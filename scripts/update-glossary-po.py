#!/usr/bin/env python3
"""Convert glossary.yaml to/from monolingual gettext PO format.

Replaces po4a for glossary management, providing full PO feature support:
msgctxt (variant grouping), msgid_plural (plurals), translator comments,
flags, locations with line numbers, and additional states.

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
    # Extract YAML -> POT and merge with existing PO files
    python scripts/update-glossary-po.py

    # Also generate localized YAML from translated PO files
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

VARIANT_SUFFIXES = re.compile(r"_(tc|sc|plural(?:_tc|_sc)?)$")
PLURAL_SUFFIX = re.compile(r"_plural(?:_(tc|sc))?$")
FLAGS_LINE = re.compile(r"^flags:\s*(.+)$", re.IGNORECASE)
DEFAULT_LANGUAGES = ["af", "de", "el", "es", "et", "fr", "it", "ne", "tr"]

POT_HEADER_COMMENT = (
    "Translations for the NeoIPC Surveillance Glossary\n"
    "Copyright (C) Charité – Universitätsmedizin Berlin\n"
    "This file is distributed under the Creative Commons "
    "Attribution 4.0 International license\n"
    "Automatically generated"
)

POT_METADATA = {
    "Project-Id-Version": "NeoIPC Surveillance Glossary 0.9",
    "Report-Msgid-Bugs-To": "NeoIPC-Support@charite.de",
    "POT-Creation-Date": "",  # filled at generation time
    "PO-Revision-Date": "YEAR-MO-DA HO:MI+ZONE",
    "Last-Translator": "Automatically generated",
    "Language-Team": "none",
    "Language": "en",
    "MIME-Version": "1.0",
    "Content-Type": "text/plain; charset=UTF-8",
    "Content-Transfer-Encoding": "8bit",
}


def _parse_comment_tokens(tokens):
    """Parse comment tokens into (description_lines, flag_strings).

    Lines matching ``# flags: ...`` are split into individual flag strings.
    All other non-empty comment lines become translator descriptions.
    """
    descriptions = []
    flags = []
    for token in tokens:
        for raw_line in token.value.splitlines():
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


def get_key_comments(yaml_data, keys, index):
    """Return (description, flags_list) for the key at *index*.

    ruamel.yaml attaches inter-key comments to the **previous** key's
    ``ca.items[prev_key][2]`` (trailing comment slot), not to the following
    key's ``[1]`` slot.  For the very first key the file-level comment
    (``yaml_data.ca.comment``) is used instead.
    """
    if index == 0:
        # File-level comment (ca.comment[1]) is the YAML header.  It is NOT
        # a per-entry description — only parse it for per-entry flags.
        top = yaml_data.ca.comment
        if top and top[1]:
            _, flags = _parse_comment_tokens(top[1])
            return None, flags
        return None, []

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
    pot.header = POT_HEADER_COMMENT
    pot.metadata = {**POT_METADATA}
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
            "occurrences": [(str(glossary_path), str(line_no))],
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

    pot.save(str(pot_path))
    print(f"Generated {pot_path} ({len(pot)} entries)")
    return pot


# Flags that are managed by translators/Weblate, not by the source YAML.
# These are preserved from existing PO files during merge; all other flags
# are replaced by whatever the POT specifies.
TRANSLATOR_FLAGS = {"fuzzy", "ignore-same"}


def _merge_flags(pot_flags, po_flags):
    """Merge source flags (from POT/YAML) with translator flags (from PO).

    POT flags are authoritative — they replace all non-translator flags.
    Only translator-managed flags (e.g. ``fuzzy``) are preserved from the
    existing PO.  Returns a deduplicated list.
    """
    merged = list(pot_flags or [])
    for f in (po_flags or []):
        if f in TRANSLATOR_FLAGS and f not in merged:
            merged.append(f)
    return merged


LANGUAGE_NAMES = {
    "af": "Afrikaans", "de": "German", "es": "Spanish", "et": "Estonian",
    "el": "Greek", "fr": "French", "it": "Italian", "ne": "Nepali",
    "tr": "Turkish",
}


def _po_header_comment(lang):
    """Generate the file-level comment block for a new PO file."""
    lang_name = LANGUAGE_NAMES.get(lang, lang)
    return (
        f"{lang_name} translations for the NeoIPC Surveillance Glossary\n"
        "Copyright (C) Charité – Universitätsmedizin Berlin\n"
        "This file is distributed under the Creative Commons "
        "Attribution 4.0 International license\n"
        "FIRST AUTHOR <EMAIL@ADDRESS>"
    )


def merge_po(pot_path, po_path):
    """Merge a POT into an existing PO file, preserving translations."""
    pot = polib.pofile(str(pot_path))

    # Extract language code from filename (glossary.<lang>.po)
    lang = po_path.stem.split(".")[-1]

    if not po_path.exists():
        # Create a new PO from the POT
        po = polib.POFile()
        po.header = _po_header_comment(lang)
        po.metadata = {**pot.metadata}
        po.metadata["Language"] = lang
        for entry in pot:
            new_entry = polib.POEntry(
                msgctxt=entry.msgctxt,
                msgid=entry.msgid,
                msgid_plural=entry.msgid_plural,
                msgstr="" if not entry.msgid_plural else None,
                msgstr_plural=({i: "" for i in range(2)}
                               if entry.msgid_plural else None),
                comment=entry.comment,
                occurrences=entry.occurrences,
            )
            if entry.flags:
                new_entry.flags = list(entry.flags)
            po.append(new_entry)
        po.save(str(po_path))
        print(f"Created {po_path}")
        return

    po = polib.pofile(str(po_path))

    # Build lookup of existing translations by (msgctxt, msgid)
    existing = {}
    for entry in po:
        existing[(entry.msgctxt, entry.msgid)] = entry

    # Also try matching by msgid alone (for migration from po4a which had
    # no msgctxt)
    existing_by_msgid = {}
    for entry in po:
        if not entry.msgctxt and entry.msgid:
            existing_by_msgid[entry.msgid] = entry

    new_po = polib.POFile()
    new_po.header = po.header or _po_header_comment(lang)
    new_po.metadata = {**po.metadata}

    for pot_entry in pot:
        key = (pot_entry.msgctxt, pot_entry.msgid)

        if key in existing:
            # Exact match — preserve translation, merge flags
            old = existing[key]
            merged_flags = _merge_flags(pot_entry.flags, old.flags)
            new_entry = polib.POEntry(
                msgctxt=pot_entry.msgctxt,
                msgid=pot_entry.msgid,
                msgid_plural=pot_entry.msgid_plural,
                msgstr=old.msgstr if not pot_entry.msgid_plural else "",
                msgstr_plural=(old.msgstr_plural
                               if pot_entry.msgid_plural else None),
                comment=pot_entry.comment,
                occurrences=pot_entry.occurrences,
            )
            new_entry.flags = merged_flags
        elif pot_entry.msgid in existing_by_msgid:
            # Migration: match by msgid (old po4a entry without msgctxt)
            old = existing_by_msgid[pot_entry.msgid]
            new_entry = polib.POEntry(
                msgctxt=pot_entry.msgctxt,
                msgid=pot_entry.msgid,
                msgid_plural=pot_entry.msgid_plural,
                msgstr=old.msgstr if not pot_entry.msgid_plural else "",
                msgstr_plural=(old.msgstr_plural
                               if pot_entry.msgid_plural else None),
                comment=pot_entry.comment,
                occurrences=pot_entry.occurrences,
            )
            new_entry.flags = _merge_flags(pot_entry.flags, old.flags)
        else:
            # New entry — no translation yet
            new_entry = polib.POEntry(
                msgctxt=pot_entry.msgctxt,
                msgid=pot_entry.msgid,
                msgid_plural=pot_entry.msgid_plural,
                msgstr="" if not pot_entry.msgid_plural else None,
                msgstr_plural=({i: "" for i in range(2)}
                               if pot_entry.msgid_plural else None),
                comment=pot_entry.comment,
                occurrences=pot_entry.occurrences,
            )
            if pot_entry.flags:
                new_entry.flags = list(pot_entry.flags)

        new_po.append(new_entry)

    new_po.save(str(po_path))
    translated = len([e for e in new_po if e.msgstr or
                      (e.msgstr_plural and any(e.msgstr_plural.values()))])
    print(f"Updated {po_path} ({translated}/{len(new_po)} translated)")


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
        total = len(po)
        translated_count = len(po.translated_entries())
        pct = (translated_count / total * 100) if total > 0 else 0

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

        out_path = glossary_path.parent / f"glossary.{lang}.yaml"
        with open(out_path, "w", encoding="utf-8") as f:
            yaml.dump(sorted_translations, f)

        print(f"Generated {out_path} ({len(sorted_translations)} entries)")


def main():
    parser = argparse.ArgumentParser(
        description="Convert glossary.yaml to/from monolingual gettext PO"
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
        help="Directory containing .po files (default: po/)",
    )
    parser.add_argument(
        "--languages",
        type=lambda s: s.split(","),
        default=DEFAULT_LANGUAGES,
        help="Comma-separated language codes",
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

    # Always extract and merge
    yaml_to_pot(args.glossary, args.pot)

    for lang in args.languages:
        po_path = args.po_dir / f"glossary.{lang}.po"
        merge_po(args.pot, po_path)

    if args.generate_yaml:
        generate_yaml(args.po_dir, args.glossary, args.languages,
                      threshold=args.threshold)


if __name__ == "__main__":
    main()
