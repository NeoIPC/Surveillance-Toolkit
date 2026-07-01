#requires -Module Pester

# Approved-verb hygiene gate. Every command script in scripts/ must start with an
# approved PowerShell verb (Get-Verb), and every function the scripts/modules define
# must too. The file-name check is custom because PSScriptAnalyzer's PSUseApprovedVerbs
# inspects function definitions, not script basenames — so it alone would not catch a
# script file named with an unapproved verb (e.g. Generate-*.ps1 / Make-*.ps1).

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
