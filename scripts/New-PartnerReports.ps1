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
    .\New-PartnerReports.ps1 -SiteCodeFilter 'NEO_.*' -Locale @('en','de') -OutputDir 'C:\tmp\partner-reports' -ReferenceDataFile '2026-01-28_124237Z.Reference-Report.json' -IncludeNonCorePatients -Verbose

.EXAMPLE
.
    .\New-PartnerReports.ps1 -DataFile 'partner-data.json' -Locale @('en','de') -Formats pdf -OutputDir 'C:\tmp\partner-reports' -Verbose
#>
[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Low', DefaultParameterSetName='Online')]
param(
    [ArgumentCompleter({
        param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
        . "$PSScriptRoot/NeoipcReportHelpers.ps1"
        $serverKey = Get-NeoipcServerKey `
            -Scheme $fakeBoundParameters['Dhis2Scheme'] `
            -Hostname $fakeBoundParameters['Dhis2Hostname'] `
            -Port $fakeBoundParameters['Dhis2Port'] `
            -Path $fakeBoundParameters['Dhis2Path']
        $cacheFile = Join-Path $PSScriptRoot '..' 'data' 'local' $serverKey 'site-codes.txt'
        if (Test-Path -LiteralPath $cacheFile) {
            Get-Content -LiteralPath $cacheFile |
                Where-Object { $_ -like "$wordToComplete*" } |
                Sort-Object
        } else {
            $cacheBase = Join-Path $PSScriptRoot '..' 'data' 'local'
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
    $Locale = @('en'),

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

    [Parameter()]
    [switch]
    $HideIntroductionTexts,

    [Parameter()]
    [switch]
    $HideOutlierInterpretation,

    [Parameter()]
    [ValidateSet('pdf','html','docx','json')]
    [string[]]
    $Formats = @('pdf'),

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

    [Parameter()]
    [ValidateSet(
        'BirthWeightDistribution',
        'GestationalAgeDistribution',
        'IncidenceDensityRates',
        'DeviceAssociatedRates',
        'AgentPerInfectionRates',
        'AntibioticResistanceRates',
        'InfectiousAgentDetectionRates',
        'ResistanceTestRates',
        'RiskDensityRates',
        'SurgicalProcedureRates',
        'SecondaryBloodstreamInfectionRates'
    )]
    [string[]]$IncludeElements = @(
        'BirthWeightDistribution',
        'GestationalAgeDistribution',
        'IncidenceDensityRates',
        'DeviceAssociatedRates',
        'AgentPerInfectionRates',
        'AntibioticResistanceRates',
        'InfectiousAgentDetectionRates',
        'ResistanceTestRates',
        'RiskDensityRates',
        'SurgicalProcedureRates',
        'SecondaryBloodstreamInfectionRates'
    )
)

. "$PSScriptRoot/NeoipcReportHelpers.ps1"

# --- Runtime validation ---
$isDataFileMode = $PSCmdlet.ParameterSetName -eq 'DataFile'

if ($isDataFileMode -and ($Formats -contains 'json')) {
    throw "The 'json' format is not supported with -DataFile. The data file is already JSON."
}

# Separate json from Quarto-renderable formats
$wantsJson = $Formats -contains 'json'
$renderFormats = @($Formats | Where-Object { $_ -ne 'json' })

# Map user-friendly element names to internal Quarto parameter names
$elementMapping = @{
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

# --- Start script ---
$wd = Get-Location
$partnerReportDir = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..' 'reports' 'Partner-Report')

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
    $resolvedReferenceDataFile = Resolve-Path -LiteralPath $absoluteRefPath -Relative -RelativeBasePath $partnerReportDir
}

# Resolve DataFile if provided
$resolvedDataFile = $null
if ($DataFile) {
    $absoluteDataPath = Resolve-Path -LiteralPath $DataFile -ErrorAction SilentlyContinue
    if (-not $absoluteDataPath) {
        throw "Data file not found: $DataFile"
    }
    $absoluteDataPath = $absoluteDataPath.Path
    $resolvedDataFile = Resolve-Path -LiteralPath $absoluteDataPath -Relative -RelativeBasePath $partnerReportDir
}

# Resolve OutputDir BEFORE changing directory (it's relative to the caller's CWD)
$resolvedOutputDir = $null
if ($OutputDir) {
    $resolvedOutputDir = Resolve-Path -LiteralPath $OutputDir -ErrorAction SilentlyContinue
    if (-not $resolvedOutputDir) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
        $resolvedOutputDir = Resolve-Path -LiteralPath $OutputDir
    }
    $resolvedOutputDir = $resolvedOutputDir.Path
}

try {
    Set-Location -LiteralPath $partnerReportDir

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
        $sites = @($siteString -split ',')
        Write-Verbose "DataFile mode: rendering from $DataFile (sites: $($sites -join ', '))"
    } else {
        # Online mode: resolve auth and fetch departments
        $auth = Resolve-NeoipcAuth -Token $Token

        # Fetch departments
        $deptArgs = @{ Auth = $auth; SiteCodeFilter = $SiteCodeFilter }
        if ($Dhis2Scheme) { $deptArgs.Scheme = $Dhis2Scheme }
        if ($Dhis2Hostname) { $deptArgs.Hostname = $Dhis2Hostname }
        if ($Dhis2Port) { $deptArgs.Port = $Dhis2Port }
        if ($Dhis2Path) { $deptArgs.Path = $Dhis2Path }
        $sites = Get-NeoipcDepartments @deptArgs

        if (-not $sites -or $sites.Count -eq 0) {
            Write-Warning "No sites matched filter '$SiteCodeFilter'. Nothing to do.";
            return
        }
    }

    # Save current auth env vars, clear them, then set only the resolved ones
    # so that R/Quarto child processes pick up credentials via neoipcr's get_auth_data()
    $originalEnv = @{}
    foreach ($name in @(
        'NEOIPC_DHIS2_TOKEN',
        'NEOIPC_DHIS2_USER',
        'NEOIPC_DHIS2_PASSWORD',
        'NEOIPC_DHIS2_SESSION_ID',
        'LC_ALL'
    )) {
        $originalEnv[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }
    if (-not $isDataFileMode) {
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
    }

    # $resolvedOutputDir already resolved before Set-Location

    # Prepare build tracking (aligned with Reference Report build report structure)
    $errors = @()
    $outputFiles = @()
    $buildCompleted = $false
    $startedAt = (Get-Date -AsUTC).ToString('o')
    $scriptTimestamp = [datetime]::UtcNow.ToString("yyyy-MM-dd_HHmmss'Z'")
    $buildLog = @()
    $totalSteps = 0
    $completedSteps = 0
    if ($wantsJson -and -not $isDataFileMode) { $totalSteps += $sites.Count }
    if ($renderFormats.Count -gt 0) { $totalSteps += ($sites.Count * $Locale.Count * $renderFormats.Count) }

    # --- JSON data generation (Online mode only) ---
    if ($wantsJson -and -not $isDataFileMode) {
        $rscriptCmd = Get-Command -Name Rscript -ErrorAction SilentlyContinue
        if (-not $rscriptCmd) {
            throw 'Rscript not found in PATH.'
        }

        foreach ($site in $sites) {
            $jsonTimestamp = [datetime]::Now.ToString('yyyy-MM-dd_HHmmss')
            $jsonFileName = "${jsonTimestamp}_NeoIPC-Surveillance-Partner-Data_${site}.json"
            $jsonOutPath = if ($resolvedOutputDir) {
                Join-Path $resolvedOutputDir $jsonFileName
            } else {
                Join-Path $partnerReportDir '_output' $jsonFileName
            }

            $currentEntry = [ordered]@{
                Site = $site
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
            Write-Progress -Activity 'Partner Report Build' -Status "Generating JSON for $site" -PercentComplete $pct

            if ($PSCmdlet.ShouldProcess($jsonOutPath, "Generate partner data JSON for $site")) {
                Write-Host "Generating partner data JSON for $site..."
                $rArgs = @('--vanilla', (Join-Path $partnerReportDir 'Generate-PartnerData.R'),
                           '--file', $jsonOutPath, '--unitCodes', $site)
                if ($resolvedReferenceDataFile) {
                    # Resolve to absolute path for R script (it doesn't run from partnerReportDir)
                    $absRefForR = Join-Path $partnerReportDir $resolvedReferenceDataFile
                    $rArgs += @('--referenceDataFile', $absRefForR)
                }
                if ($ReportingPeriodFrom -ne $null) { $rArgs += @('--reportingPeriodFrom', $ReportingPeriodFrom.ToString('yyyy-MM-dd')) }
                if ($ReportingPeriodTo -ne $null) { $rArgs += @('--reportingPeriodTo', $ReportingPeriodTo.ToString('yyyy-MM-dd')) }
                if ($BirthWeightFrom -ne $null) { $rArgs += @('--birthWeightFrom', $BirthWeightFrom.Value) }
                if ($BirthWeightTo -ne $null) { $rArgs += @('--birthWeightTo', $BirthWeightTo.Value) }
                if ($GestationWeeksFrom -ne $null) { $rArgs += @('--gestationWeeksFrom', $GestationWeeksFrom.Value) }
                if ($GestationWeeksTo -ne $null) { $rArgs += @('--gestationWeeksTo', $GestationWeeksTo.Value) }
                if ($IncludeNonCorePatients.IsPresent) { $rArgs += '--includeNonCorePatients' }
                if ($Dhis2Scheme) { $rArgs += @('--scheme', $Dhis2Scheme) }
                if ($Dhis2Hostname) { $rArgs += @('--host', $Dhis2Hostname) }
                if ($Dhis2Port) { $rArgs += @('--port', $Dhis2Port) }
                if ($Dhis2Path) { $rArgs += @('--path', $Dhis2Path) }

                $rResult = Invoke-Rscript -Arguments $rArgs -Command $rscriptCmd -Description "Generate-PartnerData.R ($site)"

                $currentEntry.ExitCode = $rResult.ExitCode
                $currentEntry.Messages = $rResult.Messages
                if ($rResult.Status -eq 'Success') {
                    Write-Host "done." -ForegroundColor Green
                    $currentEntry.Status = 'Success'
                    $outputFiles += $jsonOutPath
                } else {
                    $errMsg = "Generate-PartnerData.R failed (exit code $($rResult.ExitCode)) for site $site."
                    Write-Error $errMsg
                    $errors += $errMsg
                    $currentEntry.Status = 'Error'
                }
            } else {
                $currentEntry.Status = 'Planned'
                $currentEntry.Messages += "WhatIf: would generate partner data JSON for $site"
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
        foreach ($loc in $Locale) {
            $localeParts = Split-NeoipcLocale -Locale $loc
            $lang = $localeParts.Language
            $qmdToUse = Resolve-NeoipcLocaleQmd -ReportDir $partnerReportDir -BaseName 'Partner-Report' -Locale $loc

            # Set LC_ALL so R picks up the full locale (territory-specific resources)
            if ($localeParts.Territory) {
                $env:LC_ALL = "${loc}.UTF-8"
            } else {
                [Environment]::SetEnvironmentVariable('LC_ALL', $null, 'Process')
            }

            foreach ($site in $sites) {
                Write-Host "Generating partner report for $site (locale: $loc)..."

                # Build file name and paths
                $timestamp = [datetime]::Now.ToString('yyyy-MM-dd_HHmmss')

                # Build -P parameter list (only supported QMD params)
                $qmdParams = @{}

                $qmdParams['unitCodes'] = $site

                if ($isDataFileMode) {
                    # DataFile mode: pass data file to QMD
                    $qmdParams['partnerDataFile'] = $resolvedDataFile
                } else {
                    # Online mode: pass data params
                    if ($ReportingPeriodFrom -ne $null) { $qmdParams['reportingPeriodFrom'] = $ReportingPeriodFrom.ToString('yyyy-MM-dd') }
                    if ($ReportingPeriodTo -ne $null) { $qmdParams['reportingPeriodTo'] = $ReportingPeriodTo.ToString('yyyy-MM-dd') }
                    if ($BirthWeightFrom -ne $null) { $qmdParams['birthWeightFrom'] = $BirthWeightFrom.Value }
                    if ($BirthWeightTo -ne $null) { $qmdParams['birthWeightTo'] = $BirthWeightTo.Value }
                    if ($GestationWeeksFrom -ne $null) { $qmdParams['gestationWeeksFrom'] = $GestationWeeksFrom.Value }
                    if ($GestationWeeksTo -ne $null) { $qmdParams['gestationWeeksTo'] = $GestationWeeksTo.Value }
                    if ($IncludeNonCorePatients.IsPresent) { $qmdParams['includeNonCorePatients'] = 'true' }
                    if ($Dhis2Scheme) { $qmdParams['dhis2Scheme'] = $Dhis2Scheme }
                    if ($Dhis2Hostname) { $qmdParams['dhis2Hostname'] = $Dhis2Hostname }
                    if ($Dhis2Port) { $qmdParams['dhis2Port'] = $Dhis2Port }
                    if ($Dhis2Path) { $qmdParams['dhis2Path'] = $Dhis2Path }
                }

                if ($resolvedReferenceDataFile) { $qmdParams['referenceDataFile'] = $resolvedReferenceDataFile }
                if ($HideIntroductionTexts.IsPresent) { $qmdParams['includeIntroductionTexts'] = 'false' }
                if ($HideOutlierInterpretation.IsPresent) { $qmdParams['includeOutlierInterpretation'] = 'false' }

                # Convert user-friendly element names to Quarto boolean parameters
                foreach ($mapping in $elementMapping.GetEnumerator()) {
                    $includeValue = $IncludeElements -contains $mapping.Key
                    $qmdParams[$mapping.Value] = if ($includeValue) { 'true' } else { 'false' }
                }

                $paramPairs = Build-QmdParamPairs -Values $qmdParams

                # For each requested output format, render a report
                foreach ($format in $renderFormats) {
                    $fileName = "${timestamp}_NeoIPC-Surveillance-Partner-Report_${site}.${loc}.${format}"

                    # QUARTO requires the -o value to be filename-only (no path component). Use GetFileName just to be safe.
                    $outFileForQuarto = [System.IO.Path]::GetFileName($fileName)

                    # Prepare log entry for this run/format
                    $currentEntry = [ordered]@{
                        Site = $site
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
                    if ($resolvedOutputDir) {
                        $quartoArgs += '--output-dir'
                        $quartoArgs += $resolvedOutputDir
                    }

                    $metadataParameters = @(
                        'includeIntroductionTexts'
                        'includeOutlierInterpretation'
                        'includeBirthWeightFigure'
                        'includeGestationalAgeFigure'
                        'includeIncidenceDensityTable'
                        'includeDeviceAssociatedIncidenceDensityTable'
                        'includeAgentPerInfectionRateTable'
                        'includeInfectiousAgentDetectionRateTable'
                        'includeRiskDensityRateTable'
                        'includeSurgicalProcedureRateTable'
                        'includeResistantPathogenInfectionRateTable'
                        'includeAntibioticResistanceTestRateTable'
                        'includeSecondaryBsiRateTable'
                    )
                    # Add parameters - use -M for include* metadata, -P for others
                    foreach ($pair in $paramPairs) {
                        if ($pair -eq '-P') {
                            $quartoArgs += $pair
                        } elseif ($pair -match ':' -and ($pair -split ':')[0] -iin $metadataParameters) {
                            # Replace last -P with -M for include flags
                            $quartoArgs[$quartoArgs.Count - 1] = '-M'
                            $quartoArgs += $pair
                        } else {
                            $quartoArgs += $pair
                        }
                    }

                    # Render (or report) - respect WhatIf via ShouldProcess
                    $completedSteps++
                    $pct = if ($totalSteps -gt 0) { [int](100 * $completedSteps / $totalSteps) } else { 0 }
                    Write-Progress -Activity 'Partner Report Build' -Status "Rendering $format for $site ($lang)" -PercentComplete $pct

                    $target = "$fileName for site $site (lang: $lang, format: $format)"
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
                            $outPath = if ($resolvedOutputDir) { Join-Path $resolvedOutputDir $fileName } else { Join-Path $partnerReportDir '_output' $fileName }
                            $outputFiles += $outPath
                        }
                        elseif ($LASTEXITCODE -ne 0 -or $isError) {
                            $errMsg = "Quarto returned exit code $LASTEXITCODE for site $site (lang: $lang, format: $format)."
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
    foreach ($name in $originalEnv.Keys) {
        $originalValue = $originalEnv[$name]
        if ($null -eq $originalValue) {
            [Environment]::SetEnvironmentVariable($name, $null, 'Process')
        } else {
            [Environment]::SetEnvironmentVariable($name, $originalValue, 'Process')
        }
    }

    Write-Progress -Activity 'Partner Report Build' -Completed

    $buildReportDir = if ($resolvedOutputDir) { $resolvedOutputDir } else { Join-Path $partnerReportDir '_output' }
    $buildReportPath = Join-Path $buildReportDir "${scriptTimestamp}_NeoIPC-Surveillance-Partner-Report-Build.json"
    $extraFields = [ordered]@{
        timestamp = $scriptTimestamp
        outputDir = $buildReportDir
        sites = $sites
        locales = $Locale
        formats = $Formats
        steps = $buildLog
    }
    $reportPath = if ($JsonReport) { $buildReportPath } else { $null }
    $status = Write-NeoipcBuildReport -Name 'Partner Report Build' `
        -Errors $errors -OutputFiles $outputFiles -BuildCompleted $buildCompleted `
        -StartedAt $startedAt -BuildReportPath $reportPath -ExtraFields $extraFields

    if ($status -ne 'success') {
        exit 1
    }
}
