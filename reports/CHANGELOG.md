# Changelog — NeoIPC reports

Notable changes to the render-ready report sources: the Partner Report, Reference Report, Validation
Report, Partner Certificate, and Patient Data Report, together with the shared `common/` layer and the
localized string resources they draw on.

This product is versioned independently of the others in this repository: its version lives in
[VERSION](VERSION) beside this file, and its releases carry the `reports-v` tag prefix. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

The release workflow reads the section matching the released version out of this file and publishes
it as the GitHub Release body, so a release cannot be cut for a version this file does not describe.

## [Unreleased]

### Added

- The Validation Report takes a `rules` parameter (`integer[]`) naming the validation rules to apply,
  and its header states which rules the document rests on — all of them, or the count applied with the
  rules left out and a summary of each. `Build-ValidationReport.ps1` passes it as `-Rules`.
- A Validation Report with no findings renders a document saying so, instead of aborting the render.
  A per-site batch of `Build-ValidationReport.ps1` therefore writes one file per site, clean sites
  included; a missing file no longer means a clean site, and the `NoData` render status the module and
  wrappers carried for that case is gone.
- Every validation rule carries a placeholder-free `summary` of what it checks in the string
  resources, for the report header and for any consumer that lists the rules.
- The Validation Report renders neoipcr's rules 43 and 44, which question an enrolment still active
  more than 120 days after its admission — without a surveillance end form, or with one that is not
  completed. Their sentences and explanations say that the infant may still be in the department and
  the message can then be ignored, and the explanations tell the two cases apart: the form has to be
  added before the enrolment is completed in the one, and completed rather than added in the other.
  A new solution shows how Tracker Capture's list filter shows every patient record of a department
  with an active enrolment, so a site can find the open ones the report does not list yet.
- The Validation Report renders neoipcr's rules 45 to 56, twelve rules for constraints of the Core
  Protocol the partner team can see and correct in Tracker Capture: an admission beyond day of life
  120; a transferred or readmitted infant without a plausible day of life at admission; a later
  enrolment typed as an admission from the delivery room or on the day of birth; an enrolment dated on
  or after the patient's recorded death; the same infection type recorded again within 14 days; a
  device-associated sepsis or pneumonia on an enrolment without days of that device; a cumulative count
  above the patient days; inconsistent antibiotic substance entries, each naming the substance, or its
  stored code where the option set carries no name for it; a secondary bloodstream infection item that
  disagrees with the organisms recorded with it; and a multiple birth recorded with fewer than two
  infants. Each has its sentence, summary and explanation, and a new solution shows how to change the
  data in a patient record's profile. A sentence that shows a coded value (an admission type, a device,
  a count, the secondary-BSI item) shows its localized label, from label maps in the string resources
  that the formatter reads through one table; the counts and the secondary-BSI item are worded as the
  form labels them.
- The Validation Report renders neoipcr's rule 57, a patient record with neither a birth weight nor a
  gestational age, although the registration requires one of the two; its explanation asks for one of
  them in the patient's profile, or, in a department that includes only infants meeting the eligibility
  criteria, for the record's deletion if neither is known.
- The Validation Report renders neoipcr's rules 58 to 61. Rule 58 reports a gestational-age text in a
  format other than the one the registration form requires, and its explanation leads to the patient's
  profile. Rules 59 to 61 report a completed sepsis, necrotizing enterocolitis, or surgical site
  infection form that does not meet the case definition Tracker Capture checks when the form is
  completed: clinical sepsis for a sepsis form that records no infectious agent, and for a surgical
  site infection the definition of the type of infection the form records, which the sentence names.
  Their explanations ask for the form to be reopened, checked against the definitions, and completed
  again, so that Tracker Capture checks it once more, or deleted where the infection meets no
  definition. The report requires neoipcr `v0.0.0.9007`.
- A new solution in the Validation Report shows how to correct the day of life at admission, and the
  explanations of the rules on a day of life that does not match the calculated value and on an
  infection within the first three days of life cite it: the infection and procedure forms of an
  enrolment take their day of life from the day of life at admission on its admission form, and for
  an infant admitted from the delivery room or on the day of birth Tracker Capture sets that value to
  1 only while the admission form is open for editing. A completed admission form holding another
  value is therefore reopened, which makes Tracker Capture set the value to 1 at once, and completed
  again; each infection and procedure form of the enrolment is then refreshed so that Tracker Capture
  derives its day of life again, and a completed one is reopened first and completed again
  afterwards. An enrolment reopened to edit its forms is completed again as well. The solution also
  says that the Validation Report already uses day of life 1 at admission for such an infant in its
  calculations, so its values can differ from the forms' until the forms are corrected. Until the new
  text is translated, the German Validation Report shows the solution and the sentences citing it in
  English.
- The Partner and Reference Reports open with a data-validation summary: for each validation rule that
  removed or exempted a record, the number and kind of records it concerned, and the totals across all
  rules — the Partner Report's department beside the reference data where the report compares the two.
  The `includeValidationSummaryTable` parameter (`ValidationSummary` in the build wrappers' element
  lists) switches it off like any other table. A dataset written before neoipcr recorded the summary,
  or built with the validation pass switched off, is described by a sentence saying so, as is a
  summary in which no rule removed or exempted a record; in the Partner Report each sentence names the
  data it describes: the department's data, the reference data, or both. The reference data's counts
  are shown whenever they carry a summary, including when the department's data carry none. The
  summary relies on neoipcr's reporting period selecting the enrolments before the validation pass,
  which it does from `v0.0.0.9004` on — before that, it would count every out-of-period patient as
  removed by rule 25.
- The data-validation section of the Partner and Reference Reports shows, after the validation
  summary, what the NeoIPC coordinating centre reconciled before the validation rules were applied:
  for each of neoipcr's reconciliations, the kind of record it acts on and the number of records it
  repaired and, where there are any, of the records it reported and kept as stored — the Partner
  Report's department beside the reference data where the report compares the two. A count the
  import could not establish, since it did not read the records the reconciliation acts on, shows as
  a dash, which a note under the table explains. A dataset written before neoipcr recorded the
  reconciliations, one built with them switched off, and one in which nothing needed reconciling are
  each described by a sentence saying so; as for the validation summary, each of the Partner Report's
  sentences names the data it describes, and the reference data's counts are shown whenever they
  carry a summary. The table follows `includeValidationSummaryTable`, and its introduction says that
  the Validation Report checks the reconciled values and does not list the reconciliations. A render
  logs a warning when the loaded neoipcr applies a reconciliation the reports have no label for,
  which the table then labels by its number, or the reports label one it does not apply.
- The Validation Report fails the render when a rule's sentence names a placeholder the rule does not
  record, as `neoipcr::validation_rule_context_fields()` declares the fields, instead of failing
  inside the interpolation on the first finding that reaches it.
- The Validation Report fails the render, naming the rule, when its string resources carry sentences
  for a validation rule the loaded neoipcr does not define, as it does for a rule neoipcr defines
  without sentences. The reporting service offers its callers the rules the string resources list, so
  such a rule would otherwise fail inside `neoipcr::validate()`, and only in a render that selects it.
  Both checks, and the check of the sentences' placeholders, run before the report reads any data.

### Changed

- The Validation Report renders the findings of `neoipcr::validate()` instead of running its own copy
  of the 42 rules: the rule files and their per-rule formatters are gone, and one function interpolates
  each finding's context into the rule's sentence. The problem descriptions use `{named}` placeholders
  equal to the context field names neoipcr documents on `validate()`, and the cross-reference to a
  problem's explanation is composed in code from a `primaryDetail` mapping rather than written into every
  sentence. The exception list is read by `neoipcr::read_validation_exceptions()` — in the Validation
  Report and, through `get_validation_exceptions()`, in the Partner and Reference Reports' data scripts.
  An exception file named explicitly but missing now aborts the render like any other invalid list,
  instead of being ignored with a warning while every flagged record is removed.
- The patient dashboard links of the Validation Report take the program the import resolved by its
  code instead of a fixed UID, and point at `dhis2PublicBaseUrl`, the base URL at which the report's
  readers reach DHIS2, instead of a fixed host. A caller that reads the data over an address its
  readers cannot open passes it, as the reporting service does and as `Build-ValidationReport.ps1`
  does with `-Dhis2PublicBaseUrl`; without it the links point at the DHIS2 instance the data came
  from. Before it reads any data, the report checks the address the links start from: `http://` or
  `https://`, a host name or IPv4 address in ASCII, an optional port from 1 to 65535, and a path of
  ASCII letters, digits, `-`, `.`, `_`, `~`, and percent-encoded bytes. It refuses anything else —
  whitespace, a user name or password, a query or a fragment (an empty `?` or `#` included), a
  bracketed host such as an IPv6 literal, a parenthesis — and when the address the data is read from
  fails, it asks for `dhis2PublicBaseUrl` instead. `Build-ValidationReport.ps1` itself refuses a
  `-Dhis2PublicBaseUrl` with an `@`, a `?` or `#`, whitespace, or a control character before it
  authenticates: the parts of a URL that can carry a secret never reach its build report or debug
  output, and Quarto would drop a parameter value with a line break without a warning. A refusal never
  repeats the address.
- The German Validation Report wrapper is generated by `Build-LocaleReportSources.ps1` from the
  annotated master, like the Partner and Reference wrappers.
- The reports raise their errors with `rlang::abort()` and their warnings with `rlang::warn()`, so an
  error appears in the log in rlang's format, with its message on a `! ` line.
- The Partner and Reference Reports' description of exposure densities states that a ventilation day
  requires more than 12 hours of the respective support, following the protocol, while a catheter day
  keeps at least 12 hours.
- The move to neoipcr `v0.0.0.9006` changes the data of the Partner Report, the Reference Report, and
  the Partner Certificate as well: the import's validation pass, which these
  reports run by default, also applies rules 46 to 57 and removes the patients they flag — a
  duplicated antibiotic substance entry, the same infection type recorded again within 14 days, a
  day count above the patient days, or a patient with neither birth weight nor gestational age, for
  example. The eligibility filter keeps an admission on day of life 120, which it used to drop, and no
  longer reads a missing value as ineligible: an admission from the delivery room or on the day of
  birth without a day of life now stays, and an infant transferred or readmitted after the day of birth
  without one, like a
  patient without birth weight and gestational age, is removed by the pass and counted in the
  validation summary, where the filter used to drop it unreported. Rates, the validation summary tables,
  and the certificate's patient count can therefore change with this release. Rule 45 removes nothing there: under the
  default the eligibility filter has already dropped such an admission, and with non-core patients
  requested the pass leaves rule 45 out.
- Every report now runs on neoipcr `v0.0.0.9007`, which changes the data of the Partner Report, the
  Reference Report, and the Partner Certificate further. Its import reconciles, before its eligibility
  and range filters and its validation pass, the stored values Tracker Capture derives itself or keeps
  in a section it hides, so the filters and the pass judge the reconciled values: a first admission
  from the delivery room or on the day of birth stored with a day of life above 120 is given day of
  life 1 and stays, where the eligibility filter used to drop it; total gestation days computed again
  from the gestational-age text can move a patient across the eligibility bound of 32 weeks, in either
  direction, or across a requested gestational-age range; total gestation days outside 140 to 349
  without a text in the required format, a stored 0 among them, are removed: a patient whose total is
  removed passes no requested gestational-age range, a patient with such a total below 140 days and a
  birth weight of 1500 g or more is no longer eligible, and a patient with such a total and no birth
  weight is removed by the pass under rule 57, or rule 58 where the text is in the wrong format; a
  surgical site infection whose secondary-BSI item is not Yes no longer counts as one with a secondary
  BSI; and a culture-negative sepsis whose infectious agents are removed counts as an infection
  without an infectious agent. The pass also applies rules 58 to 61 and removes the patients they
  flag: a gestational-age text in the wrong format, a completed sepsis form without an infectious
  agent that does not meet the clinical-sepsis definition, or a completed necrotizing enterocolitis or
  surgical site infection form that does not meet its case definition. Rates, the validation summary
  tables, and the certificate's patient count can therefore change with this release. The Patient
  Data Report keeps every value as stored: it passes
  `reconcile = FALSE`, since a copy of the stored record under Article 15 of the GDPR shows the values
  as they are stored.
- Every translatable report string names its placeholders (`{column}`, `{count}`, `{hospital}` and
  the like) where it used a positional `%s`, and the reports fill them with `interpolate_translation()`.
  Pester tests keep printf placeholders out of the string resources and `sprintf()` away from them, and
  hold every interpolation of a string resource to the placeholders of its English template: exactly
  those, or for the outlier composer, which fills whichever template it picked from one set of values,
  no others; the Validation Report's rule sentences are held to neoipcr's context fields when it renders.
  The Partner and Reference Reports' prose no longer keeps sentence text inside inline R: a sentence
  that varies is written out in full for each case, as the Partner Report's introduction is with and
  without reference data, or takes only its variable part from the report's setup. The Partner
  Certificate's funding statement carries no line break: the footer wraps it beside the EU emblem where
  the layout needs, instead of where a placeholder in the translation put the break. Translators see new
  source text for these strings; until it is translated again, the German and Italian certificates and
  the German Partner Report's nosocomial-infection introduction fall below the 80 % po4a requires and
  render in English.
- The Partner Report's organism-resistance introduction and the resistance methods paragraphs of the
  Partner and Reference Reports call the phenotypes they count resistance categories, where they said
  resistance markers.

### Removed

- Validation rule 16, which reported a surgical site infection form dated outside the time frame of
  its enrolment. A surgical site infection belongs to the follow-up period of its surgical procedure,
  which may extend beyond the discharge and into a readmission, so an infection date outside the
  admission it is recorded in is legitimate as long as a recorded procedure covers it, which rule 19
  checks. The explanation of the time-frame rules says so.
- The eleven `quartile_footnote` strings, which no table used; the shared secondary-BSI
  `rate_footnote`, which the Partner Report overrides and the Reference Report does not read; and the two
  `_methods-antibiotic-utilization.Rmd` prose files, which held nothing but an inline R span; the
  antibiotic-utilization tables write that sentence themselves.

### Fixed

- The Partner and Reference Reports' PDFs did not conform to the PDF/A-4 they declare: the birth-weight
  and gestational-age figures set their text in the standard Helvetica without embedding it. The
  figures are drawn with the Cairo device now, in Noto Sans, which is embedded. Rendered on a host, the
  PDF conforms only with Noto Sans installed as the Noto project's static OTFs: Cairo embeds the
  TrueType build's glyphs outside WinAnsi without the `CIDToGIDMap` entry PDF/A-4 requires.
- The Partner and Reference Reports' PDF showed no page number on the first page, whose footer set the
  EU emblem and the funding statement but not the number. Every page is numbered now.
- The Patient Data Report's labels mixed three casings: most capitalized word by word ("Patient Days",
  "Central Venous Catheter (CVC)"), the human milk and kangaroo care days and the antibiotics heading
  in lower case, and the day counts' unit capitalized ("58 Days"). Its table labels are in sentence case
  now, as the Partner and Reference Reports' row labels are, its antibiotics heading is capitalized, and
  the unit reads "58 days"; its patient-days label is the one the other reports use. German keeps its
  noun capitalization.
- In the Partner Report's notes on outlying values, the risk-density table's probiotics appeared as the
  raw identifier "Probiotic" in every language rather than by the term the table uses, and the note for
  a table without outliers misspelled "similar".
- The Patient Data Report failed at its import on every render: neoipcr before `v0.0.0.9006` failed
  on the events' timestamps and on enrolment notes read without the DHIS2 enrolment ids, both of which
  the report requests, and on records without a creator: events created before the instance's upgrade
  to DHIS2 2.36, and enrolments and tracked entities created before its upgrade to 2.37. neoipcr
  `v0.0.0.9006` fixes all three, and the reports now require `v0.0.0.9007`.
- Once past its import, the Patient Data Report still failed for every patient it found, in the
  rendered report and in the JSON export alike: it looked up the hospital through the patient record's
  hospital key, which the import leaves off the patient record when it imports the department in full,
  as the report does, since the department then carries the key. It now takes the hospital from the
  patient's department; for a department without a hospital, the report leaves the hospital field empty
  and the JSON export's `hospital` is an empty array.
- The Patient Data Report's PDF footer showed the page number twice, in the centre and at the outer
  edge. It now shows it once, at the outer edge, on every page.
- A bare `yes` or `on` in a report's string resources stays text, as `no` and `off` already did,
  where YAML reads it as a logical: a translated label such as `Yes`, which po4a writes unquoted, no
  longer turns into `TRUE`. In the other direction, a bare `false` is now read as a logical where it
  used to stay text, so only `true` and `false` are logicals, and the Partner Report's concordance
  flags are consistently logical.
- An antibiotic-utilization table with no data failed the render with an "unused argument" error, since
  its no-data branch passed the table's own sentence to a helper that took none; the helper takes the
  sentence now, and the table renders it.
- A sentence the Partner or Reference Report's PDF shows in a table's place wraps within the text
  block, where it used to be set on one line that a longer sentence, or its translation, ran into the
  right margin.
- A sentence the Partner or Reference Report shows in a table's place was missing from Word output,
  which kept only the table's caption: every format but HTML received it as raw LaTeX, which Pandoc's
  Word writer drops. Only the PDF receives it as LaTeX now, escaped for it, and every other format
  receives it as a paragraph escaped for Markdown, so a translation containing a character either
  reserves, such as `&`, `%`, `_`, or a backslash, renders as written instead of breaking the document
  or cutting the sentence short.
- A solution that another included solution cited, but no included explanation did, was left out of
  the Validation Report, and the reference to it rendered unresolved. The report now includes every
  solution the included ones cite, and a solution po4a withheld for want of translation falls back to
  English, as an explanation does, instead of vanishing with its references.
- The Validation Report's page break between the problem details and the solutions rendered as the
  literal text `:::` whenever the last detail file ended without a final newline, since its fence then
  sat on the line after that file's closing paragraph and Pandoc read it as part of the paragraph. The
  report now ends every included prose file with a blank line of its own.
- `Invoke-QuartoRender`, the render helper every build wrapper renders through, forwards the whole
  message of a Quarto filter warning — the `WARNING (<file>:<line>)` kind — up to the blank line
  that ends it, where before only the head line reached the build log and any line after it, such as
  the text of the stray-fence diagnostic, went to the module's verbose stream. Pandoc's own warnings
  and the reports' logger records were single lines already and are unchanged, as is `Invoke-Rscript`.
- A line of the Partner Certificate's funding statement that wrapped on its own started under the EU
  emblem in the footer, not beside it: only the lines the translation's own break began were indented,
  so a translation whose text before that break ran longer than the line put its continuation under the
  emblem, and the German one came within half a millimetre of it. The statement is now set as one block
  indented past the emblem, wherever it wraps.
- The Reference Report's nosocomial-infection introduction read "In the incidence densities … are
  displayed" when the incidence-density table was left out, which the section is shown without
  whenever one of its other tables is included. The sentences pointing at the incidence-density and
  device-associated tables are now written only when the report includes the table.
- A translated figure caption could never replace the English one in the Partner or Reference Report:
  the captions were a list of entries, and the string cascade overlays a translation only onto named
  entries. They are keyed by name now. A language's captions appear once its translation of the
  shared report strings passes the 80 % po4a requires, which none has yet.

## [0.1.0-alpha] - 2026-09-07

### Added

- Every PDF is rendered with LuaLaTeX and declares archival PDF/A-4. PDF/UA is deliberately not
  declared: it requires tagged structure, which the KOMA-Script document class cannot emit, and a
  conformance the file does not have is worse than none. The two distribution figures and the
  certificate's signature carry alt text from the localized string cascade; the title-page logos
  carry the fixed alt text `NeoIPC`.
- An opt-in `audit` profile (`quarto render --profile audit`) that overlays axe-core WCAG 2.1 AA checks
  on the four reports that produce HTML; it never composes into a default render, so partner-facing
  and service HTML never carry the bundle.
- A render failure inside neoipcr is logged with a full R backtrace on the report's log channel instead
  of an opaque one-line error.
- The Partner Report says above its comparison when an uploaded dataset's embedded benchmark superseded
  the reference named in the request, since everything below then describes the benchmark that was
  used rather than the one asked for.

### Changed

- The distribution figures' sample-size captions count the patients the figure covers — those with a
  recorded birth weight or gestational age, as neoipcr's figure data now supplies them — rather than
  all patients.
- The Reference Report takes a `departmentFilter` parameter, and `Generate-ReferenceData.R` a
  `--departmentFilter` option, in place of the `hospitalFilter` parameter, which nothing consumed:
  surveillance is observed at department level.
- The report text follows the house spelling — Oxford British, taking the `-ize` form where it is also
  valid American English — so "Antibiotic Utilization" and the table and methods sources named after
  it are renamed accordingly.
- `compatibility.yml` declares neoipcr `v0.0.0.9001`, the first release carrying the exported
  `get_antibiotic_utilization_table()` these reports call, so the declared floor is the one the
  sources actually need.
- A dataset serialized before the antibiotic table was renamed is still read, under the name it was
  written with. The rename is a source-level change only, and a saved dataset is not migrated by it.

### Fixed

- Translated text that interpolates a value rendered an R error in place of the sentence, immediately
  before a table, and every following table lost its footnote while the render reported success. The
  values are now forced before interpolation, and an unnamed or zero-length argument is refused.
- A table footnote that is display math no longer leaves LaTeX a line break with no line to end — a
  construct untagged LaTeX tolerates and the `\DocumentMetadata` tagging that PDF/UA requires rejects.

## [0.0.1-alpha] - 2026-07-07

First published version. The reports render English only: `reports/.gitignore` ignores the
po4a-generated `_quarto-<lang>.yml` language profiles and keeps only `_quarto-en.yml`, and the
NeoIPC-Reporting service's `RenderReadyLanguages` option lists the languages it offers. That set is a
deliberate declaration rather than the set of catalogues that exist, so a language appears when its
output is correct rather than when its translation begins.

### Added

- The five report sources and the shared `common/` layer they build on: locale resolution, the string
  resource cascade, the formatters, and the argument parsing the wrappers hand them.
- `compatibility.yml`, declaring the neoipcr and neoipc-app versions these reports are tested against
  and require. The reporting image pins this product by release tag and matches the two records
  against each other, so an image cannot bake in a neoipcr the reports were never rendered with.
