# Public reconcile cmdlet: ingest a fresh DHIS2 export and bring the canonical metadata/ directory into line with
# the DELIBERATE, IN-SCOPE changes made in DHIS2 — as reviewable, minimal git diffs — WITHOUT (a) re-importing
# out-of-scope junk, (b) reverting directory edits not yet deployed, or (c) corrupting content the directory owns
# differently than the export carries it (the authored org units / users, the ontology-generated families, the
# domain YAML). The directory is canonical; the export is an INPUT, not the truth.
#
# THE governing invariant is SCOPE: reconcile only ever operates on the NeoIPC scope (the NEOIPC_CORE dependency
# closure plus the non-closure config definitions), NEVER the raw full export. The raw export is parsed solely to
# be reduced to that scope (Get-NeoIPCMetadataScopedConfig) — the thousands of foreign objects a shared DHIS2
# instance carries from other programs, plus deployment junk (orphan options, AAA_OLD_DELETE artifacts), are simply
# never in scope: not compared, not translated, not reported, never written. Report-only unless -Apply. No DHIS2
# API calls.

function Assert-NeoIPCReconcileGitClean {
    # -Apply's safety net IS git: review the writes with `git diff`, revert with `git restore` (+ `git clean` for
    # newly-added files). So -Apply REFUSES unless every target path is (a) inside a git working tree and (b) clean
    # (no uncommitted changes under it) — otherwise reconcile's writes would mix with pre-existing edits and the diff
    # would not be a reviewable, revertable unit. No .bkp files; git is the backup. Report-only mode needs none of this.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Path)
    if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
        throw "-Apply needs git as its safety net, but 'git' was not found on PATH. Run report-only, or install git."
    }
    foreach ($p in $Path) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        $inside = (& git -C $p rev-parse --is-inside-work-tree 2>$null)
        if ($LASTEXITCODE -ne 0 -or "$inside".Trim() -ne 'true') {
            throw "-Apply needs a git-tracked metadata directory as its safety net: '$p' is not inside a git working tree. Put it under git first (then review with 'git diff', revert with 'git restore')."
        }
        $dirty = @(& git -C $p status --porcelain -- . 2>$null | Where-Object { $_ -ne '' })
        if ($LASTEXITCODE -ne 0) { throw "Could not read git status for '$p'." }
        if ($dirty.Count -gt 0) {
            throw ("-Apply needs a CLEAN metadata directory as its safety net: '$p' has {0} uncommitted change(s). Commit or stash them first, so reconcile's writes land as an isolated, reviewable git diff." -f $dirty.Count)
        }
    }
}

function Update-NeoIPCMetadataDirectory {
    <#
    .SYNOPSIS
        Reconcile the canonical metadata directory against a fresh DHIS2 export (report-only unless -Apply).
    .DESCRIPTION
        The reverse path. Reduces the fresh export to the NeoIPC SCOPE (Get-NeoIPCMetadataScopedConfig: the
        NEOIPC_CORE closure + the non-closure config definitions, noise-stripped — the SAME scope
        New-NeoIPCMetadataPackage builds its config from and the directory was materialised at), diffs the
        directory's current package against THAT scoped package, and classifies the drift by who OWNS each object.
        No code path ever sees the raw full export, so the foreign objects and deployment junk a shared DHIS2
        instance carries are invisible — not a single out-of-scope object is compared, translated, reported or
        written.

          - AUTO-WRITE (CSV-owned config), only with -Apply: every Changed / Added object the scoped core diff
            surfaces (Compare-NeoIPCMetadataCore already skips the generated families, the domain option sets, and
            the excluded / deferred / default-UID objects on both sides, so the diff is exactly the hand-maintained
            config drift). The affected per-type CSVs are ROW-MERGED by id: the directory's current rows are the
            base; Changed rows are replaced and Added rows inserted from the incoming; every other row — INCLUDING
            Removed — is kept verbatim. Re-sorted + re-emitted deterministically, so the git diff is minimal.

          - REMOVED -> report-only, NEVER auto-deleted. A directory object absent from the deployed export may be
            config authored in the directory but not yet deployed, not a real deletion — deleting from the canonical
            source is the one dangerous direction, so it is reported and left for a deliberate manual edit.

          - REPORT-ONLY, authored: organisationUnits and users are excluded types the comparator already skips
            (org-unit instances carry the real authored production UIDs / ISO codes the export only anonymises;
            users is PII) — listed here as defense-in-depth and so the report names them if they ever surface.
            Without a -SupplementPath the program notification templates (absent from a plain /api/metadata export)
            are treated the same way, so a missing template set does not diff as a spurious removal.

          - REPORT-ONLY, generated / domain: the ontology- and matrix-generated families and the domain option
            sets / antibiotic groups are routed by Compare-NeoIPCGeneratedMetadata's classification (run against the
            SAME scoped package — the deployed generated families live inside the closure, so the scoped diff equals
            the raw-export diff). Reconcile never reverse-writes a generated object as hand-authored; the developer
            edits the ontology YAML / capability matrix / antibiotics CSV and regenerates. A 'HandAuthoredAction'
            class flags a hand-authored action riding a generated rule (e.g. the BSI no-positive-culture HIDEFIELD)
            that the directory should represent as a stand-alone rule. An 'Unclassified' generated delta is surfaced
            loudly (warning) — an unexpected change to investigate, never silently written.

          - PO (with -Apply + -PoDirectory): the translation catalogue is refreshed from the SCOPED package (NOT the
            raw export), msgmerge-style (msgstrs preserved, changed sources fuzzed, obsolete entries dropped).

        -APPLY SAFETY. -Apply refreshes the directory and PO in place, so it is guarded twice:
          - git-or-refuse + clean-or-refuse: the directory (and the PO directory, if given) must be inside a git
            working tree AND clean. git is the backup — review with `git diff`, revert with `git restore`.
          - post-migration warning: the generated diff collapses toward zero once the deployed system is migrated to
            the corrected families; while it is still large the deployed export carries STALE family strings, so an
            -Apply (especially the PO refresh) would import them. Reconcile warns (but proceeds — report-only is
            always safe, and the git net covers it).

        Returns a structured drift report; review the working-tree diff with git after -Apply. No DHIS2 API calls.
    .PARAMETER ExportPath
        Path to a fresh (PII-cleaned) DHIS2 metadata.json export to reconcile the directory against.
    .PARAMETER MetadataDirectory
        The canonical metadata directory holding the per-type CSVs (e.g. metadata/common).
    .PARAMETER SupplementPath
        Optional program dependency export carrying the program notification templates (a plain /api/metadata
        export omits them). When given, the templates are spliced into the incoming package (Merge-NeoIPCMetadataJson)
        and reconciled; when omitted, programNotificationTemplates is reported, not auto-written.
    .PARAMETER PoDirectory
        Optional directory of the gettext PO catalogue (po/). When given with -Apply, the catalogue is refreshed
        from the SCOPED package. When omitted, the PO is left untouched (and the report notes it was skipped).
    .PARAMETER Apply
        Write the reconciled changes (row-merge the affected CSVs + refresh the PO). Without it, the cmdlet only
        reports the drift and changes nothing. Requires a git-tracked, clean directory.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$ExportPath,
        [Parameter(Mandatory)][string]$MetadataDirectory,
        [string]$SupplementPath,
        [string]$PoDirectory,
        [switch]$Apply
    )
    if (-not (Test-Path -LiteralPath $ExportPath)) { throw "Export not found: '$ExportPath'." }
    if (-not (Test-Path -LiteralPath $MetadataDirectory)) { throw "Metadata directory not found: '$MetadataDirectory'." }

    # Report-only-by-source guard set: types that must never be auto-written even if they surface in the core diff.
    # organisationUnits + users are EXCLUDED types the comparator already skips (org-unit instances are authored real
    # UIDs the export only anonymises; users is PII) — kept here as defense-in-depth and to label them in the report.
    # programNotificationTemplates joins them when the incoming lacks them (a plain /api/metadata export omits them),
    # so a missing template set is reported, not auto-written as a spurious removal.
    $authoredTypes = [System.Collections.Generic.HashSet[string]]::new([string[]]@('organisationUnits', 'users'), [System.StringComparer]::Ordinal)

    # The generated diff collapses toward 0 once the deployment is migrated to the corrected families; pre-migration
    # it is in the thousands. A threshold well above the post-migration residual but far below the pre-migration
    # count flags "not yet migrated" so -Apply can warn before importing stale deployed strings.
    $migrationDriftWarnThreshold = 100

    $hasSupplement = -not [string]::IsNullOrEmpty($SupplementPath)

    # 1. Ingest: optional notification-template splice, then everything downstream reduces $sourcePath to the SCOPE.
    $tempMerged = $null
    if ($hasSupplement) {
        if (-not (Test-Path -LiteralPath $SupplementPath)) { throw "Supplement not found: '$SupplementPath'." }
        $tempMerged = Join-Path ([System.IO.Path]::GetTempPath()) ('neoipc-reconcile-' + [System.IO.Path]::GetRandomFileName() + '.json')
        Merge-NeoIPCMetadataJson -BasePath $ExportPath -SupplementPath $SupplementPath -OutputPath $tempMerged
        $sourcePath = $tempMerged
    }
    else {
        $sourcePath = $ExportPath
    }
    try {
        # Program notification templates are absent from a plain /api/metadata export; reconcile them only when the
        # incoming actually carries them — otherwise report-only, so they do not diff as spurious removals. This is a
        # cheap non-mutating probe of the raw export; the diffs below use the SCOPED package, never this parse.
        $probe = ConvertFrom-NeoIPCMetadataJsonText -Json (Get-Content -LiteralPath $sourcePath -Raw)
        $probeTpl = $probe['programNotificationTemplates']   # $null when absent; @($null).Count is 1, so test null first
        if ($null -eq $probeTpl -or @($probeTpl).Count -eq 0) { [void]$authoredTypes.Add('programNotificationTemplates') }

        # 2. CONFIG diff — the directory's current package vs the SCOPED incoming (closure + non-closure defs,
        #    noise-stripped). NEVER the raw export. Get-NeoIPCMetadataScopedConfig mutates its package in place, so
        #    each consumer gets its OWN fresh -ExportPath scope.
        $coreDeltas = @(Compare-NeoIPCMetadataCore `
                -Reference (ConvertFrom-NeoIPCMetadataJsonText -Json (ConvertTo-NeoIPCMetadataJson -Path $MetadataDirectory)) `
                -Difference (Get-NeoIPCMetadataScopedConfig -ExportPath $sourcePath))

        # 3. Partition: authored types are reported, not written. Of the rest, Changed / Added auto-write; Removed is
        #    report-only (never auto-deleted from the canonical source).
        $autoDeltas = @($coreDeltas | Where-Object { -not $authoredTypes.Contains([string]$_.Type) })
        $authoredHit = @($coreDeltas | Where-Object { $authoredTypes.Contains([string]$_.Type) } | ForEach-Object { [string]$_.Type } | Sort-Object -Unique)
        $autoWriteDeltas = @($autoDeltas | Where-Object { $_.Kind -eq 'Changed' -or $_.Kind -eq 'Added' })
        $removedDeltas = @($autoDeltas | Where-Object { $_.Kind -eq 'Removed' })

        # 4. Generated / domain drift — report-only, routed by class, against the SAME scoped package (the deployed
        #    generated families are in the closure, so the scoped diff equals the raw-export diff). The cmdlet returns
        #    its deltas as ONE protected collection (unary-comma return), so capture it first and THEN enumerate —
        #    @(<call>) would wrap the whole list in a 1-element array.
        $genResult = Compare-NeoIPCGeneratedMetadata -ExistingPackage (Get-NeoIPCMetadataScopedConfig -ExportPath $sourcePath)
        $genDeltas = @($genResult)
        $unclassified = @($genDeltas | Where-Object { [string]$_.Class -eq 'Unclassified' })

        $byType = {
            param($deltas)
            @($deltas | Group-Object Type | ForEach-Object {
                    [pscustomobject]@{
                        Type    = $_.Name
                        Added   = @($_.Group | Where-Object { $_.Kind -eq 'Added' }).Count
                        Changed = @($_.Group | Where-Object { $_.Kind -eq 'Changed' }).Count
                        Removed = @($_.Group | Where-Object { $_.Kind -eq 'Removed' }).Count
                    }
                })
        }

        $affectedTypes = @($autoWriteDeltas | ForEach-Object { [string]$_.Type } | Sort-Object -Unique)
        $poUpdated = $false

        # 5. Apply: row-merge the affected CSV-owned types + refresh the PO. Guarded by the post-migration warning
        #    and the git/clean safety net.
        if ($Apply) {
            if ($genDeltas.Count -gt $migrationDriftWarnThreshold) {
                Write-Warning ("Deployed metadata not yet migrated to the corrected generated families ({0} generated deltas) — -Apply will import the stale deployed family strings (option / rule / data-element names) into the directory and PO. Proceed only once the deployment has been migrated; otherwise run report-only." -f $genDeltas.Count)
            }
            $poDirs = if ($PoDirectory) { @($MetadataDirectory, $PoDirectory) } else { @($MetadataDirectory) }
            Assert-NeoIPCReconcileGitClean -Path $poDirs

            if ($affectedTypes.Count -gt 0 -and $PSCmdlet.ShouldProcess($MetadataDirectory, ("row-merge {0} affected type CSV(s): {1}" -f $affectedTypes.Count, ($affectedTypes -join ', ')))) {
                # Emit the SCOPED incoming to a temp dir (seeded with the committed sharing.yaml so the re-emitted
                # rows keep their AUTHORED sharing keys), then row-merge per affected type. ConvertFrom takes a JSON
                # FILE, so the scoped package is written to a temp file first.
                $scopedJson = Join-Path ([System.IO.Path]::GetTempPath()) ('neoipc-reconcile-scoped-' + [System.IO.Path]::GetRandomFileName() + '.json')
                [System.IO.File]::WriteAllText($scopedJson, ((Get-NeoIPCMetadataScopedConfig -ExportPath $sourcePath) | ConvertTo-Json -Depth 100), [System.Text.UTF8Encoding]::new($false))
                $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('neoipc-reconcile-emit-' + [System.IO.Path]::GetRandomFileName())
                New-Item -ItemType Directory -Path $tmp -Force | Out-Null
                try {
                    $sharingSrc = Join-Path $MetadataDirectory 'sharing.yaml'
                    if (Test-Path -LiteralPath $sharingSrc) { Copy-Item -LiteralPath $sharingSrc -Destination (Join-Path $tmp 'sharing.yaml') -Force }
                    ConvertFrom-NeoIPCMetadataJson -Path $scopedJson -OutputDirectory $tmp

                    foreach ($t in $affectedTypes) {
                        $dstCsv = Join-Path $MetadataDirectory "$t.csv"
                        $srcCsv = Join-Path $tmp "$t.csv"
                        $dirRows = if (Test-Path -LiteralPath $dstCsv) { @(Read-NeoIPCMetadataCsv -Path $dstCsv) } else { @() }
                        $srcRows = if (Test-Path -LiteralPath $srcCsv) { @(Read-NeoIPCMetadataCsv -Path $srcCsv) } else { @() }
                        $srcById = @{}
                        foreach ($r in $srcRows) { $srcById[[string]$r['id']] = $r }

                        # Base = the directory's current rows (so every untouched row, incl. Removed, is KEPT verbatim);
                        # then apply this type's Changed (replace) + Added (insert) from the incoming.
                        $merged = [ordered]@{}
                        foreach ($r in $dirRows) { $merged[[string]$r['id']] = $r }
                        foreach ($d in @($autoWriteDeltas | Where-Object { [string]$_.Type -eq $t })) {
                            $id = [string]$d.Id
                            if ($srcById.ContainsKey($id)) { $merged[$id] = $srcById[$id] }
                        }

                        $rows = [object[]]@($merged.Values)
                        $keys = [string[]]@(foreach ($r in $rows) { Get-NeoIPCMetadataRowSortKey -Type $t -Row $r })
                        $sorted = Get-NeoIPCMetadataSortedRowSet -Row $rows -Key $keys
                        Write-NeoIPCMetadataCsv -Path $dstCsv -Columns (Get-NeoIPCMetadataColumns -Type $t) -Rows $sorted

                        # Externalised expressions: copy ONLY the Changed / Added rows' files (delete-then-copy of a
                        # whole subtree would drop Removed rows' expressions — they must be kept). The cell already
                        # holds the relative ref (expressions/...dhis2), which encodes the co-location — a program-rule
                        # ACTION's data file lives under its owning rule's folder — so copying by ref path is correct.
                        foreach ($d in @($autoWriteDeltas | Where-Object { [string]$_.Type -eq $t })) {
                            $id = [string]$d.Id
                            if (-not $srcById.ContainsKey($id)) { continue }
                            foreach ($cell in $srcById[$id].Values) {
                                $ref = [string]$cell
                                if (-not $script:NeoIPCMetadataExpressionRefPattern.IsMatch($ref)) { continue }
                                $srcExpr = Join-Path $tmp $ref
                                if (-not (Test-Path -LiteralPath $srcExpr)) { continue }
                                $dstExpr = Join-Path $MetadataDirectory $ref
                                $dstParent = Split-Path -Parent $dstExpr
                                if (-not (Test-Path -LiteralPath $dstParent)) { New-Item -ItemType Directory -Path $dstParent -Force | Out-Null }
                                Copy-Item -LiteralPath $srcExpr -Destination $dstExpr -Force
                            }
                        }
                    }
                }
                finally {
                    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
                    Remove-Item -LiteralPath $scopedJson -Force -ErrorAction SilentlyContinue
                }
            }
            if ($PoDirectory -and $PSCmdlet.ShouldProcess($PoDirectory, 'refresh the translation catalogue from the scoped package')) {
                Export-NeoIPCMetadataTranslation -Package (Get-NeoIPCMetadataScopedConfig -ExportPath $sourcePath) -PoDirectory $PoDirectory -Validate
                $poUpdated = $true
            }
        }

        foreach ($u in $unclassified) {
            Write-Warning ("Unclassified generated delta — investigate (no known owner): {0} {1} {2} ({3})." -f $u.Kind, $u.Type, $u.Id, $u.Key)
        }

        [pscustomobject]@{
            Applied             = [bool]$Apply
            AutoWrite           = (& $byType $autoWriteDeltas)
            RemovedReportOnly   = (& $byType $removedDeltas)
            AuthoredReportOnly  = $authoredHit
            GeneratedReportOnly = @($genDeltas | Where-Object { [string]$_.Class -ne 'Unclassified' } | Group-Object Class | ForEach-Object { [pscustomobject]@{ Class = $_.Name; Count = $_.Count } } | Sort-Object Class)
            Unclassified        = @($unclassified | ForEach-Object { [pscustomobject]@{ Type = $_.Type; Kind = $_.Kind; Id = $_.Id; Key = $_.Key } })
            PoUpdated           = $poUpdated
        }
    }
    finally {
        if ($tempMerged) { Remove-Item -LiteralPath $tempMerged -Force -ErrorAction SilentlyContinue }
    }
}
