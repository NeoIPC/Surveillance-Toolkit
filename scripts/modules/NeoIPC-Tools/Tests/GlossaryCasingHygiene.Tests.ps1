#Requires -Version 7.6
#requires -Module Pester

<#
.SYNOPSIS
    Pester gate for the derived sentence-case forms of glossary terms.

.DESCRIPTION
    Casing is a rendering concern, so glossary.yaml holds one key per term and the `_sc` form is derived
    by get_string_resources() rather than translated a second time. Two things have to hold for that to
    be an improvement rather than a regression:

    - the derived form must reproduce what the retired keys held, or the deletion lost information;
    - only the FIRST character may be touched. stringr's str_to_sentence() and str_to_title() are the
      obvious-looking tools and both are wrong here, because they normalise the whole string and this
      glossary is largely abbreviations.

    Turkish is what makes the locale argument load-bearing: `i` uppercases to `İ` (U+0130), and base
    toupper() produces a plain `I` unless the process locale is Turkish - which a container rendering
    nine languages is not. The assertion names the codepoint, because a test that only checked "the
    first letter is capitalised" would pass on the wrong character.

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
            'the sentence-case form is derived from the base term rather than stored beside it')
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
  function(k) !identical(sentence_case(glossary[[k]], "de"), want[[k]]), logical(1))]
cat(if (length(bad)) paste(bad, collapse = ",") else "all reproduced")
'@
            Invoke-RSnippet $body | Should -BeExactly 'all reproduced'
        }

        It 'uppercases Turkish i to the dotted capital, which toupper does not' {
            Invoke-RSnippet 'cat(sentence_case("izleme", "tr"))' |
                Should -BeExactly "$([char]0x0130)zleme" -Because 'toupper() yields a plain I outside a Turkish locale'
        }

        It 'leaves a caseless script alone without needing a special case' {
            Invoke-RSnippet 'cat(sentence_case("निगरानी", "ne"))' |
                Should -BeExactly ([char]0x0928 + [char]0x093f + [char]0x0917 + [char]0x0930 + [char]0x093e + [char]0x0928 + [char]0x0940)
        }

        It 'touches only the first character, leaving abbreviations intact' {
            # This is what rules out str_to_sentence() and str_to_title(): they would render these as
            # "Primary sepsis/bsi" and "Aware". Both terms ship in reports, so the damage would be
            # visible to a clinician rather than theoretical.
            Invoke-RSnippet 'cat(sentence_case("primary sepsis/BSI", "en"), "|", sentence_case("AWaRe", "en"))' |
                Should -BeExactly 'Primary sepsis/BSI | AWaRe'
        }
    }
}
