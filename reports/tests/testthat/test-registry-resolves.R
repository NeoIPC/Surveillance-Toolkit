# The Partner Report's outlier texts name their infectious-agent metrics by
# the engine's row identity. A wrongly keyed identity would drop the metric's
# text from the report without a word, so this test takes the keys from the
# report's own setup source — never a copy kept here — and proves each one
# resolves to exactly one row of an engine-shaped table.

collect_first_state_keys <- function(e) {
  if (!is.call(e)) return(character(0))
  keys <- character(0)
  if (identical(e[[1]], as.name("first_state")) && length(e) >= 3 &&
      is.call(e[[3]]) && identical(e[[3]][[1]], as.name("c"))) {
    parts <- as.list(e[[3]])[-1]
    if (all(vapply(parts, function(x) is.character(x) && length(x) == 1L,
                   logical(1))))
      keys <- unlist(parts)
  }
  for (arg in as.list(e)[-1])
    keys <- c(keys, collect_first_state_keys(arg))
  keys
}

setup_exprs <- as.list(parse(knitr::purl(
  normalizePath("../../Partner-Report/_setup.qmd"),
  quiet = TRUE, output = tempfile(fileext = ".R"))))

grab_rhs <- function(name) {
  hits <- Filter(function(e) {
    is.call(e) && identical(as.character(e[[1]]), "<-") &&
      identical(as.character(e[[2]]), name)
  }, setup_exprs)
  stopifnot(length(hits) == 1L)
  hits[[1]][[3]]
}

# The interpretation functions that read infectious-agent identities, and the
# grouping entries of the two grouped infectious-agent tables.
ia_interpreters <- c("interpret_agent_staphylococci",
                     "interpret_agent_enterobacterales",
                     "interpret_abr_gram_positive")
interpreter_keys <- unlist(lapply(ia_interpreters,
                                  \(f) collect_first_state_keys(grab_rhs(f))))

og_expr <- grab_rhs("outlier_groupings")
stub_env <- new.env()
for (sym in unique(unlist(regmatches(
    deparse(og_expr), gregexpr("interpret_[a-z0-9_]+", deparse(og_expr))))))
  assign(sym, function(...) NULL, envir = stub_env)
og <- eval(og_expr, stub_env)
grouping_keys <- unlist(lapply(
  c("infectious_agent_detection_rate_per_agent_table",
    "abr_infection_rate_table"),
  \(tbl) unlist(lapply(og[[tbl]], `[[`, "metrics"))))

named_keys <- unique(c(interpreter_keys, grouping_keys))
# The old-shape texts keyed their metrics by printed labels, which contain a
# space or a full stop; the engine identities never do.
engine_keys <- tolower(named_keys[!grepl("[ .]", named_keys)])
abr_prefix <- "^(3gcr|car|cor|mrsa|vre):"

test_that("the named infectious-agent identities are a non-empty set", {
  # Guards against the extraction silently degrading to nothing: at least one
  # name from each table's block must be in the classified set.
  expect_true("neoipc|63" %in% engine_keys)
  expect_true("mrsa:gram-positive-cocci" %in% engine_keys)
  expect_true(all(c("enterobacterales", "lpsn|order/enterobacterales") %in%
                    engine_keys))
})

test_that("every infectious-agent identity named by the setup resolves to one
           row of an engine-shaped table", {
  agent_tables <- list(fixture_registry_agent_groups(),
                       fixture_registry_agent_ontology())
  abr_tables <- list(fixture_registry_abr_groups(),
                     fixture_registry_abr_ontology())
  agent <- engine_keys[!grepl(abr_prefix, engine_keys)]
  abr <- engine_keys[grepl(abr_prefix, engine_keys)]
  for (key in agent) {
    resolves <- vapply(agent_tables, function(tbl)
      !inherits(try(ia_row_index(tbl, key, "table"), silent = TRUE),
                "try-error"), logical(1))
    expect_true(any(resolves), info = key)
  }
  for (key in abr) {
    resolves <- vapply(abr_tables, function(tbl)
      !inherits(try(ia_row_index(tbl, key, "table"), silent = TRUE),
                "try-error"), logical(1))
    expect_true(any(resolves), info = key)
  }
})

test_that("ia_row_index refuses an identity no fixture row carries", {
  # The failure signal of the test above: a typo in any named key must abort,
  # not resolve, so the loop cannot pass by construction.
  typo_tables <- c(list(fixture_registry_agent_groups(),
                        fixture_registry_agent_ontology()),
                   list(fixture_registry_abr_groups(),
                        fixture_registry_abr_ontology()))
  for (tbl in typo_tables)
    expect_error(ia_row_index(tbl, "neoipc|36", "table"), "no row")
})
