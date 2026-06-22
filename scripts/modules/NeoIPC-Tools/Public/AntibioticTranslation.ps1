# NeoIPC metadata pipeline — antibiotic translation catalogue generator (public). Builds po/antibiotics.pot from
# the canonical antibiotic sources and msgmerge-updates the existing per-locale catalogues. The private machinery
# (string collection, bare-msgid PO read/write/merge) lives in Private/AntibioticTranslation.ps1.

function Export-NeoIPCAntibioticTranslation {
    <#
    .SYNOPSIS
        Generate po/antibiotics.pot (and update the existing po/antibiotics.<locale>.po) from the antibiotic sources.
    .DESCRIPTION
        The antibiotic domain is translated in its own bilingual gettext component, keyed by the English string
        (bare msgid, no msgctxt — read by Get-NeoIPCPoTranslationMap, like po4a's infectious_agents catalogue). This
        cmdlet collects the full translatable surface — substance names (+ shortName/formName/description where the
        source carries them), the ATC + AWaRe group name/shortName/description, the ATC5/WHO_AWARE group-set
        name/description, and the printed-list UI labels (ListElements.csv) — de-duplicates it, and:

          - writes the template po/<PoBaseName>.pot (all msgstr empty);
          - for every EXISTING po/<PoBaseName>.<locale>.po, msgmerge-updates it (msgid set + order from the sources;
            each existing msgstr + fuzzy flag preserved by msgid; strings dropped from the sources become obsolete;
            new strings get an empty msgstr). New locales are NOT created here — Weblate creates them from the .pot
            as translators need them (matching the metadata catalogue's policy).

        Pure file processing — no DHIS2 API. Both the .pot and each updated .po are msgfmt-validated (best-effort;
        a warning, never a hard failure, when gettext is unavailable). ATC/AWaRe content is reproduced under WHO
        attribution (see antibiotics/README.md); keying by the English name keeps WHO ATC *codes* out of the PO.
    .PARAMETER SubstancePath / GroupPath / AwareGroupPath / ListElementsPath
        The canonical antibiotic sources. Default to the repository files under metadata/common/antibiotics/.
    .PARAMETER PoDirectory
        The directory holding the catalogues. Default: the repository po/ directory.
    .PARAMETER PoBaseName
        Catalogue base name. Default: antibiotics (so antibiotics.pot + antibiotics.<locale>.po).
    .OUTPUTS
        A summary object { PotPath; StringCount; UpdatedLocales }.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [string]$SubstancePath = (Join-Path $PSScriptRoot '..' '..' '..' '..' 'metadata' 'common' 'antibiotics' 'NeoIPC-Antibiotics.csv'),
        [string]$GroupPath = (Join-Path $PSScriptRoot '..' '..' '..' '..' 'metadata' 'common' 'antibiotics' 'NeoIPC-Antibiotic-Groups.csv'),
        [string]$AwareGroupPath = (Join-Path $PSScriptRoot '..' '..' '..' '..' 'metadata' 'common' 'antibiotics' 'NeoIPC-Antibiotic-AWaRe-Groups.csv'),
        [string]$ListElementsPath = (Join-Path $PSScriptRoot '..' '..' '..' '..' 'metadata' 'common' 'antibiotics' 'ListElements.csv'),
        [string]$PoDirectory = (Join-Path $PSScriptRoot '..' '..' '..' '..' 'po'),
        [string]$PoBaseName = 'antibiotics'
    )

    $strings = Get-NeoIPCAntibioticTranslationString -SubstancePath $SubstancePath -GroupPath $GroupPath -AwareGroupPath $AwareGroupPath -ListElementsPath $ListElementsPath
    if ($strings.Count -eq 0) { throw "No antibiotic translatable strings were collected from the sources." }

    if (-not (Test-Path -LiteralPath $PoDirectory)) {
        if ($PSCmdlet.ShouldProcess($PoDirectory, 'Create PO directory')) { New-Item -ItemType Directory -Path $PoDirectory -Force | Out-Null }
    }
    $resolvedPo = (Resolve-Path -LiteralPath $PoDirectory -ErrorAction Stop).Path
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)

    # Template (.pot): every source string, msgstr empty.
    $potEntries = [System.Collections.Generic.List[object]]::new()
    foreach ($s in $strings) { $potEntries.Add([ordered]@{ Msgid = $s; Msgstr = ''; Fuzzy = $false }) }
    $potPath = Join-Path $resolvedPo "$PoBaseName.pot"
    if ($PSCmdlet.ShouldProcess($potPath, 'Write antibiotic .pot')) {
        [System.IO.File]::WriteAllText($potPath, (Write-NeoIPCAntibioticPoText -Entry $potEntries), $utf8NoBom)
        if (-not (Test-NeoIPCMetadataPoSyntax -Path $potPath)) { Write-Warning "msgfmt reported issues in $potPath." }
    }

    # Existing per-locale catalogues: msgmerge-update only (Weblate creates new locales from the .pot).
    $localeRe = [regex]('^' + [regex]::Escape($PoBaseName) + '\.(?<loc>[^.]+)\.po$')
    $updated = [System.Collections.Generic.List[string]]::new()
    foreach ($f in @(Get-ChildItem -LiteralPath $resolvedPo -Filter "$PoBaseName.*.po" -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $m = $localeRe.Match($f.Name)
        if (-not $m.Success) { continue }
        $loc = $m.Groups['loc'].Value
        $existing = Read-NeoIPCAntibioticPoText -Text (Get-Content -LiteralPath $f.FullName -Raw)
        $merged = Merge-NeoIPCAntibioticPoEntry -SourceMsgid $strings -Existing $existing
        if ($PSCmdlet.ShouldProcess($f.FullName, 'Update antibiotic .po')) {
            [System.IO.File]::WriteAllText($f.FullName, (Write-NeoIPCAntibioticPoText -Entry $merged -Locale $loc), $utf8NoBom)
            if (-not (Test-NeoIPCMetadataPoSyntax -Path $f.FullName)) { Write-Warning "msgfmt reported issues in $($f.FullName)." }
            $updated.Add($loc)
        }
    }

    [pscustomobject]@{ PotPath = $potPath; StringCount = $strings.Count; UpdatedLocales = $updated.ToArray() }
}
