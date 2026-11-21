output "instance_id" {
  description = "EC2 instance ID (SSM Run Command / Session Manager target)."
  value       = aws_instance.this.id
}

output "public_ip" {
  description = "Public IP (the Elastic IP when create_eip = true)."
  value       = var.create_eip ? aws_eip.this[0].public_ip : aws_instance.this.public_ip
}

output "public_dns" {
  description = "Public DNS name."
  value       = var.create_eip ? aws_eip.this[0].public_dns : aws_instance.this.public_dns
}

output "private_ip" {
  description = "Private IP."
  value       = aws_instance.this.private_ip
}

output "security_group_id" {
  description = "Instance security group ID."
  value       = aws_security_group.this.id
}

output "ami_id" {
  description = "AMI the instance was launched from."
  value       = aws_instance.this.ami
}
