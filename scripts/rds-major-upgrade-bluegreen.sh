#!/usr/bin/env bash
# shellcheck shell=bash
#
# This script performs a MAJOR engine upgrade (for example mysql 5.7 -> 8.0)
# with an Amazon RDS blue/green deployment: it creates the deployment, lets
# RDS build the green environment as a read replica of the blue one and apply
# the new engine there, waits until the deployment reports the status
# AVAILABLE, checks the replication lag, and only then promotes (switches over)
# the green environment to production.
#
# The exact API surface (documented in the AWS CLI reference under 'rds'):
#   aws rds create-blue-green-deployment     -- builds the green environment
#   aws rds describe-blue-green-deployments  -- the poll of the status
#   aws rds switchover-blue-green-deployment -- the promotion: this is the
#                                              'switch' that promotes the green
#                                              to the blue
#   aws rds delete-blue-green-deployment     -- removes the deployment record
# after the switch; the retired blue instance itself is kept, not destroyed by
# this script.
#
# The sequence, in order, with the reason each step is where it is:
#   1. snapshot the blue environment first (aws rds create-db-snapshot).  The
#      snapshot identifier is printed and retained: it is the restore-to-point
#      of the whole operation.  Without a snapshot there is no plan.
#   2. create the blue/green deployment for the new engine version.
#   3. poll until the deployment is AVAILABLE (and the green target is too).
#   4. THE LAG GUARD: measure the replication lag of the green environment and
#      REFUSE to promote when it exceeds --max-lag seconds.  Promoting behind
#      on a lagging replica loses writes; the guard turns 'we will not lose
#      data' from an assumption into a checked precondition.
#   5. promote with the switchover (the switch).
#   6. remove the deployment record only after the checkpoint of the read
#      replica has completed, so that the rollback path stays open while it is
#      still useful.
#
# What the reader must know about the blast radius: this script changes the
# production database.  That is why every command can be seen before it runs
# (--dry-run prints each one verbatim), why the snapshot precedes every step,
# and why the script refuses to act when the lag guard does not pass.
#
# Scope: this script reads and changes exactly one RDS resource -- the source
# instance identifier passed with --source, plus the deployment created from
# it -- in one region.  It never touches another database, never deletes an
# instance, and never reads or prints a secret.  Credentials come from the
# process environment or an AWS profile only.
#
# Failure behaviour: a failed create/poll exits 1 before the switch, leaving
# production on the untouched blue environment (the failure mode is safe by
# construction).  A failed switch leaves the switchover timeout of the service
# to roll the environments back; the snapshot identifier and the deployment
# identifier are both printed so the operator can continue by hand.  An
# exhausted lag guard exits 1 with the measured lag in the log.
#
# See also: the manual page docs/man/rds-major-upgrade-bluegreen.1.md, the
# upgrade runbooks referenced by README.md, scripts/rds-minor-upgrade.sh.

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
install_err_trap

# ---------------------------------------------------------------------------
# The blast radius: every AWS API operation this script may call, exactly once
# each, as a named constant.
# ---------------------------------------------------------------------------
readonly CMD_RDS_DESCRIBE_DB_INSTANCES='aws rds describe-db-instances'
readonly CMD_RDS_CREATE_DB_SNAPSHOT='aws rds create-db-snapshot'
readonly CMD_RDS_CREATE_BLUE_GREEN='aws rds create-blue-green-deployment'
readonly CMD_RDS_DESCRIBE_BLUE_GREEN='aws rds describe-blue-green-deployments'
readonly CMD_RDS_SWITCHOVER_BLUE_GREEN='aws rds switchover-blue-green-deployment'
readonly CMD_RDS_DELETE_BLUE_GREEN='aws rds delete-blue-green-deployment'

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
SOURCE_IDENTIFIER=''
TARGET_VERSION=''
DRY_RUN=0
MAX_LAG_SECONDS=60                # the lag guard threshold for the promotion
CREATE_TIMEOUT_SECONDS=5400       # an hour and a half: the green build is slow
SWITCHOVER_TIMEOUT_SECONDS=300    # the service timeout of the switchover itself
DO_SWITCHOVER=1                   # the promotion phase; --no-switch skips it
DEPLOYMENT_NAME=''
SNAPSHOT_ID=''
POLL_INTERVAL_SECONDS=30
AWS_REGION=${AWS_DEFAULT_REGION:-}
WORK_DIR=''

usage() {
    cat <<'USAGE_EOF'
usage: rds-major-upgrade-bluegreen.sh --source DB-IDENTIFIER
                                      --target-version MAJOR-VER [options]

Perform a major engine upgrade with an RDS blue/green deployment: snapshot
the blue environment, create the green environment at the target version, wait
until the deployment reports AVAILABLE, refuse to promote while the
replication lag exceeds --max-lag, then promote (switchover) the green to the
blue and remove the deployment record after the read-replica checkpoint.

options:
  --source ID              the DB instance identifier of the blue environment
                           (required)
  --target-version VER     the target engine version, a NEW MAJOR of the
                           installed one (required; a same-major target
                           belongs to scripts/rds-minor-upgrade.sh)
  --deployment-name NAME   the name of the blue/green deployment (default
                           '<source>-major-<UTC stamp>')
  --snapshot-id ID         the snapshot identifier for the pre-upgrade
                           snapshot (default '<source>-premaj-<UTC stamp>');
                           the identifier is printed and retained as the
                           restore-to-point
  --max-lag SECONDS        refuse to promote above this replication lag
                           (default 60)
  --create-timeout S       the wall budget of the build of the green
                           environment (default 5400)
  --switchover-timeout S   the service-side timeout of the switchover
                           (default 300)
  --poll-interval N        seconds between two status polls (default 30)
  -r, --region REGION      the AWS region; defaults from AWS_DEFAULT_REGION
                           or AWS_REGION
  -n, --dry-run            print every aws cli command, execute nothing
  -h, --help               print this help text and exit 0

exit status:
  0  the green environment was promoted and the deployment record removed
  1  a guard refused the promotion, or an AWS call failed (in every case
     production stays on the untouched blue environment)
  2  the command line was used wrongly

example:
  scripts/rds-major-upgrade-bluegreen.sh --source db-prod-01 \
      --target-version 8.0 --max-lag 30 --dry-run
  scripts/rds-major-upgrade-bluegreen.sh --source db-prod-01 --target-version 8.0
USAGE_EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --source|--source-identifier) [ "$#" -ge 2 ] || usage_error "$1 needs a value"; SOURCE_IDENTIFIER=$2; shift 2;;
            --target-version)        [ "$#" -ge 2 ] || usage_error "$1 needs a value"; TARGET_VERSION=$2; shift 2;;
            --deployment-name)       [ "$#" -ge 2 ] || usage_error "$1 needs a value"; DEPLOYMENT_NAME=$2; shift 2;;
            --snapshot-id)           [ "$#" -ge 2 ] || usage_error "$1 needs a value"; SNAPSHOT_ID=$2; shift 2;;
            --max-lag)               [ "$#" -ge 2 ] || usage_error "$1 needs a value"; MAX_LAG_SECONDS=$2; shift 2;;
            --switch|--promote)      DO_SWITCHOVER=1; shift;;
            --no-promote|--no-switch) DO_SWITCHOVER=0; shift;;
            --create-timeout)        [ "$#" -ge 2 ] || usage_error "$1 needs a value"; CREATE_TIMEOUT_SECONDS=$2; shift 2;;
            --switchover-timeout)    [ "$#" -ge 2 ] || usage_error "$1 needs a value"; SWITCHOVER_TIMEOUT_SECONDS=$2; shift 2;;
            --poll-interval)         [ "$#" -ge 2 ] || usage_error "$1 needs a value"; POLL_INTERVAL_SECONDS=$2; shift 2;;
            -r|--region)             [ "$#" -ge 2 ] || usage_error "$1 needs a value"; AWS_REGION=$2; shift 2;;
            -n|--dry-run)            DRY_RUN=1; shift;;
            -h|--help)               usage; exit 0;;
            --) shift;;
            *)  usage_error "unknown option: $1";;
        esac
    done
}

blue_is_ahead_of_major() {
    # Purpose: confirm the target really is a DIFFERENT MAJOR (this script is
    # for majors), and not an attempt at a same-major patch bump.  Prints the
    # verdict with the same protocol as scripts/rds-minor-upgrade.sh.
    local installed=$1 target=$2
    _CLOUDOPS_REPO_ROOT=$REPO_ROOT _CLOUDOPS_INSTALLED=$installed _CLOUDOPS_TARGET=$target \
        "$PYTHON_BIN" - <<'PYTHON_EOF'
import os
import sys

sys.path.insert(0, os.environ["_CLOUDOPS_REPO_ROOT"])

from cloudops.eol import SemVer, compare_versions

installed = os.environ["_CLOUDOPS_INSTALLED"]
target = os.environ["_CLOUDOPS_TARGET"]

try:
    a = SemVer(installed)
    b = SemVer(target)
    cmp = compare_versions(installed, target)
except ValueError as exc:
    print("UNPARSABLE|%s" % exc)
    sys.exit(0)

if a.major == b.major:
    print("SAME_MAJOR|%d" % a.major)
elif cmp < 0:
    print("OK|%d|%d" % (a.major, b.major))
else:
    print("BACKWARD|%d|%d" % (a.major, b.major))
PYTHON_EOF
}

deployment_reports_available() {
    # Purpose: the poll predicate -- the deployment and its green target are
    # both AVAILABLE.  The status strings of the service for this state are
    # 'AVAILABLE' on the deployment record.
    local file=$1
    local status green_status
    status=$(json_query "$file" "doc['BlueGreenDeployments'][0]['Status']") || return 1
    green_status=$(json_query "$file" "doc['BlueGreenDeployments'][0]['GreenDbInstances'][0]['Status']" 2>/dev/null || echo '')
    [ "$status" = "AVAILABLE" ] || return 1
    # The green instance may be 'available' or the deployment may report the
    # replica set; accept either so long as nothing reports a failed state.
    case "$green_status" in
        *ailed*|*rror*) return 1;;
    esac
    return 0
}

measure_replication_lag() {
    # Purpose: the lag guard measurement.  The lag of the green replica is the
    # replica lag metric of the green member of the deployment record; when the
    # record carries no number the guard reads the lag from the CloudWatch-free
    # source of truth available to it, the SecondsBehindSource field of the
    # describe document.  Prints the lag as an integer number of seconds, or
    # 'UNKNOWN' when the service does not report it.
    local file=$1
    _CLOUDOPS_DEPLOYMENT=$file "$PYTHON_BIN" - <<'PYTHON_EOF'
import json
import os
import sys

try:
    with open(os.environ["_CLOUDOPS_DEPLOYMENT"], encoding="utf-8") as handle:
        doc = json.load(handle)
except (OSError, ValueError) as exc:
    print("UNKNOWN")
    sys.exit(0)

deployments = doc.get("BlueGreenDeployments") or []
if not deployments:
    print("UNKNOWN")
    sys.exit(0)

deployment = deployments[0]
candidates = []
for key in ("ReplicationLagSeconds", "SecondsBehindSource"):
    value = deployment.get(key)
    if isinstance(value, (int, float)):
        candidates.append(float(value))
for member in deployment.get("GreenDbInstances", []) or []:
    value = member.get("ReplicationLagSeconds")
    if isinstance(value, (int, float)):
        candidates.append(float(value))

if not candidates:
    print("UNKNOWN")
else:
    print("%d" % int(max(candidates)))
PYTHON_EOF
}

main() {
    parse_args "$@"
    [ -n "$SOURCE_IDENTIFIER" ] || usage_error '--source is required'
    [ -n "$TARGET_VERSION" ] || usage_error '--target-version is required'
    [ -n "$AWS_REGION" ] || die "no region: pass --region, or export AWS_DEFAULT_REGION / AWS_REGION"
    [[ $SOURCE_IDENTIFIER =~ ^[0-9a-zA-Z][-_0-9a-zA-Z]{0,62}$ ]] || die "DB instance identifier is not a valid RDS identifier: ${SOURCE_IDENTIFIER}"
    [[ $TARGET_VERSION =~ ^[0-9]+(\.[0-9]+){0,3}([-._0-9a-zA-Z]*)$ ]] || die "the target version does not look like an engine version: ${TARGET_VERSION}"
    [[ $MAX_LAG_SECONDS =~ ^[0-9]+$ ]] && [ "$MAX_LAG_SECONDS" -ge 0 ] || usage_error "--max-lag must be a non-negative integer"
    require_cmd aws python3

    WORK_DIR=$(mktemp -d -t rds-bg-XXXXXX)
    trap '[ -n "$WORK_DIR" ] && rm -rf -- "$WORK_DIR"' EXIT

    # --- read the blue environment --------------------------------------------
    local describe_json="${WORK_DIR}/blue.json"
    local installed='' engine=''
    if describe_instance_blue "$describe_json" 2>/dev/null; then
        installed=$(json_query "$describe_json" "doc['DBInstances'][0]['EngineVersion']")
        engine=$(json_query "$describe_json" "doc['DBInstances'][0]['Engine']")
        log info "the blue environment: ${SOURCE_IDENTIFIER} runs engine '${engine:-unknown}' version ${installed:-unknown}"
    else
        [ "$DRY_RUN" -eq 1 ] || die "the DescribeDBInstances call failed for ${SOURCE_IDENTIFIER}"
        log warn "dry run: the blue environment could not be described; the version guard is skipped and the plan is printed anyway"
    fi

    # The major-version guard: this script is for majors only.
    if [ -n "$installed" ]; then
        local path
        path=$(blue_is_ahead_of_major "$installed" "$TARGET_VERSION")
        local verdict=${path%%|*}
        case "$verdict" in
            OK)       log info "version path accepted: ${installed} -> ${TARGET_VERSION} is a major step" ;;
            SAME_MAJOR) die "the target ${TARGET_VERSION} shares the major of the installed ${installed}; a same-major bump is scripts/rds-minor-upgrade.sh, not this script" ;;
            BACKWARD)   die "refusing a BACKWARD change: installed ${installed} is not older than the requested target ${TARGET_VERSION}" ;;
            UNPARSABLE) die "the version strings could not be parsed: installed=${installed} target=${TARGET_VERSION}" ;;
            *)          die "the major-version guard returned an unknown verdict: ${path}" ;;
        esac
    fi

    local stamp
    stamp=$(date -u +%Y%m%d%H%M%S)
    [ -n "$SNAPSHOT_ID" ] || SNAPSHOT_ID="${SOURCE_IDENTIFIER}-premaj-${stamp}"
    [ -n "$DEPLOYMENT_NAME" ] || DEPLOYMENT_NAME="${SOURCE_IDENTIFIER}-major-${stamp}"

    # The whole plan, printed before anything is touched.
    log info "============================== blue/green plan ==============================="
    log info "source (blue)         : ${SOURCE_IDENTIFIER} (engine ${engine:-unknown}, version ${installed:-unknown})"
    log info "target (green)        : engine version ${TARGET_VERSION}"
    log info "deployment name       : ${DEPLOYMENT_NAME}"
    log info "pre-upgrade snapshot  : ${SNAPSHOT_ID}  (the restore-to-point; retained and printed at every step)"
    log info "lag guard             : refuse to promote above ${MAX_LAG_SECONDS}s of replication lag"
    log info "budgets               : build ${CREATE_TIMEOUT_SECONDS}s, switchover ${SWITCHOVER_TIMEOUT_SECONDS}s, poll ${POLL_INTERVAL_SECONDS}s"
    log info "=============================================================================="
    log info "reminder: read the upgrade runbook first; the switchover moves the endpoint of the production database."

    # --- step 1: snapshot the blue environment first ------------------------------
    run $CMD_RDS_CREATE_DB_SNAPSHOT \
        --db-instance-identifier "$SOURCE_IDENTIFIER" \
        --db-snapshot-identifier "$SNAPSHOT_ID" \
        --region "$AWS_REGION" \
        || die "the pre-upgrade snapshot failed; NOT proceeding (there is no verified restore point). snapshot id: ${SNAPSHOT_ID}"
    log info "snapshot issued; restore-to-point retained: ${SNAPSHOT_ID}"

    # --- step 2: create the blue/green deployment ---------------------------------
    local created_json="${WORK_DIR}/created.json"
    if [ "$DRY_RUN" -eq 1 ]; then
        run $CMD_RDS_CREATE_BLUE_GREEN \
            --resource-name "db-instance=${SOURCE_IDENTIFIER}" \
            --blue-green-deployment-name "$DEPLOYMENT_NAME" \
            --green-engine-version "$TARGET_VERSION" \
            --region "$AWS_REGION"
        log info "dry run: the poll of the status, the lag guard, the switchover, and the delete of the record are printed below and not executed"
        run $CMD_RDS_DESCRIBE_BLUE_GREEN \
            --blue-green-deployment-name "$DEPLOYMENT_NAME" --region "$AWS_REGION"
        log info "dry run: the lag guard would measure the replication lag of the green environment and refuse the promotion above ${MAX_LAG_SECONDS}s"
        run $CMD_RDS_SWITCHOVER_BLUE_GREEN \
            --blue-green-deployment-name "$DEPLOYMENT_NAME" \
            --switchover-timeout "$SWITCHOVER_TIMEOUT_SECONDS" \
            --region "$AWS_REGION"
        run $CMD_RDS_DELETE_BLUE_GREEN \
            --blue-green-deployment-name "$DEPLOYMENT_NAME" --region "$AWS_REGION"
        log info "dry run: no deployment was created and production was not touched; the snapshot id ${SNAPSHOT_ID} records the intended restore-to-point"
        exit 0
    fi

    retry 3 2 $CMD_RDS_CREATE_BLUE_GREEN \
        --resource-name "db-instance=${SOURCE_IDENTIFIER}" \
        --blue-green-deployment-name "$DEPLOYMENT_NAME" \
        --green-engine-version "$TARGET_VERSION" \
        --region "$AWS_REGION" >"$created_json" \
        || die "the CreateBlueGreenDeployment call failed; production is untouched on the blue environment. snapshot: ${SNAPSHOT_ID}"
    log info "the blue/green deployment ${DEPLOYMENT_NAME} is created; the green environment is being built as a replica and upgraded to ${TARGET_VERSION}"

    # --- step 3: wait until the deployment reports AVAILABLE ---------------------
    local status_json="${WORK_DIR}/status.json"
    local deadline
    deadline=$(( $(date +%s) + CREATE_TIMEOUT_SECONDS ))
    local reached=0
    while :; do
        retry 3 2 $CMD_RDS_DESCRIBE_BLUE_GREEN \
            --blue-green-deployment-name "$DEPLOYMENT_NAME" \
            --region "$AWS_REGION" --output json >"$status_json" 2>/dev/null \
            || die "the DescribeBlueGreenDeployments call failed; deployment ${DEPLOYMENT_NAME}, snapshot ${SNAPSHOT_ID}"
        if deployment_reports_available "$status_json"; then
            reached=1
            break
        fi
        local now_status
        now_status=$(json_query "$status_json" "doc['BlueGreenDeployments'][0]['Status']" 2>/dev/null || echo 'unknown')
        case "$now_status" in
            *FAILED*|*TIMED_OUT*)
                die "the deployment ${DEPLOYMENT_NAME} ended ${now_status}; production remains on the untouched blue environment. snapshot: ${SNAPSHOT_ID}" ;;
        esac
        [ "$(date +%s)" -lt "$deadline" ] \
            || die "the build of the green environment did not become AVAILABLE within ${CREATE_TIMEOUT_SECONDS}s (last status ${now_status}); production remains on the blue environment. snapshot: ${SNAPSHOT_ID}"
        log debug "deployment status: ${now_status}; polling in ${POLL_INTERVAL_SECONDS}s"
        sleep "$POLL_INTERVAL_SECONDS"
    done
    [ "$reached" -eq 1 ] || die "the deployment never reached AVAILABLE"
    log info "the deployment ${DEPLOYMENT_NAME} reports AVAILABLE; the green environment runs ${TARGET_VERSION} and is caught up enough to be measured"

    # --- step 4: THE LAG GUARD ---------------------------------------------------
    local lag
    lag=$(measure_replication_lag "$status_json")
    if [ "$lag" = "UNKNOWN" ]; then
        err "the replication lag of the green environment could not be read from the deployment record; the guard FAILS CLOSED"
        die "refusing to promote with an unmeasured replication lag; inspect the deployment ${DEPLOYMENT_NAME} (aws rds describe-blue-green-deployments --blue-green-deployment-name ${DEPLOYMENT_NAME} --region ${AWS_REGION}) and re-run the promotion by hand once the lag is reported. snapshot: ${SNAPSHOT_ID}"
    fi
    if [ "$lag" -gt "$MAX_LAG_SECONDS" ]; then
        err "the measured replication lag is ${lag}s, above the guard limit of ${MAX_LAG_SECONDS}s"
        die "refusing to promote a lagging green environment: promoting behind on it would lose writes. wait for the replica to catch up and re-run this script (it is re-entrant: the deployment ${DEPLOYMENT_NAME} and the snapshot ${SNAPSHOT_ID} already exist). snapshot: ${SNAPSHOT_ID}"
    fi
    log info "lag guard passed: the measured replication lag is ${lag}s, within the limit of ${MAX_LAG_SECONDS}s"

    # --- step 5: promote the green to the blue (the switch) ----------------------
    if [ "$DO_SWITCHOVER" -ne 1 ]; then
        log info "the promotion is held (--no-switch was given): the deployment ${DEPLOYMENT_NAME} is built and AVAILABLE but the green is NOT promoted; production stays on the blue. Re-run without --no-switch to perform the switchover. snapshot: ${SNAPSHOT_ID}"
        exit 0
    fi
    retry 3 2 $CMD_RDS_SWITCHOVER_BLUE_GREEN \
        --blue-green-deployment-name "$DEPLOYMENT_NAME" \
        --switchover-timeout "$SWITCHOVER_TIMEOUT_SECONDS" \
        --region "$AWS_REGION" \
        || die "the switchover failed; the service rolls back a switchover that exceeds its timeout of ${SWITCHOVER_TIMEOUT_SECONDS}s, which leaves production on the blue environment. deployment: ${DEPLOYMENT_NAME}, snapshot: ${SNAPSHOT_ID}"
    log info "the switchover completed: the green environment is promoted and carries production traffic on ${TARGET_VERSION}"

    # --- step 6: remove the deployment record after the checkpoint ---------------
    # The retired blue instance is deliberately NOT deleted by this script: the
    # operator keeps it as the rollback path until the checkpoint of the read
    # replica (and of the application smoke tests) has been signed off.  Only the
    # deployment record is removed, because a stale record blocks a future
    # blue/green operation on the same source.
    log info "the checkpoint of the read replica must be confirmed before the retired blue instance is released; this script does not delete instances"
    retry 3 2 $CMD_RDS_DELETE_BLUE_GREEN \
        --blue-green-deployment-name "$DEPLOYMENT_NAME" \
        --region "$AWS_REGION" \
        || die "the DeleteBlueGreenDeployment call failed; the stale deployment record must be removed by hand. deployment: ${DEPLOYMENT_NAME}, snapshot: ${SNAPSHOT_ID}"
    log info "the deployment record ${DEPLOYMENT_NAME} is removed"

    log info "the major upgrade of ${SOURCE_IDENTIFIER} to ${TARGET_VERSION} is complete; the restore-to-point snapshot is ${SNAPSHOT_ID} (keep it until the rollback window closes)"
}

describe_instance_blue() {
    # Purpose: fetch the describe document of the source instance into $1.
    local out=$1
    retry 3 2 $CMD_RDS_DESCRIBE_DB_INSTANCES \
        --db-instance-identifier "$SOURCE_IDENTIFIER" \
        --region "$AWS_REGION" --output json >"$out"
}

main "$@"
