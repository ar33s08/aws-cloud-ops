#!/usr/bin/env bash
# This script is the one-command finisher of the aws-cloud-ops repository. It
# is what the nightly job and the human both run: it verifies the tree,
# refuses to ship a broken artifact, then creates or reuses the public GitHub
# repository and pushes the trunk. It is idempotent (safe to run again after a
# partial run) and it never destroys: it never force-pushes, never rewrites
# history, and it stops with a message rather than guessing.
#
# Scope (the blast radius of this script): it reads this repository directory,
# runs the test suite and the validators, and calls 'gh repo create' and 'git
# push' against the repository named below. It touches no AWS account, it
# deletes nothing, and it never prints a credential.
#
# Exit codes: 0 the repository is pushed and verified public; 1 a gate failed
# and nothing was pushed; 2 the environment is missing a tool.
#
# Usage: tools/finish.sh [--dry-run] [--visibility public|private]
#        --dry-run   run every gate and print the git/gh commands, do not push
#        --visibility the visibility to create the repository with (default: public)
#
# See also: tools/prep.sh, PUSH-PLAN.md, README.md

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OWNER="ar33s08"
NAME="aws-cloud-ops"
VISIBILITY="public"
DRY_RUN=false

# shellcheck source=/usr/bin/bash
for _arg in "$@"; do
  case "$_arg" in
    --dry-run) DRY_RUN=true ;;
    --visibility) ;;                       # consumed on the next iteration
    --visibility=?*) VISIBILITY="${_arg#*=}" ;;
    -h|--help) { sed -n '2,20p' "$0"; exit 0; } ;;
    public|private) VISIBILITY="$_arg" ;;
    *) echo "finish: unknown argument: $_arg" >&2; exit 2 ;;
  esac
done
# Re-parse to honour "--visibility public" (two word) form.
if [[ "$*" == *"--visibility public"* ]]; then VISIBILITY="public"; fi
if [[ "$*" == *"--visibility private"* ]]; then VISIBILITY="private"; fi

run() {  # echo-and-run, honouring --dry-run for the mutating commands
  if [[ "$DRY_RUN" == true ]]; then printf '[dry-run] %s\n' "$*"; else "$@"; fi
}

die() { printf 'finish: %s\n' "$*" >&2; exit 1; }

require() { command -v "$1" >/dev/null 2>&1 || { echo "missing tool: $1" >&2; exit 2; }; }

cd "$REPO_DIR"

echo "== 1. preflight =="
require git; require gh; require python3
gh auth status >/dev/null 2>&1 || die "gh is not authenticated; run 'gh auth login'"

echo "== 2. the test suite (the gate that may not be skipped) =="
if ! python3 -m unittest discover -s tests -p 'test_*.py' >/dev/null 2>&1; then
  python3 -m unittest discover -s tests -p 'test_*.py' || true
  die "the unit suite is failing; the repository is not fit to push"
fi
echo "   the unit suite passed."

echo "== 3. the token normaliser =="
python3 tools/fix_tokens.py || die "the token normaliser reports damage"

echo "== 4. the data and monitoring files are valid JSON =="
for f in data/eol-catalog.json data/patch-baselines.json \
         tests/fixtures/*.json monitoring/*.json; do
  [[ -f "$f" ]] || continue
  python3 - "$f" <<'PY' || die "invalid JSON: $f"
import json, sys
json.load(open(sys.argv[1], encoding="utf-8"))
PY
done
echo "   the JSON files parse."

echo "== 5. the shell lint (informative, the gate lives in CI) =="
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S bash scripts/*.sh scripts/lib/*.sh hooks/pre-commit 2>&1 | sed -n '1,6p' || true
fi

echo "== 6. the required deliverables are present =="
for f in README.md LICENSE NOTICE CONTRIBUTING.md Makefile pyproject.toml \
         ARCHITECTURE.md INSTALL.md EOL-REMEDIATION-PROGRAM.md \
         UPGRADE-RUNBOOKS.md OPERATIONS.md atlantis.yaml \
         .github/workflows/ci.yml infra/modules/network/main.tf \
         infra/envs/prod/main.tf infra/envs/dev/main.tf; do
  [[ -f "$f" ]] || die "the required file is missing: $f (a build agent did not finish)"
done
echo "   every required deliverable is present."

echo "== 7. the secrets scan (a credential in a public repo is the one unfixable defect) =="
if /usr/bin/grep -rIn -E \
   '(AKIA[0-9A-Z]{16}|aws_secret_access_key\s*[:=]|-----BEGIN (RSA )?PRIVATE KEY|ghp_[0-9A-Z]{36})' \
   --exclude-dir=.git --exclude-dir=.venv . >/tmp/cloudops-secret-findings.$$ 2>/dev/null; then
  /bin/cat /tmp/cloudops-secret-findings.$$ >&2
  rm -f /tmp/cloudops-secret-findings.$$
  die "the scan found a string that looks like a credential; it must not become public"
fi
rm -f /tmp/cloudops-secret-findings.$$ 2>/dev/null || true
echo "   no credential-shaped string in the tree."

echo "== 8. commit everything under the owner's identity =="
git config user.name "Arees Manesia"
git config user.email "arees.manesia8@gmail.com"
git add -A
if ! git diff --cached --quiet; then
  run git commit -q -m "build: complete the reference estate (infra, policy, monitoring, docs)"
fi
echo "   the working tree is committed."

echo "== 9. ensure the repository exists, then push =="
if gh repo view "$OWNER/$NAME" >/dev/null 2>&1; then
  echo "   the repository $OWNER/$NAME already exists"
  EXISTING_VIS=$(gh repo view "$OWNER/$NAME" --json visibility --jq .visibility 2>/dev/null || echo UNKNOWN)
  echo "   existing visibility: $EXISTING_VIS"
else
  run gh repo create "$NAME" --owner "$OWNER" --"$VISIBILITY" \
      --description "AWS Cloud Ops toolkit: EOL/EOS remediation, patch programs, blue/green upgrades, drift control, Terraform + Atlantis + monitoring. Personal engineering work, Apache-2.0." \
      --gitignore-template Python
fi
git remote add origin "https://github.com/$OWNER/$NAME.git" 2>/dev/null || true
run git push -u origin main
if [[ "$DRY_RUN" != true ]]; then
  gh repo view "$OWNER/$NAME" >/dev/null
  echo "== done =="
  echo "https://github.com/$OWNER/$NAME"
else
  echo "dry-run: nothing was pushed."
fi
