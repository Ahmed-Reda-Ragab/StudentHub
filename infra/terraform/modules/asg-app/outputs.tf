output "asg_name" {
  description = "Auto Scaling group name (start-instance-refresh target)."
  value       = aws_autoscaling_group.this.name
}

output "asg_arn" {
  description = "Auto Scaling group ARN."
  value       = aws_autoscaling_group.this.arn
}

output "launch_template_id" {
  description = "Launch template ID."
  value       = aws_launch_template.this.id
}

output "launch_template_latest_version" {
  description = "Latest launch template version."
  value       = aws_launch_template.this.latest_version
}

output "security_group_id" {
  description = "Instance security group (the module-created one, or the first of security_group_ids)."
  value       = var.create_security_group ? aws_security_group.this[0].id : try(var.security_group_ids[0], null)
}

output "image_parameter_name" {
  description = "SSM parameter CI updates to release a new image to this color."
  value       = aws_ssm_parameter.image_uri.name
}

output "image_parameter_arn" {
  description = "ARN of the IMAGE_URI parameter."
  value       = aws_ssm_parameter.image_uri.arn
}
