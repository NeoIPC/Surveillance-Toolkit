#Requires -Version 7.6

<#
.SYNOPSIS
    Pester tests for New-NeoIPCHospitalCode, Resolve-NeoIPCHospitalCode, and the UN/LOCODE link and interactivity
    helpers behind them.

.DESCRIPTION
    Covers Public/Onboarding.ps1 and Private/Onboarding.ps1: the shapes the cmdlets accept, the code they build, and
    how Resolve-NeoIPCHospitalCode asks for a missing part or a choice. Only what lies outside the module is mocked,
    the prompt and the browser's start; the tests that are asked something run only where the session has a user, as
    the cmdlets themselves decide. A PowerShell started with -NonInteractive is stood in for by a prompt that refuses,
    as Read-Host does there.

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
    BeforeEach {
        Mock -ModuleName NeoIPC-Tools Start-Process { }
        Mock -ModuleName NeoIPC-Tools Read-Host { }
    }

    It 'joins the UN/LOCODE parts and the acronym with underscores' {
        New-NeoIPCHospitalCode -Country DE -Location BER -Acronym CHA | Should -BeExactly 'DE_BER_CHA'
    }

    It 'accepts the digits 2 to 9 in the location and digits in the acronym' {
        New-NeoIPCHospitalCode -Country GB -Location LH2 -Acronym UCL2 | Should -BeExactly 'GB_LH2_UCL2'
    }

    It 'refuses <Name>' -ForEach @(
        @{ Name = 'a lower-case country'; Country = 'de'; Location = 'BER'; Acronym = 'CHA'; Message = "*country 'de' is not two upper-case letters*" }
        @{ Name = 'a three-letter country'; Country = 'DEU'; Location = 'BER'; Acronym = 'CHA'; Message = "*country 'DEU'*" }
        @{ Name = 'a lower-case location'; Country = 'DE'; Location = 'ber'; Acronym = 'CHA'; Message = "*location 'ber' is not three upper-case characters*" }
        @{ Name = 'a location with the digit 1'; Country = 'DE'; Location = 'BE1'; Acronym = 'CHA'; Message = "*location 'BE1'*" }
        @{ Name = 'a two-character location'; Country = 'DE'; Location = 'BE'; Acronym = 'CHA'; Message = "*location 'BE'*" }
        @{ Name = 'an acronym with an underscore'; Country = 'DE'; Location = 'BER'; Acronym = 'C_HA'; Message = "*acronym 'C_HA'*" }
        @{ Name = 'a lower-case acronym'; Country = 'DE'; Location = 'BER'; Acronym = 'Cha'; Message = "*acronym 'Cha'*" }
        @{ Name = 'an acronym with letters outside A to Z'; Country = 'DE'; Location = 'BER'; Acronym = 'ÖGK'; Message = "*acronym 'ÖGK' is not the upper-case Latin letters A-Z and the digits 0-9*" }
        @{ Name = 'an acronym that ends in a line feed'; Country = 'DE'; Location = 'BER'; Acronym = "CHA`n"; Message = '*acronym*' }
        @{ Name = 'a location that ends in a line feed'; Country = 'DE'; Location = "BER`n"; Acronym = 'CHA'; Message = '*location*' }
        @{ Name = 'a country that ends in a line feed'; Country = "DE`n"; Location = 'BER'; Acronym = 'CHA'; Message = '*country*' }
    ) {
        { New-NeoIPCHospitalCode -Country $Country -Location $Location -Acronym $Acronym } | Should -Throw $Message
    }

    It 'refuses a missing part, naming each, and neither opens nor asks anything' {
        { New-NeoIPCHospitalCode -Country DE } | Should -Throw '*Missing: Location, Acronym*'

        Should -Invoke -ModuleName NeoIPC-Tools Start-Process -Times 0 -Exactly
        Should -Invoke -ModuleName NeoIPC-Tools Read-Host -Times 0 -Exactly
    }
}

Describe 'Resolve-NeoIPCHospitalCode asking for a missing part' {
    BeforeEach {
        # The answers a person would type, in order; the mock's closure holds the queue and takes the next one.
        $queue = [System.Collections.Generic.Queue[string]]::new()
        Mock -ModuleName NeoIPC-Tools Start-Process { }
        Mock -ModuleName NeoIPC-Tools Read-Host -MockWith ({ $queue.Dequeue() }.GetNewClosure())
    }

    It 'asks for nothing and opens nothing when every part is given' {
        Resolve-NeoIPCHospitalCode -Country DE -Location BER -Acronym CHA | Should -BeExactly 'DE_BER_CHA'

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

        Resolve-NeoIPCHospitalCode -Acronym CHA | Should -BeExactly 'DE_BER_CHA'

        InModuleScope NeoIPC-Tools { $script:events } | Should -Be @(
            'open https://unece.org/trade/cefact/unlocode-code-list-country-and-territory', 'ask',
            'open https://unlocode.unece.org/directory/locodes?country=DE', 'ask')
    }

    It 'opens the directory of the given country when only the location is missing' -Skip:$noUser {
        $queue.Enqueue('BER')

        Resolve-NeoIPCHospitalCode -Country DE -Acronym CHA | Should -BeExactly 'DE_BER_CHA'

        Should -Invoke -ModuleName NeoIPC-Tools Start-Process -Times 1 -Exactly -ParameterFilter { $FilePath -ceq 'https://unlocode.unece.org/directory/locodes?country=DE' }
        Should -Invoke -ModuleName NeoIPC-Tools Read-Host -Times 1 -Exactly
    }

    It 'opens the list of countries when only the location is given' -Skip:$noUser {
        $queue.Enqueue('DE')

        Resolve-NeoIPCHospitalCode -Location BER -Acronym CHA | Should -BeExactly 'DE_BER_CHA'

        Should -Invoke -ModuleName NeoIPC-Tools Start-Process -Times 1 -Exactly -ParameterFilter { $FilePath -ceq 'https://unece.org/trade/cefact/unlocode-code-list-country-and-territory' }
    }

    It 'asks for the acronym without opening a browser, since the directory does not hold it' -Skip:$noUser {
        $queue.Enqueue('CHA')

        Resolve-NeoIPCHospitalCode -Country DE -Location BER | Should -BeExactly 'DE_BER_CHA'

        Should -Invoke -ModuleName NeoIPC-Tools Start-Process -Times 0 -Exactly
    }

    It 'asks again after an answer of the wrong shape' -Skip:$noUser {
        $queue.Enqueue('ber')
        $queue.Enqueue('BER')

        Resolve-NeoIPCHospitalCode -Country DE -Acronym CHA 3>$null | Should -BeExactly 'DE_BER_CHA'

        Should -Invoke -ModuleName NeoIPC-Tools Read-Host -Times 2 -Exactly
    }

    It 'names only the parts still missing when the input ends after an answer' -Skip:$noUser {
        # A queue of objects, since a queue of strings takes $null for an empty answer.
        $replies = [System.Collections.Generic.Queue[object]]::new()
        $replies.Enqueue('BER')
        $replies.Enqueue($null)
        Mock -ModuleName NeoIPC-Tools Read-Host -MockWith ({ $replies.Dequeue() }.GetNewClosure())

        { Resolve-NeoIPCHospitalCode -Country DE -InformationAction SilentlyContinue } | Should -Throw 'Missing: Acronym.*' -ExceptionType ([System.ArgumentException])
    }

    It 'stops on an empty answer' -Skip:$noUser {
        $queue.Enqueue('')

        { Resolve-NeoIPCHospitalCode -Country DE -Acronym CHA } | Should -Throw '*No Location given*'
    }

    It 'checks the given parts before it opens anything' {
        { Resolve-NeoIPCHospitalCode -Country de } | Should -Throw "*country 'de' is not two upper-case letters*"

        Should -Invoke -ModuleName NeoIPC-Tools Start-Process -Times 0 -Exactly
    }

    It 'fails with -NonInteractive, naming the missing parts, and opens and asks nothing' {
        { Resolve-NeoIPCHospitalCode -Country DE -NonInteractive } | Should -Throw '*Missing: Location, Acronym*'

        Should -Invoke -ModuleName NeoIPC-Tools Start-Process -Times 0 -Exactly
        Should -Invoke -ModuleName NeoIPC-Tools Read-Host -Times 0 -Exactly
    }

    It 'fails as with -NonInteractive in <Name>, naming the missing parts' -Skip:$noUser -ForEach @(
        @{ Name = 'a PowerShell started with -NonInteractive, which refuses to ask'; Refusal = [System.Management.Automation.PSInvalidOperationException]::new('PowerShell is in NonInteractive mode. Read and Prompt functionality is not available.') }
        @{ Name = 'a host without a user interface, which refuses to ask'; Refusal = [System.Management.Automation.Host.HostException]::new('A command that prompts the user failed because the host program or the command type does not support user interaction.') }
        @{ Name = 'a session whose input has ended'; Refusal = $null }
    ) {
        Mock -ModuleName NeoIPC-Tools Read-Host -MockWith ({ if ($Refusal) { throw $Refusal } }.GetNewClosure())

        { Resolve-NeoIPCHospitalCode -Country DE -InformationAction SilentlyContinue } | Should -Throw '*Missing: Location, Acronym*' -ExceptionType ([System.ArgumentException])
    }

    # A redirected stream receives what SilentlyContinue only keeps off the screen, and nothing of what Ignore drops. So
    # the session here ignores information, which the message must not take on, while a caller's Ignore drops it.
    It 'says which page it opens unless the caller drops it: <Name>' -Skip:$noUser -ForEach @(
        @{ Name = 'by default, though the session ignores information'; Arguments = @{}; Count = 1 }
        @{ Name = 'with -InformationAction Ignore'; Arguments = @{ InformationAction = 'Ignore' }; Count = 0 }
    ) {
        $queue.Enqueue('BER')
        $session = $global:InformationPreference
        $global:InformationPreference = 'Ignore'

        try { $output = @(Resolve-NeoIPCHospitalCode -Country DE -Acronym CHA @Arguments 6>&1) }
        finally { $global:InformationPreference = $session }

        @($output | Where-Object { $_ -is [System.Management.Automation.InformationRecord] -and "$($_.MessageData)" -like 'Opening the UN/LOCODE directory: *' }).Count | Should -Be $Count
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

    It 'stops on a contradiction in <Name>, as with -NonInteractive' -Skip:$noUser -ForEach @(
        @{ Name = 'a PowerShell started with -NonInteractive, which refuses to ask'; Refusal = [System.Management.Automation.PSInvalidOperationException]::new('PowerShell is in NonInteractive mode. Read and Prompt functionality is not available.') }
        @{ Name = 'a host without a user interface, which refuses to ask'; Refusal = [System.Management.Automation.Host.HostException]::new('A command that prompts the user failed because the host program or the command type does not support user interaction.') }
    ) {
        Mock -ModuleName NeoIPC-Tools Read-Host -MockWith ({ throw $Refusal }.GetNewClosure())

        { Resolve-NeoIPCHospitalCode -HospitalCode DE_BER_CHA -Country AT 3>$null } | Should -Throw "*contradict*country 'AT' against 'DE'*" -ExceptionType ([System.ArgumentException])
    }

    It 'refuses a code of another shape, and parts of the wrong shape' {
        { Resolve-NeoIPCHospitalCode -HospitalCode DE-BER-CHA } | Should -Throw '*does not have the form*'
        { Resolve-NeoIPCHospitalCode -HospitalCode "DE_BER_CHA`n" } | Should -Throw '*does not have the form*'
        { Resolve-NeoIPCHospitalCode -HospitalCode DE_BER_CHA -Country de -NonInteractive } | Should -Throw "*country 'de' is not two upper-case letters*"
    }
}

Describe 'Get-NeoIPCLocodeUrl and Test-NeoIPCInteractive' {
    It 'points at the given country''s directory only for a well-formed country code' -ForEach @(
        @{ Country = 'AT'; Expected = 'https://unlocode.unece.org/directory/locodes?country=AT' }
        @{ Country = 'at'; Expected = 'https://unece.org/trade/cefact/unlocode-code-list-country-and-territory' }
        @{ Country = ''; Expected = 'https://unece.org/trade/cefact/unlocode-code-list-country-and-territory' }
        @{ Country = 'A&B'; Expected = 'https://unece.org/trade/cefact/unlocode-code-list-country-and-territory' }
        @{ Country = "AT`n"; Expected = 'https://unece.org/trade/cefact/unlocode-code-list-country-and-territory' }
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

Describe 'The hospital-code cmdlets as a console runs them' {
    BeforeAll {
        # Runs -Line in a runspace of its own with nothing around it, as a console runs a line: a try anywhere above a
        # call, Pester's own included, makes a throw under -ErrorAction SilentlyContinue unwind to it, which PowerShell
        # drops where no try is. A line still running after 20 seconds is stopped. Returns whether it ended, its output,
        # and its errors, written or thrown.
        $script:atConsole = {
            param([string]$Line)
            $manifest = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'NeoIPC-Tools.psd1'
            $ps = [powershell]::Create()
            try {
                [void]$ps.AddScript("Import-Module '$($manifest.Replace("'", "''"))' -Force`n$Line")
                $async = $ps.BeginInvoke()
                $ended = $async.AsyncWaitHandle.WaitOne([timespan]::FromSeconds(20))
                $output = @()
                $thrown = $null
                if ($ended) { try { $output = @($ps.EndInvoke($async)) } catch { $thrown = $_ } }
                else { $ps.Stop() }
                [pscustomobject]@{
                    Ended  = $ended
                    Output = $output
                    Errors = @(@($ps.Streams.Error | ForEach-Object { $_.Exception.Message }) + @(if ($thrown) { $thrown.Exception.InnerException.Message }))
                }
            }
            finally { $ps.Dispose() }
        }
    }

    It 'ends with its error at <Name>, although the caller passes -ErrorAction SilentlyContinue' -ForEach @(
        @{ Name = 'a part of another shape'; Line = 'New-NeoIPCHospitalCode -Country de -Location BER -Acronym CHA -ErrorAction SilentlyContinue'; Message = "*country 'de' is not two upper-case letters*" }
        @{ Name = 'a missing part'; Line = 'New-NeoIPCHospitalCode -Country DE -Location BER -ErrorAction SilentlyContinue'; Message = 'Missing: Acronym.*' }
        @{ Name = 'a contradiction nobody can settle'; Line = 'Resolve-NeoIPCHospitalCode -HospitalCode DE_BER_CHA -Acronym XYZ -NonInteractive -ErrorAction SilentlyContinue'; Message = "*'DE_BER_CHA' and its parts contradict each other*" }
    ) {
        $run = & $script:atConsole $Line

        $run.Ended | Should -BeTrue
        $run.Output.Count | Should -Be 0
        @($run.Errors | Where-Object { $_ -like $Message }).Count | Should -Be 1
    }
}
