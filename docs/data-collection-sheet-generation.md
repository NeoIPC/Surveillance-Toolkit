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

Two things there are **editorial and not derivable**, and generation must not pretend otherwise. The
published BSI sheet collapses MRSA, VRE and 3GCR into a single row carrying a footnote — "mark the
resistance profile appropriate to the isolated microorganism" — where the metadata has one element each;
and it shows three organism slots where the metadata may hold more. Where the form groups or truncates
what the model separates, that is a decision, and it belongs in an explicit, checked-in mapping rather
than in the generator's inference.

That the two disagree is itself the argument for generating: the published master sheet offers **six**
antibiotic substance slots and the metadata carries **nine**. The form has been behind the data model, in
public, with nothing to say so.

## House style: the output is read by people

These SVGs are deliberately plain, and a generator is held to the same standard as the hand-written
original rather than to a lower one because a machine writes it:

- semantic `id`s derived from the metadata `code`, not counters
- presentation in CSS classes in one `<style>` block, never per-element `style="…"`
- integer coordinates on a single grid; no `transform="matrix(…)"`
- deterministic ordering, so regenerating after an unrelated metadata change yields an **empty diff**
- no editor namespace, no generated path soup

A generator whose output churns is a generator nobody can review, which is the same failure as a
whole-file re-wrap. The empty-diff property is a check, not an aspiration.

## Language

The generator is Python. The specific argument is text measurement: fontTools reads the real face and has
no cross-platform equivalent reachable from PowerShell — `System.Drawing` is not available on every
platform this must run on, and everything here must work on Windows, Linux and macOS. Reading the CSVs is
the trivial part of the job and does not drive the choice. This is the "a specific argument for a specific
script" bar that the language-fit question sets, met on the measurement rather than on preference.
