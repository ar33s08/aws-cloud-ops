# This file implements the Redis-compatible cache layer of the estate: one
# ElastiCache replication group with automatic failover, an encrypted-at-rest
# configuration with its own KMS key, in-transit encryption in required mode, a
# reviewed parameter group, and a snapshot retention policy.
#
# Encryption at rest: the AWS provider does expose the knobs on this resource, so
# the module sets at_rest_encryption_enabled together with kms_key_id. Note the
# asymmetry with the in-transit story: the key of the data tier is a customer
# managed key of the platform, and there is no unencrypted fallback path.

locals {
  # supported_engine_versions documents the engine majors that this module
  # accepts, in the same spirit as the database module: the validation of the
  # variable checks the shape, and the precondition of the resource below checks
  # the agreement with the selected engine so that an end-of-life cache version
  # fails the plan instead of the incident review.
  supported_engine_versions = {
    "redis"  = "^(6|7)\\.[0-9]+\\.[0-9]+$"
    "valkey" = "^8\\.[0-9]+\\.[0-9]+$"
  }

  # automatic failover is only honest when the group really has a spare: the
  # variable validation below refuses a replica count of zero, so the expression
  # here is a documentation of the rule, not a negotiation of it.
  failover_enabled = var.num_cache_replicas >= 1

  # cluster_mode decides how the topology is expressed. The service counts the
  # nodes of a single shard directly and counts node groups only when the cluster
  # mode of the engine is switched on, so the resource block picks the matching
  # pair of fields from this value.
  cluster_mode = var.cluster_mode_enabled ? "enabled" : "disabled"

  # The default of the eviction policy follows the platform rule: caches evict
  # least-recently-used keys with a time to live before they shed new writes,
  # which is what keeps a memory press from turning into a brownout of the tier.
  parameter_set = merge(
    {
      "maxmemory-policy"  = "volatile-lru"
      "repl-backlog-size" = "1048576"
    },
    var.parameter_overrides
  )

  common_tags = merge(
    {
      Module    = "elasticache"
      ManagedBy = "terraform"
    },
    var.tags
  )
}

resource "aws_elasticache_subnet_group" "private" {
  name        = "${var.replication_group_id}-private"
  description = "Private-tier subnet group for the cache ${var.replication_group_id}; it must never contain a public subnet."

  # The validation on private_subnet_ids keeps the placement inside the private
  # tier of the network module, exactly as the database module does.
  subnet_ids = var.private_subnet_ids

  tags = merge(local.common_tags, {
    Name            = "${var.replication_group_id}-cache-sg"
    "security:tier" = "private-only"
  })
}

resource "aws_elasticache_parameter_group" "engine" {
  name        = "${var.replication_group_id}-engine"
  family      = var.parameter_group_family
  description = "Hardened parameter set for the ${var.engine} cache ${var.replication_group_id}."

  dynamic "parameter" {
    for_each = local.parameter_set
    content {
      name  = each.key
      value = each.value
    }
  }

  tags = merge(local.common_tags, { Name = "${var.replication_group_id}-params" })
}

resource "aws_elasticache_replication_group" "this" {
  replication_group_id = var.replication_group_id
  description          = "SSM-managed ${var.engine} cache of the ${var.replication_group_id} workload."

  engine                     = var.engine
  engine_version             = var.engine_version
  node_type                  = var.node_type
  automatic_failover_enabled = local.failover_enabled
  multi_az_enabled           = var.multi_az

  # The topology is expressed in whichever pair of fields the service expects for
  # the chosen mode: a single shard counts its nodes directly (the primary plus
  # its replicas), while a sharded group counts node groups and the replicas of
  # each group. The precondition below keeps the two views consistent.
  cluster_mode            = local.cluster_mode
  num_cache_clusters      = local.cluster_mode == "disabled" ? var.num_cache_replicas + 1 : null
  num_node_groups         = local.cluster_mode == "enabled" ? var.num_cache_shards : null
  replicas_per_node_group = local.cluster_mode == "enabled" ? var.num_cache_replicas : null

  # The TLS port of the service; with the in-transit switch below in required
  # mode this is the only port that the nodes answer on.
  port                       = 6379
  snapshot_retention_limit   = var.snapshot_retention_days
  snapshot_window            = var.snapshot_window
  maintenance_window         = var.maintenance_window
  apply_immediately          = false
  auto_minor_version_upgrade = true

  # The cache sits in the private tier of the network module and is reachable
  # only from the application security groups that the caller passes.
  subnet_group_name  = aws_elasticache_subnet_group.private.name
  security_group_ids = var.cache_security_group_ids

  parameter_group_name = aws_elasticache_parameter_group.engine.name

  # Data at rest is encrypted with a platform CMK: the AWS provider does expose
  # at_rest_encryption_enabled and kms_key_id on this resource, so the estate
  # uses them instead of accepting an unencrypted cache.
  at_rest_encryption_enabled = true
  kms_key_id                 = var.kms_key_arn

  # Data in transit is encrypted and the server refuses any plaintext handshake,
  # so a client that forgets its transport encryption flag fails closed. The
  # redis-cli caveats of that switch are documented in README.md.
  transit_encryption_enabled = true
  transit_encryption_mode    = var.transit_encryption_mode

  tags = merge(local.common_tags, {
    Name           = var.replication_group_id
    "cache:engine" = var.engine
    "eol:managed"  = "true"
  })

  lifecycle {
    # Losing the cache to a mistyped destroy is recoverable only by a rebuild of
    # the warm data, so the guard stays switched on for the estate.
    prevent_destroy = true

    # The gate below mirrors the end-of-life policy of the toolkit: the version
    # must match the pattern that the engine declares in the variables file.
    precondition {
      condition     = can(regex(local.supported_engine_versions[var.engine], var.engine_version))
      error_message = "engine_version ${var.engine_version} is outside the supported majors for engine ${var.engine}; see the supported_engine_versions map above and the end-of-life catalogue of the toolkit."
    }

    # The gate below keeps the topology honest in both modes: a disabled cluster
    # mode is a single shard by definition, and an enabled mode demands at least
    # two shards, which is what the service itself enforces at apply time.
    precondition {
      condition     = var.cluster_mode_enabled ? var.num_cache_shards >= 2 : var.num_cache_shards == 1
      error_message = "the shard count contradicts the cluster mode: a disabled cluster mode takes exactly one shard and an enabled mode takes at least two."
    }
  }
}
