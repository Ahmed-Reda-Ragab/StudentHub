# F — ECS (50–58): كروت الملخص

> كارت لكل سيناريو. التفاصيل في [`../scenarios/`](../scenarios/). الأسعار تقريبية (us-east-1) — راجع صفحة الأسعار.

### 50 — ECS Fargate من الـ Console
**الهدف:** تبني VPC + SGs (ALB→task→RDS) + SSM + roles + cluster + task def `app:8080` + ALB/TG blue + service بإيدك، وmigrations كـ Run task.
**أهم الأوامر:**
```bash
bash deploy/ecs/render-taskdef.sh repo deploy/ecs/task-definition.json > td-console.json   # مع AWS_ACCOUNT_ID/AWS_REGION/ENV_NAME/IMAGE_URI
aws ssm get-parameters-by-path --path /student-app/lab/app --query 'Parameters[].Name'
bash deploy/ecs/run-migrations.sh --cluster student-app-lab --task-definition student-app-lab-app --network-configuration "$NET"
aws ecs describe-services --cluster student-app-lab --services student-app-lab-app --query 'services[0].[runningCount,desiredCount]'
curl -s http://<ALB_DNS>/ready | jq
aws logs tail /ecs/student-app-lab/app --since 10m
```
**التحقق:** `/ready` = `ready` بالـ version الصح، الـ targets `healthy`، و `/metrics` = 404 · **Gotchas:** • الـ migrations قبل الـ service وإلا `/ready` 503 والـ tasks تتبدّل • container healthCheck على `/up` مش `/ready` • تغيير SSM محتاج Force new deployment · **التكلفة:** ≈ $0.11/ساعة (2 tasks + ALB + RDS، من غير NAT)

### 51 — ECS Fargate بـ Terraform
**الهدف:** تقرا وتشغّل stack 50 وتفهم الـ ownership: Terraform للـ infra، الـ CI للـ image، الـ autoscaling للـ count، الـ deployer للـ TG.
**أهم الأوامر:**
```bash
cd infra/terraform/stacks/50-ecs-fargate && cp terraform.tfvars.example terraform.tfvars   # image_tag = SHA في ECR
terraform init -backend-config=../../backend.hcl
terraform plan -out=tfplan && terraform apply tfplan
CMD=$(terraform output -raw migration_script_command); (cd ../../../.. && eval "$CMD")
terraform output github_repository_variables
terraform apply -replace=module.ecs.aws_ecs_service.app      # تغيير عائلة الـ strategy/controller بس
terraform destroy                                            # بعد stack 36
```
**التحقق:** `terraform plan` = No changes بعد CI deploy (الـ `ignore_changes` شغال) · **Gotchas:** • `-replace` = downtime ويرجع لـ `image_tag` بتاع الـ tfvars • تعديل env بيوصل مع الـ deploy الجاي بس (و `SRE_FAULT_*` في `app_environment` بتتشال — الـ faults بـ `extra_env`) • من GitHub (`terraform.yml`) لازم repo variable `ECS_IMAGE_TAG` · **التكلفة:** ≈ $2.7/يوم؛ NAT +~$1/يوم

### 52 — Migrations كـ one-off task + ECS Exec
**الهدف:** migration مرة لكل release على on-demand بـ exit code يوقف الـ pipeline، و shell جوه الـ task من غير SSH.
**أهم الأوامر:**
```bash
export AWS_REGION=us-east-1 ECS_CLUSTER=student-app-lab ECS_SERVICE=student-app-lab-app
bash deploy/ecs/run-migrations.sh                                   # revision الـ service الحالية
bash deploy/ecs/run-migrations.sh --task-definition "$TD_ARN" --timeout 1800
bash deploy/ecs/ecs-exec.sh -- php artisan migrate:status
bash deploy/ecs/ecs-exec.sh -- wget -qO- http://127.0.0.1:8080/ready
aws ecs describe-tasks --cluster $ECS_CLUSTER --tasks <ID> --query 'tasks[0].containers[].exitCode'
```
**التحقق:** `✔ migrations done` و exit 0؛ `ExecuteCommandAgent` = RUNNING؛ output الـ session في `/ecs/student-app-lab/app` + `ExecuteCommand` في CloudTrail · **Gotchas:** • STOPPED ≠ نجح — الـ `exitCode` هو الحكم • `initProcessEnabled=false` لأن S6 لازم PID 1 • Exec بيتقرر وقت start الـ task؛ والـ session logs بتتكتب بالـ **task role** (`logs:*` على log group الـ app) · **التكلفة:** أقل من سنت لكل one-off task

### 53 — Rolling + circuit breaker rollback
**الهدف:** min 100% / max 200%، circuit breaker + rollback، grace period، drain 30s + SIGQUIT، و drills الـ boot-fail والـ unhealthy بـ 0 failures.
**أهم الأوامر:**
```bash
gh workflow run deploy-ecs.yml --ref master -f strategy=rolling -f taskdef_source=live
bash deploy/scripts/probe.sh "$URL/ready" 300 0.2
gh workflow run deploy-ecs.yml --ref master -f strategy=rolling -f run_migrations=false -f extra_env="SRE_FAULT_BOOT_FAIL=true"
gh workflow run deploy-ecs.yml --ref master -f strategy=rolling -f extra_env="SRE_FAULT_UNHEALTHY=true"
aws ecs describe-services --cluster student-app-lab --services student-app-lab-app --query 'services[0].deployments[].[rolloutState,failedTasks]'
bash deploy/ecs/render-taskdef.sh live student-app-lab-app | jq '[.containerDefinitions[0].environment[].name]'   # مفيش SRE_FAULT_*
```
**التحقق:** `rolloutState FAILED` → rollback لـ `COMPLETED`، الـ job أحمر (smoke: version ≠ tag)، و `probe.sh` = `failed : 0` · **Gotchas:** • `run_migrations=false` للـ boot-fail drill بس (غير كده الـ migration step بيوقفه بدري) • الـ `live` render بيشيل `SRE_FAULT_*` — الـ faults مبتتورّثش (`KEEP_FAULT_ENV=true` للعكس) • الـ circuit breaker مش بيشوف error rate (ده شغل الـ alarms) · **التكلفة:** surge دقايق لكل deploy (سنتات)

### 54 — Blue/Green و Canary و Linear بـ CodeDeploy
**الهدف:** `CODE_DEPLOY` controller: TGين، prod listener، appspec، deployment configs، alarm rollback، termination wait.
**أهم الأوامر:**
```bash
terraform apply -var deployment_controller=CODE_DEPLOY -var codedeploy_deployment_config_name=CodeDeployDefault.ECSCanary10Percent15Minutes -var use_deployment_alarms=true -replace=module.ecs.aws_ecs_service.app
gh workflow run deploy-ecs.yml --ref master -f strategy=codedeploy -f taskdef_source=live
aws deploy get-deployment --deployment-id <ID> --query 'deploymentInfo.[status,deploymentOverview]'
aws elbv2 describe-listeners --listener-arns "$L" --query 'Listeners[0].DefaultActions[0].ForwardConfig.TargetGroups'
aws deploy stop-deployment --deployment-id <ID> --auto-rollback-enabled
terraform apply -var deployment_controller=ECS -replace=module.ecs.aws_ecs_service.app
```
**التحقق:** الـ weights 100/0 → 90/10 → 0/100 والـ plan = No changes والـ live على green · **Gotchas:** • `update-service --task-definition` مرفوض مع CODE_DEPLOY • الـ listener بيتعمل replace لما `weights_managed_externally` يتغير • نافذة الـ canary لازم أطول من الـ alarm (5 دقايق) · **التكلفة:** CodeDeploy مجاني؛ capacity مضاعفة لحد آخر الـ wait

### 55 — ECS native blue/green و linear و canary
**الهدف:** traffic shifting من غير CodeDeploy: alternate TG + production/test listener rules + infrastructure role + bake time.
**أهم الأوامر:**
```bash
terraform apply -var deployment_strategy=CANARY -replace=module.ecs.aws_ecs_service.app   # BLUE_GREEN | LINEAR | CANARY
terraform output deployment
gh workflow run deploy-ecs.yml --ref master -f strategy=native -f taskdef_source=live
aws ecs list-service-deployments --cluster student-app-lab --service student-app-lab-app
curl -s -H 'X-Lab-Target: green' "$URL/ready" | jq .version
k6 run -e BASE_URL="$URL" -e EXPECT_VERSIONS=<OLD>,<NEW> loadtest/k6/canary-watch.js
aws ecs stop-service-deployment --service-deployment-arn "$SD" --stop-type ROLLBACK
```
**التحقق:** الـ lifecycle stages لحد `CLEAN_UP` والـ weights على rule priority 100 · **Gotchas:** • من غير Pause hook نافذة الـ test header ثواني • `ALBRequestCountPerTarget` بيتشال مع الـ strategies دي • `DEPLOY_COLOR=stable` على الكل — قيس بالـ version · **التكلفة:** مجاني؛ green 100% من `SCALE_UP` لحد `CLEAN_UP`

### 56 — Capacity providers و Fargate Spot
**الهدف:** `base`/`weight` بين FARGATE و FARGATE_SPOT، الـ Spot interruption والـ graceful shutdown، وإمتى EC2/Graviton.
**أهم الأوامر:**
```bash
aws ecs describe-services --cluster student-app-lab --services student-app-lab-app --query 'services[0].capacityProviderStrategy'
aws ecs describe-tasks --cluster student-app-lab --tasks $(aws ecs list-tasks --cluster student-app-lab --query 'taskArns' --output text) --query 'tasks[].[capacityProviderName,availabilityZone]'
aws ecs update-service --cluster student-app-lab --service student-app-lab-app --desired-count 6
aws ecs stop-task --cluster student-app-lab --task "$SPOT_TASK" --reason "drill: simulated spot interruption"
terraform apply -var use_fargate_spot=false
```
**التحقق:** 6 tasks = 1 FARGATE + 5 SPOT؛ `probe.sh` = 0 failures بعد الـ stop · **Gotchas:** • مفيش fallback أوتوماتيك من Spot لـ on-demand • ARM64 محتاج image multi-arch (الـ CI بيبني amd64) • الـ migrations دايماً على FARGATE · **التكلفة:** Spot ~$0.008/ساعة/task مقابل ~$0.025 on-demand؛ ARM ~20% أرخص

### 57 — ECS autoscaling تحت load
**الهدف:** target tracking (CPU 50% + 600 req/min/task)، cooldowns 60/180، capacity math، و SLOs ثابتة أثناء الـ scale-out.
**أهم الأوامر:**
```bash
TOKEN=$(aws ssm get-parameter --name /student-app/lab/app/SRE_LAB_TOKEN --with-decryption --query Parameter.Value --output text)
k6 run -e BASE_URL="$URL" -e LAB_TOKEN="$TOKEN" -e RATE=5 -e CPU_MS=200 -e DURATION=15m loadtest/k6/autoscale-cpu.js
k6 run -e BASE_URL="$URL" -e LOADTEST_USERS=20 -e VUS=50 -e DURATION=10m -e P95_MS=300 loadtest/k6/load.js
aws application-autoscaling describe-scaling-activities --service-namespace ecs --resource-id service/student-app-lab/student-app-lab-app --max-items 5
aws ecs describe-services --cluster student-app-lab --services student-app-lab-app --query 'services[0].[desiredCount,runningCount]'
gh workflow run perf-gate.yml -f base_url="$URL" -f script=autoscale-cpu.js -f duration=15m -f k6_env="RATE=5 CPU_MS=200"
```
**التحقق:** `desired count to 4` خلال ~5 دقايق لـ RATE=5، و k6 `load.js` exit 0 · **Gotchas:** • demand = RATE×CPU_MS/1000 ÷ (0.5×0.5) — RATE=10 = 8 tasks بيخبط في max 6 (RATE≤6 جوه الـ max) • الـ request policy لـ ROLLING بس • الـ DB connections هي الـ bottleneck الجاي · **التكلفة:** أقل من 5 سنت لكل drill

### 58 — ECS deploy بـ GitHub Actions مقابل CodePipeline
**الهدف:** نفس الـ release بـ `deploy-ecs.yml` (OIDC) وبـ stack 36 (CodeConnections + CodeBuild + modes ecs/codedeploy-ecs/codebuild) وتقارن التكلفة والـ audit.
**أهم الأوامر:**
```bash
gh workflow run deploy-ecs.yml --ref master -f strategy=rolling -f taskdef_source=live
cd infra/terraform/stacks/36-codepipeline
terraform -chdir=../50-ecs-fargate output -json pipeline_inputs > stack50.auto.tfvars.json
terraform init -backend-config=../../backend.hcl && terraform apply
aws codepipeline start-pipeline-execution --name student-app-lab-pipeline
aws codepipeline put-approval-result --pipeline-name student-app-lab-pipeline --stage-name Approve --action-name Promote --result summary=ok,status=Approved --token "$T"
terraform destroy && terraform -chdir=../50-ecs-fargate destroy     # 36 قبل 50
```
**التحقق:** الاتنين بيوصلوا `rolloutState COMPLETED` و `/ready` بالـ version الجديدة؛ execution history / job summary · **Gotchas:** • الـ `ECS` action بيعمل copy لـ revision الـ service (env Terraform مش واصل) • race بين `ci.yml` و الـ pipeline على نفس الـ tag (IMMUTABLE) • CodeConnections لازم AVAILABLE · **التكلفة:** GHA مجاني (public)؛ CodePipeline V2 ~$0.002/action-min + CodeBuild ~$0.05/release
