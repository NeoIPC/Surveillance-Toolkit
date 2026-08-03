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
from collections.abc import Callable
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
# One margin, all four sides. They were 12.5 / 10 / 12 mm, which is not a design -- it is three numbers
# that were each plausible on their own. The comments box grows to whatever is left, so the bottom margin
# is exact rather than approximate, and an even border is then simply a matter of using one value.
MARGIN = 1250
MARGIN_X = MARGIN_TOP = MARGIN_BOTTOM = MARGIN
CONTENT_W = PAGE_W - 2 * MARGIN_X

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
COMMENTS_MIN = 1200                     # below this the leftover is a gap, not a usable writing space

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

# Real superscript codepoints rather than a baseline shift, so a marker survives being copied out of the
# PDF and is one character to measure. The font's coverage is checked like any other text on the sheet.
SUPERSCRIPTS = "¹²³⁴⁵⁶⁷⁸⁹"

# A soft hyphen in a source string marks where its word may break; a real hyphen is what gets drawn if a
# break is taken there. The soft one never reaches the renderer.
SOFT_HYPHEN = "­"
HYPHEN = "-"

# Languages this emitter must REFUSE rather than lay out. It has no notion of direction at all: every
# coordinate here runs left to right, marks are placed to the left of the words they belong to, and the
# answer column is measured from the left margin. Given right-to-left text it would produce a sheet that
# is confidently, silently wrong -- and wrong in a way nobody on the team can proof-read.
#
# The refusal is the honest form of "not yet supported": a language may be translated, and its catalogue
# is worth having, but a form that reverses a patient identifier is worse than no form. Removing an entry
# from this set is not the fix; adding direction support is, and this set is what will go when it lands.
# The renderer cannot help either -- the PDF stack applies no bidirectional reordering, see
# docs/data-collection-sheet-generation.md.
RIGHT_TO_LEFT = frozenset({"ar", "arc", "ckb", "dv", "fa", "he", "ks", "ku", "ps", "sd", "ug", "ur", "yi"})

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
        # The notice travels with the artwork. A generated sheet is a distributed file that contains the
        # logo, so stating the rights holder only in the repository's README would leave every copy of it
        # silent about who owns the mark on it.
        return (
            [
                "  <!-- The NeoIPC logo below is owned by Fondazione Penta ETS and is not covered by this",
                "       repository's MIT licence. Confirm any reuse with the NeoIPC/Penta team. -->",
                f'  <symbol id="neoipc-logo" viewBox="{self.view_box}">',
            ]
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
        self.groups: list[dict] = rules.get("groups") or []
        self.omitted: set[str] = set(rules.get("omit") or [])
        self.omitted_suffixes: tuple[str, ...] = tuple(rules.get("omit_suffixes") or ())
        self.row_units: dict[str, str] = rules.get("row_units") or {}

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


def load_chrome(path: Path, language: str | None) -> dict[str, str]:
    """The figure text, taking the localized YAML po4a writes when there is one.

    These strings are NOT looked up in the metadata catalogue. They are extracted from
    common/figure-strings.yaml into the documentation catalogue, and po4a writes the translation back as
    a sibling YAML -- so the translation arrives as a file, not as a msgctxt. An earlier version keyed
    them `sheetStrings/<key>`, a context that appears in no catalogue in this repository, so every
    localized run silently emitted English chrome while looking like it had tried.
    """
    localized = path.with_suffix(f".{language}.yaml") if language else None
    source = localized if localized and localized.exists() else path
    yaml = YAML(typ="safe")
    with source.open(encoding="utf-8") as handle:
        return yaml.load(handle)


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

    def pad_at(self, size: int) -> int:
        """Equal space above the capitals and below the baseline.

        Balancing the full ink box instead -- caps above the baseline, descender below -- is correct
        typographically and looks wrong here, because most labels on a form have no descender at all. The
        reserved space below then reads as emptiness and the row looks top-heavy, which is the same
        complaint as before with the sign reversed. So the padding is symmetric about the baseline, and
        the descender clears INTO the lower half rather than being added beneath it.
        """
        return max(ROW_PAD, self.descent_at(size) + DESCENDER_CLEARANCE)

    def missing(self, text: str) -> set[str]:
        return {ch for ch in text if ord(ch) not in self.cmap and not ch.isspace()}

    def width(self, text: str, size: int) -> float:
        total = 0
        for ch in text.replace(SOFT_HYPHEN, ""):
            glyph = self.cmap.get(ord(ch))
            total += self.widths.get(glyph, self.widths.get(".notdef", 0))
        return total * size / self.units

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

    Carries the SVG body it got to, so `--allow-overflow` can write the sheet for review. Nothing else
    reads it: a normal run discards the body along with the sheet.
    """

    def __init__(self, message: str, body: list[str] | None = None):
        super().__init__(message)
        self.body = body


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
                 language: str | None, label_width: int = LABEL_COL_MAX):
        self.face, self.bold, self.chrome, self.layout = face, bold, chrome, layout
        self.logo, self.language = logo, language
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

    def footnote(self, key: str) -> str:
        """Register a footnote and return the superscript marker that refers to it.

        Numbered in the order they are first needed, so a sheet reads top to bottom, and deduplicated:
        one group repeated across three organism slots is one note, not three identical ones.
        """
        if key not in self.footnotes:
            self.footnotes.append(key)
        return SUPERSCRIPTS[self.footnotes.index(key)]

    def face_of(self, bold: bool) -> Face:
        """The face a run is actually drawn in.

        Labels and child labels are bold, and bold is wider. Measuring them in the regular face
        under-measured every one of them, which is not a rounding error: it decided where the answer
        column could sit, whether a label wrapped, whether two criteria could share a row, and whether the
        sheet was declared to fit -- and it let a fitted label overrun into the column it was fitted
        against, by little enough to look like a rendering artifact rather than a measurement bug.

        Vertical metrics stay with the regular face so every row keeps one rhythm.
        """
        return self.bold if bold else self.face

    def _text(self, text: str, size: int, bold: bool = False) -> None:
        face = self.face_of(bold)
        absent = face.missing(text)
        if absent:
            self.missing.setdefault(face.path.name, set()).update(absent)

    def sheet_svg(self, sheet: Sheet, body: list[str]) -> str:
        head = [
            '<svg version="1.1" viewBox="0 0 %d %d" xmlns="http://www.w3.org/2000/svg" '
            'xmlns:xlink="http://www.w3.org/1999/xlink" role="img">' % (PAGE_W, PAGE_H),
            *self._accessible_names(sheet),
            "  <style>",
            "    text { font-family: 'Noto Sans'; fill: #000; }",
            "    text.title { font-size: %dpx; fill: %s; }" % (TITLE_SIZE, ACCENT),
            "    text.subtitle { font-size: %dpx; fill: %s; }" % (SUBTITLE_SIZE, ACCENT),
            "    text.section { font-size: %dpx; text-anchor: middle; }" % SECTION_SIZE,
            "    text.label { font-size: %dpx; font-weight: bold; }" % LABEL_SIZE,
            "    text.option { font-size: %dpx; }" % OPTION_SIZE,
            "    text.child { font-size: %dpx; font-weight: bold; }" % OPTION_SIZE,
            "    text.legend { font-size: %dpx; font-style: italic; }" % SMALL_SIZE,
            # Every filled block is bounded. An area of colour with no edge has nothing to sit against,
            # so it reads as a stain on the page rather than as a region of the table -- and on a ruled
            # form, where every other block IS bounded, the unbounded one looks like a printing fault.
            "    rect.band { fill: %s; stroke: #000; stroke-width: 12; }" % BAND_FILL,
            "    rect.notransmit { fill: %s; stroke: #000; stroke-width: 12; }" % NOTRANSMIT_FILL,
            # A second, redundant signal: these sheets are printed, frequently in greyscale, where the
            # tint above collapses to a shade barely distinguishable from the section bands. The bar
            # survives that, and survives colour-blindness, which a hue on its own does not.
            "    rect.notransmit-edge { fill: #000; stroke: none; }",
            "    rect.frame { fill: none; stroke: #000; stroke-width: 20; }",
            "    rect.mark { fill: none; stroke: #000; stroke-width: 18; }",
            "    circle.mark { fill: none; stroke: #000; stroke-width: 18; }",
            # Three weights, and the spread between them is what makes the grid readable rather than the
            # absolute values: the frame at 0.20 mm, a row or block boundary at 0.16, and a row inside a
            # block at 0.10. A first attempt used half the row weight for the inner rule, 0.06 mm, which
            # is sub-pixel on screen and marginal on paper -- it was emitted on every sheet and visible on
            # none, which looks exactly like not having been emitted at all.
            "    line.rule { stroke: #000; stroke-width: 16; }",
            # Between two rows of one slot. Every row is a cell of a ruled table, so every row is closed --
            # but a slot and the fields hanging off it are still one thing, and ruling them all alike
            # dissolves that. The lighter stroke closes the cell without breaking up the block.
            "    line.hair { stroke: #000; stroke-width: 10; }",
            # The answer column's own stroke. Drawn per row rather than as one full-height line, because
            # the rows that span the sheet -- a criterion with its tick at the left, a question whose
            # choices are listed beneath it -- have no cell for it to bound, and a line through their
            # text would be a defect rather than a grid. Consecutive bounded rows abut, so the strokes
            # read as one column wherever there actually is one.
            "    line.column { stroke: #000; stroke-width: 16; }",
            # The inlined logo's paths carry these classes. Defined here rather than kept inside the
            # symbol so the sheet has exactly one stylesheet -- and because a symbol whose own <style>
            # was dropped renders in the default fill, which is black, silently.
            "    .brand-blue { fill: %s; }" % ACCENT,
            "    .brand-orange { fill: %s; }" % BRAND_ORANGE,
            "  </style>",
        ] + self.logo.definition()
        return "\n".join(head + body + ["</svg>", ""])

    def _accessible_names(self, sheet: Sheet) -> list[str]:
        """<title> and <desc>, which are what a screen reader announces for the figure.

        An SVG without them is an unlabelled graphic: inlined into the protocol's HTML it reads as
        nothing at all, and accessibility is a stated goal of this toolkit rather than a nicety. The
        description names the sections so a reader who cannot see the sheet still learns its shape.
        """
        sections = ", ".join(s.title for s in sheet.sections)
        return [
            f"  <title>{_esc(self.chrome['sheet_heading'])} — {_esc(sheet.title)}</title>",
            f"  <desc>{_esc(sheet.title)} data collection sheet. Sections: {_esc(sections)}.</desc>",
        ]


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
    out.extend(writer.logo.place(PAGE_W - MARGIN_X - LOGO_W, MARGIN_TOP, LOGO_W))
    out.append(f'  <text id="heading" class="title" x="{MARGIN_X}" y="{y}">{_esc(heading)}</text>')
    y += SUBTITLE_SIZE + 220
    out.append(f'  <text id="{sheet.slug}-title" class="subtitle" x="{MARGIN_X}" y="{y}">{_esc(sheet.title)}</text>')
    y += 400

    table_top = y
    body: list[str] = []
    y = _emit_patient_block(body, y, writer)
    for section in sheet.sections:
        y = _emit_section(body, section, y, writer)

    # Whatever the fields leave over becomes room to write, so the page is used rather than trailing off
    # into white space. The comments band is emitted before the frame is sized so the frame encloses it.
    # Every trailing block is measured, not estimated. Guessing the footer at one line's height left a
    # visible band of unused paper when it wrapped to one line and would have overflowed had it wrapped
    # to three -- and the whole point of the comments box is that it absorbs EXACTLY what is left, so an
    # approximation here is a gap at the bottom of every sheet.
    legend_h = 2 * (MARK + 180) + 500
    footer_h = len(
        _fit(writer, writer.chrome["footer_reference"], SMALL_SIZE, CONTENT_W, "footer", "footer")
    ) * (SMALL_SIZE + 60)
    # Footnotes are part of the budget, not an afterthought. They are known by now -- a collapsed group
    # registers its note while its section is laid out -- and leaving them out let the comments box grow
    # into the space they needed, which turned two sheets that fitted into two that did not.
    notes_h = sum(
        len(_fit(writer, f"{SUPERSCRIPTS[i]} {writer.chrome[k]}", SMALL_SIZE, CONTENT_W, "footnote", k))
        * (SMALL_SIZE + 60)
        for i, k in enumerate(writer.footnotes)
    ) + (200 if writer.footnotes else 0)
    spare = (PAGE_H - MARGIN_BOTTOM - legend_h - footer_h - notes_h) - y
    writer.spare = spare
    if spare > 0:
        # The leftover is ALWAYS absorbed, so the bottom margin equals the other three exactly. Taking it
        # only when it exceeded the minimum meant a sheet with a little space left simply abandoned it --
        # which is why the primary sepsis sheet ended 12 mm higher than the others while every constant
        # said they should match.
        if spare > COMMENTS_MIN:
            # Below that, there is room for the space but not for a heading over it: a label with two
            # millimetres under it invites writing that will not fit.
            writer._text(writer.chrome["comments"], LABEL_SIZE)
            body.append(
                f'  <text class="label" x="{TEXT_X}" y="{y + ROW_PAD + writer.face.cap_at(LABEL_SIZE)}">'
                f'{_esc(writer.chrome["comments"])}</text>'
            )
        y += spare
        body.append(f'  <line class="rule" x1="{MARGIN_X}" y1="{y}" x2="{MARGIN_X + CONTENT_W}" y2="{y}"/>')

    # The frame goes LAST, so it draws on top of everything inside it. Emitted first, every band and
    # shaded block painted over its edges, and the table's outline broke wherever a fill met it -- most
    # visibly down the left side, where the tinted patient block simply erased it.
    out.extend(body)
    out.append(
        f'  <rect class="frame" x="{MARGIN_X}" y="{table_top}" width="{CONTENT_W}" height="{y - table_top}"/>'
    )
    y = _emit_footnotes(out, y, writer)
    y = _emit_legend(out, y, writer)
    y = _emit_footer(out, y, writer)

    usable = PAGE_H - MARGIN_BOTTOM
    if y > usable:
        raise Overflow(
            f"{sheet.code}: content runs to {y} on a page whose usable height ends at {usable} "
            f"({y / usable:.2f} pages). A sheet must fit one page, so this needs a denser layout for "
            f"this stage -- not a second page.",
            out,
        )
    return out


def best_layout(
    sheet: Sheet, make_writer: Callable[[int], SvgWriter]
) -> tuple[SvgWriter, list[str] | None, Overflow | None]:
    """Lay the sheet out at every candidate answer column and keep the roomiest result.

    The column's position cannot be a constant, and the two pressures on it pull opposite ways: move it
    right and long labels stop wrapping, move it left and more choice runs fit on their label's line.
    Which wins depends on the label and option text -- so it depends on the LANGUAGE, and a number tuned
    against English would have to be re-tuned for each of the other eight and would still be wrong for the
    ninth. Since the layout is a pure function of the text, the position is measured the same way
    everything else here is: lay it out, and keep what leaves the most room.

    'Most room' is the comments box, which absorbs whatever the fields leave over -- so maximizing it is
    the same as minimizing the sheet, and it optimizes the property the sheets are actually judged on.
    """
    best: tuple[tuple[int, int, int], SvgWriter, list[str] | None, Overflow | None] | None = None
    for width in range(LABEL_COL_MIN, LABEL_COL_MAX + 1, LABEL_COL_STEP):
        writer = make_writer(width)
        failure: Overflow | None = None
        try:
            body = layout_sheet(sheet, writer)
        except Overflow as overflow:
            body, failure = overflow.body, overflow
        # A column that fits beats one that does not, whatever their spare. Among failures, one that got
        # far enough to measure a page beats one that could not place a word at all.
        score = writer.spare if body is not None else -(10 ** 9)
        # Widest spare wins; a tie goes to the NARROWER label column, which is the same layout with more
        # room to write in. Ties are the normal case once the column clears every label on the sheet.
        key = (0 if failure is None else -1, score, -width)
        if best is None or key > best[0]:
            best = (key, writer, body, failure)
    return best[1], best[2], best[3]


def _emit_legend(out: list[str], y: int, writer: SvgWriter) -> int:
    """What the two markers mean. Every published sheet carries it, and without it the shapes are decor."""
    y += 500
    for radio, key in ((True, "legend_one"), (False, "legend_many")):
        text = writer.chrome[key]
        writer._text(text, SMALL_SIZE)
        _mark(out, f"legend-{'one' if radio else 'many'}", TEXT_X, y + MARK - 20, radio, writer, SMALL_SIZE)
        out.append(f'  <text class="legend" x="{TEXT_X + MARK + MARK_GAP}" y="{y + MARK - 20}">{_esc(text)}</text>')
        y += MARK + 180
    return y


def _emit_footnotes(out: list[str], y: int, writer: SvgWriter) -> int:
    """The notes the collapsed rows point at. A group without its note is a question with no stated rule."""
    for index, key in enumerate(writer.footnotes):
        text = f"{SUPERSCRIPTS[index]} {writer.chrome[key]}"
        writer._text(text, SMALL_SIZE)
        for line in _fit(writer, text, SMALL_SIZE, CONTENT_W, "footnote", key):
            y += SMALL_SIZE + 60
            out.append(f'  <text class="legend" x="{MARGIN_X}" y="{y}">{_esc(line)}</text>')
    return y + (200 if writer.footnotes else 0)


def _emit_footer(out: list[str], y: int, writer: SvgWriter) -> int:
    text = writer.chrome["footer_reference"]
    writer._text(text, SMALL_SIZE)
    for line in _fit(writer, text, SMALL_SIZE, CONTENT_W, "footer", "footer"):
        y += SMALL_SIZE + 60
        out.append(f'  <text class="legend" x="{MARGIN_X}" y="{y}">{_esc(line)}</text>')
    return y


def _emit_patient_block(out: list[str], y: int, writer: SvgWriter) -> int:
    """Who this sheet is about -- on every sheet, because a loose page has to be filed to a patient.

    These two fields exist on the paper and nowhere else. The sheet is completed at a cot side and stays
    in the hospital, so it must name the patient unambiguously; the surveillance dataset must never carry
    that, and the note says so on the page rather than leaving it to the protocol. A person holding a form
    cannot be expected to know which of those two things they are doing.
    """
    title = writer.chrome["section_patient"]
    writer._text(title, SECTION_SIZE)
    out.append(f'  <rect class="band" x="{MARGIN_X}" y="{y}" width="{CONTENT_W}" height="{SECTION_BAND_H}"/>')
    out.append(
        f'  <text id="patient" class="section" x="{PAGE_W // 2}" y="{y + SECTION_BAND_H - 150}">{_esc(title)}</text>'
    )
    y += SECTION_BAND_H

    # The shaded block is laid down first so the rows and the note draw over it; its height is only known
    # once they are measured, so the rect is patched in afterwards at a remembered index.
    block_top = y
    shading = len(out)
    out.append("")
    out.append("")

    for key in ("patient_identifier", "patient_name"):
        label = writer.chrome[key]
        writer._text(label, LABEL_SIZE, bold=True)
        top = y
        y += writer.face.pad_at(LABEL_SIZE)
        for line in _fit(writer, label, LABEL_SIZE, writer.answer_x - COLUMN_GAP - TEXT_X, key, "label",
                         bold=True):
            out.append(f'  <text class="label" x="{TEXT_X}" y="{y + writer.face.cap_at(LABEL_SIZE)}">{_esc(line)}</text>')
            y += LABEL_SIZE + LINE_GAP
        y += writer.face.pad_at(LABEL_SIZE) - LINE_GAP
        # Written on the same column as every other answer, and on the rule closing the row. These two
        # rows are where the sheet's grid is established for its reader, so they follow it rather than
        # setting a second convention at the top of the page.
        _column(out, top, y, writer)
        out.append(f'  <line class="rule" x1="{MARGIN_X}" y1="{y}" x2="{MARGIN_X + CONTENT_W}" y2="{y}"/>')

    note = writer.chrome["patient_note"]
    writer._text(note, SMALL_SIZE)
    y += writer.face.pad_at(SMALL_SIZE)
    for line in _fit(writer, note, SMALL_SIZE, CONTENT_W - 360, "patient_note", "note"):
        out.append(f'  <text class="legend" x="{TEXT_X}" y="{y + writer.face.cap_at(SMALL_SIZE)}">{_esc(line)}</text>')
        y += SMALL_SIZE + LINE_GAP
    y += writer.face.pad_at(SMALL_SIZE) - LINE_GAP
    out.append(f'  <line class="rule" x1="{MARGIN_X}" y1="{y}" x2="{MARGIN_X + CONTENT_W}" y2="{y}"/>')

    height = y - block_top
    out[shading] = (
        f'  <rect class="notransmit" x="{MARGIN_X}" y="{block_top}" width="{CONTENT_W}" height="{height}"/>'
    )
    out[shading + 1] = (
        f'  <rect class="notransmit-edge" x="{MARGIN_X}" y="{block_top}" width="{NOTRANSMIT_BAR}" '
        f'height="{height}"/>'
    )
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

    rows = _pair_ticks(_collapse_groups(section.fields, writer), writer)
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
            y = _emit_tick_pair(out, row, y, writer)
        else:
            emit = _emit_child if row[0].is_child else _emit_field
            y = emit(out, row[0], y, writer, closes)
        weight = "rule" if closes else "hair"
        out.append(f'  <line class="{weight}" x1="{MARGIN_X}" y1="{y}" x2="{MARGIN_X + CONTENT_W}" y2="{y}"/>')
    return y


def _is_tick(field: Field, writer: SvgWriter) -> bool:
    """A criterion marked with a single box on its own line, with no answer beside it."""
    return (not field.is_child and not field.options
            and writer.layout.boolean_style(field) == "tick")


def _pair_ticks(fields: list[Field], writer: SvgWriter) -> list[tuple[Field, ...]]:
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
    half = (CONTENT_W - 2 * TEXT_INSET) // 2

    def fits(field: Field) -> bool:
        label = field.label + (f" ({writer.chrome['required']})" if field.compulsory else "")
        return writer.bold.width(label, LABEL_SIZE) + MARK + MARK_GAP + PAIR_GUTTER <= half

    rows: list[tuple[Field, ...]] = []
    index = 0
    while index < len(fields):
        following = fields[index + 1] if index + 1 < len(fields) else None
        after = fields[index + 2] if index + 2 < len(fields) else None
        if (following is not None and _is_tick(fields[index], writer) and _is_tick(following, writer)
                and (after is None or not after.is_child)
                and fits(fields[index]) and fits(following)):
            rows.append((fields[index], following))
            index += 2
        else:
            rows.append((fields[index],))
            index += 1
    return rows


def _emit_tick_pair(out: list[str], pair: tuple[Field, ...], y: int, writer: SvgWriter) -> int:
    """Two criteria side by side, on the same baseline, each on its own column."""
    y += writer.face.pad_at(LABEL_SIZE)
    baseline = y + writer.face.cap_at(LABEL_SIZE)
    for field, x in zip(pair, (TEXT_X, MARGIN_X + CONTENT_W // 2)):
        label = field.label + (f" ({writer.chrome['required']})" if field.compulsory else "")
        writer._text(label, LABEL_SIZE, bold=True)
        _mark(out, _ident(field), x, baseline, False, writer, LABEL_SIZE)
        out.append(
            f'  <text class="label" x="{x + MARK + MARK_GAP}" y="{baseline}">{_esc(label)}</text>'
        )
    return y + LABEL_SIZE + writer.face.pad_at(LABEL_SIZE)


def _collapse_groups(fields: list[Field], writer: SvgWriter) -> list[Field]:
    """Replace each run of grouped fields with the single row the form prints for them.

    The run must be CONSECUTIVE and share a slot prefix. Grouping across a gap would silently reorder the
    form relative to the data model, and grouping across slots would put one organism's answer on
    another's line -- both of which read as a working sheet.
    """
    fields = [f for f in fields if writer.layout.prints(f)]

    # Fold a continuation onto the row before it, before any grouping runs: a field that is part of
    # another's row is not a row of its own and must not be counted as one.
    folded: list[Field] = []
    for field in fields:
        unit = writer.layout.continues_row(folded[-1] if folded else None, field, writer.chrome)
        if unit is None:
            folded.append(field)
        else:
            folded[-1].trailing = unit
    fields = folded

    out: list[Field] = []
    index = 0
    while index < len(fields):
        field = fields[index]
        group = writer.layout.group_of(field)
        if group is None:
            out.append(field)
            index += 1
            continue

        prefix = field.code.rsplit("_", 1)[0]
        run = [field]
        while index + len(run) < len(fields):
            candidate = fields[index + len(run)]
            if writer.layout.group_of(candidate) is not group or not candidate.code.startswith(prefix):
                break
            run.append(candidate)

        marker = writer.footnote(group["footnote_key"])
        out.append(
            Field(
                code=f"{prefix}_{'_'.join(group['suffixes'])}",
                # The '- ' keeps it a child of the slot it belongs to, exactly as its members were.
                label=f"- {writer.chrome[group['label_key']]}{marker}",
                value_type=run[0].value_type,
                compulsory=any(f.compulsory for f in run),
                options=run[0].options,
                radio=run[0].radio,
            )
        )
        index += len(run)
    return out


def _emit_child(out: list[str], field: Field, y: int, writer: SvgWriter, closes_group: bool = True) -> int:
    """A sub-field on one line: its short label, then its answer at the sheet's answer column.

    This is where the page is won. Nine fields per organism slot, each given a label row and its own
    option rows underneath, is most of two pages for one section; the same nine as compact lines under
    their slot header is a block.

    The answer starts at the column rather than after the label, which is what makes a slot read as a
    block at all: with each row starting its marks wherever its own label ended, an organism's three
    resistance rows stepped visibly rightwards down the sheet and no two rows agreed on anything.
    """
    label = field.short_label
    writer._text(label, OPTION_SIZE, bold=True)
    top = y
    y += writer.face.pad_at(OPTION_SIZE) // 2

    x = TEXT_X + OPTION_INDENT
    baseline = y + writer.face.cap_at(OPTION_SIZE)
    for line in _fit(writer, label, OPTION_SIZE, writer.answer_x - COLUMN_GAP - x, field.code, "label",
                     bold=True):
        out.append(f'  <text class="child" x="{x}" y="{baseline}">{_esc(line)}</text>')
        baseline += OPTION_SIZE + LINE_GAP
    baseline -= OPTION_SIZE + LINE_GAP
    right = MARGIN_X + CONTENT_W - 180

    options, radio = field.options, field.radio
    if not options and not field.write_in:
        style = writer.layout.boolean_style(field)
        if style == "yes_no":
            options, radio = [writer.chrome["boolean_yes"], writer.chrome["boolean_no"]], True
        elif style == "tick":
            _mark(out, _ident(field), writer.answer_text_x, baseline, False, writer)
            return _column(out, top, baseline + writer.face.pad_at(OPTION_SIZE), writer)

    if not options:
        # Bounded by the grid, like every other cell.
        return _column(out, top, baseline + writer.face.pad_at(OPTION_SIZE), writer)

    for option in options:
        writer._text(option, OPTION_SIZE)
    widths = [writer.face.width(option, OPTION_SIZE) for option in options]
    needed = sum(w + MARK + MARK_GAP for w in widths) + OPTION_SEP * (len(options) - 1)
    if writer.answer_text_x + needed > right:
        # The choices will not share the label's line, so fall back to the indented block a parent uses,
        # which has the full width to wrap into. That block spans the column, so no stroke is drawn.
        return _emit_options(out, field, options, radio, baseline + LINE_GAP, writer)

    ident = _ident(field)
    x = writer.answer_text_x
    for index, option in enumerate(options):
        _mark(out, f"{ident}-{index + 1}", int(x), baseline, radio, writer)
        out.append(f'  <text class="option" x="{int(x + MARK + MARK_GAP)}" y="{baseline}">{_esc(option)}</text>')
        x += MARK + MARK_GAP + widths[index] + OPTION_SEP
    return _column(out, top, baseline + LINE_GAP, writer)


def _emit_field(out: list[str], field: Field, y: int, writer: SvgWriter, closes_group: bool = True) -> int:
    """One field is one full-width row: bold label, then whatever it needs to be answered."""
    label = field.label + (f" ({writer.chrome['required']})" if field.compulsory else "")
    writer._text(label, LABEL_SIZE, bold=True)
    style = writer.layout.boolean_style(field)

    options, radio = field.options, field.radio
    if not options and style == "yes_no":
        options = [writer.chrome["boolean_yes"], writer.chrome["boolean_no"]]
        radio = True

    # Choices short enough to sit on their label's own line do so, at the answer column, instead of taking
    # an indented row beneath it. A Yes/No pair given a row of its own costs the same height as a
    # paragraph, and the sheets that overflow are full of them.
    #
    # It is measured rather than decided, so the same field moves back below its label in a language whose
    # options are longer -- which is why the inconsistency this introduces is tolerable: it is not "short
    # ones are treated differently", it is "each row uses the space it has".
    widths = [writer.face.width(option, OPTION_SIZE) for option in options]
    needed = (sum(w + MARK + MARK_GAP for w in widths) + OPTION_SEP * (len(options) - 1)) if options else 0
    inline = bool(options) and writer.answer_text_x + needed <= MARGIN_X + CONTENT_W - TEXT_INSET

    # A row is either answered ON its own line -- a space to write in, or a choice run, both starting at
    # the answer column -- or it spans the sheet: a criterion whose tick sits at the left, or a question
    # whose choices are too long and are listed beneath it. Only the first kind has a cell, so only that
    # kind is bounded by the column, and only that kind gives up label width to it.
    answered_here = style != "tick" and (not options or inline)

    top = y
    y += writer.face.pad_at(LABEL_SIZE)
    label_x = TEXT_X
    if style == "tick":
        # The tick sits on the label's own line: a criterion in a list reads as one thing to mark, not as
        # a question followed by an answer. This is the shape the published sheets use for every
        # signs-and-symptoms and laboratory-findings element.
        _mark(out, _ident(field), TEXT_X, y + writer.face.cap_at(LABEL_SIZE), False, writer, LABEL_SIZE)
        label_x = TEXT_X + MARK + MARK_GAP

    edge = writer.answer_x - COLUMN_GAP if answered_here else MARGIN_X + CONTENT_W - 180
    baseline = y + writer.face.cap_at(LABEL_SIZE)
    for line in _fit(writer, label, LABEL_SIZE, edge - label_x, field.code, "label", bold=True):
        out.append(f'  <text class="label" x="{label_x}" y="{baseline}">{_esc(line)}</text>')
        y += LABEL_SIZE + LINE_GAP
        baseline += LABEL_SIZE + LINE_GAP
    y -= LINE_GAP
    baseline -= LABEL_SIZE + LINE_GAP

    if field.trailing:
        return _emit_paired_row(out, field, top, y, baseline, writer, closes_group)

    if inline:
        ident = _ident(field)
        x = writer.answer_text_x
        for index, option in enumerate(options):
            writer._text(option, OPTION_SIZE)
            _mark(out, f"{ident}-{index + 1}", int(x), baseline, radio, writer)
            out.append(
                f'  <text class="option" x="{int(x + MARK + MARK_GAP)}" y="{baseline}">{_esc(option)}</text>'
            )
            x += MARK + MARK_GAP + widths[index] + OPTION_SEP
        return _column(out, top, y + writer.face.pad_at(LABEL_SIZE), writer)

    if options:
        return _emit_options(out, field, options, radio, y + LINE_GAP, writer) + writer.face.pad_at(LABEL_SIZE)

    y += writer.face.pad_at(LABEL_SIZE)
    if answered_here:
        # No writing line: the cell is the box formed by the frame, the column and the rules above and
        # below this row. Drawing one inside it would either double the rule beneath or float in the
        # middle of the cell, and both were tried.
        _column(out, top, y, writer)
    return y


def _emit_paired_row(out: list[str], field: Field, top: int, y: int, baseline: int, writer: SvgWriter,
                     closes_group: bool) -> int:
    """A row carrying two values -- an antibiotic substance and the number of days it was given.

    Both are written on the rule that closes the row, so the row shows one line at its foot instead of a
    writing rule sitting just above the rule beneath it. What divides the two cells is a vertical stroke
    of the same weight and kind as the answer column's, so the row reads as three cells of one table
    rather than as two underscores floating in it.
    """
    writer._text(field.trailing, LABEL_SIZE, bold=True)
    right = MARGIN_X + CONTENT_W - 180
    unit_x = int(right - writer.bold.width(field.trailing, LABEL_SIZE))
    divider = unit_x - 2400
    # The unit word sits on the label's own baseline. Placing it at the row's foot instead dropped it
    # below every other word on its line by the difference between the font size and the cap height.
    out.append(f'  <text class="label" x="{unit_x}" y="{baseline}">{_esc(field.trailing)}</text>')

    bottom = y + writer.face.pad_at(LABEL_SIZE)
    _column(out, top, bottom, writer)
    out.append(f'  <line class="column" x1="{divider}" y1="{top}" x2="{divider}" y2="{bottom}"/>')
    return bottom


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
    inline = sum(w + MARK + MARK_GAP for w in widths) + OPTION_SEP * (len(options) - 1)

    if inline <= available:
        x = left
        for index, option in enumerate(options):
            _mark(out, f"{ident}-{index + 1}", int(x), y + writer.face.cap_at(OPTION_SIZE), radio, writer)
            out.append(f'  <text class="option" x="{int(x + MARK + MARK_GAP)}" y="{y + writer.face.cap_at(OPTION_SIZE)}">{_esc(option)}</text>')
            x += MARK + MARK_GAP + widths[index] + OPTION_SEP
        return y + OPTION_SIZE + LINE_GAP

    for index, option in enumerate(options):
        _mark(out, f"{ident}-{index + 1}", left, y + writer.face.cap_at(OPTION_SIZE), radio, writer)
        text_x = left + MARK + MARK_GAP
        for line in _fit(writer, option, OPTION_SIZE, available - MARK - MARK_GAP, field.code, f"option {index + 1}"):
            out.append(f'  <text class="option" x="{text_x}" y="{y + writer.face.cap_at(OPTION_SIZE)}">{_esc(line)}</text>')
            y += OPTION_SIZE + LINE_GAP
    return y


def _mark(out: list[str], ident: str, x: int, baseline: int, radio: bool, writer: SvgWriter,
          size: int = OPTION_SIZE) -> None:
    """A choose-one circle or a choose-any square, centred on the text it belongs to.

    Takes the text's BASELINE, not a row offset. The mark has to sit on the optical middle of the band
    the letters occupy -- between the baseline and the cap height -- and that band moved when rows began
    being measured from the face. Placed from the row's top instead, every mark drifted low and the
    drift grew with the size of the text beside it.
    """
    centre = baseline - writer.face.cap_at(size) // 2
    if radio:
        r = MARK // 2
        out.append(f'  <circle id="{ident}" class="mark" cx="{x + r}" cy="{centre}" r="{r}"/>')
    else:
        out.append(
            f'  <rect id="{ident}" class="mark" x="{x}" y="{centre - MARK // 2}" '
            f'width="{MARK}" height="{MARK}"/>'
        )


def _column(out: list[str], top: int, bottom: int, writer: SvgWriter) -> int:
    """Bound one row's answer cell on the left, and return the row's foot so callers can `return` it.

    Drawn per row rather than as one line down the sheet, because the rows that span it have no cell for
    it to bound and a stroke through their text would be a defect rather than a grid.
    """
    out.append(
        f'  <line class="column" x1="{writer.answer_x}" y1="{top}" x2="{writer.answer_x}" y2="{bottom}"/>'
    )
    return bottom


def _ident(field: Field) -> str:
    """The element's own code as an SVG id -- semantic, and traceable back to the metadata."""
    return field.code.lower().replace("_", "-")


def _fit(writer: SvgWriter, text: str, size: int, width: int, code: str, what: str,
         bold: bool = False) -> list[str]:
    """Wrap to the cell, and refuse to emit anything that still does not fit.

    `wrap` cannot break inside a word, so a single token wider than the cell comes back as its own
    over-long line. That is the German-compound case, and emitting it anyway is precisely what the XSLT
    wrapper did -- silently, because character counting cannot tell that it happened.
    """
    face = writer.face_of(bold)
    lines = face.wrap(text, size, width)
    widest = max(face.width(line, size) for line in lines)
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
    parser.add_argument("--strings", type=Path, default=repo / "common" / "figure-strings.yaml")
    parser.add_argument("--layout", type=Path, default=repo / "common" / "sheet-layout.yaml")
    parser.add_argument("--logo", type=Path, default=repo / "common" / "img" / LOGO_FILE)
    parser.add_argument("--po", type=Path, default=repo / "po")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--language", default=None, help="culture code; omit for the untranslated source")
    parser.add_argument("--sheet", default=None, help="only this stage code, e.g. NEOIPC_STG_BSI")
    parser.add_argument(
        "--allow-overflow",
        action="store_true",
        help="write a sheet that does not fit its page anyway, for review. Still reports the failure and "
        "still exits non-zero, so a build cannot pass by asking for it.",
    )
    args = parser.parse_args(argv)

    if args.language in RIGHT_TO_LEFT:
        return _fail(
            f"{args.language} is written right to left and this generator lays out left to right only. "
            "It would emit a sheet that looks finished and reads backwards, which is worse than emitting "
            "none. Adding direction support is what unblocks this -- not removing the language."
        )

    po_path = args.po / f"metadata.{args.language}.po" if args.language else None
    if po_path is not None and not po_path.exists():
        return _fail(f"no catalogue at {po_path}; --language must name a culture the metadata catalogue has")
    catalogue = Catalogue(po_path)
    chrome = load_chrome(args.strings, args.language)
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
        writer, body, failure = best_layout(
            sheet, lambda width: SvgWriter(face, bold, chrome, rules, logo, args.language, width)
        )
        if failure is not None:
            failures.append(str(failure))
            # Reviewing a sheet that does not fit is the only way to decide WHAT to cut, so the file can
            # be written on request -- reported as a failure either way, and the exit status is unchanged.
            if not (args.allow_overflow and body):
                continue
        if writer.missing:
            for font_name, chars in sorted(writer.missing.items()):
                shown = " ".join(f"U+{ord(c):04X} {c!r}" for c in sorted(chars))
                failures.append(f"{sheet.code}: {font_name} has no glyph for {shown}")
            continue
        target = args.out / f"NeoIPC-Core-{sheet.slug}-Sheet{suffix}.svg"
        target.write_text(writer.sheet_svg(sheet, body), encoding="utf-8", newline="\n")
        # The spare is how much page is left over, and it is the only honest measure of how much longer a
        # translation of this sheet may be before it stops fitting. Reported on every run because the
        # one-page rule is a requirement rather than a preference, and a sheet at 2 mm of headroom passes
        # the same green build as one at 30.
        written.append((target, (writer.answer_x - MARGIN_X) / 100, writer.spare / 100))

    for line in failures:
        print(f"error: {line}", file=sys.stderr)
    for target, column, spare in written:
        print(f"wrote {target} (answer column {column:.1f} mm, {spare:.1f} mm spare)")
    return 1 if failures else 0


def _fail(message: str) -> int:
    print(f"error: {message}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
