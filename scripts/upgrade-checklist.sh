#!/usr/bin/env bash
# shellcheck shell=bash
#
# This script prints the upgrade checklist for one planned upgrade of the
# estate and gates the operator on it.  It does not change anything: it is a
# disciplined pause, the pre-flight list that a human reads before the
# automation of the sibling scripts (rds-minor-upgrade.sh,
# rds-major-upgrade-bluegreen.sh, elasticache-failover-test.sh) is pointed at
# production.  A checklist that can be skimmed past is a checklist that is not a
# checklist, so the script requires an explicit acknowledgement: the operator
# must pass --confirm and type the literal word 'yes' before the script reports
# the plan as signed off.  In --dry-run mode the checklist is printed and the
# acknowledgement is waived, so that the plan can be reviewed by the reviewer.
#
# What the checklist contains (generated from the template embedded in this
# file -- there is no external template file to drift from):
#   * the preconditions of the planned change (the change ticket, the health of
#     the object, the freeze windows, the alert acknowledgements);
#   * the backups, with the identifier that each backup carries, so that the
#     restore point of the change is named on the page, not assumed;
#   * the checksums -- the sha256 of every user-data and bootstrap script under
#     scripts/ -- so that the operator can prove that the scripts they are
#     running are the scripts that were reviewed;
#   * the rollback plan, in the words of the runbook, with the exact command
#     that reverses the change and the expected time to reverse it.
#
# The --from flag selects the runbook the checklist is derived from by naming
# the section of the README index it corresponds to; the --to flag names the
# target of the change.  Both are descriptive labels that ride on the printed
# page and into the acknowledgement line; neither is executed.
#
# Scope: this script READS the scripts/ directory to compute the checksums and
# writes nothing at all -- not a file, not an API call.  It never reads or
# prints a secret.  If it ever gains an AWS call, that call must appear as a
# constant at the top of this file (it currently has none, and the block below
# is empty on purpose).
#
# Failure behaviour: exit 0 when the checklist was signed off; exit 1 when the
# operator declined to confirm (this is not an error, it is the check working);
# exit 2 for a wrong command line.
#
# See also: README.md, docs/man/, the runbook named by --from.

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
install_err_trap

# ---------------------------------------------------------------------------
# The blast radius: this script performs no AWS operation.  The block is
# deliberately empty; an auditor who greps for 'CMD_' here sees, at a glance,
# that the script cannot reach the control plane.
# ---------------------------------------------------------------------------
# (no CMD_* constants by design: this script is read-only over the checkout)

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
FROM_LABEL='README.md'          # the runbook or README index entry this plan is from
TO_LABEL=''                     # the target of the planned change (an identifier)
KIND='generic'                  # the class of the change, one of: rds-minor, rds-major, elasticache, generic
TICKET=''                       # the change ticket id, if the operator has one yet
CONFIRM=0                       # the gate; --confirm sets it
DRY_RUN=0

usage() {
    cat <<'USAGE_EOF'
usage: upgrade-checklist.sh --kind KIND --to TARGET [-c TICKET] --confirm

Print the upgrade checklist of one planned upgrade -- the preconditions, the
backups with their restore identifiers, the sha256 checksums of the user-data
scripts, and the rollback plan with the exact reversing command -- and require
the operator to acknowledge it by typing the word 'yes' before the plan is
signed off.

options:
  --kind KIND              the class of the change: rds-minor, rds-major,
                           elasticache, generic (default generic)
  --to TARGET              the identifier of the object being changed, e.g.
                           db-prod-01 or cache-prod-01 (required)
  --from LABEL             the runbook or README index entry the plan follows
                           (default 'README.md')
  -c, --ticket TICKET      the change advisory board ticket id, if it exists
  --confirm                require the operator to type 'yes' to sign the plan
                           off (without it the plan is printed and, without a
                           terminal, the acknowledgement is refused)
  -n, --dry-run            print the checklist and waive the acknowledgement
                           (for the reviewer of the plan)
  -h, --help               print this help text and exit 0

exit status:
  0  the checklist was signed off (or printed under --dry-run)
  1  the operator declined to acknowledge the checklist
  2  the command line was used wrongly

example:
  scripts/upgrade-checklist.sh --kind rds-major --to db-prod-01 -c CHNG-12345
  scripts/upgrade-checklist.sh --kind elasticache --to cache-prod-01 --dry-run
USAGE_EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --kind)        [ "$#" -ge 2 ] || usage_error "$1 needs a value"; KIND=$2; shift 2;;
            --to)          [ "$#" -ge 2 ] || usage_error "$1 needs a value"; TO_LABEL=$2; shift 2;;
            --from)        [ "$#" -ge 2 ] || usage_error "$1 needs a value"; FROM_LABEL=$2; shift 2;;
            -c|--ticket)   [ "$#" -ge 2 ] || usage_error "$1 needs a value"; TICKET=$2; shift 2;;
            --confirm)     CONFIRM=1; shift;;
            -n|--dry-run)  DRY_RUN=1; shift;;
            -h|--help)     usage; exit 0;;
            --) shift;;
            *)  usage_error "unknown option: $1";;
        esac
    done
}

rollback_command_for() {
    # Purpose: the single, exact command that reverses the planned change,
    # chosen from the --kind.  Printed verbatim on the checklist so that the
    # reversal is ready to paste at the worst moment of the night.
    local kind=$1 target=$2
    case "$kind" in
        rds-minor)
            printf 'aws rds modify-db-instance --db-instance-identifier %s --engine-version <previous-version> --apply-immediately false --region <region>\n' "$target"
            printf 'expected time to reverse: the length of the next maintenance window, plus one reboot of the instance';;
        rds-major)
            printf 'aws rds restore-db-instance-from-snapshot --db-instance-identifier %s-rollback --db-snapshot-identifier <pre-upgrade-snapshot> --region <region>\n' "$target"
            printf 'expected time to reverse: minutes, bounded by the size of the database and the speed of the restore';;
        elasticache)
            printf 'the failover is self-healing: the promoted primary stays promoted; rebuild the group from the snapshot to reverse a persistent fault:\n'
            printf 'aws elasticache create-cache-cluster --replication-group-id %s ... --region <region>\n' "$target"
            printf 'expected time to reverse: the group returns to available on its own; a rebuild follows the size of the cache';;
        *)
            printf 'no scripted reversal is registered for this kind; attach the runbook command before the change proceeds'
            printf 'expected time to reverse: to be established by the runbook author';;
    esac
}

user_data_checksums() {
    # Purpose: print the sha256 of every user-data / bootstrap script under
    # scripts/, so that the operator can prove that the automation they point
    # at production is the automation that was reviewed.  The list is sorted for
    # a stable page.
    local count=0 digest
    local file
    for file in $(find "${REPO_ROOT}/scripts" -type f -name '*.sh' 2>/dev/null | sort); do
        digest=$(sha256_file "$file") || continue
        printf '  %s  %s\n' "${digest:0:16}" "${file##*/}"
        count=$((count + 1))
    done
    printf '  (%d user-data / bootstrap script(s) checksummed)\n' "$count"
}

print_checklist() {
    # Purpose: the checklist itself, generated from the embedded template.
    local target=$1 kind=$2
    local bar
    bar=$(printf '%.0=' $(seq 1 78) 2>/dev/null || printf '%s\n' '==============================================================================')
    printf '%s\n' "$bar"
    printf ' UPGRADE CHECKLIST -- %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf ' runbook (from): %s\n' "$FROM_LABEL"
    printf ' target   (to) : %s   kind: %s\n' "$target" "$kind"
    printf ' ticket        : %s\n' "${TICKET:-<not yet filed -- file one before the change>}"
    printf '%s\n\n' "$bar"

    printf ' 1. PRECONDITIONS\n'
    printf '    [ ] a change advisory board ticket exists and is approved (the id rides on -c)\n'
    printf '    [ ] the object is healthy right now (no open alarm on %s)\n' "$target"
    printf '    [ ] the change falls inside the maintenance window of the object, or an exception is on the ticket\n'
    printf '    [ ] the on-call knows the change is happening and the alerts of the object are acknowledged, not deleted\n'
    printf '    [ ] the canary (when the kind has one) has completed its own change and passed its scan\n\n'

    printf ' 2. BACKUPS -- the restore point is named, never assumed\n'
    case "$kind" in
        rds-minor|rds-major)
            printf '    [ ] a manual snapshot exists and its identifier is written on this page\n'
            printf '        (rds: aws rds create-db-snapshot --db-instance-identifier %s --db-snapshot-identifier <%s>-pre-<stamp>)\n' "$target" "$target"
            printf '    [ ] a restore of a recent snapshot to a scratch instance was drilled within the last quarter\n\n' ;;
        elasticache)
            printf '    [ ] the group has automatic backups and a recent snapshot to restore from\n'
            printf '    [ ] the cache can be rebuilt from its source of truth if the restore is needed\n\n' ;;
        *)
            printf '    [ ] the backup appropriate to the kind of this change exists and its identifier is on this page\n\n' ;;
    esac

    printf ' 3. CHECKSUMS -- the scripts of the automation, so the reviewed code is the running code\n'
    user_data_checksums
    printf '\n'

    printf ' 4. ROLLBACK PLAN -- the exact command and its expected time\n'
    rollback_command_for "$kind" "$target" | sed -e 's/^/    /'
    printf '\n    [ ] the operator can state the rollback aloud, from this page, before the change starts\n'
    printf '%s\n' "$bar"
}

main() {
    parse_args "$@"
    [ -n "$TO_LABEL" ] || usage_error '--to is required (name the object the change targets)'
    case "$KIND" in rds-minor|rds-major|elasticache|generic) : ;; *) usage_error "--kind must be one of rds-minor, rds-major, elasticache, generic";; esac
    require_cmd python3 find

    print_checklist "$TO_LABEL" "$KIND"

    if [ "$DRY_RUN" -eq 1 ]; then
        log info "dry run: the checklist was printed for review; the acknowledgement is waived"
        exit 0
    fi

    if [ "$CONFIRM" -ne 1 ]; then
        log info "no --confirm was given: the checklist is printed but NOT signed off (re-run with --confirm to acknowledge it)"
        exit 0
    fi

    # The gate: the operator must type the literal word 'yes'.  A missing
    # terminal means no consent can be given, so the plan is not signed off.
    log info "read the checklist above; it is the contract of the change of ${TO_LABEL}"
    if confirm "sign off the upgrade checklist of ${TO_LABEL} (${KIND})?"; then
        log info "the operator signed off the checklist of ${TO_LABEL}; proceed with the automation of the matching kind"
        exit 0
    else
        err "the checklist was NOT acknowledged; the change does not proceed"
        exit 1
    fi
}

main "$@"
