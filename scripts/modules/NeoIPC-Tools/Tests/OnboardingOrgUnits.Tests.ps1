#Requires -Version 7.6

<#
.SYNOPSIS
    Pester tests for Add-NeoIPCPartnerSite.

.DESCRIPTION
    Covers Public/OnboardingOrgUnits.ps1 against mocks of the module's own DHIS2 helpers: the reads of the groups and
    the program, the lookups of the units by code and UID and of the units below a parent, and the writes. What the
    tests check is the cmdlet's decisions and the requests it sends: what it creates, below which parent, which
    memberships it adds, what it leaves alone on a repeat, and what it refuses before it writes anything. A country the
    instance lacks comes from a country list of the tests' own, so that no test depends on the toolkit's. That DHIS2
    accepts these requests is not shown here; a run against an instance is the evidence for that.

.EXAMPLE
    Invoke-Pester -Path scripts/modules/NeoIPC-Tools/Tests/OnboardingOrgUnits.Tests.ps1
#>

$ErrorActionPreference = 'Stop'

BeforeAll {
    Import-Module -Name (Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'NeoIPC-Tools.psd1') -Force
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '..', 'TestFileHelpers.ps1')
}

Describe 'Add-NeoIPCPartnerSite' {
    BeforeAll {
        # The country list: the root, Argentina with an income class for each of two fiscal years, and Uruguay with none.
        $script:metadataDir = Join-Path -Path $TestDrive -ChildPath 'metadata'
        $common = Join-Path -Path $script:metadataDir -ChildPath 'common'
        New-Item -ItemType Directory -Path $common -Force | Out-Null
        @(
            'id,code,name,shortName,openingDate,closedDate,level,parent,image,sharing'
            'ArgentinaU1,AR,Argentina,Argentina,2023-01-01,,2,RootUid0001,,'
            'RootUid0001,NEOIPC,NeoIPC,NeoIPC,2023-01-01,,1,,,'
            'UruguayUid1,UY,Uruguay,Uruguay,2023-01-01,,2,RootUid0001,,'
        ) | Set-TestFileContent -LiteralPath (Join-Path -Path $common -ChildPath 'organisationUnits.csv')
        @(
            'organisationUnitGroup,organisationUnit'
            'WORLD_BANK_CLASS_UM_FY_2025,AR'
            'WORLD_BANK_CLASS_UM_FY_2026,AR'
            'REFERENCE_CENTRE,NEOIPC'
        ) | Set-TestFileContent -LiteralPath (Join-Path -Path $common -ChildPath 'organisationUnitGroupMemberships.csv')
        # The files the stand-in for the list writer changes, three as the writer's are, so that a test can tell whether
        # the list was put back, and what a message names.
        $script:listFiles = @('list', 'memberships', 'play') | ForEach-Object { Join-Path -Path $TestDrive -ChildPath "$_-stand-in.txt" }
        $script:listFile = $script:listFiles[0]
    }

    BeforeEach {
        foreach ($file in $script:listFiles) { Set-TestFileContent -LiteralPath $file -Value 'before' -NoNewline }
        $groupCodes = 'HOSPITAL', 'NEO_DEPARTMENT', 'TEST_UNITS', 'NEOIPC_ALL_PATIENTS_ELIGIBLE', 'COUNTRY', 'WORLD_BANK_CLASS_UM_FY_2025', 'WORLD_BANK_CLASS_UM_FY_2026', 'WORLD_BANK_CLASS_LM_FY_2025', 'WORLD_BANK_CLASS_LM_FY_2026'
        $s = @{
            Units    = @{
                NEOIPC = [ordered]@{ id = 'RootUid0001'; code = 'NEOIPC'; name = 'NeoIPC'; organisationUnitGroups = @(@{ code = 'REFERENCE_CENTRE' }) }
                DE     = [ordered]@{ id = 'CountryUid01'; code = 'DE'; name = 'Germany'; parent = @{ id = 'RootUid0001' }; organisationUnitGroups = @(@{ code = 'COUNTRY' }, @{ code = 'WORLD_BANK_CLASS_H_FY_2026' }) }
            }
            Groups   = @($groupCodes | ForEach-Object { [ordered]@{ id = "Group$($_.Length)$($groupCodes.IndexOf($_))aaaa".Substring(0, 11); code = $_ } })
            Programs = @([ordered]@{ id = 'ProgramUid01'; code = 'NEOIPC_CORE' })
            NewUids  = @{ DE_BER_CHA = 'HospitalUid1'; DE_BER_CHA_NEO = 'DepartmentU1'; AR = 'ArgentinaU1'; UY = 'UruguayUid1'; AR_BUE_HOS = 'HospitalUid2'; AR_BUE_HOS_NEO = 'DepartmentU2'; UY_MVD_HOS = 'HospitalUid3'; UY_MVD_HOS_NEO = 'DepartmentU3'; KE = 'KenyaUid001'; KE_NBO_EXH = 'HospitalUid4'; KE_NBO_EXH_NEO = 'DepartmentU4' }
            Refuse   = $false
            RefuseCode = $null
            RefuseMembership = $false
            # The countries the World Bank can give a plan for, as the list helpers' stand-ins return it.
            Plans    = @{ KE = @{ Id = 'KenyaUid001'; Name = 'Kenya'; Groups = @('WORLD_BANK_CLASS_LM_FY_2025', 'WORLD_BANK_CLASS_LM_FY_2026') } }
            ListFiles = $script:listFiles
            ListWrites = [System.Collections.Generic.List[string]]::new()
            RefuseListWrite = $false
        }
        $script:params = @{
            Auth              = @{ AuthType = 'Token'; Token = 'x' }
            CountryCode       = 'DE'
            HospitalCode      = 'DE_BER_CHA'
            HospitalName      = 'Example Hospital'
            DepartmentName    = 'Example Hospital Neonatology'
            OpeningDate       = [datetime]'2026-10-19'
            MetadataDirectory = $script:metadataDir
        }

        # The mocks are defined in the module's scope, so that they read the scenario from its script scope: a mock
        # defined outside it runs in a scope of its own that does not see that variable.
        InModuleScope NeoIPC-Tools -Parameters @{ Scenario = $s } {
            $script:OnboardingTestScenario = $Scenario

            # Org units are read only through the hierarchy-scoped lookup; a read of them here would be one beyond it.
            Mock Invoke-NeoIPCDhis2Get {
                $s = $script:OnboardingTestScenario
                if ($Path -ceq 'api/organisationUnitGroups') { @{ organisationUnitGroups = $s.Groups } }
                elseif ($Path -ceq 'api/programs') { @{ programs = $s.Programs } }
                else { throw "unexpected read of $Path" }
            }
            # A unit comes back as the real lookup returns it: its id and code, and of each field asked for what DHIS2's
            # field filter gives. 'parent[id]' gives the parent's id alone, and an object asked for without sub-fields
            # is a reference, its id alone. The cmdlet asks for one level of sub-fields, which is all this reads.
            Mock Resolve-NeoIPCOrgUnit {
                $s = $script:OnboardingTestScenario
                $wanted = [ordered]@{ id = $null; code = $null }
                foreach ($field in $Fields) {
                    if ($field -cmatch '^(?<name>[^\[\]]+)\[(?<sub>[^\[\]]+)\]$') { $wanted[$Matches['name']] = @($Matches['sub'] -split ',') }
                    else { $wanted[$field] = $null }
                }
                $select = {
                    param($Value, $Sub)
                    $copy = [ordered]@{}
                    foreach ($k in ($Sub ?? @('id'))) { if ($Value.Contains($k)) { $copy[$k] = $Value[$k] } }
                    $copy
                }
                $project = {
                    param($Source)
                    $unit = [ordered]@{}
                    foreach ($key in $Source.Keys) {
                        if (-not $wanted.Contains($key)) { continue }
                        $value = $Source[$key]
                        $sub = $wanted[$key]
                        $unit[$key] = if ($value -is [System.Collections.IDictionary]) { & $select $value $sub }
                        elseif ($value -is [System.Collections.IEnumerable] -and $value -isnot [string]) { @($value | ForEach-Object { & $select $_ $sub }) }
                        else { $value }
                    }
                    $unit
                }
                $byCode = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
                $byId = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
                $missing = @()
                foreach ($c in $Code) {
                    if (-not $s.Units.ContainsKey($c)) { $missing += $c; continue }
                    $byCode[$c] = & $project $s.Units[$c]
                }
                # The read back by UID alone after a write, unlike the lookups before it, which name codes too.
                if ($Id -and -not $Code -and $s.FailIdRead) { throw [System.Net.Http.HttpRequestException]::new('The connection was reset.') }
                foreach ($i in $Id) {
                    $match = @($s.Units.Values | Where-Object { $_['id'] -ceq $i })
                    if ($match.Count -gt 0) { $byId[$i] = & $project $match[0] }
                }
                [pscustomobject]@{ Units = @($byCode.Values) + @($byId.Values); ByCode = $byCode; ById = $byId; MissingCode = [string[]]$missing; MissingId = [string[]]@($Id | Where-Object { -not $byId.ContainsKey($_) }) }
            }
            # A country the list lacks is planned and written by the helpers of Add-NeoIPCMetadataCountry, whose own tests
            # cover what they read and write. Here the plan comes from the scenario, and the write changes the stand-in
            # file, partly and then failing when the scenario says so.
            Mock Get-NeoIPCMetadataCountryPlan {
                $s = $script:OnboardingTestScenario
                if (-not $s.Plans.ContainsKey($Code)) { throw "The World Bank knows no economy with the code '$Code'." }
                $p = $s.Plans[$Code]
                $planName = $Name ? $Name : $p.Name
                [pscustomobject]@{
                    Code = $Code; Id = $p.Id; Name = $planName; ShortName = ($ShortName ? $ShortName : $planName); OpeningDate = '2023-01-01'
                    ParentId = 'RootUid0001'; ParentCode = 'NEOIPC'; Groups = [string[]]$p.Groups; Directory = $MetadataDirectory
                    Summary = "the country $Code '$planName' with the id $($p.Id)"
                    Files = @($s.ListFiles | ForEach-Object { [pscustomobject]@{ Path = $_; Columns = @(); Rows = @() } })
                }
            }
            # As the writer does, it writes all or none and returns what the files held before and what it wrote.
            Mock Write-NeoIPCMetadataCountryPlan {
                $s = $script:OnboardingTestScenario
                if ($s.RefuseListWrite) { throw 'Writing the country to the scaffold failed, so the files are as they were: The disk is full.' }
                $before = @{}
                $written = @{}
                foreach ($file in $s.ListFiles) {
                    $before[$file] = [System.IO.File]::ReadAllBytes($file)
                    [System.IO.File]::WriteAllText($file, 'after')
                    $written[$file] = [System.IO.File]::ReadAllBytes($file)
                }
                # A file of the backup that cannot be put back: its path is a directory when the call puts the files back.
                if ($s.UnrestorablePath) {
                    $before[$s.UnrestorablePath] = [byte[]](1, 2, 3)
                    $written[$s.UnrestorablePath] = [byte[]](4, 5, 6)
                }
                $s.ListWrites.Add($Plan.Code)
                [pscustomobject]@{ Before = $before; Written = $written }
            }
            # The units below a parent, as the hierarchy read returns them for the filter parent.id:eq:<UID>.
            Mock Get-NeoIPCHierarchyOrgUnit {
                $s = $script:OnboardingTestScenario
                $parent = @($Filter | Where-Object { $_ -cmatch '^parent\.id:eq:' } | ForEach-Object { $_.Substring('parent.id:eq:'.Length) })
                if ($parent.Count -ne 1) { throw "unexpected hierarchy read with the filters $($Filter -join ', ')" }
                , @($s.Units.Values | Where-Object { $_.Contains('parent') -and $_['parent']['id'] -ceq $parent[0] } | ForEach-Object { [ordered]@{ id = $_['id']; code = $_['code']; name = $_['name'] } })
            }
            # The answers are DHIS2's web messages, as 2.40 writes them, with the status code they name.
            Mock Invoke-NeoIPCDhis2Post {
                $s = $script:OnboardingTestScenario
                $refusal = { param($Code) [pscustomobject]@{ StatusCode = 409; Body = [pscustomobject]@{ httpStatus = 'Conflict'; httpStatusCode = 409; status = 'ERROR'; message = 'One or more errors occurred'; response = [pscustomobject]@{ errorReports = @([pscustomobject]@{ message = "Property code with value $Code already exists" }) } } } }
                if ($Path -ceq 'api/organisationUnits') {
                    $j = $Body | ConvertFrom-Json
                    $code = $j.code
                    # DHIS2 commits a unit before it answers, so an answer can fail for a unit it created, and DHIS2 can
                    # refuse one it committed, as when the version update after the creation fails.
                    if ($s.CommitThenFail -ceq $code -or $s.CommitThenRefuse -ceq $code) {
                        $s.Units[$code] = [ordered]@{ id = $j.id; code = $code; name = $j.name; parent = @{ id = $j.parent.id }; organisationUnitGroups = @() }
                        return ($s.CommitThenFail -ceq $code) ? [pscustomobject]@{ StatusCode = 502; Body = 'Bad Gateway' } : (& $refusal $code)
                    }
                    if ($s.DropCode -ceq $code) { throw [System.Net.Http.HttpRequestException]::new('The connection was reset.') }
                    # Ctrl+C while the request is under way.
                    if ($s.StopCode -ceq $code) { throw [System.Management.Automation.PipelineStoppedException]::new() }
                    # Another run that writes the list while this one's request is under way.
                    if ($s.ChangedByOtherRun) { [System.IO.File]::WriteAllText($s.ChangedByOtherRun, 'other run') }
                    if ($s.AnswerCode -ceq $code) { return $s.Answer }
                    if ($s.Refuse -or $s.RefuseCode -ceq $code) { return & $refusal $code }
                    [pscustomobject]@{ StatusCode = 201; Body = [pscustomobject]@{ httpStatus = 'Created'; httpStatusCode = 201; status = 'OK'; response = [pscustomobject]@{ uid = $s.NewUids[$code] } } }
                }
                elseif ($s.RefuseMembership -and $Path -like 'api/organisationUnitGroups/*') {
                    [pscustomobject]@{ StatusCode = 403; Body = [pscustomobject]@{ httpStatus = 'Forbidden'; httpStatusCode = 403; status = 'ERROR'; message = 'You do not have write access to the group' } }
                }
                else { [pscustomobject]@{ StatusCode = 200; Body = [pscustomobject]@{ httpStatus = 'OK'; httpStatusCode = 200; status = 'OK' } } }
            }
        }
        $script:groupId = { param($code) $s.Groups | Where-Object { $_.code -ceq $code } | ForEach-Object { $_.id } }.GetNewClosure()
        $script:state = $s
    }

    It 'creates the hospital below the country and the department below the hospital' {
        $result = Add-NeoIPCPartnerSite @script:params

        Should -Invoke -ModuleName NeoIPC-Tools Invoke-NeoIPCDhis2Post -Times 1 -Exactly -ParameterFilter {
            $Path -ceq 'api/organisationUnits' -and ($j = $Body | ConvertFrom-Json) -and $j.code -ceq 'DE_BER_CHA' -and $j.parent.id -ceq 'CountryUid01' -and
            $j.name -ceq 'Example Hospital' -and $j.shortName -ceq 'Example Hospital' -and $j.openingDate -ceq '2026-10-19'
        }
        Should -Invoke -ModuleName NeoIPC-Tools Invoke-NeoIPCDhis2Post -Times 1 -Exactly -ParameterFilter {
            $Path -ceq 'api/organisationUnits' -and ($j = $Body | ConvertFrom-Json) -and $j.code -ceq 'DE_BER_CHA_NEO' -and $j.parent.id -ceq 'HospitalUid1'
        }
        $result.Count | Should -Be 2
        $result[0].Kind | Should -BeExactly 'Hospital'
        $result[0].Created | Should -BeTrue
        $result[0].Id | Should -BeExactly 'HospitalUid1'
        $result[1].Id | Should -BeExactly 'DepartmentU1'
    }

    It 'takes the department code from the hospital code unless one is given' {
        $default = Add-NeoIPCPartnerSite @script:params -WhatIf
        $given = Add-NeoIPCPartnerSite @script:params -DepartmentCode DE_BER_CHA_NEO2 -WhatIf

        $default[1].Code | Should -BeExactly 'DE_BER_CHA_NEO'
        $given[1].Code | Should -BeExactly 'DE_BER_CHA_NEO2'
    }

    It 'sends no geometry when no position is given' {
        [void](Add-NeoIPCPartnerSite @script:params)

        Should -Invoke -ModuleName NeoIPC-Tools Invoke-NeoIPCDhis2Post -Times 0 -Exactly -ParameterFilter {
            $Path -ceq 'api/organisationUnits' -and ($Body | ConvertFrom-Json).PSObject.Properties.Name -contains 'geometry'
        }
    }

    It 'sends the hospital''s position as a point, longitude first, and gives the department the same' {
        [void](Add-NeoIPCPartnerSite @script:params -HospitalLatitude 52.52 -HospitalLongitude 13.405)

        foreach ($code in 'DE_BER_CHA', 'DE_BER_CHA_NEO') {
            Should -Invoke -ModuleName NeoIPC-Tools Invoke-NeoIPCDhis2Post -Times 1 -Exactly -ParameterFilter {
                $Path -ceq 'api/organisationUnits' -and ($j = $Body | ConvertFrom-Json) -and $j.code -ceq $code -and $j.geometry.type -ceq 'Point' -and
                $j.geometry.coordinates[0] -eq 13.405 -and $j.geometry.coordinates[1] -eq 52.52
            }
        }
    }

    It 'gives a department its own position when it has one' {
        [void](Add-NeoIPCPartnerSite @script:params -HospitalLatitude 52.52 -HospitalLongitude 13.405 -DepartmentLatitude 52.6 -DepartmentLongitude 13.5)

        Should -Invoke -ModuleName NeoIPC-Tools Invoke-NeoIPCDhis2Post -Times 1 -Exactly -ParameterFilter {
            $Path -ceq 'api/organisationUnits' -and ($j = $Body | ConvertFrom-Json) -and $j.code -ceq 'DE_BER_CHA_NEO' -and
            $j.geometry.coordinates[0] -eq 13.5 -and $j.geometry.coordinates[1] -eq 52.6
        }
        Should -Invoke -ModuleName NeoIPC-Tools Invoke-NeoIPCDhis2Post -Times 1 -Exactly -ParameterFilter {
            $Path -ceq 'api/organisationUnits' -and ($j = $Body | ConvertFrom-Json) -and $j.code -ceq 'DE_BER_CHA' -and $j.geometry.coordinates[1] -eq 52.52
        }
    }

    It 'gives only the department a position when only it has one' {
        [void](Add-NeoIPCPartnerSite @script:params -DepartmentLatitude 52.6 -DepartmentLongitude 13.5)

        Should -Invoke -ModuleName NeoIPC-Tools Invoke-NeoIPCDhis2Post -Times 1 -Exactly -ParameterFilter {
            $Path -ceq 'api/organisationUnits' -and ($j = $Body | ConvertFrom-Json) -and $j.code -ceq 'DE_BER_CHA' -and $j.PSObject.Properties.Name -notcontains 'geometry'
        }
    }

    It 'refuses a position that is <Name> before it writes anything' -ForEach @(
        @{ Name = 'half given'; Extra = @{ HospitalLatitude = 1.0 } }
        @{ Name = 'a department''s half'; Extra = @{ DepartmentLongitude = 1.0 } }
        @{ Name = 'a latitude beyond 90'; Extra = @{ HospitalLatitude = 91.0; HospitalLongitude = 0.0 } }
        @{ Name = 'a longitude beyond 180'; Extra = @{ DepartmentLatitude = 0.0; DepartmentLongitude = 181.0 } }
    ) {
        { Add-NeoIPCPartnerSite @script:params @Extra } | Should -Throw

        Should -Invoke -ModuleName NeoIPC-Tools Invoke-NeoIPCDhis2Post -Times 0 -Exactly
    }

    It 'puts the hospital in HOSPITAL, the department in NEO_DEPARTMENT, and the department in the program, through their owners' {
        $result = Add-NeoIPCPartnerSite @script:params

        $hospitalGroup = & $script:groupId 'HOSPITAL'
        $departmentGroup = & $script:groupId 'NEO_DEPARTMENT'
        Should -Invoke -ModuleName NeoIPC-Tools Invoke-NeoIPCDhis2Post -Times 1 -Exactly -ParameterFilter { $Path -ceq "api/organisationUnitGroups/$hospitalGroup/organisationUnits/HospitalUid1" }
        Should -Invoke -ModuleName NeoIPC-Tools Invoke-NeoIPCDhis2Post -Times 1 -Exactly -ParameterFilter { $Path -ceq "api/organisationUnitGroups/$departmentGroup/organisationUnits/DepartmentU1" }
        Should -Invoke -ModuleName NeoIPC-Tools Invoke-NeoIPCDhis2Post -Times 1 -Exactly -ParameterFilter { $Path -ceq 'api/programs/ProgramUid01/organisationUnits/DepartmentU1' }
        $result[0].GroupsAdded | Should -Be @('HOSPITAL')
        $result[1].GroupsAdded | Should -Be @('NEO_DEPARTMENT')
        $result[1].ProgramAssigned | Should -BeTrue
    }

    It 'adds the optional groups to the department only' {
        $result = Add-NeoIPCPartnerSite @script:params -AllPatientsEligible -TestUnit

        $result[0].GroupsAdded | Should -Be @('HOSPITAL')
        $result[1].GroupsAdded | Should -Be @('NEO_DEPARTMENT', 'NEOIPC_ALL_PATIENTS_ELIGIBLE', 'TEST_UNITS')
    }

    It 'keeps existing units and adds only what is missing' {
        $script:state.Units['DE_BER_CHA'] = [ordered]@{ id = 'HospitalUid1'; code = 'DE_BER_CHA'; parent = @{ id = 'CountryUid01' }; organisationUnitGroups = @(@{ code = 'HOSPITAL' }) }
        $script:state.Units['DE_BER_CHA_NEO'] = [ordered]@{ id = 'DepartmentU1'; code = 'DE_BER_CHA_NEO'; parent = @{ id = 'HospitalUid1' }; organisationUnitGroups = @(@{ code = 'NEO_DEPARTMENT' }) }

        $result = Add-NeoIPCPartnerSite @script:params

        Should -Invoke -ModuleName NeoIPC-Tools Invoke-NeoIPCDhis2Post -Times 0 -Exactly -ParameterFilter { $Path -ceq 'api/organisationUnits' }
        Should -Invoke -ModuleName NeoIPC-Tools Invoke-NeoIPCDhis2Post -Times 0 -Exactly -ParameterFilter { $Path -like 'api/organisationUnitGroups/*' }
        $result.Created | Should -Not -Contain $true
        $result[0].GroupsAdded.Count | Should -Be 0
    }

    It 'adds a membership an existing unit lacks' {
        $script:state.Units['DE_BER_CHA'] = [ordered]@{ id = 'HospitalUid1'; code = 'DE_BER_CHA'; parent = @{ id = 'CountryUid01' }; organisationUnitGroups = @() }

        $result = Add-NeoIPCPartnerSite @script:params

        $result[0].Created | Should -BeFalse
        $result[0].GroupsAdded | Should -Be @('HOSPITAL')
    }

    It 'writes nothing under -WhatIf and still reports what it would do' {
        $result = Add-NeoIPCPartnerSite @script:params -WhatIf

        Should -Invoke -ModuleName NeoIPC-Tools Invoke-NeoIPCDhis2Post -Times 0 -Exactly
        $result.Count | Should -Be 2
        $result.Created | Should -Not -Contain $true
    }

    It 'refuses <Name> before it writes anything' -ForEach @(
        @{ Name = 'a hospital below another org unit'; Setup = { $script:state.Units['DE_BER_CHA'] = [ordered]@{ id = 'HospitalUid1'; code = 'DE_BER_CHA'; parent = @{ id = 'ElsewhereU01' }; organisationUnitGroups = @() } }; Message = '*below another org unit*' }
        @{ Name = 'a department below another org unit while its hospital is missing'; Setup = { $script:state.Units['DE_BER_CHA_NEO'] = [ordered]@{ id = 'DepartmentU1'; code = 'DE_BER_CHA_NEO'; parent = @{ id = 'ElsewhereU01' }; organisationUnitGroups = @() } }; Message = '*department ''DE_BER_CHA_NEO'' exists below another org unit*does not exist yet*' }
        @{ Name = 'a department below another org unit than its hospital, which lacks a membership'; Setup = {
                $script:state.Units['DE_BER_CHA'] = [ordered]@{ id = 'HospitalUid1'; code = 'DE_BER_CHA'; parent = @{ id = 'CountryUid01' }; organisationUnitGroups = @() }
                $script:state.Units['DE_BER_CHA_NEO'] = [ordered]@{ id = 'DepartmentU1'; code = 'DE_BER_CHA_NEO'; parent = @{ id = 'ElsewhereU01' }; organisationUnitGroups = @() }
            }; Message = '*department ''DE_BER_CHA_NEO'' exists below another org unit than the hospital ''DE_BER_CHA''.'
        }
        @{ Name = 'a country outside the group COUNTRY'; Setup = { $script:state.Units['DE'].organisationUnitGroups = @() }; Message = '*not a member of the group COUNTRY*' }
        @{ Name = 'a group missing or not shared'; Setup = { $script:state.Groups = @($script:state.Groups | Where-Object { $_.code -cne 'HOSPITAL' }) }; Message = '*returns no org-unit group with the code HOSPITAL*not shared with this user*' }
        @{ Name = 'a program missing or not shared'; Setup = { $script:state.Programs = @() }; Message = '*returns no program with the code NEOIPC_CORE*not shared with this user*' }
    ) {
        & $Setup

        { Add-NeoIPCPartnerSite @script:params } | Should -Throw $Message
        { Add-NeoIPCPartnerSite @script:params -WhatIf } | Should -Throw $Message

        Should -Invoke -ModuleName NeoIPC-Tools Invoke-NeoIPCDhis2Post -Times 0 -Exactly
    }

    It 'leaves a department''s assignment to the program alone when it has it, and does not report one' {
        $script:state.Units['DE_BER_CHA'] = [ordered]@{ id = 'HospitalUid1'; code = 'DE_BER_CHA'; parent = @{ id = 'CountryUid01' }; organisationUnitGroups = @(@{ code = 'HOSPITAL' }); programs = @() }
        $script:state.Units['DE_BER_CHA_NEO'] = [ordered]@{ id = 'DepartmentU1'; code = 'DE_BER_CHA_NEO'; parent = @{ id = 'HospitalUid1' }; organisationUnitGroups = @(@{ code = 'NEO_DEPARTMENT' }); programs = @(@{ id = 'ProgramUid01' }) }

        $result = Add-NeoIPCPartnerSite @script:params

        Should -Invoke -ModuleName NeoIPC-Tools Invoke-NeoIPCDhis2Post -Times 0 -Exactly
        $result[1].ProgramAssigned | Should -BeFalse
    }

    It 'names the unit it created when a write after it is refused' {
        $script:state.RefuseMembership = $true

        { Add-NeoIPCPartnerSite @script:params } | Should -Throw '*created the hospital ''DE_BER_CHA'' with the id HospitalUid1, but a later write failed*write access*'

        Should -Invoke -ModuleName NeoIPC-Tools Invoke-NeoIPCDhis2Post -Times 0 -Exactly -ParameterFilter { $Path -ceq 'api/organisationUnits' -and ($Body | ConvertFrom-Json).code -ceq 'DE_BER_CHA_NEO' }
    }

    It 'names the hospital it created, and the group it added it to, when DHIS2 refuses the department' {
        $script:state.RefuseCode = 'DE_BER_CHA_NEO'

        { Add-NeoIPCPartnerSite @script:params } | Should -Throw '*created the hospital ''DE_BER_CHA'' with the id HospitalUid1; added it to the group HOSPITAL, but a later write failed*value DE_BER_CHA_NEO already exists*'
    }

    It 'refuses <Name> before it reads or writes anything' -ForEach @(
        @{ Name = 'the hospital''s code for the department'; Extra = @{ DepartmentCode = 'DE_BER_CHA' }; Message = '*department code ''DE_BER_CHA'' is the hospital''s code*' }
        @{ Name = 'a hospital code whose department code is longer than DHIS2 allows'; Extra = @{ HospitalCode = 'DE_BER_' + ('A' * 40) }; Message = '*department code*is 51 characters long, and DHIS2 allows 50*' }
        @{ Name = 'a coordinate that is not a number'; Extra = @{ HospitalLatitude = [double]::NaN; HospitalLongitude = 0.0 }; Message = '*latitude lies between*' }
    ) {
        $bad = $script:params.Clone()
        foreach ($key in $Extra.Keys) { $bad[$key] = $Extra[$key] }

        { Add-NeoIPCPartnerSite @bad } | Should -Throw $Message

        Should -Invoke -ModuleName NeoIPC-Tools Invoke-NeoIPCDhis2Get -Times 0 -Exactly
        Should -Invoke -ModuleName NeoIPC-Tools Invoke-NeoIPCDhis2Post -Times 0 -Exactly
    }

    It 'refuses a hospital code that does not begin with the country code' {
        $bad = $script:params.Clone()
        $bad.HospitalCode = 'AT_VIE_AKH'

        { Add-NeoIPCPartnerSite @bad } | Should -Throw '*does not begin with the country code*'
    }

    It 'refuses a short name of more than 50 characters instead of cutting the name' {
        $bad = $script:params.Clone()
        $bad.HospitalName = 'H' * 51

        { Add-NeoIPCPartnerSite @bad } | Should -Throw '*give a short name*'

        $bad.HospitalShortName = 'Short'
        { Add-NeoIPCPartnerSite @bad -WhatIf } | Should -Not -Throw
    }

    It 'warns about a country without a World Bank income class' {
        $script:state.Units['DE'].organisationUnitGroups = @(@{ code = 'COUNTRY' })

        $warnings = @(Add-NeoIPCPartnerSite @script:params -WhatIf 3>&1 | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })

        $warnings.Message | Should -BeLike '*no World Bank income class*'
    }

    It 'does not warn about the income class of a country that has one' {
        $warnings = @(Add-NeoIPCPartnerSite @script:params -WhatIf 3>&1 | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })

        $warnings.Count | Should -Be 0
    }

    It 'ends with DHIS2''s own reason when it refuses the hospital, and goes no further' {
        $script:state.Refuse = $true

        { Add-NeoIPCPartnerSite @script:params } | Should -Throw '*Property code with value DE_BER_CHA already exists*'

        Should -Invoke -ModuleName NeoIPC-Tools Invoke-NeoIPCDhis2Post -Times 1 -Exactly
    }

    It 'takes no answer with a success code for a unit created unless it is DHIS2''s: <Name>' -ForEach @(
        @{ Name = 'a firewall''s page'; Answer = [pscustomobject]@{ StatusCode = 200; Body = '<html><body>Request blocked</body></html>' }; Message = '*HTTP 200: the answer is not DHIS2''s: Request blocked*' }
        @{ Name = 'an answer without the status DHIS2 gives'; Answer = [pscustomobject]@{ StatusCode = 201; Body = [pscustomobject]@{ status = 'OK'; response = [pscustomobject]@{ uid = 'HospitalUid1' } } }; Message = '*HTTP 201: the answer is not DHIS2''s*' }
        @{ Name = 'DHIS2''s answer with a status other than OK'; Answer = [pscustomobject]@{ StatusCode = 201; Body = [pscustomobject]@{ httpStatus = 'Created'; httpStatusCode = 201; status = 'WARNING'; response = [pscustomobject]@{ uid = 'HospitalUid1' } } }; Message = '*failed with HTTP 201*' }
        @{ Name = 'DHIS2''s answer without the id of what it created'; Answer = [pscustomobject]@{ StatusCode = 201; Body = [pscustomobject]@{ httpStatus = 'Created'; httpStatusCode = 201; status = 'OK'; response = [pscustomobject]@{} } }; Message = '*answer to the creation of the hospital ''DE_BER_CHA'' names no id*' }
    ) {
        $script:state.AnswerCode = 'DE_BER_CHA'
        $script:state.Answer = $Answer

        { Add-NeoIPCPartnerSite @script:params } | Should -Throw $Message

        Should -Invoke -ModuleName NeoIPC-Tools Invoke-NeoIPCDhis2Post -Times 1 -Exactly
    }

    Context 'a country the instance lacks' {
        BeforeEach {
            $script:params.CountryCode = 'AR'
            $script:params.HospitalCode = 'AR_BUE_HOS'
        }

        It 'creates it from the country list before the hospital: its UID, name, and opening date, below the parent the list names' {
            $result = Add-NeoIPCPartnerSite @script:params

            Should -Invoke -ModuleName NeoIPC-Tools Invoke-NeoIPCDhis2Post -Times 1 -Exactly -ParameterFilter {
                $Path -ceq 'api/organisationUnits' -and ($j = $Body | ConvertFrom-Json) -and $j.id -ceq 'ArgentinaU1' -and $j.code -ceq 'AR' -and
                $j.name -ceq 'Argentina' -and $j.shortName -ceq 'Argentina' -and $j.openingDate -ceq '2023-01-01' -and $j.parent.id -ceq 'RootUid0001'
            }
            # The hospital goes below the country the call created.
            Should -Invoke -ModuleName NeoIPC-Tools Invoke-NeoIPCDhis2Post -Times 1 -Exactly -ParameterFilter {
                $Path -ceq 'api/organisationUnits' -and ($j = $Body | ConvertFrom-Json) -and $j.code -ceq 'AR_BUE_HOS' -and $j.parent.id -ceq 'ArgentinaU1' -and
                $j.openingDate -ceq '2026-10-19' -and $j.PSObject.Properties.Name -notcontains 'id'
            }
            $result.Count | Should -Be 3
            $result[0].Kind | Should -BeExactly 'Country'
            $result[0].Code | Should -BeExactly 'AR'
            $result[0].Id | Should -BeExactly 'ArgentinaU1'
            $result[0].Created | Should -BeTrue
            $result[1].Kind | Should -BeExactly 'Hospital'
        }

        It 'puts it in COUNTRY and in the income-class groups the country list names' {
            $result = Add-NeoIPCPartnerSite @script:params

            foreach ($code in 'COUNTRY', 'WORLD_BANK_CLASS_UM_FY_2025', 'WORLD_BANK_CLASS_UM_FY_2026') {
                $group = & $script:groupId $code
                Should -Invoke -ModuleName NeoIPC-Tools Invoke-NeoIPCDhis2Post -Times 1 -Exactly -ParameterFilter { $Path -ceq "api/organisationUnitGroups/$group/organisationUnits/ArgentinaU1" }
            }
            $result[0].GroupsAdded | Should -Be @('COUNTRY', 'WORLD_BANK_CLASS_UM_FY_2025', 'WORLD_BANK_CLASS_UM_FY_2026')
            $result[0].PSObject.Properties.Name | Should -Not -Contain 'ProgramAssigned'
        }

        It 'lists it under -WhatIf with the rest, and writes nothing' {
            $result = Add-NeoIPCPartnerSite @script:params -WhatIf

            Should -Invoke -ModuleName NeoIPC-Tools Invoke-NeoIPCDhis2Post -Times 0 -Exactly
            $result.Count | Should -Be 3
            $result[0].Kind | Should -BeExactly 'Country'
            $result.Created | Should -Not -Contain $true
        }

        It 'warns about a country the list gives no income class, and still creates it' {
            $script:params.CountryCode = 'UY'
            $script:params.HospitalCode = 'UY_MVD_HOS'

            $output = @(Add-NeoIPCPartnerSite @script:params 3>&1)

            @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }).Message | Should -BeLike '*joins no World Bank income class group in the country list*'
            @($output | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] })[0].GroupsAdded | Should -Be @('COUNTRY')
        }

        It 'names the country it created, and its groups, when a later write is refused' {
            $script:state.RefuseCode = 'AR_BUE_HOS'

            { Add-NeoIPCPartnerSite @script:params } | Should -Throw '*created the country ''AR'' with the id ArgentinaU1; added it to the groups COUNTRY, WORLD_BANK_CLASS_UM_FY_2025, and WORLD_BANK_CLASS_UM_FY_2026, but a later write failed*value AR_BUE_HOS already exists*'
        }

        It 'stops before the hospital when DHIS2 gives the country another UID than the list' {
            $script:state.NewUids['AR'] = 'OtherUid001'

            { Add-NeoIPCPartnerSite @script:params } | Should -Throw '*created the country ''AR'' with the id OtherUid001 instead of ArgentinaU1*'

            Should -Invoke -ModuleName NeoIPC-Tools Invoke-NeoIPCDhis2Post -Times 0 -Exactly -ParameterFilter { $Path -ceq 'api/organisationUnits' -and ($Body | ConvertFrom-Json).code -ceq 'AR_BUE_HOS' }
        }

        It 'refuses <Name> before it writes anything' -ForEach @(
            @{ Name = 'a parent the list names outside the hierarchy'; Setup = { $script:state.Units.Remove('NEOIPC') }; Message = '*cannot be created there*parent in the country list, ''NEOIPC'', lies outside that hierarchy too*' }
            @{ Name = 'an org unit below the parent with the country''s name under another code'; Setup = { $script:state.Units['ARG'] = [ordered]@{ id = 'OtherArgUid'; code = 'ARG'; name = ' argentina '; parent = @{ id = 'RootUid0001' }; organisationUnitGroups = @() } }; Message = '*'' argentina '' below ''NEOIPC'' carries the country''s name under the code ''ARG''*' }
            @{ Name = 'an org unit that carries the country''s UID'; Setup = { $script:state.Units['XX'] = [ordered]@{ id = 'ArgentinaU1'; code = 'XX'; name = 'Elsewhere'; parent = @{ id = 'CountryUid01' }; organisationUnitGroups = @() } }; Message = '*org unit ''XX'' there carries the UID ArgentinaU1*' }
            @{ Name = 'a hospital that exists while its country does not'; Setup = { $script:state.Units['AR_BUE_HOS'] = [ordered]@{ id = 'HospitalUid2'; code = 'AR_BUE_HOS'; name = 'Example'; parent = @{ id = 'CountryUid01' }; organisationUnitGroups = @() } }; Message = '*hospital ''AR_BUE_HOS'' exists below another org unit than the country ''AR''*' }
            @{ Name = 'an income-class group missing or not shared'; Setup = { $script:state.Groups = @($script:state.Groups | Where-Object { $_.code -cne 'WORLD_BANK_CLASS_UM_FY_2026' }) }; Message = '*returns no org-unit group with the code WORLD_BANK_CLASS_UM_FY_2026*' }
        ) {
            & $Setup

            { Add-NeoIPCPartnerSite @script:params } | Should -Throw $Message
            { Add-NeoIPCPartnerSite @script:params -WhatIf } | Should -Throw $Message

            Should -Invoke -ModuleName NeoIPC-Tools Invoke-NeoIPCDhis2Post -Times 0 -Exactly
        }
    }

    Context 'a country the instance and the country list lack' {
        BeforeEach {
            $script:params.CountryCode = 'KE'
            $script:params.HospitalCode = 'KE_NBO_EXH'
        }

        It 'adds it to the list first, then creates it with the UID the list gives it' {
            $result = @(Add-NeoIPCPartnerSite @script:params 3>$null)

            $script:state.ListWrites | Should -Be @('KE')
            Should -Invoke -ModuleName NeoIPC-Tools Invoke-NeoIPCDhis2Post -Times 1 -Exactly -ParameterFilter {
                $Path -ceq 'api/organisationUnits' -and ($j = $Body | ConvertFrom-Json) -and $j.id -ceq 'KenyaUid001' -and $j.code -ceq 'KE' -and
                $j.name -ceq 'Kenya' -and $j.openingDate -ceq '2023-01-01' -and $j.parent.id -ceq 'RootUid0001'
            }
            Should -Invoke -ModuleName NeoIPC-Tools Invoke-NeoIPCDhis2Post -Times 1 -Exactly -ParameterFilter {
                $Path -ceq 'api/organisationUnits' -and ($Body | ConvertFrom-Json).code -ceq 'KE_NBO_EXH' -and ($Body | ConvertFrom-Json).parent.id -ceq 'KenyaUid001'
            }
            $result[0].Kind | Should -BeExactly 'Country'
            $result[0].AddedToList | Should -BeTrue
            $result[0].GroupsAdded | Should -Be @('COUNTRY', 'WORLD_BANK_CLASS_LM_FY_2025', 'WORLD_BANK_CLASS_LM_FY_2026')
            Get-Content -LiteralPath $script:listFile -Raw | Should -BeExactly 'after'
        }

        It 'reminds that the files of the list are to be committed, naming each' {
            $warnings = @(Add-NeoIPCPartnerSite @script:params 3>&1 | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })

            $warnings.Count | Should -Be 1
            $warnings.Message | Should -BeLike '*added the country ''KE'' to the country list with the UID KenyaUid001, in *list-stand-in.txt, *memberships-stand-in.txt, and *play-stand-in.txt of*commit them*'
        }

        It 'says that the call stopped only when it stopped, not after a failure it names itself' {
            $script:state.RefuseCode = 'KE'

            $output = @(try { Add-NeoIPCPartnerSite @script:params 3>&1 } catch { $_ })

            $output[-1] | Should -BeOfType ([System.Management.Automation.ErrorRecord])
            @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] -and $_.Message -like '*stopped after*' }).Count | Should -Be 0
        }

        It 'gives the list the country name and short name it is given' {
            [void](Add-NeoIPCPartnerSite @script:params -CountryName 'Republic of Kenya' -CountryShortName 'Kenya' 3>$null)

            Should -Invoke -ModuleName NeoIPC-Tools Get-NeoIPCMetadataCountryPlan -Times 1 -Exactly -ParameterFilter { $Name -ceq 'Republic of Kenya' -and $ShortName -ceq 'Kenya' }
            Should -Invoke -ModuleName NeoIPC-Tools Invoke-NeoIPCDhis2Post -Times 1 -Exactly -ParameterFilter {
                $Path -ceq 'api/organisationUnits' -and ($j = $Body | ConvertFrom-Json) -and $j.code -ceq 'KE' -and $j.name -ceq 'Republic of Kenya' -and $j.shortName -ceq 'Kenya'
            }
        }

        It 'lists the addition under -WhatIf, and writes neither the list nor DHIS2' {
            $result = @(Add-NeoIPCPartnerSite @script:params -WhatIf)

            Should -Invoke -ModuleName NeoIPC-Tools Write-NeoIPCMetadataCountryPlan -Times 0 -Exactly
            Should -Invoke -ModuleName NeoIPC-Tools Invoke-NeoIPCDhis2Post -Times 0 -Exactly
            $result[0].Kind | Should -BeExactly 'Country'
            $result[0].AddedToList | Should -BeFalse
            Get-Content -LiteralPath $script:listFile -Raw | Should -BeExactly 'before'
        }

        It 'leaves the list as it was when DHIS2 refuses the country and does not hold it' {
            $script:state.RefuseCode = 'KE'

            { Add-NeoIPCPartnerSite @script:params } | Should -Throw '*DHIS2 refused the country ''KE'' and does not hold it, so the country list is as it was before the call*value KE already exists*'

            foreach ($file in $script:listFiles) { Get-Content -LiteralPath $file -Raw | Should -BeExactly 'before' }
            Should -Invoke -ModuleName NeoIPC-Tools Resolve-NeoIPCOrgUnit -Times 1 -Exactly -ParameterFilter { $Id -ccontains 'KenyaUid001' -and -not $Code }
            Should -Invoke -ModuleName NeoIPC-Tools Invoke-NeoIPCDhis2Post -Times 0 -Exactly -ParameterFilter { $Path -ceq 'api/organisationUnits' -and ($Body | ConvertFrom-Json).code -ceq 'KE_NBO_EXH' }
        }

        It 'names a file of the list it could not put back when DHIS2 refuses the country, and puts back the others' {
            $script:state.RefuseCode = 'KE'
            $script:state.UnrestorablePath = (New-Item -ItemType Directory -Path (Join-Path -Path $TestDrive -ChildPath "unrestorable-$([guid]::NewGuid().ToString('N'))")).FullName

            { Add-NeoIPCPartnerSite @script:params } | Should -Throw "*DHIS2 refused the country 'KE' and does not hold it, so the call put the country list back but for $($script:state.UnrestorablePath), which changed since*value KE already exists*"

            foreach ($file in $script:listFiles) { Get-Content -LiteralPath $file -Raw | Should -BeExactly 'before' }
        }

        It 'keeps the change another run made to a file of the list since, naming it, when DHIS2 refuses the country' {
            $script:state.RefuseCode = 'KE'
            $script:state.ChangedByOtherRun = $script:listFiles[1]

            { Add-NeoIPCPartnerSite @script:params } | Should -Throw "*so the call put the country list back but for $($script:listFiles[1]), which changed since*value KE already exists*"

            Get-Content -LiteralPath $script:listFiles[0] -Raw | Should -BeExactly 'before'
            Get-Content -LiteralPath $script:listFiles[1] -Raw | Should -BeExactly 'other run'
            Get-Content -LiteralPath $script:listFiles[2] -Raw | Should -BeExactly 'before'
        }

        It 'keeps the list entry when DHIS2 refuses the country but holds it, as after an error that follows the commit' {
            $script:state.CommitThenRefuse = 'KE'

            { Add-NeoIPCPartnerSite @script:params } | Should -Throw '*DHIS2 refused the country ''KE'' but holds it with the id KenyaUid001, so the country list keeps it, and the next run completes the country; commit *play-stand-in.txt*value KE already exists*'

            foreach ($file in $script:listFiles) { Get-Content -LiteralPath $file -Raw | Should -BeExactly 'after' }
        }

        It 'keeps the list entry when DHIS2 refuses the country and whether it holds it cannot be read' {
            $script:state.RefuseCode = 'KE'
            $script:state.FailIdRead = $true

            { Add-NeoIPCPartnerSite @script:params } | Should -Throw '*DHIS2 refused the country ''KE'', and whether it holds the country could not be read, so the country list keeps it with the id KenyaUid001*value KE already exists*'

            foreach ($file in $script:listFiles) { Get-Content -LiteralPath $file -Raw | Should -BeExactly 'after' }
        }

        It 'reminds that the list entry is to be kept and committed when the call is stopped while it creates the country' {
            $script:state.StopCode = 'KE'
            # A stop ends a pipeline, so the call runs in a pipeline of its own, as a stopped command would in a session.
            $nested = [powershell]::Create([System.Management.Automation.RunspaceMode]::CurrentRunspace)
            try {
                [void]$nested.AddScript('param($Call) Add-NeoIPCPartnerSite @Call 3>&1').AddArgument($script:params)
                $output = @($nested.Invoke())
            }
            finally {
                $nested.Dispose()
            }

            @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }).Message | Should -BeLike '*stopped after it added the country ''KE'' to the country list with the id KenyaUid001, in *play-stand-in.txt*keep the entry and commit the files*'
            foreach ($file in $script:listFiles) { Get-Content -LiteralPath $file -Raw | Should -BeExactly 'after' }
        }

        It 'writes nothing to DHIS2 when the list cannot be written' {
            $script:state.RefuseListWrite = $true

            { Add-NeoIPCPartnerSite @script:params } | Should -Throw '*could not be added to the country list*as they were*disk is full*'

            Should -Invoke -ModuleName NeoIPC-Tools Invoke-NeoIPCDhis2Post -Times 0 -Exactly
        }

        It 'keeps the list entry when DHIS2 created the country though its answer failed' {
            $script:state.CommitThenFail = 'KE'

            { Add-NeoIPCPartnerSite @script:params } | Should -Throw '*Creating the country ''KE'' failed without DHIS2 refusing it*keeps it with the id KenyaUid001*commit *list-stand-in.txt, *memberships-stand-in.txt, and *play-stand-in.txt of*Bad Gateway*'

            Get-Content -LiteralPath $script:listFile -Raw | Should -BeExactly 'after'
            Should -Invoke -ModuleName NeoIPC-Tools Invoke-NeoIPCDhis2Post -Times 0 -Exactly -ParameterFilter { $Path -ceq 'api/organisationUnits' -and ($Body | ConvertFrom-Json).code -ceq 'KE_NBO_EXH' }
        }

        It 'keeps the list entry when <Name>, since only DHIS2''s own refusal shows that it created nothing' -ForEach @(
            @{ Name = 'the connection drops'; Setup = { $script:state.DropCode = 'KE' }; Message = '*connection was reset*' }
            @{ Name = 'a gateway refuses the request with a page of its own'; Setup = { $script:state.AnswerCode = 'KE'; $script:state.Answer = [pscustomobject]@{ StatusCode = 413; Body = '<html><body>Request Entity Too Large</body></html>' } }; Message = '*HTTP 413*Request Entity Too Large*' }
            @{ Name = 'DHIS2 answers with a server error'; Setup = { $script:state.AnswerCode = 'KE'; $script:state.Answer = [pscustomobject]@{ StatusCode = 500; Body = [pscustomobject]@{ httpStatus = 'Internal Server Error'; httpStatusCode = 500; status = 'ERROR'; message = 'An unexpected error occurred' } } }; Message = '*HTTP 500*An unexpected error occurred*' }
            @{ Name = 'a firewall answers with a page of its own and a success code'; Setup = { $script:state.AnswerCode = 'KE'; $script:state.Answer = [pscustomobject]@{ StatusCode = 200; Body = '<html><body>Request blocked</body></html>' } }; Message = '*HTTP 200: the answer is not DHIS2''s: Request blocked*' }
        ) {
            & $Setup

            { Add-NeoIPCPartnerSite @script:params } | Should -Throw "*Creating the country 'KE' failed without DHIS2 refusing it*keeps it with the id KenyaUid001*commit *play-stand-in.txt of*$Message"

            Get-Content -LiteralPath $script:listFile -Raw | Should -BeExactly 'after'
            Should -Invoke -ModuleName NeoIPC-Tools Invoke-NeoIPCDhis2Post -Times 0 -Exactly -ParameterFilter { $Path -ceq 'api/organisationUnits' -and ($Body | ConvertFrom-Json).code -ceq 'KE_NBO_EXH' }
        }

        It 'takes no answer the session holds for the one it did not get when the connection drops' {
            $script:state.DropCode = 'KE'
            Set-Variable -Name response -Scope Global -Value ([pscustomobject]@{ StatusCode = 409; Body = [pscustomobject]@{ status = 'ERROR'; message = 'An answer from earlier' } })
            try {
                { Add-NeoIPCPartnerSite @script:params } | Should -Throw '*failed without DHIS2 refusing it*connection was reset*'
            }
            finally {
                Remove-Variable -Name response -Scope Global -ErrorAction SilentlyContinue
            }

            Get-Content -LiteralPath $script:listFile -Raw | Should -BeExactly 'after'
        }

        It 'does not ask to commit the list when DHIS2 gives the country another UID than the list' {
            $script:state.NewUids['KE'] = 'OtherKenya1'

            $thrown = { Add-NeoIPCPartnerSite @script:params } | Should -Throw '*created the country ''KE'' with the id OtherKenya1 instead of KenyaUid001*' -PassThru

            $thrown.Exception.Message | Should -Not -BeLike '*which give the country*'
        }

        It 'keeps the list entry, names everything it wrote, and reminds to commit the files of the list when a write after the country fails' {
            $script:state.RefuseCode = 'KE_NBO_EXH'

            { Add-NeoIPCPartnerSite @script:params } | Should -Throw '*added the country ''KE'' to the country list with the id KenyaUid001, in *list-stand-in.txt*; created the country ''KE'' with the id KenyaUid001; added it to the groups COUNTRY, WORLD_BANK_CLASS_LM_FY_2025, and WORLD_BANK_CLASS_LM_FY_2026, but a later write failed*value KE_NBO_EXH already exists*Commit *list-stand-in.txt, *memberships-stand-in.txt, and *play-stand-in.txt of*, which give the country ''KE'' the id KenyaUid001*'

            Get-Content -LiteralPath $script:listFile -Raw | Should -BeExactly 'after'
        }

        It 'refuses <Name> before it writes the list' -ForEach @(
            @{ Name = 'a country the World Bank cannot classify'; Setup = { $script:state.Plans.Remove('KE') }; Message = '*knows no economy with the code ''KE''*' }
            @{ Name = 'an org unit below the parent with the country''s name under another code'; Setup = { $script:state.Units['KEN'] = [ordered]@{ id = 'KenyaOther1'; code = 'KEN'; name = 'Kenya'; parent = @{ id = 'RootUid0001' }; organisationUnitGroups = @() } }; Message = '*''Kenya'' below ''NEOIPC'' carries the country''s name under the code ''KEN''*' }
            @{ Name = 'a parent outside the hierarchy'; Setup = { $script:state.Units.Remove('NEOIPC') }; Message = '*parent in the country list, ''NEOIPC'', lies outside that hierarchy too*' }
            @{ Name = 'an income-class group missing or not shared'; Setup = { $script:state.Groups = @($script:state.Groups | Where-Object { $_.code -cne 'WORLD_BANK_CLASS_LM_FY_2026' }) }; Message = '*returns no org-unit group with the code WORLD_BANK_CLASS_LM_FY_2026*' }
        ) {
            & $Setup

            { Add-NeoIPCPartnerSite @script:params } | Should -Throw $Message
            { Add-NeoIPCPartnerSite @script:params -WhatIf } | Should -Throw $Message

            Should -Invoke -ModuleName NeoIPC-Tools Write-NeoIPCMetadataCountryPlan -Times 0 -Exactly
            Should -Invoke -ModuleName NeoIPC-Tools Invoke-NeoIPCDhis2Post -Times 0 -Exactly
        }
    }

    Context 'a country that exists with the UID the country list gives it' {
        BeforeEach {
            $script:params.CountryCode = 'AR'
            $script:params.HospitalCode = 'AR_BUE_HOS'
            # As a run cut short after creating the country leaves it: in one of its groups.
            $script:state.Units['AR'] = [ordered]@{ id = 'ArgentinaU1'; code = 'AR'; name = 'Argentina'; parent = @{ id = 'RootUid0001' }; organisationUnitGroups = @(@{ code = 'WORLD_BANK_CLASS_UM_FY_2025' }) }
        }

        It 'completes it from the list: COUNTRY, and the income class of each year it has none for' {
            $result = @(Add-NeoIPCPartnerSite @script:params 3>$null)

            Should -Invoke -ModuleName NeoIPC-Tools Invoke-NeoIPCDhis2Post -Times 0 -Exactly -ParameterFilter { $Path -ceq 'api/organisationUnits' -and ($Body | ConvertFrom-Json).code -ceq 'AR' }
            foreach ($code in 'COUNTRY', 'WORLD_BANK_CLASS_UM_FY_2026') {
                $group = & $script:groupId $code
                Should -Invoke -ModuleName NeoIPC-Tools Invoke-NeoIPCDhis2Post -Times 1 -Exactly -ParameterFilter { $Path -ceq "api/organisationUnitGroups/$group/organisationUnits/ArgentinaU1" }
            }
            $result[0].Kind | Should -BeExactly 'Country'
            $result[0].Created | Should -BeFalse
            $result[0].GroupsAdded | Should -Be @('COUNTRY', 'WORLD_BANK_CLASS_UM_FY_2026')
            $result[1].Kind | Should -BeExactly 'Hospital'
            Should -Invoke -ModuleName NeoIPC-Tools Write-NeoIPCMetadataCountryPlan -Times 0 -Exactly
        }

        It 'leaves a class the instance gives for a year the list gives another for, with a warning' {
            $script:state.Units['AR'].organisationUnitGroups = @(@{ code = 'COUNTRY' }, @{ code = 'WORLD_BANK_CLASS_H_FY_2025' })

            $output = @(Add-NeoIPCPartnerSite @script:params 3>&1)

            @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }).Message | Should -BeLike '*puts the country ''AR'' in WORLD_BANK_CLASS_H_FY_2025 for fiscal year 2025, the country list in WORLD_BANK_CLASS_UM_FY_2025*'
            @($output | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] })[0].GroupsAdded | Should -Be @('WORLD_BANK_CLASS_UM_FY_2026')
        }

        It 'adds nothing to a country that has what the list gives it' {
            $script:state.Units['AR'].organisationUnitGroups = @(@{ code = 'COUNTRY' }, @{ code = 'WORLD_BANK_CLASS_UM_FY_2025' }, @{ code = 'WORLD_BANK_CLASS_UM_FY_2026' })

            $result = @(Add-NeoIPCPartnerSite @script:params)

            $result.Count | Should -Be 2
            $result[0].Kind | Should -BeExactly 'Hospital'
            Should -Invoke -ModuleName NeoIPC-Tools Invoke-NeoIPCDhis2Post -Times 0 -Exactly -ParameterFilter { $Path -like '*/organisationUnits/ArgentinaU1' }
        }

        It 'leaves out, with a warning, a group the instance lacks that would only complete the country' {
            $script:state.Groups = @($script:state.Groups | Where-Object { $_.code -cne 'WORLD_BANK_CLASS_UM_FY_2026' })
            $script:state.Units['AR'].organisationUnitGroups = @(@{ code = 'COUNTRY' }, @{ code = 'WORLD_BANK_CLASS_UM_FY_2025' })

            $output = @(Add-NeoIPCPartnerSite @script:params 3>&1)

            @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }).Message | Should -BeLike '*returns no org-unit group with the code WORLD_BANK_CLASS_UM_FY_2026*does not join it*'
            $records = @($output | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] })
            $records.Count | Should -Be 2
            $records[0].Kind | Should -BeExactly 'Hospital'
            $records[0].Created | Should -BeTrue
        }

        It 'refuses a country outside COUNTRY whose UID is not the one the list gives it' {
            $script:state.Units['AR'] = [ordered]@{ id = 'OtherArgUid'; code = 'AR'; name = 'Argentina'; parent = @{ id = 'RootUid0001' }; organisationUnitGroups = @() }

            { Add-NeoIPCPartnerSite @script:params } | Should -Throw '*not a member of the group COUNTRY*'

            Should -Invoke -ModuleName NeoIPC-Tools Invoke-NeoIPCDhis2Post -Times 0 -Exactly
        }

        It 'names the memberships it added to the country when a later write fails, without a reminder about the list' {
            $script:state.RefuseCode = 'AR_BUE_HOS'

            $thrown = { Add-NeoIPCPartnerSite @script:params } | Should -Throw '*The call added the country ''AR'' with the id ArgentinaU1 to the groups COUNTRY and WORLD_BANK_CLASS_UM_FY_2026, but a later write failed*value AR_BUE_HOS already exists*' -PassThru

            $thrown.Exception.Message | Should -Not -BeLike '*which give the country*'
        }

        It 'ends the call when the instance lacks COUNTRY, which no completion leaves out' {
            $script:state.Groups = @($script:state.Groups | Where-Object { $_.code -cne 'COUNTRY' })

            { Add-NeoIPCPartnerSite @script:params } | Should -Throw '*returns no org-unit group with the code COUNTRY*'
            { Add-NeoIPCPartnerSite @script:params -WhatIf } | Should -Throw '*returns no org-unit group with the code COUNTRY*'

            Should -Invoke -ModuleName NeoIPC-Tools Invoke-NeoIPCDhis2Post -Times 0 -Exactly
        }
    }
}
