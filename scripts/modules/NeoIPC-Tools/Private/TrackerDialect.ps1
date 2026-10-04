#Requires -Version 7.6
# The tracker API's request dialect per DHIS2 version, and one unpaged list read in it.

function Get-NeoIPCTrackerDialect {
    # The parameters a tracker list read takes on a DHIS2 version, and the key its response lists the items under.
    # 2.41 renamed the org-unit mode and paging parameters and the list key; 2.40 answers the new names with a
    # silently widened or paged read.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][version]$Version)
    if ($Version -lt [version]'2.41') {
        # NEOIPC-COMPAT(dhis2-2.40-tracker-dialect): remove once no supported instance runs 2.40 (/api/system/info
        # version 2.41 or later everywhere).
        return [pscustomobject]@{
            OrgUnitMode = 'ouMode'
            Paging      = @{ skipPaging = 'true' }
            ListKey     = @{ events = 'instances'; enrollments = 'instances'; trackedEntities = 'instances' }
        }
    }
    [pscustomobject]@{
        OrgUnitMode = 'orgUnitMode'
        # paging=false, which Invoke-NeoIPCDhis2Get sends on every read without -PageSize.
        Paging      = @{}
        ListKey     = @{ events = 'events'; enrollments = 'enrollments'; trackedEntities = 'trackedEntities' }
    }
}

function Get-NeoIPCTrackerList {
    # One unpaged read of a tracker list in the version's dialect, as ordered dictionaries. Throws when the response
    # lacks the list's key, so a renamed envelope can never read as an empty list.
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][hashtable]$Endpoint,
        [Parameter(Mandatory)]$Dialect,
        [Parameter(Mandatory)][ValidateSet('events', 'enrollments', 'trackedEntities')][string]$Resource,
        [hashtable]$Query = @{},
        [string[]]$Fields
    )
    $q = @{}
    foreach ($k in $Query.Keys) { $q[$k] = $Query[$k] }
    foreach ($k in $Dialect.Paging.Keys) { $q[$k] = $Dialect.Paging[$k] }
    $getArgs = @{ Path = "api/tracker/$Resource"; QueryParameters = $q; AsHashtable = $true; Confirm = $false; WhatIf = $false }
    if ($Fields) { $getArgs['Fields'] = $Fields }
    $resp = Invoke-NeoIPCDhis2Get @Endpoint @getArgs
    $key = $Dialect.ListKey[$Resource]
    if ($resp -isnot [System.Collections.IDictionary] -or -not $resp.Contains($key)) { throw "The tracker $Resource read did not return a '$key' list." }
    , @($resp[$key] | Where-Object { $_ -is [System.Collections.IDictionary] })
}
