<#
.SYNOPSIS
Update the local site code cache for tab completion.

.DESCRIPTION
Fetches all NeoIPC department codes from DHIS2 and writes them to a local
cache file. This cache is used by ArgumentCompleters in the report scripts
to provide tab completion for -SiteCodeFilter and -DepartmentCode parameters.

.PARAMETER Token
Optional token string or path to a file containing the token.
If omitted, uses environment variable or prompts for credentials.

.EXAMPLE
.\Update-NeoipcSiteCache.ps1 -Token $myToken
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Token
)

. "$PSScriptRoot/NeoipcReportHelpers.ps1"

$auth = Resolve-NeoipcAuth -Token $Token
$sites = Get-NeoipcDepartments -Auth $auth

$cacheDir = Join-Path $PSScriptRoot '..' 'data' 'local'
if (-not (Test-Path -LiteralPath $cacheDir)) {
    New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
}
$cachePath = Join-Path $cacheDir 'site-codes.txt'
$sites | Set-Content -LiteralPath $cachePath -Encoding UTF8

Write-Host "Cached $($sites.Count) site codes to $cachePath" -ForegroundColor Green
