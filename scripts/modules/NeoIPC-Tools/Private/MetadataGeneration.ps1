# NeoIPC metadata pipeline — ontology-derived generation (private, not exported).
# Helpers that turn the canonical infectious-agent ontology into DHIS2 metadata objects (the generation half
# of the pipeline). The public generators live in Public/Generation.ps1.

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
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()

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
            foreach ($n in 1..3) {
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
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()

    $groups = @(
        @{ Kind = 'primary'; Stages = @('BSI', 'HAP', 'SSI') },
        @{ Kind = 'secondary'; Stages = @('HAP', 'NEC', 'SSI') }
    )
    $cats = @('3GCR', 'carbapenem-resistant', 'colistin-resistant', 'MRSA', 'VRE')

    foreach ($g in $groups) {
        foreach ($stage in $g.Stages) {
            foreach ($n in 1..3) {
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
