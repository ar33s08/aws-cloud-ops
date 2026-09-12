# network

Version 1.0.0 — the private-only reference network for the aws-cloud-ops estate.

## What it creates

- One VPC with a caller-controlled CIDR block, DNS support and DNS hostnames enabled.
- Three private subnets, one per selected Availability Zone, with public addressing
  turned off for every instance launched into them.
- Two isolated subnets. They exist so that the shared NAT gateway has a placement and
  so that future inspection appliances can be parked without a route to the internet.
- A connectivity route table that owns the only `0.0.0.0/0` route of the whole design,
  pointing at the internet gateway, and that is associated only with the subnet which
  hosts the NAT gateway. No workload subnet ever carries a default route to the
  internet.
- A private route table whose default route points at the NAT gateway, associated
  with every private subnet.
- Interface endpoints for the Systems Manager control plane (`ssm`, `ssmmessages`,
  `ec2messages`), for `kms` and for `logs`, each with private DNS and an endpoint
  policy that restricts access with the `aws:Vpc` condition key.
- A hardened base security group that carries no ingress rules at all; consumers
  attach it and then add only fully scoped rules on their own group.
- VPC flow logs of type `ALL` delivered to a CloudWatch Logs group with a caller
  chosen retention period, optionally encrypted with an account-owned KMS CMK.

## Security posture

No subnet in this design is public and there is no `0.0.0.0/0` rule reachable by a
workload. Operator access is expected to come through AWS Systems Manager Session
Manager, never through an inbound port, so none exists.

## Usage

```hcl
module "network" {
  source = "../../modules/network"

  name_prefix = "acco-dev"
  vpc_cidr    = "10.20.0.0/16"
  az_count    = 1

  flow_log_retention_days = 90
  flow_log_aggregation_interval = 60
}
```

The companion examples in this directory (for production topology values) are shown
below.

```hcl
module "network" {
  source = "../../modules/network"

  name_prefix = "acco-prod"
  vpc_cidr    = "10.22.0.0/16"
  az_count    = 3

  logs_kms_key_arn = module.platform_kms.logs_key_arn
}
```

## Inputs and outputs

The full contract is documented next to each declaration: see `variables.tf` for the
inputs, each with a description, a type and a validation where correctness matters,
and `outputs.tf` for the identifiers that consumers need.

## Notes and limitations

- This is example configuration published in a portfolio repository; it is not
  deployed at any customer site and it carries no warranty.
- The isolated subnets are deliberately not associated with any route table that has
  a default route; the NAT gateway therefore reaches the public segment through its
  own subnet only.
- The interface endpoints use region-qualified service names. The environment layers
  interpolate the active region into them so that the modules stay Region-neutral.
