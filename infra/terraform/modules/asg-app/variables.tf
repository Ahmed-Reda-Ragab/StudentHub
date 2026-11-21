variable "name" {
  description = "ASG name, e.g. student-app-lab-blue (also the launch template / SG prefix)."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID."
  type        = string
}

variable "subnet_ids" {
  description = "Subnets the ASG spreads instances over (one per AZ)."
  type        = list(string)
}

variable "target_group_arns" {
  description = "ALB target groups this ASG registers into (normally just its own color's TG)."
  type        = list(string)
  default     = []
}

variable "image_uri" {
  description = "INITIAL value of /<project>/<env>/deploy/<color>/IMAGE_URI. CI owns the parameter afterwards (ignore_changes)."
  type        = string
}

variable "ami_id" {
  description = "Golden AMI from Packer (Docker preinstalled, scenario 43). null = latest Amazon Linux 2023."
  type        = string
  default     = null
}

variable "arch" {
  description = "Architecture of the default AL2023 AMI (x86_64 | arm64). Ignored when ami_id is set."
  type        = string
  default     = "x86_64"

  validation {
    condition     = contains(["x86_64", "arm64"], var.arch)
    error_message = "arch must be x86_64 or arm64."
  }
}

variable "instance_type" {
  description = "Instance type. Running (not building) the image fits in 1 GiB."
  type        = string
  default     = "t3.micro"
}

variable "min" {
  description = "ASG min size."
  type        = number
  default     = 1
}

variable "max" {
  description = "ASG max size."
  type        = number
  default     = 3
}

variable "desired" {
  description = "Initial desired capacity. Scaling policies own it afterwards (ignore_changes)."
  type        = number
  default     = 2
}

variable "ssm_prefix" {
  description = "SSM path rendered into /opt/student-app/app.env at boot, e.g. /student-app/lab/app."
  type        = string

  validation {
    condition     = startswith(var.ssm_prefix, "/")
    error_message = "ssm_prefix must start with '/'."
  }
}

variable "color" {
  description = "Deployment color: selects the IMAGE_URI parameter and sets DEPLOY_COLOR in the container."
  type        = string
  default     = "blue"
}

variable "image_parameter_name" {
  description = "Override for the IMAGE_URI parameter name. Default: <ssm_prefix without /app>/deploy/<color>/IMAGE_URI."
  type        = string
  default     = null
}

variable "wait_for" {
  description = <<-EOT
    Values (e.g. SSM parameter ARNs written by rds-mysql / elasticache-redis) that must exist
    before the first instance boots, so user data never renders an app.env without DB_HOST.
    Used instead of a module-level depends_on, which would defer this module's data sources
    (AMI lookup) to apply time and show a launch template change on every unrelated plan.
  EOT
  type        = list(string)
  default     = []
}

variable "instance_profile" {
  description = "IAM instance profile NAME (needs SSM params read + kms:Decrypt, ECR pull, SSM core, CloudWatch logs)."
  type        = string
}

variable "create_security_group" {
  description = "Create a per-ASG security group. false = only use security_group_ids (e.g. one SG shared by blue and green)."
  type        = bool
  default     = true
}

variable "security_group_ids" {
  description = "Additional (or, with create_security_group = false, the only) security groups for the instances."
  type        = list(string)
  default     = []
}

variable "alb_security_group_id" {
  description = "Source SG allowed on host_port when this module creates the security group."
  type        = string
  default     = null
}

variable "host_port" {
  description = "Host port the container is published on (-p host_port:container_port). Must equal the target group port."
  type        = number
  default     = 80
}

variable "container_port" {
  description = "Port the app listens on inside the container (CONVENTIONS §2)."
  type        = number
  default     = 8080
}

variable "golden_ami" {
  description = "true = the AMI already has Docker; user data skips the install (boot is ~30s faster)."
  type        = bool
  default     = false
}

variable "log_group_name" {
  description = "CloudWatch log group for the container (awslogs driver). null = local json-file logs only."
  type        = string
  default     = null
}

variable "key_name" {
  description = "Optional EC2 key pair. Prefer Session Manager."
  type        = string
  default     = null
}

variable "root_volume_size" {
  description = "Root gp3 volume size in GiB."
  type        = number
  default     = 20
}

variable "cpu_credits" {
  description = "Burstable CPU credit mode (standard = no surprise charges during CPU load tests)."
  type        = string
  default     = "standard"
}

variable "health_check_grace_period" {
  description = "Seconds before ELB health checks count against a new instance (boot + docker pull + optimize)."
  type        = number
  default     = 120
}

variable "instance_warmup" {
  description = "Seconds a new instance needs before its metrics count (scaling) / before refresh moves on."
  type        = number
  default     = 120
}

# ---------------------------------------------------------------- instance refresh

variable "refresh_min_healthy_percentage" {
  description = "Instance refresh: capacity that must stay InService (50 = replace half at a time)."
  type        = number
  default     = 50
}

variable "refresh_max_healthy_percentage" {
  description = "Instance refresh: >100 launches replacements before terminating (no capacity dip, temporary extra cost)."
  type        = number
  default     = 100
}

variable "refresh_auto_rollback" {
  description = "Roll back to the previous launch template version when the refresh fails."
  type        = bool
  default     = true
}

variable "refresh_alarm_names" {
  description = "CloudWatch alarms that fail (and with auto rollback, revert) an instance refresh when they go to ALARM (scenario 44)."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------- spot

variable "spot_enabled" {
  description = "Run instances on Spot via a mixed instances policy (~60-70% cheaper; interruptions are a resilience drill)."
  type        = bool
  default     = false
}

variable "spot_instance_types" {
  description = "Instance types for Spot diversification. Empty = [instance_type]. More types = fewer interruptions."
  type        = list(string)
  default     = []
}

variable "on_demand_base_capacity" {
  description = "On-Demand instances kept before Spot kicks in."
  type        = number
  default     = 0
}

variable "on_demand_percentage_above_base" {
  description = "Percent On-Demand above the base (0 = all Spot)."
  type        = number
  default     = 0
}

# ---------------------------------------------------------------- scaling

variable "enable_cpu_scaling" {
  description = "Target tracking on average CPU."
  type        = bool
  default     = true
}

variable "cpu_target" {
  description = "Average CPU % the ASG tracks."
  type        = number
  default     = 50
}

variable "enable_request_scaling" {
  description = "Target tracking on ALBRequestCountPerTarget (needs alb_arn_suffix + target_group_arn_suffix)."
  type        = bool
  default     = false
}

variable "requests_per_target" {
  description = "Requests per target per minute the ASG tracks."
  type        = number
  default     = 1000
}

variable "alb_arn_suffix" {
  description = "ALB ARN suffix for the request-count policy."
  type        = string
  default     = null
}

variable "target_group_arn_suffix" {
  description = "Target group ARN suffix for the request-count policy."
  type        = string
  default     = null
}

variable "install_codedeploy_agent" {
  description = "Install the CodeDeploy agent + Docker Compose plugin at boot (scenario 37: CodeDeploy deployments to this ASG)."
  type        = bool
  default     = false
}

variable "compose_version" {
  description = "Docker Compose plugin release installed when install_codedeploy_agent = true."
  type        = string
  default     = "v2.39.4"
}

variable "detailed_monitoring" {
  description = "1-minute EC2 metrics (faster CPU target tracking, scenario 48) — extra CloudWatch cost per instance."
  type        = bool
  default     = false
}
