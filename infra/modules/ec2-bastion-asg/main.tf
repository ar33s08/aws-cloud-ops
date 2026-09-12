# This file implements the SSM-only bastion layer of the estate: a launch template
# whose image comes from the public Parameter Store alias for Amazon Linux 2023, a
# Systems Manager instance role with its instance profile, an auto scaling group
# with instance refresh enabled, and a bastion security group that deliberately
# carries no ingress rule at all because operator access is exclusively through
# Session Manager and the daemon itself is disabled by the bootstrap script.
#
# The module also exposes an optional attach-to-ALB switch. When it is enabled the
# Application Load Balancer target group ARNs that the caller supplies are
# registered on the auto scaling group through an auto scaling attachment, which is
# the supported way of associating an ALB target group with auto scaling in the
# AWS provider.

data "aws_caller_identity" "current" {}

data "aws_ssm_parameter" "amazon_linux_2023_ami" {
  name = var.ami_ssm_parameter_name
}

locals {
  # bastion_ami_id resolves the AMI that the launch template boots. A caller who
  # has baked a hardened image passes bastion_ami_id directly and the Parameter
  # Store lookup stays unused, which keeps gold images reproducible without
  # depending on the Region alias catalogue.
  bastion_ami_id = coalesce([var.bastion_ami_id, nonsensitive(data.aws_ssm_parameter.amazon_linux_2023_ami.value)])

  # user_data_payload is the companion bootstrap script that installs the Systems
  # Manager agent and removes SSH as an access path. The path is resolved relative
  # to this module so that the script stays lintable on its own with shellcheck.
  user_data_payload = file("${path.module}/../../scripts/bastion-userdata.sh")

  common_tags = merge(
    {
      Module    = "ec2-bastion-asg"
      ManagedBy = "terraform"
    },
    var.tags
  )
}

# ---------------------------------------------------------------------------
# Systems Manager identity
# ---------------------------------------------------------------------------

resource "aws_iam_role" "ssm_instance" {
  name_prefix        = "${var.name_prefix}-bastion-ssm-"
  description        = "Instance role for the SSM-only bastion fleet of ${var.name_prefix}."
  max_session_duration = 3600

  # The trust policy binds the delegation to the EC2 service of this very account,
  # so a principal from another account cannot hand this role to a service.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "Ec2ServiceOfThisAccountMayDelegate"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = [data.aws_caller_identity.current.account_id]
        }
      }
    }]
  })

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-bastion-ssm-role" })
}

resource "aws_iam_instance_profile" "bastion" {
  name_prefix = "${var.name_prefix}-bastion-"
  role        = aws_iam_role.ssm_instance.name

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-bastion-profile" })
}

# ---------------------------------------------------------------------------
# Security group (no SSH anywhere)
# ---------------------------------------------------------------------------

resource "aws_security_group" "bastion" {
  name_prefix = "${var.name_prefix}-bastion-"
  description = "SSM-only bastion group for ${var.name_prefix}; it carries no ingress rule at all."
  vpc_id      = var.vpc_id

  egress {
    description = "The agent reaches the SSM endpoints inside the VPC only"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = merge(local.common_tags, {
    Name            = "${var.name_prefix}-bastion-sg"
    "security:ssh" = "disabled-by-design"
  })
}

# ---------------------------------------------------------------------------
# Launch template
# ---------------------------------------------------------------------------

resource "aws_launch_template" "bastion" {
  name_prefix = "${var.name_prefix}-bastion-"
  description = "SSM-only bastion of ${var.name_prefix}: IMDSv2 enforced, root volume encrypted with the platform CMK."

  image_id      = local.bastion_ami_id
  instance_type = var.bastion_instance_type

  # There is no key_name on purpose: an SSH key pair would be a credential that
  # nobody rotates, and the design does not offer SSH in the first place.
  user_data = base64encode(local.user_data_payload)

  # IMDSv2 in enforced mode: a token is required for every metadata request and
  # the endpoint is limited, so a server-side request forgery through an
  # unauthenticated version one call is not possible.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    http_protocol_ipv6          = "disabled"
  }

  ebs_optimized            = true
  disable_api_termination  = true
  disable_api_stop         = true

  # The root volume is the only device of the fleet and it is encrypted with the
  # customer managed key of the platform, never left unencrypted by default.
  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = var.root_volume_size_gb
      volume_type           = "gp3"
      encrypted             = true
      kms_key_id            = var.root_volume_kms_key_arn
      delete_on_termination = true
    }
  }

  # The hardened group is the only membership of the instances, and the auto
  # scaling group spreads the fleet across the private subnets, so no interface
  # ever receives a public address and a bastion is never internet-facing.
  vpc_security_group_ids = concat(
    [aws_security_group.bastion.id],
    var.additional_security_group_ids
  )

  monitoring {
    # Detailed monitoring costs a little and buys one-minute datapoints, which
    # is what the CPU alarm of the observability module needs to be useful.
    enabled = true
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(local.common_tags, {
      Name        = "${var.name_prefix}-bastion"
      "patch:set" = "group"
    })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(local.common_tags, { Name = "${var.name_prefix}-bastion-root" })
  }

  lifecycle {
    # A new version of the template is created for every change, so a running
    # fleet is only rotated through the explicit instance refresh below.
    create_before_destroy = false
    ignore_changes        = ["latest_version", "default_version"]
  }
}

# ---------------------------------------------------------------------------
# Auto scaling group
# ---------------------------------------------------------------------------

resource "aws_autoscaling_group" "bastion" {
  name_prefix = "${var.name_prefix}-bastion-"

  min_size              = var.min_size
  max_size              = var.max_size
  desired_capacity      = var.desired_capacity
  default_instance_warmup = var.warmup_seconds

  # The health check grace period gives a freshly launched instance enough time
  # to finish its bootstrap before the group declares it unhealthy and replaces
  # it, which is what prevents a registration storm during a scale-out.
  health_check_grace_period = var.health_check_grace_period
  health_check_type         = "EC2"

  # The Availability Zones are derived from the private subnets that the caller
  # passes, so the fleet always spans exactly the Zones of the network module.
  availability_zones = var.availability_zones

  dynamic "tag" {
    for_each = local.common_tags
    content {
      key                 = each.key
      value               = each.value
      propagate_at_launch = true
    }
  }

  launch_template {
    id      = aws_launch_template.bastion.id
    version = aws_launch_template.bastion.latest_version
  }

  # The refresh drives every host onto the newest template version with a
  # rolling strategy. The preferences keep ninety percent of the fleet healthy
  # through the rotation and checkpoint the progress, so a bad image cannot take
  # the whole entry fleet down at once.
  instance_refresh {
    strategy = "Rolling"

    preferences {
      min_healthy_percentage = 90
      checkpoint_delay       = 300
      auto_rollback          = false
    }
  }
}

resource "aws_autoscaling_attachment" "target_group" {
  count = var.attach_to_alb ? length(var.target_group_arns) : 0

  autoscaling_group_name = aws_autoscaling_group.bastion.name
  # Only Application Load Balancer target group ARNs belong here; attaching a
  # classic load balancer name instead would be a use of the wrong container.
  lb_target_group_arn = var.target_group_arns[count.index]
}
