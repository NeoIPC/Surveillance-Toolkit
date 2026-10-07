# NeoIPC-Tools PowerShell Module

PowerShell tools for the NeoIPC Surveillance project: DHIS2 admin operations,
report-generation helpers, and pipeline-composable data inspection.

Requires **PowerShell 7.6+**.

## Installation

The module is not published to a gallery. Import it directly from the
repository:

```powershell
Import-Module ./scripts/modules/NeoIPC-Tools
```

Report-generation scripts (`Build-PartnerReport.ps1`, etc.) import the module
automatically.

## Architecture & Subsystems

The module spans two broad areas:

1. **Live DHIS2 admin & inspection + report helpers** — talk to a running DHIS2
   server (auth, org-unit / tracker / user inspection, PAT lifecycle) and drive
   the Quarto/R report builds. This is the usage cookbook below.
2. **The metadata pipeline + ontology-driven generation** — a **file-only**
   subsystem (no API calls) that moves the DHIS2 metadata between an importable
   `metadata.json` export, a reviewable per-type `metadata/` directory, and an
   assembled play / production package, and generates the pathogen / substance /
   field-gating objects from the infectious-agent ontology + a capability matrix.

This section is the architecture map for area 2. The **design rationale** behind it —
the locked decisions (canonical directory, opaque UIDs, the two variants, the
export→prune→normalize→reconcile reverse path, Node-free expressions), the diffability
principles, the capability matrix, and the verification gates — lives in
[`docs/metadata-pipeline-design.md`](../../../docs/metadata-pipeline-design.md).

### Files at a Glance

`Public/` holds the exported surface; `Private/` the implementation. Each
`.ps1` is one cohesive subsystem:

| File | Role |
|------|------|
| `Public/Auth.ps1` + `Private/DHIS2Http.ps1` | DHIS2 auth (PAT / user-password) + the REST GET/POST/PUT/DELETE layer every live call goes through |
| `Public/OrgUnits.ps1`, `Tracker.ps1`, `UserInfo.ps1`, `DataElements.ps1`, `PAT.ps1` | Live, pipeline-composable inspection of org units, patients/enrolments/events, users, DE codes, and personal-access-token lifecycle |
| `Public/PatientRemoval.ps1` + `Private/PatientRemoval.ps1` | **Remove patients** entered in error (`Remove-NeoIPCPatient`): select them by department and patient ID or by UID, refuse what a deletion would take with it unseen, preview with DHIS2's own dry run, confirm once, delete one patient per request, and prove each deletion by reading it back; the planning half is free of I/O ([Removing Patients](#removing-patients)) |
| `Public/ReportHelpers.ps1` | Report-build helpers — scoped auth env vars, Quarto/Rscript invocation, locale resolution, build summaries |
| `Public/InfectiousAgents.ps1` | Infectious-agent ontology helpers (next free `Id`) |
| `Public/Metadata.ps1` | The metadata-pipeline public surface — convert, compare, round-trip, closure, lint, update, **assemble** (`New-NeoIPCMetadataPackage`), translation export/import |
| `Public/MetadataDeploy.ps1` + `Private/MetadataDeploy.ps1` | **Deploy** a package to a DHIS2 instance (`Deploy-NeoIPCMetadata`): compare with the live objects, write only what differs in the order DHIS2 needs, gate the hazardous changes, verify; the planning half is free of I/O ([`docs/metadata-deployment.md`](../../../docs/metadata-deployment.md)) |
| `Public/MetadataVerify.ps1` + `Private/MetadataLive.ps1` | Read a package's objects back from DHIS2 and report what did not land (`Test-NeoIPCMetadataImport`), check that every rule action is served (`Test-NeoIPCProgramRuleActionServed`); the batched live read and the schema index the deployment shares |
| `Private/TrackerDialect.ps1` | The tracker read parameters and response key per DHIS2 version, the attribute-filter escaping and whether a version reads an escaped value back exactly, the list read that throws when the key is missing, and the tracked-entity read that throws on any entity it did not ask for |
| `Public/MetadataReconcile.ps1` | **Reconcile** the canonical directory against a fresh export (`Update-NeoIPCMetadataDirectory`) — classify drift, auto-write CSV-owned config + PO, report-only for authored / generated / domain |
| `Public/Generation.ps1` | The ontology/matrix-driven object generators (pathogen + substance + field-gating + virus-classification) |
| `Public/Regeneration.ps1` | Re-materialize the generated families into `metadata/common/` (`Update-NeoIPCGeneratedMetadataDirectory`) — the generators are the source of truth; this writes their current output back so drift shows as a git diff |
| `Private/Metadata.ps1` | Pipeline **core** — JSON parse, deterministic UID mint, row↔object cell coercion, sharing-profile registry, noise-strip, canonicalize, CSV I/O, package↔directory, semantic compare |
| `Private/MetadataTypeMaps.ps1` | Per-type field classification (translatable vs technical vs nested), the normalization strip-list, and the non-closure type list — the data the core consults |
| `Private/MetadataClosure.ps1` | The dependency-closure prune from `NEOIPC_CORE` (structured + expression ref-walk) + the whole-type base⊕supplement merge |
| `Private/MetadataExpression.ps1` | Program-rule expression handling — canonicalizer, issue linter, embedded-UID scanner, UID-regeneration rewrite |
| `Private/MetadataAuthoring.ps1` | Read the UID-keyed directory's authored content — org units, users (+ role/org-unit assignments), org-unit-group + user-group memberships |
| `Private/MetadataAssembly.ps1` | Stitch closure config + authored content into the final package (`Join-NeoIPCMetadataPackage`) |
| `Private/MetadataTranslation.ps1` | The gettext-PO subsystem — translation-unit extraction, PO emit/parse/merge, inject `translations[]` |
| `Private/MetadataGeneration.ps1` | The generation **plans** — pathogen/substance/field-gating DE+PRV+rule plans, resistance + common-commensal + **virus** effective-flag/code-set computation, the per-slot capability matrix |
| `Public/DataDictionary.ps1` + `Private/DataDictionary.ps1` | The **data-dictionary** generator (`Export-NeoIPCDataDictionary`) — flattens the assembled package into a technology-agnostic spreadsheet (patient attributes, per-stage data elements, the event dates, and every code list in full) as CSV + a multi-tab `.xlsx` (via `DocumentFormat.OpenXml`, provisioned under `lib/`) |

### Metadata Pipeline — Data Flow

Everything here is file-only (no DHIS2 API calls). The **canonical source** is the
`metadata/` directory plus the infectious-agent ontology — not the export, which is
only the dependency-closure seed and the round-trip oracle.

```
   metadata/  (per-type CSV + YAML + sharing.yaml)          <- canonical config
   metadata/common/infectious-agents/...-Agents.yaml        <- canonical pathogen ontology
   metadata/common/antibiotics/NeoIPC-Antibiotics.csv       <- canonical substances (ATC)
   metadata.json export  (PII-cleaned: closure seed + round-trip oracle)
        |
        v
   +------------------------------------------------------------------------+
   | ConvertFrom / ConvertTo-NeoIPCMetadataJson   export <-> directory       |
   | Select-NeoIPCMetadataClosure                 prune to NEOIPC_CORE       |
   | Update-NeoIPCMetadata / Test-...Expression   lint . canonicalize .      |
   |                                              regenerate UIDs            |
   | New-NeoIPCPathogen* / New-NeoIPCSubstance*   ontology + matrix -> objs  |
   | New-NeoIPCMetadataPackage                    assemble play / production |
   | Export-NeoIPCMetadataTranslation             -> po/metadata.pot         |
   | Import-NeoIPCMetadataTranslation             <- po/metadata.<lang>.po   |
   +------------------------------------------------------------------------+
        |
        v
   importable metadata.json (play / production)  +  Weblate PO component
```

`New-NeoIPCMetadataPackage` is the assembly entry point: it prunes the export to the
`NEOIPC_CORE` closure, adds the non-closure definitions (org-unit groups, roles),
noise-strips, then overlays the authored org units / users / memberships read from the
`metadata/` directory and emits importable JSON. The generators produce the pathogen /
substance / field-gating objects from the ontology + capability matrix, each preserving
the deployed UIDs where they exist (else minting deterministically) so a regenerated
object replaces its deployed counterpart cleanly.

`Update-NeoIPCMetadataDirectory` is the reverse path: it ingests a fresh export and brings the
directory into line with it (report-only unless `-Apply`), auto-writing only the CSV-owned config
it can faithfully reconcile — and reporting the rest by owner. Authored org units / users (the
export carries only anonymized instances), the ontology-generated families, and the domain YAML are
never reverse-written; an unexpected change surfaces as `Unclassified` for investigation.

### Materialized Generation, Drift Detection & the No-Hand-Authored-Enumeration Rule

The ontology- and capability-matrix-driven families — the per-slot pathogen / substance data
elements, and the resistance / field-gating / **virus** / substance program-rule variables, rules and
actions — are **materialized (committed)** under `metadata/common/` as CSV rows plus externalized
`.dhis2` expression files. Their **source of truth is the generators** (`New-NeoIPCPathogen*` /
`New-NeoIPCSubstance*`, spliced by `Add-NeoIPCGeneratedMetadata`), **not** the committed files:
`New-NeoIPCMetadataPackage` **reads** the materialized files when it assembles a package (it regenerates
only the option-domain families at assembly), so a change to a generator, the infectious-agent ontology,
or the antibiotic sources is **inert** until the directory is re-materialized.

`Update-NeoIPCGeneratedMetadataDirectory` (in `Public/Regeneration.ps1`) is that re-materialize step. It
regenerates every generated-class object and writes it back into `common/` through the faithful
directory writer (`ConvertFrom-NeoIPCMetadataJson`: LF / UTF-8-no-BOM CSVs, one file per expression with
trailing whitespace trimmed and one closing newline). Two design points make it correct and safe:

- **The UID-preservation Export is the assembled install base, not `common/` alone.** The option-domain
  families (`NEOIPC_PATHOGENS` / `NEOIPC_ANTIMICROBIAL_SUBSTANCES` option sets + options + groups) are
  deliberately **not** materialized into `common/` (a richer source — the ontology YAML + a UID sidecar +
  the antibiotic CSVs — owns them), yet the generators reconcile every reproduced object against the
  deployed option set. `New-NeoIPCMetadataPackage` assembles exactly that base, so it is the Export; the
  committed `common/` tree is the Config. Reversing the two would drop the option-set UIDs.
- **It is idempotent.** The writer rewrites every CSV of `common/` in one canonical form (fixed column
  order, sorted rows and lists, minimal quoting), so a drift-free tree comes out byte-identical and
  running it twice produces the same result. A hand edit in another form is rewritten too.

`Build-NeoIPCMetadataDistribution.ps1` runs `Update-NeoIPCGeneratedMetadataDirectory` on **every build**,
before rendering the packages, so any divergence between the generators and the committed
`metadata/common/` tree surfaces as a **reviewable git diff** (a dirty tree after a build means the
committed metadata is stale, or was hand-edited in another form, and must be committed). CI's
`build-metadata` job fails when the build changed anything under `metadata/`.
`Compare-NeoIPCGeneratedMetadata` reports the generator drift without writing.

> **Additive-writer limit.** `ConvertFrom-NeoIPCMetadataJson` writes/overwrites files for the objects it
> is given but never **deletes** the expression files (or prunes the CSV rows) of a generated object that
> regeneration **drops or renames** (lowering the slot count, or an ontology change that removes/renames a
> rule). Those orphaned `expressions/<rule>/*.dhis2` files linger as unchanged tracked files that
> `git status` does not flag, so the automatic drift-as-git-diff guarantee covers **additions and content
> changes but not removals/renames** — the orphaned files must currently be deleted by hand.

**The rule this enforces: a program-rule expression that _enumerates an externally-sourced set_ is
GENERATED from that source, never hand-authored.** The membership sets — the ontology's virus kingdom
(the `Viruses` realm), the common-commensal set, the per-category resistance sets, the antibiotic domain
— all live in canonical external sources, and any rule that lists their codes must be derived from them.
A hand-authored enumeration is a defect on two axes: it **silently drifts** from its source as the source
grows (the `set virus` rule had drifted to 155 of the ontology's 212 virus codes before it was made
generated), and a long flat `||` chain **overflows the DHIS2 2.41 expression-parser's recursive
evaluator** (a `StackOverflowError` at tracker import). The generators avoid both — they read the current
source, and `Join-NeoIPCBalancedBooleanChain` emits the chain as fixed-size flat blocks joined into a
**balanced** binary tree (parse-tree depth `(BlockSize-1) + ceil(log2 blockCount)`, bounded as the set
grows), pretty-printed one code per line so the committed expression is human-readable and line-diffable.
Genuine clinical logic that *consumes* generated booleans (e.g. the LCBSI validation conditions reading
`#{… is recognized pathogen}`) is correctly hand-authored — the rule targets *enumerations of external
data*, not all operator-rich expressions.

## Authentication

The `Read-*Info` cmdlets and the personal-access-token cmdlets accept a
`-Token` parameter (or read `$env:NEOIPC_DHIS2_TOKEN`); `Read-OrgUnitInfo`,
`Read-PatientInfo`, `Read-EnrolmentInfo` and `Read-EventInfo` take an `-Auth`
hashtable from `Resolve-NeoIPCAuth` as well. If no token is available, you are
prompted for username/password. The other cmdlets that talk to DHIS2 take
`-Auth`. Without `-Hostname`, a cmdlet talks to the NeoIPC production instance,
except the four that write metadata or tracker data (`Import-NeoIPCMetadata`,
`Deploy-NeoIPCMetadata`, `Import-NeoIPCPlayData` and `Remove-NeoIPCPatient`),
whose `-Hostname` is mandatory, so that they always name their target.

```powershell
# Token from environment variable (set once, used by all commands)
$env:NEOIPC_DHIS2_TOKEN = 'd2pat_...'

# Token from a file
$auth = Resolve-NeoIPCAuth -Token ./secrets/my-token.txt

# Interactive username/password prompt
$auth = Resolve-NeoIPCAuth
```

Tokens are validated against the DHIS2 v1 PAT format (`d2pat_` + 32 alphanum
\+ 10-digit CRC32). Invalid tokens are rejected immediately.

## OrgUnit Inspection

```powershell
# List all departments the current user can see
Get-NeoIPCDepartments -Auth $auth

# Rich org unit objects with hierarchy, trials, World Bank class
Read-OrgUnitInfo -Token $env:NEOIPC_DHIS2_TOKEN

# Filter by country
Read-OrgUnitInfo -CountryCode DE

# Filter by OU codes (friendly form) or UIDs
Read-OrgUnitInfo -OrgUnitCode NEO_DE_01, NEO_DE_02
Read-OrgUnitInfo -OrgUnitId abc123, def456
```

## User Inspection

```powershell
# All users
Read-UserInfo

# Users assigned to specific sites
Read-UserInfo -OrgUnitCode NEO_AT_01
```

## Patient, Enrolment, and Event Inspection (Pipeline-Composable)

Each `Read-*Info` cmdlet emits parent IDs and child ID lists on its
output objects, and accepts pipeline-bound filter parameters with
matching property names. Cross-cmdlet composition works by exact
property-name match — no `[Alias]` indirection, no `Select-Object`
renames.

```powershell
# All enrolments at Austrian sites
Read-EnrolmentInfo -OrgUnitCode NEO_AT_01, NEO_AT_02

# Pipe from org units (OrgUnitCode binds to -OrgUnitCode)
Read-OrgUnitInfo -CountryCode AT | Read-EnrolmentInfo

# Filter by date range
Read-EnrolmentInfo -AdmissionDateFrom 2025-01-01 -AdmissionDateTo 2025-06-30

# Search by patient ID (lives on Read-PatientInfo — its endpoint is the
# only one with attribute filters). Compose to get enrolments:
Read-PatientInfo -NeoIpcId 'NEO_AT_01-0042' | Read-EnrolmentInfo

# Reverse direction: enrolments → patients (TrackedEntityId binds)
Read-EnrolmentInfo -OrgUnitCode NEO_DE_01 | Read-PatientInfo

# Search events directly (new — replaces Read-EventSummary)
Read-EventInfo -OrgUnitCode NEO_DE_01 -EventType 'Primary Sepsis/BSI' `
  -OccurredAfter (Get-Date).AddDays(-90)

# "Who created events with custom organism names recently?" — the
# spike-investigation use case. -DataElementCode OR-composes
# client-side; supply each DE code the partners might have populated.
$codes = @(
    'NEOIPC_BSI_PATHOGEN_1_NAME','NEOIPC_BSI_PATHOGEN_2_NAME','NEOIPC_BSI_PATHOGEN_3_NAME',
    'NEOIPC_HAP_PATHOGEN_1_NAME','NEOIPC_HAP_PATHOGEN_2_NAME','NEOIPC_HAP_PATHOGEN_3_NAME'
    # …add more codes as needed (use Tab completion: -DataElementCode NEOIPC_<Tab>)
)
Read-EventInfo -DataElementCode $codes -UpdatedAfter (Get-Date).AddDays(-30) `
  | Group-Object OrgUnitId, CreatedBy `
  | Sort-Object Count -Descending `
  | Select-Object `
      @{ Name = 'OrgUnitCode'; Expression = { (Read-OrgUnitInfo -OrgUnitId ($_.Name -split ', ')[0]).OrgUnitCode } }, `
      @{ Name = 'CreatedBy';   Expression = { ($_.Name -split ', ')[1] } }, `
      Count

# Events at a partner (no DE filter — DataValues omitted from output)
Read-OrgUnitInfo -CountryCode DE | Read-EventInfo -EventType Pneumonia

# Reverse pipe: events → parent enrolments (gets DashboardUrl, etc.)
Read-EventInfo -OrgUnitCode NEO_DE_01 -EventType Pneumonia `
  | Read-EnrolmentInfo
```

## Working With Event dataValues

`Read-EventInfo` returns a `DataValues` PSCustomObject keyed by the DE
codes you passed in `-DataElementCode` (omitted from output when the
parameter is absent — UIDs aren't decoded to codes without a separate
metadata call).

```powershell
$events = Read-EventInfo -DataElementCode 'NEOIPC_BSI_PATHOGEN_1_NAME' `
  -OccurredAfter (Get-Date).AddDays(-30)

# Direct access by code
$events[0].DataValues.NEOIPC_BSI_PATHOGEN_1_NAME.Value
$events[0].DataValues.NEOIPC_BSI_PATHOGEN_1_NAME.StoredBy

# Flatten into a tabular form with one column per DE code
$events | Select-Object EventId, OccurredAt, CreatedBy -ExpandProperty DataValues
```

## Removing Patients

`Remove-NeoIPCPatient` deletes patients entered in error, each with all its
enrolments and events. Before it deletes anything it shows a preview with
DHIS2's own dry run, and it asks once; it then deletes one patient per request
and proves each deletion by reading the patient back.

```powershell
$auth = Resolve-NeoIPCAuth

# Preview, including DHIS2's own refusals; nothing is deleted.
Remove-NeoIPCPatient -OrgUnitCode NEO_DE_01 -NeoIpcId 'NEO-0042', 'NEO-0043' `
  -Auth $auth -Hostname neoipc.example.org -WhatIf

# Delete, after one confirmation.
Remove-NeoIPCPatient -OrgUnitCode NEO_DE_01 -NeoIpcId 'NEO-0042', 'NEO-0043' `
  -Auth $auth -Hostname neoipc.example.org

# Write the plan to a file, review it, then delete exactly the reviewed patients.
Remove-NeoIPCPatient -OrgUnitCode NEO_DE_01 -NeoIpcId (Get-Content ./ids.txt) `
  -Auth $auth -Hostname neoipc.example.org -WhatIf |
  Where-Object Outcome -eq 'WouldDelete' |
  Select-Object TrackedEntityId, OrgUnitId, OrgUnitCode, NeoIpcId | Export-Csv ./plan.csv
Import-Csv ./plan.csv | Remove-NeoIPCPatient -Auth $auth -Hostname neoipc.example.org
```

**Selection.** Every selection names the department its patients belong to,
since a NeoIPC patient ID is unique only within its department:

1. `-OrgUnitCode` with `-NeoIpcId`, matched exactly (DHIS2 itself compares
   patient IDs ignoring case);
2. `-OrgUnitCode` with `-TrackedEntityId`;
3. piped patient records carrying `TrackedEntityId` and `OrgUnitId`, and
   optionally `NeoIpcId`, which must then be the patient's.

Enrolment and event records carry `TrackedEntityId` too; the cmdlet refuses
them, so that a list of events can never select their patients.
`-MaximumCount` (default 25) caps a run before any request.

**What is refused.** DHIS2 deletes every live enrolment and event of a patient
with it, in every program, without checking them. A run therefore sends no
deletion for:

1. selectors that differ only in case, contradict each other, or are
   malformed;
2. a piped `OrgUnitId` that names no department, or another one than
   `-OrgUnitCode`;
3. before DHIS2 2.42, a patient ID holding more than one `/`, which those
   releases cannot look up: select such a patient by its UID;
4. a patient ID that matches more than one patient, and a piped `NeoIpcId`
   that is not the patient's;
5. a patient registered or owned outside the department, enrolled in another
   program, or with an enrolment or event in another org unit, and one whose
   read lacks what these rules check;
6. a patient that DHIS2's own dry run (`importMode=VALIDATE`, which `-WhatIf`
   runs too) refuses.

**Outcomes.** One object per selected patient:

| Outcome | Meaning |
|---------|---------|
| `WouldDelete` | `-WhatIf`: the patient would be deleted |
| `Declined` | the confirmation was declined |
| `Deleted` | the read-back shows the patient, and every enrolment and event the preview showed, deleted, and the patient's own read answers 404; a `Reason` says why the run stopped there |
| `AlreadyDeleted` | deleted before this run |
| `NotFound` | no such patient where DHIS2 looks, by program owner: by patient ID, in the department; by UID, within your data-capture org units, and on 2.43 for a superuser anywhere |
| `Refused` | by rules 1 to 6 (`Reason`, `ErrorCodes`) |
| `Failed` | DHIS2 answered, and the patient is still there |
| `Unverified` | neither the deletion nor its failure can be proven |
| `NotAttempted` | the run stopped before this patient |

DHIS2 looks a patient up by program owner, so where `NEOIPC_CORE` is the
patient type's only program, a patient the department registered whose
`NEOIPC_CORE` owner is another org unit comes back `NotFound` by its patient
ID. By its UID it comes back `Refused` (rule 5) when that owner lies within
your data-capture org units, or you are a superuser on 2.43, and `NotFound`
otherwise.

A run carries on after a failure that concerns one patient. It stops, naming
the cause in the `Reason` of the patient it stopped at, when DHIS2 denies
access, queues the deletion as a job, or gives an answer that contradicts the
request or the read-back; when DHIS2's answer is lost and the read-back does
not prove the deletion; and when the read-back fails or finds the patient's
data deleted in part. Running it again is safe: a deleted patient comes back
`AlreadyDeleted` by UID and `NotFound` by patient ID.
`-WhatIf` writes no errors; otherwise every result but `WouldDelete`,
`Declined`, `Deleted` and `AlreadyDeleted` writes one, the refusals before the
first deletion, so that `-ErrorAction Stop` deletes nothing while any selected
patient is refused or not found.

**Who may delete.**

1. A patient with a live enrolment needs `F_TEI_CASCADE_DELETE` (the role
   "Update Delete User" carries it, and `ALL` includes it), or DHIS2 refuses it
   with `E1100`.
2. The patient's registration org unit must lie within your data-capture org
   units, on DHIS2 2.40 to 2.42 even for a superuser (`E1000`).
3. Without `ALL`, a deletion also needs data-write access to the NeoIPC Patient
   type and to one of its programs, and ownership: the owner of the CLOSED
   program `NEOIPC_CORE` must lie within your data-capture org units (`E1003`;
   on 2.43 `E1001`, `E1323` or `E1324`).

The preview counts only the enrolments and events you can read, while DHIS2
deletes every live one.

DHIS2 2.40 and 2.41 refuse to delete a patient whose enrolment or event has a
scheduled program notification, which a "schedule message" program-rule action
creates; such a patient ends `Failed`. From 2.42 DHIS2 deletes the notifications
with the patient. With `http.security.csrf.enabled` on (2.42 and later), DHIS2
refuses every deletion.

**What DHIS2 keeps.** The deletion is logical:

1. The patient, its enrolments (set to `CANCELLED`) and its events stay in the
   database, flagged as deleted; the events keep all their data values.
2. Its attribute values, the patient ID among them, are removed. DHIS2 2.40 and
   2.41 keep each removed value in the attribute-value audit while
   `changelog.tracker` is on (the default); 2.42 and later clear the patient's
   attribute change log, though rows an upgrade did not migrate can remain in
   the older audit table.
3. Its notes and program-ownership records stay, and so do the files of
   file-type attributes; analytics tables keep the data until they are next
   generated.
4. The messages the program notifications of `NEOIPC_CORE` sent about the
   patient name its patient ID and stay as they are. Removing one in the
   Messaging app removes it for that user only, while
   `DELETE /api/messageConversations/{id}` deletes it for everyone, which needs
   `ALL`, or `F_METADATA_IMPORT` and, from 2.41, being one of the
   conversation's participants, such as a recipient.

**Removing the records for good** is DHIS2's maintenance task for soft-deleted
tracker data, a separate decision this cmdlet never takes. It removes every
soft-deleted patient on the instance, not only these, and needs `ALL` or
`F_PERFORM_MAINTENANCE`. Run it from the Data Administration app, or as
`POST /api/maintenance` with `softDeletedRelationshipRemoval`,
`softDeletedEventRemoval`, `softDeletedEnrollmentRemoval` and
`softDeletedTrackedEntityRemoval` (on 2.40:
`softDeletedTrackedEntityInstanceRemoval`, which 2.42 and later ignore without
an error) set to `true` together, since the tracked-entity removal alone can
fail on records the others remove first.

**Verified releases.** The cmdlet relies on DHIS2 behaviour read in the source
of 2.40.12, 2.41.10, 2.42.6 and 2.43.2, and confirmed by a removal run against
a synthetic instance of each. A later patch of one of these lines counts as
verified; any other release is refused before a patient is read, unless
`-AllowUnverifiedVersion` is given.

## Personal Access Token Lifecycle Management

```powershell
# List all personal access tokens
Read-DHIS2PersonalAccessToken
# Aliases: Read-PAT

# List specific tokens by ID
Read-DHIS2PersonalAccessToken -Id 'abc123'

# Remove a token
Remove-DHIS2PersonalAccessToken -Id 'abc123'
# Aliases: Remove-PAT

# Pipeline: remove all tokens
Read-PAT | Select-Object -ExpandProperty id | Remove-PAT

# Clear expired tokens
Clear-DHIS2PersonalAccessTokens
# Aliases: Clear-PATs

# Clear ALL tokens (including unexpired)
Clear-PATs -All
```

## Report Generation Helpers

These functions are used by the report scripts (`Build-PartnerReport.ps1`,
`Build-ReferenceReport.ps1`, etc.) but can also be called directly.

### Scoped Auth Environment Variables

```powershell
# Run a script block with DHIS2 auth env vars set (and securely cleared after)
$auth = Resolve-NeoIPCAuth -Token $Token
Invoke-WithNeoIPCAuth -Auth $auth -ScriptBlock {
    # $env:NEOIPC_DHIS2_TOKEN (or USER/PASSWORD) is set here
    # R/Quarto child processes pick it up via neoipcr::get_auth_data()
    quarto render Partner-Report.qmd
}
# env vars are restored to their original values here, even on error
```

### Quarto & Rscript Rendering

```powershell
# Render with error/warning parsing
$result = Invoke-QuartoRender -Arguments @('render', 'Report.qmd', '--to', 'pdf')
$result.Status   # 'Success' or 'Error'

# Rscript with rlang error handling
$result = Invoke-Rscript -Arguments @('--vanilla', 'Generate-Data.R', '--output', 'data.json')
$result.Status   # 'Success' or 'Error'
```

### Locale Handling

```powershell
# Split locale code
Split-NeoIPCLocale -Locale 'de_AT'
# @{ Language = 'de'; Territory = 'AT'; Code = 'de_AT' }

# Resolve localized QMD file (with fallback)
Resolve-NeoIPCLocaleQmd -ReportDirPath ./reports/Partner-Report -BaseName 'Partner-Report' -Locale 'de'
# Returns Partner-Report.de.qmd if it exists, otherwise Partner-Report.qmd
```

### Build Reports

```powershell
# Write a build summary to console and optionally to JSON. Common fields (site codes,
# locales/formats, per-step log, parameter snapshot, ...) are first-class parameters;
# the module owns the JSON schema so every report wrapper stays consistent by construction.
$status = Write-NeoIPCBuildReport -Name 'Partner Report Build' -StartedAt $startedAt `
    -Errors $errors -OutputFilePaths $outputFiles -BuildCompleted $true `
    -BuildReportFilePath './build-report.json' `
    -SiteCodes $siteCodes -OutputLocales @('en', 'de') -OutputFormats @('pdf')

# Per-step logging: build a step, then record its outcome from an
# Invoke-Rscript / Invoke-QuartoRender result ('Success' -> success, 'Error' -> error).
$step = New-NeoIPCBuildStep -SiteCode 'NEO_DE_01' -OutputLocale 'de' -OutputFormat 'pdf'
$step = $step | Complete-NeoIPCBuildStep -Result $renderResult
```

### Quarto Parameter Pairs

```powershell
# Convert a hashtable to -P key:value pairs for quarto render
$pairs = Build-QmdParamPairs -Values @{
    unitCodes = 'NEO_DE_01'
    reportingPeriodFrom = '2025-01-01'
}
# @('-P', 'unitCodes:NEO_DE_01', '-P', 'reportingPeriodFrom:2025-01-01')
```

## Tab Completion

`-OrgUnitCode` (on `Read-OrgUnitInfo`, `Read-UserInfo`, `Read-PatientInfo`,
`Read-EnrolmentInfo`, `Read-EventInfo`, `Remove-NeoIPCPatient`) and `-DataElementCode` (on
`Read-EventInfo`) support tab completion from local caches. Populate
them once with the unified cache-refresh script:

```powershell
./scripts/Update-NeoIPCCache.ps1                # refresh everything
./scripts/Update-NeoIPCCache.ps1 -Sites         # only site-codes cache
./scripts/Update-NeoIPCCache.ps1 -DataElements  # only DE-codes cache
```

After that, `-OrgUnitCode NEO_<Tab>` and `-DataElementCode NEOIPC_<Tab>`
complete from the cached lists.

## Metadata Translations (gettext PO)

The metadata pipeline keeps DHIS2 object i18n in a translator-facing gettext PO
component (one `po/metadata.pot` template + one `po/metadata.<lang>.po` per
language), separate from the structural per-type CSV directory. Each object's
`translations[]` (`{ property, locale, value }`, where `property` is the DHIS2
ObjectTranslation token — `NAME`, `SHORT_NAME`, `DESCRIPTION`, `FORM_NAME`,
`SUBJECT_TEMPLATE`, …) maps to a PO entry keyed by a stable msgctxt:

```
msgctxt = "<type>/<key>/<TOKEN>"   # key = optionSetCode/optionCode for options; else code; else a stable semantic key for the generated families; else the object UID
msgid   = the English/default base value (e.g. the object's name)
msgstr  = the translated value (empty in the .pot)
```

The msgctxt is code-based where a code exists (so it survives UID regeneration and
never orphans a translation in Weblate). The ontology/matrix-**generated** code-less
families (resistance / field-gating / substance program-rule variables, rules and their
actions) key on a **stable semantic key** mirroring the DE code scheme
(`NEOIPC_BSI_PATHOGEN_1_SET_3GCR`, …; actions `<ruleKey>/<TYPE>[/<targetDEcode>]`), derived
from the generator plans and independent of both the UID and the display name — so a
generator reword or slot-add yields a *local* `.pot` diff. Any **other** code-less object
(program stages / sections, validation rules, hand-authored rules — whose names are not
unique) falls back to the object UID, so its msgctxt is not regeneration-stable and the
English msgid carries the readable meaning. The two
domain-authored option sets
(`NEOIPC_PATHOGENS`, `NEOIPC_ANTIMICROBIAL_SUBSTANCES`) are excluded — their
translations belong with the option generation from the canonical YAML /
antibiotics CSV.

DHIS2 marks `name` translatable on every object, so the **full** surface is large
and mostly internal labels. Nothing is dropped; instead each string gets a Weblate
**priority** (`#, priority:NNN`) from `$NeoIPCMetadataTranslationPriorities`, so
translators clear the user-facing strings first: form-entry labels (`200`) > option
values / notifications / org-unit names (`150`) > user-facing titles (`100`, the
default) > the internal remainder (program-rule / data-element names, `10`). Retune
that table as needs change. The flag goes in the template and nowhere else: Weblate
treats `po/metadata.pot` as this bilingual component's source translation, reads the
flag there, and strips it when writing each language.

**Direction matters, and it is not symmetric.** This module **writes** `po/metadata.pot`
and reads it back nowhere; it **reads** `po/metadata.<lang>.po` and writes them never.
Those language catalogues are Weblate's — Weblate brings each one up to a changed
template through its own msgmerge add-on, and creates the catalogue for a newly added
language from the template — and two writers on one of them conflicts every language of
the catalogue at once. So `Export-NeoIPCMetadataTranslation` has no parameter that could
name a language, and neither does any helper beneath it.

**Source = the assembled package, not the directory.** `Export-NeoIPCMetadataTranslation`
takes either `-Package` (a parsed package) or `-Path` (a raw export). The committed
component must be regenerated from **`New-NeoIPCMetadataPackage`'s output**, because the
`metadata/` directory is *not* a complete translation source on its own: the
ontology/matrix-generated families (the per-slot pathogen / substance data elements and
their rules / variables) and the antibiotic domain are deliberately absent from it (the
generators and `po/antibiotics.*` own them). The assembler regenerates those families
with their corrected names, so feeding its package is what carries the fixed strings into
the `.pot`; a raw `-Path ./metadata.json` extract would instead capture the *stale deployed*
family names and the deployed antibiotic domain. Build the variant-**independent common
base** so no synthetic `play` hospital/department names (or real production org units) leak
into the translator catalogue — an empty `production` overlay yields the country scaffold
only. (A first-class common-only emit mode is planned; until then the empty overlay is the
seam.) Units are emitted in a **deterministic, locale-independent order** (type-map order,
then object key ordinal, then token order — independent of how the package orders its
objects), so re-running the refresh produces a minimal, reviewable diff.

```powershell
# Canonical refresh of the committed component, from the assembled common-base package.
$overlay = Join-Path ([System.IO.Path]::GetTempPath()) ('neoipc-pot-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $overlay | Out-Null
'id,code,name,shortName,openingDate,closedDate,level,parent,image,sharing' | Set-Content (Join-Path $overlay 'organisationUnits.csv')
'username,firstName,surname'        | Set-Content (Join-Path $overlay 'users.csv')
'username,role'                     | Set-Content (Join-Path $overlay 'userRoleAssignments.csv')
'username,organisationUnit'         | Set-Content (Join-Path $overlay 'userOrgUnitAssignments.csv')
$pkg = (New-NeoIPCMetadataPackage -ExportPath ./metadata.json -MetadataDirectory ./metadata `
            -Variant production -OverlayPath $overlay -PassThru).Package
Export-NeoIPCMetadataTranslation -Package $pkg -PoDirectory ./po -Validate   # regenerates po/metadata.pot only

# Quick ad-hoc extract from a raw export (NOT for the committed component — stale family names):
Export-NeoIPCMetadataTranslation -Path ./metadata.json -PoDirectory ./po

# Apply: every language catalogue present under -PoDirectory back onto a package as
# translations[] (fuzzy and empty entries skipped), emitting the importable JSON. Which
# languages exist is Weblate's decision, so they are discovered rather than listed; pass
# -Locale to narrow to a subset.
Import-NeoIPCMetadataTranslation -Path ./metadata.json -PoDirectory ./po -OutputPath ./metadata.translated.json
```

PO emit, parse and inject are pure PowerShell (Pester-tested), mirroring how
the reports' glossary PO is managed in `scripts/update-glossary-po.py`. `-Validate`
runs `msgfmt -c` (via WSL on Windows) when gettext is available.

## Exported Functions

| Category | Functions |
|----------|-----------|
| Auth | `Resolve-NeoIPCToken`, `Resolve-NeoIPCAuth`, `Get-NeoIPCAuthPassword`, `Test-DHIS2PersonalAccessToken` |
| OrgUnits | `Get-NeoIPCDepartments`, `Get-NeoIPCServerKey`, `Read-OrgUnitInfo` |
| Tracker | `Read-PatientInfo`, `Read-EnrolmentInfo`, `Read-EventInfo`, `Remove-NeoIPCPatient` |
| DataElements | `Get-NeoIPCDataElementCodes` |
| PAT | `Read-DHIS2PersonalAccessToken`, `Remove-DHIS2PersonalAccessToken`, `Clear-DHIS2PersonalAccessTokens` |
| User | `Read-UserInfo` |
| Quarto | `Invoke-WithNeoIPCAuth`, `Invoke-QuartoRender`, `Invoke-Rscript`, `Build-QmdParamPairs`, `Write-NeoIPCBuildReport`, `New-NeoIPCBuildStep`, `Complete-NeoIPCBuildStep`, `Get-NeoIPCParameterSnapshot`, `Get-NeoIPCRenderLogLevel`, `Test-NeoIPCRenderWarningHead`, `Test-QuartoInstallation`, `Split-NeoIPCLocale`, `Resolve-NeoIPCLocaleQmd` |
| InfectiousAgents | `Find-NextFreeInfectiousAgentId` |
| Metadata pipeline | `ConvertFrom-NeoIPCMetadataJson`, `ConvertTo-NeoIPCMetadataJson`, `Compare-NeoIPCMetadata`, `Test-NeoIPCMetadataRoundTrip`, `Merge-NeoIPCMetadataJson`, `Select-NeoIPCMetadataClosure`, `Test-NeoIPCMetadataExpression`, `Update-NeoIPCMetadata`, `New-NeoIPCMetadataPackage`, `Export-NeoIPCMetadataTranslation`, `Import-NeoIPCMetadataTranslation`, `Update-NeoIPCMetadataDirectory` |
| Metadata deployment | `Deploy-NeoIPCMetadata`, `Import-NeoIPCMetadata`, `Test-NeoIPCMetadataImport`, `Test-NeoIPCProgramRuleActionServed` |
| Play data | `New-NeoIPCPlayDataPackage`, `Import-NeoIPCPlayData`, `Export-NeoIPCPlayDataCsv` |
| Metadata generation | `New-NeoIPCPathogenOptionSet`, `New-NeoIPCPathogenDataElement`, `New-NeoIPCPathogenVariable`, `New-NeoIPCPathogenRule`, `New-NeoIPCPathogenFieldGatingVariable`, `New-NeoIPCPathogenFieldGatingRule`, `New-NeoIPCPathogenVirusVariable`, `New-NeoIPCPathogenVirusRule`, `New-NeoIPCSubstanceDataElement`, `New-NeoIPCSubstanceVariable`, `New-NeoIPCSubstanceRule`, `New-NeoIPCAntimicrobialOptionSet`, `New-NeoIPCAntibioticOptionGroup`, `New-NeoIPCAntibioticOptionGroupSet`, `Export-NeoIPCAntibioticTranslation`, `Compare-NeoIPCGeneratedMetadata`, `Update-NeoIPCGeneratedMetadataDirectory` |
| Data dictionary | `Export-NeoIPCDataDictionary` |
