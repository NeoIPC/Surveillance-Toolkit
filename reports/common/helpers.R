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

  # Layer 0: glossary (lowest priority — controlled vocabulary)
  glossary_path <- "../../glossary.yaml"
  if (file.exists(glossary_path)) {
    sR <- yaml::read_yaml(glossary_path, handlers = handlers)
  } else {
    sR <- list()
  }

  # Layer 1: common (overrides glossary)
  sR <- modifyList(sR, yaml::read_yaml("../common.yaml", handlers = handlers))

  # Layer 2: report-specific (overrides common)
  sR <- modifyList(sR, yaml::read_yaml("content/_sR.yaml", handlers = handlers))

  # Language/territory overrides (glossary, then common, then report-specific)
  yaml_path <- paste0("../../glossary.", localeObj$language, ".yaml")
  if(file.exists(yaml_path)) sR <- modifyList(
    sR,
    yaml::read_yaml(file = yaml_path, handlers = handlers))

  if (!is.null(localeObj$territory)) {
    yaml_path <- paste0("../../glossary.", localeObj$language, "_", localeObj$territory, ".yaml")
    if(file.exists(yaml_path)) sR <- modifyList(
      sR,
      yaml::read_yaml(file = yaml_path, handlers = handlers))
  }

  yaml_path <- paste0("../common.", localeObj$language, ".yaml")
  if(file.exists(yaml_path)) sR <- modifyList(
    sR,
    yaml::read_yaml(file = yaml_path, handlers = handlers))

  if (!is.null(localeObj$territory)) {
    yaml_path <- paste0("../common.", localeObj$language, "_", localeObj$territory, ".yaml")
    if(file.exists(yaml_path)) sR <- modifyList(
      sR,
      yaml::read_yaml(file = yaml_path, handlers = handlers))
  }

  yaml_path <- paste0("content.", localeObj$language, "/_sR.yaml")
  if(file.exists(yaml_path)) sR <- modifyList(
    sR,
    yaml::read_yaml(file = yaml_path, handlers = handlers))

  if (!is.null(localeObj$territory)) {
    yaml_path <- paste0("content.", localeObj$language, "_", localeObj$territory, "/_sR.yaml")
    if(file.exists(yaml_path)) sR <- modifyList(
      sR,
      yaml::read_yaml(file = yaml_path, handlers = handlers))
  }

  return(sR)
}

get_localised_path <- function(file_name, language, territory) {
  if (!is.null(territory)) {
    yaml_path <- paste0("content.", language, "_", territory, "/", file_name)
    if(file.exists(yaml_path)) {
      return(yaml_path)
    }
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

get_localised_world_bank_class_names <- function(x) {
  x |>
    purrr::map_chr(
      \(x) {
        if (is.na(x) || !nzchar(trimws(x))) return(sR$not_available)
        val <- sR$worldBankClassNames[[as.character(x)]]
        if(is.null(val)) x else val
      })
}

get_validation_exceptions <- function(x) {
  validationExceptionFile = dplyr::coalesce(x, "validation-exceptions_ref.csv")
  if (file.exists(validationExceptionFile)) {
    return(read_csv(validationExceptionFile, show_col_types = FALSE))
  } else {
    logWarn("Validation exception file not found: '{validationExceptionFile}'",
            namespace = "report-common")
    return(FALSE)
  }
}

get_connection_options <- function(scheme = NULL, hostname = NULL,
                                    port = NULL, path = NULL) {
  args <- list()
  if (!is.null(scheme)) args$scheme <- scheme
  if (!is.null(hostname)) args$hostname <- hostname
  if (!is.null(port)) args$port <- port
  if (!is.null(path)) args$path <- path
  do.call(neoipcr::dhis2_connection_options, args)
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
      include_world_bank_class = "full",
      include_country = "full",
      include_department = "pseudo",
      include_patient = "full",
      patient_columns = c("id", "sex", "birth_weight", "gestational_age",
                           "delivery_mode", "siblings"),
      include_enrollment = "full",
      include_event = "full",
      surveillance_end_from = lubridate::as_date(
        dplyr::coalesce(reportingPeriodFrom, "2024-01-01")),
      surveillance_end_to = lubridate::as_date(
        dplyr::coalesce(reportingPeriodTo, as.character(Sys.Date()))),
      birth_weight_from = birthWeightFrom,
      birth_weight_to = birthWeightTo,
      gestational_age_from = gestationWeeksFrom,
      gestational_age_to = gestationWeeksTo,
      country_filter = if (!is.null(reportingCountries))
        unlist(strsplit(reportingCountries, ",")),
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
#' @param include_wb_class Whether to include WB class ("no", "pseudo", "full")
#' @return Formatted string with countries grouped by WB class, or simple list if not showing WB class
format_countries <- function(countries) {
  if (is.null(countries) || nrow(countries) == 0) {
    return(sR$not_available)
  }

  # Group by WB class and format
  if("wb_class" %in% rlang::names2(countries)) {
    formatted <- countries |>
      dplyr::arrange(.data$wb_class, .data$name) |>
      dplyr::mutate(
        wb_class_label = dplyr::if_else(
          is.na(.data$wb_class) | !nzchar(trimws(.data$wb_class)),
          sR$not_available,
          (sR$worldBankClassNames |> unlist())[gsub("\\s+", "", .data$wb_class)]
        )
      ) |>
      dplyr::mutate(
        wb_class_label = dplyr::coalesce(.data$wb_class_label, sR$not_available)
      ) |>
      dplyr::group_by(.data$wb_class_label) |>
      dplyr::summarise(
        country_list = paste((sR$countryNames |> unlist())[gsub("\\s+", "", .data$name)], collapse = "*, *"),
        .groups = "drop")|>
      dplyr::mutate(
        formatted = paste0(.data$wb_class_label, ": *", .data$country_list, "*")
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

#' Format a range filter (birthweight or gestational age) for display
#' @param from Lower bound (NULL if no lower bound)
#' @param to Upper bound (NULL if no upper bound)
#' @param unit Unit string (e.g. "g" or "w")
#' @param all_label Label when both bounds are NULL (e.g. sR$headerList$allBirthweights)
#' @return Formatted filter string
format_range_filter <- function(from, to, unit, all_label) {
  if (is.null(from) && is.null(to)) {
    all_label
  } else if (is.null(from)) {
    paste0("\u2264 ", format_integer(to), " ", unit)
  } else if (is.null(to)) {
    paste0("\u2265 ", format_integer(from), " ", unit)
  } else {
    paste0(format_integer(from), " ", unit, " - ", format_integer(to), " ", unit)
  }
}

#' Format dataset metadata and counts into display-ready values (dR fields)
#' @param metadata List with data_up_to, effective_analysis_period, countries, dataset_options
#' @param counts Named list of raw numeric values (n_departments, n_patients, etc.)
#' @param sR String resources
#' @return Named list of formatted display values
format_dataset_resources <- function(metadata, counts, sR) {
  fmt_decimal <- function(x) {
    format(x, digits = 2, nsmall = 1, scientific = FALSE)
  }

  result <- list(
    dataUpToTimestamp = if (!is.null(metadata$data_up_to)) {
      format(metadata$data_up_to, format = "%x %X", tz = "UTC", usetz = TRUE)
    } else {
      format(lubridate::now("UTC"), format = "%x %X", tz = "UTC", usetz = TRUE)
    },
    effectiveAnalysisPeriod = if (!is.null(metadata$effective_analysis_period)) {
      paste(
        format(metadata$effective_analysis_period$from, format = "%x"),
        format(metadata$effective_analysis_period$to, format = "%x"),
        sep = " - "
      )
    } else {
      sR$not_available
    },
    countriesList = {
      countries_data <- metadata$countries
      if (!is.data.frame(countries_data)) {
        countries_data <- tibble::tibble(name = countries_data)
      }
      # format_countries expects `name` (the raw, locale-independent
      # DHIS2 org unit name) as the lookup key into sR$countryNames.
      format_countries(countries_data)
    },
    birthweightFilter = format_range_filter(
      metadata$dataset_options$birth_weight_from,
      metadata$dataset_options$birth_weight_to,
      "g", sR$headerList$allBirthweights
    ),
    gestationalAgeFilter = format_range_filter(
      metadata$dataset_options$gestational_age_from,
      metadata$dataset_options$gestational_age_to,
      "w", sR$headerList$allGestationalAges
    ),
    numberOfDepartments = format_integer(counts$n_departments),
    numberOfPatients = format_integer(counts$n_patients),
    numberOfAdmissions = format_integer(counts$n_enrollments),
    sumOfPatientDays = format_integer(counts$n_patient_days),
    averageSurveillancePeriod = fmt_decimal(
      counts$n_patient_days / counts$n_patients
    ),
    numberOfSevereInfections = format_integer(counts$n_severe_infections),
    averageSevereInfectionsPerPatient = fmt_decimal(
      counts$n_severe_infections / counts$n_patients
    )
  )

  # Infectious agent fields (optional — present in Reference-Report and Partner-Report)
  if (!is.null(counts$n_infectious_agents)) {
    result$numberOfInfectiousAgents <- format_integer(counts$n_infectious_agents)
  }
  if (!is.null(counts$n_infections_with_agent)) {
    result$numberOfInfectionsWithAgent <- format_integer(counts$n_infections_with_agent)
  }
  if (!is.null(counts$n_infections_overall)) {
    result$overallNumberOfInfections <- format_integer(counts$n_infections_overall)
  }
  if (!is.null(counts$n_infections_with_agent) && !is.null(counts$n_infections_overall)) {
    result$infectiousAgentDetectionRate <- fmt_decimal(
      counts$n_infections_with_agent / counts$n_infections_overall * 100
    )
  }

  # Surgery fields (optional — present in Reference-Report)
  if (!is.null(counts$n_surgical_departments)) {
    result$numberOfSurgicalDepartments <- format_integer(counts$n_surgical_departments)
    result$proportionOfSurgicalDepartments <- paste0(
      fmt_decimal(counts$n_surgical_departments / counts$n_departments * 100),
      sR$unit_separator, sR$percent_symbol
    )
  }
  if (!is.null(counts$n_surgical_procedures)) {
    result$numberOfSurgicalProcedures <- format_integer(counts$n_surgical_procedures)
  }
  if (!is.null(counts$n_surgical_patients)) {
    result$numberOfSurgicalPatients <- format_integer(counts$n_surgical_patients)
  }
  if (!is.null(counts$n_surgical_procedures) && !is.null(counts$n_surgical_patients)) {
    result$numberOfSurgicalProceduresPerPatient <- fmt_decimal(
      counts$n_surgical_procedures / counts$n_surgical_patients
    )
  }
  if (!is.null(counts$n_surgical_site_infections)) {
    result$numberOfSurgicalSiteInfections <- format_integer(
      counts$n_surgical_site_infections
    )
  }

  result
}

no_data_table <- function() {
  cat(
    '::: {.content-visible when-format="html"}',
    sR$no_data,
    ":::",
    "",
    '::: {.content-visible unless-format="html"}',
    "\\begin{longtable}{l}",
    sR$no_data,
    "\\end{longtable}",
    ":::",
    sep = "\n"
  )
}
