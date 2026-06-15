<#
.SYNOPSIS
    (Re)generates the per-locale report wrappers ({Report}.<locale>.qmd) from
    each report's master {Report}.qmd.

.DESCRIPTION
    The per-locale wrappers are boilerplate: identical to the master apart from
    the `lang:` value, the LC_ALL setup, and the params block carrying no
    annotation comments. Maintaining them by hand drifts — the params block has
    to mirror the master exactly. This tool regenerates them so the master QMD
    (the params source of truth) plus the locale list in `_quarto.yml`'s profile
    group are the single source of truth.

    Generation is an in-place transform of the master, NOT a fixed template, so
    any extra front matter (e.g. Partner-Report's top-level `subtitle:`) and the
    document body are preserved verbatim. Only three things change:
      * the `lang:` value           -> the target locale
      * the params block            -> annotation comments and blank lines stripped
      * the LC_ALL in the setup chunk -> the locale's POSIX locale

    Supported locales come from each report's `_quarto.yml` profile group (the
    first `- [..]` group — the locale group). The master's own locale is the
    master file itself and is not regenerated. Each locale's LC_ALL is resolved
    via $LcAllByLanguage below, which MUST match the locales the
    NeoIPC-Reporting Docker image generates (see its Dockerfile `locale-gen`).

.PARAMETER Check
    Verify mode: build each wrapper in memory and report (and fail) on any
    on-disk difference, without writing. For CI / pre-commit.

.PARAMETER ToolkitRoot
    Surveillance-Toolkit root. Defaults to one level above this script.

.EXAMPLE
    pwsh scripts/Build-LocaleReportSources.ps1
    Regenerate every per-locale wrapper after editing a master QMD's params.

.EXAMPLE
    pwsh scripts/Build-LocaleReportSources.ps1 -Check
    Fail if any wrapper is stale (drifted from its master).
#>
[CmdletBinding()]
param(
    [string] $ToolkitRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [switch] $Check
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ReportsDir = Join-Path $ToolkitRoot 'reports'

# Language -> POSIX locale for the LC_ALL setup chunk. MUST stay in sync with
# the NeoIPC-Reporting Dockerfile's `locale-gen` line (a locale not generated
# in the image renders in the "C" locale). Adding a locale to a report's
# profile group without an entry here is a hard error below.
$LcAllByLanguage = @{
    en = 'en_GB.UTF-8'
    de = 'de_DE.UTF-8'
    el = 'el_GR.UTF-8'
    es = 'es_ES.UTF-8'
    et = 'et_EE.UTF-8'
    it = 'it_IT.UTF-8'
}

# Reports whose wrappers are generated. These are the two reports whose params
# are also snapshotted for the backend (Generate-ReportSchemas.ps1).
$reports = @('Partner-Report', 'Reference-Report')

# Reads the locale group — the first `- [..]` flow sequence under
# `profile: > group:` — from a report's _quarto.yml.
function Get-LocaleGroup {
    param([Parameter(Mandatory)] [string] $QuartoYmlPath)
    $lines = [System.IO.File]::ReadAllText($QuartoYmlPath) -split "`n"
    $inProfile = $false
    $inGroup = $false
    foreach ($raw in $lines) {
        $line = $raw.TrimEnd("`r")
        if ($line -match '^profile:\s*$') { $inProfile = $true; continue }
        if ($inProfile -and $line -match '^\S') { $inProfile = $false; $inGroup = $false }
        if ($inProfile -and $line -match '^\s+group:\s*$') { $inGroup = $true; continue }
        if ($inGroup -and $line -match '^\s+-\s*\[(.+)\]\s*$') {
            return @($Matches[1] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        }
    }
    throw "No locale group (profile.group first '- [..]') in '$QuartoYmlPath'."
}

# Reads the `lang:` value from a master QMD's front matter.
function Get-MasterLang {
    param([Parameter(Mandatory)] [string] $QmdPath)
    foreach ($raw in ([System.IO.File]::ReadAllText($QmdPath) -split "`n")) {
        if ($raw.TrimEnd("`r") -match '^lang:\s*(\S+)') { return $Matches[1] }
    }
    throw "No 'lang:' in '$QmdPath'."
}

# In-place transform of the master into a per-locale wrapper.
function Build-LocaleQmd {
    param(
        [Parameter(Mandatory)] [string] $MasterText,
        [Parameter(Mandatory)] [string] $Locale,
        [Parameter(Mandatory)] [string] $LcAll
    )
    $out = [System.Collections.Generic.List[string]]::new()
    $dash = 0
    $inFrontMatter = $false
    $inParams = $false
    foreach ($raw in ($MasterText -split "`n")) {
        $line = $raw.TrimEnd("`r")

        if ($line -eq '---') {
            $dash++
            $inFrontMatter = ($dash -eq 1)
            if ($dash -ge 2) { $inParams = $false }
            $out.Add($line)
            continue
        }

        if ($inFrontMatter) {
            if ($line -match '^lang:\s*') { $out.Add("lang: $Locale"); continue }
            if ($line -match '^params:\s*$') { $inParams = $true; $out.Add($line); continue }
            if ($inParams) {
                # A non-indented, non-blank line ends the params block (e.g. a
                # top-level `subtitle:`) — preserve it and leave the block.
                if ($line -notmatch '^\s' -and $line.Trim() -ne '') { $inParams = $false; $out.Add($line); continue }
                # Strip annotation/description comments and blank lines.
                if ($line.TrimStart().StartsWith('#')) { continue }
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                $out.Add($line)
                continue
            }
            $out.Add($line)
            continue
        }

        # Body: rewrite the LC_ALL value, preserving indentation.
        if ($line -match '^(\s*)Sys\.setenv\(LC_ALL\s*=') {
            $out.Add("$($Matches[1])Sys.setenv(LC_ALL = `"$LcAll`")")
            continue
        }
        $out.Add($line)
    }
    return (($out -join "`n").TrimEnd("`n") + "`n")
}

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$drift = [System.Collections.Generic.List[string]]::new()
$wrote = 0

foreach ($report in $reports) {
    $reportDir = Join-Path $ReportsDir $report
    $masterQmd = Join-Path $reportDir "$report.qmd"
    $quartoYml = Join-Path $reportDir '_quarto.yml'
    if (-not (Test-Path $masterQmd)) { throw "Master QMD not found: '$masterQmd'." }
    if (-not (Test-Path $quartoYml)) { throw "_quarto.yml not found: '$quartoYml'." }

    $masterText = [System.IO.File]::ReadAllText($masterQmd)
    $masterLang = Get-MasterLang $masterQmd
    $locales = Get-LocaleGroup $quartoYml

    Write-Host ("{0}: locales [{1}], master lang '{2}'" -f $report, ($locales -join ', '), $masterLang)

    foreach ($loc in $locales) {
        if ($loc -eq $masterLang) { continue }
        if (-not $LcAllByLanguage.ContainsKey($loc)) {
            throw "No LC_ALL mapping for locale '$loc' ($report). Add it to `$LcAllByLanguage and ensure the Docker image generates it."
        }
        $content = Build-LocaleQmd -MasterText $masterText -Locale $loc -LcAll $LcAllByLanguage[$loc]
        $outPath = Join-Path $reportDir "$report.$loc.qmd"

        if ($Check) {
            $existing = if (Test-Path $outPath) { ([System.IO.File]::ReadAllText($outPath) -replace "`r`n", "`n") } else { '' }
            if ($existing -ne $content) { $drift.Add("$report.$loc.qmd") }
        }
        else {
            [System.IO.File]::WriteAllText($outPath, $content, $utf8NoBom)
            Write-Host ("  wrote {0}.{1}.qmd" -f $report, $loc)
            $wrote++
        }
    }

    # Warn about orphan wrappers (a locale wrapper on disk no longer in the group).
    foreach ($f in (Get-ChildItem -Path $reportDir -Filter "$report.*.qmd" -File)) {
        if ($f.Name -match "^$([regex]::Escape($report))\.([A-Za-z]+(?:[-_][A-Za-z]+)?)\.qmd$") {
            $loc = $Matches[1]
            if ($loc -ne $masterLang -and $locales -notcontains $loc) {
                Write-Warning ("Orphan wrapper '{0}' — locale '{1}' is not in {2}'s profile group." -f $f.Name, $loc, $report)
            }
        }
    }
}

if ($Check) {
    if ($drift.Count -gt 0) {
        Write-Error ("Stale locale wrappers (run Build-LocaleReportSources.ps1 to regenerate): {0}" -f ($drift -join ', '))
        exit 1
    }
    Write-Host 'All locale wrappers are up to date.'
}
else {
    Write-Host ("Done. Wrote {0} locale wrapper(s)." -f $wrote)
}
