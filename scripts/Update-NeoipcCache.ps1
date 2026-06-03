<#
.SYNOPSIS
Refresh local NeoIPC tab-completion caches.

.DESCRIPTION
Single entry point for every tab-completion cache the NeoIPC-Tools module
reads. Caches are partitioned by server URL so different DHIS2 instances
maintain separate state.

Cache files (under `data/<server-key>/`):

- `site-codes.txt`  — NEOIPC department codes for `-OrgUnitCode` completers.
- `de-codes.txt`    — data-element codes for `Read-EventInfo -DataElementCode`.

.PARAMETER Sites
Refresh the site-codes cache.

.PARAMETER DataElements
Refresh the data-element-codes cache.

.PARAMETER Token
Optional token string or path to a file containing the token. If omitted,
uses environment variable or prompts for credentials.

.EXAMPLE
.\Update-NeoipcCache.ps1                      # default: refresh everything
.\Update-NeoipcCache.ps1 -Sites               # only site codes
.\Update-NeoipcCache.ps1 -DataElements        # only DE codes
.\Update-NeoipcCache.ps1 -Dhis2Hostname neoipc-demo.charite.de
#>
[CmdletBinding()]
param(
    [Parameter()]
    [switch]$Sites,

    [Parameter()]
    [switch]$DataElements,

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

Import-Module (Join-Path $PSScriptRoot 'modules' 'NeoIPC-Tools') -Force -Verbose:$false

# Default: refresh all caches
if (-not $Sites -and -not $DataElements) {
    $Sites = $true
    $DataElements = $true
}

$auth = Resolve-NeoipcAuth -Token $Token

$connArgs = @{ Auth = $auth }
if ($Dhis2Scheme)   { $connArgs.Scheme   = $Dhis2Scheme }
if ($Dhis2Hostname) { $connArgs.Hostname = $Dhis2Hostname }
if ($Dhis2Port)     { $connArgs.Port     = $Dhis2Port }
# -Dhis2Path is used only for cache-key partitioning (Get-NeoipcServerKey
# above); the readers hardcode 'api/<endpoint>' paths.

$serverKey = Get-NeoipcServerKey -Scheme $Dhis2Scheme -Hostname $Dhis2Hostname -Port $Dhis2Port -Path $Dhis2Path
$cacheDir = Join-Path $PSScriptRoot '..' 'data' $serverKey
if (-not (Test-Path -LiteralPath $cacheDir)) {
    New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
}

if ($Sites) {
    $siteList = Get-NeoipcDepartments @connArgs
    $sitePath = Join-Path $cacheDir 'site-codes.txt'
    $siteList | Set-Content -LiteralPath $sitePath -Encoding UTF8
    Write-Host "Cached $($siteList.Count) site codes to $sitePath" -ForegroundColor Green
}

if ($DataElements) {
    $deCodes = Get-NeoipcDataElementCodes @connArgs
    $dePath = Join-Path $cacheDir 'de-codes.txt'
    $deCodes | Set-Content -LiteralPath $dePath -Encoding UTF8
    Write-Host "Cached $($deCodes.Count) DE codes to $dePath" -ForegroundColor Green
}
