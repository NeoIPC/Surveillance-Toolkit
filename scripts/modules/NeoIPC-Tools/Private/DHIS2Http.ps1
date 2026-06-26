# Private DHIS2 HTTP layer — not exported from the module.
# All public functions that call the DHIS2 API should go through these functions.

function Invoke-NeoIPCDhis2Get {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Auth,

        [Parameter(Mandatory)]
        [string]$Path,

        [string]$Scheme = 'https',
        [string]$Hostname = 'neoipc.charite.de',
        [Nullable[int]]$Port = $null,

        [string[]]$Fields,
        [string[]]$Filter,
        [hashtable]$QueryParameters
    )

    # Build URI with UriBuilder — handles port=-1/null cleanly
    $effectivePort = if ($null -ne $Port) { $Port } else { -1 }
    $uriBuilder = [UriBuilder]::new($Scheme, $Hostname, $effectivePort, $Path)

    # Always disable paging — all callers want full results
    $queryParts = [System.Collections.Generic.List[string]]::new()
    $queryParts.Add('paging=false')

    if ($Fields) {
        $joined = ($Fields | Join-String -Separator ',')
        $queryParts.Add("fields=$([System.Net.WebUtility]::UrlEncode($joined))")
    }

    if ($Filter) {
        foreach ($f in $Filter) {
            $queryParts.Add("filter=$([System.Net.WebUtility]::UrlEncode($f))")
        }
    }

    if ($QueryParameters) {
        foreach ($key in $QueryParameters.Keys) {
            $queryParts.Add("${key}=$([System.Net.WebUtility]::UrlEncode($QueryParameters[$key]))")
        }
    }

    $uriBuilder.Query = '?' + ($queryParts -join '&')

    # Build Invoke-RestMethod parameters from auth hashtable
    $invokeParams = @{
        Method      = 'Get'
        Uri         = $uriBuilder.Uri
        ErrorAction = 'Stop'
    }

    if ($Auth.AuthType -eq 'Token') {
        $invokeParams.Headers = @{ 'Authorization' = "ApiToken $($Auth.Token)" }
    }
    else {
        $cred = [System.Management.Automation.PSCredential]::new(
            $Auth.Username,
            $Auth.Password)
        $invokeParams.Authentication = 'Basic'
        $invokeParams.Credential = $cred
    }

    if ($PSCmdlet.ShouldProcess(
            "GET $($uriBuilder.Uri)",
            "Fetch DHIS2 data via GET $($uriBuilder.Uri)?",
            'Fetching DHIS2 data')) {
        Write-Debug "GET $($uriBuilder.Uri)"
        try {
            Invoke-RestMethod @invokeParams
        }
        catch {
            throw "Failed to fetch '$Path' from DHIS2 ($($uriBuilder.Uri)): $($_.Exception.Message)"
        }
    }
}

function Invoke-NeoIPCDhis2Delete {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Auth,

        [Parameter(Mandatory)]
        [string]$Path,

        [string]$Scheme = 'https',
        [string]$Hostname = 'neoipc.charite.de',
        [Nullable[int]]$Port = $null
    )

    $effectivePort = if ($null -ne $Port) { $Port } else { -1 }
    $uriBuilder = [UriBuilder]::new($Scheme, $Hostname, $effectivePort, $Path)

    $invokeParams = @{
        Method             = 'Delete'
        Uri                = $uriBuilder.Uri
        SkipHttpErrorCheck = $true
    }

    if ($Auth.AuthType -eq 'Token') {
        $invokeParams.Headers = @{ 'Authorization' = "ApiToken $($Auth.Token)" }
    }
    else {
        $cred = [System.Management.Automation.PSCredential]::new(
            $Auth.Username,
            $Auth.Password)
        $invokeParams.Authentication = 'Basic'
        $invokeParams.Credential = $cred
    }

    # Low-level ShouldProcess — callers typically suppress this with -Confirm:$false
    # and implement their own higher-level confirmation
    if ($PSCmdlet.ShouldProcess(
            "DELETE $($uriBuilder.Uri)",
            "Delete DHIS2 data via DELETE $($uriBuilder.Uri)?",
            'Removing DHIS2 data')) {
        Write-Debug "DELETE $($uriBuilder.Uri)"
        $($result = . { Invoke-RestMethod @invokeParams }) 4>&1 | Write-Debug

        # DHIS2 can return HTTP 200 with an error in the JSON body on DELETE
        if ($null -ne $result.httpStatusCode -and ($result.httpStatusCode -lt 200 -or $result.httpStatusCode -ge 300)) {
            $errorMessage = "DELETE '$Path' failed with HTTP $($result.httpStatusCode) ('$($result.httpStatus)'), DHIS2 status $($result.status)"
            if ($null -ne $result.errorCode) {
                $errorMessage += ", message: '$($result.message)', error code: $($result.errorCode)"
            } else {
                $errorMessage += ", message: '$($result.message)'"
            }
            Write-Error $errorMessage
        }
        $result
    }
}

function Invoke-NeoIPCDhis2Post {
    <#
    .SYNOPSIS
        POST a JSON body to a DHIS2 endpoint, returning the transport status code and the parsed response body.
    .DESCRIPTION
        The write counterpart to Invoke-NeoIPCDhis2Get / -Delete (same $Auth-hashtable + scheme/host/port surface).
        It does NOT throw on a non-2xx transport status — it sets SkipHttpErrorCheck and returns both the HTTP status
        code and the parsed body, because DHIS2 conveys import outcomes (OK / WARNING / ERROR) in the body's
        WebMessage regardless of the transport code (e.g. a metadata import with conflicts answers HTTP 409 with the
        full ImportReport in the body). Interpreting that outcome is the caller's job. Like the DELETE helper this is
        SupportsShouldProcess; higher-level callers run their own confirmation and invoke this with -Confirm:$false.
    .PARAMETER Auth
        Auth hashtable as returned by Resolve-NeoIPCAuth (@{ AuthType = 'Token'; Token } or
        @{ AuthType = 'Basic'; Username; Password = <SecureString> }). Basic auth is sent with
        -AllowUnencryptedAuthentication so the local http dev stack works.
    .PARAMETER Path
        API path including the api/ segment (e.g. 'api/metadata'), matching the GET/DELETE helpers.
    .PARAMETER Body
        The request body string (already-serialized JSON for the default content type).
    .PARAMETER ContentType
        Request content type. Default 'application/json'.
    .PARAMETER QueryParameters
        Optional query string parameters (each value URL-encoded).
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Auth,

        [Parameter(Mandatory)]
        [string]$Path,

        [string]$Scheme = 'https',
        [string]$Hostname = 'neoipc.charite.de',
        [Nullable[int]]$Port = $null,

        [string]$Body,
        [string]$ContentType = 'application/json',
        [hashtable]$QueryParameters
    )

    $effectivePort = if ($null -ne $Port) { $Port } else { -1 }
    $uriBuilder = [UriBuilder]::new($Scheme, $Hostname, $effectivePort, $Path)

    if ($QueryParameters) {
        $queryParts = [System.Collections.Generic.List[string]]::new()
        foreach ($key in $QueryParameters.Keys) {
            $queryParts.Add("${key}=$([System.Net.WebUtility]::UrlEncode([string]$QueryParameters[$key]))")
        }
        $uriBuilder.Query = '?' + ($queryParts -join '&')
    }

    $invokeParams = @{
        Method             = 'Post'
        Uri                = $uriBuilder.Uri
        ContentType        = $ContentType
        SkipHttpErrorCheck = $true
        StatusCodeVariable = 'statusCode'
    }
    if ($PSBoundParameters.ContainsKey('Body')) { $invokeParams.Body = $Body }

    if ($Auth.AuthType -eq 'Token') {
        $invokeParams.Headers = @{ 'Authorization' = "ApiToken $($Auth.Token)" }
    }
    else {
        $cred = [System.Management.Automation.PSCredential]::new(
            $Auth.Username,
            $Auth.Password)
        $invokeParams.Authentication = 'Basic'
        $invokeParams.Credential = $cred
        $invokeParams.AllowUnencryptedAuthentication = $true
    }

    if ($PSCmdlet.ShouldProcess(
            "POST $($uriBuilder.Uri)",
            "Send data to DHIS2 via POST $($uriBuilder.Uri)?",
            'Sending DHIS2 data')) {
        Write-Debug "POST $($uriBuilder.Uri)"
        $result = Invoke-RestMethod @invokeParams
        return [pscustomobject]@{ StatusCode = $statusCode; Body = $result }
    }
}
