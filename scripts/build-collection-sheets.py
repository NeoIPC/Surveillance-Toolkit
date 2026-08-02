#!/usr/bin/env python3
"""Generate the NeoIPC data collection sheets as SVG from the canonical metadata.

The sheets are the paper equivalent of the DHIS2 program stages, so they are derived rather than drawn:
sections, field order, labels, option lists and mandatory flags all come from metadata/common/. See
docs/data-collection-sheet-generation.md for the contract this works to and for the renderer behaviour it
has to respect.

Run it:

    python scripts/build-collection-sheets.py --out doc/protocol/img
    python scripts/build-collection-sheets.py --out doc/protocol/img --language de

Exit status is non-zero when a sheet cannot be laid out faithfully -- a label that will not fit its cell,
or text the embedded font has no glyph for. Both are silent defects in the machinery this replaces, and
both are only visible in a rendered PDF that, for a localized build, nobody was producing.
"""

from __future__ import annotations

import argparse
import csv
import sys
from dataclasses import dataclass, field as dc_field
from pathlib import Path

try:
    from fontTools.ttLib import TTFont
except ImportError:  # pragma: no cover - dependency is declared in CI and in the docs
    sys.exit("fontTools is required: python -m pip install fonttools")

try:
    from ruamel.yaml import YAML
except ImportError:  # pragma: no cover
    sys.exit("ruamel.yaml is required: python -m pip install 'ruamel.yaml>=0.18'")

try:
    import polib
except ImportError:  # pragma: no cover
    sys.exit("polib is required: python -m pip install 'polib>=1.2'")


# ── Geometry ────────────────────────────────────────────────────────────────────────────────────────
#
# Hundredths of a millimetre, matching the grid the hand-drawn master sheet already used, so that
# coordinates stay integers and a reviewer reading the SVG can convert one to a position on the page in
# their head. A4 portrait is 21000 x 29700.

PAGE_W, PAGE_H = 21000, 29700
MARGIN_X, MARGIN_TOP, MARGIN_BOTTOM = 1000, 1000, 1500
CONTENT_W = PAGE_W - 2 * MARGIN_X

# The label column takes the left 58 % of the content width. Chosen once, here, rather than per sheet:
# a form whose columns move from page to page is harder to fill in than one with a slightly cramped label.
LABEL_W = int(CONTENT_W * 0.58)
INPUT_X = MARGIN_X + LABEL_W + 200

TITLE_SIZE, SECTION_SIZE, LABEL_SIZE, OPTION_SIZE, SMALL_SIZE = 620, 380, 320, 300, 260
LINE_GAP = 120          # leading between wrapped lines of one label
ROW_PAD = 130           # vertical padding inside a field row
SECTION_BAND_H = 620
BOX_H = 420             # a single-line entry box
CHECK = 300             # a checkbox square

# An option's text starts after its checkbox and a gap, and runs to the right margin.
OPTION_X = INPUT_X + CHECK + 150
OPTION_W = PAGE_W - MARGIN_X - OPTION_X


@dataclass
class Field:
    """One thing a person writes on the sheet."""

    code: str
    label: str
    value_type: str
    compulsory: bool
    options: list[str] = dc_field(default_factory=list)
    radio: bool = False


@dataclass
class Section:
    code: str
    title: str
    description: str
    fields: list[Field] = dc_field(default_factory=list)


@dataclass
class Sheet:
    code: str
    slug: str
    title: str
    sections: list[Section] = dc_field(default_factory=list)


# ── Metadata ────────────────────────────────────────────────────────────────────────────────────────


class Metadata:
    """The canonical CSVs, resolved into the shape a form needs.

    The label preference (formName, then name, then shortName) is the same rule the data-dictionary
    builder applies in `scripts/modules/NeoIPC-Tools/Private/DataDictionary.ps1`. It is restated here
    rather than shared because the two tools are in different languages; if one changes, so must the
    other, and a sheet whose labels disagree with the dictionary is a defect in both.
    """

    def __init__(self, root: Path):
        self.root = root
        self.stages = self._read("programStages.csv")
        self.sections = self._read("programStageSections.csv")
        self.stage_elements = self._read("programStageDataElements.csv")
        self.elements = self._read("dataElements.csv")
        self.option_sets = self._read("optionSets.csv")
        self.options = self._read("options.csv")

        self.element_by_id = {r["id"]: r for r in self.elements}
        self.option_set_by_id = {r["id"]: r for r in self.option_sets}
        self.options_by_set: dict[str, list[dict]] = {}
        for opt in self.options:
            self.options_by_set.setdefault(opt["optionSet"], []).append(opt)
        for opts in self.options_by_set.values():
            opts.sort(key=lambda o: _as_int(o["sortOrder"]))

    def _read(self, name: str) -> list[dict]:
        with (self.root / name).open(encoding="utf-8", newline="") as handle:
            return list(csv.DictReader(handle))

    @staticmethod
    def label_of(row: dict) -> str:
        for key in ("formName", "name", "shortName"):
            value = (row.get(key) or "").strip()
            if value:
                return value
        raise LookupError(f"metadata object {row.get('code') or row.get('id')} has no usable label")


def _as_int(value: str | None) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0


# ── Translation ─────────────────────────────────────────────────────────────────────────────────────


class Catalogue:
    """Localized metadata labels, keyed the way po/metadata.pot keys them: <type>/<CODE>/<FIELD>.

    An untranslated entry falls back to the source string rather than failing. That is deliberate and is
    the opposite of the rule for a missing GLYPH: an English label in a German form is legible and
    obviously incomplete, while a missing glyph is a mark nobody can read and nothing announces.
    """

    def __init__(self, po_path: Path | None):
        self.entries: dict[str, str] = {}
        if po_path is None:
            return
        for entry in polib.pofile(str(po_path)):
            if entry.msgctxt and entry.translated():
                self.entries[entry.msgctxt] = entry.msgstr

    def get(self, context: str, source: str) -> str:
        return self.entries.get(context, source)


def load_chrome(path: Path, catalogue: Catalogue) -> dict[str, str]:
    yaml = YAML(typ="safe")
    with path.open(encoding="utf-8") as handle:
        strings = yaml.load(handle)
    return {k: catalogue.get(f"sheetStrings/{k}", v) for k, v in strings.items()}


# ── Measurement ─────────────────────────────────────────────────────────────────────────────────────


class Face:
    """Advance widths and coverage from the font file the PDF will embed.

    Both halves matter. The width is what makes wrapping fit a real box instead of a character count --
    the XSLT this replaces measured `string-length`, to which IIIII and WWWWW are the same size. The
    coverage check is what stops a glyph the face lacks reaching a PDF: prawn-svg resolves an unknown
    family to Helvetica, a Windows-1252 core font, and every character outside that set then renders as
    the logical-NOT sign with no warning anywhere.
    """

    def __init__(self, path: Path):
        self.path = path
        self.font = TTFont(str(path))
        self.units = self.font["head"].unitsPerEm
        self.widths = {name: adv for name, (adv, _) in self.font["hmtx"].metrics.items()}
        self.cmap = self.font.getBestCmap()

    def missing(self, text: str) -> set[str]:
        return {ch for ch in text if ord(ch) not in self.cmap and not ch.isspace()}

    def width(self, text: str, size: int) -> float:
        total = 0
        for ch in text:
            glyph = self.cmap.get(ord(ch))
            total += self.widths.get(glyph, self.widths.get(".notdef", 0))
        return total * size / self.units

    def wrap(self, text: str, size: int, max_width: int) -> list[str]:
        """Greedy wrap on whitespace, measured in the real face.

        A single word wider than the cell is NOT broken and NOT silently emitted: it is returned as its
        own line and the caller fails on it. Emitting it whole is what the XSLT did, and it is the normal
        case for a German compound.
        """
        lines: list[str] = []
        current = ""
        for word in text.split():
            candidate = f"{current} {word}".strip()
            if current and self.width(candidate, size) > max_width:
                lines.append(current)
                current = word
            else:
                current = candidate
        if current:
            lines.append(current)
        return lines or [""]


class Overflow(Exception):
    """A label that cannot be laid out faithfully. Never rendered anyway -- the build stops."""


# ── Sheet assembly ──────────────────────────────────────────────────────────────────────────────────


def build_sheets(meta: Metadata, catalogue: Catalogue) -> list[Sheet]:
    """One sheet per program stage, in the stages' own sort order."""
    sections_by_stage: dict[str, list[dict]] = {}
    for section in meta.sections:
        sections_by_stage.setdefault(section["programStage"], []).append(section)
    for group in sections_by_stage.values():
        group.sort(key=lambda s: _as_int(s["sortOrder"]))

    elements_by_stage: dict[str, dict[str, dict]] = {}
    for link in meta.stage_elements:
        elements_by_stage.setdefault(link["programStage"], {})[link["dataElement"]] = link

    sheets: list[Sheet] = []
    for stage in sorted(meta.stages, key=lambda s: _as_int(s["sortOrder"])):
        links = elements_by_stage.get(stage["id"], {})
        sheet = Sheet(
            code=stage["code"],
            slug=_slug(stage["code"]),
            title=catalogue.get(f"programStages/{stage['code']}/NAME", stage["name"]),
        )
        for section in sections_by_stage.get(stage["id"], []):
            model = Section(
                code=section["code"],
                title=catalogue.get(f"programStageSections/{section['code']}/NAME", section["name"]),
                description=catalogue.get(
                    f"programStageSections/{section['code']}/DESCRIPTION", section["description"]
                ),
            )
            # The section's dataElements column is a space-separated UID list and IS the authored order
            # of the fields within it; programStageDataElements.sortOrder orders the stage as a whole and
            # would interleave sections if used here.
            for uid in (section["dataElements"] or "").split():
                element = meta.element_by_id.get(uid)
                if element is None:
                    raise LookupError(f"section {section['code']} references unknown element {uid}")
                link = links.get(uid, {})
                model.fields.append(_field_of(meta, catalogue, element, link))
            sheet.sections.append(model)
        if sheet.sections:
            sheets.append(sheet)
    return sheets


def _field_of(meta: Metadata, catalogue: Catalogue, element: dict, link: dict) -> Field:
    code = element["code"]
    options: list[str] = []
    if element.get("optionSet"):
        option_set = meta.option_set_by_id.get(element["optionSet"])
        if option_set is not None:
            for opt in meta.options_by_set.get(option_set["id"], []):
                context = f"options/{option_set['code']}/{opt['code']}/NAME"
                options.append(catalogue.get(context, opt["name"]))
    return Field(
        code=code,
        label=catalogue.get(f"dataElements/{code}/FORM_NAME", Metadata.label_of(element)),
        value_type=element["valueType"],
        compulsory=(link.get("compulsory") or "").lower() == "true",
        options=options,
        radio=(link.get("renderOptionsAsRadio") or "").lower() == "true",
    )


def _slug(code: str) -> str:
    return code.removeprefix("NEOIPC_STG_").lower().replace("_", "-")


# ── Layout and emission ─────────────────────────────────────────────────────────────────────────────


class SvgWriter:
    """Emits the minimal, hand-written style the repository uses for its figures.

    Semantic ids from the metadata code, presentation in classes, integer coordinates, deterministic
    order, no transform matrices and no per-element style. The property that makes it reviewable is that
    regenerating with unchanged metadata produces a byte-identical file.
    """

    def __init__(self, face: Face, bold: Face, chrome: dict[str, str], language: str | None):
        self.face, self.bold, self.chrome, self.language = face, bold, chrome, language
        self.missing: dict[str, set[str]] = {}

    def _text(self, text: str, size: int, bold: bool = False) -> None:
        face = self.bold if bold else self.face
        absent = face.missing(text)
        if absent:
            self.missing.setdefault(face.path.name, set()).update(absent)

    def sheet_svg(self, sheet: Sheet, page: int, pages: int, body: list[str]) -> str:
        head = [
            '<svg version="1.1" viewBox="0 0 %d %d" xmlns="http://www.w3.org/2000/svg">' % (PAGE_W, PAGE_H),
            "  <style>",
            "    text { font-family: 'Noto Sans'; fill: #000; }",
            "    text.title { font-size: %dpx; font-weight: bold; }" % TITLE_SIZE,
            "    text.section { font-size: %dpx; font-weight: bold; }" % SECTION_SIZE,
            "    text.label { font-size: %dpx; }" % LABEL_SIZE,
            "    text.option { font-size: %dpx; }" % OPTION_SIZE,
            "    text.small { font-size: %dpx; fill: #444; }" % SMALL_SIZE,
            "    rect.box { fill: none; stroke: #000; stroke-width: 20; }",
            "    rect.check { fill: none; stroke: #000; stroke-width: 20; }",
            "    rect.band { fill: #e8eef4; stroke: none; }",
            "    line.rule { stroke: #999; stroke-width: 12; }",
            "  </style>",
        ]
        return "\n".join(head + body + ["</svg>", ""])


def layout_sheet(sheet: Sheet, writer: SvgWriter) -> list[str]:
    """Flow the sheet's sections down the page, returning SVG body lines.

    **A sheet is one page.** That is a requirement of the artifact, not a limitation of this emitter: it
    is filled in at a cot side, and a form that runs onto a second sheet loses half of itself. So there
    is no pagination to fall back on, and a sheet that does not fit is a layout that has to get denser --
    which is a decision about the form, taken deliberately, rather than something a generator may resolve
    on its own by spilling onto another page.
    """
    out: list[str] = []
    y = MARGIN_TOP + TITLE_SIZE
    writer._text(sheet.title, TITLE_SIZE, bold=True)
    out.append(f'  <text id="{sheet.slug}-title" class="title" x="{MARGIN_X}" y="{y}">{_esc(sheet.title)}</text>')
    y += 700

    for section in sheet.sections:
        y = _emit_section(out, section, y, writer)

    usable = PAGE_H - MARGIN_BOTTOM
    if y > usable:
        raise Overflow(
            f"{sheet.code}: content runs to {y} on a page whose usable height ends at {usable} "
            f"({y / usable:.2f} pages). A sheet must fit one page, so this needs a denser layout for "
            f"this stage -- not a second page."
        )
    return out


def _emit_section(out: list[str], section: Section, y: int, writer: SvgWriter) -> int:
    writer._text(section.title, SECTION_SIZE, bold=True)
    out.append(f'  <rect class="band" x="{MARGIN_X}" y="{y}" width="{CONTENT_W}" height="{SECTION_BAND_H}"/>')
    out.append(
        f'  <text id="{_slug(section.code)}" class="section" x="{MARGIN_X + 150}" '
        f'y="{y + SECTION_BAND_H - 180}">{_esc(section.title)}</text>'
    )
    y += SECTION_BAND_H + ROW_PAD

    for field in section.fields:
        y = _emit_field(out, field, y, writer)
    return y + ROW_PAD


def _emit_field(out: list[str], field: Field, y: int, writer: SvgWriter) -> int:
    label = field.label + (f" ({writer.chrome['required']})" if field.compulsory else "")
    writer._text(label, LABEL_SIZE)
    lines = _fit(writer, label, LABEL_SIZE, LABEL_W, field.code, "label")

    # Option text is wrapped and measured exactly like a label. Wrapping only the labels is how the first
    # emitter ran the admission type's longest choice off the right edge of the page: the two columns are
    # different widths, so a rule applied to one of them says nothing about the other.
    option_lines = [
        _fit(writer, option, OPTION_SIZE, OPTION_W, field.code, f"option {index + 1}")
        for index, option in enumerate(field.options)
    ]
    for option in field.options:
        writer._text(option, OPTION_SIZE)

    top = y
    for line in lines:
        out.append(f'  <text class="label" x="{MARGIN_X + 150}" y="{y + LABEL_SIZE}">{_esc(line)}</text>')
        y += LABEL_SIZE + LINE_GAP

    y = max(y, top + _input_height(field, option_lines))
    _emit_input(out, field, top, writer, option_lines)
    return y + ROW_PAD


def _fit(writer: SvgWriter, text: str, size: int, width: int, code: str, what: str) -> list[str]:
    """Wrap to the cell, and refuse to emit anything that still does not fit.

    `wrap` cannot break inside a word, so a single token wider than the cell comes back as its own
    over-long line. That is the German-compound case, and emitting it anyway is precisely what the XSLT
    wrapper did -- silently, because character counting cannot tell that it happened.
    """
    lines = writer.face.wrap(text, size, width)
    widest = max(writer.face.width(line, size) for line in lines)
    if widest > width:
        raise Overflow(
            f"{code}: the {what} {text!r} contains a word wider than its {width}-unit cell "
            f"({widest:.0f} units at size {size}). Shorten the text or widen the column; it must not be "
            f"emitted overflowing."
        )
    return lines


def _input_height(field: Field, option_lines: list[list[str]]) -> int:
    if option_lines:
        return sum(max(CHECK, len(lines) * (OPTION_SIZE + LINE_GAP)) + 120 for lines in option_lines)
    if field.value_type == "BOOLEAN":
        return CHECK + 120
    return BOX_H


def _emit_input(out: list[str], field: Field, y: int, writer: SvgWriter, option_lines: list[list[str]]) -> None:
    width = PAGE_W - MARGIN_X - INPUT_X
    ident = field.code.lower().replace("_", "-")

    if option_lines:
        oy = y
        for index, lines in enumerate(option_lines):
            out.append(f'  <rect id="{ident}-{index + 1}" class="check" x="{INPUT_X}" y="{oy}" width="{CHECK}" height="{CHECK}"/>')
            ty = oy + CHECK - 40
            for line in lines:
                out.append(f'  <text class="option" x="{OPTION_X}" y="{ty}">{_esc(line)}</text>')
                ty += OPTION_SIZE + LINE_GAP
            oy += max(CHECK, len(lines) * (OPTION_SIZE + LINE_GAP)) + 120
        return

    if field.value_type == "BOOLEAN":
        for index, key in enumerate(("boolean_yes", "boolean_no")):
            word = writer.chrome[key]
            writer._text(word, OPTION_SIZE)
            ox = INPUT_X + index * 2200
            out.append(f'  <rect id="{ident}-{key.split("_")[1]}" class="check" x="{ox}" y="{y}" width="{CHECK}" height="{CHECK}"/>')
            out.append(f'  <text class="option" x="{ox + CHECK + 150}" y="{y + CHECK - 40}">{_esc(word)}</text>')
        return

    if field.value_type == "TRUE_ONLY":
        out.append(f'  <rect id="{ident}" class="check" x="{INPUT_X}" y="{y}" width="{CHECK}" height="{CHECK}"/>')
        return

    out.append(f'  <rect id="{ident}" class="box" x="{INPUT_X}" y="{y}" width="{width}" height="{BOX_H}"/>')


def _esc(text: str) -> str:
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


# ── Entry point ─────────────────────────────────────────────────────────────────────────────────────


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    repo = Path(__file__).resolve().parent.parent
    parser.add_argument("--metadata", type=Path, default=repo / "metadata" / "common")
    parser.add_argument("--fonts", type=Path, default=repo / "common" / "fonts")
    parser.add_argument("--strings", type=Path, default=repo / "common" / "sheet-strings.yaml")
    parser.add_argument("--po", type=Path, default=repo / "po")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--language", default=None, help="culture code; omit for the untranslated source")
    parser.add_argument("--sheet", default=None, help="only this stage code, e.g. NEOIPC_STG_BSI")
    args = parser.parse_args(argv)

    po_path = args.po / f"metadata.{args.language}.po" if args.language else None
    if po_path is not None and not po_path.exists():
        return _fail(f"no catalogue at {po_path}; --language must name a culture the metadata catalogue has")
    catalogue = Catalogue(po_path)
    chrome = load_chrome(args.strings, catalogue)

    # Devanagari is a separate face because Noto Sans does not cover it -- see common/fonts/README.md.
    family = "NotoSansDevanagari" if args.language == "ne" else "NotoSans"
    face = Face(args.fonts / f"{family}-Regular.ttf")
    bold = Face(args.fonts / f"{family}-Bold.ttf")

    meta = Metadata(args.metadata)
    sheets = build_sheets(meta, catalogue)
    if args.sheet:
        sheets = [s for s in sheets if s.code == args.sheet]
        if not sheets:
            return _fail(f"no stage with code {args.sheet}")

    args.out.mkdir(parents=True, exist_ok=True)
    suffix = f".{args.language}" if args.language else ""
    written, failures = [], []
    for sheet in sheets:
        writer = SvgWriter(face, bold, chrome, args.language)
        try:
            body = layout_sheet(sheet, writer)
        except Overflow as overflow:
            failures.append(str(overflow))
            continue
        if writer.missing:
            for font_name, chars in sorted(writer.missing.items()):
                shown = " ".join(f"U+{ord(c):04X} {c!r}" for c in sorted(chars))
                failures.append(f"{sheet.code}: {font_name} has no glyph for {shown}")
            continue
        target = args.out / f"NeoIPC-Core-{sheet.slug}-Sheet{suffix}.svg"
        target.write_text(writer.sheet_svg(sheet, 1, 1, body), encoding="utf-8", newline="\n")
        written.append(target)

    for line in failures:
        print(f"error: {line}", file=sys.stderr)
    for target in written:
        print(f"wrote {target}")
    return 1 if failures else 0


def _fail(message: str) -> int:
    print(f"error: {message}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
