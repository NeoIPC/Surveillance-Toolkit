# Common helper functions for NeoIPC Surveillance reports
# This file is sourced by all report types

# Write text to a file as UTF-8 with LF line endings, on every platform.
#
# `writeLines(x, "path")` opens the path with file(path, "w") — that is "wt", a TEXT-mode
# connection — and R translates LF to CRLF in text mode on Windows. R's own writeLines
# documentation is explicit: "the default separator is converted to the normal separator for
# that platform (LF on Unix/Linux, CRLF on Windows). For more control, open a binary
# connection and specify the precise value you want written to the file in sep."
#
# `useBytes = TRUE` does NOT prevent this. It only suppresses re-encoding of strings with a
# marked encoding; it has no line-ending semantics at all. Every one of these report writers
# passed useBytes = TRUE and still emitted CRLF on Windows.
#
# It matters because each artifact written here is read by something else — the
# NeoIPC.Reporting .NET service, Quarto, git — so the bytes must not depend on which machine
# produced them. Binary mode writes `sep` literally, which makes sep the single thing deciding
# the line endings; hence stating it rather than leaning on the default.
write_lines_lf <- function(x, path) {
  con <- file(path, open = "wb")
  on.exit(close(con), add = TRUE)
  writeLines(x, con, sep = "\n", useBytes = TRUE)
  invisible(path)
}

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

# Sentence-case one glossary term for a language.
#
# Casing is a rendering concern, so it is applied here rather than stored as a second translated key
# beside every term.
#
# Wrapping str_to_sentence() and putting the abbreviations back afterwards was measured against the
# eleven values the retired `_sc` keys held: it reproduces all eleven, and so does this — the same
# answer, reached through a heuristic about which words are "protected" rather than by not damaging
# them in the first place. Title case is where that difference stops being cosmetic: str_to_title()
# cannot be rescued the same way, because "sepsis/BSI" is one whitespace token needing title case on
# one side of the slash and none on the other, and restoring the token undoes both.
sentence_case <- function(text, language) {
  if (!nzchar(text)) return(text)
  # Uppercase the FIRST CHARACTER ONLY, through a locale-aware call so the language's own casing rules
  # apply rather than the build machine's: Turkish `i` becomes `İ` (U+0130) where base toupper() yields
  # a plain `I` unless the PROCESS locale is Turkish, which a container rendering nine languages is not.
  # Delegating to ICU also covers locales nobody here has enumerated — Azerbaijani shares the Turkish
  # rule, Lithuanian has its own — and returns a caseless script unchanged with no special case.
  #
  # NEVER str_to_sentence() or str_to_title(), despite the names. Both normalise the WHOLE string, and
  # these terms are largely abbreviations: measured against the values the retired `_sc` keys held,
  # uppercasing the first character alone reproduces 11 of 11, while str_to_sentence() reproduces 10 — it
  # renders "primary sepsis/BSI" as "Primary sepsis/bsi", and str_to_title() renders "AWaRe" as "Aware".
  paste0(stringr::str_to_upper(substr(text, 1, 1), locale = language),
         substr(text, 2, nchar(text)))
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
  # Which keys the glossary contributes, captured before anything overrides it: these are the terms whose
  # sentence-case form is derived below rather than translated separately.
  glossary_terms <- names(sR)

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

  # Derive the sentence-case variant of every glossary term, after the whole cascade so it is built from
  # the translation that actually won. Storing these as separate keys meant translating each term twice
  # and duplicating it in every other component's glossary sidebar; worse, the casing axis multiplied
  # against plural forms, so a six-form language would have needed eighteen keys for one term.
  #
  # A term that already carries an explicit `_sc` is left alone — the escape hatch for a rendering the
  # rule cannot produce, and why this runs last rather than first.
  for (term in glossary_terms) {
    if (grepl("_(sc|tc)$", term)) next
    variant <- paste0(term, "_sc")
    if (!is.null(sR[[variant]])) next
    value <- sR[[term]]
    if (is.character(value) && length(value) == 1) {
      sR[[variant]] <- sentence_case(value, localeObj$language)
    }
  }

  return(sR)
}

# Interpolate {name} placeholders into a TRANSLATED string.
#
# Use this for every string that came out of a catalogue; never glue::glue().
#
# glue() resolves each brace as an R EXPRESSION in the environment given by .envir, which defaults to the
# caller's frame. Report templates come from gettext catalogues that any account signed in to Weblate may
# write, so glue() on one is arbitrary R evaluated at render time with every local binding in scope, inside
# the container that renders clinical reports. Measured, not inferred: a template of "{nchar(secret)}"
# returns 23.
#
# Two mechanisms, because they close different holes and only the pair closes both:
#   glue_safe()        looks each brace up as a NAME and never evaluates, so no expression can run;
#   .envir = emptyenv() leaves nothing to look up but the values supplied here, so no binding can leak.
# glue_safe() alone still reads the caller's frame; emptyenv() alone still evaluates whatever it finds.
#
# The safety lives in this function rather than in an argument repeated at each call site, which is the
# point: the source-string migration adds many more interpolations, and a rule that must be remembered
# every time is a rule that will be missed once. Here, forgetting it is not possible.
#
# Returns a glue object, exactly as glue() did — several call sites rely on that class, and forcing
# character would be an unrelated behaviour change.
interpolate_translation <- function(.template, ...) {
  glue::glue_safe(.template, ..., .envir = emptyenv())
}

# Interpolate into ALREADY-COMPOSED translated text, against an explicit allow-list.
#
# Needed where a string is assembled from several translated fragments and only then scanned for
# placeholders, so the values cannot be passed as named arguments to the call that produced each fragment.
# `allowed` is the complete set of names that text may reference.
#
# Note glue_data_safe() is NOT an allow-list on its own: its data argument is a first lookup that falls
# back to .envir, so without emptyenv() a name absent from the list still resolves against the caller.
# Verified — dropping .envir here lets a template read a caller variable again.
interpolate_composed_translation <- function(.template, allowed) {
  glue::glue_data_safe(allowed, .template, .envir = emptyenv())
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

# The production NeoIPC DHIS2 host. neoipcr (the library) no longer defaults to
# any deployment's host — it is a public library for any NeoIPC instance — so
# the deployment default lives here in the report tooling. Host precedence is
# explicit `hostname` argument > `NEOIPC_DHIS2_HOST` env var > this production
# default, so a plain render still targets production while a dev/staging render
# can redirect via the env var without passing `--host`.
NEOIPC_PRODUCTION_DHIS2_HOST <- "neoipc.charite.de"

get_connection_options <- function(scheme = NULL, hostname = NULL,
                                    port = NULL, path = NULL) {
  args <- list()
  if (!is.null(scheme)) args$scheme <- scheme
  # Apply the production default only when NEITHER an explicit host NOR the env var
  # is set — otherwise the middle (env) tier is unreachable and an env-redirected
  # render without --host would silently hit production.
  env_host <- Sys.getenv("NEOIPC_DHIS2_HOST", unset = "")
  args$hostname <- if (!is.null(hostname)) hostname
                   else if (nzchar(env_host)) env_host
                   else NEOIPC_PRODUCTION_DHIS2_HOST
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
    departmentFilter,
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
      department_filter = if (!is.null(departmentFilter))
        unlist(strsplit(departmentFilter, ",")),
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
        # Fall back to the raw org-unit name when a country has no
        # `countryNames` entry, so an unlisted country shows its own name
        # rather than "NA". Curated/localised names can still be added to
        # `common.yaml` `countryNames`; this only guards the gaps.
        country_list = paste(
          dplyr::coalesce(
            unname((sR$countryNames |> unlist())[gsub("\\s+", "", .data$name)]),
            .data$name),
          collapse = "*, *"),
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
