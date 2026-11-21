# Instance role: everything the host needs, nothing it does not.
#   SSM core          Session Manager + Run Command (CI deploys, scenario 32/33)
#   ECR pull          the student-app repo only
#   SSM params        read /student-app/<env>/* (render-env-from-ssm.sh) + decrypt via SSM only
#   CloudWatch agent  awslogs driver (deploy/ec2/compose.awslogs.yml) + host metrics
#   S3 backups        put/get dumps in the backups bucket (scenario 27)

data "aws_iam_policy_document" "ec2_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "host" {
  name               = "${local.name}-ec2-single"
  description        = "student-app single Docker host (stack 20)"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}

resource "aws_iam_role_policy_attachment" "host_managed" {
  for_each = toset([
    "AmazonSSMManagedInstanceCore",
    "CloudWatchAgentServerPolicy",
  ])

  role       = aws_iam_role.host.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/${each.value}"
}

data "aws_iam_policy_document" "host" {
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "EcrPullAppRepo"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = ["arn:${local.partition}:ecr:${local.region}:${local.account_id}:repository/${var.ecr_repository_name}"]
  }

  # GetParametersByPath is authorized on the PATH itself (…:parameter/student-app/lab/app),
  # so both the root and its children are listed.
  statement {
    sid = "ReadOwnParameters"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
    ]
    resources = [
      "arn:${local.partition}:ssm:${local.region}:${local.account_id}:parameter${local.ssm_root}",
      "arn:${local.partition}:ssm:${local.region}:${local.account_id}:parameter${local.ssm_root}/*",
    ]
  }

  # SecureString uses the AWS-managed aws/ssm key. Its alias may not exist yet in a fresh account,
  # so scope by "only when called through SSM" instead of by key ARN.
  statement {
    sid       = "DecryptSecureStringsViaSsm"
    actions   = ["kms:Decrypt"]
    resources = ["arn:${local.partition}:kms:${local.region}:${local.account_id}:key/*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${local.region}.amazonaws.com"]
    }
  }

  statement {
    sid       = "BackupsList"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.backups.arn]
  }

  statement {
    sid       = "BackupsReadWrite"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${aws_s3_bucket.backups.arn}/*"]
  }

  # backup-mysql-to-s3.sh uploads to <key>.partial and `s3 mv`s it on success (or removes it on
  # failure). Delete is allowed on those temporary objects ONLY: a compromised host still cannot
  # delete finished backups.
  statement {
    sid       = "BackupsCleanupPartialUploads"
    actions   = ["s3:DeleteObject"]
    resources = ["${aws_s3_bucket.backups.arn}/mysql/*.partial"]
  }
}

resource "aws_iam_role_policy" "host" {
  name   = "student-app-host"
  role   = aws_iam_role.host.id
  policy = data.aws_iam_policy_document.host.json
}

resource "aws_iam_instance_profile" "host" {
  name = aws_iam_role.host.name
  role = aws_iam_role.host.name
}
