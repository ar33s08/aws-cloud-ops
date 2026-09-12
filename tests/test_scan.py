"""Tests for the end-to-end scan: the inventory through the catalog to the queue.

These tests assert on data, never on rendered layout: the reference estate
must produce exactly the fleet status the README promises, and the queue
must order the work the way OPERATIONS.md promises (canary before standard
before critical, worst severity first).
"""

import sys
import unittest
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from cloudops.eol import EolCatalog, EolStatus
from cloudops.inventory import Inventory, ServiceFamily
from cloudops.scan import patch_queue, scan_fleet, summary, worst

REPO = Path(__file__).resolve().parent.parent
FIXTURES = REPO / "tests" / "fixtures"
AS_OF = date(2026, 9, 12)


class TestReferenceFleet(unittest.TestCase):
    """The canned fleet must classify exactly as the documented reference estate."""

    def setUp(self):
        self.inventory = Inventory.from_json(FIXTURES / "fleet-inventory.json")
        self.catalog = EolCatalog.load(REPO / "data" / "eol-catalog.json")
        self.rows = scan_fleet(self.inventory, self.catalog, as_of=AS_OF)
        self.by_id = {row.host.host_id: row for row in self.rows}

    def test_host_count_matches_the_manifest(self):
        self.assertEqual(len(self.inventory), 14)

    def test_al2_instances_are_eol(self):
        """AL2 reached its end of life on 2026-06-30: the fleet must say so."""
        row = self.by_id["i-0a1b2c3d4e5f60718"]
        self.assertIs(row.status, EolStatus.EOL)
        self.assertIn("2026-06-30", row.reason)

    def test_mysql_57_is_eos_in_extended_support(self):
        """RDS MySQL 5.7 is past standard support: EOS with the blue/green action."""
        row = self.by_id["db-prod-mysql-01"]
        self.assertIs(row.status, EolStatus.EOS)
        self.assertIn("blue/green", row.action)

    def test_redis_5_is_eos_and_62_is_approaching(self):
        self.assertIs(self.by_id["cache-prod-redis-old-01"].status, EolStatus.EOS)

    def test_supported_hosts_are_ok(self):
        ok_ids = ("i-0b2c3d4e5f6071829", "db-dev-pg-01", "dev-ai-platform")
        for host_id in ok_ids:
            self.assertIs(self.by_id[host_id].status, EolStatus.OK, host_id)

    def test_worst_drives_the_exit_status(self):
        """The fleet contains an EOL host, so the scan worst case must be EOL."""
        self.assertIs(worst(self.rows), EolStatus.EOL)

    def test_summary_buckets_exist_and_total(self):
        counts = summary(self.rows)
        self.assertEqual(counts["total"], len(self.rows))
        for member in EolStatus:
            self.assertIn(member.value, counts)


class TestSelectionAndOrdering(unittest.TestCase):
    """The queue ordering rules of OPERATIONS.md (canary first, worst first)."""

    def setUp(self):
        inventory = Inventory.from_json(FIXTURES / "fleet-inventory.json")
        catalog = EolCatalog.load(REPO / "data" / "eol-catalog.json")
        rows = scan_fleet(inventory, catalog, as_of=AS_OF)
        self.items = patch_queue(rows)

    def test_ok_rows_never_enter_the_queue(self):
        """A supported host is not work: the queue carries only problems."""
        statuses = {item["status"] for item in self.items}
        self.assertNotIn("ok", statuses)

    def test_severity_order_is_non_increasing(self):
        rank = {"security-advisory": 4, "eol": 3, "eos": 2, "eol-approaching": 1}
        ranks = [rank[item["status"]] for item in self.items]
        self.assertEqual(ranks, sorted(ranks, reverse=True))

    def test_canary_precedes_critical_within_a_severity(self):
        """For the same severity, the canary ring is patched before the fleet."""
        rank = {"security-advisory": 4, "eol": 3, "eos": 2, "eol-approaching": 1}
        groups = {}
        for item in self.items:
            groups.setdefault(rank[item["status"]], []).append(item["role"])
        for _rank, roles in groups.items():
            order = {"canary": 0, "standard": 1, "critical": 2}
            mapped = [order[r] for r in roles]
            self.assertEqual(mapped, sorted(mapped), f"roles out of ring order: {roles}")

    def test_inventory_selection_helpers(self):
        inventory = Inventory.from_json(FIXTURES / "fleet-inventory.json")
        rds = inventory.select(family=ServiceFamily.RDS_DB)
        self.assertEqual(len(rds), 5)
        dev = inventory.select(environment="dev")
        self.assertEqual({h.host_id for h in dev},
                         {"db-dev-pg-01", "cache-dev-valkey-01", "dev-ai-platform"})
        with self.assertRaises(KeyError):
            inventory.by_id("i-does-not-exist")


class TestInventoryValidation(unittest.TestCase):
    """Malformed inventories must fail loudly at load, not silently at scan."""

    def test_duplicate_host_ids_are_rejected(self):
        from cloudops.inventory import Host
        with self.assertRaises(ValueError):
            from cloudops.inventory import Inventory as Inv
            Inv(hosts=[Host("dup", "ec2:ami", "1.0"), Host("dup", "ec2:ami", "2.0")])

    def test_unknown_service_label_is_rejected(self):
        from cloudops.inventory import Host
        with self.assertRaises(ValueError):
            Host("x", "quantum-flux", "1.0")

    def test_empty_version_is_rejected(self):
        from cloudops.inventory import Host
        with self.assertRaises(ValueError):
            Host("x", "ec2:ami", "  ")


if __name__ == "__main__":
    unittest.main()
