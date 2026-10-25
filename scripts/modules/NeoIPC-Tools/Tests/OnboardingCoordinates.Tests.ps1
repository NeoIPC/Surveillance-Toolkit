#Requires -Version 7.6

<#
.SYNOPSIS
    Pester tests for Get-NeoIPCMapCoordinates.

.DESCRIPTION
    Covers Public/OnboardingCoordinates.ps1 and Private/OnboardingCoordinates.ps1: the coordinates given as
    parameters, the shapes accepted when pasted from the map, and how the map is opened and the answer asked for. Only
    what lies outside the module is mocked, the prompt and the browser's start; the tests that are asked something
    run only where the session has a user, as the cmdlet itself decides.

.EXAMPLE
    Invoke-Pester -Path scripts/modules/NeoIPC-Tools/Tests/OnboardingCoordinates.Tests.ps1
#>

$ErrorActionPreference = 'Stop'

BeforeDiscovery {
    # Whether a person could be asked here; a test that expects a question is skipped where nobody could be.
    $script:noUser = -not [Environment]::UserInteractive
}

BeforeAll {
    Import-Module -Name (Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'NeoIPC-Tools.psd1') -Force
}

Describe 'Get-NeoIPCMapCoordinates with parameters' {
    It 'returns the coordinates given' {
        $result = Get-NeoIPCMapCoordinates -Latitude 52.52 -Longitude 13.405

        $result.Latitude | Should -Be 52.52
        $result.Longitude | Should -Be 13.405
    }

    It 'accepts the edges of the valid ranges' {
        { Get-NeoIPCMapCoordinates -Latitude -90 -Longitude 180 } | Should -Not -Throw
    }

    It 'refuses <Name>' -ForEach @(
        @{ Name = 'a latitude without a longitude'; Arguments = @{ Latitude = 1.0 } }
        @{ Name = 'a longitude without a latitude'; Arguments = @{ Longitude = 1.0 } }
        @{ Name = 'a latitude above 90'; Arguments = @{ Latitude = 90.1; Longitude = 0.0 } }
        @{ Name = 'a longitude below -180'; Arguments = @{ Latitude = 0.0; Longitude = -180.1 } }
        @{ Name = 'a latitude that is not a number'; Arguments = @{ Latitude = [double]::NaN; Longitude = 0.0 } }
        @{ Name = 'a longitude that is not a number'; Arguments = @{ Latitude = 0.0; Longitude = [double]::NaN } }
    ) {
        { Get-NeoIPCMapCoordinates @Arguments } | Should -Throw
    }

    It 'returns the coordinates of the origin, which are zero and not missing' {
        $result = Get-NeoIPCMapCoordinates -Latitude 0 -Longitude 0

        $result | Should -Not -BeNullOrEmpty
        $result.Latitude | Should -Be 0
    }

    It 'reads coordinates given as text with a decimal point, in any culture' {
        $culture = [cultureinfo]::CurrentCulture
        try {
            [cultureinfo]::CurrentCulture = [cultureinfo]::new('de-DE')
            $result = Get-NeoIPCMapCoordinates -Latitude '52.52' -Longitude ' -13.405 '
        }
        finally {
            [cultureinfo]::CurrentCulture = $culture
        }

        $result.Latitude | Should -Be 52.52
        $result.Longitude | Should -Be -13.405
    }

    It 'takes blank text for coordinates not given, not for zero' {
        Get-NeoIPCMapCoordinates -Latitude '' -Longitude ' ' -NonInteractive | Should -BeNullOrEmpty
        { Get-NeoIPCMapCoordinates -Latitude '' -Longitude 13.405 -NonInteractive } | Should -Throw '*together, or neither*'
    }

    It 'refuses <Name>, naming the parameter' -ForEach @(
        @{ Name = 'text with a decimal comma, which PowerShell would read as a thousands separator'; Arguments = @{ Latitude = '6,5'; Longitude = '13,4' }; Message = "*-Latitude '6,5' is not a number of decimal degrees written with a point*" }
        @{ Name = 'text that is no number'; Arguments = @{ Latitude = '52.52'; Longitude = 'east' }; Message = "*-Longitude 'east' is not a number*" }
        @{ Name = 'a value that is neither number nor text'; Arguments = @{ Latitude = $true; Longitude = 13.405 }; Message = '*-Latitude is of type Boolean, not a number of decimal degrees such as 52.52.*' }
        @{ Name = 'a number written with an unquoted decimal comma, which PowerShell binds as a list'; Arguments = @{ Latitude = @(52, 52); Longitude = 13.405 }; Message = '*-Latitude is a list of 2 values, not one number of decimal degrees such as 52.52: written with a comma and unquoted*' }
    ) {
        { Get-NeoIPCMapCoordinates @Arguments -NonInteractive } | Should -Throw $Message
    }
}

Describe 'Get-NeoIPCMapCoordinates asking for the coordinates' {
    BeforeEach {
        $queue = [System.Collections.Generic.Queue[string]]::new()
        Mock -ModuleName NeoIPC-Tools Start-Process { }
        Mock -ModuleName NeoIPC-Tools Read-Host -MockWith ({ $queue.Dequeue() }.GetNewClosure())
    }

    It 'opens the map search for the query and returns what is pasted' -Skip:$noUser {
        $queue.Enqueue('52.5200, 13.4050')

        $result = Get-NeoIPCMapCoordinates -Query 'Example Hospital, Example Town' -InformationAction SilentlyContinue

        $result.Latitude | Should -Be 52.52
        $result.Longitude | Should -Be 13.405
        Should -Invoke -ModuleName NeoIPC-Tools Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -ceq 'https://www.google.com/maps/search/?api=1&query=Example%20Hospital%2C%20Example%20Town'
        }
    }

    It 'asks again for an answer of another shape, then takes the next' -Skip:$noUser {
        $queue.Enqueue('Example Town')
        $queue.Enqueue('(-1.2921; 36.8219)')

        $result = Get-NeoIPCMapCoordinates -Query 'Example Hospital' -InformationAction SilentlyContinue -WarningAction SilentlyContinue

        $result.Latitude | Should -Be -1.2921
        $result.Longitude | Should -Be 36.8219
        Should -Invoke -ModuleName NeoIPC-Tools Read-Host -Times 2 -Exactly
    }

    It 'returns nothing for an empty answer' -Skip:$noUser {
        $queue.Enqueue('')

        Get-NeoIPCMapCoordinates -Query 'Example Hospital' -InformationAction SilentlyContinue | Should -BeNullOrEmpty
    }

    It 'stops when the input ends, rather than skipping the coordinates' -Skip:$noUser {
        Mock -ModuleName NeoIPC-Tools Read-Host { $null }

        { Get-NeoIPCMapCoordinates -Query 'Example Hospital' -InformationAction SilentlyContinue } | Should -Throw '*input ended*'
    }

    It 'returns nothing, as with -NonInteractive, in <Name>' -Skip:$noUser -ForEach @(
        @{ Name = 'a PowerShell started with -NonInteractive, which refuses to ask'; Refusal = [System.Management.Automation.PSInvalidOperationException]::new('PowerShell is in NonInteractive mode. Read and Prompt functionality is not available.') }
        @{ Name = 'a host without a user interface, which refuses to ask'; Refusal = [System.Management.Automation.Host.HostException]::new('A command that prompts the user failed because the host program or the command type does not support user interaction.') }
    ) {
        Mock -ModuleName NeoIPC-Tools Read-Host -MockWith ({ throw $Refusal }.GetNewClosure())

        Get-NeoIPCMapCoordinates -Query 'Example Hospital' -InformationAction SilentlyContinue | Should -BeNullOrEmpty
    }

    It 'takes a pasted pair separated by <Name>' -Skip:$noUser -ForEach @(
        @{ Name = 'a space'; Text = '52.5200 13.4050'; Latitude = 52.52; Longitude = 13.405 }
        @{ Name = 'a tab'; Text = "-1.2921`t36.8219"; Latitude = -1.2921; Longitude = 36.8219 }
    ) {
        $queue.Enqueue($Text)

        $result = Get-NeoIPCMapCoordinates -Query 'Example Hospital' -InformationAction SilentlyContinue

        $result.Latitude | Should -Be $Latitude
        $result.Longitude | Should -Be $Longitude
    }

    It 'opens and asks for nothing under -NonInteractive' {
        Get-NeoIPCMapCoordinates -Query 'Example Hospital' -NonInteractive | Should -BeNullOrEmpty

        Should -Invoke -ModuleName NeoIPC-Tools Start-Process -Times 0 -Exactly
        Should -Invoke -ModuleName NeoIPC-Tools Read-Host -Times 0 -Exactly
    }

    It 'opens and asks for nothing when the coordinates are given' {
        [void](Get-NeoIPCMapCoordinates -Latitude 1 -Longitude 2 -Query 'Example Hospital')

        Should -Invoke -ModuleName NeoIPC-Tools Start-Process -Times 0 -Exactly
    }

    It 'needs a query to search the map' -Skip:$noUser {
        { Get-NeoIPCMapCoordinates } | Should -Throw '*query*'
    }

    It 'rejects <Text> as coordinates' -Skip:$noUser -ForEach @(
        @{ Text = '91.0, 0.0' }
        @{ Text = '0.0, 181.0' }
        @{ Text = '52,5200, 13,4050' }
        @{ Text = '52.5200' }
        @{ Text = '48,137' }
        @{ Text = '48, 11' }
    ) {
        $queue.Enqueue($Text)
        $queue.Enqueue('')

        Get-NeoIPCMapCoordinates -Query 'Example Hospital' -InformationAction SilentlyContinue -WarningAction SilentlyContinue | Should -BeNullOrEmpty
        Should -Invoke -ModuleName NeoIPC-Tools Read-Host -Times 2 -Exactly
    }
}

Describe 'Get-NeoIPCMapCoordinates as a console runs it' {
    It 'ends with its error at <Name>, although the caller passes -ErrorAction SilentlyContinue' -ForEach @(
        @{ Name = 'a latitude out of range'; Arguments = '-Latitude 95 -Longitude 10'; Message = '*latitude lies between -90 and 90*' }
        @{ Name = 'a decimal comma'; Arguments = "-Latitude '6,5' -Longitude '3,4'"; Message = "*-Latitude '6,5' is not a number of decimal degrees*" }
    ) {
        # As a console runs a line, in a runspace of its own with nothing around it: a try anywhere above a call,
        # Pester's own included, makes a throw under -ErrorAction SilentlyContinue unwind to it, which PowerShell drops
        # where no try is.
        $manifest = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'NeoIPC-Tools.psd1'
        $ps = [powershell]::Create()
        try {
            [void]$ps.AddScript("Import-Module '$($manifest.Replace("'", "''"))' -Force`nGet-NeoIPCMapCoordinates $Arguments -NonInteractive -ErrorAction SilentlyContinue")
            $thrown = $null
            $output = try { @($ps.Invoke()) } catch { $thrown = $_; @() }
            $errors = @(@($ps.Streams.Error | ForEach-Object { $_.Exception.Message }) + @(if ($thrown) { $thrown.Exception.InnerException.Message }))
        }
        finally { $ps.Dispose() }

        $output.Count | Should -Be 0
        @($errors | Where-Object { $_ -like $Message }).Count | Should -Be 1
    }
}
