# GitHub Copilot — Surveillance-Toolkit Instructions

This file documents the Surveillance-Toolkit repository. If this repository is checked out as a submodule of the `neoipc-workspace`, the workspace-level `.github/copilot-instructions.md` adds additional workspace-specific guardrails (file boundary, cross-repo change order) on top of the guardrails below.

---

## Guardrails

The rules below without a *(repo-specific)* tag are the NeoIPC **universal** guardrails, localized to this repository's stack — language-specific examples are adapted to the languages actually used here (R, PowerShell, Quarto/R Markdown, AsciiDoc), and code-authoring rules with no referent in this repository are omitted. Rules tagged *(repo-specific)* or *(\<lang\>-specific)* apply only to the repositories that carry them. To add or change a universal guardrail, edit it here and add `<!-- SYNC: propagate to all repos -->` so it is propagated — and re-localized — across every repo when the workspace is next used.

- **Never** put personal names or other identifying information in source code (comments, strings, commit messages, etc.), except in copyright statements and file-header attribution lines (e.g. `Author:`, `@author`, `Copyright (c)` fields).
- **Never** read, write, or access files under `secrets/`, `data/`, or `.env`. This includes listing, globbing, searching, or interacting with these paths in any way — not just reading file contents. If the user provides a path under these directories, use it as-is without exploring the directory.
- **Never** push directly to `main` or `master` on this repository.
- **Never** make HTTP calls to the DHIS2 API or attempt to read JSON files returned from the DHIS2 API. These files contain sensitive surveillance data and are not needed for code-level tasks.
- **Never** put absolute local paths into files that get checked in. Use relative paths or generic placeholders. Local checkout paths are developer-specific and meaningless to others.
- Treat infection definitions in this repository as normative. When a conflict exists between code and definitions, **fix the code**, not the definitions.
- **Never** invent or paraphrase clinical definitions, thresholds, or measurement criteria. Always look up the normative text in `doc/protocol/` (or the relevant definition file) before writing or modifying footnotes, tooltips, or explanatory text that describes how a metric is defined or measured. If no protocol definition exists for the concept, flag it rather than guessing. *(repo-specific)*
- **Never** use `metadata/common/infectious-agents/NeoIPC-Pathogen-Concepts.csv` or `metadata/common/infectious-agents/NeoIPC-Pathogen-Synonyms.csv` as a reference when investigating infectious-agent taxonomy, synonyms, resistance categories, or any pathogen definition. These CSVs are legacy and unmaintained. The canonical source is `metadata/common/infectious-agents/NeoIPC-Infectious-Agents.yaml`. *(repo-specific)*
- **Always** name infectious-agent concepts in `NeoIPC-Infectious-Agents.yaml` from the appropriate **domain authority**: **LPSN** (<https://lpsn.dsmz.de>) for bacteria/prokaryotes, **MycoBank** (<https://www.mycobank.org>) for fungi, and **ICTV** (<https://ictv.global/taxonomy/>) for viruses; the **common-commensal** status follows the **NHSN Organism List** (<https://www.cdc.gov/nhsn/index.html>). For bacteria, prefer the **LoRN** name ("Recommended Names for bacteria of medical importance" — the LPSN entry whose `status` is "correct name, recommended for medical use"; its `record_lnk` joins a synonym to its correct-name record) as the primary name wherever one exists, keeping other valid names as synonyms. Each upstream source carries its own copyright — the directory's effective license is **CC BY-NC-ND 4.0** (plus CDC terms for NHSN-derived content); cite and attribute per this directory's `README.md` + `LICENSE.md`, and obtain upstream data only via each source's official download page / API (never scrape). *(repo-specific)*
- **Never** drop a pathogen name from `NeoIPC-Infectious-Agents.yaml` when it is renamed or reclassified — retain the prior name as a **synonym** of the current concept, **keeping its original `Id`** so values already entered against it still resolve, **and give the current/accepted name its own `Id` so it is selectable in DHIS2 too.** A reclassification therefore *adds* the new name as an option alongside the retained synonym — it never merely relabels the old one. A synonym's `Id` is the DHIS2 option-code already stored in collected surveillance data, so it must follow the name as it becomes a synonym — do **not** mint a new `Id` for the demoted name or retire the old one; the current name takes the next free `Id` (= `max+1`, gaps not refilled; a genuinely retired `Id` is never reassigned to a *different* organism). Whole-branch moves (mostly in viruses) can complicate this, but bacterial renames are normally clean per-name retentions. *(repo-specific)*
- **Never** introduce non-permissive dependencies (fonts, libraries, templates). All fonts must be SIL OFL or equivalent.
- **Always** write text files as **LF, UTF-8, no BOM** — and when adding or changing code that writes a file, pin those explicitly rather than trusting the runtime's default. This repository is where it matters most: `po/infectious_agents.de.po` is produced by po4a under WSL, merged by `msgmerge`, rewritten by Weblate, uploaded to by `update-glossary-po.py` using `polib`, and read by R and PowerShell — each on a different runtime with different defaults, all interleaving on one file. So the unit of agreement is **the file, not the tool**: one non-conforming writer contaminates a file that ten conforming writers handle correctly, and **a partial rewrite by a tool that disagrees is worse than a whole-file rewrite** — a uniformly-CRLF file is merely wrong and trivially fixed, a *mixed* file is corrupt and the corruption is invisible in every editor and most diffs. That is not hypothetical here: the German and Spanish infectious-agent catalogues reached Weblate as invalid gettext (`msgfmt -c`: `keyword "Copyright" unknown`), CRLF throughout except a few LF-only lines, because one writer produced CRLF and another rewrote only the header block in LF. **`.gitattributes` does not save you** — `text=auto` normalizes on *commit*, so a tool writing CRLF into the working tree still yields an LF blob and a clean `git status`; seven CRLF `po/glossary.*.po` sat here undetected exactly that way. That is why each writer is pinned individually, and why the check inspects the **working-tree** column of `git ls-files --eol` rather than the index column, which can essentially never report `crlf` for a text file. The two defaults that bite here, both verified rather than assumed: **R** — `writeLines(x, path)` opens *text mode* and emits CRLF on Windows, and `useBytes = TRUE` is an *encoding* switch with no newline semantics, so it does not help; open a binary connection (`file(path, "wb")`) and state `sep = "\n"`. `cat(file = …)` and `sink()` behave the same way. **PowerShell** — `Set-Content`/`Out-File` join items with `[Environment]::NewLine` and append one more, and `ConvertTo-Json` *already* indents with it, so even `[System.IO.File]::WriteAllText` of its output is CRLF; normalize at the write point. The exception is a **shipped artifact** rather than repository content: the generated data-dictionary CSVs carry a BOM deliberately, so they open correctly when a human double-clicks them in Excel, and their call site says so. Run `scripts/Test-TextFileHygiene.ps1` to check.
- **Always** keep `CLAUDE.md` and `.github/copilot-instructions.md` in sync within this repository. When you modify one, apply the same change to the other.
- **Never** repurpose or re-flag an existing provisioned fixture to satisfy a new requirement — **provision a new one** with the configuration needed. Seeded org units, test departments, fixture patients, demo records and Pester test fixtures exist to hold a *specific* configuration that some test depends on, and that dependency is usually on a property being **absent**: a seeded test department kept deliberately out of a test-unit group is what lets other tests exercise a department that survives test-unit filtering, so adding the flag would silently empty those tests rather than fail them. The absent-property dependency is invisible at the point of change and grep-resistant, which is what makes this dangerous. Adding a new fixture is cheap, additive, and cannot break anything that already passes.
- **Always** reach for **differential observation** before hypothesis-testing when reverse-engineering opaque third-party behaviour (a DHIS2 API response shape, a Quarto or Pandoc rendering difference, an R package's output). Capture the **complete, unfiltered** state before and after the change — full response body, full object dump, full rendered output — and **diff** them. Testing hypotheses one at a time only ever explores candidates already thought of, and the real answer is routinely something that would never have been proposed; a diff surfaces it whether or not it was suspected, and the diff is usually small enough that the candidates jump out. Corollary: never narrow the capture to the parts matching the current hypothesis — that is precisely how the answer gets discarded before it is ever seen.
- **Never** run two integration suites or metadata-driving scripts against the same DHIS2 instance at once — not in parallel shells, not "the previous one is probably nearly done". The instance is a single shared mutable substrate, so two runs defeat each other's isolation from outside it. The damage is quiet: cross-talk shows up as unrelated-looking failures in whichever run loses the race, sending the reader after a bug that does not exist, and a mid-run kill skips teardown and leaves orphaned records behind. Before launching a run, confirm any earlier one has actually **finished** — an output file whose last line is a section header means it is still going, not that it ended — and verify against the **process list** rather than the absence of a shell, since killing a wrapper reliably kills only the process you named while its children keep running detached. One run at a time, and wait for it.
- **Always** kill a long run the moment its **runner** is found to be broken — a swallowed or over-filtered output stream, a wrapper that buffers until exit, a monitor that cannot distinguish "working" from "hung". Fix the runner and relaunch; that costs a couple of minutes, whereas nursing a blind run costs the whole run's duration and leaves *both* the agent and the user unable to see a hang, a cascade of failures, or a stuck instance. Do **not** compensate with archaeology on the artifacts it happens to leave behind — that is a workaround for a defect that takes two minutes to fix, and it silently reduces what anyone can observe while the run proceeds. Concretely: PowerShell's `$x = Invoke-Thing` captures the function's **entire output stream**, so every `Write-Output` progress line disappears into `$x` and the log stays empty for the whole run — use `Write-Host` for progress and return only the value, and sanity-check that a new runner actually emits a line before walking away from it.
- **Always** resolve DHIS2 metadata objects **by `code`**, not by hard-coded UID (`filter=code:eq:<CODE>`). Two reasons, both first-order. **Legibility:** UIDs are opaque and unmemorable — that is precisely why the mnemonic codes exist. `NEOIPC_ADMISSION_TYPE` tells a reviewer what is being driven and can be grepped across the metadata CSVs, expression files and rule definitions; `AgBqfnnsUzd` tells them nothing, cannot be sanity-checked by eye, and makes a wrong-object bug invisible in review. **Portability:** codes are the stable contract the canonical metadata is authored against, while UIDs belong to whichever instance generated them — hard-coding one silently binds the code to a single instance and fails against production, a restore, or a re-generated package, with a "not found" that points at the wrong thing. Program stages historically carried no authored `code`, so they were resolved by name; NeoIPC now authors `NEOIPC_STG_<token>` codes on them (and semantic codes on the other configuration types — sections, org-unit levels, the tracked-entity type), so resolve program stages by code like every other type. The types that remain deliberately code-less — program rule actions and the placeholder validation rule — are matched by UID, never by a name/code lookup. Wherever a UID or name is used instead of a code, state that reason in a comment. Resolving costs one cached lookup and applies to data elements, tracked-entity attributes, programs, org units, option sets and rules alike.
- **Never** adopt a workaround that **reduces what the code actually verifies or does** without asking first and presenting the trade-off. This is distinct from the stuck-investigation rule below: the dangerous case is the workaround that **works**. It compiles, the tests pass, nothing looks wrong — and the loss of fidelity is invisible to everyone but its author. Before taking such a route, say plainly: what the faithful solution is, what the workaround stops verifying, and why the faithful one was not taken — then let the user decide. **And never write the resulting limitation up as if it were inherent to the third-party system**: documenting a self-imposed constraint as a discovered property of DHIS2, Quarto or R disguises a decision as a fact, and the next reader will design around it instead of fixing it. Applies equally to narrowing a test's scope, weakening an assertion, skipping a case, and hard-coding what should be derived.
- **Always** bring a stuck investigation to the user rather than iterating alone toward a workaround, once the diff above has not settled it or two attempts at the *same* problem have failed. Show what was actually observed (the diff, the failing output, the source snippet), state the current hypothesis, and ask — the user knows these systems and repeatedly spots the answer immediately. The failure mode this prevents is not "being slow": it is settling on a **weaker, stranger solution** than the obvious one and then writing a confident justification for it. A degraded assertion, an extra indirection, or a "no reliable way exists" conclusion are all signals to stop and ask. Pairs with the push-back guardrail below — both say the goal is the *right* answer, not an independently-reached one.
- **Always** push back when evidence contradicts the user's suggestion or implied assumption. Do not defer to the user's position when authoritative sources (AMA Manual of Style, protocol definitions, language specifications, etc.) say otherwise. Present the evidence clearly and let the user decide.
- **Always** consider both personal data protection (GDPR) and organizational/reputational concerns when making decisions about data shared between partners, published in reports, or exposed through APIs. Small cell counts in shared reports can expose which departments had specific rare pathogens or resistance patterns.
- **Always** treat accessibility and long-term archivability of generated user-visible or publicly published documents as explicit, first-class goals of the NeoIPC Surveillance Toolkit — not optional polish. Wherever a NeoIPC tool produces a document a person reads or that is published (reports, certificates, web UIs), enable and maintain **both** — **to the extent the toolchain can genuinely achieve them**: accessibility conformance (WCAG via `axe` on HTML, tagged PDF with alt text on every figure and decorative images marked as artifacts, accessible web UIs) and long-term archival compliance (PDF/A). **Never declare a conformance the output does not actually have.** A standard asserted in metadata but not met is worse than claiming nothing, because every downstream consumer trusts the assertion — e.g. declaring PDF/UA under a document class that cannot emit tagged structure yields a file that says it is accessible while every heading is ordinary paragraph text. When a property is currently unreachable, say so where the setting lives, record what would unblock it, and declare only what holds. When adding or changing such output, keep the properties that do work working; prefer formats and settings that preserve them, and treat a regression in tagging, alt text or PDF/A conformance as a defect.
- **Never** use deprecated or outdated APIs. Before introducing a function from a third-party package or a base library, verify it is current. When a replacement exists, use the replacement. When unsure, check the package's `NEWS.md` / release notes rather than assuming.
- **Never** use the `.data$` pronoun in tidyselect contexts (`select()`, `rename()`, `relocate()`, `across(.cols=)`, `pivot_wider(names_from=)` / `pivot_longer(cols=)`, `unnest_wider(col=)`, gt column-selection arguments). Use string column names (`"col"`), bare names, or tidyselect helpers (`all_of()`, `any_of()`, `starts_with()`, `where()`, etc.) instead. `.data$col` is correct **only** in data-masking contexts (`mutate()`, `filter()`, `summarise()`, `arrange()`, `if_else()`, `case_when()`, `aes()`).
- **Always** read the upstream source directly when you need a definitive answer about a third-party system's behaviour (DHIS2 in particular, but also R / tidyverse packages, Quarto, Pandoc, .NET runtime, etc.). Docs, release notes, and changelogs are known to be unreliable for some of these projects — the source is the ultimate authority, the written reference is a convenience shortcut. When working via the neoipc-workspace, see its `CLAUDE.md` → Reference checkouts for the `refs/` submodules that support this workflow.
- **Always** verify upstream claims now, not later. When a plan or recommendation depends on a fact about a third-party system's behaviour, read the source as part of the planning step; do not write "verify at implementation time" or "TBD against upstream" and move on. Deferred verification compounds — each unresolved fact is an attack surface for later wrong implementation. Pairs with the "read the upstream source directly" guardrail above.
- **Always** verify factual claims in design notes and task files against the actual source before propagating them. Treat "X does Y" descriptions in repo documentation as a hypothesis to verify by reading the function or module, not as ground truth — these documents can carry stale or wrong claims that survive long enough to look authoritative. When the claim turns out to be wrong, fix the documentation in the same commit.
- **Always** re-read iteratively-edited documents end-to-end before marking them done. After several rounds of edits to a long document (plan files, design docs, multi-section task files), proactively read the whole thing to catch sentences that contradict later edits, file/path references that no longer match the current model, summaries that drifted from the detail, deferred-section markers that disappeared, naming-scheme drift between sections. Don't make the user point each one out individually.
- **Never** dismiss identified inconsistencies as "cosmetic" when a rename window is already open (pre-alpha, release prep, planned breaking change in the same area). The cost-benefit changes the moment a rename for anything else in the same family is proposed; the right default in that window is to fix the inconsistency in the same pass.
- **Always** treat test evidence asymmetrically: **a red run proves a failure exists; a green run proves nothing.** Green means only that *this* run, on *these* assertions, did not hit a defect — it is never evidence that a safeguard is unnecessary, because the safeguard may be exactly what kept it green. The burden of proof therefore sits on **any** change to a wait, guard, retry or workaround — **adding one as much as removing one** — and a passing test does not discharge it in either direction. Adding is the more insidious case, because a green run after adding a fix feels like confirmation while proving only that the symptom stopped appearing: the change may have masked the defect, merely shifted the timing, or fixed something adjacent while the real cause waits to resurface elsewhere. That is precisely how workarounds accumulate — each was added when a test went green, none had its mechanism established, and they then survive for years because nobody can safely tell which is load-bearing. **If you cannot PROVE the mechanism, you have a hypothesis, not a fix — say so in the comment.** Naming one is not proving one, and the distinction is the whole point: a plausible mechanism is trivially easy to produce and manufactures confidence without evidence. Proof means a demonstration that would have come out differently had the explanation been wrong: the upstream source read to the line that settles it, a probe whose output can only occur under that explanation, or a test that goes red without it. "It is consistent with the symptom" is not proof; a great many wrong explanations are.
- **Never** let a test — or the harness around it — **change the system under test. Tests observe behaviour; they do not intervene in it.** Three things remain legitimate: **reading** state (a response body, a log, an object's fields), **driving** the software the way a real caller does (calling its public interface), and **provisioning fixtures** through that same public interface. What is barred is reaching *inside* the running system to make it do something no caller could — invoking an internal function to force a recomputation, replacing or wrapping a function, or writing to internal state to reach the condition an assertion wants. The distinction is **read versus write**: dumping internal state is observation; calling an internal routine to change it is interference. **The failure mode is that it works.** The suite goes green, nothing looks wrong, and the assertion is now passing because the harness produced the state rather than because the software did — so the test no longer measures the software at all, and the defect it was meant to catch ships. When the software is hard to observe, the answer is a better *observation* (watch its traffic, read its state, instrument a copy you build yourself), never a nudge. The sole admissible exception is an **explicitly opt-in diagnostic** — off by default, never active in a normal run, never something an assertion depends on, **and behaviour-transparent**: if it wraps a function it must be a pure passthrough that alters no argument, return value, timing, or effect, so it observes without changing what it observes (a "diagnostic" that drops an argument or delays a call is interference wearing a label).
- **Never** edit a checked-in file through a generated script (a Python/PowerShell one-liner doing string replacement, `sed -i`, and the like). Use the editor's own edit operation, one change at a time. Two reasons, both first-order. **Reviewability:** a scripted edit shows the user the *script*, not the change — they cannot see a diff, cannot follow what is happening to their code, and the actual modification is hidden behind a layer of abstraction they did not ask for. **Correctness:** string-replacement surgery on structured text repeatedly mangles files here — it has silently dropped adjacent code, left orphaned declarations, and produced edits whose damage only surfaced later in a failing test. Both failure modes have occurred more than once in a single session. This applies to bulk edits too: several individually-visible edits beat one invisible sweep. The exception is a *generated* file that is never reviewed by hand.
- **Never** use unexplained acronyms or initialisms in code comments, doc comments, or documentation prose — write "Tracker Capture", not "TC". They cost the writer nothing and cost every subsequent reader a lookup, and the reader is usually someone with less context than the author had. Established domain terms that the repository defines somewhere (`NEOIPC_CORE`, DHIS2, SSI/BSI/HAP/NEC as infection types) are fine; ad-hoc contractions of product or component names are not.
- **Never** write filler comments — comments that describe absent behavior ("not currently used"), restate the obvious, or hedge ("maybe this is needed?") add no information. The default is no comment; reserve comments for hidden constraints, subtle invariants, surprising behavior, or workarounds for specific bugs. If a property's existence is unclear without a comment, the property is misnamed, misplaced, or shouldn't exist — fix that instead.
- **Always** write doc comments on exported functions (Roxygen `#'` blocks for R, comment-based help `<# ... #>` for PowerShell) and targeted explanatory comments at non-obvious design points as part of the same change that introduces the code — don't defer to a "doc-comments sweep" follow-up. Pairs with the "no filler comments" guardrail above: comments must add information, AND the ones that are warranted must land in-band, not later.
- **Never** predict the future in code comments. Speculative commented-out code, `# TODO: when X happens, do Y` notes, or any forward-looking text describing not-yet-decided changes belongs in the project's task tracking, not in checked-in source. Source comments describe *what is*, not *what might be*.
- **Never** reference internal project-tracking identifiers in checked-in source or its comments — milestone or phase labels (`M3`, `Phase 2`), plan-decision numbers (`decision 8/9`), task-file or plan-document names, sprint names, and the like. They are opaque to anyone reading the code without the current planning context, and they go stale the moment the plan moves on. State what the code *does* and why in terms intrinsic to the code; the milestone/task linkage belongs in the project's task tracking and the commit/PR message, not in the source. Marking genuinely provisional code as such is fine — but describe the state intrinsically ("currently not handled", "deferred", "scaffold") rather than naming the milestone that will retire it. Pairs with the no-future-prediction guardrail above.
- **Never** leave placeholder stubs (a function whose body is just `stop("not implemented")` in R or `throw 'not implemented'` in PowerShell, or similar) in source as scaffolding for future work. A function that exists only to error because the real implementation "comes later" is dead code. Delete it; the planned work belongs in the project's task tracking, not in checked-in source.
- **Never** add a `Co-Authored-By` trailer to git commit messages. The user does not want AI co-author attribution.
- **Never** put long-lived guidance in per-machine local memory (e.g. Claude Code's `~/.claude/.../memory/`) — it does not follow the user across machines. Coding rules, communication preferences, domain conventions, and recurring corrections belong in this `CLAUDE.md` (and its `.github/copilot-instructions.md` sibling) so they travel with the repo. Reserve local memory for genuinely ephemeral session context.
- **Never** point a checked-in file at a Claude Code (or other agent tool's) **per-machine session artifact** as a reference — a saved plan under `~/.claude/plans/`, a transcript / tool-result under `~/.claude/projects/`, or per-project local memory. These live in per-machine local state: they do not sync across the user's machines and are invisible to other developers (and to an agent on another checkout), so a `See plan file: ~/.claude/plans/foo.md` pointer in a committed task or planning document (or any other committed doc, source comment, or commit message) is a dead link for everyone but its author on the one machine that has it. **Inline the durable content** — the plan's decisions, rationale, and build sequence — into a committed document in this repository instead of citing the local path. Merely *describing* such a path where the path itself is the subject (e.g. documenting which paths an agent tool is permitted to access) is fine; the rule is against citing one as a source of truth. Pairs with the no-absolute-local-paths and no-per-machine-local-memory guardrails above.
- **Never** modify the user's global git config (`git config --global ...` / `~/.gitconfig`) as a workaround for a transient problem. For network disconnects, slow clones, or intermittent failures, **retry** — the failure is usually elsewhere and a config tweak persists across every repo on the machine. For genuine repo-specific tuning, use `git config --local ...` or a one-shot `-c key=value` flag on the command. Examples to avoid: `core.compression=0` (kills compression for all future git operations), `http.postBuffer` bumps (only relevant for HTTP-1.1 push edge cases). If a genuine global change is needed, surface it to the user first with the specific reason and the persistent cost.
- **Never** force-push to a branch that has an open pull request under review. Rewriting already-pushed history mid-review is hostile to reviewers — it discards their in-progress review, breaks the anchoring of existing review comments to lines and commits, and hides what actually changed since they last looked. Push follow-up commits instead; because merges are squash-merged, the intermediate commits collapse into one on merge, so a clean final history costs nothing. Force-pushing is acceptable only on a private WIP branch that has not been shared for review.
- **Always** namespace-qualify calls to functions from non-`base` packages with `pkg::fn(...)`, even when `pkg` is a recommended package auto-attached at R startup (`stats`, `utils`, `methods`, `grDevices`, `graphics`, `datasets`). The alternative is an explicit `#' @importFrom pkg fn` in roxygen plus a corresponding entry in `DESCRIPTION` `Imports`. Auto-attachment populates the interactive search path, but `R CMD check` codetools resolves package code against `base` + declared imports only — unqualified non-`base` calls produce *"no visible global function definition"* NOTEs. Documentation links (`[pkg::fn()]` in roxygen) and in-message references inside backticks (e.g. `` `stats::rbinom()` `` in an error message) stay as-is — they're documentation, not calls. Authoritative source: *Writing R Extensions* §1.1.3 / §1.6.
- **Always** use an approved PowerShell verb (`Get-Verb`) + PascalCase noun for every script file and exported function. Choose by behaviour: `New-` constructs and returns an in-memory object (no I/O); `Build-` renders/assembles an artifact from inputs; `Export-` serialises data to a file.
- **Always** restore the caller's environment before a script returns: a script that sets `$env:X` must leave the session exactly as it found it. A script run **in-process** — `.\Foo.ps1`, `& .\Foo.ps1`, or dot-sourced — shares the caller's environment, so every assignment persists after it exits and is inherited by *every* later child process. (`pwsh -File Foo.ps1` forks and does not leak, which is why this goes unnoticed in CI while biting developers at a prompt.) Two consequences make it more than untidy: **credentials persist** in the session (`NEOIPC_DHIS2_TOKEN`, `NEOIPC_DHIS2_PASSWORD`), and **safety switches persist** — a leftover override silently disables a fail-closed check on a *later* run that never asked for it, which is how a guard becomes a no-op with nobody touching it. Wrap the work in a save/apply/`finally`-restore helper rather than assigning `$env:` directly. Two details are load-bearing and both have been got wrong: restore must **remove** a variable the caller did not have, which needs `[Environment]::SetEnvironmentVariable(name, [NullString]::Value, 'Process')` — passing `$null` binds to the `[string]` parameter as `''` and leaves it empty-but-**present**, so a consumer's default-when-unset fallback never fires; and a fail-closed switch must be set on **both** branches (`'1'` or `'0'`), never only when enabled, or an inherited value decides it. `finally` covers normal return, `throw` **and** `exit`; it cannot cover a hard process kill, and needs not to — the environment dies with the process.
- **Always** give every PowerShell file the same header, in this order: a `#!/usr/bin/env pwsh` shebang **on files that are executed directly** (the `scripts/*.ps1` entry points — *not* `.psm1` module roots, the module source files under `Private/`/`Public/`, or Pester test files, where it advertises an execution mode that does not work); then `#Requires -Version 7.6`; then **a blank line**; then the comment-based help block. That blank line is load-bearing, and its absence fails **silently** — three things compete for the top of the file, and getting the order wrong leaves `Get-Help` printing a synthesized syntax line, so the script *looks* documented when it is not. Three rules, each verified against the engine rather than the docs — the oracle is `ScriptBlockAst.GetHelpContent()` returning non-null, which is what a test should assert: **(1)** a `#` comment line (shebang *or* `#Requires`) **immediately** above `<#`, with no blank line between, discards the help; **(2)** a `function` fewer than **two** blank lines after `#>` steals the help from the script — which is *correct* and intended in a module source file, whose help belongs to its functions, so those files deliberately carry no script-level header (a `param()`/`[CmdletBinding()]` block in between neutralises it); **(3)** any line inside the help block that **starts** with `.` followed by a word that is not a recognised help keyword discards the **entire block**. That third one is a live hazard here rather than a theoretical one: this repository's prose discusses `.po` and `.pot` files constantly, and `Invoke-Localization.ps1` had a textbook-correct layout yet returned no help at all because one `.DESCRIPTION` line began `.po translations and is…`. Reflow such a line rather than letting it begin one — mid-line is fine, only line-initial is fatal. `#Requires` placement is otherwise free, so put it where the help parser is happiest. The **7.6 floor is measured, not preferred**: `Get-Date -AsUTC` in the `Build-*.ps1` wrappers, `Resolve-Path -RelativeBasePath` in `Build-PartnerCertificate.ps1`/`Build-PartnerReport.ps1`, and `ConvertFrom-Json -DateKind` in `NeoIPC-Tools/Private/Metadata.ps1` all need more than 7.0, so declaring less would assert a conformance the code does not have. *(PowerShell-specific)*
- **Never** add an unconditional reference (formal `@tbl-*`/`@fig-*` or textual) to content that is conditionally included. If a table, figure, section, or any content depends on a configuration flag, all references to it must be conditional on the same flag. This applies to all conditionally present content: tables, figures, sections, reference data, confidence intervals, and any other content whose presence depends on configuration. When a text contains a cross-reference to conditional content, split it into a base string (always shown) and a conditional suffix (shown only when the target is present), provide two complete variants, or use a glue placeholder that resolves to the cross-reference when the target is present and to empty when it is not. *(repo-specific)*
- **Never** join neoipcr dataset tibbles on DHIS2 UIDs (`trackedEntity`, `enrollment`, `event`, `orgUnit`, etc.). Always join on the synthesized integer keys (`patient_key`, `enrollment_key`, `event_key`, `department_key`, `hospital_key`, `country_key`, etc.). DHIS2 UIDs may not be present on every tibble (they are schema-gated); integer keys are the relational backbone. When you need a hierarchy key that isn't directly on a fact tibble (e.g. `hospital_key` on patients), join through the parent metadata tibble (`metadata$departments`) which carries it. *(repo-specific)*
- Do not use the R `argparse` package (it requires Python). Use shared `parse-args.R` or JSON parameter files instead. *(repo-specific)*
- **Never** use single letters or bare numbers as YAML keys in string resource files. po4a's YAML module fails to extract some single-letter keys (e.g., `u`), and short keys are not expressive. Use descriptive names instead (e.g., `female`/`male`/`undetermined` instead of `f`/`m`/`u`). When a YAML key must map to a short code from DHIS2, add a mapping in the R code. *(repo-specific)*
- String values must not be duplicated across YAML layers (glossary, common, report-specific) or across report-specific files. If two reports share a string, move it to `common.yaml`. Run `scripts/Test-StringResourceLayers.ps1` to check before committing changes to string resource files. *(repo-specific)*
- The **AMA Manual of Style** is the reference for human-language style questions (capitalisation, punctuation, terminology). The glossary may carry multiple casing variants of a term (e.g., lowercase for running text, title case for headings) — use whichever fits the context. Disease names are common nouns and are lowercase in running text (e.g., "necrotising enterocolitis", "pneumonia") unless they contain a proper noun (e.g., "Crohn's disease"). The sentence-case glossary variants (`_sc`) exist for labels and headings, not because the terms are proper nouns. *(repo-specific)*
- **Always** use the **official WHO translation** of a term when the source publication has one in the target language — WHO terminology is normative for the concepts NeoIPC reports on, and a locally invented rendering is wrong even when it is defensible Spanish/French/etc. Check the publication's own language editions before translating a WHO term or classification (many WHO documents ship official editions in the six WHO official languages — Arabic, Chinese, English, French, Russian, Spanish — and often more). Worked example: the AWaRe antibiotic categories are **Acceso / Precaución / Reserva** in Spanish, per [*The WHO AWaRe (Access, Watch, Reserve) antibiotic book*](https://www.who.int/publications/i/item/9789240062382) — **not** "Vigilancia" (which is also how *surveillance* is rendered, so it would collide with this project's own core term) and certainly not the bare verb "Ver". Record the resolved term in `glossary.yaml` so translators and reviewers converge on it rather than re-deciding per string. Where no official WHO translation exists, fall back to the AMA Manual of Style guidance above. *(repo-specific)*
- **Never** use imperative voice in Partner Report string resources (outlier interpretation, callout text, or any user-facing prose in `_sR.yaml`). The report cannot know the full clinical context; use suggestive phrasing ("this may indicate…", "…may warrant attention") instead of directives ("Review…", "Confirm…", "Read this…"). *(repo-specific)*
- **Always** use table-visible labels in outlier interpretation strings. The terms in callout prose must match the row labels shown in the corresponding table so readers can identify the referenced metric — but apply running-text casing, not label casing. For example, use "pneumonia" (from the Table 1 row label "Pneumonia") not "HAP", and "CVC-associated sepsis/BSI" (from the Table 2 row label) not "CVC-associated infection rate". When the same metric ID appears in multiple tables with different display labels (e.g., "CVC" in Table 2 vs Table 8), the `localize_metric_name()` function uses `table_name` context to resolve the correct label. *(repo-specific)*
- **Never** edit files that are generated by po4a or by `scripts/update-glossary-po.py`. These files are overwritten on every pipeline run. Generated files include: `common.<lang>.yaml`, `content.<lang>/` directories, `_quarto-<lang>.yml`, `Validation-Report/<lang>/` directories, `doc/protocol/<lang>/`, `glossary.<lang>.yaml`, and any other file that appears as a translation target in `po/*.po4a.cfg`. **Never** edit `.pot` files either — they are regenerated by po4a / the glossary script. *(repo-specific)*
- **The repository owns the `.pot` templates; Weblate owns the `.po` translations and is their only writer.** Never edit, regenerate, `msgmerge` or otherwise write a Weblate-owned `.po` — `po/reports.<lang>.po`, `po/documentation.<lang>.po`, `po/infectious_agents.<lang>.po`, `po/metadata.<lang>.po`. Three catalogues are **not** on Weblate and stay repository-owned, so the pipeline is their only writer and editing them here is correct: `po/glossary.*.po`, `scripts/po/*.po`, and `po/antibiotics.*.po` — the last because its content is CC BY-NC-SA 3.0 IGO, and a NonCommercial term is not a free licence, which Hosted Weblate's free plan requires. Two writers on one `.po` is what breaks every component at once: po4a rewrites `POT-Creation-Date` on **every** run (its own docs: *"The PO files are always re-generated based on the POT with msgmerge -U"*), while Weblate writes `PO-Revision-Date` / `Last-Translator` / `Language-Team` / `X-Generator` — adjacent lines in one hunk git cannot auto-merge, so a single source-string change conflicts every language of a catalogue simultaneously. `scripts/Invoke-Localization.ps1 -Update` therefore restores every Weblate-owned `.po` from `HEAD` after po4a runs, and refuses to start when one already has uncommitted changes. When changing translatable content: **(1)** edit the English source file (e.g. `common.yaml`, `content/_sR.yaml`, `glossary.yaml`); **(2)** run `scripts/Invoke-Localization.ps1 -Update`, which regenerates the `.pot`, renders the localized artifacts, and leaves every Weblate-owned `.po` byte-identical; **(3)** merge the `.pot` to `main` — Weblate's *msgmerge* add-on then updates the `.po` files and commits them back. Use `-Render` for a build or a single-language render: it passes po4a's `--no-update` and writes neither `.pot` nor `.po`. *(repo-specific)*
- **Always** send translation feedback through **Weblate**, never through a pull-request comment. Translation PRs are authored by a bot; the human who wrote the translation never sees a review comment on them. Corrections, terminology decisions and questions belong in Weblate's per-string comments (which support `@username` mentions), suggestions, and the glossary — where they reach the translator and stay attached to the string. A GitHub review of a translation PR covers **mechanics only** (does it build, `msgfmt -c`, placeholder integrity, file scope), never language. Terminology that must hold is recorded in `glossary.yaml` with a translator note, not in a thread. *(repo-specific)*
- **Never** merge a Weblate pull request with **"Squash and merge"** — use **"Rebase and merge"**. Weblate keeps its own commits after pushing them and rebases them onto `main` once the pull request lands. A squash merge fuses them into one commit with different content-identity, so git can no longer prove `main` already contains them, replays them, and conflicts — **on every component of the project at once**, not just the catalogue that was merged. That is not hypothetical: squash-merging three translation pull requests on 2026-07-27 put all three components into `merge_failure` simultaneously. A rebase merge replays each commit with the same patch, so Weblate recognises its originals by patch identity and drops them, leaving nothing stranded — and it keeps history linear, unlike the merge commit Weblate's own documentation suggests. The repository already allows rebase merges and forbids merge commits, so this is purely which button is pressed. When a component diverges anyway, the remedy is Weblate's *Reset and reapply* (`reset-keep`), which is non-destructive — it re-applies pending translations onto a fresh checkout of `main` — never a hand-edit of a catalogue. **Delete the head branch when the pull request merges** — mechanism, not tidiness: a rebase merge rewrites commit SHAs exactly as a squash does, so the pushed `weblate-<catalogue>` tip stops being an ancestor of `main`, Weblate's next push is rejected as non-fast-forward, and because *Lock on error* is on that rejection **locks the component against translators**. That is what happened on 2026-07-28, a day after the squash incident above and from an unrelated cause. The repository now has *Automatically delete head branches* enabled so the web-UI path is safe, and every component has *Push on commit* **off** — otherwise Weblate pushes at exactly the moment the Squash add-on has rewritten (and so invalidated) the already-pushed tip. *(repo-specific)*
- **Always** treat Weblate's per-component **file-format parameters as part of this repository's text-file contract**, not as remote preferences. Weblate is a writer of every `po/<catalogue>.<lang>.po`, so its settings must agree with what this repository's own writers produce: `po_line_wrap` must be unwrapped and `dos_eol` must stay off, because every repository-side writer produces unwrapped LF: three po4a configs pass `--wrap-po newlines`, `scripts/po4a.cfg` passes `--wrap-po no`, and `metadata` — which has no po4a config — is written by `Write-NeoIPCMetadataPoText`, which never wraps. A mismatch means each writer re-flows what the other wrote; one component sitting at the xgettext default of 77 produced an 18,000-line diff of pure re-wrapping. **Source-string metadata belongs in the `.pot` and must not be duplicated into the `.po`**: for these bilingual components Weblate treats `po/<catalogue>.pot` as the source translation (`is_source: true`), reads `priority:N` and other source flags from there, and strips them when writing each locale file — so `Export-NeoIPCMetadataTranslation`, which still writes those flags into every `po/metadata.<lang>.po`, generates 16,354 lines that Weblate removes again on its next write. That exporter has **not** been fixed yet; until it is, this rule describes the target and the metadata catalogue is the known exception. Canonical values, and a documented reason for every deviation, live in [`docs/weblate-component-configuration.md`](docs/weblate-component-configuration.md). *(repo-specific)*
- **Number and unit formatting** — Follow SI conventions where they aid clarity, but prioritise readability across cultural backgrounds and automated layout constraints. Specifically: **(a)** Use the `unit_separator` string resource between a number and its unit (e.g., `50 g`, `39.8 days`); do not hardcode spaces. **(b)** Use the `digit_group_separator` string resource via `format_integer()` / `gt::fmt_number()`; do not hardcode commas, periods, or spaces as thousands separators. **(c)** Use the `percent_symbol` string resource; no space before `%` (ISO 31 recommends a space, but the dominant convention in medical literature omits it). **(d)** Do not use non-breaking spaces (`\u00a0`, `\u202F`) in string resources or code unless a specific, documented line-break problem exists — let the layout engine (LaTeX, HTML) handle line-breaking; if a non-breaking space is needed, add a code comment explaining why. **(e)** Use an en-dash `\u2013` (not a hyphen) between lower and upper CI bounds; parentheses around CIs: `(lower–upper)`. **(f)** For inline rate expressions in running text, use plain spaces around operators; for formal formulas in footnotes, use LaTeX math mode. *(repo-specific)*
- **Always** keep the report PowerShell wrapper scripts (`scripts/Build-*.ps1` — Reference, Partner, Partner-Certificate, Patient-Data, Validation) aligned on any concept that applies across more than one of them: variable and parameter names, helper-call patterns, `$extraFields` / build-report JSON schema, user-facing behaviour and argument surfaces. **(a)** Before adding a new concept (parameter, variable, helper call, JSON field, etc.) to one wrapper script, grep the other wrapper scripts for preexisting implementations and **reuse or extend** existing patterns rather than inventing parallel code. **(b)** When adding a concept that could legitimately apply to other wrapper scripts, **ask the user** whether it should be added to those other scripts in the same pass. **(c)** When reading or editing across multiple wrapper scripts, **proactively assess and highlight any divergence** you notice — even if fixing it is out of the current task's scope, flag it and record it wherever this project tracks work, rather than letting it slip. *(repo-specific)*

---

## Report Locations

Reports live under `reports/`:

- **Partner Report:** `reports/Partner-Report/`
- **Reference Report:** `reports/Reference-Report/`
- **Validation Report:** `reports/Validation-Report/`
- **Partner Certificate:** `reports/Partner-Certificate/`

---

## Report Architecture

### Shared Infrastructure

- **Shared R code**: `reports/common/` — `helpers.R` (locale parsing, string resource loading, DHIS2 connection helpers), `load-neoipcr.R`, `parse-args.R` (CLI arg parsing), `getDataset.R` (dataset export), `logging.R` (unified `logger`-based logging: `configure_logging()` + `logInfo`/`logVerbose`/`logDebug`/`logWarn`/`logError`, plus `with_error_trace()` to log a full backtrace when a render-time computation fails), `reference.docx` (Word template)
- **Base string resources**: `reports/common.yaml` (English domain terms, table headers, footnotes)
- **Pandoc filters**: `reports/filters/pandoc-quotes.lua` (language-aware typographic quotes)

### Lua Filters

`pandoc-quotes.lua` on all four reports. Empty section headers are suppressed in R (conditional cat-emit gated on the section's `show_section_*` flag), not by a Lua filter.

### R Data Scripts & Docker Deployment

- **R data scripts** (e.g., `Generate-ReferenceData.R`) live alongside their reports. PowerShell wrappers live in `scripts/`. Shared R functions in `reports/common/`.
- **Docker**: The `NeoIPC.Reporting` .NET container (its own repository, `NeoIPC/NeoIPC-Reporting` on GitHub) clones this repository's report sources at image-build time and renders them via Quarto + R. Font and locale changes therefore require a Dockerfile update **there**, not here — adding a font to a report in this repository does not put it in the rendering image.

---

## String Resource Cascade

`helpers.R::get_string_resources()` implements a cascading YAML merge for localized string resources. Each report provides a base `content/_sR.yaml` (English), and the cascade overlays language-specific overrides using `modifyList()` (recursive merge).

### Cascade order (lowest → highest priority)

Paths are relative to each report's directory (e.g., `reports/Partner-Report/`).

1. `../../glossary.yaml` — controlled vocabulary (English base)
2. `../common.yaml` — shared domain terms (English base)
3. `content/_sR.yaml` — report-specific strings (English base)
4. `../../glossary.<lang>.yaml` — controlled vocabulary (language override)
5. `../../glossary.<lang>_<territory>.yaml` — controlled vocabulary (language+territory override)
6. `../common.<lang>.yaml` — shared domain terms (language override)
7. `../common.<lang>_<territory>.yaml` — shared domain terms (language+territory override)
8. `content.<lang>/_sR.yaml` — report-specific strings (language override)
9. `content.<lang>_<territory>/_sR.yaml` — report-specific strings (language+territory override)

Each level only needs to contain the keys it wants to override — `modifyList()` preserves unmodified keys from earlier levels.

### Setup pattern (in each report's `_setup.qmd`)

```r
locale <- Sys.getenv("LC_ALL")                 # e.g. "de_DE.UTF-8"
localeObj <- parse_locales(locale)[[1]]         # list(language="de", territory="DE", codeset="UTF-8")
sR <- get_string_resources(localeObj)           # cascading YAML merge
```

**Important**: `get_string_resources()` reads `localeObj` from the calling scope (not from its parameter `x`). The `localeObj` variable must exist in the parent environment.

### Locale resolution for content files

`helpers.R::get_localised_path(file_name, language, territory)` resolves localized content files with fallback:

`content.<lang>_<territory>/` → `content.<lang>/` → `content/`

### Variable naming

All reports store the string resource result in `sR` (accessed via `sR$key`).

### YAML conventions

- Use `>-` (folded, strip trailing newline) for multi-line strings that should be a single paragraph
- Use `|` (literal, keep trailing newline) for strings with intentional newlines (e.g., email templates)
- Use `>` **only** when a trailing newline is intended (rare)
- Quote numeric YAML keys: `"1"`, `"2"`, `"3"` (otherwise YAML interprets them as integers)
- Use the `'bool#no' = function(x) x` handler in `yaml::read_yaml()` to prevent YAML from converting "no" to `FALSE`

### Glossary naming convention

`glossary.yaml` uses a suffix-based naming convention for casing and plural variants:

| Suffix | Meaning | Example key | Example value |
|--------|---------|-------------|---------------|
| *(none)* | AMA canonical (lowercase) | `necrotising_enterocolitis` | `"necrotising enterocolitis"` |
| `_sc` | Sentence case | `necrotising_enterocolitis_sc` | `"Necrotising enterocolitis"` |
| `_tc` | Title case | `necrotising_enterocolitis_tc` | `"Necrotising Enterocolitis"` |
| `_plural` | Plural form | `patient_day_plural` | `"patient days"` |

- Abbreviations (CVC, HAP, INV, NEC, SSI) are always uppercase — no variants needed.
- Proper nouns (NeoIPC Surveillance) keep their canonical casing — no variants needed.
- Single-word terms: `_sc` and `_tc` produce the same result — use `_sc` only.
- Suffixes can combine: `patient_day_plural_tc` = "Patient Days".
- Weblate `variant_regex`: `_(tc|sc|plural|plural_tc|plural_sc)$` groups variants in the sidebar.
- R code picks the appropriate variant: `sR$necrotising_enterocolitis_sc` for labels, `sR$necrotising_enterocolitis` for running text.

---

## po4a / Weblate Localization Pipeline

Translatable content is managed via [po4a](https://po4a.org/) with Weblate for community translation.

### How it works

1. Source files (QMD, Rmd, YAML, LaTeX) → po4a extracts → `.pot` template
2. The `.pot` is merged to `main`; Weblate's *msgmerge* add-on brings each `.po` up to it
3. Translators work in **Weblate**, which commits the `.po` back
4. po4a generates localized files (e.g., `Report.de.qmd`, `content.de/_sR.yaml`) from the committed `.po`

**Translations live in `.po` files, not in YAML.** The localized YAML files (`content.de/_sR.yaml`, `common.de.yaml`, etc.) are *generated* by po4a from `.po` files — do not edit them directly. To change a translation, change it in Weblate; the catalogue-ownership guardrail above says which `.po` files that applies to, and `po/glossary.*.po`, `scripts/po/*.po` and `po/antibiotics.*.po` are the three that remain repository-owned. Each has a generator here that keeps it in step with its template, so change the English source and re-run the pipeline rather than editing a catalogue by hand.

### po4a setup

po4a is a Perl tool that is **incompatible with native Windows**. On Windows, always run it via **WSL**.

A recent version is required for all features. The repository includes po4a as a git submodule at `tools/po4a/`. Initialize it with:

```bash
git submodule update --init tools/po4a
```

**Preferred interface**: Use `scripts/Invoke-Localization.ps1` instead of invoking po4a directly. It handles WSL, path resolution, and the full pipeline automatically:

```powershell
./scripts/Invoke-Localization.ps1 -Update                  # full pipeline (all configs + glossary)
./scripts/Invoke-Localization.ps1 -Update -Config reports   # po4a for reports only
./scripts/Invoke-Localization.ps1 -Test                     # read-only string layer check
```

**Manual invocation** (if needed): The submodule must be called with `PERLLIB` set so it finds its own libraries:

**Do not run these bare against a Weblate-owned config.** po4a rewrites every `.po` as a side effect
of producing the `.pot`, so a bare run over `po/reports.po4a.cfg`, `po/documentation.po4a.cfg` or
`po/infectious_agents.po4a.cfg` puts a second writer on nine catalogues Weblate owns — the failure the
ownership rule above exists to prevent. Use `scripts/Invoke-Localization.ps1 -Update`, which restores
them from `HEAD` afterwards. The invocations below are for reference, and for the one config that is
repository-owned (`scripts/po4a.cfg`).

```bash
# From WSL bash (cd to the Surveillance-Toolkit repo root first):
PERLLIB=tools/po4a/lib tools/po4a/po4a <config-file>
PERLLIB=tools/po4a/lib tools/po4a/po4a-gettextize <args>

# From PowerShell on Windows:
wsl -e bash -c "cd $(wsl wslpath -a .) && PERLLIB=tools/po4a/lib tools/po4a/po4a scripts/po4a.cfg"
```

### po4a configs (in `po/`)

| Config | Scope |
|--------|-------|
| `reports.po4a.cfg` | Partner-Report, Reference-Report, Partner-Certificate, Validation-Report |
| `documentation.po4a.cfg` | Protocol AsciiDoc files |
| `infectious_agents.po4a.cfg` | Pathogen taxonomy |
| `scripts/po4a.cfg` | PowerShell message strings |

**Note:** The glossary (`glossary.yaml`) is **not** managed by po4a. It uses a custom script (`scripts/update-glossary-po.py`) that generates monolingual gettext PO with `msgctxt` for Weblate variant grouping and plural support. See the helper scripts table below.

### Target languages

af, de, el, es, et, fr, it, ne, tr (9 languages)

### Helper scripts (in `scripts/`)

| Script | Purpose |
|--------|---------|
| `Invoke-Localization.ps1` | Unified localization wrapper with tab completion. `-Update` runs the full pipeline (fix layers → YAML keys → po4a → glossary). `-Test` runs read-only validation. See `-Config`, `-Force`, `-DryRun` switches. |
| `Update-Po4aYamlKeys.ps1` | Auto-extract YAML keys for po4a config (run after changing YAML structure) |
| `Test-PoPlaceholders.ps1` | Validate placeholder consistency between source and translations |
| `update-glossary-po.py` | Convert `glossary.yaml` to/from monolingual gettext PO (replaces po4a for glossary). Requires `ruamel.yaml` and `polib`. Run after editing `glossary.yaml` to regenerate `po/glossary.pot`; it then msgmerges every `po/glossary.<lang>.po` up to that template, because this catalogue is repository-owned and the script is its only writer. `--generate-yaml` additionally produces the localized `glossary.<lang>.yaml`. **Remove the `.po` merge at the moment `neoipc-glossary` is registered on Weblate**, or there are two writers on one file again. |

### Importing existing translations

When adding a new file to po4a that already has manual translations:

1. **Back up existing translated files** before any po4a operation. po4a overwrites generated files (`content.de/_sR.yaml`, `*.de.qmd`, etc.) — only `.po` files are version-controlled, everything else is regenerated. Use a naming convention like `content.de_/` (underscore suffix) for backups.
2. **Run `Update-Po4aYamlKeys.ps1`** if the YAML file has nested keys. po4a's YAML module only extracts values whose keys are explicitly listed in the `keys` option. The script recursively collects all keys from the source YAML and updates the config. Without this, nested keys (e.g., `problems.1.description`, `sex.f`, `admission_type.1`) won't be extracted.
   ```powershell
   ./scripts/Update-Po4aYamlKeys.ps1 -ConfigFile po/reports.po4a.cfg
   ```
3. Add the file entry to the relevant `.po4a.cfg` (if not already present).
4. Use `po4a-gettextize` to import the existing translation into a **temporary** `.po` file:
   ```bash
   PERLLIB=tools/po4a/lib tools/po4a/po4a-gettextize -f <format> -m <master> -l <translation> -p /tmp/<report>_<lang>.po
   ```
5. **Remove fuzzy flags** from the gettextize output. `po4a-gettextize` marks most translations as `fuzzy` (even correct ones), and po4a ignores fuzzy translations when generating output. Strip them before merging:
   ```bash
   sed -i 's/^#, fuzzy, /#, /; s/^#, fuzzy$//' /tmp/<report>_<lang>.po
   ```
6. **Merge into a temporary file, never over the committed catalogue.** `msgcat --use-first` keeps the first file's translation for duplicate msgids, so put the imported translations first to override empty entries:
   ```bash
   msgcat --use-first /tmp/<report>_<lang>.po po/reports.<lang>.po -o /tmp/<report>_<lang>_merged.po
   ```
7. **Deliver the result according to who owns the catalogue.**
   - **Weblate-owned** (`reports`, `documentation`, `infectious_agents`, `metadata`): upload it — `wlc upload neoipc/<component>/<lang> --input /tmp/<report>_<lang>_merged.po`. Do **not** commit it; the catalogue-ownership guardrail and the CI gate both reject that, and Weblate would overwrite it anyway. Choose the upload method deliberately: `--method replace` **silently ignores entries whose msgstr is empty**, so it cannot be used to clear a translation, only to add or overwrite non-empty ones.
   - **Repository-owned** (`po/glossary.*.po`, `scripts/po/*.po`): move the merged file into place and commit it.
8. Verify with a round-trip: `PERLLIB=tools/po4a/lib tools/po4a/po4a <config-file>` — check that the generated files match the backup.

**Important**: Run steps 4–6 in a **single WSL session** (one `wsl -e bash -c '...'` invocation). Temp files in `/tmp` do not persist across separate WSL invocations on Windows.

### Known po4a YAML limitations

- **po4a owns the `.pot` file.** Do not manually add entries to `.pot` — po4a regenerates it on every run, dropping manual additions and causing `msgmerge` failures.
- **Single-letter YAML keys may not be extracted** by po4a's YAML module (e.g., `u` fails while `f` and `m` work). Avoid single-letter and bare-number YAML keys entirely (see guardrail above).
- **`.po` literal `\n`**: Inside `.po` quoted strings, `\n` is a literal two-character escape sequence (backslash + n), not a line break in the source. Multi-line msgstr values are split across multiple quoted lines, each ending with `\n`.

---

## Report Conventions

### Translatable Strings *(Target)*

No `sprintf` `%s`, markdown, or LaTeX syntax in translatable strings. Use `glue`-style `{named}` placeholders (e.g., `{patient_id}`, `{count}`). Apply formatting (bold, links, etc.) in rendering code, not in the string resource. Weblate validates `{name}` placeholders automatically.

### Fonts *(Target)*

- Partner-Report & Reference-Report: EB Garamond primary, Noto Serif Condensed fallback for non-Latin scripts (Greek, Cyrillic, Hebrew, Devanagari, etc.)
- Validation-Report & Partner-Certificate: Noto Sans
- All fonts are SIL Open Font License.

### PowerShell Scripts

Every script file and exported function uses an approved PowerShell verb (`Get-Verb`) + PascalCase noun, chosen by behaviour (see the approved-verb guardrail above: `New-` = returns an in-memory object, `Build-` = renders an artifact, `Export-` = serialises to a file). The report wrappers are `Build-*.ps1` (e.g. `Build-PartnerReport.ps1`), all in `scripts/`; they import their shared helpers from the `NeoIPC-Tools` module (`scripts/modules/NeoIPC-Tools`).

### Logging

All report R code and neoipcr log through the `logger` package (`reports/common/logging.R`). Three R namespaces —
the report's slug (e.g. `partner-report`), `report-common` (the shared `common/` layer), and `neoipcr` — let every
line self-identify its source. Verbosity is **one** setting (`quiet`/`normal`/`verbose`/`debug`): the default `normal` shows lifecycle progress;
`verbose`/`debug` reveal the DHIS2 query trace (URL + HTTP status + row count — **never** response bodies, a
data-protection boundary). The `Build-*.ps1` wrappers map the standard `-Quiet`/`-Verbose`/`-Debug` switches to it and
pass it to the children **two** ways: the **`NEOIPC_LOG_LEVEL`** environment variable (read by the QMDs and neoipcr)
and native CLI flags — `--quiet`/`--verbose`/`--debug` on the `Generate-*Data.R` calls and `--quiet`/`--log-level`
on `quarto render`; `-Quiet` additionally silences the wrapper's own progress/verbose streams. Each `Generate-*Data.R` resolves a native CLI flag
first, falls back to `NEOIPC_LOG_LEVEL` (so the .NET service can drive it environment-only), and republishes the
resolved level for neoipcr and any child processes. When `NEOIPC_LOG_FILE` is set (by the NeoIPC-Reporting .NET
service), the R side writes structured JSON to that file instead of the console.

Under Quarto/knitr, `configure_logging()` cannot install `logger`'s global warning/message handlers (knitr's own are already on the stack), so it registers knitr output hooks that route each render-time `warning()`/`message()` into the log channel and return `""` to keep it out of the report body. Two invariants follow. **(1)** That hook is the *only* thing keeping raw conditions out of the rendered PDF/HTML — a chunk-level `warning=FALSE`/`message=FALSE` drops the condition before the hook can log it — so `configure_logging()` must run before any condition-raising code (every report `_setup.qmd` installs it before, or at the top of, its first import chunk). **(2)** Render-time condition text is a **logged surface**: keep `warning()`/`message()` messages to aggregates and structural text, never record-level identifiers. The DHIS2 query-trace boundary in `log_dhis2_request` (URL + status + row count, never bodies) is separate and unaffected.

### Argument Handling

- PS passes parameters to Quarto via `-P key:value` flags
- `dhis2_connection_options()` / `dhis2_dataset_options()` in neoipcr coerce string inputs internally — single source of truth for types and defaults
- Casing per layer: PS `PascalCase` → QMD `camelCase` → R `snake_case`, mapped once at each boundary
- Defaults defined only in neoipcr functions, not duplicated in PS scripts or QMD YAML — **except the DHIS2 host**: neoipcr (a public library) no longer defaults to any deployment's host, so the production host default lives in `reports/common/helpers.R::get_connection_options()` (used by every report R entry point). Pass `--host` / `-P dhis2Hostname` to override it.

### Auth Flow

neoipcr is the single auth authority. PS scripts resolve credentials via `Resolve-NeoIPCAuth` (token or username/password), then set scoped environment variables (`NEOIPC_DHIS2_TOKEN`, `NEOIPC_DHIS2_USER`, `NEOIPC_DHIS2_PASSWORD`) so neoipcr in child R/Quarto processes finds them automatically. No `-P "token:..."` in QMD renders. The **host** resolves separately from auth — an explicit `hostname` argument, else the `NEOIPC_DHIS2_HOST` env var (the report tooling supplies the production default when neither is set).

Env var fallback chain in `neoipcr::get_auth_data()`:
1. `NEOIPC_DHIS2_SESSION_ID` → session_id (Docker only)
2. `NEOIPC_DHIS2_TOKEN` → token
3. `NEOIPC_DHIS2_USER` + `NEOIPC_DHIS2_PASSWORD` → username/password
4. `interactive()` → prompt for username/password
5. `!interactive()` → `rlang::abort()` with actionable error

---

## Cross-Platform Portability

Everything in this repository and its submodules must be portable across Windows, Linux, and macOS. When writing scripts or paths:
- Use forward slashes in paths where possible
- Avoid platform-specific tools without fallbacks
- po4a must be run via WSL on Windows (see po4a section above)
