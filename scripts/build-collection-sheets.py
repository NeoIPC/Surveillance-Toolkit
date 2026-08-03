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
import re
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
MARGIN_X, MARGIN_TOP, MARGIN_BOTTOM = 1250, 1000, 1200
CONTENT_W = PAGE_W - 2 * MARGIN_X

# There is no input COLUMN. A field is a full-width row: the label in bold at the left, and the rest of
# the row is the space to write in -- which is what the published forms do and is most of why they fit one
# page. Splitting the row into a label column and an input column, which is the obvious first design,
# wastes the majority of the sheet and turned the primary sepsis form into three pages.
TEXT_X = MARGIN_X + 180                 # left text inset inside the table
OPTION_INDENT = 700                     # options sit indented under their field
OPTION_GAP = 700                        # space between options laid out along one line

TITLE_SIZE, SUBTITLE_SIZE = 560, 400
SECTION_SIZE, LABEL_SIZE, OPTION_SIZE, SMALL_SIZE = 320, 300, 280, 240
# The vertical rhythm is measured against the published forms rather than chosen for comfort: they fit an
# infection sheet onto one page, so their row pitch is the budget this has to work within.
LINE_GAP = 90                           # leading between wrapped lines of one text run
ROW_PAD = 70                            # vertical padding above and below a row's text
SECTION_BAND_H = 460
MARK = 260                              # a choose-one circle or choose-any square
MARK_GAP = 180                          # between a mark and its text
COMMENTS_MIN = 1200                     # below this the leftover is a gap, not a usable writing space

# The brand's two primary colours, from the NeoIPC visual guideline: PANTONE 7460 C and 1495 C. Taken
# from the guideline rather than sampled from an artifact -- an earlier guess of #2e74b5 was a Word
# default that merely looked similar.
ACCENT = "#0083c1"
BRAND_ORANGE = "#ff9015"
BAND_FILL = "#cfe7f4"                   # a tint of the brand blue, light enough to print behind text

# The logo is INLINED, not referenced. It is vector, so there is no raster anywhere on a sheet, and a
# sheet carries its own logo instead of depending on what happens to sit beside it -- which matters for
# the standalone print forms, which do not live in the protocol's image directory. prawn-svg renders
# <symbol> and <use>, verified rather than assumed.
#
# The guideline gives the vertical lockup a 30 mm minimum and forbids altering its proportions, so the
# width below is a deliberate margin above that minimum and the height is derived from the artwork's own
# aspect rather than chosen.
LOGO_FILE = "NeoIPC-Logo-Horizontal.svg"
LOGO_W = 4200                           # 42 mm, above the guideline's 40 mm minimum for this lockup


@dataclass
class Field:
    """One thing a person writes on the sheet."""

    code: str
    label: str
    value_type: str
    compulsory: bool
    options: list[str] = dc_field(default_factory=list)
    radio: bool = False
    write_in: bool = False

    @property
    def is_child(self) -> bool:
        """A field the metadata marks as belonging to the one above it, by starting its form name '- '.

        The convention is the authors' own and covers 117 of the 252 elements -- an organism slot's name,
        source and resistance flags all hang off its `Organism N` row that way. Reading it is what lets a
        slot be printed as one compact block instead of nine labelled rows, which is the whole difference
        between the infection sheets fitting a page and running to three.
        """
        return self.label.startswith("- ")

    @property
    def short_label(self) -> str:
        return self.label.removeprefix("- ").strip()


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
        self.attributes = self._read("trackedEntityAttributes.csv")
        self.program_attributes = self._read("programTrackedEntityAttributes.csv")

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


class Logo:
    """The brand logo, inlined into each sheet as a <symbol> so a sheet carries its own artwork.

    Referencing it instead would bind every sheet to the directory it was written into, because
    prawn-svg resolves an <image> href relative to the SVG file rather than to the document embedding
    it -- which is fine for the protocol's figures and wrong for the standalone print forms. Inlining
    also keeps the sheets entirely vector: no raster anywhere, at any print size.
    """

    def __init__(self, path: Path):
        source = path.read_text(encoding="utf-8")
        self.view_box = re.search(r'viewBox="([^"]+)"', source).group(1)
        _, _, w, h = (float(v) for v in self.view_box.split())
        self.aspect = w / h
        body = source.split("</style>", 1)[1].rsplit("</svg>", 1)[0]
        self.body = [line for line in body.splitlines() if line.strip()]

    def definition(self) -> list[str]:
        return (
            [f'  <symbol id="neoipc-logo" viewBox="{self.view_box}">']
            + [f"  {line}" for line in self.body]
            + ["  </symbol>"]
        )

    def place(self, x: int, y: int, width: int) -> list[str]:
        height = round(width / self.aspect)
        return [f'  <use href="#neoipc-logo" x="{x}" y="{y}" width="{width}" height="{height}"/>']


class LayoutRules:
    """The editorial half: how a field is ASKED, which the metadata does not say.

    The published forms settle that this cannot be inferred. `NEOIPC_BSI_AB_TREATMENT` is TRUE_ONLY and
    is printed as a choose-one Yes/No pair; the BOOLEAN signs-and-symptoms elements beside it are each a
    single choose-any square with no negative answer. Reading valueType would get both backwards, so the
    decision is looked up here and an unlisted field takes the declared default.
    """

    def __init__(self, path: Path):
        yaml = YAML(typ="safe")
        with path.open(encoding="utf-8") as handle:
            rules = yaml.load(handle) or {}
        self.default = rules.get("default_boolean", "tick")
        self.styles: dict[str, str] = rules.get("boolean_style") or {}
        self.section_order: dict[str, list[str]] = rules.get("section_order") or {}
        self.composites: dict[str, dict] = rules.get("composites") or {}

    @property
    def absorbed_stages(self) -> set[str]:
        """Stages printed as part of a composite, and therefore not printed on their own as well."""
        return {block for c in self.composites.values() for block in c["blocks"] if block != "enrolment"}

    def order_sections(self, stage_code: str, sections: list[dict]) -> list[dict]:
        """Print order, which is not the capture order the metadata records.

        Refuses a list that does not account for every section of the stage. Silently dropping one would
        not read as a layout mistake on the finished sheet -- it would read as a field that is not
        collected.
        """
        wanted = self.section_order.get(stage_code)
        if not wanted:
            return sorted(sections, key=lambda s: _as_int(s["sortOrder"]))
        present = {s["code"] for s in sections}
        if set(wanted) != present:
            missing = ", ".join(sorted(present - set(wanted))) or "none"
            unknown = ", ".join(sorted(set(wanted) - present)) or "none"
            raise LookupError(
                f"section_order for {stage_code} does not match the stage: not listed = {missing}; "
                f"listed but not in the stage = {unknown}. Every section must be named."
            )
        by_code = {s["code"]: s for s in sections}
        return [by_code[code] for code in wanted]

    def boolean_style(self, field: Field) -> str:
        if field.options or field.value_type not in ("BOOLEAN", "TRUE_ONLY"):
            return "write"
        return self.styles.get(field.code, self.default)


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


def build_sheets(meta: Metadata, catalogue: Catalogue, rules: LayoutRules,
                 chrome: dict[str, str]) -> list[Sheet]:
    """One sheet per program stage, in the stages' own sort order."""
    sections_by_stage: dict[str, list[dict]] = {}
    for section in meta.sections:
        sections_by_stage.setdefault(section["programStage"], []).append(section)
    # Ordering happens per stage below, because it needs the stage's code to look up an override.

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
        for section in rules.order_sections(stage["code"], sections_by_stage.get(stage["id"], [])):
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

    return _apply_composites(sheets, meta, catalogue, rules, chrome)


def _apply_composites(
    sheets: list[Sheet], meta: Metadata, catalogue: Catalogue, rules: LayoutRules, chrome: dict[str, str]
) -> list[Sheet]:
    """Fold the stages a composite claims into one sheet, and drop them as standalone sheets."""
    if not rules.composites:
        return sheets
    by_code = {s.code: s for s in sheets}
    composed: list[Sheet] = []
    for name, spec in rules.composites.items():
        sheet = Sheet(code=name.upper(), slug=spec["slug"], title=chrome[spec["title_key"]])
        for block in spec["blocks"]:
            if block == "enrolment":
                sheet.sections.append(_enrolment_section(meta, catalogue, chrome))
                continue
            stage = by_code.get(block)
            if stage is None:
                raise LookupError(f"composite {name!r} names {block}, which is not a stage with sections")
            sheet.sections.extend(stage.sections)
        composed.append(sheet)

    absorbed = rules.absorbed_stages
    return composed + [s for s in sheets if s.code not in absorbed]


def _enrolment_section(meta: Metadata, catalogue: Catalogue, chrome: dict[str, str]) -> Section:
    """The patient's own attributes, which belong to no stage and so have no section to name them."""
    by_id = {a["id"]: a for a in meta.attributes}
    section = Section(code="ENROLMENT", title=chrome["section_enrolment"], description="")
    for link in sorted(meta.program_attributes, key=lambda r: _as_int(r["sortOrder"])):
        attribute = by_id.get(link["trackedEntityAttribute"])
        if attribute is None:
            raise LookupError(f"programTrackedEntityAttributes references unknown attribute {link['trackedEntityAttribute']}")
        code = attribute["code"]
        section.fields.append(
            Field(
                code=code,
                label=catalogue.get(f"trackedEntityAttributes/{code}/FORM_NAME", Metadata.label_of(attribute)),
                value_type=attribute["valueType"],
                # An attribute says `mandatory` where a stage element says `compulsory`; same question.
                compulsory=(link.get("mandatory") or "").lower() == "true",
                options=_options_of(meta, catalogue, attribute)[0],
                radio=True,
                write_in=_options_of(meta, catalogue, attribute)[1],
            )
        )
    return section


def _options_of(meta: Metadata, catalogue: Catalogue, element: dict) -> tuple[list[str], bool]:
    if not element.get("optionSet"):
        return [], False
    option_set = meta.option_set_by_id.get(element["optionSet"])
    if option_set is None:
        return [], True
    return [
        catalogue.get(f"options/{option_set['code']}/{opt['code']}/NAME", opt["name"])
        for opt in meta.options_by_set.get(option_set["id"], [])
    ], False


def _field_of(meta: Metadata, catalogue: Catalogue, element: dict, link: dict) -> Field:
    code = element["code"]
    options: list[str] = []
    write_in = False
    if element.get("optionSet"):
        option_set = meta.option_set_by_id.get(element["optionSet"])
        if option_set is None:
            # A set referenced by UID that optionSets.csv does not define -- the organism list, which is
            # authored in the infectious-agents catalogue and runs to hundreds of entries. It cannot be
            # ticked on paper, so the field becomes a write-in line, which is what the published sheets
            # do. Handled explicitly: falling through to "no options" produces the same output by
            # accident, and would go on doing so if a small set ever went missing by mistake.
            write_in = True
        else:
            for opt in meta.options_by_set.get(option_set["id"], []):
                context = f"options/{option_set['code']}/{opt['code']}/NAME"
                options.append(catalogue.get(context, opt["name"]))
    return Field(
        code=code,
        label=catalogue.get(f"dataElements/{code}/FORM_NAME", Metadata.label_of(element)),
        value_type=element["valueType"],
        compulsory=(link.get("compulsory") or "").lower() == "true",
        options=options,
        # An option-set field holds ONE value, so its choices are choose-one: a circle. Deliberately not
        # taken from renderOptionsAsRadio, which is a widget hint for the capture app rather than a
        # statement about cardinality -- it is False for the admission type, a field with exactly one
        # answer, and reading it would print choose-any squares against a question that permits one tick.
        # Where a published form re-expresses a combined option as several independent ticks -- the BSI
        # organism source, whose set carries Blood, CSF and Both -- that is an editorial decision and
        # belongs in the layout mapping, not here.
        radio=True,
        write_in=write_in,
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

    def __init__(self, face: Face, bold: Face, chrome: dict[str, str], layout: LayoutRules, logo: Logo,
                 language: str | None):
        self.face, self.bold, self.chrome, self.layout = face, bold, chrome, layout
        self.logo, self.language = logo, language
        self.missing: dict[str, set[str]] = {}

    def _text(self, text: str, size: int, bold: bool = False) -> None:
        face = self.bold if bold else self.face
        absent = face.missing(text)
        if absent:
            self.missing.setdefault(face.path.name, set()).update(absent)

    def sheet_svg(self, sheet: Sheet, body: list[str]) -> str:
        head = [
            '<svg version="1.1" viewBox="0 0 %d %d" xmlns="http://www.w3.org/2000/svg" '
            'xmlns:xlink="http://www.w3.org/1999/xlink">' % (PAGE_W, PAGE_H),
            "  <style>",
            "    text { font-family: 'Noto Sans'; fill: #000; }",
            "    text.title { font-size: %dpx; fill: %s; }" % (TITLE_SIZE, ACCENT),
            "    text.subtitle { font-size: %dpx; fill: %s; }" % (SUBTITLE_SIZE, ACCENT),
            "    text.section { font-size: %dpx; text-anchor: middle; }" % SECTION_SIZE,
            "    text.label { font-size: %dpx; font-weight: bold; }" % LABEL_SIZE,
            "    text.option { font-size: %dpx; }" % OPTION_SIZE,
            "    text.child { font-size: %dpx; font-weight: bold; }" % OPTION_SIZE,
            "    text.legend { font-size: %dpx; font-style: italic; }" % SMALL_SIZE,
            "    rect.band { fill: %s; stroke: none; }" % BAND_FILL,
            "    rect.frame { fill: none; stroke: #000; stroke-width: 20; }",
            "    rect.mark { fill: none; stroke: #000; stroke-width: 18; }",
            "    circle.mark { fill: none; stroke: #000; stroke-width: 18; }",
            "    line.rule { stroke: #000; stroke-width: 12; }",
            "    line.write { stroke: #000; stroke-width: 12; }",
            # The inlined logo's paths carry these classes. Defined here rather than kept inside the
            # symbol so the sheet has exactly one stylesheet -- and because a symbol whose own <style>
            # was dropped renders in the default fill, which is black, silently.
            "    .brand-blue { fill: %s; }" % ACCENT,
            "    .brand-orange { fill: %s; }" % BRAND_ORANGE,
            "  </style>",
        ] + self.logo.definition()
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
    heading = writer.chrome["sheet_heading"]
    writer._text(heading, TITLE_SIZE)
    writer._text(sheet.title, SUBTITLE_SIZE)

    y = MARGIN_TOP + TITLE_SIZE
    out.extend(writer.logo.place(PAGE_W - MARGIN_X - LOGO_W, MARGIN_TOP - 300, LOGO_W))
    out.append(f'  <text id="heading" class="title" x="{MARGIN_X}" y="{y}">{_esc(heading)}</text>')
    y += SUBTITLE_SIZE + 220
    out.append(f'  <text id="{sheet.slug}-title" class="subtitle" x="{MARGIN_X}" y="{y}">{_esc(sheet.title)}</text>')
    y += 400

    table_top = y
    body: list[str] = []
    for section in sheet.sections:
        y = _emit_section(body, section, y, writer)

    # Whatever the fields leave over becomes room to write, so the page is used rather than trailing off
    # into white space. The comments band is emitted before the frame is sized so the frame encloses it.
    legend_h = 2 * (MARK + 180) + 500
    footer_h = SMALL_SIZE + 300
    spare = (PAGE_H - MARGIN_BOTTOM - legend_h - footer_h) - y
    if spare > COMMENTS_MIN:
        writer._text(writer.chrome["comments"], LABEL_SIZE)
        body.append(f'  <text class="label" x="{TEXT_X}" y="{y + ROW_PAD + LABEL_SIZE}">{_esc(writer.chrome["comments"])}</text>')
        y += spare
        body.append(f'  <line class="rule" x1="{MARGIN_X}" y1="{y}" x2="{MARGIN_X + CONTENT_W}" y2="{y}"/>')

    # The frame is emitted after the rows because its height is only known once they are laid out, and it
    # is emitted BEFORE them in document order so the band fills and rules draw over it rather than under.
    out.append(
        f'  <rect class="frame" x="{MARGIN_X}" y="{table_top}" width="{CONTENT_W}" height="{y - table_top}"/>'
    )
    out.extend(body)
    y = _emit_legend(out, y, writer)
    y = _emit_footer(out, y, writer)

    usable = PAGE_H - MARGIN_BOTTOM
    if y > usable:
        raise Overflow(
            f"{sheet.code}: content runs to {y} on a page whose usable height ends at {usable} "
            f"({y / usable:.2f} pages). A sheet must fit one page, so this needs a denser layout for "
            f"this stage -- not a second page."
        )
    return out


def _emit_legend(out: list[str], y: int, writer: SvgWriter) -> int:
    """What the two markers mean. Every published sheet carries it, and without it the shapes are decor."""
    y += 500
    for radio, key in ((True, "legend_one"), (False, "legend_many")):
        text = writer.chrome[key]
        writer._text(text, SMALL_SIZE)
        _mark(out, f"legend-{'one' if radio else 'many'}", TEXT_X, y, radio)
        out.append(f'  <text class="legend" x="{TEXT_X + MARK + MARK_GAP}" y="{y + MARK - 20}">{_esc(text)}</text>')
        y += MARK + 180
    return y


def _emit_footer(out: list[str], y: int, writer: SvgWriter) -> int:
    text = writer.chrome["footer_reference"]
    writer._text(text, SMALL_SIZE)
    for line in _fit(writer, text, SMALL_SIZE, CONTENT_W, "footer", "footer"):
        y += SMALL_SIZE + 60
        out.append(f'  <text class="legend" x="{MARGIN_X}" y="{y}">{_esc(line)}</text>')
    return y


def _emit_section(out: list[str], section: Section, y: int, writer: SvgWriter) -> int:
    # Bounded like every other run. A section title is localized metadata, centred in a band, and it was
    # the one text on the sheet that was only checked for missing glyphs -- so a longer translation would
    # have run out past the band's ends and off the page, in exactly the languages nobody proof-reads.
    writer._text(section.title, SECTION_SIZE)
    lines = _fit(writer, section.title, SECTION_SIZE, CONTENT_W - 360, section.code, "section title")
    band_h = SECTION_BAND_H + (len(lines) - 1) * (SECTION_SIZE + LINE_GAP)
    out.append(f'  <rect class="band" x="{MARGIN_X}" y="{y}" width="{CONTENT_W}" height="{band_h}"/>')
    ty = y + SECTION_BAND_H - 150
    for index, line in enumerate(lines):
        ident = f' id="{_slug(section.code)}"' if index == 0 else ""
        out.append(f'  <text{ident} class="section" x="{PAGE_W // 2}" y="{ty}">{_esc(line)}</text>')
        ty += SECTION_SIZE + LINE_GAP
    y += band_h

    for index, field in enumerate(section.fields):
        y = _emit_child(out, field, y, writer) if field.is_child else _emit_field(out, field, y, writer)
        # A rule closes a GROUP, not every field: a slot and its children are one thing on the page, and
        # ruling between them would break up the block the '- ' convention exists to express.
        following = section.fields[index + 1] if index + 1 < len(section.fields) else None
        if following is None or not following.is_child:
            out.append(f'  <line class="rule" x1="{MARGIN_X}" y1="{y}" x2="{MARGIN_X + CONTENT_W}" y2="{y}"/>')
    return y


def _emit_child(out: list[str], field: Field, y: int, writer: SvgWriter) -> int:
    """A sub-field on one line: its short label, then its choices along the same line.

    This is where the page is won. Nine fields per organism slot, each given a label row and its own
    option rows underneath, is most of two pages for one section; the same nine as compact lines under
    their slot header is a block.
    """
    label = field.short_label
    writer._text(label, OPTION_SIZE)
    y += ROW_PAD // 2

    x = TEXT_X + OPTION_INDENT
    out.append(f'  <text class="child" x="{x}" y="{y + OPTION_SIZE}">{_esc(label)}</text>')
    x += writer.face.width(label, OPTION_SIZE) + OPTION_GAP
    right = MARGIN_X + CONTENT_W - 180
    baseline = y + OPTION_SIZE

    options, radio = field.options, field.radio
    if not options and not field.write_in:
        style = writer.layout.boolean_style(field)
        if style == "yes_no":
            options, radio = [writer.chrome["boolean_yes"], writer.chrome["boolean_no"]], True
        elif style == "tick":
            _mark(out, field.code.lower().replace("_", "-"), int(x), y + 30, radio=False)
            return baseline + LINE_GAP

    if not options:
        out.append(f'  <line class="write" x1="{int(x)}" y1="{baseline + 60}" x2="{right}" y2="{baseline + 60}"/>')
        return baseline + LINE_GAP

    for option in options:
        writer._text(option, OPTION_SIZE)
    widths = [writer.face.width(option, OPTION_SIZE) for option in options]
    needed = sum(w + MARK + MARK_GAP for w in widths) + OPTION_GAP * (len(options) - 1)
    if x + needed > right:
        # The choices will not share the label's line, so fall back to the indented block a parent uses.
        return _emit_options(out, field, options, radio, baseline + LINE_GAP, writer)

    ident = field.code.lower().replace("_", "-")
    for index, option in enumerate(options):
        _mark(out, f"{ident}-{index + 1}", int(x), y + 30, radio)
        out.append(f'  <text class="option" x="{int(x + MARK + MARK_GAP)}" y="{baseline}">{_esc(option)}</text>')
        x += MARK + MARK_GAP + widths[index] + OPTION_GAP
    return baseline + LINE_GAP


def _emit_field(out: list[str], field: Field, y: int, writer: SvgWriter) -> int:
    """One field is one full-width row: bold label, then whatever it needs to be answered."""
    label = field.label + (f" ({writer.chrome['required']})" if field.compulsory else "")
    writer._text(label, LABEL_SIZE)
    style = writer.layout.boolean_style(field)

    y += ROW_PAD
    label_x = TEXT_X
    if style == "tick":
        # The tick sits on the label's own line: a criterion in a list reads as one thing to mark, not as
        # a question followed by an answer. This is the shape the published sheets use for every
        # signs-and-symptoms and laboratory-findings element.
        _mark(out, field.code.lower().replace("_", "-"), TEXT_X, y + 40, radio=False)
        label_x = TEXT_X + MARK + MARK_GAP

    available = MARGIN_X + CONTENT_W - label_x - 180
    for line in _fit(writer, label, LABEL_SIZE, available, field.code, "label"):
        out.append(f'  <text class="label" x="{label_x}" y="{y + LABEL_SIZE}">{_esc(line)}</text>')
        y += LABEL_SIZE + LINE_GAP
    y -= LINE_GAP

    options = field.options
    radio = field.radio
    if not options and style == "yes_no":
        options = [writer.chrome["boolean_yes"], writer.chrome["boolean_no"]]
        radio = True
    if options:
        y = _emit_options(out, field, options, radio, y + LINE_GAP, writer)

    return y + ROW_PAD


def _emit_options(out: list[str], field: Field, options: list[str], radio: bool, y: int, writer: SvgWriter) -> int:
    """Lay the choices along one line when they fit, and one per line when they do not.

    Fitting them horizontally is the single biggest reason the published sheets hold a page, and it is a
    measurement decision rather than a rule of thumb -- which is why the one-page requirement is reachable
    at all instead of being something to negotiate away.
    """
    ident = field.code.lower().replace("_", "-")
    for option in options:
        writer._text(option, OPTION_SIZE)

    left = TEXT_X + OPTION_INDENT
    available = MARGIN_X + CONTENT_W - left - 180
    widths = [writer.face.width(option, OPTION_SIZE) for option in options]
    inline = sum(w + MARK + MARK_GAP for w in widths) + OPTION_GAP * (len(options) - 1)

    if inline <= available:
        x = left
        for index, option in enumerate(options):
            _mark(out, f"{ident}-{index + 1}", int(x), y + 30, radio)
            out.append(f'  <text class="option" x="{int(x + MARK + MARK_GAP)}" y="{y + OPTION_SIZE}">{_esc(option)}</text>')
            x += MARK + MARK_GAP + widths[index] + OPTION_GAP
        return y + OPTION_SIZE + LINE_GAP

    for index, option in enumerate(options):
        _mark(out, f"{ident}-{index + 1}", left, y + 30, radio)
        text_x = left + MARK + MARK_GAP
        for line in _fit(writer, option, OPTION_SIZE, available - MARK - MARK_GAP, field.code, f"option {index + 1}"):
            out.append(f'  <text class="option" x="{text_x}" y="{y + OPTION_SIZE}">{_esc(line)}</text>')
            y += OPTION_SIZE + LINE_GAP
    return y


def _mark(out: list[str], ident: str, x: int, y: int, radio: bool) -> None:
    """A choose-one circle or a choose-any square, which the legend on every sheet explains."""
    if radio:
        r = MARK // 2
        out.append(f'  <circle id="{ident}" class="mark" cx="{x + r}" cy="{y + r}" r="{r}"/>')
    else:
        out.append(f'  <rect id="{ident}" class="mark" x="{x}" y="{y}" width="{MARK}" height="{MARK}"/>')


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


def _esc(text: str) -> str:
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


# ── Entry point ─────────────────────────────────────────────────────────────────────────────────────


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    repo = Path(__file__).resolve().parent.parent
    parser.add_argument("--metadata", type=Path, default=repo / "metadata" / "common")
    parser.add_argument("--fonts", type=Path, default=repo / "common" / "fonts")
    parser.add_argument("--strings", type=Path, default=repo / "common" / "sheet-strings.yaml")
    parser.add_argument("--layout", type=Path, default=repo / "common" / "sheet-layout.yaml")
    parser.add_argument("--logo", type=Path, default=repo / "common" / "img" / LOGO_FILE)
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
    rules = LayoutRules(args.layout)
    logo = Logo(args.logo)

    # Devanagari is a separate face because Noto Sans does not cover it -- see common/fonts/README.md.
    family = "NotoSansDevanagari" if args.language == "ne" else "NotoSans"
    face = Face(args.fonts / f"{family}-Regular.ttf")
    bold = Face(args.fonts / f"{family}-Bold.ttf")

    meta = Metadata(args.metadata)
    sheets = build_sheets(meta, catalogue, rules, chrome)
    if args.sheet:
        sheets = [s for s in sheets if s.code == args.sheet]
        if not sheets:
            return _fail(f"no stage with code {args.sheet}")

    args.out.mkdir(parents=True, exist_ok=True)
    suffix = f".{args.language}" if args.language else ""
    written, failures = [], []
    for sheet in sheets:
        writer = SvgWriter(face, bold, chrome, rules, logo, args.language)
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
        target.write_text(writer.sheet_svg(sheet, body), encoding="utf-8", newline="\n")
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
