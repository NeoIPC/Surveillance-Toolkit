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

# Filter by partner codes
Read-OrgUnitInfo -PartnerCodes NEO_DE_01, NEO_DE_02
```

## User inspection

```powershell
# All users
Read-UserInfo

# Users assigned to specific sites
Read-UserInfo -PartnerCodes NEO_AT_01
```

## Enrollment & event inspection (pipeline-composable)

```powershell
# All enrollments at Austrian sites
Read-EnrolmentInfo -PartnerCodes NEO_AT_01, NEO_AT_02

# Pipe from org units
Read-OrgUnitInfo -CountryCode AT | Read-EnrolmentInfo

# Filter by date range
Read-EnrolmentInfo -AdmissionDateFrom 2025-01-01 -AdmissionDateTo 2025-06-30

# Search by patient ID
Read-EnrolmentInfo -NeoIpcId 'NEO_AT_01-0042'

# Events from enrollments (no extra API call)
Read-EnrolmentInfo -PartnerCodes NEO_DE_01 | Read-EventSummary

# Filter to specific event type
Read-EnrolmentInfo -PartnerCodes NEO_DE_01 | Read-EventSummary -EventType 'Primary Sepsis/BSI'

# Patient demographics
Read-OrgUnitInfo -PartnerCodes NEO_DE_01 | Read-PatientInfo
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

Functions that accept `-PartnerCodes` support tab completion from the local
site-codes cache. Run `Update-NeoipcSiteCache.ps1` once to populate the cache:

```powershell
./scripts/Update-NeoipcSiteCache.ps1 -Token $env:NEOIPC_DHIS2_TOKEN
```

After that, `-PartnerCodes NEO_<Tab>` completes from cached site codes.

## Exported functions

| Category | Functions |
|----------|-----------|
| Auth | `Resolve-NeoipcToken`, `Resolve-NeoipcAuth`, `Get-NeoipcAuthPassword`, `Test-DHIS2PersonalAccessToken` |
| OrgUnits | `Get-NeoipcDepartments`, `Get-NeoipcServerKey`, `Read-OrgUnitInfo` |
| Tracker | `Read-PatientInfo`, `Read-EnrolmentInfo`, `Read-EventSummary` |
| PAT | `Read-DHIS2PersonalAccessToken`, `Remove-DHIS2PersonalAccessToken`, `Clear-DHIS2PersonalAccessTokens` |
| User | `Read-UserInfo` |
| Quarto | `Invoke-WithNeoipcAuth`, `Invoke-QuartoRender`, `Invoke-Rscript`, `Build-QmdParamPairs`, `Write-NeoipcBuildReport`, `Test-QuartoInstallation`, `Split-NeoipcLocale`, `Resolve-NeoipcLocaleQmd` |
