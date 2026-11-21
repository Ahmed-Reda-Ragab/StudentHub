output "primary_endpoint_address" {
  description = "Primary endpoint hostname."
  value       = aws_elasticache_replication_group.this.primary_endpoint_address
}

output "port" {
  description = "Cache port."
  value       = var.port
}

output "replication_group_id" {
  description = "Replication group ID (CloudWatch dimension)."
  value       = aws_elasticache_replication_group.this.id
}

output "security_group_id" {
  description = "Cache security group ID."
  value       = aws_security_group.this.id
}

output "ssm_parameter_arns" {
  description = "SSM parameters written by this module."
  value = {
    REDIS_HOST = aws_ssm_parameter.host.arn
    REDIS_PORT = aws_ssm_parameter.port.arn
  }
}
