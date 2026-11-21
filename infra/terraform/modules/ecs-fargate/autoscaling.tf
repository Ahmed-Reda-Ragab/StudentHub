# Application Auto Scaling (scenario 57): target tracking on CPU, plus requests per task for
# ROLLING services. Practise with /sre-lab/cpu and k6 (loadtest/k6).

locals {
  request_scaling = var.enable_request_count_scaling && local.ecs_controller && var.deployment_strategy == "ROLLING"
}

resource "aws_appautoscaling_target" "service" {
  service_namespace  = "ecs"
  scalable_dimension = "ecs:service:DesiredCount"
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.app.name}"
  min_capacity       = var.autoscaling_min_capacity
  max_capacity       = var.autoscaling_max_capacity
}

resource "aws_appautoscaling_policy" "cpu" {
  name               = "${local.service_name}-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.service.service_namespace
  scalable_dimension = aws_appautoscaling_target.service.scalable_dimension
  resource_id        = aws_appautoscaling_target.service.resource_id

  target_tracking_scaling_policy_configuration {
    target_value       = var.cpu_target_value
    scale_out_cooldown = 60  # react fast to load
    scale_in_cooldown  = 180 # remove capacity slowly (avoid flapping)

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}

resource "aws_appautoscaling_policy" "requests" {
  count = local.request_scaling ? 1 : 0

  name               = "${local.service_name}-requests"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.service.service_namespace
  scalable_dimension = aws_appautoscaling_target.service.scalable_dimension
  resource_id        = aws_appautoscaling_target.service.resource_id

  target_tracking_scaling_policy_configuration {
    target_value       = var.requests_per_target
    scale_out_cooldown = 60
    scale_in_cooldown  = 180

    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      # app/<alb>/<id>/targetgroup/<tg>/<id>
      resource_label = "${var.alb_arn_suffix}/${lookup(var.target_group_arn_suffixes, "blue", "")}"
    }
  }
}
