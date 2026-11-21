variable "project" {
  description = "Project name; projects are <project>-ci, <project>-image, <project>-gha-runner."
  type        = string
  default     = "student-app"
}

variable "env" {
  description = "Environment (tags, ENV_NAME for buildspec-build.yml)."
  type        = string
  default     = "lab"
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "scenario" {
  description = "Scenario tag value."
  type        = string
  default     = "35"
}

variable "github_repo" {
  description = "owner/repo (CONVENTIONS §1)."
  type        = string
  default     = "Ahmed-Reda-Ragab/StudentHub"
}

variable "codeconnections_arn" {
  description = "Bootstrap output codeconnections_arn (the connection must be AVAILABLE: approve it once in the console)."
  type        = string
}

variable "ecr_repository_name" {
  description = "ECR repository (bootstrap)."
  type        = string
  default     = "student-app"
}

variable "build_image" {
  description = "CodeBuild image: standard:8.0 = Ubuntu 24.04, PHP 8.2-8.5, Docker."
  type        = string
  default     = "aws/codebuild/standard:8.0"
}

variable "ci_branches" {
  description = "Branches whose pushes trigger the CI project (pull requests always do)."
  type        = list(string)
  default     = ["master", "main", "devops-lab"]
}

variable "enable_ci_webhook" {
  description = "Run student-app-ci on every push to ci_branches and on pull requests (mirrors ci.yml)."
  type        = bool
  default     = true
}

variable "enable_image_webhook" {
  description = "Build + push the image on pushes to image_branch. Off by default: GitHub Actions CI already pushes; start builds by hand."
  type        = bool
  default     = false
}

variable "image_branch" {
  description = "Branch for enable_image_webhook."
  type        = string
  default     = "master"
}

variable "enable_gha_runner" {
  description = "Create student-app-gha-runner: a CodeBuild-hosted GitHub Actions runner (webhook WORKFLOW_JOB_QUEUED)."
  type        = bool
  default     = false
}

variable "gha_runner_ecr_push" {
  description = "Let jobs on the CodeBuild runner push to ECR with the project role (no OIDC needed)."
  type        = bool
  default     = false
}

variable "dockerhub_username_parameter" {
  description = "Optional SSM parameter name holding a Docker Hub username (avoids anonymous pull limits on shared CodeBuild IPs)."
  type        = string
  default     = null
}

variable "dockerhub_token_parameter" {
  description = "Optional SSM SecureString parameter name holding a Docker Hub access token."
  type        = string
  default     = null
}
