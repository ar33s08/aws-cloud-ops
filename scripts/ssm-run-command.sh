#!/usr/bin/env bash
# shellcheck shell=bash
#
# This script runs a command document across a fleet of managed instances via
# AWS Systems Manager Run Command ('aws ssm send-command') and waits for every
# invocation on every target to reach its terminal state.  It is the patching
# and maintenance work-horse of the estate: one documented, auditable call path
# for 'run this command on these instances', replacing the ad-hoc loops that
# make fleet changes unauditable.
#
# Target selection takes one of two forms, never both:
#   --targets i-0a,i-0b            an explicit list of instance identifiers
#   --tag-list Key=Environment,Value=prod
#                                  a resource tag selector, expanded by SSM
#                                  itself over the registered fleet
#
# The document defaults to the public AWS-RunShellScript document (the real SSM
# document name; the placeholder name 'AWS-Run-Document-Shell-Distribution' from
# early drafts is not a valid document and is rejected on purpose), but any
# account-internal document id is accepted via --document-id.
#
# Command parameters are passed through: --parameters takes the parameter
# string of the document in the documented form
#   --parameters 'comments=motivation runcommand=...'
# which is translated into the '--parameters Name=comments,...,Name=runcommand,...'
# shape of the CLI.  For anything non-trivial, keep the shell command in a file
# and pass it with --command-file: the script reads the file and hands its
# content over as the runcommand parameter, so the command text needs no
# shell-quoting acrobatics.
#
# Failure behaviour: each invocation status is printed when it reaches a
# terminal state; the script aggregates and prints a summary table of
# target/status/exit-code at the end, and exits 1 when any command failed on
# any target.  Transient API failures are retried with exponential backoff (the
# retry() of the library).
#
# Scope: this script may run a command on the instances named by --targets or
# matched by --tag-list in one region, and reads nothing else: no other
# instance, no SSM parameter store value, no document content beyond the
# document id, no secret.  Credentials come from the environment or an AWS
# profile alone.
#
# See also: scripts/lib/common.sh, README.md ('Automation'), OPERATIONS.md.

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
install_err_trap

# ---------------------------------------------------------------------------
# The blast radius: every AWS API operation this script may call, exactly once
# each, as a named constant.
# ---------------------------------------------------------------------------
readonly CMD_SSM_SEND_COMMAND='aws ssm send-command'
readonly CMD_SSM_LIST_INVOCATIONS='aws ssm list-commands-invocations'
readonly CMD_SSM_GET_INVOCATION='aws ssm get-command-invocation'

# ---------------------------------------------------------------------------
# Defaults.
# ---------------------------------------------------------------------------
TARGETS=''                    # comma-separated instance ids, or empty
TAG_LIST=''                   # SSM tag selector, or empty
PARSING_PARAMETERS=''         # the raw 'key=value key2=value2' string
DOCUMENT_ID='AWS-RunShellScript'
# The document version string is a literal: the service understands the dollar
# form below as 'the latest version', so the shell must not expand it.
DOCUMENT_VERSION='$DEFAULT'   # the literal string SSM understands as 'latest'
COMMAND_FILE=''               # path whose content becomes the runcommand value
TIMEOUT_SECONDS=600           # the per-invocation execution timeout (SSM side)
RETRIES=3                     # API-call retries, with exponential backoff
POLL_INTERVAL_SECONDS=5       # seconds between two status polls
MAX_POLL_SECONDS=1800         # the wall budget of the wait phase
DRY_RUN=0
AWS_REGION=${AWS_DEFAULT_REGION:-}
# This script consumes the API with the python core; the output format is
# fixed at 'json' on purpose, independent of any AWS_DEFAULT_OUTPUT the human
# session may prefer.
AWS_OUTPUT='json'

usage() {
    cat <<'USAGE_EOF'
usage: ssm-run-command.sh (--targets i-0a,i-0b | --tag-list Key=Env,Value=prod)
                          [options]

Send an SSM Run Command document to a fleet, wait until every invocation has
reached a terminal state, print each invocation status, print a summary table,
and exit 1 when any command failed on any target.

options:
  --targets LIST           comma-separated EC2 instance identifiers to target
  --tag-list SELECTOR      SSM tag selector, e.g. Key=Environment,Value=prod;
                           mutually exclusive with --targets
  --document-id ID         the SSM document to run (default AWS-RunShellScript)
  --document-version VER   the document version (default '$DEFAULT' = latest)
  --parameters STRING      document parameters in 'key=value key2=value2' form;
                           for AWS-RunShellScript the recognised keys are
                           'comments' and 'runcommand'
  --command-file PATH      read the shell script to run from this file
                           (overrides any runcommand=... in --parameters)
  --timeout SECONDS        the per-invocation execution timeout handed to the
                           document itself (default 600)
  --retries N              attempts per transient API failure, exponential
                           backoff between them (default 3)
  --poll-interval N        seconds between two status polls (default 5)
  --max-wait SECONDS       the total wall budget of the wait phase (default
                           1800; invocations still pending at expiry fail the
                           run)
  -r, --region REGION      the AWS region; defaults from AWS_DEFAULT_REGION
                           or AWS_REGION
  -n, --dry-run            print the exact aws cli commands, execute nothing
  -h, --help               print this help text and exit 0

exit status:
  0  every invocation on every target ended Success with exit code 0
  1  at least one invocation failed, timed out, or exceeded the wait budget
  2  the command line was used wrongly
  3  an input file could not be read

example:
  scripts/ssm-run-command.sh --targets i-0a1b2c3d4e5f60718,i-0f1e2d3c4b5a69780 \
      --parameters 'comments=rotate the ntp client configuration' \
      --command-file data/snippets/rotate-ntp.sh \
      --region eu-central-1
USAGE_EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --targets)          [ "$#" -ge 2 ] || usage_error "$1 needs a value"; TARGETS=$2; shift 2;;
            --tag-list)         [ "$#" -ge 2 ] || usage_error "$1 needs a value"; TAG_LIST=$2; shift 2;;
            --document-id)      [ "$#" -ge 2 ] || usage_error "$1 needs a value"; DOCUMENT_ID=$2; shift 2;;
            --document-version) [ "$#" -ge 2 ] || usage_error "$1 needs a value"; DOCUMENT_VERSION=$2; shift 2;;
            --parameters)       [ "$#" -ge 2 ] || usage_error "$1 needs a value"; PARSING_PARAMETERS=$2; shift 2;;
            --command-file)     [ "$#" -ge 2 ] || usage_error "$1 needs a value"; COMMAND_FILE=$2; shift 2;;
            --timeout)          [ "$#" -ge 2 ] || usage_error "$1 needs a value"; TIMEOUT_SECONDS=$2; shift 2;;
            --retries)          [ "$#" -ge 2 ] || usage_error "$1 needs a value"; RETRIES=$2; shift 2;;
            --poll-interval)    [ "$#" -ge 2 ] || usage_error "$1 needs a value"; POLL_INTERVAL_SECONDS=$2; shift 2;;
            --max-wait)         [ "$#" -ge 2 ] || usage_error "$1 needs a value"; MAX_POLL_SECONDS=$2; shift 2;;
            -r|--region)        [ "$#" -ge 2 ] || usage_error "$1 needs a value"; AWS_REGION=$2; shift 2;;
            -n|--dry-run)       DRY_RUN=1; shift;;
            -h|--help)          usage; exit 0;;
            --) shift;;
            *)  usage_error "unknown option: $1";;
        esac
    done
}

build_parameters_document() {
    # Purpose: turn the --parameters string, the --command-file content, and
    # the --timeout into one JSON object of document parameters, printed on
    # standard output.  Unknown parameter keys pass through untouched, so a
    # custom account document works the same way the public one does.
    _CLOUDOPS_PARAMS_RAW=$PARSING_PARAMETERS \
    _CLOUDOPS_CMD_FILE=$COMMAND_FILE \
    _CLOUDOPS_TIMEOUT=$TIMEOUT_SECONDS \
    "$PYTHON_BIN" - <<'PYTHON_EOF'
import json
import os
import shlex
import sys

raw = os.environ.get("_CLOUDOPS_PARAMS_RAW", "") or ""
cmd_file = os.environ.get("_CLOUDOPS_CMD_FILE", "") or ""
timeout = os.environ.get("_CLOUDOPS_TIMEOUT", "600")

def parse_pairs(text):
    """Split 'key=value key2=value2' with shlex, so quotes are honoured."""
    try:
        tokens = shlex.split(text)
    except ValueError as exc:
        print("ssm-run-command: cannot parse --parameters: %s" % exc, file=sys.stderr)
        sys.exit(2)
    out = {}
    for token in tokens:
        if "=" not in token:
            print("ssm-run-command: parameter token without '=': %r" % token, file=sys.stderr)
            sys.exit(2)
        key, _, value = token.partition("=")
        out[key] = value
    return out

document_parameters = parse_pairs(raw)

if cmd_file:
    try:
        with open(cmd_file, encoding="utf-8") as handle:
            document_parameters["runcommand"] = handle.read()
    except os.OSError as exc:
        print("ssm-run-command: cannot read --command-file: %s" % exc, file=sys.stderr)
        sys.exit(3)

if not document_parameters.get("runcommand"):
    print("ssm-run-command: no runcommand given (pass --parameters 'runcommand=...'"
          " or --command-file FILE)", file=sys.stderr)
    sys.exit(2)

# The comments parameter is advisory, but an unlabelled fleet command is an
# unauditable one; the script fills a minimum rather than allow an empty one.
document_parameters.setdefault("comments", "ssm-run-command.sh invocation")
document_parameters["executionTimeout"] = str(int(timeout))

print(json.dumps(document_parameters))
PYTHON_EOF
}

fetch_invocation_list() {
    # Purpose: the predicate for poll_until -- succeed once SSM has created a
    # non-empty target list for the command.  Keeps the freshest document in
    # the file named by the second argument.
    local command_id=$1 out=$2
    retry "$RETRIES" 2 $CMD_SSM_LIST_INVOCATIONS \
        --command-id "$command_id" \
        --region "$AWS_REGION" \
        --output "$AWS_OUTPUT" >"$out" 2>/dev/null || return 1
    local count
    count=$(json_query "$out" "len(doc['CommandInvocations'][0]['Targets']) if doc['CommandInvocations'] else 0") || return 1
    [ "$count" -ge 1 ]
}

record_summary_row() {
    # Purpose: append one row to the summary ledger that the final table
    # printer reads; one line per target keeps the table deterministic.
    local target=$1 status=$2 code=$3 details=$4
    printf '%s\t%s\t%s\t%s\n' "$target" "$status" "$code" "$details" >>"${WORK_DIR}/summary.tsv"
}

WORK_DIR=''
cleanup_work_dir() { [ -n "$WORK_DIR" ] && rm -rf -- "$WORK_DIR"; }

main() {
    parse_args "$@"

    # Mutual exclusion of the two target selectors, plus 'at least one'.
    if [ -n "$TARGETS" ] && [ -n "$TAG_LIST" ]; then
        usage_error "--targets and --tag-list are mutually exclusive; pick one"
    fi
    [ -n "$TARGETS" ] || [ -n "$TAG_LIST" ] \
        || usage_error "no target selection: give --targets i-0a,i-0b or --tag-list Key=Value"
    [ -n "$AWS_REGION" ] || die "no region: pass --region, or export AWS_DEFAULT_REGION / AWS_REGION"
    [ -z "$COMMAND_FILE" ] || [ -f "$COMMAND_FILE" ] || die "no such --command-file: $COMMAND_FILE"
    [[ $TIMEOUT_SECONDS =~ ^[0-9]+$ ]] && [ "$TIMEOUT_SECONDS" -ge 30 ] \
        || usage_error "--timeout must be an integer of at least 30 seconds"
    [[ $RETRIES =~ ^[0-9]+$ ]] && [ "$RETRIES" -ge 1 ] \
        || usage_error "--retries must be a positive integer"
    [[ $POLL_INTERVAL_SECONDS =~ ^[0-9]+$ ]] && [ "$POLL_INTERVAL_SECONDS" -ge 1 ] \
        || usage_error "--poll-interval must be a positive integer"
    [[ $MAX_POLL_SECONDS =~ ^[0-9]+$ ]] && [ "$MAX_POLL_SECONDS" -ge "$TIMEOUT_SECONDS" ] \
        || usage_error "--max-wait must be a positive integer of at least --timeout"

    require_cmd aws python3

    WORK_DIR=$(mktemp -d -t ssm-run-XXXXXX)
    trap 'cleanup_work_dir' EXIT
    : >"${WORK_DIR}/summary.tsv"

    local parameters_json
    parameters_json=$(build_parameters_document) \
        || die "the document parameters could not be constructed (see the message above)"
    log debug "document parameters (first 200 columns): $(printf '%s' "$parameters_json" | cut -c1-200)..."

    # Assemble and validate the target selection argument of the CLI.
    local target_flag target_value
    if [ -n "$TARGETS" ]; then
        [[ $TARGETS =~ ^i-[0-9a-f]{8,21}(,i-[0-9a-f]{8,21})*$ ]] \
            || die "each target must be an EC2 instance identifier (i-...); got: ${TARGETS}"
        target_flag='--targets'
        target_value=$TARGETS
        log info "target selection: an explicit list of $(printf '%s\n' "$TARGETS" | tr ',' '\n' | wc -l | tr -d ' ') instance identifier(s)"
    else
        [[ $TAG_LIST =~ ^Key=[^,=]+(,Value=[^,]*)?$ ]] \
            || die "--tag-list must look like Key=Name or Key=Name,Value=Value; got: ${TAG_LIST}"
        target_flag='--tag-list'
        target_value=$TAG_LIST
        log info "target selection: the tag list ${TAG_LIST}"
    fi

    # --- phase 1: send the command -----------------------------------------------
    local send_json="${WORK_DIR}/send.json"
    if [ "$DRY_RUN" -eq 1 ]; then
        run $CMD_SSM_SEND_COMMAND \
            --document-name "$DOCUMENT_ID" \
            --document-version "$DOCUMENT_VERSION" \
            "$target_flag" "$target_value" \
            --parameters "$parameters_json" \
            --timeout-seconds "$((TIMEOUT_SECONDS + 60))" \
            --region "$AWS_REGION" \
            --output "$AWS_OUTPUT"
        log info "dry run: the status poll and the summary table are skipped; nothing was executed"
        exit 0
    fi

    retry "$RETRIES" 2 $CMD_SSM_SEND_COMMAND \
        --document-name "$DOCUMENT_ID" \
        --document-version "$DOCUMENT_VERSION" \
        "$target_flag" "$target_value" \
        --parameters "$parameters_json" \
        --timeout-seconds "$((TIMEOUT_SECONDS + 60))" \
        --region "$AWS_REGION" \
        --output "$AWS_OUTPUT" >"$send_json" \
        || die "the SendCommand call failed after ${RETRIES} attempts"

    local command_id
    command_id=$(json_query "$send_json" "doc['Command']['CommandId']") \
        || die "the SendCommand response carried no CommandId"
    log info "sent ${DOCUMENT_ID} as command ${command_id}; awaiting the terminal states (poll every ${POLL_INTERVAL_SECONDS}s, wall budget ${MAX_POLL_SECONDS}s)"

    # --- phase 2: enumerate the targets SSM actually created invocations for -----
    local invocations_json="${WORK_DIR}/invocations.json"
    poll_until "invocation ${command_id} to list its targets" \
        "$MAX_POLL_SECONDS" "$POLL_INTERVAL_SECONDS" \
        fetch_invocation_list "$command_id" "$invocations_json" \
        || die "invocation ${command_id} never reported a target list within ${MAX_POLL_SECONDS}s"

    local targets_seen
    targets_seen=$(json_query "$invocations_json" \
        "[t['InstanceSource']['InstanceId'] for t in doc['CommandInvocations'][0]['Targets']]") \
        || die "no invocation targets were listed for ${command_id}"
    [ -n "$targets_seen" ] \
        || die "SSM reports zero targets for ${command_id}: check the agent registration of the instances and the tag selector"

    # --- phase 3: watch every target to its terminal state ------------------------
    local failed=0 index=0 target
    while IFS= read -r target; do
        [ -n "$target" ] || continue
        index=$((index + 1))
        log info "watching invocation ${command_id} on ${target} (target ${index} of the fleet)"
        local one_json="${WORK_DIR}/one-${index}.json"
        local deadline
        deadline=$(( $(date +%s) + MAX_POLL_SECONDS ))
        local status='Pending' code='-' details=''
        while :; do
            if retry "$RETRIES" 2 $CMD_SSM_GET_INVOCATION \
                    --command-id "$command_id" \
                    --instance-id "$target" \
                    --with-plugin \
                    --details \
                    --region "$AWS_REGION" \
                    --output "$AWS_OUTPUT" >"$one_json" 2>/dev/null; then
                status=$(json_query "$one_json" "doc['CommandInvocation']['Status']")
                code=$(json_query "$one_json" "doc['CommandInvocation']['ResponseCode']")
                details=$(json_query "$one_json" "(doc['CommandInvocation'].get('ResponseInformation') or {}).get('ResponseCodeDetails','')")
                case "$status" in
                    Success|Failed|TimedOut|Cancelled|AccessDenied|Error) break;;
                    InProgress|Pending|Delivering|Delayed)
                        # InProgress counts as terminal for the overall verdict
                        # only when the per-instance execution already finished;
                        # the document timeout of SSM will force Failed/TimedOut.
                        ;;
                    *) log debug "target ${target}: status '${status}' is transitional; polling on";;
                esac
            else
                err "the GetCommandInvocation call for ${target} failed after ${RETRIES} attempts"
                status='Unreachable'; code='-'; details='api error'
                break
            fi
            if [ "$(date +%s)" -ge "$deadline" ]; then
                status='WaitExpired'; code='-'; details="exceeded the wall budget of ${MAX_POLL_SECONDS}s"
                break
            fi
            sleep "$POLL_INTERVAL_SECONDS"
        done

        # The verdict of one target: Success plus exit code 0, nothing else.
        if [ "$status" = "Success" ] && [ "$code" != "0" ]; then
            failed=1
            details="the command exited with code ${code}"
            status='Failed'
        fi
        if [ "$status" != "Success" ]; then
            failed=1
        fi
        log info "invocation ${command_id} on ${target}: ${status} (exit code ${code})${details:+ -- ${details}}"
        record_summary_row "$target" "$status" "$code" "$details"
    done <<< "$targets_seen"

    # --- phase 4: the summary table and the exit verdict --------------------------
    log info "summary for command ${command_id} (document ${DOCUMENT_ID}):"
    printf '%-24s %-14s %-6s %s\n' 'TARGET' 'STATUS' 'CODE' 'DETAILS'
    if [ -s "${WORK_DIR}/summary.tsv" ]; then
        while IFS=$'\t' read -r s_target s_status s_code s_details; do
            printf '%-24s %-14s %-6s %s\n' "$s_target" "$s_status" "$s_code" "$s_details"
        done <"${WORK_DIR}/summary.tsv"
    fi

    if [ "$failed" -ne 0 ]; then
        die "at least one command failed on at least one target; see the summary table above"
    fi
    log info "every invocation succeeded on every target"
}

main "$@"
