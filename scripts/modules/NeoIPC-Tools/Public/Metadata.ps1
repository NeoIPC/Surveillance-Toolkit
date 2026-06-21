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
        into OutputDirectory. The two domain-authored option sets (NEOIPC_PATHOGENS, NEOIPC_ANTIMICROBIAL_SUBSTANCES)
        and their options are excluded — their canonical source is the infectious-agents YAML / the antibiotics CSV,
        and the importable package gets them from the export closure via New-NeoIPCMetadataPackage, not this
        directory. Idempotent: replaces only the per-type files it owns. No DHIS2 API calls.
    .PARAMETER Path
        Path to the DHIS2 metadata.json export.
    .PARAMETER OutputDirectory
        Directory to write the per-type CSV files into (created if absent). The named sharing profiles live
        here as sharing.yaml: an authored file is the source of truth (an unrecognized sharing shape then
        fails loud, to be named by hand); when absent, the profiles are derived from the package and written
        out, so the materialised directory is self-contained.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$OutputDirectory
    )
    if (-not (Test-Path -LiteralPath $Path)) { throw "Metadata file not found: '$Path'." }
    $package = ConvertFrom-NeoIPCMetadataJsonText -Json (Get-Content -LiteralPath $Path -Raw)
    $ugMap = Get-NeoIPCUserGroupKeyMap -UserGroups @($package['userGroups'])
    $sharingPath = Join-Path $OutputDirectory 'sharing.yaml'
    $writeSharing = -not (Test-Path -LiteralPath $sharingPath)
    if ($writeSharing) { Initialize-NeoIPCSharingProfileFromPackage -Package $package }
    else { Import-NeoIPCSharingProfile -Path $sharingPath -KeyToId $ugMap.KeyToId }
    $rows = ConvertFrom-NeoIPCMetadataPackage -Package $package
    if (-not (Test-Path -LiteralPath $OutputDirectory)) {
        if ($PSCmdlet.ShouldProcess($OutputDirectory, 'Create directory')) {
            New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
        }
    }
    if ($writeSharing -and $PSCmdlet.ShouldProcess($sharingPath, 'Write sharing profiles')) {
        Export-NeoIPCSharingProfile -Path $sharingPath -IdToKey $ugMap.IdToKey
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
        idScheme=UID). The output therefore omits the two domain-authored option sets the directory does not carry
        (NEOIPC_PATHOGENS, NEOIPC_ANTIMICROBIAL_SUBSTANCES); the complete importable package is assembled by
        New-NeoIPCMetadataPackage (closure + authored content), not by this round-trip cmdlet. Returns the JSON
        string, or writes it to OutputPath (UTF-8, no BOM) when given.
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
    $ugCsv = Join-Path $Path 'userGroups.csv'
    $ugObjs = if (Test-Path -LiteralPath $ugCsv) { @(Read-NeoIPCMetadataCsv -Path $ugCsv) } else { @() }
    Import-NeoIPCSharingProfile -Path (Join-Path $Path 'sharing.yaml') -KeyToId (Get-NeoIPCUserGroupKeyMap -UserGroups $ugObjs).KeyToId
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
    $ref = if ($Reference -is [string]) { ConvertFrom-NeoIPCMetadataJsonText -Json (Get-Content -LiteralPath $Reference -Raw) } else { $Reference }
    $dif = if ($Difference -is [string]) { ConvertFrom-NeoIPCMetadataJsonText -Json (Get-Content -LiteralPath $Difference -Raw) } else { $Difference }
    Compare-NeoIPCMetadataCore -Reference $ref -Difference $dif
}

function Test-NeoIPCMetadataRoundTrip {
    <#
    .SYNOPSIS
        Verify a metadata.json round-trips faithfully through the CSV directory.
    .DESCRIPTION
        Runs ConvertFrom-NeoIPCMetadataJson -> ConvertTo-NeoIPCMetadataJson and compares the rebuilt package
        against the original with Compare-NeoIPCMetadata. Returns the diff list; empty means a faithful
        round-trip (modulo the strip-list, deferred translations, and excluded/deferred types).
    .PARAMETER Path
        Path to the DHIS2 metadata.json export to verify.
    .PARAMETER WorkDirectory
        Optional directory for the intermediate CSVs (a temp directory is used if omitted). The intermediate
        directory is self-contained: emit derives and writes its sharing.yaml, which the read-back reads.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$WorkDirectory
    )
    $dir = if ($WorkDirectory) { $WorkDirectory } else { Join-Path ([System.IO.Path]::GetTempPath()) ('neoipc-rt-' + [System.IO.Path]::GetRandomFileName()) }
    ConvertFrom-NeoIPCMetadataJson -Path $Path -OutputDirectory $dir
    $rebuilt = ConvertFrom-NeoIPCMetadataJsonText -Json (ConvertTo-NeoIPCMetadataJson -Path $dir)
    $baseline = ConvertFrom-NeoIPCMetadataJsonText -Json (Get-Content -LiteralPath $Path -Raw)
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
    $base = ConvertFrom-NeoIPCMetadataJsonText -Json (Get-Content -LiteralPath $BasePath -Raw)
    $supplement = ConvertFrom-NeoIPCMetadataJsonText -Json (Get-Content -LiteralPath $SupplementPath -Raw)
    $merged = Merge-NeoIPCMetadataPackage -Base $base -Supplement $supplement -Types $Types
    $json = $merged | ConvertTo-Json -Depth 100 -Compress:$Compress
    if ($OutputPath) {
        [System.IO.File]::WriteAllText($OutputPath, $json, [System.Text.UTF8Encoding]::new($false))
        return
    }
    $json
}

function Test-NeoIPCMetadataExpression {
    <#
    .SYNOPSIS
        Lint the DHIS2 expressions in a metadata package for the issue classes a parser does not catch.
    .DESCRIPTION
        Walks every expression-bearing field (program-rule conditions, program-rule-action data, program-
        indicator expression/filter, validation-rule left/right sides) and applies three NeoIPC-specific
        rules. Returns finding objects (Rule, Severity, ObjectType, ObjectId, ObjectName, Field, Message,
        Expression); an empty result means nothing at or above MinimumSeverity. No DHIS2 API calls.

        Rules (all parse and validate clean in DHIS2, which is why they are linted here):
          - MixedBooleanPrecedence (Warning): a parenthesised group mixes && and || directly; && binds
            tighter than ||, so the grouping may not be what was intended.
          - NegativeSentinelComparison (Warning): an == / != comparison against -1 — for a yes/no or
            categorical data item this is almost always a typo.
          - LegacyD2FunctionArgForm (Info): a name-argument d2-function (d2:hasValue/count/countIfValue/
            countIfZeroPos/lastEventDate) uses the #/A/C/V{...} reference form instead of the canonical
            quoted name; Update-NeoIPCMetadata -Canonicalize rewrites it.
    .PARAMETER Path
        Path to a DHIS2 metadata export JSON to lint.
    .PARAMETER Package
        An already-parsed metadata package (hashtable) to lint, instead of -Path.
    .PARAMETER MinimumSeverity
        Lowest severity to return: Info (all, incl. the style findings), Warning (default — the likely
        bugs), or Error.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    [OutputType([System.Collections.Generic.List[object]])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path')][string]$Path,
        [Parameter(Mandatory, ParameterSetName = 'Package')]$Package,
        [ValidateSet('Info', 'Warning', 'Error')][string]$MinimumSeverity = 'Warning'
    )
    if ($PSCmdlet.ParameterSetName -eq 'Path') {
        if (-not (Test-Path -LiteralPath $Path)) { throw "Metadata file not found: '$Path'." }
        $pkg = ConvertFrom-NeoIPCMetadataJsonText -Json (Get-Content -LiteralPath $Path -Raw)
    }
    else { $pkg = $Package }
    # A PSCustomObject (e.g. ConvertFrom-Json WITHOUT -AsHashtable) silently yields $null for $pkg[$type], so
    # every collection would scan empty and the linter would report clean — fail loudly instead of mis-passing.
    if ($pkg -isnot [System.Collections.IDictionary]) {
        throw 'Package must be a dictionary/hashtable (parse the export with ConvertFrom-Json -AsHashtable).'
    }

    $rank = @{ Info = 0; Warning = 1; Error = 2 }
    $min = $rank[$MinimumSeverity]
    $findings = [System.Collections.Generic.List[object]]::new()
    foreach ($type in $script:NeoIPCMetadataExpressionFields.Keys) {
        foreach ($o in @($pkg[$type])) {
            if ($o -isnot [System.Collections.IDictionary]) { continue }
            $oid = [string]$o['id']
            $oname = [string]$o['name']
            foreach ($slot in (Get-NeoIPCMetadataExpressionSlot -Object $o -Type $type)) {
                foreach ($f in (Get-NeoIPCMetadataExpressionFinding -Expression $slot.Value -ObjectType $type -ObjectId $oid -ObjectName $oname -Field $slot.Path)) {
                    if ($rank[$f.Severity] -ge $min) { $findings.Add($f) }
                }
            }
        }
    }
    $byRule = $findings | Group-Object Rule | ForEach-Object { "$($_.Name)=$($_.Count)" }
    Write-Verbose ("Expression lint: {0} finding(s) at >= {1} ({2})." -f $findings.Count, $MinimumSeverity, ($byRule -join ', '))
    return $findings
}

function Update-NeoIPCMetadata {
    <#
    .SYNOPSIS
        Apply source transforms to a metadata package: canonicalize expressions and/or regenerate UIDs.
    .DESCRIPTION
        A deliberate, reviewable rewrite of the metadata source (distinct from the faithful round-trip). The
        input package is never mutated — a transformed copy is produced. No DHIS2 API calls.

        -Canonicalize rewrites the name-argument d2-functions (d2:hasValue/lastEventDate/count/countIfZeroPos/
        countIfValue) from the #/A/C/V{name} reference form to the quoted-name form ('name') — byte-for-byte
        the rewrite Tracker Capture's engine applies internally, making the source engine-version-independent.

        -RegenerateUids re-mints every owned object id (deterministically, salted by the old id) and rewrites
        every reference to it — structured {id} references AND expression-embedded UIDs (#{uid.uid}, I{uid}) —
        via one bounded-token pass. The org-unit family (non-closure deployment config), the excluded PII /
        server-generated types, the system default UIDs, and any reference to an object not present in the
        package all keep their UID. Useful for detaching a play/test package from the
        source instance's id space.

        At least one transform switch is required. By default the transformed package is emitted as JSON
        (returned, or written to OutputPath). With -PassThru the result object (Package + counts + UidMap) is
        returned instead.
    .PARAMETER Path
        Path to a DHIS2 metadata export JSON to transform.
    .PARAMETER Package
        An already-parsed metadata package (hashtable) to transform, instead of -Path.
    .PARAMETER Canonicalize
        Rewrite the name-argument d2-functions to the canonical quoted-name form.
    .PARAMETER RegenerateUids
        Re-mint every owned object id and rewrite all references consistently.
    .PARAMETER OutputPath
        Optional file to write the transformed JSON to (UTF-8, no BOM); if omitted the JSON string is
        returned (unless -PassThru is given).
    .PARAMETER Compress
        Emit compact JSON instead of indented.
    .PARAMETER PassThru
        Return the result object (Package + CanonicalizedSlots + RegeneratedUids + UidMap) instead of JSON.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    [OutputType([string], [hashtable])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path')][string]$Path,
        [Parameter(Mandatory, ParameterSetName = 'Package')]$Package,
        [switch]$Canonicalize,
        [switch]$RegenerateUids,
        [string]$OutputPath,
        [switch]$Compress,
        [switch]$PassThru
    )
    if (-not ($Canonicalize -or $RegenerateUids)) { throw 'Specify at least one transform: -Canonicalize and/or -RegenerateUids.' }
    if ($PSCmdlet.ParameterSetName -eq 'Path') {
        if (-not (Test-Path -LiteralPath $Path)) { throw "Metadata file not found: '$Path'." }
        $pkg = ConvertFrom-NeoIPCMetadataJsonText -Json (Get-Content -LiteralPath $Path -Raw)
    }
    else { $pkg = $Package }

    $result = Update-NeoIPCMetadataPackage -Package $pkg -Canonicalize:$Canonicalize -RegenerateUids:$RegenerateUids
    Write-Verbose ("Metadata transform: canonicalized {0} expression slot(s), regenerated {1} UID(s)." -f $result.CanonicalizedSlots, $result.RegeneratedUids)

    if ($OutputPath) {
        $json = $result.Package | ConvertTo-Json -Depth 100 -Compress:$Compress
        [System.IO.File]::WriteAllText($OutputPath, $json, [System.Text.UTF8Encoding]::new($false))
        if ($PassThru) { return $result }
        return
    }
    if ($PassThru) { return $result }
    $result.Package | ConvertTo-Json -Depth 100 -Compress:$Compress
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
        deployment-authored custom attributes. Two classes are never followed: the excluded PII / server-generated
        types (users, category option combos) and the non-closure org-unit family (org units, org-unit groups /
        group-sets, levels) — deployment config the program references only by code, converted and round-tripped
        elsewhere but never pulled into the program package. No DHIS2 API calls.

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
        $pkg = ConvertFrom-NeoIPCMetadataJsonText -Json (Get-Content -LiteralPath $Path -Raw)
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
        Write-Warning ("Structured reference {0} (on {1} {2}) targets a present type that is neither mapped, excluded, nor deferred — dropped. Map that type if NeoIPC adopts it." -f $s.Uid, $s.FromType, $s.FromId)
    }
    if (@($result.ExpressionUnresolved).Count -gt 0) {
        Write-Verbose ("{0} expression reference(s) resolve to non-indexed targets (excluded / non-closure / unmapped types): {1}" -f @($result.ExpressionUnresolved).Count, ((@($result.ExpressionUnresolved) | ForEach-Object { $_.Uid }) -join ', '))
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

function New-NeoIPCMetadataPackage {
    <#
    .SYNOPSIS
        Assemble an importable DHIS2 metadata package from an export plus the UID-keyed metadata directory.
    .DESCRIPTION
        The play / production package build. Starts from a (PII-cleaned, merged) DHIS2 export for the
        dependency-closure config, then overlays the authored content read from the canonical UID-keyed
        directory (push with idScheme=UID):
          1. Prunes the export to the seed program's dependency closure (the Select-NeoIPCMetadataClosure engine).
          2. Adds the non-closure config DEFINITIONS from the export — org-unit groups / group-sets / levels,
             userRoles, userGroups — with their real UIDs (the closure cannot reach these: the program
             references them only by code).
          3. Noise-strips the whole config: audit fields, user / sharing references, the anonymised
             per-deployment membership, and (for now) translations — leaving a clean, user-ref-free package.
          3b. Replaces the deployed generated classes (the NEOIPC_PATHOGENS option set + options, the per-slot
             pathogen / substance data elements, and the resistance / field-gating / substance program-rule
             variables + rules + actions) with the ontology- and matrix-generated ones (Add-NeoIPCGeneratedMetadata),
             so the package carries the corrected taxonomy and the rule-quality fixes — not the stale export
             snapshot. -SkipGeneration omits this step.
          4. Reads the org units, users, and group memberships from the UID-keyed directory — the `common`
             base plus the selected variant overlay — preserving the committed UIDs (real production UIDs for
             the live org units), and stitches them in group-side, collision-checking every authored UID
             against the captured identities (Join-NeoIPCMetadataPackage).
        The export's anonymised org-unit instances and user accounts are excluded; the directory content
        replaces them. By default the assembled package is emitted as JSON (returned, or written to
        OutputPath). Translations are dropped pending the gettext-PO pipeline. No DHIS2 API calls.
    .PARAMETER ExportPath
        Path to the merged, PII-cleaned DHIS2 export JSON (the closure seed + the non-closure definitions).
    .PARAMETER MetadataDirectory
        The canonical metadata directory root (contains common/ and play/). The base config is read from
        common/; the overlay from common/ + (play/ or the production OverlayPath).
    .PARAMETER Variant
        play (the committed synthetic overlay under MetadataDirectory/play) or production (an uncommittable
        real-data overlay supplied via OverlayPath). Both share the common base. Default: play.
    .PARAMETER OverlayPath
        For -Variant production: the uncommittable private directory of real org units / users / memberships
        (same file layout as play/). Ignored for -Variant play.
    .PARAMETER Password
        Login password for every authored user. Defaults to a clearly-test value that passes DHIS2's import
        password policy (the bare demo password 'district' is rejected — E4005 — for imported users).
    .PARAMETER SeedType
        Top-level type of the closure seed (default: programs).
    .PARAMETER SeedCode
        Code of the closure seed (default: NEOIPC_CORE).
    .PARAMETER PathogenCount
        Pathogen slots per applicable stage (1-9) for generation. Default: the module-wide count.
    .PARAMETER SubstanceCount
        Antimicrobial-substance slots (1-99) for generation. Default: the module-wide count.
    .PARAMETER SkipGeneration
        Skip the ontology / matrix generation step, emitting the config exactly as the export carries it — for
        tests and partial exports that lack the pathogen machinery the generators require. The canonical build
        leaves this off so the package is generated from the corrected ontology.
    .PARAMETER OutputPath
        Optional file to write the package JSON to (UTF-8, no BOM); if omitted the JSON string is returned
        (unless -PassThru).
    .PARAMETER Compress
        Emit compact JSON instead of indented.
    .PARAMETER PassThru
        Return the result object (Package + OrgUnitCount + UserCount) instead of JSON.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'Password',
        Justification = 'Forwards the synthetic play accounts'' known, clearly-test password to the authoring compiler — not a real secret.')]
    [CmdletBinding()]
    [OutputType([string], [hashtable])]
    param(
        [Parameter(Mandatory)][string]$ExportPath,
        [Parameter(Mandatory)][string]$MetadataDirectory,
        [ValidateSet('play', 'production')][string]$Variant = 'play',
        [string]$OverlayPath,
        [string]$Password = 'NeoIPC-Play1',
        [string]$SeedType = 'programs',
        [string]$SeedCode = 'NEOIPC_CORE',
        [ValidateRange(1, 9)][int]$PathogenCount = $script:NeoIPCPathogenSlotCount,
        [ValidateRange(1, 99)][int]$SubstanceCount = $script:NeoIPCSubstanceSlotCount,
        [switch]$SkipGeneration,
        [string]$OutputPath,
        [switch]$Compress,
        [switch]$PassThru
    )
    if (-not (Test-Path -LiteralPath $ExportPath)) { throw "Export metadata file not found: '$ExportPath'." }
    if (-not (Test-Path -LiteralPath $MetadataDirectory)) { throw "Metadata directory not found: '$MetadataDirectory'." }
    $commonDir = Join-Path $MetadataDirectory 'common'
    if (-not (Test-Path -LiteralPath $commonDir)) { throw "Common metadata directory not found: '$commonDir'." }
    $variantDir = if ($Variant -eq 'production') {
        if ([string]::IsNullOrEmpty($OverlayPath)) { throw '-Variant production requires -OverlayPath (the uncommittable real-data overlay).' }
        $OverlayPath
    }
    else { Join-Path $MetadataDirectory 'play' }
    if (-not (Test-Path -LiteralPath $variantDir)) { throw "Variant overlay directory not found: '$variantDir'." }

    $export = ConvertFrom-NeoIPCMetadataJsonText -Json (Get-Content -LiteralPath $ExportPath -Raw)

    # userRole NAME -> real UID, resolved before stripping (name and id both survive normalization anyway).
    $roleUid = @{}
    foreach ($r in @($export['userRoles'])) {
        if ($r -is [System.Collections.IDictionary] -and $r['name']) { $roleUid[[string]$r['name']] = [string]$r['id'] }
    }

    # Closure + the non-closure DEFINITION types (the whole non-closure family except org-unit instances,
    # which are read from the directory). Then noise-strip the config so the anonymised per-deployment
    # membership is gone BEFORE the authored membership is applied.
    $config = (Get-NeoIPCMetadataClosure -Package $export -SeedType $SeedType -SeedCode $SeedCode).Package
    foreach ($t in $script:NeoIPCMetadataNonClosureTypes) {
        if ($t -eq 'organisationUnits') { continue }
        if ($export.Contains($t)) { $config[$t] = $export[$t] }
    }
    $config = Remove-NeoIPCMetadataNoise -Object $config

    # Replace the deployed generated classes (pathogen option set + per-slot DEs, resistance / field-gating /
    # substance PRVs + rules + actions) with the ontology- and matrix-generated ones, so the package carries the
    # corrected taxonomy and the rule-quality fixes rather than the stale export snapshot. -SkipGeneration leaves
    # the config as-is — for tests / partial exports that lack the pathogen machinery the generators require.
    if (-not $SkipGeneration) {
        $config = Add-NeoIPCGeneratedMetadata -Config $config -Export $export -PathogenCount $PathogenCount -SubstanceCount $SubstanceCount
    }

    # Authored content from the UID-keyed directory: common base + variant overlay. Committed UIDs preserved.
    $orgUnits = Read-NeoIPCAuthoredOrgUnit -Path @((Join-Path $commonDir 'organisationUnits.csv'), (Join-Path $variantDir 'organisationUnits.csv'))
    $ouUid = @{}
    foreach ($o in $orgUnits) { $ouUid[[string]$o['code']] = [string]$o['id'] }

    $userArgs = @{
        UserPath              = (Join-Path $variantDir 'users.csv')
        RoleAssignmentPath    = (Join-Path $variantDir 'userRoleAssignments.csv')
        OrgUnitAssignmentPath = (Join-Path $variantDir 'userOrgUnitAssignments.csv')
        RoleUid               = $roleUid
        OrgUnitUid            = $ouUid
        Password              = $Password
    }
    $users = ConvertFrom-NeoIPCAuthoredUserCsv @userArgs

    # Org-unit-group membership: the common overlay (World-Bank class, reference centre) + the variant overlay
    # (test units / trial sites / all-eligible). Structural identity groups are derived from the org units.
    $ougPaths = @(@((Join-Path $commonDir 'organisationUnitGroupMemberships.csv'), (Join-Path $variantDir 'organisationUnitGroupMemberships.csv')) | Where-Object { Test-Path -LiteralPath $_ })
    $ougMembership = ConvertFrom-NeoIPCAuthoredOrgUnitGroupMembership -OrgUnit $orgUnits -MembershipPath $ougPaths

    $ugPath = Join-Path $variantDir 'userGroupMemberships.csv'
    $ugMembership = if (Test-Path -LiteralPath $ugPath) { ConvertFrom-NeoIPCAuthoredUserGroupMembership -MembershipPath $ugPath -User $users } else { [ordered]@{} }

    $package = Join-NeoIPCMetadataPackage -Config $config -OrgUnit $orgUnits -User $users -OrgUnitGroupMembership $ougMembership -UserGroupMembership $ugMembership
    Write-Verbose ("Assembled '{0}' package: {1} org units, {2} users, {3} top-level types." -f $Variant, @($orgUnits).Count, @($users).Count, @($package.Keys).Count)

    if ($PassThru) { return @{ Package = $package; OrgUnitCount = @($orgUnits).Count; UserCount = @($users).Count } }
    $json = $package | ConvertTo-Json -Depth 100 -Compress:$Compress
    if ($OutputPath) {
        [System.IO.File]::WriteAllText($OutputPath, $json, [System.Text.UTF8Encoding]::new($false))
        return
    }
    $json
}

function Export-NeoIPCMetadataTranslation {
    <#
    .SYNOPSIS
        Extract a metadata package's translatable strings to gettext PO (metadata.pot + per-locale metadata.<lang>.po).
    .DESCRIPTION
        Walks every translatable property of every object (name / shortName / description / formName /
        subjectTemplate / ...; the DHIS2 ObjectTranslation tokens verified against refs/dhis2-core) and writes a
        bilingual gettext PO component (msgid = English source, msgstr = translation) beside the reports'
        documentation / glossary PO:
          - metadata.pot — the English source template. msgctxt = <type>/<key>/<TOKEN> (key = optionSetCode/
            optionCode for options, else code — code-stable across UID regeneration and matching the legacy
            .<locale>.csv sidecars — else the object UID for code-less types like program rules / stages / sections,
            which is therefore NOT regeneration-stable), msgid = the English base value, msgstr empty.
          - metadata.<lang>.po — per language. An EXISTING .po is refreshed msgmerge-style (in code): the source
            msgid is updated, the translator's msgstr is preserved, an entry whose source changed is kept but
            marked fuzzy, and entries no longer in the source are dropped. A MISSING .po is created and seeded from
            the package's existing translations[] so nothing already translated in the export is lost.
        After the first export the .po files (Weblate) are the source of truth; Import-NeoIPCMetadataTranslation
        pushes them back onto a package. The two domain-authored option sets (NEOIPC_PATHOGENS,
        NEOIPC_ANTIMICROBIAL_SUBSTANCES) are excluded here as everywhere — their translations belong with the
        option generation from the canonical YAML / antibiotics CSV. No DHIS2 API calls.
    .PARAMETER Path
        Path to a DHIS2 metadata export JSON to extract from.
    .PARAMETER Package
        An already-parsed metadata package (hashtable) to extract from, instead of -Path.
    .PARAMETER PoDirectory
        Directory for metadata.pot + metadata.<lang>.po (created if absent).
    .PARAMETER Locale
        Languages to (re)generate. Default: the nine NeoIPC target languages.
    .PARAMETER Validate
        Run `msgfmt -c` on each generated .po (best-effort; via WSL on Windows; skipped if gettext is unavailable).
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Path')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path')][string]$Path,
        [Parameter(Mandatory, ParameterSetName = 'Package')]$Package,
        [Parameter(Mandatory)][string]$PoDirectory,
        [string[]]$Locale = $script:NeoIPCMetadataTranslationLocales,
        [switch]$Validate
    )
    if ($PSCmdlet.ParameterSetName -eq 'Path') {
        if (-not (Test-Path -LiteralPath $Path)) { throw "Metadata file not found: '$Path'." }
        $pkg = ConvertFrom-NeoIPCMetadataJsonText -Json (Get-Content -LiteralPath $Path -Raw)
    }
    else { $pkg = $Package }
    if ($pkg -isnot [System.Collections.IDictionary]) {
        throw 'Package must be a dictionary/hashtable (parse the export with ConvertFrom-Json -AsHashtable).'
    }
    if (-not (Test-Path -LiteralPath $PoDirectory)) {
        if ($PSCmdlet.ShouldProcess($PoDirectory, 'Create directory')) { New-Item -ItemType Directory -Path $PoDirectory -Force | Out-Null }
    }

    $units = Get-NeoIPCMetadataTranslationUnit -Package $pkg
    $potEntries = ConvertTo-NeoIPCMetadataPoEntry -Unit $units
    $potPath = Join-Path $PoDirectory 'metadata.pot'
    if ($PSCmdlet.ShouldProcess($potPath, 'Write POT')) {
        [System.IO.File]::WriteAllText($potPath, (Write-NeoIPCMetadataPoText -Entry $potEntries), [System.Text.UTF8Encoding]::new($false))
        if ($Validate -and -not (Test-NeoIPCMetadataPoSyntax -Path $potPath)) { throw "Generated $potPath failed msgfmt validation." }
    }
    Write-Verbose ("metadata.pot: {0} source string(s)." -f $potEntries.Count)

    foreach ($loc in $Locale) {
        $poPath = Join-Path $PoDirectory "metadata.$loc.po"
        if (Test-Path -LiteralPath $poPath) {
            $existing = Read-NeoIPCMetadataPoText -Text (Get-Content -LiteralPath $poPath -Raw)
            $entries = Merge-NeoIPCMetadataPoEntry -New $potEntries -Existing $existing
        }
        else {
            $entries = ConvertTo-NeoIPCMetadataPoEntry -Unit $units -Locale $loc
        }
        if ($PSCmdlet.ShouldProcess($poPath, 'Write PO')) {
            [System.IO.File]::WriteAllText($poPath, (Write-NeoIPCMetadataPoText -Entry $entries -Locale $loc), [System.Text.UTF8Encoding]::new($false))
            if ($Validate -and -not (Test-NeoIPCMetadataPoSyntax -Path $poPath)) { throw "Generated $poPath failed msgfmt validation." }
        }
        $translated = @($entries | Where-Object { -not $_.Fuzzy -and -not [string]::IsNullOrEmpty([string]$_.Msgstr) }).Count
        Write-Verbose ("metadata.{0}.po: {1}/{2} translated." -f $loc, $translated, $entries.Count)
    }
}

function Import-NeoIPCMetadataTranslation {
    <#
    .SYNOPSIS
        Apply per-language gettext PO translations onto a metadata package as translations[].
    .DESCRIPTION
        Reads metadata.<lang>.po from PoDirectory and injects each kept (non-fuzzy, non-empty) translation onto
        the matching object/property as a translations[] entry ({ property = <TOKEN>, locale, value }). Objects
        are matched by the same stable msgctxt the export uses; an object's translations[] is rebuilt entirely
        from the PO (deterministically ordered by locale then token), so the PO is the single source of truth.
        Fuzzy and empty entries are skipped. By default the package is emitted as JSON (returned, or written to
        OutputPath); with -PassThru the package hashtable is returned. No DHIS2 API calls.
    .PARAMETER Path
        Path to the DHIS2 metadata export JSON to inject translations into.
    .PARAMETER Package
        An already-parsed metadata package (hashtable) to inject into, instead of -Path.
    .PARAMETER PoDirectory
        Directory containing metadata.<lang>.po.
    .PARAMETER Locale
        Languages to apply. Default: the nine NeoIPC target languages (missing .po files are skipped).
    .PARAMETER OutputPath
        Optional file to write the JSON to (UTF-8, no BOM); if omitted the JSON string is returned (unless -PassThru).
    .PARAMETER Compress
        Emit compact JSON instead of indented.
    .PARAMETER PassThru
        Return the package hashtable instead of JSON.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    [OutputType([string], [hashtable])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path')][string]$Path,
        [Parameter(Mandatory, ParameterSetName = 'Package')]$Package,
        [Parameter(Mandatory)][string]$PoDirectory,
        [string[]]$Locale = $script:NeoIPCMetadataTranslationLocales,
        [string]$OutputPath,
        [switch]$Compress,
        [switch]$PassThru
    )
    if ($PSCmdlet.ParameterSetName -eq 'Path') {
        if (-not (Test-Path -LiteralPath $Path)) { throw "Metadata file not found: '$Path'." }
        $pkg = ConvertFrom-NeoIPCMetadataJsonText -Json (Get-Content -LiteralPath $Path -Raw)
    }
    else { $pkg = $Package }
    if ($pkg -isnot [System.Collections.IDictionary]) {
        throw 'Package must be a dictionary/hashtable (parse the export with ConvertFrom-Json -AsHashtable).'
    }
    if (-not (Test-Path -LiteralPath $PoDirectory)) { throw "PO directory not found: '$PoDirectory'." }

    $poByLocale = @{}
    foreach ($loc in $Locale) {
        $poPath = Join-Path $PoDirectory "metadata.$loc.po"
        if (Test-Path -LiteralPath $poPath) {
            $poByLocale[$loc] = Read-NeoIPCMetadataPoText -Text (Get-Content -LiteralPath $poPath -Raw)
        }
    }
    Write-Verbose ("Applying translations from {0} PO file(s): {1}." -f $poByLocale.Count, (@($poByLocale.Keys | Sort-Object) -join ', '))
    $result = Add-NeoIPCMetadataTranslationToPackage -Package $pkg -PoByLocale $poByLocale

    if ($PassThru) { return $result }
    $json = $result | ConvertTo-Json -Depth 100 -Compress:$Compress
    if ($OutputPath) {
        [System.IO.File]::WriteAllText($OutputPath, $json, [System.Text.UTF8Encoding]::new($false))
        return
    }
    $json
}
