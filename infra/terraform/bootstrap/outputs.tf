output "account_id" {
  description = "AWS account ID."
  value       = local.account_id
}

output "region" {
  description = "Region this bootstrap was applied in."
  value       = local.region
}

output "state_bucket" {
  description = "Remote state bucket for every stack (backend.hcl `bucket`)."
  value       = aws_s3_bucket.state.bucket
}

output "github_oidc_provider_arn" {
  description = "GitHub OIDC provider ARN."
  value       = local.oidc_provider_arn
}

output "github_ci_role_arn" {
  description = "Repo variable AWS_ROLE_ARN (ci.yml pushes to ECR)."
  value       = aws_iam_role.ci.arn
}

output "github_deploy_role_arn" {
  description = "Repo variable AWS_DEPLOY_ROLE_ARN."
  value       = aws_iam_role.deploy.arn
}

output "github_terraform_role_arn" {
  description = "Repo variable AWS_TERRAFORM_ROLE_ARN (apply/destroy, environment lab)."
  value       = aws_iam_role.terraform.arn
}

output "github_terraform_plan_role_arn" {
  description = "Repo variable AWS_TERRAFORM_PLAN_ROLE_ARN (read-only plans on PRs)."
  value       = var.create_terraform_plan_role ? aws_iam_role.terraform_plan[0].arn : null
}

output "ecr_repository_url" {
  description = "ECR repository URL (<account>.dkr.ecr.<region>.amazonaws.com/student-app)."
  value       = aws_ecr_repository.app.repository_url
}

output "codeconnections_arn" {
  description = "CodeConnections ARN for CodePipeline. Starts PENDING — finish the handshake in the console."
  value       = var.create_codeconnection ? aws_codeconnections_connection.github[0].arn : null
}

output "codeconnections_status" {
  description = "PENDING until the console handshake is done, then AVAILABLE."
  value       = var.create_codeconnection ? aws_codeconnections_connection.github[0].connection_status : null
}

output "backend_hcl" {
  description = "Paste into infra/terraform/backend.hcl."
  value       = <<-EOT
    bucket       = "${aws_s3_bucket.state.bucket}"
    region       = "${local.region}"
    use_lockfile = true
    encrypt      = true
  EOT
}

output "github_repository_variables" {
  description = "Values for GitHub -> Settings -> Secrets and variables -> Actions -> Variables (CONVENTIONS §9)."
  value = {
    AWS_REGION                  = local.region
    AWS_ROLE_ARN                = aws_iam_role.ci.arn
    AWS_DEPLOY_ROLE_ARN         = aws_iam_role.deploy.arn
    AWS_TERRAFORM_ROLE_ARN      = aws_iam_role.terraform.arn
    AWS_TERRAFORM_PLAN_ROLE_ARN = var.create_terraform_plan_role ? aws_iam_role.terraform_plan[0].arn : ""
    ECR_REPOSITORY              = aws_ecr_repository.app.name
    TF_STATE_BUCKET             = aws_s3_bucket.state.bucket
    ANSIBLE_SSM_BUCKET          = aws_s3_bucket.ansible_ssm.bucket
    CODECONNECTIONS_ARN         = var.create_codeconnection ? aws_codeconnections_connection.github[0].arn : ""
  }
}

output "ansible_ssm_bucket" {
  description = "S3 transfer bucket for Ansible over SSM (repo variable ANSIBLE_SSM_BUCKET, group_vars ansible_aws_ssm_bucket_name)."
  value       = aws_s3_bucket.ansible_ssm.bucket
}
