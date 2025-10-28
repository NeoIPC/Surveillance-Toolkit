[CmdletBinding(DefaultParameterSetName = 'Acquire')]
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$Signatory,
    [Parameter(Mandatory, Position = 1)]
    [System.IO.DirectoryInfo]$SignatureImagePath,
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

if ($Token) {
    $tokenPath = Resolve-Path -LiteralPath $Token -ErrorAction SilentlyContinue
    if ([System.IO.File]::Exists($tokenPath)) {
        $Token = Get-Content -LiteralPath $tokenPath -TotalCount 1 -Encoding utf8
    }
} elseif ($env:NEOIPC_DHIS2_TOKEN) {
    $Token = $env:NEOIPC_DHIS2_TOKEN
    if ([System.IO.File]::Exists($Token)) {
        $Token = Get-Content -LiteralPath $Token -TotalCount 1 -Encoding utf8
    }
} else {
    throw "Failed to detect a DHIS2 personal access token in the environment. Please set the 'NEOIPC_DHIS2_TOKEN' environment variable or pass the token via the -Token parameter."
}

if ($Language -eq 'en') {
    $quartoFile = 'Partner Certificate.qmd'
} else {
    $quartoFile = "Partner Certificate.$Language.qmd"
}

function HandleQuartoResult {
    param ($QuartoResult)
    $errorLine = ''
    $isError = $false
    foreach ($line in $QuartoResult) {
        $s = "$line"
        if ($s -eq 'System.Management.Automation.RemoteException') {
            continue
        }
        if ($isError) {
            $errorLine += $s
        }
        elseif ($s -match '^(Error)|(Fehler)') {
            $isError = $true
            $errorLine = $s
        }
        else {
            $s | Write-Verbose
        }
    }
    if ($isError) {
        Write-Host $errorLine -ForegroundColor Red
    }
    else {
        Write-Host "done." -ForegroundColor Green
    }
}

$currentDir = Get-Location
$reportDir = Resolve-Path -LiteralPath "$PSScriptRoot/../reports/Partner Certificate/"
$SignatureImagePath = Resolve-Path -LiteralPath (Resolve-Path -LiteralPath $SignatureImagePath) -Relative -RelativeBasePath $reportDir

$exitCode = 0
try {
    Set-Location -LiteralPath $reportDir
    if ($DepartmentCode) {
        $deptsQueryResult = curl -sfSH "Authorization: ApiToken $Token" `
        'https://neoipc.charite.de/api/organisationUnitGroups.json?paging=false&filter=code:eq:NEO_DEPARTMENT&fields=organisationUnits%5Bcode%5D' 2>&1

        if ($LASTEXITCODE -ne 0) {
            if ($deptsQueryResult -match '\D401\D?.*$') {
                throw "Authorisation failed"
                exit 401
            } else {
                exit 1
            }
        }

        $sites = ($deptsQueryResult | ConvertFrom-Json -Depth 10).organisationUnitGroups[0].organisationUnits.code | Where-Object -FilterScript {  foreach ($d in $DepartmentCode) { if ($_ -match $d) { return $true } } } | Sort-Object

        foreach ($site in $sites) {
            Write-Host "Generating validation report for $site..."
            $outFile = "$([datetime]::Now.ToString('yyyy-MM-dd_HHmmss'))_NeoIPC-Surveillance-Partner-Certificate_$($site).$($Language).pdf"
            $quartoResult = quarto render $quartoFile -P "signatory:$Signatory" -P "signatureImagePath:$SignatureImagePath" -P "departmentCode:$site" -P "token:$Token" -o $outFile 2>&1
            $exitCode = [System.Math]::Max($LASTEXITCODE, $exitCode)
            HandleQuartoResult $quartoResult
        }
        exit $exitCode
    } else {
        Write-Host "Generating validation report for $HospitalName..."
        $outFile = "$([datetime]::Now.ToString('yyyy-MM-dd_HHmmss'))_NeoIPC-Surveillance-Partner-Certificate_$($HospitalName).$($Language).pdf"
        $quartoResult = quarto render "'$quartoFile'" -P "signatory:$Signatory" -P "signatureImagePath:$SignatureImagePath" -P "startYear:$StartYear" -P "endYear:$EndYear" -P "nPatients:$NumberOfPatients" -P "hospitalName:$HospitalName" -P "token:$Token" -o $outFile 2>&1
        $exitCode = $LASTEXITCODE
        HandleQuartoResult $quartoResult
        exit $exitCode
    }
}
finally {
    Set-Location -LiteralPath $currentDir
}
