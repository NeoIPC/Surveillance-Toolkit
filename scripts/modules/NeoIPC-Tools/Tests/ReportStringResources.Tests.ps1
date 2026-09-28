#Requires -Version 7.6
#requires -Module Pester

<#
.SYNOPSIS
    Pester tests for how the reports read their string resources, how the Validation Report turns a
    finding into a sentence, and how the Partner and Reference Reports label their reconciliation rows.

.DESCRIPTION
    No CI job renders a report, so the code between the string resources and the rendered text is
    exercised nowhere else. Four parts:

    - The YAML handlers every string resource is read with (string_resource_handlers() in
      reports/common/helpers.R). A translated label such as Yes reaches the catalogue unquoted, and
      YAML 1.1 would read it as a logical.
    - The income-class labels the Partner and Reference Reports look up for a class code, whose keys
      name the class rather than repeat the code.
    - The Validation Report's formatter (_problem_text.qmd with the tables of _mapping.qmd): the
      fallback that shows a stored code where its name is missing, the label a decoration looks up,
      and the choice of a rule's second sentence.
    - The rows of the reconciliation summary table in the Partner and Reference Reports
      (reconciliation_summary_rows() in reports/common/helpers.R, which the gt formatter wraps and CI
      cannot run, since its R has no gt): a label per reconciliation id and a fallback for an id
      without one, the record kinds, when the reported column shows, and when the table gives way to
      a sentence.

    The report's own setup checks call neoipcr, which no CI runner installs; they are not covered here.

.EXAMPLE
    Invoke-Pester -Path scripts/modules/NeoIPC-Tools/Tests/ReportStringResources.Tests.ps1
#>

BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    $rscript = (Get-Command Rscript -ErrorAction SilentlyContinue)?.Source

    # Runs an R snippet from a report's directory, where the string-resource cascade resolves its
    # relative paths, with helpers.R and that report's English string resources loaded. Returns its
    # stdout.
    function Invoke-ReportSnippet {
        param([string]$Report, [string]$Body)
        $prelude = @'
source("../common/helpers.R")
localeObj <- list(language = "en", territory = NULL)
sR <- get_string_resources(localeObj)
'@
        $file = New-TemporaryFile
        try {
            [System.IO.File]::WriteAllText($file.FullName, "$prelude`n$Body",
                [System.Text.UTF8Encoding]::new($false))
            Push-Location (Join-Path $repoRoot 'reports' $Report)
            try { (& $rscript --vanilla $file.FullName 2>&1) -join "`n" } finally { Pop-Location }
        } finally {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
        }
    }

    # Runs an R snippet from the Validation Report's directory, with its formatter loaded besides.
    function Invoke-ValidationReportSnippet {
        param([string]$Body)
        $formatter = @'
purled <- function(qmd) {
  out <- tempfile(fileext = ".R")
  knitr::purl(qmd, output = out, quiet = TRUE)
  out
}
source(purled("_mapping.qmd"))
source(purled("_problem_text.qmd"))
'@
        Invoke-ReportSnippet -Report 'Validation-Report' -Body "$formatter`n$Body"
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

    It 'labels every income class by its code, and shows an unknown code as it is' {
        $body = @'
cat(get_localised_world_bank_class_names(c("H", "UM", "LM", "L", "XX")), sep = "|")
cat("\n")
countries <- tibble::tibble(name = c("A", "B", "C"), wb_class = c("L M", "H", "XX"))
cat(format_countries(countries))
'@
        $text = Invoke-ValidationReportSnippet $body
        $text | Should -Match '^High income\|Upper middle income\|Lower middle income\|Low income\|XX'
        $text | Should -Match 'High income: \*B\*'
        $text | Should -Match 'Lower middle income: \*A\*'
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

Describe 'Reconciliation summary rows' -Skip:(-not $env:CI -and -not (Get-Command Rscript -ErrorAction SilentlyContinue)) {

    BeforeAll {
        # A reconciliation summary shaped as neoipcr's import writes it: one row per reconciliation, with
        # the record kind each counts.
        # The labels are spelled out key by key rather than read back through reconciliation_labels(), so
        # that a label mapped to the wrong id fails here instead of passing against itself.
        $fixture = @'
reconciliation_summary <- function(
    repaired, reported, ids = seq_len(6L),
    kinds = c("enrollments", "events", "patients", "patients", "events", "events"))
  tibble::tibble(
    reconciliation_id = ids,
    record_kind       = factor(kinds, levels = unique(c("patients", "enrollments", "events", kinds))),
    n_repaired        = as.integer(repaired),
    n_reported        = as.integer(reported))
reconciliation_strings <- sR$`tbl-reconciliation-summary`$reconciliations
expected_labels <- c(
  reconciliation_strings$admission_day_of_life,
  reconciliation_strings$form_day_of_life,
  reconciliation_strings$gestation_days_from_text,
  reconciliation_strings$implausible_gestation_days,
  reconciliation_strings$ssi_secondary_bsi_agents,
  reconciliation_strings$culture_negative_sepsis_agents)
'@

        function Invoke-ReconciliationSnippet {
            param([string]$Body)
            Invoke-ReportSnippet -Report 'Partner-Report' -Body "$fixture`n$Body"
        }
    }

    It 'labels every reconciliation and names the kind of record it counts' {
        $body = @'
rows <- reconciliation_summary_rows(
  list(reconciliation_summary(c(2, 5, 0, 1, 0, 3), rep(0, 6))), sR)
cat(names(rows), sep = "|"); cat("\n")
cat(rows$records, sep = "|"); cat("\n")
cat(rows$repaired_1, sep = "|"); cat("\n")
cat(identical(rows$label, expected_labels), length(expected_labels) == 6L,
    all(nzchar(expected_labels)), !anyDuplicated(expected_labels), sep = "|")
'@
        Invoke-ReconciliationSnippet $body | Should -BeExactly (@(
            'label|records|repaired_1'
            'Patient admissions|Forms|Patient records|Patient records|Forms|Forms'
            '2|5|0|1|0|3'
            'TRUE|TRUE|TRUE|TRUE') -join "`n")
    }

    It 'orders the rows by reconciliation id whatever order the summaries hold them in' {
        # The first dataset lacks reconciliation 3, so a join on it appends that row last, and both
        # arrive in reverse order.
        $body = @'
own <- reconciliation_summary(
  c(1, 2, 0, 4, 5), rep(0, 5), ids = c(1L, 2L, 4L, 5L, 6L),
  kinds = c("enrollments", "events", "patients", "events", "events"))[5:1, ]
ref <- reconciliation_summary(c(1, 2, 3, 0, 4, 5), rep(0, 6))[6:1, ]
rows <- reconciliation_summary_rows(list(own = own, ref = ref), sR)
cat(identical(rows$label, expected_labels)); cat("\n")
cat(rows$repaired_1, sep = "|"); cat("\n")
cat(rows$repaired_2, sep = "|")
'@
        Invoke-ReconciliationSnippet $body | Should -BeExactly (@(
            'TRUE'
            '1|2|NA|0|4|5'
            '1|2|3|0|4|5') -join "`n")
    }

    It 'shows the reported counts of every dataset once any dataset reported a record' {
        $body = @'
own <- reconciliation_summary(c(1, 0, 0, 0, 0, 0), rep(0, 6))
ref <- reconciliation_summary(c(4, 2, 0, 0, 1, 3), c(0, 0, 0, 0, 0, 2))
rows <- reconciliation_summary_rows(list(own = own, ref = ref), sR)
cat(names(rows), sep = "|"); cat("\n")
cat(rows$reported_1, sep = "|"); cat("\n")
cat(rows$reported_2, sep = "|")
'@
        Invoke-ReconciliationSnippet $body | Should -BeExactly (@(
            'label|records|repaired_1|reported_1|repaired_2|reported_2'
            '0|0|0|0|0|0'
            '0|0|0|0|0|2') -join "`n")
    }

    It 'gives way to a sentence only when every count is zero, and keeps a count it could not take' {
        $body = @'
zeros <- reconciliation_summary(rep(0, 6), rep(0, 6))
cat(is.null(reconciliation_summary_rows(list(zeros), sR))); cat("\n")
unread <- reconciliation_summary(c(NA, NA, 0, 0, NA, NA), c(NA, NA, 0, 0, NA, NA))
rows <- reconciliation_summary_rows(list(unread), sR)
cat(names(rows), sep = "|"); cat("\n")
cat(rows$repaired_1, sep = "|")
'@
        Invoke-ReconciliationSnippet $body | Should -BeExactly (@(
            'TRUE'
            'label|records|repaired_1'
            'NA|NA|0|0|NA|NA') -join "`n")
    }

    It 'labels a reconciliation without a label by its number, and a record kind without one by its name' {
        $body = @'
newer <- reconciliation_summary(
  c(0, 3), c(0, 0), ids = c(1L, 7L), kinds = c("enrollments", "departments"))
rows <- reconciliation_summary_rows(list(newer), sR)
cat(rows$label[2], rows$records[2], sep = "|")
'@
        Invoke-ReconciliationSnippet $body | Should -BeExactly 'Reconciliation 7|departments'
    }

    It 'shows no count for a reconciliation one dataset does not carry' {
        $body = @'
own <- reconciliation_summary(c(1, 0, 0, 0, 0, 0), rep(0, 6))
ref <- reconciliation_summary(
  c(1, 0, 0, 0, 0, 0, 2), rep(0, 7), ids = seq_len(7L),
  kinds = c("enrollments", "events", "patients", "patients", "events", "events", "events"))
rows <- reconciliation_summary_rows(list(own = own, ref = ref), sR)
cat(nrow(rows), rows$repaired_1[7], rows$repaired_2[7], rows$label[7], sep = "|")
'@
        Invoke-ReconciliationSnippet $body | Should -BeExactly '7|NA|2|Reconciliation 7'
    }
}
