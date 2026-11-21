# 53 — Rolling + circuit breaker rollback

> **الهدف في سطر:** تفهم الـ rolling update بتاع ECS بالأرقام (`minimumHealthyPercent` / `maximumPercent`)، الـ deployment circuit breaker والـ rollback الأوتوماتيك، الـ health check grace period، والـ ALB deregistration delay مع `SIGQUIT`/`stopTimeout` — وتعمل drill لـ release "مش بيقوم" (`SRE_FAULT_BOOT_FAIL`) وrelease "unhealthy" (`SRE_FAULT_UNHEALTHY`) وتقيس إن المستخدم مشافش ولا error بـ `probe.sh` و k6.
> **المستوى:** Intermediate → Advanced · **الوقت:** ~3 ساعات · **التكلفة التقريبية:** نفس [51](51-ecs-fargate-terraform.md)
> **بيعتمد على:** [51](51-ecs-fargate-terraform.md) · [52](52-ecs-migrations-and-exec.md) · [22 — قياس الـ downtime](22-recreate-and-measuring-downtime.md) · [25 — Rolling على host واحد](25-rolling-single-host.md) · **الملفات في الـ repo:** [`modules/ecs-fargate/service.tf`](../../../infra/terraform/modules/ecs-fargate/service.tf) · [`modules/ecs-fargate/main.tf`](../../../infra/terraform/modules/ecs-fargate/main.tf) · [`modules/alb/main.tf`](../../../infra/terraform/modules/alb/main.tf) · [`.github/workflows/deploy-ecs.yml`](../../../.github/workflows/deploy-ecs.yml) · [`docker/entrypoint.d/2-sre-boot-fault.sh`](../../../docker/entrypoint.d/2-sre-boot-fault.sh) · [`deploy/scripts/probe.sh`](../../../deploy/scripts/probe.sh) · [`loadtest/k6/canary-watch.js`](../../../loadtest/k6/canary-watch.js)

## 1) الفكرة (Concepts)

**Rolling** = استبدال الـ tasks القديمة بجديدة بالتدريج **في نفس الـ target group**. مفيش بيئة تانية، مفيش test traffic، ومفيش instant switch — بس أرخص استراتيجية ومفيهاش capacity مضاعفة طول الوقت.

| المصطلح | المعنى |
|---|---|
| `minimumHealthyPercent` | أقل نسبة من `desiredCount` لازم تفضل `RUNNING` (وhealthy لو فيه LB) أثناء الـ deploy — **rounded up** |
| `maximumPercent` | أكبر نسبة tasks (`RUNNING` + `PENDING`) مسموحة أثناء الـ deploy — **rounded down** |
| Deployment circuit breaker | ECS بيعدّ الـ tasks الجديدة اللي فشلت تقوم أو فشلت health checks؛ لو عدّت الـ threshold → الـ deployment `FAILED` |
| Rollback on failures | لما الـ deployment يبقى `FAILED` يرجع لآخر deployment `COMPLETED` |
| `rolloutState` | `IN_PROGRESS` → `COMPLETED` أو `FAILED` (في `describe-services.deployments[]`) |
| Health check grace period | ثواني بعد start الـ task الـ scheduler بيتجاهل فيها نتايج الـ ALB/container health checks |
| Deregistration delay | ثواني الـ ALB بيسيب فيها الـ target "draining": مفيش requests جديدة، والقديمة بتكمّل |
| `stopTimeout` | ثواني بين الـ stop signal والـ `SIGKILL` (max 120 على Fargate) |
| Deployment alarms | CloudWatch alarms بتوقف الـ deployment وترجّعه لو دخلت ALARM — للـ release السليم في الـ health checks بس سيء للمستخدم |

### الحساب (الإعدادات عندنا: min 100% / max 200%)

| `desiredCount` | min healthy (↑) | max tasks (↓) | اللي بيحصل |
|---|---|---|---|
| 2 | 2 | 4 | يقوّم 2 جداد → لما يبقوا healthy يشيل القديمين. **مفيش لحظة أقل من 2 بيخدموا** |
| 6 (بعد autoscaling) | 6 | 12 | يقوّم لحد 6 جداد مرة واحدة → capacity مضاعفة دقايق |
| 2 لو min=50 / max=100 | 1 | 2 | يقفل واحد قديم الأول (نص الـ capacity!) ثم يقوّم جديد — أرخص بس بيقلل الـ capacity وقت الـ deploy |
| 2 لو min=100 / max=150 | 2 | 3 | واحد جديد في المرة → أبطأ، و +50% capacity بس |

> 💡 min=100/max=200 = "surge" كامل: أسرع وأأمن، والتمن capacity مضاعفة لدقايق (على Fargate = فلوس الدقايق دي بس). لو فيه limit على الـ RDS connections أو quota للـ tasks، الـ 200% دي ممكن تخبطها.

### الـ circuit breaker

- **الـ threshold:** تقريباً نص الـ `desiredCount` (rounded up)، بحد أدنى **3** وأقصى 200. مع `desiredCount=2` → **3 tasks فاشلة** وبعدها `FAILED`.
- **مرحلتين:** (1) الـ tasks بتوصل `RUNNING` ولا بتقف قبلها (pull، secrets، entrypoint)؛ (2) بعد `RUNNING`: الـ ALB health checks والـ container healthCheck.
- **الـ rollback** = deployment جديد بالـ task definition بتاعة آخر deployment `COMPLETED`. لو مفيش (أول deployment)، مفيش حاجة يرجعلها.
- الـ circuit breaker **مش بيشوف** error rate أو latency — release بيرجّع 500 على 50% من الصفحات وهو healthy هيعدّي. ده شغل الـ **deployment alarms** (§8، [54](54-ecs-codedeploy-bluegreen-canary.md)، [55](55-ecs-native-bluegreen-linear-canary.md)).

## 2) المعمارية (Architecture)

```text
 Rolling (desired 2, min 100%, max 200%) — target group student-app-lab-blue

 t0   update-service (rev N+1)            TG: [old1 ✓][old2 ✓]
 t+40s new1,new2 PENDING→RUNNING          TG: [old1 ✓][old2 ✓][new1 initial][new2 initial]
       (pull image + secrets + optimize)        ALB /ready كل 10s، يحتاج 2 ناجحين
       grace period 60s: الـ scheduler مش بيحاسب على health checks
 t+70s new1,new2 healthy                  TG: [old1 ✓][old2 ✓][new1 ✓][new2 ✓]
 t+70s deregister old1,old2               TG: [old1 draining][old2 draining][new1 ✓][new2 ✓]
       deregistration_delay = 30s: requests شغالة تكمّل، مفيش جديد
 t+100s ECS → SIGQUIT (image STOPSIGNAL)  php-fpm يخلّص الـ in-flight ويقفل
 t+130s SIGKILL لو لسه عايش (stopTimeout 30)
        rolloutState = COMPLETED

 Release فاشل:
 new1 ✗ (exit 1) → replacement ✗ → replacement ✗  → 3 failures ≥ threshold
   → rolloutState FAILED → rollback: deployment جديد بـ rev N → old tasks لسه شغالة أصلاً
   → المستخدم مشافش حاجة (min 100% = القديم عمره ما اتشال)
```

## 3) المتطلبات (Prerequisites)

- [ ] stack 50 شغال بـ defaults (`deployment_controller = "ECS"`، `deployment_strategy = "ROLLING"`).
- [ ] الـ GitHub variables متظبطة ([51 §6](51-ecs-fargate-terraform.md)) و `AWS_DEPLOY_ROLE_ARN` من الـ bootstrap ([30](30-ci-github-actions.md)).
- [ ] image تانية في ECR (commit تاني على `master`) عشان تشوف تغيير `version` في `/ready`.
- الأدوات: `aws`، `jq`، `gh`، `k6` (اختياري)، [`probe.sh`](../../../deploy/scripts/probe.sh).

## 4) الطريقة الأولى: AWS Console (يدوي)

### 4.1 راجع/عدّل إعدادات الـ rolling

**ECS → Clusters → `student-app-lab` → Services → `student-app-lab-app` → Update service**:

- **Deployment options:** Rolling update · Min running tasks **100** · Max running tasks **200**.
- **Deployment failure detection:** ✅ Use the Amazon ECS deployment circuit breaker · ✅ Rollback on failures · (اختياري) ✅ Use CloudWatch alarm(s) → `student-app-lab-alb-5xx-ratio` + ✅ Rollback on failures.
- **Health check grace period:** 60.
- (جديد في الـ console) **Early success criteria** (Healthy percent + Source service revision cleanup Blocking/Deferred): يخلّص الـ deployment قبل ما كل الـ tasks الجديدة توصل الـ desired count. الـ Terraform module مش بيستخدمه — اقراه وسيبه مقفول.

> ⚠️ أي تعديل هنا على service عمله Terraform = **drift**: الـ `apply` الجاي هيرجّع الـ circuit breaker/alarms/min/max (مش متجاهلين). جرّب وبعدين رجّع، أو اعمل التغيير في الـ module.

**EC2 → Target groups → `student-app-lab-blue` → Attributes:** Deregistration delay **30**.

### 4.2 Deploy من الـ console وراقب

Task definitions → revision جديدة بـ image تانية ([50 §4.12](50-ecs-fargate-console.md)) → migrations → Update service. في تاب **Deployments** شوف الـ deployment الجديد `In progress` جنب القديم، وفي **Events**: `has started 2 tasks` → `registered 2 targets` → `has begun draining connections on 2 tasks` → `deregistered 2 targets` → `has stopped 2 running tasks` → `deployment completed` → `has reached a steady state`.

### 4.3 Drill الـ boot-fail من الـ console

Create new revision من الـ revision الشغالة → container `app` → **Environment variables → Add** `SRE_FAULT_BOOT_FAIL` = `true` → Create → **Update service** بالـ revision دي (**من غير** migration). في **Deployments** هتشوف `Failed tasks` بيزيد لحد 3 → الـ deployment `Failed` → deployment جديد `Rollback in progress` بالـ revision القديمة → `Completed`. افتح أي task فاشل: **Stopped reason** `Essential container in task exited`، **Exit code** 1، والـ log: `SRE_FAULT_BOOT_FAIL=true -> refusing to start`.

## 5) الطريقة التانية: Infrastructure as Code

من [`service.tf`](../../../infra/terraform/modules/ecs-fargate/service.tf) (كلها `local.ecs_controller` بس — CodeDeploy ليه rollback بتاعه):

```hcl
deployment_minimum_healthy_percent = local.ecs_controller ? 100 : null
deployment_maximum_percent         = local.ecs_controller ? 200 : null

dynamic "deployment_circuit_breaker" { ... enable = true  rollback = true }
dynamic "alarms" {                     # بس لو deployment_alarm_names مش فاضية
  ... enable = true  rollback = true  alarm_names = var.deployment_alarm_names
}
deployment_configuration { strategy = var.deployment_strategy ... }   # ROLLING هنا
health_check_grace_period_seconds = var.health_check_grace_period_seconds   # 60
```

ومن [`main.tf`](../../../infra/terraform/modules/ecs-fargate/main.tf) و [`modules/alb/main.tf`](../../../infra/terraform/modules/alb/main.tf):

| الإعداد | القيمة | المكان |
|---|---|---|
| container `healthCheck` | `/up` كل 15s، timeout 5، retries 3، `startPeriod` 60 | module ecs-fargate |
| `stopTimeout` | 30 (الـ image `STOPSIGNAL SIGQUIT`) | module ecs-fargate |
| TG health check | `/ready`، interval 10، timeout 5، healthy 2، unhealthy 2، matcher 200 | module alb |
| `deregistration_delay` | 30 | module alb |
| ALB `idle_timeout` | 60 | module alb |
| deployment alarms | `use_deployment_alarms = true` → `["student-app-lab-alb-5xx-ratio"]` | stack 50 |

> 💡 **SIGQUIT على Fargate:** الـ Dockerfile فيه `STOPSIGNAL SIGQUIT` (الإشارة اللي بتخلّي PHP-FPM يقفل graceful). ECS على Fargate بقى بيحترم الـ `STOPSIGNAL` بتاع الـ image (إعلان AWS ديسمبر 2025)؛ قبلها كان بيبعت `SIGTERM` دايماً. اتأكد بنفسك في الـ logs وقت الـ drain (`php-fpm ... Finishing` / `exiting`).
> 💡 **ترتيب الإيقاف:** ECS بيعمل deregister من الـ TG **الأول** ويستنى الـ deregistration delay، **وبعدين** يبعت الـ stop signal. عشان كده `deregistration_delay` (30) + `stopTimeout` (30) = أقصى عمر لـ request طويل وقت الـ deploy ≈ 60s، وده متوافق مع `idle_timeout` 60.

## 6) الـ Deploy

### 6.1 Deploy عادي بـ `deploy-ecs.yml`

```bash
gh workflow run deploy-ecs.yml --ref master -f strategy=rolling -f taskdef_source=live
# من branch تاني: لازم image_tag لـ SHA اتعمله push من master
gh workflow run deploy-ecs.yml --ref devops-lab -f strategy=rolling -f taskdef_source=live -f image_tag=<SHA7>
gh run watch
```

الـ workflow (تفاصيله في [58](58-ecs-github-actions-vs-codepipeline.md)): OIDC → الـ image موجودة؟ → الـ controller مطابق للـ strategy؟ → render (live، من غير أي `SRE_FAULT_*` قديم) + `extra_env` → register → **migrations** (لو `run_migrations=true`، الـ default) → `amazon-ecs-deploy-task-definition` مع `wait-for-service-stability` → smoke: `/ready` لازم يرجّع `version == <tag>` و `/login` < 500.

### 6.2 قِس وانت بتعمل deploy

Terminal 1 (قبل ما تبدأ):

```bash
URL=$(terraform -chdir=infra/terraform/stacks/50-ecs-fargate output -raw app_url)
bash deploy/scripts/probe.sh "$URL/ready" 300 0.2
# أو k6: توزيع الـ versions + أي request فشل (DEPLOY_COLOR=stable على كل الـ tasks، فقارن بالـ version)
k6 run -e BASE_URL="$URL" -e DURATION=5m -e EXPECT_VERSIONS=<OLD_SHA7>,<NEW_SHA7> loadtest/k6/canary-watch.js
```

Terminal 2: الـ deploy (6.1). Terminal 3: راقب الـ deployments:

```bash
while :; do
  aws ecs describe-services --cluster student-app-lab --services student-app-lab-app \
    --query 'services[0].deployments[].[status,rolloutState,runningCount,failedTasks,taskDefinition]' --output table
  sleep 10
done
```

المفروض: `probe.sh` → `failed : 0` و `answered by` فيه الـ version القديمة ثم الجديدة؛ k6 → `http_req_failed` = 0%.

## 7) التحقق (Verify)

```bash
aws ecs describe-services --cluster student-app-lab --services student-app-lab-app \
  --query 'services[0].{td:taskDefinition,deployments:deployments[].{s:status,r:rolloutState,why:rolloutStateReason}}'
aws ecs describe-services --cluster student-app-lab --services student-app-lab-app \
  --query 'services[0].events[:8].[createdAt,message]' --output table
curl -s "$URL/ready" | jq '{version,color}'
```

## 8) اكسرها (Break it): تمرين على الأعطال

### 8.1 Release مش بيقوم (`SRE_FAULT_BOOT_FAIL=true`) → circuit breaker

```bash
gh workflow run deploy-ecs.yml --ref master -f strategy=rolling -f taskdef_source=live \
  -f run_migrations=false -f extra_env="SRE_FAULT_BOOT_FAIL=true"
# راقب بالـ loop بتاع 6.2 + probe.sh في terminal تاني
```

**ليه `run_migrations=false`؟** الـ workflow عادةً بيشغّل الـ **migration task بنفس الـ revision الجديدة قبل الـ deploy**، والـ entrypoint ([`2-sre-boot-fault.sh`](../../../docker/entrypoint.d/2-sre-boot-fault.sh)) بيرفض يقوم حتى مع command override (نفس [23](23-bluegreen-single-host.md) و `lab-integration.yml`). فمع `run_migrations=true` الـ workflow هيقف عند **Migrations** بـ `exit code 1` والـ service عمره ما يتحدّث — وده نفسه درس: الـ migration step = smoke test مجاني للـ boot (جرّبه مرة). الـ input ده موجود **للـ drill ده بس**؛ في أي deploy حقيقي سيبه `true`.

| المتوقع | فين |
|---|---|
| الـ tasks الجديدة `STOPPED` بـ exit 1 بعد ثواني، `failedTasks` يزيد 1 → 2 → 3 | `describe-services.deployments[]` |
| `rolloutState = FAILED` و `rolloutStateReason` فيه circuit breaker | نفس الأمر |
| deployment جديد بالـ revision القديمة → `COMPLETED` | events: `(deployment ...) deployment failed: tasks failed to start` + `rolling back to deployment ...` |
| الـ job **أحمر**: خطوة الـ deploy أو الـ smoke (`/ready does not serve <tag>` — الـ service استقر على القديم) | job summary فيه الـ "Previous revision" |
| `probe.sh` → **`failed : 0`** | القديم عمره ما اتشال (min 100%) |

**مفيش تنضيف مطلوب:** الـ revisions اللي اتسجلت فيها `SRE_FAULT_BOOT_FAIL=true` هي دلوقتي أحدث revisions في الـ family، بس `render-taskdef.sh live` **بيشيل كل `SRE_FAULT_*`** من الـ copy (إلا لو `KEEP_FAULT_ENV=true`)، فالـ deploy الجاي نضيف أوتوماتيك. اتأكد بنفسك:

```bash
bash deploy/ecs/render-taskdef.sh live student-app-lab-app | jq '[.containerDefinitions[0].environment[].name]'
KEEP_FAULT_ENV=true bash deploy/ecs/render-taskdef.sh live student-app-lab-app | jq '[.containerDefinitions[0].environment[].name]'
```

<details><summary>نفس الـ drill من الـ CLI (من غير الـ workflow)</summary>

```bash
export AWS_REGION=us-east-1 ECS_CLUSTER=student-app-lab ECS_SERVICE=student-app-lab-app
GOOD_TD=$(aws ecs describe-services --cluster $ECS_CLUSTER --services $ECS_SERVICE --query 'services[0].taskDefinition' --output text)
bash deploy/ecs/render-taskdef.sh live "$GOOD_TD" | jq '
  .containerDefinitions |= map(if .name == "app" then .environment += [{"name":"SRE_FAULT_BOOT_FAIL","value":"true"}] else . end)' > td-bootfail.json
BAD_TD=$(aws ecs register-task-definition --cli-input-json file://td-bootfail.json --query taskDefinition.taskDefinitionArn --output text)
aws ecs update-service --cluster $ECS_CLUSTER --service $ECS_SERVICE --task-definition "$BAD_TD" >/dev/null
```

(الـ `live` render شال أي `SRE_FAULT_*` قديم، فالـ `+=` مش هيكرر الاسم.)

</details>

### 8.2 Release unhealthy (`SRE_FAULT_UNHEALTHY=true`) → circuit breaker مرحلة 2

هنا الـ workflow شغال لآخره: الـ fault على HTTP بس (`/up` = 500 و `/ready` = 503 لما `SRE_LAB_ENABLED=true`)، فـ `php artisan migrate` بيعدّي.

```bash
gh workflow run deploy-ecs.yml --ref master -f strategy=rolling -f taskdef_source=live -f extra_env="SRE_FAULT_UNHEALTHY=true"
```

| المتوقع | ليه |
|---|---|
| الـ tasks الجديدة `RUNNING` بس مبتبقاش healthy في الـ TG (`/ready` 503) | الـ ALB مبيبعتلهاش traffic أصلاً |
| بعد `startPeriod` 60 + 3×15s: الـ container `UNHEALTHY` (`/up` 500) → ECS يقتلها ويبدّل | container healthCheck |
| 3 failures → `FAILED` → rollback | circuit breaker stage 2 |
| خطوة الـ deploy في الـ workflow ممكن تخلص "stable" (الـ service استقر — على القديم!) ثم **Smoke test يفشل**: `/ready does not serve <tag>` | ده سبب إن الـ smoke بيتشيك على الـ `version` مش بس الـ 200 |
| `probe.sh` → `failed : 0` | |

الـ workflow سجّل revisionين فيهم `SRE_FAULT_UNHEALTHY=true` (register + deploy) — زي 8.1، الـ `live` render بيشيل الـ `SRE_FAULT_*`، فالـ deploy الجاي (من غير `extra_env`) نضيف. ده كان bug حقيقي قبل كده: الـ fault كان بيتورّث لكل deploy بعده لأن الـ `live` بيعمل copy لأحدث revision.

### 8.3 Release سليم في الـ health checks بس سيء (`SRE_FAULT_ERROR_RATE`) → deployment alarms

```bash
cd infra/terraform/stacks/50-ecs-fargate
terraform apply -var use_deployment_alarms=true     # in-place: الـ alarms block مش متجاهل
cd -
bash deploy/scripts/probe.sh "$URL/login" 900 0.2 &   # traffic على صفحات حقيقية (InjectFaults على الـ web group)
gh workflow run deploy-ecs.yml --ref master -f strategy=rolling -f taskdef_source=live -f extra_env="SRE_FAULT_ERROR_RATE=0.5"
```

المتوقع: الـ deploy يكمّل (الـ health checks سليمة) → الـ 5xx ratio يعدّي 1% → `student-app-lab-alb-5xx-ratio` = ALARM (period 5 دقايق، فالكشف بطيء) → ECS يعتبر الـ deployment فاشل ويرجّع (ECS بيراقب الـ alarms أثناء الـ deployment وفترة بعده). **المستخدمين شافوا errors** طول الفترة دي — rolling مفيهوش blast-radius control؛ ده سبب [54](54-ecs-codedeploy-bluegreen-canary.md)/[55](55-ecs-native-bluegreen-linear-canary.md). لو الـ alarm مفجّرش والـ revision البايظة فضلت live، أي deploy جديد من غير `extra_env` بيرجّعك لـ release نضيف (الـ render بيشيل الـ fault).

### 8.4 جدول سريع

| التمرين | المتوقع |
|---|---|
| `deregistration_delay` = 0 (من الـ console على الـ TG) + `/sre-lab/latency?ms=5000` traffic أثناء deploy | requests بتتقطع (502) وقت الـ drain |
| `minimumHealthyPercent` 0 | ECS ممكن يقفل كل القديم الأول → downtime يظهر في `probe.sh` |
| Grace period 0 + boot أبطأ (`SRE_FAULT_LATENCY_MS` مش بيأثر على البوت — جرّب CPU أقل `task_cpu=256`) | tasks سليمة تتقتل قبل ما تلحق تبقى healthy → circuit breaker false positive |

## 9) الرجوع (Rollback)

```bash
# يدوي لآخر revision سليمة (الـ workflow بيطبعها في الـ summary كـ "Previous revision")
aws ecs update-service --cluster student-app-lab --service student-app-lab-app --task-definition student-app-lab-app:<GOOD_REV>
aws ecs wait services-stable --cluster student-app-lab --services student-app-lab-app
# أو re-run الـ workflow بالـ tag القديم
gh workflow run deploy-ecs.yml --ref master -f strategy=rolling -f taskdef_source=live -f image_tag=<OLD_SHA7>
```

الـ rollback في rolling = **rolling تاني** (دقايق، مش ثواني) — ده الفرق الجوهري عن blue/green.

## 10) المسح (Teardown) ⚠️

- رجّع أي تعديل console (min/max/alarms/dereg) أو اعمل `terraform apply` عشان يرجّع الـ defaults؛ ولو جرّبت `use_deployment_alarms=true` رجّعه `false` لو مش محتاجه.
- الـ revisions بتاعة الـ drills مش محتاجة مسح (الـ `live` render بيشيل `SRE_FAULT_*`)؛ امسحها بس لو عايز family نضيفة (`aws ecs deregister-task-definition`).
- الـ stack نفسه: [51 §10](51-ecs-fargate-terraform.md).

## 11) التكلفة (Cost)

| Resource | السعر التقريبي (تقريبي — راجع صفحة الأسعار) |
|---|---|
| الـ stack | ≈ $0.11/ساعة |
| الـ surge (200%) | +2 tasks لمدة ~2–3 دقايق لكل deploy ≈ أقل من سنت |
| الـ drills الفاشلة | tasks بتعيش ثواني (حد أدنى دقيقة) — سنتات |
| GitHub Actions | مجاني للـ public repo |

## 12) أسئلة Interview

<details><summary>`minimumHealthyPercent=100` و `maximumPercent=200` مع 6 tasks — اشرح اللي بيحصل وإيه المخاطر.</summary>

ECS يقدر يشغّل لحد 12 task: يقوّم 6 جداد، يستنى يبقوا healthy، يعمل drain للقديم. مفيش أي نقص في الـ capacity. المخاطر: capacity مضاعفة (quota الـ Fargate tasks/vCPU في الـ region، الـ RDS `max_connections`، الـ IPs في الـ subnet لأن كل task ليه ENI)، وتكلفة دقايق. لو الـ subnets صغيرة (/24 = 251 IP) والـ cluster كبير، الـ surge ممكن يفشل بسبب IPs.

</details>

<details><summary>الـ circuit breaker بيحمي من إيه وبيفوّت إيه؟</summary>

بيحمي من release مش قادر يبقى healthy: crash عند الـ boot، image/secret مش موجودة، health checks فاشلة. بيفوّت release healthy بس غلط: error rate على صفحات معينة، latency، bugs في الـ business logic. لده: deployment alarms (5xx ratio، latency p95، burn rate) مع rollback، أو استراتيجية بـ blast radius صغير (canary) + bake time.

</details>

<details><summary>إزاي تضمن إن request شغال وقت الـ deploy مش هيتقطع؟</summary>

السلسلة: ECS يعمل deregister من الـ TG → الـ ALB يبطّل يبعت requests جديدة ويستنى `deregistration_delay` للـ in-flight → ECS يبعت الـ STOPSIGNAL (SIGQUIT = PHP-FPM graceful) → `stopTimeout` قبل SIGKILL. لازم: الـ delay ≥ أطول request طبيعي، الـ app يتعامل مع الـ signal صح، والـ keep-alive من الـ ALB للـ target يتقفل بنضافة. ولو فيه long-polling/WebSockets لازم reconnect logic.

</details>

<details><summary>الـ health check grace period — إيه اللي يحصل لو صغير جداً أو كبير جداً؟</summary>

صغير: tasks سليمة بس بطيئة في الـ boot (cold cache، `optimize`) تتعلّم unhealthy وتتقتل → الـ circuit breaker يعتبر الـ release فاشل (false positive) أو flapping. كبير: task بايظ فعلاً ياخد وقت أطول قبل ما يتشال، والـ deploy الفاشل ياخد وقت أطول لحد الـ rollback. الصح: أطول من الـ p99 بتاع وقت الـ boot لحد أول `/ready` ناجح، بهامش.

</details>

<details><summary>ليه الـ smoke test في الـ pipeline بيتشيك على الـ version مش بس HTTP 200؟</summary>

لأن بعد circuit-breaker rollback الـ service بيبقى "stable" — على الـ revision القديمة. أي check على 200 هيعدّي والـ pipeline هيبقى أخضر وهو مـ deployش حاجة. الـ `/ready` بيرجّع `version` (الـ `APP_VERSION` المحفور في الـ image)، فالمقارنة بالـ tag بتكشف الـ silent rollback.

</details>

<details><summary>الـ rolling update مقابل blue/green — إمتى تختار rolling؟</summary>

Rolling: أرخص، أبسط، مفيش listener/TG تاني، مناسب لما الـ releases صغيرة ومتكررة ومعاك circuit breaker + alarms. عيوبه: الإصدارين بيخدموا مع بعض أثناء الـ deploy (لازم backward compatibility في الـ API والـ schema)، مفيش test traffic قبل production، والـ rollback = deploy تاني (دقايق). Blue/green: instant rollback و test traffic، والتمن capacity مضاعفة وتعقيد أكبر.

</details>

## 13) Checklist

- [ ] حسبت min/max لـ 2 و 6 tasks وفاهم الـ rounding
- [ ] عملت deploy بـ `deploy-ecs.yml` وقست 0 failures بـ `probe.sh` / k6
- [ ] شغّلت drill الـ boot-fail بـ `deploy-ecs.yml` (`run_migrations=false`) وشفت الـ circuit breaker يرجّع — ومرة بـ `run_migrations=true` وشفت الـ migration step يوقفه بدري
- [ ] شغّلت drill الـ unhealthy بالـ workflow وفهمت ليه الـ smoke فشل
- [ ] فاهم ليه `run_migrations=false` للـ boot-fail drill بس، وليه الـ `live` render بيشيل `SRE_FAULT_*` (و `KEEP_FAULT_ENV=true`)
- [ ] (اختياري) جرّبت الـ deployment alarms مع `SRE_FAULT_ERROR_RATE`
- [ ] رجّعت كل الإعدادات
