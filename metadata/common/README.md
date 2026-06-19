# Common Metadata

This directory contains the common metadata to populate the NeoIPC metadata package and the play database.

## Organisation units

`organisationUnits.csv` is the UID-keyed scaffold: the `NEOIPC` project root and one unit per country. The units
that exist in the production system (the root, the participating countries, and the `TEST_UNITS` explore
container) carry their **real production UIDs**; the remaining countries are eligible-but-not-yet-participating
and carry deterministically minted UIDs. Country codes are **ISO 3166-1 alpha-2** (`GR`, `GB`, …) and names are
English; the non-participating set was seeded from the eurostat country list and recoded to ISO. There is **no
region level** (production has none) — the `play` variant adds one test hospital + department per country.
Per-locale name translations live in the gettext PO component (`po/metadata.<lang>.po`) with the rest of the
metadata translations, converted to/from each object's `translations[]` by the pipeline.

## Row order

Rows in the per-type CSVs are sorted deterministically (ordinal, locale-independent) so diffs stay stable and
reviewable: the converter (`ConvertFrom-NeoIPCMetadataJson`) emits each type ordered by its natural key —
`code` (else `name`), with `optionSet`+`sortOrder` grouping for options and the parent + `sortOrder` for the
nested-only types. Row order is purely cosmetic: the round-trip matches objects by `id` and the comparator
sorts ref-collections, so re-ordering never changes the package. The authored junction files are ordered by
their member/subject first — `organisationUnitGroupMemberships` by `organisationUnit` then group, the user
files by `username`.
