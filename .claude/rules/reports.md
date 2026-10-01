---
paths: "reports/**"
---

## Reports

- **Never** invent or paraphrase clinical definitions, thresholds, or measurement criteria. Always look up the normative text in `doc/protocol/` (or the relevant definition file) before writing or modifying footnotes, tooltips, or explanatory text that describes how a metric is defined or measured. If no protocol definition exists for the concept, flag it rather than guessing. *(repo-specific)*
- **Never** add an unconditional reference (formal `@tbl-*`/`@fig-*` or textual) to content that is conditionally included. If a table, figure, section, or any content depends on a configuration flag, all references to it must be conditional on the same flag. This applies to all conditionally present content: tables, figures, sections, reference data, confidence intervals, and any other content whose presence depends on configuration. When a text contains a cross-reference to conditional content, split it into a base string (always shown) and a conditional suffix (shown only when the target is present), provide two complete variants, or use a glue placeholder that resolves to the cross-reference when the target is present and to empty when it is not. *(repo-specific)*
- **Never** use imperative voice in Partner Report string resources (outlier interpretation, callout text, or any user-facing prose in `_sR.yaml`). The report cannot know the full clinical context; use suggestive phrasing ("this may indicate…", "…may warrant attention") instead of directives ("Review…", "Confirm…", "Read this…"). *(repo-specific)*
- **Always** use table-visible labels in outlier interpretation strings. The terms in callout prose must match the row labels shown in the corresponding table so readers can identify the referenced metric — but apply running-text casing, not label casing. For example, use "pneumonia" (from the Table 1 row label "Pneumonia") not "HAP", and "CVC-associated sepsis/BSI" (from the Table 2 row label) not "CVC-associated infection rate". When the same metric ID appears in multiple tables with different display labels (e.g., "CVC" in Table 2 vs Table 8), the `localize_metric_name()` function uses `table_name` context to resolve the correct label. *(repo-specific)*
- **Number and unit formatting** — Follow SI conventions where they aid clarity, but prioritize readability across cultural backgrounds and automated layout constraints. Specifically: **(a)** Use the `unit_separator` string resource between a number and its unit (e.g., `50 g`, `39.8 days`); do not hardcode spaces. **(b)** Use the `digit_group_separator` string resource via `format_integer()` / `gt::fmt_number()`; do not hardcode commas, periods, or spaces as thousands separators. **(c)** Use the `percent_symbol` string resource; no space before `%` (ISO 31 recommends a space, but the dominant convention in medical literature omits it). **(d)** Do not use non-breaking spaces (`\u00a0`, `\u202F`) in string resources or code unless a specific, documented line-break problem exists — let the layout engine (LaTeX, HTML) handle line-breaking; if a non-breaking space is needed, add a code comment explaining why. **(e)** Use an en-dash `\u2013` (not a hyphen) between lower and upper CI bounds; parentheses around CIs: `(lower–upper)`. **(f)** For inline rate expressions in running text, use plain spaces around operators; for formal formulas in footnotes, use LaTeX math mode. *(repo-specific)*
- Say "patients" in user-facing report text (captions, table labels, cover summaries), and keep "patient records" and "patient admissions" for technical text that explains the records-versus-admissions distinction, such as an introduction defining the denominators. *(repo-specific)*
- Avoid footnote overload in tables: the formula footnote names the denominator and the N column shows the counts, so denominator context goes into the introduction, and footnotes are kept for what concerns one cell or row. *(repo-specific)*

## Report Locations

Reports live under `reports/`:

- **Partner Report:** `reports/Partner-Report/`
- **Reference Report:** `reports/Reference-Report/`
- **Validation Report:** `reports/Validation-Report/`
- **Partner Certificate:** `reports/Partner-Certificate/`
- **Patient Data Report:** `reports/Patient-Data-Report/`

## Report Architecture

### Shared Infrastructure

- **Shared R code**: `reports/common/` — `helpers.R` (locale parsing, string resource loading, DHIS2 connection helpers), `load-neoipcr.R`, `parse-args.R` (CLI arg parsing), `getDataset.R` (dataset export), `logging.R` (unified `logger`-based logging: `configure_logging()` + `logInfo`/`logVerbose`/`logDebug`/`logWarn`/`logError`, plus `with_error_trace()` to log a full backtrace when a render-time computation fails), `reference.docx` (Word template)
- **Base string resources**: `reports/common.yaml` (English domain terms, table headers, footnotes)
- **Pandoc filters**: `reports/filters/pandoc-quotes.lua` (language-aware typographic quotes)

### Lua Filters

Every report runs `pandoc-quotes.lua`. Empty section headers are suppressed in R (conditional cat-emit gated on the section's `show_section_*` flag), not by a Lua filter.

### Validation Report

The rules live in neoipcr (`neoipcr::validate()` returns keys and context values, never prose); the report only renders them, interpolating each finding's context into the `{named}` placeholders of `content/_sR.yaml` — the placeholder names are the context field names documented on `validate()`, plus the labels `context_decorations` in `_mapping.qmd` adds for the coded values a sentence shows. Do not add a rule or a formatter on the report side; a rule's sentence and summary belong here, in `content/_sR.yaml`, and nowhere else. See [`docs/validation-report.md`](../../docs/validation-report.md) for the layering and for how a new rule threads through both repositories. [`docs/validation-rule-coverage.md`](../../docs/validation-rule-coverage.md) maps every constraint of the Core Protocol to the rules and the capture-time program rules that enforce it and says who can act on a finding; a new rule is entered there against its protocol anchor, and a finding the partner cannot see in Tracker Capture never belongs to this report: it is a reconciliation by the NeoIPC coordinating centre, as that document describes, when it is a contradiction under the protocol whose intended state can be inferred, and no rule at all otherwise.

### R Data Scripts & Docker Deployment

- **R data scripts** (e.g., `Generate-ReferenceData.R`) live alongside their reports. PowerShell wrappers live in `scripts/`. Shared R functions in `reports/common/`.
- **Docker**: The `NeoIPC.Reporting` .NET container (its own repository, `NeoIPC/NeoIPC-Reporting` on GitHub) clones this repository's report sources at image-build time and renders them via Quarto + R. Font and locale changes therefore require a Dockerfile update **there**, not here — adding a font to a report in this repository does not put it in the rendering image.

## Report Conventions

### Translatable Strings

No `sprintf` `%s`, markdown, or LaTeX syntax in translatable strings. Use `glue`-style `{named}` placeholders (e.g., `{patient_id}`, `{count}`). Apply formatting (bold, links, etc.) in rendering code, not in the string resource. Weblate validates `{name}` placeholders automatically.

### Fonts

- Partner-Report & Reference-Report: EB Garamond, which covers Latin, Greek, and Cyrillic. Their PDF figures are in Noto Sans, drawn with the Cairo device so the font is embedded, as PDF/A-4 requires. Noto Sans and every Noto Sans family it falls back to for ≥ and other scripts come from the Noto project's static OTFs, which are Compact Font Format (CFF) fonts, because Cairo embeds a TrueType font's glyphs outside WinAnsi without the `CIDToGIDMap` entry PDF/A-4 also requires; and fontconfig has to leave out their TrueType builds and DejaVu, or Noto Sans falls back to a TrueType font. `scripts/modules/NeoIPC-Tools/Tests/ReportFigureDevice.Tests.ps1` holds both reports to the Cairo device.
- Validation-Report, Partner-Certificate & Patient-Data-Report: Noto Sans.
- All fonts are SIL Open Font License.
- The Partner and Reference Reports configure no body-text fallback for the scripts EB Garamond lacks, such as Hebrew and Devanagari, so body text in those scripts renders without glyphs.

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

Under Quarto/knitr, `configure_logging()` cannot install `logger`'s global warning/message handlers (knitr's own are already on the stack), so it registers knitr output hooks that route each render-time warning and message into the log channel and return `""` to keep it out of the report body. Two invariants follow. **(1)** That hook is the *only* thing keeping raw conditions out of the rendered PDF/HTML — a chunk-level `warning=FALSE`/`message=FALSE` drops the condition before the hook can log it — so `configure_logging()` must run before any condition-raising code (every report `_setup.qmd` installs it before, or at the top of, its first import chunk). **(2)** Render-time condition text is a **logged surface**: keep the text of warnings and messages to aggregates and structural text, never record-level identifiers. The DHIS2 query-trace boundary in `log_dhis2_request` (URL + status + row count, never bodies) is separate and unaffected.
