# Generating the data collection sheets

The sheets a partner fills in — the master sheet, the patient progress chart, the surgical procedure
sheet, and one reporting sheet per infection type — are generated from the canonical metadata rather than
drawn. This is the contract that generation works to, and the reasons behind the parts of it that are not
obvious.

## Why generated at all

The sheets are the paper equivalent of the DHIS2 program stages: the same sections, in the same order,
with the same fields, the same option lists and the same mandatory flags. Everything a form needs is
already authored in `metadata/common/`, so a drawn sheet is a second statement of facts that already have
a canonical home — and it can disagree with the data model without anything saying so.

Hand-drawing was tried and abandoned half-way, which is the practical half of the argument. Two SVGs came
out of it and neither is in the tree any more: a master sheet that was minimal and hand-written and
stopped after the first few fields, and a chart that was A4 landscape and carried 367 `<path>` elements
where the grid should be `<rect>` and `<line>` — editor output with the namespaces stripped rather than
something anyone would maintain by hand. Both are recoverable from git history; nothing reads them.

## The progress chart is one of the family, not an exception to it

It reads as the exception — a grid of days rather than a list of questions — and that reading is wrong in
the way that matters: **its rows are derivable, one for one.** Every one of the eighteen is a
surveillance-end day count that the master sheet also prints: `NEOIPC_SURVEILLANCE_END_PATIENT_DAYS`, the four device counts, human milk, kangaroo care,
probiotic, the antibiotic total, and the nine substance slots. So it is generated from the same metadata,
in the same order, by the same generator.

What genuinely is not in the metadata is the **transposition** — thirty-one day columns, a totals column,
and the two fields that let a loose sheet be filed (Month/Year, Chart no). Those are decisions about
paper, exactly like the marker on a boolean or the printed slot count, and they live in
`common/sheet-layout.yaml` with the rest of them. Nothing about the chart needed a second mechanism.

Two consequences follow from being generated rather than drawn, and the second is why the argument matters
more here than on any sheet. It becomes localizable, which it has never been. And a row can no longer go
missing: **on a grid, an absent row looks exactly like a grid** — no gap, no stray label, nothing a
proof-reader could catch — so a day count added to the stage would simply stop being tallied, on paper,
with nothing to say so. `test_the_chart_holds_every_day_count_the_stage_has` compares the printed rows
against the metadata for that reason.

The chart carries **no legend and no `required` markers**. Both belong to a form that captures values;
this page has neither a choose-one circle nor a choose-any square on it, and whether an answer is
compulsory is a property of the master sheet's fields rather than of the tally that feeds them. The
legend's absence is read off the marks actually emitted rather than declared per form, so a sheet that
lost its options would drop its legend with them instead of printing a key to shapes it no longer has.

## Source

`metadata/common/`, and nothing else:

| what a form needs | where it is |
|---|---|
| section structure and order | `programStageSections.csv` — `sortOrder`, `dataElements` |
| field order, mandatory, widget | `programStageDataElements.csv` — `sortOrder`, `compulsory`, `renderOptionsAsRadio` |
| the printed label | `dataElements.csv` — `formName`, with `valueType` and `optionSet` |
| choice lists | `optionSets.csv` / `options.csv` |
| the enrolment block | `trackedEntityAttributes.csv` + `programTrackedEntityAttributes.csv` |

**No intermediate document.** A YAML layer between the metadata and the generator would be a second place
these facts live, which is the defect being removed rather than a step towards removing it.

`DataDictionary.ps1` already resolves sections → stage elements → option sets and already implements the
label preference (`formName`, then `name`, then `shortName`). The generator applies the same rules; where
they are restated in another language, they are restated deliberately and must not drift.

## Two outputs, one layout

| output | consumer |
|---|---|
| SVG per sheet per culture | the protocol's figures, embedded `opts=inline` so the text is real text |
| standalone PDF per sheet per culture | the forms published for partners to print and fill in |

The published forms are the reason this is more than a figure generator. They are currently maintained
outside this repository, which makes them a third statement of the same field list; folding them into the
generator is what removes that, and it is also what makes them localizable, since today they exist in
English only.

The two are emitted from one set of placements: the layout measures and positions everything once, and
each output serializes that. So they cannot disagree about which fields a sheet has, in what order, or
where anything sits — only about typography too fine to see. The SVG is written by this generator; the PDF
is compiled by **Typst** from a `.typ` this generator also writes, for the reasons set out under *Which
engine draws it*.

## What the renderer actually supports

Established by rendering, then confirmed against `refs/prawn-svg` (v0.34.2, the version
`asciidoctor-pdf ~> 0.34.0` resolves). Both halves matter: the render says what happens, the source says
why, and neither alone would have been trusted.

| construct | behaviour |
|---|---|
| `<symbol>` + `<use>`, with `viewBox` | renders, scaled correctly |
| `<g>`, `<defs>`, `<clipPath>`, `<marker>`, gradients | supported |
| `<image>` raster | renders; **`xlink:href` resolves relative to the SVG file**, not to the document |
| `<filter>` (incl. `feDropShadow`) | **silently ignored** — fails closed, see below |
| `<mask>` | **silently ignored** — fails OPEN, see below |
| `<foreignObject>` | ignored |

`prawn/svg/elements.rb` maps both `filter:` and `mask:` to `Elements::Ignored`, commented `# unsupported`,
and `Ignored#parse` raises `SkipElementQuietly` — no warning on either. **The two are not equally
harmless, and the difference is the whole point.**

A **filter** fails closed: the shape draws without its decoration. A drop shadow goes missing and nothing
is misrepresented, so a browser shows the SVG with the shadow and the PDF without it — a cosmetic
divergence between the two outputs and no more. It is also forward-compatible: an artwork carrying one
simply starts working if prawn-svg gains support, so there is no reason to strip a filter from hand-drawn
artwork.

A **mask** fails open, and that is a real hazard. Neither the `<mask>` element nor the `mask=` attribute is
consumed anywhere in `lib/`, so a masked shape renders **fully visible** — whatever the mask was hiding
appears. A construct that hides something must never be a mask here.

**The generator emits neither**, because its layout needs neither: everything on a form is a rule, a
block, a mark or a run of text.

The relative-`href` rule is why a raster referenced from a generated SVG is named relative to *that SVG*
rather than to the document: an `xlink:href="img/LOGO_NEOIPC_2.png"` written from inside `img/` sends the
renderer looking for `img/img/…`.

**A document stylesheet does not reliably reach inside a `<symbol>`, so the logo states its colours
twice.** The inlined mark's paths carry `.brand-blue` and `.brand-orange`, and the rule defining them
lives in the sheet's one stylesheet. prawn-svg and browsers apply it — which is why every sheet rendered
so far has a coloured logo, and why no rendered output would ever reveal the problem. **Inkscape does
not**, so a mark styled by class alone opens black there. Proven on the decision flow by an asymmetric
pair: a tick styled that way fell back to the default fill and drew as a filled triangle, while a cross
drawn as zero-area subpaths vanished outright — two different wrong results from one cause, which an
explanation that was merely plausible could not have produced.

So each path carries its fill as a **presentation attribute** as well. The class stays, and the direction
matters: CSS outranks a presentation attribute, so the stylesheet is still what decides wherever it is
read at all, and `brand-blue` remains something a consumer can restyle. The attribute only fills the gap
where no stylesheet is applied. What it buys is that a maintainer opening a generated sheet sees the
mark — which is the whole justification for the house style below, and the one consumer no published
output speaks for.

## One image directory per culture, and the two things a figure may be

Every image the protocol reaches is named without a culture in it — `NeoIPC-Core-Master-Sheet.svg`, not
`NeoIPC-Core-Master-Sheet.de.svg` — and the build decides which file that is by assembling **one image
directory per culture**: `doc/protocol/img` for the untranslated source, `doc/protocol/<culture>/img`
beside each translated one, which is where po4a already puts that culture's protocol, definitions and
generated lists. `:imagesdir:` is `{locale-dir}/img`, so a target resolves inside the culture being built
and a figure that becomes localizable later simply starts being found there, with no change to the
document at all.

**A target is not offered for translation, and that is what the directory buys.** po4a extracts a block
image's target as its own translatable unit, on the reasoning that a translation may want to point at a
translated image — which asks a *translator* to answer `NeoIPC-Core-Decision-Flow.svg` with
`NeoIPC-Core-Decision-Flow.de.svg`, a filename convention nothing tells them about, in a field that looks
like text to translate. It is silent in the worst way: a target that still resolves shows the English
figure, and only one that fails to resolve says anything at all. So the extraction is switched off —
`noimagetargets` in `po/documentation.po4a.cfg`, which also suppresses po4a's default registration of the
image *attribute* list, so `image[1,alt,title,link]` is re-registered without the trailing `_` to keep the
alt text, title and link translatable while leaving the target alone. **Alt text is a translator's; a file
name is not.**

**The classification is `may it vary`, not `can it be localized`** — the second question has a shrinking
answer and would need re-asking every time it shrinks. So:

| class | what the build does | example |
|---|---|---|
| generated per culture | written straight into that culture's directory | the seven sheets, the AWaRe badges, the decision flow, the title page, the preview watermark |
| invariant mark | the shared file only; a per-culture variant **fails the build** | the NeoIPC logo |

The NeoIPC logo is the second row because **a wordmark is a name**, which is why even its text form is
never translated; a licence badge would be there too, its recognizability being the whole of its function.
A localized variant of either is a defect rather than an improvement, so the build refuses one instead of
quietly preferring it — the failure mode of silently preferring being a mark that nobody decided to vary,
published in one language only.

**A third class is worth naming even though nothing is in it: a shared figure that may gain a localized
form.** It would be served this culture's file wherever one appeared and the shared file otherwise.

It is named rather than left out because of which question the classification asks. The axis is **may it
vary**, not *can it be localized* — the second has a shrinking answer, and a figure that looks unlocalizable
usually is not: the AWaRe badges read as fixed marks and are a single translated letter each. Sorting by
the second question puts figures in the invariant row that have to be taken out of it again, and the
invariant row is the one whose members the build refuses to vary.

**HTML keeps its images as files, so they travel with the document.** An inlined figure is part of the
page, but a plain `image:` macro becomes an `<img src>` the browser resolves against the document, and
**asciidoctor never copies an image**. The same per-culture layout is therefore reproduced under
`artifacts/`, and a figure that is not inlined is a broken image in the published HTML the moment it is
not — which is invisible in the PDF, where the same target embeds correctly.

## Text measurement, and the font it must measure

The XSLT this replaces wrapped text by counting **characters** — a hand-rolled recursion over
`string-length` against four constants tuned by eye. `IIIII` and `WWWWW` are the same length to it, a
token longer than the constant is emitted whole and overflows, and XSLT 1.0 has no font metrics at all, so
fitting text to a box is not expressible in the language the code was written in.

Generation measures with **fontTools**: advance widths in the actual face at the actual size, wrapped to
the cell width the generator chose, emitted as explicit `<tspan>` with `dy`. Never renderer-side wrapping
(SVG 2 `inline-size`, `<foreignObject>`) — the explicit form is what ships and renders today.

**Summing advance widths is not shaping — and because the renderer does not shape either, the sum is
exact.** The measurement adds up each codepoint's advance from `hmtx`. What matters is whether the
renderer does more, and it does not: `prawn/svg/renderer.rb` hands the raw string to Prawn's `draw_text`
and takes its width from `width_of`, and prawn-svg contains no shaping layer anywhere. So the sum is not
an approximation of the drawn width, it *is* the drawn width, and adding a shaping engine here (HarfBuzz
via `uharfbuzz`) would introduce a disagreement with the renderer rather than resolve one.

Kerning is requested — `width_of(text, kerning: true)` — and has nothing to act on. All four faces in
`common/fonts/` carry `GPOS` and **no `kern` table**, so a consumer of the legacy table finds no pairs.
asciidoctor-pdf's own bundled subset is the other way round, a `kern` table of 15,534 pairs and no `GPOS`,
which is a second reason the theme points at this repository's fonts rather than the gem's: the file
measured and the file embedded must be the same file, and it should also be the one whose width is
predictable.

**The casualty is Devanagari, and it is a rendering defect rather than a measurement one.** Noto Sans
Devanagari carries `GSUB` and `GPOS` because the script needs them — consonants fuse into conjuncts, the
vowel sign ि is drawn *before* the consonant it follows in memory, and marks stack. None of it is applied.
Proven from the file rather than from a preview: a probe rendering `स्वास्थ्य` at 300 units produces the
content-stream operator `<212223242122252226> Tj` — **nine** glyph codes for nine codepoints, in logical
order, three of them the virama that shaping exists to consume. A conforming viewer draws nine separate
letters where a Nepali reader expects three clusters.

Two things follow, and the second is the reason this is written down here. Measuring it correctly would
not help, because the renderer would still draw it wrongly; the fix is a renderer that shapes, not a
better ruler. And **a rendered preview cannot be used to check this**: the rasterizer used to view that
probe reshaped the text from the PDF's `ToUnicode` map and displayed perfectly formed conjuncts, so the
page looked correct while the file was wrong. The content stream is the evidence; a picture of it is not.

**The print path has that renderer, so the defect is now the SVG path's alone.** The same `स्वास्थ्य`
through Typst draws **six** glyphs for those nine codepoints — the three viramas consumed, conjuncts
formed — and it wraps the many-to-one runs in `/Span <</ActualText …>>`, so extracting or copying the text
still yields what was written. Read from the content stream, on the same evidentiary standard as the
finding above. A Nepali form is therefore reachable; what stands between is coverage rather than shaping,
below.

**An entry marked *needs editing* is not a translation, and the generator will not treat one as though it
were.** gettext carries that state as `fuzzy`, it is what `msgmerge` sets on a near-match and what a
translator sets when flagging their own work, and a form drawn from those is indistinguishable from a
finished one — so the default is to ignore them and print the English source, which is legible and
obviously incomplete. `--include-drafts` turns that off for a review render, because nobody can approve
wording they have never seen on the page, and the run then says how many labels came from such entries.

**What this does *not* do is gate on review state, and the distinction matters because the weaker
guarantee is the tempting one to claim.** Weblate's states are *needs editing*, *translated* (displayed as
*waiting for review* where reviews are enabled) and *approved* — and only the first is `fuzzy`. A
translation a reviewer has not yet approved is in the second, which gettext has no way to express, so it
reaches the catalogue as an ordinary `msgstr` indistinguishable from an approved one. Whether it reaches
the file at all is a per-project commit policy rather than a property of the format.

So a build cannot tell reviewed wording from unreviewed by reading the catalogue, and no switch here can
make it. Doing that would mean asking the API for each unit's state — which is a network call in a build
that deliberately has none, and a different design from the one this file describes. State the guarantee
that holds: **fuzzy entries are skipped by default**; approval is not visible from here.

**A sheet's two kinds of text arrive by different routes, and only one of them is committed.** The labels
are the metadata's, translated in `po/metadata.<lang>.po`, which is in git — so a German sheet's labels
build from a clean checkout. The chrome is `common/figure-strings.yaml`, extracted into the documentation
catalogue and written back by po4a as a sibling YAML that is **build output and gitignored**. So the same
command draws German labels under English chrome on a fresh checkout and both in German where the pipeline
has run, with nothing in the output saying which happened.

That is why the chrome is gated separately rather than riding along with the labels: the protocol build
runs po4a and then generates a sheet per culture, so an overflowing translation of a form's own words
fails there, while the tests pin the chrome to a path they own and measure the labels. What that build
gate rests on is worth stating, because it lapses quietly rather than redly — po4a writes a culture's
protocol only above its `--keep` threshold, so a language falling below it stops being discovered, and
stops being checked, without anything failing.

**Whether a sheet is actually translated is checked against the finished PDF**, by
[`scripts/check-figure-language.py`](../scripts/check-figure-language.py), which extracts its text and
reports every Latin word the glossary does not account for. Reading the generator's own output would not
answer the question, and three weaker forms of the check were each wrong in a way that read as success:
asking whether a whole text run was Latin passed `CRP/इन्टरल्युकिन बढेको` as translated, since the run also
holds Devanagari; keeping the acceptable acronyms in a list inside the check made it pass by widening the
list rather than by translating anything; and admitting a one-character part of a glossary term put a bare
`I` in that list, which swallowed an ASA class numeral standing alone. What the check accepts is the
glossary, so changing the answer means making a terminology decision where terminology decisions live.
Digits are exempt: a numeral system is a separate choice from a script, and these forms carry clinical
thresholds that stay Western.

**Overflow is a build failure.** Today an over-long label runs outside its box and nobody learns until
someone opens the PDF, which for a localized build meant nobody ever did. Measurement is what lets the
generator assert the fit instead of hoping for it.

Two constraints on *which* font is measured, both of which make a wrong answer look right:

- **It must be a family the PDF theme registers, and the fallback list must never be reached.**
  `doc/NeoIPC.theme.yml` registers `Noto Sans` and `icon`, with `Noto Serif` as the document fallback.
  prawn-svg builds its registry from the Prawn document's registered families and merges externally
  scanned system fonts *behind* them, so a registered name always wins — and a name that is not
  registered is looked for in `/Library/Fonts`, `/usr/share/fonts/truetype` and two others, which is
  per-machine and matches nothing in CI.

  What happens at the end of that list is the part that has already cost this project a defect, and it
  has **two** endings rather than one. A **generic** keyword goes through
  `Prawn::SVG::Font::GENERIC_CSS_FONT_MAPPING`, which resolves `sans-serif` to **Helvetica** — an AFM core
  font with Windows-1252 encoding and no embedded glyphs at all, and the whole mechanism behind every
  non-Latin-1 character in an earlier figure rendering as the logical-NOT sign: not a corrupted file, a
  correct fallback to a font that cannot represent the text. A **named** family the renderer cannot
  resolve does not reach that mapping at all — it is drawn in the *document's* fallback face, so a figure
  asking for `Arial` comes out set in the protocol's serif. Measured from the content stream of a figure
  rendered both ways, because a rendered preview shows a letter under either outcome.

  Both are silent, and they fail in opposite directions — one produces unreadable glyphs, the other a
  perfectly readable letter in the wrong typeface. `font-family:"Noto Sans", Arial, Helvetica, sans-serif`
  is therefore a trap dressed as prudence: every entry after the first is a way to not find out.

  **Generated sheets name exactly one family, `Noto Sans`, with no fallback list.** A missing font must
  fail rather than degrade, because the degraded form is silent and is wrong precisely in the languages
  this exists to serve.
- **It must be the same file the output embeds.** Measuring some other Noto Sans agrees on the advance
  width of every glyph the two happen to share and is silently wrong about the ones they do not — which is
  exactly the non-Latin coverage this project has open questions about. The faces therefore live in
  `common/fonts/`, and each consumer has to be pointed at them; Noto is SIL OFL, which the licence
  guardrail requires.

  **The print path gets this by construction, and it needs one flag to do so.** `--font-path` *adds* to
  whatever the machine has installed rather than replacing it, so a face the document asks for and
  `common/fonts` does not ship is answered by some other file, chosen silently and differently per
  machine — the same failure as the Helvetica fallback above, reached from the other side. Measured:
  `typst fonts --font-path common/fonts` sees **198** families, and with `--ignore-system-fonts` it sees
  six — this repository's two, plus the four Typst has built in. So the compile passes
  `--ignore-system-fonts`, and the emitted `.typ` says why at the top of every file.

  **The SVG path gets it from the theme, and the order of one setting is what makes it hold.**
  `doc/NeoIPC.theme.yml` names `Noto Sans` by its file, and the protocol header puts `common/fonts` ahead
  of `GEM_FONTS_DIR` on `:pdf-fontsdir:` — the gem's directory stays on the list because the theme still
  names asciidoctor-pdf's own bundled faces for everything else. Reversed, the figure would be drawn with
  the gem's pre-subsetted `notosans-*-subset.ttf` instead of the file measured here, which is a different
  file with a `kern` table and no `GPOS`.

## What a generated document declares about itself

Every document this project generates carries four metadata fields, and they are worth very different
amounts. The rule that follows applies to the reports and the protocol as much as to these forms.

**The language must be right, and it is the one that can be actively false.** A localized PDF that
declares `/Lang (en)` tells a screen reader to pronounce Devanagari with English rules, and asserts a
PDF/UA property it does not have. Both outputs state their own language.

**The title does most of the real work.** It is what a search engine shows as the result, and what a
document system files the form under. It is translated and it names the form.

**The description is user-facing accessibility text**, reaching a reader twice — as the SVG's `<desc>`,
which a screen reader announces, and as the PDF's Subject. Every word of it is translated; assembled from
an English frame around translated names, it would be read out half in each language.

**The keywords are worth much less than they look, and a generous list can actively hurt.** Established
rather than assumed:

| consumer | uses the keyword field? |
|---|---|
| Google | No — ignored since 2009; a PDF ranks on its title and its text |
| Bing | No positive use; read as a **spam** signal, triggered by keywords **absent from the document** |
| Google Scholar | No — it reads `citation_*` tags on the landing page, not the file |
| document systems and repositories (desktop search, SharePoint, DSpace, Zotero) | **Yes** — `/Keywords` and XMP `dc:subject` |

Only the last is a real consumer, and it is narrow: anything genuinely on the page is already found by
full-text search. So the field is kept **small, and every term in it appears on the page** — the form's
own name and the module it belongs to. A resonant list of terms the document does not contain is the one
construction that is worse than saying nothing, and it also costs translator time in every language for
no gain. The reports reach the same shape from the other direction, with three terms apiece.

**Where discoverability actually comes from**, in order: the document's text being real text rather than a
raster; the title; and the page that links to the file. None of it is in the keyword field.

## The route out: render the form once, properly, and import the page

The renderer limits above look like they bound what the forms can ever be. They do not, and the reason is
that **asciidoctor-pdf can import a PDF page** — `image::form.pdf[]`, backed by `prawn-templates`, which is
already one of its runtime dependencies. That inverts the dependency: instead of handing asciidoctor-pdf an
SVG it must draw, hand it a page that has already been drawn by an engine that can.

**The import preserves real text, and this was established rather than assumed.** Importing a generated
sheet into a host document and comparing content streams: the page arrives as a `/Subtype /Form` XObject,
the source's embedded TrueType fonts come with it, and **all 30 of the form's glyph-showing operators
appear byte-verbatim in the host** — `4d6173746572204461746120436f6c6c656374696f6e205368656574` is
*Master Data Collection Sheet*, unchanged. Nothing is rasterized and nothing is re-laid-out.

So whatever shaping and bidirectional reordering the producing engine performed is **baked into the glyph
stream before asciidoctor-pdf ever sees it**, and asciidoctor-pdf's inability to shape stops mattering for
the forms. One artifact then serves both consumers: the standalone sheet a partner prints and fills in at a
cot side, and the figure inside the protocol. They cannot drift, because they are the same file.

That also changes what the SVG is for. It stays the source the layout engine emits and the thing a browser
can show, but it is no longer what the published PDF is built from — which removes prawn-svg from the
forms' path entirely, along with its silently-ignored filters and its unshaped text.

**Four caveats, all found in the source or the documentation rather than discovered later:**

- **Importing disables compression for the whole document.** `import_page` sets `state.compress = false`
  with the comment *"can't use compression if using template"*. On a protocol that is already several
  megabytes this is not a rounding error, and it interacts directly with the separate work on PDF size.
- **Running content is skipped on imported pages.** The converter explicitly refuses to draw on them —
  *"don't write on pages which are imported / inserts (otherwise we can get a corrupt PDF)"* — so an
  imported form carries no page number, header or footer from the protocol.
- **The import must be a direct descendant of the document or a section.** Nested in a delimited block or
  a table cell, the documented behaviour is *"unspecified"*.
- **Tags do not necessarily survive the embedding.** The glyph stream does; a structure tree is a
  document-level object and there is no reason to expect one to merge. This is currently moot — the
  protocol's PDF is untagged either way, because asciidoctor-pdf has no tagged-PDF support — so the
  accessible artifact is the **standalone** form. Do not claim otherwise for the protocol without checking.

## Which engine draws it — and why the answer is not an SVG converter

The import route above says *how* a properly-drawn page reaches the protocol. This is *what should draw
it*, established by surveying twelve permissively-licensed engines against shaping, bidirectional text,
tagged PDF, PDF/A, metadata, determinism, platform and licence, with each load-bearing claim then
challenged by an independent reviewer that was given the claim and not the reasoning.

**SVG as the input to a PDF engine is dead, and not for the reason it first appears.** Every engine that
can emit a structure tree collapses an SVG into exactly one node: WeasyPrint maps both `img` and `{svg}svg`
to `Figure` and scrapes `/Alt` only from `<title>`; Typst's own accessibility guide says "Neither PNGs nor
SVGs are accessible on their own"; Apache FOP states it outright. **The correction matters more than the
finding**: FOP does *not* rasterize the text — its `NativeTextPainter` writes real PDF text operators, as
do WeasyPrint, Typst and krilla-svg. So the failure mode is **real, selectable, untagged text**. It looks
right, it copies and pastes, and it is inaccessible — which means neither a visual check nor a copy-paste
check can detect it, and "the text survived" is not evidence of anything.

**One SVG defect disqualifies that path for right-to-left regardless of tagging:** `usvg` hard-codes the
bidirectional paragraph base level to left-to-right — `BidiInfo::new(text, Some(Level::ltr()))` — so a
Hebrew or Arabic string resolves against an LTR base and its trailing neutrals and punctuation land in the
wrong place. Anything routed through usvg inherits it, which includes `resvg`, `krilla-svg`, and Typst's
own `image()` of an SVG.

**The engine is Typst** (Apache-2.0), with the generator gaining a second emitter that writes native
`.typ` using absolute placement. It wins on precisely the axes this project has already declared
first-class, and one of them is uncanny: **Typst fails the export rather than emitting a document that
falsely claims a conformance** — the same rule as the guardrail here. Beyond that: tagged PDF on by
default with an explicit opt-out, PDF/UA-1 and the accessible PDF/A `a`-levels, a real Unicode
Bidirectional Algorithm with a *configurable* paragraph base level, HarfBuzz-derived shaping, native
`SOURCE_DATE_EPOCH`, a content-hash document ID with no clock in any branch, and one statically linked
binary on all three platforms — no host Pango to drift between a developer's Windows machine and CI.

The fallback is **krilla** driven from a small Rust shim, chosen deliberately because Typst *is* krilla
plus a layout engine: falling back costs only the layout, shaping and bidi layer and preserves every
PDF-side property, so the conformance story would not need re-establishing.

Why not the others, in one line each: **WeasyPrint** — bidi unsupported by its own documentation, and an
open report of a corrupted `ToUnicode` map and empty `TJ` for Arabic, which breaks extraction and with it
PDF/A-2u and PDF/UA. **Apache FOP** — Devanagari only partial, ZWJ and ZWNJ unsupported, and a trailer
`/ID` wired to the wall clock with no injection point, so byte-identical regeneration is impossible.
**Batik, resvg, librsvg** — no structure tree at all. **PDFBox** — an assembly layer, not an engine.
**Ghostscript** — AGPL, excluded on licence. **LuaLaTeX** — genuinely viable and the only route to
PDF/UA-2, but babel's `bidi=basic` is explicitly not a full Bidirectional Algorithm, and `tagpdf`
self-describes as unstable and wants a moving format, which sits badly beside a reproducibility guarantee.

**Two risks to carry rather than forget.** `rustybuzz` is archived and frozen at HarfBuzz 10.1.0 semantics
while `resvg` has already moved to `harfrust` — a maintenance risk, not a present defect. And Typst issue
**#8667**, a compiler panic when a right-to-left paragraph ends in a combining mark, is the one that could
actually bite this layout; smoke-test it before committing.

### Typst cannot own both outputs, so there are two renderings and one content model

The tempting simplification — let Typst emit the SVG too, with `--format svg`, and have one layout engine
for everything — does not work. **Typst converts all text to paths in SVG export**, deliberately, so that
a file looks identical everywhere; making it emit real text is an open request upstream. Paths are
unselectable, unsearchable and invisible to a screen reader, which is exactly what the protocol's inline
figure must not be, and what the `<title>`/`<desc>` work here exists to avoid.

So the shape is settled: **SVG from this generator's own layout for the screen, PDF from Typst for print**,
with the PDF also serving the protocol through page import. Two renderings, one content model.

What they must agree on is **fields, order, wording, options and mandatory flags** — everything derived
from the metadata. What they need not agree on is sub-millimetre typography: Typst applies `GPOS` kerning
that this generator's advance sum does not, so the two will differ slightly, and on a screen figure against
a printed form nobody can see it and nothing depends on it. Insisting otherwise would mean reimplementing
Typst's shaping in Python to chase a difference no reader can perceive.

**The one-page rule stays with the generator, because the engine cannot answer it.** Counting the compiled
document's pages looks like the natural gate and is vacuous: every element is `place`d, which is out of
flow, so content running past the bottom edge is drawn outside the page and clipped rather than starting a
second one. Established rather than assumed — a document placing a line at 400 mm exports to a single PNG
without complaint, while one containing a real `pagebreak` refuses (*"cannot export multiple images
without a page number template"*), so the oracle works and the answer really is one page. Measurement
remains the gate for both outputs; the page count is worth asserting anyway, as a check that everything
was placed at all.

### Measurement shapes, because summing advances is not a measurement of what gets drawn

Summing `hmtx` advances is exact for prawn-svg **because prawn-svg does not shape**. Typst shapes, and
the sum then disagrees by an amount and in a direction that depend on the script:

| run | sum of advances | Typst | ratio |
|---|---|---|---|
| `Patient ID`, regular and bold | 13.97 / 15.05 mm | identical | 1.000 |
| `AVATAR Two Yaws`, bold | 27.36 mm | 26.49 mm | 0.968 |
| a 175-character English line, italic | 184.637 mm | 184.685 mm | 1.0003 |
| `स्वास्थ्य सेवा`, Devanagari | 15.41 mm | 12.87 mm | 0.835 |
| a Devanagari label on the master sheet | 12.34 pt | 13.84 pt | **1.12** |

For Latin the gap is feature application — kerning and ligatures, hundredths of a percent, either way.
For Devanagari the sum is **not a measurement at all**: a combining mark carries almost no advance of its
own while the cluster it joins has real width, and a conjunct replaces several glyphs with one. Those
pull opposite ways, so one string came out a sixth narrower than the sum and another an eighth wider, and
no tolerance covers both.

### The ruler must be told the language, not just the script

A shaper takes a script *and* a language, and a font may key a feature on the language alone. Noto Sans
Devanagari does. The same string, the same face, the same size:

| declared language | drawn width |
|---|---|
| `en` | 52.92 pt |
| `hi` | 52.92 pt |
| `ne` | **56.67 pt** |

Hindi and Nepali are the same script and differ by 7 %, so this is a language system in the font rather
than anything about Devanagari. HarfBuzz's `guess_segment_properties` reads the **script** and cannot know
which language is being set in it, so a measurement that relies on the guess disagrees with the engine
exactly where such a feature applies — and only in the languages that have one, which is the worst place
for a disagreement to hide.

So the document's language reaches both sides: the emitted `.typ` declares it, and the shaping buffer is
given it after the guess has filled in script and direction. **The emitted assertion is what caught this**
— a Nepali label came out 7 % wider than the layout had allowed — which is the case for asserting every
run rather than sampling.

**So the generator shapes too, with the same engine.** `Typeface.width` splits a string into runs by the
face each character resolves to — which is what a renderer does, so kerning across a face boundary is
applied by nobody — and asks HarfBuzz, through `uharfbuzz`, for each run. Typst shapes through
`rustybuzz`, a Rust port of the same library, against the same file. Apache-2.0, so the licence guardrail
is satisfied.

The two now agree **exactly**. Measured across every run of every sheet in English and Nepali, and
separately for Hebrew including a mixed `MRSA זוהה בדם` that spans both faces: 15.5280 mm against 15.528,
20.6490 against 20.649. The emitted document still asserts it — every placed run carries its measured
width and checks against `measure()` — but the tolerance is now one grid unit for float rounding rather
than a proportional term, which makes the check about fifty times stricter than the unshaped path could
support. That assertion is what falsified "shaping only ever narrows" in the first place; it costs
nothing worth counting, at 400 asserted runs in 0.19 s.

### What the emitted `.typ` contains

One `#place` per element, at the coordinates the layout already chose, so nothing reflows and the two
outputs cannot disagree about what is on a sheet or where. Four things in it are decisions rather than
mechanics:

- **Runs are positioned by their baseline**, which is what every measurement here is relative to.
  `#set text(top-edge: "baseline", bottom-edge: "baseline")` gives a text box no height at all, so
  `place(dy: …)` puts the baseline exactly where the layout put it — verified by `measure()` returning
  zero height for every style on the sheet.
- **Text goes in as a string, not as markup**, so a label containing `#`, `*`, `_`, `@` or a leading `-`
  is a label rather than a directive, an emphasis or a list item. Two characters to escape instead of a
  dozen.
- **Coordinates stay the integers the SVG carries**, through `#let u = 0.01mm`. `#at(1180, 3367, …)` is
  the same number as `x="1180"`, so the one-grid rule survives into the second output instead of being an
  SVG-only property.
- **The document date is `auto`, and the compile pins it** — `SOURCE_DATE_EPOCH`, or
  `--creation-timestamp`. PDF/A requires a date, and taking it from the wall clock would make two compiles
  of one source differ. Verified byte-identical at a fixed epoch.

`--pdf-standard a-2a,ua-1` is what the sheets export under, and it is checked rather than asserted: the
first attempt **failed the export**, because the logo carried no alternative text. That refusal is the
property that made Typst the choice.

The test suite compiles every emitted form under those flags and reads the conformance **out of the
finished file** rather than trusting that the flag was accepted — a plain compile declares neither
`pdfaid` nor `pdfuaid`, so the two cases are distinguishable and the check is worth running. The page
count comes from Typst's own refusal to export several images without a page-number template. And because
a gate that stops running reads exactly like one that passes, a missing engine **fails** on a runner and
only skips on a developer's machine.

**The protocol build compiles them, and they ship with the protocol.** Each culture's forms are written to
`artifacts/<culture>/forms`, bundled one archive per culture, and attached to a protocol release. Three
decisions are behind that shape, and each rules out something that looks reasonable:

- **They are a deliverable of the protocol product, not an input to the document.** So they go to
  `artifacts/`, never to the image directory the document reads — a printable standalone form sitting among
  the figures asciidoctor embeds is the category error the SVG/PDF split exists to prevent.
- **The culture set is the protocol's own**, which is a decision rather than a convenience. A form could be
  built for more languages than that: its labels come from the metadata catalogue and do not depend on the
  protocol's translation level at all. Publishing one for a language the protocol is not published in
  would ship a document labelled with a language it is largely not written in — the misdeclaration the
  `--keep` threshold exists to prevent, reached by a different route.
- **One archive per culture, because a release's assets share a flat namespace.** Every culture's forms
  carry the same file names, so attaching them individually would have each culture silently overwrite the
  last.

The pre-release stamp follows the protocol's, for a reason particular to forms: a sheet is detached from
the document the moment somebody prints it, so the document's own watermark cannot speak for it, and
whoever is holding one at a cot side has no other way to know its definitions are provisional.

The logo is a wordmark, so its accessible name is the word it draws, read from the artwork's own
`<title>` rather than written here. Marking it a `pdf.artifact` would have satisfied the same gate while
asserting it carries nothing — and that assertion is irreversible: *"once something is marked as an
artifact, you cannot make any of its contents accessible again"*.

### A sheet is bilingual whenever its language is not Latin-scripted

Not by accident, and not fixable by translating harder: the resistance categories are established
abbreviations that are deliberately not translated, so MRSA, VRE, 3GCR and CRP are on every sheet in every
language, as is the project's own name. Noto splits by script, so Noto Sans Devanagari carries **no Latin
letters at all** — a Nepali sheet drawn from it alone is every Latin character missing, which is exactly
what the coverage check reported.

So a language gets a **stack** of faces rather than one: each character is measured in the first shipped
face that holds it, both families are named in the SVG's `font-family` and in Typst's `font:` list, and
the coverage check passes when their union covers the text. Both faces are already in `common/fonts/` and
both are SIL OFL. This is the opposite of the silent fallback the rules above bar — it is this
repository's own files, in a stated order, named in the output so each renderer resolves the same two.

**Two of the three consumers honour that stack. prawn-svg does not, and it is the one the protocol's PDF
goes through.** It resolves the family list to exactly **one** font and draws every character from it,
with no per-character fallback — so on a bilingual page one of the two scripts is always tofu, and which
one depends only on the order.

Established both ways, because neither half alone would have settled it. **What happens**: the same
figure rendered twice with nothing changed but that order — with `Noto Sans` first the Devanagari drew as
empty boxes; with `Noto Sans Devanagari` first the Devanagari drew correctly and every Latin letter
became an empty box, while the digits, `<`, `>` and `?` survived both, being among the 60 codepoints the
two faces share. An explanation that was wrong could not have produced that second half. **Why**:
`FontRegistry#load` is `FontFamilyParser.parse(family).detect { … break font if font.installed? }`, so it
returns the *first installed* family and stops, and `TextComponent#apply_font` then issues one `font`
call for the whole run. The list is a preference about **availability**, which is not what it means in a
browser. `fallback_font_name` is a single document-level last resort appended to that list rather than a
chain, and Prawn's own per-character `fallback_fonts` is never reached.

The consequence is not small, because **every non-Latin sheet is bilingual by construction** — the
resistance abbreviations and the project's own name are never translated. So a Nepali or Hebrew figure
cannot render correctly through this path at all, whichever order it names. What is affected is exactly
the protocol's **inlined SVG figures**: the browser applies per-character fallback and so does Typst, so
the published HTML and the printed forms are unaffected.

That makes the page-import route below load-bearing rather than an improvement: handing asciidoctor-pdf a
page Typst has already drawn is what removes prawn-svg from the figures' path, and with it this limit.
Until then, **say what holds**: the protocol PDF renders its figures correctly in Latin-script languages,
and a language needing a second face needs that route first.

**Three routes reach a correct non-Latin figure, and they trade different things.** All three draw from
the same Typst compile, so none of them is a second layout:

| route | what it gives | what it costs |
|---|---|---|
| **PDF page import** — `image::form.pdf[]` | real text, shaped and bidi-resolved, byte-verbatim through the embedding | no page number or running content on the imported page; compression off for the whole document |
| **Typst SVG** — `--format svg` | correct glyphs, correct shaping, scales | **all text becomes paths**: unselectable, unsearchable, nothing for a screen reader but `<title>`/`<desc>` |
| **Typst PNG** — `--format png` | works anywhere | raster: loses the text layer *and* resolution independence |

So the order of preference is the order of that table, and the second row is a real fallback rather than
a bad one: against a figure whose script renders as tofu, paths that are correct are worth more than text
that is wrong, and the accessible name survives in `<title>` either way. It is the *published protocol's*
own accessibility goal that decides between them — which is why the first row is the target and the
second is what to reach for if the import route proves impractical.

### Direction is not the layout's concern

A right-to-left language is served by **mirroring the finished page**, not by a second set of positioning
rules. Everything above measures and places in one direction; a single pass over the placements then
reflects the page about its vertical centre, and labels move to the right, the answer column to the left,
and every mark to the far side of the word it belongs to. A run's `x` is an anchor rather than an edge, so
it needs no width subtracted — the mirrored anchor is simply the run's other end, and both serializers
anchor text to the right on a mirrored page. Section titles are centred and so are unmoved.

Doing it there is the whole reason it is small: there is no second positioning path to keep in step, and
no emitter that can be right for one direction and quietly wrong for the other.

**Mirroring is not reordering.** Which glyph precedes which within a run is the Unicode Bidirectional
Algorithm's job and belongs to whatever draws the text. Typst applies it against the base direction the
emitted document declares, and a browser applies it to the SVG; `prawn-svg` applies none, so an inlined
figure in a right-to-left language is the one consumer that would still be wrong — the same limit already
recorded for shaping, reached by the same route.

Verified by mirroring a language whose catalogue exists rather than by argument: the resulting page is
correct in every position, and the trailing full stops migrate to the left of each sentence, which is
correct resolution of neutral characters against a right-to-left base and is exactly what would happen to
the Latin abbreviations inside a Hebrew sheet.

**What is still missing before a Hebrew sheet exists** is not the layout: it is a face — Noto Sans does
not carry Hebrew, so `common/fonts/` needs Noto Sans Hebrew and `SCRIPT_FONTS` a line — and a `he`
catalogue to translate into.

Two details in the font stack are decisions, and both were wrong on the first attempt:

- **Latin comes first, in every language.** The obvious order is the language's own script first, and it
  is wrong here because the two faces **overlap on 60 codepoints** — every digit and every punctuation
  mark. With Devanagari in front, a Nepali sheet would draw its digits, brackets and slashes from one
  design and the Latin letters beside them from another, on the same line.
- **Vertical clearance is per row, not per sheet.** Noto Sans reaches 293 thousandths of the em below the
  baseline; Noto Sans Devanagari reaches 408, which the script needs for its below-base marks. Charging
  every row the deeper figure costs 0.68 mm a row, which over a sheet of fifty is 17 mm — enough on its
  own to push the surgical-site sheet off its page, which it did. Charging every row the shallower one
  puts a Devanagari mark through the rule closing it. So each row is padded for the text it holds, and a
  sheet in a language nobody has translated yet lays out **byte-identically to the English one**, because
  it is drawing exactly the same faces.

## The layout follows the published forms; the visual style follows the two hand-drawn SVGs

These are two separate references and they are not interchangeable. **Arrangement** comes from the forms
already published for partners — one A4 page each, made in Word — because those are what people have been
filling in. **Visual language** comes from the repository's own SVGs. Neither is a starting point to
improvise from.

What the published forms actually do, read off them rather than assumed:

- **One full-width ruled table, not two columns.** A field is a row: the label in bold, ending in a colon,
  and the rest of the row is the space to write in. A separate input column, which a naive generator
  reaches for first, wastes most of the page and is why an early attempt ran three pages.
- **Sections are centred bands** in light blue across the full width.
- **Options are indented rows** under their field, marked `○` for choose-one and `□` for choose-any —
  with a legend at the foot of every sheet stating exactly that. The marker is therefore derivable:
  `renderOptionsAsRadio` decides it.
- **Short option sets run horizontally.** "No / CVC-associated / PVC-associated" sits on one line; a set
  whose text is long breaks to one option per line. This is the single biggest contributor to fitting the
  page, and it is a measurement decision, which is why measuring is what makes the one-page rule
  attainable rather than a constraint to negotiate with.
- **A repeated slot is a compact block, not a run of labelled fields.** An organism slot is a write-in
  line with its source options inline — `Organism 1: ______ , recovered from □ Blood □ CSF` — followed by
  its resistance rows, each a three-option inline run. Three slots occupy about twelve lines. The same
  fields given one labelled row each occupy the better part of two pages, which is exactly what the first
  emitter did.
- **Hints sit inline**, in italic parentheses inside the option or in a second column against the field
  (`(weeks + days, e.g. 25+4)`, `grams`).
- **Footnotes at the foot**, with superscript markers, plus a line pointing at the protocol's Data
  Dictionary and Abbreviations sections.
- Every sheet opens with a **Patient** band carrying the local patient ID and name — the identifiers the
  protocol forbids submitting, present precisely because the paper stays in the hospital.

### What is editorial, and why a mapping is unavoidable

**The value type does not determine how a field is asked, and the published forms prove it by inverting
what either type suggests.** `NEOIPC_BSI_AB_TREATMENT` is `TRUE_ONLY` and is printed as a pair of
choose-one circles, Yes and No. The nine `BOOLEAN` signs-and-symptoms elements beside it are each printed
as a single choose-any square, with no negative answer at all. A generator inferring the marker from
`valueType` would confidently get both backwards, so the decision is read from `common/sheet-layout.yaml`
rather than derived. That file holds presentation only — it may not name a field the metadata does not
define, add one, or change a label.

The other editorial act is **grouping**: the published BSI sheet collapses MRSA, VRE and 3GCR into one row
under a footnote, "mark the resistance profile appropriate to the isolated microorganism", where the
metadata has an element each. A collapsed row without that footnote is a form that quietly loses a
distinction the model draws, so the mapping carries the footnote with the group.

**That row's label is a pattern, and the three terms in it come from the glossary.** Each is controlled
terminology the glossary already carries, so writing `MRSA/VRE/3GCR` into the figure text would be a
fourth home for words that have one, and would let a form drift from the wording every other document is
held to. What the figure text holds instead is `{mrsa}/{vre}/{gcr3}` — the placeholders resolved from the
glossary, the rest the translator's.

**A pattern rather than a separator the emitter joins with**, and the difference is not stylistic.
Joining presumes the shape: *n* items, one delimiter, repeated, in a fixed order. That is a Latin list
convention rather than a property of writing, and it forecloses a conjunction before the last item, an
enumeration comma, a different order, or a rendering that is not a list at all — none of which an emitter
can be asked to decide for nine languages. The same reasoning already applies to the colon after a label,
which is why one is not appended in code either. The cost is one check: every declared placeholder must
appear and no undeclared one may, and the build fails otherwise, because a label that quietly lost a
placeholder would stop offering a resistance category the model still keeps.

The placeholder names are the layout's, not the glossary's, for one mechanical reason: `{3gcr}` leads
with a digit, which every brace-format checker in this pipeline rejects. `common/sheet-layout.yaml` maps
`gcr3` to the glossary's `3gcr`, so the exposed name stays a valid identifier.

**Slot counts are the same kind of decision, and one of them is currently wrong in public.** Checked
rather than assumed: BSI, HAP and SSI each carry exactly three organism slots in the metadata and the
published sheets print three, so nothing is truncated there. But the metadata carries **nine** antibiotic
substance slots and the published master sheet offers **six**. The form has been behind the data model, on
the website, with nothing to say so — which is the argument for generating, and the reason the printed
count is recorded as a decision instead of left to whoever last edited a Word file.

**Both now print nine**, and the chart is what forced the question rather than leaving it open. The
published chart also offers six, so a generated chart that kept six would have sat in the same package as
a generated master sheet offering nine — reintroducing, between two forms a partner fills in together, the
exact model-versus-paper drift that generating them was meant to remove. `slots:` in
`common/sheet-layout.yaml` is therefore empty, which means *print what the metadata carries*; an entry
there is how a printed count would be deliberately held below it.

## The decision flow needs this before the sheets do

The same wrapper wraps the protocol's decision-flow figure, and there the margin is already gone. Its
XSLT wraps against `maxLen` constants of **38** and **16** characters, and the German translation's
longest word is **`Gestationsalter`, at 15**. One character of headroom, in a language that builds
compounds — and because the recursion cannot break inside a word, a token that exceeds the constant is
emitted whole and runs out of its box with nothing reporting it.

So the figure is not comfortably within its limits; it is one wording change, one longer compound, or one
new language away from being wrong, and the failure would appear only in a rendered PDF for a language
that until this week nobody was building. Spanish's longest is 11 and English's 11, which is why the
constants have never been felt: they were tuned by eye against the two languages that fit.

**Breaking inside a word is the answer to the compound, and the break points come from the translator, not
from a dictionary.** Breaking on whitespace cannot help a single long word. A Hunspell hyphenation
dictionary per language was the obvious route and was rejected: it is nine assets to ship, each with a
licence to clear — several are not permissive, and the rule against non-permissive dependencies is not
limited to fonts — and each one only *guesses* where a compound may divide, which for coined clinical
compounds is exactly where a pattern file is weakest.

A **soft hyphen** (U+00AD) in the source string is used instead. It costs no dependency, no per-language
asset and no licence, and it puts the decision with the person who actually knows: where
`Gestations{shy}alter` may divide is a fact about German, not about this layout. The renderer never sees
one — `Face.wrap` strips every soft hyphen and writes a real hyphen only where a break is actually taken,
which is possible because the generator emits explicit lines rather than asking the renderer to wrap. So
whether prawn-svg honours U+00AD never arises, and a string that does not need to break carries no visible
mark.

Two properties it must keep. A break point **relaxes** the fit rule and does not remove it: a fragment
that still will not fit fails the build exactly as an unbreakable token does. And it is opt-in per string
rather than applied by a rule, so a clinical term that would be misread when divided simply carries no
soft hyphen — no mapping entry, no exception list, and nothing to keep in step with the text.

**Its mirror is the non-breaking space, and the wrapper honours it by construction.** `Face.wrap` splits
on the ASCII space alone, so U+00A0 is simply not a place a break can be taken — one mechanism says a
word *may* divide here and the other says these two *may not*, and neither is the layout's decision to
make. A threshold is where it earns its keep: `< 32 weeks` and `< 1500 g` are single terms, and a line
ending on `Birthweight <` reads as a truncated sentence rather than as a comparison. The rule against
non-breaking spaces in string resources is a rule against making a *layout* decision inside translatable
text, and it admits a documented exception for exactly this; the documentation is in
`common/figure-strings.yaml`, beside the strings that carry them.

Its eight strings live in `common/figure-strings.yaml` accordingly: they are whole sentences, so nothing
about them needs splitting by a translator, and the wrapping was never theirs to think about.

### A drawn figure gets a template, not a layout engine

**What decides the tool is where the information lives.** A sheet is *derived* — its fields, their order,
their options and their mandatory flags come from the metadata, so nobody can place them in advance and a
layout engine is unavoidable. The decision flow, the title page and the watermark are *drawn*: their
boxes, arrows and proportions are a design somebody settled, and generating them per build would re-derive
by code what a person had already decided — badly, and at the cost of arrow routing nobody asked for.

So each keeps a **hand-maintained SVG skeleton**, and the build does one thing to it: resolve each text
node's string for the culture, wrap it by measurement, and write explicit `<tspan>`s. That is the whole
of the localization path, and it reuses the sheets' own `Typeface` — the same faces, the same shaper, the
same soft-hyphen handling that lets a German compound divide where a translator said it may.

**The skeleton is generated once and then checked in as source.** Producing it by hand is what left the
figure it replaces with three question boxes on two different widths, `rx` set where the renderer does not
read it, and a label at 1.85:1. Generating it once places every box from the same rules and applies the
derived palette exactly, and the output is then a plain house-style SVG — semantic ids, classes, integer
coordinates, no editor namespace — that a maintainer edits directly. The one-off code that emitted it is
not kept: the SVG is the source afterwards, and the palette stays reproducible because its derivation is
recorded above rather than living in a script.

The skeletons live in `doc/protocol/figures/`, which is source, while `doc/protocol/img/` is where the
build writes. That separation is what the `.resx` and XSLT pair failed to make: a template and its
rendering sat in the same tree under names that differed by a suffix.

**Three rules make the template hold its own geometry**, and they are stated in the file so that editing
it does not require reading this one:

- **A labelled node is a `<g>` whose first child is its region** — a `rect`, a `circle` or an `ellipse`.
  The label is fitted to that region, so moving or resizing the shape moves the text with it. The
  alternative, an `x`/`y`/width on the text node, states the same geometry twice and lets a hand edit
  change a box without changing what is measured against it. An oval's region is the largest rectangle
  inside it — half-axes over root two, which is exact rather than a fudge factor.
- **A `<use>` in the group is a mark**, and it reserves the top of the region; the label takes what is
  left underneath. That is what lets a terminal carry both a tick and a word without a second mechanism.
- **A `<text>`'s content is a pattern of `{key}` placeholders**, resolved against
  `common/figure-strings.yaml` — the same mechanism as the resistance label on the sheets, and for the
  same reason: it needs no naming convention, it survives a key appearing three times on one page, and
  the template carries no second copy of the English.

A box holds three lines in a question where German needs two, seven in the note where Spanish needs five,
and one in a branch label, which must never wrap. Those figures are what the geometry was chosen against;
they are not a budget to spend down, because the languages that will need them have not been written yet.

**A box cannot grow at render time, so it is authored for the worst language.** This is the real
constraint the template accepts in exchange for its simplicity, and it is the stricter half of the
bargain: measurement decides whether the text fits, and text that does not fit **fails the build** rather
than silently overrunning. Sizing generously once is cheap; the figure is A4 landscape and mostly air.

Three figures are drawn this way — the decision flow, the title page and the preview watermark — and
retiring them took the seven XSLT files and the twelve `.NET` resource files with them, including the two
transforms that wrapped text by counting characters, which is what none of the above could be built on.

## Palette: two brand colours, everything else derived from them

A generated sheet uses no third hue. Recorded here so that "on brand" is checkable rather than asserted:

| value | what it is |
|---|---|
| `#0083c1` | the brand blue, as carried by `common/img/NeoIPC-Logo.svg`. Headings. |
| `#ff9015` | the brand orange, from the same artwork. |
| `#cfe7f4` | derived: a tint of the brand blue, light enough to carry black text over it. Section bands. |
| `#ffe4c4` | derived: a tint of the brand orange. The fields that never leave the hospital. |
| black, greys | neutrals — rules, text and the solid edge bar. |

Both brand values are the logo artwork's own, normalised: the converted vector carried `#0083c2` and
`#ff9016`, a rounding artifact of the colour conversion.

Two things this rules out, both of which had crept in. An **earlier accent of `#2e74b5`** was a
word-processor default that merely resembled the brand blue and was never sampled from anything. And the
hand-drawn master sheet shades its patient block in **`#E0D3DE`**, a mauve that belongs to no NeoIPC
artwork — generated sheets use a tint of the brand orange for that job, so the page carries two hues and
the difference reads as deliberate.

The tints are derived rather than given, which is the honest description. Deriving them from a brand
colour keeps the decision inside the palette instead of importing a hue from outside it.

### The decision flow carries meaning in colour, so its hues are derived rather than borrowed

A form's colours are decoration; the decision flow's are not — green means *eligible* and red means
*ineligible*, and no other element on the page says so. That rules out both easy answers: the semantic
pair cannot be dropped for the brand palette, and it cannot stay at whatever a word processor offered.

So they are **placed at the brand blue's own perceptual coordinates and rotated in hue**. `#0083c1` is
OKLCh(L 0.582, C 0.133, H 240°); green and red take that lightness and chroma at H 145° and H 29°, and
each stroke is the same hue and chroma at 72 % of the lightness. The result reads as one family because
the three fills are *equally light and equally saturated* — which is what "visually aligned" has to mean
if it is to be checkable — while staying unmistakably green and red.

| role | fill | stroke | ink | contrast |
|---|---|---|---|---|
| question box | `#0083c1` | `#00528d` | white | 4.19 |
| eligible | `#408f46` | `#005e14` | white | 4.01 |
| ineligible | `#bd584b` | `#86261d` | white | 4.51 |
| note box | `#ffe4c4` | `#ff9015` | black | 17.15 |
| *no* connector | black | black | white | 21.00 |
| *yes* connector | white | black | black | 21.00 |

**Every pairing clears WCAG AA for large text, and that is the point rather than a bonus.** The figure
this replaces set white on `#92D050` at **1.85:1** — below even the lenient large-text threshold of 3.0,
in a published protocol — so the label a reader most needs was the one they could not read. Contrast is
therefore a property of the palette here, checked when a colour changes, not an audit performed later.

**Colour is never the only signal.** These sheets are printed, routinely in greyscale, where every tint
collapses to a shade and the distinction between a section band and the non-transmitted block disappears.
So that block also carries a solid edge bar, which survives greyscale, photocopying and colour-blindness.
A distinction a form makes only in hue is a distinction it does not make.

## The alignment grid

Everything used to position itself relative to whatever preceded it on its own row, which made the sheet
read as untidy in four separate-looking ways that were all one defect. The fix is one column, and it
resolves all four.

**The answer column.** One x per sheet where every answer that shares its label's line begins — a space to
write in, a Yes/No pair, an organism's resistance run. Before it, an organism slot's three resistance rows
stepped visibly rightwards because each began wherever its own label ended.

**Its position is searched, not chosen.** Two pressures pull against each other: move the column right and
long labels stop wrapping, move it left and more choice runs fit on their label's line. Which wins depends
on the text, so it depends on the language — a constant tuned against English would be wrong for the other
eight. Since the layout is a pure function of the text, `best_layout` lays each sheet out at every
candidate position and keeps the one leaving the most room, where "most room" is the comments box that
absorbs the leftover. Maximizing it is the same as minimizing the sheet, so the search optimizes exactly
the property the sheets are judged on. In English it settles between 50 and 67.5 mm across the six sheets.

**Not every row has a cell.** A criterion carrying its tick at the left, and a question whose choices are
listed beneath it, both span the sheet. They are not forced into the column: option text runs to 11 155
units — full clinical sentences such as the SSI infection-type definitions — so confining an option block
to the answer side would wrap it into a narrow ribbon and cost far more height than the alignment is
worth. Those rows keep the full width, and the column's stroke is simply absent beside them, which is what
a ruled form does with a full-width row.

**The column is what separates a label from the space to write in.** The published forms use a colon,
which is not safe to append in code — French requires a space before it and other languages punctuate
differently, so a colon belongs to the translated string or to a per-language rule, never to the emitter.
A rule needs no such knowledge. It is drawn per row rather than as one line down the page, because the
spanning rows have no cell for it to bound; consecutive bounded rows abut exactly, so it reads as one
column wherever there actually is one.

**The rule closing a row is the line written on**, which is what the published forms do. A separate
writing rule at the text baseline sat about half a millimetre above it and read as a printing fault. Only
a row whose closing rule is elsewhere — a slot header with children under it — draws a line of its own,
and a paired row (an antibiotic substance and its days) divides its two cells with a vertical stroke of
the same weight as the column rather than with a second horizontal one.

**The same grid should govern every generated figure**, not only the sheets: the decision flow's boxes,
the progress chart's columns and the sheets' rows are the same design object seen three ways, and each one
drifting on its own is how the inconsistency arose in the first place.

The chart is where that stopped being an aspiration. It shares `_open_page` and `_close_page` with the
sheets **literally** — the same logo placement, the same two type sizes, the same patient block, the same
comments box absorbing the leftover, the same one-page rule and the same measured footer — so what differs
between a sheet and the chart is only the body between them. A chart that merely *resembled* the sheets
would have drifted from them the first time either was touched, and the family reads as one set of forms
only for as long as its edges are the same decision rather than two decisions that currently agree.

**Its one column is measured like the sheets' answer column, and it is the only form here that can fail on
WIDTH.** A sheet runs out of page at the bottom; the chart's row labels and its thirty-two columns compete
for one line, so a language whose labels are longer takes the space out of the cells somebody writes in.
Below `CHART_COL_MIN` a cell is too small to write a day count in — which no font metric can answer,
because that text is written rather than set — and the build fails rather than shipping a grid that merely
looks tight. The row height is a floor of the same kind, and it buys a property the sheets cannot have:
at 7.0 mm it is taller than the type in every script shipped here (Noto Sans and Noto Sans Hebrew want
5.26 mm for a row, Noto Sans Devanagari 5.94), so **the grid's height does not depend on its language** and
the per-row Devanagari cost recorded below is one the chart simply does not pay. It would break below
5.94 mm, which is what a face for a script with deeper marks needs checking against.

## The budget a translation spends is height, not width

The sheets are generated per language, so each gets its own column and its own wrapping — no single layout
has to serve all nine. What does not adapt is the **page**, and that is where a longer translation is felt.
`build-collection-sheets.py` reports the spare on every run, because a sheet with 1 mm of headroom passes
the same green build as one with 30.

The expectation was that a translation costs width, and that Devanagari costs more of it than most:
**15 % wider than Latin at the same point size for identical text**, which is a property of the face
rather than of Nepali. Measuring a real one inverts both halves of that.

Nepali's own expansion, over the **333** metadata units it has translated, shaped with the engine that
draws them: median **0.766**, mean 0.778, p90 1.000, and 0.29 at the narrowest. Devanagari draws each
glyph wider and needs far fewer of them — *Abdominal distension* is `पेट फुल्नु` at 0.31 — so a Nepali
sheet is **narrower** than the English one it came from, not wider. The only entries at or above 1.0 are
the abbreviations that are deliberately identical in both.

And it still grew. Between the same sheet laid out with English labels and with Nepali ones, the surgical
site sheet gained 22 grid units of height while losing two rows and two text runs — so not wrapping. Its
row pitch says what it was: with English labels the pitch is **526** ten times over, and with Nepali
labels that value is **absent** and 594 appears thirteen times. The step is exactly the 68 units by which
Noto Sans Devanagari reaches below the baseline further than Noto Sans does, which is the per-row
clearance recorded above. **A row costs 0.68 mm the moment its text becomes Devanagari**, whatever that
text says.

So the budget is spent one row at a time and is a function of *how many rows are translated*, not of how
long the translation is. That is a worse property than width would have been, because it cannot be
recovered by wording: a translator who shortens a label saves nothing, and **a sheet gets taller as
translation progresses**.

Which means the interesting question is not what fits today but what fits once the reviewing is finished,
and for the surgical-site sheet in Nepali those two answers differ. Measured against the same catalogue in
its two states:

| Nepali surgical-site sheet, drawn from | spare at a 10 mm margin | at 8 mm |
|---|---|---|
| the translations a reviewer has confirmed | +1.3 mm | +6.8 mm |
| those plus the drafts still awaiting review | **−1.2 mm** | **+2.8 mm** |

So a sheet can pass today and fail on nothing but the completion of its own review, and the margin is what
absorbs that. The surgical-site sheet is the tightest in the family and the first to reach the limit; the
others hold between 24 and 146 mm in the same run.

**Be precise about what the failure is, because it is not what the word "overflow" suggests.** The gate
measures against the **bottom margin**, not the paper. Content 1.2 mm past a 10 mm margin still stops
8.8 mm above the page edge: nothing is clipped, nothing is lost, and a printed copy looks entirely normal
— anyone opening the file to look for the damage will correctly find none. What is spent is the border,
and the border is where the headroom for the *next* translation lives, which is why losing it counts as a
failure at all. That makes the gate deliberately conservative rather than an alarm, and it is why the
remedy can be a margin as readily as a denser layout: both return the same commodity.

**No figure from a run belongs in this document.** These two are here because the *comparison* is the
finding; the per-sheet spares are not, and a table of them has already gone stale twice — once when
Devanagari clearance changed the rhythm, once when the catalogue grew. `build-collection-sheets.py`
prints the spare for every form on every run, and that is the number to read.

For the other languages the picture is still borrowed and still about width: rendered width of `msgstr`
over `msgid` across the documentation and reports catalogues is a median of **1.12–1.15** for German and
Spanish, a p90 of **1.35**, and individual strings reaching 1.9 — measured there because the metadata
catalogue those sheets read is at 1 % German and 0 % elsewhere. Those are the languages where the
compounding four — German, Estonian, Turkish, Afrikaans — are worth watching, and not for their average
width: the failure mode on a form is a single unbreakable token, which is what the soft-hyphen convention
above exists for.

## House style: the output is read by people

These SVGs are deliberately plain, and a generator is held to the same standard as the hand-written
original rather than to a lower one because a machine writes it:

- semantic `id`s derived from the metadata `code`, not counters
- presentation in CSS classes in one `<style>` block, never per-element `style="…"`
- integer coordinates on a single grid; no `transform="matrix(…)"`
- deterministic ordering, so regenerating after an unrelated metadata change yields an **empty diff**
- no editor namespace, no generated path soup

**The output is read by a person, and that is the whole point of the rules above.** The sheets are build
output — generated per language during the protocol build, like the decision flow before them, and never
committed — so no commit carries their noise and nothing diffs them. What is reviewed is the **file**: a
maintainer opens a generated SVG and reads it, which is possible only because its ids come from the
metadata codes, its presentation sits in classes, its coordinates are integers on one grid, and it
contains no path soup. Every rule above serves that, and none of them serves a diff.

Determinism serves it too, and one thing besides: identical bytes from identical inputs prove the
generator carries no hidden state — no set iteration order, no dictionary ordering, no clock. A generator
that fails that has a defect whether or not anyone would have noticed, which is why the same property is
required of the **PDF** engine, and why one whose document ID comes from the wall clock was disqualified.

A generator whose output churns is also a generator nobody can read twice the same way, the same failure
as a whole-file re-wrap. Regenerating identically is a check, not an aspiration.

## Language

The generator is Python, and the argument is the **catalogue**.

A localized sheet is assembled from `po/metadata.<lang>.po` and two YAML files, so the generator is
localization tooling and sits where this repository already reserves a place for Python on a library
argument: `polib` for gettext, `ruamel.yaml` for YAML, `tinycss2` for the stylesheet a drawn figure
declares its type scale in. PowerShell has no gettext parser, and hand-rolling one over a `.po` is what
the parse-a-format-with-its-own-parser rule exists to prevent. Reading the CSVs is the trivial part of
the job and drives nothing.

The CSS one earns its place on the same argument rather than on size. The subset a skeleton uses is
tiny — a type selector, class selectors, nothing nested — but the first thing a `selector { … }` regex
gets wrong is a comment containing a brace, and the second is a comment that does not: it folds the
`/* … */` into the selector after it. Neither raises anything. What comes out is a label measured at the
wrong size, which is a figure that overflows or a build that refuses one that would have fitted.

Measurement does not decide it, which is worth saying because the candidate that looks as though it
should is a good one: **`SixLabors.Fonts`** is .NET, so it runs wherever PowerShell does, and it does more
than fontTools — a Universal Shaping Engine for complex scripts, and the Unicode Bidirectional Algorithm.
It answers the measurement question and leaves the catalogue question, which is the one that binds.

Its licence would bar it in any case. The Six Labors Split License conditions its Apache-2.0 grant on
properties of whoever is running the code — non-profit status, revenue, whether the dependency is direct —
rather than on the code itself, so this repository cannot pass a usable permission on to whoever clones
it. Versions before June 2022 were Apache-2.0 and are no way round it: pinning a font library four years
back to escape a relicence forgoes the shaping that made it worth having.

No shaping ruler is needed here in any case. Typst shapes, and measures what it is about to draw.
