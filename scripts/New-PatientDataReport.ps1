[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'Render')]
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$PatientId,

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
    [Parameter(Mandatory, Position = 1)]
    [string]$DepartmentCode,

    [ValidateSet('pdf', 'html', 'json')]
    [Parameter(Position = 2)]
    [string]$Format = 'pdf',

    [ArgumentCompleter({
        param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
        @(
            Get-ChildItem -LiteralPath "$PSScriptRoot/../reports/Patient-Data-Report/" -File -Filter 'Patient-Data-Report.*.qmd' |
            Select-Object -ExpandProperty Name |
            ForEach-Object { if($_ -match 'Patient-Data-Report\.(.+)\.qmd') { $Matches[1] } }) + 'en' |
            Where-Object { $_ -like "$wordToComplete*" } |
            Sort-Object
    })]
    [Parameter(Position = 3)]
    [string]$Locale = 'en',

    [Parameter()]
    [string]$Token,

    [Parameter()]
    [switch]$JsonReport,

    [Parameter()]
    [string]$Dhis2Scheme = $null,

    [Parameter()]
    [string]$Dhis2Hostname = $null,

    [Parameter()]
    [Nullable[int]]$Dhis2Port = $null,

    [Parameter()]
    [string]$Dhis2Path = $null
)

. "$PSScriptRoot/NeoipcReportHelpers.ps1"
$auth = Resolve-NeoipcAuth -Token $Token

$currentDir = Get-Location
$reportDir = Resolve-Path -LiteralPath "$PSScriptRoot/../reports/Patient-Data-Report/"
$outputDirPath = Join-Path $reportDir '_output'

$originalEnv = @{}
foreach ($name in @('NEOIPC_DHIS2_TOKEN', 'NEOIPC_DHIS2_USER', 'NEOIPC_DHIS2_PASSWORD', 'NEOIPC_DHIS2_SESSION_ID', 'LC_ALL')) {
    $originalEnv[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
foreach ($name in @('NEOIPC_DHIS2_TOKEN', 'NEOIPC_DHIS2_USER', 'NEOIPC_DHIS2_PASSWORD', 'NEOIPC_DHIS2_SESSION_ID')) {
    [Environment]::SetEnvironmentVariable($name, $null, 'Process')
}
if ($auth.AuthType -eq 'Token') {
    $env:NEOIPC_DHIS2_TOKEN = $auth.Token
} elseif ($auth.AuthType -eq 'Basic') {
    $env:NEOIPC_DHIS2_USER = $auth.Username
    $env:NEOIPC_DHIS2_PASSWORD = Get-NeoipcAuthPassword -Auth $auth
}

$errors = @()
$outputFiles = @()
$buildCompleted = $false
$startedAt = (Get-Date -AsUTC).ToString('o')
$scriptTimestamp = [datetime]::UtcNow.ToString("yyyy-MM-dd_HHmmss'Z'")

try {
    Set-Location -LiteralPath $reportDir

    Write-Progress -Activity 'Patient Data Report Build' -Status "Generating $Format for $PatientId" -PercentComplete 50

    $localeParts = Split-NeoipcLocale -Locale $Locale

    if ($localeParts.Territory) {
        $env:LC_ALL = "${Locale}.UTF-8"
    } else {
        [Environment]::SetEnvironmentVariable('LC_ALL', $null, 'Process')
    }

    if ($Format -eq 'json') {
        $outFile = "${scriptTimestamp}_NeoIPC-Surveillance-Patient-Data-Report_${PatientId}.json"

        if ($PSCmdlet.ShouldProcess($outFile, "Generate patient data JSON for $PatientId")) {
            Write-Host "Generating patient data JSON for $PatientId..."
            $rArgs = @('--vanilla', 'Generate-PatientData.R',
                '--patient-id', $PatientId,
                '--department', $DepartmentCode,
                '--output', $outFile)
            if ($Dhis2Scheme) { $rArgs += @('--scheme', $Dhis2Scheme) }
            if ($Dhis2Hostname) { $rArgs += @('--host', $Dhis2Hostname) }
            if ($Dhis2Port) { $rArgs += @('--port', $Dhis2Port) }
            if ($Dhis2Path) { $rArgs += @('--path', $Dhis2Path) }
            $rResult = Invoke-Rscript -Arguments $rArgs -Description "Generate-PatientData.R"
            if ($rResult.Status -eq 'Error') {
                $errors += "Generate-PatientData.R failed (exit code $($rResult.ExitCode))."
            } else {
                $outputFiles += (Join-Path $outputDirPath $outFile)
            }
        }
    } else {
        $quartoFile = Resolve-NeoipcLocaleQmd -ReportDir $reportDir -BaseName 'Patient-Data-Report' -Locale $Locale
        $outFile = "${scriptTimestamp}_NeoIPC-Surveillance-Patient-Data-Report_${PatientId}.${Locale}.${Format}"

        if ($PSCmdlet.ShouldProcess($outFile, "Render patient data report for $PatientId")) {
            Write-Host "Generating patient data report ($Format) for $PatientId..."
            $quartoArgs = @('render', $quartoFile,
                '--profile', $localeParts.Language,
                '--to', $Format,
                '-P', "patientId:$PatientId",
                '-P', "departmentCode:$DepartmentCode",
                '-o', $outFile)
            if ($Dhis2Scheme) { $quartoArgs += @('-P', "dhis2Scheme:$Dhis2Scheme") }
            if ($Dhis2Hostname) { $quartoArgs += @('-P', "dhis2Hostname:$Dhis2Hostname") }
            if ($Dhis2Port) { $quartoArgs += @('-P', "dhis2Port:$Dhis2Port") }
            if ($Dhis2Path) { $quartoArgs += @('-P', "dhis2Path:$Dhis2Path") }
            $result = Invoke-QuartoRender -Arguments $quartoArgs -Description "patient data report for $PatientId"
            if ($result.Status -eq 'Error') {
                $errors += "Quarto render failed for $PatientId (exit code $($result.ExitCode))."
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
    foreach ($name in $originalEnv.Keys) {
        $originalValue = $originalEnv[$name]
        if ($null -eq $originalValue) {
            [Environment]::SetEnvironmentVariable($name, $null, 'Process')
        } else {
            [Environment]::SetEnvironmentVariable($name, $originalValue, 'Process')
        }
    }

    Write-Progress -Activity 'Patient Data Report Build' -Completed

    $buildReportPath = Join-Path $outputDirPath "${scriptTimestamp}_NeoIPC-Surveillance-Patient-Data-Report-Build.json"
    $extraFields = [ordered]@{
        timestamp = $scriptTimestamp
        outputDir = $outputDirPath
        patientId = $PatientId
        departmentCode = $DepartmentCode
        format = $Format
        locale = $Locale
    }
    $reportPath = if ($JsonReport) { $buildReportPath } else { $null }
    $status = Write-NeoipcBuildReport -Name 'Patient Data Report Build' `
        -Errors $errors -OutputFiles $outputFiles -BuildCompleted $buildCompleted `
        -StartedAt $startedAt -BuildReportPath $reportPath -ExtraFields $extraFields

    if ($status -ne 'success') {
        exit 1
    }
}
