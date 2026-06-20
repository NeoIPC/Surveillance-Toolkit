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

## Sharing

DHIS2 attaches a `sharing` object (a `public` access string plus optional per-user and per-user-group
grants) to most metadata objects, but across the package only a handful of distinct shapes actually occur. They are named
once in [`sharing.yaml`](sharing.yaml) and every per-type CSV's `sharing` column carries just the **profile
key** (e.g. `PUBLIC_RW`, `NEOIPC_DATA_EDIT`) instead of a JSON blob repeated on hundreds of rows. The
converter expands the key into the DHIS2 sharing object on assembly and maps a captured sharing object back
to its key on round-trip; an unrecognized shape fails loud so a human names it in `sharing.yaml` rather than
it being silently absorbed.

Grants are keyed by the user-group **code** (falling back to its unique name for a codeless group) so the
file stays human-editable — the converter resolves the handle to the group UID against `userGroups.csv`, and
an unknown code/name fails loud. The grant's `displayName` is deliberately not stored (it is server-derived
from the id, and carrying it duplicates a name that drifts — the same reason the rest of the pipeline strips
the `display*` family). The directory is self-contained: when no `sharing.yaml` is present (a throwaway work
directory, e.g. the round-trip gate) the converter derives the profiles from the package and writes one out.
