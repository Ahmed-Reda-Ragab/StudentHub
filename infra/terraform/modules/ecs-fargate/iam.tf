# Three roles, each with the minimum it needs:
#   execution role  — the ECS agent: pull the image, write logs, resolve `secrets` from SSM
#   task role       — the app itself: only the ssmmessages channels for ECS Exec
#   infrastructure  — ECS native blue/green/linear/canary: rewrite the ALB listener rule weights

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    # Confused-deputy guard: only ECS acting for THIS account may assume the role.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

# ---------------------------------------------------------------- execution role

resource "aws_iam_role" "execution" {
  name               = "${var.name}-ecs-execution"
  description        = "ECS agent for ${local.family}: ECR pull, logs, SSM secrets"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

data "aws_iam_policy_document" "execution" {
  statement {
    sid       = "EcrAuthToken"
    actions   = ["ecr:GetAuthorizationToken"] # account-level API, cannot be scoped
    resources = ["*"]
  }

  dynamic "statement" {
    for_each = local.ecr == null ? [] : [local.ecr]
    content {
      sid = "EcrPullAppRepository"
      actions = [
        "ecr:BatchCheckLayerAvailability",
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer",
      ]
      resources = ["arn:${local.partition}:ecr:${statement.value[1]}:${statement.value[0]}:repository/${statement.value[2]}"]
    }
  }

  statement {
    sid       = "WriteAppLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.app.arn}:*"]
  }

  # Only the app's own subtree (/student-app/<env>/app/*), never /student-app/* or other envs.
  statement {
    sid       = "ReadAppSecrets"
    actions   = ["ssm:GetParameters"]
    resources = ["arn:${local.partition}:ssm:${local.region}:${local.account_id}:parameter${local.ssm_prefix}/*"]
  }

  # SecureString decryption, but only when the call comes through SSM in this region.
  statement {
    sid       = "DecryptSecureStringViaSsm"
    actions   = ["kms:Decrypt"]
    resources = length(var.kms_key_arns) > 0 ? var.kms_key_arns : ["arn:${local.partition}:kms:${local.region}:${local.account_id}:key/*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${local.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "execution" {
  name   = "ecs-execution"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution.json
}

# ---------------------------------------------------------------- task role

resource "aws_iam_role" "task" {
  name               = "${var.name}-ecs-task"
  description        = "Application role of ${local.family} (ECS Exec channels only)"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

data "aws_iam_policy_document" "task_exec" {
  statement {
    sid = "EcsExecSessionManagerChannels"
    actions = [
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"] # ssmmessages has no resource-level permissions
  }

  # executeCommandConfiguration logging = DEFAULT ships each Exec session's output to the
  # container's awslogs group — written by the agent with the TASK role (audit trail, scenario 52).
  statement {
    sid       = "EcsExecSessionLogs"
    actions   = ["logs:CreateLogStream", "logs:DescribeLogStreams", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.app.arn}:*"]
  }

  statement {
    sid       = "EcsExecDescribeLogGroups"
    actions   = ["logs:DescribeLogGroups"]
    resources = ["*"] # not resource-scopable
  }
}

resource "aws_iam_role_policy" "task_exec" {
  count = var.enable_execute_command ? 1 : 0

  name   = "ecs-exec"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task_exec.json
}

# ---------------------------------------------------------------- infrastructure role (native B/G)

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    sid     = "AllowAccessToECSForInfrastructureManagement"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "infrastructure" {
  count = local.traffic_shifting ? 1 : 0

  name               = "${var.name}-ecs-infrastructure"
  description        = "Lets ECS shift ALB listener-rule weights for ${local.service_name} deployments"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy_attachment" "infrastructure" {
  count = local.traffic_shifting ? 1 : 0

  role       = aws_iam_role.infrastructure[0].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonECSInfrastructureRolePolicyForLoadBalancers"
}
