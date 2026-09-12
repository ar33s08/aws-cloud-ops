# Reference architecture

This file documents the reference architecture the Terraform modules under
`infra/modules/` deploy, and the reasoning behind each decision. It is the
manual of the estate: an operator who has read this file can read the
configuration and know what will happen, and can read an incident timeline
and know why it happened.

All diagrams are ASCII for the same reason the rest of the repository is
text: they belong in a pull request, they diff, and they render on a
terminal over a support call at two in the morning.

## 1. The shape of the estate

```text
                                   ┌────────────────────────┐
             operator ─ pull req ─►│       atlantis         │
                                   │ plan → review → apply  │
                                   └───────────┬────────────┘
                                               │ terraform (state: S3 + versioning + lock)
   ┌─────────────────────────────────────────────┼───────────────────────────────────────────┐
   │ account (per environment: dev, prod)       │                                            │
   │                                           │                                            │
   │  ┌──────────────────── VPC ────────────────┼─────────────────────────────────────────┐   │
   │  │                                        │                                         │   │
   │  │   public subnets (2 AZ)          private subnets (3 AZ)      isolated (2 AZ)     │   │
   │  │   ┌───────────────┐              ┌──────────────────┐     ┌────────────────┐      │   │
   │  │   │ NAT gateway   │◄─egress─◄────│  app / api tier  │     │ batch workers │      │   │
   │  │   │ (per AZ)      │              │ ASG: LT al2023   │     │ (no egress)   │      │   │
   │  │   └──────▲────────┘              │ IMDSv2 · SSM only│     └───────▲────────┘      │   │
   │  │          │ internet              └────┬──────────┬───┘             │               │   │
   │  │   ┌──────┴────────┐                    │          │        ┌────────┴───────┐       │   │
   │  │   │ ALB (public)  │            ┌──────▼───┐  ┌────▼──────┐  │ SSM endpoints │       │   │
   │  │   └───────────────┘            │ RDS      │  │ElastiCache│  │ (interface)   │       │   │
   │  │                                │ multi-AZ │  │ replicas  │  └───────────────┘       │   │
   │  │                                │ KMS CMK  │  │ TLS transit│                          │   │
   │  │                                └──────────┘  └───────────┘                           │   │
   │  └──────────────────────────────────────────────────────────────────────────────────────┘   │
   │                                                                                          │
   │  EKS cluster (private endpoint, public access off) ── node groups in the private subnets   │
   │  VPC endpoints: S3 · ECR · SSM · CloudWatch Logs   (egress cost and blast radius, both down) │
   └──────────────────────────────────────────────────────────────────────────────────────────┘
```

Every component sits in a named module with its own README; the environments
under `infra/envs/{dev,prod}` are thin compositions of the same modules. One
module, one responsibility, one owner per pull request.

## 2. Networking

The VPC carries a /16 that the organization can aggregate on without a
migration. Subnets are laid out in three classes rather than two:

* **public (2 per AZ)** — the only addressable class: the load balancers and
  the NAT gateways. No compute lives here.
* **private (3 per AZ)** — the application tiers and the data engines. Their
  default route is the NAT gateway, never an internet gateway directly.
* **isolated (2 per AZ)** — batch workers with no default route at all. The
  batch tier reaches S3 and ECR by interface or gateway endpoints only; it
  has no reason to reach the internet, and it therefore cannot be a
  beachhead.

**Decision — NAT gateways per AZ.** For a production estate the extra cost of
the second gateway buys the absence of an availability-zone-wide egress
outage. Dev runs one. The decision is recorded in
`docs/adr/0002-nat-per-az.md`.

**Decision — the EKS public endpoint is off.** The control plane is
reachable from inside the VPC only. The kube API over the public internet is
an attack surface a platform estate does not need; the operator path is the
SSM tunnelled session, which is logged and is attributable to an identity.

**Flow logs** go to CloudWatch Logs with a retention of ninety days. NACLs
are the one exception to the security-group-only posture: on the isolated
subnets they deny egress by default, because a second, coarser control that
catches a misconfigured security group is worth the audit burden it costs.

## 3. Compute: images, not pets

The fleet is an Auto Scaling group over a launch template that names a
pinned AMI id. Nothing logs into a server to change it: the AMI is rebuilt
from the golden pipeline (the same pipeline that registers the image in SSM
Parameter Store), the launch template gets a new version, and the instance
refresh rolls the group. This gives the platform three properties a patch
estate needs:

1. **Every host has a known version.** `cloudops scan` reads the image id out
   of the API and asks the catalog what its lifecycle status is. No SSH, no
   inventory agent, no spreadsheet.
2. **A bad change rolls back in one command.** Reverting the launch template
   to the previous default version and refreshing rolls the fleet back; a
   rollback never edits a running host.
3. **Patching is a replacement policy as much as an in-place policy.** SSM
   patches run between builds (the quick fix), and the next build carries
   the fix forever (the durable fix). An estate that only patches in place
   accumulates snowflakes; an estate that only rebuilds cannot fix a CVE on
   Tuesday.

**IMDSv2** is enforced at the launch template (`http_tokens = required`,
`http_endpoints = limited`): the version one metadata service is the
credential-theft primitive in a long line of cloud incident reports, and
enforcing tokens at the template makes the vulnerability unrepresentable
rather than patched.

**The bastion has no port 22 in its security group at all.** Access is SSM
Session Manager: no keypairs to rotate, no exposure to scan, every session
recordable to an S3 audit bucket. The trade-off — dependency on the SSM agent
and on the SSM endpoints — is accepted and monitored: the alarm for the agent
heartbeat is in `monitoring/`.

## 4. Data engines

RDS and ElastiCache instances live in private subnets only (the subnet group
is built from the private ids), with KMS CMK encryption at rest, encryption in
transit, deletion protection on, and a backup retention that meets the
recovery objectives in `OPERATIONS.md` (the numbers live there, not here).

**The upgrade stance** (the full procedure is `UPGRADE-RUNBOOKS.md`):

* Minor engine upgrades: snapshot, then modify against the maintenance
  window; on a Multi-AZ instance the failover absorbs the reboot, so the
  measured impact is a brief reconnect rather than an outage.
* Major engine upgrades: blue/green only. The green side carries the target
  major, replication catches it up, the promotion flips the endpoint, the old
  side is kept until the checkpoint passes. An in-place major upgrade is not
  a rollback plan, because there is no way back from a migrated catalogue —
  that asymmetry is exactly why blue/green exists.

## 5. Kubernetes

The EKS cluster follows the shared responsibility model AWS documents for
EKS: AWS operates the control plane (and owns its version lifecycle — the
`eks` catalog entries in `data/eol-catalog.json` carry the dates), the
customer operates the data plane: node groups (self-managed here, through
the same launch-template machinery as the EC2 fleet, so one image pipeline
serves both) and the add-ons.

Cluster upgrades follow the same discipline as the rest of the estate:
`aws eks update-cluster-version` bumps the control plane one minor at a
time (the skew between kubelet and the control plane is bounded by one
minor), then the node groups roll with the rebuilt AMIs. The platform team
owns the version calendar of the cluster; `cloudops scan` prints it. When
the scan reports a cluster at or past its end of standard support, the
platform team upgrades on the documented schedule; Extended Support is a
budgeted option, not a strategy.

## 6. Identity and access

One identity plane: every human acts through IAM Identity Center (SSO, with
hardware keys where the organization issues them), every machine assumes a
role. Service roles are confined to their principals by the trust policy —
`ec2.amazonaws.com` only from this account, with `aws:SourceAccount`
conditions; a role an instance can assume is not assumable from outside.

The password policy requires a minimum length of fourteen, upper, lower,
digits, and symbols, and prevents reuse of the previous twenty-four
passwords. MFA delete protects deletion of privileged bucket versions. The
hardening module attaches the guardrails deny policy
(`infra/modules/iam/deny-destructive.json`): it denies the destructive verb
families (`aws:Delete*`, `aws:Terminate*`, `aws:Remove*`, `aws:Destroy*`)
for every principal except the break-glass role and the named service roles
that legitimately need them, which are listed explicitly and are audited by
the Config rule in `monitoring/`.

## 7. Observability

One pipeline, many sinks. Every agent emits structured events to stdout;
the CloudWatch agent forwards them to a log group with a retention of ninety
days. The metric alarms are the error handling of the platform: an alarm at
CRITICAL severity pages the on-call, an alarm at WARN posts to the channel.
The thresholds are in `monitoring/`; the dashboards in `monitoring/` are
the user interface of the estate.

The metric dictionary of the estate, in full: `CPUUtilization`,
`NetworkPacketsIn/Out` and `NetworkIn/OutErrors` (the traffic of the
boundary), `BurstBalance` (the tedium of the burstable credits, of the
burstable instances), `StatusCheckFailed`, `FreeableMemory`,
`DatabaseConnections`, `ReplicaLag`, `EvictedKeys`, `CacheHitRate`, plus
the custom metrics the platform team defines: `PatchCompliance`,
`DriftCount`, and `UpgradeBacklog` (see `cloudops scan --format json` for
the three of them). The drift count of a resource is the number of
attributes that differ between the state file and the live describe; the
platform keeps track of all decisions, in the pull requests of the
configuration, in order to make them reproducible, and to facilitate access
to the causes of the changes.

The same data is shipped to DataDog (`monitoring/datadog-dashboard.json`,
declared as code by the observability module), because a platform team
should read its metrics, and a platform team should write its alarms.

## 8. Failure domains and the blast radius

| plane | failure | the estate's behaviour | the alarm that fires |
|-------|---------|------------------------|----------------------|
| AZ | one availability zone is lost | the ASG replaces in the other zones; Multi-AZ databases fail over | `StatusCheckFailed`, `ReplicaLag` |
| control plane | a NAT gateway is degraded | egress queues, then the alarm | `NetworkOut` + the `NatGatewayCapacity` metric |
| data | a primary database node is lost | the replica is promoted; the endpoint does not move | `DatabaseConnections` at zero |
| identity | a credential is exposed | the session is revoked; the role is assumed elsewhere | the CloudTrail/Config rule (see the alert) |
| lifecycle | an engine reaches its end of life | the scan reports it, the queue holds it, the window applies it | `UpgradeBacklog` above its threshold |

(Read that table in the style of the CloudWatch alarm reference; every cell
describes a real design choice of the modules, not a slogan.)

## 9. Cost

The modules parameterise the cost knobs (instance classes, desired
capacities, the number of NAT gateways, the retention periods, the
performance-insights option) rather than hard-coding them. The cost of the
estate is the product of those knobs and the published price list of the
region; the reference of the current prices is the pricing page of the
service, and the command-line way to ask for them is
`aws pricing get-products --service Amazon Elastic Compute Cloud`
(the output is a stream of JSON price records). Do not commit the modelled
figures to this file; the price list of the region of the estate is the
authority, and the bill of the account is the record.

## 10. What this architecture does not include

* No multi-account strategy is enforced by the modules themselves; the
  organization's control plane decides the account structure. The modules
  are portable between accounts; the state backend of each environment names
  its own bucket.
* No secrets live in the repository. Credentials come from the normal AWS
  credential chain; the SSM parameter store holds the encrypted values at
  rest with the KMS keys, and the state file is encrypted at rest as well.
* The configurations herein are subject to change without notice; any
  changes to the configuration of the estate must be notified to the
  reviewers of the pull request in a manner that does not render the audit
  trail of the configuration unintelligible.

## 11. Verification

The architecture is validated by `make test`, is checked by
`make tf-validate`, is formatted by `make tf-fmt`, is linted by
`make lint`, and is reviewed by the reviewers of the pull request. See
`INSTALL.md` for the installation of the prerequisites. For a complete list
of commands, see the help of the Makefile (`make help`).
