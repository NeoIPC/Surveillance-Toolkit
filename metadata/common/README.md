# Common Metadata

This directory contains the common metadata to populate the NeoIPC metadata package and the play database.

## Organisation units

`organisationUnits.csv` is the UID-keyed scaffold: the `NEOIPC` project root and one unit per country. The units
that exist in the production system (the root, the participating countries, and the `TEST_UNITS` explore
container) carry their **real production UIDs**; the remaining countries are eligible-but-not-yet-participating
and carry deterministically minted UIDs. Country codes are **ISO 3166-1 alpha-2** (`GR`, `GB`, …) and names are
English; the non-participating set was seeded from the eurostat country list and recoded to ISO. There is **no
region level** (production has none) — the `play` variant adds one test hospital + department per country.
Per-locale name translations live in `organisationUnits.<lang>.csv` (migrating to gettext PO with the rest of
the metadata translations).
