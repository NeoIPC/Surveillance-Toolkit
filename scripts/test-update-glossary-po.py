#!/usr/bin/env python3
"""Regression test for update-glossary-po.py: it runs the script and checks what it wrote.

Two invariants are covered, and they need different techniques because one of them cannot be
observed from the output on every platform.

**Byte hygiene.** All three artifacts the script produces -- po/glossary.pot, po/glossary.<lang>.po
and glossary.<lang>.yaml -- are committed and read by other tools (Weblate's msgmerge add-on, the
reports' R string-resource cascade). Python's io.open() default translates every "\\n" to os.linesep,
so without an explicit newline="\\n" the same script emits CRLF on Windows and LF on Linux. The end-
to-end run below asserts the bytes of every artifact.

**That assertion cannot catch a revert on Linux**, where os.linesep is already "\\n": deleting every
newline="\\n" changes nothing observable. So the pinning is *also* asserted against the source, which
is platform-independent and fails the moment a writer call loses its newline argument. An earlier
version of this file tested neither -- it reimplemented the writers with the argument hard-coded, so
it asserted that polib and ruamel work, and would have passed with the fix reverted.

**Content round-trip.** The script's non-obvious behaviour is that a comment above a key becomes a
translator note while the file's header block does not, and that YAML keys become msgctxt. Those are
checked too, since a silent regression there loses every translator note without touching a byte of
line-ending hygiene.

**Plural-form count.** A new plural entry must get as many msgstr[N] forms as its locale's rule
declares. This one also needs two techniques, and for the same reason as the byte hygiene: every
locale configured today is nplurals=2, so a hard-coded 2 and a derived one agree, and the functional
check would pass with the derivation reverted. The source scan is what makes the revert visible.

Why a standalone script rather than pytest: this repository has no Python test infrastructure and its
CI installs no Python at all (Perl for po4a, .NET, PowerShell -- never Python), so
update-glossary-po.py is a developer-machine-only tool. CI-side coverage for the byte invariant comes
from the text-hygiene gate, which rejects any committed file carrying CRLF or a BOM.

Run it after touching the script:

    python scripts/test-update-glossary-po.py
"""

import importlib.util
import re
import subprocess
import sys
import tempfile
from pathlib import Path

try:
    import polib
except ImportError:
    sys.exit("Error: polib is required. Install with: pip install polib")

SCRIPT = Path(__file__).resolve().parent / "update-glossary-po.py"

# A header block, a blank line, then keys -- one carrying a comment and a flags line. The blank line
# is load-bearing: the script splits the leading comment tokens on the last blank line, so without it
# the header would be read as a note on the first key.
GLOSSARY_YAML = """\
# Test glossary header, two lines long.
# It must not surface as a translator note on the first key.

# WHO AWaRe antibiotic category; the official rendering is normative.
# flags: terminology
access: "Access"
charite: "Charité test"
necrotising_enterocolitis: "necrotising enterocolitis"
"""


def read_bytes(path):
    with open(path, "rb") as handle:
        return handle.read()


def check_bytes(label, data, failures):
    """Assert the written bytes carry no CR and no UTF-8 BOM."""
    if b"\r" in data:
        failures.append(f"{label}: contains CR (0x0D) -- line endings are not LF")
    if data.startswith(b"\xef\xbb\xbf"):
        failures.append(f"{label}: starts with a UTF-8 BOM")


def _code_only(source):
    """Blank out docstrings and comments so a source scan cannot match prose about the code."""
    source = re.sub(r'"""(?:.|\n)*?"""', '""', source)
    source = re.sub(r"'''(?:.|\n)*?'''", "''", source)
    return re.sub(r"(?m)#.*$", "", source)


def _call_arguments(source, opening_pattern):
    """Yield the full argument text of each call matching opening_pattern.

    Parenthesis-balanced on purpose: a naive `[^)]*` stops at the first ')', which in
    `pot.save(str(pot_path), newline="\\n")` is the one closing `str(` -- so the newline argument is
    never seen and every call looks unpinned. That bug made an earlier version of this check report
    four false failures and, worse, report them identically whether or not the fix was present.
    """
    for match in re.finditer(opening_pattern, source):
        index = match.end()
        depth = 1
        while index < len(source) and depth:
            if source[index] == "(":
                depth += 1
            elif source[index] == ")":
                depth -= 1
            index += 1
        yield source[match.end():index - 1]


def check_writers_pin_newline(failures):
    """Every writer call in the script must pass newline="\\n".

    This is the only check that can fail on a platform whose os.linesep is already LF, which is
    where this test usually runs. polib's .save() forwards the argument to io.open(); a bare
    open(..., "w") has the same default. Both are matched.
    """
    # Scan code only. The script's own comments discuss "polib.save() forwards it to io.open()",
    # and matching that prose reports a call that does not exist -- a false failure that is also
    # indistinguishable from a real one.
    source = _code_only(SCRIPT.read_text(encoding="utf-8"))

    saves = list(_call_arguments(source, r"\.save\("))
    for call in saves:
        if 'newline="\\n"' not in call:
            failures.append(
                f'update-glossary-po.py: .save({call.strip()}) does not pin newline="\\n" -- '
                "it will emit CRLF on Windows"
            )

    writes = [c for c in _call_arguments(source, r"(?<![\w.])open\(") if '"w"' in c]
    for call in writes:
        if 'newline="\\n"' not in call:
            failures.append(
                f'update-glossary-po.py: open({call.strip()}) does not pin newline="\\n" -- '
                "it will emit CRLF on Windows"
            )

    if not saves and not writes:
        failures.append(
            "update-glossary-po.py: found no writer calls to check -- this test's source scan has "
            "gone stale and is silently asserting nothing"
        )


def load_generator():
    """Import update-glossary-po.py as a module.

    Its filename is not an identifier, so importlib is the only route. Importing it is safe: everything
    below the constants and helpers sits behind the __main__ guard. Bytecode writing is suppressed first --
    the import would otherwise leave an untracked scripts/__pycache__/ behind on every run, and this
    repository produces no Python bytecode anywhere else to have taught .gitignore about.
    """
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location("update_glossary_po", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def check_plural_form_count(failures):
    """A new plural entry gets as many forms as its locale's rule declares -- derived, never assumed."""
    module = load_generator()

    # Written independently of the generator's pattern rather than importing it: reusing the
    # implementation's own regex would compare it against itself and pass however wrong it is. It has to
    # be at least as permissive, though, or an entry the generator parses fine reports here as a
    # generator defect -- so whitespace around the "=" is accepted, as it is there.
    #
    # The two literals are identical today, which makes the duplication look accidental. It is not: fold
    # them into one shared constant and this check silently stops being able to detect a wrong pattern,
    # because it would then be using it. The protection is prospective -- when the generator's regex
    # changes, this one does not follow, the check goes red, and someone looks.
    declares = re.compile(r"\bnplurals\s*=\s*(\d+)")

    for lang, rule in module.PLURAL_FORMS.items():
        match = declares.search(rule)
        if not match:
            # Report it; do not let .group() raise, which would abort this function and take every
            # later check in it down with the one bad entry.
            failures.append(
                f"PLURAL_FORMS[{lang!r}] declares no nplurals: {rule!r} -- the number of forms a new "
                "plural entry gets is read from it"
            )
            continue
        declared = int(match.group(1))
        derived = module._plural_form_count(lang)
        if derived != declared:
            failures.append(
                f"_plural_form_count({lang!r}) returned {derived}, but that locale's rule declares "
                f"nplurals={declared}"
            )

    # The generator must refuse a malformed rule rather than default to a count. Exercised on an
    # in-memory entry; the real table is untouched.
    module.PLURAL_FORMS["xx"] = "plural=n != 1;"
    try:
        module._plural_form_count("xx")
    except ValueError:
        pass
    except KeyError:
        failures.append("_plural_form_count('xx') raised KeyError -- the malformed-rule branch is unreachable")
    else:
        failures.append(
            "_plural_form_count('xx') did not raise on a rule declaring no nplurals -- a malformed entry "
            "would silently decide how many forms every new plural entry gets"
        )
    finally:
        del module.PLURAL_FORMS["xx"]

    # 'ru' is the concrete case, not a hypothetical one: this repository prefers the official WHO
    # translation where one exists, and Russian is one of the six WHO languages -- at nplurals=3.
    for lang in ("zz", "ru"):
        try:
            module._plural_form_count(lang)
        except KeyError:
            pass
        else:
            failures.append(
                f"_plural_form_count({lang!r}) did not raise -- an unconfigured locale would have its "
                "number of plural forms guessed rather than refused"
            )

    # The scan above cannot fail while every configured locale is nplurals=2, because a hard-coded 2
    # returns the right answer by coincidence. This is the check that goes red on a revert.
    source = _code_only(SCRIPT.read_text(encoding="utf-8"))
    initialisers = list(_call_arguments(source, r"msgstr_plural=\("))
    for call in initialisers:
        if re.search(r"range\(\s*\d", call):
            failures.append(
                f"update-glossary-po.py: msgstr_plural=({call.strip()}) hard-codes its form count -- it "
                "must be read from PLURAL_FORMS, or adding a locale with nplurals != 2 writes a catalogue "
                "whose header and structure disagree"
            )
    if not initialisers:
        failures.append(
            "update-glossary-po.py: found no msgstr_plural initialiser to check -- this test's source scan "
            "has gone stale and is silently asserting nothing"
        )


def run_script(tmp, *extra):
    """Invoke the real script; return its CompletedProcess."""
    return subprocess.run(
        [
            sys.executable,
            str(SCRIPT),
            "--glossary", str(tmp / "glossary.yaml"),
            "--pot", str(tmp / "po" / "glossary.pot"),
            "--po-dir", str(tmp / "po"),
            "--languages", "de",
            *extra,
        ],
        capture_output=True,
        text=True,
    )


def main():
    failures = []

    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        (tmp / "po").mkdir()
        (tmp / "glossary.yaml").write_text(GLOSSARY_YAML, encoding="utf-8", newline="\n")

        # 1. Run the script for real: glossary.yaml -> .pot, then merged into glossary.de.po.
        result = run_script(tmp)
        if result.returncode != 0:
            print(f"FAIL update-glossary-po.py exited {result.returncode}")
            print(result.stdout)
            print(result.stderr)
            return 1

        pot_path = tmp / "po" / "glossary.pot"
        po_path = tmp / "po" / "glossary.de.po"
        for label, path in (("glossary.pot", pot_path), ("glossary.de.po", po_path)):
            if not path.exists():
                failures.append(f"{label}: the script did not write it")
                continue
            check_bytes(label, read_bytes(path), failures)

        # 2. The content round-trip: keys became msgctxt, the key comment became a translator note,
        #    the header block did NOT, flags survived, and non-ASCII is intact.
        if pot_path.exists():
            pot_text = pot_path.read_text(encoding="utf-8")
            if 'msgctxt "access"' not in pot_text:
                failures.append("glossary.pot: key 'access' did not become a msgctxt")
            if "WHO AWaRe antibiotic category" not in pot_text:
                failures.append("glossary.pot: the key's comment did not become a translator note")
            if "must not surface as a translator note" in pot_text:
                failures.append(
                    "glossary.pot: the file header block leaked into the catalogue as a note -- "
                    "the blank-line split that separates header from first-key comment has broken"
                )
            if "terminology" not in pot_text:
                failures.append("glossary.pot: the 'flags: terminology' line did not reach the entry")
            if "Charité test" not in pot_text:
                failures.append("glossary.pot: non-ASCII content did not survive the round trip")

        # 3. Translate, then run again with --generate-yaml to exercise the third writer.
        if po_path.exists():
            po = polib.pofile(str(po_path))
            for entry in po:
                entry.msgstr = "Übersetzung"
            po.save(str(po_path), newline="\n")

            result = run_script(tmp, "--generate-yaml", "--threshold", "0")
            if result.returncode != 0:
                failures.append(f"--generate-yaml exited {result.returncode}: {result.stderr.strip()}")
            else:
                yaml_path = tmp / "glossary.de.yaml"
                if not yaml_path.exists():
                    failures.append("glossary.de.yaml: the script did not write it")
                else:
                    check_bytes("glossary.de.yaml", read_bytes(yaml_path), failures)
                    if "Übersetzung" not in yaml_path.read_text(encoding="utf-8"):
                        failures.append("glossary.de.yaml: the translation did not reach the output")

        # 4. The source-level pinning, which is what can go red on a LF platform.
        check_writers_pin_newline(failures)

        # 5. The plural-form count is derived from the locale's rule, not hard-coded.
        check_plural_form_count(failures)

        # 6. Prove the byte detector itself works, so a vacuous pass is impossible.
        detector = []
        check_bytes("detector probe (CRLF)", b'msgid "a"\r\nmsgstr "b"\r\n', detector)
        check_bytes("detector probe (BOM)", b'\xef\xbb\xbfmsgid "a"\n', detector)
        if len(detector) != 2:
            failures.append(
                "self-check failed: check_bytes() did not flag planted CRLF and BOM bytes, so every "
                f"byte assertion here is vacuous (got {len(detector)} of 2 expected findings)"
            )

    if failures:
        for failure in failures:
            print(f"FAIL {failure}")
        return 1

    print("PASS update-glossary-po.py writes LF, no BOM, and round-trips notes, flags and msgctxt")
    return 0


if __name__ == "__main__":
    sys.exit(main())
