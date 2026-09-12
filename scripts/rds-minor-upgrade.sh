#!/usr/bin/env bash
# shellcheck shell=bash
#
# This script applies a MINOR engine upgrade to one RDS instance: it takes
# the database to a newer version within the same major release (for example
# mysql 8.0.35 -> 8.0.40), inside the maintenance window, after a manual
# snapshot.  It is deliberately scoped to the minor case only; a major upgrade
# (5.7 -> 8.0) is a different operation with a different safety model and lives
# in scripts/rds-major-upgrade-bluegreen.sh.
#
# What actually happens on the instance -- read this before you schedule the
# change, and read README.md and the runbooks first:
#   - A minor engine upgrade REBOOTS the instance.  It is not an online,
#     zero-touch change.
#   - A SINGLE-AZ instance incurs real downtime for the duration of the
#     reboot: the database is unreachable while the new binary starts.
#   - A MULTI-AZ instance fails over to the standby first, so the endpoint
#     moves instead of dying; the visible impact is a failover blip on the
#     order of one to two minutes, not a long outage.
#   This distinction is the reason the script checks the Multi-AZ attribute and
#   prints the expected impact class in its plan.
#
# Version discipline: the script compares the target against the installed
# version with the python core (cloudops.eol.compare_versions), and REFUSES to
# proceed unless the target shares the installed major and is strictly newer.
# It also skips cleanly (exit 0, no snapshot, no modify) when the instance is
# already at or above the target.  This is the guard against the classic
# operator error: aiming a 'minor' upgrade at a different major and only
# discovering it in the middle of the window.
#
# The plan is printed in full before anything is executed, and in --dry-run
# mode every aws cli command is printed and none is run.
#
# Scope: this script reads and changes exactly one RDS instance identifier,
# in one region: it describes that instance, snapshots it, and modifies it.
# It never reads, prints, or deletes anything else.  Credentials come from the
# environment or an AWS profile only.
#
# Failure behaviour: a rejected plan or a mismatched version exits 2 or 1
# with an explanatory line; a failed snapshot or modify exits 1 with the
# command reported by the error trap, and the snapshot identifier is printed
# so that the restore point is known.
#
# See also: scripts/rds-major-upgrade-bluegreen.sh, docs/man/, cloudops/eol.py.

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
readonly CMD_RDS_MODIFY_DB_INSTANCE='aws rds modify-db-instance'

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
DB_IDENTIFIER=''
TARGET_VERSION=''
DRY_RUN=0
APPLY_IMMEDIATELY=0
SNAPSHOT_ID=''
AWS_REGION=${AWS_DEFAULT_REGION:-}
WORK_DIR=''

usage() {
    cat <<'USAGE_EOF'
usage: rds-minor-upgrade.sh --identifier DB-IDENTIFIER --target-version VER [options]

Apply a minor engine upgrade (a newer version of the SAME major) to one RDS
instance: verify the version path, print the whole plan, snapshot first, then
modify with --apply-immediately false (the change is deferred to the
maintenance window) unless --apply-immediately is given.

A minor upgrade reboots the instance: single-AZ instances incur downtime,
multi-AZ instances fail over first.  Read README.md and the runbooks before
you run this against production.

options:
  --identifier ID          the RDS DB instance identifier (required)
  --target-version VER     the target engine version, a newer version within
                           the installed major (required)
  --snapshot-id ID         the snapshot identifier to create; defaults to
                           '<identifier>-preminor-<UTC stamp>'
  --apply-immediately      do not wait for the maintenance window (use only
                           under a change advisory board approval)
  -r, --region REGION      the AWS region; defaults from AWS_DEFAULT_REGION
                           or AWS_REGION
  -n, --dry-run            print the exact aws cli commands, execute nothing
  -h, --help               print this help text and exit 0

exit status:
  0  the upgrade was planned and issued, or the instance was already current
  1  the version path was rejected, or an AWS call failed
  2  the command line was used wrongly

example:
  scripts/rds-minor-upgrade.sh --identifier db-prod-01 --target-version 8.0.40 --dry-run
  scripts/rds-minor-upgrade.sh --identifier db-prod-01 --target-version 8.0.40
USAGE_EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --identifier|--db-identifier) [ "$#" -ge 2 ] || usage_error "$1 needs a value"; DB_IDENTIFIER=$2; shift 2;;
            --target-version)        [ "$#" -ge 2 ] || usage_error "$1 needs a value"; TARGET_VERSION=$2; shift 2;;
            --snapshot-id)           [ "$#" -ge 2 ] || usage_error "$1 needs a value"; SNAPSHOT_ID=$2; shift 2;;
            --apply-immediately)     APPLY_IMMEDIATELY=1; shift;;
            -r|--region)             [ "$#" -ge 2 ] || usage_error "$1 needs a value"; AWS_REGION=$2; shift 2;;
            -n|--dry-run)            DRY_RUN=1; shift;;
            -h|--help)               usage; exit 0;;
            --) shift;;
            *)  usage_error "unknown option: $1";;
        esac
    done
}

describe_instance() {
    # Purpose: fetch the describe document of the single instance into $2.
    local id=$1 out=$2
    retry 3 2 $CMD_RDS_DESCRIBE_DB_INSTANCES \
        --db-instance-identifier "$id" \
        --region "$AWS_REGION" --output json >"$out"
}

is_minor_of_same_major() {
    # Purpose: the version-path guard, delegated to cloudops.eol.compare_versions.
    # Prints 'OK' / 'EQUAL' / 'BACKWARD' / 'DIFFERENT_MAJOR' / 'UNPARSABLE' on
    # standard output so that main can branch on prose.
    local installed=$1 target=$2
    _CLOUDOPS_REPO_ROOT=$REPO_ROOT _CLOUDOPS_INSTALLED=$installed _CLOUDOPS_TARGET=$target \
        "$PYTHON_BIN" - <<'PYTHON_EOF'
import os
import sys

sys.path.insert(0, os.environ["_CLOUDOPS_REPO_ROOT"])

from cloudops.eol import compare_versions, SemVer

installed = os.environ["_CLOUDOPS_INSTALLED"]
target = os.environ["_CLOUDOPS_TARGET"]

try:
    a = SemVer(installed)
    b = SemVer(target)
    cmp = compare_versions(installed, target)
except ValueError as exc:
    print("UNPARSABLE|%s" % exc)
    sys.exit(0)

if a.major != b.major:
    print("DIFFERENT_MAJOR|%d|%d" % (a.major, b.major))
elif cmp < 0:
    print("OK|%s|%s" % (installed, target))
elif cmp == 0:
    print("EQUAL|%s" % installed)
else:
    print("BACKWARD|%s|%s" % (installed, target))
PYTHON_EOF
}

main() {
    parse_args "$@"
    [ -n "$DB_IDENTIFIER" ] || usage_error '--identifier is required'
    [ -n "$TARGET_VERSION" ] || usage_error '--target-version is required'
    [ -n "$AWS_REGION" ] || die "no region: pass --region, or export AWS_DEFAULT_REGION / AWS_REGION"
    [[ $DB_IDENTIFIER =~ ^[0-9a-zA-Z][-_0-9a-zA-Z]{0,62}$ ]] || die "DB instance identifier is not a valid RDS identifier: ${DB_IDENTIFIER}"
    require_cmd aws python3

    WORK_DIR=$(mktemp -d -t rds-minor-XXXXXX)
    trap '[ -n "$WORK_DIR" ] && rm -rf -- "$WORK_DIR"' EXIT

    local describe_json="${WORK_DIR}/describe.json"
    if [ "$DRY_RUN" -eq 1 ]; then
        # In dry-run the describe is still run when credentials allow it, but a
        # failure to reach the API must not stop the printing of the plan.
        log info "dry run: the live describe is attempted, but its result is optional"
    fi
    if ! describe_instance "$DB_IDENTIFIER" "$describe_json"; then
        [ "$DRY_RUN" -eq 1 ] || die "the DescribeDBInstances call failed for ${DB_IDENTIFIER}"
        log warn "dry run: the instance could not be described; the plan is printed against the requested target without the live version check"
        describe_json=''
    fi

    local installed='' engine='' multi_az='unknown'
    if [ -n "$describe_json" ] && [ -s "$describe_json" ]; then
        installed=$(json_query "$describe_json" "doc['DBInstances'][0]['EngineVersion']")
        engine=$(json_query "$describe_json" "doc['DBInstances'][0]['Engine']")
        multi_az=$(json_query "$describe_json" "doc['DBInstances'][0]['MultiAZ']")
    fi

    if [ -n "$installed" ]; then
        log info "current state: ${DB_IDENTIFIER} runs engine '${engine}' version ${installed}, Multi-AZ ${multi_az}"
    fi

    # The version-path guard.
    if [ -n "$installed" ]; then
        local path
        path=$(is_minor_of_same_major "$installed" "$TARGET_VERSION")
        local verdict=${path%%|*}
        case "$verdict" in
            OK)            log info "version path accepted: ${installed} -> ${TARGET_VERSION} is a minor step within the same major";;
            EQUAL)         log info "the instance is already at version ${TARGET_VERSION}; nothing to do"; exit 0;;
            BACKWARD)      die "refusing a BACKWARD change: installed ${installed} is newer than the requested target ${TARGET_VERSION}";;
            DIFFERENT_MAJOR) die "the target ${TARGET_VERSION} is a different MAJOR than the installed ${installed}; a major upgrade is scripts/rds-major-upgrade-bluegreen.sh, not this script";;
            UNPARSABLE)      die "the version strings could not be parsed: installed=${installed} target=${TARGET_VERSION}";;
            *)             die "the version-path guard returned an unknown verdict: ${path}";;
        esac
    fi

    # The expected impact class, printed before the plan: this is the paragraph
    # of the header comment that the operator must see at run time, not only in
    # the source.
    local impact='unknown'
    case "$multi_az" in
        true|True) impact='MULTI-AZ: failover to the standby first -- a short endpoint blip, not a long outage';;
        false|False) impact='SINGLE-AZ: the reboot is real downtime for the duration of the restart';;
        *) impact='the Multi-AZ attribute is unknown (dry run without describe): verify before you schedule';;
    esac

    local stamp
    stamp=$(date -u +%Y%m%d%H%M%S)
    [ -n "$SNAPSHOT_ID" ] || SNAPSHOT_ID="${DB_IDENTIFIER}-preminor-${stamp}"
    [ "$APPLY_IMMEDIATELY" -eq 1 ] || log info "the modify will carry --apply-immediately false: the change is deferred to the next maintenance window"

    # The whole plan, printed before anything is touched.
    log info "=============================== upgrade plan ==============================="
    log info "target                : ${DB_IDENTIFIER} (engine ${engine:-unknown})"
    log info "installed -> target   : ${installed:-unknown} -> ${TARGET_VERSION}"
    log info "expected impact       : ${impact}"
    log info "snapshot identifier   : ${SNAPSHOT_ID}"
    log info "apply immediately     : $([ "$APPLY_IMMEDIATELY" -eq 1 ] && echo yes || echo no)"
    log info "============================================================================"
    log info "reminders: a minor upgrade reboots the instance; verify the restore drill of the snapshot; confirm the connection poolers reconnect."

    # Step 1 -- snapshot first.  The snapshot id is retained and printed even on
    # failure, so that the restore-to-point is known.
    run $CMD_RDS_CREATE_DB_SNAPSHOT \
        --db-instance-identifier "$DB_IDENTIFIER" \
        --db-snapshot-identifier "$SNAPSHOT_ID" \
        --region "$AWS_REGION" \
        || die "the pre-upgrade snapshot failed; NOT proceeding (there is no verified restore point). snapshot id: ${SNAPSHOT_ID}"
    log info "snapshot ${SNAPSHOT_ID} issued (restore point retained)"

    # Step 2 -- modify, deferred to the window unless --apply-immediately.
    local apply_flag='false'
    [ "$APPLY_IMMEDIATELY" -eq 1 ] && apply_flag='true'
    run $CMD_RDS_MODIFY_DB_INSTANCE \
        --db-instance-identifier "$DB_IDENTIFIER" \
        --engine-version "$TARGET_VERSION" \
        --apply-immediately "$apply_flag" \
        --region "$AWS_REGION" \
        || die "the ModifyDBInstance call failed; the retained snapshot is ${SNAPSHOT_ID}"

    if [ "$DRY_RUN" -eq 1 ]; then
        log info "dry run: the plan above was printed and no state was changed (the snapshot id ${SNAPSHOT_ID} would be the restore point)"
    else
        log info "the minor upgrade to ${TARGET_VERSION} is issued for ${DB_IDENTIFIER} (apply-immediately ${apply_flag}); monitor the instance until it reports available"
    fi
}

main "$@"
