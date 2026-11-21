# 12 — SRE lab endpoints + Prometheus/Grafana محلي + k6

> **الهدف في سطر:** تفهم كل endpoint في `/sre-lab/*` بيجاوب على أنهي سؤال SRE، وإزاي تعمل "bad release" بالـ env بس، والفرق بين `/up` و `/ready`، وشكل `/metrics` — وبعدين تشغّل ستاك الـ observability (Prometheus، Alertmanager، Grafana، Loki، Alloy) جنب التطبيق، وتولّد traffic بـ k6 محلياً وعلى GitHub Actions.
> **المستوى:** Intermediate · **الوقت:** ~3 ساعات · **التكلفة التقريبية:** مجاني
> **بيعتمد على:** [10 — تحويل التطبيق لـ container](10-containerize-app.md) · [03 — تجهيز الجهاز](03-workstation-setup.md) · **الملفات في الـ repo:** [`SreLabController.php`](../../../app/Http/Controllers/SreLabController.php) · [`InjectFaults.php`](../../../app/Http/Middleware/InjectFaults.php) · [`EnsureSreLabEnabled.php`](../../../app/Http/Middleware/EnsureSreLabEnabled.php) · [`RecordRequestMetrics.php`](../../../app/Http/Middleware/RecordRequestMetrics.php) · [`ReadinessController.php`](../../../app/Http/Controllers/Health/ReadinessController.php) · [`config/sre_lab.php`](../../../config/sre_lab.php) · [`routes/sre-lab.php`](../../../routes/sre-lab.php) · [`observability/compose/`](../../../observability/compose) · [`loadtest/k6/`](../../../loadtest/k6)

## 1) الفكرة (Concepts)

عشان تتعلم SRE بجد محتاج تطبيق **تقدر تكسره بإرادتك وتقيس الكسر**. التطبيق ده فيه 3 حاجات معمولة مخصوص للمعمل:

1. **`/sre-lab/*`**: endpoints بتولّد load معروف (CPU، memory، latency، DB) أو أعطال بنسبة محددة — كل input ليه **cap** عشان request غلط ميوقعش السيرفر.
2. **Fault injection بالـ env**: نفس الـ image بالظبط، بس env مختلفة = "release سيء" (errors، بطء، unhealthy، مش بيقوم). ده اللي بنستخدمه في الـ canary والـ burn-rate alerts والـ rollback.
3. **Telemetry**: `/ready` (readiness)، `/metrics` (Prometheus)، واللوجز JSON على stderr ([70](70-logging.md)).

| المصطلح | المعنى |
|---|---|
| Liveness | "الـ process عايش؟" — لو فشل: **restart** للـ container |
| Readiness | "أقدر أستقبل traffic دلوقتي؟" — لو فشل: **وقّف الـ routing** ليه من غير restart |
| Fault injection | تعطيل متعمّد ومتحكم فيه عشان تختبر الـ detection والـ recovery |
| Scrape | Prometheus هو اللي بيروح ياخد الـ metrics (pull) كل `scrape_interval` |
| Exposition format | الشكل النصي اللي `/metrics` بيرجّعه (`# HELP`، `# TYPE`، سطر لكل series) |
| Drill SLI | SLI منفصل لـ `/sre-lab/error` بس، عشان تمارين الـ game day متحرقش الـ error budget الحقيقي ([73](73-slo-error-budget-burn-rate.md)) |
| Blast radius | قد إيه من المستخدمين ممكن يتأثر بالتجربة |

### 1.1 الـ SRE lab endpoints — كل واحد بيجاوب على إيه

كلهم متسجلين في [`bootstrap/app.php`](../../../bootstrap/app.php) تحت prefix `/sre-lab` و route names `sre-lab.*`، **بره** الـ `web` middleware group (من غير session ولا CSRF)، ووراهم `EnsureSreLabEnabled`:

- `SRE_LAB_ENABLED` مش `true` → **404** (كأن الـ route مش موجود). الـ routes متسجلة دايماً عشان `route:cache` يشتغل، والقفل وقت التشغيل.
- `SRE_LAB_TOKEN` متحدد → لازم header `X-Lab-Token` بنفس القيمة (مقارنة بـ `hash_equals`) وإلا **403**.
- الـ exceptions هنا بترجع JSON (`shouldRenderJsonWhen` على `sre-lab/*` و `ready`).

| Endpoint | Params (default → cap) | بيعمل إيه بالظبط | السؤال اللي بيجاوبه |
|---|---|---|---|
| `GET /sre-lab/ping` | — | JSON `{"status":"ok","time"}` من غير DB ولا session | الـ baseline: أقل latency ممكنة؟ سقف PHP-FPM لوحده (`breakpoint.js TARGET=ping`)؟ |
| `GET /sre-lab/version` | — | `version`، `color`، `hostname`، `php`، `laravel` | مين بيرد؟ توزيع الـ traffic بين blue/green/canary، وإمتى instance جديد بدأ ياخد traffic (`autoscale-cpu.js`) |
| `GET /sre-lab/latency` | `ms` (200)، `jitter` (0) — الاتنين clamp لـ `[0, SRE_LAB_MAX_LATENCY_MS=10000]`، والمجموع كمان ≤ الـ max | `usleep(ms + random(0..jitter))` | الـ latency alerts بتشتغل؟ الـ timeouts (الـ ALB `idle_timeout` = 60s) والـ retries بيعملوا إيه؟ |
| `GET /sre-lab/error` | `rate` (1.0، clamp 0..1)، `code` (500، clamp **500..599**) | بيرجّع `code` باحتمال `rate` وإلا 200 `{"injected":false}` | الـ burn-rate alerts بتطلع في الوقت المتوقع؟ (`error-budget-burn.js`). لاحظ: `code=404` هيتحول لـ **500** (الـ clamp) |
| `GET /sre-lab/cpu` | `ms` (200، clamp `1..SRE_LAB_MAX_CPU_MS=5000`) | loop من `sha256` لحد ما الوقت يخلص (CPU حقيقي) | الـ autoscaling على CPU (ASG / ECS / HPA) بيلحق؟ ([48](48-autoscaling-under-load.md)، [57](57-ecs-autoscaling-under-load.md)) |
| `GET /sre-lab/memory` | `mb` (32، clamp `1..SRE_LAB_MAX_MEMORY_MB=128`)، `hold_ms` (100، clamp `0..5000` ثابت في الـ config) | `str_repeat` بالحجم ده ويمسكه | memory limits، `PHP_MEMORY_LIMIT`، OOM kill للـ task/pod |
| `GET /sre-lab/db` | `limit` (50، clamp `1..500`) | آخر N students (`whereNull('deleted_at')->orderByDesc('id')`) + `query_ms` | قراية عادية بـ index — الـ DB كويسة؟ |
| `GET /sre-lab/db/heavy` | — | `GROUP BY user_id` على `subscriptions` + aggregate على `students` (full scan) | الـ bottleneck بتاع الداتابيز تحت load (`TARGET=db-heavy`، ألارم `rds-cpu`) |
| `POST /sre-lab/unready` | — | بيكتب flag في `storage/framework/sre-lab-unready` | drain يدوي لـ instance واحد: الـ LB يبطّل يبعتله من غير restart |
| `POST /sre-lab/ready` | — | يمسح الـ flag | يرجّعه للخدمة |

> 💡 الـ `POST` هنا بيشتغل بـ `curl` عادي من غير CSRF token لأن الـ routes بره الـ `web` group. والـ flag **per container** (جوه الـ filesystem بتاعه)، فـ `unready` على ALB بيقفل الـ instance اللي الـ request وقع عليه بس — عشان كده نفّذه على بورت الـ slot مباشرة (`127.0.0.1:8081`).

### 1.2 Bad-release fault injection (نفس الـ image، env مختلفة)

| Env | فين متنفذ | الأثر | مين يمسكه |
|---|---|---|---|
| `SRE_FAULT_LATENCY_MS=800` | `InjectFaults` (web group بس) | `usleep` قبل كل صفحة web، capped بـ `SRE_LAB_MAX_LATENCY_MS` | latency SLO alerts / `alb-latency-p95` |
| `SRE_FAULT_ERROR_RATE=0.5` | `InjectFaults` | `abort(500)` باحتمال 0.5 مع header `X-SRE-Fault: error-rate` | الـ canary gate، الـ burn-rate alerts. **الـ health checks بتفضل خضرا** |
| `SRE_FAULT_UNHEALTHY=true` | `AppServiceProvider` (listener على `DiagnosingHealth`) + `ReadinessController` | `/up` = 500، `/ready` = 503 `"fault injection: SRE_FAULT_UNHEALTHY"` | Docker healthcheck، ALB/K8s health checks → rollback |
| `SRE_FAULT_BOOT_FAIL=true` | [`docker/entrypoint.d/2-sre-boot-fault.sh`](../../../docker/entrypoint.d/2-sre-boot-fault.sh) | الـ entrypoint يعمل `exit 1` قبل ما التطبيق يقوم | ECS circuit breaker، CrashLoopBackOff، ASG refresh rollback |

- كل الـ faults (ما عدا `BOOT_FAIL`) مش بتشتغل غير لو `SRE_LAB_ENABLED=true` — الـ master kill-switch.
- `InjectFaults` بيطبّق الـ latency الأول وبعدين يرمي الـ coin (`Chance::roll` = `random_int(1, 10000) <= rate × 10000`). فمع الاتنين مع بعض، حتى الـ 500 بتاخد وقت.
- ليه على الـ `web` group بس؟ عشان ده بالظبط شكل الـ release السيء في الحقيقة: الـ health checks (`/up`، `/ready`) سليمة، والمستخدمين بيشوفوا errors. **الـ health checks لوحدها مش كفاية** — محتاج metric-based analysis ([24](24-canary-single-host.md)، [73](73-slo-error-budget-burn-rate.md)).
- الـ 500 المحقونة **مش بتظهر في لوج Laravel** (الـ `HttpException` مش بيتعمله report) — بتظهر في الـ metrics وفي nginx access log بس ([70](70-logging.md)).

### 1.3 `/up` مقابل `/ready`

| | `GET /up` | `GET /ready` |
|---|---|---|
| مين بيعرّفه | Laravel نفسه (`health: '/up'` في `bootstrap/app.php`) | `App\Http\Controllers\Health\ReadinessController` (route name `health.ready`) |
| بيلمس الـ DB؟ | لأ | أيوه: `DB::select('select 1')` |
| بيرجّع | صفحة HTML، 200 أو 500 | JSON `{"status","checks","version","color"}` (+ `reason` لما يفشل)، 200 أو 503 |
| بيفشل لما | `SRE_FAULT_UNHEALTHY` (exception في `DiagnosingHealth`) | unready flag، `SRE_FAULT_UNHEALTHY`، الـ DB مش بترد |
| مين يستخدمه | Docker `healthcheck`، K8s liveness/startup، ECS container `healthCheck` | ALB target group، K8s readiness، `wait_ready` في سكريبتات الـ LB |

**ليه مهم الفصل؟** لو الـ liveness بيعمل DB ping، وقعة RDS لمدة دقيقة هتخلّي ECS/K8s يعمل restart لـ **كل** الـ tasks في نفس الوقت — يعني حوّلت مشكلة DB لـ outage كامل وcold start لكل حاجة. الـ readiness بيشيل الـ instance من الـ LB بس، ولما الـ DB ترجع يرجع لوحده. الاتنين بره الـ `web` group: الـ health check كل 10 ثواني **مش بيعمل session row** في جدول `sessions`.

### 1.4 `/metrics` — الشكل

`MetricsController` بيرجّع 404 لو `METRICS_ENABLED` مش `true`، ولو `METRICS_TOKEN` متحدد لازم `Authorization: Bearer <token>` وإلا 403. الـ `Content-Type` = `text/plain; version=0.0.4`. شكل تقريبي للناتج:

```text
# HELP student_app_http_requests_total HTTP requests handled by the app.
# TYPE student_app_http_requests_total counter
student_app_http_requests_total{method="GET",route="login",status="200"} 42
student_app_http_requests_total{method="GET",route="sre-lab.error",status="503"} 7
# HELP student_app_http_request_duration_seconds HTTP request latency in seconds.
# TYPE student_app_http_request_duration_seconds histogram
student_app_http_request_duration_seconds_bucket{method="GET",route="login",le="0.25"} 40
student_app_http_request_duration_seconds_bucket{method="GET",route="login",le="0.3"} 41
student_app_http_request_duration_seconds_bucket{method="GET",route="login",le="+Inf"} 42
student_app_http_request_duration_seconds_sum{method="GET",route="login"} 3.91
student_app_http_request_duration_seconds_count{method="GET",route="login"} 42
# HELP student_app_app_info The release currently running in this instance.
# TYPE student_app_app_info gauge
student_app_app_info{version="ci-v1",color="none"} 1
```

- الـ buckets: `0.005 … 0.25, 0.3, 0.5, 1, 2.5, 5, 10` — فيه bucket عند **0.3** بالظبط عشان الـ latency SLI (300ms) وعند **1** عشان الـ p99 SLO.
- الـ `route` label = اسم الـ route (`students.index`، `health.ready`، `up`، `sre-lab.cpu`...) أو الـ URI pattern لو مفيش اسم، و `unmatched` لأي URL مش موجود — **عمره ما بيبقى الـ URL الخام** (cardinality — [71](71-metrics-dashboards.md)).
- `/metrics` نفسه **مش بيتعد**.
- العدادات في **APCu** (مشتركة بين كل workers الـ PHP-FPM في الـ container) وبتبدأ من صفر مع كل container جديد — `rate()` في Prometheus بيتعامل مع الـ reset.

## 2) المعمارية (Architecture)

```text
 WSL2 / EC2 host (Docker)
 ┌─ compose project "student-app" ─── network student-app_default ───────────────────┐
 │  app:8080 (أو app_blue:8080 / app_green:8080 من deploy/ec2/lb)    mysql:3306         │
 │     ▲ /metrics (container-to-container)                                              │
 └─────┼────────────────────────────────────────────────────────────────────────────────┘
       │ (prometheus بينضم للـ network دي كـ external)
 ┌─ compose project "student-app-obs" (observability/compose/docker-compose.yml) ──────┐
 │  prometheus:9090 ── rules (recording + burn-rate) ──► alertmanager:9093 ──► alert-sink│
 │     ▲  ▲ remote-write / OTLP من k6                       (page / ticket / drill)      │
 │     │  └─ node-exporter:9100 · cadvisor:8080 (→127.0.0.1:8089)                        │
 │  grafana:3000 ── datasources: Prometheus · Loki · Alertmanager (3 dashboards)         │
 │  loki:3100 ◄── alloy:12345 ◄── /var/run/docker.sock (stdout/stderr لكل container)    │
 └───────────────────────────────────────────────────────────────────────────────────────┘
 كل الـ UIs على 127.0.0.1 بس.   k6 ──► http://localhost:8080 (أو http://app:8080 من جوه الـ network)
```

## 3) المتطلبات (Prerequisites)

- [ ] [10](10-containerize-app.md) خلصان: `docker compose up` بيشغّل `app` + `mysql`.
- [ ] **محلياً:** WSL2 + Docker Engine أو Docker Desktop ([03](03-workstation-setup.md)). الستاكين مع بعض ~10 containers — لو الجهاز ضعيف اقفل `node-exporter` و `cadvisor` (الاتنين معمولين للـ Linux host أصلاً).
- [ ] **من غير Docker محلي:** GitHub Actions (`lab-integration.yml`، `observability-lint.yml`، `perf-gate.yml`) — §6.6.
- الأدوات: `curl`، `jq`، `k6` (أو image `grafana/k6:2.4.0`).

## 4) الطريقة الأولى: AWS Console (يدوي)

مفيش موارد AWS في السيناريو ده. لو بتشغّل الستاك على EC2 من [20](20-ec2-compose-console.md)، **متفتحش** بورتات Grafana/Prometheus في الـ Security Group — اعمل port forwarding بـ Session Manager:

```bash
aws ssm start-session --target <INSTANCE_ID> \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["3000"],"localPortNumber":["3000"]}'
```

> 💡 ليه؟ Grafana بـ `admin/admin`، و Alloy و cAdvisor بيقروا الـ Docker socket — ده root فعلياً على الـ host. أي بورت منهم public = الـ host كله مكشوف.

## 5) الطريقة التانية: as Code — الستاك سطر بسطر

### 5.1 [`observability/compose/docker-compose.yml`](../../../observability/compose/docker-compose.yml)

| Service | Image | ملاحظات مهمة |
|---|---|---|
| `prometheus` | `prom/prometheus:v3.16.0` | `--storage.tsdb.retention.time=31d` (الـ SLO window 30 يوم) و `retention.size=5GB`؛ `--web.enable-lifecycle` (reload)؛ `--web.enable-remote-write-receiver` و `--web.enable-otlp-receiver` (نتايج k6)؛ على الـ network `default` **و** `app` |
| `alertmanager` | `prom/alertmanager:v0.35.0` | routing بالـ severity + receiver `drill` منفصل ([73](73-slo-error-budget-burn-rate.md)) |
| `alert-sink` | `mendhak/http-https-echo:43` | "pager مزيف": بيطبع كل webhook بيوصله |
| `grafana` | `grafana/grafana:13.3.1` | provisioning من git، الـ home dashboard = SLO، password من `LAB_GRAFANA_PASSWORD` |
| `loki` | `grafana/loki:3.7.10` | retention 7 أيام |
| `alloy` | `grafana/alloy:v1.22.0` | `user: "0:0"` + Docker socket read-only — بديل Promtail (deprecated) |
| `node-exporter` / `cadvisor` | `prom/node-exporter:v1.13.1` / `ghcr.io/google/cadvisor:0.61.1` | الـ host والـ containers (cAdvisor اتنقل من gcr.io) |

- الـ network `app` معرّفة `external: true` باسم `student-app_default` — **الستاك ده مش بيعملها**، الـ app stack هو اللي بيعملها. عشان كده الترتيب إجباري.
- كل البورتات `127.0.0.1:${LAB_*_PORT:-...}` — تقدر تغيّرها بـ `LAB_PROMETHEUS_PORT`، `LAB_GRAFANA_PORT`... من غير ما تلمس الملف.
- الـ images كلها pinned — الـ bump بيبقى مقصود (release notes!).

### 5.2 [`observability/prometheus/prometheus.yml`](../../../observability/prometheus/prometheus.yml)

- `global`: `scrape_interval: 15s`، `evaluation_interval: 30s`، `external_labels: {project: student-app, env: lab}`.
- `job_name: student-app` كل **10s** على 3 targets ثابتة: `app:8080` (`slot: single`)، `app_blue:8080` (`slot: blue`)، `app_green:8080` (`slot: green`). اللي مش موجود يظهر **DOWN** — ده طبيعي، والـ alert `StudentAppNoTargetsUp` بيضرب بس لو **كلهم** down.
- `version` و `color` **مش** target labels — بييجوا من `student_app_app_info` وبيتعملهم join في الـ queries ([71](71-metrics-dashboards.md)). يعني deploy جديد على نفس الـ slot مش محتاج تعديل في Prometheus.
- لو فعّلت `METRICS_TOKEN`: فيه block `authorization` (Bearer من ملف) متعلّق عليه comment — فكّه وركّب الملف.
- باقي الـ jobs: `node-exporter`، `cadvisor` (مع `metric_relabel_configs` بتعمل `keep` لقايمة metrics محددة — cAdvisor رغّاي جداً)، و Prometheus/Alertmanager/Grafana/Loki/Alloy نفسهم.

### 5.3 Grafana provisioning

- [`datasources.yml`](../../../observability/compose/grafana/provisioning/datasources/datasources.yml): `Prometheus` (uid `prometheus`، `timeInterval: 15s` عشان `$__rate_interval` يتحسب صح)، `Loki`، `Alertmanager` — UIDs ثابتة.
- [`dashboards.yml`](../../../observability/compose/grafana/provisioning/dashboards/dashboards.yml): كل JSON في [`observability/grafana/dashboards`](../../../observability/grafana/dashboards) يتحمّل في فولدر **Student App**. التعديل من الـ UI مسموح للتجربة بس بيتمسح مع الـ reload — **عدّل الـ JSON في git**.
- الـ 3 dashboards: **Student App · RED** (`student-app-red`)، **Student App · SLOs & error budget** (`student-app-slo`)، **Student App · Canary compare** (`student-app-canary`). شرح كل panel في [71](71-metrics-dashboards.md) و [73](73-slo-error-budget-burn-rate.md).

## 6) الـ Deploy

### 6.1 محلياً (WSL2 + Docker) — الترتيب مهم

```bash
cd ~/src/StudentHub                                        # جوه WSL، مش /mnt/c
export APP_KEY=base64:$(openssl rand -base64 32)

# 1) الـ app (بيعمل الـ network student-app_default)
docker compose up -d --build --wait
docker compose exec -T app php artisan migrate --force
docker compose exec -T app php artisan db:seed --class=DemoSeeder --force
docker compose exec -T app sh -c 'LOADTEST_USERS=5 LOADTEST_STUDENTS_PER_USER=50 php artisan db:seed --class=LoadTestSeeder --force'

# 2) ستاك الـ observability
docker compose -f observability/compose/docker-compose.yml up -d
docker compose -f observability/compose/docker-compose.yml ps
```

الـ [`docker-compose.yml`](../../../docker-compose.yml) بتاع التطبيق بيدّي افتراضياً `SRE_LAB_ENABLED=true` و `METRICS_ENABLED=true` و `SRE_LAB_TOKEN` فاضي — مناسب للـ laptop بس.

لو شغّال بستاك الـ blue/green ([23](23-bluegreen-single-host.md)) بدل الـ single container: نفس الـ compose project (`student-app`) ونفس الـ network، فـ Prometheus هيلاقي `app_blue` و `app_green` لوحده.

| UI | URL | ملاحظات |
|---|---|---|
| Grafana | http://localhost:3000 | `admin` / `admin` (أو `LAB_GRAFANA_PASSWORD`) |
| Prometheus | http://localhost:9090 | **Status → Targets**، **Alerts**، **Rules** |
| Alertmanager | http://localhost:9093 | silences، الـ routing tree |
| Alloy | http://localhost:12345 | الـ pipeline graph live |
| Loki | http://localhost:3100/ready | الـ queries من Grafana → **Explore** |
| cAdvisor | http://localhost:8089 | |

### 6.2 جرّب كل endpoint

```bash
B=http://localhost:8080
H=()                                  # لو SRE_LAB_TOKEN متحدد: H=(-H "X-Lab-Token: <TOKEN>")

curl -s "$B/sre-lab/ping" "${H[@]}" | jq
curl -s "$B/sre-lab/version" "${H[@]}" | jq
curl -s -w ' %{time_total}s\n' "$B/sre-lab/latency?ms=250&jitter=100" "${H[@]}"
curl -s -o /dev/null -w '%{http_code}\n' "$B/sre-lab/error?rate=1&code=503" "${H[@]}"     # 503
curl -s -o /dev/null -w '%{http_code}\n' "$B/sre-lab/error?rate=1&code=404" "${H[@]}"     # 500 (clamp)
curl -s "$B/sre-lab/cpu?ms=300" "${H[@]}" | jq
curl -s "$B/sre-lab/memory?mb=500&hold_ms=200" "${H[@]}" | jq                            # allocated_mb: 128 (cap)
curl -s "$B/sre-lab/db?limit=1000" "${H[@]}" | jq                                        # rows ≤ 500
curl -s "$B/sre-lab/db/heavy" "${H[@]}" | jq

curl -s "$B/up" -o /dev/null -w 'up=%{http_code}\n'
curl -s "$B/ready" | jq
curl -s "$B/metrics" | grep -E '^student_app_(app_info|http_requests_total)' | head
```

الـ drain اليدوي:

```bash
curl -s -X POST "$B/sre-lab/unready" "${H[@]}" | jq      # {"status":"unready","hostname":...}
curl -s -o /dev/null -w '%{http_code}\n' "$B/ready"      # 503
curl -s "$B/up" -o /dev/null -w '%{http_code}\n'         # 200 — عايش، بس مش جاهز
curl -s -X POST "$B/sre-lab/ready" "${H[@]}" | jq
```

### 6.3 Bad release بالـ env

الـ compose بيقرا `SRE_FAULT_*` من الـ shell وقت `up` (`${SRE_FAULT_ERROR_RATE:-0}`)، فـ:

```bash
SRE_FAULT_ERROR_RATE=0.3 docker compose up -d --no-build --wait app
for i in $(seq 1 20); do curl -s -o /dev/null -w '%{http_code} ' "$B/login"; done; echo
curl -s -D - -o /dev/null "$B/login" | grep -i x-sre-fault       # يظهر على الـ 500 بس
curl -s -o /dev/null -w 'ready=%{http_code}\n' "$B/ready"        # 200 — الـ LB مش هيشوف حاجة

SRE_FAULT_LATENCY_MS=400 docker compose up -d --no-build --wait app
curl -s -o /dev/null -w '%{time_total}s\n' "$B/login"           # ~0.4s+

SRE_FAULT_UNHEALTHY=true docker compose up -d --no-build app     # من غير --wait: الـ healthcheck هيفشل
sleep 15; docker compose ps app                                  # (unhealthy)

docker compose up -d --no-build --wait app                       # رجوع (الـ vars مش في الـ shell)
```

> ⚠️ كل `up` بيعمل recreate للـ container → عدادات APCu بتبدأ من صفر. ده طبيعي في Prometheus (counter reset)، بس لو بتقرا `/metrics` بإيدك هتلاقي الأرقام رجعت صغيرة.

### 6.4 Traffic بـ k6 محلياً

```bash
# native
k6 run -e BASE_URL=http://localhost:8080 -e LOADTEST_USERS=5 loadtest/k6/smoke.js
k6 run -e BASE_URL=http://localhost:8080 -e LOADTEST_USERS=5 -e VUS=5 -e DURATION=5m loadtest/k6/load.js

# من غير تثبيت: الـ image الرسمية على network التطبيق
mkdir -p loadtest/results
docker run --rm -i --network student-app_default -u "$(id -u):$(id -g)" \
  -v "$PWD/loadtest:/loadtest" grafana/k6:2.4.0 run \
  -e BASE_URL=http://app:8080 -e LOADTEST_USERS=5 -e VUS=5 -e DURATION=5m /loadtest/k6/load.js
```

وأنت شغّال: Grafana → **Student App · RED** — هتشوف Requests/s by route بأسماء الـ routes (`students.index`، `students.show`...) وهي نفس الـ `name` tags اللي k6 بيطبعها في الـ summary. تفاصيل كل script في [74](74-load-testing-k6.md).

ابعت نتايج k6 لنفس Prometheus (تشوف الـ client side جنب الـ server side):

```bash
K6_PROMETHEUS_RW_SERVER_URL=http://localhost:9090/api/v1/write \
  k6 run -o experimental-prometheus-rw -e TEST_ID=local-$(date +%s) \
  -e BASE_URL=http://localhost:8080 -e LOADTEST_USERS=5 loadtest/k6/load.js
```

(`experimental-prometheus-rw` deprecated في k6 v2.4 — البديل OTLP، في [74](74-load-testing-k6.md).)

### 6.5 drill سريع للـ alerts

```bash
k6 run -e BASE_URL=http://localhost:8080 -e BURN_RATE=200 -e DURATION=10m loadtest/k6/error-budget-burn.js
# في terminal تاني:
docker compose -f observability/compose/docker-compose.yml logs -f alert-sink
```

`BURN_RATE=200` = نسبة errors 100% على `/sre-lab/error` → الـ drill SLI يعدّي 14.4× على الـ 1h والـ 5m في دقايق → `SLODrillFastBurn` يروح pending ثم firing (بعد `for: 2m`) ويوصل لـ alert-sink على `/drill` — **مش** `/page`. والـ `SLOAvailabilityFastBurn` يفضل ساكت لأن `sre-lab.*` مستبعد من الـ SLI الحقيقي. الحسابات كلها في [73](73-slo-error-budget-burn-rate.md).

### 6.6 على GitHub Actions (من غير Docker محلي)

| Workflow | بيعمل إيه هنا |
|---|---|
| [`lab-integration.yml`](../../../.github/workflows/lab-integration.yml) job **Compose · smoke · k6 · SRE drills** | يبني `ci-v1`، يشغّل `app` + `mysql`، migrate + `DemoSeeder` + `LoadTestSeeder` (`LOADTEST_USERS=5`، `LOADTEST_STUDENTS_PER_USER=20`)، smoke بـ curl (`/up`، `/ready` فيه `"version":"ci-v1"`، `/sre-lab/ping`، `/sre-lab/db/heavy`، `/metrics` فيه `student_app_app_info{version="ci-v1"`، `/sre-lab/error?rate=1&code=503` = 503)، login flow حقيقي، `k6 smoke.js`، `k6 load.js` (VUS=5، 45s)، والـ drills: `SRE_LAB_ENABLED=false` → 404، `SRE_FAULT_UNHEALTHY` → 500/503، `SRE_FAULT_BOOT_FAIL` → الـ container مش بيقوم |
| [`observability-lint.yml`](../../../.github/workflows/observability-lint.yml) | `promtool check config/rules` + `promtool test rules`، مقارنة الـ PrometheusRule بتاع K8s بالـ compose rules (no drift)، `amtool check-config`، `loki -verify-config`، `alloy fmt`، `otelcol validate`، `docker compose config`، الـ dashboards JSON صالحة وبتستخدم `${datasource}`، و `k6 inspect` على كل script |
| [`perf-gate.yml`](../../../.github/workflows/perf-gate.yml) | k6 ضد environment **deployed** (URL حقيقي، مش localhost) — [74](74-load-testing-k6.md) |

```bash
gh workflow run lab-integration.yml --ref devops-lab
gh run watch
gh run view <RUN_ID> --log | grep -E "checks|http_req_failed|http_req_duration|✓|✗" | head -40
gh workflow run observability-lint.yml --ref devops-lab
```

> 💡 خد بالك: الـ CI **مش** بيشغّل ستاك Prometheus/Grafana — بيعمله lint بس. عشان تشوف الـ dashboards بعينك محتاج WSL2 أو الـ EC2 host.

## 7) التحقق (Verify)

```bash
# الـ targets
curl -s localhost:9090/api/v1/targets | jq -r '.data.activeTargets[] | "\(.labels.job)\t\(.labels.instance)\t\(.health)"'

# مين الـ release اللي شغال
curl -s localhost:9090/api/v1/query --data-urlencode 'query=student_app_app_info' | jq '.data.result[].metric'

# الـ recording rules بتطلع أرقام (بعد دقايق من الـ traffic)
curl -s localhost:9090/api/v1/query --data-urlencode 'query=job:student_app_sli_availability_errors:ratio_rate5m' | jq '.data.result'

# Loki شايف لوجز التطبيق
curl -s -G localhost:3100/loki/api/v1/labels | jq
```

المفروض: `student-app` / `app:8080` = `up` (والـ blue/green DOWN لو مش شغالين)، `app_info` فيه `version="local"`، والـ ratio رقم صغير (أو `0`)، والـ Loki labels فيها `service` و `compose_project` و `level`.

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر | المتوقع |
|---|---|---|
| الستاك قبل الـ app | `docker compose down` ثم `up` للـ observability | `network student-app_default declared as external, but could not be found` |
| الـ lab مقفول | `SRE_LAB_ENABLED=false docker compose up -d --no-build --wait app` | `/sre-lab/*` = 404، و `SRE_FAULT_*` مالهاش أثر |
| Token | `SRE_LAB_TOKEN=s3cret docker compose up -d --no-build --wait app` | من غير `X-Lab-Token` = 403؛ k6 محتاج `-e LAB_TOKEN=s3cret` |
| `METRICS_ENABLED=false` | نفس الطريقة | target **DOWN** (404)، وبعد دقيقتين `StudentAppNoTargetsUp` (page) |
| `METRICS_TOKEN` من غير ما Prometheus يعرفه | `METRICS_TOKEN=x` (عدّل `x-app-env` أو env file) | 403 → target DOWN. فك الـ `authorization` block في `prometheus.yml` |
| Caps | `?ms=70000` على latency، `?mb=1024` على memory | `slept_ms: 10000`، `allocated_mb: 128` |
| Memory أكبر من الـ PHP limit | `SRE_LAB_MAX_MEMORY_MB=1024` + `?mb=1000` | Fatal "Allowed memory size exhausted" → 500 — الـ cap موجود عشان ده |
| Drain | `POST /sre-lab/unready` على slot واحد في ستاك [23](23-bluegreen-single-host.md) | `wait_ready` يفشل على الـ slot ده؛ الـ traffic يفضل على التاني |

## 9) الرجوع (Rollback)

```bash
docker compose up -d --no-build --wait app            # الـ env الافتراضية (من غير SRE_FAULT_*)
curl -s -X POST http://localhost:8080/sre-lab/ready     # لو سبت flag
curl -X POST http://localhost:9090/-/reload             # بعد تعديل rules
```

## 10) المسح (Teardown) ⚠️

```bash
docker compose -f observability/compose/docker-compose.yml down -v   # -v = يمسح بيانات Prometheus/Grafana/Loki
docker compose down -v                                               # الـ app + الـ MySQL volume
```

## 11) التكلفة (Cost)

| Resource | السعر التقريبي |
|---|---|
| كله محلي أو على GitHub Actions | مجاني (دقائق Actions للـ repo الـ private محدودة) |
| لو على host سيناريو 20 | نفس [20](20-ec2-compose-console.md) — بس ستاك الـ observability محتاج RAM أكتر (t3.small على الأقل) |

## 12) أسئلة Interview

<details><summary>ليه الـ liveness مش بيعمل DB check والـ readiness بيعمل؟</summary>

الـ liveness failure = restart. لو الـ DB وقعت والـ liveness بيعتمد عليها، كل الـ replicas هتتعمل restart مع بعض: cold start، connection storm لما الـ DB ترجع، وممكن CrashLoopBackOff يطوّل الـ outage. الـ readiness بيشيل الـ instance من الـ LB بس، وبيرجع لوحده. القاعدة: liveness = "الـ process نفسه بايظ ومحتاج restart"، readiness = "مش قادر أخدم دلوقتي".

</details>

<details><summary>ليه الـ fault injection بيضرب صفحات الـ web بس ومش `/ready`؟</summary>

عشان يقلّد الـ release السيء الحقيقي: الـ health checks خضرا والمستخدمين بيشوفوا errors. ده بيثبت إن الـ health checks لوحدها مش gate كفاية للـ deploy، وإنك محتاج metric-based analysis (canary على 5xx ratio، burn-rate alerts). `SRE_FAULT_UNHEALTHY` موجود منفصل للحالة التانية اللي الـ LB لازم يمسكها.

</details>

<details><summary>ليه الـ `route` label اسم الـ route مش الـ URL؟</summary>

كل قيمة label جديدة = time series جديدة في Prometheus. `/students/123` و `/students/456` كـ URLs = series لكل طالب → memory وقت الـ query بيتضرب، وممكن Prometheus يقع (cardinality explosion). اسم الـ route (`students.show`) ثابت ومحدود. والـ URLs اللي مش موجودة كلها تحت `unmatched` عشان scanner بيجرب آلاف الـ paths ميعملش آلاف الـ series.

</details>

<details><summary>إزاي تحمي endpoints زي `/sre-lab/*` و `/metrics` في environment حقيقي؟</summary>

طبقات: (1) مقفولة افتراضياً (`SRE_LAB_ENABLED=false`، `METRICS_ENABLED=false`)؛ (2) token (`X-Lab-Token`، Bearer)؛ (3) على الـ edge: ALB rule بترجّع 404 لـ `/metrics` (موجودة في الـ alb module)، و WAF/ALB rule لـ `/sre-lab/*` ([83](83-edge-security-waf-https.md))؛ (4) الـ scrape من جوه الـ network (container-to-container) مش من الإنترنت؛ (5) caps على كل input. ومتفعّلش الـ lab أصلاً على production بيخدم عملاء.

</details>

<details><summary>Prometheus بيعمل scrape لـ 3 targets و 2 منهم DOWN دايماً. ده مشكلة؟</summary>

لأ — static config بيغطي الحالات الـ 3 (single، blue، green). الـ SLO rules بتعمل `sum` على اللي up، والـ alert `StudentAppNoTargetsUp` بيضرب بس لو كله down. البديل الأنضف هو service discovery (Docker SD، أو على K8s/ECS الـ SD بتاعتهم) بحيث الموجود بس هو اللي يتعمله scrape — بس الـ static أبسط في المعمل وواضح.

</details>

<details><summary>إيه الفرق بين `rate=1&code=503` على `/sre-lab/error` و `SRE_FAULT_ERROR_RATE`؟</summary>

`/sre-lab/error` route منفصل (`sre-lab.error`) مستبعد من الـ availability SLI ومحسوب في الـ drill SLI بس — آمن تشغّله في أي وقت. `SRE_FAULT_ERROR_RATE` بيضرب صفحات المستخدمين الحقيقية (`students.index`، `login`...) فبيحرق الـ SLO الحقيقي ويطلّع الـ pages الحقيقية — ده اللي تستخدمه لما عايز تختبر الـ incident response كامل.

</details>

## 13) Checklist

- [ ] جرّبت كل endpoint وشفت الـ caps بعينك
- [ ] عملت drain بـ `unready` وفهمت ليه `/up` فضل 200
- [ ] شغّلت `SRE_FAULT_ERROR_RATE` وشفت إن `/ready` فضل 200 و `X-SRE-Fault` ظهر
- [ ] شغّلت ستاك الـ observability بالترتيب الصح وفتحت الـ 3 dashboards
- [ ] شغّلت k6 smoke و load محلياً (أو قريت نتيجتهم في `lab-integration.yml`)
- [ ] شفت `SLODrillFastBurn` واصل لـ alert-sink على `/drill`
- [ ] عملت teardown بـ `down -v`
