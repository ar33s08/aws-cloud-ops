# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and the project adheres to [semantic versioning](https://semver.org/).

## [Unreleased]

### Added

- Nothing pending at the time of the 1.0.0 cut; incoming changes land under
  this section first, as the contributing guide asks.

## [1.0.0] - 2026-09-12

The first public cut: the complete day-two toolkit, the reference
configuration estate, and the documentation set that ties them together.

### Added

- The `cloudops` Python toolkit (standard-library core): the fleet
  inventory model (`cloudops/inventory.py`), the end-of-life classification
  engine with its semver comparator and 90-day approaching window
  (`cloudops/eol.py`), the fleet scanner and the ring-ordered patch queue
  (`cloudops/scan.py`), the patch baselines and compliance model
  (`cloudops/patch.py`), the state-versus-live drift detector with its
  `CRITICAL_ATTRS` security classification (`cloudops/drift.py`), the four
  renderers (table, csv, json, md; `cloudops/report.py`), and the
  `cloudops` command line with the subcommands `scan`, `patch-queue`,
  `drift`, `baseline-list` and `snapshot` and the scheduler-facing exit
  contract 0/1/2 (`cloudops/cli.py`).
- The opt-in live mode (`cloudops/aws_live.py`): the deferred-dependency
  shim to the describe APIs, read-only, credential-chain only.
- The lifecycle catalog `data/eol-catalog.json` for the image classes
  (Amazon Linux 2, Amazon Linux 2023), the managed database engines
  (MySQL, PostgreSQL, MariaDB) with their standard- and premium-support
  dates, the cache engines (Redis, Valkey) with the extended-support
  posture, and the cluster platform (EKS 1.29 through 1.34); every entry
  carries its vendor `source` URL and fetch date.
- The patch-program definition `data/patch-baselines.json`: the baselines
  AL2023-SECURITY-30D, AL2-MIGRATE-ONLY and DB-AGENT-SECURITY with their
  approval records, and the three ring groups PROD-CANARY, PROD-STANDARD
  and PROD-CRITICAL with their cron schedules, cutoffs and overlaps.
- The shell automation under `scripts/`, all shellcheck-clean, all with
  `--dry-run`, sharing `scripts/lib/common.sh`: `ssm-run-command.sh` (the
  audited Run Command work-horse), `patch-compliance-scan.sh` (the
  measurement half, live and offline modes), `patch-schedule.sh` (the
  actuation half with the canary guard), `patch-baseline-register.sh` (the
  approval-gated registration), `ec2-drain-instance.sh` (the Standby drain
  with its documented return-to-rotation), and `bastion-userdata.sh`
  (the fail-closed bastion bootstrap that removes SSH as an access path).
- The Terraform module set under `infra/modules/`: `network` (the
  private-only VPC, the NAT placement, the SSM/KMS/Logs endpoints, the flow
  logs), `rds` (the engine-gated database with the Secrets-Manager-managed
  password, the plan-time end-of-life preconditions, the replica set), and
  `ec2-bastion-asg`, with `infra/envs/dev` and `infra/envs/prod` composing
  them.
- The change gate `atlantis.yaml`: the repository allow list, the
  mergeable/approved/fail-closed apply requirements, the per-project
  environment map, the production maintainer scope, and the plan-only
  drill repository.
- The day-two cluster workloads under `k8s/`: the daily scan CronJob
  (`cloudops-daily-scan`, 06:00 UTC), the verdict endpoint Deployment with
  its fully declared probes, and the namespace.
- The dashboard as code `monitoring/datadog-dashboard.json`: the four
  headline gauges (hosts past end-of-life, hosts approaching within 90
  days, patch compliance, drift findings) with their zero-threshold
  conditional formats, the trend widgets, the per-host verdict table, and
  the change-event timeline.
- The continuous-integration pipeline `.github/workflows/ci.yml`: the
  lint matrix on Linux and macOS, the unittest matrix on Python 3.9/3.11/
  3.12, and the Terraform gates, all credential-free and read-only.
- The unittest suite under `tests/` against the canned fixtures
  (`fleet-inventory.json`, `compliance-reports.json`, `state-export.json`,
  `live-describe.json`) and the Makefile targets `venv`, `install`, `test`,
  `lint`, `fmt`, `tf-validate`, `scan`, `report`, `patch-scan` and `ci`.
- The documentation set: `README.md`, `ARCHITECTURE.md`, `INSTALL.md`,
  `EOL-REMEDIATION-PROGRAM.md`, `OPERATIONS.md`, `UPGRADE-RUNBOOKS.md` (the
  six runbooks: the image migration, the RDS minor, the RDS major by
  blue/green, the ElastiCache upgrade and failover test, the EKS control
  plane one minor at a time, and drift remediation), `CONTRIBUTING.md`,
  the architecture decision records under `docs/adr/` (0001 remote state,
  0002 NAT per availability zone, 0003 blue/green for majors) and the
  operational-readiness review of record
  `docs/OPERATIONAL_READINESS.md`.

### Changed

- Nothing; this is the first release, so there is no prior behaviour this
  cut changed against.

### Fixed

- Nothing; defects fixed after the cut are recorded under their own version
  entries, and the pre-release corrections of the draft tree were folded
  into the initial content rather than recorded here.

### Removed

- Nothing; nothing was removed from an earlier public version.
