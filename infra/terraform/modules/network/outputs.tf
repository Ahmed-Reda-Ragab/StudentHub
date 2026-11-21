output "vpc_id" {
  description = "VPC ID."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "VPC CIDR block."
  value       = aws_vpc.this.cidr_block
}

output "azs" {
  description = "AZs used, index-aligned with the subnet ID lists."
  value       = local.azs
}

output "public_subnet_ids" {
  description = "Public subnet IDs (one per AZ)."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet IDs (one per AZ). No internet egress unless enable_nat = true."
  value       = aws_subnet.private[*].id
}

output "public_route_table_id" {
  description = "Public route table ID."
  value       = aws_route_table.public.id
}

output "private_route_table_ids" {
  description = "Private route table IDs (one per AZ)."
  value       = aws_route_table.private[*].id
}

output "nat_public_ips" {
  description = "Elastic IPs of the NAT gateway(s), empty when NAT is disabled (allow-list these on third parties)."
  value       = aws_eip.nat[*].public_ip
}
