# Changelog — NeoIPC infectious-agents list

Notable changes to the infectious-agent ontology described in [README.md](README.md).

This product is versioned independently of the others in this repository: its version lives in
[VERSION](VERSION) beside this file, and its releases carry the `infectious-agents-v` tag prefix. The
format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

The release workflow reads the section matching the released version out of this file and publishes
it as the GitHub Release body, so a release cannot be cut for a version this file does not describe.

## [0.0.1-alpha] - 2026-07-07

First published version.

### Added

- `NeoIPC-Infectious-Agents.yaml`, the canonical hierarchical ontology of infectious agents with
  their synonyms and metadata — the single source of truth from which the DHIS2 causative-pathogen
  pickers, the printed pathogen reference list, and the consumer-side helpers in neoipcr and the
  reports are all derived.
- `ListElements.csv`, shared with the protocol build so the printed list and the collected option set
  describe the same organisms.
- The list's own `LICENSE.md` and `README.md`, bundled into the release asset so the archive carries
  its attribution and effective licence independently of the repository around it.
- German translations, published alongside the source as gettext catalogues.
