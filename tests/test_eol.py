"""Tests for the version comparison and the status classification of cloudops.eol.

These tests pin the behaviour of the scanner core: the ordering of versions,
the precedence of the lifecycle statuses, and the wording of the reasons the
report prints. The dates are fixed (``as_of``), so the suite passes tomorrow
exactly as it passes today.
"""

import sys
import unittest
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from cloudops.eol import (EolCatalog, EolEntry, EolStatus, SemVer,
                          classify_status, compare_versions)

REPO = Path(__file__).resolve().parent.parent
CATALOG = REPO / "data" / "eol-catalog.json"


class TestVersionComparison(unittest.TestCase):
    """The ordering rules the whole scan depends on."""

    def test_minor_ordering(self):
        """8.0.9 must rank below 8.0.40, and 5.7 below 8.0."""
        self.assertEqual(compare_versions("8.0.9", "8.0.40"), -1)
        self.assertEqual(compare_versions("8.0.40", "8.0.9"), 1)
        self.assertEqual(compare_versions("5.7.44", "8.0.33"), -1)

    def test_equality_and_suffixes(self):
        """Equal versions compare equal; a suffix does not outrank a release."""
        self.assertEqual(compare_versions("7.1.0", "7.1"), 0)
        self.assertEqual(compare_versions("7.1.0-community", "7.1.0"), -1)

    def test_al2_image_naming(self):
        """An AL2 image string ('2.0.20240901') must be parsable and orderable."""
        self.assertEqual(compare_versions("2.0.20240901", "2.0.20250101"), -1)

    def test_garbage_raises(self):
        """An unparsable version must raise, never silently pass."""
        with self.assertRaises(ValueError):
            compare_versions("latest", "1.0")

    def test_semver_duality(self):
        """Two objects that compare equal must expose equal ordering keys."""
        a, b = SemVer("7.1"), SemVer("7.1.0")
        self.assertEqual(a, b)
        self.assertEqual(a.key, b.key)


class TestCatalog(unittest.TestCase):
    """The shipped catalog must load, index, and answer the reference lookups."""

    def setUp(self):
        self.catalog = EolCatalog.load(CATALOG)

    def test_every_entry_carries_a_source(self):
        """Every claim in the catalog must cite its vendor announcement."""
        for entry in self.catalog.all_entries():
            self.assertTrue(entry.source.startswith("https://"),
                            f"{entry.engine} {entry.version_track}: missing source")

    def test_rds_mysql_57_is_past_standard_support(self):
        """MySQL 5.7 passed its end of standard support on 2024-02-29 (AWS docs)."""
        entry = self.catalog.lookup("rds:db", "mysql", "5.7.44")
        self.assertIsNotNone(entry)
        self.assertEqual(entry.standard_support_end, date(2024, 2, 29))
        self.assertEqual(entry.premium_support_end, date(2029, 6, 30))

    def test_al2_track_lookup(self):
        """An AL2 image name resolves to the al2 track, not to the raw major number."""
        entry = self.catalog.lookup("ec2:ami", None,
                                    "amzn-2-amd-64-2.0.20250101")
        self.assertIsNotNone(entry)
        self.assertEqual(entry.version_track, "al2")

    def test_unknown_track_is_reported_not_invented(self):
        """An engine the catalog does not know has no entry (the scanner says so)."""
        self.assertIsNone(self.catalog.lookup("rds:db", "oracle", "19.0"))


class TestStatusClassification(unittest.TestCase):
    """The precedence: advisory, then EOL, then EOS, then approaching, then OK."""

    def setUp(self):
        self.entry_57 = EolEntry(
            engine="mysql", version_track="5.7",
            standard_support_end=date(2024, 2, 29),
            premium_support_end=date(2029, 6, 30),
            latest_available="8.4", action="upgrade by blue/green",
        )
        self.entry_ok = EolEntry(
            engine="postgres", version_track="17",
            standard_support_end=date(2030, 2, 28),
            latest_available="18.1", action="none",
        )
        self.as_of = date(2026, 9, 12)

    def test_past_standard_support_but_in_extended_is_eos(self):
        """A database in the RDS Extended Support window must read EOS."""
        status, reason = classify_status(self.entry_57, "5.7.44", as_of=self.as_of)
        self.assertIs(status, EolStatus.EOS)
        self.assertIn("standard support ended", reason)
        self.assertIn("premium", reason)  # the reason names the extended window

    def test_current_version_is_ok(self):
        """A supported version at the latest release reads OK."""
        status, _reason = classify_status(self.entry_ok, "17.4", as_of=self.as_of)
        self.assertIs(status, EolStatus.OK)

    def test_advisory_beats_everything(self):
        """A security advisory outranks every lifecycle date."""
        entry = EolEntry(engine="redis", version_track="7.1",
                         latest_available="7.1",
                         advisory="CVE-2026-00001 affects 7.1 before 7.1.2")
        status, reason = classify_status(entry, "7.1.0", as_of=self.as_of)
        self.assertIs(status, EolStatus.SEC)
        self.assertIn("CVE", reason)

    def test_past_eol_is_eol(self):
        """Past the hard end-of-life date the status is EOL."""
        entry = EolEntry(engine="eks", version_track="1.29",
                         eol=date(2025, 3, 23), latest_available="1.36",
                         action="upgrade now")
        status, reason = classify_status(entry, "1.29", as_of=self.as_of)
        self.assertIs(status, EolStatus.EOL)
        self.assertIn("end of life", reason)

    def test_approaching_is_earl(self):
        """A boundary within a planning quarter surfaces as EARL, not OK."""
        entry = EolEntry(engine="mysql", version_track="8.0",
                         standard_support_end=date(2026, 11, 30),
                         latest_available="8.4", action="plan the major upgrade")
        status, _reason = classify_status(entry, "8.0.40", as_of=self.as_of)
        self.assertIs(status, EolStatus.EARL)

    def test_unknown_entry_is_ok_with_a_warning_string(self):
        """No catalog entry is never a silent pass: the reason says verify."""
        status, reason = classify_status(None, "9.9", as_of=self.as_of)
        self.assertIs(status, EolStatus.OK)
        self.assertIn("verify", reason.lower())

    def test_as_of_lookforward(self):
        """A future date must see the future state, not the present one."""
        future = date(2027, 8, 1)
        entry = EolEntry(engine="mysql", version_track="8.0",
                         standard_support_end=date(2026, 7, 31),
                         premium_support_end=date(2029, 7, 31),
                         latest_available="8.4", action="upgrade")
        status, _reason = classify_status(entry, "8.0.40", as_of=future)
        self.assertIs(status, EolStatus.EOS)


if __name__ == "__main__":
    unittest.main()
