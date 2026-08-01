#!/usr/bin/env python3
"""Tests for sync-weblate.py, covering the parts that decide whether a drain is safe.

Deliberately network-free. Every test here is about a classification the tool makes before it acts, and
each one covers a case where the first draft read a failure as a safe state -- an empty push branch that
passed every guard, a check rollup that counted as green because it was empty, a legacy commit status
that looked settled because it had no `conclusion` field. Those are exactly the mistakes a live run
cannot be relied on to reveal, because the state that triggers them is rare and the wrong answer looks
like success.

What is NOT covered here, and why: the drain *sequence* talks to Weblate and to the forge, and a mock of
both would assert that the code calls what the mock expects rather than that the round trip works. Its
evidence is a real drain. The refusals along that sequence are a different matter and are covered --
each is a classification made before anything is touched, which is precisely what a live run is least
likely to reach, since it fires only on a state that should never occur.

The module name has a hyphen, so it is loaded by path rather than imported.

    pytest scripts/test_sync_weblate.py
"""

from __future__ import annotations

import argparse
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


@pytest.fixture(autouse=True)
def unstyled(monkeypatch: pytest.MonkeyPatch):
    """Pin the styling flags off for every test that does not say otherwise.

    They are computed once at import from the ambient environment, so without this a machine or a runner
    that exports FORCE_COLOR turns a sixth of this file red for a reason that has nothing to do with the
    code -- every assertion on a rendered string compares against the plain form. Pinning them also makes
    the styled branch reachable deliberately, by a test that sets them, rather than by accident.
    """
    monkeypatch.setattr(sync_weblate, "STYLED", False)
    monkeypatch.setattr(sync_weblate, "STYLED_ERRORS", False)


def state(**overrides) -> sync_weblate.ComponentState:
    """A component state with everything benign, so each test states only what it is about."""
    defaults = dict(
        slug="neoipc-glossary",
        forge_repo="NeoIPC/Surveillance-Toolkit",
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

    def test_work_queued_behind_an_open_request_is_visible(self):
        # It was not: the row reported the request's state and said nothing about translations waiting,
        # so the thing that supersedes the branch the moment it is committed was invisible.
        phrase, _ = state(branch_tip="a" * 40, open_pull_request=133, review="APPROVED",
                          checks=sync_weblate.CHECKS_GREEN, needs_commit=True).verdict
        assert "translations waiting" in phrase

    def test_an_open_request_with_nothing_queued_says_nothing_extra(self):
        phrase, _ = state(branch_tip="a" * 40, open_pull_request=133, review="APPROVED",
                          checks=sync_weblate.CHECKS_GREEN).verdict
        assert "translations waiting" not in phrase

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


class TestTrailerFiltering:
    """A tool is not a co-author, and the platform's add-on cannot be told to stop saying it is."""

    DOMAINS = {"weblate.org"}
    ADDRESSES = {"noreply@anthropic.com", "noreply@github.com"}

    def strip(self, body: str) -> str:
        return sync_weblate.strip_non_human_trailers(body, self.DOMAINS, self.ADDRESSES)

    def test_a_person_is_kept(self):
        assert "Brar" in self.strip("Co-authored-by: Brar Piening <brar@gmx.de>")

    def test_the_service_account_is_dropped_by_its_domain(self):
        # The observed case: append_trailers adds this to every squashed commit.
        assert self.strip("Co-authored-by: Hosted Weblate <hosted@weblate.org>") == ""

    def test_an_unseen_address_at_an_excluded_domain_is_dropped(self):
        # The domain rule exists so a newly installed add-on cannot slip through by being unlisted.
        assert self.strip("Co-authored-by: Some New Add-on <noreply-addon-new@weblate.org>") == ""

    def test_an_ai_trailer_is_dropped_by_its_address(self):
        assert self.strip("Co-authored-by: Claude <noreply@anthropic.com>") == ""

    def test_matching_is_on_the_address_not_the_display_name(self):
        # The same address appears under several names in this project's history, so a name-keyed
        # filter would drop one spelling and silently credit the other.
        assert self.strip("Co-authored-by: Anonymous <noreply@weblate.org>") == ""
        assert self.strip("Co-authored-by: Weblate (bot) <noreply@weblate.org>") == ""

    def test_a_human_at_a_lookalike_domain_is_kept(self):
        # weblate.org is excluded; a person's own address that merely contains it is not.
        assert "person" in self.strip("Co-authored-by: A Person <person@notweblate.org.example>")

    def test_non_trailer_lines_survive_untouched(self):
        body = "Translate-URL: https://hosted.weblate.org/projects/neoipc/\nTranslation: NeoIPC"
        assert self.strip(body) == body

    def test_a_mixed_block_keeps_only_the_people(self):
        body = ("Translation: NeoIPC/NeoIPC-Glossary\n"
                "\n"
                "Co-authored-by: Hosted Weblate <hosted@weblate.org>\n"
                "Co-authored-by: Brar Piening <brar@gmx.de>")
        result = self.strip(body)
        assert "hosted@weblate.org" not in result
        assert "brar@gmx.de" in result
        assert "Translation: NeoIPC/NeoIPC-Glossary" in result

    def test_a_trailing_blank_run_left_by_a_removal_is_collapsed(self):
        body = "Translation: NeoIPC\n\nCo-authored-by: Hosted Weblate <hosted@weblate.org>\n"
        assert self.strip(body) == "Translation: NeoIPC"


class TestNonHumanIdentitiesParse:
    """Where the sets above actually come from, read from the committed list rather than restated.

    The tests above supply their own sets, so they establish what the filter does with a correct one and
    nothing about whether the real one arrives correct. That is the half that fails open: every step of
    the parse answers a shape it does not recognize with an empty collection, and empty sets are not an
    error -- they are a filter that keeps every trailer, so a tool lands on main as a co-author and the
    only signal is the absence of one.

    The list has a second reader in PowerShell with its own tests, which is why this exists: the point of
    keeping it as shared data is that two languages read one file, and a test on either side alone
    guards its own parser against a file that is still fine rather than the pair.
    """

    LIST = Path(sync_weblate.__file__).parent.parent / "po" / "non-human-identities.yaml"

    @pytest.fixture
    def committed(self, monkeypatch: pytest.MonkeyPatch) -> tuple[set[str], set[str]]:
        """The real file's bytes through the real parse, with only the network stubbed out."""
        text = self.LIST.read_text(encoding="utf-8")
        monkeypatch.setattr(sync_weblate, "run", lambda *a, **k: text)
        return sync_weblate.non_human_identities()

    def test_the_committed_list_yields_both_sets_non_empty(self, committed):
        domains, addresses = committed
        assert domains, "no excluded domains parsed — every trailer would be kept"
        assert addresses, "no excluded addresses parsed — every trailer would be kept"

    def test_the_domain_rule_survives_the_parse(self, committed):
        # One entry, and it is what covers every add-on identity the platform has not minted yet.
        domains, _ = committed
        assert "weblate.org" in domains

    @pytest.mark.parametrize("address", ["noreply@anthropic.com", "noreply@github.com"])
    def test_the_addresses_no_domain_rule_covers_survive_the_parse(self, committed, address):
        # These two are the ones the address list is load-bearing for: nothing else excludes them, so
        # they go red if the entries stop being mappings with an `address` key — the shape change that
        # would otherwise empty the set in silence.
        _, addresses = committed
        assert address in addresses

    def test_the_committed_list_strips_the_trailer_the_squash_exists_to_remove(self, committed):
        # End to end on the real data: parse, then filter, on the one trailer append_trailers adds to
        # every squashed commit.
        domains, addresses = committed
        body = ("Co-authored-by: Hosted Weblate <hosted@weblate.org>\n"
                "Co-authored-by: Brar Piening <brar@gmx.de>")
        result = sync_weblate.strip_non_human_trailers(body, domains, addresses)
        assert "hosted@weblate.org" not in result
        assert "brar@gmx.de" in result

    def test_it_is_read_from_the_default_branch_rather_than_the_checkout(
            self, monkeypatch: pytest.MonkeyPatch):
        # Reading over the network is deliberate -- it works from any directory and reads what is on
        # main -- so a renamed path fails here rather than by returning a checkout's stale copy.
        asked = []
        monkeypatch.setattr(sync_weblate, "run",
                            lambda command, **k: (asked.append(command), "excluded_domains: [x]")[1])
        sync_weblate.non_human_identities()
        assert sync_weblate.NON_HUMAN_IDENTITIES in " ".join(asked[0])

    def test_a_shape_it_does_not_recognize_yields_nothing_rather_than_raising(
            self, monkeypatch: pytest.MonkeyPatch):
        # Pinning the fail-open behaviour rather than endorsing it: the parse cannot distinguish "no
        # tools listed" from "the file changed shape", which is exactly why the assertions above are
        # made against the committed file instead of a fixture.
        monkeypatch.setattr(sync_weblate, "run",
                            lambda *a, **k: "excluded_addresses:\n  - noreply@weblate.org\n")
        assert sync_weblate.non_human_identities() == (set(), set())


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

    def test_styling_is_off_when_output_is_not_a_terminal(self, monkeypatch: pytest.MonkeyPatch):
        # Asserted against a stream this test supplies rather than against the module-level flag, which
        # is whatever the machine running the suite happened to make it.
        class Redirected:
            encoding = "utf-8"

            @staticmethod
            def isatty() -> bool:
                return False

        monkeypatch.delenv("FORCE_COLOR", raising=False)
        monkeypatch.delenv("NO_COLOR", raising=False)
        assert not sync_weblate._terminal_supports_styling(Redirected())

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

    def test_a_reference_follows_the_stream_it_is_bound_for(self, monkeypatch: pytest.MonkeyPatch):
        # Redirecting one stream and not the other is ordinary (`2> errors.txt`), so a warning bound for
        # stderr must not inherit stdout's answer -- the escape would land in the file.
        monkeypatch.setattr(sync_weblate, "STYLED", True)
        monkeypatch.setattr(sync_weblate, "STYLED_ERRORS", False)
        assert sync_weblate.pull_request_reference(133, "NeoIPC/x", on_stderr=True) == "#133"
        assert sync_weblate.pull_request_reference(133, "NeoIPC/x").startswith(
            "\033]8;;https://github.com/NeoIPC/x/pull/133")

    def test_a_reference_degrades_to_the_number_rather_than_the_url(self):
        # The number is what identifies the pull request in conversation; a bare URL would read as
        # noise in a log and lose the thing the operator actually quotes.
        assert sync_weblate.pull_request_reference(133, "NeoIPC/x") == "#133"

    def test_check_state_falls_back_to_words_rather_than_an_icon(self):
        # The icon carries the meaning when it can be seen; without it the words must, because a row
        # that said nothing at all would be worse than a long one.
        assert sync_weblate.render_checks(sync_weblate.CHECKS_GREEN) == "checks green"
        assert sync_weblate.render_checks(sync_weblate.CHECKS_FAILED) == "CHECKS FAILED"
        assert sync_weblate.render_checks(sync_weblate.CHECKS_RUNNING) == "checks running"
        assert sync_weblate.render_checks(sync_weblate.CHECKS_NONE) == "no checks"

    def test_an_unknown_check_state_still_renders_something(self):
        assert sync_weblate.render_checks("surprising") == "surprising"

    def test_the_styled_branch_wraps_rather_than_replaces(self, monkeypatch: pytest.MonkeyPatch):
        # The other half of every assertion here, and the half that can corrupt a stream: the plain form
        # has to survive inside the escapes, or degrading and not degrading disagree about the text.
        monkeypatch.setattr(sync_weblate, "STYLED", True)
        assert sync_weblate.styled("SUPERSEDED", "31") == "\033[31mSUPERSEDED\033[0m"
        assert sync_weblate.render_checks(sync_weblate.CHECKS_FAILED) == "\033[31m✗\033[0m"
        verdict, problem = state(merge_failure="conflict").verdict
        assert "MERGE FAILURE: conflict" in verdict and verdict.startswith("\033[31m")
        assert problem

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
    MUTATING_ARGUMENTS = ("DELETE", "'create'", "'merge'")

    @staticmethod
    def definitions() -> dict[str, ast.FunctionDef]:
        """Every function and method in the module, by name.

        Methods have to be in here. `command_status` reaches its verdict through ComponentState, so a
        table built from the module's top-level definitions alone leaves every method of that class
        outside the analysis -- and a mutating call added to `verdict`, which runs for every row the
        command prints, would be invisible to the guard below.
        """
        source = Path(sync_weblate.__file__).read_text(encoding="utf-8")
        found: dict[str, ast.FunctionDef] = {}
        for node in ast.walk(ast.parse(source)):
            if isinstance(node, ast.FunctionDef):
                # Flattening the namespaces is only safe while the names are unique; a collision would
                # silently drop one of the two out of the analysis.
                assert node.name not in found, f"two definitions are named {node.name}"
                found[node.name] = node
        return found

    @staticmethod
    def reachable(name: str, functions: dict, seen: set[str] | None = None) -> set[str]:
        seen = set() if seen is None else seen
        if name in seen or name not in functions:
            return seen
        seen.add(name)
        for node in ast.walk(functions[name]):
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
                TestStatusIsReadOnly.reachable(node.func.id, functions, seen)
            # A property is reached by attribute access, not by a call, so following calls alone stops
            # at `state.verdict` -- the one method `status` runs on every row.
            elif isinstance(node, ast.Attribute):
                TestStatusIsReadOnly.reachable(node.attr, functions, seen)
        return seen

    @staticmethod
    def bound_literals(function: ast.FunctionDef) -> dict[str, str]:
        """Every local assigned in this function, dumped, so an argument named here can still be read.

        Without this the detector sees only a literal argument, and the one call it most needs to catch
        is written the other way: the merge assembles its command into a variable and then passes the
        name, which dumps to `Name(id='command')` and matches nothing.
        """
        bound: dict[str, str] = {}
        for node in ast.walk(function):
            if isinstance(node, ast.Assign):
                for target in node.targets:
                    if isinstance(target, ast.Name):
                        bound[target.id] = ast.dump(node.value)
        return bound

    @classmethod
    def mutations(cls, root: str) -> tuple[list[str], list[str]]:
        """What the call graph under `root` mutates, by each of the two routes, reported separately.

        Separately because the two arms fail independently: one detects a Weblate client call, the other
        a forge command, and a test that merged them would pass on either alone.
        """
        functions = cls.definitions()
        client_calls, commands = [], []
        for name in cls.reachable(root, functions):
            arguments = cls.bound_literals(functions[name])
            for node in ast.walk(functions[name]):
                if not isinstance(node, ast.Call):
                    continue
                if getattr(node.func, "attr", None) in cls.MUTATORS:
                    client_calls.append(f"{name}: .{node.func.attr}()")
                if isinstance(node.func, ast.Name) and node.func.id == "run" and node.args:
                    dumped = " ".join(
                        arguments.get(argument.id, "") if isinstance(argument, ast.Name)
                        else ast.dump(argument)
                        for argument in node.args)
                    if any(word in dumped for word in cls.MUTATING_ARGUMENTS):
                        commands.append(f"{name}: run(...) mutates")
        return client_calls, commands

    def test_status_reaches_no_mutating_call(self):
        client_calls, commands = self.mutations("command_status")
        assert not client_calls + commands, f"status can mutate via: {client_calls + commands}"

    def test_the_check_would_notice_a_mutating_client_call(self):
        # Guards the guard: run it against drain, which certainly mutates, so a broken detector cannot
        # pass the test above by finding nothing anywhere.
        client_calls, _ = self.mutations("command_drain")
        assert client_calls, "the detector found no client mutation in drain, so it cannot vouch for status"

    def test_the_check_would_notice_a_mutating_command(self):
        # The other arm needs its own guard for the same reason, and more sharply: it can only see what
        # a call's arguments dump to, so it is the half that silently stops matching.
        _, commands = self.mutations("command_drain")
        assert commands, "the detector found no mutating command in drain, so it cannot vouch for status"

    def test_the_verdict_is_inside_the_analysis(self):
        # The reachable set is what the guard is worth; a traversal that stops before ComponentState
        # would still report status as clean, having examined none of what it prints.
        assert "verdict" in self.reachable("command_status", self.definitions())


class TestForgeJsonReads:
    """A parse that only runs on a rare path fails where nobody is positioned to recover from it."""

    def test_no_json_read_narrows_its_output_with_jq(self):
        # The client prints a selected string bare, so `--jq .commit.message` returns text that
        # json.loads rejects. It reached the merge step -- past the checks, past the approval -- before
        # anything ran it, which is why this is asserted structurally rather than left to a live run.
        source = Path(sync_weblate.__file__).read_text(encoding="utf-8")
        offenders = [
            ast.unparse(node)
            for node in ast.walk(ast.parse(source))
            if isinstance(node, ast.Call)
            and isinstance(node.func, ast.Name) and node.func.id == "gh_json"
            and "--jq" in ast.dump(node)
        ]
        assert not offenders, f"gh_json cannot parse a --jq selection: {offenders}"

    def test_the_check_would_notice_one(self):
        # Guards the guard: the detector must be capable of finding the pattern it vouches for.
        found = [
            node for node in ast.walk(ast.parse('gh_json(["api", "x", "--jq", ".a"])'))
            if isinstance(node, ast.Call)
            and isinstance(node.func, ast.Name) and node.func.id == "gh_json"
            and "--jq" in ast.dump(node)
        ]
        assert found, "the detector cannot see a --jq selection, so it vouches for nothing"


class TestPriorityLabel:
    """The component scale is inverted relative to the per-string one, so the number reads backwards."""

    @pytest.mark.parametrize(("value", "label"), [
        (60, "very high"), (80, "high"), (100, "medium"), (120, "low"), (140, "very low")])
    def test_known_priorities_are_named(self, value, label):
        assert state(priority=value).priority_label == label

    def test_an_unknown_priority_falls_back_to_its_number(self):
        assert state(priority=42).priority_label == "42"


class TestApprovalGate:
    """What the merge waits for, and what it refuses to spend without saying so."""

    @pytest.mark.parametrize(("review", "outcome"), [
        ("APPROVED", sync_weblate.REVIEW_SETTLED),
        ("", sync_weblate.REVIEW_SETTLED),
        ("REVIEW_REQUIRED", sync_weblate.REVIEW_WAITING),
        ("CHANGES_REQUESTED", sync_weblate.REVIEW_REFUSED),
    ])
    def test_a_review_decision_is_classified(self, review, outcome):
        assert sync_weblate.approval_outcome(review) == outcome

    def test_an_unknown_decision_waits_rather_than_merging(self):
        # The safe direction: a decision this does not recognize might be a reviewer saying no, and
        # waiting costs a timeout while guessing "settled" merges past them.
        assert sync_weblate.approval_outcome("SOMETHING_NEW") == sync_weblate.REVIEW_WAITING

    def test_no_review_requirement_does_not_hang_the_drain(self):
        # A repository without the protection returns a null decision, which arrives here as "". Reading
        # it as outstanding would wait out the full timeout on every such drain and merge nothing.
        assert sync_weblate.approval_outcome("") == sync_weblate.REVIEW_SETTLED

    def test_replacing_an_approved_superseded_branch_is_flagged(self):
        assert sync_weblate.approval_would_be_discarded(
            state(branch_tip="b" * 40, open_pull_request=133, review="APPROVED"))

    def test_an_approved_branch_that_is_current_loses_nothing(self):
        assert not sync_weblate.approval_would_be_discarded(
            state(branch_tip="a" * 40, open_pull_request=133, review="APPROVED"))

    def test_a_superseded_branch_nobody_approved_loses_nothing(self):
        # Recreating this is routine; warning about it would train the operator to ignore the warning
        # that matters.
        assert not sync_weblate.approval_would_be_discarded(
            state(branch_tip="b" * 40, open_pull_request=133, review="REVIEW_REQUIRED"))


class TestBackingRepository:
    """Which repository backs a component is Weblate's to say, and getting it wrong fails by omission."""

    @pytest.mark.parametrize("url", [
        "https://github.com/NeoIPC/NeoIPC-App.git",
        "https://github.com/NeoIPC/NeoIPC-App",
        "https://github.com/NeoIPC/NeoIPC-App/",
        "git@github.com:NeoIPC/NeoIPC-App.git",
    ])
    def test_the_repository_is_read_from_the_component(self, url):
        assert sync_weblate.forge_repo({"slug": "neoipc-app", "repo": url}) == "NeoIPC/NeoIPC-App"

    def test_a_component_this_cannot_drive_is_refused_by_name(self):
        # The Weblate-local terminology store has no git backing. Refusing it loudly beats returning
        # something plausible, which is how the previous constant behaved: it silently matched nothing.
        with pytest.raises(sync_weblate.DrainError) as refusal:
            sync_weblate.forge_repo({"slug": "glossary", "repo": "local:"})
        assert "glossary" in str(refusal.value)

    def test_a_second_repository_is_not_filtered_out(self):
        # The regression this replaces: a constant naming one repository excluded every component backed
        # by another -- not with an error but by absence, so the app catalogue was missing from every
        # listing of what needed draining, and nothing anywhere said so.
        records = [
            {"slug": "neoipc-reports", "repo": "https://github.com/NeoIPC/Surveillance-Toolkit.git"},
            {"slug": "neoipc-app", "repo": "https://github.com/NeoIPC/NeoIPC-App.git"},
        ]
        assert {sync_weblate.forge_repo(r) for r in records} == {
            "NeoIPC/Surveillance-Toolkit", "NeoIPC/NeoIPC-App"}


class TestComponentLookup:
    """A slug that resolves to nothing is indistinguishable from a typo unless the refusal says so."""

    RECORDS = [{"slug": "neoipc-glossary"}, {"slug": "neoipc-reports"}]

    def test_a_known_slug_yields_its_record(self):
        assert sync_weblate.find_component(self.RECORDS, "neoipc-reports") is self.RECORDS[1]

    def test_an_unknown_slug_names_the_ones_that_exist(self):
        with pytest.raises(sync_weblate.DrainError) as refusal:
            sync_weblate.find_component(self.RECORDS, "neoipc-report")
        assert "neoipc-glossary, neoipc-reports" in str(refusal.value)


class StubClient:
    """Just enough of the Weblate client to list components: a project, and pages keyed by URL."""

    def __init__(self, pages: dict[str, dict]):
        self.pages = pages
        self.requested: list[str] = []

    @staticmethod
    def get_project(slug: str) -> dict:
        return {"slug": slug}

    def get(self, url: str) -> dict:
        self.requested.append(url)
        return self.pages[url]


class TestComponentDiscovery:
    """What the tool can see. Every failure here is an omission, and an omission is silent by nature.

    A component missing from this list is never drained and nothing anywhere reports it -- which is how
    the app catalogue stayed invisible while a hard-coded repository name decided the set.
    """

    FIRST = "projects/neoipc/components/"
    SECOND = "projects/neoipc/components/?page=2"

    def component(self, slug: str, *, priority: int = 100, repo: str | None = None) -> dict:
        default = "https://github.com/NeoIPC/Surveillance-Toolkit.git"
        return {"slug": slug, "priority": priority, "repo": default if repo is None else repo}

    def test_every_page_is_read(self):
        # Reading only the first page stops at the page size, and Weblate's default is well inside the
        # number of components this project will hold.
        client = StubClient({
            self.FIRST: {"results": [self.component("neoipc-reports")], "next": self.SECOND},
            self.SECOND: {"results": [self.component("neoipc-app")], "next": None},
        })
        found = [r["slug"] for r in sync_weblate.repository_components(client)]
        assert found == ["neoipc-app", "neoipc-reports"]
        assert client.requested == [self.FIRST, self.SECOND]

    def test_a_component_with_no_git_backing_is_left_out(self):
        # The Weblate-local terminology store. It has nothing to drain, and forge_repo would refuse it.
        client = StubClient({self.FIRST: {"results": [
            self.component("neoipc-reports"),
            self.component("glossary", repo="local:"),
        ], "next": None}})
        assert [r["slug"] for r in sync_weblate.repository_components(client)] == ["neoipc-reports"]

    def test_the_most_urgent_component_is_listed_first(self):
        # The direction is the trap: Weblate's COMPONENT priority runs 60 = very high to 140 = very low,
        # opposite to its per-string one, so sorting descending puts the most urgent last and reads as an
        # ordering rather than as a defect.
        client = StubClient({self.FIRST: {"results": [
            self.component("neoipc-infectious-agents", priority=140),
            self.component("neoipc-glossary", priority=60),
            self.component("neoipc-reports", priority=80),
        ], "next": None}})
        assert [r["slug"] for r in sync_weblate.repository_components(client)] == [
            "neoipc-glossary", "neoipc-reports", "neoipc-infectious-agents"]


class TestWeblateTip:
    """The commit every supersession judgement is made against, and where it is read from."""

    EXPORT = "https://hosted.weblate.org/git/neoipc/nomenclature/neoipc-glossary/"

    def test_the_export_url_is_taken_from_the_component(self, monkeypatch: pytest.MonkeyPatch):
        # Composing it from the project and the slug is a second copy of something Weblate already
        # states, and it is wrong for any component filed under a category -- the export path carries the
        # category slug too, so the composed URL resolves to nothing and every command dies on it.
        asked = []

        def fake_run(command, **_kwargs):
            asked.append(command)
            return f"{'a' * 40}\trefs/heads/main"

        monkeypatch.setattr(sync_weblate, "run", fake_run)
        record = {"slug": "neoipc-glossary", "git_export": self.EXPORT}
        assert sync_weblate.weblate_tip(record) == "a" * 40
        assert self.EXPORT in asked[0]

    def test_a_component_with_no_export_is_refused_by_name(self, monkeypatch: pytest.MonkeyPatch):
        monkeypatch.setattr(sync_weblate, "run", lambda *a, **k: "")
        with pytest.raises(sync_weblate.DrainError) as refusal:
            sync_weblate.weblate_tip({"slug": "neoipc-glossary"})
        assert "neoipc-glossary" in str(refusal.value)

    def test_an_export_without_main_is_refused_rather_than_read_as_absent(
            self, monkeypatch: pytest.MonkeyPatch):
        # Returning nothing here would make every pushed branch compare unequal and so read as
        # superseded -- a recommendation to delete and recreate every branch over a network blip.
        monkeypatch.setattr(sync_weblate, "run", lambda *a, **k: "")
        with pytest.raises(sync_weblate.DrainError):
            sync_weblate.weblate_tip({"slug": "neoipc-glossary", "git_export": self.EXPORT})


class TestBranchTip:
    """Whose commit the branch is compared against. Attributing another branch's tip inverts supersession."""

    # Distinct commits per branch, so an assertion can tell which one was picked. Deriving them from the
    # names would collide here, both branches starting with the same letter -- and a colliding fixture
    # makes the test below pass whichever ref the code returns, which is the one thing it must not do.
    SHAS = {"weblate-glossary": "a" * 40, "weblate-glossary-old": "b" * 40}

    def refs(self, *names: str) -> list[dict]:
        return [{"ref": f"refs/heads/{n}", "object": {"sha": self.SHAS[n]}} for n in names]

    def test_an_absent_branch_is_absence_rather_than_an_error(self, monkeypatch: pytest.MonkeyPatch):
        monkeypatch.setattr(sync_weblate, "gh_json", lambda command: [])
        assert sync_weblate.branch_tip("weblate-glossary", "NeoIPC/x") is None

    def test_a_prefix_sibling_does_not_supply_the_tip(self, monkeypatch: pytest.MonkeyPatch):
        # matching-refs is a prefix match, so a leftover weblate-glossary-old comes back alongside the
        # real branch. Taking the first would compare the wrong commit against Weblate's -- reading a
        # current branch as superseded (the drain then deletes it, discarding an approved pull request)
        # or a superseded one as current (it merges work Weblate no longer holds).
        monkeypatch.setattr(sync_weblate, "gh_json",
                            lambda command: self.refs("weblate-glossary-old", "weblate-glossary"))
        assert sync_weblate.branch_tip("weblate-glossary", "NeoIPC/x") == self.SHAS["weblate-glossary"]

    def test_the_prefix_sibling_alone_reads_as_absent(self, monkeypatch: pytest.MonkeyPatch):
        monkeypatch.setattr(sync_weblate, "gh_json", lambda command: self.refs("weblate-glossary-old"))
        assert sync_weblate.branch_tip("weblate-glossary", "NeoIPC/x") is None


class TestMergeGate:
    """The aggregation the merge is actually gated on, as opposed to the one the status row displays."""

    def rollup(self, monkeypatch: pytest.MonkeyPatch, *nodes: dict) -> None:
        monkeypatch.setattr(sync_weblate, "gh_json",
                            lambda command: {"statusCheckRollup": list(nodes)})

    def check(self, name: str, conclusion: str) -> dict:
        return {"name": name, "status": "COMPLETED", "conclusion": conclusion}

    def test_green_checks_settle(self, monkeypatch: pytest.MonkeyPatch):
        self.rollup(monkeypatch, self.check("build", "SUCCESS"), self.check("lint", "SKIPPED"))
        sync_weblate.wait_for_checks("weblate-glossary", "NeoIPC/x")

    def test_a_failed_check_is_named(self, monkeypatch: pytest.MonkeyPatch):
        self.rollup(monkeypatch, self.check("build", "SUCCESS"), self.check("text-hygiene", "FAILURE"))
        with pytest.raises(sync_weblate.DrainError) as refusal:
            sync_weblate.wait_for_checks("weblate-glossary", "NeoIPC/x")
        assert "text-hygiene" in str(refusal.value)

    def test_an_unrecognized_conclusion_blocks_the_merge(self, monkeypatch: pytest.MonkeyPatch):
        # The direction that matters. This is the gate the merge runs on, so a conclusion the forge adds
        # later -- or one this classifier fell back to -- has to read as not-green. Listing the bad ones
        # instead means anything unanticipated is merged, silently and with an approval already spent.
        self.rollup(monkeypatch, self.check("build", "SOMETHING_NEW"))
        with pytest.raises(sync_weblate.DrainError):
            sync_weblate.wait_for_checks("weblate-glossary", "NeoIPC/x")

    def test_an_empty_rollup_is_not_a_pass(self, monkeypatch: pytest.MonkeyPatch):
        # Tolerated while checks may still appear, refused once they cannot: merging on an empty rollup
        # waives the gate entirely, and does it without saying anything.
        monkeypatch.setattr(sync_weblate, "CHECK_TIMEOUT_SECONDS", -1)
        self.rollup(monkeypatch)
        with pytest.raises(sync_weblate.DrainError) as refusal:
            sync_weblate.wait_for_checks("weblate-glossary", "NeoIPC/x")
        assert "ungated" in str(refusal.value)

    def test_checks_still_running_at_the_deadline_are_named(self, monkeypatch: pytest.MonkeyPatch):
        monkeypatch.setattr(sync_weblate, "CHECK_TIMEOUT_SECONDS", -1)
        self.rollup(monkeypatch, {"name": "build", "status": "IN_PROGRESS", "conclusion": None})
        with pytest.raises(sync_weblate.DrainError) as refusal:
            sync_weblate.wait_for_checks("weblate-glossary", "NeoIPC/x")
        assert "build" in str(refusal.value)


class TestSingleCommitRefusal:
    """One commit is what makes a squash patch-identical, and it is a remote setting rather than a law."""

    class Reached(Exception):
        """Raised past the guard, so a test can assert the guard let something through."""

    def merging(self, monkeypatch: pytest.MonkeyPatch, ahead: int) -> None:
        def fake_run(command, **_kwargs):
            if "compare/main...weblate-glossary" in " ".join(command):
                return str(ahead)
            raise TestSingleCommitRefusal.Reached(" ".join(command))

        monkeypatch.setattr(sync_weblate, "run", fake_run)
        sync_weblate.merge_drain_pull_request(
            state(branch_tip="a" * 40, open_pull_request=133), admin=False)

    @pytest.mark.parametrize("ahead", [0, 2, 7])
    def test_anything_but_one_commit_is_refused(self, monkeypatch: pytest.MonkeyPatch, ahead):
        # Both directions are wrong and neither is obviously so. More than one fuses commits into a patch
        # matching none of them, and the component replays work it can no longer prove had landed --
        # conflicting on every component at once, which is what happened. Zero means the branch is already
        # contained in main, so there is nothing to merge and --match-head-commit is guarding nothing.
        with pytest.raises(sync_weblate.DrainError) as refusal:
            self.merging(monkeypatch, ahead)
        assert str(ahead) in str(refusal.value)

    def test_a_single_commit_is_let_through(self, monkeypatch: pytest.MonkeyPatch):
        # Guards the guard from the other side: without this, inverting the comparison would refuse every
        # drain there is and no test above would notice.
        with pytest.raises(TestSingleCommitRefusal.Reached) as reached:
            self.merging(monkeypatch, 1)
        assert "commits/" in str(reached.value)


class TestNoPushBranch:
    """Weblate pushing at the branch it translates -- main -- which every other guard here is blind to."""

    def test_the_status_row_calls_it_a_problem(self):
        # Every branch-derived test collapses to something benign: no branch exists, so nothing is
        # superseded or stranded and no pull request is awaited. Without its own case the row reads
        # "idle" and the command exits zero, having established nothing about the component.
        verdict, problem = state(push_branch="").verdict
        assert problem
        assert "NO PUSH BRANCH" in verdict

    def test_pending_work_does_not_mask_it(self):
        verdict, problem = state(push_branch="", needs_push=True).verdict
        assert problem
        assert "NO PUSH BRANCH" in verdict

    def test_the_drain_refuses_before_touching_anything(self, monkeypatch: pytest.MonkeyPatch):
        record = {"slug": "neoipc-glossary", "priority": 60, "push_branch": "",
                  "repo": "https://github.com/NeoIPC/Surveillance-Toolkit.git"}
        monkeypatch.setattr(sync_weblate, "repository_components", lambda client: [record])
        monkeypatch.setattr(sync_weblate, "operable", lambda client, r: object())
        monkeypatch.setattr(sync_weblate, "read_state", lambda client, r: state(push_branch=""))
        monkeypatch.setattr(sync_weblate, "forge_identity", lambda: "someone")
        arguments = argparse.Namespace(component="neoipc-glossary", no_lock=True, admin=False)
        with pytest.raises(sync_weblate.DrainError) as refusal:
            sync_weblate.command_drain(None, arguments)
        assert "no push branch" in str(refusal.value)


class TestArgumentSurface:
    """A mistyped invocation gets no diagnostic but this one, so it has to name the right thing."""

    def parse(self, *argv):
        return sync_weblate.build_parser().parse_known_args(list(argv))

    def test_status_reports_on_one_component_when_given_a_slug(self):
        args, extra = self.parse("status", "neoipc-reports")
        assert (args.component, extra) == ("neoipc-reports", [])

    def test_status_reports_on_every_component_when_given_none(self):
        args, extra = self.parse("status")
        assert (args.component, extra) == (None, [])

    @pytest.mark.parametrize("argv", [["-?"], ["status", "-?"], ["drain", "-?"],
                                      ["lock", "-?"], ["unlock", "-?"], ["repair", "-?"]])
    def test_the_powershell_help_flag_works_at_every_level(self, argv, capsys):
        # argparse installs -h/--help and cannot be given a third alias, so every parser has to opt out
        # of that pair and put all three back -- which a subcommand added later can silently miss.
        with pytest.raises(SystemExit) as exit:
            sync_weblate.build_parser().parse_known_args(argv)
        assert exit.value.code == 0
        assert "show this help message" in capsys.readouterr().out

    @pytest.mark.parametrize("name", ["status", "drain", "lock", "unlock", "repair"])
    def test_every_subcommand_records_itself_so_a_stray_argument_names_it(self, name):
        # argparse hands a leftover to the TOP-LEVEL parser, whose usage line lists only the subcommand
        # names -- so the error reads as though the subcommand were the unrecognized part. main reports
        # it against this parser instead, which a sixth subcommand added with a bare add_parser would
        # silently opt out of.
        args, _ = self.parse(name, "neoipc-glossary")
        assert args.subcommand_parser.prog.endswith(f" {name}")
