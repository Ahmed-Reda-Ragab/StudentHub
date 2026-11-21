output "address" {
  description = "DB hostname (DB_HOST)."
  value       = aws_db_instance.this.address
}

output "port" {
  description = "DB port (DB_PORT)."
  value       = aws_db_instance.this.port
}

output "db_name" {
  description = "Database name (DB_DATABASE)."
  value       = aws_db_instance.this.db_name
}

output "username" {
  description = "Master username (DB_USERNAME)."
  value       = aws_db_instance.this.username
}

output "security_group_id" {
  description = "RDS security group ID."
  value       = aws_security_group.this.id
}

output "password_ssm_arn" {
  description = "ARN of <ssm_prefix>/DB_PASSWORD (ECS secrets valueFrom). null when use_secrets_manager = true."
  value       = var.use_secrets_manager ? null : aws_ssm_parameter.password[0].arn
}

output "master_user_secret_arn" {
  description = "Secrets Manager secret holding the master password (use_secrets_manager = true), otherwise null."
  value       = var.use_secrets_manager ? aws_db_instance.this.master_user_secret[0].secret_arn : null
}

output "identifier" {
  description = "DB instance identifier (CloudWatch DBInstanceIdentifier dimension)."
  value       = aws_db_instance.this.identifier
}

output "arn" {
  description = "DB instance ARN."
  value       = aws_db_instance.this.arn
}

output "endpoint" {
  description = "host:port endpoint."
  value       = aws_db_instance.this.endpoint
}

output "ssm_parameter_arns" {
  description = "Map of env key -> SSM parameter ARN for everything this module writes."
  value = merge(
    { for k, p in aws_ssm_parameter.plain : k => p.arn },
    var.use_secrets_manager ? {} : { DB_PASSWORD = aws_ssm_parameter.password[0].arn },
  )
}
