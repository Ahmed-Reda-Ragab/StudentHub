# CodePipeline V2 (scenarios 36, 37, 58):
#   Source (CodeConnections / GitHub) -> Build (CodeBuild: image + imagedefinitions.json + imageDetail.json)
#   -> [Approval] -> Deploy ([Migrate] + ECS | CodeDeployToECS | CodeBuild deployer)

data "aws_partition" "current" {}
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region
  account_id = data.aws_caller_identity.current.account_id

  codebuild_projects = compact([var.build_project_name, var.migrate_project_name, var.deploy_project_name])
  codebuild_arns     = [for p in local.codebuild_projects : "arn:${local.partition}:codebuild:${local.region}:${local.account_id}:project/${p}"]

  run_migrations = var.migrate_project_name != null && var.deploy_mode != "codebuild"
}

# ---------------------------------------------------------------- artifact bucket

resource "aws_s3_bucket" "artifacts" {
  bucket        = "${var.name}-artifacts-${local.account_id}"
  force_destroy = true # ephemeral lab stack: destroy must not fail on leftover artifacts
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    object_ownership = "BucketOwnerEnforced" # ACLs disabled
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms" # aws/s3 managed key: no key policy to maintain, CodeBuild reads via S3
    }
    bucket_key_enabled = true # fewer KMS requests = cheaper
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    id     = "expire-artifacts"
    status = "Enabled"
    filter {}

    expiration {
      days = var.artifact_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

data "aws_iam_policy_document" "artifacts_bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.artifacts.arn, "${aws_s3_bucket.artifacts.arn}/*"]

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

resource "aws_s3_bucket_policy" "artifacts" {
  bucket     = aws_s3_bucket.artifacts.id
  policy     = data.aws_iam_policy_document.artifacts_bucket.json
  depends_on = [aws_s3_bucket_public_access_block.artifacts]
}

# ---------------------------------------------------------------- IAM

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["codepipeline.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "pipeline" {
  name               = "${var.name}-codepipeline"
  description        = "CodePipeline ${var.name}"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

data "aws_iam_policy_document" "pipeline" {
  statement {
    sid       = "ArtifactObjects"
    actions   = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject"]
    resources = ["${aws_s3_bucket.artifacts.arn}/*"]
  }

  statement {
    sid       = "ArtifactBucket"
    actions   = ["s3:GetBucketLocation", "s3:GetBucketVersioning", "s3:ListBucket"]
    resources = [aws_s3_bucket.artifacts.arn]
  }

  statement {
    sid       = "UseGitHubConnection"
    actions   = ["codeconnections:UseConnection", "codestar-connections:UseConnection"]
    resources = [var.codeconnections_arn]
  }

  statement {
    sid       = "RunCodeBuild"
    actions   = ["codebuild:StartBuild", "codebuild:BatchGetBuilds", "codebuild:StopBuild"]
    resources = local.codebuild_arns
  }

  # ECS deploy action: read the service's current task definition, register a copy with the new
  # image, update the service and poll it until it is stable.
  dynamic "statement" {
    for_each = var.deploy_mode == "ecs" ? [1] : []
    content {
      sid       = "EcsDeployService"
      actions   = ["ecs:DescribeServices", "ecs:UpdateService"]
      resources = ["arn:${local.partition}:ecs:${local.region}:${local.account_id}:service/${var.ecs_cluster_name}/${var.ecs_service_name}"]
    }
  }

  dynamic "statement" {
    for_each = var.deploy_mode == "ecs" ? [1] : []
    content {
      sid       = "EcsDeployTasks"
      actions   = ["ecs:DescribeTasks", "ecs:ListTasks"]
      resources = ["*"]
    }
  }

  # Task-definition APIs have no resource-level permissions for Register/Describe.
  dynamic "statement" {
    for_each = contains(["ecs", "codedeploy-ecs"], var.deploy_mode) ? [1] : []
    content {
      sid       = "RegisterTaskDefinition"
      actions   = ["ecs:DescribeTaskDefinition", "ecs:RegisterTaskDefinition", "ecs:TagResource"]
      resources = ["*"]
    }
  }

  dynamic "statement" {
    for_each = contains(["ecs", "codedeploy-ecs"], var.deploy_mode) && length(var.pass_role_arns) > 0 ? [1] : []
    content {
      sid       = "PassTaskRolesToEcs"
      actions   = ["iam:PassRole"]
      resources = var.pass_role_arns

      condition {
        test     = "StringEquals"
        variable = "iam:PassedToService"
        values   = ["ecs-tasks.amazonaws.com"]
      }
    }
  }

  dynamic "statement" {
    for_each = var.deploy_mode == "codedeploy-ecs" ? [1] : []
    content {
      sid = "CodeDeployToEcs"
      actions = [
        "codedeploy:CreateDeployment",
        "codedeploy:GetApplication",
        "codedeploy:GetApplicationRevision",
        "codedeploy:GetDeployment",
        "codedeploy:RegisterApplicationRevision",
      ]
      resources = [
        "arn:${local.partition}:codedeploy:${local.region}:${local.account_id}:application:${coalesce(var.codedeploy_app_name, "none")}",
        "arn:${local.partition}:codedeploy:${local.region}:${local.account_id}:deploymentgroup:${coalesce(var.codedeploy_app_name, "none")}/${coalesce(var.codedeploy_deployment_group_name, "none")}",
      ]
    }
  }

  dynamic "statement" {
    for_each = var.deploy_mode == "codedeploy-ecs" ? [1] : []
    content {
      sid       = "CodeDeployConfigs"
      actions   = ["codedeploy:GetDeploymentConfig"]
      resources = ["arn:${local.partition}:codedeploy:${local.region}:${local.account_id}:deploymentconfig:*"]
    }
  }

  dynamic "statement" {
    for_each = var.require_approval && var.approval_sns_topic_arn != null ? [1] : []
    content {
      sid       = "NotifyApprovers"
      actions   = ["sns:Publish"]
      resources = [var.approval_sns_topic_arn]
    }
  }
}

resource "aws_iam_role_policy" "pipeline" {
  name   = "codepipeline"
  role   = aws_iam_role.pipeline.id
  policy = data.aws_iam_policy_document.pipeline.json
}

# ---------------------------------------------------------------- pipeline

resource "aws_codepipeline" "this" {
  name           = var.name
  role_arn       = aws_iam_role.pipeline.arn
  pipeline_type  = "V2"
  execution_mode = var.execution_mode

  artifact_store {
    location = aws_s3_bucket.artifacts.bucket
    type     = "S3"
  }

  # V2 trigger: push to the branch, ignoring doc-only commits.
  trigger {
    provider_type = "CodeStarSourceConnection"
    git_configuration {
      source_action_name = "Source"
      push {
        branches {
          includes = [var.branch]
        }
        file_paths {
          excludes = var.trigger_file_path_excludes
        }
      }
    }
  }

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      namespace        = "SourceVariables" # #{SourceVariables.CommitId} etc.
      output_artifacts = ["source_output"]

      configuration = {
        ConnectionArn    = var.codeconnections_arn
        FullRepositoryId = var.github_repo
        BranchName       = var.branch
        DetectChanges    = "true"
      }
    }
  }

  stage {
    name = "Build"

    action {
      name             = "Image"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      namespace        = "BuildVariables" # exported IMAGE_URI / IMAGE_TAG
      input_artifacts  = ["source_output"]
      output_artifacts = ["build_output"]

      configuration = {
        ProjectName = var.build_project_name
      }
    }
  }

  dynamic "stage" {
    for_each = var.require_approval ? [1] : []
    content {
      name = "Approve"

      action {
        name     = "Promote"
        category = "Approval"
        owner    = "AWS"
        provider = "Manual"
        version  = "1"

        configuration = merge(
          { CustomData = "Deploy #{BuildVariables.IMAGE_URI} to ${coalesce(var.ecs_service_name, var.name)}?" },
          var.approval_sns_topic_arn == null ? {} : { NotificationArn = var.approval_sns_topic_arn },
        )
      }
    }
  }

  stage {
    name = "Deploy"

    # Migrations run once per release, BEFORE new code takes traffic (expand/contract, CONVENTIONS §2).
    dynamic "action" {
      for_each = local.run_migrations ? [1] : []
      content {
        name            = "Migrate"
        category        = "Build"
        owner           = "AWS"
        provider        = "CodeBuild"
        version         = "1"
        run_order       = 1
        input_artifacts = ["source_output", "build_output"]

        configuration = {
          ProjectName   = var.migrate_project_name
          PrimarySource = "source_output"
          EnvironmentVariables = jsonencode([
            { name = "DEPLOY_STEP", value = "migrate", type = "PLAINTEXT" },
          ])
        }
      }
    }

    dynamic "action" {
      for_each = var.deploy_mode == "ecs" ? [1] : []
      content {
        name            = "ECS"
        category        = "Deploy"
        owner           = "AWS"
        provider        = "ECS"
        version         = "1"
        run_order       = 2
        input_artifacts = ["build_output"]

        configuration = {
          ClusterName       = var.ecs_cluster_name
          ServiceName       = var.ecs_service_name
          FileName          = "imagedefinitions.json"
          DeploymentTimeout = tostring(var.deployment_timeout_minutes)
        }
      }
    }

    dynamic "action" {
      for_each = var.deploy_mode == "codedeploy-ecs" ? [1] : []
      content {
        name            = "CodeDeployBlueGreen"
        category        = "Deploy"
        owner           = "AWS"
        provider        = "CodeDeployToECS"
        version         = "1"
        run_order       = 2
        input_artifacts = ["build_output"]

        configuration = {
          ApplicationName                = var.codedeploy_app_name
          DeploymentGroupName            = var.codedeploy_deployment_group_name
          TaskDefinitionTemplateArtifact = "build_output"
          TaskDefinitionTemplatePath     = "taskdef.json"
          AppSpecTemplateArtifact        = "build_output"
          AppSpecTemplatePath            = "appspec.yaml"
          # imageDetail.json in build_output replaces <IMAGE1_NAME> in taskdef.json.
          Image1ArtifactName  = "build_output"
          Image1ContainerName = "IMAGE1_NAME"
        }
      }
    }

    dynamic "action" {
      for_each = var.deploy_mode == "codebuild" ? [1] : []
      content {
        name            = "MigrateAndDeploy"
        category        = "Build"
        owner           = "AWS"
        provider        = "CodeBuild"
        version         = "1"
        run_order       = 1
        input_artifacts = ["source_output", "build_output"]

        configuration = {
          ProjectName   = var.deploy_project_name
          PrimarySource = "source_output"
          EnvironmentVariables = jsonencode([
            { name = "DEPLOY_STEP", value = "all", type = "PLAINTEXT" },
          ])
        }
      }
    }
  }

  depends_on = [aws_iam_role_policy.pipeline]
}
