#!/usr/bin/env pwsh
#Requires -Version 7.6

<#
.SYNOPSIS
    Updates the protocol translation sources for one culture.

.DESCRIPTION
    Builds the manifest of translatable protocol inputs for the requested culture and drives their update.
    Three kinds of source are handled: the AsciiDoc protocol and definition files, the .NET resource files
    behind the generated figures, and the localized-attributes file that is copied rather than extracted.

    Already-localized files are excluded by construction: any source whose basename ends in a known culture
    name is skipped, so a previous run's output is never re-ingested as new source.

    The invariant culture is rejected outright — it names no language, so there is nothing to translate to.

.PARAMETER CultureInfo
    Target culture, for example de or es-ES.

.EXAMPLE
    ./scripts/Update-Translation.ps1 -CultureInfo de
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [CultureInfo]$CultureInfo
    )

if ($CultureInfo.Name.Length -eq 0) {
    Write-Error 'The invariant culture is not a valid input for this script'
    exit 1
}

# Write CSV rows as UTF-8 without a BOM and with LF line endings.
#
# `Export-Csv` joins its rows with [Environment]::NewLine, so on Windows it wrote the committed
# translation CSVs in CRLF — the same files po4a, Weblate and the R readers all treat as LF. Taking the
# rows from `ConvertTo-Csv` and writing them here is what pins the line endings; `-Encoding utf8NoBOM`
# was already correct and only the newlines were wrong.
#
# The overwrite prompt is reproduced on purpose. Export-Csv was called with
# `-Confirm:(Test-Path $newPath)` — confirm only when the file already exists — and quietly dropping
# that would turn a guarded overwrite into a silent one.
function Write-CsvLines {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LiteralPath,
        [Parameter(ValueFromPipeline)][string[]]$Line
    )

    begin { $collected = [System.Collections.Generic.List[string]]::new() }
    process { foreach ($l in $Line) { $collected.Add($l) } }
    end {
        if ((Test-Path -LiteralPath $LiteralPath) -and
            -not $PSCmdlet.ShouldContinue("Overwrite the existing file '$LiteralPath'?", 'Confirm')) {
            return
        }
        [System.IO.File]::WriteAllText(
            $LiteralPath, (($collected -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
    }
}
$workspaceFolder = Join-Path -Path $PSScriptRoot -ChildPath '..' -Resolve
$cultureNames = [System.Globalization.CultureInfo]::GetCultures([System.Globalization.CultureTypes]::AllCultures).Name | Where-Object { $_.Length -gt 0 }
$inputFileInfos = @(
    @{
        path = Join-Path -Path $workspaceFolder -ChildPath 'doc' -AdditionalChildPath 'locale','attributes-en.adoc' -Resolve | Get-Item
        type = 'copy_localized'
        source_language = 'en'
    }
    @{
        paths = Join-Path -Path $workspaceFolder -ChildPath 'doc' -AdditionalChildPath 'protocol','resx','*.resx' -Resolve | ForEach-Object {
            $swallow = $false
            foreach ($c in $cultureNames) {
                if ([System.IO.Path]::GetFileNameWithoutExtension($_).EndsWith(".$c")) {
                    $swallow = $true
                    break
                }
            }
            if (-not $swallow) {
                $_
            }
        }
        type = 'resx'
    }
    @{
        paths = @(Join-Path -Path $workspaceFolder -ChildPath 'doc' -AdditionalChildPath 'protocol','*.adoc' -Resolve) +
        @(Join-Path -Path $workspaceFolder -ChildPath 'doc' -AdditionalChildPath 'protocol','definitions','*.adoc' -Resolve) | ForEach-Object {
            $fileBaseName = [System.IO.Path]::GetFileNameWithoutExtension($_)
            $swallow = $false
            if ($fileBaseName.EndsWith('Header')) {
                $swallow = $true
            }
            else {
                foreach ($c in $cultureNames) {
                    if ($fileBaseName.EndsWith(".$c")) {
                        $swallow = $true
                        break
                    }
                }
            }

            if (-not $swallow) { $_ }
        }
        type = 'adoc'
    }
    @{
        path = Join-Path -Path $workspaceFolder -ChildPath 'metadata' -AdditionalChildPath 'common','infectious-agents','ListElements.csv' -Resolve
        type = 'csv'
        key = 'id'
        translatedProperties = @('value')
    }
    @{
        path = Join-Path -Path $workspaceFolder -ChildPath 'metadata' -AdditionalChildPath 'common','infectious-agents','NeoIPC-Pathogen-Concepts.csv' -Resolve
        type = 'csv'
        key = 'id'
        translatedProperties = @('concept')
    }
    @{
        path = Join-Path -Path $workspaceFolder -ChildPath 'metadata' -AdditionalChildPath 'common','infectious-agents','NeoIPC-Pathogen-Synonyms.csv' -Resolve
        type = 'csv'
        key = 'id'
        translatedProperties = @('synonym')
    }
)

foreach ($inputFileInfo in $inputFileInfos ) {
    switch -exact -casesensitive ($inputFileInfo.type) {
        'csv' {
            $fileContent = Import-Csv -LiteralPath $inputFileInfo.path -Encoding utf8NoBOM
            $allProperties = $fileContent | Select-Object -First 1 | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name
            $inputFileInfo.translatedProperties + $inputFileInfo.key | ForEach-Object {
                if ($allProperties -cnotcontains $_) {
                    Write-Error "The input file '$($inputFileInfo.path)' does not contain the required column '$_'."
                    exit 1
                }
            }
            $propertiesWithKeys = $inputFileInfo.translatedProperties | ForEach-Object { $r = $_ -creplace '(\p{Lu})','_$1'; @{ property = $_; key = $r.TrimStart('_').ToUpper()} }
            $newPath = [System.IO.Path]::ChangeExtension($inputFileInfo.path, $($CultureInfo.Name)+$([System.IO.Path]::GetExtension($inputFileInfo.path)))
            $fileContent | ForEach-Object {
                $line = $_
                $propertiesWithKeys | ForEach-Object {
                    [ordered]@{
                        id = $line.$($inputFileInfo.key)
                        property = $_.key
                        needs_translation = 'u'
                        default = $line.$($_.property)
                        translated = ''
                    }
                }
            } | ConvertTo-Csv -UseQuotes AsNeeded | Write-CsvLines -LiteralPath $newPath
        }
        'copy_localized' {
            $newPath = Join-Path -Path $inputFileInfo.path.DirectoryName -ChildPath ($inputFileInfo.path.Name -replace "([^A-Za-z0-9])$($inputFileInfo.source_language)([^A-Za-z0-9])","`$1$($CultureInfo.Name)`$2")
            # Copy the file with conditional confirmation
            Copy-Item -Path $inputFileInfo.path -Destination $newPath -Confirm:(Test-Path $newPath)
        }
        'resx' {
            foreach ($path in $inputFileInfo.paths) {
                $newPath = [System.IO.Path]::ChangeExtension($path, $($CultureInfo.Name)+$([System.IO.Path]::GetExtension($path)))
                Copy-Item -LiteralPath $path -Destination $newPath -Confirm:(Test-Path $newPath)
            }
        }
        'adoc' {
            foreach ($path in $inputFileInfo.paths) {
                $newPath = [System.IO.Path]::ChangeExtension($path, $($CultureInfo.Name)+$([System.IO.Path]::GetExtension($path)))
                Copy-Item -LiteralPath $path -Destination $newPath -Confirm:(Test-Path $newPath)
            }
        }
    }
}
