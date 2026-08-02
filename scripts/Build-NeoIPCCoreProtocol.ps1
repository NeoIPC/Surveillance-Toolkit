#!/usr/bin/env pwsh
#Requires -Version 7.6

<#
.SYNOPSIS
    Builds the NeoIPC Core Protocol document for one or more target cultures.

.DESCRIPTION
    Assembles the protocol from its AsciiDoc sources and the generated reference lists, then renders it.
    Each generated input is produced only when its own sources are newer than the output, so a rebuild
    after editing one list does not regenerate everything:

    - the antibiotics list and the infectious-agents list, both localized from their gettext catalogues;
    - the title-page background SVG, transformed from the localized resource file.

    Localized output paths carry a culture suffix, so building several cultures does not overwrite one
    another.

.EXAMPLE
    ./scripts/Build-NeoIPCCoreProtocol.ps1

.EXAMPLE
    ./scripts/Build-NeoIPCCoreProtocol.ps1 -TargetCultures de,es
#>
[CmdletBinding(DefaultParameterSetName = 'Build')]
param(
    [Parameter(ParameterSetName = 'Build', Position = 0)]
    [ArgumentCompleter({
        param($commandName, $parameterName, $wordToComplete, $commandAst,$fakeBoundParameters)
        [CultureInfo]::GetCultures([System.Globalization.CultureTypes]::AllCultures) | Where-Object { $_.Name -like "$wordToComplete*" } | ForEach-Object { $_.Name }
    })]
    [CultureInfo[]]$TargetCultures,
    [Parameter(ParameterSetName = 'Build')]
    [switch]$Html,
    [Parameter(ParameterSetName = 'Build')]
    [switch]$Pdf,
    [Parameter(ParameterSetName = 'Build')]
    [switch]$Docx,
    [Parameter(Mandatory, ParameterSetName = 'Clean')]
    [switch]$Clean
    )

Import-Module -Name (Join-Path -Resolve -Path $PSScriptRoot -ChildPath 'modules' -AdditionalChildPath 'NeoIPC-BuildTools') -Force -Verbose:$false

if ($Clean -or $Html -or $Pdf -or $Docx) { $All = $false } else { $All = $true }

$workspaceFolder = Join-Path -Resolve -Path $PSScriptRoot -ChildPath '..'
$metadataFolder =  Join-Path -Resolve -Path $workspaceFolder -ChildPath 'metadata'
$artifactsFolder = Join-Path -Resolve -Path $workspaceFolder -ChildPath 'artifacts' -ErrorAction SilentlyContinue
$antibioticsDir = Join-Path -Resolve -Path $metadataFolder -ChildPath 'common' -AdditionalChildPath 'antibiotics'
$poDir = Join-Path -Resolve -Path $workspaceFolder -ChildPath 'po'
$infectiousAgentsDir = Join-Path -Resolve -Path $metadataFolder -ChildPath 'common' -AdditionalChildPath 'infectious-agents'
$docDir = Join-Path -Resolve -Path $workspaceFolder -ChildPath 'doc'
$protocolDir = Join-Path -Resolve -Path $docDir -ChildPath 'protocol'
$imgDir = Join-Path -Resolve -Path $protocolDir -ChildPath 'img'
$commonImgDir = Join-Path -Resolve -Path $workspaceFolder -ChildPath 'common' -AdditionalChildPath 'img'
$resDir = Join-Path -Resolve -Path $protocolDir -ChildPath 'resx'
$transDir = Join-Path -Resolve -Path $protocolDir -ChildPath 'xslt'

$infectiousAgentsFileName = 'NeoIPC-Infectious-Agents.adoc'
$antibioticsFileName = 'NeoIPC-Antibiotics.adoc'
$protocolFileName = 'NeoIPC-Core-Protocol.adoc'
$docBookFileName = [System.IO.Path]::ChangeExtension($protocolFileName, 'xml')

$discoveredCultures = $null -eq $TargetCultures
if ($discoveredCultures) {
    # Discover cultures from the per-language subdirectories po4a writes, plus the invariant source at
    # the directory root. A directory counts only if it holds the protocol itself, which is what keeps
    # img/, resx/, xslt/ and definitions/ out and means no name has to be excluded by hand.
    #
    # This globbed the flat NeoIPC-Core-Protocol.<culture>.adoc until now — a name nothing has written
    # since the localization restructure moved po4a's output into subdirectories. The glob then matched
    # the invariant source alone, so every run rendered English and exited exactly as a run that
    # rendered ten would.
    $TargetCultures = @([CultureInfo]::InvariantCulture) + @(
        Get-ChildItem -Path $protocolDir -Directory |
        Where-Object { Test-Path -LiteralPath (Join-Path -Path $_.FullName -ChildPath $protocolFileName) -PathType Leaf } |
        ForEach-Object { [CultureInfo]$_.Name }
    )
}
else {
    foreach ($c in $TargetCultures) {
        $p = Get-LocalisedPath $protocolDir $protocolFileName $c -Subdirectory
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
            Write-Error ("File '$p' does not exist. Run the localization pipeline first — po4a writes " +
                "the translated protocol into doc/protocol/<culture>/, and only writes one at all for a " +
                "culture whose catalogue is translated above po4a's --keep threshold.")
            exit 1
        }
    }
}

if ($discoveredCultures) {
    # Assert the discovered set against the localization config, the one independent witness to where a
    # translated protocol lives. Discovery reads the filesystem; so does any check derived from it, which
    # is why comparing discovery to itself would establish nothing. The config is written by the side that
    # produces those files, so the two agreeing is a real statement -- and their disagreeing is exactly
    # the defect that hid here for seven months, when po4a moved its output and the builder did not follow.
    #
    # Only for auto-discovery: naming -TargetCultures is an explicit request for a subset, and the loop
    # above already fails on a culture whose source is absent.
    $declaredSources = Get-Po4aOutputPath (Join-Path $poDir 'documentation.po4a.cfg') 'doc/protocol/NeoIPC-Core-Protocol.adoc'
    $writtenSources = @($declaredSources | Where-Object { Test-Path -LiteralPath (Join-Path $workspaceFolder $_.Path) -PathType Leaf })
    $renderedNames = @($TargetCultures | ForEach-Object { $_.Name } | Where-Object { $_ })
    $overlooked = @($writtenSources | Where-Object { $_.Language -notin $renderedNames })
    if ($overlooked) {
        Write-Error ("The localization config declares a translated protocol at $($overlooked.Path -join ', ') " +
            "and the file is there, but culture discovery did not find it. The build and " +
            "po/documentation.po4a.cfg disagree about where a translated source lives.")
        exit 1
    }
    # Report the languages po4a declared and did not write, so a reduced culture set is never silent. They
    # are below the config's --keep threshold: po4a withholds a translation too sparse to publish, which is
    # working as intended and is not an error.
    $withheld = @($declaredSources | Where-Object { $_.Language -notin @($writtenSources.Language) })
    if ($withheld) {
        Write-Host ("Below the localization threshold, no source written, not built: {0}" -f (($withheld.Language) -join ', '))
    }
}

# Name the set rather than leaving it to be inferred from what appears in artifacts/. A build that
# renders one culture and a build that renders ten differ in nothing else an operator sees, which is how
# the seven-month gap above went unnoticed.
#
# Write-Host rather than Write-Information deliberately, against PSAvoidUsingWriteHost: this file's five
# existing Write-Information calls emit NOTHING by default, because $InformationPreference is
# SilentlyContinue and neither this script nor its module sets it. A line that announces what the build
# is about to do, and that nobody sees unless they already knew to ask for it, does not do the job it
# exists for. Which stream progress belongs on across this repository is a settled question nowhere and
# is tracked separately; until it is settled, being visible wins.
Write-Host ("Building the protocol for {0} culture(s): {1}" -f $TargetCultures.Count,
    (($TargetCultures | ForEach-Object { if ($_.Name) { $_.Name } else { 'invariant' } }) -join ', '))

if ($Clean) {
    $artifactsFolder | Where-Object { Test-Path -LiteralPath $_ -PathType Container } | Remove-Item -Recurse -Force -Verbose:($VerbosePreference -eq 'Continue')
    $TargetCultures | ForEach-Object {
        # -Subdirectory on both lists, matching where the build now writes them.
        Get-LocalisedPath $protocolDir $antibioticsFileName $_ -Subdirectory | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Remove-Item -Verbose:($VerbosePreference -eq 'Continue')
        Get-LocalisedPath $protocolDir $infectiousAgentsFileName $_ -Subdirectory | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Remove-Item -Verbose:($VerbosePreference -eq 'Continue')
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

# Document version metadata, derived from doc/protocol/VERSION (the release source of truth) so it stays in
# sync with the released version instead of being hardcoded. revnumber is the protocol's MAJOR.MINOR
# document revision — its human-facing revision line (e.g. 1.3, continuing the historical 1.2 -> 1.3
# progression), deliberately two-component, not the full semver. A semver pre-release suffix (e.g.
# 1.3.0-preview1) marks a PREVIEW build: revremark carries the identifier and the preview watermark is
# applied; a plain X.Y.Z is a final release (no remark, no watermark). $revNumber and $preRelease hold the
# BARE values (what Export-AsciiDocReferences substitutes into {revnumber}/{revremark} include/image paths);
# the key=value forms are assembled only for asciidoctor's -a CLI flags.
$version = (Get-Content -LiteralPath (Join-Path $protocolDir 'VERSION') -Raw).Trim()
$preRelease = if ($version -match '-(.+)$') { $Matches[1] } else { $null }
$revNumber = ((($version -split '-', 2)[0] -split '\.')[0..1] -join '.')
$revNumberArg = "revnumber=$revNumber"
if ($preRelease) { $revRemark = "revremark=$preRelease" } else { $revRemark = 'revremark!' }

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

$AWaReASrc = (Join-Path -Resolve -Path $commonImgDir -ChildPath 'AWaRe-A.svg')
$AWaReADest = (Join-Path -Path $imgDir -ChildPath 'AWaRe-A.svg')
Build-Target $AWaReADest $AWaReASrc {
    Copy-Item -LiteralPath $AWaReASrc -Destination $AWaReADest
}
$AWaReWSrc = (Join-Path -Resolve -Path $commonImgDir -ChildPath 'AWaRe-W.svg')
$AWaReWDest = (Join-Path -Path $imgDir -ChildPath 'AWaRe-W.svg')
Build-Target $AWaReWDest $AWaReWSrc {
    Copy-Item -LiteralPath $AWaReWSrc -Destination $AWaReWDest
}
$AWaReRSrc = (Join-Path -Resolve -Path $commonImgDir -ChildPath 'AWaRe-R.svg')
$AWaReRDest = (Join-Path -Path $imgDir -ChildPath 'AWaRe-R.svg')
Build-Target $AWaReRDest $AWaReRSrc {
    Copy-Item -LiteralPath $AWaReRSrc -Destination $AWaReRDest
}

$attributes = @{}
$attributes.revnumber = $revNumber
if ($preRelease) { $attributes.revremark = $preRelease }
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

    # This document reaches two kinds of file and they live in different places, which is why the renderer
    # needs both switches below rather than one root.
    #
    # SHARED, at doc/protocol: the header, img/, the PDF theme. Reached by plain relative paths, so
    # --base-dir has to keep pointing here even when the source being rendered is one level down.
    # Asciidoctor's base directory is what {docdir} becomes, and {docdir} is what a relative target
    # resolves against -- so this single flag preserves every shared reference unchanged.
    #
    # LOCALIZED, at doc/protocol/<culture>: the translated protocol, its definitions, and the two
    # generated lists. Reached through {locale-dir}, which is '.' for the invariant source at the root.
    #
    # `lang` reaches asciidoctor here for the first time. It was only ever put in $attributes, which is
    # read by the dependency lister and by nothing else -- so the two things the document keys on it,
    # doc/locale/attributes-<lang>.adoc (asciidoctor's own caption translations) and the localized title
    # page and watermark, were never selected. A localized build silently used English captions and the
    # English title page, and nobody saw it because no localized build has run since 2025-12-29.
    $localeDir = if ($targetCulture.Name) { $targetCulture.Name } else { '.' }
    $attributes['locale-dir'] = $localeDir
    $cultureArgs = @('-B', $protocolDir, '-a', "locale-dir=$localeDir")
    if ($targetCulture.Name) { $cultureArgs += @('-a', "lang=$($targetCulture.TwoLetterISOLanguageName)") }

    # Beside the translated protocol, not flat with a culture suffix: the protocol reaches both generated
    # lists through {locale-dir}, the same prefix its localized definitions use, so a culture's fragments
    # are all in one place and the include line is identical for every culture. Flat would resolve the
    # German protocol's list include to the English list -- silently, since a list in the wrong language
    # renders perfectly well.
    $antibioticsListFile = Get-LocalisedPath $protocolDir $antibioticsFileName $targetCulture -Subdirectory
    # New-AntibioticsList reads the base antibiotic + UI-label CSVs plus the per-locale gettext catalogue
    # po/antibiotics.<lang>.po (the translation source that replaced the retired .<lang>.csv sidecars), so the
    # incremental-build dependency set must track all three (the two base CSVs always exist; the .po is per-locale).
    $antibioticsListInputs = @(
        (Join-Path $antibioticsDir 'NeoIPC-Antibiotics.csv')
        (Join-Path $antibioticsDir 'ListElements.csv')
    ) + @(Get-LocalisedPath $poDir 'antibiotics.po' $targetCulture -All -Existing)
    Build-Target $antibioticsListFile $antibioticsListInputs {
        Write-Verbose "Generating list of antibiotics"
        # Not Out-File: it joins pipeline items with [Environment]::NewLine, so the generated AsciiDoc
        # would be CRLF on Windows and LF in CI. These lists are po4a inputs, and po4a wraps and
        # re-emits their text — the extracted strings must not depend on the platform that built them.
        $lines = New-AntibioticsList -TargetCulture $targetCulture -MetadataPath $metadataFolder -AsciiDoc
        [System.IO.File]::WriteAllText($antibioticsListFile, (($lines -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
    }
    $infectiousAgentsListFile = Get-LocalisedPath $protocolDir $infectiousAgentsFileName $targetCulture -Subdirectory
    Build-Target $infectiousAgentsListFile (Get-LocalisedPath $infectiousAgentsDir 'NeoIPC-Pathogen-Concepts.csv' $targetCulture -All -Existing),(Get-LocalisedPath $infectiousAgentsDir 'NeoIPC-Pathogen-Synonyms.csv' $targetCulture -All -Existing) {
        Write-Verbose "Generating list of infectious agents"
        $lines = New-PathogenList -TargetCulture $targetCulture -MetadataPath $metadataFolder -AsciiDoc
        [System.IO.File]::WriteAllText($infectiousAgentsListFile, (($lines -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
    }
    Build-Target (Get-LocalisedPath $imgDir 'NeoIPC-Core-Title-Page.svg' $targetCulture) (Get-LocalisedPath $resDir 'NeoIPC-Core-Title-Page.resx' $targetCulture -All -Existing),(Join-Path $transDir 'NeoIPC-Core-Title-Page.xslt') {
        Write-Verbose "Generating title page background SVG"
        $titlePage.Transform("$resDir/NeoIPC-Core-Title-Page$localeSuffix.resx", "$imgDir/NeoIPC-Core-Title-Page$localeSuffix.svg")
    }
    if ($preRelease) {
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
    # The protocol source is po4a's output, so it takes the subdirectory convention. Everything else
    # resolved in this loop is generated by this build and stays flat with a culture suffix.
    $protocolFile = Get-LocalisedPath $protocolDir $protocolFileName $targetCulture -Resolve -Subdirectory
    if ($All -or $Html) {
        $att = $attributes.Clone()
        $att['backend-html5'] = $true
        $outputFile = Get-LocalisedPath $artifactsFolder 'index.html' $targetCulture
        Build-Target $outputFile (@($protocolFile)+@(Export-AsciiDocReferences $protocolFile $att -BaseDirectory $protocolDir)) {
            Write-Information "Generating HTML"
            # -v, not -w. Asciidoctor reports a cross-reference whose target does not exist as
            # "possible invalid reference" at INFO level, guarded by `if logger.info?`, so at the
            # default WARN level it is never emitted at all: the anchor is rendered, the link is dead,
            # and the build is green. Seven such references shipped in this protocol undetected.
            # Raising the failure level to match is safe rather than noisy - INFO has nine call sites
            # in Asciidoctor 2.0.26 (refs/asciidoctor), and every one is a real defect: a dropped
            # include, a reference to a missing attribute, a bad inline-macro substitution, or this.
            # None fires on a document that is correct, and this repository uses no optional includes.
            # -D and the source are absolute because @cultureArgs carries --base-dir: asciidoctor resolves
            # a relative output directory against the base directory, not the working directory, so the
            # relative form the four renderer calls used would write into doc/protocol/artifacts.
            asciidoctor @cultureArgs -a $revNumberArg -a $revRemark -a $revDate -b html5 -v --failure-level=INFO -D $artifactsFolder -o $([System.IO.Path]::GetFileName($outputFile)) $protocolFile
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
        Build-Target $docbookFile (@($protocolFile)+@(Export-AsciiDocReferences $protocolFile $att -BaseDirectory $protocolDir)) {
            Write-Verbose "Generating DocBook xml"
            asciidoctor @cultureArgs -a $revNumberArg -a $revRemark -a $revDate -b docbook -v --failure-level=INFO -D $protocolDir -o $([System.IO.Path]::GetFileName($docbookFile)) $protocolFile
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
            Build-Target $outputFile (@($protocolFile)+@(Export-AsciiDocReferences $protocolFile $att -BaseDirectory $protocolDir)) {
                Write-Information "Generating PDF"
                # No --failure-level here, unlike the two Asciidoctor backends above -- and not at any
                # value, which is the part worth reading before "fixing" this by setting WARN instead.
                # Asciidoctor PDF emits NOTHING at INFO: it has zero logger.info sites and two
                # logger.info? guards, both wrapping logger.WARN calls (the AFM encoding fallback and
                # the missing-glyph report). So it uses info? as a verbosity switch on warn-severity
                # messages, the opposite idiom to core's, where logger.info is both the severity and the
                # emission. -v alone unlocks them, at WARN -- so every failure level from WARN down
                # fails on them, and the INFO in the flag was never the operative part. Visibility was.
                #
                # What it fails on is output that is correct: the ballot-box characters in the
                # eligibility table warn about a Windows-1252 conversion and then render perfectly. What
                # it stays silent on is output that was broken -- a diagram drawn entirely in a
                # substituted font, Greek replaced by the logical-NOT sign, an astral codepoint
                # truncated, not one diagnostic between them. A gate that fires on the correct case and
                # misses the broken one is worse than none, because it teaches the reader around it.
                #
                # -v stays. Only the gate was wrong; those same warnings are how the font substitution
                # was found at all, and they are worth reading in the log without failing the build.
                if ($IsWindows) {
                    Write-Warning "Asciidoctor Mathematical is not supported on Windows. The STEM expressions will not be converted in your pdf output."
                    asciidoctor-pdf @cultureArgs -a compress -a $revNumberArg -a $revRemark -a $revDate -v -D $artifactsFolder -o $([System.IO.Path]::GetFileName($outputFile)) $protocolFile
                } else {
                    asciidoctor-pdf @cultureArgs -a compress -a $revNumberArg -a $revRemark -a $revDate -a mathematical-format=svg -r asciidoctor-mathematical -v -D $artifactsFolder -o $([System.IO.Path]::GetFileName($outputFile)) $protocolFile
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
