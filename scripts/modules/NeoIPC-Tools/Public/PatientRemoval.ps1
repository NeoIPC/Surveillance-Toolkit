#Requires -Version 7.6
# Remove-NeoIPCPatient: deletes patients entered in error, each with all its enrolments and events, after a preview,
# DHIS2's own dry run, and one confirmation, and proves each deletion by reading it back. The rules it applies, and the
# DHIS2 behaviour they answer to, are in Private/PatientRemoval.ps1.

function Remove-NeoIPCPatient {
    <#
    .SYNOPSIS
        Delete NeoIPC patients, each with all its enrolments and events, after a preview, DHIS2's own dry run, and one
        confirmation.
    .DESCRIPTION
        Selects the patients in one of three ways, each naming the department they belong to:
          1. -OrgUnitCode with -NeoIpcId: the NeoIPC patient IDs, which are unique only within their department;
          2. -OrgUnitCode with -TrackedEntityId: the patients' DHIS2 UIDs;
          3. objects piped to -InputObject that carry TrackedEntityId and OrgUnitId, and optionally NeoIpcId, which
             must then be the patient's: Read-PatientInfo's output, or a reviewed -WhatIf result read back with
             Import-Csv. Enrolment and event records carry TrackedEntityId too; piped as they come, they are refused,
             so that a list of events piped by mistake does not select their patients.

        A run then:
          1. checks the selection before any request: exact duplicates collapse; selectors that differ only in case,
             contradict each other, or are malformed are refused; more than -MaximumCount patients end the run;
          2. checks that the DHIS2 release is one the removal was verified on (see -AllowUnverifiedVersion), and
             resolves by code the program NEOIPC_CORE, the tracked-entity type NEOIPC_PATIENT, the attribute
             NEOIPC_PATIENT_ID, and the department, which must be a member of the org-unit group NEO_DEPARTMENT; a piped
             OrgUnitId must name such a department, the same one as -OrgUnitCode if both are given; and a patient ID
             holding more than one '/' is refused before DHIS2 2.42, which may look it up as another patient ID:
             select such a patient by its UID;
          3. reads each patient with its enrolments and events, and refuses one whose patient ID matches more than one
             patient (DHIS2 compares patient IDs ignoring case, the run exactly), that is registered or owned outside
             the department, that has an enrolment or program owner in another program, or that has an enrolment or
             event in another org unit: DHIS2 deletes every live enrolment and event of a patient with it, in every
             program, without checking them;
          4. asks DHIS2 to validate the deletion of every remaining patient without carrying it out
             (importMode=VALIDATE), so that DHIS2's own refusals show before anything is deleted; an answer that
             reports any patient as deleted ends the run at once (DryRunDeleted);
          5. shows the preview, and asks once, with the totals;
          6. deletes the patients one request each, so that a refusal or a failure stays with its patient, and reads
             each back: a patient counts as Deleted only when the read with includeDeleted shows it, and every
             enrolment and event the preview showed live, deleted, and its own read answers 404.
        -WhatIf runs steps 1 to 4, which change nothing, and the preview of step 5, and writes no error: its results
        carry the outcomes.

        The Outcome of each selected patient is one of: WouldDelete (under -WhatIf); Declined; Deleted;
        AlreadyDeleted; NotFound; Refused, by a rule of steps 1 to 3 or by DHIS2's dry run in step 4 (Reason,
        ErrorCodes); Failed, when DHIS2 answered and the patient is still there; Unverified, when neither the deletion
        nor its failure can be proven; NotAttempted, when the run stopped first. DHIS2 looks a patient up by program
        owner, so where NEOIPC_CORE is the patient type's only program, a patient the department registered whose
        NEOIPC_CORE owner is another org unit comes back NotFound by its patient ID. By its UID it comes back Refused
        (OutsideDepartment) when that owner lies within your data-capture org units, or you are a superuser on DHIS2
        2.43, and NotFound otherwise.

        A run carries on after a failure that concerns one patient. It stops, naming the cause in the Reason of the
        patient it stopped at, when DHIS2 refuses access (HTTP 401 or 403), queues the deletion as a job, or gives an
        answer that contradicts the request or the read-back; when DHIS2's answer is lost and the read-back does not
        prove the deletion; when the read-back fails or finds the patient's data deleted in part; and when the deletion
        took data the preview did not show, or showed elsewhere, which DHIS2 deletes with the patient unchecked
        (Deleted, with the Reason UnpreviewedData): an enrolment or event added, or moved to another org unit, after
        the preview read the patient; its registration moved; or its program ownership changed. The read-back sees the
        enrolments and events you can read, and the program owners of every program, so an enrolment added in a
        program you cannot read shows through its owner. A later run is safe: a deleted patient comes back
        AlreadyDeleted by UID and NotFound by patient ID, since DHIS2 removes its attribute values.

        Every result other than WouldDelete, Declined, Deleted, and AlreadyDeleted writes a non-terminating error whose
        TargetObject is the result, except under -WhatIf. Refusals are written before the first deletion, so
        -ErrorAction Stop deletes nothing while any selected patient is refused or not found; failures are written
        after the last deletion, so that they never cut a confirmed run short.

        Who may delete. A patient with a live enrolment needs F_TEI_CASCADE_DELETE, which the role "Update Delete User"
        carries and ALL includes, or DHIS2 refuses it (E1100). The patient's registration org unit must lie within your
        data-capture org units, on DHIS2 2.40 to 2.42 even for a superuser (E1000). Without ALL, a deletion also needs
        data-write access to the NeoIPC Patient type and to a program of it, and ownership: the owner of the CLOSED
        program NEOIPC_CORE must lie within your data-capture org units (E1003; on 2.43 E1001, E1323, or E1324). The
        preview counts only the enrolments and events you can read, while DHIS2 deletes every live one. Patients
        selected by UID are looked for within your data-capture org units, and on 2.43 for a superuser in every org
        unit.

        DHIS2 2.40 and 2.41 refuse to delete a patient whose enrolment or event has a scheduled program notification,
        which a "schedule message" program-rule action creates: 2.40 answers with an error, 2.41 with HTTP 500 and no
        import report, and the patient ends Failed. From 2.42 DHIS2 deletes such notifications with the patient. When
        http.security.csrf.enabled is on (DHIS2 2.42 and later), DHIS2 refuses every deletion.

        What DHIS2 keeps. The deletion is logical: the patient, its enrolments (set to CANCELLED), and its events stay
        in the database flagged as deleted, the events with all their data values, and so do its notes and
        program-ownership records. Its attribute values, the NeoIPC patient ID among them, are removed; DHIS2 2.40 and
        2.41 keep each removed value in the attribute-value audit (while changelog.tracker is on, as by default), and
        2.42 and later clear the patient's attribute change log, though rows an upgrade did not migrate can remain in
        the older audit table. Analytics tables keep the patient until they are next generated. The messages the
        program notifications of NEOIPC_CORE sent about the patient name its patient ID and stay as they are: removing
        one in the Messaging app removes it for that user only, while DELETE /api/messageConversations/{id} deletes it
        for everyone, which needs ALL, or F_METADATA_IMPORT and, from DHIS2 2.41, being one of the conversation's
        participants, such as a recipient. Removing the records for good is DHIS2's maintenance task for soft-deleted
        tracker data, a separate decision this cmdlet never takes: it removes every soft-deleted patient on the
        instance, not only these, and needs ALL or F_PERFORM_MAINTENANCE. Run it from the Data Administration app, or
        as POST /api/maintenance with softDeletedRelationshipRemoval, softDeletedEventRemoval,
        softDeletedEnrollmentRemoval, and softDeletedTrackedEntityRemoval (softDeletedTrackedEntityInstanceRemoval on
        2.40) set to true together, since the tracked-entity removal alone can fail on records the others remove.
    .PARAMETER OrgUnitCode
        The code of the department the patients belong to. Mandatory with -NeoIpcId and -TrackedEntityId; with
        -InputObject it stands in for a missing OrgUnitId, and a given OrgUnitId must name the same department.
    .PARAMETER NeoIpcId
        The NeoIPC patient IDs to delete, matched exactly within the department.
    .PARAMETER TrackedEntityId
        The DHIS2 UIDs of the patients to delete.
    .PARAMETER InputObject
        Patient records from the pipeline, each with TrackedEntityId and OrgUnitId (the department's UID), and
        optionally NeoIpcId, which must then be the patient's.
    .PARAMETER Auth
        Auth hashtable from Resolve-NeoIPCAuth (Token or Basic).
    .PARAMETER Hostname
        The DHIS2 host. Mandatory, with no default, so that a deletion always names its target.
    .PARAMETER Scheme
        http or https. Default https.
    .PARAMETER Port
        DHIS2 port. Default none (the scheme's).
    .PARAMETER MaximumCount
        The most patients one run may select, checked before any request. Default 25.
    .PARAMETER AllowUnverifiedVersion
        Run on a DHIS2 release the removal was not verified on. The DHIS2 behaviour it relies on was read in the source
        of 2.40.12, 2.41.10, 2.42.6, and 2.43.2, and a removal run against a synthetic instance of each confirmed it; a
        later patch of one of these lines counts as verified. Any other release is refused before a patient is read
        unless this switch is given. On such a release DHIS2's dry run is unverified as well: should its answer report
        any patient as deleted, the run ends at once, though what the dry run did cannot be undone.
    .OUTPUTS
        One [pscustomobject] per selected patient: TrackedEntityId, NeoIpcId, OrgUnitId, OrgUnitCode, EnrollmentIds and
        EventIds (the live ones the preview showed), Outcome, Reason, ErrorCodes, HttpStatusCode, and Message.
    .EXAMPLE
        Remove-NeoIPCPatient -OrgUnitCode NEO_DE_01 -NeoIpcId 'NEO-0042', 'NEO-0043' -Auth $auth -Hostname neoipc.example.org -WhatIf

        Shows what would be deleted, including DHIS2's own refusals, and deletes nothing.
    .EXAMPLE
        Remove-NeoIPCPatient -OrgUnitCode NEO_DE_01 -NeoIpcId 'NEO-0042', 'NEO-0043' -Auth $auth -Hostname neoipc.example.org

        Deletes the two patients after asking once.
    .EXAMPLE
        Remove-NeoIPCPatient -OrgUnitCode NEO_DE_01 -NeoIpcId (Get-Content ./ids.txt) -Auth $auth -Hostname neoipc.example.org -WhatIf |
            Where-Object Outcome -eq 'WouldDelete' | Select-Object TrackedEntityId, OrgUnitId, OrgUnitCode, NeoIpcId | Export-Csv ./plan.csv
        Import-Csv ./plan.csv | Remove-NeoIPCPatient -Auth $auth -Hostname neoipc.example.org

        Writes the plan to a file for review, then deletes exactly the reviewed patients; each must still have the
        patient ID the plan shows.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'NeoIpcId')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'NeoIpcId')]
        [Parameter(Mandatory, ParameterSetName = 'TrackedEntityId')]
        [Parameter(ParameterSetName = 'InputObject')]
        [ArgumentCompleter({
                param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
                $serverKey = Get-NeoIPCServerKey -Scheme $fakeBoundParameters['Scheme'] -Hostname $fakeBoundParameters['Hostname'] -Port $fakeBoundParameters['Port']
                $cacheDir = Join-Path $script:NeoIPCRepoRoot 'data' $serverKey
                $cacheFile = Join-Path $cacheDir 'site-codes.txt'
                if (Test-Path $cacheFile) {
                    Get-Content $cacheFile | Where-Object { $_ -like "$wordToComplete*" }
                }
            })]
        [ValidateNotNullOrEmpty()][string]$OrgUnitCode,

        [Parameter(Mandatory, ParameterSetName = 'NeoIpcId')]
        [ValidateNotNullOrEmpty()][string[]]$NeoIpcId,

        [Parameter(Mandatory, ParameterSetName = 'TrackedEntityId')]
        [ValidateNotNullOrEmpty()][string[]]$TrackedEntityId,

        [Parameter(Mandatory, ParameterSetName = 'InputObject', ValueFromPipeline)]
        [psobject[]]$InputObject,

        [Parameter(Mandatory)][hashtable]$Auth,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Hostname,
        [string]$Scheme = 'https',
        [Nullable[int]]$Port = $null,
        [ValidateRange(1, [int]::MaxValue)][int]$MaximumCount = 25,
        [switch]$AllowUnverifiedVersion
    )

    begin {
        # Per-patient errors are written under the caller's error preference. Everything else runs under Stop, so that a
        # failure outside a try, such as one in step 6 after a deletion, ends the run whatever the caller's preference:
        # under SilentlyContinue or Ignore, PowerShell drops a throw that no try encloses and runs on past it.
        $callerErrorAction = $ErrorActionPreference
        $ErrorActionPreference = 'Stop'
        # With -NeoIpcId or -TrackedEntityId the selection is in the arguments, and piped objects would bind to nothing:
        # the run would delete the arguments' patients and drop the pipeline's with an error per object.
        if ($PSCmdlet.ParameterSetName -ne 'InputObject' -and $MyInvocation.ExpectingInput) {
            $PSCmdlet.ThrowTerminatingError([System.Management.Automation.ErrorRecord]::new(
                    [System.ArgumentException]::new('Only -InputObject takes pipeline input. Pass -NeoIpcId or -TrackedEntityId as arguments, or pipe patient records without them. Nothing was read or deleted.'),
                    'NeoIPCPatientRemovalInputShape', [System.Management.Automation.ErrorCategory]::InvalidArgument, $null))
        }
        $collected = [System.Collections.Generic.List[object]]::new()
    }

    process {
        if ($PSCmdlet.ParameterSetName -eq 'InputObject') { foreach ($o in $InputObject) { $collected.Add($o) } }
    }

    end {
        $ordinal = [System.StringComparer]::Ordinal
        $endpoint = @{ Auth = $Auth; Scheme = $Scheme; Hostname = $Hostname }
        if ($null -ne $Port) { $endpoint['Port'] = $Port }
        $target = '{0}://{1}{2}' -f $Scheme, $Hostname, $(if ($null -ne $Port) { ":$Port" } else { '' })
        $fields = $script:NeoIPCPatientRemovalFields

        # Ends the run with a terminating error. Called from a nested function, it ends the cmdlet at once, past any
        # try/catch around the call, and whatever the caller's error preference.
        function Stop-PatientRemoval([string]$ErrorId, [string]$Message, [string]$Category = 'InvalidOperation', $TargetObject = $null) {
            $record = [System.Management.Automation.ErrorRecord]::new([System.InvalidOperationException]::new($Message),
                "NeoIPCPatientRemoval$ErrorId", [System.Management.Automation.ErrorCategory]$Category, $TargetObject)
            $PSCmdlet.ThrowTerminatingError($record)
        }
        function Write-PatientError($Item) {
            $errorId, $category = switch ($Item.Outcome) {
                'NotFound' { 'NeoIPCPatientNotFound', 'ObjectNotFound' }
                'Refused' { 'NeoIPCPatientRefused', $(if ($Item.Reason -eq 'Dhis2Refused') { 'PermissionDenied' } else { 'InvalidData' }) }
                'Failed' { 'NeoIPCPatientNotDeleted', 'InvalidResult' }
                'Unverified' { 'NeoIPCPatientUnverified', 'InvalidResult' }
                default { 'NeoIPCPatientNotAttempted', 'OperationStopped' }
            }
            $result = New-NeoIPCPatientRemovalResult -Item $Item
            $who = if ($result.TrackedEntityId) { $result.TrackedEntityId } else { "'$($Item.Value)'" }
            $record = [System.Management.Automation.ErrorRecord]::new([System.InvalidOperationException]::new("Patient ${who}: $($Item.Message)"),
                $errorId, [System.Management.Automation.ErrorCategory]$category, $result)
            # The preference in force where WriteError runs decides whether the error ends the run.
            $ErrorActionPreference = $callerErrorAction
            $PSCmdlet.WriteError($record)
        }
        function Set-Verdict($Item, $Verdict) {
            $Item.Outcome = $Verdict.Outcome; $Item.Reason = $Verdict.Reason; $Item.Message = $Verdict.Message
            if ($Verdict.Patient) { $Item.Patient = $Verdict.Patient }
        }
        function Set-Refusal($Item, [string]$Reason, [string]$Message) { $Item.Outcome = 'Refused'; $Item.Reason = $Reason; $Item.Message = $Message }
        function New-DeleteQuery([string]$ImportMode) {
            # Never validationMode: a superuser's SKIP would bypass every check DHIS2 makes.
            @{ async = 'false'; importStrategy = 'DELETE'; atomicMode = 'ALL'; importMode = $ImportMode; reportMode = 'FULL' }
        }
        function ConvertTo-DeleteBody([string[]]$Uid) {
            # Only the UIDs: DHIS2 imports any enrolment or event nested in a tracked entity as well, deleting it too.
            @{ trackedEntities = @($Uid | ForEach-Object { [ordered]@{ trackedEntity = $_ } }) } | ConvertTo-Json -Depth 100 -Compress
        }

        # ---- 1. the selection, before any request -----------------------------------------------------------------------
        $selection = ConvertTo-NeoIPCPatientSelection -Mode $PSCmdlet.ParameterSetName -OrgUnitCode $OrgUnitCode -NeoIpcId $NeoIpcId `
            -TrackedEntityId $TrackedEntityId -InputObject $collected.ToArray() -MaximumCount $MaximumCount
        if ($selection.ErrorId) {
            Stop-PatientRemoval $selection.ErrorId "$($selection.Message) Nothing was read or deleted." $(if ($selection.ErrorId -eq 'TooMany') { 'LimitsExceeded' } else { 'InvalidArgument' })
        }
        $items = @($selection.Items)
        if ($items.Count -eq 0) { return }

        # ---- 2. version, metadata, and departments -----------------------------------------------------------------------
        # Every read passes -WhatIf:$false: the GET helper asks ShouldProcess, and a -WhatIf given to this cmdlet reaches it,
        # which would leave the preview nothing to read.
        try { $info = Invoke-NeoIPCDhis2Get @endpoint -Path 'api/system/info' -Fields 'version' -AsHashtable -Confirm:$false -WhatIf:$false }
        catch { Stop-PatientRemoval 'PreflightFailed' "Reading the DHIS2 version failed: $($_.Exception.Message) Nothing was deleted." }
        $versionText = [string]$info['version']
        if (-not (Test-NeoIPCVerifiedDhis2Version -Text $versionText -Release $script:NeoIPCPatientRemovalVerifiedReleases)) {
            $detail = 'DHIS2 {0} is no release this removal was verified on ({1}, or a later patch of one of their lines).' -f $versionText,
            (($script:NeoIPCPatientRemovalVerifiedReleases | ForEach-Object { "$_" }) -join ', ')
            if (-not $AllowUnverifiedVersion) {
                Stop-PatientRemoval 'UnverifiedVersion' "$detail No patient was read or deleted. Once the removal has been checked on this release, pass -AllowUnverifiedVersion."
            }
            Write-Warning "$detail Going on, as -AllowUnverifiedVersion asks."
        }
        try { $version = ConvertTo-NeoIPCDhis2Version -Text $versionText }
        catch { Stop-PatientRemoval 'PreflightFailed' "$($_.Exception.Message) Nothing was deleted." }
        $dialect = Get-NeoIPCTrackerDialect -Version $version

        try {
            $meta = Invoke-NeoIPCDhis2Get @endpoint -Path 'api/metadata' -AsHashtable -Confirm:$false -WhatIf:$false -QueryParameters @{
                'programs:filter'                = 'code:eq:NEOIPC_CORE'
                'programs:fields'                = 'id,code,trackedEntityType[id,code]'
                'trackedEntityAttributes:filter' = 'code:eq:NEOIPC_PATIENT_ID'
                'trackedEntityAttributes:fields' = 'id,code'
            }
        }
        catch { Stop-PatientRemoval 'PreflightFailed' "Reading the NeoIPC metadata failed: $($_.Exception.Message) Nothing was deleted." }
        $programs = @(@($meta['programs']) | Where-Object { $_ -is [System.Collections.IDictionary] -and [string]$_['code'] -ceq 'NEOIPC_CORE' })
        $attributes = @(@($meta['trackedEntityAttributes']) | Where-Object { $_ -is [System.Collections.IDictionary] -and [string]$_['code'] -ceq 'NEOIPC_PATIENT_ID' })
        if ($programs.Count -ne 1 -or $attributes.Count -ne 1) {
            Stop-PatientRemoval 'PreflightFailed' 'The instance does not hold exactly one program NEOIPC_CORE and one tracked-entity attribute NEOIPC_PATIENT_ID that your account can read. Nothing was deleted.'
        }
        $programId = [string]$programs[0]['id']
        $patientType = $programs[0]['trackedEntityType']
        if ($patientType -isnot [System.Collections.IDictionary] -or [string]$patientType['code'] -cne 'NEOIPC_PATIENT') {
            Stop-PatientRemoval 'PreflightFailed' 'The program NEOIPC_CORE does not register tracked entities of the type NEOIPC_PATIENT. Nothing was deleted.'
        }
        $typeId = [string]$patientType['id']
        $attributeId = [string]$attributes[0]['id']

        # Org-unit roles are told by org-unit group code, not by hierarchy level.
        $departments = [System.Collections.Generic.Dictionary[string, object]]::new($ordinal)
        function Read-OrgUnit([string]$Filter) {
            try { $found = Invoke-NeoIPCDhis2Get @endpoint -Path 'api/organisationUnits' -Filter $Filter -Fields 'id', 'code', 'organisationUnitGroups[code]' -AsHashtable -Confirm:$false -WhatIf:$false }
            catch { Stop-PatientRemoval 'PreflightFailed' "Reading the departments failed: $($_.Exception.Message) Nothing was deleted." }
            foreach ($ou in @($found['organisationUnits'])) {
                if ($ou -isnot [System.Collections.IDictionary]) { continue }
                $groups = @(@($ou['organisationUnitGroups']) | Where-Object { $_ -is [System.Collections.IDictionary] } | ForEach-Object { [string]$_['code'] })
                [pscustomobject]@{ Id = [string]$ou['id']; Code = [string]$ou['code']; IsDepartment = $groups -ccontains 'NEO_DEPARTMENT' }
            }
        }
        $statedId = $null
        if ($OrgUnitCode) {
            $hits = @(Read-OrgUnit "code:eq:$OrgUnitCode" | Where-Object { $_.Code -ceq $OrgUnitCode })
            if ($hits.Count -ne 1) { Stop-PatientRemoval 'DepartmentNotFound' "No org unit has the code '$OrgUnitCode' (codes compare exactly). Nothing was deleted." 'ObjectNotFound' }
            if (-not $hits[0].IsDepartment) {
                Stop-PatientRemoval 'NotADepartment' "The org unit '$OrgUnitCode' is not a department: it is not in the org-unit group NEO_DEPARTMENT. Nothing was deleted." 'InvalidArgument'
            }
            $statedId = $hits[0].Id
            $departments[$statedId] = $hits[0]
        }
        $pipedIds = [System.Collections.Generic.HashSet[string]]::new($ordinal)
        foreach ($item in $items) { if (-not $item.Outcome -and $item.OrgUnitId -and -not $departments.ContainsKey($item.OrgUnitId)) { [void]$pipedIds.Add($item.OrgUnitId) } }
        if ($pipedIds.Count -gt 0) {
            foreach ($ou in @(Read-OrgUnit ('id:in:[{0}]' -f ($pipedIds -join ',')))) { if ($pipedIds.Contains($ou.Id)) { $departments[$ou.Id] = $ou } }
        }
        foreach ($item in $items) {
            if ($item.Outcome) { continue }
            $id = if ($item.OrgUnitId) { $item.OrgUnitId } else { $statedId }
            if ($statedId -and $id -cne $statedId) { Set-Refusal $item 'DepartmentMismatch' "The input names the org unit '$id', not the department $OrgUnitCode." }
            elseif (-not $departments.ContainsKey($id)) { Set-Refusal $item 'NotADepartment' "No org unit has the UID '$id'." }
            elseif (-not $departments[$id].IsDepartment) { Set-Refusal $item 'NotADepartment' "The org unit $($departments[$id].Code) is not a department: it is not in the org-unit group NEO_DEPARTMENT." }
            else { $item.Department = $departments[$id] }
        }
        foreach ($item in $items) {
            # NEOIPC-COMPAT(dhis2-pre-2.42-filter-escape): see Test-NeoIPCTrackerFilterValue in Private/TrackerDialect.ps1.
            if (-not $item.Outcome -and $item.Kind -eq 'NeoIpcId' -and -not (Test-NeoIPCTrackerFilterValue -Dialect $dialect -Value $item.Value)) {
                Set-Refusal $item 'InvalidInput' "DHIS2 $versionText may look a patient ID that holds more than one '/' up as another one; select this patient by its UID."
            }
        }

        # ---- 3. the patients --------------------------------------------------------------------------------------------
        # Every read takes deleted data too, so that the read-back can tell data deleted before the run from data the
        # deletion took that the preview never showed. A deleted patient cannot match a patient ID: DHIS2 removes its
        # attribute values.
        foreach ($item in @($items | Where-Object { -not $_.Outcome -and $_.Kind -eq 'NeoIpcId' })) {
            try {
                $found = Get-NeoIPCTrackedEntityList -Endpoint $endpoint -Dialect $dialect -TrackedEntityTypeId $typeId -OrgUnitMode 'SELECTED' `
                    -OrgUnitId $item.Department.Id -AttributeId $attributeId -AttributeValue $item.Value -IncludeDeleted -Fields $fields
            }
            catch { Stop-PatientRemoval 'PreflightFailed' "Looking up the NeoIPC patient ID '$($item.Value)' failed: $($_.Exception.Message) Nothing was deleted." }
            $records = @($found | ForEach-Object { ConvertTo-NeoIPCPatientRecord -TrackedEntity $_ -PatientIdAttributeId $attributeId })
            Set-Verdict $item (Resolve-NeoIPCPatientMatch -Item $item -Record $records -DepartmentId $item.Department.Id -DepartmentCode $item.Department.Code `
                    -ProgramId $programId -TrackedEntityTypeId $typeId)
        }
        $uidItems = @($items | Where-Object { -not $_.Outcome -and $_.Kind -eq 'TrackedEntityId' })
        if ($uidItems.Count -gt 0) {
            # includeDeleted, so that a patient deleted earlier is told from one that never existed.
            try {
                $found = Get-NeoIPCTrackedEntityList -Endpoint $endpoint -Dialect $dialect -TrackedEntityTypeId $typeId -OrgUnitMode 'CAPTURE' `
                    -TrackedEntityId @($uidItems | ForEach-Object { $_.Value }) -IncludeDeleted -Fields $fields
            }
            catch { Stop-PatientRemoval 'PreflightFailed' "Reading the selected patients failed: $($_.Exception.Message) Nothing was deleted." }
            $byUid = [System.Collections.Generic.Dictionary[string, object]]::new($ordinal)
            foreach ($te in $found) {
                $record = ConvertTo-NeoIPCPatientRecord -TrackedEntity $te -PatientIdAttributeId $attributeId
                $byUid[$record.TrackedEntityId] = $record
            }
            foreach ($item in $uidItems) {
                $records = @(if ($byUid.ContainsKey($item.Value)) { $byUid[$item.Value] })
                Set-Verdict $item (Resolve-NeoIPCPatientMatch -Item $item -Record $records -DepartmentId $item.Department.Id -DepartmentCode $item.Department.Code `
                        -ProgramId $programId -TrackedEntityTypeId $typeId)
            }
        }

        # ---- 4. DHIS2's dry run -----------------------------------------------------------------------------------------
        $deletable = @($items | Where-Object { -not $_.Outcome })
        if ($deletable.Count -gt 0) {
            $uids = [string[]]@($deletable | ForEach-Object { $_.Patient.TrackedEntityId })
            # -WhatIf:$false: the dry run changes nothing, and it is what makes -WhatIf show DHIS2's own refusals.
            try { $response = Invoke-NeoIPCDhis2Post @endpoint -Path 'api/tracker' -Body (ConvertTo-DeleteBody $uids) -QueryParameters (New-DeleteQuery 'VALIDATE') -Confirm:$false -WhatIf:$false }
            catch { Stop-PatientRemoval 'PreflightFailed' "DHIS2's dry run failed: $($_.Exception.Message) Nothing was deleted." }
            $dry = ConvertFrom-NeoIPCTrackerImportResponse -StatusCode $response.StatusCode -Body $response.Body -TrackedEntityId $uids
            if (-not $dry.IsReport) {
                Stop-PatientRemoval 'PreflightFailed' "DHIS2's dry run answered HTTP $($dry.HttpStatusCode) without an import report: $($dry.Message) Nothing was deleted."
            }
            # A validation persists nothing, so its report lists no object. One that does means the release carried the
            # deletion out, and no outcome but this stop would be true.
            if ($dry.ReportedUids.Count -gt 0) {
                Stop-PatientRemoval 'DryRunDeleted' ("DHIS2's dry run reports {0} as deleted, so this release may have carried the deletion out instead of only validating it. Check these patients on the instance; the run sent nothing further." -f ($dry.ReportedUids -join ', ')) 'InvalidResult'
            }
            if ($dry.ForeignUids.Count -gt 0) {
                Stop-PatientRemoval 'PreflightFailed' ("DHIS2's dry run named UIDs it was not asked about ({0}). Nothing was deleted." -f ($dry.ForeignUids -join ', '))
            }
            if ($dry.Status -ceq 'ERROR' -and $dry.ErrorCodes.Count -eq 0) {
                Stop-PatientRemoval 'PreflightFailed' "DHIS2's dry run failed without refusing any patient: $($dry.Message) Nothing was deleted."
            }
            foreach ($item in $deletable) {
                $uid = $item.Patient.TrackedEntityId
                if (-not $dry.ErrorCodes.ContainsKey($uid)) { continue }
                $seen = [System.Collections.Generic.HashSet[string]]::new($ordinal)
                $item.ErrorCodes = @($dry.ErrorCodes[$uid] | Where-Object { $seen.Add($_) })
                $item.HttpStatusCode = $dry.HttpStatusCode
                $text = $dry.ErrorMessages[$uid] -join ' / '
                if ($item.ErrorCodes -ccontains 'E1063') { $item.Outcome = 'NotFound'; $item.Reason = 'NotFound'; $item.Message = "DHIS2 reports that the patient does not exist: $text" }
                elseif ($item.ErrorCodes -ccontains 'E1114') { $item.Outcome = 'AlreadyDeleted'; $item.Reason = 'AlreadyDeleted'; $item.Message = 'DHIS2 reports that the patient is already deleted.' }
                else { Set-Refusal $item 'Dhis2Refused' "DHIS2's dry run refuses the deletion: $text" }
            }
        }

        # ---- 5. the preview and the confirmation ------------------------------------------------------------------------
        Write-Host ('Removing NeoIPC patients on {0} (DHIS2 {1})' -f $target, $versionText)
        foreach ($item in $items) {
            $r = New-NeoIPCPatientRemovalResult -Item $item
            $status = if (-not $item.Outcome) { 'to delete' }
            else { '{0}{1}: {2}' -f $item.Outcome, $(if ($item.Reason -and $item.Reason -ne $item.Outcome) { " ($($item.Reason))" } else { '' }), $item.Message }
            Write-Host ('  {0,-16} {1,-20} {2,-11} {3,3} enrolment(s) {4,4} event(s)  {5}' -f $r.OrgUnitCode, $r.NeoIpcId, $r.TrackedEntityId,
                $r.EnrollmentIds.Count, $r.EventIds.Count, $status) -ForegroundColor $(if ($item.Outcome) { 'Yellow' } else { 'White' })
        }
        $deletable = @($items | Where-Object { -not $_.Outcome })
        $enrolmentCount = 0; $eventCount = 0
        foreach ($item in $deletable) { $live = Get-NeoIPCPatientLiveData -Record $item.Patient; $enrolmentCount += $live.Enrollments.Count; $eventCount += $live.Events.Count }
        $notDeletable = @($items | Where-Object { $_.Outcome })
        Write-Host ('  {0} patient(s) with {1} enrolment(s) and {2} event(s) to delete; {3} not to delete.' -f $deletable.Count, $enrolmentCount, $eventCount, $notDeletable.Count)
        Write-Host '  The counts cover the enrolments and events you can read; DHIS2 deletes every live one of each patient.' -ForegroundColor Gray

        if (-not $WhatIfPreference) { foreach ($item in @($items | Where-Object { $_.Outcome -in 'Refused', 'NotFound' })) { Write-PatientError $item } }
        $confirmed = $false
        if ($deletable.Count -gt 0) {
            $codes = [System.Collections.Generic.List[string]]::new()
            foreach ($item in $deletable) { if (-not $codes.Contains($item.Department.Code)) { $codes.Add($item.Department.Code) } }
            $refusedCount = @($items | Where-Object { $_.Outcome -in 'Refused', 'NotFound' }).Count
            $prompt = Format-NeoIPCPatientRemovalPrompt -PatientCount $deletable.Count -EnrollmentCount $enrolmentCount -EventCount $eventCount `
                -OrgUnitCode $codes.ToArray() -Target $target -Dhis2Version $versionText -RefusedCount $refusedCount
            $confirmed = $PSCmdlet.ShouldProcess($prompt.Description, $prompt.Query, 'Deleting NeoIPC patients')
            if (-not $confirmed) {
                $outcome = if ($WhatIfPreference) { 'WouldDelete' } else { 'Declined' }
                foreach ($item in $deletable) { $item.Outcome = $outcome; $item.Reason = $null; $item.Message = $(if ($WhatIfPreference) { 'Would be deleted.' } else { 'Not deleted: the confirmation was declined.' }) }
                if (-not $WhatIfPreference) { Write-Host 'Nothing was deleted.' }
            }
        }

        # ---- 6. the deletions, one patient each, each read back ---------------------------------------------------------
        $stopped = $null
        if ($confirmed) {
            $done = 0
            foreach ($item in $deletable) {
                $uid = $item.Patient.TrackedEntityId
                if ($stopped) { $item.Outcome = 'NotAttempted'; $item.Reason = 'BatchStopped'; $item.Message = "Not attempted: the run stopped after $stopped."; continue }
                Write-Progress -Activity 'Deleting NeoIPC patients' -Status $uid -PercentComplete ([int](100 * $done / $deletable.Count))
                $transportFailure = $null; $response = $null
                try { $response = Invoke-NeoIPCDhis2Post @endpoint -Path 'api/tracker' -Body (ConvertTo-DeleteBody @($uid)) -QueryParameters (New-DeleteQuery 'COMMIT') -Confirm:$false }
                catch { $transportFailure = $_.Exception.Message }
                $converted = if ($response) { ConvertFrom-NeoIPCTrackerImportResponse -StatusCode $response.StatusCode -Body $response.Body -TrackedEntityId @($uid) } else { $null }
                $answer = Get-NeoIPCTrackerDeleteAnswer -Response $converted -TrackedEntityId $uid -TransportFailure $transportFailure

                $readBack = $null; $failure = $null; $single = $null
                try {
                    $back = Get-NeoIPCTrackedEntityList -Endpoint $endpoint -Dialect $dialect -TrackedEntityTypeId $typeId -OrgUnitMode 'CAPTURE' `
                        -TrackedEntityId @($uid) -IncludeDeleted -Fields $fields
                    if (@($back).Count -eq 1) { $readBack = ConvertTo-NeoIPCPatientRecord -TrackedEntity @($back)[0] -PatientIdAttributeId $attributeId }
                }
                catch { $failure = $_.Exception.Message }
                try { $single = Get-NeoIPCDhis2StatusCode @endpoint -Path "api/tracker/trackedEntities/$uid" }
                catch { if (-not $failure) { $failure = $_.Exception.Message } }
                $state = Get-NeoIPCPatientReadBackState -Record $readBack -Previewed $item.Patient -SingleReadStatus $single -Failure $failure
                $result = Get-NeoIPCPatientRemovalOutcome -Answer $answer -ReadBack $state

                $item.Outcome = $result.Outcome; $item.Reason = $result.Reason; $item.Message = $result.Message; $item.Warning = $result.Warning
                $item.ErrorCodes = @($answer.ErrorCodes); $item.HttpStatusCode = $answer.HttpStatusCode
                Write-Host ('  {0} {1}{2}{3}' -f $uid, $result.Outcome, $(if ($result.Reason) { " ($($result.Reason))" } else { '' }),
                    $(if ($result.Outcome -ne 'Deleted') { " — $($result.Message)" } else { '' })) -ForegroundColor $(if ($result.Outcome -eq 'Deleted') { 'Green' } else { 'Red' })
                if ($result.Stop) { $stopped = "patient $uid ($($result.Reason))" }
                $done++
            }
            Write-Progress -Activity 'Deleting NeoIPC patients' -Completed
        }

        # ---- the results, errors, and summary ---------------------------------------------------------------------------
        $results = @($items | ForEach-Object { New-NeoIPCPatientRemovalResult -Item $_ })
        $results
        foreach ($item in $items) {
            if ($item.Outcome -eq 'AlreadyDeleted') { Write-Warning "Patient $(if ($item.Patient) { $item.Patient.TrackedEntityId } else { $item.Value }): $($item.Message)" }
            if ($item.Warning) { Write-Warning "Patient $($item.Patient.TrackedEntityId): $($item.Warning)" }
        }
        if ($confirmed) { foreach ($item in @($deletable | Where-Object { $_.Outcome -in 'Failed', 'Unverified', 'NotAttempted' })) { Write-PatientError $item } }
        $deletedCount = @($items | Where-Object { $_.Outcome -eq 'Deleted' }).Count
        if ($confirmed) {
            Write-Host ('Deleted {0} of {1} selected patient(s). DHIS2 keeps deleted patients in its database, flagged as deleted; Get-Help Remove-NeoIPCPatient -Full says what remains and how to remove it for good.' -f $deletedCount, $items.Count)
        }
        if ($stopped) {
            Stop-PatientRemoval 'Stopped' "The run stopped after $stopped; the patients after it were not attempted. Check the results, then run again for those still to delete." 'OperationStopped' $results
        }
    }
}
