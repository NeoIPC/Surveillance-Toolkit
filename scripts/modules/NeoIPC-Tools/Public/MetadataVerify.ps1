#Requires -Version 7.6
# Round-trip verification of a metadata import: the companion to Import-NeoIPCMetadata and Deploy-NeoIPCMetadata.
# After a package is imported it proves the import did not SILENTLY drop objects, owned-collection memberships,
# ordered-list order, or stringArray values. This guards a real DHIS2 import behaviour: optionGroup and
# optionGroupSet share one schema commit order, and which of the two commits first follows a hash map's iteration
# order, fixed when the server starts up to DHIS2 2.42 and liable to change while it runs on 2.43. When the sets
# commit first, an import that creates both links none of the sets' groups and still reports status=OK. Reading
# every object back with fields=:owner and diffing it against the package catches that and any analogous drop
# across every type at once.

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
          - OrderDrift   — an ORDERED reference collection whose members all round-trip but in a DIFFERENT order:
                           optionGroupSet.optionGroups, optionSet.options, category.categoryOptions,
                           categoryCombo.categories, programStageSection.dataElements / programIndicators,
                           programSection.trackedEntityAttributes, and the NestedOnly attribute lists
                           program.programTrackedEntityAttributes / trackedEntityType.trackedEntityTypeAttributes
                           (checked on the parent's child-id sequence). The order set is
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
          - TranslationMismatch — with -CheckTranslations: a translation the expected object carries that DHIS2
                           lacks or holds with another value, or, for an object in -Expected, a translation DHIS2
                           holds that the written body did not carry.
          - FetchFailed  — a whole type could not be read back (network / endpoint error). Reported as a record;
                           the caller decides severity — Deploy-NeoIPCMetadata treats it as fatal, since the type's
                           objects are then unverified.

        NestedOnly children (programStageDataElements, programTrackedEntityAttributes, trackedEntityTypeAttributes)
        have NO addressable top-level GET endpoint in DHIS2 2.40 (their SchemaDescriptors never set a relative API
        endpoint, and there is no controller — verified against refs/dhis2-core 2.40.3.2), and a bare fields=:owner
        on the parent returns them as id-ONLY (FieldPathHelper expands an un-elaborated owned ref-collection to its
        ids). So to diff their OWNED fields (compulsory, sortOrder, renderType, ...) the parent is fetched with the
        child collection EXPLICITLY expanded — fields=:owner,<arrayProp>[:owner] — and each child is compared out of
        the parent response. A NestedOnly child whose parent fk is synthetic (analyticsPeriodBoundaries) is not an
        independently identified object, so it stays membership-only (checked through its parent's collection field).

        An option set's order is the order of its options list, which DHIS2 keeps as received: on 2.40 the list
        position is the 1-based sort_order index column, and from 2.41 the set's write renumbers each option's
        sortOrder to its 0-based list position. The verifier therefore checks optionSet.options positionally
        (OrderDrift) and does not compare an option's absolute sortOrder, which the server renumbers.

        The PACKAGE is the source of truth: only the fields the package actually specifies are checked, so
        server-filled defaults never produce false positives. Server-managed / noisy dimensions (translations,
        sharing, audit, access) are skipped by default (-IgnoreField); -CheckTranslations compares translations
        separately. An empty result means a perfect round-trip — every object present, every link intact, every
        ordered list in order.

        Read-only (GETs only). It DRIVES a DHIS2 instance; for the local stack, pass -Scheme http -Hostname
        localhost -Port 8080 with a Basic-auth hashtable.
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
    .PARAMETER Expected
        The bodies actually written, as a package-shaped dictionary (type -> objects). An object found here is
        verified against this body instead of the package object, so properties a deployment carried over from
        the live instance (org-unit assignments, memberships, attribute values) are verified too. Objects absent
        here are verified against the package.
    .PARAMETER CheckTranslations
        Also compare translations. For an object from -Expected, DHIS2's translations must equal the written
        body's; for any other object, every translation the package carries must be present with the same value
        (DHIS2 may hold more).
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
        [System.Collections.IDictionary]$Expected,
        [switch]$CheckTranslations,
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

    # type -> id -> the body actually written (-Expected), which then stands in for the package object. Ids are
    # keyed ordinally: DHIS2 UIDs are case-sensitive.
    $expectedById = @{}
    if ($Expected) {
        foreach ($type in @($Expected.Keys)) {
            $map = [System.Collections.Generic.Dictionary[string, object]]::new($ordinal)
            foreach ($o in @($Expected[$type])) { if ($o -is [System.Collections.IDictionary] -and $o['id']) { $map[[string]$o['id']] = $o } }
            $expectedById[[string]$type] = $map
        }
    }

    # A reference is any dictionary carrying an `id`; in fields=:owner output DHIS2 returns owned references as bare
    # { id } objects, matching the package.
    function Get-NeoIPCRefId($x) {
        if ($x -is [System.Collections.IDictionary] -and $x.Contains('id')) { return [string]$x['id'] }
        return $null
    }
    function Test-NeoIPCIsRef($x) { $x -is [System.Collections.IDictionary] -and $x.Contains('id') }

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

    # Canonicalize a value for order-insensitive comparison: recursively sort the keys of every nested object
    # (the package and DHIS2 can hold the SAME nested data in a DIFFERENT key order — renderType { DESKTOP,
    # MOBILE }, style { icon, color } — which a raw ConvertTo-Json string compare would wrongly flag as a
    # FieldMismatch and block a good seed). Array order is preserved (it is semantically meaningful and checked in
    # the reference / *Array branches); only object keys are reordered. Scalars pass through unchanged, so genuine
    # value differences still surface.
    function ConvertTo-NeoIPCCanonical($Value) {
        if ($null -eq $Value) { return $null }
        if ($Value -is [System.Collections.IDictionary]) {
            $out = [ordered]@{}
            foreach ($k in (@($Value.Keys) | Sort-Object)) { $out[[string]$k] = ConvertTo-NeoIPCCanonical $Value[$k] }
            return $out
        }
        if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
            return @(foreach ($item in $Value) { ConvertTo-NeoIPCCanonical $item })
        }
        return $Value
    }

    # Diff one expected object's specified fields against its DHIS2 read-back, appending discrepancy records.
    # $SkipFields holds property names to bypass (the NestedOnly child collections on a parent, which are diffed
    # element-wise in their own pass — so the parent does not also membership-flag them).
    function Add-NeoIPCFieldDiscrepancies($Type, $PObj, $Imp, $Map, $SkipFields) {
        $id = [string]$PObj['id']
        $code = [string]$PObj['code']
        foreach ($field in @($PObj.Keys)) {
            $fname = [string]$field
            if ($fname -eq 'id' -or $fname -eq '__fk' -or $ignore.Contains($fname)) { continue }
            if ($SkipFields -and $SkipFields.Contains($fname)) { continue }
            # The server renumbers an option's sortOrder (see the help); the order is checked on optionSet.options.
            if ($Type -eq 'options' -and $fname -eq 'sortOrder') { continue }
            $expected = $PObj[$field]
            $actual = if ($Imp.Contains($fname)) { $Imp[$fname] } else { $null }
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
                # For the collections $NeoIPCMetadataServerOrderedRefs lists, additionally compare position so a
                # wrong-order reconnection is caught (OrderDrift).
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
            $e = ConvertTo-Json -InputObject (ConvertTo-NeoIPCCanonical $expected) -Compress -Depth 100
            $a = ConvertTo-Json -InputObject (ConvertTo-NeoIPCCanonical $actual) -Compress -Depth 100
            if ($e -cne $a) {
                $records.Add([pscustomobject]@{ Type = $Type; Id = $id; Code = $code; Kind = 'FieldMismatch'; Field = $fname
                        Detail = "package=$e DHIS2=$a" })
            }
        }
    }

    # Compare translations as (locale, property) -> value. $Exact: the read-back must hold exactly these (the body
    # was written); otherwise each expected translation must be present (DHIS2 may hold more).
    function Add-NeoIPCTranslationDiscrepancy($Type, $PObj, $Imp, [bool]$Exact) {
        $exp = [ordered]@{}; $act = [ordered]@{}
        foreach ($t in @($PObj['translations'])) { if ($t -is [System.Collections.IDictionary]) { $exp["$($t['locale'])/$($t['property'])"] = [string]$t['value'] } }
        foreach ($t in @($Imp['translations'])) { if ($t -is [System.Collections.IDictionary]) { $act["$($t['locale'])/$($t['property'])"] = [string]$t['value'] } }
        $problems = [System.Collections.Generic.List[string]]::new()
        foreach ($k in $exp.Keys) {
            if (-not $act.Contains($k)) { $problems.Add("missing $k") }
            elseif ($act[$k] -cne $exp[$k]) { $problems.Add("$k differs") }
        }
        if ($Exact) { foreach ($k in $act.Keys) { if (-not $exp.Contains($k)) { $problems.Add("unexpected $k") } } }
        if ($problems.Count -gt 0) {
            $shown = (@($problems) | Select-Object -First 6) -join '; '
            if ($problems.Count -gt 6) { $shown += '; …' }
            $records.Add([pscustomobject]@{ Type = $Type; Id = [string]$PObj['id']; Code = [string]$PObj['code']; Kind = 'TranslationMismatch'; Field = 'translations'
                    Detail = "$($problems.Count) difference(s): $shown" })
        }
    }

    # The work list: every top-level package type with id-bearing objects. NestedOnly children are NOT verified as
    # their own type (no top-level endpoint in 2.40) — they are diffed out of their parent's expanded read-back.
    $typeObjects = [ordered]@{}
    foreach ($type in @($pkg.Keys)) {
        $objs = @(@($pkg[$type]) | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['id'] })
        if ($objs.Count -gt 0) { $typeObjects[$type] = $objs }
    }

    # parent type -> the NestedOnly child collections to expand + diff in the parent's read-back.
    $nestedByParent = Get-NeoIPCMetadataNestedExpansion

    foreach ($type in @($typeObjects.Keys)) {
        $written = if ($expectedById.ContainsKey($type)) { $expectedById[$type] } else { [System.Collections.Generic.Dictionary[string, object]]::new($ordinal) }
        # The object each package entry is verified against: the written body where there is one.
        $objs = @(foreach ($o in $typeObjects[$type]) { if ($written.ContainsKey([string]$o['id'])) { $written[[string]$o['id']] } else { $o } })
        $map = $script:NeoIPCMetadataTypeMaps[$type]
        $childExpansions = if ($nestedByParent.ContainsKey($type)) { @($nestedByParent[$type]) } else { @() }
        $skipFields = [System.Collections.Generic.HashSet[string]]::new($ordinal)
        $fields = [System.Collections.Generic.List[string]]::new()
        $fields.Add(':owner')
        if ($CheckTranslations) { $fields.Add('translations') }
        foreach ($ce in $childExpansions) { $fields.Add("$($ce.ArrayProp)[:owner]"); [void]$skipFields.Add([string]$ce.ArrayProp) }
        Write-Verbose "Verifying $($objs.Count) $type ..."

        # Read the imported objects of this type back with all owned fields (and any NestedOnly children expanded).
        $live = Get-NeoIPCMetadataLiveObject -Endpoint $getArgs -Type $type -Id @($objs | ForEach-Object { [string]$_['id'] }) -Field $fields.ToArray() -BatchSize $BatchSize
        if ($live.Failure) {
            $records.Add([pscustomobject]@{ Type = $type; Id = ''; Code = ''; Kind = 'FetchFailed'; Field = ''; Detail = $live.Failure })
            continue
        }
        $importedById = $live.ById
        Write-Verbose "  read back $($importedById.Count) of $($objs.Count) $type"

        foreach ($pObj in $objs) {
            $id = [string]$pObj['id']
            $code = [string]$pObj['code']
            if (-not $importedById.ContainsKey($id)) {
                $records.Add([pscustomobject]@{ Type = $type; Id = $id; Code = $code; Kind = 'Missing'; Field = ''; Detail = 'object not present in DHIS2 after import' })
                continue
            }
            Add-NeoIPCFieldDiscrepancies $type $pObj $importedById[$id] $map $skipFields
            if ($CheckTranslations) { Add-NeoIPCTranslationDiscrepancy $type $pObj $importedById[$id] $written.ContainsKey($id) }
        }

        # NestedOnly children: diff each child's OWNED fields out of its parent's expanded read-back.
        foreach ($ce in $childExpansions) {
            $childType = $ce.ChildType
            $arrayProp = $ce.ArrayProp
            $childMap = $script:NeoIPCMetadataTypeMaps[$childType]
            $respChildById = [System.Collections.Generic.Dictionary[string, object]]::new($ordinal)
            foreach ($rp in $importedById.Values) {
                if ($rp.Contains($arrayProp)) { foreach ($rc in @($rp[$arrayProp])) { if ($rc -is [System.Collections.IDictionary] -and $rc['id']) { $respChildById[[string]$rc['id']] = $rc } } }
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
                # The child collection is a DHIS2 <list> whose order is the parent's (trackedEntityTypeAttributes
                # carry no element sortOrder at all), so check it positionally on the parent's child-id sequence.
                # The parent field itself is skipped in the parent compare above.
                if ($isOrderedChild -and $importedById.ContainsKey([string]$pObj['id'])) {
                    $imp = $importedById[[string]$pObj['id']]
                    $expIds = @(@($pObj[$arrayProp]) | ForEach-Object { Get-NeoIPCRefId $_ } | Where-Object { $_ })
                    $actIds = if ($imp.Contains($arrayProp)) { @(@($imp[$arrayProp]) | ForEach-Object { Get-NeoIPCRefId $_ } | Where-Object { $_ }) } else { @() }
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


function Test-NeoIPCProgramRuleActionServed {
    <#
    .SYNOPSIS
        Check that DHIS2 serves every program-rule action a package declares, through each rule's action collection.
    .DESCRIPTION
        Reads every program rule with its programRuleActions and compares them, by id, with the actions the package
        declares for that rule. Clients load a rule's actions through this collection, which DHIS2 serves from its
        second-level cache. Before DHIS2 2.40.4 (DHIS2-17470) the queries a tracker import runs could leave that cached
        collection holding only some of a rule's actions, so an action could exist in the database and still never
        fire. Test-NeoIPCMetadataImport reads the same collection, but right after the metadata import, which a later
        tracker import can undo: this check belongs after the last write to the instance.

        Read-only. Clear DHIS2's caches first (POST api/maintenance?cacheClear=true, which needs
        F_PERFORM_MAINTENANCE): the clear evicts a truncated collection, and without it a stale cached collection
        cannot be told from a genuinely missing action.
    .PARAMETER Path
        Path to the metadata package JSON file whose rules and actions are expected.
    .PARAMETER Package
        The package instead of -Path: the JSON string or the parsed hashtable.
    .PARAMETER Auth
        Auth hashtable from Resolve-NeoIPCAuth (Token or Basic).
    .PARAMETER Scheme
        DHIS2 scheme (http/https). Default https.
    .PARAMETER Hostname
        DHIS2 hostname. Default neoipc.charite.de.
    .PARAMETER Port
        DHIS2 port. Default none (scheme default).
    .OUTPUTS
        [object[]] of records { RuleId; RuleCode; Kind; ActionIds; Detail }: Kind RuleNotServed (the rule itself is
        not returned) or ActionNotServed (ActionIds lists the declared actions the rule does not serve). Empty means
        every declared action is served. Throws when the package declares no program-rule action, since the check
        would then pass without checking anything.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path')][string]$Path,
        [Parameter(Mandatory, ParameterSetName = 'Package')]$Package,
        [Parameter(Mandatory)][hashtable]$Auth,
        [string]$Scheme = 'https',
        [string]$Hostname = 'neoipc.charite.de',
        [Nullable[int]]$Port = $null
    )
    if ($PSCmdlet.ParameterSetName -eq 'Path') {
        if (-not (Test-Path -LiteralPath $Path)) { throw "Metadata package not found: '$Path'." }
        $pkg = ConvertFrom-NeoIPCMetadataJsonText -Json ([System.IO.File]::ReadAllText($Path))
    }
    elseif ($Package -is [string]) { $pkg = ConvertFrom-NeoIPCMetadataJsonText -Json $Package }
    elseif ($Package -is [System.Collections.IDictionary]) { $pkg = $Package }
    else { throw 'Package must be a JSON string, a parsed hashtable, or supply -Path.' }

    # Rule ids key these maps ordinally: DHIS2 UIDs are case-sensitive, and @{} would fold two that differ only in case.
    $ordinal = [System.StringComparer]::Ordinal
    $expected = [System.Collections.Generic.Dictionary[string, object]]::new($ordinal)
    foreach ($act in @($pkg['programRuleActions'])) {
        if ($act -isnot [System.Collections.IDictionary]) { continue }
        $ruleRef = $act['programRule']
        $ruleId = if ($ruleRef -is [System.Collections.IDictionary]) { [string]$ruleRef['id'] } else { [string]$ruleRef }
        if (-not $ruleId) { continue }
        if (-not $expected.ContainsKey($ruleId)) { $expected[$ruleId] = [System.Collections.Generic.HashSet[string]]::new($ordinal) }
        [void]$expected[$ruleId].Add([string]$act['id'])
    }
    if ($expected.Count -eq 0) { throw 'The package declares no program-rule actions, so there is nothing whose serving could be checked.' }
    $ruleCode = [System.Collections.Generic.Dictionary[string, string]]::new($ordinal)
    foreach ($r in @($pkg['programRules'])) { if ($r -is [System.Collections.IDictionary]) { $ruleCode[[string]$r['id']] = [string]$r['code'] } }

    $getArgs = @{ Auth = $Auth; Scheme = $Scheme; Hostname = $Hostname }
    if ($null -ne $Port) { $getArgs['Port'] = $Port }
    $resp = Invoke-NeoIPCDhis2Get @getArgs -Path 'api/programRules' -Fields 'id', 'programRuleActions[id]' -AsHashtable -Confirm:$false -WhatIf:$false
    if ($resp -isnot [System.Collections.IDictionary] -or $null -eq $resp['programRules']) {
        throw "Reading the program rules back did not return a 'programRules' collection."
    }
    # A rule serving no actions comes with an empty collection (DHIS2 omits only null values), and one without the
    # collection reads the same: either is exactly a rule to report.
    $served = [System.Collections.Generic.Dictionary[string, object]]::new($ordinal)
    foreach ($r in @($resp['programRules'])) {
        if ($r -isnot [System.Collections.IDictionary] -or -not $r['id']) { continue }
        $served[[string]$r['id']] = [System.Collections.Generic.HashSet[string]]::new(
            [string[]]@(@($r['programRuleActions']) | Where-Object { $_ -is [System.Collections.IDictionary] } | ForEach-Object { [string]$_['id'] }), $ordinal)
    }

    $records = [System.Collections.Generic.List[object]]::new()
    # Walked from the package side, so a rule the response leaves out entirely is reported too.
    foreach ($ruleId in @($expected.Keys | Sort-Object)) {
        if (-not $served.ContainsKey($ruleId)) {
            $records.Add([pscustomobject]@{ RuleId = $ruleId; RuleCode = $ruleCode[$ruleId]; Kind = 'RuleNotServed'; ActionIds = @($expected[$ruleId]); Detail = 'the rule itself is not served' })
            continue
        }
        $absent = @($expected[$ruleId] | Where-Object { -not $served[$ruleId].Contains($_) } | Sort-Object)
        if ($absent.Count -gt 0) {
            $records.Add([pscustomobject]@{ RuleId = $ruleId; RuleCode = $ruleCode[$ruleId]; Kind = 'ActionNotServed'; ActionIds = $absent
                    Detail = "$($absent.Count) of $($expected[$ruleId].Count) declared action(s) not served: $($absent -join ', ')" })
        }
    }
    Write-Verbose ("Served rule actions: {0} rule(s) checked, {1} short." -f $expected.Count, $records.Count)
    , [object[]]$records.ToArray()
}
