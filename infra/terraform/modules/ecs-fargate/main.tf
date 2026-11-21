# ECS on Fargate — cluster, task definition, security group (scenarios 50-57).
# The service, its deployment strategy and autoscaling live in service.tf / autoscaling.tf,
# IAM in iam.tf. Contract: docs/devops/CONVENTIONS.md §2 (container) and §6 (module interface).

data "aws_partition" "current" {}
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region
  account_id = data.aws_caller_identity.current.account_id

  service_name   = "${var.name}-app"
  family         = "${var.name}-app"
  container_name = "app" # CONVENTIONS: every pipeline (imagedefinitions.json, appspec) targets "app"
  log_group_name = "/ecs/${var.name}/app"
  ssm_prefix     = trimsuffix(var.ssm_prefix, "/")

  ecs_controller   = var.deployment_controller == "ECS"
  traffic_shifting = local.ecs_controller && var.deployment_strategy != "ROLLING"

  # <acct>.dkr.ecr.<region>.amazonaws.com/<repo>:<tag> -> pull permission on exactly that repository.
  ecr = try(regex("^([0-9]{12})\\.dkr\\.ecr\\.([a-z0-9-]+)\\.amazonaws\\.com/([^:@]+)", var.image_uri), null)
}

# ---------------------------------------------------------------- cluster

resource "aws_ecs_cluster" "this" {
  name = var.name

  # enhanced = per-task / per-container CPU, memory, network, restarts (scenario 51 dashboards).
  setting {
    name  = "containerInsights"
    value = var.container_insights
  }

  # ECS Exec sessions are logged through the container's awslogs configuration (audit trail).
  configuration {
    execute_command_configuration {
      logging = "DEFAULT"
    }
  }
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  # Also the default for `aws ecs run-task` calls that do not pass a strategy.
  dynamic "default_capacity_provider_strategy" {
    for_each = var.capacity_provider_strategy
    content {
      capacity_provider = default_capacity_provider_strategy.value.capacity_provider
      weight            = default_capacity_provider_strategy.value.weight
      base              = default_capacity_provider_strategy.value.base
    }
  }
}

resource "aws_cloudwatch_log_group" "app" {
  name              = local.log_group_name
  retention_in_days = var.log_retention_days
}

# ---------------------------------------------------------------- network

resource "aws_security_group" "service" {
  name        = "${var.name}-ecs-app"
  description = "ECS tasks of ${local.service_name}: container port from the ALB only"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-ecs-app" }
}

resource "aws_vpc_security_group_ingress_rule" "from_alb" {
  security_group_id            = aws_security_group.service.id
  description                  = "App port from the ALB (traffic + /ready health checks)"
  ip_protocol                  = "tcp"
  from_port                    = var.container_port
  to_port                      = var.container_port
  referenced_security_group_id = var.alb_security_group_id
}

# Tasks call ECR, SSM, CloudWatch Logs, ssmmessages (Exec) over HTTPS and RDS on 3306.
# Without VPC endpoints these are public endpoints, so egress cannot be narrowed to the VPC.
resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.service.id
  description       = "AWS APIs (ECR/SSM/Logs) over HTTPS and RDS"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# ---------------------------------------------------------------- task definition

locals {
  container_definition = {
    name      = local.container_name
    image     = var.image_uri
    essential = true

    portMappings = [{
      name          = "http"
      containerPort = var.container_port
      hostPort      = var.container_port
      protocol      = "tcp"
      appProtocol   = "http"
    }]

    # Sorted so the JSON is stable and plans stay quiet.
    environment = [for k in sort(keys(var.environment)) : { name = k, value = var.environment[k] }]
    secrets     = [for k in sort(keys(var.secrets)) : { name = k, valueFrom = var.secrets[k] }]

    # Liveness only (/up never touches the DB): a DB outage must not make ECS kill every task.
    # Readiness (/ready, DB ping) is the ALB target group health check.
    healthCheck = {
      command     = ["CMD-SHELL", "wget -q -O /dev/null http://127.0.0.1:${var.container_port}/up || exit 1"]
      interval    = 15
      timeout     = 5
      retries     = 3
      startPeriod = 60
    }

    # Fargate honours the image STOPSIGNAL (SIGQUIT): PHP-FPM finishes in-flight requests first.
    stopTimeout = var.stop_timeout

    linuxParameters = {
      initProcessEnabled = var.init_process_enabled
    }

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.app.name
        "awslogs-region"        = local.region
        "awslogs-stream-prefix" = "app" # stream = app/app/<task-id>
        # A CloudWatch hiccup must never block PHP writing to stderr.
        "mode"            = "non-blocking"
        "max-buffer-size" = "25m"
      }
    }
  }
}

resource "aws_ecs_task_definition" "app" {
  family                   = local.family
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(var.cpu)
  memory                   = tostring(var.memory)
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.cpu_architecture
  }

  container_definitions = jsonencode([local.container_definition])
}
