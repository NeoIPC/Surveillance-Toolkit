load_neoipcr <- function(dev_pkg_path = NULL) {
  is_dev <- !is.null(dev_pkg_path) &&
    file.exists(file.path(dev_pkg_path, "DESCRIPTION"))
  if (is_dev) {
    resolved <- normalizePath(dev_pkg_path, mustWork = FALSE)
    cat(sprintf("Loading neoipcr from source: %s\n", resolved), file = stderr())
    if (!requireNamespace("devtools", quietly = TRUE)) {
      cat("Installing devtools (needed to load neoipcr from local source)...\n",
        file = stderr())
      install.packages("devtools", repos = "https://cloud.r-project.org")
    }
    devtools::load_all(dev_pkg_path, recompile = TRUE)
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
