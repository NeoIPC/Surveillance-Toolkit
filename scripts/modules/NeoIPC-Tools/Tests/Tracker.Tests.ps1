#Requires -Version 7.6

<#
.SYNOPSIS
    Pester tests for the tracker reads Read-PatientInfo, Read-EnrolmentInfo, and Read-EventInfo.

.DESCRIPTION
    Covers Public/Tracker.ps1, Private/TrackerRead.ps1, and the enrolment and event names of Get-NeoIPCTrackerDialect
    (Private/TrackerDialect.ps1).

    The reads run against an in-memory DHIS2 that models what the source of 2.40.12, 2.41.10, 2.42.6, and 2.43.2 says of
    the tracker list reads:
      1. the parameter names each version binds: 2.40 the old ones (ouMode, orgUnit, trackedEntity, enrollment, and
         event, the lists joined with ';'), 2.41 both sets, answering 400 when both forms of one are given, and 2.42 and
         later only the new ones (orgUnitMode, orgUnits, trackedEntities, enrollments, and events, joined with ','),
         ignoring the old ones, so that a wrong name widens the read; on every version the event read takes one org unit,
         tracked entity, and program stage, the enrolment read one tracked entity, and a joined value answers 400;
      2. 2.43 and later refuse an enrolment or event read without program, the event read with Tomcat's HTML page;
      3. 2.40's enrolment read by UID ignores every other filter, returns deleted enrolments too, and refuses the whole
         read when the account may not read one of them (an account with ALL it never refuses), and its read by query
         carries no events;
      4. the lists come under the version's key;
      5. a read's org units select by the owner of NEOIPC_CORE's record (a tracked-entity read without program by the
         owner in some program of the patient, else the registration org unit); CAPTURE and an event read's ACCESSIBLE
         by an owner within the caller's capture units; a tracked-entity or enrolment read's ACCESSIBLE on 2.40 and 2.41
         also within its search units where it has any;
      6. the attribute filter's eq and in operators compare ignoring case, and their values unescape as each version
         does, before 2.42.1 putting escaped slashes back in hash order;
      7. 2.43.2 and later leave out the values of attributes the account cannot read through their sharing;
      8. the two refusals of an account without data-capture org units or without data read access to the program, in
         each version's status and words;
      9. an unknown tracked entity given to an enrolment or event read answers 400, from 2.42 a deleted one too, except
         on 2.43's enrolment read, which checks none.
    The fake projects each tracker item and each metadata object onto the fields the request asks for, nested lists
    included, so a read that forgets a field it checks fails. It can be told to ignore parameters, as DHIS2 ignores a
    name it does not know, to show what a widened read does. Its code comparisons for org units ignore case on purpose,
    so the cmdlets' own exact comparison is what a test checks.

    Self-contained: no live instance is needed and no API call is made.

.EXAMPLE
    Invoke-Pester -Path scripts/modules/NeoIPC-Tools/Tests/Tracker.Tests.ps1
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..') -Force

InModuleScope 'NeoIPC-Tools' {
    Describe 'The tracker reads' {
        BeforeAll {
            $script:Auth = @{ AuthType = 'Basic' }
            $script:Host1 = 'dhis2.example.org'

            function New-FakeInstance {
                param([string]$Version = '2.43.2')
                $ordinal = [System.StringComparer]::Ordinal
                $script:Fake = [pscustomobject]@{
                    Version         = $Version
                    ProgramId       = 'PrgCore0001'
                    HideProgram     = $false
                    Stages          = @(
                        [ordered]@{ id = 'StgAdmn0001'; code = 'NEOIPC_STG_ADM'; name = 'Admission' }
                        [ordered]@{ id = 'StgSurg0001'; code = 'NEOIPC_STG_SURGERY'; name = 'Surgical Procedure' }
                        [ordered]@{ id = 'StgBsi00001'; code = 'NEOIPC_STG_BSI'; name = 'Primary Sepsis/BSI' }
                        [ordered]@{ id = 'StgNec00001'; code = 'NEOIPC_STG_NEC'; name = 'Necrotizing enterocolitis' }
                        [ordered]@{ id = 'StgSsi00001'; code = 'NEOIPC_STG_SSI'; name = 'Surgical Site Infection' }
                        [ordered]@{ id = 'StgHap00001'; code = 'NEOIPC_STG_HAP'; name = 'Pneumonia' }
                        [ordered]@{ id = 'StgEnd00001'; code = 'NEOIPC_STG_SURV_END'; name = 'Surveillance-End' }
                    )
                    Attributes      = @(
                        @{ id = 'AttPatId001'; code = 'NEOIPC_PATIENT_ID' }
                        @{ id = 'AttSex00001'; code = 'NEOIPC_TEA_SEX' }
                        @{ id = 'AttDeliv001'; code = 'NEOIPC_TEA_DELIVERY_MODE' }
                        @{ id = 'AttBw000001'; code = 'NEOIPC_TEA_BIRTH_WEIGHT' }
                        @{ id = 'AttGa000001'; code = 'NEOIPC_TEA_GEST_AGE' }
                        @{ id = 'AttGd000001'; code = 'NeoIPC_TEA_TOTAL_GESTATION_DAYS' }
                    )
                    # The attributes the account may not read through their sharing: api/metadata leaves them out, and
                    # 2.43.2 and later leave out their values.
                    Unreadable      = [System.Collections.Generic.HashSet[string]]::new($ordinal)
                    DataElements    = @(
                        @{ id = 'DeBsiName01'; code = 'NEOIPC_BSI_PATHOGEN_1_NAME' }
                        @{ id = 'DeHapName01'; code = 'NEOIPC_HAP_PATHOGEN_1_NAME' }
                    )
                    OrgUnits        = @(
                        @{ id = 'OuRoot00001'; code = 'ROOT'; path = '/OuRoot00001' }
                        @{ id = 'OuHospX0001'; code = 'HOSP_X'; path = '/OuRoot00001/OuHospX0001' }
                        @{ id = 'OuDeptA0001'; code = 'DEPT_A'; path = '/OuRoot00001/OuHospX0001/OuDeptA0001' }
                        @{ id = 'OuDeptB0001'; code = 'DEPT_B'; path = '/OuRoot00001/OuHospX0001/OuDeptB0001' }
                        @{ id = 'OuHospY0001'; code = 'HOSP_Y'; path = '/OuRoot00001/OuHospY0001' }
                        @{ id = 'OuDeptZ0001'; code = 'DEPT_Z'; path = '/OuRoot00001/OuHospY0001/OuDeptZ0001' }
                    )
                    # The caller's data-capture org units: DEPT_Z lies outside its hierarchy.
                    MeUnits         = [System.Collections.Generic.List[string]]::new([string[]]@('OuHospX0001'))
                    # The caller's search org units, none by default, and its authorities.
                    SearchUnits     = [System.Collections.Generic.List[string]]::new()
                    Authorities     = [System.Collections.Generic.List[string]]::new()
                    TrackedEntities = [System.Collections.Generic.Dictionary[string, object]]::new($ordinal)
                    Enrollments     = [System.Collections.Generic.Dictionary[string, object]]::new($ordinal)
                    Events          = [System.Collections.Generic.Dictionary[string, object]]::new($ordinal)
                    # Parameters this DHIS2 ignores, as DHIS2 ignores a name it does not know.
                    Ignore          = [System.Collections.Generic.HashSet[string]]::new($ordinal)
                    # Tracked entities deleted, with their enrolments and events, as soon as a tracked-entity read has
                    # returned them: deleted between that read and the next.
                    DeleteOnRead    = [System.Collections.Generic.HashSet[string]]::new($ordinal)
                    Refusal         = $null
                    # Enrolments 2.40's read by UID refuses (409) as the account may not read them (ProgramRefused: as it
                    # may not read the data of the enrolment's own program), and enrolments it leaves out of that read.
                    Refused         = [System.Collections.Generic.HashSet[string]]::new($ordinal)
                    ProgramRefused  = [System.Collections.Generic.HashSet[string]]::new($ordinal)
                    Dropped         = [System.Collections.Generic.HashSet[string]]::new($ordinal)
                    Requests        = [System.Collections.Generic.List[object]]::new()
                }
            }

            # A patient of NEOIPC_CORE with one enrolment, 'En' + its UID's last nine characters, entered where it was
            # registered. -Owner is the org unit that owns NEOIPC_CORE's record of it, by default its registration org unit.
            # -Deleted deletes the patient and its enrolment, as DHIS2 does.
            function Add-FakePatient {
                param(
                    [Parameter(Mandatory)][string]$Uid,
                    [string]$NeoIpcId,
                    [string]$OrgUnit = 'OuDeptA0001',
                    [string]$Owner,
                    [hashtable]$Attributes = @{},
                    [string]$EnrolledAt = '2025-03-01T10:00:00.000',
                    [string]$UpdatedAt = '2025-03-02T10:00:00.000',
                    [switch]$Deleted
                )
                $values = [System.Collections.Generic.List[object]]::new()
                if ($NeoIpcId) { $values.Add([ordered]@{ attribute = 'AttPatId001'; code = 'NEOIPC_PATIENT_ID'; value = $NeoIpcId }) }
                foreach ($code in $Attributes.Keys) {
                    $attribute = @($script:Fake.Attributes | Where-Object { $_.code -ceq $code })[0]
                    $values.Add([ordered]@{ attribute = $attribute.id; code = $code; value = $Attributes[$code] })
                }
                $script:Fake.TrackedEntities[$Uid] = [ordered]@{
                    trackedEntity = $Uid; orgUnit = $OrgUnit; createdAt = '2025-01-01T08:00:00.000'; updatedAt = '2025-01-02T09:00:00.000'
                    attributes    = $values.ToArray()
                    programOwners = @([ordered]@{ orgUnit = $(if ($Owner) { $Owner } else { $OrgUnit }); program = $script:Fake.ProgramId; trackedEntity = $Uid })
                    deleted       = [bool]$Deleted
                }
                Add-FakeEnrollment -Uid ('En' + $Uid.Substring(2)) -TrackedEntity $Uid -OrgUnit $OrgUnit -EnrolledAt $EnrolledAt -UpdatedAt $UpdatedAt -Deleted:$Deleted
            }

            function Add-FakeEnrollment {
                param(
                    [Parameter(Mandatory)][string]$Uid,
                    [Parameter(Mandatory)][string]$TrackedEntity,
                    [string]$OrgUnit = 'OuDeptA0001',
                    [string]$Program = $script:Fake.ProgramId,
                    [string]$EnrolledAt = '2025-03-01T10:00:00.000',
                    [string]$UpdatedAt = '2025-03-02T10:00:00.000',
                    [switch]$Deleted
                )
                $script:Fake.Enrollments[$Uid] = [ordered]@{
                    enrollment = $Uid; trackedEntity = $TrackedEntity; program = $Program; orgUnit = $OrgUnit; status = 'ACTIVE'
                    enrolledAt = $EnrolledAt; createdAt = '2025-03-01T10:05:00.000'; updatedAt = $UpdatedAt; completedAt = $null; completedBy = $null
                    followUp = $false; storedBy = 'enrolment-store'; deleted = [bool]$Deleted
                    createdBy = [ordered]@{ username = 'enrolment-creator' }; updatedBy = [ordered]@{ username = 'enrolment-updater' }
                    notes = @([ordered]@{ value = 'First note' })
                }
            }

            # An event of a patient's NEOIPC_CORE enrolment, entered where the patient was registered unless -OrgUnit says.
            function Add-FakeEvent {
                param(
                    [Parameter(Mandatory)][string]$Uid,
                    [Parameter(Mandatory)][string]$TrackedEntity,
                    [string]$Stage = 'StgAdmn0001',
                    [string]$OrgUnit,
                    [string]$Enrollment,
                    [string]$Program = $script:Fake.ProgramId,
                    [AllowEmptyString()][string]$CreatedBy = 'creator',
                    [AllowEmptyString()][string]$UpdatedBy = 'updater',
                    [AllowEmptyString()][string]$StoredBy = 'store',
                    [string]$OccurredAt = '2025-03-05T00:00:00.000',
                    [hashtable]$DataValues = @{},
                    [switch]$Deleted
                )
                $te = $script:Fake.TrackedEntities[$TrackedEntity]
                $script:Fake.Events[$Uid] = [ordered]@{
                    event = $Uid; enrollment = $(if ($Enrollment) { $Enrollment } else { 'En' + $TrackedEntity.Substring(2) }); trackedEntity = $TrackedEntity
                    program = $Program; programStage = $Stage; orgUnit = $(if ($OrgUnit) { $OrgUnit } else { $te['orgUnit'] }); status = 'COMPLETED'
                    occurredAt = $OccurredAt; createdAt = '2025-03-05T08:00:00.000'; updatedAt = '2025-03-06T08:00:00.000'; deleted = [bool]$Deleted
                    storedBy = $(if ($StoredBy) { $StoredBy } else { $null })
                    createdBy = $(if ($CreatedBy) { [ordered]@{ username = $CreatedBy } } else { $null })
                    updatedBy = $(if ($UpdatedBy) { [ordered]@{ username = $UpdatedBy } } else { $null })
                    dataValues = @(foreach ($de in $DataValues.Keys) {
                            [ordered]@{ dataElement = $de; value = $DataValues[$de]; storedBy = 'value-store'; createdAt = '2025-03-05T08:01:00.000'
                                updatedAt = '2025-03-05T08:02:00.000'; createdBy = [ordered]@{ username = 'value-creator' }; updatedBy = [ordered]@{ username = 'value-updater' } }
                        })
                }
            }

            function Get-FakeVersion { ConvertTo-NeoIPCDhis2Version -Text $script:Fake.Version }

            function Stop-Fake([int]$Status, [string]$Message) {
                throw (New-NeoIPCDhis2HttpError -Method 'GET' -Path $script:FakePath -StatusCode $Status -Message $Message)
            }

            # One parameter as a version binds it: 2.40 reads the old name only, 2.41 both, refusing both at once, and
            # 2.42 and later the new name only, ignoring the old. Returns the values, split, or $null when not given.
            function Get-FakeList($Query, [string]$Old, [string]$OldSeparator, [string]$New, [string]$NewSeparator) {
                $version = Get-FakeVersion
                $forms = @(
                    if ($Old -and $version -lt [version]'2.42') { @{ Name = $Old; Separator = $OldSeparator } }
                    if ($New -and $version -ge [version]'2.41') { @{ Name = $New; Separator = $NewSeparator } }
                )
                $present = @($forms | Where-Object { $Query.ContainsKey($_.Name) })
                if ($present.Count -gt 1) { Stop-Fake 400 "Only one parameter of '$Old' and '$New' must be specified. Prefer '$New' as '$Old' will be removed." }
                if ($present.Count -eq 0) { return $null }
                $text = [string]$Query[$present[0].Name]
                , [string[]]@(if ($present[0].Separator) { $text -split [regex]::Escape($present[0].Separator) } else { $text })
            }

            # A single-value UID parameter: a joined list, or any value that is no UID, answers 400 on every version.
            function Get-FakeUid($Query, [string]$Name) {
                if (-not $Query.ContainsKey($Name)) { return $null }
                $value = [string]$Query[$Name]
                if (-not (Test-NeoIPCMetadataUid -Id $value)) { Stop-Fake 400 "Value '$value' is not a valid UID for parameter $Name." }
                $value
            }

            function Get-FakeOwner([string]$TrackedEntity) {
                $te = $script:Fake.TrackedEntities[$TrackedEntity]
                if ($null -eq $te) { return $null }
                @(@($te['programOwners']) | Where-Object { $_['program'] -ceq $script:Fake.ProgramId } | ForEach-Object { $_['orgUnit'] })[0]
            }

            # Whether an org unit lies within the caller's data-capture org units, or with -Search within its search org
            # units, or its data-capture org units where it has none.
            function Test-FakeAccessible([string]$OrgUnit, [switch]$Search) {
                $unit = @($script:Fake.OrgUnits | Where-Object { $_.id -ceq $OrgUnit })[0]
                if ($null -eq $unit) { return $false }
                $roots = if ($Search -and $script:Fake.SearchUnits.Count -gt 0) { $script:Fake.SearchUnits } else { $script:Fake.MeUnits }
                @($roots | Where-Object { $unit.path.Split('/') -ccontains $_ }).Count -gt 0
            }

            # The org units a read selects, and their mode: 2.41 and later default to SELECTED with org units and to
            # ACCESSIBLE without, and refuse ACCESSIBLE with org units and SELECTED without; 2.40 refuses a tracked-entity
            # or enrolment read with neither (409), and an event read SELECTED without an org unit.
            function Resolve-FakeScope([string]$Resource, [AllowNull()][string[]]$OrgUnits, [string]$Mode) {
                $version = Get-FakeVersion
                $OrgUnits = [string[]]@($OrgUnits | Where-Object { $_ })
                if (-not $Mode) {
                    if ($version -lt [version]'2.41' -and $Resource -ne 'events' -and $OrgUnits.Count -eq 0) { Stop-Fake 409 'At least one organisation unit must be specified' }
                    $Mode = if ($OrgUnits.Count -gt 0) { 'SELECTED' } else { 'ACCESSIBLE' }
                }
                if ($Mode -eq 'SELECTED' -and $OrgUnits.Count -eq 0) {
                    if ($version -lt [version]'2.41') { Stop-Fake 409 'At least one organisation unit must be specified' }
                    Stop-Fake 400 "At least one org unit is required for orgUnitMode: $Mode."
                }
                if ($Mode -in 'ACCESSIBLE', 'CAPTURE' -and $OrgUnits.Count -gt 0 -and $version -ge [version]'2.41') { Stop-Fake 400 "orgUnitMode $Mode cannot be used with orgUnits." }
                [pscustomobject]@{ Mode = $Mode; OrgUnits = $OrgUnits }
            }

            # A read with program selects by the owner of the program's record, one without by the owner in some program
            # of the patient, else by the registration org unit. CAPTURE, and an event read's ACCESSIBLE for a CLOSED
            # program, take the owners within the caller's data-capture org units; the tracked-entity and enrolment
            # reads' ACCESSIBLE on 2.40 and 2.41 those within its search org units as well.
            function Test-FakeInScope($Scope, [string]$TrackedEntity, [string]$Resource, [switch]$AnyProgram) {
                $orgUnit = Get-FakeOwner $TrackedEntity
                if ($AnyProgram -and -not $orgUnit) {
                    $te = $script:Fake.TrackedEntities[$TrackedEntity]
                    $orgUnit = @(@(@($te['programOwners']) | ForEach-Object { $_['orgUnit'] }) + @($te['orgUnit']))[0]
                }
                if ($Scope.Mode -eq 'SELECTED') { return $Scope.OrgUnits -ccontains $orgUnit }
                if (-not (Test-FakeAccessible $orgUnit)) { return $false }
                if ($Scope.Mode -eq 'ACCESSIBLE' -and $Resource -ne 'events' -and (Get-FakeVersion) -lt [version]'2.42') { return Test-FakeAccessible $orgUnit -Search }
                $true
            }

            # An attribute filter as DHIS2 reads it. Before 2.42.1 (RequestParamUtils / RequestParamsValidator.filterList)
            # every '//' found scanning left to right is taken out, the scan then stepping past the next character; one
            # '/' goes back per pair taken out, at its recorded position, in the iteration order of the java.util.HashMap
            # that recorded the positions (by the position masked by the table size, then by insertion; the table starts
            # at 16 and doubles past three quarters full). The rest splits at every ':' that is not escaped into the
            # operator and the value, whose '/,' and '/:' lose their slash. From 2.42.1 (FilterParser) '//', '/,', and '/:'
            # lose a slash, in that order. The in operator's values are separated by ';'.
            function ConvertFrom-FakeFilter([string]$Filter) {
                $attribute = $Filter.Substring(0, $Filter.IndexOf(':'))
                if ((Get-FakeVersion) -ge [version]'2.42.1') {
                    $operator, $value = $Filter.Substring($attribute.Length + 1) -split ':', 2
                    $value = $value.Replace('//', '/').Replace('/,', ',').Replace('/:', ':')
                }
                else {
                    $sb = [System.Text.StringBuilder]::new($Filter)
                    $keys = [System.Collections.Generic.List[int]]::new()
                    for ($i = 0; $i -lt $sb.Length - 1; $i++) {
                        if ($sb[$i] -eq [char]'/' -and $sb[$i + 1] -eq [char]'/') { [void]$sb.Remove($i, 2); $keys.Add($i) }
                    }
                    $table = 16
                    for ($n = 0; $n -lt $keys.Count; $n++) { if ($n + 1 -gt 0.75 * $table) { $table *= 2 } }
                    $pad = 0
                    foreach ($k in @($keys | Sort-Object { $_ -band ($table - 1) }, { $_ })) { [void]$sb.Insert($k + $pad, '/'); $pad++ }
                    $restored = $sb.ToString()
                    $parts = [regex]::Split($restored.Substring($restored.IndexOf(':') + 1), '(?<!/):')
                    if ($parts.Count -ne 2) { Stop-Fake 400 "Query item or filter is invalid: $restored" }
                    $operator = $parts[0]
                    $value = $parts[1].Replace('/,', ',').Replace('/:', ':')
                }
                $values = switch ($operator) { 'eq' { , @($value) } 'in' { , @($value -split ';') } default { Stop-Fake 400 "The fake does not read the operator '$operator'." } }
                @{ Attribute = $attribute; Values = $values }
            }

            # A field list such as 'a,b[c,d[e]]' as a tree: each name maps to the tree of its nested list, or to $null.
            function ConvertFrom-FakeFieldList([string]$Text) {
                $root = [ordered]@{}
                $outer = [System.Collections.Generic.Stack[object]]::new()
                $level = $root
                $name = [System.Text.StringBuilder]::new()
                foreach ($ch in $Text.ToCharArray()) {
                    if ($ch -eq [char]'[') { $child = [ordered]@{}; $level[$name.ToString()] = $child; [void]$name.Clear(); $outer.Push($level); $level = $child }
                    elseif ($ch -eq [char]']') { if ($name.Length -gt 0) { $level[$name.ToString()] = $null; [void]$name.Clear() }; $level = $outer.Pop() }
                    elseif ($ch -eq [char]',') { if ($name.Length -gt 0) { $level[$name.ToString()] = $null; [void]$name.Clear() } }
                    else { [void]$name.Append($ch) }
                }
                if ($name.Length -gt 0) { $level[$name.ToString()] = $null }
                $root
            }

            # A value cut to a field tree, as DHIS2's field filter cuts it: a dictionary to the tree's names, each element of
            # a list alike, and a name without a nested list keeps its value whole.
            function Select-FakeTree($Value, $Tree) {
                $isList = $Value -is [System.Collections.IEnumerable] -and $Value -isnot [string] -and $Value -isnot [System.Collections.IDictionary]
                if ($null -ne $Tree -and $Value -is [System.Collections.IDictionary]) {
                    $copy = [ordered]@{}
                    foreach ($k in $Tree.Keys) { if ($Value.Contains($k)) { $copy[$k] = Select-FakeTree $Value[$k] $Tree[$k] } }
                    return $copy
                }
                if ($null -ne $Tree -and $isList) { return , @(foreach ($v in $Value) { Select-FakeTree $v $Tree }) }
                if ($isList) { return , $Value }
                $Value
            }

            # An item cut to the fields the request asks for.
            function Select-FakeField($Item, [string[]]$Fields) { Select-FakeTree $Item (ConvertFrom-FakeFieldList ($Fields -join ',')) }

            # A metadata object cut to its type's '<type>:fields' list, as api/metadata cuts it.
            function Select-FakeMetadataField($Item, [string]$Fields) { Select-FakeTree $Item (ConvertFrom-FakeFieldList $Fields) }

            function Get-FakeRefusal([string]$Resource) {
                $version = Get-FakeVersion
                switch ($script:Fake.Refusal) {
                    'NoCapture' {
                        if ($version -lt [version]'2.41') {
                            switch ($Resource) {
                                'trackedEntities' { Stop-Fake 409 'Current user must be associated with at least one organisation unit when selection mode is ACCESSIBLE' }
                                'enrollments' { Stop-Fake 409 'Current user must be associated with at least one organisation unit when selection mode is ACCESSIBLE' }
                                'events' { Stop-Fake 409 'User needs to be assigned data capture org units' }
                            }
                        }
                        if ($version -lt [version]'2.42') { Stop-Fake 400 'User needs to be assigned data capture org units' }
                        Stop-Fake 403 'User needs to be assigned data capture org units'
                    }
                    'NoProgram' {
                        if ($version -lt [version]'2.41' -and $Resource -ne 'events') { Stop-Fake 409 "Current user is not authorized to read data from selected program:  $($script:Fake.ProgramId)" }
                        Stop-Fake 403 "User has no access to program: $($script:Fake.ProgramId)"
                    }
                }
            }

            function Test-FakeDate([string]$Value, $Query, [string]$After, [string]$Before) {
                $at = [datetime]::Parse($Value, [cultureinfo]::InvariantCulture)
                if ($After -and $Query.ContainsKey($After) -and $at -lt [datetime]::Parse($Query[$After], [cultureinfo]::InvariantCulture)) { return $false }
                if ($Before -and $Query.ContainsKey($Before) -and $at -ge [datetime]::Parse($Query[$Before], [cultureinfo]::InvariantCulture).AddDays(1)) { return $false }
                $true
            }

            # An enrolment or event read's tracked entity: 400 when it does not exist, from 2.42 also when it is deleted, which
            # 2.40 and 2.41 take as existing; 2.43's enrolment read checks none.
            function Test-FakeTrackedEntity([string]$Uid, [string]$Resource) {
                $version = Get-FakeVersion
                if ($Resource -eq 'enrollments' -and $version -ge [version]'2.43') { return }
                if ($script:Fake.TrackedEntities.ContainsKey($Uid) -and -not ($script:Fake.TrackedEntities[$Uid]['deleted'] -and $version -ge [version]'2.42')) { return }
                $noun = if ($version -lt [version]'2.41') { 'Tracked entity instance' } else { 'Tracked entity' }
                Stop-Fake 400 "$noun is specified but does not exist: $Uid"
            }

            function Invoke-FakeTrackerRead([string]$Resource, $Query, [string[]]$Fields) {
                $version = Get-FakeVersion
                $q = @{}
                foreach ($k in $Query.Keys) { if (-not $script:Fake.Ignore.Contains($k)) { $q[$k] = $Query[$k] } }
                $program = [string]$q['program']
                if ($version -ge [version]'2.43' -and $Resource -ne 'trackedEntities' -and -not $program) {
                    if ($Resource -eq 'events') {
                        Stop-Fake 400 (Get-NeoIPCDhis2ErrorDetail -Content '<html><head><title>HTTP Status 400 – Bad Request</title></head><body><h1>HTTP Status 400 – Bad Request</h1></body></html>').Message
                    }
                    Stop-Fake 400 'Program is mandatory'
                }
                # 2.40's enrolment read by UID refuses per enrolment instead (below).
                if (-not ($Resource -eq 'enrollments' -and $version -lt [version]'2.41' -and $q.ContainsKey('enrollment'))) { Get-FakeRefusal $Resource }
                $mode = if ($version -lt [version]'2.42' -and $q.ContainsKey('ouMode')) { [string]$q['ouMode'] }
                if ($version -ge [version]'2.41' -and $q.ContainsKey('orgUnitMode')) {
                    if ($mode) { Stop-Fake 400 "Only one parameter of 'ouMode' and 'orgUnitMode' must be specified." }
                    $mode = [string]$q['orgUnitMode']
                }
                $rows = [System.Collections.Generic.List[object]]::new()
                switch ($Resource) {
                    'trackedEntities' {
                        $ids = Get-FakeList $q 'trackedEntity' ';' 'trackedEntities' ','
                        $orgUnits = Get-FakeList $q 'orgUnit' ';' 'orgUnits' ','
                        $scope = if ($ids -and -not $orgUnits -and -not $mode) { [pscustomobject]@{ Mode = 'ACCESSIBLE'; OrgUnits = @() } } else { Resolve-FakeScope $Resource $orgUnits $mode }
                        $filter = if ($q.ContainsKey('filter')) { ConvertFrom-FakeFilter ([string]$q['filter']) }
                        foreach ($te in $script:Fake.TrackedEntities.Values) {
                            $uid = $te['trackedEntity']
                            if ($te['deleted']) { continue }
                            if ($program -and @($script:Fake.Enrollments.Values | Where-Object { $_['trackedEntity'] -ceq $uid -and $_['program'] -ceq $program -and -not $_['deleted'] }).Count -eq 0) { continue }
                            if ($ids -and $ids -cnotcontains $uid) { continue }
                            if (-not (Test-FakeInScope $scope $uid 'trackedEntities' -AnyProgram:(-not $program))) { continue }
                            if ($filter) {
                                $values = @(@($te['attributes']) | Where-Object { $_['attribute'] -ceq $filter.Attribute } | ForEach-Object { [string]$_['value'] })
                                if (@($values | Where-Object { $v = $_; @($filter.Values | Where-Object { [string]::Equals($_, $v, [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0 }).Count -eq 0) { continue }
                            }
                            $view = [ordered]@{}
                            foreach ($key in $te.Keys) { $view[$key] = $te[$key] }
                            if ($version -ge [version]'2.43.2') { $view['attributes'] = @(@($te['attributes']) | Where-Object { -not $script:Fake.Unreadable.Contains($_['code']) }) }
                            $view['enrollments'] = @($script:Fake.Enrollments.Values | Where-Object { $_['trackedEntity'] -ceq $uid -and -not $_['deleted'] } | ForEach-Object { [ordered]@{ enrollment = $_['enrollment']; program = $_['program'] } })
                            $rows.Add($view)
                        }
                        foreach ($view in $rows) {
                            $uid = $view['trackedEntity']
                            if (-not $script:Fake.DeleteOnRead.Contains($uid)) { continue }
                            $script:Fake.TrackedEntities[$uid]['deleted'] = $true
                            foreach ($record in @($script:Fake.Enrollments.Values) + @($script:Fake.Events.Values)) { if ($record['trackedEntity'] -ceq $uid) { $record['deleted'] = $true } }
                        }
                    }
                    'enrollments' {
                        $uids = Get-FakeList $q 'enrollment' ';' 'enrollments' ','
                        if ($uids -and $version -lt [version]'2.41') {
                            # 2.40 reads each listed enrolment by UID, deleted ones too, and applies no other filter; it
                            # refuses the whole read when the account may not read one of them, naming what it lacks, and
                            # checks nothing for an account with ALL (DefaultTrackerAccessManager.canRead).
                            foreach ($uid in $uids) {
                                if (-not $script:Fake.Enrollments.ContainsKey($uid) -or $script:Fake.Authorities -ccontains 'ALL') { continue }
                                $lacks = @(
                                    if ($script:Fake.Refusal -eq 'NoProgram' -or $script:Fake.ProgramRefused.Contains($uid)) {
                                        "User has no data read access to program: $($script:Fake.Enrollments[$uid]['program'])"
                                    }
                                    if ($script:Fake.Refusal -eq 'NoCapture' -or $script:Fake.Refused.Contains($uid)) { 'OWNERSHIP_ACCESS_DENIED' }
                                )
                                if ($lacks.Count -gt 0) { Stop-Fake 409 ('[' + ($lacks -join ', ') + ']') }
                            }
                            foreach ($uid in $uids) {
                                if (-not $script:Fake.Enrollments.ContainsKey($uid) -or $script:Fake.Dropped.Contains($uid)) { continue }
                                $rows.Add((Get-FakeEnrollmentView $script:Fake.Enrollments[$uid] -WithEvents))
                            }
                            break
                        }
                        $te = Get-FakeUid $q 'trackedEntity'
                        if ($te) { Test-FakeTrackedEntity $te $Resource }
                        $scope = Resolve-FakeScope $Resource (Get-FakeList $q 'orgUnit' ';' 'orgUnits' ',') $mode
                        foreach ($en in $script:Fake.Enrollments.Values) {
                            if ($en['deleted'] -or ($program -and $en['program'] -cne $program)) { continue }
                            if ($uids -and $uids -cnotcontains $en['enrollment']) { continue }
                            if ($te -and $en['trackedEntity'] -cne $te) { continue }
                            if (-not (Test-FakeInScope $scope $en['trackedEntity'] 'enrollments')) { continue }
                            if (-not (Test-FakeDate $en['enrolledAt'] $q 'enrolledAfter' 'enrolledBefore')) { continue }
                            if (-not (Test-FakeDate $en['updatedAt'] $q 'updatedAfter' $null)) { continue }
                            $rows.Add((Get-FakeEnrollmentView $en -WithEvents:($version -ge [version]'2.41')))
                        }
                    }
                    'events' {
                        $orgUnit = Get-FakeUid $q 'orgUnit'
                        $te = Get-FakeUid $q 'trackedEntity'
                        if ($te) { Test-FakeTrackedEntity $te $Resource }
                        $stage = Get-FakeUid $q 'programStage'
                        if ($stage -and @($script:Fake.Stages | Where-Object { $_.id -ceq $stage }).Count -eq 0) { Stop-Fake 400 "Program stage is specified but does not exist: $stage" }
                        $uids = Get-FakeList $q 'event' ';' 'events' ','
                        $enrollments = Get-FakeList $q $null $null 'enrollments' ','
                        if ($version -lt [version]'2.41') {
                            # 2.40 binds enrollments too, and drops a value that is no UID from both lists.
                            if ($q.ContainsKey('enrollments')) { $enrollments = [string[]]@(([string]$q['enrollments']) -split ',') }
                            if ($uids) { $uids = [string[]]@($uids | Where-Object { Test-NeoIPCMetadataUid -Id $_ }) }
                            if ($enrollments) { $enrollments = [string[]]@($enrollments | Where-Object { Test-NeoIPCMetadataUid -Id $_ }) }
                        }
                        else {
                            foreach ($v in @($uids) + @($enrollments)) { if ($v -and -not (Test-NeoIPCMetadataUid -Id $v)) { Stop-Fake 400 "Value '$v' is not a valid UID." } }
                        }
                        if (-not $mode -and $version -lt [version]'2.41') { $mode = if ($orgUnit) { 'SELECTED' } else { 'ACCESSIBLE' } }
                        $scope = Resolve-FakeScope $Resource @(if ($orgUnit) { $orgUnit }) $mode
                        foreach ($ev in $script:Fake.Events.Values) {
                            if ($ev['deleted'] -or ($program -and $ev['program'] -cne $program)) { continue }
                            if ($stage -and $ev['programStage'] -cne $stage) { continue }
                            if ($te -and $ev['trackedEntity'] -cne $te) { continue }
                            if ($uids -and $uids -cnotcontains $ev['event']) { continue }
                            if ($enrollments -and $enrollments -cnotcontains $ev['enrollment']) { continue }
                            if (-not (Test-FakeInScope $scope $ev['trackedEntity'] 'events')) { continue }
                            if (-not (Test-FakeDate $ev['occurredAt'] $q 'occurredAfter' 'occurredBefore')) { continue }
                            if (-not (Test-FakeDate $ev['updatedAt'] $q 'updatedAfter' 'updatedBefore')) { continue }
                            $rows.Add($ev)
                        }
                    }
                }
                $items = @($rows | ForEach-Object { Select-FakeField $_ $Fields })
                # 2.40 pages a read without skipPaging, 50 items to a page.
                if ($version -lt [version]'2.41' -and $q['skipPaging'] -ne 'true') { $items = @($items | Select-Object -First 50) }
                $key = if ($version -lt [version]'2.41') { 'instances' } else { $Resource }
                [ordered]@{ $key = $items }
            }

            function Get-FakeEnrollmentView($Enrollment, [switch]$WithEvents) {
                $view = [ordered]@{}
                foreach ($key in $Enrollment.Keys) { $view[$key] = $Enrollment[$key] }
                $view['events'] = @(if ($WithEvents) {
                        $script:Fake.Events.Values | Where-Object { $_['enrollment'] -ceq $Enrollment['enrollment'] -and -not $_['deleted'] } | ForEach-Object { [ordered]@{ event = $_['event'] } }
                    })
                $view
            }

            function Set-FakeMock {
                Mock Invoke-WebRequest { throw 'A test made an HTTP call.' }
                Mock Invoke-RestMethod { throw 'A test made an HTTP call.' }
                Mock Invoke-NeoIPCDhis2Get {
                    $query = @{}
                    if ($QueryParameters) { foreach ($k in $QueryParameters.Keys) { $query[$k] = $QueryParameters[$k] } }
                    $script:Fake.Requests.Add([pscustomobject]@{ Path = $Path; Query = $query; Fields = @($Fields); Filter = @($Filter); Hostname = $Hostname })
                    $script:FakePath = $Path
                    $response = switch -Regex ($Path) {
                        '^api/system/info$' { [ordered]@{ version = $script:Fake.Version }; break }
                        '^api/me$' {
                            $me = [ordered]@{
                                organisationUnits = @($script:Fake.MeUnits | ForEach-Object { $id = $_; $u = @($script:Fake.OrgUnits | Where-Object { $_.id -ceq $id })[0]; [ordered]@{ id = $u.id; path = $u.path } })
                                authorities       = @($script:Fake.Authorities)
                            }
                            Select-FakeField $me @($Fields)
                            break
                        }
                        '^api/organisationUnits$' {
                            $rows = @($script:Fake.OrgUnits)
                            foreach ($f in @($Filter)) {
                                $property, $operator, $value = ([string]$f) -split ':', 3
                                $list = @($value.TrimStart('[').TrimEnd(']') -split ',')
                                $rows = @($rows | Where-Object {
                                        $row = $_
                                        switch ("${property}:$operator") {
                                            'path:like' { $row.path.Contains($value, [System.StringComparison]::Ordinal) }
                                            'code:like' { $row.code.Contains($value, [System.StringComparison]::Ordinal) }
                                            # Looser than DHIS2 on purpose: a code differing in case comes back, and the cmdlet must not take it.
                                            'code:in' { $list -contains $row.code }
                                            'code:eq' { $row.code -eq $value }
                                            'id:in' { $list -ccontains $row.id }
                                            default { throw "The fake does not read the filter '$f'." }
                                        }
                                    })
                            }
                            [ordered]@{ organisationUnits = @($rows | ForEach-Object { [ordered]@{ id = $_.id; code = $_.code; path = $_.path } }) }
                            break
                        }
                        '^api/metadata$' {
                            $r = [ordered]@{}
                            if ($query['programs:filter'] -ceq 'code:eq:NEOIPC_CORE' -and -not $script:Fake.HideProgram) {
                                $program = [ordered]@{ id = $script:Fake.ProgramId; code = 'NEOIPC_CORE'; programStages = $script:Fake.Stages }
                                $r['programs'] = @(Select-FakeMetadataField $program ([string]$query['programs:fields']))
                            }
                            if ($query.ContainsKey('trackedEntityAttributes:filter')) {
                                $codes = @(([string]$query['trackedEntityAttributes:filter']) -replace '^code:in:\[|\]$', '' -split ',')
                                $found = @($script:Fake.Attributes | Where-Object { $codes -ccontains $_.code -and -not $script:Fake.Unreadable.Contains($_.code) })
                                if ($found.Count -gt 0) {
                                    $r['trackedEntityAttributes'] = @($found | ForEach-Object { Select-FakeMetadataField ([ordered]@{ id = $_.id; code = $_.code }) ([string]$query['trackedEntityAttributes:fields']) })
                                }
                            }
                            if ($query.ContainsKey('dataElements:filter')) {
                                $filterText = [string]$query['dataElements:filter']
                                $codes = if ($filterText.StartsWith('code:eq:')) { @($filterText.Substring(8)) } else { @($filterText -replace '^code:in:\[|\]$', '' -split ',') }
                                $found = @($script:Fake.DataElements | Where-Object { $codes -ccontains $_.code })
                                if ($found.Count -gt 0) {
                                    $r['dataElements'] = @($found | ForEach-Object { Select-FakeMetadataField ([ordered]@{ id = $_.id; code = $_.code }) ([string]$query['dataElements:fields']) })
                                }
                            }
                            # A type read without a filter, which DHIS2 answers with every object of the type.
                            if ($query.ContainsKey('organisationUnits:fields')) { $r['organisationUnits'] = @($script:Fake.OrgUnits | ForEach-Object { [ordered]@{ id = $_.id; code = $_.code } }) }
                            if ($query.ContainsKey('programStages:fields')) { $r['programStages'] = $script:Fake.Stages }
                            $r
                            break
                        }
                        '^api/tracker/(trackedEntities|enrollments|events)$' { Invoke-FakeTrackerRead $Matches[1] $query @($Fields); break }
                        default { throw "Unexpected GET $Path" }
                    }
                    # Through JSON, as the GET helper parses DHIS2's answer: ordered dictionaries, dates kept as text.
                    $response | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -DateKind String
                }
            }

            function Get-FakeRead([string]$Resource) { @($script:Fake.Requests | Where-Object { $_.Path -ceq "api/tracker/$Resource" }) }

            # A read's output, the errors it writes to the error stream, and its warnings; a terminating error is returned in
            # Stop rather than thrown. The errors come from the stream, which shows what a user sees: -ErrorVariable also
            # collects the failures of nested calls that the cmdlet catches.
            function Invoke-Read([string]$Command, [hashtable]$Arguments = @{}, [object[]]$Pipe) {
                $splat = @{ Auth = $script:Auth; Hostname = $script:Host1; ErrorAction = 'Continue'; WarningAction = 'SilentlyContinue'; WarningVariable = 'readWarnings' }
                foreach ($k in $Arguments.Keys) { $splat[$k] = $Arguments[$k] }
                $stop = $null
                $merged = try { if ($PSBoundParameters.ContainsKey('Pipe')) { $Pipe | & $Command @splat 2>&1 } else { & $Command @splat 2>&1 } } catch { $stop = $_ }
                [pscustomobject]@{
                    Output   = @($merged | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
                    Errors   = @($merged | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
                    Warnings = @($readWarnings)
                    Stop     = $stop
                }
            }

            # The corpus most tests read: two patients of DEPT_A, one of DEPT_B, and one of DEPT_Z outside the caller's
            # hierarchy, with an event each.
            function Add-FakeCorpus {
                Add-FakePatient -Uid 'TePat000001' -NeoIpcId 'A-1' -OrgUnit 'OuDeptA0001' -Attributes @{ NEOIPC_TEA_SEX = '1'; NEOIPC_TEA_BIRTH_WEIGHT = '1200'; NEOIPC_TEA_GEST_AGE = '28+3'; NeoIPC_TEA_TOTAL_GESTATION_DAYS = '199' }
                Add-FakePatient -Uid 'TePat000002' -NeoIpcId 'A-2' -OrgUnit 'OuDeptA0001'
                Add-FakePatient -Uid 'TePat000003' -NeoIpcId 'B-1' -OrgUnit 'OuDeptB0001'
                Add-FakePatient -Uid 'TePat000004' -NeoIpcId 'Z-1' -OrgUnit 'OuDeptZ0001'
                Add-FakeEvent -Uid 'EvPat000001' -TrackedEntity 'TePat000001' -Stage 'StgAdmn0001'
                Add-FakeEvent -Uid 'EvPat000002' -TrackedEntity 'TePat000002' -Stage 'StgBsi00001'
                Add-FakeEvent -Uid 'EvPat000003' -TrackedEntity 'TePat000003' -Stage 'StgAdmn0001'
                Add-FakeEvent -Uid 'EvPat000004' -TrackedEntity 'TePat000004' -Stage 'StgAdmn0001'
            }
        }

        BeforeEach {
            New-FakeInstance '2.43.2'
            Set-FakeMock
        }

        Context 'the request dialect' {
            It 'Read-PatientInfo sends DHIS2 <Version> the names <Names>' -ForEach @(
                # NEOIPC-COMPAT(dhis2-2.40-tracker-dialect): see Private/TrackerDialect.ps1.
                @{ Version = '2.40.12'; Names = @('orgUnit', 'ouMode', 'program', 'skipPaging', 'trackedEntity'); Ids = 'TePat000001;TePat000002' }
                @{ Version = '2.41.10'; Names = @('orgUnitMode', 'orgUnits', 'program', 'trackedEntities'); Ids = 'TePat000001,TePat000002' }
                @{ Version = '2.42.0'; Names = @('orgUnitMode', 'orgUnits', 'program', 'trackedEntities'); Ids = 'TePat000001,TePat000002' }
                @{ Version = '2.42.6'; Names = @('orgUnitMode', 'orgUnits', 'program', 'trackedEntities'); Ids = 'TePat000001,TePat000002' }
                @{ Version = '2.43.2'; Names = @('orgUnitMode', 'orgUnits', 'program', 'trackedEntities'); Ids = 'TePat000001,TePat000002' }
            ) {
                New-FakeInstance $Version; Add-FakeCorpus
                $r = Invoke-Read 'Read-PatientInfo' @{ TrackedEntityId = 'TePat000001', 'TePat000002'; OrgUnitCode = 'DEPT_A' }
                $r.Stop | Should -BeNullOrEmpty
                @($r.Output.TrackedEntityId) | Should -Be @('TePat000001', 'TePat000002')
                $reads = Get-FakeRead 'trackedEntities'
                $reads.Count | Should -Be 1
                [string[]]@($reads[0].Query.Keys | Sort-Object -CaseSensitive) | Should -BeExactly $Names
                $reads[0].Query['program'] | Should -BeExactly 'PrgCore0001'
                $reads[0].Query[$(if ($Version -eq '2.40.12') { 'trackedEntity' } else { 'trackedEntities' })] | Should -BeExactly $Ids
            }
            It 'Read-EnrolmentInfo sends DHIS2 <Version> the names <QueryNames> by query and <UidNames> by UID' -ForEach @(
                # NEOIPC-COMPAT(dhis2-2.40-tracker-dialect): see Private/TrackerDialect.ps1.
                @{ Version = '2.40.12'; QueryNames = @('enrolledAfter', 'orgUnit', 'ouMode', 'program', 'skipPaging', 'trackedEntity'); UidNames = @('enrollment', 'program', 'skipPaging') }
                @{ Version = '2.41.10'; QueryNames = @('enrolledAfter', 'orgUnitMode', 'orgUnits', 'program', 'trackedEntity'); UidNames = @('enrolledAfter', 'enrollments', 'orgUnitMode', 'orgUnits', 'program') }
                @{ Version = '2.42.6'; QueryNames = @('enrolledAfter', 'orgUnitMode', 'orgUnits', 'program', 'trackedEntity'); UidNames = @('enrolledAfter', 'enrollments', 'orgUnitMode', 'orgUnits', 'program') }
                @{ Version = '2.43.2'; QueryNames = @('enrolledAfter', 'orgUnitMode', 'orgUnits', 'program', 'trackedEntity'); UidNames = @('enrolledAfter', 'enrollments', 'orgUnitMode', 'orgUnits', 'program') }
            ) {
                New-FakeInstance $Version; Add-FakeCorpus
                $r = Invoke-Read 'Read-EnrolmentInfo' @{ TrackedEntityId = 'TePat000001'; OrgUnitCode = 'DEPT_A'; AdmissionDateFrom = [datetime]'2025-01-01' }
                $r.Stop | Should -BeNullOrEmpty
                @($r.Output.EnrollmentId) | Should -Be @('EnPat000001')
                $byQuery = @(Get-FakeRead 'enrollments')[0]
                [string[]]@($byQuery.Query.Keys | Sort-Object -CaseSensitive) | Should -BeExactly $QueryNames
                $byQuery.Query['enrolledAfter'] | Should -BeExactly '2025-01-01'

                $script:Fake.Requests.Clear()
                $r = Invoke-Read 'Read-EnrolmentInfo' @{ EnrollmentId = 'EnPat000001'; OrgUnitCode = 'DEPT_A'; AdmissionDateFrom = [datetime]'2025-01-01' }
                $r.Stop | Should -BeNullOrEmpty
                @($r.Output.EnrollmentId) | Should -Be @('EnPat000001')
                $byUid = @(Get-FakeRead 'enrollments')[0]
                [string[]]@($byUid.Query.Keys | Sort-Object -CaseSensitive) | Should -BeExactly $UidNames
            }
            It 'Read-EventInfo sends DHIS2 <Version> the names <Names>' -ForEach @(
                # NEOIPC-COMPAT(dhis2-2.40-tracker-dialect): see Private/TrackerDialect.ps1.
                @{ Version = '2.40.12'; Names = @('event', 'occurredAfter', 'orgUnit', 'ouMode', 'program', 'programStage', 'skipPaging', 'trackedEntity'); ListNames = @('enrollments', 'ouMode', 'program', 'skipPaging') }
                @{ Version = '2.41.10'; Names = @('events', 'occurredAfter', 'orgUnit', 'orgUnitMode', 'program', 'programStage', 'trackedEntity'); ListNames = @('enrollments', 'orgUnitMode', 'program') }
                @{ Version = '2.42.0'; Names = @('events', 'occurredAfter', 'orgUnit', 'orgUnitMode', 'program', 'programStage', 'trackedEntity'); ListNames = @('enrollments', 'orgUnitMode', 'program') }
                @{ Version = '2.42.6'; Names = @('events', 'occurredAfter', 'orgUnit', 'orgUnitMode', 'program', 'programStage', 'trackedEntity'); ListNames = @('enrollments', 'orgUnitMode', 'program') }
                @{ Version = '2.43.2'; Names = @('events', 'occurredAfter', 'orgUnit', 'orgUnitMode', 'program', 'programStage', 'trackedEntity'); ListNames = @('enrollments', 'orgUnitMode', 'program') }
            ) {
                New-FakeInstance $Version; Add-FakeCorpus
                $r = Invoke-Read 'Read-EventInfo' @{ EventId = 'EvPat000001'; TrackedEntityId = 'TePat000001'; OrgUnitCode = 'DEPT_A'; EventType = 'Admission'; OccurredAfter = [datetime]'2025-01-01' }
                $r.Stop | Should -BeNullOrEmpty
                @($r.Output.EventId) | Should -Be @('EvPat000001')
                [string[]]@((Get-FakeRead 'events')[0].Query.Keys | Sort-Object -CaseSensitive) | Should -BeExactly $Names

                $script:Fake.Requests.Clear()
                $r = Invoke-Read 'Read-EventInfo' @{ EnrollmentId = 'EnPat000001', 'EnPat000002' }
                $r.Stop | Should -BeNullOrEmpty
                @($r.Output.EventId) | Should -Be @('EvPat000001', 'EvPat000002')
                $reads = Get-FakeRead 'events'
                $reads.Count | Should -Be 1
                [string[]]@($reads[0].Query.Keys | Sort-Object -CaseSensitive) | Should -BeExactly $ListNames
                $reads[0].Query['enrollments'] | Should -BeExactly 'EnPat000001,EnPat000002'
            }
            It 'names the enrolment and event parameters of DHIS2 <Version>' -ForEach @(
                # NEOIPC-COMPAT(dhis2-2.40-tracker-dialect): see Private/TrackerDialect.ps1.
                @{ Version = '2.40.12'; OmitsEvents = $true }
                @{ Version = '2.41.10'; OmitsEvents = $false }
                @{ Version = '2.43.2'; OmitsEvents = $false }
            ) {
                $dialect = Get-NeoIPCTrackerDialect -Version $Version
                $dialect.EnrollmentQuery.QueryReadOmitsEvents | Should -Be $OmitsEvents
                foreach ($name in 'TrackedEntity', 'EnrolledAfter', 'EnrolledBefore', 'UpdatedAfter') { $dialect.EnrollmentQuery.$name | Should -BeExactly ($name.Substring(0, 1).ToLowerInvariant() + $name.Substring(1)) }
                foreach ($name in 'OrgUnit', 'TrackedEntity', 'ProgramStage', 'Enrollments', 'OccurredAfter', 'OccurredBefore', 'UpdatedAfter', 'UpdatedBefore') {
                    $dialect.EventQuery.$name | Should -BeExactly ($name.Substring(0, 1).ToLowerInvariant() + $name.Substring(1))
                }
            }
        }

        Context 'org units' {
            It '<Command> writes an error for an unknown org-unit code and reads no tracker record' -ForEach @(
                @{ Command = 'Read-PatientInfo'; Resource = 'trackedEntities' }
                @{ Command = 'Read-EnrolmentInfo'; Resource = 'enrollments' }
                @{ Command = 'Read-EventInfo'; Resource = 'events' }
            ) {
                Add-FakeCorpus
                $r = Invoke-Read $Command @{ OrgUnitCode = 'NO_SUCH_UNIT' }
                $r.Stop | Should -BeNullOrEmpty
                $r.Output.Count | Should -Be 0
                $r.Errors.Count | Should -Be 1
                $r.Errors[0].CategoryInfo.Category | Should -Be 'ObjectNotFound'
                $r.Errors[0].Exception.Message | Should -BeLike "*'NO_SUCH_UNIT'*"
                (Get-FakeRead $Resource).Count | Should -Be 0
            }
            It '<Command> treats an org unit outside your hierarchy, and a code in the wrong case, as unknown' -ForEach @(
                @{ Command = 'Read-PatientInfo'; Resource = 'trackedEntities' }
                @{ Command = 'Read-EnrolmentInfo'; Resource = 'enrollments' }
                @{ Command = 'Read-EventInfo'; Resource = 'events' }
            ) {
                Add-FakeCorpus
                $r = Invoke-Read $Command @{ OrgUnitCode = 'DEPT_Z', 'dept_a' }
                $r.Output.Count | Should -Be 0
                @($r.Errors | ForEach-Object { $_.TargetObject }) | Should -Be @('DEPT_Z', 'dept_a')
                (Get-FakeRead $Resource).Count | Should -Be 0
            }
            It '<Command> reads the org units it finds beside one it does not' -ForEach @(
                @{ Command = 'Read-PatientInfo'; Expected = @('TePat000001', 'TePat000002'); Property = 'TrackedEntityId' }
                @{ Command = 'Read-EnrolmentInfo'; Expected = @('EnPat000001', 'EnPat000002'); Property = 'EnrollmentId' }
                @{ Command = 'Read-EventInfo'; Expected = @('EvPat000001', 'EvPat000002'); Property = 'EventId' }
            ) {
                Add-FakeCorpus
                $r = Invoke-Read $Command @{ OrgUnitCode = 'DEPT_A', 'NO_SUCH_UNIT' }
                @($r.Output.$Property) | Should -Be $Expected
                $r.Errors.Count | Should -Be 1
            }
            It 'finds an org unit whose code holds ",", which DHIS2 2.42 and later would cut, by a like read' {
                Add-FakeCorpus
                $script:Fake.OrgUnits = @($script:Fake.OrgUnits) + @(@{ id = 'OuDeptC0001'; code = 'DEPT,C'; path = '/OuRoot00001/OuHospX0001/OuDeptC0001' })
                Add-FakePatient -Uid 'TePat000007' -NeoIpcId 'C-7' -OrgUnit 'OuDeptC0001'
                $r = Invoke-Read 'Read-PatientInfo' @{ OrgUnitCode = 'DEPT,C' }
                $r.Errors.Count | Should -Be 0
                @($r.Output.TrackedEntityId) | Should -Be @('TePat000007')
                @($script:Fake.Requests | Where-Object { $_.Path -ceq 'api/organisationUnits' } | ForEach-Object { $_.Filter }) | Should -Contain 'code:like:DEPT'
            }
            It 'reads nothing for an empty pipeline, not every record' {
                Add-FakeCorpus
                foreach ($command in 'Read-PatientInfo', 'Read-EnrolmentInfo', 'Read-EventInfo') {
                    $r = Invoke-Read $command -Pipe @()
                    $r.Output.Count | Should -Be 0
                    $r.Stop | Should -BeNullOrEmpty
                    $r.Errors.Count | Should -Be 0
                }
                $script:Fake.Requests.Count | Should -Be 0
            }
            It '<Command> reads nothing for an empty pipeline, without an error, also when given -<Name> as an argument' -ForEach @(
                @{ Command = 'Read-PatientInfo'; Name = 'OrgUnitCode'; Arguments = @{ OrgUnitCode = 'DEPT_A' } }
                @{ Command = 'Read-EnrolmentInfo'; Name = 'OrgUnitCode'; Arguments = @{ OrgUnitCode = 'DEPT_A' } }
                @{ Command = 'Read-EventInfo'; Name = 'CreatedBy'; Arguments = @{ CreatedBy = 'admin' } }
                @{ Command = 'Read-EventInfo'; Name = 'TrackedEntityId'; Arguments = @{ TrackedEntityId = 'TePat000001' } }
            ) {
                Add-FakeCorpus
                $r = Invoke-Read $Command $Arguments -Pipe @()
                $r.Output.Count | Should -Be 0
                $r.Stop | Should -BeNullOrEmpty
                $r.Errors.Count | Should -Be 0
                $script:Fake.Requests.Count | Should -Be 0
            }
            It 'reads nothing for a filter given without a value, and says so' {
                Add-FakeCorpus
                $r = Invoke-Read 'Read-EventInfo' @{ TrackedEntityId = [string[]]@() }
                $r.Output.Count | Should -Be 0
                $r.Errors[0].FullyQualifiedErrorId | Should -BeLike 'NeoIPCTrackerReadEmptyFilter*'
                $script:Fake.Requests.Count | Should -Be 0
            }
            It '<Command> reads nothing when the piped objects give its filters no value, whatever its arguments' -ForEach @(
                @{ Command = 'Read-PatientInfo' }, @{ Command = 'Read-EnrolmentInfo' }, @{ Command = 'Read-EventInfo' }
            ) {
                Add-FakeCorpus
                $r = Invoke-Read $Command @{ OrgUnitCode = 'DEPT_A' } -Pipe @([pscustomobject]@{ TrackedEntityId = '' })
                $r.Output.Count | Should -Be 0
                $r.Stop | Should -BeNullOrEmpty
                $r.Errors.Count | Should -Be 0
                $script:Fake.Requests.Count | Should -Be 0
            }
        }

        Context 'patient IDs' {
            It 'looks patient IDs up in one in filter whose values ";" separates, without brackets, on DHIS2 <Version>' -ForEach @(
                @{ Version = '2.40.12' }, @{ Version = '2.41.10' }, @{ Version = '2.42.6' }, @{ Version = '2.43.2' }
            ) {
                New-FakeInstance $Version; Add-FakeCorpus
                $r = Invoke-Read 'Read-PatientInfo' @{ NeoIpcId = 'A-1', 'B-1' }
                @($r.Output.NeoIpcId) | Should -Be @('A-1', 'B-1')
                $reads = Get-FakeRead 'trackedEntities'
                $reads.Count | Should -Be 1
                $reads[0].Query['filter'] | Should -BeExactly 'AttPatId001:in:A-1;B-1'
            }
            It 'matches patient IDs ignoring case, as DHIS2 does' {
                Add-FakeCorpus
                Add-FakePatient -Uid 'TePat000005' -NeoIpcId 'a-1' -OrgUnit 'OuDeptB0001'
                $r = Invoke-Read 'Read-PatientInfo' @{ NeoIpcId = 'a-1' }
                @($r.Output.TrackedEntityId) | Should -Be @('TePat000001', 'TePat000005')
            }
            It 'looks an ID holding ";" up in an eq request of its own on DHIS2 <Version>' -ForEach @(
                @{ Version = '2.40.12' }, @{ Version = '2.42.6' }, @{ Version = '2.43.2' }
            ) {
                New-FakeInstance $Version; Add-FakeCorpus
                Add-FakePatient -Uid 'TePat000005' -NeoIpcId 'C;1' -OrgUnit 'OuDeptB0001'
                $r = Invoke-Read 'Read-PatientInfo' @{ NeoIpcId = 'A-1', 'C;1' }
                @($r.Output.NeoIpcId) | Should -Be @('A-1', 'C;1')
                @((Get-FakeRead 'trackedEntities') | ForEach-Object { $_.Query['filter'] }) | Should -Be @('AttPatId001:in:A-1', 'AttPatId001:eq:C;1')
            }
            It 'before 2.42.1 looks an ID holding one "/" up alone and refuses one holding two, on DHIS2 <Version>' -ForEach @(
                # NEOIPC-COMPAT(dhis2-pre-2.42.1-filter-escape): see Private/TrackerDialect.ps1.
                @{ Version = '2.40.12' }, @{ Version = '2.41.10' }, @{ Version = '2.42.0' }
            ) {
                New-FakeInstance $Version; Add-FakeCorpus
                Add-FakePatient -Uid 'TePat000005' -NeoIpcId 'DE/1' -OrgUnit 'OuDeptB0001'
                Add-FakePatient -Uid 'TePat000006' -NeoIpcId 'DE-BER-01/2024-0000001/b' -OrgUnit 'OuDeptB0001'
                $r = Invoke-Read 'Read-PatientInfo' @{ NeoIpcId = 'A-1', 'DE/1', 'DE-BER-01/2024-0000001/b' }
                @($r.Output.NeoIpcId) | Should -Be @('A-1', 'DE/1')
                @((Get-FakeRead 'trackedEntities') | ForEach-Object { $_.Query['filter'] }) | Should -Be @('AttPatId001:in:A-1', 'AttPatId001:eq:DE//1')
                $r.Errors.Count | Should -Be 1
                $r.Errors[0].TargetObject | Should -BeExactly 'DE-BER-01/2024-0000001/b'
                $r.Errors[0].Exception.Message | Should -BeLike "*more than one '/'*UID*"
            }
            It 'from 2.42.1 looks IDs with slashes up in the in filter, on DHIS2 <Version>' -ForEach @(
                @{ Version = '2.42.1' }, @{ Version = '2.42.6' }, @{ Version = '2.43.2' }
            ) {
                New-FakeInstance $Version; Add-FakeCorpus
                Add-FakePatient -Uid 'TePat000006' -NeoIpcId 'DE-BER-01/2024-0000001/b' -OrgUnit 'OuDeptB0001'
                $r = Invoke-Read 'Read-PatientInfo' @{ NeoIpcId = 'A-1', 'DE-BER-01/2024-0000001/b' }
                @($r.Output.NeoIpcId) | Should -Be @('A-1', 'DE-BER-01/2024-0000001/b')
                @((Get-FakeRead 'trackedEntities') | ForEach-Object { $_.Query['filter'] }) | Should -Be @('AttPatId001:in:A-1;DE-BER-01//2024-0000001//b')
            }
            It 'with -TrackedEntityId, reads by UID and compares the patient IDs itself, ignoring case' {
                Add-FakeCorpus
                $r = Invoke-Read 'Read-PatientInfo' @{ TrackedEntityId = 'TePat000001', 'TePat000002'; NeoIpcId = 'a-2' }
                @($r.Output.TrackedEntityId) | Should -Be @('TePat000002')
                (Get-FakeRead 'trackedEntities')[0].Query.ContainsKey('filter') | Should -BeFalse
            }
            It 'ends the read when the account cannot read NEOIPC_PATIENT_ID' {
                Add-FakeCorpus
                [void]$script:Fake.Unreadable.Add('NEOIPC_PATIENT_ID')
                $r = Invoke-Read 'Read-PatientInfo' @{ NeoIpcId = 'A-1' }
                $r.Stop.FullyQualifiedErrorId | Should -BeLike 'NeoIPCTrackerReadNoPatientIdAttribute*'
                (Get-FakeRead 'trackedEntities').Count | Should -Be 0
            }
            It 'returns the attribute values, dates as [datetime], and the NEOIPC_CORE enrolments' {
                Add-FakeCorpus
                Add-FakeEnrollment -Uid 'EnOther0001' -TrackedEntity 'TePat000001' -Program 'PrgOthr0001'
                $p = (Invoke-Read 'Read-PatientInfo' @{ TrackedEntityId = 'TePat000001' }).Output[0]
                $p.OrgUnitId | Should -BeExactly 'OuDeptA0001'
                $p.NeoIpcId | Should -BeExactly 'A-1'
                $p.Sex | Should -BeExactly '1'
                $p.BirthWeight | Should -BeExactly '1200'
                $p.GestationalAge | Should -BeExactly '28+3'
                $p.TotalGestationDays | Should -BeExactly '199'
                $p.CreatedAt | Should -BeOfType [datetime]
                $p.CreatedAt | Should -Be ([datetime]'2025-01-01T08:00:00')
                $p.EnrollmentIds | Should -Be @('EnPat000001')
                , $p.EnrollmentIds | Should -BeOfType [string[]]
            }
        }

        Context 'given tracked entities' {
            It 'Read-PatientInfo writes an error for each that is no NEOIPC_CORE patient it can read, on DHIS2 <Version>' -ForEach @(
                @{ Version = '2.40.12' }, @{ Version = '2.41.10' }, @{ Version = '2.42.6' }, @{ Version = '2.43.2' }
            ) {
                New-FakeInstance $Version; Add-FakeCorpus
                Add-FakePatient -Uid 'TeGone00001' -NeoIpcId 'G-1' -Deleted
                $r = Invoke-Read 'Read-PatientInfo' @{ TrackedEntityId = 'TePat000001', 'TeNoSuch001', 'TeGone00001', 'TePat000004' }
                $r.Stop | Should -BeNullOrEmpty
                @($r.Output.TrackedEntityId) | Should -Be @('TePat000001')
                @($r.Errors | ForEach-Object { $_.TargetObject }) | Should -Be @('TeNoSuch001', 'TeGone00001', 'TePat000004')
                foreach ($e in $r.Errors) { $e.FullyQualifiedErrorId | Should -BeLike 'NeoIPCTrackerReadTrackedEntityNotFound*' }
            }
            It 'Read-PatientInfo writes no error for one that only the org units leave out' {
                Add-FakeCorpus
                $r = Invoke-Read 'Read-PatientInfo' @{ TrackedEntityId = 'TePat000001', 'TePat000003'; OrgUnitCode = 'DEPT_A' }
                @($r.Output.TrackedEntityId) | Should -Be @('TePat000001')
                $r.Errors.Count | Should -Be 0
            }
            It 'Read-EventInfo reads the events of a patient owned within the data-capture org units but outside the search org units, on DHIS2 <Version>' -ForEach @(
                @{ Version = '2.40.12' }, @{ Version = '2.41.10' }, @{ Version = '2.42.6' }, @{ Version = '2.43.2' }
            ) {
                New-FakeInstance $Version; Add-FakeCorpus
                $script:Fake.SearchUnits.Add('OuDeptB0001')
                $r = Invoke-Read 'Read-EventInfo' @{ TrackedEntityId = 'TePat000001', 'TePat000003' }
                $r.Errors.Count | Should -Be 0
                @($r.Output.EventId) | Should -Be @('EvPat000001', 'EvPat000003')
            }
            It 'Read-EnrolmentInfo names a patient outside the search org units as one it cannot read, as DHIS2 <Version> reads none of its enrolments' -ForEach @(
                @{ Version = '2.40.12' }, @{ Version = '2.41.10' }
            ) {
                New-FakeInstance $Version; Add-FakeCorpus
                $script:Fake.SearchUnits.Add('OuDeptB0001')
                $r = Invoke-Read 'Read-EnrolmentInfo' @{ TrackedEntityId = 'TePat000001', 'TePat000003' }
                @($r.Output.EnrollmentId) | Should -Be @('EnPat000003')
                $r.Errors.Count | Should -Be 1
                $r.Errors[0].TargetObject | Should -BeExactly 'TePat000001'
            }
            It 'Read-EventInfo writes an error for one deleted after it was read, which DHIS2 <Version> refuses, and reads the others' -ForEach @(
                @{ Version = '2.42.6' }, @{ Version = '2.43.2' }
            ) {
                New-FakeInstance $Version; Add-FakeCorpus
                [void]$script:Fake.DeleteOnRead.Add('TePat000001')
                $r = Invoke-Read 'Read-EventInfo' @{ TrackedEntityId = 'TePat000001', 'TePat000002' }
                $r.Stop | Should -BeNullOrEmpty
                @($r.Output.EventId) | Should -Be @('EvPat000002')
                $r.Errors.Count | Should -Be 1
                $r.Errors[0].FullyQualifiedErrorId | Should -BeLike 'NeoIPCTrackerReadTrackedEntityNotFound*'
                $r.Errors[0].TargetObject | Should -BeExactly 'TePat000001'
            }
            It 'Read-EnrolmentInfo writes an error for one deleted after it was read, which DHIS2 2.42 refuses, and reads the others' {
                New-FakeInstance '2.42.6'; Add-FakeCorpus
                [void]$script:Fake.DeleteOnRead.Add('TePat000001')
                $r = Invoke-Read 'Read-EnrolmentInfo' @{ TrackedEntityId = 'TePat000001', 'TePat000002' }
                $r.Stop | Should -BeNullOrEmpty
                @($r.Output.EnrollmentId) | Should -Be @('EnPat000002')
                $r.Errors.Count | Should -Be 1
                $r.Errors[0].TargetObject | Should -BeExactly 'TePat000001'
            }
        }

        Context 'the event read''s requests' {
            It 'sends one request per tracked entity on DHIS2 <Version>' -ForEach @(@{ Version = '2.40.12' }, @{ Version = '2.42.6' }, @{ Version = '2.43.2' }) {
                New-FakeInstance $Version; Add-FakeCorpus
                $r = Invoke-Read 'Read-EventInfo' @{ TrackedEntityId = 'TePat000001', 'TePat000003' }
                @($r.Output.EventId) | Should -Be @('EvPat000001', 'EvPat000003')
                @((Get-FakeRead 'events') | ForEach-Object { $_.Query['trackedEntity'] }) | Should -Be @('TePat000001', 'TePat000003')
            }
            It 'sends one request per org unit on DHIS2 <Version>' -ForEach @(@{ Version = '2.40.12' }, @{ Version = '2.42.6' }, @{ Version = '2.43.2' }) {
                New-FakeInstance $Version; Add-FakeCorpus
                $r = Invoke-Read 'Read-EventInfo' @{ OrgUnitCode = 'DEPT_A', 'DEPT_B' }
                @($r.Output.EventId) | Should -Be @('EvPat000001', 'EvPat000002', 'EvPat000003')
                @((Get-FakeRead 'events') | ForEach-Object { $_.Query['orgUnit'] }) | Should -Be @('OuDeptA0001', 'OuDeptB0001')
            }
            It 'applies several program stages itself while it fans out over the tracked entities' {
                Add-FakeCorpus
                Add-FakeEvent -Uid 'EvPat000005' -TrackedEntity 'TePat000001' -Stage 'StgHap00001'
                $r = Invoke-Read 'Read-EventInfo' @{ TrackedEntityId = 'TePat000001', 'TePat000002'; ProgramStageId = 'StgAdmn0001', 'StgBsi00001' }
                @($r.Output.EventId) | Should -Be @('EvPat000001', 'EvPat000002')
                $reads = Get-FakeRead 'events'
                $reads.Count | Should -Be 2
                @($reads | Where-Object { $_.Query.ContainsKey('programStage') }).Count | Should -Be 0
            }
            It 'applies several program stages itself with an event list, in one request without a stage' {
                Add-FakeCorpus
                Add-FakeEvent -Uid 'EvPat000005' -TrackedEntity 'TePat000001' -Stage 'StgHap00001'
                $r = Invoke-Read 'Read-EventInfo' @{ EventId = 'EvPat000001', 'EvPat000002', 'EvPat000005'; ProgramStageId = 'StgAdmn0001', 'StgHap00001' }
                @($r.Output.EventId) | Should -Be @('EvPat000001', 'EvPat000005')
                $reads = Get-FakeRead 'events'
                $reads.Count | Should -Be 1
                $reads[0].Query.ContainsKey('programStage') | Should -BeFalse
            }
            It 'sends one request per program stage when only the stages have several values' {
                Add-FakeCorpus
                $r = Invoke-Read 'Read-EventInfo' @{ OrgUnitCode = 'DEPT_A'; ProgramStageId = 'StgAdmn0001', 'StgBsi00001' }
                @($r.Output.EventId) | Should -Be @('EvPat000001', 'EvPat000002')
                @((Get-FakeRead 'events') | ForEach-Object { $_.Query['programStage'] }) | Should -Be @('StgAdmn0001', 'StgBsi00001')
            }
            It 'fans out over the tracked entities it can read and compares several org units itself' {
                Add-FakeCorpus
                $r = Invoke-Read 'Read-EventInfo' @{ TrackedEntityId = 'TePat000001', 'TePat000003', 'TePat000004'; OrgUnitCode = 'DEPT_A', 'DEPT_B' }
                @($r.Output.EventId) | Should -Be @('EvPat000001', 'EvPat000003')
                $reads = Get-FakeRead 'events'
                @($reads | ForEach-Object { $_.Query['trackedEntity'] }) | Should -Be @('TePat000001', 'TePat000003')
                @($reads | Where-Object { $_.Query.ContainsKey('orgUnit') }).Count | Should -Be 0
                # TePat000004 lies outside the caller's hierarchy.
                $r.Errors.Count | Should -Be 1
                $r.Errors[0].TargetObject | Should -BeExactly 'TePat000004'
            }
            It 'compares several org units itself by who owns the patient, whatever org unit an event was entered in' {
                Add-FakeCorpus
                Add-FakePatient -Uid 'TePat000005' -NeoIpcId 'A-5' -OrgUnit 'OuDeptB0001' -Owner 'OuDeptA0001'
                Add-FakeEvent -Uid 'EvPat000005' -TrackedEntity 'TePat000005'
                Add-FakePatient -Uid 'TePat000006' -NeoIpcId 'B-6' -OrgUnit 'OuDeptA0001' -Owner 'OuDeptB0001'
                Add-FakeEvent -Uid 'EvPat000006' -TrackedEntity 'TePat000006'
                $r = Invoke-Read 'Read-EventInfo' @{ TrackedEntityId = 'TePat000005', 'TePat000003', 'TePat000006'; OrgUnitCode = 'DEPT_A', 'HOSP_X' }
                $r.Stop | Should -BeNullOrEmpty
                @($r.Output.EventId) | Should -Be @('EvPat000005')
                $owners = Get-FakeRead 'trackedEntities'
                $owners.Count | Should -Be 1
                $owners[0].Query['trackedEntities'] | Should -BeExactly 'TePat000005,TePat000003,TePat000006'
            }
            It 'with an event list and several org units, keeps the events whose patient one of them owns' {
                Add-FakeCorpus
                Add-FakePatient -Uid 'TePat000005' -NeoIpcId 'A-5' -OrgUnit 'OuDeptB0001' -Owner 'OuDeptA0001'
                Add-FakeEvent -Uid 'EvPat000005' -TrackedEntity 'TePat000005'
                Add-FakePatient -Uid 'TePat000006' -NeoIpcId 'B-6' -OrgUnit 'OuDeptA0001' -Owner 'OuDeptB0001'
                Add-FakeEvent -Uid 'EvPat000006' -TrackedEntity 'TePat000006'
                $r = Invoke-Read 'Read-EventInfo' @{ EventId = 'EvPat000001', 'EvPat000005', 'EvPat000006'; OrgUnitCode = 'DEPT_A', 'HOSP_X' }
                $r.Stop | Should -BeNullOrEmpty
                @($r.Output.EventId) | Should -Be @('EvPat000001', 'EvPat000005')
            }
            It 'with an event list, compares several tracked entities itself without fanning out' {
                Add-FakeCorpus
                $r = Invoke-Read 'Read-EventInfo' @{ EventId = 'EvPat000001', 'EvPat000002', 'EvPat000003'; TrackedEntityId = 'TePat000001', 'TePat000003' }
                @($r.Output.EventId) | Should -Be @('EvPat000001', 'EvPat000003')
                $reads = Get-FakeRead 'events'
                $reads.Count | Should -Be 1
                $reads[0].Query.ContainsKey('trackedEntity') | Should -BeFalse
            }
            It 'with events and enrolments, reads the events and compares the enrolments itself' {
                Add-FakeCorpus
                $r = Invoke-Read 'Read-EventInfo' @{ EventId = 'EvPat000001', 'EvPat000002'; EnrollmentId = 'EnPat000002' }
                @($r.Output.EventId) | Should -Be @('EvPat000002')
                (Get-FakeRead 'events')[0].Query.ContainsKey('enrollments') | Should -BeFalse
            }
            It 'never sends a value that is no UID, which DHIS2 2.40 would drop and so widen the read' {
                New-FakeInstance '2.40.12'; Add-FakeCorpus
                $r = Invoke-Read 'Read-EventInfo' @{ EventId = 'not-a-uid' }
                $r.Output.Count | Should -Be 0
                $r.Errors[0].TargetObject | Should -BeExactly 'not-a-uid'
                (Get-FakeRead 'events').Count | Should -Be 0
            }
            It 'finds -EventType''s stage by its code, and without the code by its name' {
                Add-FakeCorpus
                (Invoke-Read 'Read-EventInfo' @{ EventType = 'Primary Sepsis/BSI' }).Output.EventId | Should -Be @('EvPat000002')
                (Get-FakeRead 'events')[0].Query['programStage'] | Should -BeExactly 'StgBsi00001'
                # NEOIPC-COMPAT(programstage-code): see Read-EventInfo.
                $script:Fake.Stages[2]['code'] = $null
                (Invoke-Read 'Read-EventInfo' @{ EventType = 'Primary Sepsis/BSI' }).Output.EventId | Should -Be @('EvPat000002')
            }
            It 'writes an error and reads nothing for a stage NEOIPC_CORE does not have' {
                Add-FakeCorpus
                $script:Fake.Stages[2]['code'] = 'OTHER'
                $script:Fake.Stages[2]['name'] = 'Other'
                $r = Invoke-Read 'Read-EventInfo' @{ EventType = 'Primary Sepsis/BSI' }
                $r.Output.Count | Should -Be 0
                $r.Errors[0].FullyQualifiedErrorId | Should -BeLike 'NeoIPCTrackerReadEventTypeNotFound*'
                $r = Invoke-Read 'Read-EventInfo' @{ ProgramStageId = 'StgNoSuch01' }
                $r.Output.Count | Should -Be 0
                $r.Errors[0].TargetObject | Should -BeExactly 'StgNoSuch01'
                (Get-FakeRead 'events').Count | Should -Be 0
            }
            It 'takes -EventType and -ProgramStageId as one set of stages, reading those it finds' {
                Add-FakeCorpus
                $r = Invoke-Read 'Read-EventInfo' @{ EventType = 'Admission'; ProgramStageId = 'StgNoSuch01' }
                @($r.Output.EventId) | Should -Be @('EvPat000001', 'EvPat000003')
                $r.Errors.Count | Should -Be 1
                $r.Errors[0].TargetObject | Should -BeExactly 'StgNoSuch01'
                $script:Fake.Stages[2]['code'] = 'OTHER'
                $script:Fake.Stages[2]['name'] = 'Other'
                $r = Invoke-Read 'Read-EventInfo' @{ EventType = 'Primary Sepsis/BSI'; ProgramStageId = 'StgAdmn0001' }
                @($r.Output.EventId) | Should -Be @('EvPat000001', 'EvPat000003')
                $r.Errors.Count | Should -Be 1
                $r.Errors[0].FullyQualifiedErrorId | Should -BeLike 'NeoIPCTrackerReadEventTypeNotFound*'
            }
            It 'writes an error for a tracked entity DHIS2 does not know, and reads the others, on DHIS2 <Version>' -ForEach @(
                @{ Version = '2.40.12' }, @{ Version = '2.41.10' }, @{ Version = '2.42.6' }, @{ Version = '2.43.2' }
            ) {
                New-FakeInstance $Version; Add-FakeCorpus
                $r = Invoke-Read 'Read-EventInfo' @{ TrackedEntityId = 'TePat000001', 'TeNoSuch001' }
                @($r.Output.EventId) | Should -Be @('EvPat000001')
                $r.Errors.Count | Should -Be 1
                $r.Errors[0].FullyQualifiedErrorId | Should -BeLike 'NeoIPCTrackerReadTrackedEntityNotFound*'
                $r.Errors[0].TargetObject | Should -BeExactly 'TeNoSuch001'
            }
            It 'writes an error for a deleted tracked entity, which DHIS2 <Version> answers with nothing' -ForEach @(@{ Version = '2.40.12' }, @{ Version = '2.41.10' }) {
                New-FakeInstance $Version; Add-FakeCorpus
                Add-FakePatient -Uid 'TeGone00001' -NeoIpcId 'G-1' -Deleted
                $r = Invoke-Read 'Read-EventInfo' @{ TrackedEntityId = 'TePat000001', 'TeGone00001' }
                @($r.Output.EventId) | Should -Be @('EvPat000001')
                $r.Errors.Count | Should -Be 1
                $r.Errors[0].TargetObject | Should -BeExactly 'TeGone00001'
                @((Get-FakeRead 'events') | ForEach-Object { $_.Query['trackedEntity'] }) | Should -Be @('TePat000001')
            }
        }

        Context 'the username filters' {
            It '-CreatedBy admin keeps the events admin created, and none created by adm, by min, or by nobody, on DHIS2 <Version>' -ForEach @(@{ Version = '2.40.12' }, @{ Version = '2.43.2' }) {
                New-FakeInstance $Version; Add-FakeCorpus
                Add-FakeEvent -Uid 'EvAdmin0001' -TrackedEntity 'TePat000001' -CreatedBy 'admin'
                Add-FakeEvent -Uid 'EvAdm000001' -TrackedEntity 'TePat000001' -CreatedBy 'adm'
                Add-FakeEvent -Uid 'EvMin000001' -TrackedEntity 'TePat000001' -CreatedBy 'min'
                Add-FakeEvent -Uid 'EvNobody001' -TrackedEntity 'TePat000001' -CreatedBy ''
                (Invoke-Read 'Read-EventInfo' @{ OrgUnitCode = 'DEPT_A'; CreatedBy = 'admin' }).Output.EventId | Should -Be @('EvAdmin0001')
            }
            It '-UpdatedBy and -StoredBy compare exactly too' {
                Add-FakeCorpus
                Add-FakeEvent -Uid 'EvUpd000001' -TrackedEntity 'TePat000001' -UpdatedBy 'Updater' -StoredBy 'stored'
                Add-FakeEvent -Uid 'EvUpd000002' -TrackedEntity 'TePat000001' -UpdatedBy 'updater-2' -StoredBy 'store'
                (Invoke-Read 'Read-EventInfo' @{ OrgUnitCode = 'DEPT_A'; UpdatedBy = 'Updater' }).Output.EventId | Should -Be @('EvUpd000001')
                (Invoke-Read 'Read-EventInfo' @{ OrgUnitCode = 'DEPT_A'; StoredBy = 'stored' }).Output.EventId | Should -Be @('EvUpd000001')
            }
        }

        Context 'the data elements' {
            It 'keeps the events with a value for any of the codes and keys DataValues by the codes in their order' {
                Add-FakeCorpus
                Add-FakeEvent -Uid 'EvBsi000001' -TrackedEntity 'TePat000001' -Stage 'StgBsi00001' -DataValues @{ DeBsiName01 = 'Agent X' }
                Add-FakeEvent -Uid 'EvBsi000002' -TrackedEntity 'TePat000001' -Stage 'StgBsi00001' -DataValues @{ DeBsiName01 = '' }
                $r = Invoke-Read 'Read-EventInfo' @{ OrgUnitCode = 'DEPT_A'; DataElementCode = 'NEOIPC_HAP_PATHOGEN_1_NAME', 'NEOIPC_BSI_PATHOGEN_1_NAME' }
                @($r.Output.EventId) | Should -Be @('EvBsi000001')
                $values = $r.Output[0].DataValues
                @($values.PSObject.Properties.Name) | Should -Be @('NEOIPC_HAP_PATHOGEN_1_NAME', 'NEOIPC_BSI_PATHOGEN_1_NAME')
                $values.NEOIPC_HAP_PATHOGEN_1_NAME | Should -BeNullOrEmpty
                $values.NEOIPC_BSI_PATHOGEN_1_NAME.Value | Should -BeExactly 'Agent X'
                $values.NEOIPC_BSI_PATHOGEN_1_NAME.CreatedByUsername | Should -BeExactly 'value-creator'
                $values.NEOIPC_BSI_PATHOGEN_1_NAME.UpdatedAt | Should -BeOfType [datetime]
            }
            It 'writes an error for an unknown code, and reads nothing when no code is known' {
                Add-FakeCorpus
                $r = Invoke-Read 'Read-EventInfo' @{ OrgUnitCode = 'DEPT_A'; DataElementCode = 'neoipc_bsi_pathogen_1_name' }
                $r.Output.Count | Should -Be 0
                $r.Errors[0].TargetObject | Should -BeExactly 'neoipc_bsi_pathogen_1_name'
                (Get-FakeRead 'events').Count | Should -Be 0
            }
            It 'reads nothing for -DataElementCode without a value, and leaves out a code differing from another only in case' {
                Add-FakeCorpus
                $r = Invoke-Read 'Read-EventInfo' @{ OrgUnitCode = 'DEPT_A'; DataElementCode = [string[]]@() }
                $r.Output.Count | Should -Be 0
                $r.Errors[0].FullyQualifiedErrorId | Should -BeLike 'NeoIPCTrackerReadEmptyFilter*'
                $script:Fake.Requests.Count | Should -Be 0
                Add-FakeEvent -Uid 'EvBsi000001' -TrackedEntity 'TePat000001' -Stage 'StgBsi00001' -DataValues @{ DeBsiName01 = 'Agent X' }
                $r = Invoke-Read 'Read-EventInfo' @{ OrgUnitCode = 'DEPT_A'; DataElementCode = 'NEOIPC_BSI_PATHOGEN_1_NAME', 'neoipc_bsi_pathogen_1_name' }
                @($r.Output.EventId) | Should -Be @('EvBsi000001')
                @($r.Output[0].DataValues.PSObject.Properties.Name) | Should -Be @('NEOIPC_BSI_PATHOGEN_1_NAME')
                $r.Errors.Count | Should -Be 1
                $r.Errors[0].TargetObject | Should -BeExactly 'neoipc_bsi_pathogen_1_name'
            }
            It 'looks a code holding "," up in an eq filter of its own, which api/metadata keeps whole' {
                Add-FakeCorpus
                $script:Fake.DataElements = @($script:Fake.DataElements) + @(@{ id = 'DeComma0001'; code = 'NEOIPC_X,Y' })
                Add-FakeEvent -Uid 'EvComma0001' -TrackedEntity 'TePat000001' -DataValues @{ DeComma0001 = 'yes' }
                $r = Invoke-Read 'Read-EventInfo' @{ OrgUnitCode = 'DEPT_A'; DataElementCode = 'NEOIPC_X,Y', 'NEOIPC_BSI_PATHOGEN_1_NAME' }
                @($r.Output.EventId) | Should -Be @('EvComma0001')
                $r.Output[0].DataValues.'NEOIPC_X,Y'.Value | Should -BeExactly 'yes'
                $filters = @($script:Fake.Requests | Where-Object { $_.Path -ceq 'api/metadata' -and $_.Query.ContainsKey('dataElements:filter') } | ForEach-Object { $_.Query['dataElements:filter'] })
                $filters | Should -Be @('code:in:[NEOIPC_BSI_PATHOGEN_1_NAME]', 'code:eq:NEOIPC_X,Y')
            }
            It 'leaves DataValues out without -DataElementCode' {
                Add-FakeCorpus
                $e = (Invoke-Read 'Read-EventInfo' @{ EventId = 'EvPat000001' }).Output[0]
                $e.PSObject.Properties.Name | Should -Not -Contain 'DataValues'
                $e.OccurredAt | Should -BeOfType [datetime]
                $e.CreatedBy | Should -BeExactly 'creator'
            }
        }

        Context 'pipelines' {
            It 'reads the events of only the patients the upstream read returned, on DHIS2 <Version>' -ForEach @(@{ Version = '2.40.12' }, @{ Version = '2.43.2' }) {
                New-FakeInstance $Version; Add-FakeCorpus
                $events = Read-PatientInfo -TrackedEntityId 'TePat000001', 'TePat000003' -OrgUnitCode 'DEPT_A' -Auth $script:Auth -Hostname $script:Host1 |
                    Read-EventInfo -Auth $script:Auth -Hostname $script:Host1
                @($events.EventId) | Should -Be @('EvPat000001')
                @((Get-FakeRead 'events') | ForEach-Object { $_.Query['trackedEntity'] }) | Should -Be @('TePat000001')
            }
            It 'reads the events of piped enrolments whoever created, updated, or stored the enrolments' {
                Add-FakeCorpus
                $events = Read-EnrolmentInfo -EnrollmentId 'EnPat000001' -Auth $script:Auth -Hostname $script:Host1 | Read-EventInfo -Auth $script:Auth -Hostname $script:Host1
                @($events.EventId) | Should -Be @('EvPat000001')
            }
            It 'reads the enrolments of the patients a patient-ID lookup returns' {
                Add-FakeCorpus
                $enrolments = Read-PatientInfo -NeoIpcId 'A-2' -Auth $script:Auth -Hostname $script:Host1 | Read-EnrolmentInfo -Auth $script:Auth -Hostname $script:Host1
                @($enrolments.EnrollmentId) | Should -Be @('EnPat000002')
            }
            It 'reads the enrolments and events of a piped patient whose record another org unit owns, on DHIS2 <Version>' -ForEach @(@{ Version = '2.40.12' }, @{ Version = '2.43.2' }) {
                New-FakeInstance $Version; Add-FakeCorpus
                Add-FakePatient -Uid 'TePat000005' -NeoIpcId 'A-5' -OrgUnit 'OuDeptB0001' -Owner 'OuDeptA0001'
                Add-FakeEvent -Uid 'EvPat000005' -TrackedEntity 'TePat000005'
                $endpoint = @{ Auth = $script:Auth; Hostname = $script:Host1 }
                @((Read-PatientInfo -NeoIpcId 'A-5' @endpoint | Read-EventInfo @endpoint).EventId) | Should -Be @('EvPat000005')
                @((Read-PatientInfo -NeoIpcId 'A-5' @endpoint | Read-EnrolmentInfo @endpoint).EnrollmentId) | Should -Be @('EnPat000005')
                @((Read-EnrolmentInfo -EnrollmentId 'EnPat000005' @endpoint | Read-EventInfo @endpoint).EventId) | Should -Be @('EvPat000005')
            }
        }

        Context 'enrolments' {
            # NEOIPC-COMPAT(dhis2-2.40-tracker-dialect): see Private/TrackerDialect.ps1.
            It 'on DHIS2 2.40, applies the other filters to enrolments read by UID itself' {
                New-FakeInstance '2.40.12'; Add-FakeCorpus
                Add-FakeEnrollment -Uid 'EnEarly0001' -TrackedEntity 'TePat000001' -EnrolledAt '2024-06-01T10:00:00.000'
                Add-FakeEnrollment -Uid 'EnGone00001' -TrackedEntity 'TePat000002' -Deleted
                Add-FakeEnrollment -Uid 'EnOther0001' -TrackedEntity 'TePat000002' -Program 'PrgOthr0001'
                Add-FakeEnrollment -Uid 'EnTe2000001' -TrackedEntity 'TePat000002'
                $r = Invoke-Read 'Read-EnrolmentInfo' @{
                    EnrollmentId = 'EnPat000001', 'EnPat000003', 'EnEarly0001', 'EnGone00001', 'EnOther0001', 'EnTe2000001'
                    TrackedEntityId = 'TePat000001', 'TePat000003'; OrgUnitCode = 'DEPT_A'; AdmissionDateFrom = [datetime]'2025-01-01'
                }
                $r.Stop | Should -BeNullOrEmpty
                @($r.Output.EnrollmentId) | Should -Be @('EnPat000001')
                (Get-FakeRead 'enrollments')[0].Query['enrollment'] | Should -BeExactly 'EnPat000001;EnPat000003;EnEarly0001;EnGone00001;EnOther0001;EnTe2000001'
            }
            # NEOIPC-COMPAT(dhis2-2.40-tracker-dialect): see Private/TrackerDialect.ps1.
            It 'on DHIS2 2.40, fills EventIds by reading the enrolments again by UID' {
                New-FakeInstance '2.40.12'; Add-FakeCorpus
                Add-FakeEvent -Uid 'EvPat000005' -TrackedEntity 'TePat000001' -Stage 'StgBsi00001'
                $r = Invoke-Read 'Read-EnrolmentInfo' @{ OrgUnitCode = 'DEPT_A' }
                @($r.Output.EnrollmentId) | Should -Be @('EnPat000001', 'EnPat000002')
                $r.Output[0].EventIds | Should -Be @('EvPat000001', 'EvPat000005')
                , $r.Output[1].EventIds | Should -BeOfType [string[]]
                $reads = Get-FakeRead 'enrollments'
                $reads.Count | Should -Be 2
                $reads[1].Query['enrollment'] | Should -BeExactly 'EnPat000001;EnPat000002'
            }
            # NEOIPC-COMPAT(dhis2-2.40-tracker-dialect): see Private/TrackerDialect.ps1.
            It 'on DHIS2 2.40, warns about an enrolment the read again by UID leaves out, whose EventIds stay empty' {
                New-FakeInstance '2.40.12'; Add-FakeCorpus
                [void]$script:Fake.Dropped.Add('EnPat000002')
                $r = Invoke-Read 'Read-EnrolmentInfo' @{ OrgUnitCode = 'DEPT_A' }
                @($r.Output.EnrollmentId) | Should -Be @('EnPat000001', 'EnPat000002')
                $r.Output[1].EventIds.Count | Should -Be 0
                $r.Warnings.Count | Should -Be 1
                "$($r.Warnings[0])" | Should -BeLike "*EnPat000002*EventIds are empty*"
            }
            # NEOIPC-COMPAT(dhis2-2.40-tracker-dialect): see Private/TrackerDialect.ps1.
            It 'on DHIS2 2.40, reads listed enrolments one by one when DHIS2 refuses the read, with an error per refused one' {
                New-FakeInstance '2.40.12'; Add-FakeCorpus
                [void]$script:Fake.Refused.Add('EnPat000002')
                $r = Invoke-Read 'Read-EnrolmentInfo' @{ EnrollmentId = 'EnPat000001', 'EnPat000002' }
                $r.Stop | Should -BeNullOrEmpty
                @($r.Output.EnrollmentId) | Should -Be @('EnPat000001')
                $r.Errors.Count | Should -Be 1
                $r.Errors[0].FullyQualifiedErrorId | Should -BeLike 'NeoIPCTrackerReadEnrollmentRefused*'
                $r.Errors[0].TargetObject | Should -BeExactly 'EnPat000002'
                @((Get-FakeRead 'enrollments') | ForEach-Object { $_.Query['enrollment'] }) | Should -Be @('EnPat000001;EnPat000002', 'EnPat000001', 'EnPat000002')
            }
            # NEOIPC-COMPAT(dhis2-2.40-tracker-dialect): see Private/TrackerDialect.ps1.
            It 'on DHIS2 2.40, ends with an error for an account without data-capture org units, which DHIS2 answers with nothing' {
                New-FakeInstance '2.40.12'; Add-FakeCorpus
                $script:Fake.MeUnits.Clear()
                $r = Invoke-Read 'Read-EnrolmentInfo'
                $r.Output.Count | Should -Be 0
                $r.Stop.FullyQualifiedErrorId | Should -BeLike 'NeoIPCTrackerReadNoCaptureOrgUnits*'
                (Get-FakeRead 'enrollments').Count | Should -Be 0
            }
            # NEOIPC-COMPAT(dhis2-2.40-tracker-dialect): see Private/TrackerDialect.ps1.
            It 'on DHIS2 2.40, ends with that error also before a read by UID, which DHIS2 refuses enrolment by enrolment' {
                New-FakeInstance '2.40.12'; Add-FakeCorpus
                $script:Fake.MeUnits.Clear(); $script:Fake.Refusal = 'NoCapture'
                $r = Invoke-Read 'Read-EnrolmentInfo' @{ EnrollmentId = 'EnPat000001', 'EnPat000002' }
                $r.Output.Count | Should -Be 0
                $r.Errors.Count | Should -Be 0
                $r.Stop.FullyQualifiedErrorId | Should -BeLike 'NeoIPCTrackerReadNoCaptureOrgUnits*'
                (Get-FakeRead 'enrollments').Count | Should -Be 0
            }
            # NEOIPC-COMPAT(dhis2-2.40-tracker-dialect): see Private/TrackerDialect.ps1.
            It 'on DHIS2 2.40, reads by UID for an account with ALL and no data-capture org units, as DHIS2 does' {
                New-FakeInstance '2.40.12'; Add-FakeCorpus
                $script:Fake.MeUnits.Clear(); $script:Fake.Authorities.Add('ALL')
                $r = Invoke-Read 'Read-EnrolmentInfo' @{ EnrollmentId = 'EnPat000001', 'EnPat000002' }
                $r.Stop | Should -BeNullOrEmpty
                @($r.Output.EnrollmentId) | Should -Be @('EnPat000001', 'EnPat000002')
            }
            # NEOIPC-COMPAT(dhis2-2.40-tracker-dialect): see Private/TrackerDialect.ps1.
            It 'on DHIS2 2.40, ends with an error when DHIS2 refuses a read by UID for NEOIPC_CORE''s data, and refuses per enrolment for another program''s' {
                New-FakeInstance '2.40.12'; Add-FakeCorpus
                $script:Fake.Refusal = 'NoProgram'
                $r = Invoke-Read 'Read-EnrolmentInfo' @{ EnrollmentId = 'EnPat000001', 'EnPat000002' }
                $r.Errors.Count | Should -Be 0
                $r.Stop.FullyQualifiedErrorId | Should -BeLike 'NeoIPCTrackerReadNoProgramAccess*'

                New-FakeInstance '2.40.12'; Add-FakeCorpus
                Add-FakeEnrollment -Uid 'EnOther0001' -TrackedEntity 'TePat000001' -Program 'PrgOthr0001'
                [void]$script:Fake.ProgramRefused.Add('EnOther0001')
                $r = Invoke-Read 'Read-EnrolmentInfo' @{ EnrollmentId = 'EnPat000001', 'EnOther0001' }
                $r.Stop | Should -BeNullOrEmpty
                @($r.Output.EnrollmentId) | Should -Be @('EnPat000001')
                $r.Errors.Count | Should -Be 1
                $r.Errors[0].FullyQualifiedErrorId | Should -BeLike 'NeoIPCTrackerReadEnrollmentRefused*'
                $r.Errors[0].TargetObject | Should -BeExactly 'EnOther0001'
            }
            # NEOIPC-COMPAT(dhis2-2.40-tracker-dialect): see Private/TrackerDialect.ps1.
            It 'on DHIS2 2.40, keeps an enrolment read by UID by who owns its patient, whatever org unit it was entered in' {
                New-FakeInstance '2.40.12'; Add-FakeCorpus
                Add-FakePatient -Uid 'TePat000007' -NeoIpcId 'A-7' -OrgUnit 'OuDeptA0001' -Owner 'OuDeptB0001'
                (Invoke-Read 'Read-EnrolmentInfo' @{ EnrollmentId = 'EnPat000007'; OrgUnitCode = 'DEPT_A' }).Output.Count | Should -Be 0
                @((Invoke-Read 'Read-EnrolmentInfo' @{ EnrollmentId = 'EnPat000007'; OrgUnitCode = 'DEPT_B' }).Output.EnrollmentId) | Should -Be @('EnPat000007')
            }
            It 'on DHIS2 <Version>, takes EventIds from the one read' -ForEach @(@{ Version = '2.41.10' }, @{ Version = '2.43.2' }) {
                New-FakeInstance $Version; Add-FakeCorpus
                $r = Invoke-Read 'Read-EnrolmentInfo' @{ OrgUnitCode = 'DEPT_A' }
                $r.Output[0].EventIds | Should -Be @('EvPat000001')
                (Get-FakeRead 'enrollments').Count | Should -Be 1
            }
            It 'returns the enrolment''s fields, its dates as [datetime]' {
                Add-FakeCorpus
                $e = (Invoke-Read 'Read-EnrolmentInfo' @{ EnrollmentId = 'EnPat000001' }).Output[0]
                $e.TrackedEntityId | Should -BeExactly 'TePat000001'
                $e.ProgramId | Should -BeExactly 'PrgCore0001'
                $e.AdmissionDate | Should -Be ([datetime]'2025-03-01T10:00:00')
                $e.AdmissionDate | Should -BeOfType [datetime]
                $e.CreatedBy | Should -BeExactly 'enrolment-creator'
                $e.Notes | Should -Be @('First note')
                $e.FollowUp | Should -BeFalse
            }
            It 'writes an error for a tracked entity DHIS2 <Version> does not know, and reads the others' -ForEach @(
                @{ Version = '2.40.12' }, @{ Version = '2.41.10' }, @{ Version = '2.42.6' }, @{ Version = '2.43.2' }
            ) {
                New-FakeInstance $Version; Add-FakeCorpus
                $r = Invoke-Read 'Read-EnrolmentInfo' @{ TrackedEntityId = 'TeNoSuch001', 'TePat000002' }
                @($r.Output.EnrollmentId) | Should -Be @('EnPat000002')
                $r.Errors.Count | Should -Be 1
                $r.Errors[0].FullyQualifiedErrorId | Should -BeLike 'NeoIPCTrackerReadTrackedEntityNotFound*'
                $r.Errors[0].TargetObject | Should -BeExactly 'TeNoSuch001'
            }
            It 'writes an error for a deleted tracked entity, which DHIS2 <Version> answers with nothing' -ForEach @(@{ Version = '2.40.12' }, @{ Version = '2.41.10' }, @{ Version = '2.43.2' }) {
                New-FakeInstance $Version; Add-FakeCorpus
                Add-FakePatient -Uid 'TeGone00001' -NeoIpcId 'G-1' -Deleted
                $r = Invoke-Read 'Read-EnrolmentInfo' @{ TrackedEntityId = 'TeGone00001', 'TePat000002' }
                @($r.Output.EnrollmentId) | Should -Be @('EnPat000002')
                $r.Errors.Count | Should -Be 1
                $r.Errors[0].TargetObject | Should -BeExactly 'TeGone00001'
            }
            It 'sends one request per tracked entity, and compares several itself when an enrolment list bounds the read' {
                Add-FakeCorpus
                (Invoke-Read 'Read-EnrolmentInfo' @{ TrackedEntityId = 'TePat000001', 'TePat000002' }).Output.EnrollmentId | Should -Be @('EnPat000001', 'EnPat000002')
                @((Get-FakeRead 'enrollments') | ForEach-Object { $_.Query['trackedEntity'] }) | Should -Be @('TePat000001', 'TePat000002')
                $script:Fake.Requests.Clear()
                (Invoke-Read 'Read-EnrolmentInfo' @{ EnrollmentId = 'EnPat000001', 'EnPat000002', 'EnPat000003'; TrackedEntityId = 'TePat000001', 'TePat000003' }).Output.EnrollmentId |
                    Should -Be @('EnPat000001', 'EnPat000003')
                $reads = Get-FakeRead 'enrollments'
                $reads.Count | Should -Be 1
                $reads[0].Query.ContainsKey('trackedEntity') | Should -BeFalse
            }
        }

        Context 'DashboardUrl' {
            It 'opens the enrolment in <App> on DHIS2 <Version>' -ForEach @(
                # NEOIPC-COMPAT(tracker-capture-dashboard-link): see Private/TrackerRead.ps1.
                @{ Version = '2.40.12'; App = 'Tracker Capture'; Url = 'http://dhis2.example.org:8080/dhis-web-tracker-capture/index.html#/dashboard?tei=TePat000001&program=PrgCore0001&ou=OuDeptA0001' }
                @{ Version = '2.41.10'; App = 'Tracker Capture'; Url = 'http://dhis2.example.org:8080/dhis-web-tracker-capture/index.html#/dashboard?tei=TePat000001&program=PrgCore0001&ou=OuDeptA0001' }
                @{ Version = '2.42.0'; App = 'the Capture app'; Url = 'http://dhis2.example.org:8080/apps/capture#/enrollment?enrollmentId=EnPat000001&orgUnitId=OuDeptA0001&programId=PrgCore0001&teiId=TePat000001' }
                @{ Version = '2.42.6'; App = 'the Capture app'; Url = 'http://dhis2.example.org:8080/apps/capture#/enrollment?enrollmentId=EnPat000001&orgUnitId=OuDeptA0001&programId=PrgCore0001&teiId=TePat000001' }
                @{ Version = '2.43.2'; App = 'the Capture app'; Url = 'http://dhis2.example.org:8080/apps/capture#/enrollment?enrollmentId=EnPat000001&orgUnitId=OuDeptA0001&programId=PrgCore0001&teiId=TePat000001' }
            ) {
                New-FakeInstance $Version; Add-FakeCorpus
                $r = Invoke-Read 'Read-EnrolmentInfo' @{ EnrollmentId = 'EnPat000001'; Scheme = 'http'; Port = 8080 }
                $r.Output[0].DashboardUrl | Should -BeExactly $Url
            }
        }

        Context 'a widened read' {
            It 'ends with an error when DHIS2 ignores <Ignored> of <Command>' -ForEach @(
                @{ Command = 'Read-PatientInfo'; Ignored = @('orgUnits', 'orgUnitMode'); Arguments = @{ OrgUnitCode = 'DEPT_A' } }
                @{ Command = 'Read-PatientInfo'; Ignored = @('trackedEntities'); Arguments = @{ TrackedEntityId = 'TePat000001' } }
                @{ Command = 'Read-PatientInfo'; Ignored = @('filter'); Arguments = @{ NeoIpcId = 'A-1' } }
                @{ Command = 'Read-EnrolmentInfo'; Ignored = @('orgUnits', 'orgUnitMode'); Arguments = @{ OrgUnitCode = 'DEPT_A' } }
                @{ Command = 'Read-EnrolmentInfo'; Ignored = @('enrollments'); Arguments = @{ EnrollmentId = 'EnPat000001' } }
                @{ Command = 'Read-EnrolmentInfo'; Ignored = @('trackedEntity'); Arguments = @{ TrackedEntityId = 'TePat000001' } }
                @{ Command = 'Read-EventInfo'; Ignored = @('orgUnit', 'orgUnitMode'); Arguments = @{ OrgUnitCode = 'DEPT_A' } }
                @{ Command = 'Read-EventInfo'; Ignored = @('events'); Arguments = @{ EventId = 'EvPat000001' } }
                @{ Command = 'Read-EventInfo'; Ignored = @('enrollments'); Arguments = @{ EnrollmentId = 'EnPat000001' } }
                @{ Command = 'Read-EventInfo'; Ignored = @('trackedEntity'); Arguments = @{ TrackedEntityId = 'TePat000001' } }
                @{ Command = 'Read-EventInfo'; Ignored = @('programStage'); Arguments = @{ EventType = 'Admission' } }
            ) {
                Add-FakeCorpus
                foreach ($name in $Ignored) { [void]$script:Fake.Ignore.Add($name) }
                $r = Invoke-Read $Command $Arguments
                $r.Output.Count | Should -Be 0
                $r.Stop.FullyQualifiedErrorId | Should -BeLike 'NeoIPCTrackerReadUnexpectedItem*'
                $r.Stop.CategoryInfo.Category | Should -Be 'InvalidResult'
            }
            It 'ends with an error when DHIS2 returns an event of another program' {
                # 2.43 and later refuse an event read without program, so the widening shows on 2.42.
                New-FakeInstance '2.42.6'; Add-FakeCorpus
                Add-FakeEvent -Uid 'EvOther0001' -TrackedEntity 'TePat000001' -Program 'PrgOthr0001'
                [void]$script:Fake.Ignore.Add('program')
                $r = Invoke-Read 'Read-EventInfo' @{ TrackedEntityId = 'TePat000001' }
                $r.Stop.Exception.Message | Should -BeLike "*'EvOther0001'*another program*"
            }
            It 'ends with an error when DHIS2 returns an enrolment of another program' {
                New-FakeInstance '2.42.6'; Add-FakeCorpus
                Add-FakeEnrollment -Uid 'EnOther0001' -TrackedEntity 'TePat000001' -Program 'PrgOthr0001'
                [void]$script:Fake.Ignore.Add('program')
                $r = Invoke-Read 'Read-EnrolmentInfo' @{ OrgUnitCode = 'DEPT_A' }
                $r.Output.Count | Should -Be 0
                $r.Stop.Exception.Message | Should -BeLike "*'EnOther0001'*another program than NEOIPC_CORE*"
            }
            It 'ends with an error when DHIS2 returns a tracked entity that is no patient of NEOIPC_CORE' {
                New-FakeInstance '2.42.6'; Add-FakeCorpus
                # A tracked entity registered in DEPT_A and enrolled in another program only, which a read without program
                # selects by the org unit owning it in that program.
                $script:Fake.TrackedEntities['TeOther0001'] = [ordered]@{
                    trackedEntity = 'TeOther0001'; orgUnit = 'OuDeptA0001'; createdAt = '2025-01-01T08:00:00.000'; updatedAt = '2025-01-02T09:00:00.000'
                    attributes = @(); programOwners = @([ordered]@{ orgUnit = 'OuDeptA0001'; program = 'PrgOthr0001'; trackedEntity = 'TeOther0001' }); deleted = $false
                }
                Add-FakeEnrollment -Uid 'EnOther0001' -TrackedEntity 'TeOther0001' -Program 'PrgOthr0001'
                [void]$script:Fake.Ignore.Add('program')
                $r = Invoke-Read 'Read-PatientInfo' @{ OrgUnitCode = 'DEPT_A' }
                $r.Output.Count | Should -Be 0
                $r.Stop.Exception.Message | Should -BeLike "*'TeOther0001'*no patient of NEOIPC_CORE*"
            }
            It 'ends with an error when the read of the given tracked entities returns one it did not ask for' {
                Add-FakeCorpus
                [void]$script:Fake.Ignore.Add('trackedEntities')
                $r = Invoke-Read 'Read-EventInfo' @{ TrackedEntityId = 'TePat000001' }
                $r.Output.Count | Should -Be 0
                $r.Stop.FullyQualifiedErrorId | Should -BeLike 'NeoIPCTrackerReadUnexpectedItem*'
                $r.Stop.Exception.Message | Should -BeLike '*trackedEntities read*did not ask for*'
                (Get-FakeRead 'events').Count | Should -Be 0
            }
            It 'takes an event entered elsewhere whose patient the selected org unit owns, reading the owner to know' {
                Add-FakeCorpus
                Add-FakePatient -Uid 'TePat000005' -NeoIpcId 'A-5' -OrgUnit 'OuDeptB0001' -Owner 'OuDeptA0001'
                Add-FakeEvent -Uid 'EvPat000005' -TrackedEntity 'TePat000005'
                $r = Invoke-Read 'Read-EventInfo' @{ OrgUnitCode = 'DEPT_A' }
                $r.Stop | Should -BeNullOrEmpty
                @($r.Output.EventId) | Should -Be @('EvPat000001', 'EvPat000002', 'EvPat000005')
                (Get-FakeRead 'trackedEntities')[0].Query['trackedEntities'] | Should -BeExactly 'TePat000005'
            }
        }

        Context 'DHIS2''s refusals' {
            It '<Command> on DHIS2 <Version> says that the account has no data-capture org units' -ForEach @(
                foreach ($version in '2.40.12', '2.41.10', '2.42.6', '2.43.2') {
                    foreach ($command in 'Read-PatientInfo', 'Read-EnrolmentInfo', 'Read-EventInfo') { @{ Version = $version; Command = $command } }
                }
            ) {
                New-FakeInstance $Version; Add-FakeCorpus
                $script:Fake.Refusal = 'NoCapture'
                $r = Invoke-Read $Command
                $r.Stop.FullyQualifiedErrorId | Should -BeLike 'NeoIPCTrackerReadNoCaptureOrgUnits*'
                $r.Stop.CategoryInfo.Category | Should -Be 'PermissionDenied'
                $r.Stop.Exception.Message | Should -BeLike '*no data-capture org units*'
            }
            It '<Command> on DHIS2 <Version> says that the account may not read the program''s records' -ForEach @(
                foreach ($version in '2.40.12', '2.41.10', '2.42.6', '2.43.2') {
                    foreach ($command in 'Read-PatientInfo', 'Read-EnrolmentInfo', 'Read-EventInfo') { @{ Version = $version; Command = $command } }
                }
            ) {
                New-FakeInstance $Version; Add-FakeCorpus
                $script:Fake.Refusal = 'NoProgram'
                $r = Invoke-Read $Command
                $r.Stop.FullyQualifiedErrorId | Should -BeLike 'NeoIPCTrackerReadNoProgramAccess*'
                $r.Stop.Exception.Message | Should -BeLike '*may not read*'
            }
            It 'passes any other failure on unchanged' {
                Add-FakeCorpus
                [void]$script:Fake.Ignore.Add('program')
                $r = Invoke-Read 'Read-EventInfo' @{ TrackedEntityId = 'TePat000001' }
                $r.Stop.Exception | Should -BeOfType [System.Net.Http.HttpRequestException]
                $r.Stop.Exception.Message | Should -BeLike '*HTTP 400*Bad Request*'
            }
            It '<Command> ends with an error when the instance holds no program NEOIPC_CORE the account can read' -ForEach @(
                @{ Command = 'Read-PatientInfo' }, @{ Command = 'Read-EnrolmentInfo' }, @{ Command = 'Read-EventInfo' }
            ) {
                $script:Fake.HideProgram = $true
                $r = Invoke-Read $Command
                $r.Stop.FullyQualifiedErrorId | Should -BeLike 'NeoIPCTrackerReadNoProgram,*'
                $script:Fake.Requests.Path | Should -Not -Contain 'api/tracker/trackedEntities'
            }
        }

        Context 'attributes the account cannot read' {
            It 'warns, naming them, when DHIS2 <Version> leaves out their values' -ForEach @(@{ Version = '2.43.2' }) {
                New-FakeInstance $Version; Add-FakeCorpus
                [void]$script:Fake.Unreadable.Add('NEOIPC_TEA_SEX')
                $r = Invoke-Read 'Read-PatientInfo' @{ TrackedEntityId = 'TePat000001' }
                $r.Output[0].Sex | Should -BeNullOrEmpty
                $r.Warnings.Count | Should -Be 1
                "$($r.Warnings[0])" | Should -BeLike '*NEOIPC_TEA_SEX*2.43.2*'
            }
            It 'takes the values by their code and does not warn when DHIS2 <Version> returns them' -ForEach @(@{ Version = '2.42.6' }, @{ Version = '2.43.0' }) {
                New-FakeInstance $Version; Add-FakeCorpus
                [void]$script:Fake.Unreadable.Add('NEOIPC_TEA_SEX')
                $r = Invoke-Read 'Read-PatientInfo' @{ TrackedEntityId = 'TePat000001' }
                $r.Output[0].Sex | Should -BeExactly '1'
                $r.Warnings.Count | Should -Be 0
            }
            It 'does not warn when the account reads every attribute' {
                Add-FakeCorpus
                (Invoke-Read 'Read-PatientInfo' @{ TrackedEntityId = 'TePat000002' }).Warnings.Count | Should -Be 0
            }
        }

        Context 'long lists' {
            It '<Command> sends 150 UIDs in two chunks of 100 and 50, joined with "<Separator>", on DHIS2 <Version>' -ForEach @(
                @{ Command = 'Read-PatientInfo'; Parameter = 'TrackedEntityId'; Resource = 'trackedEntities'; Name = 'trackedEntity'; Separator = ';'; Version = '2.40.12' }
                @{ Command = 'Read-PatientInfo'; Parameter = 'TrackedEntityId'; Resource = 'trackedEntities'; Name = 'trackedEntities'; Separator = ','; Version = '2.43.2' }
                @{ Command = 'Read-EnrolmentInfo'; Parameter = 'EnrollmentId'; Resource = 'enrollments'; Name = 'enrollment'; Separator = ';'; Version = '2.40.12' }
                @{ Command = 'Read-EnrolmentInfo'; Parameter = 'EnrollmentId'; Resource = 'enrollments'; Name = 'enrollments'; Separator = ','; Version = '2.43.2' }
                @{ Command = 'Read-EventInfo'; Parameter = 'EventId'; Resource = 'events'; Name = 'event'; Separator = ';'; Version = '2.40.12' }
                @{ Command = 'Read-EventInfo'; Parameter = 'EventId'; Resource = 'events'; Name = 'events'; Separator = ','; Version = '2.43.2' }
            ) {
                New-FakeInstance $Version
                $ids = [string[]]@(1..150 | ForEach-Object { 'Uid{0:D8}' -f $_ })
                # Patients that exist, since Read-PatientInfo reads the UIDs its read did not return again to name them.
                if ($Command -eq 'Read-PatientInfo') { foreach ($id in $ids) { Add-FakePatient -Uid $id } }
                $r = Invoke-Read $Command @{ $Parameter = $ids }
                $r.Stop | Should -BeNullOrEmpty
                $reads = Get-FakeRead $Resource
                $reads.Count | Should -Be 2
                ($reads[0].Query[$Name] -split [regex]::Escape($Separator)).Count | Should -Be 100
                ($reads[1].Query[$Name] -split [regex]::Escape($Separator)).Count | Should -Be 50
            }
        }

        Context 'help' {
            It '<Command> documents every parameter and has help the parser finds' -ForEach @(
                @{ Command = 'Read-PatientInfo' }, @{ Command = 'Read-EnrolmentInfo' }, @{ Command = 'Read-EventInfo' }
            ) {
                $help = Get-Help $Command -Full
                $names = @((Get-Command $Command).Parameters.Keys | Where-Object { $_ -notin [System.Management.Automation.PSCmdlet]::CommonParameters })
                $names.Count | Should -BeGreaterThan 8
                foreach ($name in $names) {
                    ($help.parameters.parameter | Where-Object name -EQ $name).description.Text | Should -Not -BeNullOrEmpty -Because "-$name needs help"
                }
                @($help.examples.example).Count | Should -BeGreaterOrEqual 2
                $file = Join-Path $PSScriptRoot '..' 'Public' 'Tracker.ps1'
                $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$null)
                $function = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Command }, $true)
                $function.GetHelpContent() | Should -Not -BeNullOrEmpty
            }
        }
    }
}
