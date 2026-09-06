# Changelog — NeoIPC DHIS2 metadata

Notable changes to the DHIS2 metadata package: the `NEOIPC_CORE` program and everything it is
assembled from — data elements, tracked-entity attributes, program stages and sections, option sets,
program rules and validation rules — together with the data dictionary rendered from it.

This product is versioned independently of the others in this repository: its version lives in
[VERSION](VERSION) beside this file, and its releases carry the `metadata-v` tag prefix. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

The release workflow reads the section matching the released version out of this file and publishes
it as the GitHub Release body, so a release cannot be cut for a version this file does not describe.

## [0.0.1-alpha] - 2026-07-07

First published version.

### Added

- The assembled metadata package, importable into a DHIS2 instance, and the data dictionary rendered
  from the same source so the documentation cannot describe a different configuration than the one
  that imports.
- `compatibility.yml`, recording the versions of the two shared lists this package incorporates. The
  release build verifies that record byte-for-byte against the released lists, so a metadata release
  cannot claim a list version whose content it does not actually carry.

### Notes

The canonical source is this directory's `common/` tree — the CSVs and the externalized expression
files they reference — not any exported snapshot of a deployed instance. A snapshot mirrors what is
deployed; this is what deployments are built from.
