"""Tests for the patch program: baselines, groups, and the compliance queue.

Two properties matter to an operations team and are pinned here: an
unapproved baseline can never load (the registration script would refuse it),
and the queue a scan produces is ordered so that the most dangerous, oldest
non-compliance is patched first.
"""

import json
import sys
import unittest
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from cloudops.patch import compliance_scan, load_baselines

REPO = Path(__file__).resolve().parent.parent
FIXTURES = REPO / "tests" / "fixtures"


class TestBaselines(unittest.TestCase):
    """The shipped baseline file must be loadable and fully approved."""

    def setUp(self):
        self.baselines, self.groups = load_baselines(REPO / "data" / "patch-baselines.json")

    def test_every_baseline_carries_an_approval(self):
        for baseline in self.baselines:
            self.assertTrue(baseline.is_approved(), baseline.name)

    def test_endoflife_class_has_zero_wait(self):
        """The AL2 migrate-only class approves at once: nothing bakes for a dead image."""
        al2 = next(b for b in self.baselines if b.name == "AL2-MIGRATE-ONLY")
        self.assertEqual(al2.rules[0].approve_after_days, 0)
        self.assertEqual(al2.rules[0].classify, "Security-Mandatory")

    def test_rejected_packages_are_documented(self):
        """A held-back package must say so in its name (the review note convention)."""
        for baseline in self.baselines:
            for rule in baseline.rules:
                for pkg in rule.reject_packages:
                    self.assertIn("(", pkg, f"{baseline.name}: {pkg} lacks a reason")

    def test_missing_approval_is_refused(self):
        """A baseline without the board record must raise, not load half-approved."""
        path = FIXTURES / "unapproved-baseline.json"
        document = {
            "baselines": [{"name": "ROGUE", "product_family": "Amazon Linux 2023",
                          "description": "no approval here", "rules": [
                              {"patch_set": "OS", "classify": "Security",
                               "approve_after_days": 0}]}],
            "groups": [],
        }
        path.write_text(json.dumps(document), encoding="utf-8")
        try:
            with self.assertRaises(ValueError) as ctx:
                load_baselines(str(path))
            self.assertIn("ROGUE", str(ctx.exception))
        finally:
            path.unlink(missing_ok=True)


class TestComplianceQueue(unittest.TestCase):
    """The sorted patch queue the windows are scheduled from."""

    def setUp(self):
        with open(FIXTURES / "compliance-reports.json", encoding="utf-8") as handle:
            self.reports = json.load(handle)["reports"]
        self.findings = compliance_scan(self.reports, as_of=date(2026, 9, 12))
        self.by_id = {f.host_id: f for f in self.findings}

    def test_all_reports_are_scanned(self):
        self.assertEqual(len(self.findings), len(self.reports))

    def test_worst_first(self):
        """The critical, oldest non-compliance leads the queue."""
        ranks = [f.risk_rank for f in self.findings]
        self.assertEqual(ranks, sorted(ranks, reverse=True))
        self.assertEqual(self.findings[0].host_id, "i-0a1b2c3d4e5f60718")

    def test_age_is_measured_from_execution(self):
        """The web host missed updates executed on 2026-08-18 are 25 days old."""
        self.assertEqual(self.by_id["i-0a1b2c3d4e5f60718"].oldest_missing_days, 25)
        self.assertEqual(self.by_id["i-0a1b2c3d4e5f60719"].oldest_missing_days, 7)

    def test_compliant_hosts_are_compliant(self):
        self.assertEqual(self.by_id["i-0a1b2c3d4e5f60719"].state, "COMPLIANT")
        self.assertEqual(self.by_id["i-0a1b2c3d4e5f60719"].missing, 0)

    def test_error_state_surfaces(self):
        """An agent that failed to run is an ERROR, not a silent pass."""
        self.assertEqual(self.by_id["i-0d4e5f60718293a4b"].state, "ERROR")


if __name__ == "__main__":
    unittest.main()
