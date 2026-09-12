# This file exposes the identifiers that the consumers of the network module need
# in order to place their own resources inside the topology. Each output is
# documented so that callers can read the contract without opening main.tf.

output "vpc_id" {
  description = "The id of the VPC that this module created."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "The IPv4 CIDR block of the VPC, useful for peer security group rules."
  value       = aws_vpc.this.cidr_block
}

output "private_subnet_ids" {
  description = "The ids of the private subnets, ordered by Availability Zone position. Database and application tiers must be placed in these subnets only."
  value       = aws_subnet.private[*].id
}

output "isolated_subnet_ids" {
  description = "The ids of the two isolated subnets. They host no workloads; they exist so that the NAT gateway has a placement and so that future inspection appliances can be parked without a route to the internet."
  value       = aws_subnet.isolated[*].id
}

output "availability_zones" {
  description = "The ordered list of Availability Zones that the module actually selected for the topology."
  value       = local.az_list
}

output "private_route_table_id" {
  description = "The id of the route table that carries the default route through the NAT gateway and is associated with every private subnet."
  value       = aws_route_table.private.id
}

output "base_security_group_id" {
  description = "The id of the hardened base security group, which carries no ingress rules at all. Consumers attach it and then add only fully scoped rules on their own group."
  value       = aws_security_group.base.id
}

output "flow_log_group_name" {
  description = "The name of the CloudWatch Logs group that receives the VPC flow logs."
  value       = aws_cloudwatch_log_group.flow_logs.name
}

output "nat_gateway_ip" {
  description = "The public Elastic IP address of the NAT gateway, for egress allowlists that a peer might operate on."
  value       = aws_eip.nat.public_ip
}
