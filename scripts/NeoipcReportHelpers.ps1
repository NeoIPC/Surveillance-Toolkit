<#
.SYNOPSIS
Shared helper functions for NeoIPC report generation scripts.

.DESCRIPTION
Dot-source this file to get shared functions for authentication resolution,
DHIS2 API access, Quarto rendering, and locale handling.

.EXAMPLE
. "$PSScriptRoot/NeoipcReportHelpers.ps1"
$auth = Resolve-NeoipcAuth -Token $Token
$sites = Get-NeoipcDepartments -Auth $auth -SiteCodeFilter 'NEO_AT.*'
Invoke-WithNeoipcAuth -Auth $auth -ScriptBlock { quarto render ... }
#>

. "$PSScriptRoot/Resolve-NeoipcToken.ps1"

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
#>
function Resolve-NeoipcAuth {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Token
    )

    # Try token first: explicit param → env var → file
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
        return @{
            AuthType = 'Token'
            Token    = $candidate.Trim()
        }
    }

    # No token available — prompt for username/password
    $username = Read-Host -Prompt 'DHIS2 username'
    if ([string]::IsNullOrWhiteSpace($username)) {
        throw 'No username provided.'
    }
    $securePassword = Read-Host -Prompt 'DHIS2 password' -AsSecureString

    return @{
        AuthType = 'Basic'
        Username = $username
        Password = $securePassword
    }
}

<#
.SYNOPSIS
Get the plaintext password from a Resolve-NeoipcAuth result.

.DESCRIPTION
Converts the SecureString password in a Basic auth result to plaintext.
Returns $null for Token auth.
#>
function Get-NeoipcAuthPassword {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Auth
    )

    if ($Auth.AuthType -ne 'Basic') { return $null }
    [System.Net.NetworkCredential]::new('', $Auth.Password).Password
}

<#
.SYNOPSIS
Fetch and filter NeoIPC department codes from DHIS2.

.PARAMETER Auth
Authentication hashtable from Resolve-NeoipcAuth.

.PARAMETER SiteCodeFilter
Regex pattern to filter department codes. Default: '.+' (all).

.OUTPUTS
Sorted array of department code strings.
#>
function Get-NeoipcDepartments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Auth,

        [Parameter()]
        [string]$SiteCodeFilter = '.+'
    )

    $deptsUrl = 'https://neoipc.charite.de/api/organisationUnitGroups.json?paging=false&filter=code:eq:NEO_DEPARTMENT&fields=organisationUnits%5Bcode%5D'

    $invokeParams = @{
        Method      = 'Get'
        Uri         = $deptsUrl
        ErrorAction = 'Stop'
    }

    if ($Auth.AuthType -eq 'Token') {
        $invokeParams.Headers = @{ 'Authorization' = "ApiToken $($Auth.Token)" }
    }
    else {
        $cred = [System.Management.Automation.PSCredential]::new(
            $Auth.Username,
            $Auth.Password)
        $invokeParams.Authentication = 'Basic'
        $invokeParams.Credential = $cred
    }

    try {
        $resp = Invoke-RestMethod @invokeParams
        $sites = if ($resp.organisationUnitGroups -and $resp.organisationUnitGroups[0].organisationUnits) {
            $resp.organisationUnitGroups[0].organisationUnits.code
        }
        else { @() }
        $sites = $sites | Where-Object { $_ -match $SiteCodeFilter } | Sort-Object
    }
    catch {
        throw "Failed to fetch department list from DHIS2: $($_.Exception.Message)"
    }

    return $sites
}

<#
.SYNOPSIS
Run a script block with NeoIPC auth environment variables scoped.

.DESCRIPTION
Saves current NEOIPC_DHIS2_* env vars, sets them from the Auth hashtable,
runs the script block, then restores original env vars in a finally block.

This allows R/Quarto child processes to pick up credentials via neoipcr's
get_auth_data() without passing them on the command line.

.PARAMETER Auth
Authentication hashtable from Resolve-NeoipcAuth.

.PARAMETER ScriptBlock
The script block to execute with scoped env vars.

.PARAMETER ExtraEnvVars
Optional hashtable of additional env vars to scope (save/restore).
Values of $null will remove the env var during the scope.
#>
function Invoke-WithNeoipcAuth {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Auth,

        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,

        [Parameter()]
        [hashtable]$ExtraEnvVars
    )

    $envNames = @(
        'NEOIPC_DHIS2_TOKEN',
        'NEOIPC_DHIS2_USER',
        'NEOIPC_DHIS2_PASSWORD',
        'NEOIPC_DHIS2_SESSION_ID'
    )
    if ($ExtraEnvVars) {
        $envNames += $ExtraEnvVars.Keys
        $envNames = $envNames | Select-Object -Unique
    }

    # Save current values
    $saved = @{}
    foreach ($name in $envNames) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }

    try {
        # Clear all auth env vars first
        foreach ($name in @('NEOIPC_DHIS2_TOKEN', 'NEOIPC_DHIS2_USER',
                           'NEOIPC_DHIS2_PASSWORD', 'NEOIPC_DHIS2_SESSION_ID')) {
            [Environment]::SetEnvironmentVariable($name, $null, 'Process')
        }

        # Set env vars matching the resolved auth type
        if ($Auth.AuthType -eq 'Token') {
            $env:NEOIPC_DHIS2_TOKEN = $Auth.Token
        }
        elseif ($Auth.AuthType -eq 'Basic') {
            $env:NEOIPC_DHIS2_USER = $Auth.Username
            $env:NEOIPC_DHIS2_PASSWORD = Get-NeoipcAuthPassword -Auth $Auth
        }

        # Set extra env vars
        if ($ExtraEnvVars) {
            foreach ($kvp in $ExtraEnvVars.GetEnumerator()) {
                [Environment]::SetEnvironmentVariable($kvp.Key, $kvp.Value, 'Process')
            }
        }

        # Execute the script block
        & $ScriptBlock
    }
    finally {
        # Restore original env vars
        foreach ($name in $saved.Keys) {
            $originalValue = $saved[$name]
            if ($null -eq $originalValue) {
                [Environment]::SetEnvironmentVariable($name, $null, 'Process')
            }
            else {
                [Environment]::SetEnvironmentVariable($name, $originalValue, 'Process')
            }
        }
    }
}

<#
.SYNOPSIS
Stream and parse Quarto render output, detecting errors and warnings.

.PARAMETER Arguments
Array of arguments to pass to quarto.

.PARAMETER Description
Human-readable description for log messages (e.g. "partner report for NEO_AT_01").

.OUTPUTS
PSCustomObject with Status ('Success', 'Error', 'NoData'), ExitCode, and Messages.
#>
function Invoke-QuartoRender {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [Parameter()]
        [string]$Description = 'Quarto render'
    )

    $messages = [System.Collections.Generic.List[string]]::new()
    $skipRest = $false
    $errorLine = ''
    $isError = $false

    Write-Debug "Quarto command: quarto $($Arguments -join ' ')"

    & quarto @Arguments 2>&1 | ForEach-Object -Process {
        if ($skipRest) { return }
        $s = "$_"
        if ($s -eq 'System.Management.Automation.RemoteException') { $s = '' }

        $messages.Add($s) | Out-Null

        if ($isError) {
            if ($s -eq '! No problem detected') {
                Write-Host "No problem detected." -ForegroundColor DarkYellow
                $skipRest = $true
            }
            else {
                if ($errorLine.Length -gt 0) {
                    Write-Error -Message $errorLine
                    $errorLine = ''
                }
                Write-Error -Message $s
            }
        }
        elseif ($s -match '^(Error)|(Fehler)') {
            $isError = $true
            $errorLine = $s
        }
        elseif ($s -match "^(`e\[39m)?(`e\[33m)?WARNING") {
            $s | Write-Warning
        }
        else {
            $s | Write-Verbose
        }
    }

    $exitCode = $LASTEXITCODE

    if ($skipRest) {
        $status = 'NoData'
    }
    elseif ($isError -or $exitCode -ne 0) {
        $status = 'Error'
        if ($exitCode -ne 0) {
            $messages.Add("Quarto exit code $exitCode") | Out-Null
        }
    }
    else {
        $status = 'Success'
        Write-Host "done." -ForegroundColor Green
    }

    [PSCustomObject]@{
        Status   = $status
        ExitCode = $exitCode
        Messages = $messages
    }
}

<#
.SYNOPSIS
Resolve the localized QMD file for a report.

.DESCRIPTION
Looks for BaseName.Language.qmd first, falls back to BaseName.qmd.
Throws if neither exists.

.PARAMETER ReportDir
Directory containing the QMD files.

.PARAMETER BaseName
Base name of the report (e.g. 'Partner-Report').

.PARAMETER Language
Language code (e.g. 'en', 'de').
#>
function Resolve-NeoipcLocaleQmd {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ReportDir,

        [Parameter(Mandatory)]
        [string]$BaseName,

        [Parameter(Mandatory)]
        [string]$Language
    )

    if ($Language -eq 'en') {
        $qmdPath = Join-Path $ReportDir "$BaseName.qmd"
    }
    else {
        $qmdPath = Join-Path $ReportDir "$BaseName.$Language.qmd"
    }

    if (Test-Path -LiteralPath $qmdPath) {
        return $qmdPath
    }

    # Fallback to default (no language suffix)
    $defaultPath = Join-Path $ReportDir "$BaseName.qmd"
    if (Test-Path -LiteralPath $defaultPath) {
        return $defaultPath
    }

    throw "No QMD found for '$BaseName' in language '$Language'. Expected '$qmdPath' or '$defaultPath'."
}

<#
.SYNOPSIS
Verify that Quarto is installed and knitr support is available.
#>
function Test-QuartoInstallation {
    [CmdletBinding()]
    param()

    $errors = [System.Collections.Generic.List[string]]::new()

    try {
        $outInstall = & quarto check install 2>&1
        if ($LASTEXITCODE -ne 0) {
            $errors.Add("'quarto check install' failed with exit code $LASTEXITCODE. Output: $([string]::Join("`n", $outInstall))")
        }
        else {
            Write-Verbose "quarto check install output:`n$([string]::Join("`n", $outInstall))"
            if ($outInstall -match 'Error|ERROR|FAILED|NOT FOUND') {
                $errors.Add("'quarto check install' output indicates problems: $([string]::Join("`n", $outInstall))")
            }
        }
    }
    catch {
        $errors.Add("Failed to run 'quarto check install': $($_.Exception.Message)")
    }

    try {
        $outKnitr = & quarto check knitr 2>&1
        if ($LASTEXITCODE -ne 0) {
            $errors.Add("'quarto check knitr' failed with exit code $LASTEXITCODE. Output: $([string]::Join("`n", $outKnitr))")
        }
        else {
            Write-Verbose "quarto check knitr output:`n$([string]::Join("`n", $outKnitr))"
            if ($outKnitr -match 'Error|ERROR|FAILED|NOT FOUND') {
                $errors.Add("'quarto check knitr' output indicates problems: $([string]::Join("`n", $outKnitr))")
            }
        }
    }
    catch {
        $errors.Add("Failed to run 'quarto check knitr': $($_.Exception.Message)")
    }

    if ($errors.Count -gt 0) {
        throw ("Quarto checks failed:`n" + ($errors -join "`n`n"))
    }
}

<#
.SYNOPSIS
Convert a hashtable of parameter values into Quarto -P key:value argument pairs.

.DESCRIPTION
Skips null and empty values. Returns an array of alternating '-P' and 'key:value' strings.

.PARAMETER Values
Hashtable of parameter names and values.
#>
function Build-QmdParamPairs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Values
    )

    $pairs = @()
    foreach ($k in $Values.Keys) {
        $v = $Values[$k]
        if ($null -ne $v -and -not ([string]::IsNullOrWhiteSpace([string]$v))) {
            $pairs += '-P'
            $pairs += "${k}:$v"
        }
    }
    return $pairs
}
