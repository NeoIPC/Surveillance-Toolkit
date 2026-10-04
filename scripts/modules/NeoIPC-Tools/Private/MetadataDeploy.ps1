#Requires -Version 7.6
# Planning for Deploy-NeoIPCMetadata, free of I/O: the DHIS2 version parse, the comparison of a package object with
# its live counterpart, the write bodies, link deferral, option-group-set staging, children moved between parents,
# and the hazard gate. Each rule names the DHIS2 behaviour it answers to; docs/metadata-deployment.md describes them
# together.

# Properties a deployment takes from the live object, because they belong to the instance rather than to the
# package: org-unit assignments and memberships, user-group memberships, attribute values, per-user favourite marks,
# and the creation audit pair. A write without them would clear them (a metadata import replaces whatever it is
# given), and a write without `created` stamps it with the time of the write.
$script:NeoIPCDeployOwnedProperties = @('organisationUnits', 'users', 'attributeValues', 'favorites', 'created', 'createdBy')

# The membership properties among them that a synthetic deployment lets the package govern, for every type whose
# package objects carry the property at all.
$script:NeoIPCDeployMembershipProperties = @('organisationUnits', 'users')

# Owning collections whose live-only children DHIS2 deletes when the parent is written (each is mapped
# all-delete-orphan, a stage's sections delete-orphan on 2.40): parent type -> property -> child type. A deployment
# never deletes such a child through its own endpoint (DHIS2 2.41.10 and later answer a section's DELETE with 200 and
# keep the section); it writes the parent without the child. A program's stages and sections are not among them: DHIS2
# maps neither collection with a cascade, so a program written without one only detaches it.
$script:NeoIPCDeployOwnedChildren = @{
    programStages      = [ordered]@{ programStageSections = 'programStageSections'; programStageDataElements = 'programStageDataElements'; notificationTemplates = 'programNotificationTemplates' }
    programs           = [ordered]@{ programTrackedEntityAttributes = 'programTrackedEntityAttributes'; notificationTemplates = 'programNotificationTemplates' }
    programRules       = [ordered]@{ programRuleActions = 'programRuleActions' }
    programIndicators  = [ordered]@{ analyticsPeriodBoundaries = 'analyticsPeriodBoundaries' }
    trackedEntityTypes = [ordered]@{ trackedEntityTypeAttributes = 'trackedEntityTypeAttributes' }
}

# Types whose change leaves every program's client-side copy as it was, so they bump no program version. Clients
# reload a program's metadata only when its version changes; every type not listed here is treated as part of it.
$script:NeoIPCDeployOutsideProgramTypes = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@('organisationUnits', 'organisationUnitGroups', 'organisationUnitGroupSets', 'organisationUnitLevels',
        'userRoles', 'userGroups', 'users', 'attributes', 'validationRules', 'dataElementGroups', 'optionGroupSets'),
    [System.StringComparer]::Ordinal)

# The user properties a synthetic deployment compares. The password is never read back, so it cannot be compared:
# a package that supplies one has its users written.
$script:NeoIPCDeployUserScalars = @('username', 'firstName', 'surname')
$script:NeoIPCDeployUserRefs = @('userRoles', 'organisationUnits', 'dataViewOrganisationUnits', 'teiSearchOrganisationUnits')

function ConvertTo-NeoIPCDhis2Version {
    # DHIS2's version text (/api/system/info `version`: '2.41.10', '2.42.6.1', '2.43-SNAPSHOT') -> [version], from its
    # leading numeric components. Throws on text without major.minor, so a misread version never selects a branch.
    [CmdletBinding()]
    [OutputType([version])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    if ($Text -notmatch '^(\d+)\.(\d+)(?:\.(\d+))?(?:\.(\d+))?') { throw "Unparsable DHIS2 version '$Text'." }
    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add($Matches[1]); $parts.Add($Matches[2])
    $parts.Add($(if ($Matches[3]) { $Matches[3] } else { '0' }))
    if ($Matches[4]) { $parts.Add($Matches[4]) }
    [version]($parts -join '.')
}

function Copy-NeoIPCDeployValue {
    # Deep copy through JSON, dates kept as their text and a list kept a list even with one element.
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter(Mandatory)][AllowNull()]$Value)
    if ($null -eq $Value) { return $null }
    $copy = ConvertTo-Json -InputObject $Value -Depth 100 -Compress | ConvertFrom-Json -AsHashtable -DateKind String -NoEnumerate
    if ($copy -is [System.Collections.IDictionary] -or $copy -isnot [System.Collections.IList]) { return $copy }
    , @($copy)
}

function Test-NeoIPCDeployEmpty {
    # Null, an empty string, an empty dictionary and an empty list all mean "absent": DHIS2 imports them alike.
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()]$Value)
    ($null -eq $Value) -or ($Value -is [string] -and $Value -eq '') -or
    ($Value -is [System.Collections.IDictionary] -and $Value.Count -eq 0) -or
    ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string] -and $Value -isnot [System.Collections.IDictionary] -and @($Value).Count -eq 0)
}

function Get-NeoIPCDeployRefId {
    # The id of a reference: a { id } dictionary or a bare UID string (templateUid).
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()]$Reference)
    if ($Reference -is [System.Collections.IDictionary]) { return [string]$Reference['id'] }
    if ($Reference -is [string]) { return $Reference }
    $null
}

function Get-NeoIPCDeployRefIdList {
    # The ids of a reference or reference collection, in order.
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return , [string[]]@() }
    if ($Value -is [System.Collections.IDictionary] -or $Value -is [string]) { return , [string[]]@(@(Get-NeoIPCDeployRefId $Value) | Where-Object { $_ }) }
    , [string[]]@(@($Value) | ForEach-Object { Get-NeoIPCDeployRefId $_ } | Where-Object { $_ })
}

function Get-NeoIPCDeployChildType {
    # The NestedOnly child types a parent type carries: @{ ChildType; ArrayProp; FkProp } each.
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][string]$Type)
    , @(foreach ($childType in $script:NeoIPCMetadataTypeMaps.Keys) {
            $cmap = $script:NeoIPCMetadataTypeMaps[$childType]
            if ($cmap.Nesting -eq 'NestedOnly' -and [string]$cmap.Parent.Type -eq $Type) {
                @{ ChildType = $childType; ArrayProp = [string]$cmap.Parent.ArrayProp; FkProp = [string]$cmap.Parent.FkProp }
            }
        })
}

function Get-NeoIPCDeployProjection {
    # The part of an object a deployment compares, as an ordered dictionary (key -> comparable value): its type-map
    # properties, references reduced to ids (sorted, except the collections DHIS2 keeps in order), its nested
    # specs, its NestedOnly children by id, and the memberships in $GovernedOwned. Absent and empty values are left
    # out, and DHIS2's normalizations applied, so that an object DHIS2 holds as the package states compares equal:
    #   - programs and option sets: `version` is the deployment's to manage, never compared;
    #   - options: `sortOrder` is renumbered by the set's write (the set's list carries the order);
    #   - program and tracked-entity-type attributes: `name` and `valueType` are derived, not stored;
    #   - tracked-entity types: `shortName` is not stored before 2.42;
    #   - org units: DHIS2 returns `openingDate` / `closedDate` as timestamps, the package carries dates;
    #   - nested specs (validation-rule sides, render types) carry only the fields the type map names, since DHIS2
    #     adds others (a validation rule's side gains `translations: null`).
    # Users (no type map; compared only when a synthetic deployment carries them) project their names and roles
    # and org-unit scopes.
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Object,
        [Parameter(Mandatory)][version]$Version,
        [string[]]$GovernedOwned = @()
    )
    $out = [ordered]@{}
    if ($Type -eq 'users') {
        foreach ($p in $script:NeoIPCDeployUserScalars) { if (-not (Test-NeoIPCDeployEmpty $Object[$p])) { $out[$p] = [string]$Object[$p] } }
        foreach ($p in $script:NeoIPCDeployUserRefs) {
            $ids = [string[]]@(Get-NeoIPCMetadataOrdinalSort -Values (Get-NeoIPCDeployRefIdList $Object[$p]))
            if ($ids.Count -gt 0) { $out[$p] = $ids }
        }
        return $out
    }
    $map = $script:NeoIPCMetadataTypeMaps[$Type]
    if (-not $map) { throw "No type map for '$Type': a deployment compares only mapped types." }
    $skip = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    if ($Type -in 'programs', 'optionSets') { [void]$skip.Add('version') }
    if ($Type -eq 'options') { [void]$skip.Add('sortOrder') }
    if ($Type -in 'programTrackedEntityAttributes', 'trackedEntityTypeAttributes') { [void]$skip.Add('name'); [void]$skip.Add('valueType') }
    # NEOIPC-COMPAT(dhis2-pre-2.42-tracked-entity-type-shortname): TrackedEntityType.hbm.xml maps no shortName before
    # 2.42. Remove once no instance a deployment targets runs 2.41 or earlier (/api/system/info version 2.42 or later).
    if ($Type -eq 'trackedEntityTypes' -and $Version -lt [version]'2.42') { [void]$skip.Add('shortName') }
    # A NestedOnly child's reference to its parent is its place in the parent.
    if ($map.Nesting -eq 'NestedOnly') { [void]$skip.Add([string]$map.Parent.FkProp) }

    $classes = [ordered]@{}
    foreach ($p in $map.Properties.Keys) { $classes[$p] = [string]$map.Properties[$p] }
    foreach ($p in $GovernedOwned) { if (-not $classes.Contains($p)) { $classes[$p] = 'idArray' } }
    foreach ($p in $classes.Keys) {
        if ($skip.Contains($p)) { continue }
        $v = $Object[$p]
        if (Test-NeoIPCDeployEmpty $v) { continue }
        switch ($classes[$p]) {
            'id' { $out[$p] = Get-NeoIPCDeployRefId $v }
            { $_ -in 'idArray', 'idArrayOrdered' } {
                $ids = Get-NeoIPCDeployRefIdList $v
                if (-not $script:NeoIPCMetadataServerOrderedRefs.Contains("$Type|$p")) { $ids = [string[]]@(Get-NeoIPCMetadataOrdinalSort -Values $ids) }
                if ($ids.Count -gt 0) { $out[$p] = $ids }
            }
            { $_ -in 'stringArray', 'intArray' } {
                $vals = [string[]]@(Get-NeoIPCMetadataOrdinalSort -Values @(@($v) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ }))
                if ($vals.Count -gt 0) { $out[$p] = $vals }
            }
            'int' { $out[$p] = [long]$v }
            'bool' { $out[$p] = [bool]$v }
            default {
                $s = [string]$v
                if ($Type -eq 'organisationUnits' -and $p -in 'openingDate', 'closedDate' -and $s -match '^\d{4}-\d{2}-\d{2}') { $s = $s.Substring(0, 10) }
                $out[$p] = $s
            }
        }
    }
    if ($map.Nested) {
        foreach ($np in $map.Nested.Keys) {
            $sub = $Object[$np]
            if ($sub -isnot [System.Collections.IDictionary]) { continue }
            $spec = $map.Nested[$np]
            foreach ($f in $spec.Fields.Keys) {
                $raw = $sub[$f]
                if ($spec.Wrap) { $raw = if ($raw -is [System.Collections.IDictionary]) { $raw['type'] } else { $null } }
                if (Test-NeoIPCDeployEmpty $raw) { continue }
                $out["$np.$f"] = if ($spec.Fields[$f] -eq 'bool') { [bool]$raw } else { [string]$raw }
            }
        }
    }
    foreach ($child in (Get-NeoIPCDeployChildType -Type $Type)) {
        $kids = @(@($Object[$child.ArrayProp]) | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['id'] })
        if ($kids.Count -eq 0) { continue }
        $byId = [ordered]@{}
        foreach ($kid in ($kids | Sort-Object { [string]$_['id'] } -CaseSensitive)) {
            $byId[[string]$kid['id']] = Get-NeoIPCDeployProjection -Type $child.ChildType -Object $kid -Version $Version
        }
        $out[$child.ArrayProp] = $byId
        if ($script:NeoIPCMetadataServerOrderedRefs.Contains("$Type|$($child.ArrayProp)")) {
            $out["$($child.ArrayProp)#order"] = [string[]]@($kids | ForEach-Object { [string]$_['id'] })
        }
    }
    $out
}

function Get-NeoIPCDeployTranslationMap {
    # translations[] -> ordered "locale/PROPERTY" -> the translation entry.
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([AllowNull()]$Translations)
    $m = [ordered]@{}
    foreach ($t in @($Translations)) {
        if ($t -is [System.Collections.IDictionary] -and $t['locale'] -and $t['property']) { $m["$($t['locale'])/$($t['property'])"] = $t }
    }
    $m
}

function Compare-NeoIPCDeployObject {
    # Classify one existing package object against its live counterpart. Returns the base property names that differ
    # (a nested spec or child collection counts under its own property), plus 'translations' when a translation the
    # package carries is missing or different live (live translations the package lacks belong to the instance), plus
    # 'sharing' when the package carries sharing that differs once both are reduced to public and the user and
    # user-group grants (DHIS2 fills `owner` and, on 2.40, `external`; the package states neither), plus 'password'
    # for a user whose package supplies one. Empty means unchanged.
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][System.Collections.IDictionary]$PackageObject,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Live,
        [Parameter(Mandatory)][version]$Version,
        [string[]]$GovernedOwned = @()
    )
    $changed = [System.Collections.Generic.List[string]]::new()
    $a = Get-NeoIPCDeployProjection -Type $Type -Object $PackageObject -Version $Version -GovernedOwned $GovernedOwned
    $b = Get-NeoIPCDeployProjection -Type $Type -Object $Live -Version $Version -GovernedOwned $GovernedOwned
    foreach ($k in @(@($a.Keys) + @($b.Keys) | Select-Object -Unique)) {
        $ja = if ($a.Contains($k)) { ConvertTo-Json -InputObject $a[$k] -Compress -Depth 100 } else { $null }
        $jb = if ($b.Contains($k)) { ConvertTo-Json -InputObject $b[$k] -Compress -Depth 100 } else { $null }
        if ($ja -cne $jb) {
            $base = ($k -split '[.#]')[0]
            if (-not $changed.Contains($base)) { $changed.Add($base) }
        }
    }
    $pkgTr = Get-NeoIPCDeployTranslationMap $PackageObject['translations']
    $liveTr = Get-NeoIPCDeployTranslationMap $Live['translations']
    foreach ($k in $pkgTr.Keys) {
        if (-not $liveTr.Contains($k) -or [string]$liveTr[$k]['value'] -cne [string]$pkgTr[$k]['value']) { $changed.Add('translations'); break }
    }
    if ($PackageObject['sharing']) {
        $pa = Get-NeoIPCSharingCanonicalKey -Sharing (Convert-NeoIPCSharing $PackageObject['sharing'])
        $pb = Get-NeoIPCSharingCanonicalKey -Sharing (Convert-NeoIPCSharing $Live['sharing'])
        if ($pa -cne $pb) { $changed.Add('sharing') }
    }
    if ($Type -eq 'users' -and -not (Test-NeoIPCDeployEmpty $PackageObject['password'])) { $changed.Add('password') }
    , $changed.ToArray()
}

function New-NeoIPCDeployBody {
    # The body written for a package object: the package object, with the properties in $CopyOwned taken from the
    # live object (absent live means absent in the body), the live creation audit pair kept on its NestedOnly
    # children, the live version when -LiveVersion, and translations merged: the package's own pairs govern, live
    # pairs the package lacks are kept, except those of a property in $ChangedProperties, which are dropped (their
    # text translated the old value). Returns [pscustomobject]@{ Body; DroppedTranslations }.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][System.Collections.IDictionary]$PackageObject,
        [System.Collections.IDictionary]$Live,
        [string[]]$CopyOwned = @(),
        [string[]]$ChangedProperties = @(),
        [switch]$LiveVersion
    )
    $body = Copy-NeoIPCDeployValue $PackageObject
    $dropped = [System.Collections.Generic.List[object]]::new()
    if ($Live) {
        foreach ($k in $CopyOwned) {
            if (Test-NeoIPCDeployEmpty $Live[$k]) { [void]$body.Remove($k) } else { $body[$k] = Copy-NeoIPCDeployValue $Live[$k] }
        }
        foreach ($child in (Get-NeoIPCDeployChildType -Type $Type)) {
            $liveKids = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
            foreach ($lk in @($Live[$child.ArrayProp])) { if ($lk -is [System.Collections.IDictionary] -and $lk['id']) { $liveKids[[string]$lk['id']] = $lk } }
            foreach ($kid in @($body[$child.ArrayProp])) {
                if ($kid -isnot [System.Collections.IDictionary] -or -not $liveKids.ContainsKey([string]$kid['id'])) { continue }
                foreach ($k in 'created', 'createdBy') {
                    $lv = $liveKids[[string]$kid['id']][$k]
                    if (-not (Test-NeoIPCDeployEmpty $lv)) { $kid[$k] = Copy-NeoIPCDeployValue $lv }
                }
            }
        }
        $dropTokens = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($p in $ChangedProperties) { if ($script:NeoIPCMetadataTranslatableProperties.Contains($p)) { [void]$dropTokens.Add([string]$script:NeoIPCMetadataTranslatableProperties[$p]) } }
        $pkgTr = Get-NeoIPCDeployTranslationMap $body['translations']
        $merged = [System.Collections.Generic.List[object]]::new()
        foreach ($t in $pkgTr.Values) { $merged.Add($t) }
        foreach ($entry in (Get-NeoIPCDeployTranslationMap $Live['translations']).GetEnumerator()) {
            if ($pkgTr.Contains($entry.Key)) { continue }
            $t = $entry.Value
            if ($dropTokens.Contains([string]$t['property'])) {
                $dropped.Add([pscustomobject]@{ Type = $Type; Id = [string]$PackageObject['id']; Locale = [string]$t['locale']; Property = [string]$t['property']; Value = [string]$t['value'] })
                continue
            }
            $merged.Add([ordered]@{ locale = [string]$t['locale']; property = [string]$t['property']; value = [string]$t['value'] })
        }
        if ($merged.Count -gt 0) { $body['translations'] = @($merged) } else { [void]$body.Remove('translations') }
        if ($LiveVersion -and $Live.Contains('version')) { $body['version'] = $Live['version'] }
    }
    [pscustomobject]@{ Body = $body; DroppedTranslations = $dropped.ToArray() }
}

function Get-NeoIPCDeployDeferral {
    # Which references of the objects written must wait for a second request (R2). In one request DHIS2 drops an
    # owned reference to an object created in that same request when the target type commits at the same time as
    # the referring type or later and the payload populates no owned inverse property on the target that lists the
    # referrer (a new section listing a new program indicator: status OK, link missing). References between objects
    # of one type link only to targets earlier in the array (a managing user group placed before its managed group
    # loses the link). With every object present, R2 links them. Import hooks link org-unit parents and users'
    # org-unit scopes themselves, so those are never deferred.
    #   $Write  : ordered type -> list of bodies, in the order they are posted;
    #   $New    : HashSet of "type|id" created in this run;
    #   $Schema : Get-NeoIPCMetadataSchemaIndex.
    # Returns a Dictionary "type|id" -> Dictionary property -> HashSet of deferred target ids.
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.Dictionary[string, object]])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Write,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.HashSet[string]]$New,
        [Parameter(Mandatory)]$Schema
    )
    $ordinal = [System.StringComparer]::Ordinal
    $result = [System.Collections.Generic.Dictionary[string, object]]::new($ordinal)
    $bodyByKey = [System.Collections.Generic.Dictionary[string, object]]::new($ordinal)
    $position = [System.Collections.Generic.Dictionary[string, int]]::new($ordinal)
    # "type|id|property" -> the ids that body lists there, built once: on a fresh instance every option asks
    # whether its set lists it, and a set lists thousands.
    $listed = [System.Collections.Generic.Dictionary[string, object]]::new($ordinal)
    foreach ($type in $Write.Keys) {
        $i = 0
        foreach ($b in @($Write[$type])) { $bodyByKey["$type|$($b['id'])"] = $b; $position["$type|$($b['id'])"] = $i; $i++ }
    }
    foreach ($type in $Write.Keys) {
        $sT = $Schema.ByPlural[$type]
        if (-not $sT) { continue }
        foreach ($b in @($Write[$type])) {
            $sid = [string]$b['id']
            foreach ($pn in @($b.Keys)) {
                $pr = $sT.Properties[[string]$pn]
                if (-not $pr -or -not $pr.Owner -or -not $pr.Persisted -or $pr.Embedded -or $pn -eq 'sharing') { continue }
                if ($type -eq 'organisationUnits' -and $pn -eq 'parent') { continue }
                if ($type -eq 'users' -and $pn -in 'organisationUnits', 'dataViewOrganisationUnits', 'teiSearchOrganisationUnits') { continue }
                $tS = $Schema.ByKlass[$pr.Target]
                if (-not $tS) { continue }
                foreach ($rid in (Get-NeoIPCDeployRefIdList $b[$pn])) {
                    $tKey = "$($tS.Plural)|$rid"
                    if (-not $New.Contains($tKey)) { continue }
                    $defer = $false
                    if ($tS.Plural -eq $type) {
                        $defer = ($rid -ceq $sid) -or ($position.ContainsKey($tKey) -and $position[$tKey] -gt $position["$type|$sid"])
                    }
                    elseif ($tS.Order -ge $sT.Order) {
                        $linked = $false
                        $tb = $bodyByKey[$tKey]
                        if ($tb) {
                            foreach ($qn in @($tb.Keys)) {
                                $q = $tS.Properties[[string]$qn]
                                if (-not ($q -and $q.Owner -and $q.Persisted -and $q.Target -eq $sT.Klass)) { continue }
                                $listKey = "$tKey|$qn"
                                if (-not $listed.ContainsKey($listKey)) { $listed[$listKey] = [System.Collections.Generic.HashSet[string]]::new((Get-NeoIPCDeployRefIdList $tb[$qn]), $ordinal) }
                                if ($listed[$listKey].Contains($sid)) { $linked = $true; break }
                            }
                        }
                        $defer = -not $linked
                    }
                    if (-not $defer) { continue }
                    $key = "$type|$sid"
                    if (-not $result.ContainsKey($key)) { $result[$key] = [System.Collections.Generic.Dictionary[string, object]]::new($ordinal) }
                    if (-not $result[$key].ContainsKey([string]$pn)) { $result[$key][[string]$pn] = [System.Collections.Generic.HashSet[string]]::new($ordinal) }
                    [void]$result[$key][[string]$pn].Add($rid)
                }
            }
        }
    }
    , $result
}

function ConvertTo-NeoIPCDeployFirstPass {
    # The first request's form of a body: a copy without its deferred references, a collection keeping its other
    # members in order, a single reference left out. $Deferred is one entry of Get-NeoIPCDeployDeferral (property ->
    # deferred ids).
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Body, [Parameter(Mandatory)]$Deferred)
    $copy = Copy-NeoIPCDeployValue $Body
    foreach ($pn in $Deferred.Keys) {
        $v = $copy[$pn]
        if ($v -is [System.Collections.IDictionary] -or $v -is [string]) { [void]$copy.Remove($pn); continue }
        $copy[$pn] = @(@($v) | Where-Object { -not $Deferred[$pn].Contains((Get-NeoIPCDeployRefId $_)) })
    }
    $copy
}

function Get-NeoIPCDeployGroupSetPlan {
    # How each option group set's list reaches its final order. `optiongroupsetmembers` is UNIQUE(optiongroupid)
    # table-wide, and DHIS2 rewrites a list in place, so a write that shifts a group into a slot another row still
    # holds fails whole: a swap, a reorder, an interior removal. A group moved between two sets in one request fails
    # or commits depending on which set DHIS2 flushes first, an order the payload does not control. A reset of the
    # list to empty, then the new list in a later request, always lands exactly. Categories:
    #   Same   — unchanged list;
    #   Direct — the live list plus groups that belong to no set: written as is in R1;
    #   Defer  — the live list plus groups created in this run or moved in from another set: R1 keeps the live list,
    #            R2 writes the final one (after every reset);
    #   Reset  — anything else (a swap, a reorder, a removal, a group lost to another set): R1 keeps the live list,
    #            the list is reset to empty after R1, R2 writes the final one;
    #   New    — a set created in this run: R1 creates it empty, R2 writes its list.
    # $PackageSets: the package's optionGroupSets; $LiveLists: Dictionary set id -> live group ids, for EVERY live set;
    # $NewGroups: HashSet of group ids created in this run. Returns [pscustomobject]@{ Plan; Errors }, Plan a
    # Dictionary set id -> [pscustomobject]@{ Category; R1; R2 }.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$PackageSets,
        [Parameter(Mandatory)][System.Collections.IDictionary]$LiveLists,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.HashSet[string]]$NewGroups
    )
    $ordinal = [System.StringComparer]::Ordinal
    $plan = [System.Collections.Generic.Dictionary[string, object]]::new($ordinal)
    $errors = [System.Collections.Generic.List[string]]::new()
    $liveOwner = [System.Collections.Generic.Dictionary[string, string]]::new($ordinal)
    foreach ($sid in $LiveLists.Keys) { foreach ($g in @($LiveLists[$sid])) { $liveOwner[[string]$g] = [string]$sid } }
    $finalOwner = [System.Collections.Generic.Dictionary[string, string]]::new($ordinal)
    $packageSetIds = [System.Collections.Generic.HashSet[string]]::new($ordinal)
    foreach ($s in $PackageSets) { [void]$packageSetIds.Add([string]$s['id']) }
    foreach ($s in $PackageSets) {
        foreach ($g in (Get-NeoIPCDeployRefIdList $s['optionGroups'])) {
            if ($finalOwner.ContainsKey($g)) { $errors.Add("Option group $g is listed by both option group sets $($finalOwner[$g]) and $($s['id']); a group belongs to one set."); continue }
            $finalOwner[$g] = [string]$s['id']
        }
    }
    foreach ($s in $PackageSets) {
        $sid = [string]$s['id']
        $final = Get-NeoIPCDeployRefIdList $s['optionGroups']
        foreach ($g in $final) {
            if ($liveOwner.ContainsKey($g) -and $liveOwner[$g] -cne $sid -and -not $packageSetIds.Contains($liveOwner[$g])) {
                $errors.Add("Option group $g belongs to the live option group set $($liveOwner[$g]), which the package does not carry, so it cannot move to $sid.")
            }
        }
        if (-not $LiveLists.ContainsKey($sid)) {
            $plan[$sid] = [pscustomobject]@{ Category = 'New'; R1 = [string[]]@(); R2 = $(if ($final.Count -gt 0) { $final } else { $null }) }
            continue
        }
        $live = [string[]]@($LiveLists[$sid])
        if (($final -join ' ') -ceq ($live -join ' ')) { $plan[$sid] = [pscustomobject]@{ Category = 'Same'; R1 = $live; R2 = $null }; continue }
        # A set that loses a group, to another set or not, never appends.
        $isAppend = $final.Count -ge $live.Count -and ((@($final | Select-Object -First $live.Count)) -join ' ') -ceq ($live -join ' ')
        if (-not $isAppend) { $plan[$sid] = [pscustomobject]@{ Category = 'Reset'; R1 = $live; R2 = $final }; continue }
        $suffix = @($final | Select-Object -Skip $live.Count)
        $needsLater = @($suffix | Where-Object { $NewGroups.Contains($_) -or ($liveOwner.ContainsKey($_) -and $liveOwner[$_] -cne $sid) }).Count -gt 0
        $plan[$sid] = if ($needsLater) { [pscustomobject]@{ Category = 'Defer'; R1 = $live; R2 = $final } } else { [pscustomobject]@{ Category = 'Direct'; R1 = $final; R2 = $null } }
    }
    [pscustomobject]@{ Plan = $plan; Errors = $errors.ToArray() }
}

# The children a deployment moves from one parent it writes to another: those whose move was observed on DHIS2
# 2.40.12, 2.41.10, 2.42.6 and 2.43.1.
$script:NeoIPCDeployMovableChildren = @('programRuleActions', 'programStageSections', 'programNotificationTemplates')

function Get-NeoIPCDeployMove {
    # The children of owning collections that the package lists under another parent than the instance does, both
    # parents being objects of the package. Such a child is no orphan of its old parent. One request that writes both
    # parents moves a stage section on every line, but fails whole on DHIS2 2.40.12 for a rule action or a
    # notification template ("deleted object would be re-saved by cascade"). Written in two requests, the new parent
    # first, every one of them moves on every line: each commit ends by evicting Hibernate's second-level caches, so
    # the later write reads the old parent's collection from the database. The eviction runs inside the commit's
    # transaction, so a read of that collection in between could cache it as it was, and the deployment clears the
    # caches again before the later request; a cluster's other nodes are not covered. So R1 writes the child and its
    # new parent, and R2 the old parent.
    # Errors name the moves a deployment refuses, as not observed or not possible in two requests: a child of
    # another collection; a program as either parent of a notification template (a template's row holds its program
    # and its stage in two columns, so a stage's write does not take it from a program, and programs are written
    # last); a parent the package does not carry, whether -Delete deletes it or it stays on the instance; a parent
    # that both gives a child and takes one, which would have to be written both after and before a move; and, from
    # DHIS2 2.42, an action that sends a notification, which is deleted and created again on its own after R2 instead
    # of being written with its new rule in R1. An option moves between two sets the package carries (written
    # together in R1); one taken from a set the package does not carry is refused alike. A package that lists one
    # child under two parents is refused too.
    # $Types: the package's objects by type; $Live: type -> live object by id; $State: type -> status object by id;
    # $DeleteLive: type -> live object by id, of the -Delete entries.
    # Returns [pscustomobject]@{ Moves; Sources; Errors }: Moves a list of [pscustomobject]@{ Type; Id; From; To },
    # From and To "type|id" keys; Sources a HashSet of the From keys.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Types,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Live,
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][version]$Version,
        [System.Collections.IDictionary]$DeleteLive = @{}
    )
    $ordinal = [System.StringComparer]::Ordinal
    $errors = [System.Collections.Generic.List[string]]::new()
    # Where the package lists each child: child type -> child id -> "type|id" of its parent.
    $listedBy = @{}
    foreach ($pt in $script:NeoIPCDeployOwnedChildren.Keys) {
        foreach ($prop in $script:NeoIPCDeployOwnedChildren[$pt].Keys) {
            $ct = $script:NeoIPCDeployOwnedChildren[$pt][$prop]
            if (-not $listedBy.ContainsKey($ct)) { $listedBy[$ct] = [System.Collections.Generic.Dictionary[string, string]]::new($ordinal) }
            if (-not $Types.Contains($pt)) { continue }
            foreach ($p in $Types[$pt]) {
                $key = "$pt|$($p['id'])"
                foreach ($c in (Get-NeoIPCDeployRefIdList $p[$prop])) {
                    if (-not $listedBy[$ct].ContainsKey($c)) { $listedBy[$ct][$c] = $key; continue }
                    if ($listedBy[$ct][$c] -cne $key) { $errors.Add("The package lists $ct $c under both $($listedBy[$ct][$c] -replace '\|', ' ') and $pt $($p['id']); a child belongs to one parent.") }
                }
            }
        }
    }
    $moves = [System.Collections.Generic.List[object]]::new()
    $sources = [System.Collections.Generic.HashSet[string]]::new($ordinal)
    $targets = [System.Collections.Generic.HashSet[string]]::new($ordinal)
    foreach ($pt in $script:NeoIPCDeployOwnedChildren.Keys) {
        if (-not $Types.Contains($pt)) { continue }
        foreach ($p in $Types[$pt]) {
            $id = [string]$p['id']
            if ($State[$pt][$id].Status -ne 'Changed') { continue }
            foreach ($prop in $script:NeoIPCDeployOwnedChildren[$pt].Keys) {
                $ct = $script:NeoIPCDeployOwnedChildren[$pt][$prop]
                $keep = Get-NeoIPCDeployRefIdList $p[$prop]
                foreach ($c in (Get-NeoIPCDeployRefIdList $Live[$pt][$id][$prop])) {
                    if ($keep -ccontains $c -or -not $listedBy[$ct].ContainsKey($c)) { continue }
                    $m = [pscustomobject]@{ Type = $ct; Id = $c; From = "$pt|$id"; To = $listedBy[$ct][$c] }
                    $moves.Add($m); [void]$sources.Add($m.From); [void]$targets.Add($m.To)
                    $what = 'The package moves {0} {1} from {2} to {3}' -f $ct, $c, ($m.From -replace '\|', ' '), ($m.To -replace '\|', ' ')
                    if ($script:NeoIPCDeployMovableChildren -cnotcontains $ct) {
                        $errors.Add("$what. A deployment moves only rule actions, stage sections and notification templates between two parents it writes: give the child a new id under its new parent instead.")
                    }
                    elseif ($m.To.StartsWith('programs|')) {
                        $errors.Add("$what. Programs are written last, after the old parent's write has deleted what it no longer lists: give the template a new id under the program instead.")
                    }
                    elseif ($m.From.StartsWith('programs|')) {
                        $errors.Add("$what. A template's row holds its program apart from its stage, so the stage's write does not take it from the program, and the program's write, which comes last, deletes it: give the template a new id under its new stage instead.")
                    }
                    elseif ($ct -eq 'programRuleActions' -and $Version -ge [version]'2.42') {
                        $pa = @(@($Types['programRuleActions']) | Where-Object { $_ -is [System.Collections.IDictionary] -and [string]$_['id'] -ceq $c })[0]
                        $la = if ($Live.Contains('programRuleActions')) { $Live['programRuleActions'][$c] }
                        if (($pa -and $pa['templateUid']) -or ($la -and $la['templateUid'])) {
                            $errors.Add("$what. From DHIS2 2.42 an action that sends a notification is deleted and created again on its own after R2, so it is not written with its new rule in R1, which is how a deployment moves an action: give it a new id under its new rule instead.")
                        }
                    }
                }
            }
        }
    }
    # A child the package lists under one of its parents but that no parent of the package holds on the instance comes
    # from a -Delete entry, which deletes it with itself, or from an object the package neither carries nor deletes.
    $held = @{}
    foreach ($pt in $script:NeoIPCDeployOwnedChildren.Keys) {
        if (-not $Types.Contains($pt)) { continue }
        foreach ($p in $Types[$pt]) {
            $l = $Live[$pt][[string]$p['id']]
            if (-not $l) { continue }
            foreach ($prop in $script:NeoIPCDeployOwnedChildren[$pt].Keys) {
                $ct = $script:NeoIPCDeployOwnedChildren[$pt][$prop]
                if (-not $held.ContainsKey($ct)) { $held[$ct] = [System.Collections.Generic.HashSet[string]]::new($ordinal) }
                foreach ($c in (Get-NeoIPCDeployRefIdList $l[$prop])) { [void]$held[$ct].Add($c) }
            }
        }
    }
    $deletedBy = @{}
    foreach ($t in $DeleteLive.Keys) {
        if (-not $script:NeoIPCDeployDeletedWith.ContainsKey($t)) { continue }
        foreach ($id in @($DeleteLive[$t].Keys)) {
            $l = $DeleteLive[$t][$id]
            if (-not $l) { continue }
            foreach ($prop in $script:NeoIPCDeployDeletedWith[$t].Keys) {
                $ct = $script:NeoIPCDeployDeletedWith[$t][$prop]
                if (-not $deletedBy.ContainsKey($ct)) { $deletedBy[$ct] = [System.Collections.Generic.Dictionary[string, string]]::new($ordinal) }
                foreach ($c in (Get-NeoIPCDeployRefIdList $l[$prop])) { $deletedBy[$ct][$c] = "$t|$id" }
            }
        }
    }
    $notCarried = 'A deployment moves a child only between two parents it writes: give the child a new id under its new parent instead.'
    foreach ($ct in $script:NeoIPCDeployMovableChildren) {
        if (-not $listedBy.ContainsKey($ct) -or -not $Live.Contains($ct)) { continue }
        foreach ($c in $listedBy[$ct].Keys) {
            if (-not $Live[$ct][$c] -or ($held.ContainsKey($ct) -and $held[$ct].Contains($c))) { continue }
            $to = $listedBy[$ct][$c] -replace '\|', ' '
            if ($deletedBy.ContainsKey($ct) -and $deletedBy[$ct].ContainsKey($c)) { $errors.Add("The package moves $ct $c from $($deletedBy[$ct][$c] -replace '\|', ' '), which -Delete deletes, to $to. $notCarried") }
            else { $errors.Add("The package lists $ct $c under $to, but on the instance it belongs to a parent the package neither carries nor deletes. $notCarried") }
        }
    }
    # An option belongs to one set through its own row. One the package gives to another set it carries moves in R1,
    # with both sets' writes; one it takes from a set it does not carry is refused like the children above. An option
    # in no set on the instance has no set to leave.
    if ($Types.Contains('options') -and $Live.Contains('options')) {
        $packageSets = [System.Collections.Generic.HashSet[string]]::new($ordinal)
        if ($Types.Contains('optionSets')) { foreach ($s in $Types['optionSets']) { [void]$packageSets.Add([string]$s['id']) } }
        foreach ($o in $Types['options']) {
            $id = [string]$o['id']
            $l = $Live['options'][$id]
            if (-not $l) { continue }
            $from = Get-NeoIPCDeployRefId $l['optionSet']
            $to = Get-NeoIPCDeployRefId $o['optionSet']
            if (-not $from -or $from -ceq $to -or $packageSets.Contains($from)) { continue }
            $where = if ($DeleteLive.Contains('optionSets') -and $DeleteLive['optionSets'][$from]) { 'which -Delete deletes' } else { 'which the package neither carries nor deletes' }
            $errors.Add("The package moves options $id from optionSets $from, $where, to optionSets $to. A deployment moves an option only between two sets it writes: give the option a new id in its new set instead.")
        }
    }
    foreach ($k in $sources) {
        if ($targets.Contains($k)) {
            $errors.Add("$($k -replace '\|', ' ') both gives a child to another parent and takes one from another. A deployment writes a parent that gives a child after the move and one that takes a child before it, so it cannot do both: deploy the moves in separate deployments.")
        }
    }
    [pscustomobject]@{ Moves = $moves.ToArray(); Sources = $sources; Errors = $errors.ToArray() }
}

function Test-NeoIPCDeployInertRule {
    # A rule is inert when it can never fire: condition 'false' and no actions. Retiring a rule takes two
    # deployments, because clients keep running a cached rule after the server deletes it (Tracker Capture stores
    # rules in IndexedDB and only ever upserts them): the first makes it inert and moves the program version, so
    # clients reload it as inert, and a later one deletes it.
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Rule)
    ([string]$Rule['condition']).Trim() -eq 'false' -and (Get-NeoIPCDeployRefIdList $Rule['programRuleActions']).Count -eq 0
}

# The references that keep DHIS2 from deleting what they point at, by the type that holds them: referring type ->
# property -> referenced type. The deletion handlers veto the delete of a stage or stage section that a rule, a rule
# variable or a rule action refers to, and of an option set a data element uses; foreign keys refuse the delete of an
# option set that a tracked-entity attribute, an attribute, an option group or an option group set refers to, of an
# option group a group set lists, and of an option (which goes with its set) that an option group holds or a rule
# action targets. From DHIS2 2.42 a foreign key also refuses the delete of a notification template an action sends;
# up to 2.41 the action holds the template's id in a plain column, and the template's delete with its stage or
# program leaves that id pointing at nothing.
$script:NeoIPCDeployReferenceProperties = [ordered]@{
    programRuleActions      = [ordered]@{ dataElement = 'dataElements'; trackedEntityAttribute = 'trackedEntityAttributes'; programStageSection = 'programStageSections'
        programStage = 'programStages'; programIndicator = 'programIndicators'; optionGroup = 'optionGroups'; option = 'options' }
    programRuleVariables    = [ordered]@{ programStage = 'programStages'; dataElement = 'dataElements'; trackedEntityAttribute = 'trackedEntityAttributes' }
    programRules            = [ordered]@{ programStage = 'programStages' }
    dataElements            = [ordered]@{ optionSet = 'optionSets'; commentOptionSet = 'optionSets' }
    trackedEntityAttributes = [ordered]@{ optionSet = 'optionSets' }
    attributes              = [ordered]@{ optionSet = 'optionSets' }
    optionGroups            = [ordered]@{ optionSet = 'optionSets'; options = 'options' }
    optionGroupSets         = [ordered]@{ optionSet = 'optionSets'; optionGroups = 'optionGroups' }
}

# What DHIS2 deletes together with an object a deployment deletes through its own endpoint: type -> property -> type.
# A rule's actions, a stage's notification templates and a set's options go by cascade, which runs no deletion
# handler; a stage's sections go through ProgramStageSectionDeletionHandler, which deletes each through its service,
# so their own vetoes run. What refers to any of them is checked like the object itself, so that the deployment stops
# before its first write rather than on DHIS2's refusal. A stage's DELETE also deletes the event visualizations built
# on it and clears the stage on the map views that use it; those are no package's objects, and a stage in -Delete
# that any of them uses stops the deployment before its first write.
$script:NeoIPCDeployDeletedWith = @{
    programRules  = [ordered]@{ programRuleActions = 'programRuleActions' }
    programStages = [ordered]@{ programStageSections = 'programStageSections'; notificationTemplates = 'programNotificationTemplates' }
    optionSets    = [ordered]@{ options = 'options' }
}

function Get-NeoIPCDeployReference {
    # The objects an object of a referring type refers to, as "type|id": single references and collections alike. An
    # action's rule is left out, its notification template (templateUid) included.
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Object
    )
    $props = $script:NeoIPCDeployReferenceProperties[$Type]
    if (-not $props) { throw "No reference properties are known for '$Type'." }
    $refs = [System.Collections.Generic.List[string]]::new()
    foreach ($p in $props.Keys) {
        foreach ($id in (Get-NeoIPCDeployRefIdList $Object[$p])) { $refs.Add("$($props[$p])|$id") }
    }
    if ($Type -eq 'programRuleActions' -and $Object['templateUid']) { $refs.Add("programNotificationTemplates|$([string]$Object['templateUid'])") }
    , $refs.ToArray()
}

function Get-NeoIPCDeployDeleteOrder {
    # The order in which the types of the -Delete entries go: each before every type it refers to, through its own
    # objects or what DHIS2 deletes with them (an attribute before the option set it uses, although attributes commit
    # first; a rule, whose actions go with it, before the stage they target), and otherwise in descending schema order.
    # DHIS2 refuses to delete what something still refers to, so whatever refers goes first.
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Type,
        [Parameter(Mandatory)]$Schema
    )
    $covers = @{}
    $refersTo = @{}
    $descending = @{}
    foreach ($t in $Type) {
        $covers[$t] = @($t) + @(if ($script:NeoIPCDeployDeletedWith.ContainsKey($t)) { @($script:NeoIPCDeployDeletedWith[$t].Values) })
        $refersTo[$t] = @(foreach ($c in $covers[$t]) {
                if ($script:NeoIPCDeployReferenceProperties.Contains($c)) { @($script:NeoIPCDeployReferenceProperties[$c].Values) }
                if ($c -eq 'programRuleActions') { 'programNotificationTemplates' }
            })
        $descending[$t] = -1 * [int]$Schema.ByPlural[$t].Order
    }
    $left = [System.Collections.Generic.List[string]]::new([string[]]@($Type | Sort-Object @{ Expression = { $descending[$_] } }, @{ Expression = { $_ } }))
    $order = [System.Collections.Generic.List[string]]::new()
    while ($left.Count -gt 0) {
        $next = $null
        foreach ($t in $left) {
            $waits = @($left | Where-Object { $_ -cne $t -and @($refersTo[$_] | Where-Object { $covers[$t] -ccontains $_ }).Count -gt 0 })
            if ($waits.Count -eq 0) { $next = $t; break }
        }
        if (-not $next) { throw "The -Delete types refer to one another in a cycle: $($left -join ', ')." }
        $order.Add($next); [void]$left.Remove($next)
    }
    , $order.ToArray()
}
