variable "name" {
  description = "Name prefix, e.g. student-app-lab. The DB identifier becomes <name>-mysql."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnet IDs in at least 2 AZs (an RDS subnet group requires 2 AZs even for Single-AZ)."
  type        = list(string)
}

variable "allowed_security_group_ids" {
  description = "Security groups allowed to connect on 3306 (app instances / ECS tasks / EKS nodes)."
  type        = list(string)
  default     = []
}

variable "allowed_cidr_blocks" {
  description = "Extra CIDRs allowed on 3306 (e.g. a bastion subnet). Prefer security groups."
  type        = list(string)
  default     = []
}

variable "instance_class" {
  description = "Instance class. db.t4g.micro is free-tier eligible (750 h/month for 12 months on new accounts)."
  type        = string
  default     = "db.t4g.micro"
}

variable "engine_version" {
  description = "MySQL version. A major.minor prefix (8.4) lets RDS pick the newest patch and auto-upgrade minors."
  type        = string
  default     = "8.4"
}

variable "multi_az" {
  description = "Synchronous standby in a second AZ (doubles the cost). Scenario 77 turns it on to practise failover."
  type        = bool
  default     = false
}

variable "ssm_prefix" {
  description = "SSM path the connection settings are written to, e.g. /student-app/lab/app (CONVENTIONS §4)."
  type        = string

  validation {
    condition     = startswith(var.ssm_prefix, "/")
    error_message = "ssm_prefix must start with '/'."
  }
}

variable "db_name" {
  description = "Initial database name (DB_DATABASE)."
  type        = string
  default     = "student_app"
}

variable "username" {
  description = "Master username (DB_USERNAME). Lab shortcut: the app uses the master user; prod would create a least-privilege app user."
  type        = string
  default     = "student"
}

variable "allocated_storage" {
  description = "gp3 storage in GiB (20 = minimum; gp3 includes 3000 IOPS baseline below 400 GiB)."
  type        = number
  default     = 20
}

variable "max_allocated_storage" {
  description = "Storage autoscaling ceiling in GiB (0 = disabled)."
  type        = number
  default     = 0
}

variable "backup_retention_period" {
  description = "Days of automated backups. > 0 also enables point-in-time recovery (scenario 77)."
  type        = number
  default     = 7
}

variable "deletion_protection" {
  description = "Block deletes at the API level. false in the lab so the stack can be destroyed; true for anything real."
  type        = bool
  default     = false
}

variable "skip_final_snapshot" {
  description = "Skip the final snapshot on destroy. true in the lab (snapshots cost money and outlive the stack); false for anything real."
  type        = bool
  default     = true
}

variable "use_secrets_manager" {
  description = <<-EOT
    Scenario 81: let RDS own the master password in Secrets Manager (manage_master_user_password,
    rotation every 7 days). DB_PASSWORD is then NOT written to SSM — consumers read it from the
    secret (ECS: valueFrom "<master_user_secret_arn>:password::"). Secrets Manager costs 0.40 USD/secret/month.
  EOT
  type        = bool
  default     = false
}

variable "apply_immediately" {
  description = "Apply modifications now instead of in the maintenance window (lab: true)."
  type        = bool
  default     = true
}

variable "cloudwatch_logs_exports" {
  description = "RDS logs exported to CloudWatch (slowquery helps with /sre-lab/db/heavy). [] to disable."
  type        = list(string)
  default     = ["error", "slowquery"]
}

variable "log_retention_days" {
  description = "Retention for exported RDS log groups."
  type        = number
  default     = 7
}

variable "long_query_time" {
  description = "Seconds after which a query lands in the slow query log."
  type        = number
  default     = 1
}

variable "delete_automated_backups" {
  description = "Delete the automated backups (PITR) when the instance is destroyed. true = lab hygiene (no leftover storage cost); set false — together with skip_final_snapshot = false — in anything you would ever need to restore (scenario 77)."
  type        = bool
  default     = true
}
