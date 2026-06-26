# Public surface for the NeoIPC data-dictionary generator. Flattens the assembled DHIS2 metadata package
# into a technology-agnostic spreadsheet (CSV + optional multi-tab XLSX). The transforms live in
# Private/DataDictionary.ps1; this file is the cmdlet wiring only. No DHIS2 API calls.

function Export-NeoIPCDataDictionary {
    <#
    .SYNOPSIS
        Generate the NeoIPC Core data-dictionary spreadsheet (CSV + optional XLSX) from the canonical metadata.
    .DESCRIPTION
        Produces a technology-agnostic data dictionary that sits between the DHIS2 metadata JSON and the
        end-user protocol: it documents everything the NeoIPC Core surveillance program collects — patient
        attributes, per-event data elements, the event dates (admission / infection /
        surveillance-end), and every code list (option set) in full, including the large pathogen and
        antimicrobial lists. The wording avoids DHIS2 jargon (program stage -> module/form, value type -> data
        type, option set -> code list, compulsory -> required) so it reads for both epidemiologists and
        technical implementers.

        Four sheets are produced (one CSV per sheet, named <BaseName>-<sheet>.csv, and/or all four as tabs of a
        single .xlsx): About, Variables, Code lists, and Forms & dates. Output is deterministic and
        locale-independent so a re-run is byte-identical (the CSVs; the XLSX is best-effort).

        The source is the COMPLETE assembled package (-MetadataDirectory, the default — built export-free from
        the metadata/ directory by New-NeoIPCMetadataPackage, so the pathogen/antimicrobial option domains are
        present), or an already-assembled package supplied via -Package.

        XLSX output needs the DocumentFormat.OpenXml assembly (provisioned with `dotnet`; see
        Invoke-Workspace.ps1 -InstallDeps). When XLSX is requested but the assembly is unavailable the cmdlet
        fails up front with an actionable message; CSV output needs nothing beyond PowerShell. No DHIS2 API calls.
    .PARAMETER MetadataDirectory
        The canonical metadata/ directory; the package is assembled from it (production install base). Default source.
    .PARAMETER Package
        An already-assembled package (an [ordered] dictionary: type -> object[]) to document instead of assembling one.
    .PARAMETER OutputDirectory
        Directory to write the artifacts into (created if absent).
    .PARAMETER Format
        Csv, Xlsx, or Both (default). Xlsx/Both require the DocumentFormat.OpenXml assembly.
    .PARAMETER BaseName
        File-name stem for the artifacts (default 'NeoIPC-Core-Data-Dictionary').
    .OUTPUTS
        The paths written.
    .EXAMPLE
        Export-NeoIPCDataDictionary -MetadataDirectory ./metadata -OutputDirectory ./artifacts/data-dictionary
        Assemble the package from the directory and write the CSVs + the .xlsx workbook.
    .EXAMPLE
        Export-NeoIPCDataDictionary -MetadataDirectory ./metadata -OutputDirectory ./out -Format Csv
        Write only the dependency-free CSV sheets.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Directory')]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Directory')][string]$MetadataDirectory,
        [Parameter(Mandatory, ParameterSetName = 'Package')][System.Collections.IDictionary]$Package,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [ValidateSet('Csv', 'Xlsx', 'Both')][string]$Format = 'Both',
        [string]$BaseName = 'NeoIPC-Core-Data-Dictionary'
    )

    $wantXlsx = $Format -eq 'Xlsx' -or $Format -eq 'Both'
    $wantCsv = $Format -eq 'Csv' -or $Format -eq 'Both'

    # Fail fast: don't assemble or write anything if XLSX is requested but its dependency is missing.
    if ($wantXlsx) { Assert-NeoIPCOpenXmlAvailable }

    $pkg = if ($PSCmdlet.ParameterSetName -eq 'Package') {
        $Package
    }
    else {
        if (-not (Test-Path -LiteralPath $MetadataDirectory)) { throw "Metadata directory not found: '$MetadataDirectory'." }
        (New-NeoIPCMetadataPackage -MetadataDirectory $MetadataDirectory -PassThru).Package
    }

    $sheets = Get-NeoIPCDataDictionaryRow -Package $pkg

    if (-not (Test-Path -LiteralPath $OutputDirectory)) { New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null }

    $written = [System.Collections.Generic.List[string]]::new()
    if ($wantCsv) {
        foreach ($p in (Write-NeoIPCDataDictionaryCsv -Sheet $sheets -OutputDirectory $OutputDirectory -BaseName $BaseName)) { $written.Add($p) }
    }
    if ($wantXlsx) {
        $written.Add((Write-NeoIPCDataDictionaryXlsx -Sheet $sheets -Path (Join-Path $OutputDirectory ("$BaseName.xlsx"))))
    }
    return $written.ToArray()
}
