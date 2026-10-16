#Requires -Version 7.6
# The memberships and roles of an org unit read as an ordered dictionary (Get-NeoIPCHierarchyOrgUnit,
# Resolve-NeoIPCOrgUnit), told by org-unit group code: NeoIPC names a country, a hospital, a department, and a test unit
# by its group (COUNTRY, HOSPITAL, NEO_DEPARTMENT, TEST_UNITS), never by its level or its position in the hierarchy.
# Also the dates such a read keeps as text, which Read-OrgUnitInfo and Read-UserInfo return as [datetime].

function Get-NeoIPCOrgUnitGroupCode {
    # The codes of the org-unit groups of a unit read with organisationUnitGroups[code], de-duplicated and in ordinal
    # order. With -GroupSetCode, only the groups that belong to that group set, which needs the unit read with
    # organisationUnitGroups[code,groupSets[code]].
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Unit,
        [string]$GroupSetCode
    )
    $codes = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($group in @($Unit['organisationUnitGroups'])) {
        if ($group -isnot [System.Collections.IDictionary] -or [string]::IsNullOrEmpty([string]$group['code'])) { continue }
        if ($GroupSetCode) {
            $sets = @(@($group['groupSets']) | Where-Object { $_ -is [System.Collections.IDictionary] } | ForEach-Object { [string]$_['code'] })
            if ($sets -cnotcontains $GroupSetCode) { continue }
        }
        [void]$codes.Add([string]$group['code'])
    }
    $codes
}

function Find-NeoIPCOrgUnitAncestor {
    # The nearest ancestor of a unit read with ancestors[id,code,organisationUnitGroups[code]] that is a member of the
    # org-unit group -GroupCode, or nothing. DHIS2 lists a unit's ancestors root first (OrganisationUnit.getAncestors), so
    # the nearest is the last; a hierarchy with an extra level between a department and its hospital, or between a
    # hospital and its country, changes nothing.
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Unit,
        [Parameter(Mandatory)][string]$GroupCode
    )
    $ancestors = @(@($Unit['ancestors']) | Where-Object { $_ -is [System.Collections.IDictionary] })
    for ($i = $ancestors.Count - 1; $i -ge 0; $i--) {
        if (@(Get-NeoIPCOrgUnitGroupCode -Unit $ancestors[$i]) -ccontains $GroupCode) { return $ancestors[$i] }
    }
}

function ConvertFrom-NeoIPCDhis2DateText {
    # A date DHIS2 sent as text, as a reader with -AsHashtable keeps it, turned into the [datetime] ConvertFrom-Json
    # makes of it by default: a text without an offset stays unspecified, one in UTC stays UTC, and one with an offset
    # becomes local time.
    [CmdletBinding()]
    [OutputType([datetime])]
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    [datetime]::Parse($Text, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
}
