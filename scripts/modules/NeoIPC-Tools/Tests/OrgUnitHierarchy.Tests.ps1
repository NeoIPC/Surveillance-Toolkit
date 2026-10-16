#Requires -Version 7.6

<#
.SYNOPSIS
    Pester tests for the org units of the caller's hierarchy and the lookup of org units by code or UID within it.

.DESCRIPTION
    Covers Get-NeoIPCCaptureRoot, Get-NeoIPCHierarchyOrgUnit, and Resolve-NeoIPCOrgUnit (Private/OrgUnitHierarchy.ps1).
    Self-contained: the DHIS2 reads go to a fake instance of two countries, each with one hospital, whose departments are
    in the group NEO_DEPARTMENT. The fake applies the metadata filters the helpers send, so a test sees which units a
    request names; its code comparison ignores case on purpose, so the helpers' own exact comparison is what a test
    checks. It reads the filter parameters as the DHIS2 release a test sets does: 2.41 and earlier each as sent, 2.42 and
    later joined with ',' and split again, which ends a value at its first ',' or line break, and one that starts with
    '[' at its first ']'. It then reads each filter as that release's query parser does: 2.41 and earlier take the rest
    after the operator as the value, and 2.42 and later the parts after it joined with ':', which loses the value's
    trailing ':' characters; a filter left without a value is refused. Its `in` list loses one bracket at each end before
    it splits on ','. Its `like` drops every '%' from the value, as DHIS2 does, and takes '\' as the escape of the
    character after it, as PostgreSQL's LIKE does.

.EXAMPLE
    Invoke-Pester -Path scripts/modules/NeoIPC-Tools/Tests/OrgUnitHierarchy.Tests.ps1
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..') -Force

InModuleScope 'NeoIPC-Tools' {
    Describe 'The org units of the caller''s hierarchy' {
        BeforeAll {
            $script:Endpoint = @{ Auth = @{ AuthType = 'Token'; Token = 'not-a-real-token' }; Hostname = 'given.example.org' }
            $script:BaseUnits = @(
                @{ id = 'OuRoot00001'; code = 'ROOT'; path = '/OuRoot00001'; groups = @() }
                @{ id = 'OuCtryA0001'; code = 'COUNTRY_A'; path = '/OuRoot00001/OuCtryA0001'; groups = @('COUNTRY') }
                @{ id = 'OuHospA0001'; code = 'HOSP_A'; path = '/OuRoot00001/OuCtryA0001/OuHospA0001'; groups = @('HOSPITAL') }
                @{ id = 'OuDeptA0001'; code = 'DEPT_A1'; path = '/OuRoot00001/OuCtryA0001/OuHospA0001/OuDeptA0001'; groups = @('NEO_DEPARTMENT') }
                @{ id = 'OuDeptA0002'; code = 'DEPT,A2'; path = '/OuRoot00001/OuCtryA0001/OuHospA0001/OuDeptA0002'; groups = @('NEO_DEPARTMENT') }
                @{ id = 'OuCtryB0001'; code = 'COUNTRY_B'; path = '/OuRoot00001/OuCtryB0001'; groups = @('COUNTRY') }
                @{ id = 'OuHospB0001'; code = 'HOSP_B'; path = '/OuRoot00001/OuCtryB0001/OuHospB0001'; groups = @('HOSPITAL') }
                @{ id = 'OuDeptB0001'; code = 'DEPT_B1'; path = '/OuRoot00001/OuCtryB0001/OuHospB0001/OuDeptB0001'; groups = @('NEO_DEPARTMENT') }
            )

            # The codes of the units, in ordinal order (Sort-Object compares by culture, which ignores the ',').
            function Get-SortedCode($Units) {
                $codes = [string[]]@($Units | ForEach-Object { [string]$_['code'] })
                [Array]::Sort($codes, [System.StringComparer]::Ordinal)
                $codes
            }

            # The filters DHIS2 reads from a request's filter parameters. 2.41 and earlier read each as sent
            # (AbstractFullReadOnlyController, getParameterValues("filter")); 2.42 and later receive them joined with ',' and
            # split them again with this pattern (GetObjectListParams.splitFilters).
            function Split-FakeFilter([string[]]$Filter, [string]$Version) {
                $sent = @($Filter | Where-Object { $_ })
                $joined = $sent -join ','
                if ((ConvertTo-NeoIPCDhis2Version -Text $Version) -lt [version]'2.42.0' -or -not $joined.Contains(',')) { return $sent }
                @([regex]::Matches($joined, '(?<property>[a-zA-Z0-9.]+):(?<op>[!$a-zA-Z]{2,10})(?::(?<value>\[[^]]*]|[^,\n\r]+))?') | ForEach-Object { $_.Value })
            }

            # The text a like value matches: DHIS2 drops every '%' (LikeOperator.getPredicate), and PostgreSQL's LIKE takes
            # '\' as the escape of the character after it. A '_', any one character there, is taken literally.
            function Get-FakeLikeText([string]$Value) { [regex]::Replace($Value.Replace('%', ''), '\\(.)', '$1') }

            # A filter's property, operator, and value as DHIS2's query parsers read it. Both split the filter at ':', which
            # drops trailing empty parts, so a value of ':' only reads as none, which this fake refuses; 2.41 and earlier then
            # take the rest of the filter as the value (DefaultJpaQueryParser), and 2.42 and later the parts after the
            # operator joined with ':', which loses the value's trailing ':' characters (DefaultQueryParser).
            function ConvertFrom-FakeFilter([string]$Filter, [string]$Version) {
                $parts = [System.Collections.Generic.List[string]]::new([string[]]$Filter.Split(':'))
                while ($parts.Count -gt 0 -and $parts[$parts.Count - 1] -eq '') { $parts.RemoveAt($parts.Count - 1) }
                if ($parts.Count -lt 3) { throw "The fake does not read the filter '$Filter', which DHIS2 reads without a value." }
                $value = if ((ConvertTo-NeoIPCDhis2Version -Text $Version) -ge [version]'2.42.0') { $parts.GetRange(2, $parts.Count - 2) -join ':' }
                else { $Filter.Substring($parts[0].Length + $parts[1].Length + 2) }
                $parts[0], $parts[1], $value
            }

            # The rows a metadata filter keeps, the way DHIS2 reads it ('like' compares case-sensitively, but this fake's
            # code comparisons ignore case).
            function Select-FakeUnit($Rows, [string]$Filter) {
                $property, $operator, $value = ConvertFrom-FakeFilter $Filter $script:Version
                $list = if ($operator -eq 'in') {
                    if (-not ($value.StartsWith('[') -and $value.EndsWith(']'))) { throw "The fake does not read the filter '$Filter', whose value is no list." }
                    @($value.Substring(1, $value.Length - 2) -split ',')
                }
                @($Rows | Where-Object {
                        $row = $_
                        switch ("${property}:$operator") {
                            'path:like' { $row.path.Contains($value, [System.StringComparison]::Ordinal) }
                            'code:in' { @($list | Where-Object { [string]::Equals($_, $row.code, [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0 }
                            'code:eq' { [string]::Equals($value, $row.code, [System.StringComparison]::OrdinalIgnoreCase) }
                            'code:like' { ([string]$row.code).IndexOf((Get-FakeLikeText $value), [System.StringComparison]::OrdinalIgnoreCase) -ge 0 }
                            'id:in' { $list -ccontains $row.id }
                            'organisationUnitGroups.code:eq' { $row.groups -ccontains $value }
                            default { throw "The fake does not read the filter '$Filter'." }
                        }
                    })
            }
        }

        BeforeEach {
            $script:Version = '2.43.2'
            $script:Units = @($script:BaseUnits)
            $script:Capture = @('OuHospA0001')
            $script:IgnorePath = $false
            $script:Requests = [System.Collections.Generic.List[object]]::new()
            Mock Invoke-WebRequest { throw 'A test made an HTTP call.' }
            Mock Invoke-RestMethod { throw 'A test made an HTTP call.' }
            Mock Invoke-NeoIPCDhis2Get {
                $script:Requests.Add([pscustomobject]@{ Path = $Path; Filter = @($Filter); Fields = @($Fields) })
                switch ($Path) {
                    'api/me' {
                        return [ordered]@{ organisationUnits = @($script:Capture | ForEach-Object { $id = $_; $u = $script:Units | Where-Object { $_.id -ceq $id }; [ordered]@{ id = $u.id; path = $u.path } }) }
                    }
                    'api/organisationUnits' {
                        $rows = $script:Units
                        foreach ($f in @(Split-FakeFilter $Filter $script:Version)) {
                            if ($script:IgnorePath -and $f.StartsWith('path:')) { continue }
                            $rows = Select-FakeUnit $rows $f
                        }
                        return [ordered]@{ organisationUnits = @($rows | ForEach-Object {
                                    [ordered]@{ id = $_.id; code = $_.code; path = $_.path; organisationUnitGroups = @($_.groups | ForEach-Object { [ordered]@{ code = $_ } }) }
                                }) }
                    }
                }
                throw "Unexpected GET $Path"
            }
        }

        Describe 'Get-NeoIPCCaptureRoot' {
            It 'reads a capture unit below another one no more' {
                $script:Capture = @('OuDeptA0001', 'OuCtryA0001', 'OuHospB0001')
                $roots = Get-NeoIPCCaptureRoot -Endpoint $script:Endpoint
                $roots | Should -Be @('OuCtryA0001', 'OuHospB0001')
            }
            It 'warns and returns nothing for an account without capture units' {
                $script:Capture = @()
                $roots = Get-NeoIPCCaptureRoot -Endpoint $script:Endpoint -WarningVariable warnings -WarningAction SilentlyContinue
                $roots.Count | Should -Be 0
                "$warnings" | Should -BeLike '*no data-capture org units*'
            }
        }

        Describe 'Get-NeoIPCHierarchyOrgUnit' {
            It 'joins the units below each capture unit, with one path filter per capture unit' {
                $script:Capture = @('OuDeptA0001', 'OuHospB0001')
                $units = Get-NeoIPCHierarchyOrgUnit -Endpoint $script:Endpoint -Fields 'code'
                Get-SortedCode $units | Should -Be @('DEPT_A1', 'DEPT_B1', 'HOSP_B')
                $reads = @($script:Requests | Where-Object { $_.Path -eq 'api/organisationUnits' })
                $reads.Count | Should -Be 2
                @($reads | ForEach-Object { $_.Filter[0] }) | Should -Be @('path:like:OuDeptA0001', 'path:like:OuHospB0001')
            }
            It 'applies the further filters within each capture unit' {
                $script:Capture = @('OuCtryA0001', 'OuCtryB0001')
                $units = Get-NeoIPCHierarchyOrgUnit -Endpoint $script:Endpoint -Filter 'organisationUnitGroups.code:eq:NEO_DEPARTMENT' -Fields 'code'
                Get-SortedCode $units | Should -Be @('DEPT,A2', 'DEPT_A1', 'DEPT_B1')
            }
            It 'never returns a unit twice' {
                $script:Capture = @('OuHospA0001')
                $units = Get-NeoIPCHierarchyOrgUnit -Endpoint $script:Endpoint -Fields 'code' -Root 'OuHospA0001', 'OuCtryA0001'
                @($units | ForEach-Object { $_['id'] }).Count | Should -Be 4
            }
            It 'stops when DHIS2 returns a unit outside the capture unit, rather than passing it on' {
                $script:IgnorePath = $true
                { Get-NeoIPCHierarchyOrgUnit -Endpoint $script:Endpoint -Fields 'code' } | Should -Throw '*outside the capture unit*'
            }
            It 'reads no org unit for an account without capture units' {
                $script:Capture = @()
                (Get-NeoIPCHierarchyOrgUnit -Endpoint $script:Endpoint -Fields 'code' -WarningAction SilentlyContinue).Count | Should -Be 0
                @($script:Requests | Where-Object { $_.Path -eq 'api/organisationUnits' }).Count | Should -Be 0
            }
        }

        Describe 'Resolve-NeoIPCOrgUnit' {
            It 'finds codes within the hierarchy and reports the others as missing from it' {
                $result = Resolve-NeoIPCOrgUnit -Endpoint $script:Endpoint -Code 'DEPT_A1', 'DEPT_B1' -Fields 'name'
                @($result.Units | ForEach-Object { $_['code'] }) | Should -Be @('DEPT_A1')
                $result.ByCode['DEPT_A1']['id'] | Should -BeExactly 'OuDeptA0001'
                $result.MissingCode | Should -Be @('DEPT_B1')
            }
            It 'compares codes exactly' {
                $result = Resolve-NeoIPCOrgUnit -Endpoint $script:Endpoint -Code 'dept_a1' -Fields 'name'
                @($result.Units).Count | Should -Be 0
                $result.MissingCode | Should -Be @('dept_a1')
            }
            # DHIS2 2.42 and later would read `code:eq:DEPT,A2` as `code:eq:DEPT`, and split a `code:in` list on the ','.
            It 'finds a code holding a comma on DHIS2 <Version> by its longest run without one, compared exactly' -ForEach @(
                @{ Version = '2.40.12' }
                @{ Version = '2.41.10' }
                @{ Version = '2.42.0' }
                @{ Version = '2.43.2' }
            ) {
                $script:Version = $Version
                $result = Resolve-NeoIPCOrgUnit -Endpoint $script:Endpoint -Code 'DEPT_A1', 'DEPT,A2', 'dept,a2' -Fields 'name'
                Get-SortedCode $result.Units | Should -Be @('DEPT,A2', 'DEPT_A1')
                $result.MissingCode | Should -Be @('dept,a2')
                @($script:Requests | Where-Object { $_.Path -eq 'api/organisationUnits' } | ForEach-Object { $_.Filter[1] }) |
                    Should -Be @('code:in:[DEPT_A1]', 'code:like:DEPT', 'code:like:dept')
            }
            # DHIS2 2.42 and later end a bracketed filter value at its first ']', which would cut the `in` list there.
            It 'finds a code holding a closing bracket on DHIS2 <Version> outside the code:in list' -ForEach @(
                @{ Version = '2.40.12' }
                @{ Version = '2.41.10' }
                @{ Version = '2.42.0' }
                @{ Version = '2.43.2' }
            ) {
                $script:Version = $Version
                $script:Units += @{ id = 'OuDeptA0005'; code = 'DEPT]A5'; path = '/OuRoot00001/OuCtryA0001/OuHospA0001/OuDeptA0005'; groups = @('NEO_DEPARTMENT') }
                $result = Resolve-NeoIPCOrgUnit -Endpoint $script:Endpoint -Code 'DEPT_A1', 'DEPT]A5' -Fields 'name'
                Get-SortedCode $result.Units | Should -Be @('DEPT]A5', 'DEPT_A1')
                @($script:Requests | Where-Object { $_.Path -eq 'api/organisationUnits' } | ForEach-Object { $_.Filter[1] }) |
                    Should -Be @('code:in:[DEPT_A1]', 'code:like:DEPT]A5')
            }
            # DHIS2 drops one bracket from each end of an `in` list, so a code that starts with '[' can head the list.
            It 'finds a code starting with "[" in the code:in list on DHIS2 <Version>' -ForEach @(
                @{ Version = '2.40.12' }
                @{ Version = '2.41.10' }
                @{ Version = '2.42.0' }
                @{ Version = '2.43.2' }
            ) {
                $script:Version = $Version
                $script:Units += @{ id = 'OuDeptA0011'; code = '[A11'; path = '/OuRoot00001/OuCtryA0001/OuHospA0001/OuDeptA0011'; groups = @('NEO_DEPARTMENT') }
                $result = Resolve-NeoIPCOrgUnit -Endpoint $script:Endpoint -Code '[A11', 'DEPT_A1' -Fields 'name'
                Get-SortedCode $result.Units | Should -BeExactly @('DEPT_A1', '[A11')
                @($script:Requests | Where-Object { $_.Path -eq 'api/organisationUnits' } | ForEach-Object { $_.Filter[1] }) |
                    Should -BeExactly @('code:in:[[A11,DEPT_A1]')
            }
            It 'looks a code holding a comma up on DHIS2 <Version> by a run free of the % and \ that DHIS2 and PostgreSQL do not match literally' -ForEach @(
                @{ Version = '2.40.12' }
                @{ Version = '2.43.2' }
            ) {
                $script:Version = $Version
                $script:Units += @{ id = 'OuDeptA0006'; code = 'DEPT%A6,B'; path = '/OuRoot00001/OuCtryA0001/OuHospA0001/OuDeptA0006'; groups = @('NEO_DEPARTMENT') }
                $script:Units += @{ id = 'OuWardA0007'; code = 'WARD\BX,C'; path = '/OuRoot00001/OuCtryA0001/OuHospA0001/OuWardA0007'; groups = @() }
                $result = Resolve-NeoIPCOrgUnit -Endpoint $script:Endpoint -Code 'DEPT%A6,B', 'WARD\BX,C' -Fields 'name'
                Get-SortedCode $result.Units | Should -Be @('DEPT%A6,B', 'WARD\BX,C')
                $result.MissingCode.Count | Should -Be 0
                @($script:Requests | Where-Object { $_.Path -eq 'api/organisationUnits' } | ForEach-Object { $_.Filter[1] }) |
                    Should -Be @('code:like:DEPT', 'code:like:WARD')
            }
            # Every release reads a filter value of ':' only as none, and 2.42 and later drop a value's trailing ':' characters.
            It 'finds a code holding a comma on DHIS2 <Version> by a run without trailing colons, where its longest run is colons only' -ForEach @(
                @{ Version = '2.40.12' }
                @{ Version = '2.41.10' }
                @{ Version = '2.42.0' }
                @{ Version = '2.43.2' }
            ) {
                $script:Version = $Version
                $script:Units += @{ id = 'OuDeptA0009'; code = '::,X'; path = '/OuRoot00001/OuCtryA0001/OuHospA0001/OuDeptA0009'; groups = @('NEO_DEPARTMENT') }
                $result = Resolve-NeoIPCOrgUnit -Endpoint $script:Endpoint -Code '::,X' -Fields 'name'
                Get-SortedCode $result.Units | Should -Be @('::,X')
                @($script:Requests | Where-Object { $_.Path -eq 'api/organisationUnits' } | ForEach-Object { $_.Filter[1] }) | Should -Be @('code:like:X')
            }
            # DHIS2 2.42 and later end a filter value at a line break, and one that starts with '[' at its first ']', and read
            # what follows as further filters.
            It 'finds <Case> on DHIS2 <Version> by a like value that no release cuts' -ForEach @(
                foreach ($version in '2.40.12', '2.41.10', '2.42.0', '2.43.2') {
                    @{ Version = $version; Case = 'a code holding a comma that starts with "["'; Code = '[A]code:eq:Q,X'; Value = 'A]code:eq:Q' }
                    @{ Version = $version; Case = 'a code holding a comma and a line break'; Code = "AB`ncode:eq:Q,X"; Value = 'code:eq:Q' }
                }
            ) {
                $script:Version = $Version
                $script:Units += @{ id = 'OuDeptA0010'; code = $Code; path = '/OuRoot00001/OuCtryA0001/OuHospA0001/OuDeptA0010'; groups = @('NEO_DEPARTMENT') }
                $result = Resolve-NeoIPCOrgUnit -Endpoint $script:Endpoint -Code $Code -Fields 'name'
                Get-SortedCode $result.Units | Should -BeExactly @($Code)
                @($script:Requests | Where-Object { $_.Path -eq 'api/organisationUnits' } | ForEach-Object { $_.Filter[1] }) | Should -BeExactly @("code:like:$Value")
            }
            It 'finds a code of nothing but commas on DHIS2 <Version> among all the units of the hierarchy' -ForEach @(
                @{ Version = '2.40.12' }
                @{ Version = '2.41.10' }
                @{ Version = '2.42.0' }
                @{ Version = '2.43.2' }
            ) {
                $script:Version = $Version
                $script:Units += @{ id = 'OuDeptA0008'; code = ',,'; path = '/OuRoot00001/OuCtryA0001/OuHospA0001/OuDeptA0008'; groups = @('NEO_DEPARTMENT') }
                $result = Resolve-NeoIPCOrgUnit -Endpoint $script:Endpoint -Code ',,', 'DEPT_A1', 'OUTSIDE,1' -Fields 'name'
                Get-SortedCode $result.Units | Should -Be @(',,', 'DEPT_A1')
                $result.MissingCode | Should -Be @('OUTSIDE,1')
                $reads = @($script:Requests | Where-Object { $_.Path -eq 'api/organisationUnits' })
                $reads.Count | Should -Be 1
                $reads[0].Filter | Should -Be @('path:like:OuHospA0001')
            }
            It 'finds UIDs within the hierarchy, and reports one outside it or no UID at all as missing' {
                $result = Resolve-NeoIPCOrgUnit -Endpoint $script:Endpoint -Id 'OuDeptA0001', 'OuDeptB0001', 'not a uid' -Fields 'name'
                @($result.Units | ForEach-Object { $_['id'] }) | Should -Be @('OuDeptA0001')
                $result.MissingId | Should -Be @('OuDeptB0001', 'not a uid')
                @($script:Requests | ForEach-Object { $_.Filter } | Where-Object { "$_" -like '*not a uid*' }).Count | Should -Be 0
            }
            It 'reads the capture units once for many lookups' {
                $codes = @(1..250 | ForEach-Object { 'CODE_{0:D3}' -f $_ }) + 'DEPT_A1'
                $result = Resolve-NeoIPCOrgUnit -Endpoint $script:Endpoint -Code $codes -Fields 'name'
                @($result.Units).Count | Should -Be 1
                @($script:Requests | Where-Object { $_.Path -eq 'api/me' }).Count | Should -Be 1
                @($script:Requests | Where-Object { $_.Path -eq 'api/organisationUnits' }).Count | Should -Be 3
            }
            It 'reads nothing when given nothing' {
                $result = Resolve-NeoIPCOrgUnit -Endpoint $script:Endpoint -Fields 'name'
                @($result.Units).Count | Should -Be 0
                $script:Requests.Count | Should -Be 0
            }
        }
    }
}
