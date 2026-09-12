# This file composes the six modules of the platform into the development
# environment of the estate: the hardening layer first, because every other module
# resolves the platform keys through its outputs; then the network, the SSM-only
# bastion fleet, the database tier, the cache tier, and the monitoring spine, whose
# alarms watch the three operational tiers. The profile of the environment is the
# reviewed small shape of the platform: a single Availability Zone, the burstable
# classes of compute, one node per tier, and the single-Zone database.

module "iam" {
  source = "../../modules/iam"

  environment_name     = var.name_prefix
  key_admin_role_arns  = var.key_admin_role_arns
  break_glass_role_arn = var.break_glass_role_arn
}

module "network" {
  source = "../../modules/network"

  name_prefix = var.name_prefix
  vpc_cidr    = var.vpc_cidr
  az_count    = var.az_count

  # The development slice keeps the shorter of the two retention policies of the
  # platform; the audit retention of the flow logs stays at the floor of the
  # compliance window of the estate.
  flow_log_retention_days       = 30
  flow_log_aggregation_interval = 60
  logs_kms_key_arn              = module.iam.platform_key_arns["logs"]
}

module "bastion" {
  source = "../../modules/ec2-bastion-asg"

  name_prefix        = var.name_prefix
  vpc_id             = module.network.vpc_id
  vpc_cidr           = module.network.vpc_cidr
  subnet_ids         = module.network.private_subnet_ids
  availability_zones = module.network.availability_zones

  bastion_instance_type = var.bastion_instance_type

  # The development fleet is a single reviewed capacity of one: the bootstrap of
  # the Systems Manager registration is the reason a second node is not cheaper
  # than the first one of a sandbox.
  min_size                  = 1
  max_size                  = 1
  desired_capacity          = 1
  health_check_grace_period = 600
  warmup_seconds            = 300

  root_volume_kms_key_arn = module.iam.platform_key_arns["ebs"]
}

module "orders_db" {
  source = "../../modules/rds"

  identifier     = "${var.name_prefix}-orders"
  engine         = "mysql"
  engine_version = var.database_engine_version

  instance_class         = var.database_instance_class
  replica_instance_class = var.database_instance_class
  username               = "ordersapp"

  private_subnet_ids          = module.network.private_subnet_ids
  database_security_group_ids = [module.network.base_security_group_id]

  kms_key_arn                      = module.iam.platform_key_arns["rds"]
  performance_insights_kms_key_arn = module.iam.platform_key_arns["pi"]

  multi_az              = var.database_multi_az
  backup_retention_days = 7
  allocated_storage_gb  = 20

  # The windows of the sandbox sit of the window of the production estate, so
  # that a patch run of the laboratory never contends with the patch window of
  # the platform.
  maintenance_window = "04:00-05:00"
  backup_window      = "18:00-19:00"

  read_replica_count = 0

  allow_major_version_upgrade = false
}

module "orders_cache" {
  source = "../../modules/elasticache"

  replication_group_id = "${var.name_prefix}-orders-cache"
  engine               = "redis"
  engine_version       = var.cache_engine_version

  # The family of the parameter group rides with the engine of the environment:
  # the reviewed cache of the development profile is of the seven series of the
  # engine, which is what the gate of the module accepts.
  parameter_group_family = "redis-7.1"
  node_type              = var.cache_node_type

  cluster_mode_enabled = false
  num_cache_shards     = 1
  # The validation of the module refuses zero here on purpose: even a sandbox has
  # to run the failover path of the service, because a guard that no one tests is
  # a guard that no one may trust.
  num_cache_replicas = 1
  multi_az           = var.database_multi_az

  private_subnet_ids       = module.network.private_subnet_ids
  cache_security_group_ids = [module.network.base_security_group_id]
  kms_key_arn              = module.iam.platform_key_arns["elasticache"]

  snapshot_retention_days = 7
  maintenance_window      = "sun:04:00-sun:05:00"
}

module "observability" {
  source = "../../modules/observability"

  environment_name = var.name_prefix

  logs_kms_key_arn  = module.iam.platform_key_arns["logs"]
  alarm_kms_key_arn = module.iam.platform_key_arns["sns_alarms"]

  monitored_asg_name         = module.bastion.bastion_autoscaling_group_name
  monitored_db_identifier    = module.orders_db.db_instance_id
  monitored_cache_cluster_id = module.orders_cache.replication_group_id

  # The thresholds of the sandbox are the thresholds of the platform: an alarm of
  # the development environment that is tuned softer than the one of the
  # production environment teaches the on-call nothing about the real estate.
  monitor_compute  = true
  monitor_database = true
  monitor_cache    = true

  patch_grace_period_days = 1

  enable_datadog        = var.enable_datadog
  dashboard_json_path   = "${path.module}/../../../monitoring/datadog-dashboard.json"
  datadog_pager_channel = "oncall-platform-sandbox"

  notification_subscriptions = []
}
