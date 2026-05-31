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
  library(jsonlite)
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
    "reports/Partner-Report/Generate-PartnerData.R [options]\n\n",
    "Generate partner data JSON for one or more departments.\n",
    "Authentication is handled by neoipcr via environment variables\n",
    "(NEOIPC_DHIS2_TOKEN or NEOIPC_DHIS2_SESSION_ID) or interactive\n",
    "prompts.\n\n",
    "Required:\n",
    "  --unitCodes, -u <codes>           Comma-separated department codes\n\n",
    "Options:\n",
    "  --file, -f <path>                 Output JSON file path\n",
    "                                    (stdout if omitted)\n",
    "  --referenceDataFile, -r <path>    Pre-computed reference data JSON\n",
    "  --reportingPeriodFrom, -s <date>  YYYY-MM-DD\n",
    "  --reportingPeriodTo, -e <date>    YYYY-MM-DD\n",
    "  --birthWeightFrom, -w <number>    Minimal included birth weight\n",
    "  --birthWeightTo, -W <number>      Maximal included birth weight\n",
    "  --gestationWeeksFrom, -g <number> Minimal included gestational age\n",
    "  --gestationWeeksTo, -G <number>   Maximal included gestational age\n",
    "  --includeNonCorePatients, -n      Include non-core patients\n",
    "  --validationExceptionFile, -v <path> Input CSV file path\n",
    "  --quiet, -q                       Suppress non-critical output\n",
    "  --verbose, -V                     Verbose output\n",
    "  --debug, -D                       Debug output\n",
    "  --help, -h                        Show this help\n\n",
    "Connection settings:\n",
    "  --scheme <scheme>                 URL scheme (default: https)\n",
    "  --host <hostname>                 DHIS2 hostname\n",
    "  --port <port>                     DHIS2 port\n",
    "  --path <path>                     API base path\n",
    sep = ""
  )
}

long_map <- list(
  "host" = "hostname"
)

short_map <- list(
  f = "file",
  u = "unitCodes",
  r = "referenceDataFile",
  s = "reportingPeriodFrom",
  e = "reportingPeriodTo",
  w = "birthWeightFrom",
  W = "birthWeightTo",
  g = "gestationWeeksFrom",
  G = "gestationWeeksTo",
  n = "includeNonCorePatients",
  v = "validationExceptionFile",
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
  if (file.exists(x)) {
    header <- utils::read.csv(x, nrows = 0, stringsAsFactors = FALSE)
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
    return(utils::read.csv(x, stringsAsFactors = FALSE, colClasses = colClasses))
  }
  logWarn(sprintf("Validation exception file not found: '%s'", x))
  FALSE
}

args <- parse_args(commandArgs(trailingOnly = TRUE),
  long_map = long_map, short_map = short_map)

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

outputFile <- as_null(args$file)
unitCodes <- as_vector_or_null(args$unitCodes)
referenceDataFile <- as_null(args$referenceDataFile)
reportingPeriodFrom <- as_date_or_null(args$reportingPeriodFrom)
reportingPeriodTo <- as_date_or_null(args$reportingPeriodTo)
birthWeightFrom <- as_number_or_null(args$birthWeightFrom)
birthWeightTo <- as_number_or_null(args$birthWeightTo)
gestationWeeksFrom <- as_number_or_null(args$gestationWeeksFrom)
gestationWeeksTo <- as_number_or_null(args$gestationWeeksTo)
includeNonCorePatients <- as_bool(args$includeNonCorePatients, default = FALSE)
validationExceptionFile <- as_null(args$validationExceptionFile)

if (is.null(unitCodes)) {
  cat("Error: --unitCodes is required.\n", file = stderr())
  quit(status = 1)
}

# Connection options
conn_args <- list()
if (!is.null(args$scheme)) conn_args$scheme <- args$scheme
if (!is.null(args$hostname)) conn_args$hostname <- args$hostname
if (!is.null(args$port)) conn_args$port <- args$port
if (!is.null(args$path)) conn_args$path <- args$path
connectionOptions <- do.call(neoipcr::dhis2_connection_options, conn_args)

# Dataset options (mirrors _setup.qmd)
datasetOptions <- neoipcr::dhis2_dataset_options(
  department_filter = unitCodes,
  surveillance_end_from = reportingPeriodFrom,
  surveillance_end_to = reportingPeriodTo,
  birth_weight_from = birthWeightFrom,
  birth_weight_to = birthWeightTo,
  gestational_age_from = gestationWeeksFrom,
  gestational_age_to = gestationWeeksTo,
  include_ineligible_patients = includeNonCorePatients,
  include_invalid_patients = getValidationExceptions(validationExceptionFile),
  include_world_bank_class = "yes",
  include_country = "yes",
  include_hospital = "yes",
  include_department = "yes",
  include_test_data = TRUE
)

logVerbose("Importing DHIS2 data...")
unit_data <- suppressWarnings(
  neoipcr::import_dhis2(
    connection_options = connectionOptions,
    dataset_options = datasetOptions
  )
) |> neoipcr::calculate_department_data()

# Load reference data if provided
reference_data <- NULL
if (!is.null(referenceDataFile)) {
  if (!file.exists(referenceDataFile)) {
    stop(sprintf("Reference data file not found: '%s'", referenceDataFile))
  }
  logVerbose("Loading reference data: ", referenceDataFile)
  reference_data <- jsonlite::unserializeJSON(
    readChar(referenceDataFile, file.info(referenceDataFile)$size))
}

# If reference data is provided, produce a neoipcr_bnch_ds (benchmark).
# Otherwise, output the neoipcr_rep_ds (department data) directly.
output_data <- if (!is.null(reference_data)) {
  logVerbose("Computing benchmark data...")
  neoipcr::get_benchmark_data(own = unit_data, ref = reference_data)
} else {
  unit_data
}

logDebug("Data generation completed.")

json <- jsonlite::serializeJSON(output_data, pretty = TRUE)
if (is.null(outputFile)) {
  cat(json)
} else {
  outputDir <- dirname(outputFile)
  if (!dir.exists(outputDir)) {
    dir.create(outputDir, recursive = TRUE, showWarnings = FALSE)
  }
  writeLines(json, outputFile, useBytes = TRUE)
  logInfo("Partner data written to: ", outputFile)
}
