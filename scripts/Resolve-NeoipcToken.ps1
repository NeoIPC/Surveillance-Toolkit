<#
.SYNOPSIS
Shared DHIS2 authentication resolution for NeoIPC report scripts.

.DESCRIPTION
Dot-source this file to get the Resolve-NeoipcToken function, which resolves
a DHIS2 API token from multiple sources in priority order:

  1. Explicit -Token parameter value
  2. NEOIPC_DHIS2_TOKEN environment variable
  3. If the resolved value is a file path, reads the first line as the token

Returns the resolved token string, or throws if no token is available.

.NOTES
Authentication modes supported by report scripts:
  - Token (automated scripting): resolved by this function
  - Session ID (Docker/NeoIPC-Reporting): via NEOIPC_DHIS2_SESSION_ID env var, handled by neoipcr
  - Username/password (interactive console): prompted interactively, handled per-script

.EXAMPLE
. "$PSScriptRoot/Resolve-NeoipcToken.ps1"
$resolvedToken = Resolve-NeoipcToken -Token $Token
#>

function Resolve-NeoipcToken {
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
            return $content.Trim()
        }
        catch [System.Management.Automation.ItemNotFoundException] {
            throw "Token file '$candidate' not found."
        }
        catch {
            throw "Token file '$candidate' could not be read: $($_.Exception.Message)"
        }
    }

    return $candidate.Trim()
}
