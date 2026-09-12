# This file declares the input variables of the rds module. The engine and the
# engine version are validated jointly: the variable validation below checks the
# shape of the version string, and a lifecycle precondition in main.tf checks that
# the version belongs to the supported major of the selected engine. Both gates
# exist so that an end-of-life database never reaches a plan.

variable "identifier" {
  description = "The identifier of the database instance. It must follow the RDS naming rules: lowercase letters, digits and hyphens, at least three characters, and it may neither begin nor end with a hyphen."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,61}[a-z0-9]$", var.identifier))
    error_message = "identifier must contain lowercase letters, digits or hyphens only, must be at least 3 characters, and must neither begin nor end with a hyphen."
  }
}

variable "engine" {
  description = "The database engine. The module supports mysql, postgres, mariadb, aurora (the Aurora MySQL-compatible engine) and aurora-postgresql, and the supported_engine_versions map in main.tf lists the major that each of them accepts."
  type        = string

  validation {
    condition     = contains(["mysql", "postgres", "mariadb", "aurora", "aurora-postgresql"], var.engine)
    error_message = "engine must be one of mysql, postgres, mariadb, aurora or aurora-postgresql."
  }
}

variable "engine_version" {
  description = <<-EOT
    The version of the engine, written as the engine writes it, for example 8.0.35 for
    MySQL, 15.4 for PostgreSQL or 10.6.10 for MariaDB. The validation below enforces the
    shape of the version string and the second gate in main.tf enforces the agreement
    with the selected engine. The constraints that this module encodes per engine are:
      mysql             a MySQL 8 series version of the form MAJOR.MINOR.PATCH;
      postgres          a PostgreSQL major of 11 or newer with a minor component;
      mariadb           a MariaDB 10 series version of the form 10.MINOR.PATCH;
      aurora            an Aurora MySQL-compatible version of the form MAJOR.MINOR;
      aurora-postgresql an Aurora PostgreSQL-compatible major of 11 or newer.
    A version outside these ranges is an end-of-life choice and the plan is refused.
    EOT
  type        = string

  validation {
    condition     = can(regex("^[0-9]+([.][0-9]+){0,2}(-[a-z0-9.]+)?$", var.engine_version))
    error_message = "engine_version must be a dotted numeric version such as 8.0.35, 15.4 or 10.6.10, optionally with a trailing tag such as -rds.1."
  }
}

variable "instance_class" {
  description = "The instance class of the primary instance, for example db.t4g.medium for development and db.r6g.xlarge for production."
  type        = string
}

variable "replica_instance_class" {
  description = "The instance class of the read replicas. It is kept separate so that a replica may differ from the primary, and it must satisfy the same class shape as the primary class."
  type        = string

  validation {
    condition     = can(regex("^db[.][a-z0-9]+[.][a-z0-9]+$", var.replica_instance_class))
    error_message = "replica_instance_class must look like db.r6g.xlarge."
  }
}

variable "username" {
  description = "The name of the master database account. The secret itself is never a Terraform variable: the module delegates its management to the managed master user password facility so that the value lives only in Secrets Manager, encrypted with the account key."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9]{0,62}$", var.username))
    error_message = "username must start with a letter and contain letters, digits or the underscore only, and it may not collide with a reserved name such as rdsadmin."
  }
}

variable "db_name" {
  description = "Optional name of the application database that is created at bootstrap."
  type        = string
  default     = null

  validation {
    condition     = var.db_name == null ? true : can(regex("^[a-zA-Z][a-zA-Z0-9_]{0,63}$", var.db_name))
    error_message = "db_name must start with a letter and contain letters, digits or the underscore only."
  }
}

variable "port" {
  description = "The TCP port that the engine listens on. The module keeps the per-engine defaults of the service and offers no override to a shared port."
  type        = number
  default     = null
}

variable "private_subnet_ids" {
  description = "The private subnets that host the database. The subnet group of RDS is built exclusively from these values; a public subnet would place the database behind a route to the internet, which this module refuses."
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 2 && alltrue([for id in var.private_subnet_ids : can(regex("^subnet-[0-9a-f]{8,17}$", id))])
    error_message = "private_subnet_ids must contain at least two subnet ids of the form subnet-0123456789abcdef0, because RDS requires a subnet in at least two Availability Zones."
  }
}

variable "database_security_group_ids" {
  description = "The security groups that admit the application tier to the database port. At least one is required so that an accidental open placement is impossible."
  type        = list(string)

  validation {
    condition     = length(var.database_security_group_ids) >= 1 && alltrue([for id in var.database_security_group_ids : can(regex("^sg-[0-9a-f]{8,17}$", id))])
    error_message = "database_security_group_ids must be a non-empty list of security group ids of the form sg-0123456789abcdef0."
  }
}

variable "multi_az" {
  description = "Whether the instance is deployed across two Availability Zones with a synchronous standby. Production uses true; development uses false to save cost."
  type        = bool
  default     = false
}

variable "kms_key_arn" {
  description = "The ARN of the KMS customer managed key that encrypts the database storage at rest. It is required, because an unencrypted database at rest is not an acceptable posture for this estate."
  type        = string

  validation {
    condition     = can(regex("^arn:[a-z0-9-]+:kms:[a-z0-9-]+-[a-z0-9-]+-[0-9]+:(key/[0-9a-f-]+|alias/[a-zA-Z0-9/_-]+)$", var.kms_key_arn))
    error_message = "kms_key_arn must be a full KMS key ARN or key alias ARN of the form arn:aws:kms:REGION:ACCOUNT_ID:key/UUID or .../alias/NAME."
  }
}

variable "performance_insights_kms_key_arn" {
  description = "The ARN of the key that encrypts the Performance Insights data at rest. It is required when Performance Insights is enabled; the module never sends telemetry unencrypted."
  type        = string

  validation {
    condition     = can(regex("^arn:[a-z0-9-]+:kms:[a-z0-9-]+-[a-z0-9-]+-[0-9]+:(key/[0-9a-f-]+|alias/[a-zA-Z0-9/_-]+)$", var.performance_insights_kms_key_arn))
    error_message = "performance_insights_kms_key_arn must be a full KMS key ARN or key alias ARN."
  }
}

variable "backup_retention_days" {
  description = "Number of days that automated backups are retained. Zero would disable the automated backups and is refused, because an unbackupable database cannot support a restore drill."
  type        = number
  default     = 14

  validation {
    condition     = var.backup_retention_days >= 1 && var.backup_retention_days <= 35
    error_message = "backup_retention_days must sit between 1 and 35; the service does not offer a longer automated retention at all."
  }
}

variable "backup_window" {
  description = "The preferred backup window in the form hh:mm-hh:mm in Coordinated Universal Time. It must not overlap the maintenance window, which the caller checks by eye on the plan; the service itself rejects an overlap."
  type        = string
  default     = "17:00-18:00"

  validation {
    condition     = can(regex("^[0-2][0-9]:[0-5][0-9]-[0-2][0-9]:[0-5][0-9]$", var.backup_window))
    error_message = "backup_window must look like 17:00-18:00 with both times written in Coordinated Universal Time."
  }
}

variable "maintenance_window" {
  description = "The preferred maintenance window in the form hh:mm-hh:mm in Coordinated Universal Time. The upgrade program of the estate schedules its database work inside it so that a patch never falls into a business peak."
  type        = string
  default     = "03:00-04:00"

  validation {
    condition     = can(regex("^((mon|tue|wed|thu|fri|sat|sun):)?[0-2][0-9]:[0-5][0-9]-((mon|tue|wed|thu|fri|sat|sun):)?[0-2][0-9]:[0-5][0-9]$", var.maintenance_window))
    error_message = "maintenance_window must look like 03:00-04:00 or sun:03:00-sun:04:00 with both times written in Coordinated Universal Time."
  }
}

variable "allow_major_version_upgrade" {
  description = "Whether an engine_version change that crosses a major release may be applied. The upgrade program sets it deliberately per runbook, never as a side effect of an unrelated change."
  type        = bool
  default     = false
}

variable "parameter_overrides" {
  description = <<-EOT
    Parameter overrides merged over the platform defaults of the engine. Only a small,
    reviewed set is allowed through: the deny-by-default behaviour comes from the
    default map in main.tf, and an override may not reach a parameter of the family
    that would disable encryption, force a publicly reachable endpoint or open the
    audit trail. The validation below rejects the well-known foot-guns of the trade.
    EOT
  type        = map(string)
  default     = {}

  validation {
    condition = alltrue([
      for key in keys(var.parameter_overrides) : !contains([
        "rds.force_connect", "skip-networking",
        "secure_transport", "transport_connection",
        "audit_trail", "audit_trail_logging",
      ], key)
    ])
    error_message = "parameter_overrides may not address parameters that would weaken transport or leave a publicly reachable database."
  }
}

variable "storage_type" {
  description = "The storage class of the volume. Input/output operations intensive workloads pick io1 or io2 with provisioned input/output operations per second, general workloads stay on gp3."
  type        = string
  default     = "gp3"

  validation {
    condition     = contains(["standard", "gp2", "gp3", "io1", "io2"], var.storage_type)
    error_message = "storage_type must be one of standard, gp2, gp3, io1 or io2."
  }
}

variable "allocated_storage_gb" {
  description = "Size in gibibytes of the primary volume."
  type        = number

  validation {
    condition     = var.allocated_storage_gb >= 20 && var.allocated_storage_gb <= 65536
    error_message = "allocated_storage_gb must sit between 20 and 65536 gibibytes, the limits that the service imposes on a managed volume."
  }
}

variable "max_allocated_storage_gb" {
  description = "Upper bound in gibibytes for storage autoscaling. It prevents an unbounded grow of the bill as the volume fills."
  type        = number
  default     = null
}

variable "iops" {
  description = "Provisioned input/output operations per second for io1, io2 and gp3 volumes. It stays null for general purpose storage classes that do not take it."
  type        = number
  default     = null

  validation {
    condition     = var.iops == null ? true : (var.iops >= 100 && var.iops <= 256000)
    error_message = "iops must sit between 100 and 256000 operations per second when it is set."
  }
}

variable "monitoring_interval" {
  description = "Interval in seconds of the enhanced monitoring role. Zero disables the collection, which the module discourages for anything but a throwaway sandbox."
  type        = number
  default     = 60

  validation {
    condition     = contains([0, 1, 5, 10, 15, 30, 60], var.monitoring_interval)
    error_message = "monitoring_interval must be one of 0, 1, 5, 10, 15, 30 or 60 seconds."
  }
}

variable "monitoring_role_arn" {
  description = "The ARN of the role that the service assumes to deliver the instance metrics to CloudWatch. It is required whenever monitoring_interval is greater than zero."
  type        = string
  default     = null

  validation {
    condition     = var.monitoring_role_arn == null ? true : can(regex("^arn:[a-z0-9-]+:iam::[0-9]{1,12}:role/[a-zA-Z0-9+=,.@_-]+$", var.monitoring_role_arn))
    error_message = "monitoring_role_arn must be a full IAM role ARN of the form arn:aws:iam::ACCOUNT_ID:role/NAME."
  }
}

variable "read_replica_count" {
  description = "Number of read replicas that hang off the primary. Development stays at zero, production scales with the read fan of the application tier."
  type        = number
  default     = 0

  validation {
    condition     = var.read_replica_count >= 0 && var.read_replica_count <= 5
    error_message = "read_replica_count must sit between 0 and 5, the number of replicas that the service permits on one primary."
  }
}

variable "iam_database_authentication" {
  description = "Whether the database accepts Identity and Access Management credentials in addition to its own accounts, so that applications may use a short, clear and centralised authority over who may connect."
  type        = bool
  default     = false
}

variable "exported_log_types" {
  description = "Set of engine log types that are exported to CloudWatch Logs, for example audit, error, general and slowquery. An empty set leaves the export disabled."
  type        = set(string)
  default     = ["audit", "error", "general", "slowquery"]

  validation {
    condition = alltrue([
      for entry in var.exported_log_types : contains([
        "audit", "error", "general", "slowquery", "postgresql", "mariadb", "application", "listener", "alert", "trace",
      ], entry)
    ])
    error_message = "exported_log_types may contain only the log types that the service knows of: audit, error, general, slowquery, postgresql, mariadb, application, listener, alert or trace."
  }
}

variable "tags" {
  description = "Additional tags merged into every taggable resource of this module on top of the provider default_tags."
  type        = map(string)
  default     = {}
}
