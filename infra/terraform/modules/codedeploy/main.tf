# CodeDeploy application + deployment group.
#   compute_platform = "ECS"    — blue/green for an ECS service with the CODE_DEPLOY controller (scenario 54):
#                                 both target groups, production listener, optional test listener.
#   compute_platform = "Server" — EC2 / ASG with the CodeDeploy agent (scenario 37): in-place or blue/green,
#                                 ASG or tag targets, optional ALB traffic control.

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

locals {
  is_ecs    = var.compute_platform == "ECS"
  partition = data.aws_partition.current.partition

  deployment_config_name = coalesce(
    var.deployment_config_name,
    local.is_ecs ? "CodeDeployDefault.ECSAllAtOnce" : "CodeDeployDefault.OneAtATime",
  )

  # STOP_ON_ALARM without alarms is meaningless; keep the event list honest.
  rollback_events = length(var.alarm_names) > 0 ? var.auto_rollback_events : [
    for e in var.auto_rollback_events : e if e != "DEPLOYMENT_STOP_ON_ALARM"
  ]

  server_traffic_control = length(var.server_target_group_names) > 0
}

resource "aws_codedeploy_app" "this" {
  name             = var.name
  compute_platform = var.compute_platform
}

# ---------------------------------------------------------------- service role

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["codedeploy.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = "${var.name}-codedeploy"
  description        = "CodeDeploy service role for ${var.name}"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

# AWS-managed, scoped by AWS to what CodeDeploy needs for the platform:
#   ECS    -> ECS task sets, ELB listener/rules, iam:PassRole to ecs-tasks, CloudWatch alarms
#   Server -> EC2/ASG describe + lifecycle hooks, ELB (de)registration, alarms
resource "aws_iam_role_policy_attachment" "managed" {
  role = aws_iam_role.this.name
  policy_arn = local.is_ecs ? (
    "arn:${local.partition}:iam::aws:policy/AWSCodeDeployRoleForECS"
    ) : (
    "arn:${local.partition}:iam::aws:policy/service-role/AWSCodeDeployRole"
  )
}

# Server blue/green copies an ASG built from a launch template: CodeDeploy launches the
# instances itself, so it needs RunInstances/CreateTags and PassRole on the instance role.
data "aws_iam_policy_document" "server_blue_green" {
  statement {
    sid       = "LaunchReplacementFleet"
    actions   = ["ec2:RunInstances", "ec2:CreateTags"]
    resources = ["*"]
  }

  statement {
    sid       = "PassInstanceRole"
    actions   = ["iam:PassRole"]
    resources = var.instance_role_arns

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "server_blue_green" {
  count = !local.is_ecs && var.deployment_type == "BLUE_GREEN" && length(var.instance_role_arns) > 0 ? 1 : 0

  name   = "server-blue-green"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.server_blue_green.json
}

# ---------------------------------------------------------------- ECS deployment group

resource "aws_codedeploy_deployment_group" "ecs" {
  count = local.is_ecs ? 1 : 0

  app_name               = aws_codedeploy_app.this.name
  deployment_group_name  = var.name
  service_role_arn       = aws_iam_role.this.arn
  deployment_config_name = local.deployment_config_name

  auto_rollback_configuration {
    enabled = length(local.rollback_events) > 0
    events  = local.rollback_events
  }

  dynamic "alarm_configuration" {
    for_each = length(var.alarm_names) > 0 ? [1] : []
    content {
      enabled = true
      alarms  = var.alarm_names
    }
  }

  blue_green_deployment_config {
    deployment_ready_option {
      # CONTINUE = shift as soon as green passes health checks; STOP = wait for a human
      # (`aws deploy continue-deployment`) after testing green on the test listener.
      action_on_timeout    = var.ready_wait_time_in_minutes == 0 ? "CONTINUE_DEPLOYMENT" : "STOP_DEPLOYMENT"
      wait_time_in_minutes = var.ready_wait_time_in_minutes == 0 ? null : var.ready_wait_time_in_minutes
    }

    terminate_blue_instances_on_deployment_success {
      action                           = "TERMINATE"
      termination_wait_time_in_minutes = var.termination_wait_time_in_minutes
    }
  }

  deployment_style {
    deployment_option = "WITH_TRAFFIC_CONTROL"
    deployment_type   = "BLUE_GREEN"
  }

  ecs_service {
    cluster_name = var.ecs_cluster_name
    service_name = var.ecs_service_name
  }

  load_balancer_info {
    target_group_pair_info {
      prod_traffic_route {
        listener_arns = var.prod_listener_arns
      }

      dynamic "test_traffic_route" {
        for_each = length(var.test_listener_arns) > 0 ? [1] : []
        content {
          listener_arns = var.test_listener_arns
        }
      }

      # Order matters: the first group is the one the service starts on (blue).
      target_group {
        name = var.target_group_names["blue"]
      }

      target_group {
        name = var.target_group_names["green"]
      }
    }
  }

  depends_on = [aws_iam_role_policy_attachment.managed]
}

# ---------------------------------------------------------------- Server deployment group

resource "aws_codedeploy_deployment_group" "server" {
  count = local.is_ecs ? 0 : 1

  app_name               = aws_codedeploy_app.this.name
  deployment_group_name  = var.name
  service_role_arn       = aws_iam_role.this.arn
  deployment_config_name = local.deployment_config_name
  autoscaling_groups     = var.autoscaling_group_names

  # One tag set per tag => all tags must match (sets are ANDed, filters inside a set ORed).
  dynamic "ec2_tag_set" {
    for_each = var.ec2_tag_filters
    content {
      ec2_tag_filter {
        key   = ec2_tag_set.key
        type  = "KEY_AND_VALUE"
        value = ec2_tag_set.value
      }
    }
  }

  deployment_style {
    deployment_option = local.server_traffic_control ? "WITH_TRAFFIC_CONTROL" : "WITHOUT_TRAFFIC_CONTROL"
    deployment_type   = var.deployment_type
  }

  # In-place + ALB: each instance is deregistered (BlockTraffic), updated, validated
  # (ValidateService -> /ready) and registered again (AllowTraffic).
  dynamic "load_balancer_info" {
    for_each = local.server_traffic_control ? [1] : []
    content {
      dynamic "target_group_info" {
        for_each = var.server_target_group_names
        content {
          name = target_group_info.value
        }
      }
    }
  }

  dynamic "blue_green_deployment_config" {
    for_each = var.deployment_type == "BLUE_GREEN" ? [1] : []
    content {
      deployment_ready_option {
        action_on_timeout    = var.ready_wait_time_in_minutes == 0 ? "CONTINUE_DEPLOYMENT" : "STOP_DEPLOYMENT"
        wait_time_in_minutes = var.ready_wait_time_in_minutes == 0 ? null : var.ready_wait_time_in_minutes
      }

      green_fleet_provisioning_option {
        action = "COPY_AUTO_SCALING_GROUP"
      }

      terminate_blue_instances_on_deployment_success {
        action                           = "TERMINATE"
        termination_wait_time_in_minutes = var.termination_wait_time_in_minutes
      }
    }
  }

  auto_rollback_configuration {
    enabled = length(local.rollback_events) > 0
    events  = local.rollback_events
  }

  dynamic "alarm_configuration" {
    for_each = length(var.alarm_names) > 0 ? [1] : []
    content {
      enabled = true
      alarms  = var.alarm_names
    }
  }

  depends_on = [aws_iam_role_policy_attachment.managed]
}
