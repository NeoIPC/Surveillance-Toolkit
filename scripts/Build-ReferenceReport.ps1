#!/usr/bin/env pwsh
#Requires -Version 7.6

<#
.SYNOPSIS
    Renders the NeoIPC Surveillance Reference Report.

.DESCRIPTION
    Wrapper around the Reference-Report Quarto report — the aggregate reference/benchmark view across
    participating departments, as opposed to the single-department Partner Report.

    Two modes, selected by parameter set. Online resolves DHIS2 credentials through the shared auth helper
    and acquires the reference dataset from the instance. DataFile renders from a previously exported
    dataset instead, which needs no credentials and makes a render reproducible from a fixed input.

.PARAMETER Token
    DHIS2 personal access token, or the path of a file whose first line holds one. When empty, the
    environment variable NEOIPC_DHIS2_TOKEN is read instead; with no token at all, the build prompts for a
    DHIS2 username and password. Online set; DataFile mode needs no credentials.

.PARAMETER DataFile
    Render from this previously exported dataset rather than querying DHIS2. The floor of
    contributing departments counts this file just as it counts an online build's, which R
    reads, so this mode needs Rscript too.

.PARAMETER OutputFormats
    One or more of pdf, html, docx, json. Defaults to pdf.

.PARAMETER OutputLocales
    Languages the report renders in, by default English; the report renders once per locale and format.
    Entries may also arrive comma-joined, are taken case-insensitively, and repeats collapse. The localized
    Quarto file is looked up by the locale's language and falls back to the base one; a locale with a
    territory subtag (de_AT) additionally sets the children's LC_ALL to that locale's UTF-8 form.
    Tab-completion lists the locales the report ships.

.PARAMETER Preset
    A named parameter preset from the report's presets.json, seeded over the document's own defaults
    before the parameters given on the command line: every parameter this call names explicitly
    overrides the preset's value for it, and the preset's remaining parameters still apply. Tab-completion
    lists the preset names the file carries. The two inclusion filters stand apart: the builder sets
    testUnitFilter and defaultPatientFilter on every build from -IncludeTestUnits and
    -IncludeNonCorePatients, so a preset carrying them would not take effect here.

.PARAMETER OutputDir
    Directory the reports, the generated data, and the build report are written to. A relative path resolves
    against the caller's current location, and the directory is created when it does not exist yet. Defaults
    to the report's _output directory.

.PARAMETER ReportingPeriodFrom
    Earliest date of the reporting period, given as text and passed to data acquisition and the report
    unchanged: surveillance data before it stays out. Online set.

.PARAMETER ReportingPeriodTo
    Latest date of the reporting period, given as text and passed unchanged: surveillance data after it
    stays out. Online set.

.PARAMETER BirthWeightFrom
    Minimal included birth weight. Online set.

.PARAMETER BirthWeightTo
    Maximal included birth weight. Online set.

.PARAMETER GestationWeeksFrom
    Minimal included gestational age, in weeks. Online set.

.PARAMETER GestationWeeksTo
    Maximal included gestational age, in weeks. Online set.

.PARAMETER ReportingCountries
    ISO 3166-1 alpha-2 codes of the countries whose departments the reference data covers, from the set the
    network reports from (DE, EE, GR, IT, ZA, ES, CH, GB); one or more. Without it every participating
    country is covered. Online set.

.PARAMETER ValidationExceptionFile
    CSV file listing patients to include despite failed validation, passed to data acquisition and the
    report as given. Online set.

.PARAMETER IncludeTestUnits
    Keep the patients of departments flagged as test units in the reference data, which by default filters
    them out. Online set.

.PARAMETER IncludeNonCorePatients
    Include patients who do not meet the core inclusion criteria; without it the reference data covers only
    patients in the NEOIPC_CORE set. Online set.

.PARAMETER BackupDataset
    Additionally write a password-protected archive of the acquired dataset next to the report data, for
    off-site keeping. The build asks for the backup password at a hidden prompt, clears any value the
    environment already carried before asking, and hands what it read to the data child in the
    NEOIPC_BACKUP_PASSWORD environment variable; an ambient value of that variable is not used. Online set.

.PARAMETER HideIntroductionTexts
    Leave the sections' introduction texts out of the rendered report.

.PARAMETER HideMethodsTexts
    Leave the sections' methods texts out of the rendered report.

.PARAMETER ConfidenceIntervals
    Which confidence intervals the report shows: all, none, or the families pooled and quartiles, one or
    more. Passed to the report as a comma-joined display mode; omitted, the report keeps its own default.

.PARAMETER JsonReport
    Writes the build report as a JSON file into the output directory, named with the build's UTC start time.
    Without it, the build reports itself on the console only.

.PARAMETER Quiet
    Silences the build down to warnings: no line reaches the console, not the notices of what
    the build is generating, not the build summary the report writer prints — the verbose,
    debug, and information streams and the progress bar go quiet, and the R and Quarto children
    run with their quiet flags. Warnings and errors stay visible: a build that fails gives its
    reason on the error stream. Takes precedence over -Verbose and -Debug.

.PARAMETER Dhis2Scheme
    http or https for the DHIS2 requests of the build, by default https. The choice reaches the data
    acquisition and the report's R child alike. Online set.

.PARAMETER Dhis2Hostname
    The DHIS2 instance the build reads from: the given host, else the NEOIPC_DHIS2_HOST environment variable,
    else the NeoIPC production host. Online set.

.PARAMETER Dhis2Port
    Port of the DHIS2 instance, for one served on a non-default port. Defaults to the scheme's own port.
    Online set.

.PARAMETER Dhis2Path
    The API base path the report's R code reads the data from. Online set.

.PARAMETER WhatIf
    Shows the data generation and each render without doing either; the build finishes and reports itself as
    if nothing had been produced.

.PARAMETER Confirm
    Asks before each step: -Confirm asks every time, -Confirm:$false answers for them. Without either the
    build does not ask, as its confirm impact is Medium.

.EXAMPLE
    ./scripts/Build-ReferenceReport.ps1 -OutputFormats pdf,html

.EXAMPLE
    ./scripts/Build-ReferenceReport.ps1 ./reference-data.json -OutputFormats pdf
#>

[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'Online')]
param(
    [Parameter(ParameterSetName='Online')]
    [string]$Token,

    [Parameter(ParameterSetName='DataFile', Mandatory, Position=0)]
    [ValidateScript({ Test-Path -LiteralPath $_ })]
    [string]$DataFile,

    [Parameter()]
    [ValidateSet('pdf','html','docx','json')]
    [string[]]$OutputFormats = @('pdf'),
    [ArgumentCompleter({
        param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
        @(
            Get-ChildItem -LiteralPath "$PSScriptRoot/../reports/Reference-Report/" -File -Filter 'Reference-Report.*.qmd' |
            Select-Object -ExpandProperty Name |
            ForEach-Object { if ($_ -match 'Reference-Report\.(.+)\.qmd') { $Matches[1] } }) + 'en' |
            Where-Object { $_ -like "$wordToComplete*" } |
            Sort-Object
    })]
    [Parameter()]
    [string[]]$OutputLocales = @('en'),
    [ArgumentCompleter({
        param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
        $presetsPath = Join-Path $PSScriptRoot '..' 'reports' 'Reference-Report' 'presets.json'
        if (-not (Test-Path -LiteralPath $presetsPath)) { return }
        @(((Get-Content -LiteralPath $presetsPath -Raw) | ConvertFrom-Json).presets.PSObject.Properties.Name) |
            Where-Object { $_ -like "$wordToComplete*" } |
            Sort-Object
    })]
    [Parameter()]
    [string]$Preset,
    [Parameter()]
    [string]$OutputDir = $null,
    [Parameter(ParameterSetName='Online')]
    [string]$ReportingPeriodFrom,
    [Parameter(ParameterSetName='Online')]
    [string]$ReportingPeriodTo,
    [Parameter(ParameterSetName='Online')]
    [int]$BirthWeightFrom,
    [Parameter(ParameterSetName='Online')]
    [int]$BirthWeightTo,
    [Parameter(ParameterSetName='Online')]
    [int]$GestationWeeksFrom,
    [Parameter(ParameterSetName='Online')]
    [int]$GestationWeeksTo,
    [Parameter(ParameterSetName='Online')]
    [ValidateSet('DE','EE','GR','IT','ZA','ES','CH','GB')]
    [string[]]$ReportingCountries,
    [Parameter(ParameterSetName='Online')]
    [string]$ValidationExceptionFile,
    [Parameter(ParameterSetName='Online')]
    [switch]$IncludeTestUnits,
    [Parameter(ParameterSetName='Online')]
    [switch]$IncludeNonCorePatients,
    [Parameter(ParameterSetName='Online')]
    [switch]$BackupDataset,
    [Parameter()]
    [switch]$HideIntroductionTexts,
    [Parameter()]
    [switch]$HideMethodsTexts,
    # Rows with fewer than this many events are flagged with a footnote
    # indicating statistical instability. Based on the relative standard
    # error of the Poisson distribution (1/sqrt(n)):
    #   n=10 -> 31.6%  n=16 -> 25.0%  n=20 -> 22.4%
    # Default 16 aligns with the 25% threshold recommended by the
    # Washington State Department of Health for flagging unstable rates.
    # Source: https://doh.wa.gov/sites/default/files/legacy/Documents/1500/SmallNumbers.pdf
    [Parameter()]
    [ValidateRange(1, 100)]
    [int]$SparseDataThreshold,
    [Parameter()]
    [ValidateSet('all', 'none', 'pooled', 'quartiles')]
    [string[]]$ConfidenceIntervals,
    [Parameter()]
    [switch]$JsonReport,
    [Parameter()]
    [switch]$Quiet,

    [Parameter(ParameterSetName='Online')]
    [string]$Dhis2Scheme = $null,

    [Parameter(ParameterSetName='Online')]
    [string]$Dhis2Hostname = $null,

    [Parameter(ParameterSetName='Online')]
    [Nullable[int]]$Dhis2Port = $null,

    [Parameter(ParameterSetName='Online')]
    [string]$Dhis2Path = $null,

    # Elements to enable on top of the QMD defaults. Each listed element
    # has its visibility flag(s) forced to true.
    [Parameter()]
    [ValidateSet(
        'PatientPopulation',
        'NosocomialInfections',
        'InfectiousAgents',
        'RiskFactors',
        'Surgery',
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
    # has its visibility flag(s) forced to false. If an element appears in
    # both -EnableElements and -DisableElements, -DisableElements wins.
    [Parameter()]
    [ValidateSet(
        'PatientPopulation',
        'NosocomialInfections',
        'InfectiousAgents',
        'RiskFactors',
        'Surgery',
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
    [string[]]$DisableElements = @()
)

Import-Module (Join-Path $PSScriptRoot 'modules' 'NeoIPC-Tools') -Force -Verbose:$false
# One host for every part of the build, the department list and the report data alike. Resolved inside a try, so
# that a blank host stops the build even where the caller's SilentlyContinue would let the resolver's error pass.
try { $Dhis2Hostname = Resolve-NeoIPCReportHostname -Hostname $Dhis2Hostname } catch { $PSCmdlet.ThrowTerminatingError($_) }

$isDataFileMode = $PSCmdlet.ParameterSetName -eq 'DataFile'

if ($isDataFileMode -and ($OutputFormats -contains 'json')) {
    throw "The 'json' format is not supported with -DataFile. The data file is already JSON."
}

$scriptTimestamp = (Get-Date -AsUTC).ToString("yyyy-MM-dd_HHmmss'Z'")
$repoRootDirPath = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')
$reportDirPath = Resolve-Path -LiteralPath (Join-Path $repoRootDirPath 'reports/Reference-Report')

# This build refuses a dataset with fewer than this many contributing departments:
# pooled figures from one or two would show those departments' own rates instead of
# a reference. The count comes from the dataset the build acquires, before anything
# renders. Renderers other than this builder carry their own treatment of the count.
$minimumContributingDepartments = 5

# Resolve the named preset to its render parameters here, so a name the presets file
# does not carry ends the build before it starts asking for credentials. The
# parameters seed $qmdParams below, under the explicit assignments, which win.
$presetParameters = $null
if ($Preset) {
    $presetParameters = Get-NeoIPCReportPreset -PresetsFilePath (Join-Path $reportDirPath 'presets.json') -Name $Preset
}

# Resolve OutputDir relative to the caller's location ($PWD); fall back to the report's _output.
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
} else {
    $outputDirPath = Join-Path $reportDirPath '_output'
}

$buildReportFilePath = Join-Path $outputDirPath "${scriptTimestamp}_NeoIPC-Surveillance-Reference-Report-Build.json"

$quartoCmd = Get-Command -Name quarto -ErrorAction SilentlyContinue
if (-not $quartoCmd) {
    throw 'Quarto CLI not found in PATH.'
}

$rscriptCmd = Get-Command -Name Rscript -ErrorAction SilentlyContinue
if (-not $rscriptCmd) {
    throw 'Rscript not found in PATH.'
}

$OutputFormats = $OutputFormats | ForEach-Object { $_ -split ',' } |
    ForEach-Object { $_.Trim().ToLowerInvariant() } |
    Where-Object { $_ } |
    Select-Object -Unique

$OutputLocales = $OutputLocales | ForEach-Object { $_ -split ',' } |
    ForEach-Object { $_.Trim().ToLowerInvariant() } |
    Where-Object { $_ } |
    Select-Object -Unique

# Validate locale inputs and resolve QMD files
foreach ($locale in $OutputLocales) {
    $null = Resolve-NeoIPCLocaleQmd -ReportDirPath $reportDirPath -BaseName 'Reference-Report' -Locale $locale
}

$wantsJson = $OutputFormats -contains 'json'
$renderFormats = $OutputFormats | Where-Object { $_ -ne 'json' }

if ($isDataFileMode) {
    # DataFile mode: data already exists, resolve its path
    $resolvedDataFilePath = (Resolve-Path -LiteralPath $DataFile).Path
    $jsonFilePath = $resolvedDataFilePath
    $needsJson = $false
    $jsonIntermediate = $false
    $backupFilePath = $null
    Write-Verbose "DataFile mode: rendering from $resolvedDataFilePath"
} else {
    # An online build acquires its dataset through R even when it asks for no
    # json output: the floor of contributing departments counts the dataset
    # before anything renders, and the render then shows the very dataset the
    # gate counted — one import either way. An acquired dataset that asked for
    # no json stays an intermediate, removed when the build ends clean.
    $needsJson = $true

    $jsonFilePath = Join-Path $outputDirPath "${scriptTimestamp}_NeoIPC-Surveillance-Reference-Report.json"
    $jsonIntermediate = $needsJson -and (-not $wantsJson)
    $backupFilePath = Join-Path $outputDirPath "${scriptTimestamp}_NeoIPC-Surveillance-Reference-Report.dataset.json.7z"
}

# Snapshot the bound parameters in script scope — inside the Invoke-WithNeoIPCAuth
# scriptblock $PSBoundParameters is the scriptblock's own (empty) dictionary. Feeds the
# build report's reproducibility fields.
$paramSnapshot = Get-NeoIPCParameterSnapshot -BoundParameters $PSBoundParameters

$authForEnv = if (-not $isDataFileMode) { Resolve-NeoIPCAuth -Token $Token } else { @{ AuthType = 'None' } }

# Resolve the unified log verbosity from -Quiet / -Verbose / -Debug. It reaches
# the child processes two ways: the NEOIPC_LOG_LEVEL environment variable (read
# by the QMDs / neoipcr) and native --quiet/--verbose/--debug flags on the child
# commands. Snapshot the common-parameter flags and resolve the level (and the
# per-child flag arrays) here in the script scope; inside the
# Invoke-WithNeoIPCAuth scriptblock $PSBoundParameters is the scriptblock's own
# (empty) dictionary, so the scriptblock reads the resolved arrays via closure.
$debugRequested   = $PSBoundParameters.ContainsKey('Debug')
$verboseRequested = $PSBoundParameters.ContainsKey('Verbose')
# Snapshot whether the two hide switches were named at all, for the preset overrides in
# the render scriptblock below: there $PSBoundParameters is the scriptblock's own empty
# dictionary, so mere presence cannot be asked from inside it.
$hideIntroductionTextsRequested = $PSBoundParameters.ContainsKey('HideIntroductionTexts')
$hideMethodsTextsRequested = $PSBoundParameters.ContainsKey('HideMethodsTexts')
$logLevel =
    if ($Quiet) { 'quiet' }
    elseif ($debugRequested) { 'debug' }
    elseif ($verboseRequested) { 'verbose' }
    else { 'normal' }

# -Quiet silences everything below a warning. SilentlyContinue does not: it leaves
# Write-Host lines on screen, this script's own as well as the module functions'. Ignore
# silences the script's own, the build scriptblock below included; a module function's
# lines need -InformationAction Ignore at the call, which the render and report calls take
# from $moduleInformationAction.
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

Invoke-WithNeoIPCAuth -Auth $authForEnv -ExtraEnvVars @{ 'LC_ALL' = $null; 'NEOIPC_BACKUP_PASSWORD' = $null; 'NEOIPC_LOG_LEVEL' = $logLevel } -ScriptBlock {

if (-not $isDataFileMode -and $BackupDataset -and [string]::IsNullOrWhiteSpace($env:NEOIPC_BACKUP_PASSWORD)) {
    $secureBackupPassword = Read-Host -Prompt 'Backup password' -AsSecureString
    $env:NEOIPC_BACKUP_PASSWORD =
        [System.Net.NetworkCredential]::new('', $secureBackupPassword).Password
}

$qmdParams = @{}
# The preset seeds values for parameters this call does not name; the assignments that
# follow set every parameter given on the command line, so an explicit parameter wins
# over the preset's value for it. The two filter parameters below belong to the call
# itself and are set on every build, whatever any preset holds.
if ($presetParameters) {
    foreach ($presetParameter in $presetParameters.GetEnumerator()) {
        $qmdParams[$presetParameter.Key] = $presetParameter.Value
    }
}
if ($ReportingPeriodFrom) { $qmdParams.reportingPeriodFrom = $ReportingPeriodFrom }
if ($ReportingPeriodTo) { $qmdParams.reportingPeriodTo = $ReportingPeriodTo }
if ($BirthWeightFrom) { $qmdParams.birthWeightFrom = $BirthWeightFrom }
if ($BirthWeightTo) { $qmdParams.birthWeightTo = $BirthWeightTo }
if ($GestationWeeksFrom) { $qmdParams.gestationWeeksFrom = $GestationWeeksFrom }
if ($GestationWeeksTo) { $qmdParams.gestationWeeksTo = $GestationWeeksTo }
if ($ReportingCountries) { $qmdParams.reportingCountries = ($ReportingCountries -join ',') }
if ($ValidationExceptionFile) { $qmdParams.validationExceptionFile = $ValidationExceptionFile }
$qmdParams.testUnitFilter = (-not $IncludeTestUnits)
$qmdParams.defaultPatientFilter = (-not $IncludeNonCorePatients)
# The switch's bound value, not mere presence: -HideIntroductionTexts:$false names the
# parameter explicitly and must lift a preset's false, so the call wins in both directions.
if ($hideIntroductionTextsRequested) {
    $qmdParams['includeIntroductionTexts'] = if ($HideIntroductionTexts) { 'false' } else { 'true' }
}
if ($hideMethodsTextsRequested) {
    $qmdParams['includeMethodsTexts'] = if ($HideMethodsTexts) { 'false' } else { 'true' }
}
if ($SparseDataThreshold) { $qmdParams['sparseDataThreshold'] = $SparseDataThreshold }
if ($ConfidenceIntervals) {
    $qmdParams['includeConfidenceIntervals'] = $ConfidenceIntervals -join ','
}

# Map user-friendly element names to internal Quarto metadata keys.
# Each element can map to multiple keys (e.g. a section includes its
# figures and tables together). Section introduction/methods texts are
# gated globally by -HideIntroductionTexts / -HideMethodsTexts, not per
# section.
$elementMapping = @{
    'PatientPopulation'                 = @('includeBirthWeightFigure',
                                            'includeGestationalAgeFigure')
    'NosocomialInfections'              = @('includeIncidenceDensityTable',
                                            'includeDeviceAssociatedIncidenceDensityTable')
    'InfectiousAgents'                  = @('includeAgentPerInfectionRateTable',
                                            'includeResistantPathogenInfectionRateTable')
    'RiskFactors'                       = @('includeRiskDensityRateTable')
    'Surgery'                           = @('includeSurgicalProcedureRateTable')
    'ValidationSummary'                 = @('includeValidationSummaryTable')
    'BirthWeightDistribution'           = @('includeBirthWeightFigure')
    'GestationalAgeDistribution'        = @('includeGestationalAgeFigure')
    'IncidenceDensityRates'             = @('includeIncidenceDensityTable')
    'DeviceAssociatedRates'             = @('includeDeviceAssociatedIncidenceDensityTable')
    'AgentPerInfectionRates'            = @('includeAgentPerInfectionRateTable')
    'AntibioticResistanceRates'         = @('includeResistantPathogenInfectionRateTable')
    'OrganismResistanceRates'           = @('includeOrganismResistanceRateTable')
    'InfectiousAgentDetectionRates'     = @('includeInfectiousAgentDetectionRateTable')
    'ResistanceTestRates'               = @('includeAntibioticResistanceTestRateTable')
    'AntibioticUtilisationRates'        = @('includeAntibioticUtilisationTable')
    'RiskDensityRates'                  = @('includeRiskDensityRateTable')
    'SurgicalProcedureRates'            = @('includeSurgicalProcedureRateTable')
    'SecondaryBloodstreamInfectionRates' = @('includeSecondaryBsiRateTable')
}

# Apply per-element overrides on top of QMD defaults.
# -EnableElements forces listed elements ON; -DisableElements forces them OFF.
# Elements in neither list keep their QMD defaults (no -P flag emitted).
# If an element appears in both lists, -DisableElements wins (disables run second).
foreach ($element in $EnableElements) {
    foreach ($key in $elementMapping[$element]) {
        $qmdParams[$key] = $true
    }
}
foreach ($element in $DisableElements) {
    foreach ($key in $elementMapping[$element]) {
        $qmdParams[$key] = $false
    }
}

$errors = @()
$outputFiles = @()
$buildCompleted = $false
$startedAt = (Get-Date -AsUTC).ToString('o')
$totalSteps = 0
$completedSteps = 0
if ($needsJson) { $totalSteps++ }
$totalSteps += ($renderFormats.Count * $OutputLocales.Count)

try {
    if ($needsJson) {
        $completedSteps++
        $percentComplete = if ($totalSteps -gt 0) { [int](100 * $completedSteps / $totalSteps) } else { 0 }
        Write-Progress -Activity 'Reference Report Build' -Status 'Generating JSON' -PercentComplete $percentComplete
        if ($PSCmdlet.ShouldProcess($jsonFilePath, 'Generate reference data JSON')) {
            Write-Verbose "Generating reference data JSON: $jsonFilePath"
            $rArgs = @('--vanilla', (Join-Path $reportDirPath 'Generate-ReferenceData.R'), '--file', $jsonFilePath)
            $rArgs += $rscriptVerbosityArgs
            foreach ($kvp in $qmdParams.GetEnumerator()) {
                if ($null -ne $kvp.Value -and '' -ne $kvp.Value) {
                    $rArgs += @("--$($kvp.Key)", "$($kvp.Value)")
                }
            }
            if ($IncludeTestUnits) { $rArgs += '--includeTestUnits' }
            if ($IncludeNonCorePatients) { $rArgs += '--includeNonCorePatients' }
            if ($BackupDataset) { $rArgs += @('--backup-dataset', $backupFilePath) }
            if ($Dhis2Scheme) { $rArgs += @('--scheme', $Dhis2Scheme) }
            if ($Dhis2Hostname) { $rArgs += @('--host', $Dhis2Hostname) }
            if ($Dhis2Port) { $rArgs += @('--port', $Dhis2Port) }
            if ($Dhis2Path) { $rArgs += @('--path', $Dhis2Path) }
            $rResult = Invoke-Rscript -Arguments $rArgs -Command $rscriptCmd -Description "Generate-ReferenceData.R" -InformationAction $moduleInformationAction
            if ($rResult.Status -eq 'Error') {
                throw "Generate-ReferenceData.R failed (exit code $($rResult.ExitCode))."
            }
            if (-not $jsonIntermediate) {
                $outputFiles += $jsonFilePath
            }
            Write-Verbose "Generated output: $jsonFilePath"
            if ($BackupDataset) {
                $outputFiles += $backupFilePath
                Write-Verbose "Generated output: $backupFilePath"
            }
        }
    }

    # The floor of contributing departments: pooled figures from a dataset built
    # by too few departments would show their own rates, not a reference, so a
    # build whose dataset falls below the floor warns with the count it found,
    # renders nothing, and its own finally reports it as cancelled. An online
    # -WhatIf preview has generated no dataset to count and previews as planned;
    # a -DataFile preview names a real file and counts it, which is the same read
    # the real build would make.
    $floorDatasetPath = if ($isDataFileMode) { $resolvedDataFilePath } else { $jsonFilePath }
    if (Test-Path -LiteralPath $floorDatasetPath) {
        $contributingDepartments = Get-NeoIPCReferenceDatasetDepartmentCount -DatasetFilePath $floorDatasetPath
        if ($contributingDepartments -lt $minimumContributingDepartments) {
            Write-Warning ("Fewer than {0} departments contribute to this build's dataset (found {1}); this build renders no Reference Report." -f $minimumContributingDepartments, $contributingDepartments)
            return
        }
    }

    $quartoArgsCommon = @()
    $quartoArgsCommon += $quartoVerbosityArgs
    $outputDirRelative = [System.IO.Path]::GetRelativePath($reportDirPath, $outputDirPath)
    $quartoArgsCommon += @('--output-dir', $outputDirRelative)

    Push-Location -LiteralPath $reportDirPath
    try {
        foreach ($locale in $OutputLocales) {
            $localeParts = Split-NeoIPCLocale -Locale $locale
            $qmdFilePath = Resolve-NeoIPCLocaleQmd -ReportDirPath $reportDirPath -BaseName 'Reference-Report' -Locale $locale
            $qmdFileName = [System.IO.Path]::GetFileName($qmdFilePath)
            $profileName = $localeParts.Language

            # Set LC_ALL so R picks up the full locale (territory-specific resources)
            if ($localeParts.Territory) {
                $env:LC_ALL = "${locale}.UTF-8"
            } else {
                # Let the QMD file set its own default LC_ALL
                [Environment]::SetEnvironmentVariable('LC_ALL', $null, 'Process')
            }

            foreach ($format in $renderFormats) {
                $completedSteps++
                $percentComplete = if ($totalSteps -gt 0) { [int](100 * $completedSteps / $totalSteps) } else { 0 }
                Write-Progress -Activity 'Reference Report Build' `
                    -Status "Rendering $format for $locale" -PercentComplete $percentComplete
                $outFileName = "${scriptTimestamp}_NeoIPC-Surveillance-Reference-Report.${locale}.${format}"
                $outFilePath = Join-Path $outputDirPath $outFileName
                $quartoArgs = @('render', $qmdFileName, '--profile', $profileName, '--to', $format, '-o', $outFileName)
                # All parameters via -P (R reads params$, conditional
                # blocks use cat() + when-meta="alwaysTrue" wrappers)
                foreach ($kvp in $qmdParams.GetEnumerator()) {
                    if ($null -ne $kvp.Value -and '' -ne $kvp.Value) {
                        $quartoArgs += @('-P', "$($kvp.Key):$($kvp.Value)")
                    }
                }
                if ($needsJson -or $isDataFileMode) {
                    $quartoArgs += @('-P', "referenceDataFile:$jsonFilePath")
                }
                if (-not $isDataFileMode) {
                    if ($Dhis2Scheme) { $quartoArgs += @('-P', "dhis2Scheme:$Dhis2Scheme") }
                    if ($Dhis2Hostname) { $quartoArgs += @('-P', "dhis2Hostname:$Dhis2Hostname") }
                    if ($Dhis2Port) { $quartoArgs += @('-P', "dhis2Port:$Dhis2Port") }
                    if ($Dhis2Path) { $quartoArgs += @('-P', "dhis2Path:$Dhis2Path") }
                }
                $quartoArgs += $quartoArgsCommon
                if ($PSCmdlet.ShouldProcess($outFilePath, "Render $format for $locale")) {
                    Write-Verbose "Rendering $format for $locale"
                    $renderResult = Invoke-QuartoRender -Arguments $quartoArgs -Description "$format for $locale" -InformationAction $moduleInformationAction
                    if ($renderResult.Status -eq 'Error') {
                        $errors += $renderResult.Messages
                        throw "Quarto render failed for $locale/$format."
                    }
                    $outputFiles += $outFilePath
                    Write-Verbose "Generated output: $outFilePath"
                }
            }
        }
    }
    finally {
        Pop-Location
    }

    $buildCompleted = $true
}
catch {
    $errors += $_.Exception.Message
    Write-Error $_.Exception.Message
}
finally {
    # The intermediate dataset of a build that completed is removed; a cancelled
    # build keeps it, because the build report names its path as what the build
    # acquired and a below-floor operator needs it to inspect the count.
    if ($jsonIntermediate -and $buildCompleted -and $errors.Count -eq 0 -and (Test-Path -LiteralPath $jsonFilePath)) {
        if ($PSCmdlet.ShouldProcess($jsonFilePath, 'Remove intermediate JSON')) {
            Remove-Item -LiteralPath $jsonFilePath -Force
        }
    }

    Write-Progress -Activity 'Reference Report Build' -Completed

    $json = [ordered]@{
        filePath = if ($needsJson) { $jsonFilePath } else { $null }
        requested = $wantsJson
        intermediate = $jsonIntermediate
    }
    $backup = [ordered]@{
        enabled = [bool]$BackupDataset
        filePath = if ($BackupDataset) { $backupFilePath } else { $null }
    }
    $reportFilePath = if ($JsonReport) { $buildReportFilePath } else { $null }
    $status = Write-NeoIPCBuildReport -Name 'Reference Report Build' -StartedAt $startedAt `
        -Errors $errors -OutputFilePaths $outputFiles -BuildCompleted $buildCompleted `
        -BuildReportFilePath $reportFilePath `
        -ScriptTimestamp $scriptTimestamp -OutputDirPath $outputDirPath `
        -OutputLocales $OutputLocales -OutputFormats $OutputFormats `
        -GeneratedDataFile $json -Backup $backup `
        -ParameterHash $paramSnapshot.hash -Parameters $paramSnapshot.source `
        -InformationAction $moduleInformationAction

    if ($status -ne 'success') {
        exit 1
    }
}

} # end Invoke-WithNeoIPCAuth
