# The outlier framework classifies each metric of a benchmarked table into a
# state relative to the reference quartiles, and names it back to the reader.
# These tests hold the framework across the move to identity keys: the state
# map must key by the lowercased row identity the caller passes, and the label
# of an infectious-agent metric must be the engine's label the table prints,
# not a glossary guess for an English row label.

make_benchmark_fixture <- function() {
  tibble::tribble(
    ~node_id, ~group, ~pooled_own, ~pooled_ref, ~ci_lower_ref, ~ci_upper_ref,
    ~ci_lower_own, ~ci_upper_own, ~q1_ref, ~q2_ref, ~q3_ref,
    # below Q1
    "a", "A", 1.0, 10, 8, 12, 0.5, 2.0, 8, 10, 12,
    # within the interquartile range
    "b", "B", 10.0, 10, 8, 12, 9.0, 11.0, 8, 10, 12,
    # above Q3
    "c", "C", 30.0, 10, 8, 12, 28.0, 32.0, 8, 10, 12,
    # zero with the quartiles present
    "d", "D", 0.0, 10, 8, 12, NA_real_, NA_real_, 8, 10, 12,
    # quartiles suppressed, extreme: disjoint CIs, 20-fold, narrow pooled CI
    "e", "E", 200.0, 10, 9, 11, 190.0, 220.0, NA_real_, NA_real_, NA_real_,
    # quartiles suppressed, not extreme: overlapping CIs
    "f", "F", 15.0, 10, 8, 12, 12.0, 18.0, NA_real_, NA_real_, NA_real_,
    # no own figure
    "g", "G", NA_real_, 10, 8, 12, NA_real_, NA_real_, 8, 10, 12,
  )
}

test_that("classify_metrics keys the state map by the lowercased identifiers", {
  states <- classify_metrics(
    make_benchmark_fixture(), identifiers = c("NodeA", "NodeB", "NodeC",
                                              "NodeD", "NodeE", "NodeF",
                                              "NodeG"))
  expect_identical(
    names(states),
    c("nodea", "nodeb", "nodec", "noded", "nodee", "nodef", "nodeg"))
  expect_identical(
    as.character(states),
    c("below_q1", "q1_to_q2", "above_q3", "zero",
      "extreme_above_pooled", "no_benchmark", "na"))
  expect_true(is.ordered(states))
})

test_that("classify_metrics still classifies by its identifier columns", {
  tbl <- make_benchmark_fixture()
  states <- classify_metrics(tbl, identifier_col = "group")
  expect_identical(names(states)[1:3], c("a", "b", "c"))
  states <- classify_metrics(tbl, combine_cols = c("node_id", "group"))
  expect_identical(names(states)[1], "a:a")
})

test_that("the state query helpers report the outliers", {
  states <- classify_metrics(
    make_benchmark_fixture(), identifiers = letters[1:7])
  expect_true(has_outliers(states))
  expect_setequal(get_outliers_below(states), c("a", "d"))
  expect_setequal(get_outliers_above(states), "c")
  empty <- classify_metrics(tibble::tibble())
  expect_false(has_outliers(empty))
})

test_that("a wrong identifier length aborts under its own class", {
  conds <- expect_condition(
    classify_metrics(make_benchmark_fixture(), identifiers = c("a", "b")),
    class = "reports_bad_identifiers")
  expect_true(inherits(conds, "reports_bad_identifiers"))
})

test_that("localize_metric_name returns the table's own label for an identity", {
  labels <- c(
    "total" = "Total",
    "lpsn|genus/staphylococcus~n.o.s." = "Staphylococcus n.o.s.",
    "3gcr:enterobacterales" = "Enterobacterales",
    "gram-positive-cocci" = "Gram-positive cocci")
  expect_identical(localize_metric_name("total", sR = NULL, labels = labels),
                   "Total")
  expect_identical(
    localize_metric_name("lpsn|genus/staphylococcus~n.o.s.", sR = NULL,
                         labels = labels),
    "Staphylococcus n.o.s.")
  # The text names the category beside the row: the table prints the same
  # row in every category's block, so the bare label names any of them.
  expect_identical(
    localize_metric_name("3gcr:enterobacterales", sR = NULL, labels = labels),
    "3gcr: Enterobacterales")
})

test_that("localize_metric_name still resolves the glossary identifiers", {
  sR <- list(
    "3gcr_label" = "3GCR",
    carbr_label = "CARBR",
    "tbl-resistance-test-rate" = list(carbr_if_3gcr = "in case of 3GCR"))
  expect_identical(localize_metric_name("3gcr:if_3gcr", sR),
                   "3GCR (in case of 3GCR)")
  expect_identical(
    localize_metric_name("car:routine", sR,
                         table_name = "resistance_test_rate_table"),
    "CARBR")
})

test_that("resistance-fixture rows are named by category and row together", {
  # The fixture repeats its genus row in two categories' blocks: identity
  # alone already separates them, and the outlier text must say which block
  # a named row belongs to.
  fixture <- fixture_abr_infection_rate_groups()
  labels <- ia_metric_labels(fixture)
  expect_true(all(c("3gcr:total", "car:total", "3gcr:enterobacterales",
                    "car:enterobacterales") %in% names(labels)))
  sR <- list("3gcr_label" = "3GCR", "carbr_label" = "CARBR")
  expect_identical(localize_metric_name("3gcr:total", sR, labels = labels),
                   "3GCR: Total")
  expect_identical(localize_metric_name("car:total", sR, labels = labels),
                   "CARBR: Total")
  expect_identical(
    localize_metric_name("3gcr:enterobacterales", sR, labels = labels),
    "3GCR: Enterobacterales")
  expect_identical(
    localize_metric_name("car:enterobacterales", sR, labels = labels),
    "CARBR: Enterobacterales")
})

test_that("the labels of an identity win over the glossary, and the category
           stands beside them", {
  sR <- list("3gcr_label" = "3GCR")
  labels <- c("3gcr:enterobacterales" = "Enterobacterales",
              "3gcr:total" = "Total")
  expect_identical(
    localize_metric_name("3gcr:enterobacterales", sR, labels = labels),
    "3GCR: Enterobacterales")
  # Every block's Total reads as its block's, not as any other's.
  expect_identical(localize_metric_name("3gcr:total", sR, labels = labels),
                   "3GCR: Total")
})
