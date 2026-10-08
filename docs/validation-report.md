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
   `context_fallbacks` in `_mapping.qmd` pairs the two: rules 52 to 54 and 62 record a substance both as the
   name the form shows and as the code it stores, and a code the option set does not carry has no
   name, so the sentence shows the code. The setup refuses a pair naming a field the rule does not
   record. Then `format_context()` turns the one-row context into named character scalars — dates in the locale's
   date format, factors and numbers as text, a missing value as the report's `missing_value` string,
   worded to sit inside a sentence — so `interpolate_translation()` never receives a zero-length or
   unnamed value, which it refuses. Every value is escaped for Markdown at this boundary
   (`escape_markdown()` in `reports/common/helpers.R`, which first collapses runs of whitespace, line
   breaks included, to one space, since a value is a phrase and a line break would end the heading or
   link it sits in), so a free-text infectious-agent name or a procedure description renders as typed
   rather than as emphasis, a link or HTML, and a date's or a number's separators — the digit group
   separator is a translated string — are literal too. The patient id in a record's heading is escaped
   the same way. A translated string the code places into markup it builds is escaped as well, but
   with `escape_markdown_translation()`, which leaves the apostrophes, quotation marks, dashes, and
   full stops to Pandoc's smart typography, so they are set like those of the sentence around them:
   the support link's label, the translated labels the decorations hand to the templates as values,
   the rule summaries listed in the header, and the missing-value string wherever it stands in for a
   value. The dashboard link's title is the exception: Pandoc never sets a link title's typography,
   and a quotation mark can end it, so it is escaped in full and its string carries its typographic
   apostrophe itself. The templates and headings themselves are the report's Markdown and are not
   escaped.
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
3. `select_template()` picks the template. Three rules carry more complete sentences rather than one
   sentence with an optional fragment:
   - rule 20 (`description_secondary_bsi`) for an infectious agent recorded as causing a secondary
     sepsis;
   - rule 55 (`description_unanswered`) for a secondary-BSI item that was never answered, which has no
     answer a label could name;
   - rule 54, a substance in two entries, by what the entries' days say (`rule_54_template()`):
     1. `description_days_missing` when an entry has no days, so the entries cannot be compared,
        whatever the other holds;
     2. `description_same_days` for equal days, which fit two courses of the same length as well as one
        course entered twice;
     3. its `description` for different days, most likely one entry per course, which the analyses add
        up correctly.

     Two entries with days whose substance adds up to more than the form's antibiotic days, which
     separate treatment courses cannot, are not rule 54's finding but rule 62's, which has one sentence.
4. The line starts with `problem_rule_label`, the rule's number, so that a request for an exception can
   name the rule, or with `problem_rule_label_warning` for a rule neoipcr declares a warning
   (`neoipcr::validation_rule_severities()`, which `_setup.qmd` reads into `warning_rule_ids`); the
   sentence follows, then `see_problem_details`, interpolated with the cross-reference
   to the rule's `primaryDetail` from `_mapping.qmd`. That column
   exists because the detail a rule cites is not derivable from the details it uses: the day-of-life and
   day-of-occurrence rules share the same pair of details but cite different members of it.

A warning flags a record that may be correct as entered: neoipcr's import keeps a patient only a
warning flags in the dataset the Partner and Reference Reports analyse, where an error removes it. The
Validation Report lists both alike, apart from the label, and where a warning is among the findings,
`problems_warning_note` follows the introduction to the list to say so. The note is a string rather than
a sentence of `_problems_intro.Rmd`, whose paragraphs are few: one changed paragraph, untranslated
until Weblate catches up, can take a translation below po4a's completeness threshold, and po4a then
writes no translated file at all. A string without a translation falls back to English on its own. The
introductions, the problem details, and the solutions each fall back to their English text where the
translated file is absent, with a warning in the log.

Markup stays out of the strings. The support-address links in `patient_problem_multiple_hint` and
`exception_request_hint` are built in code and handed to the template as `{support_link}`, their e-mail's
subject and body percent-encoded with each line break as `%0D%0A` (`mailto_encode()` in
`reports/common/helpers.R`); the Tracker Capture dashboard link of each patient is
built from the address the report's readers reach DHIS2 at and the program id the import resolved by its
code, never from a fixed host or UID. That address is `dhis2PublicBaseUrl` when the caller passes it, as
the reporting service does, since it reads the data over an address inside its own network, and as
`Build-ValidationReport.ps1` does when given `-Dhis2PublicBaseUrl`; otherwise it is the address the data
came from, the API base URL with its trailing slashes and then a trailing `/api` removed.

`get_tracker_capture_base()` in `reports/common/helpers.R` checks that address before the import, on its
raw text rather than on what a URL parser makes of it: `http://` or `https://`, a host of dot-separated
labels of ASCII letters, digits, hyphens, and underscores (a host name or an IPv4 address), an optional
port from 1 to 65535, and a path of ASCII letters, digits, `-`, `.`, `_`, `~`, and percent-encoded bytes.
Anything else is refused: whitespace, a user name or password, a query or a fragment (an empty `?` or `#`
included), a bracketed host such as an IPv6 literal, a parenthesis. The address is written as it stands
into a Markdown link destination, which Pandoc's Markdown reader ends at an unbalanced `)` and in which it
percent-encodes brackets and a few other characters, so an address outside that shape could yield a link
that opens somewhere else. The refusal names the defect but never repeats the address, which can carry a
password, and a connection address that fails names `dhis2PublicBaseUrl` as the parameter to pass
instead.

`Build-ValidationReport.ps1` itself refuses a `-Dhis2PublicBaseUrl` with an `@`, a `?` or `#`,
whitespace, or a control character, before it authenticates or creates `-OutputDir`, again without
repeating the value. User information and a query or fragment are the parts of a URL that can carry a
secret, which the build report's record of the parameters and the `-Debug` command line would otherwise
hold before the report refused the value; the other shapes the report refuses carry none. Quarto drops
a `-P` value with a line break without a warning (its `parseMetadataFlagValue()` matches it against a
pattern whose `.` stops at a line terminator), so such a value would never reach the report's check,
and the links would point at the address the data is read from. The script passes the
value on as a single-quoted YAML scalar, since a plain one such as `~` or `null` would arrive as no
value at all.

## The exception list

The report never removes flagged records: it imports with `include_invalid_patients = TRUE`, which
skips the import's validation pass and keeps the enrolments without an admission form that the import's
orphan removal otherwise drops, together with `include_unenrolled_patients = TRUE` for the patients
without an enrolment, and calls `validate()` itself. It passes the list
`neoipcr::read_validation_exceptions()` reads from the `validationExceptionFile` parameter, which
`neoipcr::resolve_validation_exceptions()` has mapped onto the dataset's keys, and each rule exempts the
records addressed to it. The same reader serves the Partner and Reference Reports through
`get_validation_exceptions()` in `reports/common/helpers.R`, so a list is read the same way wherever it is
used.

The header's "Validation exceptions" entry says what became of the list, in one of four states, which
`validation_exception_state()` in `reports/common/helpers.R` derives:

1. **applied**, with the records the list exempted from each rule, in rule order, as
   `neoipcr::validation_summary()` counts them, at the rule's level as the Partner and Reference Reports'
   table counts them;
2. **none**, when no list is given;
3. **switched off**, when `applyValidationExceptions` is false while a list is stored or given, as an
   administrator may ask through the reporting service, which then passes the upload time but no file;
4. **unusable**, when the reader or the resolver refuses the list, as the resolver refuses a list without
   `DEPARTMENT_CODE` on a render of several departments: the report renders without it, logs the
   refusal, and says so, so that one bad list cannot keep every department from its report. Only
   neoipcr's refusal of the list (`neoipcr_invalid_exception_list`) is caught.

In states 1, 3, and 4 the entry also gives the day the stored list was uploaded, where the
`validationExceptionFileUploadedAt` parameter gives it: the reporting service passes it as
`yyyy-mm-ddThh:mm:ssZ`. The same time with fractional seconds, or with an offset from UTC in place of the
`Z`, is read as well; a value in any other form is logged and left out.

The Partner and Reference Reports, where the list decides which flagged records stay in the analyses,
fail on an unusable list instead, since skipping it there would change their numbers without a word.
Where the report lists problems, a note follows the header on requesting an exception: the NeoIPC support
team assesses each request, and an accepted exception keeps its problem out of later reports while the
patient's NeoIPC-ID and the record's dates stay the same, since the list matches records by them. Its
e-mail link asks for what the team needs to write the record: the department, the patient, the enrolment,
the form, and the rule.

An administrator can add an appendix (`includeUnusedValidationExceptions`, the wrapper's
`-IncludeUnusedValidationExceptions`) listing the list's records for
the departments in scope that match no record, or match one that the rule they name does not flag, as
`neoipcr::validation_exception_usage()` reports them for the whole list `validate()` was given, for the
list's upkeep. Whether a record matches does not depend on the rules a render applies; a matched record of
a rule the render did not apply is left out. The appendix names patients and is not meant to be passed on.
Everything the header and the appendix show is computed from the records of the departments in scope,
never from the whole list, which covers every partner: a list without `DEPARTMENT_CODE`, which neoipcr
keeps whole, gets a sentence in the appendix rather than its records.

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
does not know aborts the render. The `# @type integer[]` annotation names the parameter's type for a
consumer of the parameter schema: the reporting service's schema generator maps it to an array of
integers, through which the service's `/validation-report` endpoint passes the rules a caller selects.

A render that finds nothing renders a document that says so under the same header and leaves out the
introduction, the problem details, and the solutions, which cross-reference sections that exist only when
there are findings to explain; an administrator's appendix can still follow. The sentence is
`no_problems_detected`, or `no_problems_detected_exempted` when
the exception list exempted records, which the header counts. This is what lets the service and the app return a report
for a clean department; for the wrapper it means a per-site batch writes one file per site, clean sites
included, and a missing file no longer means "clean".

## Before a render

`_setup.qmd` asserts, before it reads any data, that every id in `validation_rule_ids()` has its
non-empty templates (the `description`, and for rules 20, 54, and 55 their further sentences as well) and
`summary` under `problems` in the string resources, so a rule added to neoipcr without its sentences
fails the render with a message naming the rule rather than rendering a blank line or failing in the
header. It also asserts the other way round, that every rule the string resources carry sentences for
is one `validation_rule_ids()` lists: the reporting service offers its callers the rules the string
resources list, and `validate()` aborts on an id it does not know, so a rule neoipcr retired with its
sentences left behind, or a report tree ahead of the installed neoipcr, fails every render with a
message naming the id, not only a render that selects it. Both directions are
`check_validation_rule_texts()` in `reports/common/helpers.R`, which is given the ids and so needs no
neoipcr, and which the Pester tests exercise. Before the data as well, `_setup.qmd` fails the render
when a rule's sentences name a placeholder the rule does not record, as
`neoipcr::validation_rule_context_fields()` declares the fields, or that `decorate_context()` does not
add for it (the placeholders `context_decorations` names for the rule), instead of failing inside the
interpolation on the first finding that reaches the sentence. After the validation pass, it fails the
render when `validate()` reports a selected rule it could not run (its `rules_skipped` attribute, set
when the dataset lacks a column the rule reads): the import asks for every tier, so a skip means the
dataset is not what the report expects, and a document that claimed those rules would be wrong. A
neoipcr older than the report needs fails the rule-text check, before any data is read: it defines no
rule 62, whose sentences the string resources carry.

## Adding a validation rule

1. neoipcr: implement `validation_rule_N()` in the matching `R/validation-rules-*.R`, register it in
   `validation_rules`, with `severity = "warning"` if it flags records the analyses can use as they
   stand although they may hide a mistake, document its context fields in the table on `validate()`,
   add the detect / no-detect / exception tests, note it in `NEWS.md`, and release the package.
2. Here: add `problems.N` with `description` (named placeholders equal to the rule's context fields,
   plus the labels its decorations add) and
   `summary` to `content/_sR.yaml`, each with its `# Translators:` comment directly above it — the
   `description`'s saying what each placeholder is replaced with, the `summary`'s the one every summary
   carries — which is entered as the string's explanation in Weblate once the string has reached it
   (see `docs/weblate-checks-adoption.md`), and where the sentence shows a coded value as a label, a row in
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
