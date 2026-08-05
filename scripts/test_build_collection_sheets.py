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
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
GENERATOR = REPO / "scripts" / "build-collection-sheets.py"
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


@pytest.fixture(scope="module")
def english(tmp_path_factory: pytest.TempPathFactory) -> Path:
    out = tmp_path_factory.mktemp("sheets-en")
    result = generate(out)
    assert result.returncode == 0, f"the generator failed:\n{result.stdout}\n{result.stderr}"
    return out


def test_every_sheet_fits_one_page(english: Path) -> None:
    """No --allow-overflow, so this is the real gate rather than the escape hatch."""
    assert len(list(english.glob("*.svg"))) == SHEETS
    assert len(list(english.glob("*.typ"))) == SHEETS


def test_a_localized_run_fits_too(tmp_path: Path) -> None:
    """German, whose catalogue is committed here — the compounding language most likely to overflow."""
    result = generate(tmp_path / "de", "--language", "de")
    assert result.returncode == 0, f"the German sheets do not fit:\n{result.stdout}\n{result.stderr}"
    assert len(list((tmp_path / "de").glob("*.svg"))) == SHEETS


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
    for sheet in sorted(english.glob("*.svg")):
        body = sheet.read_text(encoding="utf-8").split("</symbol>", 1)[-1]
        if re.search(pattern, body):
            offenders.append(sheet.name)
    assert not offenders, f"{what} in {offenders}"


def test_coordinates_are_integers_on_one_grid(english: Path) -> None:
    """A fractional coordinate means something bypassed the grid the whole layout is expressed in."""
    fractional: list[str] = []
    for sheet in sorted(english.glob("*.svg")):
        body = sheet.read_text(encoding="utf-8").split("</symbol>", 1)[-1]
        fractional += [f"{sheet.name}: {m.group(0)}"
                       for m in re.finditer(r'\b(?:x|y|x1|y1|x2|y2|cx|cy|width|height)="\d+\.\d+"', body)]
    assert not fractional, f"coordinates off the grid: {fractional[:5]}"


# ── The progress chart ──────────────────────────────────────────────────────────────────────────────


def chart(directory: Path, language: str = "") -> str:
    suffix = f".{language}" if language else ""
    return (directory / f"NeoIPC-Core-Patient-Progress-Chart{suffix}.svg").read_text(encoding="utf-8")


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
               (("en", chart(english)), ("ne", chart(tmp_path / "ne", "ne")))}
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
