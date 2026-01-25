#!/usr/bin/env Rscript

isQuietStartup <- function() {
  args <- commandArgs(trailingOnly = TRUE)
  any(args %in% c("--quiet", "-q"))
}

suppressPackageStartupMessages({
  if (requireNamespace("pak", quietly = TRUE)) {
    if (isQuietStartup()) {
      suppressMessages(suppressWarnings(
        pak::pak("Brar/neoipcr@PartnerReport")
      ))
    } else {
      pak::pak("Brar/neoipcr@PartnerReport")
    }
  }
  library(jsonlite)
  library(neoipcr)
})

verbosity <- "normal"

logInfo <- function(...) {
  if (verbosity != "quiet") message(...)
}

logVerbose <- function(...) {
  if (verbosity %in% c("verbose", "debug")) message(...)
}

logDebug <- function(...) {
  if (verbosity == "debug") message(...)
}

logWarn <- function(...) {
  if (verbosity != "quiet") warning(..., call. = FALSE)
}

printUsage <- function() {
  cat(
    "Usage: Rscript --vanilla ",
    "reports/Reference-Report/Generate-ReferenceData.R [options]\n\n",
    "Options (same as Reference Report):\n",
    "  --file, -f <path>                    Output JSON file path\n",
    "                                       (stdout if omitted)\n",
    "  --reportingPeriodFrom, -s <date>     YYYY-MM-DD\n",
    "  --reportingPeriodTo, -e <date>       YYYY-MM-DD\n",
    "  --birthWeightFrom, -w <number>       Minimal included birth weigth\n",
    "  --birthWeightTo, -W <number>         Maximal included birth weigth\n",
    "  --gestationWeeksFrom, -g <number>    Minimal included gestational age\n",
    "  --gestationWeeksTo, -G <number>      Maximal included gestational age\n",
    "  --reportingCountries, -c <list>      Comma-separated ISO codes\n",
    "  --includeTestUnits, -t               Include test departments\n",
    "  --includeNonCorePatients, -n         Include non-core patients\n",
    "  --validationExceptionFile, -v <path> Input CSV file path\n",
    "  --quiet, -q                          Suppress non-critical output\n",
    "  --verbose, -V                        Verbose output\n",
    "  --debug, -D                          Debug output\n",
    "  --help, -h                           Show this help\n",
    sep = ""
  )
}

parseArgs <- function(args) {
  shortMap <- list(
    f = "file",
    s = "reportingPeriodFrom",
    e = "reportingPeriodTo",
    w = "birthWeightFrom",
    W = "birthWeightTo",
    g = "gestationWeeksFrom",
    G = "gestationWeeksTo",
    c = "reportingCountries",
    t = "includeTestUnits",
    n = "includeNonCorePatients",
    v = "validationExceptionFile",
    q = "quiet",
    V = "verbose",
    D = "debug",
    h = "help"
  )
  parsed <- list()
  i <- 1
  while (i <= length(args)) {
    arg <- args[[i]]
    if (startsWith(arg, "--")) {
      key <- sub("^--", "", arg)
      if (grepl("=", key, fixed = TRUE)) {
        parts <- strsplit(key, "=", fixed = TRUE)[[1]]
        parsed[[parts[[1]]]] <- parts[[2]]
      } else {
        hasNext <- i < length(args)
        if (hasNext) {
          nextArg <- args[[i + 1]]
          hasValue <- !startsWith(nextArg, "--")
          hasValue <- hasValue && !startsWith(nextArg, "-")
        } else {
          hasValue <- FALSE
        }
        if (hasValue) {
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
        long <- shortMap[[short]]
        if (!is.null(long)) parsed[[long]] <- parts[[2]]
      } else {
        long <- shortMap[[key]]
        if (!is.null(long)) {
          hasNext <- i < length(args)
          if (hasNext) {
            nextArg <- args[[i + 1]]
            hasValue <- !startsWith(nextArg, "--")
            hasValue <- hasValue && !startsWith(nextArg, "-")
          } else {
            hasValue <- FALSE
          }
          if (hasValue) {
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

asNull <- function(x) {
  if (is.null(x)) return(NULL)
  if (length(x) == 0) return(NULL)
  if (is.logical(x)) return(x)
  val <- trimws(as.character(x))
  if (val == "" ||
      tolower(val) %in% c("null", "na", "none")
  ) return(NULL)
  val
}

asBool <- function(x, default = NULL) {
  x <- asNull(x)
  if (is.null(x)) return(default)
  if (is.logical(x)) return(x)
  val <- tolower(as.character(x))
  if (val %in% c("true", "t", "1", "yes", "y")) return(TRUE)
  if (val %in% c("false", "f", "0", "no", "n")) return(FALSE)
  default
}

asDateOrNull <- function(x) {
  x <- asNull(x)
  if (is.null(x)) return(NULL)
  as.Date(x)
}

asNumberOrNull <- function(x) {
  x <- asNull(x)
  if (is.null(x)) return(NULL)
  as.numeric(x)
}

asVectorOrNull <- function(x) {
  x <- asNull(x)
  if (is.null(x)) return(NULL)
  if (length(x) > 1) return(as.character(x))
  parts <- strsplit(as.character(x), ",", fixed = TRUE)[[1]]
  parts <- trimws(parts)
  parts[nzchar(parts)]
}

getConnectionOptions <- function() {
  sessionId <- Sys.getenv("NEOIPC_DHIS2_SESSION_ID", unset = NA)
  token <- Sys.getenv("NEOIPC_DHIS2_TOKEN", unset = NA)
  username <- Sys.getenv("NEOIPC_DHIS2_USERNAME", unset = NA)
  passwordEnv <- Sys.getenv("NEOIPC_DHIS2_PASSWORD", unset = NA)
  if (!is.na(sessionId)) {
    return(neoipcr::dhis2_connection_options(
      session_id = sessionId
    ))
  }
  if (!is.na(token)) {
    return(neoipcr::dhis2_connection_options(
      token = token
    ))
  }
  if (is.na(username)) {
    username <- readline("DHIS2 username: ")
  }
  if (is.na(passwordEnv)) {
    password <- readline("DHIS2 password: ")
  } else {
    password <- passwordEnv
  }
  neoipcr::dhis2_connection_options(
    username = username,
    password = password
  )
}

getValidationExceptions <- function(x) {
  x <- asNull(x)
  if (is.null(x)) {
    return(FALSE)
  }
  validationExceptionFile <- x
  if (file.exists(validationExceptionFile)) {
    header <- utils::read.csv(
      validationExceptionFile,
      nrows = 0,
      stringsAsFactors = FALSE
    )
    colClasses <- rep(NA_character_, length(header))
    names(colClasses) <- names(header)
    integerColumns <- c("RULE_ID")
    dateColumns <- c("ENROLMENT_DATE", "EVENT_DATE")
    for (colName in intersect(integerColumns, names(colClasses))) {
      colClasses[[colName]] <- "integer"
    }
    for (colName in intersect(dateColumns, names(colClasses))) {
      colClasses[[colName]] <- "Date"
    }
    return(utils::read.csv(
      validationExceptionFile,
      stringsAsFactors = FALSE,
      colClasses = colClasses
    ))
  }
  logWarn(
    sprintf(
      "Validation exception file not found: '%s'",
      validationExceptionFile
    )
  )
  NULL
}

getDatasetOptions <- function(
  reportingPeriodFrom,
  reportingPeriodTo,
  birthWeightFrom,
  birthWeightTo,
  gestationWeeksFrom,
  gestationWeeksTo,
  reportingCountries,
  includeTestUnits,
  includeNonCorePatients,
  validationExceptionFile
) {
  neoipcr::dhis2_dataset_options(
    include_country = "yes",
    include_department = "pseudonymised",
    surveillance_end_from = as.Date(
      if (is.null(reportingPeriodFrom)) {
        "2024-01-01"
      } else {
        reportingPeriodFrom
      }
    ),
    surveillance_end_to = as.Date(
      if (is.null(reportingPeriodTo)) {
        Sys.Date()
      } else {
        reportingPeriodTo
      }
    ),
    birth_weight_from = birthWeightFrom,
    birth_weight_to = birthWeightTo,
    gestational_age_from = gestationWeeksFrom,
    gestational_age_to = gestationWeeksTo,
    country_filter = reportingCountries,
    include_test_data = isTRUE(includeTestUnits),
    include_ineligible_patients = isTRUE(includeNonCorePatients),
    include_invalid_patients = getValidationExceptions(
      validationExceptionFile
    )
  )
}

args <- parseArgs(commandArgs(trailingOnly = TRUE))

if (isTRUE(args$help)) {
  printUsage()
  quit(status = 0)
}

if (isTRUE(args$quiet)) {
  verbosity <- "quiet"
} else if (isTRUE(args$debug)) {
  verbosity <- "debug"
} else if (isTRUE(args$verbose)) {
  verbosity <- "verbose"
}

referenceDataFile <- asNull(args$file)
reportingPeriodFrom <- asDateOrNull(args$reportingPeriodFrom)
reportingPeriodTo <- asDateOrNull(args$reportingPeriodTo)
birthWeightFrom <- asNumberOrNull(args$birthWeightFrom)
birthWeightTo <- asNumberOrNull(args$birthWeightTo)
gestationWeeksFrom <- asNumberOrNull(args$gestationWeeksFrom)
gestationWeeksTo <- asNumberOrNull(args$gestationWeeksTo)
reportingCountries <- asVectorOrNull(args$reportingCountries)
includeTestUnits <- asBool(args$includeTestUnits, default = FALSE)
includeNonCorePatients <- asBool(
  args$includeNonCorePatients,
  default = FALSE
)
validationExceptionFile <- asNull(args$validationExceptionFile)

connectionOptions <- getConnectionOptions()
datasetOptions <- getDatasetOptions(
  reportingPeriodFrom = reportingPeriodFrom,
  reportingPeriodTo = reportingPeriodTo,
  birthWeightFrom = birthWeightFrom,
  birthWeightTo = birthWeightTo,
  gestationWeeksFrom = gestationWeeksFrom,
  gestationWeeksTo = gestationWeeksTo,
  reportingCountries = reportingCountries,
  includeTestUnits = includeTestUnits,
  includeNonCorePatients = includeNonCorePatients,
  validationExceptionFile = validationExceptionFile
)

logVerbose("Importing DHIS2 data...")
referenceData <- suppressWarnings(
  neoipcr::import_dhis2(
    connection_options = connectionOptions,
    dataset_options = datasetOptions
  )
) |>
  neoipcr::calculate_reference_data()

logDebug("Reference data calculation completed.")

json <- jsonlite::serializeJSON(
  referenceData,
  pretty = TRUE
)
if (is.null(referenceDataFile)) {
  cat(json)
} else {
  outputDir <- dirname(referenceDataFile)
  if (!dir.exists(outputDir)) {
    dir.create(outputDir, recursive = TRUE, showWarnings = FALSE)
  }
  writeLines(json, referenceDataFile, useBytes = TRUE)
  logInfo("Reference data written to: ", referenceDataFile)
}
