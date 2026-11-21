variable "project" {
  description = "Project name (CONVENTIONS §1)."
  type        = string
  default     = "student-app"
}

variable "env" {
  description = "Environment deployed by this pipeline."
  type        = string
  default     = "lab"
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "scenario" {
  description = "Scenario tag value (36, 37, 58)."
  type        = string
  default     = "36"
}

variable "github_repo" {
  description = "owner/repo (CONVENTIONS §1)."
  type        = string
  default     = "Ahmed-Reda-Ragab/StudentHub"
}

variable "codeconnections_arn" {
  description = "Bootstrap output codeconnections_arn (connection must be AVAILABLE)."
  type        = string
}

variable "branch" {
  description = "Branch that triggers the pipeline."
  type        = string
  default     = "master"
}

variable "deploy_mode" {
  description = "ecs (ECS deploy action) | codedeploy-ecs (CodeDeployToECS; stack 50 with deployment_controller = CODE_DEPLOY) | codebuild (CodeBuild deployer)."
  type        = string
  default     = "ecs"
}

variable "run_migrations" {
  description = "Run deploy/ecs/run-migrations.sh (CodeBuild, DEPLOY_STEP=migrate) before the ecs / codedeploy-ecs deploy action."
  type        = bool
  default     = true
}

variable "require_approval" {
  description = "Manual approval stage between Build and Deploy."
  type        = bool
  default     = false
}

variable "approval_sns_topic_arn" {
  description = "Optional SNS topic for approval notifications (e.g. stack 50 output of modules/observability)."
  type        = string
  default     = null
}

variable "taskdef_source" {
  description = "codedeploy-ecs: repo = render deploy/ecs/taskdef.json | live = copy the newest revision of task_family."
  type        = string
  default     = "repo"

  validation {
    condition     = contains(["repo", "live"], var.taskdef_source)
    error_message = "taskdef_source must be repo or live."
  }
}

variable "ecr_repository_name" {
  description = "ECR repository (bootstrap)."
  type        = string
  default     = "student-app"
}

variable "build_image" {
  description = "CodeBuild image."
  type        = string
  default     = "aws/codebuild/standard:8.0"
}

# ---------------------------------------------------------------- from stack 50
# terraform -chdir=../50-ecs-fargate output -json pipeline_inputs > stack50.auto.tfvars.json
# null = the name stack 50 derives from project/env (student-app-lab, student-app-lab-app, ...).

variable "ecs_cluster_name" {
  description = "Stack 50 output cluster_name."
  type        = string
  default     = null
}

variable "ecs_service_name" {
  description = "Stack 50 output service_name."
  type        = string
  default     = null
}

variable "task_family" {
  description = "Stack 50 output task_family."
  type        = string
  default     = null
}

variable "task_execution_role_arn" {
  description = "Stack 50 pipeline_inputs.task_execution_role_arn."
  type        = string
  default     = null
}

variable "task_role_arn" {
  description = "Stack 50 pipeline_inputs.task_role_arn."
  type        = string
  default     = null
}

variable "app_log_group_arn" {
  description = "Stack 50 pipeline_inputs.app_log_group_arn (migration logs are printed in the build log)."
  type        = string
  default     = null
}

variable "codedeploy_app_name" {
  description = "Stack 50 output codedeploy_app_name (deploy_mode = codedeploy-ecs)."
  type        = string
  default     = null
}

variable "codedeploy_deployment_group_name" {
  description = "Stack 50 output codedeploy_deployment_group_name (deploy_mode = codedeploy-ecs)."
  type        = string
  default     = null
}
