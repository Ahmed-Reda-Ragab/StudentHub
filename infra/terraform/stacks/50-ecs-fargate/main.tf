# Stack 50 — ECS on Fargate behind an ALB (scenarios 50-58).
# network (2 AZ, no NAT) -> ALB (ip targets, blue/green TGs) -> ECS service -> RDS MySQL,
# app configuration in SSM (ssm.tf), observability, optional CodeDeploy + FIS.

data "aws_caller_identity" "current" {}

locals {
  name       = "${var.project}-${var.env}" # student-app-lab
  ssm_prefix = "/${var.project}/${var.env}/app"

  image_uri = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com/${var.ecr_repository_name}:${var.image_tag}"

  # Names the ecs-fargate module derives from var.name (used where a module output would create
  # a dependency cycle, e.g. observability <-> deployment alarms).
  cluster_name = local.name
  service_name = "${local.name}-app"

  task_subnet_ids = var.enable_nat ? module.network.private_subnet_ids : module.network.public_subnet_ids

  capacity_provider_strategy = var.use_fargate_spot ? [
    { capacity_provider = "FARGATE", weight = 0, base = 1 }, # on-demand floor
    { capacity_provider = "FARGATE_SPOT", weight = 1, base = 0 },
    ] : [
    { capacity_provider = "FARGATE", weight = 1, base = 0 },
  ]

  app_url = coalesce(var.app_url, "http://${module.alb.dns_name}")

  deployment_alarm_names = var.use_deployment_alarms ? [module.observability.alarm_names["alb_5xx_ratio"]] : []
}

# ---------------------------------------------------------------- network + edge

module "network" {
  source = "../../modules/network"

  name       = local.name
  cidr       = var.vpc_cidr
  az_count   = 2
  enable_nat = var.enable_nat
}

module "alb" {
  source = "../../modules/alb"

  name              = local.name
  vpc_id            = module.network.vpc_id
  subnet_ids        = module.network.public_subnet_ids
  certificate_arn   = var.certificate_arn
  health_check_path = "/ready"
  target_type       = "ip" # awsvpc: every task has its own ENI/IP
  target_port       = 8080
  # CODE_DEPLOY rewrites the listener default action after every deployment, so Terraform
  # must stop owning it (otherwise the next apply flips traffic back). Native strategies
  # use their own listener rule (ecs-fargate module) and leave the default action alone.
  blue_weight                = 100
  green_weight               = 0
  weights_managed_externally = var.deployment_controller == "CODE_DEPLOY"
}

# ---------------------------------------------------------------- database

module "rds" {
  source = "../../modules/rds-mysql"

  name                       = local.name
  vpc_id                     = module.network.vpc_id
  subnet_ids                 = module.network.private_subnet_ids
  allowed_security_group_ids = [module.ecs.security_group_id]
  instance_class             = var.db_instance_class
  ssm_prefix                 = local.ssm_prefix # writes DB_HOST/DB_PORT/DB_DATABASE/DB_USERNAME/DB_PASSWORD
}

# ---------------------------------------------------------------- ECS

module "ecs" {
  source = "../../modules/ecs-fargate"

  name                  = local.name
  vpc_id                = module.network.vpc_id
  subnet_ids            = local.task_subnet_ids
  assign_public_ip      = !var.enable_nat
  alb_security_group_id = module.alb.security_group_id

  target_group_arns         = module.alb.target_group_arns
  target_group_arn_suffixes = module.alb.target_group_arn_suffixes
  listener_arn              = module.alb.listener_arn
  alb_arn_suffix            = module.alb.alb_arn_suffix

  image_uri  = local.image_uri
  ssm_prefix = local.ssm_prefix
  # Resource ARNs (not strings) => the task definition is registered only after every parameter exists.
  secrets = merge(
    module.rds.ssm_parameter_arns,
    { for k, p in aws_ssm_parameter.app : k => p.arn },
    { for k, p in aws_ssm_parameter.app_secret : k => p.arn },
  )
  environment = merge(
    {
      APP_ENV          = "production"
      APP_DEBUG        = "false"
      DEPLOY_COLOR     = "stable"
      LOG_LEVEL        = "info"
      QUEUE_CONNECTION = "sync"
    },
    var.app_environment,
  )

  cpu                        = var.task_cpu
  memory                     = var.task_memory
  desired_count              = var.desired_count
  capacity_provider_strategy = local.capacity_provider_strategy
  container_insights         = var.container_insights
  autoscaling_min_capacity   = var.autoscaling_min
  autoscaling_max_capacity   = var.autoscaling_max

  deployment_controller  = var.deployment_controller
  deployment_strategy    = var.deployment_strategy
  bake_time_in_minutes   = var.bake_time_in_minutes
  canary_percent         = var.canary_percent
  linear_step_percent    = var.linear_step_percent
  deployment_alarm_names = var.deployment_controller == "ECS" ? local.deployment_alarm_names : []
}

# Scenario 54: CodeDeploy owns blue/green for CODE_DEPLOY services.
module "codedeploy" {
  source = "../../modules/codedeploy"
  count  = var.deployment_controller == "CODE_DEPLOY" ? 1 : 0

  name                             = "${local.name}-ecs"
  compute_platform                 = "ECS"
  deployment_config_name           = var.codedeploy_deployment_config_name
  ecs_cluster_name                 = module.ecs.cluster_name
  ecs_service_name                 = module.ecs.service_name
  target_group_names               = module.alb.target_group_names
  prod_listener_arns               = [module.alb.listener_arn]
  alarm_names                      = local.deployment_alarm_names
  termination_wait_time_in_minutes = var.bake_time_in_minutes
}

# ---------------------------------------------------------------- observability + chaos

module "observability" {
  source = "../../modules/observability"

  name                      = local.name
  alarm_email               = var.alarm_email
  alb_arn_suffix            = module.alb.alb_arn_suffix
  target_group_arn_suffixes = module.alb.target_group_arn_suffixes
  ecs_cluster_name          = local.cluster_name # strings, not module.ecs outputs: the service
  ecs_service_name          = local.service_name # consumes this module's alarms (no cycle)
  rds_instance_id           = module.rds.identifier
  log_group_name            = module.ecs.log_group_name
}

module "fis" {
  source = "../../modules/fis"
  count  = var.enable_fis ? 1 : 0

  name             = local.name
  ecs_cluster_name = module.ecs.cluster_name
  ecs_service_name = module.ecs.service_name
  # Guardrail: abort the experiment as soon as users see a 5xx ratio above the alarm threshold.
  stop_condition_alarm_arn = module.observability.alarm_arns["alb_5xx_ratio"]
}
