#Requires -Version 7.6

<#
.SYNOPSIS
    Pester tests for the personal access token cmdlets.

.DESCRIPTION
    Covers Public/PAT.ps1. Self-contained: authentication and the DHIS2 calls are mocked, so no live instance is
    needed and no API call is made.

.EXAMPLE
    Invoke-Pester -Path scripts/modules/NeoIPC-Tools/Tests/PAT.Tests.ps1
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..') -Force

InModuleScope 'NeoIPC-Tools' {

    Describe 'Remove-DHIS2PersonalAccessToken' {
        BeforeEach {
            Mock Resolve-NeoIPCAuth { @{ AuthType = 'Token'; Token = 'not-a-real-token' } }
            # The second token's delete fails the way Invoke-NeoIPCDhis2Delete reports a refused DELETE.
            Mock Invoke-NeoIPCDhis2Delete {
                if ($Path -eq 'api/apiToken/tokenBBBBBB2') {
                    $exception = [System.Net.Http.HttpRequestException]::new("DELETE '$Path' failed with HTTP 403: forbidden", $null, [System.Net.HttpStatusCode]::Forbidden)
                    throw [System.Management.Automation.ErrorRecord]::new($exception, 'NeoIPCDhis2DeleteFailed', [System.Management.Automation.ErrorCategory]::PermissionDenied, $Path)
                }
                [pscustomobject]@{ httpStatusCode = 200; status = 'OK'; Path = $Path }
            }
        }

        It 'reports a failed delete as that token''s error and still removes the tokens after it' {
            $removed = Remove-DHIS2PersonalAccessToken -Id 'tokenAAAAAA1', 'tokenBBBBBB2', 'tokenCCCCCC3' -Force -Confirm:$false -ErrorAction SilentlyContinue -ErrorVariable failures
            Should -Invoke Invoke-NeoIPCDhis2Delete -Times 3 -Exactly
            @($removed | ForEach-Object { $_.Path }) | Should -Be @('api/apiToken/tokenAAAAAA1', 'api/apiToken/tokenCCCCCC3')
            # The error variable records the one error once per frame it passes through (the mock adds frames), so
            # the check is on what failed, not on how often it was recorded.
            $records = @($failures | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
            @($records | ForEach-Object { [string]$_.TargetObject } | Sort-Object -Unique) | Should -Be @('api/apiToken/tokenBBBBBB2')
            $records[0].Exception.StatusCode | Should -Be ([System.Net.HttpStatusCode]::Forbidden)
            $records[0].FullyQualifiedErrorId | Should -BeLike 'NeoIPCDhis2DeleteFailed*'
        }
    }
}
