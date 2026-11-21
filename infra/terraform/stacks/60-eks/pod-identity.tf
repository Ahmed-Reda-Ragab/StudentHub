# EKS Pod Identity (scenarios 63, 64): an IAM role per controller, bound to a namespace/service
# account by an association. The eks-pod-identity-agent add-on hands out the credentials —
# no OIDC provider, no annotations on the service account.

data "aws_iam_policy_document" "pod_identity_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

# ---------------------------------------------------------------- AWS Load Balancer Controller

resource "aws_iam_role" "lbc" {
  name               = "${local.name}-aws-load-balancer-controller"
  description        = "AWS Load Balancer Controller on ${local.name} (Pod Identity)"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json
}

# Official policy, unchanged — easier to diff on upgrades:
#   https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v3.6.3/docs/install/iam_policy.json
#   controller / chart version 3.6.3 (sha256 16f232c9d9f79366fe949c4550ad517a202380058a9e48d45a4e215044a20a6a)
resource "aws_iam_policy" "lbc" {
  name        = "${local.name}-aws-load-balancer-controller"
  description = "AWS Load Balancer Controller v3.6.3 (upstream iam_policy.json)"
  policy      = file("${path.module}/policies/aws-load-balancer-controller-iam-policy.json")
}

resource "aws_iam_role_policy_attachment" "lbc" {
  role       = aws_iam_role.lbc.name
  policy_arn = aws_iam_policy.lbc.arn
}

resource "aws_eks_pod_identity_association" "lbc" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.lbc.arn
}

# ---------------------------------------------------------------- External Secrets Operator

resource "aws_iam_role" "eso" {
  name               = "${local.name}-external-secrets"
  description        = "External Secrets Operator on ${local.name}: read ${local.ssm_prefix}/* only"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json
}

data "aws_iam_policy_document" "eso" {
  # Only the app subtree of THIS env: ESO cannot read another env or the mysql/deploy paths.
  statement {
    sid     = "ReadAppParameters"
    actions = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = [
      "arn:${local.partition}:ssm:${var.region}:${local.account_id}:parameter${local.ssm_prefix}",
      "arn:${local.partition}:ssm:${var.region}:${local.account_id}:parameter${local.ssm_prefix}/*",
    ]
  }

  # `find` / dataFrom in ExternalSecret lists parameter metadata (no values); not resource-scopable.
  statement {
    sid       = "DescribeParameters"
    actions   = ["ssm:DescribeParameters"]
    resources = ["*"]
  }

  statement {
    sid       = "DecryptSecureStringViaSsm"
    actions   = ["kms:Decrypt"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "eso" {
  name   = "read-app-parameters"
  role   = aws_iam_role.eso.id
  policy = data.aws_iam_policy_document.eso.json
}

resource "aws_eks_pod_identity_association" "eso" {
  cluster_name    = module.eks.cluster_name
  namespace       = "external-secrets"
  service_account = "external-secrets"
  role_arn        = aws_iam_role.eso.arn
}
