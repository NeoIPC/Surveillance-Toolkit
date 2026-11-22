#!/usr/bin/env pwsh
#Requires -Version 7.6

<#
.SYNOPSIS
    Renders the Patient Data Report for a single patient — the GDPR Article 15(3) subject-access output.

.DESCRIPTION
    Wrapper around the Patient-Data-Report Quarto report. It resolves DHIS2 credentials through the shared
    auth helper, exports that one patient's records, and drives the render, emitting a build report
    alongside the output.

    Scope is deliberately one patient: this exists to answer a data-subject access request, so the report
    covers exactly the records of the identified patient and nothing else.

.PARAMETER PatientId
    The NeoIPC patient identifier whose records the report covers.

.PARAMETER DepartmentCode
    Code of the department the patient is under surveillance in; the records are read for that department.
    Tab-completion offers the department codes of the instance being built against.

.PARAMETER OutputFormat
    pdf, html, or json, by default pdf. The json format does not render: it exports the patient's records
    through the data generation script instead.

.PARAMETER OutputLocale
    Language the report renders in, by default English. The localized Quarto file is looked up by the
    locale's language and falls back to the base one; a locale with a territory subtag (de_AT) additionally
    sets the render child's LC_ALL to that locale's UTF-8 form. The json export carries no report text and
    ignores this. Tab-completion lists the locales the report ships.

.PARAMETER Token
    DHIS2 personal access token, or the path of a file whose first line holds one. When empty, the
    environment variable NEOIPC_DHIS2_TOKEN is read instead; with no token at all, the build prompts for a
    DHIS2 username and password.

.PARAMETER Quiet
    Runs the whole build at log level quiet: the R and Quarto children run with their quiet flags, and the
    wrapper's own progress, verbose, debug, and information streams are silenced. Takes precedence over
    -Verbose and -Debug.

.PARAMETER JsonReport
    Writes the build report as a JSON file into the output directory, named with the build's UTC start time.
    Without it, the build reports itself on the console only.

.PARAMETER OutputDir
    Directory the report and the build report are written to. A relative path resolves against the caller's
    current location, and the directory is created when it does not exist yet. Defaults to the report's
    _output directory.

.PARAMETER Dhis2Scheme
    http or https for the DHIS2 requests of the build, by default https. The choice reaches the report's R
    child directly.

.PARAMETER Dhis2Hostname
    The DHIS2 instance the build reads from: the given host, else the NEOIPC_DHIS2_HOST environment variable,
    else the NeoIPC production host.

.PARAMETER Dhis2Port
    Port of the DHIS2 instance, for one served on a non-default port. Defaults to the scheme's own port.

.PARAMETER Dhis2Path
    The API base path the report's R code reads the data from, and the last part of the key that keeps each
    instance's tab-completion cache apart.

.PARAMETER WhatIf
    Shows what the build would export or render for the patient without doing it; the build finishes and
    reports itself as if nothing had been produced.

.PARAMETER Confirm
    Asks before generating: -Confirm asks, -Confirm:$false answers. Without either the build does not ask, as
    its confirm impact is Medium.

.EXAMPLE
    ./scripts/Build-PatientDataReport.ps1 'NEOIPC-000123' -OutputFormat html
#>

[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'Render')]
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$PatientId,

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
    [Parameter(Mandatory, Position = 1)]
    [string]$DepartmentCode,

    [ValidateSet('pdf', 'html', 'json')]
    [Parameter(Position = 2)]
    [string]$OutputFormat = 'pdf',

    [ArgumentCompleter({
        param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
        @(
            Get-ChildItem -LiteralPath "$PSScriptRoot/../reports/Patient-Data-Report/" -File -Filter 'Patient-Data-Report.*.qmd' |
            Select-Object -ExpandProperty Name |
            ForEach-Object { if($_ -match 'Patient-Data-Report\.(.+)\.qmd') { $Matches[1] } }) + 'en' |
            Where-Object { $_ -like "$wordToComplete*" } |
            Sort-Object
    })]
    [Parameter(Position = 3)]
    [string]$OutputLocale = 'en',

    [Parameter()]
    [string]$Token,

    [Parameter()]
    [switch]$Quiet,
    [switch]$JsonReport,

    [Parameter()]
    [string]$OutputDir = $null,

    [Parameter()]
    [string]$Dhis2Scheme = $null,

    [Parameter()]
    [string]$Dhis2Hostname = $null,

    [Parameter()]
    [Nullable[int]]$Dhis2Port = $null,

    [Parameter()]
    [string]$Dhis2Path = $null
)

Import-Module (Join-Path $PSScriptRoot 'modules' 'NeoIPC-Tools') -Force -Verbose:$false
# One host for every part of the build, the department list and the report data alike. Resolved inside a try, so
# that a blank host stops the build even where the caller's SilentlyContinue would let the resolver's error pass.
try { $Dhis2Hostname = Resolve-NeoIPCReportHostname -Hostname $Dhis2Hostname } catch { $PSCmdlet.ThrowTerminatingError($_) }
$auth = Resolve-NeoIPCAuth -Token $Token

$currentDir = Get-Location
$reportDirPath = Resolve-Path -LiteralPath "$PSScriptRoot/../reports/Patient-Data-Report/"

# Resolve OutputDir BEFORE changing directory (it's relative to the caller's CWD)
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
    $outputDirExplicit = $true
} else {
    $outputDirPath = Join-Path $reportDirPath '_output'
    $outputDirExplicit = $false
}

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

# -Quiet also silences the wrapper's own progress/verbose/info streams so the
# whole pipeline is quiet, not just the logger channel.
if ($Quiet) {
    $VerbosePreference     = 'SilentlyContinue'
    $DebugPreference       = 'SilentlyContinue'
    $InformationPreference = 'SilentlyContinue'
    $ProgressPreference    = 'SilentlyContinue'
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

Invoke-WithNeoIPCAuth -Auth $auth -ExtraEnvVars @{ 'LC_ALL' = $null; 'NEOIPC_LOG_LEVEL' = $logLevel } -ScriptBlock {

$errors = @()
$outputFiles = @()
$buildCompleted = $false
$startedAt = (Get-Date -AsUTC).ToString('o')
$scriptTimestamp = [datetime]::UtcNow.ToString("yyyy-MM-dd_HHmmss'Z'")
$generatedDataFilePath = $null

try {
    Set-Location -LiteralPath $reportDirPath

    Write-Progress -Activity 'Patient Data Report Build' -Status "Generating $OutputFormat for $PatientId" -PercentComplete 50

    $localeParts = Split-NeoIPCLocale -Locale $OutputLocale

    if ($localeParts.Territory) {
        $env:LC_ALL = "${OutputLocale}.UTF-8"
    } else {
        [Environment]::SetEnvironmentVariable('LC_ALL', $null, 'Process')
    }

    if ($OutputFormat -eq 'json') {
        $outFileName = "${scriptTimestamp}_NeoIPC-Surveillance-Patient-Data-Report_${PatientId}.json"
        $outFilePath = Join-Path $outputDirPath $outFileName
        $generatedDataFilePath = $outFilePath

        if ($PSCmdlet.ShouldProcess($outFileName, "Generate patient data JSON for $PatientId")) {
            Write-Host "Generating patient data JSON for $PatientId..."
            $rArgs = @('--vanilla', 'Generate-PatientData.R',
                '--patient-id', $PatientId,
                '--department', $DepartmentCode,
                '--output', $outFilePath)
            if ($Dhis2Scheme) { $rArgs += @('--scheme', $Dhis2Scheme) }
            if ($Dhis2Hostname) { $rArgs += @('--host', $Dhis2Hostname) }
            if ($Dhis2Port) { $rArgs += @('--port', $Dhis2Port) }
            if ($Dhis2Path) { $rArgs += @('--path', $Dhis2Path) }
            $rArgs += $rscriptVerbosityArgs
            $rResult = Invoke-Rscript -Arguments $rArgs -Description "Generate-PatientData.R"
            if ($rResult.Status -eq 'Error') {
                $errors += "Generate-PatientData.R failed (exit code $($rResult.ExitCode))."
            } else {
                $outputFiles += $outFilePath
            }
        }
    } else {
        $quartoFile = Resolve-NeoIPCLocaleQmd -ReportDirPath $reportDirPath -BaseName 'Patient-Data-Report' -Locale $OutputLocale
        $outFileName = "${scriptTimestamp}_NeoIPC-Surveillance-Patient-Data-Report_${PatientId}.${OutputLocale}.${OutputFormat}"

        if ($PSCmdlet.ShouldProcess($outFileName, "Render patient data report for $PatientId")) {
            Write-Host "Generating patient data report ($OutputFormat) for $PatientId..."
            $quartoArgs = @('render', $quartoFile,
                '--profile', $localeParts.Language,
                '--to', $OutputFormat,
                '-P', "patientId:$PatientId",
                '-P', "departmentCode:$DepartmentCode",
                '-o', $outFileName)
            if ($outputDirExplicit) { $quartoArgs += @('--output-dir', $outputDirPath) }
            if ($Dhis2Scheme) { $quartoArgs += @('-P', "dhis2Scheme:$Dhis2Scheme") }
            if ($Dhis2Hostname) { $quartoArgs += @('-P', "dhis2Hostname:$Dhis2Hostname") }
            if ($Dhis2Port) { $quartoArgs += @('-P', "dhis2Port:$Dhis2Port") }
            if ($Dhis2Path) { $quartoArgs += @('-P', "dhis2Path:$Dhis2Path") }
            $quartoArgs += $quartoVerbosityArgs
            $result = Invoke-QuartoRender -Arguments $quartoArgs -Description "patient data report for $PatientId"
            if ($result.Status -eq 'Error') {
                $errors += "Quarto render failed for $PatientId (exit code $($result.ExitCode))."
            } else {
                $outputFiles += (Join-Path $outputDirPath $outFileName)
            }
        }
    }

    $buildCompleted = $true
}
catch {
    $errors += $_.Exception.Message
}
finally {
    Set-Location -LiteralPath $currentDir

    Write-Progress -Activity 'Patient Data Report Build' -Completed

    $buildReportFilePath = Join-Path $outputDirPath "${scriptTimestamp}_NeoIPC-Surveillance-Patient-Data-Report-Build.json"
    $reportFilePath = if ($JsonReport) { $buildReportFilePath } else { $null }
    $generatedDataFile = [ordered]@{
        filePath = $generatedDataFilePath
        requested = ($OutputFormat -eq 'json')
        intermediate = $false
    }
    $status = Write-NeoIPCBuildReport -Name 'Patient Data Report Build' -StartedAt $startedAt `
        -Errors $errors -OutputFilePaths $outputFiles -BuildCompleted $buildCompleted `
        -BuildReportFilePath $reportFilePath `
        -ScriptTimestamp $scriptTimestamp -OutputDirPath $outputDirPath `
        -OutputLocales @($OutputLocale) -OutputFormats @($OutputFormat) `
        -GeneratedDataFile $generatedDataFile `
        -ParameterHash $paramSnapshot.hash -Parameters $paramSnapshot.source `
        -ExtraFields ([ordered]@{ patientId = $PatientId; departmentCode = $DepartmentCode })

    if ($status -ne 'success') {
        exit 1
    }
}

} # end Invoke-WithNeoIPCAuth
