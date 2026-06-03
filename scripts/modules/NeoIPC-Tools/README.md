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

Report-generation scripts (`New-PartnerReports.ps1`, etc.) import the module
automatically.

## Authentication

All functions that call the DHIS2 API accept a `-Token` parameter (or read
`$env:NEOIPC_DHIS2_TOKEN`). If no token is available, you are prompted for
username/password.

```powershell
# Token from environment variable (set once, used by all commands)
$env:NEOIPC_DHIS2_TOKEN = 'd2pat_...'

# Token from a file
$auth = Resolve-NeoipcAuth -Token ./secrets/my-token.txt

# Interactive username/password prompt
$auth = Resolve-NeoipcAuth
```

Tokens are validated against the DHIS2 v1 PAT format (`d2pat_` + 32 alphanum
\+ 10-digit CRC32). Invalid tokens are rejected immediately.

## OrgUnit inspection

```powershell
# List all departments the current user can see
Get-NeoipcDepartments -Auth $auth

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

These functions are used by the report scripts (`New-PartnerReports.ps1`,
`New-ReferenceReport.ps1`, etc.) but can also be called directly.

### Scoped auth environment variables

```powershell
# Run a script block with DHIS2 auth env vars set (and securely cleared after)
$auth = Resolve-NeoipcAuth -Token $Token
Invoke-WithNeoipcAuth -Auth $auth -ScriptBlock {
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
Split-NeoipcLocale -Locale 'de_AT'
# @{ Language = 'de'; Territory = 'AT'; Code = 'de_AT' }

# Resolve localized QMD file (with fallback)
Resolve-NeoipcLocaleQmd -ReportDir ./reports/Partner-Report -BaseName 'Partner-Report' -Locale 'de'
# Returns Partner-Report.de.qmd if it exists, otherwise Partner-Report.qmd
```

### Build reports

```powershell
# Write a build summary to console and optionally to JSON
$status = Write-NeoipcBuildReport -Name 'Partner Report Build' `
    -Errors $errors -OutputFiles $outputFiles -BuildCompleted $true `
    -StartedAt $startedAt -BuildReportPath './build-report.json'
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
./scripts/Update-NeoipcCache.ps1                # refresh everything
./scripts/Update-NeoipcCache.ps1 -Sites         # only site-codes cache
./scripts/Update-NeoipcCache.ps1 -DataElements  # only DE-codes cache
```

After that, `-OrgUnitCode NEO_<Tab>` and `-DataElementCode NEOIPC_<Tab>`
complete from the cached lists.

## Exported functions

| Category | Functions |
|----------|-----------|
| Auth | `Resolve-NeoipcToken`, `Resolve-NeoipcAuth`, `Get-NeoipcAuthPassword`, `Test-DHIS2PersonalAccessToken` |
| OrgUnits | `Get-NeoipcDepartments`, `Get-NeoipcServerKey`, `Read-OrgUnitInfo` |
| Tracker | `Read-PatientInfo`, `Read-EnrolmentInfo`, `Read-EventInfo` |
| DataElements | `Get-NeoipcDataElementCodes` |
| PAT | `Read-DHIS2PersonalAccessToken`, `Remove-DHIS2PersonalAccessToken`, `Clear-DHIS2PersonalAccessTokens` |
| User | `Read-UserInfo` |
| Quarto | `Invoke-WithNeoipcAuth`, `Invoke-QuartoRender`, `Invoke-Rscript`, `Build-QmdParamPairs`, `Write-NeoipcBuildReport`, `Test-QuartoInstallation`, `Split-NeoipcLocale`, `Resolve-NeoipcLocaleQmd` |
| InfectiousAgents | `Find-NextFreeInfectiousAgentId` |
