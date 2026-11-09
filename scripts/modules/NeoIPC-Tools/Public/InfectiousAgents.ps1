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
between the check and the write is not caught. A refusal ends the call whatever the caller's error preference.

.PARAMETER Path
Path to the ontology YAML. Defaults to the canonical file in the repository.

.PARAMETER UidSidecarPath
Path to the sidecar, which must be in the file system. Defaults to NeoIPC-Infectious-Agents.uids.csv beside the YAML,
which is created if absent.

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

    # Under Stop, so that a refusal ends the call whatever the caller's preference: under SilentlyContinue or Ignore,
    # PowerShell drops a throw that no try encloses and runs on past it, here to write the sidecar it refused.
    $ErrorActionPreference = 'Stop'
    Import-Module powershell-yaml -ErrorAction Stop
    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    if (-not $UidSidecarPath) { $UidSidecarPath = Join-Path (Split-Path -Parent $resolved) 'NeoIPC-Infectious-Agents.uids.csv' }
    # .NET resolves a relative path against the process's directory, not PowerShell's location, and cannot open a
    # path on a PowerShell drive, so the bytes are read from the provider's path, the file the rows come from and the
    # text goes to, which must be in the file system.
    $UidSidecarPath = Resolve-NeoIPCFileSystemPath -Path $UidSidecarPath -Noun 'sidecar'
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
Return the infectious-agent list's option codes, the code sets the generated DHIS2 rules enumerate, and what the
reporting classification gives each code, with the SHA-256 of the two files they come from.

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

It also reads, and does not run without, the reporting classification: NeoIPC-Infectious-Agent-Reporting-Groups.yaml
beside the list, or the file -ClassificationPath names. It returns in Classification one row per Id, in ascending
order: Id; ReportingGroup, the Key of the leaf group the node takes; and one property per attribute of the
classification, named by its Key in PascalCase (GramReaction, OxygenRequirement), the Key of the value the node takes.
Each comes from the nearest member or assignment at or above the node, a synonym's from its concept, through the very
resolution the classification's checks judge, so another language's reading of the classification is held to the
same resolution. A value is $null where the node takes none, as the attributes outside the bacteria always are and
the group of the Ids 0 and 3561 is in a classification that passes its checks, and where the group or the assignment
it takes has no Key or Value to hand on. Judging the classification is for its checks, which MetadataContent.Tests.ps1
applies to the committed files. ClassificationSha256 is the SHA-256 of the classification's bytes, also in lower-case
hexadecimal, which names the revision of the classification the rows come from.

Both files must be in the file system, UTF-8 without a byte order mark, as every text file of the repository is, and
valid YAML; the list must give each Id to one node only, as the option-set generator requires; the classification
must be a mapping that holds a list of Groups, with at least one group in it, and a list of Attributes; and each
attribute must be a mapping with a Key, a text with a word in it, that turns, in PascalCase, neither into the name of
another property of a row (Id, ReportingGroup, or another attribute's), in any letter case, nor into a name
PowerShell reserves, such as PSObject or PSTypeName. A file that does not, or that cannot be read, is refused, with
the file, the Id, or the attribute named, and a file that is not valid YAML with the line and the column where the
parser stopped, or with the end of the file; a refusal or a failure ends the call whatever the caller's error
preference.

.PARAMETER Path
Path to the ontology YAML. Defaults to the canonical file in the repository.

.PARAMETER ClassificationPath
Path to the reporting classification. Defaults to NeoIPC-Infectious-Agent-Reporting-Groups.yaml beside the list.

.OUTPUTS
[pscustomobject] with Sha256, Concepts, Synonyms, CommonCommensals, ResistanceCategories (one set per category),
Viruses, ClassificationSha256, and Classification (one row per Id).

.EXAMPLE
PS> (Get-NeoIPCInfectiousAgentCodeSet).ResistanceCategories.MRSA
Returns the Ids of the infectious agents for which a finding records whether they are MRSA.

.EXAMPLE
PS> (Get-NeoIPCInfectiousAgentCodeSet).Classification | Where-Object ReportingGroup -EQ 'anaerobes'
Returns the rows of the infectious agents in the reporting group of the anaerobes.
#>
function Get-NeoIPCInfectiousAgentCodeSet {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [string]$Path = (Join-Path $PSScriptRoot '..' '..' '..' '..' 'metadata' 'common' 'infectious-agents' 'NeoIPC-Infectious-Agents.yaml'),

        [string]$ClassificationPath
    )

    # Under Stop, so that a refusal or a failure ends the call whatever the caller's preference: under SilentlyContinue
    # or Ignore, PowerShell drops a throw that no try encloses and runs on past it.
    $ErrorActionPreference = 'Stop'
    Import-Module powershell-yaml -ErrorAction Stop
    # Each file is read once, so that each hash is of the very text its part of the output comes from. powershell-yaml
    # raises a parse error in its own module, beyond this function's preference, so each parse is caught here, to end
    # the call and to name the file.
    $list = Read-NeoIPCTextFile -Path $Path -Noun 'list'
    try { $tree = $list.Text | ConvertFrom-Yaml }
    catch { throw (Get-NeoIPCYamlRefusalMessage -Noun 'list' -Path $list.Path -Text $list.Text -Exception $_.Exception) }
    $nodes = @(Get-NeoIPCInfectiousAgentConcept -Node $tree)
    $nameById = [System.Collections.Generic.Dictionary[int, string]]::new()
    foreach ($node in $nodes) {
        if ($nameById.ContainsKey($node.Id)) {
            throw "The Id $($node.Id) is that of two nodes of '$($list.Path)', '$($nameById[$node.Id])' and '$($node.Name)'; an Id is the option code of one infectious agent."
        }
        $nameById[$node.Id] = $node.Name
    }
    $classificationFile = Resolve-NeoIPCReportingClassificationPath -ListPath $list.Path -ClassificationPath $ClassificationPath
    $classification = Read-NeoIPCTextFile -Path $classificationFile -Noun 'classification'
    try { $parsed = $classification.Text | ConvertFrom-Yaml }
    catch {
        throw (Get-NeoIPCYamlRefusalMessage -Noun 'classification' -Path $classification.Path -Text $classification.Text -Exception $_.Exception)
    }
    # A file that is no classification, such as an empty one or the list itself, holds nothing for the checks to judge,
    # and its rows would come back without groups, without the attributes' columns, or not at all, so it is refused
    # here, with the file named. The lists are assigned in the block, since an if statement's output would unroll a
    # list of one group into the group.
    $groupList = $null
    $attributeList = $null
    if ($parsed -is [System.Collections.IDictionary]) {
        $groupList = $parsed['Groups']
        $attributeList = $parsed['Attributes']
    }
    $groupCount = if ($groupList -is [System.Collections.IList]) { @($groupList | Where-Object { $_ -is [System.Collections.IDictionary] }).Count } else { 0 }
    if ($groupCount -eq 0 -or $attributeList -isnot [System.Collections.IList]) {
        throw "The classification '$($classification.Path)' is no reporting classification: it is no mapping that holds a list of Groups, with at least one group in it, and a list of Attributes."
    }
    try { $rows = @(Get-NeoIPCInfectiousAgentClassificationRow -Classification $parsed -Tree $tree) }
    catch { throw "The classification '$($classification.Path)' cannot be read into rows: $($_.Exception.Message)" }
    $resistance = Get-NeoIPCResistanceCodeSet -Node $tree
    $categories = [ordered]@{}
    foreach ($category in $resistance.Keys) {
        if (-not $script:NeoIPCResistanceCategoryName.Contains($category)) { throw "The resistance category '$category' has no name to return its set under." }
        $categories[$script:NeoIPCResistanceCategoryName[$category]] = [int[]]@($resistance[$category])
    }
    [pscustomobject][ordered]@{
        Sha256               = [System.Convert]::ToHexStringLower([System.Security.Cryptography.SHA256]::HashData($list.Bytes))
        Concepts             = [int[]]@($nodes | Where-Object { -not $_.IsSynonym } | ForEach-Object { [int]$_.Id } | Sort-Object)
        Synonyms             = [int[]]@($nodes | Where-Object { $_.IsSynonym } | ForEach-Object { [int]$_.Id } | Sort-Object)
        CommonCommensals     = [int[]]@(Get-NeoIPCCommonCommensalCodeSet -Node $tree)
        ResistanceCategories = [pscustomobject]$categories
        Viruses              = [int[]]@(Get-NeoIPCVirusCodeSet -Node $tree)
        ClassificationSha256 = [System.Convert]::ToHexStringLower([System.Security.Cryptography.SHA256]::HashData($classification.Bytes))
        Classification       = [pscustomobject[]]$rows
    }
}


<#
.SYNOPSIS
Write the infectious-agent list's option codes and code sets, and what the reporting classification gives each code,
with the SHA-256 of the two files, to a JSON file.

.DESCRIPTION
Writes what Get-NeoIPCInfectiousAgentCodeSet returns as JSON, in UTF-8 without a byte order mark, with LF line endings
and a final line break, for consumers outside PowerShell, such as a test that holds another language's reading of the
list and its classification to the sets the generated DHIS2 metadata takes and to the rows the classification's
checks resolve. Its Sha256 and ClassificationSha256 name the revisions of the two files it was written from. The output
is named by -OutputPath alone, and the cmdlet refuses to write over either file it reads, whether the output path
names it or reaches it through a link: since no comparison of paths tells a link from another file, it refuses any
existing file that holds the very bytes of the list or the classification, an identical copy among them. Each of the
three paths must be in the file system. A refusal or a failure ends the call before anything is written, whatever the
caller's error preference.

.PARAMETER Path
Path to the ontology YAML. Defaults to the canonical file in the repository.

.PARAMETER ClassificationPath
Path to the reporting classification. Defaults to NeoIPC-Infectious-Agent-Reporting-Groups.yaml beside the list.

.PARAMETER OutputPath
The JSON file to write. An existing file is replaced, unless it is the list or the classification, or holds the bytes
of either.

.EXAMPLE
PS> Export-NeoIPCInfectiousAgentCodeSet -OutputPath infectious-agent-code-sets.json
Writes the canonical list's option codes and code sets, and what the classification beside it gives each code, to
infectious-agent-code-sets.json in the current location.
#>
function Export-NeoIPCInfectiousAgentCodeSet {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Position = 0)]
        [string]$Path = (Join-Path $PSScriptRoot '..' '..' '..' '..' 'metadata' 'common' 'infectious-agents' 'NeoIPC-Infectious-Agents.yaml'),
        [string]$ClassificationPath,
        [Parameter(Mandatory)]
        [string]$OutputPath
    )

    # Under Stop, so that a refusal or a failure ends the call whatever the caller's preference: under SilentlyContinue
    # or Ignore, PowerShell drops a throw that no try encloses and runs on past it, into a write over the very file a
    # refusal protects.
    $ErrorActionPreference = 'Stop'
    # The list is the input at Position 0, as in the module's other cmdlets, and the output is named, so that a list
    # path given where the output belongs cannot replace the list it is read from; nor can the output name the list or
    # the classification.
    $listPath = [System.IO.Path]::GetFullPath((Resolve-NeoIPCFileSystemPath -Path $Path -Noun 'list' -Existing))
    if (-not (Test-Path -LiteralPath $listPath -PathType Leaf)) { throw "The list '$listPath' is no file." }
    $classificationFile = [System.IO.Path]::GetFullPath((Resolve-NeoIPCReportingClassificationPath -ListPath $listPath -ClassificationPath $ClassificationPath))
    $target = [System.IO.Path]::GetFullPath((Resolve-NeoIPCFileSystemPath -Path $OutputPath -Noun 'output path'))
    $comparison = if ($IsLinux) { [System.StringComparison]::Ordinal } else { [System.StringComparison]::OrdinalIgnoreCase }
    foreach ($source in @(@{ File = $listPath; Noun = 'list' }, @{ File = $classificationFile; Noun = 'classification' })) {
        if ([string]::Equals($source.File, $target, $comparison)) {
            throw "The output path '$OutputPath' is the $($source.Noun) the code sets are read from; name another file."
        }
    }
    $sets = Get-NeoIPCInfectiousAgentCodeSet -Path $Path -ClassificationPath $classificationFile
    # A link to a file read, or a path through a linked directory, names that file by another path, which no
    # comparison of paths tells from another file; what it holds does, since every such alias reads back its very bytes.
    if ([System.IO.File]::Exists($target)) {
        $held = [System.Convert]::ToHexStringLower([System.Security.Cryptography.SHA256]::HashData([System.IO.File]::ReadAllBytes($target)))
        foreach ($read in @(@{ Sha256 = $sets.Sha256; Noun = 'list' }, @{ Sha256 = $sets.ClassificationSha256; Noun = 'classification' })) {
            if ($held -ceq $read.Sha256) {
                throw "The output path '$OutputPath' holds the very bytes of the $($read.Noun) the code sets are read from, as a link to it does; name another file."
            }
        }
    }
    $json = ($sets | ConvertTo-Json -Depth 100) + "`n"
    if ($PSCmdlet.ShouldProcess($OutputPath, 'Write the infectious-agent code sets')) {
        Write-NeoIPCTextFile -Path $OutputPath -Text $json
    }
}
