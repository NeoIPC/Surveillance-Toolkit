# Changelog — NeoIPC Core Protocol

Notable changes to the surveillance protocol document and the reference lists printed with it.

This product is versioned independently of the others in this repository: its version lives in
[VERSION](VERSION) beside this file, and its releases carry the `protocol-v` tag prefix. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

The release workflow reads the section matching the released version out of this file and publishes
it as the GitHub Release body, so a release cannot be cut for a version this file does not describe.

## [Unreleased]

### Added

- The printed data-collection forms, derived from the DHIS2 metadata in this repository rather than
  drawn by hand: section structure, field order, printed labels and choice lists all come from that
  source, so a form cannot drift from the model it depicts, and the forms are localized by the
  catalogue that already translates those labels. One layout produces both the figure the protocol
  embeds and the printable form, which compiles to PDF/A-2a and PDF/UA-1. A release attaches the forms
  as one archive per culture (`NeoIPC-Core-Collection-Forms[-<culture>].zip`).
- An explicit, short, stable anchor on every block a cross-reference can point at, so references
  resolve identically in every language; the build fails on a reference whose target does not exist.

### Changed

- The drawn figures — decision flow, title page and preview watermark — take their strings from the
  gettext catalogue like the rest of the document, replacing the per-figure `.resx` string tables and
  the XSLT that assembled them.
- The text follows the house spelling — Oxford British, taking the `-ize` form where it is also valid
  American English — and the definitions of necrotizing enterocolitis and laboratory-confirmed BSI with
  a recognized pathogen are renamed to match.

### Removed

- The English-only raster screenshots of the collection instruments, replaced by the derived forms
  above.

## [1.3.0-preview1] - 2026-07-07

First version published through this repository's release workflow. It carries a `-preview1` suffix,
so the workflow publishes it as a pre-release and the document renders with a preview watermark.

### Added

- The Core Protocol document, built from AsciiDoc and published as PDF and DOCX, with the printed
  antibiotic and infectious-agent reference lists. The antibiotic list is rendered from the same
  `NeoIPC-Antibiotics.csv` the DHIS2 option set is generated from, so the printed list and the
  collected data describe one vocabulary. The infectious-agent list is rendered from the legacy
  pathogen CSVs kept beside `NeoIPC-Infectious-Agents.yaml`, the canonical ontology the option set is
  generated from.
- `compatibility.yml`, recording the versions of the two shared lists this document incorporates. The
  release build verifies that record byte-for-byte against the released lists — for the infectious-agent
  list, the ontology and the legacy CSVs together — so the protocol cannot claim a list version whose
  content it does not actually print.
- German and Spanish translations of both reference lists: the antibiotic list through the gettext
  catalogues `po/antibiotics.<lang>.po`, the infectious-agent list through the `.<lang>.csv`
  translation sidecars beside the legacy CSVs. The document itself shipped in English.
