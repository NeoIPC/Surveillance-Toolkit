# Public reconcile cmdlet: ingest a fresh DHIS2 export and bring the canonical metadata/ directory into line with
# it, as reviewable minimal diffs, WITHOUT clobbering content the directory owns differently than the export
# carries it (the authored org units / users, the ontology-generated families, the domain YAML). The directory is
# canonical; the export is an INPUT, not the truth. Reuses the existing reverse-path engine end to end. Report-only
# unless -Apply. No DHIS2 API calls.

function Update-NeoIPCMetadataDirectory {
    <#
    .SYNOPSIS
        Reconcile the canonical metadata directory against a fresh DHIS2 export (report-only unless -Apply).
    .DESCRIPTION
        The reverse path. Diffs the directory's current package (ConvertTo-NeoIPCMetadataJson) against a fresh
        export and classifies the drift by who OWNS each object, then — only with -Apply — brings the
        directory into line for the part the export faithfully carries:

          - AUTO-WRITE (CSV-owned config): every object the core diff surfaces (Compare-NeoIPCMetadataCore already
            skips the generated families, the domain option sets, and the excluded / deferred / default-UID
            objects on both sides, so the core diff is exactly the hand-maintained config). The affected per-type
            CSVs are RE-EMITTED from the incoming export — deterministically, so the git diff is minimal — through
            a temp directory seeded with the committed sharing.yaml, so the sharing cells keep their authored
            profile keys. organisationUnits is never re-emitted (see below).

          - REPORT-ONLY, authored: organisationUnits carry the REAL authored production UIDs / ISO codes / English
            names, whereas an export carries only ANONYMISED org-unit instances — auto-writing would destroy the
            authored content — and users is an excluded PII type. They are reported, never written. Without a
            -SupplementPath the program notification templates (absent from a plain /api/metadata export) are
            treated the same way, so they do not diff as spurious removals.

          - REPORT-ONLY, generated / domain: the ontology- and matrix-generated families and the domain option
            sets / antibiotic groups are routed by Compare-NeoIPCGeneratedMetadata's classification — reconcile
            never reverse-writes a generated object as hand-authored; the developer edits the ontology YAML /
            capability matrix / antibiotics CSV and regenerates. A 'HandAuthoredAction' class flags a hand-authored
            action riding a generated rule (e.g. the BSI no-positive-culture HIDEFIELD) that the directory should
            represent as a stand-alone rule. An 'Unclassified' generated delta is surfaced loudly (warning) — an
            unexpected change to investigate, never silently written.

          - PO: with -Apply and -PoDirectory, the translation catalogue is refreshed from the incoming export
            (Export-NeoIPCMetadataTranslation, which merges msgmerge-style: msgstrs preserved, changed sources
            fuzzed, obsolete entries dropped).

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
        from the incoming export. When omitted, the PO is left untouched (and the report notes it was skipped).
    .PARAMETER Apply
        Write the reconciled changes (re-emit the affected CSVs + refresh the PO). Without it, the cmdlet only
        reports the drift and changes nothing.
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

    # Authored / non-reconcilable types — never auto-written from an export. organisationUnits carry the real
    # authored UIDs (the export has only anonymised instances); users is an excluded PII type the converter never
    # emits anyway (listed for the report). programNotificationTemplates joins them when no supplement supplies them.
    $authoredTypes = [System.Collections.Generic.HashSet[string]]::new([string[]]@('organisationUnits', 'users'), [System.StringComparer]::Ordinal)
    $hasSupplement = -not [string]::IsNullOrEmpty($SupplementPath)

    # 1. Ingest: optional notification-template splice, then parse the incoming package. $sourcePath is the file
    #    the re-emit step reads, so it must be the SAME bytes the diff sees (the merged file when splicing).
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
        # Compare-NeoIPCMetadataCore and the generators normalize their input package IN PLACE (the noise strip
        # removes audit fields AND the deferred translations[]), so every diff / extract below gets its OWN fresh
        # parse — a shared package would be corrupted for the next consumer. $probe is only the non-mutating
        # template-presence check.
        $probe = ConvertFrom-NeoIPCMetadataJsonText -Json (Get-Content -LiteralPath $sourcePath -Raw)
        # Program notification templates are absent from a plain /api/metadata export; reconcile them only when the
        # incoming actually carries them (a -SupplementPath splice, or an export that already includes them) —
        # otherwise report-only, so they do not diff as spurious removals against the directory's templates.
        $probeTpl = $probe['programNotificationTemplates']   # $null when the key is absent; @($null).Count is 1, so test null first
        if ($null -eq $probeTpl -or @($probeTpl).Count -eq 0) { [void]$authoredTypes.Add('programNotificationTemplates') }

        # 2-3. Core diff (directory's current package vs the incoming) — the CSV-owned config drift; the comparator
        # skips generated / domain / excluded / deferred / default-UID objects on both sides.
        $coreDeltas = @(Compare-NeoIPCMetadataCore `
                -Reference (ConvertFrom-NeoIPCMetadataJsonText -Json (ConvertTo-NeoIPCMetadataJson -Path $MetadataDirectory)) `
                -Difference (ConvertFrom-NeoIPCMetadataJsonText -Json (Get-Content -LiteralPath $sourcePath -Raw)))

        # 4. Partition: authored types are reported, not written; everything else is an auto-write candidate.
        $autoDeltas = @($coreDeltas | Where-Object { -not $authoredTypes.Contains([string]$_.Type) })
        $authoredHit = @($coreDeltas | Where-Object { $authoredTypes.Contains([string]$_.Type) } | ForEach-Object { [string]$_.Type } | Sort-Object -Unique)

        # 5. Generated / domain drift — report-only, routed by class. Fresh parse (Compare-NeoIPCGeneratedMetadata
        # scopes + normalizes its input in place). It returns its deltas as ONE protected collection (unary-comma
        # return), so capture it first and THEN enumerate — @(<call>) would wrap the whole list in a 1-element array.
        $genResult = Compare-NeoIPCGeneratedMetadata -ExistingPackage (ConvertFrom-NeoIPCMetadataJsonText -Json (Get-Content -LiteralPath $sourcePath -Raw))
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

        $affectedTypes = @($autoDeltas | ForEach-Object { [string]$_.Type } | Sort-Object -Unique)
        $poUpdated = $false

        # 6. Apply: re-emit the affected CSV-owned types + refresh the PO.
        if ($Apply) {
            if ($affectedTypes.Count -gt 0 -and $PSCmdlet.ShouldProcess($MetadataDirectory, ("re-emit {0} affected type CSV(s): {1}" -f $affectedTypes.Count, ($affectedTypes -join ', ')))) {
                $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('neoipc-reconcile-emit-' + [System.IO.Path]::GetRandomFileName())
                New-Item -ItemType Directory -Path $tmp -Force | Out-Null
                try {
                    # Seed the temp dir with the committed sharing profiles so the re-emitted CSVs carry the AUTHORED
                    # sharing keys (an unrecognized shape in the export fails loud, as elsewhere — name it in sharing.yaml).
                    $sharingSrc = Join-Path $MetadataDirectory 'sharing.yaml'
                    if (Test-Path -LiteralPath $sharingSrc) { Copy-Item -LiteralPath $sharingSrc -Destination (Join-Path $tmp 'sharing.yaml') -Force }
                    ConvertFrom-NeoIPCMetadataJson -Path $sourcePath -OutputDirectory $tmp
                    # Copy each affected type's CSV from the deterministic re-emit.
                    foreach ($t in $affectedTypes) {
                        $srcCsv = Join-Path $tmp "$t.csv"
                        $dstCsv = Join-Path $MetadataDirectory "$t.csv"
                        if (Test-Path -LiteralPath $srcCsv) { Copy-Item -LiteralPath $srcCsv -Destination $dstCsv -Force }
                        elseif (Test-Path -LiteralPath $dstCsv) { Remove-Item -LiteralPath $dstCsv -Force }   # the type vanished from the export
                    }
                    # Mirror the externalised-expression SUBTREES of the affected types. A type's expression files live
                    # under expressions/<owningType>: a program-rule ACTION's `data` co-locates with its owning rule under
                    # expressions/programRules (Get-NeoIPCMetadataExpressionFilePath), so an affected programRuleActions
                    # maps to the programRules subtree — keying on expressions/programRuleActions would miss it entirely and
                    # silently drop the changed action expressions. Mirror each distinct subtree once (delete-then-copy;
                    # the deterministic emit keeps unchanged files byte-identical, so the diff stays minimal). A
                    # non-expression type maps to a subtree absent on both sides, so its guarded copy is a no-op.
                    $exprSubtrees = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
                    foreach ($t in $affectedTypes) { [void]$exprSubtrees.Add(($t -eq 'programRuleActions' ? 'programRules' : $t)) }
                    foreach ($sub in $exprSubtrees) {
                        $srcExpr = Join-Path (Join-Path $tmp 'expressions') $sub
                        $dstExpr = Join-Path (Join-Path $MetadataDirectory 'expressions') $sub
                        if (Test-Path -LiteralPath $dstExpr) { Remove-Item -LiteralPath $dstExpr -Recurse -Force }
                        if (Test-Path -LiteralPath $srcExpr) { Copy-Item -LiteralPath $srcExpr -Destination $dstExpr -Recurse -Force }
                    }
                }
                finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
            }
            if ($PoDirectory -and $PSCmdlet.ShouldProcess($PoDirectory, 'refresh the translation catalogue')) {
                Export-NeoIPCMetadataTranslation -Path $sourcePath -PoDirectory $PoDirectory -Validate
                $poUpdated = $true
            }
        }

        foreach ($u in $unclassified) {
            Write-Warning ("Unclassified generated delta — investigate (no known owner): {0} {1} {2} ({3})." -f $u.Kind, $u.Type, $u.Id, $u.Key)
        }

        [pscustomobject]@{
            Applied             = [bool]$Apply
            AutoWrite           = (& $byType $autoDeltas)
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
