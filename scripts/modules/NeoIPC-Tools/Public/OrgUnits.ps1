#Requires -Version 7.6

<#
.SYNOPSIS
Build a filesystem-safe key from DHIS2 connection parameters.

.DESCRIPTION
Returns a string like "https_dhis2.example.org_api" derived from scheme,
hostname, port, and path. Used to partition per-server cache files.
A null scheme or path falls back to neoipcr's default (https, /api); a null
hostname to the NEOIPC_DHIS2_HOST environment variable, and with neither
the call stops, since the module has no built-in host.
#>
function Get-NeoIPCServerKey {
    [CmdletBinding()]
    param(
        [Parameter()] [string]$Scheme = $null,
        [Parameter()] [string]$Hostname = $null,
        [Parameter()] [Nullable[int]]$Port = $null,
        [Parameter()] [string]$Path = $null
    )

    $s = if ($Scheme) { $Scheme } else { 'https' }
    $h = Resolve-NeoIPCDhis2Hostname -Hostname $Hostname
    $p = if ($Path) { $Path } else { '/api' }
    $key = "${s}_${h}"
    if ($Port) { $key += "_${Port}" }
    $key += "_$($p.TrimStart('/').Replace('/', '_'))"
    $key
}

<#
.SYNOPSIS
List the codes of the NeoIPC departments in your hierarchy.

.DESCRIPTION
Reads the org units of the org-unit group NEO_DEPARTMENT that lie in your hierarchy: your account's
data-capture org units (api/me) and the org units below them, however many data-capture org units the
account has.

Returns the codes de-duplicated and in ordinal order: codes that differ only in case are different codes.
A department without a code cannot be listed, and a warning names its UID. A failed read ends the call with
an error that begins "Failed to fetch department list from DHIS2:".

.PARAMETER Auth
Auth hashtable from Resolve-NeoIPCAuth (Token or Basic).

.PARAMETER SiteCodeFilter
A regular expression a department code must match, compared ignoring case as -match does. Default '.+'
(every department).

.PARAMETER ExcludeTestUnits
Leave out a department that is itself a member of the org-unit group TEST_UNITS.

.PARAMETER Scheme
http or https. Default https.

.PARAMETER Hostname
The DHIS2 host. Without it, the NEOIPC_DHIS2_HOST environment variable; with neither, the call stops.

.PARAMETER Port
The DHIS2 port. Default: the scheme's.

.OUTPUTS
System.String. One department code each, in ordinal order.

.EXAMPLE
Get-NeoIPCDepartments -Auth $auth -SiteCodeFilter '^NEO_AT_' -ExcludeTestUnits

The codes of the Austrian departments in your hierarchy that are no test units.
#>
function Get-NeoIPCDepartments {
    [CmdletBinding()]
    [OutputType([string])]
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

    $endpoint = @{ Auth = $Auth }
    if ($Scheme) { $endpoint.Scheme = $Scheme }
    if ($Hostname) { $endpoint.Hostname = $Hostname }
    if ($null -ne $Port) { $endpoint.Port = $Port }

    $fields = @('code')
    if ($ExcludeTestUnits) { $fields += 'organisationUnitGroups[code]' }
    try {
        $units = Get-NeoIPCHierarchyOrgUnit -Endpoint $endpoint -Filter 'organisationUnitGroups.code:eq:NEO_DEPARTMENT' -Fields $fields
    }
    catch {
        throw [System.InvalidOperationException]::new("Failed to fetch department list from DHIS2: $($_.Exception.Message)", $_.Exception)
    }

    $ordinal = [System.StringComparer]::Ordinal
    $codes = [System.Collections.Generic.HashSet[string]]::new($ordinal)
    $withoutCode = [System.Collections.Generic.List[string]]::new()
    foreach ($unit in $units) {
        $code = [string]$unit['code']
        if ([string]::IsNullOrEmpty($code)) {
            $withoutCode.Add([string]$unit['id'])
            continue
        }
        if ($ExcludeTestUnits -and @(Get-NeoIPCOrgUnitGroupCode -Unit $unit) -ccontains 'TEST_UNITS') { continue }
        if ($code -match $SiteCodeFilter) { [void]$codes.Add($code) }
    }
    if ($withoutCode.Count -gt 0) {
        Write-Warning "Left out $($withoutCode.Count) department(s) without a code, which a department list cannot name: $($withoutCode -join ', ')."
    }

    $sorted = [string[]]@($codes)
    [Array]::Sort($sorted, $ordinal)
    $sorted
}

<#
.SYNOPSIS
Read the NeoIPC departments in your hierarchy, with their hospital, country, memberships, and dates.

.DESCRIPTION
Returns one record per department: an org unit of the org-unit group NEO_DEPARTMENT that lies in your
hierarchy, which is your account's data-capture org units (api/me) and the org units below them, however
many data-capture org units the account has.

Without -OrgUnitCode and -OrgUnitId, the cmdlet returns every department in your hierarchy. With them, it
returns the departments they name, and writes an error naming each code or UID that names no org unit in
your hierarchy, and each that names an org unit that is no department; when none remains, it returns
nothing. Codes and UIDs compare exactly, case included, and an empty one names nothing. When the cmdlet
expects pipeline input and receives none, it returns nothing and reads nothing.

Roles are told by org-unit group code, never by level or position. HospitalCode is the code of the
department's nearest ancestor in the group HOSPITAL, CountryCode that of its nearest ancestor in the group
COUNTRY, and WorldBankClass the code of the country's group in the group set WORLD_BANK_CLASSES; a country
in several such groups gets the first code in ordinal order, and a warning. A test unit whose hierarchy is
flattened has no such ancestors, and these codes stay empty. IsTestUnit says whether the department itself
is a member of the group TEST_UNITS, and TrialCodes lists its groups in the group set NEOIPC_TRIALS.

.PARAMETER Auth
Auth hashtable from Resolve-NeoIPCAuth (Token or Basic). Given, -Token is not used.

.PARAMETER Token
A DHIS2 personal access token, or the path of a file that holds one, for Resolve-NeoIPCAuth when -Auth is
not given. Without either, Resolve-NeoIPCAuth decides where the credentials come from.

.PARAMETER OrgUnitCode
Codes of the departments to read. Pipeline-bound by property name, so the output of a cmdlet that emits
OrgUnitCode (such as Read-OrgUnitInfo itself) selects its departments.

.PARAMETER OrgUnitId
UIDs of the departments to read. Pipeline-bound by property name, so the output of a cmdlet that emits
OrgUnitId (such as Read-EventInfo or Read-EnrolmentInfo) selects its departments.

.PARAMETER CountryCode
Keep only the departments whose CountryCode is this code, compared exactly. A warning says when none is
left.

.PARAMETER Scheme
http or https. Default https.

.PARAMETER Hostname
The DHIS2 host. Without it, the NEOIPC_DHIS2_HOST environment variable; with neither, the call stops.

.PARAMETER Port
The DHIS2 port. Default: the scheme's.

.OUTPUTS
System.Management.Automation.PSCustomObject. One per department, in ordinal order of OrgUnitCode: OrgUnitId,
OrgUnitCode, OrgUnitName, Level, HospitalCode, CountryCode, OpeningDate and ClosedDate (DateTime),
IsTestUnit, TrialCodes (String[]), and WorldBankClass.

.EXAMPLE
Read-OrgUnitInfo -Auth $auth -CountryCode AT

The Austrian departments in your hierarchy.

.EXAMPLE
Read-OrgUnitInfo -Auth $auth -OrgUnitCode NEO_DE_01, NEO_DE_02 | Read-UserInfo -Auth $auth

The users whose data-capture org units include either department.
#>
function Read-OrgUnitInfo {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [hashtable]$Auth,

        [Parameter()]
        [string]$Token,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
            $serverKey = Get-NeoIPCServerKey -Scheme $fakeBoundParameters['Scheme'] -Hostname $fakeBoundParameters['Hostname'] -Port $fakeBoundParameters['Port']
            $cacheDir = Join-Path $script:NeoIPCRepoRoot 'data' $serverKey
            $cacheFile = Join-Path $cacheDir 'site-codes.txt'
            if (Test-Path $cacheFile) {
                Get-Content $cacheFile | Where-Object { $_ -like "$wordToComplete*" }
            }
        })]
        [string[]]$OrgUnitCode,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string[]]$OrgUnitId,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$CountryCode,

        [Parameter()] [string]$Scheme = $null,
        [Parameter()] [string]$Hostname = $null,
        [Parameter()] [Nullable[int]]$Port = $null
    )

    begin {
        $codes = [System.Collections.Generic.List[string]]::new()
        $ids = [System.Collections.Generic.List[string]]::new()
        $selectorGiven = $false
    }

    process {
        if ($PSBoundParameters.ContainsKey('OrgUnitCode')) {
            $selectorGiven = $true
            foreach ($c in $OrgUnitCode) { if (-not [string]::IsNullOrEmpty($c)) { $codes.Add($c) } }
        }
        if ($PSBoundParameters.ContainsKey('OrgUnitId')) {
            $selectorGiven = $true
            foreach ($i in $OrgUnitId) { if (-not [string]::IsNullOrEmpty($i)) { $ids.Add($i) } }
        }
    }

    end {
        if (($MyInvocation.ExpectingInput -or $selectorGiven) -and $codes.Count -eq 0 -and $ids.Count -eq 0) { return }
        if (-not $Auth) { $Auth = Resolve-NeoIPCAuth -Token $Token }
        $endpoint = @{ Auth = $Auth }
        if ($Scheme) { $endpoint.Scheme = $Scheme }
        if ($Hostname) { $endpoint.Hostname = $Hostname }
        if ($null -ne $Port) { $endpoint.Port = $Port }

        $fields = @(
            'id', 'code', 'name', 'level', 'openingDate', 'closedDate',
            'organisationUnitGroups[code,groupSets[code]]',
            'ancestors[id,code,organisationUnitGroups[code,groupSets[code]]]'
        )
        $ordinal = [System.StringComparer]::Ordinal
        $departments = [System.Collections.Generic.List[object]]::new()
        if ($codes.Count -gt 0 -or $ids.Count -gt 0) {
            $found = Resolve-NeoIPCOrgUnit -Endpoint $endpoint -Code $codes.ToArray() -Id $ids.ToArray() -Fields $fields
            foreach ($missing in $found.MissingCode) {
                Write-Error -Message "No org unit with the code '$missing' lies in your hierarchy." -Category ObjectNotFound -ErrorId 'NeoIPCOrgUnitCodeNotFound' -TargetObject $missing
            }
            foreach ($missing in $found.MissingId) {
                Write-Error -Message "No org unit with the UID '$missing' lies in your hierarchy." -Category ObjectNotFound -ErrorId 'NeoIPCOrgUnitIdNotFound' -TargetObject $missing
            }
            foreach ($lookup in @(@{ Values = $codes; Found = $found.ByCode }, @{ Values = $ids; Found = $found.ById })) {
                $reported = [System.Collections.Generic.HashSet[string]]::new($ordinal)
                foreach ($value in $lookup.Values) {
                    if (-not $lookup.Found.ContainsKey($value) -or -not $reported.Add($value)) { continue }
                    if (@(Get-NeoIPCOrgUnitGroupCode -Unit $lookup.Found[$value]) -cnotcontains 'NEO_DEPARTMENT') {
                        Write-Error -Message "The org unit '$value' is not a department: it is not a member of the org-unit group NEO_DEPARTMENT." -Category InvalidArgument -ErrorId 'NeoIPCOrgUnitNotDepartment' -TargetObject $value
                    }
                }
            }
            foreach ($unit in $found.Units) {
                if (@(Get-NeoIPCOrgUnitGroupCode -Unit $unit) -ccontains 'NEO_DEPARTMENT') { $departments.Add($unit) }
            }
            if ($departments.Count -eq 0) { return }
        }
        else {
            foreach ($unit in (Get-NeoIPCHierarchyOrgUnit -Endpoint $endpoint -Filter 'organisationUnitGroups.code:eq:NEO_DEPARTMENT' -Fields $fields)) {
                $departments.Add($unit)
            }
        }

        $records = [System.Collections.Generic.List[object]]::new()
        $ambiguousCountries = [System.Collections.Generic.HashSet[string]]::new($ordinal)
        foreach ($unit in $departments) {
            $hospital = Find-NeoIPCOrgUnitAncestor -Unit $unit -GroupCode 'HOSPITAL'
            $country = Find-NeoIPCOrgUnitAncestor -Unit $unit -GroupCode 'COUNTRY'
            $unitCountryCode = if ($country) { $country['code'] } else { $null }
            if ($PSBoundParameters.ContainsKey('CountryCode') -and [string]$unitCountryCode -cne $CountryCode) { continue }
            $worldBankClass = $null
            if ($country) {
                $classes = [string[]]@(Get-NeoIPCOrgUnitGroupCode -Unit $country -GroupSetCode 'WORLD_BANK_CLASSES')
                if ($classes.Count -gt 0) { $worldBankClass = $classes[0] }
                if ($classes.Count -gt 1 -and $ambiguousCountries.Add([string]$country['id'])) {
                    Write-Warning "The country '$unitCountryCode' is a member of $($classes.Count) groups of the group set WORLD_BANK_CLASSES ($($classes -join ', ')); WorldBankClass is '$worldBankClass'."
                }
            }
            $records.Add([pscustomobject]@{
                    OrgUnitId      = $unit['id']
                    OrgUnitCode    = $unit['code']
                    OrgUnitName    = $unit['name']
                    Level          = $unit['level']
                    HospitalCode   = if ($hospital) { $hospital['code'] } else { $null }
                    CountryCode    = $unitCountryCode
                    OpeningDate    = ConvertFrom-NeoIPCDhis2DateText -Text $unit['openingDate']
                    ClosedDate     = ConvertFrom-NeoIPCDhis2DateText -Text $unit['closedDate']
                    IsTestUnit     = @(Get-NeoIPCOrgUnitGroupCode -Unit $unit) -ccontains 'TEST_UNITS'
                    TrialCodes     = [string[]]@(Get-NeoIPCOrgUnitGroupCode -Unit $unit -GroupSetCode 'NEOIPC_TRIALS')
                    WorldBankClass = $worldBankClass
                })
        }
        if ($PSBoundParameters.ContainsKey('CountryCode') -and $records.Count -eq 0) {
            Write-Warning "No department in your hierarchy has a country with the code '$CountryCode'."
        }

        $records.Sort([System.Comparison[object]] {
                param($x, $y)
                $byCode = [string]::CompareOrdinal([string]$x.OrgUnitCode, [string]$y.OrgUnitCode)
                if ($byCode -ne 0) { $byCode } else { [string]::CompareOrdinal([string]$x.OrgUnitId, [string]$y.OrgUnitId) }
            })
        $records
    }
}
