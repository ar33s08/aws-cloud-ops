"""Patch baselines, patch groups, and the compliance queue.

This file implements the patching program of the toolkit. A *patch baseline*
is the approved set of updates for one class of operating system (an Amazon
Linux 2 baseline, an Amazon Linux 2023 baseline, a database host baseline),
together with its approval rules: how long an update waits before it becomes
installable (the approval wait period), whether security classifications are
included (they are), and which packages are explicitly excluded (an exclusion
list exists for every pinned component, and each exclusion carries a reason
and a review date). A *patch group* is the label that ties an instance to one
or more baselines; the SSM agent on the instance reports its compliance against
the group it was launched with.

The compliance scan consumes the *reported compliance* of the fleet (canned
under ``tests/fixtures/``; taken from the Get-Patch-Compliance-Operations
results in live mode — see ``cloudops.aws_live``) and produces the patch
queue: the hosts that are not compliant, sorted by the age of their
non-compliance, with the severity of the worst missing update attached.

Nothing in this module executes a patch: patching is *applied* by
``scripts/patch-schedule.sh`` and AWS Systems Manager, which is idempotent and
re-runnable. This module decides *what* and *when*, never *hows* the reboot.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from datetime import date, timedelta
from typing import Sequence


@dataclass(frozen=True)
class PatchRule:
    """One approval rule of a baseline.

    Attributes:
        patch_set:   the set the rule applies to ('OS', 'AGENT', 'AMAZON_LINUX').
        classify:    the comma-separated classifications approved ('Security',
                     'Bugfix', ...); security-only baselines approve
                     'Security,Security-Mandatory,Recommendation'.
        approve_after_days: the approval wait period; zero means the update is
                     approved at once (used by the canary ring, see OPERATIONS.md).
        reject_packages: packages held back, each with a reason; a held-back
                     package must have a review date in the future.
    """

    patch_set: str
    classify: str
    approve_after_days: int
    reject_packages: tuple[str, ...] = ()


@dataclass(frozen=True)
class PatchBaseline:
    """An approved baseline: one operating system class, its rules, its schedule.

    ``approved`` records the approval of the change advisory board (who, when);
    a baseline without an approval is refused by the registration script, so a
    hand-edited file cannot silently reach the fleet.
    """

    name: str
    product_family: str
    description: str
    rules: tuple[PatchRule, ...]
    compliance_severity: str = "MEDIUM"
    approved_by: str | None = None
    approved_on: date | None = None

    def is_approved(self) -> bool:
        """Returns: True when the change advisory board approved this baseline."""
        return self.approved_by is not None and self.approved_on is not None


@dataclass(frozen=True)
class PatchGroup:
    """The pairing of baselines with a schedule, per role (patch ring)."""

    name: str
    baseline_names: tuple[str, ...]
    schedule: str                      # cron style: 'cron(0 9 ? * WED:2)' for the 2nd Wed
    cutoff_hours: int
    overlap_duration_hours: int


@dataclass
class ComplianceFinding:
    """The compliance state of one host, as reported by the scan.

    Fields:
        host_id, patch_group: the subject of the finding.
        state:         one of COMPLIANT, NOT_COMPLIANT, ERROR, MISMATCHED.
        missing:       count of missing updates (the age is kept separately:
                       a missing update that is 30 days old is worse than a new one).
        oldest_missing_days: how long the oldest missing update has waited.
        worst_severity:CIDENTICAL, CRITICAL, HIGH, MEDIUM, INFORMATIONAL.
    """

    host_id: str
    patch_group: str
    state: str
    missing: int
    oldest_missing_days: int
    worst_severity: str

    @property
    def risk_rank(self) -> int:
        """Returns: the sorting rank — severity first, age of the queue second."""
        sev = {"CRITICAL": 4, "HIGH": 3, "MEDIUM": 2, "LOW": 1, "INFORMATIONAL": 0}
        return sev.get(self.worst_severity, 0) * 1000 + min(self.oldest_missing_days, 999)


def compliance_scan(reported: Sequence[dict], *,
                    as_of: date | None = None) -> list[ComplianceFinding]:
    """Purpose: turn the raw compliance reports into the sorted patch queue.

    ``reported`` is the list of report records (the same shape as the canned
    fixture and as the SSM API response). The age of each finding is measured
    against ``as_of`` so that the tests and the 'next window' report can share
    this function. Returns: the findings sorted worst first — the queue the
    operator feeds to ``scripts/patch-schedule.sh``. Side effects: none.
    """
    today = as_of or date.today()
    findings: list[ComplianceFinding] = []
    for record in reported:
        inst = record.get("instance_information", {})
        state = (inst.get("compliance", inst.get("compliance_type", "UNKNOWN"))
                 or "UNKNOWN").upper()
        executed = inst.get("executed_at")
        age = 0
        if executed:
            year, month, day = (int(part) for part in executed[:10].split("-"))
            executed_on = date(year, month, day)
            age = max((today - executed_on).days, 0)
        findings.append(ComplianceFinding(
            host_id=record["host_id"],
            patch_group=record.get("operation", {}).get("patch_group", ""),
            state=state,
            missing=int(inst.get("installed_count", {}).get("missing", 0) or 0),
            oldest_missing_days=age,
            worst_severity=(inst.get("severity") or "INFORMATIONAL").upper(),
        ))
    findings.sort(key=lambda f: f.risk_rank, reverse=True)
    return findings


def load_baselines(path: str) -> tuple[list[PatchBaseline], list[PatchGroup]]:
    """Purpose: load the baseline and the patch group definitions from JSON.

    Returns: (baselines, groups). Raises ValueError when a baseline lacks the
    approval of the change advisory board or when a held-back package has no
    review date — a baseline that cannot be audited is refused, not tolerated.
    Side effects: reads one file.
    """
    with open(path, encoding="utf-8") as handle:
        document = json.load(handle)
    baselines = []
    for record in document["baselines"]:
        rules = tuple(
            PatchRule(patch_set=r["patch_set"], classify=r["classify"],
                      approve_after_days=int(r["approve_after_days"]),
                      reject_packages=tuple(r.get("reject_packages", ())))
            for r in record["rules"]
        )
        approved_on = record.get("approved_on")
        if approved_on:
            year, month, day = (int(part) for part in approved_on[:10].split("-"))
            approved_on = date(year, month, day)
        baseline = PatchBaseline(
            name=record["name"], product_family=record["product_family"],
            description=record["description"], rules=rules,
            compliance_severity=record.get("compliance_severity", "MEDIUM"),
            approved_by=record.get("approved_by"),
            approved_on=approved_on,
        )
        if not baseline.is_approved():
            raise ValueError(f"baseline {baseline.name}: no change advisory board approval")
        baselines.append(baseline)
    groups = [
        PatchGroup(name=g["name"], baseline_names=tuple(g["baseline_names"]),
                   schedule=g["schedule"], cutoff_hours=int(g["cutoff_hours"]),
                   overlap_duration_hours=int(g["overlap_duration_hours"]))
        for g in document["groups"]
    ]
    return baselines, groups
