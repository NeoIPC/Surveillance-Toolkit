# Fonts

Typefaces the build **embeds**, kept here rather than taken from the machine or from a dependency.

| file | family | upstream |
|---|---|---|
| `NotoSans-Regular.ttf`, `NotoSans-Bold.ttf` | Noto Sans (v2.015) | [notofonts/latin-greek-cyrillic](https://github.com/notofonts/latin-greek-cyrillic) |
| `NotoSans-Italic.ttf`, `NotoSans-BoldItalic.ttf` | Noto Sans (v2.008) | [googlefonts/noto-fonts](https://github.com/googlefonts/noto-fonts) |
| `NotoSansDevanagari-Regular.ttf`, `NotoSansDevanagari-Bold.ttf` | Noto Sans Devanagari | [notofonts/devanagari](https://github.com/notofonts/devanagari) |
| `NotoSansHebrew-Regular.ttf`, `NotoSansHebrew-Bold.ttf` | Noto Sans Hebrew | [notofonts/hebrew](https://github.com/notofonts/hebrew) |
| `NotoSansMath-Regular.ttf` | Noto Sans Math (v2.001) | [notofonts/math](https://github.com/notofonts/math) |

**The italics are a release behind the uprights, and that is checked rather than tolerated.** Noto builds
and versions its italics separately, so v2.015 uprights and v2.008 italics is the pairing upstream
offers. Compared face to face: the italic's character map is 125 codepoints smaller, **none** of them
Greek, Cyrillic or Latin-Extended — they are Vedic combining marks, Roman numerals and a currency sign —
and its descender and cap height are identical to the upright's, which is what lets one row rhythm serve
both. If a future skew did cost a glyph some language needs, the generator's coverage check fails the
build rather than substituting one, so the risk is a stopped build and never a wrong sheet.

**Devanagari has no italic and needs none** — the script has no such distinction. A style asking for one
in Nepali gets the upright Devanagari face, which is a fallback among the files here rather than to
whatever a machine has installed. **Noto Sans Math ships a single weight**, so it answers every style with
its upright: a mathematical operator has no bold or italic form to fall back to.

**Noto Sans Math is last in every language's stack**, reached only for a character neither the Latin face
nor the language's own script face carries. It is here so that a symbol can be a symbol rather than the
letter that resembles it — a summation sign is U+2211, an operator, while the Greek capital sigma Noto
Sans already carries is a letter, and a screen reader, a text extractor and a Greek reader all treat the
two differently. It harmonizes rather than merely coexisting, and that is measured: cap height 714,
x-height 536 and ascent 1069, identical to Noto Sans, so a symbol sits on the same optical line as the
digits beside it. Its descent is deeper — 423 against 293 — which costs nothing here, because a row's
height is measured from its label rather than from the symbols in its cells.

Every family is **SIL Open Font License 1.1**, which the licence guardrail requires. The `OFL-*.txt` files
are the upstream licence texts, one per family: they are separate because the families come from
different upstream repositories and carry different copyright lines, and the OFL requires the licence to
travel with the font.

## Why the fonts are here rather than on the machine

**A generated figure is laid out by measuring text, and the measurement is only worth anything if the
file measured is the file embedded.** Text is wrapped to fit a box by reading advance widths out of the
face at the size it will be drawn at; measuring a different build of the same typeface agrees about every
glyph the two happen to share and is silently wrong about the rest — which is exactly the non-Latin
coverage this project has to get right. Keeping the file here makes measured and embedded the same file
by construction, on a developer machine and on a CI runner alike.

It also removes a dependency on what a machine happens to have installed. prawn-svg, which draws every
SVG in the published PDF, falls back to scanning `/Library/Fonts`, `/usr/share/fonts/truetype` and two
other directories for any family the document has not registered — so a figure naming an unregistered
font renders differently depending on where it was built, and on a CI runner usually resolves to nothing.

## Coverage is a hard boundary, not a gradient

**Noto Sans does not cover Devanagari.** It has 3 884 glyphs including Greek and Cyrillic, and no
Devanagari at all, which is why the Devanagari family is a separate file rather than an afterthought:
Nepali is a target language and would otherwise have rendered as substituted or missing glyphs.

What makes that dangerous rather than merely inconvenient is how the failure presents. prawn-svg maps the
generic CSS family `sans-serif` to **Helvetica**, an AFM core font with Windows-1252 encoding and no
embedded glyphs — so a document that falls through to a generic family gets a font that cannot represent
anything outside Latin-1, and renders every other character as the logical-NOT sign. Nothing warns. That
has already happened here.

Two rules follow, and both are enforced rather than remembered: a generated figure names **only concrete
families shipped here — never a generic** such as `sans-serif`, which is what falls through to Helvetica;
and text is checked against the character maps before it is laid out, so a glyph no face carries fails the
build instead of reaching a PDF nobody opens.

A stack of concrete families is the opposite of that fallback rather than a softer version of it. Each
name resolves to a file in this directory, in a stated order, and the same order is written into both
outputs, so every renderer resolves the same faces. What is barred is a name resolving to whatever a
machine happens to have.
