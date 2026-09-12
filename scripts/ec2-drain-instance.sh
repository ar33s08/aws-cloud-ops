#!/usr/bin/env bash
# shellcheck shell=bash
#
# This script drains one EC2 instance out of the rotation of its Auto Scaling
# group before maintenance.  It moves the instance to the Standby lifecycle
# state (the AWS PutInstanceStates call of the Auto Scaling API), which keeps
# the instance registered with the group but removes it from the InService
# count, then polls the health record of the instance until the Auto Scaling
# control plane itself reports the lifecycle state as 'Standby', or the given
# timeout expires.
#
# What a drained instance means, stated plainly for the reader:
#   - The instance leaves the load balancer rotation.  Auto Scaling deregisters
#     a Standby instance from every target group and load balancer attached to
#     the group, so in-flight connections are allowed to drain while new ones
#     are no longer routed to it.
#   - The instance is still managed by the group (it is not detached, not
#     stopped, not terminated), and Auto Scaling will not replace it: the
#     Standby instance still counts toward the desired capacity of the group,
#     so the group does not launch a replacement for the drained host.
#   - Maintenance on a drained instance is reversible: 'aws autoscaling
#     enter-or-exit-standby-for-instances --target-state InService' returns
#     the instance to rotation, which is the rollback plan of this script.
#
# Scope: this script reads and writes exactly one Auto Scaling instance (the
# id passed with -i, in the group passed with -g) in one region.  It never
# reads, prints, or deletes anything else: no other instance, no launch
# template, no scaling policy, no secret, no tag outside its own log line.
#
# Credentials: no credential is read, stored, or printed here.  Access comes
# from the process environment or an AWS profile alone (the standard AWS CLI
# credential chain).
#
# Failure behaviour: any AWS API error aborts at once with the failed command
# and its line number reported by the error trap of the library.  A poll that
# exceeds --timeout exits 1 with the instance left in whatever state the
# control plane reports; the operator inspects and decides, the script never
# auto-rolls-back a drain, because leaving the instance drained is always the
# safe half of the decision.
#
# See also: docs/man/ (man-1 sources), README.md, scripts/lib/common.sh.

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
install_err_trap

# ---------------------------------------------------------------------------
# The blast radius: every AWS API operation this script may call, exactly once
# each, as a named constant.  An auditor can grep this block and see the whole
# reachable surface of the script.
# ---------------------------------------------------------------------------
readonly CMD_ASG_GET_INSTANCE_HEALTH='aws autoscaling describe-instance-health-details'
readonly CMD_ASG_PUT_INSTANCE_STATE='aws autoscaling put-instance-states'
readonly CMD_EC2_DESCRIBE_INSTANCE='aws ec2 describe-instances'

# ---------------------------------------------------------------------------
# Defaults (the safe ones: dry-run off, timeout 300 seconds, poll 5 seconds)
# ---------------------------------------------------------------------------
INSTANCE_ID=''
ASG_NAME=''
TIMEOUT_SECONDS=300
POLL_INTERVAL_SECONDS=5
DRY_RUN=0
AWS_REGION=${AWS_DEFAULT_REGION:-}
AWS_OUTPUT=${AWS_DEFAULT_OUTPUT:-json}

usage() {
    cat <<'USAGE_EOF'
usage: ec2-drain-instance.sh -i INSTANCE-ID -g ASG-NAME [options]

Move one Auto Scaling instance to the Standby lifecycle state and wait until
the Auto Scaling control plane reports it as drained (out of the load balancer
rotation), before you take the instance in for maintenance.

options:
  -i, --instance-id ID     the EC2 instance identifier to drain (required)
  -g, --asg NAME           the name of the Auto Scaling group that owns it
                           (required)
  -t, --timeout SECONDS    how long to wait for the Standby state; the poll
                           stops and fails after this budget (default 300)
  -p, --poll-interval N    the sleep between two health polls, seconds
                           (default 5)
  -r, --region REGION      the AWS region of the group; defaults from the
                           environment AWS_DEFAULT_REGION or AWS_REGION
  -n, --dry-run            print the exact AWS CLI commands, execute nothing
  -h, --help               print this help text and exit 0

exit status:
  0  the instance reports the lifecycle state Standby (drained, out of the
     load balancer rotation)
  1  an AWS call failed, or the Standby state did not arrive before --timeout
  2  the command line was used wrongly
  3  the input (instance id, group name) did not pass validation

example:
  scripts/ec2-drain-instance.sh -i i-0abcdef0123456789 -g prod-web-asg -t 600
  scripts/ec2-drain-instance.sh -i i-0abcdef0123456789 -g prod-web-asg --dry-run

rollback:
  aws autoscaling enter-or-exit-standby-for-instances \
      --instance-ids i-0abcdef0123456789 --target-state InService \
      --auto-scaling-group-name prod-web-asg
USAGE_EOF
}

# ---------------------------------------------------------------------------
# Command line: bash 3.2 cannot pass long options to getopts, so the parser is
# an explicit while/case loop over "$@" -- the documented convention of this
# layer.
# ---------------------------------------------------------------------------
parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -i|--instance-id) [ "$#" -ge 2 ] || usage_error "$1 needs a value"; INSTANCE_ID=$2; shift 2;;
            -g|--asg|--asg-name|--group) [ "$#" -ge 2 ] || usage_error "$1 needs a value"; ASG_NAME=$2; shift 2;;
            -t|--timeout)     [ "$#" -ge 2 ] || usage_error "$1 needs a value"; TIMEOUT_SECONDS=$2; shift 2;;
            -p|--poll-interval) [ "$#" -ge 2 ] || usage_error "$1 needs a value"; POLL_INTERVAL_SECONDS=$2; shift 2;;
            -r|--region)      [ "$#" -ge 2 ] || usage_error "$1 needs a value"; AWS_REGION=$2; shift 2;;
            -n|--dry-run)     DRY_RUN=1; shift;;
            -h|--help)        usage; exit 0;;
            --) shift;;
            *)  usage_error "unknown option: $1";;
        esac
    done
}

validate_args() {
    [ -n "$INSTANCE_ID" ] || usage_error '--instance-id (-i) is required'
    [ -n "$ASG_NAME" ]    || usage_error '--asg (-g) is required'
    [[ $INSTANCE_ID =~ ^i-[0-9a-f]{8,21}$ ]] \
        || die "instance id does not look like an EC2 identifier: ${INSTANCE_ID}"
    [[ $ASG_NAME =~ ^[0-9a-zA-Z._/-]+$ ]] \
        || die "Auto Scaling group name contains characters outside the allowed set: ${ASG_NAME}"
    [[ $TIMEOUT_SECONDS =~ ^[0-9]+$ ]] && [ "$TIMEOUT_SECONDS" -ge 10 ] \
        || usage_error "--timeout must be an integer of at least 10 seconds"
    [[ $POLL_INTERVAL_SECONDS =~ ^[0-9]+$ ]] && [ "$POLL_INTERVAL_SECONDS" -ge 1 ] \
        || usage_error "--poll-interval must be a positive integer"
    [ -n "$AWS_REGION" ] || die "no region: pass --region, or export AWS_DEFAULT_REGION / AWS_REGION"
}

# ---------------------------------------------------------------------------
# The poll predicate: does the control plane report this instance as Standby?
# json_query (the python core) reads the health document, never jq.
# ---------------------------------------------------------------------------
health_json_file=''

health_reports_standby() {
    # Purpose: the predicate passed to poll_until.  Succeeds when the
    # DescribeInstanceHealthDetails record for the instance carries the
    # lifecycle state 'Standby'.
    # Returns: 0 when Standby is reported, 1 otherwise (including a poll that
    # itself failed -- poll_until treats every non-zero as 'not yet').
    local state
    state=$(json_query "$health_json_file" "doc['InstanceHealthDetails'][0]['LifecycleState']") || return 1
    [ "$state" = "Standby" ]
}

refresh_health() {
    # Purpose: fetch the health document of the instance into the scratch file.
    local out
    out=$(mktemp -t asg-health-XXXXXX.json)
    retry 3 2 $CMD_ASG_GET_INSTANCE_HEALTH \
        --instance-id "$INSTANCE_ID" \
        --auto-scaling-group-name "$ASG_NAME" \
        --region "$AWS_REGION" \
        --output "$AWS_OUTPUT" >"$out"
    printf '%s\n' "$out"
}

main() {
    parse_args "$@"
    validate_args
    require_cmd aws python3

    log info "drain plan: instance ${INSTANCE_ID} of group ${ASG_NAME} in region ${AWS_REGION}: put to Standby, poll until the control plane reports 'Standby', budget ${TIMEOUT_SECONDS}s"
    log info "reminder: a drained (Standby) instance leaves the load balancer rotation and is removed from the InService count; connections drain; Auto Scaling will not replace it"

    # Step 1 -- put the instance to Standby.  PutInstanceStates is the current
    # API for the lifecycle states; run() prints it verbatim in --dry-run.
    run $CMD_ASG_PUT_INSTANCE_STATE \
        --instance-states "InstanceId=${INSTANCE_ID},LifecycleState=Standby" \
        --region "$AWS_REGION" || die "the PutInstanceStates call failed; the instance was not drained"

    if [ "$DRY_RUN" -eq 1 ]; then
        log info "dry run: no health poll executed; in a live run the script would now poll DescribeInstanceHealthDetails every ${POLL_INTERVAL_SECONDS}s for up to ${TIMEOUT_SECONDS}s until LifecycleState reports 'Standby'"
        log info "dry run: complete -- nothing was changed"
        exit 0
    fi

    # Step 2 -- wait for the control plane to agree.  The predicate re-reads a
    # fresh health document on every pass, so the poll sees the propagation.
    local start now elapsed
    start=$(date +%s)
    while :; do
        health_json_file=$(refresh_health)
        if health_reports_standby; then
            now=$(date +%s); elapsed=$((now - start))
            log info "instance ${INSTANCE_ID} reports lifecycle state Standby after ${elapsed}s -- drained and out of the load balancer rotation; safe to take it in for maintenance"
            rm -f -- "$health_json_file"
            exit 0
        fi
        now=$(date +%s)
        if [ $((now - start)) -ge "$TIMEOUT_SECONDS" ]; then
            err "instance ${INSTANCE_ID} did not report 'Standby' within ${TIMEOUT_SECONDS}s (last observed state: $(json_query "$health_json_file" "doc['InstanceHealthDetails'][0]['LifecycleState']" 2>/dev/null || echo '<unknown>'))"
            err "the instance may still carry traffic; do not start maintenance; to return it to rotation: aws autoscaling enter-or-exit-standby-for-instances --instance-ids ${INSTANCE_ID} --target-state InService --auto-scaling-group-name ${ASG_NAME} --region ${AWS_REGION}"
            rm -f -- "$health_json_file"
            exit 1
        fi
        log debug "not yet Standby; sleeping ${POLL_INTERVAL_SECONDS}s"
        sleep "$POLL_INTERVAL_SECONDS"
    done
}

main "$@"
