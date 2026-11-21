variable "name" {
  description = "Name prefix, e.g. student-app-lab."
  type        = string
}

variable "stop_condition_alarm_arn" {
  description = "CloudWatch alarm that aborts every experiment when it fires (the blast-radius guardrail). null = no stop condition (not recommended)."
  type        = string
  default     = null
}

variable "log_retention_days" {
  description = "Retention of the experiment log group."
  type        = number
  default     = 14
}

# ---------------------------------------------------------------- ECS: stop tasks

variable "ecs_cluster_name" {
  description = "ECS cluster for the stop-tasks experiment. null = experiment not created."
  type        = string
  default     = null
}

variable "ecs_service_name" {
  description = "ECS service whose tasks are stopped."
  type        = string
  default     = null
}

variable "ecs_stop_task_percent" {
  description = "Share of the service's running tasks FIS stops (rounded down; 50% of 2 tasks = 1)."
  type        = number
  default     = 50
}

# ---------------------------------------------------------------- EC2 / ASG

variable "asg_name" {
  description = "ASG for the terminate-one-instance experiment (scenario 75 on stack 40). null = not created."
  type        = string
  default     = null
}

variable "cpu_stress_target_tags" {
  description = "Instance tags selecting the CPU-stress targets (SSM agent required), e.g. { \"aws:autoscaling:groupName\" = \"student-app-lab-blue\" }. Empty = not created."
  type        = map(string)
  default     = {}
}

variable "cpu_stress_duration_seconds" {
  description = "How long AWSFIS-Run-CPU-Stress loads the CPUs (watch the CPU scaling policy react)."
  type        = number
  default     = 300
}

variable "cpu_stress_instance_percent" {
  description = "Share of the matching instances that get stressed."
  type        = number
  default     = 50
}
