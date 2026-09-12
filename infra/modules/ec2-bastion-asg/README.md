# ec2-bastion-asg

Version 1.0.0 — the SSM-only operator entry fleet of the estate.

## What it creates

- A launch template whose image is resolved either from a caller-supplied baked
  AMI id or from the public Parameter Store alias for the newest Amazon Linux 2023
  x86_64 hardware virtual machine image of the Region.
- IMDSv2 enforced through `http_tokens = "required"` and the endpoint limited, so
  version one metadata calls are refused and token-forging of the credential path
  is closed.
- An encrypted root volume on `gp3` hardware, encrypted with the account-owned KMS
  CMK that the caller passes in.
- A Systems Manager instance role plus an instance profile, trusted only by the
  EC2 service of this very account through an `aws:SourceAccount` condition.
- An auto scaling group with a health-check grace period, a warm-up window, and an
  instance refresh that drives every host onto the newest template version at
  ninety percent minimum health.
- A security group with **no ingress rule at all** and no SSH key pair: there is no
  TCP port 22 anywhere in this design, and the bootstrap script disables the SSH
  daemon at first boot.
- Optionally, an association of the fleet with Application Load Balancer target
  groups through `attach_to_alb` and `target_group_arns`. The auto scaling
  attachment accepts ALB target group ARNs only; it is the documented way of
  binding a target group to auto scaling in the AWS provider.
- The user data is the companion script in this repository at
  `scripts/bastion-userdata.sh`. It installs the Systems Manager agent and the
  CloudWatch agent, records the managed-node registration marker, and disables the
  SSH daemon. The module reads it through `file()` relative to the module root so
  that the script stays lintable with shellcheck on its own.

## Usage

```hcl
module "bastion" {
  source = "../../modules/ec2-bastion-asg"

  name_prefix          = "acco-dev"
  vpc_id               = module.network.vpc_id
  vpc_cidr             = module.network.vpc_cidr
  subnet_ids           = module.network.private_subnet_ids
  availability_zones   = module.network.availability_zones
  root_volume_kms_key_arn = module.iam.platform_key_arns["ebs"]

  min_size               = 1
  max_size               = 2
  desired_capacity       = 1
  health_check_grace_period = 600
}
```

The optional load-balancer registration is used by an inspector appliance variant
of the design:

```hcl
module "session_broker" {
  source = "../../modules/ec2-bastion-asg"

  name_prefix        = "acco-prod-broker"
  vpc_id             = module.network.vpc_id
  vpc_cidr           = module.network.vpc_cidr
  subnet_ids         = module.network.private_subnet_ids
  availability_zones = module.network.availability_zones
  root_volume_kms_key_arn = module.iam.platform_key_arns["ebs"]

  attach_to_alb       = true
  target_group_arns   = [aws_lb_target_group.broker.arn]
}
```

## Inputs and outputs

Every input is described, typed and validated in `variables.tf`; every exported
identifier is documented in `outputs.tf`.

## Notes and limitations

- This is example configuration published in a portfolio repository; it is not
  deployed at any customer site and it carries no warranty.
- Session Manager requires that the three interface endpoints for `ssm`,
  `ssmmessages` and `ec2messages` exist in the VPC; the network module creates
  them, and a private subnet without them yields hosts that never register.
- The Parameter Store alias for Amazon Linux 2023 is Region-public but not every
  Region publishes every alias variant; pass `bastion_ami_id` when the fleet must
  be pinned to a tested image.
- The instance refresh of the provider pins a rolling strategy and a
  `preferences` container; this module keeps ninety percent of the fleet healthy
  through the rotation with a checkpoint delay of five minutes, and it
  deliberately does not use the mixed-instance policy, because the fleet is
  homogeneous by design.
