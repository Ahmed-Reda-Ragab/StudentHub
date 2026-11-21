# 55 — ECS native blue/green و linear و canary

> **الهدف في سطر:** تستخدم الـ blue/green المدمج في ECS (يوليو 2025) والـ linear/canary (أكتوبر 2025) من غير CodeDeploy: تفهم إزاي الـ module بيظبطه (`deployment_configuration.strategy`، `bake_time_in_minutes`، `load_balancer.advanced_configuration` بالـ alternate TG والـ production/test listener rules والـ infrastructure role، وheader الـ test traffic `X-Lab-Target: green`)، تقارنه بـ CodeDeploy في جدول، وتعمل deploy من الـ console ومن `deploy-ecs.yml strategy=native`.
> **المستوى:** Advanced · **الوقت:** ~4 ساعات · **التكلفة التقريبية:** نفس [51](51-ecs-fargate-terraform.md) + capacity مضاعفة وقت الـ deploy
> **بيعتمد على:** [51](51-ecs-fargate-terraform.md) · [53](53-ecs-rolling-circuit-breaker.md) · [54](54-ecs-codedeploy-bluegreen-canary.md) · **الملفات في الـ repo:** [`modules/ecs-fargate/service.tf`](../../../infra/terraform/modules/ecs-fargate/service.tf) · [`modules/ecs-fargate/iam.tf`](../../../infra/terraform/modules/ecs-fargate/iam.tf) · [`modules/ecs-fargate/variables.tf`](../../../infra/terraform/modules/ecs-fargate/variables.tf) · [`modules/alb/main.tf`](../../../infra/terraform/modules/alb/main.tf) · [`stacks/50-ecs-fargate/variables.tf`](../../../infra/terraform/stacks/50-ecs-fargate/variables.tf) · [`.github/workflows/deploy-ecs.yml`](../../../.github/workflows/deploy-ecs.yml) · [`loadtest/k6/canary-watch.js`](../../../loadtest/k6/canary-watch.js)

## 1) الفكرة (Concepts)

ECS بقى يعمل traffic shifting بنفسه مع **ECS controller** عادي: بيقوّم الـ green revision (100% من الـ desired) على الـ **alternate target group**، يوجّه **test traffic** ليه، يحوّل الـ **production traffic** على **listener rule** (مش الـ default action)، يستنى **bake time** والـ blue لسه شغال، وبعدين ينضّف. الـ rollback = يرجّع الـ weights للـ blue اللي لسه موجود.

| Strategy | التحويل | البارامترات (حدود AWS) |
|---|---|---|
| `BLUE_GREEN` | 0 → 100% مرة واحدة | `bakeTimeInMinutes` |
| `LINEAR` | خطوات متساوية | `stepPercent` (3.0–100.0)، `stepBakeTimeInMinutes` (0–1440) + `bakeTimeInMinutes` |
| `CANARY` | نسبة صغيرة ثم الباقي مرة واحدة | `canaryPercent`، `canaryBakeTimeInMinutes` + `bakeTimeInMinutes` |

### الـ lifecycle stages (بالترتيب)

| Stage | بيحصل إيه | Hook؟ |
|---|---|---|
| `RECONCILE_SERVICE` | لو فيه أكتر من service revision ACTIVE | ✅ |
| `PRE_SCALE_UP` | blue = 100% production، الـ green مبدأش | ✅ |
| `SCALE_UP` | الـ green يقوم لـ 100% من الـ desired، مفيش traffic | ❌ |
| `POST_SCALE_UP` | الـ green شغال، مفيش traffic | ✅ |
| `TEST_TRAFFIC_SHIFT` | الـ test rule يتحوّل للـ green (production لسه blue) | ✅ (Lambda بس) |
| `POST_TEST_TRAFFIC_SHIFT` | الـ green واخد 100% من الـ test traffic | ✅ |
| `PRE_PRODUCTION_TRAFFIC_SHIFT` | قبل كل خطوة production (مرة في B/G، كل خطوة في linear/canary) | ✅ |
| `PRODUCTION_TRAFFIC_SHIFT` | الـ weights بتتحرك للـ green | ✅ (Lambda بس) |
| `POST_PRODUCTION_TRAFFIC_SHIFT` | الـ green = 100% | ✅ |
| `BAKE_TIME` | الاتنين شغالين؛ الـ alarms متراقبة؛ instant rollback متاح | ❌ |
| `CLEAN_UP` | الـ blue ينزل لـ 0؛ الـ green بقى الـ production | ❌ |

الـ hooks نوعين: **Lambda** (ترجع `SUCCEEDED`/`FAILED`/`IN_PROGRESS` خلال 15 دقيقة، مع `callBackDelaySeconds`) و **Pause** (الـ deployment يقف لحد `ContinueServiceDeployment`، timeout لحد 14 يوم). كل stage حده 24 ساعة. **الـ module بتاعنا مش بيظبط أي hooks.**

| المصطلح | المعنى |
|---|---|
| Alternate target group | الـ TG اللي الـ green بيتسجّل فيه (`green` عندنا) — بعد النجاح بيبقى هو الـ primary |
| Production listener rule | الـ rule اللي ECS بيغيّر weights الـ forward بتاعه (priority 100، `/*`) |
| Test listener rule | rule بـ condition (header) بيوصل للـ green بدري (priority 90، `X-Lab-Target: green`) |
| Infrastructure role | role بيـ assume ـه `ecs.amazonaws.com` عشان يعدّل الـ ALB rules: `AmazonECSInfrastructureRolePolicyForLoadBalancers` |

## 2) المعمارية (Architecture)

```text
 ALB listener HTTP:80   (الـ default action: blue 100 — Terraform-managed، عملياً مش بيتوصل له)
  ├─ rule p1   /metrics, /metrics/*            → fixed 404                      (modules/alb)
  ├─ rule p90  header X-Lab-Target = green     → forward blue 100 / green 0     (test rule — ECS يحوّله وقت TEST_TRAFFIC_SHIFT)
  └─ rule p100 path /*                          → forward blue 100 / green 0     (production rule — ECS يحرّك الـ weights)
                     │                                   │
           TG student-app-lab-blue              TG student-app-lab-green (alternate)
           blue revision (N)                    green revision (N+1) — 100% desired من SCALE_UP

 CANARY (canary_percent 10، canary bake 5m)      LINEAR (step 25%، step bake 2m)
   p100: 100/0 → 90/10 ─5m─► 0/100                p100: 100/0 → 75/25 ─2m─► 50/50 ─2m─► 25/75 ─2m─► 0/100
   ثم BAKE_TIME 5m (blue لسه شغال) → CLEAN_UP     ثم BAKE_TIME 5m → CLEAN_UP

 ECS assumes role student-app-lab-ecs-infrastructure  ──► elasticloadbalancing:ModifyRule ...
 alarms (use_deployment_alarms) + circuit breaker → rollback = الـ weights ترجع 100/0 والـ green ينزل
```

## 3) المتطلبات (Prerequisites)

- [ ] stack 50 شغال، و `image_tag` في الـ tfvars = الـ SHA الحالي (التحويل = `-replace`).
- [ ] AWS provider `~> 6.21` (LINEAR/CANARY في `deployment_configuration`) — موجود في [`versions.tf`](../../../infra/terraform/stacks/50-ecs-fargate/versions.tf).
- [ ] AWS CLI v2 حديث (الأوامر `list-service-deployments` / `describe-service-deployments` / `stop-service-deployment`).
- الأدوات: `terraform`، `aws`، `jq`، `gh`، `k6`، `curl`.

## 4) الطريقة الأولى: AWS Console (يدوي)

### 4.1 تجهيز الـ ALB (لو بتعمل كل حاجة يدوي على ستاك [50](50-ecs-fargate-console.md))

1. **Listener HTTP:80 → Add rule** `ecs-production`: Condition **Path** `/*` → Action **Forward to target groups**: `student-app-lab-blue` weight 100 + `student-app-lab-green` weight 0 → Priority **100**.
2. **Add rule** `ecs-test`: Condition **HTTP header** `X-Lab-Target` = `green` → نفس الـ forward (100/0) → Priority **90**.
3. **IAM → Create role** → AWS service → **Elastic Container Service** → use case الخاص بالـ infrastructure/load balancers (أو trust policy بـ `ecs.amazonaws.com` يدوي) → policy `AmazonECSInfrastructureRolePolicyForLoadBalancers` → اسم `student-app-lab-ecs-infrastructure`.

### 4.2 Service بـ native strategy

الـ strategy والـ advanced configuration بيتحددوا عند **Create service** (أو update لو الـ service مش متظبط على حاجة متعارضة). **Create service** (زي [50 §4.11](50-ecs-fargate-console.md)) مع الفروق دي:

| القسم | القيمة |
|---|---|
| Deployment options → Deployment strategy | **Blue/green** (أو **Linear** / **Canary**) |
| Bake time | 5 (دقايق) |
| Linear: step % / step bake time · Canary: canary % / canary bake time | 25 / 2 · 10 / 5 |
| Deployment lifecycle hooks | (اختياري) **Add** → Target type **Pause** → Lifecycle stages `POST_TEST_TRAFFIC_SHIFT` — عشان تلحق تختبر الـ green بالـ header وتعمل Continue بإيدك |
| Deployment failure detection | circuit breaker + rollback · (اختياري) CloudWatch alarm `student-app-lab-alb-5xx-ratio` + rollback |
| Load balancing | ALB موجود · Listener 80:HTTP · **Production rule** = `ecs-production` (priority 100) · **Test rule** = `ecs-test` (priority 90) · Target group `student-app-lab-blue` · **Alternate target group** `student-app-lab-green` · Role = `student-app-lab-ecs-infrastructure` |

> ⚠️ لو بتجرّب الـ Pause hook على service عمله Terraform: الـ `apply` الجاي هيشيله (الـ module مفيهوش hooks في `deployment_configuration`). اعتبره تجربة console، أو ضيفه في الـ module.

### 4.3 Deploy وراقب من الـ console

Update service بـ revision جديدة (بعد الـ migration) → تاب **Deployments** → الـ service deployment الجديد بيوري **Lifecycle stage** الحالي (`SCALE_UP` → `TEST_TRAFFIC_SHIFT` → ... → `BAKE_TIME` → `CLEAN_UP`) ونسب الـ traffic. وفي **EC2 → Listeners → HTTP:80 → Rules** شوف الـ weights في rule priority 100 بتتغير.

## 5) الطريقة التانية: Infrastructure as Code (Terraform)

### 5.1 التحويل

```bash
cd infra/terraform/stacks/50-ecs-fargate
# terraform.tfvars:
#   image_tag             = "<SHA7 الحالي>"
#   deployment_strategy   = "CANARY"     # BLUE_GREEN | LINEAR | CANARY
#   bake_time_in_minutes  = 5
#   canary_percent        = 10
#   linear_step_percent   = 25
#   use_deployment_alarms = true
terraform plan -out=tfplan -replace=module.ecs.aws_ecs_service.app
terraform apply tfplan
terraform output deployment      # production_rule / test_rule ARNs + strategy + alarms
```

بين `BLUE_GREEN` ⇄ `LINEAR` ⇄ `CANARY` (كلهم traffic shifting) الـ `load_balancer` مش بيتغير، فالتغيير in-place على `deployment_configuration` عادةً كفاية؛ الـ `-replace` لازم لما تعدّي الحدود بين ROLLING والـ traffic-shifting أو ECS ⇄ CODE_DEPLOY ([51 §5.3](51-ecs-fargate-terraform.md)).

### 5.2 اللي الـ module بيعمله (`local.traffic_shifting = ecs_controller && strategy != "ROLLING"`)

```hcl
# service.tf — listener rules على var.listener_arn (اللي الـ ALB module بيطلّعه)
resource "aws_lb_listener_rule" "production" {           # priority 100، path /*
  action { forward { target_group { blue, weight 100 }  target_group { green, weight 0 } } }
  lifecycle { ignore_changes = [action] }                 # ECS يملك الـ weights
}
resource "aws_lb_listener_rule" "test" {                 # priority 90، header X-Lab-Target: green
  count = traffic_shifting && var.enable_test_listener_rule ? 1 : 0
  lifecycle { ignore_changes = [action] }
}

resource "aws_ecs_service" "app" {
  load_balancer {
    target_group_arn = blue
    advanced_configuration {
      alternate_target_group_arn = green
      production_listener_rule   = aws_lb_listener_rule.production[0].arn
      test_listener_rule         = aws_lb_listener_rule.test[0].arn
      role_arn                   = aws_iam_role.infrastructure[0].arn
    }
  }
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  deployment_circuit_breaker { enable = true  rollback = true }
  alarms { ... }                                           # لو use_deployment_alarms
  deployment_configuration {
    strategy             = var.deployment_strategy
    bake_time_in_minutes = var.bake_time_in_minutes       # 5
    canary_configuration { canary_percent = 10  canary_bake_time_in_minutes = 5 }   # CANARY بس
    linear_configuration { step_percent = 25  step_bake_time_in_minutes = 2 }      # LINEAR بس
  }
}
```

| تفصيلة | ليه |
|---|---|
| الـ traffic على **listener rule** مش الـ default action | ده تصميم ECS native: محتاج rule ARN. الـ default action (blue 100) بيفضل Terraform-managed (`weights_managed_externally = false`) ومحدش بيلمسه، والـ rule `/*` بيمسك كل الـ traffic قبله |
| priorities: 1 (`/metrics`) < 90 (test) < 100 (production) | الأقل بيتقيّم الأول: `/metrics` يتقفل دايماً، والـ header يكسب على الـ `/*` |
| `ignore_changes = [action]` على الـ rules | من غيرها كل `apply` بعد deploy يرجّع الـ weights لـ blue = outage |
| infrastructure role بـ `aws:SourceAccount` | confused-deputy guard لـ `ecs.amazonaws.com` |
| `ALBRequestCountPerTarget` بيتشال | الـ policy متثبتة على TG blue؛ بعد deploy الـ tasks ممكن تبقى في green → الـ metric يقيس TG فاضي. CPU scaling بس ([57](57-ecs-autoscaling-under-load.md)) |
| الـ circuit breaker والـ alarms شغالين | عكس CODE_DEPLOY — الـ ECS controller لسه هو صاحب الـ deployment |

> 💡 **Inputs مش متعرّضة في الـ stack:** `canary_bake_time_in_minutes` (5)، `linear_step_bake_time_in_minutes` (2)، `enable_test_listener_rule` (true)، والـ priorities (100/90). تغييرها = تعديل `module "ecs"` في [`main.tf`](../../../infra/terraform/stacks/50-ecs-fargate/main.tf).

### 5.3 CodeDeploy مقابل ECS native

| | CodeDeploy (`CODE_DEPLOY`، [54](54-ecs-codedeploy-bluegreen-canary.md)) | ECS native (`ECS` + strategy) |
|---|---|---|
| Resources | app + deployment group + service role + appspec | blocks جوه الـ service + infrastructure role + listener rules |
| بيحوّل إيه | الـ **listener default action** | **listener rule** (production) + rule للـ test |
| Test traffic | test **listener** (بورت تاني) | test **rule** على نفس الـ listener (header/path) |
| الاستراتيجيات | configs جاهزة (AllAtOnce/Canary10Percent5/15Minutes/Linear10PercentEvery1/3Minutes) + custom configs | `BLUE_GREEN` / `LINEAR` / `CANARY` بأرقامك مباشرة |
| Hooks | AppSpec Lambda hooks (5 events) | lifecycle hooks: Lambda أو **Pause** على stages أكتر (+ كل خطوة traffic في linear/canary) |
| Human gate | `deployment_ready_option = STOP` + `continue-deployment` | Pause hook + `ContinueServiceDeployment` |
| Circuit breaker | ❌ (CodeDeploy بيعمل rollback بطريقته) | ✅ |
| Alarm rollback | ✅ DG alarms | ✅ service `alarms` |
| `update-service --task-definition` | ❌ مرفوض | ✅ (هو اللي بيبدأ الـ deployment) |
| AZ rebalancing / features الـ service | محدودة | كاملة |
| Terraform drift | الـ default action ملك CodeDeploy (`weights_managed_externally`) | الـ rule actions متجاهلة؛ الـ default action Terraform |
| تغيير الاستراتيجية | `-replace` للتحويل من/لـ ECS | in-place بين B/G/LINEAR/CANARY؛ `-replace` من/لـ ROLLING |
| Pipelines | CodePipeline `CodeDeployToECS` (taskdef.json + appspec.yaml) | CodePipeline `ECS` action أو أي `update-service` |
| Rollback بعد ما الـ deployment يخلص | deployment جديد | deployment جديد (أو `update-service` بالـ revision القديمة) |
| التكلفة | مجاني | مجاني |
| إمتى | عندك hooks/CodePipeline موجودة، أو test listener منفصل، أو multi-platform CodeDeploy | الجديد الافتراضي: أبسط، أقل resources، circuit breaker، أقل drift |

## 6) الـ Deploy

### 6.1 بـ `deploy-ecs.yml strategy=native`

```bash
gh workflow run deploy-ecs.yml --ref master -f strategy=native -f taskdef_source=live
gh run watch
```

الـ workflow بيقرا `deploymentController.type` و `deploymentConfiguration.strategy`: لو `ROLLING` مع `native` → يقف (`set deployment_strategy = BLUE_GREEN | LINEAR | CANARY in stack 50`). الـ deploy step هو نفس `update-service` + `wait-for-service-stability` بـ `wait-for-minutes: 45` (test traffic + خطوات + bake). `strategy=rolling` على service native = warning بس، وECS هيعمل الـ native strategy برضه.

### 6.2 راقب الـ stages والـ weights

```bash
CL=student-app-lab SVC=student-app-lab-app
SD=$(aws ecs list-service-deployments --cluster $CL --service $SVC --query 'serviceDeployments[0].serviceDeploymentArn' --output text)
RULE=$(terraform -chdir=infra/terraform/stacks/50-ecs-fargate output -json deployment | jq -r .production_rule)
while :; do
  aws ecs describe-service-deployments --service-deployment-arns "$SD" \
    --query 'serviceDeployments[0].[status,lifecycleStage]' --output text
  aws elbv2 describe-rules --rule-arns "$RULE" \
    --query 'Rules[0].Actions[0].ForwardConfig.TargetGroups[].[TargetGroupArn,Weight]' --output text | sed 's|.*targetgroup/||'
  sleep 15
done
```

### 6.3 اختبر الـ green بالـ header قبل المستخدمين

```bash
URL=$(terraform -chdir=infra/terraform/stacks/50-ecs-fargate output -raw app_url)
while :; do
  printf 'prod=%s  test=%s\n' \
    "$(curl -s "$URL/ready" | jq -r .version)" \
    "$(curl -s -H 'X-Lab-Target: green' "$URL/ready" | jq -r .version)"
  sleep 2
done
```

من `TEST_TRAFFIC_SHIFT`: الـ `test` يطلّع الـ SHA الجديد والـ `prod` لسه القديم. **من غير Pause hook** النافذة دي ثواني (ECS بيكمّل لوحده)؛ مع Pause hook على `POST_TEST_TRAFFIC_SHIFT` (§4.2) تقدر تشغّل smoke/k6 على الـ green بالـ header، وبعدين تكمّل الـ deployment من الـ console أو بالـ API `ContinueServiceDeployment` (اتأكد من اسم الأمر المقابل في `aws ecs help` بتاع نسختك من الـ CLI).

### 6.4 k6 أثناء canary/linear

`DEPLOY_COLOR=stable` على كل الـ tasks في stack 50، فالـ split بالـ **version**:

```bash
k6 run -e BASE_URL="$URL" -e DURATION=15m -e EXPECT_VERSIONS=<OLD_SHA7>,<NEW_SHA7> loadtest/k6/canary-watch.js
# أثناء مرحلة الـ canary بس (نافذة 5 دقايق): اتأكد إن الـ ALB بيطبّق 10% فعلاً
k6 run -e BASE_URL="$URL" -e DURATION=3m -e CANARY_VERSION=<NEW_SHA7> -e EXPECT_CANARY_PCT=10 -e TOLERANCE_PCT=4 loadtest/k6/canary-watch.js
```

المفروض: `http_req_failed` = 0 طول الـ deployment، و `release_responses{version:...}` بيوري التحويل التدريجي.

## 7) التحقق (Verify)

```bash
terraform -chdir=infra/terraform/stacks/50-ecs-fargate output deployment
aws ecs describe-services --cluster student-app-lab --services student-app-lab-app \
  --query 'services[0].{strategy:deploymentConfiguration.strategy,bake:deploymentConfiguration.bakeTimeInMinutes,lb:loadBalancers[0]}'
aws ecs list-service-deployments --cluster student-app-lab --service student-app-lab-app \
  --query 'serviceDeployments[:3].[status,targetServiceRevisionArn]' --output table
terraform -chdir=infra/terraform/stacks/50-ecs-fargate plan     # No changes بعد deploy (الـ weights و load_balancer متجاهلين)
```

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر | المتوقع |
|---|---|---|
| Canary سيء + alarm | `use_deployment_alarms=true`، traffic صفحات (`probe.sh "$URL/login" 1200 0.2`)، `deploy-ecs.yml -f strategy=native -f extra_env="SRE_FAULT_ERROR_RATE=0.5"` | ~5% 5xx كلي → alarm → rollback: الـ weights ترجع 100/0 والـ green ينزل. لو الـ alarm اتأخر عن نافذة الـ canary، الـ rollback يحصل في `BAKE_TIME` (الـ blue لسه شغال) — قارن عدد الـ errors بـ [53 §8.3](53-ecs-rolling-circuit-breaker.md) |
| Green unhealthy | `extra_env="SRE_FAULT_UNHEALTHY=true"` | الـ green مبيعدّيش `SCALE_UP`/health → circuit breaker → rollback قبل أي production traffic |
| Green مش بيقوم | `-f run_migrations=false -f extra_env="SRE_FAULT_BOOT_FAIL=true"` | الـ green tasks بتقع بـ exit 1 في `SCALE_UP` → circuit breaker (3 failures) → rollback؛ الـ production rule عمره ما اتلمس |
| Rollback يدوي أثناء الـ bake | `aws ecs stop-service-deployment --service-deployment-arn "$SD" --stop-type ROLLBACK` | الـ weights ترجع للـ blue فوراً |
| `strategy=native` على ROLLING | `deploy-ecs.yml -f strategy=native` والـ service ROLLING | الـ workflow يقف: `service strategy is ROLLING; set deployment_strategy = ...` |
| `terraform apply` بعد deploy من غير ignore | (فكرياً) شيل `ignore_changes = [action]` | الـ apply يرجّع الـ rule لـ blue 100 والـ blue tasks اتقفلت → 503 لكل الناس. ده سبب الـ ignore |
| Test rule priority أكبر من الـ production | عدّل priority الـ test لـ 110 من الـ console | الـ header مبقاش بيوصل للـ green (الـ `/*` بيكسب) — drift Terraform هيرجّعه |

مفيش تنضيف بعد الـ drills: `render-taskdef.sh live` بيشيل `SRE_FAULT_*` من الـ copy، فالـ deploy الجاي نضيف (`KEEP_FAULT_ENV=true` لو قاصد تحتفظ بيها).

## 9) الرجوع (Rollback)

- **أثناء الـ deployment (لحد آخر `BAKE_TIME`):** `stop-service-deployment --stop-type ROLLBACK`، أو alarm/circuit breaker أوتوماتيك — instant لأن الـ blue لسه شغال.
- **بعد `CLEAN_UP`:** deployment جديد بالـ revision القديمة: `aws ecs update-service --cluster student-app-lab --service student-app-lab-app --task-definition student-app-lab-app:<GOOD_REV>` (وده نفسه هيمشي بالـ strategy: canary للـ rollback كمان!) أو re-run الـ workflow بالـ tag القديم.

## 10) المسح (Teardown) ⚠️

```bash
cd infra/terraform/stacks/50-ecs-fargate
# رجّع deployment_strategy = "ROLLING" في الـ tfvars
terraform apply -replace=module.ecs.aws_ecs_service.app     # الـ rules والـ infrastructure role يتمسحوا
```

أو `terraform destroy` على طول ([51 §10](51-ecs-fargate-terraform.md)). امسح أي rules/roles عملتهم يدوي في §4.1.

## 11) التكلفة (Cost)

| Resource | السعر التقريبي (تقريبي — راجع صفحة الأسعار) |
|---|---|
| ECS native deployments | مجاني |
| الـ green (100% desired) | من `SCALE_UP` لحد `CLEAN_UP`: canary ≈ 5 + 5 + دقايق boot ≈ 12–15 دقيقة × 2 tasks؛ linear (25%، 2 دقيقة) ≈ 6 + 5 + boot |
| Listener rules | ضمن الـ LCU (rule evaluations) — مهمل في الـ lab |

## 12) أسئلة Interview

<details><summary>إيه الفرق المعماري بين ECS native blue/green و CodeDeploy blue/green؟</summary>

CodeDeploy بيستخدم controller منفصل وtask sets، وبيعدّل الـ listener default action، وله appspec وhooks خاصة. ECS native بيفضل على الـ ECS controller، بيستخدم "service revisions"، بيحرّك weights على listener rule، وبيدعم test rule على نفس الـ listener، وlifecycle hooks (Lambda/Pause)، ومعاه circuit breaker و`update-service` العادي. النتيجة: resources أقل، drift أقل، وأقرب لتجربة الـ rolling العادية.

</details>

<details><summary>ليه الـ module بيعمل production rule على `/*` بدل ما يستخدم الـ default action؟</summary>

لأن ECS native بيطلب `productionListenerRule` ARN — الـ default action مالوش ARN كـ rule. وبكده الـ default action يفضل Terraform-managed من غير drift، والـ rule هو اللي ECS بيملكه (`ignore_changes = [action]`). Priority 100 بيسيب مساحة لـ rules قبله (الـ `/metrics` 404 على 1، والـ test header على 90).

</details>

<details><summary>Canary 10% لمدة 5 دقايق — إزاي تعرف إنه "كفاية"؟</summary>

إحصائياً: محتاج عدد requests كفاية على الـ canary يخلّي فرق الـ error rate يبان فوق الـ noise. مع 10 req/s كلي، الـ canary بياخد ~3000 request في 5 دقايق — كويس للـ 5xx الكبيرة، ضعيف للـ regressions الصغيرة. وكمان الـ alarm detection time (period × datapoints) لازم يبقى أقل من النافذة. الحلول: canary أطول، alarm أسرع، metrics per-TG (canary vs baseline)، أو Lambda hook بيعمل analysis.

</details>

<details><summary>إيه اللي بيحصل للـ autoscaling أثناء blue/green native؟</summary>

الـ green بيقوم بـ 100% من الـ desired (capacity مضاعفة). policy على `ALBRequestCountPerTarget` متثبتة على TG واحد بتبوظ بعد التبديل — عشان كده الـ module بيستخدم CPU بس مع الاستراتيجيات دي. ولو حصل scale-out أثناء الـ deployment، ECS بيطبّقه على الـ revisions الشغالة؛ ومهم الـ `autoscaling_max` يستحمل الـ surge.

</details>

<details><summary>إزاي تعمل "manual approval" قبل ما الـ production traffic يتحوّل في ECS native؟</summary>

Pause lifecycle hook على `POST_TEST_TRAFFIC_SHIFT` (أو `PRE_PRODUCTION_TRAFFIC_SHIFT`): الـ deployment يقف، الـ QA/الـ smoke يضرب الـ green بالـ test header، وبعدين `ContinueServiceDeployment` (أو rollback). أو Lambda hook يعمل الـ checks أوتوماتيك ويرجّع SUCCEEDED/FAILED. في CodeDeploy المقابل: `STOP_DEPLOYMENT` + `continue-deployment` أو `AfterAllowTestTraffic` Lambda.

</details>

<details><summary>Rollback بعد ما الـ deployment خلص وعمل CLEAN_UP — إيه اللي بيحصل لو الـ strategy CANARY؟</summary>

الـ rollback هنا = deployment عادي بالـ revision القديمة، فـ ECS هيمشي بنفس الـ canary: 10% للقديم 5 دقايق ثم الباقي. يعني "rollback بطيء" مقصود. لو محتاج سرعة: غيّر الـ strategy مؤقتاً لـ BLUE_GREEN (in-place) قبل الـ rollback deployment، أو اعمل الـ rollback وانت لسه في الـ bake time.

</details>

## 13) Checklist

- [ ] حوّلت الـ service لـ BLUE_GREEN ثم CANARY ثم LINEAR وقريت `terraform output deployment`
- [ ] راقبت الـ lifecycle stages والـ weights على الـ production rule
- [ ] ضربت الـ green بـ `X-Lab-Target: green` وفهمت ليه النافذة قصيرة من غير Pause hook
- [ ] قست التحويل بـ k6 بالـ versions
- [ ] عملت rollback بالـ alarm وبـ `stop-service-deployment`
- [ ] أقدر أشرح جدول CodeDeploy مقابل native
- [ ] رجعت لـ ROLLING أو عملت destroy
