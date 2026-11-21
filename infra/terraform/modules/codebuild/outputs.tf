output "project_names" {
  description = "Project key -> CodeBuild project name."
  value       = { for k, p in aws_codebuild_project.this : k => p.name }
}

output "project_arns" {
  description = "Project key -> CodeBuild project ARN."
  value       = { for k, p in aws_codebuild_project.this : k => p.arn }
}

output "role_arns" {
  description = "Project key -> service role ARN."
  value       = { for k, r in aws_iam_role.this : k => r.arn }
}

output "log_group_names" {
  description = "Project key -> CloudWatch log group."
  value       = { for k, g in aws_cloudwatch_log_group.this : k => g.name }
}

output "webhook_urls" {
  description = "Project key -> webhook URL (projects with a webhook only)."
  value       = { for k, w in aws_codebuild_webhook.this : k => w.url }
}
