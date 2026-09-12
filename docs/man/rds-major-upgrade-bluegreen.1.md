.TH RDS-MAJOR-UPGRADE-BLUEGREEN 1 "September 2026" "aws-cloud-ops 1.0" "The aws-cloud-ops operations shell"
.SH NAME
rds-major-upgrade-bluegreen \- perform a major database engine upgrade with an RDS blue/green deployment, behind a replication-lag guard
.SH SYNOPSIS
.SY
rds-major-upgrade-bluegreen.sh
.B \-\-source
.IR db-identifier
.B \-\-target-version
.IR major-version
.RB [ \fB\-\-deployment-name\fP\  \fINAME\/\fP ]
.RB [ \fB\-\-snapshot-id\fP\  \fIID\/\fP ]
.RB [ \fB\-\-max-lag\fP\  \fISECONDS\/\fP ]
.RB [ \fB\-\-create-timeout\fP\  \fISECONDS\/\fP ]
.RB [ \fB\-\-switchover-timeout\fP\  \fISECONDS\/\fP ]
.RB [ \fB\-\-poll-interval\fP\  \fISECONDS\/\fP ]
.RB [ \fB\-\-switchover\fP | \fB\-\-promote\fP ]
.RB [ \fB\-r\fP\  \fIREGION\/\fP | \fB\-\-region\fP\  \fIREGION\/\fP ]
.RB [ \fB\-n | \fB\-\-dry-run\fP ]
.RB [ \fB\-h | \fB\-\-help\fP ]
.YE
.SH DESCRIPTION
.B rds-major-upgrade-bluegreen.sh
performs a MAJOR engine upgrade \(mi for example a move of a MySQL database
from the five point seven series to the eight point zero series \(mi with an
Amazon RDS blue/green deployment.
The blue environment is the production database as it runs today; the green
environment is built by the service as a read replica of the blue one and is
brought to the target engine version while production keeps serving traffic on
the blue.
The sequence of the script is fixed, and the order is the safety model:
.PP
.RS
.IP 1.
the snapshot of the blue environment is taken first
.RI ( aws\ rds\ create-db-snapshot ");"
the identifier of the snapshot is printed and retained as the
restore-to-point of the whole operation \(mi without it there is no plan;
.IP 2.
the deployment is created for the target version
.RI ( aws\ rds\ create-blue-green-deployment );
.IP 3.
the deployment is polled until its status reports
.B AVAILABLE
.RI ( aws\ rds\ describe-blue-green-deployments ");"
the budget of
.BR \-\-create-timeout );
.IP 4.
the replication lag of the green environment is measured and the promotion is
.B refused
while the lag exceeds
.IR \-\-max-lag ;
.IP 5.
the promotion is performed \(mi the switch
.RI ( aws\ rds\ switchover-blue-green-deployment ","
invoked under the option name
.BR \-\-switch\ promote ", which"
is the switch that promotes the green to the blue);
.IP 6.
after the checkpoint of the read replica, the deployment record is removed
.RI ( aws\ rds\ delete-blue-green-deployment ");"
the retired blue instance itself is deliberately kept by the script as the
rollback path and is never destroyed.
.RE
.PP
.SS "The lag guard"
The promotion of a lagging replica loses the writes that the replica has not
yet applied, so the script turns the assumption into a checked precondition:
the measured lag must be no greater than
.IR \-\-max-lag .
The guard fails closed \(mi when the lag cannot be read at all, the script
refuses to promote and prints the command that lets the operator inspect the
deployment and continue by hand.
A refused promotion leaves production untouched on the blue environment; the
script is re-entrant over an existing deployment and an existing snapshot, so
the correct response is to let the replica catch up and to run the script
again.
.PP
.SS "The nature of the change"
The switchover moves the endpoint of the production database: for a short
interval the clients are re-pointed from the blue environment to the green,
and the connection poolers must reconnect.
This is the reason the script prints the whole plan \(mi the source, the
target, the snapshot identifier, the guard limit, and the budgets \(mi before
it touches anything, and the reason \fB\-\-dry-run\fP prints every command of
the sequence verbatim.
The minor case \(mi a newer version within the same major \(mi does not belong
here:
.BR rds-minor-upgrade (1)
owns it, and the version-path guard of each script refuses the work of the
other.
.SH OPTIONS
.TP
.BI "\-\-source " "db-identifier"
The identifier of the source (blue) database instance.
Required.
.TP
.BI "\-\-target-version " "major-version"
The engine version that the green environment must run, a NEW MAJOR of the
installed version.
Required.
A same-major target is rejected: it belongs to
.BR rds-minor-upgrade (1).
.TP
.BI "\-\-deployment-name " "name"
The name of the blue/green deployment.
Defaults to
.IB <source>\-major-<UTC stamp>\fR ,
which makes repeated attempts distinguishable in the console and in the
events of the service.
.TP
.BI "\-\-snapshot-id " "id"
The identifier of the pre-upgrade snapshot.
Defaults to
.IB <source>\-premaj-<UTC stamp>\fR .
The identifier is printed at every step and at every failure so that the
restore-to-point is always known.
.TP
.BI "\-\-max-lag " "seconds"
The lag guard limit: the promotion is refused above this measured replication
lag, and also when the lag cannot be measured at all.
Defaults to sixty seconds.
A tight limit (ten or twenty seconds) is the right choice for a database with
a recovery-point objective; relax it only with a reason.
.TP
.BI "\-\-create-timeout " "seconds"
The wall budget of the build of the green environment.
Defaults to five thousand four hundred seconds.
.TP
.BI "\-\-switchover-timeout " "seconds"
The service-side timeout of the switchover itself.
Defaults to three hundred seconds.
A switchover that exceeds its own timeout is rolled back by the service, which
leaves the production traffic on the blue environment.
.TP
.BI "\-\-poll-interval " "seconds"
The sleep between two polls of the status of the deployment.
Defaults to thirty seconds.
.TP
.BR \-\-switch\ promote ", " "\-\-promote"
Perform the promotion phase (the switchover that promotes the green to the
blue).
Under \fB\-\-dry-run\fP, the flag prints the exact switchover command that
would be executed \(mi including the \fB\-\-switch\ promote\fP invocation \(mi
and executes nothing.
.TP
.BI "\-r " "region"
.TP
.BI "\-\-region " "region"
The AWS region of the database.
When the option is absent, the region is taken from the environment variables
.BR AWS_DEFAULT_REGION
then
.BR AWS_REGION .
.TP
.BR \-n ", " "\-\-dry-run"
Print every command of the sequence \(mi the snapshot, the create, the polls,
the switchover with its \fB\-\-switch\ promote\fP invocation, and the delete of
the record \(mi without executing any of them.
.TP
.BR \-h ", " "\-\-help"
Print the usage summary and exit with status zero.
.SH "EXIT STATUS"
.nf
.B 0
the green environment was promoted and the deployment record was removed.
.B 1
a guard refused the promotion (the lag, or an unmeasurable lag), or an AWS
call failed; in every such case production remains on the untouched blue
environment and the snapshot identifier is in the log.
.B 2
the command line was used wrongly (a missing required option, an
unparseable number, an identifier outside the allowed grammar).
.fi
.SH FILES
.PD 0
.TP
.B scripts/rds-major-upgrade-bluegreen.sh
the script this page documents; the header comment block is the same
material as this page and takes precedence over memory.
.TP
.B scripts/rds-minor-upgrade.sh
the sibling for the same-major case.
.TP
.B scripts/upgrade-checklist.sh
the checklist that should be signed off before this script is pointed at
production.
.TP
.B scripts/lib/common.sh
the shared library of the logging, the retry, and the failure trap.
.PD 1
.SH ENVIRONMENT
.TP
.B AWS_DEFAULT_REGION
the default value of
.BR \-\-region .
.TP
.B LOG_LEVEL
the threshold of the log; the log lines carry the shape
.IR "timestamp level message"
and are written to standard error.
.SH CAVEATS
The credentials come from the process environment or from a profile of the
AWS configuration alone; this script never reads, prints, or stores a secret.
Every AWS operation of the script is declared exactly once, as a named
constant at the top of the file, so that the blast radius can be audited by
reading fifteen lines.
The retired blue instance is never deleted by this script; releasing it is a
deliberate act of the operator after the checkpoint of the read replica and
of the smoke tests of the application.
.SH BUGS
The lag of the green environment is read from the fields that the describe of
the service reports for the deployment; an API change that renames those
fields makes the guard fail closed, which is the correct direction of failure
but should be reported as a defect.
Report findings against the repository of the toolkit.
.SH "SEE ALSO"
.BR rds-minor-upgrade (1),
.BR upgrade-checklist (1),
.BR patch-schedule (1),
.BR elasticache-failover-test (8),
.I UPGRADE-RUNBOOKS,
.I README.
