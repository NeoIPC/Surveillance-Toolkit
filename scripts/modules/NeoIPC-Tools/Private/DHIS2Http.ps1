# Private DHIS2 HTTP layer — not exported from the module.
# All public functions that call the DHIS2 API should go through these two functions.

function Invoke-NeoipcDhis2Get {
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

    $uriBuilder.Query = ($queryParts -join '&')

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

function Invoke-NeoipcDhis2Delete {
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
