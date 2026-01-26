<#
.SYNOPSIS
    Validates that placeholders in PO file translations haven't been replaced with constant values.

.DESCRIPTION
    This script validates PO (Portable Object) translation files to ensure that placeholders,
    variables, and references in the source strings (msgid) are preserved in translations (msgstr).
    
    It checks for:
    - Printf-style placeholders (%s, %d, %f, etc.)
    - R code expressions (`r variable`)
    - Quarto cross-references (@fig-*, @tbl-*, etc.)
    - .NET placeholders ({0}, {1}, etc.)
    - LaTeX text markers (\text{...})
    
    The script reports violations with file paths, line numbers, and context. It returns the
    count of violations as the exit code (capped at 255).

.PARAMETER Path
    Path to PO files or directory containing PO files. Supports wildcards.
    Default: po\*.po

.PARAMETER Include
    Array of specific file paths to include in validation.

.PARAMETER Category
    Filter PO files by category based on filename pattern.
    Valid values: reports, documentation, glossary, infectious_agents, scripts, all
    Default: all

.PARAMETER Quiet
    Suppress summary output. Only violations are displayed.

.PARAMETER OutputFile
    Path to write validation results. Output is formatted text with all violations and summary.

.EXAMPLE
    .\Test-PoPlaceholders.ps1
    Validates all PO files in the po\ directory.

.EXAMPLE
    .\Test-PoPlaceholders.ps1 -Category reports -Verbose
    Validates only report PO files with detailed output for passing validations.

.EXAMPLE
    .\Test-PoPlaceholders.ps1 -Path "po\reports.*.po" -OutputFile "validation-report.txt"
    Validates report PO files and writes results to a file.

.EXAMPLE
    .\Test-PoPlaceholders.ps1 -Include "po\reports.de.po","po\reports.es.po"
    Validates specific PO files.

.NOTES
    Author: NeoIPC Surveillance Toolkit
    Date: January 26, 2026
    Exit Code: Number of violations found (capped at 255)
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$Path = "po\*.po",
    
    [Parameter()]
    [string[]]$Include,
    
    [Parameter()]
    [ValidateSet('reports', 'documentation', 'glossary', 'infectious_agents', 'scripts', 'all')]
    [string]$Category = 'all',
    
    [Parameter()]
    [switch]$Quiet,
    
    [Parameter()]
    [string]$OutputFile
)

#region Helper Functions

function Get-PoEntries {
    <#
    .SYNOPSIS
        Parses a PO file and extracts msgid/msgstr pairs with metadata.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$FilePath
    )
    
    $content = Get-Content -Path $FilePath -Raw -Encoding UTF8
    # Normalize line endings to Unix style for consistent parsing
    $content = $content -replace "`r`n", "`n"
    $entries = @()
    
    # Regex to match PO entries with comments, msgid, and msgstr
    $pattern = '(?ms)^(#.*?\n)?(msgid\s+"(?:[^"\\]|\\.)*"(?:\n"(?:[^"\\]|\\.)*")*)\s+(msgstr\s+"(?:[^"\\]|\\.)*"(?:\n"(?:[^"\\]|\\.)*")*)'
    
    $matches = [regex]::Matches($content, $pattern)
    
    foreach ($match in $matches) {
        $comments = $match.Groups[1].Value
        $msgidBlock = $match.Groups[2].Value
        $msgstrBlock = $match.Groups[3].Value
        
        # Extract the actual strings (handle multiline)
        $msgid = Get-PoString -Block $msgidBlock
        $msgstr = Get-PoString -Block $msgstrBlock
        
        # Skip if msgstr is empty (untranslated)
        if ([string]::IsNullOrWhiteSpace($msgstr)) {
            continue
        }
        
        # Calculate line numbers
        $textBeforeMatch = $content.Substring(0, $match.Index)
        $entryStartLine = ($textBeforeMatch -split "`n").Count
        
        # Calculate where msgstr starts within the match
        $textBeforeMsgstr = $match.Groups[1].Value + $match.Groups[2].Value
        # Count the number of lines (not newlines) in the text before msgstr
        $linesBeforeMsgstr = ($textBeforeMsgstr.TrimEnd("`n") -split "`n").Count
        $msgstrLine = $entryStartLine + $linesBeforeMsgstr
        
        # Find the column where msgstr content starts (after 'msgstr "')
        $msgstrFirstLine = ($msgstrBlock -split "`n")[0]
        # +2 because: IndexOf gives 0-based position of quote, +1 for 1-based, +1 to skip quote
        $msgstrColumn = $msgstrFirstLine.IndexOf('"') + 2
        if ($msgstrColumn -eq 1) { $msgstrColumn = 1 }
        
        # Check for fuzzy flag
        $isFuzzy = $comments -match '#,\s*fuzzy'
        
        # Extract source reference
        $sourceRef = ''
        if ($comments -match '#:\s*(.+)') {
            $sourceRef = $matches[1].Trim()
        }
        
        $entries += [PSCustomObject]@{
            LineNumber = $msgstrLine
            Column = $msgstrColumn
            SourceRef = $sourceRef
            IsFuzzy = $isFuzzy
            MsgId = $msgid
            MsgStr = $msgstr
            MsgStrBlock = $msgstrBlock
            Comments = $comments
        }
    }
    
    return $entries
}

function Get-PoString {
    <#
    .SYNOPSIS
        Extracts the actual string value from a msgid or msgstr block.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Block
    )
    
    # Remove msgid/msgstr prefix and extract quoted strings
    $strings = [regex]::Matches($Block, '"((?:[^"\\]|\\.)*)"')
    
    $result = ($strings | ForEach-Object { $_.Groups[1].Value }) -join ''
    
    # Unescape common sequences for comparison
    $result = $result -replace '\\n', "`n"
    $result = $result -replace '\\t', "`t"
    $result = $result -replace '\\"', '"'
    $result = $result -replace '\\\\', '\'
    
    return $result
}

function Get-PoFilePosition {
    <#
    .SYNOPSIS
        Maps an offset in the concatenated/unescaped string to the actual file line and column.
    #>
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Entry,
        
        [Parameter(Mandatory)]
        [int]$StringOffset
    )
    
    # For single-line msgstr, it's simple
    $msgstrLines = $Entry.MsgStrBlock -split "`n"
    if ($msgstrLines.Count -eq 1) {
        return @{
            Line = $Entry.LineNumber
            Column = $Entry.Column + $StringOffset
        }
    }
    
    # For multiline msgstr, we need to map through the concatenated content
    # Extract the raw quoted strings (before unescaping)
    $quotedStrings = [regex]::Matches($Entry.MsgStrBlock, '"((?:[^"\\]|\\.)*)"')
    
    $currentOffset = 0
    $currentLine = 0
    
    foreach ($match in $quotedStrings) {
        $rawString = $match.Groups[1].Value
        
        # Unescape to match the concatenated string
        $unescapedString = $rawString
        $unescapedString = $unescapedString -replace '\\n', "`n"
        $unescapedString = $unescapedString -replace '\\t', "`t"
        $unescapedString = $unescapedString -replace '\\"', '"'
        $unescapedString = $unescapedString -replace '\\\\', '\'
        
        $stringLength = $unescapedString.Length
        
        if ($StringOffset -lt ($currentOffset + $stringLength)) {
            # The offset is within this quoted string segment
            $offsetInSegment = $StringOffset - $currentOffset
            
            # Now map through the raw string to account for escape sequences
            $rawOffset = 0
            $unescapedOffset = 0
            
            while ($unescapedOffset -lt $offsetInSegment -and $rawOffset -lt $rawString.Length) {
                if ($rawString[$rawOffset] -eq '\' -and $rawOffset + 1 -lt $rawString.Length) {
                    $escapeChar = $rawString[$rawOffset + 1]
                    if ($escapeChar -eq 'n' -or $escapeChar -eq 't' -or $escapeChar -eq '"' -or $escapeChar -eq '\') {
                        $rawOffset += 2
                        $unescapedOffset += 1
                    } else {
                        $rawOffset += 1
                        $unescapedOffset += 1
                    }
                } else {
                    $rawOffset += 1
                    $unescapedOffset += 1
                }
            }
            
            # Calculate the column position
            $lineContent = $msgstrLines[$currentLine]
            $quotePos = $lineContent.IndexOf('"')
            
            return @{
                Line = $Entry.LineNumber + $currentLine
                Column = $quotePos + 1 + $rawOffset
            }
        }
        
        $currentOffset += $stringLength
        $currentLine++
    }
    
    # Fallback to the last line if offset is beyond content
    return @{
        Line = $Entry.LineNumber + $msgstrLines.Count - 1
        Column = $Entry.Column
    }
}

function Get-PrintfPlaceholders {
    <#
    .SYNOPSIS
        Extracts all printf-style placeholders from a string.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text
    )
    
    # Match printf placeholders: %[-+0 #]*[0-9]*\.?[0-9]*[sdifuxoegcp]
    $pattern = '%[-+0 #]*[0-9]*\.?[0-9]*[sdifuxoegcp]'
    $matches = [regex]::Matches($Text, $pattern)
    
    return @($matches | ForEach-Object { $_.Value })
}

function Get-RCodeExpressions {
    <#
    .SYNOPSIS
        Extracts all R code expressions from a string.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text
    )
    
    # Match R code: `r ...`
    $pattern = '`r\s+[^`]+'
    $matches = [regex]::Matches($Text, $pattern)
    
    return @($matches | ForEach-Object { $_.Value })
}

function Get-QuartoCrossRefs {
    <#
    .SYNOPSIS
        Extracts all Quarto cross-references from a string.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text
    )
    
    # Match Quarto cross-references: @fig-*, @tbl-*, etc.
    $pattern = '@(fig|tbl|eq|sec|lst|thm|lem|cor|prp|cnj|def|exm|exr)-[a-zA-Z0-9_-]+'
    $matches = [regex]::Matches($Text, $pattern)
    
    return @($matches | ForEach-Object { $_.Value })
}

function Get-DotNetPlaceholders {
    <#
    .SYNOPSIS
        Extracts all .NET-style placeholders from a string.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text
    )
    
    # Match .NET placeholders: {0}, {1}, {0:format}, etc.
    $pattern = '\{[0-9]+(?::[^}]*)?\}'
    $matches = [regex]::Matches($Text, $pattern)
    
    return @($matches | ForEach-Object { $_.Value })
}

function Get-LaTeXTextMarkers {
    <#
    .SYNOPSIS
        Extracts all LaTeX text markers from a string.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text
    )
    
    # Match LaTeX text markers: \text{...}
    $pattern = '\\text\{[^}]*\}'
    $matches = [regex]::Matches($Text, $pattern)
    
    return @($matches | ForEach-Object { $_.Value })
}

function Test-PlaceholderMatch {
    <#
    .SYNOPSIS
        Validates that msgstr contains the same placeholders as msgid.
    #>
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Entry,
        
        [Parameter(Mandatory)]
        [string]$FilePath,
        
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.ArrayList]$Violations
    )
    
    $hasViolation = $false
    
    # Test printf placeholders
    $msgidPrintf = Get-PrintfPlaceholders -Text $Entry.MsgId
    $msgstrPrintf = Get-PrintfPlaceholders -Text $Entry.MsgStr
    
    if ($msgidPrintf.Count -ne $msgstrPrintf.Count) {
        $hasViolation = $true
        
        # Find the position of the error in the file
        $stringOffset = 0
        if ($msgstrPrintf.Count -gt 0) {
            # Point to the first placeholder in msgstr
            $stringOffset = $Entry.MsgStr.IndexOf($msgstrPrintf[0])
        } elseif ($msgidPrintf.Count -gt 0) {
            # No placeholders found - try to find likely replacement
            if ($Entry.MsgStr -match '(\d+\s*%|\d+-)') {
                $stringOffset = $Entry.MsgStr.IndexOf($matches[1])
            }
        }
        
        if ($stringOffset -lt 0) { $stringOffset = 0 }
        $position = Get-PoFilePosition -Entry $Entry -StringOffset $stringOffset
        
        Add-Violation -Violations $Violations -FilePath $FilePath -Entry $Entry `
            -Type "Printf placeholders" `
            -Expected $msgidPrintf.Count `
            -Found $msgstrPrintf.Count `
            -ExpectedItems ($msgidPrintf -join ', ') `
            -FoundItems ($msgstrPrintf -join ', ') `
            -ErrorLine $position.Line `
            -ErrorColumn $position.Column
    }
    elseif ($msgidPrintf.Count -gt 0) {
        Write-Verbose "  [OK] Printf placeholders match ($($msgidPrintf.Count))"
    }
    
    # Test R code expressions
    $msgidRCode = Get-RCodeExpressions -Text $Entry.MsgId
    $msgstrRCode = Get-RCodeExpressions -Text $Entry.MsgStr
    
    if ($msgidRCode.Count -ne $msgstrRCode.Count) {
        $hasViolation = $true
        
        # Find the position of the error
        $stringOffset = 0
        if ($msgstrRCode.Count -gt 0) {
            $stringOffset = $Entry.MsgStr.IndexOf($msgstrRCode[0])
        } elseif ($msgidRCode.Count -gt 0 -and $Entry.MsgStr -match '\d+') {
            $stringOffset = $Entry.MsgStr.IndexOf($matches[0])
        }
        
        if ($stringOffset -lt 0) { $stringOffset = 0 }
        $position = Get-PoFilePosition -Entry $Entry -StringOffset $stringOffset
        
        Add-Violation -Violations $Violations -FilePath $FilePath -Entry $Entry `
            -Type "R code expressions" `
            -Expected $msgidRCode.Count `
            -Found $msgstrRCode.Count `
            -ExpectedItems ($msgidRCode -join ', ') `
            -FoundItems ($msgstrRCode -join ', ') `
            -ErrorLine $position.Line `
            -ErrorColumn $position.Column
    }
    elseif ($msgidRCode.Count -gt 0) {
        # Check for exact match
        $rCodeMatch = $true
        for ($i = 0; $i -lt $msgidRCode.Count; $i++) {
            if ($msgidRCode[$i] -ne $msgstrRCode[$i]) {
                $rCodeMatch = $false
                break
            }
        }
        
        if (-not $rCodeMatch) {
            $hasViolation = $true
            Add-Violation -Violations $Violations -FilePath $FilePath -Entry $Entry `
                -Type "R code expressions (content mismatch)" `
                -Expected $msgidRCode.Count `
                -Found $msgstrRCode.Count `
                -ExpectedItems ($msgidRCode -join ', ') `
                -FoundItems ($msgstrRCode -join ', ')
        }
        else {
            Write-Verbose "  [OK] R code expressions match and preserved ($($msgidRCode.Count))"
        }
    }
    
    # Test Quarto cross-references
    $msgidCrossRefs = Get-QuartoCrossRefs -Text $Entry.MsgId
    $msgstrCrossRefs = Get-QuartoCrossRefs -Text $Entry.MsgStr
    
    if ($msgidCrossRefs.Count -ne $msgstrCrossRefs.Count) {
        $hasViolation = $true
        
        # Find the position of the error
        $stringOffset = 0
        if ($msgstrCrossRefs.Count -gt 0) {
            $stringOffset = $Entry.MsgStr.IndexOf($msgstrCrossRefs[0])
        }
        
        if ($stringOffset -lt 0) { $stringOffset = 0 }
        $position = Get-PoFilePosition -Entry $Entry -StringOffset $stringOffset
        
        Add-Violation -Violations $Violations -FilePath $FilePath -Entry $Entry `
            -Type "Quarto cross-references" `
            -Expected $msgidCrossRefs.Count `
            -Found $msgstrCrossRefs.Count `
            -ExpectedItems ($msgidCrossRefs -join ', ') `
            -FoundItems ($msgstrCrossRefs -join ', ') `
            -ErrorLine $position.Line `
            -ErrorColumn $position.Column
    }
    elseif ($msgidCrossRefs.Count -gt 0) {
        Write-Verbose "  [OK] Quarto cross-references match ($($msgidCrossRefs.Count))"
    }
    
    # Test .NET placeholders
    $msgidDotNet = Get-DotNetPlaceholders -Text $Entry.MsgId
    $msgstrDotNet = Get-DotNetPlaceholders -Text $Entry.MsgStr
    
    if ($msgidDotNet.Count -ne $msgstrDotNet.Count) {
        $hasViolation = $true
        
        # Find the position of the error
        $stringOffset = 0
        if ($msgstrDotNet.Count -gt 0) {
            $stringOffset = $Entry.MsgStr.IndexOf($msgstrDotNet[0])
        }
        
        if ($stringOffset -lt 0) { $stringOffset = 0 }
        $position = Get-PoFilePosition -Entry $Entry -StringOffset $stringOffset
        
        Add-Violation -Violations $Violations -FilePath $FilePath -Entry $Entry `
            -Type ".NET placeholders" `
            -Expected $msgidDotNet.Count `
            -Found $msgstrDotNet.Count `
            -ExpectedItems ($msgidDotNet -join ', ') `
            -FoundItems ($msgstrDotNet -join ', ') `
            -ErrorLine $position.Line `
            -ErrorColumn $position.Column
    }
    elseif ($msgidDotNet.Count -gt 0) {
        Write-Verbose "  [OK] .NET placeholders match ($($msgidDotNet.Count))"
    }
    
    # Test LaTeX text markers
    $msgidLaTeX = Get-LaTeXTextMarkers -Text $Entry.MsgId
    $msgstrLaTeX = Get-LaTeXTextMarkers -Text $Entry.MsgStr
    
    if ($msgidLaTeX.Count -ne $msgstrLaTeX.Count) {
        $hasViolation = $true
        
        # Find the position of the error
        $stringOffset = 0
        if ($msgstrLaTeX.Count -gt 0) {
            $stringOffset = $Entry.MsgStr.IndexOf($msgstrLaTeX[0])
        }
        
        if ($stringOffset -lt 0) { $stringOffset = 0 }
        $position = Get-PoFilePosition -Entry $Entry -StringOffset $stringOffset
        
        Add-Violation -Violations $Violations -FilePath $FilePath -Entry $Entry `
            -Type "LaTeX text markers" `
            -Expected $msgidLaTeX.Count `
            -Found $msgstrLaTeX.Count `
            -ExpectedItems ($msgidLaTeX -join ', ') `
            -FoundItems ($msgstrLaTeX -join ', ') `
            -ErrorLine $position.Line `
            -ErrorColumn $position.Column
    }
    elseif ($msgidLaTeX.Count -gt 0) {
        Write-Verbose "  [OK] LaTeX text markers match ($($msgidLaTeX.Count))"
    }
    
    return $hasViolation
}

function Add-Violation {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.ArrayList]$Violations,
        
        [Parameter(Mandatory)]
        [string]$FilePath,
        
        [Parameter(Mandatory)]
        [PSCustomObject]$Entry,
        
        [Parameter(Mandatory)]
        [string]$Type,
        
        [Parameter(Mandatory)]
        [int]$Expected,
        
        [Parameter(Mandatory)]
        [int]$Found,
        
        [Parameter()]
        [string]$ExpectedItems = '',
        
        [Parameter()]
        [string]$FoundItems = '',
        
        [Parameter()]
        [int]$ErrorLine = -1,
        
        [Parameter()]
        [int]$ErrorColumn = -1
    )
    
    # Use provided error position or default to entry position
    $line = if ($ErrorLine -gt 0) { $ErrorLine } else { $Entry.LineNumber }
    $column = if ($ErrorColumn -gt 0) { $ErrorColumn } else { $Entry.Column }
    
    $violation = [PSCustomObject]@{
        File = $FilePath
        Line = $line
        Column = $column
        Type = $Type
        Expected = $Expected
        Found = $Found
        ExpectedItems = $ExpectedItems
        FoundItems = $FoundItems
        MsgId = $Entry.MsgId
        MsgStr = $Entry.MsgStr
        SourceRef = $Entry.SourceRef
    }
    
    $null = $Violations.Add($violation)
}

function Format-Violation {
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Violation
    )
    
    $msgIdPreview = Get-StringPreview -Text $Violation.MsgId -MaxLength 100
    $msgStrPreview = Get-StringPreview -Text $Violation.MsgStr -MaxLength 100
    
    # Use VS Code-friendly format: file:line:column: severity: message
    # This makes the file path clickable in VS Code's terminal
    $output = "$($Violation.File):$($Violation.Line):$($Violation.Column): error: $($Violation.Type): expected $($Violation.Expected), found $($Violation.Found)`n"
    
    if ($Violation.ExpectedItems) {
        $output += "  Expected: $($Violation.ExpectedItems)`n"
    }
    if ($Violation.FoundItems) {
        $output += "  Found: $($Violation.FoundItems)`n"
    }
    
    $output += "  msgid:  $msgIdPreview`n"
    $output += "  msgstr: $msgStrPreview"
    
    if ($Violation.SourceRef) {
        $output += "`n  source: $($Violation.SourceRef)"
    }
    
    return $output
}

function Get-StringPreview {
    param(
        [Parameter(Mandatory)]
        [string]$Text,
        
        [Parameter()]
        [int]$MaxLength = 100
    )
    
    $preview = $Text -replace '\r?\n', '↵'
    
    if ($preview.Length -gt $MaxLength) {
        $preview = $preview.Substring(0, $MaxLength) + '...'
    }
    
    return $preview
}

#endregion

#region Main Logic

# Resolve file paths
$filesToValidate = @()

if ($Include) {
    $filesToValidate = $Include | ForEach-Object {
        if (Test-Path $_) {
            Get-Item $_ | Select-Object -ExpandProperty FullName
        }
    }
}
else {
    if (Test-Path $Path -PathType Container) {
        $filesToValidate = Get-ChildItem -Path $Path -Filter "*.po" -File | Select-Object -ExpandProperty FullName
    }
    elseif (Test-Path $Path) {
        $filesToValidate = @((Get-Item $Path).FullName)
    }
    else {
        $filesToValidate = Get-ChildItem -Path $Path -File | Select-Object -ExpandProperty FullName
    }
}

# Filter by category
if ($Category -ne 'all') {
    $filesToValidate = $filesToValidate | Where-Object {
        $fileName = Split-Path -Leaf $_
        $fileName -match "^$Category\."
    }
}

if ($filesToValidate.Count -eq 0) {
    Write-Warning "No PO files found matching the specified criteria."
    exit 0
}

Write-Host "Validating $($filesToValidate.Count) PO file(s)..." -ForegroundColor Cyan
Write-Host

$allViolations = New-Object System.Collections.ArrayList
$totalEntries = 0
$fileStats = @{}

foreach ($file in $filesToValidate) {
    $fileName = Split-Path -Leaf $file
    Write-Verbose "Processing $fileName..."
    
    $entries = Get-PoEntries -FilePath $file
    $totalEntries += $entries.Count
    
    $fileViolations = 0
    
    foreach ($entry in $entries) {
        Write-Verbose "  Checking line $($entry.LineNumber)..."
        
        $hasViolation = Test-PlaceholderMatch -Entry $entry -FilePath $file -Violations $allViolations
        
        if ($hasViolation) {
            $fileViolations++
        }
    }
    
    $fileStats[$file] = @{
        Entries = $entries.Count
        Violations = $fileViolations
    }
    
    if ($fileViolations -eq 0) {
        Write-Verbose "  ${fileName}: All entries valid"
    }
}

# Display violations
$output = [System.Text.StringBuilder]::new()

foreach ($violation in $allViolations) {
    $formattedViolation = Format-Violation -Violation $violation
    Write-Host $formattedViolation -ForegroundColor Red
    Write-Host
    
    $null = $output.AppendLine($formattedViolation)
    $null = $output.AppendLine()
}

# Summary
if (-not $Quiet) {
    Write-Host ("=" * 80) -ForegroundColor Cyan
    Write-Host "VALIDATION SUMMARY" -ForegroundColor Cyan
    Write-Host ("=" * 80) -ForegroundColor Cyan
    Write-Host
    Write-Host "Total entries validated: $totalEntries"
    Write-Host "Total violations found: $($allViolations.Count)" -ForegroundColor $(if ($allViolations.Count -eq 0) { 'Green' } else { 'Red' })
    Write-Host
    
    # Violations by type
    if ($allViolations.Count -gt 0) {
        Write-Host "Violations by type:"
        $violationsByType = $allViolations | Group-Object -Property Type | Sort-Object -Property Count -Descending
        foreach ($group in $violationsByType) {
            Write-Host "  $($group.Name): $($group.Count)" -ForegroundColor Yellow
        }
        Write-Host
        
        # Files with violations
        Write-Host "Files with violations:"
        foreach ($file in $fileStats.Keys | Sort-Object) {
            $stats = $fileStats[$file]
            if ($stats.Violations -gt 0) {
                $fileName = Split-Path -Leaf $file
                Write-Host "  ${fileName}: $($stats.Violations) violation(s) in $($stats.Entries) entries" -ForegroundColor Yellow
            }
        }
    }
    else {
        Write-Host "All placeholder validations passed! ✓" -ForegroundColor Green
    }
    
    $null = $output.AppendLine("=" * 80)
    $null = $output.AppendLine("VALIDATION SUMMARY")
    $null = $output.AppendLine("=" * 80)
    $null = $output.AppendLine()
    $null = $output.AppendLine("Total entries validated: $totalEntries")
    $null = $output.AppendLine("Total violations found: $($allViolations.Count)")
    $null = $output.AppendLine()
    
    if ($allViolations.Count -gt 0) {
        $null = $output.AppendLine("Violations by type:")
        $violationsByType = $allViolations | Group-Object -Property Type | Sort-Object -Property Count -Descending
        foreach ($group in $violationsByType) {
            $null = $output.AppendLine("  $($group.Name): $($group.Count)")
        }
        $null = $output.AppendLine()
        
        $null = $output.AppendLine("Files with violations:")
        foreach ($file in $fileStats.Keys | Sort-Object) {
            $stats = $fileStats[$file]
            if ($stats.Violations -gt 0) {
                $fileName = Split-Path -Leaf $file
                $null = $output.AppendLine("  ${fileName}: $($stats.Violations) violation(s) in $($stats.Entries) entries")
            }
        }
    }
}

# Write output file if specified
if ($OutputFile) {
    $output.ToString() | Out-File -FilePath $OutputFile -Encoding UTF8
    Write-Host
    Write-Host "Results written to: $OutputFile" -ForegroundColor Cyan
}

# Return exit code (violation count capped at 255)
$exitCode = [Math]::Min($allViolations.Count, 255)
exit $exitCode

#endregion
