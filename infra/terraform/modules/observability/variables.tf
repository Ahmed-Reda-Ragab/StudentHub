variable "name" {
  description = "Name prefix for alarms, topic and dashboard, e.g. student-app-lab."
  type        = string
}

variable "alarm_email" {
  description = "Optional e-mail subscribed to the alerts topic (AWS sends a confirmation mail first)."
  type        = string
  default     = null
}

# ---------------------------------------------------------------- ALB (front door SLIs)

variable "alb_arn_suffix" {
  description = "ALB ARN suffix (LoadBalancer dimension). Required while enable_alb_alarms = true."
  type        = string
  default     = null
}

variable "enable_alb_alarms" {
  description = <<-EOT
    Create the ALB-based alarms (5xx ratio, p95 latency, unhealthy hosts, SLO burn rate) and widgets.
    An explicit flag instead of "alb_arn_suffix != null" because the suffix is unknown until the ALB exists.
    Set false when there is no Terraform-managed ALB (e.g. EKS + AWS Load Balancer Controller).
  EOT
  type        = bool
  default     = true
}

variable "target_group_arn_suffixes" {
  description = "Target group ARN suffixes keyed by color, e.g. { blue = ..., green = ... } (one UnHealthyHostCount alarm each)."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------- compute (dashboard)

variable "asg_name" {
  description = "Optional Auto Scaling group name (dashboard CPU / capacity)."
  type        = string
  default     = null
}

variable "asg_names" {
  description = "Optional extra ASG names (blue + green)."
  type        = list(string)
  default     = []
}

variable "ecs_cluster_name" {
  description = "Optional ECS cluster name (dashboard CPU / memory)."
  type        = string
  default     = null
}

variable "ecs_service_name" {
  description = "Optional ECS service name (used with ecs_cluster_name)."
  type        = string
  default     = null
}

# ---------------------------------------------------------------- database

variable "rds_instance_id" {
  description = "Optional RDS DBInstanceIdentifier: adds CPU / free storage alarms and widgets."
  type        = string
  default     = null
}

variable "rds_cpu_threshold" {
  description = "RDS CPU % alarm threshold."
  type        = number
  default     = 80
}

variable "rds_free_storage_threshold_bytes" {
  description = "RDS free storage alarm threshold in bytes (default 2 GiB)."
  type        = number
  default     = 2147483648
}

# ---------------------------------------------------------------- SLOs (CONVENTIONS §5)

variable "slo_availability_target" {
  description = "Availability SLO in percent (error budget = 100 - target)."
  type        = number
  default     = 99.5

  validation {
    condition     = var.slo_availability_target > 90 && var.slo_availability_target < 100
    error_message = "slo_availability_target must be between 90 and 100 (exclusive)."
  }
}

variable "latency_p95_threshold_seconds" {
  description = "p95 TargetResponseTime alarm threshold (latency SLO: 95% of requests < 300 ms)."
  type        = number
  default     = 0.3
}

variable "error_ratio_threshold" {
  description = "5xx ratio (0-1) over 5 minutes that raises the plain error-rate alarm."
  type        = number
  default     = 0.01
}

# ---------------------------------------------------------------- logs

variable "log_group_name" {
  description = "Optional app log group (JSON logs, CONVENTIONS §2): adds an ERROR+ log-count metric filter."
  type        = string
  default     = null
}

variable "create_dashboard" {
  description = "Create the CloudWatch dashboard (first 3 dashboards per account are free, then 3 USD/month)."
  type        = bool
  default     = true
}
