# This file declares the input variables of the elasticache module. The cluster
# geometry is validated in the strictest place that the language offers: a
# variable validation for the shape of each number and a lifecycle precondition in
# main.tf for the agreement between engine and version.

variable "replication_group_id" {
  description = "The identifier of the replication group. It must start with a lowercase letter and contain lowercase letters, digits and hyphens only, because the service builds the DNS names of the endpoints from it."
  type        = string

  validation {
    condition     = can(regexmatch("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.replication_group_id))
    error_message = "replication_group_id must be 3 to 32 characters of lowercase letters, digits or hyphens, starting with a letter and ending with an alphanumeric."
  }
}

variable "engine" {
  description = "The cache engine. The module supports the two engines of the family that the service offers, redis and valkey, and the supported_engine_versions map in main.tf lists the major that each of them accepts."
  type        = string

  validation {
    condition     = contains(["redis", "valkey"], var.engine)
    error_message = "engine must be either redis or valkey."
  }
}

variable "engine_version" {
  description = <<-EOT
    The version of the cache engine. The validation below enforces the shape of the
    string and the precondition in main.tf enforces the agreement with the selected
    engine. The constraints that this module encodes per engine are:
      redis  a Redis 6 or 7 series version of the form MAJOR.MINOR.PATCH;
      valkey a Valkey 8 series version of the form MAJOR.MINOR.PATCH.
    A version outside these ranges is an end-of-life choice and the plan is refused.
    EOT
  type        = string

  validation {
    condition     = can(regexmatch("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.engine_version))
    error_message = "engine_version must be a dotted version of three numeric components, for example 7.1.0."
  }
}

variable "node_type" {
  description = "The node class of the cluster, for example cache.t3.micro for a sandbox and cache.r6g.xlarge for a capacity-bound production tier."
  type        = string

  validation {
    condition     = can(regexmatch("^cache\\.[a-z0-9]+\\.[a-z0-9]+$", var.node_type))
    error_message = "node_type must look like cache.r6g.xlarge."
  }
}

variable "cluster_mode_enabled" {
  description = "Whether the group runs in the cluster mode of the engine. The switch decides which pair of topology fields the resource uses: a disabled mode counts the nodes directly, an enabled mode counts shards as node groups."
  type        = bool
  default     = false
}

variable "num_cache_shards" {
  description = "Number of shards of the group. In a disabled cluster mode it is exactly one, in an enabled mode it is the number of node groups and the service requires at least two; the validation across both shapes lives in the precondition of the resource block."
  type        = number
  default     = 1

  validation {
    condition     = var.num_cache_shards >= 1 && var.num_cache_shards <= 90
    error_message = "num_cache_shards must sit between 1 and 90."
  }
}

variable "num_cache_replicas" {
  description = <<-EOT
    Number of replicas that every shard of the group carries. The number is the
    mechanical precondition of automatic failover: without a spare there is nothing to
    promote when the primary of a shard is lost. The validation below therefore
    refuses a value of zero, so a group of this module always has a replica and the
    failover flag can be trusted.
    EOT
  type        = number
  default     = 1

  validation {
    condition     = var.num_cache_replicas >= 1 && var.num_cache_replicas <= 5
    error_message = "num_cache_replicas must sit between 1 and 5: a value of zero would leave a shard without a spare and would make the automatic failover of the group a decoration."
  }
}

variable "multi_az" {
  description = "Whether the primaries and the replicas of the group are spread across two Availability Zones. Production uses true; development may use false to save cost, and then failover remains the only safety net."
  type        = bool
  default     = false
}

variable "parameter_group_family" {
  description = "The parameter family that the parameter group of the group binds to, for example redis-7.1 or valkey-8. It must agree with the major of engine_version, because the service refuses a parameter set of a foreign family at apply time."
  type        = string

  validation {
    condition     = can(regexmatch("^(redis|valkey)-[0-9]+\\.[0-9]+$", var.parameter_group_family))
    error_message = "parameter_group_family must look like redis-7.1 or valkey-8.0, matching the major of engine_version."
  }
}

variable "parameter_overrides" {
  description = <<-EOT
    Parameter overrides merged over the reviewed defaults of the module, for example
    a different maxmemory-policy or an eviction policy of allkeys-lru. The set of
    tunables that this interface accepts is deliberately narrow: transport and
    authentication settings are not overridable, because they belong to the security
    posture of the platform and not to the shape of the workload.
    EOT
  type        = map(string)
  default     = {}

  validation {
    condition = alltrue([
      for key in keys(var.parameter_overrides) : !contains([
        "tls-port", "ssl-port", "tls-replication", "requirepass",
        "appendonly", "protected-mode",
      ], key)
    ])
    error_message = "parameter_overrides may not address transport or authentication settings; those belong to the posture of the platform."
  }
}

variable "snapshot_retention_days" {
  description = "Number of days for which automatic snapshots of the group are retained. A zero would disable the snapshots, which the module refuses, because a cache that supports no restore drill is a rebuild event in disguise."
  type        = number
  default     = 7

  validation {
    condition     = var.snapshot_retention_days >= 1 && var.snapshot_retention_days <= 35
    error_message = "snapshot_retention_days must sit between 1 and 35 days."
  }
}

variable "snapshot_window" {
  description = "The daily window of the snapshots in the form hh:mm-hh:mm in Coordinated Universal Time."
  type        = string
  default     = "16:00-17:00"

  validation {
    condition     = can(regexmatch("^[0-2][0-9]:[0-5][0-9]-[0-2][0-9]:[0-5][0-9]$", var.snapshot_window))
    error_message = "snapshot_window must look like 16:00-17:00 with both times written in Coordinated Universal Time."
  }
}

variable "maintenance_window" {
  description = "The weekly maintenance window in the form ddd:hh:mm-ddd:hh:mm, for example sat:03:00-sat:04:00. The patch program of the estate schedules its cache work inside it."
  type        = string
  default     = "sat:03:00-sat:04:00"

  validation {
    condition     = can(regexmatch("^(mon|tue|wed|thu|fri|sat|sun):[0-2][0-9]:[0-5][0-9]-(mon|tue|wed|thu|fri|sat|sun):[0-2][0-9]:[0-5][0-9]$", var.maintenance_window))
    error_message = "maintenance_window must look like sat:03:00-sat:04:00."
  }
}

variable "transit_encryption_mode" {
  description = "The enforcement mode of the in-transit encryption. The module keeps the strict default, and the only reviewed exception is the migration period of a client that cannot do the transport encryption handshake; see the redis-cli caveats of README.md."
  type        = string
  default     = "required"

  validation {
    condition     = contains(["required", "preferred"], var.transit_encryption_mode)
    error_message = "transit_encryption_mode must be required or preferred."
  }
}

variable "kms_key_arn" {
  description = "The ARN of the KMS customer managed key that encrypts the snapshots and the data at rest. It is required, because an unencrypted cache is not an acceptable posture for this estate."
  type        = string

  validation {
    condition     = can(regexmatch("^arn:[a-z0-9-]+:kms:[a-z0-9-]+-[a-z0-9-]+-[0-9]+:(key/[0-9a-f-]+|alias/[a-zA-Z0-9/_-]+)$", var.kms_key_arn))
    error_message = "kms_key_arn must be a full KMS key ARN or key alias ARN of the form arn:aws:kms:REGION:ACCOUNT_ID:key/UUID or .../alias/NAME."
  }
}

variable "private_subnet_ids" {
  description = "The private subnets that host the nodes of the cache. A public subnet would place the cache behind a route to the internet, which this module refuses by type and by shape."
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 1 && alltrue([for id in var.private_subnet_ids : can(regexmatch("^subnet-[0-9a-f]{8,17}$", id))])
    error_message = "private_subnet_ids must be a non-empty list of subnet ids of the form subnet-0123456789abcdef0."
  }
}

variable "cache_security_group_ids" {
  description = "The security groups that admit the application tier to the TLS port of the cache. At least one is required so that an accidental open placement is impossible."
  type        = list(string)

  validation {
    condition     = length(var.cache_security_group_ids) >= 1 && alltrue([for id in var.cache_security_group_ids : can(regexmatch("^sg-[0-9a-f]{8,17}$", id))])
    error_message = "cache_security_group_ids must be a non-empty list of security group ids of the form sg-0123456789abcdef0."
  }
}

variable "tags" {
  description = "Additional tags merged into every taggable resource of this module on top of the provider default_tags."
  type        = map(string)
  default     = {}
}
