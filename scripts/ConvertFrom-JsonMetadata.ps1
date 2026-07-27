#!/usr/bin/env pwsh
#Requires -Version 7.6

<#
.SYNOPSIS
    Converts a DHIS2 metadata JSON export into the authored CSV metadata directory.

.DESCRIPTION
    Takes a metadata export and writes it out as the per-type CSVs (plus externalized expression files)
    that make up the authored metadata directory — the reviewable, diffable form the pipeline builds from,
    as opposed to a single opaque JSON document.

    Output lands in a timestamped directory by default, so a conversion never overwrites a previous one and
    two runs can be compared.

.PARAMETER LiteralPath
    The metadata JSON export to convert.

.PARAMETER OutputDirectory
    Destination directory. Defaults to a UTC-timestamped directory under the metadata directory.

.PARAMETER TranslationLanguages
    Languages whose translation columns are emitted.

.EXAMPLE
    ./scripts/ConvertFrom-JsonMetadata.ps1 ./export.json
#>

[CmdletBinding(PositionalBinding, SupportsShouldProcess)]
param(
    [Parameter(Position=0, Mandatory)]
    [string]$LiteralPath,
    [Parameter(Position=1)]
    [string]$OutputDirectory = (Join-Path -Path (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'metadata') -Relative) -ChildPath (Get-Date -AsUTC -Format FileDateTimeUniversal)),
    [string[]]$TranslationLanguages = @('de', 'el', 'es', 'fr', 'it'),
    [switch]$IncudeIds,
    [switch]$NoSharing,
    # A [bool] rather than a [switch] precisely because it defaults ON, which is what this script has
    # actually done for a long time: the body used to force `$ForExcel = $true` under a "Dev mode" comment,
    # so the switch was inert and passing it changed nothing. Declaring the default here keeps that
    # behaviour while making the parameter real again — `-ForExcel $false` now genuinely selects the
    # utf8NoBOM / invariant-separator output. A switch defaulting to true would be the anti-pattern
    # PSAvoidDefaultValueSwitchParameter names, and `-ForExcel:$false` reads far worse than `-ForExcel $false`.
    [bool]$ForExcel = $true
)

Import-Module -Name (Join-Path -Resolve -Path $PSScriptRoot -ChildPath 'modules' -AdditionalChildPath 'NeoIPC-BuildTools') -Force -Verbose:$false

# In the default (-ForExcel) mode the CSV output is deliberately exempt from the LF/no-BOM text contract,
# and must stay that way: what this script emits is a **generated Excel deliverable**, not repository
# content — none of these CSVs is committed. Excel misreads a BOM-less UTF-8 CSV as the local ANSI code
# page, so the BOM is what makes the file open correctly on a double-click, and -UseCulture matches the list
# separator the user's Excel expects. `Export-Csv` is therefore kept here (with its [Environment]::NewLine
# row joins) rather than replaced by the ConvertTo-Csv + WriteAllText pattern used for committed files.
#
# Under `-ForExcel $false` the output is utf8NoBOM with an invariant separator, which is the shape a
# machine consumer wants. That branch is not newline-pinned either; if its output ever becomes an input to
# something that cares, pin it there rather than weakening the Excel branch.
if ($ForExcel) {
    $csvOutputEncoding = 'utf8BOM'
    $useCultureInCsvOutput = $true
} else {
    $csvOutputEncoding = 'utf8NoBOM'
    $useCultureInCsvOutput = $false
}

$resolvedPath = Resolve-Path -LiteralPath $LiteralPath -Relative

Write-Information "Converting JSON metadata from $resolvedPath to CSV in directory $OutputDirectory"
$metadata = Get-Content -Raw -Path $resolvedPath | ConvertFrom-Json -AsHashtable
if ($metadata.ContainsKey('users')) {
    Write-Verbose "Creating user map"
    $userMap = $metadata['users'] | Get-CodeMap
}
if ($metadata.ContainsKey('userRoles')) {
    Write-Verbose "Creating user role map"
    $userRoleMap = $metadata['userRoles'] | Get-CodeMap
}
if ($metadata.ContainsKey('userGroups')) {
    Write-Verbose "Creating user group map"
    $userGroupMap = $metadata['userGroups'] | Get-CodeMap
}
$metadata | Get-ChildObject | Foreach-Object {
    $objectName = $_.Name
    switch ($objectName) {
        'apiToken' {
            Write-Debug "Metadata object '$objectName' is ignored"
            return
        }
        'attributes' {
            $exportSharing = -not $NoSharing.IsPresent
            $sortProperties = 'name'
            $properties = Get-ObjectProperties -ObjectName $objectName -AddIdProperty:$IncudeIds.IsPresent -AddSharingProperties:$exportSharing
        }
        'dataElements' {
            $exportSharing = -not $NoSharing.IsPresent
            $sortProperties = 'name'
            $properties = Get-ObjectProperties -ObjectName $objectName -AddIdProperty:$IncudeIds.IsPresent -AddSharingProperties:$exportSharing
        }
        'optionSets' {
            $exportSharing = -not $NoSharing.IsPresent
            $sortProperties = 'name'
            $properties = Get-ObjectProperties -ObjectName $objectName -AddIdProperty:$IncudeIds.IsPresent -AddSharingProperties:$exportSharing
        }
        Default {
            Write-Warning "Metadata object '$objectName' is not handled"
            return #throw "Unnown object: '$objectName'"
        }
    }
    $obj = $_.Value
    $dir = Initialize-ObjectDirectory -BasePath $OutputDirectory -ObjectNames $objectName
    Write-Verbose "Exporting $objectName to directory $dir"
    $file = Join-Path -Path $dir -ChildPath 'data.csv'
    Write-Verbose "Creating file $file"
    $obj |
        Sort-Object -Property $sortProperties |
        Select-Object -Property $properties |
        Export-Csv -LiteralPath $file -Encoding $csvOutputEncoding -UseCulture:$useCultureInCsvOutput -UseQuotes AsNeeded

    if ($exportSharing) {
        Write-Verbose "Exporting group sharing information"
        $sharingFile = Join-Path -Path $dir -ChildPath 'group_sharings.csv'
        $csv = $obj |
            Sort-Object -Property $sortProperties |
            Select-Object -Property code -ExpandProperty Sharing |
            Select-Object -Property code -ExpandProperty userGroups |
            Select-Object -Property code -ExpandProperty values |
            Select-Object -Property code,@{name='group_code';expression={
                if ($userGroupMap -and $userGroupMap.Contains($_.id)) {
                    Write-Debug "Mapping group id '$($_.id)' to code '$($userGroupMap[$_.id])'"
                    $userGroupMap[$_.id]
                } else {
                    Write-Warning "Failed to map a code for the group with the id '$($_.id)'."
                    $_.id
                }
            }},access
        if ($csv) {
            Write-Verbose "Creating file $sharingFile"
            $csv | Export-Csv -LiteralPath $sharingFile -Encoding $csvOutputEncoding -UseCulture:$useCultureInCsvOutput -UseQuotes AsNeeded
        } else {
            Write-Verbose "Skipping empty export"
        }

        Write-Verbose "Exporting user sharing information"
        $sharingFile = Join-Path -Path $dir -ChildPath 'user_sharings.csv'
        $csv = $obj |
            Sort-Object -Property $sortProperties |
            Select-Object -ExpandProperty Sharing |
            Select-Object -ExpandProperty users |
            Select-Object -ExpandProperty values |
            Select-Object -Property @{name='user_code';expression={
                if ($userMap -and $userMap.Contains($_.id)) {
                    Write-Debug "Mapping user id '$($_.id)' to code '$($userMap[$_.id])'"
                    $userMap[$_.sharing.owner]
                } else {
                    Write-Warning "Failed to map a code for the user with the id '$($_.id)'."
                    $_.id
                }
            }},access
        if ($csv) {
            Write-Verbose "Creating file $sharingFile"
            $csv | Export-Csv -LiteralPath $sharingFile -Encoding $csvOutputEncoding -UseCulture:$useCultureInCsvOutput -UseQuotes AsNeeded
        } else {
            Write-Verbose "Skipping empty export"
        }
    }
}
