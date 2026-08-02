# Fonts

Typefaces the build **embeds**, kept here rather than taken from the machine or from a dependency.

| file | family | upstream |
|---|---|---|
| `NotoSans-Regular.ttf`, `NotoSans-Bold.ttf` | Noto Sans (v2.015) | [notofonts/latin-greek-cyrillic](https://github.com/notofonts/latin-greek-cyrillic) |
| `NotoSansDevanagari-Regular.ttf`, `NotoSansDevanagari-Bold.ttf` | Noto Sans Devanagari | [notofonts/devanagari](https://github.com/notofonts/devanagari) |

All four are **SIL Open Font License 1.1**, which the licence guardrail requires. `OFL-NotoSans.txt` and
`OFL-NotoSansDevanagari.txt` are the upstream licence texts; they are separate files because the two
families come from different upstream repositories and carry different copyright lines, and the OFL
requires the licence to travel with the font.

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

Two rules follow, and both are enforced rather than remembered: a generated figure names exactly one
concrete family and never a fallback list, and text is checked against the face's character map before it
is laid out, so a glyph the font lacks fails the build instead of reaching a PDF nobody opens.
