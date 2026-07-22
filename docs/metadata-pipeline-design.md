# Metadata pipeline — design rationale

The **what-it-is-and-why** of the DHIS2 metadata pipeline implemented in the
`scripts/modules/NeoIPC-Tools` PowerShell module. The module README documents the
*architecture* (subsystems, file roles, the forward/reverse data flow, the gettext-PO
component); this note records the **locked design decisions and the reasoning behind
them** — the part that stays true as the code evolves. Read the README first for the map;
read this for the *why*.

Everything here is **pure file processing — no DHIS2 API calls.** The pipeline reads an
out-of-band, PII-cleaned `metadata.json` export from disk and writes files; it never talks
to a server. That is what makes it fully buildable and testable offline.

## 1. The `metadata/` directory is the canonical source of truth

The reviewable, diffable, translatable source of NeoIPC's DHIS2 metadata is the
**`metadata/` directory**, not the importable JSON. The importable package is *generated*
from the directory (plus the infectious-agent ontology and the antibiotic curation CSVs);
the `metadata.json` export is only two things — the **dependency-closure seed** and the
**round-trip oracle** — never a source the build depends on.

Format follows data shape (most-suitable format per object, not CSV-for-everything):

- **CSV** for genuinely flat tabular types. Many-to-many relationships are **normalized
  into junction tables** (one assignment per row) rather than `;`-separated cells — e.g.
  play users as `users.csv` + `userRoleAssignments.csv` + `userOrgUnitAssignments.csv`, and
  group memberships as one `group,member` row each.
- **YAML** where structure is nested or carries multi-line strings (the infectious-agent
  ontology).
- **Named `sharing` profiles** (`metadata/common/sharing.yaml`): only a handful of distinct
  sharing shapes recur, so each is named once and a CSV's `sharing` cell carries just the
  profile key (`PUBLIC_RW`, …), not a JSON blob repeated on hundreds of rows. Grants are
  keyed by user-group **code** (else unique name) for human-editability; the converter
  resolves the handle to a UID and fails loud on an unknown code or shape.
- **Per-expression text files** (one DHIS2 expression per file) for the expression-heavy
  types (program-rule conditions, action data, indicator/validation expressions) — a
  dedicated file gives the author editor support a CSV cell cannot. The CSV cell holds a
  relative file reference.

## 2. UIDs are opaque — real DHIS2 UIDs, stored verbatim, never derived

Every deployed object's production UID lives verbatim in its directory row's `id` column,
and the package imports with `idScheme=UID`. This is forced by verified DHIS2 behaviour
(confirmed against DHIS2's server source, not its docs): the importer has **no UID fallback
for an empty `code`** and **no per-class `idScheme` mixing** (one global scheme per import).
Not every object carries a code — program-rule **actions** deliberately have none (a code folds
into their `hashCode` over an `order-by`-less collection, which can perturb execution order; see
the workspace `docs/dhis2-code-on-first-class-types.md`), the placeholder validation rule has none,
and most DHIS2 built-ins have none. Under `idScheme=CODE` a code-less object is skipped and
re-created with a fresh UID, so `idScheme=CODE` is unsafe regardless of how many objects carry
codes — UID stays the portable identity at import time, and the code is the portable identity for
*matching* (translations, reconcile). Program rules and variables now **do** carry codes (they
moved onto the shared identifiable base), which is what makes the code their stable msgctxt key,
but that does not change the import scheme.

A fresh UID is minted (deterministically, `f(natural key)`) **only** for a genuinely new
authored object that has no production UID yet — the synthetic play accounts and the
eurostat-only org units — and is then stored verbatim like the rest. `-RegenerateUids`
re-mints all UIDs consistently, rewriting every inbound reference (structured **and**
expression-embedded).

Sidecars are the narrow exception: the 3382-option pathogen UID sidecar
(`NeoIPC-Infectious-Agents.uids.csv`) keeps generated option UIDs out of `options.csv`; the
antibiotic option/group/group-set families carry their UIDs in their richer curation CSVs.

Org units and users are **not** real config in the export (it carries only anonymised
instances), so their package content is *authored*: org units reuse the real production UIDs
captured from the export's de-anonymised scaffold for the units that exist live, and mint for
the rest; users mint `f(username)`.

## 3. Two variants from one directory — `production` (default) and `play`

`New-NeoIPCMetadataPackage` emits two variants from the directory **alone**:

- **`production`** (the no-flag default) — config + groups/roles + the generated families,
  with **no org-unit instances and no users** (the install base). An optional `-OverlayPath`
  seeds real org units / users for a fresh deployment, supplied out-of-band and never
  committed.
- **`play`** (`-Play`) — that base plus the committed synthetic test org units / users (one
  test hospital + department per country; no region level).

There is no `-Variant` string and no "testing" variant. The synthetic play password is an
assembly parameter, never committed.

## 4. Reverse path — export → prune → normalize → reconcile

1. **Prune** to the transitive closure seeded at `NEOIPC_CORE`, **client-side**, because
   DHIS2's own dependency export is broken: it follows structured getters but never parses
   expression text, so it silently drops expression-embedded references (verified against
   DHIS2's server source). Stop-types (`users`, `orgUnits`, …) are cut and handled as
   overlays.
2. **Normalize** — strip per-instance noise (`created`/`lastUpdated`/`createdBy`/
   `lastUpdatedBy`/`user`/`href`/`access`/`favorite(s)`; user/group-specific sharing grants;
   the program's `organisationUnits` assignment). The strip-list is defined **once** and used
   by both the cleaner and the semantic-diff comparator, so round-trip equality is "modulo
   normalization", not byte-identity.
3. **Reconcile** — classify each object by code/natural-key as added/changed/removed.
   **CSV-owned** types are auto-written as reviewable minimal diffs (column order + PO
   translations preserved); **YAML-owned, template/ontology-generated, and authored**
   types are **report-only** (the developer edits the source). An unexpected change surfaces
   as `Unclassified` for investigation.

## 5. Expression handling is Node-free

The closure needs no expression parser: NeoIPC's rule expressions reference variables and
attributes **by name** (`#{name}`, `A{name}`), which resolve to program-rule variables /
attributes already in the closure via the structured walk plus reverse-`program` inclusion.
The few genuinely embedded UIDs (~4 `#{uid.uid}` program-indicator forms + 1 `I{uid}`) are
covered by a grammar-complete canonical-UID **safety net** that proves no expression-embedded
reference was dropped.

Expression *quality* is a small NeoIPC-specific linter (PowerShell/regex). A real parser
catches none of NeoIPC's actual issue classes — precedence bugs, `== -1` typos, and the
`d2:hasValue(#{})` legacy argument form all parse and validate clean — so a Node dependency
bought nothing and was designed out.

The pipeline can also rewrite the source to the DHIS2-canonical, forward-safe form
(`-Canonicalize`): chiefly the name-argument d2-functions (`d2:hasValue`/`d2:count`/
`d2:countIfValue`/`d2:countIfZeroPos`/`d2:lastEventDate`), `#{var}`/`A{var}` → `'var'` — the
same rewrite the legacy Tracker Capture client's own `avoidReplacementFunctions` applies,
verified correct for all NeoIPC variable names. This is a deliberate, reviewable *source*
transform, distinct from the faithful round-trip.

## 6. Templating — declarative templates + a per-stage capability matrix

Repeated clusters (pathogen slots, antimicrobial-substance slots) are expanded for
`N = 1..count` (`count` is config: 3 pathogens, 9 substances). Template/ontology-generated
objects are report-only on reconcile. The matrix that drives expansion:

| Stage | Primary pathogens | Secondary BSI | Per-slot primary props |
|-------|-------------------|---------------|------------------------|
| BSI | yes (3) | no | `_NAME` + `_3GCR/_CAR/_COR/_MRSA/_VRE` + `_SOURCE` (`NEOIPC_BSI_PATHOGEN_RECOVERED_FROM`) + `_MULTIPLE` |
| HAP | yes (3) | yes (3) | as BSI minus `_MULTIPLE`; `_SOURCE` = `NEOIPC_HAP_RESPIRATORY_TRACT_SAMPLE_SOURCES` |
| SSI | yes (3) | yes (3) | `_NAME` + 5 resistance only (no `_SOURCE`, no `_MULTIPLE`) |
| NEC | no | yes (3) | — |
| ADM/PRO/END | no | no | — |

- Secondary BSI (`NEOIPC_<STAGE>_SEC_BSI_PATHOGEN_<N>`): `_NAME` + 5 resistance only.
- Antimicrobial substances: `NEOIPC_SURVEILLANCE_END_AB_SUBST_0<N>` + `_DAYS`, N=01..09,
  optionSet `NEOIPC_ANTIMICROBIAL_SUBSTANCES`. Visibility rules are per-slot, organism-driven
  (no "show slot N+1" progression).

The generation **plans** (DE + PRV + rule plans, resistance / common-commensal effective-flag
computation, the per-slot matrix) live in `Private/MetadataGeneration.ps1`; the nine generator
cmdlets are in `Public/Generation.ps1`. The deployed structure the generators reproduce, the
program-rule execution model that constrains their shape, the effective-flag model behind the code
sets, and the correctness gate are documented in
[`metadata-generation-design.md`](metadata-generation-design.md).

## 7. Translations — gettext PO, managed in Weblate

Object i18n lives in a translator-facing gettext PO component (`po/metadata.pot` +
`po/metadata.<lang>.po`), separate from the structural CSV directory. The full design of the
key model, priorities, and the "source = the assembled package, not the directory" rule is in
the README's *Metadata translations* section; the one durable principle worth restating here:
a translation unit is matched by its **context (`msgctxt`)**, so that context must be a
**stable semantic identity** — code-based where a code exists, a DE-code-scheme key for the
generated code-less families, UID only as the last-resort fallback. A volatile context
(e.g. keying a generated rule on its minted UID) orphans the translation in Weblate the moment
the generator is tweaked.

## 8. Diffability is a design goal, not a nicety

A version-controlled metadata source is only useful if a change shows up as a small, readable
diff — otherwise review (human and adversarial) is blind. Two properties are required, and
every emitter must satisfy both:

**Determinism + input-order independence.** Every emitted artifact is reproducibly sorted in a
locale-independent (ordinal) order that is **intrinsic to the data**, never an accident of
upstream iteration order (closure walk, hashtable enumeration, `ConvertTo-Json` member order,
machine locale). Enforced for: per-type CSV row order (natural key), `idArray`/`stringArray`
cell serialization, the `sharing.yaml` profile numbering, the per-expression file tree, and the
PO catalogues. Each emitter has a regression test that feeds **deliberately shuffled** input and
asserts the canonical output order.

**Locality — `O(change)`, not `O(file)`.** A foreseeably-common change must touch one place, not
renumber the file. Two anti-patterns are designed out:

1. **Global renumbering** — a positional/sequential identifier (a `SHARING_NNN` counter) that
   shifts every later entry on insert. Derive keys from **content** instead, so an insert lands
   in its sorted position and touches one place.
2. **Unstable keys** — keying an emitted record on a value that churns under a foreseeable edit.
   The clearest instance, now resolved: the gettext `msgctxt` of a code-less generated rule once
   keyed on the object's minted UID, so a one-line generator tweak re-minted it and reshuffled
   half the catalogue. Those families now key on a stable semantic identity derived from the
   generator plans.

These are established-practice parallels, not bespoke rules: gettext/Weblate matching by
`msgctxt` not position; Terraform's `count`→`for_each` lesson (positional index cascades on
insert, stable string key localises it); RFC 8785 JSON canonicalization (deterministic recursive
key-sort); DHIS2's own `idScheme` treating the code as portable identity; and database 1NF /
keyed structural diff. When adding any new emitter, sort it the same way, key it on stable
content, and add the shuffle-input regression test — do not let a reshuffle pass as "just
determinism".

## 9. Verification gates

- **Diffability (every emitter):** re-emitting from unchanged input is byte-identical
  (idempotent), and output order is independent of input order (the shuffle test).
- **Round-trip:** `ConvertFrom → ConvertTo` semantically equals the cleaned export (modulo the
  strip-list); `pwsh` parse-clean.
- **Closure:** the client-side closure ⊇ DHIS2's (broken) dependency export; the canonical-UID
  safety net logs zero embedded UIDs missing from the structured/name-resolved closure.
- **Expression:** the linter flags the known real issues (precedence / `== -1`); `-Canonicalize`
  rewrites the name-arg d2-functions.
- **Translations:** `translations[]` → PO → `translations[]` is lossless; the `.pot` builds; the
  Weblate component loads.
- **Package:** the generated play package imports into a local DHIS2 (dry-run → import); the
  app's department picker populates; synthetic test users authenticate.

## 10. A note on the package manifest (alpha)

The two rendered packages (install base + play) carry a **minimal** top-level `package`
manifest and are marked **alpha**: they import as-is (DHIS2's importer tree-walks top-level keys
and skips the unrecognised `package` key, verified in source), but they do **not** yet follow the
WHO `dhis2-package-exporter` sharing/manifest conventions. A standards-compliant package — and
the user-group / role / permission model it depends on — is a planned successor. The packages are
not committed: they are rendered on demand by `scripts/Build-NeoIPCMetadataDistribution.ps1` (which
holds the manifest policy and takes the version explicitly) and published as a CI build artifact
and a manually-published Release asset.
