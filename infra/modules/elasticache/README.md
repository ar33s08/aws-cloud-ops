# elasticache

Version 1.0.0 — the Redis-compatible cache tier of the estate.

## What it creates

- An `aws_elasticache_subnet_group` built exclusively from the private subnets that
  the caller supplies, so that a cache can never be placed in front of a route to
  the internet.
- An `aws_elasticache_parameter_group` with a reviewed default set (an eviction
  policy of `volatile-lru` and a replication backlog of one mebibyte) against which
  only reviewed overrides from `parameter_overrides` are merged. Transport and
  authentication settings are not overridable, because they belong to the posture
  of the platform and not to the shape of a workload.
- One `aws_elasticache_replication_group` (this is the AWS resource and not the
  Terraform `count` idea of the same word: no copy of anything is created by it)
  with automatic failover, a caller-counted replica per shard, an optional
  cross-Zone spread, snapshots with a retention of at least one day, and a weekly
  maintenance window inside which the patch program of the estate runs.
- Encryption at rest with the platform CMK through `at_rest_encryption_enabled`
  together with `kms_key_id`; the AWS provider does expose both knobs on the
  resource, so the estate always uses them and there is no unencrypted path.
- Encryption in transit with `transit_encryption_enabled = true` and the mode of
  `required`, so the nodes refuse a plaintext handshake and a client that forgets
  its transport flag fails closed. The `preferred` mode exists as a documented,
  reviewed exception for a migration window only.

## Automatic failover is structural

`num_cache_replicas` carries a validation block that refuses zero: a shard without
a replica has nothing to promote when its primary is lost, and a failover flag
without a spare is a decoration. The module therefore always runs at least one
replica per shard and derives the topology from the counters.

## The redis-cli caveats of TLS in transit

An operator who debugs the cache from the bastion needs to know all of the
following, because every one of them generates the support ticket once:

- The plain `redis-cli` speaks the unencrypted protocol. With the required mode a
  call that lacks `--tls` is rejected at the handshake and not later, so an
  unencrypted `PING` failing is the expected, healthy behaviour of the design.
- The invocation that works from the bastion is
  `redis-cli -p 6379 --tls <primary-endpoint> ping` (the host is a positional
  argument of the modern tool; `-h` is its help flag), and with an authentication
  token it adds `-a "$token" --no-auth-warning`. The certificate of the service is
  signed by the authority of the Region, which the AL2023 trust store carries, so
  an extra `--tls-ca-cert` is not needed; an operator who points it at the wrong
  bundle gets a self-signed error that looks like an outage of the service and is
  not one. `--tls-insecure` exists for a debugging session but it skips the
  verification of the identity of the peer, so the audit trail of a session that
  used it reads as an exception.
- The shell one-liners that pipe the output of `keys *` through the tool of a
  pipeline need the same `--tls` on every member of the pipe, and a `monitor`
  session over TLS has a clearly lower ceiling than an unencrypted one; budget for
  it before the demo.
- `redis-cli --cluster call` against the configuration endpoint needs the cluster
  mode switched on; a single-shard group answers the configuration endpoint with a
  null and the call dies at DNS resolution.

## Usage

```hcl
module "orders_cache" {
  source = "../../modules/elasticache"

  replication_group_id = "acco-prod-orders-cache"
  engine               = "valkey"
  engine_version       = "8.0.2"
  parameter_group_family = "valkey-8.0"
  node_type            = "cache.r6g.large"

  cluster_mode_enabled = false
  num_cache_shards     = 1
  num_cache_replicas   = 1
  multi_az             = true

  private_subnet_ids       = module.network.private_subnet_ids
  cache_security_group_ids = [module.network.base_security_group_id]
  kms_key_arn              = module.iam.platform_key_arns["elasticache"]

  snapshot_retention_days = 14
  maintenance_window      = "sat:03:00-sat:04:00"

  parameter_overrides = {
    "maxmemory-policy" = "allkeys-lru"
  }
}
```

## Inputs and outputs

Every input is described, typed and validated in `variables.tf`; every exported
identifier is documented in `outputs.tf`.

## Notes and limitations

- This is example configuration published in a portfolio repository; it is not
  deployed at any customer site and it carries no warranty.
- The parameter families above are the reviewed snapshot of the engine versions
  that the toolkit endorses at the time of this commit; the end-of-life catalogue
  of the repository remains the authority for the drift of a date.
- An authentication token is not part of this interface: a token in the state file
  would be a secret at rest in the bucket, and the Secrets Manager path of the
  platform is the correct home of such a credential.
