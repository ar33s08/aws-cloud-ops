# Installation and setup

This file is the installation guide of the toolkit. The core of the package
has no third-party dependencies; the optional live mode needs the SDK of the
platform, and the infrastructure layer needs the provisioning tool. Nothing
here needs a write to a system location: every target of an installation is
this repository directory or the virtual environment inside it.

## 1. Prerequisites

| component | minimum version | needed for | check with |
|---|---|---|---|
| Python | 3.9 | the toolkit core | `python3 --version` |
| GNU Make | any | the targets below | `make --version` |
| boto3 (optional) | 1.34 | live mode (`cloudops --live`) | `pip show boto3` |
| Terraform or OpenTofu | 1.5 | the plan and the apply of `infra/` | `terraform version` |
| AWS CLI | 2.x | the scripts of `scripts/` | `aws --version` |
| Git | any | the hooks and the history | `git --version` |

The tooling is installed per user, with the package manager of your choice.
On a Debian derivative the usual sequence is
`doas apt-get update && doas apt-get install -y make git curl unzip`;
the provisioning tool then unpacks into `~/.local/bin` (the release
archives of the tool provide the binary; no system package is required), and
the SDK installs into the virtual environment below — never into the system
interpreter, and never through the `sudo` route of `pip install`.

## 2. The standard environment

```sh
make venv        # creates .venv (python -m venv, or uv venv when uv is present)
make install     # installs the package into .venv in editable mode, with the live extra
```

`make install` is idempotent; the second run is a no-op. The console entry
point is named `cloudops`; when you prefer not to activate the environment,
invoke the program through the Makefile or through `./.venv/bin/python -m
cloudops.cli`.

## 3. Verifying the installation

```sh
make test        # the unit suite (no network, no credentials required)
make lint        # the linters that are present on the host; skips what is not installed
```

A first look at the scanner, against the canned reference fleet:

```console
$ cloudops scan --inventory tests/fixtures/fleet-inventory.json \
      --eol-catalog data/eol-catalog.json --format table
fleet status  ok=9  eol=2  eos=3  eol-approaching=0  security-advisory=0  total=14
...
```

The exit status of the scan is `1` when the fleet carries anything past its
end-of-support date — which is what makes it usable as a scheduled gate.

## 4. Optional: live mode

Live mode reads the same describe APIs the console reads; it writes nothing.
It is opt-in because it pulls in the SDK of the platform:

```sh
make install          # installs with boto3 included
export AWS_DEFAULT_REGION=us-east-1
```

Credentials are resolved through the normal chain of the platform: the
process environment, the shared credentials file
(`~/.aws/credentials`, in the profile form), an instance profile on the
control node, or a single sign-on session (`aws sso login`). The toolkit
never reads a key from the terminal, never prints one, and never writes one
to any file. When a named profile is required, pass `--profile NAME` to the
command; do not export the pair of keys into the environment of a shell that
is shared with a colleague.

## 5. Optional: the infrastructure layer

```sh
cd infra/envs/dev
terraform init -backend=false -input=false -upgrade   # -backend=false for a read-only review
terraform validate
terraform plan        # requires a configured state backend and credentials
```

The state is remote and is locked (see `docs/adr/0001-remote-state.md`);
the plan of a pull request is the only apply path (see `atlantis.yaml`).
For the one-off review of a module, `make tf-validate` from the repository
root runs `terraform validate` over every environment, with the backend
disabled.

## 6. Uninstallation

Remove the virtual environment and the caches:

```sh
make clean
```

The clean target removes `.venv`, the build directories, and the caches of
the tests. It does not touch the fixtures, the catalog, or your history.

## 7. Where to look next

* `README.md` — the index of the repository.
* `ARCHITECTURE.md` — the theory of the estate.
* `EOL-REMEDIATION-PROGRAM.md` — the program the toolkit serves.
* `UPGRADE-RUNBOOKS.md` — the procedures, one per upgrade.
* `docs/man/` — the manual pages of the scripts (`man ./docs/man/<page>`).
