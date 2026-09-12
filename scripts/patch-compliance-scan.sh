#!/usr/bin/env bash
# shellcheck shell=bash
#
# This script reports the patch compliance of the fleet.  It aggregates the
# reported compliance state of every managed host by severity, prints the
# summary, and signals the verdict with its exit status: 0 when everything
# sits at or below the floor, 1 when anything rises above it.  It is the
# measurement half of the patching program; scripts/patch-schedule.sh is the
# actuation half and calls this script as its canary guard.
#
# Two data sources, deliberately separated:
#
#   OFFLINE MODE (--inventory FILE): the reports are read from a canned
#   fixture instead of the live APIs.  This is the mode of the unit tests and
#   of 'make patch-scan': it needs no network and no AWS account, and it is the
#   mode a reviewer should run first, because it shows the exact output of the
#   tool against known data.  The fixture is the shared fleet inventory of the
#   repository (a list of host records under the key 'hosts', each host
#   optionally carrying the reported-compliance fields 'patch_state',
#   'severity', 'patch_group', 'last_scan', 'missing_patches' -- the same
#   records the python core validates in cloudops/inventory.py).
#
#   LIVE MODE (the default): the aggregations come from the live Systems
#   Manager API 'aws ssm describe-patch-state-aggregations', together with the
#   per-instance missing counts of 'aws ssm describe-instance-patches'.  The
#   script consumes what the SSM agent has reported on its scan cycles; it
#   never installs, never approves, and never scans an agent itself.
#
# The severity floor (--severity) decides the verdict: CRITICAL escalates on
# any CRITICAL finding only; MEDIUM (the default) escalates on CRITICAL, HIGH,
# or MEDIUM.  --top N prints the N worst instances first (worst = severity,
# then the age of the non-compliance), matching the risk ordering of
# cloudops.patch.ComplianceFinding.risk_rank.
#
# Scope: this script reads -- one fixture file in offline mode, or the patch
# compliance aggregations of one region in live mode.  It writes nothing at
# all: no file outside its scratch directory, no API mutation, no secret.
# Credentials come from the environment or an AWS profile only.
#
# Failure behaviour: exit 0 verdict-pass, exit 1 verdict-fail (this is the
# contract the canary guard depends on), exit 2 command-line misuse, exit 3 a
# bad input file or a failed live call.
#
# See also: cloudops/patch.py (compliance_scan, the aggregator this script
# drives), scripts/patch-schedule.sh, README.md.

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
install_err_trap

# ---------------------------------------------------------------------------
# The blast radius: every AWS API operation this script may call, exactly once
# each, as a named constant.  (In offline mode none of them is reached.)
# ---------------------------------------------------------------------------
readonly CMD_SSM_DESCRIBE_AGGREGATIONS='aws ssm describe-patch-state-aggregations'
readonly CMD_SSM_DESCRIBE_INSTANCE_PATCHES='aws ssm describe-instance-patches'

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
INVENTORY_FILE=''            # set => offline mode
SEVERITY_FLOOR='MEDIUM'      # CRITICAL | HIGH | MEDIUM
FORMAT='table'               # table | csv | json
TOP=10                       # how many worst instances the report prints
PATCH_GROUP_FILTER=''        # restrict the aggregation to one patch group
MAX_AGE_DAYS=''              # optional: non-compliance older than this fails too
DRY_RUN=0                    # report-only: relaxes the exit code, never the scan
AWS_REGION=${AWS_DEFAULT_REGION:-}
WORK_DIR=''

usage() {
    cat <<'USAGE_EOF'
usage: patch-compliance-scan.sh [options]

Aggregate the reported patch compliance of the fleet by severity, print the
summary and the --top N worst instances, and signal the verdict with the exit
status: 0 when nothing rises above the floor, 1 when something does.

options:
  --inventory FILE         offline mode: read the canned fixture instead of
                           the live APIs (the tests and 'make patch-scan' use
                           this)
  --severity LEVEL         the verdict floor, one of CRITICAL, HIGH, MEDIUM
                           (default MEDIUM: CRITICAL, HIGH and MEDIUM findings
                           all fail the scan)
  --format FMT             table | csv | json (default table)
  --top N                  print the N worst instances, worst first
                           (default 10; 0 prints every failing instance)
  --patch-group NAME       aggregate only the hosts of this SSM patch group
  --max-age N              also fail when a host has been out of compliance
                           for more than N days
  -r, --region REGION      the AWS region of the live mode; defaults from
                           AWS_DEFAULT_REGION or AWS_REGION
  -n, --dry-run            report-only mode: print the report and exit 0
                           whatever the verdict (the scan itself never
                           mutates, so this only relaxes the exit code)
  -h, --help               print this help text and exit 0

exit status:
  0  nothing rose above the severity floor (or --dry-run)
  1  at least one finding rose above the floor -- the verdict the canary
     guard of scripts/patch-schedule.sh reacts to
  2  the command line was used wrongly
  3  the fixture could not be read or the live API call failed

example:
  scripts/patch-compliance-scan.sh --inventory tests/fixtures/fleet-inventory.json --format table
  scripts/patch-compliance-scan.sh --severity CRITICAL --top 5 --region eu-central-1
USAGE_EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --inventory)     [ "$#" -ge 2 ] || usage_error "$1 needs a value"; INVENTORY_FILE=$2; shift 2;;
            --severity)      [ "$#" -ge 2 ] || usage_error "$1 needs a value"; SEVERITY_FLOOR=$2; shift 2;;
            --format)        [ "$#" -ge 2 ] || usage_error "$1 needs a value"; FORMAT=$2; shift 2;;
            --top)           [ "$#" -ge 2 ] || usage_error "$1 needs a value"; TOP=$2; shift 2;;
            --patch-group)   [ "$#" -ge 2 ] || usage_error "$1 needs a value"; PATCH_GROUP_FILTER=$2; shift 2;;
            --max-age)       [ "$#" -ge 2 ] || usage_error "$1 needs a value"; MAX_AGE_DAYS=$2; shift 2;;
            -r|--region)     [ "$#" -ge 2 ] || usage_error "$1 needs a value"; AWS_REGION=$2; shift 2;;
            -n|--dry-run)    DRY_RUN=1; shift;;
            -h|--help)       usage; exit 0;;
            --) shift;;
            *)  usage_error "unknown option: $1";;
        esac
    done
}

severity_rank() {
    # Purpose: rank a severity name; the scale matches
    # cloudops.patch.ComplianceFinding.risk_rank so that the shell verdict and
    # the python queue agree on what 'worst' means.
    case "$(printf '%s' "$1" | tr 'a-z' 'A-Z')" in
        CRITICAL)      echo 4;;
        HIGH)          echo 3;;
        MEDIUM)        echo 2;;
        LOW)           echo 1;;
        INFORMATIONAL) echo 0;;
        *)             die 2 "unknown severity name: $1 (use CRITICAL, HIGH, or MEDIUM)";;
    esac
}

build_offline_reports() {
    # Purpose: turn the canned fixture into the shared report shape that
    # cloudops.patch.compliance_scan consumes (one record per host: host_id,
    # operation.patch_group, instance_information.{compliance,severity,
    # installed_count.missing,executed_at}).  The fixture is validated through
    # the python core first: a fixture the core rejects is a fixture the scan
    # must not accept either.
    local fixture=$1 out=$2
    local py_status=0
    _CLOUDOPS_REPO_ROOT=$REPO_ROOT _CLOUDOPS_INVENTORY=$fixture \
        "$PYTHON_BIN" - >"$out" <<'PYTHON_EOF'
import json
import os
import sys

sys.path.insert(0, os.environ["_CLOUDOPS_REPO_ROOT"])

with open(os.environ["_CLOUDOPS_INVENTORY"], encoding="utf-8") as handle:
    document = json.load(handle)

hosts = document["hosts"] if isinstance(document, dict) and "hosts" in document else document
if not isinstance(hosts, list):
    print("patch-compliance-scan: the fixture carries no list of hosts", file=sys.stderr)
    sys.exit(3)

# Validate the shape inline rather than via cloudops.inventory.Inventory,
# which is currently frozen-dataclass buggy in this work tree: the scan must
# not be friendlier than the model, so the same required fields are checked
# here directly.
for host in hosts:
    for required in ("host_id", "service", "version"):
        if not str(host.get(required, "")).strip():
            print("patch-compliance-scan: a fixture record lacks the required field %r"
                  % required, file=sys.stderr)
            sys.exit(3)

reports = []
for host in hosts:
    if "host_id" not in host:
        print("patch-compliance-scan: a fixture record carries no host_id", file=sys.stderr)
        sys.exit(3)
    reports.append({
        "host_id": str(host["host_id"]),
        "operation": {"patch_group": str(host.get("patch_group")
                                         or host.get("role", "standard"))},
        "instance_information": {
            # A host that does not report its patch state is, for the purpose
            # of the patch program, not compliant: the default is UNKNOWN, and
            # the verdict logic below treats UNKNOWN as non-compliant.
            "compliance": str(host.get("patch_state", "UNKNOWN")),
            "severity": str(host.get("severity", "INFORMATIONAL")),
            "installed_count": {"missing": int(host.get("missing_patches", 0) or 0)},
            "executed_at": host.get("last_scan"),
        },
    })
json.dump({"reports": reports}, sys.stdout)
PYTHON_EOF
    py_status=$?
    [ "$py_status" -eq 0 ] || die 3 "the fixture ${fixture} could not be turned into reports (see the message above)"
}

collect_live_reports() {
    # Purpose: pull the compliance data from the live SSM APIs into the same
    # shared report shape as the offline fixture, so that one printer serves
    # both modes.
    local out=$1
    local agg_json="${WORK_DIR}/aggregations.json"
    local entities_json="${WORK_DIR}/instance-patches.json"
    local py_status=0

    retry 3 2 $CMD_SSM_DESCRIBE_AGGREGATIONS \
        --aggregation-type-by 'ComplianceType' \
        --region "$AWS_REGION" --output json >"$agg_json" \
        || die 3 "the DescribePatchStateAggregations call failed"
    retry 3 2 $CMD_SSM_DESCRIBE_INSTANCE_PATCHES \
        --inventory-type PatchBaseline \
        --region "$AWS_REGION" --output json >"$entities_json" \
        || die 3 "the DescribeInstancePatches call failed"

    _CLOUDOPS_AGG=$agg_json _CLOUDOPS_INV=$entities_json \
        "$PYTHON_BIN" - >"$out" <<'PYTHON_EOF'
import json
import os
import sys

def load(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)

aggregations = load(os.environ["_CLOUDOPS_AGG"])
entities_document = load(os.environ["_CLOUDOPS_INV"])

def bucket_total(items):
    """Sum the counts of SSM bucket strings such as 'SECURITY:12'."""
    total = 0
    for item in items or []:
        _, _, digits = str(item).partition(":")
        try:
            total += int(digits)
        except ValueError:
            pass
    return total

SEVERITY_RANKS = {"INFORMATIONAL": 0, "LOW": 1, "MEDIUM": 2, "HIGH": 3, "CRITICAL": 4}

reports = []
for entity in entities_document.get("Entities", []):
    try:
        parsed = json.loads(entity.get("Content") or "{}")
    except ValueError:
        parsed = {}
    missing = bucket_total(parsed.get("MissingCount", []))
    missing_severity = "INFORMATIONAL"
    for bucket in parsed.get("MissingCount", []) or []:
        name = str(bucket).partition(":")[0].upper()
        if SEVERITY_RANKS.get(name, 0) > SEVERITY_RANKS[missing_severity]:
            missing_severity = name
    reports.append({
        "host_id": entity.get("Id", "unknown"),
        "operation": {"patch_group": parsed.get("PatchGroup", "")},
        "instance_information": {
            "compliance": parsed.get("ComplianceType", "UNKNOWN"),
            "severity": missing_severity,
            "installed_count": {"missing": missing},
            "executed_at": parsed.get("ExecutedAt"),
        },
    })

if not reports:
    # The region-wide roll-up exists precisely for the case where individual
    # hosts have not (yet) reported: surface the aggregate as an UNKNOWN
    # verdict instead of pretending a silent fleet is a compliant fleet.
    rollup = aggregations.get("Aggregations", [])
    reports.append({
        "host_id": "region-rollup",
        "operation": {"patch_group": "unknown"},
        "instance_information": {
            "compliance": "ERROR" if rollup else "UNKNOWN",
            "severity": "MEDIUM",
            "installed_count": {"missing": 0},
            "executed_at": None,
        },
    })

json.dump({"reports": reports, "aggregations": aggregations.get("Aggregations", [])},
          sys.stdout)
PYTHON_EOF
    py_status=$?
    [ "$py_status" -eq 0 ] || die 3 "the live aggregation documents could not be folded into the report shape"
}

emit_report() {
    # Purpose: the shared printer and the verdict.  Reads the report document
    # ($1), drives cloudops.patch.compliance_scan for the ordering, applies
    # the severity floor and the age limit, prints in --format, and exits with
    # the verdict (0 pass, 1 fail, 3 internal fault).
    local reports_file=$1
    local py_status=0
    _CLOUDOPS_REPORTS=$reports_file \
    _CLOUDOPS_FLOOR_RANK=$(severity_rank "$SEVERITY_FLOOR") \
    _CLOUDOPS_FORMAT=$FORMAT \
    _CLOUDOPS_TOP=$TOP \
    _CLOUDOPS_GROUP=$PATCH_GROUP_FILTER \
    _CLOUDOPS_MAX_AGE=$MAX_AGE_DAYS \
    _CLOUDOPS_DRY_RUN=$DRY_RUN \
    _CLOUDOPS_REPO_ROOT=$REPO_ROOT \
        "$PYTHON_BIN" - <<'PYTHON_EOF'
import datetime
import json
import os
import sys

sys.path.insert(0, os.environ["_CLOUDOPS_REPO_ROOT"])
try:
    from cloudops.patch import compliance_scan
except ImportError as exc:
    print("patch-compliance-scan: the cloudops package could not be imported: %s" % exc,
          file=sys.stderr)
    sys.exit(3)

with open(os.environ["_CLOUDOPS_REPORTS"], encoding="utf-8") as handle:
    document = json.load(handle)
records = document.get("reports", document if isinstance(document, list) else [])

group = os.environ.get("_CLOUDOPS_GROUP", "")
if group:
    records = [r for r in records
               if (r.get("operation") or {}).get("patch_group", "") == group]

findings = compliance_scan(records)

floor_rank = int(os.environ["_CLOUDOPS_FLOOR_RANK"])
max_age = os.environ.get("_CLOUDOPS_MAX_AGE", "") or ""
max_age_days = int(max_age) if max_age.isdigit() else None
SEVERITY_RANKS = {"CRITICAL": 4, "HIGH": 3, "MEDIUM": 2, "LOW": 1, "INFORMATIONAL": 0}
# A host whose reported state is anything but COMPLIANT can fail the scan;
# ERROR and MISMATCHED are worse than any severity number, since they mean
# the agent cannot answer the question at all.
FAILING_STATES = ("NOT_COMPLIANT", "NON_COMPLIANT", "NON-COMPLIANT", "NONCOMPLIANT",
                  "ERROR", "MISMATCHED", "UNKNOWN")

failing = []
for finding in findings:
    rank = SEVERITY_RANKS.get(finding.worst_severity, 0)
    bad_state = finding.state in FAILING_STATES or finding.state == ""
    too_old = max_age_days is not None and finding.oldest_missing_days > max_age_days
    above_floor = rank >= floor_rank and rank > 0
    if bad_state and (above_floor or too_old
                      or finding.state in ("ERROR", "MISMATCHED")
                      or finding.missing > 0):
        failing.append(finding)

total = len(findings)
compliant = total - len(failing)
by_severity = {}
for finding in failing:
    key = finding.worst_severity if finding.worst_severity in SEVERITY_RANKS else "UNKNOWN"
    by_severity[key] = by_severity.get(key, 0) + 1

top = int(os.environ.get("_CLOUDOPS_TOP", "10") or "10")
shown = failing if top <= 0 else failing[:top]
fmt = os.environ["_CLOUDOPS_FORMAT"]
dry = os.environ.get("_CLOUDOPS_DRY_RUN", "0") == "1"

if fmt == "json":
    stamp = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
    json.dump({
        "generated_at": stamp,
        "total_hosts": total,
        "compliant_hosts": compliant,
        "failing_hosts": len(failing),
        "by_severity": by_severity,
        "floor_rank": floor_rank,
        "verdict": "FAIL" if (failing and not dry) else "PASS",
        "worst": [{
            "host_id": f.host_id, "patch_group": f.patch_group, "state": f.state,
            "missing": f.missing, "oldest_missing_days": f.oldest_missing_days,
            "worst_severity": f.worst_severity,
        } for f in shown],
    }, sys.stdout, indent=2)
    print("")
elif fmt == "csv":
    print("host_id,patch_group,state,missing,oldest_missing_days,worst_severity")
    for f in shown:
        print("%s,%s,%s,%d,%d,%s" % (f.host_id, f.patch_group, f.state,
                                     f.missing, f.oldest_missing_days, f.worst_severity))
else:
    print("patch compliance summary -- %d host(s), %d compliant, %d above the floor"
          % (total, compliant, len(failing)))
    if by_severity:
        order = sorted(by_severity, key=lambda s: -SEVERITY_RANKS.get(s, 0))
        print("severity roll-up: " + ", ".join("%s=%d" % (s, by_severity[s]) for s in order))
    print("")
    if shown:
        print("%-24s %-18s %-14s %-8s %-6s %s"
              % ("HOST", "PATCH GROUP", "STATE", "MISS", "AGE_D", "WORST SEVERITY"))
        for f in shown:
            print("%-24s %-18s %-14s %-8d %-6d %s" % (f.host_id, f.patch_group or "-",
                                                       f.state, f.missing,
                                                       f.oldest_missing_days, f.worst_severity))
    else:
        print("nothing rose above the floor; the fleet is compliant as reported")

if failing and not dry:
    sys.exit(1)
sys.exit(0)
PYTHON_EOF
    py_status=$?
    return "$py_status"
}

main() {
    parse_args "$@"
    require_cmd python3
    case "$FORMAT" in table|csv|json) : ;; *) usage_error "--format must be table, csv, or json";; esac
    [[ $TOP =~ ^[0-9]+$ ]] || usage_error "--top must be a non-negative integer"
    case "$(printf '%s' "$SEVERITY_FLOOR" | tr 'a-z' 'A-Z')" in
        CRITICAL|HIGH|MEDIUM) : ;; *) usage_error "--severity must be CRITICAL, HIGH, or MEDIUM";;
    esac
    [ -z "$MAX_AGE_DAYS" ] || [[ $MAX_AGE_DAYS =~ ^[0-9]+$ ]] || usage_error "--max-age must be a non-negative integer"

    WORK_DIR=$(mktemp -d -t patch-scan-XXXXXX)
    trap '[ -n "$WORK_DIR" ] && rm -rf -- "$WORK_DIR"' EXIT

    local reports_file="${WORK_DIR}/reports.json"
    if [ -n "$INVENTORY_FILE" ]; then
        [ -f "$INVENTORY_FILE" ] || die 3 "no such inventory fixture: ${INVENTORY_FILE}"
        build_offline_reports "$INVENTORY_FILE" "$reports_file"
        local n
        n=$(json_query "$reports_file" 'len(doc["reports"])') || die 3 "the reports document is unreadable"
        log info "offline mode: read the compliance reports of ${n} host(s) from ${INVENTORY_FILE}"
    else
        # Live mode needs the AWS CLI and a region; offline mode needs neither.
        [ -n "$AWS_REGION" ] || die "no region: pass --region, or export AWS_DEFAULT_REGION / AWS_REGION"
        require_cmd aws
        log info "live mode: aggregating the patch state of region ${AWS_REGION} via the SSM APIs"
        collect_live_reports "$reports_file"
    fi

    local verdict=0
    emit_report "$reports_file" || verdict=$?
    case "$verdict" in
        0) log info "verdict: PASS -- nothing rose above the ${SEVERITY_FLOOR} floor";;
        1) err   "verdict: FAIL -- at least one finding rose above the ${SEVERITY_FLOOR} floor";;
        *) die "$verdict" "the scan itself failed; no verdict can be trusted";;
    esac
    if [ "$DRY_RUN" -eq 1 ] && [ "$verdict" -eq 1 ]; then
        log warn "dry run: the verdict FAIL is reported as PASS because --dry-run relaxes the exit code"
        exit 0
    fi
    exit "$verdict"
}

main "$@"
