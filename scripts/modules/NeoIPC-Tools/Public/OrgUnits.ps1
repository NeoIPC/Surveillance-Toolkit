<#
.SYNOPSIS
Build a filesystem-safe key from DHIS2 connection parameters.

.DESCRIPTION
Returns a string like "https_neoipc.charite.de_api" derived from scheme,
hostname, port, and path. Used to partition per-server cache files.
Falls back to neoipcr defaults for any null parameter.
#>
function Get-NeoipcServerKey {
    [CmdletBinding()]
    param(
        [Parameter()] [string]$Scheme = $null,
        [Parameter()] [string]$Hostname = $null,
        [Parameter()] [Nullable[int]]$Port = $null,
        [Parameter()] [string]$Path = $null
    )

    $s = if ($Scheme) { $Scheme } else { 'https' }
    $h = if ($Hostname) { $Hostname } else { 'neoipc.charite.de' }
    $p = if ($Path) { $Path } else { '/api' }
    $key = "${s}_${h}"
    if ($Port) { $key += "_${Port}" }
    $key += "_$($p.TrimStart('/').Replace('/', '_'))"
    $key
}

<#
.SYNOPSIS
Fetch and filter NeoIPC department codes from DHIS2.

.DESCRIPTION
Queries the DHIS2 /api/organisationUnits endpoint with withinUserHierarchy=true
to return only org units the authenticated user has access to, filtered to
the NEO_DEPARTMENT group. This avoids the DHIS2 metadata endpoint which
exposes all org units regardless of user assignment.

.PARAMETER Auth
Authentication hashtable from Resolve-NeoipcAuth.

.PARAMETER SiteCodeFilter
Regex pattern to filter department codes. Default: '.+' (all).

.OUTPUTS
Sorted array of department code strings.
#>
function Get-NeoipcDepartments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Auth,

        [Parameter()]
        [string]$SiteCodeFilter = '.+',

        [Parameter()]
        [switch]$ExcludeTestUnits,

        [Parameter()] [string]$Scheme = $null,
        [Parameter()] [string]$Hostname = $null,
        [Parameter()] [Nullable[int]]$Port = $null
    )

    $fields = @('code')
    if ($ExcludeTestUnits) {
        $fields += 'organisationUnitGroups[code]'
    }

    $getParams = @{
        Auth     = $Auth
        Path     = 'api/organisationUnits'
        Fields   = $fields
        Filter   = @('organisationUnitGroups.code:eq:NEO_DEPARTMENT')
        QueryParameters = @{ 'withinUserHierarchy' = 'true' }
    }
    if ($Scheme)   { $getParams.Scheme   = $Scheme }
    if ($Hostname) { $getParams.Hostname = $Hostname }
    if ($Port)     { $getParams.Port     = $Port }

    try {
        $resp = Invoke-NeoipcDhis2Get @getParams
        $units = if ($resp.organisationUnits) {
            $resp.organisationUnits
        } else { @() }

        if ($ExcludeTestUnits) {
            $units = $units | Where-Object {
                $groupCodes = @($_.organisationUnitGroups | ForEach-Object { $_.code })
                $groupCodes -notcontains 'TEST_UNITS'
            }
        }

        $sites = @($units | ForEach-Object { $_.code }) |
            Where-Object { $_ -match $SiteCodeFilter } |
            Sort-Object
    }
    catch {
        throw "Failed to fetch department list from DHIS2: $($_.Exception.Message)"
    }

    return $sites
}

<#
.SYNOPSIS
Query DHIS2 organisation units with rich detail.

.DESCRIPTION
Returns one flat PSCustomObject per org unit with OrgUnitId, OrgUnitCode,
OrgUnitName, hierarchy context (HospitalCode, CountryCode, Level), dates,
trial memberships, World Bank income class, and test-unit flag.

Uses /api/organisationUnits with withinUserHierarchy=true so results are
scoped to the authenticated user's assigned hierarchy.

.PARAMETER Auth
Authentication hashtable from Resolve-NeoipcAuth.

.PARAMETER OrgUnitCode
Filter to specific OU codes. Pipeline-bound from upstream cmdlets that emit
OrgUnitCode (e.g. Read-OrgUnitInfo itself).

.PARAMETER OrgUnitId
Filter to specific OU UIDs. Pipeline-bound from upstream cmdlets that emit
OrgUnitId (e.g. Read-EventInfo, Read-EnrolmentInfo).

.PARAMETER CountryCode
Filter to org units under a specific country code.

.OUTPUTS
Flat PSCustomObject per org unit.
#>
function Read-OrgUnitInfo {
    [CmdletBinding()]
    param(
        [Parameter()]
        [hashtable]$Auth,

        [Parameter()]
        [string]$Token = $env:NEOIPC_DHIS2_TOKEN,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
            $serverKey = Get-NeoipcServerKey -Scheme $fakeBoundParameters['Scheme'] -Hostname $fakeBoundParameters['Hostname'] -Port $fakeBoundParameters['Port']
            $cacheDir = Join-Path (Split-Path (Split-Path (Split-Path $PSScriptRoot))) 'data' $serverKey
            $cacheFile = Join-Path $cacheDir 'site-codes.txt'
            if (Test-Path $cacheFile) {
                Get-Content $cacheFile | Where-Object { $_ -like "$wordToComplete*" }
            }
        })]
        [string[]]$OrgUnitCode,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string[]]$OrgUnitId,

        [Parameter()]
        [string]$CountryCode,

        [Parameter()] [string]$Scheme = $null,
        [Parameter()] [string]$Hostname = $null,
        [Parameter()] [Nullable[int]]$Port = $null
    )

    begin {
        if (-not $Auth) {
            $Auth = Resolve-NeoipcAuth -Token $Token
        }
        $script:collectedOrgUnitCodes = [System.Collections.Generic.List[string]]::new()
        $script:collectedOrgUnitIds = [System.Collections.Generic.List[string]]::new()
    }

    process {
        if ($OrgUnitCode) { foreach ($c in $OrgUnitCode) { $script:collectedOrgUnitCodes.Add($c) } }
        if ($OrgUnitId)   { foreach ($i in $OrgUnitId)   { $script:collectedOrgUnitIds.Add($i) } }
    }

    end {
        $fields = @(
            'id', 'code', 'name', 'level', 'openingDate', 'closedDate',
            'parent[id,code,name,level,parent[id,code,name,organisationUnitGroups[code,groupSets[code]]]]',
            'organisationUnitGroups[code,groupSets[code]]'
        )

        $filters = @('organisationUnitGroups.code:eq:NEO_DEPARTMENT')
        if ($script:collectedOrgUnitCodes.Count -gt 0) {
            $codes = ($script:collectedOrgUnitCodes | Sort-Object -Unique) -join ','
            $filters += "code:in:[$codes]"
        }
        if ($script:collectedOrgUnitIds.Count -gt 0) {
            $ids = ($script:collectedOrgUnitIds | Sort-Object -Unique) -join ','
            $filters += "id:in:[$ids]"
        }

        $getParams = @{
            Auth     = $Auth
            Path     = 'api/organisationUnits'
            Fields   = $fields
            Filter   = $filters
            QueryParameters = @{ 'withinUserHierarchy' = 'true' }
        }
        if ($Scheme)   { $getParams.Scheme   = $Scheme }
        if ($Hostname) { $getParams.Hostname = $Hostname }
        if ($Port)     { $getParams.Port     = $Port }

        $resp = Invoke-NeoipcDhis2Get @getParams

        foreach ($ou in $resp.organisationUnits) {
            $groupCodes = @($ou.organisationUnitGroups | ForEach-Object { $_.code })
            $isTestUnit = $groupCodes -contains 'TEST_UNITS'

            $trialCodes = @($ou.organisationUnitGroups | Where-Object {
                $_.groupSets | Where-Object { $_.code -eq 'NEOIPC_TRIALS' }
            } | ForEach-Object { $_.code }) | Sort-Object

            # Hierarchy context: parent = hospital (level 3), grandparent = country (level 2)
            # For test units the hierarchy is flattened (root -> TEST_UNITS -> department)
            $hospitalCode = $null
            $countryCode_ = $null
            if ($ou.parent -and -not $isTestUnit) {
                $hospitalCode = $ou.parent.code
                if ($ou.parent.parent) {
                    $countryCode_ = $ou.parent.parent.code
                }
            }

            $worldBankClass = $null
            if (-not $isTestUnit -and $ou.parent -and $ou.parent.parent) {
                $wbGroup = $ou.parent.parent.organisationUnitGroups | Where-Object {
                    $_.groupSets | Where-Object { $_.code -eq 'WORLD_BANK_CLASSES' }
                } | Select-Object -First 1
                if ($wbGroup) { $worldBankClass = $wbGroup.code }
            }

            if ($CountryCode -and $countryCode_ -ne $CountryCode) { continue }

            [PSCustomObject]@{
                OrgUnitId      = $ou.id
                OrgUnitCode    = $ou.code
                OrgUnitName    = $ou.name
                Level          = $ou.level
                HospitalCode   = $hospitalCode
                CountryCode    = $countryCode_
                OpeningDate    = $ou.openingDate
                ClosedDate     = $ou.closedDate
                IsTestUnit     = $isTestUnit
                TrialCodes     = $trialCodes
                WorldBankClass = $worldBankClass
            }
        }
    }
}
