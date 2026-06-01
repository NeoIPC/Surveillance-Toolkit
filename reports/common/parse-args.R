#' Shared CLI argument parsing utilities
#'
#' Provides a lightweight argument parser and type coercion helpers
#' for R scripts. No external dependencies (replaces argparse which
#' requires Python).

#' Parse command-line arguments into a named list
#'
#' Supports `--long-name value`, `--long-name=value`, `-s value`,
#' and boolean flags (no value = TRUE).
#'
#' @param args Character vector of arguments (typically
#'   `commandArgs(trailingOnly = TRUE)`)
#' @param long_map Named list mapping long option names (with hyphens)
#'   to camelCase keys, e.g. `list("backup-dataset" = "backupDataset")`.
#'   Options not in the map are used as-is.
#' @param short_map Named list mapping single-character short flags
#'   to long (camelCase) keys, e.g. `list(f = "file", q = "quiet")`.
#' @return Named list of parsed arguments
parse_args <- function(args, long_map = list(), short_map = list()) {
  parsed <- list()
  i <- 1
  while (i <= length(args)) {
    arg <- args[[i]]
    if (startsWith(arg, "--")) {
      key <- sub("^--", "", arg)
      if (!is.null(long_map[[key]])) key <- long_map[[key]]
      if (grepl("=", key, fixed = TRUE)) {
        parts <- strsplit(key, "=", fixed = TRUE)[[1]]
        long_key <- parts[[1]]
        if (!is.null(long_map[[long_key]])) long_key <- long_map[[long_key]]
        parsed[[long_key]] <- parts[[2]]
      } else {
        has_next <- i < length(args)
        if (has_next) {
          next_arg <- args[[i + 1]]
          has_value <- !startsWith(next_arg, "-")
        } else {
          has_value <- FALSE
        }
        if (has_value) {
          parsed[[key]] <- args[[i + 1]]
          i <- i + 1
        } else {
          parsed[[key]] <- TRUE
        }
      }
    } else if (startsWith(arg, "-")) {
      key <- sub("^-", "", arg)
      if (nchar(key) >= 2 && grepl("=", key, fixed = TRUE)) {
        parts <- strsplit(key, "=", fixed = TRUE)[[1]]
        short <- parts[[1]]
        long <- short_map[[short]]
        if (!is.null(long)) parsed[[long]] <- parts[[2]]
      } else {
        long <- short_map[[key]]
        if (!is.null(long)) {
          has_next <- i < length(args)
          if (has_next) {
            next_arg <- args[[i + 1]]
            has_value <- !startsWith(next_arg, "-")
          } else {
            has_value <- FALSE
          }
          if (has_value) {
            parsed[[long]] <- args[[i + 1]]
            i <- i + 1
          } else {
            parsed[[long]] <- TRUE
          }
        }
      }
    }
    i <- i + 1
  }
  parsed
}

#' Normalise a value to NULL if it represents an empty/missing value
#'
#' Returns NULL for NULL, zero-length, empty strings, and
#' common "null-like" strings ("null", "na", "none").
#' Logical values pass through unchanged.
#'
#' @param x A value to check
#' @return The trimmed character value, or NULL
as_null <- function(x) {
  if (is.null(x)) return(NULL)
  if (length(x) == 0) return(NULL)
  if (is.logical(x)) return(x)
  val <- trimws(as.character(x))
  if (val == "" ||
      tolower(val) %in% c("null", "na", "none")
  ) return(NULL)
  val
}

#' Coerce a value to logical with a default
#'
#' @param x A value to coerce
#' @param default Default value if x is NULL/empty
#' @return Logical value or default
as_bool <- function(x, default = NULL) {
  x <- as_null(x)
  if (is.null(x)) return(default)
  if (is.logical(x)) return(x)
  val <- tolower(as.character(x))
  if (val %in% c("true", "t", "1", "yes", "y")) return(TRUE)
  if (val %in% c("false", "f", "0", "no", "n")) return(FALSE)
  default
}

#' Coerce a value to Date or NULL
#'
#' @param x A value to coerce (character date string)
#' @return Date or NULL
as_date_or_null <- function(x) {
  x <- as_null(x)
  if (is.null(x)) return(NULL)
  as.Date(x)
}

#' Coerce a value to numeric or NULL
#'
#' @param x A value to coerce
#' @return Numeric value or NULL
as_number_or_null <- function(x) {
  x <- as_null(x)
  if (is.null(x)) return(NULL)
  as.numeric(x)
}

#' Coerce a value to a character vector or NULL
#'
#' Splits comma-separated strings into a character vector.
#' Already-vectorised inputs are returned as character.
#'
#' @param x A value to coerce
#' @return Character vector or NULL
as_vector_or_null <- function(x) {
  x <- as_null(x)
  if (is.null(x)) return(NULL)
  if (length(x) > 1) return(as.character(x))
  parts <- strsplit(as.character(x), ",", fixed = TRUE)[[1]]
  parts <- trimws(parts)
  parts[nzchar(parts)]
}

#' Print usage text to stdout
#'
#' @param ... Character strings to concatenate and print
print_usage <- function(...) {
  cat(..., sep = "")
}
