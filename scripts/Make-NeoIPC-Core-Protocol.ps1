[CmdletBinding(DefaultParameterSetName = 'Build')]
param(
    [Parameter(ParameterSetName = 'Build', Position = 0)]
    [ArgumentCompleter({
        param($commandName, $parameterName, $wordToComplete, $commandAst,$fakeBoundParameters)
        [CultureInfo]::GetCultures([System.Globalization.CultureTypes]::AllCultures) | Where-Object { $_.Name -like "$wordToComplete*" } | ForEach-Object { $_.Name }
    })]
    [CultureInfo[]]$TargetCultures,
    [Parameter(ParameterSetName = 'Build')]
    [switch]$Release,
    [Parameter(ParameterSetName = 'Build')]
    [switch]$Html,
    [Parameter(ParameterSetName = 'Build')]
    [switch]$Pdf,
    [Parameter(ParameterSetName = 'Build')]
    [switch]$Docx,
    [Parameter(Mandatory, ParameterSetName = 'Clean')]
    [switch]$Clean
    )

Import-Module -Name (Join-Path -Resolve -Path $PSScriptRoot -ChildPath 'modules' -AdditionalChildPath 'NeoIPC-Tools') -Force -Verbose:$false

if ($Clean -or $Html -or $Pdf -or $Docx) { $All = $false } else { $All = $true }

$workspaceFolder = Join-Path -Resolve -Path $PSScriptRoot -ChildPath '..'
$metadataFolder =  Join-Path -Resolve -Path $workspaceFolder -ChildPath 'metadata'
$artifactsFolder = Join-Path -Resolve -Path $workspaceFolder -ChildPath 'artifacts' -ErrorAction SilentlyContinue
$antibioticsDir = Join-Path -Resolve -Path $metadataFolder -ChildPath 'common' -AdditionalChildPath 'antibiotics'
$pathogensDir = Join-Path -Resolve -Path $metadataFolder -ChildPath 'common' -AdditionalChildPath 'pathogens'
$docDir = Join-Path -Resolve -Path $workspaceFolder -ChildPath 'doc'
$protocolDir = Join-Path -Resolve -Path $docDir -ChildPath 'protocol'
$imgDir = Join-Path -Resolve -Path $protocolDir -ChildPath 'img'
$resDir = Join-Path -Resolve -Path $protocolDir -ChildPath 'resx'
$transDir = Join-Path -Resolve -Path $protocolDir -ChildPath 'xslt'

$infectiousAgentsFileName = 'NeoIPC-Infectious-Agents.adoc'
$antibioticsFileName = 'NeoIPC-Antibiotics.adoc'
$protocolFileName = 'NeoIPC-Core-Protocol.adoc'
$docBookFileName = [System.IO.Path]::ChangeExtension($protocolFileName, 'xml')

if ($null -eq $TargetCultures) {
    $TargetCultures = Get-Item "$protocolDir/NeoIPC-Core-Protocol.*adoc" |
    ForEach-Object { [CultureInfo]($_.Name -replace 'NeoIPC-Core-Protocol\.?([^.]*)\.adoc','$1') }
}
else {
    foreach ($c in $TargetCultures) {
        $p = Join-Path -Path $protocolDir -ChildPath "NeoIPC-Core-Protocol.$c.adoc"
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
            Write-Error "File '$p' does not exist."
            exit 1
        }
    }
}

if ($Clean) {
    $artifactsFolder | Where-Object { Test-Path -LiteralPath $_ -PathType Container } | Remove-Item -Recurse -Force -Verbose:($VerbosePreference -eq 'Continue')
    $TargetCultures | ForEach-Object {
        Get-LocalisedPath $protocolDir $antibioticsFileName $_ | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Remove-Item -Verbose:($VerbosePreference -eq 'Continue')
        Get-LocalisedPath $protocolDir $infectiousAgentsFileName $_ | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Remove-Item -Verbose:($VerbosePreference -eq 'Continue')
        Get-LocalisedPath $protocolDir $docBookFileName $_ | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Remove-Item -Verbose:($VerbosePreference -eq 'Continue')
        # ToDo: Remove generated SVG files
    }
    return
}

if (-not $artifactsFolder) {
    Write-Debug -Message "Creating build artifacts directory"
    $artifactsFolder = (New-Item -Path $workspaceFolder -Name 'artifacts' -ItemType Directory).FullName
}
$artifactsImgFolder = Join-Path -Resolve -Path $artifactsFolder -ChildPath 'img' -ErrorAction SilentlyContinue
if (-not $artifactsImgFolder) {
    Write-Debug -Message "Creating build artifacts image directory"
    $artifactsImgFolder = (New-Item -Path $artifactsFolder -Name 'img' -ItemType Directory).FullName
}

if ($Release) { $revRemark = 'revremark!' }
else { $revRemark = 'revremark=Preview' }

[AppContext]::SetSwitch("Switch.System.Xml.AllowDefaultResolver", $true);
$resolver = New-Object System.Xml.XmlUrlResolver

$titlePage = New-Object System.Xml.Xsl.XslCompiledTransform
$titlePage.Load((Get-ChildItem $transDir/NeoIPC-Core-Title-Page.xslt).FullName, [System.Xml.Xsl.XsltSettings]::TrustedXslt, $resolver)

$previewWatermark = New-Object System.Xml.Xsl.XslCompiledTransform
$previewWatermark.Load((Get-ChildItem $transDir/Preview-Watermark.xslt).FullName, [System.Xml.Xsl.XsltSettings]::TrustedXslt, $resolver)

$decisionFlow = New-Object System.Xml.Xsl.XslCompiledTransform
$decisionFlow.Load((Get-ChildItem $transDir/NeoIPC-Core-Decision-Flow.xslt).FullName, [System.Xml.Xsl.XsltSettings]::TrustedXslt, $resolver)

$masterDataSheet = New-Object System.Xml.Xsl.XslCompiledTransform
$masterDataSheet.Load((Get-ChildItem $transDir/NeoIPC-Core-Master-Data-Collection-Sheet.xslt).FullName, [System.Xml.Xsl.XsltSettings]::TrustedXslt, $resolver)

$masterDataSheetImage = New-Object System.Xml.Xsl.XslCompiledTransform
$masterDataSheetImage.Load((Get-ChildItem $transDir/NeoIPC-Core-Master-Data-Collection-Sheet-Image.xslt).FullName, [System.Xml.Xsl.XsltSettings]::TrustedXslt, $resolver)

$AWaReASrc = (Join-Path -Resolve -Path $imgDir -ChildPath 'AWaRe-A.svg')
$AWaReADest = (Join-Path -Path $artifactsFolder -ChildPath 'img' -AdditionalChildPath 'AWaRe-A.svg')
Build-Target $AWaReADest $AWaReASrc {
    Copy-Item -LiteralPath $AWaReASrc -Destination $AWaReADest
}
$AWaReWSrc = (Join-Path -Resolve -Path $imgDir -ChildPath 'AWaRe-W.svg')
$AWaReWDest = (Join-Path -Path $artifactsFolder -ChildPath 'img' -AdditionalChildPath 'AWaRe-W.svg')
Build-Target $AWaReWDest $AWaReWSrc {
    Copy-Item -LiteralPath $AWaReWSrc -Destination $AWaReWDest
}
$AWaReRSrc = (Join-Path -Resolve -Path $imgDir -ChildPath 'AWaRe-R.svg')
$AWaReRDest = (Join-Path -Path $artifactsFolder -ChildPath 'img' -AdditionalChildPath 'AWaRe-R.svg')
Build-Target $AWaReRDest $AWaReRSrc {
    Copy-Item -LiteralPath $AWaReRSrc -Destination $AWaReRDest
}

$attributes = @{}
if (-not $Release) { $attributes.revremark = $revRemark }
foreach ($targetCulture in $targetCultures)
{
    if ($targetCulture.Name) { $attributes.lang = $targetCulture.TwoLetterISOLanguageName } else { $attributes.Remove('lang') }

    if ($targetCulture.Name)
    {
        $revDate = "revdate=$([datetime]::UtcNow.ToString('d', $targetCulture))"
        $localeSuffix = ".$($targetCulture.Name)"
        Write-Information "Generating NeoIPC documentation for locale '$($targetCulture.Name)'"
    }
    else
    {
        $revDate = "revdate=$([datetime]::UtcNow.ToString('yyyy-MM-dd'))"
        $localeSuffix = ""
        Write-Information "Generating NeoIPC Core Protocol for the default locale (en-GB)"
    }

    $antibioticsListFile = Get-LocalisedPath $protocolDir $antibioticsFileName $targetCulture
    Build-Target $antibioticsListFile (Get-LocalisedPath $antibioticsDir 'NeoIPC-Antibiotics.csv' $targetCulture -All -Existing) {
        Write-Verbose "Generating list of antibiotics"
        New-AntibioticsList -TargetCulture $targetCulture -MetadataPath $metadataFolder -AsciiDoc | Out-File $antibioticsListFile -Encoding utf8NoBOM
    }
    $infectiousAgentsListFile = Get-LocalisedPath $protocolDir $infectiousAgentsFileName $targetCulture
    Build-Target $infectiousAgentsListFile (Get-LocalisedPath $pathogensDir 'NeoIPC-Pathogen-Concepts.csv' $targetCulture -All -Existing),(Get-LocalisedPath $pathogensDir 'NeoIPC-Pathogen-Synonyms.csv' $targetCulture -All -Existing) {
        Write-Verbose "Generating list of infectious agents"
        New-PathogenList -TargetCulture $targetCulture -MetadataPath $metadataFolder -AsciiDoc | Out-File $infectiousAgentsListFile -Encoding utf8NoBOM
    }
    Build-Target (Get-LocalisedPath $imgDir 'NeoIPC-Core-Title-Page.svg' $targetCulture) (Get-LocalisedPath $resDir 'NeoIPC-Core-Title-Page.resx' $targetCulture -All -Existing),(Join-Path $transDir 'NeoIPC-Core-Title-Page.xslt') {
        Write-Verbose "Generating title page background SVG"
        $titlePage.Transform("$resDir/NeoIPC-Core-Title-Page$localeSuffix.resx", "$imgDir/NeoIPC-Core-Title-Page$localeSuffix.svg")
    }
    if (-not $Release) {
        Build-Target (Get-LocalisedPath $imgDir 'Preview-Watermark.svg' $targetCulture) (Get-LocalisedPath $resDir 'Preview-Watermark.resx' $targetCulture -All -Existing),(Join-Path $transDir 'Preview-Watermark.xslt') {
            Write-Verbose "Generating preview watermark SVG"
            $previewWatermark.Transform("$resDir/Preview-Watermark$localeSuffix.resx", "$imgDir/Preview-Watermark$localeSuffix.svg")
        }
    }
    Build-Target (Get-LocalisedPath $imgDir 'NeoIPC-Core-Decision-Flow.svg' $targetCulture) (Get-LocalisedPath $resDir 'NeoIPC-Core-Decision-Flow.resx' $targetCulture -All -Existing),(Join-Path $transDir 'NeoIPC-Core-Decision-Flow.xslt') {
        Write-Verbose "Generating decision flow SVG"
        $decisionFlow.Transform("$resDir/NeoIPC-Core-Decision-Flow$localeSuffix.resx", "$imgDir/NeoIPC-Core-Decision-Flow$localeSuffix.svg")
    }
    Build-Target (Get-LocalisedPath $imgDir 'NeoIPC-Core-Master-Data-Collection-Sheet.svg' $targetCulture) (Get-LocalisedPath $resDir 'NeoIPC-Core-Master-Data-Collection-Sheet.resx' $targetCulture -All -Existing),(Join-Path $transDir 'NeoIPC-Core-Master-Data-Collection-Sheet.xslt') {
        Write-Verbose "Generating master data collection sheet SVG"
        $masterDataSheet.Transform("$resDir/NeoIPC-Core-Master-Data-Collection-Sheet$localeSuffix.resx", "$imgDir/NeoIPC-Core-Master-Data-Collection-Sheet$localeSuffix.svg")
    }
    Build-Target (Get-LocalisedPath $imgDir 'NeoIPC-Core-Master-Data-Collection-Sheet-Image.svg' $targetCulture) (Get-LocalisedPath $resDir 'NeoIPC-Core-Master-Data-Collection-Sheet.resx' $targetCulture -All -Existing),(Join-Path $transDir 'NeoIPC-Core-Master-Data-Collection-Sheet-Image.xslt') {
        Write-Verbose "Generating master data collection sheet image SVG"
        $masterDataSheetImage.Transform("$resDir/NeoIPC-Core-Master-Data-Collection-Sheet$localeSuffix.resx", "$imgDir/NeoIPC-Core-Master-Data-Collection-Sheet-Image$localeSuffix.svg")
    }
    $protocolFile = Get-LocalisedPath $protocolDir $protocolFileName $targetCulture -Resolve
    if ($All -or $Html) {
        $att = $attributes.Clone()
        $att['backend-html5'] = $true
        $outputFile = Get-LocalisedPath $artifactsFolder 'index.html' $targetCulture
        Build-Target $outputFile (@($protocolFile)+@(Export-AsciiDocReferences $protocolFile $att)) {
            Write-Information "Generating HTML"
            asciidoctor -a $revRemark -a $revDate -b html5 -w --failure-level=WARN -D $(Resolve-Path $artifactsFolder -Relative) -o $([System.IO.Path]::GetFileName($outputFile)) $(Resolve-Path $protocolFile -Relative)
            if (-not $?) { exit 1 }
            Write-Verbose "Linting HTML"

            # linthtml is pretty picky about the paths it gets so we
            # temporarily move our working directory to the workspace
            # directory to make sure it is happy
            $locationBackup = Get-Location
            try {
                Set-Location $workspaceFolder
                $allOutput = & linthtml --config (((Resolve-Path -Relative "$docDir/.linthtmlrc.yaml") -replace "\\","/") -replace "^\./","") (((Resolve-Path -Relative $outputFile) -replace "\\","/") -replace "^\./","") 2>&1
                $success = $?
                $stderr = $allOutput | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }
                $stdout = $allOutput | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }
                # For some reason linthtml writes standard output to STDERR and error messages to STDOUT
                foreach ($msg in $stderr) {
                    if ($msg.Exception.Message.Trim().Length -gt 0) {
                        Write-Verbose $msg.Exception.Message
                    }
                }
                if (-not $success) {
                    foreach ($msg in $stdout) {
                        if ($msg.Trim().Length -gt 0) {
                            Write-Error $msg
                        }
                    }
                    exit 1
                }
            }
            finally {
                Set-Location $locationBackup
            }
        }
    }
    if ($All -or $Docx -or ($Pdf -and $targetCulture.TextInfo.IsRightToLeft)) {
        $att = $attributes.Clone()
        $att['backend-docbook5'] = $true
        $docbookFile = Get-LocalisedPath $protocolDir $docBookFileName $targetCulture
        Build-Target $docbookFile (@($protocolFile)+@(Export-AsciiDocReferences $protocolFile $att)) {
            Write-Verbose "Generating DocBook xml"
            asciidoctor -a $revRemark -a $revDate -b docbook -w --failure-level=WARN -D $(Resolve-Path $protocolDir -Relative) -o $([System.IO.Path]::GetFileName($docbookFile)) $(Resolve-Path $protocolFile -Relative)
            if (-not $?) { exit 1 }
        }
    }
    if ($All -or $Pdf) {
        if ($targetCulture.TextInfo.IsRightToLeft) {
            # ToDo: Build pdf via the DocBook toolchain
        } else {
            $att = $attributes.Clone()
            $att['backend-pdf'] = $true
            $outputFile = Get-LocalisedPath $artifactsFolder 'NeoIPC-Core-Protocol.pdf' $targetCulture
            Build-Target $outputFile (@($protocolFile)+@(Export-AsciiDocReferences $protocolFile $att)) {
                Write-Information "Generating PDF"
                if ($IsWindows) {
                    Write-Warning "Asciidoctor Mathematical is not supported on Windows. The STEM expressions will not be converted in your pdf output."
                    asciidoctor-pdf -a compress -a $revRemark -a $revDate -w --failure-level=WARN -D $(Resolve-Path $artifactsFolder -Relative) -o $([System.IO.Path]::GetFileName($outputFile)) $(Resolve-Path $protocolFile -Relative)
                } else {
                    asciidoctor-pdf -a compress -a $revRemark -a $revDate -a mathematical-format=svg -r asciidoctor-mathematical -w --failure-level=WARN -D $(Resolve-Path $artifactsFolder -Relative) -o $([System.IO.Path]::GetFileName($outputFile)) $(Resolve-Path $protocolFile -Relative)
                }
                if (-not $?) { exit 1 }
            }
        }
    }
    if ($All -or $Docx) {
        $outputFile = Get-LocalisedPath $artifactsFolder 'NeoIPC-Core-Protocol.docx' $targetCulture
        Build-Target $outputFile $docbookFile {
            Write-Information "Generating Open XML for Microsoft Word (docx)"
            pandoc --from=docbook --to=docx --toc --number-sections --reference-doc=$(Resolve-Path "$docDir/reference.docx" -Relative) --resource-path=$(Resolve-Path $protocolDir -Relative) --fail-if-warnings --output=$outputFile $(Resolve-Path $docbookFile -Relative)
            if (-not $?) { exit 1 }
        }
    }
}
