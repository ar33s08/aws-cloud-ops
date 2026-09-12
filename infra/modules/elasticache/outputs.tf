# This file exposes the endpoints and the operational identifiers of the cache
# layer so that consumers can wire the application tier, the alarms and the patch
# program without reading main.tf. No value of cryptographic material is exported;
# the authentication token, if the group ever carries one, is deliberately absent.

output "replication_group_id" {
  description = "The id of the replication group, which the runbooks and the event subscriptions address."
  value       = aws_elasticache_replication_group.this.replication_group_id
}

output "primary_endpoint" {
  description = "The DNS name of the write endpoint of the group. It resolves inside the private namespace of the VPC and serves only the TLS port."
  value       = aws_elasticache_replication_group.this.primary_endpoint_address
}

output "reader_endpoint" {
  description = "The DNS name of the read endpoint of the group. It is the endpoint that the application tier fans its read traffic across."
  value       = aws_elasticache_replication_group.this.reader_endpoint_address
}

output "configuration_endpoint" {
  description = "The configuration endpoint that a cluster-aware client bootstraps from in the cluster mode of the engine; it is null for a single-shard group."
  value       = aws_elasticache_replication_group.this.configuration_endpoint_address
}

output "port" {
  description = "The TLS port that the nodes of the group answer on; the peer security group rules need it."
  value       = aws_elasticache_replication_group.this.port
}

output "parameter_group_name" {
  description = "The name of the parameter group of the group, which the engine upgrade runbook consults when a new family is needed."
  value       = aws_elasticache_parameter_group.engine.name
}

output "member_clusters" {
  description = "The member cache clusters of the group, which the toolkit of the repository scans for the engine inventory of the estate."
  value       = aws_elasticache_replication_group.this.member_clusters
}
