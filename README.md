# aws-cloud-ops

**Operations toolkit for AWS platform engineers** — a complete, production-shaped program for
running a large-scale AWS estate with **zero to minimal downtime**: end-of-life (EOL) /
end-of-support (EOS) remediation, large-scale patching programs, blue/green database engine
upgrades, infrastructure drift detection, IAM hardening, and CloudWatch/DataDog monitoring.

Everything is free: free as in speech and free as in free beer (see `LICENSE`).
You can use it, change it, and share it — no warranty, no liability; use at your own risk.

![CI](https://github.com/ar33s08/aws-cloud-ops/actions/workflows/ci.yml/badge.svg)
![License](https://img.shields.io/badge/license-apache--2.0-blue)
![Python](https://img.shields.io/badge/python-3.9%20--%203.12-brightgreen)
![Terraform](https://img.shields.io/badge/terraform-≥1.5-brightgreen)

---

## Contents (module index)

| Part | Title | Where to look |
|------|---------------------------|------------------------------------|
| 1 | Reference architecture | `ARCHITECTURE.md` |
| 2 | Decision records (ADR) | `docs/adr/` |
| 3 | EOL/EOS remediation program | `EOL-REMEDIATION-PROGRAM.md` |
| 4 | Upgrade runbooks (RDS, ElastiCache, AMI, K8s) | `UPGRADE-RUNBOOKS.md` |
| 5 | Security hardening | `SECURITY-HARDENING.md` |
| 6 | Day-2 operations & SLO | `OPERATIONS.md` |
| 7 | Python toolkit (`cloudops`) | `cloudops/`, usage in `INSTALL.md` |
| 8 | Shell automation (AWS CLI/SSM) | `scripts/`, see `--help` of each script |
| 9 | Terraform modules (registry) | `infra/modules/`, environments in `infra/envs/` |
| 10 | Atlantis policy (plan/apply via pull) | `atlantis.yaml` |
| 11 | Monitoring (CloudWatch + DataDog) | `infra/modules/observability/`, `monitoring/` |
| 12 | Test suite (`make test`) | `tests/` |
| 13 | Continuous integration | `.github/workflows/ci.yml` |

## Why this repository exists

The day-to-day job of a Cloud Operations Engineer / Systems Administrator on a large AI platform
is *not* building features. It is keeping the estate healthy:

* **Versions.** Operating systems, database engines, managed-service engines, runtimes and
  third-party dependencies all carry end-of-life dates and end-of-support dates. A fleet that is
  two minor releases behind today is a fleet that is one CVE away from an incident report.
* **Patching.** Patch management is a *program*, not a task: baselines, maintenance windows,
  canary stages, rollback plans, and a record of every action taken (`audit log`).
* **Upgrades.** Major version upgrades (MySQL 5.7 → 8.0, Redis 6.x → 7.x, Amazon Linux 2 → 2023,
  Kubernetes 1.2x → 1.2y) need a blue/green strategy, snapshot backups, checksums, restore drills
  and — above all — a way to minimize downtime. `pg_ctl` for RDS is `scripts/rds-*.sh`.
* **Drift.** Someone applies a change in the console at 02:00. The state file (Terraform state)
  and the configuration (the `.tf` files) then differ. `cloudops drift` finds the difference and
  `atlantis apply` resolves it, through a pull request, with a reviewer.
* **Automation.** Manual toil is the enemy. Every recipe in this repository is idempotent,
  loggable, dry-runnable, and schedulable: `make scan`, `make patch-scan`, and
  `make report` are the routines a scheduler of the platform runs on a timer.

## Quick start (installation)

Read `INSTALL.md` for the complete installation instructions. In short:

```sh
make venv        # create .venv (standard environment, no root privileges needed)
make install     # pip install -e '.[live]'   (live mode needs boto3; unit mode does not)
make test        # run the test suite (stdlib-only, no network, no AWS account)
make lint        # shellcheck + ruff + terraform fmt -check (when available)
```

Scan a fleet inventory file (the "canned" inventory of the estate, JSON or CSV):

```console
$ cloudops scan --inventory tests/fixtures/fleet-inventory.json --eol-catalog data/eol-catalog.json
 HOST                  SERVICE           ENGINE  INSTALLED                AVAILABLE  STATUS  REASON
 i-0a1b2c3d4e5f60718   ec2:ami                   amzn-2-amd-64-2.0.2025...  2023.6     EOL     end of life on 2026-06-30 -> migrate
 prod-ai-platform      eks                       1.30                     1.36       EOL     past end of extended support -> upgrade
 cache-prod-redis-ol   elasticache:redis redis   5.0.6                    7.1        EOS     std support ended 2026-01-31 -> Valkey
 db-prod-mysql-01      rds:db            mysql   5.7.44                   8.4        EOS     blue/green to 8.0 or 8.4
$ cloudops drift --state tests/fixtures/state-export.json --live tests/fixtures/live-describe.json
 SEVERITY  ADDRESS                              ATTRIBUTE                     EXPECTED  OBSERVED
 CRITICAL  module.ec2...web                     security_groups               sg-hardened, sg-bastion  + sg-debug-open
 CRITICAL  module.ec2...web                     metadata_options.http_tokens  required  optional
$ cloudops patch-queue --inventory tests/fixtures/fleet-inventory.json \
      --eol-catalog data/eol-catalog.json --format csv --out reports/patch-queue.csv
```

The scan exits `1` when the fleet carries anything past its end-of-support
date, which is what makes it usable as a scheduled gate; see `OPERATIONS.md`.

Provision the reference architecture (dry run first — plan, then apply):

```sh
cd infra/envs/prod && terraform init && terraform plan -out=tf.plan # plan
terraform show tf.plan | less                                        # inspect the changes
# atlantis apply — or, if you must, terraform apply 'tf.plan'      # apply
```

## Architecture at a glance

```text
                         ┌──────────────────────────────────────────┐
 pull request ─────────► │                 atlantis                 │ plan / apply / import
                         │   (policy: atlantis.yaml, automerger)   │ unlock repo
                         └────────────────┬─────────────────────────┘
                                          │ terraform modules (registry: local)
        ┌─────────────────────────────────┼──────────────────────────────────────┐
        │                                 │                                      │
 ┌──────▼──────┐                 ┌────────▼────────┐                    ┌─────────▼────────┐
 │  network    │                 │  ec2-bastion-asg │                   │  rds / elasticache│
 │ vpc, subnets│                 │ ami, lt, launch  │                   │ engine versions  │
 │ sgs, rt     │                 │ template, asg    │                   │ parameter groups │
 └──────┬──────┘                 └────────┬─────────┘                    └─────────┬────────┘
        │                                 │                                      │
        └───────────────────────────────────┼──────────────────────────────────┘
                                            │
                  ┌─────────────────────────┼───────────────────────────┐
                  │                         │                           │
          ┌───────▼───────┐        ┌───────▼───────┐          ┌────────▼─────────┐
          │  iam (hardening│        │ observability  │          │  ssm (patching,  │
          │  policies, roles│        │ cloudwatch,    │          │  inventory,      │
          │  permissions    │        │ datadog, alarm │          │  run command,    │
          └────────────────┘        │ metrics, logs  │          │  session manager)│
                                    └────────────────┘          └──────────────────┘
```

(Drawings, if any, conform to the conventions of the `architecture-diagram` skill; if you find
mistakes in this documentation, please report them as an issue — patches welcome.)

## Features

* **EOL/EOS scanner** — compares installed versions against a catalog of end-of-life dates and
  end-of-support dates for EC2 AMIs, RDS database engines (Aurora MySQL, Aurora PostgreSQL,
  MySQL, MariaDB, PostgreSQL, Oracle), ElastiCache (Redis, Valkey), and EKS. Reports the status
  (`OK`, `EARL`, `EOL`, `EOS`, `SEC`) and a recommended action, sorted by severity.
* **Patch baselines** — patch baseline definitions per instance class (OS class, engine class),
  in the shape the AWS Systems Manager (SSM) Patch Manager accepts; register them with
  `scripts/patch-baseline-register.sh` and scan compliance with `scripts/patch-compliance-scan.sh`.
* **Safe upgrades** — snapshot backup first, then minor version upgrade; blue/green for major
  versions, with replication (read replicas), restore from backup, and point-in-time recovery
  (PITR). `scripts/rds-major-upgrade-bluegreen.sh` implements the full sequence; read its header
  comments for the preconditions (`ulimit` the blast radius, `nice` the I/O impact).
* **Infrastructure as code** — Terraform modules with a sane versioning policy (`x.y.z`);
  semantic versioning; the registry is this repository; environments are isolated (dev, prod);
  the state is locked (S3 + DynamoDB + versioning + MFA delete, if configured).
* **Drift control** — `cloudops drift` compares the live resource inventory (describe) with the
  state file and prints a unified diff; Atlantis keeps the plan and the apply reviewable.
* **Monitoring** — a metric each, a metric in the metrics dictionary, alarm rules for CloudWatch
  and a DataDog dashboard as code (JSON) with monitors, monitor alerts and monitor templates.
* **Hardening** — least privilege, no root privileges, no public subnets, no `0.0.0.0/0`,
  IMDSv2 tokens required, KMS at rest, TLS in transit, log every action (audit), check hashes.

## Standards and conventions

* `set -euo pipefail` in every shell script, `getopts` for the options, `--help` for usage
  messages (cf. `man` pages in `docs/man/`), and `--dry-run` where a command changes anything.
* Commits follow the conventional commits specification: `feat:` `fix:` `docs:` `refactor:`
  `test:` `chore:`; imperative mood, present tense in changelogs (`docs/changelog.md`).
* Terraform: `terraform fmt`, `terraform validate`, `terraform test` (`.tftest`), module version
  constraints `~> x.y`; variables, locals and outputs documented in each module's README stub.
* Python: type hints, `dataclasses`, `unittest`; the standard library where it makes sense; no
  third-party hard dependencies in the core (boto3 is an optional, installable dependency).

## Version numbering, releases

`x.y.z` (major.minor.patch), semantic versioning. See `CHANGELOG.md`.
Compatibility: Python ≥ 3.9; Terraform ≥ 1.5; AWS CLI v2; bash ≥ 3.2 (macOS ships 3.2, Linux
ships 5.x); GNU utilities, GNU Make.

## Contributing

Read `CONTRIBUTING.md`, sign the commits if you sign your commits, keep the test suite green,
and make sure all CI checks pass before you push. Patches to the documentation are as welcome as
patches to the code — the documentation is the manual, and the manual is the product.

## License

Apache License 2.0, January 2004. See `LICENSE` and `NOTICE`.

## Notice

This is a personal engineering portfolio project, not affiliated with, endorsed by, or
sponsored by Amazon, AWS, Hashicorp, DataDog, or any other company mentioned in it.
Company names, product names, and version numbers are the trademarks of their respective owners,
registered or otherwise, and are used for identification purposes only.
The metrics in `OPERATIONS.md` and in the "measured" tables are from a local reference environment
(a sandbox of examples) and are **not** production results from any employer.
