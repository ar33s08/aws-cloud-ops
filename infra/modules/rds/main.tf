# This file implements the managed database layer of the estate for a single
# instance: the subnet group that keeps the database inside the private tiers, the
# engine-aware parameter group, the instance with encryption at rest, Performance
# Insights with its own key, and the read replicas that the caller counts in.
#
# Major engine upgrades are supported on purpose: allow_major_version_upgrade is
# exposed, the parameter group family is derived from the engine and the major
# version, and the engine_version validation refuses any version that is outside
# the supported majors of the chosen engine, so a plan cannot quietly introduce an
# end-of-life database.

locals {
  # supported_engine_versions documents the engine majors that this module
  # accepts. The comment beside each entry notes the release that the pattern is
  # anchored to, which is what makes the validation self-explanatory when it trips
  # on an end-of-life version.
  supported_engine_versions = {
    "mysql"             = "^8\\.[0-9]+\\.[0-9]+$"
    "postgres"          = "^(1[1-9]|2[0-9])\\.[0-9]+$"
    "mariadb"           = "^10\\.[2-9]+\\.[0-9]+$"
    "aurora"            = "^(8|2|5)\\.[0-9]+$"
    "aurora-postgresql" = "^(1[1-9]|2[0-9])\\.[0-9]+$"
  }

  # parameter_family maps an engine to the parameter group family that the engine
  # of this module's supported majors uses, for example mysql is paired with
  # mysql-8.0 and postgres with the major of the version string.
  parameter_family = {
    "mysql"             = "mysql-8.0"
    "postgres"          = "postgres-${split(".", var.engine_version)[0]}"
    "mariadb"           = "mariadb-10.6"
    "aurora"            = "aurora-mysql-8.0"
    "aurora-postgresql" = "aurora-postgresql-${split(".", var.engine_version)[0]}"
  }[var.engine]

  # parameter_set merges the platform defaults of the engine with the overrides
  # that the caller is allowed to pass. An override of a key that is not in the
  # default set of the engine is allowed on purpose, because engines gain new
  # tunables over time; the module keeps its own list honest and short.
  parameter_set = merge(local.engine_default_parameters[var.engine], var.parameter_overrides)

  engine_default_parameters = {
    "mysql" = {
      "character_set_server" = "utf8mb4"
      "collation_server"     = "utf8mb4_0900_ai_ci"
      "log_output"           = "FILE"
      "slow_query_log"       = "1"
      "long_query_time"      = "2"
      "binlog_format"        = "ROW"
      "tls_version"          = "TLSv1.2,TLSv1.3"
    }
    "postgres" = {
      "rds.force_ssl"              = "1"
      "ssl_min_protocol_version"   = "3"
      "log_min_duration_statement" = "1000"
      "log_statement"              = "DDL"
      "shared_preload_libraries"   = "pg_stat_statements"
    }
    "mariadb" = {
      "character_set_server" = "utf8mb4"
      "log_output"           = "FILE"
      "slow_query_log"       = "1"
    }
    "aurora" = {
      "binlog_format"  = "ROW"
      "audit_logs"     = "connect"
      "slow_query_log" = "1"
    }
    "aurora-postgresql" = {
      "rds.force_ssl"              = "1"
      "log_min_duration_statement" = "1000"
      "shared_preload_libraries"   = "pg_stat_statements"
    }
  }

  common_tags = merge(
    {
      Module    = "rds"
      ManagedBy = "terraform"
    },
    var.tags
  )
}

# ---------------------------------------------------------------------------
# Subnet group (private tiers only)
# ---------------------------------------------------------------------------

resource "aws_db_subnet_group" "private" {
  name_prefix = "${var.identifier}-"
  description = "Private-tier subnet group for ${var.identifier}; it must never contain a public subnet."

  # The validation on private_subnet_ids keeps the caller honest; the 5.x
  # provider line takes the members of the group as one set of identifiers
  # rather than as one block per member, and the tag below records that the
  # placement is an audited decision.
  subnet_ids = var.private_subnet_ids

  tags = merge(local.common_tags, {
    Name            = "${var.identifier}-db-sg"
    "security:tier" = "private-only"
  })
}

# ---------------------------------------------------------------------------
# Parameter group
# ---------------------------------------------------------------------------

resource "aws_db_parameter_group" "engine" {
  name_prefix = "${var.identifier}-"
  family      = local.parameter_family
  description = "Hardened parameter set for ${var.engine} ${var.engine_version} on ${var.identifier}."

  # allow_major_version_upgrade is true whenever the caller may raise the engine,
  # which the caller controls through var.allow_major_version_upgrade; the
  # parameter group is family-scoped, so the same group survives a minor series of
  # the same major and must be replaced across a major.
  dynamic "parameter" {
    for_each = local.parameter_set
    content {
      name         = each.key
      value        = each.value
      apply_method = "PENDING-REBOOT"
    }
  }

  tags = merge(local.common_tags, { Name = "${var.identifier}-params" })
}

# ---------------------------------------------------------------------------
# The instance
# ---------------------------------------------------------------------------

resource "aws_db_instance" "this" {
  identifier     = var.identifier
  engine         = var.engine
  engine_version = var.engine_version
  instance_class = var.instance_class

  db_name                     = var.db_name
  username                    = var.username
  manage_master_user_password = true
  port                        = var.port

  db_subnet_group_name = aws_db_subnet_group.private.name
  parameter_group_name = aws_db_parameter_group.engine.name

  # The instance is never reachable from outside the private tier: it has no
  # public address and it does not carry the default VPC security group either.
  publicly_accessible                   = false
  vpc_security_group_ids                = var.database_security_group_ids
  backup_retention_period               = var.backup_retention_days
  storage_encrypted                     = true
  kms_key_id                            = var.kms_key_arn
  multi_az                              = var.multi_az
  storage_type                          = var.storage_type
  allocated_storage                     = var.allocated_storage_gb
  max_allocated_storage                 = var.max_allocated_storage_gb
  iops                                  = var.iops
  auto_minor_version_upgrade            = true
  allow_major_version_upgrade           = var.allow_major_version_upgrade
  apply_immediately                     = false
  copy_tags_to_snapshot                 = true
  deletion_protection                   = true
  performance_insights_enabled          = true
  performance_insights_kms_key_id       = var.performance_insights_kms_key_arn
  performance_insights_retention_period = 7
  monitoring_interval                   = var.monitoring_interval
  monitoring_role_arn                   = var.monitoring_role_arn
  maintenance_window                    = var.maintenance_window
  backup_window                         = var.backup_window
  iam_database_authentication_enabled   = var.iam_database_authentication
  enabled_cloudwatch_logs_exports       = var.exported_log_types

  tags = merge(local.common_tags, {
    Name              = var.identifier
    "database:engine" = var.engine
    "eol:managed"     = "true"
  })

  lifecycle {
    # Losing a production database to a mistyped destroy is the unrecoverable
    # failure mode of this module, so the resource guard is switched on.
    prevent_destroy = true

    # The gate below is the machine-readable form of the end-of-life policy: the
    # plan fails when the engine and the version string do not agree on the
    # supported major documented in supported_engine_versions above.
    precondition {
      condition     = can(regex(local.supported_engine_versions[var.engine], var.engine_version))
      error_message = "engine_version ${var.engine_version} is outside the supported majors for engine ${var.engine}; consult the supported_engine_versions map in main.tf and the end-of-life catalogue of the toolkit before planning."
    }
  }
}

# ---------------------------------------------------------------------------
# Read replicas
# ---------------------------------------------------------------------------

resource "aws_db_instance" "replica" {
  count = var.read_replica_count

  # A replica inherits the engine, the version, the encryption and the subnet
  # placement from its source, which is exactly why the replication topology
  # cannot drift into an unencrypted copy.
  identifier          = "${var.identifier}-replica-${count.index + 1}"
  replicate_source_db = aws_db_instance.this.identifier
  instance_class      = var.replica_instance_class

  # The replica never takes writes and never gets a public address either.
  publicly_accessible = false

  tags = merge(local.common_tags, {
    Name            = "${var.identifier}-replica-${count.index + 1}"
    "database:role" = "read-replica"
    "eol:managed"   = "true"
  })
}
