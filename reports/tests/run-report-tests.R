# Runs the reports' R helpers' unit tests against the engine-shaped fixtures
# under `testthat/`. Run from the repository root:
#
#   Rscript reports/tests/run-report-tests.R
#
# The helpers under test live in `reports/common/` and in the reports' own
# directories — the outlier framework `metric-states.R` stands in
# `reports/Partner-Report/`, which that report's `_setup.qmd` sources alone —
# and `testthat/helper-report-common.R` sources the same files the render
# does, so what the tests prove here holds in the render for everything the
# helpers do.

if (!requireNamespace("testthat", quietly = TRUE)) {
  rlang::abort(
    "The package 'testthat' is required to run the reports' helper tests.",
    class = "reports_testthat_missing")
}

testthat::test_dir("reports/tests/testthat", stop_on_failure = TRUE, wrap = FALSE)
