# Pester 5 tests for the play demo-data pipeline (Private/PlayData.ps1 + Public/PlayData.ps1).
# Self-contained: the pure assembler / serializer / reader are exercised with hand-built code maps and
# temp CSVs, so the suite runs with no DHIS2 instance. The live import (Import-NeoIPCPlayData) and the
# code-map fetch (Get-NeoIPCPlayDataCodeMap) hit the API, so they are covered by the workspace integration
# seed, not here.
#
# Run:  Invoke-Pester -Path scripts/modules/NeoIPC-Tools/Tests/PlayData.Tests.ps1

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..') -Force

InModuleScope 'NeoIPC-Tools' {

    BeforeAll {
        # A hand-built code map — the offline stand-in for Get-NeoIPCPlayDataCodeMap's fetch. Map values are
        # opaque UIDs the converters copy through; only the play-data row ids must be real 11-char UIDs.
        $script:Map = @{
            ProgramId         = 'progAAAAAA1'
            TrackedEntityType = 'tetAAAAAAA1'
            TeaCodeToId       = @{ NEOIPC_PATIENT_ID = 'teaPIDAAAA1'; NEOIPC_TEA_SEX = 'teaSEXAAAA1' }
            TeaIdToCode       = @{ teaPIDAAAA1 = 'NEOIPC_PATIENT_ID'; teaSEXAAAA1 = 'NEOIPC_TEA_SEX' }
            DeCodeToId        = @{ NEOIPC_ADMISSION_TYPE = 'deADMTYPAA1'; NEOIPC_ADMISSION_DOL = 'deADMDOLAA1'; NEOIPC_SURVEILLANCE_END_REASON = 'deENDRSNAA1' }
            DeIdToCode        = @{ deADMTYPAA1 = 'NEOIPC_ADMISSION_TYPE'; deADMDOLAA1 = 'NEOIPC_ADMISSION_DOL'; deENDRSNAA1 = 'NEOIPC_SURVEILLANCE_END_REASON' }
            StageKeyToId      = @{ adm = 'stgADMAAAA1'; end = 'stgENDAAAA1'; bsi = 'stgBSIAAAA1' }
            StageIdToKey      = @{ stgADMAAAA1 = 'adm'; stgENDAAAA1 = 'end'; stgBSIAAAA1 = 'bsi' }
            OrgUnitCodeToId   = @{ AT_TEST_TEST = 'ouATAAAAAA1'; DE_TEST_TEST = 'ouDEAAAAAA1' }
            OrgUnitIdToCode   = @{ ouATAAAAAA1 = 'AT_TEST_TEST'; ouDEAAAAAA1 = 'DE_TEST_TEST' }
        }

        # The Tracker Capture fixture shape: one tracked entity, a COMPLETED enrollment (Admission ->
        # Surveillance-End) plus a later ACTIVE enrollment with only a COMPLETED Admission event.
        function New-FixtureRows {
            @{
                TrackedEntities = @(
                    [ordered]@{ id = 'trkFixAAAA1'; orgUnit = 'AT_TEST_TEST'; Attributes = [ordered]@{ NEOIPC_PATIENT_ID = 'E2E-TC-FIXTURE'; NEOIPC_TEA_SEX = 'm' } }
                )
                Enrollments     = @(
                    [ordered]@{ id = 'enrCmpAAAA1'; trackedEntity = 'trkFixAAAA1'; orgUnit = 'AT_TEST_TEST'; enrolledAt = '2025-01-01'; occurredAt = '2025-01-01'; status = 'COMPLETED'; completedAt = '2025-02-01' }
                    [ordered]@{ id = 'enrActAAAA1'; trackedEntity = 'trkFixAAAA1'; orgUnit = 'AT_TEST_TEST'; enrolledAt = '2025-03-01'; occurredAt = '2025-03-01'; status = 'ACTIVE'; completedAt = '' }
                )
                Events          = @(
                    [ordered]@{ id = 'evtAdmCAAA1'; enrollment = 'enrCmpAAAA1'; programStage = 'adm'; orgUnit = 'AT_TEST_TEST'; occurredAt = '2025-01-01'; status = 'COMPLETED'; completedAt = '2025-01-01' }
                    [ordered]@{ id = 'evtEndCAAA1'; enrollment = 'enrCmpAAAA1'; programStage = 'end'; orgUnit = 'AT_TEST_TEST'; occurredAt = '2025-02-01'; status = 'COMPLETED'; completedAt = '2025-02-01' }
                    [ordered]@{ id = 'evtAdmAAAA1'; enrollment = 'enrActAAAA1'; programStage = 'adm'; orgUnit = 'AT_TEST_TEST'; occurredAt = '2025-03-01'; status = 'COMPLETED'; completedAt = '2025-03-01' }
                )
                EventDataValues = @(
                    [ordered]@{ event = 'evtAdmCAAA1'; dataElement = 'NEOIPC_ADMISSION_TYPE'; value = '1' }
                    [ordered]@{ event = 'evtAdmCAAA1'; dataElement = 'NEOIPC_ADMISSION_DOL'; value = '1' }
                    [ordered]@{ event = 'evtEndCAAA1'; dataElement = 'NEOIPC_SURVEILLANCE_END_REASON'; value = '1' }
                    [ordered]@{ event = 'evtAdmAAAA1'; dataElement = 'NEOIPC_ADMISSION_TYPE'; value = '1' }
                    [ordered]@{ event = 'evtAdmAAAA1'; dataElement = 'NEOIPC_ADMISSION_DOL'; value = '1' }
                )
            }
        }
    }

    Describe 'ConvertTo-NeoIPCPlayDataPayload' {
        It 'assembles one tracked entity with resolved TE-type and org-unit UIDs' {
            $p = ConvertTo-NeoIPCPlayDataPayload -Rows (New-FixtureRows) -Maps $script:Map
            @($p.trackedEntities).Count | Should -Be 1
            $te = $p.trackedEntities[0]
            $te.trackedEntity | Should -Be 'trkFixAAAA1'
            $te.trackedEntityType | Should -Be 'tetAAAAAAA1'
            $te.orgUnit | Should -Be 'ouATAAAAAA1'
        }
        It 'resolves attribute codes to UIDs' {
            $te = (ConvertTo-NeoIPCPlayDataPayload -Rows (New-FixtureRows) -Maps $script:Map).trackedEntities[0]
            @($te.attributes).Count | Should -Be 2
            ($te.attributes | Where-Object { $_.attribute -eq 'teaPIDAAAA1' }).value | Should -Be 'E2E-TC-FIXTURE'
        }
        It 'nests both enrollments, emitting completedAt only for the COMPLETED one' {
            $te = (ConvertTo-NeoIPCPlayDataPayload -Rows (New-FixtureRows) -Maps $script:Map).trackedEntities[0]
            @($te.enrollments).Count | Should -Be 2
            $completed = $te.enrollments | Where-Object { $_.status -eq 'COMPLETED' }
            $active = $te.enrollments | Where-Object { $_.status -eq 'ACTIVE' }
            $completed.Contains('completedAt') | Should -BeTrue
            $completed['completedAt'] | Should -Be '2025-02-01'
            $active.Contains('completedAt') | Should -BeFalse
        }
        It 'nests the events and their resolved data values under each enrollment' {
            $te = (ConvertTo-NeoIPCPlayDataPayload -Rows (New-FixtureRows) -Maps $script:Map).trackedEntities[0]
            $completed = $te.enrollments | Where-Object { $_.status -eq 'COMPLETED' }
            $active = $te.enrollments | Where-Object { $_.status -eq 'ACTIVE' }
            @($completed.events).Count | Should -Be 2
            @($active.events).Count | Should -Be 1
            $adm = $active.events[0]
            $adm.programStage | Should -Be 'stgADMAAAA1'
            @($adm.dataValues).Count | Should -Be 2
            ($adm.dataValues | Where-Object { $_.dataElement -eq 'deADMTYPAA1' }).value | Should -Be '1'
        }
        It 'filters to the requested department' {
            $p = ConvertTo-NeoIPCPlayDataPayload -Rows (New-FixtureRows) -Maps $script:Map -OrgUnitCode 'DE_TEST_TEST'
            @($p.trackedEntities).Count | Should -Be 0
        }
        It 'fails loud on an org-unit code the map does not resolve' {
            $rows = New-FixtureRows
            $rows.TrackedEntities[0]['orgUnit'] = 'XX_TEST_TEST'
            { ConvertTo-NeoIPCPlayDataPayload -Rows $rows -Maps $script:Map } | Should -Throw '*did not resolve*'
        }
        It 'fails loud on a data-element code the map does not resolve' {
            $rows = New-FixtureRows
            $rows.EventDataValues[0]['dataElement'] = 'NEOIPC_NOT_A_REAL_DE'
            { ConvertTo-NeoIPCPlayDataPayload -Rows $rows -Maps $script:Map } | Should -Throw '*did not resolve*'
        }
    }

    Describe 'Read-NeoIPCPlayDataDirectory' {
        BeforeEach {
            $script:Dir = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString('N'))
            foreach ($tier in 'bulk', 'curated') { New-Item -ItemType Directory -Path (Join-Path $script:Dir $tier) -Force | Out-Null }
            # A minimal valid one-patient set in curated/; bulk/ stays header-only.
            Set-Content -LiteralPath (Join-Path $script:Dir 'curated/trackedEntities.csv') -Value "id,orgUnit,NEOIPC_PATIENT_ID,NEOIPC_TEA_SEX`ntrkFixAAAA1,AT_TEST_TEST,E2E-TC-FIXTURE,m"
            Set-Content -LiteralPath (Join-Path $script:Dir 'curated/enrollments.csv') -Value "id,trackedEntity,orgUnit,enrolledAt,occurredAt,status,completedAt`nenrActAAAA1,trkFixAAAA1,AT_TEST_TEST,2025-03-01,2025-03-01,ACTIVE,"
            Set-Content -LiteralPath (Join-Path $script:Dir 'curated/events.csv') -Value "id,enrollment,programStage,orgUnit,occurredAt,status,completedAt`nevtAdmAAAA1,enrActAAAA1,adm,AT_TEST_TEST,2025-03-01,COMPLETED,2025-03-01"
            Set-Content -LiteralPath (Join-Path $script:Dir 'curated/eventDataValues.csv') -Value "event,dataElement,value`nevtAdmAAAA1,NEOIPC_ADMISSION_TYPE,1"
            foreach ($f in 'trackedEntities', 'enrollments', 'events', 'eventDataValues') {
                Set-Content -LiteralPath (Join-Path $script:Dir "bulk/$f.csv") -Value (Get-Content -LiteralPath (Join-Path $script:Dir "curated/$f.csv") -TotalCount 1)
            }
        }
        It 'reads and merges the tiers, exposing the TEA columns as an Attributes map' {
            $rows = Read-NeoIPCPlayDataDirectory -Path $script:Dir
            $rows.TrackedEntities.Count | Should -Be 1
            $rows.Enrollments.Count | Should -Be 1
            $te = $rows.TrackedEntities[0]
            $te['Attributes']['NEOIPC_PATIENT_ID'] | Should -Be 'E2E-TC-FIXTURE'
            $te['Attributes'].Contains('id') | Should -BeFalse
        }
        It 'rejects an invalid tracked-entity UID' {
            Set-Content -LiteralPath (Join-Path $script:Dir 'curated/trackedEntities.csv') -Value "id,orgUnit,NEOIPC_PATIENT_ID`nnope,AT_TEST_TEST,E2E-TC-FIXTURE"
            { Read-NeoIPCPlayDataDirectory -Path $script:Dir } | Should -Throw '*invalid UID*'
        }
        It 'rejects a tracked entity with no NEOIPC_PATIENT_ID' {
            Set-Content -LiteralPath (Join-Path $script:Dir 'curated/trackedEntities.csv') -Value "id,orgUnit,NEOIPC_TEA_SEX`ntrkFixAAAA1,AT_TEST_TEST,m"
            { Read-NeoIPCPlayDataDirectory -Path $script:Dir } | Should -Throw '*no NEOIPC_PATIENT_ID*'
        }
        It 'rejects a dangling enrollment.trackedEntity reference' {
            Set-Content -LiteralPath (Join-Path $script:Dir 'curated/enrollments.csv') -Value "id,trackedEntity,orgUnit,enrolledAt,occurredAt,status,completedAt`nenrActAAAA1,trkOtherAA1,AT_TEST_TEST,2025-03-01,2025-03-01,ACTIVE,"
            { Read-NeoIPCPlayDataDirectory -Path $script:Dir } | Should -Throw '*unknown tracked entity*'
        }
        It 'rejects an invalid enrollment status' {
            Set-Content -LiteralPath (Join-Path $script:Dir 'curated/enrollments.csv') -Value "id,trackedEntity,orgUnit,enrolledAt,occurredAt,status,completedAt`nenrActAAAA1,trkFixAAAA1,AT_TEST_TEST,2025-03-01,2025-03-01,OPEN,"
            { Read-NeoIPCPlayDataDirectory -Path $script:Dir } | Should -Throw '*invalid status*'
        }
        It 'rejects an unknown programStage key' {
            Set-Content -LiteralPath (Join-Path $script:Dir 'curated/events.csv') -Value "id,enrollment,programStage,orgUnit,occurredAt,status,completedAt`nevtAdmAAAA1,enrActAAAA1,xyz,AT_TEST_TEST,2025-03-01,COMPLETED,2025-03-01"
            { Read-NeoIPCPlayDataDirectory -Path $script:Dir } | Should -Throw '*unknown programStage*'
        }
        It 'rejects a dangling event.enrollment reference' {
            Set-Content -LiteralPath (Join-Path $script:Dir 'curated/events.csv') -Value "id,enrollment,programStage,orgUnit,occurredAt,status,completedAt`nevtAdmAAAA1,enrOtherAA1,adm,AT_TEST_TEST,2025-03-01,COMPLETED,2025-03-01"
            { Read-NeoIPCPlayDataDirectory -Path $script:Dir } | Should -Throw '*unknown enrollment*'
        }
        It 'rejects a dangling eventDataValue.event reference' {
            Set-Content -LiteralPath (Join-Path $script:Dir 'curated/eventDataValues.csv') -Value "event,dataElement,value`nevtNoSuchE1,NEOIPC_ADMISSION_TYPE,1"
            { Read-NeoIPCPlayDataDirectory -Path $script:Dir } | Should -Throw '*unknown event*'
        }
        It 'rejects a duplicate tracked-entity UID across tiers' {
            Set-Content -LiteralPath (Join-Path $script:Dir 'bulk/trackedEntities.csv') -Value "id,orgUnit,NEOIPC_PATIENT_ID`ntrkFixAAAA1,DE_TEST_TEST,DEMO-9999"
            { Read-NeoIPCPlayDataDirectory -Path $script:Dir } | Should -Throw '*Duplicate tracked-entity UID*'
        }
        It 'rejects a duplicate NEOIPC_PATIENT_ID within the same org unit' {
            Set-Content -LiteralPath (Join-Path $script:Dir 'bulk/trackedEntities.csv') -Value "id,orgUnit,NEOIPC_PATIENT_ID`ntrkDupAAAA1,AT_TEST_TEST,E2E-TC-FIXTURE"
            { Read-NeoIPCPlayDataDirectory -Path $script:Dir } | Should -Throw '*Duplicate NEOIPC_PATIENT_ID*'
        }
        It 'allows the same NEOIPC_PATIENT_ID in different org units (the attribute is unique per org unit)' {
            # DEMO-#### legitimately repeats across departments in the generated bulk tier.
            Set-Content -LiteralPath (Join-Path $script:Dir 'bulk/trackedEntities.csv') -Value "id,orgUnit,NEOIPC_PATIENT_ID`ntrkDupAAAA1,DE_TEST_TEST,E2E-TC-FIXTURE"
            (Read-NeoIPCPlayDataDirectory -Path $script:Dir).TrackedEntities.Count | Should -Be 2
        }
        It 'rejects an enrollment that sets completedAt on a non-COMPLETED status' {
            Set-Content -LiteralPath (Join-Path $script:Dir 'curated/enrollments.csv') -Value "id,trackedEntity,orgUnit,enrolledAt,occurredAt,status,completedAt`nenrActAAAA1,trkFixAAAA1,AT_TEST_TEST,2025-03-01,2025-03-01,ACTIVE,2025-04-01"
            { Read-NeoIPCPlayDataDirectory -Path $script:Dir } | Should -Throw '*completedAt*'
        }
        It 'allows a COMPLETED enrollment with a blank completedAt (the server fills it on completion)' {
            Set-Content -LiteralPath (Join-Path $script:Dir 'curated/enrollments.csv') -Value "id,trackedEntity,orgUnit,enrolledAt,occurredAt,status,completedAt`nenrActAAAA1,trkFixAAAA1,AT_TEST_TEST,2025-03-01,2025-03-01,COMPLETED,"
            (Read-NeoIPCPlayDataDirectory -Path $script:Dir).Enrollments.Count | Should -Be 1
        }
        It 'rejects an event that sets completedAt on a non-COMPLETED status' {
            Set-Content -LiteralPath (Join-Path $script:Dir 'curated/events.csv') -Value "id,enrollment,programStage,orgUnit,occurredAt,status,completedAt`nevtAdmAAAA1,enrActAAAA1,adm,AT_TEST_TEST,2025-03-01,ACTIVE,2025-03-02"
            { Read-NeoIPCPlayDataDirectory -Path $script:Dir } | Should -Throw '*completedAt*'
        }
    }

    Describe 'ConvertTo-NeoIPCPlayDataRow (bulk re-freeze serializer)' {
        BeforeAll {
            # Two departments, same generator patient id 'DEMO-0001' — the per-department natural key must keep
            # their minted tracked-entity UIDs distinct. The AT patient has a COMPLETED + an ACTIVE enrollment.
            $script:GenPayload = [pscustomobject]@{ trackedEntities = @(
                    [pscustomobject]@{ orgUnit = 'ouATAAAAAA1'; attributes = @([pscustomobject]@{ attribute = 'teaPIDAAAA1'; value = 'DEMO-0001' }); enrollments = @(
                            [pscustomobject]@{ orgUnit = 'ouATAAAAAA1'; enrolledAt = '2025-01-01'; occurredAt = '2025-01-01'; status = 'COMPLETED'; completedAt = '2025-02-01'; events = @(
                                    [pscustomobject]@{ programStage = 'stgADMAAAA1'; orgUnit = 'ouATAAAAAA1'; occurredAt = '2025-01-01'; status = 'COMPLETED'; completedAt = '2025-01-01'; dataValues = @([pscustomobject]@{ dataElement = 'deADMTYPAA1'; value = '1' }) }
                                ) }
                            [pscustomobject]@{ orgUnit = 'ouATAAAAAA1'; enrolledAt = '2025-03-01'; occurredAt = '2025-03-01'; status = 'ACTIVE'; events = @() }
                        ) }
                    [pscustomobject]@{ orgUnit = 'ouDEAAAAAA1'; attributes = @([pscustomobject]@{ attribute = 'teaPIDAAAA1'; value = 'DEMO-0001' }); enrollments = @() }
                ) }
        }
        It 'reverse-maps UIDs to codes and mints per-department-unique tracked-entity UIDs' {
            $rows = ConvertTo-NeoIPCPlayDataRow -Payload @($script:GenPayload) -Maps $script:Map
            $rows.TrackedEntities.Count | Should -Be 2
            @($rows.TrackedEntities | ForEach-Object { $_['NEOIPC_PATIENT_ID'] } | Select-Object -Unique) | Should -Be 'DEMO-0001'
            @($rows.TrackedEntities.orgUnit | Sort-Object) | Should -Be @('AT_TEST_TEST', 'DE_TEST_TEST')
            @($rows.TrackedEntities | ForEach-Object { $_['id'] } | Select-Object -Unique).Count | Should -Be 2
            foreach ($r in $rows.TrackedEntities) { Test-NeoIPCMetadataUid -Id $r['id'] | Should -BeTrue }
        }
        It 'is deterministic — a second run mints byte-identical ids' {
            $a = (ConvertTo-NeoIPCPlayDataRow -Payload @($script:GenPayload) -Maps $script:Map).TrackedEntities[0]['id']
            $b = (ConvertTo-NeoIPCPlayDataRow -Payload @($script:GenPayload) -Maps $script:Map).TrackedEntities[0]['id']
            $a | Should -Be $b
        }
        It 'writes completedAt for a completed enrollment and blank for an active one' {
            $rows = ConvertTo-NeoIPCPlayDataRow -Payload @($script:GenPayload) -Maps $script:Map
            $completed = $rows.Enrollments | Where-Object { $_['status'] -eq 'COMPLETED' }
            $active = $rows.Enrollments | Where-Object { $_['status'] -eq 'ACTIVE' }
            $completed['completedAt'] | Should -Be '2025-02-01'
            $active['completedAt'] | Should -Be ''
        }
        It 'reverse-maps the event stage and data-element to codes' {
            $rows = ConvertTo-NeoIPCPlayDataRow -Payload @($script:GenPayload) -Maps $script:Map
            $rows.Events[0]['programStage'] | Should -Be 'adm'
            $rows.EventDataValues[0]['dataElement'] | Should -Be 'NEOIPC_ADMISSION_TYPE'
        }
        It 'fails loud on an org-unit UID absent from the reverse map' {
            $bad = [pscustomobject]@{ trackedEntities = @([pscustomobject]@{ orgUnit = 'ouXXAAAAAA1'; attributes = @([pscustomobject]@{ attribute = 'teaPIDAAAA1'; value = 'DEMO-9' }); enrollments = @() }) }
            { ConvertTo-NeoIPCPlayDataRow -Payload @($bad) -Maps $script:Map } | Should -Throw '*did not reverse-resolve*'
        }
    }

    Describe 'Write-NeoIPCPlayDataCsv' {
        It 'writes a header + rows, quotes only cells that need it, blanks absent columns, LF endings' {
            $path = Join-Path $TestDrive 'w.csv'
            Write-NeoIPCPlayDataCsv -Path $path -Column @('a', 'b', 'c') -Row @(
                [ordered]@{ a = 'x'; b = 'has,comma' },
                [ordered]@{ a = 'y' }
            )
            $text = [System.IO.File]::ReadAllText($path)
            $text | Should -Be "a,b,c`nx,`"has,comma`",`ny,,`n"
        }
        It 'writes a header-only file for an empty row set' {
            $path = Join-Path $TestDrive 'empty.csv'
            Write-NeoIPCPlayDataCsv -Path $path -Column @('a', 'b') -Row @()
            [System.IO.File]::ReadAllText($path) | Should -Be "a,b`n"
        }
    }

    Describe 'Import-NeoIPCPlayData (offline, mocked POST)' {
        # The live POST is mocked, so this exercises the load-bearing pure logic offline: the per-org-unit
        # split (one POST per tracked-entity org unit — the E1064 within-payload-uniqueness workaround), the
        # cross-POST stats/report aggregation, the OK/WARNING/ERROR derivation, the transport-error fold, and
        # the representative Raw. -SkipRuleEngine:$false pins the rule-engine gate off without the version GET.
        BeforeAll {
            # One tracked entity per listed org unit; the importer groups by orgUnit, so the codes drive the split.
            function New-PlayImportJson([string[]]$OrgUnit) {
                $i = 0
                $tes = @($OrgUnit | ForEach-Object { $i++; [ordered]@{ trackedEntity = ('trkImp{0:D5}' -f $i); orgUnit = $_; attributes = @(); enrollments = @() } })
                @{ trackedEntities = $tes } | ConvertTo-Json -Depth 100
            }
            # DHIS2 tracker import reports as the server returns them (WebMessage-wrapped in .response).
            function New-OkBody([int]$Created = 1) {
                [pscustomobject]@{ status = 'OK'; response = [pscustomobject]@{ status = 'OK'; stats = [pscustomobject]@{ created = $Created; updated = 0; deleted = 0; ignored = 0; total = $Created }; validationReport = [pscustomobject]@{ errorReports = @(); warningReports = @() } } }
            }
            function New-ErrorBody {
                [pscustomobject]@{ status = 'ERROR'; response = [pscustomobject]@{ status = 'ERROR'; stats = [pscustomobject]@{ created = 0; updated = 0; deleted = 0; ignored = 1; total = 1 }; validationReport = [pscustomobject]@{ errorReports = @([pscustomobject]@{ errorCode = 'E9999'; message = 'boom' }); warningReports = @() } } }
            }
            function New-WarningBody {
                [pscustomobject]@{ status = 'WARNING'; response = [pscustomobject]@{ status = 'WARNING'; stats = [pscustomobject]@{ created = 1; updated = 0; deleted = 0; ignored = 0; total = 1 }; validationReport = [pscustomobject]@{ errorReports = @(); warningReports = @([pscustomobject]@{ warningCode = 'W1000'; message = 'heads up' }) } } }
            }
        }
        It 'POSTs once per org unit and sums the stats across the groups' {
            Mock Invoke-NeoIPCDhis2Post { [pscustomobject]@{ StatusCode = 200; Body = (New-OkBody 1) } }
            $r = Import-NeoIPCPlayData -Json (New-PlayImportJson @('ouAAAAAAAA1', 'ouBBBBBBBB1', 'ouCCCCCCCC1')) -Auth @{} -SkipRuleEngine:$false -Confirm:$false
            Should -Invoke Invoke-NeoIPCDhis2Post -Times 3 -Exactly
            $r.OrgUnitGroups | Should -Be 3
            $r.Created | Should -Be 3
            $r.Status | Should -Be 'OK'
        }
        It 'reports ERROR and aggregates errorReports when any group fails' {
            Mock Invoke-NeoIPCDhis2Post -ParameterFilter { $Body -match 'ouZZZ' } { [pscustomobject]@{ StatusCode = 409; Body = (New-ErrorBody) } }
            Mock Invoke-NeoIPCDhis2Post -ParameterFilter { $Body -notmatch 'ouZZZ' } { [pscustomobject]@{ StatusCode = 200; Body = (New-OkBody 1) } }
            $r = Import-NeoIPCPlayData -Json (New-PlayImportJson @('ouAAAAAAAA1', 'ouZZZAAAAA1')) -Auth @{} -SkipRuleEngine:$false -Confirm:$false
            $r.Status | Should -Be 'ERROR'
            $r.ErrorReports.Count | Should -BeGreaterThan 0
            $r.HttpStatusCode | Should -Be 409
        }
        It 'sets Raw to an earlier failing group''s body, not a later success' {
            # Group-Object orders groups by orgUnit ascending, so the FAILING ouAAA group posts BEFORE the
            # ouZZZ success. Raw must be the ERROR body — proving the earlier failure survives the later
            # success. (The old "keep the last body" behaviour would wrongly yield the ouZZZ success here, so
            # this ordering — failure first — is what makes the assertion distinguish new code from old.)
            Mock Invoke-NeoIPCDhis2Post -ParameterFilter { $Body -match 'ouAAA' } { [pscustomobject]@{ StatusCode = 409; Body = (New-ErrorBody) } }
            Mock Invoke-NeoIPCDhis2Post -ParameterFilter { $Body -notmatch 'ouAAA' } { [pscustomobject]@{ StatusCode = 200; Body = (New-OkBody 1) } }
            $r = Import-NeoIPCPlayData -Json (New-PlayImportJson @('ouAAAAAAAA1', 'ouZZZAAAAA1')) -Auth @{} -SkipRuleEngine:$false -Confirm:$false
            $r.Raw.status | Should -Be 'ERROR'
        }
        It 'does not surface a later success in Raw when an earlier group failed with no body' {
            # A bare transport failure (HTTP 502, null body) posts first (ouAAA sorts first); a later group
            # succeeds with a body. Once a failure is seen, Raw must NOT fall back to that success — the
            # aggregate Status carries the failure, so Raw stays null rather than masking it with an OK body.
            Mock Invoke-NeoIPCDhis2Post -ParameterFilter { $Body -match 'ouAAA' } { [pscustomobject]@{ StatusCode = 502; Body = $null } }
            Mock Invoke-NeoIPCDhis2Post -ParameterFilter { $Body -notmatch 'ouAAA' } { [pscustomobject]@{ StatusCode = 200; Body = (New-OkBody 1) } }
            $r = Import-NeoIPCPlayData -Json (New-PlayImportJson @('ouAAAAAAAA1', 'ouZZZAAAAA1')) -Auth @{} -SkipRuleEngine:$false -Confirm:$false
            $r.Status | Should -Be 'ERROR'
            $r.Raw | Should -BeNullOrEmpty
        }
        It 'folds a non-2xx transport failure with no parseable report into ERROR' {
            Mock Invoke-NeoIPCDhis2Post { [pscustomobject]@{ StatusCode = 502; Body = $null } }
            $r = Import-NeoIPCPlayData -Json (New-PlayImportJson @('ouAAAAAAAA1')) -Auth @{} -SkipRuleEngine:$false -Confirm:$false
            $r.Status | Should -Be 'ERROR'
            $r.HttpStatusCode | Should -Be 502
            $r.ErrorMessage | Should -Match 'no parseable import report'
        }
        It 'reports WARNING (not ERROR) when a group warns and none error' {
            Mock Invoke-NeoIPCDhis2Post { [pscustomobject]@{ StatusCode = 200; Body = (New-WarningBody) } }
            $r = Import-NeoIPCPlayData -Json (New-PlayImportJson @('ouAAAAAAAA1')) -Auth @{} -SkipRuleEngine:$false -Confirm:$false
            $r.Status | Should -Be 'WARNING'
            $r.WarningReports.Count | Should -BeGreaterThan 0
        }
        It 'validates only (importMode=VALIDATE) under -DryRun' {
            Mock Invoke-NeoIPCDhis2Post { [pscustomobject]@{ StatusCode = 200; Body = (New-OkBody 0) } }
            $null = Import-NeoIPCPlayData -Json (New-PlayImportJson @('ouAAAAAAAA1')) -Auth @{} -SkipRuleEngine:$false -DryRun
            Should -Invoke Invoke-NeoIPCDhis2Post -Times 1 -Exactly -ParameterFilter { $QueryParameters.importMode -eq 'VALIDATE' }
        }
    }
}
