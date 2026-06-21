# Infectious Agents

This directory contains the NeoIPC infectious-agent ontology used to populate causative-pathogen pickers in DHIS2, render the printed pathogen reference list, and drive consumer-side helpers in neoipcr and the reports.

## Contents

| File | Purpose |
|------|---------|
| `NeoIPC-Infectious-Agents.yaml` | **Canonical** hierarchical ontology of infectious agents, their synonyms, and metadata. Single source of truth. |
| `NeoIPC-Infectious-Agents.<lang>.yaml` | Per-locale translation overlay generated from the po4a pipeline (do not edit by hand — see [the repo `CLAUDE.md` po4a section](../../../CLAUDE.md)). |
| `NeoIPC-Owned-Pathogen-Concepts.csv` | Classification of NeoIPC-owned concepts (`pathogen_type`, `concept_type`). Consumed by `Make-NeoIPC-Core-Protocol.ps1`. |
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
