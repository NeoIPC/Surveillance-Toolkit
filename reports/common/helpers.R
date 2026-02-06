# Common helper functions for NeoIPC Surveillance reports
# This file is sourced by all report types

parse_locales <- function(x) {
  locales <- NULL
  # split language and territory
  lists <- strsplit(x = x, split = "_")

  for(parts in lists){
    ret <- list()
    if(length(parts) > 1)
    {
      ret$language = parts[1]
      remainder <- parts[2]
      has_language <- TRUE
      has_territory <- TRUE
    } else {
      remainder <- parts[1]
      has_language <- FALSE
      has_territory <- FALSE
    }
    parts <- strsplit(x = remainder, split = "\\.")[[1]]
    if(length(parts) > 1)
    {
      if(has_territory){
        ret$territory = parts[1]
      } else {
        ret$language = parts[1]
      }
      remainder <- parts[2]
      has_codeset <- TRUE
    } else {
      remainder <- parts[1]
      has_codeset <- FALSE
    }
    parts <- strsplit(x = remainder, split = "@")[[1]]
    if(length(parts) > 1)
    {
      ret$modifier <- parts[2]
      has_modifier <- TRUE
    }

    if(has_codeset){
      ret$codeset = parts[1]
    } else if (has_territory) {
      ret$territory = parts[1]
    } else {
      ret$language = parts[1]
    }
    locales <- c(locales, list(ret))
  }
  return(locales)
}

get_string_resources <- function(x) {
  handlers <- list('bool#no' = function(x) x)
  sR <- modifyList(
    yaml::read_yaml("../common.yaml", handlers = handlers),
    yaml::read_yaml("content/_sR.yaml", handlers = handlers)
  )

  yaml_path <- paste0("../common.", localeObj$language, ".yaml")
  if(file.exists(yaml_path)) sR <- modifyList(
    sR,
    yaml::read_yaml(file = yaml_path, handlers = handlers))

  yaml_path <- paste0("../common.", localeObj$language, "_", localeObj$territory, ".yaml")
  if(file.exists(yaml_path)) sR <- modifyList(
    sR,
    yaml::read_yaml(file = yaml_path, handlers = handlers))

  yaml_path <- paste0("content.", localeObj$language, "/_sR.yaml")
  if(file.exists(yaml_path)) sR <- modifyList(
    sR,
    yaml::read_yaml(file = yaml_path, handlers = handlers))

  yaml_path <- paste0("content.", localeObj$language, "_", localeObj$territory, "/_sR.yaml")
  if(file.exists(yaml_path)) sR <- modifyList(
    sR,
    yaml::read_yaml(file = yaml_path, handlers = handlers))

  return(sR)
}

get_localised_path <- function(file_name, language, territory) {
  yaml_path <- paste0("content.", language, "_", territory, "/", file_name)
  if(file.exists(yaml_path)) {
    return(yaml_path)
  }

  yaml_path <- paste0("content.", language, "/", file_name)
  if(file.exists(yaml_path)) {
      return(yaml_path)
  }

  return(paste0("content/", file_name))
}

include_localised <- function(file_name) {
  cat(
    sep = "\n",
    knitr::knit_child(
      text = readr::read_file(
        get_localised_path(
          file_name,
          localeObj$language,
          localeObj$territory)),
      quiet = TRUE)
  )
}

get_localised_country_names <- function(x) {
  x |>
    purrr::map_chr(
      \(x) {
        val <- sR$countryNames[[stringr::str_replace_all(as.character(x), " ", "")]]
        if(is.null(val)) x else val
      })
}

get_localised_world_bank_class_names <- function(x) {
  x |>
    purrr::map_chr(
      \(x) {
        val <- sR$worldBankClassNames[[as.character(x)]]
        if(is.null(val)) x else val
      })
}

get_validation_exceptions <- function(x) {
  validationExceptionFile = dplyr::coalesce(x, "validation-exceptions_ref.csv")
  if (file.exists(validationExceptionFile)) {
    return(read_csv(validationExceptionFile, show_col_types = FALSE))
  } else {
    warning(sprintf("Validation ecxeption file not found: '%s'", validationExceptionFile))
    return(FALSE)
  }
}

get_connection_options <- function(x) {
  token <- dplyr::coalesce(x, Sys.getenv("NEOIPC_DHIS2_TOKEN", unset = NA))
  session_id <- Sys.getenv("NEOIPC_DHIS2_SESSION_ID", unset = NA)
  if(!is.na(session_id)) {
    return(neoipcr::dhis2_connection_options(session_id = session_id))
  } else if (!is.na(token)) {
    return(neoipcr::dhis2_connection_options(token = token))
  } else {
    return(neoipcr::dhis2_connection_options())
  }
}

get_dataset_options <- function(
    reportingPeriodFrom,
    reportingPeriodTo,
    birthWeightFrom,
    birthWeightTo,
    gestationWeeksFrom,
    gestationWeeksTo,
    reportingCountries,
    testUnitFilter,
    defaultPatientFilter,
    validationExceptionFile
    )  neoipcr::dhis2_dataset_options(
      include_world_bank_class = "yes",
      include_country = "yes",
      include_department = "pseudonymised",
      surveillance_end_from = lubridate::as_date(
        dplyr::coalesce(reportingPeriodFrom, "2024-01-01")),
      surveillance_end_to = lubridate::as_date(
        dplyr::coalesce(reportingPeriodTo, as.character(Sys.Date()))),
      birth_weight_from = birthWeightFrom,
      birth_weight_to = birthWeightTo,
      gestational_age_from = gestationWeeksFrom,
      gestational_age_to = gestationWeeksTo,
      country_filter = reportingCountries,
      include_test_data = !dplyr::coalesce(testUnitFilter, TRUE),
      include_ineligible_patients = !dplyr::coalesce(defaultPatientFilter, TRUE),
      include_invalid_patients = get_validation_exceptions(
        validationExceptionFile))

#' Format integer with locale-specific thousand separator
#' @param x numeric value to format
#' @param big_mark thousand separator character
#' @return formatted string
format_integer <- function(x, big_mark = sR$digit_group_separator)
  dplyr::if_else(x < 10000, format(as.integer(x), big.mark = ""), format(as.integer(x), big.mark = big_mark))

#' Format countries grouped by World Bank class
#' @param countries Tibble with displayName and optionally wb_class_name
#' @param include_wb_class Whether to include WB class ("no", "pseudonymised", "yes")
#' @return Formatted string with countries grouped by WB class, or simple list if not showing WB class
format_countries <- function(countries) {
  if (is.null(countries)) {
    return(NULL)
  }

  countries <- countries |>
    dplyr::mutate(
      name = get_localised_country_names(.data$name))

  # Group by WB class and format
  if("wb_class" %in% rlang::names2(countries)) {
    formatted <- countries |>
      dplyr::arrange(.data$wb_class, .data$name) |>
      dplyr::group_by(
        wb_class = get_localised_world_bank_class_names(.data$wb_class)) |>
      dplyr::summarise(
        country_list = paste(.data$name, collapse = ", "),
        .groups = "drop")|>
      dplyr::mutate(
        formatted = paste0(.data$wb_class, ": ", .data$country_list)
      ) |>
      dplyr::pull("formatted") |>
      paste(collapse = "; ")
  } else {
    formatted <- countries |>
      dplyr::arrange(.data$name) |>
      dplyr::pull("name") |>
      paste(collapse = ", ")
  }

  return(formatted)
}
