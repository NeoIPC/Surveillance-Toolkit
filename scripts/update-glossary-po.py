#!/usr/bin/env python3
"""Convert glossary.yaml to/from bilingual gettext PO format.

Bilingual rather than monolingual: msgctxt carries the YAML key and msgid carries the English
source, so the component's template field stays empty and new_base points at the .pot.

Replaces po4a for glossary management, providing full PO feature support:
msgctxt (variant grouping), msgid_plural (plurals), translator comments,
flags, locations with line numbers, and additional states.

Catalogue ownership: this script writes po/glossary.pot and NOTHING ELSE under po/.
The catalogues are Weblate's, written by the neoipc-glossary component; its msgmerge
add-on is what brings them up to a changed template, and its new_base creates a
catalogue for a language Weblate adds. A generator writing them as well would put
two writers on one file, which is what conflicts every language of a catalogue at
once -- both sides rewrite adjacent header lines inside a single hunk git cannot
auto-merge.

This script therefore has no per-language header machinery at all: no language-name
or plural-rule table, no contributor filtering, no flag merging. Weblate writes those
headers, and scripts/modules/NeoIPC-Tools/Tests/PoHeader.Tests.ps1 -- which runs in CI
and asserts against the committed files -- is what holds them to the contract.

Reading the catalogues is still this script's business: --generate-yaml produces
glossary.<lang>.yaml for every glossary.<lang>.po it finds in --po-dir, so a language
Weblate adds is picked up without editing anything here. Pass --languages to narrow it.

Naming convention in glossary.yaml:
    key             = AMA canonical (lowercase)
    key_sc          = Sentence case
    key_tc          = Title case
    key_plural      = Plural form
    Suffixes can combine: key_plural_tc

YAML comment conventions:
    # Description text for translators       -> PO #. extracted comment
    # flags: ignore-same, max-length:20      -> PO #, flags line
    key: value                               -> PO msgctxt + msgid

    Comment lines starting with "flags:" are parsed as PO flags.
    All other comment lines become translator descriptions.
    See https://docs.weblate.org/en/latest/admin/checks.html for available flags.

Usage:
    # Extract YAML -> POT. Writes po/glossary.pot only; the catalogues are Weblate's.
    python scripts/update-glossary-po.py

    # Also generate localized YAML from the committed PO files
    python scripts/update-glossary-po.py --generate-yaml
"""

import argparse
import datetime
import re
import sys
from pathlib import Path

try:
    from ruamel.yaml import YAML
except ImportError:
    sys.exit("Error: ruamel.yaml is required. Install with: pip install ruamel.yaml")

try:
    import polib
except ImportError:
    sys.exit("Error: polib is required. Install with: pip install polib")

PLURAL_SUFFIX = re.compile(r"_plural(?:_(tc|sc))?$")
FLAGS_LINE = re.compile(r"^flags:\s*(.+)$", re.IGNORECASE)

# The header contract is defined once, in the NeoIPC-Tools module (Private/PoHeader.ps1). This is the same
# contract expressed in Python, because this generator cannot call into a PowerShell module. Nothing renders
# both and compares them; what holds them in step is that Tests/PoHeader.Tests.ps1 asserts the contract
# against every COMMITTED catalogue and template, so a header this generator writes differently fails there
# whichever writer produced it.
#
# The trailing bare "#" is load-bearing, not decoration. translate-toolkit's updatecontributor — which
# Weblate's "Contributors in comment" add-on delegates to — splits the comment block at the first line matching
# r".*<\S+@\S+>.*\d{4,4}" (an e-mail AND a four-digit year). Everything before it is preserved untouched;
# contributors are appended after the last one; anything following them is dropped if empty. So the "#" belongs
# BELOW the licence and ABOVE any contributor, where it is the final preserved line.
POT_HEADER_COMMENT = (
    "Translations for the NeoIPC Surveillance Glossary\n"
    "Copyright (C) Charité – Universitätsmedizin Berlin\n"
    "This file is distributed under the Creative Commons "
    "Attribution 4.0 International license\n"
)

# Deliberately absent: Project-Id-Version (its version suffix froze while the products moved on),
# Last-Translator (frozen by po_set_last_translator=false, so it would name a translator who can never change)
# and X-Generator (a Weblate version string that rewrote every catalogue on each upgrade). POT-Creation-Date is
# stamped in the TEMPLATE only — msgmerge does not refresh it in a catalogue, where it silently goes stale.
POT_METADATA = {
    "Report-Msgid-Bugs-To": "NeoIPC-Support@charite.de",
    "POT-Creation-Date": "",  # filled at generation time
    "PO-Revision-Date": "YEAR-MO-DA HO:MI+ZONE",
    "Language-Team": "none",
    "Language": "en",
    "MIME-Version": "1.0",
    "Content-Type": "text/plain; charset=UTF-8",
    "Content-Transfer-Encoding": "8bit",
}


def _comment_lines(tokens):
    """Flatten comment tokens into their raw source lines, blank lines included."""
    lines = []
    for token in tokens:
        lines.extend(token.value.splitlines())
    return lines


def _parse_comment_lines(lines):
    """Parse raw comment lines into (description_lines, flag_strings).

    Lines matching ``# flags: ...`` are split into individual flag strings.
    All other non-empty comment lines become translator descriptions.
    """
    descriptions = []
    flags = []
    for raw_line in lines:
        text = raw_line.strip()
        if not text or text == "#":
            continue
        if text.startswith("#"):
            text = text[1:].strip()
        if not text:
            continue
        m = FLAGS_LINE.match(text)
        if m:
            flags.extend(f.strip() for f in m.group(1).split(",") if f.strip())
        else:
            descriptions.append(text)
    return descriptions, flags


def _parse_comment_tokens(tokens):
    """Parse comment tokens into (description_lines, flag_strings)."""
    return _parse_comment_lines(_comment_lines(tokens))


def get_key_comments(yaml_data, keys, index):
    """Return (description, flags_list) for the key at *index*.

    ruamel.yaml attaches inter-key comments to the **previous** key's
    ``ca.items[prev_key][2]`` (trailing comment slot), not to the following
    key's ``[1]`` slot.  For the very first key the file-level comment
    (``yaml_data.ca.comment``) is used instead.
    """
    if index == 0:
        # The file-level comment block holds the YAML header AND, when present,
        # the first key's own comment — ruamel does not separate them.  YAML
        # convention puts a blank line between the two, so the comment group
        # after the last blank line belongs to the key.  Without any blank line
        # the block is unambiguously just the header, so only flags are taken.
        top = yaml_data.ca.comment
        if not (top and top[1]):
            return None, []
        lines = _comment_lines(top[1])
        if not any(not line.strip() for line in lines):
            _, flags = _parse_comment_lines(lines)
            return None, flags
        group = []
        for raw in lines:
            group = [] if not raw.strip() else group + [raw]
        return _parse_comment_lines(group)

    prev_key = keys[index - 1]
    ca = yaml_data.ca.items.get(prev_key)
    if ca and ca[2]:
        tokens = [ca[2]] if not isinstance(ca[2], list) else ca[2]
        return _parse_comment_tokens(tokens)
    return None, []


def find_plural_base(key):
    """If key is a _plural variant, return the base key. Otherwise None."""
    match = PLURAL_SUFFIX.search(key)
    if match:
        return key[: match.start()]
    return None


def yaml_to_pot(glossary_path, pot_path):
    """Read glossary.yaml and generate glossary.pot with msgctxt."""
    yaml = YAML()
    yaml.preserve_quotes = True
    with open(glossary_path, "r", encoding="utf-8") as f:
        data = yaml.load(f)

    if data is None:
        sys.exit(f"Error: {glossary_path} is empty or invalid YAML")

    pot = polib.POFile()
    # Match the po_line_wrap=65535 every Weblate component here declares. polib defaults to
    # wrapwidth=78, which made this the only wrapped template in the repository -- longest line 91
    # against 625-1830 in the po4a-generated ones -- so the template and the catalogues Weblate writes
    # from it disagreed on line breaking, for no reason anyone chose.
    pot.wrapwidth = 65535
    pot.header = POT_HEADER_COMMENT
    pot.metadata = {**POT_METADATA}

    # The "#:" location must be repository-relative with forward slashes, whatever path the caller
    # passed. It is written into a committed, publicly shipped file, so an absolute --glossary would put
    # a developer's home directory into the template -- and the po4a-generated templates alongside it are
    # repository-relative, so this also keeps the family consistent. Falls back to the bare filename for
    # a source outside the repository, which is the only remaining way to name it without leaking a path.
    try:
        location = glossary_path.resolve().relative_to(Path(__file__).resolve().parent.parent).as_posix()
    except ValueError:
        location = glossary_path.name
    now = datetime.datetime.now(datetime.timezone.utc)
    pot.metadata["POT-Creation-Date"] = now.strftime("%Y-%m-%d %H:%M%z")

    # Collect plural pairs: base_key -> plural_key
    plural_pairs = {}
    for key in data:
        base = find_plural_base(key)
        if base and base in data:
            plural_pairs[base] = key

    # Track which keys are handled as plural counterparts
    handled_as_plural = set(plural_pairs.values())

    keys = list(data.keys())
    for idx, key in enumerate(keys):
        if key in handled_as_plural:
            continue  # handled as part of its base key's entry

        value = str(data[key])

        # Line number (1-based) for the #: location reference
        line_no = data.lc.key(key)[0] + 1

        # Comments: description + flags
        desc_lines, entry_flags = get_key_comments(data, keys, idx)

        entry_kwargs = {
            "msgctxt": key,
            "msgid": value,
            "msgstr": "",
            "occurrences": [(location, str(line_no))],
        }

        if desc_lines:
            entry_kwargs["comment"] = "\n".join(desc_lines)

        # If this key has a plural counterpart, create a plural entry
        if key in plural_pairs:
            plural_key = plural_pairs[key]
            plural_value = str(data[plural_key])
            entry_kwargs["msgid_plural"] = plural_value
            entry_kwargs["msgstr_plural"] = {0: "", 1: ""}
            del entry_kwargs["msgstr"]

        entry = polib.POEntry(**entry_kwargs)
        if entry_flags:
            entry.flags = entry_flags
        pot.append(entry)

    # newline="\n" is not optional. polib.save() forwards it to io.open(), and io.open's default
    # (newline=None) translates every "\n" to os.linesep -- so on Windows this writes a CRLF .pot
    # while po4a, msgmerge and Weblate all write LF. A catalogue rewritten in part by a tool that
    # disagrees is what produces a mixed file no gettext parser accepts.
    pot.save(str(pot_path), newline="\n")
    print(f"Generated {pot_path} ({len(pot)} entries)")
    return pot


def generate_yaml(po_dir, glossary_path, languages, threshold=80):
    """Generate glossary.<lang>.yaml from translated PO files.

    Languages below *threshold* percent translated are skipped to avoid
    mixed-language output (same behaviour as po4a's default 80% cutoff).
    """
    yaml = YAML()
    yaml.preserve_quotes = True
    yaml.default_flow_style = False

    for lang in languages:
        po_path = po_dir / f"glossary.{lang}.po"
        if not po_path.exists():
            continue

        po = polib.pofile(str(po_path))
        # polib's own percentage, not len(po): POFile subclasses list, so obsolete "#~" entries count
        # toward its length while never counting as translated, which drags the percentage down and can
        # skip a language that is in fact complete. Obsolete entries used to be impossible here because
        # the retired merge rebuilt each catalogue from the template; now that Weblate owns them and
        # po_remove_obsolete is deliberately false, they are normal state.
        translated_count = len(po.translated_entries())
        total = len([e for e in po if not e.obsolete])
        # polib's own percentage, not translated/len(po): POFile subclasses list, so obsolete "#~"
        # entries count toward its length while never counting as translated, which drags the figure
        # down and can skip a language that is in fact complete. Obsolete entries used to be impossible
        # here because the retired merge rebuilt each catalogue from the template; now that Weblate owns
        # them and po_remove_obsolete is deliberately false, they are normal state.
        #
        # The empty case is spelt out because polib and the previous arithmetic disagree on it: polib
        # returns 100 for a catalogue with no live entries, which would pass any threshold. Nothing
        # here should be generated from a catalogue that has no strings.
        pct = po.percent_translated() if total > 0 else 0

        if pct < threshold:
            print(
                f"Skipped {lang}: {translated_count}/{total} translated "
                f"({pct:.0f}% < {threshold}% threshold)"
            )
            continue

        translations = {}
        for entry in po.translated_entries():
            if not entry.msgctxt:
                continue

            if entry.msgid_plural and entry.msgstr_plural:
                # Singular
                if entry.msgstr_plural.get(0):
                    translations[entry.msgctxt] = entry.msgstr_plural[0]
                # Plural
                plural_key = entry.msgctxt + "_plural"
                if entry.msgstr_plural.get(1):
                    translations[plural_key] = entry.msgstr_plural[1]
            elif entry.msgstr:
                translations[entry.msgctxt] = entry.msgstr

        if not translations:
            continue

        # Sort by key
        sorted_translations = dict(sorted(translations.items()))

        # newline="\n" for the same reason as the .pot above: open()'s default translates "\n" to
        # os.linesep, so this generated YAML would be CRLF on Windows and LF in CI. It is read by
        # the reports' R string-resource cascade and committed, so the bytes must not depend on
        # which machine ran the pipeline.
        out_path = glossary_path.parent / f"glossary.{lang}.yaml"
        with open(out_path, "w", encoding="utf-8", newline="\n") as f:
            yaml.dump(sorted_translations, f)

        print(f"Generated {out_path} ({len(sorted_translations)} entries)")


def main():
    parser = argparse.ArgumentParser(
        description="Convert glossary.yaml to/from bilingual gettext PO"
    )
    parser.add_argument(
        "--glossary",
        type=Path,
        default=Path("glossary.yaml"),
        help="Glossary YAML file (default: glossary.yaml)",
    )
    parser.add_argument(
        "--pot",
        type=Path,
        default=Path("po/glossary.pot"),
        help="POT output path (default: po/glossary.pot)",
    )
    parser.add_argument(
        "--po-dir",
        type=Path,
        default=Path("po"),
        help="Directory the .po files are read from (default: po/)",
    )
    parser.add_argument(
        "--languages",
        type=lambda s: s.split(","),
        default=None,
        help="Comma-separated language codes to generate localized YAML for "
             "(default: every glossary.<lang>.po found in --po-dir)",
    )
    parser.add_argument(
        "--generate-yaml",
        action="store_true",
        help="Generate glossary.<lang>.yaml from .po files",
    )
    parser.add_argument(
        "--threshold",
        type=int,
        default=80,
        help="Minimum translation percentage to generate YAML (default: 80)",
    )

    args = parser.parse_args()

    if not args.glossary.exists():
        sys.exit(f"Error: {args.glossary} not found")

    yaml_to_pot(args.glossary, args.pot)

    if args.generate_yaml:
        # Discover the catalogues present rather than defaulting to a fixed list. Weblate owns which
        # languages exist and adds one whenever a request is accepted, so a hard-coded list silently
        # skips the new language's YAML until someone notices and edits this file. Same reasoning, and
        # the same fix, as the metadata importer's locale discovery.
        languages = args.languages
        if languages is None:
            languages = sorted(
                p.name.split(".")[1] for p in args.po_dir.glob("glossary.*.po")
            )
            if not languages:
                print(f"No glossary.<lang>.po found in {args.po_dir}; nothing to generate.")
        generate_yaml(args.po_dir, args.glossary, languages,
                      threshold=args.threshold)


if __name__ == "__main__":
    main()
