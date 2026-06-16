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

function Merge-NeoIPCMetadataJson {
    <#
    .SYNOPSIS
        Build the canonical pipeline input by splicing selected types from a supplement export into a base export.
    .DESCRIPTION
        DHIS2 cannot export everything in one file: the full /api/metadata export omits program notification
        templates (ProgramNotificationTemplate is not a metadata-export type), while a program dependency
        export (/api/programs/{id}/metadata) includes them but drops analytics groups, attributes, and
        expression-only data elements. This merges them: the full export is the BASE, and only the named
        Types (default: programNotificationTemplates) are taken from the supplement. No DHIS2 API calls.
    .PARAMETER BasePath
        Path to the full metadata export JSON (the base — the most complete export).
    .PARAMETER SupplementPath
        Path to the supplement export JSON (e.g. the program dependency export carrying the templates).
    .PARAMETER Types
        Top-level type names to take from the supplement (default: programNotificationTemplates).
    .PARAMETER OutputPath
        Optional file to write the merged JSON to (UTF-8, no BOM); if omitted the JSON string is returned.
    .PARAMETER Compress
        Emit compact JSON instead of indented.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$BasePath,
        [Parameter(Mandatory)][string]$SupplementPath,
        [string[]]$Types = @('programNotificationTemplates'),
        [string]$OutputPath,
        [switch]$Compress
    )
    if (-not (Test-Path -LiteralPath $BasePath)) { throw "Base metadata file not found: '$BasePath'." }
    if (-not (Test-Path -LiteralPath $SupplementPath)) { throw "Supplement metadata file not found: '$SupplementPath'." }
    $base = Get-Content -LiteralPath $BasePath -Raw | ConvertFrom-Json -AsHashtable
    $supplement = Get-Content -LiteralPath $SupplementPath -Raw | ConvertFrom-Json -AsHashtable
    $merged = Merge-NeoIPCMetadataPackage -Base $base -Supplement $supplement -Types $Types
    $json = $merged | ConvertTo-Json -Depth 100 -Compress:$Compress
    if ($OutputPath) {
        [System.IO.File]::WriteAllText($OutputPath, $json, [System.Text.UTF8Encoding]::new($false))
        return
    }
    $json
}

function Select-NeoIPCMetadataClosure {
    <#
    .SYNOPSIS
        Prune a DHIS2 metadata export to the dependency closure of the NEOIPC_CORE program.
    .DESCRIPTION
        Computes the transitive closure of everything a seed program needs and drops the rest — the
        deterministic, Node-free replacement for DHIS2's own dependency export (which silently drops
        expression-embedded references because it never parses expression text). The closure follows
        structured {id} references at any depth, bare-string UID references (e.g. a SEND_MESSAGE action's
        templateUid), reverse-by-program / -stage edges (program rules / variables / indicators that point
        AT the program), and a grammar-complete expression-UID safety net that proves no expression-embedded
        reference was dropped. It also recovers NeoIPC metadata the program does not reference: grouping
        objects whose members intersect the closure (ATC / AWaRe option groups, data-element groups) and the
        deployment-authored custom attributes. Stop-types (users, org units, category option combos, org-unit
        groups) are never followed — they are import-time overlays. No DHIS2 API calls.

        By default the pruned package is emitted as JSON (returned, or written to OutputPath). The closure
        diagnostics are always written to the verbose / warning streams and, with -PassThru, returned as an
        object: ExpressionMisses (expression references the structured walk missed — the DHIS2-export bug,
        expected 0 for NeoIPC; recovered by the safety net), ExpressionUnresolved (expression references to
        non-indexed targets — overlays / unmapped types), and DanglingStringRefs (bare-string UID references
        such as a templateUid with no matching object in the package).
    .PARAMETER Path
        Path to the DHIS2 metadata export JSON to prune (e.g. the Merge-NeoIPCMetadataJson output).
    .PARAMETER Package
        An already-parsed metadata package (ordered hashtable) to prune, instead of -Path.
    .PARAMETER SeedType
        Top-level type of the seed object (default: programs).
    .PARAMETER SeedCode
        Code of the seed object within SeedType (default: NEOIPC_CORE).
    .PARAMETER OutputPath
        Optional file to write the pruned JSON to (UTF-8, no BOM); if omitted the JSON string is returned
        (unless -PassThru is given).
    .PARAMETER Compress
        Emit compact JSON instead of indented.
    .PARAMETER PassThru
        Return the closure result object (Package + diagnostics) instead of the pruned JSON.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    [OutputType([string], [hashtable])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path')][string]$Path,
        [Parameter(Mandatory, ParameterSetName = 'Package')]$Package,
        [string]$SeedType = 'programs',
        [string]$SeedCode = 'NEOIPC_CORE',
        [string]$OutputPath,
        [switch]$Compress,
        [switch]$PassThru
    )
    if ($PSCmdlet.ParameterSetName -eq 'Path') {
        if (-not (Test-Path -LiteralPath $Path)) { throw "Metadata file not found: '$Path'." }
        $pkg = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    }
    else { $pkg = $Package }

    $result = Get-NeoIPCMetadataClosure -Package $pkg -SeedType $SeedType -SeedCode $SeedCode

    Write-Verbose ("Closure seeded at {0} ({1}/{2}): indexed {3}, included {4}." -f $result.SeedId, $SeedType, $SeedCode, $result.IndexedCount, $result.IncludedCount)
    foreach ($m in $result.ExpressionMisses) {
        Write-Warning ("Expression reference recovered by the safety net (the structured walk missed it): {0} [{1}] -> {2}, first seen on {3}." -f $m.Uid, $m.Form, $m.TargetType, $m.FirstSeenOn)
    }
    foreach ($d in $result.DanglingStringRefs) {
        Write-Warning ("Dangling {0} reference {1} (on {2} {3}) has no target in the package." -f $d.Field, $d.Uid, $d.FromType, $d.FromId)
    }
    foreach ($s in $result.StructuredUnresolved) {
        Write-Warning ("Structured reference {0} (on {1} {2}) targets a type that is neither mapped nor an excluded overlay — dropped. Map that type if NeoIPC adopts it." -f $s.Uid, $s.FromType, $s.FromId)
    }
    if (@($result.ExpressionUnresolved).Count -gt 0) {
        Write-Verbose ("{0} expression reference(s) resolve to non-indexed targets (stop-type overlays / unmapped types): {1}" -f @($result.ExpressionUnresolved).Count, ((@($result.ExpressionUnresolved) | ForEach-Object { $_.Uid }) -join ', '))
    }

    if ($OutputPath) {
        $json = $result.Package | ConvertTo-Json -Depth 100 -Compress:$Compress
        [System.IO.File]::WriteAllText($OutputPath, $json, [System.Text.UTF8Encoding]::new($false))
        if ($PassThru) { return $result }
        return
    }
    if ($PassThru) { return $result }
    $result.Package | ConvertTo-Json -Depth 100 -Compress:$Compress
}
