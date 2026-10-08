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
  # apply rather than the process locale's: Turkish `i` becomes `İ` (U+0130), while base toupper()
  # follows the PROCESS locale and yields a plain `I` wherever that locale is not Turkish or the platform
  # lacks it, so its answer would depend on the machine the report renders on.
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

# The YAML handlers every string resource is read with. YAML 1.1 reads a bare
# yes, no, on, off, y or n as a logical, but in string resources such a word is
# a label (po4a writes a translated label like Yes unquoted), so it stays text;
# only true and false are logicals.
string_resource_handlers <- function() {
  keep_label <- function(x) if (tolower(x) %in% c("true", "false")) as.logical(tolower(x)) else x
  list('bool#no' = keep_label, 'bool#yes' = keep_label)
}

get_string_resources <- function(x) {
  handlers <- string_resource_handlers()

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
  # Force the supplied values HERE, in this frame, before glue sees them. glue
  # takes `...` as expressions and evaluates them in `.envir`, so passing them
  # through unforced means every argument is looked up in emptyenv() — where a
  # literal survives and a variable cannot. `threshold = sparse_threshold` then
  # fails with "object 'sparse_threshold' not found", naming a variable that is
  # perfectly in scope at the call site, which reads as a scoping bug in the
  # report rather than as an unresolvable argument here. The failure needs a
  # template that references the argument AND data that reaches that branch, so
  # it hides until a footnote finally has cause to fire.
  args <- list(...)
  # Two argument shapes glue accepts and this function must not, both silent.
  # An UNNAMED argument is not data at all — glue takes it as another piece of the
  # template, concatenated onto the end — and do.call splices the forced value into
  # the call it builds, so a value that is itself a symbol or a call is evaluated
  # here, reaching exactly the bindings emptyenv() exists to keep out of reach.
  # A value of length ZERO collapses the whole interpolation to character(0),
  # discarding the literal text with it, so a NULL argument deletes the sentence
  # rather than failing (measured on glue 1.8.1). Both are refused rather than
  # rendered, because either one loses text without saying so.
  if (length(args) > 0L) {
    names_given <- names(args)
    if (is.null(names_given) || any(!nzchar(names_given)))
      rlang::abort(paste0(
        "every value must be named — an unnamed argument is template text, ",
        "not data."))
    empty <- names_given[lengths(args) == 0L]
    if (length(empty) > 0L)
      rlang::abort(paste0(
        "zero-length value for ", paste(empty, collapse = ", "),
        " — glue would discard the whole string."))
  }
  # `quote = TRUE` is not an option on this do.call, and it is worth knowing why,
  # because it is the obvious-looking way to stop do.call re-evaluating anything.
  # It wraps each argument as `base::quote(<value>)` — an expression where a plain
  # value stood — and that expression is evaluated in `.envir`. emptyenv() has no
  # parent and no bindings, so it cannot resolve `::`, and EVERY call then fails
  # with "could not find function ::". The security property is what breaks it.
  do.call(glue::glue_safe, c(list(.template), args, list(.envir = emptyenv())))
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

# The World Bank income classes' codes, as neoipcr reads them, and the keys their
# labels carry in the string resources.
world_bank_class_keys <- c(
  H = "high_income",
  UM = "upper_middle_income",
  LM = "lower_middle_income",
  L = "low_income")

get_localised_world_bank_class_names <- function(x) {
  x |>
    purrr::map_chr(
      \(x) {
        if (is.na(x) || !nzchar(trimws(x))) return(sR$not_available)
        key <- world_bank_class_keys[as.character(x)]
        val <- if (is.na(key)) NULL else sR$worldBankClassNames[[key]]
        if(is.null(val)) x else val
      })
}

# The validation exception list a render applies, read by neoipcr's own reader
# so the file is checked once, the same way, wherever it is consumed. A path
# given explicitly must exist: neoipcr refuses a missing file like any other
# invalid list, so a mistyped path cannot silently drop every exception and
# remove the records it was meant to keep. With no path, the conventional
# file beside the report is read when present; otherwise the result is
# `FALSE` — no list, every flagged record removed — the value
# `dhis2_dataset_options(include_invalid_patients =)` takes without a list.
get_validation_exceptions <- function(x) {
  if (!is.null(x))
    return(neoipcr::read_validation_exceptions(x))
  default_file <- "validation-exceptions_ref.csv"
  if (file.exists(default_file))
    return(neoipcr::read_validation_exceptions(default_file))
  logWarn("Validation exception file not found: '{default_file}'",
          namespace = "report-common")
  FALSE
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

#' What keeps an address from serving as the base of the Tracker Capture
#' links, as `get_tracker_capture_base()` states it in a refusal.
#'
#' The address is accepted when its raw text matches, as a whole, the shape
#' `get_tracker_capture_base()` describes. Otherwise the defect is named by
#' category, never by quoting the address or any part of it.
#' @param x The address, as a caller handed it over
#' @return NULL when the address is accepted, otherwise a verb phrase naming
#'   the defect ("contains whitespace")
base_url_defect <- function(x) {
  if (!is.character(x) || length(x) != 1L || is.na(x))
    return("is not a single text value")
  # Matched as bytes, so a character outside ASCII matches none of the ranges
  # and an invalid encoding cannot raise an error that would bypass the
  # classed refusal.
  shape <- regmatches(x, regexec(paste0(
    "\\A(?i:https?)://",
    "[A-Za-z0-9_-]+(?:\\.[A-Za-z0-9_-]+)*\\.?",
    "(?::([0-9]{1,5}))?",
    "(?:/(?:[A-Za-z0-9._~-]|%[0-9A-Fa-f]{2})*)*\\z"),
    x, perl = TRUE, useBytes = TRUE))[[1]]
  valid_port <- function(port) {
    number <- as.integer(port)
    number >= 1L && number <= 65535L
  }
  if (length(shape) == 2L && (!nzchar(shape[2]) || valid_port(shape[2])))
    return(NULL)

  if (grepl("[[:space:]]", x, useBytes = TRUE))
    return("contains whitespace")
  if (!grepl("^[Hh][Tt][Tt][Pp][Ss]?://", x, useBytes = TRUE))
    return("does not begin with `http://` or `https://`")
  if (grepl("@", x, fixed = TRUE, useBytes = TRUE))
    return(paste("contains an `@`, which is refused wherever it stands, since",
                 "before the host it introduces a user name or password"))
  if (grepl("[?#]", x, useBytes = TRUE))
    return("carries a query or a fragment (a `?` or a `#`, even an empty one)")
  authority <- sub("/.*$", "", sub("^[^:]*://", "", x, useBytes = TRUE),
                   useBytes = TRUE)
  if (startsWith(authority, "["))
    return("names its host by a bracketed literal, such as an IPv6 address")
  host <- sub(":.*$", "", authority, useBytes = TRUE)
  if (!nzchar(host))
    return("names no host")
  if (!grepl("\\A[A-Za-z0-9_-]+(?:\\.[A-Za-z0-9_-]+)*\\.?\\z", host,
             perl = TRUE, useBytes = TRUE))
    return(paste("has a host that is not made of dot-separated labels of",
                 "ASCII letters, digits, hyphens, and underscores"))
  if (grepl(":", authority, fixed = TRUE, useBytes = TRUE)) {
    port <- sub("^[^:]*:", "", authority, useBytes = TRUE)
    if (!grepl("\\A[0-9]{1,5}\\z", port, perl = TRUE, useBytes = TRUE) ||
        !valid_port(port))
      return("has a port that is not a number from 1 to 65535")
  }
  paste("has a path with a character other than ASCII letters, digits, `-`,",
        "`.`, `_`, `~`, and a `%` followed by two hexadecimal digits")
}

#' The Tracker Capture address the Validation Report's patient links start
#' from.
#'
#' The links go where the report's readers reach DHIS2: `public_base_url`
#' when the caller gives it, as a render that reads the data over an address
#' inside its own network does, and otherwise the address the data is read
#' from, the API base URL of `connection_options` with its trailing slashes and
#' then a trailing `/api` removed from its path.
#'
#' Either address must match, on its raw text and as a whole, this shape, or
#' the render is refused with an error of class
#' `neoipc_invalid_dhis2_public_base_url`:
#'
#' - `http://` or `https://`, the scheme in any case;
#' - a host of dot-separated labels of ASCII letters, digits, hyphens, and
#'   underscores, optionally ending in a dot, which admits a host name or an
#'   IPv4 address;
#' - optionally `:` and a port from 1 to 65535;
#' - a path of `/`-separated segments of ASCII letters, digits, `-`, `.`, `_`,
#'   `~`, and `%` followed by two hexadecimal digits.
#'
#' So no whitespace, user name or password, query or fragment (an empty `?` or
#' `#` included), bracketed host such as an IPv6 literal, or any other
#' character. The address is written as it stands into a Markdown link
#' destination, which Pandoc's Markdown reader ends at an unbalanced `)`,
#' takes a space before a quote as the start of a link title, collapses other
#' whitespace, and percent-encodes whitespace, `<`, `>`, `|`, `"`, `{`, `}`,
#' `[`, `]`, `^`, and the backtick, so an address outside the shape could yield
#' a link that opens somewhere else; the shape is stricter than those
#' characters, deliberately. The raw text is checked rather than what a URL
#' parser makes of it, because the link carries the text, and a parser
#' normalizes: curl reports no query for an empty `?`.
#'
#' A refusal names the defect but never repeats the address or any part of
#' it, since a refused address can carry a password. The condition carries
#' the defect in its `defect` field as well, as `base_url_defect()` words it.
#' @param public_base_url The `dhis2PublicBaseUrl` parameter: `NULL` or `""`
#'   when it is not given, and otherwise expected to be a single string
#' @param connection_options The connection options the data is read with, as
#'   `get_connection_options()` returns them; only `base_url` is read
#' @return The address with any trailing slashes removed and
#'   `/dhis-web-tracker-capture/index.html` appended
get_tracker_capture_base <- function(public_base_url, connection_options) {
  expected_shape <- paste(
    "Give `http://` or `https://`, a host name or IPv4 address, an optional",
    "port, and any context path, with no user name, password, query, or",
    "fragment.")
  if (is.null(public_base_url) || identical(public_base_url, "")) {
    base <- connection_options$base_url
    # Split at the end of the authority so that only the path loses its
    # trailing `/api`, never a host of that name.
    parts <- if (is.character(base) && length(base) == 1L && !is.na(base))
      regmatches(base, regexec("^([^/]*//[^/]*)(.*)$", base, useBytes = TRUE))[[1]]
    if (length(parts) == 3L)
      base <- paste0(parts[2], sub("/api$", "", sub("/+$", "", parts[3])))
    defect <- base_url_defect(base)
    if (!is.null(defect))
      rlang::abort(
        c("The address the data is read from cannot serve as the base of the Tracker Capture links.",
          x = paste0("The connection address ", defect, "."),
          i = paste("Pass `dhis2PublicBaseUrl` (`-Dhis2PublicBaseUrl` with",
                    "`Build-ValidationReport.ps1`) with the address at which the",
                    "report's readers reach DHIS2."),
          i = expected_shape),
        class = "neoipc_invalid_dhis2_public_base_url",
        defect = defect)
  } else {
    base <- public_base_url
    defect <- base_url_defect(base)
    if (!is.null(defect))
      rlang::abort(
        c("`dhis2PublicBaseUrl` must be an http or https base URL.",
          x = paste0("The value given ", defect, "."),
          i = expected_shape),
        class = "neoipc_invalid_dhis2_public_base_url",
        defect = defect)
  }
  paste0(sub("/+$", "", base), "/dhis-web-tracker-capture/index.html")
}

#' The templates the Validation Report renders a validation rule's findings
#' with
#'
#' Every rule's findings render with its `description`. Rule 20 has a second
#' complete sentence for an infectious agent recorded as causing a secondary
#' sepsis, and rule 55 one for a secondary-BSI item that was never answered.
#' Rule 54 has two more, for a substance in two entries: of which an entry has
#' no days, or whose two entries have the same days; its `description` is the
#' case of different days, most likely one entry per treatment course.
#' `select_template()` in the report's `_problem_text.qmd` chooses among them.
#' @param rule_id A validation rule id
#' @return The keys of the rule's templates in its entry under `problems` in
#'   the Validation Report's string resources
validation_rule_template_keys <- function(rule_id)
  c("description",
    if (rule_id == 20L) "description_secondary_bsi",
    if (rule_id == 54L) c("description_days_missing", "description_same_days"),
    if (rule_id == 55L) "description_unanswered")

#' Check that the Validation Report's string resources carry sentences for
#' exactly the validation rules neoipcr defines
#'
#' The rules live in neoipcr; the sentences that render their findings live in
#' the report's string resources, under `problems`, keyed by rule id. Both
#' directions abort the render with an error that names the rules concerned:
#'
#' 1. A rule in `rule_ids` whose entry is not a mapping holding its templates,
#'    as [validation_rule_template_keys()] lists them, and its `summary`, each
#'    a single non-empty string, aborts with an error of class
#'    `neoipc_validation_rule_without_text`: its findings would render as a
#'    blank line, and the report's header, which names a rule it did not apply
#'    by its summary, would fail.
#' 2. A rule the string resources carry sentences for that is not in
#'    `rule_ids` aborts with an error of class
#'    `neoipc_validation_rule_text_without_rule`: the reporting service offers
#'    its callers the rules the string resources list, and
#'    `neoipcr::validate()` aborts on an id it does not know, so the mismatch
#'    fails every render rather than only one that selects the rule.
#'
#' The check reads nothing but its arguments, so the report runs it before it
#' reads any data.
#' @param sR String resources
#' @param rule_ids The validation rule ids, as `neoipcr::validation_rule_ids()`
#'   lists them
#' @return NULL, invisibly, when the string resources and the ids match
check_validation_rule_texts <- function(sR, rule_ids) {
  has_text <- function(rule_id) {
    entry <- sR$problems[[as.character(rule_id)]]
    is.list(entry) && all(vapply(
      c(validation_rule_template_keys(rule_id), "summary"),
      \(field) is.character(entry[[field]]) && length(entry[[field]]) == 1L &&
        nzchar(entry[[field]]),
      logical(1)))
  }
  unsentenced <- rule_ids[!vapply(rule_ids, has_text, logical(1))]
  if (length(unsentenced) > 0L)
    rlang::abort(
      sprintf(
        "The string resources carry no complete description and summary for validation rule(s) %s.",
        paste(unsentenced, collapse = ", ")),
      class = "neoipc_validation_rule_without_text")
  unruled <- setdiff(names(sR$problems), as.character(rule_ids))
  if (length(unruled) > 0L)
    rlang::abort(
      sprintf(
        "The string resources carry sentences for validation rule(s) %s, which neoipcr does not define.",
        paste(unruled, collapse = ", ")),
      class = "neoipc_validation_rule_text_without_rule")
  invisible(NULL)
}

#' The labels of the record kinds that neoipcr's validation and reconciliation
#' summaries count
#'
#' @param sR String resources
#' @return A named character vector: the labels of `patients`, `enrollments`,
#'   and `events`, the levels of a summary's `record_kind`
record_kind_labels <- function(sR) {
  strings <- sR$`tbl-validation-summary`
  c(patients = strings$patients, enrollments = strings$admissions, events = strings$forms)
}

#' The label of an entry in a report's header or overview list
#'
#' The entry's name in the translated `term_label` template, which carries
#' the punctuation the report's language puts after a label (a French
#' translation writes a no-break space before the colon), as the term of a
#' Markdown definition list. The name is a translated string and is escaped
#' as one.
#' @param term The entry's name, a translated string
#' @param sR String resources
#' @return The label as Markdown text
term_label <- function(term, sR)
  as.character(interpolate_translation(sR$term_label, term = escape_markdown_translation(term)))

#' Escapes a list marker at the start of a line of the report's Markdown
#'
#' A translated template is the report's Markdown and is not escaped, so a
#' translation that starts with a list marker would open a list where its line
#' starts a list item or a definition: an ordinal as many languages write it
#' ("54. kural", "54)"), a number in parentheses ("(54)"), which opens a list
#' at any number, Pandoc's `#` and `@` markers, or a bullet followed by a
#' space. The punctuation that makes the marker is escaped, as
#' [escape_markdown_translation()] escapes it in a translated value.
#' @param x character vector, one line each
#' @return the vector with each leading marker escaped
escape_leading_list_marker <- function(x) {
  token <- "(?:[[:alnum:]]+|#|@[[:alnum:]_-]*)"
  x <- sub(paste0("^(", token, ")([.)])"), "\\1\\\\\\2", x, perl = TRUE)
  x <- sub(paste0("^\\((?=", token, "\\))"), "\\\\(", x, perl = TRUE)
  sub("^([*+-])(?=\\s|$)", "\\\\\\1", x, perl = TRUE)
}

#' The state of the Validation Report's validation-exception list
#'
#' Switched off when the caller asked for the report without a list it holds
#' or gives, which an upload time alone shows as well, since the reporting
#' service passes no file then; none without a list; unusable when neoipcr
#' refuses the list given, reading it or resolving it onto the dataset; and
#' applied otherwise. Only neoipcr's refusal of the list
#' (`neoipcr_invalid_exception_list`) makes it unusable: any other error is a
#' defect of the render and propagates.
#' @param apply `applyValidationExceptions`
#' @param file `validationExceptionFile`, or NULL
#' @param uploaded_at `validationExceptionFileUploadedAt`, or NULL
#' @param read_and_resolve A function of the file's path returning the list
#'   read (`list`) and its records resolved onto the dataset (`keys`)
#' @return A list: `state`, one of `"applied"`, `"none"`, `"switched_off"`,
#'   and `"unusable"`; `list` and `keys` when the list was applied; and
#'   `refusal`, neoipcr's message, when it is unusable
validation_exception_state <- function(apply, file, uploaded_at, read_and_resolve) {
  if (isFALSE(apply) && (!is.null(file) || !is.null(uploaded_at)))
    return(list(state = "switched_off"))
  if (is.null(file))
    return(list(state = "none"))
  tryCatch(
    c(list(state = "applied"), read_and_resolve(file)),
    neoipcr_invalid_exception_list = function(cnd)
      list(state = "unusable", refusal = conditionMessage(cnd)))
}

#' The upload time of the Validation Report's validation-exception list
#'
#' Reads `validationExceptionFileUploadedAt`, which the reporting service
#' passes as `yyyy-mm-ddThh:mm:ssZ`. The same time with fractional seconds,
#' or with an offset from UTC in place of the `Z`, is read as well; any other
#' form is not, an ISO 8601 time without seconds or without a zone included.
#' @param x The parameter's value, or NULL
#' @return The time as a POSIXct in UTC, NA when `x` is in none of these
#'   forms, or NULL when `x` is NULL
validation_exception_upload_time <- function(x) {
  if (is.null(x))
    return(NULL)
  lubridate::fast_strptime(
    x, c("%Y-%m-%dT%H:%M:%OS%Ou", "%Y-%m-%dT%H:%M:%OS%OO", "%Y-%m-%dT%H:%M:%OS%Oz"),
    tz = "UTC", lt = FALSE)
}

#' Whether the validation-exception list exempted any record from a rule
#'
#' @param summary The validation summary of the render's findings, or NULL
#'   unless the list was applied
#' @return TRUE or FALSE
validation_exceptions_exempted <- function(summary)
  !is.null(summary) && any(summary$n_exempted[!is.na(summary$rule_id)] > 0L)

#' The Validation Report's header entry for the validation-exception list
#'
#' The definitions of the "Validation exceptions" entry, as Markdown text:
#' when the list was uploaded, where that is known and the report has a list
#' to speak of; the list's state; and, when the list was applied, one line per
#' rule naming the records it exempted, in rule order, counted at the rule's
#' level as neoipcr's `validation_summary()` counts them, which is how the
#' Partner and Reference Reports' table counts them. The templates are the
#' report's Markdown, as the rules' sentences are; the values put into them
#' are escaped, and so is a list marker a translation starts a line with.
#' @param state One of `"applied"`, `"none"`, `"switched_off"`, and
#'   `"unusable"`
#' @param uploaded_at The list's upload time, as
#'   [validation_exception_upload_time()] reads it, or NULL
#' @param summary The validation summary of the render's findings, or NULL
#'   unless the list was applied
#' @param sR String resources
#' @return A character vector, one element per definition
validation_exception_overview <- function(state, uploaded_at, summary, sR) {
  strings <- sR$validation_exceptions
  per_rule <- if (identical(state, "applied") && !is.null(summary)) {
    exempted <- summary[!is.na(summary$rule_id) & summary$n_exempted > 0L, ]
    exempted[order(exempted$rule_id), ]
  }
  state_line <- switch(state,
    applied      = if (NROW(per_rule) > 0L) strings$applied else strings$applied_none_exempted,
    none         = strings$none,
    switched_off = strings$switched_off,
    unusable     = strings$unusable,
    rlang::abort(sprintf("Unknown validation-exception state '%s'.", state), .internal = TRUE))
  kinds <- record_kind_labels(sR)
  escape_leading_list_marker(c(
    if (!identical(state, "none") && length(uploaded_at) == 1L && !is.na(uploaded_at))
      as.character(interpolate_translation(
        strings$uploaded,
        date = escape_markdown(format(uploaded_at, format = "%x")))),
    state_line,
    if (NROW(per_rule) > 0L)
      vapply(seq_len(nrow(per_rule)), \(i) as.character(interpolate_translation(
        strings$rule_records,
        rule  = per_rule$rule_id[i],
        kind  = escape_markdown_translation(kinds[[as.character(per_rule$record_kind[i])]]),
        count = escape_markdown(format_integer(
          per_rule$n_exempted[i], big_mark = sR$digit_group_separator)))),
        character(1))))
}

#' Percent-encodes a value for a mailto link's header fields
#'
#' Every reserved character is encoded, a `%` included that already reads as
#' an escape, and each line break as `%0D%0A`, which RFC 6068 requires in a
#' message body.
#' @param x A string
#' @return The encoded string
mailto_encode <- function(x)
  utils::URLencode(gsub("\r?\n", "\r\n", x), reserved = TRUE, repeated = TRUE)

#' The Validation Report's hint on requesting a validation exception
#'
#' The sentence, with its link to the NeoIPC support team, which opens an
#' e-mail asking for what the team needs to assess the request and to write
#' the exception record: the department, the patient, the enrolment, the
#' form, and the rule.
#' @param sR String resources
#' @param support_email_address The support team's address
#' @return The hint as Markdown text
exception_request_hint <- function(sR, support_email_address) {
  mailto <- paste0(
    support_email_address,
    "?subject=", mailto_encode(sR$exception_request_hint_email_subject),
    "&body=", mailto_encode(sR$exception_request_hint_email_body))
  # The link is markup built here and handed to the sentence as a value; its
  # label is a translated string set inside that markup.
  support_link <- paste0(
    "[", escape_markdown_translation(sR$support_email_address_link_text), "](mailto:", mailto, ")")
  as.character(interpolate_translation(sR$exception_request_hint, support_link = support_link))
}

#' The Validation Report's appendix of unused validation exceptions
#'
#' The appendix an administrator can add: the exception list's records for
#' the report's departments that match no record, or match one but exempt
#' nothing, as neoipcr's `validation_exception_usage()` reports them, in a
#' table; or a sentence saying why there is nothing to list. A matched record
#' whose rule the render did not run, which exempted nothing for want of a
#' run, is not listed. A list whose records do not name their department is
#' kept whole by neoipcr, so its records could be other departments', and
#' none is listed. The records name patients, so the appendix is meant for the
#' list's upkeep, not for partners.
#' @param state The list's state, as for [validation_exception_overview()]
#' @param usage The list's usage, or NULL unless the list was applied
#' @param sR String resources
#' @return Markdown lines
unused_validation_exceptions_markdown <- function(state, usage, sR) {
  strings <- sR$unused_validation_exceptions
  lines <- c(paste0("## ", strings$heading, " {.unnumbered}"), "")
  if (!identical(state, "applied"))
    return(c(lines, if (identical(state, "unusable")) strings$unusable else strings$not_applied))
  if (!"DEPARTMENT_CODE" %in% names(usage))
    return(c(lines, strings$no_department_codes))
  if (nrow(usage) == 0L)
    return(c(lines, strings$no_records))
  unused <- usage[!usage$matched | usage$n_exempted %in% 0L, ]
  if (nrow(unused) == 0L)
    return(c(lines, strings$none_unused))
  date_text <- function(d) ifelse(is.na(d), escape_markdown_translation(sR$missing_value),
                                  vapply(format(d, format = "%x"), escape_markdown, character(1)))
  text <- function(x) ifelse(is.na(x) | !nzchar(x), escape_markdown_translation(sR$missing_value),
                             vapply(as.character(x), escape_markdown, character(1)))
  rows <- paste(
    "|", vapply(unused$RULE_ID, \(id) as.character(id), character(1)),
    "|", text(unused$DEPARTMENT_CODE),
    "|", text(unused$NEOIPC_PATIENT_ID),
    "|", date_text(unused$ENROLMENT_DATE),
    "|", text(toupper(unused$EVENT_TYPE)),
    "|", date_text(unused$EVENT_DATE),
    "|", escape_markdown_translation(ifelse(unused$matched, strings$exempts_nothing, strings$matches_nothing)),
    "|")
  header <- paste(
    "|", paste(vapply(c(strings$rule, sR$header$department, strings$patient, strings$enrolment_date,
                        strings$form, strings$form_date, strings$outcome),
                      escape_markdown_translation, character(1)), collapse = " | "),
    "|")
  # A pipe table wider than Pandoc's line limit, as this one always is, takes
  # its column widths from the dashes of this line. The codes and ids cannot
  # break, so they get the width; a date gets enough for its locale's format.
  separator <- paste0("|", paste(strrep("-", c(3L, 8L, 7L, 6L, 3L, 6L, 5L)), collapse = "|"), "|")
  c(lines, strings$intro, "", header, separator, rows)
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

#' Escape a value for insertion into Pandoc Markdown as literal text.
#'
#' Outside code, Pandoc treats any punctuation or space character preceded by a
#' backslash as that character itself, so escaping every punctuation character
#' makes a value someone typed — a free-text infectious-agent name, a patient
#' id — render as typed whatever it contains, rather than as emphasis, a link,
#' or raw HTML.
#' A value is a phrase inside a sentence, a heading or a link, where a line
#' break would end the block it sits in, so runs of whitespace, line breaks
#' included, become one space first.
#' @param x character vector
#' @return the vector with its whitespace runs collapsed and every punctuation
#'   character backslash-escaped
escape_markdown <- function(x)
  gsub("([[:punct:]])", "\\\\\\1", gsub("[[:space:]]+", " ", x, perl = TRUE),
       perl = TRUE)

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
          (sR$worldBankClassNames |> unlist())[
            world_bank_class_keys[gsub("\\s+", "", .data$wb_class)]]
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

#' Whether a dataset's validation summary holds anything to show: absent on a
#' dataset written before neoipcr recorded one, and empty (0×0) on one built
#' with the validation pass switched off.
#' @param summary The `validationSummary` slot of a calculated dataset
#' @return TRUE when the slot is a table with columns
has_validation_summary <- function(summary) {
  !is.null(summary) && ncol(summary) > 0L
}

#' The summaries a Partner Report table shows, and a sentence for each dataset
#' without one
#'
#' The validation and the reconciliation summary tables compare the
#' department's data with the reference data where the report has them. A
#' dataset's summary slot is shown when it is a table with columns, which is
#' what [has_validation_summary()] and [has_reconciliation_summary()] both
#' test. A dataset without one is described by a sentence instead: `absent`
#' when the slot is missing (`NULL`), as on a dataset written before neoipcr
#' recorded the summary, and `empty` when it is 0×0, as on one built without
#' the step the summary counts. The reference data are shown whenever they
#' carry a summary, whether or not the department's data do. With reference
#' data, the summaries shown are named by the labels the report's other
#' tables give the two datasets, so each gets a column group that says whose
#' it is; without, the department's summary stays unnamed, as a single
#' dataset's is. When the summaries shown count nothing, the table gives way
#' to a sentence that names the datasets they belong to, since beside a
#' sentence about the other dataset an unnamed one would read as describing
#' the department's data.
#' @param own The summary slot of the department's data
#' @param ref The summary slot of the reference data; ignored without them
#' @param has_reference Whether the report has reference data
#' @param own_notes,reference_notes The sentences for the department's data
#'   and for the reference data, named `absent` and `empty`
#' @param zero_notes The sentences for summaries shown that count nothing,
#'   named `own`, `reference` and `both` for the datasets they belong to
#' @param sR String resources
#' @return A list of `summaries`, the summaries to show, `notes`, the
#'   sentences for the datasets without one, the department's first, and
#'   `zero_note`, the sentence for the summaries shown should they count
#'   nothing, NULL when none is shown
compared_summaries <- function(own, ref, has_reference, own_notes, reference_notes,
                               zero_notes, sR) {
  datasets <- list(
    list(key = "own", slot = own, notes = own_notes, label = sR$own_data_label))
  if (has_reference)
    datasets <- c(datasets, list(list(
      key = "reference", slot = ref, notes = reference_notes, label = sR$reference_data)))
  summaries <- list()
  labels <- character()
  shown <- character()
  notes <- character()
  for (dataset in datasets) {
    if (is.null(dataset$slot)) {
      notes <- c(notes, dataset$notes[["absent"]])
    } else if (ncol(dataset$slot) == 0L) {
      notes <- c(notes, dataset$notes[["empty"]])
    } else {
      summaries <- c(summaries, list(dataset$slot))
      labels <- c(labels, dataset$label)
      shown <- c(shown, dataset$key)
    }
  }
  if (has_reference)
    names(summaries) <- labels
  zero_note <- if (length(shown) == 2L) zero_notes[["both"]]
               else if (length(shown) == 1L) zero_notes[[shown]]
  list(summaries = summaries, notes = notes, zero_note = zero_note)
}

#' Format the validation summaries of one or more datasets as a table
#'
#' One row per rule that flagged a record, in rule order, with the kind of
#' record the rule concerns and its counts, then one row per record kind with
#' the totals across all rules. `summaries` is a list of `validationSummary`
#' tibbles as neoipcr's `import_dhis2()` documents them (`rule_id`,
#' `record_kind`, `n_removed`, `n_exempted`, `n_warned`, the totals rows
#' carrying `NA` for the rule); when the list is named, each name labels a
#' column group over its dataset's counts, and a rule one dataset never met
#' shows no count for it. A summary without `n_warned` gets no column of
#' warnings, and a footnote of its own on its removed records, which include
#' the warnings' records.
#' `NULL` when no summary removed, exempted, or warned of anything, so the
#' caller can say so instead of printing a table of zeros.
#' @param summaries List of validation-summary tibbles, named to label each
#'   dataset's column group
#' @param sR String resources
#' @param font_size The table's font size, as `compute_col_widths()` gives the
#'   report's other tables; NULL keeps gt's default
#' @return A gt table, or NULL
format_validation_summary_table <- function(summaries, sR, font_size = NULL) {
  strings <- sR$`tbl-validation-summary`
  kind_labels <- record_kind_labels(sR)

  # NEOIPC-PERMANENT(validation-summary-warnings): a stored reference dataset
  # or partner-data file written before neoipcr counted the records a warning
  # flagged apart from the removed ones carries no `n_warned`. Such a file
  # outlives every deployment, and the rules that are warnings now removed
  # their records then, so its removed records include them; without this the
  # table would refuse the file.
  has_warned <- vapply(summaries, \(summary) "n_warned" %in% names(summary), logical(1))
  counts <- purrr::map2(summaries, seq_along(summaries), function(summary, i) {
    counted <- summary |>
      dplyr::select("rule_id", "record_kind", "n_removed", "n_exempted",
                    tidyselect::any_of("n_warned")) |>
      dplyr::mutate(
        rule_id     = as.integer(.data$rule_id),
        record_kind = as.character(.data$record_kind)) |>
      dplyr::rename(
        !!paste0("removed_", i)  := "n_removed",
        !!paste0("exempted_", i) := "n_exempted")
    if (has_warned[[i]])
      counted <- dplyr::rename(counted, !!paste0("warned_", i) := "n_warned")
    counted
  })
  joined <- purrr::reduce(counts, dplyr::full_join, by = c("rule_id", "record_kind"))
  count_cols <- setdiff(names(joined), c("rule_id", "record_kind"))
  if (!any(unlist(joined[count_cols]) > 0, na.rm = TRUE))
    return(NULL)

  # interpolate_translation() refuses a zero-length value, so a row set that
  # is empty — a summary with totals but no rule rows cannot arise from
  # neoipcr, but the shape is allowed — gets its labels without it.
  labels_for <- function(template, ...) {
    values <- list(...)
    if (length(values[[1]]) == 0L) character() else
      as.character(interpolate_translation(template, ...))
  }
  rules <- joined |>
    dplyr::filter(!is.na(.data$rule_id)) |>
    dplyr::arrange(.data$rule_id) |>
    dplyr::mutate(
      label   = labels_for(strings$rule_label, rule = .data$rule_id),
      records = unname(kind_labels[.data$record_kind]),
      total   = FALSE)
  totals <- joined |>
    dplyr::filter(is.na(.data$rule_id)) |>
    dplyr::mutate(record_kind = factor(.data$record_kind, levels = names(kind_labels))) |>
    dplyr::arrange(.data$record_kind) |>
    dplyr::mutate(
      label   = labels_for(
        strings$total_label, records = unname(kind_labels[as.character(.data$record_kind)])),
      records = NA_character_,
      total   = TRUE)
  tbl_data <- dplyr::bind_rows(rules, totals) |>
    dplyr::select("label", "records", tidyselect::all_of(count_cols), "total")

  tbl <- tbl_data |>
    dplyr::select(!"total") |>
    gt::gt(rowname_col = "label") |>
    gt::sub_missing(missing_text = "") |>
    gt::tab_options(
      latex.use_longtable = TRUE,
      table.width = gt::pct(100),
      table.font.size = font_size,
      footnotes.marks = "extended") |>
    gt::fmt_integer(
      columns = tidyselect::all_of(count_cols),
      sep_mark = sR$digit_group_separator,
      min_sep_threshold = 2) |>
    gt::cols_label(records = strings$records) |>
    gt::tab_style(
      style = gt::cell_text(weight = "bold"),
      locations = list(
        gt::cells_column_spanners(),
        gt::cells_column_labels(),
        gt::cells_stub(rows = tbl_data$total))) |>
    gt::tab_style(
      style = gt::cell_borders(sides = "top", weight = gt::px(2)),
      locations = list(
        gt::cells_body(rows = which(tbl_data$total)[1]),
        gt::cells_stub(rows = which(tbl_data$total)[1]))) |>
    gt::tab_footnote(
      footnote = interpolate_translation(strings$exempted_footnote, column = strings$exempted),
      locations = gt::cells_column_labels(columns = "exempted_1"),
      placement = "right") |>
    gt::tab_source_note(strings$rule_footnote)
  # The removed records of a summary without `n_warned` include the warnings'
  # records, so the note that leaves them out goes on the first summary that
  # counts them apart, and each older summary gets its own note below.
  if (any(has_warned)) {
    first_warned <- which(has_warned)[1]
    tbl <- tbl |>
      gt::tab_footnote(
        footnote = interpolate_translation(strings$removed_footnote, column = strings$removed),
        locations = gt::cells_column_labels(columns = paste0("removed_", first_warned)),
        placement = "right") |>
      gt::tab_footnote(
        footnote = interpolate_translation(strings$warned_footnote, column = strings$warned),
        locations = gt::cells_column_labels(columns = paste0("warned_", first_warned)),
        placement = "right")
  }

  for (i in seq_along(summaries)) {
    cols <- c(paste0("removed_", i), paste0("exempted_", i),
              if (has_warned[[i]]) paste0("warned_", i))
    tbl <- tbl |>
      gt::cols_label(
        !!cols[1] := strings$removed,
        !!cols[2] := strings$exempted)
    if (has_warned[[i]])
      tbl <- tbl |>
        gt::cols_label(!!cols[3] := strings$warned)
    else
      tbl <- tbl |>
        gt::tab_footnote(
          footnote = interpolate_translation(strings$warned_absent_footnote, column = strings$removed),
          locations = gt::cells_column_labels(columns = tidyselect::all_of(cols[1])),
          placement = "right")
    if (!is.null(names(summaries)))
      tbl <- tbl |>
        gt::tab_spanner(label = names(summaries)[i], columns = tidyselect::all_of(cols),
                        id = paste0("dataset_", i))
  }
  tbl
}

#' Whether a dataset's reconciliation summary holds anything to show: absent
#' on a dataset written before neoipcr recorded one, or calculated from a raw
#' dataset written before then, and empty (0×0) on one imported with the
#' reconciliations switched off.
#' @param summary The `reconciliationSummary` slot of a calculated dataset
#' @return TRUE when the slot is a table with columns
has_reconciliation_summary <- function(summary) {
  !is.null(summary) && ncol(summary) > 0L
}

#' The label of each reconciliation, keyed by the id neoipcr gives it
#'
#' The string resources key a label by what the reconciliation repairs, not
#' by its id, so the ids `neoipcr::reconciliation_ids()` lists are mapped
#' here. The labels are listed one by one as literal `sR$` references: the
#' string-layer check reads those to tell a live key from a dead one.
#' @param sR String resources
#' @return A list of labels named by reconciliation id
reconciliation_labels <- function(sR) list(
  "1" = sR$`tbl-reconciliation-summary`$reconciliations$admission_day_of_life,
  "2" = sR$`tbl-reconciliation-summary`$reconciliations$form_day_of_life,
  "3" = sR$`tbl-reconciliation-summary`$reconciliations$gestation_days_from_text,
  "4" = sR$`tbl-reconciliation-summary`$reconciliations$implausible_gestation_days,
  "5" = sR$`tbl-reconciliation-summary`$reconciliations$ssi_secondary_bsi_agents,
  "6" = sR$`tbl-reconciliation-summary`$reconciliations$culture_negative_sepsis_agents)

#' How the reconciliation labels differ from the reconciliations neoipcr
#' applies
#'
#' A reconciliation without a label keeps its row in the reconciliation table,
#' labelled by its number, so a difference does not fail the render; it is
#' reported instead, naming each id neoipcr applies that has no label here and
#' each id labelled here that neoipcr does not apply. A label whose string
#' resource is missing counts as no label, since its row falls back the same
#' way.
#' @param sR String resources
#' @param ids The reconciliation ids, as `neoipcr::reconciliation_ids()` lists
#'   them
#' @return The warning to log, or NULL when every id has a label and every
#'   label an id
reconciliation_label_mismatch <- function(sR, ids) {
  labels <- reconciliation_labels(sR)
  labelled <- as.integer(names(labels)[!vapply(labels, is.null, logical(1))])
  ids <- as.integer(ids)
  missing <- setdiff(ids, labelled)
  surplus <- setdiff(labelled, ids)
  if (length(missing) == 0L && length(surplus) == 0L)
    return(NULL)
  paste0(
    "The reconciliation labels do not match neoipcr::reconciliation_ids()",
    if (length(missing) > 0L)
      paste0("; no label for ", paste(missing, collapse = ", ")),
    if (length(surplus) == 1L)
      paste0("; a label for ", surplus, ", which neoipcr does not apply"),
    if (length(surplus) > 1L)
      paste0("; labels for ", paste(surplus, collapse = ", "),
             ", which neoipcr does not apply"),
    ".",
    if (length(missing) > 0L)
      " The table labels a reconciliation without a label by its number.")
}

#' Log a warning when the reconciliation labels differ from the
#' reconciliations the loaded neoipcr applies, as
#' [reconciliation_label_mismatch()] describes it.
#' @param sR String resources
#' @return The warning, invisibly, or NULL when the labels match
check_reconciliation_labels <- function(sR) {
  mismatch <- reconciliation_label_mismatch(sR, neoipcr::reconciliation_ids())
  if (!is.null(mismatch))
    logWarn(logger::skip_formatter(mismatch), namespace = "report-common")
  invisible(mismatch)
}

#' The rows of the reconciliation summary table
#'
#' One row per reconciliation, in id order, with its label, the kind of record
#' it acts on and, per dataset, the records it repaired and the ones it
#' reported and kept as stored. `summaries` is a list of
#' `reconciliationSummary` tibbles as neoipcr's `import_dhis2()` documents
#' them (`reconciliation_id`, `record_kind`, `n_repaired`, `n_reported`), in
#' the order their columns are shown. A count is `NA` where the import could
#' not read the records the reconciliation acts on, and where a dataset does
#' not carry the reconciliation at all. The reported columns are left out
#' unless some dataset reported a record, since a column of zeros tells the
#' reader nothing. An id without a label, as a dataset written by a newer
#' neoipcr can carry, is labelled by its number, and a record kind without one
#' by its name. Kept free of gt so that a test can run it where gt is not
#' installed.
#' @param summaries List of reconciliation-summary tibbles
#' @param sR String resources
#' @return A tibble with `label`, `records` and, for the i-th summary,
#'   `repaired_<i>` and, where shown, `reported_<i>`; NULL when every count is
#'   zero, so the caller can say so instead of printing a table of zeros
reconciliation_summary_rows <- function(summaries, sR) {
  strings <- sR$`tbl-reconciliation-summary`
  kind_labels <- record_kind_labels(sR)
  labels <- reconciliation_labels(sR)

  counts <- purrr::map2(summaries, seq_along(summaries), function(summary, i) {
    summary |>
      dplyr::select("reconciliation_id", "record_kind", "n_repaired", "n_reported") |>
      dplyr::mutate(
        reconciliation_id = as.integer(.data$reconciliation_id),
        record_kind       = as.character(.data$record_kind)) |>
      dplyr::rename(
        !!paste0("repaired_", i) := "n_repaired",
        !!paste0("reported_", i) := "n_reported")
  })
  joined <- purrr::reduce(counts, dplyr::full_join, by = c("reconciliation_id", "record_kind")) |>
    dplyr::arrange(.data$reconciliation_id)
  count_cols <- setdiff(names(joined), c("reconciliation_id", "record_kind"))
  # A missing count is not a zero: the import could not read the records that
  # reconciliation acts on, so it cannot say that none needed reconciling, and
  # the table shows the gap rather than a sentence that would hide it.
  values <- unlist(joined[count_cols])
  if (all(!is.na(values) & values == 0L))
    return(NULL)
  reported_cols <- count_cols[startsWith(count_cols, "reported_")]
  if (!any(unlist(joined[reported_cols]) > 0L, na.rm = TRUE))
    count_cols <- setdiff(count_cols, reported_cols)

  label_of <- function(id) {
    label <- labels[[as.character(id)]]
    if (is.null(label))
      as.character(interpolate_translation(strings$unknown_label, reconciliation = id))
    else
      label
  }
  joined |>
    dplyr::mutate(
      label   = purrr::map_chr(.data$reconciliation_id, label_of),
      records = dplyr::coalesce(unname(kind_labels[.data$record_kind]), .data$record_kind)) |>
    dplyr::select("label", "records", tidyselect::all_of(count_cols))
}

#' Format the reconciliation summaries of one or more datasets as a table
#'
#' The rows [reconciliation_summary_rows()] builds, as a gt table; when
#' `summaries` is named, each name labels a column group over its dataset's
#' counts. A missing count shows as the dash the report's other tables show
#' for a missing value, and a note under the table says what it means.
#' @param summaries List of reconciliation-summary tibbles, named to label
#'   each dataset's column group
#' @param sR String resources
#' @param font_size The table's font size, as `compute_col_widths()` gives the
#'   report's other tables; NULL keeps gt's default
#' @return A gt table, or NULL when every count is zero
format_reconciliation_summary_table <- function(summaries, sR, font_size = NULL) {
  rows <- reconciliation_summary_rows(summaries, sR)
  if (is.null(rows))
    return(NULL)
  strings <- sR$`tbl-reconciliation-summary`
  count_cols <- setdiff(names(rows), c("label", "records"))

  tbl <- rows |>
    gt::gt(rowname_col = "label") |>
    gt::sub_missing() |>
    gt::tab_options(
      latex.use_longtable = TRUE,
      table.width = gt::pct(100),
      table.font.size = font_size,
      footnotes.marks = "extended") |>
    gt::fmt_integer(
      columns = tidyselect::all_of(count_cols),
      sep_mark = sR$digit_group_separator,
      min_sep_threshold = 2) |>
    gt::cols_label(records = sR$`tbl-validation-summary`$records) |>
    gt::tab_style(
      style = gt::cell_text(weight = "bold"),
      locations = list(gt::cells_column_spanners(), gt::cells_column_labels()))
  # The labels are phrases, so the stub is the one column given a width,
  # which wraps them; without one the PDF sets each label on one line past
  # the margin. The record kinds and the counts take their natural width, as
  # in the validation summary table, so no header and no column group's label
  # is set narrower than its text. The stub leaves 20 % of the line to the
  # record kinds and 13 % to each count, room for headers and column group
  # labels well beyond the English ones. cols_width() evaluates its formula
  # without its environment, so the width is injected into it.
  stub_width <- gt::pct(80 - 13 * length(count_cols))
  tbl <- rlang::inject(gt::cols_width(tbl, gt::stub() ~ !!stub_width))
  if (anyNA(rows[count_cols]))
    tbl <- tbl |>
      gt::tab_source_note(strings$missing_count_footnote)
  if ("reported_1" %in% count_cols)
    tbl <- tbl |>
      gt::tab_footnote(
        footnote = interpolate_translation(strings$reported_footnote, column = strings$reported),
        locations = gt::cells_column_labels(columns = "reported_1"),
        placement = "right")

  for (i in seq_along(summaries)) {
    repaired <- paste0("repaired_", i)
    reported <- paste0("reported_", i)
    tbl <- tbl |>
      gt::cols_label(!!repaired := strings$repaired)
    if (reported %in% count_cols)
      tbl <- tbl |>
        gt::cols_label(!!reported := strings$reported)
    if (!is.null(names(summaries)))
      tbl <- tbl |>
        gt::tab_spanner(label = names(summaries)[i],
                        columns = tidyselect::all_of(intersect(c(repaired, reported), count_cols)),
                        id = paste0("dataset_", i))
  }
  tbl
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

#' Escape text for insertion into LaTeX as literal text
#'
#' Each of the ten characters LaTeX reserves becomes what typesets it, so a
#' translated sentence placed in raw LaTeX renders as written whatever it
#' contains, where an `&` would end the table cell it sits in and a `%` drop
#' the rest of the line. Every other character, non-ASCII included, is left
#' alone: LuaLaTeX reads it as itself.
#' @param x character vector
#' @return the vector with every reserved character escaped
escape_latex <- function(x) {
  reserved <- c(
    "\\" = "\\textbackslash{}", "{" = "\\{", "}" = "\\}", "#" = "\\#",
    "$" = "\\$", "%" = "\\%", "&" = "\\&", "_" = "\\_",
    "~" = "\\textasciitilde{}", "^" = "\\textasciicircum{}")
  vapply(strsplit(x, "", fixed = TRUE), function(chars) {
    hit <- chars %in% names(reserved)
    chars[hit] <- reserved[chars[hit]]
    paste(chars, collapse = "")
  }, character(1), USE.NAMES = FALSE)
}

#' Escape a translated string for insertion into Pandoc Markdown
#'
#' For a string from the string resources that the code places into Markdown
#' it builds: a sentence standing as a paragraph of its own, or a label inside
#' a sentence, a heading or the text of a link. Unlike [escape_markdown()],
#' which keeps a value exactly as typed, this leaves the four characters
#' Pandoc's smart typography reads unescaped — `'`, `"`, `-`, and `.` — so a
#' translation's apostrophes, quotation marks, dashes, and ellipses are set as
#' in the rest of the report. Every other ASCII punctuation character is
#' backslash-escaped, so none can open emphasis, a link, math, raw TeX or
#' HTML, or a citation. The first characters of a paragraph, or of a list item
#' a translated sentence begins with the string, can open a list as well, so a
#' leading `-`, and the full stop after a leading number or word, as in "1."
#' or "z. B.", are escaped too. Runs of whitespace, line breaks included,
#' become one space first, and the ends are trimmed, since a line break or an
#' indent could end the block or make it a code block. Not for a link's
#' title: Pandoc never sets a title's quotation marks, and a `"` left
#' unescaped can end it.
#' @param x character vector
#' @return the vector escaped as described
escape_markdown_translation <- function(x) {
  x <- gsub("[[:space:]]+", " ", trimws(x), perl = TRUE)
  x <- gsub("([!#$%&()*+,/:;<=>?@\\[\\\\\\]^_`{|}~])", "\\\\\\1", x, perl = TRUE)
  x <- sub("^-", "\\\\-", x, perl = TRUE)
  sub("^([[:alnum:]]+)\\.", "\\1\\\\.", x, perl = TRUE)
}

# A sentence in a table's place, shaped as a one-cell longtable in the PDF so
# the chunk's caption still has a table to sit on. The cell is a paragraph
# column as wide as the text block less the column padding, so a sentence
# longer than a line, as a translation often is, wraps instead of running into
# the margin the way an `l` column sets it; centring it keeps a short sentence
# where the natural-width column put it. The longtable is raw LaTeX, so the
# sentence is escaped for it. Every other format gets the sentence as a plain
# paragraph, Word included, escaped for Markdown: Pandoc's docx writer drops a
# raw LaTeX block, and the sentence with it.
no_data_table <- function(message = sR$no_data) {
  cat(
    '::: {.content-visible unless-format="pdf"}',
    escape_markdown_translation(message),
    ":::",
    "",
    '::: {.content-visible when-format="pdf"}',
    "\\begin{longtable}{p{\\dimexpr\\linewidth-2\\tabcolsep\\relax}}",
    paste0("\\centering ", escape_latex(message)),
    "\\end{longtable}",
    ":::",
    sep = "\n"
  )
}
