#Requires -Version 7.6
#requires -Module Pester

<#
.SYNOPSIS
    Pester gate rejecting variables named after PowerShell's automatic variables.

.DESCRIPTION
    Assigning to an automatic variable shadows the engine's own, and the result usually still works, so
    the defect survives review until an unrelated reordering changes the answer. Test-PoPlaceholders.ps1
    bound $matches to a MatchCollection in the same scope where a later -match repopulates the real one
    and its capture group is read back; it held only because foreach evaluates its collection once,
    before the overwrite.

    Delegates to PSScriptAnalyzer's PSAvoidAssignmentToAutomaticVariable, and is skipped when
    PSScriptAnalyzer is absent - the same shape as the approved-verb gate beside it. That rule does not
    flag the `$null = <expr>` discard idiom, which is why this can be a plain assertion of zero rather
    than a count with exemptions.

.EXAMPLE
    Invoke-Pester -Path scripts/modules/NeoIPC-Tools/Tests/AutomaticVariableHygiene.Tests.ps1
#>

BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
}

Describe 'Automatic-variable hygiene' -Skip:(-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
    It 'no script under scripts/ assigns to a PowerShell automatic variable' {
        $findings = Invoke-ScriptAnalyzer -Path (Join-Path $repoRoot 'scripts') -Recurse `
            -IncludeRule PSAvoidAssignmentToAutomaticVariable
        ($findings | ForEach-Object { '{0}:{1} {2}' -f $_.ScriptName, $_.Line, $_.Message } | Out-String).Trim() |
            Should -BeExactly '' -Because 'an automatic variable name shadows the engine own'
    }
}
