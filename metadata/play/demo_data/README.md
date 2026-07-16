# Play demo data — committed synthetic patient records

A **stable, deterministic** synthetic patient dataset for the play / demo DHIS2 instance, committed as CSVs
so every seed produces the **same** tracked entities, enrollments, and events. It is the tracker-data
counterpart to the org-unit / user overlay in [`../`](../): where that overlay authors *metadata*, this
authors *data* (patients enrolled in `NEOIPC_CORE`).

`New-NeoIPCPlayDataPackage` reads these CSVs, resolves the code handles to the target instance's UIDs, and
assembles a `/api/tracker` payload; `Import-NeoIPCPlayData` posts it. It is **synthetic test data only** — no
real surveillance data, no personal names (patient identifiers are `DEMO-####` / `E2E-*`).

## Two tiers

| Directory | Origin | Edit by hand? |
|-----------|--------|---------------|
| `bulk/`   | **Generated once** and frozen — a snapshot of the NeoIPC synthetic-data generator's output, serialized by `Export-NeoIPCPlayDataCsv` (this module). Provides the volume + multi-department spread the reference-data and report consumers need. | **No** — a direct edit is lost on the next re-freeze. Change the generator and re-freeze (below). |
| `curated/`| **Hand-authored** — small, deliberate patients for specific test scenarios (e.g. the Tracker Capture ACTIVE fixture). Expected to **grow** as coverage expands. | **Yes** — this is the place to add scenario patients. Validate every addition (below). |

Both tiers use the **same four-file schema**; the builder reads both and unions them. Splitting them by
directory (rather than a `tier` column in shared files) means a `bulk/` re-freeze rewrites only `bulk/` and
never touches the hand-authored `curated/` rows.

## Schema (codes, not UIDs)

Every reference is a **code** (data-element code, TEA code, org-unit code, stage key) that the builder
resolves to the target instance's UID at build time — so the same committed data imports on any DHIS2
version running the NeoIPC metadata package. Each `id` is a **committed DHIS2 UID** (11-char), so re-imports
upsert idempotently (`CREATE_AND_UPDATE`) instead of duplicating.

| File | Columns |
|------|---------|
| `trackedEntities.csv` | `id`, `orgUnit`, then one column per **TEA code** (`NEOIPC_PATIENT_ID`, `NEOIPC_TEA_SEX`, `NEOIPC_TEA_BIRTH_WEIGHT`, `NEOIPC_TEA_GEST_AGE`, `NeoIPC_TEA_TOTAL_GESTATION_DAYS`, `NEOIPC_TEA_DELIVERY_MODE`, `NEOIPC_TEA_MULTIPLE_BIRTH`, `NEOIPC_TEA_SIBLINGS`; a blank cell = attribute unset). Every non-`id`/`orgUnit` header is treated as a TEA code, so a new attribute is just a new column. |
| `enrollments.csv` | `id`, `trackedEntity`, `orgUnit`, `enrolledAt`, `occurredAt`, `status` (`ACTIVE`\|`COMPLETED`\|`CANCELLED`), `completedAt` (blank unless completed) |
| `events.csv` | `id`, `enrollment`, `programStage` (stage key: `adm`, `pro`, `bsi`, `nec`, `ssi`, `hap`, `end`), `orgUnit`, `occurredAt`, `status`, `completedAt` |
| `eventDataValues.csv` | `event`, `dataElement` (code), `value` |

**Why `eventDataValues.csv` is normalized (long form), not per-event-type wide files:** each of the seven
event types sets a different, sparse subset of data elements (a BSI event's pathogen slots 1-3 × resistance
flags + clinical findings vs. a surveillance-end's substance slots 01-09 × days), so per-type wide files
would be sparse, would churn their schema every time a data element is added, and would be awkward to diff.
The long form is uniform across all stages and diffs per value. `events.csv` carries each event's
`programStage`, so a reader sees which type an event is; data-value rows are grouped by `event` and ordered
by data-element code so a single event's block reads coherently.

### Dates

`bulk/` dates are **absolute** and frozen at bootstrap time (all in the past relative to any future seed, so
DHIS2 never rejects a future date). `enrolledAt` must equal the Admission event's `occurredAt` (program rule
`kuQVuXXgPk0`), and every enrollment sets `occurredAt = enrolledAt` (a DHIS2 2.41 preheat-cache workaround —
the importer's cached `Program` serves the entity-default `displayIncidentDate = true`, so a null enrollment
`occurredAt` is rejected at COMMIT with `E1023`).

## The Tracker Capture ACTIVE fixture (`curated/`)

`NEOIPC_PATIENT_ID = E2E-TC-FIXTURE` in `AT_TEST_TEST` carries **two** enrollments (a tracked entity may
hold several — this mirrors the generator's hernia-readmission pattern):

- a **COMPLETED** enrollment (Admission → Surveillance-End) — a normal completed patient a read consumer can
  key on by identifier;
- a later **ACTIVE** enrollment with a **COMPLETED Admission event** (so downstream ASSIGNs resolve, e.g. the
  BSI "Day of life"), the infection/surgery stages left **empty** so a UI spec can add a fresh event and
  drive its program rules.

Consumers resolve the tracked entity **by this identifier**, never by position. Do not renumber it.

## Program-rule validity — validate every change

The seed imports with the server-side rule engine on (DHIS2 2.41+), so every patient must pass the ~200
`NEOIPC_CORE` program rules. When you add or edit a `curated/` patient:

1. Dry-run it: `New-NeoIPCPlayDataPackage` → `Import-NeoIPCPlayData -DryRun` (importMode=VALIDATE) against a
   fresh synthetic stack.
2. Then a **real commit** — VALIDATE never reaches the commit phase, so it is necessary but not sufficient
   (the `E1023` preheat bug above only bites at COMMIT).

## Re-freezing `bulk/`

`bulk/` is a one-time snapshot; re-freeze only when a metadata / rule change makes the frozen data no longer
validate. `Export-NeoIPCPlayDataCsv` (this module) is the serializer: give it the NeoIPC synthetic-data
generator's `-DryRun` `/api/tracker` payloads (which persist nothing) and it reverse-maps every UID back to
its code, mints deterministic committed UIDs, and writes these four CSVs:

```powershell
Export-NeoIPCPlayDataCsv -InputPath $generatorDryRunJsonFiles -OutputDirectory <path-to>/bulk -Auth $auth @endpoint
```

Only `bulk/` is (re)written — the hand-authored `curated/` tier is never touched. Review the diff and validate
before committing (below).

## Row order

Rows are sorted deterministically (by `id`, then parent + `id`) so diffs stay stable and reviewable, matching
the [`../../common/README.md`](../../common/README.md) convention.
