#requires -Version 7.6
<#
.SYNOPSIS
    Render the NeoIPC Core data-dictionary release artifact (CSV + .xlsx) from the canonical metadata.
.DESCRIPTION
    Produces a technology-agnostic data dictionary that sits between the DHIS2 metadata JSON and the end-user
    protocol: it documents everything the NeoIPC Core program collects — patient attributes, per-event data
    elements, the event dates, and every code list in full (including the pathogen and antimicrobial lists).
    Four sheets are produced (About, Variables, Code lists, Forms & dates) as one CSV per sheet and, by
    default, as the tabs of a single .xlsx workbook.

    The data dictionary is a GENERATED release artifact (distributed alongside the protocol and metadata
    releases), not source — the output is written to the gitignored artifacts/ tree and is not committed.

    The package is assembled from the metadata/ directory alone (New-NeoIPCMetadataPackage, export-free, no
    DHIS2 API). The CSVs need only PowerShell; the .xlsx needs the DocumentFormat.OpenXml assembly. Provision
    it once with `Invoke-Workspace.ps1 -InstallDeps` (workspace) or, standalone, with:

        dotnet publish scripts/modules/NeoIPC-Tools/lib -o scripts/modules/NeoIPC-Tools/lib/bin

    See docs/data-dictionary.md.
.PARAMETER OutputDirectory
    Where to write the artifacts. Defaults to the repository's (gitignored) artifacts/data-dictionary directory.
.PARAMETER Format
    Csv, Xlsx, or Both (default). Xlsx/Both require the provisioned DocumentFormat.OpenXml assembly.
.EXAMPLE
    ./scripts/New-NeoIPCDataDictionary.ps1
    Generate the CSV + .xlsx data dictionary into artifacts/data-dictionary/.
.EXAMPLE
    ./scripts/New-NeoIPCDataDictionary.ps1 -Format Csv
    Generate only the dependency-free CSV sheets.
#>
[CmdletBinding()]
param(
    [string]$OutputDirectory,
    [ValidateSet('Csv', 'Xlsx', 'Both')][string]$Format = 'Both'
)
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$module = Join-Path $repoRoot 'scripts/modules/NeoIPC-Tools/NeoIPC-Tools.psd1'
$metadataDir = Join-Path $repoRoot 'metadata'
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repoRoot 'artifacts/data-dictionary' }
Import-Module $module -Force
if (-not (Test-Path -LiteralPath $OutputDirectory)) { New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null }

Write-Host "Rendering the NeoIPC Core data dictionary ($Format) from $metadataDir ..."
$paths = Export-NeoIPCDataDictionary -MetadataDirectory $metadataDir -OutputDirectory $OutputDirectory -Format $Format
foreach ($path in $paths) {
    Write-Host ("  -> {0} ({1:N0} bytes)" -f $path, (Get-Item -LiteralPath $path).Length)
}
