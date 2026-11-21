# 73 — SLI/SLO و Error budget و Burn-rate alerts

> **الهدف في سطر:** تحسب الـ SLO بالأرقام (99.5% / 30 يوم → كام دقيقة error budget)، تفهم الـ burn rate والـ multi-window multi-burn-rate alerts (14.4× / 6× / 1×) وليه نافذتين، تقرا الـ recording rules والـ alerts الحقيقية وتثبتها بـ `promtool test`، تفهم الـ drill SLI ليه موجود، وتشغّل `error-budget-burn.js` وتشوف نفس المنطق في CloudWatch composite alarms — وتكتب SLO policy بتقول هيحصل إيه لما الـ budget يخلص.
> **المستوى:** Advanced · **الوقت:** ~4 ساعات · **التكلفة التقريبية:** سنتات (CloudWatch alarms)
> **بيعتمد على:** [12](12-sre-lab-endpoints-and-local-observability.md) · [71](71-metrics-dashboards.md) · **الملفات في الـ repo:** [`rules/recording.yml`](../../../observability/prometheus/rules/recording.yml) · [`rules/slo-burn-rate.yml`](../../../observability/prometheus/rules/slo-burn-rate.yml) · [`rules/tests/slo-burn-rate.test.yml`](../../../observability/prometheus/rules/tests/slo-burn-rate.test.yml) · [`alertmanager.yml`](../../../observability/prometheus/alertmanager.yml) · [`k8s/prometheusrule-slo.yaml`](../../../observability/k8s/prometheusrule-slo.yaml) · [`error-budget-burn.js`](../../../loadtest/k6/error-budget-burn.js) · [`modules/observability/main.tf`](../../../infra/terraform/modules/observability/main.tf) · [`student-app-slo.json`](../../../observability/grafana/dashboards/student-app-slo.json)

## 1) الفكرة (Concepts)

| المصطلح | المعنى |
|---|---|
| SLI | مقياس لتجربة المستخدم كنسبة: **good events ÷ valid events** |
| SLO | الهدف للـ SLI على window: "99.5% من الـ requests مش 5xx على 30 يوم rolling" |
| SLA | عقد مع العميل (فلوس/تعويض) — دايماً أرخى من الـ SLO الداخلي |
| Error budget | `1 − SLO` — الفشل المسموح. مش "عيب"، ده **ميزانية** تصرفها على الـ releases والتجارب |
| Burn rate | سرعة صرف الـ budget بالنسبة للمعدل المسموح: `error ratio ÷ (1 − SLO)` |
| Multi-window | الـ alert محتاج نافذة طويلة (الأثر كبير) **و** نافذة قصيرة (لسه بيحصل) مع بعض |
| Drill SLI | SLI منفصل لـ traffic الـ game day (`/sre-lab/error`) — مش بيلمس الـ budget الحقيقي |

### 1.1 الـ SLIs بتوعنا (CONVENTIONS §5)

| SLI | Good | Valid | SLO |
|---|---|---|---|
| Availability | requests مش 5xx | كل الـ requests على app routes: **من غير** `sre-lab.*` و `up` و `health.ready` و `metrics` | **99.5%** / 30d |
| Latency | requests في bucket `le="0.3"` (≤ 300ms) | نفس الـ routes | **95%** |
| Latency tail | — | — | p99 < 1s (alert منفصل، ticket) |

**ليه الاستبعاد؟** `sre-lab.*` بتفشل بالطلب (هي أداة)، و `up`/`health.ready` بيتنادوا كل 10 ثواني من كل LB/probe ودايماً 200 ورخاص — لو حسبتهم هيخففوا (dilute) الـ errors الحقيقية: 100 error على صفحات حقيقية وسط 10,000 probe ناجح = 1% بدل 50%. و `metrics` = الـ scraper نفسه.

### 1.2 الحساب: 99.5% / 30 يوم

```text
window    = 30 يوم = 30 × 24 × 60 = 43,200 دقيقة
budget    = 1 − 0.995 = 0.005 (0.5%)
بالوقت    = 43,200 × 0.005 = 216 دقيقة = 3h 36m   (لو الـ traffic منتظم وكل الـ requests فشلت)
بالطلبات  = 1,000,000 request/شهر × 0.005 = 5,000 request فاشل مسموح
latency   = 5% من الـ requests مسموح تبقى > 300ms = 50,000 من المليون
```

"3h 36m" تبسيط: الـ budget مبني على **requests**، فـ outage ساعة بالليل (traffic قليل) بيصرف أقل من ساعة وقت الذروة.

### 1.3 الـ burn rate

```text
burn rate B = observed error ratio / 0.005
B = 1      → هتصرف الـ budget بالظبط في 30 يوم (error ratio 0.5%)
الوقت لحد ما الـ budget يخلص   = 30 يوم / B
نسبة الـ budget اللي بتتصرف في نافذة w = B × w / 30 يوم
```

| Severity | Burn | Long AND short window | `for` | error ratio threshold | budget اتصرف لما يضرب | الـ budget يخلص في |
|---|---|---|---|---|---|---|
| page | 14.4× | 1h AND 5m | 2m | 14.4 × 0.005 = **7.2%** | 14.4 × 1h/720h = **2%** | 30d/14.4 ≈ **50 ساعة** |
| page | 6× | 6h AND 30m | 15m | **3%** | 6 × 6/720 = **5%** | **5 أيام** |
| ticket | 1× | 3d AND 6h | 1h | **0.5%** | 1 × 72/720 = **10%** | **30 يوم** |

الأرقام 2%/5%/10% مش عشوائية (Google SRE Workbook ch.5): "لو صرفت 2% من الشهر في ساعة، صحّي حد".

### 1.4 ليه نافذتين؟

- **النافذة الطويلة** (1h): significance — spike لمدة دقيقة مش هيعدّي 7.2% على ساعة كاملة → أقل false positives (precision).
- **النافذة القصيرة** (5m = 1/12 من الطويلة): بتثبت إن المشكلة **لسه بتحصل** → لما تصلّح، الـ 5m بتنزل تحت الـ threshold في دقايق والـ alert يعمل **resolve** بسرعة (reset time). من غيرها، الـ 1h ratio هيفضل فوق الـ threshold لحد ساعة بعد الإصلاح وناس هتتصحى على incident خلص.
- **ليه 3 tiers؟** الـ fast بيمسك الحرايق الكبيرة بسرعة؛ الـ slow بيمسك التسريب المتوسط (3% errors) اللي الـ fast مش هيشوفه أبداً؛ الـ ticket للـ "embers" اللي هتصرف الـ budget في الشهر.

### 1.5 الـ detection time (الحسبة اللي في header الـ script)

مع traffic ثابت وتاريخ نضيف، ratio النافذة W بعد t دقيقة من بداية errors بنسبة e = `e × t / W`. الـ alert يضرب لما يعدّي الـ threshold T:

```text
t = W × T / e         (+ مدة الـ for)
outage كامل (e = 1):     fast: t = 60 × 0.072 / 1   ≈ 4.3 دقيقة  (+2m for)
B = 20 (e = 10%):        fast: t = 60 × 0.072 / 0.1 ≈ 43 دقيقة   (+2m)
                         slow: t = 360 × 0.03 / 0.1 = 108 دقيقة  (+15m)
B = 8  (e = 4%):         fast: مستحيل (4% < 7.2%)  ·  slow: t = 360 × 0.03/0.04 = 270 دقيقة
B = 2  (e = 1%):         ticket: t = 4320 × 0.005/0.01 = 2160 دقيقة = 36 ساعة
```

ده الـ trade-off اللي الـ multi-window بيعمله عمداً: **سريع للحرايق الكبيرة، بطيء للصغيرة** — والصغيرة فعلاً مش محتاجة تصحّي حد الساعة 3 الفجر.

## 2) المعمارية (Architecture)

```text
 student_app_http_requests_total / _duration_seconds_bucket   (per container, scrape 10s)
        │
        ▼  recording rules (rules/recording.yml) — كل 30s (والـ 30d كل 5m)
 job:student_app_sli_availability_errors:ratio_rate{5m,30m,1h,2h,6h,1d,3d,30d}
 job:student_app_sli_latency_good:ratio_rate{…}          student_app:…  (overall من غير job)
 job:student_app_sli_drill_errors:ratio_rate{5m…3d}      (route="sre-lab.error" بس)
 student_app:slo_objective:ratio{slo="availability"|"latency"}
        │
        ▼  alerting rules (rules/slo-burn-rate.yml)
 SLOAvailability{Fast,Slow,Budget}Burn · SLOLatency{Fast,Slow,Budget}Burn · SLOLatencyTailP99High
 SLODrill{Fast,Slow,Budget}Burn (drill="true") · StudentAppNoTargetsUp
        │ labels: severity (page|ticket) · slo · burn (fast|slow|budget) · drill
        ▼
 Alertmanager: drill="true" → receiver drill (stop) │ severity=page → pager │ severity=ticket → tickets
               inhibit: fast يسكّت slow/budget لنفس الـ slo · slow يسكّت budget · NoTargetsUp يسكّت كل slo
                                                                    runbook_url → 76-incident-response.md

 AWS (من غير Prometheus): ALB RequestCount + Target/ELB 5XX ─► 4 child metric-math alarms (no actions)
   student-app-lab-slo-burn-fast-1h AND -fast-5m ─► composite student-app-lab-slo-fast-burn ─► SNS
   student-app-lab-slo-burn-slow-6h AND -slow-30m ─► composite student-app-lab-slo-slow-burn ─► SNS
```

## 3) المتطلبات (Prerequisites)

- [ ] ستاك [12](12-sre-lab-endpoints-and-local-observability.md) شغال (Prometheus + Alertmanager + Grafana + الـ app).
- [ ] اختياري: stack 40 أو 50 للـ CloudWatch part.
- الأدوات: `k6`، `docker` (لـ `promtool`)، `jq`.

## 4) الطريقة الأولى: AWS Console (يدوي) — burn-rate composite alarm بإيدك

اعمل الـ fast tier بإيدك مرة عشان تفهم اللي الـ Terraform بيعمله (في حساب/stack من غير الـ module، أو بأسماء مختلفة عشان متتعارضش):

1. **SNS → Topics → Create topic** → Standard → `student-app-lab-alerts-manual` → **Create subscription** → Email → أكّد من الإيميل.
2. **CloudWatch → Alarms → Create alarm → Select metric → ApplicationELB → Per AppELB Metrics** → اختار للـ ALB بتاعك: `RequestCount`، `HTTPCode_Target_5XX_Count`، `HTTPCode_ELB_5XX_Count` → **Select metric**.
3. في **Graphed metrics**: غيّر الـ Statistic للتلاتة لـ **Sum** والـ Period لـ **1 hour**، وغيّر الـ Ids لـ `req`، `t5xx`، `e5xx`.
4. **Add math → Start with empty expression**: `(FILL(t5xx, 0) + FILL(e5xx, 0)) / req` → اختار الـ expression ده بس كـ metric للـ alarm.
5. Conditions: **Greater** than `0.072` · Datapoints 1 of 1 · Missing data: **Treat missing data as good (not breaching)**.
6. Notification: **Remove** (الـ child مش بيبعت حاجة) → Name: `manual-slo-burn-fast-1h` → Create.
7. كرر بـ Period **5 minutes** → `manual-slo-burn-fast-5m`.
8. **Alarms → Create alarm → Create composite alarm** → Conditions:
   ```text
   ALARM("manual-slo-burn-fast-1h") AND ALARM("manual-slo-burn-fast-5m")
   ```
   Notification → `student-app-lab-alerts-manual` → Name `manual-slo-fast-burn` → Create.

> 💡 ليه الـ children من غير actions؟ لو الـ 5m child بعت إيميل لوحده، كل spike لمدة 5 دقايق هيعمل noise — ده بالظبط اللي الـ multi-window جاي يمنعه. الـ composite بس هو اللي بيكلّم البشر.

> ⚠️ **Known limitation (موثّقة في [CONVENTIONS §5](../CONVENTIONS.md)):** الـ SLI هنا من الـ ALB — **مش بيقدر يستبعد `/sre-lab/*`**. يعني `error-budget-burn.js MODE=lab` (أو أي drill على `/sre-lab/error`) ضد الـ ALB **هيشغّل** الـ CloudWatch burn-rate alarms ويبعت إيميلات حقيقية، رغم إنه في Prometheus بيروح للـ drill SLI بس. على AWS اعمل الـ drills وأنت عارف ده: اعمل mute للـ SNS (unsubscribe مؤقت) أو disable actions على الـ composites وقت الـ game day (`aws cloudwatch disable-alarm-actions --alarm-names student-app-lab-slo-fast-burn student-app-lab-slo-slow-burn`، ورجّعها بـ `enable-alarm-actions`).

## 5) الطريقة التانية: as Code

### 5.1 الـ recording rules ([`recording.yml`](../../../observability/prometheus/rules/recording.yml))

```yaml
- record: job:student_app_sli_availability_errors:ratio_rate5m
  expr: |-
    (
      sum by (job) (rate(student_app_http_requests_total{route!~"sre-lab\\..*|up|health\\.ready|metrics", status=~"5.."}[5m]))
      or
      0 * sum by (job) (rate(student_app_http_requests_total{route!~"sre-lab\\..*|up|health\\.ready|metrics"}[5m]))
    )
    /
    sum by (job) (rate(student_app_http_requests_total{route!~"sre-lab\\..*|up|health\\.ready|metrics"}[5m]))
```

- **ratio of sums** مش average of ratios: instance خامل بـ 0/1 مينفعش يوزن زي instance شايل 1000 req/s.
- **`or 0 * sum(...)`**: لو مفيش ولا 5xx، البسط **فاضي** (مش صفر) والقسمة كلها تطلع فاضية → الـ alert "مش شايف" حاجة والـ dashboard فاضي. الحيلة دي بترجّع **0** لما فيه traffic ومفيش errors.
- مفيش traffic خالص → `0/0 = NaN` → NaN عمره ما بيعدّي threshold → مفيش alert (ومقصود).
- كل window: `5m, 30m, 1h, 2h, 6h, 1d, 3d` في groups عادية، و `30d` في group `student-app-slo-30d` بـ `interval: 5m` (غالية وبطيئة الحركة).
- `job:` (لكل job — app/app_blue/app_green كلهم `job="student-app"`) و `student_app:` (overall).
- الـ latency: `sum(rate(..._bucket{le="0.3"}))/sum(rate(..._count))` — good ratio (مش error).
- الـ drill: نفس الشكل بـ `route="sre-lab.error"` بس.
- `student_app:slo_objective:ratio` = `vector(0.995)` بـ `slo="availability"` و `vector(0.95)` بـ `slo="latency"` — خطوط الـ SLO في الـ dashboard.

### 5.2 الـ alerts ([`slo-burn-rate.yml`](../../../observability/prometheus/rules/slo-burn-rate.yml))

| Alert | expr (مختصر) | for | labels |
|---|---|---|---|
| `SLOAvailabilityFastBurn` | `ratio_rate1h > 14.4*0.005 and ratio_rate5m > 14.4*0.005` | 2m | `severity=page slo=availability burn=fast` |
| `SLOAvailabilitySlowBurn` | `ratio_rate6h > 6*0.005 and ratio_rate30m > …` | 15m | `page / availability / slow` |
| `SLOAvailabilityBudgetBurn` | `ratio_rate3d > 0.005 and ratio_rate6h > 0.005` | 1h | `ticket / availability / budget` |
| `SLOLatencyFastBurn` | `(1 - latency_good_1h) > 14.4*0.05 and (1 - …5m) > …` | 2m | `page / latency / fast` |
| `SLOLatencySlowBurn` | `6×` على 6h و 30m | 15m | `page / latency / slow` |
| `SLOLatencyBudgetBurn` | `1×` على 3d و 6h | 1h | `ticket / latency / budget` |
| `SLOLatencyTailP99High` | `histogram_quantile(0.99, sum by (job, le) (rate(..._bucket{app routes}[10m]))) > 1` | 15m | `ticket / latency-tail` |
| `SLODrillFastBurn` / `SlowBurn` / `BudgetBurn` | نفس الأرقام على `job:student_app_sli_drill_errors:ratio_rate*` | 2m/15m/1h | + `slo=availability-drill`، `drill="true"` |
| `StudentAppNoTargetsUp` | `sum by (job) (up{job="student-app"}) == 0` | 2m | `severity=page` |

لاحظ إن الـ latency budget = **0.05** (5% من الـ requests)، فـ 14.4× = 72% من الـ requests أبطأ من 300ms. وكل alert فيه `summary`، `description` (بـ `humanizePercentage`)، و `runbook_url` → `…/76-incident-response.md#<alertname lowercased>` (مثلاً `#sloavailabilityfastburn`) — [76](76-incident-response.md) فيه heading باسم كل alert بالظبط، فالـ link بيفتح الـ runbook نفسه. (نفس الـ URLs في نسخة الـ PrometheusRule وفي الـ promtool tests.)

**Low-traffic caveat** (مكتوب في الملف): مع requests قليلة، error واحد = ratio كبير. في production تضيف شرط minimum traffic، مثلاً (تمرين — مش في الـ repo):

```text
… and sum by (job) (rate(student_app_http_requests_total{route!~"sre-lab\\..*|up|health\\.ready|metrics"}[1h])) > 0.05
```

### 5.3 Alertmanager ([`alertmanager.yml`](../../../observability/prometheus/alertmanager.yml))

- `group_by: [alertname, job, slo]` — notification واحدة لكل SLO مش لكل window.
- Routes بالترتيب: **`drill="true"` → `drill`** (`continue: false` — بيقف هنا، عمره ما بيوصل للـ pager)، ثم `severity="page"` → `pager` (`group_wait: 10s`، `repeat_interval: 1h`)، ثم `severity="ticket"` → `tickets` (email + webhook، `repeat_interval: 24h`).
- Inhibition: `burn="fast"` يسكّت `burn=~"slow|budget"` لنفس `job`+`slo`؛ `slow` يسكّت `budget`؛ و `StudentAppNoTargetsUp` يسكّت أي alert فيه `slo` (لو مفيش scrape، الـ SLO alerts noise فوق الـ outage page).
- الـ receivers placeholders على `alert-sink` (`/default`، `/page`، `/ticket`، `/drill`). في الحقيقة: `pagerduty_configs`/`opsgenie_configs`/`slack_configs` والـ secrets بـ `*_file` (مش في git).

### 5.4 promtool unit tests ([`slo-burn-rate.test.yml`](../../../observability/prometheus/rules/tests/slo-burn-rate.test.yml))

| Test | Input | بيثبت إيه |
|---|---|---|
| 50% errors | 0.5 req/s ناجح + 0.5 req/s 500 على `students.index` | الـ ratio_rate5m = 0.5 عند 10m؛ `SLOAvailabilityFastBurn` firing عند 10m؛ `SLOAvailabilitySlowBurn` **مش** firing عند 10m (لسه pending بسبب `for: 15m`) و firing عند 20m |
| healthy | 0.1% errors | مفيش ولا alert (fast/slow/budget/drill) على 10m، 1h، 3h |
| drill isolation | traffic سليم على `students.index` + 50% errors على `sre-lab.error` | `student_app:sli_availability_errors:ratio_rate5m` = **0**؛ `SLOAvailabilityFastBurn` ساكت؛ `SLODrillFastBurn` firing بـ `drill="true"` |
| latency | 20% بس في `le="0.3"` | `SLOLatencyFastBurn` firing (80% بطيء = 16×)؛ الـ availability ساكت |
| targets down | `up` = 0 للـ blue والـ green | `StudentAppNoTargetsUp` firing عند 5m |

```bash
docker run --rm -v "$PWD/observability/prometheus:/p:ro" -w /p --entrypoint promtool \
  prom/prometheus:v3.16.0 test rules rules/tests/slo-burn-rate.test.yml
docker run --rm -v "$PWD/observability/prometheus:/p:ro" -w /p --entrypoint promtool \
  prom/prometheus:v3.16.0 check rules rules/recording.yml rules/slo-burn-rate.yml
```

Notation: `'0+30x60'` = ابدأ من 0 وزوّد 30 كل `interval` (1m)، 60 مرة = 0.5 req/s لمدة ساعة. promtool بيعدّ الـ **firing** بس (الـ pending = "مفيش alert") — وده اللي بيخلّيك تختبر الـ `for`. والـ CI (`observability-lint.yml`) بيشغّلهم + بيتأكد إن [`prometheusrule-slo.yaml`](../../../observability/k8s/prometheusrule-slo.yaml) (نسخة K8s) **مطابق** للـ compose rules (أي drift = فشل).

### 5.5 Grafana — **Student App · SLOs & error budget**

| Panel | Query | اقراه إزاي |
|---|---|---|
| Availability (30d) | `1 - …ratio_rate30d` | مقارنةً بـ 99.5% (أقل لو Prometheus عنده تاريخ أقل من 30 يوم) |
| Availability error budget left | `1 - ratio_rate30d / (1 - 0.995)` | 100% = ماصرفتش حاجة؛ **أقل من 0 = الـ SLO اتكسر → freeze** |
| Latency SLI (30d) / budget left | `latency_good_ratio_rate30d` / `1 - (1 - good)/0.05` | نفس الفكرة للـ 5% |
| p99 latency (1h) | `histogram_quantile(0.99, …[1h])` | الـ tail SLO < 1s |
| Firing SLO alerts | `sum by (alertname, severity, slo, burn) (ALERTS{alertstate="firing", slo=~".+"})` | |
| Availability / Latency burn rate | الـ 6 windows ÷ budget | الخطوط 14.4 / 6 / 1 |
| SLI vs SLO | 5m / 1h / 1d مقابل `student_app:slo_objective:ratio` | |
| Error budget left over time (30d) | | الاتجاه: بنصرف أسرع ولا أبطأ من الشهر اللي فات؟ |
| Drill SLI burn rate | `job:student_app_sli_drill_errors:ratio_rate{5m,1h,6h} / 0.005` | game days بس — مش جزء من الـ SLO |

### 5.6 CloudWatch (Terraform `observability` module)

```hcl
locals {
  budget_pct   = 100 - var.slo_availability_target   # 0.5
  error_budget = local.budget_pct / 100              # 0.005
  burn_windows = {
    fast-1h  = { period = 3600,  factor = 14.4, tier = "fast" }
    fast-5m  = { period = 300,   factor = 14.4, tier = "fast" }
    slow-6h  = { period = 21600, factor = 6,    tier = "slow" }
    slow-30m = { period = 1800,  factor = 6,    tier = "slow" }
  }
}
```

- `aws_cloudwatch_metric_alarm.burn` (for_each على الـ 4) → `student-app-lab-slo-burn-fast-1h`، `-fast-5m`، `-slow-6h`، `-slow-30m`: expression `(FILL(t5xx, 0) + FILL(e5xx, 0)) / req`، threshold = `factor × 0.005`، `treat_missing_data = "notBreaching"`، **من غير actions**.
- `aws_cloudwatch_composite_alarm.slo_fast_burn` = `student-app-lab-slo-fast-burn`: `ALARM("…fast-1h") AND ALARM("…fast-5m")` → SNS (`alarm_actions` و `ok_actions`). ونفسه `slo_slow_burn`.
- **مفيش tier 1× (ticket) في CloudWatch** — الـ module بيعمل الـ page tiers بس؛ الـ 3d trend تشوفه في الـ dashboard أو Prometheus.
- `slo_availability_target` (99.5، validation بين 90 و 100) → غيّره وكل الـ thresholds تتحسب.
- `alarm_names`/`alarm_arns` outputs بيتستخدموا في: instance refresh alarms (stack 40)، ECS deployment alarms (stack 50)، FIS stop conditions ([75](75-chaos-engineering-fis.md)).

```bash
cd infra/terraform/stacks/40-ec2-alb-asg
terraform output -json | jq '.sns_topic_arn.value'
aws cloudwatch describe-alarms --alarm-names student-app-lab-slo-burn-fast-1h --query 'MetricAlarms[0].[Threshold,EvaluationPeriods,Metrics[?Id==`ratio`].Expression]'
aws cloudwatch describe-alarms --alarm-types CompositeAlarm --alarm-names student-app-lab-slo-fast-burn --query 'CompositeAlarms[0].AlarmRule'
```

### 5.7 الـ Drill SLI — التصميم

- **المشكلة:** عايز تختبر إن الـ burn-rate alerts بتشتغل وإن الـ on-call بيرد — بس لو حرقت الـ budget الحقيقي: (1) الـ pager الحقيقي هيرن، (2) الـ dashboard هيقول الـ SLO اتكسر، (3) الـ SLO policy ممكن تعمل **release freeze** بسبب تمرين.
- **الحل:** الـ availability SLI بيستبعد `sre-lab.*`؛ و SLI تاني (`job:student_app_sli_drill_errors:*`) على `route="sre-lab.error"` بنفس الـ windows؛ و alerts `SLODrill*` بنفس الأرقام بالظبط بس عليها `drill="true"` → Alertmanager يوديها receiver `drill` ويقف. نفس الـ math، نفس الـ timing، صفر أثر على الـ budget.
- **لما عايز تحرق الـ SLO الحقيقي** (incident drill كامل): `SRE_FAULT_ERROR_RATE` على صفحات حقيقية (`MODE=app`).

### 5.8 `error-budget-burn.js`

| Env | Default | المعنى |
|---|---|---|
| `MODE` | `lab` | `lab` = `/sre-lab/error?rate=<B×0.005>&code=<CODE>` (drill SLI)؛ `app` = browse صفحات حقيقية والـ server هو اللي بيفشل (`SRE_FAULT_ERROR_RATE`) |
| `BURN_RATE` | `20` | B المطلوب → `ERROR_RATIO = min(1, B × 0.005)` |
| `RATE` | `10` | req/s (constant-arrival-rate) |
| `DURATION` | `15m` | مدة الـ burn |
| `WARMUP` | `0s` | traffic نضيف قبلها (`/sre-lab/error?rate=0` في lab) عشان تشوف الـ detection time "زي الحقيقة" |
| `CODE` | `500` | الـ status المحقون |

الـ thresholds كلها display-only (`rate>=0`) — الـ errors هي الهدف هنا. اختار B **أعلى شوية** من الـ threshold (مش 14.4 بالظبط — هيعمل flapping): 20 → fast + slow page؛ 8 → slow بس؛ 2 → ticket بس (بعد ~36 ساعة!).

### 5.9 SLO policy (اللي بيحصل لما الـ budget يخلص)

مثال policy تتكتب وتتمضي من product + engineering + SRE (مش قرار SRE لوحده):

| حالة الـ budget (30d rolling) | الإجراء |
|---|---|
| > 50% متبقي | شغل عادي، releases يومية، تجارب canary/A-B مسموحة |
| 25%–50% | كل release بـ canary إجباري، مفيش deploys جمعة/آخر اليوم |
| < 25% | feature releases بموافقة، الأولوية لـ reliability items من الـ postmortems |
| ≤ 0 (اتكسر) | **freeze** للـ features: بس bug/security/reliability fixes لحد ما الـ 30d window يرجع فوق الـ SLO |
| incident واحد صرف > 20% من الـ budget | postmortem إجباري بـ action items ليها owners ([76](76-incident-response.md)) |

الـ budget بيتصرف على: incidents، releases سيئة، **وتجارب مقصودة** (chaos — [75](75-chaos-engineering-fis.md)). لو الـ budget دايماً 100% فالـ SLO غالباً أعلى من اللازم في الأمان والفريق بيتحرك أبطأ من اللازم — الـ budget معمول عشان يتصرف.

## 6) الـ Deploy

### 6.1 Drill آمن (MODE=lab)

```bash
k6 run -e BASE_URL=http://localhost:8080 -e BURN_RATE=20 -e RATE=10 -e DURATION=60m loadtest/k6/error-budget-burn.js
```

راقب: Prometheus → **Alerts** (`SLODrillFastBurn` inactive → pending → firing بعد ~43+2 دقيقة)، Grafana → SLO → **Drill SLI burn rate**، و:

```bash
docker compose -f observability/compose/docker-compose.yml logs -f alert-sink | grep -E '"/drill"|alertname'
```

وفي نفس الوقت `SLOAvailabilityFastBurn` **inactive** — ده الإثبات إن الـ drill معزول. عايز أسرع؟ `BURN_RATE=200` (outage كامل على الـ drill route) → ~4 دقايق + 2.

### 6.2 Incident حقيقي (MODE=app)

```bash
SRE_FAULT_ERROR_RATE=0.1 docker compose up -d --no-build --wait app
k6 run -e BASE_URL=http://localhost:8080 -e MODE=app -e BURN_RATE=20 -e LOADTEST_USERS=5 -e DURATION=60m loadtest/k6/error-budget-burn.js
```

هتشوف `SLOAvailabilityFastBurn` يوصل alert-sink على **`/page`**، والـ "budget left" بينزل فعلاً. بعدها `docker compose up -d --no-build --wait app` (من غير الـ fault) → الـ 5m window ينزل → الـ alert يعمل resolve في دقايق رغم إن الـ 1h لسه عالي — ده الـ short window شغال.

### 6.3 Latency burn

```bash
SRE_FAULT_LATENCY_MS=400 docker compose up -d --no-build --wait app
k6 run -e BASE_URL=http://localhost:8080 -e LOADTEST_USERS=5 -e VUS=5 -e DURATION=20m -e P95_MS=2000 loadtest/k6/load.js
```

كل صفحة web > 300ms → الـ latency good ratio ≈ 0 → `SLOLatencyFastBurn` بعد ~ `60 × 0.72 / 1` ≈ 43 دقيقة + 2 (الـ threshold هنا 72% مش 7.2%!). والـ k6 نفسه هيعدّي لأنك رخّيت `P95_MS` — الـ test مش هو الـ SLO اللي على 30 يوم.

### 6.4 على GitHub Actions

- `observability-lint.yml` بيشغّل الـ promtool tests على كل تعديل في `observability/**` — الـ SLO rules مختبرة زي الكود.
- `perf-gate.yml` بـ `script: error-budget-burn.js` ضد environment deployed (Prometheus/CloudWatch هناك هو اللي هيطلّع الـ alerts).

## 7) التحقق (Verify)

```bash
q() { curl -s localhost:9090/api/v1/query --data-urlencode "query=$1" | jq -r '.data.result[] | "\(.metric) \(.value[1])"'; }
q 'job:student_app_sli_availability_errors:ratio_rate5m / 0.005'        # burn rate دلوقتي
q 'job:student_app_sli_drill_errors:ratio_rate5m'
q 'ALERTS{slo=~".+"}'
curl -s localhost:9093/api/v2/alerts | jq -r '.[] | "\(.labels.alertname) \(.labels.severity) drill=\(.labels.drill // "-") \(.status.state)"'
curl -s localhost:9090/api/v1/rules | jq -r '.data.groups[].rules[] | select(.type=="alerting") | "\(.name)\t\(.state)"'
```

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر | المتوقع |
|---|---|---|
| B عند الـ threshold بالظبط | `BURN_RATE=14.4` | الـ alert بيـ flap (pending ↔ inactive) من الـ randomness |
| شيل الـ short window | في نسخة محلية من الـ rules امسح `and …ratio_rate5m` | بعد ما توقف الـ errors الـ alert يفضل firing لحد ~ساعة |
| `or 0 *` اتشال | امسحها من الـ recording rule | في الأوقات من غير 5xx الـ panel فاضي بدل 0 — والـ tests بتاعة الـ healthy case بتفضل عدّية بس الـ dashboard مضلل |
| Drill من غير label | شيل `drill: "true"` من `SLODrillFastBurn` | `promtool test` يفشل (الـ exp_labels)، وفي الحقيقة الـ drill يرن على الـ pager |
| Inhibition | شغّل B=200 MODE=app | `FastBurn` و `SlowBurn` الاتنين firing في Prometheus، بس Alertmanager بيبعت الـ fast بس |
| CloudWatch بيشوف الـ lab | `error-budget-burn.js MODE=lab` ضد الـ ALB | `student-app-lab-slo-fast-burn` → ALARM وإيميل (الـ ALB SLI مش بيستبعد paths) |

## 9) الرجوع (Rollback)

```bash
docker compose up -d --no-build --wait app                       # شيل SRE_FAULT_*
curl -X POST localhost:9090/-/reload                             # بعد ما ترجّع الـ rules
# silence أثناء صيانة مخططة (بدل ما تعدّل الـ rules):
docker run --rm --network student-app-obs_default --entrypoint amtool prom/alertmanager:v0.35.0 \
  --alertmanager.url=http://alertmanager:9093 silence add 'alertname=~SLO.*' --duration=2h --comment="planned maintenance"
aws cloudwatch enable-alarm-actions --alarm-names student-app-lab-slo-fast-burn student-app-lab-slo-slow-burn
```

## 10) المسح (Teardown) ⚠️

```bash
aws cloudwatch delete-alarms --alarm-names manual-slo-fast-burn            # الـ composite الأول
aws cloudwatch delete-alarms --alarm-names manual-slo-burn-fast-1h manual-slo-burn-fast-5m
aws sns delete-topic --topic-arn arn:aws:sns:us-east-1:<ACCOUNT_ID>:student-app-lab-alerts-manual
docker compose -f observability/compose/docker-compose.yml down -v
```

(composite alarm لازم يتمسح قبل الـ children اللي بيشاور عليهم.)

## 11) التكلفة (Cost)

| Resource | السعر التقريبي (تقريبي — راجع صفحة الأسعار) |
|---|---|
| 4 child burn alarms (3 metrics لكل واحد) | ~12 × $0.10 = ~$1.2/شهر |
| 2 composite alarms | ~$1/شهر |
| SNS email | مجاني في حدود الـ free tier |
| Prometheus/Alertmanager محلي | مجاني |

## 12) أسئلة Interview

<details><summary>احسب الـ error budget لـ 99.9% على 30 يوم، وإيه الـ burn rate اللي يصرف 2% في ساعة؟</summary>

43,200 دقيقة × 0.001 = 43.2 دقيقة. الـ burn rate اللي يصرف 2% في ساعة = 0.02 × 720 = 14.4 (نفس الرقم لأي SLO — الـ burn rate نسبي)؛ الـ error ratio threshold = 14.4 × 0.001 = 1.44%.

</details>

<details><summary>ليه multi-window ومش alert بسيط "error rate > 1% لمدة 5 دقايق"؟</summary>

الـ threshold البسيط مش مربوط بالـ budget: 1% لـ 5 دقايق ممكن ميأثرش على الشهر خالص (false positive)، و 0.8% لساعات بيصرف الـ budget من غير ما يضرب (false negative). الـ burn rate بيربط الـ alert بأثره على الـ SLO، والنافذة الطويلة للـ significance، والقصيرة للـ reset السريع. والـ tiers بتغطي الحرايق الكبيرة بسرعة والتسريب البطيء كـ ticket.

</details>

<details><summary>ليه `/sre-lab/error` مستبعد من الـ SLI، وإزاي برضه بتختبر الـ alerts؟</summary>

لأنه traffic مصطنع بيفشل بالطلب — لو اتحسب هيرن الـ pager الحقيقي ويشوّه الـ budget ويمكن يعمل release freeze بسبب تمرين. بنختبر بـ drill SLI منفصل بنفس الـ math والـ windows، و alerts بـ `drill="true"` بتروح receiver منفصل. والـ promtool test رقم 3 بيثبت العزل ده على كل push. للـ incident drill الكامل نستخدم `SRE_FAULT_ERROR_RATE` على صفحات حقيقية.

</details>

<details><summary>الـ SLI على Prometheus والـ SLI على CloudWatch مختلفين — ليه وإيه اللي تثق فيه؟</summary>

CloudWatch من الـ ALB: بيشوف 502/503/504 اللي التطبيق ما شافهاش (no healthy targets، timeouts) — أقرب لتجربة المستخدم — بس مالوش path dimension فبيحسب traffic الـ lab. Prometheus من التطبيق: per-route ودقيق في الاستبعاد بس أعمى عن اللي قبل التطبيق. الحل الناضج: SLI من الـ edge (Athena على ALB access logs بفلتر الـ paths، أو CloudFront/ALB logs → metrics) كمرجع، و app metrics للتشخيص. والأهم إن الاتنين بنفس الأرقام (99.5%، 300ms) عشان مايبقاش فيه "أنهي dashboard صح".

</details>

<details><summary>إمتى تحط `for:` على burn-rate alert وإمتى لأ؟</summary>

الـ windows نفسها smoothing، فالـ `for` بيزود الـ detection time. هنا 2m للـ fast (يمنع blip واحد في الـ evaluation)، 15m للـ slow، 1h للـ ticket — trade-off بين الـ precision والسرعة. الـ promtool test بيثبت إن الـ slow مش firing عند 10m بسبب الـ `for`.

</details>

<details><summary>Latency SLO: ليه "95% أسرع من 300ms" وليه الـ p99 alert ticket مش page؟</summary>

النسبة aggregatable وبتتحول لـ budget مباشرة (5%)، فينفع عليها burn rate. الـ p99 tail مهم بس مش بيتحسب budget بنفس الطريقة، والـ `histogram_quantile` تقديري، و p99 على traffic قليل = request واحد بطيء — فـ ticket يتبص عليه، مش page.

</details>

<details><summary>الـ error budget خلص — تعمل إيه عملياً؟</summary>

تطبّق الـ policy المتفق عليها مسبقاً: freeze للـ features، الفريق يشتغل على action items الـ postmortems وأكبر مصادر الـ burn (من الـ dashboards: أنهي route/release صرف أكتر)، releases أصغر بـ canary. ولو الـ budget بيخلص كل شهر، يا إما الـ SLO غلط (أعلى من اللي المستخدمين محتاجينه) يا إما فيه reliability debt حقيقي — والقرار ده بيتاخد مع الـ product.

</details>

## 13) Checklist

- [ ] حسبت الـ budget بالدقايق وبالطلبات، والـ thresholds الـ 3 بالـ error ratio
- [ ] أقدر أشرح ليه نافذتين وأحسب الـ detection time لأي B
- [ ] شغّلت `promtool test rules` وفهمت كل test من الـ 5
- [ ] شغّلت drill بـ `MODE=lab` وشفت `SLODrillFastBurn` في `/drill` والـ real SLO ساكت
- [ ] شغّلت `MODE=app` مع `SRE_FAULT_ERROR_RATE` وشفت الـ page + الـ resolve السريع
- [ ] عملت composite alarm بإيدك وقارنته بالـ Terraform module
- [ ] كتبت SLO policy (حتى لو للمعمل)
