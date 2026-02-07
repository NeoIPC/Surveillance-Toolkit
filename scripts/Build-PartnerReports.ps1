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
    .\Build-PartnerReports.ps1 -SiteCodeFilter 'NEO_.*' -Language @('en','de') -OutputDir 'C:\tmp\partner-reports' -ReferenceDataFile '2026-01-28_124237Z.Reference-Report.json' -IncludeNonCorePatients -Verbose
#>
[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Low')]
param(
    [Parameter(Position=0)]
    [string]
    $SiteCodeFilter = '.+',

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

function Resolve-Token {
    param([string]$TokenParam)
    # Prefer explicit param, otherwise env var
    $tokenCandidate = $TokenParam
    if ([string]::IsNullOrWhiteSpace($tokenCandidate)) {
        $tokenCandidate = $env:NEOIPC_DHIS2_TOKEN
    }

    if (-not [string]::IsNullOrWhiteSpace($tokenCandidate)) {
        # If it's a path to a file, read the first non-empty line
        if (Test-Path -LiteralPath $tokenCandidate -PathType Leaf) {
            try {
                # Use .NET ReadAllText to correctly handle BOM and encodings
                $content = Get-Content -LiteralPath $tokenCandidate -Head 1 -Encoding UTF8 -ErrorAction Stop
                return $content
            }
            catch {
                throw "Token file '$tokenCandidate' could not be read: $($_.Exception.Message)"
            }
        }
        else {
            return $tokenCandidate
        }
    }
    throw 'No DHIS2 token provided. Set -Token <token-or-path> or environment variable NEOIPC_DHIS2_TOKEN.'
}

function Ensure-QuartoAvailable {
    # Run Quarto self-checks to ensure a functional installation and knitr support
    $errors = [System.Collections.Generic.List[string]]::new()

    try {
        $outInstall = & quarto check install 2>&1
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
        $outKnitr = & quarto check knitr 2>&1
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

function Build-QmdParamPairs {
    param(
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

    # Resolve token (throws if missing)
    $resolvedToken = Resolve-Token -TokenParam $Token

    # Fetch departments
    $deptsUrl = 'https://neoipc.charite.de/api/organisationUnitGroups.json?paging=false&filter=code:eq:NEO_DEPARTMENT&fields=organisationUnits%5Bcode%5D'
    try {
        $resp = Invoke-RestMethod -Method Get -Headers @{'Authorization' = "ApiToken $resolvedToken" } -Uri $deptsUrl -ErrorAction Stop
        $sites = if ($resp.organisationUnitGroups -and $resp.organisationUnitGroups[0].organisationUnits) { $resp.organisationUnitGroups[0].organisationUnits.code } else { @() }
        $sites = $sites | Where-Object { $_ -match $SiteCodeFilter } | Sort-Object
    }
    catch {
        throw "Failed to fetch department list from DHIS2: $($_.Exception.Message)"
    }

    if (-not $sites -or $sites.Count -eq 0) {
        Write-Warning "No sites matched filter '$SiteCodeFilter'. Nothing to do.";
        return
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
        Ensure-QuartoAvailable
    }
    catch {
        throw "Quarto checks failed: $($_.Exception.Message)"
    }

    # Loop by language and site
    foreach ($lang in $Language) {
        # Select QMD for language, fallback to default
        $qmdLang = Join-Path -Path $partnerReportDir -ChildPath "Partner-Report.$lang.qmd"
        $qmdDefault = Join-Path -Path $partnerReportDir -ChildPath 'Partner-Report.qmd'
        if (Test-Path -LiteralPath $qmdLang) {
            $qmdToUse = $qmdLang
        }
        elseif (Test-Path -LiteralPath $qmdDefault) {
            $qmdToUse = $qmdDefault
        }
        else {
            throw "No Partner-Report QMD found for language '$lang' or default. Expected '$qmdLang' or '$qmdDefault'."
        }

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
            $qmdParams['UnitCodes'] = $site
            if ($resolvedReferenceDataFile) { $qmdParams['ReferenceDataFile'] = $resolvedReferenceDataFile }
            if ($ReportingPeriodFrom -ne $null) { $qmdParams['ReportingPeriodFrom'] = $ReportingPeriodFrom.ToString('yyyy-MM-dd') }
            if ($ReportingPeriodTo -ne $null) { $qmdParams['ReportingPeriodTo'] = $ReportingPeriodTo.ToString('yyyy-MM-dd') }
            if ($BirthWeightFrom -ne $null) { $qmdParams['BirthWeightFrom'] = $BirthWeightFrom.Value }
            if ($BirthWeightTo -ne $null) { $qmdParams['BirthWeightTo'] = $BirthWeightTo.Value }
            if ($GestationWeeksFrom -ne $null) { $qmdParams['GestationWeeksFrom'] = $GestationWeeksFrom.Value }
            if ($GestationWeeksTo -ne $null) { $qmdParams['GestationWeeksTo'] = $GestationWeeksTo.Value }
            if ($IncludeNonCorePatients.IsPresent) { $qmdParams['IncludeNonCorePatients'] = 'true' }
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
}
