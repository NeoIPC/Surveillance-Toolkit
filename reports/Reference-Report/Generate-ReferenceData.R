#!/usr/bin/env Rscript

isQuietStartup <- function() {
  args <- commandArgs(trailingOnly = TRUE)
  any(args %in% c("--quiet", "-q"))
}

script_dir <- dirname(
  sub("--file=", "", grep("--file=", commandArgs(FALSE), value = TRUE)[1]))
suppressPackageStartupMessages({
  source(file.path(script_dir, "../common/load-neoipcr.R"))
  load_neoipcr(dev_pkg_path = file.path(script_dir, "../../../neoipcr"))
  source(file.path(script_dir, "../common/parse-args.R"))
  source(file.path(script_dir, "../common/logging.R"))
  source(file.path(script_dir, "../common/helpers.R"))
  library(jsonlite)
})

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
    "  --backup-dataset, -B <path>          Encrypted JSON backup (.7z)\n",
    "  --quiet, -q                          Suppress non-critical output\n",
    "  --verbose, -V                        Verbose output\n",
    "  --debug, -D                          Debug output\n",
    "  --help, -h                           Show this help\n\n",
    "Connection settings:\n",
    "  --scheme <scheme>                    URL scheme (default: https)\n",
    "  --host <hostname>                    DHIS2 hostname\n",
    "  --port <port>                        DHIS2 port\n",
    "  --path <path>                        API base path\n",
    sep = ""
  )
}

long_map <- list(
  "backup-dataset" = "backupDataset",
  "host" = "hostname"
)

short_map <- list(
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
  B = "backupDataset",
  q = "quiet",
  V = "verbose",
  D = "debug",
  h = "help"
)

getValidationExceptions <- function(x) {
  x <- as_null(x)
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
  logWarn("Validation exception file not found: '{validationExceptionFile}'")
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
    include_country = "full",
    include_department = "pseudo",
    include_world_bank_class = "full",
    include_patient = "full",
    patient_columns = c("id", "sex", "birth_weight", "gestational_age",
                         "delivery_mode", "siblings"),
    include_enrollment = "full",
    include_event = "full",
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

backupReferenceDataset <- function(data, backupPath) {
  timeoutSeconds <- 60
  sevenZip <- Sys.which("7z")
  if (is.na(sevenZip) || sevenZip == "") {
    if (.Platform$OS.type == "windows") {
      candidates <- c(
        file.path(
          Sys.getenv("ProgramFiles"),
          "7-Zip",
          "7z.exe"
        ),
        file.path(
          Sys.getenv("ProgramFiles(x86)"),
          "7-Zip",
          "7z.exe"
        )
      )
      candidates <- candidates[file.exists(candidates)]
      if (length(candidates) > 0) {
        sevenZip <- candidates[[1]]
      }
    }
  }
  if (is.na(sevenZip) || sevenZip == "") {
    stop("7z is required for --backup-dataset but was not found in PATH.")
  }
  password <- Sys.getenv("NEOIPC_BACKUP_PASSWORD", unset = NA)
  if (is.na(password) || identical(password, "")) {
    password <- readline("Backup password: ")
  }
  json <- jsonlite::serializeJSON(
    data,
    pretty = FALSE
  )
  args <- c(
    "a",
    "-t7z",
    "-mx=9",
    "-m0=lzma2",
    "-ms=on",
    "-mhe=on",
    "-y",
    "-aoa",
    paste0("-p", password),
    backupPath,
    "-siReferenceData.json"
  )
  if (verbosity == "quiet") {
    args <- c(args, "-bso0", "-bse0", "-bd")
  }
  escapePosixArg <- function(value) {
    if (value == "") {
      "''"
    } else {
      paste0("'", gsub("'", "'\\''", value, fixed = TRUE), "'")
    }
  }
  escapeCmdArg <- function(value) {
    escaped <- gsub("\"", "\\\"", value)
    escaped <- gsub("\\^", "^^", escaped)
    escaped <- gsub("&", "^&", escaped, fixed = TRUE)
    escaped <- gsub("\\|", "^|", escaped)
    escaped <- gsub("<", "^<", escaped, fixed = TRUE)
    escaped <- gsub(">", "^>", escaped, fixed = TRUE)
    paste0("\"", escaped, "\"")
  }
  if (.Platform$OS.type == "windows") {
    escapedArgs <- vapply(args, escapeCmdArg, character(1))
    command <- paste0(
      "cmd /s /c \"\"",
      sevenZip,
      "\" ",
      paste(escapedArgs, collapse = " "),
      "\""
    )
  } else {
    escapedArgs <- vapply(args, escapePosixArg, character(1))
    command <- paste(
      escapePosixArg(sevenZip),
      paste(escapedArgs, collapse = " ")
    )
  }
  con <- pipe(command, "wb")
  on.exit(
    if (!is.null(con)) {
      close(con)
    },
    add = TRUE
  )
  setTimeLimit(elapsed = timeoutSeconds, transient = TRUE)
  on.exit(setTimeLimit(elapsed = Inf, transient = FALSE), add = TRUE)
  writeBin(charToRaw(json), con)
  flush(con)
  status <- close(con)
  con <- NULL
  if (!is.null(status) && status != 0) {
    stop("7z backup failed with exit code: ", status)
  }
  if (!file.exists(backupPath)) {
    stop("7z backup did not create archive: ", backupPath)
  }
  invisible(TRUE)
}

args <- parse_args(commandArgs(trailingOnly = TRUE),
  long_map = long_map, short_map = short_map)

if (isTRUE(args$help)) {
  printUsage()
  quit(status = 0)
}

# Verbosity precedence: an explicit CLI flag wins; otherwise inherit
# NEOIPC_LOG_LEVEL (set by the PowerShell wrapper or the .NET service);
# otherwise default to normal. Republish the resolved level so neoipcr and any
# child processes share it.
verbosity <- if (isTRUE(args$quiet)) {
  "quiet"
} else if (isTRUE(args$debug)) {
  "debug"
} else if (isTRUE(args$verbose)) {
  "verbose"
} else {
  Sys.getenv("NEOIPC_LOG_LEVEL", unset = "normal")
}
Sys.setenv(NEOIPC_LOG_LEVEL = verbosity)

configure_logging(report = "reference-report", verbosity = verbosity)

referenceDataFile <- as_null(args$file)
reportingPeriodFrom <- as_date_or_null(args$reportingPeriodFrom)
reportingPeriodTo <- as_date_or_null(args$reportingPeriodTo)
birthWeightFrom <- as_number_or_null(args$birthWeightFrom)
birthWeightTo <- as_number_or_null(args$birthWeightTo)
gestationWeeksFrom <- as_number_or_null(args$gestationWeeksFrom)
gestationWeeksTo <- as_number_or_null(args$gestationWeeksTo)
reportingCountries <- as_vector_or_null(args$reportingCountries)
includeTestUnits <- as_bool(args$includeTestUnits, default = FALSE)
includeNonCorePatients <- as_bool(
  args$includeNonCorePatients,
  default = FALSE
)
validationExceptionFile <- as_null(args$validationExceptionFile)
backupDataset <- as_null(args$backupDataset)

# get_connection_options() supplies the production host default when --host is
# omitted (neoipcr itself no longer defaults to any deployment).
connectionOptions <- get_connection_options(
  scheme = args$scheme, hostname = args$hostname,
  port = args$port, path = args$path)
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
rawData <- neoipcr::import_dhis2(
  connection_options = connectionOptions,
  dataset_options = datasetOptions
)
if (!is.null(backupDataset)) {
  backupPath <- backupDataset
  if (is.na(backupPath) || backupPath == "") {
    stop("--backup-dataset requires a file path.")
  }
  logVerbose("Creating encrypted backup: {backupPath}")
  backupReferenceDataset(rawData, backupPath)
}
referenceData <- neoipcr::calculate_reference_data(rawData)

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
  logInfo("Reference data written to: {referenceDataFile}")
}
