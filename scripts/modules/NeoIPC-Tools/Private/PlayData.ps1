# Play demo-data pipeline — internal helpers (private, not exported).
#
# The tracker-data counterpart to the metadata authoring layer: read the committed demo_data/ CSVs (code
# handles), resolve the codes to the target instance's UIDs, and assemble a /api/tracker payload — and the
# reverse, serializing a generator -DryRun payload back into the CSVs. All code<->UID resolution goes through
# a code map fetched once from the instance, so the same committed data imports on any DHIS2 version running
# the NeoIPC metadata package. The pure assembler (ConvertTo-NeoIPCPlayDataPayload) takes a pre-built map, so
# it is testable offline with no API.

# Program-stage NAME -> the short key used in events.csv (and by the demo-data generator). The play data
# names stages by this stable key rather than by UID (instance-specific) or full name (verbose / locale-ish).
$script:NeoIPCPlayDataStageKeyByName = @{
    'Admission'                 = 'adm'
    'Surgical Procedure'        = 'pro'
    'Primary Sepsis/BSI'        = 'bsi'
    'Necrotizing enterocolitis' = 'nec'
    'Surgical Site Infection'   = 'ssi'
    'Pneumonia'                 = 'hap'
    'Surveillance-End'          = 'end'
}

# Valid DHIS2 tracker status values, per level. Authored data is checked against these up front (fail in the
# reader, not late at import). Sourced from refs/dhis2-core EnrollmentStatus / EventStatus enums.
$script:NeoIPCPlayDataEnrollmentStatus = @('ACTIVE', 'COMPLETED', 'CANCELLED')
$script:NeoIPCPlayDataEventStatus = @('ACTIVE', 'COMPLETED', 'VISITED', 'SCHEDULE', 'OVERDUE', 'SKIPPED')

function Get-NeoIPCPlayDataCodeMap {
    <#
    .SYNOPSIS
        Fetch the code<->UID maps the play-data builder / serializer need from a target DHIS2 instance.
    .DESCRIPTION
        One /api/metadata gist for the NEOIPC_CORE program (its trackedEntityType, its TEAs, its stages and
        their data elements) plus, on demand, an /api/organisationUnits lookup by code and/or by id. Returns a
        hashtable of forward maps (code -> UID: TeaCodeToId, DeCodeToId, StageKeyToId, OrgUnitCodeToId) and
        reverse maps (UID -> code: TeaIdToCode, DeIdToCode, StageIdToKey, OrgUnitIdToCode) plus the program and
        tracked-entity-type UIDs. The forward maps drive the builder (New-NeoIPCPlayDataPackage); the reverse
        maps drive the serializer (Export-NeoIPCPlayDataCsv). Fails loud if the program is not found. Uses the
        program's own trackedEntityType[id] rather than a name filter, so no space-in-filter encoding concern.
    .PARAMETER Auth
        Auth hashtable from Resolve-NeoIPCAuth (Token or Basic).
    .PARAMETER OrgUnitCode
        Org-unit codes to resolve to UIDs (for the builder). Fetched via filter code:in:[...].
    .PARAMETER OrgUnitId
        Org-unit UIDs to resolve to codes (for the serializer). Fetched via filter id:in:[...].
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Auth,
        [string]$Scheme = 'https',
        [string]$Hostname = 'neoipc.charite.de',
        [Nullable[int]]$Port = $null,
        [string[]]$OrgUnitCode,
        [string[]]$OrgUnitId
    )
    $endpoint = @{ Auth = $Auth }
    if ($Scheme) { $endpoint.Scheme = $Scheme }
    if ($Hostname) { $endpoint.Hostname = $Hostname }
    if ($null -ne $Port) { $endpoint.Port = $Port }

    $metaQuery = @{
        'programs:filter' = 'code:eq:NEOIPC_CORE'
        'programs:fields' = 'id,trackedEntityType[id],programTrackedEntityAttributes[trackedEntityAttribute[id,code]],programStages[id,name,programStageDataElements[dataElement[id,code]]]'
    }
    $metadata = Invoke-NeoIPCDhis2Get @endpoint -Path 'api/metadata' -QueryParameters $metaQuery
    $programs = if ($metadata -and ($metadata.PSObject.Properties.Name -contains 'programs')) { @($metadata.programs) } else { @() }
    if ($programs.Count -eq 0) { throw "Program 'NEOIPC_CORE' not found on the target DHIS2 instance — is the NeoIPC metadata package imported?" }
    $program = $programs[0]
    if (-not ($program.PSObject.Properties.Name -contains 'trackedEntityType') -or -not $program.trackedEntityType -or -not $program.trackedEntityType.id) {
        throw "Program 'NEOIPC_CORE' has no trackedEntityType in the metadata response — cannot build the tracker payload."
    }

    $teaCodeToId = @{}; $teaIdToCode = @{}
    foreach ($ptea in @($program.programTrackedEntityAttributes)) {
        $tea = $ptea.trackedEntityAttribute
        if ($tea -and $tea.code) { $teaCodeToId[[string]$tea.code] = [string]$tea.id; $teaIdToCode[[string]$tea.id] = [string]$tea.code }
    }

    $deCodeToId = @{}; $deIdToCode = @{}
    $stageKeyToId = @{}; $stageIdToKey = @{}
    foreach ($stage in @($program.programStages)) {
        $key = $script:NeoIPCPlayDataStageKeyByName[[string]$stage.name]
        if ($key) { $stageKeyToId[$key] = [string]$stage.id; $stageIdToKey[[string]$stage.id] = $key }
        foreach ($psde in @($stage.programStageDataElements)) {
            $de = $psde.dataElement
            if ($de -and $de.code) { $deCodeToId[[string]$de.code] = [string]$de.id; $deIdToCode[[string]$de.id] = [string]$de.code }
        }
    }

    $ouCodeToId = @{}; $ouIdToCode = @{}
    $ouFilters = @()
    if ($OrgUnitCode) { $ouFilters += "code:in:[$((@($OrgUnitCode | Where-Object { $_ } | Select-Object -Unique)) -join ',')]" }
    if ($OrgUnitId) { $ouFilters += "id:in:[$((@($OrgUnitId | Where-Object { $_ } | Select-Object -Unique)) -join ',')]" }
    foreach ($f in $ouFilters) {
        $ouResp = Invoke-NeoIPCDhis2Get @endpoint -Path 'api/organisationUnits' -Fields 'id', 'code' -Filter $f
        foreach ($ou in @($ouResp.organisationUnits)) {
            if ($ou.code) { $ouCodeToId[[string]$ou.code] = [string]$ou.id; $ouIdToCode[[string]$ou.id] = [string]$ou.code }
        }
    }

    @{
        ProgramId         = [string]$program.id
        TrackedEntityType = [string]$program.trackedEntityType.id
        TeaCodeToId       = $teaCodeToId
        TeaIdToCode       = $teaIdToCode
        DeCodeToId        = $deCodeToId
        DeIdToCode        = $deIdToCode
        StageKeyToId      = $stageKeyToId
        StageIdToKey      = $stageIdToKey
        OrgUnitCodeToId   = $ouCodeToId
        OrgUnitIdToCode   = $ouIdToCode
    }
}

function Read-NeoIPCPlayDataDirectory {
    <#
    .SYNOPSIS
        Read + validate the committed demo_data CSVs (bulk/ + curated/ tiers) into merged row lists.
    .DESCRIPTION
        Reads the four per-type CSVs from each tier subdirectory that exists (bulk, curated), unions their
        rows, and validates structurally up front (fail here, not late at import): every id is a valid DHIS2
        UID and unique across all tiers per type; each tracked entity carries a non-empty NEOIPC_PATIENT_ID;
        every enrollment.trackedEntity, event.enrollment and eventDataValue.event resolves to a known parent;
        statuses are in the allowed sets and programStage is one of the seven stage keys. Code -> UID
        resolution is NOT done here (that needs the instance code map) — it happens in
        ConvertTo-NeoIPCPlayDataPayload. Returns @{ TrackedEntities; Enrollments; Events; EventDataValues },
        each a list of ordered rows (TrackedEntities rows also carry an Attributes map: TEA code -> value).
        No DHIS2 API calls.
    .PARAMETER Path
        The demo_data directory (containing bulk/ and/or curated/ subdirectories).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Play-data directory not found: '$Path'." }

    $tes = [System.Collections.Generic.List[object]]::new()
    $enrs = [System.Collections.Generic.List[object]]::new()
    $evs = [System.Collections.Generic.List[object]]::new()
    $edvs = [System.Collections.Generic.List[object]]::new()

    $tierDirs = @('bulk', 'curated' | ForEach-Object { Join-Path $Path $_ } | Where-Object { Test-Path -LiteralPath $_ })
    if ($tierDirs.Count -eq 0) { throw "No tier subdirectories (bulk/, curated/) found under '$Path'." }

    foreach ($dir in $tierDirs) {
        $tier = Split-Path -Leaf $dir
        $teFile = Join-Path $dir 'trackedEntities.csv'
        $enrFile = Join-Path $dir 'enrollments.csv'
        $evFile = Join-Path $dir 'events.csv'
        $edvFile = Join-Path $dir 'eventDataValues.csv'
        foreach ($f in $teFile, $enrFile, $evFile, $edvFile) {
            if (-not (Test-Path -LiteralPath $f)) { throw "Play-data CSV not found: '$f' (tier '$tier' is missing a required file)." }
        }
        foreach ($row in (Read-NeoIPCMetadataCsv -Path $teFile)) {
            $attrs = [ordered]@{}
            foreach ($col in $row.Keys) {
                if ($col -in 'id', 'orgUnit') { continue }
                $v = [string]$row[$col]
                if (-not [string]::IsNullOrEmpty($v)) { $attrs[$col] = $v }
            }
            $row['Attributes'] = $attrs
            $row['Tier'] = $tier
            $tes.Add($row)
        }
        foreach ($row in (Read-NeoIPCMetadataCsv -Path $enrFile)) { $row['Tier'] = $tier; $enrs.Add($row) }
        foreach ($row in (Read-NeoIPCMetadataCsv -Path $evFile)) { $row['Tier'] = $tier; $evs.Add($row) }
        foreach ($row in (Read-NeoIPCMetadataCsv -Path $edvFile)) { $row['Tier'] = $tier; $edvs.Add($row) }
    }

    # --- Structural validation (fail loud, named by the offending id/code) ---
    $teIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    # NEOIPC_PATIENT_ID is unique PER ORG UNIT (its trackedEntityAttribute has orgunitScope=true, unique=true),
    # not globally — the generator legitimately reuses DEMO-#### across departments — so the duplicate check is
    # scoped to (orgUnit, patientId). A NUL joins the two so distinct pairs can never collide into one key.
    $seenPatientId = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($te in $tes) {
        $id = [string]$te['id']
        if (-not (Test-NeoIPCMetadataUid -Id $id)) { throw "Tracked entity has an invalid UID '$id' (tier '$($te['Tier'])')." }
        if (-not $teIds.Add($id)) { throw "Duplicate tracked-entity UID '$id'." }
        $patientId = if ($te['Attributes'].Contains('NEOIPC_PATIENT_ID')) { [string]$te['Attributes']['NEOIPC_PATIENT_ID'] } else { '' }
        if ([string]::IsNullOrEmpty($patientId)) { throw "Tracked entity '$id' has no NEOIPC_PATIENT_ID (required identifier)." }
        $ou = [string]$te['orgUnit']
        if (-not $seenPatientId.Add($ou + [char]0 + $patientId)) { throw "Duplicate NEOIPC_PATIENT_ID '$patientId' within department '$ou' (the attribute is unique per org unit)." }
    }
    $enrIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($enr in $enrs) {
        $id = [string]$enr['id']
        if (-not (Test-NeoIPCMetadataUid -Id $id)) { throw "Enrollment has an invalid UID '$id'." }
        if (-not $enrIds.Add($id)) { throw "Duplicate enrollment UID '$id'." }
        $te = [string]$enr['trackedEntity']
        if (-not $teIds.Contains($te)) { throw "Enrollment '$id' references unknown tracked entity '$te'." }
        $status = [string]$enr['status']
        if ($status -notin $script:NeoIPCPlayDataEnrollmentStatus) { throw "Enrollment '$id' has invalid status '$status' (expected one of $($script:NeoIPCPlayDataEnrollmentStatus -join ', '))." }
    }
    $evIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($ev in $evs) {
        $id = [string]$ev['id']
        if (-not (Test-NeoIPCMetadataUid -Id $id)) { throw "Event has an invalid UID '$id'." }
        if (-not $evIds.Add($id)) { throw "Duplicate event UID '$id'." }
        $enr = [string]$ev['enrollment']
        if (-not $enrIds.Contains($enr)) { throw "Event '$id' references unknown enrollment '$enr'." }
        $stage = [string]$ev['programStage']
        if ($stage -notin $script:NeoIPCPlayDataStageKeyByName.Values) { throw "Event '$id' has unknown programStage key '$stage' (expected one of $($script:NeoIPCPlayDataStageKeyByName.Values -join ', '))." }
        $status = [string]$ev['status']
        if ($status -notin $script:NeoIPCPlayDataEventStatus) { throw "Event '$id' has invalid status '$status' (expected one of $($script:NeoIPCPlayDataEventStatus -join ', '))." }
    }
    foreach ($edv in $edvs) {
        $ev = [string]$edv['event']
        if (-not $evIds.Contains($ev)) { throw "Event data value references unknown event '$ev' (dataElement '$([string]$edv['dataElement'])')." }
    }

    @{ TrackedEntities = $tes; Enrollments = $enrs; Events = $evs; EventDataValues = $edvs }
}

function ConvertTo-NeoIPCPlayDataPayload {
    <#
    .SYNOPSIS
        Assemble a /api/tracker payload from validated play-data rows + an instance code map (pure, no API).
    .DESCRIPTION
        Resolves every code handle (org-unit code, TEA code, stage key, data-element code) to its instance UID
        via the supplied map, nests enrollments under their tracked entity and events + data values under their
        enrollment, and returns @{ trackedEntities = @(...) } ready to POST. Committed row ids become the
        payload's trackedEntity / enrollment / event UIDs, so a re-import upserts (CREATE_AND_UPDATE) rather
        than duplicating. An unresolvable code fails loud, naming the code. completedAt is emitted only when
        present (an ACTIVE enrollment / event carries none). With -OrgUnitCode, only tracked entities in those
        departments are included (their sub-tree follows). Pure: testable offline with a hand-built map.
    .PARAMETER Rows
        The @{ TrackedEntities; Enrollments; Events; EventDataValues } from Read-NeoIPCPlayDataDirectory.
    .PARAMETER Maps
        The code map from Get-NeoIPCPlayDataCodeMap (ProgramId, TrackedEntityType, *CodeToId, StageKeyToId).
    .PARAMETER OrgUnitCode
        Optional department-code filter — include only tracked entities whose orgUnit is listed.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Rows,
        [Parameter(Mandatory)][hashtable]$Maps,
        [string[]]$OrgUnitCode
    )
    $ouFilter = if ($OrgUnitCode) { [System.Collections.Generic.HashSet[string]]::new([string[]]@($OrgUnitCode)) } else { $null }

    function Resolve-Ou([string]$code) {
        if (-not $Maps.OrgUnitCodeToId.ContainsKey($code)) { throw "Play data references org unit '$code', which the instance code map did not resolve." }
        $Maps.OrgUnitCodeToId[$code]
    }

    # Index children by parent for O(1) nesting.
    $enrByTe = @{}
    foreach ($enr in $Rows.Enrollments) {
        $te = [string]$enr['trackedEntity']
        if (-not $enrByTe.ContainsKey($te)) { $enrByTe[$te] = [System.Collections.Generic.List[object]]::new() }
        $enrByTe[$te].Add($enr)
    }
    $evByEnr = @{}
    foreach ($ev in $Rows.Events) {
        $enr = [string]$ev['enrollment']
        if (-not $evByEnr.ContainsKey($enr)) { $evByEnr[$enr] = [System.Collections.Generic.List[object]]::new() }
        $evByEnr[$enr].Add($ev)
    }
    $dvByEv = @{}
    foreach ($dv in $Rows.EventDataValues) {
        $ev = [string]$dv['event']
        if (-not $dvByEv.ContainsKey($ev)) { $dvByEv[$ev] = [System.Collections.Generic.List[object]]::new() }
        $dvByEv[$ev].Add($dv)
    }

    $trackedEntities = [System.Collections.Generic.List[object]]::new()
    foreach ($te in $Rows.TrackedEntities) {
        $teId = [string]$te['id']
        $ouCode = [string]$te['orgUnit']
        if ($ouFilter -and -not $ouFilter.Contains($ouCode)) { continue }
        $ouId = Resolve-Ou $ouCode

        $attributes = [System.Collections.Generic.List[object]]::new()
        foreach ($code in $te['Attributes'].Keys) {
            if (-not $Maps.TeaCodeToId.ContainsKey($code)) { throw "Tracked entity '$teId' uses TEA code '$code', which the instance code map did not resolve." }
            $attributes.Add([ordered]@{ attribute = $Maps.TeaCodeToId[$code]; value = [string]$te['Attributes'][$code] })
        }

        $enrollments = [System.Collections.Generic.List[object]]::new()
        foreach ($enr in @($enrByTe[$teId])) {
            if (-not $enr) { continue }
            $enrId = [string]$enr['id']
            $enrOu = Resolve-Ou ([string]$enr['orgUnit'])
            $enrObj = [ordered]@{
                enrollment    = $enrId
                trackedEntity = $teId
                program       = $Maps.ProgramId
                orgUnit       = $enrOu
                enrolledAt    = [string]$enr['enrolledAt']
                occurredAt    = [string]$enr['occurredAt']
                status        = [string]$enr['status']
            }
            if (-not [string]::IsNullOrEmpty([string]$enr['completedAt'])) { $enrObj['completedAt'] = [string]$enr['completedAt'] }

            $events = [System.Collections.Generic.List[object]]::new()
            foreach ($ev in @($evByEnr[$enrId])) {
                if (-not $ev) { continue }
                $evId = [string]$ev['id']
                $stageKey = [string]$ev['programStage']
                if (-not $Maps.StageKeyToId.ContainsKey($stageKey)) { throw "Event '$evId' uses stage key '$stageKey', which the instance code map did not resolve." }
                $dataValues = [System.Collections.Generic.List[object]]::new()
                foreach ($dv in @($dvByEv[$evId])) {
                    if (-not $dv) { continue }
                    $deCode = [string]$dv['dataElement']
                    if (-not $Maps.DeCodeToId.ContainsKey($deCode)) { throw "Event '$evId' uses data-element code '$deCode', which the instance code map did not resolve." }
                    $dataValues.Add([ordered]@{ dataElement = $Maps.DeCodeToId[$deCode]; value = [string]$dv['value'] })
                }
                $evObj = [ordered]@{
                    event        = $evId
                    programStage = $Maps.StageKeyToId[$stageKey]
                    orgUnit      = Resolve-Ou ([string]$ev['orgUnit'])
                    occurredAt   = [string]$ev['occurredAt']
                    status       = [string]$ev['status']
                    dataValues   = @($dataValues.ToArray())
                }
                if (-not [string]::IsNullOrEmpty([string]$ev['completedAt'])) { $evObj['completedAt'] = [string]$ev['completedAt'] }
                $events.Add($evObj)
            }
            $enrObj['events'] = @($events.ToArray())
            $enrollments.Add($enrObj)
        }

        $trackedEntities.Add([ordered]@{
                trackedEntity     = $teId
                trackedEntityType = $Maps.TrackedEntityType
                orgUnit           = $ouId
                attributes        = @($attributes.ToArray())
                enrollments       = @($enrollments.ToArray())
            })
    }

    @{ trackedEntities = @($trackedEntities.ToArray()) }
}

function ConvertTo-NeoIPCPlayDataRow {
    <#
    .SYNOPSIS
        Serialize a generator -DryRun tracker payload (UID-keyed) back into code-keyed play-data CSV rows.
    .DESCRIPTION
        The reverse of ConvertTo-NeoIPCPlayDataPayload, for Export-NeoIPCPlayDataCsv (the bulk re-freeze).
        Reverse-maps every UID (org unit, TEA, stage, data element) to its code via the supplied map and mints
        a deterministic committed UID for each tracked entity / enrollment / event (SHA-256 of a natural key,
        via New-NeoIPCMetadataUid) so a re-freeze produces stable ids within a snapshot. The TE natural key is
        the org-unit code + NEOIPC_PATIENT_ID (patient identifiers repeat per department in the generator, so
        the org unit disambiguates); enrollment/event keys extend it with the enrolment date + a within-parent
        index. Returns @{ TrackedEntities; Enrollments; Events; EventDataValues } — lists of ordered rows ready
        to write. A UID absent from the reverse map fails loud. No DHIS2 API calls.
    .PARAMETER Payload
        One parsed generator payload object (has .trackedEntities), or an array of them, merged in order.
    .PARAMETER Maps
        The code map from Get-NeoIPCPlayDataCodeMap (reverse maps: *IdToCode, StageIdToKey).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][object[]]$Payload,
        [Parameter(Mandatory)][hashtable]$Maps
    )
    $teRows = [System.Collections.Generic.List[object]]::new()
    $enrRows = [System.Collections.Generic.List[object]]::new()
    $evRows = [System.Collections.Generic.List[object]]::new()
    $edvRows = [System.Collections.Generic.List[object]]::new()

    function Resolve-OuCode([string]$id) {
        if (-not $Maps.OrgUnitIdToCode.ContainsKey($id)) { throw "Generator payload references org-unit UID '$id', which the instance code map did not reverse-resolve." }
        $Maps.OrgUnitIdToCode[$id]
    }

    foreach ($p in $Payload) {
        foreach ($te in @($p.trackedEntities)) {
            $ouCode = Resolve-OuCode ([string]$te.orgUnit)
            $attrs = @{}
            foreach ($a in @($te.attributes)) {
                if (-not $Maps.TeaIdToCode.ContainsKey([string]$a.attribute)) { throw "Generator payload references TEA UID '$([string]$a.attribute)', which the instance code map did not reverse-resolve." }
                $attrs[$Maps.TeaIdToCode[[string]$a.attribute]] = [string]$a.value
            }
            $patientId = if ($attrs.ContainsKey('NEOIPC_PATIENT_ID')) { [string]$attrs['NEOIPC_PATIENT_ID'] } else { throw "Generator payload has a tracked entity in '$ouCode' with no NEOIPC_PATIENT_ID." }
            $teUid = New-NeoIPCMetadataUid -Type 'trackedEntities' -NaturalKey "$ouCode|$patientId"

            $teRow = [ordered]@{ id = $teUid; orgUnit = $ouCode }
            foreach ($k in $attrs.Keys) { $teRow[$k] = $attrs[$k] }
            $teRows.Add($teRow)

            $enrIndex = 0
            foreach ($enr in @($te.enrollments)) {
                $enrolledAt = [string]$enr.enrolledAt
                $enrUid = New-NeoIPCMetadataUid -Type 'enrollments' -NaturalKey "$ouCode|$patientId|$enrolledAt|$enrIndex"
                $enrRows.Add([ordered]@{
                        id           = $enrUid
                        trackedEntity = $teUid
                        orgUnit      = Resolve-OuCode ([string]$enr.orgUnit)
                        enrolledAt   = $enrolledAt
                        occurredAt   = [string]$enr.occurredAt
                        status       = [string]$enr.status
                        completedAt  = if ($enr.PSObject.Properties.Name -contains 'completedAt') { [string]$enr.completedAt } else { '' }
                    })
                $evIndex = 0
                foreach ($ev in @($enr.events)) {
                    $stageId = [string]$ev.programStage
                    if (-not $Maps.StageIdToKey.ContainsKey($stageId)) { throw "Generator payload references stage UID '$stageId', which the instance code map did not reverse-resolve." }
                    $stageKey = $Maps.StageIdToKey[$stageId]
                    $occurredAt = [string]$ev.occurredAt
                    $evUid = New-NeoIPCMetadataUid -Type 'events' -NaturalKey "$enrUid|$stageKey|$occurredAt|$evIndex"
                    $evRows.Add([ordered]@{
                            id           = $evUid
                            enrollment   = $enrUid
                            programStage = $stageKey
                            orgUnit      = Resolve-OuCode ([string]$ev.orgUnit)
                            occurredAt   = $occurredAt
                            status       = [string]$ev.status
                            completedAt  = if ($ev.PSObject.Properties.Name -contains 'completedAt') { [string]$ev.completedAt } else { '' }
                        })
                    foreach ($dv in @($ev.dataValues)) {
                        if (-not $Maps.DeIdToCode.ContainsKey([string]$dv.dataElement)) { throw "Generator payload references data-element UID '$([string]$dv.dataElement)', which the instance code map did not reverse-resolve." }
                        $edvRows.Add([ordered]@{ event = $evUid; dataElement = $Maps.DeIdToCode[[string]$dv.dataElement]; value = [string]$dv.value })
                    }
                    $evIndex++
                }
                $enrIndex++
            }
        }
    }
    @{ TrackedEntities = $teRows; Enrollments = $enrRows; Events = $evRows; EventDataValues = $edvRows }
}

function Write-NeoIPCPlayDataCsv {
    <#
    .SYNOPSIS
        Write ordered-dictionary rows to a CSV with an explicit column order (RFC 4180, LF, UTF-8 no BOM).
    .DESCRIPTION
        The play-data writer for Export-NeoIPCPlayDataCsv. Emits the header + one line per row, taking each
        cell by column name (a column absent from a row is written blank), quoting only cells that contain a
        comma / quote / CR / LF (matching the unquoted style of the committed metadata CSVs). LF line endings
        and UTF-8 without BOM keep the files stable across platforms and match New-NeoIPCMetadataPackage's file
        writes. No DHIS2 API calls.
    .PARAMETER Path
        Destination CSV path.
    .PARAMETER Column
        The ordered column names (the header, and the per-row cell order).
    .PARAMETER Row
        The ordered-dictionary rows (may be empty — a header-only file is written).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$Column,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Row
    )
    $quote = {
        param([string]$v)
        if ($null -eq $v) { $v = '' }
        if ($v -match '[",\r\n]') { '"' + ($v -replace '"', '""') + '"' } else { $v }
    }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append((($Column | ForEach-Object { & $quote $_ }) -join ',')).Append("`n")
    foreach ($r in $Row) {
        $cells = foreach ($c in $Column) { & $quote ($(if ($r.Contains($c)) { [string]$r[$c] } else { '' })) }
        [void]$sb.Append(($cells -join ',')).Append("`n")
    }
    [System.IO.File]::WriteAllText($Path, $sb.ToString(), [System.Text.UTF8Encoding]::new($false))
}
