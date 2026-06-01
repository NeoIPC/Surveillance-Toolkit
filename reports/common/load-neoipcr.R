load_neoipcr <- function(dev_pkg_path = NULL) {
  is_dev <- !is.null(dev_pkg_path) &&
    file.exists(file.path(dev_pkg_path, "DESCRIPTION"))
  if (is_dev) {
    resolved <- normalizePath(dev_pkg_path, mustWork = FALSE)
    cat(sprintf("Loading neoipcr from source: %s\n", resolved), file = stderr())
    if (!requireNamespace("devtools", quietly = TRUE)) {
      stop(paste0(
        "load_neoipcr(dev_pkg_path = ...) requires the 'devtools' package, ",
        "which is not installed. Install it manually with ",
        "install.packages('devtools'), or omit dev_pkg_path / unset the ",
        "NEOIPCR_DEV_PATH env var to use the installed neoipcr instead."),
        call. = FALSE)
    }
    devtools::load_all(dev_pkg_path)
  } else {
    if (!is.null(dev_pkg_path)) {
      checked <- normalizePath(
        file.path(dev_pkg_path, "DESCRIPTION"), mustWork = FALSE)
      cat(sprintf(
        "Dev path specified but DESCRIPTION not found at %s. Falling back to installed neoipcr.\n",
        checked), file = stderr())
    }
    library(neoipcr, warn.conflicts = FALSE, quietly = TRUE)
  }
}
