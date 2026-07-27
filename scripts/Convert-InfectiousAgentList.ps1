#!/usr/bin/env pwsh
#Requires -Version 7.6

<#
.SYNOPSIS
    Renders the NeoIPC infectious-agent list from its authored YAML into AsciiDoc, CSV and PDF.

.DESCRIPTION
    Reads the authored infectious-agents YAML — the canonical source for organism concepts, their
    synonyms, common-commensal status and recorded resistance categories — and emits the requested output
    formats, one set per requested translation language.

    Localization runs through po4a against the config in the input directory, so translated output is
    generated from the committed catalogues rather than from any hand-edited copy.

    Each concept row carries a citation link built from the authority that names it: LPSN for bacteria,
    MycoBank for fungi and protozoa, ICTV for viruses. Synonyms inherit their accepted concept's
    commensal and resistance attributes, and cross-reference it.

.PARAMETER OutputFormats
    Any of AsciiDoc, CSV, PDF.

.PARAMETER TranslationLanguages
    Languages to render in addition to the source language.

.EXAMPLE
    ./scripts/Convert-InfectiousAgentList.ps1 -OutputFormats AsciiDoc,CSV -TranslationLanguages de,es
#>

[CmdletBinding(PositionalBinding, SupportsShouldProcess)]
param(
    [string]$InputDirectory = "$PSScriptRoot/../metadata/common/infectious-agents",
    [string]$OutputDirectory = "$PSScriptRoot/../artifacts",
    [string[]]$TranslationLanguages,
    [ValidateSet('AsciiDoc','CSV','PDF')]
    [string[]]$OutputFormats,
    [switch]$Force
)

Import-Module powershell-yaml

function AppendChildrenRecursive {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, Position = 1)]
        [System.Collections.IList]$Children,
        [Parameter(Position = 2)]
        [System.Collections.Generic.List[PSCustomObject]]$Output,
        [Parameter(Position = 3)]
        [string]$Type
    )

    if (-not $Output) {
        $Output = [System.Collections.Generic.List[PSCustomObject]]::new()
    }

    $resetType = $false
    foreach ($item in $Children) {
        if ($resetType -or -not $Type) {
            if ($item.ConceptSource -eq 'NeoIPC' -and $item.ConceptId -eq 1) {
                $Type = $item.ConceptType
                $resetType = $true
            } elseif ($item.ConceptSource -eq 'NeoIPC' -and $item.ConceptId -eq 100) {
                $Type = $contentStrings.Virus
                $resetType = $true
            } elseif ($item.ConceptSource -eq 'LPSN' -and $item.ConceptId -eq 'domain/bacteria') {
                $Type = $contentStrings.Bacterium
                $resetType = $true
            } elseif ($item.ConceptSource -eq 'MycoBank' -and $item.ConceptId -eq 455206) {
                $Type = $contentStrings.Fungus
                $resetType = $true
            } elseif ($item.ConceptSource -eq 'MycoBank' -and $item.ConceptId -eq 92339) {
                $Type = $contentStrings.Protozoon
                $resetType = $true
            } else {
                $Type = $null
            }
        }
        if ($item.Id) {
            $newItem = [ordered]@{}
            $newItem[$contentStrings.Id] = $item.Id
            $newItem[$contentStrings.Name] = $item.Name
            $newItem[$contentStrings.Type] = $Type
            $newItem[$contentStrings.CommonCommensal] = if($item.CommonCommensal){$contentStrings.Yes}
            $newItem[$contentStrings.ParentId] = ''

            $r = [System.Collections.Generic.List[string]]::new()
            if ($item.MRSA) {
                $r.Add($contentStrings.MRSA)
            }
            if ($item.VRE) {
                $r.Add($contentStrings.VRE)
            }
            if ($item['3GCR']) {
                $r.Add($contentStrings.'3GCR')
            }
            if ($item.Carbapenems) {
                $r.Add($contentStrings.Carbapenems)
            }
            if ($item.Colistin) {
                $r.Add($contentStrings.Colistin)
            }
            $newItem[$contentStrings.RecordedResistances] = $r |
                Join-String -Separator ', '

            switch ($item.ConceptSource) {
                LPSN {
                    $newItem[$contentStrings.URL] = $data.Metadata.UrlTemplates.LPSN -f $item.ConceptId
                    break
                }
                MycoBank {
                    $newItem[$contentStrings.URL] = $data.Metadata.UrlTemplates.MycoBank -f $item.ConceptId
                    break
                }
                ICTV {
                    $newItem[$contentStrings.URL] = $data.Metadata.UrlTemplates.ICTV -f $item.ConceptId
                    break
                }
            }
            $Output.Add([PSCustomObject]$newItem)
        }
        if ($item.Children) {
            if ($Output) {
                $Output = AppendChildrenRecursive $item.Children $Output $Type
            } else {
                $Output = AppendChildrenRecursive -Children $item.Children -Type $Type
            }
        }
        if ($item.Synonyms) {
            AppendSynonyms $Output $item.Synonyms $item $Type
        }
    }

    return $Output
}

function AppendSynonyms {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, Position = 1)]
        [System.Collections.Generic.List[PSCustomObject]]$Output,
        [Parameter(Mandatory, Position = 2)]
        [System.Collections.IList]$Synonyms,
        [Parameter(Mandatory, Position = 3)]
        [object]$Parent,
        [Parameter(Position = 4)]
        [string]$Type
    )

    foreach ($item in $Synonyms) {
        if ($Parent.Id) {
            $newItem = [ordered]@{}
            $newItem[$contentStrings.Id] = $item.Id
            $newItem[$contentStrings.Name] = $item.Name
            $newItem[$contentStrings.Type] = $Type
            $newItem[$contentStrings.CommonCommensal] = if($Parent.CommonCommensal){$contentStrings.Yes}
            $newItem[$contentStrings.ParentId] = $Parent.Id

            $r = [System.Collections.Generic.List[string]]::new()
            if ($Parent.MRSA) {
                $r.Add($contentStrings.MRSA)
            }
            if ($Parent.VRE) {
                $r.Add($contentStrings.VRE)
            }
            if ($Parent['3GCR']) {
                $r.Add($contentStrings.'3GCR')
            }
            if ($Parent.Carbapenems) {
                $r.Add($contentStrings.Carbapenems)
            }
            if ($Parent.Colistin) {
                $r.Add($contentStrings.Colistin)
            }
            $newItem[$contentStrings.RecordedResistances] = $r |
                Join-String -Separator ', '

            switch ($item.ConceptSource) {
                LPSN {
                    $newItem[$contentStrings.URL] = $data.Metadata.UrlTemplates.LPSN -f $item.ConceptId
                    break
                }
                MycoBank {
                    $newItem[$contentStrings.URL] = $data.Metadata.UrlTemplates.MycoBank -f $item.ConceptId
                    break
                }
                ICTV {
                    $newItem[$contentStrings.URL] = $data.Metadata.UrlTemplates.ICTV -f $item.ConceptId
                    break
                }
            }
            $Output.Add([PSCustomObject]$newItem)
        }
        if ($item.Children) {
            if ($Output) {
                $Output = AppendChildrenRecursive $item.Children $Output $Type
            } else {
                $Output = AppendChildrenRecursive -Children $item.Children -Type $Type
            }
        }
    }
}

data MessageStrings -SupportedCommand ConvertFrom-Yaml {
    ConvertFrom-Yaml @'
CreatingInfoMsg: "Creating infectious agent list for language ‘{0}’..."
FormatInfoMsg: "...in {0} format"
ExternalCmdErrorMsg: "The execution of the command '{0}' was terminated with the following error message:"
ExternalCmdWarningMsg: "The execution of the command '{0}' resulted in the following warning message:"
'@
}
Import-LocalizedData -BindingVariable 'MessageStrings' -SupportedCommand ConvertFrom-Yaml -FileName 'Convert-InfectiousAgentList-MessageStrings' -ErrorAction Ignore

$config_file = Resolve-Path "$InputDirectory/po4a.cfg" -Relative
$po4aCmd = "po4a -q "
if ($Force) {
    $po4aCmd += '-k 0 '
}
$po4aCmd += $config_file

$po4aErrors = $( $po4aWarnings = Invoke-Expression -Command $po4aCmd ) 2>&1
if ($po4aErrors) {
    $msg = ($MessageStrings.ExternalCmdErrorMsg -f $po4aCmd) + [System.Environment]::NewLine
    for ($i = 0; $i -lt $po4aErrors.Count; $i++) {
        $line = @($po4aErrors)[$i]
        if ($line.Exception.Message -and $line.Exception.Message -notmatch '^\s*$') {
            $msg = $msg + $line + [System.Environment]::NewLine
        }
    }
    Write-Error -Message $msg -ErrorAction Stop
}
if ($po4aWarnings) {
    $msg = ($MessageStrings.ExternalCmdWarningMsg -f $po4aCmd) + [System.Environment]::NewLine
    for ($i = 0; $i -lt $po4aWarnings.Count; $i++) {
        $line = @($po4aWarnings)[$i]
        if ($line -and $line -notmatch '^\s*$') {
            $msg = $msg + $line + [System.Environment]::NewLine
        }
    }
    Write-Warning -Message $msg
}

$translationPaths = Resolve-Path -Path "$InputDirectory/NeoIPC-Infectious-Agents.*.yaml" -Relative |
    ForEach-Object {
        $_ -match '^.*NeoIPC-Infectious-Agents\.(.*)\.yaml$' | Out-Null
        [PSCustomObject]@{
            Language = $Matches[1]
            FilePath = $Matches[0]
        }
    }

if ($TranslationLanguages) {
    $translationPaths = $translationPaths |
        Where-Object Language -In $TranslationLanguages
}

$translationPaths = @(
    [PSCustomObject]@{
        Language = 'en'
        FilePath = Resolve-Path -LiteralPath "$InputDirectory/NeoIPC-Infectious-Agents.yaml" -Relative
    }) + @($translationPaths)


if (-not $OutputFormats) {
    $intermediaryOutputFormats = @('AsciiDoc','CSV','PDF')
} elseif ($OutputFormats -contains 'PDF' -and $OutputFormats -notcontains 'AsciiDoc') {
    $intermediaryOutputFormats = @('AsciiDoc') + @($OutputFormats)
}

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$OutputDirectory = Resolve-Path -LiteralPath $OutputDirectory


foreach ($iaList in $translationPaths) {
    $culture = [cultureinfo]::GetCultureInfo($iaList.Language)
    Write-Information -MessageData ($MessageStrings.CreatingInfoMsg -f $culture.DisplayName)
    $data = Get-Content -LiteralPath $iaList.FilePath |
        ConvertFrom-Yaml
    $contentStrings = @{}
    $data.Metadata.ListTerms.GetEnumerator() |
        ForEach-Object {
            $contentStrings[$_.Name] = $_.Value.Value
        }
    $contentStrings = [PSCustomObject]$contentStrings

    $idNameDict = @{}
    $output = AppendChildrenRecursive $data.Hierarchies |
        ForEach-Object {
            $idNameDict[$_."$($contentStrings.Id)"] = $_."$($contentStrings.Name)"
            $_
        } |
        Sort-Object -Property $contentStrings.Name -Culture ([cultureinfo]::GetCultureInfo($iaList.Language))
    $outputBasePath = Join-Path -Path $OutputDirectory -ChildPath "NeoIPC-Infectious-Agents.$($culture.Name)."
    switch ($intermediaryOutputFormats) {
        'AsciiDoc' {
            Write-Information -MessageData ($MessageStrings.FormatInfoMsg -f 'AsciiDoc')
            $headerFilePath = Join-Path -Path $InputDirectory -ChildPath "Output-Header.$($culture.Name).adoc"
            $footerFilePath = Join-Path -Path $InputDirectory -ChildPath "Output-Footer.$($culture.Name).adoc"
            if (-not (Test-Path -LiteralPath $headerFilePath)) {
                $headerFilePath = Join-Path -Path $InputDirectory -ChildPath "Output-Header.adoc"
            }
            if (-not (Test-Path -LiteralPath $footerFilePath)) {
                $footerFilePath = Join-Path -Path $InputDirectory -ChildPath "Output-Footer.adoc"
            }
            $header = Get-Content -LiteralPath $headerFilePath
            $footer = Get-Content -LiteralPath $footerFilePath
            $adocOutputPath = $outputBasePath + 'adoc'
            # Assembled into one array and written once, rather than Out-File plus two -Append
            # passes: Out-File joins items with [Environment]::NewLine, so the generated AsciiDoc was
            # CRLF on Windows and LF in CI. These lists are po4a inputs and po4a wraps and re-emits
            # their text, so the extracted strings must not depend on the build platform.
            $adocLines = @(
                $header
                ''
                '[.small,cols="3,3,^1,2"]'
                '|==='
                "|$($contentStrings.Name) |$($contentStrings.Type) |$($contentStrings.CommonCommensal) |$($contentStrings.RecordedResistances)"
                ''
            )

            $adocLines += $output |
                ForEach-Object {
                    @(
                        if ($_."$($contentStrings.URL)") {
                            "[[pathogen-concept-$($_."$($contentStrings.Id)")]]$($_."$($contentStrings.URL)")[$($_."$($contentStrings.Name)"),window=_blank]"
                        } else {
                            "[[pathogen-concept-$($_."$($contentStrings.Id)")]]$($_."$($contentStrings.Name)")"
                        }
                        if ($_."$($contentStrings.ParentId)") {
                            "$($_."$($contentStrings.Type)") ($($contentStrings.SynonymFor -f "xref:pathogen-concept-$($_."$($contentStrings.ParentId)")[$($idNameDict[$_."$($contentStrings.ParentId)"])]"))"
                        } else {
                            $_."$($contentStrings.Type)"
                        }
                        "$($_."$($contentStrings.CommonCommensal)")"
                        "$($_."$($contentStrings.RecordedResistances)")"
                    ) | Join-String -Separator ' |' -OutputPrefix '|'
                }

            $adocLines += @(
                '|==='
                ''
                $footer
            )

            [System.IO.File]::WriteAllText($adocOutputPath, (($adocLines -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
            continue
        }
        'CSV' {
            Write-Information -MessageData ($MessageStrings.FormatInfoMsg -f 'CSV')
            $csvOutputPath = $outputBasePath + 'csv'
            # ConvertTo-Csv rather than Export-Csv: Export-Csv joins its rows with
            # [Environment]::NewLine, so the same invocation produced CRLF on Windows and LF in CI.
            # This output is a generated artifact under $OutputDirectory (default ../artifacts), not a
            # committed file, so nothing in git depends on it — it is pinned anyway because a
            # platform-dependent artifact is a nuisance to diff or hand off, and because the encoding was
            # already utf8NoBOM, leaving the newlines as the only thing out of step.
            $csvText = (($output | ConvertTo-Csv -UseQuotes AsNeeded) -join "`n") + "`n"
            [System.IO.File]::WriteAllText($csvOutputPath, $csvText, [System.Text.UTF8Encoding]::new($false))
            continue
        }
        'PDF' {
            Write-Information -MessageData ($MessageStrings.FormatInfoMsg -f 'PDF')
            $asciidoctorCmd = "asciidoctor-pdf -w --theme $(Resolve-Path "$InputDirectory/AsciiDoc-PDF.yml") -a pdf-fontsdir=/usr/share/fonts/truetype/ebgaramond/,GEM_FONTS_DIR $adocOutputPath"

            $asciidoctorErrors = $( $asciidoctorOutput = Invoke-Expression -Command $asciidoctorCmd ) 2>&1

            if ($asciidoctorOutput) {
                Write-Verbose -Message $asciidoctorOutput
            }
            if ($asciidoctorErrors) {
                $msg = ''
                $warningsOnly = $true
                for ($i = 0; $i -lt $asciidoctorErrors.Count; $i++) {
                    $line = $asciidoctorErrors[$i]
                    if ($line.Exception.Message -and $line.Exception.Message -notmatch '^\s*$') {
                        $msg = $msg + $line.Exception.Message + [System.Environment]::NewLine
                        if ($line.Exception.Message -notmatch '^asciidoctor: WARNING: ') {
                           $warningsOnly = $false
                        }
                    }
                }
                if ($warningsOnly) {
                    $msg = ($MessageStrings.ExternalCmdWarningMsg -f $asciidoctorCmd) + [System.Environment]::NewLine + $msg
                    Write-Warning -Message $msg
                } else {
                    $msg = ($MessageStrings.ExternalCmdErrorMsg -f $asciidoctorCmd) + [System.Environment]::NewLine + $msg
                    Write-Error -Message $msg -ErrorAction Stop
                }
            }
            if ($OutputFormats -notcontains 'AsciiDoc') {
                Remove-Item -LiteralPath $adocOutputPath -Force | Out-Null
            }
            continue
        }
        Default {
            throw "Unsupported output format: '$outputFormat'"
        }
    }
}
