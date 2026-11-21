output "pipeline_name" {
  description = "Pipeline name (aws codepipeline start-pipeline-execution --name ...)."
  value       = aws_codepipeline.this.name
}

output "pipeline_arn" {
  description = "Pipeline ARN."
  value       = aws_codepipeline.this.arn
}

output "artifact_bucket_name" {
  description = "Artifact bucket."
  value       = aws_s3_bucket.artifacts.bucket
}

output "artifact_bucket_arn" {
  description = "Artifact bucket ARN (CodeBuild CODEPIPELINE projects need it)."
  value       = aws_s3_bucket.artifacts.arn
}

output "role_arn" {
  description = "Pipeline service role."
  value       = aws_iam_role.pipeline.arn
}
