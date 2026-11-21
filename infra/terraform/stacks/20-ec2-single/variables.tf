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
  description = "Scenario tag value. Override per exercise, e.g. -var scenario=32."
  type        = string
  default     = "20"
}

variable "vpc_cidr" {
  description = "VPC CIDR."
  type        = string
  default     = "10.20.0.0/16"
}

variable "instance_type" {
  description = <<-EOT
    t3.small (2 GiB): scenario 20/31 BUILD the image on the server (composer + npm + vite) and
    1 GiB t3.micro runs out of memory even with the 2G swap from user-data.sh. Pull-only
    scenarios (32/33) fit on t3.micro. Use t4g.* with arch = "arm64".
  EOT
  type        = string
  default     = "t3.small"
}

variable "arch" {
  description = "x86_64 or arm64. arm64 needs an arm64 (or multi-arch) image in ECR."
  type        = string
  default     = "x86_64"
}

variable "ami_id" {
  description = "Optional AMI override (Packer golden image). null = latest AL2023."
  type        = string
  default     = null
}

variable "http_cidrs" {
  description = "CIDRs allowed on port 80. Narrow to your IP (x.x.x.x/32) if you like."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "ssh_cidrs" {
  description = "CIDRs allowed on port 22 (scenario 31 only, e.g. [\"203.0.113.10/32\"]). Default: no SSH, use SSM Session Manager."
  type        = list(string)
  default     = []
}

variable "key_name" {
  description = "Existing EC2 key pair name for scenario 31 (SSH deploys). null = no key."
  type        = string
  default     = null
}

variable "ecr_repository_name" {
  description = "ECR repository created by bootstrap."
  type        = string
  default     = "student-app"
}

variable "db_name" {
  description = "MySQL database (DB_DATABASE / MYSQL_DATABASE)."
  type        = string
  default     = "student_app"
}

variable "db_username" {
  description = "MySQL app user (DB_USERNAME / MYSQL_USER)."
  type        = string
  default     = "student"
}

variable "sre_lab_enabled" {
  description = "Expose /sre-lab/* and env fault injection (protected by SRE_LAB_TOKEN). Never on a real prod."
  type        = bool
  default     = true
}

variable "backup_retention_days" {
  description = "Days before MySQL dumps in the backups bucket expire (scenario 27)."
  type        = number
  default     = 30
}

variable "backup_bucket_force_destroy" {
  description = "Delete the backups bucket with its dumps on destroy (this stack is ephemeral)."
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "Retention of the /student-app/<env>/app log group used by deploy/ec2/compose.awslogs.yml."
  type        = number
  default     = 14
}
