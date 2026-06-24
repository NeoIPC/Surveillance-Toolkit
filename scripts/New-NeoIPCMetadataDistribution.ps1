#requires -Version 7.5
<#
.SYNOPSIS
    Render the committed, importable NeoIPC metadata package artifacts from the canonical metadata directory.
.DESCRIPTION
    Produces the two distributable packages under metadata/dist/ so others can install NeoIPC without running the
    pipeline:
      * the install base  — the NEOIPC_CORE tracker program and all of its configuration dependencies (data
        elements, the generated option sets, program rules / variables, tracked-entity type + attributes, analytics
        groups, user groups and roles), with NO org-unit hierarchy and NO users; and
      * the play package  — the install base plus the committed synthetic play overlay (test hospitals / departments
        and synthetic test users), for local / test instances.
    Each is assembled by New-NeoIPCMetadataPackage from the directory ALONE (no seed export) and emitted compressed
    (single-line) with a top-level `package` manifest.

    ALPHA: this is a pre-standards artifact. The manifest is minimal and the package does NOT yet follow the WHO
    dhis2-package-exporter sharing / manifest conventions (which depend on a user-group / role / permission model
    that is still being designed). The packages import as-is — DHIS2's importer ignores the unrecognised `package`
    key — but they are not catalogue-grade. The artifacts are GENERATED: do not hand-edit them; edit the metadata
    directory (or this script's manifest values) and re-run this script. No DHIS2 API calls.
.PARAMETER OutputDirectory
    Where to write the package files. Defaults to the repository's metadata/dist directory.
.PARAMETER Password
    Login password set on every synthetic play user (forwarded to New-NeoIPCMetadataPackage for the play variant).
    Defaults to the module's clearly-test value; never a real secret.
.EXAMPLE
    ./scripts/New-NeoIPCMetadataDistribution.ps1
    Regenerate both committed package artifacts in metadata/dist/.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'Password',
    Justification = 'Forwards the synthetic play accounts'' known, clearly-test password — not a real secret.')]
[CmdletBinding()]
param(
    [string]$OutputDirectory,
    [string]$Password = 'NeoIPC-Play1'
)
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$module = Join-Path $repoRoot 'scripts/modules/NeoIPC-Tools/NeoIPC-Tools.psd1'
$metadataDir = Join-Path $repoRoot 'metadata'
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $metadataDir 'dist' }
Import-Module $module -Force
if (-not (Test-Path -LiteralPath $OutputDirectory)) { New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null }

# --- Alpha manifest policy (the values; the module only provides the mechanism) -------------------------------------
# DHIS2Version is pinned to the NeoIPC DHIS2 deployment version (the dhis2/core image tag in the deployment's
# compose file). Versioning, healthArea tagging, DHIS2Build and the WHO sharing/group conventions are deferred to
# the standards-package design task — kept minimal here on purpose.
$packageCode = 'NEOIPC_CORE'
$packageType = 'TRK'
$packageVersion = '0.1.0-alpha'
$dhis2Version = '2.40.3.2'
$locale = 'en'

function New-AlphaManifest([string]$NameSuffix, [string]$Description) {
    # The name FOLLOWS the WHO dhis2-package-exporter format {code}_{type}_{version}_DHIS{dhis2Version}-{locale}.
    # NameSuffix is a NeoIPC-local variant marker (e.g. '_play') appended after the locale — the WHO format has no
    # variant field, so this is a deliberate local extension to tell the two alpha packages apart.
    $name = "${packageCode}_${packageType}_${packageVersion}_DHIS${dhis2Version}-${locale}${NameSuffix}"
    [ordered]@{
        name         = $name
        code         = $packageCode
        description  = $Description
        type         = $packageType
        version      = $packageVersion
        DHIS2Version = $dhis2Version
        locale       = $locale
    }
}

$installDescription = 'NeoIPC Core surveillance tracker program and its configuration dependencies (data elements, ' +
    'generated option sets, program rules and variables, tracked-entity type and attributes, analytics groups, user ' +
    'groups and roles). Install base: no org-unit hierarchy and no users. ALPHA / pre-standards: not yet conformant ' +
    'to the WHO dhis2-package-exporter sharing and manifest conventions.'
$playDescription = 'NeoIPC Core surveillance package plus a synthetic play / demo overlay (one test hospital and ' +
    'department per country, and synthetic test users). For local and test instances only — contains no real data. ' +
    'ALPHA / pre-standards.'

$installPath = Join-Path $OutputDirectory "${packageCode}_${packageType}_${packageVersion}_DHIS${dhis2Version}-${locale}.json"
$playPath = Join-Path $OutputDirectory "${packageCode}_${packageType}_${packageVersion}_DHIS${dhis2Version}-${locale}.play.json"

Write-Host 'Rendering the install-base package (no org units / users)...'
New-NeoIPCMetadataPackage -MetadataDirectory $metadataDir -Manifest (New-AlphaManifest '' $installDescription) `
    -Compress -OutputPath $installPath
Write-Host ("  -> {0} ({1:N0} bytes)" -f $installPath, (Get-Item -LiteralPath $installPath).Length)

Write-Host 'Rendering the play package (synthetic test hospitals / departments / users)...'
New-NeoIPCMetadataPackage -MetadataDirectory $metadataDir -Play -Password $Password `
    -Manifest (New-AlphaManifest '_play' $playDescription) -Compress -OutputPath $playPath
Write-Host ("  -> {0} ({1:N0} bytes)" -f $playPath, (Get-Item -LiteralPath $playPath).Length)
