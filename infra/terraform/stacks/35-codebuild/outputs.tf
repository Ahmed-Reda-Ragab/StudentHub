output "project_names" {
  description = "CodeBuild projects."
  value       = module.codebuild.project_names
}

output "role_arns" {
  description = "Service role per project."
  value       = module.codebuild.role_arns
}

output "log_groups" {
  description = "CloudWatch log group per project."
  value       = module.codebuild.log_group_names
}

output "start_build_commands" {
  description = "Manual runs."
  value = {
    for k, name in module.codebuild.project_names :
    k => "aws codebuild start-build --region ${var.region} --project-name ${name} --source-version ${var.image_branch}"
    if k != "gha-runner"
  }
}

output "gha_runner_label" {
  description = "runs-on label for jobs that should run on the CodeBuild runner (null when disabled)."
  value       = var.enable_gha_runner ? "codebuild-${module.codebuild.project_names["gha-runner"]}-$${{ github.run_id }}-$${{ github.run_attempt }}" : null
}
