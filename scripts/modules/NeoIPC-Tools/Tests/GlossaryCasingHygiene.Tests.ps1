#Requires -Version 7.6
#requires -Module Pester

<#
.SYNOPSIS
    Pester gate for the derived sentence-case forms of glossary terms.

.DESCRIPTION
    Casing is a rendering concern, so glossary.yaml holds one key per term and the `_sc` form is derived
    by get_string_resources() from reports/sentence-case.yaml. Two things have to hold for that to be an
    improvement rather than a regression, and neither is self-evident:

    - the derived form must reproduce what the retired keys held, or the deletion lost information;
    - the derivation must FAIL where it cannot be sure, because a wrong capital in a published clinical
      report is silent and the only safe alternative to failing is not shipping it.

    Turkish is the case that makes the second point concrete. `i` uppercases to `İ` (U+0130), and R's
    toupper() produces a plain `I` unless the process locale is Turkish - which a container rendering
    nine languages is not. A test that only checked "is the first letter capitalised" would pass on the
    wrong character, so the assertion names the codepoint.

    Skipped where R is absent; CI installs none, because rendering happens in the container repository.

.EXAMPLE
    Invoke-Pester -Path scripts/modules/NeoIPC-Tools/Tests/GlossaryCasingHygiene.Tests.ps1
#>

BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    $rscript = (Get-Command Rscript -ErrorAction SilentlyContinue)?.Source

    # Runs from a report directory, because the cascade resolves its layers by relative path.
    function Invoke-RSnippet {
        param([string]$Body)
        $prelude = @'
localeObj <- list(language = "en", territory = NULL)
source("../common/helpers.R")
rules <- yaml::read_yaml("../sentence-case.yaml")
glossary <- yaml::read_yaml("../../glossary.yaml")
'@
        $file = New-TemporaryFile
        try {
            [System.IO.File]::WriteAllText($file.FullName, "$prelude`n$Body",
                [System.Text.UTF8Encoding]::new($false))
            Push-Location (Join-Path $repoRoot 'reports' 'Partner-Report')
            try { (& $rscript --vanilla $file.FullName 2>&1) -join "`n" } finally { Pop-Location }
        } finally {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Glossary casing' {

    It 'glossary.yaml carries no casing variants' {
        $glossary = Join-Path $repoRoot 'glossary.yaml'
        $variants = Select-String -LiteralPath $glossary -Pattern '^[a-z0-9_]+_(sc|tc)\s*:' |
            ForEach-Object { $_.Line -replace ':.*' }
        ($variants | Out-String).Trim() | Should -BeExactly '' -Because (
            'casing is derived from the base term; an override belongs in reports/sentence-case.yaml')
    }

    It 'every target language has a declared sentence-case rule' {
        # The languages the pipeline actually builds, read from po4a's own list rather than restated
        # here, so adding a language cannot leave this test asserting the old set.
        $cfg = Get-Content -LiteralPath (Join-Path $repoRoot 'po' 'reports.po4a.cfg') -Raw
        # po4a lists the TARGET languages, so the source language is absent from it — and a default
        # render resolves its locale exactly as a translated one does, so it needs a rule just the same.
        # Reading only po4a's list is how the missing 'en' entry got past this test once already.
        $langs = @('en') + (([regex]::Match($cfg, '(?m)^\[po4a_langs\]\s*(.+)$').Groups[1].Value -split '\s+') |
            Where-Object { $_ })
        $declared = Select-String -LiteralPath (Join-Path $repoRoot 'reports' 'sentence-case.yaml') `
            -Pattern '^([a-z]{2}):' | ForEach-Object { $_.Matches[0].Groups[1].Value }
        $missing = $langs | Where-Object { $_ -notin $declared }
        ($missing -join ', ') | Should -BeExactly '' -Because (
            'an undeclared language stops the render, so it must be declared before it is built')
    }

    Context 'derivation' -Skip:(-not (Get-Command Rscript -ErrorAction SilentlyContinue)) {

        It 'reproduces every sentence-case form the retired keys held' {
            # The exact English values deleted from glossary.yaml. If the derivation cannot reproduce
            # them, the deletion lost information rather than relocating it.
            $body = @'
want <- list(admission = "Admission", antibiotics = "Antibiotics", human_milk = "Human milk",
             kangaroo_care = "Kangaroo care",
             necrotizing_enterocolitis = "Necrotizing enterocolitis", pneumonia = "Pneumonia",
             primary_sepsis_bsi = "Primary sepsis/BSI", surgical_procedure = "Surgical procedure",
             surgical_site_infection = "Surgical site infection", surveillance = "Surveillance",
             surveillance_end = "Surveillance end")
bad <- names(want)[vapply(names(want),
  function(k) !identical(sentence_case(glossary[[k]], "de", rules, key = k), want[[k]]), logical(1))]
cat(if (length(bad)) paste(bad, collapse = ",") else "all reproduced")
'@
            Invoke-RSnippet $body | Should -BeExactly 'all reproduced'
        }

        It 'uppercases Turkish i to the dotted capital, which toupper does not' {
            # Names the codepoint rather than asserting "the first letter is capitalised", because
            # toupper() also capitalises it — to the WRONG character. U+0130 is the whole point, and it
            # only appears if the locale is actually threaded through to ICU.
            Invoke-RSnippet 'cat(sentence_case("izleme", "tr", rules))' |
                Should -BeExactly "$([char]0x0130)zleme" -Because 'toupper() yields a plain I outside a Turkish locale'
        }

        It 'touches only the first character, leaving abbreviations intact' {
            # str_to_sentence() and str_to_title() are the obvious-looking tools and both are wrong here:
            # they normalise the whole string, so "primary sepsis/BSI" becomes "Primary sepsis/bsi" and
            # "AWaRe" becomes "Aware". This asserts the terms that would expose either.
            Invoke-RSnippet 'cat(sentence_case("primary sepsis/BSI", "en", rules), "|",
                                 sentence_case("AWaRe", "en", rules))' |
                Should -BeExactly 'Primary sepsis/BSI | AWaRe'
        }

        It 'leaves a caseless script alone' {
            Invoke-RSnippet 'cat(sentence_case("निगरानी", "ne", rules))' |
                Should -BeExactly ([char]0x0928 + [char]0x093f + [char]0x0917 + [char]0x0930 + [char]0x093e + [char]0x0928 + [char]0x0940)
        }

        It 'fails for a language with no declared rule' {
            Invoke-RSnippet 'cat(tryCatch(sentence_case("x", "zz", rules), error = function(e) "REFUSED"))' |
                Should -BeExactly 'REFUSED'
        }

        It 'fails for a term that does not begin with a letter' {
            # The Afrikaans article 'n takes the capital on the following word, so capitalising the
            # first character is the wrong answer rather than an approximate one.
            Invoke-RSnippet 'cat(tryCatch(sentence_case("''n boek", "af", rules), error = function(e) "REFUSED"))' |
                Should -BeExactly 'REFUSED'
        }
    }
}
