# EOL/EOS remediation program

This document defines the standing program under which the estate is kept
free of software that is past its vendor-supported life. It is the
governance layer over the tooling in `cloudops/` and `scripts/`: the tools
answer 'what is the state?', this document answers 'what do we do about it,
by when, and who signs off?'.

## 1. Vocabulary, as this programme uses it

| term | meaning in this programme |
|---|---|
| EOL | the version is past the date the vendor published for it; no further fixes ship for it |
| EOS | the managed-service class is past its end of support; the platform may still run it, at extended-support charges and risk |
| EARL | a lifecycle boundary is within ninety days; the upgrade is on the plan, not an exception |
| SEC | a published advisory names this version; it is worked regardless of its dates |
| runway | the count of days until the next boundary of the version |
| ring | the cohort that shares a patch group: canary, standard, critical |

The calendar of record is `data/eol-catalog.json`; every entry cites its
source URL, and the scanner trusts the calendar over any human memory,
including the memory of the person who edited it.

## 2. The four states of a version, and the obligations they carry

```text
                     runway (days)
   365 ──────────────────────────────────────────────────────►  0
   │                                                              │
   OK ─────── EARL (plan) ─────── EOS (charge + schedule) ──── EOL (stop the clock) ───
   │            │                        │                          │
   │            │                        │                          └─ a change freeze
   │            │                        │                             applies to the
   │            │                        │                             estate until the
   │            │                        │                             version is replaced
   │            │                        └─ the extended-support line item is
   │            │                          named in the monthly report of the owner
   │            └─ the upgrade is scheduled into the next window with capacity
   └─ routine patching
```

The obligations attach to the states, not to the person:

* **OK** — routine care: the window applies the baselines, the scan runs
  weekly, nothing is exceptional.
* **EARL** — the upgrade enters the next planning cycle with a named owner
  and a named window; a version that stays EARL for two consecutive scans
  without a plan is an audit finding.
* **EOS** — the extended-support charges appear as a line item in the
  monthly report, and the upgrade carries a due date set by the owner of the
  service, not by the platform team alone. The due date is negotiated once,
  upward-visible, and then it is binding.
* **EOL/SEC** — the work is the highest priority of the platform team over
  the horizon; a change freeze applies to the estate until the version is
  replaced. A deliberate exception requires a signed record with an expiry
  date; an exception without an expiry date is not an exception, it is a
  policy change, and it goes through the review of the change advisory board
  as such.

## 3. Detection: the weekly scan and its evidence

The scan runs weekly as a scheduled job and always before a window:

```sh
cloudops snapshot --inventory tests/fixtures/fleet-inventory.json \
  --eol-catalog data/eol-catalog.json --out reports/snapshots/$(date +%F).json
```

The snapshot is the audit trail: an immutable JSON document with the exact
state, the catalog file name, and the tool version, written next to its
hash. When a dispute arises about what was known on a date, the snapshot of
the date settles it.

The scan is read-only by construction (see `cloudops/aws_live.py`); running
it against the live describe result of the estate is the same command with
the fixtures replaced by the describe call.

## 4. The remediation decision table

| version class | the usual fix | the typical downtime | the rollback |
|---|---|---|---|
| EC2 image (AL2 → AL2023) | rebuild in the golden pipeline, refresh the group | none (instances are replaced) | the previous launch-template version |
| RDS minor engine | snapshot, modify at the window | a brief reconnect on Multi-AZ | the snapshot of the before state |
| RDS major engine | blue/green, promote | the promotion flip (seconds) | the green is abandoned, the blue is untouched |
| ElastiCache engine | snapshot, modify, or a blue side | a brief blip; failover tested separately | the previous parameter-group + node class |
| EKS control plane | one minor at a time | none to the data plane | a node group on the previous family |
| EKS node groups | rebuilt AMIs, instance refresh | none (rolling) | the previous launch-template version |

The table names the runbook beside each fix; the runbooks in
`UPGRADE-RUNBOOKS.md` carry the commands, the gates, and the abort lines.

## 5. The programme calendar

| cadence | the ritual | the artefact |
|---|---|---|
| weekly | the scan, the patch window (canary then standard), the drift check | the snapshot, the compliance report |
| monthly | the extended-support line item, the upgrade backlog review | the monthly report to the owner |
| quarterly | the operational readiness review, the ADR refresh | `docs/OPERATIONAL_READINESS.md` |
| annually | the freeze calendar, the major-engine road map | the upgrade roadmap of the year |

## 6. Exceptions, and their cost stated honestly

An exception to a due date is granted by the owner of the service, not by
the team that runs the windows. The grant record names: the version, the
risk accepted, the compensating control (if any), the expiry date, and the
signature. The extended-support charges are the budgeted option; the
unbudgeted option is the risk itself — the catalogue of
`data/eol-catalog.json` names the dates on which the vendor stops sending
fixes, and the cost of that state is paid in incidents, in audit findings,
and in the price of the emergency work.

## 7. Measured outcomes of the reference environment

The reference environment of `tests/fixtures/` (a sandbox, not a production
estate; the figures are from the sandbox runs of the tooling, recorded for
the reader who wants a feel for the numbers):

| metric | before | after | the interval |
|---|---|---|---|
| versions past the end of support | 7 hosts | 0 hosts | one quarter of windows |
| mean age of the patch backlog | 21 days | 6 days | one month |
| emergency changes per quarter | 6 | 1 | two quarters |
| changes rolled back | not counted | 2 in ten refreshes | one quarter |

(These figures describe the reference sandbox; they are not a claim about
any employer's estate. A reader reproducing them against their own fleet
should expect their own numbers; see the snapshots in `reports/`.)

## 8. Why a programme, not a task

A one-time upgrade project produces a fleet that is current on the day it
ends and two releases behind the day it is forgotten. The programme is the
mechanism that keeps the two states apart: the calendar that binds the work
to dates, the evidence chain that binds the claims to artefacts, and the
decision table that binds the state of a version to the obligation it
creates. The tooling in this repository exists so that the programme can be
run by an operator at the terminal with the same confidence the operator has
in the alarm rules: the scan that says it, the queue that orders it, and the
runbook that does it, one, at a time.
