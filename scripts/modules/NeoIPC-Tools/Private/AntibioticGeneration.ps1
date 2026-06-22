# NeoIPC metadata pipeline — antibiotic-domain generation (private helpers, not exported).
# Canonical sources (see docs/antibiotic-substance-curation.md):
#   metadata/common/antibiotics/NeoIPC-Antibiotics.csv       (id, atc_code, name, atc_group, aware_category)
#   metadata/common/antibiotics/NeoIPC-Antibiotic-Groups.csv (code, name, shortName, description)
# The public generators live in Public/AntibioticGeneration.ps1.

# The four one-off code migrations the source reconciliation applied (deployed option code -> canonical code).
# The canonical code inherits the deployed option's UID (so the option-set ref stays minimal-diff); only the
# stored data VALUE strings need a one-off rewrite (data-migration follow-up). Transitional: once the deployment
# is re-exported with the canonical codes this map is a no-op. See docs/antibiotic-substance-curation.md.
$script:NeoIPCAntibioticCodeRename = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
$script:NeoIPCAntibioticCodeRename['J01AA08']      = 'J01AA08_P'
$script:NeoIPCAntibioticCodeRename['J01XX01']      = 'J01XX01_P'
$script:NeoIPCAntibioticCodeRename['Cefoselis']    = 'tmp_002'
$script:NeoIPCAntibioticCodeRename['Micronomicin'] = 'tmp_001'

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

function Add-NeoIPCAntibioticNameTranslations {
    # Add a translations[] entry per locale whose localized name differs from the English source. property is the
    # uppercase DHIS2 ObjectTranslation NAME token (case-sensitive, single-sourced). Returns the (mutated) object;
    # no-op when $LocaleMaps is empty. Antibiotic names/group names are flat (no rank tag), so the localized value
    # is the catalogue's translation of the English name.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Object,
        [Parameter(Mandatory)][string]$EnglishName,
        [AllowNull()]$LocaleMaps
    )
    if (-not $LocaleMaps -or $LocaleMaps.Count -eq 0) { return $Object }
    $trans = [System.Collections.Generic.List[object]]::new()
    foreach ($lm in $LocaleMaps) {
        $loc = if ($lm.Map.Contains($EnglishName)) { [string]$lm.Map[$EnglishName] } else { $EnglishName }
        if ($loc -cne $EnglishName) { $trans.Add([ordered]@{ property = $script:NeoIPCMetadataTranslatableProperties['name']; locale = $lm.Locale; value = $loc }) }
    }
    if ($trans.Count -gt 0) { $Object['translations'] = $trans.ToArray() }
    $Object
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
        }
    }
}
