<#
.SYNOPSIS
Query DHIS2 tracked entity (patient) attributes.

.DESCRIPTION
Returns one flat PSCustomObject per tracked entity with demographic attributes
(NeoIPC-ID, sex, birth weight, gestational age).

.PARAMETER OrgUnitId
Organisation unit ID. Accepts pipeline input from Read-OrgUnitInfo (binds to Id property).
#>
function Read-PatientInfo {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [Alias('Id')]
        [string]$OrgUnitId,

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

        # Resolve the NeoIPC Core program ID once
        $metaParams = @{
            Auth = $Auth
            Path = 'api/metadata'
            QueryParameters = @{
                'programs:fields' = 'id'
                'programs:filter' = 'code:eq:NEOIPC_CORE'
            }
        }
        if ($Scheme)   { $metaParams.Scheme   = $Scheme }
        if ($Hostname) { $metaParams.Hostname = $Hostname }
        if ($Port)     { $metaParams.Port     = $Port }

        $metadata = Invoke-NeoipcDhis2Get @metaParams
        $programId = $metadata.programs[0].id
    }

    process {
        $fields = @(
            'trackedEntity', 'orgUnit', 'createdAt', 'updatedAt',
            'attributes[code,value]'
        )

        $queryParams = @{
            'program'     = $programId
            'skipPaging'  = 'true'
        }

        if ($OrgUnitId) {
            $queryParams['orgUnit'] = $OrgUnitId
            $queryParams['ouMode'] = 'SELECTED'
        } else {
            $queryParams['ouMode'] = 'ACCESSIBLE'
        }

        $getParams = @{
            Auth            = $Auth
            Path            = 'api/tracker/trackedEntities'
            Fields          = $fields
            QueryParameters = $queryParams
        }
        if ($Scheme)   { $getParams.Scheme   = $Scheme }
        if ($Hostname) { $getParams.Hostname = $Hostname }
        if ($Port)     { $getParams.Port     = $Port }

        $resp = Invoke-NeoipcDhis2Get @getParams

        foreach ($te in $resp.instances) {
            $attrs = @{}
            foreach ($a in $te.attributes) {
                $attrs[$a.code] = $a.value
            }

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
            }
        }
    }
}

<#
.SYNOPSIS
Query DHIS2 enrollment (admission) records.

.DESCRIPTION
Returns one flat PSCustomObject per enrollment. No nested Events property —
use Read-EventSummary piped from this function's output to get events.

.PARAMETER PartnerCodes
Filter to specific partner site codes. Accepts pipeline input from
Read-OrgUnitInfo (binds to Code property).
#>
function Read-EnrolmentInfo {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromPipelineByPropertyName)]
        [Alias('Code')]
        [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
            $serverKey = Get-NeoipcServerKey -Scheme $fakeBoundParameters['Scheme'] -Hostname $fakeBoundParameters['Hostname'] -Port $fakeBoundParameters['Port']
            $cacheDir = Join-Path (Split-Path (Split-Path (Split-Path (Split-Path $PSScriptRoot)))) 'data' 'local' $serverKey
            $cacheFile = Join-Path $cacheDir 'site-codes.txt'
            if (Test-Path $cacheFile) {
                Get-Content $cacheFile | Where-Object { $_ -like "$wordToComplete*" }
            }
        })]
        [string[]]$PartnerCodes,

        [Parameter()]
        [string]$NeoIpcId,

        [Parameter()]
        [datetime]$AdmissionDateFrom,

        [Parameter()]
        [datetime]$AdmissionDateTo,

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

        # Resolve metadata once
        $metaQueryParams = @{
            'programs:fields'            = 'id'
            'programs:filter'            = 'code:eq:NEOIPC_CORE'
            'organisationUnits:fields'   = 'id,code'
            'programStages:fields'       = 'id,name'
        }

        $metaParams = @{
            Auth            = $Auth
            Path            = 'api/metadata'
            QueryParameters = $metaQueryParams
        }
        if ($Scheme)   { $metaParams.Scheme   = $Scheme }
        if ($Hostname) { $metaParams.Hostname = $Hostname }
        if ($Port)     { $metaParams.Port     = $Port }

        $metadata = Invoke-NeoipcDhis2Get @metaParams

        $script:orgUnitMap = @{}
        foreach ($ou in $metadata.organisationUnits) {
            $script:orgUnitMap[$ou.id] = $ou.code
        }

        $script:programStageMap = @{}
        foreach ($ps in $metadata.programStages) {
            $script:programStageMap[$ps.id] = $ps.name
        }

        $script:programId = $metadata.programs[0].id

        # If NeoIpcId filtering is needed, resolve the attribute ID
        if ($NeoIpcId) {
            $attrMeta = Invoke-NeoipcDhis2Get @{
                Auth            = $Auth
                Path            = 'api/metadata'
                QueryParameters = @{
                    'trackedEntityAttributes:fields' = 'id'
                    'trackedEntityAttributes:filter' = 'code:eq:NEOIPC_PATIENT_ID'
                }
            }
            $script:patientIdAttrId = $attrMeta.trackedEntityAttributes[0].id
        }

        # Build URL for the edit link
        $effectiveScheme = if ($Scheme) { $Scheme } else { 'https' }
        $effectiveHost = if ($Hostname) { $Hostname } else { 'neoipc.charite.de' }
        $script:baseUrl = "${effectiveScheme}://${effectiveHost}"
        if ($Port) { $script:baseUrl += ":$Port" }

        $script:collectedPartnerCodes = [System.Collections.Generic.List[string]]::new()
    }

    process {
        if ($PartnerCodes) {
            foreach ($pc in $PartnerCodes) {
                $script:collectedPartnerCodes.Add($pc)
            }
        }
    }

    end {
        # If invoked via pipeline but no objects arrived, produce no output
        # rather than falling through to ouMode=ACCESSIBLE (which returns everything)
        if ($MyInvocation.ExpectingInput -and $script:collectedPartnerCodes.Count -eq 0) { return }
        $fields = @(
            'trackedEntity',
            'attributes[code,value]',
            'enrollments[enrollment,enrolledAt,status,orgUnit,createdAt,createdAtClient,updatedAt,updatedAtClient,completedAt,completedBy,followUp,storedBy,createdBy[username],updatedBy[username],notes[value],events[event,programStage,status,occurredAt]]'
        )

        $queryParams = @{
            'skipPaging' = 'true'
            'program'    = $script:programId
        }

        if ($script:collectedPartnerCodes.Count -gt 0) {
            # Resolve org unit IDs from codes
            $ouIds = @()
            foreach ($ou in $metadata.organisationUnits) {
                if ($script:collectedPartnerCodes -contains $ou.code) {
                    $ouIds += $ou.id
                }
            }
            if ($ouIds.Count -gt 0) {
                $queryParams['orgUnit'] = $ouIds -join ';'
                $queryParams['ouMode'] = 'SELECTED'
            } else {
                $queryParams['ouMode'] = 'ACCESSIBLE'
            }
        } else {
            $queryParams['ouMode'] = 'ACCESSIBLE'
        }

        if ($AdmissionDateTo) {
            $queryParams['enrollmentEnrolledBefore'] = $AdmissionDateTo.ToString('yyyy-MM-dd')
        }
        if ($AdmissionDateFrom) {
            $queryParams['enrollmentEnrolledAfter'] = $AdmissionDateFrom.ToString('yyyy-MM-dd')
        }
        if ($NeoIpcId) {
            $escaped = $NeoIpcId -replace ',','/, ' -replace ':','/:' -replace '/','//'
            $queryParams['filter'] = "$($script:patientIdAttrId):eq:$escaped"
        }

        $getParams = @{
            Auth            = $Auth
            Path            = 'api/tracker/trackedEntities'
            Fields          = $fields
            QueryParameters = $queryParams
        }
        if ($Scheme)   { $getParams.Scheme   = $Scheme }
        if ($Hostname) { $getParams.Hostname = $Hostname }
        if ($Port)     { $getParams.Port     = $Port }

        $resp = Invoke-NeoipcDhis2Get @getParams

        foreach ($te in $resp.instances) {
            # Extract NeoIPC patient ID from attributes
            $neoipcId = $null
            foreach ($attr in $te.attributes) {
                if ($attr.code -eq 'NEOIPC_PATIENT_ID') {
                    $neoipcId = $attr.value
                    break
                }
            }

            foreach ($enrollment in $te.enrollments) {
                # Store event data in module-scoped cache for Read-EventSummary
                $eventData = @()
                foreach ($e in $enrollment.events) {
                    $eventData += [PSCustomObject]@{
                        EventId        = $e.event
                        EnrollmentId   = $enrollment.enrollment
                        ProgramStageId = $e.programStage
                        Type           = $script:programStageMap[$e.programStage]
                        Status         = $e.status
                        OccurredAt     = $e.occurredAt
                        PartnerCode    = $script:orgUnitMap[$enrollment.orgUnit]
                        NeoIpcId       = $neoipcId
                    }
                }

                [PSCustomObject]@{
                    Id              = $enrollment.enrollment
                    TrackedEntityId = $te.trackedEntity
                    NeoIpcId        = $neoipcId
                    AdmissionDate   = $enrollment.enrolledAt
                    Status          = $enrollment.status
                    PartnerCode     = $script:orgUnitMap[$enrollment.orgUnit]
                    EventCount      = $eventData.Count
                    CreatedAt       = $enrollment.createdAt
                    CreatedAtClient = $enrollment.createdAtClient
                    UpdatedAt       = $enrollment.updatedAt
                    UpdatedAtClient = $enrollment.updatedAtClient
                    CompletedAt     = $enrollment.completedAt
                    CompletedBy     = $enrollment.completedBy
                    FollowUp        = $enrollment.followUp
                    StoredBy        = $enrollment.storedBy
                    CreatedBy       = $enrollment.createdBy.username
                    UpdatedBy       = $enrollment.updatedBy.username
                    Notes           = $enrollment.notes.value
                    DashboardUrl    = "$($script:baseUrl)/dhis-web-tracker-capture/index.html#/dashboard?tei=$($te.trackedEntity)&program=$($script:programId)&ou=$($enrollment.orgUnit)"
                    # Hidden property for Read-EventSummary to consume
                    _EventData      = $eventData
                }
            }
        }
    }
}

<#
.SYNOPSIS
Extract event summaries from enrollment objects.

.DESCRIPTION
Accepts enrollment objects from Read-EnrolmentInfo via pipeline and emits one
flat PSCustomObject per event. No additional API call is needed — event data
is already present in the enrollment API response.

.PARAMETER EventType
Filter to a specific event type (e.g. 'Admission', 'Primary Sepsis/BSI').

.PARAMETER EnrollmentId
Enrollment ID. Accepts pipeline input from Read-EnrolmentInfo (binds to Id property).
#>
function Read-EventSummary {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [Alias('Id')]
        [string]$EnrollmentId,

        [Parameter(ValueFromPipeline)]
        [PSObject]$InputObject,

        [Parameter()]
        [ValidateSet('Admission','Necrotizing enterocolitis','Pneumonia','Primary Sepsis/BSI',
            'Surgical Procedure','Surgical Site Infection','Surveillance-End')]
        [string]$EventType
    )

    process {
        $events = $null

        # Try to get event data from the piped enrollment object
        if ($InputObject -and $InputObject.PSObject.Properties['_EventData']) {
            $events = $InputObject._EventData
        }

        if (-not $events) {
            Write-Warning "No event data available for enrollment '$EnrollmentId'. Pipe from Read-EnrolmentInfo to get event data."
            return
        }

        foreach ($e in $events) {
            if ($EventType -and $e.Type -ne $EventType) { continue }

            [PSCustomObject]@{
                EventId      = $e.EventId
                EnrollmentId = $e.EnrollmentId
                Type         = $e.Type
                Status       = $e.Status
                OccurredAt   = $e.OccurredAt
                PartnerCode  = $e.PartnerCode
                NeoIpcId     = $e.NeoIpcId
            }
        }
    }
}
