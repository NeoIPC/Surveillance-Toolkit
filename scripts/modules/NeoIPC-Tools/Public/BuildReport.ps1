<#
.SYNOPSIS
Write a standardised build report to the console and optionally to a JSON file.

.DESCRIPTION
Owns the build-report JSON schema so every report wrapper produces a consistent report.
Computes the build status from the error list and the $BuildCompleted flag, writes a
coloured console summary, and optionally persists the JSON.

Common fields are first-class parameters, emitted with fixed camelCase keys in a fixed
order and only when supplied — so per-wrapper field sets stay honest while the naming,
casing and ordering are owned centrally. -ExtraFields carries genuinely per-wrapper
one-off fields (e.g. patientId, departmentCode, outputLayout).

CTRL+C (PipelineStoppedException) bypasses catch blocks, so $BuildCompleted distinguishes
a clean finish (true) from an interrupted one (false with no errors).

.OUTPUTS
The status string: 'success', 'failed', or 'cancelled'.
#>
function Write-NeoIPCBuildReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$StartedAt,

        [string[]]$Errors = @(),

        [string[]]$OutputFilePaths = @(),

        [bool]$BuildCompleted = $false,

        [string]$BuildReportFilePath,

        # Universal build-context metadata — emitted (in this order) only when supplied.
        [string]$ScriptTimestamp,
        [string]$OutputDirPath,

        # Common fields — emitted (in this order) only when supplied.
        [string[]]$SiteCodes,
        [string[]]$OutputLocales,
        [string[]]$OutputFormats,
        [System.Collections.IDictionary]$GeneratedDataFile,
        [System.Collections.IDictionary]$Backup,
        [string]$ParameterHash,
        $Parameters,
        [System.Collections.IEnumerable]$BuildSteps,

        # Genuinely per-wrapper one-off fields.
        [System.Collections.Specialized.OrderedDictionary]$ExtraFields
    )

    $completedAt = (Get-Date -AsUTC).ToString('o')
    $status = if ($Errors.Count -gt 0) { 'failed' }
              elseif (-not $BuildCompleted) { 'cancelled' }
              else { 'success' }

    $sortedOutputFilePaths = @($OutputFilePaths | Sort-Object -Unique)

    $buildReport = [ordered]@{
        name            = $Name
        status          = $status
        startedAt       = $StartedAt
        completedAt     = $completedAt
        outputFilePaths = $sortedOutputFilePaths
    }
    if ($PSBoundParameters.ContainsKey('ScriptTimestamp'))   { $buildReport['scriptTimestamp']   = $ScriptTimestamp }
    if ($PSBoundParameters.ContainsKey('OutputDirPath'))     { $buildReport['outputDirPath']     = $OutputDirPath }
    if ($PSBoundParameters.ContainsKey('SiteCodes'))         { $buildReport['siteCodes']         = $SiteCodes }
    if ($PSBoundParameters.ContainsKey('OutputLocales'))     { $buildReport['outputLocales']     = @($OutputLocales) }
    if ($PSBoundParameters.ContainsKey('OutputFormats'))     { $buildReport['outputFormats']     = @($OutputFormats) }
    if ($PSBoundParameters.ContainsKey('GeneratedDataFile')) { $buildReport['generatedDataFile'] = $GeneratedDataFile }
    if ($PSBoundParameters.ContainsKey('Backup'))            { $buildReport['backup']            = $Backup }
    if ($PSBoundParameters.ContainsKey('ParameterHash'))     { $buildReport['parameterHash']     = $ParameterHash }
    if ($PSBoundParameters.ContainsKey('Parameters'))        { $buildReport['parameters']        = $Parameters }
    if ($PSBoundParameters.ContainsKey('BuildSteps'))        { $buildReport['buildSteps']        = @($BuildSteps) }
    if ($ExtraFields) {
        foreach ($key in $ExtraFields.Keys) { $buildReport[$key] = $ExtraFields[$key] }
    }
    $buildReport['errors'] = $Errors

    if (-not [string]::IsNullOrWhiteSpace($BuildReportFilePath)) {
        try {
            $buildReport | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $BuildReportFilePath
            Write-Verbose "Generated build report: $BuildReportFilePath"
        }
        catch {
            Write-Warning "Failed to write build report: $($_.Exception.Message)"
        }
    }

    if ($status -eq 'success') {
        Write-Host "Build status: $status" -ForegroundColor Green
    } elseif ($status -eq 'cancelled') {
        Write-Host "Build status: $status" -ForegroundColor Yellow
    } else {
        Write-Host "Build status: $status" -ForegroundColor Red
    }

    Write-Host "Outputs:"
    $sortedOutputFilePaths | ForEach-Object { Write-Host "  $_" }

    if (-not [string]::IsNullOrWhiteSpace($BuildReportFilePath)) {
        Write-Host "Build report: $BuildReportFilePath"
    }

    return $status
}

<#
.SYNOPSIS
Construct a standard build-step entry for a build report's buildSteps array.

.DESCRIPTION
Returns an ordered dictionary with the canonical per-step schema (camelCase). Omitted
fields stay $null. Pair with Complete-NeoIPCBuildStep to record the outcome after the
step runs.
#>
function New-NeoIPCBuildStep {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [string]$SiteCode,
        [string]$OutputLocale,
        [string]$OutputFormat,
        [string]$OutputFileName,
        [string]$QmdFilePath,
        [System.Collections.IDictionary]$QmdParams
    )
    $bp = $PSBoundParameters
    return [ordered]@{
        siteCode       = if ($bp.ContainsKey('SiteCode'))       { $SiteCode }       else { $null }
        outputLocale   = if ($bp.ContainsKey('OutputLocale'))   { $OutputLocale }   else { $null }
        outputFormat   = if ($bp.ContainsKey('OutputFormat'))   { $OutputFormat }   else { $null }
        stepStartedAt  = (Get-Date -AsUTC).ToString('o')
        outputFileName = if ($bp.ContainsKey('OutputFileName')) { $OutputFileName } else { $null }
        qmdFilePath    = if ($bp.ContainsKey('QmdFilePath'))    { $QmdFilePath }    else { $null }
        qmdParams      = if ($bp.ContainsKey('QmdParams'))      { $QmdParams }      else { @{} }
        messages       = @()
        status         = 'planned'
        exitCode       = $null
    }
}

<#
.SYNOPSIS
Record the outcome of a build step.

.DESCRIPTION
Maps the { Status, ExitCode, Messages } object that Invoke-Rscript / Invoke-QuartoRender
return onto the step's status (Success->success, Error->error, NoData->nodata; anything
else leaves the current status), exitCode, and messages (appended). Explicit -Status /
-ExitCode / -Messages override, for callers without a helper result (e.g. -WhatIf planned
steps). Mutates the step in place and returns it.
#>
function Complete-NeoIPCBuildStep {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [System.Collections.Specialized.OrderedDictionary]$Step,

        [psobject]$Result,

        [ValidateSet('planned', 'success', 'error', 'nodata')]
        [string]$Status,

        [object]$ExitCode,

        [string[]]$Messages
    )
    process {
        if ($Result) {
            $Step['exitCode'] = $Result.ExitCode
            if ($null -ne $Result.Messages) { $Step['messages'] = @($Step['messages']) + @($Result.Messages) }
            switch ($Result.Status) {
                'Success' { $Step['status'] = 'success' }
                'Error'   { $Step['status'] = 'error' }
                'NoData'  { $Step['status'] = 'nodata' }
            }
        }
        if ($PSBoundParameters.ContainsKey('ExitCode')) { $Step['exitCode'] = $ExitCode }
        if ($PSBoundParameters.ContainsKey('Status'))   { $Step['status'] = $Status }
        if ($PSBoundParameters.ContainsKey('Messages')) { $Step['messages'] = @($Step['messages']) + @($Messages) }
        return $Step
    }
}

<#
.SYNOPSIS
Snapshot + hash the caller's bound parameters for a build report.

.DESCRIPTION
Takes the caller's $PSBoundParameters — the parameters explicitly supplied at the call
site (parameters left at their defaults are absent, and values are as bound, not resolved)
— drops sensitive/excluded keys, and returns @{ hash = <sha256 hex>; source = <ordered
snapshot> } so every wrapper records the same shape of invocation metadata. Feed the two
members to Write-NeoIPCBuildReport's -ParameterHash / -Parameters.
#>
function Get-NeoIPCParameterSnapshot {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$BoundParameters,

        [string[]]$Exclude = @('Token', 'Password')
    )
    $snapshot = [ordered]@{}
    foreach ($key in ($BoundParameters.Keys | Sort-Object)) {
        if ($key -in $Exclude) { continue }
        $snapshot[$key] = $BoundParameters[$key]
    }
    $json = $snapshot | ConvertTo-Json -Depth 100 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $hashBytes = [System.Security.Cryptography.SHA256]::HashData($bytes)
    $hex = ([System.BitConverter]::ToString($hashBytes) -replace '-', '').ToLowerInvariant()
    return [ordered]@{
        hash   = $hex
        source = $snapshot
    }
}
