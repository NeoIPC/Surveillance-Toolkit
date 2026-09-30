#Requires -Version 7.6
#requires -Module Pester

<#
.SYNOPSIS
    Pester tests for how the reports read their string resources, how the Validation Report turns a
    finding into a sentence, and how the Partner and Reference Reports build their data-validation
    summary tables.

.DESCRIPTION
    No CI job renders a report, so the code between the string resources and the rendered text is
    exercised nowhere else. Seven parts:

    - The YAML handlers every string resource is read with (string_resource_handlers() in
      reports/common/helpers.R). A translated label such as Yes reaches the catalogue unquoted, and
      YAML 1.1 would read it as a logical.
    - The income-class labels the Partner and Reference Reports look up for a class code, whose keys
      name the class rather than repeat the code.
    - The Validation Report's formatter (_problem_text.qmd with the tables of _mapping.qmd): the
      fallback that shows a stored code where its name is missing, the label a decoration looks up,
      and the choice of a rule's second sentence.
    - The address the Validation Report's patient links start from (get_tracker_capture_base() in
      reports/common/helpers.R): which public addresses it takes and what base each yields, which it
      refuses without repeating them, and the fallback to the address the data is read from.
    - The rows of the reconciliation summary table in the Partner and Reference Reports
      (reconciliation_summary_rows() in reports/common/helpers.R, which the gt formatter wraps): a
      label per reconciliation id and a fallback for an id without one, the record kinds, when the
      reported column shows, and when the table gives way to a sentence. Beside them, the check that
      holds those labels to the ids neoipcr applies, given the ids, and which of the Partner Report's
      two datasets its summary tables show, with the sentence for each dataset that has no summary
      and the one that names the datasets shown when they count nothing.
    - The sentence a report shows in a table's place (no_data_table()): escaped for the LaTeX the PDF
      gets, and for the Markdown every other format reads it from, Word included. Where Pandoc is
      installed, a test also has Pandoc read that Markdown.
    - The gt formatters of both summary tables: the dash and the note for a missing count, the font
      size and the column widths, and the column groups. CI's R has no gt, so this part runs only
      where gt is installed and is skipped elsewhere; the parts above need no gt.

    The report's own setup checks that call neoipcr, which no CI runner installs, are not covered here.

.EXAMPLE
    Invoke-Pester -Path scripts/modules/NeoIPC-Tools/Tests/ReportStringResources.Tests.ps1
#>

BeforeDiscovery {
    # Whether R can load gt, which only the summary-table formatters need.
    $rscriptPath = (Get-Command Rscript -ErrorAction SilentlyContinue)?.Source
    $hasGt = [bool]$rscriptPath -and
        ((& $rscriptPath --vanilla -e 'cat(requireNamespace("gt", quietly = TRUE))' 2>$null) -eq 'TRUE')
    # Whether Pandoc is installed, which only the test that has it read a sentence's Markdown needs.
    $hasPandoc = [bool](Get-Command pandoc -ErrorAction SilentlyContinue)
}

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

Describe 'The address the Validation Report links its patients to' -Skip:(-not $env:CI -and -not (Get-Command Rscript -ErrorAction SilentlyContinue)) -ForEach @(@{
    # Each value is an R expression, so a value that is not a string can be given as well. Secret is a
    # password the value carries, which a refusal must not repeat any more than the value itself.
    Accepted = @(
        @{ Case = 'a host alone'; Value = '"https://neoipc.example.org"'
           Expected = 'https://neoipc.example.org/dhis-web-tracker-capture/index.html' }
        @{ Case = 'a port'; Value = '"http://localhost:8080"'
           Expected = 'http://localhost:8080/dhis-web-tracker-capture/index.html' }
        @{ Case = 'a context path'; Value = '"https://neoipc.example.org/dhis"'
           Expected = 'https://neoipc.example.org/dhis/dhis-web-tracker-capture/index.html' }
        @{ Case = 'trailing slashes'; Value = '"https://neoipc.example.org/dhis//"'
           Expected = 'https://neoipc.example.org/dhis/dhis-web-tracker-capture/index.html' }
        @{ Case = 'an upper-case scheme'; Value = '"HTTPS://neoipc.example.org"'
           Expected = 'HTTPS://neoipc.example.org/dhis-web-tracker-capture/index.html' }
        @{ Case = 'a host with an underscore'; Value = '"http://dhis2_web:8080/dhis"'
           Expected = 'http://dhis2_web:8080/dhis/dhis-web-tracker-capture/index.html' }
        @{ Case = 'an IPv4 address'; Value = '"http://192.0.2.10:8080"'
           Expected = 'http://192.0.2.10:8080/dhis-web-tracker-capture/index.html' }
        @{ Case = 'a percent-encoded path segment'; Value = '"https://neoipc.example.org/caf%C3%A9"'
           Expected = 'https://neoipc.example.org/caf%C3%A9/dhis-web-tracker-capture/index.html' }
    )
    Refused = @(
        @{ Case = 'an empty query'; Value = '"https://neoipc.example.org/dhis?"'; Defect = 'query or a fragment' }
        @{ Case = 'an empty fragment'; Value = '"https://neoipc.example.org/dhis#"'; Defect = 'query or a fragment' }
        @{ Case = 'a query'; Value = '"https://neoipc.example.org/dhis?a=1"'; Defect = 'query or a fragment' }
        @{ Case = 'a fragment'; Value = '"https://neoipc.example.org/dhis#top"'; Defect = 'query or a fragment' }
        @{ Case = 'a single slash after the scheme'; Value = '"https:/neoipc.example.org/dhis"'
           Defect = 'does not begin with' }
        @{ Case = 'no scheme'; Value = '"neoipc.example.org/dhis"'; Defect = 'does not begin with' }
        @{ Case = 'the ftp scheme'; Value = '"ftp://user:secret@neoipc.example.org/"'; Secret = '"secret"'
           Defect = 'does not begin with' }
        @{ Case = 'the javascript scheme'; Value = '"javascript:alert(1)"'; Defect = 'does not begin with' }
        @{ Case = 'an IPv6 literal'; Value = '"http://[::1]:8080/dhis"'; Defect = 'bracketed literal' }
        @{ Case = 'a parenthesis in the path'; Value = '"https://neoipc.example.org/a)b"'; Defect = 'path with a character' }
        @{ Case = 'a lone percent sign'; Value = '"https://neoipc.example.org/100%"'; Defect = 'path with a character' }
        @{ Case = 'a space in the path'; Value = '"https://neoipc.example.org/my dhis"'; Defect = 'whitespace' }
        @{ Case = 'surrounding whitespace'; Value = '" https://neoipc.example.org\n"'; Defect = 'whitespace' }
        @{ Case = 'a user name and password'; Value = '"https://admin:district@neoipc.example.org/dhis"'
           Secret = '"district"'; Defect = 'an `@`' }
        @{ Case = 'a password with a number sign'; Value = '"https://admin:S3cret#1@neoipc.example.org/dhis"'
           Secret = '"S3cret#1"'; Defect = 'an `@`' }
        @{ Case = 'a password with a slash'; Value = '"https://admin:s3/cret@neoipc.example.org/"'
           Secret = '"s3/cret"'; Defect = 'an `@`' }
        @{ Case = 'a password with a question mark'; Value = '"https://admin:s3?cret@neoipc.example.org/"'
           Secret = '"s3?cret"'; Defect = 'an `@`' }
        @{ Case = 'a password with a space'; Value = '"https://admin:s3 cret@neoipc.example.org/"'
           Secret = '"s3 cret"'; Defect = 'whitespace' }
        @{ Case = 'an at sign in the path'; Value = '"https://neoipc.example.org/a@b"'; Defect = 'an `@`' }
        @{ Case = 'port 0'; Value = '"https://neoipc.example.org:0/dhis"'; Defect = 'port that is not' }
        @{ Case = 'port 65536'; Value = '"https://neoipc.example.org:65536/dhis"'; Defect = 'port that is not' }
        @{ Case = 'a colon without a port'; Value = '"https://neoipc.example.org:/dhis"'; Defect = 'port that is not' }
        @{ Case = 'no host'; Value = '"https:///dhis"'; Defect = 'names no host' }
        @{ Case = 'a host outside ASCII'; Value = '"https://bücher.example/dhis"'; Defect = 'host that is not' }
        @{ Case = 'two values'; Value = 'c("https://a.example.org", "https://b.example.org")'
           Defect = 'not a single text value' }
        @{ Case = 'an empty sequence'; Value = 'list()'; Defect = 'not a single text value' }
        @{ Case = 'a number'; Value = '8080'; Defect = 'not a single text value' }
        @{ Case = 'a logical'; Value = 'TRUE'; Defect = 'not a single text value' }
        @{ Case = 'a missing value'; Value = 'NA_character_'; Defect = 'not a single text value' }
    )
    # Without a public address, the links start from the address the data is read from.
    FallbackAccepted = @(
        @{ Case = '/api'; Connection = 'https://data.example.org/api'
           Expected = 'https://data.example.org/dhis-web-tracker-capture/index.html' }
        @{ Case = '/api/'; Connection = 'https://data.example.org/api/'
           Expected = 'https://data.example.org/dhis-web-tracker-capture/index.html' }
        @{ Case = '/api//'; Connection = 'https://data.example.org/api//'
           Expected = 'https://data.example.org/dhis-web-tracker-capture/index.html' }
        @{ Case = '/dhis/api'; Connection = 'https://data.example.org/dhis/api'
           Expected = 'https://data.example.org/dhis/dhis-web-tracker-capture/index.html' }
        @{ Case = 'no path'; Connection = 'http://localhost:8080'
           Expected = 'http://localhost:8080/dhis-web-tracker-capture/index.html' }
        @{ Case = 'a host named api'; Connection = 'https://api'
           Expected = 'https://api/dhis-web-tracker-capture/index.html' }
        @{ Case = 'an empty public address'; Public = '""'; Connection = 'https://data.example.org/api'
           Expected = 'https://data.example.org/dhis-web-tracker-capture/index.html' }
    )
    FallbackRefused = @(
        @{ Case = 'an IPv6 literal'; Connection = 'http://[fd00::1]:8080/api'; Defect = 'bracketed literal' }
        @{ Case = 'a host outside ASCII'; Connection = 'https://bücher.example/api'; Defect = 'host that is not' }
        @{ Case = 'a query'; Connection = 'https://data.example.org/api?a=1'; Defect = 'query or a fragment' }
    )
}) {

    BeforeAll {
        # Every case runs in one R process, which prints a tab-separated line for each: its key, then
        # `ok` and the base the links start from, or the class of the condition raised, whether its
        # message repeats the value or its secret, whether it names `dhis2PublicBaseUrl`, whether it
        # says the address is the one the data is read from, whether it states the defect, and the
        # defect.
        $runner = @'
run_case <- function(key, value, connection, secret = NULL) {
  outcome <- tryCatch(
    c("ok", get_tracker_capture_base(value, list(base_url = connection))),
    neoipc_invalid_dhis2_public_base_url = function(cnd) {
      message <- conditionMessage(cnd)
      withheld <- c(if (is.character(value)) value[!is.na(value)], connection, secret)
      c(class(cnd)[1],
        any(vapply(withheld[nzchar(withheld)], grepl, logical(1), x = message, fixed = TRUE)),
        grepl("dhis2PublicBaseUrl", message, fixed = TRUE),
        grepl("address the data is read from", message, fixed = TRUE),
        grepl(cnd$defect, message, fixed = TRUE),
        cnd$defect)
    },
    error = function(cnd) c("unclassed", class(cnd)[1]))
  cat(key, outcome, sep = "\t")
  cat("\n")
}
'@
        $connection = 'https://data.example.org/api'
        $calls = @(
            foreach ($case in @($Accepted) + @($Refused)) {
                "run_case(`"given:$($case.Case)`", $($case.Value), `"$connection`", $($case.Secret ?? 'NULL'))"
            }
            foreach ($case in @($FallbackAccepted) + @($FallbackRefused)) {
                "run_case(`"fallback:$($case.Case)`", $($case.Public ?? 'NULL'), `"$($case.Connection)`")"
            })
        $results = @{}
        foreach ($line in (Invoke-ReportSnippet -Report 'Validation-Report' -Body ((@($runner) + $calls) -join "`n")) -split "`n") {
            $fields = $line -split "`t"
            if ($fields.Count -ge 2) { $results[$fields[0]] = $fields[1..($fields.Count - 1)] }
        }
    }

    It 'takes a public address with <Case> as it stands, less trailing slashes' -ForEach $Accepted {
        $results["given:$Case"] -join '|' | Should -BeExactly "ok|$Expected"
    }

    It 'refuses a public address with <Case>, without repeating it' -ForEach $Refused {
        $outcome = $results["given:$Case"]
        $outcome[0] | Should -BeExactly 'neoipc_invalid_dhis2_public_base_url'
        $outcome[1..4] -join '|' | Should -BeExactly 'FALSE|TRUE|FALSE|TRUE' -Because (
            'a refusal names the parameter and states the defect but never repeats the value or its password')
        $outcome[5] | Should -Match ([regex]::Escape($Defect))
    }

    It 'links to the address the data is read from, less a trailing /api, for a connection with <Case>' -ForEach $FallbackAccepted {
        $results["fallback:$Case"] -join '|' | Should -BeExactly "ok|$Expected"
    }

    It 'refuses a connection address with <Case> as the base, naming dhis2PublicBaseUrl instead' -ForEach $FallbackRefused {
        $outcome = $results["fallback:$Case"]
        $outcome[0] | Should -BeExactly 'neoipc_invalid_dhis2_public_base_url'
        $outcome[1..4] -join '|' | Should -BeExactly 'FALSE|TRUE|TRUE|TRUE' -Because (
            'a refusal of the connection address names the parameter to give instead and states the ' +
            'defect but never repeats the address')
        $outcome[5] | Should -Match ([regex]::Escape($Defect))
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

    It 'names each id neoipcr applies without a label, and each label neoipcr does not apply' {
        # The ids are passed as neoipcr::reconciliation_ids() would list them; a label whose string
        # resource is missing counts as none, since its row falls back to the number as well. Only a
        # missing label leaves a row labelled by its number, so only then does the warning say so.
        $body = @'
cat(is.null(reconciliation_label_mismatch(sR, 1:6))); cat("\n")
cat(reconciliation_label_mismatch(sR, 1:7)); cat("\n")
cat(reconciliation_label_mismatch(sR, 1:5)); cat("\n")
cat(reconciliation_label_mismatch(sR, c(1:5, 8L))); cat("\n")
unlabelled <- sR
unlabelled$`tbl-reconciliation-summary`$reconciliations$ssi_secondary_bsi_agents <- NULL
cat(reconciliation_label_mismatch(unlabelled, 1:6)); cat("\n")
cat(reconciliation_label_mismatch(sR, 1:4))
'@
        $lines = (Invoke-ReconciliationSnippet $body) -split "`n"
        $lines[0] | Should -BeExactly 'TRUE'
        $lines[1] | Should -Match '; no label for 7\.'
        $lines[1] | Should -Not -Match 'a label for'
        $lines[2] | Should -Match '; a label for 6, which neoipcr does not apply\.$'
        $lines[2] | Should -Not -Match 'no label for'
        $lines[3] | Should -Match '; no label for 8; a label for 6, which neoipcr does not apply\.'
        $lines[4] | Should -Match '; no label for 5\.'
        $lines[5] | Should -Match '; labels for 5, 6, which neoipcr does not apply\.$'
        foreach ($line in $lines[1, 3, 4]) {
            $line | Should -Match 'labels a reconciliation without a label by its number\.$'
        }
        foreach ($line in $lines[2, 5]) {
            $line | Should -Not -Match 'by its number'
        }
    }

    It 'shows each dataset of the Partner Report that has a summary, and a sentence for each that has none' {
        # Each case prints the column groups shown, the sentences for the datasets without a
        # summary, and the sentence for summaries shown that count nothing, by the key of their
        # string. A missing slot and an empty one are told apart on either side, the reference data
        # are shown whenever they carry a summary, and the sentence for a count of nothing names the
        # datasets shown.
        $body = @'
strings <- sR$`tbl-reconciliation-summary`
own_notes <- c(absent = strings$own_not_recorded, empty = strings$own_not_reconciled)
reference_notes <- c(absent = strings$reference_not_recorded, empty = strings$reference_not_reconciled)
zero_notes <- c(
  own = strings$own_no_reconciliations,
  reference = strings$reference_no_reconciliations,
  both = strings$both_no_reconciliations)
note_keys <- c(own = own_notes, reference = reference_notes)
summary <- reconciliation_summary(c(1, 0, 0, 0, 0, 0), rep(0, 6))
unreconciled <- tibble::tibble()
show <- function(own, ref, has_reference) {
  shown <- compared_summaries(own, ref, has_reference, own_notes, reference_notes, zero_notes, sR)
  groups <- if (is.null(names(shown$summaries))) sprintf("%d unnamed", length(shown$summaries))
            else paste(names(shown$summaries), collapse = "+")
  zero <- if (is.null(shown$zero_note)) "-" else names(zero_notes)[match(shown$zero_note, zero_notes)]
  cat(groups, " / ", paste(names(note_keys)[match(shown$notes, note_keys)], collapse = "+"),
      " / ", zero, "\n", sep = "")
}
show(summary, NULL, FALSE)
show(NULL, NULL, FALSE)
show(unreconciled, NULL, FALSE)
show(summary, summary, FALSE)
show(summary, summary, TRUE)
show(NULL, summary, TRUE)
show(unreconciled, summary, TRUE)
show(summary, NULL, TRUE)
show(summary, unreconciled, TRUE)
show(NULL, unreconciled, TRUE)
'@
        Invoke-ReconciliationSnippet $body | Should -BeExactly (@(
            '1 unnamed /  / own'
            '0 unnamed / own.absent / -'
            '0 unnamed / own.empty / -'
            '1 unnamed /  / own'
            'Your data+Reference data /  / both'
            'Reference data / own.absent / reference'
            'Reference data / own.empty / reference'
            'Your data / reference.absent / own'
            'Your data / reference.empty / own'
            ' / own.absent+reference.empty / -') -join "`n")
    }
}

Describe 'A sentence in a table''s place' -Skip:(-not $env:CI -and -not (Get-Command Rscript -ErrorAction SilentlyContinue)) {

    It 'escapes the sentence for the LaTeX the PDF gets, and for the Markdown every other format reads' {
        # Quarto's `pdf` matches LaTeX output only, so the paragraph reaches HTML and Word alike;
        # Pandoc's Word writer drops a raw LaTeX block.
        $body = @'
no_data_table("50 % & more_{x} #1 $5 ~a ^b \\c")
'@
        Invoke-ReportSnippet -Report 'Partner-Report' -Body $body | Should -BeExactly (@(
            '::: {.content-visible unless-format="pdf"}'
            '50 \% \& more\_\{x\} \#1 \$5 \~a \^b \\c'
            ':::'
            ''
            '::: {.content-visible when-format="pdf"}'
            '\begin{longtable}{p{\dimexpr\linewidth-2\tabcolsep\relax}}'
            '\centering 50 \% \& more\_\{x\} \#1 \$5 \textasciitilde{}a \textasciicircum{}b \textbackslash{}c'
            '\end{longtable}'
            ':::') -join "`n")
    }

    It 'leaves every character LaTeX does not reserve as it is, non-ASCII included' {
        # Compared in R, so the text never crosses a console encoding.
        $body = @'
text <- "– „ok“ ü α . , ; : ! ? ' \" ( ) [ ] / | < > = + * -"
cat(identical(escape_latex(text), text), identical(escape_latex(c("a%", "")), c("a\\%", "")),
    sep = "|")
'@
        Invoke-ReportSnippet -Report 'Partner-Report' -Body $body | Should -BeExactly 'TRUE|TRUE'
    }

    It 'leaves the characters smart typography reads to it, and escapes a paragraph''s list marker' {
        # A paragraph that starts with a hyphen, or with a number or a word and a full stop, would
        # open a list; a line break or an indent would end the paragraph or make it a code block.
        $body = @'
cat(escape_markdown_paragraph(c(
  "it's \"so\" -- and so...", "- a", "1. Juni", "z. B. so", " a\n  b ")), sep = "|")
'@
        Invoke-ReportSnippet -Report 'Partner-Report' -Body $body |
            Should -BeExactly 'it''s "so" -- and so...|\- a|1\. Juni|z\. B. so|a b'
    }

    It 'gives every other format a paragraph that Pandoc reads as the sentence, beside the PDF block' -Skip:(-not $hasPandoc) {
        # Pandoc reads the Markdown itself, so an escape that leaves raw TeX, a Div fence or a list
        # marker live fails here: unescaped, the `\c` swallows the closing fence and nests the PDF block
        # in this one. HTML stands for every format but the PDF; the entities are decoded so the check
        # does not depend on how a Pandoc version spells them.
        $body = @'
no_data_table("50 % & more_{x} #1 $5 ~a ^b \\c -- it's \"so\"...")
'@
        $markdown = Invoke-ReportSnippet -Report 'Partner-Report' -Body $body
        $html = ($markdown | & pandoc -f markdown -t html --ascii --wrap=none 2>&1) -join "`n"
        [System.Net.WebUtility]::HtmlDecode($html) | Should -BeExactly (@(
            '<div class="content-visible" data-unless-format="pdf">'
            "<p>50 % & more_{x} #1 `$5 ~a ^b \c `u{2013} it`u{2019}s `u{201C}so`u{201D}`u{2026}</p>"
            '</div>'
            '<div class="content-visible" data-when-format="pdf">'
            ''
            '</div>') -join "`n")
    }
}

Describe 'Summary tables' -Skip:(-not $hasGt) {

    BeforeAll {
        $fixture = @'
reconciliation_summary <- function(repaired, reported = rep(0, 6))
  tibble::tibble(
    reconciliation_id = seq_len(6L),
    record_kind       = factor(c("enrollments", "events", "patients", "patients", "events", "events")),
    n_repaired        = as.integer(repaired),
    n_reported        = as.integer(reported))
validation_summary <- tibble::tibble(
  rule_id = c(3L, NA), record_kind = factor(c("patients", "patients")),
  n_removed = c(2L, 2L), n_exempted = c(0L, 0L))
latex <- function(tbl) as.character(gt::as_latex(tbl))
'@

        function Invoke-SummaryTableSnippet {
            param([string]$Body)
            Invoke-ReportSnippet -Report 'Partner-Report' -Body "$fixture`n$Body"
        }
    }

    It 'shows a missing count as a dash, with a note that says what it means, and only then' {
        $body = @'
note <- sR$`tbl-reconciliation-summary`$missing_count_footnote
unread <- latex(format_reconciliation_summary_table(
  list(reconciliation_summary(c(NA, 2, 0, 0, NA, 3))), sR, font_size = 11L))
read <- latex(format_reconciliation_summary_table(
  list(reconciliation_summary(c(1, 2, 0, 0, 0, 3))), sR, font_size = 11L))
cat(lengths(regmatches(unread, gregexpr("& — ", unread))),
    grepl(note, unread, fixed = TRUE), grepl(sR$not_available, unread, fixed = TRUE),
    grepl(note, read, fixed = TRUE), sep = "|")
'@
        Invoke-SummaryTableSnippet $body | Should -BeExactly '2|TRUE|FALSE|FALSE'
    }

    It 'sets both tables in the font size given, and gives the stub alone a width' {
        # gt sets a font size in px as three quarters of it in pt and its baseline skip as 1.2 times
        # that, each rounded to a whole point: 11 px, the size compute_col_widths() gives a table
        # without confidence intervals, becomes 8 pt (8.25) on a 10 pt baseline skip (9.9). The
        # counts and the record kinds take their natural width, and the stub leaves 20 % to the
        # record kinds and 13 % to each count.
        $body = @'
two <- latex(format_reconciliation_summary_table(
  list(reconciliation_summary(c(1, 2, 0, 0, 0, 3), c(0, 0, 0, 0, 0, 2))), sR, font_size = 11L))
validation <- latex(format_validation_summary_table(list(validation_summary), sR, font_size = 11L))
cat(grepl("\\fontsize{8.0pt}{10.0pt}", two, fixed = TRUE),
    grepl("\\fontsize{8.0pt}{10.0pt}", validation, fixed = TRUE),
    grepl("p{\\dimexpr 0.54\\linewidth", two, fixed = TRUE),
    grepl("}|lrr}", two, fixed = TRUE), sep = "|")
'@
        Invoke-SummaryTableSnippet $body | Should -BeExactly 'TRUE|TRUE|TRUE|TRUE'
    }

    It 'labels a column group for each named summary, and none for a single unnamed one' {
        $body = @'
has_group <- function(tbl, label) grepl(paste0("{{", label, "}}"), latex(tbl), fixed = TRUE)
cat(has_group(format_reconciliation_summary_table(
      list("Reference data" = reconciliation_summary(c(1, 0, 0, 0, 0, 0))), sR), "Reference data"),
    has_group(format_validation_summary_table(
      list("Reference data" = validation_summary), sR), "Reference data"),
    grepl("multicolumn", latex(format_reconciliation_summary_table(
      list(reconciliation_summary(c(1, 0, 0, 0, 0, 0))), sR)), fixed = TRUE),
    grepl("multicolumn", latex(format_validation_summary_table(list(validation_summary), sR)),
          fixed = TRUE), sep = "|")
'@
        Invoke-SummaryTableSnippet $body | Should -BeExactly 'TRUE|TRUE|FALSE|FALSE'
    }
}
