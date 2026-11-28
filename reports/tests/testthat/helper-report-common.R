# Sources the reports' shared helper files so the tests exercise the same
# code the renders do. The files hold functions only; sourcing them runs no
# render state. `logging.R` itself stays out — its `logger` setup is render
# machinery — so the tests carry a quiet `logDebug` under the name the render
# provides, and a helper that logs more than that would fail here unseen.

report_common <- "../../common"
if (!dir.exists(report_common)) {
  # testthat sources helpers from the test directory's working directory;
  # running the suite from the repository root is the documented way.
  report_common <- "reports/common"
}

logDebug <- function(...) invisible(NULL)

source(file.path(report_common, "infectious-agent-rows.R"), local = TRUE)
source(file.path(report_common, "..", "Partner-Report", "metric-states.R"),
     local = TRUE)
