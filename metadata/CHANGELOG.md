# Changelog — NeoIPC DHIS2 metadata

Notable changes to the DHIS2 metadata package: the `NEOIPC_CORE` program and everything it is
assembled from — data elements, tracked-entity attributes, program stages and sections, option sets,
program rules and validation rules — together with the data dictionary rendered from it.

This product is versioned independently of the others in this repository: its version lives in
[VERSION](VERSION) beside this file, and its releases carry the `metadata-v` tag prefix. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

The release workflow reads the section matching the released version out of this file and publishes
it as the GitHub Release body, so a release cannot be cut for a version this file does not describe.

## [Unreleased]

## [0.1.0-alpha] - 2026-09-07

### Added

- `NEOIPC_HAP_IT_RATIO`, the I/T ratio (immature to total granulocytes) above 0.2, as its own
  clinical/laboratory criterion of the Pneumonia stage — a data element, its rule variables and the
  rule that counts it — so the deployed definition counts at least 4 of 9 criteria, as the protocol
  does.
- An authored `code` on every first-class object — program rules and rule variables, program stages,
  stage sections, program sections, program indicators, organisation-unit levels and the tracked-entity
  type — as the stable identity the externalized expression files and the translation keys are keyed
  by. Program-rule actions deliberately stay code-less.
- A `shortName` on the tracked-entity type, which DHIS2 2.42 and later require; without it the import
  dropped the type together with its attributes and the program link.

### Changed

- The package incorporates the infectious-agent and antibiotics lists at `0.1.0-alpha`. Two of their
  changes reach the generated metadata: the recognized-pathogen column is relabelled in the house
  spelling, and the generated ATC option groups no longer carry a description, because the column that
  supplied it is gone from the antibiotics group table.
- The generated organism-membership rules — the resistance categories, the recognized-pathogen and the
  virus rules — build their `||` chains as balanced trees, so the DHIS2 2.41 engine, which evaluates
  them by recursion, no longer overflows its stack. The Pneumonia "set virus" rule is generated from
  the ontology's `Viruses` subtree rather than hand-authored; the hand-authored rule had drifted to 155
  of the ontology's 212 virus codes.
- The two gestational-age conditions use escape-free character classes, so they match identically on
  the 2.40 legacy engine and on the 2.41 expression parser, which reads a `d2:validatePattern` pattern
  raw.
- Names and descriptions follow the house spelling (Oxford British, `-ize`).
- `NEOIPC_USER_MANAGERS` no longer lists itself among its `managedGroups`: DHIS2 2.42 and later do not
  persist the self-reference, and self-management is not an intended capability.
- The generated translations omit an entry identical to the object's base value, which DHIS2 falls
  back to anyway.
- The manifest declares DHIS2 `2.40.12.0`, and `dist/README.md` states what is verified: the package
  is checked against 2.40.12.0 and 2.41.9.0; it must be imported twice, because DHIS2 does not link an
  object's owned reference collections to objects created in the same payload and reports `status=OK`
  either way; and on 2.42 and 2.43 an import intermittently drops the members of owned ordered
  collections while reporting success.

### Removed

- The inert "NeoIPC BSI Debug rule".

## [0.0.1-alpha] - 2026-07-07

First published version. The canonical source is this directory's `common/` tree — the CSVs and the
externalized expression files they reference — not any exported snapshot of a deployed instance: a
snapshot mirrors what is deployed; this is what deployments are built from.

### Added

- The assembled metadata package, importable into a DHIS2 instance, and the data dictionary rendered
  from the same source so the documentation cannot describe a different configuration than the one
  that imports.
- `compatibility.yml`, recording the versions of the two shared lists this package incorporates. The
  release build verifies that record byte-for-byte against the released lists, so a metadata release
  cannot claim a list version whose content it does not actually carry.
