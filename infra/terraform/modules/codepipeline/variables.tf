variable "name" {
  description = "Pipeline name, e.g. student-app-lab-ecs."
  type        = string
}

variable "codeconnections_arn" {
  description = "CodeConnections (GitHub) connection ARN from the bootstrap stack."
  type        = string
}

variable "github_repo" {
  description = "owner/repo."
  type        = string
}

variable "branch" {
  description = "Branch that triggers the pipeline."
  type        = string
  default     = "master"
}

variable "trigger_file_path_excludes" {
  description = "Pushes touching ONLY these paths do not start the pipeline (V2 trigger filter)."
  type        = list(string)
  default     = ["docs/**", "**/*.md"]
}

variable "execution_mode" {
  description = "QUEUED (each commit deploys in order, a running deploy is never interrupted), SUPERSEDED or PARALLEL."
  type        = string
  default     = "QUEUED"

  validation {
    condition     = contains(["QUEUED", "SUPERSEDED", "PARALLEL"], var.execution_mode)
    error_message = "execution_mode must be QUEUED, SUPERSEDED or PARALLEL."
  }
}

variable "build_project_name" {
  description = "CodeBuild project (source CODEPIPELINE) running deploy/codebuild/buildspec-build.yml."
  type        = string
}

variable "deploy_mode" {
  description = <<-EOT
    ecs            ECS standard deploy action with imagedefinitions.json (rolling / native strategy of the service)  (36)
    codedeploy-ecs CodeDeployToECS: taskdef.json + appspec.yaml, <IMAGE1_NAME> placeholder (service on CODE_DEPLOY) (58)
    codebuild      CodeBuild runs buildspec-deploy-ecs.yml: migrations + update-service + wait                     (36b)
  EOT
  type        = string
  default     = "ecs"

  validation {
    condition     = contains(["ecs", "codedeploy-ecs", "codebuild"], var.deploy_mode)
    error_message = "deploy_mode must be ecs, codedeploy-ecs or codebuild."
  }
}

variable "migrate_project_name" {
  description = "CodeBuild project running buildspec-deploy-ecs.yml with DEPLOY_STEP=migrate before the deploy action (ecs / codedeploy-ecs). null = no migration step."
  type        = string
  default     = null
}

variable "deploy_project_name" {
  description = "deploy_mode = codebuild: CodeBuild project running buildspec-deploy-ecs.yml (DEPLOY_STEP=all)."
  type        = string
  default     = null

  validation {
    condition     = var.deploy_mode != "codebuild" || var.deploy_project_name != null
    error_message = "deploy_project_name is required when deploy_mode = codebuild."
  }
}

variable "ecs_cluster_name" {
  description = "ECS cluster (stack 50 output cluster_name)."
  type        = string
  default     = null
}

variable "ecs_service_name" {
  description = "ECS service (stack 50 output service_name)."
  type        = string
  default     = null

  validation {
    condition     = var.deploy_mode != "ecs" || var.ecs_service_name != null
    error_message = "ecs_cluster_name and ecs_service_name are required when deploy_mode = ecs."
  }
}

variable "codedeploy_app_name" {
  description = "deploy_mode = codedeploy-ecs: CodeDeploy application (stack 50 output codedeploy_app_name)."
  type        = string
  default     = null
}

variable "codedeploy_deployment_group_name" {
  description = "deploy_mode = codedeploy-ecs: deployment group (stack 50 output codedeploy_deployment_group_name)."
  type        = string
  default     = null

  validation {
    condition     = var.deploy_mode != "codedeploy-ecs" || var.codedeploy_deployment_group_name != null
    error_message = "codedeploy_app_name and codedeploy_deployment_group_name are required when deploy_mode = codedeploy-ecs."
  }
}

variable "pass_role_arns" {
  description = "Task execution + task role ARNs. The ECS / CodeDeployToECS actions register a task definition and must pass these roles to ECS."
  type        = list(string)
  default     = []
}

variable "deployment_timeout_minutes" {
  description = "ECS deploy action timeout (1-60): how long CodePipeline waits for the service to stabilise."
  type        = number
  default     = 30
}

variable "require_approval" {
  description = "Insert a Manual approval stage between Build and Deploy (scenario 36: promotion gate)."
  type        = bool
  default     = false
}

variable "approval_sns_topic_arn" {
  description = "Optional SNS topic notified when an approval is pending."
  type        = string
  default     = null
}

variable "artifact_retention_days" {
  description = "Pipeline artifacts (source zips, imagedefinitions.json) expire after N days."
  type        = number
  default     = 14
}
