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

function Import-AntibioticPoTranslation {
    <#
    .SYNOPSIS
        Build an english(msgid) -> localized(msgstr) map from the antibiotic gettext catalogue po/antibiotics.<lang>.po.
    .DESCRIPTION
        The antibiotic domain is translated in a bilingual gettext component keyed by the English STRING (bare msgid,
        no msgctxt). Resolves the catalogue for $TargetCulture by walking its parent chain (e.g. de-DE -> de) and
        returns english -> localized for the entries with a real translation: the header (empty msgid), obsolete
        "#~" and FUZZY entries, and any empty or msgid-identical msgstr are skipped. Case-sensitive (Ordinal —
        substance names are case-significant). Empty map when no catalogue exists for the culture. Self-contained:
        NeoIPC-BuildTools does not depend on NeoIPC-Tools, so this mirrors NeoIPC-Tools' Get-NeoIPCPoTranslationMap.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$PoDirectory,
        [Parameter(Mandatory)]
        [CultureInfo]$TargetCulture,
        [string]$BaseName = 'antibiotics'
    )
    $map = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
    $poPath = $null
    for ($culture = $TargetCulture; $culture -and $culture.Name.Length -gt 0; $culture = $culture.Parent) {
        $candidate = Join-Path -Path $PoDirectory -ChildPath "$BaseName.$($culture.Name).po"
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $poPath = $candidate; break }
    }
    if (-not $poPath) { return $map }

    $unescape = {
        param([string]$value)
        $sb = [System.Text.StringBuilder]::new($value.Length)
        for ($i = 0; $i -lt $value.Length; $i++) {
            $ch = $value[$i]
            if ($ch -ne '\' -or $i -eq $value.Length - 1) { [void]$sb.Append($ch); continue }
            $next = $value[++$i]
            switch ($next) {
                'n' { [void]$sb.Append("`n") }
                'r' { [void]$sb.Append("`r") }
                't' { [void]$sb.Append("`t") }
                '"' { [void]$sb.Append('"') }
                '\' { [void]$sb.Append('\') }
                default { [void]$sb.Append($next) }
            }
        }
        $sb.ToString()
    }
    $peel = {
        param([string]$s)
        if ($s.StartsWith('"') -and $s.EndsWith('"') -and $s.Length -ge 2) { & $unescape $s.Substring(1, $s.Length - 2) } else { '' }
    }

    $id = $null; $str = $null; $field = $null; $fuzzy = $false; $obsolete = $false
    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($raw in ((Get-Content -LiteralPath $poPath -Raw) -split "`n")) {
        $trim = $raw.TrimEnd("`r").Trim()
        if ($trim -eq '') {
            if ($null -ne $id -and -not $obsolete -and -not $fuzzy) { $entries.Add([PSCustomObject]@{ Id = $id; Str = [string]$str }) }
            $id = $null; $str = $null; $field = $null; $fuzzy = $false; $obsolete = $false; continue
        }
        if ($trim.StartsWith('#~')) { $obsolete = $true; $field = $null; continue }
        if ($trim.StartsWith('#')) {
            if ($trim.StartsWith('#,') -and $trim -match '\bfuzzy\b') { $fuzzy = $true }
            $field = $null; continue
        }
        if ($trim.StartsWith('msgid ')) { $id = & $peel ($trim.Substring(6).Trim()); $field = 'id'; continue }
        if ($trim.StartsWith('msgstr ')) { $str = & $peel ($trim.Substring(7).Trim()); $field = 'str'; continue }
        if ($trim.StartsWith('"') -and $trim.EndsWith('"') -and $field) {
            $piece = & $peel $trim
            if ($field -eq 'id') { $id = [string]$id + $piece } else { $str = [string]$str + $piece }
        }
    }
    if ($null -ne $id -and -not $obsolete -and -not $fuzzy) { $entries.Add([PSCustomObject]@{ Id = $id; Str = [string]$str }) }

    foreach ($e in $entries) {
        if ([string]::IsNullOrEmpty($e.Id)) { continue }                          # header
        if ([string]::IsNullOrEmpty($e.Str) -or $e.Str -ceq $e.Id) { continue }   # untranslated / unchanged
        if (-not $map.ContainsKey($e.Id)) { $map[$e.Id] = $e.Str }
    }
    $map
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
    $listElementsFile = Join-Path -Resolve -Path $antibioticsFolderPath -ChildPath 'ListElements.csv'
    # Substance names + printed-list UI labels are translated in po/antibiotics.<lang>.po, keyed by the English
    # string. po/ sits at the repository root (the parent of the metadata directory).
    $poDirectory = Join-Path -Path (Split-Path -Parent $MetadataPath) -ChildPath 'po'

    $translations = if ($TargetCulture.Name) {
        Import-AntibioticPoTranslation -PoDirectory $poDirectory -TargetCulture $TargetCulture
    } else {
        [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
    }
    if ($TargetCulture.Name -and $translations.Count -eq 0) {
        Write-Warning "No antibiotic translations found for locale '$($TargetCulture.Name)' (or its parent locales) in '$poDirectory'. The antibiotic list will use the English names."
    }

    # Localize the printed-table UI labels (ListElements.csv `value`) by English string.
    $listElements = [System.Collections.Generic.Dictionary[string, string]]::new()
    Import-Csv -LiteralPath $listElementsFile -Encoding utf8NoBOM | ForEach-Object {
        $localized = if ($translations.ContainsKey($_.value)) { $translations[$_.value] } else { $_.value }
        $listElements[$_.id] = $localized
    }
    $atcCodeString = $listElements['atc_code']
    $awareCategoryString = $listElements['aware_category']
    $substanceString = $listElements['substance']

    # AWaRe category (folded into NeoIPC-Antibiotics.csv) -> the single-letter code used for the AWaRe-<X>.svg badge.
    $awareCode = @{ Access = 'A'; Watch = 'W'; Reserve = 'R' }

    # Iterate the substances and emit each translated row in the requested format.
    Import-Csv -LiteralPath $antibioticsFile -Encoding utf8NoBOM |
    ForEach-Object {
        $substance = if ($translations.ContainsKey($_.name)) { $translations[$_.name] } else { $_.name }
        # ATC link only where the substance has an ATC code (the tmp_* AWaRe-list ids have none).
        $atcUrl = if ($_.atc_code) { $AtcUrlTemplate -f $_.atc_code } else { $null }
        # AWaRe badge + search link, only where WHO has classified the substance; the search term is the English name.
        $awareCategory = $null
        $awareUrl = $null
        if ($_.aware_category -and $awareCode.ContainsKey($_.aware_category)) {
            $awareCategory = $awareCode[$_.aware_category]
            $awareUrl = $AWaReUrlTemplate -f [System.Web.HttpUtility]::UrlEncode($_.name)
        }
        [PSCustomObject][ordered]@{ Id = $_.id; Substance = $substance; AtcCode = $_.atc_code; AtcUrl = $atcUrl; AWaReCategory = $awareCategory; AWaReUrl = $awareUrl }
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
            $awareCell = if ($_.AWaReCategory) { "$($_.AWaReUrl)[image:AWaRe-$($_.AWaReCategory).svg[$($_.AWaReCategory),20],window=_blank]" } else { '' }
            $atcCell = if ($_.AtcCode) { "$($_.AtcUrl)[$($_.AtcCode),window=_blank]" } else { '' }
            Write-Output "|$($_.Substance) |$atcCell |$awareCell"
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

    $infectiousAgentsFolderPath = Join-Path -Resolve -Path $MetadataPath -ChildPath 'common' -AdditionalChildPath 'infectious-agents'
    $listElementsFile = Join-Path -Resolve -Path $infectiousAgentsFolderPath -ChildPath 'ListElements.csv'
    $ownedPathogenConceptsFile = Join-Path -Resolve -Path $infectiousAgentsFolderPath -ChildPath 'NeoIPC-Owned-Pathogen-Concepts.csv'
    $infectiousAgentConceptsFile = Join-Path -Resolve -Path $infectiousAgentsFolderPath -ChildPath 'NeoIPC-Pathogen-Concepts.csv'
    $infectiousAgentSynonymsFile = Join-Path -Resolve -Path $infectiousAgentsFolderPath -ChildPath 'NeoIPC-Pathogen-Synonyms.csv'
    if ($TargetCulture.Name) {
        $listElementsTranslations = Import-Translations -LiteralPath $listElementsFile -TargetCulture $TargetCulture -ExpectedProperties 'VALUE'
        $infectiousAgentConceptsTranslations = Import-Translations -LiteralPath $infectiousAgentConceptsFile -TargetCulture $TargetCulture -ExpectedProperties 'CONCEPT'
        $infectiousAgentSynonymsTranslations = Import-Translations -LiteralPath $infectiousAgentSynonymsFile -TargetCulture $TargetCulture -ExpectedProperties 'SYNONYM'
    } else {
        $listElementsTranslations = @()
        $infectiousAgentConceptsTranslations = @()
        $infectiousAgentSynonymsTranslations = @()
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

    $infectiousAgentConcepts = Import-Csv -LiteralPath $infectiousAgentConceptsFile -Encoding utf8NoBOM
    $infectiousAgentList = [System.Collections.Generic.List[PSCustomObject]]::new()
    $infectiousAgentConceptDictionary = [System.Collections.Generic.Dictionary[uint,PSCustomObject]]::new()
    $lineNo = 1
    foreach ($infectiousAgentConcept in $infectiousAgentConcepts) {
        $lineNo++
        # Validate the input file
        if ($infectiousAgentConcept.concept.Trim().Length -eq 0) {
            throw "Missing concept value in line $lineNo in file '$infectiousAgentConceptsFile'."
        }
        if ($infectiousAgentConcept.concept.Trim() -cne $infectiousAgentConcept.concept) {
            throw "Concept value with superflous whitespace in line $lineNo in file '$infectiousAgentConceptsFile'."
        }
        if ($infectiousAgentConcept.concept_type -cnotin 'clade','family','genus','group','serotype','species','species complex','subspecies','unknown','variety') {
            throw "Unknown concept type in line $lineNo in file '$infectiousAgentConceptsFile'."
        }
        switch -casesensitive ($infectiousAgentConcept.concept_source) {
            'LPSN' {
                $urlTemplate = $LspnUrlTemplate
                $listElementKey = 'bacterial_' + $infectiousAgentConcept.concept_type -creplace '\s', '_'
                break
            }
            'MycoBank' {
                $urlTemplate = $MycoBankUrlTemplate
                $listElementKey = 'fungal_' + $infectiousAgentConcept.concept_type -creplace '\s', '_'
                break
            }
            'ICTV' {
                $urlTemplate = $IctvUrlTemplate
                $listElementKey = 'viral_' + $infectiousAgentConcept.concept_type -creplace '\s', '_'
                break
            }
            'NeoIPC' {
                $urlTemplate = $null
                $listElementKey = if ($infectiousAgentConcept.concept_type -ceq 'unknown') { 'unknown' } else { $ownedPathogenConcepts[[uint]::Parse($infectiousAgentConcept.concept_id)] }
                break
            }
            default {
                throw "Unknown concept source '$($infectiousAgentConcept.concept_source)' in line $lineNo in file '$infectiousAgentConceptsFile'."
            }
        }

        $url = if ($urlTemplate) { $urlTemplate -f $infectiousAgentConcept.concept_id } else { $null }
        $infectiousAgentConceptType = $listElements[$listElementKey]

        $infectiousAgentName = $infectiousAgentConcept.concept
        foreach ($translation in $infectiousAgentConceptsTranslations) {
            $translationInfo = $null
            if ($translation.CONCEPT.TryGetValue($infectiousAgentConcept.id, [ref]$translationInfo)) {
                if ($infectiousAgentConcept.concept -cne $translationInfo.DefaultValue) {
                    Write-Warning "The default value '$($translationInfo.DefaultValue)' for id '$($infectiousAgentConcept.id)' in translation file '$($translation.TranslationFile)' does not match the value '$($infectiousAgentConcept.concept)' in '$infectiousAgentConceptsFile'."
                }
                if ($translationInfo.NeedsTranslation) {
                    $infectiousAgentName = $translationInfo.TranslatedValue
                }
                break
            }
        }

        if ($infectiousAgentConcept.is_cc -ceq 't') {
            $pathogenicity = $commonCommensalString
        } elseif ($infectiousAgentConcept.is_cc -ceq 'f') {
            $pathogenicity = $recognisedPathogenString
        }  else {
            throw "Unexpected boolen value '$($infectiousAgentConcept.is_cc)' in line $lineNo file '$infectiousAgentConceptsFile'."
        }

        $recordedResistances = [System.Collections.Generic.List[string]]::new()
        if ($infectiousAgentConcept.show_mrsa -ceq 't') {
            $recordedResistances.Add($MRSAString)
        } elseif (-not($infectiousAgentConcept.show_mrsa -ceq 'f')) {
            throw "Unexpected boolen value '$($infectiousAgentConcept.show_mrsa)' in line $lineNo file '$infectiousAgentConceptsFile'."
        }
        if ($infectiousAgentConcept.show_vre -ceq 't') {
            $recordedResistances.Add($VREString)
        } elseif (-not($infectiousAgentConcept.show_vre -ceq 'f')) {
            throw "Unexpected boolen value '$($infectiousAgentConcept.show_vre)' in line $lineNo file '$infectiousAgentConceptsFile'."
        }
        if ($infectiousAgentConcept.show_3gcr -ceq 't') {
            $recordedResistances.Add($3GCRString)
        } elseif (-not($infectiousAgentConcept.show_3gcr -ceq 'f')) {
            throw "Unexpected boolen value '$($infectiousAgentConcept.show_3gcr)' in line $lineNo file '$infectiousAgentConceptsFile'."
        }
        if ($infectiousAgentConcept.show_carb_r -ceq 't') {
            $recordedResistances.Add($carbapenemsString)
        } elseif (-not($infectiousAgentConcept.show_carb_r -ceq 'f')) {
            throw "Unexpected boolen value '$($infectiousAgentConcept.show_carb_r)' in line $lineNo file '$infectiousAgentConceptsFile'."
        }
        if ($infectiousAgentConcept.show_coli_r -ceq 't') {
            $recordedResistances.Add($colistinString)
        } elseif (-not($infectiousAgentConcept.show_coli_r -ceq 'f')) {
            throw "Unexpected boolen value '$($infectiousAgentConcept.show_coli_r)' in line $lineNo file '$infectiousAgentConceptsFile'."
        }

        $infectiousAgentConceptId = [uint]::Parse($infectiousAgentConcept.id)
        $infectiousAgentConceptObject = [PSCustomObject]@{
            Id = $infectiousAgentConceptId
            Name = $infectiousAgentName
            Type = $infectiousAgentConceptType
            AssumedPathogenicity = $pathogenicity
            RecordedResistances = $recordedResistances.ToArray()
            Url = $url
            SynonymFor = $null
        }
        $infectiousAgentConceptDictionary.Add($infectiousAgentConceptId, $infectiousAgentConceptObject)
        $infectiousAgentList.Add($infectiousAgentConceptObject)
    }

    $infectiousAgentSynonyms = Import-Csv -LiteralPath $infectiousAgentSynonymsFile -Encoding utf8NoBOM
    $lineNo = 1
    foreach ($infectiousAgentSynonym in $infectiousAgentSynonyms) {
        $lineNo++
        # Validate the input file
        if ($infectiousAgentSynonym.synonym.Trim().Length -eq 0) {
            throw "Missing concept value in line $lineNo in file '$infectiousAgentSynonymsFile'."
        }
        if ($infectiousAgentSynonym.synonym.Trim() -cne $infectiousAgentSynonym.synonym) {
            throw "Concept value with superflous whitespace in line $lineNo in file '$infectiousAgentSynonymsFile'."
        }
        switch -casesensitive ($infectiousAgentSynonym.concept_source) {
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
                throw "Unknown concept source '$($infectiousAgentSynonym.concept_source)' in line $lineNo in file '$infectiousAgentSynonymsFile'."
            }
        }

        $url = if ($urlTemplate) { $urlTemplate -f $infectiousAgentSynonym.concept_id } else { $null }
        $infectiousAgentSynonymName = $infectiousAgentSynonym.synonym
        foreach ($translation in $infectiousAgentSynonymsTranslations) {
            $translationInfo = $null
            if ($translation.SYNONYM.TryGetValue($infectiousAgentSynonym.id, [ref]$translationInfo)) {
                if ($infectiousAgentSynonym.synonym -cne $translationInfo.DefaultValue) {
                    Write-Warning "The default value '$($translationInfo.DefaultValue)' for id '$($infectiousAgentSynonym.id)' in translation file '$($translation.TranslationFile)' does not match the value '$($infectiousAgentSynonym.synonym)' in '$infectiousAgentSynonymsFile'."
                }
                if ($translationInfo.NeedsTranslation) {
                    $infectiousAgentSynonymName = $translationInfo.TranslatedValue
                }
                break
            }
        }
        $parentConcept = $infectiousAgentConceptDictionary[[uint]::Parse($infectiousAgentSynonym.synonym_for)]
        $infectiousAgentList.Add([PSCustomObject]@{
            Id = [uint]::Parse($infectiousAgentSynonym.id)
            Name = $infectiousAgentSynonymName
            Type = $parentConcept.Type
            AssumedPathogenicity = $parentConcept.AssumedPathogenicity
            RecordedResistances = $parentConcept.RecordedResistances
            Url = $url
            SynonymFor = $parentConcept
        })
    }

    $infectiousAgentList |
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
                $type += " ($synonymForString xref:infectious-agent-concept-$($_.SynonymFor.Id)[$($_.SynonymFor.Name)])"
            }
            Write-Output "|[[infectious-agent-concept-$($_.Id)]]$($_.Name) |$type |$($_.AssumedPathogenicity) |$($_.RecordedResistances -join ', ')"
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
