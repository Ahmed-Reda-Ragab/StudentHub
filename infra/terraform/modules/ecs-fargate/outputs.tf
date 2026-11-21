output "cluster_name" {
  description = "ECS cluster name (repo variable ECS_CLUSTER)."
  value       = aws_ecs_cluster.this.name
}

output "cluster_arn" {
  description = "ECS cluster ARN."
  value       = aws_ecs_cluster.this.arn
}

output "service_name" {
  description = "ECS service name (repo variable ECS_SERVICE)."
  value       = aws_ecs_service.app.name
}

output "task_definition_arn" {
  description = "Task definition revision registered by Terraform (CI registers newer ones in the same family)."
  value       = aws_ecs_task_definition.app.arn
}

output "task_definition_family" {
  description = "Task definition family. CI copies the newest revision of this family and swaps only the image."
  value       = aws_ecs_task_definition.app.family
}

output "container_name" {
  description = "Container name used by imagedefinitions.json / appspec.yaml."
  value       = local.container_name
}

output "container_port" {
  description = "Container port."
  value       = var.container_port
}

output "task_role_arn" {
  description = "Task (application) role ARN."
  value       = aws_iam_role.task.arn
}

output "execution_role_arn" {
  description = "Task execution role ARN."
  value       = aws_iam_role.execution.arn
}

output "log_group_name" {
  description = "CloudWatch log group of the app container (stream prefix app/app/<task-id>)."
  value       = aws_cloudwatch_log_group.app.name
}

output "log_group_arn" {
  description = "CloudWatch log group ARN."
  value       = aws_cloudwatch_log_group.app.arn
}

output "security_group_id" {
  description = "Security group of the tasks (allow it on RDS / Redis)."
  value       = aws_security_group.service.id
}

output "infrastructure_role_arn" {
  description = "Role ECS assumes to shift ALB weights (native BLUE_GREEN/LINEAR/CANARY), null otherwise."
  value       = local.traffic_shifting ? aws_iam_role.infrastructure[0].arn : null
}

output "production_listener_rule_arn" {
  description = "Listener rule ECS rewrites during native deployments, null for ROLLING / CODE_DEPLOY."
  value       = local.traffic_shifting ? aws_lb_listener_rule.production[0].arn : null
}

output "test_listener_rule_arn" {
  description = "Header-based test rule (X-Lab-Target: green), null when disabled."
  value       = local.traffic_shifting && var.enable_test_listener_rule ? aws_lb_listener_rule.test[0].arn : null
}

output "run_task_network_configuration" {
  description = "JSON for `aws ecs run-task --network-configuration` (one-off tasks such as migrations)."
  value = jsonencode({
    awsvpcConfiguration = {
      subnets        = var.subnet_ids
      securityGroups = [aws_security_group.service.id]
      assignPublicIp = var.assign_public_ip ? "ENABLED" : "DISABLED"
    }
  })
}
