# Play/test-package assembly: stitch the captured config (the NEOIPC_CORE dependency closure + the
# non-closure group / role / level DEFINITIONS) together with the authored org units, users, and group
# memberships into one importable package. The captured org-unit instances and user accounts are anonymised
# in the export and excluded; the authored content replaces them. No DHIS2 API calls.

function Add-NeoIPCMetadataId {
    <#
    .SYNOPSIS
        Recursively collect every 'id' value found anywhere in a metadata node into a HashSet.
    .DESCRIPTION
        Walks dictionaries and collections, adding the value of every 'id' key — object identities AND {id}
        reference targets alike. The assembly collision check uses this: an authored minted UID that appears
        here would clash with a captured identity at idScheme=UID import. Over-collecting reference ids is
        intentional (conservative) — an authored mint matching even a referenced id signals a real clash.
        Mutates the passed accumulator in place.
    .PARAMETER Node
        The metadata node to walk (package, object, array, or scalar).
    .PARAMETER Accumulator
        The HashSet to add discovered ids to.
    #>
    param(
        [AllowNull()]$Node,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.HashSet[string]]$Accumulator
    )
    if ($Node -is [System.Collections.IDictionary]) {
        foreach ($k in @($Node.Keys)) {
            if ($k -eq 'id') {
                $v = [string]$Node[$k]
                if ($v) { [void]$Accumulator.Add($v) }
            }
            else { Add-NeoIPCMetadataId -Node $Node[$k] -Accumulator $Accumulator }
        }
    }
    elseif ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [string]) {
        foreach ($item in $Node) { Add-NeoIPCMetadataId -Node $item -Accumulator $Accumulator }
    }
}

function Join-NeoIPCMetadataPackage {
    <#
    .SYNOPSIS
        Combine a captured config package with authored org units, users, and group memberships.
    .DESCRIPTION
        The pure assembly step (no I/O). Given the captured config (closure types + non-closure group / role /
        level definitions, already noise-stripped so the anonymised per-deployment membership is gone) and the
        authored content, it:
          1. Collision-checks every authored minted UID (org units, users) against every id already present in
             the config AND against each other — a clash would silently clobber a real config object at
             idScheme=UID import, so it is a fail-loud error.
          2. Sets organisationUnits / users to the authored objects (the captured, anonymised ones are excluded).
          3. Drops categoryOptionCombos (server-generated, regenerated on import).
          4. Applies the group memberships group-side (organisationUnitGroups.organisationUnits,
             userGroups.users) via Set-NeoIPCGroupMembership — these arrays deliberately do not ride the
             round-trip type-map/strip path, so assembly is where they are written.
        Mutates and returns the Config dictionary. No DHIS2 API calls.
    .PARAMETER Config
        The captured config package (ordered dict: type -> object array), noise-stripped.
    .PARAMETER OrgUnit
        The authored organisationUnit objects (from Read-NeoIPCAuthoredOrgUnit).
    .PARAMETER User
        The authored user objects (from ConvertFrom-NeoIPCAuthoredUserCsv).
    .PARAMETER OrgUnitGroupMembership
        Optional org-unit-group membership map (group code -> [member UID]).
    .PARAMETER UserGroupMembership
        Optional user-group membership map (group code -> [member UID]).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.IEnumerable]$OrgUnit,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.IEnumerable]$User,
        [System.Collections.IDictionary]$OrgUnitGroupMembership,
        [System.Collections.IDictionary]$UserGroupMembership
    )
    # Collision check: authored minted UIDs vs every captured identity, and vs each other.
    $captured = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    Add-NeoIPCMetadataId -Node $Config -Accumulator $captured
    foreach ($o in $OrgUnit) {
        $id = [string]$o['id']
        if (-not $captured.Add($id)) { throw "Authored org unit '$($o['code'])' minted UID '$id', which collides with a captured object id (or another authored UID)." }
    }
    foreach ($u in $User) {
        $id = [string]$u['id']
        if (-not $captured.Add($id)) { throw "Authored user '$($u['username'])' minted UID '$id', which collides with a captured object id (or another authored UID)." }
    }

    # Authored instances replace the excluded (anonymised) captured ones.
    $Config['organisationUnits'] = @($OrgUnit)
    $Config['users'] = @($User)
    if ($Config.Contains('categoryOptionCombos')) { $Config.Remove('categoryOptionCombos') }

    # Memberships applied group-side (not via the strip/round-trip path). No $Config.Contains(...) guard: a
    # non-empty membership map against a missing group type must fail loud via Set-NeoIPCGroupMembership's own
    # group-not-present check, not be silently dropped (the config always carries both group types on the live
    # path, so this only hardens the contract for a malformed config).
    if ($OrgUnitGroupMembership -and @($OrgUnitGroupMembership.Keys).Count) {
        [void](Set-NeoIPCGroupMembership -Group @($Config['organisationUnitGroups']) -Membership $OrgUnitGroupMembership -MemberProperty 'organisationUnits')
    }
    if ($UserGroupMembership -and @($UserGroupMembership.Keys).Count) {
        [void](Set-NeoIPCGroupMembership -Group @($Config['userGroups']) -Membership $UserGroupMembership -MemberProperty 'users')
    }
    $Config
}

function Add-NeoIPCGeneratedOptionMetadata {
    <#
    .SYNOPSIS
        Splice the still-generated OPTION-DOMAIN families into a directory-sourced config — export-free.
    .DESCRIPTION
        The export-independent build path. The matrix families (per-slot DEs / PRVs / rules / actions) are now
        MATERIALISED in the directory config, so only the option-domain stays generated from its richer directory
        source: the NEOIPC_PATHOGENS option set + options (from the infectious-agent YAML + the UID sidecar), the
        NEOIPC_ANTIMICROBIAL_SUBSTANCES option set + options, the 34 ATC-4 + 3 AWaRe option groups, and the
        ATC5 / WHO_AWARE option-group-sets (from the antibiotics curation CSVs, whose `uid` columns carry the
        opaque UIDs). None of these are in the directory config (they are directory-excluded), so this is a pure
        ADD — no replace-by-key, no salvage. The generators run WITHOUT -ExistingPackage (no seed); the deployed
        sharing they used to copy is reproduced from the PUBLIC_RW profile, and the group-sets' dataDimension
        defaults to true (both verified against the deployed export). Fails loud on a duplicate id across the
        spliced result. Mutates and returns Config. No DHIS2 API calls.
    .PARAMETER Config
        The directory-sourced config package (ordered dict: type -> object array) — spliced in place.
    .PARAMETER OntologyPath
        Path to the infectious-agent YAML (drives the pathogen option set). Defaults in the generator.
    .PARAMETER PoDirectory
        Directory of the po4a locale catalogues for option-label localization. Defaults to the repo po/ directory.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [string]$OntologyPath,
        [string]$PoDirectory = (Join-Path $PSScriptRoot '..' '..' '..' '..' 'po')
    )
    $ontologyArgs = @{}
    if ($OntologyPath) { $ontologyArgs['Path'] = $OntologyPath }

    # Generate the option-domain from its directory sources — no -ExistingPackage (export-free).
    $optionFrag    = New-NeoIPCPathogenOptionSet @ontologyArgs -PoDirectory $PoDirectory
    $abxOptFrag    = New-NeoIPCAntimicrobialOptionSet -PoDirectory $PoDirectory
    $abxGrpFrag    = New-NeoIPCAntibioticOptionGroup -OptionSet $abxOptFrag -PoDirectory $PoDirectory
    $abxGrpSetFrag = New-NeoIPCAntibioticOptionGroupSet -OptionGroup $abxGrpFrag -PoDirectory $PoDirectory

    # Reproduce the deployed sharing the export used to supply: PUBLIC_RW on the option sets / groups / group-sets,
    # and dataDimension=true on the group-sets (options carry no sharing of their own). A fresh sharing literal per
    # object — never a shared reference — so the objects stay independent.
    $genOptionSets      = @($optionFrag['optionSets']) + @($abxOptFrag['optionSets'])
    $genOptionGroups    = @($abxGrpFrag['optionGroups'])
    $genOptionGroupSets = @($abxGrpSetFrag['optionGroupSets'])
    foreach ($o in ($genOptionSets + $genOptionGroups)) { if (-not $o.Contains('sharing')) { $o['sharing'] = [ordered]@{ public = 'rw------' } } }
    foreach ($gs in $genOptionGroupSets) {
        if (-not $gs.Contains('dataDimension')) { $gs['dataDimension'] = $true }
        if (-not $gs.Contains('sharing')) { $gs['sharing'] = [ordered]@{ public = 'rw------' } }
    }

    $genOptions = @($optionFrag['options']) + @($abxOptFrag['options'])

    # Pure ADD: append the generated option-domain to the directory config (these types are directory-excluded, so
    # there is nothing to replace). Initialise a target collection when the directory carried none. A List append
    # (not the + operator) keeps it unambiguous when an existing collection is present.
    $splices = [ordered]@{
        optionSets      = $genOptionSets
        options         = $genOptions
        optionGroups    = $genOptionGroups
        optionGroupSets = $genOptionGroupSets
    }
    foreach ($type in @($splices.Keys)) {
        $merged = [System.Collections.Generic.List[object]]::new()
        if ($Config.Contains($type)) { foreach ($x in @($Config[$type])) { $merged.Add($x) } }
        foreach ($x in @($splices[$type])) { $merged.Add($x) }
        $Config[$type] = $merged.ToArray()
    }

    # Fail loud on any duplicate id introduced by the splice.
    $ordinal = [System.StringComparer]::Ordinal
    foreach ($type in 'optionSets', 'options', 'optionGroups', 'optionGroupSets') {
        $seen = [System.Collections.Generic.HashSet[string]]::new($ordinal)
        foreach ($o in @($Config[$type])) {
            if ($o -isnot [System.Collections.IDictionary]) { continue }
            $id = [string]$o['id']
            if ($id -and -not $seen.Add($id)) { throw "Generated option-domain splice produced a duplicate id '$id' in '$type'." }
        }
    }
    $Config
}

function Add-NeoIPCGeneratedMetadata {
    <#
    .SYNOPSIS
        Splice the ontology / capability-matrix generated objects into a closure config, replacing the deployed
        generated-class objects with the freshly generated ones.
    .DESCRIPTION
        Runs the ontology-, matrix- and source-driven generators against the export and replaces the
        deployed generated-class objects in the config with the generated ones:
          - the NEOIPC_PATHOGENS option set + its options (from the infectious-agent ontology),
          - the NEOIPC_ANTIMICROBIAL_SUBSTANCES option set + options, the 34 ATC-4 + 3 AWaRe option groups, and the
            ATC5 / WHO_AWARE option-group-sets (from the reconciled antibiotic sources),
          - the per-slot pathogen + antimicrobial-substance data elements,
          - the resistance, field-gating, virus and substance program-rule variables,
          - the resistance, field-gating, virus and substance program rules + actions (the HAP `set virus` rule
            classifies each slot's organism against the ontology's `Viruses` realm — see New-NeoIPCPathogenVirusRule).
        Replacement is by NATURAL KEY, read from the generator outputs themselves (no pattern matching): a deployed
        object is dropped iff a generated object shares its key — option-set / data-element CODE, program-rule /
        variable NAME, or (for options) membership in the generated NEOIPC_PATHOGENS set — then the generated
        objects are appended. Because each generator preserves the deployed UID where the key matches, a regenerated
        object replaces its deployed counterpart in place (same id); newly minted objects (new option codes, grown
        slots, the SSI-secondary-slot-2 reveal the deployed program omits) are simply added.
        Two deliberate exceptions keep the assembled package import-complete:
          - the stale aggregate rule 'NeoIPC HAP - set pathogen attribute variables' (+ its actions), which the
            per-slot resistance rules supersede, is dropped WITHOUT a generated replacement (the other five HAP
            aggregates feed the pneumonia definition and are kept, because the generators do not reproduce them);
          - a deployed action on a reproduced rule whose target data element is OUTSIDE the generated families
            (e.g. the BSI 'when set' rule's HIDEFIELD on NEOIPC_BSI_NO_POS_CULTURE) is a hand-authored action,
            not part of the per-slot cluster, so it is SALVAGED onto the generated rule rather than dropped.
        Everything else — the infection-definition business rules, the live HAP criterion aggregates, the
        non-pathogen data elements, every other option set — is left exactly as the config has it. Fails loud on a
        duplicate id across the spliced result. Mutates and returns Config. No DHIS2 API calls.
    .PARAMETER Config
        The captured config package (ordered dict: type -> object array), noise-stripped — spliced in place.
    .PARAMETER Export
        The full parsed export — the UID-preservation source the generators reconcile against.
    .PARAMETER OntologyPath
        Path to the infectious-agent YAML (drives the pathogen option set + resistance / common-commensal flags).
        Defaults (in each generator) to the canonical file in the repository.
    .PARAMETER PathogenCount
        Pathogen slots per applicable stage (1-9). Default: the module-wide count.
    .PARAMETER SubstanceCount
        Antimicrobial-substance slots (1-99). Default: the module-wide count.
    .PARAMETER PoDirectory
        Directory of the po4a-generated locale catalogues (infectious_agents.<locale>.po) the pathogen option
        labels are localized from. Defaults to the repository's po/ directory; a non-existent path yields
        English-only options (graceful).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Export,
        [string]$OntologyPath,
        [ValidateRange(1, 9)][int]$PathogenCount = $script:NeoIPCPathogenSlotCount,
        [ValidateRange(1, 99)][int]$SubstanceCount = $script:NeoIPCSubstanceSlotCount,
        [string]$PoDirectory = (Join-Path $PSScriptRoot '..' '..' '..' '..' 'po')
    )

    $ontologyArgs = @{}
    if ($OntologyPath) { $ontologyArgs['Path'] = $OntologyPath }

    # Generate against the export so every reproduced object keeps its deployed UID (preserve-by-key). The pathogen
    # option set is localized from the po4a catalogues (PoDirectory); the other generators carry no translations.
    $optionFrag  = New-NeoIPCPathogenOptionSet @ontologyArgs -ExistingPackage $Export -PoDirectory $PoDirectory
    $patDeFrag   = New-NeoIPCPathogenDataElement -ExistingPackage $Export -PathogenCount $PathogenCount
    $subDeFrag   = New-NeoIPCSubstanceDataElement -ExistingPackage $Export -SubstanceCount $SubstanceCount
    $patVarFrag  = New-NeoIPCPathogenVariable -ExistingPackage $Export -PathogenCount $PathogenCount
    $fgVarFrag   = New-NeoIPCPathogenFieldGatingVariable -ExistingPackage $Export -PathogenCount $PathogenCount
    $subVarFrag  = New-NeoIPCSubstanceVariable -ExistingPackage $Export -SubstanceCount $SubstanceCount
    $patRuleFrag = New-NeoIPCPathogenRule @ontologyArgs -ExistingPackage $Export -PathogenCount $PathogenCount
    $fgRuleFrag  = New-NeoIPCPathogenFieldGatingRule @ontologyArgs -ExistingPackage $Export -PathogenCount $PathogenCount
    $virusVarFrag  = New-NeoIPCPathogenVirusVariable -ExistingPackage $Export -PathogenCount $PathogenCount
    $virusRuleFrag = New-NeoIPCPathogenVirusRule @ontologyArgs -ExistingPackage $Export -PathogenCount $PathogenCount
    $subRuleFrag = New-NeoIPCSubstanceRule -ExistingPackage $Export -SubstanceCount $SubstanceCount
    # Antibiotic domain (from the reconciled antibiotic sources): the NEOIPC_ANTIMICROBIAL_SUBSTANCES option set +
    # options, the 34 ATC-4 + 3 AWaRe option groups, and the ATC5 / WHO_AWARE option-group-sets. The full
    # translatable surface (option/group/group-set name + shortName + description, where present) is localized from
    # the bilingual antibiotic catalogues (po/antibiotics.<locale>.po). The group generator needs the generated
    # option UIDs; the group-set generator needs the generated group UIDs.
    $abxOptFrag    = New-NeoIPCAntimicrobialOptionSet -ExistingPackage $Export -PoDirectory $PoDirectory
    $abxGrpFrag    = New-NeoIPCAntibioticOptionGroup -OptionSet $abxOptFrag -ExistingPackage $Export -PoDirectory $PoDirectory
    $abxGrpSetFrag = New-NeoIPCAntibioticOptionGroupSet -OptionGroup $abxGrpFrag -ExistingPackage $Export -PoDirectory $PoDirectory

    $genOptionSets      = @($optionFrag['optionSets']) + @($abxOptFrag['optionSets'])
    $genOptions         = @($optionFrag['options']) + @($abxOptFrag['options'])
    $genOptionGroups    = @($abxGrpFrag['optionGroups'])
    $genOptionGroupSets = @($abxGrpSetFrag['optionGroupSets'])
    $genDataElements = @($patDeFrag['dataElements']) + @($subDeFrag['dataElements'])
    $genVariables    = @($patVarFrag['programRuleVariables']) + @($fgVarFrag['programRuleVariables']) + @($virusVarFrag['programRuleVariables']) + @($subVarFrag['programRuleVariables'])
    $genRules        = @($patRuleFrag['programRules']) + @($fgRuleFrag['programRules']) + @($virusRuleFrag['programRules']) + @($subRuleFrag['programRules'])
    $genActions      = @($patRuleFrag['programRuleActions']) + @($fgRuleFrag['programRuleActions']) + @($virusRuleFrag['programRuleActions']) + @($subRuleFrag['programRuleActions'])

    $ordinal = [System.StringComparer]::Ordinal
    function New-NeoIPCKeySet([string[]]$Keys) {
        $s = [System.Collections.Generic.HashSet[string]]::new($ordinal)
        foreach ($k in $Keys) { [void]$s.Add($k) }
        $s
    }

    # ---- optionSets / options ------------------------------------------------------------------------------------
    $genOsCodes = New-NeoIPCKeySet @($genOptionSets | ForEach-Object { [string]$_['code'] })
    $genOsIds   = New-NeoIPCKeySet @($genOptionSets | ForEach-Object { [string]$_['id'] })
    $keptOptionSets = @(@($Config['optionSets']) | Where-Object { $_ -is [System.Collections.IDictionary] -and -not $genOsCodes.Contains([string]$_['code']) })
    # Owned options = those whose optionSet ref is a generated set (membership identity; the deployed set id is
    # preserved, so this catches every deployed pathogen option even if its code changed).
    $keptOptions = @(@($Config['options']) | Where-Object {
            if ($_ -isnot [System.Collections.IDictionary]) { return $false }
            $osRef = $_['optionSet']
            -not ($osRef -is [System.Collections.IDictionary] -and $genOsIds.Contains([string]$osRef['id']))
        })
    $Config['optionSets'] = @($keptOptionSets + $genOptionSets)
    $Config['options'] = @($keptOptions + $genOptions)

    # ---- optionGroups / optionGroupSets (by code or id; the whole antibiotic domain is generated) ----------------
    $genOgCodes = New-NeoIPCKeySet @($genOptionGroups | ForEach-Object { [string]$_['code'] })
    $genOgIds   = New-NeoIPCKeySet @($genOptionGroups | ForEach-Object { [string]$_['id'] })
    $keptOptionGroups = @(@($Config['optionGroups']) | Where-Object { $_ -is [System.Collections.IDictionary] -and -not ($genOgCodes.Contains([string]$_['code']) -or $genOgIds.Contains([string]$_['id'])) })
    $Config['optionGroups'] = @($keptOptionGroups + $genOptionGroups)

    $genOgsCodes = New-NeoIPCKeySet @($genOptionGroupSets | ForEach-Object { [string]$_['code'] })
    $genOgsIds   = New-NeoIPCKeySet @($genOptionGroupSets | ForEach-Object { [string]$_['id'] })
    $keptOptionGroupSets = @(@($Config['optionGroupSets']) | Where-Object { $_ -is [System.Collections.IDictionary] -and -not ($genOgsCodes.Contains([string]$_['code']) -or $genOgsIds.Contains([string]$_['id'])) })
    $Config['optionGroupSets'] = @($keptOptionGroupSets + $genOptionGroupSets)

    # ---- dataElements (by code or id) ----------------------------------------------------------------------------
    $genDeCodes = New-NeoIPCKeySet @($genDataElements | ForEach-Object { [string]$_['code'] })
    $genDeIds   = New-NeoIPCKeySet @($genDataElements | ForEach-Object { [string]$_['id'] })
    $keptDes = @(@($Config['dataElements']) | Where-Object { $_ -is [System.Collections.IDictionary] -and -not ($genDeCodes.Contains([string]$_['code']) -or $genDeIds.Contains([string]$_['id'])) })
    $Config['dataElements'] = @($keptDes + $genDataElements)

    # ---- programRuleVariables (by name or id) --------------------------------------------------------------------
    # The id check is load-bearing: the substance generators preserve UIDs by a padding-insensitive name
    # (deployed `… 1 …` -> generated `… 01 …`, same id), so exact-name matching alone would keep the deployed
    # object and duplicate its id onto the generated one.
    $genVarNames = New-NeoIPCKeySet @($genVariables | ForEach-Object { [string]$_['name'] })
    $genVarIds   = New-NeoIPCKeySet @($genVariables | ForEach-Object { [string]$_['id'] })
    $keptVars = @(@($Config['programRuleVariables']) | Where-Object { $_ -is [System.Collections.IDictionary] -and -not ($genVarNames.Contains([string]$_['name']) -or $genVarIds.Contains([string]$_['id'])) })
    $Config['programRuleVariables'] = @($keptVars + $genVariables)

    # ---- programRules + programRuleActions (by name or id; stale aggregate dropped; non-family actions salvaged) --
    $staleAggregateRuleNames = New-NeoIPCKeySet @('NeoIPC HAP - set pathogen attribute variables')
    $genRuleNames  = New-NeoIPCKeySet @($genRules | ForEach-Object { [string]$_['name'] })
    $genRuleIds    = New-NeoIPCKeySet @($genRules | ForEach-Object { [string]$_['id'] })
    $genActionIds  = New-NeoIPCKeySet @($genActions | ForEach-Object { [string]$_['id'] })
    $genRuleById = @{}
    foreach ($r in $genRules) { $genRuleById[[string]$r['id']] = $r }

    $deployedActionsByRuleId = @{}
    foreach ($a in @($Config['programRuleActions'])) {
        if ($a -isnot [System.Collections.IDictionary]) { continue }
        $pr = $a['programRule']
        $rid = if ($pr -is [System.Collections.IDictionary]) { [string]$pr['id'] } else { $null }
        if ($rid) {
            if (-not $deployedActionsByRuleId.ContainsKey($rid)) { $deployedActionsByRuleId[$rid] = [System.Collections.Generic.List[object]]::new() }
            $deployedActionsByRuleId[$rid].Add($a)
        }
    }

    $keptRules = @(@($Config['programRules']) | Where-Object {
            $_ -is [System.Collections.IDictionary] -and
            -not ($genRuleNames.Contains([string]$_['name']) -or $genRuleIds.Contains([string]$_['id'])) -and
            -not $staleAggregateRuleNames.Contains([string]$_['name'])
        })
    $keptRuleIds = New-NeoIPCKeySet @($keptRules | ForEach-Object { [string]$_['id'] })

    # Salvage hand-authored actions (target DE outside the generated families) from each replaced rule
    # onto the generated rule of the same id (which carries the deployed id where reproduced).
    $salvagedActions = [System.Collections.Generic.List[object]]::new()
    foreach ($r in @($Config['programRules'])) {
        if ($r -isnot [System.Collections.IDictionary]) { continue }
        $rid = [string]$r['id']
        if (-not ($genRuleIds.Contains($rid) -or $genRuleNames.Contains([string]$r['name']))) { continue }
        $genRule = $genRuleById[$rid]
        if (-not $genRule) { continue }   # replaced by name but its id was re-minted: no same-id gen rule to attach to
        foreach ($a in @($deployedActionsByRuleId[$rid])) {
            if ($a -isnot [System.Collections.IDictionary]) { continue }       # rule with no deployed actions: @($null) is a 1-element [$null] array (not empty) -> skip, do not index $null
            if ($genActionIds.Contains([string]$a['id'])) { continue }         # the generator already reproduced this action (same id) -> not an omitted hand-authored action
            $tgt = $a['dataElement']
            if ($tgt -isnot [System.Collections.IDictionary]) { continue }     # no DE target -> generator owns it
            if ($genDeIds.Contains([string]$tgt['id'])) { continue }           # generated-family DE -> generator owns it
            $salvaged = [ordered]@{}
            foreach ($k in $a.Keys) { $salvaged[$k] = $a[$k] }
            $salvaged['programRule'] = [ordered]@{ id = [string]$genRule['id'] }
            $salvagedActions.Add($salvaged)
            $refs = [System.Collections.Generic.List[object]]::new()
            foreach ($ref in @($genRule['programRuleActions'])) { $refs.Add($ref) }
            $refs.Add([ordered]@{ id = [string]$salvaged['id'] })
            $genRule['programRuleActions'] = $refs.ToArray()
        }
    }

    $keptActions = @(@($Config['programRuleActions']) | Where-Object {
            if ($_ -isnot [System.Collections.IDictionary]) { return $false }
            $pr = $_['programRule']
            $rid = if ($pr -is [System.Collections.IDictionary]) { [string]$pr['id'] } else { $null }
            $rid -and $keptRuleIds.Contains($rid)
        })

    $Config['programRules'] = @($keptRules + $genRules)
    $Config['programRuleActions'] = @($keptActions + $genActions + $salvagedActions.ToArray())

    # Fail loud on any duplicate id introduced by the splice (a generated mint colliding with a kept object).
    foreach ($type in 'optionSets', 'options', 'optionGroups', 'optionGroupSets', 'dataElements', 'programRuleVariables', 'programRules', 'programRuleActions') {
        $seen = [System.Collections.Generic.HashSet[string]]::new($ordinal)
        foreach ($o in @($Config[$type])) {
            if ($o -isnot [System.Collections.IDictionary]) { continue }
            $id = [string]$o['id']
            if ($id -and -not $seen.Add($id)) { throw "Generated-metadata splice produced a duplicate id '$id' in '$type'." }
        }
    }

    $Config
}
