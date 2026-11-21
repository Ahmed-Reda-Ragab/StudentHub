# Observability module — alerting + dashboard on AWS-native metrics (scenarios 42, 46, 70–73).
#
# Alarm tiers (CONVENTIONS §5, availability SLO 99.5% / 30d -> error budget 0.5%):
#   symptom alarms : 5xx ratio > 1% (5m), p95 latency > 300ms, unhealthy targets per TG, RDS
#   SLO burn rate  : multi-window, multi-burn-rate (Google SRE workbook ch.5)
#                      fast  14.4x budget over 1h AND 5m   -> page (2% of the monthly budget in 1h)
#                      slow   6x   budget over 6h AND 30m  -> page (5% of the monthly budget in 6h)
#                    The long window proves it is significant, the short one that it is still happening
#                    (so the alert resets quickly after a fix). Only the composites notify.
#
# SLI here = ALB-level 5xx (target + ELB-generated) / requests. It cannot exclude /sre-lab and
# health routes like the Prometheus SLI does; that difference is a scenario discussion point.

data "aws_region" "current" {}

locals {
  region       = data.aws_region.current.region
  budget_pct   = 100 - var.slo_availability_target # 0.5 (%), exact in decimal
  error_budget = local.budget_pct / 100            # 0.005 as a ratio
  alb          = var.enable_alb_alarms ? 1 : 0
  alarm_topic  = [aws_sns_topic.alerts.arn]

  burn_windows = {
    fast-1h  = { period = 3600, factor = 14.4, tier = "fast" }
    fast-5m  = { period = 300, factor = 14.4, tier = "fast" }
    slow-6h  = { period = 21600, factor = 6, tier = "slow" }
    slow-30m = { period = 1800, factor = 6, tier = "slow" }
  }

  alb_dimensions = { LoadBalancer = var.alb_arn_suffix }
}

# ---------------------------------------------------------------- notification

# No SSE on purpose: CloudWatch alarms cannot publish to a topic encrypted with the
# AWS-managed aws/sns key (it would need a customer-managed key + key policy, 1 USD/month).
resource "aws_sns_topic" "alerts" {
  name = "${var.name}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  count = var.alarm_email == null ? 0 : 1

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# ---------------------------------------------------------------- symptom alarms (ALB)

resource "aws_cloudwatch_metric_alarm" "alb_5xx_ratio" {
  count = local.alb

  alarm_name          = "${var.name}-alb-5xx-ratio"
  alarm_description   = "5xx (target + ALB) > ${var.error_ratio_threshold * 100}% of requests over 5 minutes."
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.error_ratio_threshold
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching" # no traffic = no errors
  alarm_actions       = local.alarm_topic
  ok_actions          = local.alarm_topic

  metric_query {
    id          = "ratio"
    expression  = "(FILL(t5xx, 0) + FILL(e5xx, 0)) / req"
    label       = "5xx ratio"
    return_data = true
  }

  metric_query {
    id = "req"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "RequestCount"
      dimensions  = local.alb_dimensions
      period      = 300
      stat        = "Sum"
    }
  }

  metric_query {
    id = "t5xx"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_Target_5XX_Count"
      dimensions  = local.alb_dimensions
      period      = 300
      stat        = "Sum"
    }
  }

  metric_query {
    id = "e5xx"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_ELB_5XX_Count"
      dimensions  = local.alb_dimensions
      period      = 300
      stat        = "Sum"
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "latency_p95" {
  count = local.alb

  alarm_name          = "${var.name}-alb-latency-p95"
  alarm_description   = "p95 TargetResponseTime > ${var.latency_p95_threshold_seconds}s over 5 minutes (latency SLO)."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  dimensions          = local.alb_dimensions
  extended_statistic  = "p95"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.latency_p95_threshold_seconds
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_topic
  ok_actions          = local.alarm_topic
}

# for_each over a map with static keys (blue/green): works even though the suffixes are unknown at plan.
resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  for_each = var.enable_alb_alarms ? var.target_group_arn_suffixes : {}

  alarm_name          = "${var.name}-${each.key}-unhealthy-hosts"
  alarm_description   = "At least one ${each.key} target failed /ready for 2 minutes (bad release or DB unreachable)."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  dimensions          = { LoadBalancer = var.alb_arn_suffix, TargetGroup = each.value }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching" # an empty (idle color) target group is not an incident
  alarm_actions       = local.alarm_topic
  ok_actions          = local.alarm_topic
}

# ---------------------------------------------------------------- SLO burn rate

# Child alarms carry no actions; only the composites below page.
resource "aws_cloudwatch_metric_alarm" "burn" {
  for_each = var.enable_alb_alarms ? local.burn_windows : {}

  alarm_name          = "${var.name}-slo-burn-${each.key}"
  alarm_description   = "Error ratio over ${each.value.period / 60}m > ${each.value.factor}x the ${var.slo_availability_target}% SLO budget."
  comparison_operator = "GreaterThanThreshold"
  threshold           = each.value.factor * local.error_budget
  evaluation_periods  = 1 # window = period x 1, evaluated every minute
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "ratio"
    expression  = "(FILL(t5xx, 0) + FILL(e5xx, 0)) / req"
    label       = "error ratio ${each.key}"
    return_data = true
  }

  metric_query {
    id = "req"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "RequestCount"
      dimensions  = local.alb_dimensions
      period      = each.value.period
      stat        = "Sum"
    }
  }

  metric_query {
    id = "t5xx"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_Target_5XX_Count"
      dimensions  = local.alb_dimensions
      period      = each.value.period
      stat        = "Sum"
    }
  }

  metric_query {
    id = "e5xx"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_ELB_5XX_Count"
      dimensions  = local.alb_dimensions
      period      = each.value.period
      stat        = "Sum"
    }
  }
}

resource "aws_cloudwatch_composite_alarm" "slo_fast_burn" {
  count = local.alb

  alarm_name        = "${var.name}-slo-fast-burn"
  alarm_description = "PAGE: burning the 30-day error budget 14.4x too fast (1h AND 5m windows). Budget gone in ~2 days."
  alarm_rule = format("ALARM(%q) AND ALARM(%q)",
    aws_cloudwatch_metric_alarm.burn["fast-1h"].alarm_name,
    aws_cloudwatch_metric_alarm.burn["fast-5m"].alarm_name,
  )
  alarm_actions = local.alarm_topic
  ok_actions    = local.alarm_topic
}

resource "aws_cloudwatch_composite_alarm" "slo_slow_burn" {
  count = local.alb

  alarm_name        = "${var.name}-slo-slow-burn"
  alarm_description = "PAGE: burning the 30-day error budget 6x too fast (6h AND 30m windows). Budget gone in ~5 days."
  alarm_rule = format("ALARM(%q) AND ALARM(%q)",
    aws_cloudwatch_metric_alarm.burn["slow-6h"].alarm_name,
    aws_cloudwatch_metric_alarm.burn["slow-30m"].alarm_name,
  )
  alarm_actions = local.alarm_topic
  ok_actions    = local.alarm_topic
}

# ---------------------------------------------------------------- RDS (optional)

resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  count = var.rds_instance_id == null ? 0 : 1

  alarm_name          = "${var.name}-rds-cpu"
  alarm_description   = "RDS CPU > ${var.rds_cpu_threshold}% for 10 minutes (try /sre-lab/db/heavy)."
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  dimensions          = { DBInstanceIdentifier = var.rds_instance_id }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.rds_cpu_threshold
  treat_missing_data  = "missing"
  alarm_actions       = local.alarm_topic
  ok_actions          = local.alarm_topic
}

resource "aws_cloudwatch_metric_alarm" "rds_free_storage" {
  count = var.rds_instance_id == null ? 0 : 1

  alarm_name          = "${var.name}-rds-free-storage"
  alarm_description   = "RDS free storage below ${floor(var.rds_free_storage_threshold_bytes / 1073741824)} GiB."
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  dimensions          = { DBInstanceIdentifier = var.rds_instance_id }
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "LessThanThreshold"
  threshold           = var.rds_free_storage_threshold_bytes
  treat_missing_data  = "missing"
  alarm_actions       = local.alarm_topic
  ok_actions          = local.alarm_topic
}

# ---------------------------------------------------------------- JSON log metric (optional)

# Monolog JsonFormatter writes {"level_name":"ERROR",...} to stderr (CONVENTIONS §2).
# Non-JSON lines (nginx access log) never match a JSON filter, so they are ignored.
resource "aws_cloudwatch_log_metric_filter" "app_errors" {
  count = var.log_group_name == null ? 0 : 1

  name           = "${var.name}-app-error-logs"
  log_group_name = var.log_group_name
  pattern        = "{ ($.level_name = \"ERROR\") || ($.level_name = \"CRITICAL\") || ($.level_name = \"ALERT\") || ($.level_name = \"EMERGENCY\") }"

  metric_transformation {
    name          = "AppErrorLogs"
    namespace     = "StudentApp/${var.name}"
    value         = "1"
    default_value = "0"
  }
}
