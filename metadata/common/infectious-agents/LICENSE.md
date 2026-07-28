# Licensing

The content in this directory is compiled from multiple upstream data sources, each with its own copyright and license terms. Full citations and source URLs are in [`README.md`](README.md).

While the repository as a whole is licensed under the [MIT License](https://spdx.org/licenses/MIT.html), we cannot relicense the upstream content under terms that conflict with the licenses chosen by its authors. The effective license for this directory is therefore the strictest of the applicable upstream licenses: the Creative Commons [Attribution-NonCommercial-NoDerivatives 4.0 International (CC BY-NC-ND 4.0)](https://creativecommons.org/licenses/by-nc-nd/4.0/) license.

Because the MycoBank license includes a "NoDerivatives" clause, we asked the current MycoBank curators for permission to incorporate parts of their content into the NeoIPC infectious-agent ontology, and received their approval.

In addition, NHSN-derived content carries the CDC [requirements](https://www.cdc.gov/other/agencymaterials.html) for use of agency materials, which apply on top of the CC BY-NC-ND 4.0 terms above.

## Scope: this directory, not the translation catalogue

The terms above govern **the content of this directory** — `NeoIPC-Infectious-Agents.yaml`, the per-locale overlays generated from it, and the AsciiDoc output built from them.

They do **not** determine the licence of the gettext translation catalogue (`po/infectious_agents.pot` and `po/infectious_agents.<lang>.po`), which is published under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). The licence of a source directory is not automatically the licence of the strings extracted from it; what governs a catalogue is what the catalogue actually contains. Here the extraction is limited to the `Name`, `ConceptType` and `Value` keys, so every entry is a taxonomic name or synonym, a rank label (`Species`, `Genus`, `Subfamily`), a controlled value (`Unknown`, `Not listed`), or NeoIPC's own `Output-Header`/`Output-Footer` prose. None of the upstream descriptions, authorities, references or verification apparatus — the material these licences exist to protect — is carried across, and individual taxonomic names and rank labels are not subject to copyright in any case, being names and short phrases.

A NoDerivatives term could not apply to a translation catalogue in any event: a translation **is** a derivative work, so a catalogue published under CC BY-NC-ND could not lawfully be translated at all, which is the catalogue's only purpose.
