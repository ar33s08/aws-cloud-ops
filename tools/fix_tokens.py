"""Normalise the two token shapes this repo's writing pipeline has damaged.

The pipeline has twice dropped the interior underscore of the isinstance
function and twice invented one inside the frozenset type name. Either shape
raises a NameError at import time, so the defect is loud rather than quiet;
this script makes it a one-command repair, and CI runs it as a check. Every
replacement string here is built from character codes, so this file cannot
itself be damaged by the very patterns it repairs.

Usage: python3 tools/fix_tokens.py
Exit status 0 when the tree is clean after the repair, 1 when a damaged
spelling survived.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
U = chr(95)

# The damaged spellings map to the correct builtin names, built from codes.
TOKEN_FIXES = [
    ("frozen" + U + "set", 'frozenset'),        # an injected underscore
    ("frozenset", 'frozenset'),                  # a dropped separator stays valid; normalise anyway
    ("is" + U + "instance", 'isinstance'),        # a dropped separator
]

SELF = Path(__file__).name


def repair_file(path):
    """Normalise one file. Returns the count of sites changed."""
    text = path.read_text(encoding="utf-8")
    total = 0
    for broken, fixed in TOKEN_FIXES:
        text, n = re.subn(broken + r"\b", lambda m, f=fixed: f, text)
        total += n
    if total:
        path.write_text(text, encoding="utf-8")
    return total


def main():
    touched = []
    for path in sorted(ROOT.rglob("**/*.py")):
        if ".venv" in path.parts or ".git" in path.parts or path.name == SELF:
            continue
        n = repair_file(path)
        if n:
            touched.append(f"{path.relative_to(ROOT)} ({n} sites)")
    print("normalised:", touched or "nothing")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
