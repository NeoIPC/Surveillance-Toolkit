#!/usr/bin/env python3
"""Drive a translation round trip between this repository and Weblate.

The procedure this implements, and the reasoning behind its shape, is in
docs/localization-pipeline.md. The two facts that give it that shape:

  1. A pushed weblate-<catalogue> branch is perishable. The Squash add-on regroups the whole un-merged
     range on every commit cycle, so roughly any translated string rewrites commits that were already
     pushed.
  2. Any movement of main invalidates every open push branch in the project, because Weblate rebases
     onto it. A pull request touching no catalogue does this just as thoroughly as one that does.

(2) is why a drain handles exactly one component per invocation. Merging one invalidates the rest, so
there is no batch to offer -- the command takes a single component and there is no "all" switch.

This talks to Weblate through its own Python client rather than scraping the command-line front end,
which renders a curated subset as text: the manual procedure this replaces once reported four branches
as superseded when the underlying fetch had merely failed, and could not read the per-component
file-format parameters at all.

This does not use the local repository, for reads or for writes. Weblate pushes its own branch, and both
`git ls-remote` and the forge calls name their target explicitly, so no commit, ref, index entry or
working-tree file is written and none is read either -- the tool runs from any directory, inside a
checkout or not. That makes "it must not mutate the working tree" true by construction rather than by a
post-flight check somebody has to remember to keep.

The one thing it does inherit, when it happens to run inside a checkout, is ambient git *configuration*:
URL rewrites, proxy settings and credential helpers all apply to `git ls-remote`. That is environment
rather than repository content, but it is the reason this is described as not using the repository
rather than as hermetic.

Credentials come from the wlc configuration or the environment. There is deliberately no --api-key
option: a key passed on a command line lands in the shell history, the process list and any transcript.

Forge calls authenticate as whoever `gh` is logged in as, which the drain prints before it writes
anything. Setting GH_TOKEN for the invocation runs them as a different account, and doing so is what
makes the review requirement satisfiable: a repository that requires an approving review will not let an
account approve a pull request it opened itself, so a drain run as the maintainer can only be merged by
overriding branch protection, while one opened by a separate automation account can be approved
normally. Scope the variable to the command rather than exporting it, or every later `gh` in that shell
silently acts as the bot too.

    GH_TOKEN=<bot token> sync-weblate.py drain neoipc-glossary

`status` is read-only and may be run at any time, including beside a running drain: nothing on its call
path writes, which is asserted mechanically by the companion test rather than left to inspection. Two
things to expect if you do. It reports whatever is true at that instant, so mid-drain it may show a
component whose branch has been deleted and not yet re-pushed -- accurate, and momentarily alarming. And
it spends the same forge request budget as the drain, which now treats a forge failure as fatal rather
than reading it as "the branch is not there", so polling it in a tight loop during a drain is not free.

Every other subcommand writes, and none of them is safe to run beside another.

Two limitations it does not pretend to solve. Serialization holds within one invocation, not across
two: nothing stops a second drain being started from another shell, and the two would race exactly as
two people would. And a process killed outright leaves the components it locked locked, because there
is no exit path left to run -- `unlock` is the recovery, and `status` will not tell you, so a drain that
died is worth following with one.

    sync-weblate.py status
    sync-weblate.py drain neoipc-glossary
    sync-weblate.py drain neoipc-glossary --merge
    sync-weblate.py lock / unlock
    sync-weblate.py repair neoipc-reports
"""

from __future__ import annotations

import argparse
import contextlib
import errno
import json
import os
import subprocess
import sys
import time
from collections.abc import Iterator, Sequence
from dataclasses import dataclass
from typing import Any

try:
    import requests
    from wlc import Weblate
    from wlc.config import WeblateConfig
    from wlc.exceptions import WeblateException
    from wlc.models import Component
except ImportError:
    sys.exit("Error: wlc is required. Install with: pip install wlc")

PROJECT = "neoipc"
FORGE_REPO = "NeoIPC/Surveillance-Toolkit"
GIT_EXPORT = "https://hosted.weblate.org/git/{project}/{slug}/"

# How long to wait for the forge to finish running checks on a freshly pushed branch, and how often to
# ask. A drain is interactive and rare, so a slow poll costs nothing and a rate limit costs a retry.
CHECK_TIMEOUT_SECONDS = 900
CHECK_POLL_SECONDS = 20
# After a merge, Weblate has to pull the new main and rebase whatever is still pending before the next
# component can be drained. Nothing signals that, so it is polled.
SETTLE_TIMEOUT_SECONDS = 300
# No subprocess here is long-running, so a slow one is a hang rather than work in progress.
SUBPROCESS_TIMEOUT_SECONDS = 120
# Weblate's "Medium", used when a component does not state one. Its scale runs 60 (Very high) to 140
# (Very low), so a component with no priority sorts among the middle rather than first or last.
DEFAULT_PRIORITY = 100

# One component record as the API returns it. Kept as the raw mapping rather than a model because the
# client's Component omits fields the endpoint sends -- push_branch among them.
Record = dict[str, Any]

# How a component's checks stand, as a token rather than a sentence, so the report can render it as an
# icon where that works and as words where it does not.
CHECKS_GREEN = "green"
CHECKS_RUNNING = "running"
CHECKS_FAILED = "failed"
CHECKS_NONE = "none"

_CHECK_DISPLAY = {
    CHECKS_GREEN: ("✓", "32", "checks green"),
    CHECKS_RUNNING: ("…", "33", "checks running"),
    CHECKS_FAILED: ("✗", "31", "CHECKS FAILED"),
    CHECKS_NONE: ("?", "2", "no checks"),
}

# Priority as Weblate itself draws it on the project page: a doubled chevron for the extremes, a single
# one either side of the middle, and nothing at all for medium. Matching it means the two views agree at
# a glance instead of having to be translated between. Medium is deliberately blank rather than a dash --
# it is the default, and marking the default draws the eye to the rows that least need it.
_PRIORITY_DISPLAY = {
    60: ("↑↑", "31", "very high"),
    80: ("↑", "33", "high"),
    100: ("", "0", "medium"),
    120: ("↓", "2", "low"),
    140: ("↓↓", "2", "very low"),
}


def _icons_are_encodable() -> bool:
    """Whether this stream can carry the icons at all.

    Checked rather than assumed, and checked even when styling is being forced: a stream encoded in a
    legacy code page cannot represent a check mark or a chevron, and writing one raises rather than
    degrading. Forcing colour is a request for prettier output, not for a crash.
    """
    probe = "".join(icon for icon, _, _ in (*_CHECK_DISPLAY.values(), *_PRIORITY_DISPLAY.values()))
    try:
        probe.encode(sys.stdout.encoding or "ascii")
    except (UnicodeEncodeError, LookupError):
        return False
    return True


def _enable_windows_virtual_terminal() -> bool:
    """A Windows console refuses these sequences as literal text until this is turned on."""
    try:
        import ctypes

        kernel32 = ctypes.windll.kernel32
        handle = kernel32.GetStdHandle(-11)  # STD_OUTPUT_HANDLE
        mode = ctypes.c_uint32()
        if not kernel32.GetConsoleMode(handle, ctypes.byref(mode)):
            return False
        return bool(kernel32.SetConsoleMode(handle, mode.value | 0x0004))
    except Exception:  # noqa: BLE001 - any failure here means "not supported", never a crash
        return False


def _terminal_supports_styling() -> bool:
    """Whether it is safe to emit colour, icons and hyperlinks.

    The two environment variables are the agreed way to override the guess in either direction, and
    FORCE_COLOR wins where both are set, per https://force-color.org. Forcing is what makes the output
    usable through a pager or in a log viewer that renders escapes, neither of which is a terminal as
    far as isatty is concerned.

    Everything else is a way of detecting that the reader is not a person at a terminal: redirected
    output goes to a file or a pipe, where an escape sequence is corruption rather than colour, and
    TERM=dumb is how a terminal says it cannot render one.
    """
    force = os.environ.get("FORCE_COLOR")
    if force is not None and force != "0":
        return _icons_are_encodable()
    if force == "0" or "NO_COLOR" in os.environ or os.environ.get("TERM") == "dumb":
        return False
    if not sys.stdout.isatty():
        return False
    # Only worth attempting on a real console; a forced stream is not one, and asking would fail.
    if sys.platform == "win32" and not _enable_windows_virtual_terminal():
        return False
    return _icons_are_encodable()


STYLED = _terminal_supports_styling()


def styled(text: str, colour: str) -> str:
    return f"\033[{colour}m{text}\033[0m" if STYLED else text


def linked(text: str, url: str) -> str:
    """Render text as a terminal hyperlink where the terminal understands one (OSC 8)."""
    return f"\033]8;;{url}\033\\{text}\033]8;;\033\\" if STYLED else text


def render_checks(checks: str) -> str:
    """An icon where it can be seen, the words where it cannot -- never nothing."""
    icon, colour, words = _CHECK_DISPLAY.get(checks, ("?", "2", checks))
    return styled(icon, colour) if STYLED else words


def render_priority(priority: int, width: int) -> str:
    """Weblate's chevrons where they can be seen, its words where they cannot.

    Padded before it is styled, never after: the escape sequences carry no width, so padding the styled
    string would count them as characters and pull every column after this one out of line.
    """
    icon, colour, words = _PRIORITY_DISPLAY.get(priority, ("", "0", str(priority)))
    text = icon if STYLED else words
    return styled(text.ljust(width), colour) if STYLED else text.ljust(width)


class DrainError(RuntimeError):
    """A drain could not proceed safely. The message says what to do about it."""


@dataclass(frozen=True, slots=True)
class ComponentState:
    """Everything one component's row needs, gathered once."""

    slug: str
    priority: int
    push_branch: str
    needs_commit: bool
    needs_push: bool
    merge_failure: str
    weblate_tip: str
    branch_tip: str | None
    open_pull_request: int | None
    checks: str

    @property
    def priority_label(self) -> str:
        """Weblate's own word for the priority, because the number reads backwards to everyone."""
        return {60: "very high", 80: "high", 100: "medium", 120: "low", 140: "very low"}.get(
            self.priority, str(self.priority))

    @property
    def branch_exists(self) -> bool:
        return self.branch_tip is not None

    @property
    def is_superseded(self) -> bool:
        """The pushed branch carries a commit Weblate no longer holds.

        Merging in this state is the failure the whole arrangement exists to prevent: git can no longer
        prove main contains Weblate's work, so it replays and conflicts across every component.
        """
        return self.branch_exists and self.branch_tip != self.weblate_tip

    @property
    def is_stranded(self) -> bool:
        """Pushed, but with no pull request to carry it -- so it drifts further from main unnoticed."""
        return self.branch_exists and self.open_pull_request is None

    @property
    def has_pending_work(self) -> bool:
        return self.needs_commit or self.needs_push

    @property
    def verdict(self) -> tuple[str, bool]:
        """What this component needs next, and whether that counts as a problem.

        One verdict rather than a set of flags, because the question an operator actually has is what to
        do, and a row that says "ok" for both a finished component and one holding a pull request nobody
        has merged answers it for neither. Ordered by urgency: a state that blocks the next drain is
        reported ahead of one that merely waits for a person.

        The boolean is whether the row is a defect. Waiting for a merge and holding untranslated work
        are ordinary states, so only the three that need repair make the command exit non-zero.
        """
        # Only the last column is styled, so escape sequences cannot disturb the padding of the ones
        # before it.
        if self.merge_failure:
            return styled(f"MERGE FAILURE: {self.merge_failure} — run repair", "31"), True
        if self.is_superseded:
            return styled("SUPERSEDED — branch carries a commit Weblate no longer holds; run drain",
                          "31"), True
        if self.is_stranded:
            return styled("STRANDED — pushed with no pull request; run drain", "31"), True
        if self.open_pull_request is not None:
            number = self.open_pull_request
            reference = linked(f"#{number}", f"https://github.com/{FORGE_REPO}/pull/{number}")
            separator = " " if STYLED else ", "
            return f"awaiting merge — {reference}{separator}{render_checks(self.checks)}", False
        if self.has_pending_work:
            return "translations waiting — run drain", False
        return styled("idle", "2"), False


def run(command: Sequence[str], *, timeout: int = SUBPROCESS_TIMEOUT_SECONDS) -> str:
    """Run a command and return its stdout, raising DrainError with the real message on failure.

    Every failure raises. There is deliberately no "tolerate a non-zero exit" switch: a command that
    fails for one reason exits the same way as one that fails for another, so a caller that swallows an
    exit code cannot tell "this does not exist" from "the network is down" -- and every such conflation
    here turns into the tool reporting a safe state it has not established.

    Output is decoded as UTF-8 rather than in the platform's locale encoding, which on a Windows console
    is a legacy code page that mangles any non-ASCII byte a branch name or an error message may carry.

    GIT_TERMINAL_PROMPT=0 and a timeout because ls-remote against an unreachable or auth-refusing host
    otherwise blocks on a credential prompt with no terminal to answer it, and hangs the drain.
    """
    try:
        result = subprocess.run(
            command,
            capture_output=True,
            encoding="utf-8",
            errors="replace",
            check=False,
            timeout=timeout,
            env={**os.environ, "GIT_TERMINAL_PROMPT": "0"},
        )
    except subprocess.TimeoutExpired as error:
        raise DrainError(f"{' '.join(command)} timed out after {timeout}s") from error
    if result.returncode != 0:
        raise DrainError(f"{' '.join(command)} failed ({result.returncode}): {result.stderr.strip()}")
    return result.stdout.strip()


def gh_json(args: Sequence[str]) -> object:
    """Call the forge CLI and parse its JSON. Any failure raises; absence is a caller's question."""
    output = run(["gh", *args])
    return json.loads(output) if output else None


def weblate_tip(slug: str) -> str:
    """The component's current commit, read without fetching any objects.

    ls-remote rather than fetch because Weblate's export refuses a fetch into a clone that already holds
    the commits its history has since replaced -- which is exactly the clone doing the draining.

    A failure raises rather than returning nothing. Returning None for an unreachable export would make
    every pushed branch compare unequal to it and so read as superseded, which is a recommendation to
    delete and recreate four branches on the strength of a network blip.
    """
    url = GIT_EXPORT.format(project=PROJECT, slug=slug)
    output = run(["git", "ls-remote", url, "refs/heads/main"])
    if not output:
        raise DrainError(f"{slug}: its export has no main branch, which should be impossible")
    return output.split()[0]


def branch_tip(branch: str) -> str | None:
    """The pushed branch's commit, or None if the branch genuinely does not exist.

    matching-refs rather than the commits endpoint: it answers an absent branch with an empty array and
    a zero exit, so absence is data rather than an error code shared with every transient failure. The
    commits endpoint returns 404, which the CLI reports the same way it reports a rate limit, an expired
    token and a 5xx -- and reading any of those as "not pushed" is how a drain pushes over a branch that
    is already there.
    """
    refs = gh_json(["api", f"repos/{FORGE_REPO}/git/matching-refs/heads/{branch}"]) or []
    # matching-refs is a prefix match, so a branch whose name prefixes another's would return both.
    exact = [r for r in refs if r["ref"] == f"refs/heads/{branch}"]
    return exact[0]["object"]["sha"] if exact else None


def forge_identity() -> str:
    """The account the forge calls are authenticated as.

    Worth printing before anything is written, because it is invisible otherwise until it shows up as
    the author of a pull request. It also decides whether a merge needs the administrator override: a
    repository requiring an approving review will not let an account approve what it opened itself, so
    a drain run as the maintainer must override and one run as a separate automation account need not.
    """
    # run rather than gh_json: --jq on a string field emits the bare value, which is not JSON.
    return run(["gh", "api", "user", "--jq", ".login"]) or "unknown"


def open_pull_request(branch: str) -> tuple[int, str] | None:
    """The open pull request for this branch and the state of its checks, or None if there is none.

    The rollup comes back in the same request as the number, so knowing whether a drained branch is
    actually mergeable costs nothing beyond what asking whether it has a pull request already costs.
    """
    data = gh_json(["pr", "list", "--repo", FORGE_REPO, "--head", branch, "--state", "open",
                    "--json", "number,statusCheckRollup"])
    if not data:
        return None
    nodes = data[0].get("statusCheckRollup") or []
    outcomes = [state for _, state in (check_outcome(n) for n in nodes)]
    if not outcomes:
        checks = CHECKS_NONE
    elif "PENDING" in outcomes:
        checks = CHECKS_RUNNING
    elif any(o not in ("SUCCESS", "NEUTRAL", "SKIPPED") for o in outcomes):
        checks = CHECKS_FAILED
    else:
        checks = CHECKS_GREEN
    return data[0]["number"], checks


def checked(result: object, what: str) -> None:
    """Raise when Weblate declined a repository operation it reported with a 200.

    Weblate answers a refused commit, push or reset with HTTP 200 and {"result": false, "detail": ...},
    so the client raises nothing and the caller sees success. Its own command-line front end guards
    every such call for this reason. Discarding these return values is precisely the failure this tool
    exists to remove -- an operation that quietly did nothing, indistinguishable from one that worked.
    """
    if isinstance(result, dict) and not result.get("result", True):
        detail = result.get("detail") or "no detail given"
        raise DrainError(f"Weblate refused to {what}: {detail}")


def connect() -> Weblate:
    config = WeblateConfig()
    config.load()
    return Weblate(config=config)


def repository_components(client: Weblate) -> list[Record]:
    """The components backed by this repository, discovered rather than listed, as raw API records.

    A hard-coded list is a second place to register a component, and the one nobody updates. Weblate
    already knows which components point here and what push branch each uses.

    Raw records rather than modelled objects because the model does not carry every field: push_branch
    is absent from Component.PARAMS, so attribute access on it raises rather than returning the value
    the endpoint plainly sent. The same omission is why the command-line client cannot display it. The
    modelled object is still what performs operations -- see `operable` -- so this returns the records
    and lets each caller ask for the object when it needs to act rather than to read.
    """
    project = client.get_project(PROJECT)  # get_project prepends "projects" itself; pass the slug alone
    records: list[Record] = []
    # Paginated: reading only ["results"] silently stops at the page size, and a component past it is
    # simply never drained -- a component the tool does not know about is worse than one it refuses.
    url = f"projects/{project['slug']}/components/"
    while url:
        page = client.get(url)
        records.extend(page["results"])
        url = page.get("next")
    mine = [r for r in records if FORGE_REPO.lower() in str(r.get("repo", "")).lower()]
    # Most important first, then alphabetically. Note the direction: Weblate's COMPONENT priority runs
    # the opposite way to its per-string one -- 60 is "Very high" and 140 is "Very low" -- so ascending
    # is the order the project wants these worked, and a plain descending sort would invert it. Sorted
    # here rather than in one command so every listing agrees.
    mine.sort(key=lambda r: (r.get("priority") or DEFAULT_PRIORITY, r["slug"]))
    return mine


def operable(client: Weblate, record: Record) -> Component:
    """The modelled object for a component record, for lock, commit, push and repository operations."""
    return Component(weblate=client, **record)


def read_state(client: Weblate, record: Record) -> ComponentState:
    repo = operable(client, record).repository()
    slug = record["slug"]
    branch = record.get("push_branch") or ""
    pull_request = open_pull_request(branch) if branch else None
    return ComponentState(
        slug=slug,
        priority=record.get("priority") or DEFAULT_PRIORITY,
        push_branch=branch,
        needs_commit=bool(repo["needs_commit"]),
        needs_push=bool(repo["needs_push"]),
        merge_failure=str(repo["merge_failure"] or ""),
        weblate_tip=weblate_tip(slug),
        branch_tip=branch_tip(branch) if branch else None,
        open_pull_request=pull_request[0] if pull_request else None,
        checks=pull_request[1] if pull_request else "",
    )


@contextlib.contextmanager
def components_locked(components: Sequence[Component], *, enabled: bool = True) -> Iterator[None]:
    """Lock the given components for the duration of the block, and unlock whatever was locked.

    A context manager rather than a lock/unlock pair because the unlock has to survive an exception and
    an early return, not merely a tidy exit: a component left locked blocks every translator and is
    invisible from the repository, which has already happened once here. Only components this call
    actually locked are unlocked, so a component someone locked deliberately is not freed by accident.
    """
    if not enabled:
        yield
        return

    locked = []
    try:
        for component in components:
            if not component.lock_status()["locked"]:
                component.lock()
                locked.append(component)
                print(f"  locked {component['slug']}")
        yield
    finally:
        for component in locked:
            try:
                component.unlock()
                print(f"  unlocked {component['slug']}")
            except Exception as error:  # noqa: BLE001 - one failure must not strand the rest
                print(f"  WARNING: could not unlock {component['slug']}: {error}", file=sys.stderr)


def check_outcome(node: Record) -> tuple[str, str]:
    """Classify one entry of a check rollup as (name, state).

    The rollup is a union: a CheckRun carries status/conclusion/name, while a legacy StatusContext
    carries state/context and none of those. Reading only the CheckRun shape makes every commit status
    look neither pending nor failed -- so a red one is counted as settled and green.
    """
    if "status" in node or "conclusion" in node:
        name = node.get("name") or "check"
        if node.get("status") not in (None, "COMPLETED"):
            return name, "PENDING"
        return name, str(node.get("conclusion") or "NEUTRAL")
    name = node.get("context") or "status"
    state = str(node.get("state") or "").upper()
    return name, {"PENDING": "PENDING", "EXPECTED": "PENDING", "SUCCESS": "SUCCESS"}.get(state, "FAILURE")


def wait_for_checks(branch: str) -> None:
    """Block until every check on the branch's pull request has settled, then fail on a red one."""
    deadline = time.monotonic() + CHECK_TIMEOUT_SECONDS
    bad = {"FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE", "STALE"}
    while True:
        data = gh_json(["pr", "view", "--repo", FORGE_REPO, branch, "--json", "statusCheckRollup"])
        nodes = (data or {}).get("statusCheckRollup") or []
        # An empty rollup is not "everything passed" -- it is the forge not having reported anything
        # yet, or having reported nothing at all. Merging on it waives the gate silently, so it is only
        # tolerated while there is still time for checks to appear, and is an error once there is not.
        outcomes = [check_outcome(n) for n in nodes]
        pending = [name for name, state in outcomes if state == "PENDING"]
        if nodes and not pending:
            failed = [name for name, state in outcomes if state in bad]
            if failed:
                raise DrainError(f"checks failed on {branch}: {', '.join(failed)}")
            print(f"  checks settled, {len(outcomes)} green")
            return
        if time.monotonic() > deadline:
            if not nodes:
                raise DrainError(f"no checks were reported for {branch} within "
                                 f"{CHECK_TIMEOUT_SECONDS}s; refusing to merge an ungated branch")
            raise DrainError(f"checks on {branch} still running after {CHECK_TIMEOUT_SECONDS}s: "
                             f"{', '.join(pending)}")
        time.sleep(CHECK_POLL_SECONDS)


def wait_until_settled(component, merged_tip: str) -> None:
    """Wait for Weblate to pull the merged main, so the next component starts from a settled instance."""
    deadline = time.monotonic() + SETTLE_TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        repo = component.repository()
        if str(repo["remote_commit"]["revision"]).startswith(merged_tip[:7]):
            print("  Weblate has pulled the merged main")
            return
        time.sleep(CHECK_POLL_SECONDS)
    print("  WARNING: Weblate has not yet pulled the merged main; re-check before draining the next "
          "component", file=sys.stderr)


def recreate_push_branch(state: ComponentState, component) -> None:
    """Replace a superseded push branch with Weblate's current one.

    The branch is deleted and Weblate pushes a fresh one, rather than the tip being force-updated from a
    local clone. That keeps the tool out of the local repository entirely and avoids fetching from an
    export that refuses the fetch anyway. The cost is the pull request's number: deleting the head
    branch closes it, so a new one is opened below. These carry no review to preserve -- they are too
    large for a bot to review and a human reviews the counts, not the diff.
    """
    print(f"  branch {state.push_branch} is superseded ({state.branch_tip[:7]} vs "
          f"{state.weblate_tip[:7]}); recreating it")
    run(["gh", "api", "-X", "DELETE", f"repos/{FORGE_REPO}/git/refs/heads/{state.push_branch}"])
    checked(component.push(), f"push {state.push_branch}")


def command_status(client: Weblate, _args: argparse.Namespace) -> int:
    """Report each component's state. Read-only: it repairs nothing, by design."""
    problems = 0
    # Rows arrive most-important-first from repository_components; the priority column is shown so the
    # order reads as deliberate rather than arbitrary.
    # Wide enough for two chevrons and its own heading where they render, wide enough for "very high"
    # where they do not.
    priority_width = 5 if STYLED else 11
    priority_heading = "prio" if STYLED else "priority"
    print(f"{'component':<38}{priority_heading:<{priority_width}}{'branch':<26}{'needs'}")
    for record in repository_components(client):
        state = read_state(client, record)
        verdict, is_problem = state.verdict
        problems += is_problem
        branch = state.push_branch if state.branch_exists else "—"
        print(f"{state.slug:<38}{render_priority(state.priority, priority_width)}"
              f"{branch:<26}{verdict}")
    return 1 if problems else 0


def command_drain(client: Weblate, args: argparse.Namespace) -> int:
    """Take one component's translations from Weblate to a pull request, and optionally merge it."""
    records = repository_components(client)
    record = next((r for r in records if r["slug"] == args.component), None)
    if record is None:
        known = ", ".join(sorted(r["slug"] for r in records))
        raise DrainError(f"unknown component '{args.component}'. This repository backs: {known}")
    component = operable(client, record)
    print(f"  acting on the forge as {forge_identity()}")

    # Every component is locked, not just the one being drained: a translation saved anywhere in the
    # project reaches main through this merge and would supersede the branch mid-flight.
    with components_locked([operable(client, r) for r in records], enabled=not args.no_lock):
        state = read_state(client, record)
        # An empty push branch means Weblate pushes to the branch it translates -- main. Every guard
        # here is built on the branch name, and each collapses to a benign value when it is empty, so
        # the one configuration that must never be drained is the one that would pass every check.
        if not state.push_branch:
            raise DrainError(f"{state.slug} has no push branch configured, so a push would go straight "
                             f"at the translated branch. Set one in Weblate before draining it.")
        if state.merge_failure:
            raise DrainError(f"{state.slug} is in merge failure: {state.merge_failure}. "
                             f"Run 'repair {state.slug}' first.")
        if not state.has_pending_work and not state.branch_exists:
            print(f"{state.slug}: nothing pending and nothing pushed — no drain needed")
            return 0

        if state.needs_commit:
            print(f"  committing pending translations in {state.slug}")
            checked(component.commit(), f"commit {state.slug}")
            state = read_state(client, record)
            if state.needs_commit:
                raise DrainError(f"{state.slug} still reports uncommitted translations after a commit "
                                 f"it accepted; refusing to drain a partial state")

        if state.is_superseded:
            recreate_push_branch(state, component)
        elif not state.branch_exists:
            print(f"  pushing {state.push_branch}")
            checked(component.push(), f"push {state.push_branch}")
        state = read_state(client, record)

        if not state.branch_exists:
            raise DrainError(f"{state.push_branch} was not created; Weblate reported no push")

        if state.open_pull_request is None:
            number = open_drain_pull_request(state)
            print(f"  opened pull request #{number}")
            state = read_state(client, record)

        wait_for_checks(state.push_branch)

        # Re-read immediately before merging rather than trusting the state gathered above: a
        # translation saved while the checks ran would have rewritten the range under us.
        state = read_state(client, record)
        if state.is_superseded:
            raise DrainError(f"{state.slug} moved while its checks ran; run the drain again")

        if not args.merge:
            print(f"{state.slug}: pull request #{state.open_pull_request} is ready. "
                  f"Re-run with --merge once you have approved it.")
            return 0

        merge_drain_pull_request(state, admin=args.admin)
        merged = run(["gh", "api", f"repos/{FORGE_REPO}/commits/main", "--jq", ".sha"])
        wait_until_settled(component, merged)
        print(f"{state.slug}: drained and merged as {merged[:7]}")
    return 0


def open_drain_pull_request(state: ComponentState) -> int:
    body = (
        "Translations drained from Weblate.\n\n"
        "Merge this with \"Rebase and merge\". A squash gives these commits a different patch identity, "
        "after which Weblate cannot recognise its own work as already merged and replays it into a "
        "conflict across every component at once.\n"
    )
    url = run(["gh", "pr", "create", "--repo", FORGE_REPO, "--base", "main",
               "--head", state.push_branch,
               "--title", f"Translations update from Weblate ({state.slug})",
               "--body", body])
    return int(url.rstrip("/").rsplit("/", 1)[-1])


def merge_drain_pull_request(state: ComponentState, *, admin: bool) -> None:
    """Rebase-merge, never squash.

    Squashing is what this repository does everywhere else, and is exactly wrong here: it rewrites the
    commits' patch identity, so Weblate can no longer prove main contains its work.
    """
    # --match-head-commit makes the check-then-merge atomic at the forge. Re-reading state immediately
    # beforehand narrows the window; only this closes it, and the window is exactly long enough for a
    # translator's save to rewrite the range and turn the merge into a project-wide replay.
    command = ["gh", "pr", "merge", str(state.open_pull_request), "--repo", FORGE_REPO,
               "--rebase", "--delete-branch", "--match-head-commit", state.branch_tip]
    if admin:
        command.append("--admin")
    run(command)

    # The pipeline requires the head branch to be gone: a surviving one makes Weblate's next push
    # non-fast-forward, and with Lock on error that rejection locks the component against translators.
    # --delete-branch asks; this establishes it, because the request is unreliable for fork branches.
    if branch_tip(state.push_branch) is not None:
        raise DrainError(f"merged #{state.open_pull_request}, but {state.push_branch} still exists. "
                         f"Delete it before the next drain or Weblate's next push will be rejected.")
    print(f"  merged #{state.open_pull_request} (rebase) and confirmed {state.push_branch} is gone")


def command_lock(client: Weblate, _args: argparse.Namespace) -> int:
    for record in repository_components(client):
        operable(client, record).lock()
        print(f"locked {record['slug']}")
    return 0


def command_unlock(client: Weblate, _args: argparse.Namespace) -> int:
    for record in repository_components(client):
        operable(client, record).unlock()
        print(f"unlocked {record['slug']}")
    return 0


def command_repair(client: Weblate, args: argparse.Namespace) -> int:
    """Reset and reapply a diverged component.

    Non-destructive: it re-derives the checkout from main and re-applies pending translations on top.
    The plain 'reset' operation, which the client also exposes, discards them and is never what is
    wanted here.
    """
    record = next((r for r in repository_components(client) if r["slug"] == args.component), None)
    if record is None:
        raise DrainError(f"unknown component '{args.component}'")
    if not args.yes:
        raise DrainError(f"repair rebuilds {args.component}'s checkout from main. Pass --yes to confirm.")
    # reset-keep rather than the client's reset(): the wrapped operation discards pending translations,
    # this one re-applies them onto a fresh checkout of main.
    checked(client.post(record["repository_url"], operation="reset-keep"), f"reset {args.component}")
    print(f"{args.component}: reset and reapplied")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0],
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("status",
                   help="report each component's state; read-only, safe to run during a drain")

    # One component, positionally, and no --all: a drain is serial because merging one invalidates the
    # push branch of every other, so a batch switch would be an invitation to the failure this prevents.
    drain = sub.add_parser("drain", help="drain ONE component to a pull request")
    drain.add_argument("component", help="component slug, e.g. neoipc-glossary")
    drain.add_argument("--merge", action="store_true",
                       help="merge the pull request once its checks are green")
    drain.add_argument("--admin", action="store_true",
                       help="merge with the administrator override (main requires a review that a "
                            "self-authored pull request cannot obtain)")
    drain.add_argument("--no-lock", action="store_true",
                       help="do not lock the components; a translation saved mid-drain will then "
                            "supersede the branch and the drain will have to be repeated")

    sub.add_parser("lock", help="lock every component backed by this repository")
    sub.add_parser("unlock", help="unlock every component backed by this repository")

    repair = sub.add_parser("repair", help="reset and reapply a diverged component")
    repair.add_argument("component")
    repair.add_argument("--yes", action="store_true", help="confirm the reset")

    return parser


def main(argv: Sequence[str] | None = None) -> int:
    # Line-buffer stdout. Python block-buffers it whenever it is not a terminal, so every progress line
    # of a drain -- which spends minutes waiting on checks -- stays invisible until the process exits.
    # That leaves an operator unable to tell a working run from a hung one, which is the state in which
    # people kill runs that were fine and nurse runs that were not.
    sys.stdout.reconfigure(line_buffering=True)
    args = build_parser().parse_args(argv)
    commands = {
        "status": command_status,
        "drain": command_drain,
        "lock": command_lock,
        "unlock": command_unlock,
        "repair": command_repair,
    }
    # Expected failures -- a refused drain, a server saying no -- become a message, because a traceback
    # tells the operator nothing they can act on. Anything else is a defect in this script and keeps its
    # traceback, which is the only thing that makes it findable.
    # Expected failures -- a refused drain, a server saying no, a network that is not there -- become a
    # message, because a traceback tells the operator nothing they can act on. requests is named
    # explicitly: the client converts known HTTP errors into WeblateException but re-raises a connection
    # or timeout error unchanged. Anything else is a defect in this script and keeps its traceback,
    # which is the only thing that makes it findable.
    try:
        return commands[args.command](connect(), args)
    except (DrainError, WeblateException, requests.RequestException) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    except (BrokenPipeError, OSError) as error:
        # `status | head` closes the pipe while there is still output to write. That is an ordinary
        # thing to type, and it should end quietly rather than in a traceback about the reader being
        # gone. Windows raises OSError EINVAL where POSIX raises BrokenPipeError, so both are caught,
        # and anything else is re-raised because it is a real failure wearing the same class.
        if isinstance(error, OSError) and not isinstance(error, BrokenPipeError):
            if error.errno not in (errno.EPIPE, errno.EINVAL):
                raise
        # Point the interpreter's own final flush at nothing, so it cannot fail the same way on exit
        # and print a second, uglier report of the same event.
        with contextlib.suppress(OSError):
            os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
        return 0


if __name__ == "__main__":
    sys.exit(main())
