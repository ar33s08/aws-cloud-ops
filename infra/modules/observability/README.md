# observability

Version 1.0.0 — the monitoring, logging and patch spine of the estate.

## What it creates

- One CloudWatch Logs group per family of the platform (`application`, `audit`,
  `engine` by default), each with a caller-chosen retention in days and encrypted
  with the platform CMK of the `logs` scope of the iam module.
- The metric alarms of the estate, each publishing into the one alarm topic:
  - `CPUUtilization` above eighty percent of the average of a fleet host over
    three periods of five minutes, of which two must breach.
  - `StatusCheckFailed_Instance` — the signal of a host that is dead or that the
    network path of the instance cannot reach; missing data is treated as a
    breach here, because a vanished host is the incident itself.
  - `CPUCreditBalanceSurplus` below the reviewed value, the forerunner of the
    slow-down of the entry tier of a burstable fleet.
  - `DatabaseConnections` of the database at the saturation watermark of the
    connection pool, which is the failure mode in which the database is fine and
    nothing can connect to it any more.
  - `FreeableMemory` of the database below the reviewed floor, the forerunner of
    the reach of the engine for the swap of its buffer.
  - `EvictedKeys` per ElastiCache cluster, the tax that an application pays when
    the working set has outgrown the memory of the tier.
- The patch programme: one `aws_ssm_patch_baseline` per operating system family of
  the fleet with a grace period of the reviewed number of days and a patch filter
  of the product, one `aws_ssm_patch_group` for the estate, and one
  `aws_ssm_default_patch_baseline` registration per family, because the managed
  node of a fleet has to be able to ask the service which baseline governs its
  operating system when the window of the patching opens.
- The DataDog plane of the platform: two `datadog_monitor_json` watches of the
  compute press and of the connection pool, and the board of the platform as a
  `datadog_dashboard_json` whose layout is read with the `file()` function of
  Terraform from the artefact `monitoring/dashboard.json` at the root of this
  repository. The layout is deliberately **not** duplicated inline: the JSON file
  is the single source of the truth of the board and a structured `widget` block
  in this file would fork that truth.
- The `datadog_dashboard_list` entry that puts the board of the environment first
  on the screen of the operator of the morning.
- The notification path: an SNS topic of the estate, encrypted at rest with the
  CMK of the alarm scope, whose topic policy admits a publish only from the
  monitoring services of this very account and denies any transport that is not
  the encrypted one.

## The patch baselines per operating system

`patch_os_families` in `main.tf` is the reviewed list of families of the fleet,
and one baseline is materialised per family so that an approval rule of a family
never leaks into the window of another family. A new operating system of the
fleet is added to that list with a review of its own.

## Usage

```hcl
module "observability" {
  source = "../../modules/observability"

  environment_name = "acco-prod"

  logs_kms_key_arn  = module.iam.platform_key_arns["logs"]
  alarm_kms_key_arn = module.iam.platform_key_arns["sns_alarms"]

  monitored_asg_name        = module.bastion.bastion_autoscaling_group_name
  monitored_db_identifier   = module.orders_db.db_instance_id
  monitored_cache_cluster_id = module.orders_cache.replication_group_id

  cpu_threshold                 = 80
  database_connections_threshold = 320
  freeable_memory_threshold      = 256
  evicted_keys_threshold         = 100000
  patch_grace_period_days        = 3

  enable_datadog        = true
  dashboard_json_path   = "${path.root}/../../monitoring/dashboard.json"
  datadog_pager_channel = "oncall-platform"

  notification_subscriptions = [
    { protocol = "email", endpoint = "on-call@acme.example" },
  ]
}
```

## Inputs and outputs

Every input is described, typed and validated in `variables.tf`; every exported
identifier is documented in `outputs.tf`.

## Notes and limitations

- This is example configuration published in a portfolio repository; it is not
  deployed at any customer site and it carries no warranty.
- The memory alarm of the fleet reads the CloudWatch agent metric `MemoryFree`
  of the agent that the bootstrap of the bastion installs; a fleet without the
  agent therefore has no memory signal at all, which is why the compute alarms
  of this module are gated on `monitor_compute` together with the agent.
- The DataDog resources require the credentials of the DataDog provider of the
  environment (`DD_API_KEY` and `DD_APP_KEY`); the `enable_datadog` switch exists
  so that a reviewer who plans the module without the credentials does not meet a
  provider error of the authentication.
