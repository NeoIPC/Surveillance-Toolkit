[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'Acquire')]
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$Signatory,
    [Parameter(Mandatory, Position = 1)]
    [System.IO.DirectoryInfo]$SignatureImagePath,
    [ArgumentCompleter({
        param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
        Import-Module (Join-Path $PSScriptRoot 'modules' 'NeoIPC-Tools') -Force -Verbose:$false
        $serverKey = Get-NeoIPCServerKey `
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
    [Parameter(Mandatory, Position = 2, ParameterSetName = 'Acquire')]
    [string[]]$DepartmentCode,
    [Parameter(Mandatory, Position = 2, ParameterSetName = 'Pass')]
    [int]$StartYear,
    [Parameter(Mandatory, Position = 3, ParameterSetName = 'Pass')]
    [int]$EndYear,
    [Parameter(Mandatory, Position = 4, ParameterSetName = 'Pass')]
    [int]$NumberOfPatients,
    [Parameter(Mandatory, Position = 5, ParameterSetName = 'Pass')]
    [string]$HospitalName,
    [ArgumentCompleter({
        param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
        @(
            Get-ChildItem -LiteralPath "$PSScriptRoot/../reports/Partner-Certificate/" -File -Filter 'Partner-Certificate.*.qmd' |
            Select-Object -ExpandProperty Name |
            ForEach-Object { if($_ -match 'Partner-Certificate\.(.+)\.qmd') { $Matches[1] } }) + 'en' |
            Where-Object { $_ -like "$wordToComplete*" } |
            Sort-Object
     })]
    [Parameter(Position = 3, ParameterSetName = 'Acquire')]
    [Parameter(Position = 6, ParameterSetName = 'Pass')]
    [string]$OutputLocale = 'en',
    [Parameter(Position = 4, ParameterSetName = 'Acquire')]
    [Parameter(Position = 7, ParameterSetName = 'Pass')]
    [string]$Token,

    [Parameter()]
    [switch]$JsonReport,

    [Parameter()]
    [string]$OutputDir = $null,

    [Parameter()]
    [string]$Dhis2Scheme = $null,

    [Parameter()]
    [string]$Dhis2Hostname = $null,

    [Parameter()]
    [Nullable[int]]$Dhis2Port = $null,

    [Parameter()]
    [string]$Dhis2Path = $null
)

Import-Module (Join-Path $PSScriptRoot 'modules' 'NeoIPC-Tools') -Force -Verbose:$false
$auth = Resolve-NeoIPCAuth -Token $Token

$currentDir = Get-Location
$reportDirPath = Resolve-Path -LiteralPath "$PSScriptRoot/../reports/Partner-Certificate/"

# Resolve OutputDir BEFORE changing directory (it's relative to the caller's CWD)
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
    $outputDirExplicit = $true
} else {
    $outputDirPath = Join-Path $reportDirPath '_output'
    $outputDirExplicit = $false
}

$localeParts = Split-NeoIPCLocale -Locale $OutputLocale
$quartoFile = Resolve-NeoIPCLocaleQmd -ReportDir $reportDirPath -BaseName 'Partner-Certificate' -Locale $OutputLocale
$SignatureImagePath = Resolve-Path -LiteralPath $SignatureImagePath.FullName -Relative -RelativeBasePath $reportDirPath

Invoke-WithNeoIPCAuth -Auth $auth -ExtraEnvVars @{ 'LC_ALL' = $null } -ScriptBlock {

$errors = @()
$outputFiles = @()
$buildCompleted = $false
$startedAt = (Get-Date -AsUTC).ToString('o')
$scriptTimestamp = [datetime]::UtcNow.ToString("yyyy-MM-dd_HHmmss'Z'")

try {
    Set-Location -LiteralPath $reportDirPath

    if ($localeParts.Territory) {
        $env:LC_ALL = "${OutputLocale}.UTF-8"
    } else {
        [Environment]::SetEnvironmentVariable('LC_ALL', $null, 'Process')
    }

    if ($DepartmentCode) {
        $deptArgs = @{ Auth = $auth }
        if ($Dhis2Scheme) { $deptArgs.Scheme = $Dhis2Scheme }
        if ($Dhis2Hostname) { $deptArgs.Hostname = $Dhis2Hostname }
        if ($Dhis2Port) { $deptArgs.Port = $Dhis2Port }
        if ($Dhis2Path) { $deptArgs.Path = $Dhis2Path }
        $allSiteCodes = Get-NeoIPCDepartments @deptArgs

        $siteCodes = $allSiteCodes | Where-Object -FilterScript { foreach ($d in $DepartmentCode) { if ($_ -match $d) { return $true } } } | Sort-Object

        $totalSteps = $siteCodes.Count
        $completedSteps = 0

        foreach ($siteCode in $siteCodes) {
            $completedSteps++
            $pct = if ($totalSteps -gt 0) { [int](100 * $completedSteps / $totalSteps) } else { 0 }
            Write-Progress -Activity 'Partner-Certificate Build' -Status "Rendering certificate for $siteCode" -PercentComplete $pct

            $outFile = "$([datetime]::Now.ToString('yyyy-MM-dd_HHmmss'))_NeoIPC-Surveillance-Partner-Certificate_${siteCode}.${OutputLocale}.pdf"
            $quartoArgs = @('render', $quartoFile, '-P', "signatory:$Signatory", '-P', "signatureImagePath:$SignatureImagePath", '-P', "departmentCode:$siteCode", '-o', $outFile)
            if ($outputDirExplicit) { $quartoArgs += @('--output-dir', $outputDirPath) }
            if ($Dhis2Scheme) { $quartoArgs += @('-P', "dhis2Scheme:$Dhis2Scheme") }
            if ($Dhis2Hostname) { $quartoArgs += @('-P', "dhis2Hostname:$Dhis2Hostname") }
            if ($Dhis2Port) { $quartoArgs += @('-P', "dhis2Port:$Dhis2Port") }
            if ($Dhis2Path) { $quartoArgs += @('-P', "dhis2Path:$Dhis2Path") }

            if ($PSCmdlet.ShouldProcess($outFile, "Render partner certificate for $siteCode")) {
                Write-Host "Generating partner certificate for $siteCode..."
                $result = Invoke-QuartoRender -Arguments $quartoArgs -Description "partner certificate for $siteCode"
                if ($result.Status -eq 'Error') {
                    $errors += "Quarto render failed for $siteCode (exit code $($result.ExitCode))."
                } else {
                    $outputFiles += (Join-Path $outputDirPath $outFile)
                }
            }
        }
    } else {
        $totalSteps = 1
        $completedSteps = 1
        Write-Progress -Activity 'Partner-Certificate Build' -Status "Rendering certificate for $HospitalName" -PercentComplete 100

        $outFile = "$([datetime]::Now.ToString('yyyy-MM-dd_HHmmss'))_NeoIPC-Surveillance-Partner-Certificate_${HospitalName}.${OutputLocale}.pdf"
        $quartoArgs = @('render', $quartoFile, '-P', "signatory:$Signatory", '-P', "signatureImagePath:$SignatureImagePath", '-P', "startYear:$StartYear", '-P', "endYear:$EndYear", '-P', "nPatients:$NumberOfPatients", '-P', "hospitalName:$HospitalName", '-o', $outFile)
        if ($outputDirExplicit) { $quartoArgs += @('--output-dir', $outputDirPath) }
        if ($Dhis2Scheme) { $quartoArgs += @('-P', "dhis2Scheme:$Dhis2Scheme") }
        if ($Dhis2Hostname) { $quartoArgs += @('-P', "dhis2Hostname:$Dhis2Hostname") }
        if ($Dhis2Port) { $quartoArgs += @('-P', "dhis2Port:$Dhis2Port") }
        if ($Dhis2Path) { $quartoArgs += @('-P', "dhis2Path:$Dhis2Path") }

        if ($PSCmdlet.ShouldProcess($outFile, "Render partner certificate for $HospitalName")) {
            Write-Host "Generating partner certificate for $HospitalName..."
            $result = Invoke-QuartoRender -Arguments $quartoArgs -Description "partner certificate for $HospitalName"
            if ($result.Status -eq 'Error') {
                $errors += "Quarto render failed for $HospitalName (exit code $($result.ExitCode))."
            } else {
                $outputFiles += (Join-Path $outputDirPath $outFile)
            }
        }
    }

    $buildCompleted = $true
}
catch {
    $errors += $_.Exception.Message
}
finally {
    Set-Location -LiteralPath $currentDir

    Write-Progress -Activity 'Partner-Certificate Build' -Completed

    $buildReportFilePath = Join-Path $outputDirPath "${scriptTimestamp}_NeoIPC-Surveillance-Partner-Certificate-Build.json"
    $extraFields = [ordered]@{
        scriptTimestamp = $scriptTimestamp
        outputDirPath = $outputDirPath
        outputLocale = $OutputLocale
    }
    $reportPath = if ($JsonReport) { $buildReportFilePath } else { $null }
    $status = Write-NeoIPCBuildReport -Name 'Partner-Certificate Build' `
        -Errors $errors -OutputFiles $outputFiles -BuildCompleted $buildCompleted `
        -StartedAt $startedAt -BuildReportPath $reportPath -ExtraFields $extraFields

    if ($status -ne 'success') {
        exit 1
    }
}

} # end Invoke-WithNeoIPCAuth
