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
        $cacheFile = Join-Path $PSScriptRoot '..' 'data' 'local' 'site-codes.txt'
        if (Test-Path -LiteralPath $cacheFile) {
            Get-Content -LiteralPath $cacheFile |
                Where-Object { $_ -like "$wordToComplete*" } |
                Sort-Object
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
    [string]$Token
)

. "$PSScriptRoot/NeoipcReportHelpers.ps1"

$auth = Resolve-NeoipcAuth -Token $Token

$reportDir = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..' 'reports' 'Validation-Report')

$sites = Get-NeoipcDepartments -Auth $auth -SiteCodeFilter $SiteCodeFilter

if (-not $sites -or $sites.Count -eq 0) {
    Write-Warning "No sites matched filter '$SiteCodeFilter'. Nothing to do."
    return
}

$wd = Get-Location
$originalEnv = @{}
foreach ($name in @('NEOIPC_DHIS2_TOKEN', 'NEOIPC_DHIS2_USER', 'NEOIPC_DHIS2_PASSWORD', 'NEOIPC_DHIS2_SESSION_ID')) {
    $originalEnv[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
foreach ($name in @('NEOIPC_DHIS2_TOKEN', 'NEOIPC_DHIS2_USER', 'NEOIPC_DHIS2_PASSWORD', 'NEOIPC_DHIS2_SESSION_ID')) {
    [Environment]::SetEnvironmentVariable($name, $null, 'Process')
}
if ($auth.AuthType -eq 'Token') {
    $env:NEOIPC_DHIS2_TOKEN = $auth.Token
} elseif ($auth.AuthType -eq 'Basic') {
    $env:NEOIPC_DHIS2_USER = $auth.Username
    $env:NEOIPC_DHIS2_PASSWORD = Get-NeoipcAuthPassword -Auth $auth
}
try {
    Set-Location -LiteralPath $reportDir

    foreach ($site in $sites) {
        Write-Host "Generating validation report for $site..."
        $outFile = "$([datetime]::Now.ToString('yyyy-MM-dd_HHmmss'))_NeoIPC-Surveillance-Validation-Report_$($site).$($Language).pdf"
        $skipRest = $false
        $errorLine = ''
        $isError = $false
        quarto render --profile $Language -P "language:$Language" -P "departmentFilter:$($site)" -o $outFile 2>&1 | ForEach-Object -Process {
            if ($skipRest) {
                return
            }
            $s = "$_"
            if ($s -eq 'System.Management.Automation.RemoteException') {
                $s = ''
            }
            if ($isError) {
                if ($s -eq '! No problem detected') {
                    Write-Host "No problem detected." -ForegroundColor DarkYellow
                    $skipRest = $true
                }
                else {
                    if ($errorLine.Length -gt 0) {
                        Write-Error -Message $errorLine
                        $errorLine = ''
                    }
                    Write-Error -Message $s
                }
            }
            elseif ($s -match '^(Error)|(Fehler)') {
                $isError = $true
                $errorLine = $s
            }
            elseif ($s -match "^(`e\[39m)?(`e\[33m)?WARNING") {
                $s | Write-Warning
            }
            else {
                $s | Write-Verbose
            }
        }
        if (-not $skipRest -and -not $isError) {
            Write-Host "done." -ForegroundColor Green
        }
    }
}
finally {
    Set-Location -LiteralPath $wd
    foreach ($name in $originalEnv.Keys) {
        $originalValue = $originalEnv[$name]
        if ($null -eq $originalValue) {
            [Environment]::SetEnvironmentVariable($name, $null, 'Process')
        } else {
            [Environment]::SetEnvironmentVariable($name, $originalValue, 'Process')
        }
    }
}
