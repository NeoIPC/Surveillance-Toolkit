# NeoIPC metadata pipeline — antibiotic-domain generation (private helpers, not exported).
# Canonical sources (see metadata/common/antibiotics/README.md):
#   metadata/common/antibiotics/NeoIPC-Antibiotics.csv       (id, atc_code, name, atc_group, aware_category)
#   metadata/common/antibiotics/NeoIPC-Antibiotic-Groups.csv (code, name, shortName, description)
# The public generators live in Public/AntibioticGeneration.ps1.

# The four one-off code migrations the source reconciliation applied (deployed option code -> canonical code).
# The canonical code inherits the deployed option's UID (so the option-set ref stays minimal-diff); only the
# stored data VALUE strings need a one-off rewrite (data-migration follow-up). Transitional: once the deployment
# is re-exported with the canonical codes this map is a no-op. See metadata/common/antibiotics/README.md.
$script:NeoIPCAntibioticCodeRename = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
$script:NeoIPCAntibioticCodeRename['J01AA08']      = 'J01AA08_P'
$script:NeoIPCAntibioticCodeRename['J01XX01']      = 'J01XX01_P'
$script:NeoIPCAntibioticCodeRename['Cefoselis']    = 'tmp_002'
$script:NeoIPCAntibioticCodeRename['Micronomicin'] = 'tmp_001'

# DHIS2 identity comes from SOURCE, never the export: per-option / per-group UIDs are the `uid` column of the three
# antibiotic CSVs (collections -> data files), while the fixed-code SINGLETONS (the option set + the two
# optionGroupSets) carry their UID in the constants below (singletons -> code). All were captured once from the
# deployment (see the antibiotics README for how to re-capture); the classified-diff gate verifies the regenerated
# objects stay byte-identical to the deployed ones. The export, when supplied, is consulted ONLY for sharing and for
# the no-silent-drop validation — not for identity.

# The 3 WHO AWaRe optionGroups are an abstract reference list (WHO-defined name/shortName/description + the
# aware_category they select), so they live in the canonical CSV metadata/common/antibiotics/NeoIPC-Antibiotic-
# AWaRe-Groups.csv (read by Get-NeoIPCAntibioticAwareGroup), NOT a code constant — mirroring the ATC groups. Their
# DHIS2 UID is that CSV's `uid` column; sharing is still enriched from the export by code when one is supplied.

# The NEOIPC_ANTIMICROBIAL_SUBSTANCES option set's own UID — a fixed-code singleton (the code is a contract).
$script:NeoIPCAntimicrobialOptionSetUid = 'JE7ECBWKhWD'

# The 2 antibiotic optionGroupSets — likewise structural singletons. Codes are fixed (neoipcr/the reports filter on
# ATC5 / WHO_AWARE). Content (name/description) AND the DHIS2 UID (the Uid field) are canonical here; the option-set
# reference, dataDimension and sharing are taken from the export when one is supplied. The long WHO_AWARE description
# is assembled with explicit `\n` joins so it is independent of this file's newline encoding (it must match the
# deployed value exactly — gate-verified).
$script:NeoIPCAntibioticGroupSet = [ordered]@{
    ATC5      = [ordered]@{ Uid = 'D1N8iz0Grqv'; Name = 'ATC-5 Groups'; Description = '' }
    WHO_AWARE = [ordered]@{ Uid = 'pvQ5WMrK25p'; Name = 'AWaRe Groups'; Description = (@(
                'AWaRe is the WHO classification of antibiotics introduced by WHO as part of the 2017 Model List of Essential Medicines.'
                'In the AWaRe classification, there are three categories of antibiotics:'
                '• Access antibiotics that have a narrow spectrum of activity and a good safety profile in terms of side-effects.'
                '• Watch antibiotics that are broader-spectrum antibiotics and are recommended as first-choice options for patients with more severe clinical presentations or for infections where the causative pathogens are more likely to be resistant to Access antibiotics.'
                '• Reserve antibiotics that are last-choice antibiotics used to treat multidrug-resistant infections.'
                'This classification can be used to give an indirect indication of the appropriateness of antibiotic use. The World Health Organization (WHO) has defined a target that at least 70% of global antibiotic consumption at the national level should be from the Access group.'
            ) -join "`n") }
}

function ConvertTo-NeoIPCAntibioticCanonicalCode {
    # Map a deployed option code to its canonical (post-reconciliation) code, or return it unchanged.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Code)
    if ($script:NeoIPCAntibioticCodeRename.ContainsKey($Code)) { $script:NeoIPCAntibioticCodeRename[$Code] } else { $Code }
}

function Get-NeoIPCAntibioticSubstance {
    # Read NeoIPC-Antibiotics.csv into ordered substance records:
    #   [ordered]@{ Id; AtcCode; Name; AtcGroup; AwareCategory }
    # Fails loud on a blank id/name (every DHIS2 option needs a unique non-negative code + a not-null name) and on
    # a duplicate id. Operates on a path so the public generators can default to the canonical file.
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][string]$Path)

    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    $rows = @(Import-Csv -LiteralPath $resolved -Encoding utf8NoBOM)
    if ($rows.Count -eq 0) { throw "No antibiotic substances found in '$resolved'." }
    # shortName / formName / description are TRULY OPTIONAL: substances carry only `name` today, but the schema may
    # later add any of them (e.g. a form name for the modern Capture app). Read each only if its column exists; an
    # absent column OR an empty cell yields '' and the generators then neither emit the field nor a translation for
    # it (graceful for both metadata generation and the PO).
    $cols = $rows[0].PSObject.Properties.Name
    $hasShortName = $cols -contains 'short_name'
    $hasFormName = $cols -contains 'form_name'
    $hasDescription = $cols -contains 'description'
    # `uid` is the DHIS2 option UID (source identity). Optional like the other extra columns: an absent column or a
    # blank cell yields '' and the generator mints a deterministic UID (a not-yet-deployed substance, e.g. an oral
    # route-split). Note `id` here is the option CODE, not the UID — these CSVs predate the UID-keyed convention.
    $hasUid = $cols -contains 'uid'
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($r in $rows) {
        $id = [string]$r.id
        $nm = [string]$r.name
        if ([string]::IsNullOrWhiteSpace($id)) { throw "Antibiotic row (name '$nm') has a blank id — every option needs a code." }
        if ([string]::IsNullOrWhiteSpace($nm)) { throw "Antibiotic id '$id' has a blank name — DHIS2 Option.name is not-null." }
        if (-not $seen.Add($id)) { throw "Duplicate antibiotic id '$id' in '$resolved' — option codes must be unique." }
        [ordered]@{
            Id            = $id
            AtcCode       = [string]$r.atc_code
            Name          = $nm
            AtcGroup      = [string]$r.atc_group
            AwareCategory = [string]$r.aware_category
            ShortName     = if ($hasShortName) { [string]$r.short_name } else { '' }
            FormName      = if ($hasFormName) { [string]$r.form_name } else { '' }
            Description   = if ($hasDescription) { [string]$r.description } else { '' }
            Uid           = if ($hasUid) { [string]$r.uid } else { '' }
        }
    }
}

function Get-NeoIPCAntibioticLocaleMap {
    # Load each locale's english->localized map from the bilingual antibiotic catalogues ($PoBaseName.<locale>.po
    # under $PoDirectory), skipping locales whose catalogue carries no real translation. Returns a List of
    # { Locale; Map } (empty when no -PoDirectory or none found). Shared by the option-set and group generators.
    [CmdletBinding()]
    param([AllowNull()][string]$PoDirectory, [string]$PoBaseName = 'antibiotics')
    $maps = [System.Collections.Generic.List[object]]::new()
    if (-not $PoDirectory) { return , $maps }
    $resolvedPo = Resolve-Path -LiteralPath $PoDirectory -ErrorAction SilentlyContinue
    if (-not $resolvedPo) { return , $maps }
    $localeRe = [regex]('^' + [regex]::Escape($PoBaseName) + '\.(?<loc>[^.]+)\.po$')
    foreach ($f in @(Get-ChildItem -LiteralPath $resolvedPo.Path -Filter "$PoBaseName.*.po" -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $m = $localeRe.Match($f.Name)
        if (-not $m.Success) { continue }
        $map = Get-NeoIPCPoTranslationMap -Path $f.FullName
        if ($map.Count -gt 0) { $maps.Add([pscustomobject]@{ Locale = $m.Groups['loc'].Value; Map = $map }) }
    }
    , $maps
}

function Add-NeoIPCAntibioticTranslations {
    # Add translations[] entries for an antibiotic-domain object's translatable fields. $EnglishValue is an ordered
    # map of DHIS2 property name -> English source value (e.g. [ordered]@{ name = ...; shortName = ...; description =
    # ... }); each property's uppercase ObjectTranslation token comes from $NeoIPCMetadataTranslatableProperties
    # (single source — case-sensitive). For every locale catalogue and every non-empty field, an entry is added where
    # the catalogue's localized value differs from the English source — a flat english->localized lookup, so ANY
    # translatable field (name/shortName/formName/description) is supported with no per-field catalogue split. Entries
    # are emitted locale-major then in field order, for stable diffs. Returns the (mutated) object; no-op when
    # $LocaleMaps is empty or nothing differs.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Object,
        [Parameter(Mandatory)][System.Collections.IDictionary]$EnglishValue,
        [AllowNull()]$LocaleMaps
    )
    if (-not $LocaleMaps -or $LocaleMaps.Count -eq 0) { return $Object }
    $trans = [System.Collections.Generic.List[object]]::new()
    foreach ($lm in $LocaleMaps) {
        foreach ($prop in $EnglishValue.Keys) {
            $en = [string]$EnglishValue[$prop]
            if ([string]::IsNullOrEmpty($en)) { continue }
            $token = $script:NeoIPCMetadataTranslatableProperties[$prop]
            if (-not $token) { throw "No DHIS2 translation token is defined for property '$prop'." }
            $loc = if ($lm.Map.Contains($en)) { [string]$lm.Map[$en] } else { $en }
            if ($loc -cne $en) { $trans.Add([ordered]@{ property = $token; locale = $lm.Locale; value = $loc }) }
        }
    }
    if ($trans.Count -gt 0) { $Object['translations'] = $trans.ToArray() }
    $Object
}

function Get-NeoIPCAntibioticTranslatableValues {
    # Collect an antibiotic-domain object's non-empty translatable fields into an ordered property->English map, in
    # DHIS2 field order (name, shortName, formName, description). `name` is always present (the readers reject a
    # blank one); shortName/formName/description are included ONLY when non-empty. The generators use the returned
    # map to BOTH set the fields on the emitted object AND drive Add-NeoIPCAntibioticTranslations, so the metadata
    # fields and their translations stay in lockstep and the three optional fields are gracefully absent together.
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][string]$ShortName,
        [AllowNull()][string]$FormName,
        [AllowNull()][string]$Description
    )
    $m = [ordered]@{ name = $Name }
    if (-not [string]::IsNullOrEmpty($ShortName))   { $m['shortName'] = $ShortName }
    if (-not [string]::IsNullOrEmpty($FormName))    { $m['formName'] = $FormName }
    if (-not [string]::IsNullOrEmpty($Description)) { $m['description'] = $Description }
    $m
}

function Add-NeoIPCAntibioticGroupSharing {
    # Reuse the deployed object's normalized sharing on a generated group / group-set. Returns the (mutated) object.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Group,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Deployed
    )
    if ($Deployed.Contains('sharing')) {
        $sh = Convert-NeoIPCSharing $Deployed['sharing']
        if ($sh -and $sh.Count -gt 0) { $Group['sharing'] = $sh }
    }
    $Group
}

function Get-NeoIPCAntibioticGroup {
    # Read NeoIPC-Antibiotic-Groups.csv into ordered group records:
    #   [ordered]@{ Code; Name; ShortName; Description }
    # Fails loud on a blank/duplicate code. The ATC-4 group shells; membership is derived (by atc_group) by the
    # option-group generator. The 3 AWaRe groups + the 2 group-sets are structural and reused from the export.
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][string]$Path)

    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    $rows = @(Import-Csv -LiteralPath $resolved -Encoding utf8NoBOM)
    if ($rows.Count -eq 0) { throw "No antibiotic groups found in '$resolved'." }
    $hasUid = $rows[0].PSObject.Properties.Name -contains 'uid'   # source identity; blank/absent -> generator mints
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($r in $rows) {
        $code = [string]$r.code
        if ([string]::IsNullOrWhiteSpace($code)) { throw "Antibiotic-group row (name '$($r.name)') has a blank code." }
        if (-not $seen.Add($code)) { throw "Duplicate antibiotic-group code '$code' in '$resolved'." }
        [ordered]@{
            Code        = $code
            Name        = [string]$r.name
            ShortName   = [string]$r.shortName
            Description = [string]$r.description
            Uid         = if ($hasUid) { [string]$r.uid } else { '' }
        }
    }
}

function Get-NeoIPCAntibioticAwareGroup {
    # Read NeoIPC-Antibiotic-AWaRe-Groups.csv into ordered AWaRe-group records:
    #   [ordered]@{ Code; Category; Name; ShortName; Description }
    # The 3 WHO AWaRe groups (WHO_AWARE_ACCESS/WATCH/RESERVE). Code is the DHIS2 optionGroup code (a fixed contract —
    # neoipcr filters on it); Category is the aware_category value (Access/Watch/Reserve) that selects each group's
    # member options. Fails loud on a blank/duplicate code or an unexpected category. The deployed UID + sharing are
    # preserved from the export by code by the generator (content here, identity from the export).
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][string]$Path)

    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    $rows = @(Import-Csv -LiteralPath $resolved -Encoding utf8NoBOM)
    if ($rows.Count -eq 0) { throw "No AWaRe groups found in '$resolved'." }
    $hasUid = $rows[0].PSObject.Properties.Name -contains 'uid'   # source identity; blank/absent -> generator mints
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($r in $rows) {
        $code = [string]$r.code
        $cat = [string]$r.category
        if ([string]::IsNullOrWhiteSpace($code)) { throw "AWaRe-group row (name '$($r.name)') has a blank code." }
        if ($cat -cnotin @('Access', 'Watch', 'Reserve')) { throw "AWaRe group '$code' has an unexpected category '$cat' (expected Access/Watch/Reserve)." }
        if (-not $seen.Add($code)) { throw "Duplicate AWaRe-group code '$code' in '$resolved'." }
        [ordered]@{
            Code        = $code
            Category    = $cat
            Name        = [string]$r.name
            ShortName   = [string]$r.shortName
            Description = [string]$r.description
            Uid         = if ($hasUid) { [string]$r.uid } else { '' }
        }
    }
}
