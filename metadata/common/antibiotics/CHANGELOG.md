# Changelog — NeoIPC Antibiotics List

Notable changes to the antimicrobial-substance domain described in [README.md](README.md).

This product is versioned independently of the others in this repository: its version lives in
[VERSION](VERSION) beside this file, and its releases carry the `antibiotics-v` tag prefix. The
format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

The release workflow reads the section matching the released version out of this file and publishes
it as the GitHub Release body, so a release cannot be cut for a version this file does not describe.

## [0.2.0-alpha] - 2026-11-28

### Added

- `WHO-AWaRe-Classification-2025.csv`, a faithful extract of the classification worksheet of the
  2025 edition of the WHO AWaRe classification (doi:10.2471/B09489) — all 268 classified antibiotics
  with their ATC codes, categories and 2025 EML flag.
- The Pester content check `scripts/modules/NeoIPC-Tools/Tests/AntibioticsContent.Tests.ps1`: every
  substance's `aware_category` must match the extract, and the attribution must name the edition the
  fold follows.

### Changed

- `README.md`: the section on why this catalogue is not on Weblate notes the infectious-agent list's factual-extract
  terms beside its catalogue's, and why neither transfers to this list: apart from NeoIPC's own nodes and the few
  nodes it places otherwise, each with a note, that list's lineage is a classification of how the infectious agents
  are related, as its sources publish it, while an ATC
  group and an AWaRe category sort substances by schemes made for drug-utilization studies and antibiotic
  stewardship. The substance names are described as display forms of International Nonproprietary Names, not as
  reproduced from the ATC/DDD index.
- The `aware_category` fold now follows the **2025** AWaRe classification. One option changes against
  the 2021 fold: ticarcillin/clavulanic acid (`J01CR03`), which it left without a category, is now
  **Watch**; the other 243 options keep the category the 2021 fold had them in.
- The three AWaRe group `description`s are re-summarized to the 2025 definitions, and the
  `WHO_AWARE` option-group-set description repeats the same summaries. Access is no
  longer described as narrow-spectrum — the 2025 classification gives it activity against a wide
  range of commonly encountered susceptible infectious agents, with lower resistance potential; Watch
  carries the resistance-potential and stewardship-monitoring emphasis, Reserve the last-resort
  restriction on use against multidrug-resistant infectious agents. No locale had translated these
  three strings, so the catalogues regenerate with the new source strings and empty translations.
- The two non-J01 ATC groups take the ATC/DDD index's own level-4 names, so every group name is now
  the index's verbatim: `J04AB` becomes "Antibiotics" and `P01AB` "Nitroimidazole derivatives".
- The attribution names the 2025 edition (doi:10.2471/B09489) in place of the 2021 publication
  (WHO/MHP/HPS/EML/2021.04), and records the ATC codes and group names as following the 2026
  ATC/DDD index.

## [0.1.0-alpha] - 2026-09-07

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
- German and Spanish translation catalogues (`po/antibiotics.de.po`, `po/antibiotics.es.po`),
  published alongside the source.
