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

# Resolve the exception file against the caller's cwd before we Set-Location
# into the report dir; otherwise a relative path becomes report-dir-relative.
if ($ValidationExceptionFile) {
    $ValidationExceptionFile = (Resolve-Path -LiteralPath $ValidationExceptionFile -ErrorAction Stop).Path
}

$reportDir = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..' 'reports' 'Validation-Report')
$outputDirPath = Join-Path $reportDir '_output'
$timestamp = [datetime]::Now.ToString('yyyy-MM-dd_HHmmss')
$language = (Split-NeoipcLocale -Locale $Locale).Language

if (-not $Combined) {
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
try {
    Invoke-WithNeoipcAuth -Auth $auth -ScriptBlock {
        Set-Location -LiteralPath $reportDir

        $qmdFile = Resolve-NeoipcLocaleQmd -ReportDir $reportDir -BaseName 'Validation-Report' -Locale $Locale

        if ($Combined) {
            Write-Host "Generating combined validation report..."
            $outFile = "${timestamp}_NeoIPC-Surveillance-Validation-Report.${language}.pdf"
            $quartoArgs = @('render', $qmdFile, '--profile', $language, '-o', $outFile)
            if ($ValidationExceptionFile) {
                $quartoArgs += @('-P', "validationExceptionFile:$ValidationExceptionFile")
            }
            if ($Dhis2Scheme) { $quartoArgs += @('-P', "dhis2Scheme:$Dhis2Scheme") }
            if ($Dhis2Hostname) { $quartoArgs += @('-P', "dhis2Hostname:$Dhis2Hostname") }
            if ($null -ne $Dhis2Port) { $quartoArgs += @('-P', "dhis2Port:$Dhis2Port") }
            if ($Dhis2Path) { $quartoArgs += @('-P', "dhis2Path:$Dhis2Path") }
            $null = Invoke-QuartoRender -Arguments $quartoArgs -Description "combined validation report"
        } else {
            foreach ($site in $sites) {
                Write-Host "Generating validation report for $site..."
                $outFile = "${timestamp}_NeoIPC-Surveillance-Validation-Report_${site}.${language}.pdf"
                $quartoArgs = @('render', $qmdFile, '--profile', $language, '-P', "departmentFilter:$site", '-o', $outFile)
                if ($ValidationExceptionFile) {
                    $quartoArgs += @('-P', "validationExceptionFile:$ValidationExceptionFile")
                }
                if ($Dhis2Scheme) { $quartoArgs += @('-P', "dhis2Scheme:$Dhis2Scheme") }
                if ($Dhis2Hostname) { $quartoArgs += @('-P', "dhis2Hostname:$Dhis2Hostname") }
                if ($null -ne $Dhis2Port) { $quartoArgs += @('-P', "dhis2Port:$Dhis2Port") }
                if ($Dhis2Path) { $quartoArgs += @('-P', "dhis2Path:$Dhis2Path") }
                $null = Invoke-QuartoRender -Arguments $quartoArgs -Description "validation report for $site"
            }
        }
    }
}
finally {
    Set-Location -LiteralPath $wd
}
