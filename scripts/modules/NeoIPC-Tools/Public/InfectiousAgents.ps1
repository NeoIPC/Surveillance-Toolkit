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
Returns the Id to give the next entry: one more than the largest Id in the canonical list.
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


<#
.SYNOPSIS
Return the infectious-agent list's option codes and the code sets the generated DHIS2 rules enumerate, with the
SHA-256 of the list they come from.

.DESCRIPTION
Reads NeoIPC-Infectious-Agents.yaml and returns the Ids of its Id-bearing nodes, each set in ascending order: the
concepts and the synonyms, which together are the option codes of the NEOIPC_PATHOGENS option set; and the code sets
the generated DHIS2 program rules enumerate: the common commensals, for each resistance category the infectious agents
it applies to, under the category's name (3GCR, CARBR, COLR, MRSA, VRE), and the viruses. A node's flags are its
effective ones: its own value where it has one, otherwise the nearest ancestor's, inherited down Hierarchies,
Synonyms, and Children, with an explicit false overriding an inherited true and false where no node on the path has a
value. A virus is any node under the top-level Viruses node. The sets come from the functions the generators expand
from, so a dataset generator that takes them from here agrees with the generated metadata, and another language's
reading of the list is held to them through the JSON that Export-NeoIPCInfectiousAgentCodeSet writes. Sha256 is the
SHA-256 of the bytes the sets were read from, in lower-case hexadecimal, which names the revision of the list a copy
of the sets comes from.

The list must be UTF-8 without a byte order mark, as every text file of the repository is, and give each Id to one
node only, as the option-set generator requires; a list that does not is refused, with the file or the Id named.

.PARAMETER Path
Path to the ontology YAML. Defaults to the canonical file in the repository.

.OUTPUTS
[pscustomobject] with Sha256, Concepts, Synonyms, CommonCommensals, ResistanceCategories (one set per category), and
Viruses.

.EXAMPLE
PS> (Get-NeoIPCInfectiousAgentCodeSet).ResistanceCategories.MRSA
Returns the Ids of the infectious agents for which a finding records whether they are MRSA.
#>
function Get-NeoIPCInfectiousAgentCodeSet {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [string]$Path = (Join-Path $PSScriptRoot '..' '..' '..' '..' 'metadata' 'common' 'infectious-agents' 'NeoIPC-Infectious-Agents.yaml')
    )

    Import-Module powershell-yaml -ErrorAction Stop
    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    # Read once, so that the hash is of the very text the sets come from.
    $bytes = [System.IO.File]::ReadAllBytes($resolved.ProviderPath)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        throw "The list '$($resolved.ProviderPath)' begins with a byte order mark; it must be UTF-8 without one."
    }
    try { $text = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes) }
    catch [System.Text.DecoderFallbackException] { throw "The list '$($resolved.ProviderPath)' is not valid UTF-8: $($_.Exception.Message)" }
    $tree = $text | ConvertFrom-Yaml
    $nodes = @(Get-NeoIPCInfectiousAgentConcept -Node $tree)
    $nameById = [System.Collections.Generic.Dictionary[int, string]]::new()
    foreach ($node in $nodes) {
        if ($nameById.ContainsKey($node.Id)) {
            throw "The Id $($node.Id) is that of two nodes of '$($resolved.ProviderPath)', '$($nameById[$node.Id])' and '$($node.Name)'; an Id is the option code of one infectious agent."
        }
        $nameById[$node.Id] = $node.Name
    }
    $resistance = Get-NeoIPCResistanceCodeSet -Node $tree
    $categories = [ordered]@{}
    foreach ($category in $resistance.Keys) {
        if (-not $script:NeoIPCResistanceCategoryName.Contains($category)) { throw "The resistance category '$category' has no name to return its set under." }
        $categories[$script:NeoIPCResistanceCategoryName[$category]] = [int[]]@($resistance[$category])
    }
    [pscustomobject][ordered]@{
        Sha256               = [System.Convert]::ToHexStringLower([System.Security.Cryptography.SHA256]::HashData($bytes))
        Concepts             = [int[]]@($nodes | Where-Object { -not $_.IsSynonym } | ForEach-Object { [int]$_.Id } | Sort-Object)
        Synonyms             = [int[]]@($nodes | Where-Object { $_.IsSynonym } | ForEach-Object { [int]$_.Id } | Sort-Object)
        CommonCommensals     = [int[]]@(Get-NeoIPCCommonCommensalCodeSet -Node $tree)
        ResistanceCategories = [pscustomobject]$categories
        Viruses              = [int[]]@(Get-NeoIPCVirusCodeSet -Node $tree)
    }
}


<#
.SYNOPSIS
Write the infectious-agent list's option codes and code sets, with the SHA-256 of the list, to a JSON file.

.DESCRIPTION
Writes what Get-NeoIPCInfectiousAgentCodeSet returns as JSON, in UTF-8 without a byte order mark, with LF line endings
and a final line break, for consumers outside PowerShell, such as a test that holds another language's reading of the
list to the sets the generated DHIS2 metadata takes. Its Sha256 names the revision of the list the file was written
from. The output is named by -OutputPath alone, and the cmdlet refuses to write over the list it reads.

.PARAMETER Path
Path to the ontology YAML. Defaults to the canonical file in the repository.

.PARAMETER OutputPath
The JSON file to write. An existing file is replaced, unless it is the list.

.EXAMPLE
PS> Export-NeoIPCInfectiousAgentCodeSet -OutputPath infectious-agent-code-sets.json
Writes the canonical list's code sets to infectious-agent-code-sets.json in the current location.
#>
function Export-NeoIPCInfectiousAgentCodeSet {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Position = 0)]
        [string]$Path = (Join-Path $PSScriptRoot '..' '..' '..' '..' 'metadata' 'common' 'infectious-agents' 'NeoIPC-Infectious-Agents.yaml'),
        [Parameter(Mandatory)]
        [string]$OutputPath
    )

    # The list is the input at Position 0, as in the module's other cmdlets, and the output is named, so that a list
    # path given where the output belongs cannot replace the list it is read from; nor can the output name the list.
    $listPath = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath)
    $target = [System.IO.Path]::GetFullPath($PSCmdlet.GetUnresolvedProviderPathFromPSPath($OutputPath))
    $comparison = if ($IsLinux) { [System.StringComparison]::Ordinal } else { [System.StringComparison]::OrdinalIgnoreCase }
    if ([string]::Equals($listPath, $target, $comparison)) {
        throw "The output path '$OutputPath' is the list the code sets are read from; name another file."
    }
    $json = (Get-NeoIPCInfectiousAgentCodeSet -Path $Path | ConvertTo-Json -Depth 100) + "`n"
    if ($PSCmdlet.ShouldProcess($OutputPath, 'Write the infectious-agent code sets')) {
        Write-NeoIPCTextFile -Path $OutputPath -Text $json
    }
}
