# Antibiotics

The canonical source of the NeoIPC antimicrobial-substance domain: the DHIS2 `NEOIPC_ANTIMICROBIAL_SUBSTANCES`
option set, its `ATC5` / `WHO_AWARE` option groups & group-sets, and the printed Core-Protocol antibiotic list.

**Scope: systemic antibiotics only** — essentially the WHO ATC `J01` branch ("Antibacterials for systemic use")
plus a few deliberately-added systemic non-J01 substances (e.g. Rifampicin, Secnidazole); oral/non-absorbed,
combination and topical agents are excluded.

**Conventions for editing these files:**

- **Codes are append-only** — a stored data value *is* the option `id`, so never rename or remove one. A new
  substance takes its WHO ATC-7 code as `id`; an ATC-less substance uses a `tmp_NNN` id; an `_O` / `_P` route suffix
  is used only where the oral and parenteral forms fall in **different** AWaRe categories.
- **Names** are the clinician-facing display forms (e.g. "Amoxicillin/Clavulanic-acid", "Minocycline (i. v.)").
- **At most one group per group-set** — `atc_group` selects the substance's single ATC group and `aware_category`
  its single AWaRe group. A substance placed in two groups of the same set corrupts the downstream report
  aggregation.

## Files

| File | Contents |
|------|----------|
| `NeoIPC-Antibiotics.csv` | The substance/option table — `id, atc_code, name, atc_group, aware_category`. One row per DHIS2 option (the **systemic** antibiotics — the WHO ATC `J01` branch plus a few deliberately-added systemic non-J01 substances). The WHO **AWaRe** classification is folded in as the `aware_category` column. |
| `NeoIPC-Antibiotic-Groups.csv` | The 34 WHO ATC **level-4** chemical subgroups — `code, name, shortName, description`. A substance joins a group by its `atc_group` column; the `ATC5` option-group-set is built from these. |
| `NeoIPC-Antibiotic-AWaRe-Groups.csv` | The 3 WHO **AWaRe** groups — `code, category, name, shortName, description`. A substance joins by its `aware_category`; the `WHO_AWARE` option-group-set is built from these. |
| `ListElements.csv` | The printed-list UI labels (the `New-AntibioticsList` table headers). |

The DHIS2 metadata (option set + option groups + group-sets, with localized `translations[]`) is **generated** from
these sources by the NeoIPC-Tools pipeline — they are not hand-maintained DHIS2 objects. The DHIS2 UIDs are
preserved from the deployment.

## Translations

Antibiotic translations live in a single bilingual gettext component **`po/antibiotics.pot` + `po/antibiotics.<lang>.po`**,
keyed by the English string. It covers the substance names, all antibiotic group / group-set names, shortNames and
descriptions, and the printed-list UI labels. Regenerate it with `./scripts/Invoke-Localization.ps1 -Update -Config antibiotics`
(or as part of `-Config all`). The previous `NeoIPC-Antibiotics.<lang>.csv` / `ListElements.<lang>.csv` translation
sidecars and the standalone `WHO-AWaRe-Classification-2021.csv` are **retired** (folded into the files above + the PO).

## Attribution

- **WHO ATC/DDD** — the ATC codes, the substance names and the ATC group names/descriptions are based on
  information from the [WHO Collaborating Centre for Drug Statistics Methodology, Oslo](https://www.whocc.no/)
  ([ATC/DDD copyright & disclaimer](https://atcddd.fhi.no/copyright_disclaimer/)). Reproduced here for NeoIPC's
  **non-commercial** infection-surveillance use, with attribution; the ATC classification is reproduced unchanged
  (translations are added localizations, not alterations of the classification). To keep WHO ATC *codes* out of the
  public translation files, the translation catalogue is keyed by the English **name**, never the ATC code.
- **WHO AWaRe** — Access, Watch, Reserve (AWaRe) classification of antibiotics, 2021. Geneva: World Health
  Organization; 2021 (WHO/MHP/HPS/EML/2021.04).
  <https://www.who.int/publications/i/item/2021-aware-classification>. Licence:
  [CC BY-NC-SA 3.0 IGO](https://creativecommons.org/licenses/by-nc-sa/3.0/igo/).
