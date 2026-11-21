variable "name" {
  description = "Name prefix for every resource, e.g. student-app-lab."
  type        = string
}

variable "cidr" {
  description = "VPC CIDR. /16 leaves room for /20 subnets (EKS VPC CNI gives every pod a VPC IP)."
  type        = string
  default     = "10.20.0.0/16"

  validation {
    condition     = can(cidrhost(var.cidr, 0))
    error_message = "cidr must be a valid IPv4 CIDR block."
  }
}

variable "az_count" {
  description = "Number of AZs (one public + one private subnet per AZ). ALB and RDS need at least 2."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 1 && var.az_count <= 4
    error_message = "az_count must be between 1 and 4."
  }
}

variable "enable_nat" {
  description = "Create NAT gateway(s) so private subnets reach the internet. ~32 USD/month EACH + data processing: off by default."
  type        = bool
  default     = false
}

variable "single_nat" {
  description = "true = one shared NAT (cheap, single-AZ failure domain); false = one NAT per AZ (HA, costs az_count times more)."
  type        = bool
  default     = true
}

variable "enable_s3_endpoint" {
  description = "Free S3 gateway endpoint: ECR image layers are served from S3, so pulls skip the NAT (cost + speed)."
  type        = bool
  default     = true
}

variable "subnet_newbits" {
  description = "Bits added to the VPC prefix for each subnet (4 on a /16 = /20 subnets, 4091 usable IPs each)."
  type        = number
  default     = 4
}

variable "public_subnet_tags" {
  description = "Extra tags for public subnets (merged over the defaults)."
  type        = map(string)
  default     = {}
}

variable "private_subnet_tags" {
  description = "Extra tags for private subnets (merged over the defaults)."
  type        = map(string)
  default     = {}
}
