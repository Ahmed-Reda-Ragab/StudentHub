# ---------------------------------------------------------------- identity / network

variable "name" {
  description = "Name prefix, e.g. student-app-lab. Cluster = <name>, service + task family = <name>-app."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID."
  type        = string
}

variable "subnet_ids" {
  description = <<-EOT
    Subnets for the tasks. Lab default: PUBLIC subnets + assign_public_ip = true, so tasks reach
    ECR / SSM / CloudWatch without a NAT gateway (~32 USD/month). With NAT (or VPC endpoints):
    private subnets + assign_public_ip = false — the production layout.
  EOT
  type        = list(string)
}

variable "assign_public_ip" {
  description = "Give each task ENI a public IPv4 (0.005 USD/h each). Required in public subnets without NAT."
  type        = bool
  default     = true
}

variable "alb_security_group_id" {
  description = "ALB security group; the only source allowed to reach the container port."
  type        = string
}

variable "target_group_arns" {
  description = "Target group ARNs from modules/alb: { blue, green }. The service starts on blue."
  type        = map(string)

  validation {
    condition     = alltrue([for k in ["blue", "green"] : contains(keys(var.target_group_arns), k)])
    error_message = "target_group_arns must contain the keys blue and green."
  }
}

variable "listener_arn" {
  description = "Traffic listener (modules/alb output listener_arn). Required for BLUE_GREEN / LINEAR / CANARY: ECS shifts weights on a listener rule created on it."
  type        = string
  default     = null

  validation {
    condition     = var.listener_arn != null || var.deployment_strategy == "ROLLING" || var.deployment_controller == "CODE_DEPLOY"
    error_message = "listener_arn is required when deployment_strategy is BLUE_GREEN, LINEAR or CANARY."
  }
}

variable "alb_arn_suffix" {
  description = "ALB ARN suffix, used for the ALBRequestCountPerTarget scaling policy."
  type        = string
  default     = null
}

variable "target_group_arn_suffixes" {
  description = "Target group ARN suffixes { blue, green } (ALBRequestCountPerTarget resource label)."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------- container

variable "image_uri" {
  description = "Initial image, <account>.dkr.ecr.<region>.amazonaws.com/student-app:<short-sha>. CI owns it afterwards."
  type        = string

  validation {
    condition     = can(regex(":[^/]+$", var.image_uri)) && !endswith(var.image_uri, ":latest")
    error_message = "image_uri must carry an immutable tag (git short SHA); ':latest' is not allowed (CONVENTIONS §2)."
  }
}

variable "ssm_prefix" {
  description = "SSM path holding the app env, e.g. /student-app/lab/app. The execution role may read <prefix>/* only."
  type        = string

  validation {
    condition     = startswith(var.ssm_prefix, "/")
    error_message = "ssm_prefix must start with '/'."
  }
}

variable "secrets" {
  description = <<-EOT
    Env key -> SSM parameter ARN (container `secrets[].valueFrom`). Pass the ARNs of the parameter
    RESOURCES (not hand-built strings) so Terraform registers the task definition only after every
    parameter exists — otherwise the first tasks fail with ResourceInitializationError.
  EOT
  type        = map(string)
  default     = {}
}

variable "environment" {
  description = "Non-secret env vars (APP_ENV, DB_CONNECTION, DEPLOY_COLOR, SRE_FAULT_* ...)."
  type        = map(string)
  default     = {}
}

variable "container_port" {
  description = "Container port (CONVENTIONS §2: 8080)."
  type        = number
  default     = 8080
}

variable "cpu" {
  description = "Task CPU units (512 = 0.5 vCPU). Must be a valid Fargate cpu/memory pair."
  type        = number
  default     = 512
}

variable "memory" {
  description = "Task memory in MiB (1024 with 512 CPU)."
  type        = number
  default     = 1024
}

variable "cpu_architecture" {
  description = "X86_64 (what CI builds today) or ARM64 (Graviton, ~20% cheaper; needs a multi-arch image)."
  type        = string
  default     = "X86_64"

  validation {
    condition     = contains(["X86_64", "ARM64"], var.cpu_architecture)
    error_message = "cpu_architecture must be X86_64 or ARM64."
  }
}

variable "stop_timeout" {
  description = "Seconds between the image STOPSIGNAL (SIGQUIT = graceful PHP-FPM) and SIGKILL. Max 120 on Fargate."
  type        = number
  default     = 30
}

variable "init_process_enabled" {
  description = <<-EOT
    linuxParameters.initProcessEnabled (ECS-injected tini as PID 1). Keep FALSE for this image:
    serversideup fpm-nginx runs S6 overlay, which must be PID 1 ("s6-overlay-suexec: fatal: can only
    run as pid 1") and already reaps zombies — including the SSM agent processes ECS Exec spawns.
  EOT
  type        = bool
  default     = false
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for the app log group."
  type        = number
  default     = 14
}

# ---------------------------------------------------------------- cluster / service

variable "container_insights" {
  description = "Cluster Container Insights: enhanced (task/container-level metrics, extra cost), enabled, disabled."
  type        = string
  default     = "enhanced"

  validation {
    condition     = contains(["enhanced", "enabled", "disabled"], var.container_insights)
    error_message = "container_insights must be enhanced, enabled or disabled."
  }
}

variable "desired_count" {
  description = "Initial task count. Application Auto Scaling owns it after creation (ignore_changes)."
  type        = number
  default     = 2
}

variable "capacity_provider_strategy" {
  description = <<-EOT
    Default: the first task on FARGATE (on-demand floor), every other task on FARGATE_SPOT (~70% cheaper,
    can be reclaimed with a 2-minute SIGTERM warning). Scenario 56 plays with these weights.
  EOT
  type = list(object({
    capacity_provider = string
    weight            = number
    base              = optional(number, 0)
  }))
  default = [
    { capacity_provider = "FARGATE", weight = 0, base = 1 },
    { capacity_provider = "FARGATE_SPOT", weight = 1, base = 0 },
  ]
}

variable "enable_execute_command" {
  description = "ECS Exec (aws ecs execute-command) for debugging without SSH (scenario 52)."
  type        = bool
  default     = true
}

variable "health_check_grace_period_seconds" {
  description = "Seconds the service ignores ALB health checks after a task starts (boot + php artisan optimize)."
  type        = number
  default     = 60
}

# ---------------------------------------------------------------- deployments

variable "deployment_controller" {
  description = "ECS (rolling or ECS-native blue/green/linear/canary) or CODE_DEPLOY (CodeDeploy blue/green, scenario 54)."
  type        = string
  default     = "ECS"

  validation {
    condition     = contains(["ECS", "CODE_DEPLOY"], var.deployment_controller)
    error_message = "deployment_controller must be ECS or CODE_DEPLOY."
  }
}

variable "deployment_strategy" {
  description = "ECS controller only: ROLLING (53), BLUE_GREEN / LINEAR / CANARY (55) — ECS-native traffic shifting, no CodeDeploy."
  type        = string
  default     = "ROLLING"

  validation {
    condition     = contains(["ROLLING", "BLUE_GREEN", "LINEAR", "CANARY"], var.deployment_strategy)
    error_message = "deployment_strategy must be ROLLING, BLUE_GREEN, LINEAR or CANARY."
  }
}

variable "bake_time_in_minutes" {
  description = "BLUE_GREEN/LINEAR/CANARY: minutes blue stays up after 100% of traffic is on green (instant rollback window)."
  type        = number
  default     = 5
}

variable "canary_percent" {
  description = "CANARY: share of production traffic sent to green first (0.1-100)."
  type        = number
  default     = 10
}

variable "canary_bake_time_in_minutes" {
  description = "CANARY: minutes at canary_percent before shifting the rest."
  type        = number
  default     = 5
}

variable "linear_step_percent" {
  description = "LINEAR: traffic shifted per step (3-100)."
  type        = number
  default     = 25
}

variable "linear_step_bake_time_in_minutes" {
  description = "LINEAR: minutes between steps."
  type        = number
  default     = 2
}

variable "production_listener_rule_priority" {
  description = "Priority of the production rule ECS rewrites (modules/alb uses priority 1 for the /metrics block)."
  type        = number
  default     = 100
}

variable "enable_test_listener_rule" {
  description = "Create a test rule (header X-Lab-Target: green) so green can be smoke-tested before it gets production traffic."
  type        = bool
  default     = true
}

variable "test_listener_rule_priority" {
  description = "Priority of the test rule (must be lower = evaluated before the production rule)."
  type        = number
  default     = 90
}

variable "deployment_alarm_names" {
  description = "ECS controller: CloudWatch alarms that fail + roll back a deployment while it runs (e.g. 5xx burn rate, scenarios 53–55)."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------- autoscaling

variable "autoscaling_min_capacity" {
  description = "Minimum tasks (2 = one per AZ)."
  type        = number
  default     = 2
}

variable "autoscaling_max_capacity" {
  description = "Maximum tasks (cost ceiling)."
  type        = number
  default     = 6
}

variable "cpu_target_value" {
  description = "Target average CPU % (ECSServiceAverageCPUUtilization)."
  type        = number
  default     = 50
}

variable "enable_request_count_scaling" {
  description = <<-EOT
    Add an ALBRequestCountPerTarget policy. Only applied with ROLLING: the policy is pinned to ONE
    target group, while blue/green strategies move the tasks between blue and green on every deploy.
  EOT
  type        = bool
  default     = true
}

variable "requests_per_target" {
  description = "Target requests per task per minute for ALBRequestCountPerTarget."
  type        = number
  default     = 600
}

variable "kms_key_arns" {
  description = "Customer-managed KMS keys of SecureString parameters. Empty = the AWS-managed aws/ssm key (decrypt only via SSM)."
  type        = list(string)
  default     = []
}
