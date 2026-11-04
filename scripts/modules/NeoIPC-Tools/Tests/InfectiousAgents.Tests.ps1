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
    from category to category, and on the committed list, against the functions the generators expand from.

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
        # comes out of the walk out of ascending order, so that the order the sets come in is the code's.
        $script:CodeSetYaml = @'
Hierarchies:
- Id: 0
  Name: Not listed
  MRSA: true
  VRE: true
  3GCR: true
  Carbapenems: true
  Colistin: true
- Name: Bacteria
  Children:
  - Id: 60
    Name: Enterococcus
    VRE: true
    Carbapenems: true
    Children:
    - Id: 11
      Name: Enterococcus faecium
  - Id: 50
    Name: Klebsiella
    3GCR: true
    Carbapenems: true
    Children:
    - Id: 21
      Name: Klebsiella pneumoniae
      Carbapenems: false
      Colistin: true
  - Id: 30
    Name: Staphylococcus
    CommonCommensal: true
    MRSA: true
    Synonyms:
    - Id: 25
      Name: Micrococcus
    Children:
    - Id: 12
      Name: Staphylococcus aureus
      CommonCommensal: false
      Colistin: true
- Name: Viruses
  Children:
  - Id: 41
    Name: Influenza virus
    Synonyms:
    - Id: 15
      Name: Flu virus
'@
        # The sets of that list, in ascending order.
        $script:ExpectedSets = [ordered]@{ Concepts = @(0, 11, 12, 21, 30, 41, 50, 60); Synonyms = @(15, 25); CommonCommensals = @(25, 30); Viruses = @(15, 41) }
        $script:ExpectedCategories = [ordered]@{ '3GCR' = @(0, 21, 50); CARBR = @(0, 11, 50, 60); COLR = @(0, 12, 21); MRSA = @(0, 12, 25, 30); VRE = @(0, 11, 60) }
        $script:CanonicalList = Join-Path (Get-Module NeoIPC-Tools).ModuleBase '..' '..' '..' 'metadata' 'common' 'infectious-agents' 'NeoIPC-Infectious-Agents.yaml'

        function New-TestCodeSetList {
            # A directory in TestDrive holding the list, as UTF-8 without a byte order mark and with LF line endings, or
            # as the bytes given.
            param([Parameter(Mandatory)][string]$Name, [string]$Yaml = $script:CodeSetYaml, [byte[]]$Byte)
            $directory = Join-Path $TestDrive $Name
            $null = New-Item -ItemType Directory -Path $directory -Force
            $path = Join-Path $directory 'NeoIPC-Infectious-Agents.yaml'
            if ($Byte) { [System.IO.File]::WriteAllBytes($path, $Byte) }
            else { [System.IO.File]::WriteAllText($path, $Yaml.Replace("`r`n", "`n"), [System.Text.UTF8Encoding]::new($false)) }
            $path
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

    It 'reads the list a relative path names, against the current location' {
        # .NET resolves a relative path against the process's directory, which Push-Location leaves where it is.
        $path = New-TestCodeSetList -Name 'relative'
        Push-Location -LiteralPath (Split-Path -Parent $path)
        try { $sets = Get-NeoIPCInfectiousAgentCodeSet -Path './NeoIPC-Infectious-Agents.yaml' }
        finally { Pop-Location }
        @($sets.Concepts) | Should -Be $script:ExpectedSets.Concepts
        $sets.Sha256 | Should -BeExactly (Get-TestFileHash -Path $path)
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

    It 'refuses a list <Case>, naming the file' -ForEach @(
        @{ Case = 'that begins with a byte order mark'; Name = 'bom'; Prefix = [byte[]](0xEF, 0xBB, 0xBF); Suffix = [byte[]]@(); Message = '*begins with a byte order mark*' }
        @{ Case = 'that is not valid UTF-8'; Name = 'invalid'; Prefix = [byte[]]@(); Suffix = [byte[]](0x23, 0x20, 0xFF, 0x0A); Message = '*is not valid UTF-8*' }
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
        @($read.Keys | Sort-Object) | Should -Be @('CommonCommensals', 'Concepts', 'ResistanceCategories', 'Sha256', 'Synonyms', 'Viruses')
        $read['Sha256'] | Should -BeExactly (Get-TestFileHash -Path $path)
        foreach ($set in $script:ExpectedSets.Keys) { @($read[$set]) | Should -Be $script:ExpectedSets[$set] -Because $set }
        foreach ($category in $script:ExpectedCategories.Keys) {
            @($read['ResistanceCategories'][$category]) | Should -Be $script:ExpectedCategories[$category] -Because $category
        }
    }

    It 'writes every set as a JSON array, <Case>' -ForEach @(
        @{ Case = 'each of one Id'; Count = 1; Yaml = "Hierarchies:`n- Name: Bacteria`n  CommonCommensal: true`n  MRSA: true`n  VRE: true`n  3GCR: true`n  Carbapenems: true`n  Colistin: true`n  Synonyms:`n  - Id: 2`n    Name: Bacterium`n- Name: Viruses`n  Children:`n  - Id: 1`n    Name: Influenza virus`n" }
        @{ Case = 'each empty'; Count = 0; Yaml = "Hierarchies:`n- Name: Viruses`n" }
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
    }

    It 'writes the committed list''s code sets when no -Path is given' {
        $json = Join-Path $TestDrive 'committed-code-sets.json'
        Export-NeoIPCInfectiousAgentCodeSet -OutputPath $json
        (Read-TestJson -Path $json)['Sha256'] | Should -BeExactly (Get-TestFileHash -Path $script:CanonicalList)
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
