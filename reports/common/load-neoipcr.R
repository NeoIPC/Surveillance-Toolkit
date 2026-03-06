load_neoipcr <- function(dev_pkg_path = NULL) {
  is_dev <- !is.null(dev_pkg_path) &&
    file.exists(file.path(dev_pkg_path, "DESCRIPTION"))
  if (is_dev) {
    if (!requireNamespace("devtools", quietly = TRUE)) {
      message("Installing devtools (needed to load neoipcr from local source)...")
      install.packages("devtools", repos = "https://cloud.r-project.org")
    }
    devtools::load_all(dev_pkg_path, recompile = TRUE)
  } else {
    library(neoipcr, warn.conflicts = FALSE, quietly = TRUE)
  }
}
