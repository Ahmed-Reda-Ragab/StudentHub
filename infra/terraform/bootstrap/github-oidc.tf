# GitHub Actions -> AWS with OIDC (scenario 30): every job gets short-lived credentials
# for ONE role, and only if the token's `sub` claim matches this repo + branch/environment.
# No long-lived access keys exist anywhere.
#
#   student-app-gha-ci              push images to ECR                         (ci.yml, main/master)
#   student-app-gha-deploy          roll out releases (ECS/ASG/SSM/ALB/CodeDeploy) (deploy workflows)
#   student-app-gha-terraform       terraform apply/destroy — ADMIN, gated by environment `lab`
#   student-app-gha-terraform-plan  terraform plan on PRs / any branch — READ-ONLY
#
# sub claim formats (default GitHub OIDC template):
#   repo:<owner>/<repo>:ref:refs/heads/<branch>   job without an environment
#   repo:<owner>/<repo>:environment:<name>        job with `environment: <name>` (no ref in the claim!)
#   repo:<owner>/<repo>:pull_request              pull_request events (fork PRs never get a token)

locals {
  oidc_host = "token.actions.githubusercontent.com"
  oidc_provider_arn = (var.create_github_oidc_provider
    ? aws_iam_openid_connect_provider.github[0].arn
    : data.aws_iam_openid_connect_provider.github[0].arn
  )

  repo_sub    = "repo:${var.github_repo}"
  ci_subjects = [for b in var.ci_branches : "${local.repo_sub}:ref:refs/heads/${b}"]
  deploy_subjects = concat(
    [for b in var.deploy_branches : "${local.repo_sub}:ref:refs/heads/${b}"],
    [for e in var.deploy_environments : "${local.repo_sub}:environment:${e}"],
  )
  terraform_subjects = concat(
    [for b in var.terraform_branches : "${local.repo_sub}:ref:refs/heads/${b}"],
    [for e in var.terraform_environments : "${local.repo_sub}:environment:${e}"],
  )
  plan_subjects = [
    "${local.repo_sub}:pull_request",
    "${local.repo_sub}:ref:refs/heads/*",
  ]

  ecr_repository_arn = aws_ecr_repository.app.arn
}

# Thumbprints are optional: AWS validates GitHub's certificate against its trusted CA store.
resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 1 : 0

  url            = "https://${local.oidc_host}"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 0 : 1

  url = "https://${local.oidc_host}"
}

# One trust-policy document per role, differing only in the allowed subjects.
data "aws_iam_policy_document" "trust" {
  for_each = {
    ci        = local.ci_subjects
    deploy    = local.deploy_subjects
    terraform = local.terraform_subjects
    plan      = local.plan_subjects
  }

  statement {
    sid     = "GitHubActionsOIDC"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "${local.oidc_host}:sub"
      values   = each.value
    }
  }
}

# ================================================================= CI (push images)

resource "aws_iam_role" "ci" {
  name                 = "${var.project}-gha-ci"
  description          = "GitHub Actions CI: push/pull ${var.ecr_repository_name} images only"
  assume_role_policy   = data.aws_iam_policy_document.trust["ci"].json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "ci" {
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"] # account-level call, cannot be scoped to a repo
    resources = ["*"]
  }

  statement {
    sid = "EcrPushPullThisRepoOnly"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [local.ecr_repository_arn]
  }
}

resource "aws_iam_role_policy" "ci" {
  name   = "ecr-push"
  role   = aws_iam_role.ci.id
  policy = data.aws_iam_policy_document.ci.json
}

# ================================================================= deploy (roll out releases)

data "aws_iam_policy_document" "deploy" {
  # ---- ECR: verify the tag exists, let runners pull (e.g. smoke tests)
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "EcrPull"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:DescribeImages",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [local.ecr_repository_arn]
  }

  # ---- ECS (scenarios 50-58): new task definition revision -> update service, one-off migration task
  statement {
    sid = "EcsTaskDefinitions"
    # RegisterTaskDefinition / Describe / List do not support resource-level permissions.
    actions = [
      "ecs:DescribeTaskDefinition",
      "ecs:ListTaskDefinitions",
      "ecs:RegisterTaskDefinition",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "EcsServices"
    actions   = ["ecs:DescribeServices", "ecs:UpdateService"]
    resources = ["arn:${local.partition}:ecs:${local.region}:${local.account_id}:service/${var.project}-*/*"]
  }

  statement {
    sid       = "EcsClusters"
    actions   = ["ecs:DescribeClusters"]
    resources = ["arn:${local.partition}:ecs:${local.region}:${local.account_id}:cluster/${var.project}-*"]
  }

  statement {
    sid       = "EcsMigrationTask"
    actions   = ["ecs:RunTask"]
    resources = ["arn:${local.partition}:ecs:${local.region}:${local.account_id}:task-definition/${var.project}-*:*"]
  }

  statement {
    sid       = "EcsTasks"
    actions   = ["ecs:DescribeTasks", "ecs:StopTask"]
    resources = ["arn:${local.partition}:ecs:${local.region}:${local.account_id}:task/${var.project}-*/*"]
  }

  statement {
    sid       = "EcsListTasks"
    actions   = ["ecs:ListTasks"]
    resources = ["*"]
  }

  # Tagging on create (task definitions / RunTask with propagated tags) and nothing else.
  statement {
    sid       = "EcsTagOnCreate"
    actions   = ["ecs:TagResource"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "ecs:CreateAction"
      values   = ["RegisterTaskDefinition", "RunTask"]
    }
  }

  # A new task definition references the task + execution roles; ECS is the only allowed consumer.
  statement {
    sid       = "PassTaskRolesToEcsOnly"
    actions   = ["iam:PassRole"]
    resources = [for e in var.app_environments : "arn:${local.partition}:iam::${local.account_id}:role/${var.project}-${e}-*"]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }

  # ---- EC2 single host (scenarios 32, 33): SSM Run Command, only on instances of this project
  statement {
    sid     = "SsmSendCommandProjectInstances"
    actions = ["ssm:SendCommand"]
    resources = [
      "arn:${local.partition}:ec2:${local.region}:${local.account_id}:instance/*",
    ]
    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Project"
      values   = [var.project]
    }
  }

  statement {
    sid       = "SsmSendCommandShellDocument"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:${local.partition}:ssm:${local.region}::document/AWS-RunShellScript"]
  }

  statement {
    sid = "SsmCommandResults"
    # Result/listing APIs are not resource-scopable.
    actions = [
      "ssm:DescribeInstanceInformation",
      "ssm:GetCommandInvocation",
      "ssm:ListCommandInvocations",
      "ssm:ListCommands",
      "ec2:DescribeInstances",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "SsmCancelTimedOutCommands"
    actions   = ["ssm:CancelCommand"] # best-effort cleanup in deploy-ec2-ssm.yml; not resource-scopable in practice
    resources = ["*"]
  }

  # ---- Ansible over SSM (scenario 33, amazon.aws.aws_ssm connection): sessions only on
  # this project's instances; files travel through the short-lived transfer bucket below.
  statement {
    sid     = "SsmSessionsProjectInstances"
    actions = ["ssm:StartSession"]
    resources = [
      "arn:${local.partition}:ec2:${local.region}:${local.account_id}:instance/*",
    ]
    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Project"
      values   = [var.project]
    }
  }

  statement {
    sid     = "SsmSessionDocuments"
    actions = ["ssm:StartSession"]
    resources = [
      "arn:${local.partition}:ssm:${local.region}::document/AWS-StartInteractiveCommand",
      "arn:${local.partition}:ssm:${local.region}:${local.account_id}:document/SSM-SessionManagerRunShell",
    ]
  }

  statement {
    sid       = "SsmOwnSessions"
    actions   = ["ssm:TerminateSession", "ssm:ResumeSession"]
    resources = ["arn:${local.partition}:ssm:${local.region}:${local.account_id}:session/*"]
  }

  statement {
    sid       = "AnsibleSsmTransferBucket"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.ansible_ssm.arn}/*"]
  }

  statement {
    sid       = "AnsibleSsmTransferBucketList"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.ansible_ssm.arn]
  }

  # ---- Release pointer for immutable fleets (CONVENTIONS §4): /<project>/<env>/deploy/<color>/IMAGE_URI
  statement {
    sid = "DeployParameters"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameterHistory", # rollback = previous value
      "ssm:GetParameters",
      "ssm:PutParameter",
    ]
    resources = ["arn:${local.partition}:ssm:${local.region}:${local.account_id}:parameter/${var.project}/*/deploy/*"]
  }

  # ---- ASG (scenarios 42-48): instance refresh, scale the idle color up/down
  statement {
    sid = "AsgRollout"
    actions = [
      "autoscaling:CancelInstanceRefresh",
      "autoscaling:RollbackInstanceRefresh",
      "autoscaling:SetDesiredCapacity",
      "autoscaling:StartInstanceRefresh",
      "autoscaling:UpdateAutoScalingGroup",
    ]
    resources = ["arn:${local.partition}:autoscaling:${local.region}:${local.account_id}:autoScalingGroup:*:autoScalingGroupName/${var.project}-*"]
  }

  statement {
    sid       = "AsgDescribe"
    actions   = ["autoscaling:Describe*"]
    resources = ["*"]
  }

  # ---- ALB (scenarios 44-46): weight shifts on the listener / rules of this project's ALBs
  statement {
    sid     = "AlbShiftTraffic"
    actions = ["elasticloadbalancing:ModifyListener", "elasticloadbalancing:ModifyRule"]
    resources = [
      "arn:${local.partition}:elasticloadbalancing:${local.region}:${local.account_id}:listener/app/${var.project}-*/*/*",
      "arn:${local.partition}:elasticloadbalancing:${local.region}:${local.account_id}:listener-rule/app/${var.project}-*/*/*/*",
    ]
  }

  statement {
    sid       = "AlbDescribe"
    actions   = ["elasticloadbalancing:Describe*"]
    resources = ["*"]
  }

  # ---- CodeDeploy (scenarios 37, 58): ECS blue/green deployments
  statement {
    sid = "CodeDeployDeployments"
    actions = [
      "codedeploy:ContinueDeployment",
      "codedeploy:CreateDeployment",
      "codedeploy:GetApplication",
      "codedeploy:GetApplicationRevision",
      "codedeploy:GetDeployment",
      "codedeploy:GetDeploymentConfig",
      "codedeploy:GetDeploymentGroup",
      "codedeploy:ListDeployments",
      "codedeploy:RegisterApplicationRevision",
      "codedeploy:StopDeployment",
    ]
    resources = [
      "arn:${local.partition}:codedeploy:${local.region}:${local.account_id}:application:${var.project}-*",
      "arn:${local.partition}:codedeploy:${local.region}:${local.account_id}:deploymentgroup:${var.project}-*/*",
      "arn:${local.partition}:codedeploy:${local.region}:${local.account_id}:deploymentconfig:*",
    ]
  }

  # ---- EKS (scenarios 60+): update-kubeconfig. Cluster access itself is granted by an EKS access entry.
  statement {
    sid       = "EksKubeconfig"
    actions   = ["eks:DescribeCluster"]
    resources = ["arn:${local.partition}:eks:${local.region}:${local.account_id}:cluster/${var.project}-*"]
  }

  # ---- Deployment gates: read alarms/metrics (canary analysis) and migration task logs
  statement {
    sid       = "ReadAlarmsAndMetrics"
    actions   = ["cloudwatch:DescribeAlarms", "cloudwatch:GetMetricData"]
    resources = ["*"]
  }

  statement {
    sid     = "ReadAppLogs"
    actions = ["logs:FilterLogEvents", "logs:GetLogEvents"]
    resources = [
      "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:*${var.project}*",
      "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:*${var.project}*:log-stream:*",
    ]
  }
}

resource "aws_iam_role" "deploy" {
  name                 = "${var.project}-gha-deploy"
  description          = "GitHub Actions deploy: roll out releases of ${var.project} (scoped, no create/delete of infra)"
  assume_role_policy   = data.aws_iam_policy_document.trust["deploy"].json
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "deploy" {
  name   = "deploy"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy.json
}

# ================================================================= terraform (admin, gated)

# LAB SHORTCUT, on purpose: the stacks create VPCs, IAM roles, EKS, RDS... — a least-privilege
# policy for "everything Terraform may ever create" is a project of its own. The blast radius is
# contained instead by the TRUST policy (only jobs running in the `lab` environment — set required reviewers on it —
# terraform_branches is empty by default) and by plans running under the read-only role below.
# How to tighten (scenario 80 discussion):
#   1. CloudTrail + IAM Access Analyzer "generate policy" from a few apply/destroy runs;
#   2. one role per stack with that generated policy;
#   3. a permissions boundary that denies iam:* on roles outside <project>-* and blocks
#      org/account/billing APIs, so even a compromised workflow cannot escalate.
resource "aws_iam_role" "terraform" {
  name                 = "${var.project}-gha-terraform"
  description          = "GitHub Actions terraform apply/destroy (lab: AdministratorAccess, trust-gated)"
  assume_role_policy   = data.aws_iam_policy_document.trust["terraform"].json
  max_session_duration = 7200 # EKS create/destroy can exceed 1h
}

resource "aws_iam_role_policy_attachment" "terraform_admin" {
  role       = aws_iam_role.terraform.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AdministratorAccess"
}

# ================================================================= terraform plan (read-only)

# Plans run on PRs and from any branch, so this role can be assumed by any code a collaborator
# pushes (a PR can edit the workflow itself). It therefore gets READ-ONLY access.
# Caveat to know for interviews: read-only still reads the state bucket and SecureStrings
# (plan needs them to refresh), so repository write access = secret read access.
resource "aws_iam_role" "terraform_plan" {
  count = var.create_terraform_plan_role ? 1 : 0

  name                 = "${var.project}-gha-terraform-plan"
  description          = "GitHub Actions terraform plan (read-only) for PRs / workflow_dispatch plan"
  assume_role_policy   = data.aws_iam_policy_document.trust["plan"].json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "terraform_plan_readonly" {
  count = var.create_terraform_plan_role ? 1 : 0

  role       = aws_iam_role.terraform_plan[0].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/ReadOnlyAccess"
}

# ReadOnlyAccess lacks the two reads `terraform plan` needs on secrets:
# decrypting SecureString parameters and reading this project's Secrets Manager secrets.
# Plans run with -lock=false, so no write access to the state bucket is needed.
data "aws_iam_policy_document" "terraform_plan_extra" {
  statement {
    sid       = "DecryptViaSsmAndSecretsManagerOnly"
    actions   = ["kms:Decrypt"]
    resources = ["arn:${local.partition}:kms:${local.region}:${local.account_id}:key/*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values = [
        "ssm.${local.region}.amazonaws.com",
        "secretsmanager.${local.region}.amazonaws.com",
      ]
    }
  }

  statement {
    sid       = "ReadProjectSecrets"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["arn:${local.partition}:secretsmanager:${local.region}:${local.account_id}:secret:${var.project}*"]
  }
}

resource "aws_iam_role_policy" "terraform_plan_extra" {
  count = var.create_terraform_plan_role ? 1 : 0

  name   = "plan-secrets-read"
  role   = aws_iam_role.terraform_plan[0].id
  policy = data.aws_iam_policy_document.terraform_plan_extra.json
}
