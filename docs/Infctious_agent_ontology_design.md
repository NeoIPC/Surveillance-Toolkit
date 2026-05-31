Below is a **technical design brief** you can paste directly into Copilot/another coding agent.
It captures **requirements → constraints → decisions → final architecture → data model → algorithms → usage patterns** clearly and implementation-ready.

No screenshots are needed here since this is purely structural/data-engineering content.

---

# NeoIPC Taxonomy Handling — Technical Design Summary

## Context

We have a **large hierarchical YAML taxonomy** of infectious agents (NeoIPC + ICTV).

It contains:

* mixed biological domains (viruses, bacteria, eukaryota, etc.)
* heterogeneous taxonomic depths
* inconsistent ranks
* some nodes with NeoIPC `Id`
* many parent nodes without `Id`
* synonyms that also have their own `Id`

Example structure:

```yaml
Name
ConceptType
ConceptId
ConceptSource
Id (optional)
Children
Synonyms
```

---

## Practical use case (surveillance workflow)

We use this taxonomy in NeoIPC/NEO-KISS surveillance.

Characteristics:

* actual datasets only reference **5–100 taxa**
* referenced by **Id (local_id)** only
* we frequently need:

  * the taxon metadata
  * all ancestors (family/order/etc)
  * grouping by lineage
  * optional suppression of ranks in reports
  * synonym Id resolution
* we work mainly with **tidyverse/dplyr**
* repeated analyses → performance matters

---

# Key constraints discovered

## 1. ConceptId is NOT globally unique

Only unique together with ConceptSource.

So cannot be used as primary key.

---

## 2. Id is globally unique but incomplete

* present for taxa and synonyms
* **missing for many parents**

So cannot be used as graph key.

---

## 3. Taxonomy ranks are inconsistent

Examples:

* viruses use Realm/Kingdom/Phylum/…
* bacteria use Domain/Phylum/Class/…
* some contain “species group”
* depths vary
* some ranks missing

Therefore:

❌ fixed columns (kingdom/phylum/…) impossible
✅ must use graph model

---

# Design decisions

## Core modeling principle

Treat taxonomy as:

> a directed acyclic graph (tree), not a fixed-rank table

Store:

* nodes
* parent relationships
* ranks only as metadata

Never encode rank structure.

---

# Final architecture (recommended)

We use **3 relational tables**.

---

## 1. concepts  (node dictionary)

### Purpose

Store full tree structure.

### Primary key

synthetic integer `node_id`

### Why synthetic?

Because:

* Id missing on some nodes
* ConceptId not globally unique
* composite keys slow
* integers fastest

### Schema

```r
concepts
---------
node_id (PK, int)
parent_node_id (int, nullable)
id (NeoIPC Id, nullable)
name (chr)
type (ConceptType, chr)
source (ConceptSource)
concept_id (ConceptId)
ictv_id (optional)
```

Notes:

* keep ALL nodes (even those without Id)
* ensures lineage integrity

---

## 2. closure  (ancestor table)

### Purpose

Fast lineage queries without recursion.

### Schema

```r
closure
---------
child (node_id)
ancestor (node_id)
depth (int)
```

Includes:

* self (depth 0)
* parent (1)
* grandparent (2)
* …

### Benefit

Lineage lookup becomes one join:

```r
closure %>% filter(child == node)
```

instead of recursion.

---

## 3. id_map  (lookup table)

### Purpose

Map anything user enters → canonical node.

Includes:

* taxon Ids
* synonym Ids

### Schema

```r
id_map
---------
input_id
node_id
```

Usage:

```r
node <- id_map |> filter(input_id == x) |> pull(node_id)
```

---

# Why this architecture

## Correctness

✔ keeps full lineage
✔ works even if parents lack Id
✔ supports synonyms

## Performance

✔ integer joins only
✔ no recursion
✔ closure precomputed once

## Memory

✔ only few thousand nodes max
✔ closure small

## Flexibility

✔ works with any taxonomy depth
✔ works across viruses/bacteria/eukaryota
✔ supports irregular ranks

---

# Algorithms

## Flatten YAML → concepts

Recursive traversal:

For each node:

* create new synthetic node_id
* store parent_node_id
* copy metadata
* recurse children

---

## Build closure table

Iterative parent expansion:

```
start: child → self
repeat:
  join parents
  add next ancestor
until no change
```

Standard transitive closure.

---

## Build id_map

Two sources:

### taxon ids

```
concepts where id not NA
```

### synonyms

map each synonym Id to same node

Combine both.

---

# Typical workflows

## Resolve user input

```r
node <- id_map$node_id[match(input_id, id_map$input_id)]
```

---

## Get full lineage

```r
closure %>%
  filter(child == node) %>%
  left_join(concepts, by = c("ancestor" = "node_id"))
```

---

## Group by family

```r
closure %>%
  left_join(concepts, by = c("ancestor" = "node_id")) %>%
  filter(type == "Family")
```

---

## Attach lineage columns to surveillance table

```r
attach_ranks(df, tax, ranks = c("Family","Genus","Species"))
```

Pivot lineage into wide format.

---

# Handling heterogeneous taxonomy levels

Important:

We **do NOT** encode ranks structurally.

Instead:

```
type column = metadata
```

So:

* Realm/Kingdom/Family/Species group/etc
* are just strings

Filtering decides what to show.

This avoids:

* fixed schemas
* broken joins
* brittle assumptions

---

# Reporting strategy

## Rank projection (recommended)

At reporting time:

### Option A — whitelist

```
Family, Genus, Species
```

### Option B — fallback preference

```
Species → Species group → Genus → Family
```

### Option C — custom rules

suppress certain ranks

All implemented by filtering lineage rows.

No taxonomy changes needed.

---

# Memory optimization notes

Possible but optional:

* could drop nodes not ancestral to any Id
* probably unnecessary (tree small enough)

Prefer simplicity.

---

# Final implementation target

Copilot/agent should implement:

## Function

```
build_taxonomy(path)
```

Returns:

```
list(
  concepts,
  closure,
  id_map
)
```

## Helpers

```
resolve_node(id, tax)
attach_ranks(df, tax, ranks)
get_lineage(node, tax)
```

---

# Key principles for the coding agent

1. never rely on fixed taxonomic levels
2. always use synthetic node_id internally
3. use closure table for lineage
4. treat Id only as external lookup
5. avoid recursion during queries
6. tidyverse-friendly tables only

---

# Conceptual summary

This is essentially:

> a small ontology / vocabulary system (like SNOMED or OMOP) specialized for NeoIPC

Graph + closure + lookup.

---

If you feed this brief into Copilot or another coding agent, it should be able to implement the full solution cleanly and efficiently without redesign iterations.
