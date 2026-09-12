"""The scanner: from the fleet inventory to the patch queue, in one pass.

This file is the spine of the toolkit. It reads the inventory of the fleet,
asks the catalog of end-of-life dates for a verdict on every installed version,
attaches the compliance findings, and prints the result as a table, as CSV, as
JSON, or as a markdown report. The exit code is part of the interface: 0 when
the fleet is supported, 1 when something is past its end-of-life date, and 2 on
a data problem. This makes the scanner usable as a scheduled gate (a GitHub
action, an EventBridge rule, a nightly cron) without any wrapper logic.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date
from typing import Sequence

from cloudops.eol import EolStatus, classify_status, EolCatalog
from cloudops.inventory import Host, Inventory
from cloudops.patch import ComplianceFinding, compliance_scan


@dataclass(frozen=True)
class ScanRow:
    """The verdict for one host, as one row of the report.

    Attributes:
        host:             the subject of the verdict.
        status:           the EolStatus of its installed version.
        reason:           the sentence the report prints verbatim.
        available:        the latest version the catalog knows about, if any.
        action:           the recommended action, from the catalog entry.
        source:           the URL of the vendor announcement behind the verdict.
    """

    host: Host
    status: EolStatus
    reason: str
    available: str | None
    action: str
    source: str

    @property
    def severity(self) -> int:
        """Returns: the sorting rank, so the worst rows come first."""
        return self.status.severity


def scan_fleet(inventory: Inventory, catalog: EolCatalog, *,
               as_of: date | None = None,
               severity_floor: EolStatus | None = None) -> list[ScanRow]:
    """Purpose: produce the verdict of every host in the inventory.

    ``as_of`` exists for the tests and for a look-forward report ('what will be
    past its end-of-life date on the 1st of December'). ``severity_floor``
    discards the rows below the given status (use it to print only the problems
    that need attention). The rows are sorted worst first, and, within one
    severity, by the host id, so the output is reproducible byte for byte.

    Returns: the list of ScanRow. Side effects: none.
    """
    rows = []
    for host in inventory:
        entry = catalog.lookup(host.service, host.engine, host.version)
        status, reason = classify_status(entry, host.version, as_of=as_of)
        if severity_floor is not None and status.severity < severity_floor.severity:
            continue
        rows.append(ScanRow(
            host=host, status=status, reason=reason,
            available=entry.latest_available if entry else None,
            action=entry.action if entry else "verify against the vendor announcement",
            source=entry.source if entry else "",
        ))
    rows.sort(key=lambda r: (-r.severity, r.host.host_id))
    return rows


def summary(rows: Sequence[ScanRow]) -> dict[str, int]:
    """Purpose: count the rows by status, for the header of the report.

    Returns: a mapping of status name to count, including the zero buckets, so
    that a reader can see that a status is empty rather than absent.
    """
    counts = {member.value: 0 for member in EolStatus}
    for row in rows:
        counts[row.status.value] += 1
    counts["total"] = len(rows)
    return counts


def worst(rows: Sequence[ScanRow]) -> EolStatus | None:
    """Purpose: report the worst status present in the scan result.

    Returns: the status, or None when the result is empty. This drives the
    exit code of the scanner.
    """
    if not rows:
        return None
    return max((row.status for row in rows), key=lambda s: s.severity)


def patch_queue(rows: Sequence[ScanRow], findings: Sequence[ComplianceFinding]
                | None = None) -> list[dict]:
    """Purpose: build the work queue that the operator schedules the window with.

    A queue item is one line of work: the host, its verdict, the target
    version, the role (canary, standard, critical) and the compliance age from
    ``findings`` when it is available. Items are ordered so that the canary
    ring is listed first for each service (the canary is patched before the
    fleet — see OPERATIONS.md), and the critical ring is listed last.

    Returns: a list of plain dictionaries, ready to be written as CSV or JSON.
    Side effects: none.
    """
    compliance_by_id = {f.host_id: f for f in (findings or ())}
    ring_order = {"canary": 0, "standard": 1, "critical": 2}
    items = []
    for row in rows:
        if row.status is EolStatus.OK:
            continue
        finding = compliance_by_id.get(row.host.host_id)
        items.append({
            "host_id": row.host.host_id,
            "service": row.host.service,
            "engine": row.host.engine or "",
            "installed": row.host.version,
            "target": row.available or "",
            "status": row.status.value,
            "role": row.host.role,
            "environment": row.host.tags.get("Environment", ""),
            "compliance_age_days": finding.oldest_missing_days if finding else "",
            "action": row.action,
            "source": row.source,
        })
    items.sort(key=lambda item: (
        -{"security-advisory": 4, "eol": 3, "eos": 2, "eol-approaching": 1}[item["status"]],
        ring_order.get(item["role"], 1),
        item["host_id"],
    ))
    return items
