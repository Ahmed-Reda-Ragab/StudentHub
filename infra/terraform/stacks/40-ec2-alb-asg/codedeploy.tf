# Scenario 37 — CodeDeploy (EC2/Server) on the blue ASG, enabled with codedeploy_enabled = true.
#
#   revision bucket  ← deploy/codedeploy/ec2/package-revision.sh uploads the bundle here
#   application + deployment group (IN_PLACE, with traffic control on the blue target group:
#   deregister → hooks → /ready check → re-register, one instance at a time by default)
#
# The agent itself is installed by the asg-app user data (install_codedeploy_agent) and the
# instance role gets s3:GetObject on this bucket (iam.tf). Release commands: `terraform output codedeploy`.

locals {
  codedeploy_bucket = var.codedeploy_revision_bucket != "" ? var.codedeploy_revision_bucket : "${local.name}-codedeploy-${local.account_id}"
}

resource "aws_s3_bucket" "codedeploy_revisions" {
  count = var.codedeploy_enabled && var.codedeploy_revision_bucket == "" ? 1 : 0

  bucket        = local.codedeploy_bucket
  force_destroy = true # revisions are rebuildable from git; lab teardown must not get stuck
}

resource "aws_s3_bucket_public_access_block" "codedeploy_revisions" {
  count = length(aws_s3_bucket.codedeploy_revisions)

  bucket                  = aws_s3_bucket.codedeploy_revisions[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "codedeploy_revisions" {
  count = length(aws_s3_bucket.codedeploy_revisions)

  bucket = aws_s3_bucket.codedeploy_revisions[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "codedeploy_revisions" {
  count = length(aws_s3_bucket.codedeploy_revisions)

  bucket = aws_s3_bucket.codedeploy_revisions[0].id
  rule {
    id     = "expire-old-revisions"
    status = "Enabled"
    filter {}
    expiration {
      days = 30
    }
  }
}

module "codedeploy" {
  source = "../../modules/codedeploy"
  count  = var.codedeploy_enabled ? 1 : 0

  name                      = "${local.name}-ec2"
  compute_platform          = "Server"
  deployment_type           = "IN_PLACE" # BLUE_GREEN would copy the ASG outside Terraform state
  deployment_config_name    = var.codedeploy_deployment_config_name
  autoscaling_group_names   = [module.asg_blue.asg_name]
  server_target_group_names = [module.alb.target_group_names["blue"]]
  alarm_names               = [module.observability.alarm_names["alb_5xx_ratio"]]
}
