#!/usr/bin/env pwsh

<#
.SYNOPSIS
    Unified wrapper for the NeoIPC localization toolchain.

.DESCRIPTION
    Wraps po4a, the glossary script, YAML key extraction, and string layer
    validation into a single entry point with tab-completable parameters.

    Update pipeline (default -Config all):
      1. Fix string layer duplicates (Test-StringResourceLayers.ps1 -Fix)
      2. Update YAML keys in po4a configs (Update-Po4aYamlKeys.ps1)
      3. Run po4a to extract/generate localized files
      4. Update glossary PO and generate localized YAML

    Test mode:
      Runs string layer validation in read-only mode.

.PARAMETER Update
    Run the update pipeline.

.PARAMETER Test
    Run read-only string layer validation.

.PARAMETER Config
    Which configuration to update. Default: all.
    - reports:            po/reports.po4a.cfg
    - documentation:      po/documentation.po4a.cfg
    - infectious_agents:  po/infectious_agents.po4a.cfg
    - scripts:            scripts/po4a.cfg
    - glossary:           glossary via update-glossary-po.py
    - antibiotics:        po/antibiotics.pot + .po via NeoIPC-Tools Export-NeoIPCAntibioticTranslation
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
    Run the full pipeline for all configs.

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

    [Parameter(Mandatory, ParameterSetName = 'Test')]
    [switch]$Test,

    [Parameter(ParameterSetName = 'Update')]
    [ValidateSet('reports', 'documentation', 'infectious_agents', 'scripts', 'glossary', 'antibiotics', 'all')]
    [string]$Config = 'all',

    [Parameter(ParameterSetName = 'Update')]
    [switch]$Force,

    [Parameter(ParameterSetName = 'Update')]
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
        [string]$ConfigPath
    )

    Test-Po4aSubmodule

    $keepArg = if ($Force) { ' --keep 0' } else { '' }

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
            $cmd = "cd '$wslRoot' && PERLLIB=tools/po4a/lib tools/po4a/po4a $ConfigPath$keepArg"

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
        $env:PERLLIB = Join-Path $po4aSubmodule 'lib'
        $po4aExe = Join-Path $po4aSubmodule 'po4a'
        $fullConfigPath = Join-Path $repoRoot $ConfigPath

        if ($DryRun) {
            Write-Host "[DryRun] PERLLIB=$($env:PERLLIB) $po4aExe $fullConfigPath$keepArg"
        } else {
            Write-Host "Running po4a: $ConfigPath"
            $args = @($fullConfigPath)
            if ($Force) { $args += '--keep'; $args += '0' }
            & $po4aExe @args
            if ($LASTEXITCODE -ne 0) {
                throw "po4a failed for $ConfigPath (exit code $LASTEXITCODE)"
            }
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
        Write-Host ("  antibiotics.pot: {0} strings; updated locales: {1}" -f $result.StringCount, (($result.UpdatedLocales -join ', ')))
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

    # Step 2-3: Update YAML keys then run po4a
    if ($runPo4a) {
        $targets = if ($Config -eq 'all') { $po4aConfigs } else { @($Config) }
        foreach ($target in $targets) {
            $cfgPath = $configMap[$target]
            Invoke-UpdateYamlKeys -ConfigPath $cfgPath
            Invoke-Po4a -ConfigPath $cfgPath
        }
    }

    # Step 4: Update glossary
    if ($runGlossary) {
        Invoke-UpdateGlossary
    }

    # Step 5: Update the antibiotic translation catalogue (NeoIPC-Tools, not po4a)
    if ($runAntibiotics) {
        Invoke-AntibioticTranslation
    }

    Write-Host "`nLocalization update complete."
}
elseif ($Test) {
    exit (Invoke-TestStringLayers)
}
