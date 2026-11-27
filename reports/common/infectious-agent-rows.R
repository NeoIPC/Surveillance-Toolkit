# Row identity for the infectious-agent tables neoipcr's engine returns.
#
# The reports' outlier texts and their overview counts name the rows of those
# tables. A printed label is no key: `group` holds the English name of a node,
# which a later release of the infectious-agent list can rename, while
# `node_id` is the key the engine keeps for the node across releases. These
# functions give every reportable row a key and give a key back the label the
# table prints.
#
# A row's identity is its `node_id`. Two kinds of row need more than that:
# a Total row carries no `node_id` at all and takes `total`; and a row of a
# resistance table repeats its `node_id` in every category's block that holds
# its node, so its identity carries the resistance category beside it,
# `<abr>:<node_id>` and `<abr>:total`. The engine builds the tables so that
# every identity is unique within a table (neoipcr's `API-DESIGN.md` §13.8.2);
# an identity that names no row or more than one is a mismatch between the
# reports and the engine, and is refused rather than resolved to a first match.

# The identity of every row of `table_data`, in the table's own order.
ia_row_identities <- function(table_data) {
  ids <- if ("node_id" %in% names(table_data)) {
    as.character(table_data$node_id)
  } else {
    rep(NA_character_, nrow(table_data))
  }
  ids[is.na(ids)] <- "total"
  if ("abr" %in% names(table_data)) {
    ids <- paste0(as.character(table_data$abr), ":", ids)
  }
  ids
}

# The printed label of every row, under its lowercased identity: the state
# maps of the outlier framework are keyed lowercased, and the texts quote the
# table by these labels.
ia_metric_labels <- function(table_data) {
  stats::setNames(
    as.character(table_data$group),
    tolower(ia_row_identities(table_data)))
}

# The index of the one row of `table_data` whose identity is `identity`,
# matched without regard to case. An identity no row carries, or one more than
# one row carries, aborts: the outlier texts would otherwise drop a metric
# without a word, which is the defect this mechanism replaces.
ia_row_index <- function(table_data, identity, table_label = "table") {
  hits <- which(tolower(ia_row_identities(table_data)) == tolower(identity))
  if (length(hits) == 0L) {
    rlang::abort(c(
      paste0(
        "no row of the ", table_label,
        " carries the identity '", identity, "'."),
      i = paste0(
        "The engine builds every row of the released infectious-agent list's ",
        "classification; an identity the reports name must be a node of it.")))
  }
  if (length(hits) > 1L) {
    rlang::abort(c(
      paste0(
        "more than one row of the ", table_label,
        " carries the identity '", identity, "'."),
      i = paste0(
        "The engine gives every row of a table a unique identity ",
        "(neoipcr's API-DESIGN.md §13.8.2); a repeat is a broken table.")))
  }
  hits
}

# True where the table rendered under the given slot must carry the Partner
# Report's callout for rate definitions that differ: `get_benchmark_data()`
# stamps every infectious-agent table slot with its own rate-definition
# digest, and records under `not_comparable` exactly the slots it refused —
# the two versions of a table are refused separately, because a list release
# that only grew the full tree leaves the groups version comparable.
# NEOIPC-PERMANENT(dataset-format): never drop this. A stored reference
# dataset outlives every release, and one calculated under other definitions
# — including one old enough to carry no rate-definition stamps at all —
# cannot be compared with the department's, no matter how the reports evolve.
not_comparable_here <- function(slot, not_comparable) {
  slot %in% not_comparable
}

# The state of the first of `keys` the state map carries, or NULL. An
# infectious-agent metric is named by its engine identity, and by the printed
# label the reports keyed it by before the engine tables arrived: whichever of
# the two the table was built with is present, the other is not, and the
# interpretation reads the one that is. The state map lowercases its keys, so
# the lookup lowercases the candidate keys.
first_state <- function(state_map, keys) {
  hit <- tolower(keys)[tolower(keys) %in% names(state_map)]
  if (length(hit) == 0L) NULL else state_map[[hit[1]]]
}

# The ranks whose rows the infectious-agent tables set in italics. A genus
# name is a Latin binomial's first word like a species' and stands italic
# beside it, and a subgenus no less.
ia_italic_ranks <- c(
  "Realm", "Domain", "Subkingdom", "Kingdom", "Phylum", "Subphylum",
  "Class", "Subclass", "Order", "Suborder", "Family", "Subfamily",
  "Genus", "Subgenus", "Species", "Subspecies", "Serotype", "Variety")

# The printed labels of the engine's deeper tree rows, with one em space
# (U+2003) added per level before them. `gt::tab_stub_indent()` caps its
# per-level indent at five levels, so a row of level 6 or deeper would
# otherwise print at level 5's indent alike; the em space rides along with the
# label through `fmt_markdown()`, which passes it to the rendered text in both
# the HTML and the LaTeX output, and indents one level past the cap per level
# beyond it.
ia_indent_labels <- function(labels, levels) {
  extra <- ifelse(is.na(levels), 0L, as.integer(pmax(levels - 5L, 0L)))
  paste0(strrep("\u2003", extra), labels)
}

# True for the residual (`~n.o.s.`) rows that stand above the genus: the
# engine gives a residual row no rank of its own, and its `parent_id` names
# the node it gathers the unlisted agents of. A node at or below the genus is
# what the `nos_footnote` explains, so only a node above the genus earns the
# other note. Rank alone does not tell: the classification's groups carry the
# rank "Group" wherever the list places them, a group within the genus
# *Staphylococcus* among them, so a parent of that rank is judged by its own
# parent, and the walk up the chain reads the node's path. Where the table
# carries no row for a node, the path word of its own identifier decides,
# which only some identifier sources carry.
ia_above_genus <- function(table_data, node_ids, residual) {
  at_or_below_genus <- c("Genus", "Subgenus", "Species", "Subspecies",
                         "Serotype", "Variety")
  known <- !is.na(node_ids)
  rank_by_node <- stats::setNames(
    as.character(table_data$rank)[known], node_ids[known])
  parent_by_node <- stats::setNames(
    as.character(table_data$parent_id)[known], node_ids[known])
  above <- rep(FALSE, nrow(table_data))
  rows <- which(!is.na(residual) & residual)
  for (row in rows) {
    node <- as.character(table_data$parent_id[row])
    verdict <- NA
    steps <- 0L
    while (is.na(verdict) && !is.na(node) && nzchar(node) &&
           steps <= nrow(table_data)) {
      rank <- unname(rank_by_node[node])
      if (!(node %in% names(rank_by_node))) {
        # No row of this table carries the node; its identifier's own path
        # word, where the source gives one, is all that is left to read.
        verdict <- !grepl("\\|(genus|subgenus|species|subspecies|serotype|variety)/",
                          node)
      } else if (!is.na(rank) && nzchar(rank)) {
        if (rank %in% at_or_below_genus) {
          verdict <- FALSE
        } else if (!identical(rank, "Group")) {
          verdict <- TRUE
        }
      }
      if (is.na(verdict)) {
        parent <- unname(parent_by_node[node])
        if (is.na(parent) || !nzchar(parent)) {
          verdict <- !grepl(
            "\\|(genus|subgenus|species|subspecies|serotype|variety)/", node)
        } else {
          node <- parent
        }
      }
      steps <- steps + 1L
    }
    if (is.na(verdict)) {
      # The chain ran out without a rank: the residual's own identifier
      # repeats its node's path, which settles it where the source gives one.
      verdict <- !grepl("\\|(genus|subgenus|species|subspecies|serotype|variety)/",
                        node_ids[row])
    }
    above[row] <- verdict
  }
  above
}
