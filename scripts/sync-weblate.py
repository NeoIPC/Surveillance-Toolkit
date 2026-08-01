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
anything. Running them as a separate automation account is what makes the review requirement
satisfiable: a repository that requires an approving review will not let an account approve a pull
request it opened itself, so a drain run as the maintainer can only be merged by overriding branch
protection, while one opened by an automation account can be approved normally -- which puts the
override back to being exceptional rather than the only way anything ever merges.

Two ways to select that account, both scoped to the invocation rather than exported, because an exported
value silently reroutes every later `gh` in that shell including the ones typed by hand:

    GH_CONFIG_DIR=<a config directory holding the bot's login> sync-weblate.py drain <component>
    GH_TOKEN=<the bot's token> sync-weblate.py drain <component>

Prefer the first. It keeps the credential in the same store `gh auth login` put it in, whereas a token
in an environment variable is one `env` or one crash report away from being read; authenticate the bot
once with that variable set and it stays available without ever appearing in a command.

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
    sync-weblate.py status neoipc-reports
    sync-weblate.py drain neoipc-glossary
    sync-weblate.py lock / unlock
    sync-weblate.py repair neoipc-reports
"""

from __future__ import annotations

import argparse
import contextlib
import errno
import json
import os
import re
import subprocess
import sys
import time
from collections.abc import Iterator, Sequence
from dataclasses import dataclass
from typing import Any

try:
    import requests
    from ruamel.yaml import YAML
    from wlc import Weblate
    from wlc.config import WeblateConfig
    from wlc.exceptions import WeblateException
    from wlc.models import Component
except ImportError:
    sys.exit("Error: wlc is required. Install with: pip install wlc")

PROJECT = "neoipc"
# Which repository backs a component, and where its git export lives, are both read from Weblate per
# component -- see forge_repo and weblate_tip. Nothing about a component's location is composed here.
#
# The list of not-a-person identities is the one thing still pinned to a repository. Which identities are
# tools is a fact about the project rather than about any repository, so the organization's own .github
# repository would be the tidier home -- but the list has readers that cannot fetch it: the PO header
# gate reads it from the checkout by relative path, and the translator credits are assembled during a
# render that has no network. Those need it committed here, and its header exists to stop a second copy
# being kept elsewhere, so a component in another repository reads this one over the network instead.
IDENTITIES_REPO = "NeoIPC/Surveillance-Toolkit"
_GITHUB_REPO = re.compile(r"github\.com[:/](?P<owner>[^/]+?)/(?P<name>[^/]+?)(?:\.git)?/?$")

# How long to wait for the forge to finish running checks on a freshly pushed branch, and how often to
# ask. A drain is interactive and rare, so a slow poll costs nothing and a rate limit costs a retry.
CHECK_TIMEOUT_SECONDS = 900
CHECK_POLL_SECONDS = 20
# How long to wait for a person to approve the pull request the drain opened. The component stays locked
# for this, so the timeout is what bounds how long a drain nobody is watching can block its translators;
# expiring fails the drain, which releases the lock on the way out.
APPROVAL_TIMEOUT_SECONDS = 3600
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
# What an open pull request needs while its checks are unfinished or unhappy. Checks are consulted
# before the review because a red one blocks regardless of who has approved, and reviewing a branch
# whose build is broken is work done twice.
_CHECK_VERDICT = {
    CHECKS_RUNNING: ("awaiting checks", "33", False),
    CHECKS_FAILED: ("CHECKS FAILED", "31", True),
    CHECKS_NONE: ("no checks reported", "31", True),
}

# What a review decision means to the merge gate: nothing left to wait for, a reviewer saying no, or a
# reviewer who has not answered yet.
REVIEW_SETTLED = "SETTLED"
REVIEW_REFUSED = "REFUSED"
REVIEW_WAITING = "WAITING"

# And what it needs once they are green, by the forge's own review decision. A null decision means the
# repository asks for no review, so there is nothing left to wait for.
_REVIEW_VERDICT = {
    "APPROVED": ("awaiting merge", "32", False),
    "REVIEW_REQUIRED": ("awaiting review", "36", False),
    "CHANGES_REQUESTED": ("CHANGES REQUESTED", "31", True),
    "": ("awaiting merge", "32", False),
}

_PRIORITY_DISPLAY = {
    60: ("↑↑", "31", "very high"),
    80: ("↑", "33", "high"),
    100: ("", "0", "medium"),
    120: ("↓", "2", "low"),
    140: ("↓↓", "2", "very low"),
}


def _icons_are_encodable(stream: Any) -> bool:
    """Whether this stream can carry the icons at all.

    Checked rather than assumed, and checked even when styling is being forced: a stream encoded in a
    legacy code page cannot represent a check mark or a chevron, and writing one raises rather than
    degrading. Forcing colour is a request for prettier output, not for a crash.
    """
    probe = "".join(icon for icon, _, _ in (*_CHECK_DISPLAY.values(), *_PRIORITY_DISPLAY.values()))
    try:
        probe.encode(stream.encoding or "ascii")
    except (UnicodeEncodeError, LookupError):
        return False
    return True


# GetStdHandle identifiers, from the Windows console API.
STDOUT_HANDLE = -11
STDERR_HANDLE = -12


def _enable_windows_virtual_terminal(handle_id: int) -> bool:
    """A Windows console refuses these sequences as literal text until this is turned on."""
    try:
        import ctypes

        kernel32 = ctypes.windll.kernel32
        handle = kernel32.GetStdHandle(handle_id)
        mode = ctypes.c_uint32()
        if not kernel32.GetConsoleMode(handle, ctypes.byref(mode)):
            return False
        return bool(kernel32.SetConsoleMode(handle, mode.value | 0x0004))
    except Exception:  # noqa: BLE001 - any failure here means "not supported", never a crash
        return False


def _terminal_supports_styling(stream: Any = None) -> bool:
    """Whether it is safe to emit colour, icons and hyperlinks on this stream.

    Asked per stream, because redirecting one and not the other is an ordinary thing to do
    (`2> errors.txt`) and the answer genuinely differs: an escape sequence is colour on a console and
    corruption in a file, so deciding once for stdout and then writing a styled warning to stderr
    corrupts whichever of the two was redirected. Defaults to stdout, and resolves that at call time
    rather than binding it at import, so a replaced stream is honoured.

    The two environment variables are the agreed way to override the guess in either direction, and
    FORCE_COLOR wins where both are set, per https://force-color.org. Forcing is what makes the output
    usable through a pager or in a log viewer that renders escapes, neither of which is a terminal as
    far as isatty is concerned.

    Everything else is a way of detecting that the reader is not a person at a terminal: redirected
    output goes to a file or a pipe, and TERM=dumb is how a terminal says it cannot render one.
    """
    stream = sys.stdout if stream is None else stream
    force = os.environ.get("FORCE_COLOR")
    if force is not None and force != "0":
        return _icons_are_encodable(stream)
    if force == "0" or "NO_COLOR" in os.environ or os.environ.get("TERM") == "dumb":
        return False
    if not stream.isatty():
        return False
    # Only worth attempting on a real console; a forced stream is not one, and asking would fail.
    handle_id = STDERR_HANDLE if stream is sys.stderr else STDOUT_HANDLE
    if sys.platform == "win32" and not _enable_windows_virtual_terminal(handle_id):
        return False
    return _icons_are_encodable(stream)


STYLED = _terminal_supports_styling(sys.stdout)
STYLED_ERRORS = _terminal_supports_styling(sys.stderr)


def styled(text: str, colour: str) -> str:
    return f"\033[{colour}m{text}\033[0m" if STYLED else text


def linked(text: str, url: str, *, enabled: bool | None = None) -> str:
    """Render text as a terminal hyperlink where the terminal understands one (OSC 8).

    `enabled` names the stream this is bound for; the default is stdout, where most output goes.
    """
    return (f"\033]8;;{url}\033\\{text}\033]8;;\033\\"
            if (STYLED if enabled is None else enabled) else text)


def pull_request_reference(number: int, repo: str, *, on_stderr: bool = False) -> str:
    """`#N`, clickable where the stream it is bound for can render a hyperlink.

    The number is what the operator reads; the link is what saves them retyping it into a browser. Both
    matter, which is why this degrades to the bare `#N` rather than to a URL.
    """
    return linked(f"#{number}", f"https://github.com/{repo}/pull/{number}",
                  enabled=STYLED_ERRORS if on_stderr else STYLED)


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
    forge_repo: str
    priority: int
    push_branch: str
    needs_commit: bool
    needs_push: bool
    merge_failure: str
    weblate_tip: str
    branch_tip: str | None
    open_pull_request: int | None
    checks: str
    review: str

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
        #
        # No push branch comes first because it is the state every other test here is blind to. Each of
        # them is derived from the branch, and each collapses to a benign value when there is none: no
        # branch exists, so nothing can be superseded or stranded; no pull request is found, so none is
        # awaited -- and the row lands on "idle" having established nothing. That is the same collapse
        # the drain refuses outright, and reporting it as fine is how the misconfiguration survives until
        # someone tries to drain it.
        if not self.push_branch:
            return styled("NO PUSH BRANCH — Weblate would push straight at the translated branch",
                          "31"), True
        if self.merge_failure:
            return styled(f"MERGE FAILURE: {self.merge_failure} — run repair", "31"), True
        if self.is_superseded:
            return styled("SUPERSEDED — branch carries a commit Weblate no longer holds; run drain",
                          "31"), True
        if self.is_stranded:
            return styled("STRANDED — pushed with no pull request; run drain", "31"), True
        if self.open_pull_request is not None:
            # What a pull request needs is decided by its checks and its review, not by its existence.
            # Saying "awaiting merge" while either is outstanding invites a merge that cannot happen and
            # describes a state nobody can act on; naming the blocking one says whose turn it is.
            if self.checks in _CHECK_VERDICT:
                phrase, colour, problem = _CHECK_VERDICT[self.checks]
            else:
                phrase, colour, problem = _REVIEW_VERDICT.get(
                    self.review, (f"review: {self.review}", "33", False))
            reference = pull_request_reference(self.open_pull_request, self.forge_repo)
            # Work queued behind an open request is otherwise invisible, and it is precisely what will
            # supersede the branch the moment it is committed -- so it changes what merging this costs,
            # and the operator has to be able to see it without opening Weblate.
            pending = " + translations waiting" if self.has_pending_work else ""
            # The icon repeats the phrase, which is worth it while it can be scanned and redundant once
            # it has degraded to words.
            icon = f" {render_checks(self.checks)}" if STYLED else ""
            return f"{styled(phrase, colour)} — {reference}{pending}{icon}", problem
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
    """Call the forge CLI and parse its JSON. Any failure raises; absence is a caller's question.

    Never pass --jq. It narrows the output to whatever the filter selects, and the client prints a
    selected string bare -- so a commit message comes back unquoted and parsing it raises, on a path
    that can go months without running. Read a scalar with run() instead, which wants text anyway. A
    test enforces this, because the failure surfaces at the worst possible moment otherwise: this cost a
    drain its merge, at the step after the approval had already been given.
    """
    output = run(["gh", *args])
    return json.loads(output) if output else None


def weblate_tip(record: Record) -> str:
    """The component's current commit, read without fetching any objects.

    The export URL comes from the record for the same reason the backing repository does: Weblate
    already knows it, and composing one here from the project and the slug is a second copy that goes
    wrong silently. It would not even survive a component being filed under a category -- the export
    path gains the category's slug, so the composed URL points at nothing and every command, including
    read-only status, dies talking about the export rather than about the category.

    ls-remote rather than fetch because Weblate's export refuses a fetch into a clone that already holds
    the commits its history has since replaced -- which is exactly the clone doing the draining.

    A failure raises rather than returning nothing. Returning None for an unreachable export would make
    every pushed branch compare unequal to it and so read as superseded, which is a recommendation to
    delete and recreate four branches on the strength of a network blip.
    """
    slug = record["slug"]
    url = str(record.get("git_export") or "")
    if not url:
        raise DrainError(f"{slug}: Weblate reports no git export URL for it, so its current commit "
                         f"cannot be read. Check the component is not still being created.")
    output = run(["git", "ls-remote", url, "refs/heads/main"])
    if not output:
        raise DrainError(f"{slug}: its export has no main branch, which should be impossible")
    return output.split()[0]


def branch_tip(branch: str, repo: str) -> str | None:
    """The pushed branch's commit, or None if the branch genuinely does not exist.

    matching-refs rather than the commits endpoint: it answers an absent branch with an empty array and
    a zero exit, so absence is data rather than an error code shared with every transient failure. The
    commits endpoint returns 404, which the CLI reports the same way it reports a rate limit, an expired
    token and a 5xx -- and reading any of those as "not pushed" is how a drain pushes over a branch that
    is already there.
    """
    refs = gh_json(["api", f"repos/{repo}/git/matching-refs/heads/{branch}"]) or []
    # matching-refs is a prefix match, so a branch whose name prefixes another's would return both.
    exact = [r for r in refs if r["ref"] == f"refs/heads/{branch}"]
    return exact[0]["object"]["sha"] if exact else None


COPILOT_REVIEWER = "copilot-pull-request-reviewer[bot]"
# Copilot silently declines to review a pull request past either of these, and no exclusion mechanism
# reduces the count -- not .gitattributes, not linguist-generated, not the documented exclusion list.
# A translation drain routinely exceeds both, so the request is skipped rather than spent.
COPILOT_MAX_FILES = 300
COPILOT_MAX_LINES = 20_000


NON_HUMAN_IDENTITIES = "po/non-human-identities.yaml"
_TRAILER = re.compile(r"^co-authored-by:.*<([^>]+)>\s*$", re.IGNORECASE)


def non_human_identities() -> tuple[set[str], set[str]]:
    """The domains and addresses that are not people, from the repository's own shared list.

    Read over the network rather than from a checkout, so this keeps working from any directory, and
    so it reads what is on the default branch rather than whatever the caller happens to have.

    The list is deliberately shared data rather than a constant here: its own header says it exists so
    that a second consumer in another language reads it instead of keeping a copy, because a list
    maintained twice is one that disagrees with itself.
    """
    raw = run(["gh", "api", f"repos/{IDENTITIES_REPO}/contents/{NON_HUMAN_IDENTITIES}",
               "-H", "Accept: application/vnd.github.raw"])
    data = YAML(typ="safe").load(raw) or {}
    domains = {str(d).lower() for d in (data.get("excluded_domains") or [])}
    addresses = {str(e["address"]).lower() for e in (data.get("excluded_addresses") or [])
                 if isinstance(e, dict) and e.get("address")}
    return domains, addresses


def strip_non_human_trailers(body: str, domains: set[str], addresses: set[str]) -> str:
    """Remove co-author trailers that credit a tool rather than a person.

    Matched on the ADDRESS, never the display name. The same address appears in this project's history
    under several names, so a name-keyed filter would drop one spelling and silently credit the other --
    which the shared list says in as many words.

    This is the whole reason a squash beats a replay here: the platform's add-on writes a trailer for
    every identity in the range and offers no way to exclude its own, so a verbatim replay carries a
    tool as a co-author, against the rule that a tool is not one. A squash has an editing point.
    """
    kept: list[str] = []
    for line in body.splitlines():
        match = _TRAILER.match(line.strip())
        if match:
            address = match.group(1).lower()
            if address in addresses or address.rsplit("@", 1)[-1] in domains:
                continue
        kept.append(line)
    # Collapse the blank run a removed trailer can leave at the end.
    while kept and not kept[-1].strip():
        kept.pop()
    return "\n".join(kept)


def copilot_was_requested(response: object) -> bool:
    """Whether the forge's answer shows the review request actually took.

    Separated out and checked because the status code does not say. An account with no Copilot
    entitlement receives HTTP 200 for the request and a response whose reviewer list simply does not
    contain it -- accepted, and dropped. The reviewer appears under a display name rather than the
    login the request used, so this matches on the prefix rather than on equality.
    """
    if not isinstance(response, dict):
        return False
    reviewers = response.get("requested_reviewers") or []
    return any(str(r.get("login", "")).lower().startswith("copilot") for r in reviewers)


def request_copilot_review(number: int, repo: str) -> None:
    """Ask Copilot to review, unless the diff is past what it will look at.

    Asking is all this does. A request is accepted even when the quota that would answer it is spent,
    and the failure then arrives later as a review saying only that it encountered an error -- so this
    reports what it asked for rather than what will happen, and nothing downstream waits on the answer.
    The forge's review decision tracks approving reviews, and a Copilot review is a comment, so an
    absent one never holds a drain up.

    Skipping for size is reported rather than silent. A pull request nobody mentioned was too large to
    review reads exactly like one that was reviewed and found clean, and these are the pull requests
    least likely to get a human reading instead.
    """
    size = gh_json(["pr", "view", str(number), "--repo", repo,
                    "--json", "additions,deletions,changedFiles"]) or {}
    files = int(size.get("changedFiles", 0))
    lines = int(size.get("additions", 0)) + int(size.get("deletions", 0))
    if files >= COPILOT_MAX_FILES or lines >= COPILOT_MAX_LINES:
        print(f"  no Copilot review requested: {files} files / {lines} lines is past its limit of "
              f"{COPILOT_MAX_FILES} / {COPILOT_MAX_LINES}, so it would decline")
        return
    try:
        response = gh_json(["api", "-X", "POST",
                            f"repos/{repo}/pulls/{number}/requested_reviewers",
                            "-f", f"reviewers[]={COPILOT_REVIEWER}"])
    except DrainError as error:
        # A refused review request is not worth abandoning a drain over -- the human review is the one
        # branch protection actually requires.
        print(f"  WARNING: could not request a Copilot review: {error}", file=sys.stderr)
        return

    if copilot_was_requested(response):
        print("  asked Copilot for a review (it declines silently when its quota is spent)")
    else:
        # The exit code cannot be trusted here. An account without a Copilot entitlement gets HTTP 200
        # and a response with the reviewer simply absent -- the request is accepted and dropped. Saying
        # "asked Copilot" on that response would announce a review that was never going to happen,
        # which is worse than not asking, because someone waits for it.
        print(f"  WARNING: the Copilot review request was accepted and then dropped. The account this "
              f"ran as has no Copilot entitlement; request it by hand on "
              f"{pull_request_reference(number, repo, on_stderr=True)}, or run the drain as an account "
              f"that has one.", file=sys.stderr)


def forge_identity() -> str:
    """The account the forge calls are authenticated as.

    Worth printing before anything is written, because it is invisible otherwise until it shows up as
    the author of a pull request. It also decides whether a merge needs the administrator override: a
    repository requiring an approving review will not let an account approve what it opened itself, so
    a drain run as the maintainer must override and one run as a separate automation account need not.
    """
    # run rather than gh_json: --jq on a string field emits the bare value, which is not JSON.
    return run(["gh", "api", "user", "--jq", ".login"]) or "unknown"


def open_pull_request(branch: str, repo: str) -> tuple[int, str, str] | None:
    """The open pull request for this branch, the state of its checks and its review decision.

    All three come back in one request, so knowing whether a drained branch is actually mergeable costs
    nothing beyond what asking whether it has a pull request already costs.
    """
    data = gh_json(["pr", "list", "--repo", repo, "--head", branch, "--state", "open",
                    "--json", "number,statusCheckRollup,reviewDecision"])
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
    # A null decision means the repository requires no review, not that one is outstanding.
    return data[0]["number"], checks, data[0].get("reviewDecision") or ""


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
    """Every component this tool can drive, discovered rather than listed, as raw API records.

    Every component in the project, whichever repository backs it -- the tool drives more than one, and
    scoping this to a single repository is what made `neoipc-app` invisible to it. A hard-coded list is
    a second place to register a component, and the one nobody updates. Weblate already knows which
    repository each points at and what push branch each uses.

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
    # Every component this tool can drive, whichever repository backs it -- not just one repository's.
    # The exclusion is the Weblate-local terminology store, which has no git backing at all.
    mine = [r for r in records if _GITHUB_REPO.search(str(r.get("repo") or ""))]
    # Most important first, then alphabetically. Note the direction: Weblate's COMPONENT priority runs
    # the opposite way to its per-string one -- 60 is "Very high" and 140 is "Very low" -- so ascending
    # is the order the project wants these worked, and a plain descending sort would invert it. Sorted
    # here rather than in one command so every listing agrees.
    mine.sort(key=lambda r: (r.get("priority") or DEFAULT_PRIORITY, r["slug"]))
    return mine


def forge_repo(record: Record) -> str:
    """The owner/name backing this component, taken from Weblate rather than hard-coded here.

    The same reasoning that keeps the component list out of this file applies to the repository, and
    more sharply: a constant here is a second place to record something Weblate already knows, and it
    fails by *omission* -- a component backed by another repository did not error, it simply never
    appeared in any listing, so `neoipc-app` was invisible to a tool whose whole purpose is to say what
    needs draining.
    """
    url = str(record.get("repo") or "")
    match = _GITHUB_REPO.search(url)
    if match is None:
        raise DrainError(f"{record['slug']} is backed by {url or '(nothing)'}, which is not a repository "
                         f"this tool knows how to drive")
    return f"{match['owner']}/{match['name']}"


def find_component(records: Sequence[Record], slug: str) -> Record:
    """The record for one slug, or a refusal naming the slugs that exist.

    Naming them matters more than it looks: a component this tool does not drive is indistinguishable
    from a typo, and a Weblate slug is not derivable from the catalogue's name.
    """
    record = next((r for r in records if r["slug"] == slug), None)
    if record is None:
        raise DrainError(f"unknown component '{slug}'. This tool drives: "
                         f"{', '.join(r['slug'] for r in records)}")
    return record


def operable(client: Weblate, record: Record) -> Component:
    """The modelled object for a component record, for lock, commit, push and repository operations."""
    return Component(weblate=client, **record)


def read_state(client: Weblate, record: Record) -> ComponentState:
    weblate_state = operable(client, record).repository()
    slug = record["slug"]
    forge = forge_repo(record)
    branch = record.get("push_branch") or ""
    pull_request = open_pull_request(branch, forge) if branch else None
    return ComponentState(
        slug=slug,
        forge_repo=forge,
        priority=record.get("priority") or DEFAULT_PRIORITY,
        push_branch=branch,
        needs_commit=bool(weblate_state["needs_commit"]),
        needs_push=bool(weblate_state["needs_push"]),
        merge_failure=str(weblate_state["merge_failure"] or ""),
        weblate_tip=weblate_tip(record),
        branch_tip=branch_tip(branch, forge) if branch else None,
        open_pull_request=pull_request[0] if pull_request else None,
        checks=pull_request[1] if pull_request else "",
        review=pull_request[2] if pull_request else "",
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


def wait_for_checks(branch: str, repo: str) -> None:
    """Block until every check on the branch's pull request has settled, then fail on a red one."""
    deadline = time.monotonic() + CHECK_TIMEOUT_SECONDS
    # An allow-list rather than a list of the conclusions known to be bad, because this is the
    # aggregation the merge is gated on: a conclusion nobody anticipated -- one the forge adds later, or
    # the value check_outcome falls back to -- has to read as not-green, and under a deny-list it reads
    # as green and merges. It is also exactly what open_pull_request accepts, so what `status` reports
    # and what the drain acts on cannot diverge for one rollup.
    good = {"SUCCESS", "NEUTRAL", "SKIPPED"}
    while True:
        data = gh_json(["pr", "view", "--repo", repo, branch, "--json", "statusCheckRollup"])
        nodes = (data or {}).get("statusCheckRollup") or []
        # An empty rollup is not "everything passed" -- it is the forge not having reported anything
        # yet, or having reported nothing at all. Merging on it waives the gate silently, so it is only
        # tolerated while there is still time for checks to appear, and is an error once there is not.
        outcomes = [check_outcome(n) for n in nodes]
        pending = [name for name, state in outcomes if state == "PENDING"]
        if nodes and not pending:
            failed = [name for name, state in outcomes if state not in good]
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


def approval_would_be_discarded(state: ComponentState) -> bool:
    """Whether recreating this branch would throw away an approval someone has already given.

    Recreating deletes the head branch, which closes its pull request -- so an approval given before a
    translation landed is spent on a request that no longer exists. Worth detecting here rather than
    letting the forge refuse the merge later, because the forge's refusal talks about branch protection
    and says nothing about the approval having gone stale.
    """
    return (state.is_superseded
            and state.open_pull_request is not None
            and state.review == "APPROVED")


def approval_outcome(review: str) -> str:
    """Classify a forge review decision for the merge gate.

    An empty decision means the repository requires no review at all, which is settled rather than
    outstanding: reading it as outstanding would hang every drain against a repository that has no such
    protection, and reading a genuinely outstanding one as settled would merge past a reviewer.
    """
    if review == "CHANGES_REQUESTED":
        return REVIEW_REFUSED
    if review in ("APPROVED", ""):
        return REVIEW_SETTLED
    return REVIEW_WAITING


def wait_for_approval(state: ComponentState) -> None:
    """Block until the pull request is approved, so the merge follows the approval by seconds.

    This is what keeps an approval spendable. Approving in one invocation and merging in a later one
    puts a person's attention span between the two, and anything committed to the component in that gap
    re-squashes the un-merged range -- after which the merging run finds the branch superseded and
    recreates it, which closes the very pull request that was approved. Waiting here holds the lock
    across that gap instead, so there is no gap to commit into.
    """
    print(f"  waiting for approval on "
          f"{pull_request_reference(state.open_pull_request, state.forge_repo)} — approve it now; the "
          f"component stays locked until this returns")
    deadline = time.monotonic() + APPROVAL_TIMEOUT_SECONDS
    while True:
        pull_request = open_pull_request(state.push_branch, state.forge_repo)
        if pull_request is None:
            raise DrainError(f"the pull request for {state.push_branch} closed while its approval was "
                             f"outstanding; run the drain again")
        outcome = approval_outcome(pull_request[2])
        if outcome == REVIEW_REFUSED:
            raise DrainError(f"changes were requested on {state.push_branch}'s pull request. Address "
                             f"them in Weblate -- never by editing a catalogue -- and drain again.")
        if outcome == REVIEW_SETTLED:
            print("  approved" if pull_request[2] else "  no review required by this repository")
            return
        if time.monotonic() > deadline:
            raise DrainError(f"no approval within {APPROVAL_TIMEOUT_SECONDS}s. Nothing was merged and "
                             f"the component is unlocked; re-run the drain when you can approve it.")
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
    run(["gh", "api", "-X", "DELETE", f"repos/{state.forge_repo}/git/refs/heads/{state.push_branch}"])
    checked(component.push(), f"push {state.push_branch}")


def command_status(client: Weblate, args: argparse.Namespace) -> int:
    """Report each component's state, or one component's. Read-only: it repairs nothing, by design."""
    records = repository_components(client)
    if args.component:
        records = [find_component(records, args.component)]
    problems = 0
    # Rows arrive most-important-first from repository_components; the priority column is shown so the
    # order reads as deliberate rather than arbitrary.
    # Wide enough for two chevrons and its own heading where they render, wide enough for "very high"
    # where they do not.
    priority_width = 5 if STYLED else 11
    priority_heading = "prio" if STYLED else "priority"
    print(f"{'component':<38}{priority_heading:<{priority_width}}{'branch':<26}{'needs'}")
    for record in records:
        state = read_state(client, record)
        verdict, is_problem = state.verdict
        problems += is_problem
        branch = state.push_branch if state.branch_exists else "—"
        print(f"{state.slug:<38}{render_priority(state.priority, priority_width)}"
              f"{branch:<26}{verdict}")
    return 1 if problems else 0


def command_drain(client: Weblate, args: argparse.Namespace) -> int:
    """Take one component's translations from Weblate to main, in one invocation.

    There is deliberately no switch to stop after opening the pull request. Doing so releases the lock
    with the request open, and an approval given in that state can be invalidated by any translation that
    lands before the merging run starts -- which then recreates the branch and closes the approved
    request. A drain that stops short of merging is not half a drain; it is the hazard this arrangement
    exists to remove. To abandon one, decline to approve: the wait times out, nothing is merged, and the
    component is unlocked on the way out.
    """
    records = repository_components(client)
    record = find_component(records, args.component)
    component = operable(client, record)
    # Which repository, not only which account: components are backed by more than one, and the account's
    # rights are granted per repository -- so a drain that cannot push says which door it was refused at.
    print(f"  acting on {forge_repo(record)} as {forge_identity()}")

    # Only the component being drained, because only its own translations can supersede its branch.
    # The components are standalone, so each holds its own checkout and nothing committed in one
    # reaches another's; and each push branch carries that catalogue's files alone, so merging this one
    # cannot carry another's work to main either. Locking all of them froze every catalogue in the
    # project for the length of a drain -- which now includes waiting for a person to approve.
    with components_locked([component], enabled=not args.no_lock):
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
            if approval_would_be_discarded(state):
                print(f"  WARNING: "
                      f"{pull_request_reference(state.open_pull_request, state.forge_repo, on_stderr=True)} "
                      f"is approved "
                      f"but superseded, so it is being replaced; that approval does not carry to its "
                      f"replacement, which this run will wait for you to approve.", file=sys.stderr)
            recreate_push_branch(state, component)
        elif not state.branch_exists:
            print(f"  pushing {state.push_branch}")
            checked(component.push(), f"push {state.push_branch}")
        state = read_state(client, record)

        if not state.branch_exists:
            raise DrainError(f"{state.push_branch} was not created; Weblate reported no push")

        if state.open_pull_request is None:
            number = open_drain_pull_request(state)
            print(f"  opened pull request {pull_request_reference(number, state.forge_repo)}")
            request_copilot_review(number, state.forge_repo)
            state = read_state(client, record)

        wait_for_checks(state.push_branch, state.forge_repo)
        wait_for_approval(state)

        # Re-read immediately before merging rather than trusting the state gathered above. The lock
        # covers a translation being saved, but nothing covers main moving under us -- a pull request
        # touching no catalogue at all rebases every push branch in the project.
        state = read_state(client, record)
        if state.is_superseded:
            raise DrainError(f"{state.slug} moved while the drain waited; run the drain again")
        # The checks were green before the approval wait, which blocks for as long as it takes a person
        # to answer. That is ample time for one to go red -- a re-run, a status posted asynchronously
        # (the Copilot review this drain itself requested is one), a check newly made required. Merging
        # with --admin bypasses branch protection, so this is the only thing standing in the way. Nothing
        # is lost by refusing: the branch and its approval both survive, so the drain can simply be run
        # again once the check is dealt with.
        if state.checks != CHECKS_GREEN:
            raise DrainError(f"{state.slug} was approved, but its checks are no longer green "
                             f"({state.checks}); refusing to merge. Deal with them and run the drain "
                             f"again — the branch and its approval both survive.")

        merge_drain_pull_request(state, admin=args.admin)
        merged = run(["gh", "api", f"repos/{state.forge_repo}/commits/main", "--jq", ".sha"])
        wait_until_settled(component, merged)
        print(f"{state.slug}: drained and merged as {merged[:7]}")
    return 0


def open_drain_pull_request(state: ComponentState) -> int:
    body = (
        "Translations drained from Weblate.\n\n"
        "Squash-merge this, as with every other pull request here. The branch carries a single commit, "
        "so the squash reproduces its patch exactly and Weblate still recognises its own work as "
        "merged; squashing also drops the co-author trailer naming Weblate's own service account, "
        "which a verbatim replay would carry as though a tool were a contributor.\n"
    )
    url = run(["gh", "pr", "create", "--repo", state.forge_repo, "--base", "main",
               "--head", state.push_branch,
               "--title", f"Translations update from Weblate ({state.slug})",
               "--body", body])
    return int(url.rstrip("/").rsplit("/", 1)[-1])


def merge_drain_pull_request(state: ComponentState, *, admin: bool) -> None:
    """Squash-merge, like every other pull request here, and drop the tool co-authors on the way.

    Squashing used to be forbidden for these branches because it fused several commits into one whose
    patch matched none of them, leaving the platform unable to prove its work had landed. That reason
    is gone: its own add-on now collapses each push to a single commit, and squashing one commit
    reproduces its patch exactly -- measured, identical patch id, and then confirmed by a real merge
    after which the component reported no divergence at all.

    What squashing adds is an editing point. The platform's add-on writes a co-author trailer for every
    identity in the range and cannot exclude its own, so replaying a commit verbatim credits a tool as a
    co-author, against the rule that a tool is not one. Composing the message removes exactly those.
    """
    ahead = int(run(["gh", "api", f"repos/{state.forge_repo}/compare/main...{state.push_branch}", "--jq",
                     ".ahead_by"]))
    # The single-commit property is what makes a squash patch-identical, and it is a setting on the
    # platform rather than a law -- so it is checked here rather than assumed. More than one commit
    # means the setting changed, and squashing then reproduces the failure this rule used to prevent.
    if ahead != 1:
        raise DrainError(f"{state.push_branch} carries {ahead} commits, not one. A squash would fuse "
                         f"them into a patch matching none of them, and the component would replay its "
                         f"work into a conflict. Check the Squash add-on is set to one commit.")

    # run rather than gh_json: --jq on a string field emits the bare value, which is not JSON.
    message = run(["gh", "api", f"repos/{state.forge_repo}/commits/{state.branch_tip}", "--jq",
                   ".commit.message"])
    domains, addresses = non_human_identities()
    _, _, body = message.partition("\n")

    # --match-head-commit makes the check-then-merge atomic at the forge. Re-reading state immediately
    # beforehand narrows the window; only this closes it, and the window is exactly long enough for a
    # translator's save to rewrite the range and turn the merge into a project-wide replay.
    command = ["gh", "pr", "merge", str(state.open_pull_request), "--repo", state.forge_repo,
               "--squash", "--delete-branch", "--match-head-commit", state.branch_tip,
               "--subject", f"Translations update from Weblate ({state.slug})",
               "--body", strip_non_human_trailers(body, domains, addresses)]
    if admin:
        command.append("--admin")
    run(command)

    # The pipeline requires the head branch to be gone: a surviving one makes Weblate's next push
    # non-fast-forward, and with Lock on error that rejection locks the component against translators.
    # --delete-branch asks; this establishes it, because the request is unreliable for fork branches.
    if branch_tip(state.push_branch, state.forge_repo) is not None:
        raise DrainError(f"merged "
                         f"{pull_request_reference(state.open_pull_request, state.forge_repo, on_stderr=True)}"
                         f", but {state.push_branch} still exists. Delete it before the next drain or "
                         f"Weblate's next push will be rejected.")
    print(f"  merged {pull_request_reference(state.open_pull_request, state.forge_repo)} (squash) and "
          f"confirmed "
          f"{state.push_branch} is gone")


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
    record = find_component(repository_components(client), args.component)
    if not args.yes:
        raise DrainError(f"repair rebuilds {args.component}'s checkout from main. Pass --yes to confirm.")
    # reset-keep rather than the client's reset(): the wrapped operation discards pending translations,
    # this one re-applies them onto a fresh checkout of main.
    checked(client.post(record["repository_url"], operation="reset-keep"), f"reset {args.component}")
    print(f"{args.component}: reset and reapplied")
    return 0


def with_help(parser: argparse.ArgumentParser) -> argparse.ArgumentParser:
    """Give a parser -h/--help/-?, replacing argparse's own pair.

    `-?` is what every other script in scripts/ answers to, that being PowerShell's convention for
    comment-based help. argparse cannot add a third alias to the pair it installs itself, so each
    parser is built with add_help=False and this puts all three back. Quote it in a POSIX shell --
    `?` is a glob character, so an unquoted -? is whatever the shell decides it matches.
    """
    parser.add_argument("-h", "--help", "-?", action="help", default=argparse.SUPPRESS,
                        help="show this help message and exit")
    return parser


def build_parser() -> argparse.ArgumentParser:
    parser = with_help(argparse.ArgumentParser(description=__doc__.split("\n", 1)[0],
                                               formatter_class=argparse.RawDescriptionHelpFormatter,
                                               add_help=False))
    sub = parser.add_subparsers(dest="command", required=True)

    def subcommand(name: str, summary: str) -> argparse.ArgumentParser:
        """Add a subcommand that records itself, so main can report a stray argument against it."""
        added = with_help(sub.add_parser(name, help=summary, add_help=False))
        added.set_defaults(subcommand_parser=added)
        return added

    status = subcommand("status",
                        "report each component's state; read-only, safe to run during a drain")
    status.add_argument("component", nargs="?",
                        help="report on this component alone; omit for every component")

    # One component, positionally, and no --all: a drain is serial because merging one invalidates the
    # push branch of every other, so a batch switch would be an invitation to the failure this prevents.
    drain = subcommand("drain", "drain ONE component: pull request, approval, merge")
    drain.add_argument("component", help="component slug, e.g. neoipc-glossary")
    drain.add_argument("--admin", action="store_true",
                       help="merge with the administrator override (main requires a review that a "
                            "self-authored pull request cannot obtain)")
    drain.add_argument("--no-lock", action="store_true",
                       help="do not lock the component; a translation saved mid-drain will then "
                            "supersede the branch and the drain will have to be repeated")

    # Every component in the project, not this repository's: these two are the widest thing the tool
    # does, and an operator freezing one catalogue's translators has to know they are freezing all of
    # them -- including the ones another repository backs.
    subcommand("lock", "lock every component this tool drives, across all backing repositories")
    subcommand("unlock", "unlock every component this tool drives, across all backing repositories")

    repair = subcommand("repair", "reset and reapply a diverged component")
    repair.add_argument("component", help="component slug, e.g. neoipc-glossary")
    repair.add_argument("--yes", action="store_true", help="confirm the reset")

    return parser


def main(argv: Sequence[str] | None = None) -> int:
    # Line-buffer stdout. Python block-buffers it whenever it is not a terminal, so every progress line
    # of a drain -- which spends minutes waiting on checks -- stays invisible until the process exits.
    # That leaves an operator unable to tell a working run from a hung one, which is the state in which
    # people kill runs that were fine and nurse runs that were not.
    sys.stdout.reconfigure(line_buffering=True)
    # parse_known_args, so a stray argument is reported against the subcommand that was actually named.
    # argparse hands a leftover back to the top-level parser, whose usage line lists only the subcommand
    # names -- so `status neoipc-reports` failed under a usage line that never mentions status, reading
    # as though the subcommand itself were the unrecognized part. Anything left over is still an error;
    # only which parser reports it changes.
    args, unrecognized = build_parser().parse_known_args(argv)
    if unrecognized:
        args.subcommand_parser.error(f"unrecognized arguments: {' '.join(unrecognized)}")
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
