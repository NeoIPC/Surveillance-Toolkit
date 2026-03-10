[CmdletBinding(DefaultParameterSetName = 'Acquire')]
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$Signatory,
    [Parameter(Mandatory, Position = 1)]
    [System.IO.DirectoryInfo]$SignatureImagePath,
    [ArgumentCompleter({
        param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
        $cacheFile = Join-Path $PSScriptRoot '..' 'data' 'local' 'site-codes.txt'
        if (Test-Path -LiteralPath $cacheFile) {
            Get-Content -LiteralPath $cacheFile |
                Where-Object { $_ -like "$wordToComplete*" } |
                Sort-Object
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
    [ValidateScript({
        if (-not ($_ -ceq 'en' -or (Get-Item -LiteralPath "$PSScriptRoot/../reports/Partner Certificate/Partner Certificate.$_.qmd" -ErrorAction Ignore))) { 
            throw "The language '$_' is not supported."
        }
        return $true
    })]
    [ArgumentCompleter({
        param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
        @(
            Get-ChildItem -LiteralPath "$PSScriptRoot/../reports/Partner Certificate/" -File -Filter 'Partner Certificate.*.qmd' |
            Select-Object -ExpandProperty Name |
            ForEach-Object { if($_ -match 'Partner Certificate\.(.+)\.qmd') { $Matches[1] } }) + 'en' |
            Where-Object { $_ -like "$wordToComplete*" } |
            Sort-Object
     })]
    [Parameter(Position = 3, ParameterSetName = 'Acquire')]
    [Parameter(Position = 6, ParameterSetName = 'Pass')]
    [string]$Language = 'en',
    [Parameter(Position = 4, ParameterSetName = 'Acquire')]
    [Parameter(Position = 7, ParameterSetName = 'Pass')]
    [string]$Token
)

. "$PSScriptRoot/NeoipcReportHelpers.ps1"
$auth = Resolve-NeoipcAuth -Token $Token

$currentDir = Get-Location
$reportDir = Resolve-Path -LiteralPath "$PSScriptRoot/../reports/Partner Certificate/"
$quartoFile = Resolve-NeoipcLocaleQmd -ReportDir $reportDir -BaseName 'Partner Certificate' -Language $Language
$SignatureImagePath = Resolve-Path -LiteralPath $SignatureImagePath.FullName -Relative -RelativeBasePath $reportDir

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
    if ($DepartmentCode) {
        $allSites = Get-NeoipcDepartments -Auth $auth

        $sites = $allSites | Where-Object -FilterScript { foreach ($d in $DepartmentCode) { if ($_ -match $d) { return $true } } } | Sort-Object

        foreach ($site in $sites) {
            Write-Host "Generating partner certificate for $site..."
            $outFile = "$([datetime]::Now.ToString('yyyy-MM-dd_HHmmss'))_NeoIPC-Surveillance-Partner-Certificate_$($site).$($Language).pdf"
            $quartoArgs = @('render', $quartoFile, '-P', "signatory:$Signatory", '-P', "signatureImagePath:$SignatureImagePath", '-P', "departmentCode:$site", '-o', $outFile)
            $result = Invoke-QuartoRender -Arguments $quartoArgs -Description "partner certificate for $site"
            $exitCode = [System.Math]::Max($result.ExitCode, $exitCode)
        }
        exit $exitCode
    } else {
        Write-Host "Generating partner certificate for $HospitalName..."
        $outFile = "$([datetime]::Now.ToString('yyyy-MM-dd_HHmmss'))_NeoIPC-Surveillance-Partner-Certificate_$($HospitalName).$($Language).pdf"
        $quartoArgs = @('render', $quartoFile, '-P', "signatory:$Signatory", '-P', "signatureImagePath:$SignatureImagePath", '-P', "startYear:$StartYear", '-P', "endYear:$EndYear", '-P', "nPatients:$NumberOfPatients", '-P', "hospitalName:$HospitalName", '-o', $outFile)
        $result = Invoke-QuartoRender -Arguments $quartoArgs -Description "partner certificate for $HospitalName"
        $exitCode = $result.ExitCode
        exit $exitCode
    }
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
