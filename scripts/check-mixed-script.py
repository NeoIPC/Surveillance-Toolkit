#!/usr/bin/env python3
"""Find words that mix writing systems — the homoglyph substitution no editor can show you.

Cyrillic С Р А О Е Т and Greek Α Ο Ρ Τ Ε are pixel-identical to Latin C P A O E T. On a keyboard laid out
for those scripts they are the letters within reach, while the Latin ones cost a layout switch — so a
translator writing CPAP, NEC or CVC types what looks exactly right and produces a different string. The
result is invisible: identical in every editor, identical in every diff, identical on the printed page.
What breaks is everything downstream — search misses it, sorting misplaces it, a screen reader announces
it in the wrong language, a glossary lookup never matches, and an encoding check passes it.

**This is a hazard ahead of this project rather than behind it.** Nothing in the catalogues carries one
today, but Ukrainian and Greek have had almost no translator input yet, and those are exactly the two
scripts whose keyboards make the substitution the path of least resistance.

**Two detectors, because the obvious one misses the case that actually happens.** Looking for a word that
MIXES scripts catches a half-substitution and nothing else — and a typist does not half-substitute. Asked
to write CPAP without leaving a Ukrainian layout, they type С-Р-А-Р, four Cyrillic letters, a word in one
script that is pixel-identical to a Latin abbreviation. Proven by probe: the mixed-script test passed it
without a word. So the second detector folds each word to its Latin skeleton through the confusable
characters and reports it when the skeleton is a term this project uses in Latin — which is what makes it
precise rather than a warning about every Cyrillic word.

The one routine exception is the micro prefix: Unicode's own recommendation for µg and µL is GREEK SMALL
LETTER MU, so a Greek mu against Latin letters is a correctly spelt unit and not a substitution.

    python scripts/check-mixed-script.py po

Exits non-zero when anything is found, so it can gate a push.
"""

from __future__ import annotations

import argparse
import re
import sys
import unicodedata
from pathlib import Path

import polib

WORD = re.compile(r"[^\W\d_]+", re.UNICODE)
SCRIPTS = ("LATIN", "CYRILLIC", "GREEK", "HEBREW", "DEVANAGARI", "ARABIC")

# GREEK SMALL LETTER MU as an SI prefix. U+00B5 MICRO SIGN is the compatibility character and U+03BC is
# what Unicode recommends, so a unit spelt with it is right and must not be reported.
MICRO = "μ"

# Characters that render as a Latin letter while being something else. Only the pairs that are visually
# identical in ordinary text faces -- a near-miss such as Cyrillic д is not a hazard, because it is
# visibly wrong the moment anyone looks.
CONFUSABLE = str.maketrans({
    # Cyrillic
    "А": "A", "В": "B", "Е": "E", "К": "K", "М": "M", "Н": "H", "О": "O", "Р": "P", "С": "C", "Т": "T",
    "У": "Y", "Х": "X", "І": "I", "Ј": "J", "Ѕ": "S", "Ԛ": "Q", "Ԝ": "W",
    "а": "a", "е": "e", "о": "o", "р": "p", "с": "c", "у": "y", "х": "x", "і": "i", "ј": "j", "ѕ": "s",
    "ԛ": "q", "ԝ": "w",
    # Greek
    "Α": "A", "Β": "B", "Ε": "E", "Ζ": "Z", "Η": "H", "Ι": "I", "Κ": "K", "Μ": "M", "Ν": "N", "Ο": "O",
    "Ρ": "P", "Τ": "T", "Υ": "Y", "Χ": "X",
    "ο": "o", "ρ": "p", "ι": "i", "ν": "v",
})


def script_of(char: str) -> str:
    name = unicodedata.name(char, "")
    return next((script for script in SCRIPTS if name.startswith(script)), "OTHER")


def mixed(word: str) -> set[str] | None:
    scripts = {script_of(character) for character in word} - {"OTHER"}
    if len(scripts) < 2:
        return None
    if scripts == {"GREEK", "LATIN"} and all(c == MICRO for c in word if script_of(c) == "GREEK"):
        return None
    return scripts


def latin_terms(glossary: Path) -> set[str]:
    """The Latin words a substituted lookalike would be impersonating.

    Taken from the glossary, so the set is the project's own terminology rather than a list kept here --
    and so a term added there is protected without anyone remembering to protect it.
    """
    from ruamel.yaml import YAML

    terms = YAML(typ="safe").load(glossary.read_text(encoding="utf-8"))
    return {word.strip("()/,.").upper()
            for value in terms.values() if isinstance(value, str)
            for word in value.split() if len(word.strip("()/,.")) > 1}


def impersonated(word: str, terms: set[str]) -> str | None:
    """The Latin term this word is drawn to look like, if it is not written in Latin itself."""
    if any(script_of(character) == "LATIN" for character in word):
        return None
    skeleton = word.translate(CONFUSABLE)
    if skeleton == word or not skeleton.isascii():
        return None
    return skeleton if skeleton.upper() in terms else None


def main(argv: list[str] | None = None) -> int:
    repo = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("directory", type=Path, help="a directory of .po / .pot catalogues")
    parser.add_argument("--glossary", type=Path, default=repo / "glossary.yaml")
    args = parser.parse_args(argv)

    terms = latin_terms(args.glossary)
    found = 0
    for path in sorted(args.directory.glob("*.po")) + sorted(args.directory.glob("*.pot")):
        for entry in polib.pofile(str(path)):
            for text, side in ((entry.msgstr, "msgstr"), (entry.msgid, "msgid")):
                for match in WORD.finditer(text or ""):
                    word = match.group(0)
                    where = entry.msgctxt or f"line {entry.linenum}"
                    if scripts := mixed(word):
                        found += 1
                        print(f"{path.name} [{where}] {side} {word!r} "
                              f"mixes {' + '.join(sorted(scripts))}")
                    elif lookalike := impersonated(word, terms):
                        found += 1
                        print(f"{path.name} [{where}] {side} {word!r} is not Latin but renders as "
                              f"{lookalike!r}, which is a term this project writes in Latin")

    if not found:
        print("no substituted or mixed-script words")
        return 0
    print(f"\n{found} word(s) to retype in one script, or to confirm as deliberate.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
