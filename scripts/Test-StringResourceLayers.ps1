#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Detects duplicate string values across YAML string resource layers.

.DESCRIPTION
    Scans glossary.yaml, reports/common.yaml, and each report's content/_sR.yaml
    for string values that appear in more than one layer, across different reports,
    or at multiple key paths within the same file.

    In detection mode (default), prints duplicate groups with R code references
    and exits with non-zero status if violations are found.

    In fix mode (-Fix), interactively offers to delete duplicates from lower
    layers, move shared strings to common.yaml, or consolidate intra-file
    duplicates — with optional auto-replacement of R code references.

.PARAMETER Fix
    Enable interactive fix mode.

.PARAMETER ReportFilter
    Limit checking to a single report (e.g., "Patient-Data-Report").

.PARAMETER AllowlistPath
    Path to the allowlist file. Defaults to po/string-layer-allowlist.txt.
#>
param(
    [switch]$Fix,
    [string]$ReportFilter,
    [string]$AllowlistPath
)

Import-Module powershell-yaml

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -------------------------------------------------
# Resolve paths relative to the repo root
# -------------------------------------------------
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path (Join-Path $repoRoot 'glossary.yaml'))) {
    Write-Error "Cannot locate repository root. Run this script from the Surveillance-Toolkit directory or its scripts/ subdirectory."
    exit 1
}

$glossaryPath = Join-Path $repoRoot 'glossary.yaml'
$commonPath   = Join-Path $repoRoot 'reports' 'common.yaml'
$reportsDir   = Join-Path $repoRoot 'reports'

if (-not $AllowlistPath) {
    $AllowlistPath = Join-Path $repoRoot 'po' 'string-layer-allowlist.txt'
}

# =========================================================
# Function definitions
# =========================================================

# -------------------------------------------------
# Recursively flatten YAML into (dotted-key-path, string-value) pairs
# -------------------------------------------------
function Get-FlattenedStrings {
    param(
        $Node,
        [string]$Prefix = ''
    )

    $results = @()

    if ($Node -is [System.Collections.IDictionary]) {
        foreach ($k in $Node.Keys) {
            $path = if ($Prefix) { "$Prefix.$k" } else { "$k" }
            $results += Get-FlattenedStrings -Node $Node[$k] -Prefix $path
        }
    }
    elseif ($Node -is [System.Collections.IEnumerable] -and -not ($Node -is [string])) {
        $i = 0
        foreach ($item in $Node) {
            $path = if ($Prefix) { "$Prefix[$i]" } else { "[$i]" }
            if ($item -is [string]) {
                $results += [PSCustomObject]@{
                    KeyPath = $path
                    Value   = $item
                }
            } else {
                $results += Get-FlattenedStrings -Node $item -Prefix $path
            }
            $i++
        }
    }
    elseif ($Node -is [string]) {
        $results += [PSCustomObject]@{
            KeyPath = $Prefix
            Value   = $Node
        }
    }

    return $results
}

# -------------------------------------------------
# Parse a YAML file and return flattened entries with metadata
# -------------------------------------------------
function Get-YamlEntries {
    param(
        [string]$FilePath,
        [string]$Layer,       # 'glossary', 'common', or 'report'
        [string]$ReportName   # only for report layer
    )

    if (-not (Test-Path $FilePath)) { return @() }

    $yaml = Get-Content $FilePath -Raw | ConvertFrom-Yaml
    if (-not $yaml) { return @() }

    $flat = Get-FlattenedStrings -Node $yaml

    foreach ($entry in $flat) {
        $entry | Add-Member -NotePropertyName 'FilePath' -NotePropertyValue $FilePath
        $entry | Add-Member -NotePropertyName 'Layer' -NotePropertyValue $Layer
        $entry | Add-Member -NotePropertyName 'ReportName' -NotePropertyValue $ReportName
        $entry | Add-Member -NotePropertyName 'RelPath' -NotePropertyValue (
            [System.IO.Path]::GetRelativePath($repoRoot, $FilePath) -replace '\\', '/'
        )
    }

    return $flat
}

# -------------------------------------------------
# Find the line number of a key path in a YAML file
# -------------------------------------------------
function Find-YamlKeyLine {
    param(
        [string]$FilePath,
        [string]$KeyPath
    )

    # Strip array indices — line search only works for dict keys
    $segments = @(($KeyPath -replace '\[\d+\]', '') -split '\.' | Where-Object { $_ })
    if ($segments.Count -eq 0) { return $null }

    $lines = @(Get-Content $FilePath)
    $currentIndent = 0
    $segIndex = 0

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match '^(\s*)(\S.*)') {
            $indent = $Matches[1].Length
            $content = $Matches[2]

            if ($segIndex -lt $segments.Count) {
                $targetKey = $segments[$segIndex]
                $escapedKey = [regex]::Escape($targetKey)
                if ($indent -eq $currentIndent -and $content -match "^[`"']?$escapedKey[`"']?\s*:") {
                    $segIndex++
                    if ($segIndex -eq $segments.Count) {
                        return $i + 1  # 1-based line number
                    }
                    $currentIndent = $indent + 2
                }
            }
        }
    }

    return $null
}

# -------------------------------------------------
# Build regex pattern for an R accessor chain
# -------------------------------------------------
function Build-AccessorRegex {
    param(
        [string]$KeyPath,
        [string]$VarName = 'sR'
    )

    $segments = $KeyPath -split '\.'
    $pattern = [regex]::Escape($VarName)

    foreach ($seg in $segments) {
        $escapedSeg = [regex]::Escape($seg)
        $isBareValid = $seg -match '^[a-zA-Z_.][a-zA-Z0-9_.]*$'

        $accessors = @()
        if ($isBareValid) {
            $accessors += "\`$$escapedSeg\b"
        }
        # Backtick-quoted $
        $accessors += "\`$``$escapedSeg``"
        # Double-quoted bracket
        $accessors += "\[\[`"$escapedSeg`"\]\]"
        # Single-quoted bracket
        $accessors += "\[\['$escapedSeg'\]\]"

        $pattern += "(?:" + ($accessors -join '|') + ")"
    }

    return $pattern
}

# -------------------------------------------------
# Search R/QMD files for references to a key path
# -------------------------------------------------
function Find-RCodeReferences {
    param(
        [string]$KeyPath,
        [string]$SearchDir
    )

    # Skip array-indexed paths — they don't appear as R accessors
    if ($KeyPath -match '\[') { return @() }

    $results = @()
    $pattern = Build-AccessorRegex -KeyPath $KeyPath -VarName 'sR'

    $files = Get-ChildItem -Path $SearchDir -Recurse -Include '*.qmd', '*.R', '*.Rmd' -File

    foreach ($file in $files) {
        $lines = @(Get-Content $file.FullName)
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match $pattern) {
                $relPath = [System.IO.Path]::GetRelativePath($repoRoot, $file.FullName) -replace '\\', '/'
                $results += [PSCustomObject]@{
                    File    = $relPath
                    Line    = $i + 1
                    Content = $lines[$i].Trim()
                }
            }
        }
    }

    return $results
}

# -------------------------------------------------
# Upfront scan: extract all sR accessor chains from R/QMD/Rmd files
# Returns a hashtable: dotted-key-path → array of references
# -------------------------------------------------
function Get-AllRCodeReferences {
    param(
        [string]$SearchDir
    )

    $refMap = @{}
    $files = Get-ChildItem -Path $SearchDir -Recurse -Include '*.qmd', '*.R', '*.Rmd' -File

    # Regex to match sR followed by one or more accessor segments
    $chainPattern = '(?<!\w)sR((?:\$`[^`]+`|\$[a-zA-Z_.][a-zA-Z0-9_.]*|\[\["[^"]+"\]\]|\[\[''[^'']+'']\])+)'

    # Regex to parse individual accessor segments from a chain
    $segPattern = '\$`([^`]+)`|\$([a-zA-Z_.][a-zA-Z0-9_.]*)\b|\[\["([^"]+)"\]\]|\[\[''([^'']+)''\]\]'

    foreach ($file in $files) {
        $relPath = [System.IO.Path]::GetRelativePath($SearchDir, $file.FullName) -replace '\\', '/'
        $lines = @(Get-Content $file.FullName)

        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            $chainMatches = [regex]::Matches($line, $chainPattern)

            foreach ($m in $chainMatches) {
                $chain = $m.Groups[1].Value

                # Parse individual segments
                $segMatches = [regex]::Matches($chain, $segPattern)
                $segments = @()

                foreach ($sm in $segMatches) {
                    if ($sm.Groups[1].Success) { $segments += $sm.Groups[1].Value }      # $`key`
                    elseif ($sm.Groups[2].Success) { $segments += $sm.Groups[2].Value }   # $key
                    elseif ($sm.Groups[3].Success) { $segments += $sm.Groups[3].Value }   # [["key"]]
                    elseif ($sm.Groups[4].Success) { $segments += $sm.Groups[4].Value }   # [['key']]
                }

                if ($segments.Count -gt 0) {
                    $keyPath = $segments -join '.'
                    $ref = [PSCustomObject]@{
                        File    = $relPath
                        Line    = $i + 1
                        Content = $line.Trim()
                    }

                    if (-not $refMap.ContainsKey($keyPath)) {
                        $refMap[$keyPath] = @()
                    }
                    $refMap[$keyPath] += $ref
                }
            }
        }
    }

    return $refMap
}

# -------------------------------------------------
# Remove a YAML key and its children from a file
# -------------------------------------------------
function Remove-YamlKey {
    param(
        [string]$FilePath,
        [string]$KeyPath
    )

    $segments = $KeyPath -split '\.'
    $lines = @(Get-Content $FilePath)
    $newLines = @()
    $removing = $false
    $removeIndent = -1
    $currentIndent = 0
    $segIndex = 0
    $targetLineIndex = -1

    # First pass: find the target line
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match '^(\s*)(\S.*)') {
            $indent = $Matches[1].Length
            $content = $Matches[2]

            if ($segIndex -lt $segments.Count) {
                $targetKey = $segments[$segIndex]
                $escapedKey = [regex]::Escape($targetKey)
                if ($indent -eq $currentIndent -and $content -match "^[`"']?$escapedKey[`"']?\s*:") {
                    $segIndex++
                    if ($segIndex -eq $segments.Count) {
                        $targetLineIndex = $i
                        $removeIndent = $indent
                        break
                    }
                    $currentIndent = $indent + 2
                }
            }
        }
    }

    if ($targetLineIndex -eq -1) {
        Write-Warning "Could not find key '$KeyPath' in $FilePath — remove manually"
        return $false
    }

    # Second pass: remove the key and its children
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($i -eq $targetLineIndex) {
            $removing = $true
            continue
        }

        if ($removing) {
            if ($lines[$i] -match '^(\s*)(\S)') {
                $indent = $Matches[1].Length
                if ($indent -le $removeIndent) {
                    $removing = $false
                    $newLines += $lines[$i]
                }
            }
            elseif ($lines[$i].Trim() -eq '') {
                # blank line while removing — skip
            }
        }
        else {
            $newLines += $lines[$i]
        }
    }

    $newLines | Set-Content $FilePath
    return $true
}

# -------------------------------------------------
# Add a YAML key+value to a file
# -------------------------------------------------
function Add-YamlKey {
    param(
        [string]$FilePath,
        [string]$KeyPath,
        [string]$Value
    )

    $segments = $KeyPath -split '\.'
    $lines = [System.Collections.ArrayList]@(Get-Content $FilePath)

    # Helper: quote a YAML value if it contains special chars
    $quotedValue = if ($Value -match '[\s:{}[\],&*?|>!%@`#]' -or $Value -match '^\s' -or $Value -match '\s$') {
        "`"$($Value -replace '"', '\"')`""
    } else { $Value }

    if ($segments.Count -eq 1) {
        $lines.Add("$($segments[0]): $quotedValue") | Out-Null
    }
    else {
        $currentIndent = 0
        $insertAt = $lines.Count

        for ($s = 0; $s -lt $segments.Count - 1; $s++) {
            $found = $false
            $seg = $segments[$s]
            $escapedSeg = [regex]::Escape($seg)

            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match "^(\s{$currentIndent})[`"']?$escapedSeg[`"']?\s*:") {
                    $found = $true
                    $insertAt = $i + 1
                    for ($j = $i + 1; $j -lt $lines.Count; $j++) {
                        if ($lines[$j] -match '^(\s*)(\S)') {
                            if ($Matches[1].Length -gt $currentIndent) {
                                $insertAt = $j + 1
                            } else {
                                break
                            }
                        }
                    }
                    $currentIndent += 2
                    break
                }
            }

            if (-not $found) {
                $indent = '  ' * $s
                $lines.Insert($insertAt, "$indent$seg`:") | Out-Null
                $insertAt++
                $currentIndent += 2
            }
        }

        $lastSeg = $segments[-1]
        $indent = '  ' * ($segments.Count - 1)
        $lines.Insert($insertAt, "$indent$lastSeg`: $quotedValue") | Out-Null
    }

    $lines | Set-Content $FilePath
}

# -------------------------------------------------
# Convert an R accessor chain from old key path to new
# -------------------------------------------------
function Convert-AccessorChain {
    param(
        [string]$Line,
        [string]$OldKeyPath,
        [string]$NewKeyPath
    )

    $oldPattern = Build-AccessorRegex -KeyPath $OldKeyPath -VarName 'sR'

    if ($Line -match $oldPattern) {
        $newChain = 'sR'
        $newSegments = $NewKeyPath -split '\.'

        foreach ($seg in $newSegments) {
            $isBareValid = $seg -match '^[a-zA-Z_.][a-zA-Z0-9_.]*$'
            if ($isBareValid) {
                $newChain += "`$$seg"
            } else {
                $newChain += "`$``$seg``"
            }
        }

        # Use [regex]::Replace to avoid $-as-backreference issues in -replace
        $Line = [regex]::Replace($Line, $oldPattern, $newChain.Replace('$', '$$'))
    }

    return $Line
}

# -------------------------------------------------
# Collect R code replacements without writing (for atomic apply)
# Returns @{ Aborted = $bool; Replacements = @(@{ FilePath; LineIndex; NewContent }) }
# -------------------------------------------------
function Get-RCodeReplacements {
    param(
        [string]$OldKeyPath,
        [string]$NewKeyPath,
        [string]$SearchDir
    )

    $result = @{ Aborted = $false; Replacements = @() }

    $refs = @(Find-RCodeReferences -KeyPath $OldKeyPath -SearchDir $SearchDir)
    if ($refs.Count -eq 0) { return $result }

    Write-Host ""
    Write-Host "  Found $($refs.Count) R code reference(s) to update ($OldKeyPath -> $NewKeyPath):" -ForegroundColor Yellow
    $applyAll = $false

    foreach ($ref in $refs) {
        $filePath = Join-Path $repoRoot $ref.File
        $lines = @(Get-Content $filePath)

        $oldLine = $lines[$ref.Line - 1]
        $newLine = Convert-AccessorChain -Line $oldLine -OldKeyPath $OldKeyPath -NewKeyPath $NewKeyPath

        if ($oldLine -eq $newLine) { continue }

        Write-Host "    $($ref.File):$($ref.Line)" -ForegroundColor DarkGray
        Write-Host "      - $oldLine" -ForegroundColor Red
        Write-Host "      + $newLine" -ForegroundColor Green

        if (-not $applyAll) {
            while ($true) {
                $confirm = Read-Host "    Apply? [Y]es / [N]o / [A]ll / [Q]uit (default: Y)"
                if ([string]::IsNullOrWhiteSpace($confirm)) { $confirm = 'Y'; break }
                if ($confirm -match '^[YyNnAaQq]$') { break }
                Write-Host "    Invalid choice: '$confirm'." -ForegroundColor Red
            }
            if ($confirm -eq 'Q' -or $confirm -eq 'q') {
                $result.Aborted = $true
                return $result
            }
            if ($confirm -eq 'A' -or $confirm -eq 'a') {
                $applyAll = $true
            }
            elseif ($confirm -ne 'Y' -and $confirm -ne 'y') {
                continue
            }
        }

        $result.Replacements += @{
            FilePath   = $filePath
            LineIndex  = $ref.Line - 1
            NewContent = $newLine
        }
    }

    return $result
}

# -------------------------------------------------
# Sort a YAML file's keys recursively (text-based,
# preserves comments, quoting, and multi-line values)
# -------------------------------------------------
function Optimize-YamlFileKeys {
    param(
        [string]$FilePath
    )

    $lines = @(Get-Content $FilePath)
    if ($lines.Count -eq 0) { return }

    # Recursively sort entries at a given indentation level.
    # Returns sorted lines for the block starting at $Start with indent $Indent.
    function Invoke-BlockSort {
        param(
            [string[]]$Lines,
            [int]$Start,
            [int]$End,
            [int]$Indent
        )

        if ($Start -ge $End) { return @() }

        # Collect entries at this indent level.
        # Each entry = header comments + key line + child lines.
        $entries = @()
        $preamble = @()    # lines before the first key (file-level comments)
        $current = $null

        for ($i = $Start; $i -lt $End; $i++) {
            $line = $Lines[$i]

            # Check if this is a key line at the target indent
            $isKey = $false
            if ($line -match "^(\s{$Indent})[`"']?([^\s:`"'#][^:`"']*?)[`"']?\s*:") {
                $lineIndent = if ($Matches[1]) { $Matches[1].Length } else { 0 }
                if ($lineIndent -eq $Indent) {
                    $isKey = $true
                    $keyName = $Matches[2]
                }
            }

            if ($isKey) {
                # Save previous entry
                if ($current) { $entries += ,$current }

                $current = @{
                    Key      = $keyName
                    Comments = [System.Collections.ArrayList]@($preamble)
                    KeyLine  = $i
                    Lines    = [System.Collections.ArrayList]@($line)
                }
                $preamble = @()
            }
            elseif (-not $current) {
                # Before first key — accumulate as preamble
                $preamble += $line
            }
            else {
                # Part of current entry (child lines, continuation, or inter-key comments/blanks)
                # Check if this is a deeper-indented line or a comment/blank
                $isBlankOrComment = ($line.Trim() -eq '' -or $line.Trim().StartsWith('#'))

                if ($isBlankOrComment) {
                    # Could be a trailing blank/comment of current entry, or
                    # a leading comment of the next entry. Look ahead.
                    $lookAheadBuffer = @($line)
                    $j = $i + 1
                    while ($j -lt $End -and ($Lines[$j].Trim() -eq '' -or $Lines[$j].Trim().StartsWith('#'))) {
                        $lookAheadBuffer += $Lines[$j]
                        $j++
                    }
                    # If the next non-blank/comment line is a key at this indent, these are leading comments
                    if ($j -lt $End -and $Lines[$j] -match "^(\s{$Indent})[`"']?[^\s:`"'#][^:`"']*?[`"']?\s*:" -and $Matches[1].Length -eq $Indent) {
                        # Save current entry, start buffering comments for next entry
                        $entries += ,$current
                        $current = $null
                        $preamble = $lookAheadBuffer
                        $i = $j - 1  # loop will increment
                    } else {
                        # Part of current entry's children
                        foreach ($buf in $lookAheadBuffer) {
                            $current.Lines.Add($buf) | Out-Null
                        }
                        $i = $j - 1
                    }
                }
                else {
                    $current.Lines.Add($line) | Out-Null
                }
            }
        }
        if ($current) { $entries += ,$current }

        # Sort entries by key (case-insensitive)
        $sorted = $entries | Sort-Object { $_.Key.ToLowerInvariant() }

        # For each entry, recursively sort its children
        $result = [System.Collections.ArrayList]@()

        # Add file-level preamble (only for top-level, i.e. lines before first key)
        if ($entries.Count -gt 0 -and $entries[0].Comments.Count -gt 0 -and $Indent -eq 0) {
            # Preamble was already captured in first entry's Comments via $preamble
        }

        foreach ($entry in $sorted) {
            # Add leading comments
            foreach ($c in $entry.Comments) {
                $result.Add($c) | Out-Null
            }

            $entryLines = @($entry.Lines)
            if ($entryLines.Count -le 1) {
                # Single-line entry (scalar value), no children to sort
                $result.Add($entryLines[0]) | Out-Null
            }
            else {
                # Key line + children — sort children recursively
                $result.Add($entryLines[0]) | Out-Null
                $childIndent = $Indent + 2
                # Check if children contain keys at child indent
                $hasChildKeys = $false
                for ($c = 1; $c -lt $entryLines.Count; $c++) {
                    if ($entryLines[$c] -match "^(\s{$childIndent})[`"']?[^\s:`"'#][^:`"']*?[`"']?\s*:" -and $Matches[1].Length -eq $childIndent) {
                        $hasChildKeys = $true
                        break
                    }
                }

                if ($hasChildKeys) {
                    $childLines = $entryLines[1..($entryLines.Count - 1)]
                    $sortedChildren = Invoke-BlockSort -Lines $childLines -Start 0 -End $childLines.Count -Indent $childIndent
                    foreach ($cl in $sortedChildren) {
                        $result.Add($cl) | Out-Null
                    }
                }
                else {
                    # Children are not key-value (arrays, multi-line scalars, etc.) — preserve as-is
                    for ($c = 1; $c -lt $entryLines.Count; $c++) {
                        $result.Add($entryLines[$c]) | Out-Null
                    }
                }
            }
        }

        return @($result)
    }

    $sorted = Invoke-BlockSort -Lines $lines -Start 0 -End $lines.Count -Indent 0
    $sorted | Set-Content $FilePath
}

# -------------------------------------------------
# Apply a collected changeset atomically (YAML + R code)
# -------------------------------------------------
function Invoke-Changeset {
    param(
        [array]$YamlAdditions,   # @{ FilePath; KeyPath; Value }
        [array]$YamlRemovals,    # @{ FilePath; KeyPath }
        [array]$RCodeChanges     # @{ FilePath; LineIndex; NewContent }
    )

    # Apply YAML additions first (before removals, in case same file)
    foreach ($add in $YamlAdditions) {
        Add-YamlKey -FilePath $add.FilePath -KeyPath $add.KeyPath -Value $add.Value
        $relPath = [System.IO.Path]::GetRelativePath($repoRoot, $add.FilePath) -replace '\\', '/'
        Write-Host "  Added $($add.KeyPath) to $relPath" -ForegroundColor Green
    }

    # Apply YAML removals
    foreach ($rem in $YamlRemovals) {
        if (Remove-YamlKey -FilePath $rem.FilePath -KeyPath $rem.KeyPath) {
            $relPath = [System.IO.Path]::GetRelativePath($repoRoot, $rem.FilePath) -replace '\\', '/'
            Write-Host "  Removed $($rem.KeyPath) from $relPath" -ForegroundColor Green
        }
    }

    # Apply R code changes — group by file to read/write each file once
    if ($RCodeChanges.Count -gt 0) {
        $byFile = $RCodeChanges | Group-Object -Property { $_.FilePath }
        foreach ($fg in $byFile) {
            $filePath = $fg.Name
            $lines = @(Get-Content $filePath)
            foreach ($change in $fg.Group) {
                $lines[$change.LineIndex] = $change.NewContent
            }
            $lines | Set-Content $filePath
            $relPath = [System.IO.Path]::GetRelativePath($repoRoot, $filePath) -replace '\\', '/'
            Write-Host "  Updated $($fg.Group.Count) R code reference(s) in $relPath" -ForegroundColor Green
        }
    }

    # Sort modified YAML files by key
    $modifiedYamlFiles = @{}
    foreach ($add in $YamlAdditions) { $modifiedYamlFiles[$add.FilePath] = $true }
    foreach ($rem in $YamlRemovals) { $modifiedYamlFiles[$rem.FilePath] = $true }
    foreach ($yamlFile in $modifiedYamlFiles.Keys) {
        if (Test-Path $yamlFile) {
            Optimize-YamlFileKeys -FilePath $yamlFile
            $relPath = [System.IO.Path]::GetRelativePath($repoRoot, $yamlFile) -replace '\\', '/'
            Write-Host "  Sorted keys in $relPath" -ForegroundColor DarkGray
        }
    }
}

# -------------------------------------------------
# Prompt for target key path when moving to a higher layer
# Returns the chosen key path, or $null if the user quit.
# -------------------------------------------------
function Read-TargetKeyPath {
    param(
        [string]$DefaultKeyPath,
        [string]$TargetLabel       # e.g. "common.yaml" or "glossary.yaml"
    )

    while ($true) {
        Write-Host "  Target key in $($TargetLabel): '$DefaultKeyPath'" -ForegroundColor White
        $choice = Read-Host "  Use this key? [Y]es / [C]ustom / [Q]uit (default: Y)"
        if ([string]::IsNullOrWhiteSpace($choice)) { return $DefaultKeyPath }
        if ($choice -match '^[Yy]$') { return $DefaultKeyPath }
        if ($choice -match '^[Qq]$') { return $null }
        if ($choice -match '^[Cc]$') {
            $custom = Read-Host "  Custom key path (dotted)"
            if ([string]::IsNullOrWhiteSpace($custom)) {
                Write-Host "  No key path entered." -ForegroundColor DarkGray
                continue
            }
            if ($custom -match '\[') {
                Write-Host "  Array-indexed paths cannot be created automatically." -ForegroundColor Red
                continue
            }
            return $custom
        }
        Write-Host "  Invalid choice: '$choice'. Type C to enter a custom key name." -ForegroundColor Red
    }
}

# =========================================================
# Main logic
# =========================================================

# -------------------------------------------------
# Load allowlist
# -------------------------------------------------
$allowlist = @{}
if (Test-Path $AllowlistPath) {
    Get-Content $AllowlistPath | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith('#')) {
            $allowlist[$line] = $true
        }
    }
}

# -------------------------------------------------
# Collect all entries from all layers
# -------------------------------------------------
$allEntries = @()

# Glossary
$allEntries += Get-YamlEntries -FilePath $glossaryPath -Layer 'glossary' -ReportName ''

# Common
$allEntries += Get-YamlEntries -FilePath $commonPath -Layer 'common' -ReportName ''

# Report-specific
$reportDirs = Get-ChildItem -Path $reportsDir -Directory |
    Where-Object { Test-Path (Join-Path $_.FullName 'content' '_sR.yaml') }

if ($ReportFilter) {
    $reportDirs = $reportDirs | Where-Object { $_.Name -eq $ReportFilter }
}

foreach ($dir in $reportDirs) {
    $srPath = Join-Path $dir.FullName 'content' '_sR.yaml'
    $allEntries += Get-YamlEntries -FilePath $srPath -Layer 'report' -ReportName $dir.Name
}

# -------------------------------------------------
# Upfront R code reference scan
# -------------------------------------------------
Write-Host "Scanning R/QMD/Rmd files for sR references..." -ForegroundColor DarkGray
$refMap = Get-AllRCodeReferences -SearchDir $reportsDir
Write-Host "  Found $($refMap.Count) unique key path(s) referenced in code." -ForegroundColor DarkGray
Write-Host ""

# -------------------------------------------------
# Dead key detection
# -------------------------------------------------
$deadKeys = @()
$deadAllowlist = @{}
if ($allowlist.Count -gt 0) {
    foreach ($key in $allowlist.Keys) {
        if ($key.StartsWith('dead:')) {
            $deadAllowlist[$key.Substring(5)] = $true
        }
    }
}

# Build set of all prefixes from referenced paths.
# For a referenced path like "tbl-resistance-test-rate.tbl-cap",
# add both the full path and all parent prefixes (e.g.,
# "tbl-resistance-test-rate") to the set. This ensures that
# sibling keys under the same parent are not flagged as dead
# when other siblings are actively used.
$referencedPrefixes = @{}
foreach ($refKey in $refMap.Keys) {
    $referencedPrefixes[$refKey] = $true
    $refSegments = $refKey -split '\.'
    for ($p = 1; $p -lt $refSegments.Count; $p++) {
        $prefix = ($refSegments[0..($p - 1)]) -join '.'
        $referencedPrefixes[$prefix] = $true
    }
}

foreach ($entry in $allEntries) {
    # Skip glossary entries — the glossary serves purposes beyond R code access
    if ($entry.Layer -eq 'glossary') { continue }
    # Skip array-indexed paths
    if ($entry.KeyPath -match '\[') { continue }

    $allowKey = if ($entry.ReportName) { "$($entry.Layer):$($entry.ReportName):$($entry.KeyPath)" } else { "$($entry.Layer):$($entry.KeyPath)" }
    if ($deadAllowlist.ContainsKey($allowKey)) { continue }

    if (-not $refMap.ContainsKey($entry.KeyPath)) {
        # Check if any parent prefix is referenced (dynamic access)
        $segments = $entry.KeyPath -split '\.'
        $parentReferenced = $false
        if ($segments.Count -gt 1) {
            for ($p = $segments.Count - 1; $p -ge 1; $p--) {
                $parentPath = ($segments[0..($p - 1)]) -join '.'
                if ($referencedPrefixes.ContainsKey($parentPath)) {
                    $parentReferenced = $true
                    break
                }
            }
        }

        if (-not $parentReferenced) {
            $deadKeys += $entry
        }
    }
}

# -------------------------------------------------
# Missing key detection
# -------------------------------------------------
$missingKeys = @()

# Build per-report key sets (union of glossary + common + report-specific)
$sharedKeyPaths = @{}
foreach ($entry in $allEntries) {
    if ($entry.Layer -eq 'glossary' -or $entry.Layer -eq 'common') {
        $sharedKeyPaths[$entry.KeyPath] = $true
    }
}

$reportKeyPaths = @{}
foreach ($dir in $reportDirs) {
    $reportKeyPaths[$dir.Name] = @{}
    # Add shared keys
    foreach ($k in $sharedKeyPaths.Keys) {
        $reportKeyPaths[$dir.Name][$k] = $true
    }
    # Add report-specific keys
    foreach ($entry in $allEntries) {
        if ($entry.Layer -eq 'report' -and $entry.ReportName -eq $dir.Name) {
            $reportKeyPaths[$dir.Name][$entry.KeyPath] = $true
        }
    }
}

# Also build per-report parent prefix sets (for dynamic access)
$reportParentPrefixes = @{}
foreach ($rn in $reportKeyPaths.Keys) {
    $reportParentPrefixes[$rn] = @{}
    foreach ($kp in $reportKeyPaths[$rn].Keys) {
        $segments = $kp -split '\.'
        for ($p = 1; $p -lt $segments.Count; $p++) {
            $prefix = ($segments[0..($p - 1)]) -join '.'
            $reportParentPrefixes[$rn][$prefix] = $true
        }
    }
}

# Check each referenced key path against the appropriate report's key set
foreach ($keyPath in $refMap.Keys) {
    # Skip array-indexed paths
    if ($keyPath -match '\[') { continue }

    foreach ($ref in $refMap[$keyPath]) {
        # Determine report ownership from file path
        $fileParts = $ref.File -split '/'
        $ownerReports = @()
        if ($fileParts.Count -ge 2 -and $fileParts[0] -eq 'reports') {
            $candidateReport = $fileParts[1]
            if ($reportKeyPaths.ContainsKey($candidateReport)) {
                $ownerReports = @($candidateReport)
            } elseif ($candidateReport -eq 'common' -or $candidateReport -eq 'filters') {
                # Shared code — check all reports
                $ownerReports = @($reportKeyPaths.Keys)
            }
        }

        foreach ($report in $ownerReports) {
            # Check if key exists in this report's accessible layers
            if ($reportKeyPaths[$report].ContainsKey($keyPath)) { continue }

            # Check parent prefixes (dynamic access)
            $segments = $keyPath -split '\.'
            $parentFound = $false
            if ($segments.Count -gt 1) {
                for ($p = $segments.Count - 1; $p -ge 1; $p--) {
                    $parentPath = ($segments[0..($p - 1)]) -join '.'
                    if ($reportKeyPaths[$report].ContainsKey($parentPath) -or
                        $reportParentPrefixes[$report].ContainsKey($parentPath)) {
                        $parentFound = $true
                        break
                    }
                }
            }
            if ($parentFound) { continue }

            # Check if it exists in another report's _sR.yaml
            $foundInOtherReports = @()
            foreach ($otherReport in $reportKeyPaths.Keys) {
                if ($otherReport -eq $report) { continue }
                # Check only report-specific entries (not shared)
                $otherReportEntries = @($allEntries | Where-Object {
                    $_.Layer -eq 'report' -and $_.ReportName -eq $otherReport -and $_.KeyPath -eq $keyPath
                })
                if ($otherReportEntries.Count -gt 0) {
                    $foundInOtherReports += [PSCustomObject]@{
                        ReportName = $otherReport
                        Entry      = $otherReportEntries[0]
                    }
                }
            }

            $missingKeys += [PSCustomObject]@{
                KeyPath            = $keyPath
                Report             = $report
                Reference          = $ref
                FoundInOtherReports = $foundInOtherReports
            }
        }
    }
}

# Deduplicate missing keys (same keyPath + report, keep first reference)
$missingKeys = @($missingKeys | Group-Object -Property { "$($_.Report):$($_.KeyPath)" } | ForEach-Object {
    $group = $_.Group
    [PSCustomObject]@{
        KeyPath             = $group[0].KeyPath
        Report              = $group[0].Report
        References          = @($group | ForEach-Object { $_.Reference })
        FoundInOtherReports = $group[0].FoundInOtherReports
    }
})

# -------------------------------------------------
# Group by string value and classify duplicates
# -------------------------------------------------
$groups = $allEntries | Group-Object -Property Value -CaseSensitive

$duplicateGroups = @()

foreach ($group in $groups) {
    if ($group.Count -lt 2) { continue }

    $entries = $group.Group
    $value = $group.Name

    # Skip very short strings that are likely coincidental (single chars, numbers)
    if ($value.Length -le 1) { continue }

    $layers = @($entries | Select-Object -ExpandProperty Layer -Unique)
    $reports = @($entries | Where-Object { $_.Layer -eq 'report' } | Select-Object -ExpandProperty ReportName -Unique)

    $categories = @()

    # Intra-file: same file, different key paths
    $byFile = $entries | Group-Object -Property FilePath
    $hasIntraFile = $false
    foreach ($fg in $byFile) {
        if ($fg.Count -ge 2) {
            $hasIntraFile = $true
        }
    }

    if ($layers.Count -ge 2) {
        $categories += 'cross-layer'
    }
    if ($layers.Count -eq 1 -and $layers[0] -eq 'report' -and $reports.Count -ge 2) {
        $categories += 'cross-report'
    }
    # Also tag cross-layer groups that span multiple reports
    if ($layers.Count -ge 2 -and $reports.Count -ge 2) {
        $categories += 'cross-report'
    }
    if ($hasIntraFile) {
        $categories += 'intra-file'
    }

    if ($categories.Count -eq 0) {
        continue
    }

    # Filter out allowlisted entries; skip group if fewer than 2 remain
    $filtered = @($entries | Where-Object {
        $allowKey = if ($_.ReportName) { "$($_.ReportName):$($_.KeyPath)" } else { "$($_.Layer):$($_.KeyPath)" }
        -not $allowlist.ContainsKey($allowKey)
    })
    if ($filtered.Count -lt 2) { continue }
    $entries = $filtered

    $uniqueKeyPaths = @($entries | Select-Object -ExpandProperty KeyPath -Unique)

    $duplicateGroups += [PSCustomObject]@{
        Value          = $value
        Categories     = $categories
        Entries        = $entries
        HasIntraFile   = $hasIntraFile
        KeyPathsDiffer = ($uniqueKeyPaths.Count -gt 1)
    }
}

# -------------------------------------------------
# Display results
# -------------------------------------------------
$hasIssues = ($duplicateGroups.Count -gt 0) -or ($deadKeys.Count -gt 0) -or ($missingKeys.Count -gt 0)

if (-not $hasIssues) {
    Write-Host "No string value duplicates, dead keys, or missing keys found." -ForegroundColor Green
    exit 0
}

$categoryLabels = @{
    'cross-layer'  = 'CROSS-LAYER'
    'cross-report' = 'CROSS-REPORT'
    'intra-file'   = 'INTRA-FILE'
}

if ($duplicateGroups.Count -gt 0) {
    Write-Host ""
    Write-Host "Found $($duplicateGroups.Count) duplicate string value group(s):" -ForegroundColor Yellow
    Write-Host ""
}

foreach ($dg in $duplicateGroups) {
    $labels = ($dg.Categories | ForEach-Object { $categoryLabels[$_] }) -join ', '
    $truncValue = if ($dg.Value.Length -gt 60) { $dg.Value.Substring(0, 57) + "..." } else { $dg.Value }
    Write-Host "[$labels] `"$truncValue`"" -ForegroundColor Cyan

    foreach ($entry in $dg.Entries) {
        $lineNum = Find-YamlKeyLine -FilePath $entry.FilePath -KeyPath $entry.KeyPath
        $lineInfo = if ($lineNum) { "(line $lineNum)" } else { "" }
        $source = if ($entry.ReportName) { "$($entry.ReportName)/_sR.yaml" } else { $entry.RelPath }
        Write-Host "  $($source.PadRight(40)) $($entry.KeyPath.PadRight(45)) $lineInfo"
    }

    # Show R code references if key paths differ
    if ($dg.KeyPathsDiffer) {
        $allRefs = @()
        $parentRefs = @()
        $uniqueKeyPaths = @($dg.Entries | Select-Object -ExpandProperty KeyPath -Unique)
        foreach ($kp in $uniqueKeyPaths) {
            if ($refMap.ContainsKey($kp)) {
                foreach ($ref in $refMap[$kp]) {
                    $allRefs += [PSCustomObject]@{
                        File       = $ref.File
                        Line       = $ref.Line
                        Content    = $ref.Content
                        ForKeyPath = $kp
                    }
                }
            }
            else {
                # No direct reference — check if a parent path is referenced
                # (indicates dynamic access like sR$parent[[variable]])
                $segments = $kp -split '\.'
                for ($p = $segments.Count - 1; $p -ge 1; $p--) {
                    $parentPath = ($segments[0..($p - 1)]) -join '.'
                    if ($refMap.ContainsKey($parentPath)) {
                        foreach ($ref in $refMap[$parentPath]) {
                            $parentRefs += [PSCustomObject]@{
                                File       = $ref.File
                                Line       = $ref.Line
                                Content    = $ref.Content
                                ForKeyPath = $kp
                                ViaParent  = $parentPath
                            }
                        }
                        break
                    }
                }
            }
        }
        if ($allRefs.Count -gt 0 -or $parentRefs.Count -gt 0) {
            Write-Host ""
            Write-Host "  R code references:" -ForegroundColor DarkGray
            foreach ($ref in ($allRefs | Sort-Object File, Line)) {
                Write-Host "    $($ref.File):$($ref.Line)".PadRight(55) "$($ref.Content)" -ForegroundColor DarkGray
            }
            foreach ($ref in ($parentRefs | Sort-Object File, Line)) {
                Write-Host "    $($ref.File):$($ref.Line)".PadRight(55) "$($ref.Content)" -ForegroundColor Yellow
                Write-Host "      ^ $($ref.ForKeyPath) accessed dynamically via sR`$$($ref.ViaParent)[[...]]" -ForegroundColor Yellow
            }
        }
    }

    Write-Host ""

    # -------------------------------------------------
    # Interactive fix mode
    # -------------------------------------------------
    if ($Fix) {
        # Build available actions based on all applicable categories
        $actions = @()
        $hasCrossLayer  = $dg.Categories -contains 'cross-layer'
        $hasCrossReport = $dg.Categories -contains 'cross-report'
        $hasIntraFile   = $dg.Categories -contains 'intra-file'

        $reportEntries = @($dg.Entries | Where-Object { $_.Layer -eq 'report' })

        # Determine default action
        $defaultAction = 'S'
        if ($hasCrossLayer -and $reportEntries.Count -gt 0) {
            $actions += "[D]elete from report"
            $defaultAction = 'D'
        }
        if ($hasCrossReport -and -not $hasCrossLayer) {
            $actions += "[M]ove to common"
            $defaultAction = 'M'
        }
        if ($hasIntraFile) {
            $actions += "[K]eep one (e.g., K1)"
            $actions += "[E]xtract to new key"
            if ($defaultAction -eq 'S') { $defaultAction = 'S' }  # no safe default for intra-file
        }
        $actions += "[G]lossary"
        $actions += "[S]kip"
        $actions += "[Q]uit"

        # Show key paths for intra-file choices
        if ($hasIntraFile) {
            Write-Host "  Key paths with this value:" -ForegroundColor White
            $uniqueEntries = @($dg.Entries | Group-Object KeyPath)
            for ($i = 0; $i -lt $uniqueEntries.Count; $i++) {
                $source = ($uniqueEntries[$i].Group | Select-Object -First 1)
                $fileLabel = if ($source.ReportName) { "$($source.ReportName)/_sR.yaml" } else { $source.RelPath }
                Write-Host "    [$($i + 1)] $fileLabel  $($uniqueEntries[$i].Name)"
            }
        }

        # Build valid action pattern from available actions
        $validPattern = '^([SsQqGg'
        if ($hasCrossLayer -and $reportEntries.Count -gt 0) { $validPattern += 'Dd' }
        if ($hasCrossReport -and -not $hasCrossLayer) { $validPattern += 'Mm' }
        if ($hasIntraFile) { $validPattern += 'EeKk' }
        $validPattern += ']'
        if ($hasIntraFile) { $validPattern += '|[Kk]\d+' }
        $validPattern += ')$'

        $action = $null
        while ($true) {
            Write-Host "  Actions: $($actions -join '  ')  (default: $defaultAction)" -ForegroundColor White
            $action = Read-Host "  Choice"
            if ([string]::IsNullOrWhiteSpace($action)) { $action = $defaultAction; break }
            if ($action -match $validPattern) { break }
            Write-Host "  Invalid choice: '$action'. Please enter one of the action letters shown above." -ForegroundColor Red
        }

        if ($action -eq 'Q' -or $action -eq 'q') {
            Write-Host "  Quitting. No uncommitted changes from this group." -ForegroundColor Yellow
            exit 2
        }
        elseif (($action -eq 'D' -or $action -eq 'd') -and $hasCrossLayer) {
            # --- Cross-layer delete: remove from report, point R code to common/custom key ---
            $yamlRemovals = @()
            $rCodeChanges = @()
            $aborted = $false

            $commonEntry = $dg.Entries | Where-Object { $_.Layer -ne 'report' } | Select-Object -First 1

            foreach ($re in $reportEntries) {
                $yamlRemovals += @{ FilePath = $re.FilePath; KeyPath = $re.KeyPath }

                if ($commonEntry -and $re.KeyPath -ne $commonEntry.KeyPath) {
                    # Prompt for target key (common key or custom)
                    $targetKeyPath = $commonEntry.KeyPath
                    while ($true) {
                        Write-Host "  Target key for R code: '$($commonEntry.KeyPath)'" -ForegroundColor White
                        $targetChoice = Read-Host "  Use this key? [Y]es / [C]ustom / [Q]uit (default: Y)"
                        if ([string]::IsNullOrWhiteSpace($targetChoice)) { $targetChoice = 'Y'; break }
                        if ($targetChoice -match '^[YyCcQq]$') { break }
                        Write-Host "  Invalid choice: '$targetChoice'." -ForegroundColor Red
                    }
                    if ($targetChoice -eq 'Q' -or $targetChoice -eq 'q') { $aborted = $true; break }
                    if ($targetChoice -eq 'C' -or $targetChoice -eq 'c') {
                        $customKey = Read-Host "  Custom target key path (dotted)"
                        if ([string]::IsNullOrWhiteSpace($customKey)) {
                            Write-Host "  No key path entered. Aborting this group." -ForegroundColor DarkGray
                            $aborted = $true; break
                        }
                        $targetKeyPath = $customKey
                    }

                    $replResult = Get-RCodeReplacements -OldKeyPath $re.KeyPath -NewKeyPath $targetKeyPath -SearchDir $reportsDir
                    if ($replResult.Aborted) { $aborted = $true; break }
                    $rCodeChanges += $replResult.Replacements
                }
            }

            if (-not $aborted) {
                Invoke-Changeset -YamlAdditions @() -YamlRemovals $yamlRemovals -RCodeChanges $rCodeChanges
            } else {
                Write-Host "  Aborted — no changes written for this group." -ForegroundColor DarkGray
            }
        }
        elseif (($action -eq 'M' -or $action -eq 'm') -and $hasCrossReport) {
            # --- Cross-report move: add to common, remove from reports ---
            $firstEntry = $dg.Entries | Select-Object -First 1
            $targetKeyPath = Read-TargetKeyPath -DefaultKeyPath $firstEntry.KeyPath -TargetLabel 'common.yaml'
            if (-not $targetKeyPath) {
                Write-Host "  Quitting. No uncommitted changes from this group." -ForegroundColor Yellow
                exit 2
            }
            else {
                # Check if the key already exists in common.yaml
                $commonYaml = Get-Content $commonPath -Raw | ConvertFrom-Yaml
                $existingValue = $commonYaml
                $keyExists = $true
                foreach ($seg in ($targetKeyPath -split '\.')) {
                    if ($existingValue -is [System.Collections.IDictionary] -and $existingValue.Contains($seg)) {
                        $existingValue = $existingValue[$seg]
                    } else {
                        $keyExists = $false
                        break
                    }
                }

                if ($keyExists -and $existingValue -is [string] -and $existingValue -ne $firstEntry.Value) {
                    Write-Host "  Key '$targetKeyPath' already exists in common.yaml with a different value:" -ForegroundColor Red
                    Write-Host "    Existing: `"$existingValue`"" -ForegroundColor Red
                    Write-Host "    New:      `"$($firstEntry.Value)`"" -ForegroundColor Red
                    Write-Host "  Skipped." -ForegroundColor DarkGray
                }
                else {
                    $yamlAdditions = @()
                    $yamlRemovals = @()
                    $rCodeChanges = @()
                    $aborted = $false

                    if ($keyExists -and $existingValue -is [string]) {
                        Write-Host "  Key '$targetKeyPath' already exists in common.yaml with the same value. Skipping add." -ForegroundColor DarkGray
                    } else {
                        $yamlAdditions += @{ FilePath = $commonPath; KeyPath = $targetKeyPath; Value = $firstEntry.Value }
                    }

                    foreach ($entry in $dg.Entries) {
                        $yamlRemovals += @{ FilePath = $entry.FilePath; KeyPath = $entry.KeyPath }

                        # If the source key path differs from the target, offer R code replacement
                        if ($entry.KeyPath -ne $targetKeyPath) {
                            $replResult = Get-RCodeReplacements -OldKeyPath $entry.KeyPath -NewKeyPath $targetKeyPath -SearchDir $reportsDir
                            if ($replResult.Aborted) { $aborted = $true; break }
                            $rCodeChanges += $replResult.Replacements
                        }
                    }

                    if (-not $aborted) {
                        Invoke-Changeset -YamlAdditions $yamlAdditions -YamlRemovals $yamlRemovals -RCodeChanges $rCodeChanges
                    } else {
                        Write-Host "  Aborted — no changes written for this group." -ForegroundColor DarkGray
                    }
                }
            }
        }
        elseif ($action -eq 'G' -or $action -eq 'g') {
            # --- Move to glossary: add to glossary.yaml, remove from reports (and common if present) ---
            $firstEntry = $dg.Entries | Select-Object -First 1
            $targetKeyPath = Read-TargetKeyPath -DefaultKeyPath $firstEntry.KeyPath -TargetLabel 'glossary.yaml'
            if (-not $targetKeyPath) {
                Write-Host "  Quitting. No uncommitted changes from this group." -ForegroundColor Yellow
                exit 2
            }
            else {
                # Check if the key already exists in glossary.yaml
                $glossaryYaml = Get-Content $glossaryPath -Raw | ConvertFrom-Yaml
                if (-not $glossaryYaml) { $glossaryYaml = @{} }
                $existingValue = $glossaryYaml
                $keyExists = $true
                foreach ($seg in ($targetKeyPath -split '\.')) {
                    if ($existingValue -is [System.Collections.IDictionary] -and $existingValue.Contains($seg)) {
                        $existingValue = $existingValue[$seg]
                    } else {
                        $keyExists = $false
                        break
                    }
                }

                if ($keyExists -and $existingValue -is [string] -and $existingValue -ne $firstEntry.Value) {
                    Write-Host "  Key '$targetKeyPath' already exists in glossary.yaml with a different value:" -ForegroundColor Red
                    Write-Host "    Existing: `"$existingValue`"" -ForegroundColor Red
                    Write-Host "    New:      `"$($firstEntry.Value)`"" -ForegroundColor Red
                    Write-Host "  Skipped." -ForegroundColor DarkGray
                }
                else {
                    $yamlAdditions = @()
                    $yamlRemovals = @()
                    $rCodeChanges = @()
                    $aborted = $false

                    if ($keyExists -and $existingValue -is [string]) {
                        Write-Host "  Key '$targetKeyPath' already exists in glossary.yaml with the same value. Skipping add." -ForegroundColor DarkGray
                    } else {
                        $yamlAdditions += @{ FilePath = $glossaryPath; KeyPath = $targetKeyPath; Value = $firstEntry.Value }
                    }

                    foreach ($entry in $dg.Entries) {
                        if ($entry.FilePath -eq $glossaryPath) { continue }
                        $yamlRemovals += @{ FilePath = $entry.FilePath; KeyPath = $entry.KeyPath }

                        # If the source key path differs from the target, offer R code replacement
                        if ($entry.KeyPath -ne $targetKeyPath) {
                            $replResult = Get-RCodeReplacements -OldKeyPath $entry.KeyPath -NewKeyPath $targetKeyPath -SearchDir $reportsDir
                            if ($replResult.Aborted) { $aborted = $true; break }
                            $rCodeChanges += $replResult.Replacements
                        }
                    }

                    if (-not $aborted) {
                        Invoke-Changeset -YamlAdditions $yamlAdditions -YamlRemovals $yamlRemovals -RCodeChanges $rCodeChanges
                    } else {
                        Write-Host "  Aborted — no changes written for this group." -ForegroundColor DarkGray
                    }
                }
            }
        }
        elseif ($action -match '^[Kk](\d+)$' -and $hasIntraFile) {
            # --- Intra-file keep one: remove others, update R code ---
            if (-not $uniqueEntries) {
                $uniqueEntries = @($dg.Entries | Group-Object KeyPath)
            }
            $keepIndex = [int]$Matches[1] - 1
            if ($keepIndex -ge 0 -and $keepIndex -lt $uniqueEntries.Count) {
                $keepPath = $uniqueEntries[$keepIndex].Name
                $yamlRemovals = @()
                $rCodeChanges = @()
                $aborted = $false

                for ($j = 0; $j -lt $uniqueEntries.Count; $j++) {
                    if ($j -eq $keepIndex) { continue }
                    $removePath = $uniqueEntries[$j].Name
                    $fileEntry = $uniqueEntries[$j].Group | Select-Object -First 1
                    $yamlRemovals += @{ FilePath = $fileEntry.FilePath; KeyPath = $removePath }

                    if ($removePath -ne $keepPath) {
                        $replResult = Get-RCodeReplacements -OldKeyPath $removePath -NewKeyPath $keepPath -SearchDir $reportsDir
                        if ($replResult.Aborted) { $aborted = $true; break }
                        $rCodeChanges += $replResult.Replacements
                    }
                }

                if (-not $aborted) {
                    Invoke-Changeset -YamlAdditions @() -YamlRemovals $yamlRemovals -RCodeChanges $rCodeChanges
                } else {
                    Write-Host "  Aborted — no changes written for this group." -ForegroundColor DarkGray
                }
            }
        }
        elseif (($action -eq 'E' -or $action -eq 'e') -and $hasIntraFile) {
            # --- Intra-file extract: create new key, remove all old, update R code ---
            $newKeyPath = Read-Host "  New key path (dotted)"
            if ([string]::IsNullOrWhiteSpace($newKeyPath)) {
                Write-Host "  No key path entered. Skipped." -ForegroundColor DarkGray
            }
            elseif ($newKeyPath -match '\[') {
                Write-Host "  Array-indexed paths (e.g., 'key[0].sub') cannot be created automatically." -ForegroundColor Red
                Write-Host "  Use [Q]uit, edit the YAML manually, and re-run." -ForegroundColor Red
            }
            else {
                $targetEntry = $dg.Entries | Select-Object -First 1

                # Check if the new key already exists in the target file
                $existingYaml = Get-Content $targetEntry.FilePath -Raw | ConvertFrom-Yaml
                $existingValue = $existingYaml
                $keyExists = $true
                foreach ($seg in ($newKeyPath -split '\.')) {
                    if ($existingValue -is [System.Collections.IDictionary] -and $existingValue.Contains($seg)) {
                        $existingValue = $existingValue[$seg]
                    } else {
                        $keyExists = $false
                        break
                    }
                }

                if ($keyExists -and $existingValue -is [string] -and $existingValue -ne $dg.Value) {
                    Write-Host "  Key '$newKeyPath' already exists with a different value:" -ForegroundColor Red
                    Write-Host "    Existing: `"$existingValue`"" -ForegroundColor Red
                    Write-Host "    New:      `"$($dg.Value)`"" -ForegroundColor Red
                    Write-Host "  Skipped." -ForegroundColor DarkGray
                }
                else {
                    $yamlAdditions = @()
                    $yamlRemovals = @()
                    $rCodeChanges = @()
                    $aborted = $false

                    if ($keyExists -and $existingValue -is [string]) {
                        Write-Host "  Key '$newKeyPath' already exists with the same value. Skipping add." -ForegroundColor DarkGray
                    } else {
                        $yamlAdditions += @{ FilePath = $targetEntry.FilePath; KeyPath = $newKeyPath; Value = $dg.Value }
                    }

                    # Collect removals and R code replacements
                    if (-not $uniqueEntries) {
                        $uniqueEntries = @($dg.Entries | Group-Object KeyPath)
                    }
                    foreach ($ue in $uniqueEntries) {
                        if ($ue.Name -eq $newKeyPath) { continue }
                        $fileEntry = $ue.Group | Select-Object -First 1
                        $yamlRemovals += @{ FilePath = $fileEntry.FilePath; KeyPath = $ue.Name }

                        $replResult = Get-RCodeReplacements -OldKeyPath $ue.Name -NewKeyPath $newKeyPath -SearchDir $reportsDir
                        if ($replResult.Aborted) { $aborted = $true; break }
                        $rCodeChanges += $replResult.Replacements
                    }

                    if (-not $aborted) {
                        Invoke-Changeset -YamlAdditions $yamlAdditions -YamlRemovals $yamlRemovals -RCodeChanges $rCodeChanges
                    } else {
                        Write-Host "  Aborted — no changes written for this group." -ForegroundColor DarkGray
                    }
                }
            }
        }
    }
}

# -------------------------------------------------
# Dead keys display
# -------------------------------------------------
if ($deadKeys.Count -gt 0) {
    Write-Host ""
    Write-Host "DEAD KEYS ($($deadKeys.Count) key(s) with no R code references):" -ForegroundColor Yellow
    Write-Host ""

    $deleteAll = $false
    $skipAll = $false

    foreach ($dk in $deadKeys) {
        $lineNum = Find-YamlKeyLine -FilePath $dk.FilePath -KeyPath $dk.KeyPath
        $lineInfo = if ($lineNum) { "(line $lineNum)" } else { "" }
        $source = if ($dk.ReportName) { "$($dk.ReportName)/_sR.yaml" } else { $dk.RelPath }
        $truncValue = if ($dk.Value.Length -gt 50) { $dk.Value.Substring(0, 47) + "..." } else { $dk.Value }
        Write-Host "  $($source.PadRight(40)) $($dk.KeyPath.PadRight(35)) $lineInfo" -ForegroundColor DarkYellow
        Write-Host "    Value: `"$truncValue`"" -ForegroundColor DarkGray

        if ($Fix -and -not $skipAll) {
            if ($deleteAll) {
                if (Remove-YamlKey -FilePath $dk.FilePath -KeyPath $dk.KeyPath) {
                    Write-Host "    Deleted." -ForegroundColor Green
                }
            }
            else {
                $action = $null
                while ($true) {
                    Write-Host "    Actions: [D]elete  [S]kip  [A]ll delete  [N]one (skip all)  [Q]uit  (default: D)" -ForegroundColor White
                    $action = Read-Host "    Choice"
                    if ([string]::IsNullOrWhiteSpace($action)) { $action = 'D'; break }
                    if ($action -match '^[DdSsAaNnQq]$') { break }
                    Write-Host "    Invalid choice: '$action'. Please enter one of the action letters shown above." -ForegroundColor Red
                }

                switch -regex ($action) {
                    '^[Dd]$' {
                        if (Remove-YamlKey -FilePath $dk.FilePath -KeyPath $dk.KeyPath) {
                            Write-Host "    Deleted." -ForegroundColor Green
                        }
                    }
                    '^[Aa]$' {
                        $deleteAll = $true
                        if (Remove-YamlKey -FilePath $dk.FilePath -KeyPath $dk.KeyPath) {
                            Write-Host "    Deleted." -ForegroundColor Green
                        }
                    }
                    '^[Nn]$' {
                        $skipAll = $true
                        Write-Host "    Skipping all remaining dead keys." -ForegroundColor DarkGray
                    }
                    '^[Qq]$' {
                        Write-Host "    Quitting. Changes made so far have been saved." -ForegroundColor Yellow
                        exit 2
                    }
                    default {
                        Write-Host "    Skipped." -ForegroundColor DarkGray
                    }
                }
            }
        }
    }
    Write-Host ""
}

# -------------------------------------------------
# Missing keys display
# -------------------------------------------------
if ($missingKeys.Count -gt 0) {
    Write-Host ""
    Write-Host "MISSING KEYS ($($missingKeys.Count) key(s) referenced in R code but not defined in YAML):" -ForegroundColor Yellow
    Write-Host ""

    foreach ($mk in $missingKeys) {
        Write-Host "  $($mk.Report):" -ForegroundColor Cyan -NoNewline
        Write-Host " sR`$$($mk.KeyPath)" -ForegroundColor White

        # Show references
        foreach ($ref in $mk.References) {
            Write-Host "    $($ref.File):$($ref.Line)".PadRight(55) "$($ref.Content)" -ForegroundColor DarkGray
        }

        # Show which layers were checked
        Write-Host "    Not found in: glossary.yaml, common.yaml, $($mk.Report)/_sR.yaml" -ForegroundColor DarkYellow

        # Show cross-report suggestions
        if ($mk.FoundInOtherReports.Count -gt 0) {
            foreach ($other in $mk.FoundInOtherReports) {
                $lineNum = Find-YamlKeyLine -FilePath $other.Entry.FilePath -KeyPath $mk.KeyPath
                $lineInfo = if ($lineNum) { "(line $lineNum)" } else { "" }
                Write-Host "    Found in:     $($other.ReportName)/_sR.yaml $lineInfo" -ForegroundColor Green -NoNewline
                Write-Host "  <- suggest move to common/glossary" -ForegroundColor Yellow
            }
        }

        if ($Fix) {
            $hasOtherReport = $mk.FoundInOtherReports.Count -gt 0
            $actions = @()
            $defaultAction = 'S'

            if ($hasOtherReport) {
                $actions += "[M]ove to common"
                $actions += "[G]lossary"
                $defaultAction = 'M'
            }
            $actions += "[A]dd to report"
            $actions += "[S]kip"
            $actions += "[Q]uit"

            # Build valid pattern
            $validPattern = '^[AaSsQq'
            if ($hasOtherReport) { $validPattern += 'MmGg' }
            $validPattern += ']$'

            $action = $null
            while ($true) {
                Write-Host "    Actions: $($actions -join '  ')  (default: $defaultAction)" -ForegroundColor White
                $action = Read-Host "    Choice"
                if ([string]::IsNullOrWhiteSpace($action)) { $action = $defaultAction; break }
                if ($action -match $validPattern) { break }
                Write-Host "    Invalid choice: '$action'. Please enter one of the action letters shown above." -ForegroundColor Red
            }

            if ($action -eq 'Q' -or $action -eq 'q') {
                Write-Host "    Quitting." -ForegroundColor Yellow
                exit 2
            }
            elseif (($action -eq 'M' -or $action -eq 'm') -and $hasOtherReport) {
                # Move from other report to common
                $sourceEntry = $mk.FoundInOtherReports[0].Entry
                $targetKeyPath = Read-TargetKeyPath -DefaultKeyPath $mk.KeyPath -TargetLabel 'common.yaml'
                if (-not $targetKeyPath) {
                    Write-Host "    Quitting. No uncommitted changes from this group." -ForegroundColor Yellow
                    exit 2
                }
                else {
                    # Check if key already exists in common
                    $commonYaml = Get-Content $commonPath -Raw | ConvertFrom-Yaml
                    $existingValue = $commonYaml
                    $keyExists = $true
                    foreach ($seg in ($targetKeyPath -split '\.')) {
                        if ($existingValue -is [System.Collections.IDictionary] -and $existingValue.Contains($seg)) {
                            $existingValue = $existingValue[$seg]
                        } else {
                            $keyExists = $false
                            break
                        }
                    }

                    if ($keyExists -and $existingValue -is [string] -and $existingValue -ne $sourceEntry.Value) {
                        Write-Host "    Key '$targetKeyPath' already exists in common.yaml with a different value:" -ForegroundColor Red
                        Write-Host "      Existing: `"$existingValue`"" -ForegroundColor Red
                        Write-Host "      Source:   `"$($sourceEntry.Value)`"" -ForegroundColor Red
                        Write-Host "    Skipped." -ForegroundColor DarkGray
                    }
                    else {
                        $yamlAdditions = @()
                        $yamlRemovals = @()
                        $rCodeChanges = @()
                        $aborted = $false

                        if ($keyExists -and $existingValue -is [string]) {
                            Write-Host "    Key already exists in common.yaml with the same value. Skipping add." -ForegroundColor DarkGray
                        } else {
                            $yamlAdditions += @{ FilePath = $commonPath; KeyPath = $targetKeyPath; Value = $sourceEntry.Value }
                        }
                        $yamlRemovals += @{ FilePath = $sourceEntry.FilePath; KeyPath = $mk.KeyPath }

                        # If key paths differ, offer R code replacement
                        if ($mk.KeyPath -ne $targetKeyPath) {
                            $replResult = Get-RCodeReplacements -OldKeyPath $mk.KeyPath -NewKeyPath $targetKeyPath -SearchDir $reportsDir
                            if ($replResult.Aborted) { $aborted = $true }
                            else { $rCodeChanges += $replResult.Replacements }
                        }

                        if (-not $aborted) {
                            Invoke-Changeset -YamlAdditions $yamlAdditions -YamlRemovals $yamlRemovals -RCodeChanges $rCodeChanges
                        } else {
                            Write-Host "    Aborted — no changes written." -ForegroundColor DarkGray
                        }
                    }
                }
            }
            elseif (($action -eq 'G' -or $action -eq 'g') -and $hasOtherReport) {
                # Move from other report to glossary
                $sourceEntry = $mk.FoundInOtherReports[0].Entry
                $targetKeyPath = Read-TargetKeyPath -DefaultKeyPath $mk.KeyPath -TargetLabel 'glossary.yaml'
                if (-not $targetKeyPath) {
                    Write-Host "    Quitting. No uncommitted changes from this group." -ForegroundColor Yellow
                    exit 2
                }
                else {
                    # Check if key already exists in glossary
                    $glossaryYaml = Get-Content $glossaryPath -Raw | ConvertFrom-Yaml
                    if (-not $glossaryYaml) { $glossaryYaml = @{} }
                    $existingValue = $glossaryYaml
                    $keyExists = $true
                    foreach ($seg in ($targetKeyPath -split '\.')) {
                        if ($existingValue -is [System.Collections.IDictionary] -and $existingValue.Contains($seg)) {
                            $existingValue = $existingValue[$seg]
                        } else {
                            $keyExists = $false
                            break
                        }
                    }

                    if ($keyExists -and $existingValue -is [string] -and $existingValue -ne $sourceEntry.Value) {
                        Write-Host "    Key '$targetKeyPath' already exists in glossary.yaml with a different value:" -ForegroundColor Red
                        Write-Host "      Existing: `"$existingValue`"" -ForegroundColor Red
                        Write-Host "      Source:   `"$($sourceEntry.Value)`"" -ForegroundColor Red
                        Write-Host "    Skipped." -ForegroundColor DarkGray
                    }
                    else {
                        $yamlAdditions = @()
                        $yamlRemovals = @()
                        $rCodeChanges = @()
                        $aborted = $false

                        if ($keyExists -and $existingValue -is [string]) {
                            Write-Host "    Key already exists in glossary.yaml with the same value. Skipping add." -ForegroundColor DarkGray
                        } else {
                            $yamlAdditions += @{ FilePath = $glossaryPath; KeyPath = $targetKeyPath; Value = $sourceEntry.Value }
                        }
                        $yamlRemovals += @{ FilePath = $sourceEntry.FilePath; KeyPath = $mk.KeyPath }

                        # If key paths differ, offer R code replacement
                        if ($mk.KeyPath -ne $targetKeyPath) {
                            $replResult = Get-RCodeReplacements -OldKeyPath $mk.KeyPath -NewKeyPath $targetKeyPath -SearchDir $reportsDir
                            if ($replResult.Aborted) { $aborted = $true }
                            else { $rCodeChanges += $replResult.Replacements }
                        }

                        if (-not $aborted) {
                            Invoke-Changeset -YamlAdditions $yamlAdditions -YamlRemovals $yamlRemovals -RCodeChanges $rCodeChanges
                        } else {
                            Write-Host "    Aborted — no changes written." -ForegroundColor DarkGray
                        }
                    }
                }
            }
            elseif ($action -eq 'A' -or $action -eq 'a') {
                # Add to current report's _sR.yaml
                $value = $null
                if ($mk.FoundInOtherReports.Count -gt 0) {
                    $value = $mk.FoundInOtherReports[0].Entry.Value
                    Write-Host "    Value from $($mk.FoundInOtherReports[0].ReportName): `"$value`"" -ForegroundColor DarkGray
                    $useExisting = Read-Host "    Use this value? [Y]es / [C]ustom (default: Y)"
                    if ([string]::IsNullOrWhiteSpace($useExisting)) { $useExisting = 'Y' }
                    if ($useExisting -eq 'C' -or $useExisting -eq 'c') {
                        $value = Read-Host "    Value"
                        if ([string]::IsNullOrWhiteSpace($value)) {
                            Write-Host "    No value entered. Skipped." -ForegroundColor DarkGray
                            continue
                        }
                    }
                } else {
                    $value = Read-Host "    Value (this key is not defined anywhere)"
                    if ([string]::IsNullOrWhiteSpace($value)) {
                        Write-Host "    No value entered. Skipped." -ForegroundColor DarkGray
                        continue
                    }
                }

                if ($mk.KeyPath -match '\[') {
                    Write-Host "    Array-indexed paths cannot be created automatically." -ForegroundColor Red
                    Write-Host "    Use [Q]uit, edit the YAML manually, and re-run." -ForegroundColor Red
                } else {
                    $reportSrPath = Join-Path $reportsDir $mk.Report 'content' '_sR.yaml'
                    Invoke-Changeset -YamlAdditions @(@{ FilePath = $reportSrPath; KeyPath = $mk.KeyPath; Value = $value }) -YamlRemovals @() -RCodeChanges @()
                }
            }
            else {
                Write-Host "    Skipped." -ForegroundColor DarkGray
            }
        }

        Write-Host ""
    }
}

# -------------------------------------------------
# Summary
# -------------------------------------------------
if ($Fix) {
    Write-Host ""
    Write-Host "Done. Remember to:" -ForegroundColor Yellow
    Write-Host "  1. Review any R code that references changed/removed keys"
    Write-Host "  2. Run scripts/Update-Po4aYamlKeys.ps1 for affected po4a configs"
    Write-Host "     (po/reports.po4a.cfg and/or po/glossary.po4a.cfg)"
    Write-Host "  3. Run po4a to regenerate localized files"
    Write-Host ""
}

# Exit with non-zero if issues were found
if ($hasIssues) {
    exit 1
}
