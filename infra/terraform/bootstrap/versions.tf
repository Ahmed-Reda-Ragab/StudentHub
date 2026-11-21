terraform {
  required_version = ">= 1.11" # S3 native locking (use_lockfile) is GA since 1.11

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Chicken-and-egg: this stack CREATES the state bucket, so the first apply uses local state.
  # After it, migrate (see README.md):
  #   1. uncomment the block below
  #   2. terraform init -migrate-state -backend-config=../backend.hcl
  #   3. delete the local terraform.tfstate* files once `terraform plan` shows no changes
  #
  # backend "s3" {
  #   key = "bootstrap/terraform.tfstate"
  # }
}
