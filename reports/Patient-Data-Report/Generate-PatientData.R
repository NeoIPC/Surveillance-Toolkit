#!/usr/bin/env Rscript

script_dir <- dirname(
  sub("--file=", "", grep("--file=", commandArgs(FALSE), value = TRUE)[1]))
suppressPackageStartupMessages({
  source(file.path(script_dir, "../common/load-neoipcr.R"))
  load_neoipcr(dev_pkg_path = file.path(script_dir, "../../neoipcr"))
  source(file.path(script_dir, "../common/parse-args.R"))
  source(file.path(script_dir, "../common/logging.R"))
  source(file.path(script_dir, "../common/helpers.R"))
  library(jsonlite)
  library(dplyr, warn.conflicts = FALSE)
})

print_usage <- function() {
  cat(
    "Usage: Rscript --vanilla reports/Patient-Data-Report/Generate-PatientData.R [options]\n\n",
    "Export all surveillance data for a single patient as JSON.\n",
    "Authentication is handled by neoipcr via environment variables\n",
    "(NEOIPC_DHIS2_TOKEN or NEOIPC_DHIS2_SESSION_ID) or interactive\n",
    "prompts.\n\n",
    "Required:\n",
    "  --patient-id, -p <id>           NeoIPC patient ID\n",
    "  --department, -d <code>         Department code\n\n",
    "Options:\n",
    "  --output, -o <path>             Output file path (stdout if omitted)\n",
    "  --quiet, -q                     Suppress non-critical output\n",
    "  --verbose, -V                   Verbose output\n",
    "  --debug, -D                     Debug output\n\n",
    "Connection settings:\n",
    "  --scheme <scheme>               URL scheme (default: https)\n",
    "  --host <hostname>               DHIS2 hostname\n",
    "  --port <port>                   DHIS2 port\n",
    "  --path <path>                   API base path\n\n",
    "  --help, -h                      Show this help\n",
    sep = ""
  )
}

long_map <- list(
  "patient-id" = "patientId",
  "department" = "department"
)

short_map <- list(
  p = "patientId",
  d = "department",
  o = "output",
  q = "quiet",
  V = "verbose",
  D = "debug",
  h = "help"
)

args <- parse_args(commandArgs(trailingOnly = TRUE),
  long_map = long_map, short_map = short_map)

if (isTRUE(args$help)) {
  print_usage()
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

configure_logging(report = "patient-data-report", verbosity = verbosity)

patient_id <- as_null(args$patientId)
department_code <- as_null(args$department)

if (is.null(patient_id)) {
  logError("--patient-id is required.")
  quit(status = 1)
}
if (is.null(department_code)) {
  logError("--department is required.")
  quit(status = 1)
}

# Connection options — auth handled by neoipcr via env vars or interactive
# prompt. get_connection_options() supplies the production host default when
# --host is omitted (neoipcr itself no longer defaults to any deployment).
conn_opt <- get_connection_options(
  scheme = args$scheme, hostname = args$host,
  port = args$port, path = args$path)

ds_opt <- neoipcr::dhis2_dataset_options(
  department_filter = department_code,
  include_patient = "full",
  patient_columns = c("id", "sex", "birth_weight", "gestational_age",
                       "delivery_mode", "siblings"),
  include_enrollment = "full",
  include_event = "full",
  include_country = "full",
  include_hospital = "full",
  include_department = "full",
  include_user = "pseudo",
  include_timestamps = TRUE,
  include_notes = c("enrollments", "events"),
  include_test_data = TRUE,
  include_invalid_patients = TRUE,
  include_ineligible_patients = TRUE,
  include_incomplete = c("enrollments", "events"),
  translate = TRUE
)

ds <- neoipcr::import_dhis2(connection_options = conn_opt, dataset_options = ds_opt)

# Filter to the requested patient
patient <- ds$patients |> dplyr::filter(patient_id == !!patient_id)

if (nrow(patient) == 0) {
  logError("No patient with ID '{patient_id}' found in department '{department_code}'.")
  quit(status = 1)
}

pk <- patient$patient_key

result <- list(
  patient = patient,
  enrollment = ds$enrollments |> dplyr::filter(patient_key == pk),
  events = ds$events |> dplyr::filter(patient_key == pk),
  admission = ds$admissionData |>
    dplyr::semi_join(ds$events |> dplyr::filter(patient_key == pk),
      by = "event_key"),
  surveillanceEnd = ds$surveillanceEndData |>
    dplyr::semi_join(ds$events |> dplyr::filter(patient_key == pk),
      by = "event_key"),
  sepsis = ds$sepsisData |>
    dplyr::semi_join(ds$events |> dplyr::filter(patient_key == pk),
      by = "event_key"),
  nec = ds$necData |>
    dplyr::semi_join(ds$events |> dplyr::filter(patient_key == pk),
      by = "event_key"),
  pneumonia = ds$pneumoniaData |>
    dplyr::semi_join(ds$events |> dplyr::filter(patient_key == pk),
      by = "event_key"),
  ssi = ds$ssiData |>
    dplyr::semi_join(ds$events |> dplyr::filter(patient_key == pk),
      by = "event_key"),
  surgery = ds$surgeryData |>
    dplyr::semi_join(ds$events |> dplyr::filter(patient_key == pk),
      by = "event_key"),
  substanceDays = ds$substanceDays |>
    dplyr::semi_join(ds$events |> dplyr::filter(patient_key == pk),
      by = "event_key"),
  infectiousAgentFindings = ds$infectiousAgentFindings |>
    dplyr::semi_join(ds$events |> dplyr::filter(patient_key == pk),
      by = "event_key"),
  department = ds$metadata$departments |>
    dplyr::filter(department_key == patient$department_key),
  hospital = ds$metadata$hospitals |>
    dplyr::filter(hospital_key == patient$hospital_key)
)

out <- jsonlite::toJSON(result, pretty = TRUE, auto_unbox = TRUE,
  Date = "ISO8601", POSIXt = "ISO8601", null = "null", na = "null")

output_path <- as_null(args$output)
if (is.null(output_path)) {
  cat(out)
} else {
  writeLines(out, output_path, useBytes = TRUE)
  logInfo("Patient data written to '{output_path}'.")
}
