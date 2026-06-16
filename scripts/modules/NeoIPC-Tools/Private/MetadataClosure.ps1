# NeoIPC metadata pipeline — client-side dependency closure (the M2 "prune", private, not exported).
# Reduces a full DHIS2 metadata export to the transitive closure of everything the NEOIPC_CORE program
# needs. Node-free: structured id-ref walk + reverse-by-program/-stage inclusion, with an expression-UID
# SAFETY NET that proves no expression-embedded reference was dropped. DHIS2's own dependency export is
# unreliable (it never parses expression text); this is the deterministic replacement.

# Beyond the program closure, NeoIPC owns metadata the program does not reference (decision: program closure
# + membership/ownership). Three recovery rules run after the program closure:
#  - MEMBERSHIP: include a grouping object when its member list intersects the closure — NeoIPC's analytics
#    groupings (ATC/AWaRe option groups keyed on antimicrobial-substance options; NEOIPC_ data-element groups).
$script:NeoIPCMetadataMembershipFields = [ordered]@{ optionGroups = 'options'; optionGroupSets = 'optionGroups'; dataElementGroups = 'dataElements' }
#  - OWNERSHIP: custom-attribute definitions are entirely deployment-authored (DHIS2 ships none), so in
#    NeoIPC's single-tenant instance every `attributes` object is NeoIPC's — kept wholesale. A code/name
#    prefix rule was rejected: it would drop IsTestunit / OPERATIONAL_CONTACT / REPRESENTATIVE (NeoIPC
#    org-unit attributes whose values live on overlay org units, so they carry no project-name prefix).
$script:NeoIPCMetadataKeepAllTypes = @('attributes')
#  - EXPRESSION-SOURCE: include an object that depends on the closure only through its EXPRESSION text and is
#    referenced by nothing — validationRules point AT data elements / programIndicators via leftSide/rightSide
#    expressions but are pointed at by no {id} edge, so neither the structured walk nor membership reaches them.
#    A rule is recovered when any UID in its expressions is already in the closure.
$script:NeoIPCMetadataExpressionSourceTypes = @('validationRules')

function Add-NeoIPCMetadataRefId {
    # Recursively accumulate every referenced id ({ "id": "<uid>" } anywhere in the object tree) into $Acc,
    # EXCLUDING the object's own top-level id. Wrapper-agnostic: catches refs at any depth, incl. inside
    # nested-only children (programStageDataElements.dataElement, …) and attributeValues — this is the
    # PRIMARY closure edge and needs no per-type ref-field map.
    [CmdletBinding()]
    param([AllowNull()]$Node, [bool]$IsRoot, [System.Collections.Generic.HashSet[string]]$Acc)
    if ($Node -is [System.Collections.IDictionary]) {
        foreach ($k in @($Node.Keys)) {
            if ($IsRoot -and $k -eq 'id') { continue }                 # the object's own identity, not a ref
            $v = $Node[$k]
            if ($k -eq 'id' -and $v -is [string]) { [void]$Acc.Add($v) }
            else { Add-NeoIPCMetadataRefId -Node $v -IsRoot $false -Acc $Acc }
        }
    }
    elseif ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [string]) {
        foreach ($e in $Node) { Add-NeoIPCMetadataRefId -Node $e -IsRoot $false -Acc $Acc }
    }
}

function Get-NeoIPCMetadataExpressionRef {
    # Extract every metadata UID referenced inside a DHIS2 expression STRING, tagged with the syntax form.
    # Authoritative against refs/expression-parser (DataItemType.kt / IDType.kt / Expr.kt): the UID-bearing
    # data-item wrappers are #{} A{} C{} D{} I{} N{} R{} OUG{}, each with one or more dot-joined parts; a part
    # may carry a `tag:` prefix and be `&`-joined (a tagged UID group), and only the 11-char-UID tokens are
    # taken — so:
    #   - R{dataSet.REPORTING_RATE} yields just the dataSet UID (the 2nd part is a ReportingRateType, not a UID),
    #   - #{ps.de} / #{de.coc.aoc} yield 2 / 3 UIDs,
    #   - #{ps.co:uid} / #{deGroup:uid} / #{ps.coGroup:uidA&uidB} yield the tagged/grouped category-option,
    #     data-element-group and category-option-group UIDs (the tag is stripped, the group split on '&'),
    #   - V{event_date}, VAR{…}, and program-rule NAME refs (#{NeoIPC BSI Pathogen 1 value}) yield nothing
    #     (V/VAR are non-UID per IDType.isUID(); names carry spaces / aren't 11 chars).
    # Plus the irregular forms: the bare PS_EVENTDATE:<uid> tag, d2:relationshipCount('<uid>') (its only
    # quoted-UID argument), and the orgUnit.ancestor/dataSet/group/program(<uid>…) validation-rule functions
    # whose args are bare unquoted UID lists. Returns [{ Uid; Form }] objects.
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[object]])]
    param([AllowEmptyString()][AllowNull()][string]$Text)
    $out = [System.Collections.Generic.List[object]]::new()
    if ([string]::IsNullOrEmpty($Text)) { return $out }
    # data-item wrappers; lookbehind stops A/C/D/I/N/R/OUG matching mid-identifier (e.g. the R in VAR{…}).
    # Each dot-part may carry a `tag:` prefix (deGroup:/co:/coGroup:) and/or be an `&`-joined UID group
    # (#{ps.coGroup:uidA&uidB}) — strip the tag and split on `&` before the UID test, per the grammar
    # (refs/expression-parser Expr.kt isTaggedUidGroup: substring(indexOf(':')+1).split('&')). Without this,
    # co:→categoryOption / deGroup:→dataElementGroup refs (both closure-eligible) would be dropped unseen.
    foreach ($m in [regex]::Matches($Text, '(?<![A-Za-z])(OUG|[#ACDINR])\{([^{}]*)\}')) {
        $form = $m.Groups[1].Value
        foreach ($part in ($m.Groups[2].Value -split '\.')) {
            $body = if ($part.Contains(':')) { $part.Substring($part.IndexOf(':') + 1) } else { $part }
            foreach ($tok in ($body -split '&')) {
                if ($tok -cmatch '^[A-Za-z][A-Za-z0-9]{10}$') { $out.Add([pscustomobject]@{ Uid = $tok; Form = $form }) }
            }
        }
    }
    foreach ($m in [regex]::Matches($Text, '(?<![A-Za-z0-9_])PS_EVENTDATE:([A-Za-z][A-Za-z0-9]{10})')) {
        $out.Add([pscustomobject]@{ Uid = $m.Groups[1].Value; Form = 'PS_EVENTDATE' })
    }
    foreach ($m in [regex]::Matches($Text, 'd2:relationshipCount\(\s*[''"]([A-Za-z][A-Za-z0-9]{10})[''"]')) {
        $out.Add([pscustomobject]@{ Uid = $m.Groups[1].Value; Form = 'relationshipCount' })
    }
    # Validation-rule org-unit functions take bare (unquoted) UID args: orgUnit.ancestor/dataSet/group/program(uid…).
    # Grammar: refs/expression-parser ExpressionGrammar.kt fn(orgUnit_*, UID.plus()) — a bare UID list, not quoted.
    foreach ($m in [regex]::Matches($Text, 'orgUnit\.(ancestor|dataSet|group|program)\(([^()]*)\)')) {
        $form = "orgUnit.$($m.Groups[1].Value)"
        foreach ($tok in ($m.Groups[2].Value -split '[^A-Za-z0-9]+')) {
            if ($tok -cmatch '^[A-Za-z][A-Za-z0-9]{10}$') { $out.Add([pscustomobject]@{ Uid = $tok; Form = $form }) }
        }
    }
    return $out
}

function Get-NeoIPCMetadataStringValue {
    # Collect every string value in an object tree (so embedded UID tokens are found wherever they sit).
    [CmdletBinding()]
    param([AllowNull()]$Node, [System.Collections.Generic.List[string]]$Acc)
    if ($Node -is [string]) { $Acc.Add($Node); return }
    if ($Node -is [System.Collections.IDictionary]) { foreach ($k in @($Node.Keys)) { Get-NeoIPCMetadataStringValue -Node $Node[$k] -Acc $Acc } }
    elseif ($Node -is [System.Collections.IEnumerable]) { foreach ($e in $Node) { Get-NeoIPCMetadataStringValue -Node $e -Acc $Acc } }
}

function Get-NeoIPCMetadataClosure {
    # Compute the dependency closure of a parsed DHIS2 metadata package, seeded at a program (default
    # NEOIPC_CORE). Returns the pruned package + diagnostics. Excluded types ($NeoIPCMetadataExcludedTypes:
    # users/orgUnits/orgUnitGroups/categoryOptionCombos/…) are the stop-types — never indexed, so refs into
    # them resolve to nothing (overlays).
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]$Package,
        [string]$SeedType = 'programs',
        [string]$SeedCode = 'NEOIPC_CORE'
    )

    # 1. Index every top-level object of a mapped, non-excluded, non-nested type by id; build reverse indexes
    #    for the back-reference fields the program object does NOT forward-list (program, programStage).
    $index = @{}
    $byProgram = @{}
    $byStage = @{}
    foreach ($type in $script:NeoIPCMetadataTypeMaps.Keys) {
        $map = $script:NeoIPCMetadataTypeMaps[$type]
        if ($map.Nesting -eq 'NestedOnly') { continue }
        if ($script:NeoIPCMetadataExcludedTypes -contains $type) { continue }
        foreach ($o in @($Package[$type])) {
            if ($o -isnot [System.Collections.IDictionary]) { continue }
            $id = [string]$o['id']
            if (-not $id) { continue }
            $index[$id] = @{ Type = $type; Object = $o }
            foreach ($edge in @(@{ F = 'program'; T = $byProgram }, @{ F = 'programStage'; T = $byStage })) {
                $ref = $o[$edge.F]
                if ($ref -is [System.Collections.IDictionary] -and $ref['id']) {
                    $ownerId = [string]$ref['id']
                    if (-not $edge.T.ContainsKey($ownerId)) { $edge.T[$ownerId] = [System.Collections.Generic.List[string]]::new() }
                    $edge.T[$ownerId].Add($id)
                }
            }
        }
    }

    # Ids of TOP-LEVEL objects whose collection the closure does NOT handle — present in the export but its
    # type is neither mapped, nor an excluded overlay, nor a deferred type (e.g. a future legendSet / constant /
    # dataSet). A structured {id} ref from an included object to one of these resolves to a real object the
    # closure will DROP (its type is never emitted), so it is flagged (StructuredUnresolved) rather than dropped
    # silently. Crucially this is keyed on TOP-LEVEL objects, so a nested child's OWN id (a
    # programStageDataElement/analyticsPeriodBoundary id, which rides along inside its already-included parent)
    # is never mistaken for a dropped dependency, and excluded-overlay / deferred refs are correctly ignored.
    $unmappedTopLevelIds = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($k in $Package.Keys) {
        if ($k -eq 'system' -or $script:NeoIPCMetadataTypeMaps.Contains($k)) { continue }
        if ($script:NeoIPCMetadataExcludedTypes -contains $k -or $script:NeoIPCMetadataDeferredTypes -contains $k) { continue }
        foreach ($o in @($Package[$k])) {
            if ($o -is [System.Collections.IDictionary] -and $o['id']) { [void]$unmappedTopLevelIds.Add([string]$o['id']) }
        }
    }

    # 2. Seed at the program with the requested code.
    $seed = @($Package[$SeedType]) | Where-Object { $_ -is [System.Collections.IDictionary] -and [string]$_['code'] -eq $SeedCode } | Select-Object -First 1
    if (-not $seed) { throw "Closure seed not found: type '$SeedType', code '$SeedCode'." }

    $included = [System.Collections.Generic.HashSet[string]]::new()
    $queue = [System.Collections.Generic.Queue[string]]::new()
    [void]$included.Add([string]$seed['id']); $queue.Enqueue([string]$seed['id'])
    $danglingRefs = @{}   # idString (bare-string UID) refs whose target isn't in the package, keyed by uid
    $structuredUnresolved = @{}   # structured {id} refs to a top-level object of an unmapped collection (not mapped/excluded/deferred) — dropped; flagged so the type can be mapped, keyed by uid

    # Drain the worklist to a fixpoint: forward structured {id} refs (wrapper-agnostic) + bare-string UID refs
    # (idString fields the {id} walk can't see, e.g. programRuleActions.templateUid -> notification template)
    # + reverse-by-program/-stage inclusion.
    $drain = {
        while ($queue.Count -gt 0) {
            $cur = $queue.Dequeue()
            $entry = $index[$cur]
            if (-not $entry) { continue }
            $refs = [System.Collections.Generic.HashSet[string]]::new()
            Add-NeoIPCMetadataRefId -Node $entry.Object -IsRoot $true -Acc $refs
            foreach ($r in $refs) {
                if ($index.ContainsKey($r)) { if ($included.Add($r)) { $queue.Enqueue($r) } }
                elseif ($unmappedTopLevelIds.Contains($r) -and -not $structuredUnresolved.ContainsKey($r)) {
                    $structuredUnresolved[$r] = [pscustomobject]@{ Uid = $r; FromType = $entry.Type; FromId = $cur }
                }
            }
            $tmap = $script:NeoIPCMetadataTypeMaps[$entry.Type]
            if ($tmap) {
                foreach ($prop in $tmap.Properties.Keys) {
                    if ($tmap.Properties[$prop] -ne 'idString') { continue }
                    $u = [string]$entry.Object[$prop]
                    if (-not $u) { continue }
                    if ($index.ContainsKey($u)) { if ($included.Add($u)) { $queue.Enqueue($u) } }
                    elseif (-not $danglingRefs.ContainsKey($u)) { $danglingRefs[$u] = [pscustomobject]@{ Uid = $u; Field = $prop; FromType = $entry.Type; FromId = $cur } }
                }
            }
            if ($entry.Type -eq 'programs' -and $byProgram.ContainsKey($cur)) {
                foreach ($r in $byProgram[$cur]) { if ($included.Add($r)) { $queue.Enqueue($r) } }
            }
            if ($entry.Type -eq 'programStages' -and $byStage.ContainsKey($cur)) {
                foreach ($r in $byStage[$cur]) { if ($included.Add($r)) { $queue.Enqueue($r) } }
            }
        }
    }
    & $drain

    # 3. Safety net (run to a FIXPOINT): every UID embedded in an INCLUDED object's expressions must already be
    #    in the closure. Objects can ENTER the closure late — rescued as a StructuredMiss, or recovered by the
    #    membership/ownership pass (3b) — so the expression scan, the structured drain, and the recovery are
    #    iterated together until a full pass adds nothing; otherwise a late-added object's OWN expression-only
    #    dependency (a second-order ref) would be dropped unseen. $scannedForExpr makes each pass cheap by
    #    scanning only ids not yet expression-scanned.
    #    - StructuredMiss: target IS in the indexed metadata but the structured walk didn't reach it — a real
    #      dropped dependency (the DHIS2-export bug). Pulled in here AND reported (for NeoIPC: expected none).
    #    - Unresolved: target is NOT in the indexed metadata — a stop-type (OUG / COC, expected as an overlay),
    #      an unmapped type (constant / dataSet / indicator / relationshipType — the type maps would need
    #      extending if NeoIPC adopts it), or a dangling ref. Reported, never silently dropped.
    $structuredMiss = @{}
    $unresolved = @{}
    $scannedForExpr = [System.Collections.Generic.HashSet[string]]::new()
    do {
        $startCount = $included.Count
        foreach ($id in @($included)) {
            if (-not $scannedForExpr.Add($id)) { continue }   # scan each object's expressions only once
            $strings = [System.Collections.Generic.List[string]]::new()
            Get-NeoIPCMetadataStringValue -Node $index[$id].Object -Acc $strings
            foreach ($s in $strings) {
                foreach ($ref in (Get-NeoIPCMetadataExpressionRef -Text $s)) {
                    if ($included.Contains($ref.Uid)) { continue }
                    if ($index.ContainsKey($ref.Uid)) {
                        if (-not $structuredMiss.ContainsKey($ref.Uid)) {
                            $structuredMiss[$ref.Uid] = [pscustomobject]@{ Uid = $ref.Uid; Form = $ref.Form; TargetType = $index[$ref.Uid].Type; FirstSeenOn = $id }
                        }
                        if ($included.Add($ref.Uid)) { $queue.Enqueue($ref.Uid) }
                    }
                    elseif (-not $unresolved.ContainsKey($ref.Uid)) {
                        $unresolved[$ref.Uid] = [pscustomobject]@{ Uid = $ref.Uid; Form = $ref.Form; FirstSeenOn = $id }
                    }
                }
            }
        }
        & $drain   # a StructuredMiss can transitively pull in more via structured refs

        # 3b. Recover NeoIPC metadata not reachable from the program: grouping objects whose members intersect
        #     the closure, and the wholly-deployment-owned types (attributes). Inner fixpoint so optionGroupSets
        #     pick up after their optionGroups; the trailing drain pulls the newcomers' own structured refs.
        do {
            $added = $false
            foreach ($type in $script:NeoIPCMetadataMembershipFields.Keys) {
                $field = $script:NeoIPCMetadataMembershipFields[$type]
                foreach ($o in @($Package[$type])) {
                    if ($o -isnot [System.Collections.IDictionary]) { continue }
                    $oid = [string]$o['id']
                    if (-not $oid -or $included.Contains($oid)) { continue }
                    $hit = $false
                    foreach ($m in @($o[$field])) { if ($m -is [System.Collections.IDictionary] -and $included.Contains([string]$m['id'])) { $hit = $true; break } }
                    if ($hit -and $included.Add($oid)) { $queue.Enqueue($oid); $added = $true }
                }
            }
            foreach ($type in $script:NeoIPCMetadataKeepAllTypes) {
                foreach ($o in @($Package[$type])) {
                    if ($o -isnot [System.Collections.IDictionary]) { continue }
                    $oid = [string]$o['id']
                    if ($oid -and $included.Add($oid)) { $queue.Enqueue($oid); $added = $true }
                }
            }
            foreach ($type in $script:NeoIPCMetadataExpressionSourceTypes) {
                foreach ($o in @($Package[$type])) {
                    if ($o -isnot [System.Collections.IDictionary]) { continue }
                    $oid = [string]$o['id']
                    if (-not $oid -or $included.Contains($oid)) { continue }
                    $strings = [System.Collections.Generic.List[string]]::new()
                    Get-NeoIPCMetadataStringValue -Node $o -Acc $strings
                    $hit = $false
                    foreach ($s in $strings) {
                        foreach ($ref in (Get-NeoIPCMetadataExpressionRef -Text $s)) { if ($included.Contains($ref.Uid)) { $hit = $true; break } }
                        if ($hit) { break }
                    }
                    if ($hit -and $included.Add($oid)) { $queue.Enqueue($oid); $added = $true }
                }
            }
        } while ($added)
        & $drain
    } while ($included.Count -ne $startCount)   # repeat until the expression scan + drain + recovery converge

    # 4. Pruned package: each top-level non-nested, non-excluded type filtered to the included ids.
    $pruned = [ordered]@{}
    foreach ($type in $script:NeoIPCMetadataTypeMaps.Keys) {
        $map = $script:NeoIPCMetadataTypeMaps[$type]
        if ($map.Nesting -eq 'NestedOnly') { continue }
        if ($script:NeoIPCMetadataExcludedTypes -contains $type) { continue }
        $kept = @(@($Package[$type]) | Where-Object { $_ -is [System.Collections.IDictionary] -and $included.Contains([string]$_['id']) })
        if ($kept.Count -gt 0) { $pruned[$type] = $kept }
    }

    return @{
        Package          = $pruned
        IncludedIds      = $included
        SeedId           = [string]$seed['id']
        IndexedCount     = $index.Count
        IncludedCount    = $included.Count
        ExpressionMisses = @($structuredMiss.Values)      # in-package refs the structured walk dropped (want: 0)
        ExpressionUnresolved = @($unresolved.Values)       # expression refs to non-indexed targets (overlays/unmapped)
        DanglingStringRefs = @($danglingRefs.Values)       # idString refs (e.g. templateUid) whose target is absent from the package
        StructuredUnresolved = @($structuredUnresolved.Values)  # structured {id} refs to a non-indexed, non-excluded type — dropped; flag to map that type
    }
}

function Merge-NeoIPCMetadataPackage {
    # Build the canonical pipeline input from two exports. The full /api/metadata export is the BASE (most
    # complete: all standard types, the analytics groups/attributes, every data element incl. expression-only
    # ones, and richer nested programStageDataElements/programTrackedEntityAttributes). The full export cannot
    # carry programNotificationTemplates (ProgramNotificationTemplate is not a MetadataObject, so it is not a
    # metadata-export type), so those are spliced in from a program dependency export
    # (/api/programs/{id}/metadata). TARGETED by design: only the named $Types are taken from $Supplement —
    # everything else stays exactly as the base has it (the dependency export's flattened, lower-detail
    # PSDE/PTEA are deliberately NOT taken). Returns a new ordered package; inputs are not mutated.
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]$Base,
        [Parameter(Mandatory)]$Supplement,
        [string[]]$Types = @('programNotificationTemplates')
    )
    $merged = [ordered]@{}
    foreach ($k in $Base.Keys) { $merged[$k] = $Base[$k] }
    foreach ($t in $Types) {
        if ($Supplement -is [System.Collections.IDictionary] -and $Supplement.Contains($t) -and @($Supplement[$t]).Count -gt 0) {
            $merged[$t] = $Supplement[$t]
        }
        else { Write-Warning "Supplement export has no '$t' to merge in." }
    }
    return $merged
}
