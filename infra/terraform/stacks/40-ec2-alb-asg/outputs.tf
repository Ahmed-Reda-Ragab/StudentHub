output "alb_dns_name" {
  description = "ALB DNS name."
  value       = module.alb.dns_name
}

output "app_url" {
  description = "App URL (APP_URL)."
  value       = local.app_url
}

output "asg_names" {
  description = "ASG names by color (start-instance-refresh targets)."
  value = merge(
    { blue = module.asg_blue.asg_name },
    { for m in module.asg_green : "green" => m.asg_name },
  )
}

output "image_parameter_names" {
  description = "SSM parameters CI updates to release an image, by color."
  value = merge(
    { blue = module.asg_blue.image_parameter_name },
    { for m in module.asg_green : "green" => m.image_parameter_name },
  )
}

output "target_group_arns" {
  description = "Target group ARNs { blue, green }."
  value       = module.alb.target_group_arns
}

output "target_group_names" {
  description = "Target group names { blue, green }."
  value       = module.alb.target_group_names
}

output "listener_arn" {
  description = "Listener carrying traffic (modify-listener here to shift weights)."
  value       = module.alb.listener_arn
}

output "rds_address" {
  description = "RDS endpoint hostname (also in SSM as DB_HOST)."
  value       = module.rds.address
}

output "redis_endpoint" {
  description = "ElastiCache primary endpoint (null unless redis_enabled)."
  value       = one(module.redis[*].primary_endpoint_address)
}

output "sns_topic_arn" {
  description = "Alerts topic."
  value       = module.observability.sns_topic_arn
}

output "dashboard_url" {
  description = "CloudWatch dashboard."
  value       = module.observability.dashboard_url
}

output "log_group_name" {
  description = "Container logs of all instances."
  value       = aws_cloudwatch_log_group.app.name
}

output "ssm_prefix" {
  description = "SSM root for this env."
  value       = local.ssm_root
}

output "sre_lab_token" {
  description = "X-Lab-Token / GitHub secret SRE_LAB_TOKEN. terraform output -raw sre_lab_token"
  value       = random_password.sre_lab_token.result
  sensitive   = true
}

output "migrate_command" {
  description = "Run migrations ONCE per release on one blue instance via SSM (CONVENTIONS §2)."
  value       = <<-EOT
    IID=$(aws autoscaling describe-auto-scaling-groups --region ${local.region} \
      --auto-scaling-group-names ${module.asg_blue.asg_name} \
      --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`]|[0].InstanceId' --output text)
    aws ssm send-command --region ${local.region} --instance-ids "$IID" \
      --document-name AWS-RunShellScript \
      --parameters 'commands=["docker exec student-app php artisan migrate --force"]'
  EOT
}

output "release_commands" {
  description = "Rolling release of a new image to blue (scenario 44)."
  value       = <<-EOT
    aws ssm put-parameter --region ${local.region} --overwrite \
      --name ${module.asg_blue.image_parameter_name} --value ${local.ecr_repository_url}:<sha>
    aws autoscaling start-instance-refresh --region ${local.region} \
      --auto-scaling-group-name ${module.asg_blue.asg_name} \
      --preferences '{"MinHealthyPercentage":50,"InstanceWarmup":120}'
  EOT
}

output "codedeploy" {
  description = "Scenario 37 (codedeploy_enabled = true): names + the release commands."
  value = var.codedeploy_enabled ? {
    application      = module.codedeploy[0].app_name
    deployment_group = module.codedeploy[0].deployment_group_name
    revision_bucket  = local.codedeploy_bucket
    release = join(" && ", [
      "dir=$(deploy/codedeploy/ec2/package-revision.sh <ECR_URI>:<SHA>)",
      "aws deploy push --application-name ${module.codedeploy[0].app_name} --s3-location s3://${local.codedeploy_bucket}/codedeploy/student-app-<SHA>.zip --source \"$dir\"",
      "aws deploy create-deployment --application-name ${module.codedeploy[0].app_name} --deployment-group-name ${module.codedeploy[0].deployment_group_name} --s3-location bucket=${local.codedeploy_bucket},key=codedeploy/student-app-<SHA>.zip,bundleType=zip",
    ])
  } : null
}
