[CmdletBinding(PositionalBinding, SupportsShouldProcess)]
param(
    [Parameter(Position=0, Mandatory)]
    [string]$LiteralPath,
    [Parameter(Position=1)]
    [string]$OutputDirectory = (Join-Path -Path (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'metadata') -Relative) -ChildPath (Get-Date -AsUTC -Format FileDateTimeUniversal)),
    [string[]]$TranslationLanguages = @('de', 'es', 'fr', 'gr', 'it'),
    [switch]$IncudeIds,
    [switch]$NoSharing,
    [switch]$ForExcel
)

Import-Module -Name (Join-Path -Resolve -Path $PSScriptRoot -ChildPath 'modules' -AdditionalChildPath 'NeoIPC-Tools') -Force -Verbose:$false

# Dev mode
$ForExcel = $true

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
