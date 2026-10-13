#Requires -Version 7.6
# The org units in the caller's hierarchy, and org units looked up by code or UID within it.

function Get-NeoIPCCaptureRoot {
    # The UIDs of the caller's data-capture org units (/api/me organisationUnits), less those that lie below another one,
    # whose units the other one's read already covers. Warns when the account has none.
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][hashtable]$Endpoint)
    $ordinal = [System.StringComparer]::Ordinal
    $me = Invoke-NeoIPCDhis2Get @Endpoint -Path 'api/me' -Fields 'organisationUnits[id,path]' -AsHashtable -Confirm:$false -WhatIf:$false
    $capture = @(@($me['organisationUnits']) | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['id'] })
    if ($capture.Count -eq 0) {
        Write-Warning 'Your account has no data-capture org units, so no org unit lies in its hierarchy.'
        return , [string[]]@()
    }
    $captureIds = [System.Collections.Generic.HashSet[string]]::new([string[]]@($capture | ForEach-Object { [string]$_['id'] }), $ordinal)
    $roots = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new($ordinal)
    foreach ($unit in $capture) {
        $own = [string]$unit['id']
        if (-not (Test-NeoIPCMetadataUid -Id $own)) { throw "DHIS2 named '$own' as a capture unit of your account, which is no UID." }
        $below = @(([string]$unit['path']).Split('/') | Where-Object { $_ -cne $own -and $captureIds.Contains($_) }).Count -gt 0
        if (-not $below -and $seen.Add($own)) { $roots.Add($own) }
    }
    , $roots.ToArray()
}

function Get-NeoIPCHierarchyOrgUnit {
    # The org units in the caller's data-capture hierarchy, as ordered dictionaries, optionally narrowed by more metadata
    # filters: each capture unit of the caller and its descendants, read with one `path:like:<UID>` filter per capture unit
    # (Get-NeoIPCCaptureRoot, or -Root when the caller has read them) and joined by UID. It takes the place of
    # withinUserHierarchy=true, which DHIS2 2.42 and later apply as one condition per capture unit joined with AND, so that
    # an account with several capture units matches nothing (2.43.2 special-cases a single one). A path lists the UIDs of
    # a unit and its ancestors, each eleven characters between slashes, and `like` compares case-sensitively, so the filter
    # matches the capture unit and its descendants and nothing else; each returned unit's path is checked for it all the
    # same. Which org units take part in NeoIPC is not every account's business, and org-unit metadata is readable well
    # beyond the hierarchy, so an org-unit lookup goes through here rather than reading the instance's org units.
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][hashtable]$Endpoint,
        [AllowEmptyCollection()][string[]]$Filter = @(),
        [Parameter(Mandatory)][string[]]$Fields,
        [AllowEmptyCollection()][string[]]$Root
    )
    $ordinal = [System.StringComparer]::Ordinal
    if (-not $PSBoundParameters.ContainsKey('Root')) { $Root = Get-NeoIPCCaptureRoot -Endpoint $Endpoint }
    $readFields = @($Fields) + @('id', 'path' | Where-Object { $Fields -cnotcontains $_ })
    $units = [System.Collections.Generic.Dictionary[string, object]]::new($ordinal)
    foreach ($r in $Root) {
        $response = Invoke-NeoIPCDhis2Get @Endpoint -Path 'api/organisationUnits' -Filter (@("path:like:$r") + @($Filter)) -Fields $readFields -AsHashtable -Confirm:$false -WhatIf:$false
        if ($response -isnot [System.Collections.IDictionary] -or -not $response.Contains('organisationUnits')) {
            throw 'The org-unit read did not return an organisationUnits list.'
        }
        foreach ($unit in @($response['organisationUnits'])) {
            if ($unit -isnot [System.Collections.IDictionary]) { continue }
            if (([string]$unit['path']).Split('/') -cnotcontains $r) {
                throw "The org-unit read returned '$($unit['id'])', which lies outside the capture unit it asked for."
            }
            $id = [string]$unit['id']
            if (-not $units.ContainsKey($id)) { $units[$id] = $unit }
        }
    }
    , @($units.Values)
}

function Resolve-NeoIPCOrgUnit {
    # Org units of the caller's hierarchy by code and by UID (Get-NeoIPCHierarchyOrgUnit), and the codes and UIDs that no
    # unit there has. Codes and UIDs compare exactly, and a missing one is reported as missing from the hierarchy, never as
    # existing elsewhere. A code holding a ',' cannot stand in DHIS2's `in` list, which splits on it, so it is looked up by
    # itself.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][hashtable]$Endpoint,
        [AllowEmptyCollection()][string[]]$Code = @(),
        [AllowEmptyCollection()][string[]]$Id = @(),
        [Parameter(Mandatory)][string[]]$Fields
    )
    $ordinal = [System.StringComparer]::Ordinal
    $codes = [System.Collections.Generic.List[string]]::new()
    $wantedCodes = [System.Collections.Generic.HashSet[string]]::new($ordinal)
    foreach ($c in $Code) { if (-not [string]::IsNullOrEmpty($c) -and $wantedCodes.Add($c)) { $codes.Add($c) } }
    $ids = [System.Collections.Generic.List[string]]::new()
    $wantedIds = [System.Collections.Generic.HashSet[string]]::new($ordinal)
    foreach ($i in $Id) { if (-not [string]::IsNullOrEmpty($i) -and $wantedIds.Add($i)) { $ids.Add($i) } }
    $readFields = @($Fields) + @('id', 'code' | Where-Object { $Fields -cnotcontains $_ })

    $filters = [System.Collections.Generic.List[string]]::new()
    foreach ($chunk in (Split-NeoIPCList -Value @($codes | Where-Object { -not $_.Contains(',') }) -Separator ',')) { $filters.Add("code:in:[$($chunk -join ',')]") }
    foreach ($c in @($codes | Where-Object { $_.Contains(',') })) { $filters.Add("code:eq:$c") }
    foreach ($chunk in (Split-NeoIPCList -Value @($ids | Where-Object { Test-NeoIPCMetadataUid -Id $_ }) -Separator ',')) { $filters.Add("id:in:[$($chunk -join ',')]") }

    $byCode = [System.Collections.Generic.Dictionary[string, object]]::new($ordinal)
    $byId = [System.Collections.Generic.Dictionary[string, object]]::new($ordinal)
    if ($filters.Count -gt 0) {
        $roots = Get-NeoIPCCaptureRoot -Endpoint $Endpoint
        foreach ($filter in $filters) {
            foreach ($unit in (Get-NeoIPCHierarchyOrgUnit -Endpoint $Endpoint -Filter $filter -Fields $readFields -Root $roots)) {
                $unitCode = [string]$unit['code']
                $unitId = [string]$unit['id']
                if ($wantedCodes.Contains($unitCode)) { $byCode[$unitCode] = $unit }
                if ($wantedIds.Contains($unitId)) { $byId[$unitId] = $unit }
            }
        }
    }
    $found = [System.Collections.Generic.Dictionary[string, object]]::new($ordinal)
    foreach ($unit in @(@($byCode.Values) + @($byId.Values))) { $found[[string]$unit['id']] = $unit }
    [pscustomobject]@{
        Units       = @($found.Values)
        ByCode      = $byCode
        ById        = $byId
        MissingCode = [string[]]@($codes | Where-Object { -not $byCode.ContainsKey($_) })
        MissingId   = [string[]]@($ids | Where-Object { -not $byId.ContainsKey($_) })
    }
}
