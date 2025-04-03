[AppContext]::SetSwitch("Switch.System.Xml.AllowDefaultResolver", $true);

$AtcUrlTemplate = 'https://www.whocc.no/atc_ddd_index/?code={0}&showdescription=yes'
$AWaReUrlTemplate = 'https://aware.essentialmeds.org/list?query=%22{0}%22'
$LspnUrlTemplate = 'https://lpsn.dsmz.de/{0}'
$MycoBankUrlTemplate = 'https://www.mycobank.org/page/Name%20details%20page/field/Mycobank%20%23/{0}'
$IctvUrlTemplate = 'https://ictv.global/taxonomy/taxondetails?taxnode_id={0}'

function Export-AsciiDocIds {
    param(
        [Parameter(Mandatory)]
        [string]$LiteralPath,
        [switch]$LineNumbers,
        [switch]$FileNames
    )

    $file = Get-Item -LiteralPath $LiteralPath
    $lineNumber = 0
    if ($FileNames) { "File: $($file.FullName)" }
    Get-Content -LiteralPath $file.FullName |
    ForEach-Object {
        $line = $_
        $lineNumber++
        switch -regex ($Line) {
            '^include::(\S+)\[\]' {
                $childFile = Join-Path -Path $file.DirectoryName -ChildPath $matches[1] -Resolve -ErrorAction SilentlyContinue -ErrorVariable includeFileError
                if ($childFile) {
                    Export-AsciiDocIds -LiteralPath $childFile -LineNumbers:$LineNumbers.IsPresent -FileNames:$FileNames.IsPresent
                    if ($FileNames) { "File: $($file.FullName)" }
                }
                else {
                    foreach ($w in $includeFileError) {
                        Write-Warning $w
                    }
                }
            }
            '\[\[(\S+)\]\]' {
                if ($LineNumbers) { "$($lineNumber):$($matches[1])" }
                else { $matches[1] }
            }
            '\[#(\S+)\]' {
                if ($LineNumbers) { "$($lineNumber):$($matches[1])" }
                else { $matches[1] }
            }
        }
    }
}

function Export-AsciiDocReferences {
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$LiteralPath,
        [Parameter(Position = 2)]
        [hashtable]$Attributes
    )

    $file = Get-Item -LiteralPath $LiteralPath
    $skip = $false;
    Get-Content -LiteralPath $file.FullName |
    ForEach-Object {
        $line = $_
        switch -regex ($Line) {
            # Singleline ifdef
            '^ifdef::([A-Za-z0-9_\-]+)\[.+\]' {
                if ($skip) { return }
                if (-not ($Attributes -and $Attributes.ContainsKey($matches[1]))) {
                    Write-Debug "Skipping '$_' because the attribute '$($matches[1])' is not defined."
                    return
                }
            }
            # Singleline ifndef
            '^ifndef::([A-Za-z0-9_\-]+)\[.+\]' {
                if ($skip) { return }
                if ($Attributes -and $Attributes.ContainsKey($matches[1])) {
                    Write-Debug "Skipping '$_' because the attribute '$($matches[1])' is defined."
                    return
                }
            }
            # Multiline ifdef
            '^ifdef::([A-Za-z0-9_\-]+)\[\]' {
                if (-not ($Attributes -and $Attributes.ContainsKey($matches[1]))) {
                    Write-Debug "Starting to skip lines within '$_' because the attribute '$($matches[1])' is not defined."
                    $skip = $true
                    return
                }
            }
            # Multiline ifndef
            '^ifndef::([A-Za-z0-9_\-]+)\[\]' {
                if ($Attributes -and $Attributes.ContainsKey($matches[1])) {
                    Write-Debug "Starting to skip lines within '$_' because the attribute '$($matches[1])' is not defined."
                    $skip = $true
                    return
                }
            }
            # endif
            '^endif::[A-Za-z0-9_\-]*\[\]' {
                Write-Debug "Stopping to skip lines."
                $skip = $false
            }
            '^//' {
                # Skip commented lines
                return
            }
            'include::([^[]+)\[.*\]' {
                if ($skip) { return }
                $expanded = $matches[1]
                $expanded = $expanded -replace '\{([A-Za-z0-9_\-]+)\}',{
                    $attribute = $_.Groups[1].Value
                    if ($Attributes -and $Attributes.ContainsKey($attribute)) {
                        $Attributes[$attribute]
                    } else {
                        Write-Error "Cannot resolve attribute reference '{$attribute}' in include '$expanded'."
                        break
                    }
                }
                $childFile = Join-Path -Path $file.DirectoryName -ChildPath $expanded -Resolve -ErrorAction SilentlyContinue -ErrorVariable includeFileError
                if ($childFile) {
                    $childFile
                    Export-AsciiDocReferences -LiteralPath $childFile -Attributes $Attributes
                }
                else {
                    foreach ($w in $includeFileError) {
                        Write-Warning $w
                    }
                }
                return
            }
            'image::?([^[ ]+)\[.*\]' {
                if ($skip) { return }
                $expanded = $matches[1]
                $expanded = $expanded -replace '\{([A-Za-z0-9_\-]+)\}',{
                    $attribute = $_.Groups[1].Value
                    if ($Attributes -and $Attributes.ContainsKey($attribute)) {
                        $Attributes[$attribute]
                    } else {
                        Write-Error "Cannot resolve attribute reference '{$attribute}' in image '$expanded'."
                        break
                    }
                }
                $imageFile = Join-Path -Path $file.DirectoryName -ChildPath 'img' -AdditionalChildPath $expanded -Resolve -ErrorAction SilentlyContinue -ErrorVariable includeFileError
                if ($imageFile) {
                    $imageFile
                }
                else {
                    foreach ($w in $includeFileError) {
                        Write-Warning $w
                    }
                }
                return
            }
        }
    }
}

function Build-Target {
    param (
        [Parameter(Mandatory, Position = 0)]
        [string]$TargetFilePath,
        [Parameter(Mandatory, Position = 1)]
        [string[]]$InputFiles,
        [Parameter(Mandatory, Position = 2)]
        [scriptblock]$Command
    )

    # Check if the output file exists
    if (-not (Test-Path $TargetFilePath)) {
        Write-Debug "Output file not found. Running command..."
        & $Command
        return
    }

    # Get the timestamp of the output file
    $outputTimestamp = (Get-Item $TargetFilePath).LastWriteTime

    # Iterate through input files
    foreach ($inputFile in (Resolve-Path -Path $InputFiles)) {
        # Check if the input file exists
        if (-not (Test-Path $inputFile)) {
            Write-Debug "Input file '$inputFile' not found. Skipping..."
            continue
        }

        # Get the timestamp of the input file
        $inputTimestamp = (Get-Item $inputFile).LastWriteTime

        # Compare timestamps
        if ($inputTimestamp -gt $outputTimestamp) {
            Write-Debug "Input file '$inputFile' is newer than output file. Running command..."
            & $Command
            return
        }
    }

    Write-Debug "All input files are older or equal to the output file. No need to run the command."
}

function Get-LocalisedPath {
    [CmdletBinding(DefaultParameterSetName = 'DirectoryFile')]
    param (
        [Parameter(Mandatory, ParameterSetName = 'LiteralPath', Position = 0)]
        [string]$LiteralPath,
        [Parameter(Mandatory, ParameterSetName = 'DirectoryFile', Position = 0)]
        [string]$Directory,
        [Parameter(Mandatory, ParameterSetName = 'DirectoryFile', Position = 1)]
        [string]$File,
        [Parameter(Mandatory, ParameterSetName = 'LiteralPath', Position = 1)]
        [Parameter(Mandatory, ParameterSetName = 'DirectoryFile', Position = 2)]
        [CultureInfo]$TargetCulture,
        [switch]$Resolve,
        [switch]$All,
        [switch]$Existing
    )

    do {
        if (-not $LiteralPath) { $LiteralPath = Join-Path -Path $Directory -ChildPath $File }
        $path = [System.IO.Path]::ChangeExtension($LiteralPath, $TargetCulture.Name + [System.IO.Path]::GetExtension($LiteralPath))
        $TargetCulture = $TargetCulture.Parent
        if ($Resolve) {
            if ($Existing) {
                $path = Resolve-Path -LiteralPath $path -ErrorAction SilentlyContinue
            } else {
                $path = Resolve-Path -LiteralPath $path
            }
        } elseif ($Existing -and -not (Test-Path -LiteralPath $path)) {
            if ($All) {
                continue
            } else {
                return
            }
        }
        if ($All) { $path } else { return $path }
    } while ($TargetCulture.Name)
}

function Import-Translations {
    param (
        [Parameter(Mandatory)]
        [string]$LiteralPath,
        [Parameter(Mandatory)]
        [CultureInfo]$TargetCulture,
        [Parameter(Mandatory)]
        [string[]]$ExpectedProperties
    )

    $translations = [System.Collections.Generic.List[PSCustomObject]]::new()
    # Import translations for the target culture and all of its parent cultures up to (excluding) the invarinat culture into a list of dictionaries.
    $culture = $TargetCulture
    $cultureNames = [System.Collections.Generic.List[string]]::new()
    while ($culture.Name) {
        $cultureNames.Add($culture.Name)
        $translationFile = Get-LocalisedPath -LiteralPath $LiteralPath -TargetCulture $culture -Resolve -ErrorAction SilentlyContinue -ErrorVariable resolveErrors
        # Write a debug message if the translation file for the culture does not exist
        # Due to the implicit locale fallback this neither warrants a warning nor an error
        if (-not $translationFile) {
            foreach ($e in $resolveErrors) {
                Write-Debug $e
             }
             $culture = $culture.Parent
             continue
        }

        # Initialize the dictionary with the expexted properties
        $translationInfos = [System.Collections.Generic.Dictionary[string,System.Collections.Generic.Dictionary[string,PSCustomObject]]]::new()
        foreach ($property in $ExpectedProperties) {
            $translationInfos.Add($property, [System.Collections.Generic.Dictionary[string,PSCustomObject]]::new())
        }

        # Iterate the tanslation file and populate the dictonary
        $translationFileContent = Import-Csv -LiteralPath $translationFile -Encoding utf8NoBOM
        foreach ($item in $translationFileContent) {
            $translationInfo = $null
            if (-not $translationInfos.TryGetValue($item.property, [ref]$translationInfo)) {
                Write-Error "Unexpected property value '$($item.property)' in file '$translationFile'"
                continue
            }
            if ($item.needs_translation -ceq 'f') {
                $translationInfo.Add($item.id,[PSCustomObject]@{NeedsTranslation = $false; DefaultValue = $item.default; TranslatedValue = [string]$null})
            } elseif ($item.needs_translation -ceq 't') {
                $translationInfo.Add($item.id,[PSCustomObject]@{NeedsTranslation = $true; DefaultValue = $item.default; TranslatedValue = $item.translated})
            } elseif ($item.needs_translation -ceq 'u') {
                Write-Warning "Unverified translation value '$($item.translated)' in file '$translationFile'"
                if ($item.translated.Length -gt 0) {
                    $translationInfo.Add($item.id,[PSCustomObject]@{NeedsTranslation = $true; DefaultValue = $item.default; TranslatedValue = $item.translated})
                } else {
                    $translationInfo.Add($item.id,[PSCustomObject]@{NeedsTranslation = $false; DefaultValue = $item.default; TranslatedValue = [string]$null})
                }
            } else {
                Write-Error "Unexpected needs_translation value '$($item.needs_translation)' in file '$translationFile'"
                continue
            }
        }
        $translation = @{ CultureInfo = $culture; TranslationFile = $translationFile }
        $pair = $translationInfos.GetEnumerator()
        while ($pair.MoveNext()) {
            $translation[$pair.Key] = $pair.Value
        }
        $translations.Add([PSCustomObject]$translation)
        $culture = $culture.Parent
    }

    if (-not $TargetCulture.Name) {
        Write-Warning 'Calling Import-Translations with -TargetCulture set to the invariant culture will always return an empty translation list.'
        return [PSCustomObject[]]@()
    } elseif ($translations.Count -eq 0) {
        $sb = [System.Text.StringBuilder]::new()
        foreach ($cultureName in $cultureNames) {
            $sb.Append("'").Append($cultureName).Append("', ") > $null
        }
        $sb.Length -= 2
        Write-Warning "Cannot find a translation file for '$LiteralPath' for any of the following locales $($sb.ToString())."
        return [PSCustomObject[]]@()
    }
    return $translations.ToArray()
}

function New-AntibioticsList {
    param (
        [Parameter(Mandatory)]
        [CultureInfo]$TargetCulture,
        [Parameter(Mandatory)]
        [string]$MetadataPath,
        [switch]$AsciiDoc
    )
    $antibioticsFolderPath = Join-Path -Resolve -Path $MetadataPath -ChildPath 'common' -AdditionalChildPath 'antibiotics'
    $antibioticsFile = Join-Path -Resolve -Path $antibioticsFolderPath -ChildPath 'NeoIPC-Antibiotics.csv'
    $awareFile = Join-Path -Resolve -Path $antibioticsFolderPath -ChildPath 'WHO-AWaRe-Classification-2021.csv'
    $listElementsFile = Join-Path -Resolve -Path $antibioticsFolderPath -ChildPath 'ListElements.csv'

    $awareClasses = [System.Collections.Generic.Dictionary[string, PSCustomObject]]::new()
    $lineNo = 1
    Import-Csv -LiteralPath $awareFile -Encoding utf8NoBOM | ForEach-Object {
        $lineNo++
        $category = $_.category
        switch ($category) {
            'Access' { $c = 'A' }
            'Watch' { $c = 'W' }
            'Reserve' { $c = 'R' }
            Default {
                Write-Warning "Unexpected AWaRe category '$($category)' in '$awareFile' line $lineNo."
                return
            }
        }
        if ($_.atc_code -eq 'to be assigned') { return }
        $awareClasses.Add($_.id,[PSCustomObject]@{
            Category = $c
            Url = $AWaReUrlTemplate -f [System.Web.HttpUtility]::UrlEncode($_.antibiotic)
        })
    }

    if ($TargetCulture.Name) {
        $listElementsTranslations = Import-Translations -LiteralPath $listElementsFile -TargetCulture $TargetCulture -ExpectedProperties 'VALUE'
        $translations = Import-Translations -LiteralPath $antibioticsFile -TargetCulture $TargetCulture -ExpectedProperties 'NAME'
    } else {
        $listElementsTranslations = @()
        $translations = @()
    }

    $listElements = [System.Collections.Generic.Dictionary[string, string]]::new()
    Import-Csv -LiteralPath $listElementsFile -Encoding utf8NoBOM | ForEach-Object {
        foreach ($translation in $listElementsTranslations) {
            $translationInfo = $null
            if ($translation.VALUE.TryGetValue($_.id, [ref]$translationInfo)) {
                if ($_.value -cne $translationInfo.DefaultValue) {
                    Write-Warning "The default value '$($translationInfo.DefaultValue)' for id '$($_.id)' in translation file '$($translation.TranslationFile)' does not match the value '$($_.value)' in '$listElementsFile'."
                }
                if ($translationInfo.NeedsTranslation) {
                    $listElements.add($_.id, $translationInfo.TranslatedValue)
                }
                break
            }
        }
        if (-not $listElements.ContainsKey($_.id)) {
            $listElements.add($_.id, $_.value)
        }
    }

    $atcCodeString = $listElements['atc_code']
    $awareCategoryString = $listElements['aware_category']
    $substanceString = $listElements['substance']

    # Iterate the list of antibiotics and try to find and return the translated row in the requested format.
    Import-Csv -LiteralPath $antibioticsFile -Encoding utf8NoBOM |
    Foreach-Object {
        $substance = $_.name
        $atcUrl = $AtcUrlTemplate -f $_.atc_code
        $awareInfo = $null
        if ($awareClasses.TryGetValue($_.id, [ref]$awareInfo)) {
            $awareCategory = $awareInfo.Category
            $awareUrl = $awareInfo.Url
        } else {
            $awareCategory = $null
            $awareUrl = $null
        }
        foreach ($translation in $translations) {
            $translationInfo = $null
            if ($translation.NAME.TryGetValue($_.id, [ref]$translationInfo)) {
                if ($_.name -cne $translationInfo.DefaultValue) {
                    Write-Warning "The default value '$($translationInfo.DefaultValue)' for id '$($_.id)' in translation file '$($translation.TranslationFile)' does not match the value '$($_.name)' in '$antibioticsFile'."
                }
                if ($translationInfo.NeedsTranslation) {
                    $substance = $translationInfo.TranslatedValue
                }
                return [PSCustomObject][ordered]@{ Id = $_.id; Substance = $substance; AtcCode = $_.atc_code; AtcUrl = $atcUrl; AWaReCategory = $awareCategory; AWaReUrl = $awareUrl }
            }
        }
        if ($TargetCulture.Name -and $translations.Count -gt 0) {
            Write-Warning "Cannot find a translation for id '$($_.id)' in any of the translation files for locale '$($TargetCulture.Name)' or any of its parent locales in directory '$antibioticsFolderPath'. The antibiotic will have its untranslated default name '$($_.name)'."
        }
        return [PSCustomObject][ordered]@{ Id = $_.id; Substance = $substance; AtcCode = $_.atc_code; AtcUrl = $atcUrl; AWaReCategory = $awareCategory; AWaReUrl = $awareUrl }
    } |
    Sort-Object -Culture $TargetCulture -Property 'Substance' |
    ForEach-Object -Begin {
        if ($AsciiDoc) {
            Write-Output '[cols="4,3,^2"]'
            Write-Output '|==='
            Write-Output "|$substanceString |$atcCodeString |$awareCategoryString"
            Write-Output ''
        }
    } -Process {
        if ($AsciiDoc) {
            $a = if ($_.AWaReCategory) { "$($_.AWaReUrl)[image:AWaRe-$($_.AWaReCategory).svg[$($_.AWaReCategory),20],window=_blank]" } else { '' }
            Write-Output "|$($_.Substance) |$($_.AtcUrl)[$($_.AtcCode),window=_blank] |$a"
        } else {
            $_
        }
    } -End {
        if ($AsciiDoc) {
            Write-Output '|==='
        }
    }
}

function New-PathogenList {
    [OutputType([void])]
    param (
        [Parameter(Mandatory)]
        [CultureInfo]$TargetCulture,
        [Parameter(Mandatory)]
        [string]$MetadataPath,
        [switch]$AsciiDoc
    )

    $pathogensFolderPath = Join-Path -Resolve -Path $MetadataPath -ChildPath 'common' -AdditionalChildPath 'pathogens'
    $listElementsFile = Join-Path -Resolve -Path $pathogensFolderPath -ChildPath 'ListElements.csv'
    $ownedPathogenConceptsFile = Join-Path -Resolve -Path $pathogensFolderPath -ChildPath 'NeoIPC-Owned-Pathogen-Concepts.csv'
    $pathogenConceptsFile = Join-Path -Resolve -Path $pathogensFolderPath -ChildPath 'NeoIPC-Pathogen-Concepts.csv'
    $pathogenSynonymsFile = Join-Path -Resolve -Path $pathogensFolderPath -ChildPath 'NeoIPC-Pathogen-Synonyms.csv'
    if ($TargetCulture.Name) {
        $listElementsTranslations = Import-Translations -LiteralPath $listElementsFile -TargetCulture $TargetCulture -ExpectedProperties 'VALUE'
        $pathogenConceptsTranslations = Import-Translations -LiteralPath $pathogenConceptsFile -TargetCulture $TargetCulture -ExpectedProperties 'CONCEPT'
        $pathogenSynonymsTranslations = Import-Translations -LiteralPath $pathogenSynonymsFile -TargetCulture $TargetCulture -ExpectedProperties 'SYNONYM'
    } else {
        $listElementsTranslations = @()
        $pathogenConceptsTranslations = @()
        $pathogenSynonymsTranslations = @()
    }

    $ownedPathogenConcepts = [System.Collections.Generic.Dictionary[uint, string]]::new()
    $listElements = [System.Collections.Generic.Dictionary[string, string]]::new()
    Import-Csv -LiteralPath $ownedPathogenConceptsFile -Encoding utf8NoBOM | ForEach-Object {
        $ownedPathogenConcepts.Add([uint]::Parse($_.id), ($_.pathogen_type + '_' + ($_.concept_type -replace '\s', '_')))
    }
    Import-Csv -LiteralPath $listElementsFile -Encoding utf8NoBOM | ForEach-Object {
        foreach ($translation in $listElementsTranslations) {
            $translationInfo = $null
            if ($translation.VALUE.TryGetValue($_.id, [ref]$translationInfo)) {
                if ($_.value -cne $translationInfo.DefaultValue) {
                    Write-Warning "The default value '$($translationInfo.DefaultValue)' for id '$($_.id)' in translation file '$($translation.TranslationFile)' does not match the value '$($_.value)' in '$listElementsFile'."
                }
                if ($translationInfo.NeedsTranslation) {
                    $listElements.add($_.id, $translationInfo.TranslatedValue)
                }
                break
            }
        }
        if (-not $listElements.ContainsKey($_.id)) {
            $listElements.add($_.id, $_.value)
        }
    }

    $commonCommensalString = $listElements['common_commensal']
    $recognisedPathogenString = $listElements['recognised_pathogen']
    $MRSAString = $listElements['mrsa']
    $VREString = $listElements['vre']
    $3GCRString = $listElements['3gcr']
    $carbapenemsString = $listElements['carbapenems']
    $colistinString = $listElements['colistin']
    $synonymForString = $listElements['synonym_for']
    $assumedPathogenicityString = $listElements['assumed_pathogenicity']
    $nameString = $listElements['name']
    $recordedResistancesString = $listElements['recorded_resistances']
    $typeString = $listElements['type']

    $pathogenConcepts = Import-Csv -LiteralPath $pathogenConceptsFile -Encoding utf8NoBOM
    $pathogenList = [System.Collections.Generic.List[PSCustomObject]]::new()
    $pathogenConceptDictionary = [System.Collections.Generic.Dictionary[uint,PSCustomObject]]::new()
    $lineNo = 1
    foreach ($pathogenConcept in $pathogenConcepts) {
        $lineNo++
        # Validate the input file
        if ($pathogenConcept.concept.Trim().Length -eq 0) {
            throw "Missing concept value in line $lineNo in file '$pathogenConceptsFile'."
        }
        if ($pathogenConcept.concept.Trim() -cne $pathogenConcept.concept) {
            throw "Concept value with superflous whitespace in line $lineNo in file '$pathogenConceptsFile'."
        }
        if ($pathogenConcept.concept_type -cnotin 'clade','family','genus','group','serotype','species','species complex','subspecies','unknown','variety') {
            throw "Unknown concept type in line $lineNo in file '$pathogenConceptsFile'."
        }
        switch -casesensitive ($pathogenConcept.concept_source) {
            'LPSN' {
                $urlTemplate = $LspnUrlTemplate
                $listElementKey = 'bacterial_' + $pathogenConcept.concept_type -creplace '\s', '_'
                break
            }
            'MycoBank' {
                $urlTemplate = $MycoBankUrlTemplate
                $listElementKey = 'fungal_' + $pathogenConcept.concept_type -creplace '\s', '_'
                break
            }
            'ICTV' {
                $urlTemplate = $IctvUrlTemplate
                $listElementKey = 'viral_' + $pathogenConcept.concept_type -creplace '\s', '_'
                break
            }
            'NeoIPC' {
                $urlTemplate = $null
                $listElementKey = if ($pathogenConcept.concept_type -ceq 'unknown') { 'unknown' } else { $ownedPathogenConcepts[[uint]::Parse($pathogenConcept.concept_id)] }
                break
            }
            default {
                throw "Unknown concept source '$($pathogenConcept.concept_source)' in line $lineNo in file '$pathogenConceptsFile'."
            }
        }

        $url = if ($urlTemplate) { $urlTemplate -f $pathogenConcept.concept_id } else { $null }
        $pathogenConceptType = $listElements[$listElementKey]

        $pathogenName = $pathogenConcept.concept
        foreach ($translation in $pathogenConceptsTranslations) {
            $translationInfo = $null
            if ($translation.CONCEPT.TryGetValue($pathogenConcept.id, [ref]$translationInfo)) {
                if ($pathogenConcept.concept -cne $translationInfo.DefaultValue) {
                    Write-Warning "The default value '$($translationInfo.DefaultValue)' for id '$($pathogenConcept.id)' in translation file '$($translation.TranslationFile)' does not match the value '$($pathogenConcept.concept)' in '$pathogenConceptsFile'."
                }
                if ($translationInfo.NeedsTranslation) {
                    $pathogenName = $translationInfo.TranslatedValue
                }
                break
            }
        }

        if ($pathogenConcept.is_cc -ceq 't') {
            $pathogenicity = $commonCommensalString
        } elseif ($pathogenConcept.is_cc -ceq 'f') {
            $pathogenicity = $recognisedPathogenString
        }  else {
            throw "Unexpected boolen value '$($pathogenConcept.is_cc)' in line $lineNo file '$pathogenConceptsFile'."
        }

        $recordedResistances = [System.Collections.Generic.List[string]]::new()
        if ($pathogenConcept.show_mrsa -ceq 't') {
            $recordedResistances.Add($MRSAString)
        } elseif (-not($pathogenConcept.show_mrsa -ceq 'f')) {
            throw "Unexpected boolen value '$($pathogenConcept.show_mrsa)' in line $lineNo file '$pathogenConceptsFile'."
        }
        if ($pathogenConcept.show_vre -ceq 't') {
            $recordedResistances.Add($VREString)
        } elseif (-not($pathogenConcept.show_vre -ceq 'f')) {
            throw "Unexpected boolen value '$($pathogenConcept.show_vre)' in line $lineNo file '$pathogenConceptsFile'."
        }
        if ($pathogenConcept.show_3gcr -ceq 't') {
            $recordedResistances.Add($3GCRString)
        } elseif (-not($pathogenConcept.show_3gcr -ceq 'f')) {
            throw "Unexpected boolen value '$($pathogenConcept.show_3gcr)' in line $lineNo file '$pathogenConceptsFile'."
        }
        if ($pathogenConcept.show_carb_r -ceq 't') {
            $recordedResistances.Add($carbapenemsString)
        } elseif (-not($pathogenConcept.show_carb_r -ceq 'f')) {
            throw "Unexpected boolen value '$($pathogenConcept.show_carb_r)' in line $lineNo file '$pathogenConceptsFile'."
        }
        if ($pathogenConcept.show_coli_r -ceq 't') {
            $recordedResistances.Add($colistinString)
        } elseif (-not($pathogenConcept.show_coli_r -ceq 'f')) {
            throw "Unexpected boolen value '$($pathogenConcept.show_coli_r)' in line $lineNo file '$pathogenConceptsFile'."
        }

        $pathogenConceptId = [uint]::Parse($pathogenConcept.id)
        $pathogenConceptObject = [PSCustomObject]@{
            Id = $pathogenConceptId
            Name = $pathogenName
            Type = $pathogenConceptType
            AssumedPathogenicity = $pathogenicity
            RecordedResistances = $recordedResistances.ToArray()
            Url = $url
            SynonymFor = $null
        }
        $pathogenConceptDictionary.Add($pathogenConceptId, $pathogenConceptObject)
        $pathogenList.Add($pathogenConceptObject)
    }

    $pathogenSynonyms = Import-Csv -LiteralPath $pathogenSynonymsFile -Encoding utf8NoBOM
    $lineNo = 1
    foreach ($pathogenSynonym in $pathogenSynonyms) {
        $lineNo++
        # Validate the input file
        if ($pathogenSynonym.synonym.Trim().Length -eq 0) {
            throw "Missing concept value in line $lineNo in file '$pathogenSynonymsFile'."
        }
        if ($pathogenSynonym.synonym.Trim() -cne $pathogenSynonym.synonym) {
            throw "Concept value with superflous whitespace in line $lineNo in file '$pathogenSynonymsFile'."
        }
        switch -casesensitive ($pathogenSynonym.concept_source) {
            'LPSN' {
                $urlTemplate = $LspnUrlTemplate
                break
            }
            'MycoBank' {
                $urlTemplate = $MycoBankUrlTemplate
                break
            }
            'ICTV' {
                $urlTemplate = $IctvUrlTemplate
                break
            }
            'NeoIPC' {
                $urlTemplate = $null
                break
            }
            default {
                throw "Unknown concept source '$($pathogenSynonym.concept_source)' in line $lineNo in file '$pathogenSynonymsFile'."
            }
        }

        $url = if ($urlTemplate) { $urlTemplate -f $pathogenSynonym.concept_id } else { $null }
        $pathogenSynonymName = $pathogenSynonym.synonym
        foreach ($translation in $pathogenSynonymsTranslations) {
            $translationInfo = $null
            if ($translation.SYNONYM.TryGetValue($pathogenSynonym.id, [ref]$translationInfo)) {
                if ($pathogenSynonym.synonym -cne $translationInfo.DefaultValue) {
                    Write-Warning "The default value '$($translationInfo.DefaultValue)' for id '$($pathogenSynonym.id)' in translation file '$($translation.TranslationFile)' does not match the value '$($pathogenSynonym.synonym)' in '$pathogenSynonymsFile'."
                }
                if ($translationInfo.NeedsTranslation) {
                    $pathogenSynonymName = $translationInfo.TranslatedValue
                }
                break
            }
        }
        $parentConcept = $pathogenConceptDictionary[[uint]::Parse($pathogenSynonym.synonym_for)]
        $pathogenList.Add([PSCustomObject]@{
            Id = [uint]::Parse($pathogenSynonym.id)
            Name = $pathogenSynonymName
            Type = $parentConcept.Type
            AssumedPathogenicity = $parentConcept.AssumedPathogenicity
            RecordedResistances = $parentConcept.RecordedResistances
            Url = $url
            SynonymFor = $parentConcept
        })
    }

    $pathogenList |
    Sort-Object -Property Name -Culture $TargetCulture.Name |
    ForEach-Object -Begin {
        if ($AsciiDoc) {
            Write-Output '[.small,cols="5,3,3,3"]'
            Write-Output '|==='
            Write-Output "|$nameString |$typeString |$assumedPathogenicityString |$recordedResistancesString"
            Write-Output ''
        }
    } -Process {
        if ($AsciiDoc) {
            $type = if ($_.Url) { "$($_.Url)[$($_.Type),window=_blank]" } else { $_.Type }
            if ($_.SynonymFor) {
                $type += " ($synonymForString xref:pathogen-concept-$($_.SynonymFor.Id)[$($_.SynonymFor.Name)])"
            }
            Write-Output "|[[pathogen-concept-$($_.Id)]]$($_.Name) |$type |$($_.AssumedPathogenicity) |$($_.RecordedResistances -join ', ')"
        } else {
            $_
        }
    } -End {
        if ($AsciiDoc) {
            Write-Output '|==='
        }
    }
}

function Test-ChildObject {
    param (
        [Parameter(Position=0, Mandatory)]
        [System.Management.Automation.OrderedHashtable]$Metadata,
        [Parameter(Position=1, Mandatory, ValueFromPipeline)]
        [string[]]$ChildObjectNames,
        [switch]$Throw
    )
    foreach ($childObjectName in $ChildObjectNames) {
        if (-not $Metadata.ContainsKey($childObjectName)) {
            if ($Throw) {
                throw "The metadata do not contain the required child object '$childObjectName'"
            }
            return $false
        }
    }
    return $true
}

function Get-ChildObject {
    [CmdletBinding()]
    param (
        [Parameter(Position=0, Mandatory, ValueFromPipeline)]
        [System.Management.Automation.OrderedHashtable]$Metadata,
        [Parameter(Position=1, ParameterSetName='Extract single object')]
        [string[]]$ChildObjectNames,
        [Parameter(ParameterSetName='Extract single object')]
        [switch]$ThrowIfMissing,
        $VerbosePreference = $PSCmdlet.GetVariableValue('VerbosePreference')
    )
    if ($ChildObjectNames) {
        foreach ($n in $ChildObjectNames) {
            if (-not (Test-ChildObject -Metadata $Metadata -ChildObjectName $n -Throw:$ThrowIfMissing.IsPresent)) {
                return
            }
            Write-Output [PSCustomObject]@{ Name = $n; Value = $Metadata[$n]}
        }
    }
    else {
        foreach ($key in ($Metadata.Keys | Sort-Object)) {
            Write-Output ([PSCustomObject]@{ Name = $key; Value = $Metadata[$key]})
        }
    }
}

function Get-ObjectProperties {
    param (
        [Parameter(Position=0, Mandatory)]
        [string]$ObjectName,
        [switch]$AddIdProperty,
        [switch]$AddSharingProperties
    )
    $props = [System.Collections.ArrayList]::new()
    if ($AddIdProperty ) {
        $props.Add(@{name='id';expression={$_['id']}}) > $null
    }
    switch -exact -casesensitive ($ObjectName) {
        'attributes' {
            $properties = @(
                'code'
                'name'
                'shortName'
                'description'
                'categoryAttribute'
                'categoryOptionAttribute'
                'categoryOptionComboAttribute'
                'categoryOptionGroupAttribute'
                'categoryOptionGroupSetAttribute'
                'constantAttribute'
                'dataElementAttribute'
                'dataElementGroupAttribute'
                'dataElementGroupSetAttribute'
                'dataSetAttribute'
                'documentAttribute'
                'eventChartAttribute'
                'eventReportAttribute'
                'indicatorAttribute'
                'indicatorGroupAttribute'
                'legendSetAttribute'
                'mandatory'
                'mapAttribute'
                'optionAttribute'
                'optionSetAttribute'
                'organisationUnitAttribute'
                'organisationUnitGroupAttribute'
                'organisationUnitGroupSetAttribute'
                'programAttribute'
                'programIndicatorAttribute'
                'programStageAttribute'
                'relationshipTypeAttribute'
                'sectionAttribute'
                'sqlViewAttribute'
                'trackedEntityAttributeAttribute'
                'trackedEntityTypeAttribute'
                'unique'
                'userAttribute'
                'userGroupAttribute'
                'validationRuleAttribute'
                'validationRuleGroupAttribute'
                'valueType'
                'visualizationAttribute')
        }
        'dataElements' {
            $properties = @(
                'code'
                'name'
                'shortName'
                'description'
                'aggregationType'
                @{name='categoryCombo_code';expression={
                    if ($categoryComboMap -and $categoryComboMap.Contains($_.categoryCombo.id)) {
                        Write-Debug "Mapping category combo id '$($_.categoryCombo.id)' to code '$($categoryComboMap[$_.categoryCombo.id])'"
                        $categoryComboMap[$_.categoryCombo.id]
                    } else {
                        Write-Warning "Failed to map a code for the category combo with the id '$($_.categoryCombo.id)'."
                        $_.categoryCombo.id
                    }
                }}
                'domainType'
                'valueType'
                'zeroIsSignificant')
        }
        'optionSets' {
            $properties = @(
                'code'
                'name'
                'valueType')
        }
        Default { $properties = @()}
    }
    foreach ($prop in $properties) {
        if ($prop -is [string]) {
            $props.Add(@{name=$prop;expression=$prop}) > $null
        } else {
            $props.Add($prop) > $null
        }
    }
    if ($AddSharingProperties ) {
        $props.Add(@{name='sharing_external';expression={$_.sharing.external}}) > $null
        $props.Add(@{name='sharing_public';expression={$_.sharing.public}}) > $null
        $props.Add(@{name='sharing_owner';expression={
            if ($userMap -and $userMap.Contains($_.sharing.owner)) {
                Write-Debug "Mapping user id '$($_.sharing.owner)' to code '$($userMap[$_.sharing.owner])'"
                $userMap[$_.sharing.owner]
            } else {
                Write-Warning "Failed to map a code for the user with the id '$($_.sharing.owner)'."
                $_.sharing.owner
            }
        }}) > $null
    }
    return $props.ToArray()
}

function Initialize-ObjectDirectory {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Position=0, Mandatory)]
        [string]$BasePath,
        [Parameter(Position=1, Mandatory)]
        [string[]]$ObjectNames,
        $ConfirmPreference = $PSCmdlet.GetVariableValue('ConfirmPreference'),
        $WhatIfPreference = $PSCmdlet.GetVariableValue('WhatIfPreference'),
        $VerbosePreference = $PSCmdlet.GetVariableValue('VerbosePreference')
    )
    foreach ($objectName in $ObjectNames) {
        $dir = Join-Path $BasePath -ChildPath $objectName

        if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
            Write-Verbose "Creating directory $dir"
            New-Item -Path $dir -ItemType Directory > $null
        }
        return $dir
    }
}

function Get-CodeMap {
    [CmdletBinding()]
    param (
        [Parameter(Position=0, Mandatory, ValueFromPipeline)]
        [Hashtable]$InputObject,
        [switch]$Reverse,
        $DebugPreference = $PSCmdlet.GetVariableValue('DebugPreference')
    )
    begin {
        $map = @{}
    }
    process {
        if (-not $InputObject.Contains('id')) {
            Write-Debug "The input object does not contain an id key. Skipping."
            return
        }
        $id = $InputObject['id']
        if (-not $id) {
            Write-Debug "The input object does not contain a valid id. Skipping."
            return
        }
        if (-not $InputObject.Contains('code')) {
            Write-Debug "The input object does not contain a code key. Skipping."
            return
        }
        $code = $InputObject['code']
        if (-not $code) {
            Write-Debug "The input object does not contain a valid code. Skipping."
            return
        }
        if ($Reverse) {
            $map[$code] = $id
        } else {
            $map[$id] = $code
        }
    }
    end {
        return $map
    }
}
