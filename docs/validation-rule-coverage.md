# Validation rule coverage of the NeoIPC Core Protocol

The validation rules of `neoipcr::validate()` are meant to be a superset of the explicit rules of the
NeoIPC Core Protocol: every constraint the protocol states on the surveillance data has an
enforcement path, either a post-hoc validation rule or a capture-time program rule in the DHIS2
configuration, and the validation rules may go beyond the protocol to cover implicit invariants and
DHIS2-specific constraints. This document is the inventory that makes the superset claim checkable. It
lists every constraint the protocol states, keyed by the protocol's own anchor, and says for each one
what enforces it today and, where nothing does, what would.

The inventory is hand-maintained. It describes the protocol at `doc/protocol/VERSION` 1.3.0-preview2,
the 43 rules of neoipcr v0.0.0.9004 (ids 1 to 44, 16 withdrawn) and the program rules, compulsory
flags and option sets of `metadata/common/`. A change to any of the three has to be reflected here: a
new protocol constraint gets a row, a new rule is entered in the rows it covers, and a program rule
that starts or stops enforcing something changes the enforcement column. `docs/validation-report.md`
describes how a rule threads through neoipcr and the Validation Report; the row here is where its
protocol anchor is recorded.

## How the inventory was produced

The protocol was read through its document model, not its source text: Asciidoctor loads
`doc/protocol/NeoIPC-Core-Protocol.adoc` with every include resolved, and each section, paragraph,
list, definition list and table becomes one addressable block carrying its anchor and source position.
Every block was read for constraints on the data or its collection: date windows, eligibility and
inclusion criteria, required fields and completion semantics, thresholds, classification rules,
consistency requirements between fields, value domains, and process obligations. Each constraint was
then mapped to the rule sources in neoipcr (`R/validation-rules-*.R`) and to the capture-time
configuration (`programRules.csv` with the expression files it references, `programRuleActions.csv`,
`programStageDataElements.csv`, the option sets). The mapping reads the rule's code, never its
description: "covered" means the rule's filter flags every violation of the statement as written.

The two appendix catalogues, the List of Antibiotics and the List of Infectious Agents, are reference
data rather than protocol text. Their header paragraphs and column structure are inventoried; their
rows are not.

## Reading the inventory

Each row carries the protocol anchor (a section id such as `sec-def-pneumonia`, a block id such as
`tbl-eligibility-examples`, or a data-dictionary term such as `dd-patient-days`), the constraint in
checkable form, its enforcement class, the neoipcr rules that enforce it, the capture-time
configuration that enforces it, and a pointer into the gap list below where the enforcement is
incomplete. A constraint marked *(derived)* is one the protocol states as an example, an analysis
convention or background rather than as a rule; it is inventoried because a rule can still enforce it.

| Class | Meaning |
|---|---|
| Covered | A post-hoc rule flags every violation the dataset can show. |
| Partial | A post-hoc rule flags some violations; the gap entry says which are missed. |
| Capture time | No post-hoc rule, but a program rule with an error or mandatory-field action, a compulsory flag, an option set or the form structure refuses the violation at data entry. |
| Interface only | No post-hoc rule, and the only support at data entry is a field or section the program rules hide, or a value the client assigns. Nothing refuses the violation on the stored record. |
| Not covered | Neither a post-hoc rule nor capture-time enforcement, although the dataset could show a violation. |
| Not checkable | The dataset cannot show a violation: a process obligation, a clinical judgement, or a quantity the data model does not record. |

A program rule whose only action is a warning, a message or a displayed value does not enforce
anything and is not counted as capture-time enforcement. The capture-time column of a row lists
every program rule, compulsory flag, option set or structural property that touches the constraint;
the class is decided by whether any of them refuses the violation as the row states it.

Both capture-time classes describe **today's configuration and today's client**. A record entered
through the API bypasses every program rule; a record older than a rule was never held to it; and
the data was entered through several DHIS2 and Tracker Capture versions, so the rules and the client
that were in force when a value was stored are not the ones inventoried here. A capture-time entry
therefore says how a violation is prevented from now on in the user interface, not that the dataset
is free of it. That, more than API imports, is why the constraints the analyses depend on need
post-hoc rules.

The interface-only class exists because hiding is not enforcement, and the two hiding actions behave
differently in Tracker Capture. A **field** that holds a value is never hidden: the form renders it
whatever the rule says, and when the rule fires on an editable event the client blanks the value,
saves the blank and shows an alert. Every NeoIPC stage locks its form once the event is completed, so
on a completed event such a value is displayed read-only and stays until someone reopens the event,
at which point the client removes it. A **section** is hidden regardless of the values inside it, and
those values are left in place, invisible. Three rules hide a section and nothing else, so what they
hide survives for good: `NEOIPC_BSI_IF_NO_POS_CULTURE` (the organisms of a culture-negative sepsis),
`NEOIPC_BSI_AGENT_IF_NCC` (the laboratory findings and signs of a recognized-pathogen sepsis) and the
three `NEOIPC_SSI_INFECTION_TYPE_*` rules (the findings of the other SSI depths). Four rules hide a
section and blank its fields as well, so what they hide is invisible while the event is completed and
removed on the next edit: `NEOIPC_SSI_NO_SEC_BSI` (an SSI's secondary-BSI section),
`NEOIPC_SSI_NO_MIBI_RESULT_AVAILABLE` (an SSI's organisms), `NEOIPC_SSI_NO_INFECTION_TYPE` (the three
organism fields of the depth sections) and `NEOIPC_HAP_MIBI_TEST_RESULT_VAL_NO_VAL_OR_0` (a pneumonia's
organisms, of which only the first slot is blanked; the second and third stay). A field-hiding rule
that never fires leaves its field visible and untouched, as `NEOIPC_SSI_SUPERFICIAL_INFECTION` does,
which cannot fire at all.

| Class | Rows |
|---|---|
| Covered | 20 |
| Partial | 34 |
| Capture time | 62 |
| Interface only | 14 |
| Not covered | 28 |
| Not checkable | 120 |
| All | 278 |

The counts are of the rows in the tables below, so they can be recomputed from the file. A row may
merge statements that share an anchor and an enforcement, and the sections that hold only process
obligations (licensing, participation, data protection, imprint) and the abbreviations and appendix
lists are summarized in a sentence each rather than tabulated.

## Three responses to an inconsistency

The validation serves two purposes: a clean dataset for the analyses, and feedback the team at the
partner department can act on. Feedback is actionable when the team can understand the problem, see
it in Tracker Capture and fix it there. An inconsistency that a hidden section keeps, that a client
of an earlier version wrote, that a rule which no longer exists allowed, or that a client-assigned
companion carries is none of those things: the form does not show it, or the team did not cause it.
So a finding has one of three homes, and the gap entries below say which. neoipcr implements the
first today; the second is decided here and not implemented, so an inconsistency of that kind
currently reaches no report and no repair.

- **A partner-facing rule.** The inconsistency is visible in the form and the team can correct it.
  It becomes a validation rule, is listed in the Validation Report, removes the record from the
  analyses until fixed, and is counted in the validation summary as removed or exempted.
- **Network-side reconciliation.** The inconsistency is invisible, or not of the team's making, or one
  the client itself removes without asking on the next edit, and the intended state can be inferred
  reliably. It belongs to a class of its own in neoipcr, separate from the validation findings; the
  repair is applied before the validation pass and counted in the summary beside the removals, so a
  report never shows the team a problem they cannot see and never hides a change made to their data.
  Whether a repair is also written back to DHIS2 by the network is a separate decision the same
  detection serves either way. An inconsistency the network caused, such as a code a catalogue no
  longer carries, is detected the same way and reported to the network rather than repaired.
- **Nothing.** The value is merely one the current form does not ask for. It is not invalid, and a
  layout that has changed before and will change again is no ground for destroying it; the analyses
  read only what the definitions use.

Two things decide whether an inconsistency is reconcilable. First, it has to be a contradiction under
the protocol itself, whatever client or rule set wrote it: no positive culture and a recorded organism,
findings recorded at a depth other than the recorded SSI type, secondary-BSI organisms on an SSI whose
secondary-BSI item is No, a resistance category on an organism it cannot apply to, a client-assigned
companion that disagrees with the value it is derived from. A value that only today's form would hide
is not a contradiction. Second, the intended state has to follow from the record itself rather than
from a rule set. Where one of the two values is derived from the other, or can never be right under
the protocol, it is recomputed or dropped without further evidence. Otherwise the record's own history
decides: DHIS2 keeps `createdAt` and `updatedAt` on every data value, neoipcr imports them as
companion columns of every form field under `include_timestamps`, and of two values that contradict
each other the later one is the one the user meant, whichever client they were using. When the
timestamps are equal, as after a bulk edit or an import, the record is undecidable and is reported
rather than repaired. The deployment's history of metadata exports bounds when a rule arrived only to
the interval between two exports; it is a last resort, not a foundation.

The gap list groups the partial, uncovered, capture-time and interface-only rows into the decisions
they call for. Every gap names the anchors it concerns, what exists today, what is missed, who can act
on a finding, and the proposed way to close it. Which proposals become rules or reconciliations is a
maintainer's decision; a proposal is not a commitment.

## Gaps

### G1 — Eligibility on birth weight and gestational age

`sec-collect-case-eligibility-criteria-core`, `tbl-eligibility-examples`,
`sec-intro-what-you-reading-here`, `sec-analysis`, `sec-analysis-surgical-site-infections`,
`sec-analysis-standardized-infection-rate`, `abbr-vlbw`, `abbr-vpt`.

The protocol admits an infant with a birth weight below 1500 g or a gestational age below 32 weeks
(31 weeks 6 days inclusive); either criterion suffices. The program rule
`NEOIPC_PATIENT_BW_1500_GRAMS_AND_GA_32_PLUS_WEEKS` refuses registration with an error when the birth
weight is 1500 g or more and the total gestation days are 224 or more, or when one of the two fails and
the other is missing, except in departments of the organisation-unit group
`NEOIPC_ALL_PATIENTS_ELIGIBLE`. No post-hoc rule reads `patients$birth_weight` or
`patients$total_gestation_days`; a patient registered through the API, or before the program rule
existed, passes `validate()`. Birth weight itself is compulsory only when the gestational age is empty
(regular sites) or at departments in the organisation-unit group `NEOIPC_NEODECO_TRIAL_SITES` (the
NeoDeco trial sites); elsewhere an empty birth weight only warns, and such a patient silently drops
out of the birth-weight-stratified rates.

Proposal: a patient-level rule flagging a patient whose birth weight is 1500 g or more or missing and
whose total gestation days are 224 or more or missing, mirroring the program rule's three branches,
and a second finding for a missing birth weight. Both need the dataset to carry a department's
membership in `NEOIPC_ALL_PATIENTS_ELIGIBLE`, which the import does not read today (it reads only the
`NEO_DEPARTMENT`, `COUNTRY` and `TEST_UNITS` groups); the rule skips itself until the import provides
the flag. Who acts: the partner, who sees the birth weight and the gestational age on the registration
and can correct them or end the enrolment. Not decided.

### G2 — Admission within 120 days of birth

`sec-collect-case-eligibility-criteria-core`, `tbl-eligibility-examples`.

An eligible infant is admitted within 120 days of birth; the examples table makes day of life 120
eligible and day 121 not. The only upper-bound check on the admission day of life is
`NEOIPC_ADM_DOL_VAL_150_PLUS`, a warning at 150 or more, so an admission on day 121 to 149 raises
nothing anywhere and one at 150 or more only a warning. No post-hoc rule reads the admission form's
day of life against a ceiling.

Proposal: an enrolment-level rule on the admission form flagging a day of life above 120; only
admission type 3 can trip it, since types 1 and 2 are assigned day 1. The protocol should say whether
"within 120 days of birth" means day of life at most 120, as the table implies, and the program rule's
threshold should follow the protocol. Who acts: the partner; the admission form shows the day of
life. Not decided.

### G3 — Admission day of life and admission type

`dd-admission-date`, `dd-admission-type`, `dd-admission-on-day-of-life`,
`sec-analysis-standardized-infection-rate`.

The admission type's three values fix the admission day of life: for an infant delivered in the
hospital or admitted on the day of birth (types 1 and 2) it is 1, for one admitted the day after birth
or later (type 3) it is at least 2 and must be recorded. At capture `NEOIPC_ADM_TYPE_1` assigns 1 for
types 1 and 2, `NEOIPC_ADM_TYPE_2_PLUS` makes the field mandatory for type 3 and `NEOIPC_ADM_DOL_1`
refuses a value below 2 for type 3. No post-hoc rule checks the admission day of life at all. The
consequence is wider than the field: rules 27, 31, 35, 39 and 41 compute an event's expected day of
life from the admission form's value, and a missing value makes their comparison `NA`, which
`filter()` drops, so those rules are silently disabled for every event of an enrolment whose admission
form lacks the day of life.

Proposal: for types 1 and 2 a reconciliation that sets a missing or different day of life to 1, the
value the client assigns on every save and the team never chooses; for type 3 an enrolment-level rule
on the admission form flagging a missing day of life or one below 2. Who acts: the network for the
assigned value, the partner for the recorded one. Not decided.

### G4 — A readmission recorded with the wrong admission type

`sec-collect-progress-chart`.

A readmission after a longer absence is recorded as a new admission with the admission type for a
transfer or readmission after the day of birth (type 3). Every enrolment that has an earlier
enrolment of the same patient is by definition such a readmission, yet nothing compares an
enrolment's admission type with the patient's enrolment history: type 1 or 2 on a later enrolment is
accepted at capture and post hoc.

Proposal: an enrolment-level rule flagging an enrolment with admission type 1 or 2 when the same
patient has an earlier enrolment. Who acts: the partner. Not decided.

### G5 — A short absence split into two enrolments

`sec-collect-progress-chart`, `sec-collect-pseudonymization-table`, `dd-surveillance-end-reason`.

A patient who leaves the department for up to two days (for surgery, say) is not treated as
discharged; only an absence of more than 48 hours ends the surveillance and starts a new enrolment on
return. Rule 17 flags overlapping enrolments, and its intervals include both end days, so a
re-enrolment on the day of the previous surveillance end is already flagged; a re-enrolment one or two
days after the previous end, exactly the short absence the protocol says not to split, is flagged by
nothing. The reason value that section names for the longer absence, "transfer", does not exist as
such: the data dictionary (`dd-surveillance-end-reason`) offers "Discharge or transfer" and "Death",
and the option set mirrors it, so that half of the statement cannot be checked.

Proposal: an enrolment-level plausibility rule flagging an enrolment that starts one or two days
after the same patient's previous surveillance end, exemptible like rules 43 and 44 since dates
cannot resolve 48 hours exactly. Whether the dictionary should split the merged value or the
collection section quote it is a question for the protocol authority. Who acts: the partner, who merges the two enrolments or
confirms the absence through an exception. Not decided.

### G6 — Records after death

`sec-collect`, `sec-def-surgical-site-infection`.

The surveillance period ends when the infant dies, and SSI follow-up ends early on death; a procedure
on a deceased patient is excluded. The surveillance-end reason is compulsory and bounded to
discharge/transfer or death, but no post-hoc rule reads it. Rule 15 flags a procedure dated after its
enrolment's surveillance-end date, which for a death-ended enrolment is the death date, but not one
dated on the death day, and no rule relates a death-ended enrolment to the patient's other enrolments
or events: a later enrolment of a patient whose earlier enrolment ended in death, or any event dated
after that death, passes.

Proposal: a patient-level rule flagging, for a patient with an enrolment whose surveillance-end reason
is death, every other enrolment dated on or after that end date and every event of any type dated
after it. A procedure dated on the death day itself is indistinguishable from a post-mortem one and
stays a judgement. Who acts: the partner; either the death date or the later record is wrong, and both
are on their forms. Not decided.

### G7 — The same infection type repeated within 14 days

`sec-collect-infection-data-collection`.

The same type of infection is registered again only after a minimum of 14 days and a symptom-free
period, and a new pathogen isolated in the same organ system during a recorded infection is not a new
infection. The four infection stages are repeatable with no interval, and no program rule or post-hoc
rule looks at the distance between two events of the same type for one patient. Rules 12 to 15
compare an event with its enrolment, rule 17 compares enrolments, rule 19 an SSI with procedures; none
compares two infection events.

Proposal: an event-level rule flagging, per patient and event type across all of the patient's
enrolments, the later of two consecutive events of the same type fewer than 14 days apart. The
symptom-free period is a judgement and stays unchecked. Who acts: the partner. Not decided.

### G8 — Device association without device days

`tbl-infection-device-relationship`, `dd-cvc-associated-bsi`, `dd-pvc-associated-bsi`,
`dd-inv-associated-pneumonia`, `dd-niv-associated-pneumonia`, `sec-def-pneumonia`,
`sec-analysis-device-associated-infections`.

An infection is device-associated when the device had been in place for at least three consecutive
days on the day of infection or the day before; a device-associated pneumonia additionally requires
ventilation for at least four calendar days. The dataset records no daily device timeline, only the
association on the infection form (`sepsisData$dev_ass`, `pneumoniaData$dev_ass`) and the enrolment's
cumulative device days on the surveillance-end form, so the day-level criterion itself cannot be
re-derived. Its necessary consequence can: a CVC-associated BSI on an enrolment whose CVC days are
zero, or an INV-associated pneumonia on an enrolment without a day of invasive ventilation, is a
visible contradiction. No program rule variable reads the surveillance-end stage (the admission stage
is read that way, so it is possible), and one that did would see only a count entered before the
infection form was last saved, so the check belongs post hoc; no post-hoc rule joins an infection
form to the surveillance-end form.

Proposal: an event-level rule on the sepsis and pneumonia forms flagging an association whose device
has zero or missing days on the enrolment's surveillance-end form. Whether the bound should be the
protocol's three days (four for a ventilated pneumonia) rather than one is for the protocol authority:
a device placed before a transfer contributes days this enrolment does not count, and a day with fewer
than twelve hours of device use is not a device day, so the higher bound can flag legitimate records.
The rule skips an enrolment without a completed surveillance-end form. Who acts: the partner; the
association and the day counts are both on their forms. Not decided.

### G9 — A cumulative day count exceeding the patient days

`dd-patient-days`, `dd-antibiotic-days-total`, `sec-analysis-device-utilization`,
`sec-analysis-antibiotic-use`, `sec-analysis-protective-factor-implementation`, `abbr-inv`, `abbr-niv`.

Every cumulative count on the surveillance-end form (CVC, PVC, INV, NIV, human milk, kangaroo care,
probiotic and antibiotic days) is a count of patient days and cannot exceed the patient days. Nine
program rules (`NEOIPC_SURV_END_*_DAYS_VR`) refuse exactly that at entry, with an error action, and
one of them also refuses a sum of INV and NIV days above the patient days; that bound is the
configuration's, not the protocol's, since the dictionary counts a day with twelve hours of each
support as both an INV day and an NIV day. Rule 18 pins the patient days to the enrolment's dates but
no post-hoc rule compares another count with them, so an API import can carry a count above the
patient days into every rate.

Proposal: an enrolment-level rule on the surveillance-end form flagging each count that exceeds the
patient days; the sum of INV and NIV days only if the protocol authority confirms the bound. Who acts: the partner; opening the form re-runs
the error rules, so the fix is forced on the next save. Not decided.

### G10 — The antibiotic substance slots

`dd-antibiotic-days-per-substance`, `sec-analysis-antibiotic-use`.

Each recorded substance carries its days; a substance day is an antibiotic day, so no substance's
days exceed the total antibiotic days, no substance is recorded without antibiotic days, and no days
are recorded without a substance. Rule 21 flags only the shortfall (the substance days summing to less
than the antibiotic days) on forms with antibiotic days, and the capture-time rules only hide, require
and sum the slots. A substance with no days, days with no substance, the same substance in two slots,
a substance whose days exceed the antibiotic days or the patient days, and a substance on a form with
zero antibiotic days are all invisible post hoc. All of them are on the form: a substance recorded on
a form whose total antibiotic days are zero sits in a slot the rules hide, but a field that holds a
value is never hidden, so the team sees it, read-only while the event is completed, and the client
blanks it on the next edit.

Proposal: extend rule 21, or add a sibling on the `substanceDays` rows, to flag each of those shapes
with the slot's index, substance and days as context. Who acts: the partner. Not decided.

### G11 — A compulsory value missing from a completed form

`sec-collect-master-data-collection-sheet`, `sec-collect-progress-chart`, `dd-admission-date`,
`dd-procedure-description`, `sec-def-surgical-site-infection`, `dd-respiratory-support-increase`,
`dd-ssi-type`, `sec-dd-general-infection-data`, `abbr-ichi`, `abbr-asa`, `abbr-csf`.

The data dictionary's required fields are enforced by the compulsory flag in
`programStageDataElements.csv` and by mandatory-field program rules, which an API import bypasses.
Post hoc only rule 18 flags a missing count (the patient days); the other eight day counts, the
surgery form's main procedure code and description, the SSI type, the secondary-BSI item, the
pneumonia imaging and respiratory-support booleans, a pathogen's source once a pathogen is set, and every other compulsory
value can be absent from a completed form unseen. Rule 22 filters missing codes out before its
grammar check; rule 19 deliberately tolerates a missing SSI type; rule 26 flags a missing admission
form only on a completed enrolment, although the form is auto-generated at enrolment.

Proposal: one event-level completeness rule flagging a completed form that lacks a value its stage
marks compulsory, with the form and field as context. The rule needs the compulsory flags in the
dataset, which the import does not carry today, or a list fixed in the package that the metadata
tests keep aligned. Who acts: the partner; the form refuses to save without the value once it is
opened. Not decided.

### G12 — Secondary bloodstream infection consistency

`sec-dd-general-infection-data`, `sec-collect-secondary-bloodstream-infection`.

Secondary-BSI organisms are recorded only when the secondary-BSI item is Yes, and then at least one;
at least one of them matches an organism identified at the primary infection site. The first is
enforced by hide and mandatory-field program rules only; the dataset holds both sides
(`infectiousAgentFindings$secondary_bsi` against the form's `sec_bsi`) and nothing compares them. The
second is enforced nowhere: the primary and secondary findings of a pneumonia or an SSI sit on the
same event and no rule relates them. NEC records no primary-site organisms, so the match cannot be
assessed there. The shapes of the first differ in who can see them. On an SSI the organisms recorded
while the item is No or No follow-up sit in a section the rule hides together with its fields, so
they are invisible while the event is completed and removed by the client on the next edit. On a
pneumonia or a NEC the same organisms sit in hidden fields, which the form still shows while they
hold a value, read-only on a completed event and blanked on the next edit. Yes without an organism is
a mandatory field left empty on a visible form.

Proposal: a reconciliation for organisms under an SSI's secondary-BSI item that is not Yes (a
contradiction under the protocol; the later value wins, which is also what the client does when the
event is next edited), an event-level rule flagging the same shape on a pneumonia or a NEC and Yes
without an organism on any of the three, and a second rule flagging a pneumonia or SSI whose secondary
findings share no organism with its primary findings. The match compares catalogue keys; a
genus-level entry against a species-level one does not match, which is a limit to state on the rule.
Who acts: the network for the SSI's hidden organisms, the partner for the rest. Not decided.

### G13 — A revision procedure ends the earlier follow-up

`sec-def-surgical-site-infection`, `dd-revision-procedure`.

A revision procedure in the same area ends the SSI follow-up of the earlier procedure and starts its
own. Rule 19 never shortens a window: with a procedure with implant, a revision without implant twenty
days later and a deep SSI on day sixty, the SSI is covered by the first procedure's ninety days
although its follow-up ended at the revision and the revision's own thirty days have passed.
`surgeryData$revision_procedure` is read by no rule.

Proposal: extend rule 19 so that a procedure's window ends the day before the patient's next
procedure flagged as a revision. "In the same area" is not recorded; the extension assumes a revision
revises the most recent earlier procedure and says so. Who acts: the partner, who corrects the
procedure's revision flag or the SSI. Not decided.

### G14 — Infection present at the time of surgery without recorded signs

`dd-signs-of-infection`.

When an SSI occurs, the signs of infection recorded on the procedure determine whether "infection
present at time of surgery" applies. The SSI form's flag is compulsory but nothing relates it to the
procedure's free-text signs. A weak consistency check is possible (the flag set while no procedure
covering the SSI under rule 19's windows carries any signs); the judgement behind the flag is not.
Documented here rather than proposed, since the signs field is free text and optional.

### G15 — The infection definitions are enforced at capture only

`sec-def-primary-sepsis-bloodstream-infection`, `def-clinical-sepsis`, `def-lcbsi-pathogen`,
`sec-def-lcbsi-caused-common-commensals`, `def-lcbsi-cc-twice`, `def-lcbsi-cc-lab-finding`,
`def-lcbsi-cc-treatment`, `sec-def-necrotizing-enterocolitis`, `def-nec-symptom`, `def-nec-surgical`,
`def-pneumonia`, `sec-def-pneumonia`, `sec-def-surgical-site-infection`,
`sec-def-superficial-incisional-ssi`, `def-ssi-superficial`, `sec-def-deep-incisional-ssi`,
`def-ssi-deep`, `sec-def-organ-space-ssi`, `def-ssi-organ-space`, `dd-iv-antibiotic-initiated`,
`dd-organisms-lower-rt`, `dd-organisms-upper-rt`, `abbr-lcbsi`, `sec-agent-list`.

Every infection definition is enforced by an error-on-complete program rule: `NEOIPC_BSI_CLIN_SEPSIS_VR`
and the two `NEOIPC_BSI_LCBSI_CC_*_VR` rules for the three sepsis definitions, `NEOIPC_NEC_VR`,
`NEOIPC_HAP_DEFINITION_VR`, and the three `NEOIPC_SSI_*_VR` rules, each counting the recorded findings
the way its definition does, with assign rules deriving the counts, the recognized-pathogen and
common-commensal classification and the organism criterion. A form whose findings do not meet its
definition cannot be completed in the user interface. No post-hoc rule re-evaluates any definition:
rules 7 to 11 read only the completion status, rules 12 to 15 and 27 to 42 only dates and day counts
and, for rules 30, 34 and 38, the admission type.
A record entered through the API, or completed before a definition rule changed, can therefore hold an
infection that meets no definition, and the BSI form can be neither clinical sepsis nor
laboratory-confirmed (no positive-culture flag and no organism) or both. Every input the client counts
is in the dataset: the sepsis, NEC, pneumonia and SSI booleans, the organism findings with their
source and the multiple-specimen flag, the antibiotic-treatment flag, and the common-commensal
classification through `is_cc` in the package's pathogen catalogue.

For data entered through the interface a definition fails in only one way: residue. A culture-negative
sepsis with an organism the hidden section kept, or findings of another depth than the SSI's recorded
type, are contradictions under the protocol, invisible in the form, and reconcilable by the later
value. What a mirror rule finds after that reconciliation is a form an import or an earlier client left
in a state the definitions do not admit, which the team can see and complete.

Proposal: the reconciliation of the residue shapes first; then five event-level rules mirroring the
client's definition checks, one per stage, so that a form whose recorded findings meet no definition
of its type is a finding. The alternative is to leave the definitions to capture time and record that
an API import is not held to them. Who acts: the network for the residue, the partner for what
remains. Not decided.

### G16 — Resistance categories that do not apply to the organism

`dd-mdros`, `sec-dd-general-infection-data`, `abbr-3gcr`, `abbr-mrsa`, `abbr-vre`, `sec-agent-list`.

For each isolated organism the applicable resistance categories are recorded, and only those. The
protocol restricts three of them by organism: MRSA to *Staphylococcus aureus*, VRE to enterococci,
3GCR to gram-negative organisms; the carbapenem and colistin categories it defines by the laboratory's
cut-off values alone, and their restriction to gram-negative organisms is the configuration's, drawn
from the "Recorded Resistances" column of the List of Infectious Agents. At capture a triple of
program rules per pathogen slot derives the applicability from an organism-id list embedded in the
expression, makes the applicable category mandatory and hides the others. Post hoc nothing reads a
resistance value against the organism, and the Partner Report's resistance-test table filters on the
recorded values only, which is correct for data entered in the user interface and wrong for an import
that recorded a category the organism cannot carry, or for a value that stayed in the hidden field when
the organism was changed after the category was entered. Such a value can never be right; the form
shows it read-only on a completed event and the client removes it on the next edit, so dropping it is
a reconciliation that needs no timestamp and applies the client's own rule to records the client
never re-processed. The reconciliation is not included: neoipcr's applicability flags come from the
legacy pathogen CSVs, the canonical source is
`metadata/common/infectious-agents/NeoIPC-Infectious-Agents.yaml`, the two disagree for some organisms
(the enterococci among them), and the package does not read the applicability from the YAML through
its pathogen taxonomy, which the reconciliation needs. Who acts: the network.

### G17 — Gestational age text and total days

`dd-ga`.

Gestational age is recorded as completed weeks plus days (`25+4`) and, in a second attribute, as
total days, which the client computes with an assign rule after checking the format with an error
rule. An API import must supply both, and nothing post hoc checks the text's format or that the two
agree.

Proposal: a patient-level rule flagging a gestational age that does not match the client's pattern
(`^[2-4][0-9][+][0-6]$`) for the partner, and a reconciliation recomputing the total days from the text
whenever the two differ or the total is missing: the total is displayed, but the client overwrites it
from the text on every save, so a disagreement is the client's, not the team's. Who acts: the partner
for the text, the network for the total. Not decided.

### G18 — Number of infants at birth below two

`dd-number-of-infants-at-birth`.

The number of infants at birth is recorded for a multiple birth and is then at least two. The field is
mandatory when the multiple-birth flag is set and hidden otherwise, but its type admits 1 and nothing
rejects it. The dataset carries `patients$siblings` but not the multiple-birth flag.

Proposal: a patient-level rule flagging a recorded number below two; a small rule, or a case of a
patient-consistency rule if G3 and G17 are taken together. Who acts: the partner. Not decided.

### G19 — A substance code outside the catalogue

`sec-analysis-antibiotic-use`, `sec-ab-list`.

The recordable substances are those of the List of Antibiotics, bounded at entry by the generated
option set `NEOIPC_ANTIMICROBIAL_SUBSTANCES`. Post hoc the denominator calculation inner-joins the
substance code to that option set as imported from the instance and silently drops a code the set no
longer carries or one written outside it through the API; nothing flags such a code. (Rule 20 is not
the analogue: it flags the explicit "not listed" organism entry, which the partner resolves.)

Proposal: a detection of a `substanceDays` row whose code is absent from the imported option set,
reported to the network without repair. Who acts: the network; such a code is a catalogue or migration
problem, not a data-entry one. Not decided.

### G20 — A procedure code that maps to no category

`sec-analysis-surgical-site-infections`.

SSI rates are calculated per procedure category, and every procedure has one. Rules 22 to 24 check
the grammar of the ICHI (International Classification of Health Interventions) code only, since the
classification is not bundled; a well-formed code that
`get_procedure_category()` cannot map falls into "to be categorized" and is rated only in the overall
SSI rate. Documented here: the category map is the package's, and an unmapped code is a gap in the map
rather than in the record, so it is better closed by extending the map than by flagging the record.

### G21 — The scope of NeoIPC-ID uniqueness

`dd-neoipc-id`, `sec-collect-pseudonymization-table`.

The data dictionary calls the NeoIPC-ID the unique id for tracking in the reporting platform without
qualifying the scope; the pseudonymization section speaks of identifying the patient within the
department; the attribute is unique within the organisation unit (`orgunitScope`), which is what
DHIS2 enforces. A duplicate across two departments is allowed and checked by nothing. Sites assign the
ids independently, so a platform-wide check would flag coincidences; the protocol should state the
scope it means. A question for the protocol authority rather than a rule.

### G22 — The data-entry deadline

`sec-mgmt-data-submission`.

Data entry for patients whose surveillance ended in a calendar year is complete six weeks after the
end of that year. The deadline is not modelled; what a pass run after it sees is the incomplete
entry itself: rule 25 (completed enrolment without an end form), rule 6 (end form not completed),
rule 2 (active enrolment with a completed end form), rules 43 and 44 (enrolments open beyond 120
days). Running `validate()` after the deadline with `as_of` set to it lists what is still open; a
dedicated rule would only re-express those with a calendar filter. Documented.

### G23 — The 72-hour window as days of life

`sec-collect-infection-data-collection`.

An infection whose first symptoms occur within 72 hours after birth is not recorded in the core
module. Rules 29, 33 and 37 flag a BSI, pneumonia or NEC on a day of life below 4, with the day of
birth as day 1; the data model has calendar days, not hours, so this is the closest reading, and an
infant born late in the day reaches day 4 well before 72 hours have passed. SSI is deliberately
outside the rule: a surgical site infection is hospital-acquired by its nature. The protocol should
state the window in days of life, as the rules apply it. Documented.

### G24 — Completeness beyond the record set

`sec-collect`, `sec-collect-patient-data-collection`, `sec-collect-master-data-collection-sheet`,
`sec-collect-progress-chart`, `sec-collect-surgical-procedure-data-collection`,
`sec-collect-infection-data-collection`, `sec-collect-primary-sepsis-bsi`,
`sec-collect-necrotizing-enterocolitis`, `sec-collect-pneumonia`, `sec-collect-surgical-site-infections`,
`dd-surveillance-end-date`, `dd-procedure-date`, `dd-main-procedure-code`, `dd-side-procedure-code`,
`dd-infection-date`, `sec-analysis-standardized-infection-rate`, `abbr-ichi`.

The protocol requires every eligible patient, admission, procedure and infection to be recorded and
every date to be the true one. A post-hoc pass sees only what was recorded: an admission never
enrolled, a procedure never entered, an infection never documented, or a date that is wrong but
consistent with every other date, leaves no trace. What it does see is flagged: a registered patient
without an enrolment (rule 1), a form left uncompleted on a closed record (rules 5 to 11), a completed
enrolment without its admission or end form (rules 25 and 26), an SSI that no recorded procedure
covers (rule 19), an enrolment left open beyond 120 days (rules 43 and 44), an event outside its
enrolment (rules 12 to 15), and day counts that disagree with the dates (rules 18, 27 to 42). The paper
progress chart is not submitted, so its totals cannot be compared with the surveillance-end form. The
rows marked partial under this entry are partial by nature; no rule can close them.

## Questions for the protocol authority

The audit surfaces the following points where the protocol text, the configuration and the rules do
not say the same thing, or where a rule encodes a reading the protocol does not settle. None is
changed here; the protocol is normative and a conflict between it and the code is fixed in the code.

- **Rules 30, 34 and 38** flag a sepsis, pneumonia or NEC on day 1 or 2 of the stay of a referred or
  readmitted patient without looking at prior enrolments. A patient discharged and readmitted the
  next day with an event on day 2 of the new stay is flagged, although the infection most likely
  belongs to the previous stay rather than being community-acquired; the finding's framing can lead a
  reviewer to recode rather than to attribute it to the earlier enrolment. Whether to suppress the
  finding when a prior enrolment of the patient ended within a few days of this admission, or to split
  the rule between true referrals and readmissions, is the authority's call; the rules keep the blunt
  filter until then.
- **Rules 43 and 44** question an enrolment still active more than 120 days after its enrolment date.
  The protocol defines the end of surveillance as death, transfer or discharge and sets no maximum
  stay, so the threshold is a plausibility threshold, not a protocol rule, and a genuinely long stay
  is exempted through the exception list. Whether the protocol should state such a threshold is open.
- **The eligibility wording** in the introduction ("above 1500 g", "greater than 32 weeks") assigns
  an infant of exactly 1500 g or exactly 32 weeks 0 days to no module, while the criteria section and
  the examples table exclude such an infant from the core module (`sec-intro-what-you-reading-here`
  against `sec-collect-case-eligibility-criteria-core`).
- **The readmission type** is named "transferred to your centre ≥ 24h postnatal" in
  `sec-collect-progress-chart`, an hours criterion, while `dd-admission-type` and the option set
  define it as "the day after birth or later", a calendar-day criterion, with the middle value "on the
  day of birth"; the two readings diverge around midnight, and the collection section should quote
  the dictionary's value.
- **The secondary-BSI window** is defined twice: `sec-collect-secondary-bloodstream-infection`
  counts it from the day of first symptoms or of the first positive culture at the primary site,
  `dd-secondary-bloodstream-infection` from the first symptoms only.
- **"Within 120 days of birth"** admits day of life 121 on a literal reading, which the examples
  table excludes (G2).
- **The SSI follow-up overview** states 30 or 90 days by implant alone (`sec-collect`,
  `sec-collect-surgical-procedure-data-collection`), while the definitions restrict the 90 days to deep
  incisional and organ/space infections; rule 19 follows the definitions.
- **Device association** is counted cumulatively in the example table ("≥ 3 CVC days on the day of
  infection", `tbl-infection-device-relationship`) and as consecutive days in the data dictionary
  (`dd-cvc-associated-bsi` and its siblings); the readings diverge when a device is removed and
  re-inserted.
- **A device-associated pneumonia** requires ventilation for at least four calendar days in
  `sec-def-pneumonia` and `dd-respiratory-support-increase`, while `dd-inv-associated-pneumonia`,
  `dd-niv-associated-pneumonia` and the data element's own description require three consecutive days
  on the day of infection or the day before; the dictionary carries both readings.
- **The NEC section** says the dataset records whether the patient has an intestinal perforation
  (`sec-def-necrotizing-enterocolitis`); no element of that name exists, and the nearest, the
  pneumoperitoneum imaging finding, is itself a definition criterion. The authority should say whether
  that is the referent, add the element, or drop the sentence. The same section's symptom-based
  criteria admit a spontaneous intestinal perforation (pneumoperitoneum with distension) that the
  prose says not to record as NEC.
- **The admission date** is defined as the day of admission to the hospital (`dd-admission-date`),
  while patient days count the stay in the department (`dd-patient-days`); the two diverge for an
  infant admitted to the unit after a stay elsewhere in the hospital, and rules 3 and 18 hold the
  admission date and the patient days to the enrolment date. The dictionary also leaves open whether
  the days of a short absence of up to two days count as patient days; rule 18 counts them.
- **The sum of INV and NIV days** is held to the patient days by `NEOIPC_SURV_END_NIV_INV_DAYS_VR`, a
  bound the protocol does not state: under the dictionary a day with twelve hours of each support is
  both an INV day and an NIV day (G9).
- **The surveillance-end reason** that `sec-collect-progress-chart` names for a long absence,
  "transfer", is not a distinct value in the protocol's own dictionary, which offers "Discharge or
  transfer" and "Death", nor in the option set that mirrors it; the collection section should quote
  the merged value or the dictionary should split it (G5).
- **The NeoIPC-ID's scope** is platform-wide in one place and department-wide in another (G21).
- **The 72-hour cut-off** is applied as days of life 1 to 3 (G23).
- **The birth-weight strata** are written as below 500 g, 500 to 999 g, 1000 to 1499 g and above
  1500 g, which leaves exactly 1500 g in no stratum (`sec-analysis`), and the standardized infection
  rate section speaks of three classes where the chapter lists four
  (`sec-analysis-standardized-infection-rate`).
- **The antibiotic-use formulas** multiply by 100 where the prose says per 1000 patient days, and the
  proportion of patients receiving a substance is written as therapy days over patient days where the
  prose defines patients over patients (`sec-analysis-antibiotic-use`).

## Defects in the capture-time configuration

Two findings concern the DHIS2 configuration rather than the rules; they are recorded here because a
row's enforcement column depends on them.

- `NEOIPC_SSI_SUPERFICIAL_INFECTION` references the program rule variables "NeoIPC SSI Infection
  involves skin value", "… deep soft tissues value" and "… parts deeper than fascial muscular layers
  value", and `programRuleVariables.csv` defines none of them, so the rule never evaluates true and its
  two hide-field actions are dead. The SSI depth is enforced by `NEOIPC_SSI_INFECTION_TYPE_*` instead;
  the dead rule enforces nothing and should be repaired or removed.
- `NEOIPC_ADM_DOL_VAL_150_PLUS` warns at a day of life of 150 or more; the eligibility limit is 120
  (G2).

## Not included: resistance-category applicability

The reconciliation that would drop a resistance value recorded for an organism the category does not
apply to is not included; G16 states what it needs and why the Partner Report's resistance-test
table meanwhile filters on the recorded values.

## Inventory

### Licensing and attribution (`sec-licence`)

Five statements on the licences of the protocol text and its two appendix lists. None constrains a
record; none is checkable.

### 1.1 What are you reading here? (`sec-intro-what-you-reading-here`)

| Anchor | Constraint | Enforcement | Rules | Capture-time | Gap |
|---|---|---|---|---|---|
| `sec-intro-what-you-reading-here` | *(derived)* Infants with a birth weight above 1500 g and a gestational age greater than 32 weeks are outside the core module and belong to other NeoIPC modules. | Capture time | — | `NEOIPC_PATIENT_BW_1500_GRAMS_AND_GA_32_PLUS_WEEKS` | G1 |

### 1.4 Advice for Use and Requirements for Participation (`sec-intro-participation`)

Six process obligations: acceptance of the definitions by the team, regular submission, privacy and
security policies, no personal information sent to the network, confidentiality of disaggregated
data. None constrains a record; none is checkable.

### 2.1 Data Protection and Security (`sec-mgmt-data-protection-security`, `sec-mgmt-patient-information`, `sec-mgmt-hospital-information`)

Six process obligations on lawfulness, storage and transmission of identifying information, the
re-identification risk of rare birth weights or gestational ages, and hospital-level anonymity in
publications. None constrains a record; none is checkable.

### 2.2 Data Submission (`sec-mgmt-data-submission`)

| Anchor | Constraint | Enforcement | Rules | Capture-time | Gap |
|---|---|---|---|---|---|
| `sec-mgmt-data-submission` | Submitting data to NeoIPC or a regional network is optional: the NeoIPC tools and methods may be used for departmental surveillance without submitting any information. | Not checkable | — | — |  |
| `sec-mgmt-data-submission` | The reference report is calculated once a year at a specified time from the data present in the NeoIPC database at that moment, so data for patients whose surveillance ended in the previous year that is not entered by that time is absent from that year's reference report (the mechanism behind the six-week deadline). | Not checkable | — | — |  |
| `sec-mgmt-data-submission` | *(derived)* Data submitted to NeoIPC is submitted through the DHIS2-based web reporting system. | Not checkable | — | — |  |
| `sec-mgmt-data-submission` | All data entry and completion of missing information for patients whose surveillance period ended in a calendar year is finished within 6 weeks after the end of that year. | Partial | 2, 6, 25, 43, 44 | — | G22 |
| `sec-mgmt-data-submission` | During an outage of the web reporting system data is documented on the paper datasheets and entered into the platform as soon as it is available again. | Not checkable | — | — |  |

### 3 Data Collection (`sec-collect`)

| Anchor | Constraint | Enforcement | Rules | Capture-time | Gap |
|---|---|---|---|---|---|
| `sec-collect` | *(derived)* Data collection takes place at the patient's bedside during the inpatient stay. | Not checkable | — | — |  |
| `sec-collect` | Every eligible patient has both a master data collection sheet and a patient progress chart completed. | Partial | 5, 6, 25, 26 | `NEOIPC_STG_ADM` autoGenerateEvent, `NEOIPC_ADMISSION_TYPE` compulsory, `NEOIPC_SURVEILLANCE_END_REASON` compulsory | G24 |
| `sec-collect` | Every eligible patient who undergoes a surgical procedure has a surgical procedure data collection form completed. | Partial | 19 | — | G24 |
| `sec-collect` | Every healthcare-associated infection an eligible infant develops within the follow-up period has the corresponding infection data collection sheet completed. | Partial | 7, 8, 9, 11 | `NEOIPC_BSI_CLIN_SEPSIS_VR`, `NEOIPC_BSI_LCBSI_CC_MULT_OR_AB_5D_VR`, `NEOIPC_BSI_LCBSI_CC_ONCE_NO_AB_VR`, `NEOIPC_NEC_VR`, `NEOIPC_HAP_DEFINITION_VR`, `NEOIPC_SSI_SUPERFICIAL_INCISIONAL_VR`, `NEOIPC_SSI_DEEP_INCISIONAL_VR`, `NEOIPC_SSI_ORGAN_SPACE_VR` | G24 |
| `sec-collect` | A recorded infection is one of bloodstream infection, pneumonia, necrotizing enterocolitis or surgical site infection. | Capture time | — | `NEOIPC_STG_BSI`, `NEOIPC_STG_HAP`, `NEOIPC_STG_NEC`, `NEOIPC_STG_SSI` |  |
| `sec-collect` | Only infections of the listed types that were acquired in a participating neonatology department are recorded. | Partial | 12, 13, 14, 29, 30, 33, 34, 37, 38 | `NEOIPC_BSI_LOS_LESS_THAN_2`, `NEOIPC_HAP_LOS_LESS_THAN_2`, `NEOIPC_NEC_LOS_LESS_THAN_2` | G24 |
| `sec-collect` | Every eligible infant is observed until the end of its surveillance period. | Partial | 43, 44 | — | G24 |
| `sec-collect` | The surveillance period ends when the infant dies, is transferred, or is discharged from the hospital. | Capture time | — | `NEOIPC_SURVEILLANCE_END_REASON` compulsory, option set `NEOIPC_SURVEILLANCE_END_REASON` | G6 |
| `sec-collect` | A patient with a surgical procedure is followed up for SSI for 30 days, or 90 days when an implant is present (rule 19 follows the definitions, which grant the 90 days to deep incisional and organ/space infections only; see the questions below). | Covered | 19 | — |  |

### 3.1 Case Eligibility Criteria for the Core Module (`sec-collect-case-eligibility-criteria-core`)

| Anchor | Constraint | Enforcement | Rules | Capture-time | Gap |
|---|---|---|---|---|---|
| `sec-collect-case-eligibility-criteria-core` | An eligible infant is live born. | Not checkable | — | — |  |
| `sec-collect-case-eligibility-criteria-core` | An infant qualifies on birth weight when the birth weight is less than 1500 grams. | Capture time | — | `NEOIPC_PATIENT_BW_1500_GRAMS_AND_GA_32_PLUS_WEEKS`, `NEOIPC_PATIENT_BW_MANDATORY_IF_GA_MISSING_REGULAR`, `NEOIPC_PATIENT_GA_MANDATORY_IF_BW_MISSING_REGULAR`, `NEOIPC_PATIENT_BW_AND_GA_MANDATORY_NEODECO` | G1 |
| `sec-collect-case-eligibility-criteria-core` | An infant qualifies on gestational age when the gestational age is less than 32 weeks, i.e. at most 31 weeks 6 days. | Capture time | — | `NEOIPC_PATIENT_BW_1500_GRAMS_AND_GA_32_PLUS_WEEKS`, `NEOIPC_PATIENT_GA_FORMAT_VR`, `NEOIPC_PATIENT_SET_TOTAL_GESTATION_DAYS` | G1 |
| `sec-collect-case-eligibility-criteria-core` | An eligible infant is admitted to a ward of the neonatal department within 120 days of birth. | Not covered | — | `NEOIPC_ADM_DOL_VAL_150_PLUS` (warning only), `NEOIPC_ADM_TYPE_1`, `NEOIPC_ADM_TYPE_2_PLUS` | G2 |
| `sec-collect-case-eligibility-criteria-core` | *(derived)* The "within 120 days of birth" window is operationalized by the examples table as admission on day of life at most 120, the day of birth being day 1; a literal reading would admit day 121. | Not covered | — | `NEOIPC_ADM_DOL_VAL_150_PLUS` (warning only), `NEOIPC_ADM_DOL_1` | G2 |
| `tbl-eligibility-examples` | *(derived)* Birth weight below 1500 g and gestational age below 32 weeks are alternative criteria, so an infant meeting only one of them is eligible. | Capture time | — | `NEOIPC_PATIENT_BW_1500_GRAMS_AND_GA_32_PLUS_WEEKS` | G1 |
| `tbl-eligibility-examples` | *(derived)* Admission on day of life 120 is eligible and day 121 is not; 1499 g qualifies and 1500 g does not; 31+6 qualifies and 32+0 does not. | Not covered | — | `NEOIPC_PATIENT_BW_1500_GRAMS_AND_GA_32_PLUS_WEEKS`, `NEOIPC_ADM_DOL_VAL_150_PLUS` (warning only) | G1, G2 |

### 3.2 Patient Data Collection (`sec-collect-patient-data-collection`)

| Anchor | Constraint | Enforcement | Rules | Capture-time | Gap |
|---|---|---|---|---|---|
| `sec-collect-patient-data-collection` | Each admission or readmission of an eligible patient to a ward of the neonatology department results in an enrolment. | Partial | 1 | program `NEOIPC_CORE` onlyEnrollOnce=false | G24 |

### 3.2.1 Pseudonymization Table (`sec-collect-pseudonymization-table`)

| Anchor | Constraint | Enforcement | Rules | Capture-time | Gap |
|---|---|---|---|---|---|
| `sec-collect-pseudonymization-table` | NeoIPC does not track individual patients for reference-report generation and does not use the assigned NeoIPC-IDs in any way, so the NeoIPC-ID serves the centre's own patient retrieval only. | Not checkable | — | — |  |
| `sec-collect-pseudonymization-table` | Where patients must be unambiguously identifiable in the platform, each patient is assigned a NeoIPC-ID at the time of enrolment. | Capture time | — | `NEOIPC_PATIENT_ID` mandatory program attribute |  |
| `sec-collect-pseudonymization-table` | A NeoIPC-ID is a unique random identifier that identifies the patient only within the department. | Capture time | — | `NEOIPC_PATIENT_ID` unique, orgunitScope | G21 |
| `sec-collect-pseudonymization-table` | Each patient has exactly one NeoIPC identification number. | Not checkable | — | `NEOIPC_PATIENT_ID` unique, orgunitScope |  |
| `sec-collect-pseudonymization-table` | A patient's follow-up ends at discharge and a readmission is recorded as a new enrolment. | Partial | 17, 43, 44 | — | G5 |
| `sec-collect-pseudonymization-table` | A readmitted patient's new enrolment carries the same NeoIPC-ID as the earlier enrolment. | Not checkable | — | `NEOIPC_PATIENT_ID` unique, orgunitScope |  |
| `sec-collect-pseudonymization-table` | The centre organizes retrieval of patient data based on the unique NeoIPC-IDs. | Not checkable | — | — |  |
| `sec-collect-pseudonymization-table` | *(derived)* A pseudonymization list linking each NeoIPC-ID to identifying information is kept, or that information is noted on the paper master data sheet. | Not checkable | — | — |  |
| `sec-collect-pseudonymization-table` | The pseudonymization list and paper sheets are stored under the same conditions as secret patient healthcare data and securely destroyed once no longer needed. | Not checkable | — | — |  |
| `sec-collect-pseudonymization-table` | A NeoIPC-ID is not an identifier used in any context outside NeoIPC surveillance, such as the hospital patient id, the patient name or any other identifier used elsewhere. | Not checkable | — | — |  |
| `tbl-pseudonymization-example` | *(derived)* A pseudonymization list holds a running number, NeoIPC-ID, hospital patient ID, patient name, date of birth and comments per patient. | Not checkable | — | — |  |

### 3.2.2 Master Data Collection Sheet (`sec-collect-master-data-collection-sheet`)

| Anchor | Constraint | Enforcement | Rules | Capture-time | Gap |
|---|---|---|---|---|---|
| `sec-collect-master-data-collection-sheet` | Each admission or readmission of an eligible patient to the neonatology department results in an enrolment. | Partial | 1 | program `NEOIPC_CORE` onlyEnrollOnce=false | G24 |
| `sec-collect-master-data-collection-sheet` | An enrolled patient has admission information entered and follow-up data collected on patient progress charts. | Partial | 5, 26 | `NEOIPC_STG_ADM` autoGenerateEvent, openAfterEnrollment; `NEOIPC_ADMISSION_TYPE` compulsory; `NEOIPC_ADM_TYPE_2_PLUS` | G11 |
| `sec-collect-master-data-collection-sheet` | Follow-up is ended when the patient is discharged, transferred to another hospital or dies. | Partial | 43, 44 | — | G24 |
| `sec-collect-master-data-collection-sheet` | The surveillance-end data on the master data sheet or in the online system equals the totals of the patient progress chart (the chart is not submitted; rules 18 and 21 check the entered totals against the dates and each other, not against the chart). | Not checkable | — | `NEOIPC_SURV_END_*_DAYS_VR`, `NEOIPC_SURV_END_AB_SUBST_DAYS_VR` |  |
| `sec-collect-master-data-collection-sheet` | When data is submitted to NeoIPC, all information collected on the master data collection sheet is entered into the online data entry system. | Not checkable | — | — |  |

### 3.2.3 Patient Progress Chart (`sec-collect-progress-chart`)

| Anchor | Constraint | Enforcement | Rules | Capture-time | Gap |
|---|---|---|---|---|---|
| `sec-collect-progress-chart` | An enrolled eligible patient is followed up with patient progress charts until death, transfer or discharge. | Partial | 43, 44 | — | G24 |
| `sec-collect-progress-chart` | Patient days, device days and antibiotic days are recorded in the progress chart, on a daily basis where possible. | Partial | 18 | the nine `NEOIPC_SURVEILLANCE_END_*_DAYS` counts compulsory | G11 |
| `sec-collect-progress-chart` | The patient progress chart is kept at the facility. | Not checkable | — | — |  |
| `sec-collect-progress-chart` | A patient progress chart exists for every eligible infant throughout the surveillance period. | Not checkable | — | — |  |
| `sec-collect-progress-chart` | One progress chart holds at most six antibiotic substances and further substances are documented on an additional chart. | Not checkable | — | `NEOIPC_SURVEILLANCE_END_AB_SUBST_01` to `_09` |  |
| `sec-collect-progress-chart` | A patient's surveillance-end data is the sum of the data in the patient progress charts (the charts are not submitted; rules 18 and 21 check the entered totals, not the charts). | Not checkable | — | `NEOIPC_SURV_END_*_DAYS_VR`, `NEOIPC_SURV_END_PATIENT_DAYS_SET` |  |
| `sec-collect-progress-chart` | Surveillance-end data is entered in the online reporting platform under the "surveillance end" event. | Covered | 6, 25, 43, 44 | `NEOIPC_STG_SURV_END` |  |
| `sec-collect-progress-chart` | A patient who leaves the department for up to two days (e.g. for surgery) is not treated as transferred or discharged. | Partial | 17 | — | G5 |
| `sec-collect-progress-chart` | The data for days spent outside the department during a short absence is recorded when the patient returns. | Not checkable | — | — |  |
| `sec-collect-progress-chart` | When more than 48 hours pass between transfer and re-admission, data collection ends with "transfer" as the surveillance-end reason. | Not covered | — | option set `NEOIPC_SURVEILLANCE_END_REASON` (no distinct transfer value) | G5 |
| `sec-collect-progress-chart` | A readmission after a more-than-48-hour absence is recorded as a new admission with admission type "transferred to your centre ≥ 24h postnatal". | Not covered | — | `NEOIPC_ADMISSION_TYPE` compulsory, `NEOIPC_ADM_DOL_1` | G4 |

### 3.3 Surgical Procedure Data Collection (`sec-collect-surgical-procedure-data-collection`)

| Anchor | Constraint | Enforcement | Rules | Capture-time | Gap |
|---|---|---|---|---|---|
| `sec-collect-surgical-procedure-data-collection` | Every surgical procedure performed on an eligible infant is recorded. | Partial | 19 | — | G24 |
| `sec-collect-surgical-procedure-data-collection` | After a surgical procedure the infant is followed up for surgical site infections for 30 days, or 90 days when an implant was left in place during the procedure (rule 19 follows the definitions, which grant the 90 days to deep incisional and organ/space infections only). | Covered | 19 | — |  |

### 3.4 Infection Data Collection (`sec-collect-infection-data-collection`)

| Anchor | Constraint | Enforcement | Rules | Capture-time | Gap |
|---|---|---|---|---|---|
| `sec-collect-infection-data-collection` | Hospital-acquired bloodstream infections, pneumonia, NEC and surgical site infections of eligible patients are documented until the end of the surveillance period. | Partial | 12, 13, 14, 19 | — | G24 |
| `sec-collect-infection-data-collection` | An infection whose first symptoms occur within 72 hours after birth is not nosocomial and is not recorded in the core module. | Partial | 29, 33, 37 | `NEOIPC_BSI_DOL_VAL_LESS_THAN_4`, `NEOIPC_HAP_DOL_VAL_LESS_THAN_4`, `NEOIPC_NEC_DOL_VAL_LESS_THAN_4` (warnings only) | G23 |
| `sec-collect-infection-data-collection` | The 72-hour cut-off is ignored when an infection beginning before 72 hours is clearly hospital-acquired or one starting after 72 hours is clearly vertical (the exception list keeps such a record out of the findings of rules 29 to 38). | Not checkable | — | — |  |
| `sec-collect-infection-data-collection` | *(derived)* An infection excluded by the 72-hour cut-off is recorded, if at all, as an early-onset infection in the early-onset module rather than in the core module. | Not checkable | — | — |  |
| `sec-collect-infection-data-collection` | For a transferred or readmitted patient a sepsis, pneumonia or NEC is nosocomial only when the day of symptom onset is on or after day 3 of the hospital stay (an SSI is attributed to its procedure's follow-up window by rule 19, which may span a readmission). | Covered | 30, 34, 38 | `NEOIPC_BSI_LOS_LESS_THAN_2`, `NEOIPC_HAP_LOS_LESS_THAN_2`, `NEOIPC_NEC_LOS_LESS_THAN_2` |  |
| `sec-collect-infection-data-collection` | The day of admission counts as day 1 of the hospital stay. | Covered | 28, 32, 36, 40, 42, 30, 34, 38 | `NEOIPC_ADM_SET_LOS`, `NEOIPC_BSI_SET_LOS`, `NEOIPC_HAP_SET_LOS`, `NEOIPC_NEC_SET_LOS`, `NEOIPC_SURGERY_SET_LOS`, `NEOIPC_SSI_SET_LOS` |  |
| `sec-collect-infection-data-collection` | *(derived)* The elements of an infection definition occur within a 7–10 day timeframe with no more than 2–3 days between elements. | Not checkable | — | — |  |
| `sec-collect-infection-data-collection` | A new pathogen isolated in the same organ system while a recorded infection is present is not recorded as a new infection. | Not covered | — | — | G7 |
| `sec-collect-infection-data-collection` | The same type of infection is registered again only after a minimum of 14 days and a period without relevant symptoms of infection. | Not covered | — | the four infection stages are repeatable without an interval | G7 |

### 3.4.1 to 3.4.4 Primary Sepsis/BSI, NEC, Pneumonia, SSI (`sec-collect-primary-sepsis-bsi`, `sec-collect-necrotizing-enterocolitis`, `sec-collect-pneumonia`, `sec-collect-surgical-site-infections`)

| Anchor | Constraint | Enforcement | Rules | Capture-time | Gap |
|---|---|---|---|---|---|
| `sec-collect-primary-sepsis-bsi` | Each hospital-acquired primary sepsis/BSI meeting the NeoIPC criteria that an eligible infant develops during the surveillance period is recorded and submitted. | Partial | 7 | `NEOIPC_BSI_CLIN_SEPSIS_VR`, `NEOIPC_BSI_LCBSI_CC_MULT_OR_AB_5D_VR`, `NEOIPC_BSI_LCBSI_CC_ONCE_NO_AB_VR` | G24 |
| `sec-collect-necrotizing-enterocolitis` | Each necrotizing enterocolitis meeting the NeoIPC criteria that an eligible infant develops during the surveillance period is recorded and submitted. | Partial | 8 | `NEOIPC_NEC_VR` | G24 |
| `sec-collect-pneumonia` | Each hospital-acquired pneumonia meeting the NeoIPC criteria that an eligible infant develops during the surveillance period is recorded and submitted. | Partial | 9 | `NEOIPC_HAP_DEFINITION_VR` | G24 |
| `sec-collect-surgical-site-infections` | Each surgical site infection meeting the NeoIPC criteria that an eligible infant develops during the surveillance period is recorded and submitted. | Partial | 11, 19 | `NEOIPC_SSI_SUPERFICIAL_INCISIONAL_VR`, `NEOIPC_SSI_DEEP_INCISIONAL_VR`, `NEOIPC_SSI_ORGAN_SPACE_VR` | G24 |

### 3.4.5 Device-associated Infection (`sec-collect-device-associated-infection`)

| Anchor | Constraint | Enforcement | Rules | Capture-time | Gap |
|---|---|---|---|---|---|
| `sec-collect-device-associated-infection` | *(derived)* Infections following intravenous therapy or mechanical ventilation are recorded as device-associated with the vascular catheter or intubation. | Not checkable | — | `NEOIPC_BSI_DEV_ASS` compulsory, `NEOIPC_HAP_DEVICE_ASSOCIATION` compulsory |  |
| `sec-collect-device-associated-infection` | A recorded device association is one of invasive ventilation (INV), non-invasive ventilation (NIV), central venous catheter (CVC) or peripheral venous catheter (PVC). | Capture time | — | option sets `NEOIPC_BSI_DEVICE_ASS`, `NEOIPC_HAP_DEVICE_ASS` |  |
| `sec-collect-device-associated-infection` | Device association is purely time-based: an infection is device-associated only when the device was in use for the defined period before the infection. | Not checkable | — | — |  |
| `sec-collect-device-associated-infection` | A bloodstream infection meeting both PVC and CVC association criteria is recorded as CVC-associated. | Not checkable | — | — |  |
| `sec-collect-device-associated-infection` | A pneumonia during intermittent use of both invasive and non-invasive ventilation is recorded as INV-associated. | Not checkable | — | — |  |
| `tbl-infection-device-relationship` | *(derived)* The example table counts device days cumulatively ("≥ 3 CVC days on the day of infection") whereas the data dictionary requires three consecutive days on the day of infection or the day before; the readings diverge when a device is removed and re-inserted. | Not checkable | — | — |  |
| `tbl-infection-device-relationship` | An infection is device-associated when the device is in place on the day of infection with at least 3 device days accumulated on that day, and not when fewer than 3 device days have accumulated. | Not covered | — | — | G8 |
| `tbl-infection-device-relationship` | An infection is device-associated when no device is in place on the day of infection but at least 3 device days had accumulated on the day before infection. | Not covered | — | — | G8 |
| `tbl-infection-device-relationship` | An infection is not device-associated when the device was in place neither on the day of infection nor on the day before. | Not covered | — | — | G8 |

### 3.4.6 Secondary Bloodstream Infection (`sec-collect-secondary-bloodstream-infection`)

| Anchor | Constraint | Enforcement | Rules | Capture-time | Gap |
|---|---|---|---|---|---|
| `sec-collect-secondary-bloodstream-infection` | A secondary bloodstream infection is recorded only against a pneumonia, NEC or SSI as its primary infection. | Capture time | — | the secondary-BSI item and slots exist on the pneumonia, NEC and SSI stages only; `NEOIPC_HAP_SEC_BSI_VAL_NO_VAL_OR_0`, `NEOIPC_NEC_SEC_BSI_VAL_NO_VAL_OR_0`, `NEOIPC_SSI_NO_SEC_BSI` |  |
| `sec-collect-secondary-bloodstream-infection` | The secondary-BSI item of a pneumonia, NEC or SSI record may be "No follow-up" when the centre does not follow patients for secondary BSI. | Capture time | — | option set `NEOIPC_YES_NO_NO_FOLLOWUP` |  |
| `sec-collect-secondary-bloodstream-infection` | A secondary BSI's blood specimen is collected between 3 days before and 13 days after the day of the primary infection. | Not checkable | — | — |  |
| `sec-collect-secondary-bloodstream-infection` | The day of the primary infection is the day of first symptoms or of the first positive culture at the primary infection site. | Not checkable | — | — |  |
| `sec-collect-secondary-bloodstream-infection` | At least one organism from the secondary BSI blood specimen matches an organism identified at the primary infection site. | Not covered | — | `NEOIPC_HAP_SEC_BSI_VAL_1_PLUS`, `NEOIPC_SSI_HAS_SEC_BSI` (slot 1 mandatory only) | G12 |

### 4.1 Primary Sepsis / Bloodstream Infection (`sec-def-primary-sepsis-bloodstream-infection`)

| Anchor | Constraint | Enforcement | Rules | Capture-time | Gap |
|---|---|---|---|---|---|
| `sec-def-primary-sepsis-bloodstream-infection` | A primary sepsis/BSI is classified as either culture-negative clinical sepsis or culture-proven laboratory-confirmed bloodstream infection (LCBSI). | Interface only | — | `NEOIPC_BSI_UNLESS_NO_POS_CULTURE`, `NEOIPC_BSI_IF_NO_POS_CULTURE`, `NEOIPC_BSI_NO_POS_CULTURE_HIDE_IF_AGENT_RECORDED` | G15 |
| `sec-def-primary-sepsis-bloodstream-infection` | An LCBSI is classified by its culture result as caused by a recognized pathogen or by a common commensal, and the common-commensal category is subject to additional criteria. | Interface only | — | `NEOIPC_BSI_AGENT_n_SET_NCC`, `NEOIPC_BSI_AGENT_IF_NCC`, `NEOIPC_BSI_AGENT_IF_NCC_OR_AB_TREATMENT`, `NEOIPC_BSI_AGENT_IF_NCC_OR_RECOVERED_MULT` | G15 |
| `sec-def-primary-sepsis-bloodstream-infection` | A bloodstream infection whose organism entered the bloodstream from a primary infection site (other than a catheter) is not recorded as primary sepsis/BSI but as a secondary BSI. | Not checkable | — | — |  |
| `sec-def-primary-sepsis-bloodstream-infection` | A primary sepsis/BSI record is of one of exactly two types: clinical sepsis (infection without a detected organism) or laboratory-confirmed bloodstream infection. | Interface only | — | `NEOIPC_BSI_UNLESS_NO_POS_CULTURE`, `NEOIPC_BSI_IF_NO_POS_CULTURE`, `NEOIPC_BSI_NO_POS_CULTURE_HIDE_IF_AGENT_RECORDED` | G15 |
| `sec-def-primary-sepsis-bloodstream-infection` | *(derived)* An infectious agent recorded for a primary sepsis/BSI is taken from the protocol's List of Infectious Agents. | Covered | 20 | `NEOIPC_BSI_AGENT_n_IF_NOT_LISTED`, `NEOIPC_BSI_AGENT_n_NAME_HAS_VAL` |  |

### 4.1.1 Clinical Sepsis (`sec-def-clinical-sepsis`, `def-clinical-sepsis`)

| Anchor | Constraint | Enforcement | Rules | Capture-time | Gap |
|---|---|---|---|---|---|
| `sec-def-clinical-sepsis` | An intravenous antibiotic treatment day count includes both the day of the first dose and the day of the last dose. | Not checkable | — | — |  |
| `sec-def-clinical-sepsis` | Days without a dose between the first and the last dose count as antibiotic treatment days. | Not checkable | — | — |  |
| `sec-def-clinical-sepsis` | Days after the last dose are not counted as antibiotic treatment days. | Not checkable | — | — |  |
| `sec-def-clinical-sepsis` | For a patient who died, was discharged or was transferred before completing five days of intravenous antibiotics, the five-day criterion is met when treatment was scheduled for five days or more. | Not checkable | — | — |  |
| `def-clinical-sepsis` | A clinical sepsis has no positive microbiological blood or cerebrospinal fluid culture. | Interface only | — | `NEOIPC_BSI_IF_NO_POS_CULTURE`, `NEOIPC_BSI_CLIN_SEPSIS_VR` | G15 |
| `def-clinical-sepsis` | A clinical sepsis has intravenous antibiotic treatment of five or more days initiated. | Capture time | — | `NEOIPC_BSI_IF_NO_POS_CULTURE`, `NEOIPC_BSI_CLIN_SEPSIS_VR` | G15 |
| `def-clinical-sepsis` | A clinical sepsis has at least two of the listed clinical or laboratory features of generalized infection. | Capture time | — | `NEOIPC_BSI_CLIN_SEPSIS_VR`, `NEOIPC_BSI_SET_FIRST_FINDING_COUNTS`, `NEOIPC_BSI_SET_COMMON_LAB_FINDINGS_COUNT`, `NEOIPC_BSI_SET_TOTAL_COMMON_FINDING_COUNTS`, the per-finding `NEOIPC_BSI_*_SET_COUNT` rules | G15 |

### 4.1.2 LCBSI caused by a Recognized Pathogen (`sec-def-lcbsi-caused-recognized-pathogen`, `def-lcbsi-pathogen`)

| Anchor | Constraint | Enforcement | Rules | Capture-time | Gap |
|---|---|---|---|---|---|
| `def-lcbsi-pathogen` | *(derived)* An LCBSI with recognized pathogen is defined by the culture result alone: it carries no requirement for features of generalized infection, a second specimen, a laboratory finding or a five-day antibiotic treatment. | Not checkable | — | `NEOIPC_BSI_AGENT_IF_NCC`, `NEOIPC_BSI_AGENT_n_SET_NCC` |  |
| `def-lcbsi-pathogen` | An LCBSI with recognized pathogen has a recognized pathogen recovered from a blood and/or cerebrospinal fluid culture. | Capture time | — | `NEOIPC_BSI_AGENT_n_SET_NCC`, `NEOIPC_BSI_AGENT_IF_NCC`, `NEOIPC_BSI_AGENT_n_IF_SET` (source mandatory) | G15 |

### 4.1.3 LCBSI caused by Common Commensals (`sec-def-lcbsi-caused-common-commensals`, `def-lcbsi-cc-twice`, `def-lcbsi-cc-lab-finding`, `def-lcbsi-cc-treatment`)

| Anchor | Constraint | Enforcement | Rules | Capture-time | Gap |
|---|---|---|---|---|---|
| `sec-def-lcbsi-caused-common-commensals` | An LCBSI caused by a common commensal meets one of the three alternative NeoIPC definitions (detected twice, laboratory finding, five-day treatment). | Capture time | — | `NEOIPC_BSI_LCBSI_CC_MULT_OR_AB_5D_VR`, `NEOIPC_BSI_LCBSI_CC_ONCE_NO_AB_VR`, `NEOIPC_BSI_AGENT_IF_NCC_OR_AB_TREATMENT`, `NEOIPC_BSI_AGENT_IF_NCC_OR_RECOVERED_MULT` | G15 |
| `sec-def-lcbsi-caused-common-commensals` | *(derived)* The raw data underlying a common-commensal LCBSI diagnosis (specimen count, laboratory findings, treatment) is collected so that the alternative definitions can be applied afterwards. | Not checkable | — | `NEOIPC_BSI_PATHOGEN_n_MULTIPLE`, `NEOIPC_BSI_AB_TREATMENT` |  |
| `sec-def-lcbsi-caused-common-commensals` | *(derived)* Rates of LCBSI caused by common commensals are compared across settings only with caution. | Not checkable | — | — |  |
| `sec-def-lcbsi-caused-common-commensals` | For the five-day treatment criterion, the antibiotic day count includes the day of the first dose and the day of the last dose, days without a dose between them count, days after the last dose do not, and a patient who died, was discharged or was transferred before completing five days meets it when treatment was scheduled for five days or more. | Not checkable | — | — |  |
| `def-lcbsi-cc-twice` | An LCBSI with common commensal detected twice has the same common commensal recovered from at least two blood and/or CSF culture specimens collected on separate occasions. | Capture time | — | `NEOIPC_BSI_PATHOGEN_n_MULTIPLE`, `NEOIPC_BSI_LCBSI_CC_MULT_OR_AB_5D_VR` | G15 |
| `def-lcbsi-cc-twice` | An LCBSI with common commensal detected twice has at least two of the listed clinical or laboratory features of generalized infection. | Capture time | — | `NEOIPC_BSI_LCBSI_CC_MULT_OR_AB_5D_VR` | G15 |
| `def-lcbsi-cc-lab-finding` | An LCBSI with common commensal and laboratory finding has a common commensal recovered from one blood and/or CSF culture specimen (the branch that applies when no multiple-specimen flag is set; nothing is refused). | Not checkable | — | `NEOIPC_BSI_LCBSI_CC_ONCE_NO_AB_VR` |  |
| `def-lcbsi-cc-lab-finding` | An LCBSI with common commensal and laboratory finding has at least one of the listed laboratory findings. | Capture time | — | `NEOIPC_BSI_LCBSI_CC_ONCE_NO_AB_VR`, `NEOIPC_BSI_SET_FIRST_FINDING_COUNTS` | G15 |
| `def-lcbsi-cc-lab-finding` | An LCBSI with common commensal and laboratory finding has at least two of the listed clinical or laboratory features of generalized infection. | Capture time | — | `NEOIPC_BSI_LCBSI_CC_ONCE_NO_AB_VR` | G15 |
| `def-lcbsi-cc-treatment` | An LCBSI with common commensal and five-day treatment has a common commensal recovered from one blood and/or CSF culture specimen (the branch that applies when the treatment flag is set and no multiple-specimen flag; nothing is refused). | Not checkable | — | `NEOIPC_BSI_AGENT_IF_NCC_OR_RECOVERED_MULT`, `NEOIPC_BSI_LCBSI_CC_MULT_OR_AB_5D_VR` |  |
| `def-lcbsi-cc-treatment` | An LCBSI with common commensal and five-day treatment has intravenous antibiotic treatment of five or more days initiated. | Capture time | — | `NEOIPC_BSI_AB_TREATMENT`, `NEOIPC_BSI_LCBSI_CC_MULT_OR_AB_5D_VR` | G15 |
| `def-lcbsi-cc-treatment` | An LCBSI with common commensal and five-day treatment has at least two of the listed clinical or laboratory features of generalized infection. | Capture time | — | `NEOIPC_BSI_LCBSI_CC_MULT_OR_AB_5D_VR` | G15 |

### 4.2 Necrotizing Enterocolitis (`sec-def-necrotizing-enterocolitis`, `def-nec-symptom`, `def-nec-surgical`)

| Anchor | Constraint | Enforcement | Rules | Capture-time | Gap |
|---|---|---|---|---|---|
| `sec-def-necrotizing-enterocolitis` | Intestinal perforation is recorded in the NEC dataset but is not a surveillance definition criterion, so its presence is neither required for nor by itself sufficient for recording an NEC. | Not checkable | — | — (no data element records it) |  |
| `sec-def-necrotizing-enterocolitis` | An NEC meets either a combination of radiological findings and clinical signs or a diagnosis based on surgical and/or pathological evidence. | Capture time | — | `NEOIPC_NEC_VR`, `NEOIPC_NEC_SET_FINDING_COUNTS`, `NEOIPC_NEC_IMG_CLIN_FINDINGS_CRIT_FULFILLED_TRUE`, `NEOIPC_NEC_SURG_FINDINGS_CRIT_FULFILLED_TRUE` | G15 |
| `sec-def-necrotizing-enterocolitis` | An NEC record states whether the patient has an intestinal perforation. | Not checkable | — | — (no data element records it) |  |
| `sec-def-necrotizing-enterocolitis` | A case with surgical evidence of intestinal perforation but no evidence of primary necrosis or pneumatosis intestinalis (e.g. spontaneous bowel perforation) is not recorded as NEC. | Not checkable | — | `NEOIPC_NEC_VR` |  |
| `sec-def-necrotizing-enterocolitis` | An NEC meets either the symptom-based definition or the surgical definition. | Capture time | — | `NEOIPC_NEC_VR`, `NEOIPC_NEC_IMG_CLIN_FINDINGS_CRIT_FULFILLED_TRUE`, `NEOIPC_NEC_SURG_FINDINGS_CRIT_FULFILLED_TRUE` | G15 |
| `def-nec-symptom` | A symptom-based NEC has at least one of the listed radiological signs. | Capture time | — | `NEOIPC_NEC_VR`, `NEOIPC_NEC_SET_FINDING_COUNTS` | G15 |
| `def-nec-symptom` | A radiological sign for NEC is obtained by X-ray, CT, MRI or ultrasound. | Not checkable | — | — |  |
| `def-nec-symptom` | A symptom-based NEC has at least one of the listed clinical signs. | Capture time | — | `NEOIPC_NEC_VR`, `NEOIPC_NEC_SET_FINDING_COUNTS` | G15 |
| `def-nec-surgical` | A surgical NEC has at least one surgical or pathological finding of extensive bowel necrosis or pneumatosis intestinalis. | Capture time | — | `NEOIPC_NEC_VR`, `NEOIPC_NEC_SURG_FINDINGS_CRIT_FULFILLED_TRUE`, `NEOIPC_NEC_SET_FINDING_COUNTS`, `NEOIPC_NEC_EXTENSIVE_BOWEL_NECROSIS_VAL_TRUE`, `NEOIPC_NEC_PNEUMAT_INT_SURG_VAL_TRUE` | G15 |
| `def-nec-surgical` | Extensive bowel necrosis qualifies as a surgical NEC finding only when more than 2 cm of bowel is affected. | Not checkable | — | — |  |

### 4.3 Pneumonia (`sec-def-pneumonia`, `def-pneumonia`)

| Anchor | Constraint | Enforcement | Rules | Capture-time | Gap |
|---|---|---|---|---|---|
| `sec-def-pneumonia` | *(derived)* This section requires ventilation for at least 4 calendar days for a device-associated pneumonia, whereas the data dictionary requires 3 consecutive ventilation days on the day of infection or the day before; a pneumonia on ventilation day 3 with ventilation ending that day meets one and not the other. | Not checkable | — | `NEOIPC_HAP_DEFINITION_VR`, `NEOIPC_HAP_DEVICE_ASSOCIATION` |  |
| `sec-def-pneumonia` | An escalation of respiratory support includes an increase in FiO2 need of at least 0.25 within 24 hours, judged on daily minimum FiO2 values. | Not checkable | — | — |  |
| `sec-def-pneumonia` | Beginning non-invasive ventilatory support counts as new initiation of respiratory support, except when it is a switch from invasive ventilation. | Not checkable | — | — |  |
| `sec-def-pneumonia` | Beginning invasive mechanical ventilation counts as escalation of respiratory support, including a switch from non-invasive support. | Not checkable | — | — |  |
| `sec-def-pneumonia` | The respiratory-support initiation or escalation of a pneumonia does not improve within two days. | Not checkable | — | — |  |
| `sec-def-pneumonia` | A stable or improving baseline of at least two days precedes the respiratory-support initiation or escalation of a pneumonia. | Not checkable | — | — |  |
| `sec-def-pneumonia` | A pneumonia organism counts only when identified from the respiratory tract by a testing method performed for clinical diagnosis or treatment, not by active surveillance culture/testing. | Not checkable | — | `NEOIPC_HAP_MICROBIOLOGICAL_TEST_RESULT` compulsory |  |
| `sec-def-pneumonia`, `dd-organisms-lower-rt`, `dd-organisms-upper-rt` | A fungal or bacterial pneumonia pathogen counts only when identified from secretions of the lower respiratory tract; a viral one from the upper or lower tract. | Interface only | — | `NEOIPC_HAP_LOW_RESP_TRACT_SAMPLE_POS_INFER_TRUE`, `NEOIPC_HAP_LOW_RESP_TRACT_SAMPLE_POS_INFER_FALSE`, `NEOIPC_HAP_SET_VIRUS`, `NEOIPC_HAP_VIRUS_DETECTED_OR_LOW_RESP_SAMPLE_POS` (assignments that feed the definition count; nothing refuses a bacterium recorded from an upper-tract sample), option set `NEOIPC_HAP_RESPIRATORY_TRACT_SAMPLE_SOURCES` | G15 |
| `sec-def-pneumonia` | A viral pneumonia pathogen is identified by gene, antigen or antibody (the detection method is not recorded). | Not checkable | — | — |  |
| `sec-def-pneumonia` | Interleukin counts as a pneumonia laboratory criterion only when the laboratory's specification for a pathological value is fulfilled. | Not checkable | — | — |  |
| `sec-def-pneumonia` | A pneumonia recorded as device-associated occurs in a patient ventilated (invasively or non-invasively) for at least 4 calendar days, counting the day ventilation starts as day 1. | Not covered | — | `NEOIPC_HAP_DEVICE_ASSOCIATION` compulsory | G8 |
| `sec-def-pneumonia` | The onset date of a device-associated pneumonia is no earlier than day 3 of ventilation. | Not covered | — | — | G8 |
| `def-pneumonia` | A pneumonia has at least one imaging finding showing new changes suggestive of pneumonia. | Capture time | — | `NEOIPC_HAP_DEFINITION_VR`, `NEOIPC_HAP_IMG_FINDINGS_CRIT_FULFILLED_TRUE`, `NEOIPC_HAP_IMG_FINDINGS_CRIT_FULFILLED_FALSE`, `NEOIPC_HAP_IMAGING_FINDINGS` compulsory | G15 |
| `def-pneumonia` | A pneumonia imaging finding is obtained by X-ray, CT, MRI or ultrasound. | Not checkable | — | — |  |
| `def-pneumonia` | A pneumonia has new initiation or escalation of respiratory support lasting at least 2 days, preceded by at least 2 days of stability or improvement. | Capture time | — | `NEOIPC_HAP_DEFINITION_VR`, `NEOIPC_HAP_RESP_SUPP_CRIT_FULFILLED_TRUE`, `NEOIPC_HAP_RESP_SUPP_CRIT_FULFILLED_FALSE`, `NEOIPC_HAP_RESPIRATORY_SUPPORT` compulsory | G15 |
| `def-pneumonia` | A pneumonia has at least four of the listed clinical or laboratory criteria. | Capture time | — | `NEOIPC_HAP_DEFINITION_VR`, `NEOIPC_HAP_CLIN_CRIT_TOTAL_COUNT_CALC`, `NEOIPC_HAP_CLIN_CRIT_FULFILLED_TRUE`, the per-criterion `NEOIPC_HAP_*_VAL_TRUE` rules, `NEOIPC_HAP_VIRUS_DETECTED_OR_LOW_RESP_SAMPLE_POS` | G15 |
| `tbl-hap-no-device` | *(derived)* For a non-device-associated pneumonia the infection day is the day respiratory support (e.g. CPAP) begins after two baseline days of stability, not a later day of continued support. | Not checkable | — | — |  |
| `tbl-hap-device` | *(derived)* For a device-associated pneumonia the infection day is the ventilation day on which the daily minimum FiO2 rises by at least 0.25 after two improving baseline days; the value assessed per day is the daily minimum FiO2. | Not checkable | — | — |  |

### 4.4 Surgical Site Infection (`sec-def-surgical-site-infection`)

| Anchor | Constraint | Enforcement | Rules | Capture-time | Gap |
|---|---|---|---|---|---|
| `sec-def-surgical-site-infection` | An SSI is recorded only when it occurs within the surveillance window after a surgical procedure that is itself recorded in the NeoIPC surveillance system. | Covered | 19 | — |  |
| `sec-def-surgical-site-infection` | An SSI in a patient who has no surgical procedure record in the NeoIPC surveillance system is not eligible. | Covered | 19 | — |  |
| `sec-def-surgical-site-infection` | SSI surveillance days are counted with the procedure date as day 1. | Covered | 19 | — |  |
| `sec-def-surgical-site-infection` | The surveillance window for a superficial incisional SSI is 30 days from the procedure date. | Covered | 19 | — |  |
| `sec-def-surgical-site-infection` | The surveillance window for a deep incisional SSI is 30 days, or 90 days when an implant has been left in place. | Covered | 19 | — |  |
| `sec-def-surgical-site-infection` | The surveillance window for an organ/space SSI is 30 days, or 90 days when an implant has been left in place. | Covered | 19 | — |  |
| `sec-def-surgical-site-infection` | SSI follow-up for a surgical procedure ends early on death, transfer or discharge of the patient. | Not covered | — | — | G6 |
| `sec-def-surgical-site-infection` | A revision procedure in the same area ends the SSI follow-up of the earlier procedure and starts a new follow-up period for the revision procedure. | Not covered | — | `NEOIPC_SURGERY_REVISION_PROCEDURE` compulsory | G13 |
| `sec-def-surgical-site-infection` | A minor intervention such as a simple puncture of a hematoma/seroma is not a revision procedure and neither terminates SSI surveillance nor starts a new follow-up period. | Not checkable | — | — |  |
| `sec-def-surgical-site-infection` | A surgical procedure record carries the main procedure and its associated ICHI code. | Capture time | — | `NEOIPC_SURGERY_MAIN_PROCEDURE_CODE` compulsory, `NEOIPC_SURGERY_PROCEDURE_DESCRIPTION` compulsory | G11 |
| `sec-def-surgical-site-infection` | A surgical procedure record carries at most two further ICHI codes beyond the main procedure, and only for complex interventions that one main procedure cannot adequately describe. | Capture time | — | two side-code data elements exist |  |
| `sec-def-surgical-site-infection`, `dd-ssi-type` | The reported SSI type (superficial incisional, deep incisional or organ/space) is the deepest tissue level at which SSI criteria are met during the surveillance period, so no finding of a deeper level is recorded beside a shallower type. | Interface only | — | `NEOIPC_SSI_INFECTION_TYPE_SUPERFICIAL`, `NEOIPC_SSI_INFECTION_TYPE_DEEP`, `NEOIPC_SSI_INFECTION_TYPE_ORGAN_SPACE`, `NEOIPC_SSI_NO_INFECTION_TYPE` | G15 |
| `sec-def-surgical-site-infection` | *(derived)* When an SSI deepens during the surveillance period, its recorded infection day is the day the deepest-level criteria are met. | Not checkable | — | — |  |
| `sec-def-surgical-site-infection` | A surgical procedure on a deceased patient (e.g. post-mortem organ-donation surgery) is excluded from SSI surveillance. | Partial | 15 | — | G6 |

### 4.4.1 to 4.4.3 Superficial Incisional, Deep Incisional and Organ/Space SSI (`sec-def-superficial-incisional-ssi`, `def-ssi-superficial`, `sec-def-deep-incisional-ssi`, `def-ssi-deep`, `sec-def-organ-space-ssi`, `def-ssi-organ-space`)

| Anchor | Constraint | Enforcement | Rules | Capture-time | Gap |
|---|---|---|---|---|---|
| `sec-def-superficial-incisional-ssi` | An SSI involving only the skin and subcutaneous tissue is classified as superficial incisional. | Interface only | — | `NEOIPC_SSI_INFECTION_TYPE` compulsory, `NEOIPC_SSI_INFECTION_TYPE_SUPERFICIAL`, `NEOIPC_SSI_NO_INFECTION_TYPE` | G15 |
| `sec-def-superficial-incisional-ssi` | For the SSI criteria, "physician" may be a surgeon, infectious disease physician, emergency physician, another physician on the case, or a physician's designee. | Not checkable | — | — |  |
| `sec-def-superficial-incisional-ssi` | Diagnosis or treatment of cellulitis by itself does not satisfy superficial incisional SSI criterion "d"; a stitch abscess alone, a localized stab wound or a pin site infection does not qualify as a superficial incisional SSI; a laparoscopic trocar site is a surgical incision and not a stab wound. | Not checkable | — | — |  |
| `def-ssi-superficial` | A superficial incisional SSI has its first symptoms within 30 days after the operation. | Covered | 19 | — |  |
| `def-ssi-superficial` | A superficial incisional SSI involves only the skin and subcutaneous tissue of the incision. | Interface only | — | `NEOIPC_SSI_INFECTION_TYPE` compulsory, `NEOIPC_SSI_INFECTION_TYPE_SUPERFICIAL` | G15 |
| `def-ssi-superficial` | A superficial incisional SSI has at least one of the listed findings. | Capture time | — | `NEOIPC_SSI_SUPERFICIAL_INCISIONAL_VR`, `NEOIPC_SSI_INFECTION_TYPE_SUPERFICIAL` | G15 |
| `sec-def-deep-incisional-ssi` | An SSI involving the deep soft tissues of the incision (fascial and muscle layers) is classified as deep incisional. | Interface only | — | `NEOIPC_SSI_INFECTION_TYPE` compulsory, option set `NEOIPC_SSI_TYPE`, `NEOIPC_SSI_INFECTION_TYPE_DEEP` | G15 |
| `sec-def-deep-incisional-ssi` | The 90-day symptom window for a deep incisional SSI applies only when an implant was left in place. | Covered | 19 | — |  |
| `def-ssi-deep` | A deep incisional SSI has its first symptoms within 30 days after the operation, or within 90 days when an implant was left in place. | Covered | 19 | — |  |
| `def-ssi-deep` | A deep incisional SSI involves the deep soft tissues of the incision (for example, fascial and muscle layers). | Interface only | — | `NEOIPC_SSI_INFECTION_TYPE` compulsory, option set `NEOIPC_SSI_TYPE`, `NEOIPC_SSI_INFECTION_TYPE_DEEP` | G15 |
| `def-ssi-deep` | A deep incisional SSI has at least one of the listed findings. | Capture time | — | `NEOIPC_SSI_DEEP_INCISIONAL_VR`, `NEOIPC_SSI_INFECTION_TYPE_DEEP` | G15 |
| `sec-def-organ-space-ssi` | An SSI involving any part of the body deeper than the fascial/muscle layers that was opened or manipulated during the procedure is classified as organ/space. | Interface only | — | `NEOIPC_SSI_INFECTION_TYPE` compulsory, option set `NEOIPC_SSI_TYPE`, `NEOIPC_SSI_INFECTION_TYPE_ORGAN_SPACE` | G15 |
| `sec-def-organ-space-ssi` | The 90-day symptom window for an organ/space SSI applies only when an implant was left in place. | Covered | 19 | — |  |
| `def-ssi-organ-space` | An organ/space SSI has its first symptoms within 30 days after the operation, or within 90 days when an implant was left in place. | Covered | 19 | — |  |
| `def-ssi-organ-space` | An organ/space SSI involves a part of the body deeper than the fascial/muscle layers that was opened or manipulated during the operative procedure. | Interface only | — | `NEOIPC_SSI_INFECTION_TYPE` compulsory, option set `NEOIPC_SSI_TYPE`, `NEOIPC_SSI_INFECTION_TYPE_ORGAN_SPACE` | G15 |
| `def-ssi-organ-space` | An organ/space SSI has at least one of the listed findings. | Capture time | — | `NEOIPC_SSI_ORGAN_SPACE_VR`, `NEOIPC_SSI_INFECTION_TYPE_ORGAN_SPACE` | G15 |

### 5 Data Dictionary (`sec-dd`)

| Anchor | Constraint | Enforcement | Rules | Capture-time | Gap |
|---|---|---|---|---|---|
| `sec-dd` | Each collected variable's data type, whether it is required and whether it is repeatable, together with the full code lists, are specified in the companion machine-readable data dictionary generated from the NeoIPC metadata rather than in the protocol text. | Not checkable | — | — |  |
| `sec-dd` | *(derived)* Some data items (e.g. patient id and patient name) serve local documentation only and are not used in the central NeoIPC software tools. | Not checkable | — | — |  |

### 5.1.1 Enrolment (`sec-dd-enrolment`)

| Anchor | Constraint | Enforcement | Rules | Capture-time | Gap |
|---|---|---|---|---|---|
| `dd-enrolling-organization-unit` | An enrolment records the organisation unit at which the patient is registered. | Capture time | — | DHIS2 tracker: the enrolment's organisation unit is a required property |  |
| `dd-neoipc-id` | Each patient's NeoIPC-ID is a unique identifier within the reporting platform. | Capture time | — | `NEOIPC_PATIENT_ID` unique, orgunitScope | G21 |
| `dd-neoipc-id` | *(derived)* The mapping between NeoIPC-ID and patient is kept in a local pseudonymization list. | Not checkable | — | — |  |
| `dd-patient-id` | The Patient-ID is the hospital's own unique patient identifier and, like the patient name, is a local-documentation field. | Not checkable | — | — |  |
| `sec-dd-enrolment` | The patient ID and the patient name are not part of the NeoIPC dataset and are never submitted to the data collection platform; the NeoIPC-ID is never the hospital patient ID or the patient name. | Not checkable | — | — |  |
| `dd-ga` | Gestational age is recorded as completed weeks plus days at birth in the form weeks+days (e.g. 25+4). | Capture time | — | `NEOIPC_PATIENT_GA_FORMAT_VR`, `NEOIPC_PATIENT_SET_GESTATION_DAYS_AND_WEEKS`, `NEOIPC_PATIENT_SET_TOTAL_GESTATION_DAYS`, `NEOIPC_PATIENT_WARN_GESTATION_DAYS_0_160_OR_310` (warning only) | G17 |
| `dd-ga` | *(derived)* Gestational age is the obstetrician's calculated or estimated value; only where that is unavailable may the treating physician's assessment (e.g. Ballard score) be recorded. | Not checkable | — | — |  |
| `dd-bw` | Birthweight is recorded in grams as the infant's weight immediately after birth; where it is unknown or highly pathological, the treating physician's estimate may be entered instead. | Not checkable | — | `NEOIPC_TEA_BIRTH_WEIGHT` INTEGER_POSITIVE, `NEOIPC_PATIENT_WARN_BW_1_299_OR_5000_PLUS` (warning only) |  |
| `dd-sex` | Sex is recorded as the phenotypic sex, and as undetermined when it cannot be determined from phenotype or genotype or the genotype is neither XX nor XY. | Not checkable | — | option set `NEOIPC_SEX_VALUES` |  |
| `dd-delivery-mode` | Delivery mode takes exactly one value from the enumerated list of delivery modes. | Capture time | — | option set `NEOIPC_DELIVERY_MODES`, mandatory |  |
| `dd-multiple-birth` | Multiple birth is flagged when the infant is part of a multiple birth. | Not checkable | — | `NEOIPC_TEA_MULTIPLE_BIRTH` TRUE_ONLY |  |
| `dd-number-of-infants-at-birth` | Number of infants at birth is the total number of infants delivered from the pregnancy, counting the infant being recorded. | Not checkable | — | `NEOIPC_TEA_SIBLINGS` INTEGER_POSITIVE, `NEOIPC_PATIENT_WARN_SIBLINGS_IN_BIRTH_7_PLUS` (warning only) |  |
| `dd-number-of-infants-at-birth` | *(derived)* Number of infants at birth is recorded for a multiple birth and is then at least 2. | Not covered | — | `NEOIPC_PATIENT_MULTIPLE_BIRTH_IS_SET`, `NEOIPC_PATIENT_MULTIPLE_BIRTH_IS_NOT_SET` (presence only) | G18 |

### 5.1.2 Admission Information (`sec-dd-admission-information`)

| Anchor | Constraint | Enforcement | Rules | Capture-time | Gap |
|---|---|---|---|---|---|
| `dd-admission-date` | The admission form records the admission date as the day the patient is admitted to the hospital. | Partial | 3, 26 | DHIS2: the event date is required; `NEOIPC_ADM_DATE_MUST_MATCH_ENR_ADM_DATE` | G11 |
| `dd-admission-date` | For an infant born in the hospital, the admission date equals the date of birth (no date of birth is collected; the checkable proxy is the admission day of life below). | Not checkable | — | `NEOIPC_ADM_TYPE_1` |  |
| `dd-admission-type` | Admission type is one of: admitted from the delivery room (delivered in the hospital), transferred or readmitted on the day of birth, transferred or readmitted the day after birth or later. | Capture time | — | `NEOIPC_ADMISSION_TYPE` compulsory, option set `NEOIPC_ADMISSION_TYPES` | G3 |
| `dd-admission-on-day-of-life` | For an infant not delivered in the hospital, the day of life on the day of admission is recorded; for an inborn infant it is not (the configuration records 1). | Capture time | — | `NEOIPC_ADM_TYPE_2_PLUS`, `NEOIPC_ADM_TYPE_1` | G3 |
| `dd-admission-on-day-of-life` | Day of life counts from 1 on the day of birth, and each following calendar day starting at 00:00 is the next day of life, so admission on day of life is an integer of at least 1. | Capture time | — | `NEOIPC_ADMISSION_DOL` INTEGER_POSITIVE, `NEOIPC_ADM_DOL_1`, `NEOIPC_ADM_DOL_VAL_150_PLUS` (warning only) | G3 |

### 5.1.3 Surveillance End (`sec-dd-surveillance-end`)

| Anchor | Constraint | Enforcement | Rules | Capture-time | Gap |
|---|---|---|---|---|---|
| `dd-surveillance-end-date` | The surveillance end form records the surveillance end date as the day data collection and follow-up for the patient stopped. | Partial | 4, 12, 13, 14, 15, 18, 25, 43, 44 | DHIS2: the event date is required | G24 |
| `dd-surveillance-end-reason` | Surveillance end reason is one of "Discharge or transfer" and "Death". | Capture time | — | `NEOIPC_SURVEILLANCE_END_REASON` compulsory, option set `NEOIPC_SURVEILLANCE_END_REASON` |  |
| `dd-patient-days` | Patient days count every day of the stay in the department including both the day of admission and the day of discharge/transfer/death, with no minimum duration of stay. | Covered | 18 | `NEOIPC_SURV_END_PATIENT_DAYS_SET`, `NEOIPC_SURVEILLANCE_END_PATIENT_DAYS` compulsory |  |
| `dd-patient-days` | *(derived)* Patient days is at least 1, at most the number of calendar days from admission date to surveillance end date inclusive, and no other cumulative day count exceeds it. | Partial | 18 | the nine `NEOIPC_SURV_END_*_DAYS_VR` rules | G9 |
| `dd-cvc-days`, `dd-pvc-days`, `dd-inv-days`, `dd-niv-days` | CVC, PVC, INV and NIV days count each day on which the device was in place, or the ventilation given, for at least 12 hours. | Not checkable | — | the four counts compulsory; `NEOIPC_SURV_END_CVC_DAYS_VR`, `NEOIPC_SURV_END_PVC_DAYS_VR`, `NEOIPC_SURV_END_INV_DAYS_VR`, `NEOIPC_SURV_END_NIV_DAYS_VR`, `NEOIPC_SURV_END_NIV_INV_DAYS_VR` |  |
| `dd-human-milk-days` | Human milk days count each day on which enteral feeding consisted exclusively of own mother's or donor breast milk, with fortified breast milk counting as breast milk. | Not checkable | — | `NEOIPC_SURVEILLANCE_END_HUMAN_MILK_DAYS` compulsory, `NEOIPC_SURV_END_HUMAN_MILK_DAYS_VR` |  |
| `dd-kangaroo-care-days` | Kangaroo care days count each day on which the patient received kangaroo care (intensive skin-to-skin contact) for at least 2 hours. | Not checkable | — | `NEOIPC_SURVEILLANCE_END_KANGAROO_CARE_DAYS` compulsory, `NEOIPC_SURV_END_KANGAROO_CARE_DAYS_VR` |  |
| `dd-probiotic-days` | Probiotic days count each day on which the patient received, in any amount, an oral probiotic containing Lactobacillus spp. or Bifidobacterium spp. | Not checkable | — | `NEOIPC_SURVEILLANCE_END_PROBIOTIC_DAYS` compulsory, `NEOIPC_SURV_END_PROBIOTIC_DAYS_VR` |  |
| `dd-antibiotic-days-total` | Total antibiotic days count each day of a systemic antibiotic course. | Not checkable | — | `NEOIPC_SURVEILLANCE_END_AB_DAYS` compulsory, `NEOIPC_SURV_END_AB_DAYS_VR`, `NEOIPC_SURV_END_AB_SUBST_01_REQUIRE` |  |
| `dd-antibiotic-days-total`, `dd-antibiotic-days-per-substance` | An antibiotic course counts the day of the first dose, the day of the last dose and every day between them, dose-free days within the course included; days after the last dose are not counted whatever the drug level. | Not checkable | — | — |  |
| `dd-antibiotic-days-total` | At most one antibiotic day is counted per calendar day, so a day with several antibiotics counts as one antibiotic day. | Capture time | — | `NEOIPC_SURV_END_AB_DAYS_VR` | G9 |
| `dd-antibiotic-days-per-substance` | Antibiotic days per substance count, for each recorded systemic antibiotic substance, the days on which the infant received that substance. | Capture time | — | `NEOIPC_SURV_END_AB_SUBST_0n_HIDE`, `NEOIPC_SURV_END_AB_SUBST_01_REQUIRE`, `NEOIPC_SURV_END_AB_SUBST_0n_DAYS_REQUIRE`, the generated substance option set | G10 |
| `dd-antibiotic-days-per-substance` | *(derived)* No single substance's antibiotic days exceed the total antibiotic days, and the sum of per-substance days is at least the total antibiotic days. | Partial | 21 | `NEOIPC_SURV_END_AB_SUBST_DAYS_VR` (the floor only) | G10 |

### 5.2 Surgical Procedure (`sec-dd-surgical-procedure`)

| Anchor | Constraint | Enforcement | Rules | Capture-time | Gap |
|---|---|---|---|---|---|
| `dd-procedure-date` | A surgical procedure form records the procedure date as the day of the surgical procedure. | Partial | 15, 39, 40 | DHIS2: the event date is required | G24 |
| `dd-procedure-description` | A surgical procedure form records a human-readable name or description of the procedure as used by surgeons in the institution. | Capture time | — | `NEOIPC_SURGERY_PROCEDURE_DESCRIPTION` compulsory | G11 |
| `dd-main-procedure-code` | The main procedure code is an ICHI (International Classification of Health Interventions) code. | Partial | 22 | `NEOIPC_SURGERY_MAIN_PROCEDURE_CODE` compulsory | G24 |
| `dd-main-procedure-code` | When several different procedures are performed in one surgery, the surgeon decides which is the main procedure (typically the most complex or the one with the highest infection risk). | Not checkable | — | — |  |
| `dd-side-procedure-code` | Each side procedure code is an ICHI code. | Partial | 23, 24 | — | G24 |
| `dd-side-procedure-code` | A surgical procedure form carries at most two side procedure codes. | Capture time | — | two side-code data elements exist |  |
| `dd-duration` | Duration is the length of the surgical procedure in minutes (incision-to-suture time where available). | Capture time | — | `NEOIPC_SURGERY_DURATION` compulsory, INTEGER_POSITIVE |  |
| `dd-wound-class` | Wound class is one of the four CDC wound classifications, assigned by a person involved in the procedure. | Capture time | — | `NEOIPC_SURGERY_WOUND_CLASS` compulsory, option set `NEOIPC_WOUND_CLASSES` |  |
| `dd-asa-score` | ASA score is a value of the American Society of Anesthesiologists' Physical Status Classification System. | Capture time | — | `NEOIPC_SURGERY_ASA_SCORE` compulsory, option set `NEOIPC_ASA_SCORE` |  |
| `dd-endoscopic-procedure` | The endoscopic-procedure flag is Yes when the operation was performed entirely endoscopically and No otherwise. | Capture time | — | `NEOIPC_SURGERY_ENDOSCOPIC_PROCEDURE` compulsory |  |
| `dd-emergency-procedure` | The emergency-procedure item is Yes, No or Unknown (no information available). | Capture time | — | `NEOIPC_SURGERY_EMERGENCY_PROCEDURE`, an optional boolean whose empty value stands for Unknown |  |
| `dd-primary-closure` | Primary closure means the skin was closed by some means during the original surgery, regardless of objects extruding through the incision; a surgery in which any portion of the incision is closed at the skin level is recorded as primary closure. | Not checkable | — | `NEOIPC_SURGERY_PRIMARY_CLOSURE` compulsory |  |
| `dd-revision-procedure` | A revision procedure is a follow-up, replacement or corrective procedure performed after an initial procedure. | Not checkable | — | `NEOIPC_SURGERY_REVISION_PROCEDURE` compulsory |  |
| `dd-revision-procedure` | A revision procedure ends the SSI follow-up period of the primary procedure and starts a new follow-up period of its own. | Not covered | — | — | G13 |
| `dd-implant` | An implant is a non-human foreign body permanently placed during the operation and not routinely manipulated for diagnostic or therapeutic purposes. | Not checkable | — | `NEOIPC_SURGERY_IMPLANT` compulsory |  |
| `dd-signs-of-infection` | Signs of infection at time of surgery is completed when signs of infection were identified during the surgical procedure and documented in the operation note. | Not checkable | — | `NEOIPC_SURGERY_INFECTION_SIGNS` LONG_TEXT, optional |  |
| `dd-signs-of-infection` | When an SSI occurs, the signs of infection recorded on the procedure determine whether Infection present at time of surgery applies. | Not covered | — | `NEOIPC_SSI_INFECTION_PRESENT` compulsory | G14 |
| `def-ssi-signs-example` | Intraoperative findings such as abscess, infection, purulence, phlegmon or feculent peritonitis, and a ruptured or perforated appendix at the organ/space level, count as evidence of infection at time of surgery; contamination, necrosis, gangrene, spillage, a term ending in "itis", pathology or imaging findings, organism identification from a surgical specimen, the wound class, trauma and procedural complications do not. | Not checkable | — | — |  |

### 5.3.1 General Infection Data (`sec-dd-general-infection-data`)

| Anchor | Constraint | Enforcement | Rules | Capture-time | Gap |
|---|---|---|---|---|---|
| `dd-infection-date` | An infection form records the infection date as the day the first infection symptoms appeared, or, when no symptoms occur, the day of the first positive culture at the primary infection site. | Partial | 12, 13, 14, 19, 27 to 38, 41, 42 | DHIS2: the event date is required; `NEOIPC_*_SET_DOL`, `NEOIPC_*_SET_LOS`; `NEOIPC_*_LOS_LESS_THAN_2`; `NEOIPC_*_DOL_VAL_LESS_THAN_4` (warnings only) | G24 |
| `dd-common-commensal` | A common commensal is a micro-organism commonly present on epithelium-covered body surfaces (e.g. coagulase-negative staphylococci), as designated in the Master Organism List. | Not checkable | — | `NEOIPC_BSI_AGENT_n_SET_NCC` |  |
| `dd-mdros` | For each isolated organism, the applicable multidrug-resistant organism categories are selected. | Capture time | — | per slot and stage: `NEOIPC_*_AGENT_n_SET_<category>`, `NEOIPC_*_AGENT_n_MAYBE_<category>`, `NEOIPC_*_AGENT_n_NOT_<category>` | G16 |
| `sec-dd-general-infection-data` | Each resistance category of an isolated organism takes exactly one of Yes (resistant), No (not resistant) or Not tested. | Capture time | — | option set `NEOIPC_YES_NO_NOT_TESTED` | G16 |
| `sec-dd-general-infection-data` | Collecting secondary BSI data is optional, and a department not following patients for secondary BSI records No follow-up; Yes is recorded only when the patient developed a secondary sepsis meeting the definition. | Not checkable | — | option set `NEOIPC_YES_NO_NO_FOLLOWUP` |  |
| `sec-dd-general-infection-data` | The secondary BSI field of an infection takes exactly one of Yes, No or No follow-up. | Capture time | — | `NEOIPC_NEC_SECONDARY_BSI`, `NEOIPC_HAP_SECONDARY_BSI`, `NEOIPC_SSI_SEC_BSI` compulsory, option set `NEOIPC_YES_NO_NO_FOLLOWUP` | G11 |
| `dd-secondary-bloodstream-infection` | A secondary BSI is a BSI seeded from a site-specific infection at another body site (not a catheter) and is attributed to a NEC, pneumonia or SSI when it occurs within the 17-day period from 3 days before to 13 days after the day of that infection's first symptoms. | Not checkable | — | — |  |
| `sec-dd-general-infection-data` | Secondary BSI organisms are recorded only when secondary BSI is Yes. | Interface only | — | `NEOIPC_HAP_SEC_BSI_VAL_NO_VAL_OR_0`, `NEOIPC_NEC_SEC_BSI_VAL_NO_VAL_OR_0`, `NEOIPC_SSI_NO_SEC_BSI`, `NEOIPC_HAP_SEC_BSI_VAL_1_PLUS`, `NEOIPC_NEC_SEC_BSI_VAL_1_PLUS`, `NEOIPC_SSI_HAS_SEC_BSI` | G12 |

### 5.3.2 BSI Specific Data (`sec-dd-bsi-specific-data`)

| Anchor | Constraint | Enforcement | Rules | Capture-time | Gap |
|---|---|---|---|---|---|
| `dd-cvc`, `dd-pvc` | A CVC is an intravascular catheter terminating at or close to the heart or in a great vessel; a PVC is a catheter placed into a peripheral vein that does not reach one of the great vessels. | Not checkable | — | — |  |
| `dd-cvc-associated-bsi` | A primary BSI recorded as CVC-associated has the CVC in place for at least three consecutive days on the day of infection (first symptoms or first positive diagnostic test) or the day before. | Not covered | — | — | G8 |
| `dd-cvc-day`, `dd-pvc-day` | A CVC-day or PVC-day is a day on which the patient had the catheter in place for at least 12 hours cumulatively. | Not checkable | — | — |  |
| `dd-pvc-associated-bsi` | A primary BSI recorded as PVC-associated has the PVC present for at least three consecutive days on the day of infection or the day before and does not meet the CVC-associated criteria. | Not covered | — | — | G8 |
| `dd-pvc-associated-bsi` | A BSI meeting both the PVC- and the CVC-association criteria is recorded as CVC-associated, not PVC-associated. | Not checkable | — | option set `NEOIPC_BSI_DEVICE_ASS` |  |
| `dd-iv-antibiotic-initiated` | The intravenous antibiotic therapy criterion is met when antibiotic treatment for at least five days was initiated. | Not covered | — | `NEOIPC_BSI_AB_TREATMENT` TRUE_ONLY (a flag; the course length is not recorded) | G15 |
| `dd-iv-antibiotic-initiated` | In counting the five-day course, the day of the first dose, the day of the last dose and any dose-free days between them all count; days after the last dose do not; a course cut short by death, discharge or transfer counts when treatment was scheduled for five days or more. | Not checkable | — | — |  |
| `dd-apnoea-or-oxygen-increase` | The apnoea/oxygen criterion is met by new or more frequent apnoea episodes lasting more than 20 seconds, an increased oxygen requirement, or an escalation of ventilatory support. | Not checkable | — | — |  |
| `dd-enteral-feeding-intolerance` | The enteral feeding intolerance/abdominal distension/ileus criterion applies only without imaging or surgical findings suggesting NEC or spontaneous intestinal perforation. | Not checkable | — | — |  |
| `dd-unexplained-metabolic-acidosis` | Unexplained metabolic acidosis requires a base deficit greater (more negative) than 10 mmol/L. | Not checkable | — | — |  |

### 5.3.3 to 5.3.5 NEC, Pneumonia and SSI Specific Data (`sec-dd-nec-specific-data`, `sec-dd-pneumonia-specific-data`, `sec-dd-ssi-specific-data`)

| Anchor | Constraint | Enforcement | Rules | Capture-time | Gap |
|---|---|---|---|---|---|
| `dd-portal-venous-gas` | Portal venous gas is the accumulation of gas bubbles in the portal vein and its branches. | Not checkable | — | — |  |
| `dd-respiratory-support-increase` | A pneumonia form carries a Beginning or Increase in Respiratory Support criterion field. | Capture time | — | `NEOIPC_HAP_RESPIRATORY_SUPPORT` compulsory, `NEOIPC_HAP_RESP_SUPP_CRIT_FULFILLED_TRUE`, `NEOIPC_HAP_RESP_SUPP_CRIT_FULFILLED_FALSE` | G11 |
| `dd-inv`, `dd-niv` | Invasive mechanical ventilation is ventilation via an endotracheal or tracheostomy tube; non-invasive ventilatory support is support via CPAP or high-flow nasal cannula. | Not checkable | — | — |  |
| `dd-inv-associated-pneumonia` | A pneumonia recorded as INV-associated has the patient with an endotracheal or tracheostomy tube for at least 3 consecutive days on the day of infection (first symptoms or first positive culture) or the day before. | Not covered | — | — | G8 |
| `dd-inv-day`, `dd-niv-day` | An INV-day or NIV-day is a day on which the patient received that ventilation for at least 12 hours cumulatively. | Not checkable | — | — |  |
| `dd-niv-associated-pneumonia` | A pneumonia recorded as NIV-associated has the patient receiving non-invasive ventilatory support for at least 3 consecutive days on the day of infection or the day before. | Not covered | — | — | G8 |
| `dd-organisms-respiratory-tract`, `dd-organism-surgical-site` | Organisms identified from the respiratory tract or the surgical site count only when identified by a culture or non-culture microbiologic test performed for clinical diagnosis or treatment, not by active surveillance culture/testing. | Not checkable | — | — |  |
| `dd-infection-at-surgery` | Infection Present at Time of Surgery is YES only when the sign of infection identified during the procedure applies to the depth of the SSI attributed to that procedure. | Not checkable | — | `NEOIPC_SSI_INFECTION_PRESENT` compulsory |  |
| `dd-ssi-type` | An SSI form records the SSI type (depth). | Capture time | — | `NEOIPC_SSI_INFECTION_TYPE` compulsory, option set `NEOIPC_SSI_TYPE`, `NEOIPC_SSI_NO_INFECTION_TYPE` | G11 |

The text under `dd-respiratory-support-increase` and `dd-ssi-type` repeats the criteria inventoried
under 4.3 and 4.4, including the four-calendar-day ventilation requirement of a device-associated
pneumonia and the deepest-level rule for the SSI type.

### 6 Data Analysis (`sec-analysis`)

| Anchor | Constraint | Enforcement | Rules | Capture-time | Gap |
|---|---|---|---|---|---|
| `sec-analysis` | *(derived)* Surveillance data from a department feeds both the department's own report and the reference reports, so a department's submitted data is pooled into the reference data set. | Not checkable | — | — |  |
| `sec-analysis` | *(derived)* Every patient carries a birth weight in grams that places the record in one of four birth-weight strata used for core-module rates. | Not covered | — | `NEOIPC_PATIENT_WARN_BW_EMPTY_REGULAR` (warning only), `NEOIPC_PATIENT_BW_MANDATORY_IF_GA_MISSING_REGULAR`, `NEOIPC_PATIENT_BW_AND_GA_MANDATORY_NEODECO` | G1 |
| `sec-analysis` | *(derived)* The birth-weight strata boundaries are 500 g, 1000 g and 1500 g, written as < 500 g, 500–999 g, 1000–1499 g and > 1500 g (as written, a birth weight of exactly 1500 g falls in no stratum). | Not checkable | — | — |  |

### 6.1.1 Device Utilization (`sec-analysis-device-utilization`)

| Anchor | Constraint | Enforcement | Rules | Capture-time | Gap |
|---|---|---|---|---|---|
| `sec-analysis-device-utilization` | A device utilization rate is a percentage: the device days of one device type divided by patient days and multiplied by 100, computed separately per device type. | Not checkable | — | — |  |
| `sec-analysis-device-utilization` | *(derived)* Device days are counted as the patient days on which a device was used, so for each device type (CVC, PVC, INV, NIV) a record's device days cannot exceed its patient days. | Capture time | — | `NEOIPC_SURV_END_CVC_DAYS_VR`, `NEOIPC_SURV_END_PVC_DAYS_VR`, `NEOIPC_SURV_END_INV_DAYS_VR`, `NEOIPC_SURV_END_NIV_DAYS_VR`, `NEOIPC_SURV_END_NIV_INV_DAYS_VR` | G9 |

### 6.1.2 Antibiotic Use (`sec-analysis-antibiotic-use`)

| Anchor | Constraint | Enforcement | Rules | Capture-time | Gap |
|---|---|---|---|---|---|
| `sec-analysis-antibiotic-use` | The overall antibiotic use rate is a percentage: total antibiotic days divided by total patient days and multiplied by 100. | Not checkable | — | — |  |
| `sec-analysis-antibiotic-use` | The denominator of the proportion of patients receiving a specific substance or substance group is the number of patients receiving any antibiotic, not the number of all patients. | Not checkable | — | — |  |
| `sec-analysis-antibiotic-use` | *(derived)* Only systemic antibiotics count towards antibiotic days. | Not checkable | — | — |  |
| `sec-analysis-antibiotic-use` | *(derived)* Total antibiotic days is a count of patient days and cannot exceed total patient days. | Capture time | — | `NEOIPC_SURV_END_AB_DAYS_VR` | G9 |
| `sec-analysis-antibiotic-use` | *(derived)* Antibiotic use is recorded per individual substance (therapy days per substance), not only as an overall antibiotic-day total. | Partial | 21 | `NEOIPC_SURV_END_AB_SUBST_01_REQUIRE`, `NEOIPC_SURV_END_AB_SUBST_01_DAYS_REQUIRE` | G10 |
| `sec-analysis-antibiotic-use` | *(derived)* Each recorded antibiotic substance maps to a code in the WHO Anatomical Therapeutic Chemical (ATC) classification, which is what the substance groups are derived from. | Capture time | — | the generated option set `NEOIPC_ANTIMICROBIAL_SUBSTANCES` | G19 |
| `sec-analysis-antibiotic-use` | *(derived)* Substances are grouped at ATC levels 1, 2, 4 and 5 only. | Not checkable | — | — |  |
| `sec-analysis-antibiotic-use` | *(derived)* Substance and substance-group use rates are expressed per 1000 patient days according to the prose, while the formula that follows multiplies by 100. | Not checkable | — | — |  |
| `sec-analysis-antibiotic-use` | *(derived)* Total therapy days for a substance is a count of patient days and cannot exceed the patient days. | Not covered | — | — | G10 |
| `sec-analysis-antibiotic-use` | *(derived)* A patient counted as receiving a specific substance is also a patient receiving any antibiotic, so a record with any substance recorded has antibiotic days of at least one. | Interface only | — | `NEOIPC_SURV_END_AB_SUBST_01_HIDE`, `NEOIPC_SURV_END_AB_SUBST_02_HIDE` | G10 |
| `sec-analysis-antibiotic-use` | *(derived)* The stated formula for the proportion of patients receiving a substance divides therapy days by patient days, contradicting the prose definition (patients over patients) immediately before it. | Not checkable | — | — |  |

### 6.1.3 Protective Factor Implementation (`sec-analysis-protective-factor-implementation`)

| Anchor | Constraint | Enforcement | Rules | Capture-time | Gap |
|---|---|---|---|---|---|
| `sec-analysis-protective-factor-implementation` | Each protective factor utilization rate (breast milk intake, probiotic usage, kangaroo care implementation) is a percentage: the protective-factor days divided by patient days and multiplied by 100. | Not checkable | — | — |  |
| `sec-analysis-protective-factor-implementation` | *(derived)* Protective-factor days are the patient days on which a patient received breast milk, probiotic or kangaroo mother care, so each of these three day counts cannot exceed the record's patient days. | Capture time | — | `NEOIPC_SURV_END_HUMAN_MILK_DAYS_VR`, `NEOIPC_SURV_END_PROBIOTIC_DAYS_VR`, `NEOIPC_SURV_END_KANGAROO_CARE_DAYS_VR` | G9 |

### 6.2.1 Incidence Densities (`sec-analysis-incidence-densities`)

| Anchor | Constraint | Enforcement | Rules | Capture-time | Gap |
|---|---|---|---|---|---|
| `sec-analysis-incidence-densities` | *(derived)* Incidence densities per 1000 patient days are calculated for bloodstream infections, pneumonia and NEC (not for SSI), each counted per department against that department's patient days. | Not checkable | — | — |  |

### 6.2.2 Device-associated Infections (`sec-analysis-device-associated-infections`)

| Anchor | Constraint | Enforcement | Rules | Capture-time | Gap |
|---|---|---|---|---|---|
| `sec-analysis-device-associated-infections` | Device-associated infection rates are expressed per 1000 device days: the device-associated infections divided by the corresponding device days and multiplied by 1000. | Not checkable | — | — |  |
| `sec-analysis-device-associated-infections` | *(derived)* A device-associated infection is an infection occurring in the presence of the associated device, related to the total days at risk with that device. | Not checkable | — | — |  |
| `sec-analysis-device-associated-infections` | *(derived)* A CVC-associated BSI is a BSI in a patient with a CVC, and a PVC-associated BSI one in a patient with a PVC, so a department reporting one has non-zero days of that device. | Not covered | — | `NEOIPC_BSI_DEV_ASS` | G8 |
| `sec-analysis-device-associated-infections` | *(derived)* An INV-associated pneumonia is a pneumonia in a patient on invasive ventilation, and an NIV-associated one in a patient on non-invasive ventilation, so a department reporting one has non-zero days of that ventilation. | Not covered | — | `NEOIPC_HAP_DEVICE_ASSOCIATION` | G8 |
| `sec-analysis-device-associated-infections` | *(derived)* Device association is analyzed only as BSI with a vascular catheter and pneumonia with ventilation; a BSI is not ventilator-associated and a pneumonia is not catheter-associated. | Capture time | — | option sets `NEOIPC_BSI_DEVICE_ASS`, `NEOIPC_HAP_DEVICE_ASS` |  |

### 6.2.3 Surgical Site Infections (`sec-analysis-surgical-site-infections`)

| Anchor | Constraint | Enforcement | Rules | Capture-time | Gap |
|---|---|---|---|---|---|
| `sec-analysis-surgical-site-infections` | SSI rates are percentages: SSIs occurring after surgical procedures divided by the number of surgical procedures and multiplied by 100, computed both overall and per procedure group. | Not checkable | — | — |  |
| `sec-analysis-surgical-site-infections` | *(derived)* An SSI is counted only when it occurs after an operative procedure and within the observation period, so an SSI's onset follows the linked procedure's date. | Covered | 19 | — |  |
| `sec-analysis-surgical-site-infections` | *(derived)* The SSI denominator is the number of recorded surgical procedures, so every SSI is attributable to a recorded surgical procedure. | Covered | 19 | — |  |
| `sec-analysis-surgical-site-infections` | *(derived)* Each surgical procedure is classified into a group of similar procedures (a procedure category), since SSI rates are calculated per group. | Partial | 22, 23, 24 | `NEOIPC_SURGERY_MAIN_PROCEDURE_CODE` compulsory | G20 |
| `sec-analysis-surgical-site-infections` | *(derived)* The surveilled population is VLBW/VPT infants, which is why an overall SSI rate is calculated in addition to grouped rates. | Capture time | — | `NEOIPC_PATIENT_BW_1500_GRAMS_AND_GA_32_PLUS_WEEKS` and the mandatory-field rules on birth weight and gestational age | G1 |
| `sec-analysis-surgical-site-infections` | *(derived)* An SSI is attributed to the procedure group of the procedure it followed, so an SSI's group is determined by its linked procedure. | Not checkable | — | — |  |

### 6.2.4 Standardized Infection Rate (`sec-analysis-standardized-infection-rate`)

| Anchor | Constraint | Enforcement | Rules | Capture-time | Gap |
|---|---|---|---|---|---|
| `sec-analysis-standardized-infection-rate` | A standardized infection rate greater than one means more infections were observed than expected from the department's patient composition, exactly one the same number, and less than one fewer. | Not checkable | — | — |  |
| `sec-analysis-standardized-infection-rate` | *(derived)* This paragraph refers to 3 birthweight classes whereas the chapter introduction lists 4 birth-weight groups. | Not checkable | — | — |  |
| `sec-analysis-standardized-infection-rate` | *(derived)* Patient days accrue to the department in which they were spent, so a transferred infant is surveilled per department stay and each department accounts only for its own days. | Partial | 17 | — | G24 |
| `sec-analysis-standardized-infection-rate` | *(derived)* The SIR requires each patient's birth weight and the day of life of each surveilled day, so birth weight and the admission day of life are recorded for every patient (no date of birth is collected). | Not covered | — | `NEOIPC_ADMISSION_TYPE` compulsory, `NEOIPC_ADM_TYPE_2_PLUS`, `NEOIPC_ADM_TYPE_1`, `NEOIPC_PATIENT_BW_MANDATORY_IF_GA_MISSING_REGULAR`, `NEOIPC_PATIENT_BW_AND_GA_MANDATORY_NEODECO` | G1, G3 |
| `sec-analysis-standardized-infection-rate` | *(derived)* The standardized infection rate is calculated for BSI and pneumonia only, from reference-database risks per day of life and birth weight. | Not checkable | — | — |  |
| `sec-analysis-standardized-infection-rate` | *(derived)* Expected infections are summed over the days each infant spent in the department, so every patient record yields its set of days in the department (admission through surveillance end, as days of life). | Partial | 3, 4, 18, 25, 26 | `NEOIPC_ADM_TYPE_2_PLUS` | G3 |
| `sec-analysis-standardized-infection-rate` | *(derived)* The SIR is the ratio of infections observed in a department to infections expected from its patient composition. | Not checkable | — | — |  |

### 7 Abbreviations (`sec-abbr`)

The expansions restate constraints inventoried above: the resistance categories' applicability to
gram-negative organisms, *Staphylococcus aureus* and enterococci (three statements, interface only,
since the inapplicable categories are merely hidden; G16), the LCBSI classification (G15), the two
ventilation categories (G9), ICHI coding (G11, G24), the ASA score and the CSF specimen source (G11),
and the VLBW/VPT population (G1). A PICC is a central venous catheter for
device classification, and umbilical catheters are named as distinct terms; neither is a data item.

### 8 Imprint (`sec-imprint`)

Three statements on publisher, contact and version. None constrains a record.

### A List of Antibiotics (`sec-ab-list`)

The recordable substances are those of the list, which is derived from the WHO Access, Watch,
Reserve (AWaRe) classification and the Anatomical Therapeutic Chemical / Defined Daily Dose (ATC/DDD)
index of the WHO Collaborating Centre for Drug Statistics Methodology, and bounded at entry by the
generated option set `NEOIPC_ANTIMICROBIAL_SUBSTANCES` (G19). Not every listed substance carries both
an ATC code and an AWaRe category: the list extends AWaRe with systemic substances outside it. The
licence statement constrains reuse, not records.

### B List of Infectious Agents (`sec-agent-list`)

The recordable organisms are those of the list; the "Assumed Pathogenicity" column is what the
recognized-pathogen and common-commensal classification reads (G15), and the "Recorded Resistances"
column is the applicability the per-slot program rules enforce (G16). The list is generated from
`metadata/common/infectious-agents/NeoIPC-Infectious-Agents.yaml`, the canonical source.
