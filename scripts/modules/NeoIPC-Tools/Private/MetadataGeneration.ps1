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

# The NEOIPC_PATHOGENS option set's own UID — a fixed-code singleton (the code is a contract), captured once from the
# deployment. The per-option UIDs live in the Id->uid sidecar beside the ontology YAML (Get-NeoIPCPathogenUidMap),
# so pathogen option identity comes from SOURCE, not the export. See the infectious-agents README for re-capture.
$script:NeoIPCPathogenOptionSetUid = 'KHMPRkX5a4r'

function Get-NeoIPCPathogenUidMap {
    # Read the pathogen Id->uid sidecar (NeoIPC-Infectious-Agents.uids.csv: columns id,uid) into a case-sensitive
    # code(string)->uid map. The sidecar records the DEPLOYED option UIDs; a not-yet-deployed ontology Id is simply
    # absent, and New-NeoIPCPathogenOptionSet then mints it deterministically. Returns an empty map when the file is
    # absent (every option mints). Fails loud on a blank or duplicate id (the map key must be a unique option code).
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param([Parameter(Mandatory)][string]$Path)
    $map = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
    if (-not (Test-Path -LiteralPath $Path)) { return $map }
    foreach ($r in @(Import-Csv -LiteralPath $Path -Encoding utf8NoBOM)) {
        $id = [string]$r.id
        if ([string]::IsNullOrWhiteSpace($id)) { throw "Pathogen UID sidecar '$Path' has a row with a blank id." }
        if ($map.ContainsKey($id)) { throw "Duplicate id '$id' in the pathogen UID sidecar '$Path' — option codes must be unique." }
        $map[$id] = [string]$r.uid
    }
    $map
}

function Get-NeoIPCInfectiousAgentConcept {
    # Depth-first walk of a parsed NeoIPC-Infectious-Agents.yaml tree, yielding every Id-bearing node as
    # [ordered]@{ Id = <int>; Name = <string>; ConceptType = <string|null>; IsSynonym = <bool> }. At each node it
    # emits the node itself, then recurses Hierarchies, then Synonyms, then Children — a synonym is an Id-bearing
    # selectable option, grouped immediately after its concept. ConceptType is the node's taxonomic rank (Species,
    # Genus, Family, …; null when absent); IsSynonym marks nodes reached through a Synonyms list. Both feed the
    # DHIS2 option label's bracketed rank/synonym tag (Get-NeoIPCPathogenOptionLabel) — Name itself stays the raw
    # ontology name. powershell-yaml's ConvertFrom-Yaml discards YAML mapping key order, so this fixed visit order
    # (not the file's) is what makes the output deterministic. Fails loud on a malformed Id-bearing node (blank/
    # non-integer Id, or blank Name) — every selectable option needs a unique integer code and a non-empty name.
    # Operates on an in-memory tree (not a path) so it is unit-testable without a file; the public cmdlet loads the YAML.
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][AllowNull()]$Node,
        # True when $Node is reached through a Synonyms list. A synonym's own Children are concepts, not synonyms
        # (e.g. whole-branch virus moves), so the flag does not propagate — each child key is recursed with its own.
        [bool]$IsSynonym = $false
    )

    # Emit each concept to the pipeline (a dictionary is passed as a single object, never enumerated) and let
    # recursion's output flow up; the caller collects with @(...). This avoids the array-nesting traps of mixing
    # unary-comma returns with @(foreach …) flattening — same emit-to-pipeline idiom as Find-NextFreeInfectiousAgentId.
    if ($Node -is [System.Collections.IList]) {
        foreach ($item in $Node) { Get-NeoIPCInfectiousAgentConcept -Node $item -IsSynonym $IsSynonym }
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
            [ordered]@{
                Id          = $idInt
                Name        = $name
                ConceptType = if ($Node.Contains('ConceptType')) { [string]$Node['ConceptType'] } else { $null }
                IsSynonym   = $IsSynonym
            }
        }
        if ($Node.Contains('Hierarchies')) { Get-NeoIPCInfectiousAgentConcept -Node $Node['Hierarchies'] -IsSynonym $false }
        if ($Node.Contains('Synonyms')) { Get-NeoIPCInfectiousAgentConcept -Node $Node['Synonyms'] -IsSynonym $true }
        if ($Node.Contains('Children')) { Get-NeoIPCInfectiousAgentConcept -Node $Node['Children'] -IsSynonym $false }
    }
}

function Get-NeoIPCPathogenOptionLabel {
    # Assemble a NEOIPC_PATHOGENS option label from an ontology node, reproducing the deployed naming convention:
    # a synonym-list member is tagged "<Name> [synonym]"; any other node is tagged with its lowercased taxonomic
    # rank ("<Name> [species]", "<Name> [genus]", …); a node whose rank is Unknown or absent (the "Not listed" /
    # "Unidentifiable" specials) carries no tag. Lowercasing matches the deployed English labels (the YAML rank is
    # title-case).
    #
    # Without -Translation this is the English label, assembled from the canonical ontology. With -Translation (a
    # case-sensitive english->localized map from a locale's .po, via Get-NeoIPCPoTranslationMap) it is the localized
    # label: the Name and the rank word are each replaced by their translation where one exists, and the synonym
    # word by the translated "synonym" ListTerm. The translated rank/synonym word is used VERBATIM (German ranks are
    # capitalised nouns — "Art", "Gattung"); only the English fallback is lowercased. A string absent from the map
    # falls back to its English form, so an untranslated locale yields the English label unchanged.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][string]$ConceptType,
        [bool]$IsSynonym,
        [System.Collections.IDictionary]$Translation
    )
    $name = if ($Translation -and $Translation.Contains($Name)) { [string]$Translation[$Name] } else { $Name }
    $tag = if ($IsSynonym) {
        if ($Translation -and $Translation.Contains('synonym')) { [string]$Translation['synonym'] } else { 'synonym' }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($ConceptType) -and $ConceptType -ne 'Unknown') {
        if ($Translation -and $Translation.Contains($ConceptType)) { [string]$Translation[$ConceptType] } else { $ConceptType.ToLowerInvariant() }
    }
    else { $null }
    if ($tag) { '{0} [{1}]' -f $name, $tag } else { $name }
}

function Get-NeoIPCPoTranslationMap {
    # Build a flat english(msgid) -> localized(msgstr) map from a po4a-generated YAML .po (bare msgid/msgstr, no
    # msgctxt — so Read-NeoIPCMetadataPoText, which requires a msgctxt, does not apply). Skips the header (empty
    # msgid), obsolete "#~" entries, FUZZY entries (an unconfirmed msgmerge guess — gettext/po4a ignore them too;
    # e.g. a new "synonym" msgid fuzzy-matched onto the "synonym for {0}" translation), and any msgstr that is empty
    # or identical to its msgid (no real translation). The map is case-sensitive (Ordinal) — rank words and organism
    # names are case-significant. Returns an empty map if the file is absent. Identical msgids are merged by gettext,
    # so a flat map is unambiguous.
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param([Parameter(Mandatory)][string]$Path)

    $map = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
    if (-not (Test-Path -LiteralPath $Path)) { return $map }

    # Peel exactly one surrounding quote per side (NOT Trim('"'), which would over-strip a value ending in an
    # escaped quote) and unescape via the module's PO unescaper.
    $unq = {
        param($s)
        if ($s.StartsWith('"') -and $s.EndsWith('"') -and $s.Length -ge 2) { ConvertFrom-NeoIPCPoString $s.Substring(1, $s.Length - 2) } else { '' }
    }
    $id = $null; $str = $null; $field = $null; $obsolete = $false; $fuzzy = $false
    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($raw in ((Get-Content -LiteralPath $Path -Raw) -split "`n")) {
        $line = $raw.TrimEnd("`r"); $trim = $line.Trim()
        if ($trim -eq '') {
            if ($null -ne $id -and -not $obsolete -and -not $fuzzy) { $entries.Add([pscustomobject]@{ Id = $id; Str = [string]$str }) }
            $id = $null; $str = $null; $field = $null; $obsolete = $false; $fuzzy = $false; continue
        }
        if ($trim.StartsWith('#~')) { $obsolete = $true; $field = $null; continue }
        if ($trim.StartsWith('#')) {
            if ($trim.StartsWith('#,') -and $trim -match '\bfuzzy\b') { $fuzzy = $true }
            $field = $null; continue
        }
        if ($trim.StartsWith('msgid ')) { $id = & $unq ($trim.Substring(6).Trim()); $field = 'id'; continue }
        if ($trim.StartsWith('msgstr ')) { $str = & $unq ($trim.Substring(7).Trim()); $field = 'str'; continue }
        if ($trim.StartsWith('"') -and $trim.EndsWith('"') -and $field) {
            $piece = & $unq $trim
            if ($field -eq 'id') { $id = [string]$id + $piece } else { $str = [string]$str + $piece }
        }
    }
    if ($null -ne $id -and -not $obsolete -and -not $fuzzy) { $entries.Add([pscustomobject]@{ Id = $id; Str = [string]$str }) }

    foreach ($e in $entries) {
        if ([string]::IsNullOrEmpty($e.Id)) { continue }                 # header
        if ([string]::IsNullOrEmpty($e.Str) -or $e.Str -ceq $e.Id) { continue }  # untranslated / unchanged
        if (-not $map.Contains($e.Id)) { $map[$e.Id] = $e.Str }
    }
    $map
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

function Get-NeoIPCPathogenSlotBaseCode {
    # The data-element code prefix shared by a pathogen slot's fields: NEOIPC_<STAGE>_PATHOGEN_<N> for a primary
    # slot, NEOIPC_<STAGE>_SEC_BSI_PATHOGEN_<N> for a secondary-BSI slot. The slot plans inline this prefix literally;
    # this names it once for the translation-key index to reuse, rather than re-inlining the same expression there.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)][string]$SlotKind,
        [Parameter(Mandatory)][int]$Index
    )
    if ($SlotKind -eq 'primary') { "NEOIPC_${Stage}_PATHOGEN_${Index}" } else { "NEOIPC_${Stage}_SEC_BSI_PATHOGEN_${Index}" }
}

function Get-NeoIPCPathogenVariablePlan {
    # The capability-matrix expansion of the resistance-gating PROGRAM-RULE VARIABLES: for each of the 18
    # pathogen slots, one `value` variable (DATAELEMENT_CURRENT_EVENT over the base organism DE, reading the option
    # CODE) plus five `may be <CAT>` calculated booleans the `set <CAT>` rule assigns and the `may be`/`not` rules
    # read. 18 + 90 = 108 descriptors. The slot-specific field-gating variables (name value, source value, is
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

function Get-NeoIPCCommonCommensalFlag {
    # Depth-first walk of a parsed NeoIPC-Infectious-Agents.yaml tree, yielding the EFFECTIVE CommonCommensal flag of
    # every Id-bearing node as [ordered]@{ Id = <int>; CommonCommensal = <bool> }. The effective flag is the nearest
    # explicit value on the node->root path (own value if present, else the closest ancestor that carries one); an
    # explicit `false` overrides an inherited `true`; absence everywhere defaults to false — the same own-or-inherited
    # model as Get-NeoIPCResistanceFlag, flowing DOWN through Hierarchies/Synonyms/Children. The NHSN Organism List is
    # the authority for the classification (see the repo CLAUDE.md). Pipeline-emit idiom (no accumulator); operates on
    # an in-memory tree so it is unit-testable. Fails loud on a non-boolean flag value or a non-integer Id.
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][AllowNull()]$Node,
        [bool]$Inherited = $false
    )

    if ($Node -is [System.Collections.IList]) {
        foreach ($item in $Node) { Get-NeoIPCCommonCommensalFlag -Node $item -Inherited $Inherited }
        return
    }
    if ($Node -isnot [System.Collections.IDictionary]) { return }

    $effective = $Inherited
    if ($Node.Contains('CommonCommensal')) {
        $v = $Node['CommonCommensal']
        if ($v -isnot [bool]) {
            $parsed = $false
            if (-not [bool]::TryParse([string]$v, [ref]$parsed)) {
                throw "Infectious-agent node '$($Node['Name'])' has a non-boolean 'CommonCommensal' value ('$v') — the flag must be true/false."
            }
            $v = $parsed
        }
        $effective = $v
    }

    if ($Node.Contains('Id')) {
        $idInt = 0
        if (-not [int]::TryParse([string]$Node['Id'], [ref]$idInt)) {
            throw "Infectious-agent node '$($Node['Name'])' has a non-integer Id ('$($Node['Id'])')."
        }
        [ordered]@{ Id = $idInt; CommonCommensal = $effective }
    }

    foreach ($key in 'Hierarchies', 'Synonyms', 'Children') {
        if ($Node.Contains($key)) { Get-NeoIPCCommonCommensalFlag -Node $Node[$key] -Inherited $effective }
    }
}

function Get-NeoIPCCommonCommensalCodeSet {
    # The ascending set of organism Ids whose EFFECTIVE CommonCommensal flag is true — the set the BSI
    # `set recognized pathogen` rules NEGATE (a pathogen is "recognized" iff its slot has a value and is NOT a common
    # commensal). Aggregates Get-NeoIPCCommonCommensalFlag; Ids ascending so the generated ASSIGN expression — and the
    # diff against the deployed rule — is stable. Pure (no package); the single source the recognized-pathogen rule
    # generator and its tests both expand from.
    [CmdletBinding()]
    [OutputType([int[]])]
    param([Parameter(Mandatory)][AllowNull()]$Node)

    $ids = [System.Collections.Generic.List[int]]::new()
    foreach ($row in @(Get-NeoIPCCommonCommensalFlag -Node $Node)) {
        if ($row['CommonCommensal']) { $ids.Add([int]$row['Id']) }
    }
    @($ids | Sort-Object)
}

function Get-NeoIPCPathogenSlotSuffix {
    # The ordered dependent-field suffixes of a pathogen slot on a given stage/kind, per the capability matrix: ''
    # (the organism-selector value DE), then 'NAME', the five resistance suffixes, and — primary slots only — the
    # stage-specific extras 'SOURCE' (BSI/HAP) and 'MULTIPLE' (BSI). The single source shared by the field-gating rule
    # plan's downstream-hide field set and own-extras, aligned with Get-NeoIPCPathogenDataElementPlan's suffixes.
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)][bool]$IsPrimary
    )
    $suffixes = [System.Collections.Generic.List[string]]::new()
    $suffixes.AddRange([string[]]@('', 'NAME', '3GCR', 'CAR', 'COR', 'MRSA', 'VRE'))
    if ($IsPrimary -and $Stage -in @('BSI', 'HAP')) { [void]$suffixes.Add('SOURCE') }
    if ($IsPrimary -and $Stage -eq 'BSI') { [void]$suffixes.Add('MULTIPLE') }
    $suffixes.ToArray()
}

function Get-NeoIPCPathogenFieldGatingVariablePlan {
    # The slot-specific field-gating PROGRAM-RULE VARIABLES the field-gating rules require — the `is recognized
    # pathogen` CALCULATED_VALUE boolean the BSI `set recognized pathogen` ASSIGN writes (and downstream BSI-definition
    # rules read). BSI primary slots only, mirroring the rule coverage. Kept out of Get-NeoIPCPathogenVariablePlan (the
    # resistance PRVs) because it is generated together with its rules. Pure (no package): PathogenCount descriptors.
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([ValidateRange(1, 9)][int]$PathogenCount = $script:NeoIPCPathogenSlotCount)

    foreach ($n in 1..$PathogenCount) {
        [ordered]@{
            Name                = "NeoIPC BSI Pathogen $n is recognized pathogen"
            Kind                = 'isRecognizedPathogen'
            Stage               = 'BSI'
            SlotKind            = 'primary'
            Index               = $n
            SourceType          = 'CALCULATED_VALUE'
            ValueType           = 'BOOLEAN'
            UseCodeForOptionSet = $false
            DataElementCode     = $null
        }
    }
}

function Get-NeoIPCPathogenFieldGatingRulePlan {
    # The per-slot field-gating PROGRAM RULES — the non-resistance gating on each pathogen slot — expanded from the
    # capability matrix for PathogenCount slots per group (primary BSI/HAP/SSI, secondary-BSI HAP/NEC/SSI). Five kinds,
    # all deployed-verified, each carrying an Actions array (resolved to UIDs by the generator, like the substance rules):
    #   recognizedPathogen (BSI primary only): cond `true`, priority 0, one ASSIGN that sets the slot's
    #       `is recognized pathogen` boolean to "the slot has a value and is NOT a common commensal" — the common-
    #       commensal code set NEGATED (resolved by the generator from Get-NeoIPCCommonCommensalCodeSet). Carries
    #       UsesCommonCommensalSet so the generator knows to expand the code set into the ASSIGN `data`.
    #   whenSet (BSI primary only): cond `d2:hasValue(#{<slot> value})`, one SETMANDATORYFIELD on the slot's `_SOURCE`
    #       DE. (The deployed slot-1 also hid NEOIPC_BSI_NO_POS_CULTURE — a BSI-definition business rule left to the
    #       business-rule layer, not part of this repeated cluster.)
    #   whenEmpty (slots with downstream slots and/or own SOURCE/MULTIPLE): cond `!d2:hasValue(#{<slot> value})`, a
    #       HIDEFIELD per own SOURCE/MULTIPLE extra + per field of every downstream slot in the group (value, name and
    #       the five resistance fields). This is the progressive reveal: a downstream slot's own SOURCE/MULTIPLE are
    #       hidden by THAT slot's own whenEmpty (it is empty whenever an upstream slot is), so they are not repeated
    #       here — the uniform model that reproduces the clean BSI rules and normalises the HAP/SSI inconsistencies.
    #   whenEmptyOrListed (all slots): cond `!d2:hasValue(#{<slot> value}) || #{<slot> value} != 0`, HIDEFIELD on the
    #       `_NAME` free-text DE (hide it unless code 0 = "Not listed" is selected).
    #   whenNotListed (all slots): cond `d2:hasValue(#{<slot> value}) && #{<slot> value} == 0`, SETMANDATORYFIELD on
    #       `_NAME` (require the free-text name when "Not listed").
    # Uniform explicit priorities (recognizedPathogen 0 so its ASSIGN runs before consumers; the rest 1) — normalising
    # the deployed whenEmpty priority drift. Pure (no package/YAML): the negated common-commensal set is resolved later
    # by the generator; this plan carries only the structure. Slot naming matches the DE/PRV plans.
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([ValidateRange(1, 9)][int]$PathogenCount = $script:NeoIPCPathogenSlotCount)

    $groups = @(
        @{ Kind = 'primary'; Stages = @('BSI', 'HAP', 'SSI') },
        @{ Kind = 'secondary'; Stages = @('HAP', 'NEC', 'SSI') }
    )
    # A downstream slot is hidden by its value + name + the five resistance fields only; its own SOURCE/MULTIPLE are
    # hidden by THAT slot's own whenEmpty (it is empty whenever an upstream slot is), so they are not repeated here.
    $coreSuffixes = @('', 'NAME', '3GCR', 'CAR', 'COR', 'MRSA', 'VRE')

    foreach ($g in $groups) {
        $isPrimary = $g.Kind -eq 'primary'
        foreach ($stage in $g.Stages) {
            $ownExtras = @((Get-NeoIPCPathogenSlotSuffix -Stage $stage -IsPrimary $isPrimary) | Where-Object { $_ -in @('SOURCE', 'MULTIPLE') })
            foreach ($n in 1..$PathogenCount) {
                $baseCode = if ($isPrimary) { "NEOIPC_${stage}_PATHOGEN_${n}" } else { "NEOIPC_${stage}_SEC_BSI_PATHOGEN_${n}" }
                $varPrefix = if ($isPrimary) { "NeoIPC $stage Pathogen $n" } else { "NeoIPC $stage Secondary BSI pathogen $n" }
                $namePhrase = if ($isPrimary) { "Pathogen $n" } else { "Secondary BSI pathogen $n" }
                $valueVar = "$varPrefix value"
                $nameCode = "${baseCode}_NAME"

                if ($isPrimary -and $stage -eq 'BSI') {
                    [ordered]@{
                        Kind          = 'recognizedPathogen'
                        Stage         = $stage
                        SlotKind      = $g.Kind
                        Index         = $n
                        Name          = "$varPrefix - set recognized pathogen"
                        Description   = 'Sets the recognized pathogen variable for pathogens that are not marked as common commensals.'
                        Condition     = 'true'
                        Priority      = 0
                        ValueVariable = $valueVar
                        Actions       = @([ordered]@{ Type = 'ASSIGN'; Content = "#{$varPrefix is recognized pathogen}"; UsesCommonCommensalSet = $true })
                    }
                    [ordered]@{
                        Kind          = 'whenSet'
                        Stage         = $stage
                        SlotKind      = $g.Kind
                        Index         = $n
                        Name          = "$varPrefix - when set"
                        Description   = "Makes the source field mandatory when $namePhrase is set."
                        Condition     = "d2:hasValue(#{$valueVar})"
                        Priority      = 1
                        ValueVariable = $valueVar
                        Actions       = @([ordered]@{ Type = 'SETMANDATORYFIELD'; DataElementCode = "${baseCode}_SOURCE" })
                    }
                }

                $hideActions = [System.Collections.Generic.List[object]]::new()
                foreach ($suf in $ownExtras) {
                    $hideActions.Add([ordered]@{ Type = 'HIDEFIELD'; DataElementCode = "${baseCode}_$suf" })
                }
                if ($n -lt $PathogenCount) {
                    foreach ($m in ($n + 1)..$PathogenCount) {
                        $mBase = if ($isPrimary) { "NEOIPC_${stage}_PATHOGEN_${m}" } else { "NEOIPC_${stage}_SEC_BSI_PATHOGEN_${m}" }
                        foreach ($suf in $coreSuffixes) {
                            $c = if ($suf) { "${mBase}_$suf" } else { $mBase }
                            $hideActions.Add([ordered]@{ Type = 'HIDEFIELD'; DataElementCode = $c })
                        }
                    }
                }
                if ($hideActions.Count -gt 0) {
                    [ordered]@{
                        Kind          = 'whenEmpty'
                        Stage         = $stage
                        SlotKind      = $g.Kind
                        Index         = $n
                        Name          = "$varPrefix - when empty"
                        Description   = "Hides dependent fields when $namePhrase is empty."
                        Condition     = "!d2:hasValue(#{$valueVar})"
                        Priority      = 1
                        ValueVariable = $valueVar
                        Actions       = $hideActions.ToArray()
                    }
                }

                [ordered]@{
                    Kind          = 'whenEmptyOrListed'
                    Stage         = $stage
                    SlotKind      = $g.Kind
                    Index         = $n
                    Name          = "$varPrefix - when empty or listed"
                    Description   = "Hides the pathogen name for $namePhrase unless ""Not listed"" is selected."
                    Condition     = "!d2:hasValue(#{$valueVar}) || #{$valueVar} != 0"
                    Priority      = 1
                    ValueVariable = $valueVar
                    Actions       = @([ordered]@{ Type = 'HIDEFIELD'; DataElementCode = $nameCode })
                }
                [ordered]@{
                    Kind          = 'whenNotListed'
                    Stage         = $stage
                    SlotKind      = $g.Kind
                    Index         = $n
                    Name          = "$varPrefix - when not listed"
                    Description   = "Makes the pathogen name mandatory for $namePhrase when ""Not listed"" is selected."
                    Condition     = "d2:hasValue(#{$valueVar}) && #{$valueVar} == 0"
                    Priority      = 1
                    ValueVariable = $valueVar
                    Actions       = @([ordered]@{ Type = 'SETMANDATORYFIELD'; DataElementCode = $nameCode })
                }
            }
        }
    }
}
