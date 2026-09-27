#Requires -Version 7.6
#requires -Module Pester

<#
.SYNOPSIS
    Pester tests for how the reports read their string resources and how the Validation Report turns a
    finding into a sentence.

.DESCRIPTION
    No CI job renders a report, so the code between the string resources and the rendered text is
    exercised nowhere else. Two parts:

    - The YAML handlers every string resource is read with (string_resource_handlers() in
      reports/common/helpers.R). A translated label such as Yes reaches the catalogue unquoted, and
      YAML 1.1 would read it as a logical.
    - The Validation Report's formatter (_problem_text.qmd with the tables of _mapping.qmd): the
      fallback that shows a stored code where its name is missing, the label a decoration looks up,
      and the choice of a rule's second sentence.

    The report's own setup checks call neoipcr, which no CI runner installs; they are not covered here.

.EXAMPLE
    Invoke-Pester -Path scripts/modules/NeoIPC-Tools/Tests/ReportStringResources.Tests.ps1
#>

BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    $rscript = (Get-Command Rscript -ErrorAction SilentlyContinue)?.Source

    # Runs an R snippet from the Validation Report's directory, where the string-resource cascade resolves
    # its relative paths, with helpers.R, the English string resources and the formatter loaded. Returns
    # its stdout.
    function Invoke-ValidationReportSnippet {
        param([string]$Body)
        $prelude = @'
source("../common/helpers.R")
localeObj <- list(language = "en", territory = NULL)
sR <- get_string_resources(localeObj)
purled <- function(qmd) {
  out <- tempfile(fileext = ".R")
  knitr::purl(qmd, output = out, quiet = TRUE)
  out
}
source(purled("_mapping.qmd"))
source(purled("_problem_text.qmd"))
'@
        $file = New-TemporaryFile
        try {
            [System.IO.File]::WriteAllText($file.FullName, "$prelude`n$Body",
                [System.Text.UTF8Encoding]::new($false))
            Push-Location (Join-Path $repoRoot 'reports' 'Validation-Report')
            try { (& $rscript --vanilla $file.FullName 2>&1) -join "`n" } finally { Pop-Location }
        } finally {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Report string resources' -Skip:(-not $env:CI -and -not (Get-Command Rscript -ErrorAction SilentlyContinue)) {

    It 'reads a bare yes, no, on, off, y or n as text and only true and false as logicals' {
        $body = @'
parsed <- yaml::yaml.load(
  "a: Yes\nb: no\nc: on\nd: OFF\ne: y\nf: n\ng: true\nh: False\ni: TRUE",
  handlers = string_resource_handlers())
cat(vapply(parsed, function(value) paste(class(value), format(value)), character(1)), sep = "|")
'@
        Invoke-ValidationReportSnippet $body | Should -BeExactly (
            'character Yes|character no|character on|character OFF|character y|character n|' +
            'logical TRUE|logical FALSE|logical TRUE')
    }

    It 'shows the stored code where a substance has no name' {
        $body = @'
context <- tibble::tibble(index = 4L, substance_code = "J99XX99", substance = NA_character_, days = NA_integer_)
cat(problem_text(52L, context, sR))
'@
        Invoke-ValidationReportSnippet $body | Should -Match 'the substance is J99XX99 and its days are not available'
    }

    It 'shows the missing-value string where neither the name nor the code is recorded' {
        $body = @'
context <- tibble::tibble(index = 2L, substance_code = NA_character_, substance = NA_character_, days = 5L)
cat(problem_text(52L, context, sR))
'@
        Invoke-ValidationReportSnippet $body | Should -Match 'the substance is not available and its days are 5'
    }

    It 'renders the label a decoration looks up for a recorded code' {
        $body = @'
context <- tibble::tibble(sec_bsi = factor("0", levels = c("1", "0", "-1")), organisms = 2L)
cat(problem_text(55L, context, sR))
'@
        Invoke-ValidationReportSnippet $body | Should -Match "item is 'No', but the number"
    }

    It 'renders the second sentence for a secondary-BSI item that was never answered' {
        $body = @'
context <- tibble::tibble(sec_bsi = factor(NA, levels = c("1", "0", "-1")), organisms = 2L)
cat(problem_text(55L, context, sR))
'@
        $text = Invoke-ValidationReportSnippet $body
        $text | Should -Match 'item has not been answered, but the number'
        $text | Should -Not -Match 'not available'
    }

    It 'falls back to the missing-value string for a code the label map does not carry' {
        $body = @'
context <- tibble::tibble(sec_bsi = factor("9", levels = c("9")), organisms = 2L)
cat(problem_text(55L, context, sR))
'@
        Invoke-ValidationReportSnippet $body | Should -Match "item is 'not available', but the number"
    }
}
