#Requires -Version 7.6

<#
.SYNOPSIS
List DHIS2 user accounts, all of them or those assigned to given org units, with their org units, roles,
groups, state, and two-factor state.

.DESCRIPTION
Reads the DHIS2 release (api/system/info) and the user accounts DHIS2 lets your account list (api/users):
all of them, or, with -OrgUnitCode, those whose data-capture org units include one of the given org units.
Each code must name an org unit in your hierarchy, which is your account's data-capture org units (api/me)
and the org units below them; the cmdlet writes an error naming each code that does not, and when no code
given names one, it reads no users. Codes compare exactly, case included, and an empty one names nothing.
When the cmdlet expects pipeline input and receives none, it returns nothing and reads nothing.

Listing users needs the authority F_USER_VIEW, which ALL includes. Without it, DHIS2 answers HTTP 403 and
the cmdlet stops with an error that names the authority.

Which accounts DHIS2 lists changed with 2.42. On 2.41 and earlier, an account without the authority ALL
does not see the accounts that hold any of its own user roles, itself included, unless the system setting
that lets users grant their own user roles (keyCanGrantOwnUserAuthorityGroups) is on; the cmdlet reads
your account's authorities there and warns once when ALL is not among them, whatever the setting. From
2.42, such an account sees them as well.

Where TwoFactorEnabled comes from depends on the release:
  1. 2.41 and earlier: the user's twoFactorEnabled field. It counts an account as enabled from the moment
     its user asks for the QR code that sets up an authenticator app, before the user confirms the
     enrolment with a code from the app.
  2. 2.42.6 and later patches of 2.42, 2.43.1 and later patches of 2.43, and every later release:
     api/users/twoFactor. True for an account that has confirmed two-factor authentication by
     authenticator app (time-based one-time passwords, TOTP) or by email, false for one that has not,
     including one that is still enrolling, and empty for a disabled account or an invitation, which DHIS2
     does not list there. DHIS2 shows this list only to accounts with the authority ALL: for any other,
     the column is empty and a warning says why. One answer lists at most 10,000 accounts, and a warning
     says when DHIS2 left accounts out.
  3. 2.42.0 to 2.42.5 and 2.43.0, their hotfix releases (such as 2.42.5.2) included: DHIS2 shows no other
     user's two-factor state. The column is empty, and a warning names the first patches that do (2.42.6
     and 2.43.1).

EditUrl links to the user's page in the Users app: dhis-web-user/index.html on 2.41 and earlier, apps/user
from 2.42.

.PARAMETER OrgUnitCode
Codes of the org units whose users to read: those whose data-capture org units include one of them.
Pipeline-bound by property name, so Read-OrgUnitInfo | Read-UserInfo returns the users of those
departments.

.PARAMETER Auth
Auth hashtable from Resolve-NeoIPCAuth (Token or Basic). Given, -Token and -UserName are not used, and
nothing is asked for.

.PARAMETER Token
A DHIS2 personal access token, or the path of a file that holds one, for Resolve-NeoIPCAuth when -Auth is
not given. Without either, Resolve-NeoIPCAuth decides where the credentials come from.

.PARAMETER UserName
The user name for Basic authentication, passed to Resolve-NeoIPCAuth when -Auth is not given and no token
is available; the password is then asked for.

.PARAMETER Scheme
http or https. Default https.

.PARAMETER Hostname
The DHIS2 host. Without it, the NEOIPC_DHIS2_HOST environment variable; with neither, the call stops.

.PARAMETER Port
The DHIS2 port. Default: the scheme's.

.OUTPUTS
System.Management.Automation.PSCustomObject. One per user, in ordinal order of Username: UserId, Username,
FirstName, Surname, Email, PhoneNumber, Employer; OrganisationUnits, DataViewOrganisationUnits, and
TeiSearchOrganisationUnits (the codes of the user's data-capture, data-view, and search org units),
UserRoles, and UserGroups (names), each a String[] in ordinal order; Created, CreatedBy, LastUpdated,
LastUpdatedBy, PasswordLastUpdated, and LastLogin (dates as DateTime, the others user names); Invitation,
Disabled, TwoFactorEnabled (Boolean, or empty where DHIS2 does not show it), SelfRegistered, and EditUrl.

.EXAMPLE
Read-OrgUnitInfo -Auth $auth -CountryCode AT | Read-UserInfo -Auth $auth

The users whose data-capture org units include an Austrian department in your hierarchy.

.EXAMPLE
Read-UserInfo -Auth $auth | Where-Object { $_.TwoFactorEnabled -eq $false } | Select-Object Username, LastLogin, EditUrl

The accounts DHIS2 reports without two-factor authentication, with links to their pages.
#>
function Read-UserInfo {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0, ValueFromPipelineByPropertyName)]
        [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
            $serverKey = Get-NeoIPCServerKey -Scheme $fakeBoundParameters['Scheme'] -Hostname $fakeBoundParameters['Hostname'] -Port $fakeBoundParameters['Port']
            $cacheDir = Join-Path $script:NeoIPCRepoRoot 'data' $serverKey
            $cacheFile = Join-Path $cacheDir 'site-codes.txt'
            if (Test-Path $cacheFile) {
                Get-Content $cacheFile | Where-Object { $_ -like "$wordToComplete*" }
            }
        })]
        [string[]]$OrgUnitCode,

        [Parameter()]
        [hashtable]$Auth,

        [Parameter()]
        [string]$Token,

        [Parameter()]
        [string]$UserName,

        [Parameter()] [string]$Scheme = $null,
        [Parameter()] [string]$Hostname = $null,
        [Parameter()] [Nullable[int]]$Port = $null
    )

    begin {
        $codes = [System.Collections.Generic.List[string]]::new()
        $selectorGiven = $false
    }

    process {
        if ($PSBoundParameters.ContainsKey('OrgUnitCode')) {
            $selectorGiven = $true
            foreach ($c in $OrgUnitCode) { if (-not [string]::IsNullOrEmpty($c)) { $codes.Add($c) } }
        }
    }

    end {
        # A failure ends the cmdlet with an error of its own: an error a helper throws would otherwise end the caller's
        # whole script, or, under -ErrorAction SilentlyContinue, be dropped and leave the read running on nothing.
        try {
            if (($MyInvocation.ExpectingInput -or $selectorGiven) -and $codes.Count -eq 0) { return }
            if (-not $Auth) { $Auth = Resolve-NeoIPCAuth -Token $Token -UserName $UserName }
            $endpoint = @{ Auth = $Auth }
            if ($Scheme) { $endpoint.Scheme = $Scheme }
            if ($Hostname) { $endpoint.Hostname = $Hostname }
            if ($null -ne $Port) { $endpoint.Port = $Port }
            $ordinal = [System.StringComparer]::Ordinal

            # One read per chunk of the org units' UIDs. Resolve-NeoIPCOrgUnit looks the codes up, and a UID holds no ','
            # that DHIS2 would split an `in` list or, from 2.42 on, the filter parameter on, as it would a code.
            $reads = [System.Collections.Generic.List[hashtable]]::new()
            if ($codes.Count -gt 0) {
                $found = Resolve-NeoIPCOrgUnit -Endpoint $endpoint -Code $codes.ToArray() -Fields 'code'
                foreach ($missing in $found.MissingCode) {
                    Write-Error -Message "No org unit with the code '$missing' lies in your hierarchy." -Category ObjectNotFound -ErrorId 'NeoIPCOrgUnitCodeNotFound' -TargetObject $missing
                }
                $unitIds = [System.Collections.Generic.HashSet[string]]::new($ordinal)
                foreach ($unit in $found.ByCode.Values) { [void]$unitIds.Add([string]$unit['id']) }
                if ($unitIds.Count -eq 0) { return }
                $wanted = [string[]]@($unitIds)
                [Array]::Sort($wanted, $ordinal)
                foreach ($chunk in (Split-NeoIPCList -Value $wanted -Separator ',')) {
                    $reads.Add(@{ Filter = "organisationUnits.id:in:[$($chunk -join ',')]" })
                }
            }
            else {
                $reads.Add(@{})
            }

            $versionText = Get-NeoIPCDhis2VersionText -Endpoint $endpoint
            $version = ConvertTo-NeoIPCDhis2Version -Text $versionText
            # NEOIPC-COMPAT(dhis2-user-list-own-roles): remove once no supported instance runs 2.41 or earlier
            # (/api/system/info version 2.42 or later everywhere). On 2.41 and earlier, api/users leaves out, for an account
            # without the authority ALL, every account that holds one of its user roles, its own included, unless the system
            # setting keyCanGrantOwnUserAuthorityGroups is on (DefaultUserService.handleUserQueryParams); only the user
            # lookup endpoint opts out. From 2.42.0, a list read with filters alone no longer applies that rule.
            if ($version -lt [version]'2.42.0') {
                $me = Invoke-NeoIPCDhis2Get @endpoint -Path 'api/me' -Fields 'authorities' -AsHashtable -Confirm:$false -WhatIf:$false
                $authorities = if ($me -is [System.Collections.IDictionary]) { @($me['authorities']) } else { @() }
                if ($authorities -cnotcontains 'ALL') {
                    Write-Warning "DHIS2 $versionText leaves out of the user list the accounts that hold any of your account's user roles, your own account included, unless the system setting that lets users grant their own user roles (keyCanGrantOwnUserAuthorityGroups) is on."
                }
            }
            $twoFactorSource = Get-NeoIPCUserTwoFactorSource -Version $version
            $fields = @(
                'id', 'username', 'firstName', 'surname', 'email', 'phoneNumber', 'employer', 'created', 'createdBy[username]',
                'lastUpdated', 'lastUpdatedBy[username]', 'passwordLastUpdated', 'lastLogin', 'invitation', 'disabled',
                'selfRegistered', 'userRoles[name]', 'userGroups[name]', 'organisationUnits[code]',
                'dataViewOrganisationUnits[code]', 'teiSearchOrganisationUnits[code]'
            )
            # NEOIPC-COMPAT(dhis2-user-twofactorenabled): see Get-NeoIPCUserTwoFactorSource in Private/UserInfo.ps1.
            if ($twoFactorSource -eq 'UserField') { $fields += 'twoFactorEnabled' }

            $users = [System.Collections.Generic.Dictionary[string, object]]::new($ordinal)
            foreach ($read in $reads) {
                try {
                    $answer = Invoke-NeoIPCDhis2Get @endpoint @read -Path 'api/users' -Fields $fields -AsHashtable -Confirm:$false -WhatIf:$false
                }
                catch {
                    $failure = $_
                    if ($failure.Exception -is [System.Net.Http.HttpRequestException] -and [int]$failure.Exception.StatusCode -eq 403) {
                        $PSCmdlet.ThrowTerminatingError([System.Management.Automation.ErrorRecord]::new(
                                [System.Net.Http.HttpRequestException]::new("Your account may not list DHIS2 users: api/users needs the authority F_USER_VIEW, which ALL includes. $($failure.Exception.Message)", $failure.Exception, [System.Net.HttpStatusCode]::Forbidden),
                                'NeoIPCUserListForbidden', [System.Management.Automation.ErrorCategory]::PermissionDenied, 'api/users'))
                    }
                    $PSCmdlet.ThrowTerminatingError($failure)
                }
                if ($answer -isnot [System.Collections.IDictionary] -or $answer['users'] -isnot [System.Collections.IList]) {
                    throw 'The user read did not return a users list.'
                }
                foreach ($user in $answer['users']) {
                    if ($user -isnot [System.Collections.IDictionary] -or [string]::IsNullOrEmpty([string]$user['id'])) { continue }
                    if (-not $users.ContainsKey([string]$user['id'])) { $users[[string]$user['id']] = $user }
                }
            }
            if ($users.Count -eq 0) { return }

            $twoFactor = $null
            if ($twoFactorSource -eq 'AuditEndpoint') { $twoFactor = Read-NeoIPCUserTwoFactorState -Endpoint $endpoint }
            # NEOIPC-COMPAT(dhis2-user-twofactor-audit-floor): see Get-NeoIPCUserTwoFactorSource in Private/UserInfo.ps1.
            elseif ($twoFactorSource -eq 'None') {
                Write-Warning "TwoFactorEnabled is empty for every user: DHIS2 $versionText shows no other user's two-factor state. The first patches that do (api/users/twoFactor) are 2.42.6 and 2.43.1."
            }

            $effectiveScheme = if ($Scheme) { $Scheme } else { 'https' }
            $baseUrl = "${effectiveScheme}://$(Resolve-NeoIPCDhis2Hostname -Hostname $Hostname)"
            if ($null -ne $Port) { $baseUrl += ":$Port" }

            $records = [System.Collections.Generic.List[object]]::new()
            foreach ($user in $users.Values) {
                $id = [string]$user['id']
                $twoFactorEnabled = $null
                # NEOIPC-COMPAT(dhis2-user-twofactorenabled): see Get-NeoIPCUserTwoFactorSource in Private/UserInfo.ps1.
                if ($twoFactorSource -eq 'UserField') { $twoFactorEnabled = $user['twoFactorEnabled'] }
                elseif ($null -ne $twoFactor -and $twoFactor.ContainsKey($id)) {
                    $twoFactorEnabled = @('TOTP_ENABLED', 'EMAIL_ENABLED') -ccontains $twoFactor[$id]
                }
                $createdBy = $user['createdBy']
                $lastUpdatedBy = $user['lastUpdatedBy']
                $records.Add([pscustomobject]@{
                        UserId                     = $user['id']
                        Username                   = $user['username']
                        FirstName                  = $user['firstName']
                        Surname                    = $user['surname']
                        Email                      = $user['email']
                        PhoneNumber                = $user['phoneNumber']
                        Employer                   = $user['employer']
                        OrganisationUnits          = ConvertTo-NeoIPCSortedText -InputObject $user['organisationUnits'] -Property 'code'
                        DataViewOrganisationUnits  = ConvertTo-NeoIPCSortedText -InputObject $user['dataViewOrganisationUnits'] -Property 'code'
                        TeiSearchOrganisationUnits = ConvertTo-NeoIPCSortedText -InputObject $user['teiSearchOrganisationUnits'] -Property 'code'
                        UserRoles                  = ConvertTo-NeoIPCSortedText -InputObject $user['userRoles'] -Property 'name'
                        UserGroups                 = ConvertTo-NeoIPCSortedText -InputObject $user['userGroups'] -Property 'name'
                        Created                    = ConvertFrom-NeoIPCDhis2DateText -Text $user['created']
                        CreatedBy                  = if ($createdBy -is [System.Collections.IDictionary]) { $createdBy['username'] } else { $null }
                        LastUpdated                = ConvertFrom-NeoIPCDhis2DateText -Text $user['lastUpdated']
                        LastUpdatedBy              = if ($lastUpdatedBy -is [System.Collections.IDictionary]) { $lastUpdatedBy['username'] } else { $null }
                        PasswordLastUpdated        = ConvertFrom-NeoIPCDhis2DateText -Text $user['passwordLastUpdated']
                        LastLogin                  = ConvertFrom-NeoIPCDhis2DateText -Text $user['lastLogin']
                        Invitation                 = $user['invitation']
                        Disabled                   = $user['disabled']
                        TwoFactorEnabled           = $twoFactorEnabled
                        SelfRegistered             = $user['selfRegistered']
                        EditUrl                    = Get-NeoIPCUserEditUrl -BaseUrl $baseUrl -Version $version -UserId $id
                    })
            }

            $records.Sort([System.Comparison[object]] {
                    param($x, $y)
                    $byName = [string]::CompareOrdinal([string]$x.Username, [string]$y.Username)
                    if ($byName -ne 0) { $byName } else { [string]::CompareOrdinal([string]$x.UserId, [string]$y.UserId) }
                })
            $records
        }
        catch { $PSCmdlet.ThrowTerminatingError($_) }
    }
}
