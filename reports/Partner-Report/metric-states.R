# The Partner Report's metric-state framework: every benchmarked table is
# classified into a state relative to the reference quartiles, and the outlier
# texts name those states back to the reader. The report's `_setup.qmd`
# sources this file; the tests in `reports/tests/` exercise the same code.
#
# A row's key in the state map is the caller's `identifiers` when it gives
# them — for the infectious-agent tables that is the row identity of
# `infectious-agent-rows.R`, not the printed label, so a row the engine
# labels or places otherwise cannot leave the texts without a word — and an
# identifier column of the table otherwise.

# ── Metric state levels (ordered) ──────────────────────────────────
metric_state_levels <- c("na", "no_benchmark",
                          "extreme_below_pooled", "extreme_above_pooled",
                          "zero", "below_q1",
                          "q1_to_q2", "q2_to_q3", "above_q3")

# Classify each metric in a table into a state relative to reference quartiles.
# Returns a named ordered factor (metric_id → state).
classify_metrics <- function(table_data, identifier_col = NULL,
                             combine_cols = NULL, identifiers = NULL) {
  if (is.null(table_data) || nrow(table_data) == 0) {
    return(factor(character(0), levels = metric_state_levels, ordered = TRUE))
  }

  col_names <- names(table_data)
  own_col_name_candidates <- c("pooled_own", "rate_own")
  own_col_name <- own_col_name_candidates[own_col_name_candidates %in% col_names]

  if (!(length(own_col_name) == 1 && all(c("q1_ref", "q3_ref") %in% col_names))) {
    return(factor(character(0), levels = metric_state_levels, ordered = TRUE))
  }

  # Get row identifiers
  if (!is.null(identifiers)) {
    if (length(identifiers) != nrow(table_data)) {
      rlang::abort(
        c(
          "`identifiers` must have one value per row of `table_data`.",
          i = paste0(
            "The engine keys every row of its infectious-agent tables; the ",
            "caller passes one identity per row.")
        ),
        class = "reports_bad_identifiers")
    }
  } else if (!is.null(combine_cols) && all(combine_cols %in% names(table_data))) {
    identifiers <- apply(table_data[, combine_cols, drop = FALSE], 1, function(row) {
      paste(row, collapse = ":")
    })
  } else if (!is.null(identifier_col) && identifier_col %in% names(table_data)) {
    identifiers <- as.character(table_data[[identifier_col]])
  } else if (!is.null(rownames(table_data)) && !all(rownames(table_data) == as.character(seq_len(nrow(table_data))))) {
    identifiers <- rownames(table_data)
  } else {
    # The table has at least the quartile columns checked above.
    identifiers <- as.character(table_data[[1]])
  }

  own_values <- table_data[[own_col_name]]
  q1 <- table_data$q1_ref
  q3 <- table_data$q3_ref
  q2 <- if ("q2_ref" %in% col_names) table_data$q2_ref else q1 + (q3 - q1) / 2

  # CI columns for extreme-deviation classification when quartiles are
  # suppressed. Uses CI overlap test: the department CI and pooled CI must
  # not overlap, which is stronger than comparing the department point
  # estimate alone (which ignores the department's own imprecision).
  pooled_ref <- if ("pooled_ref" %in% col_names) table_data$pooled_ref else NULL
  ci_lower_ref <- if ("ci_lower_ref" %in% col_names) table_data$ci_lower_ref else NULL
  ci_upper_ref <- if ("ci_upper_ref" %in% col_names) table_data$ci_upper_ref else NULL
  ci_lower_own <- if ("ci_lower_own" %in% col_names) table_data$ci_lower_own else NULL
  ci_upper_own <- if ("ci_upper_own" %in% col_names) table_data$ci_upper_own else NULL
  has_pooled_ci <- !is.null(pooled_ref) && !is.null(ci_lower_ref) && !is.null(ci_upper_ref)
  has_own_ci <- !is.null(ci_lower_own) && !is.null(ci_upper_own)

  # Classify states (check order matters)
  states <- character(length(identifiers))
  for (i in seq_along(identifiers)) {
    own <- own_values[i]
    if (is.na(own)) {
      states[i] <- "na"
    } else if (is.na(q1[i]) || is.na(q3[i])) {
      # Quartiles suppressed — check if CIs indicate extreme deviation.
      # Triple gate: non-overlapping CIs, magnitude > 10×, pooled CI
      # narrow enough to be meaningful.
      if (has_pooled_ci && !is.na(pooled_ref[i]) &&
          !is.na(ci_lower_ref[i]) && !is.na(ci_upper_ref[i]) &&
          pooled_ref[i] > 0) {
        # Gate 1: CI non-overlap test. When the department CI is available,
        # require that the two CIs don't overlap at all. Fall back to
        # point-vs-CI when department CI is unavailable.
        if (has_own_ci && !is.na(ci_lower_own[i]) && !is.na(ci_upper_own[i])) {
          outside_ci <- ci_upper_own[i] < ci_lower_ref[i] ||
                        ci_lower_own[i] > ci_upper_ref[i]
        } else {
          outside_ci <- own < ci_lower_ref[i] || own > ci_upper_ref[i]
        }
        magnitude <- own / pooled_ref[i]
        extreme_magnitude <- magnitude > 10 || magnitude < 0.1
        ci_width_ratio <- (ci_upper_ref[i] - ci_lower_ref[i]) / pooled_ref[i]
        narrow_enough <- ci_width_ratio < 2.0
        if (outside_ci && extreme_magnitude && narrow_enough) {
          states[i] <- if (own > pooled_ref[i]) "extreme_above_pooled"
                       else "extreme_below_pooled"
        } else {
          states[i] <- "no_benchmark"
        }
      } else {
        states[i] <- "no_benchmark"
      }
    } else if (own == 0) {
      states[i] <- "zero"
    } else if (own < q1[i]) {
      states[i] <- "below_q1"
    } else if (!is.na(q2[i]) && own <= q2[i]) {
      states[i] <- "q1_to_q2"
    } else if (own <= q3[i]) {
      states[i] <- "q2_to_q3"
    } else {
      states[i] <- "above_q3"
    }
  }

  stats::setNames(
    factor(states, levels = metric_state_levels, ordered = TRUE),
    tolower(identifiers)
  )
}

# ── Metric state query helpers ────────────────────────────────────

# Get metric IDs in a specific state (or set of states)
get_metrics_in_state <- function(state_map, states) {
  names(state_map[state_map %in% states])
}

# Does this state_map contain any outliers?
has_outliers <- function(state_map) {
  !is.null(state_map) && length(state_map) > 0 &&
    any(state_map %in% c("zero", "below_q1", "above_q3"))
}

# Get outlier metric IDs by direction
get_outliers_below <- function(state_map) {
  get_metrics_in_state(state_map, c("zero", "below_q1"))
}

get_outliers_above <- function(state_map) {
  get_metrics_in_state(state_map, "above_q3")
}

# The display label of a resistance category key, as the resistance tables
# print it. The mapping is not the identity, and it is the one the resistance
# tables apply to their row labels — which the outlier prose has to match. The
# dataset abbreviates carbapenem and colistin resistance as `car`/`cor` while
# the categories are CARBR and COLR; and the descriptive label lives under a
# `_label` key, because the bare glossary term is carried separately as
# terminology.
localize_resistance_category <- function(abr_key, sR) {
  abr_label_key <- list(
    "3gcr" = "3gcr_label",
    car = "carbr_label",
    cor = "colr_label",
    mrsa = "mrsa_label",
    vre = "vre_label"
  )[[abr_key]]
  if (!is.null(abr_label_key) && !is.null(sR[[abr_label_key]])) {
    return(sR[[abr_label_key]])
  }
  logDebug(paste0(
    "localize_metric_name: no display label found for resistance ",
    "category '{abr_key}'. Using raw identifier as fallback."))
  abr_key
}

# Localize metric name by looking up in string resources.
# `labels` is the printed label of every row identity, as the rendered table
# holds it (`ia_metric_labels()` of `infectious-agent-rows.R`): an identity in
# it takes that label, since the outlier prose must name the row as the table
# shows it. A resistance table's identity names its category beside its node,
# and the text names the category too — the table prints the same row in every
# category's block, so the bare label would name one row of a block as any
# other's. `labels` wins over the glossary, whose English keys cannot name an
# identity. For glossary identifiers, when table_name is provided, that table's
# section is checked first so that table-specific labels (e.g.,
# "CVC-associated sepsis/BSI" in Table 2 vs plain "CVC" in Table 8) take
# precedence over the generic glossary entry.
localize_metric_name <- function(metric_id, sR, table_name = NULL,
                                 labels = NULL) {
  if (!is.null(labels) && metric_id %in% names(labels)) {
    if (grepl(":", metric_id, fixed = TRUE)) {
      abr_key <- strsplit(metric_id, ":", fixed = TRUE)[[1]][1]
      return(paste0(localize_resistance_category(abr_key, sR), ": ",
                    labels[[metric_id]]))
    }
    return(labels[[metric_id]])
  }

  # Check for combined identifiers (e.g., "3gcr:Enterobacteriaceae")
  if (grepl(":", metric_id)) {
    parts <- strsplit(metric_id, ":", fixed = TRUE)[[1]]
    if (length(parts) == 2) {
      abr_key <- parts[1]
      condition_key <- parts[2]
      localized_abr <- localize_resistance_category(abr_key, sR)
      # Routine is the default — omit the suffix. Only show the condition
      # for non-routine cases (e.g., "in case of 3GCR").
      if (condition_key == "routine") {
        return(localized_abr)
      }
      # Known testing conditions → parenthesized qualifier
      condition_map <- list(
        if_3gcr = "carbr_if_3gcr",
        "if_3gcr&car" = "colr_if_3gcr_and_carbr"
      )
      cond_sR_key <- condition_map[[condition_key]]
      if (!is.null(cond_sR_key) &&
          !is.null(sR[["tbl-resistance-test-rate"]][[cond_sR_key]])) {
        localized_cond <- sR[["tbl-resistance-test-rate"]][[cond_sR_key]]
        return(paste0(localized_abr, " (", localized_cond, ")"))
      }
      # Other composite IDs (e.g., infectious-agent rows of a resistance
      # table) → colon separator
      return(paste0(localized_abr, ": ", tools::toTitleCase(condition_key)))
    }
  }

  # Explicit metric identifier mappings for identifiers that don't match their
  # display label key directly. Uses sR keys that the table rendering code uses.
  metric_key_map <- list(
    bsi = "primary_sepsis_bsi_sc",
    hap = "pneumonia_sc",
    probiotic = "probiotics",
    all = "total",
    a = "access",
    w = "watch",
    r = "reserve"
  )

  # Apply key mapping (e.g., "a" → "access", "bsi" → "primary_sepsis_bsi_sc")
  mapped_key <- metric_key_map[[tolower(metric_id)]]
  lookup_key <- if (!is.null(mapped_key)) mapped_key else tolower(metric_id)

  # Map R internal table names to sR YAML keys
  table_name_map <- list(
    incidence_density_rate_table = "tbl-incidence-density-rates",
    dev_ass_incidence_density_rate_table = "tbl-device-associated-incidence-density-rates",
    usage_density_rate_table = "tbl-risk-density-rates",
    surgery_rate_table = "tbl-surgical-procedure-rates",
    infectious_agent_detection_rate_per_inf_type_table = "tbl-infectious-agent-detection-rate",
    resistance_test_rate_table = "tbl-resistance-test-rate",
    secondary_bsi_rate_table = "tbl-secondary-bsi-rates"
  )
  sR_table_key <- table_name_map[[table_name]] %||% table_name

  # When a table_name is provided, check that table's section first so that
  # table-specific overrides take precedence over the generic glossary.
  if (!is.null(sR_table_key) && !is.null(sR[[sR_table_key]][[lookup_key]])) {
    return(sR[[sR_table_key]][[lookup_key]])
  }

  # Try top-level keys
  if (!is.null(sR[[lookup_key]])) {
    return(sR[[lookup_key]])
  }

  # Try table-specific sections (fallback when no table_name provided)
  table_sections <- c(
    "tbl-risk-density-rates",
    "tbl-device-associated-incidence-density-rates",
    "tbl-surgical-procedure-rates",
    "tbl-incidence-density-rates",
    "tbl-infectious-agent-detection-rate",
    "tbl-resistance-test-rate"
  )

  for (section in table_sections) {
    if (!is.null(sR[[section]][[lookup_key]])) {
      return(sR[[section]][[lookup_key]])
    }
  }

  # Fall back to the raw identifier; record the gap in the log channel only (it
  # never surfaces in the rendered report body).
  logDebug(paste0(
    "localize_metric_name: no display label found for metric ",
    "identifier '{metric_id}'. Using raw identifier as fallback."))
  return(metric_id)
}
