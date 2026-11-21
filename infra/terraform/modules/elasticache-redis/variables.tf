variable "name" {
  description = "Name prefix, e.g. student-app-lab (replication group id max 40 chars)."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnet IDs."
  type        = list(string)
}

variable "allowed_security_group_ids" {
  description = "Security groups allowed on the cache port."
  type        = list(string)
  default     = []
}

variable "engine" {
  description = "valkey (default: open-source Redis fork, ~20% cheaper on ElastiCache, same protocol for phpredis) or redis."
  type        = string
  default     = "valkey"

  validation {
    condition     = contains(["valkey", "redis"], var.engine)
    error_message = "engine must be valkey or redis."
  }
}

variable "engine_version" {
  description = "Engine version; null = the latest version ElastiCache offers."
  type        = string
  default     = null
}

variable "node_type" {
  description = "Node type (cache.t4g.micro ≈ 0.016 USD/h)."
  type        = string
  default     = "cache.t4g.micro"
}

variable "port" {
  description = "Cache port."
  type        = number
  default     = 6379
}

variable "transit_encryption_enabled" {
  description = <<-EOT
    TLS in transit. The module then writes REDIS_HOST=tls://<endpoint> (phpredis switches to TLS on
    the scheme). Off by default to keep the first Redis scenario simple; turning it on is a hardening step.
  EOT
  type        = bool
  default     = false
}

variable "ssm_prefix" {
  description = "SSM path for REDIS_HOST / REDIS_PORT, e.g. /student-app/lab/app."
  type        = string

  validation {
    condition     = startswith(var.ssm_prefix, "/")
    error_message = "ssm_prefix must start with '/'."
  }
}
