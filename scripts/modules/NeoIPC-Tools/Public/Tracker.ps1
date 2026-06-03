<#
.SYNOPSIS
Query DHIS2 tracked entity (patient) attributes.

.DESCRIPTION
Returns one flat PSCustomObject per tracked entity with demographic attributes
(NeoIPC-ID, sex, birth weight, gestational age) and the list of child
enrolment UIDs.

.PARAMETER TrackedEntityId
Filter by tracked-entity UID. Pipeline-bound by property name.

.PARAMETER NeoIpcId
Filter by patient identifier (NEOIPC_PATIENT_ID attribute value).
Pipeline-bound by property name.

.PARAMETER OrgUnitId
Filter by org-unit UID. Pipeline-bound by property name.

.PARAMETER OrgUnitCode
Filter by org-unit code. Pipeline-bound by property name (e.g. from
Read-OrgUnitInfo.OrgUnitCode).
#>
function Read-PatientInfo {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [string[]]$TrackedEntityId,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string[]]$NeoIpcId,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string[]]$OrgUnitId,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
            $serverKey = Get-NeoipcServerKey -Scheme $fakeBoundParameters['Scheme'] -Hostname $fakeBoundParameters['Hostname'] -Port $fakeBoundParameters['Port']
            $cacheDir = Join-Path $script:NeoipcRepoRoot 'data' $serverKey
            $cacheFile = Join-Path $cacheDir 'site-codes.txt'
            if (Test-Path $cacheFile) {
                Get-Content $cacheFile | Where-Object { $_ -like "$wordToComplete*" }
            }
        })]
        [string[]]$OrgUnitCode,

        [Parameter()]
        [hashtable]$Auth,

        [Parameter()]
        [string]$Token = $env:NEOIPC_DHIS2_TOKEN,

        [Parameter()] [string]$Scheme = $null,
        [Parameter()] [string]$Hostname = $null,
        [Parameter()] [Nullable[int]]$Port = $null
    )

    begin {
        if (-not $Auth) {
            $Auth = Resolve-NeoipcAuth -Token $Token
        }

        # Resolve metadata once: program UID always; OU code map only when
        # -OrgUnitCode is supplied; patient-ID attribute UID only when
        # -NeoIpcId is supplied (decided in `end` once binding settles).
        $script:Auth_local = $Auth
        $script:metaScheme   = $Scheme
        $script:metaHostname = $Hostname
        $script:metaPort     = $Port

        $script:collectedTrackedEntityIds = [System.Collections.Generic.List[string]]::new()
        $script:collectedNeoIpcIds        = [System.Collections.Generic.List[string]]::new()
        $script:collectedOrgUnitIds       = [System.Collections.Generic.List[string]]::new()
        $script:collectedOrgUnitCodes     = [System.Collections.Generic.List[string]]::new()
    }

    process {
        if ($TrackedEntityId) { foreach ($v in $TrackedEntityId) { $script:collectedTrackedEntityIds.Add($v) } }
        if ($NeoIpcId)        { foreach ($v in $NeoIpcId)        { $script:collectedNeoIpcIds.Add($v) } }
        if ($OrgUnitId)       { foreach ($v in $OrgUnitId)       { $script:collectedOrgUnitIds.Add($v) } }
        if ($OrgUnitCode)     { foreach ($v in $OrgUnitCode)     { $script:collectedOrgUnitCodes.Add($v) } }
    }

    end {
        if ($MyInvocation.ExpectingInput -and
            $script:collectedTrackedEntityIds.Count -eq 0 -and
            $script:collectedNeoIpcIds.Count -eq 0 -and
            $script:collectedOrgUnitIds.Count -eq 0 -and
            $script:collectedOrgUnitCodes.Count -eq 0) {
            return
        }

        # Metadata fetch: conditional fields based on which filters were
        # supplied so we don't pull maps we won't use.
        $metaQueryParams = @{
            'programs:fields' = 'id'
            'programs:filter' = 'code:eq:NEOIPC_CORE'
        }
        if ($script:collectedOrgUnitCodes.Count -gt 0) {
            $metaQueryParams['organisationUnits:fields'] = 'id,code'
        }
        if ($script:collectedNeoIpcIds.Count -gt 0) {
            $metaQueryParams['trackedEntityAttributes:fields'] = 'id'
            $metaQueryParams['trackedEntityAttributes:filter'] = 'code:eq:NEOIPC_PATIENT_ID'
        }
        $metaParams = @{
            Auth            = $script:Auth_local
            Path            = 'api/metadata'
            QueryParameters = $metaQueryParams
        }
        if ($script:metaScheme)   { $metaParams.Scheme   = $script:metaScheme }
        if ($script:metaHostname) { $metaParams.Hostname = $script:metaHostname }
        if ($script:metaPort)     { $metaParams.Port     = $script:metaPort }
        $metadata = Invoke-NeoipcDhis2Get @metaParams

        $programId = $metadata.programs[0].id

        # Resolve -OrgUnitCode → UIDs and merge with -OrgUnitId
        $ouUids = [System.Collections.Generic.List[string]]::new()
        foreach ($id in $script:collectedOrgUnitIds) { $ouUids.Add($id) }
        if ($script:collectedOrgUnitCodes.Count -gt 0) {
            $codeSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$script:collectedOrgUnitCodes)
            foreach ($ou in $metadata.organisationUnits) {
                if ($codeSet.Contains($ou.code)) { $ouUids.Add($ou.id) }
            }
        }

        $fields = @(
            'trackedEntity', 'orgUnit', 'createdAt', 'updatedAt',
            'attributes[code,value]',
            'enrollments[enrollment]'
        )

        $queryParams = @{
            'program'    = $programId
            'skipPaging' = 'true'
        }

        if ($ouUids.Count -gt 0) {
            $queryParams['orgUnit'] = ($ouUids | Sort-Object -Unique) -join ';'
            $queryParams['ouMode']  = 'SELECTED'
        } else {
            $queryParams['ouMode']  = 'ACCESSIBLE'
        }

        if ($script:collectedTrackedEntityIds.Count -gt 0) {
            $queryParams['trackedEntity'] = ($script:collectedTrackedEntityIds | Sort-Object -Unique) -join ';'
        }

        # NeoIpcId → attribute filter (semicolons in values need escaping
        # via DHIS2's filter syntax with `/` quoting)
        $extraFilters = @()
        if ($script:collectedNeoIpcIds.Count -gt 0) {
            $attrId = $metadata.trackedEntityAttributes[0].id
            $escaped = $script:collectedNeoIpcIds | ForEach-Object {
                $_ -replace '/', '//' -replace ',', '/,' -replace ':', '/:'
            }
            $extraFilters += "$($attrId):in:[$($escaped -join ',')]"
        }

        $getParams = @{
            Auth            = $script:Auth_local
            Path            = 'api/tracker/trackedEntities'
            Fields          = $fields
            QueryParameters = $queryParams
        }
        if ($extraFilters.Count -gt 0) { $getParams.Filter = $extraFilters }
        if ($script:metaScheme)   { $getParams.Scheme   = $script:metaScheme }
        if ($script:metaHostname) { $getParams.Hostname = $script:metaHostname }
        if ($script:metaPort)     { $getParams.Port     = $script:metaPort }

        $resp = Invoke-NeoipcDhis2Get @getParams

        foreach ($te in $resp.instances) {
            $attrs = @{}
            foreach ($a in $te.attributes) {
                $attrs[$a.code] = $a.value
            }

            $enrollmentIds = @($te.enrollments | ForEach-Object { $_.enrollment })

            [PSCustomObject]@{
                TrackedEntityId    = $te.trackedEntity
                OrgUnitId          = $te.orgUnit
                NeoIpcId           = $attrs['NEOIPC_PATIENT_ID']
                Sex                = $attrs['NEOIPC_TEA_SEX']
                DeliveryMode       = $attrs['NEOIPC_TEA_DELIVERY_MODE']
                BirthWeight        = $attrs['NEOIPC_TEA_BIRTH_WEIGHT']
                GestationalAge     = $attrs['NEOIPC_TEA_GEST_AGE']
                TotalGestationDays = $attrs['NeoIPC_TEA_TOTAL_GESTATION_DAYS']
                CreatedAt          = $te.createdAt
                UpdatedAt          = $te.updatedAt
                EnrollmentIds      = $enrollmentIds
            }
        }
    }
}

<#
.SYNOPSIS
Query DHIS2 enrolment records via /api/tracker/enrollments.

.DESCRIPTION
Returns one flat PSCustomObject per enrolment. NeoIpcId is intentionally
absent — attribute filters aren't supported on /api/tracker/enrollments,
so the composed pattern is Read-PatientInfo -NeoIpcId | Read-EnrolmentInfo.

.PARAMETER EnrollmentId
Filter by enrolment UID. Pipeline-bound for the reverse pipe
Read-EventInfo | Read-EnrolmentInfo.

.PARAMETER TrackedEntityId
Filter by tracked-entity UID. Pipeline-bound. The server param is
singular per request — the cmdlet loops one call per distinct UID when
multiple are supplied.

.PARAMETER OrgUnitCode
Filter by OU code. Pipeline-bound from Read-OrgUnitInfo.OrgUnitCode.

.PARAMETER OrgUnitId
Filter by OU UID. Pipeline-bound from Read-OrgUnitInfo.OrgUnitId or
similar upstream cmdlets.
#>
function Read-EnrolmentInfo {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [string[]]$EnrollmentId,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string[]]$TrackedEntityId,

        [Parameter(Position = 0, ValueFromPipelineByPropertyName)]
        [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
            $serverKey = Get-NeoipcServerKey -Scheme $fakeBoundParameters['Scheme'] -Hostname $fakeBoundParameters['Hostname'] -Port $fakeBoundParameters['Port']
            $cacheDir = Join-Path $script:NeoipcRepoRoot 'data' $serverKey
            $cacheFile = Join-Path $cacheDir 'site-codes.txt'
            if (Test-Path $cacheFile) {
                Get-Content $cacheFile | Where-Object { $_ -like "$wordToComplete*" }
            }
        })]
        [string[]]$OrgUnitCode,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string[]]$OrgUnitId,

        [Parameter()]
        [datetime]$AdmissionDateFrom,

        [Parameter()]
        [datetime]$AdmissionDateTo,

        [Parameter()]
        [datetime]$UpdatedAfter,

        [Parameter()]
        [hashtable]$Auth,

        [Parameter()]
        [string]$Token = $env:NEOIPC_DHIS2_TOKEN,

        [Parameter()] [string]$Scheme = $null,
        [Parameter()] [string]$Hostname = $null,
        [Parameter()] [Nullable[int]]$Port = $null
    )

    begin {
        if (-not $Auth) {
            $Auth = Resolve-NeoipcAuth -Token $Token
        }
        $script:Auth_local = $Auth

        $effectiveScheme = if ($Scheme) { $Scheme } else { 'https' }
        $effectiveHost   = if ($Hostname) { $Hostname } else { 'neoipc.charite.de' }
        $script:baseUrl  = "${effectiveScheme}://${effectiveHost}"
        if ($Port) { $script:baseUrl += ":$Port" }

        $script:collectedEnrollmentIds    = [System.Collections.Generic.List[string]]::new()
        $script:collectedTrackedEntityIds = [System.Collections.Generic.List[string]]::new()
        $script:collectedOrgUnitCodes     = [System.Collections.Generic.List[string]]::new()
        $script:collectedOrgUnitIds       = [System.Collections.Generic.List[string]]::new()
    }

    process {
        if ($EnrollmentId)     { foreach ($v in $EnrollmentId)     { $script:collectedEnrollmentIds.Add($v) } }
        if ($TrackedEntityId)  { foreach ($v in $TrackedEntityId)  { $script:collectedTrackedEntityIds.Add($v) } }
        if ($OrgUnitCode)      { foreach ($v in $OrgUnitCode)      { $script:collectedOrgUnitCodes.Add($v) } }
        if ($OrgUnitId)        { foreach ($v in $OrgUnitId)        { $script:collectedOrgUnitIds.Add($v) } }
    }

    end {
        if ($MyInvocation.ExpectingInput -and
            $script:collectedEnrollmentIds.Count -eq 0 -and
            $script:collectedTrackedEntityIds.Count -eq 0 -and
            $script:collectedOrgUnitCodes.Count -eq 0 -and
            $script:collectedOrgUnitIds.Count -eq 0) {
            return
        }

        # Metadata: program UID always; OU code map only when -OrgUnitCode is supplied.
        $metaQueryParams = @{
            'programs:fields' = 'id'
            'programs:filter' = 'code:eq:NEOIPC_CORE'
        }
        if ($script:collectedOrgUnitCodes.Count -gt 0) {
            $metaQueryParams['organisationUnits:fields'] = 'id,code'
        }
        $metaParams = @{
            Auth            = $script:Auth_local
            Path            = 'api/metadata'
            QueryParameters = $metaQueryParams
        }
        if ($Scheme)   { $metaParams.Scheme   = $Scheme }
        if ($Hostname) { $metaParams.Hostname = $Hostname }
        if ($Port)     { $metaParams.Port     = $Port }
        $metadata = Invoke-NeoipcDhis2Get @metaParams

        $programId = $metadata.programs[0].id

        # Merge OU codes → UIDs into the OU UID list
        $ouUids = [System.Collections.Generic.List[string]]::new()
        foreach ($id in $script:collectedOrgUnitIds) { $ouUids.Add($id) }
        if ($script:collectedOrgUnitCodes.Count -gt 0) {
            $codeSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$script:collectedOrgUnitCodes)
            foreach ($ou in $metadata.organisationUnits) {
                if ($codeSet.Contains($ou.code)) { $ouUids.Add($ou.id) }
            }
        }

        $fields = @(
            'enrollment','trackedEntity','program','orgUnit',
            'enrolledAt','occurredAt','status',
            'createdAt','updatedAt','storedBy',
            'completedAt','completedBy','followUp',
            'createdBy[username]','updatedBy[username]',
            'notes[value]',
            'events[event]'
        )

        # Common query params used on every request (whether single or per-TE looped)
        $baseQuery = @{
            'program'    = $programId
            'skipPaging' = 'true'
        }
        if ($ouUids.Count -gt 0) {
            $baseQuery['orgUnit'] = ($ouUids | Sort-Object -Unique) -join ';'
            $baseQuery['ouMode']  = 'SELECTED'
        }
        if ($script:collectedEnrollmentIds.Count -gt 0) {
            $baseQuery['enrollment'] = ($script:collectedEnrollmentIds | Sort-Object -Unique) -join ';'
        }
        if ($AdmissionDateFrom) {
            $baseQuery['enrolledAfter'] = $AdmissionDateFrom.ToString('yyyy-MM-dd')
        }
        if ($AdmissionDateTo) {
            $baseQuery['enrolledBefore'] = $AdmissionDateTo.ToString('yyyy-MM-dd')
        }
        if ($UpdatedAfter) {
            $baseQuery['updatedAfter'] = $UpdatedAfter.ToString('yyyy-MM-dd')
        }

        # /api/tracker/enrollments accepts at most one trackedEntity per request.
        # If multiple are supplied, loop one query per UID; otherwise single query.
        $teList = @($script:collectedTrackedEntityIds | Sort-Object -Unique)
        if ($teList.Count -eq 0) { $teList = @($null) }

        foreach ($te in $teList) {
            $queryParams = @{}
            foreach ($k in $baseQuery.Keys) { $queryParams[$k] = $baseQuery[$k] }
            if ($te) { $queryParams['trackedEntity'] = $te }

            $getParams = @{
                Auth            = $script:Auth_local
                Path            = 'api/tracker/enrollments'
                Fields          = $fields
                QueryParameters = $queryParams
            }
            if ($Scheme)   { $getParams.Scheme   = $Scheme }
            if ($Hostname) { $getParams.Hostname = $Hostname }
            if ($Port)     { $getParams.Port     = $Port }

            $resp = Invoke-NeoipcDhis2Get @getParams

            foreach ($enr in $resp.instances) {
                $eventIds = @($enr.events | ForEach-Object { $_.event })

                [PSCustomObject]@{
                    EnrollmentId    = $enr.enrollment
                    TrackedEntityId = $enr.trackedEntity
                    OrgUnitId       = $enr.orgUnit
                    ProgramId       = $enr.program
                    AdmissionDate   = $enr.enrolledAt
                    Status          = $enr.status
                    CreatedAt       = $enr.createdAt
                    UpdatedAt       = $enr.updatedAt
                    CompletedAt     = $enr.completedAt
                    CompletedBy     = $enr.completedBy
                    FollowUp        = $enr.followUp
                    StoredBy        = $enr.storedBy
                    CreatedBy       = $enr.createdBy.username
                    UpdatedBy       = $enr.updatedBy.username
                    Notes           = $enr.notes.value
                    EventIds        = $eventIds
                    DashboardUrl    = "$($script:baseUrl)/dhis-web-tracker-capture/index.html#/dashboard?tei=$($enr.trackedEntity)&program=$programId&ou=$($enr.orgUnit)"
                }
            }
        }
    }
}

<#
.SYNOPSIS
Search DHIS2 events via /api/tracker/events.

.DESCRIPTION
Event-level search cmdlet. Filters server-side by parent IDs and date
range; filters client-side by DataElement (OR-composed across multiple
codes) and by audit-user fields (createdBy.username is not server-side
filterable on tracker events).

.PARAMETER EventId
Filter by event UID. Pipeline-bound.

.PARAMETER OrgUnitCode
Filter by OU code (friendly). Pipeline-bound from
Read-OrgUnitInfo.OrgUnitCode.

.PARAMETER OrgUnitId
Filter by OU UID. Pipeline-bound.

.PARAMETER EnrollmentId
Filter by parent enrolment UID. Pipeline-bound.

.PARAMETER TrackedEntityId
Filter by transitive parent TE UID. Pipeline-bound.

.PARAMETER EventType
Filter by event-type (DHIS2 programStage name).

.PARAMETER ProgramStageId
Filter by program-stage UID (alternate to -EventType).

.PARAMETER DataElementCode
Filter to events that have a non-null value for *any* of the listed DE
codes (OR-composed; applied client-side after fetch). When supplied, the
output object includes a DataValues PSCustomObject keyed by these codes.

.PARAMETER CreatedBy
Filter by username of the event creator. Client-side filter — DHIS2
doesn't support createdBy.username filtering server-side on tracker events.

.PARAMETER UpdatedBy
Filter by username of the most recent event updater. Client-side filter.

.PARAMETER StoredBy
Filter by storedBy username on the event. Client-side filter.
#>
function Read-EventInfo {
    [CmdletBinding()]
    param(
        # --- Self ---
        [Parameter(ValueFromPipelineByPropertyName)]
        [string[]]$EventId,

        # --- Parents ---
        [Parameter(Position = 0, ValueFromPipelineByPropertyName)]
        [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
            $serverKey = Get-NeoipcServerKey -Scheme $fakeBoundParameters['Scheme'] -Hostname $fakeBoundParameters['Hostname'] -Port $fakeBoundParameters['Port']
            $cacheDir = Join-Path $script:NeoipcRepoRoot 'data' $serverKey
            $cacheFile = Join-Path $cacheDir 'site-codes.txt'
            if (Test-Path $cacheFile) {
                Get-Content $cacheFile | Where-Object { $_ -like "$wordToComplete*" }
            }
        })]
        [string[]]$OrgUnitCode,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string[]]$OrgUnitId,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string[]]$EnrollmentId,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string[]]$TrackedEntityId,

        [Parameter()]
        [ValidateSet('Admission','Necrotizing enterocolitis','Pneumonia','Primary Sepsis/BSI',
            'Surgical Procedure','Surgical Site Infection','Surveillance-End')]
        [string]$EventType,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string[]]$ProgramStageId,

        # --- Children ---
        [Parameter()]
        [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
            $serverKey = Get-NeoipcServerKey -Scheme $fakeBoundParameters['Scheme'] -Hostname $fakeBoundParameters['Hostname'] -Port $fakeBoundParameters['Port']
            $cacheDir = Join-Path $script:NeoipcRepoRoot 'data' $serverKey
            $cacheFile = Join-Path $cacheDir 'de-codes.txt'
            if (Test-Path $cacheFile) {
                Get-Content $cacheFile | Where-Object { $_ -like "$wordToComplete*" }
            }
        })]
        [string[]]$DataElementCode,

        # --- Audit users (client-side filters) ---
        [Parameter(ValueFromPipelineByPropertyName)] [string[]]$CreatedBy,
        [Parameter(ValueFromPipelineByPropertyName)] [string[]]$UpdatedBy,
        [Parameter(ValueFromPipelineByPropertyName)] [string[]]$StoredBy,

        # --- Time ---
        [Parameter()] [datetime]$OccurredAfter,
        [Parameter()] [datetime]$OccurredBefore,
        [Parameter()] [datetime]$UpdatedAfter,
        [Parameter()] [datetime]$UpdatedBefore,

        # --- Auth + endpoint ---
        [Parameter()] [hashtable]$Auth,
        [Parameter()] [string]$Token = $env:NEOIPC_DHIS2_TOKEN,
        [Parameter()] [string]$Scheme = $null,
        [Parameter()] [string]$Hostname = $null,
        [Parameter()] [Nullable[int]]$Port = $null
    )

    begin {
        if (-not $Auth) {
            $Auth = Resolve-NeoipcAuth -Token $Token
        }
        $script:Auth_local = $Auth

        $script:collectedEventIds         = [System.Collections.Generic.List[string]]::new()
        $script:collectedOrgUnitCodes     = [System.Collections.Generic.List[string]]::new()
        $script:collectedOrgUnitIds       = [System.Collections.Generic.List[string]]::new()
        $script:collectedEnrollmentIds    = [System.Collections.Generic.List[string]]::new()
        $script:collectedTrackedEntityIds = [System.Collections.Generic.List[string]]::new()
        $script:collectedProgramStageIds  = [System.Collections.Generic.List[string]]::new()
        $script:collectedCreatedBy        = [System.Collections.Generic.List[string]]::new()
        $script:collectedUpdatedBy        = [System.Collections.Generic.List[string]]::new()
        $script:collectedStoredBy         = [System.Collections.Generic.List[string]]::new()
    }

    process {
        if ($EventId)         { foreach ($v in $EventId)         { $script:collectedEventIds.Add($v) } }
        if ($OrgUnitCode)     { foreach ($v in $OrgUnitCode)     { $script:collectedOrgUnitCodes.Add($v) } }
        if ($OrgUnitId)       { foreach ($v in $OrgUnitId)       { $script:collectedOrgUnitIds.Add($v) } }
        if ($EnrollmentId)    { foreach ($v in $EnrollmentId)    { $script:collectedEnrollmentIds.Add($v) } }
        if ($TrackedEntityId) { foreach ($v in $TrackedEntityId) { $script:collectedTrackedEntityIds.Add($v) } }
        if ($ProgramStageId)  { foreach ($v in $ProgramStageId)  { $script:collectedProgramStageIds.Add($v) } }
        if ($CreatedBy)       { foreach ($v in $CreatedBy)       { $script:collectedCreatedBy.Add($v) } }
        if ($UpdatedBy)       { foreach ($v in $UpdatedBy)       { $script:collectedUpdatedBy.Add($v) } }
        if ($StoredBy)        { foreach ($v in $StoredBy)        { $script:collectedStoredBy.Add($v) } }
    }

    end {
        # Empty-input pipeline guard
        if ($MyInvocation.ExpectingInput -and
            $script:collectedEventIds.Count -eq 0 -and
            $script:collectedOrgUnitCodes.Count -eq 0 -and
            $script:collectedOrgUnitIds.Count -eq 0 -and
            $script:collectedEnrollmentIds.Count -eq 0 -and
            $script:collectedTrackedEntityIds.Count -eq 0 -and
            $script:collectedProgramStageIds.Count -eq 0 -and
            $script:collectedCreatedBy.Count -eq 0 -and
            $script:collectedUpdatedBy.Count -eq 0 -and
            $script:collectedStoredBy.Count -eq 0) {
            return
        }

        # Conditional metadata fetch: pull only the maps needed for the
        # supplied friendly-form filters. Program UID always; OU code map
        # when -OrgUnitCode supplied; programStage map when -EventType
        # supplied; DE code map when -DataElementCode supplied.
        $metaQueryParams = @{
            'programs:fields' = 'id'
            'programs:filter' = 'code:eq:NEOIPC_CORE'
        }
        if ($script:collectedOrgUnitCodes.Count -gt 0) {
            $metaQueryParams['organisationUnits:fields'] = 'id,code'
        }
        if ($EventType) {
            $metaQueryParams['programStages:fields'] = 'id,name'
        }
        if ($DataElementCode) {
            $metaQueryParams['dataElements:fields'] = 'id,code'
            $codeList = ($DataElementCode | Sort-Object -Unique) -join ','
            $metaQueryParams['dataElements:filter'] = "code:in:[$codeList]"
        }
        $metaParams = @{
            Auth            = $script:Auth_local
            Path            = 'api/metadata'
            QueryParameters = $metaQueryParams
        }
        if ($Scheme)   { $metaParams.Scheme   = $Scheme }
        if ($Hostname) { $metaParams.Hostname = $Hostname }
        if ($Port)     { $metaParams.Port     = $Port }
        $metadata = Invoke-NeoipcDhis2Get @metaParams

        $programId = $metadata.programs[0].id

        # Resolve -OrgUnitCode → UIDs, merge with -OrgUnitId
        $ouUids = [System.Collections.Generic.List[string]]::new()
        foreach ($id in $script:collectedOrgUnitIds) { $ouUids.Add($id) }
        if ($script:collectedOrgUnitCodes.Count -gt 0) {
            $codeSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$script:collectedOrgUnitCodes)
            foreach ($ou in $metadata.organisationUnits) {
                if ($codeSet.Contains($ou.code)) { $ouUids.Add($ou.id) }
            }
        }

        # Resolve -EventType → programStage UID, merge with -ProgramStageId
        $psUids = [System.Collections.Generic.List[string]]::new()
        foreach ($id in $script:collectedProgramStageIds) { $psUids.Add($id) }
        if ($EventType) {
            foreach ($ps in $metadata.programStages) {
                if ($ps.name -eq $EventType) { $psUids.Add($ps.id); break }
            }
        }

        # Resolve -DataElementCode → UIDs (used both for client-side filter
        # and to build the DataValues output keyed by code)
        $codeToUid = @{}
        $uidToCode = @{}
        if ($DataElementCode) {
            foreach ($de in $metadata.dataElements) {
                $codeToUid[$de.code] = $de.id
                $uidToCode[$de.id]   = $de.code
            }
        }

        # Build query
        $queryParams = @{
            'program'    = $programId
            'skipPaging' = 'true'
        }
        if ($ouUids.Count -gt 0) {
            $queryParams['orgUnit'] = ($ouUids | Sort-Object -Unique) -join ';'
            $queryParams['ouMode']  = 'SELECTED'
        } else {
            $queryParams['ouMode']  = 'ACCESSIBLE'
        }
        if ($psUids.Count -gt 0) {
            # Events endpoint accepts a single programStage; if multiple were
            # requested (unusual), the first wins. (Caller can re-issue.)
            $queryParams['programStage'] = ($psUids | Select-Object -First 1)
        }
        if ($script:collectedEnrollmentIds.Count -gt 0) {
            $queryParams['enrollment'] = ($script:collectedEnrollmentIds | Sort-Object -Unique) -join ';'
        }
        if ($script:collectedTrackedEntityIds.Count -gt 0) {
            $queryParams['trackedEntity'] = ($script:collectedTrackedEntityIds | Sort-Object -Unique) -join ';'
        }
        if ($script:collectedEventIds.Count -gt 0) {
            $queryParams['event'] = ($script:collectedEventIds | Sort-Object -Unique) -join ';'
        }
        if ($OccurredAfter)  { $queryParams['occurredAfter']  = $OccurredAfter.ToString('yyyy-MM-dd') }
        if ($OccurredBefore) { $queryParams['occurredBefore'] = $OccurredBefore.ToString('yyyy-MM-dd') }
        if ($UpdatedAfter)   { $queryParams['updatedAfter']   = $UpdatedAfter.ToString('yyyy-MM-dd') }
        if ($UpdatedBefore)  { $queryParams['updatedBefore']  = $UpdatedBefore.ToString('yyyy-MM-dd') }

        $fields = @(
            'event','enrollment','trackedEntity','orgUnit','programStage',
            'status','occurredAt','createdAt','updatedAt','storedBy',
            'createdBy[username]','updatedBy[username]',
            'dataValues[dataElement,value,storedBy,createdAt,updatedAt,createdBy[username],updatedBy[username]]'
        )

        $getParams = @{
            Auth            = $script:Auth_local
            Path            = 'api/tracker/events'
            Fields          = $fields
            QueryParameters = $queryParams
        }
        if ($Scheme)   { $getParams.Scheme   = $Scheme }
        if ($Hostname) { $getParams.Hostname = $Hostname }
        if ($Port)     { $getParams.Port     = $Port }

        $resp = Invoke-NeoipcDhis2Get @getParams

        # Build hash sets for client-side audit-user filtering
        $filterCreatedBy = if ($script:collectedCreatedBy.Count -gt 0) {
            [System.Collections.Generic.HashSet[string]]::new([string[]]$script:collectedCreatedBy)
        } else { $null }
        $filterUpdatedBy = if ($script:collectedUpdatedBy.Count -gt 0) {
            [System.Collections.Generic.HashSet[string]]::new([string[]]$script:collectedUpdatedBy)
        } else { $null }
        $filterStoredBy = if ($script:collectedStoredBy.Count -gt 0) {
            [System.Collections.Generic.HashSet[string]]::new([string[]]$script:collectedStoredBy)
        } else { $null }

        # Resolved DE UIDs (for client-side OR-filter on dataValues presence)
        $matchDeUids = if ($DataElementCode) {
            [System.Collections.Generic.HashSet[string]]::new([string[]]($codeToUid.Values))
        } else { $null }

        foreach ($e in $resp.instances) {
            $createdByUser = $e.createdBy.username
            $updatedByUser = $e.updatedBy.username

            # Client-side audit filters
            if ($filterCreatedBy -and -not $filterCreatedBy.Contains($createdByUser)) { continue }
            if ($filterUpdatedBy -and -not $filterUpdatedBy.Contains($updatedByUser)) { continue }
            if ($filterStoredBy  -and -not $filterStoredBy.Contains($e.storedBy))    { continue }

            # Client-side DE OR-filter: keep event iff any of the named DEs
            # has a non-null value in this event's dataValues.
            $dataValuesByDeUid = @{}
            foreach ($dv in $e.dataValues) {
                if ($null -ne $dv.value -and '' -ne $dv.value) {
                    $dataValuesByDeUid[$dv.dataElement] = $dv
                }
            }

            if ($matchDeUids) {
                $hasMatch = $false
                foreach ($uid in $matchDeUids) {
                    if ($dataValuesByDeUid.ContainsKey($uid)) { $hasMatch = $true; break }
                }
                if (-not $hasMatch) { continue }
            }

            # Build DataValues PSCustomObject keyed by DE code (only when
            # -DataElementCode was supplied — otherwise omit the property)
            $dataValuesOutput = $null
            if ($DataElementCode) {
                $properties = [ordered]@{}
                foreach ($code in $DataElementCode) {
                    $uid = $codeToUid[$code]
                    if ($uid -and $dataValuesByDeUid.ContainsKey($uid)) {
                        $dv = $dataValuesByDeUid[$uid]
                        $properties[$code] = [PSCustomObject]@{
                            Value             = $dv.value
                            StoredBy          = $dv.storedBy
                            CreatedAt         = $dv.createdAt
                            UpdatedAt         = $dv.updatedAt
                            CreatedByUsername = $dv.createdBy.username
                            UpdatedByUsername = $dv.updatedBy.username
                        }
                    } else {
                        $properties[$code] = $null
                    }
                }
                $dataValuesOutput = [PSCustomObject]$properties
            }

            $obj = [PSCustomObject]@{
                EventId         = $e.event
                EnrollmentId    = $e.enrollment
                TrackedEntityId = $e.trackedEntity
                OrgUnitId       = $e.orgUnit
                ProgramStageId  = $e.programStage
                Status          = $e.status
                OccurredAt      = $e.occurredAt
                CreatedAt       = $e.createdAt
                UpdatedAt       = $e.updatedAt
                StoredBy        = $e.storedBy
                CreatedBy       = $createdByUser
                UpdatedBy       = $updatedByUser
            }
            if ($null -ne $dataValuesOutput) {
                Add-Member -InputObject $obj -MemberType NoteProperty -Name DataValues -Value $dataValuesOutput
            }
            $obj
        }
    }
}
