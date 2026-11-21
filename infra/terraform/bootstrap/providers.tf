provider "aws" {
  region = var.region

  # Mandatory tags (CONVENTIONS §1) on everything this stack creates.
  default_tags {
    tags = {
      Project   = var.project
      Env       = var.env
      ManagedBy = "terraform"
      Scenario  = var.scenario
    }
  }
}
