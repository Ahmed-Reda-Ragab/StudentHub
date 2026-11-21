variable "region" {
  type        = string
  default     = "us-east-1"
  description = "Region to build in (the AMI is regional; copy it with ami_regions if needed)."
}

variable "project" {
  type    = string
  default = "student-app"
}

variable "env" {
  type    = string
  default = "lab"
}

variable "arch" {
  type        = string
  default     = "x86_64"
  description = "x86_64 (t3/t3a) or arm64 (Graviton t4g, ~20% cheaper). Must match stack 40 var.arch / instance_type."

  validation {
    condition     = contains(["x86_64", "arm64"], var.arch)
    error_message = "The arch value must be x86_64 or arm64."
  }
}

variable "instance_type" {
  type        = string
  default     = ""
  description = "Build instance type. Empty = t3.small (x86_64) or t4g.small (arm64)."
}

variable "root_volume_size" {
  type        = number
  default     = 16
  description = "GiB. Must be <= the launch template root volume (modules/asg-app root_volume_size = 20)."
}

variable "kms_key_id" {
  type        = string
  default     = ""
  description = "KMS key for the encrypted root volume / AMI snapshot. Empty = AWS-managed aws/ebs key."
}

variable "ssh_interface" {
  type        = string
  default     = "public_ip"
  description = "public_ip (temporary SG open to YOUR IP only) or session_manager (no inbound port; needs iam_instance_profile with SSM)."

  validation {
    condition     = contains(["public_ip", "session_manager"], var.ssh_interface)
    error_message = "The ssh_interface value must be public_ip or session_manager."
  }
}

variable "iam_instance_profile" {
  type        = string
  default     = ""
  description = "Instance profile of the BUILD instance. Needed for session_manager and for prepull_image (ECR pull)."
}

variable "subnet_id" {
  type        = string
  default     = ""
  description = "Empty = default VPC. Use a public subnet (the build instance needs internet for dnf/GitHub)."
}

variable "prepull_image" {
  type        = string
  default     = ""
  description = "Optional ECR image baked into the AMI so the first boot only pulls changed layers, e.g. <acct>.dkr.ecr.us-east-1.amazonaws.com/student-app:3f2c1ab."
}

variable "ami_deprecate_days" {
  type        = number
  default     = 90
  description = "Mark the AMI deprecated after N days: old golden images disappear from default listings."
}
