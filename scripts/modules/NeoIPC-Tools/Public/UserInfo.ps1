<#
.SYNOPSIS
Query DHIS2 user accounts with optional filtering by org-unit code.

.PARAMETER OrgUnitCode
Filter to users assigned to specific OU codes. Pipeline-bound by property
name so `Read-OrgUnitInfo | Read-UserInfo` returns users at those OUs.

.OUTPUTS
Flat PSCustomObject per user with account details, org unit assignments, and roles.
#>
function Read-UserInfo {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromPipelineByPropertyName)]
        [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
            $serverKey = Get-NeoipcServerKey -Scheme $fakeBoundParameters['Scheme'] -Hostname $fakeBoundParameters['Hostname'] -Port $fakeBoundParameters['Port']
            $cacheDir = Join-Path (Split-Path (Split-Path (Split-Path $PSScriptRoot))) 'data' $serverKey
            $cacheFile = Join-Path $cacheDir 'site-codes.txt'
            if (Test-Path $cacheFile) {
                Get-Content $cacheFile | Where-Object { $_ -like "$wordToComplete*" }
            }
        })]
        [string[]]$OrgUnitCode,

        [Parameter()]
        [string]$Token = $env:NEOIPC_DHIS2_TOKEN,

        [Parameter()]
        [string]$UserName,

        [Parameter()] [string]$Scheme = $null,
        [Parameter()] [string]$Hostname = $null,
        [Parameter()] [Nullable[int]]$Port = $null
    )

    begin {
        $script:auth = Resolve-NeoipcAuth -Token $Token -UserName $UserName
        $script:collectedOrgUnitCodes = [System.Collections.Generic.List[string]]::new()
    }

    process {
        if ($OrgUnitCode) {
            foreach ($c in $OrgUnitCode) { $script:collectedOrgUnitCodes.Add($c) }
        }
    }

    end {
        if ($MyInvocation.ExpectingInput -and $script:collectedOrgUnitCodes.Count -eq 0) { return }

        $fields = @(
            'id','username','firstName','surname','email','phoneNumber','employer','created',
            'createdBy[username]','lastUpdated','lastUpdatedBy[username]','passwordLastUpdated','lastLogin',
            'invitation','disabled','twoFactorEnabled','selfRegistered','userRoles[name]','userGroups[name]',
            'organisationUnits[code]','dataViewOrganisationUnits[code]','teiSearchOrganisationUnits[code]'
        )

        $filters = @()
        if ($script:collectedOrgUnitCodes.Count -gt 0) {
            $codes = ($script:collectedOrgUnitCodes | Sort-Object -Unique) -join ','
            $filters += "organisationUnits.code:in:[$codes]"
        }

        $getParams = @{
            Auth   = $script:auth
            Path   = 'api/users'
            Fields = $fields
        }
        if ($filters.Count -gt 0) { $getParams.Filter = $filters }
        if ($Scheme)   { $getParams.Scheme   = $Scheme }
        if ($Hostname) { $getParams.Hostname = $Hostname }
        if ($Port)     { $getParams.Port     = $Port }

        $obj = Invoke-NeoipcDhis2Get @getParams

        $effectiveScheme = if ($Scheme) { $Scheme } else { 'https' }
        $effectiveHost = if ($Hostname) { $Hostname } else { 'neoipc.charite.de' }
        $baseUrl = "${effectiveScheme}://${effectiveHost}"
        if ($Port) { $baseUrl += ":$Port" }

        foreach ($user in $obj.users) {
            [PSCustomObject]@{
                UserId                     = $user.id
                Username                   = $user.username
                FirstName                  = $user.firstName
                Surname                    = $user.surname
                Email                      = $user.email
                PhoneNumber                = $user.phoneNumber
                Employer                   = $user.employer
                OrganisationUnits          = $user.organisationUnits.code | Sort-Object
                DataViewOrganisationUnits  = $user.dataViewOrganisationUnits.code | Sort-Object
                TeiSearchOrganisationUnits = $user.teiSearchOrganisationUnits.code | Sort-Object
                UserRoles                  = $user.userRoles.name | Sort-Object
                UserGroups                 = $user.userGroups.name | Sort-Object
                Created                    = $user.created
                CreatedBy                  = $user.createdBy.username
                LastUpdated                = $user.lastUpdated
                LastUpdatedBy              = $user.lastUpdatedBy.username
                PasswordLastUpdated        = $user.passwordLastUpdated
                LastLogin                  = $user.lastLogin
                Invitation                 = $user.invitation
                Disabled                   = $user.disabled
                TwoFactorEnabled           = $user.twoFactorEnabled
                SelfRegistered             = $user.selfRegistered
                EditUrl                    = "$baseUrl/dhis-web-user/index.html#/users/edit/$($user.id)"
            }
        }
    }
}
