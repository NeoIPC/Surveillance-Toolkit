# Infectious Agents

This directory contains the NeoIPC infectious-agent ontology, `NeoIPC-Infectious-Agents.yaml`, from which the DHIS2 `NEOIPC_PATHOGENS` option set behind the infectious-agent pickers, and the program rules that classify the infectious agent recorded, are generated. It is written in YAML 1.2.2's portable subset, which YAML 1.1, YAML 1.2.2, and the YAML readers the toolkit meets read alike: every plain scalar reads as one type and value in each of them, every plain key as a string, and every block scalar as a string whose final line break none of them gains or loses, and there are no anchors, aliases, tags, directives, second documents, keys that are collections, or keys repeated, in the same or another letter case. The Core Protocol's printed list of infectious agents (`New-PathogenList` in the NeoIPC-BuildTools module) renders from the frozen CSVs kept beside it, which two readers outside this repository also download.

## Contents

| File | Purpose |
| --- | --- |
| `NeoIPC-Infectious-Agents.yaml` | **Canonical** hierarchical ontology of infectious agents, their synonyms, and metadata. Single source of truth. |
| `NeoIPC-Infectious-Agents.<lang>.yaml` | Per-locale translation overlay that the localization pipeline generates with po4a from the translation catalogue. Not committed, and never edited by hand. |
| `NeoIPC-Infectious-Agents.uids.csv` | The `id,uid` sidecar mapping each option code (the YAML `Id`) to its DHIS2 option **UID** (source identity for the generated `NEOIPC_PATHOGENS` option set, so generation does not read UIDs from a DHIS2 export). Holds only the **deployed** codes; an `Id` absent from it (an infectious agent not yet deployed) is minted deterministically on generation, from the option set's UID and the code. The option **set**'s own UID is a NeoIPC-Tools module constant. These are the UIDs the deployment already assigned, captured once; nothing writes the file. |
| `NeoIPC-Owned-Pathogen-Concepts.csv` | Classification of NeoIPC-owned concepts (`pathogen_type`, `concept_type`), keyed by the `ConceptId` of the NeoIPC-sourced concepts. Read by `New-PathogenList` (NeoIPC-BuildTools) when the Core Protocol build renders the printed list. |
| `ListElements.csv` / `ListElements.<lang>.csv` | The heading and value labels of the printed table of infectious agents, read by `New-PathogenList` (NeoIPC-BuildTools) when the Core Protocol build renders the list. |
| `AsciiDoc-PDF.yml` | Asciidoctor-PDF theme of the standalone list of infectious agents, which `scripts/Convert-InfectiousAgentList.ps1` renders from the ontology. The script currently fails: it looks for a `po4a.cfg` in this directory, while the list's po4a configuration is `po/infectious_agents.po4a.cfg`. The Core Protocol's list does not use the theme. |
| `Output-Header.adoc` / `Output-Footer.adoc` (+ per-locale variants) | AsciiDoc preamble and postamble of that standalone list. |
| `NeoIPC-Pathogen-Concepts.csv`, `NeoIPC-Pathogen-Synonyms.csv` | **Frozen.** The flat CSVs that predate the YAML, kept byte for byte because readers outside this repository download them from the `main` branch: an external legacy reporting service, at run time, and neoipcr's data-preparation script. The Core Protocol's printed list is built from them too. They are never edited, do not follow the ontology, and CI checks their SHA-256; consult the YAML instead. |
| `NeoIPC-Pathogen-Concepts.<lang>.csv`, `NeoIPC-Pathogen-Synonyms.<lang>.csv` | The German and Spanish names of the frozen CSVs' entries, read by `New-PathogenList` for the printed list. The Spanish synonyms file is a copy of the German one, so the Spanish list shows the German names of the synonyms that file translates. |
| `CHANGELOG.md`, `VERSION` | The list's releases, and its version: the last one released, or the one being prepared. Each release's `infectious-agents-v*` tag names its version. |

## Adding an Entry

Only the entries a user can select carry an `Id:`, a unique integer that is the option code in DHIS2 and the join key in downstream tools; structural nodes, most higher ranks among them, carry none. To find the next unused integer:

```powershell
Import-Module ./scripts/modules/NeoIPC-Tools
Find-NextFreeInfectiousAgentId
```

The cmdlet returns `max(existing Id:) + 1`, a new `Id` on `main`, which keeps every released `Id`. On a branch that maintains an earlier line, take one above every `Id` any release has used instead, since a later line may already have given the file's next integer to another infectious agent. `Id`s are append-only: an `Id` once released never disappears from the list (a branch that maintains an earlier line need not carry the `Id`s a later line added), and a renamed or reclassified infectious agent keeps its old name as a synonym, with its original `Id`, since collected records hold that `Id`, while the new name takes the next free one. Only an `Id` that was never released can leave a gap, and a gap is not refilled, so no downstream consumer meets an `Id` reused for another infectious agent.

## What CI Checks

`MetadataContent.Tests.ps1` in the NeoIPC-Tools module holds the committed list to these checks, each shown firing on a fixture in `InfectiousAgentValidation.Tests.ps1`:

1. every key is one the list's vocabulary has at its place, in its spelling, and every `Id`, record number, and flag is written in its plain form: an `Id` as an integer from 0 and a record number as one from 1, both up to 2,147,483,647, and a flag as one of YAML 1.2.2's plain Booleans (`true`, `True`, `TRUE`, `false`, `False`, or `FALSE`);
2. no two nodes share an `Id`; every node, with or without an `Id`, has a `Name`, a `ConceptSource` that the `UrlTemplates` name, in their spelling, with the source's record number where the source is LPSN, MycoBank, or ICTV, and a `ConceptId`; every selectable concept has a rank from the vocabulary; and the top-level `Id` 0 and `Viruses` exist;
3. the option labels generated from the list are distinct, as DHIS2's metadata import requires of the options of one option set, and fit the 230 characters DHIS2 stores;
4. the UID sidecar lists only `Id`s of the list, with well-formed DHIS2 UIDs, each once;
5. the list is append-only against every released version, the `infectious-agents-v*` tags: a released `Id` keeps its name, a deployed option keeps its UID, an `Id` new since the releases exceeds every released one, and a released `Id` never disappears, nor does its UID, except from a branch that maintains an earlier line, which need not carry the `Id`s of a later line's releases outside its history (those of a greater MAJOR.MINOR than its `VERSION` file names). The check reads the tags, so it fails rather than passes in a clone without them, or without the tag of a release the CHANGELOG records; only the release that the `VERSION` file names needs no tag while the CHANGELOG's `[Unreleased]` section lists no change, as while that release is prepared, since its tag names the commit that merges the preparation. Until that tag is pushed, a clone cannot tell the release from its preparation, so the tag is pushed before the next change to the list merges;
6. the two frozen CSVs are unchanged.

`YamlPortability.Tests.ps1` holds the file, like every committed YAML file of the toolkit, to YAML 1.2.2's portable subset, and `scripts/Test-YamlReaderAgreement.ps1` holds yaml12, R's yaml, powershell-yaml, and ruamel.yaml to reading it alike.

## Ontology Structure: Flag Inheritance and Virus Classification

The ontology is a tree: every node may carry child nodes under `Hierarchies`, `Synonyms`, and `Children`. **A synonym is a first-class, Id-bearing, selectable option**, not just a display alias — a value collected in DHIS2 may be a synonym's `Id`, so downstream classification must treat synonyms exactly like the concepts they belong to.

Two classification mechanisms follow from this, and both are relied upon by the generated DHIS2 program rules (the `set recognized pathogen` / `set virus` ASSIGN rules) **and** by the synthetic-data generator that must produce rule-valid data:

- **`CommonCommensal` (and resistance) flags are inherited.** A node's **effective** flag is the nearest explicit value on its path to the root: its own value if it carries one, otherwise the closest ancestor that does; absent everywhere it defaults to `false`. The flag **flows down** through `Hierarchies`/`Synonyms`/`Children`, so setting `CommonCommensal: true` on a genus marks every species and synonym beneath it without repetition — and an **explicit `false` on a descendant overrides an inherited `true`** (and vice versa). This is why you cannot read a node's flag in isolation: e.g. the *Coagulase-negative staphylococci* group node and the *Staphylococcus epidermidis* species node beneath it can carry different effective flags depending on where the explicit value sits. Resistance flags (`MRSA`, `VRE`, `3GCR`, carbapenem, colistin) use the identical own-or-inherited model.
- **Virus classification is structural, not a flag.** There is no per-concept "kingdom" attribute. A concept **is a virus if and only if it descends from the top-level `Viruses` node**, NeoIPC's own node above ICTV's realms — mirroring how bacteria live under `Bacteria` and eukaryotes under `Eukaryota`. Because synonyms are Id-bearing options too, the virus set is the **full subtree** under `Viruses` (every concept *and* synonym Id), so a value entered against a virus synonym still classifies as a virus.

The canonical implementations are `Get-NeoIPCCommonCommensalFlag` / `Get-NeoIPCCommonCommensalCodeSet`, `Get-NeoIPCResistanceFlag` / `Get-NeoIPCResistanceCodeSet`, and `Get-NeoIPCVirusCodeSet` in the `NeoIPC-Tools` module — the single source both the rule generator and its tests expand from. Compute effective flags/sets through those functions rather than reading a node's literal `CommonCommensal` value or guessing at kingdom membership.

## Reconciling the Ontology With Its Sources

The ontology is reconciled with each source's own bulk download, never with pages scraped from its website: LPSN's export of prokaryotic names, MycoBank's list of fungal names, ICTV's Master Species List, and the NHSN Organism List's workbook.

1. **Names and records.** Each node's name, rank, and record identifier are checked against the download of its source, the one its `ConceptSource` names. A node whose source is NeoIPC is NeoIPC's own, and no download covers it.
2. **Common commensals.** The NHSN Organism List's rows are matched to the ontology's nodes by name. A node's own name, its synonyms, and its concept's names form one cluster, and the most specific match wins: the cluster first, then the lineage at genus level or below, NeoIPC's groups included, then the genus named in the row, then higher ranks. Where NHSN names exceptions ("except …"), they are combined as a union, and both of the names NHSN gives a row are used, its display name and the SNOMED CT preferred term. A node takes NHSN's status by default; where NHSN is silent, the contamination test below decides.

## Data Sources

The ontology is compiled from the following sources. All citations and source URLs live here; the licensing implications are documented in [`LICENSE.md`](LICENSE.md).

### NHSN Organism List

<https://www.cdc.gov/nhsn/xls/master-organism-com-commensals-lists.xlsx>

Source: [Centers for Disease Control and Prevention National Healthcare Safety Network (NHSN)](https://www.cdc.gov/nhsn/index.html).

Available on the NHSN website for no charge.

Reference to specific commercial products, manufacturers, companies, or trademarks does not constitute its endorsement or recommendation by the U.S. Government, Department of Health and Human Services, or Centers for Disease Control and Prevention.

Not subject to copyright but some [requirements](https://www.cdc.gov/other/agencymaterials.html) must be followed.

The `CommonCommensal` flag follows the classification in the NHSN Organism List. Conceptually it is **not about (human) commensalism per se but about blood-culture contamination**: it marks infectious agents for which a positive blood culture is *most likely the result of sample contamination from the immediate sampling environment* — where the patient's own skin flora plays the dominant role — rather than the genuine presence of the infectious agent in the patient's blood. This framing is what should guide judgement whenever an infectious agent is **not** enumerated by NHSN, or when researching a specific infectious agent: ask *"is a positive blood culture for this infectious agent more plausibly skin/environmental contamination at sampling than true bacteraemia?"* Human skin/mucosal flora (e.g. coagulase-negative staphylococci, viridans streptococci) answer **yes** → common commensal; animal-associated, environmental, or frankly pathogenic infectious agents answer **no** → not a common commensal. (NHSN's own list is the same idea applied to human flora, which is why animal/environmental species and recognized pathogens are excluded from it.)

### List of Prokaryotic names with Standing in Nomenclature (LPSN)

<https://lpsn.dsmz.de/>

Parte, A.C., Sardà Carbasse, J., Meier-Kolthoff, J.P., Reimer, L.C. and Göker, M. (2020). List of Prokaryotic names with Standing in Nomenclature (LPSN) moves to the DSMZ. International Journal of Systematic and Evolutionary Microbiology, 70, 5607-5612; DOI: [10.1099/ijsem.0.004332](https://doi.org/10.1099/ijsem.0.004332)

### MycoBank

<https://www.mycobank.org/>

Vincent Robert, Duong Vu, Ammar Ben Hadj Amor, Nathalie van de Wiele, Carlo Brouwer, Bernard Jabas, Szaniszlo Szoke, Ahmed Dridi, Maher Triki, Samy ben Daoud, Oussema Chouchen, Lea Vaas, Arthur de Cock, Joost A. Stalpers, Dora Stalpers, Gerard J.M. Verkley, Marizeth Groenewald, Felipe Borges dos Santos, Gerrit Stegehuis, Wei Li, Linhuan Wu, Run Zhang, Juncai Ma, Miaomiao Zhou, Sergio Pérez Gorjón, Lily Eurwilaichitr, Supawadee Ingsriswang, Karen Hansen, Conrad Schoch, Barbara Robbertse, Laszlo Irinyi, Wieland Meyer, Gianluigi Cardinali, David L. Hawksworth, John W. Taylor, and Pedro W. Crous. 2013. MycoBank gearing up for new horizons. IMA Fungus · volume 4 · no 2: 371–379; DOI: [10.5598/imafungus.2013.04.02.16](https://doi.org/10.5598/imafungus.2013.04.02.16)

### International Committee on Taxonomy of Viruses (ICTV)

<https://ictv.global/taxonomy/>

Walker PJ, Siddell SG, Lefkowitz EJ, Mushegian AR, Adriaenssens EM, Alfenas-Zerbini P, Dempsey DM, Dutilh BE, García ML, Curtis Hendrickson R, Junglen S, Krupovic M, Kuhn JH, Lambert AJ, Łobocka M, Oksanen HM, Orton RJ, Robertson DL, Rubino L, Sabanadzovic S, Simmonds P, Smith DB, Suzuki N, Van Doorslaer K, Vandamme AM, Varsani A, Zerbini FM. [Recent changes to virus taxonomy ratified by the International Committee on Taxonomy of Viruses](https://link.springer.com/article/10.1007/s00705-022-05516-5) (2022). Arch Virol. 2022;167(11):2429-2440. doi: 10.1007/s00705-022-05516-5. PMID: 35999326.

Lefkowitz EJ, Dempsey DM, Hendrickson RC, Orton RJ, Siddell SG, Smith DB. [Virus taxonomy: the database of the International Committee on Taxonomy of Viruses (ICTV)](https://doi.org/10.1093/nar/gkx932). Nucleic Acids Res. 2018;46(D1):D708-D717. doi: 10.1093/nar/gkx932.

## Licensing

The repository as a whole is MIT-licensed, but the upstream sources above impose stricter terms on this directory's contents. See [`LICENSE.md`](LICENSE.md) for the full reasoning and the resulting effective licence.

Those terms cover **this directory**. They do not extend to the gettext translation catalogue (`po/infectious_agents.*`), which carries only names, rank labels, controlled values and list labels, and the standalone list's header and footer, and is published under CC BY 4.0, nor to factual extracts, such as the Core Protocol's list of infectious agents and neoipcr's tables, which carry nothing but the `Id`s, names and synonyms, ranks and lineage, source records, and the statuses NeoIPC assigns; those NeoIPC publishes must attribute the sources above — see [`LICENSE.md`](LICENSE.md) § *Scope*.
