#!/usr/bin/env python3
"""Tests for sync-weblate.py, covering the parts that decide whether a drain is safe.

Deliberately network-free. Every test here is about a classification the tool makes before it acts, and
each one covers a case where the first draft read a failure as a safe state -- an empty push branch that
passed every guard, a check rollup that counted as green because it was empty, a legacy commit status
that looked settled because it had no `conclusion` field. Those are exactly the mistakes a live run
cannot be relied on to reveal, because the state that triggers them is rare and the wrong answer looks
like success.

What is NOT covered here, and why: the drain sequence itself talks to Weblate and to the forge, and a
mock of both would assert that the code calls what the mock expects rather than that the round trip
works. Its evidence is a real drain.

The module name has a hyphen, so it is loaded by path rather than imported.

    pytest scripts/test_sync_weblate.py
"""

from __future__ import annotations

import ast
import importlib.util
import sys
from pathlib import Path

import pytest

_SPEC = importlib.util.spec_from_file_location(
    "sync_weblate", Path(__file__).with_name("sync-weblate.py")
)
assert _SPEC and _SPEC.loader
sync_weblate = importlib.util.module_from_spec(_SPEC)
sys.modules["sync_weblate"] = sync_weblate
_SPEC.loader.exec_module(sync_weblate)


def state(**overrides) -> sync_weblate.ComponentState:
    """A component state with everything benign, so each test states only what it is about."""
    defaults = dict(
        slug="neoipc-glossary",
        priority=60,
        push_branch="weblate-glossary",
        needs_commit=False,
        needs_push=False,
        merge_failure="",
        weblate_tip="a" * 40,
        branch_tip=None,
        open_pull_request=None,
        checks="",
        review="",
    )
    return sync_weblate.ComponentState(**{**defaults, **overrides})


class TestSupersession:
    """The single most consequential judgement the tool makes."""

    def test_branch_matching_weblate_is_not_superseded(self):
        assert not state(branch_tip="a" * 40, open_pull_request=1).is_superseded

    def test_branch_differing_from_weblate_is_superseded(self):
        # Merging this is what makes Weblate replay its work into a project-wide conflict.
        assert state(branch_tip="b" * 40, open_pull_request=1).is_superseded

    def test_absent_branch_is_not_superseded(self):
        # Nothing pushed cannot be stale, and reporting it as such would recommend recreating a branch
        # that does not exist.
        assert not state(branch_tip=None).is_superseded

    def test_pushed_branch_without_a_pull_request_is_stranded(self):
        assert state(branch_tip="a" * 40, open_pull_request=None).is_stranded

    def test_pushed_branch_with_a_pull_request_is_not_stranded(self):
        assert not state(branch_tip="a" * 40, open_pull_request=7).is_stranded


class TestCheckOutcome:
    """A rollup entry is a union type, and reading only one arm of it mislabels the other as green."""

    def test_completed_successful_check_run_is_success(self):
        assert sync_weblate.check_outcome(
            {"name": "build", "status": "COMPLETED", "conclusion": "SUCCESS"}) == ("build", "SUCCESS")

    def test_in_progress_check_run_is_pending(self):
        assert sync_weblate.check_outcome(
            {"name": "build", "status": "IN_PROGRESS", "conclusion": None}) == ("build", "PENDING")

    def test_failed_check_run_reports_its_conclusion(self):
        assert sync_weblate.check_outcome(
            {"name": "build", "status": "COMPLETED", "conclusion": "FAILURE"}) == ("build", "FAILURE")

    def test_legacy_commit_status_success_is_success(self):
        # A StatusContext has no status/conclusion at all. The first draft therefore read it as neither
        # pending nor failed, which is to say green.
        assert sync_weblate.check_outcome(
            {"context": "ci/legacy", "state": "SUCCESS"}) == ("ci/legacy", "SUCCESS")

    def test_legacy_commit_status_failure_is_not_treated_as_green(self):
        name, outcome = sync_weblate.check_outcome({"context": "ci/legacy", "state": "FAILURE"})
        assert (name, outcome) == ("ci/legacy", "FAILURE")

    def test_legacy_commit_status_error_is_not_treated_as_green(self):
        # ERROR is neither SUCCESS nor PENDING, and anything unrecognised must fall to the unsafe side.
        assert sync_weblate.check_outcome({"context": "ci/legacy", "state": "ERROR"})[1] == "FAILURE"

    def test_legacy_commit_status_pending_is_pending(self):
        assert sync_weblate.check_outcome({"context": "ci/legacy", "state": "PENDING"})[1] == "PENDING"


class TestRefusedOperations:
    """Weblate reports a refused repository operation with HTTP 200 and result: false."""

    def test_a_refused_operation_raises_with_weblate_s_own_detail(self):
        with pytest.raises(sync_weblate.DrainError, match="Push is disabled"):
            sync_weblate.checked({"result": False, "detail": "Push is disabled"}, "push")

    def test_a_refused_operation_without_detail_still_raises(self):
        with pytest.raises(sync_weblate.DrainError):
            sync_weblate.checked({"result": False}, "push")

    def test_an_accepted_operation_passes(self):
        sync_weblate.checked({"result": True}, "push")

    def test_a_response_without_a_result_field_passes(self):
        # Not every endpoint reports this way; absence must not be read as refusal.
        sync_weblate.checked({"detail": "queued"}, "push")


class TestVerdict:
    """One row, one answer to "what does this need next".

    The precedence tests are the point. Several of these conditions co-occur, and reporting the wrong
    one sends the operator to the wrong command -- most damagingly by suggesting a merge for a branch
    that must not be merged.
    """

    def test_idle_component_needs_nothing(self):
        verdict, problem = state().verdict
        assert verdict == "idle"
        assert not problem

    def test_untranslated_work_is_reported_but_is_not_a_defect(self):
        verdict, problem = state(needs_push=True).verdict
        assert "run drain" in verdict
        assert not problem

    def test_an_approved_pull_request_awaits_a_merge(self):
        verdict, problem = state(branch_tip="a" * 40, open_pull_request=129,
                                 checks=sync_weblate.CHECKS_GREEN, review="APPROVED").verdict
        assert verdict == "awaiting merge — #129"
        assert not problem

    def test_green_checks_without_a_review_await_the_review(self):
        # The case this repository is always in: checks pass in minutes, the review is the real gate,
        # and calling it "awaiting merge" says it is the operator's turn when it is the reviewer's.
        verdict, problem = state(branch_tip="a" * 40, open_pull_request=130,
                                 checks=sync_weblate.CHECKS_GREEN, review="REVIEW_REQUIRED").verdict
        assert verdict == "awaiting review — #130"
        assert not problem

    def test_requested_changes_are_a_defect(self):
        verdict, problem = state(branch_tip="a" * 40, open_pull_request=130,
                                 checks=sync_weblate.CHECKS_GREEN,
                                 review="CHANGES_REQUESTED").verdict
        assert "CHANGES REQUESTED" in verdict
        assert problem

    def test_no_review_requirement_means_nothing_is_awaited(self):
        # A null decision is the forge saying it asks for no review, not that one is outstanding.
        verdict, problem = state(branch_tip="a" * 40, open_pull_request=129,
                                 checks=sync_weblate.CHECKS_GREEN, review="").verdict
        assert verdict == "awaiting merge — #129"
        assert not problem

    def test_failing_checks_outrank_an_outstanding_review(self):
        # A red check blocks whoever approves, and reviewing a branch whose build is broken is work
        # done twice, so the check is the one to report.
        verdict, problem = state(branch_tip="a" * 40, open_pull_request=130,
                                 checks=sync_weblate.CHECKS_FAILED,
                                 review="REVIEW_REQUIRED").verdict
        assert "CHECKS FAILED" in verdict
        assert problem

    def test_a_pull_request_whose_checks_are_running_does_not_await_a_merge(self):
        # It cannot be merged yet, so calling it "awaiting merge" invites an action that would fail and
        # describes a state nobody can act on.
        verdict, problem = state(branch_tip="a" * 40, open_pull_request=130,
                                 checks=sync_weblate.CHECKS_RUNNING).verdict
        assert verdict == "awaiting checks — #130"
        assert not problem

    def test_a_pull_request_with_failing_checks_is_a_defect(self):
        verdict, problem = state(branch_tip="a" * 40, open_pull_request=129,
                                 checks=sync_weblate.CHECKS_FAILED).verdict
        assert "CHECKS FAILED" in verdict
        assert problem

    def test_a_pull_request_with_no_checks_at_all_is_a_defect(self):
        # Every branch here runs checks, so none reported means something did not start rather than
        # that there was nothing to run -- and merging on it would waive the gate silently.
        verdict, problem = state(branch_tip="a" * 40, open_pull_request=129,
                                 checks=sync_weblate.CHECKS_NONE).verdict
        assert "no checks" in verdict
        assert problem

    def test_superseded_is_a_defect(self):
        verdict, problem = state(branch_tip="b" * 40, open_pull_request=1).verdict
        assert verdict.startswith("SUPERSEDED")
        assert problem

    def test_stranded_is_a_defect(self):
        verdict, problem = state(branch_tip="a" * 40).verdict
        assert verdict.startswith("STRANDED")
        assert problem

    def test_merge_failure_is_a_defect_and_names_the_repair(self):
        verdict, problem = state(merge_failure="rebase conflict").verdict
        assert "run repair" in verdict
        assert problem

    def test_supersession_outranks_an_open_pull_request(self):
        # The dangerous confusion: a superseded branch usually DOES have a pull request, and reporting
        # that one first would invite the merge that replays Weblate's work across every component.
        verdict, problem = state(branch_tip="b" * 40, open_pull_request=129,
                                 checks=sync_weblate.CHECKS_GREEN).verdict
        assert verdict.startswith("SUPERSEDED")
        assert problem

    def test_merge_failure_outranks_supersession(self):
        # Both need a command, but repair has to happen first; draining a component in merge failure
        # cannot succeed.
        verdict, _ = state(merge_failure="conflict", branch_tip="b" * 40).verdict
        assert verdict.startswith("MERGE FAILURE")


class TestCopilotRequestVerification:
    """The forge accepts a review request it will not honour, so the answer has to be read.

    An account without a Copilot entitlement gets HTTP 200 and a response with the reviewer absent.
    Trusting the status code there announces a review that never happens, and someone waits for it --
    which is exactly what occurred before this check existed.
    """

    def test_a_response_listing_copilot_counts_as_requested(self):
        assert sync_weblate.copilot_was_requested(
            {"requested_reviewers": [{"login": "Copilot"}]})

    def test_the_display_name_is_matched_not_the_login_used_to_ask(self):
        # The request names copilot-pull-request-reviewer[bot]; the response says "Copilot".
        assert sync_weblate.copilot_was_requested(
            {"requested_reviewers": [{"login": "copilot-pull-request-reviewer[bot]"}]})

    def test_an_empty_reviewer_list_is_not_a_request(self):
        # The observed failure: accepted, and dropped.
        assert not sync_weblate.copilot_was_requested({"requested_reviewers": []})

    def test_another_reviewer_alone_is_not_a_request(self):
        assert not sync_weblate.copilot_was_requested({"requested_reviewers": [{"login": "Brar"}]})

    def test_a_response_without_the_field_is_not_a_request(self):
        assert not sync_weblate.copilot_was_requested({})

    def test_a_non_object_response_is_not_a_request(self):
        assert not sync_weblate.copilot_was_requested(None)


class TestStyling:
    """Colour, icons and hyperlinks must vanish when nothing can render them.

    These tests run with output captured, so STYLED is false and they assert the degraded form -- which
    is the form that matters. An escape sequence in a file or a pipe is corruption, and an icon on a
    console whose encoding cannot carry it is an exception rather than a symbol, so the plain path is
    the one that must never lose information.
    """

    def test_styling_is_off_when_output_is_not_a_terminal(self):
        assert not sync_weblate.STYLED

    def test_no_color_disables_styling(self, monkeypatch: pytest.MonkeyPatch):
        monkeypatch.delenv("FORCE_COLOR", raising=False)
        monkeypatch.setenv("NO_COLOR", "1")
        assert not sync_weblate._terminal_supports_styling()

    def test_force_color_enables_styling_without_a_terminal(self, monkeypatch: pytest.MonkeyPatch):
        # The case that makes forcing worth supporting: a pager or a log viewer renders escapes but is
        # not a terminal, so the guess based on isatty is wrong in the useful direction.
        monkeypatch.delenv("NO_COLOR", raising=False)
        monkeypatch.setenv("FORCE_COLOR", "1")
        assert sync_weblate._terminal_supports_styling()

    def test_force_color_zero_disables_styling(self, monkeypatch: pytest.MonkeyPatch):
        monkeypatch.delenv("NO_COLOR", raising=False)
        monkeypatch.setenv("FORCE_COLOR", "0")
        assert not sync_weblate._terminal_supports_styling()

    def test_force_color_wins_over_no_color(self, monkeypatch: pytest.MonkeyPatch):
        # Both set is a contradiction the user has to be able to resolve; force-color.org gives the
        # answer, and picking the other one would make FORCE_COLOR unusable on a machine where
        # NO_COLOR is exported globally -- which is exactly where someone needs to override it.
        monkeypatch.setenv("NO_COLOR", "1")
        monkeypatch.setenv("FORCE_COLOR", "1")
        assert sync_weblate._terminal_supports_styling()

    def test_styling_stays_off_when_the_icons_cannot_be_encoded(self, monkeypatch: pytest.MonkeyPatch):
        # Forcing colour asks for prettier output, never for a crash: a legacy code page cannot carry a
        # check mark, and writing one raises rather than degrading.
        class LegacyStream:
            encoding = "cp1252"

            @staticmethod
            def isatty() -> bool:
                return True

        monkeypatch.setenv("FORCE_COLOR", "1")
        monkeypatch.setattr(sync_weblate.sys, "stdout", LegacyStream())
        assert not sync_weblate._terminal_supports_styling()

    def test_a_capable_encoding_permits_the_icons(self, monkeypatch: pytest.MonkeyPatch):
        # Guards the guard: the check above must be rejecting the encoding rather than always failing.
        class ModernStream:
            encoding = "utf-8"

            @staticmethod
            def isatty() -> bool:
                return True

        monkeypatch.setenv("FORCE_COLOR", "1")
        monkeypatch.setattr(sync_weblate.sys, "stdout", ModernStream())
        assert sync_weblate._terminal_supports_styling()

    def test_unstyled_text_is_returned_unchanged(self):
        assert sync_weblate.styled("SUPERSEDED", "31") == "SUPERSEDED"

    def test_unstyled_links_keep_their_text_and_drop_the_escape(self):
        assert sync_weblate.linked("#129", "https://example.invalid/129") == "#129"

    def test_check_state_falls_back_to_words_rather_than_an_icon(self):
        # The icon carries the meaning when it can be seen; without it the words must, because a row
        # that said nothing at all would be worse than a long one.
        assert sync_weblate.render_checks(sync_weblate.CHECKS_GREEN) == "checks green"
        assert sync_weblate.render_checks(sync_weblate.CHECKS_FAILED) == "CHECKS FAILED"
        assert sync_weblate.render_checks(sync_weblate.CHECKS_RUNNING) == "checks running"
        assert sync_weblate.render_checks(sync_weblate.CHECKS_NONE) == "no checks"

    def test_an_unknown_check_state_still_renders_something(self):
        assert sync_weblate.render_checks("surprising") == "surprising"

    def test_no_verdict_leaks_an_escape_sequence_when_unstyled(self):
        cases = [
            state(),
            state(needs_push=True),
            state(branch_tip="a" * 40, open_pull_request=129, checks=sync_weblate.CHECKS_GREEN),
            state(branch_tip="a" * 40),
            state(branch_tip="b" * 40, open_pull_request=1),
            state(merge_failure="conflict"),
        ]
        for case in cases:
            verdict, _ = case.verdict
            assert "\033" not in verdict, f"escape leaked into: {verdict!r}"


class TestStatusIsReadOnly:
    """`status` must never change anything, so it is safe to run beside a drain.

    Asserted against the call graph rather than by running it, because the property has to hold on every
    path including the ones a test would not take, and because it is the kind of thing a later edit
    breaks silently: adding one convenient repair to a reporting command is an easy change to make and
    an invisible one to notice.
    """

    MUTATORS = {"lock", "unlock", "push", "commit", "post"}

    @staticmethod
    def reachable(name: str, functions: dict, seen: set[str] | None = None) -> set[str]:
        seen = set() if seen is None else seen
        if name in seen or name not in functions:
            return seen
        seen.add(name)
        for node in ast.walk(functions[name]):
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
                TestStatusIsReadOnly.reachable(node.func.id, functions, seen)
        return seen

    def test_status_reaches_no_mutating_call(self):
        source = Path(sync_weblate.__file__).read_text(encoding="utf-8")
        functions = {n.name: n for n in ast.parse(source).body if isinstance(n, ast.FunctionDef)}
        offenders = []
        for name in self.reachable("command_status", functions):
            for node in ast.walk(functions[name]):
                if not isinstance(node, ast.Call):
                    continue
                if getattr(node.func, "attr", None) in self.MUTATORS:
                    offenders.append(f"{name}: .{node.func.attr}()")
                if isinstance(node.func, ast.Name) and node.func.id == "run" and node.args:
                    literal = ast.dump(node.args[0])
                    if any(word in literal for word in ("DELETE", "'create'", "'merge'")):
                        offenders.append(f"{name}: run(...) mutates")
        assert not offenders, f"status can mutate via: {offenders}"

    def test_the_check_would_notice_a_mutating_command(self):
        # Guards the guard: run it against drain, which certainly mutates, so a broken detector cannot
        # pass the test above by finding nothing anywhere.
        source = Path(sync_weblate.__file__).read_text(encoding="utf-8")
        functions = {n.name: n for n in ast.parse(source).body if isinstance(n, ast.FunctionDef)}
        found = [
            name for name in self.reachable("command_drain", functions)
            for node in ast.walk(functions[name])
            if isinstance(node, ast.Call) and getattr(node.func, "attr", None) in self.MUTATORS
        ]
        assert found, "the detector found no mutation in drain, so it cannot vouch for status"


class TestPriorityLabel:
    """The component scale is inverted relative to the per-string one, so the number reads backwards."""

    @pytest.mark.parametrize(("value", "label"), [
        (60, "very high"), (80, "high"), (100, "medium"), (120, "low"), (140, "very low")])
    def test_known_priorities_are_named(self, value, label):
        assert state(priority=value).priority_label == label

    def test_an_unknown_priority_falls_back_to_its_number(self):
        assert state(priority=42).priority_label == "42"
