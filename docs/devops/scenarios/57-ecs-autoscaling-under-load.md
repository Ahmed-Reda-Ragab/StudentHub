# 57 — ECS autoscaling تحت load

> **الهدف في سطر:** تشغّل Application Auto Scaling على الـ service (target tracking على CPU و `ALBRequestCountPerTarget`)، تفهم الـ cooldowns والـ scale-in protection، تضغط بـ [`autoscale-cpu.js`](../../../loadtest/k6/autoscale-cpu.js) على `/sre-lab/cpu` (بـ `SRE_LAB_TOKEN`)، تعرف تبص على إيه (CloudWatch، Container Insights، scaling activities)، تحسب الـ capacity بإيدك، وتتأكد إن الـ SLOs (k6 `load.js`) صامدة والـ service بيكبر.
> **المستوى:** Intermediate → Advanced · **الوقت:** ~3 ساعات · **التكلفة التقريبية:** نفس [51](51-ecs-fargate-terraform.md) + tasks زيادة وقت الـ test (سنتات)
> **بيعتمد على:** [51](51-ecs-fargate-terraform.md) · [56](56-ecs-capacity-providers-spot.md) · [48 — Autoscaling على ASG](48-autoscaling-under-load.md) · [74 — k6](74-load-testing-k6.md) · **الملفات في الـ repo:** [`modules/ecs-fargate/autoscaling.tf`](../../../infra/terraform/modules/ecs-fargate/autoscaling.tf) · [`modules/ecs-fargate/variables.tf`](../../../infra/terraform/modules/ecs-fargate/variables.tf) · [`loadtest/k6/autoscale-cpu.js`](../../../loadtest/k6/autoscale-cpu.js) · [`loadtest/k6/load.js`](../../../loadtest/k6/load.js) · [`loadtest/k6/README.md`](../../../loadtest/k6/README.md) · [`config/sre_lab.php`](../../../config/sre_lab.php) · [`modules/observability/dashboard.tf`](../../../infra/terraform/modules/observability/dashboard.tf) · [`.github/workflows/perf-gate.yml`](../../../.github/workflows/perf-gate.yml)

## 1) الفكرة (Concepts)

| المصطلح | المعنى |
|---|---|
| Scalable target | `ecs:service:DesiredCount` للـ service، بـ min/max (2/6 عندنا) |
| Target tracking | "خلّي الـ metric حوالين القيمة دي" — AWS بيعمل CloudWatch alarms (high/low) ويحسب كام task يزوّد/يشيل |
| `ECSServiceAverageCPUUtilization` | متوسط CPU الـ service كنسبة من الـ CPU المحجوز للـ tasks (من `AWS/ECS`، كل دقيقة) |
| `ALBRequestCountPerTarget` | عدد الـ requests لكل target في الدقيقة على **target group واحد** |
| Scale-out cooldown | بعد scale-out، مستنى قد إيه قبل scale-out تاني (60s عندنا) |
| Scale-in cooldown | بعد scale-in، مستنى قد إيه قبل scale-in تاني (180s عندنا) |
| Turn off scale-in (`disable_scale_in`) | الـ policy تكبّر بس — حد تاني (أو policy تانية) يصغّر |
| Task scale-in protection | `UpdateTaskProtection` على task معين (شغل طويل شغال) فميتشالش وقت scale-in أو deploy |
| أكتر من policy | scale-**out** لو **أي** policy قالت كده؛ scale-**in** بس لو **كلهم** موافقين |

**ليه سريع للـ out وبطيء للـ in؟** الـ high alarm بتاع target tracking بيحتاج تقريباً 3 datapoints (دقيقة لكل واحد) فوق الـ target، والـ low alarm تقريباً 15 datapoint تحت — مقصود: الكلفة بتاعة capacity ناقصة (SLO) أعلى من كلفة capacity زيادة (فلوس). والـ cooldowns (60 / 180) بتكمّل نفس المنطق ضد الـ flapping.

### الـ policies في الـ module ([`autoscaling.tf`](../../../infra/terraform/modules/ecs-fargate/autoscaling.tf))

| Policy | Metric | Target | Cooldown out/in | إمتى موجودة |
|---|---|---|---|---|
| `student-app-lab-app-cpu` | `ECSServiceAverageCPUUtilization` | **50%** (`cpu_target_value`) | 60 / 180 | دايماً |
| `student-app-lab-app-requests` | `ALBRequestCountPerTarget` (resource label `<alb_arn_suffix>/<blue_tg_arn_suffix>`) | **600 req/min/task** (`requests_per_target`) | 60 / 180 | `enable_request_count_scaling && ECS controller && ROLLING` |

> 💡 الـ request policy متثبتة على **TG blue**؛ مع blue/green (native أو CodeDeploy) الـ tasks بتتنقل بين الـ TGs، فالـ metric هيقيس TG فاضي ويقول "صغّر" — عشان كده الـ module بيشيلها مع أي strategy غير ROLLING.
> 💡 `cpu_target_value` و `requests_per_target` مش متعرّضين في stack 50 (تعديل `module "ecs"`). الـ `autoscaling_min` / `autoscaling_max` متعرّضين (2 / 6).

### الحساب (capacity math)

`/sre-lab/cpu?ms=N` بيحرق N ms من CPU خالص لكل request. فالطلب متوقع:

```text
CPU demand (vCPU)    = RATE × CPU_MS / 1000
tasks needed         = demand / (vCPU per task × target utilisation)
task 0.5 vCPU, target 50%  →  كل task يشيل 0.25 vCPU "مريح"

RATE=5,  CPU_MS=200 → 1 vCPU → 1 / 0.25 = 4 tasks       ✅ جوه الـ max (6)
RATE=6,  CPU_MS=200 → 1.2 vCPU → 1.2 / 0.25 ≈ 5 tasks    ✅ (اللي header الـ script بيقترحه عشان تفضل جوه الـ max)
RATE=10, CPU_MS=200 → 2 vCPU → 2 / 0.25 = 8 tasks       ✗ max=6 → 6×0.5 = 3 vCPU → ~67% CPU، الـ policy مش هتوصل للـ target
```

> 💡 نفس الحساب مكتوب في header الـ [`autoscale-cpu.js`](../../../loadtest/k6/autoscale-cpu.js) (ECS task 0.5 vCPU، target 50% → RATE=10 = 8 tasks > max 6 — "you SEE the ceiling").

وكمان: request بـ 200ms CPU على task نص vCPU بياخد ≥ ~400ms wall-clock (الـ task محدود بـ 0.5 vCPU)، فالـ latency بتاعة `/sre-lab/cpu` مش مقياس SLO — ده drill capacity. والـ request policy: 600 req/min = **10 req/s لكل task**.

## 2) المعمارية (Architecture)

```text
 k6 (laptop / perf-gate.yml)
   autoscale-cpu.js: constant-arrival-rate RATE req/s → /sre-lab/cpu?ms=CPU_MS  (X-Lab-Token)
                     + 1 req/s → /sre-lab/version  (يطبع كل hostname جديد = capacity جديدة بتاخد traffic)
   load.js: VUs بيعملوا login + browse (SLO thresholds)
        │
        ▼
 ALB ──► TG blue ──► tasks (2 → 6)
                       │ CPUUtilization (AWS/ECS، 1-min)       RequestCountPerTarget (AWS/ApplicationELB)
                       ▼                                      ▼
            alarm TargetTracking-...-AlarmHigh (≈3×1m)   alarm TargetTracking-...-AlarmHigh
                       └───────────────┬──────────────────────┘
                                       ▼
                   Application Auto Scaling: desiredCount = 2 → 4 → ...
                                       ▼
                   ECS: tasks جديدة (strategy: 1 FARGATE + الباقي SPOT) → register → /ready ×2 → traffic
 scale-in: AlarmLow (≈15×1m) + cooldown 180s → يشيل tasks بالتدريج (deregister → drain 30s → SIGQUIT)
```

## 3) المتطلبات (Prerequisites)

- [ ] stack 50 بـ `deployment_strategy = "ROLLING"` (عشان الـ request policy موجودة) و `sre_lab_enabled = true`.
- [ ] الـ SRE lab token:

```bash
TOKEN=$(aws ssm get-parameter --name /student-app/lab/app/SRE_LAB_TOKEN --with-decryption --query Parameter.Value --output text)
URL=$(terraform -chdir=infra/terraform/stacks/50-ecs-fargate output -raw app_url)
curl -s -H "X-Lab-Token: $TOKEN" "$URL/sre-lab/cpu?ms=200" | jq     # 200 = تمام · 403 = token غلط · 404 = SRE_LAB_ENABLED مش true
```

- [ ] بيانات الـ load test (لـ `load.js`): seed بـ one-off task ([52 §6.1](52-ecs-migrations-and-exec.md)) — `LoadTestSeeder` بـ `LOADTEST_USERS=20`.
- [ ] k6 على جهازك ([03](03-workstation-setup.md))، أو [`perf-gate.yml`](../../../.github/workflows/perf-gate.yml) على GitHub (محتاج secret `SRE_LAB_TOKEN` = قيمة الـ SSM: `gh secret set SRE_LAB_TOKEN --body "$TOKEN"`).

## 4) الطريقة الأولى: AWS Console (يدوي)

1. **ECS → service `student-app-lab-app` → تاب Configuration and networking (أو Service auto scaling)**: الـ min/max والـ policies الاتنين.
2. لو بتبني على ستاك [50](50-ecs-fargate-console.md) اليدوي: **Update service → Service auto scaling** → ✅ Service auto scaling · Minimum number of tasks **2** · Maximum **6** → Scaling policy type **Target tracking**:
   - Policy name `student-app-lab-app-cpu` · ECS service metric **ECSServiceAverageCPUUtilization** · Target value **50** · Scale-out cooldown **60** · Scale-in cooldown **180**.
   - (تاني) `student-app-lab-app-requests` · **ALBRequestCountPerTarget** · target group `student-app-lab-blue` · Target value **600** · نفس الـ cooldowns.
3. **CloudWatch → Alarms**: هتلاقي `TargetTracking-service/student-app-lab/student-app-lab-app-AlarmHigh-...` و `...-AlarmLow-...` لكل policy. **متعدّلهمش** — AWS بيديرهم وبيكتب فوقهم.
4. **CloudWatch → Container Insights → Performance monitoring → ECS Services** (أو dashboard الـ stack: `terraform output -raw dashboard_url`).
5. أثناء الـ test: تاب **Events** في الـ service (`has started 2 tasks`) + **Application Auto Scaling activity** في صفحة الـ auto scaling.

## 5) الطريقة التانية: Infrastructure as Code (Terraform)

```hcl
resource "aws_appautoscaling_target" "service" {
  service_namespace  = "ecs"
  scalable_dimension = "ecs:service:DesiredCount"
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.app.name}"
  min_capacity       = var.autoscaling_min_capacity   # 2
  max_capacity       = var.autoscaling_max_capacity   # 6
}

resource "aws_appautoscaling_policy" "cpu" {
  policy_type = "TargetTrackingScaling"
  target_tracking_scaling_policy_configuration {
    target_value       = var.cpu_target_value         # 50
    scale_out_cooldown = 60                           # react fast to load
    scale_in_cooldown  = 180                          # remove capacity slowly (avoid flapping)
    predefined_metric_specification { predefined_metric_type = "ECSServiceAverageCPUUtilization" }
  }
}
# + aws_appautoscaling_policy.requests (ALBRequestCountPerTarget، resource_label = "<alb>/<tg blue>") لـ ROLLING بس
```

وفي الـ service: `ignore_changes = [desired_count]` — من غيره كل `apply` يرجّع الـ count لـ 2 في نص الـ peak.

غيّر الحدود:

```bash
cd infra/terraform/stacks/50-ecs-fargate
terraform apply -var autoscaling_max=10      # سقف التكلفة
```

## 6) الـ Deploy — شغّل الـ drill

### 6.1 Terminal المراقبة

```bash
CL=student-app-lab SVC=student-app-lab-app
while :; do
  date -u +%H:%M:%S
  aws ecs describe-services --cluster $CL --services $SVC --query 'services[0].[desiredCount,runningCount,pendingCount]' --output text
  aws application-autoscaling describe-scaling-activities --service-namespace ecs \
    --resource-id service/$CL/$SVC --max-items 1 --query 'ScalingActivities[0].[StatusCode,Description]' --output text
  sleep 30
done
```

### 6.2 CPU drill (يكبر لـ ~4)

```bash
k6 run -e BASE_URL="$URL" -e LAB_TOKEN="$TOKEN" -e RATE=5 -e CPU_MS=200 -e DURATION=15m loadtest/k6/autoscale-cpu.js
```

الـ timeline المتوقع (تقريبي):

| الوقت | اللي بيحصل |
|---|---|
| 0–1 دقيقة | CPU يطلع لـ ~100% على الـ 2 tasks (الطلب 1 vCPU والـ capacity 1 vCPU) — latency عالية، ممكن `dropped_iterations` |
| ~3–4 دقايق | الـ AlarmHigh يفجّر → `Successfully set desired count to 4` (الحساب: 100% / 50% × 2 = 4) |
| ~5 دقايق | الـ tasks الجديدة RUNNING + healthy → k6 يطبع `instance serving traffic: ip-10-50-...` لكل task جديد |
| بعد كده | CPU حوالين 50%، latency رجعت |
| بعد k6 ما يخلص | ~15 دقيقة لحد AlarmLow → scale-in تدريجي لـ 2 (cooldown 180s بين كل خطوة) |

### 6.3 Saturation (يخبط في الـ max)

```bash
k6 run -e BASE_URL="$URL" -e LAB_TOKEN="$TOKEN" -e RATE=10 -e CPU_MS=200 -e DURATION=10m loadtest/k6/autoscale-cpu.js
```

المتوقع: يوصل **6** ويقف (`max_capacity`)، CPU ~67%، وأي زيادة تانية = latency + errors. ده "سقف التكلفة" بيشتغل — ودي لحظة تقرر فيها: تزوّد الـ max؟ tasks أكبر (`task_cpu=1024`)؟ ولا الـ code؟

> 💡 بـ GitHub: Actions → **Perf gate (k6)** → `script = autoscale-cpu.js`، `base_url = <app_url>`، `duration = 15m`، و **`k6_env`** = `RATE=5 CPU_MS=200` (أزواج `KEY=value` بمسافات، بتتبعت كـ `-e` لـ k6). من غير `k6_env` الـ defaults (RATE=10 / CPU_MS=200) = سيناريو 6.3 (السقف).
>
> ```bash
> gh workflow run perf-gate.yml -f base_url="$URL" -f script=autoscale-cpu.js -f duration=15m -f k6_env="RATE=5 CPU_MS=200"
> ```

### 6.4 SLO أثناء الـ scaling (`load.js` + request policy)

في terminalين مع بعض:

```bash
# 1) ضغط CPU في الخلفية
k6 run -e BASE_URL="$URL" -e LAB_TOKEN="$TOKEN" -e RATE=4 -e CPU_MS=200 -e DURATION=12m loadtest/k6/autoscale-cpu.js
# 2) مستخدمين حقيقيين بالـ SLO thresholds (exit 99 لو اتكسرت)
k6 run -e BASE_URL="$URL" -e LOADTEST_USERS=20 -e VUS=50 -e DURATION=10m -e P95_MS=300 loadtest/k6/load.js
```

`load.js` بـ 50 VU ≈ 40–50 req/s (Little's law، think time 1s) → على 2 tasks ≈ 1200–1500 req/min/task > 600 → **الـ request policy** هتكبّر لوحدها حتى لو الـ CPU مش عالي (~45×60/600 ≈ 5 tasks). اقرا الـ summary: `http_req_failed` < 0.5%، و `http_req_duration{expected_response:true}` p95 < 300ms — هل الـ SLO اتكسر في أول 4–5 دقايق قبل ما الـ capacity توصل؟ ده بالظبط سبب إن الـ min (2) لازم يستحمل الـ baseline + headroom.

### 6.5 إيه اللي تبص عليه

| Metric | Namespace / المكان | بيقولك إيه |
|---|---|---|
| `CPUUtilization`، `MemoryUtilization` (ClusterName، ServiceName) | `AWS/ECS` | الـ input بتاع الـ CPU policy |
| `RunningTaskCount`، `DesiredTaskCount`، `PendingTaskCount`، `CpuUtilized`/`CpuReserved` | `ECS/ContainerInsights` | الـ capacity الفعلية مقابل المطلوبة، وper-task (enhanced) |
| `RequestCountPerTarget`، `TargetResponseTime` (p95)، `HTTPCode_Target_5XX_Count`، `HealthyHostCount` | `AWS/ApplicationELB` | الـ input بتاع الـ request policy + الـ SLO |
| `student-app-lab-alb-latency-p95` / `-alb-5xx-ratio` | CloudWatch Alarms | الـ SLO alarms (0.3s / 1%) |
| scaling activities | `describe-scaling-activities` | ليه وإمتى غيّر الـ count |
| `CPUUtilization` / `DatabaseConnections` | `AWS/RDS` | الـ bottleneck الجاي بعد ما الـ app يكبر |

```bash
aws cloudwatch get-metric-statistics --namespace AWS/ECS --metric-name CPUUtilization \
  --dimensions Name=ClusterName,Value=student-app-lab Name=ServiceName,Value=student-app-lab-app \
  --start-time "$(date -u -d '-30 min' +%Y-%m-%dT%H:%M:%SZ)" --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 60 --statistics Average --query 'sort_by(Datapoints,&Timestamp)[].[Timestamp,Average]' --output text
```

> ⚠️ **الـ bottleneck اللي جاي: الداتابيز.** كل task فيه PHP-FPM workers وكل worker ممكن يفتح connection. `max_connections` بتاع `db.t4g.micro` صغير (بيتحسب من الـ RAM). احسب: (`PHP_FPM_PM_MAX_CHILDREN` بتاع الـ image) × `autoscaling_max` مقابل `max_connections` (`SHOW VARIABLES LIKE 'max_connections'` من ECS Exec). لو أكبر، الـ scale-out هيحوّل المشكلة من CPU لـ `Too many connections` — شوف [49](49-redis-sessions-cache.md) للـ sessions/cache.

## 7) التحقق (Verify)

```bash
aws application-autoscaling describe-scalable-targets --service-namespace ecs \
  --query 'ScalableTargets[].{id:ResourceId,min:MinCapacity,max:MaxCapacity,suspended:SuspendedState}'
aws application-autoscaling describe-scaling-policies --service-namespace ecs \
  --query 'ScalingPolicies[].{name:PolicyName,metric:TargetTrackingScalingPolicyConfiguration.PredefinedMetricSpecification.PredefinedMetricType,target:TargetTrackingScalingPolicyConfiguration.TargetValue}'
aws application-autoscaling describe-scaling-activities --service-namespace ecs \
  --resource-id service/student-app-lab/student-app-lab-app --max-items 10 \
  --query 'ScalingActivities[].[StartTime,StatusCode,Description]' --output table
```

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر | المتوقع |
|---|---|---|
| مفيش مساحة | `terraform apply -var autoscaling_max=2` + RATE=5 | الـ CPU ~100%، latency عالية، `dropped_iterations` في k6، الـ activities: `desired count already at max` تقريباً |
| Flapping | (console) cooldowns 0 + load متقطع (`DURATION=2m` مرتين بفاصل دقيقتين) | scale out/in متكرر — تكلفة + tasks بتتقفل وهي لسه بتسخن |
| Turn off scale-in | (console) ✅ Turn off scale-in على الـ CPU policy | بعد الـ load الـ count يفضل عالي لو الـ request policy كمان مش بتصغّر — scale-in محتاج **كل** الـ policies |
| Scaling أثناء deploy | ابدأ RATE=5 ثم `deploy-ecs.yml strategy=rolling` | ECS بيطبّق الـ desired الجديد؛ مع 6 tasks و max 200% ممكن تشوف 12 task مؤقتاً (Fargate quota/IPs) |
| Request policy مع native B/G | stack بـ `deployment_strategy=BLUE_GREEN` | الـ policy مش موجودة أصلاً (الـ module شالها) — CPU بس |
| بلا token | `k6 run ... ` من غير `LAB_TOKEN` | 403 على كل `/sre-lab/cpu` → `http_req_failed{scenario:cpu}` > 5% → k6 exit 99، ومفيش scaling (مفيش CPU) |

## 9) الرجوع (Rollback)

```bash
aws ecs update-service --cluster student-app-lab --service student-app-lab-app --desired-count 2 >/dev/null   # يدوي (الـ autoscaling ممكن يغيّره بعدك)
cd infra/terraform/stacks/50-ecs-fargate && terraform apply      # يرجّع min/max/policies من الـ code
```

لو حاجة بايظة وعايز تجمّد الـ count مؤقتاً (incident): `aws application-autoscaling register-scalable-target --service-namespace ecs --scalable-dimension ecs:service:DesiredCount --resource-id service/student-app-lab/student-app-lab-app --suspended-state DynamicScalingInSuspended=true,DynamicScalingOutSuspended=true,ScheduledScalingSuspended=true` — وارجع `false` بعدها.

## 10) المسح (Teardown) ⚠️

- اتأكد إن k6 وقف وإن الـ count نزل لـ 2 (أو استنى الـ scale-in).
- رجّع أي تعديل console على الـ policies (`terraform apply`).
- الـ stack: [51 §10](51-ecs-fargate-terraform.md).

## 11) التكلفة (Cost)

| Resource | السعر التقريبي (تقريبي — راجع صفحة الأسعار) |
|---|---|
| Task زيادة (Spot، 0.5 vCPU/1 GB) | ~$0.008/ساعة؛ on-demand ~$0.025/ساعة |
| Drill 15 دقيقة + 15 scale-in بـ +2–4 tasks | أقل من 5 سنت |
| Application Auto Scaling | مجاني |
| Target tracking alarms | ~$0.10/alarm/شهر (4 alarms للـ 2 policies) |
| Container Insights enhanced | بيزيد مع عدد الـ tasks (metrics per task) |
| k6 من GitHub Actions | مجاني للـ public repo |

## 12) أسئلة Interview

<details><summary>Target tracking على CPU مقابل request count — تختار إيه؟</summary>

CPU: بيعكس الشغل الفعلي لو الـ app CPU-bound، بس متأخر (1-min metrics) ومش بيشوف I/O-bound load (DB waits). Request count per target: leading indicator أوضح للـ web، مستقل عن كفاءة الكود، بس محتاج تعرف throughput الـ task الآمن (load test) ومرتبط بـ TG واحد. عملياً الاتنين: scale-out لو أي واحد قال، scale-in لو الاتنين موافقين — زي الـ module.

</details>

<details><summary>ليه scale-out cooldown 60 و scale-in 180؟ وإيه علاقته بالـ alarms؟</summary>

الـ asymmetry مقصود: capacity ناقصة بتكسر الـ SLO فوراً، capacity زيادة بتكلّف فلوس بس. الـ target tracking alarms نفسها asymmetric (high ≈ 3 دقايق، low ≈ 15). الـ out cooldown القصير بيسمح بخطوة تانية لو الأولى مكفتش؛ الـ in cooldown الأطول بيمنع flapping ويدّي الـ metrics وقت تستقر بعد إزالة task.

</details>

<details><summary>الـ service بياخد ~5 دقايق عشان يضيف capacity. إزاي تقصّرها؟</summary>

قلّل كل حلقة: metric أسرع (high-resolution custom metric أو step scaling بـ alarm أسرع)، image أصغر (pull أسرع، [11](11-image-hardening.md))، boot أسرع (`optimize` و opcache)، health check أسرع (interval 10/threshold 2 موجود)، و headroom أكبر (min أعلى أو target أقل مثلاً 40%). وللـ load المتوقع: scheduled scaling أو predictive scaling قبل الـ peak.

</details>

<details><summary>إيه الفرق بين `disable_scale_in` و task scale-in protection؟</summary>

`disable_scale_in` على مستوى الـ policy: الـ policy دي مبتصغّرش خالص (حد تاني يصغّر — policy تانية، أو scheduled، أو إنسان). Task scale-in protection على مستوى task معين (`UpdateTaskProtection`، بـ expiry): الـ task ده ميتشالش في scale-in أو deployment لحد ما الـ protection تخلص — مفيد لـ worker شغال في job طويل.

</details>

<details><summary>إزاي تحسب min/max للـ service؟</summary>

Min: الـ baseline load ÷ throughput الآمن للـ task (من load test عند الـ target utilization) + redundancy (≥ 2، واحد في كل AZ) + headroom يغطي وقت الـ scale-out (~5 دقايق من نمو الـ traffic). Max: سقف تكلفة + أقل من bottleneck تحت (DB connections، quotas، IPs في الـ subnets) — لو الـ max أكبر من اللي الداتابيز تستحمله، إنت بتنقل الـ outage مش بتمنعه.

</details>

<details><summary>الـ k6 test عدّى بس المستخدمين اشتكوا وقت الـ peak. إيه اللي ممكن يكون فاتك؟</summary>

الـ test كان steady-state مش spike (الـ scale-out بياخد دقايق)، أو بيضرب endpoint واحد (cache/DB patterns مختلفة)، أو من region/IP واحد، أو بيانات قليلة (`LOADTEST_USERS`)، أو الـ thresholds على المتوسط مش الـ tail. الحل: spike/soak tests، user journeys واقعية، data volume واقعي، وthresholds = الـ SLOs (p95/p99 + error rate) — زي `load.js` و `spike.js` ([74](74-load-testing-k6.md)).

</details>

## 13) Checklist

- [ ] قريت `autoscaling.tf` وعارف ليه الـ request policy للـ ROLLING بس
- [ ] حسبت الـ capacity لـ RATE=5 و RATE=10 بالـ target 50%
- [ ] شغّلت `autoscale-cpu.js` وشفت الـ scale-out والـ scale-in في الـ activities
- [ ] خبطت في الـ max وفهمت القرار اللي بعده
- [ ] شغّلت `load.js` بالـ SLO thresholds أثناء الـ scaling
- [ ] عرفت فين الـ metrics (AWS/ECS، Container Insights، ALB، RDS)
- [ ] رجّعت الـ count والإعدادات
