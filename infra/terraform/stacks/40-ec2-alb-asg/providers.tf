provider "aws" {
  region = var.region

  # Mandatory tags (CONVENTIONS §1). Note: ASG-launched instances do not inherit these;
  # modules/asg-app copies them into the launch template tag_specifications.
  default_tags {
    tags = {
      Project   = var.project
      Env       = var.env
      ManagedBy = "terraform"
      Scenario  = var.scenario
    }
  }
}
