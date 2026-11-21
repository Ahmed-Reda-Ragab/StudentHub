# Stack 35 — AWS CodeBuild as CI (scenario 35): the same gates as GitHub Actions, run on AWS.
#   student-app-ci          pint + tests (buildspec-ci.yml), webhook on push/PR, JUnit report group
#   student-app-image       docker build + push to ECR (buildspec-build.yml), privileged, layer cache
#   student-app-gha-runner  optional CodeBuild-hosted GitHub Actions runner (WORKFLOW_JOB_QUEUED)

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

locals {
  account_id         = data.aws_caller_identity.current.account_id
  ecr_repository_arn = "arn:${data.aws_partition.current.partition}:ecr:${var.region}:${local.account_id}:repository/${var.ecr_repository_name}"
  ci_branch_regex    = "^refs/heads/(${join("|", var.ci_branches)})$"

  dockerhub_parameters = merge(
    var.dockerhub_username_parameter == null ? {} : { DOCKERHUB_USERNAME = var.dockerhub_username_parameter },
    var.dockerhub_token_parameter == null ? {} : { DOCKERHUB_TOKEN = var.dockerhub_token_parameter },
  )

  all_projects = {
    ci = {
      description     = "CI: pint + php artisan test (scenario 35)"
      buildspec       = "deploy/codebuild/buildspec-ci.yml"
      build_timeout   = 20
      cache_modes     = ["LOCAL_CUSTOM_CACHE", "LOCAL_SOURCE_CACHE"]
      test_reports    = true
      privileged_mode = false
      webhook = var.enable_ci_webhook ? {
        build_type = "BUILD"
        filter_groups = [
          [
            { type = "EVENT", pattern = "PUSH" },
            { type = "HEAD_REF", pattern = local.ci_branch_regex },
          ],
          [
            { type = "EVENT", pattern = "PULL_REQUEST_CREATED,PULL_REQUEST_UPDATED,PULL_REQUEST_REOPENED" },
          ],
        ]
      } : null
    }

    image = {
      description     = "Build the image once, push the git-SHA tag to ECR (scenario 35)"
      buildspec       = "deploy/codebuild/buildspec-build.yml"
      build_timeout   = 30
      privileged_mode = true # Docker daemon for docker build
      # Layer cache on the build host: a second build within minutes reuses vendor/npm layers.
      cache_modes = ["LOCAL_DOCKER_LAYER_CACHE", "LOCAL_SOURCE_CACHE"]
      ecr_push    = true
      environment_variables = {
        ECR_REPO       = var.ecr_repository_name
        ENV_NAME       = var.env
        AWS_ACCOUNT_ID = local.account_id
      }
      parameter_store_variables = local.dockerhub_parameters
      webhook = var.enable_image_webhook ? {
        build_type = "BUILD"
        filter_groups = [[
          { type = "EVENT", pattern = "PUSH" },
          { type = "HEAD_REF", pattern = "^refs/heads/${var.image_branch}$" },
        ]]
      } : null
    }

    # GitHub sends workflow_job "queued"; CodeBuild starts an ephemeral runner for jobs whose
    # runs-on label is codebuild-student-app-gha-runner-${{ github.run_id }}-${{ github.run_attempt }}.
    gha-runner = {
      description     = "CodeBuild-hosted GitHub Actions runner (scenario 35)"
      buildspec       = null # the runner executes the workflow job, not a buildspec
      build_timeout   = 60
      privileged_mode = true # jobs may run docker build
      ecr_push        = var.gha_runner_ecr_push
      webhook = {
        build_type = "BUILD"
        filter_groups = [[
          { type = "EVENT", pattern = "WORKFLOW_JOB_QUEUED" },
        ]]
      }
    }
  }

  projects = { for k, p in local.all_projects : k => p if k != "gha-runner" || var.enable_gha_runner }
}

module "codebuild" {
  source = "../../modules/codebuild"

  name_prefix         = var.project
  github_repo         = var.github_repo
  codeconnections_arn = var.codeconnections_arn
  build_image         = var.build_image
  ecr_repository_arn  = local.ecr_repository_arn
  projects            = local.projects
}
