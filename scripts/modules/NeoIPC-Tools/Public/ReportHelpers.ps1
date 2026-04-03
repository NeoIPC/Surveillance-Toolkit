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

.PARAMETER Arguments
Array of arguments to pass to Rscript.

.PARAMETER Description
Label used in debug/error messages. Default: 'Rscript'.

.PARAMETER Command
The Rscript executable. Default: 'Rscript'.

.OUTPUTS
PSCustomObject with Status ('Success' or 'Error'), ExitCode, Messages, and ErrorLines.
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
                # final R line after an error
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
Throws if neither exists.

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

.PARAMETER Values
Hashtable of parameter names and values.

.OUTPUTS
Array of alternating '-P' and 'key:value' strings.
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
