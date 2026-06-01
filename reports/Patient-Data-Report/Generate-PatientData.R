#!/usr/bin/env Rscript

script_dir <- dirname(
  sub("--file=", "", grep("--file=", commandArgs(FALSE), value = TRUE)[1]))
suppressPackageStartupMessages({
  source(file.path(script_dir, "../common/load-neoipcr.R"))
  load_neoipcr(dev_pkg_path = file.path(script_dir, "../../neoipcr"))
  source(file.path(script_dir, "../common/parse-args.R"))
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
    "  --output, -o <path>             Output file path (stdout if omitted)\n\n",
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
  h = "help"
)

args <- parse_args(commandArgs(trailingOnly = TRUE),
  long_map = long_map, short_map = short_map)

if (isTRUE(args$help)) {
  print_usage()
  quit(status = 0)
}

patient_id <- as_null(args$patientId)
department_code <- as_null(args$department)

if (is.null(patient_id)) {
  cat("Error: --patient-id is required.\n", file = stderr())
  quit(status = 1)
}
if (is.null(department_code)) {
  cat("Error: --department is required.\n", file = stderr())
  quit(status = 1)
}

# Connection options — auth handled by neoipcr via env vars or interactive prompt
conn_args <- list()
if (!is.null(args$scheme)) conn_args$scheme <- args$scheme
if (!is.null(args$host)) conn_args$hostname <- args$host
if (!is.null(args$port)) conn_args$port <- args$port
if (!is.null(args$path)) conn_args$path <- args$path
conn_opt <- do.call(neoipcr::dhis2_connection_options, conn_args)

ds_opt <- neoipcr::dhis2_dataset_options(
  department_filter = department_code,
  include_patient_id = TRUE,
  include_country = "yes",
  include_hospital = "yes",
  include_department = "yes",
  include_user = "pseudonymised",
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
patient <- ds$patients |> dplyr::filter(.data$patient_id == !!patient_id)

if (nrow(patient) == 0) {
  cat(sprintf("Error: No patient with ID '%s' found in department '%s'.\n",
    patient_id, department_code), file = stderr())
  quit(status = 1)
}

if (nrow(patient) > 1) {
  cat(sprintf("Error: %d patient records share ID '%s' in department '%s' — refusing to render ambiguous report.\n",
    nrow(patient), patient_id, department_code), file = stderr())
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

# Plain `jsonlite::toJSON` (not `serializeJSON`) — the Patient-Data-Report
# JSON output is intended for external/human consumption (downstream
# pipelines, manual inspection), not for round-trip back into a Quarto
# render. The Reference- and Partner-Report generators use `serializeJSON`
# because their reports consume the output via a DataFile mode that needs
# to restore tibbles, factors, dates and S3 classes faithfully; that mode
# is deliberately not wired up here.
out <- jsonlite::toJSON(result, pretty = TRUE, auto_unbox = TRUE,
  Date = "ISO8601", POSIXt = "ISO8601", null = "null", na = "null")

output_path <- as_null(args$output)
if (is.null(output_path)) {
  cat(out)
} else {
  writeLines(out, output_path, useBytes = TRUE)
  cat(sprintf("Patient data written to '%s'.\n", output_path), file = stderr())
}
