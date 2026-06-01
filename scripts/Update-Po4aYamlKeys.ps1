#!/usr/bin/env pwsh

param(
    [Parameter(Mandatory=$true)]
    [string]$ConfigFile,

    [switch]$DryRun
)

Import-Module powershell-yaml -ErrorAction Stop

$configFullPath = (Resolve-Path -LiteralPath $ConfigFile -ErrorAction Stop).Path
$configDir = Split-Path -Parent $configFullPath

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

    # Match only the trailing comment, anchored after the close of the last
    # quoted opt:"…" clause. Without that anchor, `exclude:` substrings that
    # happen to appear inside a quoted keys='…' list (e.g. a YAML key like
    # `excluded_taxa`) would silently steal real keys from the next regen.
    if ($line -match '"[^"]*"\s+#\s*exclude:\s*(.+)$' -or
        $line -match '^[^"]*#\s*exclude:\s*(.+)$') {
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
$lines = Get-Content -LiteralPath $configFullPath
$newLines = @()

foreach ($line in $lines) {

    if ($line -match '^\[type:\s*yaml\]\s+([^\s]+)') {

        $yamlPath = $Matches[1]

        # po4a paths in [type: yaml] lines are relative to the config file.
        # Resolve against the config's directory so the script works regardless
        # of the caller's cwd. Absolute paths pass through Join-Path unchanged.
        $yamlFullPath = if ([System.IO.Path]::IsPathRooted($yamlPath)) {
            $yamlPath
        } else {
            Join-Path $configDir $yamlPath
        }

        if (-not (Test-Path -LiteralPath $yamlFullPath)) {
            $newLines += $line
            continue
        }

        Write-Host "Processing $yamlPath"

        $yaml = Get-Content -LiteralPath $yamlFullPath -Raw | ConvertFrom-Yaml

        $allKeys = Get-YamlKeysRecursive $yaml |
                   Where-Object { $_ } |
                   Sort-Object -Unique

        $exclude = Get-ExcludedKeys $line

        $keys = $allKeys | Where-Object { $exclude -notcontains $_ }

        if (-not $keys -or $keys.Count -eq 0) {
            Write-Warning "No translatable keys found in $yamlPath after filtering; leaving line unchanged so po4a's default key behaviour is preserved."
            $newLines += $line
            continue
        }

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
    $newLines | Set-Content -LiteralPath $configFullPath -Encoding utf8NoBOM
    Write-Host "Config updated successfully."
}
