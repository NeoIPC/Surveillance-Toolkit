# Changelog — NeoIPC reports

Notable changes to the render-ready report sources: the Partner Report, Reference Report, Validation
Report, Partner Certificate and Patient Data Report, together with the shared `common/` layer and the
localized string resources they draw on.

This product is versioned independently of the others in this repository: its version lives in
[VERSION](VERSION) beside this file, and its releases carry the `reports-v` tag prefix. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

The release workflow reads the section matching the released version out of this file and publishes
it as the GitHub Release body, so a release cannot be cut for a version this file does not describe.

## [0.0.1-alpha] - 2026-07-07

First published version.

### Added

- The five report sources and the shared `common/` layer they build on: locale resolution, the string
  resource cascade, the formatters, and the argument parsing the wrappers hand them.
- `compatibility.yml`, declaring the neoipcr versions these reports are tested against and require.
  The reporting image pins this product by release tag and matches the two records against each
  other, so an image cannot bake in a neoipcr the reports were never rendered with.

### Notes

Reports render English only at present: the render-ready language set is a deliberate declaration
rather than the set of catalogues that exist, so a language appears here when its output is correct
rather than when its translation begins.
