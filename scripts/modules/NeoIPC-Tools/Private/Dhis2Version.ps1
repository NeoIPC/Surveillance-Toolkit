#Requires -Version 7.6
# The DHIS2 version a function talks to: read from the instance, parsed, and checked against verified releases.

function Get-NeoIPCDhis2VersionText {
    # The instance's version text, /api/system/info `version` ('2.41.10', '2.42.6.1', '2.43-SNAPSHOT'). It reads with
    # -WhatIf:$false, since the GET helper asks ShouldProcess and a caller's -WhatIf would otherwise leave nothing to
    # choose a dialect or a verified release by. Throws when the answer carries no version.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$Endpoint)
    $info = Invoke-NeoIPCDhis2Get @Endpoint -Path 'api/system/info' -Fields 'version' -AsHashtable -Confirm:$false -WhatIf:$false
    $text = if ($info -is [System.Collections.IDictionary]) { [string]$info['version'] } else { '' }
    if ([string]::IsNullOrWhiteSpace($text)) { throw 'DHIS2 answered api/system/info without a version.' }
    $text
}

function ConvertTo-NeoIPCDhis2Version {
    # DHIS2's version text (/api/system/info `version`: '2.41.10', '2.42.6.1', '2.43-SNAPSHOT') -> [version], from its
    # leading numeric components. Throws on text without major.minor, so a misread version never selects a branch.
    [CmdletBinding()]
    [OutputType([version])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    if ($Text -notmatch '^(\d+)\.(\d+)(?:\.(\d+))?(?:\.(\d+))?') { throw "Unparsable DHIS2 version '$Text'." }
    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add($Matches[1]); $parts.Add($Matches[2])
    $parts.Add($(if ($Matches[3]) { $Matches[3] } else { '0' }))
    if ($Matches[4]) { $parts.Add($Matches[4]) }
    [version]($parts -join '.')
}

function Test-NeoIPCVerifiedDhis2Version {
    # Whether DHIS2's version text names one of the given verified releases or a later patch of its line. A build with
    # a suffix ('2.43.1-SNAPSHOT', '2.43.1-RC1') is none of them, whatever its numbers.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][version[]]$Release
    )
    if ($Text -notmatch '^\d+\.\d+\.\d+(\.\d+)?$') { return $false }
    $version = ConvertTo-NeoIPCDhis2Version -Text $Text
    foreach ($v in $Release) {
        if ($version.Major -eq $v.Major -and $version.Minor -eq $v.Minor) { return $version -ge $v }
    }
    $false
}
