# deploy/ecs — ECS Fargate release tooling (scenarios 50–58)

| File | Used by | Purpose |
|---|---|---|
| [`render-taskdef.sh`](render-taskdef.sh) | GitHub Actions, CodeBuild, humans | `live`: copy the newest revision of the family and swap the image · `repo`: render a committed template |
| [`task-definition.json`](task-definition.json) | `deploy-ecs.yml` with `taskdef_source=repo` | task definition as code; `${AWS_ACCOUNT_ID}` `${AWS_REGION}` `${ENV_NAME}` `${IMAGE_URI}` |
| [`taskdef.json`](taskdef.json) | CodePipeline `CodeDeployToECS` (stack 36, `deploy_mode=codedeploy-ecs`) | same, but image = `<IMAGE1_NAME>` (filled from `imageDetail.json`) |
| [`appspec.yaml`](appspec.yaml) | CodeDeploy (GitHub Actions + CodePipeline) | `TargetService`, container `app`, port 8080, optional hooks |
| [`run-migrations.sh`](run-migrations.sh) | all pipelines | `php artisan migrate --force` as a one-off task, fails on non-zero exit |
| [`ecs-exec.sh`](ecs-exec.sh) | humans | shell / command inside a running task (ECS Exec) |

## Who owns what

Terraform (`modules/ecs-fargate`) owns roles, env, secrets, sizing and the service; CI owns the image.
The default (`live`) path keeps a single source of truth: Terraform's newest revision + new image.
The JSON templates are the "task definition in the repo" alternative — keep them in sync with
`stacks/50-ecs-fargate` (`environment` / SSM keys) if you use them. The templates assume the
names of stack 50: family `student-app-<env>-app`, roles `student-app-<env>-ecs-{execution,task}`,
log group `/ecs/student-app-<env>/app`.

## Typical commands

```bash
export AWS_REGION=us-east-1 ECS_CLUSTER=student-app-lab ECS_SERVICE=student-app-lab-app

# migrations of the release currently running (e.g. after restoring a DB snapshot)
deploy/ecs/run-migrations.sh

# migrations with a specific revision, network config taken from the service
deploy/ecs/run-migrations.sh --task-definition student-app-lab-app:42

# render, register, migrate, deploy by hand (what deploy-ecs.yml does)
deploy/ecs/render-taskdef.sh live student-app-lab-app "<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/student-app:3f2c1ab" > /tmp/td.json
TD_ARN=$(aws ecs register-task-definition --cli-input-json file:///tmp/td.json --query taskDefinition.taskDefinitionArn --output text)
deploy/ecs/run-migrations.sh --task-definition "$TD_ARN"
aws ecs update-service --cluster "$ECS_CLUSTER" --service "$ECS_SERVICE" --task-definition "$TD_ARN"
aws ecs wait services-stable --cluster "$ECS_CLUSTER" --services "$ECS_SERVICE"

# debug inside a task (needs session-manager-plugin)
deploy/ecs/ecs-exec.sh -- php artisan about
```

Migrations run on **on-demand FARGATE** even when the service runs on Spot: a reclaimed task in the
middle of `ALTER TABLE` is the outage you do not want. With `CACHE_STORE=database`, avoid
`migrate --isolated` on an empty database (no `cache_locks` table yet, CONVENTIONS §2).
