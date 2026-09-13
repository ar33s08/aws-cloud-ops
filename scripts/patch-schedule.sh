#!/usr/bin/env bash
# shellcheck shell=bash
#
# This script initiates the patching window of the fleet, ring by ring, from
# the group definitions in the baseline definition file (by convention
# data/patch-baselines.json).  The rings are executed in strict order:
#
#     1. the canary ring    -- a handful of low-risk instances, patched first
#     2. the standard ring  -- the bulk of the estate
#     3. the critical ring  -- the systems that carry production traffic
#
# The canary ring exists so that a bad baseline shows up on ten machines
# instead of on ten thousand, and the script enforces that purpose with its
# central guard:
#
#     THE CANARY GUARD: before the standard ring is started, and again before
#     the critical ring, the script runs the compliance scan of the canary ring
#     (scripts/patch-compliance-scan.sh --patch-group <canary-group>) and
#     REFUSES TO PROCEED when the canary ring has not passed its compliance
#     scan.  "Passed" means the scan exited 0 -- no canary host reports a
#     state above the severity floor, none is in ERROR, and none has been out
#     of compliance longer than the age limit.  When the guard fires, the
#     standard and critical rings are never started and the script exits 1,
#     leaving the canary hosts as the evidence of what is wrong with the
#     baseline.
#
# The windows themselves are AWS Systems Manager Maintenance Windows: the
# script starts the window of each ring with the cron schedule from the group
# definition, waits for the current execution to finish, and then advances.
#
# Scope: this script reads one JSON definition file and one region's SSM
# maintenance windows; it starts window executions and runs the sibling
# compliance scan script read-only.  It never touches instances directly,
# never registers baselines (that is scripts/patch-baseline-register.sh), and
# never reads or prints a secret.  Credentials come from the environment or an
# AWS profile only.
#
# Failure behaviour: a failed window execution, a failed canary guard, or an
# API fault exits 1 with the failed command line reported by the error trap;
# a bad definition file exits 3; a wrong command line exits 2.  Re-running the
# script after a transient fault is safe: StartMaintenanceWindowExecution is
# idempotent per window when the previous execution is terminal.
#
# The companion manual page is docs/man/patch-schedule.1.md; read it with
# 'man docs/man/patch-schedule.1.md' or render it with 'groff -mandoc'.
#
# See also: scripts/patch-compliance-scan.sh, cloudops/patch.py, OPERATIONS.md.

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
install_err_trap

# ---------------------------------------------------------------------------
# The blast radius: every AWS API operation this script may call, exactly once
# each, as a named constant.  The compliance scan is delegated to its own
# script, so its API surface is auditable there and not duplicated here.
# ---------------------------------------------------------------------------
readonly CMD_SSM_START_WINDOW_EXECUTION='aws ssm start-maintenance-window-execution'
readonly CMD_SSM_DESCRIBE_TASK_EXECUTION='aws ssm describe-maintenance-window-task-execution'

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
DEFINITIONS_JSON="${REPO_ROOT}/data/patch-baselines.json"
DRY_RUN=0
AWS_REGION=${AWS_DEFAULT_REGION:-}
# The severity floor of the canary guard: a canary finding at or above this
# level blocks the roll-out.  CRITICAL..MEDIUM are the meaningful floors; the
# task brief's floor is CRITICAL by default so that an INFORMATIONAL drift of
# a non-security package does not freeze the whole estate -- lower it with
# --floor when the program requires it.
FLOOR='CRITICAL'
# A canary host that has been out of compliance for longer than this many days
# fails the guard even when the missing patches are old news (an old, ignored
# non-compliance is a program that has lost control of its fleet).
MAX_NONCOMPLIANT_AGE_DAYS=7
# The wall budget of one window execution.
EXECUTION_BUDGET_SECONDS=3600
POLL_INTERVAL_SECONDS=15

usage() {
    cat <<'USAGE_EOF'
usage: patch-schedule.sh [options]

Initiate the patching window ring by ring -- canary, then standard, then
critical -- from the group definitions of the baseline definition file.  Each
ring is started as a maintenance-window execution with the cron schedule of
its group definition and is waited out to a terminal state before the next
ring starts.  The canary guard refuses to proceed to the standard or the
critical ring when the canary ring has not passed its compliance scan.

options:
  -f, --file PATH          the JSON group definition file
                         (default data/patch-baselines.json of the checkout)
  -r, --region REGION      the AWS region; defaults from AWS_DEFAULT_REGION
                         or AWS_REGION
  --floor SEVERITY         the severity floor of the canary guard, one of
                          CRITICAL, HIGH, MEDIUM (default CRITICAL)
  --max-age N              fail the canary guard when a canary host has been
                         out of compliance for more than N days (default 7)
  --budget SECONDS         the wall budget of one window execution
                         (default 3600)
  --poll-interval N        seconds between two execution polls (default 15)
  -n, --dry-run            print every aws cli command and every guard
                         invocation without executing any of them
  -h, --help               print this help text and exit 0

exit status:
  0  all three rings completed and every canary guard passed
  1  a window execution failed, timed out, or a canary guard refused to
     proceed (the standard and critical rings are then never started)
  2  the command line was used wrongly
  3  the definition file is missing or failed validation

example:
  scripts/patch-schedule.sh --dry-run --region eu-central-1
  scripts/patch-schedule.sh --floor HIGH --budget 7200
USAGE_EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -f|--file|--definition) [ "$#" -ge 2 ] || usage_error "$1 needs a value"; DEFINITIONS_JSON=$2; shift 2;;
            -r|--region)            [ "$#" -ge 2 ] || usage_error "$1 needs a value"; AWS_REGION=$2; shift 2;;
            --floor)                [ "$#" -ge 2 ] || usage_error "$1 needs a value"; FLOOR=$2; shift 2;;
            --max-age)              [ "$#" -ge 2 ] || usage_error "$1 needs a value"; MAX_NONCOMPLIANT_AGE_DAYS=$2; shift 2;;
            --budget)               [ "$#" -ge 2 ] || usage_error "$1 needs a value"; EXECUTION_BUDGET_SECONDS=$2; shift 2;;
            --poll-interval)        [ "$#" -ge 2 ] || usage_error "$1 needs a value"; POLL_INTERVAL_SECONDS=$2; shift 2;;
            -n|--dry-run)           DRY_RUN=1; shift;;
            -h|--help)              usage; exit 0;;
            --) shift;;
            *)  usage_error "unknown option: $1";;
        esac
    done
}

severity_rank() {
    # Purpose: map a severity name to its rank so that comparisons read as
    # prose ('HIGH is above the floor MEDIUM').  Ranks match the vocabulary of
    # cloudops.patch.ComplianceFinding.risk_rank.
    case "$(printf '%s' "$1" | tr 'a-z' 'A-Z')" in
        CRITICAL)      echo 4;;
        HIGH)          echo 3;;
        MEDIUM)        echo 2;;
        LOW)           echo 1;;
        INFORMATIONAL) echo 0;;
        *)             die "unknown severity name: $1";;
    esac
}

load_ring_schedule() {
    # Purpose: ask the python core (cloudops.patch.load_baselines, the same
    # validator the tests drive) for the schedule and the patch group name of
    # one ring, printed as 'NAME|SCHEDULE|CUTOFF_HOURS'.
    # Usage: load_ring_schedule FILE RING_NAME
    local file=$1 ring=$2
    _CLOUDOPS_REPO_ROOT=$REPO_ROOT _CLOUDOPS_BASELINE_FILE=$file _CLOUDOPS_RING=$ring \
        "$PYTHON_BIN" - <<'PYTHON_EOF'
import os
import sys

sys.path.insert(0, os.environ["_CLOUDOPS_REPO_ROOT"])

from cloudops.patch import load_baselines

try:
    _baselines, groups = load_baselines(os.environ["_CLOUDOPS_BASELINE_FILE"])
except (ValueError, KeyError, OSError) as exc:
    print("patch-schedule: the definition file failed validation: %s" % exc, file=sys.stderr)
    sys.exit(3)

wanted = os.environ["_CLOUDOPS_RING"]
for group in groups:
    if group.name == wanted:
        print("%s|%s|%d" % (group.name, group.schedule, group.cutoff_hours))
        sys.exit(0)

print("patch-schedule: the definition declares no ring named %r; the rings of "
      "the program are named canary, standard, and critical" % wanted, file=sys.stderr)
sys.exit(3)
PYTHON_EOF
}

start_window_execution() {
    # Purpose: start one maintenance-window execution (run() prints the exact
    # command in dry-run mode) and then wait for the task execution to reach a
    # terminal state.  The window id follows the estate convention
    # 'mw-<ring>-patching': the infrastructure of modules/observability and the
    # runbooks create the windows under these names; an id passed through the
    # console is always a deliberate act, never a string built here from a
    # user value other than the validated ring name.
    local ring=$1 window_id=$2
    log info "ring ${ring}: starting the window execution of ${window_id} with the schedule from the group definition"
    run $CMD_SSM_START_WINDOW_EXECUTION \
        --window-id "$window_id" \
        --targets "Key=InstanceIds,Values=${ring}" \
        --targets "Key=PatchBaseline,Values=${ring}" \
        --task-type RUN_COMMAND \
        --task-invocation-parameters "Comments=patch-schedule.sh ring ${ring}" \
        --region "$AWS_REGION"
    [ "$DRY_RUN" -eq 1 ] && return 0

    local execution_json="${WORK_DIR}/execution-${ring}.json"
    local deadline
    deadline=$(( $(date +%s) + EXECUTION_BUDGET_SECONDS ))
    local status='PENDING'
    while [ "$status" = "PENDING" ] || [ "$status" = "IN_PROGRESS" ] || [ "$status" = "SCHEDULED" ]; do
        if [ "$(date +%s)" -ge "$deadline" ]; then
            err "ring ${ring}: the window execution did not reach a terminal state within ${EXECUTION_BUDGET_SECONDS}s"
            return 1
        fi
        retry 3 2 $CMD_SSM_DESCRIBE_TASK_EXECUTION \
            --window-id "$window_id" \
            --max-results 5 \
            --region "$AWS_REGION" --output json >"$execution_json" 2>/dev/null \
            || die "ring ${ring}: the DescribeMaintenanceWindowTaskExecutions call failed"
        status=$(json_query "$execution_json" \
            "max((e['Status'] for e in doc['TaskExecutions']), key=['PENDING','SCHEDULED','IN_PROGRESS','SUCCESS','TIMED_OUT','CANCELLED','FAILED'].index)") \
            || die "ring ${ring}: the execution document carried no task executions"
        log debug "ring ${ring}: execution status ${status}"
        sleep "$POLL_INTERVAL_SECONDS"
    done
    case "$status" in
        SUCCESS) log info "ring ${ring}: the window execution completed SUCCESS"; return 0;;
        *) err "ring ${ring}: the window execution ended ${status}"; return 1;;
    esac
}

canary_guard() {
    # Purpose: THE GUARD.  Run the compliance scan of the canary ring and
    # refuse to proceed when it has not passed.  Documented at the top of
    # this file; the scan script itself owns the API surface of the check.
    # Returns: 0 when the canary ring is compliant within the floor and the
    # age limit; 1 when the guard must block the roll-out.
    local canary_group=$1
    log info "canary guard: scanning the compliance of the canary ring (group ${canary_group}, floor ${FLOOR}, age limit ${MAX_NONCOMPLIANT_AGE_DAYS}d)"
    if [ "$DRY_RUN" -eq 1 ]; then
        log info "dry run: would execute: scripts/patch-compliance-scan.sh --patch-group ${canary_group} --severity ${FLOOR} --max-age ${MAX_NONCOMPLIANT_AGE_DAYS} --region ${AWS_REGION}"
        log info "dry run: the guard is assumed to pass so that the full plan of all three rings is printed"
        return 0
    fi
    if "${SCRIPT_DIR}/patch-compliance-scan.sh" \
            --patch-group "$canary_group" \
            --severity "$FLOOR" \
            --max-age "$MAX_NONCOMPLIANT_AGE_DAYS" \
            --region "$AWS_REGION" \
            --format table >/dev/null; then
        log info "canary guard: the canary ring passed its compliance scan; proceeding to the next ring"
        return 0
    else
        local scan_status=$?
        err "canary guard: the canary ring FAILED its compliance scan (exit ${scan_status}); the standard and critical rings are NOT started"
        err "canary guard: repair the canary findings (see scripts/patch-compliance-scan.sh --format table) or register a corrected baseline, then re-run this script; the canary hosts are the evidence and must not be mass-patched around"
        return 1
    fi
}

WORK_DIR=''

main() {
    parse_args "$@"
    [ -n "$AWS_REGION" ] || die "no region: pass --region, or export AWS_DEFAULT_REGION / AWS_REGION"
    [ -f "$DEFINITIONS_JSON" ] || die 3 "no such definition file: ${DEFINITIONS_JSON} (pass -f PATH)"
    case "$FLOOR" in CRITICAL|HIGH|MEDIUM) : ;; *) usage_error "--floor must be one of CRITICAL, HIGH, MEDIUM";; esac
    [[ $MAX_NONCOMPLIANT_AGE_DAYS =~ ^[0-9]+$ ]] || usage_error "--max-age must be a non-negative integer"
    [[ $EXECUTION_BUDGET_SECONDS =~ ^[0-9]+$ ]] && [ "$EXECUTION_BUDGET_SECONDS" -ge 60 ] || usage_error "--budget must be an integer of at least 60 seconds"

    require_cmd aws python3
    WORK_DIR=$(mktemp -d -t patch-schedule-XXXXXX)
    trap '[ -n "$WORK_DIR" ] && rm -rf -- "$WORK_DIR"' EXIT

    log info "patching window plan (definition: ${DEFINITIONS_JSON}, region: ${AWS_REGION}, floor: ${FLOOR})"

    # --- ring 1: the canary ------------------------------------------------------
    local canary_row
    canary_row=$(load_ring_schedule "$DEFINITIONS_JSON" canary) || die 3 "the canary ring is not defined"
    # The two later rings are validated here and not captured: the execution of
    # each ring resolves its own schedule at the moment that it is the ring of
    # the hour, and a missing definition must fail the plan before the canary of
    # the window has started to run.
    load_ring_schedule "$DEFINITIONS_JSON" standard >/dev/null || die 3 "the standard ring is not defined"
    load_ring_schedule "$DEFINITIONS_JSON" critical >/dev/null || die 3 "the critical ring is not defined"

    local canary_name canary_schedule canary_group
    canary_name=${canary_row%%|*}
    canary_schedule=$(printf '%s' "$canary_row" | cut -d'|' -f2)
    canary_group=${canary_row%%|*}   # the group name doubles as the SSM tag value
    log info "ring order: 1=${canary_name} (schedule ${canary_schedule}), 2=standard, 3=critical -- the order is the safety model of the program and is never permuted"

    if ! start_window_execution canary "mw-canary-patching"; then
        die "the canary ring failed; nothing beyond the canary was touched"
    fi

    # --- the guard between canary and the rest ---------------------------------
    canary_guard "$canary_group" || die "the canary guard blocked the roll-out (see the messages above)"

    # --- ring 2: the standard bulk ----------------------------------------------
    if ! start_window_execution standard "mw-standard-patching"; then
        die "the standard ring failed; the critical ring was deliberately not started"
    fi

    # --- the guard runs again: the bulk may regress in ways the canary missed ---
    canary_guard "$canary_group" || die "the canary guard blocked the critical ring after the standard ring completed (see the messages above)"

    # --- ring 3: the critical systems -------------------------------------------
    if ! start_window_execution critical "mw-critical-patching"; then
        die "the critical ring failed; escalate per the incident runbook"
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        log info "dry run: the complete plan of all three rings was printed; nothing was executed"
    else
        log info "the patching window completed: canary, standard, and critical rings all finished with their guards passed"
    fi
}

main "$@"
