# Infectious Agents

This directory contains the NeoIPC infectious-agent ontology, `NeoIPC-Infectious-Agents.yaml`, from which the DHIS2 `NEOIPC_PATHOGENS` option set behind the infectious-agent pickers, and the program rules that classify the infectious agent recorded, are generated. It is written in YAML 1.2.2's portable subset, which YAML 1.1, YAML 1.2.2, and the YAML readers the toolkit meets read alike: every plain scalar reads as one type and value in each of them, every plain key as a string, and every block scalar as a string whose final line break none of them gains or loses, and there are no anchors, aliases, tags, directives, second documents, keys that are collections, or keys repeated, in the same or another letter case. The Core Protocol's printed list of infectious agents (`New-PathogenList` in the NeoIPC-BuildTools module) renders from the frozen CSVs kept beside it, which two readers outside this repository also download.

## Contents

| File | Purpose |
| --- | --- |
| `NeoIPC-Infectious-Agents.yaml` | **Canonical** hierarchical ontology of infectious agents, their synonyms, and metadata. Single source of truth. |
| `NeoIPC-Infectious-Agents.<lang>.yaml` | Per-locale translation overlay that the localization pipeline generates with po4a from the translation catalogue. Not committed, and never edited by hand. |
| `NeoIPC-Infectious-Agents.uids.csv` | The `id,uid` sidecar mapping each option code (the YAML `Id`) to its DHIS2 option **UID** (source identity for the generated `NEOIPC_PATHOGENS` option set, so generation does not read UIDs from a DHIS2 export). Holds a UID for **every** `Id`: the deployed options' as the deployment assigned them, captured once, and every other one drawn at random once, in the form DHIS2 generates, by `Add-NeoIPCInfectiousAgentUid`. A row never changes. No UID is derived: generation fails for an `Id` the file lacks. The option **set**'s own UID is a NeoIPC-Tools module constant. |
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

Once the new entries are in the file, draw each new `Id`'s DHIS2 UID, which its option takes from the UID sidecar:

```powershell
Add-NeoIPCInfectiousAgentUid
```

A row, once drawn, never changes: every instance that imported a package carrying the option holds it under that UID, and refuses another option of the set with the same code or name. An entry that a branch maintaining an earlier line takes from `main` therefore takes its row with it, rather than drawing another.

## What CI Checks

`MetadataContent.Tests.ps1` in the NeoIPC-Tools module holds the committed list to these checks, each shown firing on a fixture in `InfectiousAgentValidation.Tests.ps1`:

1. every key is one the list's vocabulary has at its place, in its spelling, and every `Id`, record number, and flag is written in its plain form: an `Id` as an integer from 0 and a record number as one from 1, both up to 2,147,483,647, and a flag as one of YAML 1.2.2's plain Booleans (`true`, `True`, `TRUE`, `false`, `False`, or `FALSE`);
2. no two nodes share an `Id`; every node, with or without an `Id`, has a `Name`, a `ConceptSource` that the `UrlTemplates` name, in their spelling, with the source's record number where the source is LPSN, MycoBank, or ICTV, and a `ConceptId`; every selectable concept has a rank from the vocabulary; and the top-level `Id` 0 and `Viruses` exist;
3. every node can be told from every other: a synonym has an `Id` of its own, since a value collected in DHIS2 may be its `Id`; no two nodes of one source share a `ConceptId`, no two LPSN nodes a record number, no two MycoBank nodes a MycoBank number, which a link to a name takes, and no two concepts an `IctvId`, which repeats only among a concept and the synonyms that are its former names; and a NeoIPC `ConceptId` is an integer from 1;
4. every `CommonCommensal` flag sits on a concept, never on a synonym, which takes its concept's status, only where it changes the status its node inherits, and only where some `Id`-bearing node takes its status from it, with the reason for it under `CommonCommensal` in the node's `Comments`; a node under which every `Id`-bearing node takes, from flags further down, a status that one flag on the node would give them all says in its `Comments.CommonCommensal` why the flags stay beneath it; and a node's `Comments` hold only texts, each under a flag the node carries, under `Background`, or, on such a node, under `CommonCommensal`;
5. the option labels generated from the list are distinct, as DHIS2's metadata import requires of the options of one option set, and fit the 230 characters DHIS2 stores;
6. the UID sidecar gives every `Id` of the list, and nothing else, a well-formed DHIS2 UID of its own;
7. the list is append-only against every released version, the `infectious-agents-v*` tags: a released `Id` keeps its name and the UID a release's sidecar gave it, an `Id` new since the releases exceeds every released one, and a released `Id` never disappears, nor does its UID, except from a branch that maintains an earlier line, which need not carry the `Id`s of a later line's releases outside its history (those of a greater MAJOR.MINOR than its `VERSION` file names). The check reads the tags, so it fails rather than passes in a clone without them, or without the tag of a release the CHANGELOG records; only the release that the `VERSION` file names needs no tag while the CHANGELOG's `[Unreleased]` section lists no change, as while that release is prepared, since its tag names the commit that merges the preparation. Until that tag is pushed, a clone cannot tell the release from its preparation, so the tag is pushed before the next change to the list merges;
8. the two frozen CSVs are unchanged.

`YamlPortability.Tests.ps1` holds the file, like every committed YAML file of the toolkit, to YAML 1.2.2's portable subset, and `scripts/Test-YamlReaderAgreement.ps1` holds yaml12, R's yaml, powershell-yaml, and ruamel.yaml to reading it alike.

## Ontology Structure: Flag Inheritance and Virus Classification

The ontology is a tree: every node may carry child nodes under `Hierarchies`, `Synonyms`, and `Children`. **A synonym is a first-class, Id-bearing, selectable option**, not just a display alias — a value collected in DHIS2 may be a synonym's `Id`, so downstream classification must treat synonyms exactly like the concepts they belong to.

Two classification mechanisms follow from this, and both are relied upon by the generated DHIS2 program rules (the `set recognized pathogen` / `set virus` ASSIGN rules) **and** by the synthetic-data generator that must produce rule-valid data:

- **`CommonCommensal` (and resistance) flags are inherited.** A node's **effective** flag is the nearest explicit value on its path to the root: its own value if it carries one, otherwise the closest ancestor that does; absent everywhere it defaults to `false`. The flag **flows down** through `Hierarchies`/`Synonyms`/`Children`, so setting `CommonCommensal: true` on a genus marks every species and synonym beneath it without repetition — and an **explicit `false` on a descendant overrides an inherited `true`** (and vice versa). This is why you cannot read a node's flag in isolation: *Staphylococcus epidermidis* carries no flag of its own and is a common commensal through the *Coagulase-negative staphylococci* group node above it. Resistance flags (`MRSA`, `VRE`, `3GCR`, carbapenem, colistin) use the identical own-or-inherited model.
- **Virus classification is structural, not a flag.** There is no per-concept "kingdom" attribute. A concept **is a virus if and only if it descends from the top-level `Viruses` node**, NeoIPC's own node above ICTV's realms — mirroring how bacteria live under `Bacteria` and eukaryotes under `Eukaryota`. Because synonyms are Id-bearing options too, the virus set is the **full subtree** under `Viruses` (every concept *and* synonym Id), so a value entered against a virus synonym still classifies as a virus.

The canonical implementations are `Get-NeoIPCCommonCommensalFlag` / `Get-NeoIPCCommonCommensalCodeSet`, `Get-NeoIPCResistanceFlag` / `Get-NeoIPCResistanceCodeSet`, and `Get-NeoIPCVirusCodeSet` in the `NeoIPC-Tools` module — the single source both the rule generator and its tests expand from. Outside the module, `Get-NeoIPCInfectiousAgentCodeSet` returns the sets they give, with the concepts, the synonyms, and the SHA-256 of the list, and `Export-NeoIPCInfectiousAgentCodeSet` writes them as JSON for a consumer in another language. Compute effective flags/sets through those rather than reading a node's literal `CommonCommensal` value or guessing at kingdom membership.

NeoIPC's own prose about a node sits in its `Comments`, a mapping of texts: under a flag's key, the reason for that flag, on the node that carries it; under `CommonCommensal` on a node without that flag, why none sits there although one would hold for every `Id`-bearing node beneath it; and under `Background`, anything else.

## Reconciling the Ontology With Its Sources

The ontology is reconciled with each source's own bulk download, never with pages scraped from its website: LPSN's export of prokaryotic names, MycoBank's list of fungal names, ICTV's Master Species List and Virus Metadata Resource, and the NHSN Organism List's workbook. What a download does not carry, such as the notes on a name's LPSN page, is read from the source's page for that record, one record at a time, and MycoBank's web services, read the same way, give the records that changed after its list was exported.

1. **Names and records.** Each node's name, rank, and record identifier are checked against the download of its source, the one its `ConceptSource` names. A node whose source is NeoIPC is NeoIPC's own, and no download covers it. A bacterial concept takes the name that the List of Recommended Names for bacteria of medical importance applies where it gives one, and LPSN's correct name otherwise; the export's "recommended for medical use" misses some names that list applies, so the note on the name's LPSN page decides. A name that gives way stays as a synonym with its `Id`, and a concept whose taxon LPSN gives no correct name, such as a name that is not validly published, keeps its name, with a `Comments.Background` saying why. A fungal concept takes the name MycoBank gives as current and sits where MycoBank classifies that name's record; where MycoBank's records disagree on the name, as where the one it gives as current is an orthographic variant or invalid while a legitimate name of the same taxon exists, the concept takes the name that agrees with the genus it sits in, with the other name as its synonym; since both keep their `Id`s, the two can change places, losing nothing, once MycoBank's records agree. A MycoBank node's `ConceptId` is the ID of its record in MycoBank's database and its `MycoBankNr` that record's MycoBank number, both permanent; a link to a name takes the MycoBank number. A higher taxon cites the legitimate record of its name where one exists. Where MycoBank's records disagree, as where a genus's record names another genus as current while its type species stays current in it, or where MycoBank files a genus that is no fungus under Fungi, the node's `Comments.Background` says where the list places it and why. A virus concept takes the name, rank, and lineage that ICTV's newest Master Species List gives its taxon, and that release's node as its `ConceptId`, while a synonym, a former name, keeps the node of the release whose name it carries, the newest such release for a synonym new to the list; the `IctvId` links a taxon's nodes across releases. A species that a release splits stays, with its `Id`, as a synonym of a NeoIPC group that holds its successors. A NeoIPC group of viruses covers the species whose isolates ICTV's Virus Metadata Resource gives the names, or abbreviations, of the viruses the group's name denotes, and holds the taxa it covers where they share one parent: whole species, whole genera, or groups or serotypes of its own; a group of the types of one species sits beneath that species, or beneath the group that holds it; and any other group stays a leaf whose `Comments.Background` says which species it covers, or which genera where those hold too many species to name.
2. **Common commensals.** The NHSN Organism List's rows are matched to the ontology's nodes by name. A node's own name, its synonyms, and its concept's names form one cluster, and the most specific match wins: the cluster first, then the lineage at genus level or below, NeoIPC's groups included, then the genus named in the row, then higher ranks. Where the rows that the most specific match reaches disagree, as where an infectious agent's names fall under two genus rows, a row that counts it a common commensal decides, since NHSN counts it one when it is reported under that name. A NeoIPC group matches the row that names the same group in NHSN's words, as *Coagulase-negative staphylococci* matches "Staphylococcus, coagulase negative", and *Viridans streptococci* "Viridans group streptococci". NHSN names viruses by their common names, which are matched to the ICTV species whose isolates ICTV's Virus Metadata Resource gives those names or abbreviations, and to the list's own names with NHSN's forms read as the list's, such as a plural ("Human parainfluenza viruses"), a type number ("Human immunodeficiency virus type I"), a "Human" that the list's name does without ("Human echovirus"), and "encephalomyelitis" for "encephalitis" ("Venezuelan equine encephalomyelitis virus"); a virus row that still matches no node, such as "Arenavirus", leaves no status open, since NHSN lists no virus as a common commensal. Where NHSN names exceptions ("Bacillus, not B. anthracis"), they are combined as a union, and both of the names NHSN gives a row are used, its display name and the SNOMED CT preferred term. A node takes NHSN's status by default; where NHSN is silent, the contamination test below decides. The list departs from NHSN only where the evidence calls for it, as for an infectious agent that NHSN counts as a common commensal but that causes sepsis and meningitis in newborns, or a zoonotic one, and only with the sign-off of NeoIPC's principal investigator; the node's `Comments.CommonCommensal` then says that its status departs from the NHSN Organism List (2024), and why. A reason whose evidence differs between newborns and adults says so.
3. **Evidence.** `Comments` cite the sources below by their records and rows, the NHSN Organism List by its name and year, as "NHSN Organism List (2024)", and any other evidence only from peer-reviewed work, by its digital object identifier (DOI) or PubMed identifier (PMID) rather than its authors' names. A conference abstract is no such evidence, since abstracts often lack proper peer review, and neither is an article in a journal whose peer review is questionable, such as one that <https://www.predatoryjournals.org/> lists, or whose publisher it lists.

## Data Sources

The ontology is compiled from the following sources, cited here with their URLs; other evidence is cited by DOI or PMID in the `Comments` that rest on it. The licensing implications are documented in [`LICENSE.md`](LICENSE.md).

### NHSN Organism List

<https://www.cdc.gov/nhsn/xls/master-organism-com-commensals-lists.xlsx>

The ontology follows the workbook's 2024 edition, updated in February 2024 for the infectious agents identified in 2024, which `Comments` cite as "NHSN Organism List (2024)". The workbook states that its content moves to a web-based terminology browser and that the workbook is discontinued in 2025.

Source: [Centers for Disease Control and Prevention National Healthcare Safety Network (NHSN)](https://www.cdc.gov/nhsn/index.html).

Available on the NHSN website for no charge.

Reference to specific commercial products, manufacturers, companies, or trademarks does not constitute its endorsement or recommendation by the U.S. Government, Department of Health and Human Services, or Centers for Disease Control and Prevention.

Not subject to copyright but some [requirements](https://www.cdc.gov/other/agencymaterials.html) must be followed.

The `CommonCommensal` flag follows the classification in the NHSN Organism List, except where a node's `Comments.CommonCommensal` records that NeoIPC departs from it, and why. The protocol defines a common commensal as an infectious agent commonly present on epithelium-covered body surfaces, such as the skin, whose growth in a blood culture makes contamination more likely than a recognized pathogen's growth does: the flag is **not about (human) commensalism per se but about blood-culture contamination** at sampling, where the patient's own skin flora plays the dominant role. Beside that flora, NHSN lists some environmental bacteria that contaminate blood cultures, such as most *Bacillus* species, and it lists no fungus, so every fungus stays a recognized pathogen. Wherever NHSN is silent, with no row reaching the infectious agent by the matching that item 2 of [Reconciling the Ontology With Its Sources](#reconciling-the-ontology-with-its-sources) describes, the contamination test decides, the protocol's definition put as a question, which also guides judgement when researching a specific infectious agent: *"is this infectious agent commonly present on the skin or mucous membranes, so that a positive blood culture more plausibly reflects contamination at sampling than true bacteraemia?"* Human skin and mucosal flora (such as coagulase-negative staphylococci and viridans streptococci) answer **yes** → common commensal; zoonotic and frankly pathogenic infectious agents answer **no** → not a common commensal.

### List of Prokaryotic names with Standing in Nomenclature (LPSN)

<https://lpsn.dsmz.de/>

Parte, A.C., Sardà Carbasse, J., Meier-Kolthoff, J.P., Reimer, L.C. and Göker, M. (2020). List of Prokaryotic names with Standing in Nomenclature (LPSN) moves to the DSMZ. International Journal of Systematic and Evolutionary Microbiology, 70, 5607-5612; DOI: [10.1099/ijsem.0.004332](https://doi.org/10.1099/ijsem.0.004332)

### List of Recommended Names for Bacteria of Medical Importance (LoRN)

Göker, M., Christensen, H., Fingerle, V., Kostovski, M., Margos, G., Moore, E.R.B., Oren, A., Patrick, S., Reischl, U. and Vázquez-Boland, J.A. (2025). List of Recommended Names for bacteria of medical importance: report of the Ad Hoc Committee on Mitigating Changes in Prokaryotic Nomenclature. International Journal of Systematic and Evolutionary Microbiology, 75(10); DOI: [10.1099/ijsem.0.006943](https://doi.org/10.1099/ijsem.0.006943)

LPSN carries the list: the page of a name on it says whether the name is the one to be applied to its taxon or a synonym of that name.

### MycoBank

<https://www.mycobank.org/>, and its web services, <https://webservices.bio-aware.com/westerdijk/public>

Vincent Robert, Duong Vu, Ammar Ben Hadj Amor, Nathalie van de Wiele, Carlo Brouwer, Bernard Jabas, Szaniszlo Szoke, Ahmed Dridi, Maher Triki, Samy ben Daoud, Oussema Chouchen, Lea Vaas, Arthur de Cock, Joost A. Stalpers, Dora Stalpers, Gerard J.M. Verkley, Marizeth Groenewald, Felipe Borges dos Santos, Gerrit Stegehuis, Wei Li, Linhuan Wu, Run Zhang, Juncai Ma, Miaomiao Zhou, Sergio Pérez Gorjón, Lily Eurwilaichitr, Supawadee Ingsriswang, Karen Hansen, Conrad Schoch, Barbara Robbertse, Laszlo Irinyi, Wieland Meyer, Gianluigi Cardinali, David L. Hawksworth, John W. Taylor, and Pedro W. Crous. 2013. MycoBank gearing up for new horizons. IMA Fungus · volume 4 · no 2: 371–379; DOI: [10.5598/imafungus.2013.04.02.16](https://doi.org/10.5598/imafungus.2013.04.02.16)

### International Committee on Taxonomy of Viruses (ICTV)

<https://ictv.global/taxonomy/>

Lefkowitz E, Hendrickson R, International Committee on Taxonomy of Viruses. [ICTV Master Species List (MSL), MSL41.v1, as corrected on 14 October 2026](https://doi.org/10.5281/zenodo.23376199). Zenodo; 2026. doi: 10.5281/zenodo.23376199. The ontology's viruses follow this release.

International Committee on Taxonomy of Viruses. [Virus Metadata Resource (VMR), MSL41.v1, as exported on 14 October 2026](https://github.com/ICTV-Virus-Knowledgebase/ICTVdatabase). ICTVdatabase; 2026 (`data/vmr_export.utf8.txt`, exported with the corrected Master Species List; the current release is at <https://ictv.global/vmr>). It gives the exemplar and additional isolates of each species with their names and abbreviations, through which the ontology's virus groups and NHSN's virus rows are mapped to species.

Black EJ, Powell CS, Dempsey DM, Hendrickson RC, Mims LR, Lefkowitz EJ. [Virus taxonomy: the database of the International Committee on Taxonomy of Viruses](https://doi.org/10.1093/nar/gkaf1159). Nucleic Acids Res. 2026;54(D1):D776-D789. doi: 10.1093/nar/gkaf1159.

## Licensing

The repository as a whole is MIT-licensed, but the upstream sources above impose stricter terms on this directory's contents. See [`LICENSE.md`](LICENSE.md) for the full reasoning and the resulting effective licence.

Those terms cover **this directory**. They do not extend to the gettext translation catalogue (`po/infectious_agents.*`), which carries only names, rank labels, controlled values and list labels, and the standalone list's header and footer, and is published under CC BY 4.0, nor to factual extracts, such as the Core Protocol's list of infectious agents and neoipcr's tables, which carry nothing but the `Id`s, names and synonyms, ranks and lineage, source records, and the statuses NeoIPC assigns; those NeoIPC publishes must attribute the sources above — see [`LICENSE.md`](LICENSE.md) § *Scope*.
