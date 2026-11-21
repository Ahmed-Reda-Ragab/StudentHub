variable "name_prefix" {
  description = "Project names become <name_prefix>-<key>, e.g. student-app-ci."
  type        = string
}

variable "github_repo" {
  description = "owner/repo (CONVENTIONS §1: Ahmed-Reda-Ragab/StudentHub)."
  type        = string
}

variable "codeconnections_arn" {
  description = "CodeConnections (GitHub App) connection ARN from the bootstrap stack. Required for GITHUB-source projects."
  type        = string
  default     = null
}

variable "build_image" {
  description = "Default CodeBuild image. standard:8.0 = Ubuntu 24.04 (same family as GitHub's ubuntu-latest), PHP 8.2-8.5 runtimes + Docker."
  type        = string
  default     = "aws/codebuild/standard:8.0"
}

variable "ecr_repository_arn" {
  description = "ECR repository projects with ecr_push = true may push to (and read, for 'tag already exists' checks)."
  type        = string
  default     = null
}

variable "artifact_bucket_arn" {
  description = "CodePipeline artifact bucket. Required for CODEPIPELINE-source projects (read input / write output artifacts)."
  type        = string
  default     = null
}

variable "log_retention_days" {
  description = "Retention of /aws/codebuild/<project> log groups."
  type        = number
  default     = 14
}

variable "projects" {
  description = <<-EOT
    Map of project key -> settings. One IAM role per project (least privilege: the CI project cannot
    push images, the runner cannot touch ECR unless asked).
      source_type     GITHUB (webhooks, CodeConnections auth) | CODEPIPELINE (pipeline input artifacts)
      buildspec       path in the repo; null for a GitHub Actions runner project
      ecr_push        grant push to ecr_repository_arn
      test_reports    grant CodeBuild report groups (JUnit from `php artisan test --log-junit`)
      webhook         filter_groups = list of groups, each a list of { type, pattern, exclude_matched_pattern }
      extra_policy_json  additional inline policy (e.g. ECS deploy permissions)
  EOT
  type = map(object({
    description               = string
    source_type               = optional(string, "GITHUB")
    buildspec                 = optional(string)
    git_clone_depth           = optional(number, 1)
    image                     = optional(string)
    compute_type              = optional(string, "BUILD_GENERAL1_SMALL")
    privileged_mode           = optional(bool, false)
    build_timeout             = optional(number, 30)
    queued_timeout            = optional(number, 60)
    concurrent_build_limit    = optional(number)
    cache_modes               = optional(list(string), [])
    environment_variables     = optional(map(string), {})
    parameter_store_variables = optional(map(string), {})
    ecr_push                  = optional(bool, false)
    test_reports              = optional(bool, false)
    extra_policy_json         = optional(string)
    webhook = optional(object({
      build_type = optional(string, "BUILD")
      filter_groups = list(list(object({
        type                    = string
        pattern                 = string
        exclude_matched_pattern = optional(bool, false)
      })))
    }))
  }))

  validation {
    condition     = alltrue([for p in values(var.projects) : contains(["GITHUB", "CODEPIPELINE"], p.source_type)])
    error_message = "source_type must be GITHUB or CODEPIPELINE."
  }

  validation {
    condition     = alltrue([for p in values(var.projects) : p.webhook == null || p.source_type == "GITHUB"])
    error_message = "Webhooks are only valid on GITHUB-source projects (CodePipeline starts CODEPIPELINE projects)."
  }
}
