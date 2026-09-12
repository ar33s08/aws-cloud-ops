#!/usr/bin/env bash
# shellcheck shell=bash
#
# This file is the shared library of every shell script in scripts/.  It is
# sourced, never executed: the operational scripts at the top of this directory
# load it with 'source "${SCRIPT_DIR}/lib/common.sh"'.  Everything that is
# repeated across the scripts lives here, so that the behaviour of logging,
# failing, retrying, and confirming is identical everywhere in the estate.
#
# Scope: this library reads nothing from AWS on its own and writes nothing to
# any AWS region.  It only provides functions; the blast radius of a script is
# defined by the command constants at the top of that script, never here.
#
# Credentials: this library never reads, prints, stores, or exports a secret.
# Access to the AWS APIs always comes from the process environment (the
# standard credential chain: exported environment variables, an ~/.aws/credentials
# profile selected with AWS_PROFILE, or an instance/task role).  If the
# environment is not configured, the AWS CLI fails and the calling script
# reports the failure; that is the intended behaviour, not a bug.
#
# Provided functions (the stable interface of this library):
#   log, warn, err, die        - logging and the fatal-error reporting strategy
#   have_cmd, require_cmd      - toolchain presence tests
#   confirm                    - interactive confirmation (the operator types 'yes')
#   retry                      - a command with exponential backoff and a cap
#   poll_until                 - wait for a condition command to become true
#   run                        - run a command, or print it in --dry-run mode
#   json_query                 - read a JSON document with the python3 core
#   sha256_file                - the sha256 digest of one file
#   usage_error                - print usage to stderr and exit 2
#   install_err_trap           - report the failed line and command on failure
#
# The log line format is 'timestamp level message' on standard error.  Table
# output and machine-readable output go to standard output, so that a log and
# a report can be separated by the caller with 2>/dev/null.
#
# Compatibility: bash 3.2 (the version macOS ships) and later.  No associative
# arrays, no mapfile, no &> redirection, no ${var,,} case conversion.

# The option parsing and the caller options of every script are strict; set
# them here so that a script that forgets is still strict.
set -euo pipefail

# ---------------------------------------------------------------------------
# Repository root and the interpreter of the python core
# ---------------------------------------------------------------------------

# The root of the repository, derived from the location of this library file
# (scripts/lib/common.sh is two levels below the root).  Scripts use it to
# find data/ and tests/fixtures/ relative to the checkout, never relative to
# the caller's working directory.
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]:-}" ]; then
    COMMON_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
else
    COMMON_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
fi
REPO_ROOT=$(cd -- "${COMMON_DIR}/../.." && pwd)
export REPO_ROOT

# The interpreter of the python core.  All JSON parsing of this shell layer is
# delegated to it, so that the shell never depends on a particular version of
# a JSON command-line tool being present.  Preference order: an explicit
# CLOUDOPS_PYTHON override, the project virtual environment, then python3.
if [ -n "${CLOUDOPS_PYTHON:-}" ]; then
    PYTHON_BIN=${CLOUDOPS_PYTHON}
elif [ -x "${REPO_ROOT}/.venv/bin/python" ]; then
    PYTHON_BIN=${REPO_ROOT}/.venv/bin/python
else
    PYTHON_BIN=$(command -v python3 2>/dev/null || echo python3)
fi
export PYTHON_BIN

# ---------------------------------------------------------------------------
# Logging (the reporting strategy of the whole shell layer)
# ---------------------------------------------------------------------------

# The threshold of the log, overridable with the environment variable
# LOG_LEVEL.  One of: debug, info, warn, error.  The default is info.
LOG_LEVEL=${LOG_LEVEL:-info}

_level_rank() {
    # Purpose: map a level name to its numeric rank.
    # Returns: 0 debug, 1 info, 2 warn, 3 error; unknown names rank as info.
    case "$1" in
        debug) echo 0;;
        info)  echo 1;;
        warn)  echo 2;;
        error) echo 3;;
        *)     echo 1;;
    esac
}

log() {
    # Purpose: print one log line 'timestamp level message' to standard error.
    # Usage: log LEVEL MESSAGE...
    local level=$1; shift
    local rank limit
    rank=$(_level_rank "$level")
    limit=$(_level_rank "$LOG_LEVEL")
    [ "$rank" -ge "$limit" ] || return 0
    printf '%s %-5s %s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$level" "$*" >&2
}

warn() {
    # Purpose: log a warning.  The script continues; the operator must read it.
    log warn "$*"
}

err() {
    # Purpose: log an error without exiting; for the paths that still act.
    log error "$*"
}

die() {
    # Purpose: log an error and terminate with the given status.
    # Usage: die MESSAGE [STATUS]   (STATUS defaults to 1)
    local status=${2:-1}
    log error "$1"
    exit "$status"
}

install_err_trap() {
    # Purpose: make any failure report the line number and the failed command
    # before the shell dies, so that a reader of the log can locate the fault
    # in the script itself.  Called once by every operational script.
    trap '_on_error $LINENO "${BASH_COMMAND}" "$?"' ERR
    trap '_on_exit "$?"' EXIT
    trap 'log warn "interrupted by signal"; exit 130' INT TERM
}

_on_error() {
    # Called by the ERR trap: $1 line, $2 command, $3 exit status.
    log error "line $1: command exited $3: $2"
}

_on_exit() {
    # Called by the EXIT trap: $1 the final exit status of the script.
    local status=$1
    if [ "$status" -ne 0 ]; then
        log error "script ${0:-unknown} terminated with status $status"
    fi
}

# ---------------------------------------------------------------------------
# Presence tests and required tools
# ---------------------------------------------------------------------------

have_cmd() {
    # Purpose: say whether a command exists in the PATH.
    # Returns: 0 when available, 1 when not.  Never prints.
    command -v "$1" >/dev/null 2>&1
}

require_cmd() {
    # Purpose: assert that every named tool is installed, or die early with an
    # actionable message.  Called at the top of every operational script.
    # Usage: require_cmd aws python3 [more tools...]
    [ "$#" -gt 0 ] || die "usage: require_cmd NAME [NAME...]"
    local tool
    for tool in "$@"; do
        have_cmd "$tool" || die "required tool not found in the PATH: $tool (install it, then run again)"
        log debug "require_cmd: found $tool at $(command -v "$tool")"
    done
}

confirm() {
    # Purpose: require the operator to confirm an action interactively.
    # The literal word 'yes' (and nothing else) continues the script.
    # Usage: confirm "PROMPT"   (returns 0 on yes, 1 otherwise; non-tty fails)
    local prompt=${1:-proceed?}
    local answer=
    if [ ! -t 0 ]; then
        log warn "confirm: standard input is not a terminal; refusing to assume consent"
        return 1
    fi
    printf '%s [type the word yes to continue]: ' "$prompt" >&2
    IFS= read -r answer || true
    if [ "$answer" = "yes" ]; then
        return 0
    fi
    log info "confirm: the operator did not confirm; aborting the action"
    return 1
}

# ---------------------------------------------------------------------------
# Command execution, with the dry-run discipline
# ---------------------------------------------------------------------------

run() {
    # Purpose: execute a command, or (in --dry-run mode) print it verbatim
    # without executing.  Every mutating command of every script is called
    # through this function, so that 'dry run' means: print every command,
    # execute none.
    # Usage: run COMMAND [ARGUMENT...]
    [ "$#" -gt 0 ] || die "usage: run COMMAND [ARGUMENT...]"
    if [ "${DRY_RUN:-0}" = 1 ]; then
        log info "dry run: would execute: $*"
        return 0
    fi
    log debug "executing: $*"
    "$@"
}

retry() {
    # Purpose: run a command with a retry policy: a bounded number of attempts
    # with exponential backoff between them.  AWS API calls fail transiently
    # (throttling, expired credentials on a stale token); retrying is the
    # correct response, an unbounded loop is not.
    # Usage: retry MAX_ATTEMPTS BASE_DELAY_SECONDS COMMAND [ARGUMENT...]
    #        the delays are BASE, 2*BASE, 4*BASE, ...  capped at 60 seconds.
    # Returns: the exit status of the last attempt.
    local max=$1 delay=$2; shift 2
    case "$max" in (''|[!0-9]*) die "retry: MAX_ATTEMPTS must be a positive integer, got: $max";; esac
    case "$delay" in (''|[!0-9]*) die "retry: BASE_DELAY_SECONDS must be a non-negative integer, got: $delay";; esac
    local attempt=1 status=0
    while :; do
        if "$@"; then
            [ "$attempt" -gt 1 ] && log info "retry: succeeded on attempt $attempt of $max"
            return 0
        fi
        status=$?
        if [ "$attempt" -ge "$max" ]; then
            err "retry: giving up after $attempt attempt(s), last exit status $status"
            return "$status"
        fi
        log warn "retry: attempt $attempt of $max failed (exit $status); sleeping ${delay}s before the next attempt"
        sleep "$delay"
        delay=$((delay * 2))
        [ "$delay" -gt 60 ] && delay=60
        attempt=$((attempt + 1))
    done
}

poll_until() {
    # Purpose: wait until a predicate command succeeds, or a timeout expires.
    # The predicate is any command that exits 0 when the condition is reached
    # (in the operational scripts these are small comparisons of a JSON field
    # extracted with json_query).
    # Usage: poll_until "DESCRIPTION" TIMEOUT_SECONDS INTERVAL_SECONDS COMMAND [ARGUMENT...]
    # Returns: 0 when the condition was reached, 1 when the timeout expired.
    local description=$1 timeout=$2 interval=$3; shift 3
    local deadline now last
    deadline=$(( $(date +%s) + timeout ))
    while :; do
        if "$@"; then
            log info "poll: $description: condition reached"
            return 0
        fi
        last=$?
        now=$(date +%s)
        if [ "$now" -ge "$deadline" ]; then
            err "poll: $description: timed out after ${timeout}s (last predicate exit $last)"
            return 1
        fi
        log debug "poll: $description: not yet (sleeping ${interval}s)"
        sleep "$interval"
    done
}

# ---------------------------------------------------------------------------
# The JSON reader (delegated to the python core; never to a jq assumption)
# ---------------------------------------------------------------------------

json_query() {
    # Purpose: evaluate a Python expression against a parsed JSON document.
    # The shell layer never parses JSON with awk or sed, and never assumes a
    # particular version of a JSON command-line tool: the python core parses
    # it, exactly as the unit tests do.
    # Usage: json_query FILE EXPR
    #   EXPR is evaluated with the parsed document bound to the name 'doc'.
    #   A list prints one item per line; a dictionary prints one JSON object;
    #   None prints an empty line.
    # Example: json_query state.json 'doc["baselines"][0]["name"]'
    local file=$1 expr=$2
    [ -f "$file" ] || die "json_query: no such file: $file"
    _CLOUDOPS_JSON_FILE=$file _CLOUDOPS_JSON_EXPR=$expr "$PYTHON_BIN" - <<'PYTHON_EOF'
import json
import os
import sys

path = os.environ["_CLOUDOPS_JSON_FILE"]
expr = os.environ["_CLOUDOPS_JSON_EXPR"]

try:
    with open(path, encoding="utf-8") as handle:
        doc = json.load(handle)
except (os.OSerror, ValueError) as exc:
    print("json_query: cannot read %s: %s" % (path, exc), file=sys.stderr)
    sys.exit(3)

try:
    # A deliberately narrow evaluation scope: no builtins beyond the handful
    # of total, side-effect-free functions the expressions need.  The
    # expressions come from this repository's own scripts, never from a
    # foreign input file, so the scope is defence in depth, not the boundary.
    value = eval(expr, {"__builtins__": {}},
                 {"doc": doc, "len": len, "any": any, "all": all, "sorted": sorted,
                  "int": int, "str": str, "float": float, "bool": bool,
                  "enumerate": enumerate, "sum": sum, "min": min, "max": max})
except Exception as exc:
    print("json_query: expression failed on %s: %s" % (path, exc), file=sys.stderr)
    sys.exit(3)

if value is None:
    print("")
elif isinstance(value, (list, tuple)):
    for item in value:
        print(json.dumps(item) if isinstance(item, (dict, list)) else item)
elif isinstance(value, (dict,)):
    print(json.dumps(value))
elif isinstance(value, bool):
    print("true" if value else "false")
else:
    print(value)
PYTHON_EOF
}

# ---------------------------------------------------------------------------
# Digests
# ---------------------------------------------------------------------------

sha256_file() {
    # Purpose: print the sha256 digest of one file, portable across macOS
    # (shasum) and Linux (sha256sum).
    # Usage: sha256_file FILE
    local file=$1
    [ -f "$file" ] || die "sha256_file: no such file: $file"
    if have_cmd shasum; then
        shasum -a 256 "$file" | cut -d' ' -f1
    elif have_cmd sha256sum; then
        sha256sum "$file" | cut -d' ' -f1
    else
        die "sha256_file: neither shasum nor sha256sum is installed"
    fi
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

usage_error() {
    # Purpose: print a usage error to standard error, then the usage, exit 2.
    # The usage convention of the whole layer: 0 = ok, 1 = operational failure,
    # 2 = a misuse of the command line, 3 = a bad input file.
    err "usage error: $*"
    usage >&2 || true
    exit 2
}

# Log a single line saying that the library is loaded (visible at debug only).
log debug "common.sh: library loaded (repo root: ${REPO_ROOT})"
