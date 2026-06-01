<#
.SYNOPSIS
Generate Validation Reports for one or more sites, or a combined report for all departments.

.DESCRIPTION
This script fetches the department/site list from DHIS2, filters by a regex, and renders the Validation Report for each site using Quarto.
With -Combined, it renders a single report covering all departments (no departmentFilter).

.EXAMPLE
    .\New-ValidationReports.ps1 -SiteCodeFilter 'NEO_AT.*' -Locale 'de' -Token $myToken -Verbose

.EXAMPLE
    .\New-ValidationReports.ps1 -Combined -Locale 'en' -Token $myToken -JsonReport
#>
[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'PerSite')]
param(
    [ArgumentCompleter({
        param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
        Import-Module (Join-Path $PSScriptRoot 'modules' 'NeoIPC-Tools') -Force -Verbose:$false
        $serverKey = Get-NeoipcServerKey `
            -Scheme $fakeBoundParameters['Dhis2Scheme'] `
            -Hostname $fakeBoundParameters['Dhis2Hostname'] `
            -Port $fakeBoundParameters['Dhis2Port'] `
            -Path $fakeBoundParameters['Dhis2Path']
        $cacheFile = Join-Path $PSScriptRoot '..' 'data' 'local' $serverKey 'site-codes.txt'
        if (Test-Path -LiteralPath $cacheFile) {
            Get-Content -LiteralPath $cacheFile |
                Where-Object { $_ -like "$wordToComplete*" } |
                Sort-Object
        } else {
            $cacheBase = Join-Path $PSScriptRoot '..' 'data' 'local'
            Get-ChildItem -LiteralPath $cacheBase -Recurse -Filter 'site-codes.txt' -ErrorAction SilentlyContinue |
                Get-Content |
                Sort-Object -Unique |
                Where-Object { $_ -like "$wordToComplete*" }
        }
    })]
    [Parameter(ParameterSetName = 'PerSite', Position = 0)]
    [string]$SiteCodeFilter = '.+',

    [Parameter(ParameterSetName = 'Combined', Mandatory)]
    [switch]$Combined,

    [ArgumentCompleter({
        param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
        @(
            Get-ChildItem -LiteralPath "$PSScriptRoot/../reports/Validation-Report/" -File -Filter '_quarto-*.yml' |
            Select-Object -ExpandProperty Name |
            ForEach-Object { if ($_ -match '_quarto-(.+)\.yml') { $Matches[1] } }) |
            Where-Object { $_ -like "$wordToComplete*" } |
            Sort-Object
    })]
    [Parameter(Position = 1)]
    [string]$Locale = 'en',

    [Parameter(Position = 2)]
    [string]$Token,

    [string]$ValidationExceptionFile,

    [Parameter()]
    [switch]$JsonReport,

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

$auth = Resolve-NeoipcAuth -Token $Token

$reportDir = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..' 'reports' 'Validation-Report')
$outputDirPath = Join-Path $reportDir '_output'

$isCombined = $PSCmdlet.ParameterSetName -eq 'Combined'

if (-not $isCombined) {
    $deptArgs = @{ Auth = $auth; SiteCodeFilter = $SiteCodeFilter }
    if ($Dhis2Scheme) { $deptArgs.Scheme = $Dhis2Scheme }
    if ($Dhis2Hostname) { $deptArgs.Hostname = $Dhis2Hostname }
    if ($null -ne $Dhis2Port) { $deptArgs.Port = $Dhis2Port }
    if ($Dhis2Path) { $deptArgs.Path = $Dhis2Path }
    $sites = Get-NeoipcDepartments @deptArgs

    if (-not $sites -or $sites.Count -eq 0) {
        Write-Warning "No sites matched filter '$SiteCodeFilter'. Nothing to do."
        return
    }
}

$wd = Get-Location

Invoke-WithNeoipcAuth -Auth $auth -ExtraEnvVars @{ 'LC_ALL' = $null } -ScriptBlock {

$errors = @()
$outputFiles = @()
$buildCompleted = $false
$startedAt = (Get-Date -AsUTC).ToString('o')
$scriptTimestamp = [datetime]::UtcNow.ToString("yyyy-MM-dd_HHmmss'Z'")
$totalSteps = if ($isCombined) { 1 } else { $sites.Count }
$completedSteps = 0

try {
    Set-Location -LiteralPath $reportDir

    $localeParts = Split-NeoipcLocale -Locale $Locale
    $language = $localeParts.Language
    $qmdPath = Resolve-NeoipcLocaleQmd -ReportDir $reportDir -BaseName 'Validation-Report' -Locale $Locale
    $qmdFile = [System.IO.Path]::GetFileName($qmdPath)

    if ($localeParts.Territory) {
        $env:LC_ALL = "${Locale}.UTF-8"
    } else {
        [Environment]::SetEnvironmentVariable('LC_ALL', $null, 'Process')
    }

    if ($isCombined) {
        # Combined mode: single report with no departmentFilter (covers all departments)
        $completedSteps++
        $pct = [int](100 * $completedSteps / $totalSteps)
        Write-Progress -Activity 'Validation Report Build' -Status 'Rendering combined report' -PercentComplete $pct

        $outFile = "${scriptTimestamp}_NeoIPC-Surveillance-Validation-Report.${Locale}.pdf"
        $quartoArgs = @('render', $qmdFile, '--profile', $language, '-o', $outFile)
        if ($ValidationExceptionFile) {
            $quartoArgs += @('-P', "validationExceptionFile:$ValidationExceptionFile")
        }
        if ($Dhis2Scheme) { $quartoArgs += @('-P', "dhis2Scheme:$Dhis2Scheme") }
        if ($Dhis2Hostname) { $quartoArgs += @('-P', "dhis2Hostname:$Dhis2Hostname") }
        if ($null -ne $Dhis2Port) { $quartoArgs += @('-P', "dhis2Port:$Dhis2Port") }
        if ($Dhis2Path) { $quartoArgs += @('-P', "dhis2Path:$Dhis2Path") }

        if ($PSCmdlet.ShouldProcess($outFile, 'Render combined validation report')) {
            Write-Host "Generating combined validation report..."
            $result = Invoke-QuartoRender -Arguments $quartoArgs -Description 'combined validation report'
            if ($result.Status -eq 'Error') {
                $errors += "Quarto render failed for combined report."
            } elseif ($result.Status -ne 'NoData') {
                $outputFiles += (Join-Path $outputDirPath $outFile)
            }
        }
    } else {
        # PerSite mode: one report per site
        foreach ($site in $sites) {
            $completedSteps++
            $pct = [int](100 * $completedSteps / $totalSteps)
            Write-Progress -Activity 'Validation Report Build' -Status "Rendering report for $site" -PercentComplete $pct

            $outFile = "$([datetime]::Now.ToString('yyyy-MM-dd_HHmmss'))_NeoIPC-Surveillance-Validation-Report_${site}.${Locale}.pdf"
            $quartoArgs = @('render', $qmdFile, '--profile', $language, '-P', "departmentFilter:$($site)", '-o', $outFile)
            if ($ValidationExceptionFile) {
                $quartoArgs += @('-P', "validationExceptionFile:$ValidationExceptionFile")
            }
            if ($Dhis2Scheme) { $quartoArgs += @('-P', "dhis2Scheme:$Dhis2Scheme") }
            if ($Dhis2Hostname) { $quartoArgs += @('-P', "dhis2Hostname:$Dhis2Hostname") }
            if ($null -ne $Dhis2Port) { $quartoArgs += @('-P', "dhis2Port:$Dhis2Port") }
            if ($Dhis2Path) { $quartoArgs += @('-P', "dhis2Path:$Dhis2Path") }

            if ($PSCmdlet.ShouldProcess($outFile, "Render validation report for $site")) {
                Write-Host "Generating validation report for $site..."
                $result = Invoke-QuartoRender -Arguments $quartoArgs -Description "validation report for $site"
                if ($result.Status -eq 'Error') {
                    $errors += "Quarto render failed for $site."
                } elseif ($result.Status -ne 'NoData') {
                    $outputFiles += (Join-Path $outputDirPath $outFile)
                }
            }
        }
    }

    $buildCompleted = $true
}
catch {
    $errors += $_.Exception.Message
}
finally {
    Set-Location -LiteralPath $wd

    Write-Progress -Activity 'Validation Report Build' -Completed

    $buildReportPath = Join-Path $outputDirPath "${scriptTimestamp}_NeoIPC-Surveillance-Validation-Report-Build.json"
    $extraFields = [ordered]@{
        timestamp = $scriptTimestamp
        outputDir = $outputDirPath
        mode = if ($isCombined) { 'combined' } else { 'per-site' }
        sites = if ($isCombined) { $null } else { $sites }
        locale = $Locale
    }
    $reportPath = if ($JsonReport) { $buildReportPath } else { $null }
    $status = Write-NeoipcBuildReport -Name 'Validation Report Build' `
        -Errors $errors -OutputFiles $outputFiles -BuildCompleted $buildCompleted `
        -StartedAt $startedAt -BuildReportPath $reportPath -ExtraFields $extraFields

    if ($status -ne 'success') {
        exit 1
    }
}

} # end Invoke-WithNeoipcAuth
