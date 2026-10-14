#Requires -Version 7.6
# DHIS2 personal access tokens come in two versions, told apart by their prefix (dhis2-core ApiTokenType and
# ApiKeyTokenGenerator):
#   1. Version 1: `d2pat_`, 32 alphanumeric characters, and their CRC32 in decimal, zero-padded to 10 digits; 48
#      characters. Only DHIS2 2.40 and earlier issue it. 2.40 builds the 32 characters from Base64 with '-' and '_'
#      replaced by 'x', so the first may be a digit. DHIS2 2.41 and later still read this version, but refuse every
#      token 2.40 issued with 400 "Checksum validation failed" (see Get-NeoIPCDhis2TokenHint).
#   2. Version 2: `d2p_`, 44 alphanumeric characters, and their CRC32 in Base62 (0-9A-Za-z), zero-padded to 6
#      characters; 54 characters. DHIS2 2.41 and later issue only this version.
# The checksum is left to DHIS2, which checks it from 2.41 on; 2.40 checks none.

function Test-DHIS2PersonalAccessToken {
    <#
    .SYNOPSIS
        Test whether a string has the shape of a DHIS2 personal access token, of version 1 or 2.
    .DESCRIPTION
        A version-1 token is `d2pat_`, 32 letters or digits, and a 10-digit checksum (48 characters); a version-2 token
        is `d2p_`, 44 letters or digits, and a 6-character checksum of letters and digits (54 characters). Only ASCII
        letters and digits count, and the whole string must match, so a token with anything around it, a line break
        included, does not. The checksum itself is not verified: DHIS2 does that when the token is used.

        DHIS2 2.41 and later refuse every version-1 token, which only DHIS2 2.40 and earlier issued: create a new token
        on the instance.
    .PARAMETER Token
        The string to test.
    .PARAMETER Invert
        Return the opposite answer: $true when the string is no token.
    .PARAMETER Throw
        Throw instead of returning $false. With -Invert, throw when the string is a token.
    .OUTPUTS
        [bool]
    .EXAMPLE
        Test-DHIS2PersonalAccessToken (Get-Content ./token.txt -TotalCount 1)

        Tells whether the first line of token.txt is a token.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string]$Token,

        [switch]$Invert,
        [switch]$Throw
    )

    # [0-9] and [A-Za-z0-9] rather than \d and \w, which match Unicode digits and letters in .NET; -cmatch, since a
    # case-insensitive match lets [A-Za-z] take the Kelvin sign; \A and \z, since $ also matches before a final line break.
    # NEOIPC-COMPAT(dhis2-version-1-token): the d2pat_ branch; remove once no supported instance runs DHIS2 2.40 or earlier
    # (/api/system/info version 2.41 or later everywhere), since 2.41 and later refuse every version-1 token 2.40 issued.
    $result = $Token -cmatch '\A(?:d2pat_[A-Za-z0-9]{32}[0-9]{10}|d2p_[A-Za-z0-9]{44}[A-Za-z0-9]{6})\z'

    if ($Invert) {
        $result = -not $result
    }
    if ($Throw -and -not $result) {
        if ($Invert) {
            throw 'The supplied token is a valid DHIS2 personal access token.'
        }
        else {
            throw 'The supplied token is not a valid DHIS2 personal access token.'
        }
    }
    return $result
}

function Resolve-NeoIPCAuth {
    <#
    .SYNOPSIS
        Resolve the credentials for DHIS2: a personal access token if one is given, else a username and password.
    .DESCRIPTION
        Takes the token from -Token or, when -Token is empty, from the environment variable NEOIPC_DHIS2_TOKEN. Either
        may hold the token itself or the path of a file whose first line is the token; a token of either version is
        accepted (see Test-DHIS2PersonalAccessToken). A value that is neither a token nor the path of an existing file,
        an empty file, and a file whose first line holds no token each end the call with an error that names where the
        value came from, never the value itself.

        With no token at all, it asks for the username (unless -UserName gives it) and the password.

        Returns a hashtable the module's DHIS2 functions take as -Auth:
          @{ AuthType = 'Token'; Token = '...' }
          @{ AuthType = 'Basic'; Username = '...'; Password = <SecureString> }
    .PARAMETER Token
        A personal access token, or the path of a file whose first line is one. When empty, the environment variable
        NEOIPC_DHIS2_TOKEN is read instead.
    .PARAMETER UserName
        The DHIS2 username for Basic authentication when no token is available; the prompt then asks only for the
        password.
    .OUTPUTS
        [hashtable]
    .EXAMPLE
        $auth = Resolve-NeoIPCAuth -Token ./my-token.txt

        Reads the token from the first line of my-token.txt.
    .EXAMPLE
        $auth = Resolve-NeoIPCAuth -UserName admin

        Without -Token and NEOIPC_DHIS2_TOKEN, asks for the password of the user admin.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Position = 0)]
        [string]$Token,

        [Parameter()]
        [string]$UserName
    )

    $resolved = Read-NeoIPCToken -Token $Token
    if ($resolved) {
        return @{
            AuthType = 'Token'
            Token    = $resolved
        }
    }

    if ([string]::IsNullOrWhiteSpace($UserName)) {
        $UserName = Read-Host -Prompt 'DHIS2 username'
    }
    if ([string]::IsNullOrWhiteSpace($UserName)) {
        throw 'No username provided.'
    }
    $securePassword = Read-Host -Prompt 'DHIS2 password' -AsSecureString

    return @{
        AuthType = 'Basic'
        Username = $UserName
        Password = $securePassword
    }
}

function Get-NeoIPCAuthPassword {
    <#
    .SYNOPSIS
        Get the plaintext password from a Resolve-NeoIPCAuth result.
    .DESCRIPTION
        Converts the SecureString password of a Basic auth result to plaintext, for a child process that needs it.
        Returns $null for Token auth.
    .PARAMETER Auth
        The hashtable Resolve-NeoIPCAuth returned.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Auth
    )

    if ($Auth.AuthType -ne 'Basic') { return $null }
    [System.Net.NetworkCredential]::new('', $Auth.Password).Password
}
