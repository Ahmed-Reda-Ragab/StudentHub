variable "project" {
  description = "Project name (CONVENTIONS §1)."
  type        = string
  default     = "student-app"
}

variable "env" {
  description = "Environment; also the SSM path segment (/student-app/<env>/app/*)."
  type        = string
  default     = "lab"
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "scenario" {
  description = "Scenario tag value (60-6A)."
  type        = string
  default     = "60"
}

# ---------------------------------------------------------------- network

variable "vpc_cidr" {
  description = "VPC CIDR (/16: the VPC CNI gives every pod a VPC IP)."
  type        = string
  default     = "10.60.0.0/16"
}

variable "enable_nat" {
  description = <<-EOT
    false (default): nodes in PUBLIC subnets with public IPs (inbound limited by the node SG) — no NAT.
    true: nodes in PRIVATE subnets behind one NAT gateway (~32 USD/month + data, the production layout).
  EOT
  type        = bool
  default     = false
}

# ---------------------------------------------------------------- cluster

variable "kubernetes_version" {
  description = "EKS version. 1.36 = standard support until Aug 2027 (1.34-1.37 are in standard support, Nov 2026); one behind latest for chart compatibility."
  type        = string
  default     = "1.36"
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "CIDRs allowed to reach the public API endpoint (set to your IP/32)."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "cluster_admin_principal_arns" {
  description = "Extra IAM principals with cluster-admin access entries (e.g. the GitHub deploy role for scenario 65)."
  type        = list(string)
  default     = []
}

variable "control_plane_log_types" {
  description = "Control plane logs to CloudWatch (each type costs ingestion)."
  type        = list(string)
  default     = ["api", "audit", "authenticator"]
}

variable "node_instance_types" {
  description = "Managed node group instance types (more than one helps Spot availability)."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_capacity_type" {
  description = "ON_DEMAND or SPOT (scenario 62: ~60-70% cheaper, 2-minute interruption notice)."
  type        = string
  default     = "ON_DEMAND"

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.node_capacity_type)
    error_message = "node_capacity_type must be ON_DEMAND or SPOT."
  }
}

variable "node_min_size" {
  description = "Minimum nodes."
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum nodes."
  type        = number
  default     = 4
}

variable "node_desired_size" {
  description = "Initial nodes (cluster autoscaling / Karpenter own it later)."
  type        = number
  default     = 2
}

variable "enable_karpenter" {
  description = "Karpenter controller IAM/SQS (module) + Helm chart (when install_addons). NodePool/EC2NodeClass manifests: docs/devops/scenarios/6A-hpa-karpenter-under-load.md."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------- Helm add-ons

variable "install_addons" {
  description = "Install the Helm releases below. Leave false on the first apply (cluster first, then add-ons)."
  type        = bool
  default     = false
}

variable "addons" {
  description = "Which Helm releases install_addons installs. kube-prometheus-stack + argo-cd are heavy for 2x t3.medium."
  type = object({
    aws_load_balancer_controller = optional(bool, true)
    external_secrets             = optional(bool, true)
    argo_rollouts                = optional(bool, true)
    argo_cd                      = optional(bool, false)
    kube_prometheus_stack        = optional(bool, false)
  })
  default = {}
}

variable "chart_versions" {
  description = "Pinned chart versions (checked Nov 2026 on Artifact Hub). Bump deliberately, one at a time."
  type = object({
    aws_load_balancer_controller = optional(string, "3.6.3")   # app v3.6.3, https://aws.github.io/eks-charts
    external_secrets             = optional(string, "2.15.0")  # app v2.15.0, https://charts.external-secrets.io
    argo_rollouts                = optional(string, "2.43.12") # app v1.10.2, https://argoproj.github.io/argo-helm
    argo_cd                      = optional(string, "10.18.2") # app v3.6.2
    kube_prometheus_stack        = optional(string, "93.6.1")  # https://prometheus-community.github.io/helm-charts
    karpenter                    = optional(string, "1.15.3")  # oci://public.ecr.aws/karpenter/karpenter
  })
  default = {}
}

# ---------------------------------------------------------------- app data

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.micro"
}

variable "app_url" {
  description = "APP_URL. Update it to the Ingress/ALB hostname once the AWS Load Balancer Controller created it."
  type        = string
  default     = "http://localhost"
}

variable "sre_lab_enabled" {
  description = "SRE_LAB_ENABLED."
  type        = bool
  default     = true
}

variable "alarm_email" {
  description = "Optional e-mail for the alerts topic (RDS alarms; ALB alarms are off: the ALB is created by the controller, not Terraform)."
  type        = string
  default     = null
}

variable "grant_github_deploy_role" {
  description = "Add an EKS access entry (cluster admin) for the bootstrap role <project>-gha-deploy used by .github/workflows/deploy-eks.yml."
  type        = bool
  default     = true
}
