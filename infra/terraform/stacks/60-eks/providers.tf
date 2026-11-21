provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project
      Env       = var.env
      ManagedBy = "terraform"
      Scenario  = var.scenario
    }
  }
}

# Helm talks to the cluster created in this same stack. Short-lived token from `aws eks get-token`
# (AWS CLI needed where Terraform runs); the identity running Terraform is cluster admin through
# enable_cluster_creator_admin_permissions. Recommended: first apply with install_addons = false,
# then flip it to true (the cluster must exist before Helm can reach it).
provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
    }
  }
}
