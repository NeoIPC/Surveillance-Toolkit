#Requires -Version 7.6

<#
.SYNOPSIS
    Pester tests for Read-UserInfo.

.DESCRIPTION
    Covers Public/UserInfo.ps1 and Private/UserInfo.ps1.

    Self-contained: the DHIS2 reads go to a fake instance that models what the source of 2.40.12, 2.41.10, 2.42.0,
    2.42.6, 2.43.1, and 2.43.2 says of reading users. api/system/info names the release. api/users applies the
    org-unit code filters it is sent, comparing codes exactly as DHIS2 does (InOperator.equals in memory, SQL IN in the
    database), and serializes only the fields it is asked for; before 2.42 that includes twoFactorEnabled, which counts
    a pending enrolment in time-based one-time passwords (TOTP) as enabled, and from 2.42.0 never. api/users/twoFactor exists from 2.42.6 in the 2.42
    line and from 2.43.1 in the 2.43 line, answers 403 to an account without the authority ALL when a test says so,
    lists only active accounts (neither disabled nor an invitation) with their twoFactorType, and caps its answer at
    the number of accounts a test sets, its pager counting them all. api/me and api/organisationUnits serve the lookup
    of the org-unit codes in the caller's hierarchy; there, the fake's code comparison ignores case, where DHIS2's does
    not, so the lookup's own exact comparison is what a test checks. Like the GET helper, the fake reads nothing under
    an inherited -WhatIf, and a refusal ends the read with the helper's error.

    The accounts: alice (TOTP enabled), Bob (enrolling in TOTP, which 2.41 already reports as enabled), carol (not
    enabled), dave (disabled), erin (an open invitation), and frank (email two-factor authentication, assigned to an
    org unit outside the caller's hierarchy).

.EXAMPLE
    Invoke-Pester -Path scripts/modules/NeoIPC-Tools/Tests/UserInfo.Tests.ps1
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..') -Force

InModuleScope 'NeoIPC-Tools' {
    Describe 'Read-UserInfo' {
        BeforeAll {
            $script:Auth = @{ AuthType = 'Token'; Token = 'not-a-real-token' }
            $script:Host1 = 'dhis2.example.org'

            $script:BaseOrgUnits = @(
                @{ id = 'OuRoot00001'; code = 'ROOT'; path = '/OuRoot00001' }
                @{ id = 'OuDeptA0001'; code = 'DEPT_A1'; path = '/OuRoot00001/OuHospA0001/OuDeptA0001' }
                @{ id = 'OuDeptA0003'; code = 'Dept_a1'; path = '/OuRoot00001/OuHospA0001/OuDeptA0003' }
                @{ id = 'OuDeptB0001'; code = 'DEPT_B1'; path = '/OuRoot00001/OuHospB0001/OuDeptB0001' }
                @{ id = 'OuOutside01'; code = 'OUTSIDE'; path = '/OuOther0001/OuOutside01' }
            )
            $script:BaseUsers = @(
                @{ id = 'UsrAlice001'; username = 'alice'; ou = @('DEPT_A1'); roles = @('beta', 'Alpha', 'alpha'); groups = @('Group b', 'Group A'); field = $true; type = 'TOTP_ENABLED' }
                @{ id = 'UsrBob00001'; username = 'Bob'; ou = @('DEPT_B1', 'DEPT_A1'); field = $true; type = 'ENROLLING_TOTP' }
                @{ id = 'UsrCarol001'; username = 'carol'; ou = @('Dept_a1'); field = $false; type = 'NOT_ENABLED' }
                @{ id = 'UsrDave0001'; username = 'dave'; ou = @('DEPT_B1'); disabled = $true; field = $true; type = 'TOTP_ENABLED' }
                @{ id = 'UsrErin0001'; username = 'erin'; ou = @('DEPT_B1'); invitation = $true; field = $false }
                @{ id = 'UsrFrank001'; username = 'frank'; ou = @('OUTSIDE'); field = $false; type = 'EMAIL_ENABLED' }
            )

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

            function Get-FakeVersion { ConvertTo-NeoIPCDhis2Version -Text $script:Fake.Version }

            function Test-FakeAuditEndpoint {
                $v = Get-FakeVersion
                if ($v -lt [version]'2.42.6') { return $false }
                -not ($v.Major -eq 2 -and $v.Minor -eq 43 -and $v -lt [version]'2.43.1')
            }

            # A user as DHIS2 holds it, before the field filter.
            function Get-FakeUserRecord($User) {
                $orgUnit = { param($code) [ordered]@{ id = $script:Fake.OrgUnitIdByCode[$code]; code = $code } }
                $by = [ordered]@{ id = 'UsrAdmin001'; code = $null; name = 'Admin'; displayName = 'Admin'; username = 'admin' }
                $record = [ordered]@{
                    id = $User.id; username = $User.username; firstName = "First $($User.username)"; surname = 'Example'
                    email = "$($User.username)@example.org"; employer = 'Example Hospital'
                    created = '2024-01-02T03:04:05.678'; createdBy = $by; lastUpdated = '2024-02-03T04:05:06.789'; lastUpdatedBy = $by
                    passwordLastUpdated = '2024-01-02T03:04:05.678'; lastLogin = '2024-03-04T05:06:07.890'
                    invitation = [bool]$User.invitation; disabled = [bool]$User.disabled; selfRegistered = $false
                    userRoles = @($User.roles | ForEach-Object { [ordered]@{ id = "Rol$($_)"; name = $_ } })
                    userGroups = @($User.groups | ForEach-Object { [ordered]@{ id = "Grp$($_)"; name = $_ } })
                    organisationUnits = @($User.ou | ForEach-Object { & $orgUnit $_ })
                    dataViewOrganisationUnits = @($User.ou | ForEach-Object { & $orgUnit $_ })
                    teiSearchOrganisationUnits = @()
                }
                # NEOIPC-COMPAT(dhis2-user-twofactorenabled): the fake's model of 2.41 and earlier.
                if ((Get-FakeVersion) -lt [version]'2.42.0') { $record['twoFactorEnabled'] = [bool]$User.field }
                $record
            }

            function Select-FakeUser([string[]]$Filter) {
                $rows = @($script:Fake.Users)
                foreach ($f in @($Filter | Where-Object { $_ })) {
                    if ($f -match '^organisationUnits\.code:in:\[(.*)\]$') { $list = $Matches[1] -split ',' }
                    elseif ($f -match '^organisationUnits\.code:eq:(.*)$') { $list = @($Matches[1]) }
                    else { throw "The fake does not read the user filter '$f'." }
                    $rows = @($rows | Where-Object { @($_.ou | Where-Object { $list -ccontains $_ }).Count -gt 0 })
                }
                $rows
            }

            function Select-FakeOrgUnit([string[]]$Filter) {
                $rows = @($script:Fake.OrgUnits)
                foreach ($f in @($Filter | Where-Object { $_ })) {
                    $property, $operator, $value = $f -split ':', 3
                    $list = if ($operator -eq 'in') { @($value.TrimStart('[').TrimEnd(']') -split ',') }
                    $rows = @($rows | Where-Object {
                            $row = $_
                            switch ("${property}:$operator") {
                                'path:like' { $row.path.Contains($value, [System.StringComparison]::Ordinal) }
                                'code:in' { @($list | Where-Object { [string]::Equals($_, $row.code, [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0 }
                                'code:eq' { [string]::Equals($value, $row.code, [System.StringComparison]::OrdinalIgnoreCase) }
                                default { throw "The fake does not read the filter '$f'." }
                            }
                        })
                }
                $rows
            }

            function Get-Message($Records) { @($Records | ForEach-Object { "$_" }) }

            # The users' TwoFactorEnabled values, in the order the cmdlet returns them.
            function Get-TwoFactorText($Users) { (@($Users) | ForEach-Object { "$($_.Username)=$($_.TwoFactorEnabled)" }) -join ' ' }

            function Get-FakeRequest([string]$Path) { @($script:Fake.Requests | Where-Object { $_.Path -eq $Path }) }
        }

        BeforeEach {
            $script:Fake = [pscustomobject]@{
                Version         = '2.43.2'
                OrgUnits        = [System.Collections.Generic.List[object]]::new()
                OrgUnitIdByCode = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
                Users           = [System.Collections.Generic.List[object]]::new()
                Capture         = @('OuRoot00001')
                UsersStatus     = 0
                TwoFactorStatus = 0
                TwoFactorCap    = 10000
                Requests        = [System.Collections.Generic.List[object]]::new()
            }
            foreach ($u in $script:BaseOrgUnits) { $script:Fake.OrgUnits.Add($u); $script:Fake.OrgUnitIdByCode[$u.code] = $u.id }
            foreach ($u in $script:BaseUsers) { $script:Fake.Users.Add($u) }

            Mock Invoke-WebRequest { throw 'A test made an HTTP call.' }
            Mock Invoke-RestMethod { throw 'A test made an HTTP call.' }
            Mock Invoke-NeoIPCDhis2Get {
                if ($WhatIfPreference) { return }
                $script:Fake.Requests.Add([pscustomobject]@{ Path = $Path; Filter = @($Filter); Fields = @($Fields); Auth = $Auth; AsHashtable = $AsHashtable.IsPresent })
                $refuse = { param([int]$Status, [string]$Message) throw (New-NeoIPCDhis2HttpError -Method 'GET' -Path $Path -StatusCode $Status -Message $Message) }
                $answer = switch ($Path) {
                    'api/system/info' { [ordered]@{ version = $script:Fake.Version } }
                    'api/me' {
                        [ordered]@{ organisationUnits = @($script:Fake.Capture | ForEach-Object { $id = $_; $u = $script:Fake.OrgUnits | Where-Object { $_.id -ceq $id }; [ordered]@{ id = $u.id; path = $u.path } }) }
                    }
                    'api/organisationUnits' {
                        [ordered]@{ organisationUnits = @(Select-FakeOrgUnit $Filter | ForEach-Object { [ordered]@{ id = $_.id; code = $_.code; path = $_.path } }) }
                    }
                    'api/users' {
                        if ($script:Fake.UsersStatus) { & $refuse $script:Fake.UsersStatus 'You don''t have the proper permissions to read objects of this type.' }
                        $specs = [string[]]@($Fields | ForEach-Object { Split-FakeFieldList $_ })
                        [ordered]@{ users = @(Select-FakeUser $Filter | ForEach-Object { Select-FakeField (Get-FakeUserRecord $_) $specs }) }
                    }
                    'api/users/twoFactor' {
                        # Before the endpoint, UserController reads 'twoFactor' as a user UID.
                        if (-not (Test-FakeAuditEndpoint)) { & $refuse 404 'User with id twoFactor could not be found.' }
                        if ($script:Fake.TwoFactorStatus) { & $refuse $script:Fake.TwoFactorStatus 'Access is denied' }
                        $active = @($script:Fake.Users | Where-Object { -not $_.disabled -and -not $_.invitation })
                        $sorted = [string[]]@($active | ForEach-Object { $_.username })
                        [Array]::Sort($sorted, [System.StringComparer]::Ordinal)
                        $listed = @($sorted | Select-Object -First $script:Fake.TwoFactorCap | ForEach-Object {
                                $name = $_
                                $u = $active | Where-Object { $_.username -ceq $name }
                                [ordered]@{ id = $u.id; username = $u.username; name = "First $($u.username) Example"
                                    twoFactorType = $(if ($u.type) { $u.type } else { 'NOT_ENABLED' }); lastLogin = '2024-03-04T05:06:07.890'
                                    email = "$($u.username)@example.org"; disabled = $false; invitation = $false }
                            })
                        [ordered]@{ pager = [ordered]@{ page = 1; total = $active.Count; pageSize = [Math]::Max(1, $listed.Count); pageCount = 1 }; users = $listed }
                    }
                    default { throw "Unexpected GET $Path" }
                }
                $json = $answer | ConvertTo-Json -Depth 100 -Compress
                if ($AsHashtable) { return ($json | ConvertFrom-Json -AsHashtable -DateKind String) }
                $json | ConvertFrom-Json
            }
        }

        Describe 'TwoFactorEnabled' {
            It 'comes on DHIS2 <Version> from <Source>' -ForEach @(
                # NEOIPC-COMPAT(dhis2-user-twofactorenabled): the field of 2.41 and earlier, which counts Bob's pending
                # enrolment as enabled.
                @{ Version = '2.40.12'; Source = 'the user''s twoFactorEnabled field'; Field = $true; Audit = $false; Floor = $false
                    Expected = 'Bob=True alice=True carol=False dave=True erin=False frank=False' }
                @{ Version = '2.41.10'; Source = 'the user''s twoFactorEnabled field'; Field = $true; Audit = $false; Floor = $false
                    Expected = 'Bob=True alice=True carol=False dave=True erin=False frank=False' }
                # NEOIPC-COMPAT(dhis2-user-twofactor-audit-floor): the releases that show no other user's state.
                @{ Version = '2.42.0'; Source = 'nowhere'; Field = $false; Audit = $false; Floor = $true; Expected = 'Bob= alice= carol= dave= erin= frank=' }
                @{ Version = '2.42.5'; Source = 'nowhere'; Field = $false; Audit = $false; Floor = $true; Expected = 'Bob= alice= carol= dave= erin= frank=' }
                @{ Version = '2.42.5.2'; Source = 'nowhere'; Field = $false; Audit = $false; Floor = $true; Expected = 'Bob= alice= carol= dave= erin= frank=' }
                @{ Version = '2.43.0'; Source = 'nowhere'; Field = $false; Audit = $false; Floor = $true; Expected = 'Bob= alice= carol= dave= erin= frank=' }
                @{ Version = '2.43.0.1'; Source = 'nowhere'; Field = $false; Audit = $false; Floor = $true; Expected = 'Bob= alice= carol= dave= erin= frank=' }
                # Enrolling is not enabled, and the disabled account and the invitation are not listed.
                @{ Version = '2.42.6'; Source = 'api/users/twoFactor'; Field = $false; Audit = $true; Floor = $false
                    Expected = 'Bob=False alice=True carol=False dave= erin= frank=True' }
                @{ Version = '2.43.1'; Source = 'api/users/twoFactor'; Field = $false; Audit = $true; Floor = $false
                    Expected = 'Bob=False alice=True carol=False dave= erin= frank=True' }
                @{ Version = '2.43.2'; Source = 'api/users/twoFactor'; Field = $false; Audit = $true; Floor = $false
                    Expected = 'Bob=False alice=True carol=False dave= erin= frank=True' }
            ) {
                $script:Fake.Version = $Version
                $users = @(Read-UserInfo -Auth $script:Auth -Hostname $script:Host1 -WarningVariable warnings -WarningAction SilentlyContinue)
                Get-TwoFactorText $users | Should -BeExactly $Expected
                @($users | Where-Object { $null -ne $_.TwoFactorEnabled -and $_.TwoFactorEnabled -isnot [bool] }).Count | Should -Be 0
                (Get-FakeRequest 'api/users')[0].Fields -ccontains 'twoFactorEnabled' | Should -Be $Field
                (Get-FakeRequest 'api/users/twoFactor').Count | Should -Be ([int]$Audit)
                if ($Floor) {
                    @($warnings).Count | Should -Be 1
                    Get-Message $warnings | Should -BeLike "*$Version*2.42.6*2.43.1*"
                }
                else { @($warnings).Count | Should -Be 0 }
            }

            It 'is empty, with a warning naming the authority ALL, when api/users/twoFactor refuses the account' {
                $script:Fake.TwoFactorStatus = 403
                $users = @(Read-UserInfo -Auth $script:Auth -Hostname $script:Host1 -WarningVariable warnings -WarningAction SilentlyContinue)
                Get-TwoFactorText $users | Should -BeExactly 'Bob= alice= carol= dave= erin= frank='
                @($warnings).Count | Should -Be 1
                Get-Message $warnings | Should -BeLike '*authority ALL*'
            }

            It 'is empty, with a warning, when api/users/twoFactor answers 404' {
                $script:Fake.TwoFactorStatus = 404
                $users = @(Read-UserInfo -Auth $script:Auth -Hostname $script:Host1 -WarningVariable warnings -WarningAction SilentlyContinue)
                Get-TwoFactorText $users | Should -BeExactly 'Bob= alice= carol= dave= erin= frank='
                Get-Message $warnings | Should -BeLike '*HTTP 404*'
            }

            It 'is empty for the accounts api/users/twoFactor leaves out at its ceiling, with a warning' {
                $script:Fake.TwoFactorCap = 2
                $users = @(Read-UserInfo -Auth $script:Auth -Hostname $script:Host1 -WarningVariable warnings -WarningAction SilentlyContinue)
                Get-TwoFactorText $users | Should -BeExactly 'Bob=False alice=True carol= dave= erin= frank='
                @($warnings).Count | Should -Be 1
                Get-Message $warnings | Should -BeLike '*10,000*2 of 4*'
            }
        }

        Describe 'EditUrl' {
            It 'links to the Users app of DHIS2 <Version>' -ForEach @(
                # NEOIPC-COMPAT(dhis2-legacy-app-path): the Users app's path on 2.41 and earlier.
                @{ Version = '2.40.12'; Expected = 'https://dhis2.example.org/dhis-web-user/index.html#/users/edit/UsrAlice001' }
                @{ Version = '2.41.10'; Expected = 'https://dhis2.example.org/dhis-web-user/index.html#/users/edit/UsrAlice001' }
                @{ Version = '2.42.0'; Expected = 'https://dhis2.example.org/apps/user#/users/edit/UsrAlice001' }
                @{ Version = '2.43.2'; Expected = 'https://dhis2.example.org/apps/user#/users/edit/UsrAlice001' }
            ) {
                $script:Fake.Version = $Version
                $users = @(Read-UserInfo -Auth $script:Auth -Hostname $script:Host1 -WarningAction SilentlyContinue)
                ($users | Where-Object { $_.Username -ceq 'alice' }).EditUrl | Should -BeExactly $Expected
            }

            It 'starts from -Scheme, -Hostname, and -Port' {
                $users = @(Read-UserInfo -Auth $script:Auth -Scheme 'http' -Hostname 'localhost' -Port 8080 -WarningAction SilentlyContinue)
                ($users | Where-Object { $_.Username -ceq 'alice' }).EditUrl | Should -BeExactly 'http://localhost:8080/apps/user#/users/edit/UsrAlice001'
            }
        }

        Describe 'Reading the users' {
            It 'uses -Auth for every read and asks for no credentials' {
                Mock Read-Host { throw 'Read-Host was called.' }
                Mock Resolve-NeoIPCAuth { throw 'Resolve-NeoIPCAuth was called.' }
                $users = @(Read-UserInfo -Auth $script:Auth -Hostname $script:Host1 -OrgUnitCode 'DEPT_A1')
                @($users | ForEach-Object { $_.Username }) | Should -BeExactly @('Bob', 'alice')
                $script:Fake.Requests.Count | Should -BeGreaterThan 0
                @($script:Fake.Requests | Where-Object { -not [object]::ReferenceEquals($_.Auth, $script:Auth) }).Count | Should -Be 0
                Should -Invoke Read-Host -Times 0 -Exactly
            }

            It 'stops with an error naming the authority F_USER_VIEW when api/users answers 403' {
                $script:Fake.UsersStatus = 403
                $failure = $null
                try { $null = Read-UserInfo -Auth $script:Auth -Hostname $script:Host1 } catch { $failure = $_ }
                $failure | Should -Not -BeNullOrEmpty
                "$failure" | Should -BeLike '*F_USER_VIEW*'
                $failure.CategoryInfo.Category | Should -Be 'PermissionDenied'
                [int]$failure.Exception.StatusCode | Should -Be 403
            }

            It 'reads the users of the org units given, and writes an error naming each code outside the hierarchy' {
                $users = @(Read-UserInfo -Auth $script:Auth -Hostname $script:Host1 -OrgUnitCode 'DEPT_B1', 'OUTSIDE', 'NOPE' -ErrorVariable failures -ErrorAction SilentlyContinue -WarningAction SilentlyContinue)
                @($users | ForEach-Object { $_.Username }) | Should -BeExactly @('Bob', 'dave', 'erin')
                @($failures | ForEach-Object { $_.TargetObject }) | Should -BeExactly @('OUTSIDE', 'NOPE')
                @($failures | Where-Object { $_.CategoryInfo.Category -ne 'ObjectNotFound' }).Count | Should -Be 0
            }

            It 'reads no users when no code given names an org unit in the hierarchy' {
                $users = @(Read-UserInfo -Auth $script:Auth -Hostname $script:Host1 -OrgUnitCode 'NOPE' -ErrorVariable failures -ErrorAction SilentlyContinue)
                $users.Count | Should -Be 0
                @($failures).Count | Should -Be 1
                (Get-FakeRequest 'api/users').Count | Should -Be 0
            }

            It 'keeps codes that differ only in case apart' {
                @(Read-UserInfo -Auth $script:Auth -Hostname $script:Host1 -OrgUnitCode 'Dept_a1' -WarningAction SilentlyContinue | ForEach-Object { $_.Username }) |
                    Should -BeExactly @('carol')
                @(Read-UserInfo -Auth $script:Auth -Hostname $script:Host1 -OrgUnitCode 'DEPT_A1', 'Dept_a1' -WarningAction SilentlyContinue | ForEach-Object { $_.Username }) |
                    Should -BeExactly @('Bob', 'alice', 'carol')
            }

            It 'reads many codes in chunks, and returns a user found in two of them once' {
                $codes = @(1..120 | ForEach-Object { 'DEPT_X{0:D3}' -f $_ })
                foreach ($c in $codes) {
                    $id = 'OuX' + $c.Substring($c.Length - 3) + 'Dept1'
                    $script:Fake.OrgUnits.Add(@{ id = $id; code = $c; path = "/OuRoot00001/$id" })
                    $script:Fake.OrgUnitIdByCode[$c] = $id
                }
                $script:Fake.Users.Add(@{ id = 'UsrGrace001'; username = 'grace'; ou = @('DEPT_X001', 'DEPT_X120'); field = $false; type = 'TOTP_ENABLED' })
                $users = @(Read-UserInfo -Auth $script:Auth -Hostname $script:Host1 -OrgUnitCode $codes -WarningAction SilentlyContinue)
                @($users | ForEach-Object { $_.Username }) | Should -BeExactly @('grace')
                (Get-FakeRequest 'api/users').Count | Should -Be 2
            }

            It 'returns nothing and reads nothing for an empty pipeline' {
                $users = @(@() | Read-UserInfo -Auth $script:Auth -Hostname $script:Host1)
                $users.Count | Should -Be 0
                $script:Fake.Requests.Count | Should -Be 0
            }

            It 'returns the users in ordinal order of Username, and their codes and names as String[] in ordinal order' {
                $users = @(Read-UserInfo -Auth $script:Auth -Hostname $script:Host1 -WarningAction SilentlyContinue)
                @($users | ForEach-Object { $_.Username }) | Should -BeExactly @('Bob', 'alice', 'carol', 'dave', 'erin', 'frank')
                $alice = $users | Where-Object { $_.Username -ceq 'alice' }
                $bob = $users | Where-Object { $_.Username -ceq 'Bob' }
                $alice.UserRoles | Should -BeExactly @('Alpha', 'alpha', 'beta')
                $alice.UserGroups | Should -BeExactly @('Group A', 'Group b')
                $bob.OrganisationUnits | Should -BeExactly @('DEPT_A1', 'DEPT_B1')
                $bob.DataViewOrganisationUnits | Should -BeExactly @('DEPT_A1', 'DEPT_B1')
                , $bob.TeiSearchOrganisationUnits | Should -BeOfType [string[]]
                $bob.TeiSearchOrganisationUnits.Count | Should -Be 0
                , $bob.UserRoles | Should -BeOfType [string[]]
            }

            It 'returns the dates as DateTime and the creating and updating accounts by user name' {
                $alice = Read-UserInfo -Auth $script:Auth -Hostname $script:Host1 -WarningAction SilentlyContinue | Where-Object { $_.Username -ceq 'alice' }
                $alice.Created | Should -Be ([datetime]::new(2024, 1, 2, 3, 4, 5, 678))
                $alice.LastLogin | Should -BeOfType [datetime]
                $alice.CreatedBy | Should -BeExactly 'admin'
                $alice.LastUpdatedBy | Should -BeExactly 'admin'
                $alice.Disabled | Should -BeFalse
            }

            It 'reads the users under an inherited -WhatIf' {
                $WhatIfPreference = $true
                @(Read-UserInfo -Auth $script:Auth -Hostname $script:Host1 -OrgUnitCode 'DEPT_A1' | ForEach-Object { $_.Username }) | Should -BeExactly @('Bob', 'alice')
            }
        }

        Describe 'The comment-based help' {
            It 'describes every parameter' {
                $help = Get-Help Read-UserInfo -Full
                @($help.parameters.parameter).Count | Should -Be 7
                @($help.parameters.parameter | Where-Object { -not $_.description } | ForEach-Object { $_.name }) | Should -BeNullOrEmpty
            }
        }
    }
}
