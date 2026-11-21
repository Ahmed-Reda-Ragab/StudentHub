# App configuration in SSM (CONVENTIONS §4). Ownership of /student-app/<env>/app/*:
#   this file          APP_KEY, APP_URL, DB_CONNECTION, SESSION_DRIVER, CACHE_STORE, SRE_LAB_*, METRICS_ENABLED
#   modules/rds-mysql  DB_HOST, DB_PORT, DB_DATABASE, DB_USERNAME, DB_PASSWORD
# Stacks 20/40/50/60 write the same paths: run one of them per env at a time.
# ECS reads every key through the task definition `secrets` (valueFrom = parameter ARN).

resource "random_bytes" "app_key" {
  length = 32
}

resource "random_password" "sre_lab_token" {
  length  = 32
  special = false
}

locals {
  app_plain = {
    APP_URL         = local.app_url
    DB_CONNECTION   = "mysql"
    SESSION_DRIVER  = "database"
    CACHE_STORE     = "database"
    SRE_LAB_ENABLED = tostring(var.sre_lab_enabled)
    METRICS_ENABLED = "true" # /metrics is blocked at the ALB (modules/alb), scraped inside the VPC only
  }

  app_secret_keys = ["APP_KEY", "SRE_LAB_TOKEN"]
  app_secrets = {
    APP_KEY       = "base64:${random_bytes.app_key.base64}" # same format as php artisan key:generate
    SRE_LAB_TOKEN = random_password.sre_lab_token.result
  }
}

resource "aws_ssm_parameter" "app" {
  for_each = local.app_plain

  name           = "${local.ssm_prefix}/${each.key}"
  type           = "String"
  insecure_value = each.value
  description    = "Managed by Terraform (stacks/50-ecs-fargate)"
}

resource "aws_ssm_parameter" "app_secret" {
  for_each = toset(local.app_secret_keys)

  name        = "${local.ssm_prefix}/${each.key}"
  type        = "SecureString" # aws/ssm key; the execution role decrypts via SSM only
  value       = local.app_secrets[each.key]
  description = "Managed by Terraform (stacks/50-ecs-fargate)"
}
