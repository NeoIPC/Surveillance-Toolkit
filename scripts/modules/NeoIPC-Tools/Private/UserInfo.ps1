#Requires -Version 7.6
# What Read-UserInfo reads and derives beside the user accounts themselves: where a DHIS2 release reports other users'
# two-factor state, that state, the link to a user's page in the Users app, and the sorted lists of a user's org units,
# roles, and groups.

function Get-NeoIPCUserTwoFactorSource {
    # Where DHIS2 -Version reports other users' two-factor state:
    #   1. 'UserField', 2.41 and earlier: the user's twoFactorEnabled field, true while the user has a secret for
    #      time-based one-time passwords (TOTP). DHIS2 stores the secret when the user asks for the QR code
    #      (generateTwoFactorOtpSecretForApproval), before the user confirms the enrolment with a code, so a pending
    #      enrolment counts as enabled. 2.42.0 and later do not serialize the field (User.isTwoFactorEnabled is
    #      @JsonIgnore there).
    #   2. 'AuditEndpoint', 2.42.6 and later in the 2.42 line, 2.43.1 and later in the 2.43 line, and every later line:
    #      api/users/twoFactor (UserTwoFactorAuditController), read by Read-NeoIPCUserTwoFactorState.
    #   3. 'None', 2.42.0 to 2.42.5.x and 2.43.0.x, which report no other user's state at all.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][version]$Version)
    # NEOIPC-COMPAT(dhis2-user-twofactorenabled): remove source 1 once no supported instance runs 2.41 or earlier
    # (/api/system/info version 2.42 or later everywhere).
    if ($Version -lt [version]'2.42.0') { return 'UserField' }
    # NEOIPC-COMPAT(dhis2-user-twofactor-audit-floor): remove source 3 once no supported instance runs 2.42.0 to 2.42.5.x
    # or 2.43.0.x (/api/system/info version 2.42.6, 2.43.1, or later everywhere).
    $floor = switch ('{0}.{1}' -f $Version.Major, $Version.Minor) {
        '2.42' { [version]'2.42.6' }
        '2.43' { [version]'2.43.1' }
        default { $null }
    }
    if ($floor -and $Version -lt $floor) { return 'None' }
    'AuditEndpoint'
}

function Read-NeoIPCUserTwoFactorState {
    # The two-factor type (twoFactorType: NOT_ENABLED, TOTP_ENABLED, EMAIL_ENABLED, ENROLLING_TOTP, ENROLLING_EMAIL) of
    # every account api/users/twoFactor lists, by user UID, or nothing after a warning that says why. DHIS2 serves the
    # endpoint to accounts with the authority ALL only (@RequiresAuthority(anyOf = ALL), so 403 for any other), answers
    # {pager, users: [{id, username, name, twoFactorType, lastLogin, email, disabled, invitation}]}, lists only active
    # accounts (neither disabled nor an invitation), and caps an answer with paging=false at 10,000 accounts, which the
    # pager's total then exceeds.
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.Dictionary[string, string]])]
    param([Parameter(Mandatory)][hashtable]$Endpoint)
    try {
        $answer = Invoke-NeoIPCDhis2Get @Endpoint -Path 'api/users/twoFactor' -AsHashtable -Confirm:$false -WhatIf:$false
    }
    catch {
        $failure = $_
        $status = if ($failure.Exception -is [System.Net.Http.HttpRequestException]) { [int]$failure.Exception.StatusCode } else { 0 }
        $reason = switch ($status) {
            403 { 'DHIS2 shows other users'' two-factor state (api/users/twoFactor) only to accounts with the authority ALL' }
            404 { 'DHIS2 answered api/users/twoFactor with HTTP 404' }
            default { "reading api/users/twoFactor failed: $($failure.Exception.Message)" }
        }
        Write-Warning "TwoFactorEnabled is empty for every user: $reason."
        return
    }
    if ($answer -isnot [System.Collections.IDictionary] -or $answer['users'] -isnot [System.Collections.IList]) {
        Write-Warning 'TwoFactorEnabled is empty for every user: DHIS2 answered api/users/twoFactor without a users list.'
        return
    }
    $states = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    foreach ($row in $answer['users']) {
        if ($row -isnot [System.Collections.IDictionary] -or [string]::IsNullOrEmpty([string]$row['id'])) { continue }
        $states[[string]$row['id']] = [string]$row['twoFactorType']
    }
    $pager = $answer['pager']
    if ($pager -is [System.Collections.IDictionary] -and $null -ne $pager['total'] -and [long]$pager['total'] -gt $states.Count) {
        Write-Warning "DHIS2 lists at most 10,000 accounts in one answer of api/users/twoFactor, and listed $($states.Count) of $($pager['total']): TwoFactorEnabled is empty for the accounts it left out."
    }
    $states
}

function Get-NeoIPCUserEditUrl {
    # The link to a user's page in the Users app, whose route is #/users/edit/<id>. DHIS2 2.42 and later serve apps at
    # /apps/<name> inside the global shell, which passes the hash on to the app; 2.41 and earlier serve the Users app at
    # dhis-web-user/index.html.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][version]$Version,
        [Parameter(Mandatory)][string]$UserId
    )
    # NEOIPC-COMPAT(dhis2-legacy-app-path): remove the dhis-web-user link once no supported instance runs 2.41 or earlier
    # (/api/system/info version 2.42 or later everywhere).
    if ($Version -lt [version]'2.42.0') { return "$BaseUrl/dhis-web-user/index.html#/users/edit/$UserId" }
    "$BaseUrl/apps/user#/users/edit/$UserId"
}

function ConvertTo-NeoIPCSortedText {
    # The non-empty values of one property of a list of records, in ordinal order, as one String[] (empty when there
    # are none): the codes or names of a user's org units, roles, or groups.
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowNull()][AllowEmptyCollection()][object[]]$InputObject,
        [Parameter(Mandatory)][string]$Property
    )
    $values = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @($InputObject)) {
        if ($item -isnot [System.Collections.IDictionary]) { continue }
        $value = [string]$item[$Property]
        if (-not [string]::IsNullOrEmpty($value)) { $values.Add($value) }
    }
    $sorted = $values.ToArray()
    [Array]::Sort($sorted, [System.StringComparer]::Ordinal)
    , $sorted
}
