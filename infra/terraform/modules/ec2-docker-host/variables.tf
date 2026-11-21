variable "name" {
  description = "Name prefix / Name tag, e.g. student-app-lab-app."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID."
  type        = string
}

variable "subnet_id" {
  description = "Public subnet ID for the instance."
  type        = string
}

variable "instance_type" {
  description = "Instance type. Must match arch (t3.* = x86_64, t4g.* = arm64)."
  type        = string
  default     = "t3.small"
}

variable "arch" {
  description = "CPU architecture of the AL2023 AMI: x86_64 or arm64 (Graviton, ~20% cheaper; the image must be built for arm64)."
  type        = string
  default     = "x86_64"

  validation {
    condition     = contains(["x86_64", "arm64"], var.arch)
    error_message = "arch must be x86_64 or arm64."
  }
}

variable "ami_id" {
  description = "Optional AMI override (e.g. a Packer golden image). null = latest Amazon Linux 2023 from the SSM public parameter."
  type        = string
  default     = null
}

variable "key_name" {
  description = "EC2 key pair for SSH (scenario 31 only). null = no key: use SSM Session Manager."
  type        = string
  default     = null
}

variable "ingress_cidrs" {
  description = "CIDRs allowed on the HTTP port(s)."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "ingress_ports" {
  description = "TCP ports opened to ingress_cidrs. 80 = app (compose 80:8080) or the nginx LB of deploy/ec2/lb."
  type        = list(number)
  default     = [80]
}

variable "ssh_cidrs" {
  description = "CIDRs allowed on port 22. Empty (default) = no SSH rule at all; Session Manager needs no inbound port."
  type        = list(string)
  default     = []
}

variable "user_data" {
  description = "Cloud-init user data (plain text; the provider base64-encodes it). Never put secrets here (visible in the console)."
  type        = string
  default     = null
}

variable "instance_profile" {
  description = "IAM instance profile NAME attached to the instance."
  type        = string
  default     = null
}

variable "root_volume_size" {
  description = "Root gp3 volume size in GiB (Docker images + MySQL data live here)."
  type        = number
  default     = 20
}

variable "create_eip" {
  description = "Attach an Elastic IP so the public IP survives stop/start (free while attached to a running instance)."
  type        = bool
  default     = true
}

variable "cpu_credits" {
  description = "Burstable (t*) CPU credit mode. standard = never billed beyond the hourly price, even during /sre-lab/cpu load tests."
  type        = string
  default     = "standard"

  validation {
    condition     = contains(["standard", "unlimited"], var.cpu_credits)
    error_message = "cpu_credits must be standard or unlimited."
  }
}

variable "tags" {
  description = "Extra tags for the instance (e.g. Role = app for the Ansible aws_ec2 inventory)."
  type        = map(string)
  default     = {}
}
