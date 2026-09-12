# Contributing

This repository is an operations toolkit and the configuration estate it
documents: the Python package `cloudops`, the shell automation under
`scripts/`, the Terraform modules under `infra/`, the dashboards under
`monitoring/`, and the manuals at the root. It is published as a portfolio
of high-quality FOSS operations work, and contributions of the same spirit
are welcome. This file is the contract between a contributor and a reviewer;
the operational counterpart lives in `OPERATIONS.md` and
`UPGRADE-RUNBOOKS.md`.

## Getting the environment up

The toolkit targets Python 3.9 through 3.12 and has no runtime dependency
outside the standard library. The supported entry points are the Makefile
targets:

    make venv       # create .venv (uv when present, otherwise python3 -m venv)
    make install    # install the package editable, with the [live] extra
    make test       # the unittest suite via .venv/bin/python
    make lint       # shellcheck over scripts/ and hooks/, ruff or compileall over Python
    make ci         # exactly what the pipeline runs (.github/workflows/ci.yml)

Run the suite with the plain interpreter as well, because that is what the
pipeline matrix runs:

    python3 -m unittest discover -s tests -p 'test_*.py' -v

The suite is network-free and credential-free; a test that needs either is
misfiled. The live mode (`import` of the optional boto3 dependency) happens
only in `cloudops/aws_live.py` and only when the operator asks for it; keep
it that way.

## Style: shell

Every script under `scripts/` follows the house rules; the CI matrix lints
them on Linux and macOS runners (`bash 3.2` and BSD userland included), so
what follows is enforced, not decorative:

- `set -euo pipefail` (or the `set -o errset -o pipefail -o nounset` form) at
  the top, and the error trap of `scripts/lib/common.sh` (`install_err_trap`)
  for anything that talks to an API.
- A `usage` block and a `getopts` loop; `--help` prints the usage and exits
  0, and a wrong command line exits 2 with the usage on stderr.
- `--dry-run` on every script that can change anything: it prints the exact
  `aws` commands verbatim and executes nothing. The reviewer reviews the
  dry-run output; the operator runs what the reviewer saw.
- Shellcheck-clean at the severity the CI job runs (`make lint-shell`). No
  shellcheck disable comment without a reason beside it.
- The header block: purpose, the exact scope of what the script reads and
  writes, the credential statement, the failure behaviour with its exit
  codes, and a `See also` line. `scripts/ec2-drain-instance.sh` is the model.
- No JSON parsing with text tools. When a script needs structured reading,
  it calls the Python core (`cloudops.patch.load_baselines` is the
  existing bridge); a jq of a particular vintage is not a dependency anyone
  may add to a control node.

## Style: Python

- The core package is standard-library only. The one place a third-party
  import may appear is `cloudops/aws_live.py`, deferred into the function
  that needs it, raising the installation hint when the extra is absent.
- The tests are `python3 -m unittest`, no pytest constructs, no fixtures
  directory beyond `tests/fixtures/` (the canned inventories, state export
  and describe export). New behaviour arrives with a test in the same pull
  request; the suite must pass on 3.9, 3.11 and 3.12.
- Docstrings state purpose, returns, raises, and side effects, the way
  `cloudops/scan.py` and `cloudops/drift.py` write them. Output is
  reproducible: the scanner sorts worst-first and then by host id so that
  two runs on the same bytes print byte-identical reports.
- Exit statuses are interface: 0 clean, 1 a finding at or above the floor,
  2 a data problem. Never repurpose them; schedulers branch on them.
- Formatting follows the project's tooling: `make fmt` (ruff when present)
  and `terraform fmt -recursive`.

## Commit messages

Conventional Commits, the subset the estate uses: `feat`, `fix`, `docs`,
`refactor`, `test`, `chore`. The subject is the imperative mood in the
present tense, under about 72 characters, without a trailing period:

    feat(scan): add a --severity floor to the scan output
    fix(drift): treat a resource present on one side only as CRITICAL
    docs(runbooks): record the replication-lag guard of the blue/green switchover
    test(eol): pin the 90-day approaching window against a leap boundary
    chore(ci): run the lint matrix on macOS as well as Linux

The body, when the change is not self-evident, states why, names the file
or datum the claim rests on, and cites the runbook or ADR a reader will
want next. A commit that changes a lifecycle date cites the `data/eol-catalog.json`
entry it touches by engine and version_track, so the diff review is not a
memory test.

## The pull request process

1. Branch from `main`, one coherent change per pull request. Open it against
   `main`; the Atlantis configuration (`atlantis.yaml`) admits only this
   repository and refuses everything else, and it forbids draft pull
   requests so a change is either in review or it is not.
2. The CI workflow (`.github/workflows/ci.yml`) is the floor: the lint job
   on Linux and macOS, the unittest matrix across the supported Pythons,
   the Terraform gates. A red pipeline is not reviewed; the Atlantis apply
   requirements refuse an apply against a pull request that is not
   mergeable, so "reviewed" and "green" cannot come apart.
3. Atlantis is the review bot of the infrastructure half: it runs the plan
   on every pull request and renders the diff into the thread. A reviewer
   who is not the author approves; `infra/envs/prod` additionally requires
   the `project_maintainers` scope. `atlantis plan` and `atlantis apply`
   are the verbs; there is no third door, and a laptop apply against
   production is not an emergency workaround but a policy incident.
4. Documentation is reviewable code. A runbook step that changes changes the
   Verification and Abort sections of the same file in the same commit;
   every date claim keeps its `source:` line into
   `data/eol-catalog.json`. The figures of a demo or a manual carry their
   reference-sandbox label.

## The release process

- Releases are tagged from `main` and carry the version of `pyproject.toml`
  and `cloudops.__version__`, which move together in the release commit.
- The release notes come from `docs/changelog.md` (see below) and the
  release itself is an artifact build of the CI gates, not a person with
  permissions: the same `make ci`, then the build of the distribution and
  the tag.
- A release that carries a behaviour change of the exit-status contract or
  of the catalog schema gets its note under the Changed section of the
  changelog with the affected file named, because schedulers and runbooks
  read those contracts.

## Security policy

- Report a vulnerability by private disclosure to the maintainers through
  the advisory system of the hosting forge (a private security advisory),
  not through the public issue tracker. Do not open a public issue that
  names a vulnerability, not even a vague one; the issue tracker is the
  first page an attacker reads.
- Handle a suspected issue privately first: the maintainer confirms it in
  the advisory, fixes it on a private branch where the exposure warrants
  it, and ships it in a release whose changelog entry describes the class
  of the flaw without operationalising it.
- A disclosure is answered within the SEV1 acknowledgement window of the
  severity ladder in `OPERATIONS.md` when it names live exposure, and
  within the SEV3 window otherwise. Publication of the details waits for
  the fix plus a coordinated grace period, agreed in the advisory thread.
- This is a portfolio repository of reference configuration; nothing in it
  is deployed at any employer of the author, and the absence of a target is
  not a reason to skip the private channel -- the toolkit runs on other
  people's control nodes.

## License

The repository is licensed under the Apache License 2.0 (the full text in
`LICENSE`):

    Copyright 2026 Arees Manesia

    Licensed under the Apache License, Version 2.0 (the "License"); you may
    not use this file except in compliance with the License. You may obtain a
    copy of the License at http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
    License for the specific language governing permissions and limitations.

By contributing, you grant your contributions under the same license and
you attest that you may: the contribution is yours to license, or your
employer's paper says so. Add a `NOTICE` entry when a contribution imports
material that carries attribution duties of its own; the `NOTICE` file
travels with redistributed copies, the way section 4 of the license asks.
