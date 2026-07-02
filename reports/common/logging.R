# Shared logging configuration for the NeoIPC Surveillance-Toolkit reports.
#
# All report R code logs through the `logger` package so the reports, the shared
# `common/` layer, and neoipcr emit through one consistent, level-aware,
# namespaced channel. Three R namespaces are used so every line self-identifies
# its source regardless of which report invoked it:
#   * the active report's slug   (e.g. "partner-report") — report-specific code
#   * "report-common"            — this shared `common/` layer
#   * "neoipcr"                  — the neoipcr package (level set via its own
#                                  configurator; destination set here)
#
# Verbosity and destination are driven by environment variables so the whole
# pipeline (PowerShell wrapper / .NET service -> Rscript / Quarto -> R) shares
# one setting:
#   * NEOIPC_LOG_LEVEL  quiet|normal|verbose|debug  (default "normal")
#   * NEOIPC_LOG_FILE   when set, structured JSON is written to this file (the
#                       NeoIPC-Reporting .NET service drains it); otherwise the
#                       console (stderr) is used.

# Active report namespace for the level helpers; updated by configure_logging().
.report_log <- new.env(parent = emptyenv())
.report_log$namespace <- "report-common"

# Map a verbosity level to a logger threshold (unknown -> INFO).
.report_log_threshold <- function(verbosity) {
  switch(
    tolower(verbosity),
    quiet   = logger::WARN,
    normal  = logger::INFO,
    verbose = logger::DEBUG,
    debug   = logger::TRACE,
    logger::INFO)
}

# Strip knitr's per-line comment marker (the chunk `comment` option, default
# "##") from the text a knitr warning/message output hook receives, so the log
# carries the condition text without the rendered comment decoration. `options`
# is the merged chunk option list knitr passes to the hook (`options$comment` is
# the active marker). knitr's own "Warning[ in <call>]:" label on warnings is
# left in place — the call context it carries is useful in the log.
.knit_condition_text <- function(x, options) {
  comment <- options$comment
  lines <- strsplit(x, "\n", fixed = TRUE)[[1]]
  if (!is.null(comment) && !is.na(comment) && nzchar(comment)) {
    lines <- vapply(lines, function(line) {
      if (startsWith(line, comment)) line <- substring(line, nchar(comment) + 1L)
      sub("^ ", "", line)
    }, character(1), USE.NAMES = FALSE)
  }
  trimws(paste(lines, collapse = "\n"))
}

# Configure logging for a report run.
#
# `report` is the report slug used as this report's logger namespace (e.g.
# "partner-report"); NULL (the default) uses "report-common", for standalone
# entry points in the shared `common/` layer. `verbosity` is one of
# quiet|normal|verbose|debug; NULL reads NEOIPC_LOG_LEVEL (default "normal").
configure_logging <- function(report = NULL, verbosity = NULL) {
  namespace <- if (is.null(report) || !nzchar(report)) "report-common" else report
  .report_log$namespace <- namespace

  if (is.null(verbosity)) {
    verbosity <- Sys.getenv("NEOIPC_LOG_LEVEL", unset = "normal")
  }
  threshold <- .report_log_threshold(verbosity)

  # Destination: structured JSON to NEOIPC_LOG_FILE when the .NET service sets
  # it (it drains the file into ILogger), else the console (stderr).
  log_file <- Sys.getenv("NEOIPC_LOG_FILE", unset = "")
  if (nzchar(log_file)) {
    appender <- logger::appender_file(log_file)
    layout   <- logger::layout_json()
  } else {
    appender <- logger::appender_console
    layout   <- logger::layout_glue_generator(format = "{level} [{namespace}] {msg}")
  }

  # The report namespaces (this report + the shared common layer) get the glue
  # formatter for their log messages; neoipcr owns its own formatter (set in
  # its .onLoad), so the application does not touch it.
  for (ns in unique(c(namespace, "report-common"))) {
    logger::log_formatter(logger::formatter_glue, namespace = ns)
  }

  # Threshold and destination (appender + layout) are application concerns:
  # apply them to all three namespaces — this report, the common layer, and
  # neoipcr — so their output shares one level and one channel. Setting
  # neoipcr's threshold directly (rather than via neoipcr::neoipcr_log_config)
  # keeps this independent of which neoipcr build is loaded.
  for (ns in unique(c(namespace, "report-common", "neoipcr"))) {
    logger::log_threshold(threshold, namespace = ns)
    logger::log_appender(appender, namespace = ns)
    logger::log_layout(layout, namespace = ns)
  }

  # Capture stray base-R conditions (warnings, messages) into the unified log.
  #
  # Outside knitr — the standalone Generate-*.R entry points run via Rscript at
  # top level — install *global* calling handlers. muffle = FALSE keeps each
  # warning propagating (logged AND still reachable by a surrounding handler),
  # independent of the global logger_muffle_warnings option; log_messages()
  # takes no muffle argument and never muffles. R permits global handlers only
  # at top level (no handlers already on the stack).
  #
  # Under knitr/Quarto that path is unavailable: every chunk runs inside knitr's
  # own calling handlers, so log_warnings()/log_messages() would error ("should
  # not be called with handlers on the stack") and abort the render. Register
  # knitr output hooks instead: each captured warning/message is routed into the
  # log channel and the hook returns "" so the condition stays out of the
  # rendered report body. This only fires for conditions knitr actually surfaces
  # to a hook — a chunk that sets warning=FALSE / message=FALSE drops the
  # condition first, so the report _setup.qmd chunks leave those unset where the
  # log capture is wanted. skip_formatter keeps logger's glue formatter from
  # trying to interpolate braces in arbitrary condition text.
  if (!isTRUE(getOption("knitr.in.progress"))) {
    logger::log_warnings(muffle = FALSE)
    logger::log_messages()
  } else if (requireNamespace("knitr", quietly = TRUE)) {
    knitr::knit_hooks$set(
      warning = function(x, options) {
        logWarn(logger::skip_formatter(.knit_condition_text(x, options)))
        ""
      },
      message = function(x, options) {
        logInfo(logger::skip_formatter(.knit_condition_text(x, options)))
        ""
      })
  }

  invisible(threshold)
}

# Leveled log helpers (replacing the old message()/warning() wrappers). They
# emit under the active report namespace by default; the shared `common/` code
# passes `namespace = "report-common"` so its lines are attributed to the
# shared layer rather than to whichever report invoked it.
#
# Each helper forwards `.topenv = parent.frame()` so logger's glue formatter
# resolves `{placeholder}` tokens in the *caller's* frame. Without it the
# formatter evaluates in this wrapper's frame (whose enclosing environment is
# globalenv, since this file is sourced at top level), and a message that
# references a caller-local variable would error at runtime.
logInfo <- function(..., namespace = .report_log$namespace) {
  logger::log_info(..., namespace = namespace, .topenv = parent.frame())
}

logVerbose <- function(..., namespace = .report_log$namespace) {
  logger::log_debug(..., namespace = namespace, .topenv = parent.frame())
}

logDebug <- function(..., namespace = .report_log$namespace) {
  logger::log_trace(..., namespace = namespace, .topenv = parent.frame())
}

logWarn <- function(..., namespace = .report_log$namespace) {
  logger::log_warn(..., namespace = namespace, .topenv = parent.frame())
}

logError <- function(..., namespace = .report_log$namespace) {
  logger::log_error(..., namespace = namespace, .topenv = parent.frame())
}
