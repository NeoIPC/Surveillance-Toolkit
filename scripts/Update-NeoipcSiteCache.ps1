<#
.SYNOPSIS
Update the local site code cache for tab completion.

.DESCRIPTION
Fetches all NeoIPC department codes from DHIS2 and writes them to a local
cache file. This cache is used by ArgumentCompleters in the report scripts
to provide tab completion for -SiteCodeFilter and -DepartmentCode parameters.

The cache is partitioned by server URL so that different DHIS2 instances
maintain separate site code lists.

.PARAMETER Token
Optional token string or path to a file containing the token.
If omitted, uses environment variable or prompts for credentials.

.EXAMPLE
.\Update-NeoipcSiteCache.ps1
.\Update-NeoipcSiteCache.ps1 -Dhis2Hostname neoipc-demo.charite.de
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Token,

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

$deptArgs = @{ Auth = $auth }
if ($Dhis2Scheme) { $deptArgs.Scheme = $Dhis2Scheme }
if ($Dhis2Hostname) { $deptArgs.Hostname = $Dhis2Hostname }
if ($null -ne $Dhis2Port) { $deptArgs.Port = $Dhis2Port }
if ($Dhis2Path) { $deptArgs.Path = $Dhis2Path }
$sites = Get-NeoipcDepartments @deptArgs

$serverKey = Get-NeoipcServerKey -Scheme $Dhis2Scheme -Hostname $Dhis2Hostname -Port $Dhis2Port -Path $Dhis2Path
$cacheDir = Join-Path $PSScriptRoot '..' 'data' 'local' $serverKey
if (-not (Test-Path -LiteralPath $cacheDir)) {
    New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
}
$cachePath = Join-Path $cacheDir 'site-codes.txt'
$sites | Set-Content -LiteralPath $cachePath -Encoding UTF8

Write-Host "Cached $($sites.Count) site codes to $cachePath" -ForegroundColor Green
