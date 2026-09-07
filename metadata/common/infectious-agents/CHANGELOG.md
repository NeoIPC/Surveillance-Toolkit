# Changelog — NeoIPC infectious-agents list

Notable changes to the infectious-agent ontology described in [README.md](README.md).

This product is versioned independently of the others in this repository: its version lives in
[VERSION](VERSION) beside this file, and its releases carry the `infectious-agents-v` tag prefix. The
format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

The release workflow reads the section matching the released version out of this file and publishes
it as the GitHub Release body, so a release cannot be cut for a version this file does not describe.

## [Unreleased]

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
