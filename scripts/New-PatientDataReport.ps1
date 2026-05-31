[CmdletBinding(DefaultParameterSetName = 'Render')]
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

    [ValidateScript({
        if (-not ($_ -ceq 'en' -or (Get-Item -LiteralPath "$PSScriptRoot/../reports/Patient-Data-Report/Patient-Data-Report.$_.qmd" -ErrorAction Ignore))) {
            throw "The language '$_' is not supported."
        }
        return $true
    })]
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
    [string]$Language = 'en',

    [Parameter()]
    [string]$Token,

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
$timestamp = [datetime]::Now.ToString('yyyy-MM-dd_HHmmss')

$originalEnv = @{}
foreach ($name in @('NEOIPC_DHIS2_TOKEN', 'NEOIPC_DHIS2_USER', 'NEOIPC_DHIS2_PASSWORD', 'NEOIPC_DHIS2_SESSION_ID')) {
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

$exitCode = 0
try {
    Set-Location -LiteralPath $reportDir

    if ($Format -eq 'json') {
        $outFile = "${timestamp}_NeoIPC-Patient-Data_${PatientId}.json"
        Write-Host "Generating patient data JSON for $PatientId..."
        $rArgs = @('--vanilla', 'Generate-PatientData.R',
            '--patient-id', $PatientId,
            '--department', $DepartmentCode,
            '--output', $outFile)
        if ($Dhis2Scheme) { $rArgs += @('--scheme', $Dhis2Scheme) }
        if ($Dhis2Hostname) { $rArgs += @('--host', $Dhis2Hostname) }
        if ($null -ne $Dhis2Port) { $rArgs += @('--port', $Dhis2Port) }
        if ($Dhis2Path) { $rArgs += @('--path', $Dhis2Path) }
        Rscript @rArgs 2>&1 | ForEach-Object {
            $s = "$_"
            if ($s -match '^Error') { Write-Error $s }
            else { Write-Verbose $s }
        }
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0) {
            Write-Host "done. Output: $outFile" -ForegroundColor Green
        }
    } else {
        $quartoFile = Resolve-NeoipcLocaleQmd -ReportDir $reportDir -BaseName 'Patient-Data-Report' -Language $Language
        $outFile = "${timestamp}_NeoIPC-Patient-Data_${PatientId}.${Language}.${Format}"

        Write-Host "Generating patient data report ($Format) for $PatientId..."
        $quartoArgs = @('render', $quartoFile,
            '--profile', $Language,
            '--to', $Format,
            '-P', "patientId:$PatientId",
            '-P', "departmentCode:$DepartmentCode",
            '-o', $outFile)
        if ($Dhis2Scheme) { $quartoArgs += @('-P', "dhis2Scheme:$Dhis2Scheme") }
        if ($Dhis2Hostname) { $quartoArgs += @('-P', "dhis2Hostname:$Dhis2Hostname") }
        if ($null -ne $Dhis2Port) { $quartoArgs += @('-P', "dhis2Port:$Dhis2Port") }
        if ($Dhis2Path) { $quartoArgs += @('-P', "dhis2Path:$Dhis2Path") }
        $result = Invoke-QuartoRender -Arguments $quartoArgs -Description "patient data report for $PatientId"
        $exitCode = $result.ExitCode
    }

    exit $exitCode
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
}
