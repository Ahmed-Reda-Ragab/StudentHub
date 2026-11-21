# 48 — Autoscaling تحت load

> **الهدف في سطر:** تشوف الـ ASG بيكبر ويصغر لوحده تحت load حقيقي: target tracking على **CPU** و **ALBRequestCountPerTarget** (اللي stack 40 مفعّلهم)، الـ warmup، ليه الـ scale-in أبطأ من الـ scale-out، وتضرب [`autoscale-cpu.js`](../../../loadtest/k6/autoscale-cpu.js) على `/sre-lab/cpu` بالـ `SRE_LAB_TOKEN` وانت عارف تبص على إيه — وبعدين **Spot** بـ mixed instances و capacity rebalancing والتكلفة.
> **المستوى:** Advanced · **الوقت:** ~3 ساعات · **التكلفة التقريبية:** نفس [42](42-alb-asg-launch-template.md) + الـ instances اللي الـ scaling بيضيفها (سنتات لكل تجربة)
> **بيعتمد على:** [42](42-alb-asg-launch-template.md) · [12 — SRE lab endpoints و k6](12-sre-lab-endpoints-and-local-observability.md) · [74 — Load testing](74-load-testing-k6.md) · **الملفات في الـ repo:** [`modules/asg-app/main.tf`](../../../infra/terraform/modules/asg-app/main.tf) · [`modules/asg-app/variables.tf`](../../../infra/terraform/modules/asg-app/variables.tf) · [`stacks/40-ec2-alb-asg/variables.tf`](../../../infra/terraform/stacks/40-ec2-alb-asg/variables.tf) · [`loadtest/k6/autoscale-cpu.js`](../../../loadtest/k6/autoscale-cpu.js) · [`loadtest/k6/load.js`](../../../loadtest/k6/load.js) · [`loadtest/k6/README.md`](../../../loadtest/k6/README.md) · [`app/Http/Controllers/SreLabController.php`](../../../app/Http/Controllers/SreLabController.php) · [`observability/fis/README.md`](../../../observability/fis/README.md)

## 1) الفكرة (Concepts)

| المصطلح | المعنى |
|---|---|
| Target tracking | "خلّي الـ metric ده حوالين الرقم ده" — AWS بيعمل ويدير الـ CloudWatch alarms لوحده (**متعدلهمش**) |
| `ASGAverageCPUUtilization` | متوسط CPU الـ group (EC2 metric) |
| `ALBRequestCountPerTarget` | requests **في الدقيقة** لكل target في TG معين (`resource_label = <alb_suffix>/<tg_suffix>`) |
| أكتر من policy | **scale-out لو أي واحدة** عايزة · **scale-in بس لو كلهم** موافقين (availability أولاً) |
| Instance warmup | الـ instance الجديدة مش بتتحسب في الـ metric لحد ما تخلص (هنا `default_instance_warmup = 120`)، وفي الفترة دي الـ scale-in متوقف |
| Cooldown | خاص بالـ simple scaling؛ target tracking بيعتمد على الـ warmup |
| Detailed monitoring | EC2 metrics كل دقيقة بدل 5 (بفلوس). في stack 40: `detailed_monitoring` (default **`false`** → `monitoring.enabled` في الـ LT) |
| Burstable credits | `t3` على `cpu_credits = "standard"`: لما الـ credits تخلص، الـ CPU بيتخنق على الـ baseline (`t3.micro` ≈ 10% لكل vCPU) |
| Spot | capacity فاضية بخصم كبير، ممكن تتسحب بإنذار **دقيقتين** |
| Mixed instances policy | ASG بيخلط types و On-Demand/Spot (`price-capacity-optimized`) |
| Capacity Rebalancing | الـ ASG يبدأ instance بديلة لما AWS يبعت "rebalance recommendation" قبل الـ interruption نفسه. في الـ module: `capacity_rebalance = var.spot_enabled` (بتشتغل لوحدها مع Spot) |

### 1.1 اللي stack 40 عامله ([`modules/asg-app/main.tf`](../../../infra/terraform/modules/asg-app/main.tf))

| Policy | الاسم | الإعداد (stack 40 default) |
|---|---|---|
| CPU | `student-app-lab-blue-cpu-50` | `ASGAverageCPUUtilization` = `cpu_target` (50) |
| Requests | `student-app-lab-blue-req-1000` | `ALBRequestCountPerTarget` = `requests_per_target` (1000/دقيقة/instance) — `enable_request_scaling = true` في الـ stack (default الـ module `false`) |
| Capacity | | `min_size 1` · `max_size 4` · `desired 2` (أول مرة؛ `ignore_changes = [desired_capacity]`) — **لكل لون** |
| Warmup / grace | | 120 / 120 |
| Group metrics | | `GroupDesiredCapacity`، `GroupInServiceInstances`، `GroupPendingInstances`، `GroupTerminatingInstances`، `GroupTotalInstances` (1-min، ببلاش) |

تعليق الـ module: "Requests per target is the better signal for a web tier: it scales before CPU saturates". وفيه سبب تاني عملي: ALB metrics **كل دقيقة** ببلاش، بينما CPU بالـ default **كل 5 دقايق** (`detailed_monitoring = false`) → الـ CPU policy أبطأ بكتير في الرد. `detailed_monitoring = true` بيخلّيها كل دقيقة (الـ module بيقول "~5x faster") مقابل تكلفة لكل instance — تمرين §5.1.

### 1.2 الحسبة قبل ما تضرب (من header الـ script)

```text
CPU demand (vCPU) = RATE × CPU_MS / 1000        RATE=10, CPU_MS=200 → 2 vCPU مشغولين طول الوقت
capacity needed   = demand / (vCPU per instance × target)
t3.micro (2 vCPU)، target 50% → 2 / (2 × 0.5) = 2 instances   ← على الورق
```

⚠️ **فخ الـ burstable:** `t3.micro` على `standard` credits بتشتغل فوق الـ baseline بس طول ما عندها credits. تحت load مستمر الـ credits بتخلص → الـ CPU بيتخنق، الـ latency بتطلع، و `CPUUtilization` ممكن **ميطلعش** بالشكل اللي تتوقعه → الـ CPU policy تتأخر أو متتحركش. عشان كده: راقب `CPUCreditBalance`، وابدأ بـ RATE صغير (`RATE=4 CPU_MS=200` ≈ 0.8 vCPU)، وفي اختبار جاد استخدم type مش burstable أو `unlimited`. الـ module اختار `standard` عشان "no surprise charges during CPU load tests".

## 2) المعمارية (Architecture)

```text
 k6 (laptop/CI) ── constant-arrival-rate RATE req/s ──► ALB ──► TG blue ──► instances (PHP-FPM يحرق CPU_MS لكل request)
     └─ whoami: /sre-lab/version كل ثانية → "instance serving traffic: <hostname>" لما instance جديدة تاخد traffic
                                              │                         │
                       RequestCountPerTarget (1-min, ALB)     CPUUtilization (5-min, EC2 basic)
                                              ▼                         ▼
                 TargetTracking alarms (managed by AWS)  ── AlarmHigh → scale-out ──► desired++ (≤ max 4)
                                                          └─ AlarmLow (كل الـ policies) → scale-in (أبطأ، بعد الـ warmup)
                                              │
                 new instance: boot (~1–2 min) → healthy (20s) → warmup 120s → داخلة في الـ metric
```

## 3) المتطلبات (Prerequisites)

- [ ] stack 40 شغال، الـ migrations والـ seed ([42 §6](42-alb-asg-launch-template.md)).
- [ ] `k6` على جهازك (`winget install k6 --source winget` أو [README](../../../loadtest/k6/README.md)) — أو [`perf-gate.yml`](../../../.github/workflows/perf-gate.yml).
- [ ] `SRE_LAB_ENABLED=true` (default الـ stack) والـ token.
- [ ] الـ max_size (4) والـ EC2 vCPU quota كفاية.

```bash
cd infra/terraform/stacks/40-ec2-alb-asg
export AWS_REGION=us-east-1
APP_URL=$(terraform output -raw app_url)
TOKEN=$(terraform output -raw sre_lab_token)
curl -s -H "X-Lab-Token: $TOKEN" "$APP_URL/sre-lab/cpu?ms=200" | jq .     # بيحرق 200ms CPU (cap SRE_LAB_MAX_CPU_MS=5000)
aws autoscaling describe-policies --auto-scaling-group-name student-app-lab-blue \
  --query 'ScalingPolicies[].{name:PolicyName,type:PolicyType,metric:TargetTrackingConfiguration.PredefinedMetricSpecification.PredefinedMetricType,target:TargetTrackingConfiguration.TargetValue,alarms:Alarms[].AlarmName}' --output json
```

## 4) الطريقة الأولى: AWS Console (يدوي)

1. **EC2 → Auto Scaling groups → `student-app-lab-blue` → Automatic scaling** → شوف الـ 2 policies. افتح **CloudWatch → Alarms** → فلتر `TargetTracking-student-app-lab-blue` → هتلاقي لكل policy `AlarmHigh` و `AlarmLow` (لاحظ عدد الـ datapoints والـ period في كل واحد — الـ Low أطول بكتير = scale-in محافظ).
2. (تجربة في الـ console على ASG بتاع الـ console من [42](42-alb-asg-launch-template.md)): **Automatic scaling → Create dynamic scaling policy** → **Target tracking scaling** → Metric type **Application Load Balancer request count per target** → Target group `student-app-lab-blue` → Target value **1000** → Instance warmup **120** → ⬜ Disable scale in → **Create**.
3. **Monitoring** tab → **Auto Scaling** و **EC2** — الـ group metrics (1-min) و CPU.
4. Detailed monitoring (على ASG الـ console): **Launch templates → Modify template (new version)** → Advanced → Detailed CloudWatch monitoring: **Enable** → instance refresh. على stack 40 متعملهاش بإيدك (drift) — استخدم `detailed_monitoring = true` (§5.1).
5. **Scheduled actions → Create scheduled action** (مثال): `desired 3` كل يوم 09:00 Africa/Cairo، `desired 1` 23:00 — الـ scale المتوقع قبل الـ peak بدل ما تستنى الـ metric.

## 5) الطريقة التانية: Infrastructure as Code (Terraform)

| Stack 40 variable | Default | Module input |
|---|---|---|
| `min_size` / `max_size` / `desired_capacity` | 1 / 4 / 2 | `min` / `max` / `desired` |
| `cpu_target` | 50 | `cpu_target` (+ `enable_cpu_scaling = true` default) |
| `enable_request_scaling` | `true` | `enable_request_scaling` (+ precondition: `alb_arn_suffix` و `target_group_arn_suffix`) |
| `requests_per_target` | 1000 | `requests_per_target` |
| `spot_enabled` | `false` | mixed instances policy |
| `spot_instance_types` | `[]` | `override` لكل type (فاضي = `[instance_type]`) |
| — | | `capacity_rebalance = var.spot_enabled` (أوتوماتيك مع Spot) |
| `detailed_monitoring` | `false` | `monitoring.enabled` في الـ LT (CPU كل دقيقة، بفلوس) |
| `instance_type` | `t3.micro` | |
| — (مش متعرّض في الـ stack) | | `on_demand_base_capacity = 0`، `on_demand_percentage_above_base = 0` (= **كله Spot** مع `spot_enabled`)، `instance_warmup = 120`، `cpu_credits = "standard"` |

### 5.1 تمرين: CPU كل دقيقة

```bash
# terraform.tfvars:  detailed_monitoring = true
terraform plan -out=tfplan      # ~ aws_launch_template (monitoring) → version جديدة → الـ instance_refresh block بيبدّل الـ fleet
terraform apply tfplan
```

كرر §6.1 وقارن الوقت من بداية الـ load لأول `AlarmHigh` بتاع الـ CPU policy قبل وبعد. رجّعها `false` بعد التجربة (التكلفة لكل instance شهرياً).

### 5.2 On-Demand base مع Spot (مش متعرّض في stack 40)

الـ module عنده `on_demand_base_capacity` و `on_demand_percentage_above_base`، بس stack 40 مبيبعتهمش. عشان base On-Demand = 1 (الحد الأدنى دايماً On-Demand والباقي Spot) ضيف السطرين دول في `module "asg_blue"` (و `module "asg_green"`) في [`main.tf`](../../../infra/terraform/stacks/40-ec2-alb-asg/main.tf) جنب `spot_enabled`:

```hcl
  on_demand_base_capacity         = 1
  on_demand_percentage_above_base = 0
```

(أو اعمله variables في الـ stack بنفس النمط.) Terraform هيعدّل الـ `mixed_instances_policy` والـ ASG هيبدّل instance لـ On-Demand.

### 5.3 ضبط الـ targets

```bash
# مثال: target أعلى للـ CPU، requests أقل (يحس أسرع)، max أكبر
# terraform.tfvars:
#   cpu_target          = 60
#   requests_per_target = 600
#   max_size            = 6
terraform plan -out=tfplan      # ~ aws_autoscaling_policy (الاسم فيه الرقم → replace) + max_size
terraform apply tfplan
```

## 6) الـ Deploy — load test وانت بتتفرّج

### 6.1 الـ CPU drill (`autoscale-cpu.js`)

Terminal 1 — الـ load (ابدأ تحت الـ capacity وطلّعه):

```bash
k6 run -e BASE_URL="$APP_URL" -e LAB_TOKEN="$TOKEN" -e RATE=4 -e CPU_MS=200 -e DURATION=20m loadtest/k6/autoscale-cpu.js
```

Terminal 2 — إيه اللي بيحصل (كل 30 ثانية):

```bash
while :; do
  date +%T
  aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names student-app-lab-blue \
    --query 'AutoScalingGroups[0].{desired:DesiredCapacity,inService:length(Instances[?LifecycleState==`InService`]),pending:length(Instances[?LifecycleState!=`InService`])}' --output text
  aws autoscaling describe-scaling-activities --auto-scaling-group-name student-app-lab-blue --max-items 1 \
    --query 'Activities[0].[StartTime,StatusCode,Cause]' --output text | cut -c1-200
  sleep 30
done
```

Terminal 3 — الـ metrics (أو الـ dashboard `terraform output -raw dashboard_url`):

```bash
ASG=student-app-lab-blue; S=$(date -u -d '-30 min' +%FT%TZ); E=$(date -u +%FT%TZ)
for M in CPUUtilization CPUCreditBalance; do
  echo "== $M"; aws cloudwatch get-metric-statistics --namespace AWS/EC2 --metric-name $M \
    --dimensions Name=AutoScalingGroupName,Value=$ASG --start-time $S --end-time $E --period 300 --statistics Average \
    --query 'sort_by(Datapoints,&Timestamp)[].[Timestamp,Average]' --output text
done
```

| تبص على إيه | ليه |
|---|---|
| k6: `instance serving traffic: <hostname>` | اللحظة اللي الـ capacity الجديدة بقت بتاخد traffic فعلاً |
| k6: `http_req_duration{name:sre-lab.cpu}` p95 و `dropped_iterations` | الـ saturation: الـ requests بتستنى PHP-FPM workers (الـ script بيقول pm.max_children بيحدد التوازي) |
| k6: `http_req_failed{scenario:cpu}` < 5% | threshold الـ drill (مش الـ SLO) |
| ASG activity: `Cause` | أنهي alarm عمل الـ scale (CPU ولا requests) |
| `CPUCreditBalance` | لو بينزل لـ 0 → الأرقام اللي جاية مش بتعبّر عن الـ demand |
| ALB `HTTPCode_ELB_5XX` / `TargetResponseTime` | 502/504 لما الـ instances مخنوقة أو timeout |
| `GroupInServiceInstances` بعد ما الـ test يخلص | الـ scale-in بياخد وقت أطول بكتير (استنى ~15+ دقيقة) |

### 6.2 الـ requests drill (`load.js` — traffic واقعي)

```bash
k6 run -e BASE_URL="$APP_URL" -e LOADTEST_USERS=20 -e VUS=60 -e DURATION=15m -e P95_MS=300 loadtest/k6/load.js
```

~50 req/s (Little's law: VUS / (think 1s + response)) على instance-ين = ~1500 req/دقيقة/target > 1000 → الـ **requests policy** بتعمل scale-out حتى لو الـ CPU لسه تحت 50%. ده المقصود بـ "scales before CPU saturates". قارن الـ `Cause` في الـ activity بين 6.1 و 6.2.

## 7) التحقق (Verify)

```bash
aws autoscaling describe-scaling-activities --auto-scaling-group-name student-app-lab-blue --max-items 10 \
  --query 'Activities[].[StartTime,EndTime,StatusCode,Description]' --output table
aws cloudwatch describe-alarms --alarm-name-prefix TargetTracking-student-app-lab-blue \
  --query 'MetricAlarms[].[AlarmName,StateValue,MetricName,Period,EvaluationPeriods]' --output table
```

سجّل timeline: بداية الـ load → أول AlarmHigh → launch → InService → `instance serving traffic` → p95 رجع → نهاية الـ load → أول scale-in. ده الرقم اللي بتظبط بيه الـ `min_size` والـ targets (والـ golden AMI في [43](43-golden-ami-packer.md) بيقصّر جزء الـ boot).

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر | المتوقع |
|---|---|---|
| الـ max صغير | `terraform apply -var max_size=2` ثم 6.1 بـ `RATE=10` | الـ ASG وقف عند 2؛ الـ activity بيقول desired = max؛ k6: latency تطلع و `dropped_iterations`. الـ autoscaling مش بيحل capacity planning |
| Spike أسرع من الـ boot | `k6 run -e BASE_URL="$APP_URL" -e LOADTEST_USERS=20 -e VUS=5 -e SPIKE_VUS=80 loadtest/k6/spike.js` | الـ spike بيخلص قبل ما الـ instances الجديدة تبقى جاهزة → errors في الأول. الحلول: min أعلى، scheduled/predictive scaling، golden AMI |
| CPU stress من غير traffic | FIS بـ [`ec2-cpu-stress.json`](../../../observability/fis/ec2-cpu-stress.json) (بيستهدف `student-app-lab-blue` — [75](75-chaos-engineering-fis.md)) | الـ CPU policy بتعمل scale-out، والـ requests policy لأ — الإشارة "مش حقيقية" (noisy neighbour / cron) |
| Spot interruption | §8.1 | |

### 8.1 Spot

```bash
# terraform.tfvars:
#   spot_enabled        = true
#   spot_instance_types = ["t3.micro", "t3a.micro", "t2.micro"]
terraform plan -out=tfplan     # ~ aws_autoscaling_group: launch_template → mixed_instances_policy، capacity_rebalance = true (+ instance refresh)
terraform apply tfplan
aws ec2 describe-instances --filters Name=tag:aws:autoscaling:groupName,Values=student-app-lab-blue Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].[InstanceId,InstanceType,InstanceLifecycle,Placement.AvailabilityZone]' --output table
```

- `InstanceLifecycle = spot` لكل الـ instances (الـ module: `on_demand_base_capacity = 0` و `on_demand_percentage_above_base = 0`). في production: base On-Demand (مثلاً 1) والباقي Spot — §5.2.
- `price-capacity-optimized` بيختار الـ pools الأقل احتمال interruption بسعر كويس؛ **كل ما الـ types أكتر، الـ interruptions أقل** (`t3a`، `t2`، `m`…). t2.micro أبطأ وبـ credits مختلفة — خليها آخر اختيار.
- **Capacity Rebalancing**: الـ module بيفعّلها مع Spot (`capacity_rebalance = var.spot_enabled`) → الـ ASG بيبدأ بديلة أول ما يجيله rebalance recommendation (قبل إنذار الدقيقتين). اتأكد: `aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names student-app-lab-blue --query 'AutoScalingGroups[0].CapacityRebalance'` = `true`. التمن: ممكن تشوف instances بتتبدّل "من غير سبب" (recommendation مش interruption) وفترة قصيرة فيها instance زيادة.
- محاكاة الـ interruption: AWS FIS action `aws:ec2:send-spot-instance-interruptions` (template زي [`observability/fis/`](../../../observability/fis/README.md)، ومن **EC2 → Spot Requests → Initiate interruption** في الـ console) → الإنذار بدقيقتين → الـ ASG بيعمل deregister (draining 30s < 120s) ويبدّل. قيس بالـ probe.

## 9) الرجوع (Rollback)

```bash
# رجّع الإعدادات (امسح التعديلات من terraform.tfvars) ثم:
terraform apply
# لو الـ group لسه كبير بعد التجربة ومش عايز تستنى الـ scale-in:
aws autoscaling set-desired-capacity --auto-scaling-group-name student-app-lab-blue --desired-capacity 2
```

## 10) المسح (Teardown) ⚠️

- اقفل k6 (Ctrl+C — بيطبع الـ summary).
- اتأكد إن الـ desired رجع (الـ scale-in أو `set-desired-capacity`)، و `spot_enabled = false` لو مش هتكمّل بيه.
- امسح أي FIS experiment template / scheduled action / policy عملتها بإيدك.
- الـ students اللي k6 عملها: code `k6-…`، note `created by k6` (من الـ README) — مش مشكلة في الـ lab.
- الـ stack: [42 §10](42-alb-asg-launch-template.md).

## 11) التكلفة (Cost)

| Resource | السعر التقريبي (us-east-1 — تقريبي، راجع صفحة الأسعار) |
|---|---|
| Instance زيادة أثناء الـ scale-out (`t3.micro`) | ~$0.0104/ساعة + IPv4 ~$0.005/ساعة (بالثانية، أقل حاجة 60s) |
| Spot | خصم متغيّر (غالباً 60–70%+) — بص على Spot pricing history |
| Detailed monitoring (`detailed_monitoring = true`) | لكل instance شهرياً (بيتحاسب بالـ metrics) — default مقفول |
| CloudWatch alarms بتاعة الـ target tracking | managed (alarms عادية بتتحاسب) |
| `t3` `unlimited` (لو غيّرته) | CPU credits زيادة بتتحاسب لو المتوسط عدّى الـ baseline |
| FIS | ~$0.10/action-minute |

## 12) أسئلة Interview

<details><summary>CPU ولا requests per target للـ web tier؟</summary>

requests per target بيعكس الـ demand مباشرة وبيتحرك قبل الـ saturation، و ALB metrics كل دقيقة ببلاش؛ لكنه بيفترض إن كل request بنفس التكلفة (لو الـ mix اتغير، الرقم الصح اتغير). CPU بيعكس الـ saturation الفعلية بس متأخر (و 5-min من غير detailed monitoring، ومضلل مع burstable). الاتنين مع بعض = scale-out لو أي واحد، scale-in لو الاتنين — وده اللي stack 40 عامله. الرقم نفسه (1000) بيتجاب من breakpoint test ([74](74-load-testing-k6.md)).

</details>

<details><summary>ليه الـ scale-in أبطأ من الـ scale-out؟</summary>

عشان الـ availability: إضافة capacity غلط بتكلّف فلوس شوية، وشيلها غلط بيكلّف errors. target tracking بيستخدم alarm للـ scale-in بـ datapoints أكتر، ومبيعملش scale-in وفيه instances لسه في الـ warmup، وبيقرّب لتحت (مش هيشيل instance لو هتطلّع الـ metric فوق الـ target). وده بيمنع الـ flapping.

</details>

<details><summary>Warmup، grace period، cooldown — الفرق؟</summary>

Grace period: حماية الـ instance الجديدة من الـ **health checks** وهي بتبوت. Warmup: الـ instance مش بتتحسب في الـ **metric** (عشان متخفضش المتوسط وهي فاضية وتأخر الـ scale-out الجاي، أو تسبب overshoot) — وبيتستخدم برضه كـ pacing في الـ instance refresh. Cooldown: فترة بعد simple scaling مفيش scaling تاني — قديم، target tracking مش محتاجه.

</details>

<details><summary>إزاي تتعامل مع traffic spike أسرع من الـ boot؟</summary>

Headroom (min أعلى أو target أقل)، scheduled scaling للـ peaks المعروفة، predictive scaling، تقليل الـ boot (golden AMI، image أصغر، pre-pull)، warm pools (instances متجهزة stopped)، وعلى مستوى الـ app: rate limiting / queueing / caching عشان الـ degradation يبقى graceful. والـ ALB نفسه بيحتاج pre-warming لـ spikes ضخمة جداً.

</details>

<details><summary>Spot على web tier stateless — إزاي تعملها صح؟</summary>

Mixed instances: base On-Demand للحد الأدنى، والباقي Spot من **pools كتير** (types و AZs) بـ `price-capacity-optimized`، Capacity Rebalancing، deregistration delay أقل من الدقيقتين، الـ app stateless (sessions في DB/Redis — [49](49-redis-sessions-cache.md))، و graceful shutdown. ولا تعتمد على Spot للـ baseline اللي لازم يبقى موجود. وجرّب interruptions بـ FIS بانتظام.

</details>

<details><summary>إيه مشاكل الـ burstable instances مع autoscaling؟</summary>

في `standard` الـ CPU بيتخنق على الـ baseline لما الـ credits تخلص → latency وحشة و CPU metric مش بيعبّر عن الـ demand → scaling متأخر أو غلط. في `unlimited` مفيش خنق بس فيه فلوس زيادة غير متوقعة تحت load مستمر. للـ production اللي عليه load ثابت: types مش burstable (c/m)، أو راقب `CPUCreditBalance` و `CPUSurplusCreditsCharged`.

</details>

## 13) Checklist

- [ ] فهمت الـ 2 policies والـ alarms اللي AWS عملها، وليه الـ Low أبطأ
- [ ] شغّلت `autoscale-cpu.js` وسجّلت timeline الـ scale-out والـ scale-in
- [ ] شغّلت `load.js` وشفت الـ requests policy بتسبق الـ CPU
- [ ] راقبت `CPUCreditBalance` وفهمت فخ الـ burstable
- [ ] جرّبت max صغير و spike
- [ ] (اختياري) Spot + capacity rebalancing + interruption drill
- [ ] رجّعت كل الإعدادات
