# This file exposes the identifiers that the consumers of the ec2-bastion-asg
# module need: the auto scaling group for scheduled actions and alarm wiring, the
# launch template for golden-image pipelines, and the security group for peer
# rules that must be granted to the bastion fleet specifically.

output "bastion_autoscaling_group_name" {
  description = "The name of the bastion auto scaling group, used for instance refresh calls and for the fleet registration of the CloudWatch agent."
  value       = aws_autoscaling_group.bastion.name
}

output "bastion_autoscaling_group_arn" {
  description = "The ARN of the bastion auto scaling group for resource-level permission policies."
  value       = aws_autoscaling_group.bastion.arn
}

output "launch_template_id" {
  description = "The id of the bastion launch template that a golden-image pipeline points at when it publishes a new image version."
  value       = aws_launch_template.bastion.id
}

output "launch_template_default_version" {
  description = "The default version of the bastion launch template, which is the version that new instances of the fleet boot."
  value       = aws_launch_template.bastion.default_version
}

output "bastion_security_group_id" {
  description = "The id of the bastion security group that carries no ingress rule at all. Peer rules may be added only for explicit, fully scoped flows."
  value       = aws_security_group.bastion.id
}

output "bastion_instance_role_arn" {
  description = "The ARN of the Systems Manager instance role of the fleet, referenced by the patch manager fleet commands and by audit queries."
  value       = aws_iam_role.ssm_instance.arn
}

output "resolved_ami_id" {
  description = "The AMI id that the module actually resolved, either the baked image that the caller supplied or the value of the Parameter Store alias."
  value       = local.bastion_ami_id
}
