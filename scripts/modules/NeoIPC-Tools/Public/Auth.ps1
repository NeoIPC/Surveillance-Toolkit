# DHIS2 version-1 personal access tokens consist of three parts:
# 1. The prefix: (d2pat_)
# 2. A 32-character alphanumeric [A-Za-z0-9] random part. There is no
#    letter-first constraint, so the first character may be a digit (e.g.
#    DHIS2's own `d2pat_5xVA...`). The deployed 2.40 line builds it with the
#    Base64 `getRandomSecureToken(24)` ('-'/'_' replaced by 'x'); a newer
#    dhis2-core (the 2025 `ApiKeyTokenGenerator`) builds it letter-first —
#    either way it is alphanumeric, hence the `[a-zA-Z0-9]` first character.
# 3. The CRC32 checksum: 10 digits, zero-padded (a CRC32 value is at most
#    4294967295, so `%010d` is always exactly ten digits).
#
# The DHIS2 codebase shows that there are also version-2 personal access
# tokens but since we haven't seen them in the wild yet, we don't support
# them.
#
# See `ApiTokenServiceImpl.initToken` (generation) + `CodeGenerator
# .getRandomSecureToken` in dhis2-core, and:
# * https://docs.dhis2.org/en/develop/using-the-api/dhis-core-version-242/introduction.html#b-creating-a-token-via-the-api

function Test-DHIS2PersonalAccessToken {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Token,

        [switch]$Invert,
        [switch]$Throw
    )

    # First char is intentionally unconstrained (see the token-format note
    # above): a valid PAT random part may start with a digit.
    $result = $Token.Length -eq 48 -and $Token -cmatch 'd2pat_[a-zA-Z0-9]{32}\d{10}'

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

<#
.SYNOPSIS
Resolve a DHIS2 API token from multiple sources in priority order.

.DESCRIPTION
Resolution order:
  1. Explicit -Token parameter value
  2. NEOIPC_DHIS2_TOKEN environment variable
  3. If the resolved value is a file path, reads the first line as the token

When a token is resolved, it is validated against Test-DHIS2PersonalAccessToken.

.PARAMETER Token
Optional token string or path to a file containing the token.
#>
function Resolve-NeoIPCToken {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)]
        [string]$Token
    )

    $candidate = $Token
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        $candidate = $env:NEOIPC_DHIS2_TOKEN
    }

    if ([string]::IsNullOrWhiteSpace($candidate)) {
        throw 'No DHIS2 token provided. Set -Token <token-or-path> or the NEOIPC_DHIS2_TOKEN environment variable.'
    }

    # If the candidate is a file path, read the token from it
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        try {
            $content = Get-Content -LiteralPath $candidate -TotalCount 1 -Encoding UTF8 -ErrorAction Stop
            if ([string]::IsNullOrWhiteSpace($content)) {
                throw "Token file '$candidate' is empty."
            }
            $candidate = $content.Trim()
        }
        catch [System.Management.Automation.ItemNotFoundException] {
            throw "Token file '$candidate' not found."
        }
        catch {
            throw "Token file '$candidate' could not be read: $($_.Exception.Message)"
        }
    }

    $candidate = $candidate.Trim()

    # Validate PAT format
    Test-DHIS2PersonalAccessToken $candidate -Throw | Out-Null

    return $candidate
}

<#
.SYNOPSIS
Resolve DHIS2 authentication credentials.

.DESCRIPTION
Tries token-based auth first (parameter, env var, file), then falls back
to prompting for username/password if no token is available.

Returns a hashtable with:
  @{ AuthType = 'Token'; Token = '...' }
  @{ AuthType = 'Basic'; Username = '...'; Password = <SecureString> }

.PARAMETER Token
Optional token string or path to a file containing the token.

.PARAMETER UserName
Optional username for Basic auth. When provided (and no token is available),
the password prompt is shown without asking for the username first.
#>
function Resolve-NeoIPCAuth {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Token,

        [Parameter()]
        [string]$UserName
    )

    # Try token first: explicit param -> env var -> file
    $candidate = $Token
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        $candidate = $env:NEOIPC_DHIS2_TOKEN
    }

    if (-not [string]::IsNullOrWhiteSpace($candidate)) {
        # If it's a file path, read the token from it
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            try {
                $content = Get-Content -LiteralPath $candidate -TotalCount 1 -Encoding UTF8 -ErrorAction Stop
                if ([string]::IsNullOrWhiteSpace($content)) {
                    throw "Token file '$candidate' is empty."
                }
                $candidate = $content.Trim()
            }
            catch [System.Management.Automation.ItemNotFoundException] {
                throw "Token file '$candidate' not found."
            }
            catch {
                throw "Token file '$candidate' could not be read: $($_.Exception.Message)"
            }
        }

        $candidate = $candidate.Trim()

        # Validate PAT format
        Test-DHIS2PersonalAccessToken $candidate -Throw | Out-Null

        return @{
            AuthType = 'Token'
            Token    = $candidate
        }
    }

    # No token available -- prompt for username/password
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

<#
.SYNOPSIS
Get the plaintext password from a Resolve-NeoIPCAuth result.

.DESCRIPTION
Converts the SecureString password in a Basic auth result to plaintext.
Returns $null for Token auth.
#>
function Get-NeoIPCAuthPassword {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Auth
    )

    if ($Auth.AuthType -ne 'Basic') { return $null }
    [System.Net.NetworkCredential]::new('', $Auth.Password).Password
}
