#Requires -Version 7.6

<#
.SYNOPSIS
Return the next unused integer Id in the infectious-agent ontology YAML.

.DESCRIPTION
Walks NeoIPC-Infectious-Agents.yaml depth-first across Hierarchies, Children,
and Synonyms lists, collecting every Id: value, and returns max + 1.

Gaps left by retired entries are not refilled — append-after-max only. Use
this when adding a new concept or synonym to the ontology.

.PARAMETER Path
Path to the YAML file. Defaults to the canonical ontology file in the
repository so the cmdlet works without arguments from anywhere inside the
repo. Relative paths are resolved against the current working directory.

.OUTPUTS
[int] The next unused Id value (max existing Id + 1).

.EXAMPLE
PS> Find-NextFreeInfectiousAgentId
3561
#>
function Find-NextFreeInfectiousAgentId {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Position = 0)]
        [string]$Path = (Join-Path $PSScriptRoot '..' '..' '..' '..' 'metadata' 'common' 'infectious-agents' 'NeoIPC-Infectious-Agents.yaml')
    )

    function Get-IdsFromNode {
        param($Node)
        if ($Node -is [System.Collections.IList]) {
            foreach ($item in $Node) { Get-IdsFromNode $item }
            return
        }
        if ($Node -is [System.Collections.IDictionary]) {
            if ($Node.Contains('Id')) { [int]$Node['Id'] }
            # Same key order as Get-NeoIPCInfectiousAgentConcept (Hierarchies, Synonyms, Children) so the two
            # ontology walkers agree on traversal; order is irrelevant here (max-Id), load-bearing there (sortOrder).
            foreach ($key in 'Hierarchies', 'Synonyms', 'Children') {
                if ($Node.Contains($key)) { Get-IdsFromNode $Node[$key] }
            }
        }
    }

    Import-Module powershell-yaml -ErrorAction Stop
    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    $tree = Get-Content -LiteralPath $resolved | ConvertFrom-Yaml
    $ids = Get-IdsFromNode $tree
    [int](($ids | Measure-Object -Maximum).Maximum + 1)
}


<#
.SYNOPSIS
Draw a random DHIS2 UID for every infectious-agent Id that has none, and write it to the UID sidecar.

.DESCRIPTION
Every option of the NEOIPC_PATHOGENS option set takes its UID from the sidecar beside the ontology,
NeoIPC-Infectious-Agents.uids.csv, and New-NeoIPCPathogenOptionSet refuses an Id the sidecar lacks, since no
option UID is derived. Run this after adding Ids to NeoIPC-Infectious-Agents.yaml: for each Id without a row it
draws a random UID in the shape of the DHIS2 code generator, unique among the sidecar's UIDs and the option
set's, and writes the sidecar back sorted by Id, as UTF-8 without a byte order mark and with LF line endings.
The rows already there stay as they are: a UID is its option's identity in every instance that imported a package
carrying it, where DHIS2 refuses another option of the set with the same code or name, and CI holds every row that
a release of the list carried. Nothing is written for a sidecar with (1) a row whose id is no Id, (2) a row whose UID
is no DHIS2 UID, which is restored from the sidecar's history or, where it never held a valid UID, removed for the
call to draw one, or (3) a change since the call read it, by another run, an editor, or git, whose rows the write
would discard. Case 3 is checked just before the write, without a lock on the file, so a change in the instant
between the check and the write is not caught.

.PARAMETER Path
Path to the ontology YAML. Defaults to the canonical file in the repository.

.PARAMETER UidSidecarPath
Path to the sidecar. Defaults to NeoIPC-Infectious-Agents.uids.csv beside the YAML, which is created if absent.

.OUTPUTS
[pscustomobject] One per row added, with its Id and Uid; nothing when every Id has a row.

.EXAMPLE
PS> Add-NeoIPCInfectiousAgentUid -WhatIf
Says how many UIDs it would add, and writes nothing.
#>
function Add-NeoIPCInfectiousAgentUid {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [string]$Path = (Join-Path $PSScriptRoot '..' '..' '..' '..' 'metadata' 'common' 'infectious-agents' 'NeoIPC-Infectious-Agents.yaml'),
        [string]$UidSidecarPath
    )

    Import-Module powershell-yaml -ErrorAction Stop
    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    if (-not $UidSidecarPath) { $UidSidecarPath = Join-Path (Split-Path -Parent $resolved) 'NeoIPC-Infectious-Agents.uids.csv' }
    # .NET resolves a relative path against the process's directory, not PowerShell's location, and cannot open a
    # path on a PowerShell drive, so the bytes are read from the provider's path, the file the rows come from and the
    # text goes to.
    $UidSidecarPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($UidSidecarPath)
    $tree = Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Yaml
    # The sidecar's bytes as read, against which the write tells whether it changed since; assigned inside the try
    # block, since a statement's output would be enumerated into an array of objects.
    try { $read = [System.IO.File]::ReadAllBytes($UidSidecarPath) }
    catch [System.IO.FileNotFoundException], [System.IO.DirectoryNotFoundException] { $read = $null }
    $uidByCode = Get-NeoIPCPathogenUidMap -Path $UidSidecarPath
    # The sidecar is written back sorted by Id, which a row whose id is no Id has no place in.
    $odd = @($uidByCode.Keys | Where-Object { $_ -cnotmatch '\A(?:0|[1-9][0-9]{0,17})\z' } | Sort-Object)
    if ($odd.Count -gt 0) { throw "The sidecar '$UidSidecarPath' has rows whose id is no Id: $($odd -join ', '). Correct or remove them first." }
    # Every row is written back unquoted, so a UID that is no DHIS2 UID could come back as another: one quoted around a
    # line break would leave its line break outside the field and read as valid, and the history would no longer show
    # which row to restore.
    $malformed = @($uidByCode.Keys | Where-Object { -not (Test-NeoIPCMetadataUid -Id $uidByCode[$_]) } | Sort-Object { [long]$_ })
    if ($malformed.Count -gt 0) {
        throw "The sidecar '$UidSidecarPath' has rows whose UID is no DHIS2 UID, for the Ids $($malformed -join ', '): restore each from the sidecar's history, since an option keeps its UID once a package has carried it; only a row that never held a valid UID may go, for this call to draw one."
    }
    $taken = [System.Collections.Generic.HashSet[string]]::new([string[]]@(@($uidByCode.Values) + $script:NeoIPCPathogenOptionSetUid), [System.StringComparer]::Ordinal)
    $added = @(foreach ($id in @(Get-NeoIPCInfectiousAgentConcept -Node $tree | ForEach-Object { [long]$_.Id } | Sort-Object -Unique)) {
            if ($uidByCode.ContainsKey([string]$id)) { continue }
            do { $uid = New-NeoIPCRandomUid } until ($taken.Add($uid))
            $uidByCode[[string]$id] = $uid
            [pscustomobject]@{ Id = $id; Uid = $uid }
        })
    if ($added.Count -eq 0) { return }
    if ($PSCmdlet.ShouldProcess($UidSidecarPath, "Add a random UID for $($added.Count) Id(s)")) {
        $rows = foreach ($code in @($uidByCode.Keys | Sort-Object { [long]$_ })) { "$code,$($uidByCode[$code])" }
        $text = ((@('id,uid') + $rows) -join "`n") + "`n"
        # A sidecar changed since it was read, by another run while this one waited for its confirmation, an editor, or
        # git, holds rows that the rows read would overwrite, and a UID once written is an option's identity. The text
        # is built first, so that only the comparison stands between this read and the write.
        try { $now = [System.IO.File]::ReadAllBytes($UidSidecarPath) }
        catch [System.IO.FileNotFoundException], [System.IO.DirectoryNotFoundException] { $now = $null }
        $unchanged = if ($null -eq $read -or $null -eq $now) { $null -eq $read -and $null -eq $now } else { [System.Linq.Enumerable]::SequenceEqual([byte[]]$now, [byte[]]$read) }
        if (-not $unchanged) {
            throw [System.IO.IOException]::new("The sidecar '$UidSidecarPath' changed since the call read it, so nothing is written: run the call again, which reads it anew.")
        }
        Write-NeoIPCTextFile -Path $UidSidecarPath -Text $text
        $added
    }
}
