# Translating the NeoIPC Surveillance Toolkit

For translators and reviewers working in
[Weblate](https://hosted.weblate.org/projects/neoipc/). If you only want to know *where* to work, the
short answer is in [`../CONTRIBUTING.md`](../CONTRIBUTING.md); this is the longer answer about the
material itself.

**Read the project's own translation instructions in Weblate before you start.** They are shown on the
project page and cover terminology, placeholder integrity and the policy on scientific organism names.
They are not repeated here, deliberately — a second copy is the one that goes stale. The same applies to
the contributor agreement Weblate shows you before your first contribution: it explains what becomes a
permanent part of the public git history, and it is worth reading rather than clicking through.

## What each catalogue is, and who reads it

They do not resemble each other, and the right instinct in one is the wrong instinct in another.

**Glossary** — around fifty controlled terms: `BSI`, `CVC`, *necrotizing enterocolitis*, the WHO
antibiotic categories. Small, and it is the highest-priority component for a reason that is mechanical
rather than symbolic: a term translated here becomes the agreed rendering everywhere else, and a term
*not* translated here cannot be enforced anywhere else. Clearing it is an afternoon and it makes every
other catalogue easier to review.

**Each term appears once**, in the form it takes in running text — `necrotizing enterocolitis`, lower
case. Where a report needs it capitalized for a label or a heading, the capital is applied when the report
is built, not translated as a second entry. So translate the term as you would write it mid-sentence, and
if your language capitalizes differently from English that is handled for you. (Terms that are capitals
anyway — `BSI`, `MRSA`, `NeoIPC Surveillance` — are unaffected.)

**Reports** — five separate documents in one catalogue, and they are **not** written for the same reader.
The location line under each string tells you which one you are in, and it changes the register more than
anything else in this guide does:

| document | who reads it |
|---|---|
| **Partner-Certificate** | pinned to a wall in the hospital — the general public |
| **Reference-Report** | published on the NeoIPC website — the general public, including political stakeholders |
| **Patient-Data-Report** | parents, and possibly legal teams acting for them |
| **Partner-Report** | everyone on the ward whose work can affect infection rates — investigators, but just as much the nursing staff, and in some settings the cleaning staff |
| **Validation-Report** | data collectors and team leads, checking their own data |

Two consequences. **"Clinical register" is the wrong default** — the Partner-Report is read by people who
are not clinicians and whose work matters just as much, so plain language beats professional shorthand
wherever both are accurate. And a large shared layer (`reports/common.yaml`) is used by **all five**, so a
string there has to work on a wall, in a parent's hands, and in a data collector's checklist at once. If
one of those readings makes a shared string impossible in your language, say so in a comment rather than
choosing which reader to serve — that is a problem with the English, and it is fixable.

**Core surveillance protocol** — the reference document describing the surveillance itself: definitions,
inclusion criteria, data collection. Read by clinicians and infection-control staff setting up a
department. Formal register; precision beats fluency.

**DHIS2 metadata** — the labels on the data-entry forms. Someone reads these while typing a patient's
data at a keyboard, so they are short by necessity and often cannot be lengthened without breaking a form
layout. Terse is correct here.

**App** — the web interface for requesting reports. Ordinary interface language: buttons, headings,
messages.

**Infectious agents** — several thousand scientific organism names, their synonyms, and rank labels such
as *Species* and *Genus*. Read the project instructions about this one before touching it; the short
version is that if your language uses these names unchanged, do not confirm thousands of entries by hand
— tell us and we will fill them in for your language in one batch.

## The markup you will meet, and what must survive

Every catalogue is extracted from a source document, and some of that document's syntax comes with it.
Anything in the list below is machinery: it must appear in your translation exactly as it does in the
source, even where it looks like a word.

**In the protocol** — AsciiDoc. Cross-references look like `<<sec-eligibility>>`, anchors like
`[[abbr-cvc]]`, and macros like `footnote:note-1[]` or `xref:target[]`.

- **The identifier inside is not translatable.** `<<sec-eligibility>>` stays `<<sec-eligibility>>`. It is
  the name of a place in the document; renaming it points the reference at nothing, and the rendered
  protocol then carries a broken link that no reader can follow back.
- **The macro name is not translatable either.** `footnote:` stays `footnote:` — it has been rendered as
  *Fußnote:* and as *nota:* here, and in both cases the footnote silently disappeared from the output.
- Text *after* the identifier usually is translatable: in `xref:patient-chart[the patient chart]`, the
  part in square brackets is what a reader sees.

**In the reports** — Markdown, plus two things that are not Markdown.

- Links: `[text](https://example.org/)`. Translate the text, leave the target alone.
- **Inline R spans**: `` `r some_expression` ``. Everything between the backticks is computed when the
  report is rendered — a number, a date, a department name. It is code, not text. Translating anything
  inside it either breaks the render or silently produces the wrong figure.
- **Quarto cross-references**: `@tbl-resistance`, `@fig-rates`, `@sec-methods`, and heading anchors like
  `{#sec-methods}`. Same rule as the protocol's: the identifier is a name, not a word.
- **Named placeholders**: `{count}`, `{department}`. Keep every one, spelled exactly. Their *order* may
  change freely to suit your language — that is precisely why they are named rather than numbered.
- **`%s` and `%i`**, which are still the *majority* form here — around one string in seven carries one,
  against a much smaller number using the named form above. Same rule about keeping them, but here the
  order **cannot** change: they are filled positionally, so swapping two puts each value in the other's
  place. That is why they are being replaced, and why until they are, a sentence whose natural word order
  differs from English is worth a comment rather than a rearrangement.

**In the DHIS2 metadata** — tokens like `V{program_name}`, `A{yQwpowV0o08}` and
`#{NeoIPC HAP Virus detected}`. All three are identifiers; keep them verbatim, braces included. The last
form is the one to watch, and it is common: the text inside those braces is an English phrase naming a
field, not a phrase for the reader, so it looks translatable and is not. Translating it does not produce
an awkward sentence — it stops the rule from finding the field at all.

**In the glossary** — nothing. Plain terms.

## The checks, and what they are telling you

Weblate will flag some translations as *failing checks*. They are advisory — nothing stops you saving —
but each one exists because the corresponding mistake has shipped here at least once.

| Check | Fires when | What to do |
|---|---|---|
| **Does not follow glossary** | Your translation of a string does not use the agreed term for something in the glossary | Use the glossary term, or say in a comment why it does not fit |
| **AsciiDoc markup** | An anchor, cross-reference or macro differs from the source | Restore the identifier exactly; translate only the visible text |
| **Markdown** | A link or formatting delimiter was dropped or added | Restore it. Dropping one link out of two passes silently, so check them all |
| **Placeholders** | A `{name}`, `@ref` or inline R span is missing or invented | Restore it exactly. An invented one fires too, which is intentional |
| **C format** | A `%s` was dropped, added or reordered | Restore it in the source's order |
| **Unchanged translation** | Your translation is identical to the English | Often correct here — an initialism or a scientific name may be right unchanged. Ignore it in that case |

**One check rewrites your text rather than warning you, and it is on for French.** Weblate inserts a
space before `: ; ! ?` automatically, which is correct French typography and is applied on save. It is
not a mistake in your work and it is not something this project configured; mention it if it ever gets
in the way.

## Style

**Use the glossary term.** Where a term has an agreed rendering it is in the glossary, and the glossary
wins — even where you would have chosen differently. If an entry is wrong, say so in a comment rather
than translating around it; the entry is what the next translator will follow, and a disagreement settled
in one string is a disagreement that recurs in the next fifty.

**Follow the AMA Manual of Style** where your language has no stronger convention of its own. The one
that catches people: disease names are common nouns and stay lowercase in running text — *necrotizing
enterocolitis*, *pneumonia* — unless they contain a proper noun.

**Do not make report prose imperative.** Where the English says *"this may warrant attention"* it
deliberately does not say *"review this patient"*. A report cannot know a department's clinical context,
so it suggests rather than instructs. Translations that sharpen the tone into an instruction change what
the document is claiming, and this is the single most common thing corrected in review here.

**Numbers and units** follow the source's spacing and separators; both are themselves translatable
strings, so if your language groups digits differently, that is a glossary-level fix rather than a
per-string one. Ask rather than improvising per string.

## Long words, and how to tell us where they may break

Some of what you translate is not prose on a page: field labels and option names from the **DHIS2
metadata** catalogue are printed onto the data collection sheets — the paper forms filled in at a cot
side — where each has a box of a fixed width. The layout measures your text in the real font and wraps it
between words. What it cannot do is break *inside* a word, and a language that builds compounds produces
words no box will hold: *Gestationsalter* is already a single token wider than several of the boxes it
appears in.

**You can say where such a word may divide, by putting a soft hyphen at each point.** It is the invisible
character U+00AD, and it is a hint rather than a hyphen: nothing is drawn where you put it. If the word
fits, it is simply not used. If the word has to break, it breaks at one of the points you marked and a
real hyphen appears there — never anywhere else.

- **Type it** by adding it once to *Special characters* in your Weblate profile — the row of characters
  above the editing box is built from that setting plus per-language punctuation, so a soft hyphen is
  there only if you put it there. Otherwise paste one. It is invisible wherever you type it, which is
  expected; Weblate will show the string as changed although it looks identical.
- **Mark every plausible point**, not just one: `Gestations­alter`, `Antibiotika­kategorie`. The
  layout picks whichever fits and ignores the rest, so more points give it more room and cost nothing.
- **Leave a word unmarked when it must not be divided.** A clinical term split across a line can be
  misread, and that judgement is yours. There is no list to maintain and no setting to change — an
  unmarked word simply never breaks.
- **They are never wrong in a string that does not need them.** A marked word that always fits behaves
  exactly as an unmarked one.

If a word cannot be made to fit even with the breaks you gave it, the build stops and says which string
and which box — it does not quietly print text running off the edge of the form, which is what the
previous generation of this tooling did for years. So an over-long label comes back to you as a question
rather than shipping as a defect.

Two things this is **not**. It is not hyphenation of the running text — the protocol and the reports set
their own text and need nothing from you. And it is not a way to force a line break: it only ever offers
one.

## Review

Review is enabled on this project. A string you save is *translated*; a reviewer then marks it
*approved*. Both states are visible in the sidebar, and `state:translated` as a search is exactly the
queue of work awaiting review in your language — worth bookmarking if you review.

**Every language has a reviewer team; several are still without members.** Until yours has one, your
translations land and are used without a second reader. That is a reason to flag anything you were unsure
about in a comment rather than to hesitate over saving it — an uncertain translation with a comment is far
more useful than a confident one without.

### If you review

**Do not approve your own translation.** Saving it is your contribution; approving it is a second
person's judgement, and one person cannot be both. Weblate will let you — no permission expresses "not
your own work" — so it is a convention rather than a control, in the way editorial recusal works in
journals.

Where you are the only editor for your language, your own translations stay *translated* and wait. That
is the honest state: it says nobody has read this yet, which is true, and it is more useful than an
approval meaning only that you approved of yourself. If a second reader appears later, the queue is
exactly the strings still sitting in that state.

The same applies upwards. Someone holding project administration can approve any language, including ones
they cannot read; the convention is that they do not, except for mechanical corrections.

**Comments are the channel for anything that needs a person.** They support `@username` mentions, they
notify, and they stay attached to the string. Do not send translation feedback through a pull request on
GitHub: those are opened by an automation account and the translator who wrote the string will never see
the comment.

**Leave soft hyphens alone.** A metadata string may carry invisible U+00AD marks saying where a long
compound is allowed to divide on the printed collection sheets (see *Long words* above). They render as
nothing, so a translation carrying them looks identical to one that does not — and retyping the word to
"clean it up" removes information the layout depends on, with no visible sign that anything changed.
Judge the wording; the marks are the translator's answer to a layout question, not a typo.

**Strings marked "needs editing" that look like untouched English** are not translations anyone made.
They come from an earlier bulk import and mean nothing has been decided for that string yet. Treat them
as untranslated.

## When something is wrong in the English

Say so — comment on the string, or write to **NeoIPC-Support@charite.de**. Source strings here have been
ambiguous, have contained typos, and in a few cases have been impossible to translate well because they
were assembled from fragments. All of those were found by translators, and fixing the source is better
than nine languages each working around it.
