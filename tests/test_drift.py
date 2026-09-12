"""Tests for drift detection: the state file of the estate against the live describe.

The two fixtures (tests/fixtures/state-export.json and
tests/fixtures/live-describe.json) carry deliberate differences; this suite
pins which of them the detector must report, at which severity, and confirms
that the ignore list silences exactly what it names and nothing else.
"""

import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from cloudops.drift import detect_drift

REPO = Path(__file__).resolve().parent.parent
FIXTURES = REPO / "tests" / "fixtures"


def load(name):
    with open(FIXTURES / name, encoding="utf-8") as handle:
        return json.load(handle)["resources"]


class TestDriftDetection(unittest.TestCase):
    """The drift findings the reference pair of fixtures must produce."""

    def setUp(self):
        self.state = load("state-export.json")
        self.live = load("live-describe.json")
        self.findings = detect_drift(self.state, self.live)
        self.keys = {(f.address, f.attribute) for f in self.findings}

    def test_security_group_change_is_critical(self):
        """An added security group in the live estate is the worst class of finding."""
        finding = next(f for f in self.findings
                       if f.address.endswith(".web") and f.attribute == "security_groups")
        self.assertEqual(finding.severity, "CRITICAL")
        self.assertIn("sg-debug-open", str(finding.observed))

    def test_imds_downgrade_is_critical(self):
        """metadata_options.http_tokens relaxed from required is a security regression."""
        finding = next(f for f in self.findings
                       if f.attribute == "metadata_options.http_tokens")
        self.assertEqual(finding.severity, "CRITICAL")
        self.assertEqual(finding.observed, "optional")

    def test_capacity_change_is_a_warning(self):
        finding = next(f for f in self.findings if f.attribute == "capacity")
        self.assertEqual(finding.severity, "WARNING")

    def test_missing_and_unmanaged_resources_are_critical(self):
        addresses = {f.address for f in self.findings if f.attribute == "<resource>"}
        self.assertIn("module.iam.aws_iam_role.lambda_exec", addresses)   # gone from live
        self.assertIn("aws_instance.console_created_debug", addresses)   # not in state

    def test_ignore_list_silences_ignored_attributes(self):
        """A public_ip difference is ignorable for EC2: the default table says so."""
        self.assertNotIn(("module.ec2.aws_autoscaling_group.web", "public_ip"),
                         self.keys)

    def test_extra_ignore_merges(self):
        """A caller-supplied ignore entry removes exactly its attribute."""
        findings = detect_drift(self.state, self.live,
                                 extra_ignore={"aws_db_instance": ["backup_retention_period"]})
        self.assertNotIn(("module.rds.aws_db_instance.prod_mysql",
                          "backup_retention_period"),
                         {(f.address, f.attribute) for f in findings})
        # The rds instance carried only that one difference: ignoring it
        # silences the whole resource, while the EC2 findings survive.
        self.assertNotIn("module.rds.aws_db_instance.prod_mysql",
                         {f.address for f in findings})
        self.assertIn(("module.ec2.aws_autoscaling_group.web", "capacity"),
                      {(f.address, f.attribute) for f in findings})

    def test_ordering_puts_critical_first(self):
        severities = [f.severity for f in self.findings]
        order = {"CRITICAL": 0, "WARNING": 1, "INFORMATIONAL": 2}
        mapped = [order[s] for s in severities]
        self.assertEqual(mapped, sorted(mapped))

    def test_clean_pair_produces_nothing(self):
        """The same file compared with itself must be silent (no false positives)."""
        findings = detect_drift(self.state, json.loads(json.dumps(self.state)))
        self.assertEqual(findings, [])

    def test_string_one_equals_int_one(self):
        """A numeric representation difference is not drift (the _normalise rule)."""
        state = [{"address": "a", "type": "t", "attributes": {"port": 5432}}]
        live = [{"address": "a", "type": "t", "attributes": {"port": "5432"}}]
        self.assertEqual(detect_drift(state, live), [])


if __name__ == "__main__":
    unittest.main()
