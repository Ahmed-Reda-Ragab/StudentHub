# Stack 40 — immutable EC2 fleet behind an ALB (scenarios 40–49).
#
#   internet ─► ALB :80/:443 ── weighted forward ──► TG blue  ◄── ASG blue  (deploy/blue/IMAGE_URI)
#                  (/metrics -> 404)             └─► TG green ◄── ASG green (deploy/green/IMAGE_URI, optional)
#                                                                  │
#                                     RDS MySQL (private) ◄────────┤
#                                     ElastiCache (optional) ◄─────┘
#
# Release = CI puts a new IMAGE_URI in SSM, then starts an instance refresh (rolling, scenario 44)
# or refreshes the idle color and shifts listener weights (blue/green 45, canary 46).

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  name       = "${var.project}-${var.env}" # student-app-lab
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region

  ssm_root = "/${var.project}/${var.env}"
  ssm_app  = "${local.ssm_root}/app"

  ecr_repository_url = "${local.account_id}.dkr.ecr.${local.region}.amazonaws.com/${var.ecr_repository_name}"
  image_uri          = var.image_uri != null ? var.image_uri : "${local.ecr_repository_url}:${var.image_tag}"

  # Known at plan time (unlike the certificate ARN), so it can drive count.
  https_enabled = var.domain_name != null
  app_url       = local.https_enabled ? "https://${var.domain_name}" : "http://${module.alb.dns_name}"

  app_subnet_ids = var.private_instances ? module.network.private_subnet_ids : module.network.public_subnet_ids

  # Names are computed here (not read from the ASG modules) so observability can use them
  # while the ASGs consume observability's alarm names — no dependency cycle.
  asg_names = merge(
    { blue = "${local.name}-blue" },
    var.green_enabled ? { green = "${local.name}-green" } : {},
  )
}

check "image_is_set" {
  assert {
    condition     = var.image_uri != null || var.image_tag != "unset"
    error_message = "image_tag is still \"unset\": instances will fail to pull and the ASG will keep replacing them. Pass -var image_tag=<sha pushed by CI>."
  }
}

# ---------------------------------------------------------------- network

module "network" {
  source = "../../modules/network"

  name       = local.name
  cidr       = var.vpc_cidr
  az_count   = 2 # ALB and the RDS subnet group both need two AZs
  enable_nat = var.private_instances
  single_nat = var.single_nat
}

# ---------------------------------------------------------------- load balancer

module "alb" {
  source = "../../modules/alb"

  name       = local.name
  vpc_id     = module.network.vpc_id
  subnet_ids = module.network.public_subnet_ids

  target_type = "instance"
  target_port = 80 # host port: the ASG user data runs `docker run -p 80:8080`

  https_enabled   = local.https_enabled
  certificate_arn = local.https_enabled ? aws_acm_certificate_validation.this[0].certificate_arn : null

  blue_weight         = var.blue_weight
  green_weight        = var.green_weight
  stickiness_duration = var.stickiness_duration

  # true when deploy-asg.yml (CI) shifts the weights with `aws elbv2 modify-listener`
  # (scenarios 45/46 "CI way"); false when you shift them with tfvars + apply ("Terraform way").
  weights_managed_externally = var.listener_weights_managed_externally
}

# One SG shared by blue and green instances: RDS / ElastiCache allow a single source, and
# the SG exists before the ASGs, so nothing waits on a module that waits on the database.
resource "aws_security_group" "app" {
  name        = "${local.name}-app"
  description = "student-app instances (blue + green): only the ALB may connect"
  vpc_id      = module.network.vpc_id
  tags        = { Name = "${local.name}-app" }
}

resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  description                  = "HTTP + health checks from the ALB"
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
  referenced_security_group_id = module.alb.security_group_id
}

resource "aws_vpc_security_group_egress_rule" "app_web" {
  for_each = toset(["80", "443"])

  security_group_id = aws_security_group.app.id
  description       = "Outbound tcp/${each.value} (dnf, ECR, SSM, CloudWatch)"
  ip_protocol       = "tcp"
  from_port         = tonumber(each.value)
  to_port           = tonumber(each.value)
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "app_data" {
  for_each = toset(["3306", "6379"])

  security_group_id = aws_security_group.app.id
  description       = "MySQL / Redis inside the VPC"
  ip_protocol       = "tcp"
  from_port         = tonumber(each.value)
  to_port           = tonumber(each.value)
  cidr_ipv4         = module.network.vpc_cidr
}

# ---------------------------------------------------------------- data tier

module "rds" {
  source = "../../modules/rds-mysql"

  name                       = local.name
  vpc_id                     = module.network.vpc_id
  subnet_ids                 = module.network.private_subnet_ids
  allowed_security_group_ids = [aws_security_group.app.id]
  instance_class             = var.db_instance_class
  multi_az                   = var.db_multi_az
  db_name                    = var.db_name
  username                   = var.db_username
  ssm_prefix                 = local.ssm_app
  deletion_protection        = var.db_deletion_protection
  skip_final_snapshot        = var.db_skip_final_snapshot
}

module "redis" {
  source = "../../modules/elasticache-redis"
  count  = var.redis_enabled ? 1 : 0

  name                       = local.name
  vpc_id                     = module.network.vpc_id
  subnet_ids                 = module.network.private_subnet_ids
  allowed_security_group_ids = [aws_security_group.app.id]
  transit_encryption_enabled = var.redis_transit_encryption
  ssm_prefix                 = local.ssm_app
}

# ---------------------------------------------------------------- logs

# Container stdout/stderr of every instance (awslogs driver, one stream per color/instance).
resource "aws_cloudwatch_log_group" "app" {
  name              = "/${var.project}/${var.env}/app"
  retention_in_days = var.log_retention_days
}

# ---------------------------------------------------------------- app fleets

locals {
  # Every SSM parameter the user data renders must exist before the first boot.
  boot_parameters = concat(
    values(module.rds.ssm_parameter_arns),
    flatten([for r in module.redis : values(r.ssm_parameter_arns)]),
    [for p in aws_ssm_parameter.app : p.arn],
    [for p in aws_ssm_parameter.app_secret : p.arn],
  )

  # Scenario 42: alarms that fail an instance refresh (and trigger auto rollback).
  refresh_alarms = {
    for color in ["blue", "green"] : color => var.refresh_rollback_on_alarms ? [
      module.observability.alarm_names["alb_5xx_ratio"],
      module.observability.alarm_names["unhealthy_hosts_${color}"],
    ] : []
  }

  asg_common = {
    vpc_id           = module.network.vpc_id
    subnet_ids       = local.app_subnet_ids
    image_uri        = local.image_uri
    ssm_prefix       = local.ssm_app
    instance_profile = aws_iam_instance_profile.app.name
  }
}

module "asg_blue" {
  source = "../../modules/asg-app"

  name              = local.asg_names["blue"]
  color             = "blue"
  vpc_id            = local.asg_common.vpc_id
  subnet_ids        = local.asg_common.subnet_ids
  target_group_arns = [module.alb.target_group_arns["blue"]]
  image_uri         = local.asg_common.image_uri
  ssm_prefix        = local.asg_common.ssm_prefix
  instance_profile  = local.asg_common.instance_profile

  create_security_group = false
  security_group_ids    = [aws_security_group.app.id]
  host_port             = 80
  log_group_name        = aws_cloudwatch_log_group.app.name
  wait_for              = local.boot_parameters

  instance_type            = var.instance_type
  arch                     = var.arch
  ami_id                   = var.ami_id
  golden_ami               = var.golden_ami
  install_codedeploy_agent = var.codedeploy_enabled
  min                      = var.min_size
  max                      = var.max_size
  desired                  = var.desired_capacity
  spot_enabled             = var.spot_enabled
  detailed_monitoring      = var.detailed_monitoring
  spot_instance_types      = var.spot_instance_types

  cpu_target              = var.cpu_target
  enable_request_scaling  = var.enable_request_scaling
  requests_per_target     = var.requests_per_target
  alb_arn_suffix          = module.alb.alb_arn_suffix
  target_group_arn_suffix = module.alb.target_group_arn_suffixes["blue"]
  refresh_alarm_names     = local.refresh_alarms["blue"]
}

module "asg_green" {
  source = "../../modules/asg-app"
  count  = var.green_enabled ? 1 : 0

  name              = "${local.name}-green"
  color             = "green"
  vpc_id            = local.asg_common.vpc_id
  subnet_ids        = local.asg_common.subnet_ids
  target_group_arns = [module.alb.target_group_arns["green"]]
  image_uri         = local.asg_common.image_uri
  ssm_prefix        = local.asg_common.ssm_prefix
  instance_profile  = local.asg_common.instance_profile

  create_security_group = false
  security_group_ids    = [aws_security_group.app.id]
  host_port             = 80
  log_group_name        = aws_cloudwatch_log_group.app.name
  wait_for              = local.boot_parameters

  instance_type            = var.instance_type
  arch                     = var.arch
  ami_id                   = var.ami_id
  golden_ami               = var.golden_ami
  install_codedeploy_agent = var.codedeploy_enabled
  min                      = var.min_size
  max                      = var.max_size
  desired                  = var.desired_capacity
  spot_enabled             = var.spot_enabled
  detailed_monitoring      = var.detailed_monitoring
  spot_instance_types      = var.spot_instance_types

  cpu_target              = var.cpu_target
  enable_request_scaling  = var.enable_request_scaling
  requests_per_target     = var.requests_per_target
  alb_arn_suffix          = module.alb.alb_arn_suffix
  target_group_arn_suffix = module.alb.target_group_arn_suffixes["green"]
  refresh_alarm_names     = local.refresh_alarms["green"]
}

# ---------------------------------------------------------------- observability

module "observability" {
  source = "../../modules/observability"

  name                      = local.name
  alarm_email               = var.alarm_email
  alb_arn_suffix            = module.alb.alb_arn_suffix
  target_group_arn_suffixes = module.alb.target_group_arn_suffixes
  asg_names                 = values(local.asg_names)
  rds_instance_id           = module.rds.identifier
  log_group_name            = aws_cloudwatch_log_group.app.name
}
