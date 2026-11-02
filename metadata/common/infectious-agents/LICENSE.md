# Licensing

The content in this directory is compiled from multiple upstream data sources, each with its own copyright and licence terms. Full citations and source URLs are in [`README.md`](README.md).

While the repository as a whole is licensed under the [MIT License](https://spdx.org/licenses/MIT.html), we cannot relicense the upstream content under terms that conflict with the licences chosen by its authors. The effective licence for this directory is therefore the strictest of the applicable upstream licences: the Creative Commons [Attribution-NonCommercial-NoDerivatives 4.0 International (CC BY-NC-ND 4.0)](https://creativecommons.org/licenses/by-nc-nd/4.0/) licence.

Because the MycoBank licence includes a "NoDerivatives" clause, we asked the current MycoBank curators for permission to incorporate parts of their content into the NeoIPC infectious-agent ontology, and received their approval.

In addition, NHSN-derived content carries the CDC [requirements](https://www.cdc.gov/other/agencymaterials.html) for use of agency materials, which apply on top of the CC BY-NC-ND 4.0 terms above.

## Scope: This Directory, Not the Translation Catalogue or Factual Extracts

The terms above govern **the content of this directory** — `NeoIPC-Infectious-Agents.yaml`, the per-locale overlays generated from it, and the AsciiDoc output built from them.

### The Translation Catalogue

The terms above do **not** determine the licence of the gettext translation catalogue (`po/infectious_agents.pot` and `po/infectious_agents.<lang>.po`), which is published under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). The licence of a source directory is not automatically the licence of the strings extracted from it; what governs a catalogue is what the catalogue actually contains. Here the extraction is limited to the ontology's `Name`, `ConceptType`, and `Value` keys and to the standalone list's `Output-Header` and `Output-Footer`, so every entry is a taxonomic name or synonym, a rank label (`Species`, `Genus`, `Subfamily`), a controlled value or list label (`Unknown`, `Not listed`, `Recorded Resistances`), or the text of that header and footer: NeoIPC's own introduction, and the citations, licence notices, and CDC disclaimer that attribute the sources. None of the upstream descriptions, authorities, per-name references, or verification apparatus — the material these licences exist to protect — is carried across, and individual taxonomic names and rank labels are not subject to copyright in any case, being names and short phrases.

A NoDerivatives term could not apply to a translation catalogue in any event: a translation **is** a derivative work, so a catalogue published under CC BY-NC-ND could not lawfully be translated at all, which is the catalogue's only purpose.

### Factual Extracts

Nor do the terms above govern an output that carries, for each infectious agent, nothing but

1. its `Id`;
2. its name and synonyms, and which name is a synonym of which;
3. its rank (`ConceptType`) and its lineage: the names and ranks of the nodes above it, NeoIPC's own among them;
4. the source its name is taken from and the identifier of its record there, which the output may render as a link to that record;
5. the common-commensal status and the resistance categories (`MRSA`, `VRE`, `3GCR`, `Carbapenems`, `Colistin`) that NeoIPC assigns to it, in the ontology or in its frozen CSVs;

with NeoIPC's own labels for these, and an attribution of the sources, which the last paragraph of this section requires of the outputs NeoIPC publishes. Such an output falls outside the CC BY-NC-ND 4.0 terms above and is licensed with the work that carries it. The *List of Infectious Agents* appendix of the NeoIPC Core Surveillance Protocol, whether built from this directory's CSV files or from its ontology, the infectious-agent tables bundled with the neoipcr R package, and the infectious-agent tables of the NeoIPC reports are such outputs. The standalone list of infectious agents built from this directory is not: it is the directory's own publication, carried by no other work, and stays under the terms above in every form, its CSV form, which carries the items above alone, included.

The reasoning is the catalogue's. The `Id`s, the infectious-agent groups, the resistance categories, and the labels are NeoIPC's own, and so is the common-commensal status where the NHSN Organism List is silent; elsewhere NeoIPC takes the status from that list, whose CDC requirements the next paragraph keeps. Names and rank labels are not subject to copyright. Apart from NeoIPC's own nodes (its infectious-agent groups and the top-level `Viruses` and `Eukaryota`), the lineage is each name's place in the classification its source publishes, for the infectious agents NeoIPC selected. None of the upstream descriptions, authorities, per-name references, or verification apparatus is carried across. An output that adds anything else from this directory, such as the `Output-Header`'s introduction, is governed by the terms above.

This concerns the CC BY-NC-ND 4.0 terms only. The CDC requirements for the use of agency materials still apply wherever NHSN-derived content is reproduced, and names translated through the catalogue keep the catalogue's CC BY 4.0 terms. An output NeoIPC publishes this way must attribute the sources that [`README.md`](README.md) lists.
