#Requires -Version 7.6

<#
.SYNOPSIS
    Pester tests for the shared gettext catalogue header contract.

.DESCRIPTION
    Four writers produced the catalogues under po/ — po4a (corrected by scripts/Invoke-Localization.ps1),
    scripts/update-glossary-po.py, and the two exporters in this module. They drifted into eight different
    comment-block shapes, three spellings of the copyright line (one ASCII-transliterated), and a header
    serialised onto a single physical line, and nothing noticed: the whole suite passed both before and after
    the header was changed, because no test asserted it.

    The glossary catalogues are now checked here rather than produced here: they became Weblate's, so the
    generator writes only its own template's header and Weblate writes theirs. That makes the last Describe
    the only thing standing between a Weblate-side header change and the contract.

    These tests are that assertion. The last Describe is the one that matters most — it checks the COMMITTED
    files rather than the writers, so a catalogue that drifts by any route at all is caught, including a hand
    edit and a writer nobody remembered to update.

.EXAMPLE
    Invoke-Pester -Path scripts/modules/NeoIPC-Tools/Tests/PoHeader.Tests.ps1
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..') -Force

InModuleScope 'NeoIPC-Tools' {

    BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
        $script:catalogues = @(
            Get-ChildItem -LiteralPath (Join-Path $script:repoRoot 'po') -File |
                Where-Object { $_.Name -match '\.pot?$' }
            Get-ChildItem -LiteralPath (Join-Path $script:repoRoot 'scripts' 'po') -File |
                Where-Object { $_.Name -match '\.pot?$' }
        )
        # The header comment block plus the fields of the empty-msgid entry, as written.
        function Get-CatalogueHeader {
            param([Parameter(Mandatory)][string]$Path)
            $lines = ((Get-Content -LiteralPath $Path -Raw) -replace "`r`n", "`n") -split "`n"
            $i = [array]::IndexOf($lines, 'msgid ""')
            if ($i -lt 0) { return $null }
            $fields = [ordered]@{}
            $raw = @()
            $j = $i + 2
            while ($j -lt $lines.Count -and $lines[$j].StartsWith('"')) {
                $raw += $lines[$j]
                if ($lines[$j] -match '^"([A-Za-z-]+):\s?(.*?)\\n"$') { $fields[$Matches[1]] = $Matches[2] }
                $j++
            }
            [pscustomobject]@{
                Path = $Path; Name = (Split-Path $Path -Leaf)
                Comment = @($lines[0..($i - 1)]); Fields = $fields; RawFieldLines = $raw
                IsTemplate = $Path.EndsWith('.pot')
            }
        }
    }

    Describe 'Write-NeoIPCPoHeader — the contract' {
        It 'renders a template: language-less title, Language en, POT-Creation-Date, no Plural-Forms' {
            $h = Write-NeoIPCPoHeader -Product 'NeoIPC Surveillance Reports' -License 'MIT' -PotCreationDate '2026-07-29 12:00+0200'
            $h | Should -Match '(?m)^# Translations for the NeoIPC Surveillance Reports$'
            $h | Should -Match '(?m)^"Language: en\\n"$'
            $h | Should -Match '(?m)^"POT-Creation-Date: 2026-07-29 12:00\+0200\\n"$'
            $h | Should -Not -Match 'Plural-Forms'
        }
        It 'renders a catalogue: per-language title, that language plural rule, no POT-Creation-Date' {
            $h = Write-NeoIPCPoHeader -Product 'NeoIPC Surveillance Reports' -License 'MIT' -Locale 'fr'
            $h | Should -Match '(?m)^# French translations for the NeoIPC Surveillance Reports$'
            $h | Should -Match '(?m)^"Language: fr\\n"$'
            $h | Should -Match '(?m)^"Plural-Forms: nplurals=2; plural=n > 1;\\n"$'
            $h | Should -Not -Match 'POT-Creation-Date'
        }
        It 'omits every field that cannot stay true' {
            # Each was correct when written and silently wrong afterwards; see Private/PoHeader.ps1.
            $h = Write-NeoIPCPoHeader -Product 'P' -License 'L' -Locale 'de'
            foreach ($absent in 'Project-Id-Version', 'Last-Translator', 'X-Generator') {
                $h | Should -Not -Match $absent
            }
        }
        It 'puts the bare # below the licence and above the contributors' {
            # Load-bearing: translate-toolkit preserves everything before the first contributor line and drops
            # an empty line after them, so contributors above the # would delete it on Weblate's next write.
            $h = Write-NeoIPCPoHeader -Product 'P' -License 'L' -Locale 'de' -Contributor @('A B <a@b.de>, 2025.')
            $comment = @(($h -split "`n") | Where-Object { $_.StartsWith('#') -or $_ -eq '#' })
            $comment[3] | Should -BeExactly '#'
            $comment[4] | Should -BeExactly '# A B <a@b.de>, 2025.'
        }
        It 'refuses a contributor line translate-toolkit would not recognise' {
            # Without an e-mail AND a year it is read as a preline, and the add-on appends a duplicate person.
            # Fixtures are invented identities. A real contributor's name and address belong in a catalogue's
            # attribution lines, which is the only place the guardrail permits them — never in test data.
            { Write-NeoIPCPoHeader -Product 'P' -License 'L' -Locale 'de' -Contributor @('A Translator') } |
                Should -Throw '*duplicate*'
            { Write-NeoIPCPoHeader -Product 'P' -License 'L' -Locale 'de' -Contributor @('A Translator <a@example.org>') } |
                Should -Throw '*duplicate*'
        }
        It 'refuses an unknown locale rather than inventing a language name' {
            { Write-NeoIPCPoHeader -Product 'P' -License 'L' -Locale 'zz' } | Should -Throw '*zz*'
        }
    }

    Describe 'Both module exporters render the same header' {
        It 'produces byte-identical headers for the same product, licence and locale' {
            # The two exporters used to carry their own copies, which is how they drifted apart.
            $meta = [System.Collections.Generic.List[object]]::new()
            $meta.Add([ordered]@{ Msgctxt = 'a/b/NAME'; Msgid = 'x'; Msgstr = ''; Fuzzy = $false; Priority = 100 })
            $abx = [System.Collections.Generic.List[object]]::new()
            $abx.Add([ordered]@{ Msgid = 'x'; Msgstr = ''; Fuzzy = $false })
            $headerOf = { param($t) (($t -split "`n") | Select-Object -First 4) -join "`n" }
            $m = & $headerOf (Write-NeoIPCMetadataPoText -Entry $meta)
            $a = & $headerOf (Write-NeoIPCAntibioticPoText -Entry $abx)
            # Only the product and licence differ; the shape must not.
            ($m -split "`n").Count | Should -Be ($a -split "`n").Count
            ($m -split "`n")[3] | Should -BeExactly '#'
            ($a -split "`n")[3] | Should -BeExactly '#'
        }
    }

    Describe 'Test-NeoIPCPoNonHumanIdentity — the shared exclusion list' {
        It 'excludes every non-human identity observed in this repository' {
            $nonHuman = @(
                '# Anonymous <noreply@weblate.org>, 2026.'
                '# Weblate (bot) <noreply@weblate.org>, 2026.'
                '# Hosted Weblate <hosted@weblate.org>, 2026.'
                '# Prefill add-on <noreply-addon-prefill@weblate.org>, 2026.'
                '# Languages add-on <noreply-addon-languages@weblate.org>, 2026.'
                '# Claude <noreply@anthropic.com>, 2026.'
                '# GitHub <noreply@github.com>, 2026.'
                '# FIRST AUTHOR <EMAIL@ADDRESS>'
                '# FULL NAME <EMAIL@ADDRESS>'
            )
            foreach ($line in $nonHuman) {
                Test-NeoIPCPoNonHumanIdentity -AuthorLine $line | Should -BeTrue -Because "'$line' is not a person"
            }
        }
        It 'keeps a person' {
            # Invented identities on purpose. The rule under test is "is this address excluded", which a real
            # contributor's address exercises no better — and a person's name and address belong in a
            # catalogue's attribution lines, not in test data. The two below differ in domain so neither the
            # excluded-domain nor the excluded-address branch can pass this by accident.
            foreach ($line in '# A Translator <a.translator@example.org>, 2025.', '# Another <another@example.net>, 2026.') {
                Test-NeoIPCPoNonHumanIdentity -AuthorLine $line | Should -BeFalse -Because "'$line' is a person"
            }
        }
        It 'matches on the address, not the display name' {
            # One address in this repository carries two different display names, so a name-keyed list would
            # exclude one and silently credit the other.
            Test-NeoIPCPoNonHumanIdentity -AuthorLine '# Someone Entirely New <noreply@weblate.org>, 2026.' |
                Should -BeTrue
        }
    }

    Describe 'Every committed catalogue conforms to the contract' {
        # This is the check that would have caught the drift: it tests the FILES, so it holds regardless of
        # which writer produced them, including a hand edit.
        It 'finds catalogues to check' {
            $script:catalogues.Count | Should -BeGreaterThan 50
        }
        It 'carries no field that cannot stay true' {
            $bad = foreach ($f in $script:catalogues) {
                $h = Get-CatalogueHeader -Path $f.FullName
                foreach ($absent in 'Project-Id-Version', 'Last-Translator', 'X-Generator') {
                    if ($h.Fields.Contains($absent)) { "$($h.Name): $absent" }
                }
            }
            $bad | Should -BeNullOrEmpty
        }
        It 'keeps POT-Creation-Date in templates only' {
            $bad = foreach ($f in $script:catalogues) {
                $h = Get-CatalogueHeader -Path $f.FullName
                if (-not $h.IsTemplate -and $h.Fields.Contains('POT-Creation-Date')) { "$($h.Name): has it" }
                if ($h.IsTemplate -and -not $h.Fields.Contains('POT-Creation-Date')) { "$($h.Name): lacks it" }
            }
            $bad | Should -BeNullOrEmpty
        }
        It 'credits no non-human identity' {
            $bad = foreach ($f in $script:catalogues) {
                $h = Get-CatalogueHeader -Path $f.FullName
                foreach ($line in $h.Comment) {
                    if (Test-NeoIPCPoNonHumanIdentity -AuthorLine $line) { "$($h.Name): $line" }
                }
            }
            $bad | Should -BeNullOrEmpty
        }
        It 'spells the copyright line identically everywhere' {
            # One variant was ASCII-transliterated (Charite - Universitaetsmedizin), which a classifier that
            # bucketed lines by keyword hid completely.
            $variants = @($script:catalogues | ForEach-Object {
                    (Get-CatalogueHeader -Path $_.FullName).Comment | Where-Object { $_ -like '*opyright*' }
                } | Sort-Object -Unique)
            $variants | Should -HaveCount 1
            $variants[0] | Should -BeExactly '# Copyright (C) Charité – Universitätsmedizin Berlin'
        }
        It 'ends the fixed part of every comment block with a bare #' {
            $bad = foreach ($f in $script:catalogues) {
                $h = Get-CatalogueHeader -Path $f.FullName
                if ($h.Comment.Count -lt 4 -or $h.Comment[3] -ne '#') { "$($h.Name): line 4 is '$($h.Comment[3])'" }
            }
            $bad | Should -BeNullOrEmpty
        }
        It 'serialises every header as continuation lines, none wrapped' {
            # scripts.pot put the whole header on one msgstr line; metadata.de.po wrapped Language-Team.
            $bad = foreach ($f in $script:catalogues) {
                $h = Get-CatalogueHeader -Path $f.FullName
                if (-not $h) { "$($f.Name): no header entry" ; continue }
                foreach ($line in $h.RawFieldLines) {
                    if ($line -notmatch '^"[A-Za-z-]+:') { "$($h.Name): continued line $line" }
                }
            }
            $bad | Should -BeNullOrEmpty
        }
        It 'gives every catalogue a language and every template Language: en' {
            $bad = foreach ($f in $script:catalogues) {
                $h = Get-CatalogueHeader -Path $f.FullName
                $lang = $h.Fields['Language']
                if ($h.IsTemplate) { if ($lang -ne 'en') { "$($h.Name): template Language '$lang'" } }
                elseif (-not $lang) { "$($h.Name): empty Language" }
            }
            $bad | Should -BeNullOrEmpty
        }
    }
}
