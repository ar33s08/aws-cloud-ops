"""End-of-life and end-of-support comparison logic.

This file answers the one question an operations engineer must answer every
month, for every installed version of the fleet: what is installed, what is
the latest supported version, and what must happen before which date. It
carries no AWS dependency of its own: it reads a catalog of end-of-life dates
(the file ``data/eol-catalog.json``, sourced from the public vendor
announcements of Amazon, Oracle, Redis, and the Kubernetes project — the file
names the exact sources and their fetch dates), and compares installed
versions against it.

The vocabulary follows the AWS conventions: a database engine version is
*standard supported* until its standard support end date, then *premium
supported* until its premium support end date, and after that it has reached
end of life. A cache engine reaches *end of support* when the vendor no longer
ships security fixes for it.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from datetime import date, datetime
from enum import Enum
from functools import total_ordering
from pathlib import Path
from typing import Sequence


@total_ordering
class SemVer:
    """A comparable version: major.minor.patch with optional suffixes.

    Purpose: parse a version string ('8.0.35', '2.0.20240901', '7.1.0',
    '6.2.7-community') and order it correctly for comparison.
    Returns: an ordering-enabled version object.
    """

    pattern = re.compile(
        r"^(?P<major>\d+)(?:\.(?P<minor>\d+))?(?:\.(?P<patch>\d+))?"
        r"(?:[-.+](?P<suffix>.*))?$"
    )

    def __init__(self, text: str) -> None:
        match = self.pattern.match(text.strip())
        if not match:
            raise ValueError(f"unparsable version: {text!r}")
        self.raw = text.strip()
        self.major = int(match["major"])
        self.minor = int(match["minor"] or 0)
        self.patch = int(match["patch"] or 0)
        self.suffix = match["suffix"] or ""

    @property
    def key(self) -> tuple:
        """Returns: the ordering key; release ordering beats a pre-release suffix."""
        return (self.major, self.minor, self.patch, self.suffix == "")

    def __lt__(self, other: object) -> bool:
        if not isinstance(other, SemVer):
            return NotImplemented
        return self.key < other.key

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, SemVer):
            return NotImplemented
        return self.key == other.key

    def __repr__(self) -> str:
        return f"SemVer({self.raw!r})"


class EolStatus(Enum):
    """The lifecycle status of one installed version, worst wins."""

    OK = "ok"                  # supported and current or nearly current
    EARL = "eol-approaching"     # supported, but a planned upgrade is due
    EOL = "eol"                 # past the end-of-life date: upgrade now
    EOS = "eos"                 # past the end-of-support date (vendor/managed)
    SEC = "security-advisory"   # a security advisory affects this version

    @property
    def severity(self) -> int:
        """Returns: the rank used for sorting, so that the worst comes first."""
        return {
            EolStatus.SEC: 4, EolStatus.EOL: 3,
            EolStatus.EOS: 2, EolStatus.EARL: 1, EolStatus.OK: 0,
        }[self]


@dataclass(frozen=True)
class EolEntry:
    """One catalog entry: the lifecycle dates of one engine track.

    Fields mirror a vendor announcement: standard_support_end and
    premium_support_end (for an RDS engine) or vendor_support_end (for a cache
    engine), an eol date, an advisory string, and the latest available
    version. ``action`` states the recommended action in one sentence; the
    reference to the source URL is kept in ``source`` so that every claim can
    be verified independently.
    """

    engine: str
    version_track: str                # e.g. '5.7', '8.0', 'al2', '1.29'
    eol: date | None = None
    standard_support_end: date | None = None
    premium_support_end: date | None = None
    latest_available: str | None = None
    advisory: str | None = None
    action: str = "no action required"
    source: str = ""

    @classmethod
    def from_json(cls, record: dict) -> "EolEntry":
        """Purpose: build one entry from one JSON record of the catalog.

        Returns: the entry; date strings are parsed as iso-8601.
        """
        def _as_date(value: str | None) -> date | None:
            if not value:
                return None
            # Split by hand rather than by a format directive: an iso-8601 date
            # has one shape, and a hand parse cannot go stale on a locale.
            year, month, day = (int(part) for part in value[:10].split("-"))
            return date(year, month, day)

        return cls(
            engine=record["engine"],
            version_track=record["version_track"],
            eol=_as_date(record.get("eol")),
            standard_support_end=_as_date(record.get("standard_support_end")),
            premium_support_end=_as_date(record.get("premium_support_end")),
            latest_available=record.get("latest_available"),
            advisory=record.get("advisory"),
            action=record.get("action", "no action required"),
            source=record.get("source", ""),
        )


class EolCatalog:
    """The catalog of lifecycle dates, indexed by (service, engine, track).

    Purpose: answer the two questions of the scanner, 'is this version
    supported?' and 'what is the target version?'. Loading is strict: a
    malformed catalog raises at once.
    Side effects: ``load`` reads one file.
    """

    def __init__(self, entries: Sequence[EolEntry]) -> None:
        self._index: dict[tuple[str, str], EolEntry] = {}
        for entry in entries:
            self._index[(entry.engine, entry.version_track)] = entry

    @classmethod
    def load(cls, path: str | Path) -> "EolCatalog":
        with open(path, encoding="utf-8") as handle:
            document = json.load(handle)
        return cls([EolEntry.from_json(record) for record in document["entries"]])

    def lookup(self, service: str, engine: str | None, version: str) -> EolEntry | None:
        """Purpose: find the catalog entry of one installed version.

        The track is the leading numeric component of the version (for an Al2
        image the track is 'al2', for an EKS platform version it is the
        '1.xx' series). Returns: the entry, or None when the catalog has no
        statement about the track (which the scanner reports as unknown, and
        never as OK).
        """
        family = service.split(":", 1)[0]
        track = _track_for(family, engine, version)
        key_engine = (engine or family).lower()
        # Three index shapes occur in a shipped catalog: the engine names the
        # engines go by (mysql, redis), the image class for a plain EC2 image
        # (the track IS the engine name there, al2/al2023), and the service
        # family for a platform (eks). Try them in that order; an unknown
        # track still returns None, which the scanner reports as unknown.
        return (self._index.get((key_engine, track))
                or self._index.get((track, track))
                or self._index.get((family, track)))

    def all_entries(self) -> tuple[EolEntry, ...]:
        """Returns: all entries, for reporting and for the tests."""
        return tuple(self._index.values())


def _track_for(family: str, engine: str | None, version: str) -> str:
    """Purpose: derive the catalog track of one installed version.

    Returns: the track string ('8.0', '5.7', 'al2', '1.29', 'al2023', '7.1').
    """
    lowered = version.lower()
    if family == "ec2":
        # Amazon images arrive with the names the registries publish:
        # 'amzn-2-amd-64-2.0....' for AL2 and any string carrying '2023'
        # for AL2023. Match on those, and on the short 'al2' spelling the
        # catalog itself uses.
        if "2023" in lowered:
            return "al2023"
        if "al2" in lowered or "amzn2" in lowered or "amzn-2" in lowered:
            return "al2"
    if engine and engine.lower() == "postgres":
        # The PostgreSQL convention: a major version is one number (13), the
        # community minor is the second (13.13). The catalog tracks majors.
        match = re.match(r"^(\d+)", lowered)
        if match:
            return match[1]
    if family == "eks":
        match = re.match(r"^(\d+\.\d+)", lowered)
        if match:
            return match[1]
    match = re.match(r"^(\d+\.\d+)", lowered)
    if match:
        return match[1]
    match = re.match(r"^(\d+)", lowered)
    return match[1] if match else lowered


def compare_versions(installed: str, target: str) -> int:
    """Purpose: compare two version strings (the comparison function of the package).

    Returns: -1, 0, or 1 as the installed version is below, equal to, or above
    the target. Raises ValueError on an unparsable version — never guess.
    """
    a, b = SemVer(installed), SemVer(target)
    return (a > b) - (a < b)


def _parses(text: str) -> bool:
    """Purpose: say whether a version string is parsable, without raising.

    Returns: True when SemVer can parse the text, False otherwise. Used only
    where a non-version string (an image name) is legitimate input.
    """
    try:
        SemVer(text)
    except ValueError:
        return False
    return True


def classify_status(entry: EolEntry | None, installed: str,
                    as_of: date | None = None) -> tuple[EolStatus, str]:
    """Purpose: classify one installed version against its catalog entry.

    The precedence runs security advisory, then end of life, then end of
    support, then approaching-end dates, then currency. An unknown track is
    reported as SEC? no — as OK with the note 'unknown track', never as a pass:
    see the returned reason string, which the report prints verbatim.

    Returns: (status, reason). ``as_of`` exists for the tests and for a
    look-forward report ('what will be EOL on 1 December').
    """
    if entry is None:
        return EolStatus.OK, "no catalog entry: verify manually against the vendor announcement"
    today = as_of or date.today()
    if entry.advisory:
        return EolStatus.SEC, f"security advisory: {entry.advisory}"
    if entry.eol and today >= entry.eol:
        return EolStatus.EOL, f"end of life on {entry.eol}: {entry.action}"
    if entry.premium_support_end and today >= entry.premium_support_end:
        return EolStatus.EOS, f"premium support ended {entry.premium_support_end}: {entry.action}"
    if entry.standard_support_end and today >= entry.standard_support_end:
        if entry.premium_support_end:
            return (EolStatus.EOS,
                    f"standard support ended {entry.standard_support_end} (premium to "
                    f"{entry.premium_support_end}): {entry.action}")
        return EolStatus.EOS, f"end of support {entry.standard_support_end}: {entry.action}"
    if entry.latest_available:
        if not _parses(installed):
            # An image name ('amzn-2-amd-64-2.0....') is not a version string:
            # the currency comparison is meaningless here. The lifecycle dates
            # above already decided the status; the remedy for an image is the
            # rebuilt AMI, not a version bump.
            return EolStatus.OK, "supported image; the fleet tracks the catalog"
        if compare_versions(installed, entry.latest_available) < 0:
            # A minor behind is fine; nine months out, plan the upgrade.
            if _approaching(entry, today):
                return (EolStatus.EARL,
                        f"planned upgrade due to {entry.latest_available}: {entry.action}")
            return EolStatus.OK, f"supported; {entry.latest_available} available"
    return EolStatus.OK, "current"


def _approaching(entry: EolEntry, today: date) -> bool:
    """Purpose: say whether any support boundary is within a planning quarter.

    Returns: True when a support boundary falls within 90 days of 'today'.
    """
    horizons = [d for d in (entry.eol, entry.standard_support_end,
                            entry.premium_support_end) if d is not None]
    return any((d - today).days <= 90 for d in horizons)
