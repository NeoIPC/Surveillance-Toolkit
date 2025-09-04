[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [CultureInfo]$CultureInfo
    )

if ($CultureInfo.Name.Length -eq 0) {
    Write-Error 'The invariant culture is not a valid input for this script'
    exit 1
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
        path = Join-Path -Path $workspaceFolder -ChildPath 'metadata' -AdditionalChildPath 'common','antibiotics','ListElements.csv' -Resolve
        type = 'csv'
        key = 'id'
        translatedProperties = @('value')
    }
    @{
        path = Join-Path -Path $workspaceFolder -ChildPath 'metadata' -AdditionalChildPath 'common','antibiotics','NeoIPC-Antibiotics.csv' -Resolve
        type = 'csv'
        key = 'atc_code'
        translatedProperties = @('name')
    }
    @{
        path = Join-Path -Path $workspaceFolder -ChildPath 'metadata' -AdditionalChildPath 'common','organisation_units','organisationUnits.csv' -Resolve
        type = 'csv'
        key = 'code'
        translatedProperties = @('name','shortName')
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
    @{
        path = Join-Path -Path $workspaceFolder -ChildPath 'metadata' -AdditionalChildPath 'play','organisationUnits.csv' -Resolve
        type = 'csv'
        key = 'code'
        translatedProperties = @('name','shortName')
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
            } | Export-Csv -LiteralPath $newPath -Encoding utf8NoBOM -UseQuotes AsNeeded -Confirm:(Test-Path $newPath)
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
