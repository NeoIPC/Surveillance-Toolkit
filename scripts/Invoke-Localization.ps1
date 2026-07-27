#!/usr/bin/env pwsh
#Requires -Version 7.6

<#
.SYNOPSIS
    Unified wrapper for the NeoIPC localization toolchain.

.DESCRIPTION
    Wraps po4a, the glossary script, YAML key extraction, and string layer
    validation into a single entry point with tab-completable parameters.

    Catalogue ownership: the repository owns the .pot templates; Weblate owns
    the .po translations and is their only writer. po4a msgmerges the .po files as an
    unavoidable side effect of every run, so -Update restores them from HEAD once
    the localized artifacts exist. Two writers on one .po is what conflicts every
    language of a catalogue at once: both sides rewrite adjacent header lines
    (POT-Creation-Date against PO-Revision-Date / Last-Translator / Language-Team /
    X-Generator) inside a single hunk git cannot auto-merge.

    Update pipeline (default -Config all):
      1. Fix string layer duplicates (Test-StringResourceLayers.ps1 -Fix)
      2. Update YAML keys in po4a configs (Update-Po4aYamlKeys.ps1)
      3. Run po4a to regenerate the .pot and the localized files, then restore
         every Weblate-owned .po so the run leaves them byte-identical
      4. Update glossary PO and generate localized YAML

    Render mode:
      Runs po4a with --no-update: produces the localized artifacts from the
      catalogues exactly as committed, writing neither .pot nor .po.

    Test mode:
      Runs string layer validation in read-only mode.

.PARAMETER Update
    Run the update pipeline: regenerate the .pot templates, render the localized
    artifacts, and leave every Weblate-owned .po byte-identical. Refuses to start
    when a Weblate-owned .po already has uncommitted changes, because the restore
    that follows po4a would discard them.

.PARAMETER Render
    Render the localized artifacts only, writing neither .pot nor .po. Supports the
    po4a configs (reports, documentation, infectious_agents, scripts) or 'all'; the
    glossary and antibiotic catalogues are produced by generators with no read-only
    mode. Use this for builds and for rendering a single language.

.PARAMETER Test
    Run read-only string layer validation.

.PARAMETER Config
    Which configuration to update. Default: all.
    - reports:            po/reports.po4a.cfg
    - documentation:      po/documentation.po4a.cfg
    - infectious_agents:  po/infectious_agents.po4a.cfg
    - scripts:            scripts/po4a.cfg
    - glossary:           glossary via update-glossary-po.py
    - antibiotics:        po/antibiotics.pot via NeoIPC-Tools Export-NeoIPCAntibioticTranslation
    - all:                all of the above

.PARAMETER Force
    Generate localized files even for incomplete translations.
    Passes --keep 0 to po4a and --threshold 0 to the glossary script.

.PARAMETER DryRun
    Show what would be done without making changes. Passes -DryRun to
    Update-Po4aYamlKeys.ps1 and prints the commands that would run for
    po4a and the glossary script.

.EXAMPLE
    Invoke-Localization -Update
    Run the full pipeline for all configs. Changes the .pot templates; leaves every
    Weblate-owned .po untouched.

.EXAMPLE
    Invoke-Localization -Render -Config reports
    Regenerate the localized report sources from the committed catalogues without
    touching po/reports.pot or any po/reports.*.po.

.EXAMPLE
    Invoke-Localization -Update -Config reports
    Update YAML keys and run po4a for the reports config only.

.EXAMPLE
    Invoke-Localization -Update -Config glossary
    Fix string layers and regenerate glossary YAML from PO files.

.EXAMPLE
    Invoke-Localization -Update -Force
    Run the full pipeline, generating localized files for all languages
    regardless of translation completeness.

.PARAMETER NonInteractive
    Suppress interactive prompts. Runs read-only string layer validation
    before the update pipeline; aborts with a non-zero exit code if
    validation fails instead of attempting interactive fixes.
    Intended for CI/CD and scripted usage.

.EXAMPLE
    Invoke-Localization -Update -NonInteractive
    Run the full pipeline non-interactively: validate string layers first,
    abort on failure, then update all configs and glossary.

.EXAMPLE
    Invoke-Localization -Test
    Check for string resource duplicates across YAML layers (read-only).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory, ParameterSetName = 'Update')]
    [switch]$Update,

    [Parameter(Mandatory, ParameterSetName = 'Render')]
    [switch]$Render,

    [Parameter(Mandatory, ParameterSetName = 'Test')]
    [switch]$Test,

    [Parameter(ParameterSetName = 'Update')]
    [Parameter(ParameterSetName = 'Render')]
    [ValidateSet('reports', 'documentation', 'infectious_agents', 'scripts', 'glossary', 'antibiotics', 'all')]
    [string]$Config = 'all',

    [Parameter(ParameterSetName = 'Update')]
    [Parameter(ParameterSetName = 'Render')]
    [switch]$Force,

    [Parameter(ParameterSetName = 'Update')]
    [Parameter(ParameterSetName = 'Render')]
    [switch]$DryRun,

    [Parameter(ParameterSetName = 'Update')]
    [switch]$NonInteractive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Path resolution
# ---------------------------------------------------------------------------
$repoRoot = Split-Path -Parent $PSScriptRoot   # scripts/ -> repo root
$po4aSubmodule = Join-Path $repoRoot 'tools' 'po4a'

$configMap = @{
    reports            = 'po/reports.po4a.cfg'
    documentation      = 'po/documentation.po4a.cfg'
    infectious_agents  = 'po/infectious_agents.po4a.cfg'
    scripts            = 'scripts/po4a.cfg'
}
$po4aConfigs = @('reports', 'documentation', 'infectious_agents', 'scripts')

# Which of those catalogues Weblate owns. `scripts` is deliberately absent: scripts/po/*.po is not
# registered as a Weblate component, so it stays repository-owned and this pipeline is the only thing
# that keeps it current. Guarding it as Weblate's would freeze it at HEAD — po4a's msgmerge of a new
# message key would be discarded, and no other writer exists to add it — and would abort the run on a
# legitimate hand edit. po/glossary.*.po is likewise repository-owned, and is not a po4a config.
$weblateOwnedPo4aConfigs = @('reports', 'documentation', 'infectious_agents')

# Each product po4a config derives its --package-version from that product's VERSION file (the single
# source of truth), passed to po4a on the command line so the version lives in exactly one place. scripts/
# is not an independently-versioned product and has no entry (it keeps whatever its .cfg declares).
$versionFileMap = @{
    reports            = 'reports/VERSION'
    documentation      = 'doc/protocol/VERSION'
    infectious_agents  = 'metadata/common/infectious-agents/VERSION'
}

# po4a cannot be told a custom file header, so after it runs we rewrite the .pot header comment block into
# the NeoIPC house style (matching po/glossary.pot).
#
# A catalogue's licence is set DELIBERATELY here; it is not inherited from the licence of the directory the
# strings were extracted from, and the two routinely differ. What governs a catalogue is what the catalogue
# actually contains. Concretely: metadata/common/infectious-agents/ is CC BY-NC-ND 4.0 because of its
# upstream sources, but po4a extracts only `keys='Name ConceptType Value'` from it — taxonomic names,
# synonyms, rank labels, controlled values, plus NeoIPC's own header/footer prose. None of the upstream
# descriptions, authorities or references travels with them, and names are not copyrightable in any case.
# A NoDerivatives term could not apply to a translation catalogue regardless: a translation *is* a
# derivative work, so an ND catalogue could not lawfully be translated at all, which is its only purpose.
#
# These values must match each Weblate component's `license` field, because that is what is displayed to a
# contributor as the terms they are contributing under.
$catalogHeaderMap = @{
    reports           = @{ Package = 'NeoIPC Surveillance Reports';               License = 'Creative Commons Attribution 4.0 International' }
    documentation     = @{ Package = 'NeoIPC Surveillance Documentation';         License = 'Creative Commons Attribution 4.0 International' }
    infectious_agents = @{ Package = 'NeoIPC Surveillance Infectious Agent List'; License = 'Creative Commons Attribution 4.0 International' }
    scripts           = @{ Package = 'NeoIPC Surveillance Scripts';               License = 'MIT' }
}
$copyrightHolder = 'Charité – Universitätsmedizin Berlin'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Test-Po4aSubmodule {
    $po4aExe = Join-Path $po4aSubmodule 'po4a'
    if (-not (Test-Path $po4aExe)) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new(
                    "The po4a submodule is not initialized. Run: git submodule update --init tools/po4a"
                ),
                'Po4aSubmoduleNotInitialized',
                [System.Management.Automation.ErrorCategory]::ObjectNotFound,
                $po4aSubmodule
            )
        )
    }
}

function Find-Python {
    foreach ($cmd in @('python3', 'python')) {
        $found = Get-Command $cmd -ErrorAction SilentlyContinue
        if ($found) {
            # Verify it's real Python, not the Windows Store stub (exit 9009)
            try {
                $null = & $found.Source --version 2>&1
                if ($LASTEXITCODE -eq 0) { return $found.Source }
            } catch { }
        }
    }
    $PSCmdlet.ThrowTerminatingError(
        [System.Management.Automation.ErrorRecord]::new(
            [System.InvalidOperationException]::new(
                "Python not found. Install Python 3 and ensure 'python3' or 'python' is on PATH."
            ),
            'PythonNotFound',
            [System.Management.Automation.ErrorCategory]::ObjectNotFound,
            $null
        )
    )
}

function Invoke-Po4a {
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        # --package-version to pass to po4a, from the product's VERSION file (the single source of truth).
        # Empty for configs without a product VERSION (e.g. scripts), which keep whatever their .cfg declares.
        [string]$PackageVersion,

        # Pass po4a's --no-update: "Do not change the POT and PO files, only the translation may be
        # updated." Renders the localized artifacts from the catalogues exactly as committed.
        [switch]$NoUpdate
    )

    Test-Po4aSubmodule

    $keepArg = if ($Force) { ' --keep 0' } else { '' }
    $pkgVerArg = if ($PackageVersion) { " --package-version $PackageVersion" } else { '' }
    $noUpdateArg = if ($NoUpdate) { ' --no-update' } else { '' }

    if ($IsWindows) {
        if (-not (Get-Command wsl -ErrorAction SilentlyContinue)) {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.InvalidOperationException]::new(
                        "WSL is required to run po4a on Windows but was not found."
                    ),
                    'WslNotFound',
                    [System.Management.Automation.ErrorCategory]::ObjectNotFound,
                    $null
                )
            )
        }
        # wslpath cannot handle Windows paths passed as arguments (backslashes
        # are stripped). Use Push-Location + "wslpath -a ." instead.
        Push-Location $repoRoot
        try {
            $wslRoot = (wsl wslpath -a .).Trim()
            # PERL_UNICODE=SDA: decode @ARGV + default open() layers as UTF-8 so po4a reads the .cfg's
            # non-ASCII --copyright-holder correctly (otherwise it double-encodes it into the .pot header).
            $cmd = "cd '$wslRoot' && PERL_UNICODE=SDA PERLLIB=tools/po4a/lib tools/po4a/po4a $ConfigPath$pkgVerArg$keepArg$noUpdateArg"

            if ($DryRun) {
                Write-Host "[DryRun] wsl -e bash -c `"$cmd`""
            } else {
                Write-Host "Running po4a: $ConfigPath"
                wsl -e bash -c $cmd
                if ($LASTEXITCODE -ne 0) {
                    throw "po4a failed for $ConfigPath (exit code $LASTEXITCODE)"
                }
            }
        } finally {
            Pop-Location
        }
    } else {
        $po4aExe = Join-Path $po4aSubmodule 'po4a'
        $perlLib = Join-Path $po4aSubmodule 'lib'
        $fullConfigPath = Join-Path $repoRoot $ConfigPath

        # Build the argument vector once so the -DryRun echo cannot drift from what is actually run.
        $po4aArgs = @($fullConfigPath)
        if ($PackageVersion) { $po4aArgs += '--package-version'; $po4aArgs += $PackageVersion }
        if ($Force)          { $po4aArgs += '--keep'; $po4aArgs += '0' }
        if ($NoUpdate)       { $po4aArgs += '--no-update' }

        if ($DryRun) {
            Write-Host "[DryRun] PERL_UNICODE=SDA PERLLIB=$perlLib $po4aExe $($po4aArgs -join ' ')"
        } else {
            Write-Host "Running po4a: $ConfigPath"
            # PERL_UNICODE=SDA: see the Windows branch — force UTF-8 so the non-ASCII
            # --copyright-holder is not double-encoded. Restored in the finally so the caller's
            # session is left exactly as it was found (a script run in-process shares it).
            $priorPerlLib = $env:PERLLIB
            $priorPerlUnicode = $env:PERL_UNICODE
            try {
                $env:PERLLIB = $perlLib
                $env:PERL_UNICODE = 'SDA'
                & $po4aExe @po4aArgs
                if ($LASTEXITCODE -ne 0) {
                    throw "po4a failed for $ConfigPath (exit code $LASTEXITCODE)"
                }
            } finally {
                # [NullString]::Value *removes* the variable; $null would bind to [string] as '' and
                # leave it empty-but-present, so a consumer's default-when-unset never fires.
                foreach ($restore in @(
                        @{ Name = 'PERLLIB';      Value = $priorPerlLib },
                        @{ Name = 'PERL_UNICODE'; Value = $priorPerlUnicode })) {
                    $value = if ($null -eq $restore.Value) { [NullString]::Value } else { $restore.Value }
                    [Environment]::SetEnvironmentVariable($restore.Name, $value, 'Process')
                }
            }
        }
    }
}

function Get-Po4aCatalogPath {
    # The .pot and per-language .po paths a po4a config declares, repo-relative. Both the template
    # header repair and the .po restore need these, and two copies of the parsing would diverge.
    param([Parameter(Mandatory)][string]$ConfigPath)

    $langs = @(); $potRel = $null; $poPattern = $null
    foreach ($l in (Get-Content -LiteralPath $ConfigPath)) {
        if     ($l -match '^\[po4a_langs\]\s+(.+)$')                { $langs = ($Matches[1].Trim() -split '\s+') }
        elseif ($l -match '^\[po4a_paths\]\s+(\S+)\s+\$lang:(\S+)') { $potRel = $Matches[1]; $poPattern = $Matches[2] }
    }

    $po = [ordered]@{}
    if ($poPattern) {
        foreach ($lang in $langs) { $po[$lang] = ($poPattern -replace '\$lang', $lang) }
    }
    [pscustomobject]@{ Pot = $potRel; Po = $po }
}

function Get-WeblateOwnedPoPath {
    # The Weblate-owned catalogues a step is about to overwrite, repo-relative. Two sources, because
    # the generators that write them are of two kinds: the po4a configs declare theirs in the .cfg,
    # while the antibiotic catalogue is produced by a NeoIPC-Tools cmdlet with no such declaration.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Config')][string]$ConfigPath,
        [Parameter(Mandatory, ParameterSetName = 'Glob')][string]$Glob
    )

    if ($PSCmdlet.ParameterSetName -eq 'Config') {
        return @((Get-Po4aCatalogPath -ConfigPath $ConfigPath).Po.Values)
    }
    @(Get-ChildItem -Path (Join-Path $repoRoot $Glob) -File -ErrorAction SilentlyContinue |
        ForEach-Object { [System.IO.Path]::GetRelativePath($repoRoot, $_.FullName) -replace '\\', '/' })
}

function Assert-CleanWeblatePo {
    # Weblate owns these .po files, so the pipeline restores them after a generator writes them (see
    # Restore-WeblateOwnedPo). That restore is a `git restore`, which would silently destroy any
    # uncommitted work already in the tree — so refuse to start when there is some. There is
    # deliberately no override switch: -Force already means --keep 0, and losing a translator's
    # in-progress edit is not a thing to make convenient.
    param([Parameter(Mandatory)][string[]]$RelativePath)

    $paths = $RelativePath
    if (-not $paths) { return }

    $dirty = @(git -C $repoRoot status --porcelain -- @paths | Where-Object { $_ })
    if ($dirty) {
        throw ("Weblate-owned .po files have uncommitted changes; refusing to run because the " +
               "post-po4a restore would discard them:`n  " + (($dirty | ForEach-Object { $_.Trim() }) -join "`n  ") +
               "`nCommit, stash or discard them first.")
    }
}

function Restore-WeblateOwnedPo {
    # Every generator here rewrites the .po files as a side effect of producing its .pot: po4a because
    # "The PO files are always re-generated based on the POT with msgmerge -U" (its own docs) with no
    # flag to suppress only that, and Export-NeoIPCAntibioticTranslation because it msgmerges each
    # existing locale in code. Weblate is their only writer, so restore them from HEAD once the
    # generator has produced the localized artifacts. This is what keeps the repository out of the
    # header hunk Weblate also writes.
    param([Parameter(Mandatory)][string[]]$RelativePath)

    $declared = @($RelativePath)
    if (-not $declared) { return }

    # `git restore` is atomic over its pathspec: a single path HEAD does not carry aborts the whole
    # command, so every other catalogue would be left exactly as po4a's msgmerge rewrote it — the
    # two-writer state this exists to prevent. Adding a language to [po4a_langs] does precisely that,
    # because po4a msginits a catalogue for it that HEAD has never seen. So partition first.
    $inHead = @(git -C $repoRoot ls-tree -r --name-only HEAD -- @declared)
    $tracked = @($declared | Where-Object { $inHead -contains $_ })
    $created = @($declared | Where-Object { $inHead -notcontains $_ -and (Test-Path (Join-Path $repoRoot $_)) })

    if ($tracked) {
        git -C $repoRoot restore --source=HEAD --worktree -- @tracked
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to restore Weblate-owned .po files after po4a (git restore exit code $LASTEXITCODE)."
        }
    }

    # A catalogue po4a created for a language HEAD does not carry is the repository authoring a .po,
    # which is Weblate's job — it adds a language from the .pot. Delete it rather than commit it.
    foreach ($rel in $created) {
        Remove-Item -LiteralPath (Join-Path $repoRoot $rel) -Force
        Write-Host "  removed $rel (po4a created it; Weblate adds new languages from the .pot)"
    }
}

function Repair-Po4aTemplateHeader {
    # po4a emits gettext-boilerplate file headers ("SOME DESCRIPTIVE TITLE", "Copyright (C) YEAR ...",
    # "same license as the PACKAGE package", "FIRST AUTHOR ...") and offers no way to set a custom
    # header, so this rewrites the leading comment block of the .pot it generated for one config into
    # the NeoIPC house style (matching po/glossary.pot): title / copyright / license / "Automatically
    # generated". Idempotent. The .po files are Weblate's, and are not touched.
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$Package,
        [Parameter(Mandatory)][string]$License
    )
    $copyrightLine = "# Copyright (C) $copyrightHolder"
    $licenseLine   = "# This file is distributed under the $License license"
    $utf8NoBom     = [System.Text.UTF8Encoding]::new($false)

    $potRel = (Get-Po4aCatalogPath -ConfigPath $ConfigPath).Pot

    # Split a catalog into (leading comment lines, body starting at `msgid ""`). $null if no header entry.
    function Split-Catalog([string]$Path) {
        if (-not (Test-Path -LiteralPath $Path)) { return $null }
        $lines = ((Get-Content -LiteralPath $Path -Raw) -replace "`r`n", "`n") -split "`n"
        $i = 0; while ($i -lt $lines.Count -and $lines[$i] -ne 'msgid ""') { $i++ }
        if ($i -ge $lines.Count) { return $null }
        [pscustomobject]@{ Comment = @($lines[0..($i - 1)]); Body = @($lines[$i..($lines.Count - 1)]) }
    }
    function Save-Catalog([string]$Path, [string[]]$Comment, [string[]]$Body) {
        [System.IO.File]::WriteAllText($Path, (($Comment + $Body) -join "`n"), $utf8NoBom)
    }

    # --- .pot ---
    if ($potRel) {
        $potPath = Join-Path $repoRoot $potRel
        $h = Split-Catalog $potPath
        if ($h) {
            $comment = @("# Translations for the $Package", $copyrightLine, $licenseLine, "# Automatically generated")
            # Match glossary.pot's header metadata (po4a leaves author placeholders in the .pot).
            $body = @($h.Body | ForEach-Object {
                $_ -replace '^"Last-Translator: .*\\n"$', '"Last-Translator: Automatically generated\n"' `
                   -replace '^"Language-Team: .*\\n"$',   '"Language-Team: none\n"'
            })
            Save-Catalog $potPath $comment $body
        }
    }

}

function Invoke-UpdateYamlKeys {
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath
    )

    $script = Join-Path $PSScriptRoot 'Update-Po4aYamlKeys.ps1'
    $fullConfigPath = Join-Path $repoRoot $ConfigPath

    Write-Host "Updating YAML keys: $ConfigPath"
    $yamlKeysArgs = @{ ConfigFile = $fullConfigPath }
    if ($DryRun) { $yamlKeysArgs['DryRun'] = $true }
    & $script @yamlKeysArgs
}

function Invoke-UpdateGlossary {
    $python = Find-Python
    $script = Join-Path $repoRoot 'scripts' 'update-glossary-po.py'

    $glossaryArgs = @($script, '--generate-yaml')
    if ($Force) { $glossaryArgs += '--threshold'; $glossaryArgs += '0' }

    if ($DryRun) {
        Write-Host "[DryRun] $python $($glossaryArgs -join ' ')"
    } else {
        Write-Host "Updating glossary PO and generating localized YAML"
        Push-Location $repoRoot
        try {
            & $python @glossaryArgs
            if ($LASTEXITCODE -ne 0) {
                throw "update-glossary-po.py failed (exit code $LASTEXITCODE)"
            }
        } finally {
            Pop-Location
        }
    }
}

function Invoke-AntibioticTranslation {
    # Regenerate po/antibiotics.pot (+ msgmerge the existing po/antibiotics.<locale>.po) from the canonical
    # antibiotic sources via the NeoIPC-Tools module. Pure PowerShell — no po4a, no Python. The antibiotic domain
    # is its own bilingual gettext component keyed by the English name (see metadata/common/antibiotics/README.md).
    $module = Join-Path $repoRoot 'scripts' 'modules' 'NeoIPC-Tools'

    if ($DryRun) {
        Write-Host "[DryRun] Import-Module $module; Export-NeoIPCAntibioticTranslation"
    } else {
        Write-Host "Updating antibiotic translation catalogue (po/antibiotics.pot + .po)"
        Import-Module -Name $module -Force -Verbose:$false
        $result = Export-NeoIPCAntibioticTranslation
        # Deliberately not reporting UpdatedLocales: the exporter does rewrite each locale, but the
        # caller restores them, so naming them here would tell the reader the opposite of what lands.
        Write-Host ("  antibiotics.pot: {0} strings" -f $result.StringCount)
    }
}

function Invoke-FixStringLayers {
    $script = Join-Path $PSScriptRoot 'Test-StringResourceLayers.ps1'

    if ($DryRun) {
        Write-Host "[DryRun] Test-StringResourceLayers.ps1 -Fix"
    } else {
        Write-Host "Fixing string layer duplicates"
        & $script -Fix
    }
}

function Invoke-TestStringLayers {
    $script = Join-Path $PSScriptRoot 'Test-StringResourceLayers.ps1'

    Write-Host "Checking string layer duplicates (read-only)"
    & $script
    return $LASTEXITCODE
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

if ($Update) {
    $runLayers      = $Config -eq 'all' -or $Config -eq 'glossary'
    $runPo4a        = $Config -eq 'all' -or $po4aConfigs -contains $Config
    $runGlossary    = $Config -eq 'all' -or $Config -eq 'glossary'
    $runAntibiotics = $Config -eq 'all' -or $Config -eq 'antibiotics'

    # Step 1: Validate/fix string layers (may move keys between YAML files)
    if ($runLayers) {
        if ($NonInteractive) {
            $rc = Invoke-TestStringLayers
            if ($rc -ne 0) {
                Write-Error "String layer validation failed (exit code $rc). Fix duplicates before running -NonInteractive -Update."
                exit $rc
            }
        } else {
            Invoke-FixStringLayers
        }
    }

    # Step 2-3: Update YAML keys then run po4a. po4a msgmerges the .po files as a side effect and
    # offers no way to suppress only that, so they are restored from HEAD afterwards — Weblate is
    # their only writer. The restore runs in a finally so a po4a failure cannot leave them rewritten.
    if ($runPo4a) {
        $targets = if ($Config -eq 'all') { $po4aConfigs } else { @($Config) }
        foreach ($target in $targets) {
            $cfgPath = $configMap[$target]
            $fullCfgPath = Join-Path $repoRoot $cfgPath
            $ownedPo = if ($weblateOwnedPo4aConfigs -contains $target) {
                Get-WeblateOwnedPoPath -ConfigPath $fullCfgPath
            } else { @() }
            if ($ownedPo -and -not $DryRun) { Assert-CleanWeblatePo -RelativePath $ownedPo }
            Invoke-UpdateYamlKeys -ConfigPath $cfgPath
            $pkgVer = if ($versionFileMap.ContainsKey($target)) {
                (Get-Content -LiteralPath (Join-Path $repoRoot $versionFileMap[$target]) -Raw).Trim()
            } else { $null }
            try {
                Invoke-Po4a -ConfigPath $cfgPath -PackageVersion $pkgVer
            } finally {
                if ($ownedPo -and -not $DryRun) { Restore-WeblateOwnedPo -RelativePath $ownedPo }
            }
            if (-not $DryRun -and $catalogHeaderMap.ContainsKey($target)) {
                $hdr = $catalogHeaderMap[$target]
                Repair-Po4aTemplateHeader -ConfigPath $fullCfgPath -Package $hdr.Package -License $hdr.License
            }
        }
    }

    # Step 4: Update glossary
    if ($runGlossary) {
        Invoke-UpdateGlossary
    }

    # Step 5: Update the antibiotic translation catalogue (NeoIPC-Tools, not po4a). Its exporter
    # msgmerges every existing po/antibiotics.<locale>.po in code, and those are Weblate-owned, so the
    # same clean-tree assertion and restore apply here as to po4a. Without them a plain -Update leaves
    # Weblate's header fields overwritten with the exporter's placeholders, and the developer who then
    # commits is rejected by the catalogue-ownership gate.
    if ($runAntibiotics) {
        $antibioticPo = if ($DryRun) { @() } else { Get-WeblateOwnedPoPath -Glob 'po/antibiotics.*.po' }
        if ($antibioticPo) { Assert-CleanWeblatePo -RelativePath $antibioticPo }
        try {
            Invoke-AntibioticTranslation
        } finally {
            if ($antibioticPo) { Restore-WeblateOwnedPo -RelativePath $antibioticPo }
        }
    }

    Write-Host "`nLocalization update complete."
}
elseif ($Render) {
    # Render-only: po4a --no-update ("Do not change the POT and PO files, only the translation may be
    # updated"). Produces the localized artifacts from the catalogues exactly as committed, writing
    # neither .pot nor .po — so it needs no clean-tree assertion and no restore.
    #
    # Restricted to the po4a configs. The glossary and antibiotic catalogues are produced by
    # generators that regenerate their .pot/.po in the same pass and have no equivalent read-only
    # mode, so -Render cannot honour its contract for them.
    if ($po4aConfigs -notcontains $Config -and $Config -ne 'all') {
        throw "-Render supports the po4a configs ($($po4aConfigs -join ', ')) or 'all'; '$Config' is generated by a different tool."
    }

    $targets = if ($Config -eq 'all') { $po4aConfigs } else { @($Config) }
    foreach ($target in $targets) {
        $pkgVer = if ($versionFileMap.ContainsKey($target)) {
            (Get-Content -LiteralPath (Join-Path $repoRoot $versionFileMap[$target]) -Raw).Trim()
        } else { $null }
        Invoke-Po4a -ConfigPath $configMap[$target] -PackageVersion $pkgVer -NoUpdate
    }

    Write-Host "`nLocalized artifacts rendered; catalogues untouched."
}
elseif ($Test) {
    exit (Invoke-TestStringLayers)
}
