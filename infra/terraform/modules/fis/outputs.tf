output "role_arn" {
  description = "IAM role FIS assumes."
  value       = aws_iam_role.fis.arn
}

output "log_group_name" {
  description = "Experiment log group."
  value       = aws_cloudwatch_log_group.fis.name
}

output "experiment_template_ids" {
  description = "Template IDs (null when not created). Start one with: aws fis start-experiment --experiment-template-id <id>"
  value = {
    ecs_stop_tasks    = try(aws_fis_experiment_template.ecs_stop_tasks[0].id, null)
    asg_terminate_one = try(aws_fis_experiment_template.asg_terminate_one[0].id, null)
    cpu_stress        = try(aws_fis_experiment_template.cpu_stress[0].id, null)
  }
}
