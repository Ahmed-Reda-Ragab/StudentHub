terraform {
  required_version = ">= 1.11" # S3 native locking (use_lockfile) is GA since 1.11

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Partial backend config: bucket/region/use_lockfile come from ../../backend.hcl
  #   terraform init -backend-config=../../backend.hcl
  # The key is pinned here so one backend.hcl serves every stack and two stacks can never
  # share a state file by accident (CI passes the same key explicitly).
  backend "s3" {
    key = "stacks/40-ec2-alb-asg/terraform.tfstate"
  }
}
