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
footnote is intact; fix that in the source rather than with a flag.

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
same day. That is a real pass rather than an inert check — German holds the whole glossary against
several hundred translated report units, so there was ample for it to fire on.

**The dependency worth knowing: the check can only bite in a language once that language's glossary is
translated.** Spanish and Italian carry a handful of terms between them, so almost nothing is enforceable
in either yet, however much report prose they accumulate. This is what makes the glossary component's
*Very high* priority operational rather than decorative — translating that component first is what
converts terminology agreement into enforcement across every other catalogue, and it is a few dozen
strings rather than a project. Read the component's own statistics for where each language stands; these
figures move whenever anyone translates a term.

### `discard:<flag>` — the escape hatch

```
discard:<flag-name>
```

What makes the component-level recommendations reversible per string: `discard:asciidoc-text` on the six
`.resx`-sourced documentation units, `discard:md-text` on any YAML-sourced reports unit that misbehaves,
`discard:placeholders` where needed. Like every per-string flag it is a source-string extra flag, so it is
invisible in git — the trade-off the configuration reference records.

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
repository controls. So database-only content needs a **committed manifest and a script that applies it**,
or it is one accident from being lost with no way to tell what was there.

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
