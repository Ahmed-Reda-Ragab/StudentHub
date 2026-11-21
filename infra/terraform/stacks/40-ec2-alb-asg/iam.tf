# Instance role shared by blue and green instances.
#   SSM core          Session Manager + Run Command (one-off migrations)
#   CloudWatch agent  awslogs driver -> /student-app/<env>/app
#   ECR pull          the student-app repo only
#   SSM params        read /student-app/<env>/* (app.env + deploy/<color>/IMAGE_URI) + decrypt via SSM

data "aws_iam_policy_document" "ec2_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "app" {
  name               = "${local.name}-asg-app"
  description        = "student-app ASG instances (stack 40)"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}

resource "aws_iam_role_policy_attachment" "app_managed" {
  for_each = toset([
    "AmazonSSMManagedInstanceCore",
    "CloudWatchAgentServerPolicy",
  ])

  role       = aws_iam_role.app.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/${each.value}"
}

data "aws_iam_policy_document" "app" {
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
}

resource "aws_iam_role_policy" "app" {
  name   = "student-app-instance"
  role   = aws_iam_role.app.id
  policy = data.aws_iam_policy_document.app.json
}

resource "aws_iam_instance_profile" "app" {
  name = aws_iam_role.app.name
  role = aws_iam_role.app.name
}

# Scenario 37 (CodeDeploy on this ASG): the agent downloads revisions from S3.
resource "aws_iam_role_policy" "codedeploy_revisions" {
  count = var.codedeploy_enabled ? 1 : 0

  name = "student-app-codedeploy-revisions"
  role = aws_iam_role.app.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "ReadCodeDeployRevisions"
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:GetObjectVersion"]
      Resource = "arn:${local.partition}:s3:::${local.codedeploy_bucket}/*"
    }]
  })
}
