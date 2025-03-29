[CmdletBinding()]
param(
    [switch]$Play,
    [switch]$WithOrganisationUnits,
    [switch]$Compress
)

$metadataDir = (Resolve-Path -Path "$PSScriptRoot/../metadata").Path
$WithOrganisationUnits = $true

$metadata = @{}

function Import-Translations {
    param (
        [string]$LiteralPath,
        [string]$BaseName
    )
    $translationDict = @{}
    foreach ($tf in (Get-ChildItem -LiteralPath $LiteralPath -Filter "$BaseName.*.csv")) {
        $lang = $tf.Name -replace "$BaseName\.([a-z]{2})\.csv",'$1'
        $translations = Import-Csv -LiteralPath $tf.FullName
        foreach ($t in $translations) {
            if (-not $translationDict.ContainsKey($t.code)) {
                $translationsList = [System.Collections.ArrayList]::new()
                $translationDict[$t.code] = $translationsList
            } else {
                $translationsList = $translationDict[$t.code]
            }
            if ($t.needs_translation -eq 't') {
                $translationsList.Add(@{locale=$lang;property=$t.property;value=$t.translated}) > $null
            }
        }
    }
    return $translationDict
}

function Import-OrganisationUnits {
    param (
        [string]$LiteralPath,
        [hashtable]$Translations
    )
    $ouList = [System.Collections.ArrayList]::new()
    $organisationUnits = Import-Csv -LiteralPath $LiteralPath
    foreach ($organisationUnit in $organisationUnits) {
        $ou = @{}
        $ou.code = $organisationUnit.code
        $ou.name = $organisationUnit.name
        $ou.shortName = $organisationUnit.shortName
        $ou.openingDate = $organisationUnit.openingDate
        if ($Translations.ContainsKey($organisationUnit.code)) {
            $ou.translations = $Translations[$organisationUnit.code].ToArray()
        }
        if ($organisationUnit.parent_code) {
            $ou.parent = @{ code = $organisationUnit.parent_code }
        }
        $ouList.Add($ou) > $null
    }
    return $ouList
}

if ($WithOrganisationUnits) {

    $translationDict = Import-Translations -LiteralPath "$metadataDir/common/organisation_units" -BaseName 'organisationUnits'
    $ouList = @(Import-OrganisationUnits -LiteralPath "$metadataDir/common/organisation_units/organisationUnits.csv" -Translations $translationDict)
    if ($Play) {
        $translationDict = Import-Translations -LiteralPath "$metadataDir/play" -BaseName 'organisationUnits'
        $ouList += @(Import-OrganisationUnits -LiteralPath "$metadataDir/play/organisationUnits.csv" -Translations $translationDict)
    }
    $metadata['organisationUnits'] = $ouList
}


ConvertTo-Json -InputObject $metadata -Depth 100 -Compress:$Compress.IsPresent |
    Out-File -LiteralPath $PSScriptRoot/metadata.json -Encoding utf8NoBOM -Force
