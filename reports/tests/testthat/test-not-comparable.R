# `get_benchmark_data()` refuses each slot on its own stamp, so the two
# versions of a table can be refused apart: a list release that only grew the
# full tree records the ontology slot alone. The callout must appear on the
# table actually rendered from a refused slot, and on no other.

test_that("not_comparable_here flags the refused slot of the same table", {
  nc <- c("abr_infection_rate_table", "abr_infection_rate_ontology_table")
  expect_true(not_comparable_here("abr_infection_rate_table", nc))
  expect_true(not_comparable_here("abr_infection_rate_ontology_table", nc))
})

test_that("not_comparable_here flags an ontology-only refusal", {
  nc <- "abr_infection_rate_ontology_table"
  expect_true(not_comparable_here("abr_infection_rate_ontology_table", nc))
  expect_false(not_comparable_here("abr_infection_rate_table", nc))
})

test_that("not_comparable_here stays off other tables' slots", {
  nc <- "abr_infection_rate_table"
  expect_false(not_comparable_here("infectious_agent_resistance_rate_table", nc))
  expect_false(not_comparable_here("infectious_agent_resistance_rate_ontology_table", nc))
  expect_false(not_comparable_here("organism_resistance_rate_table", nc))
})

test_that("not_comparable_here is silent when nothing is refused", {
  expect_false(not_comparable_here("abr_infection_rate_table", character(0)))
})
