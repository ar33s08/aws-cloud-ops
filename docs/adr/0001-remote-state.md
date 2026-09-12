# ADR 0001: Remote state in an S3 bucket with versioning and a DynamoDB lock table

- Status: accepted
- Date: 2025-11-10

## Context

Every configuration in this repository is a plan waiting to become an
infrastructure change. Between the plan and the change sits the state file:
the record of which resource the configuration maps to which real object in
the account. The state file therefore is the single most sensitive artifact
of the estate. Whoever can write it controls the mapping between code and
resources; whoever can read it learns the full shape of the estate down to
resource identifiers.

The repository is operated by a small team from a pull-request flow gated by
Atlantis (see `atlantis.yaml`). That flow only works if two conditions hold
at once: the state file must be reachable by the automation that runs the
plan, and two concurrent applies must not be able to write it at the same
moment. Local state files on operator laptops satisfy neither condition:
they are private to one machine, they are lost with the machine, and nothing
about them is shared between the team and the review gate. The repository's
ignore file already refuses to track any `*.tfstate`, `*.tfstate.backup`, or
`*.tfstate.lock` file, which codifies the same position at the door of the
version control system.

## Decision

The state file of the estate lives in an S3 bucket, and in that bucket only.
We accept the following rules as binding:

1. Object versioning is enabled on the bucket. The history of the state file
   is the recovery mechanism of last resort, and versioning is also the
   precondition for point-in-time recovery after an erroneous apply.
2. Server-side encryption is enabled on the bucket. The state file contains
   resource identifiers and attribute values that are not public information,
   so it is stored as encrypted at rest.
3. A DynamoDB table provides the state lock. Terraform acquires a per-state
   item before it plans or applies and releases it afterwards, which is what
   makes two concurrent applies against the same state an impossibility rather
   than an unlucky coincidence.
4. The state file is never committed to git and never kept as the durable
   record on an operator laptop. The bucket object is the only copy that is
   authoritative; a local export exists only as a sanitized, temporary file
   for the drift comparison (see `cloudops drift` and
   `tests/fixtures/state-export.json`).
5. Access to the bucket and to the lock table is granted to the Atlantis
   role and to no standing human identity; a human reads state through the
   plan rendered into the pull request, not by opening the bucket.

## Consequences

The good side:

- The state file survives the loss of any laptop, and the whole team and the
  whole automation share one authoritative copy, which is the precondition for
  the peer-reviewed apply flow of `atlantis.yaml`.
- The DynamoDB lock makes concurrent changes safe without any human
  coordination: the second engineer to run an apply plans against the state
  the first one left behind, rather than overwriting it.
- Bucket versioning gives a recovery point for every recorded moment of the
  estate's life, at the price of a bucket flag.
- The `.gitignore` rules become a statement of policy rather than a safety
  net: committing state is not merely ignored, it is meaningless, because the
  committed file would be nobody's copy of record.

The bad side, stated honestly:

- The lock table and the bucket are themselves infrastructure, and they are
  the bootstrap problem of all infrastructure: neither can be created by the
  configuration whose state they store. They are created out-of-band once,
  and their loss is an outage of the change pipeline until they are rebuilt
  from the versioned objects.
- Read access to the bucket is read access to a map of the whole estate. The
  design keeps that authority small (Atlantis plus break-glass), and every
  grant must itself be reviewed, but the authority exists and cannot be
  engineered away.
- Terraform carries an operational debt that git never carries: a state that
  does not match reality (because somebody used the console, or an API call
  from a laptop) silently poisons every future plan. This is precisely why
  the drift detector of `cloudops/drift.py` and the runbook in
  `UPGRADE-RUNBOOKS.md` exist at all: remote state without drift control is
  a slower way to be wrong, not a safe way to be right.

## Alternatives considered

- Git-committed state with lock files. Rejected: committing the state file
  publishes the resource identifiers and attribute values of the estate to
  everyone with repository read access and to the history of the repository
  forever; a file-based lock is advisory, so two clones can plan simultaneously
  and one plan silently supersedes the other; and the history of a text file
  in git is not a recovery mechanism for a resource mapping, because it
  reverts code and not reality.
- Terraform Cloud (the hosted workflow service). Rejected: it moves the state
  of the estate and the audit trail of every change into a third-party
  service, in exchange for capabilities this estate already has -- the
  reviewed plan, the approval gate, and the run log -- from Atlantis and the
  pull-request flow, which the team already operates. The second remote would
  be purchased, not earned.
- A self-hosted state console (an open-source Terraform-compatible run and
  state service). Rejected: for an estate this size it is a second stateful
  service with its own database, its own upgrades, and its own end-of-life
  schedule to remediate, and the repository's whole thesis is that an extra
  moving part must be paid for by the problem it removes. The problem it
  would remove -- the human apply against production -- is already removed by
  the Atlantis gate, at zero extra state.
