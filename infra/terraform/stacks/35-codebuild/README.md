# Stack 35 — AWS CodeBuild (scenario 35)

The CI of `.github/workflows/ci.yml`, rebuilt on AWS CodeBuild with [`modules/codebuild`](../../modules/codebuild):

| Project | Buildspec | Trigger | Permissions |
|---|---|---|---|
| `student-app-ci` | [`buildspec-ci.yml`](../../../../deploy/codebuild/buildspec-ci.yml) | webhook: push to `ci_branches`, PR created/updated/reopened | logs, connection, report group |
| `student-app-image` | [`buildspec-build.yml`](../../../../deploy/codebuild/buildspec-build.yml) | manual (or `enable_image_webhook`) | + ECR push to `student-app` only, privileged |
| `student-app-gha-runner` | — (runs GitHub Actions jobs) | webhook `WORKFLOW_JOB_QUEUED` | logs, connection (+ ECR push if `gha_runner_ecr_push`) |

GitHub access goes through the **CodeConnections** GitHub App from the bootstrap stack
(`auth { type = "CODECONNECTIONS" }`) — no personal access token. Image: `aws/codebuild/standard:8.0`
(Ubuntu 24.04, PHP 8.3 runtime pinned in the buildspec, Docker).

## Use

```bash
cd infra/terraform/stacks/35-codebuild
cp terraform.tfvars.example terraform.tfvars    # codeconnections_arn from the bootstrap stack
terraform init -backend-config=../../backend.hcl
terraform plan -out=tfplan
terraform apply tfplan

aws codebuild start-build --project-name student-app-image --source-version master
```

Prerequisite: the CodeConnections connection is `AVAILABLE` (bootstrap creates it `PENDING`; approve
the GitHub App once in the console) and the app is installed on the repository.

CodeBuild runner in a workflow (needs `enable_gha_runner = true`):

```yaml
runs-on: codebuild-student-app-gha-runner-${{ github.run_id }}-${{ github.run_attempt }}
```

## Destroy

```bash
terraform destroy
```

Removes the projects, roles, log groups and the GitHub webhooks CodeBuild created.

## Cost (us-east-1)

No idle cost. Linux `BUILD_GENERAL1_SMALL` ≈ 0.005 USD/build-minute (CI ≈ 3 min, image ≈ 5–8 min ⇒
≈ 0.05 USD per push); the free tier gives 100 build-minutes/month. Logs: 14-day retention.

## Outputs

`project_names`, `role_arns`, `log_groups`, `start_build_commands`, `gha_runner_label`.
