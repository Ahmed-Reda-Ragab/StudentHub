# 54 — Blue/Green و Canary و Linear بـ CodeDeploy

> **الهدف في سطر:** تحوّل الـ service لـ `deployment_controller = CODE_DEPLOY` وتعمل blue/green "الكلاسيكي" بـ AWS CodeDeploy: target groupين، production listener، `appspec.yaml`، deployment configs (`ECSAllAtOnce` / `ECSCanary10Percent5Minutes` / `ECSLinear10PercentEvery1Minutes`...)، rollback أوتوماتيك على CloudWatch alarm، وقت الانتظار والـ termination — وتعمل deploy من `deploy-ecs.yml strategy=codedeploy` ومن الـ console، وتفهم الـ drift لما الـ listener بيبقى ملك حد تاني.
> **المستوى:** Advanced · **الوقت:** ~4 ساعات · **التكلفة التقريبية:** نفس [51](51-ecs-fargate-terraform.md) + capacity مضاعفة وقت الـ deploy (CodeDeploy لـ ECS نفسه مجاني)
> **بيعتمد على:** [51](51-ecs-fargate-terraform.md) · [53](53-ecs-rolling-circuit-breaker.md) · [46 — Canary بـ weighted TGs](46-canary-weighted-target-groups.md) · [37 — CodeDeploy لـ EC2](37-aws-codedeploy-ec2.md) · **الملفات في الـ repo:** [`modules/codedeploy/main.tf`](../../../infra/terraform/modules/codedeploy/main.tf) · [`modules/codedeploy/variables.tf`](../../../infra/terraform/modules/codedeploy/variables.tf) · [`deploy/ecs/appspec.yaml`](../../../deploy/ecs/appspec.yaml) · [`modules/alb/main.tf`](../../../infra/terraform/modules/alb/main.tf) · [`stacks/50-ecs-fargate/main.tf`](../../../infra/terraform/stacks/50-ecs-fargate/main.tf) · [`.github/workflows/deploy-ecs.yml`](../../../.github/workflows/deploy-ecs.yml) · [`deploy/ecs/taskdef.json`](../../../deploy/ecs/taskdef.json)

## 1) الفكرة (Concepts)

مع `CODE_DEPLOY` controller، ECS بيبطّل يعمل deployments بنفسه. كل release = **CodeDeploy deployment**: CodeDeploy بيعمل **replacement task set** (green) جنب الـ **original task set** (blue)، يسجّله في الـ target group التاني، يحوّل الـ traffic على الـ **listener** حسب الـ deployment config، يستنى، وبعدين يقفل الـ original.

| المصطلح | المعنى |
|---|---|
| Task set | مجموعة tasks بـ task definition واحدة جوه نفس الـ service (`PRIMARY` / `ACTIVE`) — بتظهر مع CODE_DEPLOY (و EXTERNAL) بس |
| Target group pair | TG1 = اللي الـ service بدأ عليه (blue)، TG2 = اللي الـ replacement بيتسجّل فيه. بعد كل deploy بيتبادلوا |
| Production listener | الـ listener اللي CodeDeploy بيغيّر الـ **default action** بتاعه (عندنا HTTP:80) |
| Test listener | listener تاني (مثلاً :8080) بيوصل للـ green قبل production — **مش متظبط في الـ lab** |
| AppSpec | YAML بيقول لـ CodeDeploy: أنهي task definition، أنهي container/port يتربط بالـ LB، و hooks |
| Deployment config | شكل تحويل الـ traffic: all-at-once / canary / linear |
| `deployment_ready_option` | `CONTINUE_DEPLOYMENT` = حوّل أول ما green يبقى healthy · `STOP_DEPLOYMENT` + wait = استنى إنسان (`continue-deployment`) |
| Termination wait | دقايق الـ blue بيفضل شغال بعد 100% على green = نافذة الـ instant rollback |
| Auto rollback | `DEPLOYMENT_FAILURE` و/أو `DEPLOYMENT_STOP_ON_ALARM` |

### الـ deployment configs الجاهزة لـ ECS

| Config | التحويل | الوقت لـ 100% |
|---|---|---|
| `CodeDeployDefault.ECSAllAtOnce` | 0 → 100% مرة واحدة (blue/green صافي) | فوري |
| `CodeDeployDefault.ECSCanary10Percent5Minutes` | 10% → بعد 5 دقايق 100% | 5 دقايق |
| `CodeDeployDefault.ECSCanary10Percent15Minutes` | 10% → بعد 15 دقيقة 100% | 15 دقيقة |
| `CodeDeployDefault.ECSLinear10PercentEvery1Minutes` | +10% كل دقيقة | ~10 دقايق |
| `CodeDeployDefault.ECSLinear10PercentEvery3Minutes` | +10% كل 3 دقايق | ~30 دقيقة |
| Custom | `aws deploy create-deployment-config --compute-platform ECS --traffic-routing-config ...` (`TimeBasedCanary` / `TimeBasedLinear`) | اللي تحدده |

> 💡 **قاعدة Senior للـ canary:** نافذة الـ canary لازم تبقى **أطول** من وقت الكشف بتاع الـ alarm. الـ alarm بتاعنا (`student-app-lab-alb-5xx-ratio`) على period 5 دقايق × 1 datapoint، و `ECSCanary10Percent5Minutes` نافذته 5 دقايق → سباق: ممكن الـ traffic يتحوّل 100% قبل ما الـ alarm يلحق. للـ canary الحقيقي: `ECSCanary10Percent15Minutes` أو alarm أسرع (period 60s).

**Blast radius بالأرقام:** canary 10% و release بيرجّع 500 على 50% من الصفحات → الـ ratio الكلي ≈ 5% > threshold 1% → الـ alarm هيفجّر. ولو الـ error rate 5% بس → 0.5% كلي < 1% → **مش هيتكشف** في مرحلة الـ canary. الـ threshold والنسبة لازم يتحسبوا مع بعض.

## 2) المعمارية (Architecture)

```text
                      ALB listener HTTP:80  (default action ملك CodeDeploy — weights_managed_externally = true)
                       │  forward: TG blue 100 / TG green 0   ──►  canary: 90/10  ──►  0/100
          ┌────────────┴─────────────┐
   TG student-app-lab-blue      TG student-app-lab-green
          │                              │
  ┌───────┴──────────┐          ┌────────┴──────────┐
  │ original task set│          │ replacement task  │   ◄── CodeDeploy deployment (appspec: TaskDefinition,
  │ (rev N, PRIMARY) │          │ set (rev N+1)     │        ContainerName app, ContainerPort 8080)
  └──────────────────┘          └───────────────────┘
          ▲ بعد الـ termination wait (bake_time_in_minutes = 5) يتقفل

 CodeDeploy app/DG: student-app-lab-ecs · role student-app-lab-ecs-codedeploy (AWSCodeDeployRoleForECS)
 auto rollback: DEPLOYMENT_FAILURE (+ DEPLOYMENT_STOP_ON_ALARM لو use_deployment_alarms = true → alb-5xx-ratio)
 lifecycle events: BeforeInstall → Install → AfterInstall → AllowTestTraffic → AfterAllowTestTraffic
                   → BeforeAllowTraffic → AllowTraffic → AfterAllowTraffic   (hooks = Lambda، اختيارية)
```

## 3) المتطلبات (Prerequisites)

- [ ] stack 50 شغال ([51](51-ecs-fargate-terraform.md)) و **إنت فاهم إن التحويل لـ CODE_DEPLOY = `-replace` للـ service (downtime دقيقة-اتنين)**.
- [ ] `image_tag` في `terraform.tfvars` = الـ SHA الشغال حالياً (عشان الـ service الجديد ميرجعش لـ image قديمة).
- [ ] `AWS_DEPLOY_ROLE_ARN` (الـ bootstrap deploy role عنده `codedeploy:*Deployment*` على `student-app-*`).
- الأدوات: `terraform`، `aws`، `jq`، `gh`، `k6`.

## 4) الطريقة الأولى: AWS Console (يدوي)

> الـ deployment controller بيتحدد **وقت إنشاء الـ service بس**. هنعمل الـ service بـ Terraform (§5) ونستخدم الـ console للـ CodeDeploy نفسه — أو اعمل الاتنين يدوي لو بتعيد بناء [50](50-ecs-fargate-console.md) (§4.3).

### 4.1 اتفرّج على اللي Terraform عمله

**CodeDeploy → Applications → `student-app-lab-ecs`** (Compute platform: Amazon ECS) → **Deployment groups → `student-app-lab-ecs`**:

| الحقل | القيمة | من فين |
|---|---|---|
| Service role | `student-app-lab-ecs-codedeploy` | `aws_iam_role.this` + `AWSCodeDeployRoleForECS` |
| ECS cluster / service | `student-app-lab` / `student-app-lab-app` | |
| Load balancer · Production listener port | `student-app-lab-alb` · HTTP:80 | `prod_listener_arns` |
| Test listener port | (فاضي) | الـ stack مش بيمرر `test_listener_arns` |
| Target group 1 / 2 | `student-app-lab-blue` / `student-app-lab-green` | الترتيب مهم: الأول = اللي الـ service بدأ عليه |
| Traffic rerouting | Reroute traffic immediately | `ready_wait_time_in_minutes = 0` → `CONTINUE_DEPLOYMENT` |
| Deployment configuration | حسب `codedeploy_deployment_config_name` | |
| Original revision termination | 5 minutes | `termination_wait_time_in_minutes = var.bake_time_in_minutes` |
| Rollbacks / Alarms | Roll back when a deployment fails (+ when alarm thresholds are met) | `auto_rollback_configuration` / `alarm_configuration` |

### 4.2 Deploy من الـ CodeDeploy console

1. سجّل revision جديدة (الـ CLI أسهل: `render-taskdef.sh live` + `register-task-definition` — §6.2) وشغّل الـ migrations.
2. **Deployment group → Create deployment** → Revision type: **Use AppSpec editor** → Language: **YAML** → الصق [`appspec.yaml`](../../../deploy/ecs/appspec.yaml) بعد ما تبدّل `<TASK_DEFINITION>` بالـ ARN الجديد.
3. Deployment group overrides (اختياري): تقدر تختار deployment config تاني لـ deployment ده بس (مثلاً `ECSLinear10PercentEvery1Minutes`).
4. **Create deployment** → صفحة الـ deployment: **Deployment status** (Step 1 Deploying replacement task set → Step 2 Test traffic route setup → Step 3 Rerouting production traffic → Step 4 Wait → Step 5 Terminate original task set) و **Traffic shifting progress** (Original / Replacement %).
5. أزرار مهمة وهو شغال: **Stop and roll back deployment**، و (بعد 100%) **Terminate original task set** لو عايز تقصّر الـ wait.

### 4.3 (اختياري) بناء الـ deployment group يدوي

**CodeDeploy → Applications → Create application** (Compute platform: **Amazon ECS**) → **Create deployment group**: Service role بـ `AWSCodeDeployRoleForECS` · Environment configuration: الـ cluster والـ service (لازم يكون اتعمل بـ deployment controller CodeDeploy) · Load balancers: الـ ALB، Production listener port HTTP:80، Target group 1 `student-app-lab-blue`، Target group 2 `student-app-lab-green` · Deployment settings: Reroute traffic immediately، Deployment configuration، Original revision termination 5 min · Advanced → Rollbacks + Alarms.

## 5) الطريقة التانية: Infrastructure as Code (Terraform)

### 5.1 التحويل لـ CODE_DEPLOY

```bash
cd infra/terraform/stacks/50-ecs-fargate
# terraform.tfvars:  image_tag = "<SHA7 الشغال حالياً>"
terraform plan -out=tfplan \
  -var deployment_controller=CODE_DEPLOY \
  -var codedeploy_deployment_config_name=CodeDeployDefault.ECSCanary10Percent5Minutes \
  -var use_deployment_alarms=true \
  -replace=module.ecs.aws_ecs_service.app
terraform apply tfplan
terraform output -raw codedeploy_app_name; terraform output -raw codedeploy_deployment_group_name
```

(الأحسن تحط الـ 3 vars في `terraform.tfvars` بدل `-var` عشان أي `plan` جاي ميرجّعش ECS.)

**اقرا الـ plan كويس — هتلاقي:**

| التغيير | ليه |
|---|---|
| `module.ecs.aws_ecs_service.app` **must be replaced** | `-replace` (الـ controller بيتحدد عند الإنشاء) |
| `module.alb.aws_lb_listener.http[0]` destroy + `http_external[0]` create | `weights_managed_externally = true` بيختار variant الـ listener اللي فيه `ignore_changes = [default_action]` (Terraform مينفعش يعمل `ignore_changes` شرطي، فالـ module عامل resourceين بـ `count`). يعني الـ listener نفسه بيتمسح ويتعمل (ثواني من غير listener على :80) |
| `module.codedeploy[0].*` create | app + DG + role |
| الـ service: من غير min/max، circuit breaker، alarms، `deployment_configuration`؛ `availability_zone_rebalancing = DISABLED` | كلها `local.ecs_controller ? ... : null` — CodeDeploy عنده rollback وتحكم خاص بيه، والـ AZ rebalancing مش مدعوم مع CODE_DEPLOY |
| `module.ecs.aws_appautoscaling_policy.requests` destroy | `ALBRequestCountPerTarget` متثبت على TG واحد؛ مع blue/green الـ tasks بتتنقل بين الـ TGs |

> 💡 **(اختياري، Senior) تتجنب إعادة إنشاء الـ listener:** الـ config بتاع `http` و `http_external` متطابق (من غير stickiness)، فتقدر تنقل الـ state قبل الـ plan:
> ```bash
> terraform state mv 'module.alb.aws_lb_listener.http[0]' 'module.alb.aws_lb_listener.http_external[0]'
> ```
> الـ plan بعدها مش هيلمس الـ listener. ولما ترجع لـ ECS، اعمل الـ `mv` العكسي. (Terraform 1.x كمان بيدعم `moved {}` blocks لنفس الغرض جوه الـ code.)

### 5.2 جوه [`modules/codedeploy`](../../../infra/terraform/modules/codedeploy/main.tf) (`compute_platform = "ECS"`)

```hcl
deployment_style { deployment_option = "WITH_TRAFFIC_CONTROL"  deployment_type = "BLUE_GREEN" }
blue_green_deployment_config {
  deployment_ready_option { action_on_timeout = "CONTINUE_DEPLOYMENT" }        # ready_wait_time_in_minutes = 0
  terminate_blue_instances_on_deployment_success { action = "TERMINATE"  termination_wait_time_in_minutes = 5 }
}
auto_rollback_configuration { enabled = true  events = ["DEPLOYMENT_FAILURE", "DEPLOYMENT_STOP_ON_ALARM"] }
alarm_configuration { alarms = ["student-app-lab-alb-5xx-ratio"] }               # لو use_deployment_alarms
load_balancer_info { target_group_pair_info {
  prod_traffic_route { listener_arns = [<listener HTTP:80>] }
  target_group { name = "student-app-lab-blue" }   target_group { name = "student-app-lab-green" }
} }
```

- `rollback_events` بيشيل `DEPLOYMENT_STOP_ON_ALARM` أوتوماتيك لو مفيش alarms (event من غير alarm ملوش معنى).
- عايز human gate بعد ما green يبقى جاهز؟ `ready_wait_time_in_minutes > 0` → `STOP_DEPLOYMENT` → `aws deploy continue-deployment --deployment-id <id>` (الـ stack مش بيعرّضه — عدّل الـ module call).

### 5.3 الـ AppSpec ([`deploy/ecs/appspec.yaml`](../../../deploy/ecs/appspec.yaml))

```yaml
version: 0.0
Resources:
  - TargetService:
      Type: AWS::ECS::Service
      Properties:
        TaskDefinition: <TASK_DEFINITION>   # يتبدّل بـ ARN الـ revision (GitHub action / CodePipeline)
        LoadBalancerInfo:
          ContainerName: app
          ContainerPort: 8080
        PlatformVersion: LATEST
# Hooks (Lambda) متعلّقة: BeforeInstall / AfterInstall / AfterAllowTestTraffic / BeforeAllowTraffic / AfterAllowTraffic
```

- الـ replacement task set بياخد الـ network configuration بتاعة الـ service، ومن غير `CapacityProviderStrategy` في الـ appspec بياخد **الـ cluster default strategy** (= نفس استراتيجية الـ service من Terraform: FARGATE base 1 + Spot).
- `AfterAllowTestTraffic` هو المكان الكلاسيكي لـ smoke test على الـ test listener — محتاج `test_listener_arns` في الـ module + listener تاني على الـ ALB (مش موجود في الـ lab).

### 5.4 ⚠️ الـ Drift: الـ listener بقى ملك CodeDeploy

- بعد أي deployment ناجح الـ live ممكن يبقى **green**. الـ listener (`http_external`) عامل `ignore_changes = [default_action]` → `terraform apply` **مش هيرجّع الـ traffic لـ blue**، ومفيش أي تعديل يدوي لـ `blue_weight`/`green_weight` (قبل `weights_managed_externally` كان لازم). ده نفس الـ caveat المكتوب في [`modules/codedeploy/README.md`](../../../infra/terraform/modules/codedeploy/README.md)، ومعاه التمن: تبديل عائلة الـ controller بيعيد إنشاء الـ listener (§5.1).
- الـ service `load_balancer` متجاهل → Terraform مش هيحاول يرجّعه لـ blue.
- `aws ecs update-service --task-definition ...` على service بـ CODE_DEPLOY **مرفوض** (`Unable to update task definition on services with a CODE_DEPLOY deployment controller`). أي release لازم يعدّي من CodeDeploy.
- تعديلات env/secrets في Terraform بتوصل مع الـ CodeDeploy deployment الجاي (`taskdef_source=live`).

## 6) الـ Deploy

### 6.1 بـ `deploy-ecs.yml strategy=codedeploy`

```bash
terraform -chdir=infra/terraform/stacks/50-ecs-fargate output -json github_repository_variables | jq
gh variable set ECS_CODEDEPLOY_APPLICATION --body student-app-lab-ecs
gh variable set ECS_CODEDEPLOY_DEPLOYMENT_GROUP --body student-app-lab-ecs
gh workflow run deploy-ecs.yml --ref master -f strategy=codedeploy -f taskdef_source=live
gh run watch
```

الـ workflow بيتأكد إن الـ controller = `CODE_DEPLOY` (غير كده يقف)، يعمل render + register + migrations (`run_migrations`، default `true`)، وبعدين `amazon-ecs-deploy-task-definition` بـ `codedeploy-appspec: deploy/ecs/appspec.yaml` و `codedeploy-application/deployment-group` و `wait-for-minutes: 45`، ويحط الـ deployment ID في الـ job summary.

### 6.2 بالـ CLI (اللي الـ action بيعمله)

```bash
export AWS_REGION=us-east-1 ECS_CLUSTER=student-app-lab ECS_SERVICE=student-app-lab-app
IMG=<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/student-app:<SHA7>
bash deploy/ecs/render-taskdef.sh live student-app-lab-app "$IMG" > td.json
TD_ARN=$(aws ecs register-task-definition --cli-input-json file://td.json --query taskDefinition.taskDefinitionArn --output text)
bash deploy/ecs/run-migrations.sh --task-definition "$TD_ARN"          # بيقرا الشبكة من الـ PRIMARY task set
APPSPEC=$(sed "s|<TASK_DEFINITION>|$TD_ARN|" deploy/ecs/appspec.yaml)
DEP=$(aws deploy create-deployment --application-name student-app-lab-ecs --deployment-group-name student-app-lab-ecs \
  --revision "$(jq -n --arg c "$APPSPEC" '{revisionType:"AppSpecContent",appSpecContent:{content:$c}}')" \
  --description "manual <SHA7>" --query deploymentId --output text)
aws deploy wait deployment-successful --deployment-id "$DEP"
```

### 6.3 راقب التحويل

```bash
URL=$(terraform -chdir=infra/terraform/stacks/50-ecs-fargate output -raw app_url)
k6 run -e BASE_URL="$URL" -e DURATION=12m -e EXPECT_VERSIONS=<OLD_SHA7>,<NEW_SHA7> loadtest/k6/canary-watch.js
# في terminal تاني:
L=$(terraform -chdir=infra/terraform/stacks/50-ecs-fargate output -raw listener_arn)
while :; do
  aws elbv2 describe-listeners --listener-arns "$L" \
    --query 'Listeners[0].DefaultActions[0].ForwardConfig.TargetGroups[].[TargetGroupArn,Weight]' --output text | sed 's|.*targetgroup/||'
  aws deploy get-deployment --deployment-id "$DEP" --query 'deploymentInfo.[status,deploymentOverview]' --output text
  sleep 20
done
```

مع `ECSCanary10Percent5Minutes`: weights `100/0` → `90/10` (~5 دقايق، و k6 يوري ~10% للـ version الجديدة) → `0/100` → Wait 5 دقايق → الـ original task set يتقفل.

## 7) التحقق (Verify)

```bash
aws deploy list-deployments --application-name student-app-lab-ecs --deployment-group-name student-app-lab-ecs --max-items 3
aws deploy get-deployment --deployment-id "$DEP" --query 'deploymentInfo.{status:status,config:deploymentConfigName,rollback:rollbackInfo,err:errorInformation}'
aws ecs describe-services --cluster student-app-lab --services student-app-lab-app \
  --query 'services[0].taskSets[].{status:status,td:taskDefinition,scale:scale.value,stable:stabilityStatus}'
curl -s "$URL/ready" | jq '{version,color}'
cd infra/terraform/stacks/50-ecs-fargate && terraform plan     # المفروض No changes حتى لو الـ live = green
```

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر | المتوقع |
|---|---|---|
| Canary سيء + alarm | traffic صفحات (`bash deploy/scripts/probe.sh "$URL/login" 1200 0.2`) + `gh workflow run deploy-ecs.yml -f strategy=codedeploy -f extra_env="SRE_FAULT_ERROR_RATE=0.5"` مع `ECSCanary10Percent15Minutes` | ~10% من الـ traffic → ~5% 5xx كلي → `alb-5xx-ratio` ALARM → `DEPLOYMENT_STOP_ON_ALARM` → الـ traffic يرجع 100% blue والـ replacement يتقفل. الـ errors اتحددت بـ 10% من المستخدمين |
| نفس الحاجة بـ canary 5 دقايق | `ECSCanary10Percent5Minutes` | سباق مع الـ alarm (5 دقايق period): غالباً يتحوّل 100% ثم يحصل rollback متأخر — قارن عدد الـ errors في `probe.sh` |
| Replacement unhealthy | `extra_env="SRE_FAULT_UNHEALTHY=true"` | الـ replacement task set مبيبقاش healthy في TG green → الـ deployment يفشل (timeout/health) → `DEPLOYMENT_FAILURE` rollback؛ الـ production مشافش حاجة (الـ traffic مااتحوّلش) |
| Boot fail | `-f run_migrations=false -f extra_env="SRE_FAULT_BOOT_FAIL=true"` (مع `run_migrations=true` بيقف عند الـ migrations قبل CodeDeploy — [53 §8.1](53-ecs-rolling-circuit-breaker.md)) | الـ replacement task set مبيوصلش steady (tasks بتقع بـ exit 1) → الـ deployment يفشل (ممكن ياخد وقت لحد ما CodeDeploy يستسلم — **مفيش circuit breaker** مع CODE_DEPLOY) → `DEPLOYMENT_FAILURE` rollback؛ الـ production مشافش حاجة |
| update-service مباشرة | `aws ecs update-service --cluster student-app-lab --service student-app-lab-app --task-definition "$TD_ARN"` | `InvalidParameterException: Unable to update task definition on services with a CODE_DEPLOY deployment controller` |
| Rollback يدوي في الـ wait | بعد 100% وقبل ما الـ 5 دقايق يخلصوا: `aws deploy stop-deployment --deployment-id "$DEP" --auto-rollback-enabled` | الـ traffic يرجع للـ original task set فوراً (لسه شغال) |

مفيش تنضيف بعد الـ drills: `render-taskdef.sh live` بيشيل أي `SRE_FAULT_*` من الـ copy (GitHub `live`، و CodePipeline `taskdef_source=live` اللي بيستخدم نفس الـ script بـ `'<IMAGE1_NAME>'`)، فالـ deploy الجاي نضيف ([53 §8.1](53-ecs-rolling-circuit-breaker.md)).

## 9) الرجوع (Rollback)

- **أثناء الـ deployment:** `aws deploy stop-deployment --deployment-id <id> --auto-rollback-enabled` (أو زرار **Stop and roll back deployment**).
- **أوتوماتيك:** `DEPLOYMENT_FAILURE` أو alarm → CodeDeploy يرجّع الـ listener للـ original task set.
- **بعد ما الـ original اتقفل:** مفيش instant rollback — اعمل CodeDeploy deployment جديد بالـ revision القديمة (re-run الـ workflow بـ `image_tag` القديم). ده سبب إن الـ termination wait مهم.

## 10) المسح (Teardown) ⚠️

ارجع لـ ECS controller (أو destroy على طول):

```bash
cd infra/terraform/stacks/50-ecs-fargate
# (لو عملت state mv في 5.1: اعمل العكسي الأول)
# terraform state mv 'module.alb.aws_lb_listener.http_external[0]' 'module.alb.aws_lb_listener.http[0]'
terraform apply -var deployment_controller=ECS -replace=module.ecs.aws_ecs_service.app
```

الـ listener هيرجع Terraform-managed (blue 100 / green 0) حتى لو CodeDeploy كان سايبه على green، والـ service الجديد بيتسجّل في blue. لو هتعمل destroy: stack 36 الأول ثم stack 50 ([51 §10](51-ecs-fargate-terraform.md)).

## 11) التكلفة (Cost)

| Resource | السعر التقريبي (تقريبي — راجع صفحة الأسعار) |
|---|---|
| CodeDeploy لـ ECS | مجاني |
| الـ replacement task set | +100% tasks من بداية الـ deploy لحد آخر الـ termination wait (canary 15 دقيقة + wait 5 ≈ 20 دقيقة × 2 tasks ≈ سنتين) |
| CloudWatch alarm | ~$0.10/alarm/شهر (الـ metric math alarms ممكن أكتر) |

## 12) أسئلة Interview

<details><summary>اشرح CodeDeploy blue/green لـ ECS من أول `create-deployment` لحد ما الـ blue يتقفل.</summary>

CodeDeploy بيعمل replacement task set بالـ task definition اللي في الـ appspec ويسجّله في الـ TG التاني (BeforeInstall/Install/AfterInstall) → لو فيه test listener يوجّهه للـ green (AllowTestTraffic/AfterAllowTestTraffic) → يحوّل الـ production listener حسب الـ config (BeforeAllowTraffic/AllowTraffic/AfterAllowTraffic) → يراقب الـ alarms → بعد الـ termination wait يقفل الـ original task set ويخلي الـ replacement primary. أي فشل أو alarm (لو مفعّل) → يرجّع الـ listener ويقفل الـ replacement.

</details>

<details><summary>CodeDeploy canary مقابل ALB weighted TGs بإيدك (سيناريو 46)؟</summary>

نفس الآلية تحت (weighted forward على الـ listener)، بس CodeDeploy بيدير الـ state machine: الخطوات، الـ alarms، الـ rollback، الـ hooks، وسجل deployments. اليدوي مرن أكتر (أي نسب، أي gate منطق) بس إنت اللي بتكتب الـ orchestration والـ rollback وبتتعامل مع الـ drift.

</details>

<details><summary>ليه `weights_managed_externally` لازم يبقى `true` مع CODE_DEPLOY؟</summary>

لأن CodeDeploy بيكتب الـ default action بتاع الـ listener بعد كل deploy (ممكن يسيبه على green). لو Terraform مالك الـ default action، أول `apply` هيرجّعه blue 100 — يعني الـ traffic يروح لـ task set اتقفل أو قديم = outage أو rollback صامت. الحل `ignore_changes = [default_action]`؛ ولأن `ignore_changes` مينفعش يبقى شرطي، الـ module فيه listenerين بـ `count`.

</details>

<details><summary>إيه عيوب CODE_DEPLOY controller على ECS؟</summary>

مفيش circuit breaker (CodeDeploy بيعمل بديله)، مفيش `update-service --task-definition` (كل حاجة عن طريق CodeDeploy)، الـ AZ rebalancing مش مدعوم، تغيير الـ controller = service جديد، drift في الـ listener، وتعقيد أكتر (app + DG + role + appspec). الميزة: hooks ناضجة، test listener، deployment configs جاهزة، وتكامل CodePipeline `CodeDeployToECS`. ECS native ([55](55-ecs-native-bluegreen-linear-canary.md)) بقى بيغطي أغلب ده من غير CodeDeploy.

</details>

<details><summary>إزاي تختار threshold الـ alarm مع نسبة الـ canary؟</summary>

الـ alarm على الـ ALB كله بيشوف `canary% × error_rate_canary + (1−canary%) × baseline`. مع canary 10% و threshold 1%، الـ canary لازم يرجّع >~10% errors عشان يتكشف. للكشف الدقيق: alarm على الـ target group بتاع الـ canary لوحده (`HTTPCode_Target_5XX_Count` بـ dimension الـ TG)، أو مقارنة canary vs baseline، ونافذة canary أطول من evaluation period الـ alarm.

</details>

<details><summary>الـ termination wait = 5 دقايق. ليه مش صفر وليه مش ساعة؟</summary>

صفر = مفيش instant rollback بعد 100% (أي bug يظهر بعد التحويل = deploy جديد). ساعة = capacity مضاعفة ساعة كل release + deployments بتتراكم (CodeDeploy مش بيبدأ deployment جديد لنفس الـ DG وفيه واحد شغال). الرقم = الوقت اللي الـ signals بتاعتك (alarms، burn rate، business metrics) محتاجاه عشان تقول "سليم".

</details>

## 13) Checklist

- [ ] حوّلت الـ service لـ CODE_DEPLOY وقريت الـ plan (service replace، listener variant، autoscaling)
- [ ] فاهم الـ appspec وفين الـ hooks
- [ ] عملت deploy من `deploy-ecs.yml` ومن الـ CodeDeploy console
- [ ] راقبت الـ weights والـ versions أثناء canary بـ k6
- [ ] جرّبت rollback بالـ alarm و `stop-deployment`
- [ ] أثبتت إن `terraform plan` = No changes والـ live على green
- [ ] رجعت لـ ECS controller أو عملت destroy
