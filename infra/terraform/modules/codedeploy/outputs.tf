output "app_name" {
  description = "CodeDeploy application name (GitHub Actions codedeploy-application / CodePipeline ApplicationName)."
  value       = aws_codedeploy_app.this.name
}

output "deployment_group_name" {
  description = "Deployment group name (codedeploy-deployment-group / DeploymentGroupName)."
  value       = local.is_ecs ? aws_codedeploy_deployment_group.ecs[0].deployment_group_name : aws_codedeploy_deployment_group.server[0].deployment_group_name
}

output "deployment_group_arn" {
  description = "Deployment group ARN."
  value       = local.is_ecs ? aws_codedeploy_deployment_group.ecs[0].arn : aws_codedeploy_deployment_group.server[0].arn
}

output "service_role_arn" {
  description = "CodeDeploy service role ARN."
  value       = aws_iam_role.this.arn
}

output "deployment_config_name" {
  description = "Effective deployment configuration."
  value       = local.deployment_config_name
}
