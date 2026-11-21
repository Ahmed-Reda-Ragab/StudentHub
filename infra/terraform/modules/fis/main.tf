# AWS Fault Injection Service experiment templates (scenario 75). Creating a template costs
# nothing; you pay per action-minute only when you START an experiment:
#   aws fis start-experiment --experiment-template-id <id>
#
#   ecs_stop_tasks      stop X% of the service's tasks      -> ECS replaces them, ALB keeps serving
#   asg_terminate_one   terminate 1 instance of an ASG      -> ASG self-heals, SLO holds?
#   cpu_stress          AWSFIS-Run-CPU-Stress via SSM       -> CPU target tracking scales out

data "aws_partition" "current" {}
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region
  account_id = data.aws_caller_identity.current.account_id

  ecs_enabled = var.ecs_cluster_name != null && var.ecs_service_name != null
  asg_enabled = var.asg_name != null
  cpu_enabled = length(var.cpu_stress_target_tags) > 0

  stop_conditions = var.stop_condition_alarm_arn == null ? [
    { source = "none", value = null }
    ] : [
    { source = "aws:cloudwatch:alarm", value = var.stop_condition_alarm_arn }
  ]

  cpu_stress_document_arn = "arn:${local.partition}:ssm:${local.region}::document/AWSFIS-Run-CPU-Stress"
}

resource "aws_cloudwatch_log_group" "fis" {
  name              = "/aws/fis/${var.name}"
  retention_in_days = var.log_retention_days
}

# ---------------------------------------------------------------- IAM

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["fis.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "fis" {
  name               = "${var.name}-fis"
  description        = "AWS FIS experiments for ${var.name}"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

data "aws_iam_policy_document" "fis" {
  # Experiment logs to CloudWatch (FIS creates a log delivery on the group).
  statement {
    sid = "ExperimentLogs"
    actions = [
      "logs:CreateLogDelivery",
      "logs:PutResourcePolicy",
      "logs:DescribeResourcePolicies",
      "logs:DescribeLogGroups",
    ]
    resources = ["*"]
  }

  dynamic "statement" {
    for_each = local.ecs_enabled ? [1] : []
    content {
      sid       = "EcsDiscoverTasks"
      actions   = ["ecs:ListTasks", "ecs:DescribeTasks"]
      resources = ["*"] # List/Describe are filtered by the cluster parameter at runtime
    }
  }

  dynamic "statement" {
    for_each = local.ecs_enabled ? [1] : []
    content {
      sid       = "EcsStopTasksOfThisClusterOnly"
      actions   = ["ecs:StopTask"]
      resources = ["arn:${local.partition}:ecs:${local.region}:${local.account_id}:task/${var.ecs_cluster_name}/*"]
    }
  }

  dynamic "statement" {
    for_each = local.asg_enabled || local.cpu_enabled ? [1] : []
    content {
      sid       = "Ec2Discover"
      actions   = ["ec2:DescribeInstances"]
      resources = ["*"]
    }
  }

  # Only instances that belong to the named ASG can be terminated.
  dynamic "statement" {
    for_each = local.asg_enabled ? [1] : []
    content {
      sid       = "TerminateInstancesOfThisAsgOnly"
      actions   = ["ec2:TerminateInstances"]
      resources = ["arn:${local.partition}:ec2:${local.region}:${local.account_id}:instance/*"]

      condition {
        test     = "StringEquals"
        variable = "aws:ResourceTag/aws:autoscaling:groupName"
        values   = [var.asg_name]
      }
    }
  }

  dynamic "statement" {
    for_each = local.cpu_enabled ? [1] : []
    content {
      sid     = "RunCpuStressDocument"
      actions = ["ssm:SendCommand"]
      resources = [
        local.cpu_stress_document_arn,
        "arn:${local.partition}:ec2:${local.region}:${local.account_id}:instance/*",
      ]
    }
  }

  dynamic "statement" {
    for_each = local.cpu_enabled ? [1] : []
    content {
      sid       = "TrackCpuStressCommand"
      actions   = ["ssm:ListCommands", "ssm:CancelCommand"]
      resources = ["*"]
    }
  }
}

resource "aws_iam_role_policy" "fis" {
  name   = "fis-experiments"
  role   = aws_iam_role.fis.id
  policy = data.aws_iam_policy_document.fis.json
}

# ---------------------------------------------------------------- experiments

resource "aws_fis_experiment_template" "ecs_stop_tasks" {
  count = local.ecs_enabled ? 1 : 0

  description = "Stop ${var.ecs_stop_task_percent}% of ${var.ecs_service_name} tasks (ECS must replace them, users must not notice)"
  role_arn    = aws_iam_role.fis.arn

  dynamic "stop_condition" {
    for_each = local.stop_conditions
    content {
      source = stop_condition.value.source
      value  = stop_condition.value.value
    }
  }

  action {
    name      = "stop-tasks"
    action_id = "aws:ecs:stop-task"

    target {
      key   = "Tasks"
      value = "service-tasks"
    }
  }

  target {
    name           = "service-tasks"
    resource_type  = "aws:ecs:task"
    selection_mode = "PERCENT(${var.ecs_stop_task_percent})"
    parameters = {
      cluster = var.ecs_cluster_name
      service = var.ecs_service_name
    }
  }

  log_configuration {
    log_schema_version = 2
    cloudwatch_logs_configuration {
      log_group_arn = "${aws_cloudwatch_log_group.fis.arn}:*"
    }
  }

  tags = { Name = "${var.name}-ecs-stop-tasks" }

  depends_on = [aws_iam_role_policy.fis]
}

resource "aws_fis_experiment_template" "asg_terminate_one" {
  count = local.asg_enabled ? 1 : 0

  description = "Terminate one running instance of ${var.asg_name} (ASG self-healing + ALB health checks)"
  role_arn    = aws_iam_role.fis.arn

  dynamic "stop_condition" {
    for_each = local.stop_conditions
    content {
      source = stop_condition.value.source
      value  = stop_condition.value.value
    }
  }

  action {
    name      = "terminate-one"
    action_id = "aws:ec2:terminate-instances"

    target {
      key   = "Instances"
      value = "asg-instance"
    }
  }

  target {
    name           = "asg-instance"
    resource_type  = "aws:ec2:instance"
    selection_mode = "COUNT(1)"

    resource_tag {
      key   = "aws:autoscaling:groupName"
      value = var.asg_name
    }

    filter {
      path   = "State.Name"
      values = ["running"]
    }
  }

  log_configuration {
    log_schema_version = 2
    cloudwatch_logs_configuration {
      log_group_arn = "${aws_cloudwatch_log_group.fis.arn}:*"
    }
  }

  tags = { Name = "${var.name}-asg-terminate-one" }

  depends_on = [aws_iam_role_policy.fis]
}

resource "aws_fis_experiment_template" "cpu_stress" {
  count = local.cpu_enabled ? 1 : 0

  description = "CPU stress (AWSFIS-Run-CPU-Stress) for ${var.cpu_stress_duration_seconds}s on ${var.cpu_stress_instance_percent}% of the tagged instances"
  role_arn    = aws_iam_role.fis.arn

  dynamic "stop_condition" {
    for_each = local.stop_conditions
    content {
      source = stop_condition.value.source
      value  = stop_condition.value.value
    }
  }

  action {
    name      = "cpu-stress"
    action_id = "aws:ssm:send-command"

    parameter {
      key   = "documentArn"
      value = local.cpu_stress_document_arn
    }

    parameter {
      key = "documentParameters"
      value = jsonencode({
        DurationSeconds     = tostring(var.cpu_stress_duration_seconds)
        InstallDependencies = "True" # installs stress-ng on first use
      })
    }

    # FIS-side timeout: document duration + time to install stress-ng.
    parameter {
      key   = "duration"
      value = "PT${ceil(var.cpu_stress_duration_seconds / 60) + 3}M"
    }

    target {
      key   = "Instances"
      value = "stress-targets"
    }
  }

  target {
    name           = "stress-targets"
    resource_type  = "aws:ec2:instance"
    selection_mode = "PERCENT(${var.cpu_stress_instance_percent})"

    dynamic "resource_tag" {
      for_each = var.cpu_stress_target_tags
      content {
        key   = resource_tag.key
        value = resource_tag.value
      }
    }

    filter {
      path   = "State.Name"
      values = ["running"]
    }
  }

  log_configuration {
    log_schema_version = 2
    cloudwatch_logs_configuration {
      log_group_arn = "${aws_cloudwatch_log_group.fis.arn}:*"
    }
  }

  tags = { Name = "${var.name}-cpu-stress" }

  depends_on = [aws_iam_role_policy.fis]
}
