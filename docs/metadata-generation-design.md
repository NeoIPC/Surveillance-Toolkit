# Metadata generation — design reference

The **generation subsystem** of the DHIS2 metadata pipeline: how the repeated, declaratively
sourced machinery of the `NEOIPC_CORE` program — the pathogen option set, the per-slot pathogen
data elements / program-rule variables / rules, the resistance-category gating, the per-slot
field-gating, and the antimicrobial-substance cluster — is **generated** from the infectious-agent
ontology plus a per-stage capability matrix, rather than hand-authored.

Read [`metadata-pipeline-design.md`](metadata-pipeline-design.md) first for the pipeline's locked
decisions (the `metadata/` directory as source of truth, opaque UIDs, the two package variants, the
reverse path, Node-free expressions, diffability). This note is the **generation-specific** depth:
the deployed structure the generators reproduce, the program-rule execution model that constrains
their shape, the effective-flag model that drives the code sets, and the correctness gate. The
generators live in [`Public/Generation.ps1`](../scripts/modules/NeoIPC-Tools/Public/Generation.ps1)
(nine cmdlets) over plans in
[`Private/MetadataGeneration.ps1`](../scripts/modules/NeoIPC-Tools/Private/MetadataGeneration.ps1),
spliced into the package by `Add-NeoIPCGeneratedMetadata` in
[`Private/MetadataAssembly.ps1`](../scripts/modules/NeoIPC-Tools/Private/MetadataAssembly.ps1).

Everything here is **pure file/object processing — no DHIS2 API calls.** The analysis behind it is
read-only against the on-disk, PII-cleaned `metadata.json` export (the round-trip oracle and the
UID-preservation source) and the canonical ontology
`metadata/common/infectious-agents/NeoIPC-Infectious-Agents.yaml`.

## Posture: generate for correctness, don't reproduce the deployed rules

The deployed program rules are a **flawed human baseline**, not a gold standard: built under time
pressure with steadily-growing DHIS2 knowledge, they are inconsistent, partially buggy, overlapping,
and trimmed to "works most of the time in production". The generation target is therefore
**correctness from the authoritative sources** — the ontology + capability matrix for the generated
classes, the normative protocol for the definition class — and the deployed rules are a **diff
baseline for a classified review**, not a template to copy. A large, fully-classified diff against
the deployed metadata is the expected, healthy outcome.

This sets a boundary between what generation may fix unilaterally and what needs sign-off:

- **Generated classes (resistance gating, field gating, substance cluster)** — mechanical and
  structural. The generator makes them correct and consistent **by construction**: it drops dead and
  overlapping rules, emits uniform explicit priorities, holds the *mandatory ⟹ shown* invariant, and
  disentangles the rules that conflate resistance gating with definition gating. These improvements
  are the generator's to make.
- **Definition class (the infection case definitions)** — normative and clinician-owned. Divergences
  are surfaced by a separate audit and **proposed**, never changed by the generator. Per the
  repository guardrail, when a rule conflicts with a definition, fix the rule, not the definition.

### The corrected ontology intentionally diverges from the deployed rules and the protocol

The ontology's resistance flags have been deliberately corrected (e.g. *Vibrionaceae* → 3GCR +
carbapenem on, colistin off; *Stutzerimonas* → all three on; *Stenotrophomonas* confirmed unflagged).
The currently-deployed DHIS2 rules **and** the published protocol pathogen list predate these
corrections and are therefore outdated. The ontology is the source of truth; the deployed rules and
the protocol are **regenerated / re-rendered from it**, never the reverse. A diff against the
deployed `metadata.json` is expected, not a regression. (The flag normalization — nearest-wins
inheritance with `false` overrides — is its own workstream; see the *Generation model* section.)

## The capability matrix the generators expand over

Generation is count-driven over the per-stage pathogen/substance capability matrix (canonical copy in
[`metadata-pipeline-design.md`](metadata-pipeline-design.md) §6). In summary: primary pathogen slots
on BSI / HAP / SSI; secondary-BSI pathogen slots on HAP / NEC / SSI — **18 pathogen slots** total;
antimicrobial-substance slots on Surveillance-End. Per-slot property sets differ by stage (`_SOURCE`
and `_MULTIPLE` are BSI-primary extras; secondary-BSI slots carry `_NAME` + the five resistance DEs
only). The slot counts are single knobs:

- **Pathogen slots** — `-PathogenCount`, `[ValidateRange(1, 9)]`, default 3 (module-wide
  `$script:NeoIPCPathogenSlotCount`). Capped at 9 so slot codes stay single-digit unpadded
  (`NEOIPC_BSI_PATHOGEN_1..9`) and the deployed `_1` codes never gain a leading zero.
- **Substance slots** — `-SubstanceCount`, `[ValidateRange(1, 99)]`, emitting two-digit zero-padded
  codes (`NEOIPC_SURVEILLANCE_END_AB_SUBST_01..99`), matching the deployed `_0N` form.

The two clusters are deliberately asymmetric on padding: substances pad (fixing the lexical
mis-ordering where `substance 10` sorts before `substance 2`); pathogens do not. neoipcr's
event-data reader parses these codes — the substance index is read as a full two-digit group
(`_(\d\d)`), the pathogen index as a multi-digit group (`PATHOGEN_(\d+)`).

## Verified deployed structure (the generation target)

Read from the export; the exact object shapes the generators emit.

### Option set and the value variable

- **Option set `NEOIPC_PATHOGENS`** (name "NeoIPC Pathogen options") — one option per `Id`-bearing
  ontology node; each option's **code is the integer `Id`**. The per-slot organism DE
  (`NEOIPC_<STAGE>_[SEC_BSI_]PATHOGEN_<N>`) binds this option set.
- **Program-rule variable `NeoIPC <slot> value`** — `DATAELEMENT_CURRENT_EVENT`, reads the slot's
  organism DE with `useCodeForOptionSet = true`, so its value is the **option code** (integer). All
  resistance logic compares against these codes.

### Resistance-category gating — the three-rule producer/consumer triple

Per slot, per resistance category (3GCR / carbapenem-resistant / colistin-resistant / MRSA / VRE),
three rules — **270 rules / 270 actions** at the deployed 18 slots × 5 categories:

- **`<slot> - set <CAT>`** — condition `true`, **priority 0**, one **ASSIGN** action whose `content`
  is the target handle `#{<slot> may be <CAT>}` and whose `data` is the enumerated expression
  `d2:hasValue(#{<slot> value})&&(#{<slot> value}==c1||…||==cN)` — the category's effective organism
  code set in **ascending numeric** order, operator-space-free.
- **`<slot> - may be <CAT>`** — condition `#{<slot> may be <CAT>}`, **priority 1**, a
  **SETMANDATORYFIELD** action on the `_<CAT>` resistance DE.
- **`<slot> - not <CAT>`** — condition `!#{<slot> may be <CAT>}` (the **exact complement**, so a field
  is never hidden-and-mandatory), **priority 1**, a **HIDEFIELD** action on the same `_<CAT>` DE.

Field-level object shapes (the exact form emitted):

- **Rule:** `{ id, name, description, program:{id}, programStage:{id}, condition, priority,
  programRuleActions:[{id}] }`. The `programStage` is carried on the **rule**, not its actions.
- **ASSIGN action:** `{ id, programRule:{id}, programRuleActionType:"ASSIGN", content, data }` — the
  **target** variable is the `content` handle, the **expression** is `data`; there is **no**
  `dataElement` on an ASSIGN.
- **SETMANDATORYFIELD / HIDEFIELD action:** `{ id, programRule:{id}, programRuleActionType, dataElement:{id} }`
  — targets the `_<CAT>` DE only (resolved by code); no `content`, no `programStage`.

Program stages carry no `code`, so a rule's stage is resolved through `programStageDataElements` via a
slot-1 `_3GCR` resistance DE known to live on that stage (so rules for grown slots resolve too). UID
policy follows the pipeline: a rule preserves its UID + description from the export **by name** where
present, else mints deterministically (`programRules` natural key = name); an action has no name, so
it preserves the UID of its owning deployed rule's same-type action, else mints from
`<rule name>|<actionType>`. Every resolution is **fail-loud**: a missing program / stage / resistance
DE, an empty category code set, or a duplicate minted UID throws.

### Field-gating — five per-slot kinds

The non-resistance per-slot gating, all on the slot's own stage:

- **`<slot> - set recognized pathogen`** (BSI primary only) — condition `true`, priority 0, an ASSIGN
  setting the slot's `is recognized pathogen` boolean to
  `d2:hasValue(#{<slot> value}) && !(#{<slot> value}==c1||…)` — the **common-commensal code set
  NEGATED** (not "all non-commensals enumerated"). The `is recognized pathogen` CALCULATED_VALUE
  BOOLEAN PRV is generated alongside (consumed by downstream BSI-definition rules).
- **`<slot> - when set`** (BSI primary only) — condition `d2:hasValue(#{<slot> value})`, one
  SETMANDATORYFIELD on `_SOURCE` (only — not `_MULTIPLE`). The deployed slot-1 also HIDEFIELDs
  `NEOIPC_BSI_NO_POS_CULTURE`, which is a BSI-definition business action, not part of the repeated
  cluster, and is left to the business-rule layer (salvaged onto the regenerated rule by the
  assembler rather than re-homed).
- **`<slot> - when empty`** (slots with downstream slots and/or own `_SOURCE`/`_MULTIPLE`) —
  condition `!d2:hasValue(#{<slot> value})`, HIDEFIELD over the slot's own `_SOURCE`/`_MULTIPLE`
  extras **plus every field of the downstream slots** (`_value` + `_NAME` + the five resistance DEs;
  not downstream `_SOURCE`/`_MULTIPLE`, which each downstream slot's own `when empty` hides). **This
  is the progressive reveal.** It reproduces the clean deployed BSI rules and normalizes the deployed
  HAP/SSI inconsistencies — including adding the `when empty` rule the deployed metadata omits on
  SSI-secondary slot 2.
- **`<slot> - when empty or listed`** (all slots with a `_NAME` free-text DE) — condition
  `!d2:hasValue(#{<slot> value}) || #{<slot> value} != 0`, a HIDEFIELD on `_NAME` (hide the free-text
  name unless code `0` = "Not listed").
- **`<slot> - when not listed`** (same slots) — condition `d2:hasValue(#{<slot> value}) && #{<slot> value} == 0`,
  a SETMANDATORYFIELD on `_NAME`. The `d2:hasValue` guard (the exact complement of *when empty or
  listed*) **corrects a latent production over-requirement**: the vendored Tracker Capture engine
  evaluates an empty integer DE as `0`, so the deployed unguarded `== 0` makes `_NAME` mandatory even
  on an empty slot.

So *when empty or listed* + *when not listed* are the `_NAME` free-text **gating pair** — the mirror
of the resistance `may be`/`not`, gated on code `0` rather than a `may be` boolean. Generation couples
to two sources: the ontology common-commensal flag (recognized-pathogen) and the per-slot
downstream-field set (when-empty). Coverage is **domain-correct, not uniform**: `set recognized
pathogen` / `when set` are BSI-primary by design (the recognized-pathogen / no-positive-culture logic
is BSI-specific); `when empty` covers only the slots that actually have downstream fields to hide.

### Antimicrobial-substance cluster

On the Surveillance-End stage, read from the export. Unlike the resistance triple, the substance
rules have **no ASSIGN / calculated-variable indirection** — they read the slot's
`… - current event value` PRV directly. Everything substance-related is two-digit zero-padded
(`01..99`): the codes, the DE/PRV/rule `name` fields, the DE `shortName`, and the variable references
inside rule conditions — but **not** the `formName` (the data-entry label stays readable as
`Antibiotic substance 1`; field order is set by explicit `sortOrder`, not the label).

- **Data elements** (2 per slot): substance `…_AB_SUBST_0N` (valueType TEXT, optionSet **and**
  commentOptionSet = `NEOIPC_ANTIMICROBIAL_SUBSTANCES`); days `…_0N_DAYS` (INTEGER_POSITIVE,
  zeroIsSignificant true). The total `…_AB_DAYS` is a regular Surveillance-End field — referenced by
  name in conditions, not generated.
- **Program-rule variables** (2 per slot): the substance and days `… - current event value` PRVs.
- **Rules:** `substance N - hide` (two HIDEFIELDs — the substance DE and the days DE; cascading
  reveal: slot N hidden until slot N-1 has a value, slot 1 until total AB days > 0);
  `substance N days - require` (SETMANDATORYFIELD on the days DE); `substance 1 - require` (slot 1
  only); and one non-per-slot `substance days - validate` (SHOWERROR when the sum of substance-days
  exceeds the recorded total AB days).

Two structural notes the generator honours: action UID preservation matches by **(action type +
target DE)**, not type alone (the hide rule has two HIDEFIELDs on different DEs); and slots beyond the
deployed 9 have no deployed DE/UID, so the substance DE generator **mints** them (copying
categoryCombo + optionSet + commentOptionSet from the slot-1 sibling) rather than failing loud — this
is the "grow the program" capability, distinct from the pathogen DE generator's reuse-or-fail.

## Program-rule execution model (the constraints on rule shape)

Verified against the **two** engines that matter: the vendored AngularJS Tracker-Capture engine the
2.40 deployment runs in the browser (the `d2-tracker/dhis2.angular.services.js` engine bundled in
DHIS2's `tracker-capture-app` v40 — the app has no `@dhis2/rule-engine` dependency, so this, not the
modern engine, is what users hit) and the modern engine (DHIS2's `rule-engine` 3.8.1, used by the 2.41
server and modern Capture, delegating to the `expression-parser` library). Both agree on every point.
(When working in the neoipc-workspace these upstreams are checked out under `refs/`; a standalone
Surveillance-Toolkit clone identifies them by project + version above.)

- **Single ordered pass, no fixpoint.** Each evaluation runs the rules once in order; re-evaluation on
  a field edit is driven by the host app, not an internal convergence loop.
- **Ordering = `priority` ascending; null/unset priority sorts LAST.** Priority is the only ordering
  lever; ties fall back to fragile serialization order → the generator emits **explicit** priorities,
  never relying on null-means-last.
- **ASSIGN propagation is forward-only** through a shared mutable variable map: a rule that ASSIGNs a
  variable consumed by another must have a strictly lower priority. Hence `set <CAT>` (priority 0,
  ASSIGNing the `may be <CAT>` boolean) **must** run before `may be`/`not <CAT>` (priority 1, which
  read it). This priority-0-before-1 split is load-bearing.
- **Visibility is hide-only.** There is **no `SHOWFIELD` action** in either engine; fields are visible
  by default and hidden only by an in-effect `HIDEFIELD`, which also **blanks** the field's value.
- **`hiddenFields` and `mandatoryFields` are independent maps** — hiding a field does not clear its
  mandatory flag, so a field can be hidden *and* mandatory = blank-but-required = unsubmittable.
  **Generator invariant:** for every (slot, category) the mandatory condition must imply the shown
  condition. The `may be`/`not` pair satisfies this because the conditions are exact complements.
- **`programrule.rulecondition` is `type="text"`** (unbounded) — a long enumeration is as safe in a
  `condition` as in an action `data` field.

**Redesign hypotheses, tested against the engine source:**

| # | Hypothesis | Verdict |
|---|------------|---------|
| H1 | Drop the priority-0 `set` ASSIGN + the `may be` calculated variable; inline the enumeration into the two consumer conditions (`SETMANDATORYFIELD` on the enum, `HIDEFIELD` on its exact complement). | **Feasible** — behaviourally identical *iff* the hide condition is the full-expression complement (a De-Morgan variant silently breaks the empty-slot case; safe only when generated from one source list). Saves ~90 rules + 90 variables and removes the intra-pass ordering dependency. |
| H2 | Make `_CAT` fields hidden-by-default and drop `not <CAT>`, leaving one `SHOWFIELD + SETMANDATORYFIELD` rule. | **Impossible** — neither engine has hidden-by-default or `SHOWFIELD`; the field would stay permanently visible and the action be silently ignored. Off the table. |
| H3 | The priority-0-before-1 ordering between `set` and its consumers is load-bearing. | **Confirmed.** |

**Decided shape — the deployed three-rule producer/consumer triple** (not the H1 two-rule form).
Rationale: it keeps the inspectable `may be <CAT>` boolean, the enumeration appears **once** per cell
(90 copies, not 180), and it is the smallest diff from the deployed rules (the easier validation
gate). The H1 saving is real but not worth losing the named boolean handle and the minimal-diff
property. Explicit priorities are emitted either way.

## Generation model — effective flags drive the code sets

A category's organism code set = **every `Id`-bearing ontology node whose *effective* flag is true.**
The effective flag is the **nearest explicit value on the node→root path** (the node itself, else its
closest ancestor): `<CAT>: true` flags it, `<CAT>: false` **overrides** an inherited `true`, and
absence inherits; the default is false. (This nearest-wins-with-override model — option B — is being
normalized so flags live at the highest applicable level with `false` exceptions, a separate
workstream.) The flag→category mapping: `3GCR`→3GCR, `MRSA`→MRSA, `VRE`→VRE,
`Carbapenems`→carbapenem-resistant, `Colistin`→colistin-resistant. The common-commensal set
(`CommonCommensal` flag) drives the recognized-pathogen gating by the same effective-flag rule.

A resistance flag means *"ask about **acquired** `<CAT>` resistance"* — intrinsically-resistant
organisms are deliberately left unflagged (e.g. *Proteus*: 3GCR + carbapenem but not colistin). So a
generated code set differs from the deployed snapshot only by **signed-off taxonomic
reclassification**: a prior organism name retained as a synonym under a new genus inherits the new
genus's flags, which may add or remove a category. The three clades that moved, with the surrogate
breakpoint each implies (a new ontology schema, tracked separately):

| Concept (retained synonyms) | 3GCR | carbapenem | colistin | vs deployed | Surrogate breakpoint |
|-----------------------------|:----:|:----------:|:--------:|-------------|----------------------|
| *Stutzerimonas stutzeri* (syn. *P. stutzeri / perfectomarina / chloritidismutans*) | flag | flag | flag | unchanged — removal reverted | CLSI M45 "*Pseudomonas* other than *P. aeruginosa*" |
| *Stenotrophomonas beteli* (syn. *P. beteli / betle*) | no | no | no | removal confirmed (intrinsic L1 MBL → uninformative) | CLSI M45 / EUCAST *S. maltophilia* |
| *Photobacterium damselae* (syn. *Vibrio damsela / damselae*) | flag | flag | no | loses colistin, gains 3GCR + carbapenem | CLSI M45 *Vibrio* |

The flag edits are placed at the **highest node where relevance is conserved**: *Vibrionaceae* family
→ 3GCR + carbapenem (colistin off family-wide, which both gives *Photobacterium damselae* its β-lactam
markers by inheritance and resolves the *Vibrio*-genus colistin question); *Stutzerimonas* genus → all
three; *Stenotrophomonas* left unflagged. Because the ontology is the source, the fix for any
clinically-wrong removal is to set the flag on the genus node in the **YAML**, never to special-case
the generator. The naming, authority, and never-drop-a-synonym policy that makes these *flag-propagation*
questions rather than data-loss ones is codified in this repository's `CLAUDE.md` (LPSN/LoRN for
bacteria, MycoBank for fungi, ICTV for viruses, NHSN for common-commensal status; a renamed organism's
`Id` follows the name as it becomes a synonym).

## Full program-rule machinery census

A complete classification of all **497** `NEOIPC_CORE` program rules / **778** actions (reconciles
exactly, 0 unaccounted) — the scoping that precedes the build. Four classes:

| Class | Rules | Disposition |
|-------|------:|-------------|
| Resistance-gating | 276 | **generate** (135 primary-slot + 135 secondary-BSI-slot `set`/`may be`/`not`, plus 6 HAP-specific aggregate rules) |
| Substance-cluster | 19 | **generate** (9 hide + 9 days-require + 1 substance-1-require, cascading reveal) |
| Form-support (field-gating + name-has-value notifications) | 76 | **generate** the per-slot field-gating; the 18 `name has value` SENDMESSAGE notifications are a separate set |
| Infection-definition business-rules | 126 | **audit** against the protocol (a separate task; the load-bearing, non-mechanical class) |

**HAP is structurally different** — not the clean per-slot pattern. It centralizes resistance/virus
attribute computation in 6 aggregate rules: `NeoIPC HAP - set pathogen attribute variables` (15 ASSIGN
— the **stale duplicate**, dropped) plus `set virus` and the virus-detected / lower-respiratory
inference rules (which feed the HAP pneumonia microbiology criterion and are **not** dead). HAP
pathogen-slot rules also bundle resistance SET/HIDE actions into the same rule as name/definition
gating; generation disentangles them (emit the resistance triple as its own rules, leave the
definition gating to the business-rule layer).

## What the generator produces, and how it's validated

The nine cmdlets emit, from the ontology + capability matrix + counts: the `NEOIPC_PATHOGENS` option
set + options (code = `Id`, names per the authority policy, with the generated option UIDs kept in the
`NeoIPC-Infectious-Agents.uids.csv` sidecar, not `options.csv`); the per-slot pathogen DEs; the
`<slot> value` + `may be <CAT>` + `is recognized pathogen` PRVs; the resistance triple and the
field-gating rules per slot; and the substance cluster. The stale HAP aggregate is never emitted. UID
handling, the per-expression file layout for the long `set <CAT>` expressions, the deterministic
output ordering, and the report-only reconcile behaviour for generated content all follow the pipeline
decisions in [`metadata-pipeline-design.md`](metadata-pipeline-design.md) (§1, §2, §4, §8).

The deployed program is a **baseline to diff against, not a target to match**, so the gate is not
pass/fail equality but **correctness-by-construction plus a two-directional classified diff**:

- **Correct by construction:** each category's generated code set equals the YAML-effective set; slot
  uniformity holds (every slot of a category gets the identical set — the property the deployed
  colistin rules violate); the stale aggregate is absent; the *mandatory ⟹ shown* invariant holds for
  every (slot, category); explicit priorities are emitted; the closure / round-trip gates still pass
  with the generated objects in place.
- **Classified diff vs deployed (nothing silent):** every generated-not-deployed rule is classified
  *taxonomic* (signed-off reclassification) or *deliberate improvement*; every deployed-not-generated
  rule is classified *dead/debug/experiment*, *duplicate/superseded*, or *business-retained*. Any
  **unclassified** delta in either direction is the failure. A large, fully-classified diff is the
  healthy outcome.

## Authored codes on the generated families

Every generated program rule and variable carries an authored `code` (program-rule *actions* stay
code-less by decision — see the workspace `docs/dhis2-code-on-first-class-types.md`). One function mints
it, so the generator and the translation-key index cannot drift: `Get-NeoIPCGeneratedCode` maps a
data-element-scheme semantic key (`NEOIPC_BSI_PATHOGEN_1_SET_3GCR`) to the code by applying the NeoIPC
rule/variable vocabulary, and `Get-NeoIPCGeneratedObjectCode` derives that key from a plan descriptor +
family. Because `code` outranks the UID in the msgctxt (`Get-NeoIPCMetadataTranslationKey`), **an object's
code and its gettext msgctxt are the same string** by construction.

The vocabulary — data elements keep their deployed tokens, while rule/variable/config codes lead with the
target vocabulary (the two converge when the planned name/data-element migration lands):

| Token | → | Rationale |
|---|---|---|
| `PATHOGEN`, `ORGANISM(S)` | `AGENT(S)` | infectious agent — a recovered common commensal is not a pathogen, a virus is not an organism |
| `RECOGNIZED` (recognized pathogen) | `NCC` | non-common commensal |
| `SURVEILLANCE_END` → `SURV_END`; `ADMISSION` → `ADM` | stage tokens (stage codes `NEOIPC_STG_SURV_END`, `NEOIPC_STG_ADM`) | |
| `WHEN_EMPTY_OR_LISTED` / `WHEN_NOT_LISTED` / `WHEN_EMPTY` / `WHEN_SET` | `IF_EMPTY_LISTED` / `IF_NOT_LISTED` / `IF_EMPTY` / `IF_SET` | field-gating role compaction |
| `VALUE` (value-accessor role) | `VAL` | covers `_VALUE` and `_DAYS_VALUE` |
| `DAYS_VALIDATE` | `DAYS_VR` | the substance-days validation rule takes the `_VR` marker |

The generated codes stay ≤50 characters at the maximum slot counts (9 pathogen, 99 substance); the
`Get-NeoIPCGeneratedObjectCode` whole-surface test guards the DHIS2 50-char cap and per-type uniqueness
across the entire minted surface.

Program stages carry a `NEOIPC_STG_<token>` code, so each rule generator resolves its stage directly by
code (`Get-NeoIPCStageIdByToken`) rather than by which stage owns a slot-1 resistance / AB-days data
element.

## Defect catalog (what generation drops or fixes)

Generated-class defects fixed **by construction**:

- The stale HAP aggregate `… - set pathogen attribute variables` (15 dead ASSIGN duplicating the
  per-slot `set` rules; the colistin issue [#22](https://github.com/NeoIPC/Surveillance-Toolkit/issues/22) /
  [#23](https://github.com/NeoIPC/Surveillance-Toolkit/issues/23) residue) — not emitted, which also
  resolves the colistin slot non-uniformity (deployed 324 vs 328) it caused.
- `when empty` priority drift (6×0 / 7×null, no functional reason) — uniform explicit priorities.
- HAP rules intermixing resistance SET/HIDE with name/definition gating — disentangled.
- A double-space name typo in all 15 HAP-Secondary-BSI resistance DEs (deployed
  `NeoIPC HAP Secondary BSI organism N  <CAT>`) — emitted single-spaced; the classified diff flags
  exactly those 15.

Dead / dormant / failed-experiment leftovers (identified and dropped, never regenerated):

- `NeoIPC BSI Debug rule` — condition literally `false`, 22 `DISPLAYKEYVALUEPAIR` actions: a dormant
  debugging widget.
- The stale HAP aggregate above. A sweep for dormant (`condition` provably never-true),
  unreachable/orphaned, and debug/experiment rules is part of reconcile for the non-generated classes;
  the generated classes drop them simply by not emitting them — each drop classified in the diff.

Cross-cutting issues the expression linter flags (these parse clean, so only a NeoIPC-specific linter
catches them):

- Gestation-warn rule precedence bug (`b3CR62JDGHW`, `MixedBooleanPrecedence`); the gestational-age
  plausibility warning's `>=310` arm fires unconditionally of the `!=0` guard.
- SSI `== -1` sentinel comparison, likely a `!= 1` typo (`sc6VLWeyY4U`, `NegativeSentinelComparison`).

Definition-class hazards (surfaced for the audit, PI-decided — not generator-fixed): the BSI
`Antibiotic treatment` cross-rule hidden-mandatory hazard (DE `NjFq3pakY2I`); SSI organism-id value
semantics (`1`=identified / `-1`=not-cultured / `0`=not-listed).
