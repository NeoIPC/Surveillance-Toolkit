#!/usr/bin/env python3
"""Regression test for build-collection-sheets.py: it runs the generator and inspects what it wrote.

Three properties the design of record names as checks, all of which were run by hand until now — which
means each held on the last day somebody remembered to look, and says nothing about today.

**Every sheet fits one page.** This is the generator's own gate and the reason it measures text at all,
so it has to be exercised without `--allow-overflow`: that switch still reports the failure and still
exits non-zero, but a test that passes it would be asserting the escape hatch rather than the rule.
Counting pages in the compiled document cannot substitute — every element is placed out of flow, so
content past the bottom edge is clipped rather than paginated, and the page count is one either way.

**Regenerating produces identical bytes.** The reviewable property is that a maintainer can open a
generated file and read it, and that rests on the generator carrying no hidden state — no set iteration
order, no dictionary ordering, no clock. A generator that fails this has a defect whether or not anyone
would have noticed, which is why the same property is demanded of the PDF engine and why one taking its
document ID from the wall clock was disqualified.

**The house style holds.** Semantic ids, presentation in classes, integer coordinates on one grid, no
transforms, no editor namespace. These are what make the output readable rather than merely correct, and
they are exactly the things a later change makes no noise about breaking.

A localized run is covered too, and deliberately with German — the one target language whose catalogue is
committed here, so the test needs no network and no fixture of its own.
"""

from __future__ import annotations

import csv
import importlib.util
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
GENERATOR = REPO / "scripts" / "build-collection-sheets.py"
SVG_NS = "http://www.w3.org/2000/svg"
XML_NS = "http://www.w3.org/XML/1998/namespace"
# Six reporting sheets and the progress chart. The chart is one of the family rather than a thing beside
# it: same generator, same page furniture, same one-page rule -- turned on its side.
SHEETS = 7


def generator_module():
    """Import the generator so a function can be exercised directly rather than through the CLI.

    Needed because the file name carries hyphens, which `import` cannot spell. Used for the properties
    that no rendered file can show -- what mirroring does to a landscape page, above all, since no
    right-to-left catalogue is committed here to render one from.
    """
    spec = importlib.util.spec_from_file_location("build_collection_sheets", GENERATOR)
    module = importlib.util.module_from_spec(spec)
    # Registered BEFORE it is executed: `@dataclass` resolves a field's annotation by looking its own
    # module up in sys.modules, so a module that is not there yet fails while defining `Field`.
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def generate(out: Path, *extra: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(GENERATOR), "--out", str(out), *extra],
        capture_output=True, text=True, encoding="utf-8", cwd=REPO,
    )


SKELETONS = REPO / "doc" / "protocol" / "figures"


def sheet_files(directory: Path, extension: str = "svg") -> list[Path]:
    """The forms, excluding everything else the same run writes into the same place.

    A culture's image directory holds every image the protocol needs, so a run also leaves the AWaRe
    badges and the figures that are DRAWN rather than derived there. Neither is a sheet -- no page, no
    grid, no printed form -- and matching them here would judge them against rules written for something
    else: a decision flow is arrows, so it is path soup by construction.

    Which files those are is derived rather than listed: a drawn figure is one whose skeleton is in
    doc/protocol/figures, so the title page and the watermark drop out of these tests when they arrive
    without anyone remembering to exclude them.
    """
    drawn = {path.name for path in SKELETONS.glob("*.svg")}
    return sorted(path for path in directory.glob(f"NeoIPC-Core-*.{extension}")
                  if path.with_suffix(".svg").name not in drawn)


def figure_files(directory: Path) -> list[Path]:
    """The drawn figures a run produced, matched to the skeletons they came from."""
    drawn = {path.name for path in SKELETONS.glob("*.svg")}
    return sorted(path for path in directory.glob("*.svg") if path.name in drawn)


@pytest.fixture(scope="module")
def english(tmp_path_factory: pytest.TempPathFactory) -> Path:
    out = tmp_path_factory.mktemp("sheets-en")
    result = generate(out)
    assert result.returncode == 0, f"the generator failed:\n{result.stdout}\n{result.stderr}"
    return out


def test_every_sheet_fits_one_page(english: Path) -> None:
    """No --allow-overflow, so this is the real gate rather than the escape hatch."""
    assert len(sheet_files(english)) == SHEETS
    assert len(sheet_files(english, "typ")) == SHEETS


def test_a_localized_run_fits_too(tmp_path: Path) -> None:
    """German, whose catalogue is committed here — the compounding language most likely to overflow."""
    result = generate(tmp_path / "de", "--language", "de")
    assert result.returncode == 0, f"the German sheets do not fit:\n{result.stdout}\n{result.stderr}"
    assert len(sheet_files(tmp_path / "de")) == SHEETS


def test_regenerating_produces_identical_bytes(english: Path, tmp_path: Path) -> None:
    again = tmp_path / "again"
    assert generate(again).returncode == 0
    first = {p.name: p.read_bytes() for p in english.iterdir() if p.is_file()}
    second = {p.name: p.read_bytes() for p in again.iterdir() if p.is_file()}
    assert first.keys() == second.keys()
    differing = sorted(name for name in first if first[name] != second[name])
    assert not differing, (f"{len(differing)} file(s) differ between two runs over unchanged inputs, so "
                           f"the generator carries hidden state: {differing}")


@pytest.mark.parametrize("pattern, what", [
    (r'transform="matrix\(', "a transform matrix"),
    (r'\sstyle="', "per-element styling instead of a class"),
    (r'xmlns:(inkscape|sodipodi|serif)', "an editor's namespace"),
    (r'<path\b', "path soup where a rect or a line is meant"),
])
def test_house_style(english: Path, pattern: str, what: str) -> None:
    """Read one sheet the way a maintainer would, and refuse what makes that impossible.

    The logo is excluded: it is real artwork inlined as a <symbol>, so its paths are drawing rather than
    a generator's laziness. Everything after it is the generator's own output.
    """
    offenders = []
    for sheet in sheet_files(english):
        body = sheet.read_text(encoding="utf-8").split("</symbol>", 1)[-1]
        if re.search(pattern, body):
            offenders.append(sheet.name)
    assert not offenders, f"{what} in {offenders}"


def test_the_logo_carries_its_fills_where_a_stylesheet_may_not_reach(english: Path) -> None:
    """The mark must not depend on a document stylesheet reaching inside a <symbol>.

    Renderers disagree about whether it does, and Inkscape does not apply it -- so a mark styled by class
    alone opens black there, with nothing to say so. prawn-svg and browsers do apply it, which is why
    every sheet rendered so far has a coloured logo and why this cannot be caught by looking at one.
    The colours come from the generator rather than being restated here, so the two cannot drift.
    """
    fills = generator_module().Logo.FILLS
    for sheet in sheet_files(english):
        symbol = ET.fromstring(sheet.read_text(encoding="utf-8")).find(f"{{{SVG_NS}}}symbol")
        assert symbol is not None, f"{sheet.name} inlines no logo"
        classed = [el for el in symbol.iter() if el.get("class") in fills]
        assert classed, f"{sheet.name}: the inlined logo carries no brand class at all"
        unpainted = [el.get("class") for el in classed if el.get("fill") != fills[el.get("class")]]
        assert not unpainted, (f"{sheet.name}: {len(unpainted)} logo path(s) state their colour only as a "
                               f"class, so they render black wherever the stylesheet is not applied")


def test_coordinates_are_integers_on_one_grid(english: Path) -> None:
    """A fractional coordinate means something bypassed the grid the whole layout is expressed in."""
    fractional: list[str] = []
    for sheet in sheet_files(english):
        body = sheet.read_text(encoding="utf-8").split("</symbol>", 1)[-1]
        fractional += [f"{sheet.name}: {m.group(0)}"
                       for m in re.finditer(r'\b(?:x|y|x1|y1|x2|y2|cx|cy|width|height)="\d+\.\d+"', body)]
    assert not fractional, f"coordinates off the grid: {fractional[:5]}"


# ── The progress chart ──────────────────────────────────────────────────────────────────────────────


def chart(directory: Path) -> str:
    return (directory / "NeoIPC-Core-Patient-Progress-Chart.svg").read_text(encoding="utf-8")


def test_the_chart_holds_every_day_count_the_stage_has(english: Path) -> None:
    """The rows must be exactly the stage's day counts -- not a subset that happens to look complete.

    This is the chart's sharpest failure mode and the reason it is derived rather than drawn: a MISSING
    row on a grid looks exactly like a grid. There is no gap, no stray label, no failed measurement and
    nothing for a proof-reader to catch, so a day count added to the stage would simply stop being
    tallied, on paper, silently.

    Compared against the metadata rather than against a list kept here, because a list kept here is the
    same defect one level up. If this goes red because a field was added, that is the test working: put
    the new row on the chart, or record deliberately why a day count is not tallied.
    """
    with (REPO / "metadata" / "common" / "dataElements.csv").open(encoding="utf-8", newline="") as handle:
        expected = {row["code"] for row in csv.DictReader(handle)
                    if row["code"].startswith("NEOIPC_SURVEILLANCE_END_") and row["code"].endswith("_DAYS")}
    module = generator_module()
    # Ids are qualified by the form, because these figures are inlined into one HTML document and an id
    # has to be unique there rather than in its own file.
    ids = set(re.findall(r'<text id="patient-progress-chart-(neoipc-surveillance-end-[a-z0-9-]*-days)"',
                         chart(english)))
    assert {module._slug(code) for code in expected} == ids


def test_the_chart_is_landscape_and_the_sheets_are_not(english: Path) -> None:
    """A month of columns does not fit a portrait page, which is why the page size travels per form."""
    assert 'viewBox="0 0 29700 21000"' in chart(english)
    sheet = (english / "NeoIPC-Core-BSI-Sheet.svg").read_text(encoding="utf-8")
    assert 'viewBox="0 0 21000 29700"' in sheet


def test_the_chart_carries_no_legend(english: Path) -> None:
    """The legend explains a circle and a square. This page has neither, so it would explain nothing.

    Read off the emitted marks rather than declared per form, so a sheet that lost its options would drop
    its legend too instead of printing a key to shapes it no longer has.
    """
    legend = "You can select only one option."
    assert legend not in chart(english)
    assert legend in (english / "NeoIPC-Core-BSI-Sheet.svg").read_text(encoding="utf-8")


def test_the_chart_grid_does_not_grow_with_the_script(english: Path, tmp_path: Path) -> None:
    """Its rows are sized for a HAND, and a hand is taller than the type in any script shipped here.

    That is what makes the grid's height independent of the language -- the 0.68 mm per row a Devanagari
    translation costs every reporting sheet costs the chart nothing. Measured, not assumed: at a label
    size of 300, Noto Sans and Noto Sans Hebrew both want 526 for a row and Noto Sans Devanagari 594, so
    the property holds for any floor at or above 594 and breaks below it. A face for a script with deeper
    marks than Devanagari would turn this red, which is the point of asserting it rather than trusting the
    arithmetic to stay true as fonts are added.
    """
    assert generate(tmp_path / "ne", "--language", "ne", "--format", "svg").returncode == 0
    pitches = {lang: _grid_pitches(text) for lang, text in
               (("en", chart(english)), ("ne", chart(tmp_path / "ne")))}
    assert pitches["en"] == pitches["ne"], f"the grid changed height with the script: {pitches}"
    assert len(set(pitches["en"])) == 1, f"the grid has more than one row pitch: {sorted(set(pitches['en']))}"


def _grid_pitches(svg: str) -> list[int]:
    """The gaps between the full-width rules, less the four above the grid and the comments box below.

    The left edge comes from the generator rather than being written here: hard-coded, it silently matches
    nothing when the margin changes, and every comparison built on it then passes on two empty lists.
    """
    left = generator_module().MARGIN_X
    ys = sorted({int(m) for m in re.findall(rf'<line class="rule" x1="{left}" y1="(\d+)"', svg)})
    pitches = [b - a for a, b in zip(ys, ys[1:])][4:-1]
    assert pitches, "no grid rows found; the rule that finds them no longer matches the generator's output"
    return pitches


def test_the_totals_marker_centres_on_the_day_numbers(english: Path) -> None:
    """A symbol among numbers is aligned to their optical centre, not dropped on their baseline.

    U+2211 shares the digits' cap height and reaches 240 thousandths of an em BELOW the baseline, because
    an n-ary operator is drawn about the maths axis. Set on the numbers' own baseline it sags by that
    much. Asserted on the ink rather than on the placement, so it stays true if the marker, the face or
    the size changes -- and it is measurably false without the lift, which is the point of having it.
    """
    module = generator_module()
    svg = chart(english)
    placed = {text: int(y) for y, text in
              re.findall(r'<text class="day" x="-?\d+" y="(\d+)">([^<]*)</text>', svg)}
    marker = next(t for t in placed if not t.isdigit())
    faces = [module.Face(Path("common/fonts") / f"{stem}-Regular.ttf")
             for stem in ("NotoSans", module.MATH_FONT)]
    typeface = module.Typeface(faces)
    size = module.STYLES["day"].size

    def centre(text: str) -> float:
        top = placed[text]
        return top - max(face.ink_centre(run) for face, run in typeface._runs(text)) * size

    assert abs(centre(marker) - centre("31")) <= 1, (
        f"{marker!r} sits {centre(marker) - centre('31'):.1f} units off the day numbers' optical centre")


# ── The AWaRe badges ────────────────────────────────────────────────────────────────────────────────
#
# Exercised through the functions rather than through rendered files, and deliberately: the committed
# glossaries translate none of the three categories, so every catalogue here yields A, W and R and a test
# reading the output would pass whether or not the derivation worked at all.


def badge_rules(letters: dict | None = None):
    """The real layout rules, with an optional per-language letter override written in."""
    module = generator_module()
    rules = module.LayoutRules(REPO / "common" / "sheet-layout.yaml")
    if letters is not None:
        rules.badge_letters = letters
    return rules


@pytest.mark.parametrize("term, language, expected, why", [
    ("Precaución", "es", "P", "WHO's own Spanish for Watch, whose badge reads P and not W"),
    ("Access", "en", "A", "the untranslated case, which every committed glossary is in"),
    ("ihtiyat", "tr", "İ", "Turkish capitalises i with its dot; the Unicode default gives a plain I"),
    ("ihtiyat", "en", "I", "and the same word in a language without that rule keeps the plain capital"),
    ("पहुँच", "ne", "प", "Devanagari is caseless, so the initial comes back exactly as written"),
    ("किताब", "ne", "कि", "a vowel sign belongs to the consonant it is written on, so both come"),
])
def test_a_badge_letter_is_the_category_initial(term, language, expected, why) -> None:
    """The letter is derived from the glossary term, upper-cased in that language's own rules."""
    module = generator_module()
    glossary = {"watch": term, "access": term}
    letter = module.badge_letter("Watch", glossary, badge_rules(), language)
    assert letter == expected, f"{why}: {term!r} in {language} gave {letter!r}, not {expected!r}"


def test_a_recorded_letter_overrides_the_derived_one() -> None:
    """The escape hatch for a language whose badge letter is not its category's initial.

    The term and the override deliberately begin with different letters, so the two branches cannot both
    be satisfied by the same answer -- which is what a `Gwylio`/`G` pair would have done, passing whether
    the override was consulted or not.
    """
    module = generator_module()
    glossary = {"watch": "Ychwanegol"}
    rules = badge_rules({"cy": {"Watch": "G"}})
    assert module.badge_letter("Watch", glossary, rules, "cy") == "G", "the recorded letter must win"
    assert module.badge_letter("Watch", glossary, rules, "en") == "Y", "and reach no other language"


def test_a_category_with_no_glossary_term_fails() -> None:
    """Falling back to the English word would hide a terminology gap behind a plausible badge."""
    module = generator_module()
    with pytest.raises(LookupError, match="glossary term"):
        module.badge_letter("Watch", {}, badge_rules(), "de")


def test_a_letter_too_wide_for_its_circle_is_refused() -> None:
    """The failure a derived initial can actually produce, and the reason the fit is measured.

    `Ш` is nearly twice the width of `W`, and a badge printed 20 units across has nothing to absorb that
    with. Asserted against a real face rather than a nominal width, so it stays true as fonts change --
    and paired with a letter that must PASS, since a check that refuses everything would also be green.
    """
    module = generator_module()
    face = module.Typeface([module.Face(REPO / "common" / "fonts" / "NotoSans-Bold.ttf")])
    fits = module.Badge("Watch", "W", "#fff", "#000", "AWaRe Watch")
    assert module.badge_overflow(fits, face) is None, "a Latin capital must fit its own badge"
    wide = module.Badge("Watch", "MMMM", "#fff", "#000", "AWaRe Watch")
    assert module.badge_overflow(wide, face) is not None, "a letter wider than the disc must be refused"


def test_the_badge_set_comes_from_the_metadata(english: Path) -> None:
    """One badge per AWaRe category the metadata defines -- so WHO's fourth costs no code change."""
    with (REPO / "metadata" / "common" / "antibiotics" / "NeoIPC-Antibiotic-AWaRe-Groups.csv").open(
            encoding="utf-8", newline="") as handle:
        categories = {row["category"] for row in csv.DictReader(handle)}
    written = {p.stem.removeprefix("AWaRe-").replace("-", " ") for p in english.glob("AWaRe-*.svg")}
    assert written == categories, f"badges {written} do not match the categories {categories}"


def test_a_badge_names_no_font_the_repository_does_not_ship(english: Path) -> None:
    """A family the renderer cannot resolve does not fail: prawn-svg draws the text in the document's
    fallback face instead, so a badge naming one comes out in the protocol's serif and nothing says so."""
    for badge in sorted(english.glob("AWaRe-*.svg")):
        body = badge.read_text(encoding="utf-8")
        assert "Arial" not in body and "sans-serif" not in body, f"{badge.name} names a font we do not ship"
        assert "Noto Sans" in body, f"{badge.name} does not name the family it was measured in"


def test_mirroring_reflects_a_page_about_its_own_width() -> None:
    """A landscape page must be mirrored about 29700, not about whatever the portrait sheets use.

    The whole point of the page size travelling with the form. Mirroring the chart about the portrait
    width would put most of it at a negative coordinate -- off the page, clipped, and reported by nothing,
    since `place` neither reflows nor complains. Exercised directly because no right-to-left catalogue is
    committed here, so no rendered file can reach this path.
    """
    module = generator_module()
    page_w = module.LANDSCAPE[0]
    shapes = [module.Text(28000, 500, "x", "label"), module.Box(28000, 500, 900, 100, "band"),
              module.Line(1000, 500, 28700, 500, "rule"), module.Dot(28000, 500, 130)]
    mirrored = module.mirror(shapes, page_w)
    for shape in mirrored:
        for value in (getattr(shape, "x", None), getattr(shape, "x1", None),
                      getattr(shape, "x2", None), getattr(shape, "cx", None)):
            if value is not None:
                assert 0 <= value <= page_w, f"{shape} left the page when mirrored about {page_w}"
    assert module.mirror(mirrored, page_w) == shapes, "mirroring twice is not the identity"


# ── The figures that are drawn rather than derived ──────────────────────────────────────────────────
#
# A sheet's layout is computed from the metadata; the decision flow's is a design somebody settled and
# checked in. So what is gated here is the other half: that each label is resolved for the culture, that
# it is MEASURED into the box its own group declares, and that the two ways this can go wrong are build
# failures rather than a figure that quietly prints a placeholder or overruns a box.


def test_a_drawn_figure_is_written_and_holds_no_placeholder(english: Path) -> None:
    """Every `{key}` has become a string, including in the title and description a screen reader reads."""
    figures = figure_files(english)
    assert figures, "the run produced no drawn figure at all"
    for figure in figures:
        body = figure.read_text(encoding="utf-8")
        assert not re.search(r"\{\w+\}", body), f"{figure.name} still carries an unresolved placeholder"
        tree = ET.parse(figure)
        for tag in ("title", "desc"):
            element = tree.getroot().find(f"{{{SVG_NS}}}{tag}")
            assert element is not None and (element.text or "").strip(), \
                f"{figure.name} has no <{tag}>, so an inlined copy of it is an unlabelled graphic"


def test_every_label_fits_the_box_its_own_group_declares(english: Path) -> None:
    """The property the template trades a layout engine for.

    Re-measured here rather than trusted: the generator asserts it while writing, so a test that only
    re-read the file would be asking the same code the same question. This asks the geometry instead --
    every line's width against the region the group's own shape gives it, and the block's height against
    what is left of that region under any mark.
    """
    module = generator_module()
    fonts = REPO / "common" / "fonts"
    faces = {(bold, italic): module.Typeface(
        [module.Face(fonts / f"NotoSans-{module._variant('NotoSans', bold, italic)}.ttf")], "en")
        for bold in (False, True) for italic in (False, True)}
    for figure in figure_files(english):
        root = ET.parse(figure).getroot()
        sheet = module.Stylesheet(root.find(f"{{{SVG_NS}}}style").text)
        for group in root.iter(f"{{{SVG_NS}}}g"):
            label = group.find(f"{{{SVG_NS}}}text")
            if label is None:
                continue
            style = sheet.style_of(label)
            fit = module.region_of(group)
            face = faces[style.face]
            lines = [span.text or "" for span in label]
            assert lines, f"{group.get('id')} has no line in it at all"
            for line in lines:
                width = face.width(line, style.size)
                assert width <= fit.width, (
                    f"{group.get('id')}: {line!r} draws {width:.0f} in a box of {fit.width}")
            assert len(lines) <= fit.capacity(style), (
                f"{group.get('id')}: {len(lines)} lines in a box holding {fit.capacity(style)}")


def test_a_drawn_figure_names_the_faces_the_culture_is_measured_in(english: Path) -> None:
    """The one thing a skeleton cannot state for itself, because it does not know the culture.

    A figure that kept the skeleton's single family would draw a Nepali label in a face carrying no
    Devanagari -- and prawn-svg answers an unresolvable family with the document's own fallback, so the
    result is a readable line in the wrong script rather than anything that reports itself.
    """
    for figure in figure_files(english):
        css = ET.parse(figure).getroot().find(f"{{{SVG_NS}}}style").text
        assert "Noto Sans" in css
        assert "sans-serif" not in css, f"{figure.name} names a generic family, which resolves to Helvetica"


def test_a_line_is_not_separated_from_the_next_by_rendered_whitespace(english: Path) -> None:
    """Indenting inside a <text> is not cosmetic: whitespace between tspans is drawn content in SVG, so
    it puts a stray space into the text a screen reader reads and anything extracting the figure gets."""
    for figure in figure_files(english):
        for label in ET.parse(figure).getroot().iter(f"{{{SVG_NS}}}text"):
            if len(label) == 0:
                continue        # its own words, which the pass-through test checks instead
            assert not (label.text or "").strip(), \
                f"{figure.name}: a wrapped label carries character data of its own beside its tspans"
            for span in label:
                assert not (span.tail or ""), f"{figure.name}: a tspan is followed by rendered whitespace"


def test_a_label_that_will_not_fit_fails_the_build(tmp_path: Path) -> None:
    """Red without the guard. The failure this replaces was silent: the wrapper counted characters, so a
    long word was emitted whole and drew straight out of its box with nothing reporting it."""
    module = generator_module()
    skeleton = (SKELETONS / "NeoIPC-Core-Decision-Flow.svg").read_text(encoding="utf-8")
    chrome = module.load_localized(REPO / "common" / "figure-strings.yaml", None)
    chrome = dict(chrome, decision_eligible="Eligible " * 40)
    fonts = REPO / "common" / "fonts"
    faces = {(bold, italic): module.Typeface(
        [module.Face(fonts / f"NotoSans-{module._variant('NotoSans', bold, italic)}.ttf")], "en")
        for bold in (False, True) for italic in (False, True)}
    with pytest.raises(module.Overflow) as raised:
        module.localize_figure(skeleton, chrome, {}, faces, None, [])
    assert "decision-flow-eligible" in str(raised.value)


def test_a_placeholder_no_string_answers_fails_the_build(tmp_path: Path) -> None:
    """Also red without the guard, and the more insidious of the two: a figure printing `{decision_x}` to
    a partner looks like a rendering bug rather than a missing translation, so it is refused instead."""
    module = generator_module()
    skeleton = (SKELETONS / "NeoIPC-Core-Decision-Flow.svg").read_text(encoding="utf-8")
    chrome = module.load_localized(REPO / "common" / "figure-strings.yaml", None)
    del chrome["decision_birthweight"]
    fonts = REPO / "common" / "fonts"
    faces = {(bold, italic): module.Typeface(
        [module.Face(fonts / f"NotoSans-{module._variant('NotoSans', bold, italic)}.ttf")], "en")
        for bold in (False, True) for italic in (False, True)}
    with pytest.raises(module.Overflow) as raised:
        module.localize_figure(skeleton, chrome, {}, faces, None, [])
    assert "decision_birthweight" in str(raised.value)


def test_a_localized_figure_is_well_formed_and_declares_its_language(tmp_path: Path) -> None:
    """Red without the expanded-name fix, and only on a LOCALIZED run.

    The untranslated build never sets the language, so it never meets this: setting `xml:lang` by its
    literal string adds a SECOND attribute beside the one the skeleton already carries under its expanded
    name, both serialize alike, and the result is a duplicate attribute that no parser will accept. What
    the reader gets is not a broken figure but no figure -- asciidoctor drops it and substitutes the alt
    text -- so nothing about the page says the build produced rubbish.
    """
    result = generate(tmp_path / "de", "--language", "de")
    assert result.returncode == 0, f"{result.stdout}\n{result.stderr}"
    figures = figure_files(tmp_path / "de")
    assert figures, "the localized run produced no drawn figure"
    for figure in figures:
        body = figure.read_text(encoding="utf-8")
        assert body.count("xml:lang") == 1, f"{figure.name} declares its language more than once"
        root = ET.fromstring(body)          # raises on a duplicate attribute
        assert root.get(f"{{{XML_NS}}}lang") == "de", f"{figure.name} does not declare the culture built"


def test_the_preview_stamp_is_off_by_default_and_on_when_asked(english: Path, tmp_path: Path) -> None:
    """Both directions, because either one alone is wrong in a way that matters.

    A form that says it is provisional when it is not undermines every published one; a form that stays
    silent when it IS provisional gets filled in at a cot side against definitions that may still move.
    Only the build knows which it is making, so the generator is told rather than guessing.
    """
    for sheet in sheet_files(english):
        assert "preview-watermark" not in sheet.read_text(encoding="utf-8"), \
            f"{sheet.name} carries a preview stamp on an ordinary run"

    preview = tmp_path / "preview"
    assert generate(preview, "--preview").returncode == 0
    stamped = sheet_files(preview)
    assert stamped, "the preview run produced no sheet"
    for sheet in stamped:
        body = sheet.read_text(encoding="utf-8")
        assert "preview-watermark" in body, f"{sheet.name} has no preview stamp"
        assert 'transform="rotate(-45' in body, f"{sheet.name}'s stamp is not on the diagonal"
    for source in sheet_files(preview, "typ"):
        assert "#turned(" in source.read_text(encoding="utf-8"), \
            f"{source.name} does not stamp the printed form, only the figure"


def test_mirroring_a_page_reflects_the_angle_of_what_is_on_it() -> None:
    """A run rising to the right rises to the left once the page is turned over. Exercised directly:
    no right-to-left catalogue is committed here, so no rendered file can reach this."""
    module = generator_module()
    turned = module.Text(10500, 14850, "x", "watermark", "preview-watermark", angle=-45)
    mirrored = module.mirror([turned], module.PORTRAIT[0])[0]
    assert mirrored.angle == 45, "the stamp kept its lean when the page was mirrored"
    assert module.mirror([mirrored], module.PORTRAIT[0])[0] == turned, "mirroring twice is not identity"


def test_a_text_outside_a_labelled_group_is_passed_through_untouched(english: Path) -> None:
    """How a skeleton says a string is NOT translated, and it has to survive being said.

    Only a <text> inside a <g> is resolved, measured and re-placed; anything else is the skeleton's own
    words. The whitespace-cleanup that follows indenting has to skip those, because for a text element
    carrying character data rather than tspans, clearing it is not tidying -- it is the content.
    """
    seen = 0
    for figure in figure_files(english):
        root = ET.parse(figure).getroot()
        in_group = {id(label) for group in root.iter(f"{{{SVG_NS}}}g")
                    for label in group.iter(f"{{{SVG_NS}}}text")}
        for label in root.iter(f"{{{SVG_NS}}}text"):
            if id(label) in in_group:
                continue
            seen += 1
            assert (label.text or "").strip(), (
                f"{figure.name}: a standalone text element came out empty, so its content was thrown away")
    assert seen, "no figure exercises the pass-through path, so this asserts nothing"
