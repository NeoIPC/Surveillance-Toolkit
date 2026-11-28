# Production Metadata Migration Runbook

The procedure for moving production from its deployed seed metadata to a released canonical package, closing the
gaps the deployment alone cannot close: the superseded objects it must delete, the collected values that hold option
codes the package renames, and the options no set lists. The deployment mechanics — what an import replaces, which
hazards a dry run reports, how a rule is retired in two deployments — are in
[metadata-deployment.md](metadata-deployment.md); this runbook orders them for the one migration production owes.

## Preconditions

The migration deploys the package of the first `metadata-v` release that incorporates **both** the infectious-agent
list at release `0.2.0-alpha` (the reconciled list) **and** the antibiotics on WHO's AWaRe classification of 2025.
Every earlier package carries either the unreconciled list or the classification of 2021; production deploys exactly
one package, and it is this one. In order:

1. The NeoIPC-Reporting image whose neoipcr **bundles the list release of the package being deployed** is deployed
   **before the metadata**: neoipcr classifies from the release it bundles, not from what DHIS2 has deployed, so the
   image and the package must carry the same list. Were the metadata to move to the reconciled list while the image
   still bundles the old one, the new recordable infectious-agent codes would read to that neoipcr as different,
   higher taxa — it would misclassify every value entered with one — and its join of recorded codes to taxa is an
   inner join, so it would drop the unknown codes from its detection counts silently. Check it in the deployed image:
   the `infectious_agents` element of `neoipcr_supported_versions()` names the list release the bundled
   classification is built from, and must read `0.2.0-alpha`.
2. The migration runs on a DHIS2 release the deployment is verified on — the releases its behaviour was observed on
   are listed in [metadata-deployment.md](metadata-deployment.md) — and it **precedes any upgrade to a line the
   deployed metadata fails on**: from 2.41.9, the deployed seed-lineage forms' rules carry a double-escaped
   `d2:validatePattern` and flat `||` chains that draw E1300 and an HTTP 500 on the `/api/tracker` creates and
   updates of an enrollment with a gestational age or a BSI event that records an infectious agent. That failure
   falls on the bundled Capture app and on every write posted directly through the application programming
   interface (API); the legacy Tracker Capture app's entry and patient removal are unaffected either way. The
   canonical package replaces those rules, so migrating first ends the exposure.
3. The migration completes **before the data cut-off of the December 2026 Reference Report**, so the report's
   antibiotic-utilization table reads the canonical codes; that table drops a recorded value whose code matches no
   option.

## Step 1 — Check the collected codes before anything else

Against the live instance, as the migration's first act, assert that **every distinct value recorded under a data
element or tracked-entity attribute with an option set resolves to a current option of that set** — an anti-join that
fails on any row. Record separately, with counts, the values carrying:

1. the four antibiotic codes the source reconciliation renamed in place: `J01AA08` (Minocycline, now `J01AA08_P`),
   `J01XX01` (Fosfomycin, now `J01XX01_P`), `Cefoselis` (now `tmp_002`) and `Micronomicin` (now `tmp_001`);
2. the five options that no set lists on the instance, which carry their names as codes: `Doxycilin`, `Metacylin`,
   `Piperacillin`, `AEN` and `ACI`.

A value can carry a code of list 1 only if it was entered before the deployment renames its option's code; it
resolves until then, and step 4 rewrites it. A value can carry an option of list 2 only if it was entered while a set
listed the option, which no committed export records, and the anti-join fails on it: **list 2 stops the migration**
until the maintainer has decided each such value — the value is corrected or removed — and the migration proceeds only
once none is left; the five options are then deleted within the migration (step 5.4). Any other unresolved value stops
it the same way. The same anti-join runs again after the data fix of step 4 and must return zero unresolved rows; it
fails loudly on any row, both times.

## Step 2 — Backup and rehearsal

Follow [metadata-deployment.md §6](metadata-deployment.md#6-deploying-to-production): verified database backup, then
a rehearsal on a restore of that backup, on the same DHIS2 version, with the same package and arguments. The
rehearsal exercises the whole window, including the data fix of step 4 and its assertions.

## Step 3 — Deploy, with the delete-list

In the maintenance window, the dry run's plan, hazards and live-only objects decide the arguments:

1. **The retired HAP aggregate rule** `NeoIPC HAP - set pathogen attribute variables` **ships inert in the release
   package** — condition `false`, no actions, under the UID of the deployed rule — exactly as
   [metadata-deployment.md §5](metadata-deployment.md#5-retiring-a-rule) requires: Tracker Capture keeps running a
   rule it has cached after the server deletes it, and the inert write moves the program version so clients reload
   it. The dry run's plan therefore lists the rule as **changed**, not among the objects present only on the
   instance. Its deletion is **not** in this deployment; it goes in the later one of step 6, once clients have
   synchronized.
2. **Other objects present only on the instance** go on `-Delete` per type — those not in a still-generated family,
   and only where the deployment can delete the type: `Deploy-NeoIPCMetadata`'s `-Delete` states the types it
   accepts, and refuses any other before its first write. Objects of a refused type are deleted outside the
   deployment, once nothing refers to them.
3. **`OptionNameChange` hazards** are acknowledged only after each listed option is known to keep its meaning under
   its new name — the comparison is against **the package actually deployed**, code by code, checking that each
   renamed option is the same substance or taxon under its new display name (expect the bracketed concept type, rank
   markers such as "subsp.", spelling, and the nine diagnostic complexes' `[group]` rank where production says
   `[species complex]`), that no option takes a code or name another option of its set holds there, and that the
   package drops no option a production set lists. Also expect the regenerated rules to classify some options
   differently — the BSI form's recognized-pathogen and resistance-category rule actions are regenerated from the
   list — and record, option by option, how a reopened form will read under them.
4. **`OptionCodeChange` hazards** are the four antibiotic codes of step 1; the deployment proceeds knowing step 4's
   data fix follows in the same window, before forms reopen for entry against the renamed options.
5. **The ATC option-group renames and the AWaRe description rewrites carry no hazard line**: the hazard table knows
   renames of *options*, not of option *groups* or group *sets*, so the groups whose names the 2026 ATC/DDD index now
   supplies (`J04AB` "Antibiotics", `P01AB` "Nitroimidazole derivatives") and the three AWaRe groups and the
   `WHO_AWARE` group set with their re-summarized descriptions deploy as ordinary changed writes. Nothing refers to
   them by name — every consumer filters on their codes — and the deployment drops live translations of the changed
   properties, which these strings never had; read the plan's `optionGroups changed` count against the package,
   confirm no other option group on the instance already carries either new name, and read the
   `DroppedTranslations` list against this expectation.

## Step 4 — Rewrite the four antibiotic codes in the collected data

Run as a DHIS2 data fix through the tracker API, separate from the metadata deployment, **after** the metadata write
— the deployment creates none of the four options but renames the codes of the existing ones on their deployed UIDs,
so the new codes exist only once that write is done — and before the maintenance window closes.
For every event value under the substance family — `NEOIPC_SURVEILLANCE_END_AB_SUBST_nn` for each of the nine
substance slots `01` to `09` — still carrying an old code, update it to its new code:

- `J01AA08` → `J01AA08_P` (Minocycline, parenteral);
- `J01XX01` → `J01XX01_P` (Fosfomycin): the recorded fosfomycin values are parenteral, so they move to `J01XX01_P`,
  which keeps their AWaRe category — production's option groups already counted `J01XX01` as Reserve;
- `Cefoselis` → `tmp_002` and `Micronomicin` → `tmp_001`, the codes of substances without a systemic ATC code.

The rewrite is not optional and cannot be deferred past the window: neoipcr and the reports join recorded codes to
options with an inner join, so a value under an old code drops out of every antibiotic table **without a warning**,
under-counting antibiotic exposure at every level. Finish with the anti-join of step 1, at zero unresolved.

## Step 5 — Verify and reopen

1. The deployment summary's verification, and the forms in the data-entry app.
2. A fresh production export equals the to-be directory, modulo the still-generated families.
3. **The deployed HAP definition gains the `NEOIPC_HAP_IT_RATIO` criterion**: the deployed canonical definition is
   ≥4 of 9 criteria, matching the protocol. That is the fix the open bug report on the pneumonia form asks for: close
   that report, and the other data-entry bug reports whose canonical fixes this package carries, each against its own
   deployed state.
4. **Delete the five options no set lists** — `Doxycilin`, `Metacylin`, `Piperacillin`, `AEN` and `ACI` — outside
   any deployment, since the deployment refuses single options in `-Delete`. Step 1's list 2 being empty is the
   precondition: this runs only after the last value that carried one of them has been decided on, and corrected or
   removed.

## Step 6 — Later deployments

1. **Delete the retired HAP aggregate rule** once clients have synchronized: the deployment of a later release, whose
   package no longer carries the rule, lists it in `-Delete` (a deployment refuses an entry its package still
   carries), after it reads inert on the instance (an `ActiveRuleDelete` hazard otherwise). That deployment, having
   deleted a rule, carries the deployment doc's cache-clearing check for Tracker Capture.
2. Re-run the stored-code anti-join after it, still zero unresolved.
