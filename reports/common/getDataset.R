#!/usr/bin/env Rscript

script_dir <- dirname(
  sub("--file=", "", grep("--file=", commandArgs(FALSE), value = TRUE)[1]))
suppressPackageStartupMessages({
  source(file.path(script_dir, "load-neoipcr.R"))
  load_neoipcr(dev_pkg_path = file.path(script_dir, "../../neoipcr"))
  source(file.path(script_dir, "parse-args.R"))
  library(jsonlite)
})

print_usage <- function() {
  cat(
    "Usage: Rscript --vanilla reports/common/getDataset.R [options]\n\n",
    "Get a NeoIPC Surveillance dataset from a DHIS2 server.\n",
    "Authentication is handled by neoipcr via environment variables\n",
    "(NEOIPC_DHIS2_TOKEN or NEOIPC_DHIS2_SESSION_ID) or interactive\n",
    "prompts.\n\n",
    "Options:\n",
    "  --output, -o <path>                  Output file path (stdout if omitted)\n",
    "  --raw, -r                            Write raw JSON instead of serialized\n",
    "                                       S3 objects (default: TRUE)\n",
    "  --no-raw                             Write serialized S3 objects\n\n",
    "Filter settings:\n",
    "  --date-from <date>                   Minimum surveillance end date\n",
    "  --date-to <date>                     Maximum surveillance end date\n",
    "  --birth-weight-from <grams>          Minimum birth weight (grams)\n",
    "  --birth-weight-to <grams>            Maximum birth weight (grams)\n",
    "  --gestational-age-from <weeks>       Minimum gestational age (weeks)\n",
    "  --gestational-age-to <weeks>         Maximum gestational age (weeks)\n",
    "  --countries <codes>                  Comma-separated ISO 3166 codes\n",
    "  --include-invalid-patients <val>     TRUE, FALSE, or CSV exception file\n\n",
    "Connection settings:\n",
    "  --scheme <scheme>                    URL scheme (default: https)\n",
    "  --host <hostname>                    DHIS2 hostname\n",
    "  --port <port>                        DHIS2 port\n",
    "  --path <path>                        API base path\n\n",
    "  --help, -h                           Show this help\n",
    sep = ""
  )
}

long_map <- list(
  "date-from" = "dateFrom",
  "date-to" = "dateTo",
  "birth-weight-from" = "birthWeightFrom",
  "birth-weight-to" = "birthWeightTo",
  "gestational-age-from" = "gestationalAgeFrom",
  "gestational-age-to" = "gestationalAgeTo",
  "include-invalid-patients" = "includeInvalidPatients",
  "no-raw" = "noRaw"
)

short_map <- list(
  o = "output",
  r = "raw",
  h = "help"
)

args <- parse_args(commandArgs(trailingOnly = TRUE),
  long_map = long_map, short_map = short_map)

if (isTRUE(args$help)) {
  print_usage()
  quit(status = 0)
}

# Connection options — auth handled by neoipcr via env vars or interactive prompt
conn_args <- list()
if (!is.null(args$scheme)) conn_args$scheme <- args$scheme
if (!is.null(args$host)) conn_args$hostname <- args$host
if (!is.null(args$port)) conn_args$port <- args$port
if (!is.null(args$path)) conn_args$path <- args$path
conn_opt <- do.call(neoipcr::dhis2_connection_options, conn_args)

# Dataset options
surveillance_end_from <- as_date_or_null(args$dateFrom)
surveillance_end_to <- as_date_or_null(args$dateTo)
birth_weight_from <- as_number_or_null(args$birthWeightFrom)
birth_weight_to <- as_number_or_null(args$birthWeightTo)
gestational_age_from <- as_number_or_null(args$gestationalAgeFrom)
gestational_age_to <- as_number_or_null(args$gestationalAgeTo)
country_filter <- as_vector_or_null(args$countries)

include_invalid_patients <- as_null(args$includeInvalidPatients)
if (!is.null(include_invalid_patients)) {
  bool_val <- as_bool(include_invalid_patients)
  if (!is.null(bool_val)) {
    include_invalid_patients <- bool_val
  }
  # else it's a file path — pass as-is
}

ds_opt <- neoipcr::dhis2_dataset_options(
  surveillance_end_from = surveillance_end_from,
  surveillance_end_to = surveillance_end_to,
  birth_weight_from = birth_weight_from,
  birth_weight_to = birth_weight_to,
  gestational_age_from = gestational_age_from,
  gestational_age_to = gestational_age_to,
  country_filter = country_filter,
  include_invalid_patients = include_invalid_patients,
  include_country = "full",
  include_world_bank_class = "full",
  include_patient = "full",
  patient_columns = c("id", "sex", "birth_weight", "gestational_age",
                       "delivery_mode", "siblings"),
  include_enrollment = "full",
  include_event = "full"
)

ds <- neoipcr::import_dhis2(connection_options = conn_opt, dataset_options = ds_opt)

use_raw <- !isTRUE(args$noRaw)
if (use_raw) {
  out <- jsonlite::serializeJSON(ds)
} else {
  out <- jsonlite::toJSON(ds)
}

output_path <- as_null(args$output)
if (is.null(output_path)) {
  cat(out)
} else {
  writeLines(out, output_path, useBytes = TRUE)
}
