[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'Online')]
param(
    [Parameter(ParameterSetName='Online')]
    [string]$Token,

    [Parameter(ParameterSetName='DataFile', Mandatory, Position=0)]
    [ValidateScript({ Test-Path -LiteralPath $_ })]
    [string]$DataFile,

    [Parameter()]
    [ValidateSet('pdf','html','docx','json')]
    [string[]]$Formats = @('pdf'),
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
    [string[]]$Locales = @('en'),
    [Parameter()]
    [string]$OutputDir = "${PSScriptRoot}/../reports/Reference-Report/_output",
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
    [Parameter()]
    [switch]$HideConfidenceIntervals,
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
        'InfectiousAgentDetectionRates',
        'ResistanceTestRates',
        'RiskDensityRates',
        'SurgicalProcedureRates'
    )]
    [string[]]$IncludeElements = @(
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
        'InfectiousAgentDetectionRates',
        'RiskDensityRates',
        'SurgicalProcedureRates'
    )
)

. "$PSScriptRoot/NeoipcReportHelpers.ps1"

$isDataFileMode = $PSCmdlet.ParameterSetName -eq 'DataFile'

if ($isDataFileMode -and ($Formats -contains 'json')) {
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
$reportDir = Resolve-Path -LiteralPath (Join-Path $repoRoot 'reports/Reference-Report')
$outputDirPath = Resolve-Path -LiteralPath $OutputDir -ErrorAction SilentlyContinue
if (-not $outputDirPath) {
    $outputDirPath = (New-Item -ItemType Directory -Path $OutputDir -Force).FullName
} else {
    $outputDirPath = $outputDirPath.Path
}

$buildReportPath = Join-Path $outputDirPath "${scriptTimestamp}_NeoIPC-Surveillance-Reference-Report-Build.json"

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

$formats = $Formats | ForEach-Object { $_ -split ',' } |
    ForEach-Object { $_.Trim().ToLowerInvariant() } |
    Where-Object { $_ } |
    Select-Object -Unique

$locales = $Locales | ForEach-Object { $_ -split ',' } |
    ForEach-Object { $_.Trim().ToLowerInvariant() } |
    Where-Object { $_ } |
    Select-Object -Unique

# Validate locale inputs and resolve QMD files
foreach ($locale in $locales) {
    $null = Resolve-NeoipcLocaleQmd -ReportDir $reportDir -BaseName 'Reference-Report' -Locale $locale
}

$wantsJson = $formats -contains 'json'
$renderFormats = $formats | Where-Object { $_ -ne 'json' }
$renderCount = $renderFormats.Count * $locales.Count

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

$auth = if (-not $isDataFileMode) { Resolve-NeoipcAuth -Token $Token } else { $null }

$originalEnv = @{}
foreach ($name in @(
    'NEOIPC_DHIS2_TOKEN',
    'NEOIPC_DHIS2_USER',
    'NEOIPC_DHIS2_PASSWORD',
    'NEOIPC_DHIS2_SESSION_ID',
    'NEOIPC_BACKUP_PASSWORD',
    'LC_ALL'
)) {
    $originalEnv[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}

try {
if (-not $isDataFileMode) {
    # Clear all auth env vars, then set only the resolved ones
    foreach ($name in @('NEOIPC_DHIS2_TOKEN', 'NEOIPC_DHIS2_USER',
                        'NEOIPC_DHIS2_PASSWORD', 'NEOIPC_DHIS2_SESSION_ID')) {
        [Environment]::SetEnvironmentVariable($name, $null, 'Process')
    }
    if ($auth.AuthType -eq 'Token') {
        $env:NEOIPC_DHIS2_TOKEN = $auth.Token
    } elseif ($auth.AuthType -eq 'Basic') {
        $env:NEOIPC_DHIS2_USER = $auth.Username
        $env:NEOIPC_DHIS2_PASSWORD = Get-NeoipcAuthPassword -Auth $auth
    }

    if ($BackupDataset -and [string]::IsNullOrWhiteSpace($env:NEOIPC_BACKUP_PASSWORD)) {
        $secureBackupPassword = Read-Host -Prompt 'Backup password' -AsSecureString
        $env:NEOIPC_BACKUP_PASSWORD =
            [System.Net.NetworkCredential]::new('', $secureBackupPassword).Password
    }
}

$commonParams = @{}
if ($ReportingPeriodFrom) { $commonParams.reportingPeriodFrom = $ReportingPeriodFrom }
if ($ReportingPeriodTo) { $commonParams.reportingPeriodTo = $ReportingPeriodTo }
if ($BirthWeightFrom) { $commonParams.birthWeightFrom = $BirthWeightFrom }
if ($BirthWeightTo) { $commonParams.birthWeightTo = $BirthWeightTo }
if ($GestationWeeksFrom) { $commonParams.gestationWeeksFrom = $GestationWeeksFrom }
if ($GestationWeeksTo) { $commonParams.gestationWeeksTo = $GestationWeeksTo }
if ($ReportingCountries) { $commonParams.reportingCountries = ($ReportingCountries -join ',') }
if ($ValidationExceptionFile) { $commonParams.validationExceptionFile = $ValidationExceptionFile }
$commonParams.testUnitFilter = (-not $IncludeTestUnits)
$commonParams.defaultPatientFilter = (-not $IncludeNonCorePatients)
if ($HideIntroductionTexts.IsPresent) { $commonParams['includeIntroductionTexts'] = 'false' }
if ($HideMethodsTexts.IsPresent) { $commonParams['includeMethodsTexts'] = 'false' }
if ($HideConfidenceIntervals.IsPresent) { $commonParams['includeConfidenceIntervals'] = 'false' }

# Map user-friendly element names to internal Quarto metadata keys.
# Each element can map to multiple keys (e.g. a section includes its text,
# figures and tables together).
$elementMapping = @{
    'Header'                            = @('includeHeader')
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
    'InfectiousAgentDetectionRates'     = @('includeInfectiousAgentDetectionRateTable')
    'ResistanceTestRates'               = @('includeAntibioticResistanceTestRateTable')
    'RiskDensityRates'                  = @('includeRiskDensityRateTable')
    'SurgicalProcedureRates'            = @('includeSurgicalProcedureRateTable')
    'SecondaryBloodstreamInfectionRates' = @('includeSecondaryBsiRateTable')
}

# Convert user-friendly array to Quarto boolean parameters.
# Collect all metadata keys that should be true, then set everything else false.
# Header is always included — it provides essential context for all other sections
$commonParams['includeHeader'] = $true

$enabledKeys = [System.Collections.Generic.HashSet[string]]::new()
foreach ($element in $IncludeElements) {
    if ($elementMapping.ContainsKey($element)) {
        foreach ($key in $elementMapping[$element]) {
            [void]$enabledKeys.Add($key)
        }
    }
}
foreach ($mapping in $elementMapping.GetEnumerator()) {
    foreach ($key in $mapping.Value) {
        if ($key -ne 'includeHeader') {
            $commonParams[$key] = $enabledKeys.Contains($key)
        }
    }
}

$errors = @()
$outputFiles = @()
$buildCompleted = $false
$startedAt = (Get-Date -AsUTC).ToString('o')
$totalSteps = 0
$completedSteps = 0
if ($needsJson) { $totalSteps++ }
$totalSteps += ($renderFormats.Count * $locales.Count)

try {
    if ($needsJson) {
        $completedSteps++
        $percentComplete = if ($totalSteps -gt 0) { [int](100 * $completedSteps / $totalSteps) } else { 0 }
        Write-Progress -Activity 'Reference Report Build' -Status 'Generating JSON' -PercentComplete $percentComplete
        if ($PSCmdlet.ShouldProcess($jsonPath, 'Generate reference data JSON')) {
            Write-Verbose "Generating reference data JSON: $jsonPath"
            $rArgs = @('--vanilla', (Join-Path $reportDir 'Generate-ReferenceData.R'), '--file', $jsonPath)
            if ($Quiet) { $rArgs += @('--quiet') }
            if ($PSBoundParameters.Debug) { $rArgs += @('--debug') }
            if ($PSBoundParameters.Verbose) { $rArgs += @('--verbose') }
            foreach ($kvp in $commonParams.GetEnumerator()) {
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
    if ($PSBoundParameters.Debug) {
        $quartoArgsCommon += '--debug'
        $quartoArgsCommon += @('--log-level', 'debug')
    } elseif ($PSBoundParameters.Verbose) {
        $quartoArgsCommon += '--verbose'
        $quartoArgsCommon += @('--log-level', 'info')
    } else {
        if ($Quiet) {
            $quartoArgsCommon += @('--log-level', 'error')
        }
    }
    $outputDirRelative = Resolve-Path -LiteralPath $outputDirPath -Relative -RelativeBasePath $reportDir
    $quartoArgsCommon += @('--output-dir', $outputDirRelative)

    Push-Location -LiteralPath $reportDir
    try {
        foreach ($locale in $locales) {
            $localeParts = Split-NeoipcLocale -Locale $locale
            $qmdPath = Resolve-NeoipcLocaleQmd -ReportDir $reportDir -BaseName 'Reference-Report' -Locale $locale
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
                foreach ($kvp in $commonParams.GetEnumerator()) {
                    if ($null -ne $kvp.Value -and '' -ne $kvp.Value) {
                        # Use -M for include* metadata flags, -P for other params
                        if ($kvp.Key -like 'include*') {
                            $quartoArgs += @('-M', "$($kvp.Key):$($kvp.Value)")
                        } else {
                            $quartoArgs += @('-P', "$($kvp.Key):$($kvp.Value)")
                        }
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
        timestamp = $scriptTimestamp
        outputDir = $outputDirPath
        json = [ordered]@{
            path = if ($needsJson) { $jsonPath } else { $null }
            requested = $wantsJson
            intermediate = $jsonIntermediate
        }
        backup = [ordered]@{
            enabled = [bool]$BackupDataset
            path = if ($BackupDataset) { $backupPath } else { $null }
        }
        locales = $locales
        formats = $formats
        parameterHash = $paramHash
        parameters = $paramHashSource
    }
    $reportPath = if ($JsonReport) { $buildReportPath } else { $null }
    $status = Write-NeoipcBuildReport -Name 'Reference Report Build' `
        -Errors $errors -OutputFiles $outputFiles -BuildCompleted $buildCompleted `
        -StartedAt $startedAt -BuildReportPath $reportPath -ExtraFields $extraFields

    if ($status -ne 'success') {
        exit 1
    }
}
}
finally {
    # Guaranteed env var restore — even if the inner finally or exit throws
    foreach ($name in $originalEnv.Keys) {
        $originalValue = $originalEnv[$name]
        if ([string]::IsNullOrEmpty($originalValue)) {
            [Environment]::SetEnvironmentVariable($name, $null, 'Process')
        } else {
            [Environment]::SetEnvironmentVariable(
                $name,
                $originalValue,
                'Process'
            )
        }
    }
}
