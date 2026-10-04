#Requires -Version 7.6
# Live-state reads shared by the round-trip verifier (Test-NeoIPCMetadataImport) and the deployment
# (Deploy-NeoIPCMetadata): package objects read back from DHIS2 by id, as ordered dictionaries that keep the
# server's own date text.

function Get-NeoIPCMetadataNestedExpansion {
    # Parent type -> the NestedOnly child collections read with the parent, each @{ ChildType; ArrayProp }.
    # These children have no addressable endpoint of their own (their schema descriptors set no API endpoint), and
    # a bare fields=:owner on the parent returns them as ids only, so the parent is read with the collection
    # expanded (fields=:owner,<arrayProp>[:owner]). A child whose parent fk is synthetic (analyticsPeriodBoundaries)
    # carries no reference back to its parent, so the verifier keeps it membership-only; -IncludeSyntheticFk
    # expands it too, for a deployment that compares its fields.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([switch]$IncludeSyntheticFk)
    $byParent = @{}
    foreach ($childType in $script:NeoIPCMetadataTypeMaps.Keys) {
        $map = $script:NeoIPCMetadataTypeMaps[$childType]
        if ($map.Nesting -ne 'NestedOnly' -or ($map.Parent.FkSynthetic -and -not $IncludeSyntheticFk)) { continue }
        $parentType = [string]$map.Parent.Type
        if (-not $byParent.ContainsKey($parentType)) { $byParent[$parentType] = [System.Collections.Generic.List[object]]::new() }
        $byParent[$parentType].Add(@{ ChildType = $childType; ArrayProp = [string]$map.Parent.ArrayProp })
    }
    $byParent
}

function Get-NeoIPCMetadataLiveObject {
    # Read the objects of one type back from DHIS2 by id, batched into `id:in:[…]` filters, and return
    # [pscustomobject]@{ ById = id -> ordered dictionary; Failure = $null or why the read stopped }. A failed batch
    # stops the read and is reported rather than thrown, so a caller can tell an unreadable type (its objects
    # unverified) from objects that are genuinely absent. $Endpoint is the Auth / Scheme / Hostname / Port splat
    # for Invoke-NeoIPCDhis2Get. Dates stay the server's text (-AsHashtable), so a value copied from the result
    # into a write body is exactly what DHIS2 stored.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][hashtable]$Endpoint,
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Id,
        [string[]]$Field = @(':owner'),
        [ValidateRange(1, 1000)][int]$BatchSize = 120
    )
    # DHIS2 UIDs are case-sensitive; a plain @{} would merge two that differ only in case.
    $byId = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    for ($i = 0; $i -lt $Id.Count; $i += $BatchSize) {
        $batch = @($Id[$i..([Math]::Min($i + $BatchSize, $Id.Count) - 1)])
        try {
            $resp = Invoke-NeoIPCDhis2Get @Endpoint -Path "api/$Type" -Fields $Field -Filter "id:in:[$($batch -join ',')]" -AsHashtable -Confirm:$false -WhatIf:$false
        }
        catch {
            return [pscustomobject]@{ ById = $byId; Failure = $_.Exception.Message }
        }
        # A 200 without the `$Type` collection (an unexpected envelope) is a failed read, not "every object absent".
        if ($resp -isnot [System.Collections.IDictionary] -or $null -eq $resp[$Type]) {
            return [pscustomobject]@{ ById = $byId; Failure = "response did not contain a '$Type' collection" }
        }
        foreach ($o in @($resp[$Type])) {
            if ($o -is [System.Collections.IDictionary] -and $o['id']) { $byId[[string]$o['id']] = $o }
        }
    }
    [pscustomobject]@{ ById = $byId; Failure = $null }
}

function Get-NeoIPCMetadataLiveList {
    # Every object of one type that DHIS2 lists, unpaged, as ordered dictionaries. A 200 without the `$Type`
    # collection throws rather than reading as an empty list: the deployment's checks decide from what the list holds,
    # so a list read as empty would pass them unchecked.
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][hashtable]$Endpoint,
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][string[]]$Field
    )
    $resp = Invoke-NeoIPCDhis2Get @Endpoint -Path "api/$Type" -Fields $Field -AsHashtable -Confirm:$false -WhatIf:$false
    if ($resp -isnot [System.Collections.IDictionary] -or $null -eq $resp[$Type]) { throw "the response held no '$Type' collection" }
    , @(@($resp[$Type]) | Where-Object { $_ -is [System.Collections.IDictionary] })
}

function Get-NeoIPCMetadataSchemaIndex {
    # The schema facts a deployment needs, read from /api/schemas: per plural, the class, the commit order, whether its
    # objects carry sharing, and for each property, by its JSON name, whether it is owned, persisted, embedded or a
    # collection, and the class it refers to. Returns [pscustomobject]@{ ByPlural; ByKlass }, each entry
    # { Plural; Klass; Order; Shareable; Properties }.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][hashtable]$Endpoint)
    $resp = Invoke-NeoIPCDhis2Get @Endpoint -Path 'api/schemas' -AsHashtable -Confirm:$false -WhatIf:$false `
        -Fields 'name,plural,klass,order,shareable,properties[name,collectionName,owner,persisted,collection,klass,itemKlass,embeddedObject]'
    if ($resp -isnot [System.Collections.IDictionary] -or $null -eq $resp['schemas']) { throw "Reading /api/schemas did not return a 'schemas' collection." }
    $byPlural = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    $byKlass = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    foreach ($s in @($resp['schemas'])) {
        if ($s -isnot [System.Collections.IDictionary]) { continue }
        # A schema read without the flag would make every type one without sharing, and the sharing rules silently moot.
        if ($null -eq $s['shareable']) { throw "Reading /api/schemas did not return the 'shareable' flag of '$($s['plural'])'." }
        $props = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
        foreach ($p in @($s['properties'])) {
            if ($p -isnot [System.Collections.IDictionary]) { continue }
            $json = if ($p['collection'] -and $p['collectionName']) { [string]$p['collectionName'] } else { [string]$p['name'] }
            $props[$json] = [pscustomobject]@{
                Owner      = [bool]$p['owner']
                Persisted  = [bool]$p['persisted']
                Embedded   = [bool]$p['embeddedObject']
                Collection = [bool]$p['collection']
                Target     = [string]$(if ($p['collection']) { $p['itemKlass'] } else { $p['klass'] })
            }
        }
        $entry = [pscustomobject]@{ Plural = [string]$s['plural']; Klass = [string]$s['klass']; Order = [int]$s['order']; Shareable = [bool]$s['shareable']; Properties = $props }
        if ($entry.Plural) { $byPlural[$entry.Plural] = $entry }
        if ($entry.Klass) { $byKlass[$entry.Klass] = $entry }
    }
    [pscustomobject]@{ ByPlural = $byPlural; ByKlass = $byKlass }
}
