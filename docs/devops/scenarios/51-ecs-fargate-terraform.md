# 51 — ECS Fargate بـ Terraform

> **الهدف في سطر:** تقرا stack [`50-ecs-fargate`](../../../infra/terraform/stacks/50-ecs-fargate/) سطر بسطر: الـ variables، إزاي بيربط `network` و `alb` و `rds-mysql` و `ecs-fargate` و `observability` و `codedeploy`، الـ outputs (ومنها أمر الـ migration الجاهز)، وليه الـ service عامل `ignore_changes` على `task_definition` و `desired_count` و `load_balancer` — وتعمل init/plan/apply/destroy وانت عارف كل resource بيتكلف كام.
> **المستوى:** Intermediate → Advanced · **الوقت:** ~3 ساعات · **التكلفة التقريبية:** ≈ $0.11/ساعة ≈ $2.7/يوم (تقريبي — راجع صفحة الأسعار)
> **بيعتمد على:** [50 — ECS من الـ Console](50-ecs-fargate-console.md) · [30 — CI](30-ci-github-actions.md) · [90 — Terraform بالتفصيل](90-terraform-deep-dive.md) · **الملفات في الـ repo:** [`stacks/50-ecs-fargate/main.tf`](../../../infra/terraform/stacks/50-ecs-fargate/main.tf) · [`variables.tf`](../../../infra/terraform/stacks/50-ecs-fargate/variables.tf) · [`outputs.tf`](../../../infra/terraform/stacks/50-ecs-fargate/outputs.tf) · [`ssm.tf`](../../../infra/terraform/stacks/50-ecs-fargate/ssm.tf) · [`terraform.tfvars.example`](../../../infra/terraform/stacks/50-ecs-fargate/terraform.tfvars.example) · [`modules/ecs-fargate/`](../../../infra/terraform/modules/ecs-fargate/) · [`modules/alb/main.tf`](../../../infra/terraform/modules/alb/main.tf)

## 1) الفكرة (Concepts)

الـ stack ده **root module ephemeral**: apply → اتعلم → destroy في نفس اليوم. هو مجرد "wiring" لـ modules جاهزة، والذكاء كله في **حدود الملكية (ownership boundaries)**: مين المسؤول عن كل حقل بعد أول apply.

| الحقل | المالك بعد أول apply | ليه |
|---|---|---|
| الـ VPC، الـ ALB، الـ RDS، الـ roles، الـ env/secrets، الـ sizing | **Terraform** | infrastructure |
| الـ image (أي revision الـ service شغّالها) | **CI** (`deploy-ecs.yml` / CodePipeline) | Terraform بيعمل revision أولى بـ `image_tag` وبعدها يتجاهل |
| `desired_count` | **Application Auto Scaling** (2..6) | Terraform ميرجّعهاش لـ 2 كل apply |
| الـ primary target group في `load_balancer` | **الـ deployer** (ECS native أو CodeDeploy) | بعد كل blue/green ممكن الـ live يبقى green |
| الـ weights في الـ listener rule (native) | **ECS** | `ignore_changes = [action]` |
| الـ listener default action (CODE_DEPLOY) | **CodeDeploy** | `weights_managed_externally = true` في الـ ALB module |

| المصطلح | المعنى |
|---|---|
| `lifecycle.ignore_changes` | Terraform بيعمل الحقل مرة وبعدين ميعملش diff عليه — الـ "handoff" لمالك تاني |
| `-replace=ADDR` | يجبر destroy + create لـ resource معين حتى لو الـ diff في حقل متجاهل |
| Partial backend | الـ `key` جوه الـ stack، والـ bucket/region/lockfile من `../../backend.hcl` |
| `default_tags` | الـ tags الإجبارية على كل resource ([`providers.tf`](../../../infra/terraform/stacks/50-ecs-fargate/providers.tf))، وبتوصل للـ tasks بـ `propagate_tags = "SERVICE"` |

## 2) المعمارية (Architecture)

```text
 stacks/50-ecs-fargate  (state: s3://student-app-tfstate-<acct>/stacks/50-ecs-fargate/terraform.tfstate)
 │
 ├─ module.network ........ VPC 10.50.0.0/16، 2 AZ، enable_nat (default false)
 │        │ public_subnet_ids ─────────────┐        private_subnet_ids ──┐
 ├─ module.alb ............ ip targets :8080، TGs blue/green (/ready)، /metrics → 404 (priority 1)
 │        │ weights_managed_externally = (deployment_controller == "CODE_DEPLOY")
 │        │ outputs: security_group_id, target_group_arns, listener_arn, alb_arn_suffix
 ├─ module.rds ............ MySQL 8.4 في الـ private subnets؛ allowed SG = module.ecs.security_group_id
 │        │ يكتب DB_HOST/DB_PORT/DB_DATABASE/DB_USERNAME/DB_PASSWORD في /student-app/lab/app/*
 ├─ ssm.tf ................ APP_KEY, SRE_LAB_TOKEN (SecureString) + APP_URL, DB_CONNECTION, SESSION_DRIVER,
 │                          CACHE_STORE, SRE_LAB_ENABLED, METRICS_ENABLED (String)
 ├─ module.ecs ............ cluster + capacity providers، task def "app"، SG، service، autoscaling، IAM
 │        secrets = rds.ssm_parameter_arns ∪ aws_ssm_parameter.app[*].arn ∪ aws_ssm_parameter.app_secret[*].arn
 │        subnet_ids = enable_nat ? private : public ;  assign_public_ip = !enable_nat
 ├─ module.codedeploy ..... count = deployment_controller == "CODE_DEPLOY" ? 1 : 0
 ├─ module.observability .. alarms + dashboard (يستقبل أسماء الـ cluster/service كـ strings → مفيش cycle)
 └─ module.fis ............ count = enable_fis ? 1 : 0   (stop condition = alarm alb_5xx_ratio)
```

**الـ cycle اللي اتحل بالـ locals:** الـ service محتاج اسم alarm الـ 5xx (deployment alarms)، والـ observability محتاج اسم الـ cluster/service للـ dashboard. لو الاتنين خدوا outputs من بعض = dependency cycle. الحل في [`main.tf`](../../../infra/terraform/stacks/50-ecs-fargate/main.tf): `local.cluster_name` و `local.service_name` (نفس الأسماء اللي الـ module بيشتقها من `var.name`) بيتبعتوا للـ observability كـ strings.

**ترتيب الإنشاء اللي Terraform بيستنتجه:** الـ secrets بتتبعت كـ **ARNs بتاعة الـ resources** (مش strings مكتوبة بإيدك)، فالـ task definition مبيتسجّلش غير بعد ما كل parameter يبقى موجود — وإلا أول tasks كانت هتقع بـ `ResourceInitializationError`.

## 3) المتطلبات (Prerequisites)

- [ ] الـ bootstrap اتعمله apply، و `infra/terraform/backend.hcl` موجود (`terraform -chdir=infra/terraform/bootstrap output -raw backend_hcl > infra/terraform/backend.hcl`).
- [ ] image في ECR (`aws ecr list-images --repository-name student-app --query 'imageIds[].imageTag'`).
- [ ] Terraform `>= 1.10`، والـ AWS provider هيتحمّل `~> 6.21` ([`versions.tf`](../../../infra/terraform/stacks/50-ecs-fargate/versions.tf) — LINEAR/CANARY الـ native محتاجين 6.21+).
- [ ] credentials بـ admin (laptop) — أو workflow [`terraform.yml`](../../../.github/workflows/terraform.yml): بيمرر `TF_VAR_image_tag` من repo variable **`ECS_IMAGE_TAG`** (أول image بس)، فاعملها قبل أول run: `gh variable set ECS_IMAGE_TAG --body <SHA7>`.
- [ ] **الـ console resources بتاعة [50](50-ecs-fargate-console.md) اتمسحت** (نفس أسماء الـ roles والـ SGs والـ ALB والـ TGs والـ log group والـ SSM paths) ومفيش stack 20/40/60 على `env=lab`.

## 4) الطريقة الأولى: AWS Console — اتفرّج على اللي Terraform عمله

مفيش حاجة تتعمل بإيدك. بعد الـ apply لف على: **ECS → Clusters → `student-app-lab`** (Services، Tasks، Infrastructure: FARGATE + FARGATE_SPOT + default strategy) · **Task definitions → `student-app-lab-app`** (revision 1 = Terraform) · **EC2 → Load balancers / Target groups** · **RDS** · **Systems Manager → Parameter Store** (فلتر `/student-app/lab/app`) · **IAM → Roles** (`student-app-lab-ecs-*`) · **CloudWatch → Alarms / Dashboards** · **Application Auto Scaling** من تاب الـ service. قارن كل حاجة بالجداول في [50](50-ecs-fargate-console.md).

## 5) الطريقة التانية: Infrastructure as Code (Terraform)

### 5.1 الـ Variables ([`variables.tf`](../../../infra/terraform/stacks/50-ecs-fargate/variables.tf))

| Variable | Default | بيأثر على إيه |
|---|---|---|
| `project` / `env` / `region` | `student-app` / `lab` / `us-east-1` | الأسماء (`student-app-lab-*`) ومسار SSM `/student-app/<env>/app` |
| `scenario` | `"50"` | tag بس |
| `vpc_cidr` | `10.50.0.0/16` | |
| `enable_nat` | `false` | `false`: tasks في public subnets + public IP · `true`: private + NAT واحد |
| `certificate_arn` | `null` | HTTPS listener + redirect من 80 |
| `app_url` | `null` | `null` = `http://<alb-dns>` → `APP_URL` في SSM |
| `ecr_repository_name` | `student-app` | |
| `image_tag` | **مطلوب** | أول image بس. validation: مش `latest` و regex `^[A-Za-z0-9._-]{1,128}$` |
| `task_cpu` / `task_memory` | `512` / `1024` | 0.5 vCPU / 1 GiB |
| `desired_count` | `2` | أول مرة بس (بعدها autoscaling) |
| `autoscaling_min` / `autoscaling_max` | `2` / `6` | |
| `use_fargate_spot` | `true` | `FARGATE base=1 weight=0` + `FARGATE_SPOT weight=1` · `false`: `FARGATE weight=1` |
| `container_insights` | `enhanced` | `enhanced` / `enabled` / `disabled` |
| `app_environment` | `{}` | env زيادة غير سرّية (بتوصل مع الـ CI deploy الجاي). **مش للـ `SRE_FAULT_*`**: `render-taskdef.sh live` بيشيلها — الـ drills بـ `extra_env` في `deploy-ecs.yml` |
| `sre_lab_enabled` | `true` | `SRE_LAB_ENABLED` في SSM |
| `deployment_controller` | `ECS` | `ECS` أو `CODE_DEPLOY` ([54](54-ecs-codedeploy-bluegreen-canary.md)) |
| `deployment_strategy` | `ROLLING` | `ROLLING` / `BLUE_GREEN` / `LINEAR` / `CANARY` ([53](53-ecs-rolling-circuit-breaker.md)، [55](55-ecs-native-bluegreen-linear-canary.md)) |
| `bake_time_in_minutes` | `5` | native: blue يفضل قد إيه بعد الـ switch · CODE_DEPLOY: termination wait |
| `canary_percent` / `linear_step_percent` | `10` / `25` | |
| `codedeploy_deployment_config_name` | `CodeDeployDefault.ECSAllAtOnce` | |
| `use_deployment_alarms` | `false` | يربط alarm الـ ALB 5xx ratio بالـ deployment (rollback) |
| `db_instance_class` | `db.t4g.micro` | |
| `alarm_email` | `null` | SNS subscription (لازم تأكد الإيميل) |
| `enable_fis` | `false` | FIS template ([75](75-chaos-engineering-fis.md)) |

> 💡 **Inputs موجودة في الـ module ومش متعرّضة في الـ stack** (عشان تغيّرها لازم تعدّل الـ `module "ecs"` block في `main.tf`): `stop_timeout` (30)، `health_check_grace_period_seconds` (60)، `cpu_architecture` (`X86_64`)، `cpu_target_value` (50)، `requests_per_target` (600)، `enable_request_count_scaling`، `canary_bake_time_in_minutes` (5)، `linear_step_bake_time_in_minutes` (2)، `enable_test_listener_rule` (true)، `log_retention_days` (14)، `init_process_enabled` (false). ده تصميم مقصود: الـ stack بيعرّض اللي بتلعب بيه في السيناريوهات بس.

### 5.2 جوه `module.ecs` ([`modules/ecs-fargate`](../../../infra/terraform/modules/ecs-fargate/))

| ملف | أهم حاجة فيه |
|---|---|
| [`main.tf`](../../../infra/terraform/modules/ecs-fargate/main.tf) | cluster (`containerInsights`، `execute_command_configuration { logging = "DEFAULT" }`)، `aws_ecs_cluster_capacity_providers` (FARGATE + FARGATE_SPOT + default strategy = نفس استراتيجية الـ service، وده كمان default لأي `run-task` من غير strategy)، log group `/ecs/<name>/app` (14 يوم)، SG (ingress من SG الـ ALB بس، egress all)، الـ container definition (env و secrets **sorted** عشان الـ plan يفضل هادي، healthCheck `/up`، `stopTimeout`، `initProcessEnabled`، `awslogs` non-blocking)، و `runtime_platform` |
| [`service.tf`](../../../infra/terraform/modules/ecs-fargate/service.tf) | listener rules (للـ native بس)، الـ service: `platform_version = "LATEST"`، `enable_execute_command`، `propagate_tags = "SERVICE"`، `health_check_grace_period_seconds`، `availability_zone_rebalancing` (ENABLED مع ECS controller بس)، `deployment_minimum_healthy_percent=100` / `maximum_percent=200`، circuit breaker، alarms، `deployment_configuration` (strategy/bake/canary/linear)، و الـ `lifecycle.ignore_changes` |
| [`autoscaling.tf`](../../../infra/terraform/modules/ecs-fargate/autoscaling.tf) | target tracking CPU 50% (out 60s / in 180s) + `ALBRequestCountPerTarget` 600 (للـ ROLLING بس) |
| [`iam.tf`](../../../infra/terraform/modules/ecs-fargate/iam.tf) | execution role (ECR repo واحد، log group واحد، `ssm:GetParameters` على `<prefix>/*`، `kms:Decrypt` via SSM)، task role (ECS Exec بس: ssmmessages + كتابة الـ session logs في log group الـ app)، infrastructure role (native traffic shifting: `AmazonECSInfrastructureRolePolicyForLoadBalancers`) — كلهم بـ `aws:SourceAccount` |

### 5.3 الـ `ignore_changes` — أهم 12 سطر في الـ stack

```hcl
lifecycle {
  ignore_changes = [
    task_definition,  # CI owns the image
    desired_count,    # Application Auto Scaling owns the count
    load_balancer,    # native B/G and CodeDeploy swap blue <-> green
  ]
}
```

- **`task_definition`:** من غير ده، أول `terraform apply` بعد أي CI deploy هيرجّع الـ service للـ revision اللي Terraform عملها بـ `var.image_tag` = **rollback صامت لـ production** على شكل "infra change". ومعاه: لو غيّرت env/secret في Terraform، Terraform بيسجّل revision جديدة في الـ family (task definitions immutable → `must be replaced`) **بس الـ service ميتحركش**. الـ deploy الجاي بـ `taskdef_source=live` بيعمل copy لأحدث revision في الـ family (اللي فيها تعديلك) ويغيّر الـ image بس → كده الـ env بيوصل. (الـ copy بيشيل أي `SRE_FAULT_*` — fault الـ drill عمره ما بيتورّث للـ deploy اللي بعده؛ `KEEP_FAULT_ENV=true` لو عايزه يفضل.)
- **`desired_count`:** الـ autoscaling ممكن يكون مكبّر لـ 5 وقت load؛ apply من غير ignore هيرجّعها 2 في نص الـ peak.
- **`load_balancer`:** بعد blue/green الـ service ممكن يبقى primary على green. Terraform شايف `blue` في الـ config → كان هيحاول يرجّع (وده API مش مسموح أصلاً لخدمات CODE_DEPLOY). التمن: **تغيير عائلة الاستراتيجية** (ROLLING ⇄ BLUE_GREEN/LINEAR/CANARY أو ECS ⇄ CODE_DEPLOY) على service موجود محتاج:

```bash
terraform apply -replace=module.ecs.aws_ecs_service.app
```

> ⚠️ **Gotchas الـ `-replace`:**
> 1. الـ service بيتمسح وبعدين يتعمل (نفس الاسم، فمينفعش create-before-destroy) → **downtime** دقيقة-اتنين. Lab بس.
> 2. الـ service الجديد بيقوم على **revision بتاعة Terraform** (`var.image_tag`)، مش آخر release. حدّث `image_tag` في `terraform.tfvars` للـ SHA الشغال حالياً قبل الـ replace، أو اعمل CI deploy فوراً بعده.
> 3. `desired_count` بيرجع `var.desired_count` (2) لحد ما الـ autoscaling يشتغل.

### 5.4 الـ Outputs ([`outputs.tf`](../../../infra/terraform/stacks/50-ecs-fargate/outputs.tf))

| Output | الاستخدام |
|---|---|
| `app_url` / `alb_dns_name` | `curl`، k6، `ECS_APP_URL` |
| `cluster_name` / `service_name` / `task_family` | `student-app-lab` / `student-app-lab-app` / `student-app-lab-app` |
| `task_definition_arn` | الـ revision اللي Terraform سجّلها (bootstrap image) |
| `log_group` | `/ecs/student-app-lab/app` (streams `app/app/<task-id>`) |
| `target_group_names` / `listener_arn` | للـ CodeDeploy والتحقق |
| `run_task_network_configuration` | JSON جاهز لـ `aws ecs run-task --network-configuration` |
| `migration_command` | `aws ecs run-task` خام (FARGATE on-demand، command override `php artisan migrate --force`) — **بيرجع الـ task ARN بس، مش بيستنى** |
| `migration_script_command` | `AWS_REGION=... deploy/ecs/run-migrations.sh --cluster ... --service ...` — بيستنى ويتشيك الـ exit code ويطبع الـ logs ([52](52-ecs-migrations-and-exec.md)) |
| `ecs_exec_command` | `deploy/ecs/ecs-exec.sh --cluster ... --service ...` |
| `deployment` | `controller`، `strategy`، `production_rule`، `test_rule`، `alarms` الفعلية |
| `codedeploy_app_name` / `codedeploy_deployment_group_name` | `null` إلا مع CODE_DEPLOY |
| `rds_address` / `ssm_prefix` / `dashboard_url` / `fis_experiment_template_ids` | |
| `github_repository_variables` | `ECS_CLUSTER`، `ECS_SERVICE`، `ECS_APP_URL`، `ECS_CODEDEPLOY_*` لـ `deploy-ecs.yml` |
| `pipeline_inputs` | بيغذّي stack 36 ([58](58-ecs-github-actions-vs-codepipeline.md)) |

## 6) الـ Deploy

```bash
cd infra/terraform/stacks/50-ecs-fargate
cp terraform.tfvars.example terraform.tfvars
# عدّل image_tag لـ SHA موجود فعلاً في ECR:
aws ecr describe-images --repository-name student-app \
  --query 'sort_by(imageDetails,&imagePushedAt)[-1].imageTags[0]' --output text

terraform init -backend-config=../../backend.hcl
terraform fmt -check && terraform validate
terraform plan -out=tfplan          # راجع الـ "Plan: N to add"، ومفيش aws_nat_gateway لو enable_nat=false
terraform apply tfplan              # ~10 دقايق (RDS هو الأبطأ)
```

مرة واحدة قبل أول traffic حقيقي (الـ tasks بتقوم عادي و `/ready` = 200 لأنه بيعمل `select 1` بس، لكن الصفحات الحقيقية زي `/login` بتقع لحد ما الـ schema تبقى موجودة):

> ⚠️ الـ output `migration_script_command` فيه `deploy/ecs/run-migrations.sh` كـ **مسار نسبي من root الـ repo** — `eval` من فولدر الـ stack هيقع بـ `No such file or directory`. شغّله من الـ root (نفس اللي في الـ README):

```bash
cmd="$(terraform output -raw migration_script_command)" && (cd ../../../.. && eval "$cmd")
curl -s "$(terraform output -raw app_url)/ready" | jq
```

اربط GitHub (للـ [53](53-ecs-rolling-circuit-breaker.md)+):

```bash
terraform output -json github_repository_variables | \
  jq -r 'to_entries[] | select(.value != "") | "\(.key)\t\(.value)"' | \
  while IFS=$'\t' read -r k v; do gh variable set "$k" --body "$v"; done
gh variable list | grep ECS_
```

## 7) التحقق (Verify)

```bash
terraform output deployment
terraform output -raw app_url
aws ecs describe-services --cluster student-app-lab --services student-app-lab-app \
  --query 'services[0].{ctrl:deploymentController.type,strategy:deploymentConfiguration.strategy,min:deploymentConfiguration.minimumHealthyPercent,max:deploymentConfiguration.maximumPercent,cb:deploymentConfiguration.deploymentCircuitBreaker,cps:capacityProviderStrategy}'
aws application-autoscaling describe-scalable-targets --service-namespace ecs \
  --query 'ScalableTargets[].{id:ResourceId,min:MinCapacity,max:MaxCapacity}'
```

**اختبار الـ ownership:** اعمل CI deploy ([53](53-ecs-rolling-circuit-breaker.md)) ثم `terraform plan` تاني → المفروض **`No changes`** رغم إن الـ service شغال revision غير اللي في الـ state. لو ظهر diff على `task_definition` يبقى الـ `ignore_changes` مش شغال.

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر | المتوقع |
|---|---|---|
| `latest` | `terraform plan -var image_tag=latest` | validation error قبل أي API call: `image_tag must be an immutable tag` |
| Tag مش موجود | `-var image_tag=0000000` ثم apply على stack جديد | الـ tasks `CannotPullContainerError`؛ الـ circuit breaker مش هيرجّع لأنه مفيش deployment قديم `COMPLETED` → اعمل CI deploy بـ tag صح |
| تغيير env | `-var 'app_environment={DEPLOY_COLOR="green"}'` ثم apply | plan: الـ task definition `must be replaced` والـ service **متغيّرش** — `/ready` لسه `"color":"stable"` لحد الـ CI deploy الجاي (live) وبعده `"green"` |
| Fault في Terraform | `-var 'app_environment={SRE_FAULT_ERROR_RATE="0.5"}'` + apply + CI deploy (live) | الـ fault **مش هيوصل**: `render-taskdef.sh live` بيشيل `SRE_FAULT_*` — الـ faults بـ `extra_env` لكل deploy لوحده |
| تغيير الاستراتيجية من غير replace | `-var deployment_strategy=BLUE_GREEN` + apply | الـ `advanced_configuration` جوه `load_balancer` متجاهلة → الـ service مش هيبقى متظبط صح للـ native (غالباً الـ apply يفشل من الـ API أو الـ deploy الجاي يفشل). الصح: `-replace` |
| `enable_nat=true` | apply | NAT + EIP يتعملوا، الـ network_configuration يتغير → deployment جديد للـ tasks في الـ private subnets بـ `assignPublicIp=DISABLED` (والتكلفة +$1/يوم) |
| `terraform.yml` من غير `ECS_IMAGE_TAG` | امسح الـ repo variable → Actions → Terraform → `50-ecs-fargate` → plan | `TF_VAR_image_tag` فاضي → الـ validation بتاع `image_tag` يفشل. اعمل `gh variable set ECS_IMAGE_TAG --body <SHA7>` (أول image بس؛ بعدها `deploy-ecs.yml` يملكها) |

## 9) الرجوع (Rollback)

- **Infra change بايظ:** `git revert` للتعديل → `terraform plan/apply`. الـ state نفسه له versions في S3 (90 يوم) لو احتجت تسترجع state قديم (آخر حل).
- **App release بايظ:** مش شغل Terraform — `aws ecs update-service --task-definition <previous>` أو re-run `deploy-ecs.yml` بالـ tag القديم ([53](53-ecs-rolling-circuit-breaker.md)).
- **Secret اتغير غلط:** صلّح في Terraform → apply → **Force new deployment** (أو CI deploy) عشان الـ tasks تقرا القيمة.

## 10) المسح (Teardown) ⚠️

```bash
# 1) لو stack 36 (CodePipeline) شغال: امسحه الأول — بيشاور على الـ service والـ roles دي
terraform -chdir=../36-codepipeline destroy

# 2) stack 50
terraform destroy

# 3) اللي Terraform ميعرفوش: revisions سجّلها الـ CI
for td in $(aws ecs list-task-definitions --family-prefix student-app-lab-app --status ACTIVE --query 'taskDefinitionArns[]' --output text); do
  aws ecs deregister-task-definition --task-definition "$td" >/dev/null
done
aws ecs list-task-definitions --family-prefix student-app-lab-app --status INACTIVE --query 'taskDefinitionArns[]' --output text | \
  xargs -r -n 10 aws ecs delete-task-definitions --task-definitions

# 4) log groups عملها AWS مش Terraform (Container Insights)
aws logs describe-log-groups --log-group-name-prefix /aws/ecs/containerinsights/student-app-lab --query 'logGroups[].logGroupName'
```

الـ RDS: `skip_final_snapshot = true` و `deletion_protection = false` (defaults الـ module) → الـ destroy مش هيقف. تأكد: `aws ecs list-clusters`، `aws rds describe-db-instances`، `aws elbv2 describe-load-balancers`.

## 11) التكلفة (Cost)

من [`stacks/50-ecs-fargate/README.md`](../../../infra/terraform/stacks/50-ecs-fargate/README.md) (us-east-1، defaults، تقريبي — راجع صفحة الأسعار):

| Item | USD/ساعة |
|---|---|
| ALB (+ ~1 LCU) | ~0.03 |
| Fargate: 1 × on-demand 0.5 vCPU/1 GiB + 1 × Spot | ~0.025 + ~0.008 |
| Public IPv4 (2 للـ ALB + 2 tasks) | ~0.02 |
| RDS `db.t4g.micro` + 20 GiB gp3 | ~0.019 |
| Container Insights enhanced، logs، alarms، dashboard | ~0.01 |
| **الإجمالي** | **≈ 0.11 (≈ $2.7/يوم، ≈ $80/شهر)** |
| `enable_nat = true` | + ~0.045/ساعة + data processing |
| `autoscaling_max = 6` وقت load | لحد +5 tasks (أغلبها Spot) |

## 12) أسئلة Interview

<details><summary>ليه `ignore_changes = [task_definition]`؟ وإزاي التعديلات على الـ env بتوصل للـ tasks؟</summary>

عشان الـ CI هو مالك الـ image؛ من غيره أي `apply` يرجّع production لـ image الـ bootstrap. التعديلات على env/secrets: Terraform بيسجّل revision جديدة في نفس الـ family، والـ pipeline بيعمل copy لأحدث revision ويغيّر الـ image بس (`render-taskdef.sh live`). يعني "Terraform يملك الشكل، الـ CI يملك النسخة". البديل: task definition كاملة في الـ repo (`taskdef_source=repo`) — single source أوضح، بس لازم تفضل متزامنة يدوياً مع الـ stack.

</details>

<details><summary>إمتى تحتاج `-replace` وإيه مخاطره؟</summary>

لما حقل متجاهل لازم يتغير بشكل جوهري — هنا تبديل الـ deployment controller أو عائلة الاستراتيجية (`load_balancer.advanced_configuration` متجاهلة). المخاطر: downtime لأن الاسم ثابت (destroy قبل create)، الـ service الجديد بيرجع لـ revision بتاعة Terraform والـ desired count الافتراضي. في production: service جديد باسم تاني + تحويل الـ traffic (blue/green على مستوى الـ service)، أو maintenance window.

</details>

<details><summary>إزاي الـ stacks بتشارك data من غير `terraform_remote_state`؟</summary>

أسماء deterministic من `project`+`env`، `data.aws_caller_identity`/`aws_region`، SSM للـ runtime config، وoutputs مولّدة لملفات (`pipeline_inputs` → `stack50.auto.tfvars.json`). الـ remote_state بيربط الـ lifecycles: destroy لـ stack يكسر plan التاني، وأي حد بيقرا الـ state بيقرا كل الـ secrets اللي فيه.

</details>

<details><summary>إيه الـ dependency cycle اللي في الـ stack وإزاي اتحل؟</summary>

الـ service عايز اسم الـ alarm (deployment alarms) من `module.observability`، والـ observability عايز اسم الـ cluster/service من `module.ecs`. لو الاتنين outputs = cycle. الحل: الأسماء deterministic، فبتتحسب في `locals` وتتبعت كـ strings للـ observability. الدرس: لما الـ graph يعمل cycle، دوّر على قيمة تقدر تحسبها بدل ما تستناها.

</details>

<details><summary>ليه الـ secrets بتتبعت كـ resource ARNs مش كـ strings؟</summary>

عشان Terraform يبني dependency edge: الـ task definition مبتتسجّلش قبل ما الـ parameters تتعمل. لو كتبت الـ ARN كـ string، Terraform ممكن يسجّل الـ task def والـ service في نفس اللحظة اللي الـ parameters لسه بتتعمل فيها → أول tasks تقع بـ `ResourceInitializationError` وتلاقي نفسك بتعمل debug لـ race.

</details>

<details><summary>الـ module بيحط `default_capacity_provider_strategy` على الـ cluster. ليه ده مهم مع إن الـ service عنده strategy خاصة؟</summary>

لأن أي `run-task` أو حاجة بتعمل tasks من غير strategy صريحة (CodeDeploy replacement task set من غير `CapacityProviderStrategy` في الـ appspec) بتاخد الـ default. لو مفيش default، بعض الـ APIs بتقع على launch type FARGATE وبعضها بيرفض. عشان كده الـ migration scripts بتمرر `FARGATE` صراحةً — مش عايزين migration على Spot حتى لو الـ default فيه Spot.

</details>

## 13) Checklist

- [ ] قريت الـ stack والـ module وعارف مين يملك كل حقل
- [ ] عملت init/plan/apply وشغّلت الـ migration من الـ output
- [ ] ربطت الـ GitHub variables من `github_repository_variables`
- [ ] أثبتت إن `terraform plan` = No changes بعد CI deploy
- [ ] جرّبت تغيير env وفهمت إنه بيوصل مع الـ deploy الجاي
- [ ] فاهم إمتى `-replace` ومخاطره
- [ ] عملت destroy ونضفت الـ revisions والـ log groups اللي برّه الـ state
