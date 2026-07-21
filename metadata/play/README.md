# Play package — synthetic org units and users

The **play** overlay: committed synthetic test org units, users, and their group /
role / org-unit memberships. `New-NeoIPCMetadataPackage -Play` stitches this overlay
onto the production install base to build the play / demo package (see
[`../dist/README.md`](../dist/README.md)), which seeds local and CI DHIS2 instances.
It is **synthetic test data only** — no real surveillance data, and the accounts carry
a known, clearly-test password.

## Files

| File | Contents |
|------|----------|
| `organisationUnits.csv` | Synthetic **test hospital + department per country** (`<CC>_TEST` / `<CC>_TEST_TEST`), plus four **`*_TEST_TEST2`** scratch departments (`AT` / `BE` / `CZ` / `EE`) for the Tracker Capture e2e coverage suite. The production base carries no test hierarchy of its own. |
| `organisationUnitGroupMemberships.csv` | Authored group memberships for the synthetic units — `TEST_UNITS`, `NEO_DEPARTMENT`, and the eligibility / trial-site groups (`NEOIPC_ALL_PATIENTS_ELIGIBLE`, `NEOIPC_NEODECO_TRIAL_SITES`). |
| `users.csv` | Synthetic accounts — a superuser admin, data-entry users (including the Tracker Capture e2e account `play.e2e.data1`, see below), the report-only personas (`play.at.report1` / `play.ch.report1`), and report-admin / admin-only variants. |
| `userRoleAssignments.csv`, `userGroupMemberships.csv`, `userOrgUnitAssignments.csv` | Each play user's roles, group membership, and org-unit scope. |

Row order is deterministic (see [`../common/README.md`](../common/README.md)); this
overlay mirrors the layout production supplies out-of-band via `-OverlayPath`.

## The `play.e2e.data1` account's role set is deliberate — both what it has and what it lacks

`play.e2e.data1` is the account the Tracker Capture e2e coverage suite runs as. Its role assignment
(`userRoleAssignments.csv`) is chosen precisely, in **both** directions:

- **Base + Data entry** for the data entry the suite drives, **plus `Update Delete User`** — the last one
  deliberately, because every spec **tears down the patient it provisions**. The bottom-up delete
  (events → enrollment → tracked entity) needs the cascade-delete authorities that role bundles
  (`F_ENROLLMENT_CASCADE_DELETE` / `F_TEI_CASCADE_DELETE` / `F_UNCOMPLETE_EVENT`); without them a spec
  cannot remove what it created and the target accumulates orphaned records run after run. It is a
  materially higher privilege than plain data entry, and it is present on purpose.
- **Not a superuser** (no `ALL`), equally on purpose: `ALL` makes the registration form's rule-driven
  `required` indicator return false outright, so a superuser account could not observe the
  mandatory-field program rules at all — the suite would silently pass without testing them.

## `TEST_UNITS` membership is deliberately asymmetric — do not normalise it back

There are two classes of play test department, and which of them are `TEST_UNITS` members
is load-bearing in **opposite** directions — do not flag or un-flag one to match the other:

- **The country-primary `*_TEST_TEST` departments** (notably `AT_TEST_TEST` and
  `CH_TEST_TEST`) are intentionally **not** `TEST_UNITS` members. The report-only personas
  `play.at.report1` / `play.ch.report1` render reports scoped to them, and neoipcr
  **excludes** `TEST_UNITS`-classified org units unless `include_test_data = TRUE`, so those
  departments must **shed** `TEST_UNITS` to be visible to those renders by default.
- **The `*_TEST_TEST2` departments** (`AT_TEST_TEST2`, `BE_TEST_TEST2`, `CZ_TEST_TEST2`,
  `EE_TEST_TEST2`) **are** `TEST_UNITS` members — scratch departments the Tracker Capture
  e2e coverage suite provisions patients in and tears down, kept out of the report personas'
  default `include_test_data = FALSE` renders. They exist as a **set of four** because the
  suite's enrollment rules branch on two org-unit groups, eligibility
  (`NEOIPC_ALL_PATIENTS_ELIGIBLE`) × trial site (`NEOIPC_NEODECO_TRIAL_SITES`), and the four
  span that 2×2: `BE` both, `CZ` trial-site-only, `AT` eligible-only, `EE` neither. They are
  spread across countries so no single country's node carries all the e2e write traffic.

So the `TEST_UNITS` classification path
([`OrgUnits.ps1`](../../scripts/modules/NeoIPC-Tools/Public/OrgUnits.ps1)) and the
`include_test_data` code path keep coverage via the `*_TEST_TEST2` set, while the report
renders keep meaningful `include_test_data = FALSE` behaviour via the `*_TEST_TEST` set.

Each `*_TEST_TEST2` department is hospital-parented (level 4 under its country's `*_TEST`
hospital) like every other play test department — the play tree has no flat "test root" node.
This does not affect classification: `OrgUnits.ps1` sets `HospitalCode` / `CountryCode` to
`$null` for any `TEST_UNITS` member **regardless of its parent**, so the hospital parent is
ignored — and the case usefully exercises flattening a unit that *does* have a hospital/country
parent.

Each `*_TEST_TEST2` department also carries an **explicit** `NEO_DEPARTMENT` row, whereas the
`*_TEST_TEST` departments get that membership **structurally** — the authoring step derives
`NEO_DEPARTMENT` from the `_TEST_TEST` code suffix, which the `…_TEST_TEST2` codes do not
match, so their department membership must be authored here.
