locals {
  migration_overrides = jsonencode({
    containerOverrides = [{ name = module.ecs.container_name, command = ["php", "artisan", "migrate", "--force"] }]
  })
}

output "app_url" {
  description = "Public URL of the app (ALB)."
  value       = local.app_url
}

output "alb_dns_name" {
  description = "ALB DNS name."
  value       = module.alb.dns_name
}

output "cluster_name" {
  description = "ECS cluster (repo variable ECS_CLUSTER)."
  value       = module.ecs.cluster_name
}

output "service_name" {
  description = "ECS service (repo variable ECS_SERVICE)."
  value       = module.ecs.service_name
}

output "task_family" {
  description = "Task definition family; CI copies its newest revision and swaps the image."
  value       = module.ecs.task_definition_family
}

output "task_definition_arn" {
  description = "Revision registered by Terraform (bootstrap image)."
  value       = module.ecs.task_definition_arn
}

output "log_group" {
  description = "App log group (streams app/app/<task-id>)."
  value       = module.ecs.log_group_name
}

output "target_group_names" {
  description = "Target groups { blue, green }."
  value       = module.alb.target_group_names
}

output "listener_arn" {
  description = "Traffic listener (CodeDeploy production listener)."
  value       = module.alb.listener_arn
}

output "run_task_network_configuration" {
  description = "JSON for aws ecs run-task --network-configuration."
  value       = module.ecs.run_task_network_configuration
}

output "migration_command" {
  description = "One-off migration task (on-demand FARGATE). Prefer deploy/ecs/run-migrations.sh, which also waits and checks the exit code."
  value = join(" ", [
    "aws ecs run-task --region ${var.region}",
    "--cluster ${module.ecs.cluster_name}",
    "--task-definition ${module.ecs.task_definition_family}",
    "--capacity-provider-strategy capacityProvider=FARGATE,weight=1",
    "--network-configuration '${module.ecs.run_task_network_configuration}'",
    "--overrides '${local.migration_overrides}'",
    "--started-by migrations --query 'tasks[0].taskArn' --output text",
  ])
}

output "migration_script_command" {
  description = "Same, with wait + exit-code check + log output. Run it from the REPO ROOT (the script path is relative to it)."
  value       = "AWS_REGION=${var.region} deploy/ecs/run-migrations.sh --cluster ${module.ecs.cluster_name} --service ${module.ecs.service_name}"
}

output "ecs_exec_command" {
  description = "Shell inside a running task (scenario 52)."
  value       = "AWS_REGION=${var.region} deploy/ecs/ecs-exec.sh --cluster ${module.ecs.cluster_name} --service ${module.ecs.service_name}"
}

output "deployment" {
  description = "Effective deployment settings."
  value = {
    controller      = var.deployment_controller
    strategy        = var.deployment_controller == "ECS" ? var.deployment_strategy : "CODE_DEPLOY"
    production_rule = module.ecs.production_listener_rule_arn
    test_rule       = module.ecs.test_listener_rule_arn # curl -H 'X-Lab-Target: green' <app_url>/ready
    alarms          = local.deployment_alarm_names
  }
}

output "codedeploy_app_name" {
  description = "CodeDeploy application (CODE_DEPLOY only)."
  value       = try(module.codedeploy[0].app_name, null)
}

output "codedeploy_deployment_group_name" {
  description = "CodeDeploy deployment group (CODE_DEPLOY only)."
  value       = try(module.codedeploy[0].deployment_group_name, null)
}

output "rds_address" {
  description = "RDS endpoint (private)."
  value       = module.rds.address
}

output "ssm_prefix" {
  description = "SSM path of the app configuration."
  value       = local.ssm_prefix
}

output "dashboard_url" {
  description = "CloudWatch dashboard."
  value       = module.observability.dashboard_url
}

output "fis_experiment_template_ids" {
  description = "FIS templates (enable_fis)."
  value       = try(module.fis[0].experiment_template_ids, null)
}

output "github_repository_variables" {
  description = "GitHub -> Settings -> Variables for .github/workflows/deploy-ecs.yml."
  value = {
    ECS_CLUSTER                     = module.ecs.cluster_name
    ECS_SERVICE                     = module.ecs.service_name
    ECS_APP_URL                     = local.app_url
    ECS_CODEDEPLOY_APPLICATION      = try(module.codedeploy[0].app_name, "")
    ECS_CODEDEPLOY_DEPLOYMENT_GROUP = try(module.codedeploy[0].deployment_group_name, "")
  }
}

# Feed stack 36 without copy/paste (keys = its variable names):
#   terraform output -json pipeline_inputs > ../36-codepipeline/stack50.auto.tfvars.json
output "pipeline_inputs" {
  description = "Inputs for stacks/36-codepipeline."
  value = {
    ecs_cluster_name                 = module.ecs.cluster_name
    ecs_service_name                 = module.ecs.service_name
    task_family                      = module.ecs.task_definition_family
    task_execution_role_arn          = module.ecs.execution_role_arn
    task_role_arn                    = module.ecs.task_role_arn
    app_log_group_arn                = module.ecs.log_group_arn
    codedeploy_app_name              = try(module.codedeploy[0].app_name, null)
    codedeploy_deployment_group_name = try(module.codedeploy[0].deployment_group_name, null)
  }
}
