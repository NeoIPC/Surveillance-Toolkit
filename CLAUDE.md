# Claude Code — Surveillance-Toolkit Instructions

This file documents the Surveillance-Toolkit repository. If this repository is checked out as a submodule of the `neoipc-workspace`, the workspace-level `CLAUDE.md` adds additional workspace-specific guardrails (file boundary, cross-repo change order) on top of the guardrails below.

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
- **Always** keep `CLAUDE.md` and `.github/copilot-instructions.md` in sync within this repository. When you modify one, apply the same change to the other.
- **Always** push back when evidence contradicts the user's suggestion or implied assumption. Do not defer to the user's position when authoritative sources (AMA Manual of Style, protocol definitions, language specifications, etc.) say otherwise. Present the evidence clearly and let the user decide.
- **Always** consider both personal data protection (GDPR) and organizational/reputational concerns when making decisions about data shared between partners, published in reports, or exposed through APIs. Small cell counts in shared reports can expose which departments had specific rare pathogens or resistance patterns.
- **Never** use deprecated or outdated APIs. Before introducing a function from a third-party package or a base library, verify it is current. When a replacement exists, use the replacement. When unsure, check the package's `NEWS.md` / release notes rather than assuming.
- **Never** use the `.data$` pronoun in tidyselect contexts (`select()`, `rename()`, `relocate()`, `across(.cols=)`, `pivot_wider(names_from=)` / `pivot_longer(cols=)`, `unnest_wider(col=)`, gt column-selection arguments). Use string column names (`"col"`), bare names, or tidyselect helpers (`all_of()`, `any_of()`, `starts_with()`, `where()`, etc.) instead. `.data$col` is correct **only** in data-masking contexts (`mutate()`, `filter()`, `summarise()`, `arrange()`, `if_else()`, `case_when()`, `aes()`).
- **Always** read the upstream source directly when you need a definitive answer about a third-party system's behaviour (DHIS2 in particular, but also R / tidyverse packages, Quarto, Pandoc, .NET runtime, etc.). Docs, release notes, and changelogs are known to be unreliable for some of these projects — the source is the ultimate authority, the written reference is a convenience shortcut. When working via the neoipc-workspace, see its `CLAUDE.md` → Reference checkouts for the `refs/` submodules that support this workflow.
- **Always** verify upstream claims now, not later. When a plan or recommendation depends on a fact about a third-party system's behaviour, read the source as part of the planning step; do not write "verify at implementation time" or "TBD against upstream" and move on. Deferred verification compounds — each unresolved fact is an attack surface for later wrong implementation. Pairs with the "read the upstream source directly" guardrail above.
- **Always** verify factual claims in design notes and task files against the actual source before propagating them. Treat "X does Y" descriptions in repo documentation as a hypothesis to verify by reading the function or module, not as ground truth — these documents can carry stale or wrong claims that survive long enough to look authoritative. When the claim turns out to be wrong, fix the documentation in the same commit.
- **Always** re-read iteratively-edited documents end-to-end before marking them done. After several rounds of edits to a long document (plan files, design docs, multi-section task files), proactively read the whole thing to catch sentences that contradict later edits, file/path references that no longer match the current model, summaries that drifted from the detail, deferred-section markers that disappeared, naming-scheme drift between sections. Don't make the user point each one out individually.
- **Never** dismiss identified inconsistencies as "cosmetic" when a rename window is already open (pre-alpha, release prep, planned breaking change in the same area). The cost-benefit changes the moment a rename for anything else in the same family is proposed; the right default in that window is to fix the inconsistency in the same pass.
- **Never** write filler comments — comments that describe absent behavior ("not currently used"), restate the obvious, or hedge ("maybe this is needed?") add no information. The default is no comment; reserve comments for hidden constraints, subtle invariants, surprising behavior, or workarounds for specific bugs. If a property's existence is unclear without a comment, the property is misnamed, misplaced, or shouldn't exist — fix that instead.
- **Always** write doc comments on exported functions (Roxygen `#'` blocks for R, comment-based help `<# ... #>` for PowerShell) and targeted explanatory comments at non-obvious design points as part of the same change that introduces the code — don't defer to a "doc-comments sweep" follow-up. Pairs with the "no filler comments" guardrail above: comments must add information, AND the ones that are warranted must land in-band, not later.
- **Never** predict the future in code comments. Speculative commented-out code, `# TODO: when X happens, do Y` notes, or any forward-looking text describing not-yet-decided changes belongs in the project's task tracking, not in checked-in source. Source comments describe *what is*, not *what might be*.
- **Never** leave placeholder stubs (a function whose body is just `stop("not implemented")` in R or `throw 'not implemented'` in PowerShell, or similar) in source as scaffolding for future work. A function that exists only to error because the real implementation "comes later" is dead code. Delete it; the planned work belongs in the project's task tracking, not in checked-in source.
- **Never** add a `Co-Authored-By` trailer to git commit messages. The user does not want AI co-author attribution.
- **Never** put long-lived guidance in per-machine local memory (e.g. Claude Code's `~/.claude/.../memory/`) — it does not follow the user across machines. Coding rules, communication preferences, domain conventions, and recurring corrections belong in this `CLAUDE.md` (and its `.github/copilot-instructions.md` sibling) so they travel with the repo. Reserve local memory for genuinely ephemeral session context.
- **Never** modify the user's global git config (`git config --global ...` / `~/.gitconfig`) as a workaround for a transient problem. For network disconnects, slow clones, or intermittent failures, **retry** — the failure is usually elsewhere and a config tweak persists across every repo on the machine. For genuine repo-specific tuning, use `git config --local ...` or a one-shot `-c key=value` flag on the command. Examples to avoid: `core.compression=0` (kills compression for all future git operations), `http.postBuffer` bumps (only relevant for HTTP-1.1 push edge cases). If a genuine global change is needed, surface it to the user first with the specific reason and the persistent cost.
- **Never** force-push to a branch that has an open pull request under review. Rewriting already-pushed history mid-review is hostile to reviewers — it discards their in-progress review, breaks the anchoring of existing review comments to lines and commits, and hides what actually changed since they last looked. Push follow-up commits instead; because merges are squash-merged, the intermediate commits collapse into one on merge, so a clean final history costs nothing. Force-pushing is acceptable only on a private WIP branch that has not been shared for review.
- **Always** namespace-qualify calls to functions from non-`base` packages with `pkg::fn(...)`, even when `pkg` is a recommended package auto-attached at R startup (`stats`, `utils`, `methods`, `grDevices`, `graphics`, `datasets`). The alternative is an explicit `#' @importFrom pkg fn` in roxygen plus a corresponding entry in `DESCRIPTION` `Imports`. Auto-attachment populates the interactive search path, but `R CMD check` codetools resolves package code against `base` + declared imports only — unqualified non-`base` calls produce *"no visible global function definition"* NOTEs. Documentation links (`[pkg::fn()]` in roxygen) and in-message references inside backticks (e.g. `` `stats::rbinom()` `` in an error message) stay as-is — they're documentation, not calls. Authoritative source: *Writing R Extensions* §1.1.3 / §1.6.
- **Always** use an approved PowerShell verb (`Get-Verb`) + PascalCase noun for every script file and exported function. Choose by behaviour: `New-` constructs and returns an in-memory object (no I/O); `Build-` renders/assembles an artifact from inputs; `Export-` serialises data to a file.
- **Never** add an unconditional reference (formal `@tbl-*`/`@fig-*` or textual) to content that is conditionally included. If a table, figure, section, or any content depends on a configuration flag, all references to it must be conditional on the same flag. This applies to all conditionally present content: tables, figures, sections, reference data, confidence intervals, and any other content whose presence depends on configuration. When a text contains a cross-reference to conditional content, split it into a base string (always shown) and a conditional suffix (shown only when the target is present), provide two complete variants, or use a glue placeholder that resolves to the cross-reference when the target is present and to empty when it is not. *(repo-specific)*
- **Never** join neoipcr dataset tibbles on DHIS2 UIDs (`trackedEntity`, `enrollment`, `event`, `orgUnit`, etc.). Always join on the synthesized integer keys (`patient_key`, `enrollment_key`, `event_key`, `department_key`, `hospital_key`, `country_key`, etc.). DHIS2 UIDs may not be present on every tibble (they are schema-gated); integer keys are the relational backbone. When you need a hierarchy key that isn't directly on a fact tibble (e.g. `hospital_key` on patients), join through the parent metadata tibble (`metadata$departments`) which carries it. *(repo-specific)*
- Do not use the R `argparse` package (it requires Python). Use shared `parse-args.R` or JSON parameter files instead. *(repo-specific)*
- **Never** use single letters or bare numbers as YAML keys in string resource files. po4a's YAML module fails to extract some single-letter keys (e.g., `u`), and short keys are not expressive. Use descriptive names instead (e.g., `female`/`male`/`undetermined` instead of `f`/`m`/`u`). When a YAML key must map to a short code from DHIS2, add a mapping in the R code. *(repo-specific)*
- String values must not be duplicated across YAML layers (glossary, common, report-specific) or across report-specific files. If two reports share a string, move it to `common.yaml`. Run `scripts/Test-StringResourceLayers.ps1` to check before committing changes to string resource files. *(repo-specific)*
- The **AMA Manual of Style** is the reference for human-language style questions (capitalisation, punctuation, terminology). The glossary may carry multiple casing variants of a term (e.g., lowercase for running text, title case for headings) — use whichever fits the context. Disease names are common nouns and are lowercase in running text (e.g., "necrotising enterocolitis", "pneumonia") unless they contain a proper noun (e.g., "Crohn's disease"). The sentence-case glossary variants (`_sc`) exist for labels and headings, not because the terms are proper nouns. *(repo-specific)*
- **Never** use imperative voice in Partner Report string resources (outlier interpretation, callout text, or any user-facing prose in `_sR.yaml`). The report cannot know the full clinical context; use suggestive phrasing ("this may indicate…", "…may warrant attention") instead of directives ("Review…", "Confirm…", "Read this…"). *(repo-specific)*
- **Always** use table-visible labels in outlier interpretation strings. The terms in callout prose must match the row labels shown in the corresponding table so readers can identify the referenced metric — but apply running-text casing, not label casing. For example, use "pneumonia" (from the Table 1 row label "Pneumonia") not "HAP", and "CVC-associated sepsis/BSI" (from the Table 2 row label) not "CVC-associated infection rate". When the same metric ID appears in multiple tables with different display labels (e.g., "CVC" in Table 2 vs Table 8), the `localize_metric_name()` function uses `table_name` context to resolve the correct label. *(repo-specific)*
- **Never** edit files that are generated by po4a or by `scripts/update-glossary-po.py`. These files are overwritten on every pipeline run. Generated files include: `common.<lang>.yaml`, `content.<lang>/` directories, `_quarto-<lang>.yml`, `Validation-Report/<lang>/` directories, `doc/protocol/<lang>/`, `glossary.<lang>.yaml`, and any other file that appears as a translation target in `po/*.po4a.cfg`. **Never** edit `.pot` files either — they are regenerated by po4a / the glossary script. When changing translatable content, follow this order: **(1)** edit the English source file (e.g., `common.yaml`, `content/_sR.yaml`, `glossary.yaml`), **(2)** run `scripts/Invoke-Localization.ps1 -Update` (or the appropriate po4a / `scripts/update-glossary-po.py` command) so the pipeline regenerates the `.pot` and updates the `msgid` entries in the `.po` files, **(3)** only then edit `msgstr` values in `po/<scope>.<lang>.po` (or use Weblate) to provide or fix translations against the now-current `msgid`. Editing `.po` files before step 2 risks writing translations against stale `msgid` strings that po4a will mark fuzzy or discard on the next run. *(repo-specific)*
- **Number and unit formatting** — Follow SI conventions where they aid clarity, but prioritise readability across cultural backgrounds and automated layout constraints. Specifically: **(a)** Use the `unit_separator` string resource between a number and its unit (e.g., `50 g`, `39.8 days`); do not hardcode spaces. **(b)** Use the `digit_group_separator` string resource via `format_integer()` / `gt::fmt_number()`; do not hardcode commas, periods, or spaces as thousands separators. **(c)** Use the `percent_symbol` string resource; no space before `%` (ISO 31 recommends a space, but the dominant convention in medical literature omits it). **(d)** Do not use non-breaking spaces (`\u00a0`, `\u202F`) in string resources or code unless a specific, documented line-break problem exists — let the layout engine (LaTeX, HTML) handle line-breaking; if a non-breaking space is needed, add a code comment explaining why. **(e)** Use an en-dash `\u2013` (not a hyphen) between lower and upper CI bounds; parentheses around CIs: `(lower–upper)`. **(f)** For inline rate expressions in running text, use plain spaces around operators; for formal formulas in footnotes, use LaTeX math mode. *(repo-specific)*
- **Always** keep the report PowerShell wrapper scripts (`scripts/Build-*.ps1` — Reference, Partner, Partner-Certificate, Patient-Data, Validation) aligned on any concept that applies across more than one of them: variable and parameter names, helper-call patterns, `$extraFields` / build-report JSON schema, user-facing behaviour and argument surfaces. **(a)** Before adding a new concept (parameter, variable, helper call, JSON field, etc.) to one wrapper script, grep the other wrapper scripts for preexisting implementations and **reuse or extend** existing patterns rather than inventing parallel code. **(b)** When adding a concept that could legitimately apply to other wrapper scripts, **ask the user** whether it should be added to those other scripts in the same pass. **(c)** When reading or editing across multiple wrapper scripts, **proactively assess and highlight any divergence** you notice — even if fixing it is out of the current task's scope, flag it and (per the workspace task-lifecycle rule) capture it as a follow-up task file rather than letting it slip. *(repo-specific)*

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

- **Shared R code**: `reports/common/` — `helpers.R` (locale parsing, string resource loading, DHIS2 connection helpers), `load-neoipcr.R`, `parse-args.R` (CLI arg parsing), `getDataset.R` (dataset export), `logging.R` (unified `logger`-based logging: `configure_logging()` + `logInfo`/`logVerbose`/`logDebug`/`logWarn`/`logError`), `reference.docx` (Word template)
- **Base string resources**: `reports/common.yaml` (English domain terms, table headers, footnotes)
- **Pandoc filters**: `reports/filters/pandoc-quotes.lua` (language-aware typographic quotes)

### Lua Filters

`pandoc-quotes.lua` on all four reports. Empty section headers are suppressed in R (conditional cat-emit gated on the section's `show_section_*` flag), not by a Lua filter.

### R Data Scripts & Docker Deployment

- **R data scripts** (e.g., `Generate-ReferenceData.R`) live alongside their reports. PowerShell wrappers live in `scripts/`. Shared R functions in `reports/common/`.
- **Docker**: The `NeoIPC.Reporting` .NET container (`repos/NeoIPC-Reporting/` in the workspace) downloads report sources from GitHub and renders via Quarto + R. Font and locale changes require Dockerfile updates there.

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
2. Translators work on `.po` files per language (via Weblate or directly)
3. po4a generates localized files (e.g., `Report.de.qmd`, `content.de/_sR.yaml`)

**Translations live in `.po` files, not in YAML.** The localized YAML files (`content.de/_sR.yaml`, `common.de.yaml`, etc.) are *generated* by po4a from `.po` files. Do not edit them directly — edit the `.po` files or use Weblate. If you create a localized YAML file manually, you must import its strings into the `.po` file using `po4a-gettextize`, otherwise po4a will silently remove the translations on the next run.

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

```bash
# From WSL bash (cd to the Surveillance-Toolkit repo root first):
PERLLIB=tools/po4a/lib tools/po4a/po4a <config-file>
PERLLIB=tools/po4a/lib tools/po4a/po4a-gettextize <args>

# From PowerShell on Windows:
wsl -e bash -c "cd $(wsl wslpath -a .) && PERLLIB=tools/po4a/lib tools/po4a/po4a po/reports.po4a.cfg"
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
| `update-glossary-po.py` | Convert `glossary.yaml` to/from monolingual gettext PO (replaces po4a for glossary). Requires `ruamel.yaml` and `polib`. Run after editing `glossary.yaml` to regenerate `.pot` and merge `.po` files. Use `--generate-yaml` to produce localized `glossary.<lang>.yaml`. |

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
6. **Merge with new translations first** (priority order matters). `msgcat --use-first` keeps the first file's translation for duplicate msgids. Put the new translations first so they override any empty entries in the existing `.po`:
   ```bash
   msgcat --use-first /tmp/<report>_<lang>.po po/reports.<lang>.po -o po/reports.<lang>.po
   ```
7. Verify with a round-trip: `PERLLIB=tools/po4a/lib tools/po4a/po4a <config-file>` — check that the generated files match the backup.

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
