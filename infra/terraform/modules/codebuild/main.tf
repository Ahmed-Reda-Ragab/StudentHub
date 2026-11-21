# AWS CodeBuild projects (scenario 35; reused by stack 36 for pipeline build/deploy steps).
# Every project gets its own role, log group and (optionally) a GitHub webhook.

data "aws_partition" "current" {}
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region
  account_id = data.aws_caller_identity.current.account_id

  projects = { for k, p in var.projects : k => merge(p, { name = "${var.name_prefix}-${k}" }) }

  github_url = "https://github.com/${var.github_repo}.git"
}

resource "aws_cloudwatch_log_group" "this" {
  for_each = local.projects

  name              = "/aws/codebuild/${each.value.name}"
  retention_in_days = var.log_retention_days
}

# ---------------------------------------------------------------- IAM (one role per project)

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "this" {
  for_each = local.projects

  name               = "${each.value.name}-codebuild"
  description        = "CodeBuild project ${each.value.name}"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

data "aws_iam_policy_document" "project" {
  for_each = local.projects

  statement {
    sid       = "WriteOwnLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.this[each.key].arn}:*"]
  }

  # GitHub source through the CodeConnections GitHub App (no personal access token anywhere).
  # Both IAM prefixes: connections created before the 2024 rename have codestar-connections ARNs.
  dynamic "statement" {
    for_each = each.value.source_type == "GITHUB" ? [1] : []
    content {
      sid = "UseGitHubConnection"
      actions = [
        "codeconnections:GetConnection",
        "codeconnections:GetConnectionToken",
        "codeconnections:UseConnection",
        "codestar-connections:GetConnection",
        "codestar-connections:GetConnectionToken",
        "codestar-connections:UseConnection",
      ]
      resources = [var.codeconnections_arn]
    }
  }

  dynamic "statement" {
    for_each = each.value.source_type == "CODEPIPELINE" ? [1] : []
    content {
      sid       = "PipelineArtifacts"
      actions   = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject"]
      resources = ["${var.artifact_bucket_arn}/*"]
    }
  }

  dynamic "statement" {
    for_each = each.value.source_type == "CODEPIPELINE" ? [1] : []
    content {
      sid       = "PipelineArtifactBucket"
      actions   = ["s3:GetBucketLocation", "s3:GetBucketVersioning", "s3:ListBucket"]
      resources = [var.artifact_bucket_arn]
    }
  }

  dynamic "statement" {
    for_each = each.value.ecr_push ? [1] : []
    content {
      sid       = "EcrAuthToken"
      actions   = ["ecr:GetAuthorizationToken"]
      resources = ["*"]
    }
  }

  dynamic "statement" {
    for_each = each.value.ecr_push ? [1] : []
    content {
      sid = "EcrPushAppRepository"
      actions = [
        "ecr:BatchCheckLayerAvailability",
        "ecr:BatchGetImage",
        "ecr:CompleteLayerUpload",
        "ecr:DescribeImages",
        "ecr:GetDownloadUrlForLayer",
        "ecr:InitiateLayerUpload",
        "ecr:PutImage",
        "ecr:UploadLayerPart",
      ]
      resources = [var.ecr_repository_arn]
    }
  }

  dynamic "statement" {
    for_each = each.value.test_reports ? [1] : []
    content {
      sid = "TestReports"
      actions = [
        "codebuild:BatchPutCodeCoverages",
        "codebuild:BatchPutTestCases",
        "codebuild:CreateReport",
        "codebuild:CreateReportGroup",
        "codebuild:UpdateReport",
      ]
      resources = ["arn:${local.partition}:codebuild:${local.region}:${local.account_id}:report-group/${each.value.name}-*"]
    }
  }

  dynamic "statement" {
    for_each = length(each.value.parameter_store_variables) > 0 ? [1] : []
    content {
      sid     = "ReadBuildParameters"
      actions = ["ssm:GetParameters"]
      resources = [
        for p in values(each.value.parameter_store_variables) :
        "arn:${local.partition}:ssm:${local.region}:${local.account_id}:parameter/${trimprefix(p, "/")}"
      ]
    }
  }
}

resource "aws_iam_role_policy" "project" {
  for_each = local.projects

  name   = "codebuild"
  role   = aws_iam_role.this[each.key].id
  policy = data.aws_iam_policy_document.project[each.key].json
}

resource "aws_iam_role_policy" "extra" {
  for_each = { for k, p in local.projects : k => p if p.extra_policy_json != null }

  name   = "extra"
  role   = aws_iam_role.this[each.key].id
  policy = each.value.extra_policy_json
}

# ---------------------------------------------------------------- projects

resource "aws_codebuild_project" "this" {
  for_each = local.projects

  name                   = each.value.name
  description            = each.value.description
  service_role           = aws_iam_role.this[each.key].arn
  build_timeout          = each.value.build_timeout
  queued_timeout         = each.value.queued_timeout
  concurrent_build_limit = each.value.concurrent_build_limit

  artifacts {
    type = each.value.source_type == "CODEPIPELINE" ? "CODEPIPELINE" : "NO_ARTIFACTS"
  }

  environment {
    type                        = "LINUX_CONTAINER"
    compute_type                = each.value.compute_type
    image                       = coalesce(each.value.image, var.build_image)
    image_pull_credentials_type = "CODEBUILD"
    # Docker-in-Docker for `docker build`; never enable it on projects that do not build images.
    privileged_mode = each.value.privileged_mode

    dynamic "environment_variable" {
      for_each = each.value.environment_variables
      content {
        name  = environment_variable.key
        value = environment_variable.value
        type  = "PLAINTEXT"
      }
    }

    dynamic "environment_variable" {
      for_each = each.value.parameter_store_variables
      content {
        name  = environment_variable.key
        value = environment_variable.value
        type  = "PARAMETER_STORE"
      }
    }
  }

  dynamic "source" {
    for_each = each.value.source_type == "GITHUB" ? [1] : []
    content {
      type                = "GITHUB"
      location            = local.github_url
      buildspec           = each.value.buildspec
      git_clone_depth     = each.value.git_clone_depth
      report_build_status = true # commit status check on GitHub, like a GitHub Actions check

      auth {
        type     = "CODECONNECTIONS"
        resource = var.codeconnections_arn
      }
    }
  }

  dynamic "source" {
    for_each = each.value.source_type == "CODEPIPELINE" ? [1] : []
    content {
      type      = "CODEPIPELINE"
      buildspec = each.value.buildspec
    }
  }

  # LOCAL cache lives on the build host: free, best effort (warm when builds run close together).
  dynamic "cache" {
    for_each = length(each.value.cache_modes) > 0 ? [1] : []
    content {
      type  = "LOCAL"
      modes = each.value.cache_modes
    }
  }

  logs_config {
    cloudwatch_logs {
      status     = "ENABLED"
      group_name = aws_cloudwatch_log_group.this[each.key].name
    }

    s3_logs {
      status = "DISABLED"
    }
  }

  depends_on = [aws_iam_role_policy.project, aws_iam_role_policy.extra]
}

# CodeBuild creates the repository webhook through the CodeConnections GitHub App.
resource "aws_codebuild_webhook" "this" {
  for_each = { for k, p in local.projects : k => p if p.webhook != null }

  project_name = aws_codebuild_project.this[each.key].name
  build_type   = each.value.webhook.build_type

  dynamic "filter_group" {
    for_each = each.value.webhook.filter_groups
    content {
      dynamic "filter" {
        for_each = filter_group.value
        content {
          type                    = filter.value.type
          pattern                 = filter.value.pattern
          exclude_matched_pattern = filter.value.exclude_matched_pattern
        }
      }
    }
  }
}
