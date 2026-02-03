[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter()]
    [ValidateSet('pdf','html','docx','json')]
    [string[]]$Formats = @('pdf'),
    [Parameter()]
    [ValidateSet('en','de','es','et','gr','it','fr','af','tr','ne')]
    [string[]]$Locales = @('en'),
    [Parameter()]
    [string]$OutputDir = "${PSScriptRoot}/../reports/Reference-Report/_output",
    [Parameter()]
    [string]$ReportingPeriodFrom,
    [Parameter()]
    [string]$ReportingPeriodTo,
    [Parameter()]
    [int]$BirthWeightFrom,
    [Parameter()]
    [int]$BirthWeightTo,
    [Parameter()]
    [int]$GestationWeeksFrom,
    [Parameter()]
    [int]$GestationWeeksTo,
    [Parameter()]
    [ValidateSet('DE','EE','GR','IT','ZA','ES','CH','GB')]
    [string[]]$ReportingCountries,
    [Parameter()]
    [string]$ValidationExceptionFile,
    [Parameter()]
    [switch]$IncludeTestUnits,
    [Parameter()]
    [switch]$IncludeNonCorePatients,
    [Parameter()]
    [switch]$BackupDataset,
    [Parameter()]
    [switch]$Quiet,
    [Parameter()]
    [ValidateSet(
        'Header',
        'Introduction',
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
        'Header',
        'Introduction',
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
    $outputDirPath = New-Item -ItemType Directory -Path $OutputDir -Force
}
$outputDirPath = $outputDirPath.Path

$buildReportPath = Join-Path $outputDirPath "$scriptTimestamp.reference-report-build.json"

$quartoCmd = Get-Command -Name quarto -ErrorAction SilentlyContinue
if (-not $quartoCmd) {
    throw 'Quarto CLI not found in PATH.'
}

$rscriptCmd = Get-Command -Name Rscript -ErrorAction SilentlyContinue
if (-not $rscriptCmd) {
    throw 'Rscript not found in PATH.'
}

$formats = $Formats | ForEach-Object { $_ -split ',' } |
    ForEach-Object { $_.Trim().ToLowerInvariant() } |
    Where-Object { $_ } |
    Select-Object -Unique

$locales = $Locales | ForEach-Object { $_ -split ',' } |
    ForEach-Object { $_.Trim().ToLowerInvariant() } |
    Where-Object { $_ } |
    Select-Object -Unique

$localeMap = @{}
foreach ($locale in @('en','de','es','et','gr','it','fr','af','tr','ne')) {
    if ($locale -eq 'en') {
        $localeMap[$locale] = @{ Qmd = 'Reference-Report.qmd'; Profile = 'en' }
    } else {
        $localeMap[$locale] = @{ Qmd = "Reference-Report.$locale.qmd"; Profile = $locale }
    }
}

foreach ($locale in $locales) {
    $qmdPath = Join-Path $reportDir $localeMap[$locale].Qmd
    if (-not (Test-Path -LiteralPath $qmdPath)) {
        throw "Missing QMD for locale '$locale': $qmdPath"
    }
    $profilePath = Join-Path $reportDir "_quarto-$($localeMap[$locale].Profile).yml"
    if (-not (Test-Path -LiteralPath $profilePath)) {
        throw "Missing Quarto profile for locale '$locale': $profilePath"
    }
}

$needsJson = $false
$wantsJson = $formats -contains 'json'
$renderFormats = $formats | Where-Object { $_ -ne 'json' }
$renderCount = $renderFormats.Count * $locales.Count
if ($wantsJson -or $renderCount -gt 1 -or $BackupDataset) {
    $needsJson = $true
}

$jsonPath = Join-Path $outputDirPath "$scriptTimestamp.Reference-Report.json"
$jsonIntermediate = $needsJson -and (-not $wantsJson)
$backupPath = Join-Path $outputDirPath "$scriptTimestamp.Reference-Report.dataset.json.7z"

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

$originalEnv = @{}
foreach ($name in @(
    'NEOIPC_DHIS2_USERNAME',
    'NEOIPC_DHIS2_PASSWORD',
    'NEOIPC_BACKUP_PASSWORD'
)) {
    $originalEnv[$name] = [Environment]::GetEnvironmentVariable(
        $name,
        'Process'
    )
}

if (-not $env:NEOIPC_DHIS2_SESSION_ID -and -not $env:NEOIPC_DHIS2_TOKEN) {
    if (-not $env:NEOIPC_DHIS2_USERNAME) {
        $env:NEOIPC_DHIS2_USERNAME = Read-Host -Prompt 'DHIS2 username'
    }
    if (-not $env:NEOIPC_DHIS2_PASSWORD) {
        $securePassword = Read-Host -Prompt 'DHIS2 password' -AsSecureString
        $env:NEOIPC_DHIS2_PASSWORD = [System.Net.NetworkCredential]::new('', $securePassword).Password
    }
}

if ($BackupDataset -and [string]::IsNullOrWhiteSpace($env:NEOIPC_BACKUP_PASSWORD)) {
    $secureBackupPassword = Read-Host -Prompt 'Backup password' -AsSecureString
    $env:NEOIPC_BACKUP_PASSWORD =
        [System.Net.NetworkCredential]::new('', $secureBackupPassword).Password
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

# Map user-friendly element names to internal Quarto parameter names
$elementMapping = @{
    'Header' = 'includeHeader'
    'Introduction' = 'includeIntroduction'
    'PatientPopulation' = 'includeTextPatientPopulation'
    'NosocomialInfections' = 'includeTextNosocomial'
    'InfectiousAgents' = 'includeTextInfectiousAgents'
    'RiskFactors' = 'includeTextRiskFactors'
    'Surgery' = 'includeTextSurgery'
    'BirthWeightDistribution' = 'includeBirthWeightFigure'
    'GestationalAgeDistribution' = 'includeGestationalAgeFigure'
    'IncidenceDensityRates' = 'includeIncidenceDensityTable'
    'DeviceAssociatedRates' = 'includeDeviceAssociatedIncidenceDensityTable'
    'AgentPerInfectionRates' = 'includeAgentPerInfectionRateTable'
    'AntibioticResistanceRates' = 'includeResistantPathogenInfectionRateTable'
    'InfectiousAgentDetectionRates' = 'includeInfectiousAgentDetectionRateTable'
    'ResistanceTestRates' = 'includeAntibioticResistanceTestRateTable'
    'RiskDensityRates' = 'includeRiskDensityRateTable'
    'SurgicalProcedureRates' = 'includeSurgicalProcedureRateTable'
    'SecondaryBloodstreamInfectionRates' = 'includeSecondaryBsiRateTable'
}

# Convert user-friendly array to Quarto boolean parameters
foreach ($mapping in $elementMapping.GetEnumerator()) {
    $includeValue = $IncludeElements -contains $mapping.Key
    $commonParams[$mapping.Value] = $includeValue
}

$errors = @()
$outputFiles = @()
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
            $rResult = & $rscriptCmd @rArgs 2>&1
            if ($LASTEXITCODE -ne 0) {
                $rResult | Write-Error
                throw "Generate-Reference-Data failed with exit code $LASTEXITCODE."
            } else {
                $rResult | Write-Verbose
            }
            $outputFiles += $jsonPath
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
            $qmd = $localeMap[$locale].Qmd
            $profileName = $localeMap[$locale].Profile
            foreach ($format in $renderFormats) {
                $completedSteps++
                $percentComplete = if ($totalSteps -gt 0) { [int](100 * $completedSteps / $totalSteps) } else { 0 }
                Write-Progress -Activity 'Reference Report Build' `
                    -Status "Rendering $format for $locale" -PercentComplete $percentComplete
                $outFileName = "$scriptTimestamp.Reference-Report.$locale.$format"
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
                if ($needsJson) {
                    $quartoArgs += @('-P', "ReferenceDataFile:$jsonPath")
                }
                $quartoArgs += $quartoArgsCommon
                if ($PSCmdlet.ShouldProcess($outFile, "Render $format for $locale")) {
                    Write-Verbose "Rendering $format for $locale"
                    $quartoResult = & $quartoCmd @quartoArgs 2>&1
                    if ($LASTEXITCODE -ne 0) {
                        $errors += $quartoResult
                        throw "Quarto render failed for $locale/$format."
                    }
                    $quartoResult | Write-Verbose
                    $outputFiles += $outFile
                    Write-Verbose "Generated output: $outFile"
                }
            }
        }
    }
    finally {
        Pop-Location
    }
}
catch {
    $errors += $_.Exception.Message
    throw
}
finally {
    $completedAt = (Get-Date -AsUTC).ToString('o')
    $status = if ($errors.Count -gt 0) { 'failed' } else { 'success' }
    $buildReport = [ordered]@{
        name = 'Reference Report Build'
        status = $status
        startedAt = $startedAt
        completedAt = $completedAt
        timestamp = $scriptTimestamp
        outputDir = $outputDirPath
        outputs = $outputFiles | Sort-Object -Unique
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
        errors = $errors
    }
    $buildReport | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $buildReportPath
    Write-Verbose "Generated output: $buildReportPath"

    if ($jsonIntermediate -and $errors.Count -eq 0 -and (Test-Path -LiteralPath $jsonPath)) {
        if ($PSCmdlet.ShouldProcess($jsonPath, 'Remove intermediate JSON')) {
            Remove-Item -LiteralPath $jsonPath -Force
        }
    }

    Write-Progress -Activity 'Reference Report Build' -Completed

    Write-Host "Build status: $status"
    Write-Host "Outputs:"
    $buildReport.outputs | ForEach-Object { Write-Host "  $_" }
    Write-Host "Build report: $buildReportPath"

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
