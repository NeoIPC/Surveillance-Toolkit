<#
.SYNOPSIS
Batch-generate Validation Reports for one or more sites.

.DESCRIPTION
This script fetches the department/site list from DHIS2, filters by a regex, and renders the Validation Report for each site using Quarto.

.EXAMPLE
    .\New-ValidationReports.ps1 -SiteCodeFilter 'NEO_AT.*' -Language 'de' -Token $myToken -Verbose
#>
[CmdletBinding()]
param(
    [ArgumentCompleter({
        param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
        . "$PSScriptRoot/NeoipcReportHelpers.ps1"
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
    [Parameter(Position = 0)]
    [string]$SiteCodeFilter = '.+',

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
    [string]$Language = 'en',

    [Parameter(Position = 2)]
    [string]$Token,

    [string]$ValidationExceptionFile,

    [Parameter()]
    [string]$Dhis2Scheme = $null,

    [Parameter()]
    [string]$Dhis2Hostname = $null,

    [Parameter()]
    [Nullable[int]]$Dhis2Port = $null,

    [Parameter()]
    [string]$Dhis2Path = $null
)

. "$PSScriptRoot/NeoipcReportHelpers.ps1"

$auth = Resolve-NeoipcAuth -Token $Token

# Resolve the exception file against the caller's cwd before we Set-Location
# into the report dir; otherwise a relative path becomes report-dir-relative.
if ($ValidationExceptionFile) {
    $ValidationExceptionFile = (Resolve-Path -LiteralPath $ValidationExceptionFile -ErrorAction Stop).Path
}

$reportDir = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..' 'reports' 'Validation-Report')

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

$wd = Get-Location
try {
    Invoke-WithNeoipcAuth -Auth $auth -ScriptBlock {
        Set-Location -LiteralPath $reportDir

        foreach ($site in $sites) {
            Write-Host "Generating validation report for $site..."
            $outFile = "$([datetime]::Now.ToString('yyyy-MM-dd_HHmmss'))_NeoIPC-Surveillance-Validation-Report_$($site).$($Language).pdf"
            $qmdFile = Resolve-NeoipcLocaleQmd -ReportDir $reportDir -BaseName 'Validation-Report' -Language $Language
            $quartoArgs = @('render', $qmdFile, '--profile', $Language, '-P', "departmentFilter:$($site)", '-o', $outFile)
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
finally {
    Set-Location -LiteralPath $wd
}
