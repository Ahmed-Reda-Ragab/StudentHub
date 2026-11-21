terraform {
  required_version = ">= 1.11" # S3 native locking (use_lockfile) is GA since 1.11

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # Within the CONVENTIONS ~> 6.0 range, but ECS-native LINEAR/CANARY need >= 6.21 (Nov 2025).
      version = "~> 6.21"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Partial backend: bucket/region/use_lockfile from ../../backend.hcl
  #   terraform init -backend-config=../../backend.hcl
  backend "s3" {
    key = "stacks/50-ecs-fargate/terraform.tfstate"
  }
}
