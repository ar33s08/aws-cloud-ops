#!/usr/bin/env bash
# shellcheck shell=bash
#
# This script registers the SSM patch baselines and the patch groups that
# are declared in a JSON definition file (by convention data/patch-baselines.json)
# with AWS Systems Manager Patch Manager.  Registration is the moment where a
# written, reviewed baseline becomes the law of the fleet: every instance that
# carries the matching patch group tag starts evaluating its compliance against
# this definition on its next scan cycle.  Because of that, the script is
# deliberately strict:
#
#   1. The definition file is read and validated by the python core (a python3
#      helper, the same module the unit tests drive, via cloudops.patch.load_
#      baselines).  The shell never parses JSON with text tools and never
#      assumes that a jq of a particular vintage is installed.
#   2. Every baseline must carry an approval record (approved_by plus
#      approved_on).  load_baselines raises when it does not, and this script
#      refuses to register an unapproved baseline.  A hand-edited file cannot
#      silently reach the fleet: that is the whole point of the approval
#      record.
#   3. Every patch group must reference only baselines that exist in the same
#      file, so a window can never schedule against a name that was renamed
#      away.
#
# In --dry-run mode the script prints the exact aws cli commands it would run,
# verbatim, one per line, and changes nothing -- the same line the operator
# would copy and audit.
#
# Scope: this script reads one JSON file given by -f and writes only SSM patch
# baseline registrations (and the ComplianceSeverity default) in one region.
# It never touches instances, windows, schedules, parameters, or secrets.
# Credentials come from the process environment or an AWS profile only.
#
# Failure behaviour: a validation failure exits 3 (bad input file), an AWS
# registration failure exits 1 with the failed command reported by the error
# trap.  Re-running the script is safe: RegisterDefaultPatchBaseline is
# idempotent for identical filters, so a retry after a network fault is the
# correct operator response.
#
# See also: cloudops/patch.py (the validator), docs/man/, scripts/patch-schedule.sh.

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
install_err_trap

# ---------------------------------------------------------------------------
# The blast radius: every AWS API operation this script may call, exactly once
# each, as a named constant.
# ---------------------------------------------------------------------------
readonly CMD_SSM_REGISTER_BASELINE='aws ssm register-default-patch-baseline'

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
BASELINE_JSON="${REPO_ROOT}/data/patch-baselines.json"
DRY_RUN=0
AWS_REGION=${AWS_DEFAULT_REGION:-}

usage() {
    cat <<'USAGE_EOF'
usage: patch-baseline-register.sh [-f BASELINE_JSON-JSON] [options]

Validate the patch baseline and patch group definitions with the python core
(cloudops.patch.load_baselines -- every baseline must carry the approval
record of the change advisory board) and register each baseline as the
default of its product family in AWS Systems Manager Patch Manager.

options:
  -f, --file PATH        the JSON definition file
                         (default data/patch-baselines.json of the checkout)
  -r, --region REGION    the AWS region; defaults from AWS_DEFAULT_REGION
                         or AWS_REGION
  -n, --dry-run          validate, then print the exact aws cli commands
                       without executing any of them
  -h, --help             print this help text and exit 0

exit status:
  0  every baseline was validated and registered (or printed, in dry run)
  1  an AWS registration call failed
  2  the command line was used wrongly
  3  the definition file is missing, unreadable, or failed validation

example:
  scripts/patch-baseline-register.sh -f data/patch-baselines.json --dry-run
  scripts/patch-baseline-register.sh --region eu-central-1
USAGE_EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -f|--file|--definition) [ "$#" -ge 2 ] || usage_error "$1 needs a value"; BASELINE_JSON=$2; shift 2;;
            -r|--region)            [ "$#" -ge 2 ] || usage_error "$1 needs a value"; AWS_REGION=$2; shift 2;;
            -n|--dry-run)           DRY_RUN=1; shift;;
            -h|--help)              usage; exit 0;;
            --) shift;;
            *)  usage_error "unknown option: $1";;
        esac
    done
}

validate_definition_with_python() {
    # Purpose: drive the python core over the definition file: load_baselines
    # raises when a baseline lacks its approval record; this helper also
    # verifies that every patch group references only known baselines and
    # prints the registration rows (one pipe-separated line per baseline) that
    # the main flow turns into CLI calls.
    # Returns: python exit status -- 0 valid, non-zero invalid.
    local file=$1
    CLOUDOPS_REPO_ROOT=$REPO_ROOT _CLOUDOPS_BASELINE_FILE=$file \
        "$PYTHON_BIN" - <<'PYTHON_EOF'
import os
import sys

sys.path.insert(0, os.environ["_CLOUDOPS_REPO_ROOT"])

try:
    from cloudops.patch import load_baselines
except ImportError as exc:
    print("patch-baseline-register: the cloudops package could not be imported: %s" % exc,
          file=sys.stderr)
    sys.exit(3)

try:
    baselines, groups = load_baselines(os.environ["_CLOUDOPS_BASELINE_FILE"])
except (ValueError, KeyError, OSError) as exc:
    print("patch-baseline-register: the definition file failed validation: %s" % exc,
          file=sys.stderr)
    sys.exit(3)

names = {baseline.name for baseline in baselines}
for group in groups:
    for wanted in group.baseline_names:
        if wanted not in names:
            print("patch-baseline-register: patch group %r references the unknown "
                  "baseline %r" % (group.name, wanted), file=sys.stderr)
            sys.exit(3)

if not baselines:
    print("patch-baseline-register: the definition file declares no baselines",
          file=sys.stderr)
    sys.exit(3)

for baseline in baselines:
    # Row layout: NAME|PRODUCT_FAMILY|COMPLIANCE_SEVERITY|APPROVED_BY|APPROVED_ON
    print("|".join([
        baseline.name,
        baseline.product_family,
        baseline.compliance_severity,
        str(baseline.approved_by),
        str(baseline.approved_on),
    ]))
print("GROUPS|%d" % len(groups))
PYTHON_EOF
}

main() {
    parse_args "$@"
    [ -n "$AWS_REGION" ] || die "no region: pass --region, or export AWS_DEFAULT_REGION / AWS_REGION"
    [ -f "$BASELINE_JSON" ] || die 3 "no such definition file: ${BASELINE_JSON} (pass -f PATH; the default data/patch-baselines.json must exist)"

    log info "validating the baseline definitions in ${BASELINE_JSON} with the python core"

    local rows
    rows=$(validate_definition_with_python "$BASELINE_JSON") \
        || die 3 "the definition file was rejected by validation (see the message above); nothing was registered"

    require_cmd aws python3

    local row name product_family severity approved_by approved_on group_count='?'
    while IFS= read -r row; do
        case "$row" in
            GROUPS\|*)
                group_count=${row#GROUPS|}
                log info "validated the definition of ${group_count} patch group(s); the groups are the tag-pair convention that binds instances to baselines (see cloudops/patch.PatchGroup), consumed by scripts/patch-schedule.sh -- they need no registration call of their own"
                ;;
            *\|*)
                name=${row%%|*}
                local rest=${row#*|}
                product_family=${rest%%|*}; rest=${rest#*|}
                severity=${rest%%|*}; rest=${rest#*|}
                approved_by=${rest%%|*}; approved_on=${rest#*|}
                log info "approved baseline '${name}' (${product_family}, severity floor ${severity}) by ${approved_by} on ${approved_on}"
                run $CMD_SSM_REGISTER_BASELINE \
                    --operating-system "$product_family" \
                    --global-filters "PRODUCT_FAMILY=${product_family},CLASSIFICATION=Security,APPROVE_AFTER_DAYS=7,APPROVE_UNTIL_MAJOR_VERSIONS=true" \
                    --overwrite \
                    --region "$AWS_REGION" \
                    || die "the registration of baseline '${name}' failed"
                ;;
            *)
                die 3 "malformed row produced by the validator: ${row}"
                ;;
        esac
    done <<< "$rows"

    if [ "$DRY_RUN" -eq 1 ]; then
        log info "dry run: every registration command above was printed, none was executed"
    else
        log info "all baselines registered; the fleet will evaluate them at its next compliance scan cycle"
    fi
}

main "$@"
