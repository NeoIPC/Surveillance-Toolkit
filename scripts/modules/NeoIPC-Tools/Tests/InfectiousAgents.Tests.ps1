#Requires -Version 7.6

<#
.SYNOPSIS
    Tests of the public infectious-agent cmdlets (Public/InfectiousAgents.ps1).

.DESCRIPTION
    Add-NeoIPCInfectiousAgentUid is driven as its callers drive it, on a list and a UID sidecar in TestDrive, and
    New-NeoIPCPathogenOptionSet is shown taking every option UID it draws. The UID draw itself, New-NeoIPCRandomUid,
    is replaced in one test only, to force the collisions the retry exists for: a drawn UID meets a taken one with a
    chance of about 1 in 10^16, so no caller can provoke one.

    Internals are reached through InModuleScope; the Import-Module at file top runs during Pester's discovery phase,
    which InModuleScope requires.

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
