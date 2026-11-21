variable "project" {
  description = "Project name (CONVENTIONS §1)."
  type        = string
  default     = "student-app"
}

variable "env" {
  description = "Environment tag. bootstrap is account-wide and long-lived; the tag just keeps the convention."
  type        = string
  default     = "lab"
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "scenario" {
  description = "Scenario tag value (bootstrap covers scenarios 02, 30, 80)."
  type        = string
  default     = "02"
}

variable "github_repo" {
  description = "GitHub repository (owner/name) allowed to assume the roles via OIDC. Case-sensitive."
  type        = string
  default     = "Ahmed-Reda-Ragab/StudentHub"

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repo))
    error_message = "github_repo must look like owner/name."
  }
}

# ---------------------------------------------------------------- who may assume what

variable "ci_branches" {
  description = "Branches whose workflows may push images (student-app-gha-ci). ci.yml pushes from main/master only."
  type        = list(string)
  default     = ["main", "master"]
}

variable "deploy_branches" {
  description = "Branches allowed to assume student-app-gha-deploy (jobs WITHOUT a GitHub environment)."
  type        = list(string)
  default     = ["main", "master"]
}

variable "deploy_environments" {
  description = "GitHub environments allowed to assume student-app-gha-deploy (CONVENTIONS §9: lab, production)."
  type        = list(string)
  default     = ["lab", "production"]
}

variable "terraform_branches" {
  description = "Branches allowed to assume the ADMIN terraform role WITHOUT an environment. Empty by default: a branch subject would let any job on that branch skip the `lab` environment's required reviewers — only environment:<name> subjects (apply/destroy jobs) get admin."
  type        = list(string)
  default     = []
}

variable "terraform_environments" {
  description = "GitHub environments allowed to assume the ADMIN terraform role (apply/destroy jobs)."
  type        = list(string)
  default     = ["lab"]
}

variable "create_terraform_plan_role" {
  description = "Create student-app-gha-terraform-plan (read-only) for PR / dispatch plans from any branch."
  type        = bool
  default     = true
}

variable "app_environments" {
  description = "Environments whose task roles the deploy role may pass to ECS (role/<project>-<env>-*)."
  type        = list(string)
  default     = ["lab"]
}

# ---------------------------------------------------------------- toggles

variable "create_github_oidc_provider" {
  description = "Create the GitHub OIDC provider. Set false if the account already has one (only one per URL is allowed)."
  type        = bool
  default     = true
}

variable "create_codeconnection" {
  description = "Create the CodeConnections GitHub connection used by CodePipeline (scenario 36). Free."
  type        = bool
  default     = true
}

variable "ecr_repository_name" {
  description = "ECR repository name (CONVENTIONS §2)."
  type        = string
  default     = "student-app"
}

variable "ecr_force_delete" {
  description = "Allow destroying the ECR repository while it still holds images."
  type        = bool
  default     = false
}

variable "state_bucket_force_destroy" {
  description = "Allow destroying the state bucket while it still holds objects. Keep false: losing state orphans every stack."
  type        = bool
  default     = false
}

variable "state_noncurrent_days" {
  description = "Days to keep old (noncurrent) state versions — your undo button for a corrupted state."
  type        = number
  default     = 90
}
