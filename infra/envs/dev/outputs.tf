# This file exposes the identifiers of the development environment of the platform
# that the reports and the runbooks of the toolkit read: the handles of the three
# operational tiers, the lookup table of the platform keys, and the address of the
# board of the environment. The outputs are deliberately values that are safe to
# print: the module surface keeps the credential of the database inside the secret
# of the service, and this file exports the ARN of the secret and not its content.

output "vpc_id" {
  description = "The id of the network of the environment, for the drift report of the toolkit."
  value       = module.network.vpc_id
}

output "bastion_fleet_name" {
  description = "The name of the auto scaling group of the entry fleet of the environment, the handle that the session tooling and the patch scans address."
  value       = module.bastion.bastion_autoscaling_group_name
}

output "database_endpoint" {
  description = "The endpoint of the database of the environment, which resolves inside the private namespace of the network of the estate."
  value       = module.orders_db.endpoint
}

output "database_master_secret_arn" {
  description = "The ARN of the secret of the master account of the database; the content of the credential stays in the service of the secrets and is never exported."
  value       = module.orders_db.master_secret_arn
}

output "cache_primary_endpoint" {
  description = "The endpoint of the write path of the cache of the environment, the target of the TLS session of a client of the application tier."
  value       = module.orders_cache.primary_endpoint
}

output "platform_key_arns" {
  description = "The lookup table of the platform keys of the environment, keyed by the scope of the key; a module of the estate that needs a key of the platform addresses it here and not by a hand-typed ARN."
  value       = module.iam.platform_key_arns
}

output "alarm_topic_arn" {
  description = "The ARN of the topic that every metric alarm of the environment publishes into, the single address of the notification path of the estate."
  value       = module.observability.alarm_topic_arn
}

output "patch_group_name" {
  description = "The patch group that the fleet of the environment reports against, which is the handle of the compliance scan of the toolkit."
  value       = module.observability.patch_group_name
}

output "datadog_board_url" {
  description = "The address of the board of the platform of the environment when the DataDog plane is enabled, and null when a reviewer has planned the directory without the credentials of the vendor."
  value       = module.observability.datadog_board_url
}
