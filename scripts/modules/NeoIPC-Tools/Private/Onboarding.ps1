#Requires -Version 7.6

# The parts of the hospital code, the UN/LOCODE's country and location and the partner's acronym, and the whole code,
# each anchored with \A and \z: .NET's $ also matches before a final line feed, which text read from a file ends in.
$script:NeoIPCHospitalCodeParts = [ordered]@{
    Country  = @{ Pattern = '\A[A-Z]{2}\z'; Expected = 'two upper-case letters, the UN/LOCODE country code' }
    Location = @{ Pattern = '\A[A-Z2-9]{3}\z'; Expected = 'three upper-case characters of A-Z and 2-9, the UN/LOCODE location code' }
    Acronym  = @{ Pattern = '\A[A-Z0-9]+\z'; Expected = 'the upper-case Latin letters A-Z and the digits 0-9' }
}
$script:NeoIPCHospitalCodePattern = '\A(?<Country>[A-Z]{2})_(?<Location>[A-Z2-9]{3})_(?<Acronym>[A-Z0-9]+)\z'

# The UN/LOCODE directory of one country, or the list of countries when none is given. The directory's own
# country filter takes the upper-case ISO 3166 code.
function Get-NeoIPCLocodeUrl {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [string]$Country
    )

    if ($Country -cmatch $script:NeoIPCHospitalCodeParts.Country.Pattern) { return "https://unlocode.unece.org/directory/locodes?country=$Country" }
    'https://unece.org/trade/cefact/unlocode-code-list-country-and-territory'
}

# End the call on a part of the hospital code given in another shape than its own; a part not given passes.
function Assert-NeoIPCHospitalCodePart {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Value
    )

    foreach ($name in $script:NeoIPCHospitalCodeParts.Keys) {
        $part = $Value[$name]
        $shape = $script:NeoIPCHospitalCodeParts[$name]
        if (-not [string]::IsNullOrEmpty($part) -and $part -cnotmatch $shape.Pattern) {
            throw [System.ArgumentException]::new("The $($name.ToLowerInvariant()) '$part' is not $($shape.Expected).", $name)
        }
    }
}

# Whether a person can be asked: the session has a user, and the caller did not turn prompting off. Only Windows tells
# a session without a user apart; .NET reports every session elsewhere as having one. PowerShell offers no way to ask
# whether its host can put a question: a pwsh started with -NonInteractive shows the switch only in the process's
# command line, among its own parameters, which end where the script or command it runs begins, and a program that
# hosts PowerShell has a command line of its own. So the callers learn it when Read-Host refuses a question there with a
# PSInvalidOperationException, which they take as nobody to ask.
function Test-NeoIPCInteractive {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()]
        [switch]$NonInteractive
    )

    -not $NonInteractive -and [Environment]::UserInteractive
}

# Open a page in the default browser. A machine without one gets the address in a warning instead of an error:
# the caller needs the page, not the browser.
function Open-NeoIPCUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Url
    )

    try { Start-Process -FilePath $Url }
    catch { Write-Warning "Could not open a browser; open $Url yourself." }
}

# End a DHIS2 write that did not succeed with the error the read helpers raise for a refused read, plus the messages of
# the import report's error reports, which DHIS2 answers with HTTP 409 and which hold the reason (a duplicate code, a
# missing required property). DHIS2 answers each of these writes with a web message of its own, whose status is OK when
# the write succeeded: in 2.40 to 2.43, a creation's answer is WebMessageUtils.objectReport, to which
# AbstractCrudController.postObject gives HTTP 201, and an addition to a collection's is typeReport, each ok() when the
# write succeeded. A success code with any other answer, such as the page of a firewall or a proxy, says nothing of the
# write, and fails too. The response is what Invoke-NeoIPCDhis2Post returns.
function Assert-NeoIPCDhis2WriteOk {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Response,

        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [hashtable]$Auth
    )

    $body = $Response.Body
    $field = { param([string]$Name) if ($body -is [System.Collections.IDictionary]) { $body[$Name] } elseif ($null -ne $body -and $body -isnot [string]) { $body.$Name } }
    $webMessage = $null -ne (& $field 'httpStatusCode')
    $success = $Response.StatusCode -ge 200 -and $Response.StatusCode -lt 300
    if ($success -and $webMessage -and [string](& $field 'status') -ceq 'OK') { return }

    $content = if ($body -is [string]) { $body } else { ConvertTo-Json -InputObject $body -Depth 100 -Compress }
    $detail = Get-NeoIPCDhis2ErrorDetail -Content $content
    # A proxy answers with a page of its own, which is no JSON; inside a caller's try a failed parse would end the call
    # with the parser's error instead of the status.
    $parsed = try { $content | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { $null }
    $reports = @(if ($parsed -is [System.Collections.IDictionary]) { $parsed['response']?['errorReports'] })
    $reasons = @($reports | Where-Object { $_ -is [System.Collections.IDictionary] } | ForEach-Object { [string]$_['message'] })
    $message = (@($detail.Message) + $reasons | Where-Object { $_ }) -join ' '
    if ($success -and -not $webMessage) { $message = "the answer is not DHIS2's$(if ($message) { ": $message" })" }
    $record = New-NeoIPCDhis2HttpError -Method 'POST' -Path $Path -StatusCode $Response.StatusCode -Message $message -ErrorCode $detail.ErrorCode -Auth $Auth
    throw $record.Exception
}

# Whether the answer to a write is DHIS2 refusing it: a 4xx answer whose body is DHIS2's own message with the status
# ERROR. DHIS2 answers only once its transactions have ended (AbstractCrudController.postObject builds its answer after
# the @Transactional importMetadata returns), so after its refusal a read shows what it holds. A refusal does not show
# that nothing was written: an error after the import committed, such as one of the version update that follows the
# creation of an org unit (OrganisationUnitController.postCreateEntity), is answered with 409 and ERROR too
# (CrudControllerAdvice). Any other failure, such as a gateway's page, a 5xx, or no answer at all, can come before a
# commit that still happens. The response is what Invoke-NeoIPCDhis2Post returns, or nothing.
function Test-NeoIPCDhis2Refusal {
    [CmdletBinding()]
    [OutputType([bool])]
    param([pscustomobject]$Response)

    if ($null -eq $Response -or $Response.StatusCode -lt 400 -or $Response.StatusCode -ge 500) { return $false }
    $body = $Response.Body
    $status = if ($body -is [System.Collections.IDictionary]) { $body['status'] } elseif ($body -isnot [string]) { $body.status }
    [string]$status -ceq 'ERROR'
}

# Ask for one part of the hospital code until the answer has its shape. An empty answer, or an input that has ended,
# ends the call; a PowerShell that refuses to ask throws Read-Host's PSInvalidOperationException, which the caller takes.
function Read-NeoIPCHospitalCodePart {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Country', 'Location', 'Acronym')]
        [string]$Name
    )

    $shape = $script:NeoIPCHospitalCodeParts[$Name]
    while ($true) {
        $answer = Read-Host -Prompt "$Name ($($shape.Expected))"
        if ([string]::IsNullOrWhiteSpace($answer)) {
            throw [System.OperationCanceledException]::new("No $Name given.")
        }
        if ($answer -cmatch $shape.Pattern) { return $answer }
        Write-Warning "'$answer' is not $($shape.Expected)."
    }
}
