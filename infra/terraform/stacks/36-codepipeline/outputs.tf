output "pipeline_name" {
  description = "Pipeline name."
  value       = module.pipeline.pipeline_name
}

output "pipeline_console_url" {
  description = "Pipeline in the console."
  value       = "https://${var.region}.console.aws.amazon.com/codesuite/codepipeline/pipelines/${module.pipeline.pipeline_name}/view?region=${var.region}"
}

output "start_command" {
  description = "Start a run without pushing a commit."
  value       = "aws codepipeline start-pipeline-execution --region ${var.region} --name ${module.pipeline.pipeline_name}"
}

output "artifact_bucket" {
  description = "Artifact bucket (expires objects after 14 days, emptied on destroy)."
  value       = module.pipeline.artifact_bucket_name
}

output "codebuild_projects" {
  description = "CodeBuild projects used by the pipeline."
  value       = module.codebuild.project_names
}

output "deploy_mode" {
  description = "Effective deploy mode."
  value       = var.deploy_mode
}
