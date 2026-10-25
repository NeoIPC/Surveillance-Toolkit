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
        @{ Text = '91, 0' }
        @{ Text = '0, 181' }
        @{ Text = '52,5200, 13,4050' }
        @{ Text = '52.5200' }
    ) {
        $queue.Enqueue($Text)
        $queue.Enqueue('')

        Get-NeoIPCMapCoordinates -Query 'Example Hospital' -InformationAction SilentlyContinue -WarningAction SilentlyContinue | Should -BeNullOrEmpty
        Should -Invoke -ModuleName NeoIPC-Tools Read-Host -Times 2 -Exactly
    }
}
