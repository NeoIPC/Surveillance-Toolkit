#Requires -Version 7.6
# Private DHIS2 HTTP layer — not exported from the module.
# All public functions that call the DHIS2 API should go through these functions.

function Resolve-NeoIPCDhis2Hostname {
    # The DHIS2 host a call goes to: the given one, trimmed, else the NEOIPC_DHIS2_HOST environment variable. The module
    # has no built-in host, so nothing reaches an instance by omission; a call with neither stops here. A host given as
    # white space only stops it too, rather than counting as none: a writer's confirmation would name that blank host
    # while the request went to the variable's.
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Hostname)
    if (-not [string]::IsNullOrEmpty($Hostname)) {
        if ([string]::IsNullOrWhiteSpace($Hostname)) { throw '-Hostname holds only white space, which names no DHIS2 host.' }
        return $Hostname.Trim()
    }
    $fromEnvironment = $env:NEOIPC_DHIS2_HOST
    if (-not [string]::IsNullOrWhiteSpace($fromEnvironment)) { return $fromEnvironment.Trim() }
    throw 'No DHIS2 host given: pass -Hostname or set the NEOIPC_DHIS2_HOST environment variable.'
}

function Get-NeoIPCDhis2BaseUrl {
    # The address a browser opens the instance at, which every link the module emits starts from:
    # <scheme>://<host>[:<port>], https by default, the host from Resolve-NeoIPCDhis2Hostname, written as System.Uri
    # writes the requests' authority: the scheme and host in lower case, an IPv6 address in brackets, and no port where
    # it is the scheme's default.
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Scheme, [string]$Hostname, [Nullable[int]]$Port)
    $builder = [UriBuilder]::new($(if ($Scheme) { $Scheme } else { 'https' }), (Resolve-NeoIPCDhis2Hostname -Hostname $Hostname), $(if ($null -ne $Port) { $Port } else { -1 }))
    $builder.Uri.GetLeftPart([UriPartial]::Authority)
}

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

function Split-NeoIPCList {
    # Values cut into chunks for one list parameter, each holding at most -MaximumCount values whose text, joined with the
    # separator and URL-encoded, stays within -MaximumLength characters. Tomcat refuses a request line over 8 KB with
    # HTTP 414 (a filter of 550 UIDs passed on every verified release, one of 700 did not), and the same line carries the
    # path, the fields, and the other parameters. Throws on a value that alone exceeds the length.
    [CmdletBinding()]
    [OutputType([string[][]])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Value,
        [Parameter(Mandatory)][string]$Separator,
        [ValidateRange(1, [int]::MaxValue)][int]$MaximumCount = 100,
        [ValidateRange(1, [int]::MaxValue)][int]$MaximumLength = 4000
    )
    $chunks = [System.Collections.Generic.List[string[]]]::new()
    $current = [System.Collections.Generic.List[string]]::new()
    $length = 0
    $separatorLength = [System.Net.WebUtility]::UrlEncode($Separator).Length
    foreach ($v in $Value) {
        $valueLength = [System.Net.WebUtility]::UrlEncode($v).Length
        if ($valueLength -gt $MaximumLength) { throw "A value of $valueLength encoded characters does not fit in one request." }
        if ($current.Count -gt 0 -and ($current.Count -ge $MaximumCount -or $length + $separatorLength + $valueLength -gt $MaximumLength)) {
            $chunks.Add($current.ToArray())
            $current.Clear()
            $length = 0
        }
        $length += $(if ($current.Count -gt 0) { $separatorLength }) + $valueLength
        $current.Add($v)
    }
    if ($current.Count -gt 0) { $chunks.Add($current.ToArray()) }
    , $chunks.ToArray()
}

function Get-NeoIPCCodeLikeValue {
    # The value a `code:like:` filter looks a code up by: the longest of the code's runs that hold none of ',', '%', '\',
    # '[', and line breaks, each taken without its trailing ':' characters (the first of equal ones), or '' when no run is
    # left. DHIS2 2.42 and later receive an object list's filters joined with ',' and split them again, ending a value that
    # starts with '[' and holds a ']' at its first ']', and any other value at its first ',' or line break, and reading
    # what follows as further filters (GetObjectListParams.splitFilters). DHIS2 drops every '%' from a like value
    # (LikeOperator.getPredicate), and PostgreSQL's LIKE takes '\' as its escape character, so a value holding either would
    # no longer match the code, while a '_', which LIKE takes for any one character, only widens the match. DHIS2's query
    # parsers split a filter at ':', which drops trailing empty parts: every release reads a value of nothing but ':' as
    # none, and 2.42 and later read any other value without its trailing ':' characters (DefaultQueryParser), so every
    # release reads a run taken without them as sent.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Code)
    $longest = ''
    foreach ($run in $Code.Split([char[]]@(',', '%', '\', '[', "`r", "`n"))) {
        $run = $run.TrimEnd(':')
        if ($run.Length -gt $longest.Length) { $longest = $run }
    }
    $longest
}

function Get-NeoIPCDhis2ErrorDetail {
    # What the body of a failed DHIS2 response says: the WebMessage's message and errorCode when it is JSON, else a short
    # excerpt of its text. Some refusals come as the servlet container's HTML error page instead (DHIS2 2.43's event read
    # without a program, for one); .NET has no HTML parser, so the excerpt drops the markup by pattern, and it is only
    # ever shown, never read further.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowNull()][AllowEmptyString()][string]$Content)
    $message = ''
    $errorCode = $null
    if (-not [string]::IsNullOrWhiteSpace($Content)) {
        $parsed = try { $Content | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { $null }
        if ($parsed -is [System.Collections.IDictionary]) {
            $message = [string]$parsed['message']
            if ($parsed['errorCode']) { $errorCode = [string]$parsed['errorCode'] }
        }
        else {
            $text = $Content -replace '(?is)<(script|style)\b.*?</\1\s*>', ' ' -replace '(?s)<[^>]*>', ' '
            $text = ([System.Net.WebUtility]::HtmlDecode($text) -replace '\s+', ' ').Trim()
            $message = if ($text.Length -gt 300) { $text.Substring(0, 300) + '...' } else { $text }
        }
    }
    [pscustomobject]@{ Message = $message; ErrorCode = $errorCode }
}

function Get-NeoIPCDhis2TokenHint {
    # What to do about the token when DHIS2 refuses its checksum, or nothing: the sentence the error of a refused GET or
    # DELETE (New-NeoIPCDhis2HttpError) and the summary of a refused metadata import (Import-NeoIPCMetadata) append to
    # DHIS2's message. DHIS2 2.41 and later check the CRC32 over the whole 35-byte (version 1) or 48-byte (version 2)
    # buffer the UTF-8 encoder allocates for the token's 32 or 44 random characters, trailing zero bytes included, which
    # no token 2.40 issued passes, and answer 400 "Checksum validation failed" before any controller runs. The hint never
    # shows the token.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [int]$StatusCode,
        [AllowNull()][AllowEmptyString()][string]$Message,
        [hashtable]$Auth
    )
    if ($StatusCode -ne 400 -or $Message -notmatch 'Checksum validation failed' -or -not $Auth -or $Auth.AuthType -ne 'Token') { return }
    # NEOIPC-COMPAT(dhis2-version-1-token): the d2pat_ hint; see Test-DHIS2PersonalAccessToken in Public/Auth.ps1, without
    # whose version-1 branch no such token reaches DHIS2.
    if (([string]$Auth.Token).StartsWith('d2pat_', [System.StringComparison]::Ordinal)) {
        return 'The token is a version-1 token (d2pat_), which only DHIS2 2.40 and earlier issued and which 2.41 and later refuse: create a new token on this instance.'
    }
    'The token''s checksum does not match its text: check that the whole token was copied.'
}

function New-NeoIPCDhis2HttpError {
    # The error a refused DHIS2 request ends with: an HttpRequestException whose StatusCode is the failing status, whose
    # Data['Dhis2ErrorCode'] holds DHIS2's errorCode when the body names one, and whose Data['Dhis2Message'] holds DHIS2's
    # message, in the category a caller acts on (AuthenticationError for 401, PermissionDenied for 403, ObjectNotFound for
    # 404). A refused token checksum adds what to do about the token (Get-NeoIPCDhis2TokenHint). The status comes from
    # [System.Enum]::ToObject, since a cast refuses a status .NET does not name, such as a proxy's 522.
    [CmdletBinding()]
    [OutputType([System.Management.Automation.ErrorRecord])]
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$StatusCode,
        [AllowNull()][AllowEmptyString()][string]$Message,
        [AllowNull()][AllowEmptyString()][string]$ErrorCode,
        [hashtable]$Auth
    )
    $text = "$Method '$Path' failed with HTTP $StatusCode$(if ($ErrorCode) { " ($ErrorCode)" })$(if ($Message) { ": $Message" } else { '.' })"
    $hint = Get-NeoIPCDhis2TokenHint -StatusCode $StatusCode -Message $Message -Auth $Auth
    if ($hint) { $text = "$($text.TrimEnd('.')). $hint" }
    $exception = [System.Net.Http.HttpRequestException]::new($text, $null, [System.Enum]::ToObject([System.Net.HttpStatusCode], $StatusCode))
    $exception.Data['Dhis2ErrorCode'] = $ErrorCode
    $exception.Data['Dhis2Message'] = $Message
    $category = switch ($StatusCode) {
        401 { [System.Management.Automation.ErrorCategory]::AuthenticationError }
        403 { [System.Management.Automation.ErrorCategory]::PermissionDenied }
        404 { [System.Management.Automation.ErrorCategory]::ObjectNotFound }
        default { [System.Management.Automation.ErrorCategory]::InvalidOperation }
    }
    [System.Management.Automation.ErrorRecord]::new($exception, "NeoIPCDhis2$($Method.Substring(0, 1).ToUpperInvariant())$($Method.Substring(1).ToLowerInvariant())Failed", $category, $Path)
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
    <#
    .SYNOPSIS
        GET a DHIS2 API path and return the parsed JSON body, or end with an error carrying the HTTP status.
    .DESCRIPTION
        A status outside 2xx throws New-NeoIPCDhis2HttpError's error, whose message holds DHIS2's own message (or an
        excerpt of a non-JSON error page). A 2xx body that is not JSON throws too, since a reader would otherwise find
        none of the keys it looks for and take the answer as empty. A request that never reaches DHIS2 (name
        resolution, TLS, a refused connection) throws that failure's message. Each failure is thrown rather than raised
        with ThrowTerminatingError: that error ends only the statement that called this function, so a caller with no
        try around it would go on with an empty answer.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Auth,

        [Parameter(Mandatory)]
        [string]$Path,

        [string]$Scheme = 'https',
        [string]$Hostname,
        [Nullable[int]]$Port = $null,

        [string[]]$Fields,
        [string[]]$Filter,
        # One value per key. A list goes in pre-joined with the separator its parameter takes, which differs between
        # parameters and DHIS2 versions (Get-NeoIPCTrackerDialect), so an array is refused rather than joined.
        [hashtable]$QueryParameters,

        # Parse the body into ordered dictionaries and keep every date as the server's own text. Invoke-RestMethod
        # turns DHIS2's timestamps into [datetime], and a value written back from one (a `created` a deployment
        # preserves) is then re-serialized by .NET rather than passed through as DHIS2 stored it.
        [switch]$AsHashtable,

        # Read only the first page, of this many items, instead of every item: for a question one item answers.
        [Nullable[int]]$PageSize = $null
    )

    $Hostname = Resolve-NeoIPCDhis2Hostname -Hostname $Hostname
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
            $value = $QueryParameters[$key]
            if ($value -is [System.Collections.IEnumerable] -and $value -isnot [string]) {
                throw "The query parameter '$key' holds a list; join it with the separator the parameter takes."
            }
            $queryParts.Add("${key}=$([System.Net.WebUtility]::UrlEncode([string]$value))")
        }
    }

    $uri = New-NeoIPCDhis2Uri -Scheme $Scheme -Hostname $Hostname -Port $Port -Path $Path -QueryPart $queryParts

    $invokeParams = @{
        Method             = 'Get'
        Uri                = $uri
        SkipHttpErrorCheck = $true
        ErrorAction        = 'Stop'
    }
    # -AllowUnencrypted so Basic auth works over the local http dev/test stack, matching the POST helper
    # (harmless over https — it only permits, never forces, unencrypted Basic auth).
    Set-NeoIPCDhis2Auth -InvokeParams $invokeParams -Auth $Auth -AllowUnencrypted

    if ($PSCmdlet.ShouldProcess(
            "GET $uri",
            "Fetch DHIS2 data via GET $uri?",
            'Fetching DHIS2 data')) {
        Write-Debug "GET $uri"
        try { $response = Invoke-WebRequest @invokeParams }
        catch { throw "Failed to fetch '$Path' from DHIS2 ($uri): $($_.Exception.Message)" }
        $content = $response.Content
        if ($content -is [byte[]]) { $content = [System.Text.Encoding]::UTF8.GetString($content) }
        $status = [int]$response.StatusCode
        if ($status -lt 200 -or $status -ge 300) {
            $detail = Get-NeoIPCDhis2ErrorDetail -Content $content
            throw (New-NeoIPCDhis2HttpError -Method 'GET' -Path $Path -StatusCode $status -Message $detail.Message -ErrorCode $detail.ErrorCode -Auth $Auth)
        }
        if ([string]::IsNullOrWhiteSpace($content)) { return }
        try {
            if ($AsHashtable) { return ($content | ConvertFrom-Json -AsHashtable -DateKind String -ErrorAction Stop) }
            $content | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            throw "DHIS2 answered GET '$Path' with a body that is not JSON: $((Get-NeoIPCDhis2ErrorDetail -Content $content).Message)"
        }
    }
}

function Get-NeoIPCDhis2StatusCode {
    # The HTTP status of a GET, without throwing on 4xx/5xx: 200 when the object exists, 404 when it does not. The
    # read-back that proves a metadata delete, since DHIS2 can answer a DELETE with 200 and keep the object. For a
    # tracked entity a 404 alone proves nothing from DHIS2 2.42 on, which answers it for one the caller cannot see too.
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][hashtable]$Auth,
        [Parameter(Mandatory)][string]$Path,
        [string]$Scheme = 'https',
        [string]$Hostname,
        [Nullable[int]]$Port = $null
    )
    $Hostname = Resolve-NeoIPCDhis2Hostname -Hostname $Hostname
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
        caller can decide per object (catch and continue) or per status (stop at the first 401). It is thrown, as
        Invoke-NeoIPCDhis2Get's are and for the same reason, so a caller without a try stops. A 200 proves only that
        DHIS2 accepted the request: DHIS2 2.41.10 and later answer a program stage section's DELETE with 200 and keep
        the section, so a caller that must know the object is gone reads it back.
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
        [string]$Hostname,
        [Nullable[int]]$Port = $null,

        [switch]$AllowUnencrypted
    )

    $Hostname = Resolve-NeoIPCDhis2Hostname -Hostname $Hostname
    $uri = New-NeoIPCDhis2Uri -Scheme $Scheme -Hostname $Hostname -Port $Port -Path $Path

    $invokeParams = @{
        Method             = 'Delete'
        Uri                = $uri
        SkipHttpErrorCheck = $true
        ErrorAction        = 'Stop'
    }
    Set-NeoIPCDhis2Auth -InvokeParams $invokeParams -Auth $Auth -AllowUnencrypted:$AllowUnencrypted

    # Low-level ShouldProcess — callers typically suppress this with -Confirm:$false
    # and implement their own higher-level confirmation
    if ($PSCmdlet.ShouldProcess(
            "DELETE $uri",
            "Delete DHIS2 data via DELETE $uri?",
            'Removing DHIS2 data')) {
        Write-Debug "DELETE $uri"
        try { $($response = . { Invoke-WebRequest @invokeParams }) 4>&1 | Write-Debug }
        catch { throw "Failed to send DELETE '$Path' to DHIS2 ($uri): $($_.Exception.Message)" }
        $content = $response.Content
        if ($content -is [byte[]]) { $content = [System.Text.Encoding]::UTF8.GetString($content) }
        $result = $null
        if (-not [string]::IsNullOrWhiteSpace($content)) {
            $result = try { $content | ConvertFrom-Json -ErrorAction Stop } catch { $content }
        }

        $statusCode = [int]$response.StatusCode
        $bodyStatus = if ($result -and $result -isnot [string] -and $result.PSObject.Properties['httpStatusCode']) { [int]$result.httpStatusCode } else { $null }
        $failedStatus = if ($statusCode -lt 200 -or $statusCode -ge 300) { $statusCode }
        elseif ($null -ne $bodyStatus -and ($bodyStatus -lt 200 -or $bodyStatus -ge 300)) { $bodyStatus }
        else { $null }
        if ($null -ne $failedStatus) {
            $detail = Get-NeoIPCDhis2ErrorDetail -Content $content
            throw (New-NeoIPCDhis2HttpError -Method 'DELETE' -Path $Path -StatusCode $failedStatus -Message $detail.Message -ErrorCode $detail.ErrorCode -Auth $Auth)
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
        [string]$Hostname,
        [Nullable[int]]$Port = $null,

        [Parameter(Mandatory)][string]$Body,
        [string]$ContentType = 'application/json'
    )
    $Hostname = Resolve-NeoIPCDhis2Hostname -Hostname $Hostname
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
        [string]$Hostname,
        [Nullable[int]]$Port = $null,

        [string]$Body,
        [string]$ContentType = 'application/json',
        [hashtable]$QueryParameters
    )

    $Hostname = Resolve-NeoIPCDhis2Hostname -Hostname $Hostname
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
