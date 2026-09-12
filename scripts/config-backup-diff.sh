#!/usr/bin/env bash
# shellcheck shell=bash
#
# This script takes the configuration estate of one region to S3 and reports
# what moved since the last backup.  The configuration files of the estate --
# the things that break at three in the morning -- are: the security groups,
# the network ACLs, the IAM policies, the database parameter groups, and the
# KMS key aliases.  Each of them is exported to a canonical JSON document,
# uploaded to a versioned S3 bucket, and diffed against the copy that the
# previous backup left behind.
#
# The change-ticket convention (the reason the exit code 1 exists):
#   every change to a configuration file must ride on a change ticket -- the
#   identifier of the change advisory board record -- and the ticket id passes
#   to this script as  -c CHNG-12345 .
#   When the script finds a configuration document that CHANGED since the last
#   backup and no ticket was supplied, it exits 1: the estate has an
#   unexplained mutation, which is precisely the 02:00 console edit that the
#   drift program exists to surface.  When a ticket IS supplied, the change is
#   considered explained (and the ticket id rides in the metadata of the
#   uploaded object) and the script continues to exit 0.  The script never
#   judges whether the ticket is a good idea; it enforces only that a change
#   has one.
#
# The bucket must have versioning enabled -- it is the archive of the estate,
# and a backup that overwrites its own history is a backup with amnesia.  The
# script verifies the versioning state of the bucket first and REFUSES to
# upload to an unversioned bucket; the refusal is overridable by
# --allow-unversioned only, never silently.
#
# Scope: this script READS the five configuration families named above in one
# region, writes to one scratch directory of its own, and UPLOADS to one prefix
# of one bucket named by --bucket.  It never modifies, never deletes, and never
# restores any AWS resource, and it never reads or prints a secret.  The KMS
# export covers the aliases and the key metadata only -- the material of a key
# cannot be exported and is never attempted.  Credentials come from the process
# environment or an AWS profile only.
#
# Failure behaviour: exit 1 when a configuration document changed without a
# ticket, when the target bucket is not versioned, or when an AWS call failed;
# exit 2 for a wrong command line; exit 3 for a local or scratch fault.  In
# --dry-run mode the script prints the planned uploads and the planned
# comparisons and writes nothing anywhere.
#
# See also: docs/man/, README.md ('Drift control'), infra/modules/network.

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
install_err_trap

# ---------------------------------------------------------------------------
# The blast radius: every AWS API operation this script may call, exactly once
# each, as a named constant.  The seven 'get' commands are the entire read
# surface; the two s3 commands are the entire write surface (one upload per
# document, one head-object per comparison).  Nothing here deletes.
# ---------------------------------------------------------------------------
readonly CMD_EC2_DESCRIBE_SECURITY_GROUPS='aws ec2 describe-security-groups'
readonly CMD_EC2_DESCRIBE_NETWORK_ACLS='aws ec2 describe-network-acls'
readonly CMD_IAM_LIST_ATTACHED_POLICIES='aws iam list-role-policies'
readonly CMD_IAM_GET_ROLE_POLICY='aws iam get-role-policy'
readonly CMD_RDS_DESCRIBE_PARAMETER_GROUPS='aws rds describe-db-parameter-groups'
readonly CMD_KMS_LIST_ALIASES='aws kms list-aliases'
readonly CMD_S3_GET_BUCKET_VERSIONING='aws s3api get-bucket-versioning'
readonly CMD_S3_HEAD_OBJECT='aws s3api head-object'
readonly CMD_S3_DOWNLOAD='aws s3 cp'
readonly CMD_S3_UPLOAD='aws s3 cp'

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
BUCKET=''
TICKET=''                    # the change ticket id, the -c of the convention
DRY_RUN=0
ALLOW_UNVERSIONED=0
PREFIX='config-backup'     # the key prefix under which the documents live
AWS_REGION=${AWS_DEFAULT_REGION:-}
WORK_DIR=''
RUN_STAMP=''               # the stamp of this backup run, set in main

usage() {
    cat <<'USAGE_EOF'
usage: config-backup-diff.sh --bucket S3-BUCKET [-c CHNG-NNNN] [options]

Export the configuration files of the estate (the security groups, the
network ACLs, the IAM policies, the parameter groups, the KMS aliases) to a
versioned S3 bucket, print the diff against the previous backup, and exit 1
when a configuration document changed while no change ticket was supplied.

options:
  --bucket BUCKET          the destination S3 bucket (versioning required;
                           required argument)
  -c, --ticket TICKET      the id of the change advisory board ticket that
                           explains the current state of the configuration
                           (the convention of the program: -c CHNG-12345)
  --prefix PATH            the key prefix of the backup inside the bucket
                           (default 'config-backup')
  --allow-unversioned      proceed even when the bucket has no versioning
                           (NOT recommended: the versioned history is the
                           archive of the estate)
  -r, --region REGION      the AWS region; defaults from AWS_DEFAULT_REGION
                           or AWS_REGION
  -n, --dry-run            print the planned uploads and the planned diffs;
                           write nothing
  -h, --help               print this help text and exit 0

exit status:
  0  the backup is complete and every changed document rode on a ticket
  1  a configuration document changed WITHOUT a ticket, or the target bucket
     has no versioning, or an AWS call failed
  2  the command line was used wrongly

example:
  scripts/config-backup-diff.sh --bucket estate-config-archive --dry-run
  scripts/config-backup-diff.sh --bucket estate-config-archive -c CHNG-12345
USAGE_EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --bucket)             [ "$#" -ge 2 ] || usage_error "$1 needs a value"; BUCKET=$2; shift 2;;
            -c|--ticket)          [ "$#" -ge 2 ] || usage_error "$1 needs a value"; TICKET=$2; shift 2;;
            --prefix)             [ "$#" -ge 2 ] || usage_error "$1 needs a value"; PREFIX=$2; shift 2;;
            --allow-unversioned)  ALLOW_UNVERSIONED=1; shift;;
            -r|--region)          [ "$#" -ge 2 ] || usage_error "$1 needs a value"; AWS_REGION=$2; shift 2;;
            -n|--dry-run)         DRY_RUN=1; shift;;
            -h|--help)            usage; exit 0;;
            --) shift;;
            *)  usage_error "unknown option: $1";;
        esac
    done
}

# ---------------------------------------------------------------------------
# The work-horses of one configuration document.
# ---------------------------------------------------------------------------
export_configuration_document() {
    # Purpose: run one read command of the family, canonicalise its JSON (the
    # keys sorted, the volatile fields dropped), and store the result as the
    # new version of the document name under the scratch directory.  The
    # canonicalisation matters: an export whose field order drifts would
    # report a change on every run and make the whole comparison worthless.
    # Usage: export_configuration_document NAME COMMAND [ARG...]
    local name=$1; shift
    local raw="${WORK_DIR}/raw/${name}.json"
    local out="${WORK_DIR}/new/${name}.json"
    local errlog="${WORK_DIR}/fetch/${name}.err"
    mkdir -p -- "${WORK_DIR}/raw" "${WORK_DIR}/new" "${WORK_DIR}/old" "${WORK_DIR}/fetch"
    : >"$errlog"
    if ! retry 3 2 "$@" --region "$AWS_REGION" --output json >"$raw" 2>"$errlog"; then
        err "the read of the family '${name}' failed:"
        sed -e 's/^/    fetch: /' -- "$errlog" >&2 || true
        return 1
    fi
    local py_status=0
    _CLOUDOPS_RAW="$raw" _CLOUDOPS_OUT="$out" "$PYTHON_BIN" - <<'PYTHON_EOF'
import json
import os
import re
import sys

# The volatile fields that every AWS export carries and that no comparison of
# two backups should ever report: request identifiers and the stamps that the
# API applies itself.  A field is volatile when its name matches one of these
# shapes; the list is deliberately explicit rather than a catch-all, so that a
# real change to a field with a similar name is never silently dropped.
VOLATILE_NAMES = re.compile(
    r'^(ResponseMetadata|RequestId|CreatorRequestId|_meta'
    r'|UpdateTime|UpdateTimeUTC|Expires|Date|Timestamp)$'
)

def canonicalise(node):
    if isinstance(node, dict):
        return {key: canonicalise(value)
                for key, value in sorted(node.items())
                if not VOLATILE_NAMES.match(str(key)) and not str(key).startswith('_')}
    if isinstance(node, list):
        return [canonicalise(item) for item in node]
    return node

with open(os.environ["_CLOUDOPS_RAW"], encoding="utf-8") as handle:
    document = json.load(handle)

canonical = canonicalise(document)

with open(os.environ["_CLOUDOPS_OUT"], "w", encoding="utf-8") as handle:
    json.dump(canonical, handle, indent=2, sort_keys=True)
    handle.write("\n")
PYTHON_EOF
    py_status=$?
    [ "$py_status" -eq 0 ] || { err "the canonical export of '${name}' could not be written"; return 1; }
}

compare_document_against_previous() {
    # Purpose: compare the fresh export of one document name against the copy
    # that the previous backup left at the 'latest' key of the archive, and
    # print the unified diff.  The count of changed lines is reported on the
    # last standard-output line as 'CHANGE_LINES=N'.
    # Returns: 0 when the document is unchanged; 1 when it changed (or is
    # new), so that the caller's 'if' reads as prose.
    local name=$1
    local latest_key="${PREFIX}/latest/${name}.json"
    local previous="${WORK_DIR}/old/${name}.json"
    local current="${WORK_DIR}/new/${name}.json"
    mkdir -p -- "${WORK_DIR}/old"

    if [ "$DRY_RUN" -eq 1 ]; then
        log info "dry run: would fetch s3://${BUCKET}/${latest_key} and diff it against the fresh export ${name}.json"
        return 0
    fi

    local head_status=0
    retry 3 2 $CMD_S3_HEAD_OBJECT --bucket "$BUCKET" --key "$latest_key" \
        --region "$AWS_REGION" >/dev/null 2>/dev/null || head_status=$?
    if [ "$head_status" -ne 0 ]; then
        log info "'${name}': no previous backup of this document was found; this export is the first of its name"
        printf 'CHANGE_LINES=%d\n' 1
        return 1
    fi
    if ! retry 3 2 $CMD_S3_DOWNLOAD "s3://${BUCKET}/${latest_key}" "$previous" \
            --region "$AWS_REGION" >/dev/null 2>&1; then
        log info "'${name}': the previous backup could not be fetched; treating the export as new"
        printf 'CHANGE_LINES=%d\n' 1
        return 1
    fi

    local diff_status=0
    diff -u -U 3 --label "previous/${name}.json" --label "current/${name}.json" \
        "$previous" "$current" || diff_status=$?
    if [ "$diff_status" -eq 0 ]; then
        printf 'CHANGE_LINES=%d\n' 0
        return 0
    fi
    # Count the changed payload lines of the unified comparison.
    local changes
    changes=$(diff "$previous" "$current" | grep -c '^[<>]' || true)
    [[ $changes =~ ^[0-9]+$ ]] || changes=1
    [ "$changes" -ge 1 ] || changes=1
    printf 'CHANGE_LINES=%d\n' "$changes"
    return 1
}

upload_document() {
    # Purpose: upload one exported document twice -- once to the run-stamped
    # archive key (the versioned history) and once to the 'latest' key (the
    # copy that the next backup diffs against).  The ticket, when supplied,
    # rides in the user metadata of both objects, so that the archive carries
    # its own audit trail.
    #
    # Note: the metadata string below is word-split on purpose, because the
    # CLI wants '--metadata ticket=...' as separate arguments; it is built
    # only from a validated ticket id and contains no whitespace.
    local name=$1
    local source="${WORK_DIR}/new/${name}.json"
    local archive_key="${PREFIX}/${RUN_STAMP}/${name}.json"
    local latest_key="${PREFIX}/latest/${name}.json"
    local metadata_args=
    [ -n "$TICKET" ] && metadata_args="--metadata ticket=${TICKET}"
    if ! run $CMD_S3_UPLOAD "$source" "s3://${BUCKET}/${archive_key}" \
            --region "$AWS_REGION" ${metadata_args:+$metadata_args}; then
        return 1
    fi
    if ! run $CMD_S3_UPLOAD "$source" "s3://${BUCKET}/${latest_key}" \
            --region "$AWS_REGION" ${metadata_args:+$metadata_args}; then
        return 1
    fi
    return 0
}

verify_bucket_versioning() {
    # Purpose: refuse to back the estate up to a bucket without a history.
    # Returns 0 when versioning is Enabled (or --allow-unversioned was given),
    # 1 when the bucket must be configured first.
    if [ "$DRY_RUN" -eq 1 ]; then
        log info "dry run: would verify that s3://${BUCKET} has versioning Enabled"
        return 0
    fi
    local state=''
    if retry 3 2 $CMD_S3_GET_BUCKET_VERSIONING --bucket "$BUCKET" \
            --region "$AWS_REGION" --output json >"${WORK_DIR}/versioning.json" 2>/dev/null; then
        state=$(json_query "${WORK_DIR}/versioning.json" "doc.get('Status', '')" 2>/dev/null) || state=''
    fi
    case "$state" in
        Enabled)
            log info "the target bucket s3://${BUCKET} has versioning Enabled: the archive keeps every backup, every rotation, and every deleted configuration"
            return 0;;
        *)
            if [ "$ALLOW_UNVERSIONED" -eq 1 ]; then
                warn "the target bucket s3://${BUCKET} reports versioning '${state:-Disabled}'; continuing because --allow-unversioned was given"
                return 0
            fi
            err "the target bucket s3://${BUCKET} does not have versioning Enabled (state '${state:-unknown}'); a destination without a history is no backup destination at all"
            err "enable versioning first: aws s3api put-bucket-versioning --bucket ${BUCKET} --versioning-configuration Status=Enabled --region ${AWS_REGION}   (or pass --allow-unversioned with intent)"
            return 1;;
    esac
}

# The verdict of one document family, shared by the five families so that the
# reporting is identical everywhere.  Sets CHANGED_WITHOUT_TICKET when a change
# was seen while no ticket was supplied.
CHANGED_WITHOUT_TICKET=0

inspect_document_family() {
    # Purpose: export, compare, report, and upload one configuration family.
    # Usage: inspect_document_family NAME READ_COMMAND...
    local name=$1; shift
    log info "-- exporting the configuration family '${name}'"
    if ! export_configuration_document "$name" "$@"; then
        die "the family '${name}' could not be exported; the backup is incomplete and the diff of this run cannot be trusted"
    fi
    local line status=0
    if line=$(compare_document_against_previous "$name"); then
        log info "'${name}': unchanged since the previous backup (${line})"
    else
        status=$?
        log warn "'${name}': CHANGED since the previous backup (${line})"
        if [ -z "$TICKET" ]; then
            CHANGED_WITHOUT_TICKET=1
        fi
    fi
    if ! upload_document "$name"; then
        die "the upload of the family '${name}' to s3://${BUCKET} failed"
    fi
}

main() {
    parse_args "$@"
    [ -n "$BUCKET" ] || usage_error '--bucket is required (the S3 destination of the archive)'
    [ -n "$AWS_REGION" ] || die "no region: pass --region, or export AWS_DEFAULT_REGION / AWS_REGION"
    [[ $BUCKET =~ ^[0-9a-zA-Z][0-9a-zA-Z._-]{1,61}[0-9a-zA-Z]$ ]] || die "the bucket name is not a valid S3 bucket name: ${BUCKET}"
    [[ $PREFIX =~ ^[0-9a-zA-Z._/-]+$ ]] || die "the key prefix carries characters outside the allowed set: ${PREFIX}"
    if [ -n "$TICKET" ]; then
        [[ $TICKET =~ ^[0-9a-zA-Z][0-9a-zA-Z._/-]{1,63}$ ]] || die "the ticket id is not a printable identifier: ${TICKET}"
    fi
    require_cmd aws python3 diff

    WORK_DIR=$(mktemp -d -t config-backup-XXXXXX)
    trap '[ -n "$WORK_DIR" ] && rm -rf -- "$WORK_DIR"' EXIT
    RUN_STAMP=$(date -u +%Y%m%dT%H%M%SZ)

    log info "configuration backup run ${RUN_STAMP}: region ${AWS_REGION}, destination s3://${BUCKET}/${PREFIX}/, ticket ${TICKET:-<none supplied>}"

    verify_bucket_versioning || die "the destination bucket is not a valid backup destination"

    # The five configuration families of the estate.  The names below are the
    # document names of the archive: keep them stable, because the diff of
    # next month is taken against the documents of this month.
    inspect_document_family 'security-groups'  $CMD_EC2_DESCRIBE_SECURITY_GROUPS
    inspect_document_family 'network-acls'     $CMD_EC2_DESCRIBE_NETWORK_ACLS
    inspect_document_family 'iam-policies'     $CMD_IAM_LIST_ATTACHED_POLICIES
    inspect_document_family 'parameter-groups' $CMD_RDS_DESCRIBE_PARAMETER_GROUPS
    inspect_document_family 'kms-aliases'      $CMD_KMS_LIST_ALIASES

    if [ "$DRY_RUN" -eq 1 ]; then
        log info "dry run: the uploads and the comparisons above were planned and printed; nothing was written to s3://${BUCKET}"
    else
        log info "the configuration estate is backed up under s3://${BUCKET}/${PREFIX}/${RUN_STAMP}/"
    fi

    if [ "$CHANGED_WITHOUT_TICKET" -eq 1 ]; then
        err "a configuration document changed since the last backup and NO change ticket was supplied"
        err "the program admits no change to the configuration estate without a ticket: file the change, then re-run with -c <ticket> (the convention: -c CHNG-12345)"
        exit 1
    fi
    [ -z "$TICKET" ] || log info "every change of this run rides on ticket ${TICKET}"
}

main "$@"
