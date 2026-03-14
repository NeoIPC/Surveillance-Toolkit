# GitHub Copilot — Surveillance-Toolkit Instructions

This file documents the Surveillance-Toolkit repository. If this repository is checked out as a submodule of the `neoipc-workspace`, the workspace-level `.github/copilot-instructions.md` adds additional workspace-specific guardrails (file boundary, cross-repo change order) on top of the guardrails below.

---

## Guardrails

The first seven rules below are **universal** — mirrored in every NeoIPC repository's instruction files. If you add or change a universal guardrail here, add `<!-- SYNC: propagate to all repos -->` next to it so the change gets propagated when the workspace is next used. The last rule is specific to this repository.

- **Never** put personal names or other identifying information in source code (comments, strings, commit messages, etc.).
- **Never** read, write, or access files under `secrets/`, `data/local/`, or `.env`.
- **Never** push directly to `main` or `master` on this repository.
- **Never** make HTTP calls to the DHIS2 API or attempt to read JSON files returned from the DHIS2 API. These files contain sensitive surveillance data and are not needed for code-level tasks.
- **Never** put absolute local paths into files that get checked in. Use relative paths or generic placeholders. Local checkout paths are developer-specific and meaningless to others.
- Treat infection definitions in this repository as normative. When a conflict exists between code and definitions, **fix the code**, not the definitions.
- **Never** introduce non-permissive dependencies (fonts, libraries, templates). All fonts must be SIL OFL or equivalent.
- **Always** keep `CLAUDE.md` and `.github/copilot-instructions.md` in sync within this repository. When you modify one, apply the same change to the other.
- Do not use the R `argparse` package (it requires Python). Use shared `parse-args.R` or JSON parameter files instead. *(repo-specific)*
- **Never** use single letters or bare numbers as YAML keys in string resource files. po4a's YAML module fails to extract some single-letter keys (e.g., `u`), and short keys are not expressive. Use descriptive names instead (e.g., `female`/`male`/`undetermined` instead of `f`/`m`/`u`). When a YAML key must map to a short code from DHIS2, add a mapping in the R code. *(repo-specific)*

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
```

**Invocation**: The dev checkout must be called with `PERLLIB` set so it finds its own libraries (not system-installed ones):

```bash
# From WSL bash (cd to the Surveillance-Toolkit repo root first):
PERLLIB=~/dev/po4a/lib ~/dev/po4a/po4a <config-file>
PERLLIB=~/dev/po4a/lib ~/dev/po4a/po4a-gettextize <args>

# From PowerShell on Windows (adapt the path to your local checkout):
wsl -e bash -c "cd $(wsl wslpath -a .) && PERLLIB=~/dev/po4a/lib ~/dev/po4a/po4a po/reports.po4a.cfg"
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

1. **Back up existing translated files** before any po4a operation. po4a overwrites generated files (`content.de/_sR.yaml`, `*.de.qmd`, etc.) — only `.po` files are version-controlled, everything else is regenerated. Use a naming convention like `content.de_/` (underscore suffix) for backups.
2. **Run `Update-Po4aYamlKeys.ps1`** if the YAML file has nested keys. po4a's YAML module only extracts values whose keys are explicitly listed in the `keys` option. The script recursively collects all keys from the source YAML and updates the config. Without this, nested keys (e.g., `problems.1.description`, `sex.f`, `admission_type.1`) won't be extracted.
   ```powershell
   ./scripts/Update-Po4aYamlKeys.ps1 -ConfigFile po/reports.po4a.cfg
   ```
3. Add the file entry to the relevant `.po4a.cfg` (if not already present).
4. Use `po4a-gettextize` to import the existing translation into a **temporary** `.po` file:
   ```bash
   PERLLIB=~/dev/po4a/lib ~/dev/po4a/po4a-gettextize -f <format> -m <master> -l <translation> -p /tmp/<report>_<lang>.po
   ```
5. **Remove fuzzy flags** from the gettextize output. `po4a-gettextize` marks most translations as `fuzzy` (even correct ones), and po4a ignores fuzzy translations when generating output. Strip them before merging:
   ```bash
   sed -i 's/^#, fuzzy, /#, /; s/^#, fuzzy$//' /tmp/<report>_<lang>.po
   ```
6. **Merge with new translations first** (priority order matters). `msgcat --use-first` keeps the first file's translation for duplicate msgids. Put the new translations first so they override any empty entries in the existing `.po`:
   ```bash
   msgcat --use-first /tmp/<report>_<lang>.po po/reports.<lang>.po -o po/reports.<lang>.po
   ```
7. Verify with a round-trip: `PERLLIB=~/dev/po4a/lib ~/dev/po4a/po4a <config-file>` — check that the generated files match the backup.

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
