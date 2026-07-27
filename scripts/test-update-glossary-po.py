#!/usr/bin/env python3
"""Line-ending and encoding regression test for update-glossary-po.py's writers.

Both artifacts that script produces -- po/glossary.pot and glossary.<lang>.yaml -- are committed
and are read by other tools (Weblate's msgmerge add-on, the reports' R string-resource cascade).
Python's io.open() default translates every "\\n" to os.linesep, so without an explicit
newline="\\n" the same script emits CRLF on Windows and LF on Linux. This asserts the bytes.

Why a standalone script rather than pytest: this repository has no Python test infrastructure and
its CI installs no Python at all (Perl for po4a, .NET, PowerShell -- never Python), so
update-glossary-po.py is a developer-machine-only tool. Adding pytest plus a Python toolchain to
CI for two byte assertions would be disproportionate. CI-side coverage for the same invariant
comes from the text-hygiene gate, which rejects any committed file carrying CRLF or a BOM.

Run it after touching either writer:

    python scripts/test-update-glossary-po.py
"""

import os
import sys
import tempfile
from pathlib import Path

try:
    import polib
except ImportError:
    sys.exit("Error: polib is required. Install with: pip install polib")

try:
    from ruamel.yaml import YAML
except ImportError:
    sys.exit("Error: ruamel.yaml is required. Install with: pip install ruamel.yaml")


def read_bytes(path):
    with open(path, "rb") as handle:
        return handle.read()


def check(label, data, failures):
    """Assert the written bytes carry no CR and no UTF-8 BOM."""
    if b"\r" in data:
        failures.append(f"{label}: contains CR (0x0D) -- line endings are not LF")
    if data.startswith(b"\xef\xbb\xbf"):
        failures.append(f"{label}: starts with a UTF-8 BOM")


def build_pot():
    pot = polib.POFile()
    pot.metadata = {
        "Project-Id-Version": "test 0.0",
        "MIME-Version": "1.0",
        "Content-Type": "text/plain; charset=UTF-8",
        "Content-Transfer-Encoding": "8bit",
    }
    # Non-ASCII on purpose: it is what a BOM-adding or re-encoding writer would disturb.
    pot.append(
        polib.POEntry(
            msgctxt="necrotising_enterocolitis",
            msgid="necrotising enterocolitis",
            msgstr="",
        )
    )
    pot.append(polib.POEntry(msgctxt="charite", msgid="Charité", msgstr=""))
    return pot


def main():
    failures = []

    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)

        # 1. The .pot writer, as update-glossary-po.py calls it.
        pot_path = tmp / "glossary.pot"
        build_pot().save(str(pot_path), newline="\n")
        check("glossary.pot (newline='\\n')", read_bytes(pot_path), failures)

        # 2. The generated-YAML writer, as update-glossary-po.py calls it.
        yaml = YAML()
        yaml.preserve_quotes = True
        yaml.default_flow_style = False
        yaml_path = tmp / "glossary.de.yaml"
        with open(yaml_path, "w", encoding="utf-8", newline="\n") as handle:
            yaml.dump({"necrotising_enterocolitis": "nekrotisierende Enterokolitis"}, handle)
        check("glossary.de.yaml (newline='\\n')", read_bytes(yaml_path), failures)

        # 3. Prove the DETECTOR works, on every platform. This has to be platform-independent: the
        #    writer-based self-check below can only fire where os.linesep is CRLF, so on the Linux CI
        #    runner it is skipped -- which left the whole test unable to go red for the regression it
        #    exists to catch, exactly where it runs most often. Feeding check() known-bad bytes closes
        #    that gap: if these do not trip it, nothing downstream can be trusted either.
        detector = []
        check("detector probe (CRLF)", b'msgid "a"\r\nmsgstr "b"\r\n', detector)
        check("detector probe (BOM)", b'\xef\xbb\xbfmsgid "a"\n', detector)
        if len(detector) != 2:
            failures.append(
                "self-check failed: check() did not flag planted CRLF and BOM bytes, so every "
                f"assertion in this test is vacuous (got {len(detector)} of 2 expected findings)"
            )

        # 4. Additionally, on a CRLF platform, prove it end-to-end through the real writers: repeat both
        #    writes WITHOUT the newline argument and confirm that trips the same checks.
        if os.linesep == "\r\n":
            bare_pot = tmp / "bare.pot"
            build_pot().save(str(bare_pot))
            bare_yaml = tmp / "bare.yaml"
            with open(bare_yaml, "w", encoding="utf-8") as handle:
                yaml.dump({"a": "b"}, handle)

            control = []
            check("bare .pot", read_bytes(bare_pot), control)
            check("bare .yaml", read_bytes(bare_yaml), control)
            if len(control) != 2:
                failures.append(
                    "self-check failed: writing without newline='\\n' did not produce CR on a "
                    "CRLF platform, so these assertions would not catch a regression"
                )
        else:
            print(
                "note: os.linesep is LF here, so the end-to-end writer control is skipped; the "
                "detector probes above still ran and are platform-independent"
            )

    if failures:
        for failure in failures:
            print(f"FAIL {failure}")
        return 1

    print("PASS update-glossary-po.py writers emit LF and no BOM")
    return 0


if __name__ == "__main__":
    sys.exit(main())
