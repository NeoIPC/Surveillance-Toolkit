<#
.SYNOPSIS
Batch-generate Partner Reports for one or more sites and languages.

.DESCRIPTION
This script fetches the department/site list from DHIS2, filters by a regex, and renders the Partner Report for each site and language using Quarto.
It requires a DHIS2 API token provided as the -Token parameter or via the NEOIPC_DHIS2_TOKEN environment variable (token can be a raw token or a file path containing the token).

.NOTES
- Cleans Quarto temporary files before each render to avoid cross-iteration contamination.
- Streams and parses Quarto output to detect and report errors and warnings.

.EXAMPLE
.
    .\New-PartnerReports.ps1 -SiteCodeFilter 'NEO_.*' -Language @('en','de') -OutputDir 'C:\tmp\partner-reports' -ReferenceDataFile '2026-01-28_124237Z.Reference-Report.json' -IncludeNonCorePatients -Verbose
#>
[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Low')]
param(
    [ArgumentCompleter({
        param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
        $cacheFile = Join-Path $PSScriptRoot '..' 'data' 'local' 'site-codes.txt'
        if (Test-Path -LiteralPath $cacheFile) {
            Get-Content -LiteralPath $cacheFile |
                Where-Object { $_ -like "$wordToComplete*" } |
                Sort-Object
        }
    })]
    [Parameter(Position=0)]
    [string]
    $SiteCodeFilter = '.+',

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
    $Language = @('en'),

    [Parameter(Position=2)]
    [string]
    $Token = $null,

    [Parameter(Position=3)]
    [string]
    $OutputDir = $null,

    [Parameter(Position=4)]
    [string]
    $ReferenceDataFile = $null,

    [Parameter()]
    [Nullable[System.DateOnly]]
    $ReportingPeriodFrom = $null,

    [Parameter()]
    [Nullable[System.DateOnly]]
    $ReportingPeriodTo = $null,

    [Parameter()]
    [Nullable[int]]
    $BirthWeightFrom = $null,

    [Parameter()]
    [Nullable[int]]
    $BirthWeightTo = $null,

    [Parameter()]
    [Nullable[int]]
    $GestationWeeksFrom = $null,

    [Parameter()]
    [Nullable[int]]
    $GestationWeeksTo = $null,

    [Parameter()]
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

try {
    Set-Location -LiteralPath $partnerReportDir

    # Resolve auth (throws if missing)
    $auth = Resolve-NeoipcAuth -Token $Token

    # Fetch departments
    $sites = Get-NeoipcDepartments -Auth $auth -SiteCodeFilter $SiteCodeFilter

    if (-not $sites -or $sites.Count -eq 0) {
        Write-Warning "No sites matched filter '$SiteCodeFilter'. Nothing to do.";
        return
    }

    # Save current auth env vars, clear them, then set only the resolved ones
    # so that R/Quarto child processes pick up credentials via neoipcr's get_auth_data()
    $originalEnv = @{}
    foreach ($name in @(
        'NEOIPC_DHIS2_TOKEN',
        'NEOIPC_DHIS2_USER',
        'NEOIPC_DHIS2_PASSWORD',
        'NEOIPC_DHIS2_SESSION_ID'
    )) {
        $originalEnv[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }
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

    # Resolve OutputDir if provided
    $resolvedOutputDir = $null
    if ($OutputDir) {
        $resolvedOutputDir = Resolve-Path -LiteralPath $OutputDir -ErrorAction SilentlyContinue
        if (-not $resolvedOutputDir) {
            New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
            $resolvedOutputDir = Resolve-Path -LiteralPath $OutputDir
        }
        $resolvedOutputDir = $resolvedOutputDir.Path
    }

    # Prepare aggregated build log
    $buildLog = @()
    $runTimestamp = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')

    # Check Quarto once before iterating (time-consuming; no need to repeat)
    try {
        Test-QuartoInstallation
    }
    catch {
        throw "Quarto checks failed: $($_.Exception.Message)"
    }

    # Loop by language and site
    foreach ($lang in $Language) {
        $qmdToUse = Resolve-NeoipcLocaleQmd -ReportDir $partnerReportDir -BaseName 'Partner-Report' -Language $lang

        foreach ($site in $sites) {
            Write-Host "Generating partner report for $site (lang: $lang)..."

            # Build file name and paths
            $timestamp = [datetime]::Now.ToString('yyyy-MM-dd_HHmmss')
            $fileName = "${timestamp}_NeoIPC-Surveillance-Partner-Report_${site}.${lang}.pdf"

            # QUARTO requires the -o value to be filename-only (no path component).
            $outFileForQuarto = [System.IO.Path]::GetFileName($fileName)
            if ([string]::IsNullOrWhiteSpace($outFileForQuarto)) {
                throw "Computed output filename for Quarto is invalid: '$fileName'"
            }
            if ($outFileForQuarto -ne $fileName) {
                Write-Verbose "Normalized output name to filename-only: '$outFileForQuarto' (original: '$fileName')"
            }

            # Build -P parameter list (only supported QMD params)
            $qmdParams = @{}

            # UnitCodes must receive the current site code
            $qmdParams['unitCodes'] = $site
            if ($resolvedReferenceDataFile) { $qmdParams['referenceDataFile'] = $resolvedReferenceDataFile }
            if ($ReportingPeriodFrom -ne $null) { $qmdParams['reportingPeriodFrom'] = $ReportingPeriodFrom.ToString('yyyy-MM-dd') }
            if ($ReportingPeriodTo -ne $null) { $qmdParams['reportingPeriodTo'] = $ReportingPeriodTo.ToString('yyyy-MM-dd') }
            if ($BirthWeightFrom -ne $null) { $qmdParams['birthWeightFrom'] = $BirthWeightFrom.Value }
            if ($BirthWeightTo -ne $null) { $qmdParams['birthWeightTo'] = $BirthWeightTo.Value }
            if ($GestationWeeksFrom -ne $null) { $qmdParams['gestationWeeksFrom'] = $GestationWeeksFrom.Value }
            if ($GestationWeeksTo -ne $null) { $qmdParams['gestationWeeksTo'] = $GestationWeeksTo.Value }
            if ($IncludeNonCorePatients.IsPresent) { $qmdParams['includeNonCorePatients'] = 'true' }
            if ($HideIntroductionTexts.IsPresent) { $qmdParams['includeIntroductionTexts'] = 'false' }
            if ($HideOutlierInterpretation.IsPresent) { $qmdParams['includeOutlierInterpretation'] = 'false' }

            # Convert user-friendly element names to Quarto boolean parameters
            foreach ($mapping in $elementMapping.GetEnumerator()) {
                $includeValue = $IncludeElements -contains $mapping.Key
                $qmdParams[$mapping.Value] = if ($includeValue) { 'true' } else { 'false' }
            }

            $paramPairs = Build-QmdParamPairs -Values $qmdParams

            # For each requested output format, render a report
            foreach ($format in $Formats) {
                # Perform cleanup once per site (respecting WhatIf)
                # if ($PSCmdlet.ShouldProcess($partnerReportDir, "Clean Quarto temp files")) {
                #     Clean-QuartoTemp -BaseDir $partnerReportDir
                #     $cleanupMessage = "Cleaned Quarto temp files"
                # }
                # else {
                #     $cleanupMessage = "WhatIf: would clean Quarto temp files in $partnerReportDir"
                # }
                $fileName = "${timestamp}_NeoIPC-Surveillance-Partner-Report_${site}.${lang}.${format}"

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
                    Messages = @($cleanupMessage)
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
                    }
                    elseif ($LASTEXITCODE -ne 0 -or $isError) {
                        Write-Error "Quarto returned exit code $LASTEXITCODE for site $site (lang: $lang, format: $format)."
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

    # Write JSON report if requested
    if ($JsonReport) {
        $jsonTimestamp = [datetime]::Now.ToString('yyyy-MM-dd_HHmmss')
        if ($resolvedOutputDir) { $jsonPath = Join-Path $resolvedOutputDir "partner-report-build_$jsonTimestamp.json" }
        else { $jsonPath = Join-Path $partnerReportDir '_output' "partner-report-build_$jsonTimestamp.json" }
        try {
            $buildLog | ConvertTo-Json -Depth 5 | Out-File -FilePath $jsonPath -Encoding utf8
            Write-Host "Wrote JSON build report to $jsonPath" -ForegroundColor Green
        }
        catch {
            Write-Warning "Failed to write JSON build report to $($jsonPath): $($_.Exception.Message)"
        }
    }
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
}
