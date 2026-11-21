# deploy/codedeploy/ec2 — CodeDeploy on EC2 / Auto Scaling (scenario 37)

CodeDeploy with `compute_platform = "Server"` ([`modules/codedeploy`](../../../infra/terraform/modules/codedeploy/)):
the agent on each instance downloads a revision and runs the lifecycle hooks. The revision carries
**only the image reference** — the image itself was built, tested and scanned once by CI.

```
appspec.yml                files -> /opt/student-app/release, hooks below
IMAGE_URI                  <account>.dkr.ecr.<region>.amazonaws.com/student-app:<sha>
deploy.env                 USE_LOCAL_MYSQL, ENV_NAME
docker-compose.prod.yml    repo root
scripts/                   deploy/ec2/deploy-pull-image.sh, deploy/ec2/render-env-from-ssm.sh
hooks/                     application-stop · before-install · after-install · application-start · validate-service
```

| Hook | Does |
|---|---|
| ApplicationStop | (previous revision) keep or gracefully stop the running container |
| BeforeInstall | Docker/Compose/AWS CLI present, clean `/opt/student-app/release` |
| AfterInstall | reject `:latest`, copy the compose file to `/opt/student-app` |
| ApplicationStart | `deploy-pull-image.sh <IMAGE_URI>`: SSM → `app.env`, pull, migrate, recreate, record release |
| ValidateService | `/ready` must return 200 **and** `"version":"<sha>"` |

## Prerequisites on the instances

> **Stack 40 shortcut:** `codedeploy_enabled = true` + `codedeploy_revision_bucket = "<bucket>"` in
> `infra/terraform/stacks/40-ec2-alb-asg/terraform.tfvars` installs the agent + Compose plugin at boot
> (asg-app user data) and grants `s3:GetObject` on the bucket. The `before-install.sh` hook removes the
> boot-time `docker run` container so compose can own port 80. The manual steps below are for other hosts.

- CodeDeploy agent: `sudo dnf install -y ruby wget && wget https://aws-codedeploy-<REGION>.s3.<REGION>.amazonaws.com/latest/install && chmod +x install && sudo ./install auto`
  (or the SSM Distributor package `AWSCodeDeployAgent`).
- Instance profile: everything from scenario 32 (ECR pull, `ssm:GetParametersByPath` on `/student-app/<env>/*`)
  **plus** `s3:GetObject` on the revision bucket.
- Docker + Compose v2 (`deploy/ec2/user-data.sh`).

## Deploy

```bash
IMAGE=<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/student-app:3f2c1ab
DIR=$(deploy/codedeploy/ec2/package-revision.sh "$IMAGE")          # add --local-mysql on a single host
aws deploy push --application-name student-app-lab-ec2 \
  --s3-location "s3://<REVISION_BUCKET>/codedeploy/student-app-${IMAGE##*:}.zip" --source "$DIR"

aws deploy create-deployment --application-name student-app-lab-ec2 \
  --deployment-group-name student-app-lab-ec2 \
  --s3-location "bucket=<REVISION_BUCKET>,key=codedeploy/student-app-${IMAGE##*:}.zip,bundleType=zip" \
  --description "release ${IMAGE##*:}"
aws deploy wait deployment-successful --deployment-id <ID>
```

Run `package-revision.sh` on Linux/macOS/CI (it sets the executable bit the agent needs).

## Notes

- `IN_PLACE` + target group = rolling with traffic control (OneAtATime: one instance out of the ALB at a time).
- `BLUE_GREEN` (`COPY_AUTO_SCALING_GROUP`) creates a new ASG that Terraform does not know — use a
  throw-away ASG, or compare with the ALB-weight blue/green of scenarios 44–46.
- Migrations run in ApplicationStart on each instance; with OneAtATime only the first one migrates.
