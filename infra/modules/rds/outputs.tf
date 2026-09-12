# This file exposes the endpoints and the operational identifiers of the database
# layer. Nothing in here carries a credential: the master password never passes
# through Terraform at all, because the module delegates its management to the
# managed master user password facility and only the Secrets Manager reference is
# exported.

output "db_instance_arn" {
  description = "The ARN of the primary database instance, for resource-level permission policies and for the audit queries of the toolkit."
  value       = aws_db_instance.this.arn
}

output "db_instance_id" {
  description = "The resource id of the instance, which is the handle that the performance insights and the event subscriptions address."
  value       = aws_db_instance.this.id
}

output "endpoint" {
  description = "The DNS name that the application tier resolves to reach the primary instance. It lives inside the private namespace of the VPC."
  value       = aws_db_instance.this.endpoint
}

output "port" {
  description = "The port on which the engine answers, which the peer security group rules need."
  value       = aws_db_instance.this.port
}

output "replica_addresses" {
  description = "The DNS addresses of the read replicas, in the order in which they were created. Each replica is addressed individually; there is no round-robin reader endpoint over a replica set of a single instance, so the application tier chooses a replica itself or pins the primary explicitly."
  value       = aws_db_instance.replica[*].address
}

output "master_secret_arn" {
  description = "The ARN of the Secrets Manager secret that holds the master password. The secret itself is deliberately not exported, because its value must never appear in state output."
  value       = aws_db_instance.this.master_user_secret[0].arn
}

output "parameter_group_name" {
  description = "The name of the engine parameter group, which the upgrade runbook consults when a major version needs a new family."
  value       = aws_db_parameter_group.engine.name
}

output "subnet_group_name" {
  description = "The name of the private-tier subnet group of the database."
  value       = aws_db_subnet_group.private.name
}
