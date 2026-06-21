# NeoIPC metadata pipeline — ontology-derived generation (private, not exported).
# Helpers that turn the canonical infectious-agent ontology into DHIS2 metadata objects (the generation half
# of the pipeline). The public generators live in Public/Generation.ps1.

# Slot counts for the repeated clusters — the single knob each that keeps the data elements, program-rule variables
# and rules aligned. Pathogen slots default to 3 (cap 9, single-digit unpadded codes); antimicrobial-substance slots
# default to 9 (cap 99, 2-digit zero-padded). Every plan defaults its count parameter to these and the public
# generators expose -PathogenCount / -SubstanceCount; pass one value to every generator (as the assembler does) so the
# whole machinery expands consistently.
$script:NeoIPCPathogenSlotCount = 3
$script:NeoIPCSubstanceSlotCount = 9

function Get-NeoIPCInfectiousAgentConcept {
    # Depth-first walk of a parsed NeoIPC-Infectious-Agents.yaml tree, yielding every Id-bearing node as
    # [ordered]@{ Id = <int>; Name = <string> }. At each node it emits the node itself, then recurses Hierarchies,
    # then Synonyms, then Children — a synonym is an Id-bearing selectable option, grouped immediately after its
    # concept. powershell-yaml's ConvertFrom-Yaml discards YAML mapping key order, so this fixed visit order (not
    # the file's) is what makes the output deterministic. Fails loud on a malformed Id-bearing node (blank/
    # non-integer Id, or blank Name) — every selectable option needs a unique integer code and a non-empty name.
    # Operates on an in-memory tree (not a path) so it is unit-testable without a file; the public cmdlet loads the YAML.
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][AllowNull()]$Node)

    # Emit each concept to the pipeline (a dictionary is passed as a single object, never enumerated) and let
    # recursion's output flow up; the caller collects with @(...). This avoids the array-nesting traps of mixing
    # unary-comma returns with @(foreach …) flattening — same emit-to-pipeline idiom as Find-NextFreeInfectiousAgentId.
    if ($Node -is [System.Collections.IList]) {
        foreach ($item in $Node) { Get-NeoIPCInfectiousAgentConcept -Node $item }
        return
    }
    if ($Node -is [System.Collections.IDictionary]) {
        if ($Node.Contains('Id')) {
            $name = [string]$Node['Name']
            $idVal = $Node['Id']
            $idInt = 0
            if ($null -eq $idVal -or -not [int]::TryParse([string]$idVal, [ref]$idInt)) {
                throw "Infectious-agent node '$name' has a blank or non-integer Id ('$idVal') — every Id-bearing node needs an integer code."
            }
            if ([string]::IsNullOrWhiteSpace($name)) {
                throw "Infectious-agent node with Id $idInt has a blank Name — every Id-bearing node needs a non-empty name (DHIS2 Option.name is not-null)."
            }
            [ordered]@{ Id = $idInt; Name = $name }
        }
        foreach ($key in 'Hierarchies', 'Synonyms', 'Children') {
            if ($Node.Contains($key)) { Get-NeoIPCInfectiousAgentConcept -Node $Node[$key] }
        }
    }
}

function Get-NeoIPCPathogenDataElementPlan {
    # The capability-matrix expansion: a structural descriptor for every per-slot pathogen data element the
    # NEOIPC_CORE program defines — primary slots (BSI/HAP/SSI x3) and secondary-BSI slots (HAP/NEC/SSI x3).
    # Each slot carries a base organism-selector DE (binds NEOIPC_PATHOGENS) + a _NAME free-text DE + the five
    # resistance DEs (bind NEOIPC_YES_NO_NOT_TESTED); primary BSI/HAP additionally carry _SOURCE (stage-specific
    # option set), and primary BSI alone carries _MULTIPLE (TRUE_ONLY). 135 DEs total. Pure (no package needed),
    # so it is unit-testable and is the single source the generator and its tests both expand from. The rich
    # clinical descriptions are NOT here — they are reused from the export by code by the generator.
    # zeroIsSignificant is false for the INTEGER_POSITIVE _SOURCE DEs (a stored 0 is never a valid source code,
    # so it is not significant) — normalising the deployed BSI-true/HAP-false inconsistency to a single value.
    # PathogenCount sets the number of slots per applicable stage (default = the module-wide count); pass the same
    # value to the PRV and rule plans so the three stay aligned.
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([ValidateRange(1, 9)][int]$PathogenCount = $script:NeoIPCPathogenSlotCount)

    $groups = @(
        @{ Kind = 'primary'; Stages = @('BSI', 'HAP', 'SSI') },
        @{ Kind = 'secondary'; Stages = @('HAP', 'NEC', 'SSI') }
    )
    $suffixes = [ordered]@{
        ''         = @{ ValueType = 'INTEGER_ZERO_OR_POSITIVE'; OptionSetCode = 'NEOIPC_PATHOGENS';         Zero = $true;  NameSuffix = '';                        ShortSuffix = '';           FormSuffix = '' }
        'NAME'     = @{ ValueType = 'TEXT';                      OptionSetCode = $null;                      Zero = $false; NameSuffix = 'name';                    ShortSuffix = 'name';       FormSuffix = 'Name' }
        '3GCR'     = @{ ValueType = 'INTEGER';                   OptionSetCode = 'NEOIPC_YES_NO_NOT_TESTED'; Zero = $true;  NameSuffix = '3GCR';                    ShortSuffix = '3GCR';       FormSuffix = '3GCR' }
        'CAR'      = @{ ValueType = 'INTEGER';                   OptionSetCode = 'NEOIPC_YES_NO_NOT_TESTED'; Zero = $true;  NameSuffix = 'carbapenem-resistant';    ShortSuffix = 'carb.-res.'; FormSuffix = 'Carbapenem-resistant' }
        'COR'      = @{ ValueType = 'INTEGER';                   OptionSetCode = 'NEOIPC_YES_NO_NOT_TESTED'; Zero = $true;  NameSuffix = 'colistin-resistant';      ShortSuffix = 'col.-res.';  FormSuffix = 'Colistin-resistant' }
        'MRSA'     = @{ ValueType = 'INTEGER';                   OptionSetCode = 'NEOIPC_YES_NO_NOT_TESTED'; Zero = $true;  NameSuffix = 'MRSA';                    ShortSuffix = 'MRSA';       FormSuffix = 'MRSA' }
        'VRE'      = @{ ValueType = 'INTEGER';                   OptionSetCode = 'NEOIPC_YES_NO_NOT_TESTED'; Zero = $true;  NameSuffix = 'VRE';                     ShortSuffix = 'VRE';        FormSuffix = 'VRE' }
        'SOURCE'   = @{ ValueType = 'INTEGER_POSITIVE';         OptionSetCode = '<source>';                  Zero = $false; NameSuffix = 'source';                  ShortSuffix = 'source';     FormSuffix = 'Source' }
        'MULTIPLE' = @{ ValueType = 'TRUE_ONLY';                OptionSetCode = $null;                       Zero = $false; NameSuffix = 'recovered multiple times'; ShortSuffix = 'multiple';   FormSuffix = 'recovered multiple times' }
    }
    $sourceSet = @{ BSI = 'NEOIPC_BSI_PATHOGEN_RECOVERED_FROM'; HAP = 'NEOIPC_HAP_RESPIRATORY_TRACT_SAMPLE_SOURCES' }

    foreach ($g in $groups) {
        foreach ($stage in $g.Stages) {
            foreach ($n in 1..$PathogenCount) {
                $isPrimary = $g.Kind -eq 'primary'
                $prefix = if ($isPrimary) { "NEOIPC_${stage}_PATHOGEN_${n}" } else { "NEOIPC_${stage}_SEC_BSI_PATHOGEN_${n}" }
                $nameBase = if ($isPrimary) { "NeoIPC $stage Organism $n" } else { "NeoIPC $stage Secondary BSI organism $n" }
                $shortBase = if ($isPrimary) { "NeoIPC $stage Org. $n" } else { "NeoIPC $stage Sec. BSI org. $n" }
                foreach ($suffix in $suffixes.Keys) {
                    $spec = $suffixes[$suffix]
                    if ($suffix -eq 'SOURCE' -and -not ($isPrimary -and $sourceSet.ContainsKey($stage))) { continue }
                    if ($suffix -eq 'MULTIPLE' -and -not ($isPrimary -and $stage -eq 'BSI')) { continue }
                    $optSet = if ($spec.OptionSetCode -eq '<source>') { $sourceSet[$stage] } else { $spec.OptionSetCode }
                    [ordered]@{
                        Code              = if ($suffix) { "${prefix}_${suffix}" } else { $prefix }
                        Stage             = $stage
                        Kind              = $g.Kind
                        Index             = $n
                        Suffix            = $suffix
                        ValueType         = $spec.ValueType
                        OptionSetCode     = $optSet
                        ZeroIsSignificant = $spec.Zero
                        Name              = if ($spec.NameSuffix) { "$nameBase $($spec.NameSuffix)" } else { $nameBase }
                        ShortName         = if ($spec.ShortSuffix) { "$shortBase $($spec.ShortSuffix)" } else { $shortBase }
                        FormName          = if ($suffix) { "- $($spec.FormSuffix)" } else { "Organism $n" }
                    }
                }
            }
        }
    }
}

function Get-NeoIPCPathogenVariablePlan {
    # The capability-matrix expansion of the resistance-gating PROGRAM-RULE VARIABLES: for each of the 18
    # pathogen slots, one `value` variable (DATAELEMENT_CURRENT_EVENT over the base organism DE, reading the option
    # CODE) plus five `may be <CAT>` calculated booleans the `set <CAT>` rule assigns and the `may be`/`not` rules
    # read. 18 + 90 = 108 descriptors. The slot-specific housekeeping variables (name value, source value, is
    # recognized pathogen, recovered multiple times) are generated with their rules, not here. Pure (no package).
    # Primary slot names use "Pathogen {N}", secondary "Secondary BSI pathogen {N}" — matching the deployed names.
    # PathogenCount sets the number of slots per applicable stage (default = the module-wide count); pass the same
    # value to the DE and rule plans so the three stay aligned.
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([ValidateRange(1, 9)][int]$PathogenCount = $script:NeoIPCPathogenSlotCount)

    $groups = @(
        @{ Kind = 'primary'; Stages = @('BSI', 'HAP', 'SSI') },
        @{ Kind = 'secondary'; Stages = @('HAP', 'NEC', 'SSI') }
    )
    $cats = @('3GCR', 'carbapenem-resistant', 'colistin-resistant', 'MRSA', 'VRE')

    foreach ($g in $groups) {
        foreach ($stage in $g.Stages) {
            foreach ($n in 1..$PathogenCount) {
                $isPrimary = $g.Kind -eq 'primary'
                $baseCode = if ($isPrimary) { "NEOIPC_${stage}_PATHOGEN_${n}" } else { "NEOIPC_${stage}_SEC_BSI_PATHOGEN_${n}" }
                $namePrefix = if ($isPrimary) { "NeoIPC $stage Pathogen $n" } else { "NeoIPC $stage Secondary BSI pathogen $n" }
                [ordered]@{
                    Name                = "$namePrefix value"
                    Kind                = 'value'
                    Stage               = $stage
                    SlotKind            = $g.Kind
                    Index               = $n
                    SourceType          = 'DATAELEMENT_CURRENT_EVENT'
                    ValueType           = 'INTEGER_ZERO_OR_POSITIVE'
                    UseCodeForOptionSet = $true
                    DataElementCode     = $baseCode
                }
                foreach ($cat in $cats) {
                    [ordered]@{
                        Name                = "$namePrefix may be $cat"
                        Kind                = 'mayBe'
                        Category            = $cat
                        Stage               = $stage
                        SlotKind            = $g.Kind
                        Index               = $n
                        SourceType          = 'CALCULATED_VALUE'
                        ValueType           = 'BOOLEAN'
                        UseCodeForOptionSet = $false
                        DataElementCode     = $null
                    }
                }
            }
        }
    }
}

# The YAML resistance-flag key -> the DHIS2 resistance category key used by the data elements, program-rule
# variables and rules (`may be <CAT>` / the `_<CAT>` DE suffix). Single source for the mapping so the flag
# walker, the code-set aggregator and the rule generator stay aligned.
$script:NeoIPCResistanceCategoryByFlag = [ordered]@{
    '3GCR'        = '3GCR'
    'Carbapenems' = 'carbapenem-resistant'
    'Colistin'    = 'colistin-resistant'
    'MRSA'        = 'MRSA'
    'VRE'         = 'VRE'
}

function Get-NeoIPCResistanceFlag {
    # Depth-first walk of a parsed NeoIPC-Infectious-Agents.yaml tree, yielding the EFFECTIVE resistance flags of
    # every Id-bearing node as [ordered]@{ Id = <int>; '3GCR' = <bool>; 'carbapenem-resistant' = <bool>; ... }.
    # The effective flag is the nearest explicit value on the node->root path: the node's own flag if it carries
    # one, else the value inherited from its closest ancestor that does; an explicit `false` overrides an inherited
    # `true`; absence everywhere defaults to false. Inheritance flows DOWN through Hierarchies/Synonyms/Children
    # (verified: Children descends the taxonomy and Synonyms nest under their concept, so a synonym inherits its
    # concept's flags) — the same traversal as Get-NeoIPCInfectiousAgentConcept, threading the inherited flag map.
    # Pipeline-emit idiom (no accumulator), so the caller collects with @(...). Operates on an in-memory tree (not a
    # path) so it is unit-testable. Fails loud on a non-boolean flag value or a non-integer Id (module convention).
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][AllowNull()]$Node,
        [System.Collections.IDictionary]$Inherited
    )

    if (-not $Inherited) {
        $Inherited = [ordered]@{}
        foreach ($cat in $script:NeoIPCResistanceCategoryByFlag.Values) { $Inherited[$cat] = $false }
    }

    if ($Node -is [System.Collections.IList]) {
        foreach ($item in $Node) { Get-NeoIPCResistanceFlag -Node $item -Inherited $Inherited }
        return
    }
    if ($Node -isnot [System.Collections.IDictionary]) { return }

    # Effective flags at this node = own explicit value (honouring an explicit false) else inherited.
    $effective = [ordered]@{}
    foreach ($flag in $script:NeoIPCResistanceCategoryByFlag.Keys) {
        $cat = $script:NeoIPCResistanceCategoryByFlag[$flag]
        if ($Node.Contains($flag)) {
            $v = $Node[$flag]
            if ($v -isnot [bool]) {
                $parsed = $false
                if (-not [bool]::TryParse([string]$v, [ref]$parsed)) {
                    throw "Infectious-agent node '$($Node['Name'])' has a non-boolean '$flag' value ('$v') — resistance flags must be true/false."
                }
                $v = $parsed
            }
            $effective[$cat] = $v
        }
        else {
            $effective[$cat] = $Inherited[$cat]
        }
    }

    if ($Node.Contains('Id')) {
        $idInt = 0
        if (-not [int]::TryParse([string]$Node['Id'], [ref]$idInt)) {
            throw "Infectious-agent node '$($Node['Name'])' has a non-integer Id ('$($Node['Id'])')."
        }
        $row = [ordered]@{ Id = $idInt }
        foreach ($cat in $script:NeoIPCResistanceCategoryByFlag.Values) { $row[$cat] = $effective[$cat] }
        $row
    }

    foreach ($key in 'Hierarchies', 'Synonyms', 'Children') {
        if ($Node.Contains($key)) { Get-NeoIPCResistanceFlag -Node $Node[$key] -Inherited $effective }
    }
}

function Get-NeoIPCResistanceCodeSet {
    # Aggregate Get-NeoIPCResistanceFlag into the per-category organism code sets the `set <CAT>` ASSIGN rules
    # enumerate: [ordered]@{ '3GCR' = @(<int Ids ascending>); 'carbapenem-resistant' = @(...); ... } with one
    # entry per resistance category. A code (= a node's Id) is in a category's set iff that node's EFFECTIVE flag
    # for the category is true. Ids are emitted in ascending numeric order so the generated expressions — and the
    # diff against the deployed rules — are stable. Pure (no package); the single source the rule generator and its
    # tests both expand from.
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][AllowNull()]$Node)

    $sets = [ordered]@{}
    foreach ($cat in $script:NeoIPCResistanceCategoryByFlag.Values) {
        $sets[$cat] = [System.Collections.Generic.List[int]]::new()
    }
    foreach ($row in @(Get-NeoIPCResistanceFlag -Node $Node)) {
        foreach ($cat in $script:NeoIPCResistanceCategoryByFlag.Values) {
            if ($row[$cat]) { $sets[$cat].Add([int]$row['Id']) }
        }
    }

    $out = [ordered]@{}
    foreach ($cat in $script:NeoIPCResistanceCategoryByFlag.Values) {
        $out[$cat] = @($sets[$cat] | Sort-Object)
    }
    $out
}

# The resistance category key -> the `_<CAT>` data-element code suffix (the short form the DE codes use; the long
# form is the rule/variable-name token). Aligned with the Get-NeoIPCPathogenDataElementPlan suffixes.
$script:NeoIPCResistanceDeSuffixByCategory = [ordered]@{
    '3GCR'                 = '3GCR'
    'carbapenem-resistant' = 'CAR'
    'colistin-resistant'   = 'COR'
    'MRSA'                 = 'MRSA'
    'VRE'                  = 'VRE'
}

function Get-NeoIPCPathogenRulePlan {
    # The capability-matrix expansion of the resistance-gating PROGRAM RULES: for each of the 18 pathogen slots and
    # each of the 5 resistance categories, the deployed three-rule producer/consumer triple —
    #   set   : condition `true`, priority 0, ASSIGN `#{<slot> may be <CAT>}` = the enumerated effective code set;
    #   mayBe : condition `#{<slot> may be <CAT>}`, priority 1, SETMANDATORYFIELD on the `_<CAT>` resistance DE;
    #   not   : condition `!#{<slot> may be <CAT>}`, priority 1, HIDEFIELD on the `_<CAT>` resistance DE.
    # 18 x 5 x 3 = 270 descriptors. The priority-0-before-1 split is load-bearing: the `set` ASSIGN must run before
    # the `may be`/`not` consumers read the variable it assigns (program rules evaluate in one ordered pass, priority
    # ascending). The `not` condition is the exact complement of `may be` so a field is never hidden-and-mandatory.
    # Pure (no package, no YAML): the per-category code-set enumeration is resolved later by the generator from
    # Get-NeoIPCResistanceCodeSet — this plan carries only the structure. Slot naming matches the DE/PRV plans.
    # PathogenCount sets the number of slots per applicable stage (default = the module-wide count); pass the same
    # value to the DE and PRV plans so the three stay aligned.
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([ValidateRange(1, 9)][int]$PathogenCount = $script:NeoIPCPathogenSlotCount)

    $groups = @(
        @{ Kind = 'primary'; Stages = @('BSI', 'HAP', 'SSI') },
        @{ Kind = 'secondary'; Stages = @('HAP', 'NEC', 'SSI') }
    )
    $cats = @($script:NeoIPCResistanceDeSuffixByCategory.Keys)

    foreach ($g in $groups) {
        foreach ($stage in $g.Stages) {
            foreach ($n in 1..$PathogenCount) {
                $isPrimary = $g.Kind -eq 'primary'
                $baseCode = if ($isPrimary) { "NEOIPC_${stage}_PATHOGEN_${n}" } else { "NEOIPC_${stage}_SEC_BSI_PATHOGEN_${n}" }
                $varPrefix = if ($isPrimary) { "NeoIPC $stage Pathogen $n" } else { "NeoIPC $stage Secondary BSI pathogen $n" }
                $slotPhrase = if ($isPrimary) { "pathogen $n" } else { "secondary BSI pathogen $n" }
                $valueVar = "$varPrefix value"
                foreach ($cat in $cats) {
                    $mayBeVar = "$varPrefix may be $cat"
                    $catDeCode = "${baseCode}_$($script:NeoIPCResistanceDeSuffixByCategory[$cat])"
                    [ordered]@{
                        Kind           = 'set'
                        Stage          = $stage
                        SlotKind       = $g.Kind
                        Index          = $n
                        Category       = $cat
                        Name           = "$varPrefix - set $cat"
                        Description    = "Sets the `"may be $cat`" variable for pathogens that could be $cat."
                        Condition      = 'true'
                        Priority       = 0
                        ActionType     = 'ASSIGN'
                        ValueVariable  = $valueVar
                        MayBeVariable  = $mayBeVar
                        CategoryDeCode = $null
                    }
                    [ordered]@{
                        Kind           = 'mayBe'
                        Stage          = $stage
                        SlotKind       = $g.Kind
                        Index          = $n
                        Category       = $cat
                        Name           = "$varPrefix - may be $cat"
                        Description    = "Makes the $cat field for $slotPhrase mandatory if it is relevant for the selected pathogen."
                        Condition      = "#{$mayBeVar}"
                        Priority       = 1
                        ActionType     = 'SETMANDATORYFIELD'
                        ValueVariable  = $valueVar
                        MayBeVariable  = $mayBeVar
                        CategoryDeCode = $catDeCode
                    }
                    [ordered]@{
                        Kind           = 'not'
                        Stage          = $stage
                        SlotKind       = $g.Kind
                        Index          = $n
                        Category       = $cat
                        Name           = "$varPrefix - not $cat"
                        Description    = "Hides the $cat field for $slotPhrase if it is not relevant for the selected pathogen."
                        Condition      = "!#{$mayBeVar}"
                        Priority       = 1
                        ActionType     = 'HIDEFIELD'
                        ValueVariable  = $valueVar
                        MayBeVariable  = $mayBeVar
                        CategoryDeCode = $catDeCode
                    }
                }
            }
        }
    }
}

function ConvertTo-NeoIPCSubstanceUnpaddedName {
    # Strip the leading zero from the slot number in a substance object name, so a deployed *unpadded* name
    # (`… Antibiotic substance 2 …`) and the generated *padded* name (`… Antibiotic substance 02 …`) compare equal.
    # Used for padding-insensitive UID preservation: the substance generators look up the deployed UID by this
    # normalised key, so padding the names is an in-place rename rather than orphan-and-recreate. Names with no slot
    # number (`… substance days - validate`) are returned unchanged.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name)
    $Name -replace 'substance 0*(\d+)', 'substance $1'
}

function Get-NeoIPCStageByDataElementId {
    # Build a data-element-id -> program-stage-id map from a package's programStages[].programStageDataElements.
    # The deployed program stages carry NO `code` (their codes belong to other objects), so a rule's program stage is
    # resolved by which stage owns a known data element on it (a slot-1 resistance DE, or the AB-days DE) rather than
    # by a stage code. First-wins per DE id (a DE belongs to one stage).
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Package)

    $map = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    foreach ($ps in @($Package['programStages'])) {
        if ($ps -isnot [System.Collections.IDictionary]) { continue }
        $sid = [string]$ps['id']
        foreach ($psde in @($ps['programStageDataElements'])) {
            if ($psde -is [System.Collections.IDictionary] -and $psde['dataElement'] -is [System.Collections.IDictionary]) {
                $deId = [string]$psde['dataElement']['id']
                if ($deId -and -not $map.ContainsKey($deId)) { $map[$deId] = $sid }
            }
        }
    }
    $map
}

function Get-NeoIPCSubstanceDataElementPlan {
    # The antimicrobial-substance per-slot DATA ELEMENTS on the surveillance-end stage: for each of SubstanceCount
    # slots, a substance DE (TEXT, optionSet AND commentOptionSet NEOIPC_ANTIMICROBIAL_SUBSTANCES) and a days DE
    # (INTEGER_POSITIVE). The slot number is 2-digit zero-padded in the code / name / shortName but NOT the formName
    # (the data-entry UI label, which has no ordering role). Pure (no package): 2 x SubstanceCount descriptors.
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([ValidateRange(1, 99)][int]$SubstanceCount = $script:NeoIPCSubstanceSlotCount)

    foreach ($n in 1..$SubstanceCount) {
        $nn = '{0:D2}' -f $n
        [ordered]@{
            Code                 = "NEOIPC_SURVEILLANCE_END_AB_SUBST_$nn"
            Index                = $n
            Kind                 = 'substance'
            ValueType            = 'TEXT'
            OptionSetCode        = 'NEOIPC_ANTIMICROBIAL_SUBSTANCES'
            CommentOptionSetCode = 'NEOIPC_ANTIMICROBIAL_SUBSTANCES'
            AggregationType      = 'NONE'
            ZeroIsSignificant    = $false
            Name                 = "NeoIPC Surveillance end Antibiotic substance $nn"
            ShortName            = "NeoIPC Surv. end AB $nn"
            FormName             = "Antibiotic substance $n"
        }
        [ordered]@{
            Code                 = "NEOIPC_SURVEILLANCE_END_AB_SUBST_${nn}_DAYS"
            Index                = $n
            Kind                 = 'days'
            ValueType            = 'INTEGER_POSITIVE'
            OptionSetCode        = $null
            CommentOptionSetCode = $null
            AggregationType      = 'DEFAULT'
            ZeroIsSignificant    = $true
            Name                 = "NeoIPC Surveillance end Antibiotic substance $nn days"
            ShortName            = "NeoIPC Surv. end AB $nn days"
            FormName             = "Antibiotic substance $n days"
        }
    }
}

function Get-NeoIPCSubstanceVariablePlan {
    # The substance per-slot PROGRAM-RULE VARIABLES: for each slot, a substance value PRV (TEXT, useCodeForOptionSet
    # true) and a days value PRV (INTEGER_POSITIVE, useCodeForOptionSet false), both DATAELEMENT_CURRENT_EVENT. Names
    # are 2-digit padded. The total `NeoIPC Surveillance end AB days - current event value` PRV is referenced by the
    # rules, not generated here. Pure (no package): 2 x SubstanceCount descriptors.
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([ValidateRange(1, 99)][int]$SubstanceCount = $script:NeoIPCSubstanceSlotCount)

    foreach ($n in 1..$SubstanceCount) {
        $nn = '{0:D2}' -f $n
        [ordered]@{
            Name                = "NeoIPC Surveillance end Antibiotic substance $nn - current event value"
            Index               = $n
            Kind                = 'substance'
            SourceType          = 'DATAELEMENT_CURRENT_EVENT'
            ValueType           = 'TEXT'
            UseCodeForOptionSet = $true
            DataElementCode     = "NEOIPC_SURVEILLANCE_END_AB_SUBST_$nn"
        }
        [ordered]@{
            Name                = "NeoIPC Surveillance end Antibiotic substance $nn days - current event value"
            Index               = $n
            Kind                = 'days'
            SourceType          = 'DATAELEMENT_CURRENT_EVENT'
            ValueType           = 'INTEGER_POSITIVE'
            UseCodeForOptionSet = $false
            DataElementCode     = "NEOIPC_SURVEILLANCE_END_AB_SUBST_${nn}_DAYS"
        }
    }
}

function Get-NeoIPCSubstanceRulePlan {
    # The substance cascading-reveal / require / validate RULES on the surveillance-end stage. Per slot: a `hide` rule
    # (two HIDEFIELD, on the substance and days DE; slot 1 gated on total AB days <= 0, slot N>=2 on the previous slot
    # having no value) and a `days - require` (SETMANDATORYFIELD on the days DE when the substance has a value); slot 1
    # additionally a `substance - require` (SETMANDATORYFIELD on the substance DE when total AB days >= 1); plus one
    # cross-slot `validate` rule (SHOWERROR when the substance-days sum is below total AB days). Names 2-digit padded;
    # rules read the `… - current event value` PRVs directly (no ASSIGN indirection). Pure: 2*SubstanceCount + 2 rules.
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([ValidateRange(1, 99)][int]$SubstanceCount = $script:NeoIPCSubstanceSlotCount)

    $base = 'NeoIPC Surveillance end Antibiotic substance'
    $abDaysVar = 'NeoIPC Surveillance end AB days - current event value'

    foreach ($n in 1..$SubstanceCount) {
        $nn = '{0:D2}' -f $n
        $substanceVar = "$base $nn - current event value"
        $substanceCode = "NEOIPC_SURVEILLANCE_END_AB_SUBST_$nn"
        $daysCode = "NEOIPC_SURVEILLANCE_END_AB_SUBST_${nn}_DAYS"

        $hideCond = if ($n -eq 1) { "#{$abDaysVar} <= 0" }
        else { "!d2:hasValue(#{$base $('{0:D2}' -f ($n - 1)) - current event value})" }
        [ordered]@{
            Name      = "$base $nn - hide"
            Kind      = 'hide'
            Index     = $n
            Condition = $hideCond
            Priority  = $null
            Actions   = @(
                [ordered]@{ Type = 'HIDEFIELD'; DataElementCode = $substanceCode },
                [ordered]@{ Type = 'HIDEFIELD'; DataElementCode = $daysCode }
            )
        }
        [ordered]@{
            Name      = "$base $nn days - require"
            Kind      = 'daysRequire'
            Index     = $n
            Condition = "d2:hasValue(#{$substanceVar})"
            Priority  = $null
            Actions   = @([ordered]@{ Type = 'SETMANDATORYFIELD'; DataElementCode = $daysCode })
        }
        if ($n -eq 1) {
            [ordered]@{
                Name      = "$base $nn - require"
                Kind      = 'substanceRequire'
                Index     = $n
                Condition = "#{$abDaysVar} >= 1"
                Priority  = $null
                Actions   = @([ordered]@{ Type = 'SETMANDATORYFIELD'; DataElementCode = $substanceCode })
            }
        }
    }

    $daysSum = @(1..$SubstanceCount | ForEach-Object { "#{$base $('{0:D2}' -f $_) days - current event value}" }) -join ' + '
    [ordered]@{
        Name      = "$base days - validate"
        Kind      = 'validate'
        Index     = 0
        Condition = "($daysSum) < #{$abDaysVar}"
        Priority  = 1
        Actions   = @([ordered]@{
                Type            = 'SHOWERROR'
                DataElementCode = 'NEOIPC_SURVEILLANCE_END_AB_DAYS'
                Content         = 'The sum of all antibiotic substance days must be greater than or equal to antibiotic days'
            })
    }
}
