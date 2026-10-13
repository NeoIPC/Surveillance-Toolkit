#Requires -Version 7.6

<#
.SYNOPSIS
    Pester tests for the DHIS2 host a call goes to, the GET helper's query and errors, list chunking, and the version
    reader.

.DESCRIPTION
    Covers Resolve-NeoIPCDhis2Hostname, Split-NeoIPCList, Get-NeoIPCDhis2ErrorDetail, New-NeoIPCDhis2HttpError and
    Invoke-NeoIPCDhis2Get (Private/DHIS2Http.ps1), Get-NeoIPCDhis2VersionText (Private/Dhis2Version.ps1), and
    Resolve-NeoIPCReportHostname (Public/ReportHelpers.ps1). Self-contained: every HTTP call is mocked, so no instance is
    needed and no request leaves the process. NEOIPC_DHIS2_HOST is removed before each test, set where a test needs it,
    and restored afterwards, removed again if it was absent. The tokens are made-up strings of the two token shapes.

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
            $script:V1Auth = @{ AuthType = 'Token'; Token = 'd2pat_' + ('a' * 32) + ('0' * 10) }
            $script:V2Auth = @{ AuthType = 'Token'; Token = 'd2p_' + ('b' * 44) + '000000' }
            # The answer of a DHIS2 instance to a request, as Invoke-WebRequest returns it with -SkipHttpErrorCheck.
            function New-TestResponse([int]$StatusCode, [string]$Content) { [pscustomobject]@{ StatusCode = $StatusCode; Content = $Content } }
            # The error record a call threw, whatever frame wrapped it.
            function Get-TestError([scriptblock]$Call) {
                try { & $Call; return $null } catch { return $_ }
            }
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

        Describe 'Split-NeoIPCList' {
            It 'returns no chunk for no value' {
                # The chunks come back as one list of lists, which @() would wrap again.
                (Split-NeoIPCList -Value @() -Separator ',').Count | Should -Be 0
            }
            It 'keeps the values in order and cuts at the count' {
                $chunks = Split-NeoIPCList -Value @('a', 'b', 'c', 'd', 'e') -Separator ',' -MaximumCount 2
                $chunks.Count | Should -Be 3
                $chunks[0] | Should -Be @('a', 'b')
                $chunks[1] | Should -Be @('c', 'd')
                $chunks[2] | Should -Be @('e')
            }
            It 'returns one chunk as a list of one list' {
                $chunks = Split-NeoIPCList -Value @('a', 'b') -Separator ','
                $chunks.Count | Should -Be 1
                $chunks[0] | Should -Be @('a', 'b')
            }
            It 'measures the joined text URL-encoded, separators included' {
                # Each value encodes to 3 characters and the separator to 3 ('%3B'): 'abc' alone is 3, two make 9, three 15.
                $chunks = Split-NeoIPCList -Value @('abc', 'def', 'ghi') -Separator ';' -MaximumLength 9
                $chunks.Count | Should -Be 2
                $chunks[0] | Should -Be @('abc', 'def')
                $chunks[1] | Should -Be @('ghi')
                # 'a b' encodes to 'a+b' and 'ä' to '%C3%A4' (6), so the second value does not fit beside the first.
                (Split-NeoIPCList -Value @('a b', 'ä') -Separator ',' -MaximumLength 9).Count | Should -Be 2
            }
            It 'refuses a value that alone exceeds the length' {
                { Split-NeoIPCList -Value @('abcdef') -Separator ',' -MaximumLength 5 } | Should -Throw '*does not fit*'
            }
        }

        Describe 'Get-NeoIPCDhis2ErrorDetail' {
            It 'reads the message and the error code of a DHIS2 WebMessage' {
                $detail = Get-NeoIPCDhis2ErrorDetail -Content '{"httpStatus":"Conflict","httpStatusCode":409,"status":"ERROR","message":"Object not found","errorCode":"E1005"}'
                $detail.Message | Should -BeExactly 'Object not found'
                $detail.ErrorCode | Should -BeExactly 'E1005'
            }
            It 'shows the text of an HTML error page without its markup, styles, or scripts' {
                $page = '<!doctype html><html lang="en"><head><title>HTTP Status 400 &ndash; Bad Request</title><style type="text/css">body {font-family:Tahoma}</style></head>' +
                '<body><h1>HTTP Status 400 – Bad Request</h1><script>var x = 1;</script><p><b>Message</b> Required parameter &#39;program&#39; is missing</p></body></html>'
                $detail = Get-NeoIPCDhis2ErrorDetail -Content $page
                $detail.Message | Should -BeLike "*Required parameter 'program' is missing*"
                $detail.Message | Should -Not -BeLike '*<*'
                $detail.Message | Should -Not -BeLike '*Tahoma*'
                $detail.Message | Should -Not -BeLike '*var x*'
                $detail.ErrorCode | Should -BeNullOrEmpty
            }
            It 'shortens a long page' {
                (Get-NeoIPCDhis2ErrorDetail -Content ('x' * 1000)).Message.Length | Should -Be 303
            }
            It 'says nothing for an empty body' {
                (Get-NeoIPCDhis2ErrorDetail -Content '').Message | Should -BeExactly ''
            }
        }

        Describe 'Invoke-NeoIPCDhis2Get' {
            It 'sends no request when neither -Hostname nor NEOIPC_DHIS2_HOST names a host' {
                Mock Invoke-WebRequest { New-TestResponse 200 '{}' }
                { Invoke-NeoIPCDhis2Get -Auth $script:TestAuth -Path 'api/me' -Confirm:$false -WhatIf:$false } | Should -Throw '*NEOIPC_DHIS2_HOST*'
                Should -Invoke Invoke-WebRequest -Times 0 -Exactly
            }
            It 'reads from the host NEOIPC_DHIS2_HOST names when no host is given' {
                Mock Invoke-WebRequest { New-TestResponse 200 (@{ Uri = [string]$Uri } | ConvertTo-Json -Depth 100) }
                [Environment]::SetEnvironmentVariable('NEOIPC_DHIS2_HOST', 'from-variable.example.org', 'Process')
                $answer = Invoke-NeoIPCDhis2Get -Auth $script:TestAuth -Path 'api/me' -Confirm:$false -WhatIf:$false
                $answer.Uri | Should -BeLike 'https://from-variable.example.org/api/me?*'
            }
            It 'refuses a list as a query value instead of sending it joined with spaces' {
                Mock Invoke-WebRequest { New-TestResponse 200 '{}' }
                { Invoke-NeoIPCDhis2Get -Auth $script:TestAuth -Hostname 'given.example.org' -Path 'api/tracker/events' `
                        -QueryParameters @{ events = @('EvtAAAAAA01', 'EvtBBBBBB02') } -Confirm:$false -WhatIf:$false } |
                    Should -Throw "*'events' holds a list*"
                Should -Invoke Invoke-WebRequest -Times 0 -Exactly
            }
            It 'sends a list joined by the caller as one value' {
                Mock Invoke-WebRequest { New-TestResponse 200 (@{ Uri = [string]$Uri } | ConvertTo-Json -Depth 100) }
                $answer = Invoke-NeoIPCDhis2Get -Auth $script:TestAuth -Hostname 'given.example.org' -Path 'api/tracker/events' `
                    -QueryParameters @{ events = 'EvtAAAAAA01,EvtBBBBBB02' } -Confirm:$false -WhatIf:$false
                $answer.Uri | Should -BeLike '*events=EvtAAAAAA01%2CEvtBBBBBB02*'
            }
            It 'returns dates as [datetime], and as DHIS2''s text with -AsHashtable' {
                Mock Invoke-WebRequest { New-TestResponse 200 '{"created":"2026-01-02T03:04:05.678"}' }
                $plain = Invoke-NeoIPCDhis2Get -Auth $script:TestAuth -Hostname 'given.example.org' -Path 'api/me' -Confirm:$false -WhatIf:$false
                $plain.created | Should -BeOfType ([datetime])
                $raw = Invoke-NeoIPCDhis2Get -Auth $script:TestAuth -Hostname 'given.example.org' -Path 'api/me' -AsHashtable -Confirm:$false -WhatIf:$false
                $raw['created'] | Should -BeExactly '2026-01-02T03:04:05.678'
            }
            It 'ends with an error carrying the status, DHIS2''s message, and its error code' {
                Mock Invoke-WebRequest { New-TestResponse 409 '{"httpStatus":"Conflict","httpStatusCode":409,"status":"ERROR","message":"Program is specified but does not exist","errorCode":"E1081"}' }
                $failure = Get-TestError { Invoke-NeoIPCDhis2Get -Auth $script:TestAuth -Hostname 'given.example.org' -Path 'api/tracker/events' -Confirm:$false -WhatIf:$false }
                $failure | Should -Not -BeNullOrEmpty
                $failure.Exception | Should -BeOfType ([System.Net.Http.HttpRequestException])
                $failure.Exception.StatusCode | Should -Be ([System.Net.HttpStatusCode]::Conflict)
                $failure.Exception.Data['Dhis2ErrorCode'] | Should -BeExactly 'E1081'
                $failure.Exception.Message | Should -BeExactly "GET 'api/tracker/events' failed with HTTP 409 (E1081): Program is specified but does not exist"
                $failure.FullyQualifiedErrorId | Should -BeLike 'NeoIPCDhis2GetFailed*'
            }
            It 'tells a 401 as an authentication error and a 403 as a refusal' {
                Mock Invoke-WebRequest { New-TestResponse 401 '{"httpStatusCode":401,"status":"ERROR","message":"Unauthorized"}' }
                (Get-TestError { Invoke-NeoIPCDhis2Get -Auth $script:TestAuth -Hostname 'given.example.org' -Path 'api/me' -Confirm:$false -WhatIf:$false }).CategoryInfo.Category |
                    Should -Be ([System.Management.Automation.ErrorCategory]::AuthenticationError)
                Mock Invoke-WebRequest { New-TestResponse 403 '{"httpStatusCode":403,"status":"ERROR","message":"Forbidden"}' }
                (Get-TestError { Invoke-NeoIPCDhis2Get -Auth $script:TestAuth -Hostname 'given.example.org' -Path 'api/users' -Confirm:$false -WhatIf:$false }).CategoryInfo.Category |
                    Should -Be ([System.Management.Automation.ErrorCategory]::PermissionDenied)
            }
            It 'shows the text of a refusal that comes as an HTML page' {
                Mock Invoke-WebRequest { New-TestResponse 400 '<html><head><title>HTTP Status 400 – Bad Request</title></head><body><p><b>Message</b> Program is mandatory</p></body></html>' }
                $failure = Get-TestError { Invoke-NeoIPCDhis2Get -Auth $script:TestAuth -Hostname 'given.example.org' -Path 'api/tracker/events' -Confirm:$false -WhatIf:$false }
                $failure.Exception.StatusCode | Should -Be ([System.Net.HttpStatusCode]::BadRequest)
                $failure.Exception.Message | Should -BeLike "GET 'api/tracker/events' failed with HTTP 400: *Program is mandatory*"
                $failure.Exception.Message | Should -Not -BeLike '*<*'
            }
            It 'says a version-1 token must be issued again when DHIS2 refuses its checksum, without showing the token' {
                Mock Invoke-WebRequest { New-TestResponse 400 '{"httpStatus":"Bad Request","httpStatusCode":400,"status":"ERROR","message":"Checksum validation failed"}' }
                $failure = Get-TestError { Invoke-NeoIPCDhis2Get -Auth $script:V1Auth -Hostname 'given.example.org' -Path 'api/me' -Confirm:$false -WhatIf:$false }
                $failure.Exception.Message | Should -BeLike '*Checksum validation failed*version-1 token*create a new token*'
                $failure.Exception.Message | Should -Not -BeLike "*$($script:V1Auth.Token)*"
            }
            It 'says a version-2 token whose checksum DHIS2 refuses was copied wrongly' {
                Mock Invoke-WebRequest { New-TestResponse 400 '{"httpStatus":"Bad Request","httpStatusCode":400,"status":"ERROR","message":"Checksum validation failed"}' }
                $failure = Get-TestError { Invoke-NeoIPCDhis2Get -Auth $script:V2Auth -Hostname 'given.example.org' -Path 'api/me' -Confirm:$false -WhatIf:$false }
                $failure.Exception.Message | Should -BeLike '*whole token was copied*'
                $failure.Exception.Message | Should -Not -BeLike '*version-1*'
                $failure.Exception.Message | Should -Not -BeLike "*$($script:V2Auth.Token)*"
            }
            It 'ends with an error when a successful answer is not JSON, rather than reading it as empty' {
                Mock Invoke-WebRequest { New-TestResponse 200 '<html><body>Please log in</body></html>' }
                { Invoke-NeoIPCDhis2Get -Auth $script:TestAuth -Hostname 'given.example.org' -Path 'api/organisationUnits' -Confirm:$false -WhatIf:$false } |
                    Should -Throw '*not JSON*Please log in*'
            }
            It 'ends with the transport''s message when the request never reaches DHIS2' {
                Mock Invoke-WebRequest { throw [System.Net.Http.HttpRequestException]::new('No such host is known.') }
                { Invoke-NeoIPCDhis2Get -Auth $script:TestAuth -Hostname 'given.example.org' -Path 'api/me' -Confirm:$false -WhatIf:$false } |
                    Should -Throw "Failed to fetch 'api/me' from DHIS2*No such host is known.*"
            }
        }

        Describe 'Invoke-NeoIPCDhis2Delete' {
            It 'returns DHIS2''s answer to a delete it accepted' {
                Mock Invoke-WebRequest { New-TestResponse 200 '{"httpStatus":"OK","httpStatusCode":200,"status":"OK"}' }
                (Invoke-NeoIPCDhis2Delete -Auth $script:TestAuth -Hostname 'given.example.org' -Path 'api/apiToken/TokAAAAAA01' -Confirm:$false).status |
                    Should -BeExactly 'OK'
            }
            It 'ends with the status the body reports when DHIS2 answers HTTP 200 with an error' {
                Mock Invoke-WebRequest { New-TestResponse 200 '{"httpStatus":"Conflict","httpStatusCode":409,"status":"ERROR","message":"Object could not be deleted","errorCode":"E4030"}' }
                $failure = Get-TestError { Invoke-NeoIPCDhis2Delete -Auth $script:TestAuth -Hostname 'given.example.org' -Path 'api/optionGroups/GrpAAAAAA01' -Confirm:$false }
                $failure.Exception.StatusCode | Should -Be ([System.Net.HttpStatusCode]::Conflict)
                $failure.Exception.Data['Dhis2ErrorCode'] | Should -BeExactly 'E4030'
                $failure.FullyQualifiedErrorId | Should -BeLike 'NeoIPCDhis2DeleteFailed*'
            }
            It 'shows the text of a refusal that comes as an HTML page' {
                Mock Invoke-WebRequest { New-TestResponse 500 '<html><body><h1>Internal Server Error</h1></body></html>' }
                $failure = Get-TestError { Invoke-NeoIPCDhis2Delete -Auth $script:TestAuth -Hostname 'given.example.org' -Path 'api/apiToken/TokAAAAAA01' -Confirm:$false }
                $failure.Exception.StatusCode | Should -Be ([System.Net.HttpStatusCode]::InternalServerError)
                $failure.Exception.Message | Should -BeExactly "DELETE 'api/apiToken/TokAAAAAA01' failed with HTTP 500: Internal Server Error"
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
