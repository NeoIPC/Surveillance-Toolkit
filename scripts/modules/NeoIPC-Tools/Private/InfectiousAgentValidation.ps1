#Requires -Version 7.6

# Checks of the infectious-agent list: the ontology NeoIPC-Infectious-Agents.yaml, its UID sidecar, its releases, and
# the two CSVs that readers outside this repository still download. Every Get-NeoIPC*Finding function returns one
# [pscustomobject] per defect, with Rule (a stable identifier), Location, and Message, and never throws: a malformed
# input is a finding like any other, so one run reports every defect. MetadataContent.Tests.ps1 applies the checks to
# the committed files.

# The keys a node may carry, compared ordinally: powershell-yaml reads mappings case-insensitively, so a case variant
# (`name` beside `Name`) would merge into one key there unseen.
$script:NeoIPCInfectiousAgentNodeKeys = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@('Id', 'Name', 'ConceptType', 'ConceptSource', 'ConceptId', 'LpsnRecordNumber', 'MycoBankNr', 'IctvId',
        'CommonCommensal', '3GCR', 'Carbapenems', 'Colistin', 'MRSA', 'VRE', 'Description', 'Synonyms', 'Children'),
    [System.StringComparer]::Ordinal)

# The per-node flags, each a Boolean: the common-commensal status and the resistance categories that apply.
$script:NeoIPCInfectiousAgentFlagKeys = @('CommonCommensal', '3GCR', 'Carbapenems', 'Colistin', 'MRSA', 'VRE')

# The ranks a node's ConceptType may name. The DHIS2 option label is built from it, so a misspelt rank would reach
# every user as a wrong label.
$script:NeoIPCInfectiousAgentConceptTypes = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@('Realm', 'Domain', 'Kingdom', 'Subkingdom', 'Phylum', 'Subphylum', 'Class', 'Subclass', 'Order',
        'Suborder', 'Family', 'Subfamily', 'Genus', 'Subgenus', 'Group', 'Species', 'Subspecies', 'Variety', 'Serotype',
        'Unknown'),
    [System.StringComparer]::Ordinal)

# The key holding each external source's record number. A NeoIPC concept carries none.
$script:NeoIPCInfectiousAgentRecordNumberKeys = [ordered]@{
    LPSN     = 'LpsnRecordNumber'
    MycoBank = 'MycoBankNr'
    ICTV     = 'IctvId'
}

# NEOIPC-COMPAT(legacy-infectious-agent-csv): remove once nothing downloads these two files from the
# Surveillance-Toolkit's main branch any more: the legacy reporting service does at run time, and neoipcr's
# data-preparation script does when it builds the package's tables. Until then they are frozen, since a change to
# either would reach those readers unreviewed.
$script:NeoIPCFrozenInfectiousAgentCsvSha256 = [ordered]@{
    'NeoIPC-Pathogen-Concepts.csv' = 'd8b15b8dc9258341dcf2868c430edd2235c7c2fe5ddc5a929968cd95d90964ce'
    'NeoIPC-Pathogen-Synonyms.csv' = '15fddeb82f2dfc99c58a169958a2cda3b50baec4dde4c837375c06c53d2b6fcc'
}

function New-NeoIPCCheckFinding {
    # One finding of a content check: the infectious-agent checks here, and the YAML portability check.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'It builds an object in memory and changes no state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Rule,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Location,
        [Parameter(Mandatory)][string]$Message
    )
    [pscustomobject]@{ Rule = $Rule; Location = $Location; Message = $Message }
}

function Get-NeoIPCInfectiousAgentKeyFinding {
    # Reads the ontology's text with YamlDotNet's event parser, which powershell-yaml carries, and reports what a parsed
    # tree cannot show: a key outside the vocabulary of its place, a structure out of place (a sequence where a node
    # belongs, a mapping as a key), and a typed node value in another form than its type's, which powershell-yaml's own
    # typing would hide: it reads 10.0 and 1e1 as the integer 10 and tRuE as true, where YAML 1.2.2 reads two floats and
    # a string, and YAML 1.1 and R's yaml a float and two strings. An Id is the option code of a data element that takes
    # zero or a positive integer, and R's yaml holds an integer in 32 bits, so an Id is a plain integer from 0 and a
    # record number one from 1, both to 2147483647; a flag is one of YAML 1.2.2's plain Booleans. What holds for every
    # YAML file of the toolkit, such as a repeated key or an anchor, is Get-NeoIPCYamlPortabilityFinding's to report.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    try { Import-Module powershell-yaml -ErrorAction Stop }
    catch {
        New-NeoIPCCheckFinding -Rule 'yaml-reader' -Location '' -Message "powershell-yaml, which carries YamlDotNet, cannot be loaded: $($_.Exception.Message)"
        return
    }

    # The place a collection takes in the file decides its keys: the root, Metadata, ListTerms and each of its terms,
    # UrlTemplates, a list of nodes (Hierarchies, Children, Synonyms), and a node. 'Ignored' marks a collection already
    # reported as out of place, so that its contents add no follow-on findings.
    $allowedKeys = @{
        Root     = [System.Collections.Generic.HashSet[string]]::new([string[]]@('Metadata', 'Hierarchies'), [System.StringComparer]::Ordinal)
        Metadata = [System.Collections.Generic.HashSet[string]]::new([string[]]@('ListTerms', 'UrlTemplates'), [System.StringComparer]::Ordinal)
        ListTerm = [System.Collections.Generic.HashSet[string]]::new([string[]]@('Value'), [System.StringComparer]::Ordinal)
        Node     = $script:NeoIPCInfectiousAgentNodeKeys
    }
    $placeNames = @{ Root = 'the top level of the list'; Metadata = 'Metadata'; ListTerm = 'a list term'; Node = 'a node' }
    # The place of a key's value, and whether it is a mapping, a sequence, or a scalar. The value of a key already
    # reported as unknown is ignored.
    $valuePlace = {
        param([string]$Place, [string]$Key)
        $ignored = 'Ignored', 'any'
        switch ($Place) {
            'Root' {
                if ($Key -ceq 'Metadata') { 'Metadata', 'map' } elseif ($Key -ceq 'Hierarchies') { 'Nodes', 'seq' } else { $ignored }
            }
            'Metadata' {
                if ($Key -ceq 'ListTerms') { 'ListTerms', 'map' } elseif ($Key -ceq 'UrlTemplates') { 'UrlTemplates', 'map' } else { $ignored }
            }
            'ListTerms' { 'ListTerm', 'map' }
            'ListTerm' { if ($Key -ceq 'Value') { 'Value', 'scalar' } else { $ignored } }
            'UrlTemplates' { 'Value', 'scalar' }
            'Node' {
                if ($Key -ceq 'Synonyms' -or $Key -ceq 'Children') { 'Nodes', 'seq' }
                elseif ($script:NeoIPCInfectiousAgentNodeKeys.Contains($Key)) { 'Value', 'scalar' }
                else { $ignored }
            }
            default { $ignored }
        }
    }
    $kindOf = {
        param($ParsingEvent)
        if ($ParsingEvent -is [YamlDotNet.Core.Events.MappingStart]) { 'map' }
        elseif ($ParsingEvent -is [YamlDotNet.Core.Events.SequenceStart]) { 'seq' }
        else { 'scalar' }
    }
    $recordNumberKeys = @($script:NeoIPCInfectiousAgentRecordNumberKeys.Values)

    $frames = [System.Collections.Generic.Stack[hashtable]]::new()
    $parser = [YamlDotNet.Core.Parser]::new([System.IO.StringReader]::new($Text))
    try {
        while ($parser.MoveNext()) {
            $parsingEvent = $parser.Current
            $line = "line $($parsingEvent.Start.Line)"
            if ($parsingEvent -is [YamlDotNet.Core.Events.MappingEnd] -or $parsingEvent -is [YamlDotNet.Core.Events.SequenceEnd]) {
                [void]$frames.Pop()
                continue
            }
            $isNodeEvent = $parsingEvent -is [YamlDotNet.Core.Events.NodeEvent] -or $parsingEvent -is [YamlDotNet.Core.Events.AnchorAlias]
            if (-not $isNodeEvent) { continue }

            $kind = & $kindOf $parsingEvent
            $isCollection = $kind -ne 'scalar' -and $parsingEvent -isnot [YamlDotNet.Core.Events.AnchorAlias]
            if ($frames.Count -eq 0) {
                if ($kind -ne 'map') {
                    New-NeoIPCCheckFinding -Rule 'structure' -Location $line -Message 'The document is not a mapping of Metadata and Hierarchies.'
                }
                if ($isCollection) {
                    $place = if ($kind -eq 'map') { 'Root' } else { 'Ignored' }
                    $frames.Push(@{ Kind = $kind; Place = $place; ExpectKey = $true })
                }
                continue
            }

            $frame = $frames.Peek()
            if ($frame.Kind -eq 'map' -and $frame.ExpectKey) {
                $frame.ExpectKey = $false
                if ($parsingEvent -isnot [YamlDotNet.Core.Events.Scalar]) {
                    $keyMessage = if ($parsingEvent -is [YamlDotNet.Core.Events.AnchorAlias]) { 'A mapping key is an alias, not a scalar.' } else { 'A mapping key is not a scalar.' }
                    New-NeoIPCCheckFinding -Rule 'structure' -Location $line -Message $keyMessage
                    $frame.PendingKey = $null
                    if ($isCollection) { $frames.Push(@{ Kind = $kind; Place = 'Ignored'; ExpectKey = $true }) }
                    continue
                }
                $key = $parsingEvent.Value
                $frame.PendingKey = $key
                $allowed = $allowedKeys[$frame.Place]
                if ($null -ne $allowed -and -not $allowed.Contains($key)) {
                    New-NeoIPCCheckFinding -Rule 'unknown-key' -Location $line -Message "The key '$key' is not one that $($placeNames[$frame.Place]) carries."
                }
                continue
            }

            # A value in a mapping, or an item of a sequence.
            if ($frame.Kind -eq 'map') {
                $frame.ExpectKey = $true
                $target = if ($null -eq $frame.PendingKey) { 'Ignored', 'any' } else { & $valuePlace $frame.Place $frame.PendingKey }
                $what = "the value of '$($frame.PendingKey)'"
            }
            else {
                $target = if ($frame.Place -eq 'Nodes') { 'Node', 'map' } else { 'Ignored', 'any' }
                $what = 'an item of the node list'
            }
            $place, $expected = $target
            if ($expected -ne 'any' -and $expected -ne $kind) {
                $expectedText = @{ map = 'a mapping'; seq = 'a sequence'; scalar = 'a scalar' }[$expected]
                New-NeoIPCCheckFinding -Rule 'structure' -Location $line -Message "$what is not $expectedText."
                $place = 'Ignored'
            }
            elseif ($frame.Place -eq 'Node' -and $kind -eq 'scalar' -and $parsingEvent -is [YamlDotNet.Core.Events.Scalar]) {
                # A typed node value, in the form its type takes in the text.
                $text = $parsingEvent.Value
                $plain = $parsingEvent.Style -eq [YamlDotNet.Core.ScalarStyle]::Plain -and $parsingEvent.Tag.IsEmpty
                $key = $frame.PendingKey
                if ($key -ceq 'Id') {
                    if (-not ($plain -and $text -cmatch '\A(?:0|[1-9][0-9]{0,9})\z' -and [long]$text -le [int]::MaxValue)) {
                        New-NeoIPCCheckFinding -Rule 'id-type' -Location $line -Message "The Id '$text' is not written as a plain integer from 0 to 2147483647; it becomes the DHIS2 option code."
                    }
                }
                elseif ($key -cin $recordNumberKeys) {
                    if (-not ($plain -and $text -cmatch '\A[1-9][0-9]{0,9}\z' -and [long]$text -le [int]::MaxValue)) {
                        New-NeoIPCCheckFinding -Rule 'record-number' -Location $line -Message "The $key '$text' is not written as a plain integer from 1 to 2147483647."
                    }
                }
                elseif ($key -cin $script:NeoIPCInfectiousAgentFlagKeys) {
                    if (-not ($plain -and $text -cmatch '\A(?:true|True|TRUE|false|False|FALSE)\z')) {
                        New-NeoIPCCheckFinding -Rule 'flag-type' -Location $line -Message "The flag $key is '$text', not one of YAML 1.2.2's plain Booleans (true, True, TRUE, false, False, FALSE)."
                    }
                }
            }
            if ($isCollection) { $frames.Push(@{ Kind = $kind; Place = $place; ExpectKey = $true }) }
        }
    }
    catch [YamlDotNet.Core.YamlException] {
        New-NeoIPCCheckFinding -Rule 'yaml-syntax' -Location "line $($_.Exception.Start.Line)" -Message "The file is not valid YAML: $($_.Exception.Message)"
    }
    catch {
        New-NeoIPCCheckFinding -Rule 'yaml-reader' -Location '' -Message "The check could not read the text: $($_.Exception.Message)"
    }
}

function Get-NeoIPCInfectiousAgentNodeRecord {
    # Every node of a list of ontology nodes (the root's Hierarchies, or a node's Synonyms or Children), as
    # @{ Node; IsSynonym; IsTop }, depth first in the walkers' order (a node, then its Synonyms and Children). A node
    # without a Name or an Id is a node too, for the checks to report. A synonym's Children are concepts.
    [CmdletBinding()]
    [OutputType([System.Collections.Hashtable])]
    param([AllowNull()]$Node, [bool]$IsSynonym, [bool]$IsTop)
    if ($Node -is [System.Collections.IList]) {
        foreach ($item in $Node) { Get-NeoIPCInfectiousAgentNodeRecord -Node $item -IsSynonym $IsSynonym -IsTop $IsTop }
        return
    }
    if ($Node -isnot [System.Collections.IDictionary]) { return }
    @{ Node = $Node; IsSynonym = $IsSynonym; IsTop = $IsTop }
    if ($Node.Contains('Synonyms')) { Get-NeoIPCInfectiousAgentNodeRecord -Node $Node['Synonyms'] -IsSynonym $true -IsTop $false }
    if ($Node.Contains('Children')) { Get-NeoIPCInfectiousAgentNodeRecord -Node $Node['Children'] -IsSynonym $false -IsTop $false }
}

function Get-NeoIPCInfectiousAgentNodeLocation {
    # How a finding names a node: by its Id where it has one, else by its name.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Node)
    if ($Node.Contains('Id') -and $null -ne $Node['Id']) { "Id $($Node['Id'])" } else { "'$($Node['Name'])'" }
}

function Get-NeoIPCInfectiousAgentNodeFinding {
    # Checks each node of a parsed ontology tree: a unique Id typed as an integer, which becomes the option code; a
    # Name; a rank from the vocabulary on every Id-bearing concept, since the option label is built from it; a
    # ConceptSource the list's UrlTemplates name, in their spelling, with that source's record number typed as an
    # integer and no other source's number; a ConceptId; Boolean flags; and the two nodes the generated metadata relies
    # on, the top-level Id 0 ("Not listed", the option for an infectious agent the list lacks) and the top-level Viruses,
    # NeoIPC's own node above ICTV's realms, whose subtree is the virus set the pneumonia rules test.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowNull()]$Tree)

    if ($Tree -isnot [System.Collections.IDictionary] -or -not $Tree.Contains('Hierarchies')) {
        New-NeoIPCCheckFinding -Rule 'structure' -Location '' -Message 'The ontology has no Hierarchies.'
        return
    }
    $sources = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    if ($Tree.Contains('Metadata') -and $Tree['Metadata'] -is [System.Collections.IDictionary] -and
        $Tree['Metadata'].Contains('UrlTemplates') -and $Tree['Metadata']['UrlTemplates'] -is [System.Collections.IDictionary]) {
        foreach ($name in $Tree['Metadata']['UrlTemplates'].Keys) { [void]$sources.Add([string]$name) }
    }
    else {
        New-NeoIPCCheckFinding -Rule 'structure' -Location '' -Message 'The ontology has no Metadata.UrlTemplates naming its sources.'
    }

    $seenIds = [System.Collections.Generic.Dictionary[long, string]]::new()
    $hasNotListed = $false
    $hasViruses = $false
    foreach ($record in @(Get-NeoIPCInfectiousAgentNodeRecord -Node $Tree['Hierarchies'] -IsSynonym $false -IsTop $true)) {
        $node = $record.Node
        $location = Get-NeoIPCInfectiousAgentNodeLocation -Node $node
        $name = [string]$node['Name']
        if ([string]::IsNullOrWhiteSpace($name)) {
            New-NeoIPCCheckFinding -Rule 'name' -Location $location -Message 'The node has no Name.'
        }

        $hasId = $node.Contains('Id')
        if ($hasId) {
            $id = $node['Id']
            if ($id -isnot [int] -and $id -isnot [long]) {
                New-NeoIPCCheckFinding -Rule 'id-type' -Location $location -Message "The Id '$id' is not an integer; it becomes the DHIS2 option code."
            }
            elseif ($seenIds.ContainsKey([long]$id)) {
                New-NeoIPCCheckFinding -Rule 'id-duplicate' -Location $location -Message "The Id is also that of '$($seenIds[[long]$id])'."
            }
            else {
                $seenIds[[long]$id] = $name
            }
            if ($record.IsTop -and $id -is [int] -and $id -eq 0) { $hasNotListed = $true }
        }
        if ($record.IsTop -and $name -ceq 'Viruses') { $hasViruses = $true }

        if ($node.Contains('ConceptType')) {
            $type = [string]$node['ConceptType']
            if (-not $script:NeoIPCInfectiousAgentConceptTypes.Contains($type)) {
                New-NeoIPCCheckFinding -Rule 'concept-type' -Location $location -Message "The rank '$type' is not one of the list's ranks."
            }
        }
        elseif ($hasId -and -not $record.IsSynonym) {
            New-NeoIPCCheckFinding -Rule 'concept-type' -Location $location -Message 'The concept has no ConceptType, from which its option label takes its rank.'
        }

        $source = if ($node.Contains('ConceptSource')) { [string]$node['ConceptSource'] } else { '' }
        if (-not $sources.Contains($source)) {
            New-NeoIPCCheckFinding -Rule 'concept-source' -Location $location -Message "The ConceptSource '$source' is not a source the list's UrlTemplates name, in their spelling."
        }
        if (-not $node.Contains('ConceptId') -or [string]::IsNullOrWhiteSpace([string]$node['ConceptId'])) {
            New-NeoIPCCheckFinding -Rule 'concept-id' -Location $location -Message 'The node has no ConceptId.'
        }
        foreach ($entry in $script:NeoIPCInfectiousAgentRecordNumberKeys.GetEnumerator()) {
            $numberKey = $entry.Value
            if ($entry.Key -ceq $source) {
                $number = if ($node.Contains($numberKey)) { $node[$numberKey] } else { $null }
                if ($number -isnot [int] -and $number -isnot [long]) {
                    New-NeoIPCCheckFinding -Rule 'record-number' -Location $location -Message "A $source concept needs its $numberKey as an integer; it has '$number'."
                }
            }
            elseif ($node.Contains($numberKey)) {
                New-NeoIPCCheckFinding -Rule 'record-number' -Location $location -Message "The node carries $numberKey, which belongs to $($entry.Key), while its source is '$source'."
            }
        }
        foreach ($flag in $script:NeoIPCInfectiousAgentFlagKeys) {
            if ($node.Contains($flag) -and $node[$flag] -isnot [bool]) {
                New-NeoIPCCheckFinding -Rule 'flag-type' -Location $location -Message "The flag $flag is '$($node[$flag])', not true or false."
            }
        }
    }
    if (-not $hasNotListed) {
        New-NeoIPCCheckFinding -Rule 'required-node' -Location '' -Message 'No top-level node has the Id 0, the option for an infectious agent the list lacks.'
    }
    if (-not $hasViruses) {
        New-NeoIPCCheckFinding -Rule 'required-node' -Location '' -Message 'No top-level node is named Viruses, the node above ICTV''s realms whose subtree is the virus set.'
    }
}

function Get-NeoIPCInfectiousAgentLabelFinding {
    # Checks the English option labels the list generates, one per Id-bearing node: none longer than the 230 characters
    # of DHIS2's Option.name column, and no two alike. DHIS2's metadata import rejects an option whose name another
    # option of its option set already has (OptionObjectBundleHook, error E4028), comparing exactly, as this check
    # does; and a user picking an infectious agent could not tell two such options apart.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowNull()]$Tree)

    try { $concepts = @(Get-NeoIPCInfectiousAgentConcept -Node $Tree) }
    catch {
        New-NeoIPCCheckFinding -Rule 'label' -Location '' -Message "The labels cannot be built: $($_.Exception.Message)"
        return
    }
    $byLabel = [System.Collections.Generic.Dictionary[string, int]]::new([System.StringComparer]::Ordinal)
    foreach ($c in $concepts) {
        $label = Get-NeoIPCPathogenOptionLabel -Name $c.Name -ConceptType $c.ConceptType -IsSynonym $c.IsSynonym
        if ($label.Length -gt 230) {
            New-NeoIPCCheckFinding -Rule 'label-length' -Location "Id $($c.Id)" -Message "The label has $($label.Length) characters; DHIS2 stores 230."
        }
        if ($byLabel.ContainsKey($label)) {
            New-NeoIPCCheckFinding -Rule 'label-duplicate' -Location "Id $($c.Id)" -Message "The label '$label' is also that of Id $($byLabel[$label])."
        }
        else {
            $byLabel[$label] = $c.Id
        }
    }
}

function Get-NeoIPCInfectiousAgentUidFinding {
    # Checks the UID sidecar (NeoIPC-Infectious-Agents.uids.csv, the UID of every option) against the ontology: every
    # Id of the list has a row, since no option UID is derived; every id is an Id of the list and appears once; and
    # every uid is a well-formed DHIS2 UID, used once and not the option set's own.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowNull()]$Tree,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object[]]$UidRow
    )

    try { $ids = [System.Collections.Generic.HashSet[string]]::new([string[]]@(Get-NeoIPCInfectiousAgentConcept -Node $Tree | ForEach-Object { [string]$_.Id }), [System.StringComparer]::Ordinal) }
    catch {
        New-NeoIPCCheckFinding -Rule 'uid' -Location '' -Message "The list's Ids cannot be read: $($_.Exception.Message)"
        return
    }
    $seenIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $seenUids = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    foreach ($row in $UidRow) {
        if ($null -eq $row) {
            New-NeoIPCCheckFinding -Rule 'uid' -Location '' -Message 'The sidecar comes with an empty row.'
            continue
        }
        $id = [string]$row.id
        $uid = [string]$row.uid
        if (-not $seenIds.Add($id)) {
            New-NeoIPCCheckFinding -Rule 'uid-id-duplicate' -Location "id $id" -Message 'The sidecar lists the id twice.'
        }
        if (-not $ids.Contains($id)) {
            New-NeoIPCCheckFinding -Rule 'uid-orphan' -Location "id $id" -Message 'The sidecar lists an id that is no Id of the list.'
        }
        if ($uid -cnotmatch '\A[A-Za-z][A-Za-z0-9]{10}\z') {
            New-NeoIPCCheckFinding -Rule 'uid-format' -Location "id $id" -Message "The uid '$uid' is not a DHIS2 UID (a letter, then ten letters or digits)."
        }
        elseif ($uid -ceq $script:NeoIPCPathogenOptionSetUid) {
            New-NeoIPCCheckFinding -Rule 'uid-duplicate' -Location "id $id" -Message "The uid '$uid' is that of the option set itself."
        }
        elseif ($seenUids.ContainsKey($uid)) {
            New-NeoIPCCheckFinding -Rule 'uid-duplicate' -Location "id $id" -Message "The uid '$uid' is also that of id $($seenUids[$uid])."
        }
        else {
            $seenUids[$uid] = $id
        }
    }
    foreach ($id in @($ids | Where-Object { -not $seenIds.Contains($_) } | Sort-Object { [long]$_ })) {
        New-NeoIPCCheckFinding -Rule 'uid-missing' -Location "Id $id" -Message 'The sidecar lacks the Id, so its option has no UID; Add-NeoIPCInfectiousAgentUid draws one at random.'
    }
}

$script:NeoIPCGitLocalVariables = $null

function Get-NeoIPCGitLocalVariable {
    # The environment variables that tie git to one repository (GIT_DIR, GIT_WORK_TREE, GIT_INDEX_FILE, and their
    # kin), as git itself lists them. git exports some of them to its hooks, so a git command started from a hook
    # inherits them, and they outrank -C: run in a submodule, which keeps its repository behind a .git file, it would
    # read and write the hook's repository instead of the one named.
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    if ($null -eq $script:NeoIPCGitLocalVariables) {
        $names = @(& git rev-parse --local-env-vars)
        if ($LASTEXITCODE -ne 0) { throw "git rev-parse --local-env-vars failed (exit code $LASTEXITCODE)." }
        $script:NeoIPCGitLocalVariables = $names
    }
    $script:NeoIPCGitLocalVariables
}

function Invoke-NeoIPCGitText {
    # Runs git in a repository and returns its standard output as one text, decoded as UTF-8, the encoding the list's
    # files are written in, whatever the console's code page, with which PowerShell decodes a native command's output.
    # git runs without the variables that would tie it to another repository than the one named. Throws with git's own
    # message when git fails.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$RepositoryRoot, [Parameter(Mandatory)][string[]]$Argument)
    $start = [System.Diagnostics.ProcessStartInfo]::new('git')
    foreach ($item in @('-C', $RepositoryRoot) + $Argument) { $start.ArgumentList.Add($item) }
    foreach ($name in Get-NeoIPCGitLocalVariable) { [void]$start.Environment.Remove($name) }
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $start.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
    $process = [System.Diagnostics.Process]::Start($start)
    try {
        # Both streams are read at once, so that git cannot stall on a full pipe that nobody reads.
        $output = $process.StandardOutput.ReadToEndAsync()
        $errorOutput = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw "git $($Argument -join ' ') failed in '$RepositoryRoot': $($errorOutput.Result.Trim())" }
        $output.Result
    }
    finally { $process.Dispose() }
}

function Read-NeoIPCInfectiousAgentRelease {
    # Reads every released version of the list from the repository's infectious-agents-v* tags: for each, the tag, its
    # version, the Id->Name map of the ontology at that tag, the id->uid map of its UID sidecar (empty where the tag
    # predates the sidecar), and whether the release is in the history of HEAD. A release of a later line is not, on a
    # branch that maintains an earlier one. In a shallow clone, whose history cannot show that, every release counts as
    # in it. Returns nothing in a clone without the tags, which the release check reports.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [string]$ListPath = 'metadata/common/infectious-agents'
    )
    Import-Module powershell-yaml -ErrorAction Stop
    # for-each-ref, git's plumbing, rather than tag --list, whose output a column.ui setting reflows.
    $listTags = {
        param([string[]]$Filter = @())
        (Invoke-NeoIPCGitText -RepositoryRoot $RepositoryRoot -Argument (@('for-each-ref', '--format=%(refname:lstrip=2)') + $Filter + 'refs/tags/infectious-agents-v*')).Split("`n", [System.StringSplitOptions]::RemoveEmptyEntries)
    }
    $tags = @(& $listTags)
    $shallow = (Invoke-NeoIPCGitText -RepositoryRoot $RepositoryRoot -Argument 'rev-parse', '--is-shallow-repository').Trim() -ceq 'true'
    $inHistory = [System.Collections.Generic.HashSet[string]]::new([string[]]@(if ($shallow) { $tags } else { & $listTags '--merged=HEAD' }), [System.StringComparer]::Ordinal)
    foreach ($tag in $tags) {
        # The full name, since a ref of the same name outside refs/tags/ (refs/<name>, or a file in the git directory),
        # which git's disambiguation ranks above a tag, would stand in for it.
        $ref = "refs/tags/$tag"
        $yaml = Invoke-NeoIPCGitText -RepositoryRoot $RepositoryRoot -Argument 'cat-file', 'blob', "${ref}:$ListPath/NeoIPC-Infectious-Agents.yaml"
        $concepts = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
        foreach ($c in @(Get-NeoIPCInfectiousAgentConcept -Node ($yaml | ConvertFrom-Yaml))) { $concepts[[string]$c.Id] = $c.Name }
        $uids = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
        $sidecar = "$ListPath/NeoIPC-Infectious-Agents.uids.csv"
        if ((Invoke-NeoIPCGitText -RepositoryRoot $RepositoryRoot -Argument 'ls-tree', '--name-only', $ref, '--', $sidecar).Trim()) {
            $rows = (Invoke-NeoIPCGitText -RepositoryRoot $RepositoryRoot -Argument 'cat-file', 'blob', "${ref}:$sidecar").Split("`n") |
                ForEach-Object { $_.TrimEnd("`r") } | Where-Object { $_ }
            foreach ($row in @($rows | ConvertFrom-Csv)) { $uids[[string]$row.id] = [string]$row.uid }
        }
        [pscustomobject]@{
            Tag = $tag; Version = $tag.Substring('infectious-agents-v'.Length); Concepts = $concepts; Uids = $uids
            InHistory = $inHistory.Contains($tag)
        }
    }
}

function Get-NeoIPCChangelogSection {
    # The second-level sections of a Keep a Changelog file, one [pscustomobject] each: the Version in its heading's
    # leading brackets, Unreleased among them, the Heading, its Line, and HasEntries, whether anything follows before
    # the next heading of its level or above but subheadings, link reference definitions, HTML blocks, and thematic
    # breaks: a list of changes, or text in any other form. Keep a Changelog writes "[1.2.3] - 2026-11-02", and also a
    # link on the version and a trailing [YANKED]; the version is read from all of these. Version is $null where a
    # heading names none in brackets. Markdig, behind ConvertFrom-Markdown, finds the headings and the blocks, and the
    # version is read from each heading's source text, whose form no parser reads.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path)
    $markdown = [System.IO.File]::ReadAllText($PSCmdlet.GetUnresolvedProviderPathFromPSPath($Path))
    $section = $null
    foreach ($block in (ConvertFrom-Markdown -InputObject $markdown).Tokens) {
        if ($block -is [Markdig.Syntax.HeadingBlock] -and $block.Level -le 2) {
            if ($null -ne $section) { $section }
            $section = $null
            if ($block.Level -eq 2) {
                $source = $markdown.Substring($block.Span.Start, $block.Span.Length)
                $heading = (($source -split '\r?\n')[0] -replace '\A##[ \t]*', '' -replace '[ \t]#+[ \t]*\z', '').Trim()
                $version = if ($heading -cmatch '\A\[(?<version>[^\]]+)\]') { $Matches.version } else { $null }
                $section = [pscustomobject]@{ Version = $version; Heading = $heading; Line = $block.Line + 1; HasEntries = $false }
            }
        }
        elseif ($null -ne $section -and -not ($block -is [Markdig.Syntax.HeadingBlock] -or $block -is [Markdig.Syntax.LinkReferenceDefinitionGroup] -or
                $block -is [Markdig.Syntax.LinkReferenceDefinition] -or $block -is [Markdig.Syntax.HtmlBlock] -or $block -is [Markdig.Syntax.ThematicBreakBlock])) {
            $section.HasEntries = $true
        }
    }
    if ($null -ne $section) { $section }
}

function Get-NeoIPCChangelogRelease {
    # The releases a Keep a Changelog file records: its sections (Get-NeoIPCChangelogSection) but [Unreleased], in any
    # letter case, each with its Version, Heading, and Line. Version is $null where a heading names none in brackets,
    # which the release check reports rather than skips.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path)
    Get-NeoIPCChangelogSection -Path $Path | Where-Object { $_.Version -ne 'Unreleased' } | Select-Object -Property Version, Heading, Line
}

function Test-NeoIPCChangelogUnreleasedEntry {
    # Whether a Keep a Changelog file's [Unreleased] section lists a change. The pull request that prepares a release
    # moves the entries under the release's own heading, which leaves the section empty.
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)
    @(Get-NeoIPCChangelogSection -Path $Path | Where-Object { $_.Version -eq 'Unreleased' -and $_.HasEntries }).Count -gt 0
}

function Get-NeoIPCInfectiousAgentReleaseFinding {
    # Holds the list append-only against every release: an Id once released keeps its Name and the UID a release's
    # sidecar gave it, an Id new since the releases exceeds every released Id, so that a recycled code can never carry
    # two meanings in collected records, and a released Id never disappears, nor does its UID. Only a branch that
    # maintains an earlier line may lack Ids: those of a release outside the history of HEAD whose line, its
    # MAJOR.MINOR as the release job's monotonic guard reads it, is later than that of the version the list's VERSION
    # file names. It fails closed: with no release at all, or without the tag of a release the list's CHANGELOG
    # records, the clone lacks tags, and nothing could be compared. Only the version the VERSION file names needs no
    # tag while the CHANGELOG's [Unreleased] section lists no change, as while that release is prepared, its entries
    # moved under its own heading, since its tag names the commit that merges the preparation; until that tag is
    # pushed, nothing in a clone tells the release from its preparation.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        # The current list: Concepts (Id->Name) and Uids (id->uid), as Read-NeoIPCInfectiousAgentRelease returns them.
        [Parameter(Mandatory)][AllowNull()]$Current,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object[]]$Release,
        # The releases the list's CHANGELOG records, as Get-NeoIPCChangelogRelease returns them.
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object[]]$ChangelogRelease,
        # The version the list's VERSION file names.
        [Parameter(Mandatory)][AllowEmptyString()][string]$PreparedVersion,
        # Whether the CHANGELOG's [Unreleased] section lists a change, as Test-NeoIPCChangelogUnreleasedEntry tells.
        [Parameter(Mandatory)][bool]$HasUnreleasedEntry
    )

    # Each map copied into an ordinal dictionary keyed by an Id's decimal text, so that a map keyed by integers, or an
    # ordered one, compares as one keyed by text does, and one without a map, or with a key that is no Id, is reported
    # rather than compared. The entries are enumerated, since an ordered map's indexer reads an integer as a position.
    $copyMap = {
        param($Map)
        if ($Map -isnot [System.Collections.IDictionary]) { return }
        $copy = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
        foreach ($entry in $Map.GetEnumerator()) {
            $text = [string]$entry.Key
            if ($text -cnotmatch '\A(?:0|[1-9][0-9]{0,17})\z' -or $copy.ContainsKey($text)) { return }
            $copy[$text] = [string]$entry.Value
        }
        , $copy
    }
    # A version's line, its MAJOR.MINOR; nothing for a text that is no version, so that no release is exempt by it.
    $lineOf = {
        param([string]$Version)
        if ($Version -cmatch '\A(?<major>0|[1-9][0-9]{0,8})\.(?<minor>0|[1-9][0-9]{0,8})\.') { [version]::new([int]$Matches.major, [int]$Matches.minor) }
    }
    $currentLine = & $lineOf $PreparedVersion
    $currentConcepts = & $copyMap $Current.Concepts
    $currentUids = & $copyMap $Current.Uids
    if ($null -eq $currentConcepts -or $null -eq $currentUids) {
        New-NeoIPCCheckFinding -Rule 'release-input' -Location '' -Message 'The current list comes without its Id->Name and id->uid maps keyed by Ids, so the releases cannot be compared.'
        return
    }
    if ($Release.Count -eq 0) {
        New-NeoIPCCheckFinding -Rule 'release-tags' -Location '' -Message 'No infectious-agents-v* tag is present, so the releases cannot be compared; fetch the tags (a full clone, or fetch-depth 0 in CI).'
        return
    }
    $releases = [System.Collections.Generic.List[pscustomobject]]::new()
    foreach ($r in $Release) {
        $concepts = & $copyMap $r.Concepts
        $uids = & $copyMap $r.Uids
        if ($null -eq $concepts -or $null -eq $uids) {
            New-NeoIPCCheckFinding -Rule 'release-input' -Location "$($r.Tag)" -Message 'The release comes without its Id->Name and id->uid maps keyed by Ids, so it cannot be compared.'
            continue
        }
        # A release that says nothing of its history counts as in it, so that the check fails closed. One outside it
        # on the same line or an earlier one, a backport seen from main or a tag on a commit main never took, is held
        # in full.
        $line = & $lineOf ([string]$r.Version)
        $laterLine = $r.InHistory -eq $false -and $null -ne $line -and $null -ne $currentLine -and $line -gt $currentLine
        $releases.Add([pscustomobject]@{ Tag = [string]$r.Tag; Concepts = $concepts; Uids = $uids; LaterLine = $laterLine })
    }

    $tagged = [System.Collections.Generic.HashSet[string]]::new([string[]]@($Release | ForEach-Object { [string]$_.Version }), [System.StringComparer]::Ordinal)
    foreach ($entry in $ChangelogRelease) {
        if ([string]::IsNullOrEmpty($entry.Version)) {
            New-NeoIPCCheckFinding -Rule 'changelog-heading' -Location "line $($entry.Line)" -Message "The CHANGELOG heading '$($entry.Heading)' names no version in brackets, so its release cannot be compared."
        }
        elseif (-not $tagged.Contains($entry.Version) -and -not ($entry.Version -ceq $PreparedVersion -and -not $HasUnreleasedEntry)) {
            $message = 'The CHANGELOG records this release, but its tag is missing, so it cannot be compared.'
            if ($entry.Version -ceq $PreparedVersion) { $message += ' The VERSION file names it, but [Unreleased] lists changes, so it is no longer being prepared: its tag must be pushed, or fetched.' }
            New-NeoIPCCheckFinding -Rule 'release-tags' -Location "infectious-agents-v$($entry.Version)" -Message $message
        }
    }
    $maximum = [long]::MinValue
    $released = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    # One finding per Id and kind, from the first release that shows it, however many releases carried the Id.
    $reported = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($r in $releases) {
        foreach ($entry in $r.Concepts.GetEnumerator()) {
            [void]$released.Add($entry.Key)
            $maximum = [Math]::Max($maximum, [long]$entry.Key)
            if (-not $currentConcepts.ContainsKey($entry.Key)) {
                if (-not $r.LaterLine -and $reported.Add("id $($entry.Key)")) {
                    New-NeoIPCCheckFinding -Rule 'release-id-removed' -Location "Id $($entry.Key)" -Message "Released in $($r.Tag) as '$($entry.Value)', the Id is gone."
                }
            }
            elseif ($currentConcepts[$entry.Key] -cne $entry.Value -and $reported.Add("name $($entry.Key)")) {
                New-NeoIPCCheckFinding -Rule 'release-name-changed' -Location "Id $($entry.Key)" -Message "Released in $($r.Tag) as '$($entry.Value)', the Id is now named '$($currentConcepts[$entry.Key])'."
            }
        }
        foreach ($entry in $r.Uids.GetEnumerator()) {
            if (-not $currentUids.ContainsKey($entry.Key)) {
                if (-not $r.LaterLine -and $reported.Add("uid $($entry.Key)")) {
                    New-NeoIPCCheckFinding -Rule 'release-uid-changed' -Location "id $($entry.Key)" -Message "Released in $($r.Tag) with the uid $($entry.Value), the id is gone from the sidecar."
                }
            }
            elseif ($currentUids[$entry.Key] -cne $entry.Value -and $reported.Add("uid $($entry.Key)")) {
                New-NeoIPCCheckFinding -Rule 'release-uid-changed' -Location "id $($entry.Key)" -Message "Released in $($r.Tag) with the uid $($entry.Value), the id now has $($currentUids[$entry.Key])."
            }
        }
    }
    foreach ($id in $currentConcepts.Keys) {
        if (-not $released.Contains($id) -and [long]$id -le $maximum) {
            New-NeoIPCCheckFinding -Rule 'release-id-reused' -Location "Id $id" -Message "The Id is new since the releases but not above their highest Id, $maximum."
        }
    }
}

function Get-NeoIPCFrozenInfectiousAgentCsvFinding {
    # NEOIPC-COMPAT(legacy-infectious-agent-csv): see $script:NeoIPCFrozenInfectiousAgentCsvSha256. Reports either
    # frozen CSV missing from the directory, unreadable, or changed in a single byte.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Directory)
    if ([string]::IsNullOrEmpty($Directory)) {
        New-NeoIPCCheckFinding -Rule 'frozen-csv' -Location '' -Message 'No directory is named, so the frozen CSVs cannot be checked.'
        return
    }
    foreach ($entry in $script:NeoIPCFrozenInfectiousAgentCsvSha256.GetEnumerator()) {
        $path = Join-Path $Directory $entry.Key
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            New-NeoIPCCheckFinding -Rule 'frozen-csv' -Location $entry.Key -Message 'The frozen CSV is missing; readers outside this repository download it from main.'
            continue
        }
        try { $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant() }
        catch {
            New-NeoIPCCheckFinding -Rule 'frozen-csv' -Location $entry.Key -Message "The frozen CSV cannot be read: $($_.Exception.Message)"
            continue
        }
        if ($hash -cne $entry.Value) {
            New-NeoIPCCheckFinding -Rule 'frozen-csv' -Location $entry.Key -Message 'The frozen CSV has changed; readers outside this repository download it from main, so it stays byte for byte as it is.'
        }
    }
}
