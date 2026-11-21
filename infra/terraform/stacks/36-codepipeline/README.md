# Stack 36 — CodePipeline for ECS (scenarios 36, 37, 58)

AWS-native CD for the service of [stack 50](../50-ecs-fargate/), built from
[`modules/codepipeline`](../../modules/codepipeline) + [`modules/codebuild`](../../modules/codebuild):

```
Source: CodeConnections (GitHub, push to `branch`, docs-only commits ignored)
  └─ Build: student-app-lab-pipeline-image (buildspec-build.yml)
       → imagedefinitions.json, imageDetail.json, taskdef.json, appspec.yaml
  └─ [Approve: Manual]                                   require_approval = true
  └─ Deploy:
       ecs            Migrate (CodeBuild) → ECS deploy action (rolling / native strategy of the service)
       codedeploy-ecs Migrate (CodeBuild) → CodeDeployToECS (taskdef.json + appspec.yaml, <IMAGE1_NAME>)
       codebuild      CodeBuild buildspec-deploy-ecs.yml: migrate + update-service + wait
```

V2 pipeline, `QUEUED` execution mode (a running deployment is never superseded), artifact bucket
with SSE-KMS (aws/s3), public access block, TLS-only policy, 14-day expiry.

| Scenario | Settings |
|---|---|
| 36 | `deploy_mode = "ecs"`, optionally `require_approval = true` |
| 36b | `deploy_mode = "codebuild"` (CodeBuild as the deployer) |
| 58 | `deploy_mode = "codedeploy-ecs"` + stack 50 `deployment_controller = "CODE_DEPLOY"`; compare with `deploy-ecs.yml` |
| 37 | EC2/ASG CodeDeploy: [`deploy/codedeploy/ec2`](../../../../deploy/codedeploy/ec2/) + `modules/codedeploy` (`compute_platform = "Server"`) |

## Use

```bash
cd infra/terraform/stacks/36-codepipeline
cp terraform.tfvars.example terraform.tfvars                       # codeconnections_arn, deploy_mode
terraform -chdir=../50-ecs-fargate output -json pipeline_inputs > stack50.auto.tfvars.json
terraform init -backend-config=../../backend.hcl
terraform plan -out=tfplan
terraform apply tfplan                 # a V2 pipeline starts one execution right after creation

aws codepipeline start-pipeline-execution --name student-app-lab-pipeline
```

`stack50.auto.tfvars.json` is loaded automatically; its keys are this stack's variable names
(`ecs_cluster_name`, `ecs_service_name`, `task_family`, `task_execution_role_arn`, `task_role_arn`,
`app_log_group_arn`, `codedeploy_app_name`, `codedeploy_deployment_group_name`). Without it the
stack assumes the default stack-50 names. Re-generate it after switching stack 50 to `CODE_DEPLOY`.

Note: the `ECS` deploy action copies the service's *current* task definition (not the newest one
Terraform registered), so Terraform env changes reach it only after a `codebuild`/GitHub Actions deploy.

## Destroy

```bash
terraform destroy
```

The artifact bucket has `force_destroy = true` (ephemeral stack). Destroy this stack before stack 50.

## Cost (us-east-1)

V2 pipelines: 0.002 USD per action-execution-minute (100 free minutes/month), no idle cost.
CodeBuild small: 0.005 USD/min (image ≈ 6 min, migrate ≈ 2 min) ⇒ ≈ 0.05 USD per release. S3: cents.

## Outputs

`pipeline_name`, `pipeline_console_url`, `start_command`, `artifact_bucket`, `codebuild_projects`, `deploy_mode`.
