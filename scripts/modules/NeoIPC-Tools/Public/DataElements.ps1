<#
.SYNOPSIS
Fetch all data-element codes from DHIS2.

.DESCRIPTION
Queries `/api/metadata?dataElements:fields=code` and returns a sorted,
de-duplicated array of code strings. Used by the cache-population script
to feed the `-DataElementCode` argument completer on `Read-EventInfo`.

.PARAMETER Auth
Authentication hashtable from Resolve-NeoIPCAuth.

.OUTPUTS
Sorted array of data-element code strings.
#>
function Get-NeoIPCDataElementCodes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Auth,

        [Parameter()] [string]$Scheme = $null,
        [Parameter()] [string]$Hostname = $null,
        [Parameter()] [Nullable[int]]$Port = $null
    )

    $getParams = @{
        Auth            = $Auth
        Path            = 'api/metadata'
        QueryParameters = @{
            'dataElements:fields' = 'code'
            'dataElements:filter' = 'code:!null'
        }
    }
    if ($Scheme)   { $getParams.Scheme   = $Scheme }
    if ($Hostname) { $getParams.Hostname = $Hostname }
    if ($Port)     { $getParams.Port     = $Port }

    try {
        $resp = Invoke-NeoIPCDhis2Get @getParams
    }
    catch {
        throw "Failed to fetch data-element codes from DHIS2: $($_.Exception.Message)"
    }

    $codes = if ($resp.dataElements) {
        @($resp.dataElements | ForEach-Object { $_.code } | Where-Object { $_ }) | Sort-Object -Unique
    } else { @() }

    return $codes
}
