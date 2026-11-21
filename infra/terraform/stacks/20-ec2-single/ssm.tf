# SSM Parameter Store = the source of truth for runtime config (CONVENTIONS §4).
#   /student-app/<env>/app/*    -> /opt/student-app/app.env    (render-env-from-ssm.sh)
#   /student-app/<env>/mysql/*  -> /opt/student-app/mysql.env  (local MySQL container)
#
# Secrets are generated here, so they exist in Terraform state too (encrypted state bucket).
# The other EC2/ECS/EKS stacks write the same /app paths: apply ONE of them per env at a time.

resource "random_bytes" "app_key" {
  length = 32 # Laravel AES-256-CBC key
}

# Alphanumeric only: these values pass through env files, shells and compose interpolation.
resource "random_password" "db" {
  length  = 32
  special = false
}

resource "random_password" "mysql_root" {
  length  = 32
  special = false
}

resource "random_password" "sre_lab_token" {
  length  = 32
  special = false
}

locals {
  app_plain = {
    APP_URL         = "http://${module.host.public_ip}"
    DB_CONNECTION   = "mysql"
    DB_HOST         = "mysql" # compose service name of the local MySQL container
    DB_PORT         = "3306"
    DB_DATABASE     = var.db_name
    DB_USERNAME     = var.db_username
    SESSION_DRIVER  = "database"
    CACHE_STORE     = "database"
    SRE_LAB_ENABLED = tostring(var.sre_lab_enabled)
    METRICS_ENABLED = "true"
  }

  # for_each over a literal key list: a map holding sensitive values cannot drive for_each.
  app_secret_keys = ["APP_KEY", "DB_PASSWORD", "SRE_LAB_TOKEN"]
  app_secrets = {
    APP_KEY       = "base64:${random_bytes.app_key.base64}"
    DB_PASSWORD   = random_password.db.result
    SRE_LAB_TOKEN = random_password.sre_lab_token.result
  }

  mysql_plain = {
    MYSQL_DATABASE = var.db_name
    MYSQL_USER     = var.db_username
  }

  mysql_secret_keys = ["MYSQL_PASSWORD", "MYSQL_ROOT_PASSWORD"]
  mysql_secrets = {
    MYSQL_PASSWORD      = random_password.db.result # same user/password the app connects with
    MYSQL_ROOT_PASSWORD = random_password.mysql_root.result
  }
}

resource "aws_ssm_parameter" "app" {
  for_each = local.app_plain

  name           = "${local.ssm_app}/${each.key}"
  type           = "String"
  insecure_value = each.value
  description    = "Managed by Terraform (stacks/20-ec2-single)"
}

resource "aws_ssm_parameter" "app_secret" {
  for_each = toset(local.app_secret_keys)

  name        = "${local.ssm_app}/${each.key}"
  type        = "SecureString"
  value       = local.app_secrets[each.key]
  description = "Managed by Terraform (stacks/20-ec2-single)"
}

resource "aws_ssm_parameter" "mysql" {
  for_each = local.mysql_plain

  name           = "${local.ssm_mysql}/${each.key}"
  type           = "String"
  insecure_value = each.value
  description    = "Managed by Terraform (stacks/20-ec2-single)"
}

resource "aws_ssm_parameter" "mysql_secret" {
  for_each = toset(local.mysql_secret_keys)

  name        = "${local.ssm_mysql}/${each.key}"
  type        = "SecureString"
  value       = local.mysql_secrets[each.key]
  description = "Managed by Terraform (stacks/20-ec2-single)"
}
