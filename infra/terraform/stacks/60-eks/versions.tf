terraform {
  required_version = ">= 1.11" # S3 native locking (use_lockfile) is GA since 1.11

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # terraform-aws-modules/eks v21.30 requires aws >= 6.59 (still inside the CONVENTIONS ~> 6.0 range).
      version = "~> 6.59"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.1" # v3: `kubernetes = { ... }` and `set = [...]` are attributes, not blocks
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Partial backend: bucket/region/use_lockfile from ../../backend.hcl
  #   terraform init -backend-config=../../backend.hcl
  backend "s3" {
    key = "stacks/60-eks/terraform.tfstate"
  }
}
