# 71 — Metrics و Dashboards (Prometheus، Grafana، CloudWatch)

> **الهدف في سطر:** تفهم الـ RED/USE، والـ metrics اللي التطبيق بيطلّعها وليه الـ labels متصممة كده (cardinality، APCu، scrape لكل container)، تقرا كل panel في الـ Grafana dashboards (والـ `app_info` join)، وتعمل نفس الصورة على AWS بـ CloudWatch (ALB، Container Insights، ASG، RDS) — مرة import من الـ Console ومرة بالـ Terraform `observability` module.
> **المستوى:** Intermediate → Advanced · **الوقت:** ~4 ساعات · **التكلفة التقريبية:** سنتات (CloudWatch alarms/dashboards)
> **بيعتمد على:** [12](12-sre-lab-endpoints-and-local-observability.md) · [42](42-alb-asg-launch-template.md) أو [51](51-ecs-fargate-terraform.md) · **الملفات في الـ repo:** [`RequestMetrics.php`](../../../app/Support/Metrics/RequestMetrics.php) · [`RecordRequestMetrics.php`](../../../app/Http/Middleware/RecordRequestMetrics.php) · [`docker/php/zz-student-app.ini`](../../../docker/php/zz-student-app.ini) · [`prometheus.yml`](../../../observability/prometheus/prometheus.yml) · [`grafana/dashboards/`](../../../observability/grafana/dashboards) · [`cloudwatch/dashboard.json`](../../../observability/cloudwatch/dashboard.json) · [`cloudwatch/README.md`](../../../observability/cloudwatch/README.md) · [`modules/observability/`](../../../infra/terraform/modules/observability)

## 1) الفكرة (Concepts)

**RED** (للـ services، من وجهة نظر الـ request): **R**ate (req/s)، **E**rrors (نسبة الفشل)، **D**uration (توزيع الـ latency). **USE** (للـ resources): **U**tilization (CPU 70%)، **S**aturation (طابور/انتظار: run queue، PHP-FPM listen queue، CPU throttling)، **E**rrors (OOM kills، disk errors). جوجل بتجمعهم في الـ **4 golden signals**: latency، traffic، errors، saturation.

القاعدة: **الـ alerts على الـ symptoms (RED/SLO)**، والـ USE للتشخيص — CPU 90% مش مشكلة لو الـ latency تمام.

| المصطلح | المعنى |
|---|---|
| Counter | رقم بيزيد بس (أو يرجع صفر مع restart) — دايماً تقراه بـ `rate()` |
| Gauge | رقم بيطلع وينزل (`app_info`، memory) |
| Histogram | عدادات لكل bucket (`le`) + `_sum` + `_count` — بتتجمع (aggregatable) بين instances |
| Cardinality | عدد الـ time series = حاصل ضرب قيم كل الـ labels — أكبر سبب لوقوع Prometheus |
| Pull / scrape | Prometheus هو اللي بيروح لكل target؛ الـ target مش بيعرف Prometheus |
| Recording rule | query محسوبة مسبقاً ومحفوظة كـ series جديدة (أسرع ورخيصة في الـ dashboards والـ alerts) |
| `group_left` | join many-to-one في PromQL: تنقل labels من series لـ series تانية |

### 1.1 الـ metrics بتاعة التطبيق

| Metric | النوع | Labels | منين |
|---|---|---|---|
| `student_app_http_requests_total` | counter | `method`، `route`، `status` | `RecordRequestMetrics` (global middleware) |
| `student_app_http_request_duration_seconds` | histogram (`_bucket`، `_sum`، `_count`) | `method`، `route` (+ `le`) | نفس الـ middleware |
| `student_app_app_info` | gauge = 1 | `version`، `color` | `MetricsController` وقت الـ scrape (`APP_VERSION`، `DEPLOY_COLOR`) |

**قرارات التصميم (وده اللي هيتسأل فيه):**

1. **`route` = اسم الـ route** (`students.show`) أو الـ URI pattern، و `unmatched` لأي URL مش موجود — مش الـ URL الخام. عدد الـ series محدود ومعروف: (routes × methods × statuses) للـ counter، و (routes × methods) × 15 للـ histogram (12 bucket + `+Inf` + `_sum` + `_count`).
2. **مفيش `status` على الـ histogram** — الـ latency بالـ status كانت هتضرب الـ series في 6+ من غير فايدة كبيرة.
3. **Buckets حوالين الـ SLOs**: `[0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.3, 0.5, 1, 2.5, 5, 10]`. وجود `0.3` بالظبط بيخلي الـ latency SLI **مضبوط** (مش interpolation)، و `1` للـ p99 SLO.
4. **`version`/`color` مش على كل metric**: في `app_info` لوحدها وبتتعمل join وقت الـ query — مش بتضرب الـ cardinality، ومش محتاج تعدّل Prometheus مع كل deploy.
5. **`/metrics` نفسه مش بيتعد** (الـ middleware بيتخطى route `metrics`).

### 1.2 ليه APCu؟ وليه scrape لكل container؟

PHP-FPM **share-nothing**: كل request في worker process منفصل وكل حاجة في الـ memory بتموت مع نهاية الـ request. لو العدّاد في الـ memory العادية، كل scrape هيشوف request واحد. الحل: **APCu** — shared memory بين كل workers الـ FPM **جوه نفس الـ container** (adapter `APCng` من `promphp/prometheus_client_php`). [`zz-student-app.ini`](../../../docker/php/zz-student-app.ini): `apc.enabled = 1`، `apc.shm_size = 32M`، `apc.enable_cli = 0`.

- `RequestMetrics::storage()`: لو `METRICS_STORAGE=apcu` و APCu شغال → `APCng`، غير كده → `InMemory` (للـ tests: `phpunit.xml` فيه `METRICS_STORAGE=memory`).
- النتيجة: **كل container ليه عداداته**. Prometheus لازم يعمل scrape لكل container **مباشرة** (`app_blue:8080`، pod IP، task IP). لو عملت scrape من ورا الـ LB، كل scrape هيقع على container مختلف → العداد "بيقفز" لفوق وتحت → `rate()` يفتكره counter resets → أرقام زبالة. عشان كده الـ ALB بيقفل `/metrics` (404) والـ scrape container-to-container.
- العدادات بتبدأ من صفر مع كل container جديد → `rate()`/`increase()` بيتعاملوا مع ده. **عمرك ما تقرا الـ counter الخام** في dashboard.
- على K8s: annotations `prometheus.io/*` + ServiceMonitor/PodMonitor ([CONVENTIONS §8](../CONVENTIONS.md)). على ECS: مفيش Prometheus في المعمل — بنعتمد على CloudWatch (ALB + Container Insights)؛ لو عايز Prometheus على ECS محتاج ECS service discovery أو ADOT/AMP (مش متطبق).

### 1.3 PromQL اللي لازم تفهمه

```text
rate(student_app_http_requests_total[5m])                               # req/s لكل series
sum by (route) (rate(student_app_http_requests_total[$__rate_interval])) # جمّع قبل ما تعرض
histogram_quantile(0.95, sum by (le) (rate(student_app_http_request_duration_seconds_bucket[5m])))
```

- **جمّع الـ buckets (`sum by (le)`) قبل `histogram_quantile`** — متعملش average لـ p95 بتاع كل instance (الـ percentiles مش بتتجمع بالمتوسط).
- `histogram_quantile` بيعمل **interpolation خطي جوه الـ bucket**: لو الـ p95 الحقيقي 0.41s فهو بين `0.3` و `0.5` والرقم المعروض تقديري. الـ SLI بتاع "نسبة أسرع من 300ms" أدق بكتير (عدّ مباشر من bucket `le="0.3"`).
- `$__rate_interval` في Grafana = على الأقل 4 × scrape interval — بيمنع الـ gaps.

### 1.4 الـ `app_info` join

```text
sum by (version, color) (
  rate(student_app_http_requests_total{job="student-app"}[5m])
  * on(instance) group_left(version, color) student_app_app_info{job="student-app"}
)
```

`student_app_app_info` قيمته 1 وليه series واحدة لكل `instance`. الضرب `on(instance)` بيطابق كل request series بالـ `app_info` بتاع نفس الـ instance، و `group_left(version, color)` بينقل الـ labels دي للناتج (many requests ↔ one info). النتيجة: req/s لكل release — من غير ما `version` يبقى label على كل metric. ده نفس الـ pattern اللي الـ canary dashboard كله مبني عليه.

## 2) المعمارية (Architecture)

```text
 Local / EC2 host                                         AWS-native (stacks 40/50)
 ────────────────                                         ──────────────────────────
 app containers ──/metrics──► Prometheus (10s)            ALB ──► AWS/ApplicationELB (RequestCount, 5XX, TargetResponseTime,
   student_app_*                │ recording rules                  HealthyHostCount, RequestCountPerTarget…)
 cAdvisor ──► container_*       │ (SLIs per window)        ECS ──► AWS/ECS + ECS/ContainerInsights (enhanced)
 node-exporter ──► node_*       ▼                          ASG ──► AWS/EC2 CPU + AWS/AutoScaling Group* (enabled_metrics)
                              Grafana                      RDS ──► AWS/RDS (CPU, connections, latency, storage)
                    RED · SLO · Canary compare             Logs ──► StudentApp/<name> AppErrorLogs (metric filter)
                                                                     │
                                                    CloudWatch dashboard (Terraform: "student-app-lab"
                                                    أو import يدوي: "student-app-lab-slo") + alarms → SNS
```

## 3) المتطلبات (Prerequisites)

- [ ] ستاك [12](12-sre-lab-endpoints-and-local-observability.md) شغال محلياً (للجزء المحلي).
- [ ] stack `40-ec2-alb-asg` أو `50-ecs-fargate` متعمله apply (للجزء AWS) — أو اقرا بس.
- الأدوات: `aws`، `terraform`، `envsubst` (`gettext-base` على Ubuntu)، `jq`، `k6`.

## 4) الطريقة الأولى: AWS Console (يدوي)

### 4.1 Import للـ dashboard الجاهز

[`observability/cloudwatch/dashboard.json`](../../../observability/cloudwatch/dashboard.json) فيه tokens بدل الـ IDs: `${AWS_REGION}`، `${ALB_ARN_SUFFIX}`، `${TG_BLUE_ARN_SUFFIX}`، `${TG_GREEN_ARN_SUFFIX}`، `${ECS_CLUSTER}`، `${ECS_SERVICE}`، `${ASG_NAME}`، `${RDS_INSTANCE_ID}`.

هات القيم الحقيقية من الـ Console (أو من الـ outputs في §5):

- **EC2 → Load Balancers →** `student-app-lab-alb` → الـ ARN؛ الـ suffix = الجزء بعد `loadbalancer/` (مثال `app/student-app-lab-alb/0123456789abcdef`).
- **EC2 → Target Groups →** `student-app-lab-blue` / `-green` → الـ suffix = من `targetgroup/...`.
- ECS: cluster `student-app-lab` و service **`student-app-lab-app`** (اسم stack 50 الحقيقي — `terraform output -raw service_name`، وهو نفسه اللي في مثال `cloudwatch/README.md`).
- ASG: stack 40 بيعمل **`student-app-lab-blue`** (و `-green` لو `green_enabled`) — حط الـ blue في `ASG_NAME` (زي مثال الـ README).
- RDS: `student-app-lab-mysql`.

```bash
export AWS_REGION=us-east-1
export ALB_ARN_SUFFIX=app/student-app-lab-alb/<ID>
export TG_BLUE_ARN_SUFFIX=targetgroup/student-app-lab-blue/<ID>
export TG_GREEN_ARN_SUFFIX=targetgroup/student-app-lab-green/<ID>
export ECS_CLUSTER=student-app-lab ECS_SERVICE=student-app-lab-app
export ASG_NAME=student-app-lab-blue
export RDS_INSTANCE_ID=student-app-lab-mysql

envsubst < observability/cloudwatch/dashboard.json > /tmp/student-app-dashboard.json
grep -c '\${' /tmp/student-app-dashboard.json        # لازم 0
aws cloudwatch put-dashboard --dashboard-name student-app-lab-slo \
  --dashboard-body file:///tmp/student-app-dashboard.json
```

من الـ Console بدل الـ CLI: **CloudWatch → Dashboards → Create dashboard** (اسم `student-app-lab-slo`) → اقفل أول widget wizard → **Actions → View/edit source** → الصق الـ JSON بعد تبديل الـ tokens → **Update** → **Save**. الـ widgets بتاعة اللي مش عامله deploy (ECS لو أنت على ASG أو العكس) هتفضل فاضية.

### 4.2 الـ widgets بتعني إيه

| Widget | المعنى / الـ math |
|---|---|
| ALB requests and 5xx | `RequestCount`، `HTTPCode_Target_5XX_Count` (التطبيق فشل)، `HTTPCode_ELB_5XX_Count` (الـ ALB نفسه: مفيش target healthy، timeout = 502/503/504) |
| Availability % vs SLO | `100 × (1 − (Target 5xx + ELB 5xx) / RequestCount)` كل 5 دقايق، والخط عند 99.5 |
| Error-budget burn rate (5m و 1h) | error ratio ÷ 0.005؛ خطوط عند 14.4 و 6 و 1 ([73](73-slo-error-budget-burn-rate.md)) |
| Target response time p50/p95/p99 | `TargetResponseTime` بالـ percentile statistics |
| Latency SLI | `PR(:0.3)` = **percentile rank**: نسبة الـ requests اللي `TargetResponseTime ≤ 0.3s`؛ الخط 95 |
| Healthy / unhealthy targets | `HealthyHostCount` / `UnHealthyHostCount` لكل TG |
| ECS CPU / memory | `AWS/ECS` على الـ service |
| ASG CPU + in service | `AWS/EC2 CPUUtilization` بالـ `AutoScalingGroupName` و `GroupInServiceInstances` |
| ALB connections | `ActiveConnectionCount` / `NewConnectionCount` |
| RDS | CPU، connections، read/write latency، freeable memory، free storage |

نقط لازم تعرفها:
- `HTTPCode_*` **مش بتتبعت لما تبقى صفر** → من غير `FILL(m, 0)` الـ math بيطلع فاضي في الأوقات الهادية.
- مقاييس الـ ALB **مالهاش path dimension**: مش هتقدر تستبعد `/sre-lab/*` (الـ health checks مش محسوبة في `RequestCount` أصلاً، بس traffic الـ lab محسوب). الـ SLI الدقيق = Prometheus أو Athena على الـ access logs.
- `ECS/ContainerInsights RunningTaskCount` محتاج Container Insights على الـ cluster، و `AWS/AutoScaling Group*` محتاج group metrics collection على الـ ASG — الاتنين الـ Terraform بيفعّلهم.

### 4.3 Container Insights و الـ ASG metrics

- **ECS → Clusters → student-app-lab → Update cluster → Monitoring**: Container Insights **with enhanced observability** (الـ module بيحط `containerInsights = enhanced`). بعدها **CloudWatch → Container Insights** (أو **Infrastructure Monitoring**) → performance per task/container.
- **EC2 → Auto Scaling groups → student-app-lab-blue → Monitoring → Auto Scaling → Enable** group metrics collection (الـ module بيعمل `enabled_metrics`).
- EC2 detailed monitoring (1-min) **مقفول** في الـ launch template (`monitoring.enabled = false`) — الـ basic كل 5 دقايق. ده بيأثر على سرعة الـ CPU target tracking. Memory/disk على EC2 مش بيطلعوا من غير CloudWatch agent (الـ role فيه `CloudWatchAgentServerPolicy`، والـ Ansible role [`infra/ansible/roles/cloudwatch_agent`](../../../infra/ansible/roles/cloudwatch_agent) بيتكتب).

## 5) الطريقة التانية: Infrastructure as Code

### 5.1 Prometheus (local) — اتشرح في [12 §5.2](12-sre-lab-endpoints-and-local-observability.md)

الأهم هنا: `job_name: student-app` كل 10s، 3 targets بـ label `slot`، الـ cAdvisor `metric_relabel_configs` بيعمل `keep` لـ CPU/throttling/memory/network/fs/OOM بس، والـ retention 31d/5GB.

### 5.2 Terraform `observability` module

```bash
cd infra/terraform/stacks/40-ec2-alb-asg          # أو 50-ecs-fargate
terraform output -raw dashboard_url
terraform output sns_topic_arn
terraform state list | grep module.observability
```

الـ module ([`dashboard.tf`](../../../infra/terraform/modules/observability/dashboard.tf)) بيبني dashboard اسمه `var.name` (= `student-app-lab`)، 3 widgets في الصف، والـ widgets **conditional** على الـ inputs:

| Input | الـ widgets |
|---|---|
| `enable_alb_alarms` + `alb_arn_suffix` + `target_group_arn_suffixes` | Requests/min، 5xx/min (target vs ALB)، Error ratio % (خط الـ budget 0.5%)، Latency p50/p95/p99 (خطوط 0.3 و 1)، Healthy/unhealthy per color، **Requests per color (traffic split)** |
| `asg_name` / `asg_names` | ASG CPU % (scaling target 50%)، in-service instances |
| `ecs_cluster_name` + `ecs_service_name` | ECS service CPU / memory % |
| `rds_instance_id` | RDS CPU/connections، latency/free storage |
| `log_group_name` | App ERROR+ log lines / min (`StudentApp/<name>` `AppErrorLogs`) |
| (دايماً لو فيه alarms) | Alarm status strip تحت |

الـ alarms (التفاصيل والـ runbooks في [73](73-slo-error-budget-burn-rate.md) و [76](76-incident-response.md)):

| Alarm | الشرط |
|---|---|
| `student-app-lab-alb-5xx-ratio` | `(FILL(t5xx,0)+FILL(e5xx,0))/req` > `error_ratio_threshold` (0.01) على 5 دقايق |
| `student-app-lab-alb-latency-p95` | `TargetResponseTime` p95 > 0.3s على 5 دقايق |
| `student-app-lab-<blue\|green>-unhealthy-hosts` | `UnHealthyHostCount` > 0 لدقيقتين (`treat_missing_data = notBreaching`: الـ TG الفاضي مش incident) |
| `student-app-lab-slo-burn-{fast-1h,fast-5m,slow-6h,slow-30m}` | children من غير actions |
| `student-app-lab-slo-fast-burn` / `-slo-slow-burn` | composites → SNS |
| `student-app-lab-rds-cpu` / `-rds-free-storage` | CPU > 80% لـ 10 دقايق / free storage < 2 GiB |

الـ stack 60 (EKS) بيستخدم الـ module بـ `enable_alb_alarms = false` (الـ ALB هناك بيعمله الـ Load Balancer Controller مش Terraform).

### 5.3 الـ Grafana dashboards — panel بـ panel

**Student App · RED** (`student-app-red`) — variables: `datasource`، `job`، `route`:

| Row | Panels | اقراها إزاي |
|---|---|---|
| Overview (app routes بس) | Request rate، 5xx ratio (5m) = `job:student_app_sli_availability_errors:ratio_rate5m`، p95 latency (5m)، Faster than 300ms (5m) = الـ latency SLI، Instances up، Running releases (جدول `app_info`) | الصف ده = "الخدمة كويسة؟" في 5 ثواني. 7.2% في الـ 5xx ratio = 14.4× burn |
| Rate | Requests/s by route، Requests/s by status | راقب **419** (CSRF/session)، **429** (throttle)، 5xx |
| Errors | 5xx ratio by route (فيه `sre-lab.error` عمداً)، 4xx by route and status | الـ 4xx مش بتحرق الـ SLO، بس 419 = مشكلة sessions بين الـ replicas |
| Duration | Latency percentiles (خطوط 300ms و 1s)، p95 by route، Share under 300ms by route | مين الـ route البطيء؟ (`reports.index` عادةً) |
| Per release | Requests/s by release، 5xx ratio by release، p95 by release (كلهم بالـ `app_info` join) | الـ traffic split والمقارنة وقت blue/green/canary/A-B |
| Saturation | CPU cores by compose service (cAdvisor)، Memory working set، Host CPU busy / load1 per core | USE: هل الـ CPU هو اللي خلّى الـ latency تطلع؟ |

**Student App · SLOs & error budget** (`student-app-slo`) — اتشرح بالتفصيل في [73 §5.5](73-slo-error-budget-burn-rate.md).

**Student App · Canary compare** (`student-app-canary`) — variables: `by` (`version` أو `color`)، `stable`، `canary` (من `label_values(student_app_app_info, $by)`):
- Stable/Canary 5xx ratio، **Canary − stable** (موجب = الـ canary أسوأ؛ قارنه بالـ budget 0.5% مش بالصفر)، Stable/Canary p95، **Canary traffic share** (لازم يطابق الـ weight 10/25/50/100%)، والـ time series، وجدول الـ instances.
- ده بالظبط الحكم اللي `canary.sh` بيعمله بالـ awk ([24](24-canary-single-host.md)) بس بصرياً ومقارنةً بالـ baseline.

## 6) الـ Deploy

### 6.1 محلياً

```bash
docker compose up -d --wait
docker compose -f observability/compose/docker-compose.yml up -d
k6 run -e BASE_URL=http://localhost:8080 -e LOADTEST_USERS=5 -e VUS=10 -e DURATION=10m loadtest/k6/load.js
```

افتح RED واختار `job=student-app`. وفي نص الـ test شغّل `SRE_FAULT_LATENCY_MS=250 docker compose up -d --no-build --wait app` وشوف الـ "Faster than 300ms" بينزل والـ p95 بيطلع (والـ instance اتعمله recreate فالعدادات بدأت من صفر — Prometheus مكمّل عادي).

### 6.2 Blue/green محلياً + canary compare

مع ستاك [23](23-bluegreen-single-host.md)/[24](24-canary-single-host.md) شغال، و `canary.sh` شغال، افتح **Canary compare** → `by=color` → `stable=blue`، `canary=green`. الـ "Canary traffic share" هيمشي 10 → 25 → 50 → 100.

### 6.3 على AWS

```bash
k6 run -e BASE_URL=http://<ALB_DNS> -e LAB_TOKEN=<TOKEN> -e LOADTEST_USERS=20 -e VUS=20 -e DURATION=15m -e P95_MS=300 loadtest/k6/load.js
```

(أو `perf-gate.yml` من GitHub — [74](74-load-testing-k6.md).) افتح الـ `dashboard_url` وشوف Requests per color والـ latency والـ ASG/ECS CPU.

## 7) التحقق (Verify)

```bash
# Prometheus: cardinality بتاعة التطبيق
curl -s localhost:9090/api/v1/query --data-urlencode 'query=count by (__name__) ({__name__=~"student_app_.*"})' | jq -r '.data.result[] | "\(.metric.__name__) \(.value[1])"'
# الـ join شغال
curl -s localhost:9090/api/v1/query --data-urlencode 'query=sum by (version,color) (rate(student_app_http_requests_total[5m]) * on(instance) group_left(version,color) student_app_app_info)' | jq '.data.result'

# CloudWatch
aws cloudwatch list-dashboards --query 'DashboardEntries[].DashboardName'
aws cloudwatch get-metric-statistics --namespace AWS/ApplicationELB --metric-name RequestCount \
  --dimensions Name=LoadBalancer,Value=<ALB_ARN_SUFFIX> --start-time $(date -u -d '-1 hour' +%FT%TZ) \
  --end-time $(date -u +%FT%TZ) --period 300 --statistics Sum
aws cloudwatch describe-alarms --alarm-name-prefix student-app-lab --query 'MetricAlarms[].[AlarmName,StateValue]' --output table
aws cloudwatch describe-alarms --alarm-types CompositeAlarm --alarm-name-prefix student-app-lab --query 'CompositeAlarms[].[AlarmName,StateValue]'
```

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر | المتوقع |
|---|---|---|
| Scrape من ورا الـ LB | ضيف target `proxy:80` في `prometheus.yml` (ستاك LB) | nginx بيرجّع 404 لـ `/metrics` (مقفول على الـ proxy) — ولو فتحته الـ counters هتقفز بين الـ slots |
| `METRICS_STORAGE=memory` في الـ container | env في `app.env` + redeploy | كل scrape بيشوف تقريباً صفر — APCu هو اللي بيجمع الـ workers |
| Cardinality attack | `for i in $(seq 1 1000); do curl -s -o /dev/null localhost:8080/random-$i; done` | series واحدة بس `route="unmatched"` — التصميم صامد. لو كان الـ label هو الـ URI: 1000 series |
| Percentile متوسط | في Grafana اكتب `avg(histogram_quantile(0.95, rate(..._bucket[5m])))` من غير `sum by (le)` | رقم مختلف وغلط عن الـ panel الأصلي |
| مفيش traffic في CloudWatch | سيب الـ ALB هادي | الـ 5xx widgets فاضية لو شلت `FILL()` |
| ASG metrics | اقفل group metrics collection من الـ Console | widget "in-service instances" يفضى |

## 9) الرجوع (Rollback)

- Dashboard اتبوظ من الـ UI: Grafana provisioned من git (reload/restart بيرجّعه)؛ CloudWatch: `terraform apply` بيرجّع dashboard الـ module، و `put-dashboard` بالـ JSON بيرجّع الـ import.
- Prometheus config غلط: `promtool check config` قبل الـ reload — لو الـ reload فشل، Prometheus بيكمّل بالـ config القديم.

## 10) المسح (Teardown) ⚠️

```bash
aws cloudwatch delete-dashboards --dashboard-names student-app-lab-slo      # الـ import اليدوي
cd infra/terraform/stacks/40-ec2-alb-asg && terraform destroy               # بيمسح dashboard الـ module والـ alarms والـ SNS
docker compose -f observability/compose/docker-compose.yml down -v
```

## 11) التكلفة (Cost)

| Resource | السعر التقريبي (us-east-1 — تقريبي، راجع صفحة الأسعار) |
|---|---|
| CloudWatch dashboards | أول 3 مجاناً، بعدها ~$3/dashboard/شهر |
| Standard alarm | ~$0.10/alarm-metric/شهر — alarm بـ metric math بيتحاسب على كل metric جواه (الـ burn alarms 3 metrics لكل واحد) |
| Composite alarm | ~$0.50/شهر |
| Custom metrics (`AppErrorLogs`) | ~$0.30/metric/شهر بعد الـ free tier |
| Container Insights (enhanced) | بيتحاسب حسب الـ observations/metrics — راجع صفحة الأسعار قبل ما تسيبه شغال |
| ALB/ECS/RDS metrics الأساسية | مجاناً |
| Prometheus/Grafana محلي | مجاني (البديل الـ managed: Amazon Managed Service for Prometheus + Managed Grafana) |

الـ stack 40 README بيقدّر الـ alarms بـ ~$3/شهر.

## 12) أسئلة Interview

<details><summary>RED ولا USE ولا golden signals — تستخدم إيه إمتى؟</summary>

RED للـ services (الـ SLOs والـ paging مبنية عليه لأنه بيوصف تجربة المستخدم). USE للـ resources (CPU، memory، disks، connection pools) للتشخيص والـ capacity planning. الـ 4 golden signals = RED + saturation. Alerts على RED/SLO، dashboards فيها الاتنين جنب بعض عشان تربط "الـ latency طلعت" بـ "PHP-FPM workers saturated".

</details>

<details><summary>ليه PHP محتاجة APCu عشان Prometheus، وإيه البدائل؟</summary>

PHP-FPM share-nothing: الـ memory بتموت مع كل request، فالعدادات لازم تبقى في مكان مشترك. APCu = shared memory جوه الـ container (سريع، من غير network)، بس per-container فلازم scrape لكل container. البدائل: Redis كـ storage (مشترك بين containers بس بيضيف network hop و dependency في الـ hot path)، StatsD/OTel push لـ collector جنب التطبيق، أو الاعتماد على metrics الـ LB/nginx. الـ trade-off: APCu أبسط وأسرع بس العدادات بتضيع مع الـ restart (ومقبول لأن `rate()` بيتعامل).

</details>

<details><summary>إزاي تعرض metrics لكل release من غير ما تحط version على كل metric؟</summary>

info metric pattern: `student_app_app_info{version,color} 1` وبعدين `* on(instance) group_left(version,color)` وقت الـ query. الـ cardinality بتاعة الـ request metrics مبتتأثرش، والـ deploy مش محتاج config. ده نفس فكرة `kube_pod_labels` و `node_uname_info`.

</details>

<details><summary>ليه الـ latency SLI "نسبة أسرع من 300ms" وليس p95؟</summary>

النسبة بتتجمع بين instances وبين windows (ratio of sums) وبتتحوّل لـ error budget مباشرة (5% من الـ requests مسموح يبقوا بطيئين). الـ p95 مش بيتجمع (متوسط الـ p95s غلط)، و `histogram_quantile` تقديري جوه الـ bucket. ولازم يبقى فيه bucket عند الـ threshold بالظبط — عشان كده `0.3` موجود.

</details>

<details><summary>CloudWatch ALB metrics مقابل Prometheus app metrics — الفرق إيه؟</summary>

ALB: بيشوف اللي المستخدم شافه فعلاً بما فيه 502/503/504 اللي الـ ALB نفسه ولّدها (التطبيق ما وصلوش request)، ومن غير ما تعمل instrumentation — بس مفيش path/route dimension. Prometheus: route-level ودقيق وتقدر تستبعد الـ lab/probes، بس مش بيشوف الأعطال اللي قبل التطبيق. الصح: الاتنين — SLI من الـ edge للـ paging العام، و app metrics للتشخيص و per-route SLOs.

</details>

<details><summary>Grafana dashboard "as code" — ليه ومنين؟</summary>

الـ dashboards هنا JSON في git، provisioned (فولدر Student App)، وبتستخدم variable `${datasource}` بدل UID ثابت (الـ `observability-lint.yml` بيرفض أي UID hard-coded) — فنفس الـ JSON يشتغل على Prometheus المحلي، kube-prometheus-stack على EKS، أو AMP. الـ review بيبقى PR، والـ rollback `git revert`. البدائل: Grafonnet/Jsonnet أو Terraform Grafana provider.

</details>

## 13) Checklist

- [ ] أقدر أشرح RED/USE وأحدد كل panel تحت أنهي واحد
- [ ] حسبت الـ cardinality بتاعة metrics التطبيق بـ PromQL
- [ ] كتبت query بالـ `app_info` join وفهمت `group_left`
- [ ] عملت import لـ `dashboard.json` بـ `envsubst` (بالأسماء من الـ outputs: `student-app-lab-app`، `student-app-lab-blue`)
- [ ] فتحت dashboard الـ Terraform module وقارنته بالـ import
- [ ] فعّلت/اتأكدت من Container Insights و ASG group metrics
- [ ] جرّبت تمارين الـ break-it (LB scrape، `unmatched`)
- [ ] مسحت الـ dashboard اليدوي
