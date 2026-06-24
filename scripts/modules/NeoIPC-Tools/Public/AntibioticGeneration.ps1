# NeoIPC metadata pipeline — antibiotic-domain generators (the importable DHIS2 objects built from the
# reconciled antibiotic sources rather than hand-authored in the directory CSVs). See
# metadata/common/antibiotics/README.md for the curation model these reproduce.

function New-NeoIPCAntimicrobialOptionSet {
    <#
    .SYNOPSIS
        Generate the DHIS2 NEOIPC_ANTIMICROBIAL_SUBSTANCES option set + options from NeoIPC-Antibiotics.csv.
    .DESCRIPTION
        Emits one DHIS2 option per row of the reconciled substance table (the systemic antibiotic option set —
        244 substances), plus the option-set object that binds them. The option CODE is the row's id (the code
        stored in collected data); the option NAME is the row's canonical name; sortOrder is a 1-based rank in
        alphabetical-by-name order, reproducing the deployed convention so the option picker stays alphabetical.

        UID = SOURCE identity (no longer the export): the option set's UID is -OptionSetUid (the captured constant)
        and each option's UID is its source row's `uid` column; a blank/invalid one is minted deterministically from
        the natural key "<optionSetUid>|<code>" (a not-yet-deployed substance, e.g. an oral route-split). The four
        reconciliation renames (J01AA08->J01AA08_P, J01XX01->J01XX01_P, Cefoselis->tmp_002, Micronomicin->tmp_001)
        already carry the original deployed option's UID in the source row, so the option-set ref stays minimal-diff
        and only the stored data values (not the metadata) need migrating.

        Fail-loud (no silent drop): with -ExistingPackage, every deployed option code — canonicalised through the
        rename map — MUST resolve to a source substance; any that does not throws (the source and the deployed set
        have diverged beyond the documented migrations — reconcile first). New substances not yet deployed are
        added (reported via -Verbose). The export is consulted ONLY for this validation and the deployed sharing /
        valueType — never for identity; omit it to generate from source alone.

        With -PoDirectory, each option also gets a translations[] entry per locale whose name differs from the
        English source, composed from $PoBaseName.<locale>.po (the bilingual antibiotic catalogue keyed by the
        English name) via Get-NeoIPCPoTranslationMap. Antibiotic names are flat (no rank tag), so the localized
        name is just the catalogue's translation of the English name. Without -PoDirectory the options are
        English-only. (The antibiotic domain is excluded from the general metadata gettext-PO path, so this is the
        sole translation source for these options — mirrors the pathogen option set.)

        Pure file/object processing — no DHIS2 API calls. Returns a package fragment { optionSets; options }.
    .PARAMETER Path
        Path to NeoIPC-Antibiotics.csv. Defaults to the canonical file in the repository.
    .PARAMETER ExistingPackage
        Optional already-parsed DHIS2 package/export (a hashtable) whose NEOIPC_ANTIMICROBIAL_SUBSTANCES option set
        + options supply UIDs to preserve and the deployed code set to validate against. Omit to mint all UIDs.
    .PARAMETER OptionSetCode
        The option set's code. Default: NEOIPC_ANTIMICROBIAL_SUBSTANCES.
    .PARAMETER OptionSetUid
        The option set's DHIS2 UID (source identity). Default: the captured constant. Minted from the code if invalid.
    .PARAMETER OptionSetName
        The option set's name. Default: 'NeoIPC Antimicrobial Substances'.
    .PARAMETER ValueType
        The option set's value type. Default: TEXT (antibiotic codes are alphanumeric, e.g. J01AA01 / tmp_001).
        Reused from the deployed option set when -ExistingPackage carries it.
    .PARAMETER PoDirectory
        Optional directory holding the bilingual antibiotic catalogues ($PoBaseName.<locale>.po). When supplied,
        per-locale option-name translations[] are composed from those catalogues. Omit for English-only output.
    .PARAMETER PoBaseName
        Base name of the locale catalogues under -PoDirectory. Default: antibiotics.
    .OUTPUTS
        [ordered] hashtable with keys 'optionSets' (one object) and 'options' (one per substance).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Position = 0)]
        [string]$Path = (Join-Path $PSScriptRoot '..' '..' '..' '..' 'metadata' 'common' 'antibiotics' 'NeoIPC-Antibiotics.csv'),
        [System.Collections.IDictionary]$ExistingPackage,
        [string]$OptionSetCode = 'NEOIPC_ANTIMICROBIAL_SUBSTANCES',
        [string]$OptionSetUid = $script:NeoIPCAntimicrobialOptionSetUid,
        [string]$OptionSetName = 'NeoIPC Antimicrobial Substances',
        [string]$ValueType = 'TEXT',
        [string]$PoDirectory,
        [string]$PoBaseName = 'antibiotics'
    )

    $substances = @(Get-NeoIPCAntibioticSubstance -Path $Path)
    $byCode = [ordered]@{}
    foreach ($s in $substances) { $byCode[$s.Id] = $s }   # uniqueness already enforced by the reader

    # Identity is from source (the option set's -OptionSetUid + each substance's `uid`). The export, when supplied, is
    # consulted ONLY for the deployed sharing / valueType and the no-silent-drop validation — its option-set id scopes
    # the deployed code set (canonicalised through the rename map), never the emitted identity.
    $existingCodes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $existingSharing = $null
    $existingValueType = $null
    if ($ExistingPackage) {
        $existingOsUid = $null
        foreach ($os in @($ExistingPackage['optionSets'])) {
            if ($os -is [System.Collections.IDictionary] -and [string]$os['code'] -eq $OptionSetCode) {
                $existingOsUid = [string]$os['id']
                if ($os.Contains('sharing')) { $existingSharing = Convert-NeoIPCSharing $os['sharing'] }
                if ($os['valueType']) { $existingValueType = [string]$os['valueType'] }
                break
            }
        }
        if (-not $existingOsUid) {
            throw "Option set '$OptionSetCode' was not found in the supplied -ExistingPackage. Pass an export that contains the deployed option set to reconcile against, or omit -ExistingPackage to skip the validation."
        }
        foreach ($opt in @($ExistingPackage['options'])) {
            if ($opt -isnot [System.Collections.IDictionary]) { continue }
            $osRef = $opt['optionSet']
            if ($osRef -is [System.Collections.IDictionary] -and [string]$osRef['id'] -eq $existingOsUid) {
                [void]$existingCodes.Add((ConvertTo-NeoIPCAntibioticCanonicalCode -Code ([string]$opt['code'])))
            }
        }
    }

    # No silent drop: every deployed code (canonicalised) must resolve to a source substance.
    if ($existingCodes.Count -gt 0) {
        $missing = @($existingCodes | Where-Object { -not $byCode.Contains($_) } | Sort-Object)
        if ($missing.Count -gt 0) {
            throw ("Regeneration would drop {0} deployed option code(s) absent from NeoIPC-Antibiotics.csv: {1}. Add each back (or extend the code-rename map) before regenerating." -f `
                    $missing.Count, ($missing -join ', '))
        }
        $added = @($byCode.Keys | Where-Object { -not $existingCodes.Contains($_) })
        Write-Verbose ("Option set '{0}': {1} substances ({2} deployed, {3} new)." -f `
                $OptionSetCode, $substances.Count, $existingCodes.Count, $added.Count)
    }

    $osUid = if (Test-NeoIPCMetadataUid -Id $OptionSetUid) { $OptionSetUid }
    else { New-NeoIPCMetadataUid -Type 'optionSets' -NaturalKey $OptionSetCode }
    if ($existingValueType) { $ValueType = $existingValueType }

    # Optional localization: english-name -> localized-name maps from the bilingual antibiotic catalogues.
    $localeMaps = Get-NeoIPCAntibioticLocaleMap -PoDirectory $PoDirectory -PoBaseName $PoBaseName

    # Build options + the option-set's ordered option-ref list. sortOrder = 1-based alphabetical by name (the
    # deployed convention). Ordinal sort keeps it locale-independent and stable across machines.
    $ordered = @($substances | Sort-Object -Property @{ Expression = { $_.Name } } -Culture '')
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    [void]$seen.Add($osUid)
    $options = [System.Collections.Generic.List[object]]::new()
    $optionRefs = [System.Collections.Generic.List[object]]::new()
    $sortOrder = 1
    foreach ($s in $ordered) {
        $code = $s.Id
        $uid = if (Test-NeoIPCMetadataUid -Id $s.Uid) { $s.Uid }
        else { New-NeoIPCMetadataUid -Type 'options' -NaturalKey ('{0}|{1}' -f $osUid, $code) }
        if (-not $seen.Add($uid)) { throw "UID collision for option code '$code' (uid '$uid')." }
        # name is always present; shortName/formName/description only when the source carries them (truly optional).
        $fields = Get-NeoIPCAntibioticTranslatableValues -Name $s.Name -ShortName $s.ShortName -FormName $s.FormName -Description $s.Description
        $opt = [ordered]@{ id = $uid; code = $code }
        foreach ($p in $fields.Keys) { $opt[$p] = $fields[$p] }
        $opt['sortOrder'] = $sortOrder
        $opt['optionSet'] = [ordered]@{ id = $osUid }
        $opt = Add-NeoIPCAntibioticTranslations -Object $opt -EnglishValue $fields -LocaleMaps $localeMaps
        $options.Add($opt)
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

function New-NeoIPCAntibioticOptionGroup {
    <#
    .SYNOPSIS
        Generate the antibiotic option GROUPS (34 ATC-4 groups + 3 AWaRe groups) over the antimicrobial option set.
    .DESCRIPTION
        Emits one DHIS2 optionGroup per ATC-4 group (NeoIPC-Antibiotic-Groups.csv) and per AWaRe category, with
        membership derived from the reconciled substance table: an ATC group contains the options whose atc_group
        matches its code; an AWaRe group (WHO_AWARE_ACCESS/WATCH/RESERVE) contains the options whose aware_category
        matches. Members are option UIDs resolved from -OptionSet (so the two new oral-split options are included),
        ordered by option code for stable diffs.

        The ATC group's name/shortName/description come from NeoIPC-Antibiotic-Groups.csv; the AWaRe groups'
        name/shortName/description come from NeoIPC-Antibiotic-AWaRe-Groups.csv (both abstract reference lists). Each
        group's UID is its source CSV's `uid` column (minted deterministically from the code when blank); the
        optionSet ref is the generated set's UID. -ExistingPackage is OPTIONAL and supplies only each group's deployed
        sharing by code — never identity; omit it for sharing-less groups (DHIS2 defaults apply on import). With
        -PoDirectory each group's full translatable surface (name/shortName/description) gets localized translations[]
        from the antibiotic catalogue.

        Fail-loud: an ATC group with no member options throws (the source and the group list have drifted), as does a
        UID collision across the generated groups. Returns { optionGroups }.
    .PARAMETER OptionSet
        The fragment from New-NeoIPCAntimicrobialOptionSet ({ optionSets; options }), supplying the option set UID
        and the option-code -> UID map for membership.
    .PARAMETER SubstancePath
        Path to NeoIPC-Antibiotics.csv (the atc_group / aware_category source). Defaults to the canonical file.
    .PARAMETER GroupPath
        Path to NeoIPC-Antibiotic-Groups.csv (the ATC-4 group shells). Defaults to the canonical file.
    .PARAMETER AwareGroupPath
        Path to NeoIPC-Antibiotic-AWaRe-Groups.csv (the 3 WHO AWaRe group shells). Defaults to the canonical file.
    .PARAMETER ExistingPackage
        Optional parsed export supplying each group's deployed sharing by code (never identity). Omit for
        sharing-less groups.
    .PARAMETER PoDirectory / .PARAMETER PoBaseName
        Optional bilingual antibiotic catalogues for localized group name/shortName/description (default 'antibiotics').
    .OUTPUTS
        [ordered] hashtable with key 'optionGroups' (37 at the canonical counts).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$OptionSet,
        [string]$SubstancePath = (Join-Path $PSScriptRoot '..' '..' '..' '..' 'metadata' 'common' 'antibiotics' 'NeoIPC-Antibiotics.csv'),
        [string]$GroupPath = (Join-Path $PSScriptRoot '..' '..' '..' '..' 'metadata' 'common' 'antibiotics' 'NeoIPC-Antibiotic-Groups.csv'),
        [string]$AwareGroupPath = (Join-Path $PSScriptRoot '..' '..' '..' '..' 'metadata' 'common' 'antibiotics' 'NeoIPC-Antibiotic-AWaRe-Groups.csv'),
        [System.Collections.IDictionary]$ExistingPackage,
        [string]$PoDirectory,
        [string]$PoBaseName = 'antibiotics'
    )

    $substances = @(Get-NeoIPCAntibioticSubstance -Path $SubstancePath)
    $atcGroups = @(Get-NeoIPCAntibioticGroup -Path $GroupPath)

    # option code -> UID (from the generated set, so the new oral splits resolve)
    $osUid = [string]($OptionSet['optionSets'][0]['id'])
    $optUidByCode = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    foreach ($o in @($OptionSet['options'])) { $optUidByCode[[string]$o['code']] = [string]$o['id'] }

    # deployed optionGroup shells (sharing only) by code — for enrichment, not identity. Empty when no export.
    $depGroupByCode = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    if ($ExistingPackage) {
        foreach ($g in @($ExistingPackage['optionGroups'])) {
            if ($g -is [System.Collections.IDictionary] -and $g['code']) { $depGroupByCode[[string]$g['code']] = $g }
        }
    }

    $localeMaps = Get-NeoIPCAntibioticLocaleMap -PoDirectory $PoDirectory -PoBaseName $PoBaseName
    $seenUid = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    # Resolve a group's UID from its source `uid` (mint deterministically from the code when blank) and guard collisions.
    $groupUid = {
        param($Code, $SourceUid)
        $u = if (Test-NeoIPCMetadataUid -Id $SourceUid) { $SourceUid } else { New-NeoIPCMetadataUid -Type 'optionGroups' -NaturalKey $Code }
        if (-not $seenUid.Add($u)) { throw "UID collision for option group '$Code' (uid '$u')." }
        $u
    }

    # membership: ATC group code -> [option codes]; AWaRe category -> [option codes]
    $atcMembers = @{}; $awMembers = @{}
    foreach ($s in $substances) {
        if ($s.AtcGroup) {
            if (-not $atcMembers.ContainsKey($s.AtcGroup)) { $atcMembers[$s.AtcGroup] = [System.Collections.Generic.List[string]]::new() }
            $atcMembers[$s.AtcGroup].Add($s.Id)
        }
        if ($s.AwareCategory) {
            if (-not $awMembers.ContainsKey($s.AwareCategory)) { $awMembers[$s.AwareCategory] = [System.Collections.Generic.List[string]]::new() }
            $awMembers[$s.AwareCategory].Add($s.Id)
        }
    }

    $resolveMembers = {
        param($codes)
        @($codes | Sort-Object | ForEach-Object { [ordered]@{ id = $optUidByCode[$_] } })
    }
    $groups = [System.Collections.Generic.List[object]]::new()

    # ATC-4 groups (shell from the Groups CSV; UID from its `uid`; membership by atc_group; sharing from the export)
    foreach ($g in $atcGroups) {
        $members = $atcMembers[$g.Code]
        if (-not $members -or $members.Count -eq 0) { throw "ATC group '$($g.Code)' ($($g.Name)) has no member options — the source and the group list have drifted." }
        $dep = $null; [void]$depGroupByCode.TryGetValue($g.Code, [ref]$dep)
        $fields = Get-NeoIPCAntibioticTranslatableValues -Name $g.Name -ShortName $g.ShortName -Description $g.Description
        $obj = [ordered]@{ id = (& $groupUid $g.Code $g.Uid); code = $g.Code }
        foreach ($p in $fields.Keys) { $obj[$p] = $fields[$p] }
        $obj['optionSet'] = [ordered]@{ id = $osUid }
        $obj['options'] = & $resolveMembers $members
        if ($dep) { $obj = Add-NeoIPCAntibioticGroupSharing -Group $obj -Deployed $dep }
        $obj = Add-NeoIPCAntibioticTranslations -Object $obj -EnglishValue $fields -LocaleMaps $localeMaps
        $groups.Add($obj)
    }

    # AWaRe groups: name/shortName/description + UID come from NeoIPC-Antibiotic-AWaRe-Groups.csv (an abstract
    # reference list, like the ATC groups); sharing is enriched from the export by code. Membership is by aware_category.
    foreach ($aw in @(Get-NeoIPCAntibioticAwareGroup -Path $AwareGroupPath)) {
        $code = $aw.Code
        $dep = $null; [void]$depGroupByCode.TryGetValue($code, [ref]$dep)
        $members = $awMembers[$aw.Category]
        if (-not $members -or $members.Count -eq 0) { throw "AWaRe group '$code' (category '$($aw.Category)') has no member options." }
        $fields = Get-NeoIPCAntibioticTranslatableValues -Name $aw.Name -ShortName $aw.ShortName -Description $aw.Description
        $obj = [ordered]@{ id = (& $groupUid $code $aw.Uid); code = $code }
        foreach ($p in $fields.Keys) { $obj[$p] = $fields[$p] }
        $obj['optionSet'] = [ordered]@{ id = $osUid }
        $obj['options'] = & $resolveMembers $members
        if ($dep) { $obj = Add-NeoIPCAntibioticGroupSharing -Group $obj -Deployed $dep }
        $obj = Add-NeoIPCAntibioticTranslations -Object $obj -EnglishValue $fields -LocaleMaps $localeMaps
        $groups.Add($obj)
    }

    [ordered]@{ optionGroups = $groups.ToArray() }
}

function New-NeoIPCAntibioticOptionGroupSet {
    <#
    .SYNOPSIS
        Generate the two antibiotic option-group SETS (ATC5, WHO_AWARE) over the generated option groups.
    .DESCRIPTION
        Emits the ATC5 group-set (containing the 34 ATC-4 groups) and the WHO_AWARE group-set (containing the 3
        AWaRe groups), with membership = the UIDs of the groups in -OptionGroup. The set's display content
        (name/description) AND its UID are canonical in $script:NeoIPCAntibioticGroupSet (source identity — minted
        from the code when blank), so the antibiotic domain is self-contained; the optionSet reference is the
        generated antimicrobial option set's UID (taken from -OptionGroup, not the export). -ExistingPackage is
        OPTIONAL and supplies only each set's deployed dataDimension + sharing by code — never identity. With
        -PoDirectory each set's name/description gets localized translations[]. The group-set codes are fixed
        (ATC5 / WHO_AWARE) — neoipcr filters on them. Returns { optionGroupSets }.
    .PARAMETER OptionGroup
        The fragment from New-NeoIPCAntibioticOptionGroup ({ optionGroups }), supplying the group UIDs to enrol and
        (via any group's optionSet ref) the generated option set's UID.
    .PARAMETER ExistingPackage
        Optional parsed export supplying each group-set's deployed dataDimension + sharing by code (never identity).
    .PARAMETER PoDirectory / .PARAMETER PoBaseName
        Optional bilingual antibiotic catalogues for localized group-set name/description (default base 'antibiotics').
    .OUTPUTS
        [ordered] hashtable with key 'optionGroupSets' (2).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$OptionGroup,
        [System.Collections.IDictionary]$ExistingPackage,
        [string]$PoDirectory,
        [string]$PoBaseName = 'antibiotics'
    )

    # classify generated groups: ATC-4 (5-char ATC code) vs AWaRe (WHO_AWARE_*); the generated antimicrobial option
    # set's UID rides on every group's optionSet ref — use it for the set's optionSet reference (source identity).
    $atcGroupIds = [System.Collections.Generic.List[string]]::new()
    $awGroupIds = [System.Collections.Generic.List[string]]::new()
    $abxOsUid = $null
    foreach ($g in @($OptionGroup['optionGroups'])) {
        $code = [string]$g['code']
        if (-not $abxOsUid -and $g['optionSet'] -is [System.Collections.IDictionary]) { $abxOsUid = [string]$g['optionSet']['id'] }
        if ($code -like 'WHO_AWARE_*') { $awGroupIds.Add([string]$g['id']) }
        elseif (Test-NeoIPCAtcGroupCode $code) { $atcGroupIds.Add([string]$g['id']) }   # ATC-4 (5-char) group level
        else { throw "Option group '$code' is neither an ATC-4 nor an AWaRe group — cannot assign to a group-set." }
    }

    $depSetByCode = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    if ($ExistingPackage) {
        foreach ($gs in @($ExistingPackage['optionGroupSets'])) {
            if ($gs -is [System.Collections.IDictionary] -and $gs['code']) { $depSetByCode[[string]$gs['code']] = $gs }
        }
    }

    $localeMaps = Get-NeoIPCAntibioticLocaleMap -PoDirectory $PoDirectory -PoBaseName $PoBaseName

    $build = {
        param($code, $memberIds)
        if ($memberIds.Count -eq 0) { throw "Option-group-set '$code' has no member groups." }
        $content = $script:NeoIPCAntibioticGroupSet[$code]
        if (-not $content) { throw "No structural content is defined for option-group-set '$code'." }
        $uid = if (Test-NeoIPCMetadataUid -Id $content.Uid) { $content.Uid } else { New-NeoIPCMetadataUid -Type 'optionGroupSets' -NaturalKey $code }
        $fields = Get-NeoIPCAntibioticTranslatableValues -Name $content.Name -Description $content.Description
        $obj = [ordered]@{ id = $uid; code = $code }
        foreach ($p in $fields.Keys) { $obj[$p] = $fields[$p] }
        $dep = $null; [void]$depSetByCode.TryGetValue($code, [ref]$dep)
        if ($dep -and $null -ne $dep['dataDimension']) { $obj['dataDimension'] = [bool]$dep['dataDimension'] }
        if ($abxOsUid) { $obj['optionSet'] = [ordered]@{ id = $abxOsUid } }
        $obj['optionGroups'] = @($memberIds | ForEach-Object { [ordered]@{ id = $_ } })
        if ($dep) { $obj = Add-NeoIPCAntibioticGroupSharing -Group $obj -Deployed $dep }
        $obj = Add-NeoIPCAntibioticTranslations -Object $obj -EnglishValue $fields -LocaleMaps $localeMaps
        $obj
    }

    $sets = [System.Collections.Generic.List[object]]::new()
    $sets.Add((& $build 'ATC5' $atcGroupIds))
    $sets.Add((& $build 'WHO_AWARE' $awGroupIds))
    [ordered]@{ optionGroupSets = $sets.ToArray() }
}

