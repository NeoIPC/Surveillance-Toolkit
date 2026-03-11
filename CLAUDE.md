# Claude Code — Surveillance-Toolkit Instructions

This file documents the Surveillance-Toolkit repository. If this repository is checked out as a submodule of the `neoipc-workspace`, see the workspace-level `CLAUDE.md` for cross-cutting instructions.

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

- **Shared R code**: `reports/common/` — `helpers.R` (locale parsing, string resource loading, DHIS2 connection helpers), `load-neoipcr.R`, `parse-args.R` (CLI arg parsing), `getDataset.R` (dataset export), `reference.docx` (Word template)
- **Base string resources**: `reports/common.yaml` (English domain terms, table headers, footnotes)
- **Pandoc filters**: `reports/filters/pandoc-quotes.lua` (language-aware typographic quotes), `remove-empty-sections.lua`

### Lua Filters

`pandoc-quotes.lua` on all four reports. `remove-empty-sections.lua` only on Partner-Report and Reference-Report.

### R Data Scripts & Docker Deployment

- **R data scripts** (e.g., `Generate-ReferenceData.R`) live alongside their reports. PowerShell wrappers live in `scripts/`. Shared R functions in `reports/common/`.
- **Docker**: The `NeoIPC.Reporting` .NET container (`repos/NeoIPC-Reporting/` in the workspace) downloads report sources from GitHub and renders via Quarto + R. Font and locale changes require Dockerfile updates there.

---

## String Resource Cascade

`helpers.R::get_string_resources()` implements a cascading YAML merge for localized string resources. Each report provides a base `content/_sR.yaml` (English), and the cascade overlays language-specific overrides using `modifyList()` (recursive merge).

### Cascade order (lowest → highest priority)

1. `../common.yaml` — shared domain terms (English base)
2. `content/_sR.yaml` — report-specific strings (English base)
3. `../common.<lang>.yaml` — shared domain terms (language override)
4. `../common.<lang>_<territory>.yaml` — shared domain terms (language+territory override)
5. `content.<lang>/_sR.yaml` — report-specific strings (language override)
6. `content.<lang>_<territory>/_sR.yaml` — report-specific strings (language+territory override)

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

- Partner-Report and Reference-Report store the result in `sR` (accessed via `sR$key`)
- Validation-Report stores it in `translations` (accessed via `translations$key`) for historical reasons

### YAML conventions

- Use `>-` (folded, strip trailing newline) for multi-line strings that should be a single paragraph
- Use `|` (literal, keep trailing newline) for strings with intentional newlines (e.g., email templates)
- Use `>` **only** when a trailing newline is intended (rare)
- Quote numeric YAML keys: `"1"`, `"2"`, `"3"` (otherwise YAML interprets them as integers)
- Use the `'bool#no' = function(x) x` handler in `yaml::read_yaml()` to prevent YAML from converting "no" to `FALSE`

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

A recent version is required for all features. Use a git checkout of the master branch:

```bash
# Typical setup (in WSL or Linux/macOS)
cd ~/dev
git clone https://github.com/mquinson/po4a.git
# Run via: ~/dev/po4a/po4a <config-file>
```

### po4a configs (in `po/`)

| Config | Scope |
|--------|-------|
| `reports.po4a.cfg` | Partner-Report, Reference-Report, Partner-Certificate, Validation-Report |
| `documentation.po4a.cfg` | Protocol AsciiDoc files |
| `glossary.po4a.cfg` | Glossary YAML |
| `infectious_agents.po4a.cfg` | Pathogen taxonomy |

### Target languages

af, de, es, et, fr, gr, it, ne, tr (9 languages)

### Helper scripts (in `scripts/`)

| Script | Purpose |
|--------|---------|
| `Update-Po4aYamlKeys.ps1` | Auto-extract YAML keys for po4a config (run after changing YAML structure) |
| `Test-PoPlaceholders.ps1` | Validate placeholder consistency between source and translations |
| `sync-html-to-po-v2.py` | Sync translations from rendered HTML back to `.po` files |

### Importing existing translations

When adding a new file to po4a that already has manual translations:

1. Add the file entry to the relevant `.po4a.cfg`
2. Use `po4a-gettextize` to import the existing translation into the `.po` file:
   ```bash
   po4a-gettextize -f <format> -m <master> -l <translation> -p <po-file>
   ```
3. Verify with a round-trip: `po4a <config-file>` should produce the same output

---

## Report Conventions

### Licensing

**Never** introduce non-permissive dependencies (fonts, libraries, templates). All fonts must be SIL OFL or equivalent. The `reference.docx`/`reference.pptx` templates need auditing for embedded proprietary fonts.

### No Python Dependency

Do not use the R `argparse` package (it requires Python). Use shared `parse-args.R` or JSON parameter files instead.

### Translatable Strings *(Target)*

No `sprintf` `%s`, markdown, or LaTeX syntax in translatable strings. Use `glue`-style `{named}` placeholders (e.g., `{patient_id}`, `{count}`). Apply formatting (bold, links, etc.) in rendering code, not in the string resource. Weblate validates `{name}` placeholders automatically.

### Fonts *(Target)*

- Partner-Report & Reference-Report: EB Garamond primary, Noto Serif Condensed fallback for non-Latin scripts (Greek, Cyrillic, Hebrew, Devanagari, etc.)
- Validation-Report & Partner-Certificate: Noto Sans
- All fonts are SIL Open Font License.

### PowerShell Scripts

Approved PS verbs + PascalCase noun (e.g., `New-PartnerReports.ps1`). All wrappers in `scripts/`. Shared helpers in `scripts/NeoipcReportHelpers.ps1` (dot-sourced).

### Argument Handling

- PS passes parameters to Quarto via `-P key:value` flags
- `dhis2_connection_options()` / `dhis2_dataset_options()` in neoipcr coerce string inputs internally — single source of truth for types and defaults
- Casing per layer: PS `PascalCase` → QMD `camelCase` → R `snake_case`, mapped once at each boundary
- Defaults defined only in neoipcr functions, not duplicated in PS scripts or QMD YAML

### Auth Flow

neoipcr is the single auth authority. PS scripts resolve credentials via `Resolve-NeoipcAuth` (token or username/password), then set scoped environment variables (`NEOIPC_DHIS2_TOKEN`, `NEOIPC_DHIS2_USER`, `NEOIPC_DHIS2_PASSWORD`) so neoipcr in child R/Quarto processes finds them automatically. No `-P "token:..."` in QMD renders.

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
