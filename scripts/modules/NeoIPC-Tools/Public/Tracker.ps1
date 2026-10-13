#Requires -Version 7.6
# The NeoIPC tracker reads: Read-PatientInfo, Read-EnrolmentInfo, and Read-EventInfo read the tracked entities,
# enrolments, and events of the program NEOIPC_CORE within the caller's hierarchy, in the request dialect of the
# instance's DHIS2 version (Private/TrackerDialect.ps1). What they share is in Private/TrackerRead.ps1.

function Read-PatientInfo {
    <#
    .SYNOPSIS
        Read NeoIPC patients: the tracked entities of the program NEOIPC_CORE, with their demographic attributes and their
        NEOIPC_CORE enrolments.
    .DESCRIPTION
        Reads the NEOIPC_CORE patients that DHIS2 lets your account read within your hierarchy: your account's
        data-capture org units and the org units below them. Without a filter it reads every such patient. Each filter
        narrows the read, and the filters of different parameters combine, so that a patient must pass each of them. A
        patient lies in an org unit when it was registered there or its NEOIPC_CORE record is owned there.

        -NeoIpcId looks patients up by their NeoIPC patient ID, which DHIS2 compares ignoring case: 'de-01' also finds
        'DE-01', and patients whose IDs differ only in case are all returned. A patient ID holding ';' is looked up in a
        request of its own. DHIS2 before 2.42.1 may look up a patient ID that holds more than one '/' as another one, so
        on those versions such an ID is refused with an error, and the patient can be selected by its UID instead; an ID
        holding one '/' is looked up in a request of its own there.

        The cmdlet writes an error naming each code or UID that names no org unit in your hierarchy, and each
        tracked-entity value that is no DHIS2 UID. When none of the values given to a parameter names anything, it returns
        nothing rather than read without that filter; an empty pipeline, too, returns nothing.

        The attribute columns hold the values of the attributes with the codes NEOIPC_PATIENT_ID, NEOIPC_TEA_SEX,
        NEOIPC_TEA_DELIVERY_MODE, NEOIPC_TEA_BIRTH_WEIGHT, NEOIPC_TEA_GEST_AGE, and NeoIPC_TEA_TOTAL_GESTATION_DAYS.
        DHIS2 2.43.2 and later leave out the values of attributes your account may not read through their sharing: when
        your account cannot read one of these attributes and a returned patient lacks its value, a warning names the
        attribute, whose column may then be empty although a value exists. -NeoIpcId needs read access to
        NEOIPC_PATIENT_ID.

        DHIS2 lets only an account with data-capture org units and data read access to NEOIPC_CORE read its records;
        without either, the read ends with an error that says which. The cmdlet speaks the request dialect of the
        instance's DHIS2 version (2.40 to 2.43), and a response holding a patient the request did not ask for ends the
        read with an error, since DHIS2 2.42 and later ignore a parameter they do not know and widen the read.
    .PARAMETER TrackedEntityId
        The patients' DHIS2 UIDs (tracked-entity UIDs). Takes TrackedEntityId from the pipeline, as Read-EnrolmentInfo and
        Read-EventInfo emit it.
    .PARAMETER NeoIpcId
        NeoIPC patient IDs (the attribute NEOIPC_PATIENT_ID), compared ignoring case. With -TrackedEntityId, the patients
        with those UIDs whose patient ID is one of these. Takes NeoIpcId from the pipeline.
    .PARAMETER OrgUnitId
        UIDs of org units in your hierarchy: the patients registered in one of them, or whose NEOIPC_CORE record one of them
        owns. Together with -OrgUnitCode it forms one set of org units. Takes OrgUnitId from the pipeline.
    .PARAMETER OrgUnitCode
        Codes of org units in your hierarchy, compared exactly; see -OrgUnitId. Takes OrgUnitCode from the pipeline, as
        Read-OrgUnitInfo emits it, and completes from the local cache that Update-NeoIPCCache.ps1 writes.
    .PARAMETER Auth
        Authentication from Resolve-NeoIPCAuth (a token, or a username and password). Without it, the cmdlet resolves
        the authentication with Resolve-NeoIPCAuth -Token.
    .PARAMETER Token
        A DHIS2 personal access token, used when -Auth is not given; without either, Resolve-NeoIPCAuth decides
        (Get-Help Resolve-NeoIPCAuth).
    .PARAMETER Scheme
        http or https. Default: https.
    .PARAMETER Hostname
        The DHIS2 host. Default: the NEOIPC_DHIS2_HOST environment variable; with neither, the cmdlet stops.
    .PARAMETER Port
        The DHIS2 port. Default: the scheme's.
    .OUTPUTS
        One [pscustomobject] per patient: TrackedEntityId; OrgUnitId, the org unit the patient was registered in;
        NeoIpcId, Sex, DeliveryMode, BirthWeight, GestationalAge, and TotalGestationDays, the attribute values as DHIS2
        stores them; CreatedAt and UpdatedAt, [datetime] in the server's time; and EnrollmentIds, the UIDs of the
        patient's NEOIPC_CORE enrolments.
    .EXAMPLE
        Read-PatientInfo -NeoIpcId 'DEMO-0001' -Hostname dhis2.example.org | Read-EnrolmentInfo -Hostname dhis2.example.org

        Reads the patient with the NeoIPC patient ID DEMO-0001, and then its enrolments.
    .EXAMPLE
        Read-OrgUnitInfo -CountryCode DE | Read-PatientInfo | Group-Object OrgUnitId -NoElement

        Counts the patients of each German department in your hierarchy, the host coming from NEOIPC_DHIS2_HOST.
    .EXAMPLE
        Read-EnrolmentInfo -OrgUnitCode NEO_DE_01 -AdmissionDateFrom 2025-01-01 | Read-PatientInfo

        Reads the patients of the department NEO_DE_01 admitted since 1 January 2025.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
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
                $serverKey = Get-NeoIPCServerKey -Scheme $fakeBoundParameters['Scheme'] -Hostname $fakeBoundParameters['Hostname'] -Port $fakeBoundParameters['Port']
                $cacheDir = Join-Path $script:NeoIPCRepoRoot 'data' $serverKey
                $cacheFile = Join-Path $cacheDir 'site-codes.txt'
                if (Test-Path $cacheFile) {
                    Get-Content $cacheFile | Where-Object { $_ -like "$wordToComplete*" }
                }
            })]
        [string[]]$OrgUnitCode,

        [hashtable]$Auth,
        [string]$Token,
        [string]$Scheme,
        [string]$Hostname,
        [Nullable[int]]$Port
    )

    begin {
        # Per call: a variable of the module scope would carry one call's filters into the next cmdlet of a pipeline.
        $given = @{}
        $explicit = [System.Collections.Generic.List[string]]::new()
        foreach ($name in 'TrackedEntityId', 'NeoIpcId', 'OrgUnitId', 'OrgUnitCode') {
            $given[$name] = [System.Collections.Generic.List[string]]::new()
            if ($PSBoundParameters.ContainsKey($name)) { $explicit.Add($name) }
        }
    }

    process {
        foreach ($v in $TrackedEntityId) { $given['TrackedEntityId'].Add($v) }
        foreach ($v in $NeoIpcId) { $given['NeoIpcId'].Add($v) }
        foreach ($v in $OrgUnitId) { $given['OrgUnitId'].Add($v) }
        foreach ($v in $OrgUnitCode) { $given['OrgUnitCode'].Add($v) }
    }

    end {
        try {
            if (-not (Test-NeoIPCTrackerReadInput -Cmdlet $PSCmdlet -Given $given -Explicit $explicit -ExpectingInput:$MyInvocation.ExpectingInput)) { return }
            $ordinal = [System.StringComparer]::Ordinal
            # The attribute behind each column, by its code; NeoIPC_TEA_TOTAL_GESTATION_DAYS keeps the casing it was created with.
            $columns = [ordered]@{
                NeoIpcId           = 'NEOIPC_PATIENT_ID'
                Sex                = 'NEOIPC_TEA_SEX'
                DeliveryMode       = 'NEOIPC_TEA_DELIVERY_MODE'
                BirthWeight        = 'NEOIPC_TEA_BIRTH_WEIGHT'
                GestationalAge     = 'NEOIPC_TEA_GEST_AGE'
                TotalGestationDays = 'NeoIPC_TEA_TOTAL_GESTATION_DAYS'
            }
            $attributeCodes = [string[]]@($columns.Values)

            if (-not $Auth) { $Auth = Resolve-NeoIPCAuth -Token $Token }
            $endpoint = @{ Auth = $Auth }
            if ($Scheme) { $endpoint.Scheme = $Scheme }
            if ($Hostname) { $endpoint.Hostname = $Hostname }
            if ($null -ne $Port) { $endpoint.Port = $Port }
            $versionText = Get-NeoIPCDhis2VersionText -Endpoint $endpoint
            $dialect = Get-NeoIPCTrackerDialect -Version (ConvertTo-NeoIPCDhis2Version -Text $versionText)
            $names = $dialect.TrackedEntityQuery

            $core = Get-NeoIPCCoreProgram -Endpoint $endpoint -Query @{
                'trackedEntityAttributes:filter' = 'code:in:[{0}]' -f ($attributeCodes -join ',')
                'trackedEntityAttributes:fields' = 'id,code'
            }
            $programId = [string]$core.Program['id']
            $codeByAttribute = [System.Collections.Generic.Dictionary[string, string]]::new($ordinal)
            $attributeByCode = [System.Collections.Generic.Dictionary[string, string]]::new($ordinal)
            foreach ($a in @($core.Metadata['trackedEntityAttributes'])) {
                if ($a -isnot [System.Collections.IDictionary] -or $attributeCodes -cnotcontains [string]$a['code'] -or -not (Test-NeoIPCMetadataUid -Id ([string]$a['id']))) { continue }
                $codeByAttribute[[string]$a['id']] = [string]$a['code']
                $attributeByCode[[string]$a['code']] = [string]$a['id']
            }

            $patientIds = Get-NeoIPCDistinctValue -Value $given['NeoIpcId']
            if ($patientIds.Count -gt 0 -and -not $attributeByCode.ContainsKey('NEOIPC_PATIENT_ID')) {
                throw (New-NeoIPCTrackerReadError -ErrorId 'NoPatientIdAttribute' -Category PermissionDenied -TargetObject 'NEOIPC_PATIENT_ID' `
                        -Message '-NeoIpcId looks patients up by the attribute NEOIPC_PATIENT_ID, which your account cannot read.')
            }
            $orgUnits = Resolve-NeoIPCTrackerReadOrgUnit -Cmdlet $PSCmdlet -Endpoint $endpoint -Code (Get-NeoIPCDistinctValue -Value $given['OrgUnitCode']) `
                -Id (Get-NeoIPCDistinctValue -Value $given['OrgUnitId'])
            if ($orgUnits.Given -and $orgUnits.Ids.Count -eq 0) { return }
            $teIds = Get-NeoIPCDistinctValue -Value $given['TrackedEntityId']
            $trackedEntities = Select-NeoIPCTrackerReadUid -Cmdlet $PSCmdlet -Value $teIds -Noun 'tracked entity'
            if ($teIds.Count -gt 0 -and $trackedEntities.Count -eq 0) { return }

            # The patient-ID filters, one request each: an 'in' filter per chunk of IDs, whose values ';' separates without
            # brackets (with brackets DHIS2 matches nothing or refuses the filter), and an 'eq' filter for each ID an 'in'
            # list cannot carry. Read by UID, the patients' IDs are compared here instead.
            $variants = [System.Collections.Generic.List[object]]::new()
            if ($patientIds.Count -gt 0 -and $trackedEntities.Count -eq 0) {
                $attributeId = $attributeByCode['NEOIPC_PATIENT_ID']
                $inList = [System.Collections.Generic.List[string]]::new()
                $alone = [System.Collections.Generic.List[string]]::new()
                foreach ($p in $patientIds) {
                    # NEOIPC-COMPAT(dhis2-pre-2.42.1-filter-escape): see Test-NeoIPCTrackerFilterValue in Private/TrackerDialect.ps1.
                    if (-not (Test-NeoIPCTrackerFilterValue -Dialect $dialect -Value $p)) {
                        Write-NeoIPCTrackerReadError -Cmdlet $PSCmdlet -ErrorId 'PatientIdRefused' -Category InvalidArgument -TargetObject $p `
                            -Message "DHIS2 $versionText may look the patient ID '$p' up as another one, since it holds more than one '/'; select this patient by its UID."
                        continue
                    }
                    # ';' cannot be escaped inside an 'in' list; before 2.42.1 the escaped slashes of all its values count
                    # together, so an ID holding one goes alone.
                    if ($p.Contains(';') -or (-not $dialect.RestoresFilterSlashes -and $p.Contains('/'))) { $alone.Add($p) } else { $inList.Add($p) }
                }
                $escapedList = [System.Collections.Generic.List[string]]::new()
                $rawByEscaped = [System.Collections.Generic.Dictionary[string, string]]::new($ordinal)
                foreach ($p in $inList) { $e = ConvertTo-NeoIPCTrackerFilterValue -Value $p; $escapedList.Add($e); $rawByEscaped[$e] = $p }
                foreach ($chunk in (Split-NeoIPCList -Value $escapedList.ToArray() -Separator ';')) {
                    $filter = '{0}:in:{1}' -f $attributeId, ($chunk -join ';')
                    $variants.Add([pscustomobject]@{ Filter = $filter; Values = [string[]]@($chunk | ForEach-Object { $rawByEscaped[$_] }) })
                }
                foreach ($p in $alone) {
                    $filter = '{0}:eq:{1}' -f $attributeId, (ConvertTo-NeoIPCTrackerFilterValue -Value $p)
                    $variants.Add([pscustomobject]@{ Filter = $filter; Values = [string[]]@($p) })
                }
                if ($variants.Count -eq 0) { return }
            }
            else { $variants.Add([pscustomobject]@{ Filter = $null; Values = $null }) }

            $requests = [System.Collections.Generic.List[object]]::new()
            foreach ($ouChunk in (Split-NeoIPCOptionalList -Value $orgUnits.Ids -Separator $names.Separator)) {
                foreach ($teChunk in (Split-NeoIPCOptionalList -Value $trackedEntities -Separator $names.Separator)) {
                    foreach ($variant in $variants) {
                        $query = @{ program = $programId; $dialect.OrgUnitMode = 'ACCESSIBLE' }
                        if ($ouChunk.Count -gt 0) { $query[$dialect.OrgUnitMode] = 'SELECTED'; $query[$names.OrgUnits] = $ouChunk -join $names.Separator }
                        if ($teChunk.Count -gt 0) { $query[$names.TrackedEntities] = $teChunk -join $names.Separator }
                        if ($variant.Filter) { $query['filter'] = $variant.Filter }
                        $requests.Add([pscustomobject]@{ Query = $query; OrgUnits = $ouChunk; TrackedEntities = $teChunk; PatientIds = $variant.Values })
                    }
                }
            }

            $fields = @('trackedEntity', 'orgUnit', 'createdAt', 'updatedAt', 'attributes[attribute,code,value]', 'enrollments[enrollment,program]', 'programOwners[orgUnit,program]')
            $patients = [System.Collections.Generic.List[object]]::new()
            $seen = [System.Collections.Generic.HashSet[string]]::new($ordinal)
            foreach ($request in $requests) {
                foreach ($te in (Get-NeoIPCCoreTrackerList -Endpoint $endpoint -Dialect $dialect -Resource 'trackedEntities' -Query $request.Query -Fields $fields)) {
                    $uid = [string]$te['trackedEntity']
                    $owners = [string[]]@(@($te['programOwners']) | Where-Object { $_ -is [System.Collections.IDictionary] -and [string]$_['program'] -ceq $programId } | ForEach-Object { [string]$_['orgUnit'] })
                    $enrolled = @(@($te['enrollments']) | Where-Object { $_ -is [System.Collections.IDictionary] -and [string]$_['program'] -ceq $programId }).Count -gt 0
                    $why = if ($owners.Count -eq 0 -and -not $enrolled) { 'which is no patient of NEOIPC_CORE' }
                    elseif ($request.TrackedEntities.Count -gt 0 -and $request.TrackedEntities -cnotcontains $uid) { 'which it did not ask for' }
                    elseif ($request.OrgUnits.Count -gt 0 -and $request.OrgUnits -cnotcontains [string]$te['orgUnit'] -and @($owners | Where-Object { $request.OrgUnits -ccontains $_ }).Count -eq 0) {
                        'which is neither registered in nor owned by an org unit it asked for'
                    }
                    elseif ($request.PatientIds -and -not (Test-NeoIPCPatientIdMatch -Value ([string](Get-NeoIPCPatientAttributeValue -TrackedEntity $te -CodeByAttribute $codeByAttribute)['NEOIPC_PATIENT_ID']) -Candidate $request.PatientIds)) {
                        'whose patient ID is none it asked for'
                    }
                    if ($why) { throw (New-NeoIPCUnexpectedItemError -Resource 'trackedEntities' -Item "the tracked entity '$uid'" -Reason $why) }
                    if ($seen.Add($uid)) { $patients.Add($te) }
                }
            }

            $rows = [System.Collections.Generic.List[object]]::new()
            foreach ($te in $patients) {
                $values = Get-NeoIPCPatientAttributeValue -TrackedEntity $te -CodeByAttribute $codeByAttribute
                if ($trackedEntities.Count -gt 0 -and $patientIds.Count -gt 0 -and -not (Test-NeoIPCPatientIdMatch -Value ([string]$values['NEOIPC_PATIENT_ID']) -Candidate $patientIds)) { continue }
                $rows.Add([pscustomobject]@{ Entity = $te; Values = $values })
            }
            $unreadable = @($attributeCodes | Where-Object { -not $attributeByCode.ContainsKey($_) })
            $lacking = @($unreadable | Where-Object { $code = $_; @($rows | Where-Object { [string]::IsNullOrEmpty([string]$_.Values[$code]) }).Count -gt 0 })
            if ($lacking.Count -gt 0) {
                Write-Warning ('Your account cannot read the attribute(s) {0}. DHIS2 2.43.2 and later leave out the values of attributes an account cannot read, so their columns may be empty although a value exists.' -f ($lacking -join ', '))
            }

            foreach ($row in $rows) {
                $te = $row.Entity
                $patient = [ordered]@{ TrackedEntityId = [string]$te['trackedEntity']; OrgUnitId = [string]$te['orgUnit'] }
                foreach ($column in $columns.Keys) { $patient[$column] = $row.Values[$columns[$column]] }
                $patient['CreatedAt'] = ConvertFrom-NeoIPCDhis2Timestamp -Value $te['createdAt']
                $patient['UpdatedAt'] = ConvertFrom-NeoIPCDhis2Timestamp -Value $te['updatedAt']
                $patient['EnrollmentIds'] = [string[]]@(@($te['enrollments']) | Where-Object { $_ -is [System.Collections.IDictionary] -and [string]$_['program'] -ceq $programId } | ForEach-Object { [string]$_['enrollment'] })
                [pscustomobject]$patient
            }
        }
        catch { $PSCmdlet.ThrowTerminatingError($_) }
    }
}

function Read-EnrolmentInfo {
    <#
    .SYNOPSIS
        Read the NEOIPC_CORE enrolments of NeoIPC patients, each with its events and a link that opens it in the browser.
    .DESCRIPTION
        Reads the NEOIPC_CORE enrolments that DHIS2 lets your account read within your hierarchy: your account's
        data-capture org units and the org units below them. Without a filter it reads every such enrolment. Each filter
        narrows the read, and the filters of different parameters combine. An enrolment lies in an org unit when it was
        entered there or its patient's NEOIPC_CORE record is owned there; DHIS2 selects enrolments by that owner.

        The enrolment read takes one tracked entity, so -TrackedEntityId reads each patient's enrolments in a request of
        its own, unless -EnrollmentId bounds the read; the cmdlet then compares the patients itself. It writes an error
        naming each code or UID that names no org unit in your hierarchy, each enrolment or tracked-entity value that is no
        DHIS2 UID, and each tracked entity that DHIS2 says does not exist. When none of the values given to a parameter
        names anything, it returns nothing rather than read without that filter; an empty pipeline, too, returns nothing.

        DashboardUrl opens the enrolment in Tracker Capture's dashboard on DHIS2 2.41 and earlier, and on DHIS2 2.42 and
        later, which have no Tracker Capture, on the Capture app's enrolment page.

        On DHIS2 2.40, which reads listed enrolments without applying any other filter, the cmdlet applies the program,
        the tracked entities, the dates, and the org units itself; and since an enrolment read by query carries no events
        on 2.40, it reads the enrolments again by UID to fill EventIds.

        DHIS2 lets only an account with data-capture org units and data read access to NEOIPC_CORE read its records;
        without either, the read ends with an error that says which. The cmdlet speaks the request dialect of the
        instance's DHIS2 version (2.40 to 2.43), and a response holding an enrolment the request did not ask for ends the
        read with an error, since DHIS2 2.42 and later ignore a parameter they do not know and widen the read.
    .PARAMETER EnrollmentId
        Enrolment UIDs. Takes EnrollmentId from the pipeline, as Read-EventInfo emits it.
    .PARAMETER TrackedEntityId
        The UIDs of the patients whose enrolments to read. Takes TrackedEntityId from the pipeline, as Read-PatientInfo and
        Read-EventInfo emit it.
    .PARAMETER OrgUnitCode
        Codes of org units in your hierarchy, compared exactly: the enrolments that lie in one of them. Together with
        -OrgUnitId it forms one set of org units. The first positional parameter. Takes OrgUnitCode from the pipeline, as
        Read-OrgUnitInfo emits it, and completes from the local cache that Update-NeoIPCCache.ps1 writes.
    .PARAMETER OrgUnitId
        UIDs of org units in your hierarchy; see -OrgUnitCode. Takes OrgUnitId from the pipeline.
    .PARAMETER AdmissionDateFrom
        The first admission (enrolment) date to read, from the start of that day in the server's time.
    .PARAMETER AdmissionDateTo
        The last admission (enrolment) date to read, to the end of that day in the server's time.
    .PARAMETER UpdatedAfter
        Reads only enrolments updated on or after the start of this day, in the server's time.
    .PARAMETER Auth
        Authentication from Resolve-NeoIPCAuth (a token, or a username and password). Without it, the cmdlet resolves
        the authentication with Resolve-NeoIPCAuth -Token.
    .PARAMETER Token
        A DHIS2 personal access token, used when -Auth is not given; without either, Resolve-NeoIPCAuth decides
        (Get-Help Resolve-NeoIPCAuth).
    .PARAMETER Scheme
        http or https. Default: https. Also the scheme of DashboardUrl.
    .PARAMETER Hostname
        The DHIS2 host. Default: the NEOIPC_DHIS2_HOST environment variable; with neither, the cmdlet stops. Also the
        host of DashboardUrl.
    .PARAMETER Port
        The DHIS2 port. Default: the scheme's. Also the port of DashboardUrl.
    .OUTPUTS
        One [pscustomobject] per enrolment: EnrollmentId, TrackedEntityId, OrgUnitId (where it was entered), ProgramId;
        AdmissionDate, the enrolment date; Status; CreatedAt, UpdatedAt, CompletedAt; CompletedBy; FollowUp; StoredBy;
        CreatedBy and UpdatedBy, usernames; Notes, the texts of its notes; EventIds, the UIDs of its events; and
        DashboardUrl. The dates are [datetime] in the server's time.
    .EXAMPLE
        Read-PatientInfo -NeoIpcId 'DEMO-0001' | Read-EnrolmentInfo | Select-Object EnrollmentId, AdmissionDate, DashboardUrl

        Reads the enrolments of the patient with the NeoIPC patient ID DEMO-0001, with the links that open them.
    .EXAMPLE
        Read-EnrolmentInfo -OrgUnitCode NEO_DE_01 -AdmissionDateFrom 2025-01-01 -AdmissionDateTo 2025-06-30

        Reads the enrolments of the department NEO_DE_01 admitted in the first half of 2025.
    .EXAMPLE
        Read-EventInfo -OrgUnitCode NEO_DE_01 -EventType Pneumonia | Read-EnrolmentInfo

        Reads the enrolments that the pneumonia events of the department NEO_DE_01 belong to.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [string[]]$EnrollmentId,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string[]]$TrackedEntityId,

        [Parameter(Position = 0, ValueFromPipelineByPropertyName)]
        [ArgumentCompleter({
                param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
                $serverKey = Get-NeoIPCServerKey -Scheme $fakeBoundParameters['Scheme'] -Hostname $fakeBoundParameters['Hostname'] -Port $fakeBoundParameters['Port']
                $cacheDir = Join-Path $script:NeoIPCRepoRoot 'data' $serverKey
                $cacheFile = Join-Path $cacheDir 'site-codes.txt'
                if (Test-Path $cacheFile) {
                    Get-Content $cacheFile | Where-Object { $_ -like "$wordToComplete*" }
                }
            })]
        [string[]]$OrgUnitCode,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string[]]$OrgUnitId,

        [datetime]$AdmissionDateFrom,
        [datetime]$AdmissionDateTo,
        [datetime]$UpdatedAfter,

        [hashtable]$Auth,
        [string]$Token,
        [string]$Scheme,
        [string]$Hostname,
        [Nullable[int]]$Port
    )

    begin {
        # Per call: a variable of the module scope would carry one call's filters into the next cmdlet of a pipeline.
        $given = @{}
        $explicit = [System.Collections.Generic.List[string]]::new()
        foreach ($name in 'EnrollmentId', 'TrackedEntityId', 'OrgUnitCode', 'OrgUnitId') {
            $given[$name] = [System.Collections.Generic.List[string]]::new()
            if ($PSBoundParameters.ContainsKey($name)) { $explicit.Add($name) }
        }
    }

    process {
        foreach ($v in $EnrollmentId) { $given['EnrollmentId'].Add($v) }
        foreach ($v in $TrackedEntityId) { $given['TrackedEntityId'].Add($v) }
        foreach ($v in $OrgUnitCode) { $given['OrgUnitCode'].Add($v) }
        foreach ($v in $OrgUnitId) { $given['OrgUnitId'].Add($v) }
    }

    end {
        try {
            if (-not (Test-NeoIPCTrackerReadInput -Cmdlet $PSCmdlet -Given $given -Explicit $explicit -ExpectingInput:$MyInvocation.ExpectingInput)) { return }
            $ordinal = [System.StringComparer]::Ordinal

            if (-not $Auth) { $Auth = Resolve-NeoIPCAuth -Token $Token }
            $endpoint = @{ Auth = $Auth }
            if ($Scheme) { $endpoint.Scheme = $Scheme }
            if ($Hostname) { $endpoint.Hostname = $Hostname }
            if ($null -ne $Port) { $endpoint.Port = $Port }
            $version = ConvertTo-NeoIPCDhis2Version -Text (Get-NeoIPCDhis2VersionText -Endpoint $endpoint)
            $dialect = Get-NeoIPCTrackerDialect -Version $version
            $names = $dialect.EnrollmentQuery
            $programId = [string](Get-NeoIPCCoreProgram -Endpoint $endpoint).Program['id']

            $orgUnits = Resolve-NeoIPCTrackerReadOrgUnit -Cmdlet $PSCmdlet -Endpoint $endpoint -Code (Get-NeoIPCDistinctValue -Value $given['OrgUnitCode']) `
                -Id (Get-NeoIPCDistinctValue -Value $given['OrgUnitId'])
            if ($orgUnits.Given -and $orgUnits.Ids.Count -eq 0) { return }
            $enrollmentIds = Get-NeoIPCDistinctValue -Value $given['EnrollmentId']
            $enrollments = Select-NeoIPCTrackerReadUid -Cmdlet $PSCmdlet -Value $enrollmentIds -Noun 'enrolment'
            if ($enrollmentIds.Count -gt 0 -and $enrollments.Count -eq 0) { return }
            $teIds = Get-NeoIPCDistinctValue -Value $given['TrackedEntityId']
            $trackedEntities = Select-NeoIPCTrackerReadUid -Cmdlet $PSCmdlet -Value $teIds -Noun 'tracked entity'
            if ($teIds.Count -gt 0 -and $trackedEntities.Count -eq 0) { return }
            $baseUrl = Get-NeoIPCDhis2BaseUrl -Scheme $Scheme -Hostname $Hostname -Port $Port

            $fields = @('enrollment', 'trackedEntity', 'program', 'orgUnit', 'enrolledAt', 'status', 'createdAt', 'updatedAt', 'completedAt', 'completedBy',
                'followUp', 'storedBy', 'deleted', 'createdBy[username]', 'updatedBy[username]', 'notes[value]', 'events[event]')
            $found = [System.Collections.Generic.List[object]]::new()
            $seen = [System.Collections.Generic.HashSet[string]]::new($ordinal)

            if ($names.UidReadIgnoresFilters -and $enrollments.Count -gt 0) {
                # NEOIPC-COMPAT(dhis2-2.40-tracker-dialect): see Get-NeoIPCTrackerDialect. DHIS2 2.40 reads listed enrolments
                # by UID, deleted ones too, and applies no other filter, so the filters the query read would apply are
                # applied here: the program, deletion, the tracked entities, the dates, and the org units.
                foreach ($chunk in (Split-NeoIPCList -Value $enrollments -Separator $names.Separator)) {
                    $query = @{ program = $programId; $names.Enrollments = $chunk -join $names.Separator }
                    foreach ($en in (Get-NeoIPCCoreTrackerList -Endpoint $endpoint -Dialect $dialect -Resource 'enrollments' -Query $query -Fields $fields)) {
                        $uid = [string]$en['enrollment']
                        if ($chunk -cnotcontains $uid) { throw (New-NeoIPCUnexpectedItemError -Resource 'enrollments' -Item "the enrolment '$uid'" -Reason 'which it did not ask for') }
                        if ([string]$en['program'] -cne $programId -or $en['deleted'] -eq $true) { continue }
                        if ($trackedEntities.Count -gt 0 -and $trackedEntities -cnotcontains [string]$en['trackedEntity']) { continue }
                        if (-not (Test-NeoIPCTrackerDate -Value (ConvertFrom-NeoIPCDhis2Timestamp -Value $en['enrolledAt']) -After $AdmissionDateFrom -Before $AdmissionDateTo)) { continue }
                        if (-not (Test-NeoIPCTrackerDate -Value (ConvertFrom-NeoIPCDhis2Timestamp -Value $en['updatedAt']) -After $UpdatedAfter)) { continue }
                        if ($seen.Add($uid)) { $found.Add($en) }
                    }
                }
                $kept = $found.ToArray()
                if ($orgUnits.Given) { $kept = (Split-NeoIPCTrackerItemByOrgUnit -Endpoint $endpoint -Dialect $dialect -ProgramId $programId -Item $kept -OrgUnitId $orgUnits.Ids).Inside }
            }
            else {
                $dates = @{}
                if ($null -ne $AdmissionDateFrom) { $dates[$names.EnrolledAfter] = $AdmissionDateFrom.ToString('yyyy-MM-dd', [cultureinfo]::InvariantCulture) }
                if ($null -ne $AdmissionDateTo) { $dates[$names.EnrolledBefore] = $AdmissionDateTo.ToString('yyyy-MM-dd', [cultureinfo]::InvariantCulture) }
                if ($null -ne $UpdatedAfter) { $dates[$names.UpdatedAfter] = $UpdatedAfter.ToString('yyyy-MM-dd', [cultureinfo]::InvariantCulture) }
                # The read takes one tracked entity: one request per tracked entity, unless an enrolment list bounds the
                # read, which then leaves several tracked entities to be compared here.
                $teOnClient = $trackedEntities.Count -gt 1 -and $enrollments.Count -gt 0
                $teSent = [System.Collections.Generic.List[string]]::new()
                if ($trackedEntities.Count -gt 0 -and -not $teOnClient) { $teSent.AddRange($trackedEntities) } else { $teSent.Add($null) }

                $requests = [System.Collections.Generic.List[object]]::new()
                foreach ($ouChunk in (Split-NeoIPCOptionalList -Value $orgUnits.Ids -Separator $names.Separator)) {
                    foreach ($enChunk in (Split-NeoIPCOptionalList -Value $enrollments -Separator $names.Separator)) {
                        foreach ($te in $teSent) {
                            $query = @{ program = $programId; $dialect.OrgUnitMode = 'ACCESSIBLE' } + $dates
                            if ($ouChunk.Count -gt 0) { $query[$dialect.OrgUnitMode] = 'SELECTED'; $query[$names.OrgUnits] = $ouChunk -join $names.Separator }
                            if ($enChunk.Count -gt 0) { $query[$names.Enrollments] = $enChunk -join $names.Separator }
                            if ($te) { $query[$names.TrackedEntity] = $te }
                            $requests.Add([pscustomobject]@{ Query = $query; OrgUnits = $ouChunk; Enrollments = $enChunk; TrackedEntity = $te })
                        }
                    }
                }
                foreach ($request in $requests) {
                    try { $items = Get-NeoIPCCoreTrackerList -Endpoint $endpoint -Dialect $dialect -Resource 'enrollments' -Query $request.Query -Fields $fields }
                    catch {
                        if ($request.TrackedEntity -and (Test-NeoIPCTrackedEntityMissing -ErrorRecord $_ -TrackedEntityId $request.TrackedEntity)) {
                            Write-NeoIPCTrackerReadError -Cmdlet $PSCmdlet -ErrorId 'TrackedEntityNotFound' -TargetObject $request.TrackedEntity `
                                -Message "No tracked entity has the UID '$($request.TrackedEntity)': $($_.Exception.Message)"
                            continue
                        }
                        throw
                    }
                    foreach ($en in $items) {
                        $uid = [string]$en['enrollment']
                        $why = if ([string]$en['program'] -cne $programId) { 'which belongs to another program than NEOIPC_CORE' }
                        elseif ($request.Enrollments.Count -gt 0 -and $request.Enrollments -cnotcontains $uid) { 'which it did not ask for' }
                        elseif ($request.TrackedEntity -and [string]$en['trackedEntity'] -cne $request.TrackedEntity) { 'which belongs to another tracked entity than the one it asked for' }
                        if ($why) { throw (New-NeoIPCUnexpectedItemError -Resource 'enrollments' -Item "the enrolment '$uid'" -Reason $why) }
                    }
                    if ($request.OrgUnits.Count -gt 0) {
                        $outside = (Split-NeoIPCTrackerItemByOrgUnit -Endpoint $endpoint -Dialect $dialect -ProgramId $programId -Item $items -OrgUnitId $request.OrgUnits).Outside
                        if ($outside.Count -gt 0) {
                            throw (New-NeoIPCUnexpectedItemError -Resource 'enrollments' -Item "the enrolment '$($outside[0]['enrollment'])'" -Reason 'which lies in none of the org units it asked for')
                        }
                    }
                    foreach ($en in $items) { if ($seen.Add([string]$en['enrollment'])) { $found.Add($en) } }
                }
                $kept = $found.ToArray()
                if ($teOnClient) {
                    $wanted = [System.Collections.Generic.HashSet[string]]::new($trackedEntities, $ordinal)
                    $kept = @($kept | Where-Object { $wanted.Contains([string]$_['trackedEntity']) })
                }
            }

            $eventsOf = $null
            if ($names.QueryReadOmitsEvents -and -not ($names.UidReadIgnoresFilters -and $enrollments.Count -gt 0) -and $kept.Count -gt 0) {
                # NEOIPC-COMPAT(dhis2-2.40-tracker-dialect): see Get-NeoIPCTrackerDialect. The query read carried no events,
                # so the enrolments are read again by UID, which carries them.
                $eventsOf = [System.Collections.Generic.Dictionary[string, string[]]]::new($ordinal)
                foreach ($chunk in (Split-NeoIPCList -Value ([string[]]@($kept | ForEach-Object { [string]$_['enrollment'] })) -Separator $names.Separator)) {
                    $query = @{ program = $programId; $names.Enrollments = $chunk -join $names.Separator }
                    foreach ($en in (Get-NeoIPCCoreTrackerList -Endpoint $endpoint -Dialect $dialect -Resource 'enrollments' -Query $query -Fields 'enrollment', 'events[event]')) {
                        $uid = [string]$en['enrollment']
                        if ($chunk -cnotcontains $uid) { throw (New-NeoIPCUnexpectedItemError -Resource 'enrollments' -Item "the enrolment '$uid'" -Reason 'which it did not ask for') }
                        $eventsOf[$uid] = [string[]]@(@($en['events']) | Where-Object { $_ -is [System.Collections.IDictionary] } | ForEach-Object { [string]$_['event'] })
                    }
                }
                $lost = @($kept | ForEach-Object { [string]$_['enrollment'] } | Where-Object { -not $eventsOf.ContainsKey($_) })
                if ($lost.Count -gt 0) {
                    Write-Warning ('DHIS2 did not return the enrolment(s) {0} when read again for their events, so their EventIds are empty.' -f ($lost -join ', '))
                }
            }

            foreach ($en in $kept) {
                $uid = [string]$en['enrollment']
                [string[]]$eventIds = @()
                if ($null -ne $eventsOf) { if ($eventsOf.ContainsKey($uid)) { $eventIds = $eventsOf[$uid] } }
                else { $eventIds = @(@($en['events']) | Where-Object { $_ -is [System.Collections.IDictionary] } | ForEach-Object { [string]$_['event'] }) }
                [pscustomobject]@{
                    EnrollmentId    = $uid
                    TrackedEntityId = [string]$en['trackedEntity']
                    OrgUnitId       = [string]$en['orgUnit']
                    ProgramId       = [string]$en['program']
                    AdmissionDate   = ConvertFrom-NeoIPCDhis2Timestamp -Value $en['enrolledAt']
                    Status          = $en['status']
                    CreatedAt       = ConvertFrom-NeoIPCDhis2Timestamp -Value $en['createdAt']
                    UpdatedAt       = ConvertFrom-NeoIPCDhis2Timestamp -Value $en['updatedAt']
                    CompletedAt     = ConvertFrom-NeoIPCDhis2Timestamp -Value $en['completedAt']
                    CompletedBy     = $en['completedBy']
                    FollowUp        = $en['followUp'] -eq $true
                    StoredBy        = $en['storedBy']
                    CreatedBy       = Get-NeoIPCDhis2Username -User $en['createdBy']
                    UpdatedBy       = Get-NeoIPCDhis2Username -User $en['updatedBy']
                    Notes           = [string[]]@(@($en['notes']) | Where-Object { $_ -is [System.Collections.IDictionary] } | ForEach-Object { [string]$_['value'] })
                    EventIds        = $eventIds
                    DashboardUrl    = Get-NeoIPCEnrollmentDashboardUrl -BaseUrl $baseUrl -Version $version -EnrollmentId $uid -TrackedEntityId ([string]$en['trackedEntity']) `
                        -ProgramId $programId -OrgUnitId ([string]$en['orgUnit'])
                }
            }
        }
        catch { $PSCmdlet.ThrowTerminatingError($_) }
    }
}

function Read-EventInfo {
    <#
    .SYNOPSIS
        Read the NEOIPC_CORE events of NeoIPC patients, optionally with the values of chosen data elements.
    .DESCRIPTION
        Reads the NEOIPC_CORE events that DHIS2 lets your account read within your hierarchy: your account's data-capture
        org units and the org units below them. Without a filter it reads every such event. Each filter narrows the read,
        and the filters of different parameters combine. An event lies in an org unit when it was entered there or its
        patient's NEOIPC_CORE record is owned there; DHIS2 selects events by that owner.

        The event read takes one org unit, one tracked entity, and one program stage. With several values of one of them,
        and no -EventId or -EnrollmentId bounding the read, the cmdlet sends one request per value of the first of
        tracked entity, org unit, and program stage that has several, and compares the others itself; with -EventId or
        -EnrollmentId it compares them all itself. With both -EventId and -EnrollmentId, DHIS2 reads the events and the
        cmdlet compares the enrolments.

        -EventType names a stage by its English name and finds the NEOIPC_CORE stage with that stage's code
        (NEOIPC_STG_ADM, NEOIPC_STG_SURGERY, NEOIPC_STG_BSI, NEOIPC_STG_NEC, NEOIPC_STG_SSI, NEOIPC_STG_HAP, or
        NEOIPC_STG_SURV_END), or, where no stage carries that code, the stage with that name. -EventType and
        -ProgramStageId together select the stages of both.

        -CreatedBy, -UpdatedBy, and -StoredBy are compared exactly, by the cmdlet rather than by DHIS2, and an event
        without the value never matches. They take their values from the pipeline too, so objects piped from
        Read-EnrolmentInfo, which carry their enrolment's CreatedBy, UpdatedBy, and StoredBy, filter the events by them;
        to read every event of piped enrolments, pipe only their EnrollmentId (Select-Object EnrollmentId).
        -DataElementCode keeps the events with a value for any of the data elements and adds their values to the output.

        The cmdlet writes an error naming each code or UID that names no org unit in your hierarchy, each stage that is no
        stage of NEOIPC_CORE, each data-element code your account can read no data element of, each event, enrolment, or
        tracked-entity value that is no DHIS2 UID, and each tracked entity that DHIS2 says does not exist. When none of
        the values given to a parameter names anything, it returns nothing rather than read without that filter; an empty
        pipeline, too, returns nothing.

        DHIS2 lets only an account with data-capture org units and data read access to NEOIPC_CORE read its records;
        without either, the read ends with an error that says which. The cmdlet speaks the request dialect of the
        instance's DHIS2 version (2.40 to 2.43), and a response holding an event the request did not ask for ends the
        read with an error, since DHIS2 2.42 and later ignore a parameter they do not know and widen the read.
    .PARAMETER EventId
        Event UIDs. Takes EventId from the pipeline.
    .PARAMETER OrgUnitCode
        Codes of org units in your hierarchy, compared exactly: the events that lie in one of them. Together with
        -OrgUnitId it forms one set of org units. The first positional parameter. Takes OrgUnitCode from the pipeline, as
        Read-OrgUnitInfo emits it, and completes from the local cache that Update-NeoIPCCache.ps1 writes.
    .PARAMETER OrgUnitId
        UIDs of org units in your hierarchy; see -OrgUnitCode. Takes OrgUnitId from the pipeline.
    .PARAMETER EnrollmentId
        The UIDs of the enrolments whose events to read. Takes EnrollmentId from the pipeline, as Read-EnrolmentInfo emits
        it.
    .PARAMETER TrackedEntityId
        The UIDs of the patients whose events to read. Takes TrackedEntityId from the pipeline, as Read-PatientInfo and
        Read-EnrolmentInfo emit it.
    .PARAMETER EventType
        The kind of event, by the English name of its NEOIPC_CORE program stage: Admission, Surgical Procedure, Primary
        Sepsis/BSI, Necrotizing enterocolitis, Surgical Site Infection, Pneumonia, or Surveillance-End.
    .PARAMETER ProgramStageId
        UIDs of NEOIPC_CORE program stages. Takes ProgramStageId from the pipeline.
    .PARAMETER DataElementCode
        Data-element codes, compared exactly: keeps the events with a value for any of them, and adds DataValues to the
        output. Completes from the local cache that Update-NeoIPCCache.ps1 writes.
    .PARAMETER CreatedBy
        Usernames of the accounts that created the events, compared exactly. Takes CreatedBy from the pipeline.
    .PARAMETER UpdatedBy
        Usernames of the accounts that last updated the events, compared exactly. Takes UpdatedBy from the pipeline.
    .PARAMETER StoredBy
        The events' storedBy values, compared exactly. Takes StoredBy from the pipeline.
    .PARAMETER OccurredAfter
        Reads only events that occurred on or after the start of this day, in the server's time.
    .PARAMETER OccurredBefore
        Reads only events that occurred on or before the end of this day, in the server's time.
    .PARAMETER UpdatedAfter
        Reads only events updated on or after the start of this day, in the server's time.
    .PARAMETER UpdatedBefore
        Reads only events updated on or before the end of this day, in the server's time.
    .PARAMETER Auth
        Authentication from Resolve-NeoIPCAuth (a token, or a username and password). Without it, the cmdlet resolves
        the authentication with Resolve-NeoIPCAuth -Token.
    .PARAMETER Token
        A DHIS2 personal access token, used when -Auth is not given; without either, Resolve-NeoIPCAuth decides
        (Get-Help Resolve-NeoIPCAuth).
    .PARAMETER Scheme
        http or https. Default: https.
    .PARAMETER Hostname
        The DHIS2 host. Default: the NEOIPC_DHIS2_HOST environment variable; with neither, the cmdlet stops.
    .PARAMETER Port
        The DHIS2 port. Default: the scheme's.
    .OUTPUTS
        One [pscustomobject] per event: EventId, EnrollmentId, TrackedEntityId, OrgUnitId (where it was entered),
        ProgramStageId, Status; OccurredAt, CreatedAt, and UpdatedAt, [datetime] in the server's time; StoredBy; CreatedBy
        and UpdatedBy, usernames. With -DataElementCode also DataValues, which has a property per given code, in the order
        given: $null where the event has no value for it, else Value, StoredBy, CreatedAt, UpdatedAt, CreatedByUsername,
        and UpdatedByUsername.
    .EXAMPLE
        Read-OrgUnitInfo -OrgUnitCode NEO_DE_01 | Read-EventInfo -EventType Admission

        Reads the admission events of the department NEO_DE_01.
    .EXAMPLE
        Read-EventInfo -OrgUnitCode NEO_DE_01 -DataElementCode NEOIPC_BSI_PATHOGEN_1_NAME -UpdatedAfter (Get-Date).AddDays(-30) |
            Select-Object EventId, CreatedBy -ExpandProperty DataValues

        Reads the events of the department NEO_DE_01 updated in the last 30 days that name an infectious agent in the
        first BSI slot, with that value.
    .EXAMPLE
        Read-PatientInfo -NeoIpcId 'DEMO-0001' | Read-EventInfo

        Reads the events of the patient with the NeoIPC patient ID DEMO-0001.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [string[]]$EventId,

        [Parameter(Position = 0, ValueFromPipelineByPropertyName)]
        [ArgumentCompleter({
                param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
                $serverKey = Get-NeoIPCServerKey -Scheme $fakeBoundParameters['Scheme'] -Hostname $fakeBoundParameters['Hostname'] -Port $fakeBoundParameters['Port']
                $cacheDir = Join-Path $script:NeoIPCRepoRoot 'data' $serverKey
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

        [ValidateSet('Admission', 'Necrotizing enterocolitis', 'Pneumonia', 'Primary Sepsis/BSI',
            'Surgical Procedure', 'Surgical Site Infection', 'Surveillance-End')]
        [string]$EventType,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string[]]$ProgramStageId,

        [ArgumentCompleter({
                param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
                $serverKey = Get-NeoIPCServerKey -Scheme $fakeBoundParameters['Scheme'] -Hostname $fakeBoundParameters['Hostname'] -Port $fakeBoundParameters['Port']
                $cacheDir = Join-Path $script:NeoIPCRepoRoot 'data' $serverKey
                $cacheFile = Join-Path $cacheDir 'de-codes.txt'
                if (Test-Path $cacheFile) {
                    Get-Content $cacheFile | Where-Object { $_ -like "$wordToComplete*" }
                }
            })]
        [string[]]$DataElementCode,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string[]]$CreatedBy,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string[]]$UpdatedBy,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string[]]$StoredBy,

        [datetime]$OccurredAfter,
        [datetime]$OccurredBefore,
        [datetime]$UpdatedAfter,
        [datetime]$UpdatedBefore,

        [hashtable]$Auth,
        [string]$Token,
        [string]$Scheme,
        [string]$Hostname,
        [Nullable[int]]$Port
    )

    begin {
        # Per call: a variable of the module scope would carry one call's filters into the next cmdlet of a pipeline.
        $given = @{}
        $explicit = [System.Collections.Generic.List[string]]::new()
        foreach ($name in 'EventId', 'OrgUnitCode', 'OrgUnitId', 'EnrollmentId', 'TrackedEntityId', 'ProgramStageId', 'CreatedBy', 'UpdatedBy', 'StoredBy') {
            $given[$name] = [System.Collections.Generic.List[string]]::new()
            if ($PSBoundParameters.ContainsKey($name)) { $explicit.Add($name) }
        }
    }

    process {
        foreach ($v in $EventId) { $given['EventId'].Add($v) }
        foreach ($v in $OrgUnitCode) { $given['OrgUnitCode'].Add($v) }
        foreach ($v in $OrgUnitId) { $given['OrgUnitId'].Add($v) }
        foreach ($v in $EnrollmentId) { $given['EnrollmentId'].Add($v) }
        foreach ($v in $TrackedEntityId) { $given['TrackedEntityId'].Add($v) }
        foreach ($v in $ProgramStageId) { $given['ProgramStageId'].Add($v) }
        foreach ($v in $CreatedBy) { $given['CreatedBy'].Add($v) }
        foreach ($v in $UpdatedBy) { $given['UpdatedBy'].Add($v) }
        foreach ($v in $StoredBy) { $given['StoredBy'].Add($v) }
    }

    end {
        try {
            if (-not (Test-NeoIPCTrackerReadInput -Cmdlet $PSCmdlet -Given $given -Explicit $explicit -ExpectingInput:$MyInvocation.ExpectingInput)) { return }
            $ordinal = [System.StringComparer]::Ordinal
            $dataElementCodes = Get-NeoIPCDistinctValue -Value $DataElementCode
            if ($PSBoundParameters.ContainsKey('DataElementCode') -and $dataElementCodes.Count -eq 0) {
                Write-NeoIPCTrackerReadError -Cmdlet $PSCmdlet -ErrorId 'EmptyFilter' -Category InvalidArgument -TargetObject 'DataElementCode' `
                    -Message '-DataElementCode holds no value, so it selects nothing; leave it out to read without it.'
                return
            }
            # DataValues has a property per code, and properties compare ignoring case.
            $keys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            $dataElementCodes = [string[]]@(foreach ($code in $dataElementCodes) {
                    if ($keys.Add($code)) { $code; continue }
                    Write-NeoIPCTrackerReadError -Cmdlet $PSCmdlet -ErrorId 'DataElementCodeCase' -Category InvalidArgument -TargetObject $code `
                        -Message "-DataElementCode holds '$code' and a code that differs from it only in case, which DataValues cannot tell apart; '$code' is left out."
                })

            if (-not $Auth) { $Auth = Resolve-NeoIPCAuth -Token $Token }
            $endpoint = @{ Auth = $Auth }
            if ($Scheme) { $endpoint.Scheme = $Scheme }
            if ($Hostname) { $endpoint.Hostname = $Hostname }
            if ($null -ne $Port) { $endpoint.Port = $Port }
            $dialect = Get-NeoIPCTrackerDialect -Version (ConvertTo-NeoIPCDhis2Version -Text (Get-NeoIPCDhis2VersionText -Endpoint $endpoint))
            $names = $dialect.EventQuery
            $core = Get-NeoIPCCoreProgram -Endpoint $endpoint -ProgramField 'programStages[id,code,name]'
            $programId = [string]$core.Program['id']
            $stages = @(@($core.Program['programStages']) | Where-Object { $_ -is [System.Collections.IDictionary] })

            # The stages the read selects: -EventType's and -ProgramStageId's, each of NEOIPC_CORE.
            $stageIds = [System.Collections.Generic.List[string]]::new()
            if ($EventType) {
                # The code of each event type's stage (metadata/common/programStages.csv).
                $eventTypes = @(
                    @{ Name = 'Admission'; Code = 'NEOIPC_STG_ADM' }
                    @{ Name = 'Surgical Procedure'; Code = 'NEOIPC_STG_SURGERY' }
                    @{ Name = 'Primary Sepsis/BSI'; Code = 'NEOIPC_STG_BSI' }
                    @{ Name = 'Necrotizing enterocolitis'; Code = 'NEOIPC_STG_NEC' }
                    @{ Name = 'Surgical Site Infection'; Code = 'NEOIPC_STG_SSI' }
                    @{ Name = 'Pneumonia'; Code = 'NEOIPC_STG_HAP' }
                    @{ Name = 'Surveillance-End'; Code = 'NEOIPC_STG_SURV_END' }
                )
                $type = @($eventTypes | Where-Object { $_.Name -eq $EventType })[0]
                $matched = @($stages | Where-Object { [string]$_['code'] -ceq $type.Code })
                if ($matched.Count -eq 0) {
                    # NEOIPC-COMPAT(programstage-code): remove once every supported instance reports the codes NEOIPC_STG_*
                    # on all seven NEOIPC_CORE stages (api/metadata programs.programStages.code); until then a stage without
                    # its code is found by the English name it was created with, as neoipcr finds it.
                    $stageCodes = [string[]]@($eventTypes | ForEach-Object { $_.Code })
                    $matched = @($stages | Where-Object { $stageCodes -cnotcontains [string]$_['code'] -and [string]$_['name'] -ceq $type.Name })
                }
                if ($matched.Count -eq 0) {
                    Write-NeoIPCTrackerReadError -Cmdlet $PSCmdlet -ErrorId 'EventTypeNotFound' -TargetObject $type.Name `
                        -Message "No program stage of NEOIPC_CORE has the code $($type.Code), nor, without such a code, the name '$($type.Name)'."
                    return
                }
                foreach ($s in $matched) { $stageIds.Add([string]$s['id']) }
            }
            $askedStages = Get-NeoIPCDistinctValue -Value $given['ProgramStageId']
            if ($askedStages.Count -gt 0) {
                $known = [System.Collections.Generic.HashSet[string]]::new([string[]]@($stages | ForEach-Object { [string]$_['id'] }), $ordinal)
                $resolved = 0
                foreach ($s in $askedStages) {
                    if ($known.Contains($s)) { $stageIds.Add($s); $resolved++ }
                    else { Write-NeoIPCTrackerReadError -Cmdlet $PSCmdlet -ErrorId 'ProgramStageNotFound' -TargetObject $s -Message "No program stage of NEOIPC_CORE has the UID '$s'." }
                }
                if ($resolved -eq 0) { return }
            }
            $stageIds = Get-NeoIPCDistinctValue -Value $stageIds

            # The data elements of -DataElementCode, by code: a code holding ',' cannot stand in an 'in' list, which splits
            # on it, so it is looked up by itself.
            $dataElementByCode = [System.Collections.Generic.Dictionary[string, string]]::new($ordinal)
            if ($dataElementCodes.Count -gt 0) {
                $filters = [System.Collections.Generic.List[string]]::new()
                foreach ($chunk in (Split-NeoIPCList -Value ([string[]]@($dataElementCodes | Where-Object { -not $_.Contains(',') })) -Separator ',')) { $filters.Add("code:in:[$($chunk -join ',')]") }
                foreach ($code in @($dataElementCodes | Where-Object { $_.Contains(',') })) { $filters.Add("code:eq:$code") }
                foreach ($filter in $filters) {
                    $metadata = Invoke-NeoIPCDhis2Get @endpoint -Path 'api/metadata' -QueryParameters @{ 'dataElements:filter' = $filter; 'dataElements:fields' = 'id,code' } -AsHashtable -Confirm:$false -WhatIf:$false
                    if ($metadata -isnot [System.Collections.IDictionary]) { continue }
                    foreach ($de in @($metadata['dataElements'])) {
                        if ($de -is [System.Collections.IDictionary] -and $dataElementCodes -ccontains [string]$de['code'] -and (Test-NeoIPCMetadataUid -Id ([string]$de['id']))) {
                            $dataElementByCode[[string]$de['code']] = [string]$de['id']
                        }
                    }
                }
                foreach ($code in $dataElementCodes) {
                    if (-not $dataElementByCode.ContainsKey($code)) {
                        Write-NeoIPCTrackerReadError -Cmdlet $PSCmdlet -ErrorId 'DataElementNotFound' -TargetObject $code -Message "No data element your account can read has the code '$code' (codes compare exactly)."
                    }
                }
                if ($dataElementByCode.Count -eq 0) { return }
            }

            $orgUnits = Resolve-NeoIPCTrackerReadOrgUnit -Cmdlet $PSCmdlet -Endpoint $endpoint -Code (Get-NeoIPCDistinctValue -Value $given['OrgUnitCode']) `
                -Id (Get-NeoIPCDistinctValue -Value $given['OrgUnitId'])
            if ($orgUnits.Given -and $orgUnits.Ids.Count -eq 0) { return }
            $resolvedLists = @{}
            foreach ($list in @(@{ Name = 'EventId'; Noun = 'event' }, @{ Name = 'EnrollmentId'; Noun = 'enrolment' }, @{ Name = 'TrackedEntityId'; Noun = 'tracked entity' })) {
                $asked = Get-NeoIPCDistinctValue -Value $given[$list.Name]
                $resolvedLists[$list.Name] = Select-NeoIPCTrackerReadUid -Cmdlet $PSCmdlet -Value $asked -Noun $list.Noun
                if ($asked.Count -gt 0 -and $resolvedLists[$list.Name].Count -eq 0) { return }
            }
            [string[]]$events = $resolvedLists['EventId']
            [string[]]$enrollments = $resolvedLists['EnrollmentId']
            [string[]]$trackedEntities = $resolvedLists['TrackedEntityId']

            # The org unit, tracked entity, and program stage each take one value. With several of one of them, and no event
            # or enrolment list bounding the read, one request per value of the first that has several; every other
            # several-valued one, and with a bounding list every one, is compared here. With both lists, the events are
            # read and the enrolments compared here.
            $fanOut = $null
            if ($events.Count -eq 0 -and $enrollments.Count -eq 0) {
                if ($trackedEntities.Count -gt 1) { $fanOut = 'TrackedEntity' }
                elseif ($orgUnits.Ids.Count -gt 1) { $fanOut = 'OrgUnit' }
                elseif ($stageIds.Count -gt 1) { $fanOut = 'ProgramStage' }
            }
            $teSent = Get-NeoIPCTrackerSentValue -Value $trackedEntities -FanOut:($fanOut -eq 'TrackedEntity')
            $ouSent = Get-NeoIPCTrackerSentValue -Value $orgUnits.Ids -FanOut:($fanOut -eq 'OrgUnit')
            $stageSent = Get-NeoIPCTrackerSentValue -Value $stageIds -FanOut:($fanOut -eq 'ProgramStage')
            [string[]]$enrollmentsSent = @()
            if ($events.Count -eq 0) { $enrollmentsSent = $enrollments }

            $dates = @{}
            if ($null -ne $OccurredAfter) { $dates[$names.OccurredAfter] = $OccurredAfter.ToString('yyyy-MM-dd', [cultureinfo]::InvariantCulture) }
            if ($null -ne $OccurredBefore) { $dates[$names.OccurredBefore] = $OccurredBefore.ToString('yyyy-MM-dd', [cultureinfo]::InvariantCulture) }
            if ($null -ne $UpdatedAfter) { $dates[$names.UpdatedAfter] = $UpdatedAfter.ToString('yyyy-MM-dd', [cultureinfo]::InvariantCulture) }
            if ($null -ne $UpdatedBefore) { $dates[$names.UpdatedBefore] = $UpdatedBefore.ToString('yyyy-MM-dd', [cultureinfo]::InvariantCulture) }

            $requests = [System.Collections.Generic.List[object]]::new()
            foreach ($eventChunk in (Split-NeoIPCOptionalList -Value $events -Separator $names.EventSeparator)) {
                foreach ($enChunk in (Split-NeoIPCOptionalList -Value $enrollmentsSent -Separator ',')) {
                    foreach ($te in $teSent) {
                        foreach ($ou in $ouSent) {
                            foreach ($stage in $stageSent) {
                                $query = @{ program = $programId; $dialect.OrgUnitMode = 'ACCESSIBLE' } + $dates
                                if ($ou) { $query[$dialect.OrgUnitMode] = 'SELECTED'; $query[$names.OrgUnit] = $ou }
                                if ($te) { $query[$names.TrackedEntity] = $te }
                                if ($stage) { $query[$names.ProgramStage] = $stage }
                                if ($eventChunk.Count -gt 0) { $query[$names.Events] = $eventChunk -join $names.EventSeparator }
                                if ($enChunk.Count -gt 0) { $query[$names.Enrollments] = $enChunk -join ',' }
                                $requests.Add([pscustomobject]@{ Query = $query; Events = $eventChunk; Enrollments = $enChunk; TrackedEntity = $te; OrgUnit = $ou; ProgramStage = $stage })
                            }
                        }
                    }
                }
            }

            $fields = @('event', 'enrollment', 'trackedEntity', 'program', 'orgUnit', 'programStage', 'status', 'occurredAt', 'createdAt', 'updatedAt', 'storedBy',
                'createdBy[username]', 'updatedBy[username]', 'dataValues[dataElement,value,storedBy,createdAt,updatedAt,createdBy[username],updatedBy[username]]')
            $found = [System.Collections.Generic.List[object]]::new()
            $seen = [System.Collections.Generic.HashSet[string]]::new($ordinal)
            foreach ($request in $requests) {
                try { $items = Get-NeoIPCCoreTrackerList -Endpoint $endpoint -Dialect $dialect -Resource 'events' -Query $request.Query -Fields $fields }
                catch {
                    if ($request.TrackedEntity -and (Test-NeoIPCTrackedEntityMissing -ErrorRecord $_ -TrackedEntityId $request.TrackedEntity)) {
                        Write-NeoIPCTrackerReadError -Cmdlet $PSCmdlet -ErrorId 'TrackedEntityNotFound' -TargetObject $request.TrackedEntity `
                            -Message "No tracked entity has the UID '$($request.TrackedEntity)': $($_.Exception.Message)"
                        continue
                    }
                    throw
                }
                foreach ($e in $items) {
                    $uid = [string]$e['event']
                    $why = if ([string]$e['program'] -cne $programId) { 'which belongs to another program than NEOIPC_CORE' }
                    elseif ($request.Events.Count -gt 0 -and $request.Events -cnotcontains $uid) { 'which it did not ask for' }
                    elseif ($request.Enrollments.Count -gt 0 -and $request.Enrollments -cnotcontains [string]$e['enrollment']) { 'whose enrolment is none it asked for' }
                    elseif ($request.TrackedEntity -and [string]$e['trackedEntity'] -cne $request.TrackedEntity) { 'whose tracked entity is not the one it asked for' }
                    elseif ($request.ProgramStage -and [string]$e['programStage'] -cne $request.ProgramStage) { 'whose program stage is not the one it asked for' }
                    if ($why) { throw (New-NeoIPCUnexpectedItemError -Resource 'events' -Item "the event '$uid'" -Reason $why) }
                }
                if ($request.OrgUnit) {
                    $outside = (Split-NeoIPCTrackerItemByOrgUnit -Endpoint $endpoint -Dialect $dialect -ProgramId $programId -Item $items -OrgUnitId $request.OrgUnit).Outside
                    if ($outside.Count -gt 0) {
                        throw (New-NeoIPCUnexpectedItemError -Resource 'events' -Item "the event '$($outside[0]['event'])'" -Reason 'which lies in none of the org units it asked for')
                    }
                }
                foreach ($e in $items) { if ($seen.Add([string]$e['event'])) { $found.Add($e) } }
            }

            # The filters compared here, the org units last, since they may need the owners read.
            $kept = $found.ToArray()
            if ($trackedEntities.Count -gt 1 -and $fanOut -ne 'TrackedEntity') {
                $wanted = [System.Collections.Generic.HashSet[string]]::new($trackedEntities, $ordinal)
                $kept = @($kept | Where-Object { $wanted.Contains([string]$_['trackedEntity']) })
            }
            if ($stageIds.Count -gt 1 -and $fanOut -ne 'ProgramStage') {
                $wantedStages = [System.Collections.Generic.HashSet[string]]::new($stageIds, $ordinal)
                $kept = @($kept | Where-Object { $wantedStages.Contains([string]$_['programStage']) })
            }
            if ($events.Count -gt 0 -and $enrollments.Count -gt 0) {
                $wantedEnrollments = [System.Collections.Generic.HashSet[string]]::new($enrollments, $ordinal)
                $kept = @($kept | Where-Object { $wantedEnrollments.Contains([string]$_['enrollment']) })
            }
            # Each username filter stays a set, whatever its size: a one-element set unrolled into a string would match by
            # substring.
            $createdBySet = $null
            $updatedBySet = $null
            $storedBySet = $null
            $createdByNames = Get-NeoIPCDistinctValue -Value $given['CreatedBy']
            $updatedByNames = Get-NeoIPCDistinctValue -Value $given['UpdatedBy']
            $storedByNames = Get-NeoIPCDistinctValue -Value $given['StoredBy']
            if ($createdByNames.Count -gt 0) { $createdBySet = [System.Collections.Generic.HashSet[string]]::new($createdByNames, $ordinal) }
            if ($updatedByNames.Count -gt 0) { $updatedBySet = [System.Collections.Generic.HashSet[string]]::new($updatedByNames, $ordinal) }
            if ($storedByNames.Count -gt 0) { $storedBySet = [System.Collections.Generic.HashSet[string]]::new($storedByNames, $ordinal) }
            if ($null -ne $createdBySet) {
                $kept = @($kept | Where-Object { $username = Get-NeoIPCDhis2Username -User $_['createdBy']; $null -ne $username -and $createdBySet.Contains($username) })
            }
            if ($null -ne $updatedBySet) {
                $kept = @($kept | Where-Object { $username = Get-NeoIPCDhis2Username -User $_['updatedBy']; $null -ne $username -and $updatedBySet.Contains($username) })
            }
            if ($null -ne $storedBySet) {
                $kept = @($kept | Where-Object { $value = [string]$_['storedBy']; $value -ne '' -and $storedBySet.Contains($value) })
            }
            if ($orgUnits.Ids.Count -gt 1 -and $fanOut -ne 'OrgUnit' -and $kept.Count -gt 0) {
                $kept = (Split-NeoIPCTrackerItemByOrgUnit -Endpoint $endpoint -Dialect $dialect -ProgramId $programId -Item $kept -OrgUnitId $orgUnits.Ids).Inside
            }

            foreach ($e in $kept) {
                $valueOf = [System.Collections.Generic.Dictionary[string, object]]::new($ordinal)
                foreach ($dv in @($e['dataValues'])) {
                    if ($dv -is [System.Collections.IDictionary] -and -not [string]::IsNullOrEmpty([string]$dv['value'])) { $valueOf[[string]$dv['dataElement']] = $dv }
                }
                if ($dataElementCodes.Count -gt 0 -and @($dataElementByCode.Values | Where-Object { $valueOf.ContainsKey($_) }).Count -eq 0) { continue }
                $record = [ordered]@{
                    EventId         = [string]$e['event']
                    EnrollmentId    = [string]$e['enrollment']
                    TrackedEntityId = [string]$e['trackedEntity']
                    OrgUnitId       = [string]$e['orgUnit']
                    ProgramStageId  = [string]$e['programStage']
                    Status          = $e['status']
                    OccurredAt      = ConvertFrom-NeoIPCDhis2Timestamp -Value $e['occurredAt']
                    CreatedAt       = ConvertFrom-NeoIPCDhis2Timestamp -Value $e['createdAt']
                    UpdatedAt       = ConvertFrom-NeoIPCDhis2Timestamp -Value $e['updatedAt']
                    StoredBy        = $e['storedBy']
                    CreatedBy       = Get-NeoIPCDhis2Username -User $e['createdBy']
                    UpdatedBy       = Get-NeoIPCDhis2Username -User $e['updatedBy']
                }
                if ($dataElementCodes.Count -gt 0) {
                    $values = [ordered]@{}
                    foreach ($code in $dataElementCodes) {
                        $values[$code] = $null
                        if (-not $dataElementByCode.ContainsKey($code) -or -not $valueOf.ContainsKey($dataElementByCode[$code])) { continue }
                        $dv = $valueOf[$dataElementByCode[$code]]
                        $values[$code] = [pscustomobject]@{
                            Value             = $dv['value']
                            StoredBy          = $dv['storedBy']
                            CreatedAt         = ConvertFrom-NeoIPCDhis2Timestamp -Value $dv['createdAt']
                            UpdatedAt         = ConvertFrom-NeoIPCDhis2Timestamp -Value $dv['updatedAt']
                            CreatedByUsername = Get-NeoIPCDhis2Username -User $dv['createdBy']
                            UpdatedByUsername = Get-NeoIPCDhis2Username -User $dv['updatedBy']
                        }
                    }
                    $record['DataValues'] = [pscustomobject]$values
                }
                [pscustomobject]$record
            }
        }
        catch { $PSCmdlet.ThrowTerminatingError($_) }
    }
}
