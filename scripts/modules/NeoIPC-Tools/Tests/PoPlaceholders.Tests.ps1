#Requires -Version 7.6
#requires -Module Pester

<#
.SYNOPSIS
    Pester tests for the named-placeholder check of scripts/Test-PoPlaceholders.ps1.

.DESCRIPTION
    Runs the script on a one-entry catalogue written for each case and reads its exit code, which is
    the number of violations it found. A translation may reorder the named placeholders but must keep
    every name, spelled as the source spells it: glue refuses a name it has no value for, and a value
    whose name the translation dropped leaves the sentence without an error.

.EXAMPLE
    Invoke-Pester -Path scripts/modules/NeoIPC-Tools/Tests/PoPlaceholders.Tests.ps1
#>

BeforeAll {
    $checker = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' 'Test-PoPlaceholders.ps1')).Path

    # Writes a catalogue holding one translated entry and returns the number of violations the checker
    # reports for it.
    function Get-ViolationCount {
        param([string]$MsgId, [string]$MsgStr)
        $dir = Join-Path ([IO.Path]::GetTempPath()) ([IO.Path]::GetRandomFileName())
        New-Item -ItemType Directory -Path $dir | Out-Null
        try {
            $po = "msgid `"`"`nmsgstr `"Content-Type: text/plain; charset=UTF-8\n`"`n`n" +
                  "msgid `"$MsgId`"`nmsgstr `"$MsgStr`"`n"
            [IO.File]::WriteAllText((Join-Path $dir 'reports.de.po'), $po, [Text.UTF8Encoding]::new($false))
            & pwsh -NoProfile -File $checker -Path $dir -Quiet *> $null
            $LASTEXITCODE
        } finally {
            Remove-Item -LiteralPath $dir -Recurse -Force
        }
    }
}

Describe 'Named placeholders in a translation' {

    It 'passes a translation that keeps every name, in another order' {
        Get-ViolationCount '{count} infections in {department}' 'In {department}: {count} Infektionen' |
            Should -Be 0
    }

    It 'reports a translation that drops a name' {
        Get-ViolationCount '{count} infections in {department}' '{count} Infektionen' | Should -Be 1
    }

    It 'reports a translation that renames one' {
        Get-ViolationCount 'The neonatal department at {hospital}' 'Die Abteilung der {krankenhaus}' |
            Should -Be 1
    }

    It 'reports a translation that changes the case of one, as glue reads names case-sensitively' {
        Get-ViolationCount '{column}: the number' '{Column}: die Anzahl' | Should -Be 1
    }

    It 'takes neither a heading anchor nor a .NET index for a named placeholder' {
        Get-ViolationCount 'Methods {#sec-methods} in {0} parts' 'Methoden {#sec-methoden} in {0} Teilen' |
            Should -Be 0
    }
}
