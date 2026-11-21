# Transfer bucket for Ansible's amazon.aws.aws_ssm connection plugin (scenario 33):
# the controller uploads module files here and the instance fetches them through
# pre-signed URLs, so instances need no S3 permissions and port 22 stays closed.
# Objects are throw-away (expire after 1 day).
resource "aws_s3_bucket" "ansible_ssm" {
  bucket        = "${var.project}-ansible-ssm-${local.account_id}"
  force_destroy = true # only transient transfer files live here
}

resource "aws_s3_bucket_ownership_controls" "ansible_ssm" {
  bucket = aws_s3_bucket.ansible_ssm.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "ansible_ssm" {
  bucket                  = aws_s3_bucket.ansible_ssm.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "ansible_ssm" {
  bucket = aws_s3_bucket.ansible_ssm.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "ansible_ssm" {
  bucket = aws_s3_bucket.ansible_ssm.id
  rule {
    id     = "expire-transfers"
    status = "Enabled"
    filter {}
    expiration {
      days = 1
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}
