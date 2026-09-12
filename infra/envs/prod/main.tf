# This file composes the six modules of the platform into the production
# environment of the estate: the hardening layer first, because every other module
# resolves the platform keys through its outputs; then the network that spans the
# three Availability Zones of the Region, the SSM-only bastion fleet that carries
# the floor capacity of the estate, the database tier with its two read replicas
# and the multi-Zone standby, the cache tier with its failover replica, and the
# monitoring spine whose alarms watch the three operational tiers with the
# thresholds of the platform.
#
# The profile of the environment is the reviewed production shape: a three-Zone
# topology, the memory-optimised classes of compute, the multi-Availability-Zone
# database, and the retention policy of the audit. The reviewed values are the
# defaults of variables.tf, so that an override of the environment is a written line
# of the profile and not a hand-edit of a module. No value in this file is
# reviewed here alone: each is the reviewed value of the platform, and a change of
# it passes the same pull request and the same plan that a change of the modules
# passes.

module "iam" {
  source = "../../modules/iam"

  environment_name     = var.name_prefix
  key_admin_role_arns  = var.key_admin_role_arns
  break_glass_role_arn = var.break_glass_role_arn

  # The password policy of the estate lives with the hardening layer, because the
  # same control that governs a human console session governs the floor that the
  # audit of the account expects; the review of the platform sets it at fourteen,
  # which is the value of the reviewed profile of the estate.
  manage_password_policy  = true
  password_minimum_length = 14

  # The destruction window of the keys is the longest the service offers: a key
  # that can be recovered is a key whose recovery is possible at all, and the
  # recovery of the estate depends on it.
  kms_deletion_window_days = 30
}

module "network" {
  source = "../../modules/network"

  name_prefix = var.name_prefix
  vpc_cidr    = var.vpc_cidr
  az_count    = var.az_count

  # The production estate keeps the longer of the two retention policies of the
  # platform on the flow logs, which are the trail the investigation of an incident
  # reads of the network; the aggregate interval stays at the floor of the service
  # so that the first minute of an event of the flow is of the log and not of the
  # gap of the window.
  flow_log_retention_days       = 90
  flow_log_aggregation_interval = 60
  logs_kms_key_arn              = module.iam.platform_key_arns["logs"]

  # The interface endpoints of the plane of the platform keep the traffic of the
  # keys, the logs, and the Systems Manager of the private network; the list is the
  # reviewed list of the platform and a service without an endpoint on purpose
  # leaves the reason for its absence in the record of the pull request.
  endpoint_service_names = [
    "kms", "logs", "ssmmessages", "ssminvocation", "ec2messages", "monitoring",
  ]
}

module "bastion" {
  source = "../../modules/ec2-bastion-asg"

  name_prefix        = var.name_prefix
  vpc_id             = module.network.vpc_id
  vpc_cidr           = module.network.vpc_cidr
  subnet_ids         = module.network.private_subnet_ids
  availability_zones = module.network.availability_zones

  bastion_instance_type = var.bastion_instance_type

  # The fleet of the entry carries the floor capacity of the estate: two nodes
  # so that the loss of the node of the session is the loss of a session and not
  # the loss of the path of the estate, and three at the ceiling of the refresh of
  # the fleet, which is the window that an instance refresh of the fleet opens.
  min_size                  = var.bastion_capacity_floor
  max_size                  = var.bastion_capacity_ceiling
  desired_capacity          = var.bastion_capacity_floor
  health_check_grace_period = 900
  warmup_seconds            = 300

  # The image of the fleet is the alias of the current release of the Amazon
  # Linux image of the Region, resolved through the public parameter store at the
  # plan; the explicit id of an image is an input of the promotion and not a value
  # of this file, because the pinning of an old image is how a fleet of the estate
  # quietly falls out of the window of the support.
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
  db_name                = "orders"

  private_subnet_ids          = module.network.private_subnet_ids
  database_security_group_ids = [module.network.base_security_group_id]

  kms_key_arn                      = module.iam.platform_key_arns["rds"]
  performance_insights_kms_key_arn = module.iam.platform_key_arns["pi"]

  # The two properties of the availability of the production database: the standby
  # of the second Availability Zone, and the read replicas of the readers of the
  # same engine. Both are inputs of the profile of the environment, and the gate of
  # the module refuses the combination that the review of the platform rejects.
  multi_az           = var.database_multi_az
  read_replica_count = var.read_replica_count

  # The retention of the backup of the production estate is thirty-five days, the
  # longest the service keeps an automatic backup: an incident discovered on the
  # third week of the quarter is still an incident with a point of recovery.
  backup_retention_days    = 35
  allocated_storage_gb     = 200
  max_allocated_storage_gb = 1000
  storage_type             = "gp3"

  # The windows of the production estate are the windows of the platform: the
  # window of the maintenance of the database is the window that the change-freeze
  # policy of the estate and the schedule of the patch ring both honour, and the
  # window of the backup sits of it so that a night of the restore does not compete
  # with a night of the patch.
  maintenance_window = "sun:06:00-sun:07:00"
  backup_window      = "12:00-13:00"

  # A major of the engine is never applied in place by the plan of the estate: the
  # promotion path of a major is the blue/green deployment of the runbook, with the
  # guard of the lag of the replication and the snapshot of the blue. The gate of
  # the module keeps the claim in code and not in the prose of this file.
  allow_major_version_upgrade = false

  exported_log_types = ["audit", "error", "general", "slowquery"]
}

module "orders_cache" {
  source = "../../modules/elasticache"

  replication_group_id = "${var.name_prefix}-orders-cache"
  engine               = "redis"
  engine_version       = var.cache_engine_version

  # The family of the parameter group rides with the engine of the environment; the
  # reviewed cache of the production profile is of the seven series of the engine,
  # which is what the gate of the module accepts, and the series of the cache that
  # the catalog of the end of the life still shows inside its window of support.
  parameter_group_family = "redis-7.1"
  node_type              = var.cache_node_type

  # The cluster mode of the engine is closed on the estate: the working set of the
  # tier fits a shard of the reviewed class, and a resharding is an operational
  # event that the estate does not need in order to serve a get. The replica count
  # is the floor of one and the multi-Zone placement of the failover together,
  # which is the posture that the test of the failover of the toolkit measures.
  cluster_mode_enabled = false
  num_cache_shards     = 1
  num_cache_replicas   = 1
  multi_az             = var.database_multi_az

  private_subnet_ids       = module.network.private_subnet_ids
  cache_security_group_ids = [module.network.base_security_group_id]
  kms_key_arn              = module.iam.platform_key_arns["elasticache"]

  # In-transit encryption is enforced for the clients that can speak the transport
  # security layer: the cache of the estate is inside the boundary of the
  # classification of the network, and a control that is free and that removes a
  # class of the plaintext is taken.
  transit_encryption_mode = "required"

  snapshot_retention_days = 35
  snapshot_window         = "03:00-04:00"
  maintenance_window      = "sun:07:00-sun:08:00"
}

module "observability" {
  source = "../../modules/observability"

  environment_name = var.name_prefix

  logs_kms_key_arn  = module.iam.platform_key_arns["logs"]
  alarm_kms_key_arn = module.iam.platform_key_arns["sns_alarms"]

  monitored_asg_name         = module.bastion.bastion_autoscaling_group_name
  monitored_db_identifier    = module.orders_db.db_instance_id
  monitored_cache_cluster_id = module.orders_cache.replication_group_id

  # All three tiers are watched by the production environment: a spine that is
  # silent about the tier it was pointed away from is worse than no spine at all,
  # because it is read as health.
  monitor_compute  = true
  monitor_database = true
  monitor_cache    = true

  # The grace period of the patch of the production estate is the seven days of the
  # ring of the canary: the window that the patch of the canary ring is given before
  # a non-compliance of the ring of the standard is an alarm, and the window that
  # the operator has to act on the report of the toolkit.
  patch_grace_period_days = 7

  enable_datadog        = var.enable_datadog
  dashboard_json_path   = "${path.module}/../../../monitoring/datadog-dashboard.json"
  datadog_pager_channel = var.datadog_pager_channel

  # The subscription of the alarm is an input of the environment and not a default:
  # an alarm that pages a mailbox that the review has not seen is an alarm that no
  # one carries, and the topic of the alarm of the module exists so that the
  # subscription of the estate is a written line of the profile of the environment.
  notification_subscriptions = var.notification_subscriptions
}
