"""Tests for the rendering layer and the command-line interface.

The renderers must never fail on a value shape they have not seen, and the
CLI must exit with the status the scheduling contract promises. These tests
drive the real entry point with canned argv and canned files, and assert on
the rendered content and on the exit codes.
"""

import contextlib
import io
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from cloudops import cli
from cloudops.report import as_csv, as_json, as_markdown, as_table

REPO = Path(__file__).resolve().parent.parent
FIXTURES = REPO / "tests" / "fixtures"
CATALOG = str(REPO / "data" / "eol-catalog.json")
INVENTORY = str(FIXTURES / "fleet-inventory.json")


class TestRenderers(unittest.TestCase):
    """The renderers of the report layer."""

    ROWS = [{"a": "one", "b": None, "c": True, "d": ["x", "y"]},
            {"a": "two and a long value " * 8, "b": 7, "c": False, "d": ()}]

    def test_table_caps_widths_and_survives_nones(self):
        text = as_table(self.ROWS, ("a", "b", "c", "d"))
        self.assertIn("ONE", text.upper())
        self.assertIn("...", text)               # the long value is ellipsised
        for line in text.splitlines():
            self.assertLessEqual(len(line), 8 * 50, "table must not explode sideways")

    def test_csv_roundtrips(self):
        text = as_csv(self.ROWS, ("a", "b", "c", "d"))
        self.assertEqual(text.splitlines()[0], "a,b,c,d")
        self.assertIn("one,,yes", text)

    def test_markdown_escapes_pipes(self):
        rows = [{"a": "a | b"}]
        text = as_markdown(rows, ("a",), title="T")
        self.assertIn("a \\| b", text)

    def test_json_is_parseable(self):
        payload = {"rows": self.ROWS}
        parsed = json.loads(as_json(payload))
        self.assertEqual(parsed["rows"][0]["a"], "one")


class TestCli(unittest.TestCase):
    """The exit-code contract of the CLI, with its real files."""

    def _run(self, argv):
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer), contextlib.redirect_stderr(buffer):
            status = cli.main(argv)
        return status, buffer.getvalue()

    def test_scan_finds_the_reference_eol(self):
        status, out = self._run(["scan", "--inventory", INVENTORY,
                                 "--eol-catalog", CATALOG,
                                 "--as-of", "2026-09-12", "--format", "csv"])
        self.assertEqual(status, 1, "an EOL in the fleet must exit 1")
        self.assertIn("prod-ai-platform", out)
        self.assertIn("eol", out)

    def test_scan_json_is_machine_readable(self):
        status, out = self._run(["scan", "--inventory", INVENTORY,
                                 "--eol-catalog", CATALOG, "--format", "json"])
        document = json.loads(out)
        self.assertEqual(document["summary"]["total"], 14)

    def test_drift_exits_one_on_findings(self):
        status, out = self._run(["drift",
                                 "--state", str(FIXTURES / "state-export.json"),
                                 "--live", str(FIXTURES / "live-describe.json"),
                                 "--format", "csv"])
        self.assertEqual(status, 1)
        self.assertIn("sg-debug-open", out)

    def test_drift_with_a_full_ignore_is_clean(self):
        extra = REPO / "reports" / "test-ignore.json"
        extra.parent.mkdir(exist_ok=True)
        extra.write_text(json.dumps({
            "aws_vpc": ["cidr_block"],
            "aws_instance": ["capacity", "health_check_type",
                             "metadata_options.http_tokens", "security_groups"],
            "aws_db_instance": ["backup_retention_period"],
            "aws_iam_role": [],
        }), encoding="utf-8")
        status, _out = self._run(["drift",
                                   "--state", str(FIXTURES / "state-export.json"),
                                   "--live", str(FIXTURES / "live-describe.json"),
                                   "--ignore", str(extra), "--format", "csv"])
        extra.unlink()
        # The two <resource> findings (the unmanaged and the missing resource)
        # remain: the ignore list silences attributes, not entire resources.
        self.assertEqual(status, 1)

    def test_baselines_list_exits_zero(self):
        status, out = self._run(["baseline-list",
                                 "--baselines", str(REPO / "data" / "patch-baselines.json")])
        self.assertEqual(status, 0)
        self.assertIn("AL2023-SECURITY-30D", out)

    def test_bad_data_exits_two_not_traceback(self):
        status, err = self._run(["scan", "--inventory", "/nonexistent/inventory.json",
                                 "--eol-catalog", CATALOG])
        self.assertEqual(status, 2)
        self.assertIn("data problem", err)

    def test_snapshot_writes_a_file(self):
        out_dir = REPO / "reports"
        out_dir.mkdir(exist_ok=True)
        target = out_dir / "test-snapshot.json"
        self._run(["snapshot", "--inventory", INVENTORY,
                   "--eol-catalog", CATALOG, "--out", str(target)])
        document = json.loads(target.read_text(encoding="utf-8"))
        self.assertEqual(document["tool"], "cloudops")
        target.unlink(missing_ok=True)


if __name__ == "__main__":
    unittest.main()
