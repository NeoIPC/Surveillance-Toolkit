#Requires -Version 7.6
#requires -Module Pester

<#
.SYNOPSIS
    Pester gate enforcing approved-verb naming on script files and module functions.

.DESCRIPTION
    Every command script under scripts/ must begin with an approved PowerShell verb (Get-Verb), and so
    must every function the modules under scripts/modules define.

    The file-name half is a custom check rather than a PSScriptAnalyzer rule, and deliberately so:
    PSUseApprovedVerbs inspects function definitions, not script basenames, so on its own it would not
    catch a script file named with an unapproved verb such as Generate-Something.ps1 or Make-Thing.ps1.
    The function half does delegate to PSUseApprovedVerbs, and is skipped when PSScriptAnalyzer is absent.

.EXAMPLE
    Invoke-Pester -Path scripts/modules/NeoIPC-Tools/Tests/ScriptVerbHygiene.Tests.ps1
#>

BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    $approvedVerbs = (Get-Verb).Verb
}

Describe 'Approved-verb hygiene: script file names' {
    It 'every scripts/*.ps1 file name starts with an approved PowerShell verb' {
        $offenders =
            Get-ChildItem -LiteralPath (Join-Path $repoRoot 'scripts') -Filter '*.ps1' -File |
            Where-Object { ($_.BaseName -split '-', 2)[0] -notin $approvedVerbs } |
            ForEach-Object { $_.Name }
        ($offenders -join ', ') |
            Should -BeExactly '' -Because 'script file names must start with an approved verb (Get-Verb)'
    }
}

Describe 'Approved-verb hygiene: function names' -Skip:(-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
    It 'no function under scripts/ uses an unapproved verb (PSUseApprovedVerbs)' {
        $findings = Invoke-ScriptAnalyzer -Path (Join-Path $repoRoot 'scripts') -Recurse -IncludeRule PSUseApprovedVerbs
        ($findings | ForEach-Object { '{0}:{1} {2}' -f $_.ScriptName, $_.Line, $_.Message } | Out-String).Trim() |
            Should -BeExactly '' -Because 'function names must use an approved verb'
    }
}
