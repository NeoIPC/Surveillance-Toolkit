# NeoIPC metadata pipeline — ontology / matrix-driven generators.
# These produce the importable DHIS2 objects that are NOT hand-authored in the per-type CSV directory but
# generated from a richer canonical source: the NEOIPC_PATHOGENS option set from the infectious-agent ontology
# (New-NeoIPCPathogenOptionSet), the per-slot pathogen data elements (New-NeoIPCPathogenDataElement), and the
# resistance-gating program-rule variables (New-NeoIPCPathogenVariable).

function New-NeoIPCPathogenOptionSet {
    <#
    .SYNOPSIS
        Generate the DHIS2 NEOIPC_PATHOGENS option set + options from the infectious-agent ontology.
    .DESCRIPTION
        Walks the canonical NeoIPC-Infectious-Agents.yaml and emits one DHIS2 option per Id-bearing node
        (concepts AND synonyms — a synonym is a selectable option keeping its original Id), plus the option-set
        object that binds them. The option CODE is the node's integer Id (the code already stored in collected
        surveillance data and compared by the resistance program rules); the option NAME is the node's Name plus a
        bracketed rank/synonym tag — "<Name> [genus]", "<Name> [species]", "<Name> [synonym]" — reproducing the
        deployed convention (a node whose rank is Unknown carries no tag), assembled by Get-NeoIPCPathogenOptionLabel.
        The name is the domain-authority name (repo CLAUDE.md); the tag is the lowercased ConceptType (the English
        label). Output order is a deterministic depth-first walk of the ontology (node, then
        Hierarchies/Synonyms/Children) with a 1-based sortOrder, so diffs are stable.

        UID policy mirrors the rest of the pipeline (preserve-if-present, else deterministic mint from the natural
        key): with -ExistingPackage, the option set's UID and each option's UID are reused from the export where
        the code matches (so binding data elements and already-imported options keep their ids and the diff stays
        minimal); otherwise the option set mints from its code and each option from "<optionSetUid>|<code>" — the
        same seed the converter uses, so a generated directory round-trips with zero id churn.

        Fail-loud guarantee (no silent drop): when -ExistingPackage is supplied, every deployed option code MUST
        resolve to an ontology node; any deployed code absent from the YAML throws (restore it to the YAML as a
        synonym keeping its original Id rather than dropping it). New ontology nodes not yet in the export are
        added (reported via -Verbose).

        Pure file/object processing — no DHIS2 API calls. Returns a package fragment { optionSets; options }
        ready to splice into an assembly (see New-NeoIPCMetadataPackage).
    .PARAMETER Path
        Path to the ontology YAML. Defaults to the canonical file in the repository.
    .PARAMETER ExistingPackage
        Optional already-parsed DHIS2 package/export (a hashtable, e.g. from ConvertFrom-NeoIPCMetadataJson's
        internal parse) whose NEOIPC_PATHOGENS option set + options supply UIDs to preserve and the deployed code
        set to validate against. Omit to mint all UIDs deterministically and skip the deployed cross-check.
    .PARAMETER OptionSetCode
        The option set's code. Default: NEOIPC_PATHOGENS.
    .PARAMETER OptionSetName
        The option set's name. Default: 'NeoIPC Pathogen options'.
    .PARAMETER ValueType
        The option set's value type. Default: INTEGER_ZERO_OR_POSITIVE (matches the deployed set; option codes
        are non-negative integers, Id 0 = "Not listed").
    .OUTPUTS
        [ordered] hashtable with keys 'optionSets' (one object) and 'options' (one per Id-bearing node).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Position = 0)]
        [string]$Path = (Join-Path $PSScriptRoot '..' '..' '..' '..' 'metadata' 'common' 'infectious-agents' 'NeoIPC-Infectious-Agents.yaml'),
        [System.Collections.IDictionary]$ExistingPackage,
        [string]$OptionSetCode = 'NEOIPC_PATHOGENS',
        [string]$OptionSetName = 'NeoIPC Pathogen options',
        [string]$ValueType = 'INTEGER_ZERO_OR_POSITIVE'
    )

    Import-Module powershell-yaml -ErrorAction Stop
    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    $tree = Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Yaml
    $concepts = @(Get-NeoIPCInfectiousAgentConcept -Node $tree)
    if ($concepts.Count -eq 0) { throw "No Id-bearing concepts found in '$resolved'." }

    # Index by code (= Id, as a string) and fail loud on a duplicate Id — option codes must be unique.
    $byCode = [ordered]@{}
    foreach ($c in $concepts) {
        $code = [string]$c['Id']
        if ($byCode.Contains($code)) {
            throw "Duplicate option code $code in the ontology ('$($c['Name'])' vs '$($byCode[$code]['Name'])') — Ids must be unique."
        }
        $byCode[$code] = $c
    }

    # Preserve UIDs from the export where the option set already exists, and collect the deployed code set.
    $existingOsUid = $null
    $existingOptUid = @{}
    $existingCodes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $existingSharing = $null
    if ($ExistingPackage) {
        foreach ($os in @($ExistingPackage['optionSets'])) {
            if ($os -is [System.Collections.IDictionary] -and [string]$os['code'] -eq $OptionSetCode) {
                $existingOsUid = [string]$os['id']
                # Normalize on capture (strip owner/external/displayName/empty-grant noise) and detach from the
                # input package — mirrors ConvertTo-NeoIPCMetadataRow / Initialize-NeoIPCSharingProfileFromPackage.
                if ($os.Contains('sharing')) { $existingSharing = Convert-NeoIPCSharing $os['sharing'] }
                break
            }
        }
        # A package was supplied but does not carry the target set: this is a malformed/partial/wrong-code export,
        # not the "omit to mint fresh" mode. Fail loud rather than silently re-minting every UID (which would
        # orphan the data-element bindings on import) — mirrors the strict anchor checks in the sibling generators.
        if (-not $existingOsUid) {
            throw "Option set '$OptionSetCode' was not found in the supplied -ExistingPackage. Pass an export that contains the deployed option set to reconcile against, or omit -ExistingPackage to mint all UIDs fresh."
        }
        foreach ($opt in @($ExistingPackage['options'])) {
            if ($opt -isnot [System.Collections.IDictionary]) { continue }
            $osRef = $opt['optionSet']
            if ($osRef -is [System.Collections.IDictionary] -and [string]$osRef['id'] -eq $existingOsUid) {
                $oc = [string]$opt['code']
                $existingOptUid[$oc] = [string]$opt['id']
                [void]$existingCodes.Add($oc)
            }
        }
    }

    # No silent drop: every deployed code must resolve to an ontology node.
    if ($existingCodes.Count -gt 0) {
        $missing = @($existingCodes | Where-Object { -not $byCode.Contains($_) } | Sort-Object { [int]$_ })
        if ($missing.Count -gt 0) {
            throw ("Regeneration would drop {0} deployed option code(s) absent from the ontology: {1}. Restore each to NeoIPC-Infectious-Agents.yaml (as a synonym keeping its original Id) before regenerating." -f `
                    $missing.Count, ($missing -join ', '))
        }
        $added = @($byCode.Keys | Where-Object { -not $existingCodes.Contains($_) })
        Write-Verbose ("Option set '{0}': {1} concepts ({2} preserved from export, {3} new)." -f `
                $OptionSetCode, $concepts.Count, $existingCodes.Count, $added.Count)
    }

    $osUid = if ($existingOsUid -and (Test-NeoIPCMetadataUid -Id $existingOsUid)) { $existingOsUid }
    else { New-NeoIPCMetadataUid -Type 'optionSets' -NaturalKey $OptionSetCode }

    # Build the options + the option-set's ordered option-ref list. Deterministic 1-based sortOrder in doc order.
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    [void]$seen.Add($osUid)
    $options = [System.Collections.Generic.List[object]]::new()
    $optionRefs = [System.Collections.Generic.List[object]]::new()
    $sortOrder = 1
    foreach ($c in $concepts) {
        $code = [string]$c['Id']
        $uid = if ($existingOptUid.ContainsKey($code) -and (Test-NeoIPCMetadataUid -Id $existingOptUid[$code])) {
            $existingOptUid[$code]
        }
        else {
            New-NeoIPCMetadataUid -Type 'options' -NaturalKey ('{0}|{1}' -f $osUid, $code)
        }
        if (-not $seen.Add($uid)) { throw "UID collision minting option code '$code' (uid '$uid')." }
        $options.Add([ordered]@{
                id        = $uid
                code      = $code
                name      = Get-NeoIPCPathogenOptionLabel -Name ([string]$c['Name']) -ConceptType ([string]$c['ConceptType']) -IsSynonym ([bool]$c['IsSynonym'])
                sortOrder = $sortOrder
                optionSet = [ordered]@{ id = $osUid }
            })
        $optionRefs.Add([ordered]@{ id = $uid })
        $sortOrder++
    }

    $optionSet = [ordered]@{
        id        = $osUid
        code      = $OptionSetCode
        name      = $OptionSetName
        valueType = $ValueType
        options   = $optionRefs.ToArray()
    }
    if ($existingSharing -and $existingSharing.Count -gt 0) { $optionSet['sharing'] = $existingSharing }

    [ordered]@{ optionSets = @($optionSet); options = $options.ToArray() }
}

function New-NeoIPCPathogenDataElement {
    <#
    .SYNOPSIS
        Generate the per-slot pathogen DATA ELEMENTS of NEOIPC_CORE from the capability matrix.
    .DESCRIPTION
        Expands the pathogen-slot capability matrix (Get-NeoIPCPathogenDataElementPlan) — 18 slots (9 primary
        BSI/HAP/SSI + 9 secondary-BSI HAP/NEC/SSI), each with a base organism-selector DE (binds NEOIPC_PATHOGENS),
        a _NAME free-text DE, and the five resistance DEs (bind NEOIPC_YES_NO_NOT_TESTED); primary BSI/HAP also
        carry a stage-specific _SOURCE, and primary BSI alone a _MULTIPLE (TRUE_ONLY) — 135 DEs total.

        The matrix is the source of each DE's STRUCTURE (code, valueType, option-set binding, zeroIsSignificant)
        and NAMING (name / shortName / formName, regenerated to the consistent template — normalising any deployed
        drift). The rich clinical DESCRIPTION, the UID, and the categoryCombo are REUSED from the existing package
        by code (the export is the source of that content), mirroring the option-set generator. Option-set
        references are resolved by code against the package's optionSets.

        Fail-loud (no silent divergence): every matrix DE must exist in the package (a missing one means the matrix
        and the deployed program have drifted — reconcile first), and every referenced option set must be present.
        Pure object processing — no DHIS2 API calls. Returns a package fragment { dataElements }.
    .PARAMETER ExistingPackage
        An already-parsed DHIS2 package/export (hashtable) supplying the per-slot DEs' descriptions, UIDs and
        categoryCombo, and the option sets the DEs bind.
    .PARAMETER PathogenCount
        Number of organism slots per applicable program stage (1-9, single digit). Defaults to the module-wide count (3). Pass the same
        value to New-NeoIPCPathogenVariable and New-NeoIPCPathogenRule so the data elements, variables and rules stay
        aligned.
    .OUTPUTS
        [ordered] hashtable with key 'dataElements' (the per-slot pathogen data elements; 135 at the default count of 3).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$ExistingPackage,
        [ValidateRange(1, 9)][int]$PathogenCount = $script:NeoIPCPathogenSlotCount
    )

    # Ordinal-comparer indexes (DHIS2 codes are case-sensitive), failing loud on a case-only duplicate rather than
    # silently last-wins — consistent with the module's no-silent-divergence convention.
    $deByCode = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    foreach ($de in @($ExistingPackage['dataElements'])) {
        if ($de -is [System.Collections.IDictionary] -and $de['code']) {
            $c = [string]$de['code']
            if ($deByCode.ContainsKey($c)) { throw "Duplicate data-element code '$c' in the package." }
            $deByCode[$c] = $de
        }
    }
    $osByCode = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    foreach ($os in @($ExistingPackage['optionSets'])) {
        if ($os -is [System.Collections.IDictionary] -and $os['code']) {
            $c = [string]$os['code']
            if ($osByCode.ContainsKey($c)) { throw "Duplicate option-set code '$c' in the package." }
            $osByCode[$c] = [string]$os['id']
        }
    }

    $plan = @(Get-NeoIPCPathogenDataElementPlan -PathogenCount $PathogenCount)
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $missing = [System.Collections.Generic.List[string]]::new()
    $out = [System.Collections.Generic.List[object]]::new()

    foreach ($d in $plan) {
        $code = [string]$d['Code']
        if (-not $deByCode.ContainsKey($code)) { $missing.Add($code); continue }
        $existing = $deByCode[$code]

        $id = [string]$existing['id']
        if (-not (Test-NeoIPCMetadataUid -Id $id)) { $id = New-NeoIPCMetadataUid -Type 'dataElements' -NaturalKey $code }
        if (-not $seen.Add($id)) { throw "Duplicate data-element id '$id' for code '$code'." }

        $de = [ordered]@{
            id        = $id
            code      = $code
            name      = [string]$d['Name']
            shortName = [string]$d['ShortName']
            formName  = [string]$d['FormName']
        }
        if ($existing.Contains('description') -and "$($existing['description'])") { $de['description'] = [string]$existing['description'] }
        $de['valueType'] = [string]$d['ValueType']
        $de['domainType'] = 'TRACKER'
        $de['aggregationType'] = 'DEFAULT'
        $de['zeroIsSignificant'] = [bool]$d['ZeroIsSignificant']
        if ($existing['categoryCombo'] -is [System.Collections.IDictionary]) {
            $de['categoryCombo'] = [ordered]@{ id = [string]$existing['categoryCombo']['id'] }
        }
        if ($d['OptionSetCode']) {
            $osc = [string]$d['OptionSetCode']
            if (-not $osByCode.ContainsKey($osc)) { throw "Option set '$osc' (bound by data element '$code') is not present in the package." }
            $de['optionSet'] = [ordered]@{ id = $osByCode[$osc] }
        }
        # Reuse the deployed DE's sharing (normalised), like the option-set generator — without it the regenerated
        # DEs would import with null sharing instead of the deployed public access.
        if ($existing.Contains('sharing')) {
            $sh = Convert-NeoIPCSharing $existing['sharing']
            if ($sh -and $sh.Count -gt 0) { $de['sharing'] = $sh }
        }
        $out.Add($de)
    }

    if ($missing.Count -gt 0) {
        throw ("{0} matrix-expected pathogen data element(s) are missing from the package: {1}. The capability matrix and the deployed program have diverged — reconcile before generating." -f `
                $missing.Count, (($missing | Sort-Object) -join ', '))
    }

    [ordered]@{ dataElements = $out.ToArray() }
}

function New-NeoIPCPathogenVariable {
    <#
    .SYNOPSIS
        Generate the resistance-gating program-rule VARIABLES of NEOIPC_CORE from the capability matrix.
    .DESCRIPTION
        Expands the resistance-PRV plan (Get-NeoIPCPathogenVariablePlan) — for each of the 18 pathogen slots, a
        `value` variable (DATAELEMENT_CURRENT_EVENT over the base organism DE, useCodeForOptionSet=true, so it reads
        the option CODE the resistance rules compare) plus five `may be <CAT>` CALCULATED_VALUE booleans — 108 PRVs.

        The variables are generated fresh from the matrix (their fields are all structural); the UID is preserved
        from the package by name where present, else minted deterministically (programRuleVariables natural key =
        name), mirroring the option-set generator. The `value` variable's dataElement reference and the program
        reference are resolved by code against the package (fail-loud if the base DE or the NEOIPC_CORE program is
        absent). The slot-specific field-gating variables (name value, source value, is recognized pathogen,
        recovered multiple times) are generated with their rules, not here.

        Pure object processing — no DHIS2 API calls. Returns a package fragment { programRuleVariables }.
    .PARAMETER ExistingPackage
        An already-parsed DHIS2 package/export (hashtable) supplying UIDs to preserve, the base organism DEs the
        `value` variables read (by code), and the NEOIPC_CORE program reference.
    .PARAMETER ProgramCode
        Code of the program the variables belong to. Default: NEOIPC_CORE.
    .PARAMETER PathogenCount
        Number of organism slots per applicable program stage (1-9, single digit). Defaults to the module-wide count (3). Pass the same
        value to New-NeoIPCPathogenDataElement and New-NeoIPCPathogenRule so the data elements, variables and rules
        stay aligned.
    .OUTPUTS
        [ordered] hashtable with key 'programRuleVariables' (the resistance-gating variables; 108 at the default count of 3).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$ExistingPackage,
        [string]$ProgramCode = 'NEOIPC_CORE',
        [ValidateRange(1, 9)][int]$PathogenCount = $script:NeoIPCPathogenSlotCount
    )

    $programId = $null
    foreach ($p in @($ExistingPackage['programs'])) {
        if ($p -is [System.Collections.IDictionary] -and [string]$p['code'] -eq $ProgramCode) { $programId = [string]$p['id']; break }
    }
    if (-not $programId) { throw "Program '$ProgramCode' not found in the package." }

    # Ordinal-comparer indexes (case-sensitive), failing loud on a case-only duplicate rather than silently
    # last-wins — consistent with the module's no-silent-divergence convention.
    $deByCode = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    foreach ($de in @($ExistingPackage['dataElements'])) {
        if ($de -is [System.Collections.IDictionary] -and $de['code']) {
            $c = [string]$de['code']
            if ($deByCode.ContainsKey($c)) { throw "Duplicate data-element code '$c' in the package." }
            $deByCode[$c] = [string]$de['id']
        }
    }
    $prvByName = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    foreach ($v in @($ExistingPackage['programRuleVariables'])) {
        if ($v -is [System.Collections.IDictionary] -and $v['name']) {
            $nm = [string]$v['name']
            if ($prvByName.ContainsKey($nm)) { throw "Duplicate program-rule-variable name '$nm' in the package." }
            $prvByName[$nm] = [string]$v['id']
        }
    }

    $plan = @(Get-NeoIPCPathogenVariablePlan -PathogenCount $PathogenCount)
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $out = [System.Collections.Generic.List[object]]::new()

    foreach ($d in $plan) {
        $name = [string]$d['Name']
        $existingId = if ($prvByName.ContainsKey($name)) { $prvByName[$name] } else { $null }
        $id = if ($existingId -and (Test-NeoIPCMetadataUid -Id $existingId)) { $existingId }
        else { New-NeoIPCMetadataUid -Type 'programRuleVariables' -NaturalKey $name }
        if (-not $seen.Add($id)) { throw "UID collision for program-rule variable '$name' (uid '$id')." }

        $prv = [ordered]@{
            id                            = $id
            name                          = $name
            programRuleVariableSourceType = [string]$d['SourceType']
            valueType                     = [string]$d['ValueType']
            useCodeForOptionSet           = [bool]$d['UseCodeForOptionSet']
            program                       = [ordered]@{ id = $programId }
        }
        if ($d['DataElementCode']) {
            $dec = [string]$d['DataElementCode']
            if (-not $deByCode.ContainsKey($dec)) { throw "Base data element '$dec' (read by variable '$name') is not present in the package." }
            $prv['dataElement'] = [ordered]@{ id = $deByCode[$dec] }
        }
        $out.Add($prv)
    }

    [ordered]@{ programRuleVariables = $out.ToArray() }
}

function New-NeoIPCPathogenRule {
    <#
    .SYNOPSIS
        Generate the resistance-gating PROGRAM RULES + ACTIONS of NEOIPC_CORE from the ontology + capability matrix.
    .DESCRIPTION
        Expands the resistance-rule plan (Get-NeoIPCPathogenRulePlan) — for each of the 18 pathogen slots and each of
        the 5 resistance categories, the three-rule producer/consumer triple and its single action:
          - `<slot> - set <CAT>`   : condition `true`, priority 0, an ASSIGN action that sets the `may be <CAT>`
            variable (`content`) to `d2:hasValue(#{<slot> value})&&(#{<slot> value}==c1||...)` (`data`), enumerating
            the category's effective organism code set in ascending order;
          - `<slot> - may be <CAT>`: condition `#{<slot> may be <CAT>}`, priority 1, a SETMANDATORYFIELD action on the
            `_<CAT>` resistance data element;
          - `<slot> - not <CAT>`   : condition `!#{<slot> may be <CAT>}` (the exact complement, so a field is never
            hidden-and-mandatory), priority 1, a HIDEFIELD action on the same `_<CAT>` data element.
        270 rules / 270 actions. The category code sets come from Get-NeoIPCResistanceCodeSet over the canonical
        ontology — the nearest-explicit (own-or-inherited, false-overriding) effective flag per node — so the
        generated rules carry the corrected taxonomy, not the deployed snapshot. The stale aggregate
        `NeoIPC HAP - set pathogen attribute variables` is never emitted.

        Each rule's `programStage` is resolved via a slot-1 `_3GCR` resistance data element on that stage (the deployed
        program stages carry no `code`), through programStageDataElements; the `may be`/`not` actions' target `_<CAT>`
        data element is resolved by code; the `set` action's variables are referenced by name. UID policy mirrors the
        rest of the pipeline: a rule preserves its UID + description from the export by
        name where present, else mints deterministically (programRules natural key = name); an action (which has no
        name of its own) preserves the UID of its owning deployed rule's same-type action, else mints from
        `<rule name>|<actionType>`. Fail-loud (no silent divergence): a missing program / program stage / resistance
        data element, an empty category code set, or a duplicate minted UID throws.

        Pure file/object processing — no DHIS2 API calls. Returns a package fragment { programRules; programRuleActions }.
    .PARAMETER ExistingPackage
        An already-parsed DHIS2 package/export (hashtable) supplying the NEOIPC_CORE program, the four program stages
        (with their programStageDataElements, used to resolve each rule's stage), the `_<CAT>` resistance data elements
        (by code), and the deployed rules/actions whose UIDs + descriptions are preserved.
    .PARAMETER Path
        Path to the ontology YAML (drives the per-category code sets). Defaults to the canonical file in the repository.
    .PARAMETER ProgramCode
        Code of the program the rules belong to. Default: NEOIPC_CORE.
    .PARAMETER PathogenCount
        Number of organism slots per applicable program stage (1-9, single digit). Defaults to the module-wide count (3). Pass the same
        value to New-NeoIPCPathogenDataElement and New-NeoIPCPathogenVariable so the data elements, variables and
        rules stay aligned.
    .OUTPUTS
        [ordered] hashtable with keys 'programRules' and 'programRuleActions' (270 each at the default count of 3).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$ExistingPackage,
        [Parameter(Position = 0)]
        [string]$Path = (Join-Path $PSScriptRoot '..' '..' '..' '..' 'metadata' 'common' 'infectious-agents' 'NeoIPC-Infectious-Agents.yaml'),
        [string]$ProgramCode = 'NEOIPC_CORE',
        [ValidateRange(1, 9)][int]$PathogenCount = $script:NeoIPCPathogenSlotCount
    )

    Import-Module powershell-yaml -ErrorAction Stop

    $programId = $null
    foreach ($p in @($ExistingPackage['programs'])) {
        if ($p -is [System.Collections.IDictionary] -and [string]$p['code'] -eq $ProgramCode) { $programId = [string]$p['id']; break }
    }
    if (-not $programId) { throw "Program '$ProgramCode' not found in the package." }

    # Ordinal-comparer indexes (DHIS2 codes/names are case-sensitive), failing loud on a duplicate rather than
    # silently last-wins — consistent with the module's no-silent-divergence convention.
    $deByCode = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    foreach ($de in @($ExistingPackage['dataElements'])) {
        if ($de -is [System.Collections.IDictionary] -and $de['code']) {
            $c = [string]$de['code']
            if ($deByCode.ContainsKey($c)) { throw "Duplicate data-element code '$c' in the package." }
            $deByCode[$c] = [string]$de['id']
        }
    }
    $ruleByName = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    foreach ($r in @($ExistingPackage['programRules'])) {
        if ($r -is [System.Collections.IDictionary] -and $r['name']) {
            $nm = [string]$r['name']
            if ($ruleByName.ContainsKey($nm)) { throw "Duplicate program-rule name '$nm' in the package." }
            $ruleByName[$nm] = $r
        }
    }
    # Group deployed actions by owning rule id so a generated rule can preserve its same-type action's UID.
    $actionsByRuleId = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[object]]]::new([System.StringComparer]::Ordinal)
    foreach ($a in @($ExistingPackage['programRuleActions'])) {
        if ($a -isnot [System.Collections.IDictionary]) { continue }
        $pr = $a['programRule']
        if ($pr -is [System.Collections.IDictionary] -and $pr['id']) {
            $rid = [string]$pr['id']
            if (-not $actionsByRuleId.ContainsKey($rid)) { $actionsByRuleId[$rid] = [System.Collections.Generic.List[object]]::new() }
            $actionsByRuleId[$rid].Add($a)
        }
    }

    $resolvedYaml = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    $tree = Get-Content -LiteralPath $resolvedYaml -Raw | ConvertFrom-Yaml
    $codeSets = Get-NeoIPCResistanceCodeSet -Node $tree

    # The deployed program stages carry no code, so resolve each pathogen stage by a slot-1 resistance DE that always
    # exists on it (so rules for grown slots resolve too); map the stage token -> stage id once.
    $stageByDeId = Get-NeoIPCStageByDataElementId -Package $ExistingPackage
    $stageAnchorByToken = @{
        BSI = 'NEOIPC_BSI_PATHOGEN_1_3GCR'
        HAP = 'NEOIPC_HAP_PATHOGEN_1_3GCR'
        SSI = 'NEOIPC_SSI_PATHOGEN_1_3GCR'
        NEC = 'NEOIPC_NEC_SEC_BSI_PATHOGEN_1_3GCR'
    }
    $stageIdByToken = @{}
    foreach ($tok in $stageAnchorByToken.Keys) {
        $anchor = $stageAnchorByToken[$tok]
        if ($deByCode.ContainsKey($anchor) -and $stageByDeId.ContainsKey($deByCode[$anchor])) {
            $stageIdByToken[$tok] = $stageByDeId[$deByCode[$anchor]]
        }
    }

    $plan = @(Get-NeoIPCPathogenRulePlan -PathogenCount $PathogenCount)
    $rulesSeen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $actionsSeen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $rules = [System.Collections.Generic.List[object]]::new()
    $actions = [System.Collections.Generic.List[object]]::new()

    foreach ($d in $plan) {
        $name = [string]$d['Name']
        $stage = [string]$d['Stage']
        if (-not $stageIdByToken.ContainsKey($stage)) { throw "Cannot resolve the program stage for rule '$name' — the anchor data element '$($stageAnchorByToken[$stage])' is absent from the package or not assigned to a stage." }
        $psId = $stageIdByToken[$stage]

        $deployedRule = if ($ruleByName.ContainsKey($name)) { $ruleByName[$name] } else { $null }
        $deployedRuleId = if ($deployedRule) { [string]$deployedRule['id'] } else { $null }

        $ruleId = if ($deployedRuleId -and (Test-NeoIPCMetadataUid -Id $deployedRuleId)) { $deployedRuleId }
        else { New-NeoIPCMetadataUid -Type 'programRules' -NaturalKey $name }
        if (-not $rulesSeen.Add($ruleId)) { throw "UID collision for program rule '$name' (uid '$ruleId')." }

        $actionType = [string]$d['ActionType']
        $actionId = $null
        if ($deployedRuleId -and $actionsByRuleId.ContainsKey($deployedRuleId)) {
            foreach ($a in $actionsByRuleId[$deployedRuleId]) {
                if ([string]$a['programRuleActionType'] -eq $actionType -and (Test-NeoIPCMetadataUid -Id ([string]$a['id']))) {
                    $actionId = [string]$a['id']; break
                }
            }
        }
        if (-not $actionId) { $actionId = New-NeoIPCMetadataUid -Type 'programRuleActions' -NaturalKey ('{0}|{1}' -f $name, $actionType) }
        if (-not $actionsSeen.Add($actionId)) { throw "UID collision for the action of program rule '$name' (uid '$actionId')." }

        $rule = [ordered]@{ id = $ruleId; name = $name }
        $desc = if ($deployedRule -and $deployedRule.Contains('description') -and "$($deployedRule['description'])") { [string]$deployedRule['description'] } else { [string]$d['Description'] }
        if ($desc) { $rule['description'] = $desc }
        $rule['program'] = [ordered]@{ id = $programId }
        $rule['programStage'] = [ordered]@{ id = $psId }
        $rule['condition'] = [string]$d['Condition']
        $rule['priority'] = [int]$d['Priority']
        $rule['programRuleActions'] = @([ordered]@{ id = $actionId })
        $rules.Add($rule)

        $action = [ordered]@{
            id                    = $actionId
            programRule           = [ordered]@{ id = $ruleId }
            programRuleActionType = $actionType
        }
        if ([string]$d['Kind'] -eq 'set') {
            $cat = [string]$d['Category']
            $codes = @($codeSets[$cat])
            if ($codes.Count -eq 0) { throw "Resistance category '$cat' has an empty code set — cannot build the ASSIGN expression for '$name'." }
            $valueVar = [string]$d['ValueVariable']
            $terms = ($codes | ForEach-Object { "#{$valueVar}==$_" }) -join '||'
            $action['content'] = "#{$([string]$d['MayBeVariable'])}"
            $action['data'] = "d2:hasValue(#{$valueVar})&&($terms)"
        }
        else {
            $catDeCode = [string]$d['CategoryDeCode']
            if (-not $deByCode.ContainsKey($catDeCode)) { throw "Resistance data element '$catDeCode' (targeted by rule '$name') is not present in the package." }
            $action['dataElement'] = [ordered]@{ id = $deByCode[$catDeCode] }
        }
        $actions.Add($action)
    }

    [ordered]@{ programRules = $rules.ToArray(); programRuleActions = $actions.ToArray() }
}

function New-NeoIPCPathogenFieldGatingVariable {
    <#
    .SYNOPSIS
        Generate the slot-specific field-gating PROGRAM-RULE VARIABLES of NEOIPC_CORE (the recognized-pathogen boolean).
    .DESCRIPTION
        Expands the field-gating-variable plan (Get-NeoIPCPathogenFieldGatingVariablePlan) — for each BSI primary slot
        an `is recognized pathogen` CALCULATED_VALUE boolean. This is the variable the BSI `set recognized pathogen`
        ASSIGN writes (and downstream BSI-definition rules read), so it must be generated alongside those rules — it is
        deliberately NOT in New-NeoIPCPathogenVariable (the resistance PRVs). The UID is preserved from the export by
        name where present, else minted deterministically (programRuleVariables natural key = name); the program is
        resolved by code. Fail-loud if the program is absent. Pure object processing — no DHIS2 API calls.
        Returns a package fragment { programRuleVariables }.
    .PARAMETER ExistingPackage
        An already-parsed DHIS2 package/export (hashtable) supplying UIDs to preserve and the NEOIPC_CORE program.
    .PARAMETER ProgramCode
        Code of the program the variables belong to. Default: NEOIPC_CORE.
    .PARAMETER PathogenCount
        Number of organism slots per applicable program stage (1-9, single digit). Defaults to the module-wide count (3).
        Pass the same value to New-NeoIPCPathogenFieldGatingRule so the variables and rules stay aligned.
    .OUTPUTS
        [ordered] hashtable with key 'programRuleVariables' (PathogenCount at the default count of 3).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$ExistingPackage,
        [string]$ProgramCode = 'NEOIPC_CORE',
        [ValidateRange(1, 9)][int]$PathogenCount = $script:NeoIPCPathogenSlotCount
    )

    $programId = $null
    foreach ($p in @($ExistingPackage['programs'])) {
        if ($p -is [System.Collections.IDictionary] -and [string]$p['code'] -eq $ProgramCode) { $programId = [string]$p['id']; break }
    }
    if (-not $programId) { throw "Program '$ProgramCode' not found in the package." }

    $prvByName = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    foreach ($v in @($ExistingPackage['programRuleVariables'])) {
        if ($v -is [System.Collections.IDictionary] -and $v['name']) {
            $nm = [string]$v['name']
            if ($prvByName.ContainsKey($nm)) { throw "Duplicate program-rule-variable name '$nm' in the package." }
            $prvByName[$nm] = [string]$v['id']
        }
    }

    $plan = @(Get-NeoIPCPathogenFieldGatingVariablePlan -PathogenCount $PathogenCount)
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($d in $plan) {
        $name = [string]$d['Name']
        $existingId = if ($prvByName.ContainsKey($name)) { $prvByName[$name] } else { $null }
        $id = if ($existingId -and (Test-NeoIPCMetadataUid -Id $existingId)) { $existingId }
        else { New-NeoIPCMetadataUid -Type 'programRuleVariables' -NaturalKey $name }
        if (-not $seen.Add($id)) { throw "UID collision for program-rule variable '$name' (uid '$id')." }

        $out.Add([ordered]@{
                id                            = $id
                name                          = $name
                programRuleVariableSourceType = [string]$d['SourceType']
                valueType                     = [string]$d['ValueType']
                useCodeForOptionSet           = [bool]$d['UseCodeForOptionSet']
                program                       = [ordered]@{ id = $programId }
            })
    }
    [ordered]@{ programRuleVariables = $out.ToArray() }
}

function New-NeoIPCPathogenFieldGatingRule {
    <#
    .SYNOPSIS
        Generate the per-slot field-gating PROGRAM RULES + ACTIONS of NEOIPC_CORE from the ontology + capability matrix.
    .DESCRIPTION
        Expands the field-gating-rule plan (Get-NeoIPCPathogenFieldGatingRulePlan) — the non-resistance gating on each
        pathogen slot — into rules and actions. Five kinds:
          - `<slot> - set recognized pathogen` (BSI primary): condition `true`, priority 0, an ASSIGN that sets the
            slot's `is recognized pathogen` boolean to `d2:hasValue(#{<slot> value}) && !(#{<slot> value}==c1||...)` —
            the common-commensal code set (from Get-NeoIPCCommonCommensalCodeSet over the canonical ontology) NEGATED;
          - `<slot> - when set` (BSI primary): condition `d2:hasValue(#{<slot> value})`, a SETMANDATORYFIELD on `_SOURCE`;
          - `<slot> - when empty`: condition `!d2:hasValue(#{<slot> value})`, HIDEFIELD actions over the slot's own
            SOURCE/MULTIPLE extras and every field of the downstream slots (progressive reveal);
          - `<slot> - when empty or listed`: condition `!... || != 0`, a HIDEFIELD on `_NAME`;
          - `<slot> - when not listed`: condition `d2:hasValue && == 0`, a SETMANDATORYFIELD on `_NAME`.
        The recognized-pathogen code set carries the corrected taxonomy (the nearest-explicit effective CommonCommensal
        flag), not the deployed snapshot. The deployed slot-1 NEOIPC_BSI_NO_POS_CULTURE interlock is a BSI-definition
        business rule and is not emitted here.

        Each rule's `programStage` is resolved via a slot-1 `_3GCR` resistance data element on that stage (the deployed
        stages carry no `code`), through programStageDataElements. UID policy mirrors the rest of the pipeline: a rule
        preserves its UID + description from the export by name where present, else mints deterministically; an action
        preserves the UID of its owning deployed rule's action matching (action type + target data element, or just
        type for the target-less ASSIGN), else mints from `<rule name>|<type>[|<target code>]`. Fail-loud (no silent
        divergence): a missing program / program stage / target data element, an empty common-commensal code set, or a
        duplicate minted UID throws.

        Pure file/object processing — no DHIS2 API calls. Returns a package fragment { programRules; programRuleActions }.
    .PARAMETER ExistingPackage
        An already-parsed DHIS2 package/export (hashtable) supplying the NEOIPC_CORE program, the program stages (with
        their programStageDataElements, used to resolve each rule's stage), the target data elements (by code), and the
        deployed rules/actions whose UIDs + descriptions are preserved.
    .PARAMETER Path
        Path to the ontology YAML (drives the common-commensal code set). Defaults to the canonical file in the repository.
    .PARAMETER ProgramCode
        Code of the program the rules belong to. Default: NEOIPC_CORE.
    .PARAMETER PathogenCount
        Number of organism slots per applicable program stage (1-9, single digit). Defaults to the module-wide count (3).
        Pass the same value to New-NeoIPCPathogenFieldGatingVariable so the variables and rules stay aligned.
    .OUTPUTS
        [ordered] hashtable with keys 'programRules' and 'programRuleActions'.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$ExistingPackage,
        [Parameter(Position = 0)]
        [string]$Path = (Join-Path $PSScriptRoot '..' '..' '..' '..' 'metadata' 'common' 'infectious-agents' 'NeoIPC-Infectious-Agents.yaml'),
        [string]$ProgramCode = 'NEOIPC_CORE',
        [ValidateRange(1, 9)][int]$PathogenCount = $script:NeoIPCPathogenSlotCount
    )

    Import-Module powershell-yaml -ErrorAction Stop

    $programId = $null
    foreach ($p in @($ExistingPackage['programs'])) {
        if ($p -is [System.Collections.IDictionary] -and [string]$p['code'] -eq $ProgramCode) { $programId = [string]$p['id']; break }
    }
    if (-not $programId) { throw "Program '$ProgramCode' not found in the package." }

    $deByCode = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    foreach ($de in @($ExistingPackage['dataElements'])) {
        if ($de -is [System.Collections.IDictionary] -and $de['code']) {
            $c = [string]$de['code']
            if ($deByCode.ContainsKey($c)) { throw "Duplicate data-element code '$c' in the package." }
            $deByCode[$c] = [string]$de['id']
        }
    }
    $ruleByName = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    foreach ($r in @($ExistingPackage['programRules'])) {
        if ($r -is [System.Collections.IDictionary] -and $r['name']) {
            $nm = [string]$r['name']
            if ($ruleByName.ContainsKey($nm)) { throw "Duplicate program-rule name '$nm' in the package." }
            $ruleByName[$nm] = $r
        }
    }
    $actionsByRuleId = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[object]]]::new([System.StringComparer]::Ordinal)
    foreach ($a in @($ExistingPackage['programRuleActions'])) {
        if ($a -isnot [System.Collections.IDictionary]) { continue }
        $pr = $a['programRule']
        if ($pr -is [System.Collections.IDictionary] -and $pr['id']) {
            $rid = [string]$pr['id']
            if (-not $actionsByRuleId.ContainsKey($rid)) { $actionsByRuleId[$rid] = [System.Collections.Generic.List[object]]::new() }
            $actionsByRuleId[$rid].Add($a)
        }
    }

    $resolvedYaml = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    $tree = Get-Content -LiteralPath $resolvedYaml -Raw | ConvertFrom-Yaml
    $commonCommensal = @(Get-NeoIPCCommonCommensalCodeSet -Node $tree)

    # The deployed program stages carry no code, so resolve each pathogen stage by a slot-1 resistance DE that always
    # exists on it (so rules for grown slots resolve too); map the stage token -> stage id once.
    $stageByDeId = Get-NeoIPCStageByDataElementId -Package $ExistingPackage
    $stageAnchorByToken = @{
        BSI = 'NEOIPC_BSI_PATHOGEN_1_3GCR'
        HAP = 'NEOIPC_HAP_PATHOGEN_1_3GCR'
        SSI = 'NEOIPC_SSI_PATHOGEN_1_3GCR'
        NEC = 'NEOIPC_NEC_SEC_BSI_PATHOGEN_1_3GCR'
    }
    $stageIdByToken = @{}
    foreach ($tok in $stageAnchorByToken.Keys) {
        $anchor = $stageAnchorByToken[$tok]
        if ($deByCode.ContainsKey($anchor) -and $stageByDeId.ContainsKey($deByCode[$anchor])) {
            $stageIdByToken[$tok] = $stageByDeId[$deByCode[$anchor]]
        }
    }

    $plan = @(Get-NeoIPCPathogenFieldGatingRulePlan -PathogenCount $PathogenCount)
    $rulesSeen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $actionsSeen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $rules = [System.Collections.Generic.List[object]]::new()
    $actions = [System.Collections.Generic.List[object]]::new()

    foreach ($d in $plan) {
        $name = [string]$d['Name']
        $stage = [string]$d['Stage']
        if (-not $stageIdByToken.ContainsKey($stage)) { throw "Cannot resolve the program stage for rule '$name' — the anchor data element '$($stageAnchorByToken[$stage])' is absent from the package or not assigned to a stage." }
        $psId = $stageIdByToken[$stage]

        $deployedRule = if ($ruleByName.ContainsKey($name)) { $ruleByName[$name] } else { $null }
        $deployedRuleId = if ($deployedRule) { [string]$deployedRule['id'] } else { $null }

        $ruleId = if ($deployedRuleId -and (Test-NeoIPCMetadataUid -Id $deployedRuleId)) { $deployedRuleId }
        else { New-NeoIPCMetadataUid -Type 'programRules' -NaturalKey $name }
        if (-not $rulesSeen.Add($ruleId)) { throw "UID collision for program rule '$name' (uid '$ruleId')." }

        $rule = [ordered]@{ id = $ruleId; name = $name }
        $desc = if ($deployedRule -and $deployedRule.Contains('description') -and "$($deployedRule['description'])") { [string]$deployedRule['description'] } else { [string]$d['Description'] }
        if ($desc) { $rule['description'] = $desc }
        $rule['program'] = [ordered]@{ id = $programId }
        $rule['programStage'] = [ordered]@{ id = $psId }
        $rule['condition'] = [string]$d['Condition']
        $rule['priority'] = [int]$d['Priority']

        $deployedActions = if ($deployedRuleId -and $actionsByRuleId.ContainsKey($deployedRuleId)) { $actionsByRuleId[$deployedRuleId] } else { @() }
        $actionRefs = [System.Collections.Generic.List[object]]::new()
        foreach ($a in @($d['Actions'])) {
            $type = [string]$a['Type']
            $targetId = $null
            $targetCode = $null
            if ($a['DataElementCode']) {
                $targetCode = [string]$a['DataElementCode']
                if (-not $deByCode.ContainsKey($targetCode)) { throw "Data element '$targetCode' (targeted by rule '$name') is not present in the package." }
                $targetId = $deByCode[$targetCode]
            }

            $actionId = $null
            foreach ($da in $deployedActions) {
                if ([string]$da['programRuleActionType'] -ne $type) { continue }
                if ($targetId) {
                    $deTgt = if ($da['dataElement'] -is [System.Collections.IDictionary]) { [string]$da['dataElement']['id'] } else { $null }
                    if ($deTgt -ne $targetId) { continue }
                }
                if (Test-NeoIPCMetadataUid -Id ([string]$da['id'])) { $actionId = [string]$da['id']; break }
            }
            if (-not $actionId) {
                $nk = if ($targetCode) { '{0}|{1}|{2}' -f $name, $type, $targetCode } else { '{0}|{1}' -f $name, $type }
                $actionId = New-NeoIPCMetadataUid -Type 'programRuleActions' -NaturalKey $nk
            }
            if (-not $actionsSeen.Add($actionId)) { throw "UID collision for an action of program rule '$name' (uid '$actionId')." }

            $action = [ordered]@{
                id                    = $actionId
                programRule           = [ordered]@{ id = $ruleId }
                programRuleActionType = $type
            }
            if ($targetId) { $action['dataElement'] = [ordered]@{ id = $targetId } }
            if ($a['UsesCommonCommensalSet']) {
                if ($commonCommensal.Count -eq 0) { throw "The common-commensal code set is empty — cannot build the recognized-pathogen ASSIGN expression for '$name'." }
                $valueVar = [string]$d['ValueVariable']
                $terms = ($commonCommensal | ForEach-Object { "#{$valueVar}==$_" }) -join '||'
                $action['content'] = [string]$a['Content']
                $action['data'] = "d2:hasValue(#{$valueVar}) && !($terms)"
            }
            elseif ($a['Content']) { $action['content'] = [string]$a['Content'] }
            $actions.Add($action)
            $actionRefs.Add([ordered]@{ id = $actionId })
        }
        $rule['programRuleActions'] = $actionRefs.ToArray()
        $rules.Add($rule)
    }

    [ordered]@{ programRules = $rules.ToArray(); programRuleActions = $actions.ToArray() }
}

function New-NeoIPCSubstanceDataElement {
    <#
    .SYNOPSIS
        Generate the antimicrobial-substance per-slot DATA ELEMENTS of NEOIPC_CORE (surveillance-end stage).
    .DESCRIPTION
        Expands the substance plan (Get-NeoIPCSubstanceDataElementPlan) — for each of SubstanceCount slots a substance
        DE (TEXT, optionSet AND commentOptionSet NEOIPC_ANTIMICROBIAL_SUBSTANCES) and a days DE (INTEGER_POSITIVE). The
        slot number is 2-digit zero-padded in code / name / shortName; the formName stays unpadded (a data-entry UI
        label with no ordering role). Structure (valueType / option sets / aggregationType / zeroIsSignificant / names)
        comes from the plan; the UID, description and categoryCombo are reused from the export by code where the slot
        already exists.

        Supports growing the program beyond the deployed slot count: a slot whose code is NOT in the package (a 10th..
        99th substance) is MINTED — its UID from the code, its categoryCombo copied from the lowest-numbered deployed DE
        of the same kind (substance / days), its description templated — rather than failing loud. Fail-loud only when a
        brand-new slot has no deployed sibling to copy a categoryCombo from, or a referenced option set is absent. Pure
        object processing — no DHIS2 API calls. Returns a package fragment { dataElements }.
    .PARAMETER ExistingPackage
        Parsed DHIS2 package/export supplying the deployed substance DEs (UID / description / categoryCombo) and the
        NEOIPC_ANTIMICROBIAL_SUBSTANCES option set.
    .PARAMETER SubstanceCount
        Number of antimicrobial-substance slots (1-99, default 9). Pass the same value to New-NeoIPCSubstanceVariable
        and New-NeoIPCSubstanceRule so the data elements, variables and rules stay aligned.
    .OUTPUTS
        [ordered] hashtable with key 'dataElements' (2 x SubstanceCount).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$ExistingPackage,
        [ValidateRange(1, 99)][int]$SubstanceCount = $script:NeoIPCSubstanceSlotCount
    )

    $deByCode = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    foreach ($de in @($ExistingPackage['dataElements'])) {
        if ($de -is [System.Collections.IDictionary] -and $de['code']) {
            $c = [string]$de['code']
            if ($deByCode.ContainsKey($c)) { throw "Duplicate data-element code '$c' in the package." }
            $deByCode[$c] = $de
        }
    }
    $osByCode = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    foreach ($os in @($ExistingPackage['optionSets'])) {
        if ($os -is [System.Collections.IDictionary] -and $os['code']) {
            $c = [string]$os['code']
            if ($osByCode.ContainsKey($c)) { throw "Duplicate option-set code '$c' in the package." }
            $osByCode[$c] = [string]$os['id']
        }
    }

    $plan = @(Get-NeoIPCSubstanceDataElementPlan -SubstanceCount $SubstanceCount)

    # Reference categoryCombo and sharing per kind for minted (growth) slots: those of the lowest-numbered deployed
    # DE of that kind, resolved once in plan order so they are deterministic.
    $refCatCombo = @{}
    $refSharing = @{}
    foreach ($d in $plan) {
        $kind = [string]$d['Kind']
        if (-not $deByCode.ContainsKey([string]$d['Code'])) { continue }
        $ex = $deByCode[[string]$d['Code']]
        if (-not $refCatCombo.ContainsKey($kind) -and $ex['categoryCombo'] -is [System.Collections.IDictionary]) {
            $refCatCombo[$kind] = [ordered]@{ id = [string]$ex['categoryCombo']['id'] }
        }
        if (-not $refSharing.ContainsKey($kind) -and $ex.Contains('sharing')) {
            $sh = Convert-NeoIPCSharing $ex['sharing']
            if ($sh -and $sh.Count -gt 0) { $refSharing[$kind] = $sh }
        }
    }

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($d in $plan) {
        $code = [string]$d['Code']
        $kind = [string]$d['Kind']
        $existing = if ($deByCode.ContainsKey($code)) { $deByCode[$code] } else { $null }

        $id = if ($existing -and (Test-NeoIPCMetadataUid -Id ([string]$existing['id']))) { [string]$existing['id'] }
        else { New-NeoIPCMetadataUid -Type 'dataElements' -NaturalKey $code }
        if (-not $seen.Add($id)) { throw "Duplicate data-element id '$id' for code '$code'." }

        $de = [ordered]@{
            id        = $id
            code      = $code
            name      = [string]$d['Name']
            shortName = [string]$d['ShortName']
            formName  = [string]$d['FormName']
        }
        if ($existing -and $existing.Contains('description') -and "$($existing['description'])") {
            $de['description'] = [string]$existing['description']
        }
        else {
            $de['description'] = if ($kind -eq 'days') {
                "The cumulative number of days the infant received antibiotic substance number $($d['Index'])."
            }
            else { "Systemic antibiotic substance number $($d['Index']) the infant received." }
        }
        $de['valueType'] = [string]$d['ValueType']
        $de['domainType'] = 'TRACKER'
        $de['aggregationType'] = [string]$d['AggregationType']
        $de['zeroIsSignificant'] = [bool]$d['ZeroIsSignificant']

        if ($existing -and $existing['categoryCombo'] -is [System.Collections.IDictionary]) {
            $de['categoryCombo'] = [ordered]@{ id = [string]$existing['categoryCombo']['id'] }
        }
        elseif ($refCatCombo.ContainsKey($kind)) { $de['categoryCombo'] = $refCatCombo[$kind] }
        else { throw "Cannot derive a categoryCombo for new substance data element '$code' — no deployed '$kind' substance DE to copy from." }

        if ($d['OptionSetCode']) {
            $osc = [string]$d['OptionSetCode']
            if (-not $osByCode.ContainsKey($osc)) { throw "Option set '$osc' (bound by data element '$code') is not present in the package." }
            $de['optionSet'] = [ordered]@{ id = $osByCode[$osc] }
        }
        if ($d['CommentOptionSetCode']) {
            $cosc = [string]$d['CommentOptionSetCode']
            if (-not $osByCode.ContainsKey($cosc)) { throw "Comment option set '$cosc' (bound by data element '$code') is not present in the package." }
            $de['commentOptionSet'] = [ordered]@{ id = $osByCode[$cosc] }
        }
        # Reuse the deployed DE's sharing (normalised), else the lowest-numbered deployed sibling's for grown slots —
        # without it the regenerated DEs would import with null sharing instead of the deployed public access.
        if ($existing -and $existing.Contains('sharing')) {
            $sh = Convert-NeoIPCSharing $existing['sharing']
            if ($sh -and $sh.Count -gt 0) { $de['sharing'] = $sh }
        }
        elseif ($refSharing.ContainsKey($kind)) { $de['sharing'] = $refSharing[$kind] }
        $out.Add($de)
    }
    [ordered]@{ dataElements = $out.ToArray() }
}

function New-NeoIPCSubstanceVariable {
    <#
    .SYNOPSIS
        Generate the antimicrobial-substance per-slot PROGRAM-RULE VARIABLES of NEOIPC_CORE.
    .DESCRIPTION
        Expands the substance PRV plan (Get-NeoIPCSubstanceVariablePlan) — for each slot a substance value PRV (TEXT,
        useCodeForOptionSet true) and a days value PRV (INTEGER_POSITIVE), both DATAELEMENT_CURRENT_EVENT over the
        slot's DE. Names are 2-digit padded. The UID is preserved from the export by a slot-number-NORMALISED name (so
        the deployed unpadded `substance 2 …` maps to the generated padded `substance 02 …` and keeps its UID), else
        minted from the padded name. The base DE and program references are resolved by code. Fail-loud if a base DE or
        the program is absent. Pure object processing — no DHIS2 API calls. Returns { programRuleVariables }.
    .PARAMETER ExistingPackage
        Parsed DHIS2 package/export supplying UIDs to preserve, the substance / days DEs (by code) and the program.
    .PARAMETER SubstanceCount
        Number of antimicrobial-substance slots (1-99, default 9).
    .PARAMETER ProgramCode
        Code of the program the variables belong to. Default: NEOIPC_CORE.
    .OUTPUTS
        [ordered] hashtable with key 'programRuleVariables' (2 x SubstanceCount).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$ExistingPackage,
        [ValidateRange(1, 99)][int]$SubstanceCount = $script:NeoIPCSubstanceSlotCount,
        [string]$ProgramCode = 'NEOIPC_CORE'
    )

    $programId = $null
    foreach ($p in @($ExistingPackage['programs'])) {
        if ($p -is [System.Collections.IDictionary] -and [string]$p['code'] -eq $ProgramCode) { $programId = [string]$p['id']; break }
    }
    if (-not $programId) { throw "Program '$ProgramCode' not found in the package." }

    $deByCode = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    foreach ($de in @($ExistingPackage['dataElements'])) {
        if ($de -is [System.Collections.IDictionary] -and $de['code']) {
            $c = [string]$de['code']
            if ($deByCode.ContainsKey($c)) { throw "Duplicate data-element code '$c' in the package." }
            $deByCode[$c] = [string]$de['id']
        }
    }
    # Index deployed PRVs by slot-number-normalised name (padding-insensitive UID preservation), first-wins.
    $prvByName = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    foreach ($v in @($ExistingPackage['programRuleVariables'])) {
        if ($v -is [System.Collections.IDictionary] -and $v['name']) {
            $nm = ConvertTo-NeoIPCSubstanceUnpaddedName -Name ([string]$v['name'])
            if (-not $prvByName.ContainsKey($nm)) { $prvByName[$nm] = [string]$v['id'] }
        }
    }

    $plan = @(Get-NeoIPCSubstanceVariablePlan -SubstanceCount $SubstanceCount)
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($d in $plan) {
        $name = [string]$d['Name']
        $normalised = ConvertTo-NeoIPCSubstanceUnpaddedName -Name $name
        $existingId = if ($prvByName.ContainsKey($normalised)) { $prvByName[$normalised] } else { $null }
        $id = if ($existingId -and (Test-NeoIPCMetadataUid -Id $existingId)) { $existingId }
        else { New-NeoIPCMetadataUid -Type 'programRuleVariables' -NaturalKey $name }
        if (-not $seen.Add($id)) { throw "UID collision for program-rule variable '$name' (uid '$id')." }

        $dec = [string]$d['DataElementCode']
        if (-not $deByCode.ContainsKey($dec)) { throw "Base data element '$dec' (read by variable '$name') is not present in the package." }
        $out.Add([ordered]@{
                id                            = $id
                name                          = $name
                programRuleVariableSourceType = [string]$d['SourceType']
                valueType                     = [string]$d['ValueType']
                useCodeForOptionSet           = [bool]$d['UseCodeForOptionSet']
                program                       = [ordered]@{ id = $programId }
                dataElement                   = [ordered]@{ id = $deByCode[$dec] }
            })
    }
    [ordered]@{ programRuleVariables = $out.ToArray() }
}

function New-NeoIPCSubstanceRule {
    <#
    .SYNOPSIS
        Generate the antimicrobial-substance cascading-reveal / require / validate RULES of NEOIPC_CORE.
    .DESCRIPTION
        Expands the substance rule plan (Get-NeoIPCSubstanceRulePlan) on the surveillance-end stage: per slot a `hide`
        rule (two HIDEFIELD on the substance + days DE, cascading — slot 1 gated on total AB days, slot N>=2 on the
        previous slot having a value), a `days - require` (SETMANDATORYFIELD); slot 1 a `substance - require`; plus one
        cross-slot `validate` (SHOWERROR when the substance-days sum is below total AB days). Names are 2-digit padded;
        conditions read the `… - current event value` PRVs directly. The programStage is resolved as the stage that owns
        the total AB-days DE (the deployed stages carry no code), each action's target DE by code, and the validate
        SHOWERROR targets NEOIPC_SURVEILLANCE_END_AB_DAYS.

        UID preservation is padding-insensitive: a rule preserves its UID from the export by a slot-number-NORMALISED
        name, else mints from the padded name; an action preserves the UID of its owning deployed rule's action matching
        (action type + target DE) — the hide rule carries two HIDEFIELD actions on different DEs — else mints from
        `<padded rule name>|<type>|<target code>`. Fail-loud on a missing program / stage / target DE. Pure object
        processing — no DHIS2 API calls. Returns { programRules; programRuleActions }.
    .PARAMETER ExistingPackage
        Parsed DHIS2 package/export supplying the program, the surveillance-end stage, the substance / days / AB-days
        DEs (by code) and the deployed rules/actions whose UIDs are preserved.
    .PARAMETER SubstanceCount
        Number of antimicrobial-substance slots (1-99, default 9).
    .PARAMETER ProgramCode
        Code of the program. Default: NEOIPC_CORE.
    .OUTPUTS
        [ordered] hashtable with keys 'programRules' and 'programRuleActions'.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$ExistingPackage,
        [ValidateRange(1, 99)][int]$SubstanceCount = $script:NeoIPCSubstanceSlotCount,
        [string]$ProgramCode = 'NEOIPC_CORE'
    )

    $programId = $null
    foreach ($p in @($ExistingPackage['programs'])) {
        if ($p -is [System.Collections.IDictionary] -and [string]$p['code'] -eq $ProgramCode) { $programId = [string]$p['id']; break }
    }
    if (-not $programId) { throw "Program '$ProgramCode' not found in the package." }

    $deByCode = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    foreach ($de in @($ExistingPackage['dataElements'])) {
        if ($de -is [System.Collections.IDictionary] -and $de['code']) {
            $c = [string]$de['code']
            if ($deByCode.ContainsKey($c)) { throw "Duplicate data-element code '$c' in the package." }
            $deByCode[$c] = [string]$de['id']
        }
    }

    # The surveillance-end program stage carries no code, so resolve it as the stage that owns the total AB-days DE.
    $stageByDeId = Get-NeoIPCStageByDataElementId -Package $ExistingPackage
    $stageAnchor = 'NEOIPC_SURVEILLANCE_END_AB_DAYS'
    if (-not ($deByCode.ContainsKey($stageAnchor) -and $stageByDeId.ContainsKey($deByCode[$stageAnchor]))) {
        throw "Cannot resolve the surveillance-end program stage — the anchor data element '$stageAnchor' is absent from the package or not assigned to a stage."
    }
    $psId = $stageByDeId[$deByCode[$stageAnchor]]
    # Deployed rules by slot-number-normalised name (first-wins) + actions grouped by owning rule id.
    $ruleByName = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    foreach ($r in @($ExistingPackage['programRules'])) {
        if ($r -is [System.Collections.IDictionary] -and $r['name']) {
            $nm = ConvertTo-NeoIPCSubstanceUnpaddedName -Name ([string]$r['name'])
            if (-not $ruleByName.ContainsKey($nm)) { $ruleByName[$nm] = $r }
        }
    }
    $actionsByRuleId = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[object]]]::new([System.StringComparer]::Ordinal)
    foreach ($a in @($ExistingPackage['programRuleActions'])) {
        if ($a -isnot [System.Collections.IDictionary]) { continue }
        $pr = $a['programRule']
        if ($pr -is [System.Collections.IDictionary] -and $pr['id']) {
            $rid = [string]$pr['id']
            if (-not $actionsByRuleId.ContainsKey($rid)) { $actionsByRuleId[$rid] = [System.Collections.Generic.List[object]]::new() }
            $actionsByRuleId[$rid].Add($a)
        }
    }

    $plan = @(Get-NeoIPCSubstanceRulePlan -SubstanceCount $SubstanceCount)
    $rulesSeen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $actionsSeen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $rules = [System.Collections.Generic.List[object]]::new()
    $actions = [System.Collections.Generic.List[object]]::new()

    foreach ($d in $plan) {
        $name = [string]$d['Name']
        $normalised = ConvertTo-NeoIPCSubstanceUnpaddedName -Name $name
        $deployedRule = if ($ruleByName.ContainsKey($normalised)) { $ruleByName[$normalised] } else { $null }
        $deployedRuleId = if ($deployedRule) { [string]$deployedRule['id'] } else { $null }

        $ruleId = if ($deployedRuleId -and (Test-NeoIPCMetadataUid -Id $deployedRuleId)) { $deployedRuleId }
        else { New-NeoIPCMetadataUid -Type 'programRules' -NaturalKey $name }
        if (-not $rulesSeen.Add($ruleId)) { throw "UID collision for program rule '$name' (uid '$ruleId')." }

        $rule = [ordered]@{ id = $ruleId; name = $name }
        if ($deployedRule -and $deployedRule.Contains('description') -and "$($deployedRule['description'])") {
            $rule['description'] = [string]$deployedRule['description']
        }
        $rule['program'] = [ordered]@{ id = $programId }
        $rule['programStage'] = [ordered]@{ id = $psId }
        $rule['condition'] = [string]$d['Condition']
        if ($null -ne $d['Priority']) { $rule['priority'] = [int]$d['Priority'] }

        $deployedActions = if ($deployedRuleId -and $actionsByRuleId.ContainsKey($deployedRuleId)) { $actionsByRuleId[$deployedRuleId] } else { @() }
        $actionRefs = [System.Collections.Generic.List[object]]::new()
        foreach ($a in @($d['Actions'])) {
            $type = [string]$a['Type']
            $targetCode = [string]$a['DataElementCode']
            if (-not $deByCode.ContainsKey($targetCode)) { throw "Data element '$targetCode' (targeted by rule '$name') is not present in the package." }
            $targetId = $deByCode[$targetCode]

            $actionId = $null
            foreach ($da in $deployedActions) {
                if ([string]$da['programRuleActionType'] -ne $type) { continue }
                $deTgt = if ($da['dataElement'] -is [System.Collections.IDictionary]) { [string]$da['dataElement']['id'] } else { $null }
                if ($deTgt -eq $targetId -and (Test-NeoIPCMetadataUid -Id ([string]$da['id']))) { $actionId = [string]$da['id']; break }
            }
            if (-not $actionId) { $actionId = New-NeoIPCMetadataUid -Type 'programRuleActions' -NaturalKey ('{0}|{1}|{2}' -f $name, $type, $targetCode) }
            if (-not $actionsSeen.Add($actionId)) { throw "UID collision for an action of program rule '$name' (uid '$actionId')." }

            $action = [ordered]@{
                id                    = $actionId
                programRule           = [ordered]@{ id = $ruleId }
                programRuleActionType = $type
                dataElement           = [ordered]@{ id = $targetId }
            }
            if ($a['Content']) { $action['content'] = [string]$a['Content'] }
            $actions.Add($action)
            $actionRefs.Add([ordered]@{ id = $actionId })
        }
        $rule['programRuleActions'] = $actionRefs.ToArray()
        $rules.Add($rule)
    }

    [ordered]@{ programRules = $rules.ToArray(); programRuleActions = $actions.ToArray() }
}
