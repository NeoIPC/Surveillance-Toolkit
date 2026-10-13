#Requires -Version 7.6

<#
.SYNOPSIS
    Pester tests for the DHIS2 host a call goes to, the GET helper's query, and the version reader.

.DESCRIPTION
    Covers Resolve-NeoIPCDhis2Hostname and Invoke-NeoIPCDhis2Get (Private/DHIS2Http.ps1), Get-NeoIPCDhis2VersionText
    (Private/Dhis2Version.ps1), and Resolve-NeoIPCReportHostname (Public/ReportHelpers.ps1). Self-contained: every HTTP
    call is mocked, so no instance is needed and no request leaves the process. NEOIPC_DHIS2_HOST is removed before
    each test, set where a test needs it, and restored afterwards, removed again if it was absent.

.EXAMPLE
    Invoke-Pester -Path scripts/modules/NeoIPC-Tools/Tests/DHIS2Http.Tests.ps1
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..') -Force

InModuleScope 'NeoIPC-Tools' {
    Describe 'The DHIS2 host and query' {
        BeforeAll {
            $script:SavedHostVariable = [Environment]::GetEnvironmentVariable('NEOIPC_DHIS2_HOST', 'Process')
            $script:TestAuth = @{ AuthType = 'Token'; Token = 'not-a-real-token' }
        }
        AfterAll {
            # [NullString]::Value removes the variable; $null would bind as '' and leave it present but empty.
            $restore = if ($null -eq $script:SavedHostVariable) { [NullString]::Value } else { $script:SavedHostVariable }
            [Environment]::SetEnvironmentVariable('NEOIPC_DHIS2_HOST', $restore, 'Process')
        }
        BeforeEach {
            [Environment]::SetEnvironmentVariable('NEOIPC_DHIS2_HOST', [NullString]::Value, 'Process')
        }

        Describe 'Resolve-NeoIPCDhis2Hostname' {
            It 'takes the given host over NEOIPC_DHIS2_HOST' {
                [Environment]::SetEnvironmentVariable('NEOIPC_DHIS2_HOST', 'from-variable.example.org', 'Process')
                Resolve-NeoIPCDhis2Hostname -Hostname 'given.example.org' | Should -BeExactly 'given.example.org'
            }
            It 'takes NEOIPC_DHIS2_HOST when no host is given' {
                [Environment]::SetEnvironmentVariable('NEOIPC_DHIS2_HOST', 'from-variable.example.org', 'Process')
                Resolve-NeoIPCDhis2Hostname -Hostname '' | Should -BeExactly 'from-variable.example.org'
            }
            It 'stops when neither names a host, instead of choosing one' {
                { Resolve-NeoIPCDhis2Hostname -Hostname '' } | Should -Throw '*NEOIPC_DHIS2_HOST*'
            }
        }

        Describe 'Invoke-NeoIPCDhis2Get' {
            BeforeEach {
                Mock Invoke-RestMethod { [pscustomobject]@{ Uri = [string]$Uri } }
            }

            It 'sends no request when neither -Hostname nor NEOIPC_DHIS2_HOST names a host' {
                { Invoke-NeoIPCDhis2Get -Auth $script:TestAuth -Path 'api/me' -Confirm:$false -WhatIf:$false } | Should -Throw '*NEOIPC_DHIS2_HOST*'
                Should -Invoke Invoke-RestMethod -Times 0 -Exactly
            }
            It 'reads from the host NEOIPC_DHIS2_HOST names when no host is given' {
                [Environment]::SetEnvironmentVariable('NEOIPC_DHIS2_HOST', 'from-variable.example.org', 'Process')
                $answer = Invoke-NeoIPCDhis2Get -Auth $script:TestAuth -Path 'api/me' -Confirm:$false -WhatIf:$false
                $answer.Uri | Should -BeLike 'https://from-variable.example.org/api/me?*'
            }
            It 'refuses a list as a query value instead of sending it joined with spaces' {
                { Invoke-NeoIPCDhis2Get -Auth $script:TestAuth -Hostname 'given.example.org' -Path 'api/tracker/events' `
                        -QueryParameters @{ events = @('EvtAAAAAA01', 'EvtBBBBBB02') } -Confirm:$false -WhatIf:$false } |
                    Should -Throw "*'events' holds a list*"
                Should -Invoke Invoke-RestMethod -Times 0 -Exactly
            }
            It 'sends a list joined by the caller as one value' {
                $answer = Invoke-NeoIPCDhis2Get -Auth $script:TestAuth -Hostname 'given.example.org' -Path 'api/tracker/events' `
                    -QueryParameters @{ events = 'EvtAAAAAA01,EvtBBBBBB02' } -Confirm:$false -WhatIf:$false
                $answer.Uri | Should -BeLike '*events=EvtAAAAAA01%2CEvtBBBBBB02*'
            }
        }

        Describe 'Get-NeoIPCDhis2VersionText' {
            It 'returns the version text the instance reports' {
                Mock Invoke-NeoIPCDhis2Get { [ordered]@{ version = '2.43.2' } } -ParameterFilter { $Path -eq 'api/system/info' }
                Get-NeoIPCDhis2VersionText -Endpoint @{ Auth = $script:TestAuth; Hostname = 'given.example.org' } | Should -BeExactly '2.43.2'
            }
            It 'throws when the answer carries no version, so no dialect is chosen from nothing' {
                Mock Invoke-NeoIPCDhis2Get { [ordered]@{ revision = 'abc' } } -ParameterFilter { $Path -eq 'api/system/info' }
                { Get-NeoIPCDhis2VersionText -Endpoint @{ Auth = $script:TestAuth; Hostname = 'given.example.org' } } | Should -Throw '*without a version*'
            }
        }

        Describe 'Resolve-NeoIPCReportHostname' {
            It 'takes the given host first' {
                [Environment]::SetEnvironmentVariable('NEOIPC_DHIS2_HOST', 'from-variable.example.org', 'Process')
                Resolve-NeoIPCReportHostname -Hostname 'given.example.org' | Should -BeExactly 'given.example.org'
            }
            It 'takes NEOIPC_DHIS2_HOST next, as the reports'' R scripts do' {
                [Environment]::SetEnvironmentVariable('NEOIPC_DHIS2_HOST', 'from-variable.example.org', 'Process')
                Resolve-NeoIPCReportHostname | Should -BeExactly 'from-variable.example.org'
            }
            It 'falls back to the production host the reports'' R scripts default to' {
                # No R parser is at hand in PowerShell, so the R default is matched by the exact form of its one assignment.
                $helpers = Get-Content -Raw -LiteralPath (Join-Path $script:NeoIPCRepoRoot 'reports/common/helpers.R')
                $helpers -match 'NEOIPC_PRODUCTION_DHIS2_HOST <- "([^"]+)"' | Should -BeTrue
                Resolve-NeoIPCReportHostname | Should -BeExactly $Matches[1]
            }
        }
    }
}
