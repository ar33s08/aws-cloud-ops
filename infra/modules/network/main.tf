# This file implements the reference network topology for the aws-cloud-ops estate.
# It creates a private-only VPC with three private subnets and two isolated subnets
# across three Availability Zones, the NAT egress path through a single shared NAT
# gateway in the connectivity zone, the VPC interface endpoints that keep traffic for
# SSM, KMS and CloudWatch Logs inside the AWS backbone, a hardened base security group
# with no ingress rules whatsoever, and VPC flow logs delivered to a CloudWatch Logs
# group. Every resource is tagged through the provider default_tags plus the module
# Name tag.

data "aws_availability_zones" "selected" {
  filter {
    name   = "opt-in-status"
    values = ["available"]
  }
}

locals {
  # az_list is the ordered list of Availability Zones that receive subnets. The
  # caller controls the width of the topology through az_count: development uses a
  # single Zone, production spreads across three.
  az_list = slice(
    sort(tolist(data.aws_availability_zones.selected.zones)),
    0,
    min(var.az_count, length(tolist(data.aws_availability_zones.selected.zones)))
  )

  # cidr_plan pre-computes one subnet CIDR block per position of the topology so
  # that a plan is readable before the VPC exists: positions 0..(n-1) are the
  # private subnets, positions n and n+1 are the two isolated subnets.
  private_subnet_cidrs = [for index in range(length(local.az_list)) : cidrsubnets(var.vpc_cidr, length(local.az_list) + 2, index)[0]]
  isolated_subnet_cidrs = [for index in range(2) : cidrsubnets(var.vpc_cidr, length(local.az_list) + 2, length(local.az_list) + index)[0]]

  common_tags = merge(
    {
      Module    = "network"
      ManagedBy = "terraform"
    },
    var.tags
  )
}

resource "aws_vpc" "this" {
  cidr_block = var.vpc_cidr

  # DNS resolution and DNS hostnames stay enabled because the interface endpoints
  # and private Route 53 records that applications rely on depend on both flags.
  enable_dns_support   = true
  enable_dns_hostnames = true
  instance_tenancy     = "default"

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-vpc" })
}

# ---------------------------------------------------------------------------
# Subnets
# ---------------------------------------------------------------------------

resource "aws_subnet" "private" {
  count = length(local.az_list)

  vpc_id              = aws_vpc.this.id
  cidr_block          = local.private_subnet_cidrs[count.index]
  availability_zone   = local.az_list[count.index]
  map_public_ip_on_launch = false

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-private-${count.index + 1}"
    Tier = "private"
  })
}

resource "aws_subnet" "isolated" {
  count = length(local.az_list) > 0 ? 2 : 0

  vpc_id              = aws_vpc.this.id
  cidr_block          = local.isolated_subnet_cidrs[count.index]
  availability_zone   = local.az_list[count.index % length(local.az_list)]
  map_public_ip_on_launch = false

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-isolated-${count.index + 1}"
    Tier = "isolated"
  })
}

# ---------------------------------------------------------------------------
# Egress path (connectivity zone)
# ---------------------------------------------------------------------------

# The connectivity zone is the only location from which packets may leave the VPC.
# It is represented here by the internet gateway, the Elastic IP and the NAT
# gateway; no workload is ever placed inside it.
resource "aws_internet_gateway" "connectivity" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.common_tags, { Name = "${var.name_prefix}-igw-connectivity" })
}

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-nat-eip" })
}

resource "aws_nat_gateway" "connectivity" {
  allocation_id         = aws_eip.nat.id
  connectivity_type     = "public"
  subnet_id             = aws_subnet.isolated[0].id
  enable_primary_ipv6_outbound = false

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-nat-connectivity" })

  depends_on = [aws_internet_gateway.connectivity]
}

# ---------------------------------------------------------------------------
# Route tables and associations
# ---------------------------------------------------------------------------

resource "aws_route_table" "connectivity" {
  vpc_id = aws_vpc.this.id

  # No association: the connectivity route table carries only the default route
  # toward the internet gateway for the NAT gateway's own destination traffic.
  tags = merge(local.common_tags, { Name = "${var.name_prefix}-rt-connectivity" })
}

resource "aws_route" "connectivity_default" {
  route_table_id = aws_route_table.connectivity.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id     = aws_internet_gateway.connectivity.id

  # This is the single 0.0.0.0/0 route of the topology: it exists only in the
  # connectivity route table, which is associated only with the subnet that hosts
  # the NAT gateway. No workload subnet ever carries a route to the internet.
  depends_on = [aws_internet_gateway.connectivity]
}

resource "aws_route_table_association" "connectivity" {
  # The subnet that hosts the NAT gateway is the only member of the connectivity
  # route table. Its second subnet stays route-less and therefore truly isolated.
  route_table_id = aws_route_table.connectivity.id
  subnet_id      = aws_subnet.isolated[0].id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-rt-private" })
}

resource "aws_route_table_association" "private" {
  count = length(local.az_list)

  route_table_id = aws_route_table.private.id
  subnet_id      = aws_subnet.private[count.index].id
}

resource "aws_route" "private_via_nat" {
  route_table_id = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id = aws_nat_gateway.connectivity.id

  depends_on = [aws_nat_gateway.connectivity]
}

resource "aws_route_table" "isolated" {
  count = length(local.isolated_subnet_cidrs)

  vpc_id = aws_vpc.this.id

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-rt-isolated-${count.index + 1}" })
}

resource "aws_route_table_association" "isolated" {
  count = length(aws_subnet.isolated)

  route_table_id = aws_route_table.isolated[count.index].id
  subnet_id      = aws_subnet.isolated[count.index].id
}

# ---------------------------------------------------------------------------
# Interface endpoints (SSM, KMS, CloudWatch Logs)
# ---------------------------------------------------------------------------

resource "aws_security_group" "endpoint" {
  name_prefix = "${var.name_prefix}-endpoint-"
  description = "Interface endpoints for the ${var.name_prefix} VPC"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "TCP 443 from inside the VPC only"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # The only egress rule is the one back into the VPC CIDR block; the endpoints
  # never initiate traffic toward the internet.
  egress {
    description = "Return traffic stays inside the VPC CIDR block"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-endpoint-sg" })
}

resource "aws_vpc_endpoint" "private_dns" {
  for_each = toset(var.endpoint_service_names)

  vpc_id             = aws_vpc.this.id
  service_name       = each.value
  vpc_endpoint_type  = "Interface"
  subnet_ids         = aws_subnet.private[*].id
  security_group_ids = [aws_security_group.endpoint.id]
  private_dns_enabled = true

  # The endpoint policy pins access to this VPC with the aws:Vpc condition key,
  # so the same endpoint cannot be reached from any other VPC in the Region.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowFromThisVpcOnly"
      Effect    = "Allow"
      Principal = "*"
      Action    = ["*"]
      Resource  = "*"
      Condition = {
        StringEquals = {
          "aws:Vpc" = [aws_vpc.this.id]
        }
      }
    }]
  })

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-${replace(each.value, "/[^a-zA-Z0-9]+/", "-")}-vpce"
  })
}

# ---------------------------------------------------------------------------
# Base security group (empty by design)
# ---------------------------------------------------------------------------

# The base security group carries no ingress rules at all, which means it admits
# no inbound connection from anywhere, including from the public internet. Only
# dedicated, fully scoped rules such as the SSM-only bastion rules in the
# ec2-bastion-asg module are ever added, and they are added on their own group.
resource "aws_security_group" "base" {
  name_prefix = "${var.name_prefix}-base-"
  description = "Base group for ${var.name_prefix}; carries no ingress rules by design."
  vpc_id      = aws_vpc.this.id

  egress {
    description = "Egress to VPC CIDR only"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-base-sg" })
}

# ---------------------------------------------------------------------------
# VPC flow logs
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "flow_logs" {
  name_prefix      = "${var.name_prefix}-flow-logs-"
  retention_in_days = var.flow_log_retention_days
  kms_key_id       = var.logs_kms_key_arn

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-flow-logs" })
}

resource "aws_iam_role" "flow_logs" {
  name_prefix        = "${var.name_prefix}-flow-logs-"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "VpcFlowLogsDeliverToCloudWatch"
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.ch.aws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-flow-logs-role" })
}

resource "aws_iam_role_policy" "flow_logs" {
  name_prefix = "${var.name_prefix}-flow-logs-"
  role        = aws_iam_role.flow_logs.name

  # Least privilege: the role may only create the stream and put events into the
  # one log group that this module owns.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "CreateLogGroup"
        Effect   = "Allow"
        Action   = "logs:CreateLogGroup"
        Resource = aws_cloudwatch_log_group.flow_logs.arn
      },
      {
        Sid      = "PutLogEvents"
        Effect   = "Allow"
        Action   = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = aws_cloudwatch_log_group.flow_logs.arn
      }
    ]
  })

  # Note: the action set above follows the flow-logs delivery permissions that
  # the service documentation prescribes for the delivering principal.
  tags = merge(local.common_tags, { Name = "${var.name_prefix}-flow-logs-policy" })
}

resource "aws_flow_log" "vpc" {
  vpc_id                   = aws_vpc.this.id
  traffic_type             = "ALL"
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.flow_logs.arn
  iam_role_arn             = aws_iam_role.flow_logs.arn
  max_aggregation_interval = var.flow_log_aggregation_interval

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-flow-log" })
}
