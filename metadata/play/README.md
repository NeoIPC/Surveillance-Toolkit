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
| `organisationUnits.csv` | One synthetic **test hospital + department per country** (`<CC>_TEST` / `<CC>_TEST_TEST`), plus a second Austrian test department, `AT_TEST_TEST2`. The production base carries no test hierarchy of its own. |
| `organisationUnitGroupMemberships.csv` | Authored group memberships for the synthetic units — `TEST_UNITS`, `NEO_DEPARTMENT`, and the eligibility / trial-site groups (`NEOIPC_ALL_PATIENTS_ELIGIBLE`, `NEOIPC_NEODECO_TRIAL_SITES`). |
| `users.csv` | Synthetic accounts — a superuser admin, data-entry users, the report-only personas (`play.at.report1` / `play.ch.report1`), and report-admin / admin-only variants. |
| `userRoleAssignments.csv`, `userGroupMemberships.csv`, `userOrgUnitAssignments.csv` | Each play user's roles, group membership, and org-unit scope. |

Row order is deterministic (see [`../common/README.md`](../common/README.md)); this
overlay mirrors the layout production supplies out-of-band via `-OverlayPath`.

## `TEST_UNITS` membership is deliberately asymmetric — do not normalise it back

`organisationUnitGroupMemberships.csv` makes **only `AT_TEST_TEST2`** a `TEST_UNITS`
member; the other `*_TEST_TEST` departments — notably `AT_TEST_TEST` and
`CH_TEST_TEST` — are intentionally **not** members:

- The report-only personas `play.at.report1` / `play.ch.report1` render reports scoped
  to `AT_TEST_TEST` / `CH_TEST_TEST`. neoipcr **excludes** `TEST_UNITS`-classified org
  units unless `include_test_data = TRUE`, so those two departments must **shed**
  `TEST_UNITS` to be visible to those renders by default.
- `AT_TEST_TEST2` is retained as the one genuinely test-classified department, so the
  `TEST_UNITS` classification path
  ([`OrgUnits.ps1`](../../scripts/modules/NeoIPC-Tools/Public/OrgUnits.ps1)) and the
  `include_test_data` code path keep coverage.

`AT_TEST_TEST2` is hospital-parented (level 4 under the `AT_TEST` hospital) like every
other play test department — the play tree has no flat "test root" node. This does not
affect classification: `OrgUnits.ps1` sets `HospitalCode` / `CountryCode` to `$null`
for any `TEST_UNITS` member **regardless of its parent**, so the hospital parent is
ignored — and the case usefully exercises flattening a unit that *does* have a
hospital/country parent.

`AT_TEST_TEST2` also carries an **explicit** `NEO_DEPARTMENT` row, whereas the other
departments get that membership **structurally** — the authoring step derives
`NEO_DEPARTMENT` from the `_TEST_TEST` code suffix, which `AT_TEST_TEST2`
(`…_TEST_TEST2`) does not match, so its department membership must be authored here.
