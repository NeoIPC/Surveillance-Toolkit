#Requires -Version 7.6

<#
.SYNOPSIS
    Pester tests for Get-NeoIPCDepartments and Read-OrgUnitInfo, and for the department list the report builders read.

.DESCRIPTION
    Covers Public/OrgUnits.ps1 and Private/OrgUnits.ps1, and the department step of scripts/Build-PartnerCertificate.ps1,
    scripts/Build-PartnerReport.ps1, scripts/Build-ValidationReport.ps1, and scripts/Update-NeoIPCCache.ps1.

    Self-contained: the DHIS2 reads go to a fake instance of two countries, each in a group of the group set
    WORLD_BANK_CLASSES, with hospitals and departments below them. One hospital lies below a region, and one department
    below a unit of its hospital, so that neither the parent nor the grandparent of a department is reliably its
    hospital or its country. A test unit hangs, flattened, below an org unit outside every country, and one department
    is in three groups of the group set NEOIPC_TRIALS. Two department codes differ only in case.

    The fake answers api/me with the capture units a test sets, and api/organisationUnits by applying the metadata
    filters it is sent and serializing only the fields it is asked for, each nested record cut down to the fields in the
    brackets after its name, and the ancestors root first, as DHIS2's field filter and OrganisationUnit.getAncestors do.
    Its code comparison ignores case, where DHIS2's does not, so the cmdlets' own exact comparison is what a test
    checks. It applies withinUserHierarchy=true the way DHIS2 does: 2.41 and earlier as the union of the capture units'
    subtrees, 2.42 and later as one condition per capture unit joined with AND, which matches nothing for an account
    with two or more capture units. Its answers pass through JSON the way the GET helper's do, so a read with
    -AsHashtable gets ordered dictionaries with the dates as text, and one without it objects with DateTime values; and
    like the GET helper, it reads nothing under an inherited -WhatIf. A minimal api/system/info and api/users serve the
    pipeline into Read-UserInfo.

    The report builders' department step is checked by parsing the scripts: every key a script puts into the hashtable
    it splats into Get-NeoIPCDepartments must be a parameter Get-NeoIPCDepartments declares. Running every builder
    instead would need Quarto, R, and their whole environment mocked, while parsing reaches all of them at once.
    Build-PartnerCertificate.ps1, whose department step decides what it renders, is also run, with the module's
    import, the authentication, the department list, and the render mocked: once given -Dhis2Path, and once with no
    department matching.

.EXAMPLE
    Invoke-Pester -Path scripts/modules/NeoIPC-Tools/Tests/OrgUnits.Tests.ps1
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..') -Force

InModuleScope 'NeoIPC-Tools' {
    Describe 'The departments and org-unit records of the caller''s hierarchy' {
        BeforeAll {
            $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
            $script:Auth = @{ AuthType = 'Token'; Token = 'not-a-real-token' }
            $script:Host1 = 'dhis2.example.org'
            $ordinal = [System.StringComparer]::Ordinal

            # The group set of each group that belongs to one.
            $script:GroupSets = [System.Collections.Generic.Dictionary[string, string]]::new($ordinal)
            foreach ($pair in @(('WB_HIGH', 'WORLD_BANK_CLASSES'), ('WB_LOW', 'WORLD_BANK_CLASSES'), ('TRIAL_X', 'NEOIPC_TRIALS'),
                    ('TRIAL_Y', 'NEOIPC_TRIALS'), ('trial_a', 'NEOIPC_TRIALS'))) {
                $script:GroupSets[$pair[0]] = $pair[1]
            }

            $script:BaseUnits = @(
                @{ id = 'OuRoot00001'; code = 'ROOT'; groups = @() }
                @{ id = 'OuCtryA0001'; code = 'COUNTRY_A'; parent = 'OuRoot00001'; groups = @('COUNTRY', 'WB_HIGH') }
                @{ id = 'OuHospA0001'; code = 'HOSP_A'; parent = 'OuCtryA0001'; groups = @('HOSPITAL') }
                @{ id = 'OuDeptA0001'; code = 'DEPT_A1'; parent = 'OuHospA0001'; groups = @('NEO_DEPARTMENT', 'TRIAL_Y', 'TRIAL_X', 'trial_a'); openingDate = '2020-01-15T00:00:00.000' }
                @{ id = 'OuDeptA0003'; code = 'Dept_a1'; parent = 'OuHospA0001'; groups = @('NEO_DEPARTMENT') }
                @{ id = 'OuUnitA0001'; code = 'UNIT_A'; parent = 'OuHospA0001'; groups = @() }
                @{ id = 'OuDeptA0004'; code = 'DEPT_A4'; parent = 'OuUnitA0001'; groups = @('NEO_DEPARTMENT') }
                @{ id = 'OuRegnA0001'; code = 'REGION_A'; parent = 'OuCtryA0001'; groups = @() }
                @{ id = 'OuHospA0002'; code = 'HOSP_A2'; parent = 'OuRegnA0001'; groups = @('HOSPITAL') }
                @{ id = 'OuDeptA0002'; code = 'DEPT_A2'; parent = 'OuHospA0002'; groups = @('NEO_DEPARTMENT') }
                @{ id = 'OuCtryB0001'; code = 'COUNTRY_B'; parent = 'OuRoot00001'; groups = @('COUNTRY', 'WB_LOW') }
                @{ id = 'OuHospB0001'; code = 'HOSP_B'; parent = 'OuCtryB0001'; groups = @('HOSPITAL') }
                @{ id = 'OuDeptB0001'; code = 'DEPT_B1'; parent = 'OuHospB0001'; groups = @('NEO_DEPARTMENT'); openingDate = '2019-03-01T00:00:00.000'; closedDate = '2024-06-30T00:00:00.000Z' }
                @{ id = 'OuWardB0001'; code = 'WARD_B'; parent = 'OuHospB0001'; groups = @() }
                @{ id = 'OuTestU0001'; code = 'TEST_UNITS'; parent = 'OuRoot00001'; groups = @() }
                @{ id = 'OuTestD0001'; code = 'TEST_DEPT'; parent = 'OuTestU0001'; groups = @('NEO_DEPARTMENT', 'TEST_UNITS') }
            )

            function Set-FakeUnit([object[]]$Rows) {
                $script:Units = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
                foreach ($r in $Rows) {
                    $script:Units[$r.id] = @{ id = $r.id; code = $r.code; parent = $r.parent; groups = [string[]]@($r.groups); name = "Unit $($r.id)"
                        openingDate = $r.openingDate; closedDate = $r.closedDate }
                }
            }

            # A unit as DHIS2 holds it, before the field filter: its ancestors root first, each without ancestors of its own.
            function Get-FakeUnitRecord([string]$Id, [switch]$WithoutAncestors) {
                $u = $script:Units[$Id]
                $chain = [System.Collections.Generic.List[string]]::new()
                for ($p = $u.parent; $p; $p = $script:Units[$p].parent) { $chain.Insert(0, $p) }
                $record = [ordered]@{
                    id = $u.id; code = $u.code; name = $u.name; level = $chain.Count + 1; path = '/' + ((@($chain) + $u.id) -join '/')
                    openingDate = $u.openingDate; closedDate = $u.closedDate
                    organisationUnitGroups = @($u.groups | ForEach-Object {
                            [ordered]@{ code = $_; groupSets = @(if ($script:GroupSets.ContainsKey($_)) { [ordered]@{ code = $script:GroupSets[$_] } }) }
                        })
                }
                if (-not $WithoutAncestors) { $record['ancestors'] = @($chain | ForEach-Object { Get-FakeUnitRecord $_ -WithoutAncestors }) }
                $record
            }

            # The top-level fields of a DHIS2 field list, split at the commas outside brackets.
            function Split-FakeFieldList([string]$Text) {
                $parts = [System.Collections.Generic.List[string]]::new()
                $depth = 0
                $start = 0
                for ($i = 0; $i -lt $Text.Length; $i++) {
                    if ($Text[$i] -eq [char]'[') { $depth++ }
                    elseif ($Text[$i] -eq [char]']') { $depth-- }
                    elseif ($Text[$i] -eq [char]',' -and $depth -eq 0) { $parts.Add($Text.Substring($start, $i - $start)); $start = $i + 1 }
                }
                $parts.Add($Text.Substring($start))
                $parts
            }

            # A record cut down to the fields DHIS2's field filter serializes: the named ones, and a nested record or list of
            # records cut down to the fields in the brackets after its name. A field without a value is left out.
            function Select-FakeField($Record, [string[]]$Fields) {
                $out = [ordered]@{}
                foreach ($field in $Fields) {
                    $open = $field.IndexOf('[')
                    $name = if ($open -ge 0) { $field.Substring(0, $open) } else { $field }
                    if (-not $Record.Contains($name) -or $null -eq $Record[$name]) { continue }
                    $value = $Record[$name]
                    if ($open -ge 0) {
                        $inner = [string[]]@(Split-FakeFieldList $field.Substring($open + 1, $field.Length - $open - 2))
                        $value = if ($value -is [System.Collections.IList]) { @($value | ForEach-Object { Select-FakeField $_ $inner }) } else { Select-FakeField $value $inner }
                    }
                    $out[$name] = $value
                }
                $out
            }

            # Whether a unit passes a metadata filter. Looser than DHIS2, which compares codes exactly: a code differing in
            # case passes, and the cmdlet must not take it.
            function Test-FakeFilter($Record, [string]$Filter) {
                $property, $operator, $value = $Filter -split ':', 3
                $list = if ($operator -eq 'in') { @($value.TrimStart('[').TrimEnd(']') -split ',') }
                switch ("${property}:$operator") {
                    'path:like' { return $Record.path.Contains($value, [System.StringComparison]::Ordinal) }
                    'code:in' { return @($list | Where-Object { [string]::Equals($_, $Record.code, [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0 }
                    'code:eq' { return [string]::Equals($value, $Record.code, [System.StringComparison]::OrdinalIgnoreCase) }
                    'id:in' { return $list -ccontains $Record.id }
                    'organisationUnitGroups.code:eq' { return @($Record.organisationUnitGroups | ForEach-Object { $_.code }) -ccontains $value }
                    default { throw "The fake does not read the filter '$Filter'." }
                }
            }

            # What the GET helper returns for an answer: parsed from JSON, as ordered dictionaries with the dates as text
            # under -AsHashtable, else as objects with DateTime values.
            function ConvertTo-FakeAnswer($Answer, [bool]$AsHashtable) {
                $json = $Answer | ConvertTo-Json -Depth 100 -Compress
                if ($AsHashtable) { return ($json | ConvertFrom-Json -AsHashtable -DateKind String) }
                $json | ConvertFrom-Json
            }

            # The users of the minimal api/users: one per department, named after it.
            function Get-FakeUserAnswer([string[]]$Filter) {
                $users = @($script:Units.Values | Where-Object { $_.groups -ccontains 'NEO_DEPARTMENT' } | ForEach-Object {
                        [ordered]@{ id = ('Usr' + $_.id.Substring(3)); username = "user_$($_.code)"; organisationUnits = @([ordered]@{ code = $_.code }) }
                    })
                foreach ($f in @($Filter | Where-Object { $_ })) {
                    if ($f -notmatch '^organisationUnits\.code:in:\[(.*)\]$') { throw "The fake does not read the user filter '$f'." }
                    $list = $Matches[1] -split ','
                    $users = @($users | Where-Object { $list -ccontains $_.organisationUnits[0].code })
                }
                [ordered]@{ users = $users }
            }

            function Get-Message($Records) { @($Records | ForEach-Object { "$_" }) }
        }

        BeforeEach {
            Set-FakeUnit $script:BaseUnits
            $script:Version = '2.43.2'
            $script:Capture = @('OuCtryA0001', 'OuCtryB0001')
            $script:FailRead = $false
            $script:Requests = [System.Collections.Generic.List[object]]::new()
            Mock Invoke-WebRequest { throw 'A test made an HTTP call.' }
            Mock Invoke-RestMethod { throw 'A test made an HTTP call.' }
            Mock Invoke-NeoIPCDhis2Get {
                if ($WhatIfPreference) { return }
                $script:Requests.Add([pscustomobject]@{ Path = $Path; Filter = @($Filter); Fields = @($Fields); Query = $QueryParameters })
                if ($script:FailRead) { throw "Failed to fetch '$Path' from DHIS2: 503 (Service Unavailable)" }
                $answer = switch ($Path) {
                    'api/system/info' { [ordered]@{ version = $script:Version } }
                    'api/me' {
                        [ordered]@{ organisationUnits = @($script:Capture | ForEach-Object { $r = Get-FakeUnitRecord $_; [ordered]@{ id = $r.id; path = $r.path } }) }
                    }
                    'api/organisationUnits' {
                        $rows = @($script:Units.Keys | ForEach-Object { Get-FakeUnitRecord $_ })
                        foreach ($f in @($Filter)) { $rows = @($rows | Where-Object { Test-FakeFilter $_ $f }) }
                        if ($QueryParameters -and $QueryParameters['withinUserHierarchy'] -eq 'true') {
                            $capture = @($script:Capture)
                            $rows = if ((ConvertTo-NeoIPCDhis2Version -Text $script:Version) -ge [version]'2.42.0') {
                                # One condition per capture unit, joined with AND.
                                @($rows | Where-Object { $r = $_; @($capture | Where-Object { -not $r.path.Contains($_) }).Count -eq 0 })
                            }
                            else {
                                @($rows | Where-Object { $r = $_; @($capture | Where-Object { $r.path.Contains($_) }).Count -gt 0 })
                            }
                        }
                        $specs = [string[]]@($Fields | ForEach-Object { Split-FakeFieldList $_ })
                        [ordered]@{ organisationUnits = @($rows | ForEach-Object { Select-FakeField $_ $specs }) }
                    }
                    'api/users' { Get-FakeUserAnswer $Filter }
                    default { throw "Unexpected GET $Path" }
                }
                ConvertTo-FakeAnswer $answer $AsHashtable.IsPresent
            }
        }

        Describe 'Get-NeoIPCDepartments' {
            It 'lists the departments below each of several capture units on DHIS2 <Version>, codes differing in case apart and in ordinal order' -ForEach @(
                @{ Version = '2.40.12' }
                @{ Version = '2.41.10' }
                @{ Version = '2.42.0' }
                @{ Version = '2.42.6' }
                @{ Version = '2.43.2' }
            ) {
                $script:Version = $Version
                $codes = Get-NeoIPCDepartments -Auth $script:Auth -Hostname $script:Host1
                @($codes) | Should -BeExactly @('DEPT_A1', 'DEPT_A2', 'DEPT_A4', 'DEPT_B1', 'Dept_a1')
                @($script:Requests | Where-Object { $_.Query -and $_.Query.ContainsKey('withinUserHierarchy') }).Count | Should -Be 0
                @($script:Requests | Where-Object { $_.Path -eq 'api/organisationUnits' } | ForEach-Object { $_.Filter[0] }) |
                    Should -BeExactly @('path:like:OuCtryA0001', 'path:like:OuCtryB0001')
            }

            It 'leaves out a department in the group TEST_UNITS with -ExcludeTestUnits, and only then' {
                $script:Capture = @('OuRoot00001')
                @(Get-NeoIPCDepartments -Auth $script:Auth -Hostname $script:Host1) | Should -Contain 'TEST_DEPT'
                @(Get-NeoIPCDepartments -Auth $script:Auth -Hostname $script:Host1 -ExcludeTestUnits) |
                    Should -BeExactly @('DEPT_A1', 'DEPT_A2', 'DEPT_A4', 'DEPT_B1', 'Dept_a1')
            }

            It 'matches -SiteCodeFilter as a regular expression that ignores case' {
                @(Get-NeoIPCDepartments -Auth $script:Auth -Hostname $script:Host1 -SiteCodeFilter '^dept_a\d$') |
                    Should -BeExactly @('DEPT_A1', 'DEPT_A2', 'DEPT_A4', 'Dept_a1')
            }

            It 'warns about a department without a code, which it cannot list' {
                Set-FakeUnit ($script:BaseUnits + @{ id = 'OuNoCode001'; parent = 'OuHospB0001'; groups = @('NEO_DEPARTMENT') })
                $codes = Get-NeoIPCDepartments -Auth $script:Auth -Hostname $script:Host1 -WarningVariable warnings -WarningAction SilentlyContinue
                @($codes) | Should -BeExactly @('DEPT_A1', 'DEPT_A2', 'DEPT_A4', 'DEPT_B1', 'Dept_a1')
                Get-Message $warnings | Should -BeLike '*without a code*OuNoCode001*'
            }

            It 'reads the departments under an inherited -WhatIf, as the report builders'' previews need' {
                $WhatIfPreference = $true
                @(Get-NeoIPCDepartments -Auth $script:Auth -Hostname $script:Host1) | Should -BeExactly @('DEPT_A1', 'DEPT_A2', 'DEPT_A4', 'DEPT_B1', 'Dept_a1')
            }

            It 'ends a failed read with an error naming the department list' {
                $script:FailRead = $true
                { Get-NeoIPCDepartments -Auth $script:Auth -Hostname $script:Host1 } | Should -Throw 'Failed to fetch department list from DHIS2: *503*'
            }
        }

        Describe 'Read-OrgUnitInfo' {
            It 'returns every department below several capture units on DHIS2 <Version>, with hospital and country by group code' -ForEach @(
                @{ Version = '2.40.12' }
                @{ Version = '2.41.10' }
                @{ Version = '2.42.0' }
                @{ Version = '2.42.6' }
                @{ Version = '2.43.2' }
            ) {
                $script:Version = $Version
                $records = @(Read-OrgUnitInfo -Auth $script:Auth -Hostname $script:Host1)
                @($records | ForEach-Object { $_.OrgUnitCode }) | Should -BeExactly @('DEPT_A1', 'DEPT_A2', 'DEPT_A4', 'DEPT_B1', 'Dept_a1')
                $context = @($records | ForEach-Object { "$($_.OrgUnitCode): $($_.HospitalCode) $($_.CountryCode) $($_.WorldBankClass)" })
                $context | Should -BeExactly @(
                    'DEPT_A1: HOSP_A COUNTRY_A WB_HIGH'
                    # A region lies between the hospital and the country.
                    'DEPT_A2: HOSP_A2 COUNTRY_A WB_HIGH'
                    # A unit of the hospital lies between it and the department.
                    'DEPT_A4: HOSP_A COUNTRY_A WB_HIGH'
                    'DEPT_B1: HOSP_B COUNTRY_B WB_LOW'
                    'Dept_a1: HOSP_A COUNTRY_A WB_HIGH'
                )
                @($script:Requests | Where-Object { $_.Query -and $_.Query.ContainsKey('withinUserHierarchy') }).Count | Should -Be 0
            }

            It 'gives a flattened test unit empty hospital and country codes, and IsTestUnit from its own group' {
                $script:Capture = @('OuRoot00001')
                $records = @(Read-OrgUnitInfo -Auth $script:Auth -Hostname $script:Host1)
                $test = $records | Where-Object { $_.OrgUnitCode -ceq 'TEST_DEPT' }
                $test.IsTestUnit | Should -BeTrue
                $test.HospitalCode | Should -BeNullOrEmpty
                $test.CountryCode | Should -BeNullOrEmpty
                $test.WorldBankClass | Should -BeNullOrEmpty
                ($records | Where-Object { $_.OrgUnitCode -ceq 'DEPT_A1' }).IsTestUnit | Should -BeFalse
            }

            It 'lists the department''s groups of the group set NEOIPC_TRIALS as TrialCodes, in ordinal order' {
                $records = @(Read-OrgUnitInfo -Auth $script:Auth -Hostname $script:Host1 -OrgUnitCode 'DEPT_A1', 'DEPT_B1')
                $a1 = $records | Where-Object { $_.OrgUnitCode -ceq 'DEPT_A1' }
                $b1 = $records | Where-Object { $_.OrgUnitCode -ceq 'DEPT_B1' }
                , $a1.TrialCodes | Should -BeOfType [string[]]
                $a1.TrialCodes | Should -BeExactly @('TRIAL_X', 'TRIAL_Y', 'trial_a')
                , $b1.TrialCodes | Should -BeOfType [string[]]
                $b1.TrialCodes.Count | Should -Be 0
            }

            It 'returns the opening and closing dates as DateTime' {
                $records = @(Read-OrgUnitInfo -Auth $script:Auth -Hostname $script:Host1 -OrgUnitCode 'DEPT_A1', 'DEPT_B1')
                $a1 = $records | Where-Object { $_.OrgUnitCode -ceq 'DEPT_A1' }
                $b1 = $records | Where-Object { $_.OrgUnitCode -ceq 'DEPT_B1' }
                $a1.OpeningDate | Should -BeOfType [datetime]
                $a1.OpeningDate | Should -Be ([datetime]::new(2020, 1, 15))
                $a1.ClosedDate | Should -BeNullOrEmpty
                $b1.ClosedDate.ToUniversalTime() | Should -Be ([datetime]::new(2024, 6, 30, 0, 0, 0, [System.DateTimeKind]::Utc))
            }

            It 'writes an error naming a code outside the hierarchy, and reads nothing more' {
                $records = @(Read-OrgUnitInfo -Auth $script:Auth -Hostname $script:Host1 -OrgUnitCode 'NOPE' -ErrorVariable failures -ErrorAction SilentlyContinue)
                $records.Count | Should -Be 0
                @($failures).Count | Should -Be 1
                $failures[0].CategoryInfo.Category | Should -Be 'ObjectNotFound'
                $failures[0].TargetObject | Should -BeExactly 'NOPE'
                "$($failures[0])" | Should -BeLike "*'NOPE'*"
                $reads = @($script:Requests | Where-Object { $_.Path -eq 'api/organisationUnits' })
                @($reads | Where-Object { $_.Filter -cnotcontains 'code:in:[NOPE]' }).Count | Should -Be 0
            }

            It 'writes an error naming a UID outside the hierarchy' {
                $script:Capture = @('OuCtryA0001')
                $records = @(Read-OrgUnitInfo -Auth $script:Auth -Hostname $script:Host1 -OrgUnitId 'OuDeptB0001', 'OuDeptA0002' -ErrorVariable failures -ErrorAction SilentlyContinue)
                @($records | ForEach-Object { $_.OrgUnitCode }) | Should -BeExactly @('DEPT_A2')
                @($failures).Count | Should -Be 1
                $failures[0].TargetObject | Should -BeExactly 'OuDeptB0001'
            }

            It 'writes an error naming an org unit that is not a department, and returns the departments' {
                $records = @(Read-OrgUnitInfo -Auth $script:Auth -Hostname $script:Host1 -OrgUnitCode 'WARD_B', 'DEPT_B1' -ErrorVariable failures -ErrorAction SilentlyContinue)
                @($records | ForEach-Object { $_.OrgUnitCode }) | Should -BeExactly @('DEPT_B1')
                @($failures).Count | Should -Be 1
                $failures[0].TargetObject | Should -BeExactly 'WARD_B'
                "$($failures[0])" | Should -BeLike '*not a department*'
            }

            It 'keeps codes that differ only in case apart' {
                $records = @(Read-OrgUnitInfo -Auth $script:Auth -Hostname $script:Host1 -OrgUnitCode 'Dept_a1')
                @($records | ForEach-Object { $_.OrgUnitId }) | Should -BeExactly @('OuDeptA0003')
            }

            It 'selects the departments that piped objects name by OrgUnitId or OrgUnitCode' {
                $records = @([pscustomobject]@{ OrgUnitId = 'OuDeptB0001' }, [pscustomobject]@{ OrgUnitCode = 'DEPT_A2' } |
                        Read-OrgUnitInfo -Auth $script:Auth -Hostname $script:Host1)
                @($records | ForEach-Object { $_.OrgUnitCode }) | Should -BeExactly @('DEPT_A2', 'DEPT_B1')
            }

            It 'returns nothing and reads nothing for an empty pipeline' {
                $records = @(@() | Read-OrgUnitInfo -Auth $script:Auth -Hostname $script:Host1)
                $records.Count | Should -Be 0
                $script:Requests.Count | Should -Be 0
            }

            It 'keeps the departments whose CountryCode is -CountryCode, compared exactly, and warns when none is left' {
                @(Read-OrgUnitInfo -Auth $script:Auth -Hostname $script:Host1 -CountryCode 'COUNTRY_A' | ForEach-Object { $_.OrgUnitCode }) |
                    Should -BeExactly @('DEPT_A1', 'DEPT_A2', 'DEPT_A4', 'Dept_a1')
                $records = @(Read-OrgUnitInfo -Auth $script:Auth -Hostname $script:Host1 -CountryCode 'country_a' -WarningVariable warnings -WarningAction SilentlyContinue)
                $records.Count | Should -Be 0
                Get-Message $warnings | Should -BeLike "*'country_a'*"
            }

            It 'reads the departments under an inherited -WhatIf' {
                $WhatIfPreference = $true
                @(Read-OrgUnitInfo -Auth $script:Auth -Hostname $script:Host1).Count | Should -Be 5
            }

            It 'keeps the codes piped into it to itself, so that Read-UserInfo after it reads no users when it returns none' {
                $script:Version = '2.41.10'
                Mock Resolve-NeoIPCAuth { $script:Auth }
                $users = @([pscustomobject]@{ OrgUnitCode = 'DEPT_A1' } |
                        Read-OrgUnitInfo -Hostname $script:Host1 -CountryCode 'COUNTRY_B' -WarningAction SilentlyContinue |
                        Read-UserInfo -Hostname $script:Host1 -WarningAction SilentlyContinue)
                $users.Count | Should -Be 0
                @($script:Requests | Where-Object { $_.Path -eq 'api/users' }).Count | Should -Be 0
            }
        }

        Describe 'The comment-based help' {
            It 'describes every parameter of <Name>' -ForEach @(
                @{ Name = 'Get-NeoIPCDepartments' }
                @{ Name = 'Read-OrgUnitInfo' }
            ) {
                $help = Get-Help $Name -Full
                @($help.parameters.parameter).Count | Should -BeGreaterThan 0
                @($help.parameters.parameter | Where-Object { -not $_.description } | ForEach-Object { $_.name }) | Should -BeNullOrEmpty
            }
        }

        Describe 'The report builders'' department step' {
            It '<Name> puts into the hashtable it splats into Get-NeoIPCDepartments only parameters that Get-NeoIPCDepartments declares' -ForEach @(
                @{ Name = 'Build-PartnerCertificate.ps1' }
                @{ Name = 'Build-PartnerReport.ps1' }
                @{ Name = 'Build-ValidationReport.ps1' }
                @{ Name = 'Update-NeoIPCCache.ps1' }
            ) {
                $parseErrors = $null
                $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoRoot 'scripts' $Name), [ref]$null, [ref]$parseErrors)
                @($parseErrors).Count | Should -Be 0
                $declared = @((Get-Command Get-NeoIPCDepartments).Parameters.Keys)
                $calls = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Get-NeoIPCDepartments' }, $true))
                $calls.Count | Should -BeGreaterThan 0
                foreach ($call in $calls) {
                    $splatted = @($call.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.VariableExpressionAst] -and $_.Splatted } | ForEach-Object { $_.VariablePath.UserPath })
                    $splatted.Count | Should -Be 1
                    $keys = [System.Collections.Generic.List[string]]::new()
                    foreach ($assignment in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
                        $left = $assignment.Left
                        if ($left -is [System.Management.Automation.Language.VariableExpressionAst] -and $left.VariablePath.UserPath -eq $splatted[0]) {
                            foreach ($table in $assignment.Right.FindAll({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true)) {
                                foreach ($pair in $table.KeyValuePairs) { $keys.Add([string]$pair.Item1.SafeGetValue()) }
                            }
                        }
                        elseif ($left -is [System.Management.Automation.Language.MemberExpressionAst] -and $left.Expression -is [System.Management.Automation.Language.VariableExpressionAst] -and
                            $left.Expression.VariablePath.UserPath -eq $splatted[0]) {
                            $keys.Add([string]$left.Member.SafeGetValue())
                        }
                        elseif ($left -is [System.Management.Automation.Language.IndexExpressionAst] -and $left.Target -is [System.Management.Automation.Language.VariableExpressionAst] -and
                            $left.Target.VariablePath.UserPath -eq $splatted[0]) {
                            $keys.Add([string]$left.Index.SafeGetValue())
                        }
                    }
                    $keys.Count | Should -BeGreaterThan 0
                    @($keys | Where-Object { $_ -notin $declared }) | Should -BeNullOrEmpty -Because "Get-NeoIPCDepartments declares $($declared -join ', ')"
                }
            }

            Context 'Build-PartnerCertificate.ps1, run with its import, authentication, department list, and render mocked' {
                BeforeEach {
                    $script:Certificate = Join-Path $script:RepoRoot 'scripts' 'Build-PartnerCertificate.ps1'
                    $script:Signature = Join-Path $TestDrive 'signature.png'
                    [System.IO.File]::WriteAllBytes($script:Signature, [byte[]](1, 2, 3))
                    Mock Import-Module { }
                    Mock Resolve-NeoIPCAuth { @{ AuthType = 'None' } }
                    Mock Get-NeoIPCDepartments { 'DEPT_A1', 'DEPT_B1' }
                    Mock Invoke-QuartoRender { [pscustomobject]@{ Status = 'Success'; ExitCode = 0; Messages = @() } }
                }

                It 'renders the certificate of a build given -Dhis2Path, which reaches the render and not the department list' {
                    $null = & $script:Certificate 'A. Signatory' $script:Signature -DepartmentCode '^DEPT_A1$' -Dhis2Hostname $script:Host1 `
                        -Dhis2Path '/dhis/api' -OutputDir (Join-Path $TestDrive 'out') -WarningAction SilentlyContinue 6>$null
                    Should -Invoke Get-NeoIPCDepartments -Times 1 -Exactly
                    Should -Invoke Invoke-QuartoRender -Times 1 -Exactly -ParameterFilter { $Arguments -ccontains 'departmentCode:DEPT_A1' -and $Arguments -ccontains 'dhis2Path:/dhis/api' }
                }

                It 'warns, renders nothing, and reports the build as cancelled when no department matches' {
                    $hostLines = & $script:Certificate 'A. Signatory' $script:Signature -DepartmentCode 'NOPE' -Dhis2Hostname $script:Host1 `
                        -OutputDir (Join-Path $TestDrive 'out') -WarningVariable warnings -WarningAction SilentlyContinue 6>&1
                    Get-Message $warnings | Should -BeLike "*No department matched -DepartmentCode 'NOPE'*"
                    Should -Invoke Invoke-QuartoRender -Times 0 -Exactly
                    @(Get-Message $hostLines) | Should -Contain 'Build status: cancelled'
                }
            }

            It '<Name> says in its help where -Dhis2Path takes effect' -ForEach @(
                @{ Name = 'Build-PartnerCertificate.ps1' }
                @{ Name = 'Build-PartnerReport.ps1' }
                @{ Name = 'Build-ValidationReport.ps1' }
            ) {
                $help = Get-Help (Join-Path $script:RepoRoot 'scripts' $Name) -Full
                $text = @($help.parameters.parameter | Where-Object { $_.name -eq 'Dhis2Path' } | ForEach-Object { $_.description.Text }) -join ' '
                $text | Should -BeLike '*/api*'
            }
        }
    }
}
