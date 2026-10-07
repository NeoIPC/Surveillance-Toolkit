#Requires -Version 7.6
# The tracker API's request dialect per DHIS2 version, and one unpaged list read in it.

function Get-NeoIPCTrackerDialect {
    # The parameters a tracker list read takes on a DHIS2 version, and the key its response lists the items under.
    # 2.41 renamed the org-unit mode and paging parameters, the tracked-entity read's org-unit and tracked-entity
    # parameters (with ',' in place of ';' between their values), and the list key; 2.40 answers the new names with a
    # silently widened or paged read, and 2.42 ignores the old names, so a read in the wrong dialect widens rather than
    # fails.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][version]$Version)
    if ($Version -lt [version]'2.41') {
        # NEOIPC-COMPAT(dhis2-2.40-tracker-dialect): remove once no supported instance runs 2.40 (/api/system/info
        # version 2.41 or later everywhere).
        return [pscustomobject]@{
            OrgUnitMode           = 'ouMode'
            Paging                = @{ skipPaging = 'true' }
            ListKey               = @{ events = 'instances'; enrollments = 'instances'; trackedEntities = 'instances' }
            TrackedEntityQuery    = [pscustomobject]@{ OrgUnits = 'orgUnit'; TrackedEntities = 'trackedEntity'; Separator = ';' }
            # NEOIPC-COMPAT(dhis2-pre-2.42-filter-escape): see Test-NeoIPCTrackerFilterValue.
            RestoresFilterSlashes = $false
        }
    }
    [pscustomobject]@{
        OrgUnitMode           = 'orgUnitMode'
        # paging=false, which Invoke-NeoIPCDhis2Get sends on every read without -PageSize.
        Paging                = @{}
        ListKey               = @{ events = 'events'; enrollments = 'enrollments'; trackedEntities = 'trackedEntities' }
        TrackedEntityQuery    = [pscustomobject]@{ OrgUnits = 'orgUnits'; TrackedEntities = 'trackedEntities'; Separator = ',' }
        # NEOIPC-COMPAT(dhis2-pre-2.42-filter-escape): see Test-NeoIPCTrackerFilterValue.
        RestoresFilterSlashes = $Version -ge [version]'2.42'
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

function ConvertTo-NeoIPCTrackerFilterValue {
    # A value for a tracker attribute filter (<attribute>:eq:<value>), escaped the way DHIS2 parses it: '/' is the escape
    # character, so it is doubled first, then the two separators it guards, ':' and ',', are escaped. Whether an
    # instance reads the value back exactly is Test-NeoIPCTrackerFilterValue's answer. DHIS2 compares text attributes
    # lower-cased, so a caller that must not take one value for another compares what it reads back itself.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Value)
    $Value.Replace('/', '//').Replace(':', '/:').Replace(',', '/,')
}

function Test-NeoIPCTrackerFilterValue {
    # Whether DHIS2 reads an attribute-filter value back as ConvertTo-NeoIPCTrackerFilterValue sent it. Before 2.42 the
    # filter parser (RequestParamUtils.filterList on 2.40, RequestParamsValidator.filterList on 2.41) takes every
    # escaped slash out, skipping the second of two adjacent ones, and puts the slashes back in java.util.HashMap order
    # rather than in position order, so a value holding more than one '/' can be looked up as another value; a single
    # '/' comes back exactly. 2.42 replaced that parser with one that unescapes in order.
    # NEOIPC-COMPAT(dhis2-pre-2.42-filter-escape): remove once no supported instance runs a release before 2.42
    # (/api/system/info version 2.42 or later everywhere).
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$Dialect, [Parameter(Mandatory)][string]$Value)
    $Dialect.RestoresFilterSlashes -or $Value.Split('/').Count -le 2
}

function Get-NeoIPCTrackedEntityList {
    # Tracked entities of one type, read in the version's dialect as ordered dictionaries: those of one org unit
    # (SELECTED: for some program of the type, the org unit owns the entity, or registered it where that program has no
    # owner for it), optionally narrowed by one attribute's value; or those with the given UIDs (CAPTURE, read 50 UIDs
    # at a time), which DHIS2 looks for within the caller's data-capture org units, and on 2.43 for a superuser in every
    # org unit. CAPTURE always counts as a search inside the capture scope, where the type's maximum search result does
    # not apply. Every returned entity is checked against the request, and one the request did not ask for makes the
    # read throw, since 2.42 and later ignore a parameter name they do not know rather than refuse it.
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][hashtable]$Endpoint,
        [Parameter(Mandatory)]$Dialect,
        [Parameter(Mandatory)][string]$TrackedEntityTypeId,
        [Parameter(Mandatory)][ValidateSet('SELECTED', 'CAPTURE')][string]$OrgUnitMode,
        [string]$OrgUnitId,
        [string[]]$TrackedEntityId,
        [string]$AttributeId,
        [string]$AttributeValue,
        [switch]$IncludeDeleted,
        [Parameter(Mandatory)][string[]]$Fields
    )
    $ordinal = [System.StringComparer]::Ordinal
    if ($OrgUnitMode -eq 'SELECTED' -and -not $OrgUnitId) { throw 'A SELECTED tracked-entity read needs an org unit.' }
    if ($OrgUnitMode -eq 'CAPTURE' -and $OrgUnitId) { throw 'A CAPTURE tracked-entity read takes no org unit; DHIS2 2.41 and later refuse one.' }
    if ([bool]$AttributeId -ne [bool]$AttributeValue) { throw 'An attribute filter needs both the attribute and the value.' }
    if ($AttributeId -and -not (Test-NeoIPCTrackerFilterValue -Dialect $Dialect -Value $AttributeValue)) {
        throw "DHIS2 before 2.42 cannot look up the value '$AttributeValue': it holds more than one '/'."
    }
    $ids = @($TrackedEntityId | Where-Object { $_ })
    foreach ($id in @($ids + @($TrackedEntityTypeId, $OrgUnitId, $AttributeId) | Where-Object { $_ })) {
        if (-not (Test-NeoIPCMetadataUid -Id $id)) { throw "'$id' is not a DHIS2 UID, so it cannot go into a tracked-entity read." }
    }
    $base = @{ trackedEntityType = $TrackedEntityTypeId; $Dialect.OrgUnitMode = $OrgUnitMode }
    if ($OrgUnitId) { $base[$Dialect.TrackedEntityQuery.OrgUnits] = $OrgUnitId }
    if ($AttributeId) { $base['filter'] = '{0}:eq:{1}' -f $AttributeId, (ConvertTo-NeoIPCTrackerFilterValue -Value $AttributeValue) }
    if ($IncludeDeleted) { $base['includeDeleted'] = 'true' }

    $chunks = [System.Collections.Generic.List[string[]]]::new()
    if ($ids.Count -eq 0) { $chunks.Add([string[]]@()) }
    for ($i = 0; $i -lt $ids.Count; $i += 50) { $chunks.Add([string[]]$ids[$i..([Math]::Min($i + 49, $ids.Count - 1))]) }
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($chunk in $chunks) {
        $query = @{}
        foreach ($k in $base.Keys) { $query[$k] = $base[$k] }
        if ($chunk.Count -gt 0) { $query[$Dialect.TrackedEntityQuery.TrackedEntities] = $chunk -join $Dialect.TrackedEntityQuery.Separator }
        $asked = [System.Collections.Generic.HashSet[string]]::new([string[]]$chunk, $ordinal)
        foreach ($te in (Get-NeoIPCTrackerList -Endpoint $Endpoint -Dialect $Dialect -Resource 'trackedEntities' -Query $query -Fields $Fields)) {
            $uid = [string]$te['trackedEntity']
            if ($chunk.Count -gt 0 -and -not $asked.Contains($uid)) { throw "The tracked-entity read returned '$uid', which it did not ask for." }
            if ($te.Contains('trackedEntityType') -and [string]$te['trackedEntityType'] -cne $TrackedEntityTypeId) {
                throw "The tracked-entity read returned '$uid' of type '$($te['trackedEntityType'])', which it did not ask for."
            }
            if ($OrgUnitId) {
                $owners = @(@($te['programOwners']) | Where-Object { $_ -is [System.Collections.IDictionary] } | ForEach-Object { [string]$_['orgUnit'] })
                if ([string]$te['orgUnit'] -cne $OrgUnitId -and $owners -cnotcontains $OrgUnitId) {
                    throw "The tracked-entity read returned '$uid', which is neither registered nor owned in the org unit it asked for."
                }
            }
            if ($AttributeId) {
                $values = @(@($te['attributes']) | Where-Object { $_ -is [System.Collections.IDictionary] -and [string]$_['attribute'] -ceq $AttributeId } | ForEach-Object { [string]$_['value'] })
                if (@($values | Where-Object { [string]::Equals($_, $AttributeValue, [System.StringComparison]::OrdinalIgnoreCase) }).Count -eq 0) {
                    throw "The tracked-entity read returned '$uid', whose attribute value does not match the one it asked for."
                }
            }
            $result.Add($te)
        }
    }
    , $result.ToArray()
}
