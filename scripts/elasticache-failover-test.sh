#!/usr/bin/env bash
# shellcheck shell=bash
#
# This script tests the automatic failover of one replication group of Amazon
# ElastiCache by asking the service to fail it over deliberately
# ('aws elasticache test-failover'), then measuring how long the group spends
# out of its 'available' state, and reporting the measured failover time.  It
# is the scheduled drill of the cache tier: a failover that has never been
# measured is a failover whose cost nobody knows, and an unmeasured failover is
# what turns an incident review into an archaeology project.
#
# The acceptable downtime of a MULTI-AZ replication group, stated plainly:
#   - A Multi-AZ replication group with automatic failover enabled carries its
#     reads and writes on more than one availability zone.  When the primary
#     node fails -- or when this script asks the service to fail it over -- the
#     service promotes a read replica to primary and repoints the primary
#     endpoint.
#   - The client-visible cost of that promotion is a short unavailability of
#     the endpoint while DNS and the endpoint move: measure it in seconds, in
#     the low tens of seconds for a healthy group, with a single-digit number
#     of seconds of connection reset on the clients.  It is NOT zero: clients
#     see a blip, and the connection poolers must reconnect.
#   - The design target of this estate is the default --max-downtime of this
#     script, in seconds: a failover measured above it either means the group
#     is not Multi-AZ with automatic failover, or that the promotion is not
#     behaving, and the drill has found a real problem.  A single-AZ group has
#     no failover target at all and fails the drill by design.
#
# How the measurement works: the script records the wall clock immediately
# before the test-failover call, polls the status of the replication group until
# it is 'available' again, records the clock, and reports the difference as the
# measured failover time.  The reported number is an upper bound of the true
# blip -- it includes the poll interval -- so the poll interval is deliberately
# short and is printed with the result.
#
# Scope: this script reads and affects exactly one ElastiCache replication
# group identifier, in one region.  It never creates, modifies, or deletes a
# cache resource; it never reads or prints a secret.  Credentials come from the
# process environment or an AWS profile only.
#
# Failure behaviour: a group that does not return to 'available' within
# --timeout exits 1 and the group is reported by name so that the operator can
# escalate; a failover that returns late -- above --max-downtime -- also exits
# 1, with the measured figure in the log line; a missing group or a wrong
# command line exits 1 / 2 respectively.
#
# See also: docs/man/, README.md, scripts/rds-minor-upgrade.sh (the sibling
# database drill), infra/modules/elasticache (the Multi-AZ definition).

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
install_err_trap

# ---------------------------------------------------------------------------
# The blast radius: every AWS API operation this script may call, exactly once
# each, as a named constant.
# ---------------------------------------------------------------------------
readonly CMD_ELASTICACHE_DESCREPLICATION='aws elasticache describe-replication-groups'
readonly CMD_ELASTICACHE_TEST_FAILOVER='aws elasticache test-failover'

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
REPLICATION_GROUP_ID=''
MAX_DOWNTIME_SECONDS=60       # the design target of the drill
TIMEOUT_SECONDS=900           # the wall budget of the wait for 'available'
POLL_INTERVAL_SECONDS=5
DRY_RUN=0
AWS_REGION=${AWS_DEFAULT_REGION:-}
WORK_DIR=''

usage() {
    cat <<'USAGE_EOF'
usage: elasticache-failover-test.sh --replication-group-id ID [options]

Trigger the automatic failover of an ElastiCache replication group, wait until
the group is 'available' again, measure the failover time, and fail the drill
when the measured time exceeds --max-downtime.

A Multi-AZ replication group with automatic failover is expected to blip its
endpoint for seconds (a low, single- to double-digit number), not minutes: the
promotion of a read replica to primary and the repoint of the primary endpoint
happens in that window, and clients see a short reset.  A failover that takes
longer than --max-downtime is the finding this drill exists to catch.

options:
  --replication-group-id ID   the ElastiCache replication group to test
                              (required)
  --max-downtime SECONDS      the acceptable client-visible downtime; the
                              drill fails above it (default 60)
  --timeout SECONDS           the wall budget of the wait for 'available'
                              (default 900)
  --poll-interval N           seconds between two status polls (default 5)
  -r, --region REGION         the AWS region; defaults from AWS_DEFAULT_REGION
                              or AWS_REGION
  -n, --dry-run               print the aws cli commands, execute nothing
  -h, --help                  print this help text and exit 0

exit status:
  0  the failover completed within --max-downtime seconds
  1  the measured failover exceeded --max-downtime, or the group did not
     become available within --timeout, or an AWS call failed
  2  the command line was used wrongly

example:
  scripts/elasticache-failover-test.sh --replication-group-id cache-prod-01 --dry-run
  scripts/elasticache-failover-test.sh --replication-group-id cache-prod-01 --max-downtime 45
USAGE_EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --replication-group-id) [ "$#" -ge 2 ] || usage_error "$1 needs a value"; REPLICATION_GROUP_ID=$2; shift 2;;
            --max-downtime)         [ "$#" -ge 2 ] || usage_error "$1 needs a value"; MAX_DOWNTIME_SECONDS=$2; shift 2;;
            --timeout)              [ "$#" -ge 2 ] || usage_error "$1 needs a value"; TIMEOUT_SECONDS=$2; shift 2;;
            --poll-interval)        [ "$#" -ge 2 ] || usage_error "$1 needs a value"; POLL_INTERVAL_SECONDS=$2; shift 2;;
            -r|--region)            [ "$#" -ge 2 ] || usage_error "$1 needs a value"; AWS_REGION=$2; shift 2;;
            -n|--dry-run)           DRY_RUN=1; shift;;
            -h|--help)              usage; exit 0;;
            --) shift;;
            *)  usage_error "unknown option: $1";;
        esac
    done
}

group_state_is_available() {
    # Purpose: the poll predicate -- the group reports the status 'available'.
    # Returns: 0 when available, 1 otherwise (a failed fetch reads as 'not
    # yet' so that a transient API fault does not abort the measurement).
    local file=$1
    local state
    state=$(json_query "$file" "doc['ReplicationGroups'][0]['GlobalReplicationGroupDetails']['GlobalReplicationGroupMember'] is None and doc['ReplicationGroups'][0]['GlobalReplicationGroupDetails']" 2>/dev/null || true)
    state=$(json_query "$file" "doc['ReplicationGroups'][0]['ReplicationGroupStatus']" 2>/dev/null) \
        || state=$(json_query "$file" "doc['ReplicationGroups'][0]['GlobalReplicationGroupDetails']['GlobalReplicationGroupMember']['ReplicationGroupStatus']" 2>/dev/null) \
        || return 1
    case "$state" in
        available|Available|AVAILABLE) return 0;;
        *) log debug "replication group status: ${state}"; return 1;;
    esac
}

describe_group() {
    # Purpose: fetch the describe document of the group into $1.
    local out=$1
    retry 3 2 "$CMD_ELASTICACHE_DESCREPLICATION" \
        --replication-group-id "$REPLICATION_GROUP_ID" \
        --show-global-replication-groups \
        --region "$AWS_REGION" --output json >"$out"
}

main() {
    parse_args "$@"
    [ -n "$REPLICATION_GROUP_ID" ] || usage_error '--replication-group-id is required'
    [ -n "$AWS_REGION" ] || die "no region: pass --region, or export AWS_DEFAULT_REGION / AWS_REGION"
    [[ $REPLICATION_GROUP_ID =~ ^[0-9a-zA-Z][-_0-9a-zA-Z]{0,39}$ ]] || die "the replication group id is not a valid ElastiCache identifier: ${REPLICATION_GROUP_ID}"
    [[ $MAX_DOWNTIME_SECONDS =~ ^[0-9]+$ ]] && [ "$MAX_DOWNTIME_SECONDS" -ge 1 ] || usage_error "--max-downtime must be a positive integer"
    [[ $TIMEOUT_SECONDS =~ ^[0-9]+$ ]] && [ "$TIMEOUT_SECONDS" -ge 30 ] || usage_error "--timeout must be an integer of at least 30 seconds"
    [[ $POLL_INTERVAL_SECONDS =~ ^[0-9]+$ ]] && [ "$POLL_INTERVAL_SECONDS" -ge 1 ] || usage_error "--poll-interval must be a positive integer"
    require_cmd aws python3

    WORK_DIR=$(mktemp -d -t elc-failover-XXXXXX)
    trap '[ -n "$WORK_DIR" ] && rm -rf -- "$WORK_DIR"' EXIT

    # The precondition check: the group must exist and must report a Multi-AZ
    # automatic failover, or the drill measures something that will not save the
    # cache tier.
    local pre_json="${WORK_DIR}/pre.json"
    if ! describe_group "$pre_json"; then
        [ "$DRY_RUN" -eq 1 ] || die "the DescribeReplicationGroups call failed for ${REPLICATION_GROUP_ID}"
        log warn "dry run: the group could not be described; the plan is printed without the precondition check"
    elif [ -s "$pre_json" ]; then
        local multi_az auto_failover
        multi_az=$(json_query "$pre_json" "doc['ReplicationGroups'][0]['MultiAZEnabled']")
        auto_failover=$(json_query "$pre_json" "doc['ReplicationGroups'][0]['AutomaticFailoverEnabled']")
        log info "preconditions of ${REPLICATION_GROUP_ID}: Multi-AZ ${multi_az:-unknown}, automatic failover ${auto_failover:-unknown}"
        if [ "${multi_az:-false}" != "true" ]; then
            err "the group ${REPLICATION_GROUP_ID} is not Multi-AZ enabled: there is no standby to promote and the drill will measure a real outage"
            [ "$DRY_RUN" -eq 1 ] || die "a single-AZ group has no failover target; enable Multi-AZ and automatic failover before you test failover"
            log warn "dry run: the drill would have failed on the precondition; continuing to print the commands"
        fi
        if [ "${auto_failover:-false}" != "true" ]; then
            err "automatic failover is not enabled on ${REPLICATION_GROUP_ID}: test-failover will not promote a replica automatically"
            [ "$DRY_RUN" -eq 1 ] || die "enable AutomaticFailoverEnabled before you test failover"
            log warn "dry run: the drill would have failed on the precondition; continuing to print the commands"
        fi
    fi

    log info "failover drill of ${REPLICATION_GROUP_ID}: triggering the failover, then waiting for the status 'available' (budget ${TIMEOUT_SECONDS}s, poll ${POLL_INTERVAL_SECONDS}s); the acceptable client-visible downtime is ${MAX_DOWNTIME_SECONDS}s"

    # Trigger the failover and stamp the clock around it.
    local started_at
    started_at=$(date +%s)
    if ! run $CMD_ELASTICACHE_TEST_FAILOVER \
            --replication-group-id "$REPLICATION_GROUP_ID" \
            --region "$AWS_REGION"; then
        die "the TestFailover call failed"
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        log info "dry run: the status poll would follow -- every ${POLL_INTERVAL_SECONDS}s the script runs: aws elasticache describe-replication-groups --replication-group-id ${REPLICATION_GROUP_ID} --region ${AWS_REGION} --output json --query ReplicationGroups[0].ReplicationGroupStatus -- until it reads 'available', then it reports the measured failover time and fails it above ${MAX_DOWNTIME_SECONDS}s"
        log info "dry run: nothing was triggered"
        exit 0
    fi

    # Wait for the group to be available again and measure the elapsed time.
    local failover_seconds=0
    if poll_until "replication group ${REPLICATION_GROUP_ID} to report 'available'" \
            "$TIMEOUT_SECONDS" "$POLL_INTERVAL_SECONDS" \
            _poll_available; then
        local finished_at
        finished_at=$(date +%s)
        failover_seconds=$((finished_at - started_at))
    else
        local late_at
        late_at=$(date +%s)
        err "the replication group ${REPLICATION_GROUP_ID} did not report 'available' within ${TIMEOUT_SECONDS}s (still unavailable after $((late_at - started_at))s)"
        err "escalate per the incident runbook: the group name is the object of the escalation; do not run the drill again while it is unavailable"
        die "the failover did not complete; the cache tier may be impaired"
    fi

    # Report the result and apply the verdict.
    log info "measured failover time of ${REPLICATION_GROUP_ID}: ${failover_seconds}s (an upper bound: it includes a poll interval of ${POLL_INTERVAL_SECONDS}s); acceptable is ${MAX_DOWNTIME_SECONDS}s"
    printf 'REPLICATION_GROUP\tMEASURED_SECONDS\tLIMIT_SECONDS\tRESULT\n%s\t%s\t%s\t%s\n' \
        "$REPLICATION_GROUP_ID" "$failover_seconds" "$MAX_DOWNTIME_SECONDS" \
        "$([ "$failover_seconds" -le "$MAX_DOWNTIME_SECONDS" ] && echo PASS || echo FAIL)"

    if [ "$failover_seconds" -gt "$MAX_DOWNTIME_SECONDS" ]; then
        err "the measured failover time ${failover_seconds}s exceeds the acceptable downtime ${MAX_DOWNTIME_SECONDS}s of a Multi-AZ replication group"
        err "inspect the group and the node failover parameters: ${REPLICATION_GROUP_ID} -- aws elasticache describe-events --source-type replication-group --source-id ${REPLICATION_GROUP_ID} --region ${AWS_REGION}"
        die "the failover drill FAILED: the group is slower to promote than the design target"
    fi
    log info "the failover drill PASSED: ${REPLICATION_GROUP_ID} promotes within the acceptable downtime"
}

_poll_available() {
    # Purpose: the poll_until predicate body -- fetch, then test availability.
    local file="${WORK_DIR}/poll-current.json"
    describe_group "$file" 2>/dev/null || return 1
    group_state_is_available "$file"
}

main "$@"
