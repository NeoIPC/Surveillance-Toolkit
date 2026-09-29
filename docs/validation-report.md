# The Validation Report

The Validation Report lists the records of a department's NeoIPC surveillance data that a validation
rule flags, so the department's data manager can correct them. It is rendered from
`reports/Validation-Report/` by Quarto through `scripts/Build-ValidationReport.ps1`; the
`_quarto-minimal.yml` profile is for a host that embeds the HTML body as a fragment in a page of its own.

## Two layers

The rules and the sentences live in different places, on purpose.

- **neoipcr computes.** `neoipcr::validate()` runs the rules and returns one row per finding: the rule
  id, the keys of the record it concerns at each level (`patient_key`, `enrollment_key`, `event_key`,
  `NA` where there is none; the level a rule is recorded and exempted on is the one `?validate` names,
  and an enrolment-level rule that compared a form names that form's event, which is how a finding is
  filed under the form) and a `context` column holding a one-row tibble of the values the rule compared.
  A finding is never prose. The rule ids the package knows are `neoipcr::validation_rule_ids()`.
- **The report renders.** `content/_sR.yaml` holds, per rule id under `problems`, the `description`
  template a finding is rendered with and a placeholder-free `summary` of what the rule checks;
  `_problem_text.qmd` interpolates a finding's context into its template; `_problems.qmd` joins the keys
  back to patients, enrolments and events and lays the findings out per site, department, patient,
  enrolment and event; `_mapping.qmd` says which explanation and which solutions the report includes for
  each rule that fired.

The link between the layers is the **context field names**: the placeholders of a template are the
column names of the rule's context, exactly as the "Context fields" section of `?neoipcr::validate`
lists them, plus the labels `context_decorations` in `_mapping.qmd` adds for the coded values a
sentence shows. That section is the contract; this report does not restate it.

## Rendering a finding

One function renders every rule (`problem_text()` in `_problem_text.qmd`):

1. `fall_back_context()` first replaces a missing field by another field the rule records, where
   `context_fallbacks` in `_mapping.qmd` pairs the two: rules 52 to 54 record a substance both as the
   name the form shows and as the code it stores, and a code the option set does not carry has no
   name, so the sentence shows the code. The setup refuses a pair naming a field the rule does not
   record. Then `format_context()` turns the one-row context into named character scalars — dates in the locale's
   date format, factors and numbers as text, a missing value as the report's `missing_value` string,
   worded to sit inside a sentence — so `interpolate_translation()` never receives a zero-length or
   unnamed value, which it refuses. Every value is escaped for Markdown at this boundary
   (`escape_markdown()` in `reports/common/helpers.R`, which first collapses runs of whitespace, line
   breaks included, to one space, since a value is a phrase and a line break would end the heading or
   link it sits in), so a free-text pathogen name or a procedure description renders as typed rather
   than as emphasis, a link or HTML, and a date's or a number's separators — the digit group separator
   is a translated string — are literal too. The same goes for every string that is placed into
   markup the code builds rather than into a sentence: the patient id and the dashboard link's title in
   a record's heading, the support link's label, the translated labels the decorations hand to the
   templates as values, the rule summaries listed in the header, and the missing-value string wherever
   it stands in for a value. The templates and headings themselves are the report's Markdown and are
   not escaped.
2. `decorate_context()` adds the values a template needs beyond what the rule records: a localized
   label for each coded value `context_decorations` in `_mapping.qmd` names for the rule (rule 19's and
   rule 61's SSI type from `ssi_types`, rule 47's admission type from `admission_types`, rule 50's
   device from `devices`, which `label_maps()` assembles from the glossary's abbreviations, rule 51's
   count from `day_counts`, rule 55's secondary-BSI item from
   `secondary_bsi_items`), with `missing_value` where the code is missing or unknown, so the
   placeholder always has a value. A rule whose sentence needs a label for a code it records gets a
   row in that table and a map in `label_maps()` beside it in `_mapping.qmd`. The string resources key
   each label by what it means (`delivery_room`, not the option code `1`), and `label_maps()` maps
   every value the rule's field holds to its label by a literal `sR$` reference, so that the
   string-layer check sees the key used and a changed option code changes that function but no
   translated string. The setup refuses a row whose field the rule does not record, whose map
   `label_maps()` lacks, whose map has no string for one of its values, or whose placeholder none of
   the rule's sentences names. That last check reads the English source sentences, since it guards
   the table: a translation that words a sentence without the label still renders.
3. `select_template()` picks the template. Two rules carry a second complete sentence rather than one
   sentence with an optional fragment: rule 20 (`description_secondary_bsi`) for a pathogen recorded as
   causing a secondary sepsis, and rule 55 (`description_unanswered`) for a secondary-BSI item that
   was never answered, which has no answer a label could name.
4. The sentence is followed by `see_problem_details`, interpolated with the cross-reference to the
   rule's `primaryDetail` from `_mapping.qmd`. That column exists because the detail a rule cites is not
   derivable from the details it uses: the day-of-life and day-of-occurrence rules share the same pair of
   details but cite different members of it.

Markup stays out of the strings. The support-address link in `patient_problem_multiple_hint` is built in
code and handed to the template as `{support_link}`; the Tracker Capture dashboard link of each patient is
built from the connection options the data came from (the API base URL with the web context in place of
`/api`) and the program id the import resolved by its code, never from a fixed host or UID.

## The exception list

The report never removes flagged records: it imports with `include_invalid_patients = TRUE`, which
skips the import's validation pass and keeps the enrolments without an admission form that the import's
orphan removal otherwise drops, together with `include_unenrolled_patients = TRUE` for the patients
without an enrolment, and calls `validate()` itself, passing the list
`neoipcr::read_validation_exceptions()` reads from the `validationExceptionFile` parameter. neoipcr resolves the list onto the dataset's keys and each rule
exempts the records addressed to it. The same reader serves the Partner and Reference Reports through
`get_validation_exceptions()` in `reports/common/helpers.R`, so a malformed file is refused once, the same
way, wherever it is used.

## Reconciled data

The import reconciles, as every import does unless it passes `reconcile = FALSE` to
`neoipcr::dhis2_dataset_options()`: before anything is validated, it repairs the stored values the NeoIPC
coordinating centre is responsible for, which are the values Tracker Capture derives itself or keeps in a
section it hides (`neoipcr::reconciliation_ids()` lists the reconciliations, and the `reconcile`
argument of `?neoipcr::dhis2_dataset_options` describes them). The report therefore validates reconciled
data. A value a finding shows, or the value it is compared with, can differ from what Tracker Capture
shows for the same record: the day of life of an infant admitted from the delivery room or on the day of
birth, for example, is derived from day of life 1 at admission, a value the client writes to the
admission form only while that form is open for editing. The help on correcting the day of life at
admission (`en/_solution_0018.Rmd`) tells the partner that the report's values can differ from the
forms' for this reason, and how to bring the stored values in line. The problem details on
a day of life that does not match the calculated value and on an infection within the first three days
of life cite it, so the report includes it wherever one of rules 27 to 42 fired except rules 30, 34 and
38, which concern the day of hospitalization.

The report never lists a reconciliation. Repairing what the partner neither chooses nor sees is the
coordinating centre's task, not the department's, so a reconciliation is not a finding. The Partner and
Reference Reports show how many records each reconciliation changed, and
`neoipcr::reconciliation_details()` gives the coordinating centre the record-by-record view.

## Rule selection and the clean result

The `rules` parameter (`integer[]`) restricts the render to the named rules; absent, every rule runs.
The header states which rules the document rests on — all of the rules neoipcr defines, with their
number (`rules_applied_all`), or the count applied and the rules not applied with their summaries — so
a report rendered with a subset cannot be read as a clean bill on the rules it skipped. An id neoipcr
does not know aborts the render. The `# @type integer[]`
annotation names the parameter's type for a consumer of the parameter schema; the only such consumer
today, the reporting service's schema generator, maps `character[]` and not yet `integer[]`, which is
part of what a service endpoint for this report has to add.

A render that finds nothing renders a document that says so (`no_problems_detected`) under the same
header, and stops: the introduction, the problem details and the solutions cross-reference sections that
exist only when there are findings to explain. This is what lets the service and the app return a report
for a clean department; for the wrapper it means a per-site batch writes one file per site, clean sites
included, and a missing file no longer means "clean".

## Before a render

`_setup.qmd` asserts, before it composes the header, that every id in `validation_rule_ids()` has its
non-empty templates (the `description`, and for rules 20 and 55 their second sentence as well) and
`summary` under `problems` in the string resources, so a rule added to neoipcr without its sentences
fails the render with a message naming the rule rather than rendering a blank line or failing in the
header. `_setup.qmd` fails the render when `validate()` reports
a selected rule it could not run (its `rules_skipped` attribute, set when the dataset lacks a column the
rule reads): the import asks for every tier, so a skip means the dataset is not what the report expects,
and a document that claimed those rules would be wrong. It also fails the render when a rule's
sentences name a placeholder the rule does not record, as `neoipcr::validation_rule_context_fields()`
declares the fields, or that `decorate_context()` does not add for it (the placeholders
`context_decorations` names for the rule), instead of failing inside the interpolation on the first
finding that reaches the sentence.

## Adding a validation rule

1. neoipcr: implement `validation_rule_N()` in the matching `R/validation-rules-*.R`, register it in
   `validation_rules`, document its context fields in the table on `validate()`, add the detect /
   no-detect / exception tests, note it in `NEWS.md`, and release the package.
2. Here: add `problems.N` with `description` (named placeholders equal to the rule's context fields,
   plus the labels its decorations add) and
   `summary` to `content/_sR.yaml`, and where the sentence shows a coded value as a label, a row in
   `context_decorations` with its labels in the string resources under descriptive keys, mapped from
   the field's values in `label_maps()`
   (and, where a field can be missing while another records the same thing, a row in
   `context_fallbacks`); add its row to `problem_info` in
   `_mapping.qmd` (`primaryDetail`,
   `usedDetails`), writing a new `en/_problem_detail_NNNN.Rmd` and `_solution_NNNN.Rmd` where no
   existing one fits and registering them in `problem_detail_info` / `solution_info`. A detail's
   `usedSolutions` names the solutions its text cites; the render closes that set over the solutions
   those cite in turn, so a solution needs no list of its own, and a detail that cites another detail
   must share every rule's `usedDetails` with it. List the new files
   in `po/reports.po4a.cfg`, regenerate the YAML key list with `scripts/Update-Po4aYamlKeys.ps1`, run
   `scripts/Invoke-Localization.ps1 -Update -NonInteractive` and commit the `.pot`.
3. Declare the neoipcr release the report now needs in `reports/compatibility.yml`.
4. Enter the rule in `docs/validation-rule-coverage.md` against the protocol anchor it enforces, and say
   who can act on its findings. A finding the partner cannot see in Tracker Capture does not belong in
   this report: it is a reconciliation by the NeoIPC coordinating centre, as that document describes,
   when it is a contradiction under the protocol whose intended state can be inferred, and no rule at
   all otherwise.
