#Requires -Version 7.6

<#
.SYNOPSIS
    Pester tests for New-NeoIPCHospitalCode.

.DESCRIPTION
    Covers Public/Onboarding.ps1 and Private/Onboarding.ps1: the shape the cmdlet accepts, the code it builds, and
    how it asks for a missing part. Only what lies outside the module is mocked, the prompt and the browser's start;
    the tests that are asked something run only where the session has a user, as the cmdlets themselves decide.

.EXAMPLE
    Invoke-Pester -Path scripts/modules/NeoIPC-Tools/Tests/Onboarding.Tests.ps1
#>

$ErrorActionPreference = 'Stop'

BeforeDiscovery {
    # Whether a person could be asked here; a test that expects a question is skipped where nobody could be.
    $script:noUser = -not [Environment]::UserInteractive
}

BeforeAll {
    Import-Module -Name (Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'NeoIPC-Tools.psd1') -Force
}

Describe 'New-NeoIPCHospitalCode' {
    It 'joins the UN/LOCODE parts and the acronym with underscores' {
        New-NeoIPCHospitalCode -Country DE -Location BER -Acronym CHA | Should -BeExactly 'DE_BER_CHA'
    }

    It 'accepts the digits 2 to 9 in the location and digits in the acronym' {
        New-NeoIPCHospitalCode -Country GB -Location LH2 -Acronym UCL2 | Should -BeExactly 'GB_LH2_UCL2'
    }

    It 'refuses <Name>' -ForEach @(
        @{ Name = 'a lower-case country'; Country = 'de'; Location = 'BER'; Acronym = 'CHA' }
        @{ Name = 'a three-letter country'; Country = 'DEU'; Location = 'BER'; Acronym = 'CHA' }
        @{ Name = 'a lower-case location'; Country = 'DE'; Location = 'ber'; Acronym = 'CHA' }
        @{ Name = 'a location with the digit 1'; Country = 'DE'; Location = 'BE1'; Acronym = 'CHA' }
        @{ Name = 'a two-character location'; Country = 'DE'; Location = 'BE'; Acronym = 'CHA' }
        @{ Name = 'an acronym with an underscore'; Country = 'DE'; Location = 'BER'; Acronym = 'C_HA' }
        @{ Name = 'a lower-case acronym'; Country = 'DE'; Location = 'BER'; Acronym = 'Cha' }
    ) {
        { New-NeoIPCHospitalCode -Country $Country -Location $Location -Acronym $Acronym } | Should -Throw
    }
}

Describe 'New-NeoIPCHospitalCode asking for a missing part' {
    BeforeEach {
        # The answers a person would type, in order; the mock's closure holds the queue and takes the next one.
        $queue = [System.Collections.Generic.Queue[string]]::new()
        Mock -ModuleName NeoIPC-Tools Start-Process { }
        Mock -ModuleName NeoIPC-Tools Read-Host -MockWith ({ $queue.Dequeue() }.GetNewClosure())
    }

    It 'asks for nothing and opens nothing when every part is given' {
        New-NeoIPCHospitalCode -Country DE -Location BER -Acronym CHA | Should -BeExactly 'DE_BER_CHA'

        Should -Invoke -ModuleName NeoIPC-Tools Start-Process -Times 0 -Exactly
        Should -Invoke -ModuleName NeoIPC-Tools Read-Host -Times 0 -Exactly
    }

    It 'opens the list of countries before it asks for the country, and the directory of that country before it asks for the location' -Skip:$noUser {
        $queue.Enqueue('DE')
        $queue.Enqueue('BER')
        # The mocks run in the module's scope, where their parameters bind and a list of events can be kept.
        $answers = @($queue.ToArray())
        InModuleScope NeoIPC-Tools -Parameters @{ Answers = $answers } {
            $script:events = [System.Collections.Generic.List[string]]::new()
            $script:answers = [System.Collections.Generic.Queue[string]]::new([string[]]$Answers)
            Mock Start-Process { $script:events.Add("open $FilePath") }
            Mock Read-Host { $script:events.Add('ask'); $script:answers.Dequeue() }
        }

        New-NeoIPCHospitalCode -Acronym CHA | Should -BeExactly 'DE_BER_CHA'

        InModuleScope NeoIPC-Tools { $script:events } | Should -Be @(
            'open https://unece.org/trade/cefact/unlocode-code-list-country-and-territory', 'ask',
            'open https://unlocode.unece.org/directory/locodes?country=DE', 'ask')
    }

    It 'opens the directory of the given country when only the location is missing' -Skip:$noUser {
        $queue.Enqueue('BER')

        New-NeoIPCHospitalCode -Country DE -Acronym CHA | Should -BeExactly 'DE_BER_CHA'

        Should -Invoke -ModuleName NeoIPC-Tools Start-Process -Times 1 -Exactly -ParameterFilter { $FilePath -ceq 'https://unlocode.unece.org/directory/locodes?country=DE' }
        Should -Invoke -ModuleName NeoIPC-Tools Read-Host -Times 1 -Exactly
    }

    It 'opens the list of countries when only the location is given' -Skip:$noUser {
        $queue.Enqueue('DE')

        New-NeoIPCHospitalCode -Location BER -Acronym CHA | Should -BeExactly 'DE_BER_CHA'

        Should -Invoke -ModuleName NeoIPC-Tools Start-Process -Times 1 -Exactly -ParameterFilter { $FilePath -ceq 'https://unece.org/trade/cefact/unlocode-code-list-country-and-territory' }
    }

    It 'asks for the acronym without opening a browser, since the directory does not hold it' -Skip:$noUser {
        $queue.Enqueue('CHA')

        New-NeoIPCHospitalCode -Country DE -Location BER | Should -BeExactly 'DE_BER_CHA'

        Should -Invoke -ModuleName NeoIPC-Tools Start-Process -Times 0 -Exactly
    }

    It 'asks again after an answer of the wrong shape' -Skip:$noUser {
        $queue.Enqueue('ber')
        $queue.Enqueue('BER')

        New-NeoIPCHospitalCode -Country DE -Acronym CHA 3>$null | Should -BeExactly 'DE_BER_CHA'

        Should -Invoke -ModuleName NeoIPC-Tools Read-Host -Times 2 -Exactly
    }

    It 'stops on an empty answer' -Skip:$noUser {
        $queue.Enqueue('')

        { New-NeoIPCHospitalCode -Country DE -Acronym CHA } | Should -Throw '*No Location given*'
    }

    It 'checks the given parts before it opens anything' {
        { New-NeoIPCHospitalCode -Country de } | Should -Throw

        Should -Invoke -ModuleName NeoIPC-Tools Start-Process -Times 0 -Exactly
    }

    It 'fails with -NonInteractive, naming the missing parts, and opens and asks nothing' {
        { New-NeoIPCHospitalCode -Country DE -NonInteractive } | Should -Throw '*Missing: Location, Acronym*'

        Should -Invoke -ModuleName NeoIPC-Tools Start-Process -Times 0 -Exactly
        Should -Invoke -ModuleName NeoIPC-Tools Read-Host -Times 0 -Exactly
    }
}

Describe 'Resolve-NeoIPCHospitalCode' {
    BeforeEach {
        $queue = [System.Collections.Generic.Queue[string]]::new()
        Mock -ModuleName NeoIPC-Tools Start-Process { }
        Mock -ModuleName NeoIPC-Tools Read-Host -MockWith ({ $queue.Dequeue() }.GetNewClosure())
    }

    It 'returns the code when only the code is given' {
        Resolve-NeoIPCHospitalCode -HospitalCode DE_BER_CHA | Should -BeExactly 'DE_BER_CHA'

        Should -Invoke -ModuleName NeoIPC-Tools Read-Host -Times 0 -Exactly
    }

    It 'builds the code from the parts when only parts are given' {
        Resolve-NeoIPCHospitalCode -Country DE -Location BER -Acronym CHA | Should -BeExactly 'DE_BER_CHA'
    }

    It 'accepts the code together with parts that agree with it, whole or in part' -ForEach @(
        @{ Parts = @{ Country = 'DE' } }
        @{ Parts = @{ Country = 'DE'; Location = 'BER'; Acronym = 'CHA' } }
        @{ Parts = @{ Acronym = 'CHA' } }
    ) {
        Resolve-NeoIPCHospitalCode -HospitalCode DE_BER_CHA @Parts -NonInteractive | Should -BeExactly 'DE_BER_CHA'
    }

    It 'throws on a contradiction under -NonInteractive, naming the parts' {
        { Resolve-NeoIPCHospitalCode -HospitalCode DE_BER_CHA -Country AT -Acronym XYZ -NonInteractive } | Should -Throw "*contradict*acronym 'XYZ' against 'CHA', country 'AT' against 'DE'*"

        Should -Invoke -ModuleName NeoIPC-Tools Read-Host -Times 0 -Exactly
    }

    It 'asks which to use on a contradiction, and returns the code for c, in either case' -Skip:$noUser {
        $queue.Enqueue('x')
        $queue.Enqueue('C')

        Resolve-NeoIPCHospitalCode -HospitalCode DE_BER_CHA -Country AT 3>$null | Should -BeExactly 'DE_BER_CHA'
        Should -Invoke -ModuleName NeoIPC-Tools Read-Host -Times 2 -Exactly
    }

    It 'returns the parts, completed from the code, for p' -Skip:$noUser {
        $queue.Enqueue('p')

        Resolve-NeoIPCHospitalCode -HospitalCode DE_BER_CHA -Country AT 3>$null | Should -BeExactly 'AT_BER_CHA'
    }

    It 'stops on a contradiction when its input ends, instead of asking forever' -Skip:$noUser {
        Mock -ModuleName NeoIPC-Tools Read-Host { $null }

        { Resolve-NeoIPCHospitalCode -HospitalCode DE_BER_CHA -Country AT 3>$null } | Should -Throw '*contradict*'
        Should -Invoke -ModuleName NeoIPC-Tools Read-Host -Times 1 -Exactly
    }

    It 'refuses a code of another shape, and parts of the wrong shape' {
        { Resolve-NeoIPCHospitalCode -HospitalCode DE-BER-CHA } | Should -Throw '*does not have the form*'
        { Resolve-NeoIPCHospitalCode -HospitalCode DE_BER_CHA -Country de -NonInteractive } | Should -Throw
    }
}

Describe 'Get-NeoIPCLocodeUrl and Test-NeoIPCInteractive' {
    It 'points at the given country''s directory only for a well-formed country code' -ForEach @(
        @{ Country = 'AT'; Expected = 'https://unlocode.unece.org/directory/locodes?country=AT' }
        @{ Country = 'at'; Expected = 'https://unece.org/trade/cefact/unlocode-code-list-country-and-territory' }
        @{ Country = ''; Expected = 'https://unece.org/trade/cefact/unlocode-code-list-country-and-territory' }
        @{ Country = 'A&B'; Expected = 'https://unece.org/trade/cefact/unlocode-code-list-country-and-territory' }
    ) {
        InModuleScope NeoIPC-Tools -Parameters @{ Country = $Country } {
            Get-NeoIPCLocodeUrl -Country $Country
        } | Should -BeExactly $Expected
    }

    It 'is never interactive under -NonInteractive' {
        InModuleScope NeoIPC-Tools { Test-NeoIPCInteractive -NonInteractive } | Should -BeFalse
    }

    It 'is interactive otherwise exactly when the session has a user' {
        InModuleScope NeoIPC-Tools { Test-NeoIPCInteractive } | Should -Be ([Environment]::UserInteractive)
    }

    It 'opens a page with the browser of the system' {
        Mock -ModuleName NeoIPC-Tools Start-Process { }

        InModuleScope NeoIPC-Tools { Open-NeoIPCUrl -Url 'https://example.org/' }

        Should -Invoke -ModuleName NeoIPC-Tools Start-Process -Times 1 -Exactly -ParameterFilter { $FilePath -ceq 'https://example.org/' }
    }
}
