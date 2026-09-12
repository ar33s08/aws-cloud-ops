# Architecture decision records

This directory is the decision log of the estate. Each record follows the
style popularised by Michael Nygard: a decision is written the day it is
taken, with the context that forced it, the alternatives that were weighed,
and the honest bad side of the choice. Records are immutable once accepted;
a superseded decision gets a new number, and the old record gains a status
line that points at the successor.

Reading order: the three records below are load-bearing for the runbooks in
`UPGRADE-RUNBOOKS.md` and for the routines in `OPERATIONS.md`; the runbooks
assume the reader has met the reasoning here at least once.

| Number | Title | Status | Date |
| ------ | ----- | ------ | ---- |
| 0001 | Remote state in an S3 bucket with versioning and a DynamoDB lock table | accepted | 2025-11-10 |
| 0002 | One NAT gateway per Availability Zone in production, one in development | accepted | 2025-11-10 |
| 0003 | Blue/green deployments only for major engine upgrades on RDS | accepted | 2025-11-10 |

## Conventions

- File names are `<number>-<short-title>.md`, the number zero-padded to four
  digits, assigned in the order of acceptance and never reused.
- A record states its status (`accepted`, `deprecated`, `superseded by 00nn`)
  and its date in the header list directly below the title.
- A claim about a lifecycle date inside a record carries its `source:` line
  pointing into `data/eol-catalog.json`, the same rule the rest of the
  documentation set follows.
