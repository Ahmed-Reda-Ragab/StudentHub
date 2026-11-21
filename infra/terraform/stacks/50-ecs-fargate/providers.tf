provider "aws" {
  region = var.region

  # Mandatory tags (CONVENTIONS §1). ECS tasks get them through propagate_tags = "SERVICE".
  default_tags {
    tags = {
      Project   = var.project
      Env       = var.env
      ManagedBy = "terraform"
      Scenario  = var.scenario
    }
  }
}
