#Requires -Version 7.6

# The UN/LOCODE directory of one country, or the list of countries when none is given. The directory's own
# country filter takes the upper-case ISO 3166 code.
function Get-NeoIPCLocodeUrl {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [string]$Country
    )

    if ($Country -cmatch '^[A-Z]{2}$') { return "https://unlocode.unece.org/directory/locodes?country=$Country" }
    'https://unece.org/trade/cefact/unlocode-code-list-country-and-territory'
}

# Whether a person can be asked: the session has a user, and the caller did not turn prompting off. Only Windows tells
# a session without a user apart; .NET reports every session elsewhere as having one.
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
# the write succeeded (WebMessageUtils.created, ok, and typeReport in 2.40): a success code with any other answer, such
# as the page of a firewall or a proxy, says nothing of the write, and fails too. The response is what
# Invoke-NeoIPCDhis2Post returns.
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

# Ask for one part of the hospital code until the answer has the expected shape. An empty answer ends the call.
function Read-NeoIPCHospitalCodePart {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Pattern,

        [Parameter(Mandatory)]
        [string]$Expected
    )

    while ($true) {
        $answer = Read-Host -Prompt "$Name ($Expected)"
        if ([string]::IsNullOrWhiteSpace($answer)) {
            throw [System.OperationCanceledException]::new("No $Name given.")
        }
        if ($answer -cmatch $Pattern) { return $answer }
        Write-Warning "'$answer' is not $Expected."
    }
}
