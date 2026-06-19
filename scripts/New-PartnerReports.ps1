<#
.SYNOPSIS
Batch-generate Partner Reports for one or more sites and languages.

.DESCRIPTION
This script fetches the department/site list from DHIS2, filters by a regex, and renders the Partner Report for each site and language using Quarto.
It requires a DHIS2 API token provided as the -Token parameter or via the NEOIPC_DHIS2_TOKEN environment variable (token can be a raw token or a file path containing the token).

In DataFile mode (-DataFile), the script renders a formatted report from a pre-computed partner data JSON file without needing network access.

.NOTES
- Cleans Quarto temporary files before each render to avoid cross-iteration contamination.
- Streams and parses Quarto output to detect and report errors and warnings.

.EXAMPLE
.
    .\New-PartnerReports.ps1 -SiteCodeFilter 'NEO_.*' -OutputLocales @('en','de') -OutputDir 'C:\tmp\partner-reports' -ReferenceDataFile '2026-01-28_124237Z.Reference-Report.json' -IncludeNonCorePatients -Verbose

.EXAMPLE
.
    .\New-PartnerReports.ps1 -DataFile 'partner-data.json' -OutputLocales @('en','de') -OutputFormats pdf -OutputDir 'C:\tmp\partner-reports' -Verbose
#>
[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Low', DefaultParameterSetName='Online')]
param(
    [ArgumentCompleter({
        param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
        Import-Module (Join-Path $PSScriptRoot 'modules' 'NeoIPC-Tools') -Force -Verbose:$false
        $serverKey = Get-NeoipcServerKey `
            -Scheme $fakeBoundParameters['Dhis2Scheme'] `
            -Hostname $fakeBoundParameters['Dhis2Hostname'] `
            -Port $fakeBoundParameters['Dhis2Port'] `
            -Path $fakeBoundParameters['Dhis2Path']
        $cacheFile = Join-Path $PSScriptRoot '..' 'data' $serverKey 'site-codes.txt'
        if (Test-Path -LiteralPath $cacheFile) {
            Get-Content -LiteralPath $cacheFile |
                Where-Object { $_ -like "$wordToComplete*" } |
                Sort-Object
        } else {
            $cacheBase = Join-Path $PSScriptRoot '..' 'data'
            Get-ChildItem -LiteralPath $cacheBase -Recurse -Filter 'site-codes.txt' -ErrorAction SilentlyContinue |
                Get-Content |
                Sort-Object -Unique |
                Where-Object { $_ -like "$wordToComplete*" }
        }
    })]
    [Parameter(ParameterSetName='Online', Position=0)]
    [string]
    $SiteCodeFilter = '.+',

    [Parameter(ParameterSetName='DataFile', Mandatory, Position=0)]
    [ValidateScript({ Test-Path -LiteralPath $_ })]
    [string]
    $DataFile,

    [ArgumentCompleter({
        param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
        @(
            Get-ChildItem -LiteralPath "$PSScriptRoot/../reports/Partner-Report/" -File -Filter 'Partner-Report.*.qmd' |
            Select-Object -ExpandProperty Name |
            ForEach-Object { if ($_ -match 'Partner-Report\.(.+)\.qmd') { $Matches[1] } }) + 'en' |
            Where-Object { $_ -like "$wordToComplete*" } |
            Sort-Object
    })]
    [Parameter(Position=1)]
    [string[]]
    $OutputLocales = @('en'),

    [Parameter(ParameterSetName='Online')]
    [string]
    $Token = $null,

    [Parameter()]
    [string]
    $OutputDir = $null,

    [Parameter()]
    [string]
    $ReferenceDataFile = $null,

    [Parameter(ParameterSetName='Online')]
    [Nullable[System.DateOnly]]
    $ReportingPeriodFrom = $null,

    [Parameter(ParameterSetName='Online')]
    [Nullable[System.DateOnly]]
    $ReportingPeriodTo = $null,

    [Parameter(ParameterSetName='Online')]
    [Nullable[int]]
    $BirthWeightFrom = $null,

    [Parameter(ParameterSetName='Online')]
    [Nullable[int]]
    $BirthWeightTo = $null,

    [Parameter(ParameterSetName='Online')]
    [Nullable[int]]
    $GestationWeeksFrom = $null,

    [Parameter(ParameterSetName='Online')]
    [Nullable[int]]
    $GestationWeeksTo = $null,

    [Parameter(ParameterSetName='Online')]
    [switch]
    $IncludeNonCorePatients,

    [Parameter(ParameterSetName='Online')]
    [string]
    $ValidationExceptionFile,

    [Parameter(ParameterSetName='Online')]
    [switch]
    $IncludeTestData,

    [Parameter()]
    [switch]
    $HideIntroductionTexts,

    [Parameter()]
    [ValidateSet('all', 'none', 'rate', 'pooled', 'quartiles')]
    [string[]]
    $ConfidenceIntervals,

    [Parameter()]
    [switch]
    $HideMethodsTexts,

    [Parameter()]
    [switch]
    $HideOutlierInterpretation,

    # Rows with fewer than this many events are flagged with a footnote
    # indicating statistical instability. Based on the relative standard
    # error of the Poisson distribution (1/sqrt(n)):
    #   n=10 -> 31.6%  n=16 -> 25.0%  n=20 -> 22.4%
    # Default 16 aligns with the 25% threshold recommended by the
    # Washington State Department of Health for flagging unstable rates.
    # Source: https://doh.wa.gov/sites/default/files/legacy/Documents/1500/SmallNumbers.pdf
    [Parameter()]
    [ValidateRange(1, 100)]
    [int]
    $SparseDataThreshold,

    [Parameter()]
    [switch]
    $DebugReport,

    [Parameter()]
    [ValidateSet('pdf','html','docx','json')]
    [string[]]
    $OutputFormats = @('pdf'),

    [Parameter()]
    [switch]
    $JsonReport,

    [Parameter(ParameterSetName='Online')]
    [string]
    $Dhis2Scheme = $null,

    [Parameter(ParameterSetName='Online')]
    [string]
    $Dhis2Hostname = $null,

    [Parameter(ParameterSetName='Online')]
    [Nullable[int]]
    $Dhis2Port = $null,

    [Parameter(ParameterSetName='Online')]
    [string]
    $Dhis2Path = $null,

    # Elements to enable on top of the QMD defaults. Each listed element
    # has its visibility flag forced to true.
    [Parameter()]
    [ValidateSet(
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
    # has its visibility flag forced to false. If an element appears in
    # both -EnableElements and -DisableElements, -DisableElements wins.
    [Parameter()]
    [ValidateSet(
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

# --- Runtime validation ---
$isDataFileMode = $PSCmdlet.ParameterSetName -eq 'DataFile'

if ($isDataFileMode -and ($OutputFormats -contains 'json')) {
    throw "The 'json' format is not supported with -DataFile. The data file is already JSON."
}

# Separate json from Quarto-renderable formats
$wantsJson = $OutputFormats -contains 'json'
$renderFormats = @($OutputFormats | Where-Object { $_ -ne 'json' })

# Map user-friendly element names to internal Quarto parameter names
$elementMapping = @{
    'BirthWeightDistribution' = 'includeBirthWeightFigure'
    'GestationalAgeDistribution' = 'includeGestationalAgeFigure'
    'IncidenceDensityRates' = 'includeIncidenceDensityTable'
    'DeviceAssociatedRates' = 'includeDeviceAssociatedIncidenceDensityTable'
    'AgentPerInfectionRates' = 'includeAgentPerInfectionRateTable'
    'AntibioticResistanceRates' = 'includeResistantPathogenInfectionRateTable'
    'OrganismResistanceRates' = 'includeOrganismResistanceRateTable'
    'InfectiousAgentDetectionRates' = 'includeInfectiousAgentDetectionRateTable'
    'ResistanceTestRates' = 'includeAntibioticResistanceTestRateTable'
    'AntibioticUtilisationRates' = 'includeAntibioticUtilisationTable'
    'RiskDensityRates' = 'includeRiskDensityRateTable'
    'SurgicalProcedureRates' = 'includeSurgicalProcedureRateTable'
    'SecondaryBloodstreamInfectionRates' = 'includeSecondaryBsiRateTable'
}

# --- Start script ---
$wd = Get-Location
$reportDirPath = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..' 'reports' 'Partner-Report')

# Resolve ReferenceDataFile if provided BEFORE changing directory
# ReferenceDataFile is relative to current directory; resolve it absolutely first,
# then make it relative to partnerReportDir for Quarto
$resolvedReferenceDataFile = $null
if ($ReferenceDataFile) {
    # Resolve absolute path from current directory
    $absoluteRefPath = Resolve-Path -LiteralPath $ReferenceDataFile -ErrorAction SilentlyContinue
    if (-not $absoluteRefPath) {
        throw "Reference data file not found: $ReferenceDataFile"
    }
    $absoluteRefPath = $absoluteRefPath.Path

    # Convert to path relative to partnerReportDir for Quarto
    $resolvedReferenceDataFile = Resolve-Path -LiteralPath $absoluteRefPath -Relative -RelativeBasePath $reportDirPath
}

# Resolve DataFile if provided
$resolvedDataFile = $null
if ($DataFile) {
    $absoluteDataPath = Resolve-Path -LiteralPath $DataFile -ErrorAction SilentlyContinue
    if (-not $absoluteDataPath) {
        throw "Data file not found: $DataFile"
    }
    $absoluteDataPath = $absoluteDataPath.Path
    $resolvedDataFile = Resolve-Path -LiteralPath $absoluteDataPath -Relative -RelativeBasePath $reportDirPath
}

# Resolve OutputDir BEFORE changing directory (it's relative to the caller's CWD)
$outputDirPath = $null
if ($OutputDir) {
    # Resolve a relative -OutputDir against the caller's location ($PWD), not .NET's
    # [Environment]::CurrentDirectory (PowerShell does not keep them in sync). Fall
    # back to the .NET CWD only when $PWD has no filesystem path (a non-FileSystem
    # PSDrive). GetFullPath creates nothing (stays -WhatIf-safe); New-Item makes the dir.
    $base = if ([System.IO.Path]::IsPathFullyQualified($PWD.ProviderPath)) { $PWD.ProviderPath } else { [Environment]::CurrentDirectory }
    $outputDirPath = [System.IO.Path]::GetFullPath($OutputDir, $base)
    if (-not (Test-Path -LiteralPath $outputDirPath)) {
        New-Item -ItemType Directory -Path $outputDirPath -Force | Out-Null
    }
}

# Resolve ValidationExceptionFile BEFORE changing directory (relative to caller's CWD)
$resolvedValidationExceptionFile = $null
if ($ValidationExceptionFile) {
    $absolutePath = Resolve-Path -LiteralPath $ValidationExceptionFile -ErrorAction SilentlyContinue
    if (-not $absolutePath) {
        throw "Validation exception file not found: $ValidationExceptionFile"
    }
    $resolvedValidationExceptionFile = Resolve-Path -LiteralPath $absolutePath.Path -Relative -RelativeBasePath $reportDirPath
}

# In DataFile mode no DHIS2 auth is needed, but we still scope LC_ALL.
# Pass a dummy auth hashtable that clears env vars without setting new ones.
$authForEnv = if ($isDataFileMode) { @{ AuthType = 'None' } } else { Resolve-NeoipcAuth -Token $Token }

Invoke-WithNeoipcAuth -Auth $authForEnv -ExtraEnvVars @{ 'LC_ALL' = $null } -ScriptBlock {

# Prepare build tracking before try block so variables are always initialized,
# even if an early exception (e.g. auth failure) skips the rest of the try body
$errors = @()
$outputFiles = @()
$buildCompleted = $false
$startedAt = (Get-Date -AsUTC).ToString('o')
$scriptTimestamp = [datetime]::UtcNow.ToString("yyyy-MM-dd_HHmmss'Z'")
$buildLog = @()
$totalSteps = 0
$completedSteps = 0

try {
    Set-Location -LiteralPath $reportDirPath

    if ($isDataFileMode) {
        # DataFile mode: no auth, no department fetch
        # Extract unit codes from the serialized R object's metadata via a temp script
        $dataPathR = $absoluteDataPath -replace '\\', '/'
        $tempR = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.R'
        try {
            @"
x <- jsonlite::unserializeJSON(readChar('$dataPathR', file.info('$dataPathR')`$size))
if (inherits(x, 'neoipcr_bnch_ds')) {
  cat(paste(x`$metadata`$own`$dataset_options`$department_filter, collapse = ','))
} else if (inherits(x, 'neoipcr_rep_ds')) {
  cat(paste(x`$metadata`$dataset_options`$department_filter, collapse = ','))
} else {
  stop('Unknown data type in file')
}
"@ | Set-Content -LiteralPath $tempR -Encoding utf8
            $siteString = & Rscript --vanilla $tempR 2>$null
        } finally {
            Remove-Item -LiteralPath $tempR -ErrorAction SilentlyContinue
        }
        if (-not $siteString) {
            throw "Could not extract unit codes from data file: $DataFile"
        }
        $siteCodes = @($siteString -split ',')
        Write-Verbose "DataFile mode: rendering from $DataFile (sites: $($siteCodes -join ', '))"
    } else {
        # Online mode: auth already resolved as $authForEnv above
        $auth = $authForEnv

        # Fetch departments
        $deptArgs = @{ Auth = $auth; SiteCodeFilter = $SiteCodeFilter }
        if ($Dhis2Scheme) { $deptArgs.Scheme = $Dhis2Scheme }
        if ($Dhis2Hostname) { $deptArgs.Hostname = $Dhis2Hostname }
        if ($Dhis2Port) { $deptArgs.Port = $Dhis2Port }
        if ($Dhis2Path) { $deptArgs.Path = $Dhis2Path }
        $siteCodes = Get-NeoipcDepartments @deptArgs

        if (-not $siteCodes -or $siteCodes.Count -eq 0) {
            Write-Warning "No sites matched filter '$SiteCodeFilter'. Nothing to do.";
            return
        }
    }

    # $outputDirPath already resolved before Set-Location

    # Step counts depend on $siteCodes which is resolved inside the try block
    if ($wantsJson -and -not $isDataFileMode) { $totalSteps += $siteCodes.Count }
    if ($renderFormats.Count -gt 0) { $totalSteps += ($siteCodes.Count * $OutputLocales.Count * $renderFormats.Count) }

    # --- JSON data generation (Online mode only) ---
    if ($wantsJson -and -not $isDataFileMode) {
        $rscriptCmd = Get-Command -Name Rscript -ErrorAction SilentlyContinue
        if (-not $rscriptCmd) {
            throw 'Rscript not found in PATH.'
        }

        foreach ($siteCode in $siteCodes) {
            $jsonTimestamp = [datetime]::Now.ToString('yyyy-MM-dd_HHmmss')
            $jsonFileName = "${jsonTimestamp}_NeoIPC-Surveillance-Partner-Data_${siteCode}.json"
            $jsonOutPath = if ($outputDirPath) {
                Join-Path $outputDirPath $jsonFileName
            } else {
                Join-Path $reportDirPath '_output' $jsonFileName
            }

            $currentEntry = [ordered]@{
                Site = $siteCode
                Language = $null
                Format = 'json'
                Timestamp = (Get-Date).ToString('o')
                FileName = $jsonFileName
                Qmd = $null
                Params = @{}
                Messages = @()
                Status = 'Planned'
                ExitCode = $null
            }

            $completedSteps++
            $pct = if ($totalSteps -gt 0) { [int](100 * $completedSteps / $totalSteps) } else { 0 }
            Write-Progress -Activity 'Partner Report Build' -Status "Generating JSON for $siteCode" -PercentComplete $pct

            if ($PSCmdlet.ShouldProcess($jsonOutPath, "Generate partner data JSON for $siteCode")) {
                Write-Host "Generating partner data JSON for $siteCode..."
                $rArgs = @('--vanilla', (Join-Path $reportDirPath 'Generate-PartnerData.R'),
                           '--file', $jsonOutPath, '--unitCodes', $siteCode)
                if ($resolvedReferenceDataFile) {
                    # Resolve to absolute path for R script (it doesn't run from partnerReportDir)
                    $absRefForR = Join-Path $reportDirPath $resolvedReferenceDataFile
                    $rArgs += @('--referenceDataFile', $absRefForR)
                }
                if ($ReportingPeriodFrom -ne $null) { $rArgs += @('--reportingPeriodFrom', $ReportingPeriodFrom.ToString('yyyy-MM-dd')) }
                if ($ReportingPeriodTo -ne $null) { $rArgs += @('--reportingPeriodTo', $ReportingPeriodTo.ToString('yyyy-MM-dd')) }
                if ($BirthWeightFrom -ne $null) { $rArgs += @('--birthWeightFrom', $BirthWeightFrom) }
                if ($BirthWeightTo -ne $null) { $rArgs += @('--birthWeightTo', $BirthWeightTo) }
                if ($GestationWeeksFrom -ne $null) { $rArgs += @('--gestationWeeksFrom', $GestationWeeksFrom) }
                if ($GestationWeeksTo -ne $null) { $rArgs += @('--gestationWeeksTo', $GestationWeeksTo) }
                if ($IncludeNonCorePatients.IsPresent) { $rArgs += '--includeNonCorePatients' }
                if ($IncludeTestData.IsPresent) { $rArgs += '--includeTestData' }
                if ($resolvedValidationExceptionFile) {
                    $absVefForR = Join-Path $reportDirPath $resolvedValidationExceptionFile
                    $rArgs += @('--validationExceptionFile', $absVefForR)
                }
                if ($Dhis2Scheme) { $rArgs += @('--scheme', $Dhis2Scheme) }
                if ($Dhis2Hostname) { $rArgs += @('--host', $Dhis2Hostname) }
                if ($Dhis2Port) { $rArgs += @('--port', $Dhis2Port) }
                if ($Dhis2Path) { $rArgs += @('--path', $Dhis2Path) }

                $rResult = Invoke-Rscript -Arguments $rArgs -Command $rscriptCmd -Description "Generate-PartnerData.R ($siteCode)"

                $currentEntry.ExitCode = $rResult.ExitCode
                $currentEntry.Messages = $rResult.Messages
                if ($rResult.Status -eq 'Success') {
                    Write-Host "done." -ForegroundColor Green
                    $currentEntry.Status = 'Success'
                    $outputFiles += $jsonOutPath
                } else {
                    $errMsg = "Generate-PartnerData.R failed (exit code $($rResult.ExitCode)) for site $siteCode."
                    Write-Error $errMsg
                    $errors += $errMsg
                    $currentEntry.Status = 'Error'
                }
            } else {
                $currentEntry.Status = 'Planned'
                $currentEntry.Messages += "WhatIf: would generate partner data JSON for $siteCode"
            }

            $buildLog += (New-Object PSObject -Property $currentEntry)
        }
    }

    # --- Quarto rendering (if any renderable formats requested) ---
    if ($renderFormats.Count -gt 0) {
        # Check Quarto once before iterating (time-consuming; no need to repeat)
        try {
            Test-QuartoInstallation
        }
        catch {
            throw "Quarto checks failed: $($_.Exception.Message)"
        }

        # Loop by locale and site
        foreach ($locale in $OutputLocales) {
            $localeParts = Split-NeoipcLocale -Locale $locale
            $lang = $localeParts.Language
            $qmdToUse = Resolve-NeoipcLocaleQmd -ReportDir $reportDirPath -BaseName 'Partner-Report' -Locale $locale

            # Set LC_ALL so R picks up the full locale (territory-specific resources)
            if ($localeParts.Territory) {
                $env:LC_ALL = "${locale}.UTF-8"
            } else {
                [Environment]::SetEnvironmentVariable('LC_ALL', $null, 'Process')
            }

            foreach ($siteCode in $siteCodes) {
                Write-Host "Generating partner report for $siteCode (locale: $locale)..."

                # Build file name and paths
                $timestamp = [datetime]::Now.ToString('yyyy-MM-dd_HHmmss')

                # Build -P parameter list (only supported QMD params)
                $qmdParams = @{}

                $qmdParams['unitCodes'] = $siteCode

                if ($isDataFileMode) {
                    # DataFile mode: pass data file to QMD
                    $qmdParams['partnerDataFile'] = $resolvedDataFile
                } else {
                    # Online mode: pass data params
                    if ($ReportingPeriodFrom -ne $null) { $qmdParams['reportingPeriodFrom'] = $ReportingPeriodFrom.ToString('yyyy-MM-dd') }
                    if ($ReportingPeriodTo -ne $null) { $qmdParams['reportingPeriodTo'] = $ReportingPeriodTo.ToString('yyyy-MM-dd') }
                    if ($BirthWeightFrom -ne $null) { $qmdParams['birthWeightFrom'] = $BirthWeightFrom }
                    if ($BirthWeightTo -ne $null) { $qmdParams['birthWeightTo'] = $BirthWeightTo }
                    if ($GestationWeeksFrom -ne $null) { $qmdParams['gestationWeeksFrom'] = $GestationWeeksFrom }
                    if ($GestationWeeksTo -ne $null) { $qmdParams['gestationWeeksTo'] = $GestationWeeksTo }
                    if ($IncludeNonCorePatients.IsPresent) { $qmdParams['includeNonCorePatients'] = 'true' }
                    if ($IncludeTestData.IsPresent) { $qmdParams['includeTestData'] = 'true' }
                    if ($resolvedValidationExceptionFile) { $qmdParams['validationExceptionFile'] = $resolvedValidationExceptionFile }
                    if ($Dhis2Scheme) { $qmdParams['dhis2Scheme'] = $Dhis2Scheme }
                    if ($Dhis2Hostname) { $qmdParams['dhis2Hostname'] = $Dhis2Hostname }
                    if ($Dhis2Port) { $qmdParams['dhis2Port'] = $Dhis2Port }
                    if ($Dhis2Path) { $qmdParams['dhis2Path'] = $Dhis2Path }
                }

                if ($resolvedReferenceDataFile) { $qmdParams['referenceDataFile'] = $resolvedReferenceDataFile }
                if ($HideIntroductionTexts.IsPresent) { $qmdParams['includeIntroductionTexts'] = 'false' }
                if ($ConfidenceIntervals) { $qmdParams['includeConfidenceIntervals'] = $ConfidenceIntervals -join ',' }
                if ($HideMethodsTexts.IsPresent) { $qmdParams['includeMethodsTexts'] = 'false' }
                if ($SparseDataThreshold) { $qmdParams['sparseDataThreshold'] = $SparseDataThreshold }
                if ($HideOutlierInterpretation.IsPresent) { $qmdParams['includeOutlierInterpretation'] = 'false' }
                if ($DebugReport) { $qmdParams['debug'] = 'true' }

                # Apply per-element overrides on top of QMD defaults.
                # -EnableElements forces listed elements ON; -DisableElements forces them OFF.
                # Elements in neither list keep their QMD defaults (no -P flag emitted).
                # If an element appears in both lists, -DisableElements wins (disables run second).
                foreach ($element in $EnableElements) {
                    $qmdParams[$elementMapping[$element]] = 'true'
                }
                foreach ($element in $DisableElements) {
                    $qmdParams[$elementMapping[$element]] = 'false'
                }

                $paramPairs = Build-QmdParamPairs -Values $qmdParams

                # For each requested output format, render a report
                foreach ($format in $renderFormats) {
                    $fileName = "${timestamp}_NeoIPC-Surveillance-Partner-Report_${siteCode}.${locale}.${format}"

                    # QUARTO requires the -o value to be filename-only (no path component). Use GetFileName just to be safe.
                    $outFileForQuarto = [System.IO.Path]::GetFileName($fileName)

                    # Prepare log entry for this run/format
                    $currentEntry = [ordered]@{
                        Site = $siteCode
                        Language = $lang
                        Format = $format
                        Timestamp = (Get-Date).ToString('o')
                        FileName = $fileName
                        Qmd = $qmdToUse
                        Params = $qmdParams
                        Messages = @()
                        Status = 'Planned'
                        ExitCode = $null
                    }

                    # Build Quarto argument list for this format
                    $quartoArgs = @('render', '--profile', $lang, $qmdToUse, '--to', $format, '-o', $outFileForQuarto)
                    if ($outputDirPath) {
                        $quartoArgs += '--output-dir'
                        $quartoArgs += $outputDirPath
                    }

                    # All parameters via -P (R reads params$, conditional
                    # blocks use cat() + when-meta="alwaysTrue" wrappers)
                    $quartoArgs += $paramPairs

                    # Render (or report) - respect WhatIf via ShouldProcess
                    $completedSteps++
                    $pct = if ($totalSteps -gt 0) { [int](100 * $completedSteps / $totalSteps) } else { 0 }
                    Write-Progress -Activity 'Partner Report Build' -Status "Rendering $format for $siteCode ($lang)" -PercentComplete $pct

                    $target = "$fileName for site $siteCode (lang: $lang, format: $format)"
                    $currentMessages = New-Object System.Collections.Generic.List[string]
                    if ($PSCmdlet.ShouldProcess($target, "Render Partner Report")) {
                        # Execute the render and collect messages
                        $skipRest = $false
                        $errorLine = ''
                        $isError = $false

                        # Debug: show full Quarto command as it will be executed (args with spaces quoted)
                        $quartoArgsQuoted = $quartoArgs | ForEach-Object {
                            if ($_ -match '\s') { '"' + ($_.ToString().Replace('"', '\"')) + '"' } else { $_.ToString() }
                        }
                        Write-Debug "Quarto command: quarto $($quartoArgsQuoted -join ' ')"

                        & quarto @quartoArgs 2>&1 | ForEach-Object -Process {
                            if ($skipRest) { return }
                            $s = "$_"
                            if ($s -eq 'System.Management.Automation.RemoteException') { $s = '' }

                            $currentMessages.Add($s) | Out-Null

                            if ($isError) {
                                if ($s -eq '! No problem detected') {
                                    Write-Host "No problem detected." -ForegroundColor DarkYellow
                                    $skipRest = $true
                                }
                                else {
                                    if ($errorLine.Length -gt 0) { Write-Error -Message $errorLine; $errorLine = '' }
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

                        # Record exit status
                        $currentEntry.ExitCode = $LASTEXITCODE
                        $currentEntry.Messages += $currentMessages

                        if (-not $skipRest -and -not $isError -and $LASTEXITCODE -eq 0) {
                            Write-Host "done." -ForegroundColor Green
                            $currentEntry.Status = 'Success'
                            $outPath = if ($outputDirPath) { Join-Path $outputDirPath $fileName } else { Join-Path $reportDirPath '_output' $fileName }
                            $outputFiles += $outPath
                        }
                        elseif ($LASTEXITCODE -ne 0 -or $isError) {
                            $errMsg = "Quarto returned exit code $LASTEXITCODE for site $siteCode (lang: $lang, format: $format)."
                            Write-Error $errMsg
                            $errors += $errMsg
                            $currentEntry.Status = 'Error'
                            if ($LASTEXITCODE -ne 0) { $currentEntry.Messages += "Quarto exit code $LASTEXITCODE" }
                        }
                    }
                    else {
                        # WhatIf / dry-run: report planned action
                        Write-Host "WhatIf: would render $target" -ForegroundColor DarkYellow
                        $currentEntry.Status = 'Planned'
                        $currentEntry.Messages += "WhatIf: would render $target"
                        $currentEntry.Messages += "Params: $(ConvertTo-Json -Depth 3 $qmdParams | Out-String)"
                    }

                    # Add current entry to aggregated log
                    $buildLog += (New-Object PSObject -Property $currentEntry)
                }
            }
        }
    }


    $buildCompleted = $true
}
catch {
    $errors += $_.Exception.Message
}
finally {
    Set-Location -LiteralPath $wd

    Write-Progress -Activity 'Partner Report Build' -Completed

    $buildReportDirPath = if ($outputDirPath) { $outputDirPath } else { Join-Path $reportDirPath '_output' }
    $buildReportFilePath = Join-Path $buildReportDirPath "${scriptTimestamp}_NeoIPC-Surveillance-Partner-Report-Build.json"
    $extraFields = [ordered]@{
        scriptTimestamp = $scriptTimestamp
        outputDirPath = $buildReportDirPath
        siteCodes = $siteCodes
        outputLocales = $OutputLocales
        outputFormats = $OutputFormats
        buildSteps = $buildLog
    }
    $reportPath = if ($JsonReport) { $buildReportFilePath } else { $null }
    $status = Write-NeoipcBuildReport -Name 'Partner Report Build' `
        -Errors $errors -OutputFiles $outputFiles -BuildCompleted $buildCompleted `
        -StartedAt $startedAt -BuildReportPath $reportPath -ExtraFields $extraFields

    if ($status -ne 'success') {
        exit 1
    }
}

} # end Invoke-WithNeoipcAuth
