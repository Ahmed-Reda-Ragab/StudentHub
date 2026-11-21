# Stack 20 — single EC2 Docker host (scenarios 20–27, 31–33).
#
#   internet ──► EIP :80 ──► EC2 (AL2023, Docker Compose)
#                              ├─ app    (docker-compose.prod.yml or deploy/ec2/lb blue/green)
#                              └─ mysql  (local container, dumps to the backups bucket)
#
# Config & secrets: SSM /student-app/<env>/{app,mysql}/* (ssm.tf), rendered on the host by
# deploy/ec2/render-env-from-ssm.sh. Access: SSM Session Manager (no SSH key, no port 22).
# Public subnet + EIP and no NAT: the cheapest possible always-reachable host.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  name       = "${var.project}-${var.env}" # student-app-lab
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region

  ssm_root  = "/${var.project}/${var.env}" # /student-app/lab
  ssm_app   = "${local.ssm_root}/app"
  ssm_mysql = "${local.ssm_root}/mysql"

  ecr_repository_url = "${local.account_id}.dkr.ecr.${local.region}.amazonaws.com/${var.ecr_repository_name}"
}

module "network" {
  source = "../../modules/network"

  name       = local.name
  cidr       = var.vpc_cidr
  az_count   = 2 # subnets are free; keeps the VPC ready for an ALB later
  enable_nat = false
}

module "host" {
  source = "../../modules/ec2-docker-host"

  name          = "${local.name}-app"
  vpc_id        = module.network.vpc_id
  subnet_id     = module.network.public_subnet_ids[0]
  instance_type = var.instance_type
  arch          = var.arch
  ami_id        = var.ami_id
  key_name      = var.key_name
  ingress_cidrs = var.http_cidrs
  ssh_cidrs     = var.ssh_cidrs

  # The same script the docs use for a console-launched instance: Docker + Compose + Buildx, swap.
  user_data        = file("${path.module}/../../../../deploy/ec2/user-data.sh")
  instance_profile = aws_iam_instance_profile.host.name

  # Role=app -> Ansible inventory group role_app (CONVENTIONS §7).
  tags = { Role = "app" }
}

# ---------------------------------------------------------------- backups bucket (scenario 27)

resource "aws_s3_bucket" "backups" {
  bucket        = "${local.name}-backups-${local.account_id}" # BACKUP_BUCKET in deploy/ec2/backup-mysql-to-s3.sh
  force_destroy = var.backup_bucket_force_destroy
}

resource "aws_s3_bucket_ownership_controls" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket                  = aws_s3_bucket.backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Retention is enforced by the bucket, not by the backup script.
resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  rule {
    id     = "expire-dumps"
    status = "Enabled"
    filter {}

    expiration {
      days = var.backup_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

data "aws_iam_policy_document" "backups_tls_only" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.backups.arn, "${aws_s3_bucket.backups.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "backups" {
  bucket     = aws_s3_bucket.backups.id
  policy     = data.aws_iam_policy_document.backups_tls_only.json
  depends_on = [aws_s3_bucket_public_access_block.backups]
}

# Log group for the optional awslogs override (deploy/ec2/compose.awslogs.yml, scenario 70).
# Pre-creating it gives it a retention; one auto-created by the Docker driver never expires.
resource "aws_cloudwatch_log_group" "app" {
  name              = "/student-app/${var.env}/app"
  retention_in_days = var.log_retention_days
}
