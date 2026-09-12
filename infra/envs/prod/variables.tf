# This file declares the variables of the production environment of the platform,
# the shared profile that a plan of the directory addresses with the flag of the
# file of Terraform. Each variable carries a description and a type; the values
# that the platform has reviewed for the production environment are the defaults,
# and an override is a written line of the environment file and not a hand-edit of
# a module. The reviewed profile of the production estate is the wide shape of the
# platform: three Availability Zones, the memory optimised classes of compute, and
# the database of two Zones with its read replicas.

variable "aws_region" {
  description = "The Region of the production environment of the estate. A reviewer who plans this directory against a sandbox of a laboratory points the variable at the Region of the sandbox, which is why the Region is an input of the environment and not a constant of the module."
  type        = string

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]$", var.aws_region))
    error_message = "aws_region must look like us-east-1."
  }
}

variable "owner_tag" {
  description = "The value of the owner tag of every resource of the environment, normally the team that carries the pager of the estate."
  type        = string

  validation {
    condition     = length(var.owner_tag) >= 3 && length(var.owner_tag) <= 64
    error_message = "owner_tag must name the owning team of the estate, of 3 to 64 characters."
  }
}

variable "project_tag" {
  description = "The value of the project tag of every resource of the environment, which the cost reports of the platform and the audit of the drift use as the join key."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,63}$", var.project_tag))
    error_message = "project_tag must be a lowercase handle of 2 to 64 characters, such as aws-cloud-ops."
  }
}

variable "deployment_role_arn" {
  description = "The ARN of the role that the plan and the apply of the environment assume for the pipeline of Atlantis. It is a required input of the environment on purpose: a pipeline that runs as the identity of a human is the drift that the toolkit of the repository exists to catch."
  type        = string

  validation {
    condition     = can(regex("^arn:[a-z0-9-]+:iam::[0-9]{1,12}:role/[a-zA-Z0-9+=,.@_-]+$", var.deployment_role_arn))
    error_message = "deployment_role_arn must be a full IAM role ARN of the form arn:aws:iam::ACCOUNT_ID:role/NAME."
  }
}

variable "name_prefix" {
  description = "The prefix that the modules of the estate put before every name of the environment; the production environment keeps it short, because the names of the service are budgets of characters and not gifts."
  type        = string
  default     = "acco-prod"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}$", var.name_prefix))
    error_message = "name_prefix must start with a lowercase letter and contain lowercase letters, digits or hyphens only, of at most 31 characters."
  }
}

variable "vpc_cidr" {
  description = "The Classless Inter-Domain Routing block of the network of the environment; the production slice of the address plan of the platform."
  type        = string
  default     = "10.22.0.0/16"

  validation {
    condition     = can(cidrsubnets(var.vpc_cidr, 8, 0))
    error_message = "vpc_cidr must be a valid IPv4 Classless Inter-Domain Routing block of at most a /24 prefix, such as 10.22.0.0/16."
  }
}

variable "az_count" {
  description = "The number of Availability Zones that the production topology spans. The reviewed value of the production environment is three: the fleet of the entry tier, the database of two Zones and the caches of the estate all lean on the third Zone as the failure domain that the estate is sized against."
  type        = number
  default     = 3
}

variable "bastion_instance_type" {
  description = "The instance class of the bastion fleet of the production environment; a burstable class of the reviewed size is the shape of an entry fleet that must survive a session storm of an incident night."
  type        = string
  default     = "t3.small"
}

variable "bastion_capacity_floor" {
  description = "The floor of the bastion fleet of the environment, the number of entry hosts that the auto scaling group keeps warm through the quiet of the night. The reviewed value of the production environment is two, because a single entry host is a single point of the access path of the whole estate."
  type        = number
  default     = 2
}

variable "bastion_capacity_ceiling" {
  description = "The ceiling of the bastion fleet of the environment. The fleet serves operator sessions and not traffic, so the reviewed ceiling of the platform is three; a fleet that has to grow past the value is the sign of an incident that is being run by hand and not by the tooling."
  type        = number
  default     = 3
}

variable "database_instance_class" {
  description = "The instance class of the database of the production environment, of the memory optimised family, because the working set of the orders tier is sized against the buffer of the engine and not against the credit account of a burstable class."
  type        = string
  default     = "db.r6g.xlarge"
}

variable "read_replica_count" {
  description = "The number of read replicas of the database of the environment. The reviewed profile of the production estate carries two, which is the fan of the read traffic that the reports of the orders tier draw against the primary of the platform."
  type        = number
  default     = 2
}

variable "cache_node_type" {
  description = "The node class of the cache of the production environment, of the memory optimised family of the tier."
  type        = string
  default     = "cache.r6g.large"
}

variable "database_multi_az" {
  description = "Whether the database of the environment is spread across two Availability Zones with a synchronous standby. The reviewed value of the production environment is true: the failover of a standby of a Zone is the only restore path that the mean time to recovery of the estate can live with."
  type        = bool
  default     = true
}

variable "datadog_api_key" {
  description = "The key of the interface of the DataDog plane of the environment. It arrives from the environment of the runner and is deliberately without a default, so that a forgetful apply fails the validation in stead of shipping an unmonitored estate."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.datadog_api_key) >= 24
    error_message = "datadog_api_key must be the credential of the DataDog plane that the runner of the pipeline carries."
  }
}

variable "datadog_app_key" {
  description = "The key of the application of the DataDog plane of the environment, with the same rule as the key of the interface above."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.datadog_app_key) >= 24
    error_message = "datadog_app_key must be the credential of the DataDog plane that the runner of the pipeline carries."
  }
}

variable "enable_datadog" {
  description = "Whether the DataDog plane of the platform is materialised by the environment; a reviewer who plans the directory without the credentials of the vendor flips it to false and still gets a complete plan of the AWS side."
  type        = bool
  default     = true
}

variable "break_glass_role_arn" {
  description = "The ARN of the break-glass role of the estate that the deny policy of the iam module exempts from the destructive list. The production environment points it at the session-gated, alarmed governance role of the platform."
  type        = string

  validation {
    condition     = can(regex("^arn:[a-z0-9-]+:iam::[0-9]{1,12}:role/[a-zA-Z0-9+=,.@_-]+$", var.break_glass_role_arn))
    error_message = "break_glass_role_arn must be a full IAM role ARN of the form arn:aws:iam::ACCOUNT_ID:role/NAME."
  }
}

variable "key_admin_role_arns" {
  description = "The full ARNs of the roles that may govern the platform keys of the environment. The production environment admits the governance role of the keys and the break-glass role, and the precondition of the key resource refuses anything else."
  type        = list(string)

  validation {
    condition     = length(var.key_admin_role_arns) >= 1
    error_message = "key_admin_role_arns must name at least one role of the platform."
  }
}

variable "database_engine_version" {
  description = "The version of the database engine of the production environment; the end-of-life gates of the rds module police it, so a stale value fails the plan and not the review of an incident."
  type        = string
  default     = "8.0.35"
}

variable "cache_engine_version" {
  description = "The version of the cache engine of the production environment; the end-of-life gates of the elasticache module police it in the same way."
  type        = string
  default     = "7.1.0"
}

variable "datadog_pager_channel" {
  description = "The name of the route of the pager of the DataDog plane that the monitors of the production estate notify. It is an input of the environment and not a default, because a route of the pager that the review of the platform has not named is a monitor that pages no one."
  type        = string

  validation {
    condition     = length(var.datadog_pager_channel) >= 3 && can(regex("^[a-zA-Z0-9_-]+$", var.datadog_pager_channel))
    error_message = "datadog_pager_channel must name the route of the pager of the DataDog plane as a single token."
  }
}

variable "notification_subscriptions" {
  description = "The subscriptions of the topic of the alarms of the CloudWatch, as a list of the objects that the module of the observability accepts (the protocol and the endpoint). The production estate carries them explicitly so that the review of the pull request shows who is paged by the change; the empty list is legal and is the shape of a sandbox, not the shape of the platform."
  type = list(object({
    protocol = string
    endpoint = string
  }))
  default = []
}
