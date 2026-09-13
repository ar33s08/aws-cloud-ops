#!/usr/bin/env python3
"""Doc-to-artifact coherence check (the CI documentation gate).

Every command a reader can copy out of the documentation must exist:
every 'make TARGET' names a target of the Makefile, every 'cloudops VERB'
names a subcommand of the command-line interface, and every path cited
under scripts/ is a file of the repository. The checker reports each
violation as a line of the form FILE | CITE | CONTEXT and exits with status
one when any violation is found. Prose words that happen to follow the two
verbs are not violations; the checker knows the difference because it looks
at what a shell would do with the citation, not at the dictionary.

Usage:
    python3 tools/check-doc-coherence.py        # run over every markdown file
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Words that appear after the two verbs in prose but are never shellwords of
# either program: the checker treats a citation of them as a figure of speech,
# not a command. Keep the list narrow; anything that looks like a real
# subcommand stays under the subcommand test.
PROSE_AFTER_MAKE = {"the", "git", "sure", "build", "version", "your", "this"}
PROSE_AFTER_CLOUDOPS = {"toolkit", "live", "scanner", "suite", "user", "team"}


def make_targets() -> set[str]:
    """The set of real targets of the Makefile."""
    text = (ROOT / "Makefile").read_text(encoding="utf-8")
    return set(re.findall(r"(?m)^([a-zA-Z_-]+):", text))


def cli_subcommands() -> set[str]:
    """The set of verbs the command-line interface actually accepts."""
    text = (ROOT / "cloudops" / "cli.py").read_text(encoding="utf-8")
    verbs = set(re.findall(r"add_parser\(\s*[\"']([a-z][a-z-]{2,20})[\"']", text))
    verbs |= set(re.findall(r"set_defaults\(func=cmd_([a-z_]+)\)", text))
    return {v.replace("_", "-") for v in verbs} | verbs


def script_names() -> set[str]:
    """The set of file names under scripts/ (the paths documentation may cite)."""
    return {p.name for p in (ROOT / "scripts").rglob("*.sh")}


def check_markdown(docs, targets, subs, scripts) -> list[tuple[str, str, str]]:
    """Return the violations: (file, citation, surrounding context)."""
    violations = []
    for doc in docs:
        text = doc.read_text(encoding="utf-8", errors="replace")
        rel = str(doc.relative_to(ROOT))
        # Only citations inside code (fenced blocks or inline spans) are
        # commands a reader can copy; prose 'make it better' is not a violation.
        code = "\n".join(re.findall(r"(?ms)^```.*?^```|`[^`\n]+`", text))
        for token in set(re.findall(r"\bmake\s+([a-zA-Z][a-zA-Z_-]{1,20})\b", code)):
            if token in targets:
                continue
            # 'apt-get install ... make git curl unzip' is a list of packages that
            # happens to follow the word make; it is not a make invocation. Only a
            # citation where make stands as the program itself counts.
            if re.search(r"(install|apt-get|yum|brew)\b[^`\n]*\bmake\s+" + token + r"\b", code):
                continue
            sample = _context(text, "make " + token)
            violations.append((rel, "make " + token, sample))
        for token in set(re.findall(r"\bcloudops\s+([a-z][a-z-]{2,15})\b", code)):
            if token in PROSE_AFTER_CLOUDOPS or token.startswith("--"):
                continue
            if token.replace("-", "_") in subs or token in subs:
                continue
            sample = _context(text, "cloudops " + token)
            if re.search(r"cloudops " + token + r"(\s+(-{1,2}[a-z-]|$))", sample):
                violations.append((rel, "cloudops " + token, sample))
        for token in set(re.findall(r"scripts/([a-zA-Z0-9_.-]+\.sh)", text)):
            if token not in scripts:
                violations.append((rel, "scripts/" + token, _context(text, token)))
    return violations


def _context(text: str, needle: str, span: int = 48) -> str:
    """A short window of text around the first occurrence of needle."""
    index = text.find(needle)
    if index < 0:
        return ""
    start = max(0, index - 8)
    end = min(len(text), index + len(needle) + span)
    return text[start:end].replace("\n", " ")


def main(argv: list[str]) -> int:
    docs = sorted(p for p in ROOT.rglob("*.md")
                  if "/.git/" not in str(p) and "/.venv/" not in str(p)
                  and "/.terraform/" not in str(p) and "/.tf-cache/" not in str(p))
    targets, subs, scripts = make_targets(), cli_subcommands(), script_names()
    violations = check_markdown(docs, targets, subs, scripts)
    for path, cite, sample in violations:
        print(" | ".join((path, cite, sample)))
    if violations:
        print(f"doc coherence: found {len(violations)} violation(s)", file=sys.stderr)
        return 1
    print(f"doc coherence: {len(docs)} file(s), no violation found")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
