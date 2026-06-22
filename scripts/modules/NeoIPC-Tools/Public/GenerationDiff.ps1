# The validation gate for the ontology / capability-matrix generation: a CLASSIFIED diff of the generated families
# against the deployed export. The deployed program is a baseline to review against, not a target to match, so a
# large fully-classified diff is healthy; the gate failure is any delta that does not match a known bucket.

function Compare-NeoIPCGeneratedMetadata {
    <#
    .SYNOPSIS
        Classified diff of the ontology / capability-matrix GENERATED families against the deployed export.
    .DESCRIPTION
        Runs the nine generators against $ExistingPackage, scopes the deployed objects to the same generated
        families (the option set by the generated set ids; the data elements / variables / rules / actions via
        Get-NeoIPCMetadataGeneratedKeys), diffs each family by id modulo the normalization strip-list AND the
        deferred `translations` dimension, and CLASSIFIES every Added / Removed / Changed object into a documented
        bucket.

        The deployed program is a baseline to review against, not a target to match (it carries hand-maintained
        drift, dead config and bugs), so a large, fully-classified diff is the healthy outcome. The gate FAILURE is
        any object whose delta does not match a known bucket — class 'Unclassified' (a silent / unexpected add,
        drop or change). Buckets: option additions = 'TaxonomicAddition'; option name/sortOrder = 'TaxonomicNaming'
        (the YAML current names — incl. the bracketed rank/synonym tag reproduced from the ontology — and the
        deterministic order; the residual name diffs are genuine taxonomy deltas: reclassifications, the LPSN
        subsp. form, typo fixes);
        data-element name/shortName/formName/zeroIsSignificant = 'DataElementNormalisation' (the double-space typo
        + substance padding + the _SOURCE zeroIsSignificant fix); variable name = 'VariablePadding'; rule
        condition/priority/name/description/action-membership = 'RuleNormalisation' (the field-gating guard, uniform
        priorities, substance padding, Model-A reveal); action data/content/dataElement = 'ActionNormalisation'
        (incl. the taxonomic resistance / common-commensal code-set enumerations). Added rules/actions =
        'CoverageAddition' (the SSI-secondary-slot-2 reveal the deployed program omits) or 'FieldGatingChange';
        removed = 'SupersededAggregate' (the stale HAP aggregate), 'BusinessInterlock' (a hand-authored action on a
        reproduced rule whose target is outside the generated families — e.g. the BSI no-positive-culture HIDEFIELD
        the assembler salvages) or 'FieldGatingChange'.

        The antibiotic domain adds its own families + buckets: the NEOIPC_ANTIMICROBIAL_SUBSTANCES option set
        (options membership = 'OptionSetGrowth'); its options (added oral route-splits = 'SubstanceAddition'; the
        four documented code migrations = 'SubstanceCodeMigration'; route-qualifier name + alphabetical re-rank =
        'SubstanceNaming'); the ATC-4 + AWaRe option GROUPS (membership = 'GroupMembership'); and the ATC5 /
        WHO_AWARE option-group-SETS (member-order normalisation = 'GroupSetNormalisation'). Pure object processing —
        no DHIS2 API calls. Returns one record per delta: { Type; Kind; Id; Key; Class; DiffFields }.
    .PARAMETER ExistingPackage
        The parsed DHIS2 export the generators reconcile against and the diff baseline.
    .PARAMETER OntologyPath
        Path to the infectious-agent YAML (the pathogen option set + resistance / common-commensal flags). Defaults
        (in each generator) to the canonical file in the repository.
    .PARAMETER PathogenCount
        Pathogen slots per applicable stage (1-9). Default: the module-wide count (matching the deployed export).
    .PARAMETER SubstanceCount
        Antimicrobial-substance slots (1-99). Default: the module-wide count (matching the deployed export).
    .OUTPUTS
        [object[]] of classified delta records; empty when the generated families equal the deployed ones.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$ExistingPackage,
        [string]$OntologyPath,
        [ValidateRange(1, 9)][int]$PathogenCount = $script:NeoIPCPathogenSlotCount,
        [ValidateRange(1, 99)][int]$SubstanceCount = $script:NeoIPCSubstanceSlotCount
    )
    $ontologyArgs = @{}; if ($OntologyPath) { $ontologyArgs['Path'] = $OntologyPath }
    $optionFrag  = New-NeoIPCPathogenOptionSet @ontologyArgs -ExistingPackage $ExistingPackage
    $patDeFrag   = New-NeoIPCPathogenDataElement -ExistingPackage $ExistingPackage -PathogenCount $PathogenCount
    $subDeFrag   = New-NeoIPCSubstanceDataElement -ExistingPackage $ExistingPackage -SubstanceCount $SubstanceCount
    $patVarFrag  = New-NeoIPCPathogenVariable -ExistingPackage $ExistingPackage -PathogenCount $PathogenCount
    $fgVarFrag   = New-NeoIPCPathogenFieldGatingVariable -ExistingPackage $ExistingPackage -PathogenCount $PathogenCount
    $subVarFrag  = New-NeoIPCSubstanceVariable -ExistingPackage $ExistingPackage -SubstanceCount $SubstanceCount
    $patRuleFrag = New-NeoIPCPathogenRule @ontologyArgs -ExistingPackage $ExistingPackage -PathogenCount $PathogenCount
    $fgRuleFrag  = New-NeoIPCPathogenFieldGatingRule @ontologyArgs -ExistingPackage $ExistingPackage -PathogenCount $PathogenCount
    $subRuleFrag = New-NeoIPCSubstanceRule -ExistingPackage $ExistingPackage -SubstanceCount $SubstanceCount
    $abxOptFrag    = New-NeoIPCAntimicrobialOptionSet -ExistingPackage $ExistingPackage
    $abxGrpFrag    = New-NeoIPCAntibioticOptionGroup -OptionSet $abxOptFrag -ExistingPackage $ExistingPackage
    $abxGrpSetFrag = New-NeoIPCAntibioticOptionGroupSet -OptionGroup $abxGrpFrag -ExistingPackage $ExistingPackage

    $gen = [ordered]@{
        optionSets           = @($optionFrag['optionSets']) + @($abxOptFrag['optionSets'])
        options              = @($optionFrag['options']) + @($abxOptFrag['options'])
        optionGroups         = @($abxGrpFrag['optionGroups'])
        optionGroupSets      = @($abxGrpSetFrag['optionGroupSets'])
        dataElements         = @($patDeFrag['dataElements']) + @($subDeFrag['dataElements'])
        programRuleVariables = @($patVarFrag['programRuleVariables']) + @($fgVarFrag['programRuleVariables']) + @($subVarFrag['programRuleVariables'])
        programRules         = @($patRuleFrag['programRules']) + @($fgRuleFrag['programRules']) + @($subRuleFrag['programRules'])
        programRuleActions   = @($patRuleFrag['programRuleActions']) + @($fgRuleFrag['programRuleActions']) + @($subRuleFrag['programRuleActions'])
    }
    $genAbxOsId = if (@($abxOptFrag['optionSets']).Count -gt 0) { [string]$abxOptFrag['optionSets'][0]['id'] } else { $null }   # to split the shared 'options' family pathogen vs antibiotic

    $ordinal = [System.StringComparer]::Ordinal
    $gk = Get-NeoIPCMetadataGeneratedKeys -Package $ExistingPackage -PathogenCount $PathogenCount -SubstanceCount $SubstanceCount
    function New-NeoIPCDiffKeySet([string[]]$Values) { $s = [System.Collections.Generic.HashSet[string]]::new($ordinal); foreach ($v in $Values) { [void]$s.Add($v) }; $s }
    $genOsIds   = New-NeoIPCDiffKeySet @($gen['optionSets'] | ForEach-Object { [string]$_['id'] })
    $genDeIds   = New-NeoIPCDiffKeySet @($gen['dataElements'] | ForEach-Object { [string]$_['id'] })
    $genRuleIds = New-NeoIPCDiffKeySet @($gen['programRules'] | ForEach-Object { [string]$_['id'] })
    $depRuleNameById = @{}
    foreach ($r in @($ExistingPackage['programRules'])) { if ($r -is [System.Collections.IDictionary]) { $depRuleNameById[[string]$r['id']] = [string]$r['name'] } }

    function Test-NeoIPCDiffInFamily($type, $o) {
        if ($o -isnot [System.Collections.IDictionary]) { return $false }
        if ($type -eq 'optionSets') { return $genOsIds.Contains([string]$o['id']) }
        if ($type -eq 'options') { $os = $o['optionSet']; return ($os -is [System.Collections.IDictionary] -and $genOsIds.Contains([string]$os['id'])) }
        if ($type -eq 'dataElements') { return $gk.DataElementCodes.Contains([string]$o['code']) }
        if ($type -eq 'programRuleVariables') { $n = [string]$o['name']; return ($n -and $gk.VariableNames.Contains((ConvertTo-NeoIPCSubstanceUnpaddedName $n))) }
        if ($type -eq 'programRules') { $n = [string]$o['name']; return ($n -and $gk.RuleNames.Contains((ConvertTo-NeoIPCSubstanceUnpaddedName $n))) }
        if ($type -eq 'programRuleActions') { $pr = $o['programRule']; $rid = if ($pr -is [System.Collections.IDictionary]) { [string]$pr['id'] } else { [string]$pr }; return ($rid -and $gk.ExcludedRuleIds.Contains($rid)) }
        if ($type -eq 'optionGroups') { $c = [string]$o['code']; return (($c -like 'WHO_AWARE_*') -or ($c -cmatch '^[A-Z][0-9]{2}[A-Z]{2}$')) }   # antibiotic groups are AWaRe or ATC-4 (5-char) only
        if ($type -eq 'optionGroupSets') { $c = [string]$o['code']; return (($c -ceq 'ATC5') -or ($c -ceq 'WHO_AWARE')) }
        $false
    }
    function Test-NeoIPCDiffAbxOption($o) { $os = $o['optionSet']; return ($os -is [System.Collections.IDictionary] -and [string]$os['id'] -eq $genAbxOsId) }
    function Get-NeoIPCDiffStripped($o) {
        $c = Remove-NeoIPCMetadataNoise -Object $o
        if ($c -is [System.Collections.IDictionary] -and $c.Contains('translations')) { $c.Remove('translations') }
        $c
    }
    function Get-NeoIPCDiffFields($a, $b) {
        $keys = @(@($a.Keys) + @($b.Keys) | Select-Object -Unique)
        @($keys | Where-Object {
                $av = if ($a.Contains($_)) { (ConvertTo-NeoIPCMetadataCanonical $a[$_]) | ConvertTo-Json -Compress -Depth 40 } else { '<absent>' }
                $bv = if ($b.Contains($_)) { (ConvertTo-NeoIPCMetadataCanonical $b[$_]) | ConvertTo-Json -Compress -Depth 40 } else { '<absent>' }
                $av -ne $bv
            } | Sort-Object)
    }

    $changeAllowed = @{
        optionSets           = @('options', 'version')
        options              = @('name', 'sortOrder')                                  # pathogen; antibiotic options also allow 'code' (see below)
        optionGroups         = @('options', 'name', 'shortName', 'description')
        optionGroupSets      = @('optionGroups', 'name', 'description')
        dataElements         = @('name', 'shortName', 'formName', 'zeroIsSignificant')
        programRuleVariables = @('name')
        programRules         = @('condition', 'priority', 'name', 'description', 'programRuleActions')
        programRuleActions   = @('data', 'content', 'dataElement', 'location')
    }
    $changeClass = @{
        optionSets = 'OptionSetGrowth'; options = 'TaxonomicNaming'; dataElements = 'DataElementNormalisation'
        optionGroups = 'GroupMembership'; optionGroupSets = 'GroupSetNormalisation'
        programRuleVariables = 'VariablePadding'; programRules = 'RuleNormalisation'; programRuleActions = 'ActionNormalisation'
    }
    # Antibiotic options diverge from pathogen options (the 4 documented code migrations + the route-qualifier name
    # + alphabetical re-rank), so they carry their own allowed fields + classes, keyed off the generated set id.
    $abxOptAllowed = New-NeoIPCDiffKeySet @('code', 'name', 'sortOrder')

    # The rule add/remove split feeds the action classification (an action on an ADDED rule is coverage; on a
    # reproduced rule it is a field-gating change).
    $depRuleInFamilyIds = New-NeoIPCDiffKeySet @(@($ExistingPackage['programRules']) | Where-Object { Test-NeoIPCDiffInFamily 'programRules' $_ } | ForEach-Object { [string]$_['id'] })
    $addedRuleIds = New-NeoIPCDiffKeySet @($genRuleIds | Where-Object { -not $depRuleInFamilyIds.Contains($_) })

    $records = [System.Collections.Generic.List[object]]::new()
    function Add-NeoIPCDiffRecord($Type, $Kind, $Id, $Key, $Class, $DiffFields) {
        $records.Add([pscustomobject]@{ Type = $Type; Kind = $Kind; Id = $Id; Key = $Key; Class = $Class; DiffFields = ($DiffFields -join ',') })
    }

    foreach ($type in 'optionSets', 'options', 'optionGroups', 'optionGroupSets', 'dataElements', 'programRuleVariables', 'programRules', 'programRuleActions') {
        $depStripped = @{}; $depRaw = @{}
        foreach ($o in @($ExistingPackage[$type])) { if (Test-NeoIPCDiffInFamily $type $o) { $id = [string]$o['id']; $depStripped[$id] = (Get-NeoIPCDiffStripped $o); $depRaw[$id] = $o } }
        $genStripped = @{}; $genRaw = @{}
        foreach ($o in @($gen[$type])) { if ($o -is [System.Collections.IDictionary]) { $id = [string]$o['id']; $genStripped[$id] = (Get-NeoIPCDiffStripped $o); $genRaw[$id] = $o } }
        $allowed = New-NeoIPCDiffKeySet $changeAllowed[$type]

        foreach ($id in @($genStripped.Keys)) {
            $key = [string]$genRaw[$id]['code']; if (-not $key) { $key = [string]$genRaw[$id]['name'] }
            if ($depStripped.ContainsKey($id)) {
                $diff = @(Get-NeoIPCDiffFields $depStripped[$id] $genStripped[$id])
                if ($diff.Count -eq 0) { continue }
                if ($type -eq 'options' -and (Test-NeoIPCDiffAbxOption $genRaw[$id])) {
                    # Antibiotic options: a 'code' change is a benign 'SubstanceCodeMigration' ONLY when the
                    # (deployed code -> generated code) pair is one of the documented renames
                    # ($script:NeoIPCAntibioticCodeRename) — any other code change is 'Unclassified' so the gate
                    # cannot wave through an undocumented rename (the highest-consequence, data-affecting delta). A
                    # name/sortOrder-only change is 'SubstanceNaming' (route qualifier + alphabetical re-rank). The
                    # rename map itself is pinned to exactly the documented set by a test.
                    $class = if (@($diff | Where-Object { -not $abxOptAllowed.Contains($_) }).Count -ne 0) { 'Unclassified' }
                    elseif ($diff -contains 'code') {
                        $depCode = [string]$depRaw[$id]['code']; $genCode = [string]$genRaw[$id]['code']
                        if ($script:NeoIPCAntibioticCodeRename.Contains($depCode) -and $script:NeoIPCAntibioticCodeRename[$depCode] -ceq $genCode) { 'SubstanceCodeMigration' } else { 'Unclassified' }
                    }
                    else { 'SubstanceNaming' }
                }
                else {
                    $class = if (@($diff | Where-Object { -not $allowed.Contains($_) }).Count -eq 0) { $changeClass[$type] } else { 'Unclassified' }
                }
                Add-NeoIPCDiffRecord $type 'Changed' $id $key $class $diff
                continue
            }
            $class = switch ($type) {
                'options' { if (Test-NeoIPCDiffAbxOption $genRaw[$id]) { 'SubstanceAddition' } else { 'TaxonomicAddition' } }
                'programRules' { 'CoverageAddition' }
                'programRuleActions' {
                    $pr = $genRaw[$id]['programRule']; $rid = if ($pr -is [System.Collections.IDictionary]) { [string]$pr['id'] } else { [string]$pr }
                    if ($rid -and $addedRuleIds.Contains($rid)) { 'CoverageAddition' } elseif ($rid -and $genRuleIds.Contains($rid)) { 'FieldGatingChange' } else { 'Unclassified' }
                }
                default { 'Unclassified' }
            }
            Add-NeoIPCDiffRecord $type 'Added' $id $key $class @()
        }
        foreach ($id in @($depStripped.Keys)) {
            if ($genStripped.ContainsKey($id)) { continue }
            $o = $depRaw[$id]
            $key = [string]$o['code']; if (-not $key) { $key = [string]$o['name'] }
            $class = switch ($type) {
                'programRules' { if ($script:NeoIPCMetadataRetiredRuleNames.Contains([string]$o['name'])) { 'SupersededAggregate' } else { 'Unclassified' } }
                'programRuleActions' {
                    $pr = $o['programRule']; $rid = if ($pr -is [System.Collections.IDictionary]) { [string]$pr['id'] } else { [string]$pr }
                    $ownName = if ($rid) { [string]$depRuleNameById[$rid] } else { '' }
                    $tgt = $o['dataElement']; $tgtId = if ($tgt -is [System.Collections.IDictionary]) { [string]$tgt['id'] } else { $null }
                    if ($ownName -and $script:NeoIPCMetadataRetiredRuleNames.Contains($ownName)) { 'SupersededAggregate' }
                    elseif ($rid -and $genRuleIds.Contains($rid) -and $tgtId -and -not $genDeIds.Contains($tgtId)) { 'BusinessInterlock' }
                    elseif ($rid -and $genRuleIds.Contains($rid)) { 'FieldGatingChange' }
                    else { 'Unclassified' }
                }
                default { 'Unclassified' }
            }
            Add-NeoIPCDiffRecord $type 'Removed' $id $key $class @()
        }
    }
    , [object[]]$records.ToArray()
}
