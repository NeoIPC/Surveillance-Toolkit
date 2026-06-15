# Public NeoIPC metadata-pipeline cmdlets. The conversion is pure file processing (no DHIS2 API):
# a DHIS2 metadata.json on disk <-> a reviewable directory of one CSV per object type. The heavy
# lifting lives in Private/Metadata.ps1 (engine + orchestration) and Private/MetadataTypeMaps.ps1.

function ConvertFrom-NeoIPCMetadataJson {
    <#
    .SYNOPSIS
        Convert a DHIS2 metadata.json export into the reviewable per-type CSV directory.
    .DESCRIPTION
        Reads a (PII-cleaned) DHIS2 metadata JSON file, prunes per-instance noise, extracts nested-only
        child objects (programStageDataElements, programTrackedEntityAttributes, trackedEntityTypeAttributes,
        analyticsPeriodBoundaries) into their own tables, and writes one UTF-8/no-BOM/LF CSV per object type
        into OutputDirectory. Idempotent: replaces only the per-type files it owns. No DHIS2 API calls.
    .PARAMETER Path
        Path to the DHIS2 metadata.json export.
    .PARAMETER OutputDirectory
        Directory to write the per-type CSV files into (created if absent).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$OutputDirectory
    )
    if (-not (Test-Path -LiteralPath $Path)) { throw "Metadata file not found: '$Path'." }
    $package = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    $rows = ConvertFrom-NeoIPCMetadataPackage -Package $package
    if (-not (Test-Path -LiteralPath $OutputDirectory)) {
        if ($PSCmdlet.ShouldProcess($OutputDirectory, 'Create directory')) {
            New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
        }
    }
    foreach ($type in $rows.Keys) {
        $target = Join-Path $OutputDirectory "$type.csv"
        if ($PSCmdlet.ShouldProcess($target, 'Write CSV')) {
            Write-NeoIPCMetadataCsv -Path $target -Columns (Get-NeoIPCMetadataColumns -Type $type) -Rows $rows[$type]
        }
    }
}

function ConvertTo-NeoIPCMetadataJson {
    <#
    .SYNOPSIS
        Build the importable DHIS2 metadata JSON from the per-type CSV directory.
    .DESCRIPTION
        Reads the per-type CSV files, coerces cells back to typed values, re-nests nested-only children
        into their parents, and emits a DHIS2 metadata package as JSON (every id a valid UID — push with
        idScheme=UID). Returns the JSON string, or writes it to OutputPath (UTF-8, no BOM) when given.
    .PARAMETER Path
        Directory containing the per-type CSV files.
    .PARAMETER OutputPath
        Optional file to write the JSON to; if omitted the JSON string is returned.
    .PARAMETER Compress
        Emit compact JSON instead of indented.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$OutputPath,
        [switch]$Compress
    )
    if (-not (Test-Path -LiteralPath $Path)) { throw "Metadata directory not found: '$Path'." }
    $rows = [ordered]@{}
    foreach ($type in $script:NeoIPCMetadataTypeMaps.Keys) {
        $csv = Join-Path $Path "$type.csv"
        if (Test-Path -LiteralPath $csv) { $rows[$type] = Read-NeoIPCMetadataCsv -Path $csv }
    }
    $package = ConvertTo-NeoIPCMetadataPackage -Rows $rows
    $json = $package | ConvertTo-Json -Depth 100 -Compress:$Compress
    if ($OutputPath) {
        [System.IO.File]::WriteAllText($OutputPath, $json, [System.Text.UTF8Encoding]::new($false))
        return
    }
    $json
}

function Compare-NeoIPCMetadata {
    <#
    .SYNOPSIS
        Semantic diff between two DHIS2 metadata packages (modulo noise, deferred fields, excluded types).
    .DESCRIPTION
        Normalizes both sides (strip-list + deferred fields applied recursively), matches objects by id per
        type, and reports Added / Removed / Changed records. An empty result means the two packages are
        semantically equal. Each argument may be a metadata.json path or an already-parsed package hashtable.
    .PARAMETER Reference
        Reference package (path or parsed).
    .PARAMETER Difference
        Difference package (path or parsed).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Reference,
        [Parameter(Mandatory)]$Difference
    )
    $ref = if ($Reference -is [string]) { Get-Content -LiteralPath $Reference -Raw | ConvertFrom-Json -AsHashtable } else { $Reference }
    $dif = if ($Difference -is [string]) { Get-Content -LiteralPath $Difference -Raw | ConvertFrom-Json -AsHashtable } else { $Difference }
    Compare-NeoIPCMetadataCore -Reference $ref -Difference $dif
}

function Test-NeoIPCMetadataRoundTrip {
    <#
    .SYNOPSIS
        Verify a metadata.json round-trips faithfully through the CSV directory (the M1 acceptance gate).
    .DESCRIPTION
        Runs ConvertFrom-NeoIPCMetadataJson -> ConvertTo-NeoIPCMetadataJson and compares the rebuilt package
        against the original with Compare-NeoIPCMetadata. Returns the diff list; empty means a faithful
        round-trip (modulo the strip-list, deferred translations, and excluded/deferred types).
    .PARAMETER Path
        Path to the DHIS2 metadata.json export to verify.
    .PARAMETER WorkDirectory
        Optional directory for the intermediate CSVs (a temp directory is used if omitted).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$WorkDirectory
    )
    $dir = if ($WorkDirectory) { $WorkDirectory } else { Join-Path ([System.IO.Path]::GetTempPath()) ('neoipc-rt-' + [System.IO.Path]::GetRandomFileName()) }
    ConvertFrom-NeoIPCMetadataJson -Path $Path -OutputDirectory $dir
    $rebuilt = ConvertTo-NeoIPCMetadataJson -Path $dir | ConvertFrom-Json -AsHashtable
    $baseline = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    Compare-NeoIPCMetadataCore -Reference $baseline -Difference $rebuilt
}
