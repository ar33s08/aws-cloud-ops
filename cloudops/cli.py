"""The command-line interface of the toolkit (the entry point 'cloudops').

This file wires the library modules into one program with subcommands, the
way the AWS CLI itself is organised: a verb first ('scan', 'drift',
'patch-queue'), then the flags. Every subcommand supports ``--format``
(table, csv, json, md) and exits with a status that a scheduler can branch on:

    0   everything is supported (or the requested comparison found no drift)
    1   at least one finding at or above the severity floor
    2   a data problem (a malformed inventory, an unknown catalog entry)

The program never calls the AWS APIs unless ``--live`` is given and the
optional boto3 extra is installed (see ``cloudops.aws_live``); the default
mode is read-only against the files named by the flags, which is what makes
it safe to run from a cron job or a CI step with no credentials configured.
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import date, datetime
from pathlib import Path

from cloudops import __version__
from cloudops.drift import detect_drift
from cloudops.eol import EolCatalog, EolStatus
from cloudops.inventory import Inventory
from cloudops.patch import compliance_scan, load_baselines
from cloudops.report import as_csv, as_json, as_markdown, as_table
from cloudops.scan import patch_queue, scan_fleet, summary, worst

COLUMNS = ("host_id", "service", "engine", "installed", "available",
           "status", "reason", "action", "source")

DRIFT_COLUMNS = ("severity", "address", "attribute", "expected", "observed",
                 "remediation")

QUEUE_COLUMNS = ("host_id", "service", "engine", "installed", "target",
                 "status", "role", "environment", "compliance_age_days",
                 "action", "source")

SEVERITIES = {member.value: member for member in EolStatus}


def build_parser() -> argparse.ArgumentParser:
    """Purpose: construct the argument parser of the whole program.

    Returns: the configured parser. Keeping construction separate from main
    lets the tests drive every subcommand without patching sys.argv.
    """
    parser = argparse.ArgumentParser(
        prog="cloudops",
        description="Operations toolkit for AWS platform engineers: EOL/EOS "
                    "remediation, patch programs, and drift control.",
    )
    parser.add_argument("--version", action="version",
                        version=f"%(prog)s {__version__}")
    subs = parser.add_subparsers(dest="command", required=True)

    def _add_common(sub: argparse.ArgumentParser) -> None:
        sub.add_argument("--format", choices=("table", "csv", "json", "md"),
                         default="table", help="the output format (default: table)")
        sub.add_argument("--out", metavar="FILE",
                         help="write the report to FILE instead of stdout")

    scan = subs.add_parser("scan", help="scan an inventory against the EOL/EOS catalog")
    scan.add_argument("--inventory", required=True, metavar="FILE",
                      help="the fleet inventory (JSON or CSV, by extension)")
    scan.add_argument("--eol-catalog", required=True, metavar="FILE",
                      help="the catalog of lifecycle dates (data/eol-catalog.json)")
    scan.add_argument("--as-of", metavar="YYYY-MM-DD",
                      help="evaluate the dates as if today were this date")
    scan.add_argument("--severity", choices=sorted(SEVERITIES), metavar="LEVEL",
                      help="discard the rows below this status")
    _add_common(scan)

    queue = subs.add_parser("patch-queue",
                            help="produce the sorted work queue for the next window")
    queue.add_argument("--inventory", required=True, metavar="FILE")
    queue.add_argument("--eol-catalog", required=True, metavar="FILE")
    queue.add_argument("--compliance", metavar="FILE",
                       help="compliance reports to join in (JSON, the shape of "
                            "tests/fixtures/compliance-reports.json)")
    _add_common(queue)

    drift = subs.add_parser("drift",
                            help="compare the state file of the estate with the live describe")
    drift.add_argument("--state", required=True, metavar="FILE",
                       help="sanitized terraform state export (JSON)")
    drift.add_argument("--live", required=True, metavar="FILE",
                       help="live describe export (JSON)")
    drift.add_argument("--ignore", metavar="FILE",
                       help="extra ignore list (JSON, mapping of type to attribute list)")
    _add_common(drift)

    baselines = subs.add_parser("baseline-list",
                                help="list the patch baselines and their approval records")
    baselines.add_argument("--baselines", required=True, metavar="FILE",
                           help="the baseline definitions (data/patch-baselines.json)")
    _add_common(baselines)

    snapshot = subs.add_parser("snapshot",
                               help="write an audit snapshot of a scan (the audit trail)")
    snapshot.add_argument("--inventory", required=True, metavar="FILE")
    snapshot.add_argument("--eol-catalog", required=True, metavar="FILE")
    snapshot.add_argument("--out", required=True, metavar="FILE",
                          help="the JSON snapshot file to create")
    snapshot.add_argument("--as-of", metavar="YYYY-MM-DD")

    return parser


def _load_inventory(path: str) -> Inventory:
    """Purpose: load one inventory by its extension (json or csv)."""
    if path.endswith(".csv"):
        return Inventory.from_csv(path)
    return Inventory.from_json(path)


def _emit(text: str, out: str | None) -> None:
    """Purpose: route rendered text to stdout or to a file.

    Side effects: creates or replaces the named file when --out was given;
    the parent directories are created, because a snapshot path under
    reports/ rarely exists the first time the job runs.
    """
    if out:
        target = Path(out)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text + "\n", encoding="utf-8")
        print(f"cloudops: wrote {target}", file=sys.stderr)
    else:
        print(text)


def _rows_from_scan(inventory_path: str, catalog_path: str,
                    as_of: str | None,
                    severity: str | None) -> tuple[list, dict, EolStatus | None]:
    """Purpose: run one scan for the scan/patch-queue/snapshot commands.

    Returns: (rows, summary_counts, worst_status). Side effects: reads two files.
    """
    inventory = _load_inventory(inventory_path)
    catalog = EolCatalog.load(catalog_path)
    floor = SEVERITIES[severity] if severity else None
    today = None
    if as_of:
        year, month, day = (int(part) for part in as_of[:10].split("-"))
        today = date(year, month, day)
    rows = scan_fleet(inventory, catalog, as_of=today, severity_floor=floor)
    return rows, summary(rows), worst(rows)


def cmd_scan(args: argparse.Namespace) -> int:
    """Purpose: implement 'cloudops scan'. Returns: the exit status (0 or 1)."""
    rows, counts, worst_status = _rows_from_scan(
        args.inventory, args.eol_catalog, args.as_of, args.severity)
    payload = [{
        "host_id": r.host.host_id, "service": r.host.service,
        "engine": r.host.engine or "", "installed": r.host.version,
        "available": r.available or "", "status": r.status.value,
        "reason": r.reason, "action": r.action, "source": r.source,
    } for r in rows]
    header = "fleet status  " + "  ".join(f"{k}={v}" for k, v in counts.items())
    if args.format == "table":
        text = as_table(payload, COLUMNS, header=header)
    elif args.format == "csv":
        text = as_csv(payload, COLUMNS)
    elif args.format == "md":
        text = as_markdown(payload, COLUMNS, title="Fleet status")
    else:
        text = as_json({"generated_at": datetime.now().isoformat(timespec="seconds"),
                        "summary": counts, "rows": payload})
    _emit(text, args.out)
    if worst_status is not None and worst_status.severity >= EolStatus.EOS.severity:
        return 1
    return 0


def cmd_patch_queue(args: argparse.Namespace) -> int:
    """Purpose: implement 'cloudops patch-queue'. Returns: 0, or 1 when the queue is not empty."""
    rows, _counts, _worst = _rows_from_scan(
        args.inventory, args.eol_catalog, None, None)
    findings = None
    if args.compliance:
        with open(args.compliance, encoding="utf-8") as handle:
            reports = json.load(handle)["reports"]
        findings = compliance_scan(reports)
    items = patch_queue(rows, findings)
    if args.format == "table":
        text = as_table(items, QUEUE_COLUMNS, header=f"patch queue ({len(items)} items)")
    elif args.format == "csv":
        text = as_csv(items, QUEUE_COLUMNS)
    elif args.format == "md":
        text = as_markdown(items, QUEUE_COLUMNS, title="Patch queue")
    else:
        text = as_json({"generated_at": datetime.now().isoformat(timespec="seconds"),
                        "queue": items})
    _emit(text, args.out)
    return 1 if items else 0


def cmd_drift(args: argparse.Namespace) -> int:
    """Purpose: implement 'cloudops drift'. Returns: 1 when any drift was found."""
    with open(args.state, encoding="utf-8") as handle:
        state_export = json.load(handle)["resources"]
    with open(args.live, encoding="utf-8") as handle:
        live_describe = json.load(handle)["resources"]
    extra = None
    if args.ignore:
        with open(args.ignore, encoding="utf-8") as handle:
            extra = json.load(handle)
    findings = detect_drift(state_export, live_describe, extra_ignore=extra)
    payload = [{"severity": f.severity, "address": f.address,
                "attribute": f.attribute, "expected": f.expected,
                "observed": f.observed, "remediation": f.remediation}
               for f in findings]
    if args.format == "table":
        text = as_table(payload, DRIFT_COLUMNS,
                         header=f"drift report ({len(findings)} findings)")
    elif args.format == "csv":
        text = as_csv(payload, DRIFT_COLUMNS)
    elif args.format == "md":
        text = as_markdown(payload, DRIFT_COLUMNS, title="Drift report")
    else:
        text = as_json({"generated_at": datetime.now().isoformat(timespec="seconds"),
                        "findings": payload})
    _emit(text, args.out)
    return 1 if findings else 0


def cmd_baseline_list(args: argparse.Namespace) -> int:
    """Purpose: implement 'cloudops baseline-list'. Returns: 0; a missing approval raises."""
    baselines, groups = load_baselines(args.baselines)
    rows = [{"name": b.name, "product_family": b.product_family,
             "approved_by": b.approved_by or "", "approved_on": str(b.approved_on or ""),
             "rules": len(b.rules),
             "rejected_packages": ", ".join(
                 pkg for rule in b.rules for pkg in rule.reject_packages),
             "description": b.description}
            for b in baselines]
    if args.format == "json":
        text = as_json({"baselines": rows, "groups": [vars(g) for g in groups]})
    elif args.format == "csv":
        text = as_csv(rows, ("name", "product_family", "approved_by",
                            "approved_on", "rules", "rejected_packages",
                            "description"))
    elif args.format == "md":
        text = as_markdown(rows, ("name", "product_family", "approved_by",
                                 "approved_on", "rules", "rejected_packages"),
                          title="Patch baselines")
    else:
        text = as_table(rows, ("name", "product_family", "approved_by",
                              "approved_on", "rules", "rejected_packages"),
                        header=f"{len(rows)} baselines, {len(groups)} groups")
    _emit(text, args.out)
    return 0


def cmd_snapshot(args: argparse.Namespace) -> int:
    """Purpose: implement 'cloudops snapshot' — the immutable audit trail.

    Side effects: writes one JSON document (never overwrites an existing
    snapshot for the same day without --force; the operator keeps history).
    """
    rows, counts, worst_status = _rows_from_scan(
        args.inventory, args.eol_catalog, args.as_of, None)
    target = Path(args.out)
    if target.exists():
        stamp = datetime.now().strftime("%h%m-t%H%M%S")
        target = target.with_suffix(f".{stamp}{target.suffix}")
    document = {
        "tool": "cloudops",
        "version": __version__,
        "generated_at": datetime.now().isoformat(timespec="seconds"),
        "inventory": str(args.inventory),
        "catalog": str(args.eol_catalog),
        "summary": counts,
        "worst": worst_status.value if worst_status else "empty",
        "rows": [{
            "host_id": r.host.host_id, "service": r.host.service,
            "engine": r.host.engine or "", "installed": r.host.version,
            "available": r.available or "", "status": r.status.value,
            "reason": r.reason, "action": r.action, "source": r.source,
            "role": r.host.role, "tags": r.host.tags,
        } for r in rows],
    }
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(as_json(document) + "\n", encoding="utf-8")
    print(f"cloudops: snapshot written to {target}", file=sys.stderr)
    return 0


def main(argv: list[str] | None = None) -> int:
    """Purpose: the console entry point (declared in pyproject.toml).

    Returns: the process exit status; raises SystemExit when argparse itself
    decides to terminate (usage errors).
    """
    parser = build_parser()
    args = parser.parse_args(argv)
    handlers = {
        "scan": cmd_scan,
        "patch-queue": cmd_patch_queue,
        "drift": cmd_drift,
        "baseline-list": cmd_baseline_list,
        "snapshot": cmd_snapshot,
    }
    try:
        return handlers[args.command](args)
    except FileNotFoundError as exc:
        print(f"cloudops: data problem: {exc}", file=sys.stderr)
        return 2
    except (ValueError, KeyError) as exc:
        print(f"cloudops: data problem: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
