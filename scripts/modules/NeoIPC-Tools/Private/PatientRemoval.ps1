#Requires -Version 7.6
# Planning for Remove-NeoIPCPatient, free of I/O: the selection, the rules that decide which patients a run may delete,
# the reading of DHIS2's import answers and of the read-back, and the outcome they lead to. The DHIS2 behaviour each
# rule answers to was read in the source of the releases in $NeoIPCPatientRemovalVerifiedReleases.

# The DHIS2 releases whose source the removal's rules were read in, and on which a removal run against a synthetic
# instance confirmed them, one per line. A later patch of one of these lines counts as verified; any other release
# needs -AllowUnverifiedVersion.
$script:NeoIPCPatientRemovalVerifiedReleases = @([version]'2.40.12', [version]'2.41.10', [version]'2.42.6', [version]'2.43.2')

# What a removal reads of a tracked entity. DHIS2 serializes each of these whenever it is asked for, empty lists and a
# false deleted flag included, so a read that lacks one did not return what was asked for.
$script:NeoIPCPatientRemovalFields = @(
    'trackedEntity', 'trackedEntityType', 'orgUnit', 'deleted', 'attributes[attribute,code,value]',
    'programOwners[program,orgUnit]',
    'enrollments[enrollment,program,orgUnit,status,deleted,events[event,programStage,orgUnit,status,deleted]]'
)

function Test-NeoIPCPatientRemovalMember {
    # Whether an object carries a member of the given name: a key of a dictionary, a property of anything else.
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()]$InputObject, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $InputObject) { return $false }
    if ($InputObject -is [System.Collections.IDictionary]) { return $InputObject.Contains($Name) }
    $null -ne $InputObject.PSObject.Properties[$Name]
}

function Get-NeoIPCPatientRemovalMember {
    # The value of an object's member (a dictionary's key, anything else's property), or $null. A list comes back as
    # the list, never unrolled.
    [CmdletBinding()]
    param([AllowNull()]$InputObject, [Parameter(Mandatory)][string]$Name)
    if (-not (Test-NeoIPCPatientRemovalMember -InputObject $InputObject -Name $Name)) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) { return , $InputObject[$Name] }
    return , $InputObject.PSObject.Properties[$Name].Value
}

function ConvertTo-NeoIPCPatientSelection {
    # The patients a run is asked to delete: one item per distinct selector, in the order given. Exact duplicates
    # collapse; selectors that differ only in case, that contradict each other, or that are malformed are refused
    # rather than guessed at. Input the run cannot read as a selection at all, and more items than -MaximumCount, end
    # the run before any request (ErrorId and Message set, no Items).
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateSet('NeoIpcId', 'TrackedEntityId', 'InputObject')][string]$Mode,
        [AllowNull()][AllowEmptyString()][string]$OrgUnitCode,
        [string[]]$NeoIpcId,
        [string[]]$TrackedEntityId,
        [object[]]$InputObject,
        [Parameter(Mandatory)][int]$MaximumCount
    )
    $ordinal = [System.StringComparer]::Ordinal
    function New-SelectionFailure([string]$ErrorId, [string]$Message) { [pscustomobject]@{ Items = @(); ErrorId = $ErrorId; Message = $Message } }
    $hint = 'Pipe objects that carry TrackedEntityId and OrgUnitId (as Read-PatientInfo emits them), or pass -OrgUnitCode with -NeoIpcId or -TrackedEntityId.'

    $raw = [System.Collections.Generic.List[object]]::new()
    switch ($Mode) {
        'NeoIpcId' { foreach ($v in $NeoIpcId) { $raw.Add([pscustomobject]@{ Kind = 'NeoIpcId'; Value = [string]$v; OrgUnitId = $null; Expected = $null; Input = $v }) } }
        'TrackedEntityId' { foreach ($v in $TrackedEntityId) { $raw.Add([pscustomobject]@{ Kind = 'TrackedEntityId'; Value = [string]$v; OrgUnitId = $null; Expected = $null; Input = $v }) } }
        'InputObject' {
            foreach ($o in $InputObject) {
                if ($null -eq $o -or $o -is [string] -or $o -is [System.ValueType]) { return New-SelectionFailure 'InputShape' "Piped input '$o' is no patient record. $hint" }
                foreach ($name in 'EnrollmentId', 'EventId') {
                    if (Test-NeoIPCPatientRemovalMember -InputObject $o -Name $name) {
                        return New-SelectionFailure 'InputShape' "A piped object carries $name, so it is an enrolment or event record: deleting by it would delete its whole patient. Pipe patient records, such as Read-PatientInfo's output, or select the patients with -OrgUnitCode and -NeoIpcId or -TrackedEntityId."
                    }
                }
                $uid = Get-NeoIPCPatientRemovalMember -InputObject $o -Name 'TrackedEntityId'
                if ($uid -isnot [string] -or $uid -eq '') { return New-SelectionFailure 'InputShape' "A piped object carries no single TrackedEntityId. $hint" }
                $ou = Get-NeoIPCPatientRemovalMember -InputObject $o -Name 'OrgUnitId'
                if ($null -ne $ou -and $ou -isnot [string]) { return New-SelectionFailure 'InputShape' "The piped object for '$uid' carries an OrgUnitId that is no single string." }
                if ($ou -eq '') { $ou = $null }
                if (-not $ou -and -not $OrgUnitCode) { return New-SelectionFailure 'InputShape' "The piped object for '$uid' names no department: give it an OrgUnitId, or pass -OrgUnitCode." }
                $expected = Get-NeoIPCPatientRemovalMember -InputObject $o -Name 'NeoIpcId'
                if ($null -ne $expected -and $expected -isnot [string]) { return New-SelectionFailure 'InputShape' "The piped object for '$uid' carries a NeoIpcId that is no single string." }
                if ($expected -eq '') { $expected = $null }
                $raw.Add([pscustomobject]@{ Kind = 'TrackedEntityId'; Value = $uid; OrgUnitId = $ou; Expected = $expected; Input = $o })
            }
        }
    }

    $items = [System.Collections.Generic.List[object]]::new()
    $byValue = [System.Collections.Generic.Dictionary[string, object]]::new($ordinal)
    foreach ($r in $raw) {
        if ($byValue.ContainsKey($r.Value)) {
            $first = $byValue[$r.Value]
            if (-not $first.Outcome -and ($first.OrgUnitId -cne $r.OrgUnitId -or $first.ExpectedNeoIpcId -cne $r.Expected)) {
                $first.Outcome = 'Refused'; $first.Reason = 'ConflictingInput'
                $first.Message = "'$($r.Value)' is selected twice with different departments or patient IDs."
            }
            continue
        }
        $item = [pscustomobject]@{
            Index = $items.Count; Kind = $r.Kind; Value = $r.Value; OrgUnitCode = $(if ($OrgUnitCode) { $OrgUnitCode } else { $null })
            OrgUnitId = $r.OrgUnitId; ExpectedNeoIpcId = $r.Expected; Input = $r.Input; Department = $null; Patient = $null
            Outcome = $null; Reason = $null; Message = $null; ErrorCodes = @(); HttpStatusCode = $null; Warning = $null
        }
        $byValue[$r.Value] = $item
        $items.Add($item)
    }

    # Ignoring case on purpose, to find the selectors that differ only in case: DHIS2 compares UIDs exactly but patient
    # IDs ignoring case, so such a pair is either two patients one of which a lookup cannot tell apart, or a typing
    # error. Every member of such a group is refused.
    $byFold = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[object]]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $items) {
        if (-not $byFold.ContainsKey($item.Value)) { $byFold[$item.Value] = [System.Collections.Generic.List[object]]::new() }
        $byFold[$item.Value].Add($item)
    }
    foreach ($group in $byFold.Values) {
        if ($group.Count -lt 2) { continue }
        $names = ($group | ForEach-Object { "'$($_.Value)'" }) -join ', '
        foreach ($item in $group) {
            if ($item.Outcome) { continue }
            $item.Outcome = 'Refused'; $item.Reason = 'CaseVariantInput'
            $item.Message = "The selection holds $names, which differ only in case."
        }
    }

    foreach ($item in $items) {
        if ($item.Outcome) { continue }
        $problem = if ($item.Kind -eq 'TrackedEntityId' -and -not (Test-NeoIPCMetadataUid -Id $item.Value)) { "'$($item.Value)' is not a DHIS2 UID." }
        elseif ($item.Kind -eq 'NeoIpcId' -and $item.Value -cne $item.Value.Trim()) { "The patient ID '$($item.Value)' has leading or trailing white space." }
        elseif ($item.OrgUnitId -and -not (Test-NeoIPCMetadataUid -Id $item.OrgUnitId)) { "The OrgUnitId '$($item.OrgUnitId)' is not a DHIS2 UID." }
        if ($problem) { $item.Outcome = 'Refused'; $item.Reason = 'InvalidInput'; $item.Message = $problem }
    }

    if ($items.Count -gt $MaximumCount) {
        return New-SelectionFailure 'TooMany' ("The selection names {0} patients, more than -MaximumCount ({1}) allows. Narrow it, or check it and raise -MaximumCount." -f $items.Count, $MaximumCount)
    }
    [pscustomobject]@{ Items = $items.ToArray(); ErrorId = $null; Message = $null }
}

function ConvertTo-NeoIPCPatientRecord {
    # A tracked entity as the removal reads it: its UID, type, registration org unit, NeoIPC patient ID, deleted flag,
    # program owners, and enrolments with their events. Complete is false when the read lacks any of these.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$TrackedEntity,
        [Parameter(Mandatory)][string]$PatientIdAttributeId
    )
    $complete = $true
    foreach ($key in 'trackedEntity', 'trackedEntityType', 'orgUnit', 'deleted', 'attributes', 'programOwners', 'enrollments') {
        if (-not $TrackedEntity.Contains($key)) { $complete = $false }
    }
    $patientIds = @(@($TrackedEntity['attributes']) |
            Where-Object { $_ -is [System.Collections.IDictionary] -and [string]$_['attribute'] -ceq $PatientIdAttributeId } |
            ForEach-Object { [string]$_['value'] })
    $owners = foreach ($po in @($TrackedEntity['programOwners'])) {
        if ($po -is [System.Collections.IDictionary]) { [pscustomobject]@{ ProgramId = [string]$po['program']; OrgUnitId = [string]$po['orgUnit'] } }
    }
    $enrollments = foreach ($en in @($TrackedEntity['enrollments'])) {
        if ($en -isnot [System.Collections.IDictionary]) { continue }
        foreach ($key in 'enrollment', 'program', 'orgUnit', 'deleted', 'events') { if (-not $en.Contains($key)) { $complete = $false } }
        $trackerEvents = foreach ($ev in @($en['events'])) {
            if ($ev -isnot [System.Collections.IDictionary]) { continue }
            foreach ($key in 'event', 'orgUnit', 'deleted') { if (-not $ev.Contains($key)) { $complete = $false } }
            [pscustomobject]@{ EventId = [string]$ev['event']; ProgramStageId = [string]$ev['programStage']; OrgUnitId = [string]$ev['orgUnit']; Status = [string]$ev['status']; Deleted = $ev['deleted'] -eq $true }
        }
        [pscustomobject]@{
            EnrollmentId = [string]$en['enrollment']; ProgramId = [string]$en['program']; OrgUnitId = [string]$en['orgUnit']
            Status = [string]$en['status']; Deleted = $en['deleted'] -eq $true; Events = @($trackerEvents)
        }
    }
    [pscustomobject]@{
        TrackedEntityId     = [string]$TrackedEntity['trackedEntity']
        TrackedEntityTypeId = [string]$TrackedEntity['trackedEntityType']
        OrgUnitId           = [string]$TrackedEntity['orgUnit']
        NeoIpcIds           = $patientIds
        NeoIpcId            = $(if ($patientIds.Count -eq 1) { $patientIds[0] } else { $null })
        Deleted             = $TrackedEntity['deleted'] -eq $true
        Owners              = @($owners)
        Enrollments         = @($enrollments)
        Complete            = $complete
    }
}

function Get-NeoIPCPatientLiveData {
    # The enrolments and events of a patient record that are not deleted: what a deletion takes with the patient, as
    # far as the read shows it.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)]$Record)
    $liveEnrollments = @($Record.Enrollments | Where-Object { -not $_.Deleted })
    $liveEvents = @($liveEnrollments | ForEach-Object { $_.Events } | Where-Object { $_ -and -not $_.Deleted })
    [pscustomobject]@{ Enrollments = $liveEnrollments; Events = $liveEvents }
}

function Resolve-NeoIPCPatientMatch {
    # The verdict on one selected item, from the tracked entities its lookup returned: the patient the run may delete
    # (Outcome $null), or why not. A patient ID is matched exactly, since DHIS2 compares it ignoring case. A patient is
    # deletable only when everything the read shows of it lies in the stated department and in NEOIPC_CORE, because
    # DHIS2 deletes every live enrolment and event of the patient with it, in any program, without checking them.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Item,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Record,
        [Parameter(Mandatory)][string]$DepartmentId,
        [Parameter(Mandatory)][string]$DepartmentCode,
        [Parameter(Mandatory)][string]$ProgramId,
        [Parameter(Mandatory)][string]$TrackedEntityTypeId
    )
    function New-Verdict([string]$Outcome, [string]$Reason, [string]$Message, $Patient) {
        [pscustomobject]@{ Outcome = $(if ($Outcome) { $Outcome } else { $null }); Reason = $Reason; Message = $Message; Patient = $Patient }
    }
    function Get-Candidate($Records) { ($Records | ForEach-Object { '{0} ({1})' -f $_.TrackedEntityId, ($_.NeoIpcIds -join '/') }) -join ', ' }

    if ($Item.Kind -eq 'NeoIpcId') {
        $exact = @($Record | Where-Object { $_.NeoIpcIds -ccontains $Item.Value })
        $variants = @($Record | Where-Object {
                -not ($_.NeoIpcIds -ccontains $Item.Value) -and
                @($_.NeoIpcIds | Where-Object { [string]::Equals($_, $Item.Value, [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
            })
        if ($exact.Count -eq 0) {
            $message = "No patient with the NeoIPC patient ID '$($Item.Value)' in department $DepartmentCode."
            if ($variants.Count -gt 0) { $message += " Patients whose ID differs only in case: $(Get-Candidate $variants)." }
            return New-Verdict 'NotFound' 'NotFound' $message $null
        }
        if ($exact.Count -gt 1 -or $variants.Count -gt 0) {
            return New-Verdict 'Refused' 'Ambiguous' "The NeoIPC patient ID '$($Item.Value)' matches more than one patient in department ${DepartmentCode}: $(Get-Candidate @($exact + $variants))." $null
        }
        $patient = $exact[0]
    }
    else {
        $hits = @($Record | Where-Object { $_.TrackedEntityId -ceq $Item.Value })
        if ($hits.Count -eq 0) { return New-Verdict 'NotFound' 'NotFound' "No patient with the UID '$($Item.Value)' among the patients DHIS2 lets you capture data for." $null }
        $patient = $hits[0]
    }

    if (-not $patient.Complete) {
        return New-Verdict 'Refused' 'IncompleteRead' "DHIS2's read of patient $($patient.TrackedEntityId) lacked fields the removal checks, so it cannot tell what the deletion would take with it." $patient
    }
    if ($patient.Deleted) { return New-Verdict 'AlreadyDeleted' 'AlreadyDeleted' "Patient $($patient.TrackedEntityId) is already deleted." $patient }
    if ($patient.TrackedEntityTypeId -cne $TrackedEntityTypeId) {
        return New-Verdict 'Refused' 'NotAPatient' "$($patient.TrackedEntityId) is a tracked entity of another type than NEOIPC_PATIENT." $patient
    }
    if ($Item.ExpectedNeoIpcId -and $patient.NeoIpcIds -cnotcontains $Item.ExpectedNeoIpcId) {
        return New-Verdict 'Refused' 'InputMismatch' ("Patient {0} has the NeoIPC patient ID '{1}', not '{2}' as the input says." -f $patient.TrackedEntityId, ($patient.NeoIpcIds -join '/'), $Item.ExpectedNeoIpcId) $patient
    }
    $coreOwners = @($patient.Owners | Where-Object { $_.ProgramId -ceq $ProgramId })
    if ($patient.OrgUnitId -cne $DepartmentId -or @($coreOwners | Where-Object { $_.OrgUnitId -cne $DepartmentId }).Count -gt 0) {
        return New-Verdict 'Refused' 'OutsideDepartment' "Patient $($patient.TrackedEntityId) is registered in, or owned by, an org unit other than department $DepartmentCode." $patient
    }
    $live = Get-NeoIPCPatientLiveData -Record $patient
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $otherPrograms = @(@($live.Enrollments | ForEach-Object { $_.ProgramId }) + @($patient.Owners | ForEach-Object { $_.ProgramId }) |
            Where-Object { $_ -cne $ProgramId -and $seen.Add($_) })
    if ($otherPrograms.Count -gt 0) {
        return New-Verdict 'Refused' 'OtherProgram' ("Patient {0} has data in other programs ({1}), which its deletion would delete as well." -f $patient.TrackedEntityId, ($otherPrograms -join ', ')) $patient
    }
    $elsewhere = @(@($live.Enrollments | Where-Object { $_.OrgUnitId -cne $DepartmentId } | ForEach-Object { "enrolment $($_.EnrollmentId)" }) +
        @($live.Events | Where-Object { $_.OrgUnitId -cne $DepartmentId } | ForEach-Object { "event $($_.EventId)" }))
    if ($elsewhere.Count -gt 0) {
        return New-Verdict 'Refused' 'OtherOrgUnit' ("Patient {0} has data outside department {1} ({2}), which its deletion would delete as well." -f $patient.TrackedEntityId, $DepartmentCode, ($elsewhere -join ', ')) $patient
    }
    New-Verdict $null $null $null $patient
}

function ConvertFrom-NeoIPCTrackerImportResponse {
    # DHIS2's answer to a synchronous tracker import that deletes tracked entities, read for the UIDs the request
    # carried: whether the body is an import report at all (some failures come back as a plain WebMessage), its status,
    # the error codes and messages per UID, every UID its tracked-entity object reports name (ReportedUids), those of
    # them the request carried (DeletedUids), and every UID it names that the request did not carry. Matched by UID,
    # never by an object report's index, which is not the position in the request.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]$StatusCode,
        [AllowNull()]$Body,
        [Parameter(Mandatory)][string[]]$TrackedEntityId
    )
    $ordinal = [System.StringComparer]::Ordinal
    $asked = [System.Collections.Generic.HashSet[string]]::new([string[]]$TrackedEntityId, $ordinal)
    $errorCodes = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]]::new($ordinal)
    $errorMessages = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]]::new($ordinal)
    $deleted = [System.Collections.Generic.HashSet[string]]::new($ordinal)
    $reported = [System.Collections.Generic.List[string]]::new()
    $foreign = [System.Collections.Generic.List[string]]::new()
    $structured = $null -ne $Body -and $Body -isnot [string] -and $Body -isnot [System.ValueType]
    $isReport = $structured -and (Test-NeoIPCPatientRemovalMember $Body 'status') -and
        ((Test-NeoIPCPatientRemovalMember $Body 'validationReport') -or (Test-NeoIPCPatientRemovalMember $Body 'stats') -or (Test-NeoIPCPatientRemovalMember $Body 'bundleReport'))
    if ($isReport) {
        $validation = Get-NeoIPCPatientRemovalMember $Body 'validationReport'
        $errorReports = Get-NeoIPCPatientRemovalMember $validation 'errorReports'
        foreach ($er in @($errorReports)) {
            if ($null -eq $er) { continue }
            $uid = [string](Get-NeoIPCPatientRemovalMember $er 'uid')
            if (-not $asked.Contains($uid)) { $foreign.Add($uid); continue }
            if (-not $errorCodes.ContainsKey($uid)) { $errorCodes[$uid] = [System.Collections.Generic.List[string]]::new(); $errorMessages[$uid] = [System.Collections.Generic.List[string]]::new() }
            $errorCodes[$uid].Add([string](Get-NeoIPCPatientRemovalMember $er 'errorCode'))
            $errorMessages[$uid].Add([string](Get-NeoIPCPatientRemovalMember $er 'message'))
        }
        $typeReports = Get-NeoIPCPatientRemovalMember (Get-NeoIPCPatientRemovalMember $Body 'bundleReport') 'typeReportMap'
        $trackedEntities = Get-NeoIPCPatientRemovalMember $typeReports 'TRACKED_ENTITY'
        $objectReports = Get-NeoIPCPatientRemovalMember $trackedEntities 'objectReports'
        foreach ($or in @($objectReports)) {
            if ($null -eq $or) { continue }
            $uid = [string](Get-NeoIPCPatientRemovalMember $or 'uid')
            $reported.Add($uid)
            if ($asked.Contains($uid)) { [void]$deleted.Add($uid) } else { $foreign.Add($uid) }
        }
    }
    $response = if ($structured) { Get-NeoIPCPatientRemovalMember $Body 'response' } else { $null }
    [pscustomobject]@{
        HttpStatusCode = $(if ($null -ne $StatusCode) { [int]$StatusCode } else { $null })
        IsReport       = [bool]$isReport
        Structured     = [bool]$structured
        Status         = $(if ($structured) { [string](Get-NeoIPCPatientRemovalMember $Body 'status') } else { $null })
        Message        = $(if ($structured) { [string](Get-NeoIPCPatientRemovalMember $Body 'message') } elseif ($Body -is [string]) { $Body.Substring(0, [Math]::Min(300, $Body.Length)) } else { $null })
        ResponseType   = $(if ($response) { [string](Get-NeoIPCPatientRemovalMember $response 'responseType') } else { $null })
        ErrorCodes     = $errorCodes
        ErrorMessages  = $errorMessages
        ReportedUids   = $reported.ToArray()
        DeletedUids    = $deleted
        ForeignUids    = $foreign.ToArray()
    }
}

function Get-NeoIPCTrackerDeleteAnswer {
    # What DHIS2's answer to one patient's DELETE import says, before the read-back decides what happened:
    #   Foreign      the report names UIDs the request did not carry, whatever it says of the patient;
    #   Reported     the report lists the patient as deleted;
    #   Refused      the report refuses the patient with error codes;
    #   CommitFailed the report is an ERROR without errors for the patient (2.40 reports a commit that throws, such as
    #                the veto of a patient with scheduled notifications, this way);
    #   ServerError  a WebMessage with a 5xx status, without a report: 2.41.10's answer to that veto and to any other
    #                commit that throws, and from 2.42 the answer to a commit that throws an exception DHIS2 maps to no
    #                4xx status;
    #   Rejected     a WebMessage with another 4xx status, without a report: from 2.42 also the answer to a commit that
    #                throws a checked exception (409), or an unchecked one DHIS2 maps to 400 or 409;
    #   AccessDenied 401 or 403, which no single patient causes;
    #   AsyncJob     DHIS2 queued the import as a job instead of running it;
    #   NoAnswer     no answer, a gateway's 502/503/504, or a body that is not JSON;
    #   Unclear      a report that neither lists nor refuses the patient.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]$Response,
        [Parameter(Mandatory)][string]$TrackedEntityId,
        [AllowNull()][AllowEmptyString()][string]$TransportFailure
    )
    function New-Answer([string]$Kind, [string]$Message, [string[]]$Codes = @()) {
        [pscustomobject]@{ Kind = $Kind; Message = $Message; ErrorCodes = $Codes; HttpStatusCode = $(if ($Response) { $Response.HttpStatusCode } else { $null }) }
    }
    # A lead and the text DHIS2 or the transport gave with it, which a proxy's answer can leave empty.
    function Join-Detail([string]$Lead, [string]$Detail) { if ([string]::IsNullOrWhiteSpace($Detail)) { "$Lead." } else { "${Lead}: $($Detail.Trim())" } }
    if ($TransportFailure -or $null -eq $Response) { return New-Answer 'NoAnswer' (Join-Detail 'No answer from DHIS2' $TransportFailure) }
    $code = $Response.HttpStatusCode
    if ($Response.IsReport) {
        $codes = @()
        if ($Response.ErrorCodes.ContainsKey($TrackedEntityId)) {
            $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
            $codes = @($Response.ErrorCodes[$TrackedEntityId] | Where-Object { $seen.Add($_) })
        }
        if ($Response.ForeignUids.Count -gt 0) { return New-Answer 'Foreign' ("DHIS2's report names UIDs the request did not carry: {0}." -f ($Response.ForeignUids -join ', ')) $codes }
        if ($codes.Count -gt 0) { return New-Answer 'Refused' (Join-Detail 'DHIS2 refused the deletion' (@($Response.ErrorMessages[$TrackedEntityId] | Where-Object { $_ }) -join ' / ')) $codes }
        if ($Response.Status -ceq 'OK' -and $null -ne $code -and $code -ge 200 -and $code -lt 300 -and $Response.DeletedUids.Contains($TrackedEntityId)) {
            return New-Answer 'Reported' 'DHIS2 reported the patient deleted.'
        }
        if ($Response.Status -ceq 'ERROR') { return New-Answer 'CommitFailed' (Join-Detail 'DHIS2 reported an error without refusing the patient' $Response.Message) }
        return New-Answer 'Unclear' "DHIS2 answered status $($Response.Status), HTTP $code, without reporting the patient deleted or refused."
    }
    if ($code -in 401, 403) { return New-Answer 'AccessDenied' (Join-Detail "DHIS2 refused the request with HTTP $code" $Response.Message) }
    if ($Response.ResponseType -ceq 'TrackerJob' -or $Response.Message -ceq 'Tracker job added') { return New-Answer 'AsyncJob' 'DHIS2 queued the deletion as a job instead of running it.' }
    if (-not $Response.Structured -or $null -eq $code -or $code -in 502, 503, 504) { return New-Answer 'NoAnswer' (Join-Detail "No usable answer from DHIS2 (HTTP $code)" $Response.Message) }
    if ($code -ge 500) { return New-Answer 'ServerError' (Join-Detail "DHIS2 failed with HTTP $code" $Response.Message) }
    if ($code -ge 400) { return New-Answer 'Rejected' (Join-Detail "DHIS2 rejected the request with HTTP $code" $Response.Message) }
    New-Answer 'Unclear' "DHIS2 answered HTTP $code without an import report."
}

function Get-NeoIPCPatientReadBackState {
    # What the read-back after a patient's deletion proves, against the preview's read, which included deleted data:
    #   ProvenDeleted both reads agree: the list read with includeDeleted shows the patient and every enrolment and
    #                 event the preview showed live as deleted, and the single read answers 404. Neither proves it
    #                 alone: from 2.42 the single read answers 404 for a patient the caller cannot see as well, and the
    #                 list read shows only what the caller can read. Unpreviewed names what the deletion took that the
    #                 preview did not show, or showed elsewhere, and DHIS2's cascade took unchecked by the removal's
    #                 rules: an enrolment or event added, or moved to another org unit, after the preview read the
    #                 patient; its registration moved; and a program owner added or moved. An owner shows an enrolment
    #                 in a program the caller cannot read too, since DHIS2 returns the owners of every program and
    #                 creates one with a patient's first enrolment in a program.
    #   Live          the list read shows the patient, and every enrolment and event the preview showed live, not
    #                 deleted, and no deleted enrolment or event the preview did not show, while the single read finds
    #                 it. A patient can survive a failed request without all of its data: on 2.42 and later a commit
    #                 that fails on a checked exception (a NotFoundException, when a record disappeared between DHIS2's
    #                 preheat and its commit) keeps what it deleted before, while any other failure rolls the request
    #                 back.
    #   Unknown       anything else. The list read alone shows a deletion that ran in part, whether the single read
    #                 answers or fails: a deleted patient whose read does not show every enrolment and event the preview
    #                 showed live as deleted is CascadeIncomplete, and a live patient whose read does not show them all
    #                 live, or shows deleted data the preview did not show, is PartialDeletion. A deleted patient whose
    #                 single read fails or answers otherwise than 404 reads ReadBackFailed, naming what the list read
    #                 shows taken that the preview did not show, or showed elsewhere.
    # ReadsDeleted says, whatever the state, whether the list read showed the patient itself deleted. $Failure is
    # whichever read failed first, and with a record it is the single read's.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]$Record,
        [Parameter(Mandatory)]$Previewed,
        [AllowNull()]$SingleReadStatus,
        [AllowNull()][AllowEmptyString()][string]$Failure
    )
    # ReadsDeleted comes from $Record, a parameter and so always defined here: a variable of the same name in a
    # caller's scope can never stand in for it.
    function New-State([string]$State, [string]$Reason, [string]$Message, [string[]]$Unpreviewed = @()) {
        [pscustomobject]@{ State = $State; Reason = $(if ($Reason) { $Reason } else { $null }); Message = $Message; Unpreviewed = $Unpreviewed
            ReadsDeleted = $null -ne $Record -and $Record.Deleted -eq $true }
    }
    if ($null -eq $Record) {
        return New-State 'Unknown' 'ReadBackFailed' $(if ($Failure) { "Reading the patient back failed: $($Failure.Trim().TrimEnd('.'))." } else { 'The read-back did not return the patient.' })
    }
    if (-not $Record.Complete) { return New-State 'Unknown' 'ReadBackFailed' 'The read-back lacked fields the removal checks.' }
    $ordinal = [System.StringComparer]::Ordinal
    $previewedChildren = [System.Collections.Generic.Dictionary[string, object]]::new($ordinal)
    foreach ($en in $Previewed.Enrollments) {
        $previewedChildren["enrollment|$($en.EnrollmentId)"] = $en
        foreach ($ev in $en.Events) { $previewedChildren["event|$($ev.EventId)"] = $ev }
    }
    $deletedChildren = [System.Collections.Generic.HashSet[string]]::new($ordinal)
    $liveChildren = [System.Collections.Generic.HashSet[string]]::new($ordinal)
    # $unpreviewed holds the deleted enrolments and events the preview did not show at all, $moved what it showed
    # elsewhere: deleted enrolments and events now in another org unit, the registration, and the program owners.
    # $moved counts only beside the patient's deletion; beside a live patient, its deleted enrolments and events show
    # as gone anyway.
    $unpreviewed = [System.Collections.Generic.List[string]]::new()
    $moved = [System.Collections.Generic.List[string]]::new()
    function Add-Child([string]$Key, [string]$Label, $Child) {
        if (-not $Child.Deleted) { [void]$liveChildren.Add($Key); return }
        [void]$deletedChildren.Add($Key)
        if (-not $previewedChildren.ContainsKey($Key)) { $unpreviewed.Add($Label) }
        elseif (-not $previewedChildren[$Key].Deleted -and $previewedChildren[$Key].OrgUnitId -cne $Child.OrgUnitId) { $moved.Add("$Label (moved to org unit $($Child.OrgUnitId))") }
    }
    foreach ($en in $Record.Enrollments) {
        Add-Child "enrollment|$($en.EnrollmentId)" "enrolment $($en.EnrollmentId)" $en
        foreach ($ev in $en.Events) { Add-Child "event|$($ev.EventId)" "event $($ev.EventId)" $ev }
    }
    if ($Record.OrgUnitId -cne $Previewed.OrgUnitId) { $moved.Add("the patient's registration (moved to org unit $($Record.OrgUnitId))") }
    $previewedOwners = [System.Collections.Generic.Dictionary[string, string]]::new($ordinal)
    foreach ($owner in $Previewed.Owners) { $previewedOwners[$owner.ProgramId] = $owner.OrgUnitId }
    foreach ($owner in $Record.Owners) {
        if (-not $previewedOwners.ContainsKey($owner.ProgramId)) { $moved.Add("data in program $($owner.ProgramId) (owned by org unit $($owner.OrgUnitId))") }
        elseif ($previewedOwners[$owner.ProgramId] -cne $owner.OrgUnitId) { $moved.Add("the ownership in program $($owner.ProgramId) (moved to org unit $($owner.OrgUnitId))") }
    }
    $previewedLive = Get-NeoIPCPatientLiveData -Record $Previewed
    # The data the preview showed live that the read-back does not show in the given set, as 'enrolment X' and 'event Y'.
    function Get-Absent($Set) {
        @(@($previewedLive.Enrollments | Where-Object { -not $Set.Contains("enrollment|$($_.EnrollmentId)") } | ForEach-Object { "enrolment $($_.EnrollmentId)" }) +
            @($previewedLive.Events | Where-Object { -not $Set.Contains("event|$($_.EventId)") } | ForEach-Object { "event $($_.EventId)" }))
    }
    if ($Record.Deleted) {
        $missing = @(Get-Absent $deletedChildren)
        if ($missing.Count -gt 0) { return New-State 'Unknown' 'CascadeIncomplete' ("The patient reads as deleted, but not all of its data: {0}." -f ($missing -join ', ')) }
        $taken = [string[]]@($unpreviewed) + [string[]]@($moved)
        if ($Failure -or $SingleReadStatus -ne 404) {
            $why = if ($Failure) { "its single read failed: $($Failure.Trim().TrimEnd('.'))" } else { "its single read answered HTTP $SingleReadStatus instead of 404" }
            $also = if ($taken.Count -gt 0) { " The list read also shows data the preview did not show, or showed elsewhere: $($taken -join ', ')." } else { '' }
            return New-State 'Unknown' 'ReadBackFailed' "The patient reads as deleted, but $why.$also"
        }
        return New-State 'ProvenDeleted' $null 'The read-back shows the patient and its data deleted.' $taken
    }
    $gone = @(Get-Absent $liveChildren)
    if ($gone.Count -gt 0 -or $unpreviewed.Count -gt 0) {
        $parts = @(
            if ($gone.Count -gt 0) { 'not all of the data the preview showed does ({0})' -f ($gone -join ', ') }
            if ($unpreviewed.Count -gt 0) { 'data the preview did not show reads as deleted ({0})' -f ($unpreviewed -join ', ') }
        )
        return New-State 'Unknown' 'PartialDeletion' ('The patient reads as not deleted, but {0}.' -f ($parts -join ', and '))
    }
    if ($Failure) { return New-State 'Unknown' 'ReadBackFailed' "The patient reads as not deleted, but its single read failed: $($Failure.Trim().TrimEnd('.'))." }
    if ($null -ne $SingleReadStatus -and [int]$SingleReadStatus -ge 200 -and [int]$SingleReadStatus -lt 300) {
        return New-State 'Live' $null 'The read-back shows the patient and its data not deleted.'
    }
    New-State 'Unknown' 'ReadBackFailed' "The patient reads as not deleted, but its single read answered HTTP $SingleReadStatus."
}

function Get-NeoIPCPatientRemovalOutcome {
    # The outcome of one patient's deletion, from DHIS2's answer and the read-back, and whether the run must stop. Only
    # the read-back can make a patient Deleted. A run carries on after a failure that concerns this patient alone, which
    # the read-back finds with the data the preview showed, and after a deletion the read-back proves while its answer
    # was lost or failed. It stops, with a Reason naming the cause even beside Deleted, when the failure concerns every
    # patient; when DHIS2's answer contradicts the request or the read-back; when DHIS2 queued the deletion as a job;
    # when the deletion took data the preview did not show, or showed elsewhere; and when the deletion may still be
    # running or ran in part.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)]$Answer, [Parameter(Mandatory)]$ReadBack)
    function New-Outcome([string]$Outcome, [string]$Reason, [bool]$Stop, [string]$Message, [string]$Warning = $null) {
        [pscustomobject]@{ Outcome = $Outcome; Reason = $(if ($Reason) { $Reason } else { $null }); Stop = $Stop; Message = $Message; Warning = $Warning }
    }
    # Messages as sentences: an answer's message often ends in DHIS2's own words, without a full stop.
    function Join-Sentence([string[]]$Part) { (@($Part | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) | ForEach-Object { if ($_ -match '[.!?]$') { $_ } else { "$_." } }) -join ' ' }
    # A 401 or 403 changes nothing: DHIS2 answers so before the import runs, or after rolling it back. The patient is
    # then still there when the read-back finds it live, or fails, as it does under the same refusal, but not when the
    # list read shows it deleted, or its data deleted in part: no refusal did that, and the read-back's verdict stands.
    if ($Answer.Kind -eq 'AccessDenied' -and -not $ReadBack.ReadsDeleted -and
        ($ReadBack.State -eq 'Live' -or ($ReadBack.State -eq 'Unknown' -and $ReadBack.Reason -eq 'ReadBackFailed'))) {
        return New-Outcome 'Failed' 'AccessDenied' $true $Answer.Message
    }
    switch ($ReadBack.State) {
        'ProvenDeleted' {
            $unpreviewed = @(if ($ReadBack.PSObject.Properties['Unpreviewed']) { $ReadBack.Unpreviewed | Where-Object { $_ } })
            $warnings = @(
                # A Foreign report may list the patient as deleted: what it gets wrong is the UIDs it adds.
                if ($Answer.Kind -eq 'Foreign') { Join-Sentence $Answer.Message, 'The read-back proves the patient deleted.' }
                elseif ($Answer.Kind -ne 'Reported') { "DHIS2's answer did not report the deletion ($("$($Answer.Message)".Trim().TrimEnd('.'))), but the read-back proves it." }
                if ($unpreviewed.Count -gt 0) { "The deletion also took data the preview did not show, or showed elsewhere, which the removal's rules never checked: $($unpreviewed -join ', ')." }
            )
            $warning = if ($warnings.Count -gt 0) { $warnings -join ' ' } else { $null }
            if ($unpreviewed.Count -gt 0) { return New-Outcome 'Deleted' 'UnpreviewedData' $true $ReadBack.Message $warning }
            switch ($Answer.Kind) {
                'Reported' { return New-Outcome 'Deleted' $null $false $ReadBack.Message }
                { $_ -in 'NoAnswer', 'ServerError' } { return New-Outcome 'Deleted' $null $false $ReadBack.Message $warning }
                'AsyncJob' { return New-Outcome 'Deleted' 'AsyncJob' $true $ReadBack.Message $warning }
                default { return New-Outcome 'Deleted' 'ReportMismatch' $true $ReadBack.Message $warning }
            }
        }
        'Live' {
            switch ($Answer.Kind) {
                'Refused' { return New-Outcome 'Failed' 'Dhis2Refused' $false $Answer.Message }
                'CommitFailed' { return New-Outcome 'Failed' 'CommitFailed' $false $Answer.Message }
                'ServerError' { return New-Outcome 'Failed' 'ServerError' $false $Answer.Message }
                'Rejected' { return New-Outcome 'Failed' 'Rejected' $false $Answer.Message }
                'Reported' { return New-Outcome 'Failed' 'ReportMismatch' $true "DHIS2 reported the patient deleted, but the read-back finds it." }
                { $_ -in 'Unclear', 'Foreign' } { return New-Outcome 'Failed' 'ReportMismatch' $true (Join-Sentence $Answer.Message, 'The read-back finds the patient.') }
                'AsyncJob' { return New-Outcome 'Unverified' 'AsyncJob' $true (Join-Sentence $Answer.Message, 'It may still be running.') }
                default { return New-Outcome 'Unverified' 'ResponseLost' $true (Join-Sentence $Answer.Message, 'The deletion may still be running.') }
            }
        }
    }
    New-Outcome 'Unverified' $ReadBack.Reason $true (Join-Sentence $Answer.Message, $ReadBack.Message)
}

function Format-NeoIPCPatientRemovalPrompt {
    # The texts of a run's one confirmation: Description is what -WhatIf and -Verbose show, Query the question the
    # prompt asks.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][int]$PatientCount,
        [Parameter(Mandatory)][int]$EnrollmentCount,
        [Parameter(Mandatory)][int]$EventCount,
        [Parameter(Mandatory)][string[]]$OrgUnitCode,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Dhis2Version,
        [int]$RefusedCount = 0
    )
    function Format-Count([int]$Count, [string]$Noun) { '{0} {1}{2}' -f $Count, $Noun, $(if ($Count -eq 1) { '' } else { 's' }) }
    $what = '{0} with {1} and {2} in {3} on {4} (DHIS2 {5})' -f (Format-Count $PatientCount 'patient'), (Format-Count $EnrollmentCount 'enrolment'),
        (Format-Count $EventCount 'event'), ($OrgUnitCode -join ', '), $Target, $Dhis2Version
    $query = "Delete ${what}? DHIS2 deletes every live enrolment and event of each patient, including any you cannot read."
    if ($RefusedCount -gt 0) {
        $query += ' {0} {1} refused and will not be deleted.' -f (Format-Count $RefusedCount 'selected patient'), $(if ($RefusedCount -eq 1) { 'is' } else { 'are' })
    }
    [pscustomobject]@{ Description = "Deleting $what"; Query = $query }
}

function New-NeoIPCPatientRemovalResult {
    # The object a run emits for one selected item. Its TrackedEntityId, OrgUnitId, and NeoIpcId are what a later run
    # takes from the pipeline, so a reviewed -WhatIf result can be fed back.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)]$Item)
    $patient = $Item.Patient
    $live = if ($patient) { Get-NeoIPCPatientLiveData -Record $patient } else { $null }
    [pscustomobject]@{
        TrackedEntityId = $(if ($patient) { $patient.TrackedEntityId } elseif ($Item.Kind -eq 'TrackedEntityId') { $Item.Value } else { $null })
        NeoIpcId        = $(if ($patient -and $patient.NeoIpcId) { $patient.NeoIpcId } elseif ($Item.Kind -eq 'NeoIpcId') { $Item.Value } else { $Item.ExpectedNeoIpcId })
        OrgUnitId       = $(if ($Item.Department) { $Item.Department.Id } else { $Item.OrgUnitId })
        OrgUnitCode     = $(if ($Item.Department) { $Item.Department.Code } else { $Item.OrgUnitCode })
        EnrollmentIds   = [string[]]@(if ($live) { $live.Enrollments | ForEach-Object { $_.EnrollmentId } })
        EventIds        = [string[]]@(if ($live) { $live.Events | ForEach-Object { $_.EventId } })
        Outcome         = $Item.Outcome
        Reason          = $Item.Reason
        ErrorCodes      = [string[]]@($Item.ErrorCodes)
        HttpStatusCode  = $Item.HttpStatusCode
        Message         = $Item.Message
    }
}
