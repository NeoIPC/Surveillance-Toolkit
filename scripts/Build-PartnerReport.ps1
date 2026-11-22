#!/usr/bin/env pwsh
#Requires -Version 7.6

<#
.SYNOPSIS
Batch-generate Partner Reports for one or more sites and languages.

.DESCRIPTION
This script fetches the department/site list from DHIS2, filters by a regex, and renders the Partner Report for each site and language using Quarto.
It requires a DHIS2 API token provided as the -Token parameter or via the NEOIPC_DHIS2_TOKEN environment variable (token can be a raw token or a file path containing the token).

In DataFile mode (-DataFile), the script renders a formatted report from a pre-computed partner data JSON file without needing network access.

.PARAMETER SiteCodeFilter
    A regular expression a department code must match, compared ignoring case as -match does, applied where
    the department list is read from DHIS2. Default '.+', every department in the hierarchy. When nothing
    matches, the build warns, reports itself cancelled, and ends with exit code 1. Online set.

.PARAMETER DataFile
    A pre-computed partner data JSON file — the json format of an online run — rendered into the report
    without any network access. DataFile set, which takes no online data parameters and refuses the json
    output format.

.PARAMETER OutputLocales
    Languages the report renders in, by default English; every site renders once per locale. The localized
    Quarto file is looked up by the locale's language and falls back to the base one; a locale with a
    territory subtag (de_AT) additionally sets the children's LC_ALL to that locale's UTF-8 form.
    Tab-completion lists the locales the report ships.

.PARAMETER Token
    DHIS2 personal access token, or the path of a file whose first line holds one. When empty, the
    environment variable NEOIPC_DHIS2_TOKEN is read instead; with no token at all, the build prompts for a
    DHIS2 username and password. Online set; DataFile mode needs no credentials.

.PARAMETER OutputDir
    Directory the reports, data files, and build report are written to. A relative path resolves against the
    caller's current location, and the directory is created when it does not exist yet. Defaults to the
    report's _output directory.

.PARAMETER ReferenceDataFile
    Path to the reference data JSON passed to data generation and to the report as the reference data set the
    report compares against. Resolved against the caller's current location before the build enters the
    report directory.

.PARAMETER ReportingPeriodFrom
    Earliest date of the reporting period: surveillance data before it stays out of the report. Passed to the
    data generation and the render alike.

.PARAMETER ReportingPeriodTo
    Latest date of the reporting period: surveillance data after it stays out of the report.

.PARAMETER BirthWeightFrom
    Minimal included birth weight.

.PARAMETER BirthWeightTo
    Maximal included birth weight.

.PARAMETER GestationWeeksFrom
    Minimal included gestational age, in weeks.

.PARAMETER GestationWeeksTo
    Maximal included gestational age, in weeks.

.PARAMETER IncludeNonCorePatients
    Include patients who do not meet the core inclusion criteria; without it the data covers only patients in
    the NEOIPC_CORE set.

.PARAMETER ValidationExceptionFile
    CSV file listing patients to include despite failed validation, passed to the data generation and the
    report. Resolved against the caller's current location.

.PARAMETER IncludeTestData
    Include the patients of test departments in the report data; without it, patients of departments flagged
    as test units stay out of the dataset even where the department filter matched such a department.

.PARAMETER HideIntroductionTexts
    Leave the sections' introduction texts out of the rendered report.

.PARAMETER ConfidenceIntervals
    Which confidence intervals the report shows: all, none, or the families rate, pooled, and quartiles, one
    or more. Passed to the report as a comma-joined display mode; omitted, the report keeps its default of
    rate intervals.

.PARAMETER HideMethodsTexts
    Leave the sections' methods texts out of the rendered report.

.PARAMETER HideOutlierInterpretation
    Leave the interpretation text that accompanies flagged outliers out of the rendered report.

.PARAMETER OutputFormats
    Formats to produce, by default pdf. The pdf, html, and docx formats render the report once per site,
    locale, and format; json asks the data generation for each site's partner data without rendering —
    online mode only, refused with -DataFile.

.PARAMETER JsonReport
    Writes the build report as a JSON file into the output directory, named with the build's UTC start time.
    Without it, the build reports itself on the console only.

.PARAMETER Dhis2Scheme
    http or https for the DHIS2 requests of the build, by default https. The choice reaches the department
    list, the data generation, and the render alike. Online set.

.PARAMETER Dhis2Hostname
    The DHIS2 instance the build reads from: the given host, else the NEOIPC_DHIS2_HOST environment variable,
    else the NeoIPC production host. Online set.

.PARAMETER Dhis2Port
    Port of the DHIS2 instance, for one served on a non-default port. Defaults to the scheme's own port.
    Online set.

.PARAMETER Dhis2Path
    The API base path the report's R code reads the data from, and the last part of the key that keeps each
    instance's tab-completion cache apart. The site list is read from the instance's /api root whatever this
    says, as every read of the NeoIPC-Tools module is. Online set.

.PARAMETER Quiet
    Silences the build down to warnings: no line reaches the console, not the notices of what
    the build is generating, not the build summary the report writer prints — the verbose,
    debug, and information streams and the progress bar go quiet, and the R and Quarto children
    run with their quiet flags. Warnings and errors stay visible: a build that fails gives its
    reason on the error stream. Takes precedence over -Verbose and -Debug.

.PARAMETER WhatIf
    Shows each data generation per site and each render per site, locale, and format without running any of
    them, recording every planned step in the build report.

.PARAMETER Confirm
    Asks before each step: -Confirm asks for every one of them, -Confirm:$false answers for them. Without
    either the build never asks, as its confirm impact is Low.

.NOTES
- Cleans Quarto temporary files before each render to avoid cross-iteration contamination.
- Streams and parses Quarto output to detect and report errors and warnings.

.EXAMPLE
    .\Build-PartnerReport.ps1 -SiteCodeFilter 'NEO_.*' -OutputLocales @('en','de') -OutputDir 'C:\tmp\partner-reports' -ReferenceDataFile '2026-01-28_124237Z.Reference-Report.json' -IncludeNonCorePatients -Verbose

.EXAMPLE
    .\Build-PartnerReport.ps1 -DataFile 'partner-data.json' -OutputLocales @('en','de') -OutputFormats pdf -OutputDir 'C:\tmp\partner-reports' -Verbose
#>
[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Low', DefaultParameterSetName='Online')]
param(
    [ArgumentCompleter({
        param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
        Import-Module (Join-Path $PSScriptRoot 'modules' 'NeoIPC-Tools') -Force -Verbose:$false
        $serverKey = Get-NeoIPCServerKey `
            -Scheme $fakeBoundParameters['Dhis2Scheme'] `
            -Hostname (Resolve-NeoIPCReportHostname -Hostname $fakeBoundParameters['Dhis2Hostname']) `
            -Port $fakeBoundParameters['Dhis2Port'] `
            -Path $fakeBoundParameters['Dhis2Path']
        $cacheFilePath = Join-Path $PSScriptRoot '..' 'data' $serverKey 'site-codes.txt'
        if (Test-Path -LiteralPath $cacheFilePath) {
            Get-Content -LiteralPath $cacheFilePath |
                Where-Object { $_ -like "$wordToComplete*" } |
                Sort-Object
        } else {
            $cacheBaseDirPath = Join-Path $PSScriptRoot '..' 'data'
            Get-ChildItem -LiteralPath $cacheBaseDirPath -Recurse -Filter 'site-codes.txt' -ErrorAction SilentlyContinue |
                Get-Content |
                Sort-Object -Unique |
                Where-Object { $_ -like "$wordToComplete*" }
        }
    })]
    [Parameter(ParameterSetName='Online', Position=0)]
    [string]
    $SiteCodeFilter = '.+',

    [Parameter(ParameterSetName='DataFile', Mandatory, Position=0)]
    [ValidateScript({ Test-Path -LiteralPath $_ })]
    [string]
    $DataFile,

    [ArgumentCompleter({
        param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
        @(
            Get-ChildItem -LiteralPath "$PSScriptRoot/../reports/Partner-Report/" -File -Filter 'Partner-Report.*.qmd' |
            Select-Object -ExpandProperty Name |
            ForEach-Object { if ($_ -match 'Partner-Report\.(.+)\.qmd') { $Matches[1] } }) + 'en' |
            Where-Object { $_ -like "$wordToComplete*" } |
            Sort-Object
    })]
    [Parameter(Position=1)]
    [string[]]
    $OutputLocales = @('en'),

    [Parameter(ParameterSetName='Online')]
    [string]
    $Token = $null,

    [Parameter()]
    [string]
    $OutputDir = $null,

    [Parameter()]
    [string]
    $ReferenceDataFile = $null,

    [Parameter(ParameterSetName='Online')]
    [Nullable[System.DateOnly]]
    $ReportingPeriodFrom = $null,

    [Parameter(ParameterSetName='Online')]
    [Nullable[System.DateOnly]]
    $ReportingPeriodTo = $null,

    [Parameter(ParameterSetName='Online')]
    [Nullable[int]]
    $BirthWeightFrom = $null,

    [Parameter(ParameterSetName='Online')]
    [Nullable[int]]
    $BirthWeightTo = $null,

    [Parameter(ParameterSetName='Online')]
    [Nullable[int]]
    $GestationWeeksFrom = $null,

    [Parameter(ParameterSetName='Online')]
    [Nullable[int]]
    $GestationWeeksTo = $null,

    [Parameter(ParameterSetName='Online')]
    [switch]
    $IncludeNonCorePatients,

    [Parameter(ParameterSetName='Online')]
    [string]
    $ValidationExceptionFile,

    [Parameter(ParameterSetName='Online')]
    [switch]
    $IncludeTestData,

    [Parameter()]
    [switch]
    $HideIntroductionTexts,

    [Parameter()]
    [ValidateSet('all', 'none', 'rate', 'pooled', 'quartiles')]
    [string[]]
    $ConfidenceIntervals,

    [Parameter()]
    [switch]
    $HideMethodsTexts,

    [Parameter()]
    [switch]
    $HideOutlierInterpretation,

    # Rows with fewer than this many events are flagged with a footnote
    # indicating statistical instability. Based on the relative standard
    # error of the Poisson distribution (1/sqrt(n)):
    #   n=10 -> 31.6%  n=16 -> 25.0%  n=20 -> 22.4%
    # Default 16 aligns with the 25% threshold recommended by the
    # Washington State Department of Health for flagging unstable rates.
    # Source: https://doh.wa.gov/sites/default/files/legacy/Documents/1500/SmallNumbers.pdf
    [Parameter()]
    [ValidateRange(1, 100)]
    [int]
    $SparseDataThreshold,

    [Parameter()]
    [ValidateSet('pdf','html','docx','json')]
    [string[]]
    $OutputFormats = @('pdf'),

    [Parameter()]
    [switch]
    $JsonReport,

    [Parameter(ParameterSetName='Online')]
    [string]
    $Dhis2Scheme = $null,

    [Parameter(ParameterSetName='Online')]
    [string]
    $Dhis2Hostname = $null,

    [Parameter(ParameterSetName='Online')]
    [Nullable[int]]
    $Dhis2Port = $null,

    # The API base path the report's R code reads the data from, and the last
    # part of the key that keeps each instance's tab-completion cache apart.
    # The site list is read from the instance's /api root whatever this says,
    # as every read of the NeoIPC-Tools module is.
    [Parameter(ParameterSetName='Online')]
    [string]
    $Dhis2Path = $null,

    # Elements to enable on top of the QMD defaults. Each listed element
    # has its visibility flag forced to true.
    [Parameter()]
    [ValidateSet(
        'ValidationSummary',
        'BirthWeightDistribution',
        'GestationalAgeDistribution',
        'IncidenceDensityRates',
        'DeviceAssociatedRates',
        'AgentPerInfectionRates',
        'AntibioticResistanceRates',
        'OrganismResistanceRates',
        'InfectiousAgentDetectionRates',
        'ResistanceTestRates',
        'AntibioticUtilisationRates',
        'RiskDensityRates',
        'SurgicalProcedureRates',
        'SecondaryBloodstreamInfectionRates'
    )]
    [string[]]$EnableElements = @(),
    # Elements to disable on top of the QMD defaults. Each listed element
    # has its visibility flag forced to false. If an element appears in
    # both -EnableElements and -DisableElements, -DisableElements wins.
    [Parameter()]
    [ValidateSet(
        'ValidationSummary',
        'BirthWeightDistribution',
        'GestationalAgeDistribution',
        'IncidenceDensityRates',
        'DeviceAssociatedRates',
        'AgentPerInfectionRates',
        'AntibioticResistanceRates',
        'OrganismResistanceRates',
        'InfectiousAgentDetectionRates',
        'ResistanceTestRates',
        'AntibioticUtilisationRates',
        'RiskDensityRates',
        'SurgicalProcedureRates',
        'SecondaryBloodstreamInfectionRates'
    )]
    [string[]]$DisableElements = @(),

    [switch]$Quiet
)

Import-Module (Join-Path $PSScriptRoot 'modules' 'NeoIPC-Tools') -Force -Verbose:$false
# One host for every part of the build, the department list and the report data alike. Resolved inside a try, so
# that a blank host stops the build even where the caller's SilentlyContinue would let the resolver's error pass.
try { $Dhis2Hostname = Resolve-NeoIPCReportHostname -Hostname $Dhis2Hostname } catch { $PSCmdlet.ThrowTerminatingError($_) }

# --- Runtime validation ---
$isDataFileMode = $PSCmdlet.ParameterSetName -eq 'DataFile'

if ($isDataFileMode -and ($OutputFormats -contains 'json')) {
    throw "The 'json' format is not supported with -DataFile. The data file is already JSON."
}

# Separate json from Quarto-renderable formats
$wantsJson = $OutputFormats -contains 'json'
$renderFormats = @($OutputFormats | Where-Object { $_ -ne 'json' })

# Map user-friendly element names to internal Quarto parameter names
$elementMapping = @{
    'ValidationSummary' = 'includeValidationSummaryTable'
    'BirthWeightDistribution' = 'includeBirthWeightFigure'
    'GestationalAgeDistribution' = 'includeGestationalAgeFigure'
    'IncidenceDensityRates' = 'includeIncidenceDensityTable'
    'DeviceAssociatedRates' = 'includeDeviceAssociatedIncidenceDensityTable'
    'AgentPerInfectionRates' = 'includeAgentPerInfectionRateTable'
    'AntibioticResistanceRates' = 'includeResistantPathogenInfectionRateTable'
    'OrganismResistanceRates' = 'includeOrganismResistanceRateTable'
    'InfectiousAgentDetectionRates' = 'includeInfectiousAgentDetectionRateTable'
    'ResistanceTestRates' = 'includeAntibioticResistanceTestRateTable'
    'AntibioticUtilisationRates' = 'includeAntibioticUtilisationTable'
    'RiskDensityRates' = 'includeRiskDensityRateTable'
    'SurgicalProcedureRates' = 'includeSurgicalProcedureRateTable'
    'SecondaryBloodstreamInfectionRates' = 'includeSecondaryBsiRateTable'
}

# --- Start script ---
$wd = Get-Location
$reportDirPath = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..' 'reports' 'Partner-Report')

# Resolve ReferenceDataFile if provided BEFORE changing directory
# ReferenceDataFile is relative to current directory; resolve it absolutely first,
# then make it relative to partnerReportDir for Quarto
$resolvedReferenceDataFilePath = $null
if ($ReferenceDataFile) {
    # Resolve absolute path from current directory
    $absoluteRefFilePath = Resolve-Path -LiteralPath $ReferenceDataFile -ErrorAction SilentlyContinue
    if (-not $absoluteRefFilePath) {
        throw "Reference data file not found: $ReferenceDataFile"
    }
    $absoluteRefFilePath = $absoluteRefFilePath.Path

    # Convert to path relative to partnerReportDir for Quarto
    $resolvedReferenceDataFilePath = Resolve-Path -LiteralPath $absoluteRefFilePath -Relative -RelativeBasePath $reportDirPath
}

# Resolve DataFile if provided
$resolvedDataFilePath = $null
if ($DataFile) {
    $absoluteDataFilePath = Resolve-Path -LiteralPath $DataFile -ErrorAction SilentlyContinue
    if (-not $absoluteDataFilePath) {
        throw "Data file not found: $DataFile"
    }
    $absoluteDataFilePath = $absoluteDataFilePath.Path
    $resolvedDataFilePath = Resolve-Path -LiteralPath $absoluteDataFilePath -Relative -RelativeBasePath $reportDirPath
}

# Resolve OutputDir BEFORE changing directory (it's relative to the caller's CWD)
$outputDirPath = $null
if ($OutputDir) {
    # Resolve a relative -OutputDir against the caller's location ($PWD), not .NET's
    # [Environment]::CurrentDirectory (PowerShell does not keep them in sync). Fall
    # back to the .NET CWD only when $PWD has no filesystem path (a non-FileSystem
    # PSDrive). GetFullPath creates nothing (stays -WhatIf-safe); New-Item makes the dir.
    $base = if ([System.IO.Path]::IsPathFullyQualified($PWD.ProviderPath)) { $PWD.ProviderPath } else { [Environment]::CurrentDirectory }
    $outputDirPath = [System.IO.Path]::GetFullPath($OutputDir, $base)
    if (-not (Test-Path -LiteralPath $outputDirPath -PathType Container)) {
        New-Item -ItemType Directory -Path $outputDirPath -Force | Out-Null
    }
}

# Resolve ValidationExceptionFile BEFORE changing directory (relative to caller's CWD)
$resolvedValidationExceptionFilePath = $null
if ($ValidationExceptionFile) {
    $absolutePath = Resolve-Path -LiteralPath $ValidationExceptionFile -ErrorAction SilentlyContinue
    if (-not $absolutePath) {
        throw "Validation exception file not found: $ValidationExceptionFile"
    }
    $resolvedValidationExceptionFilePath = Resolve-Path -LiteralPath $absolutePath.Path -Relative -RelativeBasePath $reportDirPath
}

# In DataFile mode no DHIS2 auth is needed, but we still scope LC_ALL.
# Pass a dummy auth hashtable that clears env vars without setting new ones.
$authForEnv = if ($isDataFileMode) { @{ AuthType = 'None' } } else { Resolve-NeoIPCAuth -Token $Token }

# Resolve the unified log verbosity from -Quiet / -Verbose / -Debug. It reaches
# the child processes two ways: the NEOIPC_LOG_LEVEL environment variable (read
# by the QMDs / neoipcr) and native --quiet/--verbose/--debug flags on the child
# commands. Snapshot the common-parameter flags and resolve the level (and the
# per-child flag arrays) here in the script scope; inside the
# Invoke-WithNeoIPCAuth scriptblock $PSBoundParameters is the scriptblock's own
# (empty) dictionary, so the scriptblock reads the resolved arrays via closure.
$debugRequested   = $PSBoundParameters.ContainsKey('Debug')
$verboseRequested = $PSBoundParameters.ContainsKey('Verbose')
$logLevel =
    if ($Quiet) { 'quiet' }
    elseif ($debugRequested) { 'debug' }
    elseif ($verboseRequested) { 'verbose' }
    else { 'normal' }

# -Quiet silences everything below a warning. SilentlyContinue does not: it leaves
# Write-Host lines on screen, this script's own as well as the module functions'. Ignore
# silences the script's own, the build scriptblock below included; a module function's
# lines need -InformationAction Ignore at the call, which the data step and the report call
# take from $moduleInformationAction. The render this script runs itself, outside the
# helpers, already writes a failed child's error lines to the error stream, which quiet
# runs keep.
$moduleInformationAction = 'SilentlyContinue'
if ($Quiet) {
    $VerbosePreference       = 'SilentlyContinue'
    $DebugPreference         = 'SilentlyContinue'
    $InformationPreference   = 'Ignore'
    $ProgressPreference      = 'SilentlyContinue'
    $moduleInformationAction = 'Ignore'
}

# Native verbosity flags for the child processes, derived from the same level.
$rscriptVerbosityArgs = switch ($logLevel) {
    'quiet'   { @('--quiet') }
    'verbose' { @('--verbose') }
    'debug'   { @('--debug') }
    default   { @() }
}
$quartoVerbosityArgs = switch ($logLevel) {
    'quiet'   { @('--quiet') }
    'verbose' { @('--log-level', 'info') }
    'debug'   { @('--log-level', 'debug') }
    default   { @() }
}

# Snapshot the bound parameters in script scope — inside the Invoke-WithNeoIPCAuth
# scriptblock $PSBoundParameters is the scriptblock's own (empty) dictionary. Feeds the
# build report's reproducibility fields.
$paramSnapshot = Get-NeoIPCParameterSnapshot -BoundParameters $PSBoundParameters

Invoke-WithNeoIPCAuth -Auth $authForEnv -ExtraEnvVars @{ 'LC_ALL' = $null; 'NEOIPC_LOG_LEVEL' = $logLevel } -ScriptBlock {

# Prepare build tracking before try block so variables are always initialized,
# even if an early exception (e.g. auth failure) skips the rest of the try body
$errors = @()
$outputFiles = @()
$buildCompleted = $false
$startedAt = (Get-Date -AsUTC).ToString('o')
$scriptTimestamp = [datetime]::UtcNow.ToString("yyyy-MM-dd_HHmmss'Z'")
$buildLog = @()
$totalSteps = 0
$completedSteps = 0

try {
    Set-Location -LiteralPath $reportDirPath

    if ($isDataFileMode) {
        # DataFile mode: no auth, no department fetch
        # Extract unit codes from the serialized R object's metadata via a temp script
        $dataFilePathForR = $absoluteDataFilePath -replace '\\', '/'
        $tempRFilePath = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.R'
        try {
            # Not Set-Content: it appends [Environment]::NewLine after the string it is given, while
            # the here-string's own newlines come from this file (LF). On Windows that produced a
            # genuinely MIXED file — LF throughout the body, CRLF at the end — which is the state
            # that is corrupt rather than merely wrong. WriteAllText writes the text verbatim.
            $rScript = @"
x <- jsonlite::unserializeJSON(readChar('$dataFilePathForR', file.info('$dataFilePathForR')`$size))
if (inherits(x, 'neoipcr_bnch_ds')) {
  cat(paste(x`$metadata`$own`$dataset_options`$department_filter, collapse = ','))
} else if (inherits(x, 'neoipcr_rep_ds')) {
  cat(paste(x`$metadata`$dataset_options`$department_filter, collapse = ','))
} else {
  stop('Unknown data type in file')
}
"@
            [System.IO.File]::WriteAllText($tempRFilePath, (($rScript -replace "`r`n", "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
            $siteString = & Rscript --vanilla $tempRFilePath 2>$null
        } finally {
            Remove-Item -LiteralPath $tempRFilePath -ErrorAction SilentlyContinue
        }
        if (-not $siteString) {
            throw "Could not extract unit codes from data file: $DataFile"
        }
        $siteCodes = @($siteString -split ',')
        Write-Verbose "DataFile mode: rendering from $DataFile (sites: $($siteCodes -join ', '))"
    } else {
        # Online mode: auth already resolved as $authForEnv above
        $auth = $authForEnv

        # Fetch departments
        $deptArgs = @{ Auth = $auth; SiteCodeFilter = $SiteCodeFilter }
        if ($Dhis2Scheme) { $deptArgs.Scheme = $Dhis2Scheme }
        if ($Dhis2Hostname) { $deptArgs.Hostname = $Dhis2Hostname }
        if ($Dhis2Port) { $deptArgs.Port = $Dhis2Port }
        $siteCodes = Get-NeoIPCDepartments @deptArgs

        if (-not $siteCodes -or $siteCodes.Count -eq 0) {
            Write-Warning "No sites matched filter '$SiteCodeFilter'. Nothing to do.";
            return
        }
    }

    # $outputDirPath already resolved before Set-Location

    # Step counts depend on $siteCodes which is resolved inside the try block
    if ($wantsJson -and -not $isDataFileMode) { $totalSteps += $siteCodes.Count }
    if ($renderFormats.Count -gt 0) { $totalSteps += ($siteCodes.Count * $OutputLocales.Count * $renderFormats.Count) }

    # --- JSON data generation (Online mode only) ---
    if ($wantsJson -and -not $isDataFileMode) {
        $rscriptCmd = Get-Command -Name Rscript -ErrorAction SilentlyContinue
        if (-not $rscriptCmd) {
            throw 'Rscript not found in PATH.'
        }

        foreach ($siteCode in $siteCodes) {
            $jsonTimestamp = [datetime]::Now.ToString('yyyy-MM-dd_HHmmss')
            $jsonFileName = "${jsonTimestamp}_NeoIPC-Surveillance-Partner-Data_${siteCode}.json"
            $jsonOutFilePath = if ($outputDirPath) {
                Join-Path $outputDirPath $jsonFileName
            } else {
                Join-Path $reportDirPath '_output' $jsonFileName
            }

            $currentEntry = New-NeoIPCBuildStep -SiteCode $siteCode -OutputFormat 'json' -OutputFileName $jsonFileName

            $completedSteps++
            $pct = if ($totalSteps -gt 0) { [int](100 * $completedSteps / $totalSteps) } else { 0 }
            Write-Progress -Activity 'Partner Report Build' -Status "Generating JSON for $siteCode" -PercentComplete $pct

            if ($PSCmdlet.ShouldProcess($jsonOutFilePath, "Generate partner data JSON for $siteCode")) {
                Write-Host "Generating partner data JSON for $siteCode..."
                $rArgs = @('--vanilla', (Join-Path $reportDirPath 'Generate-PartnerData.R'),
                           '--file', $jsonOutFilePath, '--unitCodes', $siteCode)
                if ($resolvedReferenceDataFilePath) {
                    # Resolve to absolute path for R script (it doesn't run from partnerReportDir)
                    $absRefFilePathForR = Join-Path $reportDirPath $resolvedReferenceDataFilePath
                    $rArgs += @('--referenceDataFile', $absRefFilePathForR)
                }
                if ($ReportingPeriodFrom -ne $null) { $rArgs += @('--reportingPeriodFrom', $ReportingPeriodFrom.ToString('yyyy-MM-dd')) }
                if ($ReportingPeriodTo -ne $null) { $rArgs += @('--reportingPeriodTo', $ReportingPeriodTo.ToString('yyyy-MM-dd')) }
                if ($BirthWeightFrom -ne $null) { $rArgs += @('--birthWeightFrom', $BirthWeightFrom) }
                if ($BirthWeightTo -ne $null) { $rArgs += @('--birthWeightTo', $BirthWeightTo) }
                if ($GestationWeeksFrom -ne $null) { $rArgs += @('--gestationWeeksFrom', $GestationWeeksFrom) }
                if ($GestationWeeksTo -ne $null) { $rArgs += @('--gestationWeeksTo', $GestationWeeksTo) }
                if ($IncludeNonCorePatients.IsPresent) { $rArgs += '--includeNonCorePatients' }
                if ($IncludeTestData.IsPresent) { $rArgs += '--includeTestData' }
                if ($resolvedValidationExceptionFilePath) {
                    $absVefFilePathForR = Join-Path $reportDirPath $resolvedValidationExceptionFilePath
                    $rArgs += @('--validationExceptionFile', $absVefFilePathForR)
                }
                if ($Dhis2Scheme) { $rArgs += @('--scheme', $Dhis2Scheme) }
                if ($Dhis2Hostname) { $rArgs += @('--host', $Dhis2Hostname) }
                if ($Dhis2Port) { $rArgs += @('--port', $Dhis2Port) }
                if ($Dhis2Path) { $rArgs += @('--path', $Dhis2Path) }
                $rArgs += $rscriptVerbosityArgs

                $rResult = Invoke-Rscript -Arguments $rArgs -Command $rscriptCmd -Description "Generate-PartnerData.R ($siteCode)" -InformationAction $moduleInformationAction

                $currentEntry = $currentEntry | Complete-NeoIPCBuildStep -Result $rResult
                if ($rResult.Status -eq 'Success') {
                    Write-Host "done." -ForegroundColor Green
                    $outputFiles += $jsonOutFilePath
                } else {
                    $errMsg = "Generate-PartnerData.R failed (exit code $($rResult.ExitCode)) for site $siteCode."
                    Write-Error $errMsg
                    $errors += $errMsg
                }
            } else {
                $currentEntry = $currentEntry | Complete-NeoIPCBuildStep -Messages @("WhatIf: would generate partner data JSON for $siteCode")
            }

            $buildLog += $currentEntry
        }
    }

    # --- Quarto rendering (if any renderable formats requested) ---
    if ($renderFormats.Count -gt 0) {
        # Check Quarto once before iterating (time-consuming; no need to repeat)
        try {
            Test-QuartoInstallation
        }
        catch {
            throw "Quarto checks failed: $($_.Exception.Message)"
        }

        # Loop by locale and site
        foreach ($locale in $OutputLocales) {
            $localeParts = Split-NeoIPCLocale -Locale $locale
            $lang = $localeParts.Language
            $qmdFilePath = Resolve-NeoIPCLocaleQmd -ReportDirPath $reportDirPath -BaseName 'Partner-Report' -Locale $locale

            # Set LC_ALL so R picks up the full locale (territory-specific resources)
            if ($localeParts.Territory) {
                $env:LC_ALL = "${locale}.UTF-8"
            } else {
                [Environment]::SetEnvironmentVariable('LC_ALL', $null, 'Process')
            }

            foreach ($siteCode in $siteCodes) {
                Write-Host "Generating partner report for $siteCode (locale: $locale)..."

                # Build file name and paths
                $timestamp = [datetime]::Now.ToString('yyyy-MM-dd_HHmmss')

                # Build -P parameter list (only supported QMD params)
                $qmdParams = @{}

                $qmdParams['unitCodes'] = $siteCode

                if ($isDataFileMode) {
                    # DataFile mode: pass data file to QMD
                    $qmdParams['partnerDataFile'] = $resolvedDataFilePath
                } else {
                    # Online mode: pass data params
                    if ($ReportingPeriodFrom -ne $null) { $qmdParams['reportingPeriodFrom'] = $ReportingPeriodFrom.ToString('yyyy-MM-dd') }
                    if ($ReportingPeriodTo -ne $null) { $qmdParams['reportingPeriodTo'] = $ReportingPeriodTo.ToString('yyyy-MM-dd') }
                    if ($BirthWeightFrom -ne $null) { $qmdParams['birthWeightFrom'] = $BirthWeightFrom }
                    if ($BirthWeightTo -ne $null) { $qmdParams['birthWeightTo'] = $BirthWeightTo }
                    if ($GestationWeeksFrom -ne $null) { $qmdParams['gestationWeeksFrom'] = $GestationWeeksFrom }
                    if ($GestationWeeksTo -ne $null) { $qmdParams['gestationWeeksTo'] = $GestationWeeksTo }
                    if ($IncludeNonCorePatients.IsPresent) { $qmdParams['includeNonCorePatients'] = 'true' }
                    if ($IncludeTestData.IsPresent) { $qmdParams['includeTestData'] = 'true' }
                    if ($resolvedValidationExceptionFilePath) { $qmdParams['validationExceptionFile'] = $resolvedValidationExceptionFilePath }
                    if ($Dhis2Scheme) { $qmdParams['dhis2Scheme'] = $Dhis2Scheme }
                    if ($Dhis2Hostname) { $qmdParams['dhis2Hostname'] = $Dhis2Hostname }
                    if ($Dhis2Port) { $qmdParams['dhis2Port'] = $Dhis2Port }
                    if ($Dhis2Path) { $qmdParams['dhis2Path'] = $Dhis2Path }
                }

                if ($resolvedReferenceDataFilePath) { $qmdParams['referenceDataFile'] = $resolvedReferenceDataFilePath }
                if ($HideIntroductionTexts.IsPresent) { $qmdParams['includeIntroductionTexts'] = 'false' }
                if ($ConfidenceIntervals) { $qmdParams['includeConfidenceIntervals'] = $ConfidenceIntervals -join ',' }
                if ($HideMethodsTexts.IsPresent) { $qmdParams['includeMethodsTexts'] = 'false' }
                if ($SparseDataThreshold) { $qmdParams['sparseDataThreshold'] = $SparseDataThreshold }
                if ($HideOutlierInterpretation.IsPresent) { $qmdParams['includeOutlierInterpretation'] = 'false' }

                # Apply per-element overrides on top of QMD defaults.
                # -EnableElements forces listed elements ON; -DisableElements forces them OFF.
                # Elements in neither list keep their QMD defaults (no -P flag emitted).
                # If an element appears in both lists, -DisableElements wins (disables run second).
                foreach ($element in $EnableElements) {
                    $qmdParams[$elementMapping[$element]] = 'true'
                }
                foreach ($element in $DisableElements) {
                    $qmdParams[$elementMapping[$element]] = 'false'
                }

                $paramPairs = Build-QmdParamPairs -Values $qmdParams

                # For each requested output format, render a report
                foreach ($format in $renderFormats) {
                    # QUARTO requires the -o value to be filename-only (no path component). Use GetFileName just to be safe.
                    $outFileName = [System.IO.Path]::GetFileName("${timestamp}_NeoIPC-Surveillance-Partner-Report_${siteCode}.${locale}.${format}")

                    # Prepare log entry for this run/format
                    $currentEntry = New-NeoIPCBuildStep -SiteCode $siteCode -OutputLocale $lang -OutputFormat $format -OutputFileName $outFileName -QmdFilePath $qmdFilePath -QmdParams $qmdParams

                    # Build Quarto argument list for this format
                    $quartoArgs = @('render', '--profile', $lang, $qmdFilePath, '--to', $format, '-o', $outFileName)
                    if ($outputDirPath) {
                        $quartoArgs += '--output-dir'
                        $quartoArgs += $outputDirPath
                    }

                    # All parameters via -P (R reads params$, conditional
                    # blocks use cat() + when-meta="alwaysTrue" wrappers)
                    $quartoArgs += $paramPairs
                    $quartoArgs += $quartoVerbosityArgs

                    # Render (or report) - respect WhatIf via ShouldProcess
                    $completedSteps++
                    $pct = if ($totalSteps -gt 0) { [int](100 * $completedSteps / $totalSteps) } else { 0 }
                    Write-Progress -Activity 'Partner Report Build' -Status "Rendering $format for $siteCode ($lang)" -PercentComplete $pct

                    $target = "$outFileName for site $siteCode (lang: $lang, format: $format)"
                    $currentMessages = New-Object System.Collections.Generic.List[string]
                    if ($PSCmdlet.ShouldProcess($target, "Render Partner Report")) {
                        # Execute the render and collect messages
                        $errorLine = ''
                        $isError = $false

                        # Debug: show full Quarto command as it will be executed (args with spaces quoted)
                        $quartoArgsQuoted = $quartoArgs | ForEach-Object {
                            if ($_ -match '\s') { '"' + ($_.ToString().Replace('"', '\"')) + '"' } else { $_.ToString() }
                        }
                        Write-Debug "Quarto command: quarto $($quartoArgsQuoted -join ' ')"

                        & quarto @quartoArgs 2>&1 | ForEach-Object -Process {
                            $s = "$_"
                            if ($s -eq 'System.Management.Automation.RemoteException') { $s = '' }

                            $currentMessages.Add($s) | Out-Null

                            if ($isError) {
                                if ($errorLine.Length -gt 0) { Write-Error -Message $errorLine; $errorLine = '' }
                                Write-Error -Message $s
                            }
                            elseif ((Get-NeoIPCRenderLogLevel -Line $s) -eq 'Error') {
                                # This wrapper classifies its own Quarto output
                                # rather than going through Invoke-QuartoRender,
                                # so it shares that function's classifier instead
                                # of keeping a second copy of the patterns.
                                $isError = $true
                                $errorLine = $s
                            }
                            elseif ((Get-NeoIPCRenderLogLevel -Line $s) -eq 'Warning') {
                                $s | Write-Warning
                            }
                            else {
                                $s | Write-Verbose
                            }
                        }

                        # The last line can be the error: flush the pending line the way
                        # the helpers do, or a failure's reason reaches neither stream.
                        if ($isError -and $errorLine.Length -gt 0) { Write-Error -Message $errorLine }

                        # Record exit status
                        $currentEntry.exitCode = $LASTEXITCODE
                        $currentEntry.messages += $currentMessages

                        if (-not $isError -and $LASTEXITCODE -eq 0) {
                            Write-Host "done." -ForegroundColor Green
                            $currentEntry.status = 'success'
                            $outFilePath = if ($outputDirPath) { Join-Path $outputDirPath $outFileName } else { Join-Path $reportDirPath '_output' $outFileName }
                            $outputFiles += $outFilePath
                        }
                        elseif ($LASTEXITCODE -ne 0 -or $isError) {
                            $errMsg = "Quarto returned exit code $LASTEXITCODE for site $siteCode (lang: $lang, format: $format)."
                            Write-Error $errMsg
                            $errors += $errMsg
                            $currentEntry.status = 'error'
                            if ($LASTEXITCODE -ne 0) { $currentEntry.messages += "Quarto exit code $LASTEXITCODE" }
                        }
                    }
                    else {
                        # WhatIf / dry-run: report planned action
                        Write-Host "WhatIf: would render $target" -ForegroundColor DarkYellow
                        $currentEntry.status = 'planned'
                        $currentEntry.messages += "WhatIf: would render $target"
                        $currentEntry.messages += "Params: $(ConvertTo-Json -Depth 3 $qmdParams | Out-String)"
                    }

                    # Add current entry to aggregated log
                    $buildLog += $currentEntry
                }
            }
        }
    }


    $buildCompleted = $true
}
catch {
    $errors += $_.Exception.Message
    Write-Error $_.Exception.Message
}
finally {
    Set-Location -LiteralPath $wd

    Write-Progress -Activity 'Partner Report Build' -Completed

    $buildReportDirPath = if ($outputDirPath) { $outputDirPath } else { Join-Path $reportDirPath '_output' }
    $buildReportFilePath = Join-Path $buildReportDirPath "${scriptTimestamp}_NeoIPC-Surveillance-Partner-Report-Build.json"
    $reportFilePath = if ($JsonReport) { $buildReportFilePath } else { $null }
    $status = Write-NeoIPCBuildReport -Name 'Partner Report Build' -StartedAt $startedAt `
        -Errors $errors -OutputFilePaths $outputFiles -BuildCompleted $buildCompleted `
        -BuildReportFilePath $reportFilePath `
        -ScriptTimestamp $scriptTimestamp -OutputDirPath $buildReportDirPath `
        -SiteCodes $siteCodes -OutputLocales $OutputLocales -OutputFormats $OutputFormats `
        -ParameterHash $paramSnapshot.hash -Parameters $paramSnapshot.source `
        -BuildSteps $buildLog `
        -InformationAction $moduleInformationAction

    if ($status -ne 'success') {
        exit 1
    }
}

} # end Invoke-WithNeoIPCAuth
