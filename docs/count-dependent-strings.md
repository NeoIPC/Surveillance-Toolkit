# Count-dependent strings in the reports

Which translatable strings need a plural family, which are labels that must be left alone, and why each
was decided that way. This is the input the monolingual catalogue generator's schema is built against:
a family emits `msgid`/`msgid_plural` and *n* `msgstr[i]`, so the set has to be known before the schema
is designed rather than discovered afterwards.

## The rule

**Write what the context calls for and let the schema express it.** A plural family exists so that *prose*
can read naturally in a language whose grammar varies with the count — not so that every string carrying a
number becomes one.

Both directions are mistakes, and this project has now made each:

- An earlier convention told authors to **avoid** count-dependent grammar — "prefer `Number of patients: {n}`
  over `{n} patients`". That bent the writing to work around a schema limitation.
- The correction is **not** to convert every such string back. `Number of patients: 5` is simply right for a
  table label, where a label takes a value and no grammar varies.

So each string is judged in its context, and the labels are recorded here alongside the families. A list
containing only families would be evidence that the pass converted rather than judged.

## Why this matters now

The reports currently express **no** count-dependence at all: there is not one `msgid_plural` in the
project. That is the gap, not a reassurance. Every target language so far takes two forms, which is the one
case where the absence is invisible — Ukrainian and Polish take three, Arabic six, and this project's own
rule is to prefer the official WHO rendering, of which Arabic and Russian are official languages. Adding
such a language to a schema that cannot hold a second form means retranslating, not extending.

## Three kinds of count-bearing string, not two

The third kind is the one every search misses.

| kind | how it is spotted | example |
|---|---|---|
| Count printed in the string | a placeholder receiving a number | `(N = {n} patients)` |
| Count printed, but the noun does not agree | reading the sentence | `%s: The aggregated number of infections…` — `%s` is a column symbol |
| **Count not printed at all, and R picks the form** | only by finding the *selection* in code | `if (length(countries) > 1) sR$countries else sR$country` |

The third kind carries no number in the rendered text, so no inspection of the catalogue can find it — the
count never enters the string. It is nonetheless count-dependent grammar, and gettext handles it exactly:
`ngettext` takes *n* whether or not *n* is displayed.

**Detecting these mechanically is harder than it looks.** A sweep for sibling keys differing by a trailing
`s` finds none of them: `countries` less `s` is `countrie`, not `country`. English irregular plurals defeat
the obvious heuristic, which is why the list below was built by reading the selection sites in R.

## Families — these need `msgid_plural`

| string | where | why |
|---|---|---|
| `fig_sample_size` | `reports/common.yaml` | `(N = %s patients)`. Receives a patient count. The noun follows the numeral directly and must agree. |
| `sparse_data_footnote` | `reports/common.yaml` | `Fewer than {threshold} events; …`. Receives the sparse-data threshold. |
| `sparse_data_footnote_no_ci` | `reports/common.yaml` | As above, the variant rendered when confidence intervals are off. |
| `content[4]` | `reports/Partner-Certificate/content/_sR.yaml` | `…monitoring of %s newborns with birth weights…`. Receives a newborn count. |
| `headerList.country` / `.countries` | Partner-Report, Reference-Report | Selected in R by `length(countries) > 1`. No count is printed; the noun still agrees with one. |
| `header.department` / `.departments` | Validation-Report | Selected in R by `nrow(departments) > 1`. Same shape. |

**Six, where the design note that preceded this named three.** The three it named were found by inspecting
`reports/common.yaml`; the other three live in a report's own `_sR.yaml` or in R code, which is why
inspecting one file could not have found them.

### The hand-rolled selections are already slightly wrong

`if (n > 1) plural else singular` encodes English's rule in code — and not quite. English takes the plural
at **zero** ("0 countries"), so the correct English predicate is `n != 1`, not `n > 1`. The current form
renders the singular for an empty set. Whether zero is reachable here is a separate question; the point is
that the rule is hard-coded, invisible to translators, and cannot be right for more than one language at a
time. French happens to agree with `> 1` (zero takes the singular there); Polish, Ukrainian and Arabic
cannot be expressed by any two-branch test.

Replacing these with a family is therefore a correctness fix as well as a localization one.

## Labels — deliberately not families

Recorded so the question is not reopened.

| string family | why it stays |
|---|---|
| every `*_footnote` carrying `%s` (`n_`, `pooled_`, `rate_`, `quartile_`) | The `%s` is a **column symbol** — `N`, `Q₂` — not a count. Nothing agrees with anything. This is the bulk of the 124 placeholder-carrying strings. |
| `fig-cap` bin-width and quantile captions | `%s` receives a formatted quantity with a unit (`50 g`, `7 days`) or a percentage. "steps" and "quantiles" are fixed plurals describing the construct, not agreeing with the value. |
| `gestational_age_format` (`{weeks}+{days}`) | A numeric format with no words at all. |
| `generated_on`, `patient_not_found` | Placeholders receive a date and identifiers. |
| `outlier.composed.*`, `outlier.generic_summary` | Placeholders receive metric labels and cross-references. |
| `headerList.*` income-class addenda | Placeholders receive classification names. |
| `problems.*.description` (Validation-Report) | Placeholders receive dates, statuses, codes and identifiers. `problems.18` mentions a number in parentheses — `The number of patient days (%s) does not match…` — where the noun phrase is fixed and the value is parenthetical. |

## Method

Surveyed all **614** translatable strings across `reports/common.yaml`, `glossary.yaml` and the five
reports' `content/_sR.yaml`; **124** carry a placeholder. Each was judged by what its placeholder actually
receives at the call site, not by its shape. The count-selected strings were found separately, by
searching R for a conditional on a length or row count that chooses between two string resources.

Weblate's **Unpluralised** check should be enabled to cover the same ground mechanically. Expect it to
disagree with this list in both directions — it will flag label-shaped strings it cannot know are fine, and
it cannot see the third kind at all, since those carry no number. Exact agreement would mean it was not
actually enabled on the right component.
