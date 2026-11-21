# 76 — Incident response (runbooks، postmortem)

> **الهدف في سطر:** يبقى عندك runbook لكل alert في المعمل (Prometheus و CloudWatch) — الـ `runbook_url` في كل alert بيشاور هنا — وتعرف الـ severities، أساسيات الـ on-call، أدوار الـ incident (IC، comms، ops، scribe)، الـ mitigation-first بأوامر rollback لكل platform، و postmortem blameless؛ وتعمل incident محاكى كامل بـ bad release.
> **المستوى:** Intermediate → Advanced · **الوقت:** ~3 ساعات · **التكلفة التقريبية:** مجاني (نفس الستاك اللي بتتدرب عليه)
> **بيعتمد على:** [73](73-slo-error-budget-burn-rate.md) · [12](12-sre-lab-endpoints-and-local-observability.md) · [23](23-bluegreen-single-host.md) · **الملفات في الـ repo:** [`rules/slo-burn-rate.yml`](../../../observability/prometheus/rules/slo-burn-rate.yml) · [`alertmanager.yml`](../../../observability/prometheus/alertmanager.yml) · [`modules/observability/main.tf`](../../../infra/terraform/modules/observability/main.tf) · [`deploy/ec2/lb/bin/rollback.sh`](../../../deploy/ec2/lb/bin/rollback.sh) · [`deploy/ec2/deploy-pull-image.sh`](../../../deploy/ec2/deploy-pull-image.sh) · [`logs-insights-queries.md`](../../../observability/cloudwatch/logs-insights-queries.md)

> **روابط سريعة للـ runbooks (Prometheus):** [SLOAvailabilityFastBurn](#sloavailabilityfastburn) · [SLOAvailabilitySlowBurn](#sloavailabilityslowburn) · [SLOAvailabilityBudgetBurn](#sloavailabilitybudgetburn) · [SLOLatencyFastBurn](#slolatencyfastburn) · [SLOLatencySlowBurn](#slolatencyslowburn) · [SLOLatencyBudgetBurn](#slolatencybudgetburn) · [SLOLatencyTailP99High](#slolatencytailp99high) · [SLODrillFastBurn](#slodrillfastburn) · [SLODrillSlowBurn](#slodrillslowburn) · [SLODrillBudgetBurn](#slodrillbudgetburn) · [StudentAppNoTargetsUp](#studentappnotargetsup)
> **CloudWatch:** [slo-fast-burn](#student-app-lab-slo-fast-burn) · [slo-slow-burn](#student-app-lab-slo-slow-burn) · [alb-5xx-ratio](#student-app-lab-alb-5xx-ratio) · [alb-latency-p95](#student-app-lab-alb-latency-p95) · [blue-unhealthy-hosts](#student-app-lab-blue-unhealthy-hosts) · [green-unhealthy-hosts](#student-app-lab-green-unhealthy-hosts) · [rds-cpu](#student-app-lab-rds-cpu) · [rds-free-storage](#student-app-lab-rds-free-storage)

## 1) الفكرة (Concepts)

الـ incident = أي حاجة بتأذي المستخدمين (أو هتأذيهم قريب) ومحتاجة استجابة منسقة. الهدف **مش** تلاقي الـ root cause وقت الحريق — الهدف **توقف النزيف** (mitigate) بأسرع وقت، وبعدين تفهم.

| المصطلح | المعنى |
|---|---|
| MTTD / MTTA / MTTR | وقت الاكتشاف / الـ acknowledge / الـ recovery (الـ mitigate) |
| Mitigation-first | rollback/drain/scale الأول، الـ debugging بعدين — الـ rollback أرخص من أي تحقيق |
| IC (Incident Commander) | بيدير الـ incident: قرارات، أولويات، مين بيعمل إيه. **مش** بيكتب commands |
| Comms lead | بيكلّم الـ stakeholders/المستخدمين بـ updates دورية |
| Ops lead | بيشتغل على الـ mitigation فعلياً (rollback، queries) |
| Scribe | بيكتب الـ timeline بالدقيقة (وقت كل قرار وكل ملاحظة) |
| Blameless postmortem | تحليل بعد الـ incident بيسأل "إيه في النظام سمح بده؟" مش "مين غلط؟" |

### 1.1 الـ severities

| Sev | المعنى | مثال في المعمل | الاستجابة |
|---|---|---|---|
| SEV1 | outage كامل أو data loss | `StudentAppNoTargetsUp`، `slo-fast-burn` بـ 100% errors | page فوري، IC + war room، updates كل 15–30 دقيقة |
| SEV2 | جزء كبير من المستخدمين متأثر / الـ budget بيتحرق بسرعة | `SLOAvailabilityFastBurn`، `SLOLatencyFastBurn`، `SLOAvailabilitySlowBurn` | page، IC لو مكمّل > 30 دقيقة |
| SEV3 | تدهور محدود أو بطيء | `*BudgetBurn`، `SLOLatencyTailP99High`، `rds-cpu` | ticket — شغل ساعات العمل |
| SEV4 | مفيش أثر على المستخدم | `SLODrill*`، warning | log / channel |

الـ severity بتتحدد بالأثر على المستخدم مش بالـ alert. وممكن ترفعها أو تنزّلها أثناء الـ incident.

### 1.2 أساسيات الـ on-call

- كل **page لازم يبقى actionable** وليه runbook — page مالوش action = alert noise → احذفه أو حوّله ticket.
- Ack خلال ~5 دقايق، و escalation لو مفيش ack (PagerDuty/Opsgenie policies).
- Handoff مكتوب في آخر الـ shift (incidents مفتوحة، silences شغالة، deploys جاية).
- Silences في Alertmanager لازم ليها **expiry** و comment.
- بعد كل incident: هل الـ alert ضرب في الوقت الصح؟ هل الـ runbook ساعد؟ عدّله.

## 2) المعمارية (Architecture)

```text
 Prometheus rules ──► Alertmanager ──┬─ drill="true"  → receiver drill   (alert-sink /drill)  — مش pager
   (runbook_url → هنا)               ├─ severity=page → receiver pager   (alert-sink /page → PagerDuty/Slack)
                                     └─ severity=ticket → receiver tickets (email + /ticket)
 CloudWatch alarms ──► SNS student-app-lab-alerts ──► email (alarm_email) [+ Slack/PagerDuty subscriptions]
                                     │
                                     ▼
 on-call ack ─► IC يعلن الـ incident (sev، channel، roles) ─► mitigate (rollback / drain / scale / fault off)
            ─► verify (SLI رجع، burn rate نازل، alerts resolved) ─► comms "resolved" ─► postmortem (≤ 5 أيام)
```

## 3) المتطلبات (Prerequisites)

- [ ] ستاك [12](12-sre-lab-endpoints-and-local-observability.md) (Prometheus/Alertmanager/alert-sink) و/أو stack 40/50 بـ `alarm_email`.
- [ ] ستاك [23](23-bluegreen-single-host.md) شغال للمحاكاة (أو على GitHub Actions بالـ lab-integration).
- [ ] الأوامر دي محفوظة/مجرّبة **قبل** ما تحتاجها.

## 4) الطريقة الأولى: AWS Console (يدوي)

1. **SNS → Topics → `student-app-lab-alerts` → Subscriptions**: اتأكد إن الـ email **Confirmed** (مش PendingConfirmation — ساعتها مفيش حاجة هتوصلك).
2. **CloudWatch → Alarms → All alarms** → filter `student-app-lab` → افتح أي alarm → **History** (state changes والـ actions اللي اتبعتت).
3. Slack/Teams (اختياري): **AWS Chatbot** (اسمه دلوقتي *Amazon Q Developer in chat applications*) → configure Slack channel → subscribe الـ SNS topic.
4. وقت صيانة مخططة: **Alarm → Actions → Disable actions** (ورجّعها بعد كده) — بدل ما تمسح الـ alarm.

## 5) الطريقة التانية: as Code

- **Prometheus:** كل alert في [`slo-burn-rate.yml`](../../../observability/prometheus/rules/slo-burn-rate.yml) (ونسخة الـ PrometheusRule والـ promtool tests) فيه `annotations.runbook_url` = `…/76-incident-response.md#<alertname lowercased>` — مثلاً `#sloavailabilityfastburn`، و `summary`/`description` بالـ `$labels.job` والـ `$value`. الـ headings في §6 مكتوبة باسم الـ alert **بالظبط** (`### SLOAvailabilityFastBurn`) عشان GitHub يطلّع نفس الـ anchor — **متغيّرش عنوان runbook** من غير ما تغيّر الـ `runbook_url` (وإلا الـ link هيفتح أول الصفحة).
- **Alertmanager:** [`alertmanager.yml`](../../../observability/prometheus/alertmanager.yml) — الـ routing والـ inhibition ([73 §5.3](73-slo-error-budget-burn-rate.md)). الـ receivers الحقيقية بـ `*_file` للـ secrets.
- **CloudWatch:** `alarm_email` في الـ stack → `aws_sns_topic_subscription.email`؛ الـ alarms بـ `alarm_actions` و `ok_actions` (بيبعت لما يدخل ALARM ولما يرجع OK).

```bash
cd infra/terraform/stacks/40-ec2-alb-asg
terraform apply -var alarm_email=<YOU@example.com> -var image_tag=<SHA7>
aws sns list-subscriptions-by-topic --topic-arn "$(terraform output -raw sns_topic_arn)" --query 'Subscriptions[].[Protocol,Endpoint,SubscriptionArn]'
```

### 5.1 أوامر الـ triage المشتركة (هتتكرر في الـ runbooks)

```bash
# Prometheus (محلي/EC2 عبر SSM port-forward)
pq() { curl -s localhost:9090/api/v1/query --data-urlencode "query=$1" | jq -r '.data.result[] | "\(.metric) \(.value[1])"'; }
pq 'sum by (route, status) (rate(student_app_http_requests_total{status=~"5.."}[5m]))'           # مين بيفشل
pq 'sum by (version, color) (rate(student_app_http_requests_total{status=~"5.."}[5m]) * on(instance) group_left(version,color) student_app_app_info)'  # أنهي release
pq 'student_app_app_info'                                                                       # إيه اللي شغال فين
pq 'up{job="student-app"}'

# Single host
cd /opt/student-app/src/deploy/ec2/lb && bash bin/status.sh
docker compose -f /opt/student-app/src/docker-compose.prod.yml ps
curl -s http://127.0.0.1:8081/ready; curl -s http://127.0.0.1:8082/ready

# AWS
aws cloudwatch describe-alarms --state-value ALARM --alarm-name-prefix student-app-lab --query 'MetricAlarms[].[AlarmName,StateReason]'
aws elbv2 describe-target-health --target-group-arn <TG_ARN> --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State,TargetHealth.Reason]' --output table
aws ecs describe-services --cluster student-app-lab --services student-app-lab-app --query 'services[0].[taskDefinition,runningCount,desiredCount,deployments[].[status,rolloutState,taskDefinition],events[:5].message]'
aws autoscaling describe-instance-refreshes --auto-scaling-group-name student-app-lab-blue --max-records 1
aws ssm get-parameter-history --name /student-app/lab/deploy/blue/IMAGE_URI --query 'Parameters[-3:].[LastModifiedDate,Value]' --output table
aws logs tail /student-app/lab/app --since 15m --filter-pattern '{ $.level_name = "ERROR" || $.level_name = "CRITICAL" }'   # ASG
aws logs tail /ecs/student-app-lab/app --since 15m --filter-pattern '{ $.level_name = "ERROR" || $.level_name = "CRITICAL" }'  # ECS
```

### 5.2 Rollback لكل platform (mitigation-first)

| Platform | الأمر | ملاحظات |
|---|---|---|
| Single host — Recreate | `bash deploy/ec2/deploy-pull-image.sh rollback` | بيعمل redeploy لـ `PREVIOUS_RELEASE` ([32](32-cd-ec2-ecr-ssm.md)) |
| Single host — blue/green/canary/rolling | `cd deploy/ec2/lb && bash bin/rollback.sh` | `MODE=single` → اللون التاني (فوري لو لسه شغال)؛ `canary\|ab\|shadow` → 100% على `ACTIVE`؛ `rolling` → الـ slots الاتنين لـ `PREVIOUS_IMAGE`. ⚠️ canary اتقطع بـ Ctrl+C → `bash bin/ab-test.sh stop` مش rollback ([24](24-canary-single-host.md)) |
| ASG (rolling / refresh) | refresh شغال: `aws autoscaling rollback-instance-refresh --auto-scaling-group-name student-app-lab-blue` (أو `cancel-instance-refresh`). خلص: رجّع الـ image القديمة: `aws ssm put-parameter --name /student-app/lab/deploy/blue/IMAGE_URI --value <PREV_URI> --overwrite` ثم `aws autoscaling start-instance-refresh --auto-scaling-group-name student-app-lab-blue --preferences '{"MinHealthyPercentage":50,"InstanceWarmup":120}'` | refresh بدأه الـ CI (من غير تغيير launch template) مش بيقدر "auto rollback" للـ image — الـ alarm بيوقفه بس (stack 40 README) |
| ASG blue/green (listener) | `aws elbv2 modify-listener --listener-arn <LISTENER_ARN> --default-actions '[{"Type":"forward","ForwardConfig":{"TargetGroups":[{"TargetGroupArn":"<BLUE_TG>","Weight":100},{"TargetGroupArn":"<GREEN_TG>","Weight":0}]}}]'` | ثواني؛ وبعدها حدّث `blue_weight`/`green_weight` في tfvars (drift) ([45](45-bluegreen-two-asgs.md)) |
| ECS rolling | `aws ecs update-service --cluster student-app-lab --service student-app-lab-app --task-definition <PREVIOUS_TASKDEF_ARN>` | الـ revisions: `aws ecs list-task-definitions --family-prefix student-app-lab-app --sort DESC --max-items 3`؛ الـ circuit breaker بيرجّع لوحده لو الـ tasks مش بتقوم ([53](53-ecs-rolling-circuit-breaker.md)) |
| ECS + CodeDeploy | `aws deploy stop-deployment --deployment-id <ID> --auto-rollback-enabled` | ([54](54-ecs-codedeploy-bluegreen-canary.md)) |
| Helm | `helm history student-app -n student-app` ثم `helm rollback student-app <REVISION> -n student-app` | ([65](65-helm-chart.md)) |
| Argo Rollouts | `kubectl argo rollouts abort <ROLLOUT> -n student-app` (يرجع للـ stable فوراً) ثم `kubectl argo rollouts undo <ROLLOUT> -n student-app` | ([68](68-k8s-canary-argo-rollouts.md)) |
| Fault env (تمرين) | شيل `SRE_FAULT_*` (compose `up`، `aws ssm delete-parameter --name /student-app/lab/app/SRE_FAULT_ERROR_RATE` + refresh) | |

> ⚠️ **الـ migrations مش بترجع** مع أي rollback — عشان كده expand/contract ([95](95-zero-downtime-db-migrations.md)). لو الـ release الجديد عمل migration مش backward compatible، الـ rollback ممكن يكسر أكتر — اعرف ده **قبل** ما تعمل deploy.

## 6) الـ Runbooks

كل runbook: **المعنى · الأثر · أول 5 دقايق · أسباب محتملة · Mitigation · التحقق · بعدين**.

### SLOAvailabilityFastBurn

- **Severity:** page (SEV2، SEV1 لو قريب من 100%). `slo=availability`، `burn=fast`.
- **المعنى:** نسبة الـ 5xx على app routes > **7.2%** على آخر ساعة **و** آخر 5 دقايق (14.4× الـ budget). لو كمّل كده الـ budget الشهري يخلص في ~يومين. الـ alert ده بيسكّت الـ slow/budget لنفس الـ SLO (inhibition).
- **أول 5 دقايق:**
  1. Ack وأعلن الـ incident لو مكمّل.
  2. **حصل deploy في آخر ساعة؟** `pq 'student_app_app_info'`، `bash bin/status.sh`، `gh run list --limit 5`، ECS deployments، `get-parameter-history` للـ IMAGE_URI.
  3. مين بيفشل: `sum by (route, status)` و `by (version, color)` (§5.1). كل الـ routes؟ release واحد؟ instance واحد؟
  4. اللوجز: Logs Insights "Exceptions by class" و "Database trouble" ([70](70-logging.md)).
- **أسباب محتملة:** release سيء (الـ health checks خضرا والـ errors على الصفحات — بالظبط `SRE_FAULT_ERROR_RATE`)، الـ DB (connections، credentials بعد rotation، failover)، `APP_KEY` مختلف بين replicas (419 مش 5xx — مش هنا)، disk/memory على الـ host.
- **Mitigation:** deploy حديث = **rollback فوراً** (§5.2) من غير ما تستنى تفهم. release واحد/instance واحد بيفشل = اشيله (`POST /sre-lab/unready` على الـ slot، أو weight 0). الـ DB = [rds-cpu](#student-app-lab-rds-cpu) / failover.
- **التحقق:** الـ 5m ratio نزل تحت 7.2% → الـ alert resolved في دقايق (الـ short window)؛ RED → 5xx ratio ≈ 0؛ k6 smoke عدّى.
- **بعدين:** postmortem لو صرف > 20% من الـ budget؛ ليه الـ canary/smoke ما مسكوش؟

### SLOAvailabilitySlowBurn

- **Severity:** page (SEV2). `burn=slow`.
- **المعنى:** 5xx > **3%** على 6 ساعات **و** 30 دقيقة (6×) — الـ budget يخلص في ~5 أيام. تسريب متوسط مش حريق: الـ fast مش شايفه.
- **أول 5 دقايق:** نفس الـ fast، بس دوّر على حاجة **جزئية**: route واحد (`sum by (route)`)، instance/AZ واحد، نوع user معين، cron/job بيعمل load في أوقات معينة.
- **أسباب محتملة:** bug في route واحد (مثلاً `reports.index` بفلتر معين)، slot قديم في rolling/canary فاضل شغال، dependency بطيئة بتعمل timeouts متقطعة، `db.t4g.micro` max connections وقت الذروة.
- **Mitigation:** لو مربوط بـ release → rollback؛ route واحد → feature flag/إخفاء ([26](26-ab-testing-shadow-feature-flags.md)) أو hotfix سريع؛ capacity → scale out.
- **التحقق:** الـ 30m window تحت 3%؛ الـ burn rate panel (6h) بينزل.
- **بعدين:** ticket للـ root cause؛ ليه ما اتمسكش في الـ load test (journey ناقصة؟).

### SLOAvailabilityBudgetBurn

- **Severity:** ticket (SEV3). `burn=budget`.
- **المعنى:** 5xx > **0.5%** على 3 أيام **و** 6 ساعات — بنصرف الـ budget أسرع من المسموح (هيخلص قبل 30 يوم).
- **أول خطوة (ساعات العمل):** SLO dashboard → "Error budget left" و "Availability burn rate" (1d/3d)؛ `topk(5, sum by (route) (increase(student_app_http_requests_total{status=~"5.."}[3d])))`.
- **أسباب محتملة:** errors صغيرة مستمرة (exception في edge case، timeouts متفرقة)، traffic بيكبر والـ capacity على الحد.
- **Mitigation:** مش طوارئ — bugs بأولوية، ومراجعة الـ SLO policy (لو الـ budget < 25%: canary إجباري، تقليل المخاطرة — [73 §5.9](73-slo-error-budget-burn-rate.md)).
- **التحقق:** الـ 3d ratio بينزل خلال أيام.

### SLOLatencyFastBurn

- **Severity:** page (SEV2). `slo=latency`، `burn=fast`.
- **المعنى:** أكتر من **72%** من الـ requests أبطأ من 300ms على ساعة **و** 5 دقايق (budget الـ latency = 5%؛ 14.4 × 5% = 72%). ده بطء عام تقريباً على كل حاجة.
- **أول 5 دقايق:** RED → Duration row: كل الـ routes ولا route واحد؟ Saturation row: CPU cores بالـ service، memory؛ CloudWatch: ECS/ASG CPU، RDS CPU/latency، `TargetResponseTime` p95/p99؛ deploy حديث؟ (`SRE_FAULT_LATENCY_MS` بيعمل بالظبط ده).
- **أسباب محتملة:** release بطيء (N+1 query، cache اتشال)، الـ DB saturated (`/sre-lab/db/heavy` تحت load، slow query log في `/aws/rds/instance/student-app-lab-mysql/slowquery`)، CPU saturated (PHP-FPM workers كلهم مشغولين → queue)، CPU credits خلصت على t3 (burstable)، noisy neighbor/FIS latency.
- **Mitigation:** rollback لو deploy؛ scale out (`aws autoscaling set-desired-capacity --auto-scaling-group-name student-app-lab-blue --desired-capacity <N>` أو `aws ecs update-service --cluster student-app-lab --service student-app-lab-app --desired-count <N>`)؛ DB: اقتل الـ query/وقّف الـ job التقيل.
- **التحقق:** "Faster than 300ms (5m)" رجع > 95%؛ p95 تحت 300ms.

### SLOLatencySlowBurn

- **Severity:** page (SEV2). `burn=slow`.
- **المعنى:** > **30%** من الـ requests أبطأ من 300ms على 6 ساعات و 30 دقيقة.
- **أول 5 دقايق:** "p95 by route" و "Share under 300ms by route" — غالباً route أو اتنين (`reports.index`، search `?q`)؛ هل بيزيد مع نمو الداتا (الطلاب اللي k6 عملها!)؟
- **Mitigation:** index ناقص/query تقيلة → hotfix أو feature flag؛ capacity → scale؛ cache ([49](49-redis-sessions-cache.md)).
- **التحقق:** الـ 30m window تحت 30%.

### SLOLatencyBudgetBurn

- **Severity:** ticket (SEV3).
- **المعنى:** > 5% من الـ requests أبطأ من 300ms على 3 أيام و 6 ساعات — الـ latency budget بيتصرف أسرع من المسموح.
- **الخطوة:** ticket لتحسين الـ routes البطيئة (من "p95 by route")، EXPLAIN على الـ queries، مراجعة الـ capacity plan ([74 §5.2](74-load-testing-k6.md)).

### SLOLatencyTailP99High

- **Severity:** ticket. `slo=latency-tail`.
- **المعنى:** الـ p99 على app routes (نافذة 10 دقايق) > **1s** لمدة 15 دقيقة. معظم الناس تمام، بس 1 من كل 100 request بطيء جداً.
- **الخطوة:** "Latency percentiles" (p99) و "p95 by route"؛ CloudWatch `TargetResponseTime` p99؛ مصادر الـ tail المعتادة: cold starts بعد scale out/deploy (opcache فاضي، `AUTORUN` optimize)، GC، bcrypt على الـ login، locks في الـ DB، retries.
- **ملاحظة:** على traffic قليل الـ p99 = request أو اتنين — اتأكد من الحجم قبل ما تستثمر وقت.

### SLODrillFastBurn

- **Severity:** label `page` بس **`drill="true"`** → Alertmanager بيوديه receiver `drill` (مش الـ pager). SEV4.
- **المعنى:** traffic على `/sre-lab/error` (route `sre-lab.error`) بيفشل > 7.2% على 1h و 5m. ده **game day** (`loadtest/k6/error-budget-burn.js MODE=lab`)، مش incident.
- **الخطوة:** لو فيه drill مخطط: سجّل في الـ timeline وقت الـ firing وقارنه بالحسبة المتوقعة ([73 §1.5](73-slo-error-budget-burn-rate.md)) — ده الهدف من التمرين. لو **مفيش** drill مخطط: حد بيضرب `/sre-lab/error` — اعرف مين (`aws logs`/nginx access log)، واتأكد إن `SRE_LAB_TOKEN` متحدد على أي environment مكشوف وإن الـ lab مقفول بره الـ game days ([83](83-edge-security-waf-https.md)).
- **مش محتاج rollback.** ولو الـ drill وصل للـ pager الحقيقي → bug في الـ routing (`drill="true"` لازم أول route و `continue: false`).

### SLODrillSlowBurn

- **Severity:** drill (SEV4). نفس [SLODrillFastBurn](#slodrillfastburn) بأرقام 6× على 6h و 30m. لو شغّال drill طويل (`DURATION` ساعات) ده متوقع.

### SLODrillBudgetBurn

- **Severity:** drill ticket (SEV4). 1× على 3d و 6h على الـ drill SLI — حد سايب `error-budget-burn.js` شغال أيام، أو مراقبة synthetic بتضرب `/sre-lab/error`. وقّفه.

### StudentAppNoTargetsUp

- **Severity:** page (SEV1). `sum by (job) (up{job="student-app"}) == 0` لمدة دقيقتين. بيسكّت كل الـ SLO alerts (inhibition) لأن مفيش data.
- **المعنى:** Prometheus مش قادر يعمل scrape لأي instance. يا الخدمة واقعة، يا مسار الـ scrape مكسور.
- **أول 5 دقايق — فرّق بين الاتنين:**
  ```bash
  curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/up          # من برّه (أو الـ ALB)
  curl -s localhost:9090/api/v1/targets | jq -r '.data.activeTargets[] | select(.labels.job=="student-app") | "\(.labels.instance) \(.health) \(.lastError)"'
  docker compose ps; docker network inspect student-app_default --format '{{range .Containers}}{{.Name}} {{end}}'
  ```
- **أسباب محتملة:** الـ app containers واقعة (`SRE_FAULT_BOOT_FAIL`، OOM، crash loop)؛ `METRICS_ENABLED=false` (404) أو `METRICS_TOKEN` اتحط من غير Prometheus credentials (403)؛ الـ app stack اتعمله `down` فـ Prometheus خرج من الـ network `student-app_default` (اعمل `up` للستاك تاني)؛ تغيير أسماء الـ services.
- **Mitigation:** الخدمة واقعة → rollback/restart؛ scrape path → صلّح الـ config (الخدمة شغالة، الأولوية أقل بس انت أعمى لحد ما يتصلح).
- **التحقق:** `up{job="student-app"}` = 1 لـ target واحد على الأقل.

### student-app-lab-slo-fast-burn

- **Severity:** page (SEV2). Composite: `ALARM("student-app-lab-slo-burn-fast-1h") AND ALARM("student-app-lab-slo-burn-fast-5m")` → SNS.
- **المعنى:** ALB 5xx ratio (`(Target 5XX + ELB 5XX) / RequestCount`) > 7.2% على ساعة و 5 دقايق. نفس [SLOAvailabilityFastBurn](#sloavailabilityfastburn) بس من الـ edge: بيشمل 502/503/504 اللي التطبيق ما شافهاش، **وبيشمل traffic الـ `/sre-lab/*`** (مفيش path dimension).
- **أول 5 دقايق:** CloudWatch dashboard → "5xx / min (target vs ALB)": **target 5xx** = التطبيق بيرجّع 500 (release/DB)؛ **ELB 5xx** = مفيش target healthy أو timeouts (→ [unhealthy-hosts](#student-app-lab-blue-unhealthy-hosts)). اتأكد إن مفيش game day شغال (`error-budget-burn.js MODE=lab` ضد الـ ALB بيحرق ده).
- **Mitigation:** §5.2 حسب الـ platform. لو drill → `aws cloudwatch disable-alarm-actions --alarm-names student-app-lab-slo-fast-burn student-app-lab-slo-slow-burn` لحد ما يخلص (ورجّعها).
- **التحقق:** الـ child `fast-5m` يرجع OK → الـ composite OK (SNS بيبعت OK).

### student-app-lab-slo-slow-burn

- **Severity:** page (SEV2). Composite على `student-app-lab-slo-burn-slow-6h` AND `-slow-30m` (> 3%). نفس [SLOAvailabilitySlowBurn](#sloavailabilityslowburn) من الـ ALB. دوّر على "Requests per color" — لون واحد بيرجّع errors؟ و Athena "Who produced the 5xx" على الـ ALB access logs لو مفعّلة.
- الـ children (`student-app-lab-slo-burn-*`) مالهمش actions — مش هيوصلك منهم حاجة لوحدهم.

### student-app-lab-alb-5xx-ratio

- **Severity:** symptom — ابدأ بيه كـ SEV3 وارفعه لو مكمّل. (`(FILL(t5xx,0)+FILL(e5xx,0))/req` > 1% على 5 دقايق.) ده كمان stop condition للـ FIS في stack 50 و alarm للـ ECS deployments (`use_deployment_alarms`) والـ instance refresh (stack 40).
- **المعنى:** spike قصير في الـ 5xx. لوحده مش بيصرف budget كبير، بس أول إنذار.
- **الخطوة:** deploy/refresh شغال دلوقتي؟ (`describe-instance-refreshes`، ECS deployments) — الـ alarm ده بيوقف الـ refresh/الـ deployment أوتوماتيك. FIS experiment شغال؟ (`aws fis list-experiments`). target vs ELB 5xx.
- **التحقق:** OK بعد 5 دقايق نضيفة.

### student-app-lab-alb-latency-p95

- **Severity:** symptom (SEV3)، وبيبقى stop condition في `ec2-cpu-stress.json`. `TargetResponseTime` p95 > 0.3s على 5 دقايق.
- **الخطوة:** نفس [SLOLatencyFastBurn](#slolatencyfastburn): CPU (ASG/ECS)، RDS، deploy حديث، FIS (CPU stress / network latency). `TargetResponseTime` = من ما الـ ALB بعت للـ target لحد أول byte رجع — مش بيشمل الـ client network.

### student-app-lab-blue-unhealthy-hosts

- **Severity:** SEV2 لو **كل** الـ targets unhealthy (ELB 5xx هيطلع)، SEV3 لو واحد. `UnHealthyHostCount > 0` لدقيقتين على TG الـ blue (`/ready` فاشل). TG فاضي (idle color) مش بيضرب (`notBreaching`).
- **أول 5 دقايق:**
  ```bash
  aws elbv2 describe-target-health --target-group-arn <BLUE_TG_ARN> --output table     # Reason: Target.ResponseCodeMismatch = /ready رجّع 503
  ```
  ادخل instance بـ Session Manager: `curl -s localhost/ready` → الـ `reason` بيقولك: `database unreachable` / `manually drained (unready flag present)` / `fault injection: SRE_FAULT_UNHEALTHY`.
- **أسباب محتملة:** الـ DB (security group، credentials، RDS reboot/failover)؛ release unhealthy (`SRE_FAULT_UNHEALTHY`)؛ unready flag منسي؛ instance لسه بيقوم (grace period).
- **Mitigation:** DB → [rds-cpu](#student-app-lab-rds-cpu)/الـ SSM params؛ release → rollback (الـ ASG بـ ELB health checks هيستبدل الـ instances لوحده — راقب ما يعملش replace loop)؛ flag → `POST /sre-lab/ready`.

### student-app-lab-green-unhealthy-hosts

- نفس [student-app-lab-blue-unhealthy-hosts](#student-app-lab-blue-unhealthy-hosts) على TG الـ green. لو الـ green هو الـ idle color وانت بتعمل deploy عليه: ده الـ gate بيشتغل — **متحوّلش** الـ weights عليه.

### student-app-lab-rds-cpu

- **Severity:** SEV3 (SEV2 لو مصاحب latency/5xx). RDS `CPUUtilization` > 80% (default `rds_cpu_threshold`) لـ 10 دقايق.
- **الخطوة:** RDS slow query log (`aws logs tail /aws/rds/instance/student-app-lab-mysql/slowquery --since 30m`)؛ connections؛ هل فيه `breakpoint.js TARGET=db-heavy` أو soak شغال؟ `db.t4g.micro` burstable — CPU credits؟
- **Mitigation:** وقّف الـ load/job التقيل، اقتل الـ query (`SHOW PROCESSLIST` / `KILL <id>` من instance عبر SSM)، cache، أو scale vertical (`db_instance_class` — downtime قصير بدون Multi-AZ).

### student-app-lab-rds-free-storage

- **Severity:** SEV3 — بيبقى SEV1 لو وصل صفر (الـ DB بتبقى read-only/storage-full). `FreeStorageSpace` < 2 GiB.
- **الخطوة:** إيه اللي بيكبر؟ (جداول `sessions`/`cache` مع `SESSION_DRIVER=database`، students k6، binlogs). `max_allocated_storage` = 0 في الـ module (storage autoscaling مقفول).
- **Mitigation:** زوّد `allocated_storage` (online على gp3 بس فيه cooldown بين التعديلات)، أو فعّل storage autoscaling، نضّف الجداول المؤقتة.

## 7) التحقق (Verify) — المحاكاة: bad release على single host

السيناريو: release جديد فيه bug بيرجّع 500 على 10% من الصفحات. الـ health checks خضرا، فالـ blue/green **هيعدّي** (الـ smoke بيعمل request واحد على `/login` — 90% ينجح).

**التجهيز** (ستاك [23](23-bluegreen-single-host.md) + ستاك الـ observability على نفس الـ host/WSL):

```bash
# terminal 1: traffic مستمر على صفحات حقيقية
k6 run -e BASE_URL=http://localhost -e LOADTEST_USERS=5 -e VUS=10 -e DURATION=2h -e P95_MS=2000 loadtest/k6/load.js
# terminal 2: الـ "release"
cd deploy/ec2/lb
SLOT_ENV="SRE_FAULT_ERROR_RATE=0.1" SKIP_PULL=true bash bin/bluegreen.sh student-app:v2
```

**الـ timeline المتوقع** (traffic ثابت، تاريخ نضيف — [73 §1.5](73-slo-error-budget-burn-rate.md)):

| t | الحدث | الدور |
|---|---|---|
| 0 | الـ switch على green (v2). k6 بيبدأ يشوف ~10% failures | — |
| ~1m | RED: "5xx ratio (5m)" بيطلع؛ "5xx ratio by release" = v2 بس | observer |
| ~43m + 2m | `SLOAvailabilityFastBurn` firing → alert-sink `/page` | on-call: ack |
| +2m | IC يعلن SEV2: channel، الأدوار، أول update | IC / comms |
| +3m | `pq … by (version, color)` = v2؛ `bin/status.sh` = deploy من 45 دقيقة → **قرار: rollback** (مش debugging) | IC + ops |
| +4m | `bash bin/rollback.sh` → 100% على blue (v1) فوراً (الـ blue لسه شغال) | ops |
| +5m…+10m | الـ 5m window ينزل → الـ alert resolved؛ k6 failures وقفت | observer |
| +15m | comms: "resolved"؛ الـ incident مقفول، postmortem متحدد له ميعاد | IC |

> لاحظ إن الـ detection خد ~45 دقيقة لأن 10% "صغيرة" بالنسبة للـ fast tier. الـ budget اللي اتصرف ≈ 0.1 × 45 دقيقة من traffic الشهر — احسبه في الـ postmortem. السؤال الأهم: ليه الـ gate ما مسكوش قبل المستخدمين؟ (blue/green من غير metric gate → الـ canary في [24](24-canary-single-host.md) كان هيعمل abort في دقيقة.)

**بعد الـ rollback:**

```bash
bash bin/status.sh                                     # ACTIVE=blue، MODE=single
cat state/green.env                                    # SRE_FAULT_ERROR_RATE=0.1 — "الـ bug"
pq 'job:student_app_sli_availability_errors:ratio_rate5m'
curl -s localhost:9093/api/v2/alerts | jq -r '.[] | "\(.labels.alertname) \(.status.state)"'
```

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر | المتوقع / الدرس |
|---|---|---|
| Outage كامل | `SLOT_ENV="SRE_FAULT_ERROR_RATE=1"` | الـ smoke بيفشل → `bluegreen.sh` بيقف قبل الـ switch (exit 1) — الـ gate البسيط مسك الحالة الكبيرة |
| Release unhealthy | `SLOT_ENV="SRE_FAULT_UNHEALTHY=true"` | `wait_ready` يفشل → مفيش switch. على ALB: [green-unhealthy-hosts](#student-app-lab-green-unhealthy-hosts) |
| بطء | `SLOT_ENV="SRE_FAULT_LATENCY_MS=500"` | [SLOLatencyFastBurn](#slolatencyfastburn) — والـ rollback نفسه |
| Prometheus أعمى | `docker compose -f docker-compose.prod.yml down` للـ app stack | [StudentAppNoTargetsUp](#studentappnotargetsup) + كل الـ SLO alerts مكتومة (inhibition) |
| Drill وصل للـ pager | شيل `drill="true"` route من `alertmanager.yml` (نسخة محلية) | SLODrill يوصل `/page` — ليه الترتيب و `continue: false` مهمين |
| Silence من غير expiry | `amtool silence add … --duration=8760h` | الـ alert الحقيقي الجاي مش هيوصل — كل silence بمدة وسبب |

## 9) الرجوع (Rollback)

الجدول في §5.2 هو الـ rollback. القاعدة: **اعرف أمر الـ rollback وجرّبه قبل الـ deploy**، والـ deploy اللي مالوش rollback واضح (migration destructive) محتاج خطة منفصلة.

## 10) المسح (Teardown) ⚠️

```bash
cd deploy/ec2/lb && : > state/green.env && : > state/blue.env     # شيل الـ fault env
docker run --rm --network student-app-obs_default --entrypoint amtool prom/alertmanager:v0.35.0 \
  --alertmanager.url=http://alertmanager:9093 silence query                     # مفيش silences منسية
aws cloudwatch describe-alarms --alarm-name-prefix student-app-lab --query 'MetricAlarms[?ActionsEnabled==`false`].AlarmName'
```

## 11) التكلفة (Cost)

| Resource | السعر التقريبي |
|---|---|
| Runbooks/postmortems | مجاني |
| SNS email | مجاني في حدود الـ free tier |
| PagerDuty/Opsgenie | فيه free tiers صغيرة — راجع أسعارهم |
| المحاكاة | نفس الستاك (محلي = مجاني) |

## 12) أسئلة Interview

<details><summary>إيه أول حاجة تعملها لما الـ page يرن؟</summary>

Ack، وبعدين أحدد الأثر (SLI: نسبة errors/latency، مين متأثر)، وأسأل "إيه اللي اتغيّر؟" (deploy، config، traffic، dependency). لو فيه تغيير حديث → rollback فوراً قبل أي تحقيق (mitigation-first). لو الأثر كبير أو الموضوع مكمّل → أعلن incident وأحدد IC، والـ IC مش هو اللي بيكتب commands.

</details>

<details><summary>ليه الـ IC مش المفروض يشتغل في الـ debugging؟</summary>

لأن حد لازم يشوف الصورة الكاملة: الأولويات، مين بيعمل إيه، إمتى نعمل rollback، الـ comms، الـ escalation. اللي غرقان في logs بيفقد الإحساس بالوقت ("خمس دقايق كمان وألاقيها" لمدة ساعة). الفصل بيمنع إن حد يقرر rollback وحد تاني يعمل fix في نفس الوقت.

</details>

<details><summary>إيه اللي يخلّي الـ postmortem blameless فعلاً؟</summary>

بيركّز على الأنظمة والقرارات في سياقها ("الـ deploy pipeline سمح بـ release من غير metric gate") مش على الأشخاص ("فلان عمل deploy"). الناس بتقول الحقيقة لما مش خايفين، والـ action items بتغيّر النظام (gate، alert، runbook، test) مش "خلي بالك المرة الجاية". وفيه timeline بالدقيقة وأرقام (detection، mitigation، budget المصروف).

</details>

<details><summary>عندك alert بيرن كل يوم ومحدش بيعمل حاجة — تعمل إيه؟</summary>

ده alert fatigue وبيدرّب الناس يتجاهلوا الـ pages. يا إما مش actionable (احذفه أو حوّله ticket/dashboard)، يا إما الـ threshold غلط (اربطه بالـ SLO burn rate بدل رقم ثابت)، يا إما فيه مشكلة حقيقية مزمنة (اعمل ticket بأولوية واعمل silence بمدة لحد ما تتصلح). وراجع الـ pages كل أسبوع.

</details>

<details><summary>الـ rollback مش متاح (migration مش backward compatible). تعمل إيه؟</summary>

Roll forward بـ hotfix، أو feature flag يقفل الـ code path، أو تقليل الأثر (drain الـ instances المتأثرة، read-only mode). الدرس للـ postmortem: كل migration لازم expand/contract عشان الـ rollback يفضل متاح ([95](95-zero-downtime-db-migrations.md))، والـ release checklist يسأل "الـ rollback بيشتغل؟".

</details>

<details><summary>إزاي تقيس إن الـ incident response بيتحسن؟</summary>

MTTD (من بداية الأثر للـ alert)، MTTA، MTTR (للـ mitigation مش للـ root cause)، الـ budget المصروف لكل incident، نسبة الـ incidents اللي اتكشفت بالـ alerts مقابل اللي بلّغ عنها مستخدمين، ونسبة الـ action items اللي اتقفلت. والـ game days ([75](75-chaos-engineering-fis.md)) بتدّيك قياس متحكم فيه.

</details>

## 13) Checklist

- [ ] الـ SNS subscription Confirmed وشفت alarm بيوصل email
- [ ] قريت كل runbook وجرّبت أوامر الـ triage في §5.1
- [ ] جرّبت أمر rollback لكل platform عندي (على الأقل `rollback.sh` و ECS/ASG)
- [ ] عملت المحاكاة الكاملة وكتبت timeline بالدقيقة
- [ ] كتبت postmortem بالـ template (§13.1) للمحاكاة
- [ ] مفيش silences أو disabled alarm actions منسية

### 13.1 Postmortem template (blameless)

```markdown
# Postmortem: <عنوان قصير> — <YYYY-MM-DD>
**Status:** draft / reviewed · **Severity:** SEV2 · **Authors:** … · **IC:** …

## Summary
جملتين: إيه حصل، الأثر، إزاي اتحل.

## Impact
- المدة: HH:MM → HH:MM (UTC) — X دقيقة
- المستخدمين/الـ requests المتأثرة: ~10% من الصفحات رجّعت 500
- Error budget: اتصرف X% من الـ 30-day budget (من SLO dashboard)
- Detection: MTTD = X دقيقة (alert: SLOAvailabilityFastBurn) · MTTR = X دقيقة

## Timeline (UTC)
| الوقت | الحدث |
|---|---|
| 10:00 | deploy v2 (blue/green) — smoke عدّى |
| 10:45 | SLOAvailabilityFastBurn firing |
| 10:47 | SEV2 declared، IC = … |
| 10:49 | rollback.sh → blue (v1) |
| 10:55 | alert resolved |

## Root cause(s) & contributing factors
- السبب المباشر: …
- ليه ما اتمسكش قبل المستخدمين: blue/green من غير metric gate؛ الـ smoke بيعمل request واحد
- ليه الـ detection خد 45 دقيقة: 10% < threshold الـ fast tier لحد ما الـ 1h window يتملي (متوقع رياضياً)

## What went well / what went poorly / where we got lucky
- …

## Action items
| Action | Type (prevent/detect/mitigate) | Owner | Due | Ticket |
|---|---|---|---|---|
| canary بـ metric gate بدل blue/green مباشر | prevent | … | … | … |
| k6 smoke بعد الـ switch بـ 2 دقيقة traffic | detect | … | … | … |
| runbook: إضافة أمر … | mitigate | … | … | … |

## Lessons learned
…
```
