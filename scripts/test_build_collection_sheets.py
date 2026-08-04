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

import re
import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
GENERATOR = REPO / "scripts" / "build-collection-sheets.py"
SHEETS = 6


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
