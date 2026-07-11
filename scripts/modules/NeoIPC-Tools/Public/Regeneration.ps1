function Update-NeoIPCGeneratedMetadataDirectory {
    <#
    .SYNOPSIS
        Regenerate the ontology / capability-matrix families and re-materialise them into the canonical metadata
        directory's common/ tree.
    .DESCRIPTION
        The matrix-generated families — the per-slot pathogen / substance data elements and the resistance /
        field-gating / virus / substance program-rule variables, rules and actions — are COMMITTED under common/ (as
        CSV rows + externalised expression files under expressions/) so a human can review them and git can show drift.
        Their SOURCE OF TRUTH is the generators (Add-NeoIPCGeneratedMetadata): a change to the infectious-agent
        ontology, the antibiotic sources, or a generator only reaches common/ once the directory is re-materialised.
        This command does exactly that — regenerate the generated-class objects (UID-preserving, reconciled against the
        assembled install base, which carries the option-set UIDs that common/ deliberately omits) and write the result
        back into common/ through the faithful directory writer (ConvertFrom-NeoIPCMetadataJson: UTF-8 / no-BOM / LF
        CSVs, expressions emitted verbatim). So a build that runs this first always ships the current generators, and
        drift between the generators and the committed directory surfaces as a reviewable git diff. Only the generated
        families are rewritten; hand-authored config (the infection-definition business rules, the domain YAML, the
        org-unit / user overlay) is left exactly as the directory carries it. Idempotent. No DHIS2 API calls.

        LIMIT (additive writer): ConvertFrom-NeoIPCMetadataJson writes/overwrites files for the objects it is given but
        never DELETES the expression files (or prunes the CSV rows) of a generated object that this regeneration DROPS
        or RENAMES — lowering the slot count, or an ontology change that removes/renames a rule, leaves the old
        expressions/<rule>/*.dhis2 files behind as unchanged tracked files that git status does not flag. So the
        drift-as-git-diff guarantee is complete for ADDITIONS and CONTENT changes but NOT for removals/renames, whose
        orphaned files must be deleted by hand until an orphan-sweep is added.

        Why an assembled install base is the UID source, not common/ alone: the option-domain families
        (NEOIPC_PATHOGENS / NEOIPC_ANTIMICROBIAL_SUBSTANCES option sets + options + groups) are NOT materialised into
        common/ (a richer source — the ontology YAML + UID sidecar + antibiotic CSVs — owns them, and they are
        generated at build), so the generators, which reconcile every reproduced object against the deployed option
        set, need a source that carries them. New-NeoIPCMetadataPackage assembles exactly that.
    .PARAMETER MetadataDirectory
        The canonical metadata directory root (contains common/). common/ is rewritten in place.
    .PARAMETER PathogenCount
        Pathogen slots per applicable stage (1-9). Default: the module-wide count.
    .PARAMETER SubstanceCount
        Antimicrobial-substance slots (1-99). Default: the module-wide count.
    .PARAMETER OntologyPath
        Path to the infectious-agent YAML. Defaults (in each generator) to the canonical file in the repository.
    .PARAMETER PoDirectory
        Directory of the po4a locale catalogues the option labels are localized from. Defaults to the repository's po/.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$MetadataDirectory,
        [ValidateRange(1, 9)][int]$PathogenCount = $script:NeoIPCPathogenSlotCount,
        [ValidateRange(1, 99)][int]$SubstanceCount = $script:NeoIPCSubstanceSlotCount,
        [string]$OntologyPath,
        [string]$PoDirectory
    )
    if (-not (Test-Path -LiteralPath $MetadataDirectory)) { throw "Metadata directory not found: '$MetadataDirectory'." }
    $common = Join-Path $MetadataDirectory 'common'
    if (-not (Test-Path -LiteralPath $common)) { throw "Common metadata directory not found: '$common'." }

    # UID-preservation source: the assembled install base carries the deployed option sets (from the UID sidecar) that
    # the committed common/ tree omits and the generators reconcile against. Config is the current common/ package.
    $export = ConvertFrom-NeoIPCMetadataJsonText -Json (New-NeoIPCMetadataPackage -MetadataDirectory $MetadataDirectory)
    $config = ConvertFrom-NeoIPCMetadataJsonText -Json (ConvertTo-NeoIPCMetadataJson -Path $common)

    $genArgs = @{ Config = $config; Export = $export; PathogenCount = $PathogenCount; SubstanceCount = $SubstanceCount }
    if ($OntologyPath) { $genArgs['OntologyPath'] = $OntologyPath }
    if ($PoDirectory) { $genArgs['PoDirectory'] = $PoDirectory }
    $regen = Add-NeoIPCGeneratedMetadata @genArgs

    if ($PSCmdlet.ShouldProcess($common, 'Re-materialise the generated matrix families')) {
        $tmp = [System.IO.Path]::GetTempFileName()
        try {
            [System.IO.File]::WriteAllText($tmp, ($regen | ConvertTo-Json -Depth 100), [System.Text.UTF8Encoding]::new($false))
            ConvertFrom-NeoIPCMetadataJson -Path $tmp -OutputDirectory $common -Confirm:$false
        }
        finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
    }
}
