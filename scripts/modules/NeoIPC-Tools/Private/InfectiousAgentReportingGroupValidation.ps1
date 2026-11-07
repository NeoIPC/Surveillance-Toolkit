#Requires -Version 7.6

# Checks of the reporting classification, NeoIPC-Infectious-Agent-Reporting-Groups.yaml, against the infectious-agent
# ontology it classifies, and of how the translation catalogue takes the two apart. The classification sorts every
# Id-bearing node of the ontology but the Ids 0 and 3561 into one leaf of a tree of reporting groups, by the group of its
# nearest listed ancestor-or-self, and gives every Id-bearing bacterial node one value of each attribute, by the nearest
# assignment on its path to the root. Like the ontology's checks (InfectiousAgentValidation.ps1), each Get-NeoIPC*Finding
# function returns one [pscustomobject] per finding, from New-NeoIPCCheckFinding, and never throws;
# MetadataContent.Tests.ps1 applies them to the committed files, and CI applies the translation check to the localized
# classifications po4a writes.

# The keys of each place in the classification, compared ordinally: powershell-yaml reads mappings case-insensitively,
# so a key in another letter case would pass a lookup unseen. YamlPortability.Tests.ps1 reports a key repeated in
# another case.
$script:NeoIPCReportingGroupPlaceKeys = @{
    Root       = @('Groups', 'Attributes')
    Group      = @('Key', 'Name', 'EcdcCategory', 'Definition', 'Evidence', 'Children', 'Members')
    Member     = @('Name', 'ConceptSource', 'ConceptId', 'Evidence', 'Reason')
    Attribute  = @('Key', 'Name', 'Values', 'Assignments')
    Value      = @('Key', 'Name')
    Assignment = @('Name', 'ConceptSource', 'ConceptId', 'Value', 'Evidence', 'Reason')
}

# The nine categories of Annex 1 of ECDC's protocol for the surveillance of healthcare-associated infections in
# intensive care units (HAI-Net ICU protocol, version 2.3, doi:10.2900/7455254), spelled as the annex spells them. A
# group's EcdcCategory names the one whose figures its own are set against.
$script:NeoIPCEcdcCategories = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@('Gram-positive cocci', 'Gram-negative cocci', 'Gram-positive bacilli', 'Enterobacterales',
        'Gram-negative bacilli', 'Anaerobes', 'Other bacteria', 'Fungi', 'Viruses'),
    [System.StringComparer]::Ordinal)

# The attributes every Id-bearing bacterial node takes one value of, by Key.
$script:NeoIPCReportingGroupRequiredAttributes = @('gram-reaction', 'oxygen-requirement')

# The two nodes that belong to no reporting group: the option for an infectious agent the list lacks (Id 0) and the
# one for an infectious agent the laboratory could not identify (Id 3561). Neither says what the agent was, so no group
# could hold it.
$script:NeoIPCUngroupedInfectiousAgentIds = @(0, 3561)

function Test-NeoIPCReportingGroupText {
    # Whether a value is a text with something in it.
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()]$Value)
    $Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value)
}

function Get-NeoIPCReportingGroupEvidenceFinding {
    # Checks a list of evidence: identifiers of peer-reviewed or official work, each a DOI as doi:10.<registrant>/<suffix>
    # or a PubMed identifier as PMID:<digits>, none repeated.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowNull()]$Evidence, [Parameter(Mandatory)][string]$Location, [bool]$Required)

    if ($null -eq $Evidence) {
        if ($Required) {
            New-NeoIPCCheckFinding -Rule 'evidence-missing' -Location $Location -Message 'The entry carries no Evidence: a DOI or a PMID of the work that supports it.'
        }
        return
    }
    $items = @($Evidence)
    if ($Evidence -isnot [System.Collections.IList] -or $items.Count -eq 0) {
        New-NeoIPCCheckFinding -Rule 'evidence' -Location $Location -Message 'Evidence is not a list of identifiers.'
        return
    }
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($item in $items) {
        if ($item -isnot [string] -or ($item -cnotmatch '\Adoi:10\.[0-9]{4,9}/\S+\z' -and $item -cnotmatch '\APMID:[1-9][0-9]{0,8}\z')) {
            New-NeoIPCCheckFinding -Rule 'evidence' -Location $Location -Message "The evidence '$item' is neither a DOI, written doi:10.<registrant>/<suffix>, nor a PMID, written PMID:<digits>."
        }
        elseif (-not $seen.Add($item)) {
            New-NeoIPCCheckFinding -Rule 'evidence' -Location $Location -Message "The evidence '$item' is listed twice."
        }
    }
}

function Get-NeoIPCReportingGroupKeyFinding {
    # Reports a key of a mapping that its place in the classification does not carry, in that spelling.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Mapping,
        [Parameter(Mandatory)][string]$Place,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Location
    )
    $allowed = $script:NeoIPCReportingGroupPlaceKeys[$Place]
    $placeName = @{ Root = 'the top level'; Group = 'a group'; Member = 'a member'; Attribute = 'an attribute'; Value = 'a value'; Assignment = 'an assignment' }[$Place]
    foreach ($key in @($Mapping.Keys)) {
        if ([string]$key -cnotin $allowed) {
            New-NeoIPCCheckFinding -Rule 'unknown-key' -Location $Location -Message "The key '$key' is not one that $placeName carries: $($allowed -join ', ')."
        }
    }
}

function Get-NeoIPCReportingGroupStructureFinding {
    # Checks the classification on its own: its keys, in their spelling at each place; a tree of groups, each with a
    # Key (lower-case letters and digits joined by hyphens, a stable identifier never translated) and a Name (its
    # English label), both unique, its Evidence, and either Children or Members, never both; an EcdcCategory, where a
    # group has one, from ECDC's nine, the same on every group beneath it, and on every leaf; members and attribute
    # assignments that name an ontology node by ConceptSource, ConceptId, and Name, with their Evidence; texts where
    # texts belong; and the attributes every bacterial node takes, each with a vocabulary of values, Key and Name
    # unique, from which every assignment takes its Value. How the members and assignments meet the ontology is for
    # Get-NeoIPCReportingGroupMemberFinding and Get-NeoIPCReportingGroupAttributeFinding to check.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowNull()]$Classification)

    if ($Classification -isnot [System.Collections.IDictionary]) {
        New-NeoIPCCheckFinding -Rule 'structure' -Location '' -Message 'The classification is not a mapping of Groups and Attributes.'
        return
    }
    Get-NeoIPCReportingGroupKeyFinding -Mapping $Classification -Place 'Root' -Location ''

    $groupKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $groupNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $keyPattern = '\A[a-z0-9]+(?:-[a-z0-9]+)*\z'

    $checkEntry = {
        # A member or an assignment: the node it names, its evidence, and its reason.
        param([System.Collections.IDictionary]$Entry, [string]$Place, [string]$Location)
        Get-NeoIPCReportingGroupKeyFinding -Mapping $Entry -Place $Place -Location $Location
        foreach ($field in 'Name', 'ConceptSource') {
            if (-not (Test-NeoIPCReportingGroupText $Entry[$field])) {
                New-NeoIPCCheckFinding -Rule 'entry' -Location $Location -Message "The entry has no $field."
            }
        }
        if ($null -eq $Entry['ConceptId'] -or [string]::IsNullOrWhiteSpace([string]$Entry['ConceptId'])) {
            New-NeoIPCCheckFinding -Rule 'entry' -Location $Location -Message 'The entry has no ConceptId.'
        }
        Get-NeoIPCReportingGroupEvidenceFinding -Evidence $Entry['Evidence'] -Location $Location -Required $true
        if ($Entry.Contains('Reason') -and -not (Test-NeoIPCReportingGroupText $Entry['Reason'])) {
            New-NeoIPCCheckFinding -Rule 'text' -Location $Location -Message 'Reason is not a text.'
        }
    }

    $checkGroup = {
        param($Group, [string]$Inherited, [string]$Parent)
        if ($Group -isnot [System.Collections.IDictionary]) {
            New-NeoIPCCheckFinding -Rule 'structure' -Location $Parent -Message 'An item of a list of groups is not a mapping.'
            return
        }
        $key = [string]$Group['Key']
        $location = "group '$key'"
        if (-not (Test-NeoIPCReportingGroupText $Group['Key']) -or $key -cnotmatch $keyPattern) {
            New-NeoIPCCheckFinding -Rule 'group-key' -Location $location -Message "The group's Key '$key' is not lower-case letters and digits joined by hyphens."
        }
        elseif (-not $groupKeys.Add($key)) {
            New-NeoIPCCheckFinding -Rule 'group-key' -Location $location -Message 'Another group has the same Key.'
        }
        Get-NeoIPCReportingGroupKeyFinding -Mapping $Group -Place 'Group' -Location $location
        if (-not (Test-NeoIPCReportingGroupText $Group['Name'])) {
            New-NeoIPCCheckFinding -Rule 'group-name' -Location $location -Message 'The group has no Name.'
        }
        elseif (-not $groupNames.Add([string]$Group['Name'])) {
            New-NeoIPCCheckFinding -Rule 'group-name' -Location $location -Message "Another group has the Name '$($Group['Name'])'."
        }
        if ($Group.Contains('Definition') -and -not (Test-NeoIPCReportingGroupText $Group['Definition'])) {
            New-NeoIPCCheckFinding -Rule 'text' -Location $location -Message 'Definition is not a text.'
        }
        Get-NeoIPCReportingGroupEvidenceFinding -Evidence $Group['Evidence'] -Location $location -Required $true

        $category = $Inherited
        if ($Group.Contains('EcdcCategory')) {
            $category = [string]$Group['EcdcCategory']
            if (-not $script:NeoIPCEcdcCategories.Contains($category)) {
                New-NeoIPCCheckFinding -Rule 'ecdc-category' -Location $location -Message "The EcdcCategory '$category' is not one of the nine of ECDC's Annex 1: $(@($script:NeoIPCEcdcCategories) -join ', ')."
            }
            elseif ($Inherited -and $category -cne $Inherited) {
                New-NeoIPCCheckFinding -Rule 'ecdc-category' -Location $location -Message "The group's EcdcCategory '$category' differs from '$Inherited', that of the group above it."
            }
        }

        # A group with both is judged by its Children alone, so that its Members add no follow-on findings.
        $hasChildren = $Group.Contains('Children')
        $hasMembers = $Group.Contains('Members') -and -not $hasChildren
        if ($hasChildren -eq $Group.Contains('Members')) {
            New-NeoIPCCheckFinding -Rule 'group-shape' -Location $location -Message 'A group holds either Children, other groups, or Members, ontology nodes, and exactly one of them.'
        }
        if ($hasChildren) {
            $children = $Group['Children']
            if ($children -isnot [System.Collections.IList] -or @($children).Count -eq 0) {
                New-NeoIPCCheckFinding -Rule 'group-shape' -Location $location -Message 'Children is not a list of groups.'
            }
            else {
                foreach ($child in $children) { & $checkGroup $child $category $location }
            }
        }
        if ($hasMembers) {
            if (-not $category) {
                New-NeoIPCCheckFinding -Rule 'ecdc-category' -Location $location -Message "The group holds members but neither it nor a group above it has an EcdcCategory, so its figures cannot be set against ECDC's."
            }
            $members = $Group['Members']
            if ($members -isnot [System.Collections.IList] -or @($members).Count -eq 0) {
                New-NeoIPCCheckFinding -Rule 'group-shape' -Location $location -Message 'Members is not a list of ontology nodes.'
            }
            else {
                foreach ($member in $members) {
                    if ($member -isnot [System.Collections.IDictionary]) {
                        New-NeoIPCCheckFinding -Rule 'structure' -Location $location -Message 'An item of Members is not a mapping.'
                        continue
                    }
                    & $checkEntry $member 'Member' "$location, member '$($member['Name'])'"
                }
            }
        }
    }

    $groups = $Classification['Groups']
    if ($groups -isnot [System.Collections.IList] -or @($groups).Count -eq 0) {
        New-NeoIPCCheckFinding -Rule 'structure' -Location '' -Message 'The classification has no Groups.'
    }
    else {
        foreach ($group in $groups) { & $checkGroup $group '' '' }
    }

    $attributes = $Classification['Attributes']
    if ($attributes -isnot [System.Collections.IList]) {
        New-NeoIPCCheckFinding -Rule 'structure' -Location '' -Message 'The classification has no list of Attributes.'
        $attributes = @()
    }
    $attributeKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $attributeNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($attribute in $attributes) {
        if ($attribute -isnot [System.Collections.IDictionary]) {
            New-NeoIPCCheckFinding -Rule 'structure' -Location '' -Message 'An item of Attributes is not a mapping.'
            continue
        }
        $key = [string]$attribute['Key']
        $location = "attribute '$key'"
        Get-NeoIPCReportingGroupKeyFinding -Mapping $attribute -Place 'Attribute' -Location $location
        if (-not (Test-NeoIPCReportingGroupText $attribute['Key']) -or $key -cnotmatch $keyPattern) {
            New-NeoIPCCheckFinding -Rule 'attribute-key' -Location $location -Message "The attribute's Key '$key' is not lower-case letters and digits joined by hyphens."
        }
        elseif (-not $attributeKeys.Add($key)) {
            New-NeoIPCCheckFinding -Rule 'attribute-key' -Location $location -Message 'Another attribute has the same Key.'
        }
        if (-not (Test-NeoIPCReportingGroupText $attribute['Name'])) {
            New-NeoIPCCheckFinding -Rule 'attribute-name' -Location $location -Message 'The attribute has no Name.'
        }
        elseif (-not $attributeNames.Add([string]$attribute['Name'])) {
            New-NeoIPCCheckFinding -Rule 'attribute-name' -Location $location -Message "Another attribute has the Name '$($attribute['Name'])'."
        }

        $valueKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        $valueNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        $values = $attribute['Values']
        if ($values -isnot [System.Collections.IList] -or @($values).Count -eq 0) {
            New-NeoIPCCheckFinding -Rule 'attribute-value' -Location $location -Message 'The attribute has no list of Values.'
            $values = @()
        }
        foreach ($value in $values) {
            if ($value -isnot [System.Collections.IDictionary]) {
                New-NeoIPCCheckFinding -Rule 'structure' -Location $location -Message 'An item of Values is not a mapping.'
                continue
            }
            $valueKey = [string]$value['Key']
            $valueLocation = "$location, value '$valueKey'"
            Get-NeoIPCReportingGroupKeyFinding -Mapping $value -Place 'Value' -Location $valueLocation
            if (-not (Test-NeoIPCReportingGroupText $value['Key']) -or $valueKey -cnotmatch $keyPattern) {
                New-NeoIPCCheckFinding -Rule 'attribute-value' -Location $valueLocation -Message "The value's Key '$valueKey' is not lower-case letters and digits joined by hyphens."
            }
            elseif (-not $valueKeys.Add($valueKey)) {
                New-NeoIPCCheckFinding -Rule 'attribute-value' -Location $valueLocation -Message 'Another value of the attribute has the same Key.'
            }
            if (-not (Test-NeoIPCReportingGroupText $value['Name'])) {
                New-NeoIPCCheckFinding -Rule 'attribute-value' -Location $valueLocation -Message 'The value has no Name.'
            }
            elseif (-not $valueNames.Add([string]$value['Name'])) {
                New-NeoIPCCheckFinding -Rule 'attribute-value' -Location $valueLocation -Message "Another value of the attribute has the Name '$($value['Name'])'."
            }
        }

        $assignments = $attribute['Assignments']
        if ($assignments -isnot [System.Collections.IList] -or @($assignments).Count -eq 0) {
            New-NeoIPCCheckFinding -Rule 'structure' -Location $location -Message 'The attribute has no list of Assignments.'
            continue
        }
        foreach ($assignment in $assignments) {
            if ($assignment -isnot [System.Collections.IDictionary]) {
                New-NeoIPCCheckFinding -Rule 'structure' -Location $location -Message 'An item of Assignments is not a mapping.'
                continue
            }
            $assignmentLocation = "$location, assignment '$($assignment['Name'])'"
            & $checkEntry $assignment 'Assignment' $assignmentLocation
            if (-not $valueKeys.Contains([string]$assignment['Value'])) {
                New-NeoIPCCheckFinding -Rule 'attribute-value' -Location $assignmentLocation -Message "The Value '$($assignment['Value'])' is not the Key of one of the attribute's Values."
            }
        }
    }
    foreach ($required in $script:NeoIPCReportingGroupRequiredAttributes) {
        if (-not $attributeKeys.Contains($required)) {
            New-NeoIPCCheckFinding -Rule 'attribute-missing' -Location '' -Message "The classification has no attribute with the Key '$required', which every Id-bearing bacterial node takes a value of."
        }
    }
}

function Get-NeoIPCInfectiousAgentIndex {
    # An index of a parsed ontology tree for the classification's checks. Concepts maps the key
    # "<ConceptSource>|<ConceptId>" of every concept, Id-bearing or not, to the list of concepts with that key, each as
    # @{ Node; Name; ParentKey; IsBacterial }, where ParentKey is the key of the nearest concept above it (a synonym's
    # Children count as its concept's) and IsBacterial says whether it sits under the top-level Bacteria; a key with
    # more than one concept is the identity check's to report. SynonymKeys holds the keys of the synonyms, which take
    # their concept's group and values, IdBearing every node with an Id, concept or synonym, as
    # @{ Id; Location; ConceptKey }, a synonym's ConceptKey being its concept's, and NodeNames maps the Name of every
    # node, concept or synonym, to the keys of the concepts it names, a synonym's being its concept's.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowNull()]$Tree)

    $concepts = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[hashtable]]]::new([System.StringComparer]::Ordinal)
    $synonymKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $idBearing = [System.Collections.Generic.List[pscustomobject]]::new()
    $nodeNames = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.HashSet[string]]]::new([System.StringComparer]::Ordinal)
    $addName = {
        param([string]$Name, [string]$ConceptKey)
        if (-not $Name) { return }
        if (-not $nodeNames.ContainsKey($Name)) { $nodeNames[$Name] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal) }
        [void]$nodeNames[$Name].Add($ConceptKey)
    }
    $items = {
        param($Value)
        if ($Value -is [System.Collections.IList]) { foreach ($item in $Value) { & $items $item } }
        elseif ($Value -is [System.Collections.IDictionary]) { $Value }
    }
    $keyOf = { param([System.Collections.IDictionary]$Node) '{0}|{1}' -f [string]$Node['ConceptSource'], [string]$Node['ConceptId'] }
    $addIdBearing = {
        param([System.Collections.IDictionary]$Node, [string]$ConceptKey)
        if ($Node.Contains('Id') -and $null -ne $Node['Id']) {
            $idBearing.Add([pscustomobject]@{ Id = $Node['Id']; Location = (Get-NeoIPCInfectiousAgentNodeLocation -Node $Node); ConceptKey = $ConceptKey })
        }
    }
    $walkSynonym = {
        param([System.Collections.IDictionary]$Node, [string]$ConceptKey, [bool]$IsBacterial)
        [void]$synonymKeys.Add((& $keyOf $Node))
        & $addIdBearing $Node $ConceptKey
        & $addName ([string]$Node['Name']) $ConceptKey
        if ($Node.Contains('Synonyms')) { foreach ($synonym in @(& $items $Node['Synonyms'])) { & $walkSynonym $synonym $ConceptKey $IsBacterial } }
        if ($Node.Contains('Children')) { foreach ($child in @(& $items $Node['Children'])) { & $walk $child $ConceptKey $IsBacterial } }
    }
    $walk = {
        param([System.Collections.IDictionary]$Node, [string]$ParentKey, [bool]$IsBacterial)
        $key = & $keyOf $Node
        if (-not $concepts.ContainsKey($key)) { $concepts[$key] = [System.Collections.Generic.List[hashtable]]::new() }
        $concepts[$key].Add(@{ Node = $Node; Name = [string]$Node['Name']; ParentKey = $ParentKey; IsBacterial = $IsBacterial })
        & $addIdBearing $Node $key
        & $addName ([string]$Node['Name']) $key
        if ($Node.Contains('Synonyms')) { foreach ($synonym in @(& $items $Node['Synonyms'])) { & $walkSynonym $synonym $key $IsBacterial } }
        if ($Node.Contains('Children')) { foreach ($child in @(& $items $Node['Children'])) { & $walk $child $key $IsBacterial } }
    }
    if ($Tree -is [System.Collections.IDictionary] -and $Tree.Contains('Hierarchies')) {
        foreach ($top in @(& $items $Tree['Hierarchies'])) { & $walk $top '' ([string]$top['Name'] -ceq 'Bacteria') }
    }
    [pscustomobject]@{ Concepts = $concepts; SynonymKeys = $synonymKeys; IdBearing = $idBearing; NodeNames = $nodeNames }
}

function Resolve-NeoIPCReportingGroupPlacement {
    # Resolves every Id-bearing node to the placement of its nearest placed ancestor-or-self, a synonym through its
    # concept, from a set of placements of ontology nodes, the members of the groups or the assignments of one
    # attribute, and checks the placements against an index of the ontology (Get-NeoIPCInfectiousAgentIndex) on the way,
    # for its callers to report what it finds. A placement names one concept, by its key and its Name, and no node is
    # placed twice. One that gives a node the value its nearest placed ancestor gives already repeats it; one that gives
    # another is an override, which says why in its Reason; and one from which no Id-bearing node takes its value, as
    # where every Id-bearing node beneath it is placed further down, serves nothing. Returns @{ Findings; Resolved },
    # where Resolved maps the location of each Id-bearing node in scope to the value it takes, $null for none.
    #
    # Each placement is @{ Key; Name; Value; Reason; Location }. Noun says what a placement is in the messages
    # ('member', 'assignment'), and BacteriaOnly limits the check to the nodes under the top-level Bacteria: a
    # placement outside them is reported, and only the Id-bearing nodes among them are resolved.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Placement,
        [Parameter(Mandatory)][pscustomobject]$Index,
        [Parameter(Mandatory)][string]$Noun,
        [switch]$BacteriaOnly
    )

    $findings = [System.Collections.Generic.List[pscustomobject]]::new()
    $byKey = [System.Collections.Generic.Dictionary[string, pscustomobject]]::new([System.StringComparer]::Ordinal)
    foreach ($p in $Placement) {
        $records = $null
        if ($Index.Concepts.ContainsKey($p.Key)) { $records = $Index.Concepts[$p.Key] }
        if ($null -eq $records) {
            $what = if ($Index.SynonymKeys.Contains($p.Key)) { 'names a synonym, which takes the placement of its concept, so the concept is to be named instead' } else { 'names no node of the ontology' }
            $findings.Add((New-NeoIPCCheckFinding -Rule "$Noun-unresolved" -Location $p.Location -Message "The $Noun $what ($($p.Key -replace '\|', ' '))."))
            continue
        }
        if ($records.Count -gt 1) {
            $findings.Add((New-NeoIPCCheckFinding -Rule "$Noun-unresolved" -Location $p.Location -Message "The $Noun's ConceptSource and ConceptId name $($records.Count) nodes of the ontology."))
            continue
        }
        $record = $records[0]
        if ($record.Name -cne $p.Name) {
            $findings.Add((New-NeoIPCCheckFinding -Rule "$Noun-name" -Location $p.Location -Message "The $Noun's Name is '$($p.Name)', while the node it names is '$($record.Name)'."))
        }
        if ($BacteriaOnly -and -not $record.IsBacterial) {
            $findings.Add((New-NeoIPCCheckFinding -Rule "$Noun-scope" -Location $p.Location -Message "The $Noun names a node outside the bacteria, while the attribute applies to bacteria only."))
            continue
        }
        if ($byKey.ContainsKey($p.Key)) {
            $findings.Add((New-NeoIPCCheckFinding -Rule "$Noun-duplicate" -Location $p.Location -Message "The node is placed twice: also at $($byKey[$p.Key].Location)."))
            continue
        }
        $byKey[$p.Key] = $p
    }

    # The nearest effective placement on a concept's path to the root, itself included, or the nearest strictly above
    # it. A placement reported as repeating the value it would take counts as absent, as it is once removed, so that
    # the findings beneath it judge the placements that stay; the placements are judged from the top down for that.
    $effective = [System.Collections.Generic.Dictionary[string, pscustomobject]]::new([System.StringComparer]::Ordinal)
    $nearest = {
        param([string]$Key, [bool]$Strict)
        $current = $Key
        if ($Strict) { $current = $Index.Concepts[$Key][0].ParentKey }
        while ($current) {
            if ($effective.ContainsKey($current)) { return $effective[$current] }
            $current = $Index.Concepts[$current][0].ParentKey
        }
        $null
    }
    $depthOf = {
        param([string]$Key)
        $depth = 0
        $current = $Index.Concepts[$Key][0].ParentKey
        while ($current) { $depth++; $current = $Index.Concepts[$current][0].ParentKey }
        $depth
    }
    foreach ($p in @($byKey.Values | Sort-Object { & $depthOf $_.Key })) {
        $above = & $nearest $p.Key $true
        if ($null -ne $above -and $above.Value -ceq $p.Value) {
            $findings.Add((New-NeoIPCCheckFinding -Rule "$Noun-redundant" -Location $p.Location -Message "The $Noun repeats '$($p.Value)', which the node takes from $($above.Location) already."))
            continue
        }
        if ($null -ne $above -and -not (Test-NeoIPCReportingGroupText $p.Reason)) {
            $findings.Add((New-NeoIPCCheckFinding -Rule "$Noun-reason-missing" -Location $p.Location -Message "The $Noun gives '$($p.Value)' where the node would take '$($above.Value)' from $($above.Location), without a Reason saying why."))
        }
        $effective[$p.Key] = $p
    }

    $resolved = [ordered]@{}
    $takers = [System.Collections.Generic.Dictionary[string, int]]::new([System.StringComparer]::Ordinal)
    foreach ($node in $Index.IdBearing) {
        if (-not $Index.Concepts.ContainsKey($node.ConceptKey)) { continue }
        if ($BacteriaOnly -and -not $Index.Concepts[$node.ConceptKey][0].IsBacterial) { continue }
        $from = & $nearest $node.ConceptKey $false
        if ($null -eq $from) { $resolved[$node.Location] = $null; continue }
        $resolved[$node.Location] = $from.Value
        $takers[$from.Key] = 1 + ($takers[$from.Key] ?? 0)
    }
    foreach ($p in $effective.Values) {
        if (-not $takers.ContainsKey($p.Key)) {
            $findings.Add((New-NeoIPCCheckFinding -Rule "$Noun-unused" -Location $p.Location -Message "No Id-bearing node takes its placement from the ${Noun}: the node has no Id, and every Id-bearing node beneath it, if there is one, is placed further down."))
        }
    }
    @{ Findings = $findings; Resolved = $resolved }
}

function Get-NeoIPCReportingGroupLeaf {
    # The leaf groups of a list of groups, depth first, each as @{ Key; Group; Location; Category }, where Category is
    # the leaf's EcdcCategory, its own or that of the nearest group above it with one.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([AllowNull()]$Groups, [string]$Category)
    foreach ($group in @($Groups)) {
        if ($group -isnot [System.Collections.IDictionary]) { continue }
        $own = if ($group.Contains('EcdcCategory')) { [string]$group['EcdcCategory'] } else { $Category }
        if ($group.Contains('Children')) { Get-NeoIPCReportingGroupLeaf -Groups $group['Children'] -Category $own }
        elseif ($group.Contains('Members')) { @{ Key = [string]$group['Key']; Group = $group; Location = "group '$($group['Key'])'"; Category = $own } }
    }
}

function Get-NeoIPCReportingGroupPlacement {
    # The placements of a list of members or assignments, as Resolve-NeoIPCReportingGroupPlacement takes them, with
    # Value set to the given one, or to each entry's own Value where none is given.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowNull()]$Entry, [Parameter(Mandatory)][string]$Location, [string]$Value, [Parameter(Mandatory)][string]$Noun)
    foreach ($e in @($Entry)) {
        if ($e -isnot [System.Collections.IDictionary]) { continue }
        $placedValue = $Value
        if (-not $placedValue) { $placedValue = [string]$e['Value'] }
        [pscustomobject]@{
            Key      = '{0}|{1}' -f [string]$e['ConceptSource'], [string]$e['ConceptId']
            Name     = [string]$e['Name']
            Value    = $placedValue
            Reason   = $e['Reason']
            Location = "$Location, $Noun '$($e['Name'])'"
        }
    }
}

function Get-NeoIPCReportingGroupMemberFinding {
    # Checks the members of the classification's leaf groups against a parsed ontology tree: each names one concept by
    # its ConceptSource, ConceptId, and Name, none twice, none repeating the group it would take from a member above
    # it, an override saying why in its Reason, and each the group of some Id-bearing node; and every Id-bearing node,
    # concept or synonym, takes one leaf group, from its nearest listed ancestor-or-self, but for the Ids 0 and 3561,
    # which take none. A node no member reaches is reported, never placed in a residual group.
    #
    # Two more rules follow from what the file does not show. A group that shares its EcdcCategory with another sets
    # its members apart by a property the attributes do not show, such as the use of glucose, what makes a bacterium
    # one of the other bacteria, or a fungus's growth as yeast or mould, so each of its members names it in its Reason.
    # And a group named like a node of the ontology shares that node's entry in the translation catalogue, whose one
    # translation fits both only where the group is that taxon: every Id-bearing node beneath the node takes a leaf of
    # the group.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowNull()]$Classification, [Parameter(Mandatory)][AllowNull()]$Tree)

    if ($Classification -isnot [System.Collections.IDictionary] -or $Tree -isnot [System.Collections.IDictionary]) {
        New-NeoIPCCheckFinding -Rule 'structure' -Location '' -Message 'The classification or the ontology is not a mapping.'
        return
    }
    try {
        $index = Get-NeoIPCInfectiousAgentIndex -Tree $Tree
        $leaves = @(Get-NeoIPCReportingGroupLeaf -Groups $Classification['Groups'])
        $placements = foreach ($leaf in $leaves) {
            Get-NeoIPCReportingGroupPlacement -Entry $leaf.Group['Members'] -Location $leaf.Location -Value $leaf.Key -Noun 'member'
        }
        $result = Resolve-NeoIPCReportingGroupPlacement -Placement @($placements) -Index $index -Noun 'member'
        $result.Findings
        $ungrouped = [System.Collections.Generic.HashSet[string]]::new([string[]]@($script:NeoIPCUngroupedInfectiousAgentIds | ForEach-Object { "Id $_" }), [System.StringComparer]::Ordinal)
        foreach ($entry in $result.Resolved.GetEnumerator()) {
            if ($ungrouped.Contains($entry.Key)) {
                if ($null -ne $entry.Value) {
                    New-NeoIPCCheckFinding -Rule 'member-ungrouped' -Location $entry.Key -Message "The node belongs to no group, since it does not say what the infectious agent was, but takes the group '$($entry.Value)'."
                }
            }
            elseif ($null -eq $entry.Value) {
                New-NeoIPCCheckFinding -Rule 'member-missing' -Location $entry.Key -Message 'No member reaches the node or a node above it, so it takes no group.'
            }
        }

        foreach ($leaf in $leaves) {
            if (-not $leaf.Category) { continue }
            if (@($leaves | Where-Object { $_.Category -ceq $leaf.Category }).Count -lt 2) { continue }
            foreach ($member in @($leaf.Group['Members'])) {
                if ($member -isnot [System.Collections.IDictionary] -or (Test-NeoIPCReportingGroupText $member['Reason'])) { continue }
                New-NeoIPCCheckFinding -Rule 'member-split-reason-missing' -Location "$($leaf.Location), member '$($member['Name'])'" -Message "The group shares the EcdcCategory '$($leaf.Category)' with another group, so the member says in its Reason what sets it in this one."
            }
        }

        # The concept keys on a concept's path to the root, itself included, by concept key.
        $lineage = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.HashSet[string]]]::new([System.StringComparer]::Ordinal)
        $lineageOf = {
            param([string]$Key)
            if (-not $lineage.ContainsKey($Key)) {
                $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
                $current = $Key
                while ($current -and $index.Concepts.ContainsKey($current)) { [void]$set.Add($current); $current = $index.Concepts[$current][0].ParentKey }
                $lineage[$Key] = $set
            }
            $lineage[$Key]
        }
        $locationOfConcept = @{}
        foreach ($node in $index.IdBearing) { $locationOfConcept[$node.Location] = $node.ConceptKey }
        $checkName = {
            param($Group)
            if ($Group -isnot [System.Collections.IDictionary]) { return }
            $leafKeys = [System.Collections.Generic.HashSet[string]]::new([string[]]@(Get-NeoIPCReportingGroupLeaf -Groups @(, $Group) | ForEach-Object { $_.Key }), [System.StringComparer]::Ordinal)
            $name = [string]$Group['Name']
            if ($name -and $index.NodeNames.ContainsKey($name)) {
                foreach ($nodeKey in $index.NodeNames[$name]) {
                    $outside = @(foreach ($entry in $result.Resolved.GetEnumerator()) {
                            if ($null -eq $entry.Value -or $leafKeys.Contains([string]$entry.Value)) { continue }
                            if ((& $lineageOf $locationOfConcept[$entry.Key]).Contains($nodeKey)) { $entry }
                        })
                    if ($outside.Count) {
                        New-NeoIPCCheckFinding -Rule 'group-name-taxon' -Location "group '$($Group['Key'])'" -Message "The group's Name '$name' is that of the ontology's node $($nodeKey -replace '\|', ' '), with which it shares one entry of the translation catalogue, yet $($outside.Count) Id-bearing nodes beneath that node take a group outside this one: $($outside[0].Key), for one, takes the group '$($outside[0].Value)'."
                    }
                }
            }
            if ($Group.Contains('Children')) { foreach ($child in @($Group['Children'])) { & $checkName $child } }
        }
        foreach ($group in @($Classification['Groups'])) { & $checkName $group }
    }
    catch {
        New-NeoIPCCheckFinding -Rule 'member' -Location '' -Message "The members cannot be checked: $($_.Exception.Message)"
    }
}

function Get-NeoIPCReportingGroupAttributeFinding {
    # Checks each attribute's assignments against a parsed ontology tree: each names one bacterial concept by its
    # ConceptSource, ConceptId, and Name, none twice, none repeating the value it would take from an assignment above
    # it, an override saying why in its Reason, and each the value of some Id-bearing node; and every Id-bearing
    # bacterial node, concept or synonym, takes one value of every attribute, from its nearest assignment. A node no
    # assignment reaches is reported, never given a default.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowNull()]$Classification, [Parameter(Mandatory)][AllowNull()]$Tree)

    if ($Classification -isnot [System.Collections.IDictionary] -or $Tree -isnot [System.Collections.IDictionary]) {
        New-NeoIPCCheckFinding -Rule 'structure' -Location '' -Message 'The classification or the ontology is not a mapping.'
        return
    }
    try {
        $index = Get-NeoIPCInfectiousAgentIndex -Tree $Tree
        foreach ($attribute in @($Classification['Attributes'])) {
            if ($attribute -isnot [System.Collections.IDictionary]) { continue }
            $location = "attribute '$($attribute['Key'])'"
            $placements = Get-NeoIPCReportingGroupPlacement -Entry $attribute['Assignments'] -Location $location -Noun 'assignment'
            $result = Resolve-NeoIPCReportingGroupPlacement -Placement @($placements) -Index $index -Noun 'assignment' -BacteriaOnly
            $result.Findings
            foreach ($entry in $result.Resolved.GetEnumerator()) {
                if ($null -eq $entry.Value) {
                    New-NeoIPCCheckFinding -Rule 'assignment-missing' -Location $entry.Key -Message "No assignment of $location reaches the bacterial node or a node above it, so it takes none of its values."
                }
            }
        }
    }
    catch {
        New-NeoIPCCheckFinding -Rule 'assignment' -Location '' -Message "The attributes cannot be checked: $($_.Exception.Message)"
    }
}

function Get-NeoIPCReportingGroupTranslationFinding {
    # Compares a localized classification, as po4a writes it from the translation catalogue, with the canonical one.
    # Only the labels the catalogue offers may differ: a group's Name and Definition, and an attribute's and a value's
    # Name. Everything else stays as it is, in its type as in its text, the members' and assignments' names, which name
    # nodes of the ontology, and the assignments' values, which are keys, among it. Location names the localized file
    # in the messages.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowNull()]$Classification,
        [Parameter(Mandatory)][AllowNull()]$Translation,
        [Parameter(Mandatory)][string]$Location
    )

    $labels = @{ Group = @('Name', 'Definition'); Attribute = @('Name'); Value = @('Name') }
    $placeOf = @{
        Root      = @{ Groups = 'Group'; Attributes = 'Attribute' }
        Group     = @{ Children = 'Group'; Members = 'Member' }
        Attribute = @{ Values = 'Value'; Assignments = 'Assignment' }
    }
    $compare = {
        param($Canonical, $Localized, [string]$Place, [string]$Path)
        $where = if ($Path) { $Path } else { 'the top level' }
        if ($Canonical -is [System.Collections.IDictionary]) {
            if ($Localized -isnot [System.Collections.IDictionary]) {
                New-NeoIPCCheckFinding -Rule 'translation-difference' -Location $Location -Message "At $where the translation holds no mapping."
                return
            }
            $canonicalKeys = @($Canonical.Keys | ForEach-Object { [string]$_ })
            $localizedKeys = @($Localized.Keys | ForEach-Object { [string]$_ })
            foreach ($key in $canonicalKeys) {
                if ($key -cnotin $localizedKeys) {
                    New-NeoIPCCheckFinding -Rule 'translation-difference' -Location $Location -Message "At $where the translation lacks the key '$key'."
                    continue
                }
                if ($labels.ContainsKey($Place) -and $key -cin $labels[$Place]) { continue }
                $next = if ($placeOf.ContainsKey($Place) -and $placeOf[$Place].ContainsKey($key)) { $placeOf[$Place][$key] } else { 'Other' }
                & $compare $Canonical[$key] $Localized[$key] $next "$Path/$key"
            }
            foreach ($key in $localizedKeys) {
                if ($key -cnotin $canonicalKeys) {
                    New-NeoIPCCheckFinding -Rule 'translation-difference' -Location $Location -Message "At $where the translation has the key '$key', which the classification lacks."
                }
            }
        }
        elseif ($Canonical -is [System.Collections.IList]) {
            if ($Localized -isnot [System.Collections.IList] -or $Localized.Count -ne $Canonical.Count) {
                New-NeoIPCCheckFinding -Rule 'translation-difference' -Location $Location -Message "At $where the translation holds no list of $($Canonical.Count) items."
                return
            }
            for ($i = 0; $i -lt $Canonical.Count; $i++) { & $compare $Canonical[$i] $Localized[$i] $Place "$Path[$i]" }
        }
        elseif (($null -eq $Canonical) -ne ($null -eq $Localized) -or ($null -ne $Canonical -and $Canonical.GetType() -ne $Localized.GetType())) {
            # po4a writes an untranslated value that looks like a number unquoted, so a value can keep its text and
            # change its type; a list or a mapping in place of a value is of another type too.
            New-NeoIPCCheckFinding -Rule 'translation-difference' -Location $Location -Message "At $where the translation holds a value of another type than the classification's '$Canonical'."
        }
        elseif ([string]$Canonical -cne [string]$Localized) {
            New-NeoIPCCheckFinding -Rule 'translation-difference' -Location $Location -Message "At $where the translation reads '$Localized' where the classification reads '$Canonical'."
        }
    }
    try {
        & $compare $Classification $Translation 'Root' ''
    }
    catch {
        New-NeoIPCCheckFinding -Rule 'translation' -Location $Location -Message "The translation cannot be compared: $($_.Exception.Message)"
    }
}

function ConvertFrom-NeoIPCPo4aConfiguration {
    # The logical lines of a po4a configuration, read as po4a reads one (the loop over CONFIG in tools/po4a/po4a): a
    # comment from # to the end of its physical line removed, tabs and runs of spaces made one space, the line trimmed,
    # and a line that then ends in a backslash continued on the next. A final line break ends the last line, as Perl
    # reads lines, and a line still continued at the end of the text is dropped, since po4a leaves its loop without it.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $physicalLines = @($Text -split '\r?\n')
    if ($physicalLines.Count -gt 1 -and $physicalLines[-1] -eq '') { $physicalLines = $physicalLines[0..($physicalLines.Count - 2)] }
    $line = ''
    foreach ($physical in $physicalLines) {
        $line = ((($line + ($physical -replace '#.*', '')) -replace '\t', ' ') -replace ' +', ' ').Trim()
        if ($line.EndsWith('\')) {
            $line = $line.Substring(0, $line.Length - 1)
            continue
        }
        if ($line) { $line }
        $line = ''
    }
}

function Split-NeoIPCPo4aConfigurationArgument {
    # The arguments of a logical line of a po4a configuration, split as po4a's split_line splits one: at spaces outside
    # quotes, a quoted part taken without its quotes, a quote of the other kind inside it kept, and a backslash taking
    # the character after it as it is.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Line)

    $argument = [System.Text.StringBuilder]::new()
    $quote = $null
    $quoted = $false
    for ($i = 0; $i -lt $Line.Length; $i++) {
        $character = $Line[$i]
        if ($character -eq '\' -and $i + 1 -lt $Line.Length) {
            $i++
            [void]$argument.Append($Line[$i])
        }
        elseif ($character -eq "'" -or $character -eq '"') {
            $quoted = $true
            if ($null -eq $quote) { $quote = $character }
            elseif ($quote -eq $character) { $quote = $null }
            else { [void]$argument.Append($character) }
        }
        elseif ($character -eq ' ' -and $null -eq $quote) {
            if ($argument.Length -gt 0 -or $quoted) { $argument.ToString() }
            [void]$argument.Clear()
            $quoted = $false
        }
        else { [void]$argument.Append($character) }
    }
    if ($argument.Length -gt 0 -or $quoted) { $argument.ToString() }
}

function Split-NeoIPCPo4aOption {
    # The options of a po4a option string, split as po4a's split_opts splits one: at spaces, the quoted parts of an
    # option joined to it without their quotes.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $rest = ($Text -replace '\\"', '"').TrimStart(' ')
    while ($rest.Length -gt 0) {
        $option = [System.Text.StringBuilder]::new()
        while ($rest.Length -gt 0 -and $rest[0] -ne ' ') {
            $plain = [regex]::Match($rest, '\A[^\\"'' ]*')
            [void]$option.Append($plain.Value)
            $rest = $rest.Substring($plain.Length)
            $quotedPart = [regex]::Match($rest, '\A(["''])((?:\\.|(?!\1)[^\\])*)\1')
            if ($quotedPart.Success) {
                [void]$option.Append($quotedPart.Groups[2].Value)
                $rest = $rest.Substring($quotedPart.Length)
            }
            elseif ($rest.Length -gt 0 -and $rest[0] -ne ' ') {
                throw "po4a cannot split the options '$Text'."
            }
        }
        $option.ToString()
        $rest = $rest.TrimStart(' ')
    }
}

function Get-NeoIPCPo4aModuleOption {
    # The options po4a hands its format module, from a list of options as po4a's get_options reads them, with Getopt's
    # bundling and without abbreviations: the value of each -o, also written -o<value>, and of each --option, also
    # written --option=<value>, as name=value, or a bare name, which stands for 1. A later value of a name replaces an
    # earlier one.
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.Dictionary[string, string]])]
    param([AllowEmptyCollection()][string[]]$Option)

    $moduleOptions = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    $items = @($Option)
    for ($i = 0; $i -lt $items.Count; $i++) {
        $value = $null
        if ($items[$i] -ceq '-o' -or $items[$i] -ceq '--option') {
            if ($i + 1 -lt $items.Count) {
                $i++
                $value = $items[$i]
            }
        }
        elseif ($items[$i].StartsWith('--option=', [System.StringComparison]::Ordinal)) { $value = $items[$i].Substring(9) }
        elseif ($items[$i] -cmatch '\A-o(.+)\z') { $value = $Matches[1] }
        if ($null -eq $value) { continue }
        if ($value -cmatch '\A([^=]*)=(.*)\z') { $moduleOptions[$Matches[1]] = $Matches[2] }
        else { $moduleOptions[$value] = '1' }
    }
    Write-Output -NoEnumerate -InputObject $moduleOptions
}

function Get-NeoIPCPo4aYamlDocument {
    # The YAML documents of a po4a configuration's logical lines (ConvertFrom-NeoIPCPo4aConfiguration), each as
    # @{ Master; HasKeys; Variants }: the master file as its line names it; whether any options po4a hands the YAML
    # module for it name keys; and the module options of each way po4a reads it, as @{ Language; Paths; SkipArray }:
    # one for the template, with Language empty, and one for each language for which the line gives options of its own
    # (opt_<lang>:). As in po4a, a document's options follow the configuration's [options] lines, which give the
    # defaults, its line's options for every language (opt:) follow those, and its options for one language come last.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowEmptyCollection()][string[]]$Line)

    $defaults = [System.Collections.Generic.List[string]]::new()
    foreach ($logical in @($Line)) {
        if ($logical -cnotmatch '\A\[\s*options\s*\]\s*(.*)\z') { continue }
        foreach ($argument in @(Split-NeoIPCPo4aConfigurationArgument -Line $Matches[1])) {
            if ($argument -cmatch '\Aopt:(.*)\z') { $defaults.AddRange([string[]]@(Split-NeoIPCPo4aOption -Text $Matches[1])) }
            elseif ($argument -cnotmatch '\Aopt_') { $defaults.Add($argument) }
        }
    }
    foreach ($logical in @($Line)) {
        if ($logical -cnotmatch '\A\[type:\s*yaml\]\s+(\S+)(.*)\z') { continue }
        $master = $Matches[1]
        $rest = $Matches[2]
        $documentOptions = [System.Collections.Generic.List[string]]::new()
        $languageOptions = [ordered]@{}
        foreach ($argument in @(Split-NeoIPCPo4aConfigurationArgument -Line $rest)) {
            if ($argument -cnotmatch '\Aopt(?:_(.+?))?:(.*)\z') { continue }
            $language = $Matches[1]
            $options = [string[]]@(Split-NeoIPCPo4aOption -Text $Matches[2])
            if (-not $language) { $documentOptions.AddRange($options); continue }
            if (-not $languageOptions.Contains($language)) { $languageOptions[$language] = [System.Collections.Generic.List[string]]::new() }
            $languageOptions[$language].AddRange($options)
        }
        $hasKeys = $false
        $variants = foreach ($language in @('') + @($languageOptions.Keys)) {
            $all = [System.Collections.Generic.List[string]]::new($defaults)
            $all.AddRange($documentOptions)
            if ($language) { $all.AddRange($languageOptions[$language]) }
            $moduleOptions = Get-NeoIPCPo4aModuleOption -Option $all.ToArray()
            # Yaml.pm splits keys at commas and spaces, paths at commas, and takes skip_array as Perl takes a truth.
            if ($moduleOptions.ContainsKey('keys') -and @($moduleOptions['keys'] -split '[, ]' | Where-Object { $_ }).Count -gt 0) { $hasKeys = $true }
            [string[]]$paths = @()
            if ($moduleOptions.ContainsKey('paths')) { $paths = @($moduleOptions['paths'] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
            [pscustomobject]@{
                Language  = [string]$language
                Paths     = $paths
                SkipArray = $moduleOptions.ContainsKey('skip_array') -and $moduleOptions['skip_array'] -cnotin '', '0'
            }
        }
        [pscustomobject]@{ Master = $master; HasKeys = $hasKeys; Variants = @($variants) }
    }
}

function Get-NeoIPCPo4aConfigurationFinding {
    # Checks the po4a configuration of the infectious-agent catalogue against the two YAML documents it reads, the
    # classification and the list, each named by its master path as the configuration names it. Each document's line
    # names the values it offers the catalogue by path, never by key: po4a's YAML module keeps the keys and paths of
    # every document it reads in a run (Yaml.pm's file-level %yfm_keys and %yfm_paths, which initialize adds to and
    # never clears), and it renders every document for one language before it turns to the next, so a key option on one
    # document translates the values of that key in every document it reads after it, in every language after the
    # first. The paths reach exactly the values the catalogue carries: the names and definitions of the
    # classification's groups and the names of its attributes and values, never its members' or assignments' names,
    # which are names of ontology nodes, or its assignments' values, which are keys; and every Name, ConceptType, and
    # Value of the list, its nodes' names and ranks and its list terms. The classification's line also skips arrays,
    # which po4a extracts whatever the paths say, so that its lists of evidence stay out. A document's options are read
    # as po4a reads them (Get-NeoIPCPo4aYamlDocument): those of the configuration's [options] lines and of every opt:
    # and opt_<lang>: argument of its line, the last value of an option counting, and a language with options of its
    # own is checked as the template is.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Configuration,
        [Parameter(Mandatory)][AllowNull()]$Classification,
        [Parameter(Mandatory)][AllowNull()]$Tree,
        [Parameter(Mandatory)][string]$ClassificationMaster,
        [Parameter(Mandatory)][string]$TreeMaster
    )

    try {
        $documents = @(Get-NeoIPCPo4aYamlDocument -Line @(ConvertFrom-NeoIPCPo4aConfiguration -Text $Configuration))
        foreach ($document in $documents) {
            if ($document.HasKeys) {
                New-NeoIPCCheckFinding -Rule 'po4a-keys' -Location $document.Master -Message "The options po4a gives the document name keys, which po4a would apply to every YAML document it reads after this one, in every language after the first, rather than paths."
            }
        }

        $classificationPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        $collectGroups = {
            param($Groups, [string]$Path)
            foreach ($group in @($Groups)) {
                if ($group -isnot [System.Collections.IDictionary]) { continue }
                foreach ($key in 'Name', 'Definition') { if ($group.Contains($key)) { [void]$classificationPaths.Add("$Path $key") } }
                if ($group.Contains('Children')) { & $collectGroups $group['Children'] "$Path Children" }
            }
        }
        if ($Classification -is [System.Collections.IDictionary]) {
            & $collectGroups $Classification['Groups'] 'Groups'
            foreach ($attribute in @($Classification['Attributes'])) {
                if ($attribute -isnot [System.Collections.IDictionary]) { continue }
                if ($attribute.Contains('Name')) { [void]$classificationPaths.Add('Attributes Name') }
                foreach ($value in @($attribute['Values'])) {
                    if ($value -is [System.Collections.IDictionary] -and $value.Contains('Name')) { [void]$classificationPaths.Add('Attributes Values Name') }
                }
            }
        }

        $treePaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        $collectTree = {
            param($Node, [string]$Path)
            if ($Node -is [System.Collections.IDictionary]) {
                foreach ($key in @($Node.Keys)) {
                    $value = $Node[$key]
                    $next = if ($Path) { "$Path $key" } else { [string]$key }
                    if ([string]$key -cin 'Name', 'ConceptType', 'Value' -and $value -isnot [System.Collections.IDictionary] -and $value -isnot [System.Collections.IList]) {
                        [void]$treePaths.Add($next)
                    }
                    else { & $collectTree $value $next }
                }
            }
            elseif ($Node -is [System.Collections.IList]) { foreach ($item in $Node) { & $collectTree $item $Path } }
        }
        & $collectTree $Tree ''

        foreach ($expected in @(
                @{ Master = $ClassificationMaster; Paths = $classificationPaths; What = 'the classification' }
                @{ Master = $TreeMaster; Paths = $treePaths; What = 'the list' }
            )) {
            $lines = @($documents | Where-Object { $_.Master -ceq $expected.Master })
            if ($lines.Count -ne 1) {
                New-NeoIPCCheckFinding -Rule 'po4a-document' -Location $expected.Master -Message "The configuration has $($lines.Count) lines for $($expected.What), not one."
                continue
            }
            foreach ($variant in $lines[0].Variants) {
                $where = if ($variant.Language) { "$($expected.Master) ($($variant.Language))" } else { $expected.Master }
                $given = [System.Collections.Generic.HashSet[string]]::new([string[]]@($variant.Paths), [System.StringComparer]::Ordinal)
                foreach ($path in $expected.Paths) {
                    if (-not $given.Contains($path)) {
                        New-NeoIPCCheckFinding -Rule 'po4a-path-missing' -Location $where -Message "No path of the line reaches the values at '$path', which the catalogue is to carry."
                    }
                }
                foreach ($path in $given) {
                    if (-not $expected.Paths.Contains($path)) {
                        New-NeoIPCCheckFinding -Rule 'po4a-path-extra' -Location $where -Message "The path '$path' reaches no value the catalogue is to carry from $($expected.What)."
                    }
                }
                if ($expected.Master -ceq $ClassificationMaster -and -not $variant.SkipArray) {
                    New-NeoIPCCheckFinding -Rule 'po4a-skip-array' -Location $where -Message 'The line does not skip arrays, so po4a would offer the catalogue the lists of evidence.'
                }
            }
        }
    }
    catch {
        New-NeoIPCCheckFinding -Rule 'po4a' -Location '' -Message "The po4a configuration cannot be checked: $($_.Exception.Message)"
    }
}
