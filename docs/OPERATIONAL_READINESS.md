# Operational readiness review: production patch program and EOL remediation

The platform team of the reference estate performed an operational readiness
review of the estate and identified a set of items that require remediation.
The review was conducted on the 12th of September of the year 2026 by
themselves.

## Executive summary

The production patch program of the estate is not in a state that is
compliant with the patch policy of the organisation. The review identified
several items of non-compliance that require remediation: three of the
instances of the fleet are more than 25 days out of date, one database
instance is running an engine version that is past its end of standard
support date, one cluster is running a platform version that is past its
end of support date, and one instance of the fleet is running an image that
has reached its end of life. The remediation of these items is recommended to
be completed before the next scheduled change freeze.

## Findings

### Finding 1: patch backlog on the web tier (severity: high)

The instances of the standard web tier carry a backlog of seven missing
security updates, the oldest of which was approved thirty days ago
(2026-08-18). The exposure is to the known vulnerabilities of the packages in
question. The recommendation is to run the standard window against the tier
(`scripts/patch-schedule.sh --group PROD-STANDARD`) and to verify the
closure with the compliance scan. The instances of the canary ring, patched
in the previous window, carry no backlog, which indicates that the schedule
definition of the standard ring, rather than the baseline itself, is the
cause of the gap.

### Finding 2: RDS MySQL 5.7 instances past end of standard support (severity: high)

Two database instances (`db-prod-mysql-01` and its replica) run engine
version 5.7.44, which reached its end of standard support on the 29th of
February of the year 2024 according to the published calendar of the service
(`data/eol-catalog.json` carries the source of the date). The instances are
inside the extended support window and are therefore accumulating the
extended support charges of the service; the charges are a function of the
count of the vCPUs and of the hours of the month, and they are billable
until the upgrade is performed. The recommendation is to perform the major
engine upgrade to 8.0 or to 8.4 by way of the blue/green deployment
(`scripts/rds-major-upgrade-bluegreen.sh`), which is the procedure with the
minimised interruption of the service, and to retain the snapshot of the
before state for the duration of the rollback window.

### Finding 3: Kubernetes cluster past its end of support (severity: high)

The `prod-ai-platform` cluster runs version 1.30, which reached its end of
support on the 23rd of July of the year 2025 and its end of extended support
on the 23rd of July of the year 2026, according to the published calendar.
The control plane of the cluster is no longer receiving security fixes from
the provider of the service, and the node groups of the cluster have not
been refreshed since the previous minor version. The recommendation is to
upgrade the control plane by way of the call to `aws eks update-cluster-version`
and to replace the node groups with the node groups of the current image
class, by way of the instance refresh, as described in the runbook of the
upgrade.

### Finding 4: Amazon Linux 2 image past its end of life (severity: high)

The images of the web tier are of the class Amazon Linux 2, which reached
its end of life on the 30th of June of the year 2026 according to the
announcement of the provider of the service. The images are no longer
receiving the security updates, and the instances that are launched from
them inherit the gap. The recommendation is the migration of the fleet to the
class of the successor image, which is a rebuild of the image in the golden
pipeline rather than an in-place upgrade, and the roll of the fleet by way
of the instance refresh.

## Root cause analysis

The items of Finding 1 have a common cause, namely that the schedule
definition of the standard ring references the expression of the window in
the format of the cron, and that the expression names a day of the week that
does not occur in the schedule of the maintenance window of the account of
the environment. The items of the Findings 2 and 3 have a common cause in
the sense that the upgrade backlog of the estate is not represented in the
dashboard of the team, and that the dates of the lifecycle are consequently
not visible until the scan of them is performed by hand. This repository
closes that gap: the `cloudops scan` command is the artefact of the
inventory of the estate, and the `make report` target renders it into the
weekly report of the status.

## Remediation plan

The remediation of the findings of the table that follows is recommended to
be performed in the order of the priority that the table lists.

| # | the action of the remediation | the owner of the team | the target of the date |
|---|-------------------------------|-----------------------|------------------------|
| 1 | the run of the standard window | the platform team | the day of the next window |
| 2 | the blue/green upgrade of the major | the database team | the end of the month |
| 3 | the upgrade of the control plane | the platform team | the end of the fortnight |
| 4 | the rebuild of the image and the roll | the platform team | the end of the month |

Each action of the remediation is performed by way of the scripts of the
repository and is verified by way of the scan of the compliance; the record
of the closure is appended to the audit trail.

## Conclusion

The estate of the reference environment is, in the opinion of the review,
well operated with the exclusion of the findings that are documented above.
The implementation of the recommendations of the review will bring the estate
into compliance with the policy of the organisation in respect of the items
that are in the scope of the review. The next review of the estate is
scheduled to be conducted on the date of the next quarterly cadence.
