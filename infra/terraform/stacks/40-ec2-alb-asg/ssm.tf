# App configuration in SSM (CONVENTIONS §4). Ownership of /student-app/<env>/app/*:
#   this file           APP_KEY, APP_URL, DB_CONNECTION, SESSION_DRIVER, CACHE_STORE, SRE_LAB_*, METRICS_ENABLED
#   modules/rds-mysql   DB_HOST, DB_PORT, DB_DATABASE, DB_USERNAME, DB_PASSWORD
#   modules/elasticache REDIS_HOST, REDIS_PORT                      (redis_enabled)
#   modules/asg-app     ../deploy/<color>/IMAGE_URI                  (seeded; CI owns the value)
# Stacks 20/50/60 write the same paths: one of them per env at a time.

resource "random_bytes" "app_key" {
  length = 32
}

resource "random_password" "sre_lab_token" {
  length  = 32
  special = false
}

locals {
  # Scenario 49: sessions + cache move from MySQL (already shared, so scale-in never logs anyone
  # out) to Redis — the point is taking a write per request off the database, not stickiness.
  state_store = var.redis_enabled ? "redis" : "database"

  app_plain = {
    APP_URL         = local.app_url
    DB_CONNECTION   = "mysql"
    SESSION_DRIVER  = local.state_store
    CACHE_STORE     = local.state_store
    SRE_LAB_ENABLED = tostring(var.sre_lab_enabled)
    METRICS_ENABLED = "true"
    # Behind HTTPS the session cookie must never travel over plain HTTP (scenario 83).
    SESSION_SECURE_COOKIE = tostring(local.https_enabled)
  }

  app_secret_keys = ["APP_KEY", "SRE_LAB_TOKEN"]
  app_secrets = {
    APP_KEY       = "base64:${random_bytes.app_key.base64}"
    SRE_LAB_TOKEN = random_password.sre_lab_token.result
  }
}

resource "aws_ssm_parameter" "app" {
  for_each = local.app_plain

  name           = "${local.ssm_app}/${each.key}"
  type           = "String"
  insecure_value = each.value
  description    = "Managed by Terraform (stacks/40-ec2-alb-asg)"
}

resource "aws_ssm_parameter" "app_secret" {
  for_each = toset(local.app_secret_keys)

  name        = "${local.ssm_app}/${each.key}"
  type        = "SecureString"
  value       = local.app_secrets[each.key]
  description = "Managed by Terraform (stacks/40-ec2-alb-asg)"
}
