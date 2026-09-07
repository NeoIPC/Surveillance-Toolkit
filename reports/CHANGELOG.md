# Changelog — NeoIPC reports

Notable changes to the render-ready report sources: the Partner Report, Reference Report, Validation
Report, Partner Certificate and Patient Data Report, together with the shared `common/` layer and the
localized string resources they draw on.

This product is versioned independently of the others in this repository: its version lives in
[VERSION](VERSION) beside this file, and its releases carry the `reports-v` tag prefix. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

The release workflow reads the section matching the released version out of this file and publishes
it as the GitHub Release body, so a release cannot be cut for a version this file does not describe.

## [Unreleased]

## [0.1.0-alpha] - 2026-09-07

### Added

- Every PDF is rendered with LuaLaTeX and declares archival PDF/A-4. PDF/UA is deliberately not
  declared: it requires tagged structure, which the KOMA-Script document class cannot emit, and a
  conformance the file does not have is worse than none. The two distribution figures and the
  certificate's signature carry alt text from the localized string cascade; the title-page logos
  carry the fixed alt text `NeoIPC`.
- An opt-in `audit` profile (`quarto render --profile audit`) that overlays axe-core WCAG 2.1 AA checks
  on the four reports that produce HTML; it never composes into a default render, so partner-facing
  and service HTML never carry the bundle.
- A render failure inside neoipcr is logged with a full R backtrace on the report's log channel instead
  of an opaque one-line error.
- The Partner Report says above its comparison when an uploaded dataset's embedded benchmark superseded
  the reference named in the request, since everything below then describes the benchmark that was
  used rather than the one asked for.

### Changed

- The distribution figures' sample-size captions count the patients the figure covers — those with a
  recorded birth weight or gestational age, as neoipcr's figure data now supplies them — rather than
  all patients.
- The Reference Report takes a `departmentFilter` parameter, and `Generate-ReferenceData.R` a
  `--departmentFilter` option, in place of the `hospitalFilter` parameter, which nothing consumed:
  surveillance is observed at department level.
- The report text follows the house spelling — Oxford British, taking the `-ize` form where it is also
  valid American English — so "Antibiotic Utilization" and the table and methods sources named after
  it are renamed accordingly.
- `compatibility.yml` declares neoipcr `v0.0.0.9001`, the first release carrying the exported
  `get_antibiotic_utilization_table()` these reports call, so the declared floor is the one the
  sources actually need.
- A dataset serialized before the antibiotic table was renamed is still read, under the name it was
  written with. The rename is a source-level change only, and a saved dataset is not migrated by it.

### Fixed

- Translated text that interpolates a value rendered an R error in place of the sentence, immediately
  before a table, and every following table lost its footnote while the render reported success. The
  values are now forced before interpolation, and an unnamed or zero-length argument is refused.
- A table footnote that is display math no longer leaves LaTeX a line break with no line to end — a
  construct untagged LaTeX tolerates and the `\DocumentMetadata` tagging that PDF/UA requires rejects.

## [0.0.1-alpha] - 2026-07-07

First published version. The reports render English only: `reports/.gitignore` ignores the
po4a-generated `_quarto-<lang>.yml` language profiles and keeps only `_quarto-en.yml`, and the
NeoIPC-Reporting service's `RenderReadyLanguages` option lists the languages it offers. That set is a
deliberate declaration rather than the set of catalogues that exist, so a language appears when its
output is correct rather than when its translation begins.

### Added

- The five report sources and the shared `common/` layer they build on: locale resolution, the string
  resource cascade, the formatters, and the argument parsing the wrappers hand them.
- `compatibility.yml`, declaring the neoipcr and neoipc-app versions these reports are tested against
  and require. The reporting image pins this product by release tag and matches the two records
  against each other, so an image cannot bake in a neoipcr the reports were never rendered with.
