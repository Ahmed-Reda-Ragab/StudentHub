output "instance_id" {
  description = "Repo variable EC2_INSTANCE_ID (SSM Run Command target)."
  value       = module.host.instance_id
}

output "public_ip" {
  description = "Elastic IP of the host (repo variable EC2_HOST for the SSH scenario)."
  value       = module.host.public_ip
}

output "public_dns" {
  description = "Public DNS name of the host."
  value       = module.host.public_dns
}

output "app_url" {
  description = "App URL (APP_URL)."
  value       = "http://${module.host.public_ip}"
}

output "ssm_start_session" {
  description = "Shell on the host without SSH."
  value       = "aws ssm start-session --target ${module.host.instance_id} --region ${local.region}"
}

output "backup_bucket" {
  description = "BACKUP_BUCKET for deploy/ec2/backup-mysql-to-s3.sh."
  value       = aws_s3_bucket.backups.bucket
}

output "ssm_prefix" {
  description = "SSM root for this env (app/ and mysql/ live under it)."
  value       = local.ssm_root
}

output "ecr_repository_url" {
  description = "Where CI pushes images (scenario 32/33 pull from here)."
  value       = local.ecr_repository_url
}

output "sre_lab_token" {
  description = "GitHub secret SRE_LAB_TOKEN / X-Lab-Token header. terraform output -raw sre_lab_token"
  value       = random_password.sre_lab_token.result
  sensitive   = true
}
