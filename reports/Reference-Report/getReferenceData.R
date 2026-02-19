#!/usr/bin/env Rscript
library("argparse")
library("neoipcr")
library("jsonlite")

parser <- ArgumentParser(description='Get NeoIPC Surveiullance reference data from a DHIS2 server')

parser$add_argument(
  "--tee",
  type="character",
  default="",
  help="Path of the output file",
  metavar="FILE"
)

parser$add_argument(
  "--raw",
  help="Write raw JSON instead of serialized S3 objects",
  action='store_true'
)

filter_group <- parser$add_argument_group("Filter settings")
filter_group$add_argument(
  "--date-from",
  type="character",
  default=NULL,
  help="Minimum surveillance end date of patient records to include",
  metavar="DATE")
filter_group$add_argument(
  "--date-to",
  type="character",
  default=NULL,
  help="Maximum surveillance end date of patient records to include",
  metavar="DATE")
filter_group$add_argument(
  "--birth-weight-from",
  type="integer",
  default=NULL,
  help="Minimum birth weight (in grams) of patient records to include",
  metavar="GRAMS")
filter_group$add_argument(
  "--birth-weight-to",
  type="integer",
  default=NULL,
  help="Maximum birth weight (in grams) of patient records to include",
  metavar="GRAMS")
filter_group$add_argument(
  "--gestational-age-from",
  type="integer",
  default=NULL,
  help="Minimum gestational age (in completed weeks) of patient records to include",
  metavar="WEEKS")
filter_group$add_argument(
  "--gestational-age-to",
  type="integer",
  default=NULL,
  help="Maximum gestational age (in completed weeks) of patient records to include",
  metavar="WEEKS")
filter_group$add_argument(
  "--countries",
  type="character",
  default=NULL,
  help="ISO 3166 country codes of the countries the enrolling departments are located in to include",
  metavar="COUNTRY_CODE[,...]")
filter_group$add_argument(
  "--include-invalid-patients",
  type="character",
  default="FALSE",
  help="TRUE to include data from patient records that have validation errors. A CSV-file containing the exceptions if validation should be skipped for some records only.",
  metavar="FILE")

url_group <- parser$add_argument_group("Connection settings")
url_group$add_argument(
  "--scheme",
  type="character",
  default="https",
  help="URL scheme of the DHIS2 host")
url_group$add_argument(
  "--host",
  type="character",
  default="neoipc.charite.de",
  help="Name of the DHIS2 host")
url_group$add_argument(
  "--port",
  type="integer",
  default=NULL,
  help="Port of the DHIS2 host")
url_group$add_argument(
  "--path",
  type="character",
  default="/api",
  help="API base path on the DHIS2 host")

credential_group <- parser$add_argument_group("Credential settings")
ecg <- credential_group$add_mutually_exclusive_group()
#ecg <- parser$add_mutually_exclusive_group()
ecg$add_argument(
  "--token",
  type="character",
  default=NULL,
  help="DHIS2 personal access token or path to a file containing the token")
ecg$add_argument(
  "--username",
  type="character",
  default=NULL,
  help="DHIS2 username")
ecg$add_argument(
  "--session-id",
  type="character",
  default=NULL,
  help="DHIS2 session id")


opt <- parser$parse_args()

if (!is.null(opt$token)) {
  conn_opt <- dhis2_connection_options(token = opt$token, scheme = opt$scheme, hostname = opt$host, port = opt$port, path = opt$path)
} else if(!is.null(opt$username)) {
  conn_opt <- dhis2_connection_options(username = opt$username, scheme = opt$scheme, hostname = opt$host, port = opt$port, path = opt$path)
} else if (!is.null(opt$session_id)) {
  conn_opt <- dhis2_connection_options(session_id = opt$session_id, scheme = opt$scheme, hostname = opt$host, port = opt$port, path = opt$path)
} else {
  conn_opt <- dhis2_connection_options(scheme = opt$scheme, hostname = opt$host, port = opt$port, path = opt$path)
}

surveillance_end_from <- as.Date(opt$date_from)
if (length(surveillance_end_from) == 0) {
  surveillance_end_from <- NULL
}

surveillance_end_to <- as.Date(opt$date_to)
if (length(surveillance_end_to) == 0) {
  surveillance_end_to <- NULL
}

birth_weight_from <- as.integer(opt$birth_weight_from)
if (length(birth_weight_from) == 0) {
  birth_weight_from <- NULL
}

birth_weight_to <- as.integer(opt$birth_weight_to)
if (length(birth_weight_to) == 0) {
  birth_weight_to <- NULL
}

gestational_age_from <- as.integer(opt$gestational_age_from)
if (length(gestational_age_from) == 0) {
  gestational_age_from <- NULL
}

gestational_age_to <- as.integer(opt$gestational_age_to)
if (length(gestational_age_to) == 0) {
  gestational_age_to <- NULL
}

country_filter <- opt$countries
if (!is.null(country_filter)) {
  country_filter <- strsplit(opt$countries, ",", fixed = TRUE) |>
    unlist()
}

include_invalid_patients <- as.logical(opt$include_invalid_patients)
if (is.na(include_invalid_patients) || length(include_invalid_patients) == 0) {
  include_invalid_patients <- opt$include_invalid_patients
}

ds_opt <- dhis2_dataset_options(
  surveillance_end_from = surveillance_end_from,
  surveillance_end_to = surveillance_end_to,
  birth_weight_from = birth_weight_from,
  birth_weight_to = birth_weight_to,
  gestational_age_from = gestational_age_from,
  gestational_age_to = gestational_age_to,
  country_filter = country_filter,
  include_invalid_patients = include_invalid_patients,
  include_country = "yes",
  include_department = "pseudonymised",
  include_world_bank_class = "yes"
)

rd <- import_dhis2(connection_options = conn_opt, dataset_options = ds_opt) |>
    calculate_reference_data()

if (opt$raw) {
  out <- toJSON(rd)
} else {
  out <- serializeJSON(rd)
}

write(out, "")

if (opt$tee != "") {
  write(out, opt$tee)
}
