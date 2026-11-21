variable "name" {
  description = "Name prefix, e.g. student-app-lab (ALB name max 32 chars, TG names get -blue/-green)."
  type        = string

  validation {
    condition     = length(var.name) <= 26
    error_message = "name must be <= 26 chars so \"<name>-green\" fits the 32-char target group limit."
  }
}

variable "vpc_id" {
  description = "VPC ID."
  type        = string
}

variable "subnet_ids" {
  description = "Public subnet IDs in at least 2 AZs."
  type        = list(string)
}

variable "certificate_arn" {
  description = "ACM certificate ARN. When set (and https_enabled is not false): HTTPS listener + HTTP->HTTPS redirect."
  type        = string
  default     = null
}

variable "https_enabled" {
  description = <<-EOT
    Explicit HTTPS switch. Leave null to derive it from certificate_arn != null.
    Set it (e.g. to var.domain_name != null) when certificate_arn comes from a resource in the
    same plan: count cannot depend on a value that is unknown until apply.
  EOT
  type        = bool
  default     = null
}

variable "health_check_path" {
  description = "Target group health check path. /ready checks the DB, so a broken release never receives traffic."
  type        = string
  default     = "/ready"
}

variable "target_type" {
  description = "instance (EC2/ASG, scenarios 40-49) or ip (ECS awsvpc / EKS, scenarios 50+)."
  type        = string
  default     = "instance"

  validation {
    condition     = contains(["instance", "ip"], var.target_type)
    error_message = "target_type must be instance or ip."
  }
}

variable "target_port" {
  description = <<-EOT
    Port the ALB sends traffic to. 8080 = container port (ECS/EKS ip targets).
    EC2/ASG instance targets publish the container on host port 80 (-p 80:8080), so stack 40 passes 80.
  EOT
  type        = number
  default     = 8080
}

variable "blue_weight" {
  description = "Weight of the blue target group in the weighted forward action (0-999)."
  type        = number
  default     = 100

  validation {
    condition     = var.blue_weight >= 0 && var.blue_weight <= 999
    error_message = "blue_weight must be 0-999."
  }
}

variable "green_weight" {
  description = "Weight of the green target group. Blue/green = 100/0 -> 0/100; canary = 90/10 (scenarios 44-46)."
  type        = number
  default     = 0

  validation {
    condition     = var.green_weight >= 0 && var.green_weight <= 999
    error_message = "green_weight must be 0-999."
  }
}

variable "stickiness_duration" {
  description = "Target-group-level stickiness in seconds for the weighted action (0 = off). Keeps a canary user on one version."
  type        = number
  default     = 0
}

variable "deregistration_delay" {
  description = "Seconds the ALB keeps draining in-flight requests from a deregistered target."
  type        = number
  default     = 30
}

variable "ingress_cidrs" {
  description = "CIDRs allowed to reach the ALB on 80/443."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "ssl_policy" {
  description = "TLS policy for the HTTPS listener."
  type        = string
  default     = "ELBSecurityPolicy-TLS13-1-2-2021-06"
}

variable "idle_timeout" {
  description = "ALB idle timeout in seconds (must exceed the slowest /sre-lab/latency call you plan to make)."
  type        = number
  default     = 60
}

variable "enable_deletion_protection" {
  description = "ALB deletion protection. false in the lab so terraform destroy works."
  type        = bool
  default     = false
}

variable "access_logs_bucket" {
  description = "Optional S3 bucket for ALB access logs (bucket policy must allow the regional ELB principal)."
  type        = string
  default     = null
}

variable "weights_managed_externally" {
  description = "true when CodeDeploy / ECS deployments / CI own the blue-green weights: Terraform creates the listener once and ignores later default_action changes (no drift reverting a deployment)."
  type        = bool
  default     = false
}
