# Weblate quality checks: what to enable, and what not to

Weblate ships roughly ninety built-in checks and seven automatic fixups. This file records a decision for
every one of them against *these* catalogues, so the question is settled once rather than re-argued from
the documentation each time someone notices a check that sounds useful.

Every recommendation below was measured against the files in `po/`, and every "turn it on" row was
challenged by someone other than its author before it was written down. Where a count is given it came
from parsing the catalogue, not from reading the check's description.

Read [`weblate-component-configuration.md`](weblate-component-configuration.md) first for **how a flag
reaches a string at all** — that is a separate and counter-intuitive subject, and getting it wrong wastes
more time than choosing the wrong check.

## Two mechanics that decide everything else

**A check's identifier is not the flag that enables it.** The check called `asciidoc-markup` is switched on
by the flag `asciidoc-text`; `md-syntax`, `md-link` and `md-reflink` all come from the single flag
`md-text`. Setting the identifier does nothing. Every row below gives the flag string to type.

**"Automatically enabled for X files" never fires here.** These catalogues are gettext PO, extracted *from*
AsciiDoc, Markdown and YAML by po4a. Weblate sees PO, so every format-triggered auto-enablement is inert
and the flag must be explicit.

## Enable these

Set component flags in *Component → Translation flags*. Per-string flags are source-string extra flags,
reachable only through the web interface or the API — never the `.pot`, for the reason the configuration
reference explains.

### `asciidoc-text` — protocol documentation, then infectious agents

```
asciidoc-text
```

The highest-value check available, because it is the only thing that notices a **translated
cross-reference anchor**. Coverage: 160 of 686 documentation source strings carry an AsciiDoc token (34
`name:target[]` macros, 11 `<<xref>>`, 117 `[[anchor]]`, 2 passthrough); 13 of 4107 infectious-agent
strings, all from `Output-Header.adoc` / `Output-Footer.adoc` — the 4084 taxonomy entries carry none, so
component scope is safe there.

It finds real, shipping defects — see *Defects this survey found* below.

Prerequisite before enabling it on infectious agents: the three Creative-Commons licence strings from
`Output-Footer.adoc` need per-string `ignore-asciidoc-markup`. Translators deliberately localised the deed
URL (`…/4.0/[` → `…/4.0/deed.de[`), and because the check normalises a macro to name-plus-target, a
deliberately different URL always fires.

Known limits, so nobody assumes more cover than exists: the check collects only macros, `<<xref>>`,
`[[anchor]]` and passthroughs — **not** bold, italic, monospace or attribute references. And its macro
pattern absorbs a preceding word, so `daysfootnote:x[]` against `Tagefootnote:x[]` fires although the
footnote is intact.

**The source is correct as written, and an earlier revision here wrongly said to fix it.** AsciiDoc
requires an inline footnote to sit immediately against the text it annotates: Asciidoctor's
`InlineFootnoteMacroRx` has no left boundary, so it matches from `footnote` onwards and leaves whatever
precedes it as ordinary text — which is why `daysfootnote:x[]` renders as *days* followed by the marker.
Inserting a space to satisfy the check would change the output. Two real remedies, in preference order:

**Externalize the footnote, which fixes the cause rather than the symptom.** Asciidoctor supports
assigning a footnote to a document attribute and referencing it, because "attribute references are
expanded before footnotes are parsed":

```asciidoc
//po4a: entry fn-ab-days
:fn-ab-days: footnote:ab-days-comment[The day of the first dose and the day of ...]

The cumulative number of days{fn-ab-days} when the infant received ...
```

**The `//po4a: entry` line is not optional and its absence fails silently.** po4a translates an attribute
entry only where one has declared it — `AsciiDoc.pm` gates the `translate()` call on that name being
registered, and its own documentation says *"This declares an attribute entry as being translatable. By
default, they are not translated."* Without the directive the value is pushed through verbatim: the
footnote's prose never reaches `po/documentation.pot`, so it ships in English in all nine languages while
the build stays green and the check goes quiet — the loudest possible way to look like a fix. No
`//po4a: entry` exists anywhere in this repository today, so this is the first, and every externalized
footnote needs its own.

With the directive in place the translatable surface is unchanged in size but better shaped: the prose
becomes a unit of its own and the sentence carries `{fn-ab-days}` instead of `footnote:ab-days-comment[]`
— this project's own principle applied, since markup does not belong in a string a translator has to
carry through unchanged, and there is no decision for them to make about a footnote id. It also reads
better in the source, which is why the technique exists. Two further things to know: formatting inside an
externalized footnote needs `pass:c,q[…]`, and this check does **not** inspect attribute references, so
the false positive disappears and so does the (nonexistent) protection — cover it with a `placeholders:`
alternative if that matters.

**Otherwise suppress per string** with `ignore-asciidoc-markup`, the same treatment the Creative Commons
licence strings get and for the same reason: the source is right and the check cannot see it.

### `md-text` — reports

```
md-text
```

Enables `md-link`, `md-syntax` and `md-reflink` (the last is inert — no referents). Coverage: 27 of 774
strings carry a Markdown link (31 instances), 16 carry syntax tokens (37 instances, 15 of them inline R
spans).

Also repairs something invisible: `reports.pot` tags 190 entries `markdown-text`, but that is **po4a's**
flag, not Weblate's. Weblate applies no Markdown awareness anywhere today, including the markdown-link
exclusion inside `punctuation_spacing`, which tests `'md-text' in unit.all_flags`.

Do **not** set it on the protocol documentation: 34 entries, no findings, it misses AsciiDoc's own
constructs, and it switches the translator's editor into Markdown mode for AsciiDoc text.

Limits: `md-syntax` compares *sets* of delimiters, so a translation keeping one backtick pair and dropping
six others passes — entries here carry 4, 5 and 7 spans. `md-link` only inspects targets beginning `.`,
`#` or `{`, none of ours, so it degrades to link-count parity and a silently rewritten URL passes. Neither
replaces the repository's own placeholder gate.

### `placeholders` — reports, one flag with four alternatives

```
placeholders:r"`r [^`]+`":r"@(fig|tbl|eq|sec|lst|thm|lem|cor|prp|cnj|def|exm|exr)-[a-zA-Z0-9_-]+":r"\{[a-zA-Z_][a-zA-Z0-9_]*\}":r"\{#[A-Za-z0-9._-]+\}"
```

`placeholders:` is a **single** flag whose value is a colon-separated list, so a second line replaces the
first rather than adding to it — hence one flag covering inline R spans, Quarto cross-references, glue
`{named}` placeholders and Quarto heading anchors. Colons inside a member would break the quoting; none of
these four contains one.

Puts 15 inline-R spans, 107 cross-references, 30 glue placeholders and 40 heading anchors under
enforcement. A mangled `{#sec-…}` silently breaks every `@sec-` reference to that section and nothing else
catches it.

**Settle the inline-R policy before enabling.** Either an `` `r …` `` span is opaque — in which case adopt
this and restructure the one string whose German translation renders literals *inside* the span — or spans
are partly translatable, which no count- or content-based check can express and which stays human review.
Six German report units already differ in their span set. Without a decision the first finding gets argued
about instead of fixed.

Caveat: it is *not* a no-op on token-free sources. A placeholder the target invents always fires, which is
a feature (a translation that adds a cross-reference is a defect) but it means every unit is in scope.

### `placeholders` — DHIS2 metadata

```
placeholders:r"[#AV]\{[^}]+\}"
```

A different regex from the reports one, so this cannot be a project-level flag. Covers 177 of 2820 strings
(267 tokens). The character class is minimal by measurement rather than guesswork: a census of the
character before every `{` in the catalogue returns exactly `#`, `V` and `A`.

### `c-format` — reports, transitionally

```
c-format
```

114 of 774 strings carry a C-printf token (223 tokens: `%s` ×191, `%i` ×29). This is a **transitional**
adoption: the target state is named `{}` placeholders everywhere, and this covers `%s` only until they are
gone.

Three of the 223 tokens are not placeholders and will produce permanent noise — a `% a` inside "Values
above 100% are expected", a msgid that is literally `%`, and a `%x` inside an inline R span. Suppress those
three per string rather than leaving them to teach translators that the check cries wolf.

### `xml-text` — three documentation strings, per-string only

Eight `documentation.pot` entries come from the decision-flow `.resx`, and **three** of them carry escaped
entities in the msgid — the two `&lt;` thresholds and the one `&gt;`. The other five are bare words
(`Yes`, `No`, `Eligible`, `Ineligible`) and one entity-free question, which have nothing for the check to
protect. `xml-invalid` is automatic but only engages on strings it recognises as XML-like; forcing it on
those three needs per-string `xml-text`.

*(This said six until the units were counted at enablement. Measure from the current template rather than
quoting the number, as with the anchor counts further down.)*

Per-string **only**: `documentation.pot` is regenerated by po4a on every pipeline run and po4a cannot emit
custom per-string flags, so a flag written into the template is destroyed on the next run.

### `url` — one string

One msgid in the whole project is nothing but a URL (`https://neoipc.org/`). Worth the per-string `url`
flag; must **not** be set at component level, where it would demand every target validate as a URL.

### `check-glossary` — every component carrying prose or labels

```
check-glossary
```

Turns *Does not follow glossary* on, which is what makes the terminology decisions recorded in
`glossary.yaml` enforced rather than merely displayed in the sidebar. Set on reports, the protocol,
metadata and the app. **Not** on infectious agents: those 4,107 entries are nomenclature, so a
terminology check has nothing there to enforce and any match would be coincidental.

Measured at enablement: **zero findings on all four**, and again once German's glossary was completed the
same day. That reading was wrong, and the way it was wrong is the useful part: all seven device and
infection abbreviations carried a German rendering but **no `terminology` flag**, so they were not in
the glossary the check consults and could not be enforced at all. Adding the flag produced a real finding
within hours. A quiet check is evidence of nothing until you know its terms are actually reaching it.

#### What it actually compares, and the limitation that follows

From `weblate/checks/glossary.py`: for each glossary term matching the source, it searches the **target**
for the expected rendering — `term.target` normally, or the *source* term where the entry is `read-only` —
case-insensitively, bounded by `\b` in languages that use whitespace and unbounded in those that do not.
Present once anywhere: satisfied. Absent: flagged.

**So it cannot detect an untranslated term. It can only detect the absence of the translated one.** The
distinction is not academic. A German protocol string carried **three** occurrences of `PVC` where the
glossary says `PVK` — one inside an AsciiDoc cross-reference, two in prose. The check fired; correcting a
**single** occurrence introduced `PVK`, which satisfied the term and cleared the check while two `PVC`
remained in the shipped text.

Markup has nothing to do with it — the target is searched as plain text, and a term inside `<<…>>` counts
exactly like one in prose. What makes the leftovers invisible is that `PVC` is never searched for at any
point.

Read the check accordingly: **it finds strings worth looking at, not strings that are finished.** It sits
alongside the `md-syntax` and `md-link` limits below, which degrade to set and count comparisons for the
same practical reason.

#### It is blind to a term inside a compound, which matters most in German

The search is bounded: `boundary = r"\b" if unit.translation.language.uses_whitespace() else ""`. For
German that means it looks for `\bAufnahme\b` — and in *Aufnahmedaten* the term is followed by another
word character, so there is no boundary and the match fails. The check then reports the term as not
followed, on a translation that follows it perfectly.

**In a compounding language this is not an edge case, it is how nouns are built**, so expect it wherever a
glossary term appears only as a compound element. It has already fired on *Admission → Aufnahme* against a
correct *Aufnahmedaten*. The boundary exists so a term does not match inside an unrelated word; in German
it instead makes the check blind to the commonest correct usage. The same applies to Dutch, Finnish,
Hungarian and Turkish.

The inverse is worth knowing before a CJK language joins: `uses_whitespace()` is false for Chinese and
Japanese, so there the boundary is empty and matching is plain substring — the opposite trade, and it will
behave differently rather than merely less well.

Dismiss such a finding on the string rather than adjusting the glossary. Adding compound forms as terms
would be unbounded — German composes freely — and each one added would then have to be maintained as
terminology it is not.

Three further behaviours from the same function, each load-bearing:

- **Variants are excluded** (`include_variants=False`), so the casing variants that duplicate in the
  translator's *sidebar* do not duplicate in the *check*. The sidebar duplication is display-only — and it
  compounds with the project holding **two** glossary stores, so one concept can return three sidebar
  entries: the TBX store's, and both casing variants from `neoipc-glossary`. Terms from every glossary in
  a project are merged into one list with no way to select between them, which is why there is one
  curated vocabulary rather than several.
- **`read-only` inverts the test** to demand the source term verbatim, which is what makes an entry like
  `aware: "AWaRe"` behave as intended.
- **`forbidden` inverts it the other way**: the check fires when the forbidden rendering *is* present.
  That is the mechanism for recording a wrong rendering — *Watch → Vigilancia* — as a rule rather than a
  note, and it is confirmed in the code rather than assumed from the documentation.

**The dependency worth knowing: the check can only bite in a language once that language's glossary is
translated.** Spanish and Italian carry a handful of terms between them, so almost nothing is enforceable
in either yet, however much report prose they accumulate. This is what makes the glossary component's
*Very high* priority operational rather than decorative — translating that component first is what
converts terminology agreement into enforcement across every other catalogue, and it is a few dozen
strings rather than a project. Read the component's own statistics for where each language stands; these
figures move whenever anyone translates a term.

### `python-brace-format` — the end state, blocked on a source change

```
python-brace-format
```

**Not enabled, and not rejected either.** It is the standard gettext flag for exactly the `{named}` syntax
this project is migrating towards, so it is where the reports catalogue should end up: a standard flag
instead of a hand-written regex, with the same coverage.

One thing blocks it, and it is in the strings rather than in the check. **A brace here is not always a
placeholder.** In `po/reports.pot`, 40 source strings carry a Quarto heading anchor such as
`{#sec-problems}` against 30 carrying a glue placeholder. `#sec-problems` is not a valid format field, so
today the check would report a syntax error on more strings than it covers correctly — and a check that is
wrong more often than right teaches translators to dismiss it, which costs more than the check is worth.
That is why `placeholders:` carries an explicit alternative per construct: distinguishing them is the
whole job.

**The unblocking is a source change, not a re-measurement.** Those anchors are markup inside translatable
text, which the source-string migration's own first principle says should not be there — a translator has
no decision to make about `{#sec-problems}` and cannot safely alter it. Move them out and the collision
disappears; enable this and drop the corresponding `placeholders:` alternative in the same step, since the
two would then overlap.

*(It was once proposed as a replacement for `placeholders:` on the grounds that that flag could not take a
regex. It can, and the reports flag uses that form, so ignore that argument if it resurfaces — the anchors
are the real reason and the only one that has to change.)*

### `discard:<flag>` — the escape hatch

```
discard:<flag-name>
```

What makes the component-level recommendations reversible per string: `discard:asciidoc-text` on the six
`.resx`-sourced documentation units, `discard:md-text` on any YAML-sourced reports unit that misbehaves,
`discard:placeholders` where needed. Like every per-string flag it is a source-string extra flag, so it is
invisible in git — the trade-off the configuration reference records.

### `max-size` — the metadata labels a generated form has to fit, once the generator emits the flags

```
max-size:<width>[:<lines>], font-family:<name>, font-size:<points>
```

**Adopted in principle, not yet wired**, and it replaces `max-length` rather than joining it. The two are
not variants of one idea: `max-length:100` counts *characters*, which is the same proxy the XSLT wrapper
used and the reason it failed — `IIIII` and `WWWWW` are the same length to a counter and nothing like the
same width on paper. `max-size` renders the translation and measures **pixels**, wrapping it across the
number of lines allowed. Verified against the upstream documentation, whose own example is
`max-size:500:2, font-family:ubuntu, font-size:22`.

What makes it worth doing here rather than merely correct: the repository now ships the very font files
the build embeds, in `common/fonts/`. Upload those to the Weblate project and one file governs all three
places a width is decided — the check a translator sees while typing, the measurement the sheet generator
lays out with, and the face the PDF embeds. Today only the last two agree, and the translator finds out
by having their work rejected by a build they never see.

Two things to settle before enabling it, neither of which the checks documentation answers:

- **How a font becomes available.** `font-family` names something the project already holds; the check
  page does not say how it gets there, so the font-management side has to be read before this is
  configured, not after.
- **The flags are per string, not per component.** A label's real budget is the width of *its* cell, and
  the cells differ per field, so a single component-level `max-size` would be wrong almost everywhere. It
  therefore has to be emitted per entry, by whatever writes the metadata catalogue, from the same layout
  the generator uses. That makes this a downstream consequence of the sheet generator rather than a
  configuration change that can be made on its own.

The generator's own measurement stays regardless. Weblate cannot know a cell's width, so the check is
feed-forward for the translator and the build gate remains the backstop — the one that actually refuses
to publish a sheet whose text does not fit.

## Defects this survey found

These are not configuration; they are broken translations that are shipping. They are fixed **through
Weblate**, because the catalogues are Weblate-owned.

**Translated cross-reference anchors — about ten, in German and Spanish.** Five German `<<xref>>` ids
(`<<bsi-spezifischen Daten_cvc>>`, `<<bsi-spezifische-daten_pvc>>`, `<<bsi-spezifischen Daten_pvc>>`,
`<<pneumonie-spezifischen-daten_inv>>`, `<<pneumonie-spezifische-daten_niv>>`), one Spanish
(`<<neumonia-specific-data_inv>>`), one `xref:` pointing at an anchor that does not exist, one dropped
`xref:patient-progress-chart[]`, and `footnote:` rendered as `Fußnote:` / `nota:`. Each silently breaks a
cross-reference in the rendered protocol.

Confirmed genuine rather than a language convention: when this was surveyed, every `[[anchor]]`
definition was translated in German with its id carried through unchanged, and none of the German xref
targets existed as an anchor anywhere — so the ids in those references were invented rather than
translated from something real.

That survey ran before the protocol gained its explicit short-anchor scheme, and the anchor half of it
has since been overtaken: **every** id was rewritten in that pass, so a count taken against the current
template measures the new scheme rather than the surveyed one. The finding it supports is unaffected —
five German references still point at targets that exist in no language, which is exactly the defect
`asciidoc-text` is being enabled to catch, and the reason the scheme was made explicit in the first
place. Re-derive the anchor counts from `po/documentation.pot` rather than quoting the numbers above;
the coverage figures earlier in this document have been re-measured against the current template.

**Merge-conflict markers in translated text — fifteen strings.** German (3) and Spanish (12)
`documentation` entries contain raw po4a/`msgcat` conflict text in the `msgstr`, e.g.
`#-#-#-#-#  NeoIPC-Core-Protocol.de.adoc:169 (type Block title)  #-#-#-#-#`. **The three German ones are
not fuzzy**, so they are shippable. They also account for roughly 40 % of the project's entire current
check noise — fixing them improves every other measurement before a single flag is set.

**Dropped Markdown links and inline R spans — four.** Spanish and Italian both dropped a link from the
Reference-Report introduction; German dropped the inline R span from two table-introduction paragraphs,
silently removing computed content from the rendered report.

## What stays in the repository's own gate

Weblate cannot express these, so `scripts/Test-PoPlaceholders.ps1` remains necessary rather than redundant:

- **Content** equality of an inline R span. A translation that rewrites a variable name inside `` `r …` ``
  keeps the token count and passes every Weblate check — and that is arbitrary code reaching the renderer,
  not a formatting slip.
- **Count** parity where Weblate compares sets: both `md-syntax` and `md-link` degrade to set or count
  comparisons that a partial drop survives.
- Anything requiring real logic. Custom checks need a Python class registered server-side, which a hosted
  instance cannot accept.

It runs in CI as the `po-placeholders` job, **report-only** for now: the committed catalogues already carry
violations, and every one of them sits in a Weblate-owned `.po` that the ownership gate forbids changing in
a pull request, so a blocking gate would fail every pull request over defects only Weblate can fix. Run the
script for the current count rather than quoting one — it moves with every drain. Dropping `-ReportOnly`
from the job is the whole of the change that makes it blocking, and the right moment is once the findings
below are fixed through Weblate. The switch waives the violation count and nothing else: a run that matched
no files, or a catalogue it could not parse, still fails. That is deliberate — waiving the failure with the
workflow's own `continue-on-error` would have waived those too, and a gate reporting success having
inspected nothing is the failure shape this repository has already been bitten by.

## Fixups: no decision to make, but you must know

Fixups **mutate a translation on save**. They are a server-level list, not configurable per project, so
these are facts to work around rather than choices.

- **Punctuation spacing** inserts a space character before `: ; ! ?` in **French**, and we have French
  catalogues. Any rule banning non-ASCII characters must be scoped to hyphens alone or it will fight this
  on every French string.
- **Trailing ellipsis** rewrites `...` to `…`.
- Zero-width-space removal, control-character removal, Devanagari danda, unsafe-HTML cleanup and the
  leading/trailing whitespace fixer complete the list.

## Rejected, so it is not re-litigated

The entire per-language format-string family is **not applicable**: PHP, Java (printf and MessageFormat),
JavaScript, ECMAScript templates, i18next, Qt, Ruby, Scheme, Lua, Objective-C, Object Pascal, AngularJS,
Automattic, Vue, Laravel, Perl (both), C#, percent-placeholders. Several are exact behavioural aliases of
`c-format` under another name; several actively misparse our content — Laravel's pattern *is* AsciiDoc
macro syntax, Scheme's is AsciiDoc subscript, and `python_format` would accept `%(name)s`, which R's
`sprintf` does not.

`safe-html` is rejected on measurement: no source string contains HTML, while its attached fixup would
strip the Markdown links that *are* there.

`ignore-all-checks` is rejected explicitly because it is the obvious shortcut for bulk-suppressing the
nomenclature strings and it would discard the checks that still matter on them.

The Fluent family is inapplicable, and its two syntax checks are actively wrong here — they validate
rather than compare.

## The five string-information fields, and who owns each

A translator's sidebar carries five things beside the string. They divide cleanly by **where the truth
lives**, and that division decides everything about how they are maintained.

| field | source of truth | reaches Weblate by | survives a component reset |
|---|---|---|---|
| Source string description | the `.pot` `#.` comment | generated, committed | yes — it is re-read from the template |
| Flags (source) | the `.pot` `#,` line | generated, committed | yes |
| Flags (per-string extra) | Weblate database | web interface or API | yes, but invisible to git |
| Explanation | Weblate database | web interface or API | yes, but invisible to git |
| Labels | Weblate database | web interface, API or bulk edit | yes, but invisible to git |
| Screenshots | Weblate database plus an uploaded image | API | yes, but invisible to git |

**Anything derivable from the authored source belongs in the template.** It is then reviewable in a diff,
survives every `msgmerge`, and cannot drift from the string it describes. po4a already does this much: the
`type: Title ==` a translator sees on a protocol heading is a `#.` comment it extracted.

**Everything else lives only in Weblate's database, and that is a durability problem rather than a
preference.** This project has already reset components to recover from a diverged checkout; a reset
preserves the database, but a *recreate* does not, and neither route is covered by any backup this
repository controls.

**Size the remedy to the failure, though.** A committed manifest with a script that applies it is keyed to
the source string, so it restores what a *component recreate* destroyed — msgids are unchanged there. It
does nothing about the likelier destroyer: editing a source string retires its unit and takes the
explanation with it, and invalidates the manifest entry for that msgid in the same stroke. The
source-string migration does exactly that, wholesale. So a manifest guards the rare accident and not the
scheduled one, and it should be built when something actually needs it rather than as a precondition for
writing any explanation at all.

Two consequences follow, and the second is **per catalogue rather than blanket** — an earlier revision
here said no po4a module carries translator comments, which is wrong for the one catalogue where it
matters most.

**Where guidance is derivable from the authored source, put it in the description and no manifest
arises.** The glossary does this already, its generator carrying YAML comments through into the template.
Measure the proportion from the current template rather than quoting one here; this branch alone moved it.

**`documentation` can do the same, from the AsciiDoc source.** `AsciiDoc.pm` collects `//` line comments
and `////` comment blocks and passes them to every `translate()` call as the `comment` option, which
`TransTractor.pm` maps to the PO `automatic` field — the `#.` line this document's own table names as the
source of truth for a source-string description. So a note written above a protocol paragraph reaches the
translator, is reviewable in a pull request, and survives a recreate, a reset and the source-string
migration alike. Prefer it to an explanation wherever the guidance belongs to the document.

**`reports` and `infectious_agents` genuinely cannot**, and this is where an explanation is the only
route: `Text.pm` declares a comments list and never fills it, and `Yaml.pm` has no comment handling at
all. Those explanations carry the same sequencing constraint as editorial approval, and for the same
reason: both are database-only and both die with the unit, so both are written **after** the migration
that rewrites msgids, not before it.

### What fills each field is per catalogue, not uniform

The discipline is the same everywhere; the content is not, because the catalogues do not resemble each
other. Filling them uniformly would be worse than filling them well.

| catalogue | description | source flags | explanation earns its place when |
|---|---|---|---|
| `documentation` | po4a's block type | `asciidoc-text` | an anchor id or macro name must survive unchanged |
| `reports` | the YAML key path, once `msgctxt` exists | `md-text`, `placeholders` | a placeholder's resolved value is not guessable from its name |
| `glossary` | the authored YAML comment | `terminology`, `read-only` | a term collides with another this project uses — `Watch` against *surveillance* |
| `metadata` | the DHIS2 object and field | `placeholders` | the string is a data-entry label whose length is constrained |
| `infectious_agents` | rank and concept type | `ignore-same` | the language's own convention for nomenclature is the question |

Screenshots are worth the effort only where the msgid cannot carry the context — a composed callout
clause, a table cell whose meaning depends on its column. A heading does not need one.

## Traps worth keeping

- A check identifier is not its enabling flag.
- "Automatic for X files" does not fire for gettext PO extracted from X.
- **Fuzzy units are checked.** Any measurement taken over non-fuzzy units alone understates the benefit —
  most live findings here sit on fuzzy units.
- `md-syntax`, `asciidoc-markup` and `placeholders` have **no source-side early return**, so a
  component-level flag puts every unit in scope and a token the *target* invents fires on its own.
- `po_line_wrap`, `check_flags` and per-string flags are three different delivery routes with three
  different persistence properties. See the configuration reference.
- **The source string description says which format a string came from, and where.** po4a writes its
  extraction type into the note, so the sidebar answers "is this Markdown or AsciiDoc or a YAML value?"
  without opening anything: `type: Hash Value: <key>` is a YAML mapping value under that key,
  `type: #sec-<id>` is the AsciiDoc section the string sits in. Worth knowing before judging whether a
  component-level flag suits a particular string — a YAML value looks like plain text and frequently is
  not, since the report string resources carry Markdown, links and inline R spans. Reading the note beats
  querying the API for the same fact.
