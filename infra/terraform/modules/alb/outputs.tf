output "alb_arn" {
  description = "ALB ARN."
  value       = aws_lb.this.arn
}

output "alb_arn_suffix" {
  description = "ALB ARN suffix (CloudWatch LoadBalancer dimension, ALBRequestCountPerTarget resource label)."
  value       = aws_lb.this.arn_suffix
}

output "dns_name" {
  description = "ALB DNS name."
  value       = aws_lb.this.dns_name
}

output "zone_id" {
  description = "ALB hosted zone ID (Route 53 alias records)."
  value       = aws_lb.this.zone_id
}

output "security_group_id" {
  description = "ALB security group ID (allow it as the source on target security groups)."
  value       = aws_security_group.this.id
}

output "listener_http_arn" {
  description = "HTTP :80 listener ARN (redirects to HTTPS when a certificate is configured)."
  value       = local.http_listener_arn
}

output "listener_https_arn" {
  description = "HTTPS :443 listener ARN, null without a certificate."
  value       = local.https ? local.https_listener_arn : null
}

output "listener_arn" {
  description = "The listener that carries traffic (HTTPS when enabled, otherwise HTTP). Modify THIS one to shift weights."
  value       = local.traffic_listener_arn
}

output "target_group_arns" {
  description = "Target group ARNs: { blue, green }."
  value       = { for color, tg in aws_lb_target_group.this : color => tg.arn }
}

output "target_group_arn_suffixes" {
  description = "Target group ARN suffixes (CloudWatch TargetGroup dimension): { blue, green }."
  value       = { for color, tg in aws_lb_target_group.this : color => tg.arn_suffix }
}

output "target_group_names" {
  description = "Target group names: { blue, green }."
  value       = { for color, tg in aws_lb_target_group.this : color => tg.name }
}
