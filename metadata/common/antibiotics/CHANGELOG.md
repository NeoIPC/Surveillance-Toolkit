# Changelog — NeoIPC antibiotics list

Notable changes to the antimicrobial-substance domain described in [README.md](README.md).

This product is versioned independently of the others in this repository: its version lives in
[VERSION](VERSION) beside this file, and its releases carry the `antibiotics-v` tag prefix. The
format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

The release workflow reads the section matching the released version out of this file and publishes
it as the GitHub Release body, so a release cannot be cut for a version this file does not describe.

## [Unreleased]

### Changed

- The translation catalogue `po/antibiotics.pot` + `po/antibiotics.<lang>.po` is maintained in this
  repository rather than on Hosted Weblate, whose free plan requires a free licence; the list's
  CC BY-NC-SA 3.0 IGO terms are not one, so translations are contributed by pull request.

### Removed

- The `description` column of `NeoIPC-Antibiotic-Groups.csv`, and with it the description on the
  generated ATC option groups. Only 17 of the 34 groups carried one, nothing consumed them, and as
  verbatim prose from the WHO Collaborating Centre for Drug Statistics Methodology they were the
  directory's largest block of reproduced upstream text.

## [0.0.1-alpha] - 2026-07-07

First published version. Its scope is systemic antibiotics — essentially the WHO ATC `J01` branch,
plus a few deliberately added systemic non-`J01` substances; oral non-absorbed, combination and topical
agents are out of scope by design, not by omission.

### Added

- `NeoIPC-Antibiotics.csv`, the canonical antimicrobial-substance source — one row per DHIS2 option,
  with its ATC group and AWaRe category — from which both the DHIS2 `NEOIPC_ANTIMICROBIAL_SUBSTANCES`
  option set with its `ATC5` and `WHO_AWARE` option groups and group-sets and the substance list
  printed in the Core Protocol are generated, so the printed list and the collected option set cannot
  drift apart. The group tables it joins, `NeoIPC-Antibiotic-Groups.csv` and
  `NeoIPC-Antibiotic-AWaRe-Groups.csv`, ship beside it.
- `ListElements.csv`, the printed table's column labels.
- The list's own `LICENSE.md` and `README.md`, bundled into the release asset so the archive carries
  its attribution and effective licence rather than depending on the repository around it.
- German translations, published alongside the source as gettext catalogues.
