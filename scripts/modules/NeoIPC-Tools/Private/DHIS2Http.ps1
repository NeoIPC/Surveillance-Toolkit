#Requires -Version 7.6
# Private DHIS2 HTTP layer — not exported from the module.
# All public functions that call the DHIS2 API should go through these functions.

function New-NeoIPCDhis2Uri {
    # Build the request URI from scheme/host/port/path plus pre-built, already-encoded query parts. Shared by
    # the GET / DELETE / POST verbs so the UriBuilder construction (port=-1/null handled cleanly) lives once.
    param(
        [Parameter(Mandatory)][string]$Scheme,
        [Parameter(Mandatory)][string]$Hostname,
        [Nullable[int]]$Port,
        [Parameter(Mandatory)][string]$Path,
        [string[]]$QueryPart
    )
    $effectivePort = if ($null -ne $Port) { $Port } else { -1 }
    $uriBuilder = [UriBuilder]::new($Scheme, $Hostname, $effectivePort, $Path)
    if ($QueryPart) { $uriBuilder.Query = '?' + ($QueryPart -join '&') }
    $uriBuilder.Uri
}

function Set-NeoIPCDhis2Auth {
    # Apply an auth hashtable to an Invoke-RestMethod splat: a PAT goes in the Authorization header, a
    # username/password becomes Basic credential auth. Shared by every verb so a credential change lands once.
    # -AllowUnencrypted adds AllowUnencryptedAuthentication for Basic over http (the local dev stack).
    param(
        [Parameter(Mandatory)][hashtable]$InvokeParams,
        [Parameter(Mandatory)][hashtable]$Auth,
        [switch]$AllowUnencrypted
    )
    if ($Auth.AuthType -eq 'Token') {
        $InvokeParams.Headers = @{ 'Authorization' = "ApiToken $($Auth.Token)" }
    }
    else {
        $InvokeParams.Authentication = 'Basic'
        $InvokeParams.Credential = [System.Management.Automation.PSCredential]::new($Auth.Username, $Auth.Password)
        if ($AllowUnencrypted) { $InvokeParams.AllowUnencryptedAuthentication = $true }
    }
}

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
        [hashtable]$QueryParameters,

        # Parse the body into ordered dictionaries and keep every date as the server's own text. Invoke-RestMethod
        # turns DHIS2's timestamps into [datetime], and a value written back from one (a `created` a deployment
        # preserves) is then re-serialized by .NET rather than passed through as DHIS2 stored it.
        [switch]$AsHashtable,

        # Read only the first page, of this many items, instead of every item: for a question one item answers.
        [Nullable[int]]$PageSize = $null
    )

    $queryParts = [System.Collections.Generic.List[string]]::new()
    if ($null -ne $PageSize) { $queryParts.Add("pageSize=$PageSize") }
    else { $queryParts.Add('paging=false') }

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

    $uri = New-NeoIPCDhis2Uri -Scheme $Scheme -Hostname $Hostname -Port $Port -Path $Path -QueryPart $queryParts

    $invokeParams = @{
        Method      = 'Get'
        Uri         = $uri
        ErrorAction = 'Stop'
    }
    # -AllowUnencrypted so Basic auth works over the local http dev/test stack, matching the POST helper
    # (harmless over https — it only permits, never forces, unencrypted Basic auth).
    Set-NeoIPCDhis2Auth -InvokeParams $invokeParams -Auth $Auth -AllowUnencrypted

    if ($PSCmdlet.ShouldProcess(
            "GET $uri",
            "Fetch DHIS2 data via GET $uri?",
            'Fetching DHIS2 data')) {
        Write-Debug "GET $uri"
        try {
            if ($AsHashtable) { return ((Invoke-WebRequest @invokeParams).Content | ConvertFrom-Json -AsHashtable -DateKind String) }
            Invoke-RestMethod @invokeParams
        }
        catch {
            throw "Failed to fetch '$Path' from DHIS2 ($uri): $($_.Exception.Message)"
        }
    }
}

function Get-NeoIPCDhis2StatusCode {
    # The HTTP status of a GET, without throwing on 4xx/5xx: 200 when the object exists, 404 when it does not. The
    # read-back that proves a delete, since DHIS2 can answer a DELETE with 200 and keep the object.
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][hashtable]$Auth,
        [Parameter(Mandatory)][string]$Path,
        [string]$Scheme = 'https',
        [string]$Hostname = 'neoipc.charite.de',
        [Nullable[int]]$Port = $null
    )
    $uri = New-NeoIPCDhis2Uri -Scheme $Scheme -Hostname $Hostname -Port $Port -Path $Path -QueryPart 'fields=id'
    $invokeParams = @{ Method = 'Get'; Uri = $uri; SkipHttpErrorCheck = $true }
    Set-NeoIPCDhis2Auth -InvokeParams $invokeParams -Auth $Auth -AllowUnencrypted
    Write-Debug "GET $uri"
    [int](Invoke-WebRequest @invokeParams).StatusCode
}

function Invoke-NeoIPCDhis2Delete {
    <#
    .SYNOPSIS
        DELETE a DHIS2 object, throwing an error that carries the HTTP status and DHIS2's error code on failure.
    .DESCRIPTION
        A failure is a transport status outside 2xx, or a 2xx whose WebMessage body reports one (DHIS2 can answer a
        DELETE with HTTP 200 and an error body). It is thrown as an HttpRequestException whose StatusCode is the
        failing status and whose Data['Dhis2ErrorCode'] holds DHIS2's errorCode when the body names one, so a
        caller can decide per object (catch and continue) or per status (stop at the first 401). A 200 proves only
        that DHIS2 accepted the request: DHIS2 2.41.10 and later answer a program stage section's DELETE with 200
        and keep the section, so a caller that must know the object is gone reads it back.
    .PARAMETER AllowUnencrypted
        Permit Basic auth over http (the local stack).
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Auth,

        [Parameter(Mandatory)]
        [string]$Path,

        [string]$Scheme = 'https',
        [string]$Hostname = 'neoipc.charite.de',
        [Nullable[int]]$Port = $null,

        [switch]$AllowUnencrypted
    )

    $uri = New-NeoIPCDhis2Uri -Scheme $Scheme -Hostname $Hostname -Port $Port -Path $Path

    $invokeParams = @{
        Method             = 'Delete'
        Uri                = $uri
        SkipHttpErrorCheck = $true
        StatusCodeVariable = 'statusCode'
    }
    Set-NeoIPCDhis2Auth -InvokeParams $invokeParams -Auth $Auth -AllowUnencrypted:$AllowUnencrypted

    # Low-level ShouldProcess — callers typically suppress this with -Confirm:$false
    # and implement their own higher-level confirmation
    if ($PSCmdlet.ShouldProcess(
            "DELETE $uri",
            "Delete DHIS2 data via DELETE $uri?",
            'Removing DHIS2 data')) {
        Write-Debug "DELETE $uri"
        $($result = . { Invoke-RestMethod @invokeParams }) 4>&1 | Write-Debug

        $bodyStatus = if ($result -and $result.PSObject.Properties['httpStatusCode']) { [int]$result.httpStatusCode } else { $null }
        $failedStatus = if ([int]$statusCode -lt 200 -or [int]$statusCode -ge 300) { [int]$statusCode }
        elseif ($null -ne $bodyStatus -and ($bodyStatus -lt 200 -or $bodyStatus -ge 300)) { $bodyStatus }
        else { $null }
        if ($null -ne $failedStatus) {
            $errorCode = if ($result -and $result.PSObject.Properties['errorCode']) { [string]$result.errorCode } else { $null }
            $message = if ($result -and $result.PSObject.Properties['message']) { [string]$result.message } else { '' }
            $text = "DELETE '$Path' failed with HTTP $failedStatus$(if ($errorCode) { " ($errorCode)" }): $message"
            $exception = [System.Net.Http.HttpRequestException]::new($text, $null, [System.Net.HttpStatusCode]$failedStatus)
            $exception.Data['Dhis2ErrorCode'] = $errorCode
            $category = switch ($failedStatus) {
                401 { [System.Management.Automation.ErrorCategory]::AuthenticationError }
                403 { [System.Management.Automation.ErrorCategory]::PermissionDenied }
                404 { [System.Management.Automation.ErrorCategory]::ObjectNotFound }
                default { [System.Management.Automation.ErrorCategory]::InvalidOperation }
            }
            $PSCmdlet.ThrowTerminatingError([System.Management.Automation.ErrorRecord]::new($exception, 'NeoIPCDhis2DeleteFailed', $category, $Path))
        }
        $result
    }
}

function Invoke-NeoIPCDhis2Put {
    <#
    .SYNOPSIS
        PUT a JSON body to a DHIS2 endpoint, returning the transport status code and the parsed response body.
    .DESCRIPTION
        The PUT counterpart of Invoke-NeoIPCDhis2Post, for DHIS2's collection endpoints
        (api/<type>/<id>/<collection>, which replace a collection with {"identifiableObjects": [...]}). Like the POST
        helper it does not throw on a non-2xx status; interpreting the outcome is the caller's job. Higher-level
        callers run their own confirmation and invoke this with -Confirm:$false.
    .PARAMETER Path
        API path including the api/ segment.
    .PARAMETER Body
        The request body string (already-serialized JSON).
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

        [Parameter(Mandatory)][string]$Body,
        [string]$ContentType = 'application/json'
    )
    $uri = New-NeoIPCDhis2Uri -Scheme $Scheme -Hostname $Hostname -Port $Port -Path $Path
    $invokeParams = @{
        Method             = 'Put'
        Uri                = $uri
        ContentType        = $ContentType
        Body               = $Body
        SkipHttpErrorCheck = $true
        StatusCodeVariable = 'statusCode'
    }
    Set-NeoIPCDhis2Auth -InvokeParams $invokeParams -Auth $Auth -AllowUnencrypted
    if ($PSCmdlet.ShouldProcess("PUT $uri", "Replace DHIS2 data via PUT $uri?", 'Replacing DHIS2 data')) {
        Write-Debug "PUT $uri"
        $result = Invoke-RestMethod @invokeParams
        return [pscustomobject]@{ StatusCode = $statusCode; Body = $result }
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

    $queryParts = [System.Collections.Generic.List[string]]::new()
    if ($QueryParameters) {
        foreach ($key in $QueryParameters.Keys) {
            $queryParts.Add("${key}=$([System.Net.WebUtility]::UrlEncode([string]$QueryParameters[$key]))")
        }
    }
    $uri = New-NeoIPCDhis2Uri -Scheme $Scheme -Hostname $Hostname -Port $Port -Path $Path -QueryPart $queryParts

    $invokeParams = @{
        Method             = 'Post'
        Uri                = $uri
        ContentType        = $ContentType
        SkipHttpErrorCheck = $true
        StatusCodeVariable = 'statusCode'
    }
    if ($PSBoundParameters.ContainsKey('Body')) { $invokeParams.Body = $Body }
    Set-NeoIPCDhis2Auth -InvokeParams $invokeParams -Auth $Auth -AllowUnencrypted

    if ($PSCmdlet.ShouldProcess(
            "POST $uri",
            "Send data to DHIS2 via POST $uri?",
            'Sending DHIS2 data')) {
        Write-Debug "POST $uri"
        $result = Invoke-RestMethod @invokeParams
        return [pscustomobject]@{ StatusCode = $statusCode; Body = $result }
    }
}
