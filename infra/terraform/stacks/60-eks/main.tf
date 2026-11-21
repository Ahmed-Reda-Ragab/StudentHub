# Stack 60 — Amazon EKS (scenarios 60-6A).
# terraform-aws-modules/vpc v6 + terraform-aws-modules/eks v21 (v21 renamed the cluster_* inputs:
# name, kubernetes_version, endpoint_public_access, addons, ...), managed node group, EKS add-ons,
# Pod Identity (pod-identity.tf), optional Karpenter + Helm releases (addons.tf), RDS + SSM (ssm.tf).

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"] # no Local Zones
  }
}

locals {
  name       = "${var.project}-${var.env}" # student-app-lab
  partition  = data.aws_partition.current.partition
  account_id = data.aws_caller_identity.current.account_id
  cluster_admins = distinct(concat(
    var.cluster_admin_principal_arns,
    var.grant_github_deploy_role ? ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${var.project}-gha-deploy"] : [],
  ))
  ssm_prefix = "/${var.project}/${var.env}/app"
  azs        = slice(data.aws_availability_zones.available.names, 0, 2)

  node_subnet_ids = var.enable_nat ? module.vpc.private_subnets : module.vpc.public_subnets

  karpenter_discovery = var.enable_karpenter ? { "karpenter.sh/discovery" = local.name } : {}
}

# ---------------------------------------------------------------- VPC

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.8"

  name = local.name
  cidr = var.vpc_cidr
  azs  = local.azs

  # /20 subnets: room for pod IPs (VPC CNI prefix delegation hands out /28 blocks).
  public_subnets  = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 4, i)]
  private_subnets = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 4, i + 8)]

  enable_nat_gateway      = var.enable_nat
  single_nat_gateway      = true
  map_public_ip_on_launch = !var.enable_nat # nodes in public subnets need a public IP to pull images

  enable_dns_hostnames = true
  enable_dns_support   = true

  # AWS Load Balancer Controller subnet discovery (+ Karpenter on the node subnets).
  public_subnet_tags = merge(
    { "kubernetes.io/role/elb" = "1" },
    var.enable_nat ? {} : local.karpenter_discovery,
  )
  private_subnet_tags = merge(
    { "kubernetes.io/role/internal-elb" = "1" },
    var.enable_nat ? local.karpenter_discovery : {},
  )
}

# ---------------------------------------------------------------- EKS

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.30"

  name               = local.name
  kubernetes_version = var.kubernetes_version
  # STANDARD: auto-upgrade at end of standard support instead of paying extended support (6x the price).
  upgrade_policy = { support_type = "STANDARD" }

  endpoint_public_access       = true # kubectl from a laptop / GitHub runner (v21 defaults to false)
  endpoint_private_access      = true
  endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs

  enabled_log_types                      = var.control_plane_log_types
  cloudwatch_log_group_retention_in_days = 7
  kms_key_deletion_window_in_days        = 7 # secrets envelope encryption key; short window for an ephemeral lab

  # Pod Identity instead of IRSA: no OIDC provider, no role trust per service account.
  enable_irsa = false

  # Terraform's identity becomes cluster admin (needed by the Helm provider) + optional extra admins.
  enable_cluster_creator_admin_permissions = true
  # The GitHub deploy role (deploy-eks.yml) needs cluster scope: it creates the Namespace and
  # the ClusterSecretStore. Disable with grant_github_deploy_role = false.
  access_entries = {
    for i, arn in local.cluster_admins : "admin-${i}" => {
      principal_arn = arn
      policy_associations = {
        admin = {
          policy_arn   = "arn:${local.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = local.node_subnet_ids
  control_plane_subnet_ids = module.vpc.private_subnets

  addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni = {
      before_compute = true
      # Prefix delegation: a t3.medium goes from 17 to 110 pods (ENI IP limits) — Argo CD +
      # Prometheus + the app would not fit on 2 nodes otherwise.
      configuration_values = jsonencode({
        # Enforce NetworkPolicy objects (the Helm chart ships one) — off by default in EKS.
        enableNetworkPolicy = "true"
        env = {
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
      })
    }
    eks-pod-identity-agent = {
      before_compute = true # credentials for LBC / ESO / Karpenter pods
    }
    metrics-server = {} # EKS community add-on: kubectl top + HPA (scenario 6A)
  }

  eks_managed_node_groups = {
    default = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = var.node_instance_types
      capacity_type  = var.node_capacity_type
      min_size       = var.node_min_size
      max_size       = var.node_max_size
      desired_size   = var.node_desired_size
      subnet_ids     = local.node_subnet_ids

      labels = merge(
        { "student-app/pool" = "default" },
        var.enable_karpenter ? { "karpenter.sh/controller" = "true" } : {},
      )

      # Shell on nodes through SSM Session Manager — no SSH key, no port 22.
      iam_role_additional_policies = {
        AmazonSSMManagedInstanceCore = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
      }
    }
  }

  node_security_group_tags = local.karpenter_discovery
}

# ---------------------------------------------------------------- database

module "rds" {
  source = "../../modules/rds-mysql"

  name                       = local.name
  vpc_id                     = module.vpc.vpc_id
  subnet_ids                 = module.vpc.private_subnets
  allowed_security_group_ids = [module.eks.node_security_group_id] # pods use the node SG (no SG-for-pods)
  instance_class             = var.db_instance_class
  ssm_prefix                 = local.ssm_prefix
}

# RDS alarms + dashboard only: the ALB belongs to the AWS Load Balancer Controller, not Terraform.
module "observability" {
  source = "../../modules/observability"

  name              = local.name
  alarm_email       = var.alarm_email
  enable_alb_alarms = false
  rds_instance_id   = module.rds.identifier
}
