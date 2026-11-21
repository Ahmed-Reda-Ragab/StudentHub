# ECS service + deployment strategy (scenarios 53-55).
#
#   deployment_controller = "ECS"
#     ROLLING     replace tasks in place, circuit breaker rolls back a release that cannot start   (53)
#     BLUE_GREEN  ECS-native (July 2025): green tasks on the green TG, test traffic, 100% switch,  (55)
#                 bake time, then blue is drained — no CodeDeploy involved
#     LINEAR      ECS-native (Oct 2025): shift linear_step_percent every N minutes                 (55)
#     CANARY      ECS-native (Oct 2025): canary_percent first, then the rest                       (55)
#   deployment_controller = "CODE_DEPLOY"
#     CodeDeploy owns the traffic shift (modules/codedeploy, appspec.yaml)                         (54)

# ECS native traffic shifting works on a LISTENER RULE (not the listener default action).
# Both target groups sit in one weighted forward action; ECS rewrites the weights during a deploy.
resource "aws_lb_listener_rule" "production" {
  count = local.traffic_shifting ? 1 : 0

  listener_arn = var.listener_arn
  priority     = var.production_listener_rule_priority

  action {
    type = "forward"
    forward {
      target_group {
        arn    = var.target_group_arns["blue"]
        weight = 100
      }
      target_group {
        arn    = var.target_group_arns["green"]
        weight = 0
      }
    }
  }

  condition {
    path_pattern {
      values = ["/*"]
    }
  }

  tags = { Name = "${var.name}-ecs-production" }

  # ECS owns the weights after creation; Terraform would otherwise undo every traffic shift.
  lifecycle {
    ignore_changes = [action]
  }
}

# Test traffic: `curl -H 'X-Lab-Target: green' http://<alb>/ready` reaches the new revision
# during the TEST_TRAFFIC_SHIFT stage, before any real user does.
resource "aws_lb_listener_rule" "test" {
  count = local.traffic_shifting && var.enable_test_listener_rule ? 1 : 0

  listener_arn = var.listener_arn
  priority     = var.test_listener_rule_priority

  action {
    type = "forward"
    forward {
      target_group {
        arn    = var.target_group_arns["blue"]
        weight = 100
      }
      target_group {
        arn    = var.target_group_arns["green"]
        weight = 0
      }
    }
  }

  condition {
    http_header {
      http_header_name = "X-Lab-Target"
      values           = ["green"]
    }
  }

  tags = { Name = "${var.name}-ecs-test" }

  lifecycle {
    ignore_changes = [action]
  }
}

resource "aws_ecs_service" "app" {
  name             = local.service_name
  cluster          = aws_ecs_cluster.this.arn
  task_definition  = aws_ecs_task_definition.app.arn
  desired_count    = var.desired_count
  platform_version = "LATEST"

  enable_execute_command            = var.enable_execute_command
  enable_ecs_managed_tags           = true
  propagate_tags                    = "SERVICE"
  health_check_grace_period_seconds = var.health_check_grace_period_seconds
  # Re-spread tasks after an AZ event; not supported with the CODE_DEPLOY controller.
  availability_zone_rebalancing = local.ecs_controller ? "ENABLED" : "DISABLED"

  deployment_controller {
    type = var.deployment_controller
  }

  dynamic "capacity_provider_strategy" {
    for_each = var.capacity_provider_strategy
    content {
      capacity_provider = capacity_provider_strategy.value.capacity_provider
      weight            = capacity_provider_strategy.value.weight
      base              = capacity_provider_strategy.value.base
    }
  }

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [aws_security_group.service.id]
    assign_public_ip = var.assign_public_ip
  }

  load_balancer {
    target_group_arn = var.target_group_arns["blue"]
    container_name   = local.container_name
    container_port   = var.container_port

    dynamic "advanced_configuration" {
      for_each = local.traffic_shifting ? [1] : []
      content {
        alternate_target_group_arn = var.target_group_arns["green"]
        production_listener_rule   = aws_lb_listener_rule.production[0].arn
        test_listener_rule         = var.enable_test_listener_rule ? aws_lb_listener_rule.test[0].arn : null
        role_arn                   = aws_iam_role.infrastructure[0].arn
      }
    }
  }

  # ---- ECS controller only (CodeDeploy has its own rollback + traffic settings)

  # Rolling: start new tasks before stopping old ones, never drop below desired capacity.
  deployment_minimum_healthy_percent = local.ecs_controller ? 100 : null
  deployment_maximum_percent         = local.ecs_controller ? 200 : null

  # SRE_FAULT_BOOT_FAIL=true (scenario 53) -> tasks never become healthy -> automatic rollback.
  dynamic "deployment_circuit_breaker" {
    for_each = local.ecs_controller ? [1] : []
    content {
      enable   = true
      rollback = true
    }
  }

  # Release is healthy but bad (SRE_FAULT_ERROR_RATE): alarms catch what health checks cannot.
  dynamic "alarms" {
    for_each = local.ecs_controller && length(var.deployment_alarm_names) > 0 ? [1] : []
    content {
      enable      = true
      rollback    = true
      alarm_names = var.deployment_alarm_names
    }
  }

  dynamic "deployment_configuration" {
    for_each = local.ecs_controller ? [1] : []
    content {
      strategy             = var.deployment_strategy
      bake_time_in_minutes = local.traffic_shifting ? var.bake_time_in_minutes : null

      dynamic "canary_configuration" {
        for_each = var.deployment_strategy == "CANARY" ? [1] : []
        content {
          canary_percent              = var.canary_percent
          canary_bake_time_in_minutes = var.canary_bake_time_in_minutes
        }
      }

      dynamic "linear_configuration" {
        for_each = var.deployment_strategy == "LINEAR" ? [1] : []
        content {
          step_percent              = var.linear_step_percent
          step_bake_time_in_minutes = var.linear_step_bake_time_in_minutes
        }
      }
    }
  }

  depends_on = [
    aws_ecs_cluster_capacity_providers.this, # the strategy references FARGATE_SPOT
    aws_iam_role_policy.execution,           # first tasks need the pull/secret permissions
    aws_iam_role_policy_attachment.infrastructure,
  ]

  lifecycle {
    ignore_changes = [
      # CI owns the image: every pipeline (GitHub Actions, CodePipeline, CodeDeploy) registers a new
      # revision. Without this, the next `terraform apply` would roll production back to the
      # revision Terraform created with var.image_uri.
      task_definition,
      # Application Auto Scaling owns the running count (2..6); Terraform must not reset it to 2.
      desired_count,
      # Native blue/green and CodeDeploy swap the primary target group (blue <-> green) after every
      # deployment. Consequence: switching ROLLING <-> BLUE_GREEN/LINEAR/CANARY or ECS <-> CODE_DEPLOY
      # on an EXISTING service needs `terraform apply -replace=module.ecs.aws_ecs_service.app`.
      load_balancer,
    ]
  }
}
