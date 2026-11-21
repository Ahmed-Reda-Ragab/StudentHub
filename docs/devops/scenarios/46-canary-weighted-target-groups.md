# 46 — Canary بـ weighted target groups + alarm rollback

> **الهدف في سطر:** تدّي الإصدار الجديد (green) نسبة صغيرة من الـ traffic بأوزان الـ ALB (10 → 25 → 50 → 100)، وتخلّي **CloudWatch alarm** هو اللي يقرر بين كل خطوة (`CANARY_ALARM_NAME`)، وتجرّب bad release بـ `SRE_FAULT_ERROR_RATE` على green يتعمله **abort أوتوماتيك** — وتفهم الـ stickiness trade-off، وليه الـ detection هنا بالدقايق مش بالثواني (ALB metrics + alarm window)، وإزاي ده يتقارن بـ [24](24-canary-single-host.md) و ECS/Argo.
> **المستوى:** Advanced · **الوقت:** ~3 ساعات · **التكلفة التقريبية:** نفس [45](45-bluegreen-two-asgs.md) (لونين شغالين)
> **بيعتمد على:** [45](45-bluegreen-two-asgs.md) · [24 — Canary على سيرفر واحد](24-canary-single-host.md) · [73 — SLO و burn rate](73-slo-error-budget-burn-rate.md) · **الملفات في الـ repo:** [`.github/workflows/deploy-asg.yml`](../../../.github/workflows/deploy-asg.yml) · [`modules/alb/main.tf`](../../../infra/terraform/modules/alb/main.tf) · [`modules/observability/main.tf`](../../../infra/terraform/modules/observability/main.tf) · [`app/Http/Middleware/InjectFaults.php`](../../../app/Http/Middleware/InjectFaults.php) · [`loadtest/k6/canary-watch.js`](../../../loadtest/k6/canary-watch.js) · [`deploy/scripts/probe.sh`](../../../deploy/scripts/probe.sh)

## 1) الفكرة (Concepts)

Blue/green ([45](45-bluegreen-two-asgs.md)) بيحوّل 100% مرة واحدة: لو الـ bug بيظهر تحت traffic حقيقي بس، **كل** المستخدمين بيشوفوه لحد ما الـ alarm يصحى (~5 دقايق). الـ **canary** بيصغّر الـ blast radius: 10% من الـ requests للجديد، نستنى الـ alarm، نكبّر أو نرجع.

| المصطلح | المعنى |
|---|---|
| Step | وزن green (و blue = 100 − الوزن) لمدة `step_seconds` |
| Gate | الـ alarms اللي بتتراقب في الخطوة: `CANARY_ALARM_NAME` + `student-app-<env>-<target>-unhealthy-hosts` |
| Abort | `route_to live 100` + الـ job يفشل (`outcome=aborted`) |
| Target group stickiness | الـ ALB بيحط cookie `AWSALBTG` يثبّت الـ client على **TG** (مش target) لمدة `duration` (1 ثانية – 7 أيام) |
| Detection latency | الوقت من أول request بايظ لحد قرار الـ abort |

### 1.1 الـ gate بالأرقام — الـ alarm الافتراضي على مستوى الـ ALB كله

`CANARY_ALARM_NAME` default = `student-app-<env>-alb-5xx-ratio` ([observability](../../../infra/terraform/modules/observability/main.tf)): `(HTTPCode_Target_5XX + HTTPCode_ELB_5XX) / RequestCount` على **الـ ALB كله**، period **300s**، evaluation 1، threshold **1%**، `notBreaching` لو مفيش traffic.

نسبة الـ errors اللي الـ alarm بيشوفها ≈ **وزن الـ canary × error rate بتاع الـ canary**:

| وزن green | error rate green | اللي الـ alarm شايفه | النتيجة |
|---|---|---|---|
| 10% | 50% (`SRE_FAULT_ERROR_RATE=0.5`) | 5% | ALARM → abort عند 10% ✅ |
| 10% | 5% | 0.5% | **يعدّي** الخطوة دي ❌ |
| 25% | 5% | 1.25% | ALARM عند 25% |
| 10% | 100% بس على صفحة نادرة | ≈ 0 | ممكن يوصل 100% |

يعني الـ gate ده **بيخفّف** إشارة الـ canary بالـ baseline. الـ canary analysis الصح بيقارن **الـ canary بالـ baseline** — per-TG alarm (§5.3) أو metrics بالـ `color` من Prometheus ([71](71-metrics-dashboards.md))، زي ما [24](24-canary-single-host.md) بيقرا `/metrics` بتاع الـ canary slot بس.

### 1.2 الـ detection latency (ليه `step_seconds` default = 300)

ALB metrics بتتنشر كل **60 ثانية** (مع تأخير دقيقة–اتنين)، والـ alarm بيبص على window **5 دقايق** → أول ALARM بعد ~2–6 دقايق من بداية الـ errors. والـ workflow بيسأل `describe-alarms` كل 15 ثانية. فالـ step لازم ≥ window الـ alarm + تأخير النشر، وإلا هتكبّر قبل ما الـ alarm يلحق يشوف الخطوة اللي فاتت. التمن: canary بـ 4 خطوات = ~20 دقيقة release. [24](24-canary-single-host.md) بيحكم في 30 ثانية لأنه بيقرا العدادات من الـ slot مباشرة.

### 1.3 الـ stickiness — trade-off حقيقي

| | من غير stickiness (default) | `stickiness_duration = 300` |
|---|---|---|
| تجربة المستخدم | كل request ممكن يروح لون مختلف (صفحة v2 ثم v1) | ثابت على لون 5 دقايق |
| نسبة الـ traffic | = الأوزان بالظبط | الأوزان بتطبّق على **الـ clients الجدد/المنتهية مدتهم** بس |
| الـ abort / rollback | فوري لكل الـ requests | **الـ stickiness بتكسب على الأوزان**: الـ clients الملزوقين في green بيفضلوا عليه لحد ما الـ cookie يخلص — حتى لو وزنه بقى 0 |
| مين بيتأثر بالـ bug | 10% من كل المستخدمين شوية | 10% من المستخدمين تماماً |

في الـ [alb module](../../../infra/terraform/modules/alb/main.tf) الـ `stickiness_duration` شغال مع الطريقتين: الـ listeners الـ `*_external` (لما `listener_weights_managed_externally = true`) فيها نفس الـ `stickiness` block. ⚠️ بس عليهم `ignore_changes = [default_action]` → القيمة بتتطبّق **وقت إنشاء الـ listener** (حطها في نفس الـ apply اللي قلب فيه الـ flag)؛ أي تغيير بعد كده في tfvars مالوش أثر، وبيتعمل بالـ CLI (§5.2). والـ workflow (`set_weights`) بيحافظ على الـ stickiness config وهو بيغيّر الأوزان.

## 2) المعمارية (Architecture)

```text
 traffic: probe /login (20 req/s, من الـ workflow أو جهازك) + k6 canary-watch
                │
 ALB listener default action (weighted) ── blue (stable) 90 → 75 → 50 → 0
                │                       └─ green (canary) 10 → 25 → 50 → 100
                │                              ▲ InjectFaults (web group): SRE_FAULT_ERROR_RATE → 500 + X-SRE-Fault
                ▼                              │ (/ready بره الـ web group → healthy عادي)
 CloudWatch (1-min ALB metrics) ─► alarm student-app-lab-alb-5xx-ratio (5 min, >1%)
                                  alarm student-app-lab-green-unhealthy-hosts (2×1 min)
                │
 deploy-asg.yml canary-weights:  for pct in 10 25 50 100:
                                   route_to green pct → watch_alarms STEP_SECONDS (poll 15s)
                                   ALARM → route_to blue 100, outcome=aborted, exit 1
                                 (steps مش واصلة 100 = split مقصود، مثلاً "10 25" = canary طويل)
```

## 3) المتطلبات (Prerequisites)

- [ ] [45](45-bluegreen-two-asgs.md) شغال: `green_enabled = true`، والأوزان 100/0، والـ CI way متظبط (`listener_weights_managed_externally = true` + `ALB_LISTENER_ARN` الجديد) لو هتستخدم الـ workflow.
- [ ] `APP_URL` على environment `lab` (الـ workflow بيشغّل probe على `/login` عشان الـ alarm يبقى عنده داتا — الـ lab مفيهوش مستخدمين).
- [ ] الـ alarm `student-app-lab-alb-5xx-ratio` في `OK`.

```bash
cd infra/terraform/stacks/40-ec2-alb-asg
export AWS_REGION=us-east-1
APP_URL=$(terraform output -raw app_url)
L=$(terraform output -raw listener_arn)
TGB=$(terraform output -json target_group_arns | jq -r .blue)
TGG=$(terraform output -json target_group_arns | jq -r .green)
ALB_SFX=$(aws elbv2 describe-load-balancers --names student-app-lab-alb --query 'LoadBalancers[0].LoadBalancerArn' --output text | sed 's#.*:loadbalancer/##')
TGG_SFX=$(echo "$TGG" | sed 's#.*:##')
aws cloudwatch describe-alarms --alarm-names student-app-lab-alb-5xx-ratio student-app-lab-green-unhealthy-hosts \
  --query 'MetricAlarms[].[AlarmName,StateValue]' --output table
```

## 4) الطريقة الأولى: AWS Console (يدوي)

1. شغّل traffic على صفحات حقيقية (الـ canary من غير traffic مالوش معنى): `bash deploy/scripts/probe.sh "$APP_URL/login" 0 0.05`.
2. حضّر green على الـ release الجديد ([45 §4.1](45-bluegreen-two-asgs.md)) واستنى كل الـ targets healthy.
3. **Listeners → HTTP:80 → Edit** → blue **90** / green **10** → (اختياري) **Target group stickiness: On** → 300 seconds → **Save**.
4. **CloudWatch → Alarms → `student-app-lab-alb-5xx-ratio`** + **Dashboards → `student-app-lab`** (widget "Requests per color") — استنى 5–6 دقايق.
5. OK → 75/25 → استنى → 50/50 → 0/100. ALARM → 100/0 فوراً.

> 💡 لاحظ في الـ dashboard إن "Requests per color" مش بالظبط 90/10 في كل دقيقة — الأوزان احتمالية، ومع stickiness بتبعد أكتر.

## 5) الطريقة التانية: Infrastructure as Code / CI

### 5.1 الـ Terraform way (tfvars)

```bash
# مع listener_weights_managed_externally = false
# terraform.tfvars: blue_weight = 90, green_weight = 10, stickiness_duration = 300
terraform apply                                    # ~ default_action بس
aws cloudwatch describe-alarms --alarm-names student-app-lab-alb-5xx-ratio --query 'MetricAlarms[0].StateValue'
# بعد 6 دقايق OK: 50/50 → apply → 0/100 → apply.   ALARM: 100/0 → apply
```

الـ gate هنا **إنت** (مفيش أتمتة). مفيد عشان تفهم، بس كل خطوة = apply (صلاحيات + وقت).

### 5.2 الـ CI way — `deploy-asg.yml strategy=canary-weights`

```bash
# stickiness: الأسهل stickiness_duration = 300 في tfvars قبل/مع قلب listener_weights_managed_externally (وقت الإنشاء).
# لو الـ listener الـ external موجود بالفعل (Terraform بيتجاهل الـ default_action)، غيّرها بالـ CLI:
ACT=$(aws elbv2 describe-listeners --listener-arns "$L" --query 'Listeners[0].DefaultActions' --output json \
  | jq -c 'map(if .Type=="forward" then .ForwardConfig.TargetGroupStickinessConfig={Enabled:true,DurationSeconds:300} | del(.TargetGroupArn) else . end)')
aws elbv2 modify-listener --listener-arn "$L" --default-actions "$ACT" >/dev/null

gh workflow run deploy-asg.yml --ref devops-lab \
  -f strategy=canary-weights -f image_tag=<NEW_SHA> -f target_color=auto \
  -f canary_steps="10 25 50 100" -f step_seconds=300 -f run_migrations=true
gh run watch
```

| Input | Default | المعنى |
|---|---|---|
| `canary_steps` | `"10 25 50 100"` | أي قيمة > 100 بتتقص لـ 100؛ لو مفيش 100 → split مقصود (canary طويل) |
| `step_seconds` | `300` | bake كل خطوة ("the stack 40 alarms use 5-minute windows") |
| `scale_down_old` | `false` | بعد 100%: القديم لـ 0 |
| Variable `CANARY_ALARM_NAME` | `student-app-<env>-alb-5xx-ratio` | الـ gate (ممكن تحطه alarm per-TG — §5.3، أو الـ composite `student-app-lab-slo-fast-burn`) |

الـ workflow في الـ canary: نفس الـ plan/migrations/prepare idle بتوع [45](45-bluegreen-two-asgs.md)، والـ probe على **`/login` كل 0.05s** (مش `/ready`) عشان الـ 5xx alarm يبقى عنده requests حقيقية تتأثر بالـ `InjectFaults`.

### 5.3 Gate أدق: alarm على الـ canary TG بس (اقتراح — مش في الـ Terraform)

```bash
cat > /tmp/canary-alarm.json <<EOF
[
  {"Id":"ratio","Expression":"FILL(e,0)/r","Label":"green 5xx ratio","ReturnData":true},
  {"Id":"e","MetricStat":{"Metric":{"Namespace":"AWS/ApplicationELB","MetricName":"HTTPCode_Target_5XX_Count",
     "Dimensions":[{"Name":"LoadBalancer","Value":"$ALB_SFX"},{"Name":"TargetGroup","Value":"$TGG_SFX"}]},"Period":60,"Stat":"Sum"},"ReturnData":false},
  {"Id":"r","MetricStat":{"Metric":{"Namespace":"AWS/ApplicationELB","MetricName":"RequestCount",
     "Dimensions":[{"Name":"LoadBalancer","Value":"$ALB_SFX"},{"Name":"TargetGroup","Value":"$TGG_SFX"}]},"Period":60,"Stat":"Sum"},"ReturnData":false}
]
EOF
aws cloudwatch put-metric-alarm --alarm-name student-app-lab-green-5xx-ratio \
  --alarm-description "Canary gate: green target group 5xx ratio > 2% for 2 of 3 minutes" \
  --metrics file:///tmp/canary-alarm.json --comparison-operator GreaterThanThreshold --threshold 0.02 \
  --evaluation-periods 3 --datapoints-to-alarm 2 --treat-missing-data notBreaching
gh variable set CANARY_ALARM_NAME --body student-app-lab-green-5xx-ratio
```

دلوقتي 5% errors على green عند وزن 10% = 5% في الـ alarm ده (مش 0.5%)، وبـ period دقيقة. التمن: alarm خاص بلون واحد (لما الأدوار تتبدّل محتاج واحد لـ blue)، ومع traffic قليل الـ ratio بيبقى noisy (requests قليلة جداً على الـ canary). امسحه في §10.

## 6) الـ Deploy — canary سليم مع القياس

```bash
# Terminal 1: صفحات حقيقية
bash deploy/scripts/probe.sh "$APP_URL/login" 0 0.05
# Terminal 2: نسبة الـ canary الفعلية (fail لو برة 10±5%) — لخطوة 10% ثابتة (canary_steps="10")
k6 run -e BASE_URL="$APP_URL" -e WATCH_PATH=/ready -e CANARY_COLOR=green \
  -e EXPECT_CANARY_PCT=10 -e TOLERANCE_PCT=5 -e RATE=10 -e DURATION=5m loadtest/k6/canary-watch.js
# Terminal 3: الـ workflow (§5.2) أو الأوزان بإيدك
```

> 💡 الـ k6 بيحتفظ بالـ cookies → مع stickiness هتشوف كل VU ثابت على لون، والنسبة الإجمالية بتتحدد بعدد الـ VUs اللي اتوزعوا أول مرة. `probe.sh` (curl من غير cookie jar) بيشوف الأوزان الخام.

## 7) التحقق (Verify)

```bash
aws elbv2 describe-listeners --listener-arns "$L" --query 'Listeners[0].DefaultActions[0].ForwardConfig' --output json
bash deploy/scripts/version-split.sh "$APP_URL/ready" 100
aws cloudwatch get-metric-statistics --namespace AWS/ApplicationELB --metric-name RequestCount \
  --dimensions Name=LoadBalancer,Value=$ALB_SFX Name=TargetGroup,Value=$TGG_SFX \
  --start-time "$(date -u -d '-15 min' +%FT%TZ)" --end-time "$(date -u +%FT%TZ)" --period 60 --statistics Sum \
  --query 'sort_by(Datapoints,&Timestamp)[].[Timestamp,Sum]' --output text
```

(`date -d` = GNU date: WSL/Git Bash.) وفي الـ job summary: جدول الأوزان بالوقت + الـ probe.

## 8) اكسرها (Break it): bad release على green

الـ `InjectFaults` متسجّل على الـ **web** group بس ([`bootstrap/app.php`](../../../bootstrap/app.php)) → `SRE_FAULT_ERROR_RATE=0.5` بيخلّي نص الصفحات (زي `/login`) 500 بـ header `X-SRE-Fault: error-rate`، و `/ready` سليم → الـ TG health والـ `unhealthy-hosts` مش هيشوفوه؛ **الـ 5xx alarm بس**.

الـ fault بيتحقن من `/student-app/lab/app/*` (مشتركة) → نفس تكنيك [45 §8](45-bluegreen-two-asgs.md): حطه، خلّي green يبوت، امسحه.

```bash
aws ssm put-parameter --name /student-app/lab/app/SRE_FAULT_ERROR_RATE --type String --value 0.5
gh workflow run deploy-asg.yml --ref devops-lab -f strategy=canary-weights -f image_tag=<NEW_SHA> \
  -f canary_steps="10 25 50 100" -f step_seconds=300 -f run_migrations=false
# راقب "Prepare the idle color": أول ما الـ green instances تبقى healthy (أو بعد ~4 دقايق):
aws ssm delete-parameter --name /student-app/lab/app/SRE_FAULT_ERROR_RATE
# اتأكد إن green فعلاً فيه الـ fault:
for i in $(seq 1 20); do curl -s -o /dev/null -D - "$APP_URL/login" | grep -i '^x-sre-fault'; done | sort | uniq -c
```

| السيناريو | المتوقع |
|---|---|
| Gate = `alb-5xx-ratio` (الـ default) | عند 10%: الـ ALB كله ~5% errors > 1% → ALARM خلال ~2–6 دقايق → `canary aborted at 10%: alarm student-app-lab-alb-5xx-ratio - 100% back on blue`. الـ probe: failures بتساوي تقريباً 5% من requests الفترة دي |
| `SRE_FAULT_ERROR_RATE=0.05` | ممكن يعدّي 10% ويقع عند 25% أو 50% (§1.1) — جرّبه بالـ alarm الـ default وبعدين بالـ per-TG (§5.3) وقارن |
| Stickiness 300 + abort | بعد الـ abort الـ probe (curl) بيرجع سليم فوراً، بس k6 (cookies) بيفضل يشوف green لحد 5 دقايق |
| `SRE_FAULT_LATENCY_MS=800` | مفيش 5xx → الـ gate الـ default مش هيكشفه. الـ alarm `student-app-lab-alb-latency-p95` (p95 > 300ms) كان هيكشفه — جرّب `CANARY_ALARM_NAME=student-app-lab-alb-latency-p95` |

احسب **الـ blast radius**: (عدد الـ failures في الـ probe) ÷ (كل requests الـ release). قارنه بنفس التمرين في [45 §8](45-bluegreen-two-asgs.md) (100% traffic لحد الـ alarm).

## 9) الرجوع (Rollback)

```bash
ACT=$(aws elbv2 describe-listeners --listener-arns "$L" --query 'Listeners[0].DefaultActions' --output json \
  | jq -c --arg b "$TGB" --arg g "$TGG" 'map(if .Type=="forward" then del(.TargetGroupArn) | .ForwardConfig.TargetGroups=[{TargetGroupArn:$b,Weight:100},{TargetGroupArn:$g,Weight:0}] else . end)')
aws elbv2 modify-listener --listener-arn "$L" --default-actions "$ACT" >/dev/null     # بيحافظ على الـ stickiness config
```

لو عايز تقطع الـ sticky clients فوراً: اقفل الـ stickiness في نفس الـ call (`.ForwardConfig.TargetGroupStickinessConfig={Enabled:false}`) — الـ cookies القديمة بتتجاهل.

## 10) المسح (Teardown) ⚠️

```bash
aws cloudwatch delete-alarms --alarm-names student-app-lab-green-5xx-ratio 2>/dev/null || true
gh variable delete CANARY_ALARM_NAME 2>/dev/null || true
aws ssm get-parameters-by-path --path /student-app/lab/app --query 'Parameters[?contains(Name, `SRE_FAULT`)].Name'   # لازم []
```

رجّع الأوزان 100% على اللون اللي هيفضل، وبعدين `green_enabled = false` ([45 §10](45-bluegreen-two-asgs.md)) أو `terraform destroy`.

## 11) التكلفة (Cost)

| Resource | السعر التقريبي (us-east-1 — تقريبي، راجع صفحة الأسعار) |
|---|---|
| لونين شغالين طول الـ canary (~20+ دقيقة) | نفس [45](45-bluegreen-two-asgs.md) |
| Alarm per-TG (metric math بـ 2 metrics) | ~$0.20/شهر |
| `describe-alarms` / `describe-listeners` polling | مجاني تقريباً (API calls) |
| GitHub Actions (job ~25 دقيقة) | دقايق Actions |

## 12) أسئلة Interview

<details><summary>Canary بـ ALB weights مقابل canary على nginx (سيناريو 24)؟</summary>

nginx: الأوزان على host واحد، والـ gate بيقرا عدادات الـ canary slot نفسه من `/metrics` كل 30 ثانية → سريع ودقيق، بس الـ host single point of failure. ALB: الأوزان managed وعلى fleet حقيقي، بس الـ gate CloudWatch (1-min metrics + window) → دقايق، والـ alarm الافتراضي على الـ ALB كله (بيخفف الإشارة). الأحسن: ALB للـ routing + gate بيقارن canary بـ baseline (per-TG metrics أو Prometheus بالـ `color` label).

</details>

<details><summary>إيه اللي بيحدد سرعة الـ abort؟</summary>

دقة الـ metric (ALB = 60s، high-resolution custom = ثواني)، تأخير النشر، window الـ alarm و datapoints-to-alarm، سرعة الـ poll (15s هنا)، وكمية الـ traffic (requests قليلة = لازم window أطول عشان الـ ratio يبقى له معنى). قاعدة: `step_seconds` ≥ window + تأخير، وإلا بتكبّر على عمى.

</details>

<details><summary>Stickiness في canary: معاها ولا ضدها؟</summary>

معاها: تجربة متسقة للمستخدم (مفيش تنقل بين إصدارين في نفس الـ session) — مهم لو الـ UI أو الـ session shape اتغيّرت. ضدها: الـ split بيبعد عن الأوزان، والـ rollback مبيشيلش الـ sticky clients لحد ما الـ duration يخلص (الـ stickiness بتكسب على الوزن). الحل الوسط: duration قصير (دقايق)، وفي الـ rollback اقفل الـ stickiness في نفس الـ call.

</details>

<details><summary>ليه الـ health checks مش هتمسك release بيرجّع 500 على 50% من الصفحات؟</summary>

`/ready` بره الـ web group (مفيش session، مفيش `InjectFaults`) وبيرجّع 200 طول ما الداتابيز شغالة. الـ health check بيسأل "الـ instance تقدر تخدم؟" مش "الكود صح؟". الـ correctness بتتقاس بـ SLIs على traffic حقيقي (5xx ratio، latency) — وده بالظبط شغل الـ canary analysis.

</details>

<details><summary>إزاي تعمل canary analysis "صح" إحصائياً؟</summary>

قارن الـ canary بـ baseline بيستقبل نفس نوع الـ traffic في نفس الوقت (مش بالـ production كله، ومش بالأمس)، بحد أدنى من الـ requests قبل أي حكم، وعلى أكتر من metric (errors، latency p95/p99، saturation، business KPIs). أدوات: Argo Rollouts AnalysisTemplate بـ Prometheus ([68](68-k8s-canary-argo-rollouts.md))، Kayenta، أو ECS/CodeDeploy مع CloudWatch alarms ([54](54-ecs-codedeploy-bluegreen-canary.md)، [55](55-ecs-native-bluegreen-linear-canary.md)). 10 requests مش عينة.

</details>

<details><summary>Canary على ALB مقابل ECS native / Argo Rollouts؟</summary>

ALB + ASG (هنا): إنت بتكتب الـ orchestration (الـ workflow) والـ capacity الكاملة لـ green جاهزة من الأول. ECS native canary/linear: ECS بيحرّك الأوزان على listener rule ويرجّع بالـ alarms لوحده، و tasks بتتعمل بسرعة. Argo Rollouts: steps declarative + analysis بـ Prometheus + `setWeight` على ingress/service mesh، و pods بتتعمل حسب النسبة. الفكرة واحدة؛ الفرق في مين بيملك الـ state machine وسرعة الـ feedback.

</details>

## 13) Checklist

- [ ] عملت canary يدوي بالـ console وراقبت الـ alarm والـ "Requests per color"
- [ ] شغّلت `canary-weights` لحد 100% والـ probe/k6 بيأكدوا النسب
- [ ] جرّبت bad release بـ `SRE_FAULT_ERROR_RATE=0.5` وشفت الـ abort أوتوماتيك، وحسبت الـ blast radius
- [ ] جرّبت error rate صغير وفهمت ليه الـ gate الـ ALB-wide بيعدّيه، وعملت per-TG alarm
- [ ] فهمت الـ stickiness trade-off، وإنها على الـ `*_external` listener بتتطبّق وقت الإنشاء بس (بعد كده CLI)
- [ ] مسحت الـ fault parameters والـ alarm الإضافي
