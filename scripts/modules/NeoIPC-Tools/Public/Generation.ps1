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
        surveillance data and compared by the resistance program rules); the option NAME is the node's Name (per
        the domain-authority naming policy in the repo CLAUDE.md). Output order is a deterministic depth-first walk
        of the ontology (node, then Hierarchies/Synonyms/Children) with a 1-based sortOrder, so diffs are stable.

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
                name      = [string]$c['Name']
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
    .OUTPUTS
        [ordered] hashtable with key 'dataElements' (the 135 per-slot pathogen data elements).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$ExistingPackage
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

    $plan = @(Get-NeoIPCPathogenDataElementPlan)
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
        absent). The slot-specific housekeeping variables (name value, source value, is recognized pathogen,
        recovered multiple times) are generated with their rules, not here.

        Pure object processing — no DHIS2 API calls. Returns a package fragment { programRuleVariables }.
    .PARAMETER ExistingPackage
        An already-parsed DHIS2 package/export (hashtable) supplying UIDs to preserve, the base organism DEs the
        `value` variables read (by code), and the NEOIPC_CORE program reference.
    .PARAMETER ProgramCode
        Code of the program the variables belong to. Default: NEOIPC_CORE.
    .OUTPUTS
        [ordered] hashtable with key 'programRuleVariables' (the 108 resistance-gating variables).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$ExistingPackage,
        [string]$ProgramCode = 'NEOIPC_CORE'
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

    $plan = @(Get-NeoIPCPathogenVariablePlan)
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
