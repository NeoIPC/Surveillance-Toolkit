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

Hand-drawing was tried and abandoned half-way, which is the practical half of the argument. Two SVGs
survive from it: `NeoIPC-Core-Master-Data-Collection-Sheet.svg`, which is minimal and hand-written and
stops after the first few fields, and `NeoIPC-Core-Patient-Progress-Chart.svg`, which is A4 landscape and
carries 367 `<path>` elements where the grid should be `<rect>` and `<line>` — editor output with the
namespaces stripped rather than something anyone would maintain by hand.

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

The standalone PDF is rendered from the generated SVG through **asciidoctor-pdf**, on a generated
one-page AsciiDoc, rather than through a second SVG renderer. One renderer means one set of quirks, and
they are the quirks already characterised below.

## What the renderer actually supports

Established by rendering, then confirmed against `refs/prawn-svg` (v0.34.2, the version
`asciidoctor-pdf ~> 0.34.0` resolves). Both halves matter: the render says what happens, the source says
why, and neither alone would have been trusted.

| construct | behaviour |
|---|---|
| `<symbol>` + `<use>`, with `viewBox` | renders, scaled correctly |
| `<g>`, `<defs>`, `<clipPath>`, `<marker>`, gradients | supported |
| `<image>` raster | renders; **`xlink:href` resolves relative to the SVG file**, not to the document |
| `<filter>` (incl. `feDropShadow`) | **silently ignored** |
| `<mask>` | **silently ignored** |
| `<foreignObject>` | ignored |

`prawn/svg/elements.rb` maps `filter:` and `mask:` to `Elements::Ignored`, commented `# unsupported`. No
warning is emitted, so a decorative shadow that does nothing is indistinguishable from one that works —
which is how the existing master sheet's drop shadow went unnoticed. **The generator emits no filters and
no masks**; anything that would need one is not decoration this project can afford.

The relative-`href` rule is why the existing generated sheet loses its logo: it carries
`xlink:href="img/LOGO_NEOIPC_2.png"` while sitting *in* `img/`, so the renderer looks for `img/img/…`.
A raster referenced from a generated SVG is named relative to that SVG.

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

  What happens at the end of that list is the part that has already cost this project a defect.
  `Prawn::SVG::Font::GENERIC_CSS_FONT_MAPPING` resolves `sans-serif` to **Helvetica** — an AFM core font
  with Windows-1252 encoding and no embedded glyphs at all. That is the whole mechanism behind every
  non-Latin-1 character in an earlier figure rendering as the logical-NOT sign: not a corrupted file, a
  correct fallback to a font that cannot represent the text. `font-family:"Noto Sans", Arial, Helvetica,
  sans-serif` is therefore a trap dressed as prudence, and the existing AWaRe badges saying plain
  `font-family:Arial` resolve to nothing on any machine this builds on.

  **Generated sheets name exactly one family, `Noto Sans`, with no fallback list.** A missing font must
  fail rather than degrade, because the degraded form is silent and is wrong precisely in the languages
  this exists to serve.
- **It must be the same file the PDF embeds.** The theme points at `GEM_FONTS_DIR/notosans-*-subset.ttf`,
  asciidoctor-pdf's own pre-subsetted build, which lives inside the gem. Measuring a system Noto Sans
  instead would agree on the advance width of every glyph it happens to share and be silently wrong about
  the ones it does not — which is precisely the non-Latin coverage this project has open questions about.
  So the fonts move into the repository and the theme points at them, making the measured file and the
  embedded file the same file by construction. Noto is SIL OFL, which the licence guardrail requires.

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

**The one-page rule moves with the print path.** Today it is asserted by measuring; for the PDF it becomes
exact and trivial — compile, count pages, fail if there is more than one. That is a stronger gate than the
current one because it is the engine's own answer rather than a prediction of it.

### The consequence for measurement, which reverses an earlier conclusion

This document already records that summing `hmtx` advances is exact **because prawn-svg does not shape**,
and that adding HarfBuzz would introduce a disagreement rather than resolve one. Both remain true of the
current renderer, and both stop being true the moment Typst draws the page: Typst *does* shape, so the
naive sum would no longer be what gets drawn, and the one-page gate would be measuring a width the engine
does not produce.

So the same change that is wrong today becomes necessary after the switch — measure with the shaper the
engine uses, or let the engine do the measuring and give up the exact one-page control the generator
currently has. That is a decision to take deliberately when the emitter is built, and it is the reason
this paragraph exists rather than being discovered by a form that overflows in Nepali.

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

**Slot counts are the same kind of decision, and one of them is currently wrong in public.** Checked
rather than assumed: BSI, HAP and SSI each carry exactly three organism slots in the metadata and the
published sheets print three, so nothing is truncated there. But the metadata carries **nine** antibiotic
substance slots and the published master sheet offers **six**. The form has been behind the data model, on
the website, with nothing to say so — which is the argument for generating, and the reason the printed
count is recorded as a decision instead of left to whoever last edited a Word file.

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

Two things follow. The decision flow moves onto the same measured layout as the sheets rather than
waiting behind them — its need is more urgent, not less, because its boxes are fixed and its text is
long. And its eight strings move out of `.resx` with it: they are already whole sentences, so nothing
about them needs splitting by a translator, and the wrapping was never theirs to think about.

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

## The width budget, and which language spends it

The sheets are generated per language, so each gets its own column and its own wrapping — no single layout
has to serve all nine. What does not adapt is the **page**, and that is where a longer translation is felt.

`build-collection-sheets.py` reports the spare on every run because a sheet with 1 mm of headroom passes
the same green build as one with 30. Converting that to the expansion each sheet can absorb before it
stops fitting, measured by scaling every advance width:

| sheet | absorbs up to |
|---|---|
| surgery, NEC | ×2.0 or more |
| master | ×1.74 |
| primary sepsis/BSI | ×1.24 |
| SSI, pneumonia | does not fit in English yet |

Against that, NeoIPC's own measured expansion — rendered width of `msgstr` over `msgid` across the
translated catalogues — is a median of **1.12–1.15** for German and Spanish and a p90 of **1.35**, with
individual strings reaching 1.9. So the BSI sheet survives a typical German translation and not an
unusual one, which is a real risk rather than a theoretical one.

Two caveats on those numbers. The **metadata catalogue, which is what the sheets read, is essentially
untranslated** — German is at 1 %, the other five at 0 % — so the expansion figures above are borrowed
from the documentation and reports catalogues, and no German sheet has ever been laid out. And Devanagari
is **15 % wider than Latin at the same point size for identical text**, which is a property of the face
rather than of Nepali, and comes on top of whatever Nepali's own expansion turns out to be.

The four target languages that build compounds — German, Estonian, Turkish, Afrikaans — are the ones to
watch, and not because of their average width: the failure mode on a form is a single unbreakable token,
which is what the soft-hyphen convention above exists for.

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

The generator is Python. The specific argument is text measurement: fontTools reads the real face and has
no cross-platform equivalent reachable from PowerShell — `System.Drawing` is not available on every
platform this must run on, and everything here must work on Windows, Linux and macOS. Reading the CSVs is
the trivial part of the job and does not drive the choice. This is the "a specific argument for a specific
script" bar that the language-fit question sets, met on the measurement rather than on preference.
