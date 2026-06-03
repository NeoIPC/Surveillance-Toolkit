<#
.SYNOPSIS
Read DHIS2 personal access tokens for the current user.

.PARAMETER Filter
DHIS2 API filter expression (e.g. 'key:token:d2pat_...').

.PARAMETER Id
One or more PAT IDs to fetch directly.

.PARAMETER Fields
Fields to include in the response.
#>
function Read-DHIS2PersonalAccessToken {
    [CmdletBinding()]
    param(
        [Parameter(ParameterSetName = 'filter', Position = 0)]
        [string]$Filter,

        [Parameter(Mandatory, ParameterSetName = 'id', Position = 0)]
        [string[]]$Id,

        [Parameter()]
        [string]$Token = $env:NEOIPC_DHIS2_TOKEN,

        [Parameter()]
        [string]$UserName,

        [Parameter()]
        [string[]]$Fields = @('id', 'key', 'expire', 'created', 'createdBy[username]', 'attributes'),

        [Parameter()] [string]$Scheme = $null,
        [Parameter()] [string]$Hostname = $null,
        [Parameter()] [Nullable[int]]$Port = $null
    )

    $auth = Resolve-NeoipcAuth -Token $Token -UserName $UserName

    $expand = $true
    $filterExpr = $Filter
    if ($Id) {
        if ($Id.Count -gt 1) {
            $path = 'api/apiToken'
            $filterExpr = $Id | Join-String -OutputPrefix 'id:in:' -Separator ','
        } else {
            $path = "api/apiToken/$($Id[0])"
            $expand = $false
        }
    } else {
        $path = 'api/apiToken'
    }

    $getParams = @{
        Auth = $auth
        Path = $path
    }
    if ($Fields)   { $getParams.Fields = $Fields }
    if ($filterExpr) { $getParams.Filter = @($filterExpr) }
    if ($Scheme)   { $getParams.Scheme   = $Scheme }
    if ($Hostname) { $getParams.Hostname = $Hostname }
    if ($Port)     { $getParams.Port     = $Port }

    $obj = Invoke-NeoipcDhis2Get @getParams

    $tokens = if ($expand) {
        $obj | Select-Object -ExpandProperty apiToken
    } else {
        @($obj)
    }

    foreach ($t in $tokens) {
        # Flatten attributes: extract AllowedMethods from MethodAllowedList
        $allowedMethods = @()
        if ($t.attributes) {
            $methodAttr = $t.attributes | Where-Object { $_.type -eq 'MethodAllowedList' } | Select-Object -First 1
            if ($methodAttr -and $methodAttr.allowedMethods) {
                $allowedMethods = @($methodAttr.allowedMethods)
            }
        }

        [PSCustomObject]@{
            Id             = $t.id
            Key            = $t.key
            Expire         = if ($t.expire) { [System.DateTimeOffset]::FromUnixTimeMilliseconds($t.expire).UtcDateTime } else { $null }
            Created        = $t.created
            CreatedBy      = $t.createdBy.username
            AllowedMethods = $allowedMethods
        }
    }
}

<#
.SYNOPSIS
Remove one or more DHIS2 personal access tokens.

.PARAMETER Id
PAT IDs to remove. Accepts pipeline input (e.g. from Read-DHIS2PersonalAccessToken).
#>
function Remove-DHIS2PersonalAccessToken {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string[]]$Id,

        [Parameter()]
        [string]$Token = $env:NEOIPC_DHIS2_TOKEN,

        [Parameter()]
        [string]$UserName,

        [Parameter()] [string]$Scheme = $null,
        [Parameter()] [string]$Hostname = $null,
        [Parameter()] [Nullable[int]]$Port = $null,

        [switch]$Force
    )

    begin {
        $auth = Resolve-NeoipcAuth -Token $Token -UserName $UserName
        $results = [System.Collections.ArrayList]::new()
        $yesToAll = $false
        $noToAll = $false
    }

    process {
        foreach ($currentId in $Id) {
            if ($ConfirmPreference -gt [System.Management.Automation.ConfirmImpact]'Medium' -or `
                $PSCmdlet.ShouldProcess(
                    "Removing DHIS2 personal access token '$currentId'",
                    "Remove DHIS2 personal access token '$currentId'?",
                    'Removing token'))
            {
                if ($Force -or $PSCmdlet.ShouldContinue(
                    "Remove DHIS2 personal access token '$currentId'?",
                    'Removing token',
                    [ref]$yesToAll,
                    [ref]$noToAll
                )) {
                    Write-Verbose "Removing DHIS2 personal access token '$currentId'."
                    $deleteParams = @{
                        Auth = $auth
                        Path = "api/apiToken/$currentId"
                        Confirm = $false
                    }
                    if ($Scheme)   { $deleteParams.Scheme   = $Scheme }
                    if ($Hostname) { $deleteParams.Hostname = $Hostname }
                    if ($Port)     { $deleteParams.Port     = $Port }
                    $results.Add((Invoke-NeoipcDhis2Delete @deleteParams)) | Out-Null
                } else {
                    Write-Debug "Skipping removal of token '$currentId'."
                }
            } else {
                Write-Debug "Not processing removal of token '$currentId'."
                $results = $null
            }
        }
    }

    end {
        $results
    }
}

<#
.SYNOPSIS
Remove all (or only expired) DHIS2 personal access tokens.

.PARAMETER All
When set, removes all tokens including unexpired ones. Default: only expired tokens.
#>
function Clear-DHIS2PersonalAccessTokens {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter()]
        [string]$Token = $env:NEOIPC_DHIS2_TOKEN,

        [Parameter()]
        [string]$UserName,

        [Parameter()] [string]$Scheme = $null,
        [Parameter()] [string]$Hostname = $null,
        [Parameter()] [Nullable[int]]$Port = $null,

        [switch]$All,
        [switch]$Force
    )

    $auth = Resolve-NeoipcAuth -Token $Token -UserName $UserName

    if ($All) {
        $fields = @('id')
    } else {
        $fields = @('id', 'expire')
    }

    $getParams = @{
        Auth   = $auth
        Path   = 'api/apiToken'
        Fields = $fields
    }
    if ($Scheme)   { $getParams.Scheme   = $Scheme }
    if ($Hostname) { $getParams.Hostname = $Hostname }
    if ($Port)     { $getParams.Port     = $Port }

    $tokens = (Invoke-NeoipcDhis2Get @getParams -WhatIf:$false) | Select-Object -ExpandProperty apiToken

    $tokens |
        Where-Object {
            $All -or [System.DateTimeOffset]::FromUnixTimeMilliseconds($_.expire) -le [System.DateTimeOffset]::UtcNow
        } |
        Select-Object -ExpandProperty id |
        Remove-DHIS2PersonalAccessToken -Token $Token -UserName $UserName -Scheme $Scheme -Hostname $Hostname -Port $Port -Force:$Force
}

New-Alias -Name Read-PAT -Value Read-DHIS2PersonalAccessToken -Force
New-Alias -Name Remove-PAT -Value Remove-DHIS2PersonalAccessToken -Force
New-Alias -Name Clear-PATs -Value Clear-DHIS2PersonalAccessTokens -Force
