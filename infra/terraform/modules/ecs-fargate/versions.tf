terraform {
  required_version = ">= 1.11" # S3 native locking (use_lockfile) is GA since 1.11

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # 6.4.0 added load_balancer.advanced_configuration (ECS native blue/green, July 2025);
      # 6.21.0 added deployment_configuration.linear/canary_configuration (Oct 2025).
      version = ">= 6.21"
    }
  }
}
