# Optional cluster add-ons via Helm (install_addons = true, second apply). Chart versions are
# pinned in var.chart_versions; values are kept minimal and lab-sized.

locals {
  helm = {
    lbc        = var.install_addons && var.addons.aws_load_balancer_controller
    eso        = var.install_addons && var.addons.external_secrets
    rollouts   = var.install_addons && var.addons.argo_rollouts
    argocd     = var.install_addons && var.addons.argo_cd
    prometheus = var.install_addons && var.addons.kube_prometheus_stack
    karpenter  = var.install_addons && var.enable_karpenter
  }
}

# ---------------------------------------------------------------- Karpenter (scenario 6A)

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 21.30"
  count   = var.enable_karpenter ? 1 : 0

  cluster_name = module.eks.cluster_name

  # Controller credentials through Pod Identity (kube-system/karpenter).
  create_pod_identity_association = true

  # The EC2NodeClass (manifest in docs/devops/scenarios/6A-hpa-karpenter-under-load.md) references this role by name.
  node_iam_role_use_name_prefix = false
  node_iam_role_name            = "${local.name}-karpenter-node"
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }
}

resource "helm_release" "karpenter" {
  count = local.helm.karpenter ? 1 : 0

  name       = "karpenter"
  namespace  = "kube-system"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = var.chart_versions.karpenter
  wait       = false

  values = [yamlencode({
    nodeSelector = { "karpenter.sh/controller" = "true" } # never on nodes Karpenter itself manages
    dnsPolicy    = "Default"
    settings = {
      clusterName       = module.eks.cluster_name
      clusterEndpoint   = module.eks.cluster_endpoint
      interruptionQueue = module.karpenter[0].queue_name # Spot interruption / rebalance events
    }
    webhook = { enabled = false }
  })]

  depends_on = [module.eks]
}

# ---------------------------------------------------------------- AWS Load Balancer Controller (scenario 63)

resource "helm_release" "aws_load_balancer_controller" {
  count = local.helm.lbc ? 1 : 0

  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.chart_versions.aws_load_balancer_controller

  values = [yamlencode({
    clusterName = module.eks.cluster_name
    # Explicit region/VPC: IMDSv2 hop limit 1 on the nodes keeps pods away from instance metadata.
    region       = var.region
    vpcId        = module.vpc.vpc_id
    replicaCount = 1 # lab: one replica saves a pod slot; 2 for anything real
    serviceAccount = {
      create = true
      name   = aws_eks_pod_identity_association.lbc.service_account
    }
  })]

  depends_on = [module.eks, aws_iam_role_policy_attachment.lbc]
}

# ---------------------------------------------------------------- External Secrets Operator (scenario 64)

resource "helm_release" "external_secrets" {
  count = local.helm.eso ? 1 : 0

  name             = "external-secrets"
  namespace        = aws_eks_pod_identity_association.eso.namespace
  create_namespace = true
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = var.chart_versions.external_secrets

  values = [yamlencode({
    installCRDs    = true
    serviceAccount = { create = true, name = aws_eks_pod_identity_association.eso.service_account }
  })]

  depends_on = [module.eks, aws_iam_role_policy.eso]
}

# ---------------------------------------------------------------- Argo Rollouts (scenarios 67–68: blue-green / canary)

resource "helm_release" "argo_rollouts" {
  count = local.helm.rollouts ? 1 : 0

  name             = "argo-rollouts"
  namespace        = "argo-rollouts"
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-rollouts"
  version          = var.chart_versions.argo_rollouts

  values = [yamlencode({
    dashboard = { enabled = true } # kubectl -n argo-rollouts port-forward svc/argo-rollouts-dashboard 3100:3100
  })]

  depends_on = [module.eks]
}

# ---------------------------------------------------------------- Argo CD (scenario 69: GitOps)

resource "helm_release" "argo_cd" {
  count = local.helm.argocd ? 1 : 0

  name             = "argo-cd"
  namespace        = "argocd"
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.chart_versions.argo_cd

  values = [yamlencode({
    dex           = { enabled = false } # no SSO in the lab: admin password from argocd-initial-admin-secret
    notifications = { enabled = false }
    configs = {
      params = { "server.insecure" = true } # TLS terminates at the ALB / port-forward
    }
  })]

  depends_on = [module.eks]
}

# ---------------------------------------------------------------- kube-prometheus-stack (scenarios 71, 73: SLOs)

resource "helm_release" "kube_prometheus_stack" {
  count = local.helm.prometheus ? 1 : 0

  name             = "kube-prometheus-stack"
  namespace        = "monitoring"
  create_namespace = true
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = var.chart_versions.kube_prometheus_stack
  timeout          = 900 # CRDs + several deployments

  # Shared lab values first (PodMonitor for the student-app pods — the canary AnalysisTemplate
  # depends on it), then the EKS-specific overrides below (later values win).
  values = [file("${path.module}/../../../../observability/k8s/kube-prometheus-stack-values.yaml"), yamlencode({
    prometheus = {
      prometheusSpec = {
        # Pick up the student-app ServiceMonitor from any namespace/release.
        serviceMonitorSelectorNilUsesHelmValues = false
        podMonitorSelectorNilUsesHelmValues     = false
        ruleSelectorNilUsesHelmValues           = false
        retention                               = "2d"
        resources                               = { requests = { cpu = "200m", memory = "512Mi" } }
      }
    }
    alertmanager = { enabled = true }
    grafana      = { enabled = true }
  })]

  depends_on = [module.eks]
}
