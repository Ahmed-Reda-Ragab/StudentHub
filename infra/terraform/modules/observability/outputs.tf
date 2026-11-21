output "sns_topic_arn" {
  description = "Alerts SNS topic ARN (subscribe Slack/Chatbot/PagerDuty here)."
  value       = aws_sns_topic.alerts.arn
}

output "dashboard_name" {
  description = "CloudWatch dashboard name (null when create_dashboard = false)."
  value       = var.create_dashboard ? aws_cloudwatch_dashboard.this[0].dashboard_name : null
}

output "dashboard_url" {
  description = "Console URL of the dashboard."
  value       = var.create_dashboard ? "https://${local.region}.console.aws.amazon.com/cloudwatch/home?region=${local.region}#dashboards/dashboard/${aws_cloudwatch_dashboard.this[0].dashboard_name}" : null
}

output "alarm_arns" {
  description = "Map of logical alarm name -> ARN for every alarm this module created."
  value = merge(
    { for a in aws_cloudwatch_metric_alarm.alb_5xx_ratio : "alb_5xx_ratio" => a.arn },
    { for a in aws_cloudwatch_metric_alarm.latency_p95 : "latency_p95" => a.arn },
    { for color, a in aws_cloudwatch_metric_alarm.unhealthy_hosts : "unhealthy_hosts_${color}" => a.arn },
    { for w, a in aws_cloudwatch_metric_alarm.burn : "slo_burn_${w}" => a.arn },
    { for a in aws_cloudwatch_composite_alarm.slo_fast_burn : "slo_fast_burn" => a.arn },
    { for a in aws_cloudwatch_composite_alarm.slo_slow_burn : "slo_slow_burn" => a.arn },
    { for a in aws_cloudwatch_metric_alarm.rds_cpu : "rds_cpu" => a.arn },
    { for a in aws_cloudwatch_metric_alarm.rds_free_storage : "rds_free_storage" => a.arn },
  )
}

output "alarm_names" {
  description = "Map of logical alarm name -> alarm name (same keys as alarm_arns; feed into instance refresh / ECS deployment alarms)."
  value = merge(
    { for a in aws_cloudwatch_metric_alarm.alb_5xx_ratio : "alb_5xx_ratio" => a.alarm_name },
    { for a in aws_cloudwatch_metric_alarm.latency_p95 : "latency_p95" => a.alarm_name },
    { for color, a in aws_cloudwatch_metric_alarm.unhealthy_hosts : "unhealthy_hosts_${color}" => a.alarm_name },
    { for w, a in aws_cloudwatch_metric_alarm.burn : "slo_burn_${w}" => a.alarm_name },
    { for a in aws_cloudwatch_composite_alarm.slo_fast_burn : "slo_fast_burn" => a.alarm_name },
    { for a in aws_cloudwatch_composite_alarm.slo_slow_burn : "slo_slow_burn" => a.alarm_name },
    { for a in aws_cloudwatch_metric_alarm.rds_cpu : "rds_cpu" => a.alarm_name },
    { for a in aws_cloudwatch_metric_alarm.rds_free_storage : "rds_free_storage" => a.alarm_name },
  )
}
