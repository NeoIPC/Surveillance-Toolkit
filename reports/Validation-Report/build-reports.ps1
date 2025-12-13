[CmdletBinding()]
Param(
    [Parameter(Position=0)]
    [System.String]
    $SiteCodeFilter = '.+',

    [Parameter(Position=1)]
    [System.String]
    $Language = 'en'
)

$token = Get-Content -LiteralPath "$PSScriptRoot/../../../token.txt" -Raw -Encoding utf8NoBOM

$depts = (
    Invoke-RestMethod -Method Get -Headers @{'Authorization' = "ApiToken $token" } -Uri `
    'https://neoipc.charite.de/api/organisationUnitGroups.json?paging=false&filter=code:eq:NEO_DEPARTMENT&fields=organisationUnits%5Bcode%5D'
    ).organisationUnitGroups[0].organisationUnits.code | Where-Object -FilterScript { $_ -match $SiteCodeFilter } | Sort-Object

$wd = Get-Location
try {
    Set-Location -LiteralPath $PSScriptRoot

    foreach ($site in $depts) {
        Write-Host "Generating validation report for $site..."
        $outFile = "$([datetime]::Now.ToString('yyyy-MM-dd_HHmmss'))_NeoIPC-Surveillance-Validation-Report_$($site).$($Language).pdf"
        $skipRest = $false
        $errorLine = ''
        $isError = $false
        quarto render --profile $Language -P "language:$Language" -P "token:../../../token.txt" -P "departmentFilter:$($site)" -o $outFile 2>&1 | ForEach-Object -Process {
            if ($skipRest) {
                return
            }
            $s = "$_"
            if ($s -eq 'System.Management.Automation.RemoteException') {
                $s = ''
            }
            if ($isError) {
                if ($s -eq '! No problem detected') {
                    Write-Host "No problem detected." -ForegroundColor DarkYellow
                    $skipRest = $true
                }
                else {
                    if ($errorLine.Length -gt 0) {
                        Write-Error -Message $errorLine
                        $errorLine = ''
                    }
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
        if (-not $skipRest -and -not $isError) {
            Write-Host "done." -ForegroundColor Green
        }
    }
}
finally {
    Set-Location -LiteralPath $wd
}
