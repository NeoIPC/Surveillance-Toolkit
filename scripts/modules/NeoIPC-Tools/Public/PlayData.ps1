function New-NeoIPCPlayDataPackage {
    <#
    .SYNOPSIS
        Assemble a /api/tracker payload from the committed play demo-data CSVs, resolving codes to instance UIDs.
    .DESCRIPTION
        The tracker-data counterpart to New-NeoIPCMetadataPackage. Reads the demo_data/ CSVs (bulk/ + curated/
        tiers), fetches the code<->UID map from the target instance (Get-NeoIPCPlayDataCodeMap), and assembles a
        deterministic { trackedEntities: [...] } payload with every code handle resolved to that instance's UID
        (ConvertTo-NeoIPCPlayDataPayload). Because it re-resolves per instance, the same committed data imports
        on any DHIS2 version running the NeoIPC metadata package. Committed row ids become the payload UIDs, so
        Import-NeoIPCPlayData can upsert (CREATE_AND_UPDATE) rather than duplicate. Emits JSON (returned, or to
        -OutputPath), or the package object with -PassThru. This READS the instance metadata only — no writes.
    .PARAMETER Path
        The demo_data directory (containing bulk/ and/or curated/). Defaults to the committed
        metadata/play/demo_data under the repo root.
    .PARAMETER Auth
        Auth hashtable from Resolve-NeoIPCAuth (Token or Basic).
    .PARAMETER OrgUnitCode
        Optional department-code filter — include only tracked entities in these departments.
    .PARAMETER OutputPath
        Optional file to write the payload JSON to (UTF-8, no BOM); if omitted the JSON string is returned
        (unless -PassThru).
    .PARAMETER Compress
        Emit compact JSON instead of indented.
    .PARAMETER PassThru
        Return the payload hashtable (with a trackedEntities array) instead of JSON.
    #>
    [CmdletBinding()]
    [OutputType([string], [hashtable])]
    param(
        [string]$Path,
        [Parameter(Mandatory)][hashtable]$Auth,
        [string]$Scheme = 'https',
        [string]$Hostname = 'neoipc.charite.de',
        [Nullable[int]]$Port = $null,
        [string[]]$OrgUnitCode,
        [string]$OutputPath,
        [switch]$Compress,
        [switch]$PassThru
    )
    if (-not $Path) { $Path = Join-Path $script:NeoIPCRepoRoot 'metadata/play/demo_data' }
    $rows = Read-NeoIPCPlayDataDirectory -Path $Path

    # Every org-unit code the data references — from tracked entities AND their enrollments / events, since the
    # schema permits a per-row org unit (e.g. modelling a transfer) that differs from the TE's. Resolve them all
    # so the converter's Resolve-Ou finds each (unused ones are harmless).
    $ouCodes = @(
        @($rows.TrackedEntities | ForEach-Object { [string]$_['orgUnit'] }) +
        @($rows.Enrollments | ForEach-Object { [string]$_['orgUnit'] }) +
        @($rows.Events | ForEach-Object { [string]$_['orgUnit'] })
    ) | Where-Object { $_ } | Select-Object -Unique

    $endpoint = @{ Auth = $Auth }
    if ($Scheme) { $endpoint.Scheme = $Scheme }
    if ($Hostname) { $endpoint.Hostname = $Hostname }
    if ($null -ne $Port) { $endpoint.Port = $Port }
    $maps = Get-NeoIPCPlayDataCodeMap @endpoint -OrgUnitCode $ouCodes

    $payload = ConvertTo-NeoIPCPlayDataPayload -Rows $rows -Maps $maps -OrgUnitCode $OrgUnitCode
    Write-Verbose ("Assembled play-data payload: {0} tracked entities." -f @($payload.trackedEntities).Count)

    if ($PassThru) { return $payload }
    $json = $payload | ConvertTo-Json -Depth 100 -Compress:$Compress
    if ($OutputPath) {
        [System.IO.File]::WriteAllText($OutputPath, $json, [System.Text.UTF8Encoding]::new($false))
        return
    }
    $json
}

function Import-NeoIPCPlayData {
    <#
    .SYNOPSIS
        POST a play-data tracker payload to /api/tracker, returning a normalized import summary.
    .DESCRIPTION
        The import half of the play-data pipeline (counterpart to Import-NeoIPCMetadata). Sends a payload from
        New-NeoIPCPlayDataPackage (or any /api/tracker JSON) to /api/tracker and returns a normalized summary
        of the tracker import report (Status OK/WARNING/ERROR, the create/update/delete/ignore/total stats, and
        the validation error/warning reports). The payload is imported PER ORG UNIT (one POST per tracked-entity
        org unit): DHIS2's within-payload uniqueness check ignores org-unit scope, so a unique-per-org-unit
        attribute (NEOIPC_PATIENT_ID) carrying the same value in two departments in one payload is wrongly
        rejected E1064 — splitting by org unit avoids it. The returned summary aggregates the per-org-unit
        reports (its OrgUnitGroups field is the POST count). With -DryRun the server only validates (importMode=VALIDATE) and
        persists nothing — necessary but NOT sufficient, because VALIDATE never reaches the COMMIT phase where
        the 2.41 preheat displayIncidentDate bug rejects a null enrollment occurredAt (E1023); always confirm a
        change with a real commit too. A non-OK status is reported, not thrown — the caller decides. Like the
        metadata importer, a real commit is high-impact and confirms by default (pass -Confirm:$false to run
        unattended); a dry-run does not prompt. This DRIVES a DHIS2 instance, so it is for the LOCAL / test
        stack only (synthetic data).

        On DHIS2 2.43.0 / 2.43.0.x the server-side program-rule engine is skipped automatically (a broken
        SupplementaryDataProvider makes the d2:inOrgUnitGroup rules collide with a 409 "Duplicate key"; fixed in
        2.43.1). The payload is complete and separately VALIDATE-checked, so it needs no server-side rules on
        those two patches. -SkipRuleEngine / -SkipRuleEngine:$false overrides the auto-detection.
    .PARAMETER Path
        Path to a /api/tracker payload JSON file.
    .PARAMETER Json
        A /api/tracker payload JSON string (e.g. the New-NeoIPCPlayDataPackage return), instead of -Path.
    .PARAMETER Auth
        Auth hashtable from Resolve-NeoIPCAuth (Token or Basic).
    .PARAMETER ImportStrategy
        DHIS2 importStrategy: CREATE_AND_UPDATE (default — idempotent on committed UIDs), CREATE, UPDATE, DELETE.
    .PARAMETER AtomicMode
        DHIS2 atomicMode: ALL (default — all-or-nothing) or OBJECT (import what is valid, report the rest).
    .PARAMETER DryRun
        Validate only (importMode=VALIDATE); the server persists nothing.
    .PARAMETER SkipRuleEngine
        Force the server-side program-rule engine on/off, overriding the 2.43.0.x auto-skip.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'Path')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path')][string]$Path,
        [Parameter(Mandatory, ParameterSetName = 'Json')][string]$Json,
        [Parameter(Mandatory)][hashtable]$Auth,
        [string]$Scheme = 'https',
        [string]$Hostname = 'neoipc.charite.de',
        [Nullable[int]]$Port = $null,
        [ValidateSet('CREATE_AND_UPDATE', 'CREATE', 'UPDATE', 'DELETE')][string]$ImportStrategy = 'CREATE_AND_UPDATE',
        [ValidateSet('ALL', 'OBJECT')][string]$AtomicMode = 'ALL',
        [switch]$DryRun,
        [switch]$SkipRuleEngine
    )
    if ($PSCmdlet.ParameterSetName -eq 'Path') {
        if (-not (Test-Path -LiteralPath $Path)) { throw "Play-data payload not found: '$Path'." }
        $payload = [System.IO.File]::ReadAllText($Path)
    }
    else { $payload = $Json }

    $endpoint = @{ Auth = $Auth }
    if ($Scheme) { $endpoint.Scheme = $Scheme }
    if ($Hostname) { $endpoint.Hostname = $Hostname }
    if ($null -ne $Port) { $endpoint.Port = $Port }

    $query = [ordered]@{
        async          = 'false'
        importStrategy = $ImportStrategy
        atomicMode     = $AtomicMode
        importMode     = if ($DryRun) { 'VALIDATE' } else { 'COMMIT' }
        # FULL so the returned report carries warnings too — the server default (ERRORS) strips warningReports
        # even when status is WARNING (DefaultTrackerImportService.buildImportReport, refs/dhis2-core).
        reportMode     = 'FULL'
    }

    # Skip the rule engine on the two 2.43.0.x patches whose SupplementaryDataProvider 409s our
    # d2:inOrgUnitGroup rules (fixed in 2.43.1); explicit -SkipRuleEngine overrides the detection.
    if ($PSBoundParameters.ContainsKey('SkipRuleEngine')) {
        if ($SkipRuleEngine) { $query['skipRuleEngine'] = 'true' }
    }
    else {
        $version = ''
        try { $version = [string]((Invoke-NeoIPCDhis2Get @endpoint -Path 'api/system/info').version) }
        catch { Write-Verbose "Could not read the DHIS2 version for the rule-engine gate ($($_.Exception.Message)); leaving the server-side rule engine on." }
        if ($version -match '^2\.43\.0(\.\d+)?$') {
            $query['skipRuleEngine'] = 'true'
            Write-Verbose "DHIS2 ${version}: skipping the program-rule engine on import (2.43.0.x SupplementaryDataProvider workaround; fixed in 2.43.1)."
        }
    }

    $portSuffix = if ($null -ne $Port) { ":$Port" } else { '' }
    $target = "${Scheme}://${Hostname}${portSuffix}/api/tracker"
    $action = if ($DryRun) { 'Validate play-data import (dry-run)' } else { "Import play data ($ImportStrategy)" }
    if ($DryRun -and -not $PSBoundParameters.ContainsKey('Confirm')) { $ConfirmPreference = 'None' }
    if (-not $PSCmdlet.ShouldProcess($target, $action)) { return }

    # Import each org unit's tracked entities in its OWN POST. DHIS2's WITHIN-PAYLOAD uniqueness check groups a
    # unique attribute's values by (attribute, value) IGNORING org-unit scope (verified at source against
    # refs/dhis2-core UniqueAttributesSupplier.getDuplicatedUniqueValuesInPayload + AttributeValidator), so a
    # unique-PER-ORG-UNIT attribute (NEOIPC_PATIENT_ID, orgunitScope=true) carrying the same value in two
    # departments in ONE payload is wrongly rejected E1064. Splitting by tracked-entity orgUnit keeps each
    # department's per-org-unit-unique values in a separate POST; the persisted-value check (across POSTs) DOES
    # honour the org-unit scope, so values re-used across departments are accepted. Each POST is atomic per its
    # -AtomicMode; a failure in one department does not roll back an already-committed one (as the old
    # per-department seed behaved).
    $payloadObj = $payload | ConvertFrom-Json -Depth 100
    $tes = @($payloadObj.trackedEntities)
    $groups = if ($tes.Count -gt 0) { @($tes | Group-Object -Property orgUnit) } else { @() }

    $created = 0; $updated = 0; $deleted = 0; $ignored = 0; $total = 0
    $errorReports = [System.Collections.Generic.List[object]]::new()
    $warningReports = [System.Collections.Generic.List[object]]::new()
    $errorMessages = [System.Collections.Generic.List[string]]::new()
    $statuses = [System.Collections.Generic.List[string]]::new()
    $httpCodes = [System.Collections.Generic.List[int]]::new()
    # Raw retains a representative response body — the first group's, unless a later group fails, in which
    # case the first FAILING body takes over (see the loop) so a post-mortem reads the failure, not a
    # subsequent group's success.
    $rawBody = $null
    $rawIsFailure = $false

    foreach ($grp in $groups) {
        $groupBody = @{ trackedEntities = @($grp.Group) } | ConvertTo-Json -Depth 100
        $response = Invoke-NeoIPCDhis2Post @endpoint -Path 'api/tracker' -Body $groupBody -QueryParameters $query -Confirm:$false
        $body = $response.Body
        $httpCodes.Add([int]$response.StatusCode)

        # The tracker import report is either plain or wrapped in a WebMessage (.response), depending on version.
        $hasResponse = $body -and ($body.PSObject.Properties.Name -contains 'response') -and $body.response
        $report = if ($hasResponse) { $body.response } else { $body }
        $status = if ($report -and ($report.PSObject.Properties.Name -contains 'status')) { [string]$report.status }
        elseif ($body -and ($body.PSObject.Properties.Name -contains 'status')) { [string]$body.status } else { $null }
        if ($status) { $statuses.Add($status) }

        # Keep Raw representative of a failure rather than merely "the last group posted". Prefer the first
        # FAILING group's body (non-2xx transport or status=ERROR); fall back to the first group's body only
        # while no failure has been seen. A failure claims the slot even with a null body (a bare transport
        # error carries none), so a later group's success can never mask it — the failure detail then lives
        # in the aggregate Status / HttpStatusCode / ErrorMessage.
        $isFailureBody = ([int]$response.StatusCode -ge 400) -or ($status -eq 'ERROR')
        if ($isFailureBody) {
            if (-not $rawIsFailure) { $rawBody = $body; $rawIsFailure = $true }
        }
        elseif ((-not $rawIsFailure) -and ($null -eq $rawBody)) {
            $rawBody = $body
        }

        $stats = if ($report -and ($report.PSObject.Properties.Name -contains 'stats')) { $report.stats } else { $null }
        if ($stats) {
            if ($stats.PSObject.Properties.Name -contains 'created') { $created += [int]$stats.created }
            if ($stats.PSObject.Properties.Name -contains 'updated') { $updated += [int]$stats.updated }
            if ($stats.PSObject.Properties.Name -contains 'deleted') { $deleted += [int]$stats.deleted }
            if ($stats.PSObject.Properties.Name -contains 'ignored') { $ignored += [int]$stats.ignored }
            if ($stats.PSObject.Properties.Name -contains 'total') { $total += [int]$stats.total }
        }
        $validation = if ($report -and ($report.PSObject.Properties.Name -contains 'validationReport')) { $report.validationReport } else { $null }
        if ($validation -and ($validation.PSObject.Properties.Name -contains 'errorReports')) { foreach ($e in @($validation.errorReports)) { $errorReports.Add($e) } }
        if ($validation -and ($validation.PSObject.Properties.Name -contains 'warningReports')) { foreach ($w in @($validation.warningReports)) { $warningReports.Add($w) } }

        # A bare WebMessage (no .response) carries the real cause in `message` (e.g. a Tomcat-level failure) —
        # surface it rather than an opaque "status ERROR".
        if (-not $hasResponse -and $body) {
            $m = if ($body.PSObject.Properties.Name -contains 'message') { $body.message } else { $null }
            $dm = if ($body.PSObject.Properties.Name -contains 'devMessage') { $body.devMessage } else { $null }
            $em = (@($m, $dm) | Where-Object { $_ }) -join ' / '
            if ($em) { $errorMessages.Add($em) }
        }
    }

    $worstHttp = if ($httpCodes.Count -gt 0) { ($httpCodes | Measure-Object -Maximum).Maximum } else { $null }
    # A per-group POST that returned a non-2xx body with NO parseable import report (e.g. an nginx 502/504 or a
    # Tomcat 500 HTML page from a backend restart mid-import) contributes nothing to $statuses / $errorReports —
    # fold the transport code in so such a failure cannot be mistaken for a successful import.
    if (($null -ne $worstHttp) -and ([int]$worstHttp -ge 400) -and ($errorReports.Count -eq 0) -and ($errorMessages.Count -eq 0)) {
        $errorMessages.Add("At least one tracker POST returned HTTP $worstHttp with no parseable import report (likely a transport / server error).")
    }
    $overallStatus =
    if (($statuses -contains 'ERROR') -or ($errorReports.Count -gt 0) -or ($errorMessages.Count -gt 0)) { 'ERROR' }
    elseif ($statuses -contains 'WARNING') { 'WARNING' }
    else { 'OK' }
    $errorMessage = if ($errorMessages.Count -gt 0) { (@($errorMessages | Select-Object -Unique)) -join ' / ' } else { $null }

    Write-Verbose ("play-data import ({0}): {1} org-unit POST(s), overall status {2}; created={3} updated={4} deleted={5} ignored={6}{7}." -f `
        ($(if ($DryRun) { 'dry-run' } else { 'commit' })), $groups.Count, $overallStatus, $created, $updated, $deleted, $ignored,
        $(if ($errorMessage) { " — $errorMessage" } else { '' }))

    [pscustomobject]@{
        DryRun         = [bool]$DryRun
        HttpStatusCode = $worstHttp
        Status         = $overallStatus
        Created        = $created
        Updated        = $updated
        Deleted        = $deleted
        Ignored        = $ignored
        Total          = $total
        OrgUnitGroups  = $groups.Count
        ErrorReports   = $errorReports.ToArray()
        WarningReports = $warningReports.ToArray()
        ErrorMessage   = $errorMessage
        Raw            = $rawBody
    }
}

function Export-NeoIPCPlayDataCsv {
    <#
    .SYNOPSIS
        Serialize demo-data generator -DryRun payload(s) into the committed play-data CSVs (the bulk re-freeze).
    .DESCRIPTION
        The one-time bootstrap / re-freeze tool for the bulk tier. Takes one or more Build-Dhis2DemoData.ps1
        -DryRun payloads (UID-keyed { trackedEntities: [...] }), fetches the instance code map to reverse-map
        every UID back to its code, mints a deterministic committed UID per tracked entity / enrollment / event
        (ConvertTo-NeoIPCPlayDataRow), and writes the four code-keyed CSVs to -OutputDirectory (normally
        metadata/play/demo_data/bulk). Rows are sorted deterministically so a re-freeze produces a reviewable
        diff. Writes UTF-8 (no BOM), LF line endings. This READS the instance metadata only — it does not write
        to DHIS2 (the generator already ran; this just serializes its output).
    .PARAMETER InputPath
        One or more generator -DryRun JSON files (each a { trackedEntities: [...] } payload). Merged in order.
    .PARAMETER InputJson
        One or more generator -DryRun JSON strings, instead of -InputPath.
    .PARAMETER OutputDirectory
        Directory to write trackedEntities.csv / enrollments.csv / events.csv / eventDataValues.csv into
        (created if absent).
    .PARAMETER Auth
        Auth hashtable from Resolve-NeoIPCAuth (Token or Basic) for the code-map fetch.
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Path')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path')][string[]]$InputPath,
        [Parameter(Mandatory, ParameterSetName = 'Json')][string[]]$InputJson,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][hashtable]$Auth,
        [string]$Scheme = 'https',
        [string]$Hostname = 'neoipc.charite.de',
        [Nullable[int]]$Port = $null
    )
    $payloads = if ($PSCmdlet.ParameterSetName -eq 'Path') {
        @($InputPath | ForEach-Object {
                if (-not (Test-Path -LiteralPath $_)) { throw "Generator payload not found: '$_'." }
                [System.IO.File]::ReadAllText($_) | ConvertFrom-Json
            })
    }
    else { @($InputJson | ForEach-Object { $_ | ConvertFrom-Json }) }

    # Reverse-resolve needs every org-unit UID the payloads reference; the DE / TEA / stage reverse maps come
    # from the program metadata.
    # Union the org-unit UIDs from tracked entities AND their enrollments / events — ConvertTo-NeoIPCPlayDataRow
    # reverse-resolves all three (a per-row org unit may differ from the TE's), symmetric with the forward
    # New-NeoIPCPlayDataPackage collection.
    $ouIds = @(
        $payloads | ForEach-Object {
            foreach ($te in @($_.trackedEntities)) {
                [string]$te.orgUnit
                foreach ($enr in @($te.enrollments)) {
                    [string]$enr.orgUnit
                    foreach ($ev in @($enr.events)) { [string]$ev.orgUnit }
                }
            }
        }
    ) | Where-Object { $_ } | Select-Object -Unique
    $endpoint = @{ Auth = $Auth }
    if ($Scheme) { $endpoint.Scheme = $Scheme }
    if ($Hostname) { $endpoint.Hostname = $Hostname }
    if ($null -ne $Port) { $endpoint.Port = $Port }
    $maps = Get-NeoIPCPlayDataCodeMap @endpoint -OrgUnitId $ouIds

    $rows = ConvertTo-NeoIPCPlayDataRow -Payload $payloads -Maps $maps

    if (-not $PSCmdlet.ShouldProcess($OutputDirectory, "Write play-data CSVs ($($rows.TrackedEntities.Count) tracked entities)")) { return }
    if (-not (Test-Path -LiteralPath $OutputDirectory)) { $null = New-Item -ItemType Directory -Path $OutputDirectory -Force }

    # Deterministic ORDINAL order so a re-freeze diffs byte-identically on any machine (README: by id, then
    # parent + id / DE code). Sort-Object is culture-sensitive + case-insensitive; DHIS2 UIDs are
    # case-significant, so reuse the metadata pipeline's ordinal row-set sorter over NUL-joined composite keys
    # (every key ends in a unique id / DE code, so there are no ties and the sort is fully determined).
    $teRows = Get-NeoIPCMetadataSortedRowSet -Row @($rows.TrackedEntities) -Key @($rows.TrackedEntities | ForEach-Object { [string]$_['id'] })
    $enrRows = Get-NeoIPCMetadataSortedRowSet -Row @($rows.Enrollments) -Key @($rows.Enrollments | ForEach-Object { [string]$_['trackedEntity'] + [char]0 + [string]$_['id'] })
    $evRows = Get-NeoIPCMetadataSortedRowSet -Row @($rows.Events) -Key @($rows.Events | ForEach-Object { [string]$_['enrollment'] + [char]0 + [string]$_['id'] })
    $edvRows = Get-NeoIPCMetadataSortedRowSet -Row @($rows.EventDataValues) -Key @($rows.EventDataValues | ForEach-Object { [string]$_['event'] + [char]0 + [string]$_['dataElement'] })

    # trackedEntities columns: id, orgUnit, then TEA codes in a stable preferred order, appending any extras.
    $preferredTea = @('NEOIPC_PATIENT_ID', 'NEOIPC_TEA_SEX', 'NEOIPC_TEA_BIRTH_WEIGHT', 'NEOIPC_TEA_GEST_AGE',
        'NeoIPC_TEA_TOTAL_GESTATION_DAYS', 'NEOIPC_TEA_DELIVERY_MODE', 'NEOIPC_TEA_MULTIPLE_BIRTH', 'NEOIPC_TEA_SIBLINGS')
    $presentTea = [System.Collections.Generic.List[string]]::new()
    foreach ($r in $teRows) { foreach ($k in $r.Keys) { if ($k -notin 'id', 'orgUnit' -and -not $presentTea.Contains($k)) { $presentTea.Add($k) } } }
    $teaCols = @($preferredTea | Where-Object { $presentTea.Contains($_) }) + @(Get-NeoIPCMetadataOrdinalSort -Values @($presentTea | Where-Object { $_ -notin $preferredTea }))
    $teColumns = @('id', 'orgUnit') + $teaCols

    Write-NeoIPCPlayDataCsv -Path (Join-Path $OutputDirectory 'trackedEntities.csv') -Column $teColumns -Row $teRows
    Write-NeoIPCPlayDataCsv -Path (Join-Path $OutputDirectory 'enrollments.csv') -Column @('id', 'trackedEntity', 'orgUnit', 'enrolledAt', 'occurredAt', 'status', 'completedAt') -Row $enrRows
    Write-NeoIPCPlayDataCsv -Path (Join-Path $OutputDirectory 'events.csv') -Column @('id', 'enrollment', 'programStage', 'orgUnit', 'occurredAt', 'status', 'completedAt') -Row $evRows
    Write-NeoIPCPlayDataCsv -Path (Join-Path $OutputDirectory 'eventDataValues.csv') -Column @('event', 'dataElement', 'value') -Row $edvRows

    Write-Verbose ("Wrote play-data CSVs to {0}: {1} tracked entities, {2} enrollments, {3} events, {4} data values." -f `
            $OutputDirectory, $teRows.Count, $enrRows.Count, $evRows.Count, $edvRows.Count)
}
