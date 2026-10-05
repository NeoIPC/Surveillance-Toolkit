#Requires -Version 7.6

<#
.SYNOPSIS
    Pester tests for Deploy-NeoIPCMetadata and its planning helpers.

.DESCRIPTION
    Covers Private/MetadataDeploy.ps1 (the comparison, the write bodies, link deferral and option-group-set staging,
    all free of I/O) and Public/MetadataDeploy.ps1, which drives DHIS2. The orchestration tests run against a small
    in-memory DHIS2: the HTTP helpers are mocked by a fake that stores objects by type and id, applies a metadata
    import's payload, manages versions the way DHIS2 does (a payload version lower than the stored one is kept, an
    equal one stored plus one, a higher one adopted; each created option moves its set's version by one), deletes a
    rule's dropped actions, a stage's dropped sections and a stage's or program's dropped notification templates,
    takes the children a parent's write lists from their old parent (the child's own row holds its parent; a
    template's holds its stage and its program in two columns, so it moves only between two parents of one type),
    cascades a DELETE the way DHIS2 2.41.10 and later do (an option set's options, an option group's member options, a
    rule's actions, a stage's sections and notification templates), keeps a stage section on its own DELETE from
    2.41.10 and refuses a rule action's own DELETE on 2.40.12, replaces a collection with the items a collection
    endpoint's PUT lists, answers a tracker events read from the events it holds, resets the sharing of a shareable
    object written without a public access string, as DHIS2 does before it writes one, and records every request. It
    refuses an import with a reference, single or in a collection, to an object that neither exists nor comes with it
    (E5002, for the properties the tests use), or with an option whose name or code another option of its set holds
    as stored (E4028), and fails a committing import whole where DHIS2 fails while flushing
    it: an option group set's list rewritten onto a group another row still holds (optiongroupsetmembers is unique on
    the group, and DHIS2's flush order between sets is not the payload's, so both orders must hold), an update of a
    rule action that carries a template on 2.42 and later, a stage's write that drops a section a live rule action
    targets, and on 2.42 and later a stage's or program's write that drops a template a live action sends. It refuses
    the DELETE of a stage something refers to, events included, and of what a foreign key holds: a stage's template
    an action sends (2.42 and later), an option set something uses, one whose options an action or an option group
    holds, and an option group a group set lists; on 2.40.12, also an option group that has members. Like the real
    helpers, every mock but the status read sends and returns nothing under an inherited -WhatIf. The assertions are
    about the requests the deployment sends and the outcome it reports; the fake stands in for DHIS2's state, so that
    the deployment's own verification has something to read back.

    Self-contained: no live instance is needed and no API call is made. The schema facts link deferral reads from
    /api/schemas are a fixture of what DHIS2 reports for the package's types. One test assembles the real play
    package from metadata/, which takes some seconds.

.EXAMPLE
    Invoke-Pester -Path scripts/modules/NeoIPC-Tools/Tests/MetadataDeploy.Tests.ps1
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..') -Force

InModuleScope 'NeoIPC-Tools' {

    BeforeAll {
        # The commit order and the owned, persisted, non-embedded references of each type the play package
        # carries, as /api/schemas reports them on DHIS2 2.43.1 (the orders are the same on 2.40.12, 2.41.10 and
        # 2.42.6). Only references between these types are listed: a reference to any other type has no target
        # schema here and is never deferred, as with the real index.
        function Get-SchemaRow {
            @(
                'attributes|attribute.Attribute|100|createdBy>users,lastUpdatedBy>users,optionSet>optionSets'
                'userRoles|user.UserRole|100|createdBy>users,lastUpdatedBy>users'
                'users|user.User|101|createdBy>users,dataViewOrganisationUnits[]>organisationUnits,lastUpdatedBy>users,organisationUnits[]>organisationUnits,teiSearchOrganisationUnits[]>organisationUnits,userRoles[]>userRoles'
                'userGroups|user.UserGroup|102|createdBy>users,lastUpdatedBy>users,managedGroups[]>userGroups,users[]>users'
                'options|option.Option|1040|optionSet>optionSets'
                'optionSets|option.OptionSet|1050|createdBy>users,lastUpdatedBy>users,options[]>options'
                'optionGroups|option.OptionGroup|1051|createdBy>users,lastUpdatedBy>users,options[]>options,optionSet>optionSets'
                'optionGroupSets|option.OptionGroupSet|1051|createdBy>users,lastUpdatedBy>users,optionGroups[]>optionGroups,optionSet>optionSets'
                'organisationUnits|organisationunit.OrganisationUnit|1100|createdBy>users,lastUpdatedBy>users,parent>organisationUnits'
                'organisationUnitLevels|organisationunit.OrganisationUnitLevel|1110|lastUpdatedBy>users'
                'organisationUnitGroups|organisationunit.OrganisationUnitGroup|1120|createdBy>users,lastUpdatedBy>users,organisationUnits[]>organisationUnits'
                'organisationUnitGroupSets|organisationunit.OrganisationUnitGroupSet|1130|createdBy>users,lastUpdatedBy>users,organisationUnitGroups[]>organisationUnitGroups'
                'dataElements|dataelement.DataElement|1200|commentOptionSet>optionSets,createdBy>users,lastUpdatedBy>users,optionSet>optionSets'
                'dataElementGroups|dataelement.DataElementGroup|1210|createdBy>users,dataElements[]>dataElements,lastUpdatedBy>users'
                'validationRules|validation.ValidationRule|1390|createdBy>users,lastUpdatedBy>users'
                'trackedEntityAttributes|trackedentity.TrackedEntityAttribute|1450|createdBy>users,lastUpdatedBy>users,optionSet>optionSets'
                'trackedEntityTypes|trackedentity.TrackedEntityType|1480|createdBy>users,lastUpdatedBy>users'
                'programNotificationTemplates|program.notification.ProgramNotificationTemplate|1508|lastUpdatedBy>users,recipientDataElement>dataElements,recipientProgramAttribute>trackedEntityAttributes,recipientUserGroup>userGroups'
                'programStageSections|program.ProgramStageSection|1508|dataElements[]>dataElements,lastUpdatedBy>users,programIndicators[]>programIndicators,programStage>programStages'
                'programStages|program.ProgramStage|1509|createdBy>users,lastUpdatedBy>users,nextScheduleDate>dataElements,notificationTemplates[]>programNotificationTemplates,program>programs,programStageSections[]>programStageSections'
                'programs|program.Program|1520|createdBy>users,lastUpdatedBy>users,notificationTemplates[]>programNotificationTemplates,organisationUnits[]>organisationUnits,programSections[]>programSections,programStages[]>programStages,relatedProgram>programs,trackedEntityType>trackedEntityTypes,userRoles[]>userRoles'
                'programSections|program.ProgramSection|1550|lastUpdatedBy>users,program>programs,trackedEntityAttributes[]>trackedEntityAttributes'
                'programIndicators|program.ProgramIndicator|1560|createdBy>users,lastUpdatedBy>users,program>programs'
                'programRuleVariables|programrule.ProgramRuleVariable|1600|dataElement>dataElements,lastUpdatedBy>users,program>programs,programStage>programStages,trackedEntityAttribute>trackedEntityAttributes'
                'programRuleActions|programrule.ProgramRuleAction|1610|dataElement>dataElements,lastUpdatedBy>users,option>options,optionGroup>optionGroups,programIndicator>programIndicators,programRule>programRules,programStage>programStages,programStageSection>programStageSections,trackedEntityAttribute>trackedEntityAttributes'
                'programRules|programrule.ProgramRule|1620|lastUpdatedBy>users,program>programs,programRuleActions[]>programRuleActions,programStage>programStages'
            )
        }
        # The rows as Get-NeoIPCMetadataSchemaIndex builds them.
        function New-SchemaIndexFixture {
            $rows = Get-SchemaRow
            $klassOf = @{}
            foreach ($row in $rows) { $f = $row -split '\|'; $klassOf[$f[0]] = "org.hisp.dhis.$($f[1])" }
            $byPlural = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
            $byKlass = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
            foreach ($row in $rows) {
                $f = $row -split '\|'
                $props = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
                foreach ($ref in @($f[3] -split ',' | Where-Object { $_ })) {
                    $name, $target = $ref -split '>'
                    $props[$name.TrimEnd('[', ']')] = [pscustomobject]@{ Owner = $true; Persisted = $true; Embedded = $false; Collection = $name.EndsWith('[]'); Target = $klassOf[$target] }
                }
                $entry = [pscustomobject]@{ Plural = $f[0]; Klass = $klassOf[$f[0]]; Order = [int]$f[2]; Shareable = $script:FakeShareable.Contains($f[0])
                    DataShareable = $script:FakeDataShareable.Contains($f[0]); Properties = $props }
                $byPlural[$f[0]] = $entry; $byKlass[$entry.Klass] = $entry
            }
            [pscustomobject]@{ ByPlural = $byPlural; ByKlass = $byKlass }
        }
        # The rows as /api/schemas answers them, for the deployment's own read of the index.
        function New-SchemaResponseFixture {
            $rows = Get-SchemaRow
            $klassOf = @{}
            foreach ($row in $rows) { $f = $row -split '\|'; $klassOf[$f[0]] = "org.hisp.dhis.$($f[1])" }
            $schemas = foreach ($row in $rows) {
                $f = $row -split '\|'
                $props = foreach ($ref in @($f[3] -split ',' | Where-Object { $_ })) {
                    $name, $target = $ref -split '>'
                    if ($name.EndsWith('[]')) { @{ name = $name.TrimEnd('[', ']'); collectionName = $name.TrimEnd('[', ']'); owner = $true; persisted = $true; collection = $true; itemKlass = $klassOf[$target]; klass = 'java.util.List'; embeddedObject = $false } }
                    else { @{ name = $name; owner = $true; persisted = $true; collection = $false; klass = $klassOf[$target]; embeddedObject = $false } }
                }
                @{ name = $f[0]; plural = $f[0]; klass = $klassOf[$f[0]]; order = [int]$f[2]; shareable = $script:FakeShareable.Contains($f[0])
                    dataShareable = $script:FakeDataShareable.Contains($f[0]); properties = @($props) }
            }
            @{ schemas = @($schemas) }
        }

        function Copy-Value($Value) { if ($null -eq $Value) { return $null }; ConvertTo-Json -InputObject $Value -Depth 100 -Compress | ConvertFrom-Json -AsHashtable -DateKind String }
        function Get-IdList($Value) { @(@($Value) | Where-Object { $_ -is [System.Collections.IDictionary] } | ForEach-Object { [string]$_['id'] }) }

        # The types among these whose objects carry sharing, as /api/schemas on DHIS2 2.43.1 reports them (`shareable`).
        $script:FakeShareable = [System.Collections.Generic.HashSet[string]]::new([string[]]@('attributes', 'userRoles', 'userGroups',
                'optionSets', 'optionGroups', 'optionGroupSets', 'organisationUnitGroups', 'organisationUnitGroupSets', 'dataElements',
                'dataElementGroups', 'validationRules', 'trackedEntityAttributes', 'trackedEntityTypes', 'programStages', 'programs',
                'programIndicators'), [System.StringComparer]::Ordinal)
        # Those whose sharing also grants data access, as DHIS2's schema descriptors set it on every line (`dataShareable`).
        $script:FakeDataShareable = [System.Collections.Generic.HashSet[string]]::new([string[]]@('programs', 'programStages', 'trackedEntityTypes'),
            [System.StringComparer]::Ordinal)

        # ---- the fake DHIS2 -------------------------------------------------------------------------------------
        # The owning collections whose child's own row holds its parent: type, property, child type.
        $script:FakeHolders = @(
            @{ Type = 'optionSets'; Prop = 'options'; Child = 'options' }
            @{ Type = 'programRules'; Prop = 'programRuleActions'; Child = 'programRuleActions' }
            @{ Type = 'programStages'; Prop = 'programStageSections'; Child = 'programStageSections' }
            @{ Type = 'programStages'; Prop = 'notificationTemplates'; Child = 'programNotificationTemplates' }
            @{ Type = 'programs'; Prop = 'notificationTemplates'; Child = 'programNotificationTemplates' }
        )
        # The fake's version as the deployment reads DHIS2's text, a build suffix such as -SNAPSHOT left aside.
        function Get-FakeVersion { ConvertTo-NeoIPCDhis2Version -Text $script:Fake.Version }
        function Reset-FakeDhis2([string]$Version = '2.41.10') {
            $script:Fake = @{
                Version     = $Version
                Objects     = @{}
                Requests    = [System.Collections.Generic.List[object]]::new()
                DeleteKeeps = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
                Events      = [System.Collections.Generic.List[object]]::new()   # @{ event; programStage; deleted }
                FailImport  = $null   # scriptblock (payload) -> $true to answer a committing import with ERROR
                RefuseImport = $null  # scriptblock (payload) -> an HTTP status to answer a committing import with, as a proxy's HTML page
                ThrowImport = $null   # scriptblock (payload) -> $true to fail a committing import in transport
                ThrowPost   = $null   # scriptblock ({ Path; Mode }) -> $true to fail any POST in transport, a validation or cache clear included
                AfterImport = $null   # scriptblock (payload), run after a committed import
                ThrowGet    = $null   # scriptblock ({ Path; Filter; Fields }) -> $true to fail a read in transport
                NoList      = $null   # scriptblock ({ Path; Filter; Fields }) -> $true to answer a read with a 200 that holds no list (an object read: only its id)
                ThrowDelete = $null   # scriptblock (type, id) -> 'Refuse' to answer HTTP 409, 'Lose' to fail in transport
                StatusRead  = $null   # scriptblock ({ Path }) -> an HTTP status to answer a status read with, or nothing for the fake's own
                EventsKey   = $null   # the key a tracker events read lists its rows under, in place of the version's
                Stamp       = 0
            }
        }
        function Get-FakeType([string]$Type) {
            if (-not $script:Fake.Objects.ContainsKey($Type)) { $script:Fake.Objects[$Type] = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal) }
            $script:Fake.Objects[$Type]
        }
        function Set-FakeObject([string]$Type, $Object) {
            $c = Copy-Value $Object
            $script:Fake.Stamp++
            $c['lastUpdated'] = 'stamp-{0:D6}' -f $script:Fake.Stamp
            (Get-FakeType $Type)[[string]$c['id']] = $c
        }
        function Get-FakeObject([string]$Type, [string]$Id) { $t = Get-FakeType $Type; if ($t.ContainsKey($Id)) { $t[$Id] } else { $null } }
        function Set-FakeFromPackage($Package) { foreach ($t in @($Package.Keys)) { foreach ($o in @($Package[$t])) { Set-FakeObject $t $o } } }
        # The key of a child held by a parent of this type: "type|id", and for a notification template also the parent's
        # type, since a template's row holds its stage and its program in two columns of their own.
        function Get-FakeChildKey([string]$HolderType, [string]$Child, [string]$Id) { if ($Child -eq 'programNotificationTemplates') { "$Child@$HolderType|$Id" } else { "$Child|$Id" } }
        # The children the parents of a request list, by Get-FakeChildKey: one a parent's write drops goes to the other
        # parent of the same request that lists it in the same column, and is not deleted.
        function Get-FakeListed($Payload) {
            $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
            foreach ($h in $script:FakeHolders) {
                foreach ($p in @($Payload[$h.Type])) { if ($p -is [System.Collections.IDictionary]) { foreach ($c in (Get-IdList $p[$h.Prop])) { [void]$set.Add((Get-FakeChildKey $h.Type $h.Child $c)) } } }
            }
            , $set
        }
        function Invoke-FakeImport($Payload) {
            $created = 0; $updated = 0
            $listed = Get-FakeListed $Payload
            # Options commit before option sets (schema order 1040 < 1050): each created option moves its set's
            # stored version, so the set's own write then carries a lower version than stored and keeps it.
            $order = @(@($Payload.Keys) | Sort-Object { $(if ($_ -eq 'options') { 0 } else { 1 }) })
            foreach ($t in $order) {
                foreach ($o in @($Payload[$t])) {
                    $id = [string]$o['id']
                    $old = Get-FakeObject $t $id
                    $new = Copy-Value $o
                    if ($t -in 'programs', 'optionSets' -and $old) {
                        $stored = [int]$old['version']; $given = [int]$new['version']
                        $new['version'] = if ($given -lt $stored) { $stored } elseif ($given -eq $stored) { $stored + 1 } else { $given }
                    }
                    if ($t -eq 'options' -and -not $old) { $set = Get-FakeObject 'optionSets' ([string]$new['optionSet']['id']); if ($set) { $set['version'] = [int]$set['version'] + 1 } }
                    # A parent written without a child of an owning collection deletes that child, unless another parent
                    # of the request takes it.
                    if ($t -eq 'programRules' -and $old) {
                        foreach ($a in (Get-IdList $old['programRuleActions'])) { if ((Get-IdList $new['programRuleActions']) -cnotcontains $a -and -not $listed.Contains("programRuleActions|$a")) { [void](Get-FakeType 'programRuleActions').Remove($a) } }
                    }
                    if ($t -eq 'programStages' -and $old) {
                        foreach ($s in (Get-IdList $old['programStageSections'])) { if ((Get-IdList $new['programStageSections']) -cnotcontains $s -and -not $listed.Contains("programStageSections|$s")) { [void](Get-FakeType 'programStageSections').Remove($s) } }
                    }
                    if ($t -in 'programStages', 'programs' -and $old) {
                        foreach ($n in (Get-IdList $old['notificationTemplates'])) { if ((Get-IdList $new['notificationTemplates']) -cnotcontains $n -and -not $listed.Contains((Get-FakeChildKey $t 'programNotificationTemplates' $n))) { [void](Get-FakeType 'programNotificationTemplates').Remove($n) } }
                    }
                    # The child's own row holds its parent, so a parent's write takes the children it lists from any
                    # other parent, which then no longer holds them; a template only from a parent of the same type.
                    foreach ($h in $script:FakeHolders) {
                        if ($h.Type -ne $t) { continue }
                        $takenIds = Get-IdList $new[$h.Prop]
                        foreach ($other in $script:FakeHolders | Where-Object { $_.Child -eq $h.Child -and ($_.Child -ne 'programNotificationTemplates' -or $_.Type -eq $h.Type) }) {
                            foreach ($p in (Get-FakeType $other.Type).Values) {
                                if ($other.Type -eq $t -and [string]$p['id'] -ceq $id) { continue }
                                $kept = @(@($p[$other.Prop]) | Where-Object { $_ -is [System.Collections.IDictionary] -and $takenIds -cnotcontains [string]$_['id'] })
                                if ($kept.Count -lt @(Get-IdList $p[$other.Prop]).Count) { $p[$other.Prop] = $kept }
                            }
                        }
                    }
                    if ($old) { foreach ($k in 'created', 'createdBy') { if (-not $new.Contains($k) -and $old.Contains($k)) { $new[$k] = $old[$k] } } }
                    # Before the write, DHIS2 resets the sharing of a shareable object whose sharing has no public access
                    # string: default public access, the importing user as owner unless one is given, no grants.
                    if ($script:FakeShareable.Contains($t) -and -not ($new['sharing'] -is [System.Collections.IDictionary] -and $new['sharing']['public'])) {
                        $owner = if ($new['sharing'] -is [System.Collections.IDictionary] -and $new['sharing']['owner']) { $new['sharing']['owner'] } else { 'usIMPORTER1' }
                        $new['sharing'] = @{ owner = $owner; public = 'rw------'; users = @{}; userGroups = @{} }
                    }
                    Set-FakeObject $t $new
                    if ($old) { $updated++ } else { $created++ }
                }
            }
            @{ created = $created; updated = $updated }
        }
        function New-ImportReport([string]$Status, [int]$Created = 0, [int]$Updated = 0, [int]$Http = 200) {
            $json = '{"httpStatus":"OK","httpStatusCode":' + $Http + ',"status":"' + $Status + '","response":{"responseType":"ImportReport","status":"' + $Status + '","stats":{"created":' + $Created + ',"updated":' + $Updated + ',"deleted":0,"ignored":0,"total":' + ($Created + $Updated) + '},"typeReports":[]}}'
            [pscustomobject]@{ StatusCode = $Http; Body = ($json | ConvertFrom-Json) }
        }
        # A request that fails while DHIS2 flushes it: a bare WebMessage, nothing committed.
        function New-FlushFailure([string]$Message) {
            [pscustomobject]@{ StatusCode = 409; Body = ([pscustomobject]@{ httpStatus = 'Conflict'; httpStatusCode = 409; status = 'ERROR'; message = $Message }) }
        }
        # The group whose row collides when DHIS2 writes these option group sets in this order, or nothing. The model
        # is a mapped list's row-by-row update (the rows past the new length deleted, then each changed row updated
        # in index order, then the new rows inserted) against optiongroupsetmembers' table-wide unique key on the
        # group; it fails a swap and an interior move, as DHIS2 does.
        function Find-FakeGroupSetCollision([object[]]$Sets) {
            $rows = @{}
            foreach ($s in (Get-FakeType 'optionGroupSets').Values) { $rows[[string]$s['id']] = [System.Collections.Generic.List[string]]::new([string[]]@(Get-IdList $s['optionGroups'])) }
            foreach ($s in $Sets) {
                $sid = [string]$s['id']
                if (-not $rows.ContainsKey($sid)) { $rows[$sid] = [System.Collections.Generic.List[string]]::new() }
                $list = $rows[$sid]
                $new = @(Get-IdList $s['optionGroups'])
                while ($list.Count -gt $new.Count) { $list.RemoveAt($list.Count - 1) }
                for ($i = 0; $i -lt $new.Count; $i++) {
                    if ($i -lt $list.Count -and $list[$i] -ceq $new[$i]) { continue }
                    foreach ($other in $rows.Values) { if ($other.Contains($new[$i])) { return $new[$i] } }
                    if ($i -lt $list.Count) { $list[$i] = $new[$i] } else { $list.Add($new[$i]) }
                }
            }
        }
        # DHIS2 refuses a reference to an object that neither exists nor comes in the same request (E5002), a single
        # one or an item of a collection, by these properties.
        function Get-FakeMissingReference($Payload) {
            $targets = @{ program = 'programs'; programStage = 'programStages'; programStageSection = 'programStageSections'; programRule = 'programRules'
                optionSet = 'optionSets'; option = 'options'; optionGroup = 'optionGroups'; dataElement = 'dataElements'
                programRuleActions = 'programRuleActions'; programStageSections = 'programStageSections'; programStages = 'programStages'
                options = 'options'; optionGroups = 'optionGroups'; notificationTemplates = 'programNotificationTemplates'; dataElements = 'dataElements' }
            foreach ($t in @($Payload.Keys)) {
                foreach ($o in @($Payload[$t])) {
                    if ($o -isnot [System.Collections.IDictionary]) { continue }
                    foreach ($p in $targets.Keys) {
                        $tt = $targets[$p]
                        foreach ($rid in (Get-IdList $o[$p])) {
                            $inPayload = @(@($Payload[$tt]) | Where-Object { $_ -is [System.Collections.IDictionary] -and [string]$_['id'] -ceq $rid }).Count -gt 0
                            if (-not $inPayload -and -not (Get-FakeObject $tt $rid)) { return "E5002: $t $($o['id']) refers to $tt $rid, which does not exist" }
                        }
                    }
                }
            }
        }
        # DHIS2 refuses an option whose name or code another option of its set holds as the set is stored, a member the
        # same request drops included (E4028), in a validation too.
        function Get-FakeDuplicateOption($Payload) {
            foreach ($o in @($Payload['options'])) {
                if ($o -isnot [System.Collections.IDictionary] -or $o['optionSet'] -isnot [System.Collections.IDictionary]) { continue }
                $set = Get-FakeObject 'optionSets' ([string]$o['optionSet']['id'])
                if (-not $set) { continue }
                foreach ($m in (Get-IdList $set['options'])) {
                    if ($m -ceq [string]$o['id']) { continue }
                    $q = Get-FakeObject 'options' $m
                    if (-not $q -or $null -eq $q['name'] -or $null -eq $q['code']) { continue }
                    if ([string]$q['name'] -ceq [string]$o['name'] -or [string]$q['code'] -ceq [string]$o['code']) { return "E4028: option $($o['id']) has the name or code of option $m in set $($set['id'])" }
                }
            }
        }
        # Why DHIS2 would refuse to delete this object, or nothing: its deletion handlers' vetoes and the foreign keys
        # that what goes with it by cascade (a stage's notification templates, a set's options) runs into.
        function Get-FakeDeleteVeto([string]$Type, [string]$Id, $Object) {
            $points = { param($x, [string]$Prop, [string[]]$Ids) $x[$Prop] -is [System.Collections.IDictionary] -and $Ids -ccontains [string]$x[$Prop]['id'] }
            if ($Type -eq 'programStages') {
                $sections = Get-IdList $Object['programStageSections']
                foreach ($rt in 'programRules', 'programRuleVariables', 'programRuleActions') {
                    foreach ($x in (Get-FakeType $rt).Values) {
                        if ((& $points $x 'programStage' @($Id)) -or (& $points $x 'programStageSection' $sections)) { return "associated with another object: $rt $($x['id'])" }
                    }
                }
                if (@($script:Fake.Events | Where-Object { $_.programStage -ceq $Id }).Count -gt 0) { return 'associated with another object: Event' }
                if ((Get-FakeVersion) -ge [version]'2.42') {
                    $templates = Get-IdList $Object['notificationTemplates']
                    foreach ($a in (Get-FakeType 'programRuleActions').Values) {
                        if ($a['templateUid'] -and $templates -ccontains [string]$a['templateUid']) { return "violating foreign key constraint fk_programruleaction_notificationtemplate: $($a['id'])" }
                    }
                }
            }
            if ($Type -eq 'optionGroups') {
                foreach ($s in (Get-FakeType 'optionGroupSets').Values) { if ((Get-IdList $s['optionGroups']) -ccontains $Id) { return "violating foreign key constraint fk_optiongroupsetmembers_optiongroupid: $($s['id'])" } }
                # On 2.40.12 a group that still has members cannot go; from 2.41.10 its members go with it (the cascade below).
                if ((Get-FakeVersion) -lt [version]'2.41' -and @(Get-IdList $Object['options']).Count -gt 0) { return 'deleted object would be re-saved by cascade (remove deleted object from associations)' }
            }
            if ($Type -eq 'optionSets') {
                foreach ($rt in 'dataElements', 'trackedEntityAttributes', 'attributes', 'optionGroups', 'optionGroupSets') {
                    foreach ($x in (Get-FakeType $rt).Values) { if ((& $points $x 'optionSet' @($Id)) -or (& $points $x 'commentOptionSet' @($Id))) { return "associated with another object: $rt $($x['id'])" } }
                }
                $options = Get-IdList $Object['options']
                foreach ($a in (Get-FakeType 'programRuleActions').Values) { if (& $points $a 'option' $options) { return "violating foreign key constraint fk_programruleaction_option: $($a['id'])" } }
                foreach ($g in (Get-FakeType 'optionGroups').Values) {
                    if (@(Get-IdList $g['options'] | Where-Object { $options -ccontains $_ }).Count -gt 0) { return "violating foreign key constraint fk_optiongroupmembers_optionid: $($g['id'])" }
                }
            }
        }
        # Why DHIS2 would fail this committing import while flushing it, or nothing. A child that one parent of the
        # request drops and another lists moves rather than goes, so nothing refers to it as deleted.
        function Get-FakeFlushFailure($Payload) {
            $listed = Get-FakeListed $Payload
            # On 2.40.12 a request that writes the rule an action leaves and the rule it moves to fails whole, and so
            # does one that moves a notification template between two stages or programs: the old parent's write
            # orphans the child, and the new parent's cascade reaches it again. A stage section moves.
            if ((Get-FakeVersion) -lt [version]'2.41') {
                foreach ($h in @($script:FakeHolders | Where-Object { $_.Child -in 'programRuleActions', 'programNotificationTemplates' })) {
                    foreach ($p in @($Payload[$h.Type])) {
                        $old = if ($p -is [System.Collections.IDictionary]) { Get-FakeObject $h.Type ([string]$p['id']) }
                        if (-not $old) { continue }
                        foreach ($c in (Get-IdList $old[$h.Prop])) {
                            if ((Get-IdList $p[$h.Prop]) -cnotcontains $c -and $listed.Contains((Get-FakeChildKey $h.Type $h.Child $c))) { return "deleted object would be re-saved by cascade (remove deleted object from associations): $($h.Child) $c" }
                        }
                    }
                }
            }
            # From 2.42 any update of an existing rule action that carries a template fails whole.
            if ((Get-FakeVersion) -ge [version]'2.42') {
                foreach ($a in @($Payload['programRuleActions'])) {
                    if ($a -is [System.Collections.IDictionary] -and $a['templateUid'] -and (Get-FakeObject 'programRuleActions' ([string]$a['id']))) {
                        return 'object references an unsaved transient instance: ProgramRuleAction.notificationTemplate'
                    }
                }
            }
            # From 2.42 an action refers to its template through a foreign key, and a stage's or a program's write
            # deletes the templates it drops before the request's rule actions commit.
            if ((Get-FakeVersion) -ge [version]'2.42') {
                foreach ($pt in 'programStages', 'programs') {
                    foreach ($p in @($Payload[$pt])) {
                        $old = if ($p -is [System.Collections.IDictionary]) { Get-FakeObject $pt ([string]$p['id']) }
                        if (-not $old) { continue }
                        foreach ($n in (Get-IdList $old['notificationTemplates'])) {
                            if ((Get-IdList $p['notificationTemplates']) -ccontains $n -or $listed.Contains((Get-FakeChildKey $pt 'programNotificationTemplates' $n))) { continue }
                            foreach ($a in (Get-FakeType 'programRuleActions').Values) {
                                if ([string]$a['templateUid'] -ceq $n) { return "violating foreign key constraint fk_programruleaction_notificationtemplate: $($a['id'])" }
                            }
                        }
                    }
                }
            }
            # A stage's write deletes the sections it drops before the request's rule actions commit, and DHIS2 vetoes
            # the delete of a section a live action targets.
            foreach ($st in @($Payload['programStages'])) {
                $old = if ($st -is [System.Collections.IDictionary]) { Get-FakeObject 'programStages' ([string]$st['id']) }
                if (-not $old) { continue }
                foreach ($sec in (Get-IdList $old['programStageSections'])) {
                    if ((Get-IdList $st['programStageSections']) -ccontains $sec -or $listed.Contains("programStageSections|$sec")) { continue }
                    foreach ($act in (Get-FakeType 'programRuleActions').Values) {
                        if ($act['programStageSection'] -and [string]$act['programStageSection']['id'] -ceq $sec) { return "Object could not be deleted because it is associated with another object: ProgramRule (section $sec)" }
                    }
                }
            }
            # DHIS2 flushes the sets in an order the payload does not control, so the request must hold in either.
            $sets = @(@($Payload['optionGroupSets']) | Where-Object { $_ -is [System.Collections.IDictionary] })
            if ($sets.Count -gt 0) {
                $reversed = [object[]]$sets.Clone(); [array]::Reverse($reversed)
                $g = Find-FakeGroupSetCollision $sets
                if (-not $g) { $g = Find-FakeGroupSetCollision $reversed }
                if ($g) { return "duplicate key value violates unique constraint on optiongroupsetmembers: Key (optiongroupid)=($g) already exists." }
            }
        }

        # Every HTTP helper but the status read asks ShouldProcess, so under an inherited -WhatIf the real one sends
        # nothing and returns nothing; each mock does the same.
        function Set-FakeMock {
            Mock Invoke-NeoIPCDhis2Get {
                if ($WhatIfPreference) { return }
                if ($script:Fake.ThrowGet -and (& $script:Fake.ThrowGet ([pscustomobject]@{ Path = $Path; Filter = $Filter; Fields = $Fields }))) { throw "Failed to fetch '$Path' from DHIS2: The SSL connection could not be established." }
                $p = $Path -replace '^api/', ''
                if ($p -eq 'system/info') { return @{ version = $script:Fake.Version } }
                if ($p -eq 'schemas') {
                    # Like DHIS2, the schema read carries the sharing flags only when they are asked for.
                    $f = New-SchemaResponseFixture
                    foreach ($flag in 'shareable', 'dataShareable') {
                        if ((@($Fields) -join ',') -notmatch "(^|,)$flag(,|$)") { foreach ($s in $f.schemas) { $s.Remove($flag) } }
                    }
                    return $f
                }
                if ($p -eq 'tracker/events') {
                    $script:Fake.Requests.Add(@{ Kind = 'events'; Query = $QueryParameters; PageSize = $PageSize })
                    if ((Get-FakeVersion) -ge [version]'2.43' -and -not $QueryParameters['program']) { throw "Failed to fetch '$Path' from DHIS2: 400 (Bad Request)" }
                    $rows = @($script:Fake.Events | Where-Object { $_.programStage -ceq [string]$QueryParameters['programStage'] -and ($QueryParameters['includeDeleted'] -eq 'true' -or -not $_.deleted) })
                    if ($null -ne $PageSize) { $rows = @($rows | Select-Object -First $PageSize) }
                    $key = if ($script:Fake.EventsKey) { $script:Fake.EventsKey } elseif ((Get-FakeVersion) -lt [version]'2.41') { 'instances' } else { 'events' }
                    return @{ $key = @($rows | ForEach-Object { @{ event = $_.event } }) }
                }
                $segments = $p -split '/'
                if ($segments.Count -eq 2) {
                    $o = Get-FakeObject $segments[0] $segments[1]
                    if (-not $o) { throw "Failed to fetch '$Path' from DHIS2: 404 (Not Found)" }
                    if ($script:Fake.NoList -and (& $script:Fake.NoList ([pscustomobject]@{ Path = $Path; Filter = $Filter; Fields = $Fields }))) { return @{ id = [string]$o['id'] } }
                    return (Copy-Value $o)
                }
                if ($script:Fake.NoList -and (& $script:Fake.NoList ([pscustomobject]@{ Path = $Path; Filter = $Filter; Fields = $Fields }))) { return @{ pager = @{ page = 1; pageCount = 1 } } }
                $all = @((Get-FakeType $p).Values)
                if ($Filter -and $Filter[0] -match '^id:in:\[(.*)\]$') { $ids = $Matches[1] -split ','; $all = @($all | Where-Object { $ids -ccontains [string]$_['id'] }) }
                @{ $p = @($all | ForEach-Object { Copy-Value $_ }) }
            }
            Mock Get-NeoIPCDhis2StatusCode {
                if ($script:Fake.StatusRead) { $code = & $script:Fake.StatusRead ([pscustomobject]@{ Path = $Path }); if ($null -ne $code) { return $code } }
                $segments = ($Path -replace '^api/', '') -split '/'; if (Get-FakeObject $segments[0] $segments[1]) { 200 } else { 404 }
            }
            Mock Invoke-NeoIPCDhis2Post {
                if ($WhatIfPreference) { return }
                if ($script:Fake.ThrowPost -and (& $script:Fake.ThrowPost ([pscustomobject]@{ Path = $Path; Mode = [string]$QueryParameters['importMode'] }))) { throw 'The SSL connection could not be established.' }
                if ($Path -eq 'api/maintenance') { $script:Fake.Requests.Add(@{ Kind = 'cacheClear' }); return [pscustomobject]@{ StatusCode = 200; Body = $null } }
                $payload = $Body | ConvertFrom-Json -AsHashtable -DateKind String
                $mode = [string]$QueryParameters['importMode']
                $script:Fake.Requests.Add(@{ Kind = 'metadata'; Mode = $mode; Payload = $payload })
                $count = 0; foreach ($t in $payload.Keys) { $count += @($payload[$t]).Count }
                if ((Get-FakeMissingReference $payload) -or (Get-FakeDuplicateOption $payload)) { return New-ImportReport 'ERROR' 0 0 409 }
                # A validation stops before DHIS2 flushes anything, so it sees none of the flush failures.
                if ($mode -eq 'VALIDATE') { return New-ImportReport 'OK' 0 $count }
                if ($script:Fake.ThrowImport -and (& $script:Fake.ThrowImport $payload)) { throw 'The SSL connection could not be established.' }
                if ($script:Fake.FailImport -and (& $script:Fake.FailImport $payload)) { return New-ImportReport 'ERROR' 0 0 409 }
                $refused = if ($script:Fake.RefuseImport) { & $script:Fake.RefuseImport $payload }
                if ($refused) { return [pscustomobject]@{ StatusCode = [int]$refused; Body = "<html><body><h1>$refused</h1></body></html>" } }
                $flush = Get-FakeFlushFailure $payload
                if ($flush) { return New-FlushFailure $flush }
                $s = Invoke-FakeImport $payload
                if ($script:Fake.AfterImport) { & $script:Fake.AfterImport $payload }
                New-ImportReport 'OK' $s.created $s.updated
            }
            Mock Invoke-NeoIPCDhis2Put {
                if ($WhatIfPreference) { return }
                $script:Fake.Requests.Add(@{ Kind = 'put'; Path = $Path; Body = $Body })
                $segments = ($Path -replace '^api/', '') -split '/'
                $o = Get-FakeObject $segments[0] $segments[1]
                # The collection endpoint replaces the collection with the items the body lists.
                if ($o) { $o[$segments[2]] = @(@(($Body | ConvertFrom-Json -AsHashtable)['identifiableObjects']) | Where-Object { $_ } | ForEach-Object { @{ id = [string]$_['id'] } }) }
                [pscustomobject]@{ StatusCode = 200; Body = $null }
            }
            Mock Invoke-NeoIPCDhis2Delete {
                if ($WhatIfPreference) { return }
                $segments = ($Path -replace '^api/', '') -split '/'
                $script:Fake.Requests.Add(@{ Kind = 'delete'; Type = $segments[0]; Id = $segments[1] })
                $how = if ($script:Fake.ThrowDelete) { & $script:Fake.ThrowDelete $segments[0] $segments[1] }
                if ($how -eq 'Refuse') { throw [System.Net.Http.HttpRequestException]::new("DELETE $Path failed (HTTP 409): refused", $null, [System.Net.HttpStatusCode]::Conflict) }
                if ($how -eq 'Lose') { throw [System.Net.Http.HttpRequestException]::new('The SSL connection could not be established.') }
                # DHIS2 2.40.12 refuses a rule action's own DELETE.
                if ($segments[0] -eq 'programRuleActions' -and (Get-FakeVersion) -lt [version]'2.41') {
                    throw [System.Net.Http.HttpRequestException]::new("DELETE $Path failed (HTTP 409): deleted object would be re-saved by cascade (remove deleted object from associations)", $null, [System.Net.HttpStatusCode]::Conflict)
                }
                # The 200 that keeps the object: DHIS2 2.41.10 and later on a stage section's DELETE, or what a test asks for.
                if ($script:Fake.DeleteKeeps.Contains("$($segments[0])|$($segments[1])") -or ($segments[0] -eq 'programStageSections' -and (Get-FakeVersion) -ge [version]'2.41')) {
                    return [pscustomobject]@{ httpStatusCode = 200; status = 'OK' }
                }
                $o = Get-FakeObject $segments[0] $segments[1]
                $veto = if ($o) { Get-FakeDeleteVeto $segments[0] $segments[1] $o }
                if ($veto) { throw [System.Net.Http.HttpRequestException]::new("DELETE $Path failed (HTTP 409): Object could not be deleted because it is $veto", $null, [System.Net.HttpStatusCode]::Conflict) }
                if ($o) {
                    $cascade = @{ programRules = 'programRuleActions>programRuleActions'; optionSets = 'options>options'; optionGroups = 'options>options'
                        programStages = 'programStageSections>programStageSections', 'notificationTemplates>programNotificationTemplates' }[$segments[0]]
                    foreach ($c in @($cascade | Where-Object { $_ })) { $prop, $ct = $c -split '>'; foreach ($x in (Get-IdList $o[$prop])) { [void](Get-FakeType $ct).Remove($x) } }
                }
                [void](Get-FakeType $segments[0]).Remove($segments[1])
                [pscustomobject]@{ httpStatusCode = 200; status = 'OK' }
            }
        }

        # ---- a small package ------------------------------------------------------------------------------------
        function New-TestPackage {
            [ordered]@{
                optionSets                   = @([ordered]@{ id = 'osAAAAAAAA1'; code = 'OS1'; name = 'Set'; valueType = 'TEXT'; version = 2
                        options = @([ordered]@{ id = 'opAAAAAAAA1' }, [ordered]@{ id = 'opAAAAAAAA2' }) })
                options                      = @(
                    [ordered]@{ id = 'opAAAAAAAA1'; code = '1'; name = 'One'; sortOrder = 1; optionSet = [ordered]@{ id = 'osAAAAAAAA1' } }
                    [ordered]@{ id = 'opAAAAAAAA2'; code = '2'; name = 'Two'; sortOrder = 2; optionSet = [ordered]@{ id = 'osAAAAAAAA1' } })
                optionGroups                 = @(
                    [ordered]@{ id = 'ogAAAAAAAA1'; code = 'G1'; name = 'G1'; shortName = 'G1'; optionSet = [ordered]@{ id = 'osAAAAAAAA1' }; options = @([ordered]@{ id = 'opAAAAAAAA1' }) }
                    [ordered]@{ id = 'ogAAAAAAAA2'; code = 'G2'; name = 'G2'; shortName = 'G2'; optionSet = [ordered]@{ id = 'osAAAAAAAA1' }; options = @([ordered]@{ id = 'opAAAAAAAA2' }) }
                    [ordered]@{ id = 'ogAAAAAAAA3'; code = 'G3'; name = 'G3'; shortName = 'G3'; optionSet = [ordered]@{ id = 'osAAAAAAAA1' } })
                optionGroupSets              = @(
                    [ordered]@{ id = 'gsAAAAAAAA1'; code = 'GS1'; name = 'GS1'; optionGroups = @([ordered]@{ id = 'ogAAAAAAAA1' }, [ordered]@{ id = 'ogAAAAAAAA2' }) }
                    [ordered]@{ id = 'gsAAAAAAAA2'; code = 'GS2'; name = 'GS2'; optionGroups = @([ordered]@{ id = 'ogAAAAAAAA3' }) })
                dataElements                 = @([ordered]@{ id = 'deAAAAAAAA1'; code = 'DE1'; name = 'Data element'; shortName = 'DE'; valueType = 'TEXT'; domainType = 'TRACKER'; aggregationType = 'NONE' })
                organisationUnitGroups       = @([ordered]@{ id = 'ougAAAAAAA1'; code = 'OUG1'; name = 'Group'; shortName = 'Group'; description = 'Grouped' })
                # The managing group comes first, so on a fresh instance its link to the managed one waits for R2.
                userGroups                   = @(
                    [ordered]@{ id = 'ugAAAAAAAA1'; code = 'UG1'; name = 'Managers'; managedGroups = @([ordered]@{ id = 'ugAAAAAAAA2' }) }
                    [ordered]@{ id = 'ugAAAAAAAA2'; code = 'UG2'; name = 'Managed' })
                programNotificationTemplates = @([ordered]@{ id = 'ntAAAAAAAA1'; name = 'Notice'; messageTemplate = 'Hello'; notificationTrigger = 'PROGRAM_RULE'; notificationRecipient = 'USER_GROUP' })
                programs                     = @([ordered]@{ id = 'prAAAAAAAA1'; code = 'PROG'; name = 'Program'; shortName = 'Program'; programType = 'WITH_REGISTRATION'; version = 5
                        programStages = @([ordered]@{ id = 'psAAAAAAAA1' }) })
                programStages                = @([ordered]@{ id = 'psAAAAAAAA1'; code = 'STG'; name = 'Stage'; program = [ordered]@{ id = 'prAAAAAAAA1' }
                        programStageSections = @([ordered]@{ id = 'ssAAAAAAAA1' }, [ordered]@{ id = 'ssAAAAAAAA2' }) })
                programStageSections         = @(
                    [ordered]@{ id = 'ssAAAAAAAA1'; code = 'SEC1'; name = 'Section one'; sortOrder = 0; programStage = [ordered]@{ id = 'psAAAAAAAA1' }; dataElements = @([ordered]@{ id = 'deAAAAAAAA1' }) }
                    [ordered]@{ id = 'ssAAAAAAAA2'; code = 'SEC2'; name = 'Section two'; sortOrder = 1; programStage = [ordered]@{ id = 'psAAAAAAAA1' } })
                programRules                 = @(
                    [ordered]@{ id = 'ruAAAAAAAA1'; code = 'R1'; name = 'Rule one'; condition = 'true'; program = [ordered]@{ id = 'prAAAAAAAA1' }
                        programRuleActions = @([ordered]@{ id = 'raAAAAAAAA1' }, [ordered]@{ id = 'raAAAAAAAA3' }) }
                    [ordered]@{ id = 'ruAAAAAAAA2'; code = 'R2'; name = 'Rule two'; condition = 'true'; program = [ordered]@{ id = 'prAAAAAAAA1' }
                        programRuleActions = @([ordered]@{ id = 'raAAAAAAAA2' }) })
                programRuleActions           = @(
                    [ordered]@{ id = 'raAAAAAAAA1'; programRuleActionType = 'DISPLAYTEXT'; content = 'Text'; location = 'feedback'; programRule = [ordered]@{ id = 'ruAAAAAAAA1' } }
                    [ordered]@{ id = 'raAAAAAAAA2'; programRuleActionType = 'SENDMESSAGE'; templateUid = 'ntAAAAAAAA1'; programRule = [ordered]@{ id = 'ruAAAAAAAA2' } }
                    [ordered]@{ id = 'raAAAAAAAA3'; programRuleActionType = 'HIDESECTION'; programStageSection = [ordered]@{ id = 'ssAAAAAAAA2' }; programRule = [ordered]@{ id = 'ruAAAAAAAA1' } })
            }
        }
        # A second stage of the program, for children that move between stages.
        function Add-TestStage($Package) {
            $Package['programs'][0]['programStages'] = @(@($Package['programs'][0]['programStages']) + @([ordered]@{ id = 'psAAAAAAAA2' }))
            $Package['programStages'] = @(@($Package['programStages']) + @([ordered]@{ id = 'psAAAAAAAA2'; code = 'STG2'; name = 'Stage two'; program = [ordered]@{ id = 'prAAAAAAAA1' } }))
        }
        function Invoke-TestDeploy($Package, [hashtable]$Extra = @{}) {
            Deploy-NeoIPCMetadata -Json ($Package | ConvertTo-Json -Depth 100 -Compress) -Auth @{ AuthType = 'Basic' } -Hostname 'dhis2.example.org' -Confirm:$false @Extra 6>$null
        }
        # Both return their list as one object (the leading comma), so a single result indexes as a list.
        function Get-CommitRequest { , @($script:Fake.Requests | Where-Object { $_.Kind -eq 'metadata' -and $_.Mode -eq 'COMMIT' }) }
        # The positions, in the request log, of the requests $Where accepts.
        function Get-RequestIndex([scriptblock]$Where) {
            $all = @($script:Fake.Requests)
            , [int[]]@(for ($i = 0; $i -lt $all.Count; $i++) { if (& $Where $all[$i]) { $i } })
        }
        # The object of a type and id that a metadata request carries, or nothing.
        function Get-PayloadObject($Request, [string]$Type, [string]$Id) {
            if ($Request.Kind -ne 'metadata' -or -not $Request.Payload.Contains($Type)) { return }
            @($Request.Payload[$Type]) | Where-Object { $_ -is [System.Collections.IDictionary] -and [string]$_['id'] -ceq $Id } | Select-Object -First 1
        }
    }

    Describe 'ConvertTo-NeoIPCDhis2Version' {
        It 'parses <Text> as <Expected>' -ForEach @(
            @{ Text = '2.41.10'; Expected = '2.41.10' }
            @{ Text = '2.42.6.1'; Expected = '2.42.6.1' }
            @{ Text = '2.43-SNAPSHOT'; Expected = '2.43.0' }
        ) { (ConvertTo-NeoIPCDhis2Version -Text $Text) | Should -Be ([version]$Expected) }
        It 'refuses text without major.minor, so a misread version never selects a branch' {
            { ConvertTo-NeoIPCDhis2Version -Text 'unknown' } | Should -Throw '*Unparsable*'
        }
    }

    Describe 'Test-NeoIPCDeployVerifiedVersion (the releases the deployment was verified on, and later patches)' {
        It 'counts <Text> as verified: <Verified>' -ForEach @(
            @{ Text = '2.40.12'; Verified = $true }
            @{ Text = '2.41.10'; Verified = $true }
            @{ Text = '2.41.11'; Verified = $true }
            @{ Text = '2.42.6.1'; Verified = $true }
            @{ Text = '2.43.1'; Verified = $true }
            @{ Text = '2.40.11'; Verified = $false }
            @{ Text = '2.41.9'; Verified = $false }
            @{ Text = '2.43-SNAPSHOT'; Verified = $false }
            @{ Text = '2.43.1-SNAPSHOT'; Verified = $false }
            @{ Text = '2.43.1-RC1'; Verified = $false }
            @{ Text = '2.43.2-SNAPSHOT'; Verified = $false }
            @{ Text = '2.39.6'; Verified = $false }
            @{ Text = '2.44.0'; Verified = $false }
        ) { (Test-NeoIPCDeployVerifiedVersion -Text $Text) | Should -Be $Verified }
    }

    Describe 'Compare-NeoIPCDeployObject (what DHIS2 holds as the package states compares equal)' {
        It 'applies DHIS2''s normalizations: dates, derived and unstored fields, renumbered sortOrder, managed versions, added nested keys' {
            $v = [version]'2.41.10'
            (Compare-NeoIPCDeployObject -Type 'organisationUnits' -Version $v -PackageObject ([ordered]@{ id = 'ou1'; name = 'U'; openingDate = '2023-01-01' }) `
                -Live ([ordered]@{ id = 'ou1'; name = 'U'; openingDate = '2023-01-01T00:00:00.000' })).Count | Should -Be 0
            (Compare-NeoIPCDeployObject -Type 'options' -Version $v -PackageObject ([ordered]@{ id = 'o1'; code = '1'; name = 'A'; sortOrder = 1 }) `
                -Live ([ordered]@{ id = 'o1'; code = '1'; name = 'A'; sortOrder = 0 })).Count | Should -Be 0
            (Compare-NeoIPCDeployObject -Type 'optionSets' -Version $v -PackageObject ([ordered]@{ id = 's1'; name = 'S'; version = 2 }) `
                -Live ([ordered]@{ id = 's1'; name = 'S'; version = 7 })).Count | Should -Be 0
            # NEOIPC-COMPAT(dhis2-pre-2.42-tracked-entity-type-shortname): see Private/MetadataDeploy.ps1.
            (Compare-NeoIPCDeployObject -Type 'trackedEntityTypes' -Version $v -PackageObject ([ordered]@{ id = 't1'; name = 'T'; shortName = 'T' }) `
                -Live ([ordered]@{ id = 't1'; name = 'T' })).Count | Should -Be 0 -Because 'DHIS2 does not store the shortName before 2.42'
            (Compare-NeoIPCDeployObject -Type 'trackedEntityTypes' -Version ([version]'2.42.6') -PackageObject ([ordered]@{ id = 't1'; name = 'T'; shortName = 'T' }) `
                -Live ([ordered]@{ id = 't1'; name = 'T' })) | Should -Be @('shortName')
            (Compare-NeoIPCDeployObject -Type 'validationRules' -Version $v -PackageObject ([ordered]@{ id = 'v1'; name = 'V'; leftSide = [ordered]@{ expression = 'I{a}'; slidingWindow = $false } }) `
                -Live ([ordered]@{ id = 'v1'; name = 'V'; leftSide = [ordered]@{ expression = 'I{a}'; slidingWindow = $false; translations = $null } })).Count | Should -Be 0
            $p = [ordered]@{ id = 'p1'; name = 'P'; programTrackedEntityAttributes = @([ordered]@{ id = 'a1'; name = 'Derived'; valueType = 'TEXT'; mandatory = $true; program = [ordered]@{ id = 'p1' } }) }
            $l = [ordered]@{ id = 'p1'; name = 'P'; programTrackedEntityAttributes = @([ordered]@{ id = 'a1'; mandatory = $true }) }
            (Compare-NeoIPCDeployObject -Type 'programs' -Version $v -PackageObject $p -Live $l).Count | Should -Be 0
        }
        It 'compares an option set''s list in order, and an unordered collection as a set' {
            $v = [version]'2.41.10'
            (Compare-NeoIPCDeployObject -Type 'optionSets' -Version $v -PackageObject ([ordered]@{ id = 's1'; options = @(@{ id = 'a' }, @{ id = 'b' }) }) `
                -Live ([ordered]@{ id = 's1'; options = @(@{ id = 'b' }, @{ id = 'a' }) })) | Should -Be @('options')
            (Compare-NeoIPCDeployObject -Type 'programs' -Version $v -PackageObject ([ordered]@{ id = 'p1'; programStages = @(@{ id = 'a' }, @{ id = 'b' }) }) `
                -Live ([ordered]@{ id = 'p1'; programStages = @(@{ id = 'b' }, @{ id = 'a' }) })).Count | Should -Be 0
        }
        It 'compares two children whose ids differ only in case apart (a change in <Changed>)' -ForEach @(
            @{ Changed = 'PSDECASE001' }
            @{ Changed = 'psdeCASE001' }
        ) {
            $kid = { param([string]$Id, [bool]$Compulsory) [ordered]@{ id = $Id; compulsory = $Compulsory; programStage = [ordered]@{ id = 'ps1' }; dataElement = [ordered]@{ id = "de$Id" } } }
            $pkg = [ordered]@{ id = 'ps1'; name = 'S'; programStageDataElements = @((& $kid 'PSDECASE001' ($Changed -ceq 'PSDECASE001')), (& $kid 'psdeCASE001' ($Changed -ceq 'psdeCASE001'))) }
            $live = [ordered]@{ id = 'ps1'; name = 'S'; programStageDataElements = @((& $kid 'PSDECASE001' $false), (& $kid 'psdeCASE001' $false)) }
            (Compare-NeoIPCDeployObject -Type 'programStages' -Version ([version]'2.41.10') -PackageObject $pkg -Live $live) | Should -Be @('programStageDataElements')
        }
        It 'reports a translation the package carries but DHIS2 lacks, and not one only DHIS2 carries' {
            $v = [version]'2.41.10'
            $pkg = [ordered]@{ id = 'd1'; name = 'D'; translations = @([ordered]@{ locale = 'de'; property = 'NAME'; value = 'D (de)' }) }
            (Compare-NeoIPCDeployObject -Type 'dataElements' -Version $v -PackageObject $pkg -Live ([ordered]@{ id = 'd1'; name = 'D' })) | Should -Be @('translations')
            (Compare-NeoIPCDeployObject -Type 'dataElements' -Version $v -PackageObject ([ordered]@{ id = 'd1'; name = 'D' }) `
                -Live ([ordered]@{ id = 'd1'; name = 'D'; translations = @([ordered]@{ locale = 'fr'; property = 'NAME'; value = 'D (fr)' }) })).Count | Should -Be 0
        }
        It 'compares sharing by public and grants, ignoring the owner and external flag DHIS2 fills' {
            $v = [version]'2.41.10'
            $pkg = [ordered]@{ id = 'd1'; name = 'D'; sharing = [ordered]@{ public = 'r-------' } }
            (Compare-NeoIPCDeployObject -Type 'dataElements' -Version $v -PackageObject $pkg `
                -Live ([ordered]@{ id = 'd1'; name = 'D'; sharing = [ordered]@{ public = 'r-------'; owner = 'u1'; external = $false; users = @{}; userGroups = @{} } })).Count | Should -Be 0
            (Compare-NeoIPCDeployObject -Type 'dataElements' -Version $v -PackageObject $pkg `
                -Live ([ordered]@{ id = 'd1'; name = 'D'; sharing = [ordered]@{ public = 'rw------' } })) | Should -Be @('sharing')
        }
    }

    Describe 'New-NeoIPCDeployBody (the package governs; the instance keeps its own)' {
        It 'copies the instance''s properties, clears what the package leaves out, keeps created verbatim, and drops the translations of a changed value' {
            $pkg = [ordered]@{ id = 'g1'; code = 'G'; name = 'New name'; translations = @([ordered]@{ locale = 'fr'; property = 'NAME'; value = 'Nom' }) }
            $live = [ordered]@{ id = 'g1'; code = 'G'; name = 'Old name'; description = 'Live only'; created = '2024-01-02T03:04:05.678'
                organisationUnits = @([ordered]@{ id = 'ou1' }); attributeValues = @([ordered]@{ value = 'x'; attribute = [ordered]@{ id = 'at1' } })
                translations = @([ordered]@{ locale = 'de'; property = 'NAME'; value = 'Alter Name' }, [ordered]@{ locale = 'de'; property = 'SHORT_NAME'; value = 'Kurz' }) }
            $made = New-NeoIPCDeployBody -Type 'organisationUnitGroups' -PackageObject $pkg -Live $live -CopyOwned $script:NeoIPCDeployOwnedProperties -ChangedProperties 'name'
            $made.Body['created'] | Should -BeExactly '2024-01-02T03:04:05.678'
            @($made.Body['organisationUnits'] | ForEach-Object { $_['id'] }) | Should -Be @('ou1')
            @($made.Body['attributeValues']).Count | Should -Be 1
            $made.Body.Contains('description') | Should -BeFalse -Because 'a type-map property the package leaves out is cleared'
            @($made.Body['translations'] | ForEach-Object { "$($_['locale'])/$($_['property'])" } | Sort-Object) | Should -Be @('de/SHORT_NAME', 'fr/NAME')
            @($made.DroppedTranslations).Count | Should -Be 1
            $made.DroppedTranslations[0].Locale | Should -Be 'de'
        }
        It 'keeps the live sharing of a shareable object only when the package gives it none' {
            $live = [ordered]@{ id = 'g1'; name = 'G'; sharing = [ordered]@{ owner = 'us1'; public = 'r-------'; userGroups = [ordered]@{ ug1 = [ordered]@{ id = 'ug1'; access = 'rw------' } } } }
            $kept = New-NeoIPCDeployBody -Type 'optionSets' -PackageObject ([ordered]@{ id = 'g1'; name = 'G' }) -Live $live -Shareable
            $kept.SharingKept | Should -BeTrue
            $kept.Body['sharing']['owner'] | Should -Be 'us1'
            $kept.Body['sharing']['userGroups']['ug1']['access'] | Should -Be 'rw------'
            $stated = New-NeoIPCDeployBody -Type 'optionSets' -PackageObject ([ordered]@{ id = 'g1'; name = 'G'; sharing = [ordered]@{ public = 'rw------' } }) -Live $live -Shareable
            $stated.SharingKept | Should -BeFalse
            $stated.Body['sharing'].Contains('userGroups') | Should -BeFalse -Because 'the package governs the sharing it states'
            $plain = New-NeoIPCDeployBody -Type 'programRules' -PackageObject ([ordered]@{ id = 'g1'; name = 'G' }) -Live $live
            $plain.Body.Contains('sharing') | Should -BeFalse -Because 'an object of a type without sharing has none to keep'
        }
        It 'refuses to keep live sharing without a public access string, which DHIS2 reads as open and resets on any write' {
            $live = [ordered]@{ id = 'g1'; name = 'G'; sharing = [ordered]@{ owner = 'us1'; userGroups = [ordered]@{ ug1 = [ordered]@{ id = 'ug1'; access = 'rw------' } } } }
            { New-NeoIPCDeployBody -Type 'optionSets' -PackageObject ([ordered]@{ id = 'g1'; name = 'G' }) -Live $live -Shareable } |
                Should -Throw '*optionSets g1 holds sharing without a public access string*give it sharing in the package*'
        }
    }

    Describe 'Get-NeoIPCDeploySharingLoss (what writing the package''s sharing takes away)' {
        BeforeAll {
            # Parsed from JSON, as the instance's answer and the package are: a hashtable literal folds keys that differ
            # only in case.
            function Get-Loss([string]$Live, [string]$Package, [switch]$DataShareable) {
                $l = Convert-NeoIPCSharing ($Live | ConvertFrom-Json -AsHashtable)
                $p = Convert-NeoIPCSharing ($Package | ConvertFrom-Json -AsHashtable)
                $loss = Get-NeoIPCDeploySharingLoss -Live $l -Package $p -DataShareable:$DataShareable
                , $loss
            }
        }
        It 'reports <Case>' -ForEach @(
            @{ Case = 'a narrowed public access string'; Live = '{"public":"rw------"}'; Package = '{"public":"r-------"}'
                Expected = 'public access loses metadata write (rw------ to r-------)' }
            @{ Case = 'a user-group grant the package leaves out'; Live = '{"public":"r-------","userGroups":{"ugAAAAAAAA1":{"id":"ugAAAAAAAA1","access":"rw------"}}}'
                Package = '{"public":"r-------"}'; Expected = 'user group ugAAAAAAAA1 loses metadata read, metadata write (rw------ to no grant)' }
            @{ Case = 'a narrowed user grant'; Live = '{"public":"--------","users":{"usAAAAAAAA1":{"id":"usAAAAAAAA1","access":"rw------"}}}'
                Package = '{"public":"--------","users":{"usAAAAAAAA1":{"id":"usAAAAAAAA1","access":"r-------"}}}'; Expected = 'user usAAAAAAAA1 loses metadata write (rw------ to r-------)' }
            @{ Case = 'a missing public access string, which grants every permission'; Live = '{"owner":"usAAAAAAAA1"}'; Package = '{"public":"r-------"}'
                Expected = 'public access loses metadata write (no access string to r-------)' }
            @{ Case = 'the grant of one of two user groups whose ids differ only in case'
                Live = '{"public":"--------","userGroups":{"ugCASE00001":{"id":"ugCASE00001","access":"r-------"},"UGCASE00001":{"id":"UGCASE00001","access":"r-------"}}}'
                Package = '{"public":"--------","userGroups":{"ugCASE00001":{"id":"ugCASE00001","access":"r-------"}}}'; Expected = 'user group UGCASE00001 loses metadata read (r------- to no grant)' }
        ) {
            (Get-Loss $Live $Package) -join '|' | Should -BeExactly $Expected
        }
        It 'counts the data permissions only for a type that shares data' {
            (Get-Loss '{"public":"rwrw----"}' '{"public":"rw------"}' -DataShareable) -join '|' | Should -BeExactly 'public access loses data read, data write (rwrw---- to rw------)'
            (Get-Loss '{"public":"rwrw----"}' '{"public":"rw------"}').Count | Should -Be 0
            (Get-Loss '{"public":"--------","users":{"usAAAAAAAA1":{"id":"usAAAAAAAA1"}}}' '{"public":"--------","users":{"usAAAAAAAA1":{"id":"usAAAAAAAA1","access":"rwr-----"}}}' -DataShareable) -join '|' |
                Should -BeExactly 'user usAAAAAAAA1 loses data write (no access string to rwr-----)'
        }
        It 'reports nothing for sharing the package widens or keeps, nor for an access string DHIS2 does not accept' {
            (Get-Loss '{"public":"r-------","userGroups":{"ugAAAAAAAA1":{"id":"ugAAAAAAAA1","access":"r-------"}}}' `
                    '{"public":"rw------","userGroups":{"ugAAAAAAAA1":{"id":"ugAAAAAAAA1","access":"rw------"},"ugAAAAAAAA2":{"id":"ugAAAAAAAA2","access":"r-------"}}}').Count | Should -Be 0
            (Get-Loss '{"public":"rwx-----"}' '{"public":"--------"}').Count | Should -Be 0 -Because 'DHIS2 grants nothing for an access string it does not accept'
        }
    }

    Describe 'Live reads (a 200 without the list asked for is a failed read)' {
        It 'refuses a list read whose response has no list, or a null one, under the type''s key (<Case>)' -ForEach @(
            @{ Case = 'no key'; Response = @{ pager = @{ page = 1 } } }
            @{ Case = 'a null value'; Response = @{ mapViews = $null } }
        ) {
            $script:LiveAnswer = $Response
            Mock Invoke-NeoIPCDhis2Get { $script:LiveAnswer }
            { Get-NeoIPCMetadataLiveList -Endpoint @{ Auth = @{} } -Type 'mapViews' -Field 'id' } | Should -Throw "*held no 'mapViews' collection*"
        }
        It 'reports a batched read whose response has no list, or a null one, as failed, not as every object absent (<Case>)' -ForEach @(
            @{ Case = 'no key'; Response = @{ pager = @{ page = 1 } } }
            @{ Case = 'a null value'; Response = @{ optionSets = $null } }
        ) {
            $script:LiveAnswer = $Response
            Mock Invoke-NeoIPCDhis2Get { $script:LiveAnswer }
            $read = Get-NeoIPCMetadataLiveObject -Endpoint @{ Auth = @{} } -Type 'optionSets' -Id 'osAAAAAAAA1'
            $read.Failure | Should -BeLike "*did not contain a 'optionSets' collection*"
            $read.ById.Count | Should -Be 0
        }
        It 'refuses a schema read whose response has no schemas list, or a null one (<Case>)' -ForEach @(
            @{ Case = 'no key'; Response = @{ pager = @{ page = 1 } } }
            @{ Case = 'a null value'; Response = @{ schemas = $null } }
        ) {
            $script:LiveAnswer = $Response
            Mock Invoke-NeoIPCDhis2Get { $script:LiveAnswer }
            { Get-NeoIPCMetadataSchemaIndex -Endpoint @{ Auth = @{} } } | Should -Throw "*did not return a 'schemas' collection*"
        }
        It 'refuses a schema read that carries no <Flag> flag, which would read every type as one without that sharing' -ForEach @(
            @{ Flag = 'shareable'; Present = @{ dataShareable = $false } }
            @{ Flag = 'dataShareable'; Present = @{ shareable = $true } }
        ) {
            $schema = @{ name = 'optionSet'; plural = 'optionSets'; klass = 'org.hisp.dhis.option.OptionSet'; order = 1050; properties = @() } + $Present
            $script:LiveAnswer = @{ schemas = @($schema) }
            Mock Invoke-NeoIPCDhis2Get { $script:LiveAnswer }
            { Get-NeoIPCMetadataSchemaIndex -Endpoint @{ Auth = @{} } } | Should -Throw "*'$Flag' flag of 'optionSets'*"
        }
    }

    Describe 'Get-NeoIPCDeployDeferral (links DHIS2 drops in a create request)' {
        It 'defers exactly the option-group-set links in the play package' {
            # The real play package, all of it new: the set that must wait for R2 is pinned here, so a change to the
            # package or to the rule that widens it (deferring every rule action's programRule, which DHIS2 would
            # reject) fails this test. Its managing user group comes after the groups it manages, so by array
            # position those links land in R1.
            $metadata = Join-Path $PSScriptRoot '..' '..' '..' '..' 'metadata'
            $pkg = (New-NeoIPCMetadataPackage -MetadataDirectory $metadata -Play -WarningAction SilentlyContinue) | ConvertFrom-Json -AsHashtable -DateKind String
            $write = [ordered]@{}; $new = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
            foreach ($t in @($pkg.Keys)) {
                $objs = @(@($pkg[$t]) | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['id'] })
                if ($objs.Count -eq 0) { continue }
                $write[$t] = $objs
                foreach ($o in $objs) { [void]$new.Add("$t|$($o['id'])") }
            }
            $deferral = Get-NeoIPCDeployDeferral -Write $write -New $new -Schema (New-SchemaIndexFixture)
            $pairs = @(foreach ($key in $deferral.Keys) { foreach ($prop in $deferral[$key].Keys) { "$(($key -split '\|')[0]).$prop" } }) | Sort-Object -Unique
            $pairs | Should -Be @('optionGroupSets.optionGroups')
        }
        It 'defers a reference to a later-committing new target without an inverse, and not one whose target lists the referrer' {
            $write = [ordered]@{
                programStageSections = @([ordered]@{ id = 'ss1'; programStage = @{ id = 'ps1' }; programIndicators = @(@{ id = 'pi1' }) })
                programStages        = @([ordered]@{ id = 'ps1'; programStageSections = @(@{ id = 'ss1' }) })
                programIndicators    = @([ordered]@{ id = 'pi1' })
            }
            $new = [System.Collections.Generic.HashSet[string]]::new([string[]]@('programStageSections|ss1', 'programStages|ps1', 'programIndicators|pi1'), [System.StringComparer]::Ordinal)
            $deferral = Get-NeoIPCDeployDeferral -Write $write -New $new -Schema (New-SchemaIndexFixture)
            @($deferral.Keys) | Should -Be @('programStageSections|ss1')
            @($deferral['programStageSections|ss1'].Keys) | Should -Be @('programIndicators')
        }
    }

    Describe 'Get-NeoIPCDeployGroupSetPlan (unique group membership, in-place list rewrites)' {
        BeforeAll {
            function New-LiveListMap([hashtable]$Map) { $d = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal); foreach ($k in $Map.Keys) { $d[$k] = [string[]]$Map[$k] }; , $d }
            function New-Set([string]$Id, [string[]]$Groups) { [ordered]@{ id = $Id; optionGroups = @($Groups | ForEach-Object { @{ id = $_ } }) } }
            $script:NoNew = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        }
        It 'resets a swap, an interior or tail removal, and a set that loses a group to another; the gaining set waits for R2' {
            $plan = (Get-NeoIPCDeployGroupSetPlan -PackageSets @((New-Set 's1' 'b', 'a', 'c'), (New-Set 's2' 'x'), (New-Set 's3' 'y'), (New-Set 's4' 'p', 'r', 's')) `
                    -LiveLists (New-LiveListMap @{ s1 = @('a', 'b', 'c'); s2 = @('x', 'z'); s3 = @('y'); s4 = @('p', 'q', 'r', 's') }) -NewGroups $script:NoNew).Plan
            $plan['s1'].Category | Should -Be 'Reset'
            $plan['s2'].Category | Should -Be 'Reset' -Because 'a removal is no append'
            $plan['s3'].Category | Should -Be 'Same'
            $plan['s4'].Category | Should -Be 'Reset' -Because 'an interior removal shifts the later groups onto rows that still hold them'
            $move = (Get-NeoIPCDeployGroupSetPlan -PackageSets @((New-Set 's1' 'a'), (New-Set 's2' 'x', 'b')) `
                    -LiveLists (New-LiveListMap @{ s1 = @('a', 'b'); s2 = @('x') }) -NewGroups $script:NoNew).Plan
            $move['s1'].Category | Should -Be 'Reset'
            $move['s2'].Category | Should -Be 'Defer' -Because 'in R1 the group still belongs to its old set'
            @($move['s2'].R1) | Should -Be @('x')
            @($move['s2'].R2) | Should -Be @('x', 'b')
        }
        It 'writes a plain append of free groups directly, and defers one of new groups' {
            $new = [System.Collections.Generic.HashSet[string]]::new([string[]]@('n'), [System.StringComparer]::Ordinal)
            $plan = (Get-NeoIPCDeployGroupSetPlan -PackageSets @((New-Set 's1' 'a', 'free'), (New-Set 's2' 'x', 'n')) -LiveLists (New-LiveListMap @{ s1 = @('a'); s2 = @('x') }) -NewGroups $new).Plan
            $plan['s1'].Category | Should -Be 'Direct'
            $plan['s2'].Category | Should -Be 'Defer'
        }
        It 'refuses a group the package lists in two sets, or takes from a live set the package does not carry' {
            (Get-NeoIPCDeployGroupSetPlan -PackageSets @((New-Set 's1' 'a'), (New-Set 's2' 'a')) -LiveLists (New-LiveListMap @{}) -NewGroups $script:NoNew).Errors.Count | Should -Be 1
            (Get-NeoIPCDeployGroupSetPlan -PackageSets @((New-Set 's1' 'a', 'b')) -LiveLists (New-LiveListMap @{ s1 = @('a'); other = @('b') }) -NewGroups $script:NoNew).Errors.Count | Should -Be 1
        }
    }

    Describe 'Get-NeoIPCDeployDeleteOrder (whatever refers goes first)' {
        It 'puts each type before the types it refers to, through itself or what DHIS2 deletes with it, and otherwise follows descending schema order' {
            $order = Get-NeoIPCDeployDeleteOrder -Schema (New-SchemaIndexFixture) -Type @('optionSets', 'attributes', 'optionGroups', 'optionGroupSets', 'dataElements',
                'trackedEntityAttributes', 'programStages', 'programRules', 'programRuleVariables', 'programIndicators')
            $order | Should -HaveCount 10
            $before = { param([string]$A, [string]$B) [array]::IndexOf($order, $A) -lt [array]::IndexOf($order, $B) }
            & $before 'attributes' 'optionSets' | Should -BeTrue -Because 'an attribute uses its option set, although attributes commit first'
            & $before 'optionGroupSets' 'optionGroups' | Should -BeTrue -Because 'a group set lists its groups, which commit at the same order'
            & $before 'optionGroups' 'optionSets' | Should -BeTrue
            & $before 'dataElements' 'optionSets' | Should -BeTrue
            & $before 'trackedEntityAttributes' 'optionSets' | Should -BeTrue
            & $before 'programRules' 'programStages' | Should -BeTrue -Because 'a rule refers to its stage'
            & $before 'programRules' 'programIndicators' | Should -BeTrue
            & $before 'programRuleVariables' 'programStages' | Should -BeTrue
            & $before 'programIndicators' 'programStages' | Should -BeTrue -Because 'unrelated types follow descending schema order (1560, then 1509)'
        }

        It 'puts a rule before an option set when only what goes with each relates them, against the schema order' {
            # No rule refers to an option set; one of its actions, which goes with it, targets an option, which goes with
            # its set. With the rules' schema order below the sets', only that relation puts the rules first.
            $schema = New-SchemaIndexFixture
            $schema.ByPlural['programRules'].Order = 1000
            $order = Get-NeoIPCDeployDeleteOrder -Schema $schema -Type @('optionSets', 'programRules')
            $order | Should -Be @('programRules', 'optionSets')
        }
    }

    Describe 'Deploy-NeoIPCMetadata (against an in-memory DHIS2)' {
        BeforeEach { Reset-FakeDhis2; Set-FakeMock }

        It 'requires the host to be named (no default target)' {
            $hostParam = (Get-Command Deploy-NeoIPCMetadata).Parameters['Hostname']
            @($hostParam.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory }).Count | Should -Be 1
        }

        It 'creates a package on a fresh instance, linking in R2 what DHIS2 would drop in R1' {
            $r = Invoke-TestDeploy (New-TestPackage)
            $r.Succeeded | Should -BeTrue
            $commits = Get-CommitRequest
            $commits.Count | Should -Be 2
            $r1 = $commits[0].Payload
            @($r1['optionGroupSets'] | ForEach-Object { @($_['optionGroups']).Count }) | Should -Be @(0, 0) -Because 'a new set is created empty'
            @(@($r1['userGroups'])[0]['managedGroups']).Count | Should -Be 0 -Because 'the managed group comes later in the array'
            $r2 = $commits[1].Payload
            @(@($r2['optionGroupSets'])[0]['optionGroups'] | ForEach-Object { $_['id'] }) | Should -Be @('ogAAAAAAAA1', 'ogAAAAAAAA2')
            @(@($r2['userGroups'])[0]['managedGroups'] | ForEach-Object { $_['id'] }) | Should -Be @('ugAAAAAAAA2')
            $r2.Contains('programRuleActions') | Should -BeFalse -Because 'the rules list their actions, which links them in R1'
            $r2.Contains('programStageSections') | Should -BeFalse -Because 'the stage lists its sections'
        }

        It 'writes nothing and moves no version when the instance already matches' {
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            $r = Invoke-TestDeploy $pkg
            $r.Succeeded | Should -BeTrue
            (Get-CommitRequest).Count | Should -Be 0
            $r.Written.Count | Should -Be 0
            (Get-FakeObject 'programs' 'prAAAAAAAA1')['version'] | Should -Be 5
            (Get-FakeObject 'optionSets' 'osAAAAAAAA1')['version'] | Should -Be 2
        }

        It 'writes an option set whose order differs and a data element whose translation is missing, and bumps the program last' {
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            (Get-FakeObject 'optionSets' 'osAAAAAAAA1')['options'] = @(@{ id = 'opAAAAAAAA2' }, @{ id = 'opAAAAAAAA1' })
            $pkg['dataElements'][0]['translations'] = @([ordered]@{ locale = 'de'; property = 'NAME'; value = 'Datenelement' })
            $r = Invoke-TestDeploy $pkg
            $r.Succeeded | Should -BeTrue
            $commits = Get-CommitRequest
            $commits.Count | Should -Be 2
            @($commits[0].Payload.Keys) | Should -Be @('optionSets', 'dataElements')
            @($commits[1].Payload.Keys) | Should -Be @('programs') -Because 'the program is written once, last, carrying its live version'
            (Get-FakeObject 'optionSets' 'osAAAAAAAA1')['version'] | Should -Be 3
            (Get-FakeObject 'programs' 'prAAAAAAAA1')['version'] | Should -Be 6
        }

        It 'writes a changed program once, in the last request, so its version moves after everything clients load with it' {
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            $pkg['programs'][0]['name'] = 'Program renamed'
            $pkg['dataElements'][0]['name'] = 'Changed'
            $r = Invoke-TestDeploy $pkg
            $r.Succeeded | Should -BeTrue
            $carrying = Get-RequestIndex { param($q) $q.Mode -eq 'COMMIT' -and (Get-PayloadObject $q 'programs' 'prAAAAAAAA1') }
            $carrying.Count | Should -Be 1
            $carrying[0] | Should -Be (Get-RequestIndex { param($q) $q.Mode -eq 'COMMIT' })[-1]
            (Get-FakeObject 'programs' 'prAAAAAAAA1')['name'] | Should -Be 'Program renamed'
            (Get-FakeObject 'programs' 'prAAAAAAAA1')['version'] | Should -Be 6
        }

        It 'keeps what belongs to the instance in production mode, and lets the package govern carried memberships when synthetic' {
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            $live = Get-FakeObject 'organisationUnitGroups' 'ougAAAAAAA1'
            $live['organisationUnits'] = @(@{ id = 'ou1' }, @{ id = 'ou2' }); $live['created'] = '2024-01-02T03:04:05.678'
            $pkg['organisationUnitGroups'][0]['name'] = 'Renamed'
            $pkg['organisationUnitGroups'][0].Remove('description')
            $r = Invoke-TestDeploy $pkg
            $r.Succeeded | Should -BeTrue
            $body = @((Get-CommitRequest)[0].Payload['organisationUnitGroups'])[0]
            @($body['organisationUnits'] | ForEach-Object { $_['id'] }) | Should -Be @('ou1', 'ou2')
            $body['created'] | Should -BeExactly '2024-01-02T03:04:05.678'
            $body.Contains('description') | Should -BeFalse
            Reset-FakeDhis2
            $syn = New-TestPackage
            Set-FakeFromPackage $syn
            (Get-FakeObject 'organisationUnitGroups' 'ougAAAAAAA1')['organisationUnits'] = @(@{ id = 'ou1' }, @{ id = 'ou2' })
            $syn['organisationUnitGroups'][0]['organisationUnits'] = @([ordered]@{ id = 'ou1' })
            $r = Invoke-TestDeploy $syn @{ SyntheticInstance = $true }
            $r.Succeeded | Should -BeTrue
            @((Get-FakeObject 'organisationUnitGroups' 'ougAAAAAAA1')['organisationUnits'] | ForEach-Object { $_['id'] }) | Should -Be @('ou1')
        }

        It 'keeps the sharing of a shareable object the package gives none, which DHIS2 would otherwise reset' {
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            foreach ($o in (Get-FakeObject 'optionSets' 'osAAAAAAAA1'), (Get-FakeObject 'programs' 'prAAAAAAAA1')) {
                $o['sharing'] = @{ owner = 'usOWNER0001'; public = 'r-------'; users = @{}; userGroups = @{ ugAAAAAAAA1 = @{ id = 'ugAAAAAAAA1'; access = 'rw------' } } }
            }
            # The set changes; the program, unchanged, is written last only to move its version.
            $pkg['optionSets'][0]['name'] = 'Renamed set'
            $r = Invoke-TestDeploy $pkg
            $r.Succeeded | Should -BeTrue
            (Get-FakeObject 'programs' 'prAAAAAAAA1')['version'] | Should -Be 6
            foreach ($key in 'optionSets|osAAAAAAAA1', 'programs|prAAAAAAAA1') {
                $t, $id = $key -split '\|'
                $stored = (Get-FakeObject $t $id)['sharing']
                $stored['owner'] | Should -Be 'usOWNER0001'
                $stored['public'] | Should -Be 'r-------'
                @($stored['userGroups'].Keys) | Should -Be @('ugAAAAAAAA1') -Because "the $t write keeps the grant"
            }
            @($r.Kept | Where-Object { $_.Type -eq 'optionSets' -and $_.Property -eq 'sharing' })[0].Objects | Should -Be 1
        }

        It 'refuses before any write sharing the package gives without a public access string, which DHIS2 resets grants and all' {
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            $pkg['optionSets'][0]['sharing'] = [ordered]@{ userGroups = [ordered]@{ ugAAAAAAAA1 = [ordered]@{ id = 'ugAAAAAAAA1'; access = 'rw------' } } }
            { Invoke-TestDeploy $pkg } | Should -Throw '*resets the sharing of an object whose sharing has no public access string*optionSets osAAAAAAAA1*'
            (Get-CommitRequest).Count | Should -Be 0
        }

        It 'refuses before any write to keep live sharing that has no public access string' {
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            (Get-FakeObject 'optionSets' 'osAAAAAAAA1')['sharing'] = @{ owner = 'usOWNER0001'; users = @{}; userGroups = @{ ugAAAAAAAA1 = @{ id = 'ugAAAAAAAA1'; access = 'rw------' } } }
            $pkg['optionSets'][0]['name'] = 'Renamed set'
            { Invoke-TestDeploy $pkg } | Should -Throw '*optionSets osAAAAAAAA1 holds sharing without a public access string*'
            (Get-CommitRequest).Count | Should -Be 0
        }

        It 'writes a changed notification action on <Version>: in R1 before 2.42, from 2.42 deleted and re-created after R2' -ForEach @(
            @{ Version = '2.41.10'; OwnStep = $false }
            @{ Version = '2.42.6'; OwnStep = $true }
        ) {
            $script:Fake.Version = $Version
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            $pkg['programRuleActions'][1]['content'] = 'Changed'
            # A new group in a new set gives the run an R2 to order the action's own step against.
            $pkg['optionGroups'] += [ordered]@{ id = 'ogAAAAAAAA4'; code = 'G4'; name = 'G4'; shortName = 'G4'; optionSet = [ordered]@{ id = 'osAAAAAAAA1' }; options = @([ordered]@{ id = 'opAAAAAAAA1' }) }
            $pkg['optionGroupSets'] += [ordered]@{ id = 'gsAAAAAAAA3'; code = 'GS3'; name = 'GS3'; optionGroups = @([ordered]@{ id = 'ogAAAAAAAA4' }) }
            $r = Invoke-TestDeploy $pkg
            $r.Succeeded | Should -BeTrue
            $carrying = Get-RequestIndex { param($q) $q.Mode -eq 'COMMIT' -and (Get-PayloadObject $q 'programRuleActions' 'raAAAAAAAA2') }
            $r2 = Get-RequestIndex { param($q) $set = Get-PayloadObject $q 'optionGroupSets' 'gsAAAAAAAA3'; $q.Mode -eq 'COMMIT' -and $set -and @($set['optionGroups']).Count -gt 0 }
            $deletes = Get-RequestIndex { param($q) $q.Kind -eq 'delete' -and $q.Id -eq 'raAAAAAAAA2' }
            $carrying.Count | Should -Be 1
            $r2.Count | Should -Be 1
            if ($OwnStep) {
                $deletes.Count | Should -Be 1 -Because 'from 2.42 any update of such an action fails, so it is deleted and re-created'
                $deletes[0] | Should -BeGreaterThan $r2[0] -Because 'the step runs after R2'
                $carrying[0] | Should -BeGreaterThan $deletes[0]
            }
            else {
                $deletes.Count | Should -Be 0
                $carrying[0] | Should -BeLessThan $r2[0] -Because 'R1 carries it'
            }
            (Get-FakeObject 'programRuleActions' 'raAAAAAAAA2')['content'] | Should -Be 'Changed'
        }

        It 'restores a notification action from its snapshot when its re-creation fails, and fails the run' {
            $script:Fake.Version = '2.43.1'
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            $pkg['programRuleActions'][1]['content'] = 'Changed'
            $script:Fake.FailImport = { param($p) $p.Contains('programRuleActions') -and @($p['programRuleActions'])[0]['content'] -eq 'Changed' }
            $err = $null
            try { Invoke-TestDeploy $pkg } catch { $err = $_ }
            $err.Exception.Message | Should -BeLike '*restored from its snapshot*'
            @($err.TargetObject.ProgramVersionPending).Count | Should -Be 0 -Because 'the restored action is what clients hold already'
            $restored = Get-FakeObject 'programRuleActions' 'raAAAAAAAA2'
            $restored | Should -Not -BeNullOrEmpty
            $restored.Contains('content') | Should -BeFalse -Because 'the snapshot is the action as it was'
            $restored['templateUid'] | Should -Be 'ntAAAAAAAA1'
        }

        It 'deletes a re-created notification action that fails its check before restoring it, since writing over it is an update' {
            $script:Fake.Version = '2.43.1'
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            $pkg['programRuleActions'][1]['content'] = 'Changed'
            # The re-creation commits, but leaves the template unlinked.
            $script:Fake.AfterImport = { param($p)
                $a = Get-FakeObject 'programRuleActions' 'raAAAAAAAA2'
                if ($p.Contains('programRuleActions') -and $a -and $a['content'] -eq 'Changed') { $a.Remove('templateUid') }
            }
            $err = $null
            try { Invoke-TestDeploy $pkg } catch { $err = $_ }
            $err.Exception.Message | Should -BeLike '*template is not linked. It was restored from its snapshot.'
            @($err.TargetObject.ProgramVersionPending).Count | Should -Be 0 -Because 'the restored action is what clients hold already'
            @($script:Fake.Requests | Where-Object { $_.Kind -eq 'delete' -and $_.Id -eq 'raAAAAAAAA2' }).Count | Should -Be 2 -Because 'the step deletes the action, and the restore deletes its failed re-creation'
            $restored = Get-FakeObject 'programRuleActions' 'raAAAAAAAA2'
            $restored.Contains('content') | Should -BeFalse
            $restored['templateUid'] | Should -Be 'ntAAAAAAAA1'
        }

        It 'restores a notification action whose re-creation fails in transport' {
            $script:Fake.Version = '2.42.6'
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            $pkg['programRuleActions'][1]['content'] = 'Changed'
            $script:Fake.ThrowImport = { param($p) $p.Contains('programRuleActions') -and @($p['programRuleActions'])[0]['content'] -eq 'Changed' }
            { Invoke-TestDeploy $pkg } | Should -Throw '*SSL connection*It was restored from its snapshot.*'
            (Get-FakeObject 'programRuleActions' 'raAAAAAAAA2')['templateUid'] | Should -Be 'ntAAAAAAAA1'
        }

        It 'keeps the snapshot in the summary and says so when the restore fails too' {
            $script:Fake.Version = '2.43.1'
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            $pkg['programRuleActions'][1]['content'] = 'Changed'
            $script:Fake.FailImport = { param($p) $p.Contains('programRuleActions') }
            $err = $null
            try { Invoke-TestDeploy $pkg } catch { $err = $_ }
            $err.Exception.Message | Should -BeLike '*Its restore failed*its snapshot is in the summary (Snapshots).*'
            $err.Exception.Message | Should -Not -BeLike '*was restored*'
            Get-FakeObject 'programRuleActions' 'raAAAAAAAA2' | Should -BeNullOrEmpty
            @($err.TargetObject.ProgramVersionPending) | Should -Be @('prAAAAAAAA1') -Because 'the action is gone from the instance while clients still run it'
            @($err.TargetObject.Snapshots).Count | Should -Be 1
            $err.TargetObject.Snapshots[0].Object['templateUid'] | Should -Be 'ntAAAAAAAA1'
        }

        It 'stops with the program version pending, unrestored, when a notification action''s accepted DELETE reads back neither present nor gone' {
            $script:Fake.Version = '2.43.1'
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            $pkg['programRuleActions'][1]['content'] = 'Changed'
            $script:Fake.StatusRead = { param($q) if ($q.Path -eq 'api/programRuleActions/raAAAAAAAA2') { 503 } }
            $err = $null
            try { Invoke-TestDeploy $pkg } catch { $err = $_ }
            $err.Exception.Message | Should -BeLike '*raAAAAAAAA2 was deleted for its re-creation, but reading programRuleActions raAAAAAAAA2 back answered HTTP 503*most likely gone*Deploy again*'
            @($err.TargetObject.ProgramVersionPending) | Should -Be @('prAAAAAAAA1') -Because 'the action is most likely gone while clients still run it'
            @($script:Fake.Requests | Where-Object { $_.Kind -eq 'delete' -and $_.Id -eq 'raAAAAAAAA2' }).Count | Should -Be 1 -Because 'no restore deletes it again'
            # A later run whose reads answer creates the action as the package states it.
            $script:Fake.StatusRead = $null
            (Invoke-TestDeploy $pkg).Succeeded | Should -BeTrue
            (Get-FakeObject 'programRuleActions' 'raAAAAAAAA2')['content'] | Should -Be 'Changed'
        }

        It 'reports a restore as failed, with the program version pending, when its read-back proves nothing' {
            $script:Fake.Version = '2.43.1'
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            $pkg['programRuleActions'][1]['content'] = 'Changed'
            $script:Fake.FailImport = { param($p) $p.Contains('programRuleActions') -and @($p['programRuleActions'])[0]['content'] -eq 'Changed' }
            # The read after the DELETE answers; the restore's own reads do not.
            $script:Fake['StatusReads'] = 0
            $script:Fake.StatusRead = { param($q) if ($q.Path -ne 'api/programRuleActions/raAAAAAAAA2') { return }; $script:Fake['StatusReads']++; if ($script:Fake['StatusReads'] -ge 2) { 503 } }
            $err = $null
            try { Invoke-TestDeploy $pkg } catch { $err = $_ }
            $err.Exception.Message | Should -BeLike '*Its restore failed (reading programRuleActions raAAAAAAAA2 back answered HTTP 503*its snapshot is in the summary (Snapshots).*'
            @($err.TargetObject.ProgramVersionPending) | Should -Be @('prAAAAAAAA1')
        }

        It 'stops with the program version pending when a delete''s read-back proves nothing, rather than call the object still present' {
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            Set-FakeObject 'optionGroups' @{ id = 'ogAAAAAAAA9'; code = 'G9'; name = 'G9'; shortName = 'G9'; optionSet = @{ id = 'osAAAAAAAA1' } }
            $script:Fake.StatusRead = { param($q) if ($q.Path -eq 'api/optionGroups/ogAAAAAAAA9') { 401 } }
            $err = $null
            try { Invoke-TestDeploy $pkg @{ Delete = @{ optionGroups = @('ogAAAAAAAA9') } } } catch { $err = $_ }
            $err.Exception.Message | Should -BeLike '*delete optionGroups ogAAAAAAAA9 failed: reading optionGroups ogAAAAAAAA9 back answered HTTP 401*'
            $err.Exception.Message | Should -Not -BeLike '*in place*'
            @($err.TargetObject.ProgramVersionPending) | Should -Be @('prAAAAAAAA1')
        }

        It 'stops before the DELETE of a notification action when the rule''s other actions cannot be read, and keeps a re-created one when its check cannot read the result' {
            $script:Fake.Version = '2.43.1'
            $pkg = New-TestPackage
            $pkg['programRules'][1]['programRuleActions'] = @([ordered]@{ id = 'raAAAAAAAA2' }, [ordered]@{ id = 'raAAAAAAAA4' })
            $pkg['programRuleActions'] += [ordered]@{ id = 'raAAAAAAAA4'; programRuleActionType = 'DISPLAYTEXT'; content = 'Four'; location = 'feedback'; programRule = [ordered]@{ id = 'ruAAAAAAAA2' } }
            Set-FakeFromPackage $pkg
            $pkg['programRuleActions'][1]['content'] = 'Changed'
            # Every read of the other actions' timestamps fails: the first comes before the DELETE.
            $script:Fake.ThrowGet = { param($q) (@($q.Fields) -join ',') -ceq 'id,lastUpdated' }
            $err = $null
            try { Invoke-TestDeploy $pkg } catch { $err = $_ }
            $err.Exception.Message | Should -BeLike '*Reading the other actions of rule ruAAAAAAAA2 before re-creating program-rule action raAAAAAAAA2 failed*'
            @($script:Fake.Requests | Where-Object { $_.Kind -eq 'delete' }).Count | Should -Be 0
            @($err.TargetObject.ProgramVersionPending).Count | Should -Be 0
            (Get-FakeObject 'programRuleActions' 'raAAAAAAAA2').Contains('content') | Should -BeFalse
            # Only the read after the re-creation fails: the action stays as written, and is not restored.
            $script:Fake['Reads'] = 0
            $script:Fake.ThrowGet = { param($q) if ((@($q.Fields) -join ',') -cne 'id,lastUpdated') { return $false }; $script:Fake['Reads']++; $script:Fake['Reads'] -ge 2 }
            $err = $null
            try { Invoke-TestDeploy $pkg } catch { $err = $_ }
            $err.Exception.Message | Should -BeLike '*raAAAAAAAA2 was re-created with its rule, but reading the result back for its check failed*left as written*'
            @($script:Fake.Requests | Where-Object { $_.Kind -eq 'delete' -and $_.Id -eq 'raAAAAAAAA2' }).Count | Should -Be 1 -Because 'no restore deletes it again'
            (Get-FakeObject 'programRuleActions' 'raAAAAAAAA2')['content'] | Should -Be 'Changed'
            @($err.TargetObject.ProgramVersionPending) | Should -Be @('prAAAAAAAA1')
        }

        It 'keeps a re-created notification action, unrestored, when the read of its rule holds no list of actions' {
            $script:Fake.Version = '2.43.1'
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            $pkg['programRuleActions'][1]['content'] = 'Changed'
            $script:Fake.NoList = { param($q) $q.Path -eq 'api/programRules/ruAAAAAAAA2' -and (@($q.Fields) -join ',') -ceq 'programRuleActions[id]' }
            $err = $null
            try { Invoke-TestDeploy $pkg } catch { $err = $_ }
            $err.Exception.Message | Should -BeLike "*raAAAAAAAA2 was re-created with its rule, but reading the result back for its check failed: the read of rule ruAAAAAAAA2 held no 'programRuleActions' list*left as written*"
            @($script:Fake.Requests | Where-Object { $_.Kind -eq 'delete' -and $_.Id -eq 'raAAAAAAAA2' }).Count | Should -Be 1 -Because 'no restore deletes it again'
            (Get-FakeObject 'programRuleActions' 'raAAAAAAAA2')['content'] | Should -Be 'Changed'
        }

        It 'aborts on an unacknowledged <Kind> hazard (<Case>) before any write, and goes ahead when it is acknowledged' -ForEach @(
            @{ Kind = 'OptionSetMembership'; Case = 'an option lost'; Live = $null; Change = { param($p) $p['optionSets'][0]['options'] = @([ordered]@{ id = 'opAAAAAAAA1' }); $p['options'] = @($p['options'][0]) } }
            @{ Kind = 'OptionSetMembership'; Case = 'an option inserted before existing ones'; Live = $null
                Change = { param($p)
                    $p['options'] += [ordered]@{ id = 'opAAAAAAAA3'; code = '3'; name = 'Three'; sortOrder = 0; optionSet = [ordered]@{ id = 'osAAAAAAAA1' } }
                    $p['optionSets'][0]['options'] = @([ordered]@{ id = 'opAAAAAAAA3' }, [ordered]@{ id = 'opAAAAAAAA1' }, [ordered]@{ id = 'opAAAAAAAA2' }) } }
            @{ Kind = 'OptionCodeChange'; Case = 'a code'; Live = $null; Change = { param($p) $p['options'][0]['code'] = 'one' } }
            @{ Kind = 'OptionNameChange'; Case = 'an option renamed'; Live = $null; Change = { param($p) $p['options'][0]['name'] = 'Uno' } }
            @{ Kind = 'SharingGrantRemoval'; Case = 'a user-group grant'; Change = { param($p) $p['dataElements'][0]['sharing'] = [ordered]@{ public = 'r-------' } }
                Live = { (Get-FakeObject 'dataElements' 'deAAAAAAAA1')['sharing'] = @{ public = 'r-------'; userGroups = @{ ugAAAAAAAA1 = @{ id = 'ugAAAAAAAA1'; access = 'r-------' } } } } }
            @{ Kind = 'SharingGrantRemoval'; Case = 'a narrowed public access string'; Change = { param($p) $p['dataElements'][0]['sharing'] = [ordered]@{ public = 'r-------' } }
                Live = { (Get-FakeObject 'dataElements' 'deAAAAAAAA1')['sharing'] = @{ public = 'rw------' } } }
            @{ Kind = 'OrphanDelete'; Case = 'an action its rule drops'; Live = $null; Change = { param($p) $p['programRules'][1]['programRuleActions'] = @(); $p['programRuleActions'] = @($p['programRuleActions'][0], $p['programRuleActions'][2]) } }
        ) {
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            if ($Live) { & $Live }
            & $Change $pkg
            { Invoke-TestDeploy $pkg } | Should -Throw "*Unacknowledged hazard(s): $Kind*"
            (Get-CommitRequest).Count | Should -Be 0
            $r = Invoke-TestDeploy $pkg @{ AllowHazard = @($Kind) }
            $r.Succeeded | Should -BeTrue
            @($r.Hazards | Where-Object Kind -eq $Kind).Count | Should -BeGreaterThan 0
        }

        It 'names each permission the package''s sharing takes away, the data permissions only for a type that shares data' {
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            (Get-FakeObject 'dataElements' 'deAAAAAAAA1')['sharing'] = @{ public = 'rwrw----' }
            (Get-FakeObject 'programs' 'prAAAAAAAA1')['sharing'] = @{ public = 'rwrw----' }
            $pkg['dataElements'][0]['sharing'] = [ordered]@{ public = 'rw------' }
            $pkg['programs'][0]['sharing'] = [ordered]@{ public = 'rw------' }
            { Invoke-TestDeploy $pkg } | Should -Throw '*Unacknowledged hazard(s): SharingGrantRemoval*'
            (Get-CommitRequest).Count | Should -Be 0
            $r = Invoke-TestDeploy $pkg @{ AllowHazard = @('SharingGrantRemoval') }
            $r.Succeeded | Should -BeTrue
            @($r.Hazards | Where-Object Kind -eq 'SharingGrantRemoval' | ForEach-Object { "$($_.Type) $($_.Id): $($_.Detail)" }) |
                Should -BeExactly @('programs prAAAAAAAA1: public access loses data read, data write (rwrw---- to rw------)') -Because 'a data element shares no data'
        }

        It 'stops before its confirmation and any request but its reads on a DHIS2 release it was not verified on (<Version>), unless acknowledged or synthetic' -ForEach @(
            @{ Version = '2.44.0' }
            @{ Version = '2.41.9' }
            @{ Version = '2.43.1-SNAPSHOT' }
        ) {
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            $pkg['dataElements'][0]['name'] = 'Renamed'
            $script:Fake.Version = $Version
            { Invoke-TestDeploy $pkg } | Should -Throw '*Unacknowledged hazard(s): UnverifiedVersion*'
            $script:Fake.Requests.Count | Should -Be 0 -Because 'it stops before the cache clear'
            # A dry run reports it with the other hazards, the plan included.
            $err = $null
            try { Invoke-TestDeploy $pkg @{ DryRun = $true } } catch { $err = $_ }
            $err.Exception.Message | Should -BeLike '*Unacknowledged hazard(s): UnverifiedVersion*'
            @($err.TargetObject.Plan | Where-Object Type -eq 'dataElements')[0].Changed | Should -Be 1
            (Get-CommitRequest).Count | Should -Be 0
            $r = Invoke-TestDeploy $pkg @{ AllowHazard = @('UnverifiedVersion') }
            $r.Succeeded | Should -BeTrue
            $h = @($r.Hazards | Where-Object Kind -eq 'UnverifiedVersion')
            $h.Count | Should -Be 1
            "$($h[0].Type) $($h[0].Id) $($h[0].Detail)" |
                Should -BeExactly "DHIS2 $Version is no release this deployment was verified on: 2.40.12, 2.41.10, 2.42.6, 2.43.1, or a later patch of one of their lines"
            (Invoke-TestDeploy $pkg @{ SyntheticInstance = $true }).Succeeded | Should -BeTrue -Because 'a synthetic deployment acknowledges every hazard'
        }

        It 'raises no version hazard on a later patch of a verified line' {
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            $pkg['dataElements'][0]['name'] = 'Renamed'
            $script:Fake.Version = '2.41.11'
            $r = Invoke-TestDeploy $pkg
            $r.Succeeded | Should -BeTrue
            @($r.Hazards).Count | Should -Be 0
        }

        It 'aborts when a rule action the package keeps refers to a section it drops, naming the action' {
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            $pkg['programStages'][0]['programStageSections'] = @([ordered]@{ id = 'ssAAAAAAAA1' })
            $pkg['programStageSections'] = @($pkg['programStageSections'][0])
            { Invoke-TestDeploy $pkg @{ AllowHazard = @('OrphanDelete') } } | Should -Throw '*raAAAAAAAA3*refers to programStageSections|ssAAAAAAAA2*'
            (Get-CommitRequest).Count | Should -Be 0
        }

        It 'retires a section with its HIDESECTION action: the rule first, then the stage' {
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            $pkg['programStages'][0]['programStageSections'] = @([ordered]@{ id = 'ssAAAAAAAA1' })
            $pkg['programStageSections'] = @($pkg['programStageSections'][0])
            $pkg['programRules'][0]['programRuleActions'] = @([ordered]@{ id = 'raAAAAAAAA1' })
            $pkg['programRuleActions'] = @($pkg['programRuleActions'][0], $pkg['programRuleActions'][1])
            $r = Invoke-TestDeploy $pkg @{ Delete = @{ programStageSections = @('ssAAAAAAAA2'); programRuleActions = @('raAAAAAAAA3') } }
            $r.Succeeded | Should -BeTrue
            $commits = Get-CommitRequest
            @($commits[0].Payload.Keys) | Should -Be @('programRules') -Because 'the detach request comes first'
            $commits[1].Payload.Contains('programStages') | Should -BeTrue
            Get-FakeObject 'programStageSections' 'ssAAAAAAAA2' | Should -BeNullOrEmpty
            Get-FakeObject 'programRuleActions' 'raAAAAAAAA3' | Should -BeNullOrEmpty
            @($script:Fake.Requests | Where-Object { $_.Kind -eq 'delete' }).Count | Should -Be 0 -Because 'a child is removed by its parent''s write, never through its own endpoint'
            $r.Deleted.Contains('programStageSections|ssAAAAAAAA2') | Should -BeTrue
        }

        It 'detaches an action the package points away from a section its stage drops, and creates it again in R1' {
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            $pkg['programStages'][0]['programStageSections'] = @([ordered]@{ id = 'ssAAAAAAAA1' })
            $pkg['programStageSections'] = @($pkg['programStageSections'][0])
            $pkg['programRuleActions'][2]['programStageSection'] = [ordered]@{ id = 'ssAAAAAAAA1' }
            $r = Invoke-TestDeploy $pkg @{ Delete = @{ programStageSections = @('ssAAAAAAAA2') } }
            $r.Succeeded | Should -BeTrue
            $commits = Get-CommitRequest
            @($commits[0].Payload.Keys) | Should -Be @('programRules') -Because 'the live action still targets the section, so its rule lets go of it first'
            @((Get-PayloadObject $commits[0] 'programRules' 'ruAAAAAAAA1')['programRuleActions'] | ForEach-Object { $_['id'] }) | Should -Be @('raAAAAAAAA1')
            (Get-PayloadObject $commits[1] 'programRuleActions' 'raAAAAAAAA3')['programStageSection']['id'] | Should -Be 'ssAAAAAAAA1'
            $commits[1].Payload.Contains('programStages') | Should -BeTrue
            (Get-FakeObject 'programRuleActions' 'raAAAAAAAA3')['programStageSection']['id'] | Should -Be 'ssAAAAAAAA1'
            @((Get-FakeObject 'programRules' 'ruAAAAAAAA1')['programRuleActions'] | ForEach-Object { $_['id'] }) | Should -Be @('raAAAAAAAA1', 'raAAAAAAAA3')
            Get-FakeObject 'programStageSections' 'ssAAAAAAAA2' | Should -BeNullOrEmpty
        }

        It 'aborts before any write when an action the package does not carry refers to a section it drops' {
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            Set-FakeObject 'programRules' @{ id = 'ruAAAAAAAA9'; name = 'Live only'; condition = 'true'; program = @{ id = 'prAAAAAAAA1' }; programRuleActions = @(@{ id = 'raAAAAAAAA9' }) }
            Set-FakeObject 'programRuleActions' @{ id = 'raAAAAAAAA9'; programRuleActionType = 'HIDESECTION'; programStageSection = @{ id = 'ssAAAAAAAA2' }; programRule = @{ id = 'ruAAAAAAAA9' } }
            $pkg['programStages'][0]['programStageSections'] = @([ordered]@{ id = 'ssAAAAAAAA1' })
            $pkg['programStageSections'] = @($pkg['programStageSections'][0])
            $pkg['programRules'][0]['programRuleActions'] = @([ordered]@{ id = 'raAAAAAAAA1' })
            $pkg['programRuleActions'] = @($pkg['programRuleActions'][0], $pkg['programRuleActions'][1])
            $delete = @{ programStageSections = @('ssAAAAAAAA2'); programRuleActions = @('raAAAAAAAA3') }
            { Invoke-TestDeploy $pkg @{ Delete = $delete } } | Should -Throw '*programRuleActions raAAAAAAAA9 refers to programStageSections|ssAAAAAAAA2*the package does not carry it*'
            (Get-CommitRequest).Count | Should -Be 0
            # Listed in -Delete, its rule would go only after the stage's write, which needs the section gone.
            { Invoke-TestDeploy $pkg @{ Delete = $delete + @{ programRules = @('ruAAAAAAAA9') }; AllowHazard = @('ActiveRuleDelete') } } |
                Should -Throw '*raAAAAAAAA9*make the rule inert in an earlier deployment*'
            (Get-CommitRequest).Count | Should -Be 0
        }

        It 'deletes a stage and a program section the program drops through their own endpoints, only when -Delete lists them' {
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            $program = Get-FakeObject 'programs' 'prAAAAAAAA1'
            $program['programStages'] = @(@{ id = 'psAAAAAAAA1' }, @{ id = 'psAAAAAAAA2' })
            $program['programSections'] = @(@{ id = 'pscAAAAAAA9' })
            Set-FakeObject 'programStages' @{ id = 'psAAAAAAAA2'; code = 'STG2'; name = 'Old stage'; program = @{ id = 'prAAAAAAAA1' }; programStageSections = @(@{ id = 'ssAAAAAAAA9' }) }
            Set-FakeObject 'programStageSections' @{ id = 'ssAAAAAAAA9'; code = 'SEC9'; name = 'Old section'; sortOrder = 0; programStage = @{ id = 'psAAAAAAAA2' } }
            Set-FakeObject 'programSections' @{ id = 'pscAAAAAAA9'; name = 'Old program section'; sortOrder = 0; program = @{ id = 'prAAAAAAAA1' } }
            # Writing the program without them would only detach them.
            { Invoke-TestDeploy $pkg } | Should -Throw '*no longer lists programStages psAAAAAAAA2*list it in -Delete*'
            { Invoke-TestDeploy $pkg @{ Delete = @{ programStages = @('psAAAAAAAA2') } } } | Should -Throw '*no longer lists programSections pscAAAAAAA9*'
            (Get-CommitRequest).Count | Should -Be 0
            $r = Invoke-TestDeploy $pkg @{ Delete = @{ programStages = @('psAAAAAAAA2'); programSections = @('pscAAAAAAA9') } }
            $r.Succeeded | Should -BeTrue
            @($script:Fake.Requests | Where-Object { $_.Kind -eq 'delete' } | ForEach-Object { "$($_.Type)|$($_.Id)" } | Sort-Object) | Should -Be @('programSections|pscAAAAAAA9', 'programStages|psAAAAAAAA2')
            Get-FakeObject 'programStages' 'psAAAAAAAA2' | Should -BeNullOrEmpty
            Get-FakeObject 'programStageSections' 'ssAAAAAAAA9' | Should -BeNullOrEmpty
            $r.Deleted.Contains('programStageSections|ssAAAAAAAA9') | Should -BeTrue -Because 'the stage''s sections are read back as gone'
            $deletes = Get-RequestIndex { param($q) $q.Kind -eq 'delete' }
            $writes = Get-RequestIndex { param($q) $q.Mode -eq 'COMMIT' -and (Get-PayloadObject $q 'programs' 'prAAAAAAAA1') }
            $writes.Count | Should -Be 1
            $writes[0] | Should -BeGreaterThan $deletes[-1] -Because 'the program is written once, last'
            @((Get-FakeObject 'programs' 'prAAAAAAAA1')['programStages'] | ForEach-Object { $_['id'] }) | Should -Be @('psAAAAAAAA1')
            (Get-FakeObject 'programs' 'prAAAAAAAA1')['version'] | Should -Be 6
        }

        It 'aborts before any write when a rule variable the package does not carry refers to a stage it deletes' {
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            (Get-FakeObject 'programs' 'prAAAAAAAA1')['programStages'] = @(@{ id = 'psAAAAAAAA1' }, @{ id = 'psAAAAAAAA2' })
            Set-FakeObject 'programStages' @{ id = 'psAAAAAAAA2'; code = 'STG2'; name = 'Old stage'; program = @{ id = 'prAAAAAAAA1' } }
            Set-FakeObject 'programRuleVariables' @{ id = 'rvAAAAAAAA9'; name = 'old_stage_value'; programRuleVariableSourceType = 'DATAELEMENT_NEWEST_EVENT_PROGRAM_STAGE'
                program = @{ id = 'prAAAAAAAA1' }; programStage = @{ id = 'psAAAAAAAA2' }; dataElement = @{ id = 'deAAAAAAAA1' } }
            { Invoke-TestDeploy $pkg @{ Delete = @{ programStages = @('psAAAAAAAA2') } } } |
                Should -Throw '*programRuleVariables rvAAAAAAAA9 refers to programStages|psAAAAAAAA2*the package does not carry it*'
            (Get-CommitRequest).Count | Should -Be 0
            @($script:Fake.Requests | Where-Object { $_.Kind -eq 'delete' }).Count | Should -Be 0
        }

        It 'deletes a rule in -Delete before the stage its action refers to' {
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            (Get-FakeObject 'programs' 'prAAAAAAAA1')['programStages'] = @(@{ id = 'psAAAAAAAA1' }, @{ id = 'psAAAAAAAA2' })
            Set-FakeObject 'programStages' @{ id = 'psAAAAAAAA2'; code = 'STG2'; name = 'Old stage'; program = @{ id = 'prAAAAAAAA1' } }
            Set-FakeObject 'programRules' @{ id = 'ruAAAAAAAA9'; name = 'Old rule'; condition = 'true'; program = @{ id = 'prAAAAAAAA1' }; programRuleActions = @(@{ id = 'raAAAAAAAA9' }) }
            Set-FakeObject 'programRuleActions' @{ id = 'raAAAAAAAA9'; programRuleActionType = 'HIDEPROGRAMSTAGE'; programStage = @{ id = 'psAAAAAAAA2' }; programRule = @{ id = 'ruAAAAAAAA9' } }
            $r = Invoke-TestDeploy $pkg @{ Delete = @{ programStages = @('psAAAAAAAA2'); programRules = @('ruAAAAAAAA9') }; AllowHazard = @('ActiveRuleDelete') }
            $r.Succeeded | Should -BeTrue
            @($script:Fake.Requests | Where-Object { $_.Kind -eq 'delete' } | ForEach-Object { "$($_.Type)|$($_.Id)" }) |
                Should -Be @('programRules|ruAAAAAAAA9', 'programStages|psAAAAAAAA2') -Because 'DHIS2 refuses to delete a stage that a rule action still refers to'
            Get-FakeObject 'programStages' 'psAAAAAAAA2' | Should -BeNullOrEmpty
        }

        It 'stops before any write when an action the package does not carry sends a template that a stage in -Delete takes with it (<Version>)' -ForEach @(
            @{ Version = '2.41.10' }
            @{ Version = '2.43.1' }
        ) {
            $script:Fake.Version = $Version
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            (Get-FakeObject 'programs' 'prAAAAAAAA1')['programStages'] = @(@{ id = 'psAAAAAAAA1' }, @{ id = 'psAAAAAAAA2' })
            Set-FakeObject 'programStages' @{ id = 'psAAAAAAAA2'; code = 'STG2'; name = 'Old stage'; program = @{ id = 'prAAAAAAAA1' }; notificationTemplates = @(@{ id = 'ntAAAAAAAA9' }) }
            Set-FakeObject 'programNotificationTemplates' @{ id = 'ntAAAAAAAA9'; name = 'Old notice'; messageTemplate = 'Old'; notificationTrigger = 'PROGRAM_RULE'; notificationRecipient = 'USER_GROUP' }
            Set-FakeObject 'programRules' @{ id = 'ruAAAAAAAA9'; name = 'Live only'; condition = 'true'; program = @{ id = 'prAAAAAAAA1' }; programRuleActions = @(@{ id = 'raAAAAAAAA9' }) }
            Set-FakeObject 'programRuleActions' @{ id = 'raAAAAAAAA9'; programRuleActionType = 'SENDMESSAGE'; templateUid = 'ntAAAAAAAA9'; programRule = @{ id = 'ruAAAAAAAA9' } }
            # An action goes only with its rule, so the rule is what -Delete would have to list.
            { Invoke-TestDeploy $pkg @{ Delete = @{ programStages = @('psAAAAAAAA2') } } } |
                Should -Throw '*programRuleActions raAAAAAAAA9 refers to programNotificationTemplates|ntAAAAAAAA9*the package does not carry it: list its rule ruAAAAAAAA9 in -Delete*'
            (Get-CommitRequest).Count | Should -Be 0
            @($script:Fake.Requests | Where-Object { $_.Kind -eq 'delete' }).Count | Should -Be 0
            Get-FakeObject 'programNotificationTemplates' 'ntAAAAAAAA9' | Should -Not -BeNullOrEmpty
        }

        It 'repoints an action that sends a template a stage in -Delete takes with it, then deletes the stage and the template (<Version>)' -ForEach @(
            @{ Version = '2.41.10' }
            @{ Version = '2.43.1' }
        ) {
            $script:Fake.Version = $Version
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            (Get-FakeObject 'programs' 'prAAAAAAAA1')['programStages'] = @(@{ id = 'psAAAAAAAA1' }, @{ id = 'psAAAAAAAA2' })
            Set-FakeObject 'programStages' @{ id = 'psAAAAAAAA2'; code = 'STG2'; name = 'Old stage'; program = @{ id = 'prAAAAAAAA1' }; notificationTemplates = @(@{ id = 'ntAAAAAAAA9' }) }
            Set-FakeObject 'programNotificationTemplates' @{ id = 'ntAAAAAAAA9'; name = 'Old notice'; messageTemplate = 'Old'; notificationTrigger = 'PROGRAM_RULE'; notificationRecipient = 'USER_GROUP' }
            # On the instance the action sends the old stage's template; the package has it send its own.
            (Get-FakeObject 'programRuleActions' 'raAAAAAAAA2')['templateUid'] = 'ntAAAAAAAA9'
            $r = Invoke-TestDeploy $pkg @{ Delete = @{ programStages = @('psAAAAAAAA2') } }
            $r.Succeeded | Should -BeTrue
            (Get-FakeObject 'programRuleActions' 'raAAAAAAAA2')['templateUid'] | Should -Be 'ntAAAAAAAA1'
            Get-FakeObject 'programNotificationTemplates' 'ntAAAAAAAA9' | Should -BeNullOrEmpty
            $r.Deleted.Contains('programNotificationTemplates|ntAAAAAAAA9') | Should -BeTrue -Because 'what goes with a stage is read back as gone'
            $repointed = Get-RequestIndex { param($q) $q.Mode -eq 'COMMIT' -and (Get-PayloadObject $q 'programRuleActions' 'raAAAAAAAA2') }
            $stageDelete = Get-RequestIndex { param($q) $q.Kind -eq 'delete' -and $q.Id -eq 'psAAAAAAAA2' }
            $repointed[-1] | Should -BeLessThan $stageDelete[0]
        }

        It 'stops before any write when something still refers to an option set in -Delete or to one of its options' {
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            Set-FakeObject 'optionSets' @{ id = 'osAAAAAAAA9'; code = 'OS9'; name = 'Old set'; valueType = 'TEXT'; version = 1; options = @(@{ id = 'opAAAAAAAA9' }) }
            Set-FakeObject 'options' @{ id = 'opAAAAAAAA9'; code = '9'; name = 'Nine'; sortOrder = 1; optionSet = @{ id = 'osAAAAAAAA9' } }
            $delete = @{ Delete = @{ optionSets = @('osAAAAAAAA9') }; AllowHazard = @('OptionSetMembership') }
            # A live action the package does not carry targets one of the set's options.
            Set-FakeObject 'programRules' @{ id = 'ruAAAAAAAA9'; name = 'Live only'; condition = 'true'; program = @{ id = 'prAAAAAAAA1' }; programRuleActions = @(@{ id = 'raAAAAAAAA9' }) }
            Set-FakeObject 'programRuleActions' @{ id = 'raAAAAAAAA9'; programRuleActionType = 'HIDEOPTION'; option = @{ id = 'opAAAAAAAA9' }; dataElement = @{ id = 'deAAAAAAAA1' }; programRule = @{ id = 'ruAAAAAAAA9' } }
            { Invoke-TestDeploy $pkg $delete } | Should -Throw '*programRuleActions raAAAAAAAA9 refers to options|opAAAAAAAA9*the package does not carry it*'
            # A live data element the package does not carry uses the set.
            [void](Get-FakeType 'programRuleActions').Remove('raAAAAAAAA9')
            (Get-FakeObject 'programRules' 'ruAAAAAAAA9')['programRuleActions'] = @()
            Set-FakeObject 'dataElements' @{ id = 'deAAAAAAAA9'; code = 'DE9'; name = 'Live only'; shortName = 'DE9'; valueType = 'TEXT'; domainType = 'TRACKER'; aggregationType = 'NONE'; optionSet = @{ id = 'osAAAAAAAA9' } }
            { Invoke-TestDeploy $pkg $delete } | Should -Throw '*dataElements deAAAAAAAA9 refers to optionSets|osAAAAAAAA9*the package does not carry it*'
            # The package's own data element would use it.
            [void](Get-FakeType 'dataElements').Remove('deAAAAAAAA9')
            $pkg['dataElements'][0]['optionSet'] = [ordered]@{ id = 'osAAAAAAAA9' }
            { Invoke-TestDeploy $pkg $delete } | Should -Throw "*The package's dataElements deAAAAAAAA1 refers to optionSets|osAAAAAAAA9*"
            (Get-CommitRequest).Count | Should -Be 0
            @($script:Fake.Requests | Where-Object { $_.Kind -eq 'delete' }).Count | Should -Be 0
        }

        It 'refuses before any write to delete a stage that has an event, a deleted one included (<Version>)' -ForEach @(
            @{ Version = '2.40.12'; Mode = 'ouMode' }
            @{ Version = '2.43.1'; Mode = 'orgUnitMode' }
        ) {
            $script:Fake.Version = $Version
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            (Get-FakeObject 'programs' 'prAAAAAAAA1')['programStages'] = @(@{ id = 'psAAAAAAAA1' }, @{ id = 'psAAAAAAAA2' })
            Set-FakeObject 'programStages' @{ id = 'psAAAAAAAA2'; code = 'STG2'; name = 'Old stage'; program = @{ id = 'prAAAAAAAA1' } }
            $script:Fake.Events.Add(@{ event = 'evAAAAAAAA1'; programStage = 'psAAAAAAAA2'; deleted = $true })
            { Invoke-TestDeploy $pkg @{ Delete = @{ programStages = @('psAAAAAAAA2') } } } | Should -Throw '*Program stage psAAAAAAAA2 has events*the package must keep it*'
            (Get-CommitRequest).Count | Should -Be 0
            @($script:Fake.Requests | Where-Object { $_.Kind -eq 'delete' }).Count | Should -Be 0
            $read = @($script:Fake.Requests | Where-Object { $_.Kind -eq 'events' })[0]
            $read.Query[$Mode] | Should -Be 'ALL' -Because 'an event in any org unit vetoes the delete'
            $read.PageSize | Should -Be 1
        }

        It 'refuses before any write to delete a stage that <Case>' -ForEach @(
            @{ Case = 'an event visualization is built on'; Version = '2.41.10'; Expect = "*eventVisualizations evAAAAAAAA9 ('Line list') uses programStages psAAAAAAAA2*"
                Live = { Set-FakeObject 'eventVisualizations' @{ id = 'evAAAAAAAA9'; name = 'Line list'; programStage = @{ id = 'psAAAAAAAA2' } } } }
            @{ Case = 'a map view uses'; Version = '2.43.1'; Expect = '*mapViews mvAAAAAAAA9 uses programStages psAAAAAAAA2*'
                Live = { Set-FakeObject 'mapViews' @{ id = 'mvAAAAAAAA9'; programStage = @{ id = 'psAAAAAAAA2' } } } }
            @{ Case = 'nothing uses, on 2.40 while an event visualization has no stage'; Version = '2.40.12'; Expect = "*eventVisualizations evAAAAAAAA9 ('Enrollment list') has no stage*"
                Live = { Set-FakeObject 'eventVisualizations' @{ id = 'evAAAAAAAA9'; name = 'Enrollment list' } } }
            @{ Case = 'a working list names'; Version = '2.42.6'; Expect = "*programStageWorkingLists wlAAAAAAAA9 ('Open') uses programStages psAAAAAAAA2*"
                Live = { Set-FakeObject 'programStageWorkingLists' @{ id = 'wlAAAAAAAA9'; name = 'Open'; programStage = @{ id = 'psAAAAAAAA2' } } } }
            @{ Case = 'a relationship type''s constraint names'; Version = '2.41.10'; Expect = '*relationshipTypes rtAAAAAAAA9 names programStages psAAAAAAAA2 in its toConstraint*'
                Live = { Set-FakeObject 'relationshipTypes' @{ id = 'rtAAAAAAAA9'; fromConstraint = @{ relationshipEntity = 'TRACKED_ENTITY_INSTANCE' }; toConstraint = @{ programStage = @{ id = 'psAAAAAAAA2' } } } } }
            @{ Case = 'an SMS command names'; Version = '2.43.1'; Expect = '*smsCommands scAAAAAAAA9 uses programStages psAAAAAAAA2*'
                Live = { Set-FakeObject 'smsCommands' @{ id = 'scAAAAAAAA9'; programStage = @{ id = 'psAAAAAAAA2' } } } }
            @{ Case = 'an event visualization''s data-element dimension names'; Version = '2.43.1'; Expect = '*eventVisualizations evAAAAAAAA9 has a data-element dimension on programStages psAAAAAAAA2*'
                Live = { Set-FakeObject 'eventVisualizations' @{ id = 'evAAAAAAAA9'; programStage = @{ id = 'psAAAAAAAA1' }; dataElementDimensions = @(@{ dataElement = @{ id = 'deAAAAAAAA1' }; programStage = @{ id = 'psAAAAAAAA2' } }) } } }
            @{ Case = 'a map view''s data-element dimension names'; Version = '2.42.6'; Expect = '*mapViews mvAAAAAAAA9 has a data-element dimension on programStages psAAAAAAAA2*'
                Live = { Set-FakeObject 'mapViews' @{ id = 'mvAAAAAAAA9'; dataElementDimensions = @(@{ programStage = @{ id = 'psAAAAAAAA2' } }) } } }
        ) {
            $script:Fake.Version = $Version
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            (Get-FakeObject 'programs' 'prAAAAAAAA1')['programStages'] = @(@{ id = 'psAAAAAAAA1' }, @{ id = 'psAAAAAAAA2' })
            Set-FakeObject 'programStages' @{ id = 'psAAAAAAAA2'; code = 'STG2'; name = 'Old stage'; program = @{ id = 'prAAAAAAAA1' } }
            & $Live
            { Invoke-TestDeploy $pkg @{ Delete = @{ programStages = @('psAAAAAAAA2') } } } | Should -Throw $Expect
            (Get-CommitRequest).Count | Should -Be 0
            @($script:Fake.Requests | Where-Object { $_.Kind -eq 'delete' }).Count | Should -Be 0
            # From 2.41 a visualization without a stage is no obstacle.
            if ($Version -eq '2.40.12') {
                $script:Fake.Version = '2.41.10'
                $r = Invoke-TestDeploy $pkg @{ Delete = @{ programStages = @('psAAAAAAAA2') } }
                $r.Succeeded | Should -BeTrue
                Get-FakeObject 'programStages' 'psAAAAAAAA2' | Should -BeNullOrEmpty
            }
        }

        It 'stops before any write when the rule that holds an action the package points away from a dropped section is one it does not carry' {
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            (Get-FakeObject 'programRules' 'ruAAAAAAAA1')['programRuleActions'] = @(@{ id = 'raAAAAAAAA1' })
            Set-FakeObject 'programRules' @{ id = 'ruAAAAAAAA9'; name = 'Live only'; condition = 'true'; program = @{ id = 'prAAAAAAAA1' }; programRuleActions = @(@{ id = 'raAAAAAAAA3' }) }
            (Get-FakeObject 'programRuleActions' 'raAAAAAAAA3')['programRule'] = @{ id = 'ruAAAAAAAA9' }
            $pkg['programStages'][0]['programStageSections'] = @([ordered]@{ id = 'ssAAAAAAAA1' })
            $pkg['programStageSections'] = @($pkg['programStageSections'][0])
            $pkg['programRuleActions'][2]['programStageSection'] = [ordered]@{ id = 'ssAAAAAAAA1' }
            # Listed under a rule the package carries, the action would move out of one it does not.
            { Invoke-TestDeploy $pkg @{ Delete = @{ programStageSections = @('ssAAAAAAAA2') } } } | Should -Throw '*lists programRuleActions raAAAAAAAA3 under programRules ruAAAAAAAA1, but on the instance it belongs to a parent the package neither carries nor deletes*'
            (Get-CommitRequest).Count | Should -Be 0
            # Listed under none, it stays where it is, and the rule that holds it would have to write it out first.
            $pkg['programRules'][0]['programRuleActions'] = @([ordered]@{ id = 'raAAAAAAAA1' })
            { Invoke-TestDeploy $pkg @{ Delete = @{ programStageSections = @('ssAAAAAAAA2') } } } | Should -Throw '*raAAAAAAAA3*the rule ruAAAAAAAA9 that holds it*'
            (Get-CommitRequest).Count | Should -Be 0
        }

        It 'detaches a rule with the live value of a reference to a stage the run creates (<Case>), and writes the rule in full in R1' -ForEach @(
            @{ Case = 'none on the instance'; LiveStage = $null }
            @{ Case = 'an existing stage on the instance'; LiveStage = 'psAAAAAAAA1' }
        ) {
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            if ($LiveStage) { (Get-FakeObject 'programRules' 'ruAAAAAAAA1')['programStage'] = @{ id = $LiveStage } }
            $pkg['programStages'] += [ordered]@{ id = 'psAAAAAAAA3'; code = 'STG3'; name = 'New stage'; program = [ordered]@{ id = 'prAAAAAAAA1' } }
            $pkg['programs'][0]['programStages'] = @([ordered]@{ id = 'psAAAAAAAA1' }, [ordered]@{ id = 'psAAAAAAAA3' })
            $pkg['programStages'][0]['programStageSections'] = @([ordered]@{ id = 'ssAAAAAAAA1' })
            $pkg['programStageSections'] = @($pkg['programStageSections'][0])
            $pkg['programRules'][0]['programRuleActions'] = @([ordered]@{ id = 'raAAAAAAAA1' })
            $pkg['programRules'][0]['programStage'] = [ordered]@{ id = 'psAAAAAAAA3' }
            $pkg['programRuleActions'] = @($pkg['programRuleActions'][0], $pkg['programRuleActions'][1])
            $r = Invoke-TestDeploy $pkg @{ Delete = @{ programStageSections = @('ssAAAAAAAA2'); programRuleActions = @('raAAAAAAAA3') } }
            $r.Succeeded | Should -BeTrue
            $commits = Get-CommitRequest
            $detached = Get-PayloadObject $commits[0] 'programRules' 'ruAAAAAAAA1'
            if ($LiveStage) { $detached['programStage']['id'] | Should -Be $LiveStage -Because 'the new stage does not exist before R1' }
            else { $detached.Contains('programStage') | Should -BeFalse -Because 'the new stage does not exist before R1' }
            (Get-PayloadObject $commits[1] 'programRules' 'ruAAAAAAAA1')['programStage']['id'] | Should -Be 'psAAAAAAAA3'
            (Get-FakeObject 'programRules' 'ruAAAAAAAA1')['programStage']['id'] | Should -Be 'psAAAAAAAA3'
        }

        It 'refuses a -Delete entry for a child that the package keeps or no written parent drops, for a single option, and for a program' {
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            Set-FakeObject 'options' @{ id = 'opAAAAAAAA9'; code = '9'; name = 'Nine'; sortOrder = 3; optionSet = @{ id = 'osAAAAAAAA1' } }
            Set-FakeObject 'programs' @{ id = 'prAAAAAAAA9'; code = 'PROG9'; name = 'Old program'; shortName = 'Old program'; programType = 'WITH_REGISTRATION'; version = 1 }
            { Invoke-TestDeploy $pkg @{ Delete = @{ programStageSections = @('ssAAAAAAAA1') } } } | Should -Throw '*which the package still carries*'
            { Invoke-TestDeploy $pkg @{ Delete = @{ programRuleActions = @('raAAAAAAAA9') } } } | Should -Throw '*which no written parent drops*'
            { Invoke-TestDeploy $pkg @{ Delete = @{ options = @('opAAAAAAAA9') } } } | Should -Throw '*does not delete single options*'
            { Invoke-TestDeploy $pkg @{ Delete = @{ programs = @('prAAAAAAAA9') } } } | Should -Throw "*does not delete programs*stages, rules, rule variables and indicators*"
            Get-FakeObject 'programs' 'prAAAAAAAA9' | Should -Not -BeNullOrEmpty
            (Get-CommitRequest).Count | Should -Be 0
            @($script:Fake.Requests | Where-Object { $_.Kind -eq 'delete' }).Count | Should -Be 0
        }

        It 'resets a swapped group-set list before writing it in its new order' {
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            $pkg['optionGroupSets'][0]['optionGroups'] = @([ordered]@{ id = 'ogAAAAAAAA2' }, [ordered]@{ id = 'ogAAAAAAAA1' })
            $r = Invoke-TestDeploy $pkg
            $r.Succeeded | Should -BeTrue
            $lists = @(foreach ($c in (Get-CommitRequest)) {
                    $o = Get-PayloadObject $c 'optionGroupSets' 'gsAAAAAAAA1'
                    if ($o) { (@($o['optionGroups']) | ForEach-Object { $_['id'] }) -join ',' }
                })
            $lists | Should -Be @('ogAAAAAAAA1,ogAAAAAAAA2', '', 'ogAAAAAAAA2,ogAAAAAAAA1') -Because 'R1 keeps the live list, the reset empties it, R2 writes the new one'
            @((Get-FakeObject 'optionGroupSets' 'gsAAAAAAAA1')['optionGroups'] | ForEach-Object { $_['id'] }) | Should -Be @('ogAAAAAAAA2', 'ogAAAAAAAA1')
        }

        It 'stops before R2 when the read-back of a reset group set holds no list of groups' {
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            $pkg['optionGroupSets'][0]['optionGroups'] = @([ordered]@{ id = 'ogAAAAAAAA2' }, [ordered]@{ id = 'ogAAAAAAAA1' })
            $script:Fake.NoList = { param($q) $q.Path -eq 'api/optionGroupSets/gsAAAAAAAA1' }
            $err = $null
            try { Invoke-TestDeploy $pkg } catch { $err = $_ }
            $err.Exception.Message | Should -BeLike "*Reading option group set gsAAAAAAAA1 back after its reset returned no 'optionGroups' list*"
            (Get-CommitRequest).Count | Should -Be 2 -Because 'R1 and the reset are written, R2 is not'
        }

        It 'stops when the read-back of a parent whose dropped child has no endpoint holds no list of its children' {
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            (Get-FakeObject 'programStages' 'psAAAAAAAA1')['programStageDataElements'] = @(@{ id = 'sdAAAAAAAA1'; dataElement = @{ id = 'deAAAAAAAA1' } })
            $script:Fake.NoList = { param($q) $q.Path -eq 'api/programStages/psAAAAAAAA1' -and (@($q.Fields) -join ',') -ceq 'programStageDataElements[id]' }
            $err = $null
            try { Invoke-TestDeploy $pkg @{ Delete = @{ programStageDataElements = @('sdAAAAAAAA1') } } } catch { $err = $_ }
            $err.Exception.Message | Should -BeLike "*R1 read-back: reading programStages psAAAAAAAA1 back returned no 'programStageDataElements' list*"
        }

        It 'resets a group set that loses an interior group, whose later groups one write would shift onto rows that still hold them' {
            $pkg = New-TestPackage
            foreach ($n in 4, 5) { $pkg['optionGroups'] += [ordered]@{ id = "ogAAAAAAAA$n"; code = "G$n"; name = "G$n"; shortName = "G$n"; optionSet = [ordered]@{ id = 'osAAAAAAAA1' } } }
            $pkg['optionGroupSets'][0]['optionGroups'] = @('ogAAAAAAAA1', 'ogAAAAAAAA2', 'ogAAAAAAAA4', 'ogAAAAAAAA5' | ForEach-Object { [ordered]@{ id = $_ } })
            Set-FakeFromPackage $pkg
            $pkg['optionGroupSets'][0]['optionGroups'] = @('ogAAAAAAAA1', 'ogAAAAAAAA4', 'ogAAAAAAAA5' | ForEach-Object { [ordered]@{ id = $_ } })
            $r = Invoke-TestDeploy $pkg
            $r.Succeeded | Should -BeTrue
            $lists = @(foreach ($c in (Get-CommitRequest)) {
                    $o = Get-PayloadObject $c 'optionGroupSets' 'gsAAAAAAAA1'
                    if ($o) { (@($o['optionGroups']) | ForEach-Object { $_['id'] }) -join ',' }
                })
            $lists | Should -Be @('ogAAAAAAAA1,ogAAAAAAAA2,ogAAAAAAAA4,ogAAAAAAAA5', '', 'ogAAAAAAAA1,ogAAAAAAAA4,ogAAAAAAAA5')
            @((Get-FakeObject 'optionGroupSets' 'gsAAAAAAAA1')['optionGroups'] | ForEach-Object { $_['id'] }) | Should -Be @('ogAAAAAAAA1', 'ogAAAAAAAA4', 'ogAAAAAAAA5')
        }

        It 'resets a group set that loses a group to another set, and gives the gaining set its list in R2' {
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            $pkg['optionGroupSets'][0]['optionGroups'] = @([ordered]@{ id = 'ogAAAAAAAA1' })
            $pkg['optionGroupSets'][1]['optionGroups'] = @([ordered]@{ id = 'ogAAAAAAAA3' }, [ordered]@{ id = 'ogAAAAAAAA2' })
            $r = Invoke-TestDeploy $pkg
            $r.Succeeded | Should -BeTrue
            $commits = Get-CommitRequest
            $commits.Count | Should -Be 3
            $first = @($commits[0].Payload['optionGroupSets'])
            @($first[0]['optionGroups'] | ForEach-Object { $_['id'] }) | Should -Be @('ogAAAAAAAA1', 'ogAAAAAAAA2') -Because 'R1 keeps the live list'
            @($first[1]['optionGroups'] | ForEach-Object { $_['id'] }) | Should -Be @('ogAAAAAAAA3') -Because 'in R1 the moving group still belongs to its old set'
            @(@($commits[1].Payload['optionGroupSets'])[0]['optionGroups']).Count | Should -Be 0 -Because 'the losing set is reset'
            $final = @($commits[2].Payload['optionGroupSets'])
            @($final | ForEach-Object { $_['id'] }) | Should -Be @('gsAAAAAAAA1', 'gsAAAAAAAA2')
            @($final[1]['optionGroups'] | ForEach-Object { $_['id'] }) | Should -Be @('ogAAAAAAAA3', 'ogAAAAAAAA2')
        }

        It 'expects an existing set to move by the number of options created in it, and writes a changed option with its set' {
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            $pkg['options'] += [ordered]@{ id = 'opAAAAAAAA3'; code = '3'; name = 'Three'; sortOrder = 3; optionSet = [ordered]@{ id = 'osAAAAAAAA1' } }
            $pkg['options'] += [ordered]@{ id = 'opAAAAAAAA4'; code = '4'; name = 'Four'; sortOrder = 4; optionSet = [ordered]@{ id = 'osAAAAAAAA1' } }
            $pkg['optionSets'][0]['options'] += [ordered]@{ id = 'opAAAAAAAA3' }
            $pkg['optionSets'][0]['options'] += [ordered]@{ id = 'opAAAAAAAA4' }
            $r = Invoke-TestDeploy $pkg
            $r.Succeeded | Should -BeTrue
            $set = @($r.Versions | Where-Object Type -eq 'optionSets')[0]
            $set.Expected | Should -Be 4 -Because 'two options created in the set move its version twice'
            $set.Stored | Should -Be 4
            Reset-FakeDhis2
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            $pkg['options'][0]['name'] = 'Renamed'
            $r = Invoke-TestDeploy $pkg @{ AllowHazard = @('OptionNameChange') }
            $r.Succeeded | Should -BeTrue
            @((Get-CommitRequest)[0].Payload.Keys) | Should -Be @('optionSets', 'options') -Because 'only the set''s write renumbers its options'
            (Get-FakeObject 'optionSets' 'osAAAAAAAA1')['version'] | Should -Be 3
        }

        It 'empties a live-only option group before its delete, keeps its options, and moves the program version in a delete-only deployment' {
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            Set-FakeObject 'optionGroups' @{ id = 'ogAAAAAAAA9'; code = 'G9'; name = 'G9'; shortName = 'G9'; optionSet = @{ id = 'osAAAAAAAA1' }; options = @(@{ id = 'opAAAAAAAA1' }, @{ id = 'opAAAAAAAA2' }) }
            $r = Invoke-TestDeploy $pkg @{ Delete = @{ optionGroups = @('ogAAAAAAAA9') } }
            $r.Succeeded | Should -BeTrue
            $put = Get-RequestIndex { param($q) $q.Kind -eq 'put' -and $q.Path -eq 'api/optionGroups/ogAAAAAAAA9/options' }
            $delete = Get-RequestIndex { param($q) $q.Kind -eq 'delete' -and $q.Id -eq 'ogAAAAAAAA9' }
            $put.Count | Should -Be 1
            $delete.Count | Should -Be 1
            $put[0] | Should -BeLessThan $delete[0] -Because 'a group''s DELETE deletes the options it still holds'
            Get-FakeObject 'optionGroups' 'ogAAAAAAAA9' | Should -BeNullOrEmpty
            Get-FakeObject 'options' 'opAAAAAAAA1' | Should -Not -BeNullOrEmpty
            Get-FakeObject 'options' 'opAAAAAAAA2' | Should -Not -BeNullOrEmpty
            $commits = Get-CommitRequest
            $commits.Count | Should -Be 1
            @($commits[0].Payload.Keys) | Should -Be @('programs')
            $delete[0] | Should -BeLessThan (Get-RequestIndex { param($q) $q.Mode -eq 'COMMIT' })[0] -Because 'the program is written last'
            (Get-FakeObject 'programs' 'prAAAAAAAA1')['version'] | Should -Be 6
        }

        It 'takes an option group out of its set before emptying and deleting it' {
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            $pkg['optionGroupSets'][0]['optionGroups'] = @([ordered]@{ id = 'ogAAAAAAAA2' })
            $pkg['optionGroups'] = @($pkg['optionGroups'][1], $pkg['optionGroups'][2])
            $r = Invoke-TestDeploy $pkg @{ Delete = @{ optionGroups = @('ogAAAAAAAA1') } }
            $r.Succeeded | Should -BeTrue
            $left = Get-RequestIndex { param($q) $q.Mode -eq 'COMMIT' -and (Get-PayloadObject $q 'optionGroupSets' 'gsAAAAAAAA1') -and
                (@((Get-PayloadObject $q 'optionGroupSets' 'gsAAAAAAAA1')['optionGroups'] | ForEach-Object { $_['id'] }) -join ',') -eq 'ogAAAAAAAA2' }
            $put = Get-RequestIndex { param($q) $q.Kind -eq 'put' }
            $left.Count | Should -Be 1
            $left[0] | Should -BeLessThan $put[0]
            Get-FakeObject 'optionGroups' 'ogAAAAAAAA1' | Should -BeNullOrEmpty
            Get-FakeObject 'options' 'opAAAAAAAA1' | Should -Not -BeNullOrEmpty
        }

        It 'deletes an option set and its options only when OptionSetMembership is acknowledged, reading both back' {
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            Set-FakeObject 'optionSets' @{ id = 'osAAAAAAAA9'; code = 'OS9'; name = 'Old set'; valueType = 'TEXT'; version = 1; options = @(@{ id = 'opAAAAAAAA9' }) }
            Set-FakeObject 'options' @{ id = 'opAAAAAAAA9'; code = '9'; name = 'Nine'; sortOrder = 1; optionSet = @{ id = 'osAAAAAAAA9' } }
            { Invoke-TestDeploy $pkg @{ Delete = @{ optionSets = @('osAAAAAAAA9') } } } | Should -Throw '*Unacknowledged hazard(s): OptionSetMembership*'
            @($script:Fake.Requests | Where-Object { $_.Kind -eq 'delete' }).Count | Should -Be 0
            $r = Invoke-TestDeploy $pkg @{ Delete = @{ optionSets = @('osAAAAAAAA9') }; AllowHazard = @('OptionSetMembership') }
            $r.Succeeded | Should -BeTrue
            Get-FakeObject 'optionSets' 'osAAAAAAAA9' | Should -BeNullOrEmpty
            $r.Deleted.Contains('optionSets|osAAAAAAAA9') | Should -BeTrue
            $r.Deleted.Contains('options|opAAAAAAAA9') | Should -BeTrue
        }

        It 'refuses before any write to delete an option set one of whose options a <Holder> holds as a data dimension item, from 2.42 only' -ForEach @(
            @{ Holder = 'visualization'; Type = 'visualizations'; Item = @{ dataDimensionItemType = 'PROGRAM_DATA_ELEMENT_OPTION'; programDataElementOption = @{ option = @{ id = 'opAAAAAAAA9' } } } }
            @{ Holder = 'map view'; Type = 'mapViews'; Item = @{ dataDimensionItemType = 'PROGRAM_ATTRIBUTE_OPTION'; programAttributeOption = @{ option = @{ id = 'opAAAAAAAA9' } } } }
        ) {
            $script:Fake.Version = '2.42.6'
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            Set-FakeObject 'optionSets' @{ id = 'osAAAAAAAA9'; code = 'OS9'; name = 'Old set'; valueType = 'TEXT'; version = 1; options = @(@{ id = 'opAAAAAAAA9' }) }
            Set-FakeObject 'options' @{ id = 'opAAAAAAAA9'; code = '9'; name = 'Nine'; sortOrder = 1; optionSet = @{ id = 'osAAAAAAAA9' } }
            Set-FakeObject $Type @{ id = 'vzAAAAAAAA9'; name = 'Counts'; dataDimensionItems = @($Item) }
            $delete = @{ Delete = @{ optionSets = @('osAAAAAAAA9') }; AllowHazard = @('OptionSetMembership') }
            { Invoke-TestDeploy $pkg $delete } | Should -Throw "*$Type vzAAAAAAAA9 ('Counts') holds options opAAAAAAAA9 as a data dimension item*Nothing was written*"
            (Get-CommitRequest).Count | Should -Be 0
            @($script:Fake.Requests | Where-Object { $_.Kind -eq 'delete' }).Count | Should -Be 0
            # Before 2.42 no data dimension item holds an option, and none is read.
            $script:Fake.Version = '2.41.10'
            $script:Fake.ThrowGet = { param($q) $q.Path -in 'api/visualizations', 'api/mapViews' }
            (Invoke-TestDeploy $pkg $delete).Succeeded | Should -BeTrue
        }

        It 'refuses before any request a -Delete type whose referrers it does not check (<Type>)' -ForEach @(
            @{ Type = 'dataElements'; Id = 'deAAAAAAAA1' }
            @{ Type = 'organisationUnits'; Id = 'ouAAAAAAAA1' }
            @{ Type = 'programIndicators'; Id = 'piAAAAAAAA1' }
            @{ Type = 'attributes'; Id = 'atAAAAAAAA9' }
        ) {
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            { Invoke-TestDeploy $pkg @{ Delete = @{ $Type = @($Id) } } } | Should -Throw "*-Delete names '$Type'. A deployment deletes only *, whose referrers it checks before its first write*Delete it outside the deployment*"
            $script:Fake.Requests.Count | Should -Be 0
        }

        It 'fails the run when a DELETE answers 200 but the object is still there' {
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            $pkg['optionGroupSets'][1]['optionGroups'] = @()
            $pkg['optionGroups'] = @($pkg['optionGroups'][0], $pkg['optionGroups'][1])
            [void]$script:Fake.DeleteKeeps.Add('optionGroups|ogAAAAAAAA3')
            { Invoke-TestDeploy $pkg @{ Delete = @{ optionGroups = @('ogAAAAAAAA3') } } } | Should -Throw '*left 1 object(s) in place*'
        }

        It 'refuses to delete a rule that is still active, and deletes it with its actions once inert' {
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            $without = Copy-Value $pkg
            $without['programRules'] = @($without['programRules'][0])
            $without['programRuleActions'] = @($without['programRuleActions'][0], $without['programRuleActions'][2])
            { Invoke-TestDeploy $without @{ Delete = @{ programRules = @('ruAAAAAAAA2') } } } | Should -Throw '*Unacknowledged hazard(s): ActiveRuleDelete*'
            @($script:Fake.Requests | Where-Object { $_.Kind -eq 'delete' }).Count | Should -Be 0
            $inert = Get-FakeObject 'programRules' 'ruAAAAAAAA2'; $inert['condition'] = 'false'; $inert['programRuleActions'] = @()
            [void](Get-FakeType 'programRuleActions').Remove('raAAAAAAAA2')
            $r = Invoke-TestDeploy $without @{ Delete = @{ programRules = @('ruAAAAAAAA2') } }
            $r.Succeeded | Should -BeTrue
            Get-FakeObject 'programRules' 'ruAAAAAAAA2' | Should -BeNullOrEmpty
            @((Get-CommitRequest)[-1].Payload.Keys) | Should -Be @('programs') -Because 'clients reload rules only when the program version moves'
        }

        It 'deletes an active rule with its actions when ActiveRuleDelete is acknowledged' {
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            $pkg['programRules'] = @($pkg['programRules'][0])
            $pkg['programRuleActions'] = @($pkg['programRuleActions'][0], $pkg['programRuleActions'][2])
            $r = Invoke-TestDeploy $pkg @{ Delete = @{ programRules = @('ruAAAAAAAA2') }; AllowHazard = @('ActiveRuleDelete') }
            $r.Succeeded | Should -BeTrue
            @($r.Hazards | Where-Object Kind -eq 'ActiveRuleDelete').Count | Should -Be 1
            @($script:Fake.Requests | Where-Object { $_.Kind -eq 'delete' } | ForEach-Object { "$($_.Type)|$($_.Id)" }) | Should -Be @('programRules|ruAAAAAAAA2')
            Get-FakeObject 'programRuleActions' 'raAAAAAAAA2' | Should -BeNullOrEmpty
            $r.Deleted.Contains('programRuleActions|raAAAAAAAA2') | Should -BeTrue -Because 'the rule''s actions are read back as gone'
            @((Get-CommitRequest)[-1].Payload.Keys) | Should -Be @('programs')
        }

        It 'names the programs whose version a failed run left unmoved, and moves it with -BumpProgramVersion later' {
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            Set-FakeObject 'optionGroups' @{ id = 'ogAAAAAAAA9'; code = 'G9'; name = 'G9'; shortName = 'G9'; optionSet = @{ id = 'osAAAAAAAA1' } }
            [void]$script:Fake.DeleteKeeps.Add('optionGroups|ogAAAAAAAA9')
            $pkg['dataElements'][0]['name'] = 'Changed'
            $err = $null
            try { Invoke-TestDeploy $pkg @{ Delete = @{ optionGroups = @('ogAAAAAAAA9') } } } catch { $err = $_ }
            $err.Exception.Message | Should -BeLike '*left 1 object(s) in place*deploy again with -BumpProgramVersion.'
            @($err.TargetObject.ProgramVersionPending) | Should -Be @('prAAAAAAAA1')
            (Get-FakeObject 'dataElements' 'deAAAAAAAA1')['name'] | Should -Be 'Changed' -Because 'R1 committed before the delete failed'
            (Get-FakeObject 'programs' 'prAAAAAAAA1')['version'] | Should -Be 5
            $script:Fake.DeleteKeeps.Clear()
            $again = Invoke-TestDeploy $pkg
            $again.Written.Count | Should -Be 0
            (Get-FakeObject 'programs' 'prAAAAAAAA1')['version'] | Should -Be 5 -Because 'a run that finds nothing to write leaves the version where the failed run left it'
            $script:Fake.FailImport = { param($p) $p.Contains('programs') }
            $err = $null
            try { Invoke-TestDeploy $pkg @{ BumpProgramVersion = $true } } catch { $err = $_ }
            @($err.TargetObject.ProgramVersionPending) | Should -Be @('prAAAAAAAA1') -Because 'a run asked to move the version that fails before it does leaves it pending'
            $script:Fake.FailImport = $null
            $gated = Copy-Value $pkg
            $gated['options'][0]['code'] = 'one'
            $err = $null
            try { Invoke-TestDeploy $gated @{ BumpProgramVersion = $true } } catch { $err = $_ }
            $err.Exception.Message | Should -BeLike '*Unacknowledged hazard(s): OptionCodeChange*'
            @($err.TargetObject.ProgramVersionPending) | Should -Be @('prAAAAAAAA1') -Because 'a run stopped before it plans the programs leaves them pending too'
            $bumped = Invoke-TestDeploy $pkg @{ BumpProgramVersion = $true }
            $bumped.Succeeded | Should -BeTrue
            (Get-FakeObject 'programs' 'prAAAAAAAA1')['version'] | Should -Be 6
        }

        It 'ends with the summary when a read fails in transport after the writes' {
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            $pkg['dataElements'][0]['name'] = 'Changed'
            # The served-actions check reads every rule's actions in one request.
            $script:Fake.ThrowGet = { param($Read) $Read.Path -eq 'api/programRules' -and -not $Read.Filter }
            $err = $null
            try { Invoke-TestDeploy $pkg } catch { $err = $_ }
            $err.FullyQualifiedErrorId | Should -BeLike 'NeoIPCDeploymentFailed*'
            $err.Exception.Message | Should -BeLike '*wrote its changes, but verifying them failed*SSL connection*'
            $err.TargetObject.Written.Contains('dataElements|deAAAAAAAA1') | Should -BeTrue
        }

        It 'returns the plan and the objects present only on the instance from a dry run that the hazard gate stops' {
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            Set-FakeObject 'dataElements' @{ id = 'deAAAAAAAA9'; code = 'DE9'; name = 'Live only'; shortName = 'DE9'; valueType = 'TEXT'; domainType = 'TRACKER'; aggregationType = 'NONE' }
            $pkg['options'][0]['code'] = 'one'
            $err = $null
            try { Invoke-TestDeploy $pkg @{ DryRun = $true } } catch { $err = $_ }
            $err.Exception.Message | Should -BeLike '*Unacknowledged hazard(s): OptionCodeChange*'
            @($err.TargetObject.Plan | Where-Object Type -eq 'options')[0].Changed | Should -Be 1
            @($err.TargetObject.LiveOnly | Where-Object Type -eq 'dataElements')[0].Sample | Should -BeLike '*deAAAAAAAA9 DE9*'
        }

        It 'skips a -Delete entry that is already absent, and writes no program for it' {
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            $r = Invoke-TestDeploy $pkg @{ Delete = @{ optionGroups = @('ogAAAAAAAA9') } }
            $r.Succeeded | Should -BeTrue
            @($r.Steps | Where-Object Name -eq 'delete optionGroups ogAAAAAAAA9')[0].Status | Should -Be 'Skipped'
            (Get-CommitRequest).Count | Should -Be 0
            (Get-FakeObject 'programs' 'prAAAAAAAA1')['version'] | Should -Be 5
        }

        It 'lists the objects present only on the instance in a dry run, leaving out those the run deletes' {
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            Set-FakeObject 'dataElements' @{ id = 'deAAAAAAAA9'; code = 'DE9'; name = 'Live only'; shortName = 'DE9'; valueType = 'TEXT'; domainType = 'TRACKER'; aggregationType = 'NONE' }
            Set-FakeObject 'optionGroups' @{ id = 'ogAAAAAAAA9'; code = 'G9'; name = 'G9'; shortName = 'G9'; optionSet = @{ id = 'osAAAAAAAA1' } }
            $r = Invoke-TestDeploy $pkg @{ DryRun = $true; Delete = @{ optionGroups = @('ogAAAAAAAA9') } }
            $r.Succeeded | Should -BeTrue
            $de = @($r.LiveOnly | Where-Object Type -eq 'dataElements')
            $de.Count | Should -Be 1
            $de[0].Count | Should -Be 1
            $de[0].Sample | Should -BeLike '*deAAAAAAAA9 DE9*'
            @($r.LiveOnly | Where-Object Type -eq 'optionGroups').Count | Should -Be 0 -Because 'the run deletes it'
        }

        It 'validates every object once in a dry run, deleting and committing nothing' {
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            $pkg['dataElements'][0]['name'] = 'Changed'
            $pkg['optionGroupSets'][0]['optionGroups'] = @([ordered]@{ id = 'ogAAAAAAAA2' })
            $pkg['optionGroups'] = @($pkg['optionGroups'][1], $pkg['optionGroups'][2])
            $r = Invoke-TestDeploy $pkg @{ DryRun = $true; Delete = @{ optionGroups = @('ogAAAAAAAA1') } }
            $r.Succeeded | Should -BeTrue
            $validate = @($script:Fake.Requests | Where-Object { $_.Kind -eq 'metadata' })
            $validate.Count | Should -Be 1
            $validate[0].Mode | Should -Be 'VALIDATE'
            $keys = @(foreach ($t in $validate[0].Payload.Keys) { foreach ($o in $validate[0].Payload[$t]) { "$t|$($o['id'])" } })
            $keys | Should -Contain 'optionGroupSets|gsAAAAAAAA1'
            $keys | Should -Contain 'programs|prAAAAAAAA1'
            @($keys | Group-Object | Where-Object Count -gt 1).Count | Should -Be 0 -Because 'each object appears once'
            @((@($validate[0].Payload['optionGroupSets']) | Where-Object { $_['id'] -eq 'gsAAAAAAAA1' })['optionGroups'] | ForEach-Object { $_['id'] }) | Should -Be @('ogAAAAAAAA2') -Because 'the final list is validated'
            @($script:Fake.Requests | Where-Object { $_.Kind -in 'delete', 'put' }).Count | Should -Be 0
            Get-FakeObject 'optionGroups' 'ogAAAAAAAA1' | Should -Not -BeNullOrEmpty
        }

        It 'asks before clearing the caches for a dry run; declined, it sends nothing but still plans and gates hazards' {
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            $pkg['dataElements'][0]['name'] = 'Changed'
            # -WhatIf declines every confirmation; a cache clear sent without asking would still reach the fake.
            $r = Deploy-NeoIPCMetadata -Json ($pkg | ConvertTo-Json -Depth 100 -Compress) -Auth @{ AuthType = 'Basic' } -Hostname 'dhis2.example.org' -DryRun -WhatIf 6>$null
            @($script:Fake.Requests | Where-Object { $_.Kind -in 'cacheClear', 'metadata', 'put', 'delete' }).Count | Should -Be 0
            @($r.Steps | Where-Object Name -eq 'cache clear')[0].Status | Should -Be 'Skipped'
            @($r.Plan | Where-Object Type -eq 'dataElements')[0].Changed | Should -Be 1
            $pkg['options'][0]['code'] = 'one'
            { Deploy-NeoIPCMetadata -Json ($pkg | ConvertTo-Json -Depth 100 -Compress) -Auth @{ AuthType = 'Basic' } -Hostname 'dhis2.example.org' -DryRun -WhatIf 6>$null } |
                Should -Throw '*Unacknowledged hazard(s): OptionCodeChange*'
        }

        It 'refuses before any write a child the package carries that DHIS2 deletes with a -Delete entry, under no parent it keeps or moved to one' {
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            Set-FakeObject 'optionSets' @{ id = 'osAAAAAAAA9'; code = 'OS9'; name = 'Old set'; valueType = 'TEXT'; version = 1; options = @(@{ id = 'opAAAAAAAA9' }) }
            Set-FakeObject 'options' @{ id = 'opAAAAAAAA9'; code = '9'; name = 'Nine'; sortOrder = 1; optionSet = @{ id = 'osAAAAAAAA9' } }
            $delete = @{ Delete = @{ optionSets = @('osAAAAAAAA9') }; AllowHazard = @('OptionSetMembership') }
            $pkg['options'] += [ordered]@{ id = 'opAAAAAAAA9'; code = '9'; name = 'Nine'; sortOrder = 1; optionSet = [ordered]@{ id = 'osAAAAAAAA9' } }
            { Invoke-TestDeploy $pkg $delete } | Should -Throw '*The package carries options opAAAAAAAA9, which DHIS2 deletes with optionSets osAAAAAAAA9*'
            (Get-CommitRequest).Count | Should -Be 0
            # Moved to the end of a set the package keeps: no probe covered a move out of a parent that is deleted.
            $pkg['options'][-1]['optionSet'] = [ordered]@{ id = 'osAAAAAAAA1' }
            $pkg['optionSets'][0]['options'] = @($pkg['optionSets'][0]['options']) + @([ordered]@{ id = 'opAAAAAAAA9' })
            { Invoke-TestDeploy $pkg $delete } | Should -Throw '*moves options opAAAAAAAA9 from optionSets osAAAAAAAA9, which -Delete deletes, to optionSets osAAAAAAAA1*'
            (Get-CommitRequest).Count | Should -Be 0
            @($script:Fake.Requests | Where-Object { $_.Kind -in 'put', 'delete' }).Count | Should -Be 0
            (Get-FakeObject 'options' 'opAAAAAAAA9')['optionSet']['id'] | Should -Be 'osAAAAAAAA9'
        }

        It 'moves an action to another rule on <Version>: R1 writes it with its new rule, and R2 the rule it leaves' -ForEach @(
            @{ Version = '2.40.12' }
            @{ Version = '2.43.1' }
        ) {
            $script:Fake.Version = $Version
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            $pkg['programRules'][0]['programRuleActions'] = @([ordered]@{ id = 'raAAAAAAAA3' })
            $pkg['programRules'][1]['programRuleActions'] = @([ordered]@{ id = 'raAAAAAAAA2' }, [ordered]@{ id = 'raAAAAAAAA1' })
            $pkg['programRuleActions'][0]['programRule'] = [ordered]@{ id = 'ruAAAAAAAA2' }
            $r = Invoke-TestDeploy $pkg
            $r.Succeeded | Should -BeTrue
            @($r.Hazards).Count | Should -Be 0 -Because 'a moved action is no orphan of the rule it leaves'
            @($r.Moved | ForEach-Object { "$($_.Type) $($_.Id): $($_.From) -> $($_.To)" }) | Should -Be @('programRuleActions raAAAAAAAA1: programRules|ruAAAAAAAA1 -> programRules|ruAAAAAAAA2')
            $gain = Get-RequestIndex { param($q) $q.Mode -eq 'COMMIT' -and (Get-PayloadObject $q 'programRules' 'ruAAAAAAAA2') -and (Get-PayloadObject $q 'programRuleActions' 'raAAAAAAAA1') }
            $give = Get-RequestIndex { param($q) $q.Mode -eq 'COMMIT' -and (Get-PayloadObject $q 'programRules' 'ruAAAAAAAA1') }
            $gain.Count | Should -Be 1
            $give.Count | Should -Be 1
            $give[0] | Should -BeGreaterThan $gain[0] -Because 'DHIS2 2.40.12 fails a request that writes both rules of a moved action'
            (Get-FakeObject 'programRuleActions' 'raAAAAAAAA1')['programRule']['id'] | Should -Be 'ruAAAAAAAA2'
            @((Get-FakeObject 'programRules' 'ruAAAAAAAA1')['programRuleActions'] | ForEach-Object { $_['id'] }) | Should -Be @('raAAAAAAAA3')
            @((Get-FakeObject 'programRules' 'ruAAAAAAAA2')['programRuleActions'] | ForEach-Object { $_['id'] }) | Should -Be @('raAAAAAAAA2', 'raAAAAAAAA1')
            $r.Deleted.Count | Should -Be 0
            @($script:Fake.Requests | Where-Object { $_.Kind -eq 'delete' }).Count | Should -Be 0 -Because 'the parents move the action; DHIS2 2.40.12 refuses its own DELETE'
            $clear = @(Get-RequestIndex { param($q) $q.Kind -eq 'cacheClear' })
            @($clear | Where-Object { $_ -gt $gain[0] -and $_ -lt $give[0] }).Count | Should -Be 1 -Because 'R2 must read the rule the action leaves from the database'
        }

        It 'moves a section that a HIDESECTION action targets to another stage, writing the stage it leaves in R2' {
            $pkg = New-TestPackage
            Add-TestStage $pkg
            Set-FakeFromPackage $pkg
            $pkg['programStages'][0]['programStageSections'] = @([ordered]@{ id = 'ssAAAAAAAA1' })
            $pkg['programStages'][1]['programStageSections'] = @([ordered]@{ id = 'ssAAAAAAAA2' })
            $pkg['programStageSections'][1]['programStage'] = [ordered]@{ id = 'psAAAAAAAA2' }
            $r = Invoke-TestDeploy $pkg
            $r.Succeeded | Should -BeTrue
            @($r.Hazards).Count | Should -Be 0
            $gain = Get-RequestIndex { param($q) $q.Mode -eq 'COMMIT' -and (Get-PayloadObject $q 'programStages' 'psAAAAAAAA2') -and (Get-PayloadObject $q 'programStageSections' 'ssAAAAAAAA2') }
            $give = Get-RequestIndex { param($q) $q.Mode -eq 'COMMIT' -and (Get-PayloadObject $q 'programStages' 'psAAAAAAAA1') }
            $gain.Count | Should -Be 1
            $give.Count | Should -Be 1
            $give[0] | Should -BeGreaterThan $gain[0]
            (Get-FakeObject 'programStageSections' 'ssAAAAAAAA2')['programStage']['id'] | Should -Be 'psAAAAAAAA2'
            @((Get-FakeObject 'programStages' 'psAAAAAAAA1')['programStageSections'] | ForEach-Object { $_['id'] }) | Should -Be @('ssAAAAAAAA1')
            @((Get-FakeObject 'programStages' 'psAAAAAAAA2')['programStageSections'] | ForEach-Object { $_['id'] }) | Should -Be @('ssAAAAAAAA2')
            (Get-RequestIndex { param($q) $q.Mode -eq 'COMMIT' -and (Get-PayloadObject $q 'programRuleActions' 'raAAAAAAAA3') }).Count | Should -Be 0 -Because 'the action still targets the section, which stays'
            $r.Deleted.Count | Should -Be 0
            @($script:Fake.Requests | Where-Object { $_.Kind -eq 'delete' }).Count | Should -Be 0 -Because 'the stages move the section; from 2.41.10 its own DELETE keeps it'
        }

        It 'moves a notification template an action sends to another stage on <Version>, writing the stage it leaves in R2' -ForEach @(
            @{ Version = '2.40.12' }
            @{ Version = '2.43.1' }
        ) {
            $script:Fake.Version = $Version
            $pkg = New-TestPackage
            Add-TestStage $pkg
            $pkg['programStages'][0]['notificationTemplates'] = @([ordered]@{ id = 'ntAAAAAAAA1' })
            Set-FakeFromPackage $pkg
            $pkg['programStages'][0].Remove('notificationTemplates')
            $pkg['programStages'][1]['notificationTemplates'] = @([ordered]@{ id = 'ntAAAAAAAA1' })
            $r = Invoke-TestDeploy $pkg
            $r.Succeeded | Should -BeTrue
            @($r.Hazards).Count | Should -Be 0
            $gain = Get-RequestIndex { param($q) $q.Mode -eq 'COMMIT' -and (Get-PayloadObject $q 'programStages' 'psAAAAAAAA2') }
            $give = Get-RequestIndex { param($q) $q.Mode -eq 'COMMIT' -and (Get-PayloadObject $q 'programStages' 'psAAAAAAAA1') }
            $give[0] | Should -BeGreaterThan $gain[0] -Because 'DHIS2 2.40.12 fails a request that writes both stages of a moved template'
            Get-FakeObject 'programNotificationTemplates' 'ntAAAAAAAA1' | Should -Not -BeNullOrEmpty
            @((Get-FakeObject 'programStages' 'psAAAAAAAA2')['notificationTemplates'] | ForEach-Object { $_['id'] }) | Should -Be @('ntAAAAAAAA1')
            @((Get-FakeObject 'programStages' 'psAAAAAAAA1')['notificationTemplates'] | Where-Object { $_ }).Count | Should -Be 0
            (Get-FakeObject 'programRuleActions' 'raAAAAAAAA2')['templateUid'] | Should -Be 'ntAAAAAAAA1'
            @($script:Fake.Requests | Where-Object { $_.Kind -eq 'delete' }).Count | Should -Be 0
        }

        It 'moves an action that sends a notification to another rule up to 2.41' {
            $script:Fake.Version = '2.41.10'
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            $pkg['programRules'][0]['programRuleActions'] = @([ordered]@{ id = 'raAAAAAAAA1' }, [ordered]@{ id = 'raAAAAAAAA3' }, [ordered]@{ id = 'raAAAAAAAA2' })
            $pkg['programRules'][1]['programRuleActions'] = @()
            $pkg['programRuleActions'][1]['programRule'] = [ordered]@{ id = 'ruAAAAAAAA1' }
            $r = Invoke-TestDeploy $pkg
            $r.Succeeded | Should -BeTrue
            (Get-FakeObject 'programRuleActions' 'raAAAAAAAA2')['programRule']['id'] | Should -Be 'ruAAAAAAAA1'
            @((Get-FakeObject 'programRules' 'ruAAAAAAAA2')['programRuleActions'] | Where-Object { $_ }).Count | Should -Be 0
        }

        It 'keeps a rule that gives an action away listing it in the detach request, and writes the rule in R2' {
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            # The stage drops the section raAAAAAAAA3 targets and the package points the action elsewhere, so its rule
            # is detached; the same rule gives raAAAAAAAA1 to the other rule.
            $pkg['programStages'][0]['programStageSections'] = @([ordered]@{ id = 'ssAAAAAAAA1' })
            $pkg['programStageSections'] = @($pkg['programStageSections'][0])
            $pkg['programRuleActions'][2]['programStageSection'] = [ordered]@{ id = 'ssAAAAAAAA1' }
            $pkg['programRules'][0]['programRuleActions'] = @([ordered]@{ id = 'raAAAAAAAA3' })
            $pkg['programRules'][1]['programRuleActions'] = @([ordered]@{ id = 'raAAAAAAAA2' }, [ordered]@{ id = 'raAAAAAAAA1' })
            $pkg['programRuleActions'][0]['programRule'] = [ordered]@{ id = 'ruAAAAAAAA2' }
            $r = Invoke-TestDeploy $pkg @{ Delete = @{ programStageSections = @('ssAAAAAAAA2') } }
            $r.Succeeded | Should -BeTrue
            $commits = Get-CommitRequest
            @($commits[0].Payload.Keys) | Should -Be @('programRules')
            @((Get-PayloadObject $commits[0] 'programRules' 'ruAAAAAAAA1')['programRuleActions'] | ForEach-Object { $_['id'] }) | Should -Be @('raAAAAAAAA1') -Because 'the detach request lets go of the action that targets the dropped section, and keeps the one R1 moves'
            Get-PayloadObject $commits[1] 'programRules' 'ruAAAAAAAA1' | Should -BeNullOrEmpty -Because 'the rule it leaves is written once the action has moved'
            Get-PayloadObject $commits[1] 'programRules' 'ruAAAAAAAA2' | Should -Not -BeNullOrEmpty
            (Get-RequestIndex { param($q) $q.Mode -eq 'COMMIT' -and (Get-PayloadObject $q 'programRules' 'ruAAAAAAAA1') }).Count | Should -Be 2
            (Get-FakeObject 'programRuleActions' 'raAAAAAAAA1')['programRule']['id'] | Should -Be 'ruAAAAAAAA2'
            @((Get-FakeObject 'programRules' 'ruAAAAAAAA1')['programRuleActions'] | ForEach-Object { $_['id'] }) | Should -Be @('raAAAAAAAA3')
            (Get-FakeObject 'programRuleActions' 'raAAAAAAAA3')['programStageSection']['id'] | Should -Be 'ssAAAAAAAA1'
        }

        It 'reads a child dropped by a rule that gives another one away back as gone after R2' {
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            $pkg['programRules'][0]['programRuleActions'] = @()
            $pkg['programRules'][1]['programRuleActions'] = @([ordered]@{ id = 'raAAAAAAAA2' }, [ordered]@{ id = 'raAAAAAAAA1' })
            $pkg['programRuleActions'][0]['programRule'] = [ordered]@{ id = 'ruAAAAAAAA2' }
            $pkg['programRuleActions'] = @($pkg['programRuleActions'][0], $pkg['programRuleActions'][1])
            $r = Invoke-TestDeploy $pkg @{ Delete = @{ programRuleActions = @('raAAAAAAAA3') } }
            $r.Succeeded | Should -BeTrue
            @($r.Steps | Where-Object { $_.Name -eq 'R2 read-back' } | ForEach-Object { $_.Status }) | Should -Be @('OK')
            @($r.Steps | Where-Object { $_.Name -eq 'R1 read-back' }).Count | Should -Be 0 -Because 'the rule that drops it is written only in R2'
            Get-FakeObject 'programRuleActions' 'raAAAAAAAA3' | Should -BeNullOrEmpty
            (Get-FakeObject 'programRuleActions' 'raAAAAAAAA1')['programRule']['id'] | Should -Be 'ruAAAAAAAA2'
            $r.Deleted.Contains('programRuleActions|raAAAAAAAA3') | Should -BeTrue
        }

        It 'moves an option to another set in R1, written with both sets, and names that set in the hazard' {
            $pkg = New-TestPackage
            $pkg['optionSets'] += [ordered]@{ id = 'osAAAAAAAA2'; code = 'OS2'; name = 'Set two'; valueType = 'TEXT'; version = 1; options = @([ordered]@{ id = 'opAAAAAAAA3' }) }
            $pkg['options'] += [ordered]@{ id = 'opAAAAAAAA3'; code = '3'; name = 'Three'; sortOrder = 1; optionSet = [ordered]@{ id = 'osAAAAAAAA2' } }
            Set-FakeFromPackage $pkg
            $pkg['optionSets'][0]['options'] = @([ordered]@{ id = 'opAAAAAAAA1' })
            $pkg['optionSets'][1]['options'] = @([ordered]@{ id = 'opAAAAAAAA3' }, [ordered]@{ id = 'opAAAAAAAA2' })
            $pkg['options'][1]['optionSet'] = [ordered]@{ id = 'osAAAAAAAA2' }
            $pkg['options'][1]['sortOrder'] = 2
            { Invoke-TestDeploy $pkg } | Should -Throw '*Unacknowledged hazard(s): OptionSetMembership*'
            (Get-CommitRequest).Count | Should -Be 0
            $r = Invoke-TestDeploy $pkg @{ AllowHazard = @('OptionSetMembership') }
            $r.Succeeded | Should -BeTrue
            $h = @($r.Hazards | Where-Object { $_.Kind -eq 'OptionSetMembership' })
            $h.Count | Should -Be 1
            $h[0].Id | Should -Be 'osAAAAAAAA1'
            $h[0].Detail | Should -Be 'gives 1 option(s) to another set: opAAAAAAAA2 to osAAAAAAAA2' -Because 'the option is not left in no set'
            (Get-RequestIndex { param($q) $q.Mode -eq 'COMMIT' -and (Get-PayloadObject $q 'options' 'opAAAAAAAA2') -and (Get-PayloadObject $q 'optionSets' 'osAAAAAAAA1') -and (Get-PayloadObject $q 'optionSets' 'osAAAAAAAA2') }).Count | Should -Be 1
            (Get-FakeObject 'options' 'opAAAAAAAA2')['optionSet']['id'] | Should -Be 'osAAAAAAAA2'
            @((Get-FakeObject 'optionSets' 'osAAAAAAAA1')['options'] | ForEach-Object { $_['id'] }) | Should -Be @('opAAAAAAAA1')
            @((Get-FakeObject 'optionSets' 'osAAAAAAAA2')['options'] | ForEach-Object { $_['id'] }) | Should -Be @('opAAAAAAAA3', 'opAAAAAAAA2')
            (Get-FakeObject 'optionSets' 'osAAAAAAAA1')['version'] | Should -Be 3
            (Get-FakeObject 'optionSets' 'osAAAAAAAA2')['version'] | Should -Be 2
        }

        It 'keeps two option sets whose ids differ only in case apart: each one''s options created and checked for names' {
            # DHIS2 UIDs are case-sensitive. The second set holds an option named and coded like one of the first set's,
            # which DHIS2 allows across sets.
            $pkg = New-TestPackage
            $pkg['optionSets'] += [ordered]@{ id = 'OSAAAAAAAA1'; code = 'OS1B'; name = 'Twin set'; valueType = 'TEXT'; version = 1; options = @([ordered]@{ id = 'opBBBBBBBB1' }) }
            $pkg['options'] += [ordered]@{ id = 'opBBBBBBBB1'; code = '1'; name = 'One'; sortOrder = 1; optionSet = [ordered]@{ id = 'OSAAAAAAAA1' } }
            Set-FakeFromPackage $pkg
            $pkg['options'] += [ordered]@{ id = 'opAAAAAAAA3'; code = '3'; name = 'Three'; sortOrder = 3; optionSet = [ordered]@{ id = 'osAAAAAAAA1' } }
            $pkg['optionSets'][0]['options'] += [ordered]@{ id = 'opAAAAAAAA3' }
            $pkg['options'] += [ordered]@{ id = 'opBBBBBBBB2'; code = '2'; name = 'Two'; sortOrder = 2; optionSet = [ordered]@{ id = 'OSAAAAAAAA1' } }
            $pkg['optionSets'][1]['options'] += [ordered]@{ id = 'opBBBBBBBB2' }
            $r = Invoke-TestDeploy $pkg
            $r.Succeeded | Should -BeTrue -Because "the twin's new option clashes with no option of its own set"
            foreach ($set in @(@{ Id = 'osAAAAAAAA1'; Version = 3 }, @{ Id = 'OSAAAAAAAA1'; Version = 2 })) {
                $row = @($r.Versions | Where-Object { $_.Type -eq 'optionSets' -and $_.Id -ceq $set.Id })
                $row.Count | Should -Be 1
                "$($row[0].Expected) $($row[0].Stored)" | Should -Be "$($set.Version) $($set.Version)" -Because 'one option created in each set moves each version once'
            }
        }

        It 'names the option a set detaches apart from one it gives away whose id differs only in case' {
            $pkg = New-TestPackage
            $pkg['optionSets'] += [ordered]@{ id = 'osAAAAAAAA2'; code = 'OS2'; name = 'Set two'; valueType = 'TEXT'; version = 1; options = @([ordered]@{ id = 'opAAAAAAAA3' }) }
            $pkg['options'] += [ordered]@{ id = 'opAAAAAAAA3'; code = '3'; name = 'Three'; sortOrder = 1; optionSet = [ordered]@{ id = 'osAAAAAAAA2' } }
            $pkg['optionSets'][0]['options'] += [ordered]@{ id = 'OPAAAAAAAA2' }
            $pkg['options'] += [ordered]@{ id = 'OPAAAAAAAA2'; code = '9'; name = 'Nine'; sortOrder = 3; optionSet = [ordered]@{ id = 'osAAAAAAAA1' } }
            Set-FakeFromPackage $pkg
            # The first set gives opAAAAAAAA2 to the second set and drops OPAAAAAAAA2, which the package no longer carries.
            $pkg['optionSets'][0]['options'] = @([ordered]@{ id = 'opAAAAAAAA1' })
            $pkg['optionSets'][1]['options'] = @([ordered]@{ id = 'opAAAAAAAA3' }, [ordered]@{ id = 'opAAAAAAAA2' })
            $pkg['options'][1]['optionSet'] = [ordered]@{ id = 'osAAAAAAAA2' }
            $pkg['options'][1]['sortOrder'] = 2
            $pkg['options'] = @($pkg['options'] | Where-Object { [string]$_['id'] -cne 'OPAAAAAAAA2' })
            $r = Invoke-TestDeploy $pkg @{ AllowHazard = @('OptionSetMembership') }
            $r.Succeeded | Should -BeTrue
            @($r.Hazards | Where-Object { $_.Kind -eq 'OptionSetMembership' } | ForEach-Object { $_.Detail }) | Should -BeExactly @(
                "loses 1 option(s): OPAAAAAAAA2; the set's write detaches them, leaving them in no set; gives 1 option(s) to another set: opAAAAAAAA2 to osAAAAAAAA2")
        }

        It 'names each option whose stored values would show another name' {
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            $pkg['options'][0]['name'] = 'Uno'
            { Invoke-TestDeploy $pkg } | Should -Throw '*Unacknowledged hazard(s): OptionNameChange*'
            (Get-CommitRequest).Count | Should -Be 0
            $r = Invoke-TestDeploy $pkg @{ AllowHazard = @('OptionNameChange') }
            $r.Succeeded | Should -BeTrue
            @($r.Hazards | Where-Object { $_.Kind -eq 'OptionNameChange' } | ForEach-Object { "$($_.Type) $($_.Id): $($_.Detail)" }) | Should -Be @("options opAAAAAAAA1: code '1': 'One' -> 'Uno'")
        }

        It 'refuses before any write an option whose <What> another option of its set holds as stored, whatever is acknowledged' -ForEach @(
            @{ What = 'code, passed on from an option the set drops'; Expect = "*E4028*option opAAAAAAAA9 takes the code '2' that option opAAAAAAAA2 holds in set osAAAAAAAA1*"
                Change = { param($p)
                    $p['options'] = @($p['options'][0]) + @([ordered]@{ id = 'opAAAAAAAA9'; code = '2'; name = 'Deux'; sortOrder = 2; optionSet = [ordered]@{ id = 'osAAAAAAAA1' } })
                    $p['optionSets'][0]['options'] = @([ordered]@{ id = 'opAAAAAAAA1' }, [ordered]@{ id = 'opAAAAAAAA9' })
                    $p['optionGroups'][1]['options'] = @([ordered]@{ id = 'opAAAAAAAA9' }) } }
            @{ What = 'name, in a swap'; Expect = "*option opAAAAAAAA1 takes the name 'Two' that option opAAAAAAAA2 holds in set osAAAAAAAA1; option opAAAAAAAA2 takes the name 'One' that option opAAAAAAAA1 holds*"
                Change = { param($p) $p['options'][0]['name'] = 'Two'; $p['options'][1]['name'] = 'One' } }
        ) {
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            & $Change $pkg
            { Invoke-TestDeploy $pkg @{ AllowHazard = @('OptionSetMembership', 'OptionCodeChange', 'OptionNameChange', 'OrphanDelete') } } | Should -Throw $Expect
            (Get-CommitRequest).Count | Should -Be 0
            # DHIS2, and its stand-in, would refuse the request that writes them.
            Get-FakeDuplicateOption ([ordered]@{ options = @($pkg['options']) }) | Should -BeLike 'E4028*'
        }

        It 'refuses before any write a move it cannot carry out: <Case>' -ForEach @(
            @{ Case = 'a rule that both gives an action and takes one'; Version = '2.41.10'; Expect = '*programRules ruAAAAAAAA1 both gives a child to another parent and takes one*'; Live = $null
                Change = { param($p)
                    $p['programRules'][0]['programRuleActions'] = @([ordered]@{ id = 'raAAAAAAAA3' }, [ordered]@{ id = 'raAAAAAAAA2' })
                    $p['programRules'][1]['programRuleActions'] = @([ordered]@{ id = 'raAAAAAAAA1' })
                    $p['programRuleActions'][0]['programRule'] = [ordered]@{ id = 'ruAAAAAAAA2' }
                    $p['programRuleActions'][1]['programRule'] = [ordered]@{ id = 'ruAAAAAAAA1' } } }
            @{ Case = 'a template moved to the program'; Version = '2.41.10'; Expect = '*moves programNotificationTemplates ntAAAAAAAA1 from programStages psAAAAAAAA1 to programs prAAAAAAAA1. Programs are written last*'
                Live = { (Get-FakeObject 'programStages' 'psAAAAAAAA1')['notificationTemplates'] = @(@{ id = 'ntAAAAAAAA1' }) }
                Change = { param($p) $p['programs'][0]['notificationTemplates'] = @([ordered]@{ id = 'ntAAAAAAAA1' }) } }
            @{ Case = 'an action that sends a notification, from 2.42'; Version = '2.42.6'; Expect = '*moves programRuleActions raAAAAAAAA2 from programRules ruAAAAAAAA2 to programRules ruAAAAAAAA1. From DHIS2 2.42*'; Live = $null
                Change = { param($p)
                    $p['programRules'][0]['programRuleActions'] = @([ordered]@{ id = 'raAAAAAAAA1' }, [ordered]@{ id = 'raAAAAAAAA3' }, [ordered]@{ id = 'raAAAAAAAA2' })
                    $p['programRules'][1]['programRuleActions'] = @()
                    $p['programRuleActions'][1]['programRule'] = [ordered]@{ id = 'ruAAAAAAAA1' } } }
            @{ Case = 'a stage data element'; Version = '2.41.10'; Expect = '*moves programStageDataElements sdAAAAAAAA1 from programStages psAAAAAAAA1 to programStages psAAAAAAAA2. A deployment moves only*'
                Live = { (Get-FakeObject 'programStages' 'psAAAAAAAA1')['programStageDataElements'] = @(@{ id = 'sdAAAAAAAA1'; dataElement = @{ id = 'deAAAAAAAA1' } }) }
                Change = { param($p) $p['programStages'][1]['programStageDataElements'] = @([ordered]@{ id = 'sdAAAAAAAA1'; dataElement = [ordered]@{ id = 'deAAAAAAAA1' } }) } }
            @{ Case = 'a section listed under two stages'; Version = '2.41.10'; Expect = '*lists programStageSections ssAAAAAAAA2 under both programStages psAAAAAAAA1 and programStages psAAAAAAAA2*'; Live = $null
                Change = { param($p) $p['programStages'][1]['programStageSections'] = @([ordered]@{ id = 'ssAAAAAAAA2' }) } }
            @{ Case = 'a template moved from the program to a stage'; Version = '2.41.10'; Expect = '*moves programNotificationTemplates ntAAAAAAAA1 from programs prAAAAAAAA1 to programStages psAAAAAAAA2. A template''s row holds its program apart from its stage*'
                Live = { (Get-FakeObject 'programs' 'prAAAAAAAA1')['notificationTemplates'] = @(@{ id = 'ntAAAAAAAA1' }) }
                Change = { param($p) $p['programStages'][1]['notificationTemplates'] = @([ordered]@{ id = 'ntAAAAAAAA1' }) } }
            @{ Case = 'an action from a rule the package does not carry'; Version = '2.41.10'; Expect = '*lists programRuleActions raAAAAAAAA9 under programRules ruAAAAAAAA1, but on the instance it belongs to a parent the package neither carries nor deletes*'
                Live = {
                    Set-FakeObject 'programRules' @{ id = 'ruAAAAAAAA9'; name = 'Live only'; condition = 'true'; program = @{ id = 'prAAAAAAAA1' }; programRuleActions = @(@{ id = 'raAAAAAAAA9' }) }
                    Set-FakeObject 'programRuleActions' @{ id = 'raAAAAAAAA9'; programRuleActionType = 'DISPLAYTEXT'; content = 'Nine'; location = 'feedback'; programRule = @{ id = 'ruAAAAAAAA9' } } }
                Change = { param($p)
                    $p['programRules'][0]['programRuleActions'] = @(@($p['programRules'][0]['programRuleActions']) + @([ordered]@{ id = 'raAAAAAAAA9' }))
                    $p['programRuleActions'] = @(@($p['programRuleActions']) + @([ordered]@{ id = 'raAAAAAAAA9'; programRuleActionType = 'DISPLAYTEXT'; content = 'Nine'; location = 'feedback'; programRule = [ordered]@{ id = 'ruAAAAAAAA1' } })) } }
            @{ Case = 'a section from a stage in -Delete'; Version = '2.41.10'; Expect = '*moves programStageSections ssAAAAAAAA9 from programStages psAAAAAAAA9, which -Delete deletes, to programStages psAAAAAAAA2*'
                DeleteEntries = @{ programStages = @('psAAAAAAAA9') }
                Live = {
                    Set-FakeObject 'programStages' @{ id = 'psAAAAAAAA9'; code = 'STG9'; name = 'Old stage'; program = @{ id = 'prAAAAAAAA1' }; programStageSections = @(@{ id = 'ssAAAAAAAA9' }) }
                    Set-FakeObject 'programStageSections' @{ id = 'ssAAAAAAAA9'; code = 'SEC9'; name = 'Section nine'; sortOrder = 0; programStage = @{ id = 'psAAAAAAAA9' } } }
                Change = { param($p)
                    $p['programStages'][1]['programStageSections'] = @([ordered]@{ id = 'ssAAAAAAAA9' })
                    $p['programStageSections'] = @(@($p['programStageSections']) + @([ordered]@{ id = 'ssAAAAAAAA9'; code = 'SEC9'; name = 'Section nine'; sortOrder = 0; programStage = [ordered]@{ id = 'psAAAAAAAA2' } })) } }
            @{ Case = 'a template from a stage in -Delete to the program'; Version = '2.43.1'; Expect = '*moves programNotificationTemplates ntAAAAAAAA1 from programStages psAAAAAAAA9, which -Delete deletes, to programs prAAAAAAAA1*'
                DeleteEntries = @{ programStages = @('psAAAAAAAA9') }
                Live = { Set-FakeObject 'programStages' @{ id = 'psAAAAAAAA9'; code = 'STG9'; name = 'Old stage'; program = @{ id = 'prAAAAAAAA1' }; notificationTemplates = @(@{ id = 'ntAAAAAAAA1' }) } }
                Change = { param($p) $p['programs'][0]['notificationTemplates'] = @([ordered]@{ id = 'ntAAAAAAAA1' }) } }
            @{ Case = 'an option from a set the package does not carry'; Version = '2.41.10'; Expect = '*moves options opAAAAAAAA9 from optionSets osAAAAAAAA9, which the package neither carries nor deletes, to optionSets osAAAAAAAA1*'
                Live = {
                    Set-FakeObject 'optionSets' @{ id = 'osAAAAAAAA9'; code = 'OS9'; name = 'Other set'; valueType = 'TEXT'; version = 1; options = @(@{ id = 'opAAAAAAAA9' }) }
                    Set-FakeObject 'options' @{ id = 'opAAAAAAAA9'; code = '9'; name = 'Nine'; sortOrder = 1; optionSet = @{ id = 'osAAAAAAAA9' } } }
                Change = { param($p)
                    $p['options'] = @(@($p['options']) + @([ordered]@{ id = 'opAAAAAAAA9'; code = '9'; name = 'Nine'; sortOrder = 3; optionSet = [ordered]@{ id = 'osAAAAAAAA1' } }))
                    $p['optionSets'][0]['options'] = @(@($p['optionSets'][0]['options']) + @([ordered]@{ id = 'opAAAAAAAA9' })) } }
        ) {
            $script:Fake.Version = $Version
            $pkg = New-TestPackage
            Add-TestStage $pkg
            Set-FakeFromPackage $pkg
            if ($Live) { & $Live }
            & $Change $pkg
            $extra = @{ AllowHazard = @('OrphanDelete', 'OptionSetMembership') }
            if ($DeleteEntries) { $extra['Delete'] = $DeleteEntries }
            { Invoke-TestDeploy $pkg $extra } | Should -Throw $Expect
            (Get-CommitRequest).Count | Should -Be 0
            @($script:Fake.Requests | Where-Object { $_.Kind -in 'put', 'delete' }).Count | Should -Be 0
        }

        It 'stops before any write when a live option group set the package does not carry lists an option group in -Delete, and deletes the set first when -Delete lists it too' {
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            Set-FakeObject 'optionGroups' @{ id = 'ogAAAAAAAA9'; code = 'G9'; name = 'G9'; shortName = 'G9'; optionSet = @{ id = 'osAAAAAAAA1' } }
            Set-FakeObject 'optionGroupSets' @{ id = 'gsAAAAAAAA9'; code = 'GS9'; name = 'GS9'; optionGroups = @(@{ id = 'ogAAAAAAAA9' }) }
            { Invoke-TestDeploy $pkg @{ Delete = @{ optionGroups = @('ogAAAAAAAA9') } } } | Should -Throw '*optionGroupSets gsAAAAAAAA9 refers to optionGroups|ogAAAAAAAA9*the package does not carry it*'
            # A package without option group sets is checked against the live ones all the same.
            $noSets = Copy-Value $pkg
            $noSets.Remove('optionGroupSets')
            { Invoke-TestDeploy $noSets @{ Delete = @{ optionGroups = @('ogAAAAAAAA9') } } } | Should -Throw '*optionGroupSets gsAAAAAAAA9 refers to optionGroups|ogAAAAAAAA9*'
            (Get-CommitRequest).Count | Should -Be 0
            @($script:Fake.Requests | Where-Object { $_.Kind -in 'put', 'delete' }).Count | Should -Be 0
            $r = Invoke-TestDeploy $pkg @{ Delete = @{ optionGroups = @('ogAAAAAAAA9'); optionGroupSets = @('gsAAAAAAAA9') } }
            $r.Succeeded | Should -BeTrue
            @($script:Fake.Requests | Where-Object { $_.Kind -eq 'delete' } | ForEach-Object { "$($_.Type)|$($_.Id)" }) | Should -Be @('optionGroupSets|gsAAAAAAAA9', 'optionGroups|ogAAAAAAAA9')
        }

        It 'stops before any write when an object the package carries refers to what -Delete removes through a property the deployment does not write' {
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            # Attributes carry no option set in the package, so one the instance gives them compares unchanged.
            $pkg['attributes'] = @([ordered]@{ id = 'atAAAAAAAA1'; code = 'AT1'; name = 'Attribute'; shortName = 'AT1'; valueType = 'TEXT' })
            Set-FakeObject 'attributes' @{ id = 'atAAAAAAAA1'; code = 'AT1'; name = 'Attribute'; shortName = 'AT1'; valueType = 'TEXT'; optionSet = @{ id = 'osAAAAAAAA9' } }
            Set-FakeObject 'optionSets' @{ id = 'osAAAAAAAA9'; code = 'OS9'; name = 'Old set'; valueType = 'TEXT'; version = 1; options = @() }
            { Invoke-TestDeploy $pkg @{ Delete = @{ optionSets = @('osAAAAAAAA9') }; AllowHazard = @('OptionSetMembership') } } |
                Should -Throw '*attributes atAAAAAAAA1 refers to optionSets|osAAAAAAAA9*this deployment does not write it*'
            (Get-CommitRequest).Count | Should -Be 0
            @($script:Fake.Requests | Where-Object { $_.Kind -eq 'delete' }).Count | Should -Be 0
        }

        It 'names the program pending after a request whose answer is lost, and not after one DHIS2 refuses' {
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            $changed = Copy-Value $pkg
            $changed['dataElements'][0]['name'] = 'Changed'
            # An import with atomicMode ALL that DHIS2 answers with an error commits nothing.
            $script:Fake.FailImport = { $true }
            $err = $null
            try { Invoke-TestDeploy $changed } catch { $err = $_ }
            $err.FullyQualifiedErrorId | Should -BeLike 'NeoIPCDeploymentFailed*'
            @($err.TargetObject.ProgramVersionPending).Count | Should -Be 0
            # An answer lost on the way can follow a commit.
            $script:Fake.FailImport = $null
            $script:Fake.ThrowImport = { $true }
            $err = $null
            try { Invoke-TestDeploy $changed } catch { $err = $_ }
            @($err.TargetObject.ProgramVersionPending) | Should -Be @('prAAAAAAAA1')
            $script:Fake.ThrowImport = $null
            # A proxy's refusal, a page without DHIS2's status, commits nothing either.
            $script:Fake.RefuseImport = { 413 }
            $err = $null
            try { Invoke-TestDeploy $changed } catch { $err = $_ }
            $err.FullyQualifiedErrorId | Should -BeLike 'NeoIPCDeploymentFailed*'
            @($err.TargetObject.ProgramVersionPending).Count | Should -Be 0
            $script:Fake.RefuseImport = $null
            # The same holds for a delete.
            Set-FakeObject 'programRules' @{ id = 'ruAAAAAAAA9'; name = 'Inert'; condition = 'false'; program = @{ id = 'prAAAAAAAA1' }; programRuleActions = @() }
            $script:Fake.ThrowDelete = { 'Refuse' }
            $err = $null
            try { Invoke-TestDeploy $pkg @{ Delete = @{ programRules = @('ruAAAAAAAA9') } } } catch { $err = $_ }
            $err.Exception.Message | Should -BeLike '*Deleting programRules ruAAAAAAAA9 failed*'
            @($err.TargetObject.ProgramVersionPending).Count | Should -Be 0
            $script:Fake.ThrowDelete = { 'Lose' }
            $err = $null
            try { Invoke-TestDeploy $pkg @{ Delete = @{ programRules = @('ruAAAAAAAA9') } } } catch { $err = $_ }
            @($err.TargetObject.ProgramVersionPending) | Should -Be @('prAAAAAAAA1')
        }

        It 'ends a dry run whose validation fails in transport with the plan and the objects present only on the instance' {
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            Set-FakeObject 'dataElements' @{ id = 'deAAAAAAAA9'; code = 'DE9'; name = 'Live only'; shortName = 'DE9'; valueType = 'TEXT'; domainType = 'TRACKER'; aggregationType = 'NONE' }
            $pkg['dataElements'][0]['name'] = 'Changed'
            $script:Fake.ThrowPost = { param($Post) $Post.Mode -eq 'VALIDATE' }
            $err = $null
            try { Invoke-TestDeploy $pkg @{ DryRun = $true } } catch { $err = $_ }
            $err.FullyQualifiedErrorId | Should -BeLike 'NeoIPCDeploymentFailed*'
            $err.Exception.Message | Should -BeLike "*The dry run's validation request failed*SSL connection*"
            @($err.TargetObject.Plan | Where-Object Type -eq 'dataElements')[0].Changed | Should -Be 1
            @($err.TargetObject.LiveOnly | Where-Object Type -eq 'dataElements')[0].Sample | Should -BeLike '*deAAAAAAAA9 DE9*'
        }

        It 'refuses before any write under a SilentlyContinue error preference, when no try encloses the call' {
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            (Get-FakeObject 'programs' 'prAAAAAAAA1')['programStages'] = @(@{ id = 'psAAAAAAAA1' }, @{ id = 'psAAAAAAAA2' })
            Set-FakeObject 'programStages' @{ id = 'psAAAAAAAA2'; code = 'STG2'; name = 'Old stage'; program = @{ id = 'prAAAAAAAA1' } }
            $script:Fake.Events.Add(@{ event = 'evAAAAAAAA1'; programStage = 'psAAAAAAAA2'; deleted = $false })
            $pkg['dataElements'][0]['name'] = 'Changed'
            # PowerShell drops a throw only where no try encloses it, and Pester runs each test inside one; a nested
            # pipeline in this runspace has a call stack of its own.
            $ps = [powershell]::Create([System.Management.Automation.RunspaceMode]::CurrentRunspace)
            try {
                [void]$ps.AddScript('param($Arguments) Deploy-NeoIPCMetadata @Arguments 6>$null').AddArgument(@{ Json = ($pkg | ConvertTo-Json -Depth 100 -Compress)
                        Auth = @{ AuthType = 'Basic' }; Hostname = 'dhis2.example.org'; Confirm = $false; Delete = @{ programStages = @('psAAAAAAAA2') }; ErrorAction = 'SilentlyContinue' })
                try { [void]$ps.Invoke() } catch { Write-Verbose "The nested pipeline ended: $($_.Exception.Message)" }
            }
            finally { $ps.Dispose() }
            @($script:Fake.Requests | Where-Object { $_.Kind -eq 'events' }).Count | Should -Be 1 -Because 'the deployment ran as far as the stage''s event check'
            (Get-CommitRequest).Count | Should -Be 0
            @($script:Fake.Requests | Where-Object { $_.Kind -eq 'delete' }).Count | Should -Be 0
            (Get-FakeObject 'dataElements' 'deAAAAAAAA1')['name'] | Should -Not -Be 'Changed'
        }

        It 'detaches an action the package points away from a template its stage drops, and creates it again in R1' {
            $script:Fake.Version = '2.43.1'
            $pkg = New-TestPackage
            $pkg['programStages'][0]['notificationTemplates'] = @([ordered]@{ id = 'ntAAAAAAAA1' })
            Set-FakeFromPackage $pkg
            # On the instance the stage also holds a template the action sends; the package drops it and has the action send the other.
            (Get-FakeObject 'programStages' 'psAAAAAAAA1')['notificationTemplates'] = @(@{ id = 'ntAAAAAAAA1' }, @{ id = 'ntAAAAAAAA9' })
            Set-FakeObject 'programNotificationTemplates' @{ id = 'ntAAAAAAAA9'; name = 'Old notice'; messageTemplate = 'Old'; notificationTrigger = 'PROGRAM_RULE'; notificationRecipient = 'USER_GROUP' }
            (Get-FakeObject 'programRuleActions' 'raAAAAAAAA2')['templateUid'] = 'ntAAAAAAAA9'
            $r = Invoke-TestDeploy $pkg @{ Delete = @{ programNotificationTemplates = @('ntAAAAAAAA9') } }
            $r.Succeeded | Should -BeTrue
            $commits = Get-CommitRequest
            @($commits[0].Payload.Keys) | Should -Be @('programRules') -Because 'from 2.42 the live action''s template keeps the stage''s write from deleting it'
            @((Get-PayloadObject $commits[0] 'programRules' 'ruAAAAAAAA2')['programRuleActions']).Count | Should -Be 0
            (Get-PayloadObject $commits[1] 'programRuleActions' 'raAAAAAAAA2')['templateUid'] | Should -Be 'ntAAAAAAAA1'
            Get-FakeObject 'programNotificationTemplates' 'ntAAAAAAAA9' | Should -BeNullOrEmpty
            (Get-FakeObject 'programRuleActions' 'raAAAAAAAA2')['templateUid'] | Should -Be 'ntAAAAAAAA1'
            $r.Deleted.Contains('programNotificationTemplates|ntAAAAAAAA9') | Should -BeTrue
        }

        It 'detaches a rule that also gains an action with only the actions that exist, and R1 creates the new one' {
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            $pkg['programStages'][0]['programStageSections'] = @([ordered]@{ id = 'ssAAAAAAAA1' })
            $pkg['programStageSections'] = @($pkg['programStageSections'][0])
            $pkg['programRuleActions'][2]['programStageSection'] = [ordered]@{ id = 'ssAAAAAAAA1' }
            $pkg['programRules'][0]['programRuleActions'] = @($pkg['programRules'][0]['programRuleActions']) + @([ordered]@{ id = 'raAAAAAAAA4' })
            $pkg['programRuleActions'] += [ordered]@{ id = 'raAAAAAAAA4'; programRuleActionType = 'DISPLAYTEXT'; content = 'New'; location = 'feedback'; programRule = [ordered]@{ id = 'ruAAAAAAAA1' } }
            $r = Invoke-TestDeploy $pkg @{ Delete = @{ programStageSections = @('ssAAAAAAAA2') } }
            $r.Succeeded | Should -BeTrue
            $commits = Get-CommitRequest
            @((Get-PayloadObject $commits[0] 'programRules' 'ruAAAAAAAA1')['programRuleActions'] | ForEach-Object { $_['id'] }) | Should -Be @('raAAAAAAAA1') -Because 'DHIS2 refuses a reference to an action that does not exist yet'
            Get-FakeObject 'programRuleActions' 'raAAAAAAAA4' | Should -Not -BeNullOrEmpty
            @((Get-FakeObject 'programRules' 'ruAAAAAAAA1')['programRuleActions'] | ForEach-Object { $_['id'] }) | Should -Be @('raAAAAAAAA1', 'raAAAAAAAA3', 'raAAAAAAAA4')
        }

        It 'stops before any write when a live <Type> the package does not carry refers to an option set in -Delete through <Property>' -ForEach @(
            @{ Type = 'dataElements'; Property = 'commentOptionSet'; Hit = 'optionSets|osAAAAAAAA9'
                Object = @{ id = 'deAAAAAAAA9'; code = 'DE9'; name = 'Live only'; shortName = 'DE9'; valueType = 'TEXT'; domainType = 'TRACKER'; aggregationType = 'NONE'; commentOptionSet = @{ id = 'osAAAAAAAA9' } } }
            @{ Type = 'trackedEntityAttributes'; Property = 'optionSet'; Hit = 'optionSets|osAAAAAAAA9'
                Object = @{ id = 'teAAAAAAAA9'; code = 'TE9'; name = 'Live only'; shortName = 'TE9'; valueType = 'TEXT'; optionSet = @{ id = 'osAAAAAAAA9' } } }
            @{ Type = 'optionGroups'; Property = 'optionSet'; Hit = 'optionSets|osAAAAAAAA9'
                Object = @{ id = 'ogAAAAAAAA9'; code = 'G9'; name = 'G9'; shortName = 'G9'; optionSet = @{ id = 'osAAAAAAAA9' } } }
            @{ Type = 'optionGroups'; Property = 'options'; Hit = 'options|opAAAAAAAA9'
                Object = @{ id = 'ogAAAAAAAA9'; code = 'G9'; name = 'G9'; shortName = 'G9'; optionSet = @{ id = 'osAAAAAAAA1' }; options = @(@{ id = 'opAAAAAAAA9' }) } }
            @{ Type = 'optionGroupSets'; Property = 'optionSet'; Hit = 'optionSets|osAAAAAAAA9'
                Object = @{ id = 'gsAAAAAAAA9'; code = 'GS9'; name = 'GS9'; optionSet = @{ id = 'osAAAAAAAA9' }; optionGroups = @() } }
        ) {
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            Set-FakeObject 'optionSets' @{ id = 'osAAAAAAAA9'; code = 'OS9'; name = 'Old set'; valueType = 'TEXT'; version = 1; options = @(@{ id = 'opAAAAAAAA9' }) }
            Set-FakeObject 'options' @{ id = 'opAAAAAAAA9'; code = '9'; name = 'Nine'; sortOrder = 1; optionSet = @{ id = 'osAAAAAAAA9' } }
            Set-FakeObject $Type $Object
            { Invoke-TestDeploy $pkg @{ Delete = @{ optionSets = @('osAAAAAAAA9') }; AllowHazard = @('OptionSetMembership') } } |
                Should -Throw "*$Type $($Object['id']) refers to $Hit*the package does not carry it*"
            (Get-CommitRequest).Count | Should -Be 0
            @($script:Fake.Requests | Where-Object { $_.Kind -in 'put', 'delete' }).Count | Should -Be 0
        }

        It 'ends with the summary and writes nothing when <Read> fails before the writes' -ForEach @(
            @{ Read = 'the version read'; Message = '*Reading the DHIS2 version failed*'; Delete = @{}
                ThrowGet = { param($Read) $Read.Path -eq 'api/system/info' }; ThrowPost = $null; EventsKey = $null; NoList = $null }
            @{ Read = 'the cache clear'; Message = '*Clearing the DHIS2 caches failed*'; Delete = @{}
                ThrowGet = $null; ThrowPost = { param($Post) $Post.Path -eq 'api/maintenance' }; EventsKey = $null; NoList = $null }
            @{ Read = 'the schema read'; Message = '*Reading the DHIS2 schemas failed*'; Delete = @{}
                ThrowGet = { param($Read) $Read.Path -eq 'api/schemas' }; ThrowPost = $null; EventsKey = $null; NoList = $null }
            @{ Read = 'the option group sets read'; Message = '*Reading the live option group sets failed*'; Delete = @{}
                ThrowGet = { param($Read) $Read.Path -eq 'api/optionGroupSets' -and -not $Read.Filter }; ThrowPost = $null; EventsKey = $null; NoList = $null }
            @{ Read = 'an option group sets read without its list'; Message = "*Reading the live option group sets failed: the response held no 'optionGroupSets' collection*"; Delete = @{}
                ThrowGet = $null; ThrowPost = $null; EventsKey = $null; NoList = { param($Read) $Read.Path -eq 'api/optionGroupSets' -and -not $Read.Filter } }
            @{ Read = 'the read of the referring objects'; Message = '*Reading the live programRuleVariables failed*'; Delete = @{ programStages = @('psAAAAAAAA2') }
                ThrowGet = { param($Read) $Read.Path -eq 'api/programRuleVariables' -and -not $Read.Filter }; ThrowPost = $null; EventsKey = $null; NoList = $null }
            @{ Read = 'a read of the referring objects without its list'; Message = "*Reading the live programRuleVariables failed: the response held no 'programRuleVariables' collection*"; Delete = @{ programStages = @('psAAAAAAAA2') }
                ThrowGet = $null; ThrowPost = $null; EventsKey = $null; NoList = { param($Read) $Read.Path -eq 'api/programRuleVariables' -and -not $Read.Filter } }
            @{ Read = 'the event read'; Message = '*Reading whether program stage psAAAAAAAA2 has events failed*'; Delete = @{ programStages = @('psAAAAAAAA2') }
                ThrowGet = { param($Read) $Read.Path -eq 'api/tracker/events' }; ThrowPost = $null; EventsKey = $null; NoList = $null }
            @{ Read = 'an event read without its list'; Message = "*Reading whether program stage psAAAAAAAA2 has events returned no 'events' list*"; Delete = @{ programStages = @('psAAAAAAAA2') }
                ThrowGet = $null; ThrowPost = $null; EventsKey = 'rows'; NoList = $null }
            @{ Read = 'an event visualizations read without its list'; Message = "*Reading the live eventVisualizations failed: the response held no 'eventVisualizations' collection*"; Delete = @{ programStages = @('psAAAAAAAA2') }
                ThrowGet = $null; ThrowPost = $null; EventsKey = $null; NoList = { param($Read) $Read.Path -eq 'api/eventVisualizations' } }
            @{ Read = 'a map views read without its list'; Message = "*Reading the live mapViews failed: the response held no 'mapViews' collection*"; Delete = @{ programStages = @('psAAAAAAAA2') }
                ThrowGet = $null; ThrowPost = $null; EventsKey = $null; NoList = { param($Read) $Read.Path -eq 'api/mapViews' } }
        ) {
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            if ($Delete.Count -gt 0) {
                (Get-FakeObject 'programs' 'prAAAAAAAA1')['programStages'] = @(@{ id = 'psAAAAAAAA1' }, @{ id = 'psAAAAAAAA2' })
                Set-FakeObject 'programStages' @{ id = 'psAAAAAAAA2'; code = 'STG2'; name = 'Old stage'; program = @{ id = 'prAAAAAAAA1' } }
            }
            $pkg['dataElements'][0]['name'] = 'Changed'
            $script:Fake.ThrowGet = $ThrowGet; $script:Fake.ThrowPost = $ThrowPost; $script:Fake.EventsKey = $EventsKey; $script:Fake.NoList = $NoList
            $err = $null
            try { Invoke-TestDeploy $pkg @{ Delete = $Delete } } catch { $err = $_ }
            $err.FullyQualifiedErrorId | Should -BeLike 'NeoIPCDeploymentFailed*'
            $err.Exception.Message | Should -BeLike $Message
            $err.TargetObject.Target | Should -Be 'https://dhis2.example.org'
            (Get-CommitRequest).Count | Should -Be 0
            @($script:Fake.Requests | Where-Object { $_.Kind -eq 'delete' }).Count | Should -Be 0
        }

        It 'reports a failed listing of the objects present only on the instance (<Case>)' -ForEach @(
            @{ Case = 'a dry run'; Extra = @{ DryRun = $true }; Code = $null; NoList = $false; Message = '*Listing the objects present only on the instance failed*SSL connection*' }
            @{ Case = 'a dry run the hazard gate stops'; Extra = @{ DryRun = $true }; Code = 'one'; NoList = $false; Message = '*Unacknowledged hazard(s): OptionCodeChange*Listing the objects present only on the instance failed too*' }
            @{ Case = 'after the verification'; Extra = @{}; Code = $null; NoList = $false; Message = '*failed verification: listing the objects present only on the instance failed*' }
            @{ Case = 'a dry run whose reads hold no list'; Extra = @{ DryRun = $true }; Code = $null; NoList = $true; Message = "*Listing the objects present only on the instance failed: the response held no '*' collection*" }
        ) {
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            $pkg['dataElements'][0]['name'] = 'Changed'
            if ($Code) { $pkg['options'][0]['code'] = $Code }
            # The listing reads every type of the package, unfiltered, for its ids, codes and names.
            $listing = { param($Read) -not $Read.Filter -and ($Read.Fields -join ',') -eq 'id,code,name' }
            if ($NoList) { $script:Fake.NoList = $listing } else { $script:Fake.ThrowGet = $listing }
            $err = $null
            try { Invoke-TestDeploy $pkg $Extra } catch { $err = $_ }
            $err.FullyQualifiedErrorId | Should -BeLike 'NeoIPCDeploymentFailed*'
            $err.Exception.Message | Should -BeLike $Message
            @($err.TargetObject.Plan | Where-Object Type -eq 'dataElements')[0].Changed | Should -Be 1
        }

        It 'names only the programs that exist on the instance pending when a run asked to move their versions stops early' {
            $pkg = New-TestPackage
            Set-FakeFromPackage $pkg
            $pkg['programs'] += [ordered]@{ id = 'prAAAAAAAA2'; code = 'PROG2'; name = 'New program'; shortName = 'New program'; programType = 'WITH_REGISTRATION'; version = 1 }
            $pkg['options'][0]['code'] = 'one'
            $err = $null
            try { Invoke-TestDeploy $pkg @{ BumpProgramVersion = $true } } catch { $err = $_ }
            $err.Exception.Message | Should -BeLike '*Unacknowledged hazard(s): OptionCodeChange*'
            @($err.TargetObject.ProgramVersionPending) | Should -Be @('prAAAAAAAA1') -Because 'clients hold no version of a program the run would create'
        }
    }
}
