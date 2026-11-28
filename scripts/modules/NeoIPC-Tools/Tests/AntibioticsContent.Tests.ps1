#Requires -Version 7.6

<#
.SYNOPSIS
    Content lints over the committed sources of the antibiotics list.

.DESCRIPTION
    These read the real committed files under metadata/common/antibiotics and cross-reference them:
    the substance table against the committed extract of WHO's AWaRe classification of 2025, so no
    substance's category drifts from the edition the directory says it follows; and the attribution
    in README.md, LICENSE.md, and the Core Protocol's colophon against that same edition, so the
    three never name different editions of the classification. The distinction from
    Metadata.Tests.ps1, which exercises the generators against fixtures, is the same as
    MetadataContent.Tests.ps1's: content drift that a synthetic fixture cannot see.

    The property the cross-reference holds: every option carries one of the three AWaRe categories
    and the category the 2025 classification gives it — a substance without a category is silently
    left out of every WHO_AWARE option group by the generator's membership walk, which reads only
    non-empty categories, so a green build would hide a substance that no AWaRe group names.

.EXAMPLE
    Invoke-Pester -Path scripts/modules/NeoIPC-Tools/Tests/AntibioticsContent.Tests.ps1
#>

Describe 'Antibiotics list (metadata/common/antibiotics)' {
    BeforeAll {
        $dir = (Resolve-Path (Join-Path $PSScriptRoot '../../../../metadata/common/antibiotics')).Path
        $script:Substances = @(Import-Csv -LiteralPath (Join-Path $dir 'NeoIPC-Antibiotics.csv'))
        $script:Classification2025 = @(Import-Csv -LiteralPath (Join-Path $dir 'WHO-AWaRe-Classification-2025.csv'))
        $script:Readme = Get-Content -Raw -LiteralPath (Join-Path $dir 'README.md')
        $script:License = Get-Content -Raw -LiteralPath (Join-Path $dir 'LICENSE.md')
        $script:Colophon = Get-Content -Raw -LiteralPath (Join-Path $dir '../../../doc/protocol/NeoIPC-Core-Protocol.adoc')

        # Pair each NeoIPC option with its row in the WHO extract. The two sides mark route
        # differently: the extract names its parenteral and oral entries X_IV / X_oral — twelve
        # substances split that way, ten of them under the ATC code of the non-J01 group the oral
        # form belongs to — while NeoIPC marks a route in the option id (X_O / X_P) only where it
        # splits a substance across two options, in a display name "(i. v.)" where it holds only
        # the parenteral form, or nowhere at all where the substance has one systemic row of its
        # own (Metronidazole, Tinidazole, Ornidazole). The ATC code therefore pairs the rows, the
        # route narrows the pair where one code carries two entries, and the name settles it
        # where one code covers two substances (Amoxicillin/clavulanic-acid and
        # Amoxicillin/sulbactam share J01CR02). The two substances NeoIPC holds without an ATC
        # code join the extract's unassigned rows by name.
        function ConvertTo-NormalizedSubstanceName {
            param([string]$Name)
            $n = $Name.ToLowerInvariant()
            $n = $n -replace '(?i)_oral\b', ' ' -replace '(?i)_iv\b', ' '
            $n = $n -replace '\(\s*i\.\s*v\.\s*\)', ' ' -replace '\(\s*oral\s*\)', ' '
            $n = $n -replace '[^a-z0-9]+', ' '
            ($n -replace '\s+', ' ').Trim()
        }

        $whoByAtc = @{}
        foreach ($w in $script:Classification2025) {
            if ($w.category -notin @('Access', 'Watch', 'Reserve')) {
                throw "WHO extract row '$($w.antibiotic)' carries unknown category '$($w.category)'."
            }
            $route = if ($w.antibiotic -match '(?i)_oral$') { 'O' } elseif ($w.antibiotic -match '(?i)_iv$') { 'P' } else { '' }
            $atc = if ($w.atc_code -eq 'not assigned') { '' } else { $w.atc_code }
            if (-not $whoByAtc.ContainsKey($atc)) { $whoByAtc[$atc] = [System.Collections.Generic.List[object]]::new() }
            $whoByAtc[$atc].Add([pscustomobject]@{ Route = $route; Name = (ConvertTo-NormalizedSubstanceName $w.antibiotic); Row = $w })
        }

        $script:Uncategorized = [System.Collections.Generic.List[string]]::new()
        $script:NotIn2025 = [System.Collections.Generic.List[string]]::new()
        $script:CategoryDiffers = [System.Collections.Generic.List[string]]::new()
        foreach ($s in $script:Substances) {
            if ($s.aware_category -notin @('Access', 'Watch', 'Reserve')) {
                $script:Uncategorized.Add("$($s.id) ($($s.name)) : '$($s.aware_category)'")
            }
            $route = ''
            if ($s.id -cmatch '^(.+)_(O|P)$' -and $Matches[1] -eq $s.atc_code) { $route = $Matches[2] }
            elseif ($s.name -match '(?i)\(\s*i\.\s*v\.\s*\)') { $route = 'P' }
            elseif ($s.name -match '(?i)\(\s*oral\s*\)') { $route = 'O' }
            $candidates = if ($whoByAtc.ContainsKey($s.atc_code)) { @($whoByAtc[$s.atc_code]) } else { @() }
            if ($route -ne '') { $candidates = @($candidates | Where-Object { $_.Route -eq $route }) }
            if ($candidates.Count -gt 1) {
                $narrower = @($candidates | Where-Object { $_.Route -eq '' })
                if ($narrower.Count -eq 1) { $candidates = $narrower }
                else {
                    $byName = @($candidates | Where-Object { $_.Name -eq (ConvertTo-NormalizedSubstanceName $s.name) })
                    if ($byName.Count -eq 1) { $candidates = $byName }
                }
            }
            if ($candidates.Count -ne 1) {
                $script:NotIn2025.Add("$($s.id) ($($s.name)) route '$route' candidates $($candidates.Count)")
            } elseif ($s.aware_category -cne $candidates[0].Row.category) {
                $script:CategoryDiffers.Add("$($s.id) : NeoIPC '$($s.aware_category)', 2025 classification '$($candidates[0].Row.category)'")
            }
        }
    }

    It 'keeps the substance table from silently shrinking' {
        # The walk below cross-references only the rows it is handed: a substance row deleted here
        # deletes its own guard, so the floor is asserted before the walk's result is read.
        $script:Substances.Count | Should -BeGreaterOrEqual 244 -Because 'every removed option removes its own category check with it; the 244 committed options are the floor'
    }

    It 'holds the extract at the 268 entries of the 2025 classification worksheet' {
        $script:Classification2025.Count | Should -Be 268 -Because 'README.md promises all 268 entries of B09489-eng.xlsx, and the edition is fixed — a silent loss of an extract row breaks that promise'
    }

    It 'places every substance in exactly one of the three AWaRe categories' {
        $script:Uncategorized.Count | Should -Be 0 -Because ('substances without an AWaRe category drop out of every WHO_AWARE option group silently: ' + ($script:Uncategorized -join ' | '))
    }

    It 'holds every substance in the AWaRe category the 2025 classification gives it' {
        $script:NotIn2025.Count | Should -Be 0 -Because ('substances the committed 2025 extract has no row for: ' + ($script:NotIn2025 -join ' | '))
        $script:CategoryDiffers.Count | Should -Be 0 -Because ('categories that differ from the 2025 classification: ' + ($script:CategoryDiffers -join ' | '))
    }

    It 'cites the 2025 AWaRe edition and its DOI in the README attribution' {
        $script:Readme | Should -Match 'B09489' -Because 'the README must carry WHO''s suggested citation of the edition the list follows'
    }

    It 'names the 2025 AWaRe edition as the derivation in LICENSE.md' {
        $script:License | Should -Match 'B09489' -Because 'the licence note names the derivative''s source edition'
    }

    It 'names the 2025 AWaRe edition in the Core Protocol colophon' {
        $script:Colophon | Should -Match 'B09489' -Because 'the colophon''s antibiotics appendix clause names the edition compiled into the protocol'
    }

    It 'keeps the 2021 edition''s document code and publication URL out of README, LICENSE, and the colophon' {
        foreach ($pair in @(@('README.md', $script:Readme), @('LICENSE.md', $script:License), @('the colophon', $script:Colophon))) {
            $pair[1] | Should -Not -Match 'EML/2021\.04' -Because "$($pair[0]) follows one AWaRe edition, the 2025 one"
            $pair[1] | Should -Not -Match '2021-aware-classification' -Because "$($pair[0]) follows one AWaRe edition, the 2025 one"
        }
    }
}
