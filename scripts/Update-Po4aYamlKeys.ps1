#!/usr/bin/env pwsh
#Requires -Version 7.6

<#
.SYNOPSIS
    Refreshes the explicit YAML key list in a po4a config so nested keys are actually extracted.

.DESCRIPTION
    po4a's YAML module extracts only the values whose keys are named in the config's keys option. Nested
    keys are therefore invisible to it unless listed — a string resource one level down is silently left
    untranslated, with no error to indicate it. This walks each YAML master listed in the config, collects
    every key recursively, and rewrites that option.

    Run it after changing the structure of a string-resource file, not merely its text: adding a key is
    what needs the config updated, editing an existing value is not.

    The config is rewritten with LF line endings regardless of platform, because po4a reads and writes the
    same file in LF and a CRLF rewrite here would show the config as modified on every pipeline run.

.PARAMETER ConfigFile
    The po4a config to update.

.PARAMETER DryRun
    Print the resulting config instead of writing it.

.EXAMPLE
    ./scripts/Update-Po4aYamlKeys.ps1 -ConfigFile po/reports.po4a.cfg

.EXAMPLE
    ./scripts/Update-Po4aYamlKeys.ps1 -ConfigFile po/reports.po4a.cfg -DryRun
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$ConfigFile,

    [switch]$DryRun
)

Import-Module powershell-yaml

# -------------------------------------------------
# Recursively collect YAML keys
# -------------------------------------------------
function Get-YamlKeysRecursive {
    param($Node)

    $keys = @()

    if ($Node -is [System.Collections.IDictionary]) {
        foreach ($k in $Node.Keys) {
            $keys += $k
            $keys += Get-YamlKeysRecursive $Node[$k]
        }
    }
    elseif ($Node -is [System.Collections.IEnumerable] -and -not ($Node -is [string])) {
        foreach ($item in $Node) {
            $keys += Get-YamlKeysRecursive $item
        }
    }

    return $keys
}

# -------------------------------------------------
# Extract exclude keys from inline comment
# -------------------------------------------------
function Get-ExcludedKeys {
    param($line)

    if ($line -match '#\s*exclude:\s*(.+)$') {
        return $Matches[1] -split '\s+'
    }

    return @()
}

# -------------------------------------------------
# Replace or insert keys option safely
# -------------------------------------------------
function Update-KeysOption {
    param(
        [string]$Line,
        [string]$KeyString
    )

    $newOpt = "opt:`"-o keys='$KeyString'`""

    # CASE 1: replace existing keys option
    if ($Line -match 'opt:"-o keys=''[^'']*''"') {
        return ($Line -replace 'opt:"-o keys=''[^'']*''"', $newOpt)
    }

    # CASE 2: no keys yet → insert before comment if present
    $parts = $Line -split '#', 2

    if ($parts.Count -eq 2) {
        return "$($parts[0].TrimEnd()) $newOpt #$($parts[1])"
    }
    else {
        return "$Line $newOpt"
    }
}

# -------------------------------------------------
# Main
# -------------------------------------------------
$lines = Get-Content $ConfigFile
$newLines = @()

foreach ($line in $lines) {

    if ($line -match '^\[type:\s*yaml\]\s+([^\s]+)') {

        # Skip lines with manual-keys marker — these have a curated key list
        if ($line -match '#\s*manual-keys') {
            Write-Host "Skipping (manual-keys): $($Matches[1])"
            $newLines += $line
            continue
        }

        $yamlPath = $Matches[1]

        if (-not (Test-Path $yamlPath)) {
            $newLines += $line
            continue
        }

        Write-Host "Processing $yamlPath"

        $yaml = Get-Content $yamlPath -Raw | ConvertFrom-Yaml

        $allKeys = Get-YamlKeysRecursive $yaml |
                   Where-Object { $_ } |
                   Sort-Object -Unique

        $exclude = Get-ExcludedKeys $line

        $keys = $allKeys | Where-Object { $exclude -notcontains $_ }

        $keyString = ($keys -join " ")

        $updatedLine = Update-KeysOption -Line $line -KeyString $keyString

        $newLines += $updatedLine
    }
    else {
        $newLines += $line
    }
}

if ($DryRun) {
    $newLines | Out-Host
}
else {
    # Not Set-Content: it joins pipeline items with [Environment]::NewLine and appends one more, so
    # on Windows it rewrote this COMMITTED po4a config in CRLF on every pipeline run — a file po4a
    # itself reads and writes in LF. The result was a config that showed as modified with an
    # apparently empty content diff, because git's text=auto normalizes it straight back on commit.
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($ConfigFile, (($newLines -join "`n") + "`n"), $utf8NoBom)
    Write-Host "Config updated successfully."
}
