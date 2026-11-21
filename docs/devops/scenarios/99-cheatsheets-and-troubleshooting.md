# 99 — Cheat sheets و Troubleshooting

> **الهدف في سطر:** صفحة واحدة ترجعلها وانت شغال: أهم أوامر كل أداة في المعمل (docker/compose، aws cli، terraform، ansible، kubectl، helm، argo rollouts، argocd، k6، gh، وسكريبتات المعمل نفسها بالـ env vars بتاعتها)، وجدول troubleshooting (العَرَض ← السبب ← الحل) لأشهر الأعطال اللي هتقابلها في كل سيناريو.
> **المستوى:** كل المستويات · **الوقت:** مرجع · **التكلفة التقريبية:** مجاني
> **بيعتمد على:** [01 — الأدوات](01-tools-primer.md) · [CONVENTIONS](../CONVENTIONS.md) · **الملفات في الـ repo:** [`deploy/ec2/lb/bin/lib.sh`](../../../deploy/ec2/lb/bin/lib.sh) · [`deploy/scripts/`](../../../deploy/scripts) · [`deploy/ecs/`](../../../deploy/ecs) · [`loadtest/k6/README.md`](../../../loadtest/k6/README.md) · [`k8s/README.md`](../../../k8s/README.md) · [`infra/ansible/README.md`](../../../infra/ansible/README.md)

## 1) الفكرة (Concepts)

الأسماء ثابتة في كل الأوامر (CONVENTIONS): env `lab`، region `us-east-1`، prefix `student-app-lab-*`، namespace `student-app`، cluster ECS `student-app-lab` و service `student-app-lab-app`، cluster EKS `student-app-lab`، ALB `student-app-lab-alb`، TGs `student-app-lab-{blue,green}`، RDS `student-app-lab-mysql`، ASGs `student-app-lab-{blue,green}`. لو غيّرت `env` غيّرها في الأوامر.

```bash
export AWS_REGION=us-east-1 ENV_NAME=lab
export ECS_CLUSTER=student-app-lab ECS_SERVICE=student-app-lab-app
export REPO=<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/student-app
```

## 2) Docker و Compose

```bash
# local / CI (docker-compose.yml) — بورت 8080
export APP_KEY=base64:$(openssl rand -base64 32)
docker compose up -d --build --wait
docker compose run --rm app php artisan migrate --force
docker compose run --rm app php artisan db:seed --class=DemoSeeder --force
docker compose exec -T app sh -c 'LOADTEST_USERS=20 LOADTEST_STUDENTS_PER_USER=100 php artisan db:seed --class=LoadTestSeeder --force'
docker compose --profile redis up -d          # scenario 49 · --profile tools = adminer :8090
docker compose logs -f app | head -50
docker compose exec app id                    # uid=82(www-data)
docker compose down                           # -v يمسح الـ volume (الداتا!)

# build / inspect
docker build -f docker/Dockerfile --build-arg APP_VERSION=$(git rev-parse --short HEAD) -t student-app:local .
docker run --rm --entrypoint id student-app:local
docker inspect --format '{{.Config.StopSignal}}' student-app:local      # SIGQUIT
docker buildx build --platform linux/amd64,linux/arm64 -f docker/Dockerfile -t "$REPO:<SHA7>" --push .
docker system df && docker image prune -f

# EC2 Recreate stack (docker-compose.prod.yml) — بورت 80
APP_IMAGE="$REPO:<SHA7>" docker compose -f docker-compose.prod.yml pull app
APP_IMAGE="$REPO:<SHA7>" docker compose -f docker-compose.prod.yml up -d --wait
docker compose -f docker-compose.prod.yml up -d --no-deps app          # مع RDS (من غير mysql)

# الـ lb stack (deploy/ec2/lb) — من جوه deploy/ec2/lb
docker compose -f docker-compose.yml --env-file state/release.env ps
docker compose -f docker-compose.yml --env-file state/release.env exec -T proxy nginx -t
docker compose -f docker-compose.yml --env-file state/release.env logs --tail=50 app_green
```

## 3) AWS CLI

```bash
aws sts get-caller-identity
aws sso login --profile lab

# --- SSM: Parameter Store
aws ssm get-parameters-by-path --path /student-app/lab/app --with-decryption --query 'Parameters[].[Name,Value]' --output table
aws ssm put-parameter --name /student-app/lab/app/APP_KEY --type SecureString --value "base64:$(openssl rand -base64 32)" --overwrite
aws ssm get-parameter-history --name /student-app/lab/deploy/blue/IMAGE_URI --query 'Parameters[-5:].[Version,Value,LastModifiedDate]' --output table
aws ssm delete-parameter --name /student-app/lab/app/SRE_FAULT_BOOT_FAIL
# --- SSM: Session Manager / Run Command
aws ssm start-session --target <INSTANCE_ID>
aws ssm start-session --target <INSTANCE_ID> --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["3000"],"localPortNumber":["3000"]}'
CMD=$(aws ssm send-command --document-name AWS-RunShellScript --targets Key=tag:Scenario,Values=20 \
  --parameters 'commands=["docker ps","curl -s localhost/ready"]' --query Command.CommandId --output text)
aws ssm list-commands --command-id "$CMD" --query 'Commands[0].Status'
aws ssm get-command-invocation --command-id "$CMD" --instance-id <INSTANCE_ID> --query '[Status,StandardOutputContent,StandardErrorContent]'
aws ssm cancel-command --command-id "$CMD"

# --- ECR
aws ecr get-login-password | docker login --username AWS --password-stdin <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com
aws ecr describe-images --repository-name student-app --image-ids imageTag=<SHA7> --query 'imageDetails[0].[imageDigest,imagePushedAt]'
aws ecr describe-image-scan-findings --repository-name student-app --image-id imageTag=<SHA7> --query 'imageScanFindings.findingSeverityCounts'

# --- ECS
aws ecs describe-services --cluster $ECS_CLUSTER --services $ECS_SERVICE \
  --query 'services[0].deployments[].[status,rolloutState,taskDefinition,runningCount,desiredCount]' --output table
aws ecs describe-services --cluster $ECS_CLUSTER --services $ECS_SERVICE --query 'services[0].events[:10].[createdAt,message]' --output table
aws ecs list-tasks --cluster $ECS_CLUSTER --service-name $ECS_SERVICE --desired-status STOPPED
aws ecs describe-tasks --cluster $ECS_CLUSTER --tasks <TASK_ARN> --query 'tasks[0].[lastStatus,stopCode,stoppedReason,containers[0].reason]'
aws ecs update-service --cluster $ECS_CLUSTER --service $ECS_SERVICE --task-definition <FAMILY:REV>
aws ecs wait services-stable --cluster $ECS_CLUSTER --services $ECS_SERVICE
aws ecs update-service --cluster $ECS_CLUSTER --service $ECS_SERVICE --force-new-deployment

# --- ELBv2
aws elbv2 describe-target-health --target-group-arn <TG_ARN> \
  --query 'TargetHealthDescriptions[].[Target.Id,Target.Port,TargetHealth.State,TargetHealth.Reason]' --output table
aws elbv2 describe-listeners --load-balancer-arn <ALB_ARN> --query 'Listeners[].DefaultActions[].ForwardConfig.TargetGroups'
aws elbv2 modify-listener --listener-arn "$ALB_LISTENER_ARN" --default-actions \
  '[{"Type":"forward","ForwardConfig":{"TargetGroups":[{"TargetGroupArn":"'"$TG_BLUE_ARN"'","Weight":90},{"TargetGroupArn":"'"$TG_GREEN_ARN"'","Weight":10}]}}]'

# --- Auto Scaling
aws autoscaling start-instance-refresh --auto-scaling-group-name student-app-lab-blue --strategy Rolling \
  --preferences '{"MinHealthyPercentage":100,"MaxHealthyPercentage":150,"InstanceWarmup":120,"SkipMatching":false,"AutoRollback":false}'
aws autoscaling describe-instance-refreshes --auto-scaling-group-name student-app-lab-blue \
  --query 'InstanceRefreshes[0].[Status,PercentageComplete,StatusReason]'
aws autoscaling cancel-instance-refresh --auto-scaling-group-name student-app-lab-blue
aws autoscaling resume-processes --auto-scaling-group-name student-app-lab-blue        # بعد rolling-asg.yml فاشل
aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names student-app-lab-blue \
  --query 'AutoScalingGroups[0].[DesiredCapacity,Instances[].[InstanceId,LifecycleState,HealthStatus]]'

# --- Logs و Alarms
aws logs tail /ecs/student-app-lab/app --follow --since 10m        # EC2: /student-app/lab/app
Q=$(aws logs start-query --log-group-name /ecs/student-app-lab/app --start-time $(date -d '-1 hour' +%s) --end-time $(date +%s) \
  --query-string 'fields @timestamp, level_name, message | filter level_name = "ERROR" | sort @timestamp desc | limit 20' --query queryId --output text)
aws logs get-query-results --query-id "$Q"
aws cloudwatch describe-alarms --state-value ALARM --query 'MetricAlarms[].AlarmName'
aws cloudwatch set-alarm-state --alarm-name student-app-lab-alb-5xx-ratio --state-value ALARM --state-reason "drill"   # اختبر الـ rollback

# --- CodeBuild / CodePipeline / CodeDeploy / CodeConnections
aws codebuild start-build --project-name student-app-image --source-version master
aws codepipeline start-pipeline-execution --name student-app-lab-pipeline
aws codepipeline get-pipeline-state --name student-app-lab-pipeline --query 'stageStates[].[stageName,latestExecution.status]' --output table
aws deploy get-deployment --deployment-id <ID> --query 'deploymentInfo.[status,errorInformation]'
aws codeconnections list-connections --query 'Connections[].[ConnectionName,ConnectionStatus]' --output table

# --- EKS
aws eks update-kubeconfig --name student-app-lab --region us-east-1
```

## 4) Terraform

```bash
cp infra/terraform/backend.hcl.example infra/terraform/backend.hcl
cd infra/terraform/stacks/<NN-name>
terraform init -backend-config=../../backend.hcl
terraform fmt -recursive && terraform validate
terraform plan -out=tfplan && terraform apply tfplan
terraform output                                   # -raw <name> · -json github_repository_variables
terraform state list && terraform state show '<ADDRESS>'
terraform plan -refresh-only                       # drift
terraform plan -detailed-exitcode; echo "exit=$?"  # 0 نضيف · 1 error · 2 فيه تغيير
terraform plan -generate-config-out=generated.tf   # مع import blocks (91)
terraform apply -replace=module.ecs.aws_ecs_service.app     # ROLLING ⇄ B/G، ECS ⇄ CODE_DEPLOY (50)
terraform force-unlock <LOCK_ID>                   # آخر حل
terraform destroy
terraform -chdir=infra/terraform/stacks/50-ecs-fargate output -json pipeline_inputs > infra/terraform/stacks/36-codepipeline/stack50.auto.tfvars.json
tflint --recursive --chdir=infra/terraform --config "$PWD/infra/terraform/.tflint.hcl"

# من GitHub (plan على PR تلقائياً)
gh workflow run terraform.yml --ref master -f stack=40-ec2-alb-asg -f action=plan     # apply | destroy
```

## 5) Ansible (من WSL، جوه `infra/ansible`)

```bash
source ~/.venvs/ansible/bin/activate && cd infra/ansible
ansible-galaxy collection install -r requirements.yml
SSM_BUCKET=$(terraform -chdir=../terraform/bootstrap output -raw ansible_ssm_bucket)
ansible-inventory --graph
ansible role_app -m ansible.builtin.ping -e ssm_bucket_name=$SSM_BUCKET
ansible-playbook playbooks/provision.yml -e ssm_bucket_name=$SSM_BUCKET
ansible-playbook playbooks/deploy.yml -e ssm_bucket_name=$SSM_BUCKET -e app_image=$REPO:<SHA7> --check --diff
ansible-playbook playbooks/bluegreen.yml -e ssm_bucket_name=$SSM_BUCKET -e app_image=$REPO:<SHA7>
ansible-playbook playbooks/canary.yml -e ssm_bucket_name=$SSM_BUCKET -e app_image=$REPO:<SHA7> -e nginx_lb_canary_step_seconds=60
ansible-playbook playbooks/rollback.yml -e ssm_bucket_name=$SSM_BUCKET
TG=$(terraform -chdir=../terraform/stacks/40-ec2-alb-asg output -json target_group_arns)
ansible-playbook playbooks/rolling-asg.yml -e ssm_bucket_name=$SSM_BUCKET -e app_image=$REPO:<SHA7> -e "{\"rolling_target_group_arns\": $TG}"
ansible-lint --profile=production
```

## 6) kubectl

```bash
kubectl config current-context
kubectl -n student-app get pods,svc,ingress,hpa,pdb -o wide
kubectl -n student-app get rollout,analysisrun,externalsecret,job
kubectl -n student-app describe pod <POD>
kubectl -n student-app logs -l app.kubernetes.io/name=student-app --all-containers --prefix --tail=80
kubectl -n student-app logs job/student-app-migrate
kubectl -n student-app get events --sort-by=.lastTimestamp | tail -30
kubectl -n student-app rollout status deployment/student-app --timeout 120s
kubectl -n student-app rollout undo deployment/student-app
kubectl -n student-app rollout restart deployment/student-app          # بعد rotation في الـ Secret
kubectl -n student-app exec -it deploy/student-app -- php artisan about
kubectl -n student-app port-forward svc/student-app 8080:80
kubectl -n student-app top pods
kubectl auth can-i create deployments.apps -n student-app
kubectl get clustersecretstore -o wide
kubectl -n student-app annotate externalsecret student-app-secrets force-sync="$(date +%s)" --overwrite
kubectl -n student-app wait --for=condition=complete job/student-app-migrate --timeout=300s
kubectl apply -k k8s/manifests/overlays/kind
kind create cluster --config k8s/kind/cluster.yaml && kind load docker-image student-app:ci-v1 --name student-app-lab
```

## 7) Helm (v4)

```bash
helm lint k8s/helm/student-app
helm template lab k8s/helm/student-app -f k8s/helm/student-app/values-eks.yaml | less
helm upgrade --install student-app k8s/helm/student-app -n student-app \
  -f k8s/helm/student-app/values-kind.yaml --set-string image.tag=ci-v1 --wait
helm upgrade --install student-app k8s/helm/student-app -n student-app -f k8s/helm/student-app/values-eks.yaml \
  --set-string image.repository=$REPO --set-string image.tag=<SHA7> --set rollout.enabled=false \
  --wait --rollback-on-failure --timeout 10m                   # = deploy-eks.yml mode=helm
helm -n student-app history student-app --max 5
helm -n student-app rollback student-app [REVISION]
helm -n student-app get values student-app
helm -n student-app uninstall student-app
```

## 8) Argo Rollouts و Argo CD

```bash
# Argo Rollouts (plugin kubectl-argo-rollouts)
kubectl argo rollouts get rollout student-app -n student-app --watch
kubectl argo rollouts status student-app -n student-app --timeout 15m
kubectl argo rollouts promote student-app -n student-app          # الخطوة الجاية · --full = يتخطى كل حاجة (طوارئ)
kubectl argo rollouts abort student-app -n student-app            # 100% stable دلوقتي
kubectl argo rollouts retry rollout student-app -n student-app    # بعد abort
kubectl argo rollouts undo student-app -n student-app             # بعد promote (بالـ steps تاني)
kubectl argo rollouts dashboard                                   # localhost:3100
kubectl -n student-app describe analysisrun <NAME>

# Argo CD
kubectl -n argocd get applications
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
kubectl -n argocd port-forward svc/argo-cd-argocd-server 8080:80
argocd login localhost:8080 --username admin --password "<PASSWORD>" --insecure
argocd app get student-app --refresh
argocd app diff student-app                                       # فاضي = الـ cluster == git
argocd app history student-app
argocd app sync student-app
# الـ rollback في GitOps = git revert للـ bump commit (argocd app rollback مرفوض طول ما الـ auto-sync شغال)
```

## 9) k6

```bash
k6 run -e BASE_URL=http://localhost:8080 -e LOADTEST_USERS=5 loadtest/k6/smoke.js
k6 run -e BASE_URL=http://<ALB> -e LOADTEST_USERS=20 -e VUS=10 -e DURATION=5m -e P95_MS=300 loadtest/k6/load.js
k6 run -e BASE_URL=http://<ALB> -e LAB_TOKEN=<TOKEN> -e RATE=10 -e CPU_MS=200 -e DURATION=10m loadtest/k6/autoscale-cpu.js
k6 run -e BASE_URL=http://<ALB> -e EXPECT_VERSIONS=v1,v2 -e CANARY_VERSION=<SHA7> -e EXPECT_CANARY_PCT=10 -e TOLERANCE_PCT=4 loadtest/k6/canary-watch.js
k6 run -e BASE_URL=http://localhost:8080 -e BURN_RATE=20 -e DURATION=20m loadtest/k6/error-budget-burn.js   # MODE=lab (drill) | app
k6 run --summary-export loadtest/results/summary.json loadtest/k6/load.js
K6_WEB_DASHBOARD=true K6_WEB_DASHBOARD_EXPORT=loadtest/results/report.html k6 run loadtest/k6/load.js
docker run --rm -i --network student-app_default -v "$PWD/loadtest:/loadtest" grafana/k6:2.4.0 run -e BASE_URL=http://app:8080 /loadtest/k6/smoke.js
# exit 99 = threshold اتكسر (= الـ SLO)
```

## 10) gh (GitHub CLI)

```bash
gh workflow run lab-integration.yml --ref devops-lab && gh run watch
gh run list --workflow deploy-ecs.yml -L 5
gh run view <RUN_ID> --log-failed
gh workflow run deploy-ecs.yml --ref master -f image_tag=<SHA7> -f strategy=rolling -f taskdef_source=live
gh workflow run deploy-ecs.yml --ref master -f image_tag=<SHA7> -f run_migrations=false -f extra_env=SRE_FAULT_BOOT_FAIL=true
gh workflow run deploy-asg.yml --ref master -f strategy=canary-weights -f image_tag=<SHA7>
gh workflow run deploy-eks.yml --ref master -f image_tag=<SHA7> -f mode=rollouts
gh workflow run deploy-ec2-bluegreen.yml --ref master -f image_tag=<SHA7>
gh workflow run release-promote.yml --ref master -f image_tag=<SHA7>
gh variable set ECS_IMAGE_TAG --body <SHA7> && gh variable list
```

## 11) سكريبتات المعمل والـ env vars بتاعتها

| السكريبت | الاستخدام | الـ env (الافتراضي) |
|---|---|---|
| كل `deploy/ec2/lb/bin/*.sh` (من `lib.sh`) | — | `APP_ENV_FILE` (`/opt/student-app/app.env`)، `MYSQL_ENV_FILE` (`/opt/student-app/mysql.env`)، `USE_LOCAL_MYSQL` (`true`)، `LB_HTTP_PORT` (`80`)، `READY_TIMEOUT` (`120`)، `SKIP_PULL`، `SKIP_MIGRATE`، `SLOT_ENV` (للـ slot الجديد بس، مفصولة بمسافات) |
| `init.sh <image>` | أول تشغيل: blue live، `MODE=single` | ↑ |
| `bluegreen.sh <image>` | deploy على الـ idle ثم switch | `KEEP_OLD` (`true`)، `DRAIN_SECONDS` (`10`) |
| `canary.sh <image>` | weights + metric gate، abort = exit **2** | `STEPS` (`10 25 50 100`)، `STEP_SECONDS` (`30`)، `MAX_ERROR_RATE` (`0.01`)، `MIN_REQUESTS` (`10`)، `METRICS_TOKEN` (وإلا من `APP_ENV_FILE`) |
| `rolling.sh <image>` | slot بعد slot في الـ pool | `DRAIN_SECONDS` (`3`) |
| `ab-test.sh <image> [percent] \| stop` | A/B sticky (افتراضي 20%) | — |
| `shadow.sh <image> \| stop` | mirror لـ GET/HEAD | — |
| `rollback.sh` | mode-aware (single / canary·ab·shadow / rolling) | — |
| `status.sh` | state + containers + upstream + `/ready` | — |
| `deploy/scripts/probe.sh <url> [sec=60] [interval=0.2]` | يقيس الـ downtime (0 sec = لحد `STOP_FILE`) | `TIMEOUT` (`2`)، `OUT`، `STOP_FILE`، `MAX_FAILURES` |
| `deploy/scripts/with-probe.sh -- <cmd>` | يشغّل deploy والـ probe شغال | `PROBE_URL` (`http://localhost/ready`)، `PROBE_INTERVAL` (`0.05`)، `MAX_FAILURES` (`0`)، `EXPECT_EXIT` (`0`) |
| `deploy/scripts/version-split.sh <url> [count=100] [header]` | توزيع الـ traffic على الإصدارات | — |
| `deploy/scripts/probe.ps1 -Url -Seconds -IntervalMs` | نسخة Windows | — |
| `deploy/ec2/render-env-from-ssm.sh` | SSM → `app.env` / `mysql.env` (chmod 600) | `ENV_NAME` (`lab`)، `APP_DIR` (`/opt/student-app`)، `AWS_REGION` (من IMDS) |
| `deploy/ec2/deploy-pull-image.sh <uri> \| rollback` | Recreate بـ image من ECR | `APP_DIR`، `USE_LOCAL_MYSQL` (`true`)، `RENDER_ENV` (`true`) |
| `deploy/ec2/deploy-build-on-server.sh [ref=master]` | build على السيرفر (الطريقة القديمة) | `APP_DIR`، `SRC_DIR` (`$APP_DIR/src`)، `USE_LOCAL_MYSQL` |
| `deploy/ec2/backup-mysql-to-s3.sh [restore s3://…]` | mysqldump → S3 | `BACKUP_BUCKET` |
| `deploy/ecs/render-taskdef.sh live <family> <image> \| repo <file>` | task definition للـ register (بيشيل `SRE_FAULT_*`) | `KEEP_FAULT_ENV`، (repo) `AWS_ACCOUNT_ID` `AWS_REGION` `ENV_NAME` `IMAGE_URI` |
| `deploy/ecs/run-migrations.sh [--task-definition X]` | migrate كـ one-off task | `ECS_CLUSTER`، `ECS_SERVICE`، `TASK_DEFINITION`، `NETWORK_CONFIGURATION`، `CAPACITY_PROVIDER` |
| `deploy/ecs/ecs-exec.sh [--task ID] -- <cmd>` | ECS Exec | `ECS_CLUSTER`، `ECS_SERVICE`، `CONTAINER_NAME` |
| `deploy/codedeploy/ec2/package-revision.sh <image> [--local-mysql]` | revision لـ CodeDeploy (Linux/CI) | — |

أمثلة سريعة:

```bash
cd /opt/student-app/src/deploy/ec2/lb
SKIP_PULL=true bash ../../scripts/with-probe.sh -- bash bin/bluegreen.sh student-app:v2
STEPS="10 50 100" STEP_SECONDS=60 bash bin/canary.sh "$REPO:<SHA7>"
SLOT_ENV="SRE_FAULT_ERROR_RATE=0.5" EXPECT_EXIT=2 bash ../../scripts/with-probe.sh -- bash bin/canary.sh "$REPO:<SHA7>"
bash bin/ab-test.sh "$REPO:<SHA7>" 20 && curl -s -H 'X-Variant: green' localhost/ready
bash bin/rollback.sh && bash bin/status.sh
bash ../../scripts/version-split.sh http://localhost/ready 100
```

## 12) Troubleshooting (العَرَض ← السبب ← الحل)

### 12.1 التطبيق (Laravel / container)

| العَرَض | السبب | الحل | # |
|---|---|---|---|
| **419 Page Expired** على الفورمز ورا ALB/proxy | (1) sessions مش مشتركة بين الـ replicas (`SESSION_DRIVER=file`)، (2) `APP_KEY` مختلف بين الـ replicas/الألوان، (3) cookie `Secure` على HTTP أو العكس | `SESSION_DRIVER=database` (أو `redis` في 49)، `APP_KEY` واحد من SSM لكل الـ replicas، `SESSION_SECURE_COOKIE=true` بس مع HTTPS | [74](74-load-testing-k6.md)، [81](81-secrets-management.md) |
| **Mixed content** / روابط و forms بـ `http://` / redirect loop ورا ALB بـ HTTPS | Laravel مش شايف إن الـ client كان HTTPS | `trustProxies(at: '*', headers: HEADER_X_FORWARDED_PROTO)` موجود في [`bootstrap/app.php`](../../../bootstrap/app.php) — اتأكد إن الـ proxy بيبعت `X-Forwarded-Proto` (nginx الـ lb بيحافظ عليه) و `APP_URL` = `https://…` | [83](83-edge-security-waf-https.md) |
| `APP_KEY is required - generate one with …` من `docker compose` | الـ compose المحلي بيرفض يقوم من غير `APP_KEY` (`${APP_KEY:?…}`) | `export APP_KEY=base64:$(openssl rand -base64 32)` | [10](10-containerize-app.md) |
| `MissingAppKeyException` (No application encryption key) على AWS | `/student-app/lab/app/APP_KEY` مش موجود أو الـ env file متعملهوش render | اعمل الـ parameter (SecureString، `base64:` + 32 byte) ثم `render-env-from-ssm.sh` + redeploy (ECS: deployment جديد، EKS: force-sync + restart) | [20](20-ec2-compose-console.md)، [81](81-secrets-management.md) |
| `Permission denied` على `storage/` أو `bootstrap/cache` | volume أو bind mount مملوك لـ root والـ process هو `www-data` (UID **82**) | متعملش mount فوق `/var/www/html/storage` في production؛ لو لازم: `chown -R 82:82 <dir>`، وعلى K8s `fsGroup: 82` (موجود في الـ chart) | [10](10-containerize-app.md) |
| `/ready` = **503** | الـ JSON فيه `reason`: `database unreachable` (DB_HOST/SG/credentials/RDS لسه بيقوم)، `fault injection: SRE_FAULT_UNHEALTHY`، `manually drained (unready flag present)` | `curl -s <host>/ready \| jq`؛ صلّح الـ DB أو شيل الـ fault، أو `curl -X POST -H "X-Lab-Token: $T" <host>/sre-lab/ready` | [12](12-sre-lab-endpoints-and-local-observability.md) |
| `/ready` = 200 بس `/login` = 500 | `/ready` بيعمل `select 1` بس ومبيتأكدش من الـ schema؛ جدول `sessions` مش موجود = الـ migrations متعملتش | شغّل الـ migration (compose `run --rm` / `run-migrations.sh` / الـ Helm hook) | [52](52-ecs-migrations-and-exec.md)، [60](60-kubernetes-on-kind.md) |
| `/sre-lab/*` = 404 / 403 | 404 = `SRE_LAB_ENABLED` مش `true`؛ 403 = `SRE_LAB_TOKEN` متحدد ومفيش `X-Lab-Token` | فعّل في SSM (للـ drills بس) أو ابعت الـ header (k6: `-e LAB_TOKEN=…`) | [12](12-sre-lab-endpoints-and-local-observability.md) |
| `/metrics` = 404 / 403 | 404 = `METRICS_ENABLED` مش `true` (أو عبر الـ LB: مقفول عمداً)؛ 403 = `METRICS_TOKEN` من غير Bearer | اعمل scrape للـ container مباشرة؛ ابعت `Authorization: Bearer <token>` | [12](12-sre-lab-endpoints-and-local-observability.md) |
| الـ container بيقف فوراً: `SRE_FAULT_BOOT_FAIL=true -> refusing to start` | الـ fault متحقن (env / SSM / `SLOT_ENV`) | شيله من المصدر: `aws ssm delete-parameter …/SRE_FAULT_BOOT_FAIL`؛ رجوع الـ image لوحده مش هيصلّح لو الـ fault في config مشتركة | [44 §8.2](44-rolling-instance-refresh.md) |
| `bash: ./x.sh: Permission denied` | الـ exec bit ضاع (commit من Windows) | `bash x.sh` أو `git update-index --chmod=+x x.sh` | [03](03-workstation-setup.md) |

### 12.2 Single host (nginx / lb scripts)

| العَرَض | السبب | الحل | # |
|---|---|---|---|
| `nginx -t` بيفشل على `resolve` (invalid parameter / requires shared memory / no resolver) | nginx open source أقدم من 1.27.3، أو الـ upstream من غير `zone`، أو مفيش `resolver` | استخدم الـ image المتثبتة في [`lb/docker-compose.yml`](../../../deploy/ec2/lb/docker-compose.yml) (`nginx:1.28-alpine`)؛ متعدّلش `write_upstreams` يدوي | [23](23-bluegreen-single-host.md) |
| `nginx config test failed — traffic NOT switched` | ملف في `state/nginx/` بايظ | رجّع الملف / `bash bin/init.sh` من جديد؛ السكريبت عمل die قبل الـ reload فالـ traffic مكانه | [23](23-bluegreen-single-host.md) |
| `No state yet — run bin/init.sh <image> first.` | مفيش `state/release.env` | `SKIP_PULL=true bash bin/init.sh <image>` | [23](23-bluegreen-single-host.md) |
| `mode=… but live color … is not ready — inspect with bin/status.sh` | الـ `MODE` مش `single` والـ live واقع | `bash bin/status.sh`، شغّل الـ live (`compose start app_<color>`) ثم كمّل | [23](23-bluegreen-single-host.md) |
| `canary.sh` خرج بـ **exit 2** | (1) `canary failed its pre-traffic checks (migrate / ready / smoke)`، (2) `no traffic reached the canary` (أقل من `MIN_REQUESTS` مرتين — ومعاها `/metrics` مش reachable: `METRICS_ENABLED` مقفول أو token غلط → `0 0`)، (3) `error rate X > MAX_ERROR_RATE at N%` | (1) logs الـ slot، (2) ولّد traffic على صفحات حقيقية (`probe.sh http://localhost/login 0 0.05`)، `curl 127.0.0.1:8082/metrics`، (3) ده الـ gate شغال صح — صلّح الـ release | [24](24-canary-single-host.md) |
| `rollback.sh`: `app_X holds the release that just failed its checks … nothing to roll back to; Y is still live` | الـ **`BROKEN`** marker: آخر deploy فشل والـ traffic أصلاً عمره ما اتحرك | ده الصح — مفيش حاجة ترجعلها. اعمل deploy لإصدار سليم (الـ marker بيتمسح لما نفس اللون ينجح) | [23 §9](23-bluegreen-single-host.md) |
| B/G عدّى release بيرجّع 500 على جزء من الصفحات | الـ smoke request واحد على `/login`؛ B/G مفيهوش metric gate | استخدم `canary.sh`، أو burn-rate alert + `rollback.sh` | [23 §8](23-bluegreen-single-host.md)، [24](24-canary-single-host.md) |
| `network student-app_default declared as external, but could not be found` | ستاك الـ observability قبل الـ app | شغّل الـ app stack الأول | [12](12-sre-lab-endpoints-and-local-observability.md) |

### 12.3 AWS (ALB / ASG / ECS / SSM)

| العَرَض | السبب | الحل | # |
|---|---|---|---|
| Targets **unhealthy** في الـ TG والتطبيق شغال | **البورت**: stack 40 الـ TG على **80** (host port، `docker run -p 80:8080`)، stack 50 و EKS على **8080** (`target_type = ip`)؛ أو `/ready` = 503؛ أو الـ SG مش سامح من الـ ALB SG | `aws elbv2 describe-target-health` (الـ `Reason`)؛ `curl` على البورت الصح من جوه الـ VPC؛ راجع `target_port` في الـ stack | [42](42-alb-asg-launch-template.md)، [51](51-ecs-fargate-terraform.md) |
| ECS: `rolloutState = FAILED` والـ service رجع لوحده | **circuit breaker** (≥ 3 tasks فشلت تقوم أو الـ health checks) | `describe-tasks` → `stoppedReason`؛ لو `SRE_FAULT_BOOT_FAIL`: ده الـ drill. أول deployment مالوش rollback | [53](53-ecs-rolling-circuit-breaker.md) |
| `CannotPullContainerError` | الـ tag مش في ECR، أو الـ task مش واصل لـ ECR (public IP off من غير NAT)، أو ARM64 والـ image مش multi-arch، أو الـ execution role ناقصها ECR | `aws ecr describe-images … imageTag=<TAG>`؛ public IP / NAT؛ `buildx --platform linux/amd64,linux/arm64` | [50](50-ecs-fargate-console.md)، [56](56-ecs-capacity-providers-spot.md) |
| `ResourceInitializationError: unable to pull secrets or registry auth` | ARN غلط في `secrets[].valueFrom`، الـ execution role ناقصها `ssm:GetParameters`/`kms:Decrypt`، أو مفيش طريق للـ SSM | `aws ssm get-parameters --names <NAME> --with-decryption`؛ صلّح الـ role/الشبكة | [52](52-ecs-migrations-and-exec.md)، [81](81-secrets-management.md) |
| `ImageTagAlreadyExistsException` | ECR `IMMUTABLE` وحد بيعمل push لنفس الـ SHA (re-run، أو `ci.yml` والـ pipeline في نفس الوقت) | الـ CI بيعمل `describe-images` الأول ويتخطى — اتأكد إن الـ role عنده `ecr:DescribeImages`؛ trigger واحد بيبني | [30](30-ci-github-actions.md)، [58](58-ecs-github-actions-vs-codepipeline.md) |
| `deploy-ecs.yml`: `service strategy is ROLLING; set deployment_strategy = BLUE_GREEN \| LINEAR \| CANARY in stack 50` | `strategy=native` على service rolling (أو `codedeploy` على ECS controller) | غيّر الـ stack + `terraform apply -replace=module.ecs.aws_ecs_service.app` | [55](55-ecs-native-bluegreen-linear-canary.md) |
| Instance refresh فشل / الـ instances الجديدة unhealthy loop | الـ `IMAGE_URI` بيشاور على tag مش موجود (user data بيعمل retry للـ pull 10 مرات ويخرج)، أو fault في `/student-app/lab/app/*`، أو alarm في ALARM قبل البدء | `/var/log/cloud-init-output.log` (Session Manager)؛ رجّع الـ pointer بـ `get-parameter-history`؛ شيل الـ fault من SSM | [44](44-rolling-instance-refresh.md) |
| الـ weights رجعت بعد `terraform apply` | الـ CI غيّرها بـ `modify-listener` و Terraform لسه مالكها | انسخها في tfvars أو `listener_weights_managed_externally = true` | [46](46-canary-weighted-target-groups.md)، [91](91-terraform-import-and-drift.md) |
| ASG processes **suspended** بعد `rolling-asg.yml` | الـ playbook فشل وساب الـ fleet متجمد عمداً | حقق، وبعدين `aws autoscaling resume-processes --auto-scaling-group-name student-app-lab-blue` | [47](47-ansible-rolling-deploy.md) |
| SSM command **timeout** / `TimedOut` / فاضل Pending | `TimeoutSeconds` (600) = الـ agent ماستلمش (offline، instance stopped، مفيش outbound 443، instance profile ناقص `AmazonSSMManagedInstanceCore`)؛ `executionTimeout` = السكريبت طوّل (canary: `900 + steps × step_seconds × 2`) | `aws ssm describe-instance-information`؛ `systemctl status amazon-ssm-agent`؛ الـ workflow بيعمل `cancel-command` بعد `executionTimeout + 600` | [32](32-cd-ec2-ecr-ssm.md) |
| `::error::set the ANSIBLE_SSM_BUCKET variable (bootstrap output ansible_ssm_bucket)` | الـ variable مش متحدد، أو الـ controller مالوش S3 على الـ bucket، أو `session-manager-plugin` مش متثبت | `gh variable set ANSIBLE_SSM_BUCKET --body "$(terraform -chdir=infra/terraform/bootstrap output -raw ansible_ssm_bucket)"`؛ الـ instance نفسه مش محتاج S3 | [33](33-cd-ec2-ansible.md) |
| Ansible بيتجاهل `ansible.cfg` | الـ repo على `/mnt/c/...` (world-writable) | clone جوه WSL filesystem (`~/src`) | [93](93-ansible-deep-dive.md) |
| CloudWatch `slo-fast-burn` ضرب وقت drill | الـ ALB metrics مالهاش path dimension فـ `/sre-lab/error` بيتحسب | متوقع (CONVENTIONS §5): mute للـ SNS وقت الـ drill أو اعمله على Prometheus | [73](73-slo-error-budget-burn-rate.md) |

### 12.4 Kubernetes / EKS

| العَرَض | السبب | الحل | # |
|---|---|---|---|
| **ESO مش بيعمل sync** (`SecretSyncedError`، الـ Secret فاضي/قديم) | Pod Identity association ناقص (`AccessDenied`)، `ssmPath` غلط أو برّه الـ policy (`/app` بس)، الـ store `conditions` مش سامحة للـ namespace، region غلط | `kubectl -n student-app describe externalsecret student-app-secrets`؛ `kubectl get clustersecretstore -o wide`؛ force-sync؛ بعد الـ sync `rollout restart` | [64](64-eks-external-secrets.md) |
| Rollout **Degraded** | (1) الـ analysis لقى 5xx ratio > `maxErrorRate` (الـ gate شغال)، (2) مفيش series (الـ PodMonitor مش متركّب، أو `METRICS_TOKEN` → 403) = abort لكل release، (3) الـ canary مش Ready → `progressDeadlineAbort` | `kubectl -n student-app get analysisrun` + `describe`؛ صلّح السبب ثم `kubectl argo rollouts retry rollout student-app -n student-app` أو `helm rollback` | [68](68-k8s-canary-argo-rollouts.md) |
| Canary سيء اتعمله **promote** | مفيش traffic على الـ canary → `isNaN(result[0])` بيعدّي | traffic حقيقي أثناء الـ canary (k6 / probe على `/login`)، أو حد أدنى requests في الـ AnalysisTemplate | [68](68-k8s-canary-argo-rollouts.md) |
| PodMonitor target DOWN / 403 | `METRICS_TOKEN` اتحط في SSM وظهر في الـ Secret، والـ PodMonitor مبيبعتش Bearer | امسح الـ token، أو استخدم الـ ServiceMonitor بـ `serviceMonitor.bearerTokenSecretKey` (والـ PodMonitor يتشال — الاتنين = double counting) | [64](64-eks-external-secrets.md)، [68](68-k8s-canary-argo-rollouts.md) |
| `CrashLoopBackOff` | `SRE_FAULT_BOOT_FAIL` / `extraEnv`، أو secret ناقص | `kubectl logs --previous`، `describe pod`؛ `helm rollback` | [66](66-k8s-rolling-recreate.md) |
| `helm upgrade --rollback-on-failure` رجع لوحده | الـ pods مبقتش Ready خلال `--timeout`، أو الـ migrate hook Job فشل | `kubectl -n student-app logs job/student-app-migrate`، events؛ الـ release القديم شغال أصلاً | [65](65-helm-chart.md) |
| `kubectl` بيعمل timeout على EKS | الـ IP بتاعك اتغيّر و `cluster_endpoint_public_access_cidrs` مقفول | حدّث الـ CIDR (tfvars أو `aws eks update-cluster-config … publicAccessCidrs=<IP>/32`) | [61](61-eks-console-eksctl.md) |
| `terraform destroy` لـ 60 واقف على الـ VPC/SGs | Ingress / LoadBalancer Service عملوا ALB و SGs برّه Terraform | `kubectl delete ingress --all -A` قبل الـ destroy؛ لو فات: امسح الـ ALB والـ SGs بإيدك | [62](62-eks-terraform.md)، [97](97-cost-and-teardown.md) |
| migrate Job immutable / بيفشل في الـ apply التاني (plain manifests) | الـ Job بيتعمل مع الـ Deployment ومبيتعدّلش | `kubectl wait … job/student-app-migrate` ثم امسحه قبل الـ release الجاي (أو استخدم الـ chart بالـ hook) | [60](60-kubernetes-on-kind.md) |

### 12.5 CI/CD و IaC

| العَرَض | السبب | الحل | # |
|---|---|---|---|
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | الـ `sub` مش في الـ trust policy: branch مش في القايمة، أو الـ job فيه `environment:` (الـ `sub` = `environment:<name>` مش branch)، أو `pull_request`، أو الـ role var غلط (plan role ↔ admin role)، أو ناقص `permissions: id-token: write` | قارن الـ `sub` (CloudTrail `AssumeRoleWithWebIdentity`) بـ `github-oidc.tf`؛ استخدم الـ role المناسب للـ job | [30](30-ci-github-actions.md)، [80](80-iam-oidc-least-privilege.md)، [92](92-terraform-in-ci.md) |
| الـ job مش بيبدأ: الـ branch مش مسموح يعمل deploy على `lab` | **Deployment branches** على الـ environment مقفولة على main/master (مقصود: الـ `sub` بتاع environment مفيهوش ref) | شغّل من master/main، أو عدّل الـ policy عن وعي | [CONVENTIONS §9](../CONVENTIONS.md)، [34](34-environments-approvals-promotion.md) |
| `Error acquiring the state lock` | apply تاني شغال، أو run اتعمله cancel وساب `<key>.tflock` | استنى/اتأكد إن مفيش run شغال، وبعدين `terraform force-unlock <LOCK_ID>` | [90](90-terraform-deep-dive.md)، [92](92-terraform-in-ci.md) |
| CodePipeline Source فشل: الـ connection مش `AVAILABLE` | CodeConnections اتعمل **PENDING** (Terraform مبيقدرش يكمّل الـ handshake) | Console → Developer Tools → Settings → Connections → `student-app-github` → **Update pending connection** → ثبّت **AWS Connector for GitHub** على الـ repo → Connect | [36](36-aws-codepipeline.md)، [`bootstrap/README.md`](../../../infra/terraform/bootstrap/README.md) |
| تغيير env في Terraform مش واصل للـ ECS tasks | الـ service بيتجاهل `task_definition`، والـ `ECS` action في CodePipeline بيعمل copy لـ revision الـ service الحالية | deploy بـ `deploy-ecs.yml taskdef_source=live` أو `deploy_mode=codebuild` | [51](51-ecs-fargate-terraform.md)، [58](58-ecs-github-actions-vs-codepipeline.md) |
| `::error::<repo>:<tag> is not in ECR. Run CI (ci.yml) on that commit first` | الـ deploy قبل ما الـ CI يعمل push (الـ push على main/master بس) | استنى `ci.yml` أو استخدم SHA اتعمله push | [32](32-cd-ec2-ecr-ssm.md)، [58](58-ecs-github-actions-vs-codepipeline.md) |
| k6: `csrf_failures` / `login_failures` / `session_relogins` > 0 | token قديم/cookie مش محفوظ، users مش seeded أو `LOADTEST_USERS` غلط، sessions مش مشتركة | seed بـ `LoadTestSeeder`، نفس `LOADTEST_USERS`، `SESSION_DRIVER=database` | [74](74-load-testing-k6.md) |

## 13) أسئلة Interview

<details><summary>أول 3 أوامر بتشغّلها لما deploy على ECS يفشل؟</summary>

`describe-services` (الـ deployments و `rolloutState` و آخر events)، `list-tasks --desired-status STOPPED` + `describe-tasks` (الـ `stoppedReason` و `containers[].reason`)، و `aws logs tail` على الـ log group. 90% من الأسباب: image/tag، secrets/IAM، شبكة، أو health check.

</details>

<details><summary>Targets unhealthy في الـ ALB — طريقتك في الـ debug؟</summary>

`describe-target-health` (الـ Reason: timeout؟ 503؟ connection refused؟) ← البورت والـ path بتوع الـ TG مقابل اللي الـ container بيسمع عليه (80 ولا 8080) ← SG من الـ ALB ← `curl` من جوه الـ VPC (Session Manager/ECS Exec) على `/ready` وأقرا الـ `reason` ← logs التطبيق والـ DB.

</details>

<details><summary>ليه الـ 419 ظهرت فجأة بعد blue/green؟</summary>

غالباً الـ session مبقتش قابلة للقراية من الإصدار الجديد: `APP_KEY` مختلف (الـ cookies مشفرة بيه)، أو الـ session store مش مشترك (file/memory). الحل: `APP_KEY` واحد من SSM و sessions في الـ DB/Redis، و rotation بـ `APP_PREVIOUS_KEYS`.

</details>

<details><summary>الـ canary اتعمله abort بس الـ release سليم. تفكيرك إيه؟</summary>

الـ gate نفسه أعمى: مفيش traffic كفاية، أو الـ metrics مش واصلة (scraping/token)، أو الـ threshold أضيق من الـ noise الطبيعي. اتأكد من الـ data قبل ما تلوم الـ release: `/metrics` بتاع الـ canary، عدد الـ requests، الـ AnalysisRun measurements. fail-closed أحسن من promote أعمى، بس لازم يتصلّح.

</details>

<details><summary>إزاي تعرف ده drift ولا تغيير مقصود؟</summary>

`terraform plan -refresh-only` / `-detailed-exitcode` بيقولك فيه فرق. بعدين: مين المالك؟ الـ repo بيوثّق الـ drift المقصود (الـ image، الـ weights، الـ desired count) بـ `ignore_changes` أو `*_managed_externally`. أي فرق تاني = تعديل يدوي → adopt (تعدّل الكود) أو revert (apply).

</details>

<details><summary>OIDC role بيرفض الـ assume من workflow جديد. هتعمل إيه؟</summary>

أشوف الـ `sub` الفعلي (CloudTrail event أو decode للـ token في debug step) وأقارنه بالـ trust policy: الـ job فيه `environment`؟ PR؟ branch جديد؟ و `aud` و `id-token: write`. الحل يا تعدّل الـ job (environment صح) يا تضيف subject محدد — مش wildcard `repo:*`.

</details>

## 14) Checklist

- [ ] عملت alias/snippets لأكتر أوامر بتستخدمها (`ecs describe-services`، `describe-target-health`، `status.sh`، `argo rollouts get`)
- [ ] قابلت 5 أعطال على الأقل من الجدول وحلّيتها بنفسك
- [ ] ضفت أي عطل جديد قابلته للجدول (مع السبب والحل)
