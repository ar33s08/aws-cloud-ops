# This file declares the input variables of the iam module. The module governs
# the account-wide controls, so the interface is intentionally narrow: the caller
# chooses the scopes and the names, and the posture itself is not negotiable from
# the outside.

variable "environment_name" {
  description = "The short name of the environment, for example acco-dev or acco-prod. It prefixes every name, alias and tag of the module."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}$", var.environment_name))
    error_message = "environment_name must start with a lowercase letter and contain lowercase letters, digits or hyphens only, of at most 31 characters."
  }
}

variable "key_scopes" {
  description = <<-EOT
    The scopes of the platform keys that this environment materialises, each one an
    entry of the key_service_principals map in main.tf: ebs, rds, pi, logs, cloudwatch,
    elasticache, backups, secrets or sns_alarms. A key that is named here gets an
    alias of the form environment_name/scope in the Region, and the consumers of the
    platform address the keys only through those aliases.
    EOT
  type        = list(string)
  default = [
    "ebs",
    "rds",
    "pi",
    "logs",
    "cloudwatch",
    "elasticache",
    "backups",
    "secrets",
    "sns_alarms",
  ]

  validation {
    condition     = alltrue([for scope in var.key_scopes : contains(["ebs", "rds", "pi", "logs", "cloudwatch", "elasticache", "backups", "secrets", "sns_alarms"], scope)])
    error_message = "every member of key_scopes must be one of ebs, rds, pi, logs, cloudwatch, elasticache, backups, secrets or sns_alarms, the scopes whose key policy is reviewed in main.tf."
  }
}

variable "kms_deletion_window_days" {
  description = "The waiting period in days before the erasure of a platform key takes effect. The window is the alarm time of an accidental destroy, so the estate never accepts a window below the seven days of a weekend."
  type        = number
  default     = 30

  validation {
    condition     = var.kms_deletion_window_days >= 7 && var.kms_deletion_window_days <= 30
    error_message = "kms_deletion_window_days must sit between 7 and 30 days, the window that the service offers at all."
  }
}

variable "password_minimum_length" {
  description = "Minimum length of an interactive password of the account. The reviewed baseline of the estate is fourteen characters; the validation below refuses anything shorter than the eleven that the service will accept, so that a silent weakening of the posture in a review fails the plan."
  type        = number
  default     = 14

  validation {
    condition     = var.password_minimum_length >= 14 && var.password_minimum_length <= 128
    error_message = "password_minimum_length must be at least 14; the estate does not ship an environment with a weaker human credential than the reviewed baseline."
  }
}

variable "manage_password_policy" {
  description = "Whether the account password policy is managed by this module. It is switched off only for an organisation that keeps the account-wide control in a separate governance stack, and the comment in the plan must say which of the stacks owns it."
  type        = bool
  default     = true
}

variable "key_admin_role_arns" {
  description = "The full ARNs of the roles that may govern the platform keys, meaning the rotation, the policy and the deletion scheduling. Every entry must be a role ARN: the precondition of the key resource refuses a wildcard, a root or a service principal."
  type        = list(string)

  validation {
    condition     = length(var.key_admin_role_arns) >= 1
    error_message = "key_admin_role_arns must name at least one role of the platform; a key without a named administrator cannot be governed by anyone."
  }
}

variable "break_glass_role_arn" {
  description = "The full ARN of the break-glass role of the estate, which is the only principal that the deny policy of the estate exempts from the destructive list. The role is normally a session-gated, alarmed role of the governance stack."
  type        = string

  validation {
    condition     = can(regex("^arn:[a-z0-9-]+:iam::[0-9]{1,12}:role/[a-zA-Z0-9+=,.@_-]+$", var.break_glass_role_arn))
    error_message = "break_glass_role_arn must be a full IAM role ARN of the form arn:aws:iam::ACCOUNT_ID:role/NAME."
  }
}

variable "tags" {
  description = "Additional tags merged into every taggable resource of this module on top of the provider default_tags."
  type        = map(string)
  default     = {}
}
