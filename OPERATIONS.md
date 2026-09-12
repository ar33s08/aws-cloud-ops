# Operations

This file is the day-two manual of the estate: the routine that keeps the
estate honest between the changes, the alarms and the numbers behind them,
the ladder that decides how fast anyone answers, and the calendars that
decide when nobody may change anything. The change procedures themselves
are not here; they are the runbooks of `UPGRADE-RUNBOOKS.md`. The decisions
behind the shape of this manual are in `docs/adr/`.

Two conventions apply to every line below. A threshold is never quoted
without the number it documents and the file that configures it. A figure
that was measured rather than configured is labelled *reference sandbox*,
which means it came from the sample data and the golden pipeline of this
repository and is illustrative. Nothing here asserts that any of it is
deployed at any employer of anyone.

## The routine

The routine is the rhythm that catches, before an alarm does, the three
things that erode an estate: versions that age, compliance that rots, and
reality that drifts from the configuration.

### Daily

1. **The scan.** The scheduled scan of `k8s/daily-scan-cronjob.yaml`
   (the CronJob `cloudops-daily-scan`, `schedule: "0 6 * * *"` -- 06:00 UTC,
   before the US morning stand-up; the file that configures it) runs

       cloudops scan --inventory <inventory> --eol-catalog data/eol-catalog.json --format json

   The exit-status contract of `cloudops/cli.py` is the gate, not a human
   reading a table: 0 everything is supported, 1 a finding sits at or above
   the severity floor, 2 a data problem. A 1 opens a remediation item against
   the owner of the host; a 2 is itself an incident of the tooling and is
   fixed before the scan is re-trusted.
2. **The compliance check.**

       scripts/patch-compliance-scan.sh --inventory <inventory>

   The verdict floor is `SEVERITY_FLOOR='MEDIUM'` -- CRITICAL, HIGH and
   MEDIUM findings all escalate -- (the file that configures it:
   `scripts/patch-compliance-scan.sh`, overridable with `--severity` to
   CRITICAL or HIGH). The script aggregates what the SSM agent reported via
   `aws ssm describe-patch-state-aggregations`; it installs nothing, because
   it is the measurement half of the programme and `scripts/patch-schedule.sh`
   is the actuation half.
3. **The dashboards.** The reference-fleet dashboard
   (`monitoring/datadog-dashboard.json`, title "aws-cloud-ops -- reference
   fleet operations") is glanced, not stared at: the four gauges are the
   standing questions, and a non-green gauge is somebody's item before it is
   anybody's emergency.

### Weekly

1. **The patch windows, in the ring order.** The windows of
   `data/patch-baselines.json` run canary, then standard, then critical, and
   `scripts/patch-schedule.sh` enforces the order with its canary guard: the
   standard ring never starts while the canary ring has not passed its
   compliance scan, and the critical ring never starts behind the standard.
   The configured clock (the file that configures it,
   `data/patch-baselines.json`): the group PROD-CANARY on
   `cron(0 9 ? WED 2)` (second Wednesday, 09:00), PROD-STANDARD on
   `cron(0 10 ? THU *)`, PROD-CRITICAL on `cron(0 11 ? SUN *)`, with the
   cutoff hours 3, 4 and 2 and the overlap durations 1, 1 and 0 hours
   respectively. The guard's own dials are `--floor` and `--max-age` of
   `scripts/patch-schedule.sh`; its poll interval defaults to 15 seconds.
2. **The drift report.**

       cloudops drift --state <state-export.json> --live <live-describe.json> --format md

   Findings are triaged by the severity the detector assigns
   (`cloudops/drift.py`): CRITICAL attributes -- the members of its
   `CRITICAL_ATTRS` frozenset, which is the file that configures the
   classification -- page a human the day they are seen and open the process
   of Runbook F of `UPGRADE-RUNBOOKS.md`; WARNING findings get an item;
   INFORMATIONAL findings wait in the report.
3. **The snapshot into `reports/snapshots/`.** The audit trail is written by
   the tool rather than by a human promise:

       cloudops snapshot --inventory <inventory> --eol-catalog data/eol-catalog.json \
         --out reports/snapshots/<yyyymmdd>.json

   `cloudops/cli.py` creates the parent directory, never overwrites an
   existing snapshot for the same day (it stamps the file instead), and
   embeds the tool version, the summary counts and the worst status in the
   document, which is what makes a snapshot comparable across quarters.
   The `reports/` tree is ignored by git on purpose: snapshots are evidence,
   and evidence lives in the artifact store, not in the history of code.

### Monthly

1. **The extended-support line item.** Every host that the scan reports in
   an extended-support posture -- the reason string naming the
   premium-support date, as the MySQL 5.7 and PostgreSQL 13 rows do in the
   reference sandbox -- is a bill as well as a risk, and the bill is metered
   per vCPU-hour against a date that ends regardless of the budget. The
   monthly item reads the `cloudops patch-queue` output against the catalog
   entries' `premium_support_end` dates
   (`data/eol-catalog.json`, the file that carries them) and attaches the
   surcharge estimate to the backlog item so the calendar choice is made
   with money in view.
2. **The backlog review.** The patch queue is the backlog
   (`cloudops patch-queue --inventory <inventory> --eol-catalog
   data/eol-catalog.json [--compliance <reports>]`): the queue's own
   ordering -- severity first, then the ring order canary, standard,
   critical, per `patch_queue` of `cloudops/scan.py` -- is the review's
   agenda, item by item, each leaving with a date or with a reason.

### Quarterly

- **The operational readiness review.** The quarter closes with the review
  written up in the form of `docs/OPERATIONAL_READINESS.md`: the executive
  summary, then a finding each with severity, exposure, and the named
  remediation command. The document of record for the reference sandbox
  review (conducted 2026-09-12; source: the preamble of
  `docs/OPERATIONAL_READINESS.md`) names its own staleness bar in plain
  words -- instances "more than 25 days out of date" are a finding
  (source: Finding 1 of `docs/OPERATIONAL_READINESS.md`) -- and its
  remediations are the same commands this manual routes to. The quarterly
  review is not complete when it is written; it is complete when each
  finding carries an owner and a date.

## The alarm set

Two readings of the estate exist: the live signals, carried by the agents
(`monitoring/datadog-dashboard.json` records in its own `_about` text that
"the metrics are emitted by the cloudops toolkit and by the SSM/CloudWatch
integration"), and the configuration of those signals as code. The honest
inventory of that configuration, as it stands in this repository today:

1. **The dashboard and its gauges.** `monitoring/datadog-dashboard.json` is
   the dashboard as code. It renders no monitors of its own -- its
   description line says "the monitor definitions live beside the
   dashboards" -- so the table below names the widgets and their conditional
   formats exactly as defined, each threshold carrying its configuring file.

   | Widget (title, verbatim) | Type | Threshold as configured | Configuring file |
   | ------------------------ | ---- | ----------------------- | ---------------- |
   | Hosts past end-of-life | query_value | red on `> 0`, green on `== 0` (palette white_on_red / white_on_green) | `monitoring/datadog-dashboard.json` |
   | Hosts approaching end-of-life (< 90 days) | query_value | yellow on `> 0` | `monitoring/datadog-dashboard.json`; the 90-day horizon itself is `_approaching` of `cloudops/eol.py` ("within 90 days") |
   | Patch compliance (baseline-missed packages) | query_value | orange on `> 0`, green on `== 0` | `monitoring/datadog-dashboard.json` |
   | Infrastructure drift findings | query_value | red on `> 0` | `monitoring/datadog-dashboard.json`; severity classes from `CRITICAL_ATTRS` of `cloudops/drift.py` |
   | Patch queue depth by severity (7d) | line | none (trend widget) | `monitoring/datadog-dashboard.json` |
   | Instances by AMI family (Amazon Linux 2 vs 2023) | area | none (trend widget) | `monitoring/datadog-dashboard.json` |
   | RDS minor upgrade duration and blue/green switchover lag | timeseries | none (trend widget; read against the lag guard of Runbook C) | `monitoring/datadog-dashboard.json` |
   | SSM Run Command / patch execution latency | heatmap | none (trend widget) | `monitoring/datadog-dashboard.json` |
   | EOL verdict per host (from the cloudops scanner gauge feed) | table | none (listing widget) | `monitoring/datadog-dashboard.json` |
   | Recent change events (deploy / patch / drift) | event_timeline | filtered on `tags:program:aws-cloud-ops` | `monitoring/datadog-dashboard.json` |

2. **The CloudWatch alarms of `infra/modules/observability`.** Recorded
   truthfully: that module directory exists but is empty in this repository
   today -- it carries no `.tf` files yet -- so there are no CloudWatch alarm
   names to enumerate, and this manual will not invent any. When the module
   lands, the rule of this section is that its alarms enter the table above
   with their names verbatim and their thresholds pointing at the file that
   configures them; until then, paging runs off the dashboard's conditional
   formats and the exit-status contract of the two scan scripts.

The reference-sandbox reading of the gauges (all four headline widgets share
the same shape): every threshold is zero. The estate's position is that a
single EOL host or a single drift finding is exactly as pageable as a
hundred, because both are counted, not weighed -- any other stance lets
one finding age invisibly behind ninety invisible ones.

## On-call rotation

- The rotation is a pair per week: a primary and a secondary, the secondary
  answering when the primary is silent past the acknowledgement time of the
  severity ladder below. The handover is the weekly snapshot plus the open
  findings of the last drift and compliance runs; a rotation that inherits no
  written state inherits no estate.
- On-call owns *response*, not *authorship of fixes*: the on-call operator
  acknowledges, triages, contains, and routes; the deep fix goes to the
  owner of the component with the evidence attached. This split is what lets
  the rota be a rota and not a research position.
- The on-call operator is the only standing human authority to page upward
  and the only one expected to read the dashboards under pressure; the
  authority to change infrastructure is deliberately elsewhere -- the
  pull-request gate of `atlantis.yaml`, whose production applies are
  restricted to the maintainers of the estate.

## Incident procedure and the severity ladder

The procedure runs in order: acknowledge, stabilise, communicate, resolve,
then write. The severity ladder is the policy that decides who is paged and
how fast; the times are response commitments, not resolution promises.

| Severity | Definition | Acknowledge | Communicate cadence | Page |
| -------- | ---------- | ----------- | ------------------- | ---- |
| SEV1 | A user-facing service is down, or a security compromise is live, or the state store of the estate (the bucket or the lock table of ADR 0001) is unusable | 5 minutes | hourly | primary immediately, secondary at 5 min, maintainer within 15 min |
| SEV2 | One tier degraded or a production single point lost (one NAT zone of ADR 0002 gone, one database on its own); CRITICAL drift finding of `cloudops/drift.py`; scan exit 1 on a critical-ring host | 15 minutes | every 2 hours | primary immediately, secondary on silence |
| SEV3 | Redundancy or compliance eroded without user impact: canary ring failing its guard, a WARNING drift finding, a standard-ring host past end-of-support | same business day | at closure | ticket to the ring owner; no overnight page |
| SEV4 | Cosmetic or informational: INFORMATIONAL drift, an approaching-end catalog note, a documentation defect | next weekly review | at closure | backlog |

The rules that give the ladder teeth:

- An alarm that would not sustain its severity under the definitions above
  is retuned at the next review of the alarm set rather than ignored;
  silencing is a change like any other and gets a pull request.
- A patch-window failure has a rule of its own: the failed host stays
  failed. The operator of `scripts/patch-schedule.sh` reads in the header of
  the script -- leaving the canary hosts standing as "the evidence of what
  is wrong with the baseline" -- because the diagnostic value of a live
  failure outranks the tidiness of a cleaned one.
- A runbook abort criterion that has fired *is* the triage: the runbooks of
  `UPGRADE-RUNBOOKS.md` were written so that an abort maps to a severity
  (an engine-version event is SEV2, a snapshot failure is SEV3), and an
  operator who has just aborted is not asked to redesign the ladder mid
  flight.

## Escalation path

1. Primary on-call (acknowledgement times above).
2. Secondary on-call, automatic on silence past the acknowledgement time.
3. The maintainers of the estate -- the `project_maintainers` scope that
   `atlantis.yaml` already names as the authority for production plans and
   applies -- on any SEV1, and on any SEV2 the secondary cannot place.
4. The change advisory board -- the approval authority recorded in the
   `approved_by` fields of `data/patch-baselines.json` -- is convened, by
   the maintainer and not by the rota, when the incident's resolution
   contradicts an approved baseline or an accepted ADR, or when an extended
   support date will be crossed unremediated.

The escalation never routes through "someone who can force an apply": the
gate of `atlantis.yaml` fails closed by design, and an incident that cannot
be contained without breaking it is an argument for a designed break-glass
procedure, not for improvising at 03:00.

## The change-freeze calendar

Freezes suspend *promotions and applies*, not detection: the daily scan, the
compliance check and the drift report run straight through every freeze --
finding things is what makes a freeze safe.

| Period | Freeze | Basis |
| ------ | ------ | ----- |
| December 20 through January 3 | Year-end quiet | applies disabled outside break-glass; a standing blue/green may soak through it but may not promote (ADR 0003) |
| The week of each public market holiday of the operating region | Holiday quiet | same terms |
| Every patch-window day, from 2 hours before the window to its closure | Window freeze on everything except the window itself | the windows of `data/patch-baselines.json` |
| The window of a booked major upgrade, per its three booked dates | Change isolation | Runbook C of `UPGRADE-RUNBOOKS.md`; the three-date booking is the calendar consequence of ADR 0003 |

The freeze interacts with the patch clock in one way that must be known, not
discovered: while an organisational freeze holds, the approval waits of the
baselines keep aging -- a package whose `approve_after_days` (30 for
AL2023-SECURITY-30D, 0 for AL2-MIGRATE-ONLY, 14 for DB-AGENT-SECURITY; the
file that configures them, `data/patch-baselines.json`) matures mid-freeze
becomes installable the moment the freeze lifts. The first window after a
freeze is therefore always the biggest window, and the operator schedules
it like one.

## Capacity planning notes (read before scaling)

- **Drift before capacity.** A scale-out action against an estate that is
  drifting encodes the drift into new resources. The drift report of the
  weekly routine is the precondition of any scaling change; a CRITICAL drift
  finding on the resource class you are about to multiply is a stop sign,
  because `cloudops/drift.py` calls exactly the attributes that scale into
  the account (instance profile, metadata options, encryption flags) what
  they are.
- **The refresh is the scaling move.** Instance-level change on this estate
  travels through the launch template and the group's refresh -- the
  mechanism Runbook A and Runbook E both route through
  (`aws autoscaling start-instance-refresh`) -- and a capacity change that
  skips the template re-creates the AMI drift this manual exists to catch.
- **Rough sizing is rough.** The group definitions in
  `data/patch-baselines.json` carry a real constraint the capacity plan must
  respect: the PROD-CRITICAL window (`cron(0 11 ? SUN *)`) has cutoff
  `2` hours and overlap `0` hours. A critical ring sized so that one
  instance's patch-plus-verification outruns its cutoff cannot finish the
  window and will strand the ring mid-compliance; size the ring against the
  window, or move the ring, but do not leave the mismatch to the scheduler
  to interpret.
- **The egress path is a capacity path.** Each NAT gateway of ADR 0002
  carries a data-processing charge of its own; growth that raises the charge
  of one zone's gateway is visible on the per-zone series of the dashboard
  and must be sized per zone, not averaged across zones.
- **Databases: storage first, then class.** A disk- and instance-class
  change to a database is a `modify` against the reviewed maintenance window
  of the rds module (`infra/modules/rds/README.md` -- "a reviewed
  maintenance window and a backup window"), and the reference sandbox
  measurements of resize of the blue/green switchover series
  (`monitoring/datadog-dashboard.json`) are the baseline a proposed capacity
  change must be compared against. There are no units, and every measurement
  is relative to your account's true value of the engine, but the comparison
  against the series is not optional.
- **No measured figure of this manual is a promise.** Every number a reader
  of this section may mistake for a figure of production is labelled
  reference sandbox, and the real measurement of the estate begins where the
  scan says so.

## The patch baselines

The baselines are the law of the fleet and live, definitionally, in one
file: `data/patch-baselines.json`. The registered set of the reference
estate reads:

| Baseline | Product family | Compliance severity | Approval (from the file) | Bake | Held back |
| -------- | -------------- | ------------------- | ------------------------ | ---- | --------- |
| AL2023-SECURITY-30D | Amazon Linux 2023 | CRITICAL | change advisory board 2026-07-15 | 30 days | kernel-livepatch, aws-cfn-init-script |
| AL2-MIGRATE-ONLY | Amazon Linux 2 | MEDIUM | change advisory board 2026-08-01 | 0 days | (none) |
| DB-AGENT-SECURITY | Amazon Linux 2023 Database | HIGH | change advisory board 2026-07-15 | 14 days | datadog-agent |

The properties of the set that matter to the operator:

- Registration is an act of the reviewed file alone:
  `scripts/patch-baseline-register.sh` validates through the Python core
  (`cloudops.patch.load_baselines`) and refuses a baseline whose
  `approved_by`/`approved_on` pair is absent, so an unapproved baseline
  reaches the fleet the way a union of two empty sets reaches the console:
  it does not. The same script prints, in `--dry-run`, the exact
  `aws ssm register-default-patch-baseline` commands it would run.
- The membership map of the rings is the groups section of the same file:
  PROD-CANARY and PROD-STANDARD take AL2023-SECURITY-30D and
  DB-AGENT-SECURITY; PROD-CRITICAL takes AL2023-SECURITY-30D alone -- the
  critical ring's exposure is deliberately narrower, and the reason a
  database-agent baseline is absent from it is the intersection of "agent"
  and "critical traffic" being empty by definition.
- The difference set between what the agent reports and what the baseline
  demands is the compliance scan; where it is non-empty,
  `scripts/patch-compliance-scan.sh` is the function that maps the
  difference to an exit status, and the canary guard of
  `scripts/patch-schedule.sh` is the function that maps a non-zero exit of
  the canary subset to "the other two rings shall not be started".
- `AL2-MIGRATE-ONLY` exists to keep the SSM agent of the end-of-life image
  class alive while Runbook A moves the fleet off it; treating it as a patch
  programme of its own -- staying on Amazon Linux 2 and letting it patch --
  contradicts its own description, which states that the migration to 2023
  supersedes every other action.
- The baselines are sample configuration data; the dates they carry are the
  real calendar and the approvals are real to this repository's history.
  Source: the `_about` line of `data/patch-baselines.json`.

## Reading list

- `UPGRADE-RUNBOOKS.md` -- the six procedures, each with its abort criteria.
- `docs/adr/README.md` -- the decision index; ADR 0001 (state), 0002 (NAT),
  0003 (blue/green) are load-bearing for this manual.
- `docs/OPERATIONAL_READINESS.md` -- the review form, with the reference
  sandbox review as the worked example.
- `data/eol-catalog.json` -- the dates; every lifecycle claim in this
  manual resolves to an entry there.
