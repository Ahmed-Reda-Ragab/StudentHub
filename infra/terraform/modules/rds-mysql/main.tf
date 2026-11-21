# RDS MySQL module (scenarios 41, 77, 81).
#
# - private, encrypted, gp3, automated backups + PITR
# - connection settings are published to SSM (CONVENTIONS §4) so EC2 user data, ECS task
#   definitions and External Secrets all read ONE source of truth:
#     <ssm_prefix>/DB_HOST, DB_PORT, DB_DATABASE, DB_USERNAME (String), DB_PASSWORD (SecureString)
#
# The password is in Terraform state (random_password + SSM value): the state bucket is
# encrypted and access-controlled for that reason. use_secrets_manager = true removes it.

locals {
  identifier = "${var.name}-mysql"
  ssm_prefix = trimsuffix(var.ssm_prefix, "/")
  # "8.4" / "8.4.6" -> "mysql8.4"
  family = "mysql${join(".", slice(split(".", var.engine_version), 0, 2))}"
}

# Alphanumeric only: the value travels through env files (docker --env-file, compose),
# shells and URLs, where $ # " ' / @ break things. 32 chars of [A-Za-z0-9] ≈ 190 bits.
resource "random_password" "master" {
  count = var.use_secrets_manager ? 0 : 1

  length  = 32
  special = false
}

# Final snapshot names must be unique per account/region; a suffix avoids collisions
# when the lab stack is created and destroyed repeatedly.
resource "random_id" "snapshot" {
  byte_length = 4
}

# ---------------------------------------------------------------- networking

resource "aws_db_subnet_group" "this" {
  name       = local.identifier
  subnet_ids = var.subnet_ids
  tags       = { Name = local.identifier }
}

resource "aws_security_group" "this" {
  name        = "${var.name}-rds"
  description = "MySQL ${local.identifier}: 3306 from app security groups only"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-rds" }
  # No egress rules: the database never initiates connections.
}

# count (not for_each): SG IDs created in the same plan are unknown, but the list length is known.
resource "aws_vpc_security_group_ingress_rule" "from_sg" {
  count = length(var.allowed_security_group_ids)

  security_group_id            = aws_security_group.this.id
  description                  = "MySQL from app SG"
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
  referenced_security_group_id = var.allowed_security_group_ids[count.index]
}

resource "aws_vpc_security_group_ingress_rule" "from_cidr" {
  for_each = toset(var.allowed_cidr_blocks)

  security_group_id = aws_security_group.this.id
  description       = "MySQL from ${each.value}"
  ip_protocol       = "tcp"
  from_port         = 3306
  to_port           = 3306
  cidr_ipv4         = each.value
}

# ---------------------------------------------------------------- engine settings

resource "aws_db_parameter_group" "this" {
  # name_prefix + create_before_destroy: a family change (8.4 -> 9.x) can build the new group
  # before the old one, which is still attached to the instance, is deleted.
  name_prefix = "${local.identifier}-"
  family      = local.family
  description = "utf8mb4 + slow query log for ${local.identifier}"

  # Same charset/collation as the local MySQL container (docker-compose.prod.yml).
  parameter {
    name  = "character_set_server"
    value = "utf8mb4"
  }

  parameter {
    name  = "collation_server"
    value = "utf8mb4_unicode_ci"
  }

  parameter {
    name  = "slow_query_log"
    value = "1"
  }

  parameter {
    name  = "long_query_time"
    value = tostring(var.long_query_time)
  }

  # require_secure_transport stays OFF on purpose: Laravel's mysql driver does not use TLS
  # unless MYSQL_ATTR_SSL_CA is configured. Turning it on is a scenario 81 hardening step.

  lifecycle {
    create_before_destroy = true
  }
}

# RDS creates these log groups with "never expire"; pre-creating them sets a retention.
resource "aws_cloudwatch_log_group" "exports" {
  for_each = toset(var.cloudwatch_logs_exports)

  name              = "/aws/rds/instance/${local.identifier}/${each.value}"
  retention_in_days = var.log_retention_days
}

# ---------------------------------------------------------------- instance

resource "aws_db_instance" "this" {
  identifier = local.identifier

  engine                     = "mysql"
  engine_version             = var.engine_version
  auto_minor_version_upgrade = true
  instance_class             = var.instance_class
  parameter_group_name       = aws_db_parameter_group.this.name

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true # AWS-managed aws/rds key: free, and encryption cannot be added later

  db_name  = var.db_name
  username = var.username
  port     = 3306

  # Exactly one of the two password modes.
  password                    = var.use_secrets_manager ? null : random_password.master[0].result
  manage_master_user_password = var.use_secrets_manager ? true : null

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.this.id]
  publicly_accessible    = false
  multi_az               = var.multi_az

  backup_retention_period = var.backup_retention_period
  backup_window           = "03:00-03:30"         # UTC, before the maintenance window
  maintenance_window      = "sun:04:00-sun:04:30" # UTC
  copy_tags_to_snapshot   = true

  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${local.identifier}-final-${random_id.snapshot.hex}"
  delete_automated_backups  = var.delete_automated_backups

  enabled_cloudwatch_logs_exports = var.cloudwatch_logs_exports
  apply_immediately               = var.apply_immediately

  tags = { Name = local.identifier }

  depends_on = [aws_cloudwatch_log_group.exports]
}

# ---------------------------------------------------------------- SSM (CONVENTIONS §4)

locals {
  ssm_plain = {
    DB_HOST     = aws_db_instance.this.address
    DB_PORT     = tostring(aws_db_instance.this.port)
    DB_DATABASE = var.db_name
    DB_USERNAME = var.username
  }
}

resource "aws_ssm_parameter" "plain" {
  for_each = local.ssm_plain

  name           = "${local.ssm_prefix}/${each.key}"
  type           = "String"
  insecure_value = each.value # not secret: keep it readable in plans
  description    = "Managed by Terraform (modules/rds-mysql)"
}

resource "aws_ssm_parameter" "password" {
  count = var.use_secrets_manager ? 0 : 1

  name        = "${local.ssm_prefix}/DB_PASSWORD"
  type        = "SecureString" # aws/ssm KMS key; readers need kms:Decrypt via ssm
  value       = random_password.master[0].result
  description = "Managed by Terraform (modules/rds-mysql)"
}
