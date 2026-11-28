# Pins the Tested column of the resistance tables: the engine's `tested_*`
# names are read behind `any_of()` guards, so nothing would fail if upstream
# renamed a column — the table would simply print without it and the suite
# would stay green. These tests build both reports' resistance table from the
# engine-shaped fixtures, which carry the `tested_*` columns, and read the
# built table: the column's name, its place between the count and the rate
# spanner, the footnote defining the measure, the flag on its own
# denominator, and the declared widths keeping their sum of 100%.
#
#   Rscript reports/tests/run-report-tests.R

report_path <- function(...) {
  rel <- file.path("..", "..", ...)
  if (file.exists(rel) || dir.exists(rel)) rel
  else file.path("reports", ...)
}

# The render evaluates its chunks in the document's global environment and
# gt reads the width formulas' variables along the search path — so the
# setup the harness supplies stands in the global environment too, which is
# also what the chunk's own assignments add to; `render_case` removes
# everything an added case leaves.

# The string resources and the helpers a report's chunk needs, with the
# report's own `compute_col_widths()` read out of its _setup.qmd, which is
# not sourced whole because it is render machinery. The string layer reads
# its files relative to the report directory, as the render does.
install_render_setup <- function(report, ci) {
  suppressMessages(library(gt))
  old <- setwd(report_path(report))
  on.exit(setwd(old))
  logDebug <<- function(...) invisible(NULL)
  source("../common/helpers.R")
  source("../common/infectious-agent-rows.R")
  localeObj <<- list(language = "en")
  locale_gt <<- "en"
  ci_config <<- ci
  include_rate_ci <<- identical(ci, "all")
  include_pooled_ci <<- identical(ci, "all")
  include_quartile_ci <<- identical(ci, "all")
  ci_pattern_inline <<- "{1} ({2}–{3})"
  sparse_threshold <<- 16L
  params <<- list()
  infectious_agent_rows <<- "groups"
  setup_src <- knitr::purl("_setup.qmd", quiet = TRUE,
                           output = tempfile(fileext = ".R"))
  cw_def <- Filter(function(e) {
    is.call(e) && identical(as.character(e[[1]]), "<-") &&
      identical(as.character(e[[2]]), "compute_col_widths")
  }, as.list(parse(setup_src)))[[1]]
  eval(cw_def, envir = globalenv())
  sR <<- get_string_resources(localeObj)
  invisible(TRUE)
}

header_en <- local({
  old <- setwd(report_path("Partner-Report"))
  on.exit(setwd(old))
  env <- new.env(parent = parent.env(globalenv()))
  env$logDebug <- function(...) invisible(NULL)
  env$localeObj <- list(language = "en")
  source("../common/helpers.R", local = env)
  env$get_string_resources(env$localeObj)$table_headers
})

# The labelled table chunk alone, evaluated as the render evaluates it.
build_table_chunk <- function(report) {
  txt <- paste(readLines(report_path(report, "tables",
    "_tbl-organism-resistance-rate.qmd"), warn = FALSE), collapse = "\n")
  blocks <- regmatches(
    txt, gregexpr("```\\{r\\}[^\n]*\n(?:.|\\n)*?```", txt))[[1]]
  block <- grep("#\\| label: tbl-organism-resistance-rate", blocks,
                value = TRUE)
  stopifnot(length(block) == 1L)
  lines <- strsplit(block, "\n")[[1]]
  code <- lines[!grepl("^```", lines) & !grepl("^#\\|", lines)]
  suppressWarnings(suppressMessages(
    eval(parse(text = paste(code, collapse = "\n")), envir = globalenv())))
}

# Runs one case: the setup and the data in the global environment, the chunk
# through it, the built table back, and every name the case added removed
# again, so one case leaves nothing the next could read by mistake.
render_case <- function(report, ci, data_name, data_value) {
  before <- ls(globalenv())
  on.exit({
    added <- setdiff(ls(globalenv()), before)
    if (length(added) > 0L) rm(list = added, envir = globalenv())
  })
  install_render_setup(report, ci)
  assign(data_name, data_value, envir = globalenv())
  build_table_chunk(report)
}

# The shown column labels in table order: everything but the row-group key
# and the hidden helper columns.
shown_labels <- function(gt_tbl) {
  bh <- gt_tbl$`_boxhead`
  as.character(unlist(bh$column_label[!bh$type %in% c("hidden", "row_group")]))
}

# The declared column widths in percent, as `cols_width()` recorded them in
# the boxhead; the columns it left unlisted carry no width.
declared_widths <- function(gt_tbl) {
  w <- unlist(unname(gt_tbl$`_boxhead`$column_width))
  w <- w[endsWith(w, "%")]
  widths <- as.numeric(sub("%$", "", w))
  stopifnot(length(widths) > 0L)
  widths
}

test_that("the Partner resistance table prints the Tested column between
           the count and the rate spanner, flagged on its own denominator", {
  tbl <- render_case("Partner-Report", "all", "benchmark_data", list(
    infectious_agent_resistance_rate_table = fixture_resistance_own()))

  labels <- shown_labels(tbl)
  expect_true(header_en$tested %in% labels)
  expect_true(match(header_en$count, labels) <
                match(header_en$tested, labels))
  expect_true(match(header_en$tested, labels) <
                match(header_en$rate, labels))

  html <- as.character(gt::as_raw_html(tbl))
  expect_match(html, "The infections of your department with a resistance test result for the category", fixed = TRUE)
  # gt rounds each percentage to two decimals.
  expect_equal(sum(declared_widths(tbl)), 100, tolerance = 1e-6)

  # The sparse mark sits on the Tested cell of the row whose eight tested
  # infections fall below the threshold, and on no count cell: the rows'
  # counted infections all stand above it.
  notes <- tbl$`_footnotes`
  cell_notes <- notes[notes$locname == "data", ]
  expect_true(any(cell_notes$colname == header_en$tested &
                    cell_notes$rownum == 2L))
  expect_false(any(cell_notes$colname == header_en$count))
})

test_that("the Reference resistance table prints the Tested column with
           intervals off, without overrunning the page", {
  gt_tbl <- render_case("Reference-Report", "none", "reference_data", list(
    infectious_agent_resistance_rate_table = fixture_resistance_ref()))

  labels <- shown_labels(gt_tbl)
  expect_true(header_en$tested %in% labels)
  expect_true(match(header_en$count, labels) <
                match(header_en$tested, labels))
  expect_true(match(header_en$tested, labels) <
                match(header_en$pooled, labels))

  html <- as.character(gt::as_raw_html(gt_tbl))
  expect_match(html, "The resistance test rate calculated across all departments", fixed = TRUE)
  expect_equal(sum(declared_widths(gt_tbl)), 100, tolerance = 1e-6)

  notes <- gt_tbl$`_footnotes`
  cell_notes <- notes[notes$locname == "data", ]
  expect_true(any(cell_notes$colname == header_en$tested &
                    cell_notes$rownum == 2L))
  expect_false(any(cell_notes$colname == header_en$count))
})

test_that("a resistance table from before the engine prints no Tested column",
          {
  tbl <- render_case("Partner-Report", "all", "benchmark_data", list(
    organism_resistance_rate_table = fixture_resistance_old()))

  expect_false(header_en$tested %in% shown_labels(tbl))
  expect_equal(sum(declared_widths(tbl)), 100, tolerance = 1e-6)
})
