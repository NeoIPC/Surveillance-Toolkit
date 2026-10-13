#Requires -Version 7.6

<#
.SYNOPSIS
    Pester tests for the org units of the caller's hierarchy and the lookup of org units by code or UID within it.

.DESCRIPTION
    Covers Get-NeoIPCCaptureRoot, Get-NeoIPCHierarchyOrgUnit and Resolve-NeoIPCOrgUnit (Private/OrgUnitHierarchy.ps1).
    Self-contained: the DHIS2 reads go to a fake instance of two countries, each with one hospital, whose departments are
    in the group NEO_DEPARTMENT. The fake applies the metadata filters the helpers send, so a test sees which units a
    request names; its code comparison ignores case on purpose, so the helpers' own exact comparison is what a test checks.

.EXAMPLE
    Invoke-Pester -Path scripts/modules/NeoIPC-Tools/Tests/OrgUnitHierarchy.Tests.ps1
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..') -Force

InModuleScope 'NeoIPC-Tools' {
    Describe 'The org units of the caller''s hierarchy' {
        BeforeAll {
            $script:Endpoint = @{ Auth = @{ AuthType = 'Token'; Token = 'not-a-real-token' }; Hostname = 'given.example.org' }
            $script:Units = @(
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

            # The rows a metadata filter keeps, the way DHIS2 reads it ('like' compares case-sensitively).
            function Select-FakeUnit($Rows, [string]$Filter) {
                $property, $operator, $value = $Filter -split ':', 3
                $list = if ($operator -eq 'in') { @($value.TrimStart('[').TrimEnd(']') -split ',') }
                @($Rows | Where-Object {
                        $row = $_
                        switch ("${property}:$operator") {
                            'path:like' { $row.path.Contains($value, [System.StringComparison]::Ordinal) }
                            'code:in' { @($list | Where-Object { [string]::Equals($_, $row.code, [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0 }
                            'code:eq' { [string]::Equals($value, $row.code, [System.StringComparison]::OrdinalIgnoreCase) }
                            'id:in' { $list -ccontains $row.id }
                            'organisationUnitGroups.code:eq' { $row.groups -ccontains $value }
                            default { throw "The fake does not read the filter '$Filter'." }
                        }
                    })
            }
        }

        BeforeEach {
            $script:Capture = @('OuHospA0001')
            $script:IgnorePath = $false
            $script:Requests = [System.Collections.Generic.List[object]]::new()
            Mock Invoke-WebRequest { throw 'A test made an HTTP call.' }
            Mock Invoke-NeoIPCDhis2Get {
                $script:Requests.Add([pscustomobject]@{ Path = $Path; Filter = @($Filter); Fields = @($Fields) })
                switch ($Path) {
                    'api/me' {
                        return [ordered]@{ organisationUnits = @($script:Capture | ForEach-Object { $id = $_; $u = $script:Units | Where-Object { $_.id -ceq $id }; [ordered]@{ id = $u.id; path = $u.path } }) }
                    }
                    'api/organisationUnits' {
                        $rows = $script:Units
                        foreach ($f in $Filter) {
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
            It 'looks a code holding a comma up by itself' {
                $result = Resolve-NeoIPCOrgUnit -Endpoint $script:Endpoint -Code 'DEPT_A1', 'DEPT,A2' -Fields 'name'
                Get-SortedCode $result.Units | Should -Be @('DEPT,A2', 'DEPT_A1')
                $filters = @($script:Requests | Where-Object { $_.Path -eq 'api/organisationUnits' } | ForEach-Object { $_.Filter[1] })
                $filters | Should -Contain 'code:in:[DEPT_A1]'
                $filters | Should -Contain 'code:eq:DEPT,A2'
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
