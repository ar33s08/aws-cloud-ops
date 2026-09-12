# This file declares the input variables of the network module. Every variable
# carries a description, a type constraint, and where correctness matters a
# validation block that fails the plan early with a helpful message instead of a
# confusing apply-time error.

variable "name_prefix" {
  description = "Prefix applied to every name and name-prefix in this module. It must start with a letter and contain only lowercase letters, digits and hyphens."
  type        = string

  validation {
    condition     = can(regexmatch("^[a-z][a-z0-9-]{1,30}$", var.name_prefix))
    error_message = "name_prefix must start with a lowercase letter and contain only lowercase letters, digits or hyphens (maximum 31 characters)."
  }
}

variable "vpc_cidr" {
  description = "The IPv4 CIDR block of the VPC. A /2x block (for example 10.2x.0.0/16) leaves room for the private and isolated subnets that this module carves out of it."
  type        = string

  validation {
    condition     = can(cidrsubnets(var.vpc_cidr, 8, 0))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block that is at most a /2x so that the subnet plan still has room (for example 10.2x.0.0/16)."
  }
}

variable "az_count" {
  description = "Number of Availability Zones that receive a private subnet. Development environments use 1, production uses 3. The isolated subnets are placed across the same Zones."
  type        = number
  default     = 3

  validation {
    condition     = var.az_count >= 1 && var.az_count <= 4
    error_message = "az_count must be between 1 and 4 so that the subnet plan stays inside the usable slice of the Region."
  }
}

variable "flow_log_retention_days" {
  description = "Retention in days for the CloudWatch Logs group that receives the VPC flow logs. Common audit values are 90, 180 and 365."
  type        = number
  default     = 90

  validation {
    condition     = contains([1, 3, 7, 14, 30, 60, 90, 120, 180, 365, 400, 545, 731, 1827, 2192, 2557, 2922, 3653], var.flow_log_retention_days)
    error_message = "flow_log_retention_days must be one of the retention periods that CloudWatch Logs accepts (1, 3, 7, 14, 30, 60, 90, 120, 180, 365, 400, 545, 731, 1827, 2192, 2557, 2922, 3653)."
  }
}

variable "flow_log_aggregation_interval" {
  description = "Maximum aggregation interval in seconds for the flow logs. A larger interval reduces cost at the expense of latency of the log stream."
  type        = number
  default     = 60

  validation {
    condition     = contains([1, 5, 10, 15, 30, 60], var.flow_log_aggregation_interval)
    error_message = "flow_log_aggregation_interval must be one of 1, 5, 10, 15, 30 or 60 seconds."
  }
}

variable "logs_kms_key_arn" {
  description = "Optional ARN of the KMS customer managed key that encrypts the flow log group at rest. When it is null the AWS managed key for CloudWatch Logs is used, which is weaker than an account-owned CMK."
  type        = string
  default     = null

  validation {
    condition     = var.logs_kms_key_arn == null ? true : can(regexmatch("^arn:[a-z0-9-]+:kms:[a-z0-9-]+-[a-z0-9-]+-[0-9]+:key/[0-9a-f-]+$", var.logs_kms_key_arn))
    error_message = "logs_kms_key_arn must be a full KMS key ARN of the form arn:aws:kms:REGION:ACCOUNT_ID:key/UUID."
  }
}

variable "endpoint_service_names" {
  description = "Set of interface endpoint service names that are created in the private subnets. The defaults cover the SSM chain, KMS and CloudWatch Logs so that management traffic never leaves the AWS backbone."
  type        = set(string)
  default = [
    "com.amazonaws.vpc.ssm",
    "com.amazonaws.vpc.ssmmessages",
    "com.amazonaws.vpc.ec2messages",
    "com.amazonaws.kms",
    "com.amazonaws.logs",
  ]
}

variable "tags" {
  description = "Additional tags merged into every taggable resource in this module. The provider default_tags already contribute owner and project; the values here are for module-specific labels such as cost-center or compliance-tier."
  type        = map(string)
  default     = {}
}
