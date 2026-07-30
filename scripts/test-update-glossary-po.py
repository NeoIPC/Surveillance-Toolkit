#!/usr/bin/env python3
"""Regression test for update-glossary-po.py: it runs the script and checks what it wrote.

Three invariants are covered, and they need different techniques — one of them because it cannot be
observed from the output on every platform, the others because the obvious observation is vacuous.

**Catalogue ownership.** po/glossary.<lang>.po belongs to Weblate's neoipc-glossary component. This
script writes the template and must not touch a catalogue -- two writers on one .po is what conflicts
every language at once, both sides rewriting adjacent header lines inside a hunk git cannot merge.
The check runs the script over a directory already holding a catalogue and asserts that file is
byte-identical afterwards, which is the property that matters and is invisible in a diff of the
script. The CI gate enforces the same rule from the other end, by rejecting a commit that changes an
owned catalogue outside Weblate; this catches it before a commit exists.

**BOTH invocations are bracketed, and that is not redundant.** The bare run and the --generate-yaml run
take different paths: only the latter opens a catalogue into a mutable polib object, and it is the one
the pipeline actually invokes. An earlier version asserted the bare run alone; a catalogue writer
planted inside generate_yaml passed the entire suite green. Assert both, or the assertion covers the
path where the mistake is least likely.

**Byte hygiene.** Both artifacts the script produces -- po/glossary.pot and glossary.<lang>.yaml --
are committed and read by other tools (Weblate's msgmerge add-on, the reports' R string-resource
cascade). Python's io.open() default translates every "\\n" to os.linesep, so without an explicit
newline="\\n" the same script emits CRLF on Windows and LF on Linux. The end-to-end run below asserts
the bytes of every artifact.

**That assertion cannot catch a revert on Linux**, where os.linesep is already "\\n": deleting every
newline="\\n" changes nothing observable. So the pinning is *also* asserted against the source, which
is platform-independent and fails the moment a writer call loses its newline argument. An earlier
version of this file tested neither -- it reimplemented the writers with the argument hard-coded, so
it asserted that polib and ruamel work, and would have passed with the fix reverted.

**Content round-trip.** The script's non-obvious behaviour is that a comment above a key becomes a
translator note while the file's header block does not, and that YAML keys become msgctxt. Those are
checked too, since a silent regression there loses every translator note without touching a byte of
line-ending hygiene.

Why a standalone script rather than pytest: this repository has no Python test infrastructure and its
CI installs no Python at all (Perl for po4a, .NET, PowerShell -- never Python), so
update-glossary-po.py is a developer-machine-only tool. CI-side coverage for the byte invariant comes
from the text-hygiene gate, which rejects any committed file carrying CRLF or a BOM.

Run it after touching the script:

    python scripts/test-update-glossary-po.py
"""

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


def check_leaves_catalogues_alone(tmp, failures):
    """The script must not touch po/glossary.<lang>.po -- those belong to Weblate.

    Asserted on the bytes of a catalogue that already exists, because that is the property with
    consequences. A source scan for "no .po writer" would pass the moment someone reintroduced one
    under a different name, and the damage from two writers is not visible in a diff of this script
    at all -- it shows up later as a conflict in every language of the catalogue at once.

    The fixture deliberately carries a stale msgid the template no longer has, plus a real
    translation. A reintroduced merge would rewrite the header, drop the stale entry, or both, and
    every one of those changes the bytes.
    """
    po_path = tmp / "po" / "glossary.de.po"
    stale = (
        "# German translations for the NeoIPC Surveillance Glossary\n"
        "# Copyright (C) Charité – Universitätsmedizin Berlin\n"
        "#\n"
        'msgid ""\n'
        'msgstr ""\n'
        '"Language: de\\n"\n'
        '"MIME-Version: 1.0\\n"\n'
        '"Content-Type: text/plain; charset=UTF-8\\n"\n'
        '"Content-Transfer-Encoding: 8bit\\n"\n'
        "\n"
        'msgctxt "a_key_the_template_does_not_have"\n'
        'msgid "Gone"\n'
        'msgstr "Weg"\n'
    )
    po_path.write_text(stale, encoding="utf-8", newline="\n")
    before = read_bytes(po_path)

    result = run_script(tmp)
    if result.returncode != 0:
        failures.append(f"the script exited {result.returncode} with a catalogue present: {result.stderr.strip()}")
        return

    after = read_bytes(po_path)
    if after != before:
        failures.append(
            "po/glossary.de.po changed -- this script must write only the template. A catalogue writer "
            "here puts two writers on one Weblate-owned file, which conflicts every language at once."
        )
    for name in ("glossary.af.po", "glossary.fr.po"):
        if (tmp / "po" / name).exists():
            failures.append(f"po/{name} was created -- Weblate creates a catalogue from new_base, not this script")


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


def check_committed_template_matches_source(tmp, failures):
    """po/glossary.pot must be what glossary.yaml currently produces.

    This is the one relationship the repository still owns end to end, and nothing was checking it.
    It broke immediately: a commit added two flag comments, regenerated the template, then reworded a
    header comment from one line to two and did not regenerate again — leaving all 41 `#:` location
    references pointing one line early. Because `po_no_location` is deliberately false so those become
    clickable links, and because msgmerge copies locations from the template into every catalogue, a
    stale template propagates the error to all nine languages on the next drain.

    Asserted against the REAL committed files rather than a fixture, since a fixture cannot go stale.
    POT-Creation-Date is excluded — it moves on every run by design.
    """
    repo = SCRIPT.parent.parent
    out = tmp / "parity"
    out.mkdir()
    # An ABSOLUTE --glossary on purpose. It used to change the "#:" locations, because the generator
    # wrote the path it was handed straight into a committed file — so this call both compares the
    # template and asserts that the location no longer depends on how the caller spelt the path.
    result = subprocess.run(
        [sys.executable, str(SCRIPT),
         "--glossary", str(repo / "glossary.yaml"),
         "--pot", str(out / "glossary.pot"),
         "--po-dir", str(out)],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        failures.append(f"regenerating the template from the committed glossary.yaml failed: "
                        f"{result.stderr.strip()[:200]}")
        return

    def comparable(path):
        text = path.read_text(encoding="utf-8")
        return [ln for ln in text.split("\n") if not ln.startswith('"POT-Creation-Date:')]

    committed = repo / "po" / "glossary.pot"
    if comparable(committed) != comparable(out / "glossary.pot"):
        failures.append(
            "po/glossary.pot is not what glossary.yaml produces — run "
            "`python scripts/update-glossary-po.py` and commit the result. Most likely a glossary.yaml "
            "edit changed line numbers after the template was last generated."
        )


def main():
    failures = []

    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        (tmp / "po").mkdir()
        (tmp / "glossary.yaml").write_text(GLOSSARY_YAML, encoding="utf-8", newline="\n")

        # 1. Run the script for real: glossary.yaml -> glossary.pot, and nothing else under po/.
        result = run_script(tmp)
        if result.returncode != 0:
            print(f"FAIL update-glossary-po.py exited {result.returncode}")
            print(result.stdout)
            print(result.stderr)
            return 1

        pot_path = tmp / "po" / "glossary.pot"
        po_path = tmp / "po" / "glossary.de.po"
        if not pot_path.exists():
            failures.append("glossary.pot: the script did not write it")
        else:
            check_bytes("glossary.pot", read_bytes(pot_path), failures)
        if po_path.exists():
            failures.append(
                "po/glossary.de.po was created from an empty po/ -- the catalogues are Weblate's, and "
                "Weblate creates a new one from new_base"
            )

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

        # 3. Stand in for Weblate: write the catalogue this script no longer writes, translate it, and
        #    run --generate-yaml, which reads it. The fixture is built from the template so the msgctxt
        #    keys match; only Weblate's role is being simulated, not its file format.
        if pot_path.exists():
            pot = polib.pofile(str(pot_path))
            weblate_po = polib.POFile()
            # Shaped the way WEBLATE writes a catalogue, not the way polib defaults to. This is
            # load-bearing for the ownership check below: at polib's default wrapwidth of 78 a short
            # fixture is a polib FIXED POINT, so a re-save produces identical bytes and the byte
            # comparison cannot see a writer at all. A planted po.save() passed the whole suite green
            # until this line existed. 65535 is what every component declares, and the long entry below
            # is what makes the difference observable.
            weblate_po.wrapwidth = 65535
            weblate_po.header = (
                "German translations for the NeoIPC Surveillance Glossary\n"
                "Copyright (C) Charité – Universitätsmedizin Berlin\n"
            )
            weblate_po.metadata = {
                "Language": "de",
                "MIME-Version": "1.0",
                "Content-Type": "text/plain; charset=UTF-8",
                "Content-Transfer-Encoding": "8bit",
            }
            for entry in pot:
                weblate_po.append(polib.POEntry(
                    msgctxt=entry.msgctxt, msgid=entry.msgid, msgstr="Übersetzung",
                ))
            # One entry longer than polib's default wrap width, so the fixture is NOT a polib fixed
            # point. Without it every line is short enough that polib re-serialises the file
            # identically whatever its wrapwidth, and the ownership assertion below is vacuous.
            weblate_po.append(polib.POEntry(
                msgctxt="a_long_entry_so_the_fixture_is_not_a_polib_fixed_point",
                msgid="This project has received funding from the European Union's Horizon 2020 "
                      "research and innovation programme under grant agreement number 965328.",
                msgstr="Dieses Projekt wurde aus dem Forschungs- und Innovationsprogramm Horizont "
                       "2020 der Europäischen Union unter der Finanzhilfevereinbarung Nummer 965328 "
                       "gefördert.",
            ))
            weblate_po.save(str(po_path), newline="\n")

            # Bracket THIS run, not just the bare one. --generate-yaml is the mode the pipeline actually
            # invokes (Invoke-Localization.ps1 passes it), and generate_yaml is the only place the script
            # opens a catalogue into a mutable polib object -- so it is where an accidental po.save() is
            # one line away. Asserted here rather than only in step 5 because a writer added inside
            # generate_yaml passed the whole suite green: proven by planting one, not assumed.
            before_generate = read_bytes(po_path)

            result = run_script(tmp, "--generate-yaml", "--threshold", "0")
            if result.returncode != 0:
                failures.append(f"--generate-yaml exited {result.returncode}: {result.stderr.strip()}")
            else:
                # The BELOW-threshold path too, which is the one a normal -Update takes for every
                # language today -- nine catalogues sit far under the default 80 -- so leaving it
                # unbracketed leaves the common branch unguarded. The fixture is fully translated, so
                # an impossible threshold is what forces the skip.
                before_skip = read_bytes(po_path)
                skipped = run_script(tmp, "--generate-yaml", "--threshold", "101")
                if skipped.returncode != 0:
                    failures.append(f"--generate-yaml (skip path) exited {skipped.returncode}")
                elif read_bytes(po_path) != before_skip:
                    failures.append(
                        "po/glossary.de.po changed on the below-threshold path of --generate-yaml -- "
                        "the branch that skips a language must still not write its catalogue"
                    )
                elif "Skipped de" not in skipped.stdout:
                    failures.append(
                        "the below-threshold path did not report skipping -- this check is asserting "
                        f"nothing (stdout: {skipped.stdout.strip()[:120]!r})"
                    )

                if read_bytes(po_path) != before_generate:
                    failures.append(
                        "po/glossary.de.po changed during --generate-yaml -- that path reads the catalogue "
                        "and must not write it. A writer there is two writers on a Weblate-owned file."
                    )
                yaml_path = tmp / "glossary.de.yaml"
                if not yaml_path.exists():
                    failures.append("glossary.de.yaml: the script did not write it")
                else:
                    check_bytes("glossary.de.yaml", read_bytes(yaml_path), failures)
                    if "Übersetzung" not in yaml_path.read_text(encoding="utf-8"):
                        failures.append("glossary.de.yaml: the translation did not reach the output")

        # 4. The source-level pinning, which is what can go red on a LF platform.
        check_writers_pin_newline(failures)

        # 5. Ownership: a catalogue already in po/ must come out byte-identical.
        check_leaves_catalogues_alone(tmp, failures)

        # 6. The ABSENT-catalogue branch. Weblate creates a catalogue for a new language from new_base;
        #    this script must not, and a writer planted in that branch would create all nine at once.
        #    Cheaper to assert than to reason about: run over a po/ holding only the template.
        absent = tmp / "absent"
        (absent / "po").mkdir(parents=True)
        (absent / "glossary.yaml").write_text(GLOSSARY_YAML, encoding="utf-8", newline="\n")
        r = subprocess.run(
            [sys.executable, str(SCRIPT),
             "--glossary", str(absent / "glossary.yaml"),
             "--pot", str(absent / "po" / "glossary.pot"),
             "--po-dir", str(absent / "po"),
             "--languages", "de,fr,af", "--generate-yaml", "--threshold", "0"],
            capture_output=True, text=True,
        )
        if r.returncode != 0:
            failures.append(f"run over a catalogue-less po/ exited {r.returncode}: {r.stderr.strip()[:160]}")
        else:
            created = sorted(p.name for p in (absent / "po").glob("glossary.*.po"))
            if created:
                failures.append(
                    f"the script created {created} from an empty po/ — Weblate creates a catalogue for a "
                    "new language from new_base, and a writer in that branch creates every language at once"
                )

        # 7. Prove the committed template is what the committed source produces.
        check_committed_template_matches_source(tmp, failures)

        # 8. Prove the byte detector itself works, so a vacuous pass is impossible.
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
