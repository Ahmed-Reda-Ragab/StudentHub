variable "project" {
  description = "Project name (CONVENTIONS §1)."
  type        = string
  default     = "student-app"
}

variable "env" {
  description = "Environment; also the SSM path segment (/student-app/<env>/...)."
  type        = string
  default     = "lab"
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "scenario" {
  description = "Scenario tag value. Override per exercise, e.g. -var scenario=45."
  type        = string
  default     = "40"
}

# ---------------------------------------------------------------- network

variable "vpc_cidr" {
  description = "VPC CIDR."
  type        = string
  default     = "10.20.0.0/16"
}

variable "private_instances" {
  description = <<-EOT
    false (default): app instances live in PUBLIC subnets with a public IP, reachable only from
    the ALB security group — no NAT needed (saves ~32 USD/month).
    true: instances in PRIVATE subnets behind a NAT gateway (the production layout, scenario 40 "prod toggle").
  EOT
  type        = bool
  default     = false
}

variable "single_nat" {
  description = "With private_instances: one shared NAT (cheap) vs one per AZ (HA)."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------- release

variable "ecr_repository_name" {
  description = "ECR repository created by bootstrap."
  type        = string
  default     = "student-app"
}

variable "image_tag" {
  description = "Git short SHA already pushed to ECR by CI. Only seeds deploy/<color>/IMAGE_URI; CI owns it afterwards."
  type        = string
  default     = "unset"
}

variable "image_uri" {
  description = "Full image URI override (e.g. a GHCR image). Takes precedence over image_tag."
  type        = string
  default     = null
}

# ---------------------------------------------------------------- compute

variable "instance_type" {
  description = "App instance type (running the image only: 1 GiB is enough)."
  type        = string
  default     = "t3.micro"
}

variable "arch" {
  description = "x86_64 or arm64 (arm64 needs a t4g type and an arm64 image)."
  type        = string
  default     = "x86_64"
}

variable "ami_id" {
  description = "Packer golden AMI (scenario 43). null = latest AL2023 + Docker installed at boot."
  type        = string
  default     = null
}

variable "golden_ami" {
  description = "Set true with a Packer ami_id that already contains Docker."
  type        = bool
  default     = false
}

variable "min_size" {
  description = "Per-color ASG min size."
  type        = number
  default     = 1
}

variable "max_size" {
  description = "Per-color ASG max size."
  type        = number
  default     = 4
}

variable "desired_capacity" {
  description = "Per-color initial desired capacity (2 = one per AZ; scaling policies own it afterwards)."
  type        = number
  default     = 2
}

variable "green_enabled" {
  description = "Create the green ASG (blue/green + canary, scenarios 44-46). Off = only blue exists."
  type        = bool
  default     = false
}

variable "blue_weight" {
  description = "ALB weight for blue (0-999)."
  type        = number
  default     = 100
}

variable "green_weight" {
  description = "ALB weight for green (0-999). 100/0 -> 0/100 = blue/green switch, 90/10 = canary."
  type        = number
  default     = 0
}

variable "stickiness_duration" {
  description = "Seconds a client sticks to one color during a canary (0 = off)."
  type        = number
  default     = 0
}

variable "spot_enabled" {
  description = "Run the ASGs on Spot (scenario 48)."
  type        = bool
  default     = false
}

variable "spot_instance_types" {
  description = "Spot diversification list, e.g. [\"t3.micro\", \"t3a.micro\", \"t2.micro\"]."
  type        = list(string)
  default     = []
}

variable "cpu_target" {
  description = "Target tracking: average CPU %."
  type        = number
  default     = 50
}

variable "enable_request_scaling" {
  description = "Target tracking on ALBRequestCountPerTarget as well."
  type        = bool
  default     = true
}

variable "requests_per_target" {
  description = "Target tracking: requests per instance per minute."
  type        = number
  default     = 1000
}

variable "refresh_rollback_on_alarms" {
  description = "Fail + roll back instance refreshes when the 5xx-ratio or unhealthy-host alarm fires (scenario 44)."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------- data

variable "db_name" {
  description = "Database name."
  type        = string
  default     = "student_app"
}

variable "db_username" {
  description = "Master username (used by the app in the lab)."
  type        = string
  default     = "student"
}

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.micro"
}

variable "db_multi_az" {
  description = "Multi-AZ standby (scenario 77 failover drill; doubles RDS cost)."
  type        = bool
  default     = false
}

variable "db_deletion_protection" {
  description = "RDS deletion protection (false so the lab can be destroyed)."
  type        = bool
  default     = false
}

variable "db_skip_final_snapshot" {
  description = "Skip the final snapshot on destroy (lab: true)."
  type        = bool
  default     = true
}

variable "redis_enabled" {
  description = "ElastiCache + SESSION_DRIVER/CACHE_STORE=redis (scenario 49)."
  type        = bool
  default     = false
}

variable "redis_transit_encryption" {
  description = "TLS to ElastiCache (REDIS_HOST becomes tls://...)."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------- edge / ops

variable "domain_name" {
  description = "Optional FQDN (e.g. lab.example.com): ACM certificate + HTTPS listener + Route 53 alias."
  type        = string
  default     = null
}

variable "hosted_zone_id" {
  description = "Route 53 public hosted zone ID for domain_name."
  type        = string
  default     = null

  validation {
    condition     = var.domain_name == null || var.hosted_zone_id != null
    error_message = "hosted_zone_id is required when domain_name is set."
  }
}

variable "alarm_email" {
  description = "Optional e-mail for alarm notifications (confirm the subscription mail)."
  type        = string
  default     = null
}

variable "log_retention_days" {
  description = "Retention of the app log group."
  type        = number
  default     = 7
}

variable "sre_lab_enabled" {
  description = "Expose /sre-lab/* and env fault injection (protected by SRE_LAB_TOKEN)."
  type        = bool
  default     = true
}

variable "listener_weights_managed_externally" {
  description = "Set true when CI/CLI (deploy-asg.yml) shifts blue/green weights; Terraform then ignores listener default_action drift. Changing it recreates the listener."
  type        = bool
  default     = false
}

variable "codedeploy_enabled" {
  description = "Scenario 37: install the CodeDeploy agent on the ASG instances and create the CodeDeploy app + IN_PLACE deployment group on the blue ASG and its revision bucket (codedeploy.tf)."
  type        = bool
  default     = false
}

variable "codedeploy_revision_bucket" {
  description = "Existing S3 bucket for CodeDeploy revisions. Empty = the stack creates <name>-codedeploy-<account> (codedeploy.tf)."
  type        = string
  default     = ""
}

variable "codedeploy_deployment_config_name" {
  description = "CodeDeployDefault.OneAtATime | HalfAtATime | AllAtOnce (null = OneAtATime)."
  type        = string
  default     = null
}

variable "detailed_monitoring" {
  description = "1-minute EC2 metrics on the ASG instances: CPU target tracking reacts much faster (scenario 48). Extra CloudWatch cost per instance."
  type        = bool
  default     = false
}
