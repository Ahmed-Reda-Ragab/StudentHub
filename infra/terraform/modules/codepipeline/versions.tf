terraform {
  required_version = ">= 1.11" # S3 native locking (use_lockfile) is GA since 1.11

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }
}
