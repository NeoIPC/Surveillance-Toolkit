load_neoipcr <- function(dev_pkg_path = NULL) {
  env_path <- Sys.getenv("NEOIPCR_DEV_PATH", unset = "")
  effective_path <- if (nzchar(env_path)) env_path else dev_pkg_path
  is_dev <- !is.null(effective_path) &&
    file.exists(file.path(effective_path, "DESCRIPTION"))
  if (is_dev) {
    resolved <- normalizePath(effective_path, mustWork = FALSE)
    cat(sprintf("Loading neoipcr from source: %s\n", resolved), file = stderr())
    if (!requireNamespace("devtools", quietly = TRUE)) {
      cat("Installing devtools (needed to load neoipcr from local source)...\n",
        file = stderr())
      install.packages("devtools", repos = "https://cloud.r-project.org")
    }
    devtools::load_all(effective_path, recompile = TRUE)
  } else {
    if (!is.null(effective_path)) {
      checked <- normalizePath(
        file.path(effective_path, "DESCRIPTION"), mustWork = FALSE)
      cat(sprintf(
        "Dev path specified but DESCRIPTION not found at %s. Falling back to installed neoipcr.\n",
        checked), file = stderr())
    }
    library(neoipcr, warn.conflicts = FALSE, quietly = TRUE)
  }
}
