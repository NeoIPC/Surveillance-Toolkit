#Requires -Version 7.6

<#
.SYNOPSIS
    Tests of the infectious-agent list's checks (Private/InfectiousAgentValidation.ps1) on fixtures.

.DESCRIPTION
    Each rule is shown firing on a fixture that carries its defect, beside a clean fixture that yields no finding, so
    a check that stops firing fails here. MetadataContent.Tests.ps1 applies the same checks to the committed list.

    Internals are reached through InModuleScope; the Import-Module at file top runs during Pester's discovery phase,
    which InModuleScope requires.

.EXAMPLE
    Invoke-Pester -Path scripts/modules/NeoIPC-Tools/Tests/InfectiousAgentValidation.Tests.ps1
#>

Import-Module (Join-Path $PSScriptRoot '..') -Force

InModuleScope 'NeoIPC-Tools' {

    BeforeAll {
        Import-Module powershell-yaml -ErrorAction Stop

        # A small list in the committed file's shape: the not-listed option, a bacterial genus with a synonym, and the
        # top-level Viruses node with one genus.
        $script:CleanYaml = @'
Metadata:
  ListTerms:
    Name:
      Value: Name
  UrlTemplates:
    ICTV: https://ictv.global/taxonomy/taxondetails?taxnode_id={0}
    LPSN: https://lpsn.dsmz.de/{0}
    MycoBank: https://www.mycobank.org/MB/{0}
    NeoIPC: https://neoipc.org/infectious-agents/{0}
Hierarchies:
- Id: 0
  Name: Not listed
  ConceptType: Unknown
  ConceptSource: NeoIPC
  ConceptId: 1
- Name: Bacteria
  ConceptType: Domain
  ConceptSource: LPSN
  ConceptId: domain/bacteria
  LpsnRecordNumber: 1
  Children:
  - Id: 10
    Name: Staphylococcus
    ConceptType: Genus
    ConceptSource: LPSN
    ConceptId: genus/staphylococcus
    LpsnRecordNumber: 2
    CommonCommensal: true
    Synonyms:
    - Id: 11
      Name: Micrococcus
      ConceptSource: LPSN
      ConceptId: genus/micrococcus
      LpsnRecordNumber: 3
- Name: Viruses
  ConceptSource: NeoIPC
  ConceptId: 2
  Children:
  - Id: 20
    Name: Orthoflavivirus
    ConceptType: Genus
    ConceptSource: ICTV
    ConceptId: 202401234
    IctvId: 19990001
'@

        function Get-Rule {
            # The rules of a set of findings, for asserting which rule fired.
            param([AllowEmptyCollection()][object[]]$Finding)
            @($Finding | ForEach-Object { $_.Rule })
        }

        function Edit-Tree {
            # A clean tree with one change applied by the script block, which receives the tree.
            param([Parameter(Mandatory)][scriptblock]$Change)
            $tree = $script:CleanYaml | ConvertFrom-Yaml
            & $Change $tree
            $tree
        }

        function ConvertTo-OrdinalMap {
            # An ordinal string map from a hashtable.
            param([hashtable]$Entry)
            $map = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
            foreach ($k in $Entry.Keys) { $map[[string]$k] = [string]$Entry[$k] }
            $map
        }

        function Initialize-TestRepository {
            # A git repository of its own in TestDrive holding a list and, unless left out, its sidecar, committed,
            # with the developer's global configuration kept out (signing among it), and every git call's exit code
            # checked.
            param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Yaml, [switch]$WithoutSidecar)
            $repository = Join-Path $TestDrive $Name
            $list = Join-Path $repository 'metadata/common/infectious-agents'
            $null = New-Item -ItemType Directory -Path $list -Force
            [System.IO.File]::WriteAllText((Join-Path $list 'NeoIPC-Infectious-Agents.yaml'), $Yaml, [System.Text.UTF8Encoding]::new($false))
            if (-not $WithoutSidecar) {
                [System.IO.File]::WriteAllText((Join-Path $list 'NeoIPC-Infectious-Agents.uids.csv'), "id,uid`n10,a1234567890`n", [System.Text.UTF8Encoding]::new($false))
            }
            Invoke-TestGit -Repository $repository -Argument 'init', '-q', '-b', 'main'
            Invoke-TestGit -Repository $repository -Argument 'add', '-A'
            Invoke-TestGit -Repository $repository -Argument 'commit', '-q', '-m', 'init'
            $repository
        }

        function Invoke-TestGit {
            # git in a test repository, with no global or system configuration, without the variables that would tie
            # it to another repository, such as the GIT_DIR a hook running this suite inherits, and a failure as a
            # failed test.
            param([Parameter(Mandatory)][string]$Repository, [Parameter(Mandatory)][string[]]$Argument)
            $global = Join-Path $TestDrive 'gitconfig'
            if (-not (Test-Path -LiteralPath $global)) { [System.IO.File]::WriteAllText($global, '', [System.Text.UTF8Encoding]::new($false)) }
            $start = [System.Diagnostics.ProcessStartInfo]::new('git')
            foreach ($item in @('-C', $Repository, '-c', 'user.email=t@t', '-c', 'user.name=t', '-c', 'commit.gpgsign=false', '-c', 'tag.gpgsign=false') + $Argument) {
                $start.ArgumentList.Add($item)
            }
            foreach ($name in Get-NeoIPCGitLocalVariable) { [void]$start.Environment.Remove($name) }
            $start.Environment['GIT_CONFIG_GLOBAL'] = $global
            $start.Environment['GIT_CONFIG_NOSYSTEM'] = '1'
            $start.RedirectStandardOutput = $true
            $start.RedirectStandardError = $true
            $process = [System.Diagnostics.Process]::Start($start)
            $errorOutput = $process.StandardError.ReadToEndAsync()
            $null = $process.StandardOutput.ReadToEnd()
            $process.WaitForExit()
            $process.ExitCode | Should -Be 0 -Because "git $($Argument -join ' ') must succeed: $($errorOutput.Result)"
        }
    }

    Describe 'Get-NeoIPCInfectiousAgentKeyFinding' {
        It 'reports nothing for a clean list' {
            @(Get-NeoIPCInfectiousAgentKeyFinding -Text $script:CleanYaml) | Should -BeNullOrEmpty
        }

        It 'reports a key outside the vocabulary of a node' {
            $text = $script:CleanYaml -replace '(?m)^(  Name: Not listed)$', "`$1`n  Remark: none"
            Get-Rule (Get-NeoIPCInfectiousAgentKeyFinding -Text $text) | Should -Be @('unknown-key')
        }

        It 'reports a key in another case than the vocabulary spells it' {
            $text = $script:CleanYaml -replace '(?m)^  ConceptId: 1$', '  conceptId: 1'
            Get-Rule (Get-NeoIPCInfectiousAgentKeyFinding -Text $text) | Should -Be @('unknown-key')
        }

        It 'reports a key outside the vocabulary of the root' {
            Get-Rule (Get-NeoIPCInfectiousAgentKeyFinding -Text ($script:CleanYaml + "`nExtra: 1`n")) | Should -Be @('unknown-key')
        }

        It 'reports node children given as a mapping instead of a list' {
            $text = $script:CleanYaml -replace '(?m)^- Name: Viruses$', "- Name: Viruses`n  Synonyms:`n    Id: 30"
            Get-Rule (Get-NeoIPCInfectiousAgentKeyFinding -Text $text) | Should -Be @('structure')
        }

        It 'reports a document that is not a mapping' {
            Get-Rule (Get-NeoIPCInfectiousAgentKeyFinding -Text "just text`n") | Should -Be @('structure')
        }

        It 'reports a mapping key that is not a scalar' {
            Get-Rule (Get-NeoIPCInfectiousAgentKeyFinding -Text ($script:CleanYaml + "`n? [a, b]`n: c`n")) | Should -Be @('structure')
            $alias = Get-NeoIPCInfectiousAgentKeyFinding -Text ($script:CleanYaml + "`n*a : c`n")
            Get-Rule $alias | Should -Be @('structure')
            $alias.Message | Should -Be 'A mapping key is an alias, not a scalar.'
        }

        It 'reports <Rule> for <Defect>' -ForEach @(
            @{ Defect = 'an Id written as a float'; Rule = 'id-type'; From = '(?m)^  - Id: 10$'; To = '  - Id: 10.0' }
            @{ Defect = 'a negative Id'; Rule = 'id-type'; From = '(?m)^  - Id: 10$'; To = '  - Id: -10' }
            @{ Defect = 'an Id beyond 32 bits'; Rule = 'id-type'; From = '(?m)^  - Id: 10$'; To = '  - Id: 2147483648' }
            @{ Defect = 'an Id written with a sign'; Rule = 'id-type'; From = '(?m)^  - Id: 10$'; To = '  - Id: +10' }
            @{ Defect = 'an Id written as a quoted string'; Rule = 'id-type'; From = '(?m)^  - Id: 10$'; To = "  - Id: '10'" }
            @{ Defect = 'an Id with an explicit tag'; Rule = 'id-type'; From = '(?m)^  - Id: 10$'; To = '  - Id: !!int 10' }
            @{ Defect = 'a record number written as a float'; Rule = 'record-number'; From = '(?m)^    LpsnRecordNumber: 2$'; To = '    LpsnRecordNumber: 2.0' }
            @{ Defect = 'a record number of 0'; Rule = 'record-number'; From = '(?m)^    LpsnRecordNumber: 2$'; To = '    LpsnRecordNumber: 0' }
            @{ Defect = 'a record number beyond 32 bits'; Rule = 'record-number'; From = '(?m)^    LpsnRecordNumber: 2$'; To = '    LpsnRecordNumber: 2147483648' }
            @{ Defect = 'a record number with an explicit tag'; Rule = 'record-number'; From = '(?m)^    LpsnRecordNumber: 2$'; To = '    LpsnRecordNumber: !!int 2' }
            @{ Defect = 'a flag in mixed letter case'; Rule = 'flag-type'; From = '(?m)^    CommonCommensal: true$'; To = '    CommonCommensal: tRuE' }
            @{ Defect = 'a flag written as yes'; Rule = 'flag-type'; From = '(?m)^    CommonCommensal: true$'; To = '    CommonCommensal: yes' }
            @{ Defect = 'a flag written as a quoted string'; Rule = 'flag-type'; From = '(?m)^    CommonCommensal: true$'; To = "    CommonCommensal: 'true'" }
        ) {
            $text = $script:CleanYaml -replace $From, $To
            $text | Should -Not -BeExactly $script:CleanYaml
            Get-Rule (Get-NeoIPCInfectiousAgentKeyFinding -Text $text) | Should -Be @($Rule)
        }

        It 'accepts the forms its types take: <To>' -ForEach @(
            @{ From = '(?m)^    CommonCommensal: true$'; To = '    CommonCommensal: False' }
            @{ From = '(?m)^  - Id: 10$'; To = '  - Id: 2147483647' }
        ) {
            @(Get-NeoIPCInfectiousAgentKeyFinding -Text ($script:CleanYaml -replace $From, $To)) | Should -BeNullOrEmpty
        }

        It "accepts a node's Comments, with the reason for a flag under its key and other prose under Background" {
            $text = $script:CleanYaml -replace '(?m)^(    CommonCommensal: true)$', "`$1`n    Comments:`n      CommonCommensal: The genus is a common commensal.`n      Background: >-`n        Other prose."
            $text | Should -Not -BeExactly $script:CleanYaml
            @(Get-NeoIPCInfectiousAgentKeyFinding -Text $text) | Should -BeNullOrEmpty
        }

        It 'reports <Rule> for <Defect>' -ForEach @(
            @{ Defect = "a key outside the vocabulary of a node's Comments"; Rule = 'unknown-key'; To = "`$1`n    Comments:`n      Remark: none" }
            @{ Defect = 'Comments given as a text'; Rule = 'structure'; To = "`$1`n    Comments: The genus is a common commensal." }
            @{ Defect = 'a Comments entry given as a mapping'; Rule = 'structure'; To = "`$1`n    Comments:`n      Background:`n        Text: Other prose." }
            @{ Defect = 'a Description, which a node does not carry'; Rule = 'unknown-key'; To = "`$1`n    Description: Other prose." }
        ) {
            $text = $script:CleanYaml -replace '(?m)^(    CommonCommensal: true)$', $To
            $text | Should -Not -BeExactly $script:CleanYaml
            Get-Rule (Get-NeoIPCInfectiousAgentKeyFinding -Text $text) | Should -Be @($Rule)
        }

        It 'reports text that is not YAML instead of throwing' {
            Get-Rule (Get-NeoIPCInfectiousAgentKeyFinding -Text "Hierarchies: [`n") | Should -Be @('yaml-syntax')
        }
    }

    Describe 'Get-NeoIPCInfectiousAgentNodeFinding' {
        It 'reports nothing for a clean list' {
            @(Get-NeoIPCInfectiousAgentNodeFinding -Tree ($script:CleanYaml | ConvertFrom-Yaml)) | Should -BeNullOrEmpty
        }

        It 'reports <Rule> for <Defect>' -ForEach @(
            @{ Defect = 'an Id written as a string'; Rule = 'id-type'; Change = { param($t) $t.Hierarchies[1].Children[0].Id = '10' } }
            @{ Defect = 'an Id given twice'; Rule = 'id-duplicate'; Change = { param($t) $t.Hierarchies[1].Children[0].Synonyms[0].Id = 10 } }
            @{ Defect = 'a node without a Name'; Rule = 'name'; Change = { param($t) $t.Hierarchies[1].Children[0].Name = '' } }
            @{ Defect = 'a concept without a rank'; Rule = 'concept-type'; Change = { param($t) $t.Hierarchies[1].Children[0].Remove('ConceptType') } }
            @{ Defect = 'a rank outside the vocabulary'; Rule = 'concept-type'; Change = { param($t) $t.Hierarchies[1].Children[0].ConceptType = 'Genre' } }
            @{ Defect = 'a source the URL templates lack'; Rule = 'concept-source'; Change = { param($t) $t.Hierarchies[0].ConceptSource = 'NCBI' } }
            @{ Defect = 'a source in another letter case'; Rule = 'concept-source'; Change = { param($t) $t.Hierarchies[0].ConceptSource = 'neoipc' } }
            @{ Defect = 'a node without a ConceptId'; Rule = 'concept-id'; Change = { param($t) $t.Hierarchies[0].Remove('ConceptId') } }
            @{ Defect = 'an LPSN concept without its record number'; Rule = 'record-number'; Change = { param($t) $t.Hierarchies[1].Children[0].Remove('LpsnRecordNumber') } }
            @{ Defect = 'a record number written as a string'; Rule = 'record-number'; Change = { param($t) $t.Hierarchies[2].Children[0].IctvId = '19990001' } }
            @{ Defect = "another source's record number"; Rule = 'record-number'; Change = { param($t) $t.Hierarchies[2].Children[0].MycoBankNr = 5 } }
            @{ Defect = 'a flag written as a string'; Rule = 'flag-type'; Change = { param($t) $t.Hierarchies[1].Children[0].CommonCommensal = 'true' } }
            @{ Defect = 'no top-level Id 0'; Rule = 'required-node'; Change = { param($t) $t.Hierarchies[0].Id = 1 } }
            @{ Defect = 'no top-level Viruses node'; Rule = 'required-node'; Change = { param($t) $t.Hierarchies[2].Name = 'Virus' } }
        ) {
            Get-Rule (Get-NeoIPCInfectiousAgentNodeFinding -Tree (Edit-Tree -Change $Change)) | Should -Be @($Rule)
        }

        It 'checks a node that has neither a Name nor an Id' {
            # The Bacteria domain, Id-less, loses its Name: every rule a node owes still applies to it.
            $tree = Edit-Tree -Change { param($t) $t.Hierarchies[1].Remove('Name'); $t.Hierarchies[1].ConceptSource = 'NCBI' }
            Get-Rule (Get-NeoIPCInfectiousAgentNodeFinding -Tree $tree) | Should -Be @('name', 'concept-source', 'record-number')
        }

        It 'reports a list without Hierarchies instead of throwing' {
            Get-Rule (Get-NeoIPCInfectiousAgentNodeFinding -Tree @{ Metadata = @{} }) | Should -Be @('structure')
        }

        It 'reports a list without Metadata.UrlTemplates' {
            Get-Rule (Get-NeoIPCInfectiousAgentNodeFinding -Tree @{ Hierarchies = @() }) | Should -Be @('structure', 'required-node', 'required-node')
        }
    }

    Describe 'Get-NeoIPCInfectiousAgentIdentityFinding' {
        It 'reports nothing for a clean list' {
            @(Get-NeoIPCInfectiousAgentIdentityFinding -Tree ($script:CleanYaml | ConvertFrom-Yaml)) | Should -BeNullOrEmpty
        }

        It 'reports <Rule> for <Defect>' -ForEach @(
            @{ Defect = 'a synonym without an Id'; Rule = 'synonym-id'; Change = { param($t) $t.Hierarchies[1].Children[0].Synonyms[0].Remove('Id') } }
            @{ Defect = 'a NeoIPC ConceptId that is no number'; Rule = 'concept-id-format'; Change = { param($t) $t.Hierarchies[0].ConceptId = 'ToDo' } }
            @{ Defect = 'a NeoIPC ConceptId of 0'; Rule = 'concept-id-format'; Change = { param($t) $t.Hierarchies[0].ConceptId = 0 } }
            @{ Defect = 'a NeoIPC ConceptId quoted as text, as a reader reads it'; Rule = 'concept-id-format'; Change = { param($t) $t.Hierarchies[0].ConceptId = '5' } }
            @{ Defect = 'two NeoIPC nodes with one ConceptId'; Rule = 'concept-id-duplicate'; Change = { param($t) $t.Hierarchies[2].ConceptId = 1 } }
            @{ Defect = 'two LPSN nodes with one ConceptId'; Rule = 'concept-id-duplicate'; Change = { param($t) $t.Hierarchies[1].Children[0].Synonyms[0].ConceptId = 'genus/staphylococcus' } }
            @{ Defect = 'two LPSN nodes with one record number'; Rule = 'record-duplicate'; Change = { param($t) $t.Hierarchies[1].Children[0].Synonyms[0].LpsnRecordNumber = 2 } }
            @{ Defect = 'two ICTV concepts with one IctvId'; Rule = 'record-duplicate'; Change = {
                    param($t)
                    $t.Hierarchies[2].Children = @($t.Hierarchies[2].Children[0], @{ Id = 21; Name = 'Orthohepacivirus'; ConceptType = 'Genus'; ConceptSource = 'ICTV'; ConceptId = 202401235; IctvId = 19990001 })
                }
            }
            @{ Defect = "a synonym that shares another concept's IctvId"; Rule = 'record-duplicate'; Change = {
                    param($t)
                    $t.Hierarchies[2].Children = @($t.Hierarchies[2].Children[0], @{ Id = 21; Name = 'Orthohepacivirus'; ConceptType = 'Genus'; ConceptSource = 'ICTV'; ConceptId = 202401235; IctvId = 19990002
                            Synonyms = @(@{ Id = 22; Name = 'Hepacivirus'; ConceptSource = 'ICTV'; ConceptId = 201901235; IctvId = 19990001 })
                        })
                }
            }
        ) {
            Get-Rule (Get-NeoIPCInfectiousAgentIdentityFinding -Tree (Edit-Tree -Change $Change)) | Should -Be @($Rule)
        }

        It 'leaves a NeoIPC node with <Form> to the node check' -ForEach @(
            @{ Form = 'no ConceptId'; Change = { param($t) $t.Hierarchies[0].Remove('ConceptId') } }
            @{ Form = 'a blank ConceptId'; Change = { param($t) $t.Hierarchies[0].ConceptId = ' ' } }
        ) {
            @(Get-NeoIPCInfectiousAgentIdentityFinding -Tree (Edit-Tree -Change $Change)) | Should -BeNullOrEmpty
        }

        It 'accepts one ConceptId in two sources' {
            $tree = Edit-Tree -Change { param($t) $t.Hierarchies[2].ConceptId = 202401234 }
            @(Get-NeoIPCInfectiousAgentIdentityFinding -Tree $tree) | Should -BeNullOrEmpty
        }

        It 'accepts an IctvId that a concept shares with a synonym that is its former name' {
            $tree = Edit-Tree -Change {
                param($t)
                $t.Hierarchies[2].Children[0].Synonyms = @(@{ Id = 21; Name = 'Flavivirus'; ConceptSource = 'ICTV'; ConceptId = 201901234; IctvId = 19990001 })
            }
            @(Get-NeoIPCInfectiousAgentIdentityFinding -Tree $tree) | Should -BeNullOrEmpty
        }

        It 'reports a list without Hierarchies instead of throwing' {
            Get-Rule (Get-NeoIPCInfectiousAgentIdentityFinding -Tree @{ Metadata = @{} }) | Should -Be @('structure')
        }
    }

    Describe 'Get-NeoIPCInfectiousAgentFlagFinding' {
        BeforeAll {
            # A list whose CommonCommensal flags sit where the checks want them: a group flagged a common commensal,
            # with a species that inherits it, the species' synonym, and an exception beneath it, each flag with its
            # reason; a species of the same genus outside the group, and a second genus, neither flagged.
            $script:FlagYaml = @'
Metadata:
  UrlTemplates:
    LPSN: https://lpsn.dsmz.de/{0}
    NeoIPC: https://neoipc.org/infectious-agents/{0}
Hierarchies:
- Id: 0
  Name: Not listed
  ConceptType: Unknown
  ConceptSource: NeoIPC
  ConceptId: 1
- Name: Bacteria
  ConceptType: Domain
  ConceptSource: LPSN
  ConceptId: domain/bacteria
  LpsnRecordNumber: 1
  Children:
  - Name: Staphylococcus
    ConceptType: Genus
    ConceptSource: LPSN
    ConceptId: genus/staphylococcus
    LpsnRecordNumber: 2
    Children:
    - Id: 10
      Name: Coagulase-negative staphylococci
      ConceptType: Group
      ConceptSource: NeoIPC
      ConceptId: 2
      CommonCommensal: true
      Comments:
        CommonCommensal: The group is a common commensal.
      Children:
      - Id: 11
        Name: Staphylococcus epidermidis
        ConceptType: Species
        ConceptSource: LPSN
        ConceptId: species/staphylococcus-epidermidis
        LpsnRecordNumber: 3
        Synonyms:
        - Id: 12
          Name: Staphylococcus albus
          ConceptSource: LPSN
          ConceptId: species/staphylococcus-albus
          LpsnRecordNumber: 4
      - Id: 13
        Name: Staphylococcus lugdunensis
        ConceptType: Species
        ConceptSource: LPSN
        ConceptId: species/staphylococcus-lugdunensis
        LpsnRecordNumber: 5
        CommonCommensal: false
        Comments:
          CommonCommensal: The species is an exception within the group.
          Background: Other prose.
    - Id: 14
      Name: Staphylococcus aureus
      ConceptType: Species
      ConceptSource: LPSN
      ConceptId: species/staphylococcus-aureus
      LpsnRecordNumber: 6
  - Name: Escherichia
    ConceptType: Genus
    ConceptSource: LPSN
    ConceptId: genus/escherichia
    LpsnRecordNumber: 7
    Children:
    - Id: 15
      Name: Escherichia coli
      ConceptType: Species
      ConceptSource: LPSN
      ConceptId: species/escherichia-coli
      LpsnRecordNumber: 8
'@

            function Edit-FlagTree {
                # The flag fixture with one change applied by the script block, which receives the tree's nodes by
                # name.
                param([Parameter(Mandatory)][scriptblock]$Change)
                $tree = $script:FlagYaml | ConvertFrom-Yaml
                $bacteria = $tree.Hierarchies[1]
                $nodes = @{
                    NotListed = $tree.Hierarchies[0]; Bacteria = $bacteria; Staphylococcus = $bacteria.Children[0]
                    Group = $bacteria.Children[0].Children[0]; Epidermidis = $bacteria.Children[0].Children[0].Children[0]
                    Albus = $bacteria.Children[0].Children[0].Children[0].Synonyms[0]
                    Lugdunensis = $bacteria.Children[0].Children[0].Children[1]; Aureus = $bacteria.Children[0].Children[1]
                }
                & $Change $nodes
                $tree
            }
        }

        It 'reports nothing for a list whose flags sit where their statuses hold, each with its reason' {
            @(Get-NeoIPCInfectiousAgentFlagFinding -Tree ($script:FlagYaml | ConvertFrom-Yaml)) | Should -BeNullOrEmpty
        }

        It 'reports <Rule> for <Defect>' -ForEach @(
            @{ Defect = 'a flag on a synonym'; Rule = 'flag-on-synonym'; Change = { param($n) $n.Albus.CommonCommensal = $true } }
            @{ Defect = 'a flag that repeats an inherited true'; Rule = 'flag-redundant'; Change = { param($n) $n.Epidermidis.CommonCommensal = $true; $n.Epidermidis.Comments = @{ CommonCommensal = 'A reason.' } } }
            @{ Defect = 'a top-level false, the status without any flag'; Rule = 'flag-redundant'; Change = { param($n) $n.NotListed.CommonCommensal = $false; $n.NotListed.Comments = @{ CommonCommensal = 'A reason.' } } }
            @{ Defect = 'a flag without Comments'; Rule = 'flag-comment-missing'; Change = { param($n) $n.Group.Remove('Comments') } }
            @{ Defect = "a flag whose Comments lack the flag's key"; Rule = 'flag-comment-missing'; Change = { param($n) $n.Group.Comments = @{ Background = 'Other prose.' } } }
            @{ Defect = 'the reason for a flag the node lacks, where no warning asks for one'; Rule = 'comment-key'; Change = { param($n) $n.Aureus.Comments = @{ CommonCommensal = 'A reason.' } } }
            @{ Defect = 'the reason for a resistance flag the node lacks'; Rule = 'comment-key'; Change = { param($n) $n.Aureus.Comments = @{ MRSA = 'A reason.' } } }
            @{ Defect = 'Comments given as a text'; Rule = 'comment'; Change = { param($n) $n.Aureus.Comments = 'Other prose.' } }
            @{ Defect = 'Comments given as a list of one mapping'; Rule = 'comment'; Change = { param($n) $n.Aureus.Comments = @(@{ Background = 'Other prose.' }) } }
            @{ Defect = 'Comments given as an empty list'; Rule = 'comment'; Change = { param($n) $n.Aureus.Comments = @() } }
            @{ Defect = 'a Comments entry that is a number'; Rule = 'comment'; Change = { param($n) $n.Lugdunensis.Comments.Background = 5 } }
            @{ Defect = 'an empty Comments entry'; Rule = 'comment'; Change = { param($n) $n.Lugdunensis.Comments.Background = ' ' } }
        ) {
            $findings = @(Get-NeoIPCInfectiousAgentFlagFinding -Tree (Edit-FlagTree -Change $Change))
            Get-Rule $findings | Should -Be @($Rule)
            $findings.Severity | Should -Be @('Error')
        }

        It 'accepts the reason for a resistance flag the node carries' {
            $tree = Edit-FlagTree -Change { param($n) $n.Aureus.MRSA = $true; $n.Aureus.Comments = @{ MRSA = 'A reason.' } }
            @(Get-NeoIPCInfectiousAgentFlagFinding -Tree $tree) | Should -BeNullOrEmpty
        }

        It 'warns at a node where one flag would hold for every Id-bearing node beneath it' {
            # Without the exception and the species outside the group, every Id-bearing node of the genus is a
            # common commensal through the group's flag.
            $tree = Edit-FlagTree -Change {
                param($n)
                $n.Lugdunensis.Remove('CommonCommensal'); $n.Lugdunensis.Remove('Comments')
                $n.Staphylococcus.Children = @($n.Group)
            }
            $findings = @(Get-NeoIPCInfectiousAgentFlagFinding -Tree $tree)
            Get-Rule $findings | Should -Be @('flag-hoistable')
            $findings.Severity | Should -Be @('Warning')
            $findings.Location | Should -Be @("'Staphylococcus'")
        }

        It 'warns only at the highest such node' {
            $tree = Edit-FlagTree -Change {
                param($n)
                $n.Lugdunensis.Remove('CommonCommensal'); $n.Lugdunensis.Remove('Comments')
                $n.Staphylococcus.Children = @($n.Group)
                $n.Bacteria.Children = @($n.Staphylococcus)
            }
            (@(Get-NeoIPCInfectiousAgentFlagFinding -Tree $tree)).Location | Should -Be @("'Bacteria'")
        }

        It 'warns at an Id-bearing node whose own status differs from that of every Id-bearing node beneath it' {
            $tree = Edit-FlagTree -Change {
                param($n)
                $n.Aureus.Children = @(@{ Id = 16; Name = 'Staphylococcus aureus subsp. anaerobius'; ConceptType = 'Subspecies'; ConceptSource = 'LPSN'
                        ConceptId = 'subspecies/staphylococcus-aureus-anaerobius'; LpsnRecordNumber = 9; CommonCommensal = $true; Comments = @{ CommonCommensal = 'A reason.' }
                    })
            }
            $findings = @(Get-NeoIPCInfectiousAgentFlagFinding -Tree $tree)
            Get-Rule $findings | Should -Be @('flag-hoistable')
            $findings.Location | Should -Be @('Id 14')
            $findings.Message | Should -BeLike 'The node is no common commensal, the status it inherits, while *'
        }

        It 'takes the reason on the node a warning names as its answer, and names the highest such nodes beneath instead' {
            $tree = Edit-FlagTree -Change {
                param($n)
                $n.Lugdunensis.Remove('CommonCommensal'); $n.Lugdunensis.Remove('Comments')
                $n.Staphylococcus.Children = @($n.Group)
                $n.Bacteria.Children = @($n.Staphylococcus)
                $n.Bacteria.Comments = @{ CommonCommensal = 'A reason the flags stay beneath the domain.' }
            }
            (@(Get-NeoIPCInfectiousAgentFlagFinding -Tree $tree)).Location | Should -Be @("'Staphylococcus'")
            $tree.Hierarchies[1].Children[0].Comments = @{ CommonCommensal = 'A reason the flag stays on the group.' }
            @(Get-NeoIPCInfectiousAgentFlagFinding -Tree $tree) | Should -BeNullOrEmpty
        }

        It 'does not warn at a node under which no node has an Id' {
            $tree = Edit-FlagTree -Change {
                param($n)
                $n.Aureus.Children = @(@{ Name = 'Staphylococcus aureus subsp. aureus'; ConceptType = 'Subspecies'; ConceptSource = 'LPSN'
                        ConceptId = 'subspecies/staphylococcus-aureus-aureus'; LpsnRecordNumber = 9
                    })
            }
            @(Get-NeoIPCInfectiousAgentFlagFinding -Tree $tree) | Should -BeNullOrEmpty
        }

        It 'does not warn at a synonym' {
            # A synonym without an Id, an identity defect, whose concept child is the exception: the one status
            # beneath the synonym is not the synonym's to carry. A second species keeps its concept's subtree mixed.
            $tree = Edit-FlagTree -Change {
                param($n)
                $n.Albus.Remove('Id')
                $n.Albus.Children = @(@{ Id = 17; Name = 'Staphylococcus albus var. nobilis'; ConceptType = 'Variety'; ConceptSource = 'LPSN'
                        ConceptId = 'variety/staphylococcus-albus-nobilis'; LpsnRecordNumber = 10; CommonCommensal = $false; Comments = @{ CommonCommensal = 'A reason.' }
                    })
                $n.Epidermidis.Children = @(@{ Id = 18; Name = 'Staphylococcus epidermidis subsp. epidermidis'; ConceptType = 'Subspecies'; ConceptSource = 'LPSN'
                        ConceptId = 'subspecies/staphylococcus-epidermidis-epidermidis'; LpsnRecordNumber = 11
                    })
            }
            @(Get-NeoIPCInfectiousAgentFlagFinding -Tree $tree) | Should -BeNullOrEmpty
        }

        It 'reads a flag written as text that parses as a Boolean, as the walkers do' {
            # Read as true, the group's flag makes the same flag on its species repeat the status the species
            # inherits; a flag the check could not read would leave that status unknown.
            $tree = Edit-FlagTree -Change {
                param($n)
                $n.Group.CommonCommensal = 'true'
                $n.Epidermidis.CommonCommensal = $true; $n.Epidermidis.Comments = @{ CommonCommensal = 'A reason.' }
            }
            $findings = @(Get-NeoIPCInfectiousAgentFlagFinding -Tree $tree)
            Get-Rule $findings | Should -Be @('flag-redundant')
            $findings.Location | Should -Be @('Id 11')
        }

        It 'leaves a flag that is no Boolean to the node check, and judges no flag beneath it against the status it would set' {
            # Read as no flag, the group would leave the exception beneath it repeating the genus's status.
            $tree = Edit-FlagTree -Change { param($n) $n.Group.CommonCommensal = 'maybe' }
            @(Get-NeoIPCInfectiousAgentFlagFinding -Tree $tree) | Should -BeNullOrEmpty
        }

        It 'does not warn where the status beneath is unknown' {
            $tree = Edit-FlagTree -Change {
                param($n)
                $n.Group.CommonCommensal = 'maybe'
                $n.Lugdunensis.Remove('CommonCommensal'); $n.Lugdunensis.Remove('Comments')
                $n.Staphylococcus.Children = @($n.Group)
            }
            @(Get-NeoIPCInfectiousAgentFlagFinding -Tree $tree) | Should -BeNullOrEmpty
        }

        It 'judges the flags beneath again once a flag it can read sets the status' {
            $tree = Edit-FlagTree -Change {
                param($n)
                $n.Group.CommonCommensal = 'maybe'
                $n.Lugdunensis.Children = @(@{ Id = 19; Name = 'Staphylococcus lugdunensis subsp. lugdunensis'; ConceptType = 'Subspecies'; ConceptSource = 'LPSN'
                        ConceptId = 'subspecies/staphylococcus-lugdunensis-lugdunensis'; LpsnRecordNumber = 12; CommonCommensal = $false; Comments = @{ CommonCommensal = 'A reason.' }
                    })
            }
            $findings = @(Get-NeoIPCInfectiousAgentFlagFinding -Tree $tree)
            Get-Rule $findings | Should -Be @('flag-redundant')
            $findings.Location | Should -Be @('Id 19')
        }

        It 'reads the nodes of a list within a list, as the walkers do' {
            $tree = Edit-FlagTree -Change {
                param($n)
                $n.Epidermidis.CommonCommensal = $true; $n.Epidermidis.Comments = @{ CommonCommensal = 'A reason.' }
                $inner = [System.Collections.Generic.List[object]]::new()
                $inner.Add($n.Epidermidis); $inner.Add($n.Lugdunensis)
                $outer = [System.Collections.Generic.List[object]]::new()
                $outer.Add($inner)
                $n.Group.Children = $outer
            }
            $findings = @(Get-NeoIPCInfectiousAgentFlagFinding -Tree $tree)
            Get-Rule $findings | Should -Be @('flag-redundant')
            $findings.Location | Should -Be @('Id 11')
        }

        It 'reports a flag it cannot check instead of throwing' {
            Mock Get-NeoIPCInfectiousAgentNodeLocation { throw 'no location' }
            $findings = @(Get-NeoIPCInfectiousAgentFlagFinding -Tree ($script:FlagYaml | ConvertFrom-Yaml))
            Get-Rule $findings | Should -Be @('flag')
            $findings.Message | Should -BeLike '*no location*'
        }

        It 'reports a list without Hierarchies instead of throwing' {
            Get-Rule (Get-NeoIPCInfectiousAgentFlagFinding -Tree @{ Metadata = @{} }) | Should -Be @('structure')
        }
    }

    Describe 'Get-NeoIPCInfectiousAgentLabelFinding' {
        It 'reports nothing for a clean list' {
            @(Get-NeoIPCInfectiousAgentLabelFinding -Tree ($script:CleanYaml | ConvertFrom-Yaml)) | Should -BeNullOrEmpty
        }

        It 'reports two options with one label' {
            $tree = Edit-Tree -Change { param($t) $t.Hierarchies[2].Children[0].Name = 'Staphylococcus' }
            Get-Rule (Get-NeoIPCInfectiousAgentLabelFinding -Tree $tree) | Should -Be @('label-duplicate')
        }

        # The label "<name> [genus]" adds eight characters to the name.
        It 'reports a label longer than the 230 characters DHIS2 stores' {
            $tree = Edit-Tree -Change { param($t) $t.Hierarchies[2].Children[0].Name = 'x' * 223 }
            Get-Rule (Get-NeoIPCInfectiousAgentLabelFinding -Tree $tree) | Should -Be @('label-length')
        }

        It 'accepts a label of exactly 230 characters' {
            $tree = Edit-Tree -Change { param($t) $t.Hierarchies[2].Children[0].Name = 'x' * 222 }
            @(Get-NeoIPCInfectiousAgentLabelFinding -Tree $tree) | Should -BeNullOrEmpty
        }

        It 'reports labels it cannot build instead of throwing' {
            $tree = Edit-Tree -Change { param($t) $t.Hierarchies[1].Children[0].Name = '' }
            Get-Rule (Get-NeoIPCInfectiousAgentLabelFinding -Tree $tree) | Should -Be @('label')
        }
    }

    Describe 'Get-NeoIPCInfectiousAgentUidFinding' {
        BeforeAll {
            $script:Tree = $script:CleanYaml | ConvertFrom-Yaml
        }

        It 'reports nothing for a sidecar of the list''s Ids with well-formed, unique UIDs' {
            $rows = @(@{ id = '0'; uid = 'z1234567890' }, @{ id = '10'; uid = 'a1234567890' }, @{ id = '11'; uid = 'c1234567890' }, @{ id = '20'; uid = 'B1234567890' }) |
                ForEach-Object { [pscustomobject]$_ }
            @(Get-NeoIPCInfectiousAgentUidFinding -Tree $script:Tree -UidRow $rows) | Should -BeNullOrEmpty
        }

        It 'reports <Rule> for <Defect>' -ForEach @(
            @{ Defect = 'an id that is no Id of the list'; Rule = 'uid-orphan'; Rows = @(@{ id = '99'; uid = 'd1234567890' }) }
            @{ Defect = 'a uid that starts with a digit'; Rule = 'uid-format'; Rows = @(@{ id = '10'; uid = '11234567890' }) }
            @{ Defect = 'a uid of ten characters'; Rule = 'uid-format'; Rows = @(@{ id = '10'; uid = 'a123456789' }) }
            @{ Defect = 'one uid for two ids'; Rule = 'uid-duplicate'; Rows = @(@{ id = '20'; uid = 'a1234567890' }) }
            @{ Defect = 'an id listed twice'; Rule = 'uid-id-duplicate'; Rows = @(@{ id = '10'; uid = 'b1234567890' }) }
        ) {
            # A complete sidecar, with the defect's rows replacing the clean rows of their ids or added to them; the row
            # listed twice keeps the clean one too.
            $clean = [ordered]@{ '0' = 'z1234567890'; '10' = 'a1234567890'; '11' = 'c1234567890'; '20' = 'B1234567890' }
            $replaced = if ($Defect -ne 'an id listed twice') { @($Rows | ForEach-Object { $_.id }) } else { @() }
            $rows = @($clean.GetEnumerator() | Where-Object { $_.Key -notin $replaced } | ForEach-Object { [pscustomobject]@{ id = $_.Key; uid = $_.Value } }) +
                @($Rows | ForEach-Object { [pscustomobject]$_ })
            Get-Rule (Get-NeoIPCInfectiousAgentUidFinding -Tree $script:Tree -UidRow $rows) | Should -Be @($Rule)
        }

        It 'reports uid-duplicate for the option set''s own uid' {
            $rows = @(@{ id = '0'; uid = 'z1234567890' }, @{ id = '10'; uid = 'a1234567890' }, @{ id = '11'; uid = $script:NeoIPCPathogenOptionSetUid }, @{ id = '20'; uid = 'B1234567890' }) |
                ForEach-Object { [pscustomobject]$_ }
            $findings = @(Get-NeoIPCInfectiousAgentUidFinding -Tree $script:Tree -UidRow $rows)
            Get-Rule $findings | Should -Be @('uid-duplicate')
            $findings[0].Location | Should -BeExactly 'id 11'
        }

        It 'reports each Id of the list that the sidecar lacks, since no option UID is derived' {
            $rows = @([pscustomobject]@{ id = '10'; uid = 'a1234567890' }, [pscustomobject]@{ id = '20'; uid = 'B1234567890' })
            $findings = @(Get-NeoIPCInfectiousAgentUidFinding -Tree $script:Tree -UidRow $rows)
            Get-Rule $findings | Should -Be @('uid-missing', 'uid-missing')
            @($findings.Location) | Should -Be @('Id 0', 'Id 11')
        }

        It 'reports Ids it cannot read instead of throwing' {
            $tree = Edit-Tree -Change { param($t) $t.Hierarchies[1].Children[0].Name = '' }
            Get-Rule (Get-NeoIPCInfectiousAgentUidFinding -Tree $tree -UidRow @()) | Should -Be @('uid')
        }

        It 'reports an empty row instead of throwing' {
            Get-Rule (Get-NeoIPCInfectiousAgentUidFinding -Tree $script:Tree -UidRow @($null)) | Should -Be @('uid', 'uid-missing', 'uid-missing', 'uid-missing', 'uid-missing')
            Get-Rule (Get-NeoIPCInfectiousAgentUidFinding -Tree $script:Tree -UidRow $null) | Should -Be @('uid-missing', 'uid-missing', 'uid-missing', 'uid-missing')
        }
    }

    Describe 'Get-NeoIPCInfectiousAgentReleaseFinding' {
        BeforeAll {
            $script:Released = [pscustomobject]@{
                Tag      = 'infectious-agents-v0.1.0-alpha'
                Version  = '0.1.0-alpha'
                Concepts = ConvertTo-OrdinalMap @{ 10 = 'Staphylococcus'; 11 = 'Micrococcus' }
                Uids     = ConvertTo-OrdinalMap @{ 10 = 'a1234567890' }
            }
            $script:Changelog = @([pscustomobject]@{ Version = '0.1.0-alpha'; Heading = '[0.1.0-alpha] - 2026-09-07'; Line = 5 })
        }

        It 'reports nothing when the list keeps every release and adds above the released Ids' {
            $current = [pscustomobject]@{ Concepts = ConvertTo-OrdinalMap @{ 10 = 'Staphylococcus'; 11 = 'Micrococcus'; 12 = 'Kocuria' }; Uids = ConvertTo-OrdinalMap @{ 10 = 'a1234567890' } }
            @(Get-NeoIPCInfectiousAgentReleaseFinding -Current $current -Release @($script:Released) -ChangelogRelease $script:Changelog -PreparedVersion '0.1.0-alpha' -HasUnreleasedEntry $false) | Should -BeNullOrEmpty
        }

        It 'compares maps keyed by integers, or ordered, as maps keyed by text' {
            $current = [pscustomobject]@{ Concepts = [ordered]@{ 10 = 'Staphylococcus'; 11 = 'Micrococcus' }; Uids = @{ 10 = 'a1234567890' } }
            @(Get-NeoIPCInfectiousAgentReleaseFinding -Current $current -Release @($script:Released) -ChangelogRelease $script:Changelog -PreparedVersion '0.1.0-alpha' -HasUnreleasedEntry $false) | Should -BeNullOrEmpty
        }

        It 'reports <Defect> instead of throwing' -ForEach @(
            @{ Defect = 'a current list keyed by something other than Ids'; Current = @{ Concepts = @{ 'x1' = 'Staphylococcus' }; Uids = @{} }; Release = $null }
            @{ Defect = 'a current list keyed by an Id of more than 18 digits'; Current = @{ Concepts = @{ '9999999999999999999' = 'Staphylococcus' }; Uids = @{} }; Release = $null }
            # Built in two steps, since a hash literal may not name one key twice.
            @{ Defect = 'a current list holding one Id twice, as a number and as text'; Current = @{ Concepts = & { $map = @{ 10 = 'Staphylococcus' }; $map['10'] = 'Kocuria'; $map }; Uids = @{} }; Release = $null }
            @{ Defect = 'a release without its maps'; Current = $null; Release = [pscustomobject]@{ Tag = 'infectious-agents-v0.0.1-alpha'; Version = '0.0.1-alpha' } }
        ) {
            $currentList = if ($Current) { [pscustomobject]$Current } else { [pscustomobject]@{ Concepts = ConvertTo-OrdinalMap @{ 10 = 'Staphylococcus'; 11 = 'Micrococcus' }; Uids = ConvertTo-OrdinalMap @{ 10 = 'a1234567890' } } }
            $releases = @($script:Released) + @($Release | Where-Object { $_ })
            Get-Rule (Get-NeoIPCInfectiousAgentReleaseFinding -Current $currentList -Release $releases -ChangelogRelease $script:Changelog -PreparedVersion '0.1.0-alpha' -HasUnreleasedEntry $false) |
                Should -Be @('release-input')
        }

        It 'reports null arguments instead of throwing' {
            $kept = [pscustomobject]@{ Concepts = ConvertTo-OrdinalMap @{ 10 = 'Staphylococcus'; 11 = 'Micrococcus' }; Uids = ConvertTo-OrdinalMap @{ 10 = 'a1234567890' } }
            Get-Rule (Get-NeoIPCInfectiousAgentReleaseFinding -Current $kept -Release @($script:Released, $null) -ChangelogRelease $script:Changelog -PreparedVersion '0.1.0-alpha' -HasUnreleasedEntry $false) |
                Should -Be @('release-input')
            Get-Rule (Get-NeoIPCInfectiousAgentReleaseFinding -Current $kept -Release $null -ChangelogRelease $script:Changelog -PreparedVersion '0.1.0-alpha' -HasUnreleasedEntry $false) |
                Should -Be @('release-tags')
            Get-Rule (Get-NeoIPCInfectiousAgentReleaseFinding -Current $kept -Release @($script:Released) -ChangelogRelease @($null) -PreparedVersion '0.1.0-alpha' -HasUnreleasedEntry $false) |
                Should -Be @('changelog-heading')
        }

        It 'holds the list to the names and UIDs of a later line''s release outside its history, but not to that release''s added Ids' {
            # A branch that maintains 0.1, after 0.2.0 added the Ids 12 and 13 to main: it lacks them, and must not
            # reuse 13 for another name, nor take 11 or an Id up to 13 that no release has, nor give 12 another UID.
            $later = [pscustomobject]@{
                Tag = 'infectious-agents-v0.2.0-alpha'; Version = '0.2.0-alpha'; InHistory = $false
                Concepts = ConvertTo-OrdinalMap @{ 10 = 'Staphylococcus'; 11 = 'Micrococcus'; 12 = 'Kocuria'; 13 = 'Rothia' }
                Uids = ConvertTo-OrdinalMap @{ 10 = 'a1234567890'; 12 = 'c1234567890' }
            }
            $changelog = @([pscustomobject]@{ Version = '0.2.0-alpha'; Heading = '[0.2.0-alpha] - 2026-11-13'; Line = 3 }) + $script:Changelog
            $kept = [pscustomobject]@{ Concepts = ConvertTo-OrdinalMap @{ 10 = 'Staphylococcus'; 11 = 'Micrococcus' }; Uids = ConvertTo-OrdinalMap @{ 10 = 'a1234567890' } }
            @(Get-NeoIPCInfectiousAgentReleaseFinding -Current $kept -Release @($script:Released, $later) -ChangelogRelease $changelog -PreparedVersion '0.1.0-alpha' -HasUnreleasedEntry $false) | Should -BeNullOrEmpty
            $reused = [pscustomobject]@{ Concepts = ConvertTo-OrdinalMap @{ 10 = 'Staphylococcus'; 11 = 'Micrococcus'; 13 = 'Gemella' }; Uids = ConvertTo-OrdinalMap @{ 10 = 'a1234567890' } }
            Get-Rule (Get-NeoIPCInfectiousAgentReleaseFinding -Current $reused -Release @($script:Released, $later) -ChangelogRelease $changelog -PreparedVersion '0.1.0-alpha' -HasUnreleasedEntry $false) |
                Should -Be @('release-name-changed')
            $gap = [pscustomobject]@{ Concepts = ConvertTo-OrdinalMap @{ 10 = 'Staphylococcus'; 11 = 'Micrococcus'; 9 = 'Gemella' }; Uids = ConvertTo-OrdinalMap @{ 10 = 'a1234567890' } }
            Get-Rule (Get-NeoIPCInfectiousAgentReleaseFinding -Current $gap -Release @($script:Released, $later) -ChangelogRelease $changelog -PreparedVersion '0.1.0-alpha' -HasUnreleasedEntry $false) |
                Should -Be @('release-id-reused')
            $backported = [pscustomobject]@{ Concepts = ConvertTo-OrdinalMap @{ 10 = 'Staphylococcus'; 11 = 'Micrococcus'; 12 = 'Kocuria' }; Uids = ConvertTo-OrdinalMap @{ 10 = 'a1234567890'; 12 = 'd1234567890' } }
            Get-Rule (Get-NeoIPCInfectiousAgentReleaseFinding -Current $backported -Release @($script:Released, $later) -ChangelogRelease $changelog -PreparedVersion '0.1.0-alpha' -HasUnreleasedEntry $false) |
                Should -Be @('release-uid-changed')
        }

        It 'holds the list in full to a release outside its history that is no later line''s: <Name>' -ForEach @(
            @{ Name = 'an earlier line''s maintenance release, seen from main'; Version = '0.1.1-alpha'; Prepared = '0.2.0-alpha' }
            @{ Name = 'a release of its own line on a commit it never took'; Version = '0.2.1-alpha'; Prepared = '0.2.0-alpha' }
            @{ Name = 'any release where the VERSION file names no version'; Version = '0.2.0-alpha'; Prepared = 'next' }
        ) {
            # The release outside the history added Id 12, which the list lacks.
            $outside = [pscustomobject]@{
                Tag = "infectious-agents-v$Version"; Version = $Version; InHistory = $false
                Concepts = ConvertTo-OrdinalMap @{ 10 = 'Staphylococcus'; 11 = 'Micrococcus'; 12 = 'Kocuria' }
                Uids = ConvertTo-OrdinalMap @{ 10 = 'a1234567890' }
            }
            $changelog = @([pscustomobject]@{ Version = $Version; Heading = "[$Version] - 2026-11-20"; Line = 3 }) + $script:Changelog
            $kept = [pscustomobject]@{ Concepts = ConvertTo-OrdinalMap @{ 10 = 'Staphylococcus'; 11 = 'Micrococcus'; 13 = 'Rothia' }; Uids = ConvertTo-OrdinalMap @{ 10 = 'a1234567890' } }
            Get-Rule (Get-NeoIPCInfectiousAgentReleaseFinding -Current $kept -Release @($script:Released, $outside) -ChangelogRelease $changelog -PreparedVersion $Prepared -HasUnreleasedEntry $false) |
                Should -Be @('release-id-removed')
        }

        It 'reports <Rule> for <Defect>' -ForEach @(
            @{ Defect = 'a released Id that is gone'; Rule = 'release-id-removed'; Concepts = @{ 10 = 'Staphylococcus' }; Uids = @{ 10 = 'a1234567890' } }
            @{ Defect = 'a released Id renamed'; Rule = 'release-name-changed'; Concepts = @{ 10 = 'Staphylococcus'; 11 = 'Micrococcus luteus' }; Uids = @{ 10 = 'a1234567890' } }
            @{ Defect = 'a released Id renamed in letter case alone'; Rule = 'release-name-changed'; Concepts = @{ 10 = 'Staphylococcus'; 11 = 'micrococcus' }; Uids = @{ 10 = 'a1234567890' } }
            @{ Defect = 'a released uid replaced'; Rule = 'release-uid-changed'; Concepts = @{ 10 = 'Staphylococcus'; 11 = 'Micrococcus' }; Uids = @{ 10 = 'b1234567890' } }
            @{ Defect = 'a released uid changed in letter case alone'; Rule = 'release-uid-changed'; Concepts = @{ 10 = 'Staphylococcus'; 11 = 'Micrococcus' }; Uids = @{ 10 = 'A1234567890' } }
            @{ Defect = 'a released uid gone from the sidecar'; Rule = 'release-uid-changed'; Concepts = @{ 10 = 'Staphylococcus'; 11 = 'Micrococcus' }; Uids = @{} }
            @{ Defect = 'a new Id below a released one'; Rule = 'release-id-reused'; Concepts = @{ 5 = 'Kocuria'; 10 = 'Staphylococcus'; 11 = 'Micrococcus' }; Uids = @{ 10 = 'a1234567890' } }
        ) {
            $current = [pscustomobject]@{ Concepts = ConvertTo-OrdinalMap $Concepts; Uids = ConvertTo-OrdinalMap $Uids }
            Get-Rule (Get-NeoIPCInfectiousAgentReleaseFinding -Current $current -Release @($script:Released) -ChangelogRelease $script:Changelog -PreparedVersion '0.1.0-alpha' -HasUnreleasedEntry $false) | Should -Be @($Rule)
        }

        It 'reports <Rule> once, however many releases carried the Id' -ForEach @(
            @{ Rule = 'release-id-removed'; Concepts = @{ 10 = 'Staphylococcus' } }
            @{ Rule = 'release-name-changed'; Concepts = @{ 10 = 'Staphylococcus'; 11 = 'Micrococcus luteus' } }
        ) {
            # The first release, as its tag predates the UID sidecar, without UIDs.
            $first = [pscustomobject]@{
                Tag = 'infectious-agents-v0.0.1-alpha'; Version = '0.0.1-alpha'
                Concepts = ConvertTo-OrdinalMap @{ 10 = 'Staphylococcus'; 11 = 'Micrococcus' }; Uids = ConvertTo-OrdinalMap @{}
            }
            $changelog = $script:Changelog + @([pscustomobject]@{ Version = '0.0.1-alpha'; Heading = '[0.0.1-alpha] - 2026-07-07'; Line = 9 })
            $currentList = [pscustomobject]@{ Concepts = ConvertTo-OrdinalMap $Concepts; Uids = ConvertTo-OrdinalMap @{ 10 = 'a1234567890' } }
            Get-Rule (Get-NeoIPCInfectiousAgentReleaseFinding -Current $currentList -Release @($first, $script:Released) -ChangelogRelease $changelog -PreparedVersion '0.1.0-alpha' -HasUnreleasedEntry $false) |
                Should -Be @($Rule)
        }

        It 'fails closed when no release tag is present' {
            $current = [pscustomobject]@{ Concepts = ConvertTo-OrdinalMap @{ 10 = 'Staphylococcus' }; Uids = ConvertTo-OrdinalMap @{} }
            Get-Rule (Get-NeoIPCInfectiousAgentReleaseFinding -Current $current -Release @() -ChangelogRelease $script:Changelog -PreparedVersion '0.1.0-alpha' -HasUnreleasedEntry $false) | Should -Be @('release-tags')
        }

        It 'fails closed when the tag of a release the CHANGELOG records is missing' {
            $current = [pscustomobject]@{ Concepts = ConvertTo-OrdinalMap @{ 10 = 'Staphylococcus'; 11 = 'Micrococcus' }; Uids = ConvertTo-OrdinalMap @{ 10 = 'a1234567890' } }
            $changelog = @([pscustomobject]@{ Version = '0.1.0-alpha'; Heading = '[0.1.0-alpha] - 2026-09-07'; Line = 5 }, [pscustomobject]@{ Version = '0.0.1-alpha'; Heading = '[0.0.1-alpha] - 2026-07-07'; Line = 9 })
            Get-Rule (Get-NeoIPCInfectiousAgentReleaseFinding -Current $current -Release @($script:Released) -ChangelogRelease $changelog -PreparedVersion '0.1.0-alpha' -HasUnreleasedEntry $false) | Should -Be @('release-tags')
        }

        It 'needs no tag yet for the release being prepared, which its VERSION file names while [Unreleased] lists no change' {
            $current = [pscustomobject]@{ Concepts = ConvertTo-OrdinalMap @{ 10 = 'Staphylococcus'; 11 = 'Micrococcus'; 12 = 'Kocuria' }; Uids = ConvertTo-OrdinalMap @{ 10 = 'a1234567890' } }
            $changelog = @([pscustomobject]@{ Version = '0.2.0-alpha'; Heading = '[0.2.0-alpha] - 2026-11-13'; Line = 3 }) + $script:Changelog
            @(Get-NeoIPCInfectiousAgentReleaseFinding -Current $current -Release @($script:Released) -ChangelogRelease $changelog -PreparedVersion '0.2.0-alpha' -HasUnreleasedEntry $false) | Should -BeNullOrEmpty
            Get-Rule (Get-NeoIPCInfectiousAgentReleaseFinding -Current $current -Release @($script:Released) -ChangelogRelease $changelog -PreparedVersion '0.1.0-alpha' -HasUnreleasedEntry $false) | Should -Be @('release-tags')
            # Once [Unreleased] lists changes, the release VERSION names is no longer being prepared: its tag exists,
            # and a clone that lacks it must fetch it.
            $missing = @(Get-NeoIPCInfectiousAgentReleaseFinding -Current $current -Release @($script:Released) -ChangelogRelease $changelog -PreparedVersion '0.2.0-alpha' -HasUnreleasedEntry $true)
            Get-Rule $missing | Should -Be @('release-tags')
            $missing[0].Message | Should -BeLike '*VERSION file names it, but `[Unreleased`] lists changes*'
        }

        It 'reports a CHANGELOG heading that names no version instead of skipping it' {
            $current = [pscustomobject]@{ Concepts = ConvertTo-OrdinalMap @{ 10 = 'Staphylococcus'; 11 = 'Micrococcus' }; Uids = ConvertTo-OrdinalMap @{ 10 = 'a1234567890' } }
            $changelog = @([pscustomobject]@{ Version = $null; Heading = '0.0.9 - 2026-01-01'; Line = 12 }) + $script:Changelog
            Get-Rule (Get-NeoIPCInfectiousAgentReleaseFinding -Current $current -Release @($script:Released) -ChangelogRelease $changelog -PreparedVersion '0.1.0-alpha' -HasUnreleasedEntry $false) | Should -Be @('changelog-heading')
        }

        It 'reports a current list without its maps instead of throwing' {
            Get-Rule (Get-NeoIPCInfectiousAgentReleaseFinding -Current ([pscustomobject]@{ Concepts = ConvertTo-OrdinalMap @{} }) -Release @($script:Released) -ChangelogRelease $script:Changelog -PreparedVersion '0.1.0-alpha' -HasUnreleasedEntry $false) |
                Should -Be @('release-input')
        }
    }

    Describe 'Read-NeoIPCInfectiousAgentRelease' {
        It 'returns nothing in a repository without release tags' {
            $repository = Initialize-TestRepository -Name 'untagged' -Yaml $script:CleanYaml
            @(Read-NeoIPCInfectiousAgentRelease -RepositoryRoot $repository) | Should -BeNullOrEmpty
        }

        It "reads each tag's Ids, names and UIDs" {
            $repository = Initialize-TestRepository -Name 'tagged' -Yaml $script:CleanYaml
            Invoke-TestGit -Repository $repository -Argument 'tag', 'infectious-agents-v0.1.0-alpha'
            $release = @(Read-NeoIPCInfectiousAgentRelease -RepositoryRoot $repository)
            $release.Count | Should -Be 1
            $release[0].Version | Should -Be '0.1.0-alpha'
            $release[0].Concepts['11'] | Should -Be 'Micrococcus'
            $release[0].Concepts.Count | Should -Be 4
            $release[0].Uids['10'] | Should -Be 'a1234567890'
        }

        It "reads a name as UTF-8 whatever the console's code page" {
            $repository = Initialize-TestRepository -Name 'non-ascii' -Yaml ($script:CleanYaml.Replace('Name: Micrococcus', 'Name: Micrococcus Müller'))
            Invoke-TestGit -Repository $repository -Argument 'tag', 'infectious-agents-v0.1.0-alpha'
            $console = [Console]::OutputEncoding
            try {
                # PowerShell decodes a native command's output with the console's encoding, here code page 850.
                [Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding(850)
                $release = @(Read-NeoIPCInfectiousAgentRelease -RepositoryRoot $repository)
            }
            finally { [Console]::OutputEncoding = $console }
            $release[0].Concepts['11'] | Should -BeExactly 'Micrococcus Müller'
        }

        It 'reads a tag that predates the UID sidecar as a release without UIDs' {
            $repository = Initialize-TestRepository -Name 'no-sidecar' -Yaml $script:CleanYaml -WithoutSidecar
            Invoke-TestGit -Repository $repository -Argument 'tag', 'infectious-agents-v0.0.1-alpha'
            $release = @(Read-NeoIPCInfectiousAgentRelease -RepositoryRoot $repository)
            $release[0].Concepts.Count | Should -Be 4
            $release[0].Uids.Count | Should -Be 0
        }

        It 'tells the releases in the history of HEAD from those of a later line' {
            # 0.1.0 on main, a branch that maintains it, and 0.2.0, which adds an Id, on main.
            $repository = Initialize-TestRepository -Name 'lines' -Yaml $script:CleanYaml
            Invoke-TestGit -Repository $repository -Argument 'tag', 'infectious-agents-v0.1.0-alpha'
            Invoke-TestGit -Repository $repository -Argument 'branch', 'maintenance', 'infectious-agents-v0.1.0-alpha'
            $added = $script:CleanYaml -replace '(?m)^- Name: Viruses$', "- Id: 12`n  Name: Kocuria`n  ConceptType: Genus`n  ConceptSource: NeoIPC`n  ConceptId: 3`n- Name: Viruses"
            [System.IO.File]::WriteAllText((Join-Path $repository 'metadata/common/infectious-agents/NeoIPC-Infectious-Agents.yaml'), $added, [System.Text.UTF8Encoding]::new($false))
            Invoke-TestGit -Repository $repository -Argument 'commit', '-q', '-a', '-m', 'add'
            Invoke-TestGit -Repository $repository -Argument 'tag', 'infectious-agents-v0.2.0-alpha'
            Invoke-TestGit -Repository $repository -Argument 'switch', '-q', 'maintenance'
            $release = @(Read-NeoIPCInfectiousAgentRelease -RepositoryRoot $repository)
            @($release | ForEach-Object { "$($_.Version) $($_.InHistory)" }) | Should -Be @('0.1.0-alpha True', '0.2.0-alpha False')
            $release[1].Concepts['12'] | Should -Be 'Kocuria'
        }

        It 'counts every release as in the history of HEAD in a shallow clone, whose history cannot show it' {
            # A depth-1 clone with its tags, fetched at depth 1 too: the tagged commit lies beyond the shallow boundary
            # of HEAD, so for-each-ref --merged=HEAD lists no tag there.
            $origin = Initialize-TestRepository -Name 'deep' -Yaml $script:CleanYaml
            Invoke-TestGit -Repository $origin -Argument 'tag', 'infectious-agents-v0.1.0-alpha'
            Invoke-TestGit -Repository $origin -Argument 'commit', '-q', '--allow-empty', '-m', 'later'
            $clone = Join-Path $TestDrive 'shallow'
            Invoke-TestGit -Repository $TestDrive -Argument '-c', 'protocol.file.allow=always', 'clone', '-q', '--depth', '1', ([System.Uri]::new($origin).AbsoluteUri), $clone
            Invoke-TestGit -Repository $clone -Argument '-c', 'protocol.file.allow=always', 'fetch', '-q', '--depth', '1', 'origin', 'refs/tags/*:refs/tags/*'
            (Invoke-NeoIPCGitText -RepositoryRoot $clone -Argument 'for-each-ref', '--merged=HEAD', 'refs/tags/').Trim() | Should -BeNullOrEmpty -Because 'the fixture must cut the tag off from HEAD'
            @(Read-NeoIPCInfectiousAgentRelease -RepositoryRoot $clone | ForEach-Object { "$($_.Version) $($_.InHistory)" }) | Should -Be @('0.1.0-alpha True')
        }

        It 'reads the repository it names whatever repository GIT_DIR names, as git sets it for a hook' {
            $repository = Initialize-TestRepository -Name 'named' -Yaml $script:CleanYaml
            Invoke-TestGit -Repository $repository -Argument 'tag', 'infectious-agents-v0.1.0-alpha'
            $other = Initialize-TestRepository -Name 'other' -Yaml $script:CleanYaml
            $saved = [Environment]::GetEnvironmentVariable('GIT_DIR', 'Process')
            try {
                [Environment]::SetEnvironmentVariable('GIT_DIR', (Join-Path $other '.git'), 'Process')
                $release = @(Read-NeoIPCInfectiousAgentRelease -RepositoryRoot $repository)
            }
            finally {
                # Restored as the caller had it: removed, unless it was set.
                [Environment]::SetEnvironmentVariable('GIT_DIR', $(if ($null -eq $saved) { [NullString]::Value } else { $saved }), 'Process')
            }
            @($release | ForEach-Object { $_.Tag }) | Should -Be @('infectious-agents-v0.1.0-alpha')
        }
    }

    Describe 'Get-NeoIPCChangelogRelease' {
        It 'returns the releases, in every heading form Keep a Changelog writes, and leaves out Unreleased' {
            $path = Join-Path $TestDrive 'CHANGELOG.md'
            $text = "# Changelog`n`n## [Unreleased]`n`n## [0.3.0-alpha] - 2026-12-01 [YANKED]`n`n- Three.`n`n" +
                "## [0.2.0-alpha](https://example.org/2) - 2026-11-01`n`n- Two.`n`n[0.1.0-alpha] - 2026-09-07`n" +
                "-------------------------------`n`n- One.`n`n## 0.0.9 - 2026-01-01`n`n- None.`n`n[0.1.0-alpha]: https://example.org/1`n"
            [System.IO.File]::WriteAllText($path, $text, [System.Text.UTF8Encoding]::new($false))
            $releases = @(Get-NeoIPCChangelogRelease -Path $path)
            @($releases | ForEach-Object { [string]$_.Version }) | Should -Be @('0.3.0-alpha', '0.2.0-alpha', '0.1.0-alpha', '')
            $releases[3].Heading | Should -Be '0.0.9 - 2026-01-01'
        }

        It 'leaves out [Unreleased] in any letter case' {
            $path = Join-Path $TestDrive 'CHANGELOG-case.md'
            [System.IO.File]::WriteAllText($path, "# Changelog`n`n## [unreleased]`n`n## [0.1.0-alpha] - 2026-09-07`n`n- One.`n", [System.Text.UTF8Encoding]::new($false))
            @(Get-NeoIPCChangelogRelease -Path $path | ForEach-Object { $_.Version }) | Should -Be @('0.1.0-alpha')
        }
    }

    Describe 'Test-NeoIPCChangelogUnreleasedEntry' {
        It 'tells <Name>' -ForEach @(
            @{ Name = 'an empty [Unreleased], as at a release''s tag'; Unreleased = ''; Expected = $false }
            @{ Name = 'a change listed under a subheading'; Unreleased = "### Added`n`n- A check.`n`n"; Expected = $true }
            @{ Name = 'a change listed directly'; Unreleased = "- A check.`n`n"; Expected = $true }
            @{ Name = 'a subheading without a list'; Unreleased = "### Added`n`n"; Expected = $false }
            @{ Name = 'a change written as a paragraph'; Unreleased = "A check of the list.`n`n"; Expected = $true }
            @{ Name = 'a change in a table'; Unreleased = "| Kind | Change |`n| --- | --- |`n| Added | A check. |`n`n"; Expected = $true }
            @{ Name = 'a change in a block quote'; Unreleased = "> - A check.`n`n"; Expected = $true }
            @{ Name = 'an HTML comment alone'; Unreleased = "<!-- Nothing yet. -->`n`n"; Expected = $false }
            @{ Name = 'a link reference definition alone'; Unreleased = "[0.1.0-alpha]: https://example.org/1`n`n"; Expected = $false }
        ) {
            $path = Join-Path $TestDrive 'CHANGELOG-unreleased.md'
            $text = "# Changelog`n`n## [Unreleased]`n`n$Unreleased## [0.1.0-alpha] - 2026-09-07`n`n- One.`n"
            [System.IO.File]::WriteAllText($path, $text, [System.Text.UTF8Encoding]::new($false))
            Test-NeoIPCChangelogUnreleasedEntry -Path $path | Should -Be $Expected
        }
    }

    Describe 'Get-NeoIPCFrozenInfectiousAgentCsvFinding' {
        # NEOIPC-COMPAT(legacy-infectious-agent-csv): see Private/InfectiousAgentValidation.ps1.
        It 'reports a frozen CSV that is missing or changed' {
            $dir = Join-Path $TestDrive 'frozen'
            $null = New-Item -ItemType Directory -Path $dir -Force
            [System.IO.File]::WriteAllText((Join-Path $dir 'NeoIPC-Pathogen-Concepts.csv'), "changed`n", [System.Text.UTF8Encoding]::new($false))
            $findings = @(Get-NeoIPCFrozenInfectiousAgentCsvFinding -Directory $dir)
            Get-Rule $findings | Should -Be @('frozen-csv', 'frozen-csv')
            @($findings.Location) | Should -Be @('NeoIPC-Pathogen-Concepts.csv', 'NeoIPC-Pathogen-Synonyms.csv')
        }

        It 'reports a frozen CSV it cannot read instead of throwing' {
            $dir = Join-Path $TestDrive 'locked'
            $null = New-Item -ItemType Directory -Path $dir -Force
            foreach ($name in 'NeoIPC-Pathogen-Concepts.csv', 'NeoIPC-Pathogen-Synonyms.csv') {
                [System.IO.File]::WriteAllText((Join-Path $dir $name), "locked`n", [System.Text.UTF8Encoding]::new($false))
            }
            # A stream that shares nothing, which .NET enforces on Windows and, through flock, on Linux and macOS.
            $lock = [System.IO.File]::Open((Join-Path $dir 'NeoIPC-Pathogen-Concepts.csv'), 'Open', 'Read', 'None')
            try { $findings = @(Get-NeoIPCFrozenInfectiousAgentCsvFinding -Directory $dir) }
            finally { $lock.Dispose() }
            Get-Rule $findings | Should -Be @('frozen-csv', 'frozen-csv')
            $findings[0].Message | Should -BeLike '*cannot be read*'
        }

        It 'reports no directory instead of throwing' {
            Get-Rule (Get-NeoIPCFrozenInfectiousAgentCsvFinding -Directory '') | Should -Be @('frozen-csv')
            Get-Rule (Get-NeoIPCFrozenInfectiousAgentCsvFinding -Directory $null) | Should -Be @('frozen-csv')
        }
    }
}
