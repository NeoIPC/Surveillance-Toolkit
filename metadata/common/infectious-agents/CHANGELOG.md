# Changelog — NeoIPC Infectious Agent List

Notable changes to the infectious-agent ontology described in [README.md](README.md).

This product is versioned independently of the others in this repository: its version lives in
[VERSION](VERSION) beside this file, and its releases carry the `infectious-agents-v` tag prefix. The
format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

The release workflow reads the section matching the released version out of this file and publishes
it as the GitHub Release body, so a release cannot be cut for a version this file does not describe.

## [Unreleased]

### Added

- CI checks of the list: its keys and structure; every node's `Id`, `Name`, rank, source, and record number, and the
  form each typed value takes in the file; the option labels generated from it; its UID sidecar; the two frozen
  CSVs; and that it stays append-only against every released version, so that a released `Id` keeps its name, a
  deployed option keeps its UID, a new `Id` exceeds every released one, and a released `Id` never disappears, except
  from a branch that maintains an earlier line, which need not carry a later line's `Id`s.
- CI checks that the list keeps to YAML 1.2.2's portable subset, which YAML 1.1, YAML 1.2.2, and the YAML readers
  the toolkit meets read alike, and that those readers read it alike.

### Changed

- `LICENSE.md`: factual extracts of the list, outputs that carry nothing but `Id`s, names and synonyms, ranks and
  lineage, source records, and the statuses NeoIPC assigns, such as the Core Protocol's list of infectious agents,
  neoipcr's tables, and the reports' infectious-agent tables, fall outside the directory's CC BY-NC-ND 4.0 terms.
- `README.md`: which files are frozen and who reads them, what CI checks, and how the ontology is reconciled with
  its sources.
- In `NeoIPC-Infectious-Agents.yaml`, `ListTerms`' `Yes` is quoted, so that a YAML 1.1 reader reads it as text
  rather than as a Boolean. The per-locale overlays, which po4a writes, have it plain.

### Deprecated

- `NeoIPC-Pathogen-Concepts.csv` and `NeoIPC-Pathogen-Synonyms.csv` are frozen: kept byte for byte for the readers
  outside this repository that download them, a legacy reporting service and neoipcr's data-preparation script, and
  to be removed once neither does and the Core Protocol's list of infectious agents is built from the ontology.

## [0.1.0-alpha] - 2026-09-07

### Changed

- `ListElements.csv` and its translations label the recognized-pathogen column in the house spelling
  (`recognized_pathogen`, "Recognized pathogen"). The file is among the sources a protocol or metadata
  release checks against the list release it incorporates, so those products pick the change up only
  through a new list release.
- `LICENSE.md` and `README.md` state the scope of the directory's licence terms: they cover the
  directory's content and not the gettext catalogue `po/infectious_agents.*`, which carries only names,
  rank labels, controlled values and NeoIPC's own header and footer prose and is published under
  CC BY 4.0. `README.md` also documents how `CommonCommensal` and the resistance flags are inherited
  down the tree, and that a concept is a virus by descending from the `Viruses` realm.

### Fixed

- The translation sidecars `NeoIPC-Pathogen-Concepts.<lang>.csv` and
  `NeoIPC-Pathogen-Synonyms.<lang>.csv` no longer begin with a byte-order mark.

## [0.0.1-alpha] - 2026-07-07

First published version.

### Added

- `NeoIPC-Infectious-Agents.yaml`, the canonical hierarchical ontology of infectious agents with their
  synonyms and metadata, from which the DHIS2 `NEOIPC_PATHOGENS` option set is generated. The printed
  pathogen list in the Core Protocol and the neoipcr package still read the legacy
  `NeoIPC-Pathogen-Concepts.csv` and `NeoIPC-Pathogen-Synonyms.csv` kept beside it; a protocol or
  metadata release checks the ontology and those CSVs together against the list release it
  incorporates.
- `NeoIPC-Infectious-Agents.uids.csv`, mapping each option code to the DHIS2 UID the deployment
  already assigned, so a generated option set keeps the deployed identities.
- `ListElements.csv`, the heading and value labels of the printed pathogen table, with their
  `.<lang>.csv` translations.
- The list's own `LICENSE.md` and `README.md`, bundled into the release asset so the archive carries
  its attribution and effective licence independently of the repository around it.
- Per-language `NeoIPC-Infectious-Agents.<lang>.yaml` overlays, generated from the gettext catalogues
  under `po/` and bundled with the release; German is the translated catalogue.
