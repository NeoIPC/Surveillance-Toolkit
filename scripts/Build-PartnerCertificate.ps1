#!/usr/bin/env pwsh
#Requires -Version 7.6

<#
.SYNOPSIS
    Renders the NeoIPC Surveillance Partner Certificate for one or more departments.

.DESCRIPTION
    Wrapper around the Partner-Certificate Quarto report. It resolves DHIS2 credentials through the
    shared auth helper, acquires the participation data (or renders from a supplied data file), and drives
    the render, emitting a build report alongside the certificate.

    The signatory name and signature image are the certificate's two required inputs — they appear on the
    face of the document, so there is no sensible default for either.

.PARAMETER Signatory
    Name printed as the certifying signatory.

.PARAMETER SignatureImagePath
    Path to the signature image reproduced on the certificate.

.PARAMETER DepartmentCode
    The departments to certify, given as their codes. Each code is matched as a case-insensitive regular
    expression against every department code the build reads from the DHIS2 instance, and one certificate is
    rendered per matching department. When nothing matches, the build warns, reports itself cancelled, and ends
    with exit code 1.

.PARAMETER StartYear
    Year the certified participation period begins, taken as given instead of read from the department's
    surveillance data (Pass set). Required together with EndYear, NumberOfPatients, and HospitalName.

.PARAMETER EndYear
    Year the certified participation period ends. Part of the Pass set.

.PARAMETER NumberOfPatients
    Patient count the certificate states, taken as given instead of computed from surveillance data. Part of the
    Pass set.

.PARAMETER HospitalName
    Hospital name the certificate is issued in, in place of a department code. Part of the Pass set, which
    renders a single certificate from the passed figures and reads no department list.

.PARAMETER OutputLocale
    Language the certificate renders in, by default English. The localized Quarto file is looked up by the
    locale's language and falls back to the base one; a locale with a territory subtag (de_AT) additionally sets
    the render child's LC_ALL to that locale's UTF-8 form. Tab-completion lists the locales the report ships.

.PARAMETER Token
    DHIS2 personal access token, or the path of a file whose first line holds one. When empty, the environment
    variable NEOIPC_DHIS2_TOKEN is read instead; with no token at all, the build prompts for a DHIS2 username
    and password.

.PARAMETER Quiet
    Runs the build at log level quiet: the Quarto child renders with --quiet, and the wrapper's verbose,
    debug, and information streams and its progress bar are silenced. Console messages written with
    Write-Host stay visible, the build summary among them, as do warnings, terminating errors, and
    whatever a child still prints as it runs. Takes precedence over -Verbose and -Debug.

.PARAMETER JsonReport
    Writes the build report as a JSON file into the output directory, named with the build's UTC start time.
    Without it, the build reports itself on the console only.

.PARAMETER OutputDir
    Directory the certificates and the build report are written to. A relative path resolves against the
    caller's current location, and the directory is created when it does not exist yet. Defaults to the
    report's _output directory.

.PARAMETER Dhis2Scheme
    http or https for the DHIS2 requests of the build, by default https. The choice reaches the department list
    and the certificate's R child alike.

.PARAMETER Dhis2Hostname
    The DHIS2 instance the build reads from: the given host, else the NEOIPC_DHIS2_HOST environment variable,
    else the NeoIPC production host.

.PARAMETER Dhis2Port
    Port of the DHIS2 instance, for one served on a non-default port. Defaults to the scheme's own port.

.PARAMETER Dhis2Path
    The API base path the certificate's R code reads the participation data from, and the last part of the
    key that keeps each instance's tab-completion cache apart. The department list is read from the
    instance's /api root whatever this says, as every read of the NeoIPC-Tools module is.

.PARAMETER WhatIf
    Shows each certificate the build would render without rendering it. The department list is still read from
    DHIS2, and the build report notes each planned certificate as a would-render step.

.PARAMETER Confirm
    Asks before rendering: -Confirm asks for every certificate, -Confirm:$false answers for them. Without
    either the build does not ask, as its confirm impact is Medium.

.EXAMPLE
    ./scripts/Build-PartnerCertificate.ps1 'A. Signatory' ./signature.png -Department AT_TEST_TEST
#>

[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'Acquire')]
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$Signatory,
    [Parameter(Mandatory, Position = 1)]
    [string]$SignatureImagePath,
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
    [Parameter(Mandatory, Position = 2, ParameterSetName = 'Acquire')]
    [string[]]$DepartmentCode,
    [Parameter(Mandatory, Position = 2, ParameterSetName = 'Pass')]
    [int]$StartYear,
    [Parameter(Mandatory, Position = 3, ParameterSetName = 'Pass')]
    [int]$EndYear,
    [Parameter(Mandatory, Position = 4, ParameterSetName = 'Pass')]
    [int]$NumberOfPatients,
    [Parameter(Mandatory, Position = 5, ParameterSetName = 'Pass')]
    [string]$HospitalName,
    [ArgumentCompleter({
        param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
        @(
            Get-ChildItem -LiteralPath "$PSScriptRoot/../reports/Partner-Certificate/" -File -Filter 'Partner-Certificate.*.qmd' |
            Select-Object -ExpandProperty Name |
            ForEach-Object { if($_ -match 'Partner-Certificate\.(.+)\.qmd') { $Matches[1] } }) + 'en' |
            Where-Object { $_ -like "$wordToComplete*" } |
            Sort-Object
     })]
    [Parameter(Position = 3, ParameterSetName = 'Acquire')]
    [Parameter(Position = 6, ParameterSetName = 'Pass')]
    [string]$OutputLocale = 'en',
    [Parameter(Position = 4, ParameterSetName = 'Acquire')]
    [Parameter(Position = 7, ParameterSetName = 'Pass')]
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
$reportDirPath = Resolve-Path -LiteralPath "$PSScriptRoot/../reports/Partner-Certificate/"

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

$localeParts = Split-NeoIPCLocale -Locale $OutputLocale
$quartoFile = Resolve-NeoIPCLocaleQmd -ReportDirPath $reportDirPath -BaseName 'Partner-Certificate' -Locale $OutputLocale
$SignatureImagePath = Resolve-Path -LiteralPath $SignatureImagePath -Relative -RelativeBasePath $reportDirPath

# Resolve the unified log verbosity from -Quiet / -Verbose / -Debug. It reaches
# the Quarto child two ways: the NEOIPC_LOG_LEVEL environment variable (read by
# the QMD / neoipcr) and native --quiet/--log-level flags on the render command.
# Snapshot the common-parameter flags and resolve the level (and the Quarto flag
# array) here in the script scope; inside the Invoke-WithNeoIPCAuth scriptblock
# $PSBoundParameters is the scriptblock's own (empty) dictionary, so the
# scriptblock reads the resolved array via closure.
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

# Native verbosity flags for the Quarto child, derived from the same level.
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
$buildLog = @()
$siteCodes = $null   # set in Acquire (DepartmentCode) mode; stays $null in Pass (HospitalName) mode
$buildCompleted = $false
$startedAt = (Get-Date -AsUTC).ToString('o')
$scriptTimestamp = [datetime]::UtcNow.ToString("yyyy-MM-dd_HHmmss'Z'")

try {
    Set-Location -LiteralPath $reportDirPath

    if ($localeParts.Territory) {
        $env:LC_ALL = "${OutputLocale}.UTF-8"
    } else {
        [Environment]::SetEnvironmentVariable('LC_ALL', $null, 'Process')
    }

    if ($DepartmentCode) {
        $deptArgs = @{ Auth = $auth }
        if ($Dhis2Scheme) { $deptArgs.Scheme = $Dhis2Scheme }
        if ($Dhis2Hostname) { $deptArgs.Hostname = $Dhis2Hostname }
        if ($Dhis2Port) { $deptArgs.Port = $Dhis2Port }
        $allSiteCodes = Get-NeoIPCDepartments @deptArgs

        $siteCodes = $allSiteCodes | Where-Object -FilterScript { foreach ($d in $DepartmentCode) { if ($_ -match $d) { return $true } } }

        if (-not $siteCodes -or $siteCodes.Count -eq 0) {
            Write-Warning "No department matched -DepartmentCode '$($DepartmentCode -join "', '")'. Nothing to do."
            return
        }

        $totalSteps = $siteCodes.Count
        $completedSteps = 0

        foreach ($siteCode in $siteCodes) {
            $completedSteps++
            $pct = if ($totalSteps -gt 0) { [int](100 * $completedSteps / $totalSteps) } else { 0 }
            Write-Progress -Activity 'Partner-Certificate Build' -Status "Rendering certificate for $siteCode" -PercentComplete $pct

            $outFileName = "$([datetime]::Now.ToString('yyyy-MM-dd_HHmmss'))_NeoIPC-Surveillance-Partner-Certificate_${siteCode}.${OutputLocale}.pdf"
            $currentEntry = New-NeoIPCBuildStep -SiteCode $siteCode -OutputLocale $OutputLocale -OutputFormat 'pdf' -OutputFileName $outFileName -QmdFilePath $quartoFile
            $quartoArgs = @('render', $quartoFile, '-P', "signatory:$Signatory", '-P', "signatureImagePath:$SignatureImagePath", '-P', "departmentCode:$siteCode", '-o', $outFileName)
            if ($outputDirExplicit) { $quartoArgs += @('--output-dir', $outputDirPath) }
            if ($Dhis2Scheme) { $quartoArgs += @('-P', "dhis2Scheme:$Dhis2Scheme") }
            if ($Dhis2Hostname) { $quartoArgs += @('-P', "dhis2Hostname:$Dhis2Hostname") }
            if ($Dhis2Port) { $quartoArgs += @('-P', "dhis2Port:$Dhis2Port") }
            if ($Dhis2Path) { $quartoArgs += @('-P', "dhis2Path:$Dhis2Path") }
            $quartoArgs += $quartoVerbosityArgs

            if ($PSCmdlet.ShouldProcess($outFileName, "Render partner certificate for $siteCode")) {
                Write-Host "Generating partner certificate for $siteCode..."
                $result = Invoke-QuartoRender -Arguments $quartoArgs -Description "partner certificate for $siteCode"
                $currentEntry = $currentEntry | Complete-NeoIPCBuildStep -Result $result
                if ($result.Status -eq 'Error') {
                    $errors += "Quarto render failed for $siteCode (exit code $($result.ExitCode))."
                } else {
                    $outputFiles += (Join-Path $outputDirPath $outFileName)
                }
            } else {
                $currentEntry = $currentEntry | Complete-NeoIPCBuildStep -Messages @("WhatIf: would render partner certificate for $siteCode")
            }
            $buildLog += $currentEntry
        }
    } else {
        $totalSteps = 1
        $completedSteps = 1
        Write-Progress -Activity 'Partner-Certificate Build' -Status "Rendering certificate for $HospitalName" -PercentComplete 100

        $outFileName = "$([datetime]::Now.ToString('yyyy-MM-dd_HHmmss'))_NeoIPC-Surveillance-Partner-Certificate_${HospitalName}.${OutputLocale}.pdf"
        $currentEntry = New-NeoIPCBuildStep -OutputLocale $OutputLocale -OutputFormat 'pdf' -OutputFileName $outFileName -QmdFilePath $quartoFile
        $quartoArgs = @('render', $quartoFile, '-P', "signatory:$Signatory", '-P', "signatureImagePath:$SignatureImagePath", '-P', "startYear:$StartYear", '-P', "endYear:$EndYear", '-P', "nPatients:$NumberOfPatients", '-P', "hospitalName:$HospitalName", '-o', $outFileName)
        if ($outputDirExplicit) { $quartoArgs += @('--output-dir', $outputDirPath) }
        if ($Dhis2Scheme) { $quartoArgs += @('-P', "dhis2Scheme:$Dhis2Scheme") }
        if ($Dhis2Hostname) { $quartoArgs += @('-P', "dhis2Hostname:$Dhis2Hostname") }
        if ($Dhis2Port) { $quartoArgs += @('-P', "dhis2Port:$Dhis2Port") }
        if ($Dhis2Path) { $quartoArgs += @('-P', "dhis2Path:$Dhis2Path") }
        $quartoArgs += $quartoVerbosityArgs

        if ($PSCmdlet.ShouldProcess($outFileName, "Render partner certificate for $HospitalName")) {
            Write-Host "Generating partner certificate for $HospitalName..."
            $result = Invoke-QuartoRender -Arguments $quartoArgs -Description "partner certificate for $HospitalName"
            $currentEntry = $currentEntry | Complete-NeoIPCBuildStep -Result $result
            if ($result.Status -eq 'Error') {
                $errors += "Quarto render failed for $HospitalName (exit code $($result.ExitCode))."
            } else {
                $outputFiles += (Join-Path $outputDirPath $outFileName)
            }
        } else {
            $currentEntry = $currentEntry | Complete-NeoIPCBuildStep -Messages @("WhatIf: would render partner certificate for $HospitalName")
        }
        $buildLog += $currentEntry
    }

    $buildCompleted = $true
}
catch {
    $errors += $_.Exception.Message
}
finally {
    Set-Location -LiteralPath $currentDir

    Write-Progress -Activity 'Partner-Certificate Build' -Completed

    $buildReportFilePath = Join-Path $outputDirPath "${scriptTimestamp}_NeoIPC-Surveillance-Partner-Certificate-Build.json"
    $reportFilePath = if ($JsonReport) { $buildReportFilePath } else { $null }
    $status = Write-NeoIPCBuildReport -Name 'Partner-Certificate Build' -StartedAt $startedAt `
        -Errors $errors -OutputFilePaths $outputFiles -BuildCompleted $buildCompleted `
        -BuildReportFilePath $reportFilePath `
        -ScriptTimestamp $scriptTimestamp -OutputDirPath $outputDirPath `
        -OutputLocales @($OutputLocale) `
        -SiteCodes $siteCodes `
        -BuildSteps $buildLog `
        -ParameterHash $paramSnapshot.hash -Parameters $paramSnapshot.source

    if ($status -ne 'success') {
        exit 1
    }
}

} # end Invoke-WithNeoIPCAuth
