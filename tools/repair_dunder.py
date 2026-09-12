"""One-shot repair of token damage introduced by the writing pipeline.

The pipeline has, at various moments, dropped leading underscores from dunder
names and mangled a few dotted identifiers while writing. This script applies
the deterministic repairs and reports what remains suspicious. Every fixed
string is constructed from character codes so that this file cannot itself be
corrupted by the very pattern it repairs. Idempotent: safe to run repeatedly.

Usage: python3 tools/repair_dunder.py
"""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
U = chr(95)                       # the underscore character
D = U + U                         # the double underscore of dunder names

# The dunder protocol names, built from characters: (broken regex, fixed)
DUNDER_FIXES = [
    (r"def " + U + r"init" + D + r"\(", "def " + D + "init" + D + "("),
    (r"def " + D + U + r"init" + D + r"\(", "def " + D + "init" + D + "("),
    (r"def " + U + r"init" + U + r"\(", "def " + D + "init" + D + "("),
    (r"def " + U + r"post" + U + r"init" + U + r"\(", "def " + D + "init" + D + "("),
    (r"def " + D + r"post_init" + D + r"\(", "def " + D + "init" + D + "("),
    (r"def " + U + r"iter" + U + r"\(", "def " + D + "iter" + D + "("),
    (r"def " + U + r"len" + U + r"\(", "def " + D + "len" + D + "("),
    (r"def " + U + r"lt" + U + r"\(", "def " + D + "lt" + D + "("),
    (r"def " + U + r"eq" + U + r"\(", "def " + D + "eq" + D + "("),
    (r"def " + U + r"repr" + U + r"\(", "def " + D + "repr" + D + "("),
]

# Identifier repairs: broken -> fixed, each constructed from characters.
IDENTIFIER_FIXES = [
    ("frozen" + U + "set", "frozen" + U + "set"),        # already correct; identity
    ("is" + U + "instance", "is" + U + "instance"),      # identity guard
]


def repair_text(text):
    """Apply every deterministic repair to one module's text. Returns new text."""
    for pattern, fixed in DUNDER_FIXES:
        text = re.sub(pattern, fixed, text)
    # name mangling guard: __name__ == '__main__' written without quotes
    text = re.sub(
        "if " + D + "name" + D + " == " + D + "main" + D + ":",
        'if ' + D + 'name' + D + ' == "' + D + 'main' + D + '":',
        text,
    )
    return text


SUSPECTS = ("def " + U + "init", "def " + D + "post_init",
            "frozen" + U + "set" + "(", "is" + U + "instance" + "(")


def scan_suspects(path):
    """Return the suspect shapes still present in one file (report only)."""
    text = path.read_text(encoding="utf-8")
    found = []
    for needle in SUSPECTS:
        if needle in text:
            found.append(needle)
    return found


def main():
    changed = []
    suspects = []
    for path in sorted(ROOT.rglob("**/*.py")):
        if ".venv" in path.parts or ".git" in path.parts:
            continue
        original = path.read_text(encoding="utf-8")
        repaired = repair_text(original)
        if repaired != original:
            path.write_text(repaired, encoding="utf-8")
            changed.append(str(path.relative_to(ROOT)))
        left = scan_suspects(path)
        if left:
            suspects.append(f"{path.relative_to(ROOT)}: {left}")
    print("repaired:", changed or "nothing (already clean)")
    print("suspects remaining:", suspects or "none")


if __name__ == "__main__":
    main()
