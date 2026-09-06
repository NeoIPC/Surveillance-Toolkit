# Changelog — NeoIPC Core Protocol

Notable changes to the surveillance protocol document and the reference lists printed with it.

This product is versioned independently of the others in this repository: its version lives in
[VERSION](VERSION) beside this file, and its releases carry the `protocol-v` tag prefix. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

The release workflow reads the section matching the released version out of this file and publishes
it as the GitHub Release body, so a release cannot be cut for a version this file does not describe.

## [1.3.0-preview1] - 2026-07-07

First version published through this repository's release workflow.

### Added

- The Core Protocol document, built from AsciiDoc and published as PDF and DOCX, with the printed
  antibiotic and infectious-agent reference lists rendered from the same shared sources the DHIS2
  option sets are generated from — so the printed list and the collected data describe one vocabulary.
- `compatibility.yml`, recording the versions of the two shared lists this document incorporates. The
  release build verifies that record byte-for-byte against the released lists, so the protocol cannot
  claim a list version whose content it does not actually print.
- German translations of both reference lists, maintained through the gettext catalogues rather than
  as separate documents.

### Notes

Carries a `-preview1` suffix, so the release workflow publishes it as a pre-release. The version line
predates this repository's release workflow; this is the first version cut through it.
