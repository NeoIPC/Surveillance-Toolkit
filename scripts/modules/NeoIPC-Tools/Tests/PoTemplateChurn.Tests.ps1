#Requires -Version 7.6
#requires -Module Pester

<#
.SYNOPSIS
    Pester gate on the predicate that decides whether a regenerated template changed at all.

.DESCRIPTION
    Invoke-Localization.ps1 puts a template back when a run rewrote nothing but its POT-Creation-Date,
    because po4a and the two exporters rewrite that field on every run whether or not a source string
    moved. Committing such a template makes Weblate merge the header into every catalogue of the
    component -- a diff across nine languages for no content -- and it destroys the signal, since a run
    that genuinely changed one template then looks like a run that changed six.

    The predicate is therefore load-bearing in the dangerous direction: reverting a template that DID
    change would silently discard a new or edited source string, which no later step could detect. Most
    of what is asserted below is that it leaves real changes alone, including the two cases that are easy
    to get wrong -- a source string that changed while the date ALSO moved, and one that changed only in
    case, which PowerShell's case-insensitive -eq would read as no change at all.

    The function is extracted from the script by syntax tree rather than copied here, so what runs is the
    code that ships. Dot-sourcing is not available: the script executes on load.
#>

BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    $scriptPath = Join-Path $repoRoot 'scripts' 'Invoke-Localization.ps1'
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
    $definition = $ast.FindAll({ param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Test-TimestampOnlyChange' }, $true) | Select-Object -First 1
    if (-not $definition) {
        throw "Test-TimestampOnlyChange is not defined in $scriptPath, so this gate is inspecting nothing."
    }
    . ([scriptblock]::Create($definition.Extent.Text))

    $script:Template = @'
# Translations for the thing
msgid ""
msgstr ""
"POT-Creation-Date: 2026-08-05 10:00+0000\n"
"Language-Team: none\n"

msgid "Birthweight"
msgstr ""
'@
    # Not named Diff: that is a built-in alias for Compare-Object, which wins the name resolution and
    # fails on a missing -DifferenceObject rather than calling anything defined here.
    function script:Test-Churn([string]$After) {
        Test-TimestampOnlyChange -Before ([System.Text.Encoding]::UTF8.GetBytes($script:Template)) `
                                 -After  ([System.Text.Encoding]::UTF8.GetBytes($After))
    }
}

Describe 'Test-TimestampOnlyChange' {
    It 'reports a rewritten creation date as the only change' {
        Test-Churn($script:Template -replace '2026-08-05 10:00', '2026-08-06 11:30') | Should -BeTrue
    }

    It 'reports nothing for a template that did not change' {
        Test-Churn $script:Template | Should -BeFalse
    }

    It 'keeps a changed source string' {
        Test-Churn($script:Template -replace 'Birthweight', 'Birth weight') | Should -BeFalse
    }

    It 'keeps a changed source string when the date moved as well' {
        # The realistic shape of a real change, since the date always moves too. A predicate that stopped
        # at "the date differs" would discard the edit.
        Test-Churn(($script:Template -replace '2026-08-05 10:00', '2026-08-06 11:30') -replace
              'Birthweight', 'Birth weight') | Should -BeFalse
    }

    It 'keeps a source string that changed only in case' {
        # -eq would call these equal. A casing fix to a msgid is a real change to a translatable unit.
        Test-Churn($script:Template -replace 'Birthweight', 'birthweight') | Should -BeFalse
    }

    It 'keeps a template that gained a unit' {
        Test-Churn($script:Template + "`nmsgid `"Gestational age`"`nmsgstr `"`"`n") | Should -BeFalse
    }
}
