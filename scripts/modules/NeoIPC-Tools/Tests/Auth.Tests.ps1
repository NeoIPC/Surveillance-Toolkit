#Requires -Version 7.6

<#
.SYNOPSIS
    Pester tests for the DHIS2 personal-access-token format, the token reader, and the credential resolver.

.DESCRIPTION
    Covers Test-DHIS2PersonalAccessToken, Resolve-NeoIPCAuth, and Get-NeoIPCAuthPassword (Public/Auth.ps1); and
    Read-NeoIPCToken and Format-NeoIPCMessageValue (Private/Auth.ps1). A version-1 token is `d2pat_`, 32 letters or
    digits, and a 10-digit checksum (48 characters); a version-2 token is `d2p_`, 44 letters or digits, and a 6-character
    Base62 checksum (54 characters). The tokens here are made-up strings of those shapes, built part by part so that their
    lengths are plain; no checksum is real, since none is checked here.

    NEOIPC_DHIS2_TOKEN is removed before each test, set to a made-up value where a test needs one, and restored after the
    file, removed again if it was absent. Token files are written to Pester's TestDrive. Self-contained: no request is
    made.

.EXAMPLE
    Invoke-Pester -Path scripts/modules/NeoIPC-Tools/Tests/Auth.Tests.ps1
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..') -Force

InModuleScope 'NeoIPC-Tools' {
    Describe 'DHIS2 personal access tokens and credentials' {
        BeforeAll {
            $script:SavedTokenVariable = [Environment]::GetEnvironmentVariable('NEOIPC_DHIS2_TOKEN', 'Process')
            $script:V1LetterFirst = 'd2pat_' + ('a' * 32) + ('0' * 10)
            $script:V1DigitFirst = 'd2pat_' + '5' + ('a' * 31) + ('0' * 10)
            $script:V2LetterFirst = 'd2p_' + 'Q' + ('a' * 43) + '0aZ9zZ'
            $script:V2DigitFirst = 'd2p_' + '7' + ('b' * 43) + '000000'
            $script:ArabicIndicFive = [string][char]0x0665
            $script:KelvinSign = [string][char]0x212A

            # The error record a call ended with, or $null.
            function Get-ThrownRecord([scriptblock]$Call) {
                try { & $Call; $null } catch { $_ }
            }
            # A token file as a person would save it: LF or CRLF line ends, without a byte order mark.
            function New-TokenFile([string]$Name, [string]$Content) {
                $path = Join-Path $TestDrive $Name
                [System.IO.File]::WriteAllText($path, $Content, [System.Text.UTF8Encoding]::new($false))
                $path
            }
        }
        AfterAll {
            # [NullString]::Value removes the variable; $null would bind as '' and leave it present but empty.
            $restore = if ($null -eq $script:SavedTokenVariable) { [NullString]::Value } else { $script:SavedTokenVariable }
            [Environment]::SetEnvironmentVariable('NEOIPC_DHIS2_TOKEN', $restore, 'Process')
        }
        BeforeEach {
            [Environment]::SetEnvironmentVariable('NEOIPC_DHIS2_TOKEN', [NullString]::Value, 'Process')
            Mock Invoke-WebRequest { throw 'A test made an HTTP call.' }
            Mock Invoke-RestMethod { throw 'A test made an HTTP call.' }
        }

        Describe 'Test-DHIS2PersonalAccessToken' {
            It 'accepts a <Case>' -ForEach @(
                # NEOIPC-COMPAT(dhis2-version-1-token): see Public/Auth.ps1.
                @{ Case = 'version-1 token whose body starts with a letter'; Value = 'd2pat_' + ('a' * 32) + ('0' * 10) }
                # DHIS2 2.40 builds the body from Base64, so its first character may be a digit (d2pat_5xVA...).
                @{ Case = 'version-1 token whose body starts with a digit'; Value = 'd2pat_' + '5' + ('a' * 31) + ('0' * 10) }
                @{ Case = 'version-2 token whose body starts with a letter'; Value = 'd2p_' + 'Q' + ('a' * 43) + '0aZ9zZ' }
                @{ Case = 'version-2 token whose body starts with a digit'; Value = 'd2p_' + '7' + ('b' * 43) + '000000' }
            ) {
                Test-DHIS2PersonalAccessToken $Value | Should -BeTrue
            }

            It 'rejects <Case>' -ForEach @(
                @{ Case = 'a version-1 token one character short'; Value = 'd2pat_' + ('a' * 31) + ('0' * 10) }
                @{ Case = 'a version-1 token one character long'; Value = 'd2pat_' + ('a' * 33) + ('0' * 10) }
                @{ Case = 'a version-2 token one character short'; Value = 'd2p_' + ('a' * 43) + '000000' }
                @{ Case = 'a version-2 token one character long'; Value = 'd2p_' + ('a' * 45) + '000000' }
                @{ Case = 'another prefix'; Value = 'xxpat_' + ('a' * 32) + ('0' * 10) }
                @{ Case = 'a prefix in upper case'; Value = 'D2P_' + ('a' * 44) + '000000' }
                @{ Case = 'a version-1 body behind the version-2 prefix'; Value = 'd2p_' + ('a' * 32) + ('0' * 10) }
                @{ Case = 'a version-2 body behind the version-1 prefix'; Value = 'd2pat_' + ('a' * 44) + '000000' }
                @{ Case = 'a version-1 checksum that is not all digits'; Value = 'd2pat_' + ('a' * 32) + ('a' * 10) }
                @{ Case = 'a version-1 body with a hyphen'; Value = 'd2pat_' + ('a' * 31) + '-' + ('0' * 10) }
                @{ Case = 'a version-2 body with an underscore'; Value = 'd2p_' + ('a' * 43) + '_' + '000000' }
                # .NET's \d matches every Unicode decimal digit.
                @{ Case = 'a version-1 checksum of non-ASCII digits'; Value = 'd2pat_' + ('a' * 32) + ([string][char]0x0665 * 10) }
                @{ Case = 'a version-2 body with a non-ASCII digit'; Value = 'd2p_' + ([string][char]0x0665) + ('a' * 43) + '000000' }
                # A case-insensitive match lets [A-Za-z] take the Kelvin sign, whose lower case is 'k'.
                @{ Case = 'a version-2 body with the Kelvin sign'; Value = 'd2p_' + ([string][char]0x212A) + ('a' * 43) + '000000' }
                @{ Case = 'a token with a character before it'; Value = 'x' + 'd2p_' + ('a' * 44) + '000000' }
                @{ Case = 'a token with a character after it'; Value = 'd2p_' + ('a' * 44) + '000000' + 'x' }
                # A regex '$' also matches before a final line break.
                @{ Case = 'a version-2 token with a line break after it'; Value = 'd2p_' + ('a' * 44) + '000000' + "`n" }
                @{ Case = 'a version-1 token with a line break after it'; Value = 'd2pat_' + ('a' * 32) + ('0' * 10) + "`n" }
                @{ Case = 'an empty string'; Value = '' }
            ) {
                Test-DHIS2PersonalAccessToken $Value | Should -BeFalse
            }

            It '-Invert inverts the answer' {
                Test-DHIS2PersonalAccessToken $script:V2DigitFirst -Invert | Should -BeFalse
                Test-DHIS2PersonalAccessToken 'nope' -Invert | Should -BeTrue
            }
            It '-Throw throws on a string that is no token, without the string' {
                $record = Get-ThrownRecord { Test-DHIS2PersonalAccessToken 'd2p_not-quite-a-token' -Throw }
                $record.Exception.Message | Should -BeLike '*not a valid DHIS2 personal access token*'
                $record.Exception.Message | Should -Not -BeLike '*d2p_not-quite*'
            }
            It '-Throw passes a token of either version' {
                { Test-DHIS2PersonalAccessToken $script:V1DigitFirst -Throw } | Should -Not -Throw
                { Test-DHIS2PersonalAccessToken $script:V2LetterFirst -Throw } | Should -Not -Throw
            }
        }

        Describe 'Read-NeoIPCToken' {
            It 'returns the token -Token holds, trimmed' {
                Read-NeoIPCToken -Token "  $($script:V2LetterFirst)`t" | Should -BeExactly $script:V2LetterFirst
            }
            It 'returns the token NEOIPC_DHIS2_TOKEN holds when -Token is empty' {
                [Environment]::SetEnvironmentVariable('NEOIPC_DHIS2_TOKEN', $script:V2DigitFirst, 'Process')
                Read-NeoIPCToken -Token '' | Should -BeExactly $script:V2DigitFirst
            }
            It 'takes -Token over NEOIPC_DHIS2_TOKEN' {
                [Environment]::SetEnvironmentVariable('NEOIPC_DHIS2_TOKEN', $script:V2DigitFirst, 'Process')
                Read-NeoIPCToken -Token $script:V1LetterFirst | Should -BeExactly $script:V1LetterFirst
            }
            It 'returns nothing when neither holds a value' {
                Read-NeoIPCToken -Token '  ' | Should -BeNullOrEmpty
            }
            It 'reads the first line of the file that <Source> names' -ForEach @(
                @{ Source = '-Token' }
                @{ Source = 'NEOIPC_DHIS2_TOKEN' }
            ) {
                $path = New-TokenFile 'token.txt' "$($script:V2LetterFirst)  `r`nsecond line`r`n"
                $argument = if ($Source -eq '-Token') { $path } else { [Environment]::SetEnvironmentVariable('NEOIPC_DHIS2_TOKEN', $path, 'Process'); '' }
                Read-NeoIPCToken -Token $argument | Should -BeExactly $script:V2LetterFirst
            }
            It 'names <Source> and neither the value nor a path when the value is neither a token nor an existing file' -ForEach @(
                @{ Source = '-Token'; Expected = '-Token holds neither a DHIS2 personal access token nor the path of an existing file.' }
                @{ Source = 'NEOIPC_DHIS2_TOKEN'; Expected = 'The environment variable NEOIPC_DHIS2_TOKEN holds neither a DHIS2 personal access token nor the path of an existing file.' }
            ) {
                $missing = Join-Path $TestDrive 'no-such-token.txt'
                $argument = if ($Source -eq '-Token') { $missing } else { [Environment]::SetEnvironmentVariable('NEOIPC_DHIS2_TOKEN', $missing, 'Process'); '' }
                $record = Get-ThrownRecord { Read-NeoIPCToken -Token $argument }
                $record.Exception.Message | Should -BeExactly $Expected
                $record.CategoryInfo.Category | Should -Be 'ObjectNotFound'
                $record.ToString() | Should -Not -BeLike '*no-such-token*'
                [string]$record.TargetObject | Should -Not -BeLike '*no-such-token*'
            }
            It 'takes <Case> for neither a token nor a file' -ForEach @(
                @{ Case = 'a value no path can be'; Value = "token$([char]0)file" }
                @{ Case = 'an item of a provider other than the file system'; Value = 'Env:\NEOIPC_TEST_TOKEN_HOLDER' }
            ) {
                [Environment]::SetEnvironmentVariable('NEOIPC_TEST_TOKEN_HOLDER', $script:V2LetterFirst, 'Process')
                try {
                    # The error stream is what reaches the console; the error variable would also hold errors the reader
                    # handles.
                    $caught = [System.Collections.Generic.List[object]]::new()
                    $streamed = @(& { try { $null = Read-NeoIPCToken -Token $Value } catch { $caught.Add($_) } } 2>&1)
                    $caught.Count | Should -Be 1
                    $caught[0].Exception.Message | Should -BeExactly '-Token holds neither a DHIS2 personal access token nor the path of an existing file.'
                    $streamed.Count | Should -Be 0 -Because 'nothing else, such as the path check''s own error, may reach the console'
                }
                finally { [Environment]::SetEnvironmentVariable('NEOIPC_TEST_TOKEN_HOLDER', [NullString]::Value, 'Process') }
            }
            It 'never shows a malformed token it was given' {
                $malformed = 'd2p_' + ('S' * 43) + '000000'
                $record = Get-ThrownRecord { Read-NeoIPCToken -Token $malformed }
                $record.Exception.Message | Should -BeExactly '-Token holds neither a DHIS2 personal access token nor the path of an existing file.'
                $record.ToString() | Should -Not -BeLike '*SSSS*'
                [string]$record.TargetObject | Should -Not -BeLike '*SSSS*'
            }
            It 'says once that the token file is empty' {
                $path = New-TokenFile 'empty.txt' ''
                $record = Get-ThrownRecord { Read-NeoIPCToken -Token $path }
                $record.Exception.Message | Should -BeExactly 'The token file that -Token names is empty.'
                $record.Exception.InnerException | Should -BeNullOrEmpty
                $record.ToString() | Should -Not -BeLike '*empty.txt*'
            }
            It 'says that the first line of the token file holds no token, without showing it' {
                $path = New-TokenFile 'junk.txt' "d2p_TooShortToBeAToken`nd2p_$('a' * 44)000000`n"
                [Environment]::SetEnvironmentVariable('NEOIPC_DHIS2_TOKEN', $path, 'Process')
                $record = Get-ThrownRecord { Read-NeoIPCToken -Token '' }
                $record.Exception.Message | Should -BeExactly 'The first line of the token file that the environment variable NEOIPC_DHIS2_TOKEN names holds no DHIS2 personal access token.'
                $record.ToString() | Should -Not -BeLike '*TooShort*'
                $record.ToString() | Should -Not -BeLike '*junk.txt*'
            }
        }

        Describe 'Format-NeoIPCMessageValue' {
            It 'withholds a value that begins like a token, of <Version>' -ForEach @(
                @{ Version = 'version 1'; Value = 'd2pat_' + ('a' * 32) + ('0' * 10) }
                @{ Version = 'version 2'; Value = 'd2p_' + ('a' * 44) + '000000' }
                @{ Version = 'version 2, malformed'; Value = 'd2p_abc' }
            ) {
                Format-NeoIPCMessageValue -Value $Value | Should -Not -BeLike '*aaa*'
                Format-NeoIPCMessageValue -Value $Value | Should -Not -BeLike '*abc*'
            }
            It 'withholds a token''s prefix anywhere in a value, <Case>' -ForEach @(
                @{ Case = 'after a space'; Value = ' d2p_' + ('a' * 44) + '000000' }
                @{ Case = 'after the ApiToken scheme of an Authorization header'; Value = 'ApiToken d2p_' + ('a' * 44) + '000000' }
                @{ Case = 'in upper case'; Value = 'D2PAT_' + ('a' * 32) + ('0' * 10) }
            ) {
                Format-NeoIPCMessageValue -Value $Value | Should -BeExactly '(a personal access token, not shown)'
            }
            It 'shows any other value as it is, a UID beginning with d2p included' {
                Format-NeoIPCMessageValue -Value 'd2pAbcdefgh' | Should -BeExactly 'd2pAbcdefgh'
                Format-NeoIPCMessageValue -Value '../users/x' | Should -BeExactly '../users/x'
            }
        }

        Describe 'Resolve-NeoIPCAuth' {
            It 'returns token auth for a token of <Version>' -ForEach @(
                @{ Version = 'version 2'; Value = 'd2p_' + 'Q' + ('a' * 43) + '0aZ9zZ' }
                # NEOIPC-COMPAT(dhis2-version-1-token): see Public/Auth.ps1.
                @{ Version = 'version 1'; Value = 'd2pat_' + ('a' * 32) + ('0' * 10) }
            ) {
                Mock Read-Host { throw 'Resolve-NeoIPCAuth asked for credentials.' }
                $auth = Resolve-NeoIPCAuth -Token $Value
                $auth.AuthType | Should -Be 'Token'
                $auth.Token | Should -BeExactly $Value
            }
            It 'ends with the reader''s message, unwrapped, for a token file that does not exist' {
                $record = Get-ThrownRecord { Resolve-NeoIPCAuth -Token (Join-Path $TestDrive 'missing.txt') }
                $record.Exception.Message | Should -BeExactly '-Token holds neither a DHIS2 personal access token nor the path of an existing file.'
            }
            It 'ends with one message for an empty token file' {
                $record = Get-ThrownRecord { Resolve-NeoIPCAuth -Token (New-TokenFile 'empty.txt' '') }
                $record.Exception.Message | Should -BeExactly 'The token file that -Token names is empty.'
            }
            It 'asks for the username and the password when no token is given' {
                Mock Read-Host { if ($AsSecureString) { [System.Net.NetworkCredential]::new('', 'made-up').SecurePassword } else { 'someone' } }
                $auth = Resolve-NeoIPCAuth
                $auth.AuthType | Should -Be 'Basic'
                $auth.Username | Should -BeExactly 'someone'
                Get-NeoIPCAuthPassword -Auth $auth | Should -BeExactly 'made-up'
                Should -Invoke Read-Host -Times 2 -Exactly
            }
            It 'asks only for the password when -UserName is given' {
                Mock Read-Host { if ($AsSecureString) { [System.Net.NetworkCredential]::new('', 'made-up').SecurePassword } else { throw 'asked for the username' } }
                (Resolve-NeoIPCAuth -UserName 'admin').Username | Should -BeExactly 'admin'
                Should -Invoke Read-Host -Times 1 -Exactly
            }
        }

        Describe 'Get-NeoIPCAuthPassword' {
            It 'returns nothing for token auth' {
                Get-NeoIPCAuthPassword -Auth @{ AuthType = 'Token'; Token = $script:V2LetterFirst } | Should -BeNullOrEmpty
            }
        }

        Describe 'Help' {
            It 'documents every parameter of <Name>' -ForEach @(
                @{ Name = 'Test-DHIS2PersonalAccessToken' }
                @{ Name = 'Resolve-NeoIPCAuth' }
                @{ Name = 'Get-NeoIPCAuthPassword' }
            ) {
                $help = Get-Help $Name -Full
                $help.Synopsis | Should -Not -BeLike "*$Name*" -Because 'a missing help block leaves Get-Help a synthesized syntax line'
                @($help.parameters.parameter | Where-Object { -not $_.description } | ForEach-Object name) | Should -BeNullOrEmpty
            }
            It 'parses a help block for every function of Public/Auth.ps1' {
                $path = Join-Path (Get-Module NeoIPC-Tools).ModuleBase 'Public/Auth.ps1'
                $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
                $functions = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false))
                $functions.Count | Should -Be 3
                foreach ($f in $functions) { $f.GetHelpContent().Synopsis | Should -Not -BeNullOrEmpty -Because "$($f.Name) needs help" }
            }
        }
    }
}
