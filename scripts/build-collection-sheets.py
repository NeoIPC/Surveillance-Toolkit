#!/usr/bin/env python3
"""Generate the NeoIPC data collection sheets from the canonical metadata.

The sheets are the paper equivalent of the DHIS2 program stages, so they are derived rather than drawn:
sections, field order, labels, option lists and mandatory flags all come from metadata/common/. See
docs/data-collection-sheet-generation.md for the contract this works to and for the renderer behaviour it
has to respect.

Each sheet is written twice from ONE set of placements -- an SVG, which the protocol inlines so its text
stays real text, and a Typst source, which compiles to the form a partner prints. Sharing the layout is
what stops the two drifting: they can differ in typography too fine to see, never in what is on the page.

Run it:

    python scripts/build-collection-sheets.py --out doc/protocol/img
    python scripts/build-collection-sheets.py --out doc/protocol/img --language de

    typst compile --font-path common/fonts --ignore-system-fonts --pdf-standard a-2a,ua-1 <sheet>.typ

Exit status is non-zero when a sheet cannot be laid out faithfully -- a label that will not fit its cell,
or text the embedded font has no glyph for. Both are silent defects in the machinery this replaces, and
both are only visible in a rendered PDF that, for a localized build, nobody was producing.
"""

from __future__ import annotations

import argparse
import csv
import re
import sys
from collections.abc import Callable
from dataclasses import dataclass, field as dc_field, replace
from pathlib import Path

try:
    from fontTools.ttLib import TTFont
except ImportError:  # pragma: no cover - dependency is declared in CI and in the docs
    sys.exit("fontTools is required: python -m pip install fonttools")

try:
    import uharfbuzz as hb
except ImportError:  # pragma: no cover
    sys.exit("uharfbuzz is required: python -m pip install uharfbuzz")

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

# A4 both ways round. A reporting sheet is a column of fields and is portrait; the progress chart is a
# month of columns and is landscape, which is a property of what the page holds rather than a preference.
# The size travels on the `Composer` rather than in a global, so the two can be laid out by one engine --
# it is read by the frame, the mirror, the centred titles and both serializers, and a global would have
# meant the chart quietly measuring itself against the other orientation's page.
PORTRAIT = (21000, 29700)
LANDSCAPE = (29700, 21000)
# One margin, all four sides. The comments box grows to whatever is left, so the bottom margin is exact
# rather than approximate, and an even border is then simply a matter of using one value.
#
# The floor is the printer: a consumer printer is safe from about 6.4 mm (0.25 in), so this keeps 1.6 mm
# in hand. The bleed allowance that governs commercially trimmed matter does not apply -- nothing on these
# forms runs to the edge, and a partner prints them on A4 rather than trimming them.
#
# The ceiling is height, and it is what makes the margin worth spending care on rather than rounding to a
# comfortable number. A millimetre of margin costs two millimetres of page on every form, and the sheets
# are held to one page each while their translations get longer.
#
# It costs a second time through the width, and by an amount no constant can express: a narrower page
# wraps labels that would otherwise sit on one line and pushes `best_layout` onto a different answer
# column. That is a function of the text and so of the language -- 2 mm of margin is worth 4 mm of page on
# the English primary-sepsis sheet and 7.9 mm on the Nepali one, whose column moves 20 mm.
MARGIN = 800
MARGIN_X = MARGIN_TOP = MARGIN_BOTTOM = MARGIN

# There is no input COLUMN. A field is a full-width row: the label in bold at the left, and the rest of
# the row is the space to write in -- which is what the published forms do and is most of why they fit one
# page. Splitting the row into a label column and an input column, which is the obvious first design,
# wastes the majority of the sheet and turned the primary sepsis form into three pages.
# How far content sits inside the rule to its left. Used at the table's own edge and again at the answer
# column, so a mark in a cell stands off its rule by the same amount a label stands off the frame --
# placed exactly on the column, a circle touches the line and the pair reads as one smudged glyph.
TEXT_INSET = 180
TEXT_X = MARGIN_X + TEXT_INSET
OPTION_INDENT = 700                     # options sit indented under their field
OPTION_GAP = 700                        # indent step for an option block

TITLE_SIZE, SUBTITLE_SIZE = 560, 400
SECTION_SIZE, LABEL_SIZE, OPTION_SIZE, SMALL_SIZE = 320, 300, 280, 240
# The vertical rhythm is measured against the published forms rather than chosen for comfort: they fit an
# infection sheet onto one page, so their row pitch is the budget this has to work within.
LINE_GAP = 90                           # leading between wrapped lines of one text run
# Padding ABOVE the cap height and BELOW the descender, both of which are now measured from the face, so
# this is clearance on top of the letters rather than a guess that had to cover them. It was 70 while it
# was also standing in for the descender it did not know about, which is what made rows bottom-heavy.
ROW_PAD = 45
# How far a descender must stay clear of the rule closing its row.
DESCENDER_CLEARANCE = 25
SECTION_BAND_H = 460
MARK = 260                              # a choose-one circle or choose-any square
MARK_GAP = 110                          # between a mark and its own word: deliberately tighter
OPTION_SEP = 820                        # between one option and the next, so the pairing reads
LEGEND_LEAD = 100                       # between the last footnote and the legend
LEGEND_SEP = 1200                       # between the two legend entries when they share a row
LEGEND_ROW = MARK + 60                  # a legend row: its mark, plus air below it
NOTES_TRAIL = 60                        # under the last footnote

# The answer column: ONE x per sheet where every answer that shares its label's line begins -- a space to
# write in, a Yes/No pair, an organism's resistance run. Before it, each row started its answer wherever
# its own label happened to end, so nothing lined up with anything and a slot's three resistance rows
# stepped visibly rightwards down the block.
#
# Its position is searched rather than chosen: `_best_column` lays the sheet out at each candidate and
# keeps the one that leaves the most room. A constant would have to be re-tuned for every language, which
# is exactly the failure mode of the character-counting wrapper this generator replaces.
LABEL_COL_MIN, LABEL_COL_MAX, LABEL_COL_STEP = 5000, 11000, 250
COLUMN_GAP = 300                        # clear space between the longest label and the column
# Between a criterion in the left half and the box of the one in the right half. It has to be wide enough
# to read as two columns rather than as one run-on line: at a bare text inset the last word of a long
# label finished flush against the next box, which is legible and looks like a defect.
PAIR_GUTTER = 700

# The progress chart's grid. Both are minima for a cell somebody writes a number in BY HAND, which is the
# one measurement on these forms that no font can answer: the text in a chart cell is written, not set.
# They are taken from the published chart, which has been filled in for years at 6.87 x 6.90 mm.
CHART_COL_MIN = 600                     # a day column: two digits, or a tick, written with a ballpoint
# The row keeps the published 6.9 mm rather than shrinking to what a label needs, and that buys a property
# worth more than the millimetre: it is TALLER THAN THE TEXT IN EVERY SCRIPT SHIPPED HERE, so the chart's
# height does not depend on its language, and the 0.68 mm per row that a Devanagari translation costs
# every reporting sheet costs the chart nothing. Measured at a label size of 300 rather than derived: Noto
# Sans and Noto Sans Hebrew both want 526 for a row, Noto Sans Devanagari 594. This clears the tallest of
# them by 106, and the property fails below 594 -- which is what a face for a script with deeper marks
# than Devanagari would need checking against before it is added to SCRIPT_FONTS.
CHART_ROW_MIN = 700

# Real superscript codepoints rather than a baseline shift, so a marker survives being copied out of the
# PDF and is one character to measure. The font's coverage is checked like any other text on the sheet.
SUPERSCRIPTS = "¹²³⁴⁵⁶⁷⁸⁹"

# A soft hyphen in a source string marks where its word may break; a real hyphen is what gets drawn if a
# break is taken there. The soft one never reaches the renderer.
SOFT_HYPHEN = "­"
HYPHEN = "-"

# Languages written right to left. The layout itself is direction-agnostic: it does its arithmetic in one
# direction and the finished page is mirrored, so a form for one of these reads from the right without any
# emitter needing to know. See `mirror`.
RIGHT_TO_LEFT = frozenset({"ar", "arc", "ckb", "dv", "fa", "he", "ks", "ku", "ps", "sd", "ug", "ur", "yi"})

# Languages whose script needs a face of its own, in front of the Latin one every sheet also needs. Noto
# is split by script deliberately, so this is a property of the fonts rather than a workaround: adding a
# language written in a script Noto Sans does not carry means adding its file to common/fonts and a line
# here. See common/fonts/README.md.
SCRIPT_FONTS = {"ne": "NotoSansDevanagari", "he": "NotoSansHebrew"}

# Mathematical symbols, in every language, as the LAST face in the stack -- reached only for a character
# neither the Latin face nor the language's own script face carries.
#
# It is here so that a symbol can be a symbol. A summation sign is U+2211, an operator; the Greek capital
# sigma that Noto Sans does carry is a LETTER, and substituting one for the other is wrong in exactly the
# way this project cares about -- a screen reader announces "Greek capital letter sigma", extraction
# yields a letter, and a Greek reader sees a character of their own alphabet doing an operator's job.
#
# It harmonizes rather than merely coexisting, which is measured rather than assumed: Noto Sans Math and
# Noto Sans agree exactly on cap height (714), x-height (536) and ascent (1069), so a symbol sits on the
# same optical line as the digits beside it. Its descent is deeper (423 against 293), which costs nothing
# here because a row's height is measured from its label rather than from the symbols in its cells.
MATH_FONT = "NotoSansMath"

# Families shipping a single upright face. Asking one of these for a bold or an italic gets its regular,
# which is not a stand-in for a file somebody forgot: Noto Sans Math has no weights, and a mathematical
# operator has no italic form to fall back to.
SINGLE_FACE = frozenset({MATH_FONT})

# The brand's two colours, as carried by common/img/NeoIPC-Logo.svg. An earlier accent of #2e74b5 was a
# word-processor default that merely looked similar and was sampled from nothing; see
# docs/data-collection-sheet-generation.md for the palette and how each derived tint is arrived at.
ACCENT = "#0083c1"
BRAND_ORANGE = "#ff9015"
BAND_FILL = "#cfe7f4"                   # a tint of the brand blue, light enough to print behind text

# The fields that stay in the hospital are marked in a tint of the brand's OTHER primary, so the sheet
# still uses two hues rather than three and the difference is the point rather than decoration. The
# hand-drawn master sheet used a mauve for the same job; that colour is in no brand document, and orange
# reads as "look at this" where an unrelated hue reads as an accident.
NOTRANSMIT_FILL = "#ffe4c4"
NOTRANSMIT_BAR = 60                     # the solid edge that carries the distinction into a greyscale print

# The logo is INLINED, not referenced. It is vector, so there is no raster anywhere on a sheet, and a
# sheet carries its own logo instead of depending on what happens to sit beside it -- which matters for
# the standalone print forms, which do not live in the protocol's image directory. prawn-svg renders
# <symbol> and <use>, verified rather than assumed.
#
# The logo has a minimum legible size and its proportions are not ours to alter, so the width below sits
# deliberately above that minimum and the height is derived from the artwork's own aspect rather than
# chosen. See common/img/README.md before changing it.
LOGO_FILE = "NeoIPC-Logo-Horizontal.svg"
LOGO_W = 4200                           # 42 mm


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
    # The unit word closing this field's row, where another field's value shares it -- "days" against an
    # antibiotic substance. Set by the layout, never read from the metadata.
    trailing: str | None = None

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
    # Whether the section gets a titled band. A stage's main section restates the sheet's own subtitle --
    # "Surgical Site Infection" over "Surgical Site Infection (SSI)" -- so on a sheet that IS that stage
    # the band says nothing the reader has not just read. The other bands stay: several of their fields
    # depend on them for meaning, and two rows on the surgical-site sheet are the same words under
    # different headings.
    banded: bool = True
    # The case definition printed under the band, where the question that used to distinguish this section
    # from its siblings has been folded away. Empty on every section that still has its question.
    definition: str = ""


@dataclass
class Sheet:
    code: str
    slug: str
    title: str
    sections: list[Section] = dc_field(default_factory=list)

    # What the file is called. Separate from `slug`, which stays lower case because it is an SVG id: a
    # file name is read by a person choosing which form to print, and "bsi" and "hap" are abbreviations
    # that a person expects to see in capitals.
    name: str = ""


@dataclass
class Chart:
    """The progress chart: a stage's day counts as rows, against the days of a month as columns.

    Same fields, same metadata, same page furniture as a sheet -- transposed. It is the working paper the
    totals on the master sheet are arrived at, which is why it holds no options, no marks and no mandatory
    flags: nothing on it is captured, and everything on it is counted.
    """

    slug: str
    name: str
    title: str
    days: int
    rows: list[Field] = dc_field(default_factory=list)

    # The code is the stage the rows come from, so an overflow names something a reader can act on.
    code: str = ""


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
        self.programs = self._read("programs.csv")
        self.rule_actions = self._read("programRuleActions.csv")

        self.element_by_id = {r["id"]: r for r in self.elements}
        self.option_set_by_id = {r["id"]: r for r in self.option_sets}
        # Fields the platform works out for itself, derived rather than listed: anything a program rule
        # ASSIGNs is computed from other answers, so asking for it on paper asks someone at a cot side to
        # do arithmetic the system does -- and to do it without the inputs, since the dates those rules
        # read were not on the form at all. Thirteen data elements and one attribute, found this way
        # instead of by hand, so a rule added later takes its field off the sheet with it.
        self.calculated = {
            self.element_by_id[a["dataElement"]]["code"]
            for a in self.rule_actions
            if a["programRuleActionType"] == "ASSIGN" and a.get("dataElement") in self.element_by_id
        } | {
            attribute["code"]
            for a in self.rule_actions
            if a["programRuleActionType"] == "ASSIGN"
            for attribute in self.attributes
            if attribute["id"] == a.get("trackedEntityAttribute")
        }

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

    def __init__(self, po_path: Path | None, drafts: bool = False):
        self.entries: dict[str, str] = {}
        # How many of the labels in use are a translator's unreviewed draft. Counted so a run can SAY so:
        # a form drawn from drafts looks exactly as finished as one drawn from approved translations, and
        # the difference is invisible in the artifact itself.
        self.drafted = 0
        if po_path is None:
            return
        for entry in polib.pofile(str(po_path)):
            if not entry.msgctxt or not entry.msgstr:
                continue
            # `translated()` is False for an entry marked needing-edit, which is what Weblate writes for
            # every draft. That is the right default -- a published form must not present unreviewed
            # wording as though a reviewer had passed it -- and it is the wrong behaviour for the one job
            # a reviewer actually needs, which is to SEE the draft on the page before approving it.
            if entry.fuzzy:
                if not drafts:
                    continue
                self.drafted += 1
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

    NOTICE = ("The NeoIPC logo is owned by Fondazione Penta ETS and is not covered by this repository's "
              "MIT licence. Confirm any reuse with the NeoIPC/Penta team.")

    def __init__(self, path: Path):
        source = path.read_text(encoding="utf-8")
        self.view_box = re.search(r'viewBox="([^"]+)"', source).group(1)
        _, _, w, h = (float(v) for v in self.view_box.split())
        self.aspect = w / h
        # The artwork's own <title>, which is what a screen reader is told the mark says. Read from the
        # file rather than written here: it is a wordmark, so its accessible name is the word it draws,
        # and that is a fact about the artwork. Not translated -- it is a name.
        self.name = re.search(r"<title>([^<]+)</title>", source).group(1)
        body = source.split("</style>", 1)[1].rsplit("</svg>", 1)[0]
        self.body = [line for line in body.splitlines() if line.strip()]

    def definition(self) -> list[str]:
        # The notice travels with the artwork. A generated sheet is a distributed file that contains the
        # logo, so stating the rights holder only in the repository's README would leave every copy of it
        # silent about who owns the mark on it.
        return (
            [
                f"  <!-- {self.NOTICE} -->",
                f'  <symbol id="neoipc-logo" viewBox="{self.view_box}">',
            ]
            + [f"  {line}" for line in self.body]
            + ["  </symbol>"]
        )

    def standalone(self) -> str:
        """The artwork as an SVG that carries its own stylesheet.

        The `<symbol>` above leans on the sheet's one stylesheet for its two brand fills, which is right
        where the sheet is the document. Anywhere else -- handed to an engine that reads the artwork on
        its own -- those classes resolve to nothing and every path renders in the default fill, which is
        black, silently. So the standalone form restates them.
        """
        return (
            f'<svg version="1.1" viewBox="{self.view_box}" xmlns="http://www.w3.org/2000/svg">'
            f"<style>.brand-blue{{fill:{ACCENT};}}.brand-orange{{fill:{BRAND_ORANGE};}}</style>"
            + "".join(line.strip() for line in self.body)
            + "</svg>"
        )

    def place(self, x: int, y: int, width: int) -> Emblem:
        return Emblem(x, y, width, round(width / self.aspect))


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
        self.groups: list[dict] = rules.get("groups") or []
        self.omitted: set[str] = set(rules.get("omit") or [])
        self.omitted_suffixes: tuple[str, ...] = tuple(rules.get("omit_suffixes") or ())
        self.keep_calculated: set[str] = set(rules.get("keep_calculated") or [])
        # field code -> {section code: option code}. A question whose every answer names a section of the
        # same sheet: the answer moves into the heading and the question comes off the page.
        self.folded: dict[str, dict[str, str]] = {
            entry["field"]: entry["into"] for entry in (rules.get("fold_questions") or [])
        }
        self.sheet_names: dict[str, str] = rules.get("sheet_names") or {}
        self.row_units: dict[str, str] = rules.get("row_units") or {}
        self.chart: dict = rules.get("chart") or {}

    def file_name(self, code: str, slug: str) -> str:
        """What a sheet's file is called, which is read by whoever picks a form to print.

        Title case by default, which is right for a word, and overridden where the stage's name is an
        abbreviation and a person expects capitals. Listing only the exceptions means a stage added later
        gets a sensible name without anyone remembering to add one.
        """
        return self.sheet_names.get(code) or slug.replace("-", " ").title().replace(" ", "-")

    def prints(self, field: Field) -> bool:
        """Whether this field gets a row of its own on a sheet."""
        return (field.code not in self.omitted
                and not any(field.code.endswith(f"_{s}") for s in self.omitted_suffixes))

    def continues_row(self, previous: Field | None, field: Field, chrome: dict[str, str]) -> str | None:
        """The unit word to print at the end of `previous`'s row, if `field` belongs on it.

        The relationship is stated by the codes -- `X_DAYS` is the days of `X`. The unit word is a figure
        string rather than a fragment of the child's own form name: deriving it by subtracting the
        parent's label from the child's works only where a language happens to build one out of the other,
        and fails silently everywhere else.
        """
        if previous is None:
            return None
        for suffix, key in self.row_units.items():
            if field.code == f"{previous.code}_{suffix}":
                return chrome[key]
        return None

    def group_of(self, field: Field) -> dict | None:
        """The printed group a field belongs to, matched on the suffix its code ends in."""
        for group in self.groups:
            if any(field.code.endswith(f"_{suffix}") for suffix in group["suffixes"]):
                return group
        return None

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


def load_localized(path: Path, language: str | None) -> dict[str, str]:
    """A YAML string resource, taking the localized sibling its pipeline writes when there is one.

    Two files arrive this way and neither is looked up in the metadata catalogue. The figure text is
    extracted from common/figure-strings.yaml into the documentation catalogue, and po4a writes the
    translation back as a sibling YAML; the glossary is extracted by its own generator into its own
    component and written back the same way. So a translation arrives as a file, not as a msgctxt. An
    earlier version keyed the figure text `sheetStrings/<key>`, a context that appears in no catalogue in
    this repository, so every localized run silently emitted English chrome while looking like it had
    tried.

    **The localized file is laid OVER the English one rather than replacing it**, which is the cascade
    every other string resource here uses: a level supplies only the keys it overrides. Replacing it makes
    a key that exists in the source and not yet in the sibling a crash rather than an untranslated string
    -- and since po4a writes those siblings, every localized run breaks between adding a string and
    regenerating eleven files. Falling back to the source is also the rule already applied to a metadata
    label: English on a Nepali form is legible and visibly incomplete, which a traceback is not.
    """
    yaml = YAML(typ="safe")
    with path.open(encoding="utf-8") as handle:
        strings: dict[str, str] = yaml.load(handle)
    localized = path.with_suffix(f".{language}.yaml") if language else None
    if localized and localized.exists():
        with localized.open(encoding="utf-8") as handle:
            strings.update(yaml.load(handle) or {})
    return strings


# ── Measurement ─────────────────────────────────────────────────────────────────────────────────────


class Face:
    """Advance widths and coverage from one font file the output will embed.

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
        self.cmap = self.font.getBestCmap()
        self._font: "hb.Font | None" = None
        # The name a renderer resolves the family by, read from the file rather than written here so that
        # what is asked for and what was measured cannot come apart.
        self.family = self.font["name"].getBestFamilyName()
        # How far the face reaches below the baseline, as a fraction of the em. A row sized from the font
        # size alone leaves no room for it, so a descender crosses the rule closing the row -- the 'y' of
        # "Day of life" fusing with the line under it.
        self._descent = abs(self.font["hhea"].descent) / self.units

        # Where the capitals reach above the baseline. Placing a baseline one full em below the row's top
        # leaves a gap the height of the em ABOVE the letters and nothing below them, which is why rows
        # looked bottom-heavy and their descenders still met the rule. Positioning from the cap height
        # instead balances the row and, because caps are about seven tenths of an em, costs no height.
        os2 = self.font["OS/2"]
        cap = getattr(os2, "sCapHeight", 0) or round(0.7 * self.units)
        self._cap = cap / self.units

    def descent_at(self, size: int) -> int:
        return round(self._descent * size)

    def cap_at(self, size: int) -> int:
        return round(self._cap * size)

    def has(self, ch: str) -> bool:
        return ord(ch) in self.cmap

    def shaped_width(self, text: str, language: str = "en") -> float:
        """What this face actually draws `text` as, in ems, with the script's own shaping applied.

        Summing `hmtx` advances instead is exact only where nothing shapes. It is close for Latin, where
        the difference is kerning and ligatures worth hundredths of a percent -- and it is not a
        measurement at all for Devanagari, where a combining mark carries almost no advance of its own
        while the cluster it joins has real width, and a conjunct replaces several glyphs with one. Those
        pull opposite ways: one string came out a sixth narrower than the sum and another an eighth wider,
        so there was no direction to lean in and no tolerance that would have covered both.

        HarfBuzz is what the engine shapes with -- Typst through `rustybuzz`, a port of it -- so this asks
        the same question of the same file and gets the same answer.
        """
        buffer = hb.Buffer()
        buffer.add_str(text)
        # Fills in script, language and direction from the text itself, which is what decides whether
        # Devanagari reordering or Hebrew's right-to-left run applies at all.
        buffer.guess_segment_properties()
        # Then override the language it guessed with the one the document declares. The guess reads the
        # SCRIPT and cannot know which language is being set in it, and a font may key a feature on the
        # difference -- Noto Sans Devanagari draws Nepali 7 % wider than Hindi in the same script. The
        # engine is told the language explicitly, so the ruler has to be told the same thing.
        buffer.language = language
        hb.shape(self._shaper, buffer)
        return sum(p.x_advance for p in buffer.glyph_positions) / self.units

    @property
    def _shaper(self) -> "hb.Font":
        """Built once per face and kept, because constructing it parses the whole font."""
        if self._font is None:
            self._font = hb.Font(hb.Face(self.path.read_bytes()))
        return self._font


class Typeface:
    """The faces a sheet may draw from, in the order they are preferred.

    A sheet is bilingual whenever its language is not written in Latin script, and not by accident: the
    resistance categories are established abbreviations that are deliberately not translated, so MRSA, VRE
    and 3GCR are on every sheet in every language, as is the project's own name. Noto splits by script, so
    Noto Sans Devanagari carries no Latin at all and a Nepali sheet drawn from it alone is every Latin
    character missing.

    This is the opposite of the fallback the one-family rule bars. That rule is against a name resolving
    to whatever a machine happens to have installed, silently and differently per machine; this is a list
    of this repository's own files, in a stated order, named in the output so both renderers resolve the
    same two.
    """

    def __init__(self, faces: list[Face], language: str = "en"):
        self.faces = faces
        # The language the OUTPUT declares, passed to the shaper because a font may apply a feature keyed
        # on it. Noto Sans Devanagari does: `ड्रेनबाट पिप बग्नु` draws 7 % wider under `ne` than under `en`
        # -- and identically under `hi`, which is the same script, so this is a language system in the
        # font rather than anything to do with Devanagari. Guessing it from the text cannot find that, so
        # a measurement taken without it disagrees with the engine exactly where such a feature applies.
        self.language = language
        # Latin is FIRST, in every language, and the order is not arbitrary: the two faces overlap on 60
        # codepoints -- every digit and every punctuation mark. With the script's face in front, a Nepali
        # sheet would draw its digits, brackets and slashes from the Devanagari design and the Latin
        # letters beside them from another, on the same line.
        self.primary = faces[0]
        self.families = [face.family for face in faces]
        self.name = " + ".join(face.path.name for face in faces)

    def cap_at(self, size: int) -> int:
        """Where the baseline sits below a row's top -- taken from the Latin face in every language.

        It decides position rather than height, so a shared value is what makes a row of Latin sit the
        same way on a Nepali sheet as on an English one.
        """
        return self.primary.cap_at(size)

    def descent_at(self, size: int, text: str) -> int:
        """The deepest reach below the baseline among the faces that will actually draw this text."""
        return max(face.descent_at(size) for face in self._drawing(text))

    def pad_at(self, size: int, text: str) -> int:
        """Equal space above the capitals and below the baseline, sized to what the run is drawn in.

        Balancing the full ink box instead -- caps above the baseline, descender below -- is correct
        typographically and looks wrong here, because most labels on a form have no descender at all. The
        reserved space below then reads as emptiness and the row looks top-heavy. So the padding is
        symmetric about the baseline, and the descender clears INTO the lower half rather than being
        added beneath it.

        Per text rather than per sheet, because the faces disagree by a third: Noto Sans reaches 293
        thousandths of the em below the baseline and Noto Sans Devanagari 408, which the script needs for
        its below-base marks. Charging every row the deeper figure costs 0.68 mm a row -- 17 mm down a
        sheet of fifty, enough on its own to push one off its page -- while charging every row the
        shallower one puts a Devanagari mark through the rule that closes it. So each row is padded for
        the text it actually holds, and a sheet in a language nobody has translated yet lays out exactly
        like the English one, because it is drawing exactly the same faces.
        """
        return max(ROW_PAD, self.descent_at(size, text) + DESCENDER_CLEARANCE)

    def _drawing(self, text: str) -> list[Face]:
        """The faces this text is drawn from -- the first one holding each character, never all of them.

        The distinction matters because the faces overlap: asking which faces CONTAIN some character of
        the text returns the Devanagari one for any label carrying a digit, and a page of Latin would then
        be padded for a script it never draws.
        """
        used: list[Face] = []
        for ch in text:
            if ch.isspace():
                continue
            face = self._face_for(ch)
            if face not in used:
                used.append(face)
        return used or [self.primary]

    def _face_for(self, ch: str) -> Face:
        """The first face in the stack holding the character, which is the one that will draw it.

        Both renderers resolve a family list this way, so measuring in a different order from the one
        they draw in would be measuring a different sheet.
        """
        return next((face for face in self.faces if face.has(ch)), self.primary)

    def missing(self, text: str) -> set[str]:
        """Characters no face in the stack can draw. A space is nobody's glyph and never missing."""
        return {ch for ch in text
                if not ch.isspace() and not any(face.has(ch) for face in self.faces)}

    def width(self, text: str, size: int) -> float:
        """Shaped, one run per face, which is how a renderer draws it too.

        A renderer shapes each run of characters it resolves to one face and lays the runs side by side,
        so kerning across a face boundary is not applied by anyone -- and measuring the whole string
        through a single face would measure something nobody draws.
        """
        return sum(face.shaped_width(run, self.language) for face, run in self._runs(text)) * size

    def _runs(self, text: str) -> list[tuple[Face, str]]:
        """Split into maximal runs sharing one face, in order."""
        runs: list[tuple[Face, str]] = []
        for ch in text.replace(SOFT_HYPHEN, ""):
            face = self._face_for(ch)
            if runs and runs[-1][0] is face:
                runs[-1] = (face, runs[-1][1] + ch)
            else:
                runs.append((face, ch))
        return runs

    def wrap(self, text: str, size: int, max_width: int) -> list[str]:
        """Greedy wrap on whitespace, and inside a word wherever the translator allowed one.

        A soft hyphen (U+00AD) in the source marks a place the word may break. It is the translator's
        call because it is a fact about their language rather than about this layout -- where
        `Gestations{shy}alter` may split is something they know and a pattern file only guesses at. No
        dependency, no per-language dictionary, and no licence to clear.

        The renderer never sees one. Every soft hyphen is stripped, and a REAL hyphen is written only at
        the point a break actually happens, which is possible because this emits explicit lines rather
        than asking the renderer to wrap. So it does not matter whether prawn-svg honours U+00AD -- a
        question that would otherwise decide whether the text came out with stray hyphens in it.

        A word still too wide with every break taken is neither broken nor silently emitted: the caller
        fails on it, exactly as before. Hyphenation relaxes the fit rule; it does not remove it.
        """
        lines: list[str] = []
        current = ""
        # Split on the ASCII space ONLY. Python's argument-less split() treats U+00A0 as whitespace, so
        # it breaks at exactly the joins a non-breaking space exists to prevent -- an operator from its
        # number, a value from its unit. Empty pieces from runs of spaces are dropped here instead.
        for word in (w for w in text.split(" ") if w):
            candidate = f"{current} {word}".strip()
            if current and self.width(candidate, size) > max_width:
                lines.append(current.replace(SOFT_HYPHEN, ""))
                current = word
            else:
                current = candidate

            while self.width(current, size) > max_width and SOFT_HYPHEN in current:
                found = self._break_at_soft_hyphen(current, size, max_width)
                if found is None:
                    break
                head, position = found
                lines.append(head)
                # Slice the ORIGINAL string by the break's own position. Slicing by the head's length
                # would be short by however many soft hyphens the head absorbed, which silently
                # re-included characters already printed.
                current = current[position + 1:]

        if current:
            lines.append(current.replace(SOFT_HYPHEN, ""))
        return lines or [""]

    def _break_at_soft_hyphen(self, text: str, size: int, max_width: int) -> tuple[str, int] | None:
        """The longest prefix ending at a permitted break that still fits once its hyphen is added.

        Returns the text to draw AND the break's index in the original string, because the two differ by
        however many soft hyphens the prefix contained.
        """
        best = None
        for position, ch in enumerate(text):
            if ch != SOFT_HYPHEN:
                continue
            head = text[:position].replace(SOFT_HYPHEN, "") + HYPHEN
            if self.width(head, size) <= max_width:
                best = (head, position)
            else:
                break
        return best


class Overflow(Exception):
    """Content that cannot be laid out faithfully. The build stops.

    Carries what it had placed by the time it gave up, so `--allow-overflow` can write the sheet for
    review. Nothing else reads it: a normal run discards it along with the sheet.
    """

    def __init__(self, message: str, body: list[Shape] | None = None):
        super().__init__(message)
        self.body = body


# ── Sheet assembly ──────────────────────────────────────────────────────────────────────────────────


def build_stage_sheets(meta: Metadata, catalogue: Catalogue, rules: LayoutRules) -> list[Sheet]:
    """One sheet per program stage, in the stages' own sort order, before any composite claims it.

    Kept separate from `build_sheets` because the progress chart reads it too: the chart's rows are a
    stage's day counts in the order that stage is printed, and after the composites have run the stage it
    needs is no longer a sheet of its own. Deriving the chart from the same walk is what makes a row on it
    and a row on the master sheet the same field rather than two lists that agree today.
    """
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
            name=rules.file_name(stage["code"], _slug(stage["code"])),
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
            # The event's own date, at the head of the stage's first section. It is not a data element --
            # in DHIS2 it is the event date -- so nothing in dataElements.csv carries it and the sheets
            # had no date on them at all, while asking for two values computed FROM it. Its label is the
            # stage's `executionDateLabel`, already translatable in the metadata catalogue.
            #
            # The enrolment block deliberately gets none: the program's enrolment date is labelled
            # "Admission date" exactly as the admission stage's event date is, and a form that asks for
            # the same date twice reads as two questions.
            if not sheet.sections:
                model.fields.append(_event_date_field(catalogue, stage))
                # Only on a sheet that is this one stage. Folded into a composite the same section sits
                # under a title that is not its own, and its band is the only thing naming it.
                model.banded = not section["code"].endswith("_SECT_MAIN")

            # The section's dataElements column is a space-separated UID list and IS the authored order
            # of the fields within it; programStageDataElements.sortOrder orders the stage as a whole and
            # would interleave sections if used here.
            for uid in (section["dataElements"] or "").split():
                element = meta.element_by_id.get(uid)
                if element is None:
                    raise LookupError(f"section {section['code']} references unknown element {uid}")
                if element["code"] in meta.calculated and element["code"] not in rules.keep_calculated:
                    continue
                if element["code"] in rules.folded:
                    continue
                link = links.get(uid, {})
                model.fields.append(_field_of(meta, catalogue, element, link))
            _fold_definition(model, rules)
            sheet.sections.append(model)
        if sheet.sections:
            sheets.append(sheet)

    return sheets


def build_sheets(meta: Metadata, catalogue: Catalogue, rules: LayoutRules,
                 chrome: dict[str, str]) -> list[Sheet]:
    """The sheets as printed: the stages, with those a composite claims folded into it."""
    return _apply_composites(build_stage_sheets(meta, catalogue, rules), meta, catalogue, rules, chrome)


def build_chart(sheets: list[Sheet], rules: LayoutRules, chrome: dict[str, str]) -> Chart | None:
    """The progress chart's rows: one stage's day counts, in the order that stage is printed.

    Derived from the sheets rather than listed, so a day count added to the stage appears on the chart
    with it. That matters more here than anywhere else on these forms, because a MISSING row on a grid
    looks exactly like a grid -- there is no gap, no stray label and no failed measurement to notice.
    """
    spec = rules.chart
    if not spec:
        return None
    stage = next((s for s in sheets if s.code == spec["stage"]), None)
    if stage is None:
        raise LookupError(f"chart names stage {spec['stage']}, which has no sheet to take its rows from")
    suffix = f"_{spec['suffix']}"
    slug = "patient-progress-chart"
    chart = Chart(
        slug=slug,
        # Named by the same rule as a sheet, so the family's file names come from one place. It keeps the
        # name the published chart already has, which is what the protocol's figure refers to.
        name=rules.file_name(stage.code, slug),
        title=chrome["chart_title"],
        days=spec["days"],
        code=stage.code,
    )
    chart.rows = [field for section in stage.sections for field in section.fields
                  if field.code.endswith(suffix)]
    if not chart.rows:
        raise LookupError(f"no field of {stage.code} ends in {suffix}, so the chart would have no rows")
    return chart


def _apply_composites(
    sheets: list[Sheet], meta: Metadata, catalogue: Catalogue, rules: LayoutRules, chrome: dict[str, str]
) -> list[Sheet]:
    """Fold the stages a composite claims into one sheet, and drop them as standalone sheets."""
    if not rules.composites:
        return sheets
    by_code = {s.code: s for s in sheets}
    composed: list[Sheet] = []
    for name, spec in rules.composites.items():
        sheet = Sheet(
            code=name.upper(),
            slug=spec["slug"],
            title=chrome[spec["title_key"]],
            name=rules.file_name(name.upper(), spec["slug"]),
        )
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


def _fold_definition(section: Section, rules: LayoutRules) -> None:
    """Print a section's own description, where the question that used to distinguish it has been folded.

    The section keeps its short name and gains the definition beneath it, taken verbatim from the metadata
    rather than assembled. Two earlier attempts were worse and both are worth remembering.

    Renaming the section to carry the case definition would have put a THIRD statement of it in the
    metadata, and a lossy one: the descriptions here carry the 30-day and 90-day windows that the
    question's options omit, so a name built from an option would promote the shorter version to a heading
    and leave the complete one unused.

    Composing the heading from the section's name plus the option's text -- both already translated, so
    apparently free -- was worse still. The option is a sentence fragment written to complete "Infection
    involves ...", and a language whose verb governs the case of what follows leaves it stranded when the
    verb is removed. The translator would never see it either: they translate one string, shown as an
    option under a question, with nothing to tell them it is also half a heading.
    """
    if section.code in {code for mapping in rules.folded.values() for code in mapping}:
        section.definition = section.description.strip()


def _event_date_field(catalogue: Catalogue, stage: dict) -> Field:
    """The date the event happened, which every sheet needs and none of them carried.

    DHIS2 keeps it on the event rather than in a data element, so it appears in no CSV of fields and was
    invisible to a generator reading only those. It is the one answer the rest of the stage is anchored
    to -- the day-of-life and days-since-admission figures are computed from it -- so a form without it
    cannot be transcribed.
    """
    return Field(
        code=f"{stage['code']}_EVENT_DATE",
        label=catalogue.get(
            f"programStages/{stage['code']}/EXECUTION_DATE_LABEL", stage["executionDateLabel"]
        ),
        value_type="DATE",
        compulsory=True,
    )


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


# ── What a sheet is made of ─────────────────────────────────────────────────────────────────────────
#
# The layout produces PLACEMENTS rather than markup, and each output serializes them. That split is what
# keeps the two renderings from drifting: the screen figure and the printed form are one set of decisions
# written out twice, rather than two layouts somebody has to keep in step.


@dataclass(frozen=True)
class Style:
    """A named way of setting text: what the SVG carries as a CSS class and Typst as a `let` binding.

    It names the FACE as well as the size, and everything measures through it. Nothing here takes a
    weight or a slant as a separate argument, because that separation is what let a run be measured in
    one file and drawn in another -- twice, once for bold and once for italic, each time producing a
    sheet whose fit had been checked against text nobody was going to see.
    """

    size: int
    bold: bool = False
    italic: bool = False
    colour: str = "#000"
    centred: bool = False

    @property
    def face(self) -> tuple[bool, bool]:
        return self.bold, self.italic


STYLES: dict[str, Style] = {
    "title": Style(TITLE_SIZE, colour=ACCENT),
    "subtitle": Style(SUBTITLE_SIZE, colour=ACCENT),
    "section": Style(SECTION_SIZE, centred=True),
    "label": Style(LABEL_SIZE, bold=True),
    "option": Style(OPTION_SIZE),
    "child": Style(OPTION_SIZE, bold=True),
    # The small print -- the legend, the footnotes, the footer, the note on the patient block and the
    # case definitions. Italic sets it apart from the questions without another size or another colour.
    "note": Style(SMALL_SIZE, italic=True),
    # A day number over the progress chart's grid, and the marker over its total column. Centred on the
    # column rather than on the page -- `centred` means "anchored at its own x", which the page-centred
    # section titles reach by being placed at the page's middle. Upright, because a column heading is not
    # small print: it is read while writing in the cell beneath it.
    "day": Style(SMALL_SIZE, centred=True),
}


@dataclass(frozen=True)
class Ink:
    """How a shape is filled and stroked, in one table for lines, boxes and marks alike.

    Every filled block is bounded. An area of colour with no edge has nothing to sit against, so it reads
    as a stain on the page rather than as a region of the table -- and on a ruled form, where every other
    block IS bounded, the unbounded one looks like a printing fault.

    Three rule weights, and the SPREAD between them is what makes the grid readable rather than the
    absolute values: the frame at 0.20 mm, a row or block boundary at 0.16, and a row inside a block at
    0.10. A first attempt used 0.06 mm for the inner rule, which is sub-pixel on screen and marginal on
    paper -- emitted on every sheet and visible on none, which looks exactly like not being emitted.
    """

    fill: str | None = None
    stroke: int = 0


INKS: dict[str, Ink] = {
    "band": Ink(BAND_FILL, 12),
    "notransmit": Ink(NOTRANSMIT_FILL, 12),
    # A second, redundant signal: these sheets are printed, frequently in greyscale, where the tint above
    # collapses to a shade barely distinguishable from the section bands. A solid bar survives that, and
    # survives colour-blindness, which a hue on its own does not.
    "notransmit-edge": Ink("#000"),
    "frame": Ink(stroke=20),
    "mark": Ink(stroke=18),
    "rule": Ink(stroke=16),
    # Between two rows of one slot. Every row is a cell of a ruled table, so every row is closed -- but a
    # slot and the fields hanging off it are still one thing, and ruling them all alike dissolves that.
    "hair": Ink(stroke=10),
    # The answer column's own stroke, drawn per row rather than as one full-height line: the rows that
    # span the sheet have no cell for it to bound, and a line through their text would be a defect rather
    # than a grid. Consecutive bounded rows abut, so the strokes read as one column where there is one.
    "column": Ink(stroke=16),
}


@dataclass
class Text:
    """A run on one line, positioned by its BASELINE.

    The baseline rather than a box top, because that is what every measurement here is relative to: the
    cap height above it, the descender below it, and the optical centre a mark sits on. Both renderings
    can express it -- it is what SVG's `y` means, and what Typst's becomes once the text box is set to
    have no height at all.
    """

    x: int
    y: int
    text: str
    style: str
    ident: str | None = None


@dataclass
class Line:
    x1: int
    y1: int
    x2: int
    y2: int
    kind: str


@dataclass
class Box:
    x: int
    y: int
    width: int
    height: int
    kind: str
    ident: str | None = None


@dataclass
class Dot:
    """A choose-one circle, positioned by its centre."""

    cx: int
    cy: int
    r: int
    ident: str | None = None


@dataclass
class Emblem:
    """Where the logo goes. The artwork itself is carried once per document by `Logo`."""

    x: int
    y: int
    width: int
    height: int


Shape = Text | Line | Box | Dot | Emblem


def mirror(shapes: list[Shape], page_w: int) -> list[Shape]:
    """Reflect a finished page about its vertical centre, for a language written right to left.

    **Direction is not a concern of the layout at all.** Everything above measures and places in one
    direction -- labels at the left, answers to their right, a mark before the word it belongs to -- and
    this turns the finished result round. Doing it in one pass over the placements, rather than teaching
    each emitter about direction, is what makes that possible: there is no second set of positioning rules
    to keep in step, and no emitter that can be right for one direction and quietly wrong for the other.

    Everything measured from a left edge mirrors by taking its own width off. A text run is the exception
    and does not need one: its x is an ANCHOR rather than an edge, so the mirrored anchor is simply the
    run's other end, and the serializers anchor text to the right on a mirrored page.

    What this does NOT do is reorder glyphs within a run. That is the Unicode Bidirectional Algorithm's
    job and belongs to whatever draws the text -- Typst applies it against the base direction the emitted
    document declares, and a browser applies it to the SVG. See docs/data-collection-sheet-generation.md
    for which consumers can and cannot.
    """
    return [_mirrored(shape, page_w) for shape in shapes]


def _mirrored(shape: Shape, page_w: int) -> Shape:
    match shape:
        case Text():
            return replace(shape, x=page_w - shape.x)
        case Line():
            return replace(shape, x1=page_w - shape.x1, x2=page_w - shape.x2)
        case Box() | Emblem():
            return replace(shape, x=page_w - shape.x - shape.width)
        case Dot():
            return replace(shape, cx=page_w - shape.cx)


# ── Layout ──────────────────────────────────────────────────────────────────────────────────────────


class Composer:
    """Measures the text and places it, in the minimal style the repository uses for its figures.

    Semantic ids from the metadata code, presentation in named styles, integer coordinates on one grid,
    deterministic order, no transforms and no per-element styling. The property that makes the result
    reviewable is that regenerating with unchanged metadata produces a byte-identical file.
    """

    def __init__(self, faces: dict[tuple[bool, bool], Typeface], chrome: dict[str, str],
                 glossary: dict[str, str], layout: LayoutRules, logo: Logo,
                 language: str | None, label_width: int = LABEL_COL_MAX,
                 page: tuple[int, int] = PORTRAIT):
        self.faces, self.chrome, self.glossary, self.layout = faces, chrome, glossary, layout
        self.page_w, self.page_h = page
        # The upright regular face, which is what the vertical rhythm is taken from. That is sound only
        # because the four faces agree on the two metrics it uses, so it is asserted rather than assumed:
        # a family whose italic sat deeper would need the rhythm to follow the style like the width does.
        self.face = faces[False, False]
        for other in faces.values():
            if (other.primary.descent_at(1000), other.primary.cap_at(1000)) != (
                    self.face.primary.descent_at(1000), self.face.primary.cap_at(1000)):
                raise ValueError(
                    f"{other.name} does not share the vertical metrics of {self.face.name}; the row "
                    "rhythm is taken from one face and would be wrong for text set in this one."
                )
        self.logo, self.language = logo, language
        # What the finished document DECLARES it is written in -- the SVG's xml:lang and the PDF's /Lang.
        # Not cosmetic: a screen reader picks its pronunciation rules from it, so a Devanagari page
        # declaring English is read aloud wrongly, and PDF/UA requires the declaration to be right rather
        # than merely present. The untranslated source really is English, so that is the honest default.
        self.language_tag = language or "en"
        self.rtl = language in RIGHT_TO_LEFT
        self.missing: dict[str, set[str]] = {}
        self.footnotes: list[str] = []
        # Where the answers begin. One value for the whole sheet, so a mark on the first row and a mark on
        # the last sit on the same vertical.
        self.answer_x = MARGIN_X + label_width
        # Where content inside the answer cell begins, inset from the column rule exactly as a label is
        # inset from the table's own frame.
        self.answer_text_x = self.answer_x + TEXT_INSET
        # How much page is left once everything is placed -- the size of the comments box, and the only
        # honest measure of how much longer a translation may be before the sheet stops fitting.
        self.spare = 0
        # Ways this form is unfit that are neither a fit failure nor a missing glyph -- reported like
        # both, so a defective form fails the build rather than being written and looking finished.
        self.problems: list[str] = []

    @property
    def content_w(self) -> int:
        """The width between the margins: what the table spans and what every full-width run wraps to."""
        return self.page_w - 2 * MARGIN_X

    def fill(self, pattern: str, terms: dict[str, str]) -> str:
        """Resolve a label pattern's `{placeholder}`s from the glossary.

        Not `str.format`, which would also read `{}` and `{0}` and would raise on a stray brace a
        translator left behind; this replaces exactly the placeholders the layout declared and then
        checks what is left.

        Both failures are the build's rather than the reader's. A placeholder the pattern never used
        means a term silently vanished -- on this row, a resistance category the form stops offering
        while the data model still keeps it -- and one left unresolved means a translator invented a
        name, which would print a brace on a form somebody fills in with a pen.
        """
        out = pattern
        for placeholder, term in terms.items():
            out = out.replace(f"{{{placeholder}}}", self.glossary[term])
        if missing := [p for p in terms if f"{{{p}}}" not in pattern]:
            raise ValueError(f"label pattern {pattern!r} never uses {', '.join(sorted(missing))}, so the "
                             f"term{'s' if len(missing) > 1 else ''} it stands for would not be printed")
        if left := re.findall(r"\{[^{}]*\}", out):
            raise ValueError(f"label pattern {pattern!r} uses {', '.join(left)}, which the layout does "
                             f"not map to a glossary term")
        return out

    def compose(self, key: str, **values: str) -> str:
        """Resolve a chrome string's `{placeholder}`s from values the layout supplies.

        The sibling of `fill`, which resolves them from the glossary. Same strictness for the same reason:
        a placeholder the pattern never uses means something the reader was meant to be told is silently
        absent, and one left unresolved prints a brace at whoever is listening.
        """
        out = self.chrome[key]
        for placeholder, value in values.items():
            out = out.replace(f"{{{placeholder}}}", value)
        if missing := [p for p in values if f"{{{p}}}" not in self.chrome[key]]:
            raise ValueError(f"{key} never uses {', '.join(sorted(missing))}, so what it stands for "
                             f"would not be said at all")
        if left := re.findall(r"\{[^{}]*\}", out):
            raise ValueError(f"{key} uses {', '.join(left)}, which the layout does not supply")
        return out

    def join(self, items: list[str]) -> str:
        """Run a generated list together with the separator this language uses."""
        return self.chrome["list_separator"].join(items)

    def footnote(self, key: str) -> str:
        """Register a footnote and return the superscript marker that refers to it.

        Numbered in the order they are first needed, so a sheet reads top to bottom, and deduplicated:
        one group repeated across three organism slots is one note, not three identical ones.
        """
        if key not in self.footnotes:
            self.footnotes.append(key)
        return SUPERSCRIPTS[self.footnotes.index(key)]

    def face_of(self, style: str) -> Typeface:
        """The faces a run in this style is actually drawn from.

        Keyed by the STYLE rather than by a weight or a slant passed alongside it, because that is what
        went wrong twice. Labels are bold and bold is wider, and measuring them upright under-measured
        every one: it decided where the answer column could sit, whether a label wrapped, whether two
        criteria shared a row, and whether the sheet was declared to fit -- letting a fitted label overrun
        the column it had been fitted against by little enough to read as a rendering artifact. The small
        print then repeated it in the other direction, measured upright and drawn slanted.
        """
        return self.faces[STYLES[style].face]

    def _text(self, text: str, style: str) -> None:
        face = self.face_of(style)
        absent = face.missing(text)
        if absent:
            self.missing.setdefault(face.name, set()).update(absent)

    def measured(self, run: Text) -> float:
        """The width this generator makes of a placed run, in grid units.

        What the print emitter asserts against: the engine re-measures the same run with its own shaper
        and refuses to draw it wider than this.
        """
        return self.face_of(run.style).width(run.text, STYLES[run.style].size)


def title_of(form: Sheet | Chart, composer: Composer) -> str:
    """What the document is called -- the same words in the SVG's <title> and the PDF's metadata."""
    return f"{composer.chrome['sheet_heading']} — {form.title}"


def description_of(form: Sheet | Chart, composer: Composer) -> str:
    """What a reader who cannot see the page is told it holds.

    A sheet is described by its sections and a chart by its rows, because those are what each one's shape
    actually is. Naming the chart's rows matters more than it looks: they are the whole content of a grid,
    and a grid described only as a grid tells a screen-reader user nothing at all.

    Every word of it is translated -- the sentence from this repository's figure strings, the names from
    the metadata catalogue. Assembled in the generator instead, it would be an English frame around
    translated content, which is what a screen reader would then read out in a language nobody chose.
    """
    if isinstance(form, Chart):
        return composer.compose("chart_description", title=form.title,
                                rows=composer.join([row.label for row in form.rows]))
    return composer.compose("sheet_description", title=form.title,
                            sections=composer.join([s.title for s in form.sections]))


def keywords_of(form: Sheet | Chart, composer: Composer) -> list[str]:
    """What a metadata-only catalogue indexes the published form by.

    **Deliberately small, and every term is one the page itself carries.** Keywords are worth far less
    than they look. Google has ignored the field since 2009 and ranks a PDF on its title and its text;
    Google Scholar reads the landing page's `citation_*` tags rather than the file; and Bing uses the
    field only as a SPAM signal, where the trigger is keywords that do not appear in the document. So a
    generous list of resonant phrases is the one construction that can actively hurt, and full-text search
    already finds anything that is genuinely on the page.

    What is left is a real but narrow consumer -- a document system or repository that indexes metadata
    without indexing text. These serve it, cost nothing, and cannot misrepresent the form: the words are
    the form's own name and the module it belongs to, both already translated in the metadata catalogue
    and both printed at the top of the page. No new string to translate, and no separator to join with,
    because the engine takes a list.
    """
    return [form.title, composer.chrome["sheet_heading"]]


def layout_sheet(sheet: Sheet, composer: Composer) -> list[Shape]:
    """Flow the sheet's sections down the page, returning what to draw and where.

    **A sheet is one page.** That is a requirement of the artifact, not a limitation of this emitter: it
    is filled in at a cot side, and a form that runs onto a second sheet loses half of itself. So there
    is no pagination to fall back on, and a sheet that does not fit is a layout that has to get denser --
    which is a decision about the form, taken deliberately, rather than something a generator may resolve
    on its own by spilling onto another page.
    """
    out: list[Shape] = []
    y = _open_page(out, sheet.title, sheet.slug, composer)

    table_top = y
    body: list[Shape] = []
    y = _emit_patient_block(body, y, composer)
    for section in sheet.sections:
        y = _emit_section(body, section, y, composer)

    return _close_page(out, body, table_top, y, sheet.code, composer)


def layout_chart(chart: Chart, composer: Composer) -> list[Shape]:
    """Flow the chart: the shared head, the patient block, the filing row, then the grid.

    Same page furniture as a sheet and the same one-page rule; what differs is the body, which is a table
    of rows against days rather than a run of sections. The two share `_open_page` and `_close_page`
    literally rather than by resemblance, so the family cannot drift apart at the edges.
    """
    out: list[Shape] = []
    y = _open_page(out, chart.title, chart.slug, composer)

    table_top = y
    body: list[Shape] = []
    y = _emit_patient_block(body, y, composer)
    y = _emit_filing_row(body, y, composer)
    y = _emit_grid(body, chart, y, composer)

    return _close_page(out, body, table_top, y, chart.code, composer)


def _emit_filing_row(out: list[Shape], y: int, composer: Composer) -> int:
    """Which month this chart covers, and which of that month's charts it is.

    Paper-only, like the two identifying fields above -- the platform stores a stay, not a stack of sheets,
    so nothing in the metadata names either. They are NOT under the block that must not be transmitted:
    that tint means "identifies the patient", and a month and a sheet number identify neither. Reusing it
    here would have made the one signal on these forms that carries a data-protection rule mean two things.
    """
    labels = [composer.chrome["chart_month_year"], composer.chrome["chart_number"]]
    half = composer.content_w // 2
    top = y
    height = max(composer.face.pad_at(LABEL_SIZE, text) * 2 + LABEL_SIZE for text in labels)
    for label, left in zip(labels, (MARGIN_X, MARGIN_X + half)):
        composer._text(label, "label")
        answer = left + (composer.answer_x - MARGIN_X)
        for line in _fit(composer, label, "label", answer - COLUMN_GAP - (left + TEXT_INSET),
                         "chart_filing", "label"):
            out.append(Text(left + TEXT_INSET,
                            y + composer.face.pad_at(LABEL_SIZE, label) + composer.face.cap_at(LABEL_SIZE),
                            line, "label"))
        _column(out, top, top + height, composer, answer)
    # The divider between the two cells, at the same weight as the column that opens each of them. Without
    # it the row reads as ONE field with a stray word in the middle of the space to write in: the first
    # cell's writing area runs straight into the second cell's label, and nothing says where one question
    # ends and the next begins. It is the same stroke a paired row on a sheet uses for the same reason.
    out.append(Line(MARGIN_X + half, top, MARGIN_X + half, top + height, "column"))
    out.append(Line(MARGIN_X, top + height, MARGIN_X + composer.content_w, top + height, "rule"))
    return top + height


def _emit_grid(out: list[Shape], chart: Chart, y: int, composer: Composer) -> int:
    """The chart proper: a row per day count, a column per day, and a column for the total.

    **The column width is measured, not chosen, and it fails on WIDTH** -- the only form in this family
    that can. A sheet runs out of page at the bottom, so its failure is a height; here the labels and the
    thirty-two columns compete for one line, and a language whose labels are longer takes the space out of
    the cells somebody writes in. Below `CHART_COL_MIN` a cell is too small to write a number in, which no
    font metric can tell us and which would otherwise ship as a grid that merely looks tight.
    """
    labels = [row.label for row in chart.rows] + [composer.chrome["chart_days"]]
    for text in labels:
        composer._text(text, "label")
    # The label column has to hold the widest of them whole: these are field names, and wrapping one would
    # cost every row the extra line, on a page whose rows are already at a hand-written minimum.
    needed = max(composer.face_of("label").width(text, LABEL_SIZE) for text in labels)
    wanted = int(needed) + 2 * TEXT_INSET
    columns = chart.days + 1
    # Integers on the one grid: the cell width is floored, and the label column absorbs what that leaves,
    # so every column boundary lands on a whole unit instead of accumulating a rounding error across
    # thirty-two of them.
    col_w = (composer.content_w - wanted) // columns
    if col_w < CHART_COL_MIN:
        raise Overflow(
            f"{chart.code}: the row labels need {wanted} of the {composer.content_w} across the page, "
            f"leaving {col_w} for each of the {columns} columns where {CHART_COL_MIN} is the least a "
            f"person can write a day count in. The labels are what has to give, not the cells.",
            out,
        )
    grid_x = MARGIN_X + composer.content_w - columns * col_w

    head = composer.chrome["chart_days"]
    total = composer.chrome["chart_total"]
    composer._text(head, "label")
    composer._text(total, "day")
    for day in range(1, chart.days + 1):
        composer._text(str(day), "day")

    # The heading row, then one row per field. Both are measured the same way and both take the written
    # minimum, so the grid has one pitch from top to bottom.
    def row_height(text: str, style: str) -> int:
        size = STYLES[style].size
        return max(CHART_ROW_MIN, 2 * composer.face.pad_at(size, text) + size)

    top = y
    height = row_height(head, "label")
    baseline = y + composer.face.pad_at(LABEL_SIZE, head) + composer.face.cap_at(LABEL_SIZE)
    out.append(Text(MARGIN_X + TEXT_INSET, baseline, head, "label"))
    for index, text in enumerate([str(d) for d in range(1, chart.days + 1)] + [total]):
        # Centred in its own cell. `mid` in the print emitter and `text-anchor: middle` in the SVG both
        # anchor a run at its x, so the same placement centres a day number over its column and a section
        # title over the page.
        out.append(Text(grid_x + index * col_w + col_w // 2, baseline, text, "day"))
    y += height
    out.append(Line(MARGIN_X, y, MARGIN_X + composer.content_w, y, "rule"))

    for row in chart.rows:
        height = row_height(row.label, "label")
        baseline = y + composer.face.pad_at(LABEL_SIZE, row.label) + composer.face.cap_at(LABEL_SIZE)
        out.append(Text(MARGIN_X + TEXT_INSET, baseline, row.label, "label", _ident(row)))
        y += height
        out.append(Line(MARGIN_X, y, MARGIN_X + composer.content_w, y, "rule"))

    # The verticals last, so they run the whole table in one stroke each rather than per row. The label
    # column and the total column are bounded at the weight the sheets bound an answer cell with; the days
    # between them are ruled at the lighter one, so thirty-one boundaries read as one field of cells
    # instead of as thirty-one separate columns.
    for index in range(columns + 1):
        x = grid_x + index * col_w
        kind = "column" if index in (0, columns - 1, columns) else "hair"
        out.append(Line(x, top, x, y, kind))
    return y


def _open_page(out: list[Shape], subtitle: str, slug: str, composer: Composer) -> int:
    """The head every generated form shares: the mark, the module heading, and what this one is.

    One function rather than a copy per layout, because a chart that merely *resembled* the sheets would
    drift from them the first time either was touched -- and the family reads as one set of forms only for
    as long as the logo, the heading and the two type sizes are literally the same decision.
    """
    heading = composer.chrome["sheet_heading"]
    composer._text(heading, "title")
    composer._text(subtitle, "subtitle")

    y = MARGIN_TOP + TITLE_SIZE
    out.append(composer.logo.place(composer.page_w - MARGIN_X - LOGO_W, MARGIN_TOP, LOGO_W))
    out.append(Text(MARGIN_X, y, heading, "title", "heading"))
    y += SUBTITLE_SIZE + 220
    out.append(Text(MARGIN_X, y, subtitle, "subtitle", f"{slug}-title"))
    return y + 400


def _close_page(out: list[Shape], body: list[Shape], table_top: int, y: int, code: str,
                composer: Composer) -> list[Shape]:
    """Absorb the leftover into the comments box, frame the table, and set the small print under it.

    Whatever the body leaves over becomes room to write, so the page is used rather than trailing off into
    white space. Every trailing block is MEASURED, not estimated: guessing the footer at one line's height
    left a visible band of unused paper when it wrapped to one line and would have overflowed had it
    wrapped to three -- and the whole point of the comments box is that it absorbs exactly what is left, so
    an approximation here is a wrong bottom margin on every form.
    """
    # The legend explains a choose-one circle and a choose-any square, so it belongs on a page that has
    # them and is noise on one that does not -- the progress chart's cells are written in, not marked.
    # Read off what the body actually emitted rather than declared per form: a flag set at the top of a
    # layout is a second statement of the same fact, and it is the copy nobody updates.
    marked = any(isinstance(s, Dot) or (isinstance(s, Box) and s.kind == "mark") for s in body)
    legend_h = _legend_height(composer) if marked else 0
    footer_h = len(
        _fit(composer, composer.chrome["footer_reference"], "note", composer.content_w, "footer", "footer")
    ) * (SMALL_SIZE + 60)
    # Footnotes are part of the budget, not an afterthought. They are known by now -- a collapsed group
    # registers its note while its section is laid out -- and leaving them out let the comments box grow
    # into the space they needed, which turned two sheets that fitted into two that did not.
    notes_h = sum(
        len(_fit(composer, f"{SUPERSCRIPTS[i]} {composer.chrome[k]}", "note", composer.content_w, "footnote", k))
        * (SMALL_SIZE + 60)
        for i, k in enumerate(composer.footnotes)
    ) + (NOTES_TRAIL if composer.footnotes else 0)
    spare = (composer.page_h - MARGIN_BOTTOM - legend_h - footer_h - notes_h) - y
    composer.spare = spare
    if spare > 0:
        # The leftover is ALWAYS absorbed, so the bottom margin equals the other three exactly. Taking it
        # only when it exceeded the minimum meant a sheet with a little space left simply abandoned it --
        # which is why the primary sepsis sheet ended 12 mm higher than the others while every constant
        # said they should match.
        if spare >= LABEL_SIZE + 2 * composer.face.pad_at(LABEL_SIZE, composer.chrome["comments"]):
            # Labelled whenever the label itself fits, which is a measurement rather than a judgement --
            # it costs no height, being drawn inside the space it names. A fixed minimum was tried and
            # left a box with no heading at the foot of a tight sheet, which reads as a mistake rather
            # than as room to write. Below this the space is genuinely too small to head, and it stays
            # blank rather than carrying a label that would not fit above it.
            composer._text(composer.chrome["comments"], "label")
            body.append(Text(TEXT_X, y + ROW_PAD + composer.face.cap_at(LABEL_SIZE),
                             composer.chrome["comments"], "label"))
        y += spare
        body.append(Line(MARGIN_X, y, MARGIN_X + composer.content_w, y, "rule"))

    # The frame goes LAST, so it draws on top of everything inside it. Emitted first, every band and
    # shaded block painted over its edges, and the table's outline broke wherever a fill met it -- most
    # visibly down the left side, where the tinted patient block simply erased it.
    out.extend(body)
    out.append(Box(MARGIN_X, table_top, composer.content_w, y - table_top, "frame"))
    y = _emit_footnotes(out, y, composer)
    if marked:
        y = _emit_legend(out, y, composer)
    y = _emit_footer(out, y, composer)

    usable = composer.page_h - MARGIN_BOTTOM
    if y > usable:
        # Says which limit was passed and by how much, because the two are far apart and the difference
        # decides how urgent this is. Breaching the MARGIN leaves a form that prints and reads perfectly
        # -- a reviewer opening the file sees nothing wrong, which is exactly why the number has to be
        # stated rather than described. Reaching the PAGE EDGE is what actually loses content, and the
        # margin is the headroom that keeps the next translation away from it.
        raise Overflow(
            f"{code}: content runs to {y}, which is {y - usable} past the {MARGIN_BOTTOM}-unit bottom "
            f"margin and still {composer.page_h - y} clear of the page edge. Nothing is clipped; what is "
            f"gone is the room the next translation needs, so this wants a denser layout.",
            out,
        )
    return out


def best_layout(
    form: Sheet | Chart, make_composer: Callable[[int], Composer],
    lay_out: Callable[[Sheet | Chart, Composer], list[Shape]] = None,
) -> tuple[Composer, list[Shape] | None, Overflow | None]:
    """Lay the form out at every candidate answer column and keep the roomiest result.

    The column's position cannot be a constant, and the two pressures on it pull opposite ways: move it
    right and long labels stop wrapping, move it left and more choice runs fit on their label's line.
    Which wins depends on the label and option text -- so it depends on the LANGUAGE, and a number tuned
    against English would have to be re-tuned for each of the other eight and would still be wrong for the
    ninth. Since the layout is a pure function of the text, the position is measured the same way
    everything else here is: lay it out, and keep what leaves the most room.

    'Most room' is the comments box, which absorbs whatever the fields leave over -- so maximizing it is
    the same as minimizing the sheet, and it optimizes the property the sheets are actually judged on.
    """
    lay_out = lay_out or layout_sheet
    best: tuple[tuple[int, int, int], Composer, list[Shape] | None, Overflow | None] | None = None
    for width in range(LABEL_COL_MIN, LABEL_COL_MAX + 1, LABEL_COL_STEP):
        composer = make_composer(width)
        failure: Overflow | None = None
        try:
            body = lay_out(form, composer)
        except Overflow as overflow:
            body, failure = overflow.body, overflow
        # A column that fits beats one that does not, whatever their spare. Among failures, one that got
        # far enough to measure a page beats one that could not place a word at all.
        score = composer.spare if body is not None else -(10 ** 9)
        # Widest spare wins; a tie goes to the NARROWER label column, which is the same layout with more
        # room to write in. Ties are the normal case once the column clears every label on the sheet.
        key = (0 if failure is None else -1, score, -width)
        if best is None or key > best[0]:
            best = (key, composer, body, failure)
    return best[1], best[2], best[3]


def _legend_entries(composer: Composer) -> list[tuple[bool, str]]:
    return [(True, composer.chrome["legend_one"]), (False, composer.chrome["legend_many"])]


def _legend_rows(composer: Composer) -> int:
    """One row when both entries fit on it, two when they do not.

    Two sentences of half a dozen words each were taking a row apiece and most of the foot of the page
    with them. Whether they fit together is a measurement like every other one here, so a language whose
    legend is longer simply gets the stacked form back.
    """
    widths = [composer.face_of("note").width(text, SMALL_SIZE) + MARK + MARK_GAP for _, text in _legend_entries(composer)]
    return 1 if sum(widths) + LEGEND_SEP <= composer.content_w - 2 * TEXT_INSET else 2


def _legend_height(composer: Composer) -> int:
    """What `_emit_legend` will take. The page budget and the emitter must not disagree: the comments box
    absorbs the difference between them, so an estimate here is a wrong bottom margin on every sheet."""
    return LEGEND_LEAD + _legend_rows(composer) * (LEGEND_ROW)


def _emit_legend(out: list[Shape], y: int, composer: Composer) -> int:
    """What the two markers mean. Every published sheet carries it, and without it the shapes are decor."""
    y += LEGEND_LEAD
    one_row = _legend_rows(composer) == 1
    x, baseline = TEXT_X, y + MARK - 20
    for radio, text in _legend_entries(composer):
        composer._text(text, "note")
        _mark(out, f"legend-{'one' if radio else 'many'}", int(x), baseline, radio, composer, SMALL_SIZE)
        out.append(Text(int(x + MARK + MARK_GAP), baseline, text, "note"))
        if one_row:
            x += MARK + MARK_GAP + composer.face_of("note").width(text, SMALL_SIZE) + LEGEND_SEP
        else:
            baseline += LEGEND_ROW
    return y + _legend_rows(composer) * (LEGEND_ROW)


def _emit_footnotes(out: list[Shape], y: int, composer: Composer) -> int:
    """The notes the collapsed rows point at. A group without its note is a question with no stated rule."""
    for index, key in enumerate(composer.footnotes):
        text = f"{SUPERSCRIPTS[index]} {composer.chrome[key]}"
        composer._text(text, "note")
        for line in _fit(composer, text, "note", composer.content_w, "footnote", key):
            y += SMALL_SIZE + 60
            out.append(Text(MARGIN_X, y, line, "note"))
    return y + (NOTES_TRAIL if composer.footnotes else 0)


def _emit_footer(out: list[Shape], y: int, composer: Composer) -> int:
    text = composer.chrome["footer_reference"]
    composer._text(text, "note")
    for line in _fit(composer, text, "note", composer.content_w, "footer", "footer"):
        y += SMALL_SIZE + 60
        out.append(Text(MARGIN_X, y, line, "note"))
    return y


def _emit_patient_block(out: list[Shape], y: int, composer: Composer) -> int:
    """Who this sheet is about -- on every sheet, because a loose page has to be filed to a patient.

    These two fields exist on the paper and nowhere else. The sheet is completed at a cot side and stays
    in the hospital, so it must name the patient unambiguously; the surveillance dataset must never carry
    that, and the note says so on the page rather than leaving it to the protocol. A person holding a form
    cannot be expected to know which of those two things they are doing.
    """
    title = composer.chrome["section_patient"]
    composer._text(title, "section")
    out.append(Box(MARGIN_X, y, composer.content_w, SECTION_BAND_H, "band"))
    out.append(Text(composer.page_w // 2, y + SECTION_BAND_H - 150, title, "section", "patient"))
    y += SECTION_BAND_H

    # The shaded block is laid down first so the rows and the note draw over it; its height is only known
    # once they are measured, so the two boxes are patched in afterwards at a remembered index.
    block_top = y
    shading = len(out)
    out.append(Box(0, 0, 0, 0, "notransmit"))
    out.append(Box(0, 0, 0, 0, "notransmit-edge"))

    # These two exist to tell one patient from another, so they have to tell each OTHER apart first. A
    # translation that renders both the same is not a wording preference: it leaves a person holding the
    # form with two identical lines and no way to know which takes the identifier and which the name, and
    # it looks entirely finished. Checked here because it is a property of the pair rather than of either
    # string, so no per-string check in the translation pipeline can see it.
    identifying = [composer.chrome[k] for k in ("patient_identifier", "patient_name")]
    if identifying[0] == identifying[1]:
        composer.problems.append(
            f"the patient block's two fields both read {identifying[0]!r}, so the form cannot say which "
            f"line takes the identifier and which the name; the two source strings need distinct "
            f"translations in this language"
        )

    for key in ("patient_identifier", "patient_name"):
        label = composer.chrome[key]
        composer._text(label, "label")
        top = y
        y += composer.face.pad_at(LABEL_SIZE, label)
        for line in _fit(composer, label, "label", composer.answer_x - COLUMN_GAP - TEXT_X, key, "label"):
            out.append(Text(TEXT_X, y + composer.face.cap_at(LABEL_SIZE), line, "label"))
            y += LABEL_SIZE + LINE_GAP
        y += composer.face.pad_at(LABEL_SIZE, label) - LINE_GAP
        # Written on the same column as every other answer, and on the rule closing the row. These two
        # rows are where the sheet's grid is established for its reader, so they follow it rather than
        # setting a second convention at the top of the page.
        _column(out, top, y, composer)
        out.append(Line(MARGIN_X, y, MARGIN_X + composer.content_w, y, "rule"))

    note = composer.chrome["patient_note"]
    composer._text(note, "note")
    y += composer.face.pad_at(SMALL_SIZE, note)
    for line in _fit(composer, note, "note", composer.content_w - 360, "patient_note", "note"):
        out.append(Text(TEXT_X, y + composer.face.cap_at(SMALL_SIZE), line, "note"))
        y += SMALL_SIZE + LINE_GAP
    y += composer.face.pad_at(SMALL_SIZE, note) - LINE_GAP
    out.append(Line(MARGIN_X, y, MARGIN_X + composer.content_w, y, "rule"))

    height = y - block_top
    out[shading] = Box(MARGIN_X, block_top, composer.content_w, height, "notransmit")
    out[shading + 1] = Box(MARGIN_X, block_top, NOTRANSMIT_BAR, height, "notransmit-edge")
    return y


def _emit_section(out: list[Shape], section: Section, y: int, composer: Composer) -> int:
    # Bounded like every other run. A section title is localized metadata, centred in a band, and it was
    # the one text on the sheet that was only checked for missing glyphs -- so a longer translation would
    # have run out past the band's ends and off the page, in exactly the languages nobody proof-reads.
    if section.banded:
        composer._text(section.title, "section")
        lines = _fit(composer, section.title, "section", composer.content_w - 360, section.code, "section title")
        band_h = SECTION_BAND_H + (len(lines) - 1) * (SECTION_SIZE + LINE_GAP)
        out.append(Box(MARGIN_X, y, composer.content_w, band_h, "band"))
        ty = y + SECTION_BAND_H - 150
        for index, line in enumerate(lines):
            out.append(Text(composer.page_w // 2, ty, line, "section",
                            _slug(section.code) if index == 0 else None))
            ty += SECTION_SIZE + LINE_GAP
        y += band_h

    if section.definition:
        # The case this section covers, in the protocol's own words, standing where the question that
        # asked which case applies used to be. It says more than that question did: the options never
        # carried the 30-day and 90-day windows.
        composer._text(section.definition, "note")
        y += composer.face.pad_at(SMALL_SIZE, section.definition)
        for line in _fit(composer, section.definition, "note", composer.content_w - 2 * TEXT_INSET,
                         section.code, "definition"):
            out.append(Text(TEXT_X, y + composer.face.cap_at(SMALL_SIZE), line, "note"))
            y += SMALL_SIZE + LINE_GAP
        y += composer.face.pad_at(SMALL_SIZE, section.definition) - LINE_GAP
        out.append(Line(MARGIN_X, y, MARGIN_X + composer.content_w, y, "hair"))

    rows = _pair_ticks(_collapse_groups(section.fields, composer), composer)
    for index, row in enumerate(rows):
        # EVERY row is closed, because every row is a cell of a ruled table. A space to write in that is
        # bounded on all four sides -- the frame, the answer column, and the rules above and below it --
        # needs no line of its own, which is what a writing rule floating inside an unruled block looked
        # like: a stray mark rather than a field.
        #
        # The weight carries what the rule used to carry by its presence: a slot and the fields hanging
        # off it stay one block, separated by hairlines, and the full rule falls at the block's edge.
        following = rows[index + 1][0] if index + 1 < len(rows) else None
        closes = following is None or not following.is_child
        if len(row) == 2:
            y = _emit_tick_pair(out, row, y, composer)
        else:
            emit = _emit_child if row[0].is_child else _emit_field
            y = emit(out, row[0], y, composer, closes)
        out.append(Line(MARGIN_X, y, MARGIN_X + composer.content_w, y, "rule" if closes else "hair"))
    return y


def _is_tick(field: Field, composer: Composer) -> bool:
    """A criterion marked with a single box on its own line, with no answer beside it."""
    return (not field.is_child and not field.options
            and composer.layout.boolean_style(field) == "tick")


def _pair_ticks(fields: list[Field], composer: Composer) -> list[tuple[Field, ...]]:
    """Put two tick criteria on one row wherever both fit half the width.

    A criterion is a box and a few words, and it was taking a full-width row -- so two thirds of every one
    of them was blank paper. The signs-and-symptoms and laboratory-findings blocks are almost entirely
    these, which is why the infection sheets ran over a page while the space to fix it sat unused beside
    every line.

    Pairing is greedy and conditional on measurement, so a criterion whose text needs the full width still
    gets it and nothing is squeezed. Fields with children are never paired: a slot header and the block
    hanging off it are one thing, and splitting that across a half-row would break the group the rule
    below it closes.
    """
    half = (composer.content_w - 2 * TEXT_INSET) // 2

    def fits(field: Field) -> bool:
        return (composer.face_of("label").width(_required(field, composer), LABEL_SIZE)
                + MARK + MARK_GAP + PAIR_GUTTER <= half)

    rows: list[tuple[Field, ...]] = []
    index = 0
    while index < len(fields):
        following = fields[index + 1] if index + 1 < len(fields) else None
        after = fields[index + 2] if index + 2 < len(fields) else None
        if (following is not None and _is_tick(fields[index], composer) and _is_tick(following, composer)
                and (after is None or not after.is_child)
                and fits(fields[index]) and fits(following)):
            rows.append((fields[index], following))
            index += 2
        else:
            rows.append((fields[index],))
            index += 1
    return rows


def _emit_tick_pair(out: list[Shape], pair: tuple[Field, ...], y: int, composer: Composer) -> int:
    """Two criteria side by side, on the same baseline, each on its own column."""
    labels = [_required(field, composer) for field in pair]
    # Both criteria share the row, so the row is padded for both of them.
    pad = composer.face.pad_at(LABEL_SIZE, " ".join(labels))
    y += pad
    baseline = y + composer.face.cap_at(LABEL_SIZE)
    for field, label, x in zip(pair, labels, (TEXT_X, MARGIN_X + composer.content_w // 2)):
        composer._text(label, "label")
        _mark(out, _ident(field), x, baseline, False, composer, LABEL_SIZE)
        out.append(Text(x + MARK + MARK_GAP, baseline, label, "label"))
    return y + LABEL_SIZE + pad


def _collapse_groups(fields: list[Field], composer: Composer) -> list[Field]:
    """Replace each run of grouped fields with the single row the form prints for them.

    The run must be CONSECUTIVE and share a slot prefix. Grouping across a gap would silently reorder the
    form relative to the data model, and grouping across slots would put one organism's answer on
    another's line -- both of which read as a working sheet.
    """
    fields = [f for f in fields if composer.layout.prints(f)]

    # Fold a continuation onto the row before it, before any grouping runs: a field that is part of
    # another's row is not a row of its own and must not be counted as one.
    folded: list[Field] = []
    for field in fields:
        unit = composer.layout.continues_row(folded[-1] if folded else None, field, composer.chrome)
        if unit is None:
            folded.append(field)
        else:
            folded[-1].trailing = unit
    fields = folded

    out: list[Field] = []
    index = 0
    while index < len(fields):
        field = fields[index]
        group = composer.layout.group_of(field)
        if group is None:
            out.append(field)
            index += 1
            continue

        prefix = field.code.rsplit("_", 1)[0]
        run = [field]
        while index + len(run) < len(fields):
            candidate = fields[index + len(run)]
            if composer.layout.group_of(candidate) is not group or not candidate.code.startswith(prefix):
                break
            run.append(candidate)

        marker = composer.footnote(group["footnote_key"])
        label = composer.fill(composer.chrome[group["label_key"]], group["label_terms"])
        out.append(
            Field(
                code=f"{prefix}_{'_'.join(group['suffixes'])}",
                # The '- ' keeps it a child of the slot it belongs to, exactly as its members were.
                label=f"- {label}{marker}",
                value_type=run[0].value_type,
                compulsory=any(f.compulsory for f in run),
                options=run[0].options,
                radio=run[0].radio,
            )
        )
        index += len(run)
    return out


def _emit_child(out: list[Shape], field: Field, y: int, composer: Composer, closes_group: bool = True) -> int:
    """A sub-field on one line: its short label, then its answer at the sheet's answer column.

    This is where the page is won. Nine fields per organism slot, each given a label row and its own
    option rows underneath, is most of two pages for one section; the same nine as compact lines under
    their slot header is a block.

    The answer starts at the column rather than after the label, which is what makes a slot read as a
    block at all: with each row starting its marks wherever its own label ended, an organism's three
    resistance rows stepped visibly rightwards down the sheet and no two rows agreed on anything.
    """
    label = field.short_label
    composer._text(label, "child")
    top = y
    y += composer.face.pad_at(OPTION_SIZE, label) // 2

    x = TEXT_X + OPTION_INDENT
    baseline = y + composer.face.cap_at(OPTION_SIZE)
    for line in _fit(composer, label, "child", composer.answer_x - COLUMN_GAP - x, field.code, "label"):
        out.append(Text(x, baseline, line, "child"))
        baseline += OPTION_SIZE + LINE_GAP
    baseline -= OPTION_SIZE + LINE_GAP
    right = MARGIN_X + composer.content_w - 180

    options, radio = field.options, field.radio
    if not options and not field.write_in:
        style = composer.layout.boolean_style(field)
        if style == "yes_no":
            options, radio = [composer.chrome["boolean_yes"], composer.chrome["boolean_no"]], True
        elif style == "tick":
            _mark(out, _ident(field), composer.answer_text_x, baseline, False, composer)
            return _column(out, top, baseline + composer.face.pad_at(OPTION_SIZE, label), composer)

    if not options:
        # Bounded by the grid, like every other cell.
        return _column(out, top, baseline + composer.face.pad_at(OPTION_SIZE, label), composer)

    for option in options:
        composer._text(option, "option")
    widths = [composer.face_of("option").width(option, OPTION_SIZE) for option in options]
    needed = sum(w + MARK + MARK_GAP for w in widths) + OPTION_SEP * (len(options) - 1)
    if composer.answer_text_x + needed > right:
        # The choices will not share the label's line, so fall back to the indented block a parent uses,
        # which has the full width to wrap into. That block spans the column, so no stroke is drawn.
        return _emit_options(out, field, options, radio, baseline + LINE_GAP, composer)

    ident = _ident(field)
    x = composer.answer_text_x
    for index, option in enumerate(options):
        _mark(out, f"{ident}-{index + 1}", int(x), baseline, radio, composer)
        out.append(Text(int(x + MARK + MARK_GAP), baseline, option, "option"))
        x += MARK + MARK_GAP + widths[index] + OPTION_SEP
    return _column(out, top, baseline + LINE_GAP, composer)


def _emit_field(out: list[Shape], field: Field, y: int, composer: Composer, closes_group: bool = True) -> int:
    """One field is one full-width row: bold label, then whatever it needs to be answered."""
    label = _required(field, composer)
    composer._text(label, "label")
    style = composer.layout.boolean_style(field)

    options, radio = field.options, field.radio
    if not options and style == "yes_no":
        options = [composer.chrome["boolean_yes"], composer.chrome["boolean_no"]]
        radio = True

    # Choices short enough to sit on their label's own line do so, at the answer column, instead of taking
    # an indented row beneath it. A Yes/No pair given a row of its own costs the same height as a
    # paragraph, and the sheets that overflow are full of them.
    #
    # It is measured rather than decided, so the same field moves back below its label in a language whose
    # options are longer -- which is why the inconsistency this introduces is tolerable: it is not "short
    # ones are treated differently", it is "each row uses the space it has".
    widths = [composer.face_of("option").width(option, OPTION_SIZE) for option in options]
    needed = (sum(w + MARK + MARK_GAP for w in widths) + OPTION_SEP * (len(options) - 1)) if options else 0
    inline = bool(options) and composer.answer_text_x + needed <= MARGIN_X + composer.content_w - TEXT_INSET

    # A row is either answered ON its own line -- a space to write in, or a choice run, both starting at
    # the answer column -- or it spans the sheet: a criterion whose tick sits at the left, or a question
    # whose choices are too long and are listed beneath it. Only the first kind has a cell, so only that
    # kind is bounded by the column, and only that kind gives up label width to it.
    answered_here = style != "tick" and (not options or inline)

    top = y
    # Only the label is on the row's first line, so only the label decides the clearance above it.
    y += composer.face.pad_at(LABEL_SIZE, label)
    label_x = TEXT_X
    if style == "tick":
        # The tick sits on the label's own line: a criterion in a list reads as one thing to mark, not as
        # a question followed by an answer. This is the shape the published sheets use for every
        # signs-and-symptoms and laboratory-findings element.
        _mark(out, _ident(field), TEXT_X, y + composer.face.cap_at(LABEL_SIZE), False, composer, LABEL_SIZE)
        label_x = TEXT_X + MARK + MARK_GAP

    edge = composer.answer_x - COLUMN_GAP if answered_here else MARGIN_X + composer.content_w - 180
    baseline = y + composer.face.cap_at(LABEL_SIZE)
    for line in _fit(composer, label, "label", edge - label_x, field.code, "label"):
        out.append(Text(label_x, baseline, line, "label"))
        y += LABEL_SIZE + LINE_GAP
        baseline += LABEL_SIZE + LINE_GAP
    y -= LINE_GAP
    baseline -= LABEL_SIZE + LINE_GAP

    if field.trailing:
        return _emit_paired_row(out, field, top, y, baseline, composer, closes_group)

    if inline:
        ident = _ident(field)
        x = composer.answer_text_x
        for index, option in enumerate(options):
            composer._text(option, "option")
            _mark(out, f"{ident}-{index + 1}", int(x), baseline, radio, composer)
            out.append(Text(int(x + MARK + MARK_GAP), baseline, option, "option"))
            x += MARK + MARK_GAP + widths[index] + OPTION_SEP
        # The choice run shares the label's line, so both decide the clearance below it.
        return _column(out, top, y + composer.face.pad_at(LABEL_SIZE, " ".join([label, *options])), composer)

    if options:
        # The choices are the last thing in the block, so they are what the closing clearance is for.
        return (_emit_options(out, field, options, radio, y + LINE_GAP, composer)
                + composer.face.pad_at(LABEL_SIZE, " ".join(options)))

    y += composer.face.pad_at(LABEL_SIZE, label)
    if answered_here:
        # No writing line: the cell is the box formed by the frame, the column and the rules above and
        # below this row. Drawing one inside it would either double the rule beneath or float in the
        # middle of the cell, and both were tried.
        _column(out, top, y, composer)
    return y


def _emit_paired_row(out: list[Shape], field: Field, top: int, y: int, baseline: int, composer: Composer,
                     closes_group: bool) -> int:
    """A row carrying two values -- an antibiotic substance and the number of days it was given.

    Both are written on the rule that closes the row, so the row shows one line at its foot instead of a
    writing rule sitting just above the rule beneath it. What divides the two cells is a vertical stroke
    of the same weight and kind as the answer column's, so the row reads as three cells of one table
    rather than as two underscores floating in it.
    """
    composer._text(field.trailing, "label")
    right = MARGIN_X + composer.content_w - 180
    unit_x = int(right - composer.face_of("label").width(field.trailing, LABEL_SIZE))
    divider = unit_x - 2400
    # The unit word sits on the label's own baseline. Placing it at the row's foot instead dropped it
    # below every other word on its line by the difference between the font size and the cap height.
    out.append(Text(unit_x, baseline, field.trailing, "label"))

    bottom = y + composer.face.pad_at(LABEL_SIZE, f"{_required(field, composer)} {field.trailing}")
    _column(out, top, bottom, composer)
    out.append(Line(divider, top, divider, bottom, "column"))
    return bottom


def _emit_options(out: list[Shape], field: Field, options: list[str], radio: bool, y: int, composer: Composer) -> int:
    """Lay the choices along one line when they fit, and one per line when they do not.

    Fitting them horizontally is the single biggest reason the published sheets hold a page, and it is a
    measurement decision rather than a rule of thumb -- which is why the one-page requirement is reachable
    at all instead of being something to negotiate away.
    """
    ident = field.code.lower().replace("_", "-")
    for option in options:
        composer._text(option, "option")

    left = TEXT_X + OPTION_INDENT
    available = MARGIN_X + composer.content_w - left - 180
    widths = [composer.face_of("option").width(option, OPTION_SIZE) for option in options]
    inline = sum(w + MARK + MARK_GAP for w in widths) + OPTION_SEP * (len(options) - 1)

    if inline <= available:
        x = left
        for index, option in enumerate(options):
            baseline = y + composer.face.cap_at(OPTION_SIZE)
            _mark(out, f"{ident}-{index + 1}", int(x), baseline, radio, composer)
            out.append(Text(int(x + MARK + MARK_GAP), baseline, option, "option"))
            x += MARK + MARK_GAP + widths[index] + OPTION_SEP
        return y + OPTION_SIZE + LINE_GAP

    for index, option in enumerate(options):
        _mark(out, f"{ident}-{index + 1}", left, y + composer.face.cap_at(OPTION_SIZE), radio, composer)
        text_x = left + MARK + MARK_GAP
        for line in _fit(composer, option, "option", available - MARK - MARK_GAP, field.code, f"option {index + 1}"):
            out.append(Text(text_x, y + composer.face.cap_at(OPTION_SIZE), line, "option"))
            y += OPTION_SIZE + LINE_GAP
    return y


def _mark(out: list[Shape], ident: str, x: int, baseline: int, radio: bool, composer: Composer,
          size: int = OPTION_SIZE) -> None:
    """A choose-one circle or a choose-any square, centred on the text it belongs to.

    Takes the text's BASELINE, not a row offset. The mark has to sit on the optical middle of the band
    the letters occupy -- between the baseline and the cap height -- and that band moved when rows began
    being measured from the face. Placed from the row's top instead, every mark drifted low and the
    drift grew with the size of the text beside it.
    """
    centre = baseline - composer.face.cap_at(size) // 2
    if radio:
        out.append(Dot(x + MARK // 2, centre, MARK // 2, ident))
    else:
        out.append(Box(x, centre - MARK // 2, MARK, MARK, "mark", ident))


def _column(out: list[Shape], top: int, bottom: int, composer: Composer, x: int | None = None) -> int:
    """Bound one row's answer cell on the left, and return the row's foot so callers can `return` it.

    Drawn per row rather than as one line down the sheet, because the rows that span it have no cell for
    it to bound and a stroke through their text would be a defect rather than a grid.

    `x` defaults to the sheet's one answer column. The chart's filing row overrides it because that row
    carries two cells side by side, each wanting the column at the same offset into its own half -- which
    is the same rule applied twice, not a second convention.
    """
    at = composer.answer_x if x is None else x
    out.append(Line(at, top, at, bottom, "column"))
    return bottom


def _required(field: Field, composer: Composer) -> str:
    """The label as printed, which says so where the protocol requires an answer.

    A word rather than an asterisk, so it survives being read aloud and a translator can choose a form
    that fits the language.
    """
    return field.label + (f" ({composer.chrome['required']})" if field.compulsory else "")


def _ident(field: Field) -> str:
    """The element's own code as an SVG id -- semantic, and traceable back to the metadata."""
    return field.code.lower().replace("_", "-")


def _fit(composer: Composer, text: str, style: str, width: int, code: str, what: str) -> list[str]:
    """Wrap to the cell in the style's own face, and refuse to emit anything that still does not fit.

    The style carries the size and the face together, so the text cannot be wrapped to one measurement
    and then set in another -- which is the whole reason a run's style rather than its size is what gets
    passed around.

    `wrap` cannot break inside a word, so a single token wider than the cell comes back as its own
    over-long line. That is the German-compound case, and emitting it anyway is precisely what the XSLT
    wrapper did -- silently, because character counting cannot tell that it happened.
    """
    size = STYLES[style].size
    face = composer.face_of(style)
    lines = face.wrap(text, size, width)
    widest = max(face.width(line, size) for line in lines)
    if widest > width:
        raise Overflow(
            f"{code}: the {what} {text!r} contains a word wider than its {width}-unit cell "
            f"({widest:.0f} units at size {size}). Shorten the text or widen the column; it must not be "
            f"emitted overflowing."
        )
    return lines


def _plain(text: str) -> str:
    """Drop every soft hyphen on the way out, whichever output is being written.

    A soft hyphen is a note from the translator to the layout -- "this word may divide here" -- and no
    renderer must ever receive one, because a renderer that draws U+00AD puts a hyphen through the middle
    of a word that never needed to break. `Face.wrap` already strips them and writes a real hyphen where a
    break is actually taken, but wrapping is not the only way text reaches the page. Paired criteria,
    inline choice runs, the legend and the sheet's own heading are all placed directly, and every one of
    them leaked: a German test render read "Kern-modul", "Druck-schmerz" and "Temperatur-auffälligkeiten",
    none of which had broken anywhere.

    Stripping in the funnel every serializer goes through makes it a property of emission rather than a
    rule each new one has to remember.
    """
    return text.replace(SOFT_HYPHEN, "")


def _esc(text: str) -> str:
    """Escape for XML."""
    return _plain(text).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def _quoted(text: str) -> str:
    """A Typst string literal.

    Text goes into the `.typ` as a string rather than as markup, so a label containing `#`, `*`, `_`, `@`
    or a leading `-` is a label rather than a directive, an emphasis or a list item. That leaves exactly
    two characters to escape instead of the dozen Typst's markup mode would.
    """
    return '"' + _plain(text).replace("\\", "\\\\").replace('"', '\\"') + '"'


# ── Serializing ─────────────────────────────────────────────────────────────────────────────────────


def svg_document(form: Sheet | Chart, shapes: list[Shape], composer: Composer) -> str:
    """The screen figure, inlined into the protocol so its text stays real text."""
    head = [
        '<svg version="1.1" viewBox="0 0 %d %d" xmlns="http://www.w3.org/2000/svg" '
        'xmlns:xlink="http://www.w3.org/1999/xlink" role="img" xml:lang="%s">'
        % (composer.page_w, composer.page_h, composer.language_tag),
        # What a screen reader announces. Without them an inlined figure is an unlabelled graphic, which
        # reads as nothing at all, and accessibility is a stated goal of this toolkit rather than a nicety.
        f"  <title>{_esc(title_of(form, composer))}</title>",
        f"  <desc>{_esc(description_of(form, composer))}</desc>",
        "  <style>",
        # The families this sheet was measured in, in the order it was measured -- and NO generic at the
        # end. `sans-serif` looks like prudence and is a trap: prawn-svg maps it to Helvetica, a core font
        # with Windows-1252 encoding and no embedded glyphs, so every character outside Latin-1 comes out
        # as the logical-NOT sign. A missing font must fail rather than degrade.
        #
        # On a mirrored page every run's x is its right-hand end, and the base direction is what a
        # bidirectional reorderer resolves each run against.
        "    text { font-family: %s; fill: #000;%s }" % (
            _css_families(composer.face),
            " direction: rtl; text-anchor: end;" if composer.rtl else "",
        ),
        *(f"    .{name} {{ {_css_text(style)} }}" for name, style in STYLES.items()),
        *(f"    .{kind} {{ {_css_shape(kind, ink)} }}" for kind, ink in INKS.items()),
        # The inlined logo's paths carry these classes. Defined here rather than kept inside the symbol so
        # the sheet has exactly one stylesheet -- and because a symbol whose own <style> was dropped
        # renders in the default fill, which is black, silently.
        "    .brand-blue { fill: %s; }" % ACCENT,
        "    .brand-orange { fill: %s; }" % BRAND_ORANGE,
        "  </style>",
    ] + composer.logo.definition()
    return "\n".join(head + [_svg_shape(shape) for shape in shapes] + ["</svg>", ""])


def _css_families(face: Typeface) -> str:
    return ", ".join(f"'{family}'" for family in face.families)


def _css_text(style: Style) -> str:
    parts = [f"font-size: {style.size}px"]
    if style.bold:
        parts.append("font-weight: bold")
    if style.italic:
        parts.append("font-style: italic")
    if style.colour != "#000":
        parts.append(f"fill: {style.colour}")
    if style.centred:
        # Stated on the style rather than left to the base rule, so it wins in both directions: a section
        # title is centred on the page whichever way the page reads.
        parts.append("text-anchor: middle")
    return "; ".join(parts) + ";"


def _css_shape(kind: str, ink: Ink) -> str:
    parts = []
    if kind not in _LINE_KINDS:
        # A rect defaults to being filled black, so an unfilled one has to say so; a line has no interior
        # for the property to describe and saying it there is noise in a file people read.
        parts.append(f"fill: {ink.fill or 'none'}")
    parts.append(f"stroke: #000; stroke-width: {ink.stroke}" if ink.stroke else "stroke: none")
    return "; ".join(parts) + ";"


def _svg_shape(shape: Shape) -> str:
    match shape:
        case Text():
            return (f'  <text{_svg_id(shape.ident)} class="{shape.style}" x="{shape.x}" y="{shape.y}">'
                    f"{_esc(shape.text)}</text>")
        case Line():
            return (f'  <line class="{shape.kind}" x1="{shape.x1}" y1="{shape.y1}" '
                    f'x2="{shape.x2}" y2="{shape.y2}"/>')
        case Box():
            return (f'  <rect{_svg_id(shape.ident)} class="{shape.kind}" x="{shape.x}" y="{shape.y}" '
                    f'width="{shape.width}" height="{shape.height}"/>')
        case Dot():
            return (f'  <circle{_svg_id(shape.ident)} class="mark" cx="{shape.cx}" cy="{shape.cy}" '
                    f'r="{shape.r}"/>')
        case Emblem():
            return (f'  <use href="#neoipc-logo" x="{shape.x}" y="{shape.y}" '
                    f'width="{shape.width}" height="{shape.height}"/>')


def _svg_id(ident: str | None) -> str:
    """Semantic ids come from the metadata code, so a row on the page is traceable to what it collects.
    Shapes that carry no meaning of their own -- a rule, a frame -- carry no id either."""
    return f' id="{ident}"' if ident else ""


def typst_document(form: Sheet | Chart, shapes: list[Shape], composer: Composer) -> str:
    """The printed form: one page, drawn by an engine that shapes text and can declare a conformance.

    Every element is placed absolutely, at the coordinates the layout already chose, so nothing here
    reflows and the two outputs cannot disagree about what is on the sheet or where.
    """
    return "\n".join(
        _typst_preamble(form, composer)
        + [_typst_shape(shape, composer) for shape in shapes]
        + [""]
    )


def _typst_preamble(form: Sheet | Chart, composer: Composer) -> list[str]:
    styles = ",\n".join(f"  {name}: s => text({_typst_text_args(style)}, s)"
                        for name, style in STYLES.items())
    strokes = ",\n".join(f'  "{kind}": {ink.stroke} * u + black'
                         for kind, ink in INKS.items() if ink.stroke and kind in _LINE_KINDS)
    blocks = ",\n".join(f'  "{kind}": (fill: {_typst_colour(ink.fill)}, stroke: {_typst_stroke(ink)})'
                        for kind, ink in INKS.items() if kind not in _LINE_KINDS)
    families = ", ".join(_quoted(family) for family in composer.face.families)
    direction = "rtl" if composer.rtl else "ltr"
    # A trailing comma so a one-element list stays a list rather than collapsing to a bare string.
    keywords = "".join(f"{_quoted(word)}, " for word in keywords_of(form, composer))
    # On a mirrored page a run's x is its right-hand end, so it is placed from the page's right edge. The
    # two forms are the same statement about where a run goes, expressed from whichever side it starts.
    anchor = (
        "#let at(x, y, style, w, s) = place(\n"
        f"  top + right, dx: (x - {composer.page_w}) * u, dy: y * u, fit(w, styles.at(style)(s)),\n"
        ")"
        if composer.rtl else
        "#let at(x, y, style, w, s) = place(\n"
        "  top + left, dx: x * u, dy: y * u, fit(w, styles.at(style)(s)),\n"
        ")"
    )
    return f"""// Generated by scripts/build-collection-sheets.py from metadata/common. Do not edit.
//
// Compile with this repository's own fonts and nothing else:
//
//   typst compile --font-path common/fonts --ignore-system-fonts --pdf-standard a-2a,ua-1 <this file>
//
// --ignore-system-fonts is not optional. --font-path ADDS to whatever the machine has installed rather
// than replacing it, so without it a face this document asks for and common/fonts does not ship is
// answered by some other file -- a different one per machine, chosen silently.
//
// Set SOURCE_DATE_EPOCH, or pass --creation-timestamp, for a reproducible file. Left to itself the
// document date is the wall clock, and two compiles of one source then differ.

#set document(
  title: {_quoted(title_of(form, composer))},
  description: {_quoted(description_of(form, composer))},
  keywords: ({keywords}),
  date: auto,
)

// The sheet's grid: hundredths of a millimetre, carrying the same integers as the SVG so a coordinate
// here and a coordinate there are the same number.
#let u = 0.01mm

#set page(width: {composer.page_w} * u, height: {composer.page_h} * u, margin: 0pt)
// top-edge and bottom-edge at the baseline give a text box no height at all, which is what makes `place`
// position a run by its BASELINE -- the same reference every measurement in the layout is taken from.
// `fallback: false` keeps a missing glyph missing instead of borrowing one from another family.
//
// `lang` is what the exported PDF declares as its own language, and it has to be right rather than
// merely present: a screen reader takes its pronunciation rules from it, so a page of Devanagari
// declaring English is read aloud in the wrong language, and PDF/UA is not met by a declaration that is
// false. Typst would otherwise default it to English on every localized form.
#set text(font: ({families}), fallback: false, top-edge: "baseline", bottom-edge: "baseline",
          lang: {_quoted(composer.language_tag)}, dir: {direction})

// What the layout measured a run at, against what the engine will actually draw, checked on every run.
//
// The slack is ONE grid unit -- a hundredth of a millimetre, for the rounding in getting a float onto
// this grid -- and no proportional term at all. Both sides shape with HarfBuzz against the same file,
// the layout through `uharfbuzz` and the engine through `rustybuzz`, so they agree exactly rather than
// approximately: measured across every run of every sheet in English and Nepali, none needed more.
//
// A proportional term is what an unshaped measurement would need, and it would cost most of what this
// check is worth. The disagreements it exists to catch -- a run set in the wrong face, or a script whose
// shaping the measurement cannot see -- are 6 % and 12 to 16 %, but the ones worth catching EARLY are
// far smaller than that, and half a percent of a full-width line is a third of a millimetre of overlap
// admitted silently.
#let fit(w, body) = context {{
  let drawn = measure(body).width
  assert(
    drawn <= w * u + u,
    message: "drawn " + repr(drawn) + " wide, past the " + repr(w * u) + " the layout allowed for it",
  )
  body
}}

#let styles = (
{styles},
)
#let strokes = (
{strokes},
)
#let blocks = (
{blocks},
)

{anchor}
// A section title is centred on the page rather than on anything the layout placed, so it is positioned
// from the page's own middle instead of from a left edge and a measured width.
#let mid(x, y, style, w, s) = place(
  top + center, dx: (x - {composer.page_w // 2}) * u, dy: y * u, fit(w, styles.at(style)(s)),
)
#let stroke-between(kind, x1, y1, x2, y2) = place(
  top + left, line(start: (x1 * u, y1 * u), end: (x2 * u, y2 * u), stroke: strokes.at(kind)),
)
#let block-at(kind, x, y, w, h) = place(
  top + left, dx: x * u, dy: y * u, rect(width: w * u, height: h * u, ..blocks.at(kind)),
)
#let dot-at(x, y, r) = place(
  top + left, dx: (x - r) * u, dy: (y - r) * u, circle(radius: r * u, ..blocks.at("mark")),
)

// {Logo.NOTICE}
#let emblem = {_quoted(composer.logo.standalone())}
// The mark is a wordmark, so what it says IS its accessible name -- not decoration to be hidden from a
// screen reader as an artifact, which would be irreversible and would assert it carries nothing.
#let emblem-at(x, y, w, h) = place(
  top + left, dx: x * u, dy: y * u,
  image(bytes(emblem), format: "svg", alt: {_quoted(composer.logo.name)},
        width: w * u, height: h * u),
)
""".splitlines()


# Which inks describe a stroked path rather than a filled block. Both come out of one table, because the
# weights are chosen against each other and splitting them invites two half-tables that drift.
_LINE_KINDS = frozenset({"rule", "hair", "column"})


def _typst_text_args(style: Style) -> str:
    args = [f"size: {style.size} * u"]
    if style.bold:
        args.append('weight: "bold"')
    if style.italic:
        args.append('style: "italic"')
    if style.colour != "#000":
        args.append(f'fill: {_typst_colour(style.colour)}')
    return ", ".join(args)


def _typst_colour(colour: str | None) -> str:
    if colour is None:
        return "none"
    return "black" if colour == "#000" else f'rgb("{colour}")'


def _typst_stroke(ink: Ink) -> str:
    return f"{ink.stroke} * u + black" if ink.stroke else "none"


def _typst_shape(shape: Shape, composer: Composer) -> str:
    match shape:
        case Text():
            place = "mid" if STYLES[shape.style].centred else "at"
            width = round(composer.measured(shape), 1)
            return (f'#{place}({shape.x}, {shape.y}, "{shape.style}", {width}, '
                    f"{_quoted(shape.text)})")
        case Line():
            return f'#stroke-between("{shape.kind}", {shape.x1}, {shape.y1}, {shape.x2}, {shape.y2})'
        case Box():
            return (f'#block-at("{shape.kind}", {shape.x}, {shape.y}, '
                    f"{shape.width}, {shape.height})")
        case Dot():
            return f"#dot-at({shape.cx}, {shape.cy}, {shape.r})"
        case Emblem():
            return f"#emblem-at({shape.x}, {shape.y}, {shape.width}, {shape.height})"


# ── Entry point ─────────────────────────────────────────────────────────────────────────────────────

# The two renderings of one layout: the figure the protocol inlines, and the source of the form a partner
# prints. Named here so `--format` and the writing loop cannot disagree about what either one is called.
OUTPUTS = (("svg", "svg", svg_document), ("typst", "typ", typst_document))


def main(argv: list[Shape] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    repo = Path(__file__).resolve().parent.parent
    parser.add_argument("--metadata", type=Path, default=repo / "metadata" / "common")
    parser.add_argument("--fonts", type=Path, default=repo / "common" / "fonts")
    parser.add_argument("--strings", type=Path, default=repo / "common" / "figure-strings.yaml")
    parser.add_argument("--glossary", type=Path, default=repo / "glossary.yaml")
    parser.add_argument("--layout", type=Path, default=repo / "common" / "sheet-layout.yaml")
    parser.add_argument("--logo", type=Path, default=repo / "common" / "img" / LOGO_FILE)
    parser.add_argument("--po", type=Path, default=repo / "po")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--language", default=None, help="culture code; omit for the untranslated source")
    parser.add_argument("--sheet", default=None,
                        help="only this form: a stage code such as NEOIPC_STG_BSI, MASTER for the "
                        "composite, or the chart's own stage for the progress chart")
    parser.add_argument(
        "--format",
        choices=("svg", "typst", "both"),
        default="both",
        help="svg is the protocol's figure, typst the source of the printed form. Both are the same "
        "layout, so writing one is a convenience and never a different sheet.",
    )
    parser.add_argument(
        "--include-drafts",
        action="store_true",
        help="use translations a reviewer has not yet confirmed. For REVIEW renders only: a reviewer "
        "cannot approve wording they have never seen on the page, and every catalogue here starts as "
        "drafts. Off by default, because a form built this way is indistinguishable from a finished one.",
    )
    parser.add_argument(
        "--allow-overflow",
        action="store_true",
        help="write a sheet that does not fit its page anyway, for review. Still reports the failure and "
        "still exits non-zero, so a build cannot pass by asking for it.",
    )
    args = parser.parse_args(argv)

    po_path = args.po / f"metadata.{args.language}.po" if args.language else None
    if po_path is not None and not po_path.exists():
        return _fail(f"no catalogue at {po_path}; --language must name a culture the metadata catalogue has")
    catalogue = Catalogue(po_path, drafts=args.include_drafts)
    chrome = load_localized(args.strings, args.language)
    glossary = load_localized(args.glossary, args.language)
    rules = LayoutRules(args.layout)
    logo = Logo(args.logo)

    # Latin first -- see Typeface -- then the language's own script where it needs a second face.
    stems = ["NotoSans"]
    if args.language in SCRIPT_FONTS:
        stems.append(SCRIPT_FONTS[args.language])
    stems.append(MATH_FONT)
    # One stack per variant a style can ask for. A script without an italic of its own -- Devanagari has
    # none, and the tradition it comes from has no such distinction -- simply repeats its upright face,
    # so a note set in it stays legible instead of resolving to nothing.
    faces = {
        (bold, italic): Typeface([Face(args.fonts / f"{stem}-{_variant(stem, bold, italic)}.ttf")
                                  for stem in stems], args.language or "en")
        for bold in (False, True) for italic in (False, True)
    }

    meta = Metadata(args.metadata)
    # The chart reads the stages before the composites claim them, because the stage its rows come from is
    # folded into the master sheet and is no longer a sheet of its own afterwards.
    stage_sheets = build_stage_sheets(meta, catalogue, rules)
    sheets = _apply_composites(stage_sheets, meta, catalogue, rules, chrome)
    chart = build_chart(stage_sheets, rules, chrome)

    # What is drawn, and how each one is drawn: a sheet flows sections down a portrait page, the chart
    # lays a grid across a landscape one. Everything past this point treats them identically -- one
    # column search, one fit check, one coverage check, one pair of outputs.
    forms: list[tuple[Sheet | Chart, Callable[..., list[Shape]], tuple[int, int], str]] = [
        (sheet, layout_sheet, PORTRAIT, f"NeoIPC-Core-{sheet.name}-Sheet") for sheet in sheets
    ]
    if chart is not None:
        forms.append((chart, layout_chart, LANDSCAPE, f"NeoIPC-Core-{chart.name}"))
    if args.sheet:
        forms = [entry for entry in forms if entry[0].code == args.sheet]
        if not forms:
            return _fail(f"no stage with code {args.sheet}")

    args.out.mkdir(parents=True, exist_ok=True)
    suffix = f".{args.language}" if args.language else ""
    written, failures = [], []
    for form, lay_out, page, stem_name in forms:
        composer, body, failure = best_layout(
            form,
            # `page` is bound here rather than captured, so each form is measured against its own
            # orientation instead of whichever one the loop happened to end on.
            lambda width, page=page: Composer(faces, chrome, glossary, rules, logo, args.language,
                                              width, page),
            lay_out,
        )
        if failure is not None:
            failures.append(str(failure))
            # Reviewing a form that does not fit is the only way to decide WHAT to cut, so the file can
            # be written on request -- reported as a failure either way, and the exit status is unchanged.
            if not (args.allow_overflow and body):
                continue
        if composer.missing:
            for font_name, chars in sorted(composer.missing.items()):
                shown = " ".join(f"U+{ord(c):04X} {c!r}" for c in sorted(chars))
                failures.append(f"{form.code}: {font_name} has no glyph for {shown}")
            continue
        if composer.problems:
            failures.extend(f"{form.code}: {problem}" for problem in composer.problems)
            # A defect in an unreviewed translation is what a review render EXISTS to show, so the file is
            # written and the reviewer can see it. The exit status is unchanged either way, so a build
            # still cannot pass by asking for drafts -- the same bargain `--allow-overflow` strikes.
            if not args.include_drafts:
                continue
        # Not `with_suffix`: the stem already ends in the culture code, which is exactly what that would
        # take to be the extension and replace.
        stem = args.out / f"{stem_name}{suffix}"
        # Turned round once, after the page is finished and before either output is written, so both are
        # written from the same placements in this direction as in the other.
        placed = mirror(body, composer.page_w) if composer.rtl else body
        for name, extension, document in OUTPUTS:
            if args.format in ("both", name):
                target = stem.with_name(f"{stem.name}.{extension}")
                target.write_text(document(form, placed, composer), encoding="utf-8", newline="\n")
        # The spare is how much page is left over, and it is the only honest measure of how much longer a
        # translation of this sheet may be before it stops fitting. Reported on every run because the
        # one-page rule is a requirement rather than a preference, and a sheet at 2 mm of headroom passes
        # the same green build as one at 30.
        written.append((stem, (composer.answer_x - MARGIN_X) / 100, composer.spare / 100))

    for line in failures:
        print(f"error: {line}", file=sys.stderr)
    for target, column, spare in written:
        print(f"wrote {target} (answer column {column:.1f} mm, {spare:.1f} mm spare)")
    if catalogue.drafted:
        # Said on every run that used one, because nothing in the artifact shows it. A form drawn partly
        # from drafts is finished-looking and is not finished, and the person holding it is the only one
        # who can tell the difference -- so they have to be told.
        print(f"note: {catalogue.drafted} label(s) came from translations no reviewer has confirmed; "
              f"these forms are for review, not for publication")
    return 1 if failures else 0


def _variant(stem: str, bold: bool, italic: bool) -> str:
    """The file name suffix for one variant of a family.

    Only Noto Sans ships four; the others ship upright faces alone, and asking one of them for an italic
    gets its upright. That is not a stand-in for a file somebody forgot to add. **Neither Devanagari nor
    Hebrew has an italic**: Devanagari has no such tradition and emphasises by other means, and Hebrew's
    historical semi-cursive marks a register rather than emphasis, so an "italic" Hebrew face is a Latin
    convention mechanically applied. Setting the small print upright in those languages is what their
    typography actually calls for, and the distinction it carries in Latin -- against the questions
    around it -- is carried by size in every language anyway.
    """
    if stem in SINGLE_FACE:
        return "Regular"
    if italic and stem == "NotoSans":
        return "BoldItalic" if bold else "Italic"
    return "Bold" if bold else "Regular"


def _fail(message: str) -> int:
    print(f"error: {message}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
