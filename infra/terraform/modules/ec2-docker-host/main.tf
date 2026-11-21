# EC2 Docker host — one Amazon Linux 2023 instance that runs the app with Docker Compose
# (scenarios 20–27, 31–33). Pets, not cattle: the local MySQL data lives on the root volume,
# so AMI / user-data changes never replace the instance implicitly (see lifecycle below).

# The SSM public parameter always points at the latest AL2023 AMI for the region/arch:
# no hardcoded AMI IDs, no owner filters.
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-${var.arch}"
}

locals {
  ami_id = coalesce(var.ami_id, data.aws_ssm_parameter.al2023.insecure_value)
  # credit_specification is only valid for burstable families.
  burstable = can(regex("^t[0-9]", var.instance_type))
}

# ---------------------------------------------------------------- security group

resource "aws_security_group" "this" {
  name        = "${var.name}-host"
  description = "Docker host ${var.name}"
  vpc_id      = var.vpc_id
  tags        = merge({ Name = "${var.name}-host" }, var.tags)
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  for_each = {
    for pair in setproduct(var.ingress_cidrs, var.ingress_ports) : "${pair[0]}:${pair[1]}" => pair
  }

  security_group_id = aws_security_group.this.id
  description       = "App port ${each.value[1]}"
  ip_protocol       = "tcp"
  from_port         = each.value[1]
  to_port           = each.value[1]
  cidr_ipv4         = each.value[0]
}

# Only rendered when ssh_cidrs is non-empty: the default lab path is SSM Session Manager.
resource "aws_vpc_security_group_ingress_rule" "ssh" {
  for_each = toset(var.ssh_cidrs)

  security_group_id = aws_security_group.this.id
  description       = "SSH (scenario 31)"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_ipv4         = each.value
}

# Outbound HTTP(S) only: dnf repos, ECR/S3/SSM/CloudWatch APIs, GitHub, Docker Hub,
# packagist/npm during build-on-server. DNS (VPC resolver) and NTP (169.254.169.123) are not SG-filtered.
resource "aws_vpc_security_group_egress_rule" "web" {
  for_each = toset(["80", "443"])

  security_group_id = aws_security_group.this.id
  description       = "Outbound tcp/${each.value}"
  ip_protocol       = "tcp"
  from_port         = tonumber(each.value)
  to_port           = tonumber(each.value)
  cidr_ipv4         = "0.0.0.0/0"
}

# ---------------------------------------------------------------- instance

resource "aws_instance" "this" {
  ami                    = local.ami_id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.this.id]
  iam_instance_profile   = var.instance_profile
  key_name               = var.key_name
  user_data              = var.user_data
  monitoring             = false # detailed monitoring costs extra; 5-min metrics are enough here

  # IMDSv2 only (blocks SSRF-style credential theft). Hop limit 1 = containers on the
  # docker bridge cannot reach IMDS, so the app container can never borrow the instance role.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size
    encrypted             = true
    delete_on_termination = true
  }

  dynamic "credit_specification" {
    for_each = local.burstable ? [1] : []
    content {
      cpu_credits = var.cpu_credits
    }
  }

  tags = merge({ Name = var.name }, var.tags)

  lifecycle {
    # A newer AL2023 AMI or an edited user-data script must not silently replace a pet
    # server holding MySQL data. Roll it on purpose: terraform apply -replace=<address>.
    ignore_changes = [ami, user_data]
  }
}

resource "aws_eip" "this" {
  count = var.create_eip ? 1 : 0

  domain   = "vpc"
  instance = aws_instance.this.id
  tags     = { Name = var.name }
}
