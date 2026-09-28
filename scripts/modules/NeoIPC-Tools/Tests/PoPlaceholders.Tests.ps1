#Requires -Version 7.6
#requires -Module Pester

<#
.SYNOPSIS
    Pester tests for the named-placeholder check of scripts/Test-PoPlaceholders.ps1.

.DESCRIPTION
    Runs the script on a one-entry catalogue written for each case and reads the named-placeholder
    violations it prints, together with its exit code, which is the number of violations it found. A
    translation may reorder the named placeholders but must keep every name, spelled as the source
    spells it: glue refuses a name it has no value for, and a value whose name the translation dropped
    leaves the sentence without an error.

    The printed violation is the oracle rather than the exit code alone, because a script that fails
    for any other reason exits non-zero too, and would pass every case that expects a violation.

.EXAMPLE
    Invoke-Pester -Path scripts/modules/NeoIPC-Tools/Tests/PoPlaceholders.Tests.ps1
#>

BeforeAll {
    $checker = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' 'Test-PoPlaceholders.ps1')).Path

    # Writes a catalogue holding one translated entry, fuzzy if asked, and returns the checker's exit
    # code, the named-placeholder violations it printed, the translation it printed as found, and the
    # number of fuzzy entries its summary says it left unchecked.
    function Invoke-Checker {
        param([string]$MsgId, [string]$MsgStr, [switch]$Fuzzy)
        $dir = Join-Path ([IO.Path]::GetTempPath()) ([IO.Path]::GetRandomFileName())
        New-Item -ItemType Directory -Path $dir | Out-Null
        try {
            $flag = if ($Fuzzy) { "#, fuzzy`n" } else { '' }
            $po = "msgid `"`"`nmsgstr `"Content-Type: text/plain; charset=UTF-8\n`"`n`n" +
                  "$flag" + "msgid `"$MsgId`"`nmsgstr `"$MsgStr`"`n"
            [IO.File]::WriteAllText((Join-Path $dir 'reports.de.po'), $po, [Text.UTF8Encoding]::new($false))
            $output = & pwsh -NoProfile -File $checker -Path $dir *>&1 | Out-String
            $lines = $output -split '\r?\n'
            [pscustomobject]@{
                ExitCode   = $LASTEXITCODE
                Violations = @($lines | Where-Object { $_ -match ': error: Named placeholders: ' })
                Found      = @($lines | Where-Object { $_ -match '^\s+Found: ' } |
                    ForEach-Object { ($_ -replace '^\s+Found: ', '').Trim() })
                Fuzzy      = @($lines | Where-Object { $_ -match '^Fuzzy entries not checked: ' } |
                    ForEach-Object { [int]($_ -replace '^Fuzzy entries not checked: ', '') })
            }
        } finally {
            Remove-Item -LiteralPath $dir -Recurse -Force
        }
    }
}

Describe 'Named placeholders in a translation' {

    It 'passes a translation that keeps every name, in another order' {
        $result = Invoke-Checker '{count} infections in {department}' 'In {department}: {count} Infektionen'
        $result.Violations | Should -BeNullOrEmpty
        $result.ExitCode | Should -Be 0
    }

    It 'reports a translation that drops a name' {
        $result = Invoke-Checker '{count} infections in {department}' '{count} Infektionen'
        $result.Violations | Should -HaveCount 1
        $result.Found | Should -Be '{count}'
        $result.ExitCode | Should -Be 1
    }

    It 'reports a translation that renames one' {
        $result = Invoke-Checker 'The neonatal department at {hospital}' 'Die Abteilung der {krankenhaus}'
        $result.Violations | Should -HaveCount 1
        $result.Found | Should -Be '{krankenhaus}'
        $result.ExitCode | Should -Be 1
    }

    It 'reports a translation that changes the case of one, as glue reads names case-sensitively' {
        $result = Invoke-Checker '{column}: the number' '{Column}: die Anzahl'
        $result.Violations | Should -HaveCount 1
        $result.Found | Should -Be '{Column}'
        $result.ExitCode | Should -Be 1
    }

    It 'reports a translation that turns an escaped brace into a placeholder' {
        $result = Invoke-Checker 'Write {{name}} literally' 'Schreibe {name} wörtlich'
        $result.Violations | Should -HaveCount 1
        $result.Found | Should -Be '{name}'
        $result.ExitCode | Should -Be 1
    }

    It 'takes neither a heading anchor nor a .NET index for a named placeholder' {
        $result = Invoke-Checker 'Methods {#sec-methods} in {0} parts' 'Methoden {#sec-methoden} in {0} Teilen'
        $result.Violations | Should -BeNullOrEmpty
        $result.ExitCode | Should -Be 0
    }

    It 'takes no TeX command argument for a named placeholder' {
        $result = Invoke-Checker '{rate} per \\text{days}' '{rate} pro \\text{Tage}'
        $result.Violations | Should -BeNullOrEmpty
        $result.ExitCode | Should -Be 0
    }

    It 'leaves a fuzzy entry unchecked, since po4a does not render it' {
        $result = Invoke-Checker '{count} infections in {department}' '{count} Infektionen' -Fuzzy
        $result.Violations | Should -BeNullOrEmpty
        $result.Fuzzy | Should -Be 1
        $result.ExitCode | Should -Be 0
    }
}
