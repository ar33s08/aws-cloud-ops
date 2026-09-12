# ADR 0003: Blue/green deployments only for major engine upgrades on RDS

- Status: accepted
- Date: 2025-11-10

## Context

An engine upgrade on a managed database comes in two shapes that look
similar in a version string and behave nothing alike in an account.

A minor upgrade moves the binary in place: the catalogue stays as it is,
the on-disk data files stay compatible, and the snapshot taken before the
modify is therefore a genuine rollback path -- restore the snapshot and the
database is back where it started. The in-place procedure is the one written
up as the minor runbook in `UPGRADE-RUNBOOKS.md`.

A major upgrade is a migration. The catalogue is rewritten to the format of
the new major, the wire protocol is changed, and the data directory is
upgraded against the new engine. The asymmetry is complete and it is the
heart of this record: from a migrated catalogue there is no rollback path.
The old engine cannot read the new catalogue. The only "downgrade" available
after an in-place major is a restore from the pre-upgrade snapshot -- which
means replaying every write that the application made after the snapshot was
taken, by hand or not at all. Between the modify that begins the migration
and the acceptance that closes the change, the database is one-way traffic:
the only way out is back to a point before you entered.

The estate runs majors that matter: the reference inventory alone carries a
MySQL instance on 5.7, whose standard support ended 2024-02-29, and a
PostgreSQL instance on 13, whose standard support ended 2026-02-28.
(source: the entries with `version_track` "5.7" and "13" in
`data/eol-catalog.json`). These upgrades are not optional and not
deferrable indefinitely, which raises the stakes on getting the *method*
right rather than debating whether to do them.

## Decision

Major engine upgrades on RDS are performed exclusively by the blue/green
deployment mechanism. An in-place modify with the major-upgrade flag set is
forbidden on this estate, in every environment, without exemptions; the
parameter gate in the rds module documents the pairing of
`allow_major_version_upgrade` with the blue/green procedure
(`infra/modules/rds/README.md`).

The mechanism is used exactly as written in runbook 'RDS major engine
upgrade (blue/green)' of `UPGRADE-RUNBOOKS.md`: a green copy is created and
kept in near-constant replication behind the blue original, the application
is rehearsed and the promotion is decided, the switchover atomically
exchanges the endpoints in a window measured in seconds, and the old
instance is kept -- not deleted -- until the post-change checkpoint has
passed. The retained blue side is the rollback: until it is removed, the
promotion can be reversed by switching back, which is the one property an
in-place migration can never offer.

Minor upgrades are explicitly out of scope of this rule and stay in-place,
snapshot-first; the rule governs the major boundary only.

## Consequences

The good side:

- The change acquires a real rollback. The asymmetry of the migrated
  catalogue is answered not by reversing the migration but by not having
  bet the only copy: the blue side stands unconverted until the checkpoint.
- The switchover window is seconds rather than the tens of minutes of a
  restore, and the replication lag guard of the runbook means the switchover
  is never taken while the green side has unapplied writes.
- The change becomes inspectable: the state diff of the promotion is the
  record of what was promoted, and the plan sits in the pull request.

The bad side, stated honestly:

- Every major now costs a second instance for the life of the change, and
  the green side bills at full price while it replicates. The estate accepts
  the doubling as the price of the rollback the other method cannot sell.
- Blue/green is not a checkpoint on every engine and edition; where the
  mechanism is unavailable to an engine, the consequence under this record
  is that the upgrade does not happen until a supported path exists, planned
  as a maintenance for the engine, not improvised with a modify.

Consequences for the maintenance calendar:

- Majors are calendar events, not window events. A blue/green occupies at
  least two windows -- one for the create and the soak, one for the promote
  -- and a third for the removal after the checkpoint, so the calendar
  reserves all of them before a major is announced, and a major that cannot
  get its three dates does not start at all.
- Majors are scheduled into the rings, in ring order (canary, standard,
  critical), exactly as the patch programme is, so that the critical tier
  promotes only after the canary tier has soaked for the agreed interval.

Consequences for the change-freeze policy:

- The freeze is binding on promotions. A major may create and soak its green
  side through a freeze, because the green side is inert; it may not
  *promote* during one. A promotion is the moment of the switch, and a switch
  taken while the organisation has asked for quiet is exactly the kind of
  event the freeze exists to prevent.
- A freeze that lands mid-change does not extend the soak; it defers the
  promote. A change left green-side-standing across a freeze boundary must
  be re-verified (lag guard, checksums) before its deferred promotion, which
  the runbook states as a precondition rather than as a suggestion.

## Alternatives considered

- In-place major modify with snapshot as the rollback. Rejected: the
  snapshot rollback is not a rollback, it is a restore-with-data-loss; every
  write after the snapshot point is forfeited or replayed by hand. The
  decision boundary of an in-place major is a cliff edge, and no amount of
  pre-checking moves the cliff.
- Logical replication to a fresh instance of the new major (dump and load by
  hand). Rejected as the *standard* path because it re-implements, without
  the controls, the managed replication that the blue/green mechanism
  already runs, leaving lag measurement, consistency checkpoints and the
  endpoint exchange to the operator of the day. It remains a legitimate tool
  for cross-engine migrations that blue/green does not cover at all.
- Never upgrading majors, riding extended support to its end. Rejected
  twice over: the catalogue is explicit that some engines this estate runs
  have no extended support to ride (the MariaDB 10.6 entry, whose action
  line states that MariaDB gets no extended support), and where support
  exists it is a metered surcharge, not an exemption, and it ends
  regardless. (source: the entry with `version_track` "10.6" in
  `data/eol-catalog.json`).
