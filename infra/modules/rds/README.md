# rds

Version 1.0.0 — the managed database tier of the estate with end-of-life gates.

## What it creates

- An `aws_db_subnet_group` built exclusively from the private subnets that the
  caller passes in. The variable validation refuses a list of fewer than two
  subnets and refuses anything that is not shaped like a subnet id, so the
  database can not be placed into a public tier by accident.
- An engine-aware `aws_db_parameter_group` whose family is derived from the engine
  and the major of the version: `mysql-8.0` for MySQL, `postgres-MAJOR` for
  PostgreSQL, `mariadb-10.6` for MariaDB, `aurora-mysql-8.0` for the
  Aurora MySQL-compatible engine and `aurora-postgresql-MAJOR` for the
  Aurora PostgreSQL-compatible engine.
- An `aws_db_instance` with storage encrypted by the platform KMS CMK, a separate
  CMK for Performance Insights, `publicly_accessible = false`, deletion protection,
  automatic minor upgrades, a reviewed maintenance window and a backup window, and
  cloudwatch log exports for the audit, error, general and slowquery trails.
- Read replicas counted by `read_replica_count`; each of them inherits the engine,
  the version, the encryption and the placement from its source, so the replication
  topology cannot drift into an unencrypted copy.
- The master password is **never** a Terraform variable. The module sets
  `manage_master_user_password = true`, so the value lives only in a Secrets
  Manager secret that the platform key encrypts, and only the ARN of the secret
  leaves the module.

## End-of-life gates

Two gates cooperate, and both are enforced at plan time:

1. The `engine_version` variable validates the shape of the version string, and
   its description documents the per-engine constraint (MySQL must be an 8 series
   of the form `MAJOR.MINOR.PATCH`, PostgreSQL must be major 11 or newer, and so
   on).
2. A `lifecycle.precondition` on the instance requires the version to match the
   pattern of the selected engine in the `supported_engine_versions` map in
   `main.tf`, so an 8 series string on the PostgreSQL engine, or any end-of-life
   major, fails the plan with an explicit message instead of applying a forgotten
   database.

## Usage

```hcl
module "orders_db" {
  source = "../../modules/rds"

  identifier         = "acco-dev-orders"
  engine             = "mysql"
  engine_version     = "8.0.35"
  instance_class     = "db.t4g.medium"
  replica_instance_class = "db.t4g.medium"
  username           = "ordersapp"

  private_subnet_ids        = module.network.private_subnet_ids
  database_security_group_ids = [aws_security_group.app_tier.id]

  kms_key_arn                        = module.iam.platform_key_arns["rds"]
  performance_insights_kms_key_arn   = module.iam.platform_key_arns["pi"]

  multi_az              = false
  backup_retention_days = 14
  maintenance_window    = "03:00-04:00"
  backup_window         = "17:00-18:00"
  read_replica_count    = 0

  parameter_overrides = {
    long_query_time = "1"
  }
}
```

## Inputs and outputs

Every input is described, typed and validated in `variables.tf`; every exported
identifier is documented in `outputs.tf`.

## Notes and limitations

- This is example configuration published in a portfolio repository; it is not
  deployed at any customer site and it carries no warranty.
- The default set of the engine parameters is intentionally short and reviewed:
  parameters that would weaken transport or leave a publicly reachable database
  are rejected by the validation of `parameter_overrides`.
- A major upgrade changes the family of the parameter group, which forces a
  replacement of the group. The runbook pairs the change with an explicit
  `allow_major_version_upgrade = true` and a blue/green instance first.
- `replica_addresses` exposes one address per replica on purpose: a single-node
  replica set has no round-robin reader endpoint, and pretending otherwise in the
  interface would be an invention.
