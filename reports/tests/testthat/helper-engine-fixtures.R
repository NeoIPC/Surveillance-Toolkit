# Fixtures in the shape neoipcr's infectious-agent engine returns, as
# API-DESIGN.md §13.8 and the getters' documentation give it: `level`, `rank`,
# `node_id`, `parent_id`, `group`, the measures, and `n_total_only` on a Total
# row; `abr` before them in the two resistance tables. They hold no surveillance
# data, only row structure, and they keep the engine's key formats: a node's
# `<ConceptSource>|<ConceptId>`, an ICTV virus's `ICTV|<IctvId>`, a reporting
# group's kebab-case key, a summary row's `<attribute>|<value>`, and a residual
# row's `<node_id>~n.o.s.`. Each fixture is a tibble in that shape.

# The table of the infectious agents detected, over the reporting groups: a
# Total, the summary block above the tree, the tree with a group nested in its
# top-level node, and `n_total_only` on the Total alone.
fixture_agent_per_infection_groups <- function() {
  tibble::tribble(
    ~level, ~rank, ~node_id, ~parent_id, ~group,
    0L, NA_character_, NA_character_, NA_character_, "Total",
    1L, NA_character_, "gram_reaction|positive", NA_character_, "Gram-positive",
    1L, NA_character_, "bacteria", NA_character_, "Bacteria",
    2L, NA_character_, "gram-positive-cocci", "bacteria", "Gram-positive cocci",
    2L, NA_character_, "enterobacterales", "bacteria", "Enterobacterales",
    1L, NA_character_, "fungi", NA_character_, "Fungi",
    2L, NA_character_, "yeasts", "fungi", "Yeasts",
  ) |>
    dplyr::mutate(
      n = c(12L, 6L, 11L, 5L, 4L, 1L, 1L),
      total = c(8L, 6L, 8L, 6L, 4L, 1L, 1L),
      pooled = c(150, 100, 137.5, 83.3, 100, 100, 100),
      ci_lower = c(77.2, 41.5, 69.6, 35.8, 30.0, 2.5, 2.5),
      ci_upper = c(250.4, 193.3, 227.2, 161.9, 100.0, 97.5, 97.5),
      q1 = c(100, 80, 100, 50, 50, NA_real_, NA_real_),
      q2 = c(120, 100, 110, 60, 75, NA_real_, NA_real_),
      q3 = c(140, 130, 130, 90, 90, NA_real_, NA_real_),
      quartile_departments = c(6L, 6L, 6L, 6L, 5L, 0L, 0L),
      n_total_only = c(1L, NA_integer_, NA_integer_, NA_integer_,
                       NA_integer_, NA_integer_, NA_integer_))
}

# The same table over the full ontology: the domain row, an LPSN genus, the
# ontology's own group under it, a species, the residual rows of the genus
# and of that group — a group within the genus, not above it — a virus
# keyed by its ICTV identifier, and the ontology's Viruses top as the
# released list holds it: a tree top with no parent and no rank.
fixture_agent_per_infection_ontology <- function() {
  tibble::tribble(
    ~level, ~rank, ~node_id, ~parent_id, ~group,
    0L, NA_character_, NA_character_, NA_character_, "Total",
    1L, "Domain", "NeoIPC|1", NA_character_, "Bacteria",
    2L, "Genus", "LPSN|genus/staphylococcus", "NeoIPC|1", "Staphylococcus",
    3L, "Group", "NeoIPC|63", "LPSN|genus/staphylococcus",
    "Coagulase-negative staphylococci",
    3L, "Species", "LPSN|species/staphylococcus-epidermidis",
    "NeoIPC|63", "Staphylococcus epidermidis",
    3L, NA_character_, "LPSN|genus/staphylococcus~n.o.s.",
    "LPSN|genus/staphylococcus", "Staphylococcus n.o.s.",
    4L, NA_character_, "NeoIPC|63~n.o.s.", "NeoIPC|63",
    "Coagulase-negative staphylococci n.o.s.",
    1L, "Species", "ICTV|191161", NA_character_, "Human respiratory syncytial virus",
    1L, NA_character_, "NeoIPC|100", NA_character_, "Viruses",
  ) |>
    dplyr::mutate(
      n = c(12L, 11L, 6L, 4L, 2L, 2L, 2L, 1L, 3L),
      total = c(8L, 8L, 6L, 4L, 2L, 2L, 2L, 1L, 2L),
      pooled = c(150, 137.5, 100, 100, 100, 100, 100, 100, 150),
      ci_lower = c(77.2, 69.6, 41.5, 15.8, 1.5, 1.5, 1.5, 2.5, 3.2),
      ci_upper = c(250.4, 227.2, 193.3, 84.1, 64.6, 64.6, 64.6, 97.5, 99.8),
      q1 = c(100, 100, 50, NA_real_, NA_real_, NA_real_, NA_real_,
             NA_real_, NA_real_),
      q2 = c(120, 110, 60, NA_real_, NA_real_, NA_real_, NA_real_,
             NA_real_, NA_real_),
      q3 = c(140, 130, 90, NA_real_, NA_real_, NA_real_, NA_real_,
             NA_real_, NA_real_),
      quartile_departments = c(6L, 6L, 6L, 0L, 0L, 0L, 0L, 0L, 0L),
      n_total_only = c(1L, NA_integer_, NA_integer_, NA_integer_,
                       NA_integer_, NA_integer_, NA_integer_, NA_integer_,
                       NA_integer_))
}

# A resistance table's blocks: the same genus row in two categories' blocks,
# so the bare `node_id` names two rows and only `abr` with it is a key, and a
# Total per block.
fixture_abr_infection_rate_groups <- function() {
  tibble::tribble(
    ~abr, ~level, ~rank, ~node_id, ~parent_id, ~group,
    "3gcr", 0L, NA_character_, NA_character_, NA_character_, "Total",
    "3gcr", 1L, NA_character_, "bacteria", NA_character_, "Bacteria",
    "3gcr", 2L, NA_character_, "gram-negative-bacilli", "bacteria",
    "Gram-negative bacilli",
    "3gcr", 2L, NA_character_, "enterobacterales", "bacteria",
    "Enterobacterales",
    "car", 0L, NA_character_, NA_character_, NA_character_, "Total",
    "car", 1L, NA_character_, "bacteria", NA_character_, "Bacteria",
    "car", 2L, NA_character_, "enterobacterales", "bacteria",
    "Enterobacterales",
    "mrsa", 0L, NA_character_, NA_character_, NA_character_, "Total",
    "mrsa", 1L, NA_character_, "gram-positive-cocci", NA_character_,
    "Gram-positive cocci",
  ) |>
    dplyr::mutate(
      n = c(3L, 3L, 2L, 2L, 1L, 1L, 1L, 2L, 2L),
      total = c(1200, 1200, 800, 600, 900, 900, 400, 700, 700),
      pooled = c(2.5, 2.5, 2.5, 3.3, 1.1, 1.1, 2.5, 2.9, 2.5),
      ci_lower = c(0.5, 0.5, 0.3, 0.4, 0.0, 0.0, 0.1, 0.4, 0.3),
      ci_upper = c(7.3, 7.3, 9.1, 11.9, 6.2, 6.2, 13.0, 10.4, 9.1),
      q1 = c(0, 0, 0, 0, 0, 0, 0, 0, 0),
      q2 = c(2, 2, 2, 2, 1, 1, 2, 2, 2),
      q3 = c(3, 3, 3, 4, 2, 2, 3, 3, 3),
      quartile_departments = c(8L, 8L, 8L, 8L, 8L, 8L, 5L, 5L, 5L),
      n_total_only = c(0L, NA_integer_, NA_integer_, NA_integer_,
                       0L, NA_integer_, NA_integer_,
                       0L, NA_integer_))
}

# A resistance table in the shape the engine returns to the Partner Report:
# the department's own columns and the reference's joined under `_own` and
# `_ref`, the five Tested columns of each beside the rate's. One row's
# `tested_total_own` sits below the sparse-data threshold while its `n_own`
# stands well above it, so a test can tell the Tested share's own flag from
# the rate's. `test-resistance-tested-share.R` builds the table from this.
fixture_resistance_own <- function() {
  tibble::tribble(
    ~abr, ~level, ~rank, ~node_id, ~parent_id, ~group,
    "3gcr", 0L, NA_character_, NA_character_, NA_character_, "Total",
    "3gcr", 1L, "Genus", "LPSN|genus/klebsiella", NA_character_,
    "Klebsiella",
    "mrsa", 1L, "Genus", "LPSN|genus/staphylococcus", NA_character_,
    "Staphylococcus",
  ) |>
    dplyr::mutate(
      abr = factor(.data$abr,
                   levels = c("3gcr", "car", "cor", "mrsa", "vre")),
      n_own = c(40L, 30L, 20L),
      total_own = c(1200, 900, 500),
      pooled_own = c(20.0, 23.3, 25.0),
      ci_lower_own = c(16.4, 19.2, 20.4),
      ci_upper_own = c(23.9, 27.9, 30.1),
      n_ref = c(400L, 300L, 200L),
      pooled_ref = c(22.0, 24.0, 26.0),
      ci_lower_ref = c(21.0, 23.0, 25.0),
      ci_upper_ref = c(23.1, 25.1, 27.1),
      q1_ref = c(15.0, 17.0, 19.0),
      q2_ref = c(22.0, 24.0, 26.0),
      q3_ref = c(29.0, 31.0, 33.0),
      q1_ci_lower_ref = c(14.0, 16.0, 18.0),
      q1_ci_upper_ref = c(16.0, 18.0, 20.0),
      q2_ci_lower_ref = c(21.0, 23.0, 25.0),
      q2_ci_upper_ref = c(23.0, 25.0, 27.0),
      q3_ci_lower_ref = c(28.0, 30.0, 32.0),
      q3_ci_upper_ref = c(30.0, 32.0, 34.0),
      quartile_departments_ref = c(20L, 20L, 20L),
      tested_n_own = c(28L, 6L, 18L),
      tested_total_own = c(40L, 8L, 20L),
      tested_pooled_own = c(70.0, 75.0, 90.0),
      tested_ci_lower_own = c(55.9, 44.3, 71.0),
      tested_ci_upper_own = c(81.7, 93.7, 98.5),
      tested_n_ref = c(280L, 210L, 150L),
      tested_total_ref = c(400L, 300L, 200L),
      tested_pooled_ref = c(70.0, 70.0, 75.0),
      tested_ci_lower_ref = c(65.1, 63.8, 68.6),
      tested_ci_upper_ref = c(74.6, 75.9, 80.7))
}

# The same shape as the Reference Report reads it: the reference's own
# columns, unsuffixed. Its second row's `tested_total` is the sparse one.
fixture_resistance_ref <- function() {
  tibble::tribble(
    ~abr, ~level, ~rank, ~node_id, ~parent_id, ~group,
    "3gcr", 0L, NA_character_, NA_character_, NA_character_, "Total",
    "3gcr", 1L, "Genus", "LPSN|genus/klebsiella", NA_character_,
    "Klebsiella",
    "mrsa", 1L, "Genus", "LPSN|genus/staphylococcus", NA_character_,
    "Staphylococcus",
  ) |>
    dplyr::mutate(
      abr = factor(.data$abr,
                   levels = c("3gcr", "car", "cor", "mrsa", "vre")),
      n = c(400L, 300L, 200L),
      total = c(12000, 9000, 5000),
      pooled = c(20.0, 23.3, 25.0),
      ci_lower = c(19.0, 22.0, 23.5),
      ci_upper = c(21.1, 24.7, 26.6),
      q1 = c(15.0, 17.0, 19.0),
      q2 = c(22.0, 24.0, 26.0),
      q3 = c(29.0, 31.0, 33.0),
      q1_ci_lower = c(14.0, 16.0, 18.0),
      q1_ci_upper = c(16.0, 18.0, 20.0),
      q2_ci_lower = c(21.0, 23.0, 25.0),
      q2_ci_upper = c(23.0, 25.0, 27.0),
      q3_ci_lower = c(28.0, 30.0, 32.0),
      q3_ci_upper = c(30.0, 32.0, 34.0),
      quartile_departments = c(20L, 20L, 20L),
      tested_n = c(280L, 9L, 150L),
      tested_total = c(400L, 12L, 200L),
      tested_pooled = c(70.0, 75.0, 75.0),
      tested_ci_lower = c(65.1, 63.8, 68.6),
      tested_ci_upper = c(74.6, 75.9, 80.7))
}

# A resistance table as a neoipcr from before the engine returns it: rows
# keyed by the printed label under `taxon`, no `node_id`, and the Tested
# columns absent — the reports render those tables without the column.
fixture_resistance_old <- function() {
  tibble::tribble(
    ~abr, ~level, ~taxon, ~group,
    "3gcr", 1L, "order", "Enterobacterales",
    "mrsa", 1L, "genus", "Staphylococcus",
  ) |>
    dplyr::mutate(
      abr = factor(.data$abr,
                   levels = c("3gcr", "car", "cor", "mrsa", "vre")),
      n_own = c(10L, 8L),
      ia_tst_tot_own = c(300L, 200L),
      pooled_own = c(15.0, 18.0),
      ci_lower_own = c(12.0, 14.5),
      ci_upper_own = c(18.4, 22.1),
      n_ref = c(100L, 80L),
      ia_tst_tot_ref = c(3000L, 2000L),
      pooled_ref = c(16.0, 19.0),
      ci_lower_ref = c(15.0, 18.0),
      ci_upper_ref = c(17.1, 20.1),
      q1_ref = c(12.0, 15.0),
      q2_ref = c(16.0, 19.0),
      q3_ref = c(20.0, 23.0),
      # The pre-engine table carries its own Tested columns; the reports drop
      # them, since only the engine's are the §13.8.6 measure the column
      # claims to print.
      tested_n_own = c(7L, 6L),
      tested_total_own = c(10L, 8L),
      tested_pooled_own = c(70.0, 75.0),
      tested_ci_lower_own = c(41.2, 44.3),
      tested_ci_upper_own = c(90.9, 93.7))
}

# The rows the Partner Report's outlier texts name for the two grouped
# infectious-agent tables, per version, as `outlier_groupings` and the
# `first_state()` candidate lists name them: `test-registry-resolves.R`
# extracts those keys from the report's own setup source and resolves each
# against these rows. They carry only what identity needs — `node_id`, `group`,
# and the `abr` block key in the resistance tables.
fixture_registry_agent_groups <- function() {
  tibble::tribble(
    ~node_id, ~group,
    NA_character_, "Total",
    "bacteria", "Bacteria",
    "gram-positive-cocci", "Gram-positive cocci",
    "enterobacterales", "Enterobacterales",
  )
}

fixture_registry_agent_ontology <- function() {
  tibble::tribble(
    ~node_id, ~group,
    NA_character_, "Total",
    "LPSN|genus/staphylococcus", "Staphylococcus",
    "NeoIPC|63", "Coagulase-negative staphylococci",
    "NeoIPC|64", "Coagulase-positive staphylococci",
    "LPSN|species/staphylococcus-epidermidis", "Staphylococcus epidermidis",
    "LPSN|species/staphylococcus-aureus", "Staphylococcus aureus",
    "LPSN|order/enterobacterales", "Enterobacterales",
    "LPSN|genus/klebsiella", "Klebsiella",
    "LPSN|genus/escherichia", "Escherichia",
    "LPSN|genus/enterobacter", "Enterobacter",
    "LPSN|genus/serratia", "Serratia",
  )
}

fixture_registry_abr_groups <- function() {
  tibble::tribble(
    ~abr, ~node_id, ~group,
    "3gcr", NA_character_, "Total",
    "car", NA_character_, "Total",
    "cor", NA_character_, "Total",
    "mrsa", NA_character_, "Total",
    "mrsa", "gram-positive-cocci", "Gram-positive cocci",
    "vre", NA_character_, "Total",
    "vre", "gram-positive-cocci", "Gram-positive cocci",
  )
}

fixture_registry_abr_ontology <- function() {
  tibble::tribble(
    ~abr, ~node_id, ~group,
    "3gcr", NA_character_, "Total",
    "car", NA_character_, "Total",
    "cor", NA_character_, "Total",
    "mrsa", NA_character_, "Total",
    "mrsa", "LPSN|genus/staphylococcus", "Staphylococcus",
    "mrsa", "LPSN|species/staphylococcus-aureus", "Staphylococcus aureus",
    "vre", NA_character_, "Total",
    "vre", "LPSN|genus/enterococcus", "Enterococcus",
  )
}
