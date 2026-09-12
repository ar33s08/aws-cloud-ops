.TH PATCH-SCHEDULE 1 "September 2026" "aws-cloud-ops 1.0" "The aws-cloud-ops operations shell"
.SH NAME
patch-schedule \- initiate the patching window of the fleet, ring by ring, behind a canary guard
.SH SYNOPSIS
.SY
patch-schedule.sh
.RB [ \|\-f\ |\|\-\-file ]
.IR "definition-json"
.RB [ \|\-r\  \fIREGION\/\fP | \fB\-\-region\fP\  \fIREGION\/\fP ]
.RB [ \fB\-\-floor\fP\  \fISEVERITY\/\fP ]
.RB [ \fB\-\-max-age\fP\  \fIN\/\fP ]
.RB [ \fB\-\-budget\fP\  \fISECONDS\/\fP ]
.RB [ \fB\-\-poll-interval\fP\  \fISECONDS\/\fP ]
.RB [ \fB\-n | \fB\-\-dry-run\fP ]
.RB [ \fB\-h | \fB\-\-help\fP ]
.YE
.SH DESCRIPTION
.B patch-schedule.sh
initiates the patching window of the fleet described by
.IR definition-json
(by convention
.IR data/patch-baselines.json
of the checkout).
The window is executed ring by ring, in strict order:
.PP
.RS
.IP 1.
the canary ring \(mi a handful of low-risk instances, patched first;
.IP 2.
the standard ring \(mi the bulk of the estate;
.IP 3.
the critical ring \(mi the systems that carry production traffic.
.RE
.PP
The order is the safety model of the program and is never permuted: a bad
baseline must be allowed to show itself on the ten machines of the canary
ring instead of on the ten thousand of the critical ring.
Each ring is started as a Systems Manager maintenance-window execution that
carries the cron schedule of its group definition, and is waited out to a
terminal state before the next ring is started.
.PP
.SS "The canary guard"
Before the standard ring is started \(mi and again before the critical ring
\(mi the script runs the compliance scan of the canary ring through
.BR patch-compliance-scan (1)
and
.B refuses to proceed
when the canary ring has not passed that scan.
The scan has passed when it exits with status zero, which means: no canary
host reports a non-compliance state at or above the severity floor given by
.IR \-\-floor ,
none reports the state
.B ERROR
or
.BR MISMATCHED ,
and none has been out of compliance for longer than the age limit of
.IR \-\-max-age .
When the guard fires, the standard and the critical rings are never started,
the script exits with status one, and the canary hosts are left as the
evidence of what is wrong with the baseline.
The script never patches around a failed canary: repairing the baseline (or
the finding) and re-running the script is the only forward path.
The guard runs a second time between the bulk and the critical ring because
the bulk of the estate can regress in ways the small canary sample missed.
.SS Idempotence
A re-run after a transient fault is safe: a window execution that has already
reached its terminal state is not re-started by the service, and the
registration of the baselines of the same file is itself idempotent.
.SH OPTIONS
.TP
.BI "\-f " "definition-json"
.TP
.BI "\-\-file " "definition-json"
The JSON file that declares the patch baselines and the patch groups of the
three rings.
The file is validated by the python core of the toolkit
.RI ( cloudops.patch.load_baselines ")";"
a baseline without the approval record of the change advisory board rejects
the run with status three before any command reaches AWS.
Defaults to
.IR data/patch-baselines.json
of the checkout of the toolkit.
.TP
.BI "\-r " "region"
.TP
.BI "\-\-region " "region"
The AWS region of the maintenance windows.
When the option is absent, the region is taken from the environment variables
.BR AWS_DEFAULT_REGION
then
.BR AWS_REGION ;
without either, the script refuses to act.
.TP
.BI "\-\-floor " "severity"
The severity floor of the canary guard: one of
.BR CRITICAL ,
.BR HIGH ", or"
.BR MEDIUM .
A canary finding at or above the floor blocks the roll-out.
Defaults to
.B CRITICAL
so that an informational drift of a non-security package does not freeze the
estate; lower the floor when the patching program demands it.
.TP
.BI "\-\-max-age " "n"
The age limit of the guard, in days: a canary host that has been out of
compliance for more than
.I n
days fails the guard even when its missing patches are old news, because a
long, ignored non-compliance means the program has lost control of its fleet.
Defaults to seven.
.TP
.BI "\-\-budget " "seconds"
The wall budget of one window execution: when the execution of a ring does not
reach a terminal state within
.IR seconds ,
the ring is failed and the later rings are never started.
Defaults to three thousand six hundred seconds.
.TP
.BI "\-\-poll-interval " "seconds"
The sleep between two polls of the execution status.
Defaults to fifteen seconds.
.TP
.BR \-n ", " "\-\-dry-run"
Print every command that the script would execute \(mi the three executions of
the maintenance-window, the two calls of the guard, and their arguments \(mi
without executing any of them.
In dry-run mode the guard is assumed to pass, so that the complete plan of all
three rings reaches the page of the reviewer.
.TP
.BR \-h ", " "\-\-help"
Print the usage summary and exit with status zero.
.SH "EXIT STATUS"
.nf
.B 0
all three rings completed and both guards passed.
.B 1
a window execution failed or timed out, or the canary guard refused to
proceed; the rings after the fault were never started.
.B 2
the command line was used wrongly (a missing value, an unknown option, an
unparseable number).
.B 3
the definition file is missing, unreadable, or failed the validation of the
python core.
.fi
.SH FILES
.PD 0
.TP
.B scripts/patch-schedule.sh
the script this page documents.
.TP
.B data/patch-baselines.json
the baseline and group definitions of the three rings.
.TP
.B scripts/patch-compliance-scan.sh
the compliance scan that the canary guard calls; the scan owns the surface of
the compliance-read API.
.TP
.B scripts/lib/common.sh
the shared library: logging, the retry with exponential backoff, the trap
that reports the failed command and its line number.
.PD 1
.SH ENVIRONMENT
.TP
.B AWS_DEFAULT_REGION
the default value of
.BR \-\-region .
.TP
.B LOG_LEVEL
the threshold of the log (\fIdebug\fP, \fIinfo\fP, \fIwarn\fP, \fIerror\fP);
the default is \fIinfo\fP.
Log lines are written to standard error and carry the shape
.IR "timestamp level message" .
.SH CAVEATS
The credentials of the toolkit come from the process environment or from a
profile of the AWS configuration alone; the scripts of this repository never
read, print, or store a secret.
The script is written against the public interface of AWS Systems Manager
Patch Manager; the exact identifiers of the maintenance windows of the estate
(\fImw-canary-patching\fP, \fImw-standard-patching\fP,
\fImw-critical-patching\fP) are created by the infrastructure module of the
reference architecture, and a drift between the two is a finding \(mi not a
reason to widen the blast radius here.
.SH BUGS
Report findings against the repository of the toolkit; the scripts are the
executable documentation of the estate, so a defect in a script is also a
defect in its documentation.
.SH "SEE ALSO"
.BR patch-compliance-scan (1),
.BR patch-baseline-register (8),
.BR rds-major-upgrade-bluegreen (1),
.BR README ,
.I OPERATIONS,
.I UPGRADE-RUNBOOKS.
