# The reports' outlier texts and the lookups of the overview counts name the
# rows of the infectious-agent tables. They must do it by the engine's row
# identity, not by the printed label, so that a row the engine labels or places
# otherwise stays in the texts and no silent drop remains.

test_that("a row's identity is its node_id, and the Total's is total", {
  tbl <- fixture_agent_per_infection_groups()
  expect_identical(
    ia_row_identities(tbl),
    c("total", "gram_reaction|positive", "bacteria",
      "gram-positive-cocci", "enterobacterales", "fungi", "yeasts"))

  onto <- fixture_agent_per_infection_ontology()
  expect_identical(
    ia_row_identities(onto),
    c("total", "NeoIPC|1", "LPSN|genus/staphylococcus", "NeoIPC|63",
      "LPSN|species/staphylococcus-epidermidis",
      "LPSN|genus/staphylococcus~n.o.s.", "ICTV|191161"))
})

test_that("an identity is unique in every table, a resistance table's included", {
  for (tbl in list(
      fixture_agent_per_infection_groups(),
      fixture_agent_per_infection_ontology(),
      fixture_abr_infection_rate_groups())) {
    ids <- ia_row_identities(tbl)
    expect_false(anyDuplicated(ids) > 0)
  }

  abr <- fixture_abr_infection_rate_groups()
  expect_identical(
    ia_row_identities(abr)[c(1L, 2L, 4L, 5L, 7L)],
    c("3gcr:total", "3gcr:bacteria", "3gcr:enterobacterales",
      "car:total", "car:enterobacterales"))
})

test_that("ia_row_index finds the one row an identity names", {
  abr <- fixture_abr_infection_rate_groups()
  expect_identical(
    abr$n[ia_row_index(abr, "car:enterobacterales")], 1L)
  expect_identical(
    abr$n[ia_row_index(abr, "3gcr:enterobacterales")], 2L)
  expect_identical(
    abr$pooled[ia_row_index(abr, "mrsa:total")], 2.9)

  onto <- fixture_agent_per_infection_ontology()
  expect_identical(
    onto$n[ia_row_index(onto, "NeoIPC|63")], 4L)
  expect_identical(
    onto$group[ia_row_index(onto, "LPSN|genus/staphylococcus~n.o.s.")],
    "Staphylococcus n.o.s.")
})

test_that("ia_row_index refuses an identity no row carries", {
  tbl <- fixture_agent_per_infection_groups()
  expect_error(ia_row_index(tbl, "staphylococcus"), "no row")
})

test_that("ia_row_index refuses an identity more than one row carries", {
  broken <- fixture_agent_per_infection_groups()
  broken$node_id[6] <- "bacteria"
  expect_error(ia_row_index(broken, "bacteria"), "more than one")
})

test_that("ia_metric_labels maps every identity to the label the table prints", {
  labels <- ia_metric_labels(fixture_agent_per_infection_groups())
  expect_identical(labels[["total"]], "Total")
  expect_identical(labels[["gram-positive-cocci"]], "Gram-positive cocci")
  expect_identical(labels[["gram_reaction|positive"]], "Gram-positive")

  abr_labels <- ia_metric_labels(fixture_abr_infection_rate_groups())
  expect_identical(
    abr_labels[["3gcr:gram-negative-bacilli"]], "Gram-negative bacilli")

  onto_labels <- ia_metric_labels(fixture_agent_per_infection_ontology())
  expect_identical(
    onto_labels[["lpsn|genus/staphylococcus~n.o.s."]], "Staphylococcus n.o.s.")
})
