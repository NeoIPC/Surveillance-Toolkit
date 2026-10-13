#Requires -Version 7.6
# The personal access tokens of a DHIS2 instance (api/apiToken): read them, delete them, and delete the expired ones. A
# token is a sharing object, private by default (ApiTokenSchemaDescriptor), so DHIS2 lists for an account the tokens it
# created and any shared with it, while a superuser (authority ALL) bypasses sharing and sees every user's tokens.
# DHIS2 never serializes a token's key. A token is expired once its expire, in epoch milliseconds, is not after the
# present (ApiTokenAuthManager.validateTokenExpiry), and every token has one: the column is NOT NULL and the create
# endpoint fills in 30 days when the request gives none.

function Read-DHIS2PersonalAccessToken {
    <#
    .SYNOPSIS
        Read DHIS2 personal access tokens: your own, every user's with -AllUsers, or those -Id names.
    .DESCRIPTION
        By default, lists the tokens your account created, those whose creator is the account /api/me names. DHIS2
        lists every user's tokens to a superuser (authority ALL), so the cmdlet compares the creator itself.

        -AllUsers lists every token DHIS2 lets the account read: every user's for a superuser; for any other account
        only the tokens shared with it, which it then warns about.

        -Id reads exactly the tokens it names, whoever created them. An id that DHIS2 does not return, because no such
        token exists or your account cannot read it, is an error that names it, and so is an id that is no DHIS2 UID,
        which is never sent; a value that begins like a token itself (d2p_ or d2pat_) is not shown.

        DHIS2 never returns a token's key, so a token cannot be told from its key.
    .PARAMETER Id
        The UIDs of the tokens to read.
    .PARAMETER Filter
        DHIS2 metadata filters (property:operator:value) the read sends, such as 'id:eq:<UID>'; DHIS2 combines several
        with AND. Without -AllUsers the cmdlet still keeps only your own tokens of those DHIS2 returns.
    .PARAMETER AllUsers
        List every token DHIS2 lets the account read, not only its own.
    .PARAMETER Auth
        Auth hashtable from Resolve-NeoIPCAuth (Token or Basic). Without it, the credentials are resolved from -Token
        and -UserName.
    .PARAMETER Token
        A personal access token, or the path of a file whose first line is one, when -Auth is not given. When empty,
        the environment variable NEOIPC_DHIS2_TOKEN is read; with neither, you are asked for a username and password.
    .PARAMETER UserName
        The DHIS2 username to ask a password for when -Auth is not given and no token is available.
    .PARAMETER Scheme
        http or https. Default https.
    .PARAMETER Hostname
        The DHIS2 host. Default: the environment variable NEOIPC_DHIS2_HOST.
    .PARAMETER Port
        DHIS2 port. Default none (the scheme's).
    .OUTPUTS
        One [pscustomobject] per token: Id; Expire, the UTC time from which DHIS2 refuses the token (a time past the
        year 9999 shows as [datetime]::MaxValue); Created; CreatedBy, the creator's username; and AllowedMethods, the
        HTTP methods the token is limited to, empty when it is not limited.
    .EXAMPLE
        Read-DHIS2PersonalAccessToken -Auth $auth -Hostname dhis2.example.org

        Lists your own tokens.
    .EXAMPLE
        Read-DHIS2PersonalAccessToken -AllUsers -Auth $auth -Hostname dhis2.example.org |
            Where-Object Expire -le (Get-Date).ToUniversalTime()

        Lists every user's expired tokens (with the authority ALL).
    #>
    [CmdletBinding(DefaultParameterSetName = 'List')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0, ParameterSetName = 'Id')]
        [ValidateNotNullOrEmpty()]
        [string[]]$Id,

        [Parameter(ParameterSetName = 'List')]
        [string[]]$Filter,

        [Parameter(ParameterSetName = 'List')]
        [switch]$AllUsers,

        [hashtable]$Auth,
        [string]$Token,
        [string]$UserName,
        [string]$Scheme,
        [string]$Hostname,
        [Nullable[int]]$Port = $null
    )

    $fields = 'id', 'expire', 'created', 'createdBy[id,username]', 'attributes'
    $ordinal = [System.StringComparer]::Ordinal

    function Get-TokenList($Response) {
        if ($null -eq $Response -or -not $Response.PSObject.Properties['apiToken']) {
            throw 'The personal access token read did not return an apiToken list.'
        }
        @($Response.apiToken | Where-Object { $null -ne $_ })
    }
    function ConvertTo-TokenRecord($Item) {
        $expire = $null
        if ($null -ne $Item.expire) {
            $milliseconds = [long]$Item.expire
            # DHIS2 takes any long, and [datetime] ends with the year 9999.
            $expire = if ($milliseconds -gt 253402300799999) { [datetime]::SpecifyKind([datetime]::MaxValue, 'Utc') }
            elseif ($milliseconds -lt -62135596800000) { [datetime]::SpecifyKind([datetime]::MinValue, 'Utc') }
            else { [System.DateTimeOffset]::FromUnixTimeMilliseconds($milliseconds).UtcDateTime }
        }
        $methods = @(@($Item.attributes) | Where-Object { $null -ne $_ -and [string]$_.type -ceq 'MethodAllowedList' } |
                ForEach-Object { @($_.allowedMethods) } | Where-Object { $_ } | ForEach-Object { [string]$_ })
        [pscustomobject]@{
            Id             = [string]$Item.id
            Expire         = $expire
            Created        = $Item.created
            CreatedBy      = $Item.createdBy.username
            AllowedMethods = [string[]]$methods
        }
    }

    # A failed request ends the cmdlet as a whole: a terminating error from a helper ends only the statement it stands in,
    # and the rest would go on without the answer.
    try {
        $wanted = [System.Collections.Generic.List[string]]::new()
        $seen = [System.Collections.Generic.HashSet[string]]::new($ordinal)
        foreach ($i in $Id) {
            if (-not (Test-NeoIPCMetadataUid -Id $i)) {
                $shown = Format-NeoIPCMessageValue -Value $i
                Write-Error -Message "'$shown' is no DHIS2 UID, so it names no personal access token; it was not sent." -Category ObjectNotFound `
                    -ErrorId 'NeoIPCPersonalAccessTokenNotFound' -TargetObject $shown
                continue
            }
            if ($seen.Add($i)) { $wanted.Add($i) }
        }
        if ($PSCmdlet.ParameterSetName -eq 'Id' -and $wanted.Count -eq 0) { return }

        if (-not $Auth) { $Auth = Resolve-NeoIPCAuth -Token $Token -UserName $UserName }
        $endpoint = @{ Auth = $Auth }
        if ($Scheme) { $endpoint.Scheme = $Scheme }
        if ($Hostname) { $endpoint.Hostname = $Hostname }
        if ($null -ne $Port) { $endpoint.Port = $Port }

        if ($PSCmdlet.ParameterSetName -eq 'Id') {
            $found = [System.Collections.Generic.Dictionary[string, object]]::new($ordinal)
            if ($wanted.Count -eq 1) {
                $single = $null
                try { $single = Invoke-NeoIPCDhis2Get @endpoint -Path "api/apiToken/$($wanted[0])" -Fields $fields -Confirm:$false -WhatIf:$false }
                catch {
                    if (-not ($_.Exception -is [System.Net.Http.HttpRequestException] -and [int]$_.Exception.StatusCode -eq 404)) { throw }
                }
                if ($null -ne $single -and [string]$single.id -ceq $wanted[0]) { $found[$wanted[0]] = $single }
            }
            elseif ($wanted.Count -gt 1) {
                foreach ($chunk in (Split-NeoIPCList -Value $wanted.ToArray() -Separator ',')) {
                    $response = Invoke-NeoIPCDhis2Get @endpoint -Path 'api/apiToken' -Fields $fields -Filter "id:in:[$($chunk -join ',')]" -Confirm:$false -WhatIf:$false
                    foreach ($item in (Get-TokenList $response)) {
                        if ($seen.Contains([string]$item.id)) { $found[[string]$item.id] = $item }
                    }
                }
            }
            foreach ($i in $wanted) {
                if ($found.ContainsKey($i)) { ConvertTo-TokenRecord $found[$i] }
                else {
                    Write-Error -Message "DHIS2 returned no personal access token with the id '$i': none exists, or your account cannot read it." `
                        -Category ObjectNotFound -ErrorId 'NeoIPCPersonalAccessTokenNotFound' -TargetObject $i
                }
            }
            return
        }

        $me = Invoke-NeoIPCDhis2Get @endpoint -Path 'api/me' -Fields 'id', 'authorities' -Confirm:$false -WhatIf:$false
        $meId = [string]$me.id
        if (-not (Test-NeoIPCMetadataUid -Id $meId)) { throw 'DHIS2 did not name the id of your account (/api/me).' }
        if ($AllUsers -and @($me.authorities) -cnotcontains 'ALL') {
            Write-Warning 'Your account lacks the authority ALL, so DHIS2 lists only the personal access tokens shared with it, not every user''s.'
        }
        $response = Invoke-NeoIPCDhis2Get @endpoint -Path 'api/apiToken' -Fields $fields -Filter $Filter -Confirm:$false -WhatIf:$false
        foreach ($item in (Get-TokenList $response)) {
            if ($AllUsers -or [string]$item.createdBy.id -ceq $meId) { ConvertTo-TokenRecord $item }
        }
    }
    catch { $PSCmdlet.ThrowTerminatingError($_) }
}

function Remove-DHIS2PersonalAccessToken {
    <#
    .SYNOPSIS
        Delete DHIS2 personal access tokens, asking once for each.
    .DESCRIPTION
        Deletes each token -Id names, after asking for it (the default, since the impact is High), unless -Force or
        -Confirm:$false is given; -WhatIf deletes nothing. A declined token is skipped and the others go on. Each
        token's outcome is written as it happens.

        A failure that concerns one token, such as HTTP 403 for a token the account may not delete or 404 for one that
        does not exist, is that token's error, and the run goes on. HTTP 401 ends the run with a terminating error, and
        no later token is sent: DHIS2 no longer accepts the credentials, which is what happens once the run has deleted
        the token it authenticates with (DHIS2 2.41 and later at once; 2.40 once its token cache lets the token go, at
        most an hour later). An id that is no DHIS2 UID is an error and is never sent; a value that begins like a token
        itself (d2p_ or d2pat_) is not shown.
    .PARAMETER Id
        The UIDs of the tokens to delete. Takes pipeline input, such as Read-DHIS2PersonalAccessToken's output.
    .PARAMETER Auth
        Auth hashtable from Resolve-NeoIPCAuth (Token or Basic). Without it, the credentials are resolved once from
        -Token and -UserName.
    .PARAMETER Token
        A personal access token, or the path of a file whose first line is one, when -Auth is not given. When empty,
        the environment variable NEOIPC_DHIS2_TOKEN is read; with neither, you are asked for a username and password.
    .PARAMETER UserName
        The DHIS2 username to ask a password for when -Auth is not given and no token is available.
    .PARAMETER Scheme
        http or https. Default https.
    .PARAMETER Hostname
        The DHIS2 host. Mandatory, with no default, so that a deletion always names its target.
    .PARAMETER Port
        DHIS2 port. Default none (the scheme's).
    .PARAMETER Force
        Delete without asking, unless -Confirm is given as well.
    .PARAMETER WhatIf
        Show which tokens would be deleted, and delete none.
    .PARAMETER Confirm
        Ask before each token, -Force notwithstanding; -Confirm:$false deletes without asking.
    .OUTPUTS
        One [pscustomobject] per token: Id; Outcome, one of Deleted, WouldDelete (under -WhatIf), Declined, and Failed;
        HttpStatusCode, the status of a failed deletion; and Message, the reason it failed.
    .EXAMPLE
        Remove-DHIS2PersonalAccessToken -Id 'aBcDeFgHiJ1' -Auth $auth -Hostname dhis2.example.org

        Deletes the token after asking.
    .EXAMPLE
        Read-DHIS2PersonalAccessToken -Auth $auth -Hostname dhis2.example.org | Remove-DHIS2PersonalAccessToken -Auth $auth -Hostname dhis2.example.org -WhatIf

        Shows which of your own tokens a deletion would take, and deletes nothing.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Id,

        [hashtable]$Auth,
        [string]$Token,
        [string]$UserName,
        [string]$Scheme = 'https',

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Hostname,

        [Nullable[int]]$Port = $null,
        [switch]$Force
    )

    begin {
        if ($Force -and -not $PSBoundParameters.ContainsKey('Confirm')) { $ConfirmPreference = 'None' }
        if (-not $Auth) { $Auth = Resolve-NeoIPCAuth -Token $Token -UserName $UserName }
        $endpoint = @{ Auth = $Auth; Scheme = $Scheme; Hostname = $Hostname }
        if ($null -ne $Port) { $endpoint.Port = $Port }
        $target = '{0}://{1}{2}' -f $Scheme, $Hostname, $(if ($null -ne $Port) { ":$Port" })
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        function New-Outcome([string]$TokenId, [string]$Outcome, $HttpStatusCode = $null, [string]$Message = $null) {
            [pscustomobject]@{ Id = $TokenId; Outcome = $Outcome; HttpStatusCode = $HttpStatusCode; Message = $Message }
        }
    }

    process {
        foreach ($currentId in $Id) {
            if (-not $seen.Add($currentId)) { continue }
            if (-not (Test-NeoIPCMetadataUid -Id $currentId)) {
                $shown = Format-NeoIPCMessageValue -Value $currentId
                $message = "'$shown' is no DHIS2 UID, so it names no personal access token; it was not sent."
                Write-Error -Message $message -Category ObjectNotFound -ErrorId 'NeoIPCPersonalAccessTokenNotFound' -TargetObject $shown
                New-Outcome $shown 'Failed' -Message $message
                continue
            }
            $reason = [System.Management.Automation.ShouldProcessReason]::None
            if (-not $PSCmdlet.ShouldProcess("Deleting the personal access token '$currentId' on $target.",
                    "Delete the personal access token '$currentId' on ${target}?", 'Delete personal access token', [ref]$reason)) {
                New-Outcome $currentId $(if ($reason -eq [System.Management.Automation.ShouldProcessReason]::WhatIf) { 'WouldDelete' } else { 'Declined' })
                continue
            }
            try {
                $null = Invoke-NeoIPCDhis2Delete @endpoint -Path "api/apiToken/$currentId" -AllowUnencrypted -Confirm:$false -WhatIf:$false
            }
            catch {
                $status = if ($_.Exception -is [System.Net.Http.HttpRequestException] -and $null -ne $_.Exception.StatusCode) { [int]$_.Exception.StatusCode }
                New-Outcome $currentId 'Failed' $status $_.Exception.Message
                if ($status -eq 401) {
                    $exception = [System.Net.Http.HttpRequestException]::new(
                        "DHIS2 no longer accepts the credentials (HTTP 401) at the personal access token '$currentId', so no later token was sent. This happens once the run has deleted the token it authenticates with; delete the rest with other credentials.",
                        $_.Exception, [System.Net.HttpStatusCode]::Unauthorized)
                    $PSCmdlet.ThrowTerminatingError([System.Management.Automation.ErrorRecord]::new($exception, 'NeoIPCDhis2CredentialsRejected',
                            [System.Management.Automation.ErrorCategory]::AuthenticationError, $currentId))
                }
                $PSCmdlet.WriteError($_)
                continue
            }
            New-Outcome $currentId 'Deleted'
        }
    }
}

function Clear-DHIS2PersonalAccessTokens {
    <#
    .SYNOPSIS
        Delete your expired DHIS2 personal access tokens, or with -All every one of them.
    .DESCRIPTION
        Reads the tokens as Read-DHIS2PersonalAccessToken does (your own, or with -AllUsers every token DHIS2 lets the
        account read) and deletes the expired ones, those whose expiry is not after the present, which DHIS2 refuses;
        a token without an expiry never counts as expired. -All deletes them whether expired or not, the token the run
        authenticates with included when it is among them.

        The deletion is Remove-DHIS2PersonalAccessToken's, with the same credentials, which are resolved once: it asks
        once for each token unless -Force or -Confirm:$false is given, -WhatIf deletes nothing, and HTTP 401 ends the
        run, which happens once it has deleted the token it authenticates with.
    .PARAMETER All
        Delete every token read, expired or not.
    .PARAMETER AllUsers
        Read every token DHIS2 lets the account read, not only its own: every user's with the authority ALL.
    .PARAMETER Force
        Delete without asking, unless -Confirm is given as well.
    .PARAMETER Auth
        Auth hashtable from Resolve-NeoIPCAuth (Token or Basic). Without it, the credentials are resolved once from
        -Token and -UserName.
    .PARAMETER Token
        A personal access token, or the path of a file whose first line is one, when -Auth is not given. When empty,
        the environment variable NEOIPC_DHIS2_TOKEN is read; with neither, you are asked for a username and password.
    .PARAMETER UserName
        The DHIS2 username to ask a password for when -Auth is not given and no token is available.
    .PARAMETER Scheme
        http or https. Default https.
    .PARAMETER Hostname
        The DHIS2 host. Mandatory, with no default, so that a deletion always names its target.
    .PARAMETER Port
        DHIS2 port. Default none (the scheme's).
    .PARAMETER WhatIf
        Show which tokens would be deleted, and delete none.
    .PARAMETER Confirm
        Ask before each token, -Force notwithstanding; -Confirm:$false deletes without asking.
    .OUTPUTS
        Remove-DHIS2PersonalAccessToken's outcome for each token it was given.
    .EXAMPLE
        Clear-DHIS2PersonalAccessTokens -Auth $auth -Hostname dhis2.example.org -WhatIf

        Shows which of your expired tokens would be deleted, and deletes nothing.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '',
        Justification = 'The confirmation is Remove-DHIS2PersonalAccessToken''s, one per token, to which -WhatIf and -Confirm are passed on.')]
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [switch]$All,
        [switch]$AllUsers,
        [switch]$Force,

        [hashtable]$Auth,
        [string]$Token,
        [string]$UserName,
        [string]$Scheme = 'https',

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Hostname,

        [Nullable[int]]$Port = $null
    )

    # The read's or the deletion's terminating error ends the cmdlet, not only the statement it stands in.
    try {
        if (-not $Auth) { $Auth = Resolve-NeoIPCAuth -Token $Token -UserName $UserName }
        $connection = @{ Auth = $Auth; Scheme = $Scheme; Hostname = $Hostname }
        if ($null -ne $Port) { $connection.Port = $Port }

        # ForEach-Object's -MemberName form asks ShouldProcess itself, so under -WhatIf it would yield nothing and under
        # -Confirm take the answers meant for the deletions: the script block form does not.
        $now = [datetime]::UtcNow
        $ids = @(Read-DHIS2PersonalAccessToken @connection -AllUsers:$AllUsers |
                Where-Object { $All -or ($null -ne $_.Expire -and $_.Expire -le $now) } | ForEach-Object { $_.Id })
        if ($ids.Count -eq 0) { return }

        $removal = @{ Force = $Force; WhatIf = $WhatIfPreference }
        if ($PSBoundParameters.ContainsKey('Confirm')) { $removal.Confirm = $PSBoundParameters['Confirm'] }
        $ids | Remove-DHIS2PersonalAccessToken @connection @removal
    }
    catch { $PSCmdlet.ThrowTerminatingError($_) }
}

New-Alias -Name Read-PAT -Value Read-DHIS2PersonalAccessToken -Force
New-Alias -Name Remove-PAT -Value Remove-DHIS2PersonalAccessToken -Force
New-Alias -Name Clear-PATs -Value Clear-DHIS2PersonalAccessTokens -Force
