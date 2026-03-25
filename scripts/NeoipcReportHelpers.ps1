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
Build a filesystem-safe key from DHIS2 connection parameters.

.DESCRIPTION
Returns a string like "https_neoipc.charite.de_api" derived from scheme,
hostname, port, and path. Used to partition per-server cache files.
Falls back to neoipcr defaults for any null parameter.

.PARAMETER Scheme
URL scheme. Falls back to 'https'.

.PARAMETER Hostname
DHIS2 server hostname. Falls back to 'neoipc.charite.de'.

.PARAMETER Port
TCP port. Omitted from key when null.

.PARAMETER Path
API base path. Falls back to '/api'.
#>
function Get-NeoipcServerKey {
    [CmdletBinding()]
    param(
        [Parameter()] [string]$Scheme = $null,
        [Parameter()] [string]$Hostname = $null,
        [Parameter()] [Nullable[int]]$Port = $null,
        [Parameter()] [string]$Path = $null
    )

    $s = if ($Scheme) { $Scheme } else { 'https' }
    $h = if ($Hostname) { $Hostname } else { 'neoipc.charite.de' }
    $p = if ($Path) { $Path } else { '/api' }
    $key = "${s}_${h}"
    if ($Port) { $key += "_${Port}" }
    $key += "_$($p.TrimStart('/').Replace('/', '_'))"
    $key
}

<#
.SYNOPSIS
Fetch and filter NeoIPC department codes from DHIS2.

.PARAMETER Auth
Authentication hashtable from Resolve-NeoipcAuth.

.PARAMETER SiteCodeFilter
Regex pattern to filter department codes. Default: '.+' (all).

.PARAMETER Scheme
URL scheme. Defaults to 'https' when not specified.

.PARAMETER Hostname
DHIS2 server hostname. Defaults to 'neoipc.charite.de' when not specified.

.PARAMETER Port
TCP port. Not included in URL when null.

.PARAMETER Path
API base path. Defaults to '/api' when not specified.

.OUTPUTS
Sorted array of department code strings.
#>
function Get-NeoipcDepartments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Auth,

        [Parameter()]
        [string]$SiteCodeFilter = '.+',

        [Parameter()] [string]$Scheme = $null,
        [Parameter()] [string]$Hostname = $null,
        [Parameter()] [Nullable[int]]$Port = $null,
        [Parameter()] [string]$Path = $null
    )

    $effectiveScheme = if ($Scheme) { $Scheme } else { 'https' }
    $effectiveHost = if ($Hostname) { $Hostname } else { 'neoipc.charite.de' }
    $effectivePath = if ($Path) { $Path } else { '/api' }
    $baseUrl = "${effectiveScheme}://${effectiveHost}"
    if ($Port) { $baseUrl += ":$Port" }
    $deptsUrl = "${baseUrl}${effectivePath}/organisationUnitGroups.json?paging=false&filter=code:eq:NEO_DEPARTMENT&fields=organisationUnits%5Bcode%5D"

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
        throw "Failed to fetch department list from DHIS2 ($deptsUrl): $($_.Exception.Message)"
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
    $errorLines = [System.Collections.Generic.List[string]]::new()
    $skipRest = $false
    $isError = $false
    $inBacktrace = $false

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
            elseif ($s -match '^Backtrace:') {
                $inBacktrace = $true
            }
            elseif ($inBacktrace) {
                # Silently collect backtrace lines (available in Messages)
            }
            elseif ($s -match '^\s*$') {
                # skip blank lines in error block
            }
            else {
                $errorLines.Add($s) | Out-Null
                Write-Host $s -ForegroundColor Red
            }
        }
        elseif ($s -match '^(Error)|(Fehler)') {
            $isError = $true
            $errorLines.Add($s) | Out-Null
            Write-Host $s -ForegroundColor Red
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
        # Error details already streamed via Write-Host above.
        # Full output (including backtrace) available in Messages.
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
Run an Rscript command and parse its output, handling multi-line rlang errors.

.DESCRIPTION
Executes Rscript with the given arguments, routing output to Write-Verbose,
Write-Warning, or Write-Host (red) depending on content. Multi-line rlang
error messages (! message, i bullets) are kept together and displayed in red.
Backtrace lines are silently collected in Messages for debugging.

Returns a result object identical in shape to Invoke-QuartoRender.

.PARAMETER Arguments
Array of arguments to pass to Rscript.

.PARAMETER Description
Label used in debug/error messages. Default: 'Rscript'.

.PARAMETER Command
The Rscript executable. Default: 'Rscript'.

.OUTPUTS
PSCustomObject with Status ('Success' or 'Error'), ExitCode, and Messages.
#>
function Invoke-Rscript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [Parameter()]
        [string]$Description = 'Rscript',

        [Parameter()]
        [string]$Command = 'Rscript'
    )

    $messages = [System.Collections.Generic.List[string]]::new()
    $errorLines = [System.Collections.Generic.List[string]]::new()
    $isError = $false
    $inBacktrace = $false

    Write-Debug "$Description command: $Command $($Arguments -join ' ')"

    & $Command @Arguments 2>&1 | ForEach-Object -Process {
        $s = "$_"
        if ($s -eq 'System.Management.Automation.RemoteException') { $s = '' }

        $messages.Add($s) | Out-Null

        if ($isError) {
            if ($s -match '^Backtrace:') {
                $inBacktrace = $true
            }
            elseif ($inBacktrace) {
                # Silently collect backtrace lines (available in Messages)
            }
            elseif ($s -match '^\s*$') {
                # skip blank lines in error block
            }
            elseif ($s -eq 'Execution halted') {
                # final R line after an error — no need to display
            }
            else {
                $errorLines.Add($s) | Out-Null
                Write-Host $s -ForegroundColor Red
            }
        }
        elseif ($s -match '^(Error)|(Fehler)') {
            $isError = $true
            $errorLines.Add($s) | Out-Null
            Write-Host $s -ForegroundColor Red
        }
        elseif ($s -match "^(`e\[39m)?(`e\[33m)?WARNING") {
            $s | Write-Warning
        }
        else {
            $s | Write-Verbose
        }
    }

    $exitCode = $LASTEXITCODE

    if ($isError -or $exitCode -ne 0) {
        $status = 'Error'
        if ($exitCode -ne 0 -and -not $isError) {
            $messages.Add("$Description exit code $exitCode") | Out-Null
        }
    }
    else {
        $status = 'Success'
    }

    [PSCustomObject]@{
        Status     = $status
        ExitCode   = $exitCode
        Messages   = $messages
        ErrorLines = $errorLines
    }
}

<#
.SYNOPSIS
Split a locale code into its language and territory components.

.DESCRIPTION
Parses locale codes like 'de_AT', 'de', or 'en_GB' into a hashtable with
Language, Territory, and Code fields.

.PARAMETER Locale
Locale code (e.g. 'de_AT', 'de', 'en_GB', 'en').

.OUTPUTS
Hashtable with keys: Language (always set), Territory (null when absent), Code (original input).
#>
function Split-NeoipcLocale {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Locale
    )

    $parts = $Locale -split '_', 2
    return @{
        Language  = $parts[0].ToLowerInvariant()
        Territory = if ($parts.Count -gt 1) { $parts[1] } else { $null }
        Code      = $Locale
    }
}

<#
.SYNOPSIS
Resolve the localized QMD file for a report.

.DESCRIPTION
Looks for BaseName.Language.qmd first, falls back to BaseName.qmd.
Throws if neither exists. Accepts either a bare language code ('de')
or a full locale code ('de_AT'); when a full locale is passed, only the
language component is used for file resolution.

.PARAMETER ReportDir
Directory containing the QMD files.

.PARAMETER BaseName
Base name of the report (e.g. 'Partner-Report').

.PARAMETER Locale
Locale or language code (e.g. 'en', 'de', 'de_AT').
#>
function Resolve-NeoipcLocaleQmd {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ReportDir,

        [Parameter(Mandatory)]
        [string]$BaseName,

        [Parameter(Mandatory)]
        [string]$Locale
    )

    $language = (Split-NeoipcLocale -Locale $Locale).Language

    if ($language -eq 'en') {
        $qmdPath = Join-Path $ReportDir "$BaseName.qmd"
    }
    else {
        $qmdPath = Join-Path $ReportDir "$BaseName.$language.qmd"
    }

    if (Test-Path -LiteralPath $qmdPath) {
        return $qmdPath
    }

    # Fallback to default (no language suffix)
    $defaultPath = Join-Path $ReportDir "$BaseName.qmd"
    if (Test-Path -LiteralPath $defaultPath) {
        return $defaultPath
    }

    throw "No QMD found for '$BaseName' in locale '$Locale'. Expected '$qmdPath' or '$defaultPath'."
}

<#
.SYNOPSIS
Verify that Quarto is installed and knitr support is available.
#>
function Test-QuartoInstallation {
    [CmdletBinding()]
    param()

    $errors = [System.Collections.Generic.List[string]]::new()

    # Quarto emits terminal spinner frames (|), (/), (-), (\) that clutter
    # captured output. Filter them out before logging or error-checking.
    $spinnerPattern = '^\([|/\-\\]\) '

    try {
        $outInstall = & quarto check install 2>&1 |
            Where-Object { $_ -notmatch $spinnerPattern }
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
        $outKnitr = & quarto check knitr 2>&1 |
            Where-Object { $_ -notmatch $spinnerPattern }
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

<#
.SYNOPSIS
Write a standardised build report to the console and optionally to a JSON file.

.DESCRIPTION
Computes the build status from the error list and the $BuildCompleted flag,
writes a coloured console summary, and optionally persists a JSON build report.

CTRL+C (PipelineStoppedException) bypasses catch blocks, so $BuildCompleted
distinguishes a clean finish (true) from an interrupted one (false with no errors).

.PARAMETER Name
Display name for the build (e.g. 'Reference Report Build').

.PARAMETER Errors
Array of error messages collected during the build.

.PARAMETER OutputFiles
Array of output file paths produced by the build.

.PARAMETER BuildCompleted
Set to $true at the end of the try block. If $false and no errors, status is 'cancelled'.

.PARAMETER StartedAt
ISO 8601 timestamp from when the build started.

.PARAMETER BuildReportPath
Path for the JSON build report. If null or empty, no JSON file is written.

.PARAMETER ExtraFields
Ordered hashtable of additional fields to include in the JSON report
(e.g. timestamp, outputDir, locales, formats, parameterHash, parameters, steps).
These are merged after the core fields.

.OUTPUTS
The status string: 'success', 'failed', or 'cancelled'.
#>
function Write-NeoipcBuildReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [string[]]$Errors = @(),

        [string[]]$OutputFiles = @(),

        [bool]$BuildCompleted = $false,

        [Parameter(Mandatory)]
        [string]$StartedAt,

        [string]$BuildReportPath,

        [System.Collections.Specialized.OrderedDictionary]$ExtraFields
    )

    $completedAt = (Get-Date -AsUTC).ToString('o')
    $status = if ($Errors.Count -gt 0) { 'failed' }
              elseif (-not $BuildCompleted) { 'cancelled' }
              else { 'success' }

    $sortedOutputs = @($OutputFiles | Sort-Object -Unique)

    # Build the report object with core fields first, then extra fields, then errors last
    $buildReport = [ordered]@{
        name        = $Name
        status      = $status
        startedAt   = $StartedAt
        completedAt = $completedAt
        outputs     = $sortedOutputs
    }
    if ($ExtraFields) {
        foreach ($key in $ExtraFields.Keys) {
            $buildReport[$key] = $ExtraFields[$key]
        }
    }
    $buildReport['errors'] = $Errors

    # Write JSON report if requested
    if (-not [string]::IsNullOrWhiteSpace($BuildReportPath)) {
        try {
            $buildReport | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $BuildReportPath
            Write-Verbose "Generated build report: $BuildReportPath"
        }
        catch {
            Write-Warning "Failed to write build report: $($_.Exception.Message)"
        }
    }

    # Console summary
    if ($status -eq 'success') {
        Write-Host "Build status: $status" -ForegroundColor Green
    } elseif ($status -eq 'cancelled') {
        Write-Host "Build status: $status" -ForegroundColor Yellow
    } else {
        Write-Host "Build status: $status" -ForegroundColor Red
    }

    Write-Host "Outputs:"
    $sortedOutputs | ForEach-Object { Write-Host "  $_" }

    if (-not [string]::IsNullOrWhiteSpace($BuildReportPath)) {
        Write-Host "Build report: $BuildReportPath"
    }

    return $status
}
