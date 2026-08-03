#!/usr/bin/env python3
"""Report the text of a generated sheet that is still in the source language.

Reads the finished PDF rather than the SVG the generator wrote, so what is checked is what a partner
receives: after shaping, after the engine's own extraction, out of the file itself. That matters because
every cheaper check tried here was too weak. Asking whether a whole text run was Latin passed
"CRP/इन्टरल्युकिन बढेको" as translated; asking the generator's own output would not have shown whether
the PDF agrees.

What counts as acceptable Latin is the GLOSSARY, not a list kept here. Which borrowed acronyms stay in
Latin script on a form written in another script is a terminology decision, and this project keeps
terminology decisions in one place; a second list inside a checking script is that decision made twice,
by whoever wrote the script, invisibly. Digits are exempt -- a numeral system is a separate decision from
a script, and most of these forms carry clinical thresholds that stay Western.

Exits non-zero when anything is left, so it can gate a build.

    python scripts/check-figure-language.py artifacts/sheets-ne

**It only means anything for a target written in another script.** The whole inference is "Latin here is
text nobody translated", which holds for Nepali, Greek, Hebrew and Ukrainian and is nonsense for German,
Turkish, Spanish, French, Italian, Afrikaans and Estonian -- there a perfect translation is Latin from end
to end and this would report every word of it. Passing one of those is refused rather than answered, since
a check that returns a confident wrong number is worse than one that declines. For a Latin-scripted
target the equivalent question is whether the catalogue has a translation for every string the sheets
consume, which is asked of the catalogue and not of the PDF.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path

from ruamel.yaml import YAML

# A word, or several joined by a solidus or a hyphen. Digits may appear inside so that 3GCR is one token
# rather than a stray 3 beside GCR, but a token of digits alone is not a word and is never reported.
WORD = re.compile(r"[A-Za-z0-9]*[A-Za-z][A-Za-z0-9]*(?:[/'’-][A-Za-z0-9]+)*")
SPLIT = re.compile(r"[/'’-]")

# A Roman numeral is a NUMBER that happens to be written in Latin letters, so it falls under the same
# exemption as the digits: choosing a numeral system is a separate decision from choosing a script. The
# ASA physical status classes are written I to VI in clinical use nearly everywhere, and a language that
# prefers 1 to 6 is equally exempt -- what neither should do is fail a check about translation.
ROMAN = re.compile(r"^(?=[IVXLCDM]+$)M*(CM|CD|D?C{0,3})(XC|XL|L?X{0,3})(IX|IV|V?I{0,3})$")


def accepted(glossary: Path, extra: list[str]) -> set[str]:
    """Every token a sheet may legitimately carry in Latin, upper-cased.

    A part must be at least two characters. The term "I/T" would otherwise contribute a bare "I" and
    swallow an ASA class numeral standing on its own -- which it did, silently, the first time this ran.
    """
    terms = YAML(typ="safe").load(glossary.read_text(encoding="utf-8"))
    return {
        part.upper()
        for value in terms.values() if isinstance(value, str)
        for word in value.split()
        for part in (word, *SPLIT.split(word)) if len(part) > 1
    } | {token.upper() for token in extra}


def residue(pdf: Path, allowed: set[str]) -> Counter[str]:
    text = subprocess.run(["pdftotext", "-enc", "UTF-8", str(pdf), "-"],
                          capture_output=True, text=True, encoding="utf-8", check=True).stdout
    found: Counter[str] = Counter()
    for match in WORD.finditer(text):
        word = match.group(0)
        # The WHOLE token first, then its parts. Checking only the parts made a glossary term containing
        # a one-letter part unmatchable: "I/T" splits to I and T, neither of which may be admitted on its
        # own, so the term was reported as untranslated in every language that has it.
        if word.upper() in allowed:
            continue
        if all(part.upper() in allowed for part in SPLIT.split(word) if part):
            continue
        if ROMAN.match(word):
            continue
        found[word] += 1
    return found


# Target languages this cannot speak about, because they are written in the same script as the source.
LATIN_SCRIPTED = {"af", "de", "en", "es", "et", "fr", "it", "tr"}


def main(argv: list[str] | None = None) -> int:
    repo = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("directory", type=Path, help="a directory of compiled sheets")
    parser.add_argument("--glossary", type=Path, default=repo / "glossary.yaml")
    parser.add_argument("--allow", nargs="*", default=["NeoIPC"],
                        help="names that are not terminology and belong in no glossary")
    args = parser.parse_args(argv)

    pdfs = sorted(args.directory.glob("*.pdf"))
    if not pdfs:
        print(f"no compiled sheet in {args.directory}", file=sys.stderr)
        return 2

    # Sheets are written as <name>.<culture>.pdf, so the culture is the second-to-last suffix.
    culture = pdfs[0].stem.rsplit(".", 1)[-1] if "." in pdfs[0].stem else "en"
    if culture in LATIN_SCRIPTED:
        print(f"{culture} is written in the Latin script, so 'Latin means untranslated' does not hold and "
              f"this check would report a correct translation as entirely missing. Ask the catalogue "
              f"whether every string the sheets consume has a translation instead.", file=sys.stderr)
        return 2

    allowed = accepted(args.glossary, args.allow)
    total: Counter[str] = Counter()
    for pdf in pdfs:
        found = residue(pdf, allowed)
        total.update(found)
        print(f"{pdf.stem:36} {sum(found.values()):5d} untranslated word(s)")

    if not total:
        print(f"\nnothing untranslated across {len(pdfs)} sheet(s)")
        return 0
    print(f"\n{sum(total.values())} occurrences of {len(total)} distinct word(s):")
    for word, count in sorted(total.items(), key=lambda item: (-item[1], item[0])):
        print(f"  {word:<20} x{count}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
