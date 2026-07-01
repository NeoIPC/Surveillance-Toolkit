[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'Online')]
param(
    [Parameter(ParameterSetName='Online')]
    [string]$Token,

    [Parameter(ParameterSetName='DataFile', Mandatory, Position=0)]
    [ValidateScript({ Test-Path -LiteralPath $_ })]
    [string]$DataFile,

    [Parameter()]
    [ValidateSet('pdf','html','docx','json')]
    [string[]]$OutputFormats = @('pdf'),
    [ArgumentCompleter({
        param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
        @(
            Get-ChildItem -LiteralPath "$PSScriptRoot/../reports/Reference-Report/" -File -Filter 'Reference-Report.*.qmd' |
            Select-Object -ExpandProperty Name |
            ForEach-Object { if ($_ -match 'Reference-Report\.(.+)\.qmd') { $Matches[1] } }) + 'en' |
            Where-Object { $_ -like "$wordToComplete*" } |
            Sort-Object
    })]
    [Parameter()]
    [string[]]$OutputLocales = @('en'),
    [Parameter()]
    [string]$OutputDir = $null,
    [Parameter(ParameterSetName='Online')]
    [string]$ReportingPeriodFrom,
    [Parameter(ParameterSetName='Online')]
    [string]$ReportingPeriodTo,
    [Parameter(ParameterSetName='Online')]
    [int]$BirthWeightFrom,
    [Parameter(ParameterSetName='Online')]
    [int]$BirthWeightTo,
    [Parameter(ParameterSetName='Online')]
    [int]$GestationWeeksFrom,
    [Parameter(ParameterSetName='Online')]
    [int]$GestationWeeksTo,
    [Parameter(ParameterSetName='Online')]
    [ValidateSet('DE','EE','GR','IT','ZA','ES','CH','GB')]
    [string[]]$ReportingCountries,
    [Parameter(ParameterSetName='Online')]
    [string]$ValidationExceptionFile,
    [Parameter(ParameterSetName='Online')]
    [switch]$IncludeTestUnits,
    [Parameter(ParameterSetName='Online')]
    [switch]$IncludeNonCorePatients,
    [Parameter(ParameterSetName='Online')]
    [switch]$BackupDataset,
    [Parameter()]
    [switch]$HideIntroductionTexts,
    [Parameter()]
    [switch]$HideMethodsTexts,
    # Rows with fewer than this many events are flagged with a footnote
    # indicating statistical instability. Based on the relative standard
    # error of the Poisson distribution (1/sqrt(n)):
    #   n=10 -> 31.6%  n=16 -> 25.0%  n=20 -> 22.4%
    # Default 16 aligns with the 25% threshold recommended by the
    # Washington State Department of Health for flagging unstable rates.
    # Source: https://doh.wa.gov/sites/default/files/legacy/Documents/1500/SmallNumbers.pdf
    [Parameter()]
    [ValidateRange(1, 100)]
    [int]$SparseDataThreshold,
    [Parameter()]
    [ValidateSet('all', 'none', 'pooled', 'quartiles')]
    [string[]]$ConfidenceIntervals,
    [Parameter()]
    [switch]$JsonReport,
    [Parameter()]
    [switch]$Quiet,

    [Parameter(ParameterSetName='Online')]
    [string]$Dhis2Scheme = $null,

    [Parameter(ParameterSetName='Online')]
    [string]$Dhis2Hostname = $null,

    [Parameter(ParameterSetName='Online')]
    [Nullable[int]]$Dhis2Port = $null,

    [Parameter(ParameterSetName='Online')]
    [string]$Dhis2Path = $null,

    # Elements to enable on top of the QMD defaults. Each listed element
    # has its visibility flag(s) forced to true.
    [Parameter()]
    [ValidateSet(
        'PatientPopulation',
        'NosocomialInfections',
        'InfectiousAgents',
        'RiskFactors',
        'Surgery',
        'BirthWeightDistribution',
        'GestationalAgeDistribution',
        'IncidenceDensityRates',
        'DeviceAssociatedRates',
        'AgentPerInfectionRates',
        'AntibioticResistanceRates',
        'OrganismResistanceRates',
        'InfectiousAgentDetectionRates',
        'ResistanceTestRates',
        'AntibioticUtilisationRates',
        'RiskDensityRates',
        'SurgicalProcedureRates',
        'SecondaryBloodstreamInfectionRates'
    )]
    [string[]]$EnableElements = @(),
    # Elements to disable on top of the QMD defaults. Each listed element
    # has its visibility flag(s) forced to false. If an element appears in
    # both -EnableElements and -DisableElements, -DisableElements wins.
    [Parameter()]
    [ValidateSet(
        'PatientPopulation',
        'NosocomialInfections',
        'InfectiousAgents',
        'RiskFactors',
        'Surgery',
        'BirthWeightDistribution',
        'GestationalAgeDistribution',
        'IncidenceDensityRates',
        'DeviceAssociatedRates',
        'AgentPerInfectionRates',
        'AntibioticResistanceRates',
        'OrganismResistanceRates',
        'InfectiousAgentDetectionRates',
        'ResistanceTestRates',
        'AntibioticUtilisationRates',
        'RiskDensityRates',
        'SurgicalProcedureRates',
        'SecondaryBloodstreamInfectionRates'
    )]
    [string[]]$DisableElements = @()
)

Import-Module (Join-Path $PSScriptRoot 'modules' 'NeoIPC-Tools') -Force -Verbose:$false

$isDataFileMode = $PSCmdlet.ParameterSetName -eq 'DataFile'

if ($isDataFileMode -and ($OutputFormats -contains 'json')) {
    throw "The 'json' format is not supported with -DataFile. The data file is already JSON."
}

$scriptTimestamp = (Get-Date -AsUTC).ToString("yyyy-MM-dd_HHmmss'Z'")
$repoRoot = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')
$reportDirPath = Resolve-Path -LiteralPath (Join-Path $repoRoot 'reports/Reference-Report')

# Resolve OutputDir relative to the caller's location ($PWD); fall back to the report's _output.
if ($OutputDir) {
    # Resolve a relative -OutputDir against the caller's location ($PWD), not .NET's
    # [Environment]::CurrentDirectory (PowerShell does not keep them in sync). Fall
    # back to the .NET CWD only when $PWD has no filesystem path (a non-FileSystem
    # PSDrive). GetFullPath creates nothing (stays -WhatIf-safe); New-Item makes the dir.
    $base = if ([System.IO.Path]::IsPathFullyQualified($PWD.ProviderPath)) { $PWD.ProviderPath } else { [Environment]::CurrentDirectory }
    $outputDirPath = [System.IO.Path]::GetFullPath($OutputDir, $base)
    if (-not (Test-Path -LiteralPath $outputDirPath -PathType Container)) {
        New-Item -ItemType Directory -Path $outputDirPath -Force | Out-Null
    }
} else {
    $outputDirPath = Join-Path $reportDirPath '_output'
}

$buildReportFilePath = Join-Path $outputDirPath "${scriptTimestamp}_NeoIPC-Surveillance-Reference-Report-Build.json"

$quartoCmd = Get-Command -Name quarto -ErrorAction SilentlyContinue
if (-not $quartoCmd) {
    throw 'Quarto CLI not found in PATH.'
}

$rscriptCmd = $null
if (-not $isDataFileMode) {
    $rscriptCmd = Get-Command -Name Rscript -ErrorAction SilentlyContinue
    if (-not $rscriptCmd) {
        throw 'Rscript not found in PATH.'
    }
}

$OutputFormats = $OutputFormats | ForEach-Object { $_ -split ',' } |
    ForEach-Object { $_.Trim().ToLowerInvariant() } |
    Where-Object { $_ } |
    Select-Object -Unique

$OutputLocales = $OutputLocales | ForEach-Object { $_ -split ',' } |
    ForEach-Object { $_.Trim().ToLowerInvariant() } |
    Where-Object { $_ } |
    Select-Object -Unique

# Validate locale inputs and resolve QMD files
foreach ($locale in $OutputLocales) {
    $null = Resolve-NeoIPCLocaleQmd -ReportDir $reportDirPath -BaseName 'Reference-Report' -Locale $locale
}

$wantsJson = $OutputFormats -contains 'json'
$renderFormats = $OutputFormats | Where-Object { $_ -ne 'json' }
$renderCount = $renderFormats.Count * $OutputLocales.Count

if ($isDataFileMode) {
    # DataFile mode: data already exists, resolve its path
    $resolvedDataFile = (Resolve-Path -LiteralPath $DataFile).Path
    $jsonPath = $resolvedDataFile
    $needsJson = $false
    $jsonIntermediate = $false
    $backupPath = $null
    Write-Verbose "DataFile mode: rendering from $resolvedDataFile"
} else {
    $needsJson = $false
    if ($wantsJson -or $renderCount -gt 1 -or $BackupDataset) {
        $needsJson = $true
    }

    $jsonPath = Join-Path $outputDirPath "${scriptTimestamp}_NeoIPC-Surveillance-Reference-Report.json"
    $jsonIntermediate = $needsJson -and (-not $wantsJson)
    $backupPath = Join-Path $outputDirPath "${scriptTimestamp}_NeoIPC-Surveillance-Reference-Report.dataset.json.7z"
}

# Snapshot the bound parameters in script scope — inside the Invoke-WithNeoIPCAuth
# scriptblock $PSBoundParameters is the scriptblock's own (empty) dictionary. Feeds the
# build report's reproducibility fields.
$paramSnapshot = Get-NeoIPCParameterSnapshot -BoundParameters $PSBoundParameters

$authForEnv = if (-not $isDataFileMode) { Resolve-NeoIPCAuth -Token $Token } else { @{ AuthType = 'None' } }

# Resolve the unified log verbosity from -Quiet / -Verbose / -Debug. It reaches
# the child processes two ways: the NEOIPC_LOG_LEVEL environment variable (read
# by the QMDs / neoipcr) and native --quiet/--verbose/--debug flags on the child
# commands. Snapshot the common-parameter flags and resolve the level (and the
# per-child flag arrays) here in the script scope; inside the
# Invoke-WithNeoIPCAuth scriptblock $PSBoundParameters is the scriptblock's own
# (empty) dictionary, so the scriptblock reads the resolved arrays via closure.
$debugRequested   = $PSBoundParameters.ContainsKey('Debug')
$verboseRequested = $PSBoundParameters.ContainsKey('Verbose')
$logLevel =
    if ($Quiet) { 'quiet' }
    elseif ($debugRequested) { 'debug' }
    elseif ($verboseRequested) { 'verbose' }
    else { 'normal' }

# -Quiet also silences the wrapper's own progress/verbose/info streams so the
# whole pipeline is quiet, not just the logger channel.
if ($Quiet) {
    $VerbosePreference     = 'SilentlyContinue'
    $DebugPreference       = 'SilentlyContinue'
    $InformationPreference = 'SilentlyContinue'
    $ProgressPreference    = 'SilentlyContinue'
}

# Native verbosity flags for the child processes, derived from the same level.
$rscriptVerbosityArgs = switch ($logLevel) {
    'quiet'   { @('--quiet') }
    'verbose' { @('--verbose') }
    'debug'   { @('--debug') }
    default   { @() }
}
$quartoVerbosityArgs = switch ($logLevel) {
    'quiet'   { @('--quiet') }
    'verbose' { @('--log-level', 'info') }
    'debug'   { @('--log-level', 'debug') }
    default   { @() }
}

Invoke-WithNeoIPCAuth -Auth $authForEnv -ExtraEnvVars @{ 'LC_ALL' = $null; 'NEOIPC_BACKUP_PASSWORD' = $null; 'NEOIPC_LOG_LEVEL' = $logLevel } -ScriptBlock {

if (-not $isDataFileMode -and $BackupDataset -and [string]::IsNullOrWhiteSpace($env:NEOIPC_BACKUP_PASSWORD)) {
    $secureBackupPassword = Read-Host -Prompt 'Backup password' -AsSecureString
    $env:NEOIPC_BACKUP_PASSWORD =
        [System.Net.NetworkCredential]::new('', $secureBackupPassword).Password
}

$qmdParams = @{}
if ($ReportingPeriodFrom) { $qmdParams.reportingPeriodFrom = $ReportingPeriodFrom }
if ($ReportingPeriodTo) { $qmdParams.reportingPeriodTo = $ReportingPeriodTo }
if ($BirthWeightFrom) { $qmdParams.birthWeightFrom = $BirthWeightFrom }
if ($BirthWeightTo) { $qmdParams.birthWeightTo = $BirthWeightTo }
if ($GestationWeeksFrom) { $qmdParams.gestationWeeksFrom = $GestationWeeksFrom }
if ($GestationWeeksTo) { $qmdParams.gestationWeeksTo = $GestationWeeksTo }
if ($ReportingCountries) { $qmdParams.reportingCountries = ($ReportingCountries -join ',') }
if ($ValidationExceptionFile) { $qmdParams.validationExceptionFile = $ValidationExceptionFile }
$qmdParams.testUnitFilter = (-not $IncludeTestUnits)
$qmdParams.defaultPatientFilter = (-not $IncludeNonCorePatients)
if ($HideIntroductionTexts.IsPresent) { $qmdParams['includeIntroductionTexts'] = 'false' }
if ($HideMethodsTexts.IsPresent) { $qmdParams['includeMethodsTexts'] = 'false' }
if ($SparseDataThreshold) { $qmdParams['sparseDataThreshold'] = $SparseDataThreshold }
if ($ConfidenceIntervals) {
    $qmdParams['includeConfidenceIntervals'] = $ConfidenceIntervals -join ','
}

# Map user-friendly element names to internal Quarto metadata keys.
# Each element can map to multiple keys (e.g. a section includes its
# figures and tables together). Section introduction/methods texts are
# gated globally by -HideIntroductionTexts / -HideMethodsTexts, not per
# section.
$elementMapping = @{
    'PatientPopulation'                 = @('includeBirthWeightFigure',
                                            'includeGestationalAgeFigure')
    'NosocomialInfections'              = @('includeIncidenceDensityTable',
                                            'includeDeviceAssociatedIncidenceDensityTable')
    'InfectiousAgents'                  = @('includeAgentPerInfectionRateTable',
                                            'includeResistantPathogenInfectionRateTable')
    'RiskFactors'                       = @('includeRiskDensityRateTable')
    'Surgery'                           = @('includeSurgicalProcedureRateTable')
    'BirthWeightDistribution'           = @('includeBirthWeightFigure')
    'GestationalAgeDistribution'        = @('includeGestationalAgeFigure')
    'IncidenceDensityRates'             = @('includeIncidenceDensityTable')
    'DeviceAssociatedRates'             = @('includeDeviceAssociatedIncidenceDensityTable')
    'AgentPerInfectionRates'            = @('includeAgentPerInfectionRateTable')
    'AntibioticResistanceRates'         = @('includeResistantPathogenInfectionRateTable')
    'OrganismResistanceRates'           = @('includeOrganismResistanceRateTable')
    'InfectiousAgentDetectionRates'     = @('includeInfectiousAgentDetectionRateTable')
    'ResistanceTestRates'               = @('includeAntibioticResistanceTestRateTable')
    'AntibioticUtilisationRates'        = @('includeAntibioticUtilisationTable')
    'RiskDensityRates'                  = @('includeRiskDensityRateTable')
    'SurgicalProcedureRates'            = @('includeSurgicalProcedureRateTable')
    'SecondaryBloodstreamInfectionRates' = @('includeSecondaryBsiRateTable')
}

# Apply per-element overrides on top of QMD defaults.
# -EnableElements forces listed elements ON; -DisableElements forces them OFF.
# Elements in neither list keep their QMD defaults (no -P flag emitted).
# If an element appears in both lists, -DisableElements wins (disables run second).
foreach ($element in $EnableElements) {
    foreach ($key in $elementMapping[$element]) {
        $qmdParams[$key] = $true
    }
}
foreach ($element in $DisableElements) {
    foreach ($key in $elementMapping[$element]) {
        $qmdParams[$key] = $false
    }
}

$errors = @()
$outputFiles = @()
$buildCompleted = $false
$startedAt = (Get-Date -AsUTC).ToString('o')
$totalSteps = 0
$completedSteps = 0
if ($needsJson) { $totalSteps++ }
$totalSteps += ($renderFormats.Count * $OutputLocales.Count)

try {
    if ($needsJson) {
        $completedSteps++
        $percentComplete = if ($totalSteps -gt 0) { [int](100 * $completedSteps / $totalSteps) } else { 0 }
        Write-Progress -Activity 'Reference Report Build' -Status 'Generating JSON' -PercentComplete $percentComplete
        if ($PSCmdlet.ShouldProcess($jsonPath, 'Generate reference data JSON')) {
            Write-Verbose "Generating reference data JSON: $jsonPath"
            $rArgs = @('--vanilla', (Join-Path $reportDirPath 'Generate-ReferenceData.R'), '--file', $jsonPath)
            $rArgs += $rscriptVerbosityArgs
            foreach ($kvp in $qmdParams.GetEnumerator()) {
                if ($null -ne $kvp.Value -and '' -ne $kvp.Value) {
                    $rArgs += @("--$($kvp.Key)", "$($kvp.Value)")
                }
            }
            if ($IncludeTestUnits) { $rArgs += '--includeTestUnits' }
            if ($IncludeNonCorePatients) { $rArgs += '--includeNonCorePatients' }
            if ($BackupDataset) { $rArgs += @('--backup-dataset', $backupPath) }
            if ($Dhis2Scheme) { $rArgs += @('--scheme', $Dhis2Scheme) }
            if ($Dhis2Hostname) { $rArgs += @('--host', $Dhis2Hostname) }
            if ($Dhis2Port) { $rArgs += @('--port', $Dhis2Port) }
            if ($Dhis2Path) { $rArgs += @('--path', $Dhis2Path) }
            $rResult = Invoke-Rscript -Arguments $rArgs -Command $rscriptCmd -Description "Generate-ReferenceData.R"
            if ($rResult.Status -eq 'Error') {
                throw "Generate-ReferenceData.R failed (exit code $($rResult.ExitCode))."
            }
            if (-not $jsonIntermediate) {
                $outputFiles += $jsonPath
            }
            Write-Verbose "Generated output: $jsonPath"
            if ($BackupDataset) {
                $outputFiles += $backupPath
                Write-Verbose "Generated output: $backupPath"
            }
        }
    }

    $quartoArgsCommon = @()
    $quartoArgsCommon += $quartoVerbosityArgs
    $outputDirRelative = [System.IO.Path]::GetRelativePath($reportDirPath, $outputDirPath)
    $quartoArgsCommon += @('--output-dir', $outputDirRelative)

    Push-Location -LiteralPath $reportDirPath
    try {
        foreach ($locale in $OutputLocales) {
            $localeParts = Split-NeoIPCLocale -Locale $locale
            $qmdPath = Resolve-NeoIPCLocaleQmd -ReportDir $reportDirPath -BaseName 'Reference-Report' -Locale $locale
            $qmd = [System.IO.Path]::GetFileName($qmdPath)
            $profileName = $localeParts.Language

            # Set LC_ALL so R picks up the full locale (territory-specific resources)
            if ($localeParts.Territory) {
                $env:LC_ALL = "${locale}.UTF-8"
            } else {
                # Let the QMD file set its own default LC_ALL
                [Environment]::SetEnvironmentVariable('LC_ALL', $null, 'Process')
            }

            foreach ($format in $renderFormats) {
                $completedSteps++
                $percentComplete = if ($totalSteps -gt 0) { [int](100 * $completedSteps / $totalSteps) } else { 0 }
                Write-Progress -Activity 'Reference Report Build' `
                    -Status "Rendering $format for $locale" -PercentComplete $percentComplete
                $outFileName = "${scriptTimestamp}_NeoIPC-Surveillance-Reference-Report.${locale}.${format}"
                $outFile = Join-Path $outputDirPath $outFileName
                $quartoArgs = @('render', $qmd, '--profile', $profileName, '--to', $format, '-o', $outFileName)
                # All parameters via -P (R reads params$, conditional
                # blocks use cat() + when-meta="alwaysTrue" wrappers)
                foreach ($kvp in $qmdParams.GetEnumerator()) {
                    if ($null -ne $kvp.Value -and '' -ne $kvp.Value) {
                        $quartoArgs += @('-P', "$($kvp.Key):$($kvp.Value)")
                    }
                }
                if ($needsJson -or $isDataFileMode) {
                    $quartoArgs += @('-P', "referenceDataFile:$jsonPath")
                }
                if (-not $isDataFileMode) {
                    if ($Dhis2Scheme) { $quartoArgs += @('-P', "dhis2Scheme:$Dhis2Scheme") }
                    if ($Dhis2Hostname) { $quartoArgs += @('-P', "dhis2Hostname:$Dhis2Hostname") }
                    if ($Dhis2Port) { $quartoArgs += @('-P', "dhis2Port:$Dhis2Port") }
                    if ($Dhis2Path) { $quartoArgs += @('-P', "dhis2Path:$Dhis2Path") }
                }
                $quartoArgs += $quartoArgsCommon
                if ($PSCmdlet.ShouldProcess($outFile, "Render $format for $locale")) {
                    Write-Verbose "Rendering $format for $locale"
                    $renderResult = Invoke-QuartoRender -Arguments $quartoArgs -Description "$format for $locale"
                    if ($renderResult.Status -eq 'Error') {
                        $errors += $renderResult.Messages
                        throw "Quarto render failed for $locale/$format."
                    }
                    $outputFiles += $outFile
                    Write-Verbose "Generated output: $outFile"
                }
            }
        }
    }
    finally {
        Pop-Location
    }

    $buildCompleted = $true
}
catch {
    $errors += $_.Exception.Message
}
finally {
    if ($jsonIntermediate -and $errors.Count -eq 0 -and (Test-Path -LiteralPath $jsonPath)) {
        if ($PSCmdlet.ShouldProcess($jsonPath, 'Remove intermediate JSON')) {
            Remove-Item -LiteralPath $jsonPath -Force
        }
    }

    Write-Progress -Activity 'Reference Report Build' -Completed

    $json = [ordered]@{
        filePath = if ($needsJson) { $jsonPath } else { $null }
        requested = $wantsJson
        intermediate = $jsonIntermediate
    }
    $backup = [ordered]@{
        enabled = [bool]$BackupDataset
        filePath = if ($BackupDataset) { $backupPath } else { $null }
    }
    $reportFilePath = if ($JsonReport) { $buildReportFilePath } else { $null }
    $status = Write-NeoIPCBuildReport -Name 'Reference Report Build' -StartedAt $startedAt `
        -Errors $errors -OutputFilePaths $outputFiles -BuildCompleted $buildCompleted `
        -BuildReportFilePath $reportFilePath `
        -ScriptTimestamp $scriptTimestamp -OutputDirPath $outputDirPath `
        -OutputLocales $OutputLocales -OutputFormats $OutputFormats `
        -GeneratedDataFile $json -Backup $backup `
        -ParameterHash $paramSnapshot.hash -Parameters $paramSnapshot.source

    if ($status -ne 'success') {
        exit 1
    }
}

} # end Invoke-WithNeoIPCAuth
