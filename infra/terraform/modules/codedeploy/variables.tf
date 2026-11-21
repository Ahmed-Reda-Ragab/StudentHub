variable "name" {
  description = "CodeDeploy application + deployment group name, e.g. student-app-lab-ecs."
  type        = string
}

variable "compute_platform" {
  description = "ECS (blue/green for an ECS service, scenario 54) or Server (EC2 / ASG with the CodeDeploy agent, scenario 37)."
  type        = string
  default     = "ECS"

  validation {
    condition     = contains(["ECS", "Server"], var.compute_platform)
    error_message = "compute_platform must be ECS or Server."
  }
}

variable "deployment_config_name" {
  description = <<-EOT
    null = CodeDeployDefault.ECSAllAtOnce (ECS) / CodeDeployDefault.OneAtATime (Server).
    ECS: CodeDeployDefault.ECSAllAtOnce | ECSCanary10Percent5Minutes | ECSCanary10Percent15Minutes |
         ECSLinear10PercentEvery1Minutes | ECSLinear10PercentEvery3Minutes
    Server: CodeDeployDefault.OneAtATime | HalfAtATime | AllAtOnce
  EOT
  type        = string
  default     = null
}

variable "alarm_names" {
  description = "CloudWatch alarms that stop (and roll back) a deployment in progress."
  type        = list(string)
  default     = []
}

variable "auto_rollback_events" {
  description = "Events that trigger an automatic rollback. DEPLOYMENT_STOP_ON_ALARM is dropped when alarm_names is empty."
  type        = list(string)
  default     = ["DEPLOYMENT_FAILURE", "DEPLOYMENT_STOP_ON_ALARM"]
}

variable "termination_wait_time_in_minutes" {
  description = "Minutes the old (blue) tasks/instances stay alive after the switch — the instant-rollback window."
  type        = number
  default     = 5
}

variable "ready_wait_time_in_minutes" {
  description = "0 = shift traffic as soon as green is healthy. > 0 = wait for a manual `aws deploy continue-deployment` (test on the test listener first)."
  type        = number
  default     = 0
}

# ---------------------------------------------------------------- ECS

variable "ecs_cluster_name" {
  description = "ECS: cluster name."
  type        = string
  default     = null
}

variable "ecs_service_name" {
  description = "ECS: service name (deployment_controller must be CODE_DEPLOY)."
  type        = string
  default     = null
}

variable "target_group_names" {
  description = "ECS: { blue, green } target group NAMES (modules/alb output target_group_names)."
  type        = map(string)
  default     = {}
}

variable "prod_listener_arns" {
  description = "ECS: production listener ARN(s) CodeDeploy re-points from blue to green."
  type        = list(string)
  default     = []
}

variable "test_listener_arns" {
  description = "ECS (optional): test listener ARN(s) that reach green before production does."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------- Server (EC2 / ASG)

variable "deployment_type" {
  description = <<-EOT
    Server only. IN_PLACE: the agent updates existing instances (works with the Terraform-managed ASG).
    BLUE_GREEN: CodeDeploy COPIES the ASG into a new one and deletes the old one — the copy is not
    in Terraform state, so use it on a throw-away ASG (scenario 37b) or expect drift.
  EOT
  type        = string
  default     = "IN_PLACE"

  validation {
    condition     = contains(["IN_PLACE", "BLUE_GREEN"], var.deployment_type)
    error_message = "deployment_type must be IN_PLACE or BLUE_GREEN."
  }
}

variable "autoscaling_group_names" {
  description = "Server: ASGs to deploy to (CodeDeploy adds a launch lifecycle hook so scale-out instances get the current revision)."
  type        = list(string)
  default     = []
}

variable "ec2_tag_filters" {
  description = "Server: instance tags to target (key = value, ANDed, max 3), e.g. { Project = \"student-app\", Role = \"app\" }."
  type        = map(string)
  default     = {}

  validation {
    condition     = length(var.ec2_tag_filters) <= 3
    error_message = "CodeDeploy supports at most 3 EC2 tag sets."
  }
}

variable "server_target_group_names" {
  description = "Server: ALB target group(s) the instances sit behind. Set = WITH_TRAFFIC_CONTROL (deregister -> deploy -> re-register)."
  type        = list(string)
  default     = []
}

variable "instance_role_arns" {
  description = "Server BLUE_GREEN: instance-profile role(s) CodeDeploy passes when it launches the copied ASG (launch templates need iam:PassRole)."
  type        = list(string)
  default     = []
}
