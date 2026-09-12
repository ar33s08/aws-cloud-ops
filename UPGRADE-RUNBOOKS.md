# Upgrade runbooks

This file is the runbook collection of the estate. A runbook is the document
an operator follows when the change is large enough that memory is not a
sufficient control: each one carries the fixed skeleton *Purpose;
Preconditions; Procedure; Verification; Rollback; Abort criteria; Source*,
and an operator executes a section in order, without skipping ahead.

Three conventions bind every runbook below.

- Nothing in a runbook touches the estate directly. Infrastructure changes
  are made by a pull request that Atlantis plans and a reviewer approves
  (the policy is `atlantis.yaml`); the runbook prepares the change, the pull
  request carries it.
- Every lifecycle date quoted here is transcribed from an entry of
  `data/eol-catalog.json` and carries a `source:` line naming that entry.
  Where the runbook gives an AWS CLI command, the same command name is the
  name of the script that will wrap it; a wrapper that does not exist yet is
  marked *not yet in `scripts/`* and the raw AWS CLI command is given in its
  place.
- All figures measured on the sample fleet are labelled *reference sandbox*,
  which means: captured from the canned fixtures and the golden pipeline of
  the repository, illustrative, and not a promise about your account.

Runbook index:

1. [EC2 image migration: Amazon Linux 2 to Amazon Linux 2023](#runbook-a)
2. [RDS minor engine upgrade](#runbook-b)
3. [RDS major engine upgrade (blue/green)](#runbook-c)
4. [ElastiCache engine upgrade and failover test](#runbook-d)
5. [EKS control plane and node group upgrade](#runbook-e)
6. [Drift remediation](#runbook-f)

---

<a id="runbook-a"></a>
## Runbook A: EC2 image migration, Amazon Linux 2 to Amazon Linux 2023

### Purpose

Move the instance fleet off the Amazon Linux 2 image class. The class
reached its end of life on 2026-06-30, and the catalog action line is
explicit that the remedy is a rebuilt image, not an in-place package
campaign.
(source: the entry with `engine` "al2" in `data/eol-catalog.json`, fetched
2026-09-12 per the `_sources` block of the same file.)
The AL2 baseline in `data/patch-baselines.json` is named `AL2-MIGRATE-ONLY`
and states in its own description that the migration supersedes every other
action; the patch programme keeps the agent alive only until this runbook
runs. The decision of record is `docs/adr/0001-remote-state.md` (the state
change is a reviewed apply) and the ring order below matches the canary
guard of `scripts/patch-schedule.sh`.

### Preconditions

- The golden pipeline has produced an Amazon Linux 2023 AMI and the
  operator knows its id; the pipeline output, not the console, is the only
  accepted source of an AMI id.
- The scan of the fleet shows which instances still carry the old class:

      cloudops scan --inventory tests/fixtures/fleet-inventory.json \
        --eol-catalog data/eol-catalog.json --format md

  (against live data, pass the live inventory export; the fixture invocation
  above is the reference sandbox demonstration of the same command).
- The launch template of each affected Auto Scaling group is under the
  Terraform configuration of the estate, so the AMI id change arrives as a
  code change and not as a console edit.
- The drain tooling is at hand: `scripts/ec2-drain-instance.sh` moves an
  instance to Standby with `aws autoscaling put-instance-states` and
  verifies it with `aws autoscaling describe-instance-health-details`; its
  documented return-to-rotation command is the rollback of any individual
  instance that must leave maintenance early.

### Procedure

1. Rebuild in the golden pipeline. The pipeline bakes the AL2023 image with
   the standard agent set; the operator's only action is the build request
   and the reading of the resulting AMI id.
2. Pin the new AMI id in the configuration: the launch template data of the
   module (`infra/modules/ec2-bastion-asg` and the application groups
   likewise) takes the new id as an attribute change, together with a bump
   of the template version.
3. Open the pull request. Atlantis runs `terraform fmt -check`, `init`, and
   `plan` as the pre-workflow and workflow steps of `atlantis.yaml`; the
   plan rendered into the pull request is the artifact of record. A
   reviewer who is not the author approves, and the maintainer runs
   `atlantis apply` on the approved pull request.
4. Refresh the instances per Auto Scaling group, one ring at a time, in the
   ring order canary, then standard, then critical. The refresh is the
   native instance refresh of the Auto Scaling service
   (`aws autoscaling start-instance-refresh` with the new template version,
   then `aws autoscaling describe-instance-refresh` until it reports
   `Successful`); groups that need a manual hand use
   `scripts/ec2-drain-instance.sh` per instance and drain the host before
   its replacement arrives.
5. Re-run the scan after each ring has converged, and let the canary guard
   of `scripts/patch-schedule.sh` be the pattern: the next ring does not
   start while the previous ring is red.

### Verification

- `cloudops scan --inventory <live-inventory> --eol-catalog
  data/eol-catalog.json --severity eos` exits 0, which means (the exit-code
  contract of `cloudops/cli.py`) that no host remains at end-of-support or
  worse.
- `aws autoscaling describe-instance-refresh` reports `Successful` for
  every group's refresh and `status: InService` for the new instances.
- The area widget "Instances by AMI family (Amazon Linux 2 vs 2023)" of
  `monitoring/datadog-dashboard.json` shows the old family's area going to
  zero.
- `scripts/patch-compliance-scan.sh --inventory <inventory> --dry-run`
  reports the refreshed hosts compliant against the AL2023 baselines.

### Rollback

The rollback is the previous launch-template version: point the group's
refresh back at the version before the migration
(`aws autoscaling start-instance-refresh` against the prior version, or the
equivalent revert-and-apply of the pull request), and the group converges
back onto the AL2 image. An instance already mid-maintenance returns to
rotation with the documented command of `scripts/ec2-drain-instance.sh`:
`aws autoscaling enter-or-exit-standby-for-instances --target-state
InService`. The rollback is cheap precisely because the migration is
image-based: nothing was mutated in place, so there is nothing to mutate
back.

### Abort criteria

- Any canary instance fails its health check after the refresh, or the
  golden-ami smoke test of the pipeline is red: stop; the remaining rings
  are not started.
- The scan of the canary ring shows the new image class regressing (an
  unknown track, or the agent absent from the SSM inventory): stop; the
  image build is defective, not the estate.
- An Auto Scaling refresh reports a `StatusReason` naming a template error
  mid-flight: roll back the group to the previous version and re-plan; do
  not nurse a half-refreshed group.

### Source

- source: the entry with `engine` "al2" in `data/eol-catalog.json`
  (end of life 2026-06-30; action: rebuild the AMIs and reattach the prior
  launch-template version as the rollback plan).
- source: the entry with `engine` "al2023" in `data/eol-catalog.json`
  (standard support end 2027-06-30; the target of the migration).
- Commands of record: `cloudops/cli.py` (scan), `scripts/ec2-drain-instance.sh`,
  `scripts/patch-compliance-scan.sh`, `atlantis.yaml`; the instance-refresh
  calls are the Auto Scaling APIs of the same names
  (`aws autoscaling start-instance-refresh`,
  `aws autoscaling describe-instance-refresh`) -- a wrapping script is not
  yet in `scripts/`.

---

<a id="runbook-b"></a>
## Runbook B: RDS minor engine upgrade

### Purpose

Move a managed database to the latest minor of its major while the engine
stays supported, keeping the database inside the patch programme rather than
inside an extended-support bill. The minor is the in-place path; the majors
live under the blue/green rule (Runbook C, and
`docs/adr/0003-blue-green-for-majors.md`). The rds module already configures
`auto_minor_version_upgrade` and a reviewed maintenance window
(`infra/modules/rds/README.md`); this runbook is the managed, *unattended-by-
default* alternative an operator drives deliberately.

### Preconditions

- The scan names the instance and the target:

      cloudops scan --inventory <inventory> --eol-catalog data/eol-catalog.json

  A concrete reference sandbox example: the host `db-prod-pg-01` on
  PostgreSQL 13 carries the reason that standard support ended
  2026-02-28 and the target line `18.1`.
  (source: the entry with `engine` "postgres" and `version_track` "13" in
  `data/eol-catalog.json`.)
- The instance is not the blue side of a standing blue/green deployment, has
  no pending automated snapshot operation, and replication is healthy
  (`aws rds describe-db-instances` shows `Status: available` and replica lag
  within its alarm threshold -- see the alarm table in `OPERATIONS.md`).
- The instance is in the ring order position the calendar says it is; a
  critical-tier database upgrades only after the canary-tier database of
  the same engine has completed and soaked.

### Procedure

1. Take the named snapshot the change will roll back to:

       aws rds create-db-snapshot \
         --db-instance-identifier <identifier> \
         --db-snapshot-identifier <identifier>-pre-minor-<yyyymmdd> \
         --region <region>

   and wait for it to report `available` before anything else happens. A
   minor in place without a completed named snapshot is not this runbook.
2. Make the change against the maintenance window: the configuration change
   is the `engine_version` attribute of the rds module, applied through the
   pull request (Atlantis plan, reviewer approval, `atlantis apply`), with
   `apply_immediately` left at its reviewed default so the engine upgrade
   lands in the window the module configures rather than at the moment of
   the apply. For an instance the module does not own yet, the equivalent is
   the same-named API:

       aws rds modify-db-instance \
         --db-instance-identifier <identifier> \
         --engine-version <minor> \
         --region <region>

   with no `--apply-immediately` flag, which is the "against the maintenance
   window" in the shape of a command line.
3. For the read replicas, upgrade the replicas first, then the source; the
   fleet inventory of the reference sandbox carries exactly that pairing in
   `db-prod-mysql-01` and `db-prod-mysql-replica-01`.
4. A dry rehearsal of any SSM-borne work around the database (agent
   restarts, checks) goes through `scripts/ssm-run-command.sh`, whose
   `aws ssm send-command` path is the single audited way onto a host.

### Verification

- `aws rds describe-db-instances --db-instance-identifier <identifier>
  --region <region>` reports `EngineVersion` equal to the target and
  `Status: available`, and a `PendingMaintenanceActions` list without an
  outstanding `APPLY_PENDING_MAJOR_VERSION_UPGRADE` or minor twin.
- `cloudops scan` against the refreshed inventory reports the host as
  supported (`status: ok`) with no reason string.
- `cloudops drift --state <state-export> --live <live-describe>` exits 0 or
  reports the `engine_version` delta as expected: `engine_version` is a
  member of the `CRITICAL_ATTRS` set of `cloudops/drift.py`, so a live value
  that moved *without* a plan behind it is a CRITICAL finding, and the run
  of this verification proves the movement had a plan behind it.

### Rollback

Restore the pre-change snapshot as a new instance and re-point the
applications -- the snapshot of step 1 is the reason the rollback of a minor
is a sentence and not a project. For a replica-set change, restoring the
set is restoring the source and rebuilding the replicas from it. A
configuration rollback is available before, not after: reverting the pull
request before the apply is a merge; after the window has run, the data is
on the new minor and only the snapshot moves it back.

### Abort criteria

- The named snapshot fails or stalls: abort before the modify. There is no
  version of this runbook that proceeds without it.
- The instance reports a state other than `available` at any precondition
  check, or replication lag breaches its threshold: abort and reschedule;
  the window will come again.
- Mid-upgrade the instance fails over to its standby and reports an
  engine-state inconsistency in its events: stop the window's remaining
  instances, page per `OPERATIONS.md`, and treat the incident as the higher
  priority than the calendar.

### Source

- source: the entry with `engine` "postgres" and `version_track` "13" in
  `data/eol-catalog.json` (standard support end 2026-02-28, premium support
  end 2029-02-28, the extended-support horizon the minor programme keeps the
  estate ahead of).
- Commands of record: `aws rds create-db-snapshot`,
  `aws rds modify-db-instance`, `aws rds describe-db-instances` (the AWS
  CLI commands of the same names the wrapper scripts use -- a wrapping
  script is not yet in `scripts/`), plus `cloudops scan`, `cloudops drift`
  (`cloudops/cli.py`) and `scripts/ssm-run-command.sh`.

---

<a id="runbook-c"></a>
## Runbook C: RDS major engine upgrade (blue/green)

### Purpose

Cross a major engine boundary -- the boundary at which the catalogue is
migrated and the return road closes -- by the blue/green mechanism only, per
`docs/adr/0003-blue-green-for-majors.md`. The reference sandbox case that
motivates the runbook is `db-prod-mysql-01` on 5.7, past its standard
support end of 2024-02-29, whose catalog action names the blue/green path.
(source: the entry with `engine` "mysql" and `version_track` "5.7" in
`data/eol-catalog.json`; the wrapper the catalog entry names,
`scripts/rds-major-upgrade-bluegreen.sh`, is not yet in `scripts/`, so this
runbook gives the AWS CLI commands of the same names directly.)

### Preconditions

- The minor runbook has brought the *current* major fully current first;
  blue/green is never the vehicle for two boundaries at once.
- The instance qualifies for blue/green: it is in a supported configuration,
  has no task in flight, and its event feed is clean.
- The blue side and the green side will coexist, so capacity and billing
  have been reviewed for the doubling (the honest cost consequence of the
  ADR).
- The promotion date is booked and outside any freeze; the soak date is
  booked; the removal date is booked. Under the calendar consequence of the
  ADR, a major without all three dates does not start.
- A checkpoint protocol is agreed: which checksums and which application
  smoke tests constitute the post-promotion checkpoint, and who says the
  word that lets Runbook step 4 remove the blue side.

### Procedure

1. Create the deployment and let the green side build and sync:

       aws rds create-blue-green-deployment \
         --source-arn <db-instance-arn> \
         --blue-green-deployment-name <id>-maj-<target> \
         --target-d-b-instance-config EngineVersion=<target>, \
         DBInstanceClass=<class>,StorageEncrypted=true \
         --region <region>

   Poll `aws rds describe-blue-green-deployments
   --blue-green-deployment-name <name>` until the green resource reports
   `Provisioned` and the deployment `Available`.
2. Soak with replication running: let the green side replicate for the
   agreed soak interval under real blue-side write traffic, rehearsing
   connections and query plans against the green endpoint. This is also the
   interval the freeze may cover -- an inert green side through a freeze is
   allowed; a promotion is not.
3. Guard the switchover on replication lag, then promote. Before any
   switchover, `aws rds describe-db-instances` on the *blue* side must show
   `AuroraReplicaLag`/replica-lag metrics at or below the alarm threshold,
   sustained, so that "switch" can never mean "drop unapplied writes"; the
   reference sandbox reads the shape of that guard from the replica-lag
   series of `monitoring/datadog-dashboard.json` (labelled reference
   sandbox). Then:

       aws rds switch-blue-green-deployment \
         --blue-green-deployment-name <name> \
         --switchover-timeout <seconds> \
         --region <region>

   The switch exchanges the endpoints atomically; applications see seconds,
   not a window.
4. Keep the blue side until the checkpoint has passed -- connection
   profiles, checksums, replication from the new side, and the application
   smoke suite all green. Only then remove the old resource:

       aws rds delete-blue-green-deployment \
         --blue-green-deployment-name <name> \
         --region <region>

   Deleting the deployment removes the retained old resource; doing it
   before the checkpoint voids the one property that distinguishes this
   method from a restore.
5. Land the configuration onto the new reality: the `engine_version` of the
   rds module and its parameter-group family follow the new major (the
   module README notes a major forces a replacement of the parameter group),
   through the pull request and `atlantis apply`, and
   `allow_major_version_upgrade` is set only in the plan that carries the
   completed change.

### Verification

- `cloudops scan` against the refreshed inventory: the host reports
  supported at the new major. Reference sandbox instance: `8.4` is "no
  action required".
  (source: the entry with `engine` "mysql" and `version_track` "8.4" in
  `data/eol-catalog.json`.)
- `aws rds describe-blue-green-deployments` returns empty for the estate;
  no deployment is left standing past its checkpoint.
- `cloudops drift --state <export> --live <describe>` is clean on the
  database addresses -- remember `engine_version` is CRITICAL in
  `cloudops/drift.py`, so a clean drift report is the proof that the engine
  that runs is the engine the reviewed plan put there.
- Replica lag is back inside its threshold, and the blue/green switchover
  duration series of `monitoring/datadog-dashboard.json` shows the change
  event with a small, seconds-scale switch duration (reference sandbox
  expectation, from the same dashboard) while the client error rate stayed
  bounded and returned to zero.

### Rollback

Before the removal step, the rollback is the switch back:
`aws rds switch-blue-green-deployment --revert-from-switchover
--switchover-timeout <seconds>` returns the endpoints to the still-unconverted
blue side, which exists until step 4 executes. That is the ADR's answer to
the asymmetry: the rollback of a migrated catalogue is not a downgrade, so
the method keeps an un-migrated copy instead. After the removal step, the
only rollback is the pre-change snapshot restore, and every write after the
snapshot is at risk -- which is exactly why the removal waits for the
checkpoint.

### Abort criteria

- The green resource never reaches `Provisioned`/`Available`, or replication
  to the green side will not catch up within the soak budget: abort; delete
  the deployment while the blue side is untouched (the abort-before-switch
  state is always safe).
- Replication lag breaches the guard threshold at any point before the
  switch: do not switch. A lagging green side converts the atomical switch
  into a data-loss switch.
- The checkpoint is red after a promotion: revert immediately under the
  switch-back, keep the deployment and the blue side as the evidence, and
  open the incident before opening any post-mortem.
- The promotion date slips into a freeze: the change parks as a soaked
  green side, re-verifies per the ADR, and waits for the freeze to lift.

### Source

- source: the entry with `engine` "mysql" and `version_track` "5.7" in
  `data/eol-catalog.json` (standard support end 2024-02-29, premium support
  end 2029-06-30; action names the blue/green script).
- Commands of record: `aws rds create-blue-green-deployment`,
  `aws rds describe-blue-green-deployments`,
  `aws rds switch-blue-green-deployment` (including
  `--revert-from-switchover`), `aws rds delete-blue-green-deployment` -- the
  AWS CLI commands of the same names the intended wrapper
  `scripts/rds-major-upgrade-bluegreen.sh` will use; that script is not yet
  in `scripts/`. Plus `cloudops scan`, `cloudops drift` (`cloudops/cli.py`)
  and the parameter-family note of `infra/modules/rds/README.md`.

---

<a id="runbook-d"></a>
## Runbook D: ElastiCache engine upgrade and failover test

### Purpose

Move a cache replication group onto a supported engine release and prove
its failover actually fails over. The two halves belong together because an
upgrade is the moment the failover path is exercised: the estate has a
reference-sandbox case (`cache-prod-redis-old-01` on 5.0) that is inside the
Extended Support window, where the catalog action records that ElastiCache
auto-enrolled the cache and that the surcharge runs to 80 to 160 percent of
the base instance price.
(source: the entry with `engine` "redis" and `version_track` "5.0" in
`data/eol-catalog.json`; the 6.2 entry carries the pre-emptive deadline:
upgrade to 7.x before 2027-01-31.
source: the entry with `engine` "redis" and `version_track` "6.2" in
`data/eol-catalog.json`.)

### Preconditions

- The scan reports the group's status and its target (the reference sandbox
  rows report `6.2.7` and `5.0.6` against target `7.1`).
- The engine path is a supported in-place path
  (`aws elasticache describe-update --service-type cache` for the eligible
  pairs); where the desired target is a different engine family -- the
  catalog's own recommendation is Valkey or Redis OSS 7.x -- the change is
  a rebuild-dual-write migration planned as a project, not this runbook.
- A failover test window is agreed: `test-failover` moves a replica into a
  promotion and is designed for maintenance, but it costs the group its
  redundancy for the duration, so the group must be Multi-AZ and outside a
  freeze.
- Application-side assumptions are checked: client reconnect behaviour,
  cache warming strategy, and the eviction policy's tolerance of a cold
  start.

### Procedure

1. Snapshot first:

       aws elasticache create-snapshot \
         --replication-group-id <id> \
         --snapshot-name <id>-pre-engine-<yyyymmdd> \
         --region <region>

   and let it reach `available`.
2. Apply the engine change through the configuration (the ElastiCache
   resource's engine version attribute in the estate's module set, via the
   pull request and `atlantis apply`) -- the same-named API, for the estate
   not yet under the module, is:

       aws elasticache modify-replication-group \
         --replication-group-id <id> \
         --engine-version <target> \
         --apply-immediately \
         --region <region>

   With `--apply-immediately` absent, ElastiCache parks the change as a
   pending modification for the maintenance window -- the same in-window
   discipline as Runbook B.
3. Roll the nodes: ElastiCache upgrades replicas before the primary and
   promotes a replica to take the primary role; watch
   `aws elasticache describe-replication-groups` until the group is
   `available` and every node reports the target `EngineVersion`.
4. Run the failover proof after the upgrade, in the agreed window:

       aws elasticache test-failover \
         --replication-group-id <id> \
         --target-nodes-to-failover 1 \
         --region <region>

   This deliberately triggers a replica promotion on one node, which is the
   only way to see, before the incident, that promotion works, clients
   reconnect, and the metrics recover.

### Verification

- `aws elasticache describe-replication-groups --replication-group-id <id>`
  reports every node at the target engine version, `Multi-AZ: enabled`
  intact, and the group `available`.
- The failover completed inside its measured, seconds-scale window
  (reference sandbox expectation) and the client reconnect was clean:
  error-rate transient bounded, then zero.
- `cloudops scan` reports the host supported (reference sandbox: the 7.1
  entry is "no action required".
  source: the entry with `engine` "redis" and `version_track` "7.1" in
  `data/eol-catalog.json`).
- The next `scripts/patch-compliance-scan.sh` cycle is green on the cache
  hosts, proving the agents survived the promotion.

### Rollback

- Before the modification lands: withdraw the pull request, or clear the
  pending modification -- the nodes are still on the old engine and nothing
  happened.
- After a node set has upgraded and behaviour is wrong: ElastiCache does
  not support an engine downgrade in place; restore the snapshot of step 1
  into a new replication group
  (`aws elasticache create-replication-group --snapshot-arn <arn>`) and
  re-point the clients. The snapshot-to-new-group path is the rollback of
  record because it is the only one the service offers.

### Abort criteria

- The snapshot will not reach `available`: abort at once; the runbook has
  no no-snapshot branch.
- The group is single-AZ, or a previous failover test has not completed:
  abort the test half; running a failover drill against a group with no
  surviving copy is manufacturing an outage, not preventing one.
- During the engine roll, a node fails to arrive at the target version or
  the group wedges in a modifying state past its budget: freeze, do not
  retry into the wedge, and follow the incident procedure of
  `OPERATIONS.md`.

### Source

- source: the entries with `engine` "redis" (`version_track` "5.0", "6.2",
  "7.1") in `data/eol-catalog.json`.
- Commands of record: `aws elasticache create-snapshot`,
  `aws elasticache modify-replication-group`,
  `aws elasticache describe-replication-groups`,
  `aws elasticache test-failover` -- the AWS CLI commands of the same names
  the future wrapper scripts will use; no ElastiCache script is yet in
  `scripts/`. Plus `cloudops scan` (`cloudops/cli.py`) and
  `scripts/patch-compliance-scan.sh`.

---

<a id="runbook-e"></a>
## Runbook E: EKS control plane (one minor at a time), then node groups

### Purpose

Keep the Kubernetes platform inside its support window. The catalog is the
authority for the estate's reference rows: 1.30 passed its end of life
2025-07-23 and its extended-support end 2026-07-23, and the action line for
that state is "upgrade without delay".
(source: the entry with `engine` "eks" and `version_track` "1.30" in
`data/eol-catalog.json`; the 1.34 entry is the posture to aim at --
"supported; plan the next minor at the usual pace".
source: the entry with `engine` "eks" and `version_track` "1.34" in
`data/eol-catalog.json`.)
The iron rule of the runbook is that the control plane moves **one minor at
a time**: 1.30 goes to 1.31, and only after it has settled does anything
move to 1.32. The cluster version ladder is not a suggestion; the API server
refuses the skip, and an operator who plans the whole staircase in one
afternoon has planned a failed change.

### Preconditions

- `aws eks describe-cluster --name <cluster>` reports `active`, and
  `aws eks describe-upgrade` reports the next eligible minor (the API of
  the same name the future wrapper will consult; no EKS script is yet in
  `scripts/`).
- The version-skew audit has run: no node group may run an Kubernetes minor
  further behind the control plane than the version-skew policy of the
  estate permits, so the sequence is always control plane first, node groups
  second, per hop.
- Add-on compatibility for the target minor has been checked (the managed
  add-ons' versions and any vendored controllers' support matrices).
- The workloads are drain-safe: pod disruption budgets exist where they must
  exist, and the node group's instance refresh will respect them.
- The scan line of the cluster is on the record:

      cloudops scan --inventory <inventory> --eol-catalog data/eol-catalog.json --severity eos

### Procedure

1. Upgrade the control plane one minor through the configuration of the
   cluster resource (via the pull request and `atlantis apply`); the
   equivalent same-named API is

       aws eks update-cluster-version \
         --name <cluster> \
         --version <next-minor> \
         --region <region>

2. Watch `aws eks describe-cluster --name <cluster>` until
   `status: ACTIVE` and `version` is the target; the control plane upgrade
   is a rolling replacement of the API layer and takes minutes during which
   the cluster stays served.
3. Run the control-plane conformance smoke set (deployment rollout to a
   canary namespace, a service endpoint probe, the dashboard of
   `monitoring/datadog-dashboard.json` showing the cluster's metrics keep
   flowing).
4. Refresh the node groups, one group at a time, in the ring order (canary
   pool first): change the launch template's AMI to the target platform
   build, then

       aws eks start-nodegroup-update \
         --cluster-name <cluster> --nodegroup-name <ng> \
         --launch-template-version <new> \
         --region <region>

   or, for managed node groups on Auto Scaling, the instance refresh of the
   group (`aws autoscaling start-instance-refresh`, the same mechanism as
   Runbook A) -- which is the "node groups via the instance refresh" of the
   runbook title.
5. Only when the whole estate is green at the new minor does the next hop
   become legal to plan. A 1.30-to-1.32 estate is two complete passes of
   this runbook, with a soak between them.

### Verification

- `aws eks describe-cluster` reports the target `version`; every node
  reports `status: Ready` and a `kubelet_version` at the target minor;
  `aws eks describe-nodegroup` reports `ACTIVE`.
- `kubectl get nodes` (or the describe equivalent) shows zero nodes behind
  on the version skew.
- `cloudops scan` on the refreshed inventory reports the cluster supported
  (reference sandbox: the 1.34 row).
  (source: the entry with `engine` "eks" and `version_track` "1.34" in
  `data/eol-catalog.json`.)
- The daily scan of `k8s/daily-scan-cronjob.yaml`, which is the recurring
  gate of exactly this posture, goes green for the cluster row.

### Rollback

A control plane has no supported downgrade. The rollback of a bad hop is
therefore architectural, and the runbook earns its shape from it: because
the change is one minor at a time, the blast radius of a bad hop is the
between-two-minors delta, and the response is forward-fixing (hold at the
current good minor, remediate the incompatibility, continue) rather than
backward. The node groups *do* have a rollback -- re-point the refresh at
the previous launch-template version, the same move as Runbook A -- which
is why every node-level change goes through the launch template and never
through an SSH session.

### Abort criteria

- `aws eks describe-upgrade` reports no eligible target, or the control
  plane is `UPDATING` past its budget without progress: abort the hop and
  escalate; do not force a second hop under a stuck first one.
- After the control plane arrives, more than the drain budget of pods is
  not-ready, or the disruption budget of any critical application blocks the
  refresh repeatedly: hold the node groups where they are (a one-minor skew
  is survivable within the policy) and fix the workload, not the platform.
- Any control-plane outage during the hop: it is an incident under
  `OPERATIONS.md` first and a failed runbook second; page, stabilize, then
  decide the forward/backward question.

### Source

- source: the entries with `engine` "eks" (`version_track` "1.30" through
  "1.34") in `data/eol-catalog.json`.
- Commands of record: `aws eks update-cluster-version`,
  `aws eks describe-cluster`, `aws eks describe-upgrade`,
  `aws eks start-nodegroup-update`, `aws autoscaling
  start-instance-refresh` -- the AWS CLI commands of the same names the
  future wrapper scripts will use; no EKS script is yet in `scripts/`.
  Plus `cloudops scan` (`cloudops/cli.py`) and
  `k8s/daily-scan-cronjob.yaml`.

---

<a id="runbook-f"></a>
## Runbook F: Drift remediation

### Purpose

Close the gap between what the state file records and what the APIs report,
and close it *in the direction of the configuration*. The drift detector
(`cloudops/drift.py`) states the doctrine: a drift finding is not a change
request, it is the evidence for one. The remediation of drift by the console
-- "the resource already looks right, leave it" -- is prohibited: it leaves
the configuration lying, and the next plan will try to undo the console.

### Preconditions

- The weekly drift report has produced findings. Its producing pair is the
  sanitized state export and the live describe export, in the shapes of
  `tests/fixtures/state-export.json` and
  `tests/fixtures/live-describe.json`:

      cloudops drift --state <state-export.json> --live <live-describe.json> \
        --format md

  (the fixture invocation is the reference sandbox demonstration; in
  production the two files come from the state export of the bucket and the
  describe sweep of `cloudops/aws_live.py`).
- Each finding carries its severity from the detector: CRITICAL findings
  (a member of `CRITICAL_ATTRS`: a security group that moved, an unencrypted
  volume, an engine version nobody planned) page the on-call immediately and
  follow the incident procedure of `OPERATIONS.md` in parallel with this
  runbook; INFORMATIONAL findings ride the weekly report and wait their
  turn.
- Nobody has "hot-fixed" the resource to make the report go away. If that
  happened, the fix stays in and the drift stands, but it must come through
  the pull request below.

### Procedure

1. Reproduce the finding from the authoritative inputs: run `cloudops drift`
   fresh against the current exports, and triage every finding by the
   `remediation` field the detector attaches to it.
2. For a finding whose correct direction is *the configuration is right and
   reality is wrong*: restore reality by applying the configuration -- the
   pull request is opened first, the reviewer approves second, and
   `atlantis apply` is the last resort before changing anything. Where the
   divergence is on attributes the resource genuinely ignores, add the
   attribute to the ignore list (`--ignore`, the table shape of
   `DEFAULT_IGNORE` in `cloudops/drift.py` is the model), never to the
   comparison.
3. For a finding whose correct direction is *reality has grown and the
   configuration must change with it*: import the change -- write the
   attribute into the configuration as the live value, and let Atlantis
   plan it. The reviewer approves, and `atlantis apply` runs the change, and
   both must obey the apply requirements of `atlantis.yaml` (mergeable,
   approved, fail-closed).
4. Comment any review notes into the pull request: the drift report file
   itself (`--out reports/drift-<yyyymmdd>.md`), the finding, the chosen
   direction, and the owner who signs the change-off.

### Verification

- `cloudops drift --state <new-export> --live <new-describe>` on freshly
  exported inputs, after the apply has settled and before the report is
  filed, must exit with status 0; the exit-status of a non-zero run is the
  signal that the change is incomplete, and the operator must not delete
  the findings, but must read them again.
- The `Infrastructure drift findings` gauge of
  `monitoring/datadog-dashboard.json` returns to zero for the resource
  type (reference sandbox expectation, from the dashboard definition file).

### Rollback

The remediation itself is a reviewed pull request, so its rollback is the
revert of the pull request through the same gate; the drift finding will
reappear, which is the proof that the revert worked and the correct
diagnosis of the first round was the wrong one. There is no rollback of
"reality accepted" beyond re-adding the manual change -- which is why step
2/3 choose one direction per finding, and the manual pages of this section
are the reference.

### Abort criteria

- The exports cannot be compared (a schema mismatch between the two
  files -- a data problem is reported by exit status 2 from
  `cloudops/cli.py`): stop, fix the export pipeline, and re-run; do
  not remediate against a broken comparison.
- The number of findings on one resource exceeds what the ring's change
  can absorb in one window: split and sequence them into more pull
  requests, one coherent change each.
- A CRITICAL finding whose error is a security incident: the abort
  criteria of `OPERATIONS.md` (the severity ladder) take precedence; the
  patch, the commit, and the merge wait, the pager does not.

### Source

- Commands of record: `cloudops drift` (`cloudops/cli.py`, exit statuses
  0/1/2 as documented in its module docstring), the describe sweep of
  `cloudops/aws_live.py`, and the plan/apply pair of `atlantis.yaml`
  (`atlantis plan`, `atlantis apply`). No dedicated drift wrapper script is
  yet in `scripts/`; the AWS CLI commands of the same names that such a
  script will use are the plain `aws <service> describe-*` calls that
  `cloudops/aws_live.py` already makes.
