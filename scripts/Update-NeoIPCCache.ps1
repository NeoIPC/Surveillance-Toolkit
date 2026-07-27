#!/usr/bin/env pwsh
#Requires -Version 7.6

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
.\Update-NeoIPCCache.ps1                      # default: refresh everything
.\Update-NeoIPCCache.ps1 -Sites               # only site codes
.\Update-NeoIPCCache.ps1 -DataElements        # only DE codes
.\Update-NeoIPCCache.ps1 -Dhis2Hostname neoipc-demo.charite.de
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

$auth = Resolve-NeoIPCAuth -Token $Token

$connArgs = @{ Auth = $auth }
if ($Dhis2Scheme)   { $connArgs.Scheme   = $Dhis2Scheme }
if ($Dhis2Hostname) { $connArgs.Hostname = $Dhis2Hostname }
if ($Dhis2Port)     { $connArgs.Port     = $Dhis2Port }
# -Dhis2Path is used only for cache-key partitioning (Get-NeoIPCServerKey
# above); the readers hardcode 'api/<endpoint>' paths.

$serverKey = Get-NeoIPCServerKey -Scheme $Dhis2Scheme -Hostname $Dhis2Hostname -Port $Dhis2Port -Path $Dhis2Path
$cacheDir = Join-Path $PSScriptRoot '..' 'data' $serverKey
if (-not (Test-Path -LiteralPath $cacheDir)) {
    New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
}

if ($Sites) {
    $siteList = Get-NeoIPCDepartments @connArgs
    $sitePath = Join-Path $cacheDir 'site-codes.txt'
    # Set-Content joins with [Environment]::NewLine. These cache files are not committed, but they are
    # read back by other tooling, so they follow the same LF contract as everything else.
    [System.IO.File]::WriteAllText(
        $sitePath, (($siteList -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
    Write-Host "Cached $($siteList.Count) site codes to $sitePath" -ForegroundColor Green
}

if ($DataElements) {
    $deCodes = Get-NeoIPCDataElementCodes @connArgs
    $dePath = Join-Path $cacheDir 'de-codes.txt'
    [System.IO.File]::WriteAllText(
        $dePath, (($deCodes -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
    Write-Host "Cached $($deCodes.Count) DE codes to $dePath" -ForegroundColor Green
}
