#!/usr/bin/env pwsh
#requires -Version 7.6

<#
.SYNOPSIS
    Render the NeoIPC metadata package artefacts (CI build artifact / Release asset) from the canonical metadata
    directory.
.DESCRIPTION
    Produces the two distributable packages under metadata/dist/ so others can install NeoIPC without running the
    pipeline:
      * the install base  — the NEOIPC_CORE tracker program and all of its configuration dependencies (data
        elements, the generated option sets, program rules / variables, tracked-entity type + attributes, analytics
        groups, user groups and roles), with NO org-unit hierarchy and NO users; and
      * the play package  — the install base plus the committed synthetic play overlay (test hospitals / departments
        and synthetic test users), for local / test instances.
    Each is assembled by New-NeoIPCMetadataPackage from the directory ALONE (no seed export) and emitted compressed
    (single-line) with a top-level `package` manifest, whose `deployment` entry says how to deploy the package and
    why a plain metadata import is no substitute.

    ALPHA: this is a pre-standards artefact. The manifest is minimal and the package does NOT yet follow the WHO
    dhis2-package-exporter sharing / manifest conventions (which depend on a user-group / role / permission model
    that is still being designed), so the packages are not catalogue-grade. DHIS2's importer ignores the `package`
    key, and Deploy-NeoIPCMetadata leaves it out: deploy the packages with Deploy-NeoIPCMetadata, since a plain
    metadata import is no substitute (the manifest's `deployment` entry says why). The artefacts are GENERATED: do
    not hand-edit them; edit the metadata directory (or this script's manifest values) and re-run this script. No
    DHIS2 API calls.
.PARAMETER OutputDirectory
    Where to write the package files. Defaults to the repository's metadata/dist directory.
.PARAMETER Version
    Package version written into the manifest + filename. REQUIRED — no default, so the version is always an explicit
    caller decision (the script never silently picks one). CI passes the metadata release version on a metadata-v*
    release build (the tag is the released version), else the `metadata/VERSION` file — the source of truth for the
    metadata product version.
.PARAMETER Password
    Login password set on every synthetic play user (forwarded to New-NeoIPCMetadataPackage for the play variant).
    Defaults to the module's clearly-test value; never a real secret.
.EXAMPLE
    ./scripts/Build-NeoIPCMetadataDistribution.ps1 -Version (Get-Content ./metadata/VERSION -Raw).Trim()
    Render both package artefacts into metadata/dist/ at the metadata product's current version.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'Password',
    Justification = 'Forwards the synthetic play accounts'' known, clearly-test password — not a real secret.')]
[CmdletBinding()]
param(
    [string]$OutputDirectory,
    [Parameter(Mandatory)][string]$Version,
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
# compose file), which doubles as the lowest release the packages are actually exercised against. It names a
# verified release rather than the lowest that could theoretically work: 2.40.3.2 carries a confirmed defect
# fixed in 2.40.4, and no release below 2.40.12.0 is tested, so the stamp follows what is tested.
# The version is the required -Version param (no default — the caller always decides): CI passes the
# metadata release version on a metadata-v* release build, else the metadata/VERSION file (the metadata product's
# source of truth).
# healthArea tagging, DHIS2Build and the WHO sharing/group conventions are deferred to the standards-package design
# task — kept minimal here on purpose.
$packageCode = 'NEOIPC_CORE'
$packageType = 'TRK'
$packageVersion = $Version
$dhis2Version = '2.40.12.0'
$locale = 'en'

function New-AlphaManifest([string]$NameSuffix, [string]$Description, [string]$Deployment) {
    # The name FOLLOWS the WHO dhis2-package-exporter format {code}_{type}_{version}_DHIS{dhis2Version}-{locale}.
    # NameSuffix is a NeoIPC-local variant marker (e.g. '_play') appended after the locale — the WHO format has no
    # variant field, so this is a deliberate local extension to tell the two alpha packages apart. `deployment` is
    # another: the manifest is the one place in the file DHIS2 ignores, so it is where the package itself says how
    # it is deployed, first in the file for anyone who opens it.
    $name = "${packageCode}_${packageType}_${packageVersion}_DHIS${dhis2Version}-${locale}${NameSuffix}"
    [ordered]@{
        name         = $name
        code         = $packageCode
        description  = $Description
        type         = $packageType
        version      = $packageVersion
        DHIS2Version = $dhis2Version
        locale       = $locale
        deployment   = $Deployment
    }
}

$installDescription = 'NeoIPC Core surveillance tracker program and its configuration dependencies (data elements, ' +
    'generated option sets, program rules and variables, tracked-entity type and attributes, analytics groups, user ' +
    'groups and roles). Install base: no org-unit hierarchy and no users. ALPHA / pre-standards: not yet conformant ' +
    'to the WHO dhis2-package-exporter sharing and manifest conventions.'
$playDescription = 'NeoIPC Core surveillance package plus a synthetic play / demo overlay (one test hospital and ' +
    'department per country, and synthetic test users). For local and test instances only — contains no real data. ' +
    'ALPHA / pre-standards.'
$deployment = 'Deploy with Deploy-NeoIPCMetadata from NeoIPC-Tools (https://github.com/NeoIPC/Surveillance-Toolkit), ' +
    'a dry run first. A plain metadata import, through the Import/Export app or a POST to /api/metadata, is no ' +
    'substitute: in one request, DHIS2 can link an option group set to none of its groups while reporting success; ' +
    'repeated over an existing instance, the import fails whole from DHIS2 2.42 on; and on an instance in use, it ' +
    'clears what the package does not carry, such as the program''s organisation units and the members of every ' +
    'org-unit group and user group. Why, and how to deploy to production: ' +
    'https://github.com/NeoIPC/Surveillance-Toolkit/blob/main/docs/metadata-deployment.md'
$playDeployment = $deployment + ' This play package carries synthetic users: deploy it with -SyntheticInstance, and ' +
    'only to a test instance.'

$installPath = Join-Path $OutputDirectory "${packageCode}_${packageType}_${packageVersion}_DHIS${dhis2Version}-${locale}.json"
$playPath = Join-Path $OutputDirectory "${packageCode}_${packageType}_${packageVersion}_DHIS${dhis2Version}-${locale}.play.json"

# Regenerate the ontology- / capability-matrix-driven families (per-slot pathogen + substance data elements, the
# resistance / field-gating / virus / substance program-rule variables, rules and actions) into metadata/common/
# BEFORE rendering, so every build ships the current generators and drift between the generators and the committed
# metadata/common/ tree surfaces as a reviewable git diff. The writer rewrites every CSV there in one deterministic
# form, so a drift-free tree comes out byte-identical and git sees no change (regeneration is idempotent); a dirty
# tree after a build means the committed metadata is stale, or was hand-edited in another form, and must be
# committed. CI's build-metadata job fails on it.
#
# LIMIT: the directory writer is ADDITIVE — it writes/overwrites files for the objects currently generated but does NOT
# delete the externalized expression files (or prune the CSV rows) of a generated object that regeneration DROPS or
# RENAMES (e.g. lowering the slot count, or an ontology change that removes/renames a rule). Such a removal surfaces
# only as the CSV-row change; its now-orphaned expressions/<rule>/*.dhis2 files linger as unchanged tracked files that
# git status does not flag, so they must be deleted by hand. So the automatic drift-as-git-diff guarantee covers
# ADDITIONS and CONTENT changes, not REMOVALS/RENAMES. See Update-NeoIPCGeneratedMetadataDirectory.
Write-Host 'Regenerating the ontology / capability-matrix families into metadata/common/ (drift check)...'
Update-NeoIPCGeneratedMetadataDirectory -MetadataDirectory $metadataDir -Confirm:$false

Write-Host 'Rendering the install-base package (no org units / users)...'
$installManifest = New-AlphaManifest -NameSuffix '' -Description $installDescription -Deployment $deployment
New-NeoIPCMetadataPackage -MetadataDirectory $metadataDir -Manifest $installManifest -Compress -OutputPath $installPath
Write-Host ("  -> {0} ({1:N0} bytes)" -f $installPath, (Get-Item -LiteralPath $installPath).Length)

Write-Host 'Rendering the play package (synthetic test hospitals / departments / users)...'
$playManifest = New-AlphaManifest -NameSuffix '_play' -Description $playDescription -Deployment $playDeployment
New-NeoIPCMetadataPackage -MetadataDirectory $metadataDir -Play -Password $Password -Manifest $playManifest -Compress `
    -OutputPath $playPath
Write-Host ("  -> {0} ({1:N0} bytes)" -f $playPath, (Get-Item -LiteralPath $playPath).Length)
