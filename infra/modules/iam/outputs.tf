# This file exposes the identifiers of the hardening layer for the consumers of
# the estate: the sibling modules resolve the platform keys by scope through
# platform_key_arns, and the runbooks of the toolkit read the policy ARNs from
# here when they write an audit report.

output "platform_key_arns" {
  description = "The ARN of every platform key, keyed by its scope such as ebs, rds, pi or elasticache. This is the single lookup table through which the rest of the estate addresses the keys of the platform, so that a scope is never spelled by hand twice."
  value       = { for scope, key in aws_kms_key.platform : scope => key.arn }
}

output "platform_key_id_aliases" {
  description = "The alias names of the platform keys, keyed by scope. A consumer that must survive a replacement of a key addresses the alias and not the key id, which is why the map exists next to the ARN map above."
  value       = { for scope, alias in aws_kms_alias.platform : scope => alias.alias_name }
}

output "deny_destructive_policy_arn" {
  description = "The ARN of the customer-managed deny policy that closes the destructive actions of the account for every principal but the break-glass role."
  value       = aws_iam_policy.deny_destructive.arn
}

output "boundary_policy_arn" {
  description = "The ARN of the permissions boundary that every service role of the platform carries."
  value       = aws_iam_policy.boundary.arn
}

output "service_role_arns" {
  description = "The ARNs of the service-bounded roles of the platform, keyed by the workload of the role such as ec2_runtime or lambda_runtime. The instance profile of the bastion module and the monitoring role of the database module resolve through this map."
  value       = { for key, role in aws_iam_role.service : key => role.arn }
}

output "alarm_delivery_role_arn" {
  description = "The ARN of the role that the monitoring services assume to publish their events into the alarm topic of the environment."
  value       = aws_iam_role.alarm_delivery.arn
}

output "ssm_agent_managed_policy_arns" {
  description = "The managed policies of the agent of Systems Manager that the module attaches to the compute role, listed for the drift report of the toolkit, which checks them against the role of the fleet."
  value       = local.ssm_agent_managed_policies
}
