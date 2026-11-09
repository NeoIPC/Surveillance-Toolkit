# Changelog — NeoIPC Infectious Agent List

Notable changes to the infectious-agent ontology described in [README.md](README.md).

This product is versioned independently of the others in this repository: its version lives in
[VERSION](VERSION) beside this file, and its releases carry the `infectious-agents-v` tag prefix. The
format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

The release workflow reads the section matching the released version out of this file and publishes
it as the GitHub Release body, so a release cannot be cut for a version this file does not describe.

## [Unreleased]

### Added

- CI checks of the list: its keys and structure; every node's `Id`, `Name`, rank, source, and record number, and the
  form each typed value takes in the file; that every node can be told from every other, a synonym by an `Id` of
  its own, a source's record by one node, an ICTV taxon by one concept, and a NeoIPC concept by an integer
  `ConceptId`; that each common-commensal flag sits on a concept, only where it changes the status its node inherits and
  some `Id`-bearing node takes its status from it, with the reason for it in the node's `Comments`, and that a node
  under which every `Id`-bearing node takes, from flags further down, a status one flag on it would give them all says
  there why the flags stay beneath it; the option labels generated from it; its UID sidecar; the two frozen CSVs; and
  that it stays append-only against every released version, so that a released `Id` keeps its name and the UID a
  release's sidecar gave it, a new `Id` exceeds every released one, and a released `Id` never disappears, except from a
  branch that maintains an earlier line, which need not carry a later line's `Id`s.
- CI checks that the list keeps to YAML 1.2.2's portable subset, which YAML 1.1, YAML 1.2.2, and the YAML readers
  the toolkit meets read alike, and that those readers read it alike.
- NeoIPC-Tools' `Get-NeoIPCInfectiousAgentCodeSet` returns the list's option codes, as its concepts and synonyms, and
  the code sets the generated DHIS2 rules enumerate: the common commensals, the infectious agents each resistance
  category (3GCR, CARBR, COLR, MRSA, VRE) applies to, and the viruses, with the list's SHA-256; and, for every `Id`,
  what the reporting classification gives it, its reporting group and, for a bacterium, its Gram reaction and oxygen
  requirement, null where the classification gives none, as the classification's checks resolve them, with the
  classification's SHA-256. It reads the classification beside the list unless `-ClassificationPath` names another,
  and does not run without one. `Export-NeoIPCInfectiousAgentCodeSet` writes them as JSON, for consumers in other
  languages.
- `NeoIPC-Infectious-Agent-Reporting-Groups.yaml`, the reporting classification above the ontology. It holds a tree of
  reporting groups after the categories of Annex 1 of ECDC's protocol for the surveillance of healthcare-associated
  infections in intensive care units (HAI-Net ICU protocol, version 2.3), into which every `Id`-bearing node falls but
  the `Id`s 0 and 3561. The tree splits the Gram-negative bacilli outside the Enterobacterales into non-fermenting,
  fermenting and fastidious, and variably fermenting ones, the other bacteria into actinomycetes, mycobacteria,
  bacteria without a cell wall, obligate intracellular bacteria, and spirochaetes, and the fungi into yeasts, moulds,
  and other fungi. The file also gives every bacterium its Gram reaction and oxygen requirement, and every placement
  its evidence. CI checks that every `Id`-bearing node takes one group, and every bacterium one value of each
  attribute, through members and assignments that each name one node, cite their evidence, and serve some `Id`, and
  that every member of a group that shares its ECDC category with another says what sets it in its group. The
  translation catalogue gains the groups' names and definitions and the names of the attributes and their values,
  which po4a takes from the classification by path, as it now takes the list's names, ranks, and terms, so that
  neither document's options reach the other; CI checks that the localized classifications differ from the canonical
  one only in those labels, and the list's release bundles the classification with them.

### Changed

- `LICENSE.md`: factual extracts of the list, outputs that carry nothing but `Id`s, names and synonyms, ranks and
  lineage, source records, and the statuses NeoIPC assigns, such as the Core Protocol's list of infectious agents,
  neoipcr's tables, and the reports' infectious-agent tables, fall outside the directory's CC BY-NC-ND 4.0 terms.
  The file also says what MycoBank's curators approved in January 2023. The reporting classification is part of the
  directory, and the reporting groups, Gram reactions, and oxygen requirements NeoIPC assigns are among the facts such
  extracts carry.
- `README.md`: which files are frozen and who reads them, what CI checks, which sources the ontology is compiled from,
  in which editions, how it is reconciled with them, when its common-commensal status departs from NHSN's, what
  evidence its `Comments` cite, and how the reporting classification groups the infectious agents.
- In `NeoIPC-Infectious-Agents.yaml`, `ListTerms`' `Yes` is quoted, so that a YAML 1.1 reader reads it as text
  rather than as a Boolean. The per-locale overlays, which po4a writes, have it plain.
- In `NeoIPC-Infectious-Agents.yaml`, NeoIPC's own prose about a node sits in its `Comments`: the reason for a flag
  under the flag's key, and anything else under `Background`. `Description` is no longer a node key; the text that
  Unidentifiable (3561) carried there is its `Comments.Background`.
- A bacterial concept takes the name that the List of Recommended Names for bacteria of medical importance applies where
  it gives one, and LPSN's correct name otherwise, as LPSN's export of 2 November 2026 and its pages give them. A
  correct name that was a synonym is the concept now, and one the list lacked is a new concept; concepts that name one
  taxon are merged; subspecies that LPSN gives as synonyms of their species are synonyms; species sit in the groups that
  hold them; names the NHSN Organism List (2024) enumerates are added; and some record numbers and `ConceptId`s are
  corrected. Where the list departs from what LPSN records, as for two merges that LPSN's notes support and for the
  concepts whose taxon LPSN gives no correct name, among them the names it lists as not validly published,
  `Comments.Background` says why. A former concept keeps its `Id` as a synonym, so no collected value changes meaning.
  Streptococcus massiliensis (2789), now among the viridans streptococci, is a common commensal. The 18 new `Id`s, 3570
  to 3587, have UIDs in `NeoIPC-Infectious-Agents.uids.csv`.
- The viruses follow ICTV's Master Species List 2025 (MSL41), as ICTV corrected it on 14 October 2026: a virus concept
  takes the name, rank, and lineage that release gives its taxon, and its node there as the `ConceptId`, while a
  synonym, a former name, keeps the node of the release whose name it carries. The realm Monodnaviria is now
  Floreoviria; the new family Hepaciviridae holds Pegivirus and Orthohepacivirus, formerly Hepacivirus, whose species
  Orthohepacivirus hominis is a new concept over Hepacivirus hominis (3501); and the list's species of Orthoflavivirus
  sit in the new subgenus Euflavivirus. The release splits Orthoflavivirus encephalitidis (3553) into two species, so
  Tick-borne encephalitis virus (2389) is now a NeoIPC group holding them, with 3553 as its synonym, and no collected
  value changes meaning. NeoIPC's virus groups hold the taxa they cover where those share one parent, as Human
  adenovirus (2692) holds its seven species and Influenza virus (2659) its four genera; a group of the types of one
  species sits beneath that species, as Echovirus (2681) does, or beneath the group that holds it, as Human
  coxsackievirus B (2625) does; and any other group says in `Comments.Background` which species it covers. Poliovirus
  (2635), which now holds its three serotypes, is a group rather than a serotype, and its DHIS2 option's label says so.
  New are the species the groups now hold, Orthoflavivirus mediterranense, the parechoviruses, the enteroviruses A and D
  with Enterovirus A71 and D68, and the species of the four seasonal human coronaviruses, and so are Human herpesvirus 4
  and 5 as synonyms. The 32 new `Id`s, 3588 to 3619, have UIDs in `NeoIPC-Infectious-Agents.uids.csv`.
- The fungi follow MycoBank, its list of fungal names of 7 January 2026 and, for the records changed since, its web
  services as of 4 November 2026: a fungal concept takes the name MycoBank gives as current and sits where MycoBank
  classifies that name's record, a higher taxon cites the legitimate record of its name where one exists, and where
  MycoBank's records disagree on a name, the concept takes the one that agrees with its genus; a node's
  `Comments.Background` says where the list departs from MycoBank's records and why, as for Hormodendrum (300), which
  sits in Cladosporiaceae, and Candida mycoderma, the concept over Azymocandida mycoderma (3349). A name that gives way
  stays as a synonym with its `Id`, so no collected value changes meaning. The three species of the group Candida
  parapsilosis complex (2701), which keeps its name and now sits in Lodderomyces, are Lodderomyces metapsilosis,
  orthopsilosis, and parapsilosis; Candida sake and Candida zeylanoides are Fermentozyma sake and Dujonia zeylanoides;
  Cyberlindnera (3566) is Petasospora, and Cyberlindnera fabianii is Petasospora fabianii, while Cyberlindnera jadinii,
  with Candida utilis among its synonyms, is Williopsis jadinii; Pichia inconspicua, now an invalid name, gives way to
  Candida inconspicua; and Trichomonascus ciferrii is Blastobotrys ciferrii, Amesia atrobrunnea Amesomyces atrobrunneus,
  Phialophora americana Capronia americana, Sporotrichum pruinosum Phanerochaete chrysosporium, and Ochroconis humicola
  Scolecobasidium humicola. Penicillium aurantiogriseum is the concept over its type variety, and Candida pintolopesii
  var. pintolopesii over its species; Aspergillus oryzae, Fusarium sporotrichioides, Microsporum brachytomum, Candida
  mycoderma, and the genus Schwanniomyces (2254) are concepts, and Alternaria tenuissima is a synonym of Alternaria
  alternata. Plasmodium (401) and Sarcocystis (88), apicomplexan protozoa that MycoBank files under Fungi, sit under
  Protozoa. The 14 new `Id`s, 3620 to 3632 and 3640, have UIDs in `NeoIPC-Infectious-Agents.uids.csv`.
- `UrlTemplates.MycoBank` in `NeoIPC-Infectious-Agents.yaml` links to a name's MycoBank page by its MycoBank number,
  `https://www.mycobank.org/page/Name%20details%20page/field/Mycobank%20%23/{0}`, which takes a node's `MycoBankNr` in
  place of its `ConceptId`, the ID of the name's record in MycoBank's database.
- The common-commensal flags follow the NHSN Organism List (2024), branch by branch: a flag sits on the highest
  node where its status holds, a NeoIPC group such as Coagulase-negative staphylococci (2776) and Viridans
  streptococci (2798), or a genus, with an override beneath it only where the status differs, and none on a
  synonym. Each flag carries its reason in `Comments.CommonCommensal`, and a node whose flags stay beneath it,
  although one flag on it would hold for all of them, says there why. Coagulase-negative staphylococci (2776), with
  Staphylococcus schleiferi (741), and Parageobacillus thermoglucosidasius (3174), with its synonyms (2437 and 1997),
  are common commensals; Streptococcus gallinaceus (2785), Streptococcus minor (2791), and Streptococcus
  thoraltensis (2793), outside the viridans streptococci, are not. The Streptococcus bovis group (2801),
  Paenibacillus thiaminolyticus (579), Rhodococcus equi (1776), Corynebacterium ulcerans (2113), Corynebacterium
  pseudotuberculosis (214), Corynebacterium belfantii (2916), and Corynebacterium rouxii (2926) are recognized
  pathogens, departing from the NHSN Organism List (2024), each reason saying why. New are the NeoIPC groups
  Coryneform bacteria, with Diphtheroids as its synonym and Aerobic diphtheroids and Anaerobic diphtheroids beneath
  it; Alpha-hemolytic streptococci, not Streptococcus pneumoniae, under Alpha-hemolytic streptococci (2795); Group F
  streptococci, under the Streptococcus anginosus group (2799); and the Bacillus circulans group, all of them common
  commensals, as NHSN lists them. Not listed (0) and Unidentifiable (3561) say in `Comments.Background` why they are
  recognized pathogens. The 7 new `Id`s, 3633 to 3639, have UIDs in `NeoIPC-Infectious-Agents.uids.csv`.
- `NeoIPC-Infectious-Agents.uids.csv` holds the DHIS2 UID of every `Id`: the 113 `Id`s production has not
  deployed, which had no row, and whose options the metadata packages gave UIDs derived from their codes, have
  random ones, as every new `Id` gets from NeoIPC-Tools' `Add-NeoIPCInfectiousAgentUid`, and CI fails for an `Id`
  the file lacks.

### Deprecated

- `NeoIPC-Pathogen-Concepts.csv` and `NeoIPC-Pathogen-Synonyms.csv` are frozen: kept byte for byte for the readers
  outside this repository that download them, a legacy reporting service and neoipcr's data-preparation script, and
  to be removed once neither does and the Core Protocol's list of infectious agents is built from the ontology.

## [0.1.0-alpha] - 2026-09-07

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
