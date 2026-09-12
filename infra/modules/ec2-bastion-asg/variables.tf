# This file declares the input variables of the ec2-bastion-asg module. Each
# variable documents the contract that the caller must honour, and the capacity
# trio is validated so that an impossible auto scaling configuration fails the plan
# instead of failing an apply at two in the morning.

variable "name_prefix" {
  description = "Prefix applied to every name and name-prefix in this module, normally the environment short name such as acco-dev."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}$", var.name_prefix))
    error_message = "name_prefix must start with a lowercase letter and contain only lowercase letters, digits or hyphens (maximum 31 characters)."
  }
}

variable "vpc_id" {
  description = "The id of the VPC that hosts the private subnets of the network module."
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]{8,17}$", var.vpc_id))
    error_message = "vpc_id must look like a VPC id, for example vpc-0123456789abcdef0."
  }
}

variable "vpc_cidr" {
  description = "The IPv4 CIDR block of the VPC, used to scope the HTTPS egress rule of the agent to inside the network."
  type        = string

  validation {
    condition     = can(cidrsubnets(var.vpc_cidr, 8, 0))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block of at most a /24 prefix."
  }
}

variable "subnet_ids" {
  description = "The private subnets that host the bastion fleet. They must come from the private subnet outputs of the network module; public placement would defeat the security posture."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 1 && alltrue([for id in var.subnet_ids : can(regex("^subnet-[0-9a-f]{8,17}$", id))])
    error_message = "subnet_ids must be a non-empty list of subnet ids of the form subnet-0123456789abcdef0."
  }
}

variable "availability_zones" {
  description = "The Availability Zones that the auto scaling group spans. They are exported by the network module so that fleet and subnets always agree."
  type        = list(string)

  validation {
    condition     = length(var.availability_zones) >= 1
    error_message = "availability_zones must contain at least one Availability Zone."
  }
}

variable "bastion_instance_type" {
  description = "The instance class of the bastion fleet. The fleet is tiny and SSM-bound, so a burstable class is the right shape for it."
  type        = string
  default     = "t3.small"
}

variable "bastion_ami_id" {
  description = "Optional AMI id of a baked and hardened bastion image. When it is null the module resolves the Amazon Linux 2023 image through the public Parameter Store alias given by ami_ssm_parameter_name."
  type        = string
  default     = null

  validation {
    condition     = var.bastion_ami_id == null ? true : can(regex("^ami-[0-9a-f]{8,17}$", var.bastion_ami_id))
    error_message = "bastion_ami_id must be null or an AMI id of the form ami-0123456789abcdef0."
  }
}

variable "ami_ssm_parameter_name" {
  description = "The public Parameter Store alias of the Amazon Linux 2023 image that is used when bastion_ami_id is not supplied. The alias returns the newest x86_64 hardware virtual machine image of the Region."
  type        = string
  default     = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-x86_64"

  validation {
    condition     = can(regex("^/aws/service/[a-zA-Z0-9_/.-]+$", var.ami_ssm_parameter_name))
    error_message = "ami_ssm_parameter_name must be an absolute public Parameter Store path below /aws/service/."
  }
}

variable "root_volume_size_gb" {
  description = "Size in gibibytes of the encrypted root volume of every bastion host."
  type        = number
  default     = 24

  validation {
    condition     = var.root_volume_size_gb >= 8 && var.root_volume_size_gb <= 128
    error_message = "root_volume_size_gb must sit between 8 and 128 gibibytes; a bastion is deliberately a small host."
  }
}

variable "root_volume_kms_key_arn" {
  description = "The ARN of the KMS customer managed key that encrypts the root volumes at rest. Leaving it null would fall back to an unencrypted default and is not an acceptable posture."
  type        = string

  validation {
    condition     = can(regex("^arn:[a-z0-9-]+:kms:[a-z0-9-]+-[a-z0-9-]+-[0-9]+:(key/[0-9a-f-]+|alias/[a-zA-Z0-9/_-]+)$", var.root_volume_kms_key_arn))
    error_message = "root_volume_kms_key_arn must be a full KMS key ARN or key alias ARN of the form arn:aws:kms:REGION:ACCOUNT_ID:key/UUID or .../alias/NAME."
  }
}

variable "min_size" {
  description = "Minimum size of the bastion fleet. Development runs one host, production runs at least two."
  type        = number
  default     = 1
}

variable "max_size" {
  description = "Maximum size of the bastion fleet. It is deliberately small: the fleet serves operator sessions, not traffic."
  type        = number
  default     = 2
}

variable "desired_capacity" {
  description = "Desired capacity of the bastion fleet between min_size and max_size."
  type        = number
  default     = 1

  # The cross-variable check below needs Terraform 1.4 or newer; the environments
  # pin 1.5 or newer, so the constraint is always available here.
  validation {
    condition     = var.desired_capacity >= var.min_size && var.desired_capacity <= var.max_size
    error_message = "desired_capacity must sit between min_size and max_size, otherwise the auto scaling group immediately fights its own capacity settings."
  }
}

variable "health_check_grace_period" {
  description = "Seconds that a fresh instance has to finish its bootstrap before the auto scaling group may declare it unhealthy. The agent install plus registration of the bootstrap script is what this window buys."
  type        = number
  default     = 600

  validation {
    condition     = var.health_check_grace_period >= 120 && var.health_check_grace_period <= 3600
    error_message = "health_check_grace_period must sit between 120 and 3600 seconds."
  }
}

variable "warmup_seconds" {
  description = "Seconds that a newly launched instance is considered warming up and is excluded from the capacity accounting of the group."
  type        = number
  default     = 300

  validation {
    condition     = var.warmup_seconds >= 60 && var.warmup_seconds <= 3600
    error_message = "warmup_seconds must sit between 60 and 3600 seconds."
  }
}

variable "additional_security_group_ids" {
  description = "Optional extra security group ids attached to the bastion, for example the endpoint group of the network module. Never add a group that opens an inbound port."
  type        = list(string)
  default     = []
}

variable "attach_to_alb" {
  description = "Whether the fleet is registered with Application Load Balancer target groups. The bastion normally runs headless; the switch exists so that an inspector appliance or a session broker can be placed behind an ALB without forking the module."
  type        = bool
  default     = false
}

variable "target_group_arns" {
  description = "The ARNs of the Application Load Balancer target groups that receive the fleet when attach_to_alb is true. Auto scaling attachment accepts ALB target group ARNs only."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for arn in var.target_group_arns : can(regex("^arn:[a-z0-9-]+:elasticloadbalancing:[a-z0-9-]+-[a-z0-9-]+-[0-9]+:targetgroup/[a-zA-Z0-9-]+/[a-zA-Z0-9-]+$", arn))])
    error_message = "every entry of target_group_arns must be an Application Load Balancer target group ARN of the form arn:aws:elasticloadbalancing:REGION:ACCOUNT_ID:targetgroup/NAME/GROUP_ID."
  }
}

variable "tags" {
  description = "Additional tags merged into every taggable resource of this module on top of the provider default_tags."
  type        = map(string)
  default     = {}
}
