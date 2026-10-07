#Requires -Version 7.6

<#
.SYNOPSIS
    Pester tests for Remove-NeoIPCPatient and its planning helpers.

.DESCRIPTION
    Covers Private/PatientRemoval.ps1 (the selection, the refusal rules, the reading of DHIS2's answers and of the
    read-back, all free of I/O), the tracked-entity read and the filter escaping in Private/TrackerDialect.ps1, and
    Public/PatientRemoval.ps1, which drives DHIS2.

    The cmdlet tests run against a small in-memory DHIS2 that models what the source of 2.40.12, 2.41.10, 2.42.6 and
    2.43.2 says of the tracked-entity read: the parameter names each version reads (2.40: orgUnit, ouMode and
    trackedEntity joined with ';', the list under 'instances'; 2.41: those and orgUnits, orgUnitMode and
    trackedEntities joined with ',', answering 400 to both forms of one; 2.42 and later: only the new names, ignoring
    the old ones, which widens the read); the attribute filter's unescaping, which before 2.42 puts escaped slashes
    back in hash order, and its comparison ignoring case; the org-unit match, per program of the type, against the
    program owner or, where that program has no owner for the entity, its registration org unit; and includeDeleted,
    without which soft-deleted entities and children stay hidden. A DELETE import soft-deletes the entity with its
    enrolments and events and removes its attribute values; a VALIDATE import reports E1063, E1114 or a refusal per
    UID and deletes nothing; and the single read answers 404 for a deleted entity. Each commit can be told to answer
    the way DHIS2 does when it refuses, vetoes (2.40: 409 with an Exception message and no stats; 2.41: HTTP 500
    without a report), lies, names UIDs it was not sent, queues a job, denies access, deletes in part (2.42 and later:
    409 without a report, keeping what it deleted), or loses its answer. The caller it models reads every program of the type and captures in both departments; DHIS2's sharing and
    ownership checks are not modelled. Like the real helpers, every mock but the status read sends and returns nothing
    under an inherited -WhatIf, so a read that forgets -WhatIf:$false fails the preview tests.

    Self-contained: no live instance is needed and no API call is made.

.EXAMPLE
    Invoke-Pester -Path scripts/modules/NeoIPC-Tools/Tests/PatientRemoval.Tests.ps1
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..') -Force

InModuleScope 'NeoIPC-Tools' {

    BeforeAll {
        $script:Auth = @{ AuthType = 'Basic' }
        $script:Host1 = 'dhis2.example.org'

        function New-FakeInstance {
            param([string]$Version = '2.43.2')
            $ordinal = [System.StringComparer]::Ordinal
            $script:Fake = [pscustomobject]@{
                Version        = $Version
                ProgramId      = 'PrgCore0001'
                OtherProgramId = 'PrgOthr0001'
                TypeId         = 'TetPatnt001'
                TypeCode       = 'NEOIPC_PATIENT'
                AttributeId    = 'AttPatId001'
                OrgUnits       = [System.Collections.Generic.List[object]]::new()
                Capture        = [System.Collections.Generic.HashSet[string]]::new([string[]]@('OuDeptA0001', 'OuDeptB0001'), $ordinal)
                # The programs of the patient type the caller can read, which the org-unit match runs over.
                TypePrograms   = [System.Collections.Generic.List[string]]::new([string[]]@('PrgCore0001', 'PrgOthr0001'))
                Patients       = [System.Collections.Generic.Dictionary[string, object]]::new($ordinal)
                Behaviour      = [System.Collections.Generic.Dictionary[string, string]]::new($ordinal)
                DryRunCode     = [System.Collections.Generic.Dictionary[string, string]]::new($ordinal)
                SingleRead     = [System.Collections.Generic.Dictionary[string, int]]::new($ordinal)
                Requests       = [System.Collections.Generic.List[object]]::new()
                IgnoreSelector = $false
                IgnoreType     = $false
                ListKey        = $null
                DropField      = $null
                DryRun         = $null
                ThrowRead      = $false
            }
            $script:Fake.OrgUnits.Add(@{ id = 'OuDeptA0001'; code = 'DEPT_A'; groups = @('NEO_DEPARTMENT') })
            $script:Fake.OrgUnits.Add(@{ id = 'OuDeptB0001'; code = 'DEPT_B'; groups = @('NEO_DEPARTMENT') })
            $script:Fake.OrgUnits.Add(@{ id = 'OuHospX0001'; code = 'HOSP_X'; groups = @('HOSPITAL') })
        }

        # A patient with -Enrollments enrolments of -Events events each. Children's ids derive from the patient's UID.
        function Add-FakePatient {
            param(
                [Parameter(Mandatory)][string]$Uid,
                [string]$NeoIpcId,
                [string]$OrgUnit = 'OuDeptA0001',
                [int]$Enrollments = 1,
                [int]$Events = 1,
                [string]$Program,
                [string]$OwnerOrgUnit,
                [string]$EnrollmentOrgUnit,
                [string]$EventOrgUnit,
                [string]$ExtraOwnerProgram,
                [string]$Type,
                [switch]$Deleted
            )
            $prog = if ($Program) { $Program } else { $script:Fake.ProgramId }
            $ens = for ($i = 1; $i -le $Enrollments; $i++) {
                $evs = for ($j = 1; $j -le $Events; $j++) {
                    [ordered]@{ event = ('Ev' + $Uid.Substring($Uid.Length - 7) + $i + $j); programStage = 'StgAdmn0001'
                        orgUnit = $(if ($EventOrgUnit) { $EventOrgUnit } else { $OrgUnit }); status = 'COMPLETED'; deleted = [bool]$Deleted }
                }
                [ordered]@{ enrollment = ('En' + $Uid.Substring($Uid.Length - 8) + $i); program = $prog; orgUnit = $(if ($EnrollmentOrgUnit) { $EnrollmentOrgUnit } else { $OrgUnit })
                    status = 'COMPLETED'; deleted = [bool]$Deleted; events = @($evs) }
            }
            $owners = @([ordered]@{ program = $prog; orgUnit = $(if ($OwnerOrgUnit) { $OwnerOrgUnit } else { $OrgUnit }) })
            if ($ExtraOwnerProgram) { $owners += [ordered]@{ program = $ExtraOwnerProgram; orgUnit = $OrgUnit } }
            $script:Fake.Patients[$Uid] = [ordered]@{
                trackedEntity = $Uid; trackedEntityType = $(if ($Type) { $Type } else { $script:Fake.TypeId }); orgUnit = $OrgUnit; deleted = [bool]$Deleted
                attributes    = @(if ($NeoIpcId -and -not $Deleted) { [ordered]@{ attribute = $script:Fake.AttributeId; code = 'NEOIPC_PATIENT_ID'; value = $NeoIpcId } })
                programOwners = $owners
                enrollments   = @($ens)
            }
        }

        # A DELETE import's effect: the entity, its live enrolments and their live events deleted, its attributes gone.
        function Remove-FakePatient([string]$Uid, [switch]$KeepFirstEvent) {
            $p = $script:Fake.Patients[$Uid]
            $p['deleted'] = $true
            $p['attributes'] = @()
            $first = $true
            foreach ($en in $p['enrollments']) {
                $en['deleted'] = $true
                foreach ($ev in $en['events']) {
                    if ($KeepFirstEvent -and $first) { $first = $false; continue }
                    $ev['deleted'] = $true
                }
            }
        }

        # What 2.42 and later keep of a commit that fails on a checked exception (a record gone between DHIS2's preheat
        # and its commit): the deletions made before it, here the first live event.
        function Remove-FakeEvent([string]$Uid) {
            $first = @(@($script:Fake.Patients[$Uid]['enrollments']) | ForEach-Object { $_['events'] } | Where-Object { -not $_['deleted'] })[0]
            $first['deleted'] = $true
        }

        function Get-FakeVersion { ConvertTo-NeoIPCDhis2Version -Text $script:Fake.Version }

        # An attribute filter as DHIS2 reads it. Before 2.42 (RequestParamUtils / RequestParamsValidator.filterList)
        # every '//' found scanning left to right is taken out, the scan then stepping past the next character; one '/'
        # goes back per pair taken out, at its recorded position, in the iteration order of the java.util.HashMap that
        # recorded the positions: by the position masked by the table size, then by insertion. The table starts at 16
        # and doubles when it would hold more than three quarters of its size, and, while it is below 64, when a
        # position lands in a bucket that already holds eight; the tree such a bucket turns into from 64 on is not
        # modelled. The rest splits at every ':' that is not escaped, which must leave one operator and one value
        # (DHIS2 also reads two operator-value pairs, which no test sends), and '/,' and '/:' lose their slash. From
        # 2.42 (FilterParser) '//', '/,' and '/:' lose a slash, in that order.
        function ConvertFrom-FakeFilter([string]$Filter) {
            $attribute, $rest = $Filter -split ':', 2
            if ((Get-FakeVersion) -ge [version]'2.42') {
                return @{ Attribute = $attribute; Value = ($rest -split ':', 2)[1].Replace('//', '/').Replace('/,', ',').Replace('/:', ':') }
            }
            $sb = [System.Text.StringBuilder]::new($Filter)
            $keys = [System.Collections.Generic.List[int]]::new()
            for ($i = 0; $i -lt $sb.Length - 1; $i++) {
                if ($sb[$i] -eq [char]'/' -and $sb[$i + 1] -eq [char]'/') { [void]$sb.Remove($i, 2); $keys.Add($i) }
            }
            $table = 16
            for ($n = 0; $n -lt $keys.Count; $n++) {
                $bucket = $keys[$n] -band ($table - 1)
                $held = 0
                for ($m = 0; $m -lt $n; $m++) { if (($keys[$m] -band ($table - 1)) -eq $bucket) { $held++ } }
                if ($held -ge 8) {
                    if ($table -ge 64) { throw 'The fake does not model the tree a java.util.HashMap bucket turns into.' }
                    $table *= 2
                }
                if ($n + 1 -gt 0.75 * $table) { $table *= 2 }
            }
            $pad = 0
            foreach ($k in @($keys | Sort-Object { $_ -band ($table - 1) }, { $_ })) { [void]$sb.Insert($k + $pad, '/'); $pad++ }
            $restored = $sb.ToString()
            $parts = [regex]::Split($restored.Substring($restored.IndexOf(':') + 1), '(?<!/):')
            if ($parts.Count -ne 2) { throw "HTTP 400: Query item or filter is invalid: $restored" }
            @{ Attribute = $attribute; Value = $parts[1].Replace('/,', ',').Replace('/:', ':') }
        }

        # Whether a tracked entity lies in one of the org units, the way a read by type matches it: for some program of
        # the type, the program's owner of the entity, or its registration org unit where that program has no owner.
        function Test-FakeOrgUnitMatch($Te, [string[]]$OrgUnits) {
            foreach ($p in $script:Fake.TypePrograms) {
                $owner = @(@($Te['programOwners']) | Where-Object { [string]$_['program'] -ceq $p })
                $at = if ($owner.Count -gt 0) { [string]$owner[0]['orgUnit'] } else { [string]$Te['orgUnit'] }
                if ($OrgUnits -ccontains $at) { return $true }
            }
            $false
        }

        function Get-FakeView($Te, [bool]$IncludeDeleted) {
            $copy = $Te | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
            if (-not $IncludeDeleted) {
                $copy['enrollments'] = @(@($copy['enrollments']) | Where-Object { $_ -and -not $_['deleted'] } | ForEach-Object {
                        $_['events'] = @(@($_['events']) | Where-Object { $_ -and -not $_['deleted'] }); $_ })
            }
            if ($script:Fake.DropField) { $copy.Remove($script:Fake.DropField) }
            $copy
        }

        function Get-FakeTrackedEntityList($Query) {
            if ($script:Fake.ThrowRead) { throw "Failed to fetch 'api/tracker/trackedEntities' from DHIS2: 503 (Service Unavailable)" }
            $version = Get-FakeVersion
            # The names each version reads: 2.40 the old ones, 2.41 both, 2.42 and later the new ones.
            $forms = @(
                if ($version -lt [version]'2.42') { @{ OrgUnit = 'orgUnit'; Mode = 'ouMode'; Ids = 'trackedEntity'; Separator = ';' } }
                if ($version -ge [version]'2.41') { @{ OrgUnit = 'orgUnits'; Mode = 'orgUnitMode'; Ids = 'trackedEntities'; Separator = ',' } }
            )
            $given = @{}
            foreach ($name in 'OrgUnit', 'Mode', 'Ids') {
                $present = @($forms | Where-Object { $Query.ContainsKey($_[$name]) })
                if ($present.Count -gt 1) { throw "HTTP 400: both $($present[0][$name]) and $($present[1][$name]) were given." }
                if ($present.Count -eq 1) { $given[$name] = [string]$Query[$present[0][$name]]; $given["$name.Separator"] = $present[0].Separator }
            }
            $includeDeleted = $Query['includeDeleted'] -eq 'true'
            $type = [string]$Query['trackedEntityType']
            $rows = @($script:Fake.Patients.Values | Where-Object { ($script:Fake.IgnoreType -or [string]$_['trackedEntityType'] -ceq $type) -and ($includeDeleted -or -not $_['deleted']) })
            if (-not $script:Fake.IgnoreSelector) {
                if ($given.ContainsKey('Ids')) {
                    $ids = $given['Ids'] -split [regex]::Escape($given['Ids.Separator'])
                    $rows = @($rows | Where-Object { $ids -ccontains [string]$_['trackedEntity'] })
                }
                $scope = if ($given.ContainsKey('OrgUnit')) { @($given['OrgUnit']) } elseif ($given['Mode'] -eq 'CAPTURE') { @($script:Fake.Capture) } else { $null }
                if ($scope) { $rows = @($rows | Where-Object { Test-FakeOrgUnitMatch $_ $scope }) }
                if ($Query.ContainsKey('filter')) {
                    $f = ConvertFrom-FakeFilter ([string]$Query['filter'])
                    $rows = @($rows | Where-Object {
                            @($_['attributes'] | Where-Object { [string]$_['attribute'] -ceq $f.Attribute -and [string]::Equals([string]$_['value'], $f.Value, [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
                        })
                }
            }
            $key = if ($script:Fake.ListKey) { $script:Fake.ListKey } elseif ($version -lt [version]'2.41') { 'instances' } else { 'trackedEntities' }
            @{ $key = @($rows | ForEach-Object { Get-FakeView $_ $includeDeleted }) }
        }

        function New-FakeReport([object[]]$Errors = @(), [string[]]$Deleted = @(), [switch]$Validate) {
            $status = if (@($Errors).Count -gt 0) { 'ERROR' } else { 'OK' }
            $body = [ordered]@{
                status           = $status
                validationReport = [ordered]@{ errorReports = @($Errors | ForEach-Object { [ordered]@{ message = $_.message; errorCode = $_.errorCode; trackerType = 'TRACKED_ENTITY'; uid = $_.uid } }); warningReports = @() }
                stats            = [ordered]@{ created = 0; updated = 0; deleted = @($Deleted).Count; ignored = @($Errors).Count; total = @($Deleted).Count + @($Errors).Count }
            }
            if ($status -eq 'OK') {
                $map = if ($Validate) { [ordered]@{} } else {
                    [ordered]@{ TRACKED_ENTITY = [ordered]@{ trackerType = 'TRACKED_ENTITY'; objectReports = @($Deleted | ForEach-Object { [ordered]@{ trackerType = 'TRACKED_ENTITY'; uid = $_; errorReports = @() } }) } }
                }
                $body['bundleReport'] = [ordered]@{ typeReportMap = $map }
            }
            [pscustomobject]@{ StatusCode = $(if ($status -eq 'ERROR') { 409 } else { 200 }); Body = ($body | ConvertTo-Json -Depth 100 | ConvertFrom-Json) }
        }
        function New-FakeWebMessage([int]$Code, [string]$Message, $Response = $null) {
            $body = [ordered]@{ httpStatus = 'x'; httpStatusCode = $Code; status = $(if ($Code -lt 400) { 'OK' } else { 'ERROR' }); message = $Message }
            if ($Response) { $body['response'] = $Response }
            [pscustomobject]@{ StatusCode = $Code; Body = ($body | ConvertTo-Json -Depth 100 | ConvertFrom-Json) }
        }
        # 2.40.12's answer to an import that throws (ImportReport.withError): an empty validation report, the timings
        # reportMode=FULL asks for and the message, but neither stats nor a bundle report.
        function New-Fake240ErrorReport([string]$Message) {
            $body = [ordered]@{ status = 'ERROR'; validationReport = [ordered]@{ errorReports = @(); warningReports = @() }
                timingsStats = [ordered]@{ timers = [ordered]@{ preheat = '0.010 sec.'; totalImport = '0.020 sec.' } }; message = $Message }
            [pscustomobject]@{ StatusCode = 409; Body = ($body | ConvertTo-Json -Depth 100 | ConvertFrom-Json) }
        }

        function Set-FakeMock {
            Mock Invoke-WebRequest { throw 'A test made an HTTP call.' }
            Mock Invoke-RestMethod { throw 'A test made an HTTP call.' }
            Mock Invoke-NeoIPCDhis2Get {
                if ($WhatIfPreference) { return }
                $script:Fake.Requests.Add(@{ Kind = 'GET'; Path = $Path; Query = $QueryParameters; Filter = $Filter; Fields = $Fields; Hostname = $Hostname })
                switch ($Path) {
                    'api/system/info' { return @{ version = $script:Fake.Version } }
                    'api/metadata' {
                        $r = @{}
                        if ($QueryParameters['programs:filter'] -eq 'code:eq:NEOIPC_CORE') {
                            $r['programs'] = @(@{ id = $script:Fake.ProgramId; code = 'NEOIPC_CORE'; trackedEntityType = @{ id = $script:Fake.TypeId; code = $script:Fake.TypeCode } })
                        }
                        if ($QueryParameters['trackedEntityAttributes:filter'] -eq 'code:eq:NEOIPC_PATIENT_ID') {
                            $r['trackedEntityAttributes'] = @(@{ id = $script:Fake.AttributeId; code = 'NEOIPC_PATIENT_ID' })
                        }
                        return $r
                    }
                    'api/organisationUnits' {
                        $f = [string]$Filter[0]
                        # Looser than DHIS2 on purpose: a code differing in case comes back, and the cmdlet must not take it.
                        $rows = if ($f.StartsWith('code:eq:')) { $code = $f.Substring(8); @($script:Fake.OrgUnits | Where-Object { $_.code -eq $code }) }
                        else { $ids = $f.Substring(7).TrimEnd(']') -split ','; @($script:Fake.OrgUnits | Where-Object { $ids -ccontains $_.id }) }
                        return @{ organisationUnits = @($rows | ForEach-Object { @{ id = $_.id; code = $_.code; organisationUnitGroups = @($_.groups | ForEach-Object { @{ code = $_ } }) } }) }
                    }
                    'api/tracker/trackedEntities' { return Get-FakeTrackedEntityList $QueryParameters }
                }
                throw "Unexpected GET $Path"
            }
            Mock Get-NeoIPCDhis2StatusCode {
                $script:Fake.Requests.Add(@{ Kind = 'STATUS'; Path = $Path; Hostname = $Hostname })
                $uid = ($Path -split '/')[-1]
                if ($script:Fake.SingleRead.ContainsKey($uid)) { return $script:Fake.SingleRead[$uid] }
                if ($script:Fake.Patients.ContainsKey($uid) -and -not $script:Fake.Patients[$uid]['deleted']) { 200 } else { 404 }
            }
            Mock Invoke-NeoIPCDhis2Post {
                if ($WhatIfPreference) { return }
                $payload = $Body | ConvertFrom-Json -AsHashtable
                $uids = @(@($payload['trackedEntities']) | ForEach-Object { [string]$_['trackedEntity'] })
                $mode = [string]$QueryParameters['importMode']
                $script:Fake.Requests.Add(@{ Kind = 'POST'; Path = $Path; Mode = $mode; Query = $QueryParameters; Uids = $uids; Payload = $payload; Hostname = $Hostname })
                if ($mode -eq 'VALIDATE') {
                    switch ($script:Fake.DryRun) {
                        'NoReport' { return [pscustomobject]@{ StatusCode = 500; Body = '<html><body>Internal error</body></html>' } }
                        'Foreign' { return New-FakeReport -Errors @(@{ uid = 'TeForeign01'; errorCode = 'E1063'; message = 'TrackedEntity: TeForeign01, does not exist.' }) -Validate }
                        'ErrorNoCodes' { return New-Fake240ErrorReport 'Exception:could not execute statement' }
                    }
                    $errors = foreach ($uid in $uids) {
                        if (-not $script:Fake.Patients.ContainsKey($uid)) { @{ uid = $uid; errorCode = 'E1063'; message = "TrackedEntity: $uid, does not exist." } }
                        elseif ($script:Fake.Patients[$uid]['deleted']) { @{ uid = $uid; errorCode = 'E1114'; message = "TrackedEntity: $uid is already deleted." } }
                        elseif ($script:Fake.DryRunCode.ContainsKey($uid)) { @{ uid = $uid; errorCode = $script:Fake.DryRunCode[$uid]; message = "refused $uid" } }
                    }
                    return New-FakeReport -Errors @($errors) -Validate
                }
                $uid = $uids[0]
                $how = if ($script:Fake.Behaviour.ContainsKey($uid)) { $script:Fake.Behaviour[$uid] } else { 'Delete' }
                if ($how.StartsWith('Refuse:')) { return New-FakeReport -Errors @(@{ uid = $uid; errorCode = $how.Substring(7); message = "refused $uid" }) }
                switch ($how) {
                    'Delete' { Remove-FakePatient $uid; return New-FakeReport -Deleted @($uid) }
                    'Partial' { Remove-FakePatient $uid -KeepFirstEvent; return New-FakeReport -Deleted @($uid) }
                    'Lie' { return New-FakeReport -Deleted @($uid) }
                    'Foreign' { Remove-FakePatient $uid; return New-FakeReport -Deleted @($uid, 'TeForeign01') }
                    'RefuseForeign' { return New-FakeReport -Errors @(@{ uid = $uid; errorCode = 'E1000'; message = "refused $uid" }, @{ uid = 'TeForeign01'; errorCode = 'E1063'; message = 'TrackedEntity: TeForeign01, does not exist.' }) }
                    'Veto240' { return New-Fake240ErrorReport 'Exception:Object could not be deleted because it is associated with another object: ProgramNotificationInstance' }
                    'Veto241' { return New-FakeWebMessage 500 'Cannot invoke "getStats()" because "persistenceReport" is null' }
                    # JobProgress's post-condition turns the checked exception into a CancellationException, which
                    # CrudControllerAdvice answers as a conflict; the job's process has no description.
                    'PartialFail' { Remove-FakeEvent $uid; return New-FakeWebMessage 409 "Non-null post-condition failed after: null`n  => Commit Transaction" }
                    'AccessDenied' { return New-FakeWebMessage 403 'Access is denied' }
                    'Async' { return New-FakeWebMessage 200 'Tracker job added' @{ responseType = 'TrackerJob'; id = 'JobId000001' } }
                    'AsyncDeleted' { Remove-FakePatient $uid; return New-FakeWebMessage 200 'Tracker job added' @{ responseType = 'TrackerJob'; id = 'JobId000001' } }
                    'Gateway' { return [pscustomobject]@{ StatusCode = 504; Body = '<html><body>Gateway Timeout</body></html>' } }
                    'Transport' { throw 'The SSL connection could not be established.' }
                    'DeleteLost' { Remove-FakePatient $uid; throw 'The response ended prematurely.' }
                }
                throw "Unknown behaviour $how"
            }
        }

        function Get-FakeRequest([string]$Kind, [string]$Mode, [string]$Path) {
            @($script:Fake.Requests | Where-Object { $_.Kind -eq $Kind -and (-not $Mode -or $_.Mode -eq $Mode) -and (-not $Path -or $_.Path -eq $Path) })
        }

        # A patient-ID lookup's query, the first one sent.
        function Get-LookupQuery { @(Get-FakeRequest 'GET' -Path 'api/tracker/trackedEntities' | Where-Object { $_.Query.ContainsKey('filter') } | Select-Object -First 1).Query }

        # A run's results, errors and warnings. A run that ends with a terminating error rethrows it, unless -AllowStop
        # asks for it in Stop beside the results emitted before it.
        function Invoke-Removal([hashtable]$Arguments, [switch]$AllowStop) {
            $splat = @{ Auth = $script:Auth; Hostname = $script:Host1; Confirm = $false; ErrorAction = 'SilentlyContinue'; ErrorVariable = 'removalErrors'
                WarningAction = 'SilentlyContinue'; WarningVariable = 'removalWarnings'; OutVariable = 'removalOut' }
            foreach ($k in $Arguments.Keys) { $splat[$k] = $Arguments[$k] }
            $stop = $null
            try { $null = Remove-NeoIPCPatient @splat 6>$null } catch { $stop = $_ }
            if ($stop -and -not $AllowStop) { throw $stop }
            [pscustomobject]@{ Results = @($removalOut); Errors = @($removalErrors | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }); Warnings = @($removalWarnings); Stop = $stop }
        }
    }

    Describe 'ConvertTo-NeoIPCTrackerFilterValue and Test-NeoIPCTrackerFilterValue' {
        It 'doubles the escape character first, then escapes the separators it guards' {
            ConvertTo-NeoIPCTrackerFilterValue -Value 'a/b:c,d' | Should -BeExactly 'a//b/:c/,d'
        }
        It 'lets DHIS2 <Version> look up <Value>: <Expected>' -ForEach @(
            # NEOIPC-COMPAT(dhis2-pre-2.42-filter-escape): see Private/TrackerDialect.ps1.
            @{ Version = '2.40.12'; Value = 'x/2:a,b'; Expected = $true }
            @{ Version = '2.40.12'; Value = 'A//1'; Expected = $false }
            @{ Version = '2.41.10'; Value = 'DE-BER-01/2024-0000001/b'; Expected = $false }
            @{ Version = '2.42.6'; Value = 'DE-BER-01/2024-0000001/b'; Expected = $true }
            @{ Version = '2.43.2'; Value = 'A//1'; Expected = $true }
        ) {
            Test-NeoIPCTrackerFilterValue -Dialect (Get-NeoIPCTrackerDialect -Version $Version) -Value $Value | Should -Be $Expected
        }
        Context 'the fake DHIS2 reads a filter back the way the source does' {
            # A value with two slashes comes back changed before 2.42 (the cause of the check above); one slash, ':' and
            # ',' come back exactly on every version.
            It 'reads <Value> back on DHIS2 <Version> as <ReadAs>' -ForEach @(
                @{ Version = '2.40.12'; Value = 'x/2:a,b'; ReadAs = 'x/2:a,b' }
                @{ Version = '2.40.12'; Value = 'A//1'; ReadAs = 'A///1' }
                @{ Version = '2.41.10'; Value = 'DE-BER-01/2024-0000001/b'; ReadAs = 'DE-BER-012/024-0000001/b' }
                @{ Version = '2.41.10'; Value = 'AT-WIEN-AKH-0042/1/2'; ReadAs = 'AT-WIEN-AKH-00421//2' }
                # Nine positions 16 apart share a bucket of the table of 16, which then doubles to 32.
                @{ Version = '2.41.10'; Value = (('x' * 16) + '/') * 9
                    ReadAs = ((('x' * 20), ('x' * 12), ('x' * 19), ('x' * 13), ('x' * 18), ('x' * 14), ('x' * 17), ('x' * 15), ('x' * 16)) -join '/') + '/' }
                @{ Version = '2.42.6'; Value = 'DE-BER-01/2024-0000001/b'; ReadAs = 'DE-BER-01/2024-0000001/b' }
                @{ Version = '2.43.2'; Value = 'A//1:x,y'; ReadAs = 'A//1:x,y' }
            ) {
                New-FakeInstance $Version
                (ConvertFrom-FakeFilter ('AttPatId001:eq:' + (ConvertTo-NeoIPCTrackerFilterValue -Value $Value))).Value | Should -BeExactly $ReadAs
            }
        }
    }

    Describe 'Get-NeoIPCTrackerDialect: the tracked-entity read names' {
        It 'names the org units, the tracked entities and their separator of DHIS2 <Version>' -ForEach @(
            # NEOIPC-COMPAT(dhis2-2.40-tracker-dialect): see Private/TrackerDialect.ps1.
            @{ Version = '2.40.12'; OrgUnits = 'orgUnit'; TrackedEntities = 'trackedEntity'; Separator = ';' }
            @{ Version = '2.41.10'; OrgUnits = 'orgUnits'; TrackedEntities = 'trackedEntities'; Separator = ',' }
            @{ Version = '2.43.2'; OrgUnits = 'orgUnits'; TrackedEntities = 'trackedEntities'; Separator = ',' }
        ) {
            $q = (Get-NeoIPCTrackerDialect -Version $Version).TrackedEntityQuery
            $q.OrgUnits | Should -BeExactly $OrgUnits
            $q.TrackedEntities | Should -BeExactly $TrackedEntities
            $q.Separator | Should -BeExactly $Separator
        }
    }

    Describe 'Get-NeoIPCTrackedEntityList' {
        BeforeEach { New-FakeInstance '2.43.2'; Set-FakeMock }

        It 'reads 50 UIDs at a time, joined with the dialect''s separator' {
            $uids = 1..60 | ForEach-Object { 'TePat{0:D6}' -f $_ }
            foreach ($u in $uids) { Add-FakePatient -Uid $u -NeoIpcId "ID-$u" }
            $read = Get-NeoIPCTrackedEntityList -Endpoint @{ Auth = $script:Auth; Hostname = $script:Host1 } -Dialect (Get-NeoIPCTrackerDialect -Version '2.43.2') `
                -TrackedEntityTypeId 'TetPatnt001' -OrgUnitMode 'CAPTURE' -TrackedEntityId $uids -Fields 'trackedEntity'
            @($read).Count | Should -Be 60
            $reads = Get-FakeRequest 'GET' -Path 'api/tracker/trackedEntities'
            $reads.Count | Should -Be 2
            ($reads[0].Query['trackedEntities'] -split ',').Count | Should -Be 50
            ($reads[1].Query['trackedEntities'] -split ',').Count | Should -Be 10
        }
        It 'throws when the read returns a tracked entity it did not ask for (a read the server widened)' {
            Add-FakePatient -Uid 'TePat000001' -NeoIpcId 'A-1'
            Add-FakePatient -Uid 'TePat000002' -NeoIpcId 'A-2'
            $script:Fake.IgnoreSelector = $true
            { Get-NeoIPCTrackedEntityList -Endpoint @{ Auth = $script:Auth; Hostname = $script:Host1 } -Dialect (Get-NeoIPCTrackerDialect -Version '2.43.2') `
                    -TrackedEntityTypeId 'TetPatnt001' -OrgUnitMode 'CAPTURE' -TrackedEntityId 'TePat000001' -Fields 'trackedEntity' } |
                Should -Throw "*did not ask for*"
        }
        It 'throws when the read returns a UID that differs from the one asked for only in case' {
            Add-FakePatient -Uid 'abcDefGhi12' -NeoIpcId 'A-1'
            $script:Fake.IgnoreSelector = $true
            { Get-NeoIPCTrackedEntityList -Endpoint @{ Auth = $script:Auth; Hostname = $script:Host1 } -Dialect (Get-NeoIPCTrackerDialect -Version '2.43.2') `
                    -TrackedEntityTypeId 'TetPatnt001' -OrgUnitMode 'CAPTURE' -TrackedEntityId 'AbcDefGhi12' -Fields 'trackedEntity' } |
                Should -Throw "*did not ask for*"
        }
        It 'refuses a value that is no UID before any request' {
            { Get-NeoIPCTrackedEntityList -Endpoint @{ Auth = $script:Auth; Hostname = $script:Host1 } -Dialect (Get-NeoIPCTrackerDialect -Version '2.43.2') `
                    -TrackedEntityTypeId 'TetPatnt001' -OrgUnitMode 'CAPTURE' -TrackedEntityId 'a;b' -Fields 'trackedEntity' } | Should -Throw "*not a DHIS2 UID*"
            @(Get-FakeRequest 'GET').Count | Should -Be 0
        }
        It 'refuses before any request a filter value DHIS2 <Version> would look up as another value' -ForEach @(
            # NEOIPC-COMPAT(dhis2-pre-2.42-filter-escape): see Private/TrackerDialect.ps1.
            @{ Version = '2.40.12' }
            @{ Version = '2.41.10' }
        ) {
            New-FakeInstance $Version; Set-FakeMock
            { Get-NeoIPCTrackedEntityList -Endpoint @{ Auth = $script:Auth; Hostname = $script:Host1 } -Dialect (Get-NeoIPCTrackerDialect -Version $Version) `
                    -TrackedEntityTypeId 'TetPatnt001' -OrgUnitMode 'SELECTED' -OrgUnitId 'OuDeptA0001' -AttributeId 'AttPatId001' -AttributeValue 'A/1/2' -Fields 'trackedEntity' } |
                Should -Throw "*more than one '/'*"
            @(Get-FakeRequest 'GET').Count | Should -Be 0
        }
    }

    Describe 'ConvertTo-NeoIPCPatientSelection' {
        It 'collapses exact duplicates and keeps the order given' {
            $s = ConvertTo-NeoIPCPatientSelection -Mode 'NeoIpcId' -OrgUnitCode 'DEPT_A' -NeoIpcId 'B-2', 'A-1', 'B-2' -MaximumCount 25
            @($s.Items.Value) | Should -Be @('B-2', 'A-1')
            @($s.Items | Where-Object Outcome).Count | Should -Be 0
        }
        It 'refuses every selector of a group that differs only in case, <Mode>' -ForEach @(
            @{ Mode = 'NeoIpcId'; Values = @('abc-1', 'ABC-1') }
            @{ Mode = 'TrackedEntityId'; Values = @('AbcDefGhi12', 'abcDefGhi12') }
        ) {
            $arguments = @{ Mode = $Mode; OrgUnitCode = 'DEPT_A'; MaximumCount = 25; $Mode = $Values }
            $s = ConvertTo-NeoIPCPatientSelection @arguments
            @($s.Items | ForEach-Object { $_.Reason }) | Should -Be @('CaseVariantInput', 'CaseVariantInput')
        }
        It 'refuses a malformed UID, a padded patient ID and a malformed piped OrgUnitId, and nothing else' {
            $items = (ConvertTo-NeoIPCPatientSelection -Mode 'TrackedEntityId' -OrgUnitCode 'DEPT_A' -TrackedEntityId 'not-a-uid', 'TePat000001' -MaximumCount 25).Items
            $items[0].Reason | Should -Be 'InvalidInput'
            $items[1].Outcome | Should -BeNullOrEmpty
            (ConvertTo-NeoIPCPatientSelection -Mode 'NeoIpcId' -OrgUnitCode 'DEPT_A' -NeoIpcId ' A-1' -MaximumCount 25).Items[0].Reason | Should -Be 'InvalidInput'
            (ConvertTo-NeoIPCPatientSelection -Mode 'InputObject' -InputObject @([pscustomobject]@{ TrackedEntityId = 'TePat000001'; OrgUnitId = 'x' }) -MaximumCount 25).Items[0].Reason |
                Should -Be 'InvalidInput'
        }
        It 'ends the run on input that is no patient record: <Case>' -ForEach @(
            @{ Case = 'a string'; Object = 'TePat000001' }
            @{ Case = 'an event record'; Object = [pscustomobject]@{ TrackedEntityId = 'TePat000001'; OrgUnitId = 'OuDeptA0001'; EventId = 'Ev000000001' } }
            @{ Case = 'an enrolment record'; Object = [pscustomobject]@{ TrackedEntityId = 'TePat000001'; OrgUnitId = 'OuDeptA0001'; EnrollmentId = 'En000000001' } }
            @{ Case = 'no TrackedEntityId'; Object = [pscustomobject]@{ OrgUnitId = 'OuDeptA0001' } }
            @{ Case = 'no department'; Object = [pscustomobject]@{ TrackedEntityId = 'TePat000001' } }
        ) {
            $s = ConvertTo-NeoIPCPatientSelection -Mode 'InputObject' -InputObject @($Object) -MaximumCount 25
            $s.ErrorId | Should -Be 'InputShape'
            @($s.Items).Count | Should -Be 0
        }
        It 'reads a hashtable like any other record' {
            $s = ConvertTo-NeoIPCPatientSelection -Mode 'InputObject' -InputObject @(@{ TrackedEntityId = 'TePat000001'; OrgUnitId = 'OuDeptA0001'; NeoIpcId = 'A-1' }) -MaximumCount 25
            $s.Items[0].Value | Should -BeExactly 'TePat000001'
            $s.Items[0].OrgUnitId | Should -BeExactly 'OuDeptA0001'
            $s.Items[0].ExpectedNeoIpcId | Should -BeExactly 'A-1'
        }
        It 'refuses one UID piped twice with different departments' {
            $s = ConvertTo-NeoIPCPatientSelection -Mode 'InputObject' -MaximumCount 25 -InputObject @(
                [pscustomobject]@{ TrackedEntityId = 'TePat000001'; OrgUnitId = 'OuDeptA0001' }, [pscustomobject]@{ TrackedEntityId = 'TePat000001'; OrgUnitId = 'OuDeptB0001' })
            @($s.Items).Count | Should -Be 1
            $s.Items[0].Reason | Should -Be 'ConflictingInput'
        }
        It 'ends the run when the selection is larger than -MaximumCount' {
            (ConvertTo-NeoIPCPatientSelection -Mode 'NeoIpcId' -OrgUnitCode 'DEPT_A' -NeoIpcId 'A-1', 'A-2', 'A-3' -MaximumCount 2).ErrorId | Should -Be 'TooMany'
        }
    }

    Describe 'Resolve-NeoIPCPatientMatch' {
        BeforeAll {
            function New-Record([string]$Uid, [string]$Id, [string]$OrgUnit = 'OuDeptA0001', [string]$Program = 'PrgCore0001', [string]$Owner, [string]$EnrollmentOrgUnit,
                [string]$EventOrgUnit, [string]$ExtraOwnerProgram, [string]$Type = 'TetPatnt001', [switch]$Deleted, [string]$Drop) {
                $owners = @(@{ program = $Program; orgUnit = $(if ($Owner) { $Owner } else { $OrgUnit }) })
                if ($ExtraOwnerProgram) { $owners += @{ program = $ExtraOwnerProgram; orgUnit = $OrgUnit } }
                $te = [ordered]@{ trackedEntity = $Uid; trackedEntityType = $Type; orgUnit = $OrgUnit; deleted = [bool]$Deleted
                    attributes = @(if ($Id) { @{ attribute = 'AttPatId001'; value = $Id } })
                    programOwners = $owners
                    enrollments = @(@{ enrollment = 'En000000001'; program = $Program; orgUnit = $(if ($EnrollmentOrgUnit) { $EnrollmentOrgUnit } else { $OrgUnit }); deleted = $false
                            events = @(@{ event = 'Ev000000001'; orgUnit = $(if ($EventOrgUnit) { $EventOrgUnit } else { $OrgUnit }); deleted = $false }) })
                }
                if ($Drop) { $te.Remove($Drop) }
                ConvertTo-NeoIPCPatientRecord -TrackedEntity $te -PatientIdAttributeId 'AttPatId001'
            }
            function Resolve-Case($Kind, $Value, $Records, $Expected = $null) {
                $item = [pscustomobject]@{ Kind = $Kind; Value = $Value; ExpectedNeoIpcId = $Expected }
                Resolve-NeoIPCPatientMatch -Item $item -Record @($Records) -DepartmentId 'OuDeptA0001' -DepartmentCode 'DEPT_A' -ProgramId 'PrgCore0001' -TrackedEntityTypeId 'TetPatnt001'
            }
        }
        It 'matches a patient ID exactly, never one that differs only in case' {
            $v = Resolve-Case 'NeoIpcId' 'abc-1' @(New-Record 'TePat000001' 'ABC-1')
            $v.Outcome | Should -Be 'NotFound'
            $v.Message | Should -BeLike '*differs only in case*TePat000001*'
        }
        It 'refuses an exact match beside a case variant as ambiguous' {
            (Resolve-Case 'NeoIpcId' 'abc-1' @((New-Record 'TePat000001' 'abc-1'), (New-Record 'TePat000002' 'ABC-1'))).Reason | Should -Be 'Ambiguous'
        }
        It 'returns the deletable patient when everything lies in the department and NEOIPC_CORE' {
            $v = Resolve-Case 'NeoIpcId' 'A-1' @(New-Record 'TePat000001' 'A-1')
            $v.Outcome | Should -BeNullOrEmpty
            $v.Patient.TrackedEntityId | Should -BeExactly 'TePat000001'
        }
        It 'refuses <Reason>' -ForEach @(
            @{ Reason = 'OutsideDepartment'; Record = { New-Record 'TePat000001' 'A-1' -OrgUnit 'OuDeptB0001' } }
            @{ Reason = 'OutsideDepartment'; Record = { New-Record 'TePat000001' 'A-1' -Owner 'OuDeptB0001' } }
            @{ Reason = 'OtherProgram'; Record = { New-Record 'TePat000001' 'A-1' -Program 'PrgOthr0001' } }
            @{ Reason = 'OtherProgram'; Record = { New-Record 'TePat000001' 'A-1' -ExtraOwnerProgram 'PrgOthr0001' } }
            @{ Reason = 'OtherOrgUnit'; Record = { New-Record 'TePat000001' 'A-1' -EventOrgUnit 'OuDeptB0001' } }
            @{ Reason = 'OtherOrgUnit'; Record = { New-Record 'TePat000001' 'A-1' -EnrollmentOrgUnit 'OuDeptB0001' } }
            @{ Reason = 'NotAPatient'; Record = { New-Record 'TePat000001' 'A-1' -Type 'TetOther001' } }
            @{ Reason = 'IncompleteRead'; Record = { New-Record 'TePat000001' 'A-1' -Drop 'programOwners' } }
        ) {
            (Resolve-Case 'NeoIpcId' 'A-1' @(& $Record)).Reason | Should -Be $Reason
        }
        It 'refuses a piped patient ID that is not the patient''s' {
            (Resolve-Case 'TrackedEntityId' 'TePat000001' @(New-Record 'TePat000001' 'A-1') 'A-2').Reason | Should -Be 'InputMismatch'
        }
        It 'reports a deleted patient selected by UID as already deleted' {
            (Resolve-Case 'TrackedEntityId' 'TePat000001' @(New-Record 'TePat000001' $null -Deleted)).Outcome | Should -Be 'AlreadyDeleted'
        }
    }

    Describe 'Get-NeoIPCTrackerDeleteAnswer' {
        BeforeAll {
            function Get-Answer($Response, [string]$Uid = 'TePat000001', [string]$Transport) {
                $converted = if ($Response) { ConvertFrom-NeoIPCTrackerImportResponse -StatusCode $Response.StatusCode -Body $Response.Body -TrackedEntityId @($Uid) } else { $null }
                Get-NeoIPCTrackerDeleteAnswer -Response $converted -TrackedEntityId $Uid -TransportFailure $Transport
            }
        }
        It 'classifies <Case> as <Kind>' -ForEach @(
            @{ Case = 'a report that lists the patient'; Kind = 'Reported'; Make = { New-FakeReport -Deleted @('TePat000001') } }
            @{ Case = 'a 409 report refusing the patient'; Kind = 'Refused'; Make = { New-FakeReport -Errors @(@{ uid = 'TePat000001'; errorCode = 'E1000'; message = 'no' }) } }
            @{ Case = 'a report listing another patient'; Kind = 'Foreign'; Make = { New-FakeReport -Deleted @('TePat000002') } }
            @{ Case = 'a report listing the patient and another'; Kind = 'Foreign'; Make = { New-FakeReport -Deleted @('TePat000001', 'TePat000002') } }
            @{ Case = 'a report refusing the patient and naming another'; Kind = 'Foreign'; Make = { New-FakeReport -Errors @(@{ uid = 'TePat000001'; errorCode = 'E1000'; message = 'no' }, @{ uid = 'TePat000002'; errorCode = 'E1063'; message = 'no' }) } }
            @{ Case = 'a report that neither lists nor refuses the patient'; Kind = 'Unclear'; Make = { New-FakeReport } }
            @{ Case = '2.40''s veto'; Kind = 'CommitFailed'; Make = { New-Fake240ErrorReport 'Exception:x' } }
            @{ Case = '2.41''s veto'; Kind = 'ServerError'; Make = { New-FakeWebMessage 500 'null' } }
            @{ Case = 'a 403'; Kind = 'AccessDenied'; Make = { New-FakeWebMessage 403 'denied' } }
            @{ Case = 'a queued job'; Kind = 'AsyncJob'; Make = { New-FakeWebMessage 200 'Tracker job added' @{ responseType = 'TrackerJob' } } }
            @{ Case = 'a gateway timeout'; Kind = 'NoAnswer'; Make = { [pscustomobject]@{ StatusCode = 504; Body = '<html></html>' } } }
            @{ Case = 'a 400 WebMessage'; Kind = 'Rejected'; Make = { New-FakeWebMessage 400 'bad' } }
        ) {
            (Get-Answer (& $Make)).Kind | Should -Be $Kind
        }
        It 'reads a 200 report that refuses the patient as a refusal, not a deletion' {
            $r = New-FakeReport -Errors @(@{ uid = 'TePat000001'; errorCode = 'E1100'; message = 'no' })
            $r.StatusCode = 200
            $a = Get-Answer $r
            $a.Kind | Should -Be 'Refused'
            $a.ErrorCodes | Should -Be @('E1100')
        }
        It 'never takes an object report at index 0 for another patient as this one''s' {
            $body = [pscustomobject]@{ status = 'OK'; validationReport = [pscustomobject]@{ errorReports = @() }
                bundleReport = [pscustomobject]@{ typeReportMap = [pscustomobject]@{ TRACKED_ENTITY = [pscustomobject]@{ objectReports = @([pscustomobject]@{ uid = 'TePat000002'; index = 0 }) } } } }
            (Get-Answer ([pscustomobject]@{ StatusCode = 200; Body = $body })).Kind | Should -Not -Be 'Reported'
        }
        It 'classifies a lost connection as no answer' {
            (Get-Answer $null -Transport 'The SSL connection could not be established.').Kind | Should -Be 'NoAnswer'
        }
    }

    Describe 'Get-NeoIPCPatientReadBackState and Get-NeoIPCPatientRemovalOutcome' {
        BeforeAll {
            function New-Rec([bool]$Deleted, [bool]$ChildDeleted = $Deleted, [switch]$Incomplete) {
                [pscustomobject]@{ TrackedEntityId = 'TePat000001'; Deleted = $Deleted; Complete = -not $Incomplete
                    Enrollments = @([pscustomobject]@{ EnrollmentId = 'En000000001'; Deleted = $ChildDeleted; Events = @([pscustomobject]@{ EventId = 'Ev000000001'; Deleted = $ChildDeleted }) }) }
            }
            $script:Previewed = New-Rec $false
        }
        It 'proves a deletion only with the patient and its data deleted and a 404' {
            (Get-NeoIPCPatientReadBackState -Record (New-Rec $true) -Previewed $script:Previewed -SingleReadStatus 404).State | Should -Be 'ProvenDeleted'
        }
        It 'reads <Case> as <State>' -ForEach @(
            @{ Case = 'a deleted patient with a live event'; State = 'Unknown'; Reason = 'CascadeIncomplete'; Rec = { New-Rec $true $false }; Single = 404 }
            @{ Case = 'a deleted patient whose single read answers 200'; State = 'Unknown'; Reason = 'ReadBackFailed'; Rec = { New-Rec $true }; Single = 200 }
            @{ Case = 'a live patient found by the single read'; State = 'Live'; Reason = $null; Rec = { New-Rec $false }; Single = 200 }
            @{ Case = 'a live patient whose data is deleted'; State = 'Unknown'; Reason = 'PartialDeletion'; Rec = { New-Rec $false $true }; Single = 200 }
            @{ Case = 'a live patient whose single read answers 404'; State = 'Unknown'; Reason = 'ReadBackFailed'; Rec = { New-Rec $false }; Single = 404 }
            @{ Case = 'an incomplete read'; State = 'Unknown'; Reason = 'ReadBackFailed'; Rec = { New-Rec $true -Incomplete }; Single = 404 }
            @{ Case = 'no read'; State = 'Unknown'; Reason = 'ReadBackFailed'; Rec = { $null }; Single = 404 }
        ) {
            $s = Get-NeoIPCPatientReadBackState -Record (& $Rec) -Previewed $script:Previewed -SingleReadStatus $Single
            $s.State | Should -Be $State
            $s.Reason | Should -Be $Reason
        }
        It 'gives <Outcome> (<Reason>, stop: <Stop>) for <Answer> with the patient <ReadBack>' -ForEach @(
            @{ Answer = 'Reported'; ReadBack = 'ProvenDeleted'; Outcome = 'Deleted'; Reason = $null; Stop = $false }
            @{ Answer = 'NoAnswer'; ReadBack = 'ProvenDeleted'; Outcome = 'Deleted'; Reason = $null; Stop = $false }
            @{ Answer = 'ServerError'; ReadBack = 'ProvenDeleted'; Outcome = 'Deleted'; Reason = $null; Stop = $false }
            @{ Answer = 'AsyncJob'; ReadBack = 'ProvenDeleted'; Outcome = 'Deleted'; Reason = 'AsyncJob'; Stop = $true }
            @{ Answer = 'Refused'; ReadBack = 'ProvenDeleted'; Outcome = 'Deleted'; Reason = 'ReportMismatch'; Stop = $true }
            @{ Answer = 'CommitFailed'; ReadBack = 'ProvenDeleted'; Outcome = 'Deleted'; Reason = 'ReportMismatch'; Stop = $true }
            @{ Answer = 'Rejected'; ReadBack = 'ProvenDeleted'; Outcome = 'Deleted'; Reason = 'ReportMismatch'; Stop = $true }
            @{ Answer = 'AccessDenied'; ReadBack = 'ProvenDeleted'; Outcome = 'Deleted'; Reason = 'ReportMismatch'; Stop = $true }
            @{ Answer = 'Unclear'; ReadBack = 'ProvenDeleted'; Outcome = 'Deleted'; Reason = 'ReportMismatch'; Stop = $true }
            @{ Answer = 'Foreign'; ReadBack = 'ProvenDeleted'; Outcome = 'Deleted'; Reason = 'ReportMismatch'; Stop = $true }
            @{ Answer = 'Refused'; ReadBack = 'Live'; Outcome = 'Failed'; Reason = 'Dhis2Refused'; Stop = $false }
            @{ Answer = 'CommitFailed'; ReadBack = 'Live'; Outcome = 'Failed'; Reason = 'CommitFailed'; Stop = $false }
            @{ Answer = 'ServerError'; ReadBack = 'Live'; Outcome = 'Failed'; Reason = 'ServerError'; Stop = $false }
            @{ Answer = 'Rejected'; ReadBack = 'Live'; Outcome = 'Failed'; Reason = 'Rejected'; Stop = $false }
            @{ Answer = 'AccessDenied'; ReadBack = 'Live'; Outcome = 'Failed'; Reason = 'AccessDenied'; Stop = $true }
            @{ Answer = 'Reported'; ReadBack = 'Live'; Outcome = 'Failed'; Reason = 'ReportMismatch'; Stop = $true }
            @{ Answer = 'Unclear'; ReadBack = 'Live'; Outcome = 'Failed'; Reason = 'ReportMismatch'; Stop = $true }
            @{ Answer = 'Foreign'; ReadBack = 'Live'; Outcome = 'Failed'; Reason = 'ReportMismatch'; Stop = $true }
            @{ Answer = 'NoAnswer'; ReadBack = 'Live'; Outcome = 'Unverified'; Reason = 'ResponseLost'; Stop = $true }
            @{ Answer = 'AsyncJob'; ReadBack = 'Live'; Outcome = 'Unverified'; Reason = 'AsyncJob'; Stop = $true }
            @{ Answer = 'Reported'; ReadBack = 'Unknown'; Outcome = 'Unverified'; Reason = 'ReadBackFailed'; Stop = $true }
        ) {
            $o = Get-NeoIPCPatientRemovalOutcome -Answer ([pscustomobject]@{ Kind = $Answer; Message = 'm' }) -ReadBack ([pscustomobject]@{ State = $ReadBack; Reason = 'ReadBackFailed'; Message = 'r' })
            $o.Outcome | Should -Be $Outcome
            $o.Reason | Should -Be $Reason
            $o.Stop | Should -Be $Stop
        }
    }

    Describe 'Format-NeoIPCPatientRemovalPrompt' {
        It 'states the totals, singular and plural, and the refused patients' {
            $p = Format-NeoIPCPatientRemovalPrompt -PatientCount 2 -EnrollmentCount 1 -EventCount 4 -OrgUnitCode 'DEPT_A' -Target 'https://h' -Dhis2Version '2.40.12' -RefusedCount 1
            $p.Description | Should -BeExactly 'Deleting 2 patients with 1 enrolment and 4 events in DEPT_A on https://h (DHIS2 2.40.12)'
            $p.Query | Should -BeLike '*1 selected patient is refused and will not be deleted.'
        }
    }

    Describe 'Remove-NeoIPCPatient' {
        BeforeEach { New-FakeInstance '2.43.2'; Set-FakeMock }

        Context 'the requests' {
            It 'deletes by department and patient IDs in the DHIS2 <Version> dialect' -ForEach @(
                # NEOIPC-COMPAT(dhis2-2.40-tracker-dialect): see Private/TrackerDialect.ps1.
                @{ Version = '2.40.12'; OrgUnits = 'orgUnit'; Mode = 'ouMode'; TrackedEntities = 'trackedEntity'; Stale = @('orgUnits', 'orgUnitMode', 'trackedEntities'); Paging = 'skipPaging' }
                @{ Version = '2.41.10'; OrgUnits = 'orgUnits'; Mode = 'orgUnitMode'; TrackedEntities = 'trackedEntities'; Stale = @('orgUnit', 'ouMode', 'trackedEntity', 'skipPaging'); Paging = $null }
                @{ Version = '2.42.6'; OrgUnits = 'orgUnits'; Mode = 'orgUnitMode'; TrackedEntities = 'trackedEntities'; Stale = @('orgUnit', 'ouMode', 'trackedEntity', 'skipPaging'); Paging = $null }
                @{ Version = '2.43.2'; OrgUnits = 'orgUnits'; Mode = 'orgUnitMode'; TrackedEntities = 'trackedEntities'; Stale = @('orgUnit', 'ouMode', 'trackedEntity', 'skipPaging'); Paging = $null }
            ) {
                New-FakeInstance $Version; Set-FakeMock
                Add-FakePatient -Uid 'TePat000001' -NeoIpcId 'A-1' -Enrollments 2 -Events 2
                Add-FakePatient -Uid 'TePat000002' -NeoIpcId 'A-2'
                $r = Invoke-Removal @{ OrgUnitCode = 'DEPT_A'; NeoIpcId = @('A-1', 'A-2') }
                @($r.Results.Outcome) | Should -Be @('Deleted', 'Deleted')
                $r.Errors.Count | Should -Be 0
                $script:Fake.Patients['TePat000001']['deleted'] | Should -BeTrue
                $lookup = Get-LookupQuery
                $lookup[$OrgUnits] | Should -BeExactly 'OuDeptA0001'
                $lookup[$Mode] | Should -BeExactly 'SELECTED'
                $lookup['filter'] | Should -BeExactly 'AttPatId001:eq:A-1'
                if ($Paging) { $lookup[$Paging] | Should -Be 'true' }
                foreach ($read in Get-FakeRequest 'GET' -Path 'api/tracker/trackedEntities') {
                    foreach ($name in @($Stale) + 'program') { $read.Query.ContainsKey($name) | Should -BeFalse -Because "the DHIS2 $Version dialect never sends '$name' on a tracked-entity read" }
                }
                $readBack = Get-FakeRequest 'GET' -Path 'api/tracker/trackedEntities' | Where-Object { $_.Query.ContainsKey($TrackedEntities) } | Select-Object -First 1
                $readBack.Query[$Mode] | Should -BeExactly 'CAPTURE'
                $readBack.Query['includeDeleted'] | Should -Be 'true'
            }
            It 'sends every request to the host it was given' {
                Add-FakePatient -Uid 'TePat000001' -NeoIpcId 'A-1'
                $null = Invoke-Removal @{ OrgUnitCode = 'DEPT_A'; NeoIpcId = 'A-1' }
                @($script:Fake.Requests | Where-Object { $_.Hostname -cne $script:Host1 }).Count | Should -Be 0
                $script:Fake.Requests.Count | Should -BeGreaterThan 0
            }
            It 'declares a mandatory -Hostname without a default and asks before it deletes' {
                $command = Get-Command Remove-NeoIPCPatient
                $command.Parameters['Hostname'].Attributes.Where({ $_ -is [System.Management.Automation.ParameterAttribute] }).Mandatory | Should -Not -Contain $false
                $command.ScriptBlock.Attributes.Where({ $_ -is [System.Management.Automation.CmdletBindingAttribute] })[0].ConfirmImpact | Should -Be 'High'
            }
            It 'deletes each patient in its own request carrying only its UID, never with validationMode' {
                Add-FakePatient -Uid 'TePat000001' -NeoIpcId 'A-1'
                Add-FakePatient -Uid 'TePat000002' -NeoIpcId 'A-2'
                $null = Invoke-Removal @{ OrgUnitCode = 'DEPT_A'; NeoIpcId = @('A-1', 'A-2') }
                $commits = Get-FakeRequest 'POST' 'COMMIT'
                $commits.Count | Should -Be 2
                foreach ($c in $commits) {
                    @($c.Query.Keys | Sort-Object -CaseSensitive) | Should -Be @('async', 'atomicMode', 'importMode', 'importStrategy', 'reportMode')
                    $c.Query['async'] | Should -BeExactly 'false'
                    $c.Query['importStrategy'] | Should -BeExactly 'DELETE'
                    $c.Query['atomicMode'] | Should -BeExactly 'ALL'
                    $c.Query['reportMode'] | Should -BeExactly 'FULL'
                    @($c.Payload.Keys) | Should -Be @('trackedEntities')
                    @($c.Payload['trackedEntities']).Count | Should -Be 1
                    @($c.Payload['trackedEntities'][0].Keys) | Should -Be @('trackedEntity')
                }
                @(Get-FakeRequest 'POST' 'VALIDATE').Count | Should -Be 1
                @(Get-FakeRequest 'POST' 'VALIDATE')[0].Uids | Should -Be @('TePat000001', 'TePat000002')
            }
        }

        Context 'the preview' {
            It 'under -WhatIf reads and validates, deletes nothing, and writes no error' {
                Add-FakePatient -Uid 'TePat000001' -NeoIpcId 'A-1'
                $r = Invoke-Removal @{ OrgUnitCode = 'DEPT_A'; NeoIpcId = @('A-1', 'X-9'); WhatIf = $true }
                @($r.Results | ForEach-Object Outcome) | Should -Be @('WouldDelete', 'NotFound')
                @(Get-FakeRequest 'POST' 'VALIDATE').Count | Should -Be 1
                @(Get-FakeRequest 'POST' 'COMMIT').Count | Should -Be 0
                $r.Errors.Count | Should -Be 0
                $script:Fake.Patients['TePat000001']['deleted'] | Should -BeFalse
            }
            It 'refuses the patients DHIS2''s dry run refuses, and deletes the others' {
                Add-FakePatient -Uid 'TePat000001' -NeoIpcId 'A-1'
                Add-FakePatient -Uid 'TePat000002' -NeoIpcId 'A-2'
                $script:Fake.DryRunCode['TePat000001'] = 'E1100'
                $r = Invoke-Removal @{ OrgUnitCode = 'DEPT_A'; NeoIpcId = @('A-1', 'A-2') }
                $r.Results[0].Outcome | Should -Be 'Refused'
                $r.Results[0].Reason | Should -Be 'Dhis2Refused'
                $r.Results[0].ErrorCodes | Should -Be @('E1100')
                $r.Results[1].Outcome | Should -Be 'Deleted'
                @(@(Get-FakeRequest 'POST' 'COMMIT').Uids) | Should -Be @('TePat000002')
            }
            It 'ends the run before any deletion when the dry run <Case>' -ForEach @(
                @{ Case = 'answers without a report'; DryRun = 'NoReport'; Message = '*without an import report*' }
                @{ Case = 'names a UID it was not asked about'; DryRun = 'Foreign'; Message = '*UIDs it was not asked about*' }
                @{ Case = 'fails without refusing a patient'; DryRun = 'ErrorNoCodes'; Message = '*without refusing any patient*' }
            ) {
                Add-FakePatient -Uid 'TePat000001' -NeoIpcId 'A-1'
                $script:Fake.DryRun = $DryRun
                { Invoke-Removal @{ OrgUnitCode = 'DEPT_A'; NeoIpcId = 'A-1' } } | Should -Throw $Message
                @(Get-FakeRequest 'POST' 'COMMIT').Count | Should -Be 0
            }
            It 'takes the dry run''s <Code> as <Outcome> and sends no deletion for that patient' -ForEach @(
                @{ Code = 'E1063'; Outcome = 'NotFound' }
                @{ Code = 'E1114'; Outcome = 'AlreadyDeleted' }
            ) {
                Add-FakePatient -Uid 'TePat000001' -NeoIpcId 'A-1'
                Add-FakePatient -Uid 'TePat000002' -NeoIpcId 'A-2'
                $script:Fake.DryRunCode['TePat000001'] = $Code
                $r = Invoke-Removal @{ OrgUnitCode = 'DEPT_A'; NeoIpcId = @('A-1', 'A-2') }
                $r.Results[0].Outcome | Should -Be $Outcome
                $r.Results[0].ErrorCodes | Should -Be @($Code)
                $r.Results[1].Outcome | Should -Be 'Deleted'
                @(@(Get-FakeRequest 'POST' 'COMMIT').Uids) | Should -Be @('TePat000002')
            }
            It 'emits the enrolment and event IDs as string arrays, whatever their number' {
                Add-FakePatient -Uid 'TePat000001' -NeoIpcId 'A-1' -Enrollments 1 -Events 1
                Add-FakePatient -Uid 'TePat000002' -NeoIpcId 'A-2' -Enrollments 2 -Events 1
                $r = Invoke-Removal @{ OrgUnitCode = 'DEPT_A'; NeoIpcId = @('A-1', 'A-2', 'X-9'); WhatIf = $true }
                foreach ($result in $r.Results) {
                    , $result.EnrollmentIds | Should -BeOfType [string[]]
                    , $result.EventIds | Should -BeOfType [string[]]
                }
                @($r.Results | ForEach-Object { $_.EnrollmentIds.Count }) | Should -Be @(1, 2, 0)
                @($r.Results | ForEach-Object { $_.EventIds.Count }) | Should -Be @(1, 2, 0)
            }
            It 'states the totals in the confirmation text' {
                Add-FakePatient -Uid 'TePat000001' -NeoIpcId 'A-1' -Enrollments 2 -Events 1
                Add-FakePatient -Uid 'TePat000002' -NeoIpcId 'A-2' -Enrollments 1 -Events 2
                $verbose = Remove-NeoIPCPatient -OrgUnitCode 'DEPT_A' -NeoIpcId 'A-1', 'A-2' -Auth $script:Auth -Hostname $script:Host1 -Confirm:$false -Verbose 4>&1 6>$null |
                    Where-Object { $_ -is [System.Management.Automation.VerboseRecord] }
                ($verbose.Message -join "`n") | Should -BeLike "*Deleting 2 patients with 3 enrolments and 4 events in DEPT_A on https://$($script:Host1) (DHIS2 2.43.2)*"
            }
        }

        Context 'what may not be deleted' {
            It 'ends the run before any tracker read on DHIS2 <Version>, unless -AllowUnverifiedVersion' -ForEach @(
                @{ Version = '2.44.0' }
                @{ Version = '2.41.9' }
                @{ Version = '2.43.2-SNAPSHOT' }
            ) {
                New-FakeInstance $Version; Set-FakeMock
                Add-FakePatient -Uid 'TePat000001' -NeoIpcId 'A-1'
                $err = $null
                try { $null = Invoke-Removal @{ OrgUnitCode = 'DEPT_A'; NeoIpcId = 'A-1' } } catch { $err = $_ }
                $err.Exception.Message | Should -BeExactly ("DHIS2 $Version is no release this removal was verified on (2.40.12, 2.41.10, 2.42.6, 2.43.2, or a " +
                    'later patch of one of their lines). No patient was read or deleted. Once the removal has been checked on this release, pass -AllowUnverifiedVersion.')
                @(Get-FakeRequest 'GET' -Path 'api/tracker/trackedEntities').Count | Should -Be 0
                $r = Invoke-Removal @{ OrgUnitCode = 'DEPT_A'; NeoIpcId = 'A-1'; AllowUnverifiedVersion = $true }
                $r.Results[0].Outcome | Should -Be 'Deleted'
            }
            It 'ends the run before any tracker read when -OrgUnitCode names <Case>' -ForEach @(
                @{ Case = 'no org unit'; Code = 'DEPT_Z' }
                @{ Case = 'an org unit only ignoring case'; Code = 'dept_a' }
                @{ Case = 'no department'; Code = 'HOSP_X' }
            ) {
                { Invoke-Removal @{ OrgUnitCode = $Code; NeoIpcId = 'A-1' } } | Should -Throw
                @(Get-FakeRequest 'GET' -Path 'api/tracker/trackedEntities').Count | Should -Be 0
            }
            It 'ends the run when NEOIPC_CORE registers another type' {
                $script:Fake.TypeCode = 'OTHER'
                { Invoke-Removal @{ OrgUnitCode = 'DEPT_A'; NeoIpcId = 'A-1' } } | Should -Throw '*NEOIPC_PATIENT*'
            }
            It 'never deletes a patient whose ID differs only in case' {
                Add-FakePatient -Uid 'TePat000001' -NeoIpcId 'ABC-1'
                $r = Invoke-Removal @{ OrgUnitCode = 'DEPT_A'; NeoIpcId = 'abc-1' }
                $r.Results[0].Outcome | Should -Be 'NotFound'
                @(Get-FakeRequest 'POST').Count | Should -Be 0
            }
            It 'refuses <Reason> and sends nothing for that patient' -ForEach @(
                @{ Reason = 'OtherProgram'; Setup = { Add-FakePatient -Uid 'TePat000001' -NeoIpcId 'A-1' -Program 'PrgOthr0001' } }
                @{ Reason = 'OtherOrgUnit'; Setup = { Add-FakePatient -Uid 'TePat000001' -NeoIpcId 'A-1' -EventOrgUnit 'OuDeptB0001' } }
                @{ Reason = 'OutsideDepartment'; Setup = { Add-FakePatient -Uid 'TePat000001' -NeoIpcId 'A-1' -OrgUnit 'OuDeptB0001' -OwnerOrgUnit 'OuDeptA0001' } }
                @{ Reason = 'Ambiguous'; Setup = { Add-FakePatient -Uid 'TePat000001' -NeoIpcId 'A-1'; Add-FakePatient -Uid 'TePat000002' -NeoIpcId 'a-1' } }
                @{ Reason = 'IncompleteRead'; Setup = { Add-FakePatient -Uid 'TePat000001' -NeoIpcId 'A-1'; $script:Fake.DropField = 'programOwners' } }
            ) {
                & $Setup
                $r = Invoke-Removal @{ OrgUnitCode = 'DEPT_A'; NeoIpcId = 'A-1' }
                $r.Results[0].Outcome | Should -Be 'Refused'
                $r.Results[0].Reason | Should -Be $Reason
                @(Get-FakeRequest 'POST').Count | Should -Be 0
                $script:Fake.Patients['TePat000001']['deleted'] | Should -BeFalse
            }
            It 'refuses on DHIS2 <Version> the patient ID <NeoIpcId>, without looking it up' -ForEach @(
                # NEOIPC-COMPAT(dhis2-pre-2.42-filter-escape): see Private/TrackerDialect.ps1.
                @{ Version = '2.40.12'; NeoIpcId = 'A//1' }
                @{ Version = '2.40.12'; NeoIpcId = 'DE-BER-01/2024-0000001/b' }
                @{ Version = '2.41.10'; NeoIpcId = 'A//1' }
                @{ Version = '2.41.10'; NeoIpcId = 'AT-WIEN-AKH-0042/1/2' }
            ) {
                New-FakeInstance $Version; Set-FakeMock
                Add-FakePatient -Uid 'TePat000001' -NeoIpcId $NeoIpcId
                $r = Invoke-Removal @{ OrgUnitCode = 'DEPT_A'; NeoIpcId = $NeoIpcId }
                $r.Results[0].Outcome | Should -Be 'Refused'
                $r.Results[0].Reason | Should -Be 'InvalidInput'
                @(Get-FakeRequest 'GET' -Path 'api/tracker/trackedEntities').Count | Should -Be 0
                @(Get-FakeRequest 'POST').Count | Should -Be 0
            }
            It 'finds and deletes on DHIS2 <Version> a patient whose ID is <NeoIpcId>' -ForEach @(
                @{ Version = '2.40.12'; NeoIpcId = 'A/1:x,y'; Filter = 'AttPatId001:eq:A//1/:x/,y' }
                @{ Version = '2.41.10'; NeoIpcId = 'A/1:x,y'; Filter = 'AttPatId001:eq:A//1/:x/,y' }
                @{ Version = '2.42.6'; NeoIpcId = 'DE-BER-01/2024-0000001/b'; Filter = 'AttPatId001:eq:DE-BER-01//2024-0000001//b' }
                @{ Version = '2.43.2'; NeoIpcId = 'A//1:x,y'; Filter = 'AttPatId001:eq:A////1/:x/,y' }
            ) {
                New-FakeInstance $Version; Set-FakeMock
                Add-FakePatient -Uid 'TePat000001' -NeoIpcId $NeoIpcId
                (Invoke-Removal @{ OrgUnitCode = 'DEPT_A'; NeoIpcId = $NeoIpcId }).Results[0].Outcome | Should -Be 'Deleted'
                (Get-LookupQuery)['filter'] | Should -BeExactly $Filter
            }
            It 'finds by patient ID only what the department owns where NEOIPC_CORE is the patient type''s only program' {
                [void]$script:Fake.TypePrograms.Remove($script:Fake.OtherProgramId)
                Add-FakePatient -Uid 'TePat000001' -NeoIpcId 'A-1' -OwnerOrgUnit 'OuDeptB0001'
                (Invoke-Removal @{ OrgUnitCode = 'DEPT_A'; NeoIpcId = 'A-1' }).Results[0].Outcome | Should -Be 'NotFound'
                $byUid = (Invoke-Removal @{ OrgUnitCode = 'DEPT_A'; TrackedEntityId = 'TePat000001' }).Results[0]
                $byUid.Reason | Should -Be 'OutsideDepartment'
                @(Get-FakeRequest 'POST').Count | Should -Be 0
            }
            It 'finds by UID a patient another department owns only where you capture data for that department' {
                [void]$script:Fake.TypePrograms.Remove($script:Fake.OtherProgramId)
                [void]$script:Fake.Capture.Remove('OuDeptB0001')
                Add-FakePatient -Uid 'TePat000001' -NeoIpcId 'A-1' -OwnerOrgUnit 'OuDeptB0001'
                $byUid = (Invoke-Removal @{ OrgUnitCode = 'DEPT_A'; TrackedEntityId = 'TePat000001' }).Results[0]
                $byUid.Outcome | Should -Be 'NotFound'
                $byUid.Message | Should -BeExactly "No patient with the UID 'TePat000001' among the patients DHIS2 lets you capture data for."
                @(Get-FakeRequest 'POST').Count | Should -Be 0
            }
            It 'ends the run before any request when the selection exceeds -MaximumCount' {
                { Invoke-Removal @{ OrgUnitCode = 'DEPT_A'; NeoIpcId = @('A-1', 'A-2', 'A-3'); MaximumCount = 2 } } | Should -Throw '*-MaximumCount*'
                $script:Fake.Requests.Count | Should -Be 0
            }
            It 'ends the run before any POST when a read lacks the version''s list key' {
                Add-FakePatient -Uid 'TePat000001' -NeoIpcId 'A-1'
                $script:Fake.ListKey = 'instances'
                { Invoke-Removal @{ OrgUnitCode = 'DEPT_A'; NeoIpcId = 'A-1' } } | Should -Throw "*did not return a 'trackedEntities' list*"
                @(Get-FakeRequest 'POST').Count | Should -Be 0
            }
            It 'ends the run before any POST when DHIS2 widens a read' {
                Add-FakePatient -Uid 'TePat000001' -NeoIpcId 'A-1'
                Add-FakePatient -Uid 'TePat000002' -NeoIpcId 'A-2'
                $script:Fake.IgnoreSelector = $true
                { Invoke-Removal @{ OrgUnitCode = 'DEPT_A'; NeoIpcId = 'A-1' } } | Should -Throw
                @(Get-FakeRequest 'POST').Count | Should -Be 0
            }
            It 'ends the run before any POST when a widened read returns the patient ID from another department' {
                Add-FakePatient -Uid 'TePat000001' -NeoIpcId 'A-1'
                Add-FakePatient -Uid 'TePat000002' -NeoIpcId 'A-1' -OrgUnit 'OuDeptB0001'
                $script:Fake.IgnoreSelector = $true
                { Invoke-Removal @{ OrgUnitCode = 'DEPT_A'; NeoIpcId = 'A-1' } } | Should -Throw '*neither registered nor owned*'
                @(Get-FakeRequest 'POST').Count | Should -Be 0
            }
            It 'ends the run before any POST when a read returns a tracked entity of another type' {
                Add-FakePatient -Uid 'TePat000001' -NeoIpcId 'A-1' -Type 'TetOther001'
                $script:Fake.IgnoreType = $true
                { Invoke-Removal @{ OrgUnitCode = 'DEPT_A'; NeoIpcId = 'A-1' } } | Should -Throw "*of type 'TetOther001'*"
                @(Get-FakeRequest 'POST').Count | Should -Be 0
            }
        }

        Context 'selection by UID and from the pipeline' {
            It 'deletes by UID, and tells an already deleted and an unknown UID apart without sending them' {
                Add-FakePatient -Uid 'TePat000001' -NeoIpcId 'A-1'
                Add-FakePatient -Uid 'TePat000002' -Deleted
                $r = Invoke-Removal @{ OrgUnitCode = 'DEPT_A'; TrackedEntityId = @('TePat000001', 'TePat000002', 'TePat000009') }
                @($r.Results | ForEach-Object Outcome) | Should -Be @('Deleted', 'AlreadyDeleted', 'NotFound')
                @(@(Get-FakeRequest 'POST' 'COMMIT').Uids) | Should -Be @('TePat000001')
            }
            It 'keeps two UIDs that differ only in case apart, refusing both' {
                Add-FakePatient -Uid 'AbcDefGhi12' -NeoIpcId 'A-1'
                Add-FakePatient -Uid 'abcDefGhi12' -NeoIpcId 'A-2'
                $r = Invoke-Removal @{ OrgUnitCode = 'DEPT_A'; TrackedEntityId = @('AbcDefGhi12', 'abcDefGhi12') }
                @($r.Results | ForEach-Object Reason) | Should -Be @('CaseVariantInput', 'CaseVariantInput')
                @(Get-FakeRequest 'POST').Count | Should -Be 0
            }
            It 'deletes piped patient records, and refuses one whose patient ID is not the patient''s' {
                Add-FakePatient -Uid 'TePat000001' -NeoIpcId 'A-1'
                Add-FakePatient -Uid 'TePat000002' -NeoIpcId 'A-2'
                $records = @(
                    [pscustomobject]@{ TrackedEntityId = 'TePat000001'; OrgUnitId = 'OuDeptA0001'; NeoIpcId = 'A-1' }
                    [pscustomobject]@{ TrackedEntityId = 'TePat000002'; OrgUnitId = 'OuDeptA0001'; NeoIpcId = 'A-3' }
                )
                $results = @($records | Remove-NeoIPCPatient -Auth $script:Auth -Hostname $script:Host1 -Confirm:$false -ErrorAction SilentlyContinue 6>$null)
                @($results | ForEach-Object Outcome) | Should -Be @('Deleted', 'Refused')
                $results[1].Reason | Should -Be 'InputMismatch'
            }
            It 'refuses a piped record whose OrgUnitId <Case>, and sends nothing for it' -ForEach @(
                @{ Case = 'names another department than -OrgUnitCode'; OrgUnitId = 'OuDeptB0001'; OrgUnitCode = 'DEPT_A'; Reason = 'DepartmentMismatch'; Message = "*'OuDeptB0001', not the department DEPT_A*" }
                @{ Case = 'names an org unit that is no department'; OrgUnitId = 'OuHospX0001'; OrgUnitCode = $null; Reason = 'NotADepartment'; Message = '*HOSP_X is not a department*' }
                @{ Case = 'names no org unit'; OrgUnitId = 'OuNone00001'; OrgUnitCode = $null; Reason = 'NotADepartment'; Message = "*No org unit has the UID 'OuNone00001'*" }
            ) {
                Add-FakePatient -Uid 'TePat000001' -NeoIpcId 'A-1' -OrgUnit $OrgUnitId
                Add-FakePatient -Uid 'TePat000002' -NeoIpcId 'A-2'
                $arguments = @{ InputObject = @([pscustomobject]@{ TrackedEntityId = 'TePat000001'; OrgUnitId = $OrgUnitId }, [pscustomobject]@{ TrackedEntityId = 'TePat000002'; OrgUnitId = 'OuDeptA0001' }) }
                if ($OrgUnitCode) { $arguments['OrgUnitCode'] = $OrgUnitCode }
                $r = Invoke-Removal $arguments
                $r.Results[0].Outcome | Should -Be 'Refused'
                $r.Results[0].Reason | Should -Be $Reason
                $r.Results[0].Message | Should -BeLike $Message
                $r.Results[1].Outcome | Should -Be 'Deleted'
                @(@(Get-FakeRequest 'POST').Uids | Where-Object { $_ -ceq 'TePat000001' }).Count | Should -Be 0
                $script:Fake.Patients['TePat000001']['deleted'] | Should -BeFalse
            }
            It 'ends the run before any request on an event record from the pipeline' {
                $event1 = [pscustomobject]@{ EventId = 'Ev000000001'; TrackedEntityId = 'TePat000001'; OrgUnitId = 'OuDeptA0001' }
                { $event1 | Remove-NeoIPCPatient -Auth $script:Auth -Hostname $script:Host1 -Confirm:$false 6>$null } | Should -Throw '*enrolment or event record*'
                $script:Fake.Requests.Count | Should -Be 0
            }
            It 'ends the run before any request when piped input meets -NeoIpcId' {
                { [pscustomobject]@{ TrackedEntityId = 'TePat000001' } | Remove-NeoIPCPatient -OrgUnitCode 'DEPT_A' -NeoIpcId 'A-1' -Auth $script:Auth -Hostname $script:Host1 -Confirm:$false 6>$null } |
                    Should -Throw '*Only -InputObject takes pipeline input*'
                $script:Fake.Requests.Count | Should -Be 0
            }
        }

        Context 'the outcome of each deletion' {
            It 'carries on after a patient DHIS2 refuses at commit' {
                Add-FakePatient -Uid 'TePat000001' -NeoIpcId 'A-1'
                Add-FakePatient -Uid 'TePat000002' -NeoIpcId 'A-2'
                $script:Fake.Behaviour['TePat000001'] = 'Refuse:E1000'
                $r = Invoke-Removal @{ OrgUnitCode = 'DEPT_A'; NeoIpcId = @('A-1', 'A-2') }
                @($r.Results | ForEach-Object Outcome) | Should -Be @('Failed', 'Deleted')
                $r.Results[0].ErrorCodes | Should -Be @('E1000')
            }
            It 'carries on after the <Case> veto' -ForEach @(
                @{ Case = '2.40'; Behaviour = 'Veto240'; Version = '2.40.12' }
                @{ Case = '2.41'; Behaviour = 'Veto241'; Version = '2.41.10' }
            ) {
                New-FakeInstance $Version; Set-FakeMock
                Add-FakePatient -Uid 'TePat000001' -NeoIpcId 'A-1'
                Add-FakePatient -Uid 'TePat000002' -NeoIpcId 'A-2'
                $script:Fake.Behaviour['TePat000001'] = $Behaviour
                $r = Invoke-Removal @{ OrgUnitCode = 'DEPT_A'; NeoIpcId = @('A-1', 'A-2') }
                @($r.Results | ForEach-Object Outcome) | Should -Be @('Failed', 'Deleted')
            }
            It 'stops after <Behaviour> and leaves the later patients unattempted' -ForEach @(
                @{ Behaviour = 'Lie'; Outcome = 'Failed'; Reason = 'ReportMismatch'; Warning = $null }
                @{ Behaviour = 'Foreign'; Outcome = 'Deleted'; Reason = 'ReportMismatch'
                    Warning = "Patient TePat000001: DHIS2's report names UIDs the request did not carry: TeForeign01. The read-back proves the patient deleted." }
                @{ Behaviour = 'RefuseForeign'; Outcome = 'Failed'; Reason = 'ReportMismatch'; Warning = $null }
                @{ Behaviour = 'AccessDenied'; Outcome = 'Failed'; Reason = 'AccessDenied'; Warning = $null }
                @{ Behaviour = 'Transport'; Outcome = 'Unverified'; Reason = 'ResponseLost'; Warning = $null }
                @{ Behaviour = 'Gateway'; Outcome = 'Unverified'; Reason = 'ResponseLost'; Warning = $null }
                @{ Behaviour = 'Async'; Outcome = 'Unverified'; Reason = 'AsyncJob'; Warning = $null }
                @{ Behaviour = 'AsyncDeleted'; Outcome = 'Deleted'; Reason = 'AsyncJob'
                    Warning = "Patient TePat000001: DHIS2's answer did not report the deletion (DHIS2 queued the deletion as a job instead of running it.), but the read-back proves it." }
                @{ Behaviour = 'Partial'; Outcome = 'Unverified'; Reason = 'CascadeIncomplete'; Warning = $null }
                @{ Behaviour = 'PartialFail'; Outcome = 'Unverified'; Reason = 'PartialDeletion'; Warning = $null }
            ) {
                Add-FakePatient -Uid 'TePat000001' -NeoIpcId 'A-1'
                Add-FakePatient -Uid 'TePat000002' -NeoIpcId 'A-2'
                $script:Fake.Behaviour['TePat000001'] = $Behaviour
                $r = Invoke-Removal @{ OrgUnitCode = 'DEPT_A'; NeoIpcId = @('A-1', 'A-2') } -AllowStop
                $r.Stop.FullyQualifiedErrorId | Should -BeLike 'NeoIPCPatientRemovalStopped*'
                $r.Stop.Exception.Message | Should -BeLike "*TePat000001 ($Reason)*"
                $r.Results[0].Outcome | Should -Be $Outcome
                $r.Results[0].Reason | Should -Be $Reason
                $r.Results[1].Outcome | Should -Be 'NotAttempted'
                @(@(Get-FakeRequest 'POST' 'COMMIT').Uids) | Should -Be @('TePat000001')
                @($r.Warnings).Count | Should -Be $(if ($Warning) { 1 } else { 0 })
                if ($Warning) { "$($r.Warnings[0])" | Should -BeExactly $Warning }
            }
            It 'reports a deletion whose answer was lost as deleted once the read-back proves it' {
                Add-FakePatient -Uid 'TePat000001' -NeoIpcId 'A-1'
                $script:Fake.Behaviour['TePat000001'] = 'DeleteLost'
                $r = Invoke-Removal @{ OrgUnitCode = 'DEPT_A'; NeoIpcId = 'A-1' }
                $r.Results[0].Outcome | Should -Be 'Deleted'
                @($r.Warnings).Count | Should -BeGreaterThan 0
            }
            It 'never reports Deleted when the single read still finds the patient' {
                Add-FakePatient -Uid 'TePat000001' -NeoIpcId 'A-1'
                $script:Fake.SingleRead['TePat000001'] = 200
                $r = Invoke-Removal @{ OrgUnitCode = 'DEPT_A'; NeoIpcId = 'A-1' } -AllowStop
                $r.Results[0].Outcome | Should -Be 'Unverified'
            }
        }

        Context 'errors' {
            It 'writes one error per patient that is not deleted, with the result as its target' {
                Add-FakePatient -Uid 'TePat000001' -NeoIpcId 'A-1'
                $r = Invoke-Removal @{ OrgUnitCode = 'DEPT_A'; NeoIpcId = @('A-1', 'X-9') }
                $r.Errors.Count | Should -Be 1
                $r.Errors[0].FullyQualifiedErrorId | Should -BeLike 'NeoIPCPatientNotFound*'
                $r.Errors[0].TargetObject.NeoIpcId | Should -BeExactly 'X-9'
            }
            It 'deletes nothing under -ErrorAction Stop when a selected patient is refused' {
                Add-FakePatient -Uid 'TePat000001' -NeoIpcId 'A-1'
                { Remove-NeoIPCPatient -OrgUnitCode 'DEPT_A' -NeoIpcId 'A-1', 'X-9' -Auth $script:Auth -Hostname $script:Host1 -Confirm:$false -ErrorAction Stop 6>$null } | Should -Throw
                @(Get-FakeRequest 'POST' 'COMMIT').Count | Should -Be 0
            }
            It 'sends every confirmed deletion under -ErrorAction Stop before a failure ends the run' {
                Add-FakePatient -Uid 'TePat000001' -NeoIpcId 'A-1'
                Add-FakePatient -Uid 'TePat000002' -NeoIpcId 'A-2'
                $script:Fake.Behaviour['TePat000001'] = 'Refuse:E1000'
                { Remove-NeoIPCPatient -OrgUnitCode 'DEPT_A' -NeoIpcId 'A-1', 'A-2' -Auth $script:Auth -Hostname $script:Host1 -Confirm:$false -ErrorAction Stop 6>$null } | Should -Throw
                @(Get-FakeRequest 'POST' 'COMMIT').Count | Should -Be 2
                $script:Fake.Patients['TePat000002']['deleted'] | Should -BeTrue
            }
            It 'keeps per-patient errors non-terminating under the caller''s default error preference' {
                Add-FakePatient -Uid 'TePat000001' -NeoIpcId 'A-1'
                $ErrorActionPreference = 'Continue'
                $results = @(Remove-NeoIPCPatient -OrgUnitCode 'DEPT_A' -NeoIpcId 'X-9', 'A-1' -Auth $script:Auth -Hostname $script:Host1 -Confirm:$false `
                        -ErrorVariable removalErrors 2>$null 6>$null)
                @($results | ForEach-Object Outcome) | Should -Be @('NotFound', 'Deleted')
                @(Get-FakeRequest 'POST' 'COMMIT').Count | Should -Be 1
                @($removalErrors | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }).Count | Should -Be 1
            }
            It 'ends the run before any POST when a read fails, through the read''s own try, under -ErrorAction SilentlyContinue too' {
                Add-FakePatient -Uid 'TePat000001' -NeoIpcId 'A-1'
                $script:Fake.ThrowRead = $true
                { Remove-NeoIPCPatient -OrgUnitCode 'DEPT_A' -NeoIpcId 'A-1' -Auth $script:Auth -Hostname $script:Host1 -Confirm:$false -ErrorAction SilentlyContinue 6>$null } | Should -Throw
                @(Get-FakeRequest 'POST').Count | Should -Be 0
            }
            It 'ends the run at a failure after a deletion under -ErrorAction SilentlyContinue, with no try around the call' {
                # Only a process with no try anywhere above the call shows what the function-wide Stop preference does:
                # Pester's own try makes every throw end the run, whatever the preference. The child process replaces
                # the HTTP helpers in the module, and the classification of DHIS2's answer throws after the first
                # deletion; without the preference the run would drop that throw and go on to the second patient.
                $manifest = Join-Path (Get-Module NeoIPC-Tools).ModuleBase 'NeoIPC-Tools.psd1'
                $child = @"
Import-Module '$($manifest.Replace("'", "''"))' -Force
`$m = Get-Module NeoIPC-Tools
& `$m {
    function script:Invoke-WebRequest { throw 'A test made an HTTP call.' }
    function script:Invoke-RestMethod { throw 'A test made an HTTP call.' }
    function script:Invoke-NeoIPCDhis2Get {
        [CmdletBinding(SupportsShouldProcess)]
        param(`$Auth, `$Scheme, `$Hostname, `$Port, `$Path, `$Fields, `$Filter, `$QueryParameters, [switch]`$AsHashtable)
        switch (`$Path) {
            'api/system/info' { return @{ version = '2.43.2' } }
            'api/metadata' { return @{ programs = @(@{ id = 'PrgCore0001'; code = 'NEOIPC_CORE'; trackedEntityType = @{ id = 'TetPatnt001'; code = 'NEOIPC_PATIENT' } }); trackedEntityAttributes = @(@{ id = 'AttPatId001'; code = 'NEOIPC_PATIENT_ID' }) } }
            'api/organisationUnits' { return @{ organisationUnits = @(@{ id = 'OuDeptA0001'; code = 'DEPT_A'; organisationUnitGroups = @(@{ code = 'NEO_DEPARTMENT' }) }) } }
            'api/tracker/trackedEntities' {
                return @{ trackedEntities = @(([string]`$QueryParameters['trackedEntities']) -split ',' | ForEach-Object {
                            [ordered]@{ trackedEntity = `$_; trackedEntityType = 'TetPatnt001'; orgUnit = 'OuDeptA0001'; deleted = `$false; attributes = @()
                                programOwners = @([ordered]@{ program = 'PrgCore0001'; orgUnit = 'OuDeptA0001' }); enrollments = @() } }) }
            }
        }
    }
    function script:Invoke-NeoIPCDhis2Post {
        [CmdletBinding(SupportsShouldProcess)]
        param(`$Auth, `$Scheme, `$Hostname, `$Port, `$Path, `$Body, `$QueryParameters)
        if (`$QueryParameters['importMode'] -eq 'COMMIT') { [Console]::Out.WriteLine('##COMMIT##') }
        [pscustomobject]@{ StatusCode = 200; Body = [pscustomobject]@{ status = 'OK'; validationReport = [pscustomobject]@{ errorReports = @() }; bundleReport = [pscustomobject]@{ typeReportMap = [pscustomobject]@{} } } }
    }
    function script:Get-NeoIPCDhis2StatusCode { param(`$Auth, `$Scheme, `$Hostname, `$Port, `$Path) 200 }
    function script:Get-NeoIPCTrackerDeleteAnswer { throw 'A failure after a deletion.' }
}
Remove-NeoIPCPatient -OrgUnitCode 'DEPT_A' -TrackedEntityId 'TePat000001', 'TePat000002' -Auth @{ AuthType = 'Basic' } -Hostname 'dhis2.example.org' ``
    -Confirm:`$false -ErrorAction SilentlyContinue 6>`$null | Out-Null
"@
                $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($child))
                $output = & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -EncodedCommand $encoded 2>&1
                @($output | Where-Object { "$_" -ceq '##COMMIT##' }).Count | Should -Be 1 -Because ($output -join "`n")
            }
        }

        It 'documents every parameter' {
            $help = Get-Help Remove-NeoIPCPatient -Full
            foreach ($name in 'OrgUnitCode', 'NeoIpcId', 'TrackedEntityId', 'InputObject', 'Auth', 'Hostname', 'Scheme', 'Port', 'MaximumCount', 'AllowUnverifiedVersion') {
                ($help.parameters.parameter | Where-Object name -eq $name).description.Text | Should -Not -BeNullOrEmpty -Because "-$name needs help"
            }
        }
    }
}
