#Requires -Version 7.6

<#
.SYNOPSIS
    Tests of the reporting classification's checks (Private/InfectiousAgentReportingGroupValidation.ps1) on fixtures.

.DESCRIPTION
    Each rule is shown firing on a fixture that carries its defect, and that defect alone, beside a clean fixture that
    yields no finding, so a check that stops firing fails here. MetadataContent.Tests.ps1 applies the same checks to
    the committed classification and list.

    Internals are reached through InModuleScope; the Import-Module at file top runs during Pester's discovery phase,
    which InModuleScope requires.

.EXAMPLE
    Invoke-Pester -Path scripts/modules/NeoIPC-Tools/Tests/InfectiousAgentReportingGroupValidation.Tests.ps1
#>

Import-Module (Join-Path $PSScriptRoot '..') -Force

InModuleScope 'NeoIPC-Tools' {

    BeforeAll {
        Import-Module powershell-yaml -ErrorAction Stop

        # A small list in the committed file's shape: the two ungrouped options, Viruses with one genus, two bacterial
        # genera in one phylum, the first with a species and its synonym, and a fungal genus.
        $script:OntologyYaml = @'
Metadata:
  UrlTemplates:
    ICTV: https://ictv.global/taxonomy/taxondetails?taxnode_id={0}
    LPSN: https://lpsn.dsmz.de/{0}
    MycoBank: https://www.mycobank.org/page/Name%20details%20page/field/Mycobank%20%23/{0}
    NeoIPC: https://neoipc.org/infectious-agents/{0}
Hierarchies:
- Id: 0
  Name: Not listed
  ConceptType: Unknown
  ConceptSource: NeoIPC
  ConceptId: 1
- Id: 3561
  Name: Unidentifiable
  ConceptType: Unknown
  ConceptSource: NeoIPC
  ConceptId: 101
- Name: Viruses
  ConceptSource: NeoIPC
  ConceptId: 100
  Children:
  - Id: 20
    Name: Orthoflavivirus
    ConceptType: Genus
    ConceptSource: ICTV
    ConceptId: 202401234
    IctvId: 19990001
- Name: Bacteria
  ConceptType: Domain
  ConceptSource: LPSN
  ConceptId: domain/bacteria
  LpsnRecordNumber: 1
  Children:
  - Name: Bacillota
    ConceptType: Phylum
    ConceptSource: LPSN
    ConceptId: phylum/bacillota
    LpsnRecordNumber: 2
    Children:
    - Id: 10
      Name: Staphylococcus
      ConceptType: Genus
      ConceptSource: LPSN
      ConceptId: genus/staphylococcus
      LpsnRecordNumber: 3
      Children:
      - Id: 12
        Name: Staphylococcus aureus
        ConceptType: Species
        ConceptSource: LPSN
        ConceptId: species/staphylococcus-aureus
        LpsnRecordNumber: 4
        Synonyms:
        - Id: 13
          Name: Micrococcus aureus
          ConceptSource: LPSN
          ConceptId: species/micrococcus-aureus
          LpsnRecordNumber: 5
    - Id: 30
      Name: Clostridium
      ConceptType: Genus
      ConceptSource: LPSN
      ConceptId: genus/clostridium
      LpsnRecordNumber: 6
- Name: Eukaryota
  ConceptType: Domain
  ConceptSource: NeoIPC
  ConceptId: 99
  Children:
  - Name: Fungi
    ConceptType: Kingdom
    ConceptSource: MycoBank
    ConceptId: 455206
    MycoBankNr: 90157
    Children:
    - Id: 40
      Name: Candida
      ConceptType: Genus
      ConceptSource: MycoBank
      ConceptId: 56219
      MycoBankNr: 772
'@

        # A classification of that list that every check passes.
        $script:ClassificationYaml = @'
Groups:
- Key: bacteria
  Name: Bacteria
  Evidence:
  - doi:10.2900/7455254
  Children:
  - Key: gram-positive-cocci
    Name: Gram-positive cocci
    EcdcCategory: Gram-positive cocci
    Definition: Gram-positive cocci.
    Evidence:
    - doi:10.2900/7455254
    Members:
    - Name: Staphylococcus
      ConceptSource: LPSN
      ConceptId: genus/staphylococcus
      Evidence:
      - doi:10.2900/7455254
  - Key: anaerobes
    Name: Anaerobes
    EcdcCategory: Anaerobes
    Evidence:
    - doi:10.2900/7455254
    Members:
    - Name: Clostridium
      ConceptSource: LPSN
      ConceptId: genus/clostridium
      Evidence:
      - doi:10.2900/7455254
- Key: fungi
  Name: Fungi
  EcdcCategory: Fungi
  Evidence:
  - doi:10.2900/7455254
  Members:
  - Name: Fungi
    ConceptSource: MycoBank
    ConceptId: 455206
    Evidence:
    - doi:10.2900/7455254
- Key: viruses
  Name: Viruses
  EcdcCategory: Viruses
  Evidence:
  - doi:10.2900/7455254
  Members:
  - Name: Viruses
    ConceptSource: NeoIPC
    ConceptId: 100
    Evidence:
    - doi:10.2900/7455254
Attributes:
- Key: gram-reaction
  Name: Gram reaction
  Values:
  - Key: positive
    Name: Gram-positive
  - Key: negative
    Name: Gram-negative
  Assignments:
  - Name: Bacillota
    ConceptSource: LPSN
    ConceptId: phylum/bacillota
    Value: positive
    Evidence:
    - PMID:12345
- Key: oxygen-requirement
  Name: Oxygen requirement
  Values:
  - Key: facultative-anaerobic
    Name: Facultatively anaerobic
  - Key: obligate-anaerobic
    Name: Obligately anaerobic
  Assignments:
  - Name: Staphylococcus
    ConceptSource: LPSN
    ConceptId: genus/staphylococcus
    Value: facultative-anaerobic
    Evidence:
    - doi:10.1002/9781118960608.gbm00569
  - Name: Clostridium
    ConceptSource: LPSN
    ConceptId: genus/clostridium
    Value: obligate-anaerobic
    Evidence:
    - doi:10.1002/9781118960608.gbm00619
'@

        function Get-Rule {
            # The rules of a set of findings, for asserting which rule fired.
            param([AllowEmptyCollection()][object[]]$Finding)
            @($Finding | ForEach-Object { $_.Rule })
        }

        function Edit-Classification {
            # The clean classification with one change applied by the script block, which receives it.
            param([scriptblock]$Change = {})
            $classification = $script:ClassificationYaml | ConvertFrom-Yaml
            & $Change $classification
            $classification
        }

        function Edit-Ontology {
            # The clean list with one change applied by the script block, which receives it.
            param([scriptblock]$Change = {})
            $tree = $script:OntologyYaml | ConvertFrom-Yaml
            & $Change $tree
            $tree
        }

        function Get-Group {
            # The group of a classification with the given Key, at any depth.
            param([Parameter(Mandatory)]$Classification, [Parameter(Mandatory)][string]$Key)
            $pending = [System.Collections.Generic.Stack[object]]::new()
            foreach ($group in $Classification['Groups']) { $pending.Push($group) }
            while ($pending.Count -gt 0) {
                $group = $pending.Pop()
                if ($group['Key'] -ceq $Key) { return $group }
                if ($group.Contains('Children')) { foreach ($child in $group['Children']) { $pending.Push($child) } }
            }
        }

        function Get-Attribute {
            # The attribute of a classification with the given Key.
            param([Parameter(Mandatory)]$Classification, [Parameter(Mandatory)][string]$Key)
            $Classification['Attributes'] | Where-Object { $_['Key'] -ceq $Key } | Select-Object -First 1
        }

        function New-Entry {
            # A member, or with a Value an assignment, naming a node, with evidence and, where given, a reason.
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'It builds an object in memory and changes no state.')]
            param([string]$Name, [string]$Source, $ConceptId, [string]$Value, [string]$Reason)
            $entry = @{ Name = $Name; ConceptSource = $Source; ConceptId = $ConceptId; Evidence = [System.Collections.Generic.List[object]]@('doi:10.2900/7455254') }
            if ($Value) { $entry['Value'] = $Value }
            if ($Reason) { $entry['Reason'] = $Reason }
            $entry
        }

        function Get-AllFinding {
            # The findings of all three checks of a classification against a list.
            param($Classification, $Tree)
            @(Get-NeoIPCReportingGroupStructureFinding -Classification $Classification) +
            @(Get-NeoIPCReportingGroupMemberFinding -Classification $Classification -Tree $Tree) +
            @(Get-NeoIPCReportingGroupAttributeFinding -Classification $Classification -Tree $Tree)
        }
    }

    Describe 'Get-NeoIPCReportingGroupStructureFinding' {
        It 'reports nothing for a clean classification' {
            @(Get-AllFinding -Classification (Edit-Classification) -Tree (Edit-Ontology)) | Should -BeNullOrEmpty
        }

        It 'reports a key outside the vocabulary of its place' {
            $c = Edit-Classification { param($c) (Get-Group $c 'anaerobes')['Colour'] = 'red' }
            Get-Rule (Get-NeoIPCReportingGroupStructureFinding -Classification $c) | Should -Be @('unknown-key')
        }

        It 'reports a key spelled in another letter case <Case>, which a lookup would pass unseen' -ForEach @(
            @{ Case = 'at the top level'; Change = { param($c) $attributes = $c['Attributes']; $c.Remove('Attributes'); $c['attributes'] = $attributes } }
            @{ Case = 'on a member'; Change = { param($c) $member = (Get-Group $c 'anaerobes')['Members'][0]; $member.Remove('Name'); $member['name'] = 'Clostridium' } }
            @{ Case = 'on an attribute'; Change = { param($c) $attribute = Get-Attribute $c 'gram-reaction'; $values = $attribute['Values']; $attribute.Remove('Values'); $attribute['values'] = $values } }
            @{ Case = 'on a value'; Change = { param($c) $value = (Get-Attribute $c 'gram-reaction')['Values'][0]; $name = $value['Name']; $value.Remove('Name'); $value['name'] = $name } }
            @{ Case = 'on an assignment'; Change = { param($c) $assignment = (Get-Attribute $c 'gram-reaction')['Assignments'][0]; $key = $assignment['Value']; $assignment.Remove('Value'); $assignment['value'] = $key } }
        ) {
            Get-Rule (Get-NeoIPCReportingGroupStructureFinding -Classification (Edit-Classification $Change)) | Should -Be @('unknown-key')
        }

        It 'reports a classification that is no mapping, or one without groups' {
            Get-Rule (Get-NeoIPCReportingGroupStructureFinding -Classification 'Groups') | Should -Be @('structure')
            $c = Edit-Classification { param($c) $c.Remove('Groups') }
            Get-Rule (Get-NeoIPCReportingGroupStructureFinding -Classification $c) | Should -Be @('structure')
        }

        It 'reports <Case> that is no mapping' -ForEach @(
            @{ Case = 'a group'; Change = { param($c) $c['Groups'].Add('viruses') } }
            @{ Case = 'a member'; Change = { param($c) (Get-Group $c 'viruses')['Members'].Add('Viruses') } }
            @{ Case = 'an attribute'; Change = { param($c) $c['Attributes'].Add('gram-reaction') } }
            @{ Case = 'a value'; Change = { param($c) (Get-Attribute $c 'gram-reaction')['Values'].Add('variable') } }
            @{ Case = 'an assignment'; Change = { param($c) (Get-Attribute $c 'gram-reaction')['Assignments'].Add('Bacillota') } }
        ) {
            Get-Rule (Get-NeoIPCReportingGroupStructureFinding -Classification (Edit-Classification $Change)) | Should -Be @('structure')
        }

        It 'reports a classification without a list of attributes, and an attribute without assignments' {
            $c = Edit-Classification { param($c) $c['Attributes'] = 'none' }
            Get-Rule (Get-NeoIPCReportingGroupStructureFinding -Classification $c) | Should -Be @('structure', 'attribute-missing', 'attribute-missing')
            $c = Edit-Classification { param($c) (Get-Attribute $c 'gram-reaction').Remove('Assignments') }
            Get-Rule (Get-NeoIPCReportingGroupStructureFinding -Classification $c) | Should -Be @('structure')
        }

        It 'reports a Key that is no hyphenated lower-case identifier' {
            $c = Edit-Classification { param($c) (Get-Group $c 'anaerobes')['Key'] = 'Anaerobes' }
            Get-Rule (Get-NeoIPCReportingGroupStructureFinding -Classification $c) | Should -Be @('group-key')
        }

        It 'reports two groups with one Key' {
            $c = Edit-Classification { param($c) (Get-Group $c 'anaerobes')['Key'] = 'fungi' }
            Get-Rule (Get-NeoIPCReportingGroupStructureFinding -Classification $c) | Should -Be @('group-key')
        }

        It 'reports two groups with one Name, and a group without one' {
            $c = Edit-Classification { param($c) (Get-Group $c 'anaerobes')['Name'] = 'Fungi' }
            Get-Rule (Get-NeoIPCReportingGroupStructureFinding -Classification $c) | Should -Be @('group-name')
            $c = Edit-Classification { param($c) (Get-Group $c 'anaerobes').Remove('Name') }
            Get-Rule (Get-NeoIPCReportingGroupStructureFinding -Classification $c) | Should -Be @('group-name')
        }

        It 'reports a Definition or a Reason that is no text' {
            $c = Edit-Classification { param($c) (Get-Group $c 'gram-positive-cocci')['Definition'] = ' ' }
            Get-Rule (Get-NeoIPCReportingGroupStructureFinding -Classification $c) | Should -Be @('text')
            $c = Edit-Classification { param($c) (Get-Group $c 'anaerobes')['Members'][0]['Reason'] = 5 }
            Get-Rule (Get-NeoIPCReportingGroupStructureFinding -Classification $c) | Should -Be @('text')
        }

        It 'reports a member without evidence' {
            $c = Edit-Classification { param($c) (Get-Group $c 'anaerobes')['Members'][0].Remove('Evidence') }
            Get-Rule (Get-NeoIPCReportingGroupStructureFinding -Classification $c) | Should -Be @('evidence-missing')
        }

        It 'reports a group without evidence, <Case>' -ForEach @(
            @{ Case = 'a group of members'; Key = 'anaerobes' }
            @{ Case = 'a group of groups'; Key = 'bacteria' }
        ) {
            $groupKey = $Key
            $c = Edit-Classification { param($c) (Get-Group $c $groupKey).Remove('Evidence') }
            Get-Rule (Get-NeoIPCReportingGroupStructureFinding -Classification $c) | Should -Be @('evidence-missing')
        }

        It 'reports evidence that is <Case>' -ForEach @(
            @{ Case = 'a DOI of another form'; Evidence = [System.Collections.Generic.List[object]]@('doi:11.1000/x') }
            @{ Case = 'a PMID of another form'; Evidence = [System.Collections.Generic.List[object]]@('PMID 12345') }
            @{ Case = 'a DOI in another letter case'; Evidence = [System.Collections.Generic.List[object]]@('DOI:10.2900/7455254') }
            @{ Case = 'a PMID in another letter case'; Evidence = [System.Collections.Generic.List[object]]@('pmid:12345') }
            @{ Case = 'listed twice'; Evidence = [System.Collections.Generic.List[object]]@('PMID:12345', 'PMID:12345') }
            @{ Case = 'no list'; Evidence = 'PMID:12345' }
            @{ Case = 'an empty list'; Evidence = [System.Collections.Generic.List[object]]::new() }
        ) {
            $value = $Evidence
            $c = Edit-Classification { param($c) (Get-Group $c 'anaerobes')['Members'][0]['Evidence'] = $value }
            Get-Rule (Get-NeoIPCReportingGroupStructureFinding -Classification $c) | Should -Be @('evidence')
        }

        It 'reports a group''s evidence of another form' {
            $c = Edit-Classification { param($c) (Get-Group $c 'anaerobes')['Evidence'] = [System.Collections.Generic.List[object]]@('doi:11.1000/x') }
            Get-Rule (Get-NeoIPCReportingGroupStructureFinding -Classification $c) | Should -Be @('evidence')
        }

        It 'reports an EcdcCategory that is not one of the nine in their spelling, such as ''<Category>''' -ForEach @(
            @{ Category = 'Gram positive cocci' }
            @{ Category = 'Gram-Positive cocci' }
        ) {
            $category = $Category
            $c = Edit-Classification { param($c) (Get-Group $c 'gram-positive-cocci')['EcdcCategory'] = $category }
            Get-Rule (Get-NeoIPCReportingGroupStructureFinding -Classification $c) | Should -Be @('ecdc-category')
        }

        It 'reports an EcdcCategory that differs from that of the group above' {
            $c = Edit-Classification { param($c) (Get-Group $c 'bacteria')['EcdcCategory'] = 'Gram-positive cocci' }
            Get-Rule (Get-NeoIPCReportingGroupStructureFinding -Classification $c) | Should -Be @('ecdc-category')
        }

        It 'reports a group of members without an EcdcCategory of its own or from above' {
            $c = Edit-Classification { param($c) (Get-Group $c 'anaerobes').Remove('EcdcCategory') }
            Get-Rule (Get-NeoIPCReportingGroupStructureFinding -Classification $c) | Should -Be @('ecdc-category')
        }

        It 'reports a group with both Children and Members, with neither, or with an empty list' {
            $c = Edit-Classification { param($c) (Get-Group $c 'bacteria')['Members'] = (Get-Group $c 'anaerobes')['Members'] }
            Get-Rule (Get-NeoIPCReportingGroupStructureFinding -Classification $c) | Should -Be @('group-shape')
            $c = Edit-Classification { param($c) (Get-Group $c 'viruses').Remove('Members') }
            Get-Rule (Get-NeoIPCReportingGroupStructureFinding -Classification $c) | Should -Be @('group-shape')
            $c = Edit-Classification { param($c) (Get-Group $c 'viruses')['Members'] = [System.Collections.Generic.List[object]]::new() }
            Get-Rule (Get-NeoIPCReportingGroupStructureFinding -Classification $c) | Should -Be @('group-shape')
            $c = Edit-Classification { param($c) (Get-Group $c 'bacteria')['Children'] = [System.Collections.Generic.List[object]]::new() }
            Get-Rule (Get-NeoIPCReportingGroupStructureFinding -Classification $c) | Should -Be @('group-shape')
        }

        It 'reports a member that does not name its node in full' {
            $c = Edit-Classification { param($c) (Get-Group $c 'anaerobes')['Members'][0].Remove('ConceptId') }
            Get-Rule (Get-NeoIPCReportingGroupStructureFinding -Classification $c) | Should -Be @('entry')
            $c = Edit-Classification { param($c) (Get-Group $c 'anaerobes')['Members'][0].Remove('ConceptSource') }
            Get-Rule (Get-NeoIPCReportingGroupStructureFinding -Classification $c) | Should -Be @('entry')
        }

        It 'reports an attribute Key that is no identifier, or one two attributes share' {
            $c = Edit-Classification { param($c) (Get-Attribute $c 'oxygen-requirement')['Key'] = 'Oxygen' }
            Get-Rule (Get-NeoIPCReportingGroupStructureFinding -Classification $c) | Should -Be @('attribute-key', 'attribute-missing')
            $c = Edit-Classification { param($c) (Get-Attribute $c 'oxygen-requirement')['Key'] = 'gram-reaction' }
            Get-Rule (Get-NeoIPCReportingGroupStructureFinding -Classification $c) | Should -Be @('attribute-key', 'attribute-missing')
        }

        It 'reports an attribute without a Name, or with another attribute''s' {
            $c = Edit-Classification { param($c) (Get-Attribute $c 'oxygen-requirement').Remove('Name') }
            Get-Rule (Get-NeoIPCReportingGroupStructureFinding -Classification $c) | Should -Be @('attribute-name')
            $c = Edit-Classification { param($c) (Get-Attribute $c 'oxygen-requirement')['Name'] = 'Gram reaction' }
            Get-Rule (Get-NeoIPCReportingGroupStructureFinding -Classification $c) | Should -Be @('attribute-name')
        }

        It 'reports a value the attribute''s vocabulary lacks, and a vocabulary with a Key twice' {
            $c = Edit-Classification { param($c) (Get-Attribute $c 'gram-reaction')['Assignments'][0]['Value'] = 'Positive' }
            Get-Rule (Get-NeoIPCReportingGroupStructureFinding -Classification $c) | Should -Be @('attribute-value')
            $c = Edit-Classification { param($c) (Get-Attribute $c 'gram-reaction')['Values'][1]['Key'] = 'positive' }
            Get-Rule (Get-NeoIPCReportingGroupStructureFinding -Classification $c) | Should -Be @('attribute-value')
        }

        It 'reports a vocabulary that is <Case>' -ForEach @(
            @{ Case = 'missing'; Change = { param($c) (Get-Attribute $c 'oxygen-requirement').Remove('Values') }; Expected = @('attribute-value', 'attribute-value', 'attribute-value') }
            @{ Case = 'given a Key that is no identifier'; Change = { param($c) (Get-Attribute $c 'gram-reaction')['Values'][1]['Key'] = 'Negative' }; Expected = @('attribute-value') }
            @{ Case = 'given a value without a Name'; Change = { param($c) (Get-Attribute $c 'gram-reaction')['Values'][1].Remove('Name') }; Expected = @('attribute-value') }
            @{ Case = 'given a Name twice'; Change = { param($c) (Get-Attribute $c 'gram-reaction')['Values'][1]['Name'] = 'Gram-positive' }; Expected = @('attribute-value') }
        ) {
            Get-Rule (Get-NeoIPCReportingGroupStructureFinding -Classification (Edit-Classification $Change)) | Should -Be $Expected
        }

        It 'reports a missing attribute, which every Id-bearing bacterial node takes a value of' {
            $c = Edit-Classification { param($c) $c['Attributes'].RemoveAt(1) }
            Get-Rule (Get-NeoIPCReportingGroupStructureFinding -Classification $c) | Should -Be @('attribute-missing')
        }
    }

    Describe 'Get-NeoIPCReportingGroupMemberFinding' {
        It 'reports nothing for a clean classification' {
            @(Get-NeoIPCReportingGroupMemberFinding -Classification (Edit-Classification) -Tree (Edit-Ontology)) | Should -BeNullOrEmpty
        }

        It 'reports a member that names no node' {
            $c = Edit-Classification { param($c) (Get-Group $c 'anaerobes')['Members'].Add((New-Entry 'Nothing' 'LPSN' 'genus/nothing')) }
            Get-Rule (Get-NeoIPCReportingGroupMemberFinding -Classification $c -Tree (Edit-Ontology)) | Should -Be @('member-unresolved')
        }

        It 'reports a member that names a synonym, which takes its concept''s group' {
            $c = Edit-Classification { param($c) (Get-Group $c 'anaerobes')['Members'].Add((New-Entry 'Micrococcus aureus' 'LPSN' 'species/micrococcus-aureus' -Reason 'r')) }
            $findings = @(Get-NeoIPCReportingGroupMemberFinding -Classification $c -Tree (Edit-Ontology))
            Get-Rule $findings | Should -Be @('member-unresolved')
            $findings[0].Message | Should -BeLike '*synonym*'
        }

        It 'reports a member whose ConceptSource and ConceptId name two nodes' {
            $tree = Edit-Ontology {
                param($t)
                $fungi = $t['Hierarchies'][4]['Children'][0]
                $fungi['Children'].Add(@{ Id = 41; Name = 'Clostridium'; ConceptType = 'Genus'; ConceptSource = 'LPSN'; ConceptId = 'genus/clostridium'; LpsnRecordNumber = 7 })
            }
            Get-Rule (Get-NeoIPCReportingGroupMemberFinding -Classification (Edit-Classification) -Tree $tree) | Should -Contain 'member-unresolved'
        }

        It 'reports a member whose Name is not that of its node, such as ''<Name>''' -ForEach @(
            @{ Name = 'Clostridia' }
            @{ Name = 'clostridium' }
        ) {
            $memberName = $Name
            $c = Edit-Classification { param($c) (Get-Group $c 'anaerobes')['Members'][0]['Name'] = $memberName }
            Get-Rule (Get-NeoIPCReportingGroupMemberFinding -Classification $c -Tree (Edit-Ontology)) | Should -Be @('member-name')
        }

        It 'reports a node listed in two groups' {
            $c = Edit-Classification { param($c) (Get-Group $c 'anaerobes')['Members'].Add((New-Entry 'Staphylococcus' 'LPSN' 'genus/staphylococcus')) }
            Get-Rule (Get-NeoIPCReportingGroupMemberFinding -Classification $c -Tree (Edit-Ontology)) | Should -Be @('member-duplicate')
        }

        It 'reports a member that repeats the group a member above it gives' {
            $c = Edit-Classification { param($c) (Get-Group $c 'gram-positive-cocci')['Members'].Add((New-Entry 'Staphylococcus aureus' 'LPSN' 'species/staphylococcus-aureus')) }
            Get-Rule (Get-NeoIPCReportingGroupMemberFinding -Classification $c -Tree (Edit-Ontology)) | Should -Be @('member-redundant')
        }

        It 'reports an override of a member above without a Reason, and accepts one with it' {
            $c = Edit-Classification { param($c) (Get-Group $c 'anaerobes')['Members'].Add((New-Entry 'Staphylococcus aureus' 'LPSN' 'species/staphylococcus-aureus')) }
            Get-Rule (Get-NeoIPCReportingGroupMemberFinding -Classification $c -Tree (Edit-Ontology)) | Should -Be @('member-reason-missing')
            $c = Edit-Classification { param($c) (Get-Group $c 'anaerobes')['Members'].Add((New-Entry 'Staphylococcus aureus' 'LPSN' 'species/staphylococcus-aureus' -Reason 'r')) }
            @(Get-NeoIPCReportingGroupMemberFinding -Classification $c -Tree (Edit-Ontology)) | Should -BeNullOrEmpty
        }

        It 'reports a member from which no Id-bearing node takes its group' {
            $c = Edit-Classification {
                param($c)
                foreach ($key in 'gram-positive-cocci', 'anaerobes') { (Get-Group $c $key)['Members'][0]['Reason'] = 'r' }
                (Get-Group $c 'fungi')['Members'].Add((New-Entry 'Bacillota' 'LPSN' 'phylum/bacillota'))
            }
            Get-Rule (Get-NeoIPCReportingGroupMemberFinding -Classification $c -Tree (Edit-Ontology)) | Should -Be @('member-unused')
        }

        It 'counts a member that repeats the group above as absent, so the member above is not unused' {
            $c = Edit-Classification {
                param($c)
                (Get-Group $c 'gram-positive-cocci')['Members'][0]['Reason'] = 'r'
                (Get-Group $c 'anaerobes')['Members'].Add((New-Entry 'Bacillota' 'LPSN' 'phylum/bacillota'))
            }
            Get-Rule (Get-NeoIPCReportingGroupMemberFinding -Classification $c -Tree (Edit-Ontology)) | Should -Be @('member-redundant')
        }

        It 'reports an Id-bearing node that no member reaches' {
            $c = Edit-Classification { param($c) (Get-Group $c 'anaerobes')['Members'][0]['ConceptId'] = 'genus/nothing' }
            $findings = @(Get-NeoIPCReportingGroupMemberFinding -Classification $c -Tree (Edit-Ontology))
            Get-Rule $findings | Should -Be @('member-unresolved', 'member-missing')
            $findings[1].Location | Should -Be 'Id 30'
        }

        It 'reports a group for the Id <Id>, which belongs to none' -ForEach @(
            @{ Id = 0; Name = 'Not listed'; ConceptId = 1 }
            @{ Id = 3561; Name = 'Unidentifiable'; ConceptId = 101 }
        ) {
            $entry = New-Entry $Name 'NeoIPC' $ConceptId
            $c = Edit-Classification { param($c) (Get-Group $c 'anaerobes')['Members'].Add($entry) }
            $findings = @(Get-NeoIPCReportingGroupMemberFinding -Classification $c -Tree (Edit-Ontology))
            Get-Rule $findings | Should -Be @('member-ungrouped')
            $findings[0].Location | Should -Be "Id $Id"
        }

        It 'reports a member of a group that shares its ECDC category with another, without a Reason, and accepts one with it' {
            # A second group in the anaerobes' category, which it takes from the group above it, holding Staphylococcus
            # aureus, which overrides its genus and says why; Clostridium, the anaerobes' member, says nothing.
            $split = {
                param($c)
                $members = [System.Collections.Generic.List[object]]@((New-Entry 'Staphylococcus aureus' 'LPSN' 'species/staphylococcus-aureus' -Reason 'r'))
                $leaf = @{ Key = 'other-anaerobes'; Name = 'Other anaerobes'; Members = $members }
                (Get-Group $c 'bacteria')['Children'].Add(@{ Key = 'more-anaerobes'; Name = 'More anaerobes'; EcdcCategory = 'Anaerobes'; Children = [System.Collections.Generic.List[object]]@($leaf) })
            }
            $findings = @(Get-NeoIPCReportingGroupMemberFinding -Classification (Edit-Classification $split) -Tree (Edit-Ontology))
            Get-Rule $findings | Should -Be @('member-split-reason-missing')
            $findings[0].Location | Should -Be "group 'anaerobes', member 'Clostridium'"
            $c = Edit-Classification { param($c) & $split $c; (Get-Group $c 'anaerobes')['Members'][0]['Reason'] = 'r' }
            @(Get-NeoIPCReportingGroupMemberFinding -Classification $c -Tree (Edit-Ontology)) | Should -BeNullOrEmpty
        }

        It 'reports a group named like a node <Case>, whose entry in the translation catalogue it shares' -ForEach @(
            @{ Case = 'beneath which a node takes another group'; Name = 'Bacillota' }
            @{ Case = 'by a synonym''s name, beneath whose concept a node takes another group'; Name = 'Micrococcus aureus' }
        ) {
            $groupName = $Name
            $c = Edit-Classification { param($c) (Get-Group $c 'anaerobes')['Name'] = $groupName }
            Get-Rule (Get-NeoIPCReportingGroupMemberFinding -Classification $c -Tree (Edit-Ontology)) | Should -Be @('group-name-taxon')
        }

        It 'reports a group of groups named like a node beneath which a node takes a group outside it' {
            # Candida (Id 40), beneath Eukaryota, takes the group 'fungi', which the group 'bacteria' does not hold.
            $c = Edit-Classification { param($c) (Get-Group $c 'bacteria')['Name'] = 'Eukaryota' }
            $findings = @(Get-NeoIPCReportingGroupMemberFinding -Classification $c -Tree (Edit-Ontology))
            Get-Rule $findings | Should -Be @('group-name-taxon')
            $findings[0].Location | Should -Be "group 'bacteria'"
        }

        It 'accepts a group named like the node whose every Id-bearing node it holds' {
            $c = Edit-Classification { param($c) (Get-Group $c 'gram-positive-cocci')['Name'] = 'Staphylococcus' }
            @(Get-NeoIPCReportingGroupMemberFinding -Classification $c -Tree (Edit-Ontology)) | Should -BeNullOrEmpty
        }
    }

    Describe 'Resolve-NeoIPCReportingGroupPlacement' {
        It 'reports a classification or a list that is no mapping' {
            Get-Rule (Get-NeoIPCReportingGroupMemberFinding -Classification 'Groups' -Tree (Edit-Ontology)) | Should -Be @('structure')
            Get-Rule (Get-NeoIPCReportingGroupAttributeFinding -Classification (Edit-Classification) -Tree 'Hierarchies') | Should -Be @('structure')
        }

        It 'places a concept beneath a synonym by the synonym''s concept' {
            $tree = Edit-Ontology {
                param($t)
                $synonym = $t['Hierarchies'][3]['Children'][0]['Children'][0]['Children'][0]['Synonyms'][0]
                $synonym['Children'] = [System.Collections.Generic.List[object]]@(
                    @{ Id = 14; Name = 'Staphylococcus aureus subsp. aureus'; ConceptType = 'Subspecies'; ConceptSource = 'LPSN'; ConceptId = 'subspecies/staphylococcus-aureus-aureus'; LpsnRecordNumber = 8 })
            }
            $index = Get-NeoIPCInfectiousAgentIndex -Tree $tree
            $placements = foreach ($leaf in @(Get-NeoIPCReportingGroupLeaf -Groups (Edit-Classification)['Groups'])) {
                Get-NeoIPCReportingGroupPlacement -Entry $leaf.Group['Members'] -Location $leaf.Location -Value $leaf.Key -Noun 'member'
            }
            $result = Resolve-NeoIPCReportingGroupPlacement -Placement @($placements) -Index $index -Noun 'member'
            $result.Resolved['Id 14'] | Should -Be 'gram-positive-cocci'
        }

        It 'gives a synonym the group of its concept' {
            $c = Edit-Classification { param($c) (Get-Group $c 'anaerobes')['Members'].Add((New-Entry 'Staphylococcus aureus' 'LPSN' 'species/staphylococcus-aureus' -Reason 'r')) }
            $index = Get-NeoIPCInfectiousAgentIndex -Tree (Edit-Ontology)
            $placements = foreach ($leaf in @(Get-NeoIPCReportingGroupLeaf -Groups $c['Groups'])) {
                Get-NeoIPCReportingGroupPlacement -Entry $leaf.Group['Members'] -Location $leaf.Location -Value $leaf.Key -Noun 'member'
            }
            $result = Resolve-NeoIPCReportingGroupPlacement -Placement @($placements) -Index $index -Noun 'member'
            $result.Resolved['Id 13'] | Should -Be 'anaerobes'
            $result.Resolved['Id 12'] | Should -Be 'anaerobes'
            $result.Resolved['Id 10'] | Should -Be 'gram-positive-cocci'
        }
    }

    Describe 'Get-NeoIPCReportingGroupAttributeFinding' {
        It 'reports nothing for a clean classification' {
            @(Get-NeoIPCReportingGroupAttributeFinding -Classification (Edit-Classification) -Tree (Edit-Ontology)) | Should -BeNullOrEmpty
        }

        It 'reports an assignment to a node outside the bacteria' {
            $c = Edit-Classification { param($c) (Get-Attribute $c 'gram-reaction')['Assignments'].Add((New-Entry 'Fungi' 'MycoBank' 455206 -Value 'positive')) }
            Get-Rule (Get-NeoIPCReportingGroupAttributeFinding -Classification $c -Tree (Edit-Ontology)) | Should -Be @('assignment-scope')
        }

        It 'reports an Id-bearing bacterial node that no assignment reaches' {
            $c = Edit-Classification { param($c) (Get-Attribute $c 'oxygen-requirement')['Assignments'].RemoveAt(1) }
            $findings = @(Get-NeoIPCReportingGroupAttributeFinding -Classification $c -Tree (Edit-Ontology))
            Get-Rule $findings | Should -Be @('assignment-missing')
            $findings[0].Location | Should -Be 'Id 30'
        }

        It 'reports an assignment that repeats the value an assignment above gives' {
            $c = Edit-Classification { param($c) (Get-Attribute $c 'oxygen-requirement')['Assignments'].Add((New-Entry 'Staphylococcus aureus' 'LPSN' 'species/staphylococcus-aureus' -Value 'facultative-anaerobic')) }
            Get-Rule (Get-NeoIPCReportingGroupAttributeFinding -Classification $c -Tree (Edit-Ontology)) | Should -Be @('assignment-redundant')
        }

        It 'reports an override of an assignment above without a Reason, and accepts one with it' {
            $c = Edit-Classification { param($c) (Get-Attribute $c 'oxygen-requirement')['Assignments'].Add((New-Entry 'Staphylococcus aureus' 'LPSN' 'species/staphylococcus-aureus' -Value 'obligate-anaerobic')) }
            Get-Rule (Get-NeoIPCReportingGroupAttributeFinding -Classification $c -Tree (Edit-Ontology)) | Should -Be @('assignment-reason-missing')
            $c = Edit-Classification { param($c) (Get-Attribute $c 'oxygen-requirement')['Assignments'].Add((New-Entry 'Staphylococcus aureus' 'LPSN' 'species/staphylococcus-aureus' -Value 'obligate-anaerobic' -Reason 'r')) }
            @(Get-NeoIPCReportingGroupAttributeFinding -Classification $c -Tree (Edit-Ontology)) | Should -BeNullOrEmpty
        }

        It 'reports an assignment from which no Id-bearing node takes its value' {
            $c = Edit-Classification {
                param($c)
                $attribute = Get-Attribute $c 'oxygen-requirement'
                $attribute['Values'].Add(@{ Key = 'aerobic'; Name = 'Aerobic' })
                foreach ($assignment in $attribute['Assignments']) { $assignment['Reason'] = 'r' }
                $attribute['Assignments'].Add((New-Entry 'Bacillota' 'LPSN' 'phylum/bacillota' -Value 'aerobic'))
            }
            Get-Rule (Get-NeoIPCReportingGroupAttributeFinding -Classification $c -Tree (Edit-Ontology)) | Should -Be @('assignment-unused')
        }

        It 'reports an assignment that names no node, and a node assigned twice' {
            $c = Edit-Classification { param($c) (Get-Attribute $c 'gram-reaction')['Assignments'].Add((New-Entry 'Nothing' 'LPSN' 'genus/nothing' -Value 'positive')) }
            Get-Rule (Get-NeoIPCReportingGroupAttributeFinding -Classification $c -Tree (Edit-Ontology)) | Should -Be @('assignment-unresolved')
            $c = Edit-Classification { param($c) (Get-Attribute $c 'gram-reaction')['Assignments'].Add((New-Entry 'Bacillota' 'LPSN' 'phylum/bacillota' -Value 'negative')) }
            Get-Rule (Get-NeoIPCReportingGroupAttributeFinding -Classification $c -Tree (Edit-Ontology)) | Should -Be @('assignment-duplicate')
        }
    }

    Describe 'Get-NeoIPCReportingGroupTranslationFinding' {
        It 'reports nothing for a translation that changes nothing, or only the labels the catalogue offers' {
            @(Get-NeoIPCReportingGroupTranslationFinding -Classification (Edit-Classification) -Translation (Edit-Classification) -Location 'de') | Should -BeNullOrEmpty
            $translation = Edit-Classification {
                param($c)
                (Get-Group $c 'gram-positive-cocci')['Name'] = 'Grampositive Kokken'
                (Get-Group $c 'gram-positive-cocci')['Definition'] = 'Grampositive Kokken.'
                (Get-Attribute $c 'gram-reaction')['Name'] = 'Gramfärbung'
                (Get-Attribute $c 'gram-reaction')['Values'][0]['Name'] = 'Grampositiv'
            }
            @(Get-NeoIPCReportingGroupTranslationFinding -Classification (Edit-Classification) -Translation $translation -Location 'de') | Should -BeNullOrEmpty
        }

        It 'reports a translation that changes <Case>' -ForEach @(
            @{ Case = 'a member''s Name'; Change = { param($c) (Get-Group $c 'viruses')['Members'][0]['Name'] = 'Viren' } }
            @{ Case = 'an assignment''s Name'; Change = { param($c) (Get-Attribute $c 'gram-reaction')['Assignments'][0]['Name'] = 'Bacillota (Stamm)' } }
            @{ Case = 'an assignment''s Value'; Change = { param($c) (Get-Attribute $c 'gram-reaction')['Assignments'][0]['Value'] = 'negative' } }
            @{ Case = 'a group''s Key'; Change = { param($c) (Get-Group $c 'anaerobes')['Key'] = 'anaerobier' } }
            @{ Case = 'an item of evidence'; Change = { param($c) (Get-Group $c 'anaerobes')['Members'][0]['Evidence'][0] = 'doi:10.2900/7455255' } }
            @{ Case = 'a list of members by one'; Change = { param($c) (Get-Group $c 'anaerobes')['Members'].Add((New-Entry 'Bacillota' 'LPSN' 'phylum/bacillota')) } }
            @{ Case = 'a key it drops'; Change = { param($c) (Get-Group $c 'anaerobes').Remove('EcdcCategory') } }
            @{ Case = 'a key it adds'; Change = { param($c) (Get-Group $c 'anaerobes')['Note'] = 'x' } }
            # po4a writes an untranslated value that looks like a number unquoted, so a string comes back as a number.
            @{ Case = 'the type of a value, its text kept'; Change = { param($c) (Get-Group $c 'fungi')['Members'][0]['ConceptId'] = '455206' } }
            @{ Case = 'a value into a list of it'; Change = { param($c) (Get-Group $c 'viruses')['Members'][0]['ConceptSource'] = [System.Collections.Generic.List[object]]@('NeoIPC') } }
        ) {
            Get-Rule (Get-NeoIPCReportingGroupTranslationFinding -Classification (Edit-Classification) -Translation (Edit-Classification $Change) -Location 'de') | Should -Be @('translation-difference')
        }

        It 'reports a translation that is no mapping' {
            Get-Rule (Get-NeoIPCReportingGroupTranslationFinding -Classification (Edit-Classification) -Translation 'Groups' -Location 'de') | Should -Be @('translation-difference')
        }
    }

    Describe 'Get-NeoIPCPo4aConfigurationFinding' {
        BeforeAll {
            $script:GroupsMaster = 'metadata/common/infectious-agents/NeoIPC-Infectious-Agent-Reporting-Groups.yaml'
            $script:ListMaster = 'metadata/common/infectious-agents/NeoIPC-Infectious-Agents.yaml'
            # A configuration of the clean classification and list that every check passes: the list's line spreads its
            # paths over lines continued by a backslash, one of them indented, as po4a reads them.
            $script:Po4aConfiguration = @'
[po4a_langs] de es
[po4a_paths] po/infectious_agents.pot $lang:po/infectious_agents.$lang.po
# The classification's labels only.
[type: yaml] metadata/common/infectious-agents/NeoIPC-Infectious-Agent-Reporting-Groups.yaml $lang:groups.$lang.yaml opt:"-o skip_array -o paths='Groups Name,Groups Children Name,Groups Children Definition,Attributes Name,Attributes Values Name'" # manual-keys
[type: yaml] metadata/common/infectious-agents/NeoIPC-Infectious-Agents.yaml $lang:list.$lang.yaml opt:"-o paths='\ # manual-keys
Hierarchies Name,Hierarchies ConceptType,\
    Hierarchies Children Name,Hierarchies Children ConceptType,\
Hierarchies Children Children Name,Hierarchies Children Children ConceptType,\
Hierarchies Children Children Children Name,Hierarchies Children Children Children ConceptType,\
Hierarchies Children Children Children Synonyms Name'"
[type: asciidoc] header.adoc $lang:header.$lang.adoc
'@

            function Get-Po4aFinding {
                # The findings of the configuration check, on the given configuration, of the clean classification and list.
                param([Parameter(Mandatory)][string]$Configuration)
                @(Get-NeoIPCPo4aConfigurationFinding -Configuration $Configuration -Classification (Edit-Classification) -Tree (Edit-Ontology) `
                        -ClassificationMaster $script:GroupsMaster -TreeMaster $script:ListMaster)
            }
        }

        It 'reads a configuration as po4a does: comments out, spaces collapsed, and a line ending in a backslash continued' {
            ConvertFrom-NeoIPCPo4aConfiguration -Text "# note`n[x] a,\ # note`nb,\`n   c`n[y]  d" | Should -Be @('[x] a,b, c', '[y] d')
        }

        It 'drops a line still continued at the end of the text, as po4a does, <Case>' -ForEach @(
            @{ Case = 'after a final line break'; Text = "[x] a`n[y] b\`n" }
            @{ Case = 'without one'; Text = "[x] a`n[y] b\" }
        ) {
            $lines = @(ConvertFrom-NeoIPCPo4aConfiguration -Text $Text)
            $lines.Count | Should -Be 1
            $lines[0] | Should -Be '[x] a'
        }

        It 'reports nothing for a clean configuration' {
            Get-Po4aFinding $script:Po4aConfiguration | Should -BeNullOrEmpty
        }

        It 'reports <Case>' -ForEach @(
            @{ Case = 'a line that names keys'; Old = "opt:`"-o paths='\"; New = "opt:`"-o keys='Name' -o paths='\"; Rule = 'po4a-keys' }
            @{ Case = 'the classification''s line without skip_array'; Old = '-o skip_array '; New = ''; Rule = 'po4a-skip-array' }
            @{ Case = 'a group label no path reaches'; Old = ',Groups Children Definition'; New = ''; Rule = 'po4a-path-missing' }
            @{ Case = 'a value of the list no path reaches'; Old = ',Hierarchies Children Children Children ConceptType'; New = ''; Rule = 'po4a-path-missing' }
            @{ Case = 'a path to the members'' names'; Old = ',Attributes Values Name'; New = ',Attributes Values Name,Groups Children Members Name'; Rule = 'po4a-path-extra' }
        ) {
            $configuration = $script:Po4aConfiguration.Replace($Old, $New)
            $configuration | Should -Not -Be $script:Po4aConfiguration
            Get-Rule (Get-Po4aFinding $configuration) | Should -Be @($Rule)
        }

        It 'reports a document the configuration does not list' {
            $configuration = ($script:Po4aConfiguration -split "`n" | Where-Object { -not $_.StartsWith('[type: yaml] metadata/common/infectious-agents/NeoIPC-Infectious-Agent-Reporting-Groups.yaml') }) -join "`n"
            Get-Rule (Get-Po4aFinding $configuration) | Should -Be @('po4a-document')
        }

        It 'reports a document the configuration lists twice' {
            $line = $script:Po4aConfiguration -split "`n" | Where-Object { $_.StartsWith('[type: yaml] metadata/common/infectious-agents/NeoIPC-Infectious-Agent-Reporting-Groups.yaml') }
            Get-Rule (Get-Po4aFinding "$($script:Po4aConfiguration)`n$line") | Should -Be @('po4a-document')
        }

        It 'reports keys named <Case>' -ForEach @(
            @{ Case = 'in a second option argument'; Old = "Attributes Values Name'`""; New = "Attributes Values Name'`" opt:`"-o keys='Name'`""; Rules = @('po4a-keys') }
            @{ Case = 'by --option'; Old = 'opt:"-o skip_array'; New = 'opt:"--option keys=Name -o skip_array'; Rules = @('po4a-keys') }
            @{ Case = 'by -o bundled with its value'; Old = 'opt:"-o skip_array'; New = 'opt:"-okeys=Name -o skip_array'; Rules = @('po4a-keys') }
            @{ Case = 'for one language'; Old = "Attributes Values Name'`""; New = "Attributes Values Name'`" opt_de:`"-o keys='Name'`""; Rules = @('po4a-keys') }
            @{ Case = 'in the configuration''s options, for every document'; Old = '[po4a_paths]'; New = "[options] --keep 0 -o keys=Name`n[po4a_paths]"; Rules = @('po4a-keys', 'po4a-keys') }
        ) {
            $configuration = $script:Po4aConfiguration.Replace($Old, $New)
            $configuration | Should -Not -Be $script:Po4aConfiguration
            Get-Rule (Get-Po4aFinding $configuration) | Should -Be $Rules
        }

        It 'takes the last of the paths a line gives twice, as po4a does' {
            $first = $script:Po4aConfiguration.Replace("opt:`"-o skip_array -o paths='Groups Name,", "opt:`"-o skip_array -o paths='Groups Name' -o paths='Groups Name,")
            $first | Should -Not -Be $script:Po4aConfiguration
            Get-Po4aFinding $first | Should -BeNullOrEmpty
            $last = $script:Po4aConfiguration.Replace("Attributes Values Name'`"", "Attributes Values Name' -o paths='Groups Name'`"")
            $last | Should -Not -Be $script:Po4aConfiguration
            @(Get-Rule (Get-Po4aFinding $last) | Sort-Object -Unique) | Should -Be @('po4a-path-missing')
        }

        It 'checks the paths that one language''s options give the document' {
            $configuration = $script:Po4aConfiguration.Replace("Attributes Values Name'`"", "Attributes Values Name'`" opt_de:`"-o paths='Groups Name'`"")
            $configuration | Should -Not -Be $script:Po4aConfiguration
            $findings = @(Get-Po4aFinding $configuration)
            @(Get-Rule $findings | Sort-Object -Unique) | Should -Be @('po4a-path-missing')
            @($findings | Where-Object { $_.Location -cnotlike '*(de)' }) | Should -BeNullOrEmpty
        }
    }
}
