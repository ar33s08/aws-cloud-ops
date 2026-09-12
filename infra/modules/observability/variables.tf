# This file declares the input variables of the observability module. The module
# is the single place of the estate where a threshold is defined, so the variables
# carry the reviewed values of the platform and the caller overrides them only
# with a written reason in the environment file.

variable "environment_name" {
  description = "The short name of the environment, for example acco-dev or acco-prod; it prefixes every alarm, log group and patch artefact of the module."
  type        = string

  validation {
    condition     = can(regexmatch("^[a-z][a-z0-9-]{1,30}$", var.environment_name))
    error_message = "environment_name must start with a lowercase letter and contain lowercase letters, digits or hyphens only, of at most 31 characters."
  }
}

variable "log_retentions" {
  description = <<-EOT
    The CloudWatch Logs groups of the platform, keyed by the family of the log, with
    the number of days of the retention as the value. The reviewed set is application
    for the stdout of the fleet, audit for the trail of the actions, and engine for
    the exports of the database. The validation accepts only the retention periods
    that the service offers at all.
    EOT
  type        = map(number)
  default = {
    application = 30
    audit       = 365
    engine      = 90
  }

  validation {
    condition = alltrue([
      for family, days in var.log_retentions : contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1461, 1827, 2192, 2557, 2922, 3288, 3653], days)
    ])
    error_message = "every retention of log_retentions must be one of the day counts that CloudWatch Logs offers: 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1461, 1827, 2192, 2557, 2922, 3288 or 3653."
  }
}

variable "logs_kms_key_arn" {
  description = "The ARN of the key that encrypts the platform log groups at rest. The caller resolves it from the logs scope of the platform key map of the iam module."
  type        = string

  validation {
    condition     = can(regexmatch("^arn:[a-z0-9-]+:kms:[a-z0-9-]+-[a-z0-9-]+-[0-9]+:(key/[0-9a-f-]+|alias/[a-zA-Z0-9/_-]+)$", var.logs_kms_key_arn))
    error_message = "logs_kms_key_arn must be a full KMS key ARN or key alias ARN of the form arn:aws:kms:REGION:ACCOUNT_ID:key/UUID or .../alias/NAME."
  }
}

variable "alarm_kms_key_arn" {
  description = "The ARN of the key that encrypts the messages of the alarm topic at rest. The caller resolves it from the sns-alarms scope of the platform key map of the iam module."
  type        = string

  validation {
    condition     = can(regexmatch("^arn:[a-z0-9-]+:kms:[a-z0-9-]+-[a-z0-9-]+-[0-9]+:(key/[0-9a-f-]+|alias/[a-zA-Z0-9/_-]+)$", var.alarm_kms_key_arn))
    error_message = "alarm_kms_key_arn must be a full KMS key ARN or key alias ARN."
  }
}

variable "monitor_compute" {
  description = "Whether the alarms of the compute tier are created; a sandbox may switch them off so that the alarm of a test does not page the on-call of the humans."
  type        = bool
  default     = true
}

variable "monitor_database" {
  description = "Whether the alarms of the database tier are created."
  type        = bool
  default     = true
}

variable "monitor_cache" {
  description = "Whether the alarms of the cache tier are created."
  type        = bool
  default     = true
}

variable "monitored_asg_name" {
  description = "The name of the bastion fleet of the auto scaling module that the compute alarms watch; the compute alarms bind their dimensions to it."
  type        = string
  default     = null

  validation {
    condition     = var.monitored_asg_name == null ? true : can(regexmatch("^[a-zA-Z0-9-_][a-zA-Z0-9-_+.=,@\\[\\]]{0,254}$", var.monitored_asg_name))
    error_message = "monitored_asg_name must name an existing auto scaling group of the environment."
  }
}

variable "monitored_db_identifier" {
  description = "The identifier of the database instance of the rds module that the database alarms watch."
  type        = string
  default     = null
}

variable "monitored_cache_cluster_id" {
  description = "The identifier of the ElastiCache cluster of the elasticache module that the cache alarms watch."
  type        = string
  default     = null
}

variable "cpu_threshold" {
  description = "The percentage of the compute of a host above which the alarm of the CPU of the fleet fires; the reviewed baseline of the platform is eighty percent."
  type        = number
  default     = 80

  validation {
    condition     = var.cpu_threshold > 50 && var.cpu_threshold < 100
    error_message = "cpu_threshold must sit between 50 and 100 percent: an alarm that fires at a lower value is noise, and one that fires at the whole of the value is too late to be a warning."
  }
}

variable "burst_balance_threshold" {
  description = "The percent of the CPU credit of a burstable host below which the alarm of the burst balance fires, at one hundred percent of the spend of the credit."
  type        = number
  default     = 100
}

variable "database_connections_threshold" {
  description = "The number of connections of the database at which the alarm of the pool fires. The caller sets it as a fraction of the ceiling of the instance class of the database, and the runbook of the pool of the platform carries the arithmetic."
  type        = number
  default     = 200
}

variable "freeable_memory_threshold" {
  description = "The mebibytes of freeable memory of the database below which the alarm of the memory of the engine fires; the reviewed baseline of the platform is two hundred fifty-six mebibytes."
  type        = number
  default     = 256
}

variable "evicted_keys_threshold" {
  description = "The keys per period of the cache above which the alarm of the eviction fires; the working set of a tier that crosses the value has outgrown the memory of the tier."
  type        = number
  default     = 100000
}

variable "notification_subscriptions" {
  description = <<-EOT
    The subscriptions of the alarm topic of the estate, each a map of protocol and
    endpoint, for example { protocol = "email", endpoint = "on-call@acme.example" } or
    { protocol = "https", endpoint = "https://hooks.acme.example/alarms" }. The
    validation admits only the transports that the estate approves, so an endpoint of
    the alarms can not be delivered over a channel that the platform does not
    recognise.
    EOT
  type = list(object({
    protocol = string
    endpoint = string
  }))
  default = []

  validation {
    condition = alltrue([
      for sub in var.notification_subscriptions :
      contains(["email", "email-json", "https", "sqs", "lambda"], sub.protocol)
    ]) && alltrue([
      for sub in var.notification_subscriptions :
      (sub.protocol == "https" ? can(regexmatch("^https://[a-zA-Z0-9-./%_~]+$", sub.endpoint)) : true)
    ])
    error_message = "every subscription must use one of email, email-json, https, sqs or lambda, and an endpoint of the https protocol must be a full https address."
  }
}

variable "enable_datadog" {
  description = "Whether the DataDog plane of the platform is materialised. The switch exists for a sandbox or for a reviewer of the plan that has no credentials of the DataDog at hand, and a real environment sets it true."
  type        = bool
  default     = false
}

variable "dashboard_json_path" {
  description = "The path of the JSON artefact of the board of the platform, which the module reads with the file function. The environments of the platform resolve it against the monitoring directory of the repository, so that the layout of the board stays an artefact of its own."
  type        = string

  validation {
    condition     = can(regexmatch(".*[a-zA-Z0-9_/.-]+\\.json$", var.dashboard_json_path))
    error_message = "dashboard_json_path must name an existing JSON file of the repository."
  }
}

variable "patch_grace_period_days" {
  description = "The days of the grace period between the publication of a patch and its approval for the bulk of the fleet. The reviewed baseline of the estate of three days buys the canary stage its window; a value of zero would deploy a patch to the whole of the estate on the day of its publication."
  type        = number
  default     = 3

  validation {
    condition     = var.patch_grace_period_days >= 1 && var.patch_grace_period_days <= 30
    error_message = "patch_grace_period_days must sit between 1 and 30 days."
  }
}

variable "datadog_pager_channel" {
  description = "The name of the channel of the on-call that the escalation message of a DataDog watcher addresses, without the leading at sign of the channel."
  type        = string

  validation {
    condition     = can(regexmatch("^[a-zA-Z0-9-]{1,80}$", var.datadog_pager_channel))
    error_message = "datadog_pager_channel must name one channel of the platform without an at sign, for example oncall-platform."
  }
}

variable "tags" {
  description = "Additional tags merged into every taggable resource of this module on top of the provider default_tags."
  type        = map(string)
  default     = {}
}
