output "cluster_name" {
  description = "EKS cluster (repo variable EKS_CLUSTER)."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "API server endpoint."
  value       = module.eks.cluster_endpoint
}

output "kubernetes_version" {
  description = "Control plane version."
  value       = module.eks.cluster_version
}

output "region" {
  description = "AWS region."
  value       = var.region
}

output "update_kubeconfig" {
  description = "Configure kubectl."
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "vpc_id" {
  description = "VPC ID."
  value       = module.vpc.vpc_id
}

output "node_security_group_id" {
  description = "Node security group (pods share it)."
  value       = module.eks.node_security_group_id
}

output "rds_address" {
  description = "RDS endpoint (private subnets)."
  value       = module.rds.address
}

output "ssm_prefix" {
  description = "SSM path ESO reads (ClusterSecretStore / ExternalSecret)."
  value       = local.ssm_prefix
}

output "pod_identity_roles" {
  description = "IAM roles bound through Pod Identity."
  value = {
    aws_load_balancer_controller = aws_iam_role.lbc.arn
    external_secrets             = aws_iam_role.eso.arn
    karpenter                    = try(module.karpenter[0].iam_role_arn, null)
  }
}

output "karpenter" {
  description = "Values the Karpenter NodePool/EC2NodeClass manifests need (null when disabled)."
  value = var.enable_karpenter ? {
    node_role       = module.karpenter[0].node_iam_role_name
    discovery_tag   = local.name # karpenter.sh/discovery on subnets + node SG
    interrupt_queue = module.karpenter[0].queue_name
  } : null
}

output "cluster_secret_store_manifest" {
  description = "ClusterSecretStore for ESO (kubectl apply -f -); credentials come from Pod Identity, no auth block needed."
  value       = <<-EOT
    apiVersion: external-secrets.io/v1
    kind: ClusterSecretStore
    metadata:
      name: aws-parameter-store
    spec:
      provider:
        aws:
          service: ParameterStore
          region: ${var.region}
  EOT
}
