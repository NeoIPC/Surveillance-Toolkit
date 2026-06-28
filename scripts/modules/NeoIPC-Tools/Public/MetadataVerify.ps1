# Round-trip verification of a metadata import: the companion to Import-NeoIPCMetadata. After a package is
# imported it proves the import did not SILENTLY drop objects, owned-collection memberships, ordered-list
# order, or stringArray values. This guards a real DHIS2 import behaviour: a single combined /api/metadata
# import does NOT connect an optionGroupSet's `optionGroups` membership to optionGroups created in the SAME
# payload (verified empirically — the groups and the option->optionGroup links persist, only the
# group-set->group link is dropped), so an import that reports status=OK can still leave a group set with
# zero members. Reading every object back with fields=:owner and diffing it against the package catches that
# and any analogous drop across every type at once.

function Test-NeoIPCMetadataImport {
    <#
    .SYNOPSIS
        Round-trip verification: assert every object in a metadata package is present in DHIS2 and correctly
        linked after import.
    .DESCRIPTION
        For every object in $Package, fetches the imported object from DHIS2 with fields=:owner (all OWNED
        properties, including owned reference collections) and compares it against the package object. Emits one
        record per discrepancy:
          - Missing      — a package object absent from DHIS2 (the import dropped the whole object). Also raised
                           for a NestedOnly child (see below) the parent no longer carries.
          - LinkDrop     — an owned reference / reference-collection the package specifies that DHIS2 did not
                           store: a dropped group-set membership (optionGroupSet.optionGroups), or any other
                           reference field (optionSet.options, optionGroup.options, program.programStages,
                           programStage.programStageDataElements, ...). Reference collections are compared as
                           id-SETS so a member the package lists but DHIS2 lacks IS caught.
          - OrderDrift   — a genuinely ORDERED reference collection (a DHIS2 <list> with a sort_order list-index:
                           optionGroupSet.optionGroups, category.categoryOptions, categoryCombo.categories,
                           programStageSection.dataElements / programIndicators, programSection.trackedEntityAttributes,
                           and the NestedOnly attribute lists program.programTrackedEntityAttributes /
                           trackedEntityType.trackedEntityTypeAttributes — checked on the parent's child-id sequence)
                           whose members all round-trip but in a DIFFERENT order. The order set is
                           $NeoIPCMetadataServerOrderedRefs (keyed by "<type>|<property>") — deliberately narrower
                           than the normalizer's name-keyed $NeoIPCMetadataOrderedRefProps: e.g. dataElementGroup.members
                           is a DHIS2 <set> (read back in hash order) and is NOT order-checked even though its CSV cell
                           keeps a stable order.
          - ValueDrop    — a `stringArray` / `intArray` value (authorities, restrictions, deliveryChannels,
                           objectTypes, aggregationLevels, organisationUnitLevels) the package lists but DHIS2
                           did not store. Compared order-insensitively (these are DHIS2 <set>s), so a reordering
                           is NOT flagged — only a genuine value drop.
          - FieldMismatch — a non-reference scalar / nested-object field whose stored value differs from the
                           package (DHIS2 value normalization typically).
          - FetchFailed  — a whole type could not be read back (network / endpoint error). Reported as a record;
                           the caller decides severity — the seed's round-trip gate (Initialize-TestDhis2.ps1)
                           treats it as fatal, since its objects are then unverified.

        NestedOnly children (programStageDataElements, programTrackedEntityAttributes, trackedEntityTypeAttributes)
        have NO addressable top-level GET endpoint in DHIS2 2.40 (their SchemaDescriptors never set a relative API
        endpoint, and there is no controller — verified against refs/dhis2-core 2.40.3.2), and a bare fields=:owner
        on the parent returns them as id-ONLY (FieldPathHelper expands an un-elaborated owned ref-collection to its
        ids). So to diff their OWNED fields (compulsory, sortOrder, renderType, ...) the parent is fetched with the
        child collection EXPLICITLY expanded — fields=:owner,<arrayProp>[:owner] — and each child is compared out of
        the parent response. A NestedOnly child whose parent fk is synthetic (analyticsPeriodBoundaries) is not an
        independently identified object, so it stays membership-only (checked through its parent's collection field).

        Option sortOrder needs NO special handling and produces NO noise: DHIS2 maps OptionSet.options as a
        Hibernate <list> with <list-index column="sort_order" base="1"> (OptionSet.hbm.xml) and Option.sortOrder
        maps to the SAME column, so the persisted list position becomes the stored sortOrder — a 1-based dense rank
        per set. The package already emits option sortOrder as a 1-based contiguous sequence per set (the directory
        CSV and the pathogen / antibiotic generators alike), so the value round-trips exactly. Verified against
        refs/dhis2-core.

        The PACKAGE is the source of truth: only the fields the package actually specifies are checked, so
        server-filled defaults never produce false positives. Server-managed / noisy dimensions (translations,
        sharing, audit, access) are skipped by default (-IgnoreField). An empty result means a perfect
        round-trip — every object present, every link intact, every ordered list in order.

        Read-only (GETs only). It DRIVES a DHIS2 instance, so it is intended for the local / test stack; pass
        -Scheme http -Hostname localhost -Port 8080 with a Basic-auth hashtable for the local stack.
    .PARAMETER Path
        Path to a metadata package JSON file to verify.
    .PARAMETER Package
        The package to verify instead of -Path: the JSON string or the parsed hashtable from
        New-NeoIPCMetadataPackage.
    .PARAMETER Auth
        Auth hashtable from Resolve-NeoIPCAuth (Token or Basic).
    .PARAMETER Scheme
        DHIS2 scheme (http/https). Default https.
    .PARAMETER Hostname
        DHIS2 hostname. Default neoipc.charite.de.
    .PARAMETER Port
        DHIS2 port. Default none (scheme default).
    .PARAMETER IgnoreField
        Object property names to skip. Defaults to the server-managed / noisy set (translations, sharing,
        access, audit) plus `password`, so a synthetic user's login password is never echoed into a
        FieldMismatch detail.
    .PARAMETER BatchSize
        Maximum object ids per `id:in:[...]` request. Default 120 (keeps the request URL well within limits).
    .OUTPUTS
        [object[]] of discrepancy records { Type; Id; Code; Kind; Field; Detail }. Empty = perfect round-trip.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path')][string]$Path,
        [Parameter(Mandatory, ParameterSetName = 'Package')]$Package,
        [Parameter(Mandatory)][hashtable]$Auth,
        [string]$Scheme = 'https',
        [string]$Hostname = 'neoipc.charite.de',
        [Nullable[int]]$Port = $null,
        [string[]]$IgnoreField = @(
            'translations', 'sharing', 'access', 'publicAccess', 'externalAccess',
            'user', 'userAccesses', 'userGroupAccesses', 'favorites', 'favorite',
            'password', 'created', 'lastUpdated', 'createdBy', 'lastUpdatedBy',
            'createdByUserInfo', 'lastUpdatedByUserInfo', 'href'),
        [ValidateRange(1, 1000)][int]$BatchSize = 120
    )

    if ($PSCmdlet.ParameterSetName -eq 'Path') {
        if (-not (Test-Path -LiteralPath $Path)) { throw "Metadata package not found: '$Path'." }
        $pkg = [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json -AsHashtable -Depth 100
    }
    elseif ($Package -is [string]) { $pkg = $Package | ConvertFrom-Json -AsHashtable -Depth 100 }
    elseif ($Package -is [System.Collections.IDictionary]) { $pkg = $Package }
    else { throw 'Package must be a JSON string, a parsed hashtable, or supply -Path.' }

    $ignore = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($f in $IgnoreField) { [void]$ignore.Add($f) }

    $getArgs = @{ Auth = $Auth; Scheme = $Scheme; Hostname = $Hostname }
    if ($null -ne $Port) { $getArgs['Port'] = $Port }

    $records = [System.Collections.Generic.List[object]]::new()
    $ordinal = [System.StringComparer]::Ordinal

    # A reference is any object carrying an `id`; in fields=:owner output DHIS2 returns owned references as bare
    # { id } objects, matching the package. Extract the id whether the object is a package hashtable or a parsed
    # DHIS2 PSCustomObject.
    function Get-NeoIPCRefId($x) {
        if ($null -eq $x) { return $null }
        if ($x -is [System.Collections.IDictionary]) { if ($x.Contains('id')) { return [string]$x['id'] } return $null }
        $p = $x.PSObject.Properties['id']; if ($p) { return [string]$p.Value } return $null
    }
    function Test-NeoIPCIsRef($x) {
        if ($x -is [System.Collections.IDictionary]) { return $x.Contains('id') }
        return ($null -ne $x -and $null -ne $x.PSObject -and $null -ne $x.PSObject.Properties['id'])
    }

    # An ordered ref-collection drifts when its members all round-trip (membership is checked separately) but in
    # a different sequence. Returns a detail string when the package order is not preserved, else $null. A count
    # mismatch means a membership problem (Missing / LinkDrop, reported elsewhere), not an order one — so skip it.
    function Get-NeoIPCOrderDriftDetail($ExpIds, $ActIds) {
        $exp = @($ExpIds)
        if ($exp.Count -le 1) { return $null }
        $expSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$exp, $ordinal)
        $actInExp = @(@($ActIds) | Where-Object { $expSet.Contains($_) })
        if ($actInExp.Count -ne $exp.Count) { return $null }
        for ($k = 0; $k -lt $exp.Count; $k++) {
            if ($exp[$k] -cne $actInExp[$k]) {
                $expShown = (@($exp) | Select-Object -First 8) -join ','
                $actShown = (@($actInExp) | Select-Object -First 8) -join ','
                return "ordered list reconnected out of order: package [$expShown] DHIS2 [$actShown]"
            }
        }
        return $null
    }

    # Diff one package object's specified fields against its DHIS2 read-back, appending discrepancy records.
    # $SkipFields holds property names to bypass (the NestedOnly child collections on a parent, which are diffed
    # element-wise in their own pass — so the parent does not also membership-flag them).
    function Add-NeoIPCFieldDiscrepancies($Type, $PObj, $Imp, $Map, $SkipFields) {
        $id = [string]$PObj['id']
        $code = [string]$PObj['code']
        foreach ($field in @($PObj.Keys)) {
            $fname = [string]$field
            if ($fname -eq 'id' -or $fname -eq '__fk' -or $ignore.Contains($fname)) { continue }
            if ($SkipFields -and $SkipFields.Contains($fname)) { continue }
            $expected = $PObj[$field]
            $impProp = $Imp.PSObject.Properties[$fname]
            $actual = if ($impProp) { $impProp.Value } else { $null }
            $class = if ($Map -and $Map.Properties -and $Map.Properties.Contains($fname)) { [string]$Map.Properties[$fname] } else { '' }

            # stringArray / intArray: DHIS2 <set>s — compare values order-insensitively; a package value DHIS2
            # lacks is a ValueDrop. (Not a reference, so it never reaches the id-set branch below.)
            if ($class -eq 'stringArray' -or $class -eq 'intArray') {
                $expVals = @(@($expected) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
                $actVals = [System.Collections.Generic.HashSet[string]]::new($ordinal)
                foreach ($v in @($actual)) { if ($null -ne $v) { [void]$actVals.Add([string]$v) } }
                $missing = @($expVals | Where-Object { -not $actVals.Contains($_) })
                if ($missing.Count -gt 0) {
                    $shown = (@($missing) | Select-Object -First 8) -join ','
                    if ($missing.Count -gt 8) { $shown += ',…' }
                    $records.Add([pscustomobject]@{ Type = $Type; Id = $id; Code = $code; Kind = 'ValueDrop'; Field = $fname
                            Detail = "package lists $($expVals.Count) value(s), DHIS2 has $($actVals.Count); missing $($missing.Count): $shown" })
                }
                continue
            }

            $expArr = @($expected)
            if (($expArr.Count -gt 0 -and (Test-NeoIPCIsRef $expArr[0])) -or $class -eq 'idArray' -or $class -eq 'idArrayOrdered' -or $class -eq 'id') {
                # Reference (single or collection): compare membership as id-sets so a dropped link is caught.
                # For collections DHIS2 persists as ordered <list>s ($NeoIPCMetadataServerOrderedRefs) additionally
                # compare position so a wrong-order reconnection is caught (OrderDrift).
                $expIds = @($expArr | ForEach-Object { Get-NeoIPCRefId $_ } | Where-Object { $_ })
                $actIds = @(@($actual) | ForEach-Object { Get-NeoIPCRefId $_ } | Where-Object { $_ })
                $actSet = [System.Collections.Generic.HashSet[string]]::new($ordinal)
                foreach ($a in $actIds) { [void]$actSet.Add($a) }
                $missing = @($expIds | Where-Object { -not $actSet.Contains($_) })
                if ($missing.Count -gt 0) {
                    $shown = (@($missing) | Select-Object -First 8) -join ','
                    if ($missing.Count -gt 8) { $shown += ',…' }
                    $records.Add([pscustomobject]@{ Type = $Type; Id = $id; Code = $code; Kind = 'LinkDrop'; Field = $fname
                            Detail = "package lists $($expIds.Count) ref(s), DHIS2 has $($actSet.Count); missing $($missing.Count): $shown" })
                    continue
                }
                if ($script:NeoIPCMetadataServerOrderedRefs.Contains("$Type|$fname")) {
                    $detail = Get-NeoIPCOrderDriftDetail $expIds $actIds
                    if ($detail) {
                        $records.Add([pscustomobject]@{ Type = $Type; Id = $id; Code = $code; Kind = 'OrderDrift'; Field = $fname; Detail = $detail })
                    }
                }
                continue
            }
            $e = $expected | ConvertTo-Json -Compress -Depth 20
            $a = $actual | ConvertTo-Json -Compress -Depth 20
            if ($e -cne $a) {
                $records.Add([pscustomobject]@{ Type = $Type; Id = $id; Code = $code; Kind = 'FieldMismatch'; Field = $fname
                        Detail = "package=$e DHIS2=$a" })
            }
        }
    }

    # The work list: every top-level package type with id-bearing objects. NestedOnly children are NOT verified as
    # their own type (no top-level endpoint in 2.40) — they are diffed out of their parent's expanded read-back.
    $typeObjects = [ordered]@{}
    foreach ($type in @($pkg.Keys)) {
        $objs = @(@($pkg[$type]) | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['id'] })
        if ($objs.Count -gt 0) { $typeObjects[$type] = $objs }
    }

    # parent type -> the NestedOnly child collections to expand + diff in the parent's read-back (skip synthetic-fk
    # children, which are not independently identified objects).
    $nestedByParent = @{}
    foreach ($childType in $script:NeoIPCMetadataTypeMaps.Keys) {
        $cmap = $script:NeoIPCMetadataTypeMaps[$childType]
        if ($cmap.Nesting -ne 'NestedOnly' -or $cmap.Parent.FkSynthetic) { continue }
        $pt = [string]$cmap.Parent.Type
        if (-not $nestedByParent.ContainsKey($pt)) { $nestedByParent[$pt] = [System.Collections.Generic.List[object]]::new() }
        $nestedByParent[$pt].Add(@{ ChildType = $childType; ArrayProp = [string]$cmap.Parent.ArrayProp })
    }

    foreach ($type in @($typeObjects.Keys)) {
        $objs = @($typeObjects[$type])
        if ($objs.Count -eq 0) { continue }
        $map = $script:NeoIPCMetadataTypeMaps[$type]
        $childExpansions = if ($nestedByParent.ContainsKey($type)) { @($nestedByParent[$type]) } else { @() }
        $skipFields = [System.Collections.Generic.HashSet[string]]::new($ordinal)
        $fields = [System.Collections.Generic.List[string]]::new()
        $fields.Add(':owner')
        foreach ($ce in $childExpansions) { $fields.Add("$($ce.ArrayProp)[:owner]"); [void]$skipFields.Add([string]$ce.ArrayProp) }
        Write-Verbose "Verifying $($objs.Count) $type ..."

        # Read the imported objects of this type back with all owned fields (and any NestedOnly children expanded),
        # batched by id.
        $importedById = @{}
        $fetchFailed = $false
        for ($i = 0; $i -lt $objs.Count; $i += $BatchSize) {
            $batch = @($objs[$i..([Math]::Min($i + $BatchSize, $objs.Count) - 1)])
            $ids = @($batch | ForEach-Object { [string]$_['id'] })
            try {
                $resp = Invoke-NeoIPCDhis2Get @getArgs -Path "api/$type" -Fields $fields.ToArray() -Filter "id:in:[$($ids -join ',')]" -Confirm:$false
            }
            catch {
                $records.Add([pscustomobject]@{ Type = $type; Id = ''; Code = ''; Kind = 'FetchFailed'; Field = ''; Detail = $_.Exception.Message })
                $fetchFailed = $true
                break
            }
            # A 200 with no `$type` collection key (an unexpected envelope) is a read-back failure, not "all
            # objects missing" — record FetchFailed (fatal at the seed gate) rather than let `$resp.$type` throw
            # under StrictMode or flood every object as Missing.
            if ($null -eq $resp -or -not $resp.PSObject.Properties[$type]) {
                $records.Add([pscustomobject]@{ Type = $type; Id = ''; Code = ''; Kind = 'FetchFailed'; Field = ''; Detail = "response did not contain a '$type' collection" })
                $fetchFailed = $true
                break
            }
            foreach ($o in @($resp.$type)) { if ($null -ne $o -and $o.id) { $importedById[[string]$o.id] = $o } }
        }
        if ($fetchFailed) { continue }
        Write-Verbose "  read back $($importedById.Count) of $($objs.Count) $type"

        foreach ($pObj in $objs) {
            $id = [string]$pObj['id']
            $code = [string]$pObj['code']
            if (-not $importedById.ContainsKey($id)) {
                $records.Add([pscustomobject]@{ Type = $type; Id = $id; Code = $code; Kind = 'Missing'; Field = ''; Detail = 'object not present in DHIS2 after import' })
                continue
            }
            Add-NeoIPCFieldDiscrepancies $type $pObj $importedById[$id] $map $skipFields
        }

        # NestedOnly children: diff each child's OWNED fields out of its parent's expanded read-back.
        foreach ($ce in $childExpansions) {
            $childType = $ce.ChildType
            $arrayProp = $ce.ArrayProp
            $childMap = $script:NeoIPCMetadataTypeMaps[$childType]
            $respChildById = @{}
            foreach ($rp in $importedById.Values) {
                $rpProp = $rp.PSObject.Properties[$arrayProp]
                if ($rpProp) { foreach ($rc in @($rpProp.Value)) { if ($null -ne $rc -and $rc.id) { $respChildById[[string]$rc.id] = $rc } } }
            }
            $isOrderedChild = $script:NeoIPCMetadataServerOrderedRefs.Contains("$type|$arrayProp")
            foreach ($pObj in $objs) {
                if (-not ($pObj -is [System.Collections.IDictionary]) -or -not $pObj.Contains($arrayProp)) { continue }
                foreach ($pc in @($pObj[$arrayProp])) {
                    if (-not ($pc -is [System.Collections.IDictionary]) -or -not $pc['id']) { continue }
                    $cid = [string]$pc['id']
                    if (-not $respChildById.ContainsKey($cid)) {
                        $records.Add([pscustomobject]@{ Type = $childType; Id = $cid; Code = [string]$pc['code']; Kind = 'Missing'; Field = ''; Detail = "nested object absent from its parent ($type) after import" })
                        continue
                    }
                    Add-NeoIPCFieldDiscrepancies $childType $pc $respChildById[$cid] $childMap $null
                }
                # The child collection is a DHIS2 <list> whose order is the parent's (not recoverable from an
                # element sortOrder — trackedEntityTypeAttributes has none), so check it positionally on the
                # parent's child-id sequence. The parent field itself is skipped in the parent compare above.
                if ($isOrderedChild -and $importedById.ContainsKey([string]$pObj['id'])) {
                    $imp = $importedById[[string]$pObj['id']]
                    $expIds = @(@($pObj[$arrayProp]) | ForEach-Object { Get-NeoIPCRefId $_ } | Where-Object { $_ })
                    $rpProp = $imp.PSObject.Properties[$arrayProp]
                    $actIds = if ($rpProp) { @(@($rpProp.Value) | ForEach-Object { Get-NeoIPCRefId $_ } | Where-Object { $_ }) } else { @() }
                    $detail = Get-NeoIPCOrderDriftDetail $expIds $actIds
                    if ($detail) {
                        $records.Add([pscustomobject]@{ Type = $type; Id = [string]$pObj['id']; Code = [string]$pObj['code']; Kind = 'OrderDrift'; Field = $arrayProp; Detail = $detail })
                    }
                }
            }
        }
    }

    $summary = $records | Group-Object Kind | ForEach-Object { "$($_.Name)=$($_.Count)" }
    Write-Verbose ("Round-trip verification: {0}." -f $(if ($summary) { $summary -join ' ' } else { 'no discrepancies' }))
    , [object[]]$records.ToArray()
}
