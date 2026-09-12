# This file exposes the identifiers of the monitoring spine so that the rest of
# the estate and the reports of the toolkit can address the alarms, the log
# groups, the patch baselines and the notification path without reading main.tf.

output "alarm_topic_arn" {
  description = "The ARN of the alarm topic that every metric alarm of the estate publishes into; the iam module grants the publish right for exactly this ARN."
  value       = aws_sns_topic.alarms.arn
}

output "alarm_topic_name" {
  description = "The name of the alarm topic, for the subscription tooling of the on-call."
  value       = aws_sns_topic.alarms.name
}

output "log_group_names" {
  description = "The names of the platform log groups, keyed by the family of the log such as application, audit or engine."
  value       = { for family, group in aws_cloudwatch_log_group.platform : family => group.name }
}

output "log_group_arns" {
  description = "The ARNs of the platform log groups, keyed by the family of the log, for the resource policy of a log delivery."
  value       = { for family, group in aws_cloudwatch_log_group.platform : family => group.arn }
}

output "alarm_arns" {
  description = "The ARNs of every metric alarm of the estate, keyed by the name of the alarm resource, so that the drift report of the toolkit may check each of the guards of the platform against the console of the service."
  value = merge(
    var.monitor_compute ? {
      cpu_utilisation = aws_cloudwatch_metric_alarm.cpu_utilisation[0].arn
      status_check    = aws_cloudwatch_metric_alarm.status_check[0].arn
      burst_balance   = aws_cloudwatch_metric_alarm.burst_balance[0].arn
    } : {},
    var.monitor_database ? {
      database_connections = aws_cloudwatch_metric_alarm.database_connections[0].arn
      freeable_memory      = aws_cloudwatch_metric_alarm.freeable_memory[0].arn
    } : {},
    var.monitor_cache ? {
      cache_evictions = aws_cloudwatch_metric_alarm.cache_evicted_keys[0].arn
    } : {}
  )
}

output "patch_group_name" {
  description = "The name of the patch group that the fleet of the estate registers against, which is the handle of the compliance scan of the toolkit."
  value       = aws_ssm_patch_group.platform.patch_group
}

output "patch_baseline_ids" {
  description = "The identifiers of the patch baselines of the platform, keyed by the operating system family of each of the baselines."
  value       = { for family, baseline in aws_ssm_patch_baseline.family : family => baseline.baseline_id }
}

output "datadog_board_url" {
  description = "The uniform resource locator of the board of the platform when the DataDog plane is enabled, and null when it is not; the status report of the toolkit prints it next to the name of the environment."
  value       = var.enable_datadog ? datadog_dashboard_json.platform_board[0].url : null
}
