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

if ($Quiet) {
    $VerbosePreference = 'SilentlyContinue'
    $DebugPreference = 'SilentlyContinue'
    $InformationPreference = 'SilentlyContinue'
    $ProgressPreference = 'SilentlyContinue'
}

$scriptTimestamp = (Get-Date -AsUTC).ToString("yyyy-MM-dd_HHmmss'Z'")
$repoRoot = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')
$reportDirPath = Resolve-Path -LiteralPath (Join-Path $repoRoot 'reports/Reference-Report')

# Resolve OutputDir (relative to caller's CWD); fall back to the report's _output
$effectiveOutputDir = if ($OutputDir) { $OutputDir } else { Join-Path $reportDirPath '_output' }
$outputDirPath = Resolve-Path -LiteralPath $effectiveOutputDir -ErrorAction SilentlyContinue
if (-not $outputDirPath) {
    # Resolve to absolute path without requiring the directory to exist.
    # New-Item respects -WhatIf and won't create it during dry runs, so
    # Resolve-Path would fail. The directory is created on first write by
    # Set-Content / ConvertTo-Json inside the build report function.
    $outputDirPath = [System.IO.Path]::GetFullPath($effectiveOutputDir)
} else {
    $outputDirPath = $outputDirPath.Path
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
    $null = Resolve-NeoipcLocaleQmd -ReportDir $reportDirPath -BaseName 'Reference-Report' -Locale $locale
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
    $paramHashSource = [ordered]@{ dataFile = $resolvedDataFile }
    $paramHashJson = ($paramHashSource | ConvertTo-Json -Depth 100 -Compress)
    $paramHash = [System.BitConverter]::ToString(
        [System.Security.Cryptography.SHA256]::Create().ComputeHash(
            [System.Text.Encoding]::UTF8.GetBytes($paramHashJson)
        )
    ).Replace('-', '').ToLowerInvariant()
    Write-Verbose "DataFile mode: rendering from $resolvedDataFile"
} else {
    $needsJson = $false
    if ($wantsJson -or $renderCount -gt 1 -or $BackupDataset) {
        $needsJson = $true
    }

    $jsonPath = Join-Path $outputDirPath "${scriptTimestamp}_NeoIPC-Surveillance-Reference-Report.json"
    $jsonIntermediate = $needsJson -and (-not $wantsJson)
    $backupPath = Join-Path $outputDirPath "${scriptTimestamp}_NeoIPC-Surveillance-Reference-Report.dataset.json.7z"

    $paramHashSource = [ordered]@{
        reportingPeriodFrom = $ReportingPeriodFrom
        reportingPeriodTo = $ReportingPeriodTo
        birthWeightFrom = $BirthWeightFrom
        birthWeightTo = $BirthWeightTo
        gestationWeeksFrom = $GestationWeeksFrom
        gestationWeeksTo = $GestationWeeksTo
        reportingCountries = $ReportingCountries
        includeTestUnits = [bool]$IncludeTestUnits
        includeNonCorePatients = [bool]$IncludeNonCorePatients
        backupDataset = [bool]$BackupDataset
        validationExceptionFile = $ValidationExceptionFile
    }
    $paramHashJson = ($paramHashSource | ConvertTo-Json -Depth 100 -Compress)
    $paramHash = [System.BitConverter]::ToString(
        [System.Security.Cryptography.SHA256]::Create().ComputeHash(
            [System.Text.Encoding]::UTF8.GetBytes($paramHashJson)
        )
    ).Replace('-', '').ToLowerInvariant()
}

$authForEnv = if (-not $isDataFileMode) { Resolve-NeoipcAuth -Token $Token } else { @{ AuthType = 'None' } }

# $PSBoundParameters is per-invocation; inside the Invoke-WithNeoipcAuth
# scriptblock it refers to the scriptblock's own (empty) parameter dictionary,
# not this script's. Snapshot common-parameter flags here so the scriptblock
# can read them via lexical closure.
$debugRequested   = $PSBoundParameters.ContainsKey('Debug')
$verboseRequested = $PSBoundParameters.ContainsKey('Verbose')

Invoke-WithNeoipcAuth -Auth $authForEnv -ExtraEnvVars @{ 'LC_ALL' = $null; 'NEOIPC_BACKUP_PASSWORD' = $null } -ScriptBlock {

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
# Each element can map to multiple keys (e.g. a section includes its text,
# figures and tables together).
$elementMapping = @{
    'PatientPopulation'                 = @('includeTextPatientPopulation',
                                            'includeBirthWeightFigure',
                                            'includeGestationalAgeFigure')
    'NosocomialInfections'              = @('includeTextNosocomial',
                                            'includeIncidenceDensityTable',
                                            'includeDeviceAssociatedIncidenceDensityTable')
    'InfectiousAgents'                  = @('includeTextInfectiousAgents',
                                            'includeAgentPerInfectionRateTable',
                                            'includeResistantPathogenInfectionRateTable')
    'RiskFactors'                       = @('includeTextRiskFactors',
                                            'includeRiskDensityRateTable')
    'Surgery'                           = @('includeTextSurgery',
                                            'includeSurgicalProcedureRateTable')
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
            if ($Quiet) { $rArgs += @('--quiet') }
            if ($debugRequested) { $rArgs += @('--debug') }
            if ($verboseRequested) { $rArgs += @('--verbose') }
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
    if ($Quiet) {$quartoArgsCommon += '--quiet' }
    if ($debugRequested) {
        $quartoArgsCommon += '--debug'
        $quartoArgsCommon += @('--log-level', 'debug')
    } elseif ($verboseRequested) {
        $quartoArgsCommon += '--verbose'
        $quartoArgsCommon += @('--log-level', 'info')
    } else {
        if ($Quiet) {
            $quartoArgsCommon += @('--log-level', 'error')
        }
    }
    $outputDirRelative = [System.IO.Path]::GetRelativePath($reportDirPath, $outputDirPath)
    $quartoArgsCommon += @('--output-dir', $outputDirRelative)

    Push-Location -LiteralPath $reportDirPath
    try {
        foreach ($locale in $OutputLocales) {
            $localeParts = Split-NeoipcLocale -Locale $locale
            $qmdPath = Resolve-NeoipcLocaleQmd -ReportDir $reportDirPath -BaseName 'Reference-Report' -Locale $locale
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

    $extraFields = [ordered]@{
        scriptTimestamp = $scriptTimestamp
        outputDirPath = $outputDirPath
        json = [ordered]@{
            filePath = if ($needsJson) { $jsonPath } else { $null }
            requested = $wantsJson
            intermediate = $jsonIntermediate
        }
        backup = [ordered]@{
            enabled = [bool]$BackupDataset
            filePath = if ($BackupDataset) { $backupPath } else { $null }
        }
        outputLocales = $OutputLocales
        outputFormats = $OutputFormats
        parameterHash = $paramHash
        parameters = $paramHashSource
    }
    $reportPath = if ($JsonReport) { $buildReportFilePath } else { $null }
    $status = Write-NeoipcBuildReport -Name 'Reference Report Build' `
        -Errors $errors -OutputFiles $outputFiles -BuildCompleted $buildCompleted `
        -StartedAt $startedAt -BuildReportPath $reportPath -ExtraFields $extraFields

    if ($status -ne 'success') {
        exit 1
    }
}

} # end Invoke-WithNeoipcAuth
