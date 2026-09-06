# Changelog — NeoIPC antibiotics list

Notable changes to the antimicrobial-substance domain described in [README.md](README.md).

This product is versioned independently of the others in this repository: its version lives in
[VERSION](VERSION) beside this file, and its releases carry the `antibiotics-v` tag prefix. The
format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

The release workflow reads the section matching the released version out of this file and publishes
it as the GitHub Release body, so a release cannot be cut for a version this file does not describe.

## [0.0.1-alpha] - 2026-07-07

First published version.

### Added

- The canonical antimicrobial-substance source: the DHIS2 `NEOIPC_ANTIMICROBIAL_SUBSTANCES` option
  set with its `ATC5` and `WHO_AWARE` option groups and group-sets, and the substance list printed in
  the Core Protocol.
- `ListElements.csv`, shared with the protocol build so the printed list and the collected option set
  cannot drift apart.
- The list's own `LICENSE.md` and `README.md`, bundled into the release asset so the archive carries
  its attribution and effective licence rather than depending on the repository around it.
- German translations, published alongside the source as gettext catalogues.

### Notes

Scope is systemic antibiotics — essentially the WHO ATC `J01` branch, plus a few deliberately added
systemic non-`J01` substances. Oral non-absorbed, combination and topical agents are out of scope by
design, not by omission.
