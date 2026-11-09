#Requires -Version 7.6

<#
.SYNOPSIS
    Tests of the public infectious-agent cmdlets (Public/InfectiousAgents.ps1).

.DESCRIPTION
    Add-NeoIPCInfectiousAgentUid is driven as its callers drive it, on a list and a UID sidecar in TestDrive, and
    New-NeoIPCPathogenOptionSet is shown taking every option UID it draws. The UID draw itself, New-NeoIPCRandomUid,
    is replaced in one test only, to force the collisions the retry exists for: a drawn UID meets a taken one with a
    chance of about 1 in 10^16, so no caller can provoke one. A change to the sidecar while a call waits for its
    confirmation comes from the scripted host (ScriptedHost.ps1), which writes or deletes the file when it is asked, as
    another run, an editor, or git would. Get-NeoIPCInfectiousAgentCodeSet and Export-NeoIPCInfectiousAgentCodeSet are
    called through the module's exports, as their callers call them, on small lists in TestDrive, whose sets differ
    from category to category, each with a classification beside it, and on the committed list and classification,
    against the functions the generators expand from and a walk of the two files.

    The tests of Add-NeoIPCInfectiousAgentUid reach internals through InModuleScope; the Import-Module at file top runs
    during Pester's discovery phase, which InModuleScope requires.

.EXAMPLE
    Invoke-Pester -Path scripts/modules/NeoIPC-Tools/Tests/InfectiousAgents.Tests.ps1
#>

Import-Module (Join-Path $PSScriptRoot '..') -Force

InModuleScope 'NeoIPC-Tools' {

    Describe 'Add-NeoIPCInfectiousAgentUid' {
        BeforeAll {
            # The not-listed option, a genus with a synonym, and a genus whose Id sorts first numerically but not as
            # text.
            $script:Yaml = @'
Hierarchies:
- Id: 0
  Name: Not listed
- Name: Bacteria
  Children:
  - Id: 10
    Name: Staphylococcus
    Synonyms:
    - Id: 11
      Name: Micrococcus
  - Id: 2
    Name: Kocuria
'@

            function New-TestList {
                # A directory in TestDrive holding the list and, where given, its sidecar's text.
                param([Parameter(Mandatory)][string]$Name, [string]$Sidecar)
                $directory = Join-Path $TestDrive $Name
                $null = New-Item -ItemType Directory -Path $directory -Force
                [System.IO.File]::WriteAllText((Join-Path $directory 'NeoIPC-Infectious-Agents.yaml'), $script:Yaml, [System.Text.UTF8Encoding]::new($false))
                if ($PSBoundParameters.ContainsKey('Sidecar')) {
                    [System.IO.File]::WriteAllText((Join-Path $directory 'NeoIPC-Infectious-Agents.uids.csv'), $Sidecar, [System.Text.UTF8Encoding]::new($false))
                }
                $directory
            }

            . (Join-Path (Join-Path (Get-Module NeoIPC-Tools).ModuleBase 'Tests') 'ScriptedHost.ps1')

            function Invoke-ConfirmedUidAdd {
                # Runs Add-NeoIPCInfectiousAgentUid -Confirm on the list in Directory, in a runspace of the scripted
                # host, which answers Yes after doing what another run, an editor, or git might do while the call
                # waits: writing Theirs as the sidecar, or deleting it. With Relative, the call names both files by
                # relative paths from the list's directory, which the process's directory is not. Returns the prompts
                # and what the call returned or threw.
                param([Parameter(Mandatory)][string]$Directory, [string]$Theirs, [switch]$Delete, [switch]$Relative)
                $sidecarPath = Join-Path $Directory 'NeoIPC-Infectious-Agents.uids.csv'
                $scriptedHost = [NeoIPCTests.ScriptedHost]::new()
                $scriptedHost.ScriptedUI.Answers.Enqueue('Yes')
                if ($Delete) { $scriptedHost.ScriptedUI.DeleteOnPromptPath = $sidecarPath }
                else {
                    $scriptedHost.ScriptedUI.WriteOnPromptPath = $sidecarPath
                    $scriptedHost.ScriptedUI.WriteOnPromptText = $Theirs
                }
                $runspace = [runspacefactory]::CreateRunspace($scriptedHost)
                $runspace.Open()
                $ps = [powershell]::Create()
                try {
                    $ps.Runspace = $runspace
                    $quote = { param([string]$Text) "'$($Text.Replace("'", "''"))'" }
                    $manifest = Join-Path (Get-Module NeoIPC-Tools).ModuleBase 'NeoIPC-Tools.psd1'
                    $call = if ($Relative) {
                        "Set-Location -LiteralPath $(& $quote $Directory); Add-NeoIPCInfectiousAgentUid -Path ./NeoIPC-Infectious-Agents.yaml -UidSidecarPath ./NeoIPC-Infectious-Agents.uids.csv -Confirm"
                    }
                    else { "Add-NeoIPCInfectiousAgentUid -Path $(& $quote (Join-Path $Directory 'NeoIPC-Infectious-Agents.yaml')) -Confirm" }
                    $null = $ps.AddScript(@"
Import-Module $(& $quote $manifest) -Force
try { $call } catch { `$_.Exception.Message }
"@)
                    $output = @($ps.Invoke())
                    [pscustomobject]@{ Prompts = @($scriptedHost.ScriptedUI.Prompts); Output = $output }
                }
                finally {
                    $ps.Dispose()
                    $runspace.Dispose()
                }
            }
        }

        It 'draws a UID for each Id without a row, keeps the rows there, and writes the sidecar sorted, as LF without a BOM' {
            $directory = New-TestList -Name 'partial' -Sidecar "id,uid`n10,a1234567890`n"
            $added = @(Add-NeoIPCInfectiousAgentUid -Path (Join-Path $directory 'NeoIPC-Infectious-Agents.yaml'))
            @($added.Id) | Should -Be @(0, 2, 11)
            @($added.Uid | Sort-Object -Unique -CaseSensitive).Count | Should -Be 3
            $bytes = [System.IO.File]::ReadAllBytes((Join-Path $directory 'NeoIPC-Infectious-Agents.uids.csv'))
            $bytes[0] | Should -Not -Be 0xEF -Because 'the sidecar carries no byte order mark'
            $text = [System.Text.UTF8Encoding]::new($false).GetString($bytes)
            $text | Should -Not -Match "`r"
            $text | Should -BeLike "*`n" -Because 'the sidecar ends with a line break'
            $lines = $text.TrimEnd("`n").Split("`n")
            $lines[0] | Should -BeExactly 'id,uid'
            @($lines | Select-Object -Skip 1 | ForEach-Object { $_.Split(',')[0] }) | Should -Be @('0', '2', '10', '11')
            $lines | Should -Contain '10,a1234567890'
            foreach ($row in $added) {
                $row.Uid | Should -MatchExactly '\A[A-Za-z][A-Za-z0-9]{10}\z'
                $lines | Should -Contain "$($row.Id),$($row.Uid)"
            }
        }

        It 'draws anew each time, deriving nothing from the Id' {
            $first = @(Add-NeoIPCInfectiousAgentUid -Path (Join-Path (New-TestList -Name 'first' -Sidecar "id,uid`n") 'NeoIPC-Infectious-Agents.yaml'))
            $second = @(Add-NeoIPCInfectiousAgentUid -Path (Join-Path (New-TestList -Name 'second' -Sidecar "id,uid`n") 'NeoIPC-Infectious-Agents.yaml'))
            ($first.Uid -join ',') | Should -Not -Be ($second.Uid -join ',')
        }

        It 'draws again where the UID drawn is taken already, by a row or by the option set' {
            $script:Draws = [System.Collections.Generic.Queue[string]]::new([string[]]@('a1234567890', $script:NeoIPCPathogenOptionSetUid, 'b1234567890', 'c1234567890', 'd1234567890', 'e1234567890'))
            Mock New-NeoIPCRandomUid { $script:Draws.Dequeue() }
            $directory = New-TestList -Name 'collision' -Sidecar "id,uid`n10,a1234567890`n"
            $added = @(Add-NeoIPCInfectiousAgentUid -Path (Join-Path $directory 'NeoIPC-Infectious-Agents.yaml'))
            @($added | ForEach-Object { "$($_.Id),$($_.Uid)" }) | Should -Be @('0,b1234567890', '2,c1234567890', '11,d1234567890')
        }

        It 'adds nothing, and leaves the sidecar as it is, when every Id has a row' {
            # CRLF, and in text order rather than numeric order, so that a rewrite would change its bytes.
            $sidecar = "id,uid`r`n0,a1234567890`r`n10,c1234567890`r`n11,d1234567890`r`n2,b1234567890`r`n"
            $directory = New-TestList -Name 'complete' -Sidecar $sidecar
            @(Add-NeoIPCInfectiousAgentUid -Path (Join-Path $directory 'NeoIPC-Infectious-Agents.yaml')) | Should -BeNullOrEmpty
            [System.IO.File]::ReadAllText((Join-Path $directory 'NeoIPC-Infectious-Agents.uids.csv')) | Should -BeExactly $sidecar
        }

        It 'creates the sidecar where none exists' {
            $directory = New-TestList -Name 'none'
            @(Add-NeoIPCInfectiousAgentUid -Path (Join-Path $directory 'NeoIPC-Infectious-Agents.yaml')).Count | Should -Be 4
            Test-Path -LiteralPath (Join-Path $directory 'NeoIPC-Infectious-Agents.uids.csv') -PathType Leaf | Should -BeTrue
        }

        It 'refuses a sidecar with a row whose id is no Id, and writes nothing' {
            $sidecar = "id,uid`n10,a1234567890`nabc,b1234567890`n"
            $directory = New-TestList -Name 'odd-id' -Sidecar $sidecar
            { Add-NeoIPCInfectiousAgentUid -Path (Join-Path $directory 'NeoIPC-Infectious-Agents.yaml') } | Should -Throw "*rows whose id is no Id: abc.*"
            [System.IO.File]::ReadAllText((Join-Path $directory 'NeoIPC-Infectious-Agents.uids.csv')) | Should -BeExactly $sidecar
        }

        # The sidecar is written back unquoted, so a UID quoted around a line break would come back as a valid one.
        It 'refuses a sidecar with a row whose UID is no DHIS2 UID, <Case>, and writes nothing' -ForEach @(
            @{ Case = 'one quoted around a line break'; Directory = 'quoted-line-break'; Row = "10,`"a1234567890`n`"" }
            @{ Case = 'one too short'; Directory = 'short'; Row = '10,a123456789' }
            @{ Case = 'one that starts with a digit'; Directory = 'digit-first'; Row = '10,1a234567890' }
            @{ Case = 'an empty one'; Directory = 'empty'; Row = '10,' }
        ) {
            $sidecar = "id,uid`n$Row`n"
            $directory = New-TestList -Name "malformed-$Directory" -Sidecar $sidecar
            { Add-NeoIPCInfectiousAgentUid -Path (Join-Path $directory 'NeoIPC-Infectious-Agents.yaml') } |
                Should -Throw "*rows whose UID is no DHIS2 UID, for the Ids 10: restore each from the sidecar's history*only a row that never held a valid UID may go, for this call to draw one."
            [System.IO.File]::ReadAllText((Join-Path $directory 'NeoIPC-Infectious-Agents.uids.csv')) | Should -BeExactly $sidecar
        }

        It 'writes nothing when the sidecar <Case> while the call waits for its confirmation, and keeps that change' -ForEach @(
            # Another run adds the row of the Id 0 while this one waits at -Confirm with the sidecar it read.
            @{ Case = 'changes'; Directory = 'changed'; Sidecar = "id,uid`n10,a1234567890`n"; Theirs = "id,uid`n0,z1234567890`n10,a1234567890`n"; Delete = $false }
            # Another run creates the sidecar this one found absent.
            @{ Case = 'appears'; Directory = 'appeared'; Sidecar = $null; Theirs = "id,uid`n0,z1234567890`n"; Delete = $false }
            # git or a person deletes it.
            @{ Case = 'disappears'; Directory = 'disappeared'; Sidecar = "id,uid`n10,a1234567890`n"; Theirs = $null; Delete = $true }
        ) {
            $directory = if ($null -ne $Sidecar) { New-TestList -Name $Directory -Sidecar $Sidecar } else { New-TestList -Name $Directory }
            $sidecarPath = Join-Path $directory 'NeoIPC-Infectious-Agents.uids.csv'
            $result = Invoke-ConfirmedUidAdd -Directory $directory -Theirs $Theirs -Delete:$Delete
            @($result.Prompts).Count | Should -Be 1
            @($result.Output | Where-Object { "$_" -like '*changed since the call read it, so nothing is written*' }).Count | Should -Be 1
            $left = if (Test-Path -LiteralPath $sidecarPath) { [System.IO.File]::ReadAllText($sidecarPath) } else { $null }
            $left | Should -BeExactly $Theirs
        }

        It 'tells a change to the sidecar a relative path names, against the current location' {
            # .NET resolves a relative path against the process's directory, which Set-Location leaves where it is, so
            # a check reading through .NET would read another file there, or none at both reads, and miss the change.
            $directory = New-TestList -Name 'relative-changed' -Sidecar "id,uid`n10,a1234567890`n"
            $theirs = "id,uid`n0,z1234567890`n10,a1234567890`n"
            $result = Invoke-ConfirmedUidAdd -Directory $directory -Theirs $theirs -Relative
            @($result.Output | Where-Object { "$_" -like '*changed since the call read it, so nothing is written*' }).Count | Should -Be 1
            [System.IO.File]::ReadAllText((Join-Path $directory 'NeoIPC-Infectious-Agents.uids.csv')) | Should -BeExactly $theirs
        }

        It 'reads and writes the sidecar a relative path names, against the current location' {
            $directory = New-TestList -Name 'relative' -Sidecar "id,uid`n10,a1234567890`n"
            Push-Location -LiteralPath $directory
            try { $added = @(Add-NeoIPCInfectiousAgentUid -Path './NeoIPC-Infectious-Agents.yaml' -UidSidecarPath './NeoIPC-Infectious-Agents.uids.csv') }
            finally { Pop-Location }
            @($added.Id) | Should -Be @(0, 2, 11)
            [System.IO.File]::ReadAllText((Join-Path $directory 'NeoIPC-Infectious-Agents.uids.csv')) |
                Should -BeExactly "id,uid`n0,$($added[0].Uid)`n2,$($added[1].Uid)`n10,a1234567890`n11,$($added[2].Uid)`n"
        }

        It 'reads and writes the sidecar beside a list on a PowerShell drive' {
            $directory = New-TestList -Name 'drive' -Sidecar "id,uid`n10,a1234567890`n"
            $null = New-PSDrive -Name NeoIPCTestList -PSProvider FileSystem -Root $directory -Scope Global
            try { $added = @(Add-NeoIPCInfectiousAgentUid -Path 'NeoIPCTestList:\NeoIPC-Infectious-Agents.yaml') }
            finally { Remove-PSDrive -Name NeoIPCTestList -Scope Global }
            @($added.Id) | Should -Be @(0, 2, 11)
            [System.IO.File]::ReadAllText((Join-Path $directory 'NeoIPC-Infectious-Agents.uids.csv')) |
                Should -BeExactly "id,uid`n0,$($added[0].Uid)`n2,$($added[1].Uid)`n10,a1234567890`n11,$($added[2].Uid)`n"
        }

        It 'refuses a sidecar on a drive of a provider other than the file system, and writes nothing' {
            # The provider path of a variable is no file-system path: .NET would read it relative to the process's
            # directory, and PowerShell's cmdlets relative to the current location, here both the list's directory.
            $directory = New-TestList -Name 'variable-sidecar' -Sidecar "id,uid`n10,a1234567890`n"
            $processDirectory = [System.Environment]::CurrentDirectory
            [System.Environment]::CurrentDirectory = $directory
            Push-Location -LiteralPath $directory
            try {
                { Add-NeoIPCInfectiousAgentUid -Path (Join-Path $directory 'NeoIPC-Infectious-Agents.yaml') -UidSidecarPath 'Variable:\NeoIPCTestSidecar' } |
                    Should -Throw -ExpectedMessage "The sidecar 'Variable:\NeoIPCTestSidecar' is on a drive of the Variable provider, not in the file system*"
            }
            finally {
                Pop-Location
                [System.Environment]::CurrentDirectory = $processDirectory
            }
            @(Get-ChildItem -LiteralPath $directory -Name | Sort-Object) | Should -Be @('NeoIPC-Infectious-Agents.uids.csv', 'NeoIPC-Infectious-Agents.yaml')
        }

        It 'ends at a <Case> it refuses, writing nothing, under the caller''s SilentlyContinue' -ForEach @(
            @{ Case = 'sidecar on a drive of another provider'; Name = 'silently-variable'; Sidecar = "id,uid`n10,a1234567890`n"; Named = 'Variable:\NeoIPCTestSidecar'; Message = "*The sidecar 'Variable:\NeoIPCTestSidecar' is on a drive of the Variable provider*" }
            @{ Case = 'sidecar row whose id is no Id'; Name = 'silently-odd'; Sidecar = "id,uid`nfoo,a1234567890`n"; Named = 'none'; Message = '*has rows whose id is no Id: foo*' }
        ) {
            # In a process of its own, whose global preference the module's functions see: inside Pester's own try, the
            # first error ends the call whatever the cmdlet does. The child works in the list's directory, where a
            # dropped refusal would have written the sidecar or the variable's name; NormalView prints the message on
            # one line.
            $directory = New-TestList -Name $Name -Sidecar $Sidecar
            $before = [System.IO.File]::ReadAllText((Join-Path $directory 'NeoIPC-Infectious-Agents.uids.csv'))
            $caller = Join-Path $TestDrive "$Name.ps1"
            $callerText = "param(`$Module, `$Directory, `$Named)`n`$PSStyle.OutputRendering = 'PlainText'`n`$ErrorView = 'NormalView'`n`$global:ErrorActionPreference = 'SilentlyContinue'`nImport-Module `$Module`nSet-Location -LiteralPath `$Directory`n[System.Environment]::CurrentDirectory = `$Directory`n`$arguments = @{ Path = (Join-Path `$Directory 'NeoIPC-Infectious-Agents.yaml') }`nif (`$Named -ne 'none') { `$arguments.UidSidecarPath = `$Named }`n`$added = @(Add-NeoIPCInfectiousAgentUid @arguments)`n""added `$(`$added.Count)""`n"
            [System.IO.File]::WriteAllText($caller, $callerText, [System.Text.UTF8Encoding]::new($false))
            $module = Join-Path (Get-Module NeoIPC-Tools).ModuleBase 'NeoIPC-Tools.psd1'
            $said = @(& (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $caller -Module $module -Directory $directory -Named $Named 2>&1 | ForEach-Object { "$_" })
            ($said -join "`n") | Should -BeLike $Message
            $said | Should -Not -BeLike 'added*'
            @(Get-ChildItem -LiteralPath $directory -Name | Sort-Object) | Should -Be @('NeoIPC-Infectious-Agents.uids.csv', 'NeoIPC-Infectious-Agents.yaml')
            [System.IO.File]::ReadAllText((Join-Path $directory 'NeoIPC-Infectious-Agents.uids.csv')) | Should -BeExactly $before
        }

        It 'writes nothing with WhatIf' {
            $directory = New-TestList -Name 'what-if' -Sidecar "id,uid`n"
            @(Add-NeoIPCInfectiousAgentUid -Path (Join-Path $directory 'NeoIPC-Infectious-Agents.yaml') -WhatIf) | Should -BeNullOrEmpty
            [System.IO.File]::ReadAllText((Join-Path $directory 'NeoIPC-Infectious-Agents.uids.csv')) | Should -BeExactly "id,uid`n"
        }

        It 'gives the option generator the UID of every option, which it refuses to derive' {
            $directory = New-TestList -Name 'generated' -Sidecar "id,uid`n"
            $yaml = Join-Path $directory 'NeoIPC-Infectious-Agents.yaml'
            { New-NeoIPCPathogenOptionSet -Path $yaml } | Should -Throw '*4 option code(s) have no UID in the sidecar*: 0, 2, 10, 11.*'
            $added = @(Add-NeoIPCInfectiousAgentUid -Path $yaml)
            $options = (New-NeoIPCPathogenOptionSet -Path $yaml)['options']
            @($options | ForEach-Object { "$($_['code']),$($_['id'])" } | Sort-Object) | Should -Be @($added | ForEach-Object { "$($_.Id),$($_.Uid)" } | Sort-Object)
        }
    }
}

# The code-set cmdlets are called as their callers call them, through the module's exports; the generators' own
# functions, the reference on the committed list, are reached through the module's scope.
Describe 'Get-NeoIPCInfectiousAgentCodeSet and Export-NeoIPCInfectiousAgentCodeSet' {
    BeforeAll {
        Import-Module powershell-yaml -ErrorAction Stop

        # The not-listed option with every resistance flag, as the canonical list gives it; a genus whose flags flow
        # down to its species; a genus whose flags flow down to its species, which turns one off and adds another; a
        # genus whose flags reach its synonym and its species, which turns the common-commensal flag off and adds a
        # resistance flag; and a virus with a synonym. Each category's set differs from the others', and every set
        # comes out of the walk out of ascending order, so that the order the sets come in is the code's. Each node
        # names its record, by which the classification names it.
        $script:CodeSetYaml = @'
Hierarchies:
- Id: 0
  Name: Not listed
  ConceptSource: NeoIPC
  ConceptId: 1
  MRSA: true
  VRE: true
  3GCR: true
  Carbapenems: true
  Colistin: true
- Name: Bacteria
  ConceptSource: LPSN
  ConceptId: domain/bacteria
  Children:
  - Id: 60
    Name: Enterococcus
    ConceptSource: LPSN
    ConceptId: genus/enterococcus
    VRE: true
    Carbapenems: true
    Children:
    - Id: 11
      Name: Enterococcus faecium
      ConceptSource: LPSN
      ConceptId: species/enterococcus-faecium
  - Id: 50
    Name: Klebsiella
    ConceptSource: LPSN
    ConceptId: genus/klebsiella
    3GCR: true
    Carbapenems: true
    Children:
    - Id: 21
      Name: Klebsiella pneumoniae
      ConceptSource: LPSN
      ConceptId: species/klebsiella-pneumoniae
      Carbapenems: false
      Colistin: true
  - Id: 30
    Name: Staphylococcus
    ConceptSource: LPSN
    ConceptId: genus/staphylococcus
    CommonCommensal: true
    MRSA: true
    Synonyms:
    - Id: 25
      Name: Micrococcus
      ConceptSource: LPSN
      ConceptId: genus/micrococcus
    Children:
    - Id: 12
      Name: Staphylococcus aureus
      ConceptSource: LPSN
      ConceptId: species/staphylococcus-aureus
      CommonCommensal: false
      Colistin: true
- Name: Viruses
  ConceptSource: NeoIPC
  ConceptId: 100
  Children:
  - Id: 41
    Name: Influenza virus
    ConceptSource: ICTV
    ConceptId: 1
    Synonyms:
    - Id: 5
      Name: Flu virus
      ConceptSource: ICTV
      ConceptId: 2
'@
        # A classification of that list: the genera into two groups of bacteria, the viruses into a third by their
        # top-level node, and the bacteria's Gram reaction from the domain, overridden on two genera, and their oxygen
        # requirement from the domain alone.
        $script:CodeSetClassificationYaml = @'
Groups:
- Key: bacteria
  Name: Bacteria
  Evidence:
  - doi:10.5555/fixture
  Children:
  - Key: gram-positive-cocci
    Name: Gram-positive cocci
    EcdcCategory: Gram-positive cocci
    Evidence:
    - doi:10.5555/fixture
    Members:
    - Name: Enterococcus
      ConceptSource: LPSN
      ConceptId: genus/enterococcus
      Evidence:
      - doi:10.5555/fixture
    - Name: Staphylococcus
      ConceptSource: LPSN
      ConceptId: genus/staphylococcus
      Evidence:
      - doi:10.5555/fixture
  - Key: enterobacterales
    Name: Enterobacterales
    EcdcCategory: Enterobacterales
    Evidence:
    - doi:10.5555/fixture
    Members:
    - Name: Klebsiella
      ConceptSource: LPSN
      ConceptId: genus/klebsiella
      Evidence:
      - doi:10.5555/fixture
- Key: viruses
  Name: Viruses
  EcdcCategory: Viruses
  Evidence:
  - doi:10.5555/fixture
  Members:
  - Name: Viruses
    ConceptSource: NeoIPC
    ConceptId: 100
    Evidence:
    - doi:10.5555/fixture
Attributes:
- Key: gram-reaction
  Name: Gram reaction
  Values:
  - Key: positive
    Name: Positive
  - Key: negative
    Name: Negative
  Assignments:
  - Name: Bacteria
    ConceptSource: LPSN
    ConceptId: domain/bacteria
    Value: negative
    Evidence:
    - doi:10.5555/fixture
  - Name: Enterococcus
    ConceptSource: LPSN
    ConceptId: genus/enterococcus
    Value: positive
    Reason: Its cells stain Gram-positive.
    Evidence:
    - doi:10.5555/fixture
  - Name: Staphylococcus
    ConceptSource: LPSN
    ConceptId: genus/staphylococcus
    Value: positive
    Reason: Its cells stain Gram-positive.
    Evidence:
    - doi:10.5555/fixture
- Key: oxygen-requirement
  Name: Oxygen requirement
  Values:
  - Key: facultative-anaerobic
    Name: Facultative anaerobic
  - Key: aerobic
    Name: Aerobic
  Assignments:
  - Name: Bacteria
    ConceptSource: LPSN
    ConceptId: domain/bacteria
    Value: facultative-anaerobic
    Evidence:
    - doi:10.5555/fixture
'@
        # The sets of that list, in ascending order.
        $script:ExpectedSets = [ordered]@{ Concepts = @(0, 11, 12, 21, 30, 41, 50, 60); Synonyms = @(5, 25); CommonCommensals = @(25, 30); Viruses = @(5, 41) }
        $script:ExpectedCategories = [ordered]@{ '3GCR' = @(0, 21, 50); CARBR = @(0, 11, 50, 60); COLR = @(0, 12, 21); MRSA = @(0, 12, 25, 30); VRE = @(0, 11, 60) }
        # What the classification gives each Id, as Id|ReportingGroup|GramReaction|OxygenRequirement, <null> for
        # $null: nothing for the not-listed option, a synonym its concept's, a species its genus's, and no attribute
        # to the viruses. As text, the Ids would sort otherwise, 5 after 41, so the order expected is a numeric sort's.
        $script:ExpectedRows = @(
            '0|<null>|<null>|<null>'
            '5|viruses|<null>|<null>'
            '11|gram-positive-cocci|positive|facultative-anaerobic'
            '12|gram-positive-cocci|positive|facultative-anaerobic'
            '21|enterobacterales|negative|facultative-anaerobic'
            '25|gram-positive-cocci|positive|facultative-anaerobic'
            '30|gram-positive-cocci|positive|facultative-anaerobic'
            '41|viruses|<null>|<null>'
            '50|enterobacterales|negative|facultative-anaerobic'
            '60|gram-positive-cocci|positive|facultative-anaerobic'
        )
        $script:CanonicalDirectory = Join-Path (Get-Module NeoIPC-Tools).ModuleBase '..' '..' '..' 'metadata' 'common' 'infectious-agents'
        $script:CanonicalList = Join-Path $script:CanonicalDirectory 'NeoIPC-Infectious-Agents.yaml'
        $script:CanonicalClassification = Join-Path $script:CanonicalDirectory 'NeoIPC-Infectious-Agent-Reporting-Groups.yaml'

        function New-TestCodeSetList {
            # A directory in TestDrive holding the list and the classification beside it, each as UTF-8 without a byte
            # order mark and with LF line endings, or as the bytes given; with NoClassification, the list alone.
            param(
                [Parameter(Mandatory)][string]$Name,
                [string]$Yaml = $script:CodeSetYaml,
                [byte[]]$Byte,
                [string]$Classification = $script:CodeSetClassificationYaml,
                [byte[]]$ClassificationByte,
                [switch]$NoClassification
            )
            $directory = Join-Path $TestDrive $Name
            $null = New-Item -ItemType Directory -Path $directory -Force
            $path = Join-Path $directory 'NeoIPC-Infectious-Agents.yaml'
            if ($Byte) { [System.IO.File]::WriteAllBytes($path, $Byte) }
            else { [System.IO.File]::WriteAllText($path, $Yaml.Replace("`r`n", "`n"), [System.Text.UTF8Encoding]::new($false)) }
            if (-not $NoClassification) {
                $classificationPath = Join-Path $directory 'NeoIPC-Infectious-Agent-Reporting-Groups.yaml'
                if ($ClassificationByte) { [System.IO.File]::WriteAllBytes($classificationPath, $ClassificationByte) }
                else { [System.IO.File]::WriteAllText($classificationPath, $Classification.Replace("`r`n", "`n"), [System.Text.UTF8Encoding]::new($false)) }
            }
            $path
        }

        function Get-TestRow {
            # The rows of the code sets' Classification as Id|ReportingGroup|GramReaction|OxygenRequirement, in the
            # order they come, a $null field as <null>, so that it is told apart from an empty string, which a
            # consumer reading JSON null as NA would not take for a missing value.
            param([AllowNull()][object[]]$Row)
            @($Row | ForEach-Object {
                    @(@($_.Id, $_.ReportingGroup, $_.GramReaction, $_.OxygenRequirement) | ForEach-Object { if ($null -eq $_) { '<null>' } else { [string]$_ } }) -join '|'
                })
        }

        function Get-TestFileHash {
            # A file's SHA-256 in lower-case hexadecimal, the form the cmdlets give it in.
            param([Parameter(Mandatory)][string]$Path)
            (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
        }

        function Read-TestJson {
            # A JSON file the export wrote, as a hashtable.
            param([Parameter(Mandatory)][string]$Path)
            [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json -AsHashtable
        }
    }

    It 'returns the option codes and each set the rules enumerate, with the flags flowing down the tree and an explicit false overriding' {
        $sets = Get-NeoIPCInfectiousAgentCodeSet -Path (New-TestCodeSetList -Name 'sets')
        foreach ($set in $script:ExpectedSets.Keys) { @($sets.$set) | Should -Be $script:ExpectedSets[$set] -Because $set }
        @($sets.ResistanceCategories.PSObject.Properties.Name) | Should -Be @('3GCR', 'CARBR', 'COLR', 'MRSA', 'VRE')
        foreach ($category in $script:ExpectedCategories.Keys) {
            @($sets.ResistanceCategories.$category) | Should -Be $script:ExpectedCategories[$category] -Because $category
        }
    }

    It 'gives the SHA-256 of the bytes it read, in lower-case hexadecimal' {
        $path = New-TestCodeSetList -Name 'hash'
        (Get-NeoIPCInfectiousAgentCodeSet -Path $path).Sha256 | Should -BeExactly (Get-TestFileHash -Path $path)
    }

    It 'gives every Id, in ascending order, the group and the attribute values the classification beside the list gives it, a synonym through its concept and $null where it gives none' {
        $sets = Get-NeoIPCInfectiousAgentCodeSet -Path (New-TestCodeSetList -Name 'classification')
        Get-TestRow -Row $sets.Classification | Should -BeExactly $script:ExpectedRows
        @($sets.Classification[0].PSObject.Properties.Name) | Should -Be @('Id', 'ReportingGroup', 'GramReaction', 'OxygenRequirement')
        foreach ($row in $sets.Classification) { $row.Id | Should -BeOfType [int] }
    }

    It 'gives the SHA-256 of the classification it read, in lower-case hexadecimal' {
        $path = New-TestCodeSetList -Name 'classification-hash'
        (Get-NeoIPCInfectiousAgentCodeSet -Path $path).ClassificationSha256 |
            Should -BeExactly (Get-TestFileHash -Path (Join-Path (Split-Path -Parent $path) 'NeoIPC-Infectious-Agent-Reporting-Groups.yaml'))
    }

    It 'reads the classification -ClassificationPath names in place of the one beside the list' {
        $path = New-TestCodeSetList -Name 'classification-named'
        $other = Join-Path $TestDrive 'other-classification.yaml'
        [System.IO.File]::WriteAllText($other, $script:CodeSetClassificationYaml.Replace("`r`n", "`n").Replace('- Key: viruses', '- Key: viral-agents'), [System.Text.UTF8Encoding]::new($false))
        $sets = Get-NeoIPCInfectiousAgentCodeSet -Path $path -ClassificationPath $other
        Get-TestRow -Row $sets.Classification | Should -BeExactly @($script:ExpectedRows | ForEach-Object { $_.Replace('|viruses|', '|viral-agents|') })
        $sets.ClassificationSha256 | Should -BeExactly (Get-TestFileHash -Path $other)
    }

    It 'refuses a classification that does not exist, naming it and how it was chosen: <Case>' -ForEach @(
        @{ Case = 'none beside the list'; Named = $false; Message = "*NeoIPC-Infectious-Agent-Reporting-Groups.yaml', the one beside the list, which is read unless -ClassificationPath names another, does not exist*" }
        @{ Case = 'none where -ClassificationPath names one'; Named = $true; Message = "*missing.yaml', which -ClassificationPath names, does not exist*" }
    ) {
        $path = New-TestCodeSetList -Name "classification-missing-$Named" -NoClassification
        $arguments = @{ Path = $path }
        if ($Named) { $arguments.ClassificationPath = Join-Path $TestDrive 'missing.yaml' }
        { Get-NeoIPCInfectiousAgentCodeSet @arguments } | Should -Throw -ExpectedMessage $Message
    }

    It 'refuses a classification <Case>, naming the file' -ForEach @(
        @{ Case = 'that begins with a byte order mark'; Name = 'classification-bom'; Prefix = [byte[]](0xEF, 0xBB, 0xBF); Suffix = [byte[]]@(); Message = "The classification '*' begins with a byte order mark*" }
        @{ Case = 'that is not valid UTF-8'; Name = 'classification-invalid'; Prefix = [byte[]]@(); Suffix = [byte[]](0x23, 0x20, 0xFF, 0x0A); Message = "The classification '*' is not valid UTF-8*" }
    ) {
        $text = [System.Text.UTF8Encoding]::new($false).GetBytes($script:CodeSetClassificationYaml.Replace("`r`n", "`n"))
        $path = New-TestCodeSetList -Name $Name -ClassificationByte ([byte[]]($Prefix + $text + $Suffix))
        $classification = Join-Path (Split-Path -Parent $path) 'NeoIPC-Infectious-Agent-Reporting-Groups.yaml'
        { Get-NeoIPCInfectiousAgentCodeSet -Path $path } | Should -Throw -ExpectedMessage $Message
        { Get-NeoIPCInfectiousAgentCodeSet -Path $path } | Should -Throw -ExpectedMessage "*'$classification'*"
    }

    It 'refuses a file that is no reporting classification, naming it: <Case>' -ForEach @(
        @{ Case = 'an empty file'; Kind = 'empty' }
        @{ Case = 'a mapping of other keys'; Kind = 'other' }
        @{ Case = 'a mapping of Groups without Attributes'; Kind = 'no-attributes' }
        @{ Case = 'a mapping with no group'; Kind = 'no-group' }
        @{ Case = 'a mapping whose Groups hold no group'; Kind = 'no-group-mapping' }
        @{ Case = 'the list itself, which -ClassificationPath names'; Kind = 'list' }
    ) {
        # None holds anything for the checks to judge; read into rows, each would come back without groups, without the
        # attributes' columns, or not at all.
        $classification = $script:CodeSetClassificationYaml.Replace("`r`n", "`n")
        $attributes = $classification.IndexOf("`nAttributes:") + 1
        $text = switch ($Kind) {
            'empty' { '' }
            'other' { "Foo: bar`n" }
            'no-attributes' { $classification.Substring(0, $attributes) }
            'no-group' { "Groups: []`n" + $classification.Substring($attributes) }
            'no-group-mapping' { "Groups: [foo]`n" + $classification.Substring($attributes) }
            default { $classification }
        }
        $path = New-TestCodeSetList -Name "not-classification-$Kind" -Classification $text
        $arguments = @{ Path = $path }
        $file = Join-Path (Split-Path -Parent $path) 'NeoIPC-Infectious-Agent-Reporting-Groups.yaml'
        if ($Kind -eq 'list') {
            $arguments.ClassificationPath = $path
            $file = $path
        }
        { Get-NeoIPCInfectiousAgentCodeSet @arguments } | Should -Throw -ExpectedMessage "The classification '$file' is no reporting classification*"
    }

    It 'refuses a <Noun> that is not valid YAML, naming the file and where its parser stopped: <Case>' -ForEach @(
        @{ Noun = 'list'; Case = 'an unclosed sequence'; Appended = "`nbroken: [`n"; Message = '*did not find expected node content*' }
        @{ Noun = 'classification'; Case = 'an unclosed sequence'; Appended = "`nbroken: [`n"; Message = '*did not find expected node content*' }
        @{ Noun = 'classification'; Case = 'a repeated key'; Appended = "`nGroups: []`n"; Message = '*Duplicate key*' }
    ) {
        $source = if ($Noun -eq 'list') { $script:CodeSetYaml } else { $script:CodeSetClassificationYaml }
        $text = $source.Replace("`r`n", "`n") + $Appended
        $arguments = @{ Name = "yaml-$Noun-$($Appended.Length)" }
        if ($Noun -eq 'list') { $arguments.Yaml = $text } else { $arguments.Classification = $text }
        $path = New-TestCodeSetList @arguments
        $file = if ($Noun -eq 'list') { $path } else { Join-Path (Split-Path -Parent $path) 'NeoIPC-Infectious-Agent-Reporting-Groups.yaml' }
        # The parser stops at the end of the file for an unclosed sequence, past the file's last line, and for a
        # repeated key at the line of that key, here the text's last line, whose number is the count of its line feeds.
        $where = if ($Case -eq 'a repeated key') { "at line $(@($text -split "`n").Count - 1), column 1" } else { 'at the end of the file' }
        $thrown = { Get-NeoIPCInfectiousAgentCodeSet -Path $path } |
            Should -Throw -ExpectedMessage "The $Noun '$file' is not valid YAML ${where}: $Message" -PassThru
        $thrown.Exception.Message | Should -Not -BeLike '*Load*' -Because 'the parser''s message is given without the wrapper PowerShell puts around it'
    }

    It 'refuses a path that names a directory, saying so: <Case>' -ForEach @(
        @{ Case = 'the list'; Cmdlet = 'Get'; Named = 'Path' }
        @{ Case = 'the list, to the export'; Cmdlet = 'Export'; Named = 'Path' }
        @{ Case = 'the classification'; Cmdlet = 'Get'; Named = 'ClassificationPath' }
    ) {
        # The directory sits where no classification lies beside it, so that the export's own check, not a later one,
        # is what names the list.
        $path = New-TestCodeSetList -Name "directory-$Cmdlet-$Named"
        $directory = Join-Path $TestDrive "a-directory-$Cmdlet-$Named"
        $null = New-Item -ItemType Directory -Path $directory
        $arguments = @{ Path = $path }
        $arguments[$Named] = $directory
        $message = if ($Named -eq 'Path') { "The list '$directory' is no file*" } else { "The classification '$directory', which -ClassificationPath names, is no file*" }
        if ($Cmdlet -eq 'Export') {
            $arguments.OutputPath = Join-Path $TestDrive "directory-$Cmdlet.json"
            { Export-NeoIPCInfectiousAgentCodeSet @arguments } | Should -Throw -ExpectedMessage $message
        }
        else { { Get-NeoIPCInfectiousAgentCodeSet @arguments } | Should -Throw -ExpectedMessage $message }
    }

    It 'refuses a classification it cannot read, naming the file' -Skip:((-not $IsWindows) -and ((& id -u) -eq '0')) {
        # Windows refuses a read of a file another handle holds without sharing; elsewhere a file without permissions
        # is refused to anyone but root, for whom this case cannot be made.
        $path = New-TestCodeSetList -Name 'classification-unreadable'
        $classification = Join-Path (Split-Path -Parent $path) 'NeoIPC-Infectious-Agent-Reporting-Groups.yaml'
        $lock = $null
        if ($IsWindows) { $lock = [System.IO.File]::Open($classification, 'Open', 'Read', 'None') }
        else { [System.IO.File]::SetUnixFileMode($classification, [System.IO.UnixFileMode]::None) }
        try {
            $thrown = { Get-NeoIPCInfectiousAgentCodeSet -Path $path } | Should -Throw -ExpectedMessage "The classification '$classification' cannot be read*" -PassThru
            $thrown.Exception.Message | Should -Not -BeLike '*ReadAllBytes*' -Because 'the reader''s message is given without the wrapper PowerShell puts around it'
        }
        finally {
            if ($lock) { $lock.Dispose() }
            else { [System.IO.File]::SetUnixFileMode($classification, [System.IO.UnixFileMode]'UserRead, UserWrite') }
        }
    }

    It 'gives no attribute value outside the bacteria, even where an assignment names a node there' {
        # An assignment outside the bacteria is the attribute checks' to report; the attributes apply to bacteria only.
        $assignment = "  - Name: Viruses`n    ConceptSource: NeoIPC`n    ConceptId: 100`n    Value: aerobic`n    Evidence:`n    - doi:10.5555/fixture`n"
        $classification = $script:CodeSetClassificationYaml.Replace("`r`n", "`n") + "`n" + $assignment
        $sets = Get-NeoIPCInfectiousAgentCodeSet -Path (New-TestCodeSetList -Name 'classification-outside' -Classification $classification)
        Get-TestRow -Row $sets.Classification | Should -BeExactly $script:ExpectedRows
    }

    It 'refuses an attribute whose Key, in PascalCase, names another property: <Case>' -ForEach @(
        @{ Case = 'the group'; Key = 'reporting-group'; Name = 'ReportingGroup' }
        @{ Case = 'the group, in another letter case'; Key = 'reportinggroup'; Name = 'Reportinggroup' }
        @{ Case = 'the Id'; Key = 'id'; Name = 'Id' }
        @{ Case = 'the Id, in another letter case'; Key = 'i-d'; Name = 'ID' }
        @{ Case = 'another attribute'; Key = 'gram-reaction'; Name = 'GramReaction' }
        @{ Case = 'another attribute, in another letter case'; Key = 'gramreaction'; Name = 'Gramreaction' }
    ) {
        $classification = $script:CodeSetClassificationYaml.Replace('- Key: oxygen-requirement', "- Key: $Key")
        $path = New-TestCodeSetList -Name "classification-clash-$Key" -Classification $classification
        { Get-NeoIPCInfectiousAgentCodeSet -Path $path } | Should -Throw -ExpectedMessage "*attribute '$Key' would be handed on as $Name, the name of another property*"
    }

    It 'refuses an attribute without a Key, naming the classification' {
        $classification = $script:CodeSetClassificationYaml.Replace("`r`n", "`n").Replace("- Key: oxygen-requirement`n  Name:", '- Name:')
        $path = New-TestCodeSetList -Name 'classification-keyless' -Classification $classification
        $file = Join-Path (Split-Path -Parent $path) 'NeoIPC-Infectious-Agent-Reporting-Groups.yaml'
        { Get-NeoIPCInfectiousAgentCodeSet -Path $path } | Should -Throw -ExpectedMessage "The classification '$file' cannot be read into rows: An attribute has no Key*"
    }

    It 'refuses an attribute that is no mapping, naming the classification and the attribute' {
        # Its column would otherwise vanish from every row unseen.
        $classification = $script:CodeSetClassificationYaml.Replace("`r`n", "`n") + "`n- oxygen`n"
        $path = New-TestCodeSetList -Name 'classification-attribute-scalar' -Classification $classification
        $file = Join-Path (Split-Path -Parent $path) 'NeoIPC-Infectious-Agent-Reporting-Groups.yaml'
        { Get-NeoIPCInfectiousAgentCodeSet -Path $path } |
            Should -Throw -ExpectedMessage "The classification '$file' cannot be read into rows: An attribute, 'oxygen', is no mapping with a Key to hand its values on under*"
    }

    It 'reads a classification without Attributes into rows without their columns, where its rows are read on their own' {
        # The cmdlets refuse such a file before its rows are read; the rows themselves refuse only an attribute that is
        # there and no mapping, such as the null item of Attributes: [~].
        $parameters = @{ List = $script:CodeSetYaml; Classification = $script:CodeSetClassificationYaml }
        InModuleScope 'NeoIPC-Tools' -Parameters $parameters {
            param($List, $Classification)
            Import-Module powershell-yaml -ErrorAction Stop
            $tree = $List | ConvertFrom-Yaml
            $parsed = $Classification | ConvertFrom-Yaml
            $parsed.Remove('Attributes')
            $rows = @(Get-NeoIPCInfectiousAgentClassificationRow -Classification $parsed -Tree $tree)
            $rows.Count | Should -BeGreaterThan 0
            @($rows | ForEach-Object { $_.PSObject.Properties.Name -join ',' } | Sort-Object -Unique) | Should -Be @('Id,ReportingGroup')
            $parsed['Attributes'] = [System.Collections.Generic.List[object]]::new()
            $parsed['Attributes'].Add($null)
            { Get-NeoIPCInfectiousAgentClassificationRow -Classification $parsed -Tree $tree } | Should -Throw -ExpectedMessage "An attribute, '', is no mapping*"
        }
    }

    It 'refuses an attribute whose Key gives its values no name to be handed on under: <Case>' -ForEach @(
        @{ Case = 'spaces'; Key = "'  '"; Refusal = "An attribute's Key, '  ', is no text with a word in it" }
        @{ Case = 'hyphens alone'; Key = "'- -'"; Refusal = "An attribute's Key, '- -', is no text with a word in it" }
        @{ Case = 'punctuation alone'; Key = "'!'"; Refusal = "An attribute's Key, '!', is no text with a word in it" }
        @{ Case = 'a number'; Key = '5'; Refusal = "An attribute's Key is a number, not a text with a word in it" }
        @{ Case = 'a Boolean'; Key = 'true'; Refusal = "An attribute's Key is a Boolean, not a text with a word in it" }
        @{ Case = 'a sequence'; Key = '[gram, reaction]'; Refusal = "An attribute's Key is a sequence, not a text with a word in it" }
        @{ Case = 'a mapping'; Key = '{gram: reaction}'; Refusal = "An attribute's Key is a mapping, not a text with a word in it" }
    ) {
        # A Key that is no text is named by its kind, since PowerShell would quote a sequence's items as if they were
        # one text.
        $classification = $script:CodeSetClassificationYaml.Replace('- Key: oxygen-requirement', "- Key: $Key")
        $path = New-TestCodeSetList -Name "classification-key-$($Case.Replace(' ', '-'))" -Classification $classification
        $file = Join-Path (Split-Path -Parent $path) 'NeoIPC-Infectious-Agent-Reporting-Groups.yaml'
        { Get-NeoIPCInfectiousAgentCodeSet -Path $path } |
            Should -Throw -ExpectedMessage "The classification '$file' cannot be read into rows: $Refusal to hand its values on under*"
    }

    It 'refuses an attribute whose Key, in PascalCase, is a name PowerShell reserves: <Key>' -ForEach @(
        @{ Key = 'ps-object'; Name = 'PsObject' }
        @{ Key = 'ps-type-names'; Name = 'PsTypeNames' }
        @{ Key = 'ps-type-name'; Name = 'PsTypeName' }
    ) {
        # PsTypeName holds no value of its own: a row cast from a dictionary takes it for the row's type name, so its
        # column would vanish from every row whose value is not $null.
        $classification = $script:CodeSetClassificationYaml.Replace('- Key: oxygen-requirement', "- Key: $Key")
        $path = New-TestCodeSetList -Name "classification-reserved-$Key" -Classification $classification
        { Get-NeoIPCInfectiousAgentCodeSet -Path $path } | Should -Throw -ExpectedMessage "*attribute '$Key' would be handed on as $Name, a name PowerShell reserves*"
    }

    It 'hands on $null, not an empty text, where <Case>' -ForEach @(
        @{ Case = 'an assignment has no Value'; Name = 'no-value'; From = "    ConceptId: domain/bacteria`n    Value: facultative-anaerobic`n"; To = "    ConceptId: domain/bacteria`n"; Given = '|facultative-anaerobic'; Handed = '|<null>'; Stray = $false }
        @{ Case = 'a group has no Key'; Name = 'no-key'; From = "  - Key: enterobacterales`n    Name: Enterobacterales`n"; To = "  - Name: Enterobacterales`n"; Given = '|enterobacterales|'; Handed = '|<null>|'; Stray = $false }
        @{ Case = 'a member of a group without a Key carries a Value of its own'; Name = 'stray-value'; From = "  - Key: enterobacterales`n    Name: Enterobacterales`n"; To = "  - Name: Enterobacterales`n"; Given = '|enterobacterales|'; Handed = '|<null>|'; Stray = $true }
    ) {
        # The classification's checks report each case; a consumer reading JSON null as NA would take an empty text for
        # a value, and a member's own Value for a group's Key.
        $classification = $script:CodeSetClassificationYaml.Replace("`r`n", "`n").Replace($From, $To)
        if ($Stray) { $classification = $classification.Replace("      ConceptId: genus/klebsiella`n", "      ConceptId: genus/klebsiella`n      Value: positive`n") }
        $sets = Get-NeoIPCInfectiousAgentCodeSet -Path (New-TestCodeSetList -Name "handed-null-$Name" -Classification $classification)
        Get-TestRow -Row $sets.Classification | Should -BeExactly @($script:ExpectedRows | ForEach-Object { $_.Replace($Given, $Handed) })
    }

    It 'gives each row the Id the list''s walker reads, so that the form of an Id is never laid at the classification''s door' {
        # A one-item sequence, which the list's checks report, is read by the walker as its item.
        $path = New-TestCodeSetList -Name 'id-form' -Yaml $script:CodeSetYaml.Replace('    - Id: 12', '    - Id: [12]')
        Get-TestRow -Row (Get-NeoIPCInfectiousAgentCodeSet -Path $path).Classification | Should -BeExactly $script:ExpectedRows
    }

    It 'gives $null where nothing reaches a node: a group to Klebsiella, an oxygen requirement to all but Klebsiella' {
        # A member that names no node, and an assignment moved below the domain, leave nodes unplaced, which the
        # classification's checks report; the rows hand on $null there rather than a default.
        $classification = $script:CodeSetClassificationYaml.Replace("`r`n", "`n")
        $classification = $classification.Replace("      ConceptId: genus/klebsiella`n", "      ConceptId: genus/unlisted`n")
        $classification = $classification.Replace("    ConceptId: domain/bacteria`n    Value: facultative-anaerobic", "    ConceptId: genus/klebsiella`n    Value: facultative-anaerobic")
        $sets = Get-NeoIPCInfectiousAgentCodeSet -Path (New-TestCodeSetList -Name 'classification-unreached' -Classification $classification)
        Get-TestRow -Row $sets.Classification | Should -BeExactly @(
            '0|<null>|<null>|<null>'
            '5|viruses|<null>|<null>'
            '11|gram-positive-cocci|positive|<null>'
            '12|gram-positive-cocci|positive|<null>'
            '21|<null>|negative|facultative-anaerobic'
            '25|gram-positive-cocci|positive|<null>'
            '30|gram-positive-cocci|positive|<null>'
            '41|viruses|<null>|<null>'
            '50|<null>|negative|facultative-anaerobic'
            '60|gram-positive-cocci|positive|<null>'
        )
    }

    It 'gives, on the committed files, every Id one row, a leaf group to every Id but 0 and 3561, and a value of each attribute from its vocabulary to every bacterium and no other node' {
        # The reference is walked here from the two files, independently of the resolution the cmdlet shares with the
        # classification's checks: the Ids under the top-level Bacteria, the leaf groups' Keys, and each attribute's
        # value Keys.
        $sets = Get-NeoIPCInfectiousAgentCodeSet
        $tree = [System.IO.File]::ReadAllText($script:CanonicalList) | ConvertFrom-Yaml
        $classification = [System.IO.File]::ReadAllText($script:CanonicalClassification) | ConvertFrom-Yaml
        $bacteria = [System.Collections.Generic.HashSet[int]]::new()
        $collect = {
            param($Node)
            foreach ($item in @($Node)) {
                if ($item -isnot [System.Collections.IDictionary]) { continue }
                if ($item.Contains('Id')) { [void]$bacteria.Add([int]$item['Id']) }
                foreach ($key in 'Synonyms', 'Children') { if ($item.Contains($key)) { & $collect $item[$key] } }
            }
        }
        & $collect @($tree['Hierarchies'] | Where-Object { $_['Name'] -ceq 'Bacteria' })
        $leaves = [System.Collections.Generic.HashSet[string]]::new()
        $collectLeaves = {
            param($Group)
            foreach ($item in @($Group)) {
                if ($item.Contains('Children')) { & $collectLeaves $item['Children'] } else { [void]$leaves.Add([string]$item['Key']) }
            }
        }
        & $collectLeaves $classification['Groups']
        $vocabulary = @{}
        foreach ($attribute in $classification['Attributes']) {
            $name = -join @([string]$attribute['Key'] -split '-' | ForEach-Object { $_.Substring(0, 1).ToUpperInvariant() + $_.Substring(1) })
            $vocabulary[$name] = @($attribute['Values'] | ForEach-Object { [string]$_['Key'] })
        }

        $sets.ClassificationSha256 | Should -BeExactly (Get-TestFileHash -Path $script:CanonicalClassification)
        @($sets.Classification.Id) | Should -Be @(@($sets.Concepts) + @($sets.Synonyms) | Sort-Object)
        @($sets.Classification | Where-Object { $null -eq $_.ReportingGroup } | ForEach-Object Id) | Should -Be @(0, 3561)
        @($sets.Classification | Where-Object { $null -ne $_.ReportingGroup -and -not $leaves.Contains($_.ReportingGroup) }) | Should -BeNullOrEmpty
        @($vocabulary.Keys | Sort-Object) | Should -Be @('GramReaction', 'OxygenRequirement')
        foreach ($name in $vocabulary.Keys) {
            $valued = @($sets.Classification | Where-Object { $null -ne $_.$name })
            @($valued.Id | Sort-Object) | Should -Be @($bacteria | Sort-Object) -Because "$name is given to the bacteria"
            @($valued | Where-Object { $_.$name -cnotin $vocabulary[$name] }) | Should -BeNullOrEmpty -Because "$name takes its vocabulary's values"
        }
    }

    It 'places well-known infectious agents of the committed files where the classification puts them' {
        # Known answers, each read from the two files by hand through the nearest member and assignment on the agent's
        # lineage, a genus, family, order, or phylum: the test above holds every node to a group and values that exist,
        # which a resolution placing nodes in the wrong ones would still pass.
        $rows = @((Get-NeoIPCInfectiousAgentCodeSet).Classification | Where-Object { $_.Id -in 934, 1296, 1807, 1958, 2273, 2600 })
        Get-TestRow -Row $rows | Should -BeExactly @(
            '934|gram-positive-cocci|positive|facultative-anaerobic'
            '1296|anaerobes|negative|obligate-anaerobic'
            '1807|enterobacterales|negative|facultative-anaerobic'
            '1958|non-fermenting-gram-negative-bacilli|negative|aerobic'
            '2273|yeasts|<null>|<null>'
            '2600|gram-positive-cocci|positive|facultative-anaerobic'
        )
    }

    It 'reads the list a relative path names, against the current location' {
        # .NET resolves a relative path against the process's directory, which Push-Location leaves where it is.
        $path = New-TestCodeSetList -Name 'relative'
        Push-Location -LiteralPath (Split-Path -Parent $path)
        try { $sets = Get-NeoIPCInfectiousAgentCodeSet -Path './NeoIPC-Infectious-Agents.yaml' }
        finally { Pop-Location }
        @($sets.Concepts) | Should -Be $script:ExpectedSets.Concepts
        $sets.Sha256 | Should -BeExactly (Get-TestFileHash -Path $path)
    }

    It 'reads and guards the classification a relative -ClassificationPath names, against the current location' {
        # A file of the same name in the process's directory, which Push-Location leaves where it is, is what a
        # resolution through .NET alone would read, and write over.
        $path = New-TestCodeSetList -Name 'classification-relative'
        $directory = Split-Path -Parent $path
        $named = Join-Path $directory 'named.yaml'
        [System.IO.File]::WriteAllText($named, $script:CodeSetClassificationYaml.Replace("`r`n", "`n").Replace('- Key: viruses', '- Key: viral-agents'), [System.Text.UTF8Encoding]::new($false))
        $decoyDirectory = Join-Path $TestDrive 'classification-relative-process'
        $null = New-Item -ItemType Directory -Path $decoyDirectory
        $decoy = Join-Path $decoyDirectory 'named.yaml'
        [System.IO.File]::WriteAllText($decoy, $script:CodeSetClassificationYaml.Replace("`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))
        $before = Get-TestFileHash -Path $named
        $decoyBefore = Get-TestFileHash -Path $decoy
        $processDirectory = [System.Environment]::CurrentDirectory
        [System.Environment]::CurrentDirectory = $decoyDirectory
        Push-Location -LiteralPath $directory
        try {
            $sets = Get-NeoIPCInfectiousAgentCodeSet -Path $path -ClassificationPath './named.yaml'
            { Export-NeoIPCInfectiousAgentCodeSet -Path $path -ClassificationPath './named.yaml' -OutputPath './named.yaml' } |
                Should -Throw -ExpectedMessage '*is the classification the code sets are read from*'
        }
        finally {
            Pop-Location
            [System.Environment]::CurrentDirectory = $processDirectory
        }
        $sets.ClassificationSha256 | Should -BeExactly $before
        Get-TestRow -Row $sets.Classification | Should -BeExactly @($script:ExpectedRows | ForEach-Object { $_.Replace('|viruses|', '|viral-agents|') })
        Get-TestFileHash -Path $named | Should -BeExactly $before
        Get-TestFileHash -Path $decoy | Should -BeExactly $decoyBefore
    }

    It 'reads a list on a PowerShell drive, and writes beside it' {
        $path = New-TestCodeSetList -Name 'drive'
        $null = New-PSDrive -Name NeoIPCTestCodeSet -PSProvider FileSystem -Root (Split-Path -Parent $path) -Scope Global
        try {
            $sets = Get-NeoIPCInfectiousAgentCodeSet -Path 'NeoIPCTestCodeSet:\NeoIPC-Infectious-Agents.yaml'
            Export-NeoIPCInfectiousAgentCodeSet -Path 'NeoIPCTestCodeSet:\NeoIPC-Infectious-Agents.yaml' -OutputPath 'NeoIPCTestCodeSet:\code-sets.json'
        }
        finally { Remove-PSDrive -Name NeoIPCTestCodeSet -Scope Global }
        @($sets.Concepts) | Should -Be $script:ExpectedSets.Concepts
        $sets.Sha256 | Should -BeExactly (Get-TestFileHash -Path $path)
        (Read-TestJson -Path (Join-Path (Split-Path -Parent $path) 'code-sets.json'))['Sha256'] | Should -BeExactly $sets.Sha256
    }

    It 'reads, writes from, and guards the classification -ClassificationPath names on a PowerShell drive' {
        $path = New-TestCodeSetList -Name 'drive-classification'
        $directory = Split-Path -Parent $path
        $named = Join-Path $directory 'named.yaml'
        [System.IO.File]::WriteAllText($named, $script:CodeSetClassificationYaml.Replace("`r`n", "`n").Replace('- Key: viruses', '- Key: viral-agents'), [System.Text.UTF8Encoding]::new($false))
        $before = Get-TestFileHash -Path $named
        $null = New-PSDrive -Name NeoIPCTestCodeSet -PSProvider FileSystem -Root $directory -Scope Global
        try {
            $sets = Get-NeoIPCInfectiousAgentCodeSet -Path $path -ClassificationPath 'NeoIPCTestCodeSet:\named.yaml'
            Export-NeoIPCInfectiousAgentCodeSet -Path $path -ClassificationPath 'NeoIPCTestCodeSet:\named.yaml' -OutputPath (Join-Path $directory 'code-sets.json')
            { Export-NeoIPCInfectiousAgentCodeSet -Path $path -ClassificationPath 'NeoIPCTestCodeSet:\named.yaml' -OutputPath 'NeoIPCTestCodeSet:\named.yaml' } |
                Should -Throw -ExpectedMessage '*is the classification the code sets are read from*'
        }
        finally { Remove-PSDrive -Name NeoIPCTestCodeSet -Scope Global }
        $expected = @($script:ExpectedRows | ForEach-Object { $_.Replace('|viruses|', '|viral-agents|') })
        $sets.ClassificationSha256 | Should -BeExactly $before
        Get-TestRow -Row $sets.Classification | Should -BeExactly $expected
        $read = Read-TestJson -Path (Join-Path $directory 'code-sets.json')
        $read['ClassificationSha256'] | Should -BeExactly $before
        Get-TestRow -Row $read['Classification'] | Should -BeExactly $expected
        Get-TestFileHash -Path $named | Should -BeExactly $before
    }

    It 'refuses <Case> on a drive of a provider other than the file system, writing nothing' -ForEach @(
        @{ Case = 'the list'; Name = 'variable-list'; Cmdlet = 'Get'; Named = 'Path'; Noun = 'list' }
        @{ Case = 'the list, to the export'; Name = 'variable-list-export'; Cmdlet = 'Export'; Named = 'Path'; Noun = 'list' }
        @{ Case = 'the classification'; Name = 'variable-classification'; Cmdlet = 'Get'; Named = 'ClassificationPath'; Noun = 'classification' }
        @{ Case = 'the classification, to the export'; Name = 'variable-classification-export'; Cmdlet = 'Export'; Named = 'ClassificationPath'; Noun = 'classification' }
        @{ Case = 'the output'; Name = 'variable-output'; Cmdlet = 'Export'; Named = 'OutputPath'; Noun = 'output path' }
    ) {
        # An alias is an item every session has, on a drive of the Alias provider. Its provider path, the alias's name,
        # is no file-system path: .NET would read or write it relative to the process's directory, and PowerShell's
        # cmdlets relative to the current location, here both the list's directory.
        $path = New-TestCodeSetList -Name $Name
        $directory = Split-Path -Parent $path
        $arguments = @{ Path = $path }
        if ($Cmdlet -eq 'Export') { $arguments.OutputPath = Join-Path $directory 'code-sets.json' }
        $arguments[$Named] = 'Alias:\gci'
        $processDirectory = [System.Environment]::CurrentDirectory
        [System.Environment]::CurrentDirectory = $directory
        Push-Location -LiteralPath $directory
        try {
            $call = if ($Cmdlet -eq 'Export') { { Export-NeoIPCInfectiousAgentCodeSet @arguments } } else { { Get-NeoIPCInfectiousAgentCodeSet @arguments } }
            $call | Should -Throw -ExpectedMessage "The $Noun 'Alias:\gci' is on a drive of the Alias provider, not in the file system*"
        }
        finally {
            Pop-Location
            [System.Environment]::CurrentDirectory = $processDirectory
        }
        @(Get-ChildItem -LiteralPath $directory -Name | Sort-Object) | Should -Be @('NeoIPC-Infectious-Agent-Reporting-Groups.yaml', 'NeoIPC-Infectious-Agents.yaml')
    }

    It 'refuses <Case> on a drive that does not exist, naming it, without the wrapper PowerShell puts around the reason' -ForEach @(
        @{ Case = 'the list'; Name = 'missing-drive-list'; Cmdlet = 'Get'; Named = 'Path'; Noun = 'list' }
        @{ Case = 'the output'; Name = 'missing-drive-output'; Cmdlet = 'Export'; Named = 'OutputPath'; Noun = 'output path' }
    ) {
        $path = New-TestCodeSetList -Name $Name
        $arguments = @{ Path = $path }
        if ($Cmdlet -eq 'Export') { $arguments.OutputPath = Join-Path (Split-Path -Parent $path) 'code-sets.json' }
        $arguments[$Named] = 'NeoIPCNoSuchDrive:\file'
        $call = if ($Cmdlet -eq 'Export') { { Export-NeoIPCInfectiousAgentCodeSet @arguments } } else { { Get-NeoIPCInfectiousAgentCodeSet @arguments } }
        $thrown = $call | Should -Throw -ExpectedMessage "The $Noun 'NeoIPCNoSuchDrive:\file' cannot be resolved: *" -PassThru
        $thrown.Exception.Message | Should -Not -BeLike '*GetUnresolvedProviderPathFromPSPath*'
    }

    It 'refuses a list <Case>, naming the file' -ForEach @(
        @{ Case = 'that begins with a byte order mark'; Name = 'bom'; Prefix = [byte[]](0xEF, 0xBB, 0xBF); Suffix = [byte[]]@(); Message = "The list '*' begins with a byte order mark*" }
        @{ Case = 'that is not valid UTF-8'; Name = 'invalid'; Prefix = [byte[]]@(); Suffix = [byte[]](0x23, 0x20, 0xFF, 0x0A); Message = "The list '*' is not valid UTF-8*" }
    ) {
        $text = [System.Text.UTF8Encoding]::new($false).GetBytes($script:CodeSetYaml.Replace("`r`n", "`n"))
        $path = New-TestCodeSetList -Name $Name -Byte ([byte[]]($Prefix + $text + $Suffix))
        { Get-NeoIPCInfectiousAgentCodeSet -Path $path } | Should -Throw -ExpectedMessage $Message
        { Get-NeoIPCInfectiousAgentCodeSet -Path $path } | Should -Throw -ExpectedMessage "*'$path'*"
    }

    It 'refuses a list that gives one Id to two nodes, as the option-set generator does' {
        $path = New-TestCodeSetList -Name 'duplicate' -Yaml $script:CodeSetYaml.Replace('    - Id: 25', '    - Id: 30')
        { Get-NeoIPCInfectiousAgentCodeSet -Path $path } | Should -Throw -ExpectedMessage "*Id 30 is that of two nodes*'Staphylococcus' and 'Micrococcus'*"
    }

    It 'returns, on the committed list, the sets the generators expand from' {
        # The generators' own functions are the reference, and CI holds the committed metadata to what they generate.
        $sets = Get-NeoIPCInfectiousAgentCodeSet
        $sets.Sha256 | Should -BeExactly (Get-TestFileHash -Path $script:CanonicalList)
        $reference = & (Get-Module NeoIPC-Tools) {
            param([string]$Path)
            $tree = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Yaml
            $resistance = Get-NeoIPCResistanceCodeSet -Node $tree
            [ordered]@{
                Codes            = @(Get-NeoIPCInfectiousAgentConcept -Node $tree | ForEach-Object { [int]$_.Id } | Sort-Object)
                CommonCommensals = @(Get-NeoIPCCommonCommensalCodeSet -Node $tree)
                '3GCR'           = @($resistance['3GCR'])
                CARBR            = @($resistance['carbapenem-resistant'])
                COLR             = @($resistance['colistin-resistant'])
                MRSA             = @($resistance['MRSA'])
                VRE              = @($resistance['VRE'])
                Viruses          = @(Get-NeoIPCVirusCodeSet -Node $tree)
            }
        } $script:CanonicalList
        @(@($sets.Concepts) + @($sets.Synonyms) | Sort-Object) | Should -Be $reference.Codes
        @($sets.CommonCommensals) | Should -Be $reference.CommonCommensals
        foreach ($category in '3GCR', 'CARBR', 'COLR', 'MRSA', 'VRE') {
            @($sets.ResistanceCategories.$category) | Should -Be $reference[$category] -Because $category
        }
        @($sets.Viruses) | Should -Be $reference.Viruses
    }

    It 'writes the code sets as JSON, in UTF-8 without a BOM, with LF line endings and a final line break' {
        $path = New-TestCodeSetList -Name 'export'
        $json = Join-Path (Split-Path -Parent $path) 'code-sets.json'
        Export-NeoIPCInfectiousAgentCodeSet -Path $path -OutputPath $json
        $bytes = [System.IO.File]::ReadAllBytes($json)
        $bytes[0] | Should -Not -Be 0xEF -Because 'the file carries no byte order mark'
        $text = [System.Text.UTF8Encoding]::new($false).GetString($bytes)
        $text | Should -Not -Match "`r"
        $text | Should -BeLike "*}`n" -Because 'the file ends with a line break'
        $read = $text | ConvertFrom-Json -AsHashtable
        @($read.Keys | Sort-Object) | Should -Be @('Classification', 'ClassificationSha256', 'CommonCommensals', 'Concepts', 'ResistanceCategories', 'Sha256', 'Synonyms', 'Viruses')
        $read['Sha256'] | Should -BeExactly (Get-TestFileHash -Path $path)
        foreach ($set in $script:ExpectedSets.Keys) { @($read[$set]) | Should -Be $script:ExpectedSets[$set] -Because $set }
        foreach ($category in $script:ExpectedCategories.Keys) {
            @($read['ResistanceCategories'][$category]) | Should -Be $script:ExpectedCategories[$category] -Because $category
        }
        $read['ClassificationSha256'] | Should -BeExactly (Get-TestFileHash -Path (Join-Path (Split-Path -Parent $path) 'NeoIPC-Infectious-Agent-Reporting-Groups.yaml'))
        Get-TestRow -Row $read['Classification'] | Should -BeExactly $script:ExpectedRows
        foreach ($row in $read['Classification']) {
            @($row.Keys) | Should -Be @('Id', 'ReportingGroup', 'GramReaction', 'OxygenRequirement') -Because 'every row carries every column, null where it takes no value'
        }
    }

    It 'writes every set as a JSON array, <Case>' -ForEach @(
        @{ Case = 'each of one Id'; Count = 1; Rows = 2; Yaml = "Hierarchies:`n- Name: Bacteria`n  CommonCommensal: true`n  MRSA: true`n  VRE: true`n  3GCR: true`n  Carbapenems: true`n  Colistin: true`n  Synonyms:`n  - Id: 2`n    Name: Bacterium`n- Name: Viruses`n  Children:`n  - Id: 1`n    Name: Influenza virus`n" }
        @{ Case = 'each empty'; Count = 0; Rows = 0; Yaml = "Hierarchies:`n- Name: Viruses`n" }
    ) {
        $path = New-TestCodeSetList -Name "shape-$Count" -Yaml $Yaml
        $json = Join-Path (Split-Path -Parent $path) 'code-sets.json'
        Export-NeoIPCInfectiousAgentCodeSet -Path $path -OutputPath $json
        $read = Read-TestJson -Path $json
        foreach ($set in $script:ExpectedSets.Keys) {
            , $read[$set] | Should -BeOfType [array] -Because $set
            $read[$set].Count | Should -Be $Count -Because $set
        }
        foreach ($category in $script:ExpectedCategories.Keys) {
            , $read['ResistanceCategories'][$category] | Should -BeOfType [array] -Because $category
            $read['ResistanceCategories'][$category].Count | Should -Be $Count -Because $category
        }
        , $read['Classification'] | Should -BeOfType [array] -Because 'the classification has a row per Id'
        $read['Classification'].Count | Should -Be $Rows
    }

    It 'writes the classification as a JSON array of one row for a list of one Id' {
        $path = New-TestCodeSetList -Name 'shape-one-row' -Yaml "Hierarchies:`n- Id: 0`n  Name: Not listed`n- Name: Viruses`n"
        $json = Join-Path (Split-Path -Parent $path) 'code-sets.json'
        Export-NeoIPCInfectiousAgentCodeSet -Path $path -OutputPath $json
        $read = Read-TestJson -Path $json
        , $read['Classification'] | Should -BeOfType [array]
        Get-TestRow -Row $read['Classification'] | Should -BeExactly @('0|<null>|<null>|<null>')
    }

    It 'writes the committed list''s code sets, and what the classification beside it gives each Id, when no path is given' {
        $json = Join-Path $TestDrive 'committed-code-sets.json'
        Export-NeoIPCInfectiousAgentCodeSet -OutputPath $json
        $read = Read-TestJson -Path $json
        $sets = Get-NeoIPCInfectiousAgentCodeSet
        $read['Sha256'] | Should -BeExactly (Get-TestFileHash -Path $script:CanonicalList)
        $read['ClassificationSha256'] | Should -BeExactly (Get-TestFileHash -Path $script:CanonicalClassification)
        @($read['Classification'] | ForEach-Object { $_['Id'] }) | Should -Be @(@($sets.Concepts) + @($sets.Synonyms) | Sort-Object)
        Get-TestRow -Row $read['Classification'] | Should -BeExactly (Get-TestRow -Row $sets.Classification)
    }

    It 'takes the list as its first positional argument, as the module''s other cmdlets take their input, and the output by name only' {
        $parameters = (Get-Command Export-NeoIPCInfectiousAgentCodeSet).Parameters
        @($parameters['Path'].ParameterSets.Values.Position) | Should -Be @(0)
        @($parameters['OutputPath'].ParameterSets.Values.Position) | Should -Be @([int]::MinValue)
        $path = New-TestCodeSetList -Name 'positional'
        $json = Join-Path (Split-Path -Parent $path) 'code-sets.json'
        Export-NeoIPCInfectiousAgentCodeSet $path -OutputPath $json
        (Read-TestJson -Path $json)['Sha256'] | Should -BeExactly (Get-TestFileHash -Path $path)
    }

    It 'refuses to write over the list it reads, named <Case>' -ForEach @(
        @{ Case = 'as it is'; Name = 'over-list'; Relative = $false }
        @{ Case = 'by a relative path'; Name = 'over-list-relative'; Relative = $true }
    ) {
        $path = New-TestCodeSetList -Name $Name
        $before = Get-TestFileHash -Path $path
        Push-Location -LiteralPath (Split-Path -Parent $path)
        try {
            $output = if ($Relative) { './NeoIPC-Infectious-Agents.yaml' } else { $path }
            { Export-NeoIPCInfectiousAgentCodeSet -Path $path -OutputPath $output } | Should -Throw -ExpectedMessage '*is the list the code sets are read from*'
        }
        finally { Pop-Location }
        Get-TestFileHash -Path $path | Should -BeExactly $before
    }

    It 'refuses an output that holds the list''s very bytes, leaving the list as it is: <Case>' -ForEach @(
        @{ Case = 'a hard link to the list'; Name = 'alias-hard'; Kind = 'HardLink' }
        @{ Case = 'a symbolic link to the list'; Name = 'alias-symbolic'; Kind = 'SymbolicLink' }
        @{ Case = 'the list reached through a linked directory'; Name = 'alias-directory'; Kind = 'Directory' }
        @{ Case = 'an identical copy of the list'; Name = 'alias-copy'; Kind = 'Copy' }
    ) {
        $path = New-TestCodeSetList -Name $Name
        $directory = Split-Path -Parent $path
        $before = Get-TestFileHash -Path $path
        $output = switch ($Kind) {
            'Directory' {
                # A junction needs no privilege on Windows, where a symbolic link may.
                $link = Join-Path $TestDrive "$Name-link"
                $null = New-Item -ItemType $(if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }) -Path $link -Target $directory
                Join-Path $link 'NeoIPC-Infectious-Agents.yaml'
            }
            'Copy' {
                $copy = Join-Path $directory 'copy.yaml'
                Copy-Item -LiteralPath $path -Destination $copy
                $copy
            }
            default {
                $alias = Join-Path $directory 'alias.json'
                try { $null = New-Item -ItemType $Kind -Path $alias -Target $path -ErrorAction Stop }
                catch {
                    Set-ItResult -Skipped -Because "this account cannot create $Case here: $($_.Exception.Message)"
                    return
                }
                $alias
            }
        }
        { Export-NeoIPCInfectiousAgentCodeSet -Path $path -OutputPath $output } | Should -Throw -ExpectedMessage '*holds the very bytes of the list*'
        Get-TestFileHash -Path $path | Should -BeExactly $before
    }

    It 'refuses to write over the classification it reads, named <Case>, leaving it as it is' -ForEach @(
        @{ Case = 'as it is'; Name = 'over-classification'; Relative = $false; Named = $false }
        @{ Case = 'by a relative path'; Name = 'over-classification-relative'; Relative = $true; Named = $false }
        @{ Case = 'where -ClassificationPath names it'; Name = 'over-classification-named'; Relative = $false; Named = $true }
    ) {
        $path = New-TestCodeSetList -Name $Name
        $directory = Split-Path -Parent $path
        $classification = Join-Path $directory 'NeoIPC-Infectious-Agent-Reporting-Groups.yaml'
        if ($Named) {
            $classification = Join-Path $directory 'named-classification.yaml'
            Move-Item -LiteralPath (Join-Path $directory 'NeoIPC-Infectious-Agent-Reporting-Groups.yaml') -Destination $classification
        }
        $before = Get-TestFileHash -Path $classification
        $arguments = @{ Path = $path }
        if ($Named) { $arguments.ClassificationPath = $classification }
        Push-Location -LiteralPath $directory
        try {
            $arguments.OutputPath = if ($Relative) { './NeoIPC-Infectious-Agent-Reporting-Groups.yaml' } else { $classification }
            { Export-NeoIPCInfectiousAgentCodeSet @arguments } | Should -Throw -ExpectedMessage '*is the classification the code sets are read from*'
        }
        finally { Pop-Location }
        Get-TestFileHash -Path $classification | Should -BeExactly $before
    }

    It 'refuses an output that holds the classification''s very bytes, as an identical copy does' {
        $path = New-TestCodeSetList -Name 'alias-classification-copy'
        $directory = Split-Path -Parent $path
        $copy = Join-Path $directory 'copy.yaml'
        Copy-Item -LiteralPath (Join-Path $directory 'NeoIPC-Infectious-Agent-Reporting-Groups.yaml') -Destination $copy
        $before = Get-TestFileHash -Path $copy
        { Export-NeoIPCInfectiousAgentCodeSet -Path $path -OutputPath $copy } | Should -Throw -ExpectedMessage '*holds the very bytes of the classification*'
        Get-TestFileHash -Path $copy | Should -BeExactly $before
    }

    It 'ends at a <Case>, saying so and leaving the file it would write over as it was, under the caller''s <Preference>' -ForEach @(
        @{ Case = 'classification that is not valid YAML'; Name = 'stop-yaml'; Preference = 'Continue'; Over = 'Output'; Message = "*The classification '*' is not valid YAML*" }
        @{ Case = 'refusal to write over the list'; Name = 'stop-refusal'; Preference = 'SilentlyContinue'; Over = 'List'; Message = "*The output path '*' is the list the code sets are read from*" }
    ) {
        # In a process of its own, whose global preference the module's functions see: inside Pester's own try, the
        # first error ends the call whatever the cmdlet does. The message shows that the child reached the cmdlet: a
        # child that failed before it, at its import, would leave the file as it was too. NormalView prints the message
        # on one line, where the default view wraps it at the width of the console.
        $path = New-TestCodeSetList -Name $Name
        $directory = Split-Path -Parent $path
        $output = $path
        if ($Over -eq 'Output') {
            $broken = $script:CodeSetClassificationYaml.Replace("`r`n", "`n") + "`nbroken: [`n"
            [System.IO.File]::WriteAllText((Join-Path $directory 'NeoIPC-Infectious-Agent-Reporting-Groups.yaml'), $broken, [System.Text.UTF8Encoding]::new($false))
            $output = Join-Path $directory 'code-sets.json'
            [System.IO.File]::WriteAllText($output, "{}`n", [System.Text.UTF8Encoding]::new($false))
        }
        $before = Get-TestFileHash -Path $output
        $caller = Join-Path $TestDrive "$Name.ps1"
        $callerText = "param(`$Module, `$List, `$Output, `$Preference)`n`$PSStyle.OutputRendering = 'PlainText'`n`$ErrorView = 'NormalView'`n`$global:ErrorActionPreference = `$Preference`nImport-Module `$Module`nExport-NeoIPCInfectiousAgentCodeSet -Path `$List -OutputPath `$Output`n"
        [System.IO.File]::WriteAllText($caller, $callerText, [System.Text.UTF8Encoding]::new($false))
        $module = Join-Path (Get-Module NeoIPC-Tools).ModuleBase 'NeoIPC-Tools.psd1'
        $said = @(& (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $caller -Module $module -List $path -Output $output -Preference $Preference 2>&1 | ForEach-Object { "$_" })
        ($said -join "`n") | Should -BeLike $Message
        Get-TestFileHash -Path $output | Should -BeExactly $before
    }

    It 'ends at a list it refuses, handing the caller no sets, under the caller''s SilentlyContinue' {
        # In a process of its own, as above: a refusal dropped there, silently, would hand the caller sets from a list
        # refused, where under Stop it ends the caller's script with the refusal's message.
        $path = New-TestCodeSetList -Name 'stop-get' -Yaml $script:CodeSetYaml.Replace('    - Id: 25', '    - Id: 30')
        $caller = Join-Path $TestDrive 'stop-get.ps1'
        $callerText = "param(`$Module, `$List)`n`$PSStyle.OutputRendering = 'PlainText'`n`$global:ErrorActionPreference = 'SilentlyContinue'`nImport-Module `$Module`n`$sets = Get-NeoIPCInfectiousAgentCodeSet -Path `$List`nif (`$null -ne `$sets) { 'returned sets' }`n"
        [System.IO.File]::WriteAllText($caller, $callerText, [System.Text.UTF8Encoding]::new($false))
        $module = Join-Path (Get-Module NeoIPC-Tools).ModuleBase 'NeoIPC-Tools.psd1'
        $said = @(& (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $caller -Module $module -List $path 2>&1 | ForEach-Object { "$_" })
        ($said -join "`n") | Should -BeLike '*The Id 30 is that of two nodes*'
        $said | Should -Not -Contain 'returned sets'
    }

    It 'writes the classification -ClassificationPath names' {
        $path = New-TestCodeSetList -Name 'export-classification-named' -NoClassification
        $directory = Split-Path -Parent $path
        $classification = Join-Path $directory 'named-classification.yaml'
        [System.IO.File]::WriteAllText($classification, $script:CodeSetClassificationYaml.Replace("`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))
        $json = Join-Path $directory 'code-sets.json'
        Export-NeoIPCInfectiousAgentCodeSet -Path $path -ClassificationPath $classification -OutputPath $json
        $read = Read-TestJson -Path $json
        $read['ClassificationSha256'] | Should -BeExactly (Get-TestFileHash -Path $classification)
        Get-TestRow -Row $read['Classification'] | Should -BeExactly $script:ExpectedRows
    }

    It 'refuses to write over the list it reads, named in another letter case, where the file system ignores case' -Skip:$IsLinux {
        $path = New-TestCodeSetList -Name 'over-list-case'
        $before = Get-TestFileHash -Path $path
        { Export-NeoIPCInfectiousAgentCodeSet -Path $path -OutputPath $path.ToUpperInvariant() } | Should -Throw -ExpectedMessage '*is the list the code sets are read from*'
        Get-TestFileHash -Path $path | Should -BeExactly $before
    }

    It 'writes to a relative path against the current location, and nothing with WhatIf' {
        $path = New-TestCodeSetList -Name 'export-relative'
        $directory = Split-Path -Parent $path
        Push-Location -LiteralPath $directory
        try {
            Export-NeoIPCInfectiousAgentCodeSet -Path $path -OutputPath './code-sets.json'
            Export-NeoIPCInfectiousAgentCodeSet -Path $path -OutputPath './not-written.json' -WhatIf
        }
        finally { Pop-Location }
        Test-Path -LiteralPath (Join-Path $directory 'code-sets.json') -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $directory 'not-written.json') | Should -BeFalse
    }
}
