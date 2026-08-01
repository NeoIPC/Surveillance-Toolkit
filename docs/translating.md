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

Many terms appear three times in different casings — `necrotizing enterocolitis`, `Necrotizing
enterocolitis`, `Necrotizing Enterocolitis`. That is not duplication: reports use the first in running
text, the second for a label, the third in a heading. Your language may well not distinguish them, in
which case the same rendering three times is the correct answer. Weblate groups the variants together so
you can see them side by side.

**Reports** — the prose partners actually read: methods paragraphs, table headings, footnotes, and the
interpretation text beside an unusual result. The most consequential catalogue for tone, and the one
where the style rules below matter most.

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
- A few older strings still use `%s` instead. Same rule, and here the order **cannot** change, which is
  why they are being replaced.

**In the DHIS2 metadata** — tokens like `#{NEOIPC_BSI_PATHOGEN_1}` and `V{event_date}`. Identifiers
again: keep them verbatim.

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

## Review

Review is enabled on this project. A string you save is *translated*; a reviewer then marks it
*approved*. Both states are visible in the sidebar, and `state:translated` as a search is exactly the
queue of work awaiting review in your language — worth bookmarking if you review.

**Reviewer teams are being formed and are not yet in place for every language.** Until yours has one,
your translations land and are used without a second reader. That is a reason to flag anything you were
unsure about in a comment rather than to hesitate over saving it — an uncertain translation with a
comment is far more useful than a confident one without.

**Comments are the channel for anything that needs a person.** They support `@username` mentions, they
notify, and they stay attached to the string. Do not send translation feedback through a pull request on
GitHub: those are opened by an automation account and the translator who wrote the string will never see
the comment.

**Strings marked "needs editing" that look like untouched English** are not translations anyone made.
They come from an earlier bulk import and mean nothing has been decided for that string yet. Treat them
as untranslated.

## When something is wrong in the English

Say so — comment on the string, or write to **NeoIPC-Support@charite.de**. Source strings here have been
ambiguous, have contained typos, and in a few cases have been impossible to translate well because they
were assembled from fragments. All of those were found by translators, and fixing the source is better
than nine languages each working around it.
