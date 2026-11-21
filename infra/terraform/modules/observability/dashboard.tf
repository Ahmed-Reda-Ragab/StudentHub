# One dashboard for every stack: widgets appear only for the inputs that were provided
# (ALB / ASG / ECS / RDS / app logs). Layout: 3 widgets per row, 8x6 each.
#
# Each widget's properties are JSON-encoded individually so the conditional lists stay
# list(string): HCL cannot unify tuples of differently-shaped objects in a conditional.

locals {
  lb   = var.alb_arn_suffix
  asgs = distinct(compact(concat(var.asg_name == null ? [] : [var.asg_name], var.asg_names)))
  ecs  = var.ecs_cluster_name != null && var.ecs_service_name != null

  alb_widgets = var.enable_alb_alarms ? [
    jsonencode({
      title   = "Requests / min"
      stat    = "Sum"
      metrics = [["AWS/ApplicationELB", "RequestCount", "LoadBalancer", local.lb, { label = "requests" }]]
    }),
    jsonencode({
      title = "5xx / min (target vs ALB)"
      stat  = "Sum"
      metrics = [
        ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", local.lb, { label = "target 5xx" }],
        ["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", local.lb, { label = "ALB 5xx (502/503/504)" }],
      ]
    }),
    jsonencode({
      title = "Error ratio % (SLO budget ${local.budget_pct}%)"
      stat  = "Sum"
      metrics = [
        [{ expression = "100 * (FILL(t5xx, 0) + FILL(e5xx, 0)) / req", label = "5xx %", id = "ratio" }],
        ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", local.lb, { id = "req", visible = false }],
        ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", local.lb, { id = "t5xx", visible = false }],
        ["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", local.lb, { id = "e5xx", visible = false }],
      ]
      annotations = { horizontal = [{ label = "error budget", value = local.budget_pct }] }
    }),
    jsonencode({
      title = "Latency p50 / p95 / p99 (s)"
      stat  = "p95"
      metrics = [
        ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", local.lb, { stat = "p50", label = "p50" }],
        ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", local.lb, { stat = "p95", label = "p95" }],
        ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", local.lb, { stat = "p99", label = "p99" }],
      ]
      annotations = { horizontal = [
        { label = "p95 SLO", value = var.latency_p95_threshold_seconds },
        { label = "p99 SLO", value = 1 },
      ] }
    }),
    jsonencode({
      title = "Healthy / unhealthy targets per color"
      stat  = "Maximum"
      metrics = concat(
        [for color, tg in var.target_group_arn_suffixes :
        ["AWS/ApplicationELB", "HealthyHostCount", "TargetGroup", tg, "LoadBalancer", local.lb, { label = "${color} healthy" }]],
        [for color, tg in var.target_group_arn_suffixes :
        ["AWS/ApplicationELB", "UnHealthyHostCount", "TargetGroup", tg, "LoadBalancer", local.lb, { label = "${color} unhealthy" }]],
      )
    }),
    # The traffic split made visible: blue/green switches and canary steps show up here.
    jsonencode({
      title = "Requests per color (traffic split)"
      stat  = "Sum"
      metrics = [for color, tg in var.target_group_arn_suffixes :
      ["AWS/ApplicationELB", "RequestCount", "TargetGroup", tg, "LoadBalancer", local.lb, { label = color }]]
    }),
  ] : []

  asg_widgets = length(local.asgs) > 0 ? [
    jsonencode({
      title   = "ASG CPU % (scaling target 50%)"
      stat    = "Average"
      metrics = [for asg in local.asgs : ["AWS/EC2", "CPUUtilization", "AutoScalingGroupName", asg, { label = asg }]]
    }),
    jsonencode({
      title   = "ASG in-service instances"
      stat    = "Maximum"
      metrics = [for asg in local.asgs : ["AWS/AutoScaling", "GroupInServiceInstances", "AutoScalingGroupName", asg, { label = asg }]]
    }),
  ] : []

  ecs_widgets = local.ecs ? [
    jsonencode({
      title = "ECS service CPU / memory %"
      stat  = "Average"
      metrics = [
        ["AWS/ECS", "CPUUtilization", "ClusterName", var.ecs_cluster_name, "ServiceName", var.ecs_service_name, { label = "CPU" }],
        ["AWS/ECS", "MemoryUtilization", "ClusterName", var.ecs_cluster_name, "ServiceName", var.ecs_service_name, { label = "memory" }],
      ]
    }),
  ] : []

  rds_widgets = var.rds_instance_id != null ? [
    jsonencode({
      title = "RDS CPU % / connections"
      stat  = "Average"
      metrics = [
        ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", var.rds_instance_id, { label = "CPU %" }],
        ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", var.rds_instance_id, { label = "connections", yAxis = "right" }],
      ]
    }),
    jsonencode({
      title = "RDS latency (s) / free storage"
      stat  = "Average"
      metrics = [
        ["AWS/RDS", "ReadLatency", "DBInstanceIdentifier", var.rds_instance_id, { label = "read latency" }],
        ["AWS/RDS", "WriteLatency", "DBInstanceIdentifier", var.rds_instance_id, { label = "write latency" }],
        ["AWS/RDS", "FreeStorageSpace", "DBInstanceIdentifier", var.rds_instance_id, { label = "free storage (bytes)", yAxis = "right" }],
      ]
    }),
  ] : []

  log_widgets = var.log_group_name != null ? [
    jsonencode({
      title   = "App ERROR+ log lines / min"
      stat    = "Sum"
      metrics = [["StudentApp/${var.name}", "AppErrorLogs", { label = "error logs" }]]
    }),
  ] : []

  metric_widgets = concat(local.alb_widgets, local.asg_widgets, local.ecs_widgets, local.rds_widgets, local.log_widgets)

  dashboard_alarm_arns = concat(
    aws_cloudwatch_composite_alarm.slo_fast_burn[*].arn,
    aws_cloudwatch_composite_alarm.slo_slow_burn[*].arn,
    aws_cloudwatch_metric_alarm.alb_5xx_ratio[*].arn,
    aws_cloudwatch_metric_alarm.latency_p95[*].arn,
    [for a in aws_cloudwatch_metric_alarm.unhealthy_hosts : a.arn],
    aws_cloudwatch_metric_alarm.rds_cpu[*].arn,
    aws_cloudwatch_metric_alarm.rds_free_storage[*].arn,
  )

  widgets = concat(
    [for i, props in local.metric_widgets : {
      type       = "metric"
      x          = (i % 3) * 8
      y          = floor(i / 3) * 6
      width      = 8
      height     = 6
      properties = merge({ region = local.region, view = "timeSeries", stacked = false, period = 60 }, jsondecode(props))
    }],
    # Alarm status strip at the bottom: everything that can page, at a glance.
    var.enable_alb_alarms || var.rds_instance_id != null ? [{
      type       = "alarm"
      x          = 0
      y          = ceil(length(local.metric_widgets) / 3) * 6
      width      = 24
      height     = 4
      properties = { title = "Alarms", alarms = local.dashboard_alarm_arns }
    }] : [],
  )
}

resource "aws_cloudwatch_dashboard" "this" {
  count = var.create_dashboard ? 1 : 0

  dashboard_name = var.name
  dashboard_body = jsonencode({ widgets = local.widgets })
}
