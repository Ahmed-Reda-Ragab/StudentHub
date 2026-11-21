# Bootstrap — applied ONCE per account, long-lived (scenarios 02, 30, 80):
#   main.tf             S3 remote-state bucket (S3-native locking, no DynamoDB)
#   github-oidc.tf      GitHub OIDC provider + CI / deploy / terraform roles (no stored AWS keys)
#   ecr.tf              ECR repository student-app (immutable tags, scan on push, lifecycle)
#   codeconnections.tf  GitHub connection for CodePipeline
# Everything else lives in ephemeral stacks under ../stacks (apply -> practise -> destroy).

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region

  # Account ID in the name: bucket names are global, and this keeps them collision-free.
  state_bucket = "${var.project}-tfstate-${local.account_id}"
}

# ---------------------------------------------------------------- remote state bucket

resource "aws_s3_bucket" "state" {
  bucket        = local.state_bucket
  force_destroy = var.state_bucket_force_destroy
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    object_ownership = "BucketOwnerEnforced" # ACLs off; IAM decides everything
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Versioning = undo for state: every write keeps the previous version.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

# State holds secrets (DB passwords, APP_KEY): encrypted at rest. SSE-S3 is free;
# switch to aws:kms with a CMK when you need key-level access control and CloudTrail per decrypt.
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"
    filter {} # whole bucket

    noncurrent_version_expiration {
      noncurrent_days           = var.state_noncurrent_days
      newer_noncurrent_versions = 10 # always keep the last 10 versions, whatever their age
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.state]
}

data "aws_iam_policy_document" "state_bucket" {
  # Encryption in transit is not optional for a bucket full of secrets.
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]

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

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.state]
}
