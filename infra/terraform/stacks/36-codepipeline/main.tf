# Stack 36 — CodePipeline V2 for the ECS service of stack 50 (scenarios 36, 37, 58).
#   Source (CodeConnections) -> Build (CodeBuild: image + imagedefinitions.json/imageDetail.json)
#   -> [Approve] -> Deploy: [Migrate] + ECS | CodeDeployToECS | CodeBuild deployer
# Its own CODEPIPELINE-source CodeBuild projects keep this stack independent of stack 35.

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

locals {
  partition  = data.aws_partition.current.partition
  account_id = data.aws_caller_identity.current.account_id
  name       = "${var.project}-${var.env}" # student-app-lab

  # Stack 50 inputs, defaulting to the names stack 50 derives from project/env.
  ecs_cluster_name        = coalesce(var.ecs_cluster_name, local.name)
  ecs_service_name        = coalesce(var.ecs_service_name, "${local.name}-app")
  task_family             = coalesce(var.task_family, "${local.name}-app")
  task_execution_role_arn = coalesce(var.task_execution_role_arn, "arn:${local.partition}:iam::${local.account_id}:role/${local.name}-ecs-execution")
  task_role_arn           = coalesce(var.task_role_arn, "arn:${local.partition}:iam::${local.account_id}:role/${local.name}-ecs-task")
  app_log_group_arn       = coalesce(var.app_log_group_arn, "arn:${local.partition}:logs:${var.region}:${local.account_id}:log-group:/ecs/${local.name}/app")

  ecr_repository_arn = "arn:${local.partition}:ecr:${var.region}:${local.account_id}:repository/${var.ecr_repository_name}"
  cluster_arn        = "arn:${local.partition}:ecs:${var.region}:${local.account_id}:cluster/${local.ecs_cluster_name}"

  needs_deploy_project = var.deploy_mode == "codebuild" || var.run_migrations
}

# ---------------------------------------------------------------- CodeBuild permissions

# The deployer (migrate / update-service): exactly one service, one family, its two roles.
data "aws_iam_policy_document" "deploy" {
  statement {
    sid       = "Service"
    actions   = ["ecs:DescribeServices", "ecs:UpdateService"]
    resources = ["arn:${local.partition}:ecs:${var.region}:${local.account_id}:service/${local.ecs_cluster_name}/${local.ecs_service_name}"]
  }

  statement {
    sid       = "TaskDefinitions" # no resource-level permissions for these two
    actions   = ["ecs:DescribeTaskDefinition", "ecs:RegisterTaskDefinition"]
    resources = ["*"]
  }

  statement {
    sid       = "MigrationTaskInThisClusterOnly"
    actions   = ["ecs:RunTask"]
    resources = ["arn:${local.partition}:ecs:${var.region}:${local.account_id}:task-definition/${local.task_family}:*"]

    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [local.cluster_arn]
    }
  }

  statement {
    sid       = "WatchTasks"
    actions   = ["ecs:DescribeTasks"]
    resources = ["arn:${local.partition}:ecs:${var.region}:${local.account_id}:task/${local.ecs_cluster_name}/*"]
  }

  statement {
    sid       = "ListTasks"
    actions   = ["ecs:ListTasks"]
    resources = ["*"]
  }

  statement {
    sid       = "TagOnCreateOnly"
    actions   = ["ecs:TagResource"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "ecs:CreateAction"
      values   = ["RegisterTaskDefinition", "RunTask"]
    }
  }

  statement {
    sid       = "PassTaskRolesToEcsOnly"
    actions   = ["iam:PassRole"]
    resources = [local.task_execution_role_arn, local.task_role_arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }

  statement {
    sid       = "ReadMigrationLogs"
    actions   = ["logs:GetLogEvents"]
    resources = ["${local.app_log_group_arn}:log-stream:*"]
  }
}

# The image project only needs ECS read access when it copies the live task definition.
data "aws_iam_policy_document" "image_live_taskdef" {
  statement {
    sid       = "ReadTaskDefinition"
    actions   = ["ecs:DescribeTaskDefinition"]
    resources = ["*"]
  }
}

locals {
  all_projects = {
    image = {
      description     = "Pipeline build: image + imagedefinitions.json / imageDetail.json / taskdef.json / appspec.yaml"
      source_type     = "CODEPIPELINE"
      buildspec       = "deploy/codebuild/buildspec-build.yml"
      privileged_mode = true
      cache_modes     = ["LOCAL_DOCKER_LAYER_CACHE", "LOCAL_SOURCE_CACHE"]
      ecr_push        = true
      environment_variables = {
        ECR_REPO       = var.ecr_repository_name
        ENV_NAME       = var.env
        AWS_ACCOUNT_ID = local.account_id
        TASKDEF_SOURCE = var.taskdef_source
        TASK_FAMILY    = local.task_family
      }
      extra_policy_json = var.taskdef_source == "live" ? data.aws_iam_policy_document.image_live_taskdef.json : null
    }

    deploy = {
      description       = "Pipeline deploy step: migrations (+ update-service for deploy_mode = codebuild)"
      source_type       = "CODEPIPELINE"
      buildspec         = "deploy/codebuild/buildspec-deploy-ecs.yml"
      build_timeout     = 60
      privileged_mode   = false
      extra_policy_json = data.aws_iam_policy_document.deploy.json
      environment_variables = {
        ECS_CLUSTER = local.ecs_cluster_name
        ECS_SERVICE = local.ecs_service_name
        TASK_FAMILY = local.task_family
      }
    }
  }

  projects = { for k, p in local.all_projects : k => p if k != "deploy" || local.needs_deploy_project }
}

module "codebuild" {
  source = "../../modules/codebuild"

  name_prefix         = "${local.name}-pipeline"
  github_repo         = var.github_repo
  build_image         = var.build_image
  ecr_repository_arn  = local.ecr_repository_arn
  artifact_bucket_arn = module.pipeline.artifact_bucket_arn
  projects            = local.projects
}

# ---------------------------------------------------------------- pipeline

module "pipeline" {
  source = "../../modules/codepipeline"

  name                = "${local.name}-pipeline"
  codeconnections_arn = var.codeconnections_arn
  github_repo         = var.github_repo
  branch              = var.branch

  build_project_name   = module.codebuild.project_names["image"]
  deploy_mode          = var.deploy_mode
  migrate_project_name = var.run_migrations && var.deploy_mode != "codebuild" ? try(module.codebuild.project_names["deploy"], null) : null
  deploy_project_name  = var.deploy_mode == "codebuild" ? try(module.codebuild.project_names["deploy"], null) : null

  ecs_cluster_name                 = local.ecs_cluster_name
  ecs_service_name                 = local.ecs_service_name
  codedeploy_app_name              = var.codedeploy_app_name
  codedeploy_deployment_group_name = var.codedeploy_deployment_group_name
  pass_role_arns                   = [local.task_execution_role_arn, local.task_role_arn]

  require_approval       = var.require_approval
  approval_sns_topic_arn = var.approval_sns_topic_arn
}
