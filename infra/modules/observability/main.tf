# This file implements the monitoring spine of the estate: a CloudWatch Logs group
# with a retention policy, the metric alarms of the compute, database and cache
# tiers, the Simple Systems Manager patch groups and the per-operating-system
# default patch baselines, the DataDog monitors and the DataDog dashboard that the
# platform owns, and the notification topic through which every alarm action of
# the estate is delivered.
#
# The dashboard layout lives in monitoring/dashboard.json at the root of this
# repository and is referenced through the file function of Terraform, so that the
# JSON of the board can be reviewed and edited as an artefact of its own instead
# of being duplicated inside a Terraform string.


data "aws_caller_identity" "current" {
  # The identity of the caller that plans this configuration: the account
  # that owns the alarms, bound into the publish policy of the topic so that only the
  # services of this account may publish into it.
}

data "aws_partition" "current" {
  # The partition of the cloud of this Region, so that the resource ARNs of the
  # topic policy are written for the partition the estate actually runs in.
}
locals {
  # alarm_namespace keeps every custom metric of the estate under one namespace,
  # which is what lets a single alarm query of the toolkit find all of them.
  alarm_namespace = "aws-cloud-ops/${var.environment_name}"

  # production_periods counts how many five-minute windows an alarm needs before
  # it fires. The value of three for the three-hour rule of the estate means that
  # a transient spike is never an incident and a sustained press always is.
  cpu_periods = 3

  common_tags = merge(
    {
      Module    = "observability"
      ManagedBy = "terraform"
    },
    var.tags
  )

  # patch_os_families is the reviewed list of operating systems of the fleet of
  # the estate; each family gets its own patch baseline so that an approval rule
  # of one family never leaks into the window of another.
  patch_os_families = ["Amazon Linux 2", "Amazon Linux 2023", "Ubuntu 22.0.4"]
}

# ---------------------------------------------------------------------------
# The notification topic of the alarms
# ---------------------------------------------------------------------------

resource "aws_sns_topic" "alarms" {
  name              = "${var.environment_name}-alarms"
  display_name      = "Alarms of ${var.environment_name}"
  kms_master_key_id = var.alarm_kms_key_arn

  tags = merge(local.common_tags, { Name = "${var.environment_name}-alarms" })
}

resource "aws_sns_topic_policy" "alarms" {
  # The policy resource of the provider binds to the topic through the arn of
  # the topic itself; the name of the argument is the identifier that the
  # service of the policy reads, and the resource is inert without it.
  arn = aws_sns_topic.alarms.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "MonitoringServicesOfThisAccountMayPublish"
        Effect    = "Allow"
        Principal = { Service = ["cloudwatch.amazonaws.com", "cloudwatch-alarm.amazonaws.com", "cloudwatch-sns-forwarder.i.events.amazonaws.com"] }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.alarms.arn
        Condition = {
          StringEquals = {
            # The publish right binds to the account that owns the alarms, and the
            # resource ARN further binds it to the one log group family that the
            # publishing services operate on.
            "aws:SourceAccount" = [data.aws_caller_identity.current.account_id]
          }
          ArnLike = {
            "aws:SourceArn" = "arn:${data.aws_partition.current.partition}:logs:*:${data.aws_caller_identity.current.account_id}:*:*"
          }
        }
      },
      {
        Sid       = "DenyPublishWithoutTransportEncryption"
        Effect    = "Deny"
        Principal = "*"
        Action    = "sns:*"
        Resource  = aws_sns_topic.alarms.arn
        Condition = {
          # The standard transport-security guard of the estate: no subscriber of
          # the topic may speak in the clear, whatever protocol it uses.
          Bool = {
            "aws:SecureTransport" = ["false"]
          }
        }
      }
    ]
  })
}

# The subscription of the operations channel is a list of endpoints that the
# caller owns; an empty list means the alarms stay in the CloudWatch console
# alone, which is the posture of a sandbox.
resource "aws_sns_topic_subscription" "operations" {
  # the for-each keys are built as a map, not through toset: the elements of the
  # variable are objects, and the argument toset accepts is restricted to the
  # primitive values of string, number, or bool. the address of the endpoint
  # keys the set on its own, and it is unique by construction.
  for_each = {
    for sub in var.notification_subscriptions : sub.endpoint => sub
  }

  topic_arn = aws_sns_topic.alarms.arn
  # The protocol of every member is validated in variables.tf so that the
  # service never sees a transport that the estate would not approve.
  protocol = each.value.protocol
  endpoint = each.value.endpoint

}

# ---------------------------------------------------------------------------
# CloudWatch Logs
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "platform" {
  for_each = var.log_retentions

  # One group per log family of the platform: the name of the group carries the
  # name of the family, and the retention is the policy of the caller. The prefix
  # form keeps the name unique across the account without a hand-minted suffix.
  name_prefix       = "/aws-cloud-ops/${var.environment_name}/${each.key}-"
  retention_in_days = each.value
  kms_key_id        = var.logs_kms_key_arn

  tags = merge(local.common_tags, {
    Name         = "${var.environment_name}-${each.key}-logs"
    "log:family" = each.key
  })
}

# ---------------------------------------------------------------------------
# The metric alarms of the estate
# ---------------------------------------------------------------------------

# alarm_common is the shared skeleton of the alarms of the estate: the actions
# ride on the topic, the missing data of a fresh host is not an incident, and the
# treat-missing-data posture is set per alarm for the cases in which the absence
# of the data is itself the signal.
locals {
  alarm_actions = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_metric_alarm" "cpu_utilisation" {
  count = var.monitor_compute ? 1 : 0

  # The metric is the platform metric of the service in the namespace of EC2;
  # the statistic of the average over three five-minute periods with two of them
  # breaching is the rule that the on-call of the platform signed off on.
  alarm_name        = "${var.environment_name}-cpu-utilisation"
  alarm_description = "The compute of a fleet host has been above ${var.cpu_threshold} percent for ${local.cpu_periods} periods of five minutes."
  namespace         = "AWS/EC2"
  metric_name       = "CPUUtilization"
  dimensions = {
    AutoScalingGroupName = var.monitored_asg_name
  }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = local.cpu_periods
  datapoints_to_alarm = 2
  threshold           = var.cpu_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions

  tags = merge(local.common_tags, { Name = "${var.environment_name}-cpu-utilisation" })
}

resource "aws_cloudwatch_metric_alarm" "status_check" {
  count = var.monitor_compute ? 1 : 0

  # The status check of the instance is the signal of a host that is alive but
  # unreachable, which is the class of incident that the pager must never miss;
  # the missing data is treated as a breach here, because a vanished host is the
  # incident, not the absence of one.
  alarm_name        = "${var.environment_name}-status-check"
  alarm_description = "A fleet host has failed its status check; the host is either dead or unreachable through the network path of the instance."
  namespace         = "AWS/EC2"
  metric_name       = "StatusCheckFailed_Instance"
  dimensions = {
    AutoScalingGroupName = var.monitored_asg_name
  }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = local.alarm_actions

  tags = merge(local.common_tags, { Name = "${var.environment_name}-status-check" })
}

resource "aws_cloudwatch_metric_alarm" "burst_balance" {
  count = var.monitor_compute ? 1 : 0

  # The surplus credit of a burstable host is the reserve that is left of the
  # credit account of the instance; when the surplus falls under the reviewed
  # value the on-call still has the window of a full period before the press bites.
  alarm_name        = "${var.environment_name}-burst-balance"
  alarm_description = "A fleet host of the burstable class has fallen under ${var.burst_balance_threshold} percent of the surplus credit of its CPU."
  namespace         = "AWS/EC2"
  metric_name       = "CPUCreditBalanceSurplus"
  dimensions = {
    AutoScalingGroupName = var.monitored_asg_name
  }
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = var.burst_balance_threshold
  comparison_operator = "LessThanThreshold"
  alarm_actions       = local.alarm_actions

  tags = merge(local.common_tags, { Name = "${var.environment_name}-burst-balance" })
}

resource "aws_cloudwatch_metric_alarm" "agent_free_memory" {
  count = var.monitor_compute ? 1 : 0

  # The memory signal of a fleet host comes from the CloudWatch agent that the
  # bootstrap of the bastion installs, which publishes its measures under the
  # namespace of the agent and adds the dimension of the auto scaling group. A
  # fleet without the agent has no memory signal at all, which is why this alarm
  # stands beside the alarms of the platform plane and not inside them.
  alarm_name        = "${var.environment_name}-free-memory"
  alarm_description = "A fleet host has less than ${var.free_memory_threshold} mebibytes of free memory; the next allocation of the workload may reach for the swap."
  namespace         = "CWAgent"
  metric_name       = "MemoryFree"
  dimensions = {
    AutoScalingGroupName = var.monitored_asg_name
  }
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = local.cpu_periods
  datapoints_to_alarm = 2
  threshold           = var.free_memory_threshold
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions

  tags = merge(local.common_tags, { Name = "${var.environment_name}-free-memory" })
}

resource "aws_cloudwatch_metric_alarm" "database_connections" {
  count = var.monitor_database ? 1 : 0

  # The saturation of the connection pool is the failure mode that every operator
  # of an application database knows by heart: the database is fine, and nothing
  # can connect any more. The threshold is a fraction of the ceiling of the class
  # that the caller passes in.
  alarm_name        = "${var.environment_name}-database-connections"
  alarm_description = "The database has reached ${var.database_connections_threshold} connections of the pool; a saturation of the pool starves every new client of the application."
  namespace         = "AWS/RDS"
  metric_name       = "DatabaseConnections"
  dimensions = {
    DBInstanceIdentifier = var.monitored_db_identifier
  }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  datapoints_to_alarm = 1
  threshold           = var.database_connections_threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  alarm_actions       = local.alarm_actions

  tags = merge(local.common_tags, { Name = "${var.environment_name}-database-connections" })
}

resource "aws_cloudwatch_metric_alarm" "freeable_memory" {
  count = var.monitor_database ? 1 : 0

  # The freeable memory of the database is the memory that the engine may reclaim
  # without pressure; when it runs low for three periods, the next large query is
  # a swap event and the swap is the outage of the trade.
  alarm_name        = "${var.environment_name}-freeable-memory"
  alarm_description = "The freeable memory of the database has fallen under ${var.freeable_memory_threshold} mebibytes; the engine is about to reach for the swap of its buffer."
  namespace         = "AWS/RDS"
  metric_name       = "FreeableMemory"
  dimensions = {
    DBInstanceIdentifier = var.monitored_db_identifier
  }
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = local.cpu_periods
  datapoints_to_alarm = 2
  threshold           = var.freeable_memory_threshold
  comparison_operator = "LessThanThreshold"
  alarm_actions       = local.alarm_actions

  tags = merge(local.common_tags, { Name = "${var.environment_name}-freeable-memory" })
}

resource "aws_cloudwatch_metric_alarm" "cache_evicted_keys" {
  count = var.monitor_cache ? 1 : 0

  # Keys that are evicted on a cache that runs full are the tax that the
  # application pays; a sustained rate of eviction is a signal to scale the tier
  # of the cache, not a signal to tune the eviction policy of it again.
  alarm_name        = "${var.environment_name}-cache-evictions"
  alarm_description = "The cache of ${var.monitored_cache_cluster_id} has evicted more than ${var.evicted_keys_threshold} keys per period; the working set has outgrown the memory of the tier."
  namespace         = "AWS/ElastiCache"
  metric_name       = "EvictedKeys"
  dimensions = {
    CacheClusterId = var.monitored_cache_cluster_id
  }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 2
  datapoints_to_alarm = 1
  threshold           = var.evicted_keys_threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  alarm_actions       = local.alarm_actions

  tags = merge(local.common_tags, { Name = "${var.environment_name}-cache-evictions" })
}

# ---------------------------------------------------------------------------
# The patch programme
# ---------------------------------------------------------------------------

resource "aws_ssm_patch_baseline" "family" {
  for_each = toset(local.patch_os_families)

  name                                 = "${var.environment_name}-${replace(lower(each.value), " ", "-")}"
  description                          = "Patch baseline of the ${each.value} family of ${var.environment_name}: it approves the security class of patch with a grace period of ${var.patch_grace_period_days} days."
  operating_system                     = each.value
  approved_patches_compliance_level    = "HIGH"
  approved_patches_enable_non_security = true

  approval_rule {
    # The approve rule of the estate: a patch that matches the filter of the
    # product is installed after the grace period of its publication, so that a
    # canary stage of the fleet meets it before the bulk of the estate does.
    approve_after_days  = var.patch_grace_period_days
    compliance_level    = "HIGH"
    enable_non_security = true

    patch_filter {
      key    = "Product"
      values = ["*"]
    }
  }

  global_filter {
    key    = "CLASSIFICATION"
    values = ["*"]
  }

  tags = merge(local.common_tags, { Name = "${var.environment_name}-${replace(lower(each.value), " ", "-")}-baseline" })
}

# The patch group of the platform collects the reviewed baselines by identifier:
# the fleet of ${var.environment_name} is patched against this set, and the group is
# the default of every patchable operating system of the platform. The narrative
# of the group lives here in the record of the change, because the resource of the
# service carries no description argument.
resource "aws_ssm_patch_group" "platform" {
  patch_group = "${var.environment_name}-platform"
  baseline_id = [for baseline in aws_ssm_patch_baseline.family : baseline.id]
}

resource "aws_ssm_default_patch_baseline" "family" {
  for_each = aws_ssm_patch_baseline.family

  # The default baseline of an operating system family must be registered once
  # per family, because the fleet of a managed node asks the service which
  # baseline it should consult when the window of the patching opens.
  operating_system = each.value.operating_system
  baseline_id      = each.value.baseline_id
}

# ---------------------------------------------------------------------------
# The DataDog plane of the platform
# ---------------------------------------------------------------------------

resource "datadog_monitor_json" "platform_watcher" {
  for_each = var.enable_datadog ? toset([
    # The two watchers of the platform are declared as the JSON documents of the
    # monitors of the service, so that the query language of the monitor is
    # written in the syntax of the vendor and not squeezed into the structured
    # blocks of the provider. The escalation message names the channel of the
    # on-call, which is what turns a page into a human act.
    jsonencode({
      name    = "${var.environment_name} compute press"
      type    = "metric alert"
      query   = "avg:system.cpu.iowait{env:${var.environment_name}} by {host} > 80"
      message = <<-EOM
        A fleet host of ${var.environment_name} has pressed its storage path for
        fifteen minutes; the escalation message of the watch routes to the team
        channel ${var.datadog_pager_channel} of the on-call.
        @${var.datadog_pager_channel}
        EOM
      options = {
        thresholds = { critical = 80 }
        # The evaluation delay of sixty seconds lets a late flush of the agent
        # still settle into the window of the evaluation, which is what keeps a
        # monitor from firing on a packet that is still on the wire.
        evaluation_delay = 60
        new_host_delay   = 600
      }
      tags = [
        "env:${var.environment_name}",
        "managed_by:terraform",
      ]
    }),
    jsonencode({
      name    = "${var.environment_name} database pool saturation"
      type    = "query alert"
      query   = "avg:rds.connections.active{db:${var.monitored_db_identifier}} > ${var.database_connections_threshold}"
      message = <<-EOM
        The connection pool of ${var.monitored_db_identifier} has reached the
        reviewed watermark; the runbook of the pool is the board of the database
        tier of ${var.environment_name}.
        @${var.datadog_pager_channel}
        EOM
      options = {
        thresholds        = { critical = var.database_connections_threshold }
        renotify_interval = 1800
        renotify_statuses = ["alert"]
      }
      tags = [
        "env:${var.environment_name}",
        "managed_by:terraform",
      ]
    }),
  ]) : toset([])

  # The monitor document is the single source of the truth of the watch: the
  # query language, the escalation of the message and the window of the
  # re-notification all ride inside the JSON of the document.
  monitor = each.value
}

resource "datadog_dashboard_json" "platform_board" {
  count = var.enable_datadog ? 1 : 0

  # The layout of the board is the JSON artefact of the repository at
  # monitoring/dashboard.json, read through the file function of Terraform so
  # that the widgets of the board are reviewed as an artefact of their own. The
  # provider of the JSON variant of the resource consumes the document verbatim,
  # which is why the structured widget language of the provider is not repeated
  # here: duplicating the layout inline would fork the truth of the board.
  #
  # The path is a variable because a registry consumer of the module does not
  # carry the directory tree of this repository; the environments of the platform
  # resolve it against the root of the repository.
  dashboard = file(var.dashboard_json_path)
}

resource "datadog_dashboard_list" "platform" {
  count = var.enable_datadog ? 1 : 0

  name = "${var.environment_name} — the board of the platform"

  dash_item {
    # The list of the board of the team holds the board of this module as an item
    # of the type of the dashboard, addressed by the identifier that the board
    # resource reports, so that the operator of the platform finds the board of
    # the estate first on the screen of the morning.
    dash_id = datadog_dashboard_json.platform_board[0].id
    type    = "custom_timeboard"
  }
}
