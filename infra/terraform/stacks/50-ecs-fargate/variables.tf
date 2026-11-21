variable "project" {
  description = "Project name (CONVENTIONS §1)."
  type        = string
  default     = "student-app"
}

variable "env" {
  description = "Environment; also the SSM path segment (/student-app/<env>/app/*)."
  type        = string
  default     = "lab"
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "scenario" {
  description = "Scenario tag value, e.g. -var scenario=54."
  type        = string
  default     = "50"
}

# ---------------------------------------------------------------- network / edge

variable "vpc_cidr" {
  description = "VPC CIDR (2 AZs, no NAT by default)."
  type        = string
  default     = "10.50.0.0/16"
}

variable "enable_nat" {
  description = <<-EOT
    false (default): tasks in PUBLIC subnets with a public IP (inbound only from the ALB SG) — no NAT, ~32 USD/month saved.
    true: tasks in PRIVATE subnets behind one NAT gateway (the production layout).
  EOT
  type        = bool
  default     = false
}

variable "certificate_arn" {
  description = "ACM certificate for HTTPS on the ALB (optional; HTTP-only lab by default)."
  type        = string
  default     = null
}

variable "app_url" {
  description = "Public URL written to APP_URL. null = http://<alb-dns-name>."
  type        = string
  default     = null
}

# ---------------------------------------------------------------- image / task

variable "ecr_repository_name" {
  description = "ECR repository created by the bootstrap stack."
  type        = string
  default     = "student-app"
}

variable "image_tag" {
  description = "Initial image tag: a git short SHA CI already pushed (aws ecr list-images --repository-name student-app). CI owns the image afterwards."
  type        = string

  validation {
    condition     = var.image_tag != "latest" && can(regex("^[A-Za-z0-9._-]{1,128}$", var.image_tag))
    error_message = "image_tag must be set to an immutable tag (git short SHA), never 'latest' or empty — in CI set the repo variable ECS_IMAGE_TAG."
  }
}

variable "task_cpu" {
  description = "Task CPU units (512 = 0.5 vCPU)."
  type        = number
  default     = 512
}

variable "task_memory" {
  description = "Task memory MiB."
  type        = number
  default     = 1024
}

variable "desired_count" {
  description = "Initial tasks (autoscaling owns the count afterwards)."
  type        = number
  default     = 2
}

variable "autoscaling_min" {
  description = "Minimum tasks."
  type        = number
  default     = 2
}

variable "autoscaling_max" {
  description = "Maximum tasks."
  type        = number
  default     = 6
}

variable "use_fargate_spot" {
  description = "true: 1 task on FARGATE + the rest on FARGATE_SPOT (~70% cheaper). false: everything on FARGATE (scenario 56 compares)."
  type        = bool
  default     = true
}

variable "container_insights" {
  description = "enhanced | enabled | disabled (enhanced adds per-task metrics at extra CloudWatch cost)."
  type        = string
  default     = "enhanced"
}

variable "app_environment" {
  description = "Extra non-secret env merged into the task definition (rolled out by the next CI deploy). Not for SRE_FAULT_* drills: deploy/ecs/render-taskdef.sh drops them — use deploy-ecs.yml extra_env per deploy."
  type        = map(string)
  default     = {}
}

variable "sre_lab_enabled" {
  description = "SRE_LAB_ENABLED (/sre-lab/* endpoints + env fault injection; token-protected)."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------- deployments

variable "deployment_controller" {
  description = "ECS (rolling / native blue-green / linear / canary) or CODE_DEPLOY (scenario 54)."
  type        = string
  default     = "ECS"
}

variable "deployment_strategy" {
  description = "ECS controller: ROLLING (53), BLUE_GREEN / LINEAR / CANARY (55, ECS-native). CODE_DEPLOY controller = scenario 54."
  type        = string
  default     = "ROLLING"
}

variable "bake_time_in_minutes" {
  description = "Native strategies: minutes blue survives after the switch. CODE_DEPLOY: termination wait time."
  type        = number
  default     = 5
}

variable "canary_percent" {
  description = "CANARY: first traffic share for green."
  type        = number
  default     = 10
}

variable "linear_step_percent" {
  description = "LINEAR: traffic per step."
  type        = number
  default     = 25
}

variable "codedeploy_deployment_config_name" {
  description = "CODE_DEPLOY: CodeDeployDefault.ECSAllAtOnce | ECSCanary10Percent5Minutes | ECSLinear10PercentEvery1Minutes | ..."
  type        = string
  default     = "CodeDeployDefault.ECSAllAtOnce"
}

variable "use_deployment_alarms" {
  description = "Wire the ALB 5xx-ratio alarm into the deployment (ECS deployment alarms or CodeDeploy alarms) so a healthy-but-bad release rolls back (scenarios 53–55)."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------- data / ops

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.micro"
}

variable "alarm_email" {
  description = "Optional e-mail for the alerts topic."
  type        = string
  default     = null
}

variable "enable_fis" {
  description = "Create the AWS FIS 'stop 50% of the tasks' experiment template (scenario 75). Free until started."
  type        = bool
  default     = false
}
