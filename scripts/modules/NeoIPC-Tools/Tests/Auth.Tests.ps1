#requires -Module Pester

# Tests for the DHIS2 personal-access-token format validator (Public/Auth.ps1):
# Test-DHIS2PersonalAccessToken. The token is `d2pat_` + a 32-char alphanumeric
# random part + a 10-digit CRC32 checksum. The random part is Base64-derived,
# NOT a UID, so its first character may be a digit — the case the earlier
# `[a-zA-Z]` first-char regex wrongly rejected.

BeforeAll {
    Import-Module -Name (Join-Path $PSScriptRoot '..') -Force

    # 48-char tokens built part-by-part so the lengths are unambiguous.
    $script:letterFirst = 'd2pat_' + ('a' * 32) + ('0' * 10)
    $script:digitFirst  = 'd2pat_' + '5' + ('a' * 31) + ('0' * 10)
}

Describe 'Test-DHIS2PersonalAccessToken' {
    It 'accepts a valid letter-first token' {
        Test-DHIS2PersonalAccessToken $letterFirst | Should -BeTrue
    }

    It 'accepts a valid digit-first token (DHIS2 PAT bodies may start with a digit)' {
        # Regression: DHIS2 generates the random part with getRandomSecureToken
        # (Base64), which is not letter-first — e.g. its own d2pat_5xVA... token.
        $digitFirst.Length | Should -Be 48
        Test-DHIS2PersonalAccessToken $digitFirst | Should -BeTrue
    }

    It 'rejects a token of the wrong length' {
        Test-DHIS2PersonalAccessToken ('d2pat_' + ('a' * 30) + ('0' * 10)) |
            Should -BeFalse
    }

    It 'rejects a token with the wrong prefix' {
        Test-DHIS2PersonalAccessToken ('xxpat_' + ('a' * 32) + ('0' * 10)) |
            Should -BeFalse
    }

    It 'rejects a token whose 10-char checksum tail is not all digits' {
        Test-DHIS2PersonalAccessToken ('d2pat_' + ('a' * 32) + ('a' * 10)) |
            Should -BeFalse
    }

    It 'rejects a token with a non-alphanumeric body character' {
        Test-DHIS2PersonalAccessToken ('d2pat_' + ('a' * 31) + '-' + ('0' * 10)) |
            Should -BeFalse
    }

    It 'rejects a non-ASCII (Unicode) digit in the checksum tail' {
        # .NET/PowerShell `\d` matches Unicode decimal digits, so [0-9] is used
        # for the checksum tail; a U+0665 (Arabic-Indic 5) tail must be rejected.
        $unicodeTail = 'd2pat_' + ('a' * 32) + ((0..9 | ForEach-Object { [char]0x0665 }) -join '')
        $unicodeTail.Length | Should -Be 48
        Test-DHIS2PersonalAccessToken $unicodeTail | Should -BeFalse
    }

    It 'accepts only the whole token (the prefix must be at the start)' {
        # The pattern is anchored, so a valid 48-char token surrounded by any
        # other characters is not accepted as a substring.
        Test-DHIS2PersonalAccessToken ('x' + $letterFirst) | Should -BeFalse
        Test-DHIS2PersonalAccessToken ($letterFirst + 'x') | Should -BeFalse
    }

    It '-Invert inverts the result' {
        Test-DHIS2PersonalAccessToken $digitFirst -Invert | Should -BeFalse
        Test-DHIS2PersonalAccessToken 'nope' -Invert | Should -BeTrue
    }

    It '-Throw throws on an invalid token' {
        { Test-DHIS2PersonalAccessToken 'nope' -Throw } |
            Should -Throw '*not a valid DHIS2 personal access token*'
    }

    It '-Throw does not throw on a valid (digit-first) token' {
        { Test-DHIS2PersonalAccessToken $digitFirst -Throw } | Should -Not -Throw
    }
}
