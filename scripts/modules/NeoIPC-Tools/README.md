# NeoIPC-Tools PowerShell Module

PowerShell tools for the NeoIPC Surveillance project: DHIS2 admin operations,
report-generation helpers, and pipeline-composable data inspection.

Requires **PowerShell 7.5+**.

## Installation

The module is not published to a gallery. Import it directly from the
repository:

```powershell
Import-Module ./scripts/modules/NeoIPC-Tools
```

Report-generation scripts (`Build-PartnerReport.ps1`, etc.) import the module
automatically.

## Architecture & subsystems

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

### Files at a glance

`Public/` holds the exported surface; `Private/` the implementation. Each
`.ps1` is one cohesive subsystem:

| File | Role |
|------|------|
| `Public/Auth.ps1` + `Private/DHIS2Http.ps1` | DHIS2 auth (PAT / user-password) + the REST GET/DELETE layer every live call goes through |
| `Public/OrgUnits.ps1`, `Tracker.ps1`, `UserInfo.ps1`, `DataElements.ps1`, `PAT.ps1` | Live, pipeline-composable inspection of org units, patients/enrolments/events, users, DE codes, and personal-access-token lifecycle |
| `Public/ReportHelpers.ps1` | Report-build helpers — scoped auth env vars, Quarto/Rscript invocation, locale resolution, build summaries |
| `Public/InfectiousAgents.ps1` | Infectious-agent ontology helpers (next free `Id`) |
| `Public/Metadata.ps1` | The metadata-pipeline public surface — convert, compare, round-trip, closure, lint, update, **assemble** (`New-NeoIPCMetadataPackage`), translation export/import |
| `Public/MetadataReconcile.ps1` | **Reconcile** the canonical directory against a fresh export (`Update-NeoIPCMetadataDirectory`) — classify drift, auto-write CSV-owned config + PO, report-only for authored / generated / domain |
| `Public/Generation.ps1` | The nine ontology/matrix-driven object generators (pathogen + substance + field-gating) |
| `Private/Metadata.ps1` | Pipeline **core** — JSON parse, deterministic UID mint, row↔object cell coercion, sharing-profile registry, noise-strip, canonicalize, CSV I/O, package↔directory, semantic compare |
| `Private/MetadataTypeMaps.ps1` | Per-type field classification (translatable vs technical vs nested), the normalization strip-list, and the non-closure type list — the data the core consults |
| `Private/MetadataClosure.ps1` | The dependency-closure prune from `NEOIPC_CORE` (structured + expression ref-walk) + the whole-type base⊕supplement merge |
| `Private/MetadataExpression.ps1` | Program-rule expression handling — canonicalizer, issue linter, embedded-UID scanner, UID-regeneration rewrite |
| `Private/MetadataAuthoring.ps1` | Read the UID-keyed directory's authored content — org units, users (+ role/org-unit assignments), org-unit-group + user-group memberships |
| `Private/MetadataAssembly.ps1` | Stitch closure config + authored content into the final package (`Join-NeoIPCMetadataPackage`) |
| `Private/MetadataTranslation.ps1` | The gettext-PO subsystem — translation-unit extraction, PO emit/parse/merge, inject `translations[]` |
| `Private/MetadataGeneration.ps1` | The generation **plans** — pathogen/substance/field-gating DE+PRV+rule plans, resistance + common-commensal effective-flag/code-set computation, the per-slot capability matrix |
| `Public/DataDictionary.ps1` + `Private/DataDictionary.ps1` | The **data-dictionary** generator (`Export-NeoIPCDataDictionary`) — flattens the assembled package into a technology-agnostic spreadsheet (patient attributes, per-stage data elements, the event dates, and every code list in full) as CSV + a multi-tab `.xlsx` (via `DocumentFormat.OpenXml`, provisioned under `lib/`) |

### Metadata pipeline — data flow

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
   | Export / Import-NeoIPCMetadataTranslation    <-> po/metadata.<lang>.po  |
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
export carries only anonymised instances), the ontology-generated families, and the domain YAML are
never reverse-written; an unexpected change surfaces as `Unclassified` for investigation.

## Authentication

All functions that call the DHIS2 API accept a `-Token` parameter (or read
`$env:NEOIPC_DHIS2_TOKEN`). If no token is available, you are prompted for
username/password.

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

## OrgUnit inspection

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

## User inspection

```powershell
# All users
Read-UserInfo

# Users assigned to specific sites
Read-UserInfo -OrgUnitCode NEO_AT_01
```

## Patient, enrolment, event inspection (pipeline-composable)

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

## Working with event dataValues

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

## PAT lifecycle management

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

## Report generation helpers

These functions are used by the report scripts (`Build-PartnerReport.ps1`,
`Build-ReferenceReport.ps1`, etc.) but can also be called directly.

### Scoped auth environment variables

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

### Quarto & Rscript rendering

```powershell
# Render with error/warning parsing
$result = Invoke-QuartoRender -Arguments @('render', 'Report.qmd', '--to', 'pdf')
$result.Status   # 'Success', 'Error', or 'NoData'

# Rscript with rlang error handling
$result = Invoke-Rscript -Arguments @('--vanilla', 'Generate-Data.R', '--output', 'data.json')
$result.Status   # 'Success' or 'Error'
```

### Locale handling

```powershell
# Split locale code
Split-NeoIPCLocale -Locale 'de_AT'
# @{ Language = 'de'; Territory = 'AT'; Code = 'de_AT' }

# Resolve localized QMD file (with fallback)
Resolve-NeoIPCLocaleQmd -ReportDirPath ./reports/Partner-Report -BaseName 'Partner-Report' -Locale 'de'
# Returns Partner-Report.de.qmd if it exists, otherwise Partner-Report.qmd
```

### Build reports

```powershell
# Write a build summary to console and optionally to JSON. Common fields (site codes,
# locales/formats, per-step log, parameter snapshot, ...) are first-class parameters;
# the module owns the JSON schema so every report wrapper stays consistent by construction.
$status = Write-NeoIPCBuildReport -Name 'Partner Report Build' -StartedAt $startedAt `
    -Errors $errors -OutputFilePaths $outputFiles -BuildCompleted $true `
    -BuildReportFilePath './build-report.json' `
    -SiteCodes $siteCodes -OutputLocales @('en', 'de') -OutputFormats @('pdf')

# Per-step logging: build a step, then record its outcome from an
# Invoke-Rscript / Invoke-QuartoRender result ('Success' -> success, 'Error' -> error,
# 'NoData' -> nodata).
$step = New-NeoIPCBuildStep -SiteCode 'NEO_DE_01' -OutputLocale 'de' -OutputFormat 'pdf'
$step = $step | Complete-NeoIPCBuildStep -Result $renderResult
```

### Quarto parameter pairs

```powershell
# Convert a hashtable to -P key:value pairs for quarto render
$pairs = Build-QmdParamPairs -Values @{
    unitCodes = 'NEO_DE_01'
    reportingPeriodFrom = '2025-01-01'
}
# @('-P', 'unitCodes:NEO_DE_01', '-P', 'reportingPeriodFrom:2025-01-01')
```

## Tab completion

`-OrgUnitCode` (on `Read-OrgUnitInfo`, `Read-UserInfo`, `Read-PatientInfo`,
`Read-EnrolmentInfo`, `Read-EventInfo`) and `-DataElementCode` (on
`Read-EventInfo`) support tab completion from local caches. Populate
them once with the unified cache-refresh script:

```powershell
./scripts/Update-NeoIPCCache.ps1                # refresh everything
./scripts/Update-NeoIPCCache.ps1 -Sites         # only site-codes cache
./scripts/Update-NeoIPCCache.ps1 -DataElements  # only DE-codes cache
```

After that, `-OrgUnitCode NEO_<Tab>` and `-DataElementCode NEOIPC_<Tab>`
complete from the cached lists.

## Metadata translations (gettext PO)

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
that table as needs change. The committed component lives in
`po/metadata.pot` + `po/metadata.<lang>.po`.

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
Export-NeoIPCMetadataTranslation -Package $pkg -PoDirectory ./po -Locale de -Validate   # regenerate .pot + msgmerge .po

# Quick ad-hoc extract from a raw export (NOT for the committed component — stale family names):
Export-NeoIPCMetadataTranslation -Path ./metadata.json -PoDirectory ./po -Locale de

# Apply: per-language PO back onto a package as translations[] (fuzzy and
# empty entries skipped), emitting the importable JSON.
Import-NeoIPCMetadataTranslation -Path ./metadata.json -PoDirectory ./po -OutputPath ./metadata.translated.json
```

PO emit/parse/merge are pure PowerShell (Pester-tested round-trip), mirroring how
the reports' glossary PO is managed in `scripts/update-glossary-po.py`. `-Validate`
runs `msgfmt -c` (via WSL on Windows) when gettext is available.

## Exported functions

| Category | Functions |
|----------|-----------|
| Auth | `Resolve-NeoIPCToken`, `Resolve-NeoIPCAuth`, `Get-NeoIPCAuthPassword`, `Test-DHIS2PersonalAccessToken` |
| OrgUnits | `Get-NeoIPCDepartments`, `Get-NeoIPCServerKey`, `Read-OrgUnitInfo` |
| Tracker | `Read-PatientInfo`, `Read-EnrolmentInfo`, `Read-EventInfo` |
| DataElements | `Get-NeoIPCDataElementCodes` |
| PAT | `Read-DHIS2PersonalAccessToken`, `Remove-DHIS2PersonalAccessToken`, `Clear-DHIS2PersonalAccessTokens` |
| User | `Read-UserInfo` |
| Quarto | `Invoke-WithNeoIPCAuth`, `Invoke-QuartoRender`, `Invoke-Rscript`, `Build-QmdParamPairs`, `Write-NeoIPCBuildReport`, `Test-QuartoInstallation`, `Split-NeoIPCLocale`, `Resolve-NeoIPCLocaleQmd` |
| InfectiousAgents | `Find-NextFreeInfectiousAgentId` |
| Metadata pipeline | `ConvertFrom-NeoIPCMetadataJson`, `ConvertTo-NeoIPCMetadataJson`, `Compare-NeoIPCMetadata`, `Test-NeoIPCMetadataRoundTrip`, `Merge-NeoIPCMetadataJson`, `Select-NeoIPCMetadataClosure`, `Test-NeoIPCMetadataExpression`, `Update-NeoIPCMetadata`, `New-NeoIPCMetadataPackage`, `Export-NeoIPCMetadataTranslation`, `Import-NeoIPCMetadataTranslation`, `Update-NeoIPCMetadataDirectory` |
| Metadata generation | `New-NeoIPCPathogenOptionSet`, `New-NeoIPCPathogenDataElement`, `New-NeoIPCPathogenVariable`, `New-NeoIPCPathogenRule`, `New-NeoIPCPathogenFieldGatingVariable`, `New-NeoIPCPathogenFieldGatingRule`, `New-NeoIPCSubstanceDataElement`, `New-NeoIPCSubstanceVariable`, `New-NeoIPCSubstanceRule` |
| Data dictionary | `Export-NeoIPCDataDictionary` |
