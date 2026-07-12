# Infectious Agents

This directory contains the NeoIPC infectious-agent ontology used to populate causative-pathogen pickers in DHIS2, render the printed pathogen reference list, and drive consumer-side helpers in neoipcr and the reports.

## Contents

| File | Purpose |
|------|---------|
| `NeoIPC-Infectious-Agents.yaml` | **Canonical** hierarchical ontology of infectious agents, their synonyms, and metadata. Single source of truth. |
| `NeoIPC-Infectious-Agents.<lang>.yaml` | Per-locale translation overlay generated from the po4a pipeline (do not edit by hand — see [the repo `CLAUDE.md` po4a section](../../../CLAUDE.md)). |
| `NeoIPC-Infectious-Agents.uids.csv` | The `id,uid` sidecar mapping each option code (the YAML `Id`) to its DHIS2 option **UID** (source identity for the generated `NEOIPC_PATHOGENS` option set, so generation no longer reads UIDs from the export). Holds only the **deployed** codes; an `Id` absent from it (a not-yet-deployed organism) is minted deterministically on generation. The option **set**'s own UID is a NeoIPC-Tools module constant. These are the UIDs the deployment already assigned. |
| `NeoIPC-Owned-Pathogen-Concepts.csv` | Classification of NeoIPC-owned concepts (`pathogen_type`, `concept_type`). Consumed by `Build-NeoIPCCoreProtocol.ps1`. |
| `ListElements.csv` / `ListElements.<lang>.csv` | UI/report list-element labels used by `Convert-InfectiousAgentList.ps1` when rendering the pathogen reference document. |
| `AsciiDoc-PDF.yml` | Asciidoctor-PDF theme for the rendered pathogen reference document. |
| `Output-Header.adoc` / `Output-Footer.adoc` (+ per-locale variants) | AsciiDoc preamble/postamble for the rendered pathogen reference document. |
| `NeoIPC-Pathogen-Concepts.csv`, `NeoIPC-Pathogen-Synonyms.csv` (+ per-locale variants) | **Legacy, unmaintained.** Flat-CSV representation predating the YAML, scheduled for removal. Do not consult for ontology questions; use the YAML. |

## Adding an entry

Every entry in `NeoIPC-Infectious-Agents.yaml` carries a unique integer `Id:` (used as the option-code in DHIS2 and as the join key in downstream tools). To find the next unused integer:

```powershell
Import-Module ./scripts/modules/NeoIPC-Tools
Find-NextFreeInfectiousAgentId
```

The cmdlet returns `max(existing Id:) + 1`. Gaps left by retired entries are not refilled — IDs are append-only, so a retired ID stays retired and out-of-band downstream consumers don't have to worry about it being silently reused.

## Ontology structure: flag inheritance and virus classification

The ontology is a tree: every node may carry child nodes under `Hierarchies`, `Synonyms`, and `Children`. **A synonym is a first-class, Id-bearing, selectable option**, not just a display alias — a value collected in DHIS2 may be a synonym's `Id`, so downstream classification must treat synonyms exactly like the concepts they belong to.

Two classification mechanisms follow from this, and both are relied upon by the generated DHIS2 program rules (the `set recognized pathogen` / `set virus` ASSIGN rules) **and** by the synthetic-data generator that must produce rule-valid data:

- **`CommonCommensal` (and resistance) flags are inherited.** A node's **effective** flag is the nearest explicit value on its path to the root: its own value if it carries one, otherwise the closest ancestor that does; absent everywhere it defaults to `false`. The flag **flows down** through `Hierarchies`/`Synonyms`/`Children`, so setting `CommonCommensal: true` on a genus marks every species and synonym beneath it without repetition — and an **explicit `false` on a descendant overrides an inherited `true`** (and vice versa). This is why you cannot read a node's flag in isolation: e.g. the *Coagulase-negative staphylococci* group node and the *Staphylococcus epidermidis* species node beneath it can carry different effective flags depending on where the explicit value sits. Resistance flags (`MRSA`, `VRE`, `3GCR`, carbapenem, colistin) use the identical own-or-inherited model.
- **Virus classification is structural, not a flag.** There is no per-concept "kingdom" attribute. A concept **is a virus iff it descends from the top-level `Viruses` realm** (the ICTV branch) — mirroring how bacteria live under `Bacteria` and eukaryotes under `Eukaryota`. Because synonyms are Id-bearing options too, the virus set is the **full subtree** under `Viruses` (every concept *and* synonym Id), so a value entered against a virus synonym still classifies as a virus.

The canonical implementations are `Get-NeoIPCCommonCommensalFlag` / `Get-NeoIPCCommonCommensalCodeSet` and `Get-NeoIPCVirusCodeSet` in the `NeoIPC-Tools` module — the single source both the rule generator and its tests expand from. Compute effective flags/sets through those functions rather than reading a node's literal `CommonCommensal` value or guessing at kingdom membership.

## Data sources

The ontology is compiled from the following sources. All citations and source URLs live here; the licensing implications are documented in [`LICENSE.md`](LICENSE.md).

### NHSN Organism List

<https://www.cdc.gov/nhsn/xls/master-organism-com-commensals-lists.xlsx>

Source: [Centers for Disease Control and Prevention National Healthcare Safety Network (NHSN)](https://www.cdc.gov/nhsn/index.html).

Available on the NHSN website for no charge.

Reference to specific commercial products, manufacturers, companies, or trademarks does not constitute its endorsement or recommendation by the U.S. Government, Department of Health and Human Services, or Centers for Disease Control and Prevention.

Not subject to copyright but some [requirements](https://www.cdc.gov/other/agencymaterials.html) must be followed.

The `CommonCommensal` flag follows the classification in the NHSN Organism List. Conceptually it is **not about (human) commensalism per se but about blood-culture contamination**: it marks organisms for which a positive blood culture is *most likely the result of sample contamination from the immediate sampling environment* — where the patient's own skin flora plays the dominant role — rather than the genuine presence of the organism in the patient's blood. This framing is what should guide judgement whenever an organism is **not** enumerated by NHSN, or when researching a specific organism: ask *"is a positive blood culture for this organism more plausibly skin/environmental contamination at sampling than true bacteraemia?"* Human skin/mucosal flora (e.g. coagulase-negative staphylococci, viridans streptococci) answer **yes** → common commensal; animal-associated, environmental, or frankly pathogenic organisms answer **no** → not a common commensal. (NHSN's own list is the same idea applied to human flora, which is why animal/environmental species and recognised pathogens are excluded from it.)

### List of Prokaryotic names with Standing in Nomenclature (LPSN)

<https://lpsn.dsmz.de/>

Parte, A.C., Sardà Carbasse, J., Meier-Kolthoff, J.P., Reimer, L.C. and Göker, M. (2020). List of Prokaryotic names with Standing in Nomenclature (LPSN) moves to the DSMZ. International Journal of Systematic and Evolutionary Microbiology, 70, 5607-5612; DOI: [10.1099/ijsem.0.004332](https://doi.org/10.1099/ijsem.0.004332)

### MycoBank

<https://www.mycobank.org/>

Vincent Robert, Duong Vu, Ammar Ben Hadj Amor, Nathalie van de Wiele, Carlo Brouwer, Bernard Jabas, Szaniszlo Szoke, Ahmed Dridi, Maher Triki, Samy ben Daoud, Oussema Chouchen, Lea Vaas, Arthur de Cock, Joost A. Stalpers, Dora Stalpers, Gerard J.M. Verkley, Marizeth Groenewald, Felipe Borges dos Santos, Gerrit Stegehuis, Wei Li, Linhuan Wu, Run Zhang, Juncai Ma, Miaomiao Zhou, Sergio Pérez Gorjón, Lily Eurwilaichitr, Supawadee Ingsriswang, Karen Hansen, Conrad Schoch, Barbara Robbertse, Laszlo Irinyi, Wieland Meyer, Gianluigi Cardinali, David L. Hawksworth, John W. Taylor, and Pedro W. Crous. 2013. MycoBank gearing up for new horizons. IMA Fungus · volume 4 · no 2: 371–379; DOI: [10.5598/imafungus.2013.04.02.16](https://doi.org/10.5598/imafungus.2013.04.02.16)

### International Committee on Taxonomy of Viruses (ICTV)

<https://ictv.global/taxonomy/>

Walker PJ, Siddell SG, Lefkowitz EJ, Mushegian AR, Adriaenssens EM, Alfenas-Zerbini P, Dempsey DM, Dutilh BE, García ML, Curtis Hendrickson R, Junglen S, Krupovic M, Kuhn JH, Lambert AJ, Łobocka M, Oksanen HM, Orton RJ, Robertson DL, Rubino L, Sabanadzovic S, Simmonds P, Smith DB, Suzuki N, Van Doorslaer K, Vandamme AM, Varsani A, Zerbini FM. [Recent changes to virus taxonomy ratified by the International Committee on Taxonomy of Viruses](https://link.springer.com/article/10.1007/s00705-022-05516-5) (2022). Arch Virol. 2022 Aug 23. doi: 10.1007/s00705-022-05516-5. Epub ahead of print. PMID: 35999326.

## Licensing

The repository as a whole is MIT-licensed, but the upstream sources above impose stricter terms on this directory's contents. See [`LICENSE.md`](LICENSE.md) for the full reasoning and the resulting effective license.
