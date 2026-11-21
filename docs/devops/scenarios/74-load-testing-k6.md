# 74 — Load testing بـ k6 (smoke → soak → breakpoint)

> **الهدف في سطر:** تعرف كل نوع load test بيجاوب على أنهي سؤال (smoke، load، stress، spike، soak، breakpoint، journey، autoscale، canary-watch، error-budget-burn)، تشغّل الـ scripts الحقيقية بكل الـ env vars بتاعتها، تفهم ليه الـ thresholds = الـ SLOs، وإزاي الـ scripts بتتعامل مع مصايد Laravel (CSRF 419، token rotation بعد الـ login، `_submission_token`)، تقرا النتايج وتعمل capacity planning (Little's law، الـ knee)، وتحوّل k6 لـ perf gate في الـ CI.
> **المستوى:** Intermediate → Advanced · **الوقت:** ~4 ساعات · **التكلفة التقريبية:** مجاني محلياً (على AWS: تكلفة الستاك اللي بتختبره)
> **بيعتمد على:** [12](12-sre-lab-endpoints-and-local-observability.md) · [73](73-slo-error-budget-burn-rate.md) · **الملفات في الـ repo:** [`loadtest/k6/README.md`](../../../loadtest/k6/README.md) · [`lib/config.js`](../../../loadtest/k6/lib/config.js) · [`lib/auth.js`](../../../loadtest/k6/lib/auth.js) · [`lib/journey.js`](../../../loadtest/k6/lib/journey.js) · [`lib/helpers.js`](../../../loadtest/k6/lib/helpers.js) · [`lib/metrics.js`](../../../loadtest/k6/lib/metrics.js) · [`LoadTestSeeder.php`](../../../database/seeders/LoadTestSeeder.php) · [`PreventDuplicateSubmissions.php`](../../../app/Http/Middleware/PreventDuplicateSubmissions.php) · [`perf-gate.yml`](../../../.github/workflows/perf-gate.yml) · [`lab-integration.yml`](../../../.github/workflows/lab-integration.yml)

## 1) الفكرة (Concepts)

الـ load test مش "اضرب السيرفر وشوف هيقع إمتى". كل test بيجاوب على سؤال واحد، وبيتحكم عليه بالـ **SLOs** (نفس أرقام Prometheus و CloudWatch — [CONVENTIONS §5](../CONVENTIONS.md)).

| Script | السؤال | الـ executor / الشكل | Defaults |
|---|---|---|---|
| [`smoke.js`](../../../loadtest/k6/smoke.js) | الـ deploy شغال أصلاً؟ (health، login، قراية، كتابة واحدة) | `constant-vus` (≤ 2) | `VUS=2`، `DURATION=30s` |
| [`load.js`](../../../loadtest/k6/load.js) | بنحقق الـ SLO عند الـ traffic المتوقع؟ | `ramping-vus` 20% ramp / 60% hold / 20% down | `VUS=10`، `DURATION=5m` |
| [`stress.js`](../../../loadtest/k6/stress.js) | إيه اللي بيقع الأول فوق الطبيعي؟ degradation نضيف؟ | steps 1×,2×,3×,4× `VUS` (30s ramp + `DURATION` hold لكل step) + 1m recovery | `VUS=20`، `DURATION=2m`، `STEPS=1,2,3,4` |
| [`spike.js`](../../../loadtest/k6/spike.js) | قفزة 10× في ثواني؟ بنتعافى قد إيه؟ | baseline → spike في 10s → hold → رجوع → 2m recovery | `VUS=5`، `SPIKE_VUS=VUS×10`، `DURATION=1m` |
| [`soak.js`](../../../loadtest/k6/soak.js) | لسه سليم بعد ساعات؟ (leaks، نمو الجداول، الـ disk) | `ramping-vus` ثابت | `VUS=20`، `DURATION=2h` |
| [`breakpoint.js`](../../../loadtest/k6/breakpoint.js) | الـ capacity كام req/s جوه الـ SLO؟ | `ramping-arrival-rate` (open model) + `abortOnFail` | `START_RATE=5`، `MAX_RATE=200`، `DURATION=20m`، `TARGET=journey` |
| [`user-journey.js`](../../../loadtest/k6/user-journey.js) | مهمة حقيقية بتاخد قد إيه step بـ step؟ الكتابة idempotent؟ | `constant-vus` + k6 groups | `VUS=5`، `DURATION=5m` |
| [`autoscale-cpu.js`](../../../loadtest/k6/autoscale-cpu.js) | الـ CPU autoscaling بيلحق؟ | `constant-arrival-rate` على `/sre-lab/cpu` + scenario `whoami` | `RATE=10`، `CPU_MS=200`، `DURATION=10m` |
| [`canary-watch.js`](../../../loadtest/k6/canary-watch.js) | مين بيرد وبأنهي نسبة؟ صفر failures وقت الـ shift؟ | `constant-arrival-rate` على `/ready` | `RATE=10`، `DURATION=5m` |
| [`error-budget-burn.js`](../../../loadtest/k6/error-budget-burn.js) | الـ burn-rate alerts بتضرب امتى؟ | `constant-arrival-rate` على `/sre-lab/error` (أو صفحات حقيقية) | `BURN_RATE=20`، `RATE=10`، `DURATION=15m`، `MODE=lab` |

| المصطلح | المعنى |
|---|---|
| VU | virtual user: loop بيعمل `default function` تاني وتالت |
| Closed model (VU-based) | عدد users ثابت؛ لو السيرفر بطّأ، الـ users بيستنوا فالـ load **بيقل** لوحده — بيخبّي المشكلة (coordinated omission) |
| Open model (arrival-rate) | requests/s ثابتة مهما السيرفر بطّأ — زي الإنترنت الحقيقي؛ لو الـ VUs خلصوا → `dropped_iterations` |
| Threshold | شرط على metric؛ لو اتكسر k6 بيخرج بـ **exit 99** |
| Check | assertion على response واحد (مش بيوقف الـ test، بيتحسب في `checks` rate) |
| Think time | الانتظار بين الصفحات (`THINK_TIME` ±50% jitter عشان الـ VUs متمشيش lockstep) |

### 1.1 كل الـ env vars (من الـ scripts)

| Var | Default | مين بيستخدمه | المعنى |
|---|---|---|---|
| `BASE_URL` | `http://localhost:8080` | الكل | الـ target (ALB DNS، nginx LB، ingress، `http://app:8080`) |
| `LOADTEST_USERS` | `20` | الـ journeys | عدد `loadtest{N}@example.com` المتسيدين — VU رقم n بياخد user `((n-1) % N)+1` |
| `PASSWORD` | `password` | الـ journeys | |
| `LAB_TOKEN` | فاضي | `/sre-lab/*` | بيتبعت كـ `X-Lab-Token` |
| `VUS` | حسب الـ script | VU-based | (smoke: max 2) |
| `DURATION` | حسب الـ script | الكل | `45s`، `5m`، `1h30m`، `500ms` (في stress: لكل step) |
| `P95_MS` | `500` | الـ gates | p95 على الـ responses الناجحة. **الـ SLO الحقيقي 300** (الـ default أعلى لأن الـ CI runner ضعيف؛ `perf-gate.yml` default `300`) |
| `P99_MS` | `1000` | الـ gates | tail SLO |
| `THINK_TIME` | `1` | VU-based | ثواني بين الصفحات |
| `WRITE_PCT` | `5` | الـ journeys | % من الـ page views اللي بتعمل student (في user-journey: 4× في الـ step 05) |
| `LAB_ENDPOINTS` | `true` | smoke | `false` لو الـ lab مقفول على الـ target (مايعملش `/sre-lab/ping`) |
| `TEST_ID` | فاضي | الكل | tag `testid` على كل sample |
| `INSECURE_TLS` | `false` | الكل | skip TLS verify (certs self-signed) |
| `SPIKE_VUS` | `VUS×10` | spike | |
| `STEPS` | `1,2,3,4` | stress | مضاعفات الـ `VUS` |
| `START_RATE` / `MAX_RATE` | `5` / `200` | breakpoint | iterations/s، ramp خطي |
| `TARGET` | `journey` | breakpoint | `journey`، `ping`، `db`، `db-heavy`، `cpu` |
| `PRE_VUS` / `MAX_VUS` / `MAX_DROPPED` | `50` / `1000` / `100` | breakpoint | pool الـ VUs، و abort بعد N dropped iterations |
| `RATE` | `10` | arrival-rate scripts | req/s |
| `CPU_MS` | `200` (`50` في breakpoint) | autoscale-cpu، breakpoint cpu | CPU لكل request |
| `MAX_VUS` | `max(50, RATE×10)` | autoscale-cpu | |
| `WATCH_PATH` | `/ready` | canary-watch | أو `/sre-lab/version` (بيضيف hostname، محتاج الـ lab) |
| `EXPECT_VERSIONS` | فاضي | canary-watch | `v1,v2` → rows لكل version في الـ summary |
| `CANARY_COLOR` / `CANARY_VERSION` | فاضي | canary-watch | مين يتحسب "canary" |
| `EXPECT_CANARY_PCT` / `TOLERANCE_PCT` | off / `5` | canary-watch | فشل لو نسبة الـ canary بره pct ± tolerance |
| `MAX_ERROR_RATE` | `0.005` | canary-watch | |
| `BURN_RATE` / `MODE` / `WARMUP` / `CODE` | `20` / `lab` / `0s` / `500` | error-budget-burn | [73 §5.8](73-slo-error-budget-burn-rate.md) |

### 1.2 الـ thresholds = الـ SLOs (`lib/config.js → sloThresholds()`)

| Threshold | الـ SLO | ليه |
|---|---|---|
| `http_req_failed: rate<0.005` | availability 99.5% | 0.5% = الـ budget؛ k6 بيعتبر أي status بره 200–399 فشل → **419 بيتحسب** (مقصود) |
| `http_req_duration{expected_response:true}: p(95)<P95_MS` | 95% < 300ms | الناجح بس — 500 سريعة متحسّنش الـ p95 |
| `…: p(99)<P99_MS` | p99 < 1s | (مش في smoke: مع 2 VUs الـ p99 = أبطأ request = login بـ bcrypt) |
| `checks: rate>0.99` (smoke: `rate==1`) | correctness | 200 بتاعة صفحة login = فشل |
| `csrf_failures`، `login_failures`، `session_relogins: count==0` | correctness | أعطال Laravel شكلها 200 OK (soak بيسمح بالـ relogins: `allowRelogin`) |
| `duplicate_submissions`، `validation_failures: count==0` | idempotency | user-journey بس |

`showPerPage()` بيضيف `http_req_duration{name:<route>}: max>=0` (بيعدّي دايماً) عشان k6 يطبع p95 لكل صفحة في الـ summary — والـ `name` = اسم الـ route في Laravel، فتقارن 1:1 مع `student_app_http_requests_total{route="students.show"}`. و `systemTags` من غير `url` (الـ URLs زي `/students/123` كانت هتعمل cardinality explosion لو بعت النتايج لـ Prometheus).

### 1.3 مصايد Laravel اللي الـ scripts بتتعامل معاها

1. **CSRF (419):** `GET /login` → regex على `name="_token" value="…"` (أو `<meta name="csrf-token">`) → `POST /login` form-encoded. أي `_token` قديم أو cookie مش محفوظ = **419 Page Expired** → `csrf_failures`.
2. **الـ token بيتغير بعد الـ login:** `session()->regenerate()` بيعمل rotate للـ CSRF token — الـ token بتاع فورم الـ login **مات**. `newSession()` بياخد الجديد من صفحة `/students` اللي اتعمل لها redirect، و `page()` بيحدّث `s.csrf` من كل صفحة.
3. **`_submission_token`:** كل فورم POST فيه UUID v4 (`x-form` component). `PreventDuplicateSubmissions` بيعمل `Cache::add("submission:<user>:<token>")` — الـ replay بنفس الـ token بيتعمله redirect لنفس النتيجة بدل insert تاني (TTL `subscriptions.submission_token_ttl`، default 60s). `user-journey.js` بيعمل replay متعمد ويتأكد إن الـ URL هو نفس الطالب (`duplicate_submissions == 0`).
4. **Login مرة واحدة لكل VU:** `noCookiesReset: true` — الـ cookie jar بيعيش طول عمر الـ VU. لو login كل iteration، الـ test هيبقى "bcrypt test" مش "browse test".
5. **Login throttle:** 5 محاولات فاشلة/دقيقة لكل email+IP — `ensureSession()` بيعمل back-off 5s بدل ما يضرب `/login` تاني.
6. **مش بيبعت `Sec-Fetch-Site`:** الـ `PreventRequestForgery` في Laravel 13 بيقبل requests "same-origin" من غير token — الـ scripts قاصدة تختبر مسار الـ `_token` الحقيقي.
7. **Session store:** `SESSION_DRIVER=file` ورا LB بأكتر من replica = sessions مش مشتركة → 419 و relogins. الـ lab بيستخدم `database` (أو `redis` في [49](49-redis-sessions-cache.md)). و `APP_KEY` مختلف بين الـ replicas = نفس العَرَض.
8. **التحقق من "signed-in":** كل صفحة في الـ layout المسجّل فيها فورم `/logout`؛ لو اتعمل redirect لـ `/login` → `sessionLost()` → `session_relogins`.

### 1.4 بيانات `LoadTestSeeder`

```bash
docker compose exec -T app sh -c 'LOADTEST_USERS=20 LOADTEST_STUDENTS_PER_USER=100 php artisan db:seed --class=LoadTestSeeder --force'
```

- users: `loadtest1@example.com … loadtestN@example.com` / `password` (عن طريق `User::factory`).
- لكل user: `LOADTEST_STUDENTS_PER_USER` طالب عن طريق `SubscriptionService::addStudent` (نفس مسار الـ traffic الحقيقي)، أسماء عربي (`fake('ar_EG')`)، تليفونات `010/011/012/015…`، codes من `500001`، section عشوائي من `Section::cases()`، تاريخ اشتراك في آخر 150 يوم، وتجديدات (loop بـ 80% احتمال تجديد في ميعاده) → تاريخ واقعي لصفحات الـ reports.
- **Idempotent:** user موجود = skip. فلو عايز داتا أكتر لنفس الـ users لازم تمسحهم.
- 20 × 100 = 2000 طالب + آلاف subscriptions — جداول بحجم يخلّي `/sre-lab/db/heavy` و `reports.index` يبانوا.
- k6 بيعمل طلاب بـ code `k6-<vu>-…` واسم `k6 Student …` و note `created by k6 (loadtest/k6)` — سهل تنضيفهم.

## 2) المعمارية (Architecture)

```text
 k6 (laptop / WSL / GitHub runner / grafana/k6 image)
  ├─ VU 1 ── GET /login → _token → POST /login (+_submission_token) → 302 → /students (token جديد)
  │          └─ browse: students.index 30 · ?q 20 · show 20 · dashboard 12 · reports 8 · notifications 5 · store WRITE_PCT
  ├─ VU 2 … (loadtest2@…)              think time 1s ±50%
  └─ thresholds = SLOs ──► exit 0 / 99
        │                                         │
        ▼                                         ▼
 app (ALB / nginx LB / app:8080) ─► /metrics ─► Prometheus ◄── k6 remote-write / OTLP (TEST_ID)
                                                 Grafana: RED + SLO (server side)  ◄── قارن بالـ k6 summary (client side)
 CI: lab-integration.yml (compose على الـ runner: smoke + load) · perf-gate.yml (environment deployed: أي script + HTML report)
```

## 3) المتطلبات (Prerequisites)

- [ ] target شغال: محلي ([12](12-sre-lab-endpoints-and-local-observability.md)) أو deployed (ALB).
- [ ] `LoadTestSeeder` متشغّل بنفس الـ `LOADTEST_USERS` اللي هتبعته لـ k6.
- [ ] `SRE_LAB_ENABLED=true` للـ scripts اللي بتستخدم `/sre-lab/*` (smoke ping، breakpoint lab targets، autoscale، error-budget-burn MODE=lab)، و `LAB_TOKEN` لو الـ target فيه `SRE_LAB_TOKEN`.
- k6: `winget install k6 --source winget` (Windows) أو من الـ apt repo في WSL ([03](03-workstation-setup.md))، أو image `grafana/k6:2.4.0`.

## 4) الطريقة الأولى: AWS Console (يدوي)

مفيش موارد جديدة. قبل أي test على AWS:

1. **Service Quotas / EC2 / RDS**: اتأكد إن الـ ASG `max` والـ ECS `autoscaling_max` كافيين، و `max_connections` بتاعة `db.t4g.micro` (صغيرة) — الـ stress هيوصلها.
2. **Budgets**: alert شغال ([02](02-aws-account-setup.md)).
3. افتح الـ CloudWatch dashboard (`terraform output -raw dashboard_url`) والـ ECS service events / ASG activity في tabs جنب الـ k6.
4. هات الـ token: `terraform output -raw sre_lab_token` (stacks 20/40) أو **Systems Manager → Parameter Store → `/student-app/lab/app/SRE_LAB_TOKEN` → Show decrypted value**.

## 5) الطريقة التانية: as Code — الـ scripts

### 5.1 `lib/` (مشترك، من غير remote imports — بيشتغل offline وجوه الـ image)

| ملف | فيه إيه |
|---|---|
| `config.js` | parsing للـ env (`envInt`، `envFloat`، `parseDuration`...)، ثوابت الـ SLO (`ERROR_BUDGET = 0.005`، `SLO_LATENCY_MS = 300`)، `baseOptions()` (`noCookiesReset`، `summaryTrendStats` فيها p90/p95/p99، `systemTags` من غير `url`، `testid`)، `sloThresholds()`، `showPerPage()` |
| `auth.js` | `vuEmail()`، `login()`، `ensureSession()` (lazy + back-off)، `sessionLost()` |
| `journey.js` | الـ page mix (`ACTIONS` weights)، `createStudent()` (+ replay)، `userJourney()` (7 groups: `01-dashboard` … `07-notifications`) |
| `helpers.js` | `uuidv4()` (Web Crypto)، `think()`، `labHeaders()`، `extractCsrf()`، `extractStudentIds()` |
| `metrics.js` | `csrf_failures`، `login_failures`، `session_relogins`، `validation_failures`، `students_created`، `duplicate_submissions`، `login_duration` |

### 5.2 Capacity planning — Little's law والـ knee

**Little's law:** `L = λ × W` — الـ concurrency = throughput × زمن الاستجابة.

- **حجم الـ VUs في test مغلق:** كل VU بيعمل request كل `THINK_TIME + W` → throughput ≈ `VUS / (THINK_TIME + W)`. مثال (من header `load.js`): `VUS=50`، `THINK_TIME=1`، W ≈ 0.1s → ~45 req/s.
- **سقف container واحد:** لو PHP-FPM فيه `C` workers (`pm.max_children`) ومتوسط الـ request `W`، أقصى throughput ≈ `C / W`. بعدها الـ requests بتستنى في الـ listen queue → الـ latency بتطلع من غير ما الـ throughput يزيد. (اعرف `C` بتاع الـ image من `PHP_FPM_PM_*` env بتاعة serversideup — متفترضش.)
- **k6 في open model:** VUs المطلوبة = `rate × W`. لو الـ W طلع من 0.1 لـ 2s عند 100 req/s → محتاج 200 VU؛ لو `MAX_VUS` أقل → `dropped_iterations` = إشارة إن السيرفر بطيء (مش إن k6 ضعيف).
- **الـ knee:** ارسم throughput (`http_reqs` rate) قصاد p95 من الـ breakpoint run. في الأول الـ throughput بيزيد خطياً والـ p95 ثابت؛ عند الـ knee الـ throughput بيـ flatten والـ p95 بيطلع بسرعة (queueing). **الـ capacity = الـ rate عند الـ knee جوه الـ SLO**، والتخطيط على ~60–70% منها (headroom للـ spikes لأن الـ autoscaling بيتأخر دقايق).
- **الـ autoscale math** (header `autoscale-cpu.js`): `CPU demand (vCPU) = RATE × CPU_MS / 1000` → `RATE=10, CPU_MS=200` = 2 vCPU. السعة = `demand / (vCPU per unit × target)`: t3.small (2 vCPU) عند 50% → 2 instances؛ task 0.5 vCPU عند 60% → ~7 tasks؛ pod `250m` عند 70% → ~12 pods.

### 5.3 قراية النتيجة

```text
✓ http_req_failed................: 0.12%   ✓ 4 ✗ 3201        ← لازم < 0.5%
✓ http_req_duration{expected_response:true}: p(95)=212ms p(99)=640ms
  http_req_duration{name:reports.index}: p(95)=480ms       ← أبطأ صفحة (display only)
✓ checks..........................: 99.9%
✓ csrf_failures / login_failures / session_relogins: 0
  dropped_iterations.............: 0                          ← open model: > 0 = السيرفر مش ملاحق
  iterations / http_reqs (rate)  = الـ throughput الفعلي
```

- **Exit codes:** `0` = كل الـ SLO thresholds عدّت، `99` = threshold اتكسر، غير كده = خطأ في الـ script/الـ infra.
- **الـ summary متوسط الـ run كله** — الـ soak لازم تقارن الساعة الأولى بالأخيرة في Grafana (الـ summary بيدفن الـ trend).
- **Client vs server:** k6 latency = network + queueing + التطبيق؛ Prometheus histogram = جوه PHP بس. الفرق الكبير = network/LB/queue قبل PHP-FPM.
- 419 كتير = sessions؛ 429 = throttle؛ 502/504 من الـ ALB = targets بتموت أو timeouts (ELB 5xx في CloudWatch).

## 6) الـ Deploy

### 6.1 محلياً (native k6 أو Docker)

```bash
B=http://localhost:8080
k6 run -e BASE_URL=$B -e LOADTEST_USERS=5 loadtest/k6/smoke.js
k6 run -e BASE_URL=$B -e LOADTEST_USERS=5 -e VUS=10 -e DURATION=5m loadtest/k6/load.js
k6 run -e BASE_URL=$B -e LOADTEST_USERS=5 -e VUS=5 -e DURATION=5m loadtest/k6/user-journey.js
k6 run -e BASE_URL=$B -e LOADTEST_USERS=5 -e VUS=10 -e STEPS=1,2,4 -e DURATION=1m loadtest/k6/stress.js
k6 run -e BASE_URL=$B -e LOADTEST_USERS=5 -e VUS=3 -e SPIKE_VUS=40 loadtest/k6/spike.js
k6 run -e BASE_URL=$B -e TARGET=ping -e MAX_RATE=300 -e DURATION=5m loadtest/k6/breakpoint.js     # سقف PHP-FPM
k6 run -e BASE_URL=$B -e TARGET=db-heavy -e MAX_RATE=100 -e DURATION=5m loadtest/k6/breakpoint.js # سقف الـ DB
k6 run -e BASE_URL=$B -e LOADTEST_USERS=5 -e VUS=10 -e DURATION=2h -e TEST_ID=soak-$(date +%F) loadtest/k6/soak.js
```

بالـ Docker (على network التطبيق — WSL2 + Docker Engine):

```bash
mkdir -p loadtest/results
docker run --rm -i --network student-app_default -u "$(id -u):$(id -g)" -v "$PWD/loadtest:/loadtest" \
  grafana/k6:2.4.0 run -e BASE_URL=http://app:8080 -e LOADTEST_USERS=5 \
  --summary-export /loadtest/results/load-summary.json /loadtest/k6/load.js
```

(Docker Desktop: `BASE_URL=http://host.docker.internal:8080`؛ PowerShell: `${PWD}/loadtest` ومن غير `-u`.)

### 6.2 Canary / blue-green watch

```bash
# terminal 1 (ستاك 23/24): الـ deploy
# terminal 2:
k6 run -e BASE_URL=http://localhost -e DURATION=3m -e EXPECT_VERSIONS=v1,v2 loadtest/k6/canary-watch.js
k6 run -e BASE_URL=http://localhost -e CANARY_COLOR=green -e EXPECT_CANARY_PCT=25 -e TOLERANCE_PCT=5 -e DURATION=2m loadtest/k6/canary-watch.js
```

كل iteration client جديد (`noCookiesReset: false`) فالـ sticky A/B cookie مش بيثبّت VU على لون. النتيجة: `release_responses{color:…}`، `release_latency`، `release_errors`، `canary_share`، و `http_req_failed` لازم ~0 (ده تعريف "zero downtime").

### 6.3 Autoscaling على AWS

```bash
k6 run -e BASE_URL=http://<ALB_DNS> -e LAB_TOKEN=<TOKEN> -e RATE=10 -e CPU_MS=200 -e DURATION=15m loadtest/k6/autoscale-cpu.js
```

الـ scenario `whoami` بيطبع `instance serving traffic: <hostname>` أول ما instance/task جديد يرد — ده لحظة ما الـ capacity الجديدة دخلت. الـ threshold هنا مش SLO: `http_req_failed{scenario:cpu}: rate<0.05` (أكتر من 5% = الـ scaling ما لحقش). كمّل راقب ~15 دقيقة بعد الـ test: الـ scale-in أبطأ عمداً ([48](48-autoscaling-under-load.md)، [57](57-ecs-autoscaling-under-load.md)، [6A](6A-hpa-karpenter-under-load.md)).

### 6.4 Outputs

```bash
k6 run --summary-export loadtest/results/summary.json loadtest/k6/load.js            # JSON (اللي perf-gate بيرفعه)

K6_WEB_DASHBOARD=true K6_WEB_DASHBOARD_EXPORT=loadtest/results/report.html \
  k6 run loadtest/k6/load.js                                                          # live على :5665 + HTML report
# CI: K6_WEB_DASHBOARD_PORT=-1 · Docker: -p 5665:5665 -e K6_WEB_DASHBOARD_HOST=0.0.0.0

K6_PROMETHEUS_RW_SERVER_URL=http://localhost:9090/api/v1/write \
K6_PROMETHEUS_RW_TREND_STATS="p(95),p(99),min,max" \
  k6 run -o experimental-prometheus-rw -e TEST_ID=load-$(date +%s) loadtest/k6/load.js   # deprecated (removal مخطط في v3)

K6_OTEL_EXPORTER_PROTOCOL=http/protobuf K6_OTEL_HTTP_EXPORTER_ENDPOINT=localhost:9090 \
K6_OTEL_HTTP_EXPORTER_URL_PATH=/api/v1/otlp/v1/metrics K6_OTEL_HTTP_EXPORTER_INSECURE=true \
K6_OTEL_METRIC_PREFIX=k6_ k6 run -o opentelemetry loadtest/k6/load.js                  # الطريق الجديد (Prometheus --web.enable-otlp-receiver)
```

مع الـ OTLP الأسماء بتتبع ترجمة OTLP→Prometheus (مثلاً `_total` suffix للـ counters).

### 6.5 على GitHub Actions

**`lab-integration.yml`** (كل push بيلمس الكود/الـ docker/الـ loadtest): compose على الـ runner، k6 `2.4.0` (نفس الـ pin في `perf-gate.yml` و `observability-lint.yml`) → `smoke.js` ثم `load.js` بـ `VUS=5 DURATION=45s` و `LOADTEST_USERS=5` — لو الـ SLO thresholds اتكسرت الـ job يقع.

**`perf-gate.yml`** — ضد environment **deployed**:

```bash
gh workflow run perf-gate.yml -f base_url=http://<ALB_DNS> -f script=load.js -f vus=20 -f duration=10m -f p95_ms=300 -f loadtest_users=20
gh run watch
gh run download <RUN_ID> -n k6-<RUN_ID>-1            # report.html + summary.json + k6-output.txt
```

| Step | بيعمل إيه |
|---|---|
| Inputs | `base_url`، `script` (choice من الـ 10)، `vus`، `duration`، `p95_ms` (300)، `loadtest_users` |
| `concurrency: perf-gate-<base_url>` و `cancel-in-progress: false` | مستحيل test-ين على نفس الـ environment (هيقيسوا بعض) |
| Inputs → env | مفيش `${{ }}` جوه `run:` → مفيش script injection؛ و `LAB_TOKEN` من secret `SRE_LAB_TOKEN` (k6 بيقرا الـ process env، فمش بيظهر في command line) |
| Validate inputs | regex على اسم الـ script والـ URL والأرقام والـ duration |
| Target is ready | `curl /ready` لحد 10 محاولات |
| Run k6 | `--summary-export`، web dashboard HTML (`K6_WEB_DASHBOARD_PORT=-1`)، `TEST_ID=perf-gate-<run>-<attempt>`، و `set +e` عشان يمسك الـ exit code |
| Job summary | Python بيقرا `summary.json` ويكتب جدول (req/s، error rate، p50/p95/p99، checks) و ✅/❌ لكل threshold (في `--summary-export` القيمة `true` = اتكسر) |
| Upload | artifact `k6-<run_id>-<attempt>` (14 يوم) |
| Fail on SLO breach | exit 99 → "SLOs crossed"، غير كده → "script/infra error" |

ومن deploy workflow بعد ما الـ release يبقى live:

```yaml
perf-gate:
  needs: deploy
  uses: ./.github/workflows/perf-gate.yml
  with: { base_url: "http://${{ needs.deploy.outputs.alb_dns }}", script: load.js, vus: "20", duration: 5m, p95_ms: "300" }
  secrets: inherit
```

و `observability-lint.yml` بيعمل `k6 inspect --execution-requirements` على كل script (syntax + options).

## 7) التحقق (Verify)

```bash
k6 version
k6 inspect --execution-requirements loadtest/k6/breakpoint.js | head -20
docker compose exec -T mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" student_app -N -e "SELECT COUNT(*) FROM users WHERE email LIKE \"loadtest%\";"'
k6 run -e BASE_URL=http://localhost:8080 -e LOADTEST_USERS=5 loadtest/k6/smoke.js; echo "exit=$?"
jq '.metrics.http_req_failed.value, .metrics["http_req_duration{expected_response:true}"]["p(95)"]' loadtest/results/summary.json
```

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر | المتوقع |
|---|---|---|
| Users أكتر من المتسيدين | `-e LOADTEST_USERS=50` وانت سايد 5 | `login_failures` > 0 → exit 99 |
| Sessions مش بتتحفظ | `LAB_SESSION_DRIVER=array docker compose up -d --no-build --wait app` | الـ login مش بيثبت (redirect لـ `/login`) → `login_failures`/`session_relogins` |
| Token ناقص | الـ target فيه `SRE_LAB_TOKEN` ومش باعت `LAB_TOKEN` | smoke: check `sre-lab ping` يفشل (403) → `checks rate==1` اتكسر |
| SLO صارم | `-e P95_MS=50` | exit **99**، والـ summary بيعلّم الـ threshold بـ ✗ |
| Bad release | `SRE_FAULT_ERROR_RATE=0.02` + `load.js` | `http_req_failed` ≈ 2% > 0.5% → exit 99 (والـ health checks خضرا!) |
| Breakpoint بـ VUs قليلة | `-e TARGET=db-heavy -e MAX_VUS=10` | `dropped_iterations` بتعدّي `MAX_DROPPED` → abort — السيرفر بطيء على الـ rate ده |
| Closed vs open | نفس الـ fault latency `SRE_FAULT_LATENCY_MS=800` على `load.js` و `breakpoint.js` | load: الـ req/s بيقل (الـ VUs مستنية) · breakpoint: الـ rate ثابت والـ VUs بتزيد/drops |

## 9) الرجوع (Rollback)

- Test بيأذي environment: **Ctrl+C** (k6 بيكمّل يكتب الـ summary)، أو cancel الـ workflow run (`gh run cancel <RUN_ID>`).
- تنضيف الطلاب اللي k6 عملها (SQL مباشر — على lab بس):

```bash
docker compose exec -T mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" student_app -N -e "SELECT COUNT(*) FROM students WHERE code LIKE \"k6-%\";"'
```

(المسح الفعلي لازم يراعي الـ subscriptions المرتبطة/الـ soft deletes — أسهل حاجة على lab: `migrate:fresh --seed` أو تعيد الـ volume.)

## 10) المسح (Teardown) ⚠️

```bash
rm -rf loadtest/results          # gitignored أصلاً
```

لو اختبرت على AWS: الـ scale-out اللي حصل بيرجع لوحده بعد الـ cooldown — اتأكد (`aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names student-app-lab-blue --query 'AutoScalingGroups[0].DesiredCapacity'`) قبل `terraform destroy` ([97](97-cost-and-teardown.md)).

## 11) التكلفة (Cost)

| Resource | السعر التقريبي |
|---|---|
| k6 OSS محلي / Docker | مجاني |
| GitHub Actions | مجاني للـ public؛ soak 2h على repo private = 120 دقيقة من الـ quota |
| على AWS | الـ ALB LCUs + الـ instances/tasks الإضافية من الـ scale-out + data transfer — دقايق/ساعات = سنتات، بس soak طول الليل على stack 40/50 ≈ تكلفة يوم |

## 12) أسئلة Interview

<details><summary>إيه الفرق بين load و stress و spike و soak و breakpoint؟</summary>

load: الـ traffic المتوقع → بنحقق الـ SLO؟ (pass/fail gate). stress: فوق الطبيعي بخطوات → إيه بيقع الأول وإزاي (graceful؟). spike: قفزة مفاجئة → الـ headroom والـ recovery (الـ autoscaling بيتأخر دقايق). soak: ساعات → leaks، نمو جداول/لوجز، connection leaks. breakpoint: open-model ramp لحد ما الـ SLO يتكسر → رقم الـ capacity اللي بتبني عليه الـ autoscaling والـ alarms.

</details>

<details><summary>Closed model ولا open model؟ وإيه coordinated omission؟</summary>

Closed (VUs ثابتة): لما السيرفر يبطّأ، الـ VUs بتستنى فالـ load المبعوت بيقل — النتيجة بتبان أحسن من الحقيقة (الـ requests اللي "كان المفروض تتبعت" وقت البطء اتحذفت = coordinated omission). Open (arrival-rate): rate ثابت زي users الإنترنت اللي مش بيستنوا بعض — بيكشف الـ queueing بجد. closed مناسب للـ journeys الواقعية بـ think time، open للـ capacity والـ breakpoint.

</details>

<details><summary>ليه الـ latency threshold على `expected_response:true` بس؟</summary>

لأن الـ errors غالباً سريعة (500 فوري، 503 من LB). لو اتحسبت، outage هيحسّن الـ p95! الـ errors ليها threshold منفصل (`http_req_failed`)، والـ latency على الناجح بس — نفس تعريف الـ latency SLI.

</details>

<details><summary>إزاي تعمل load test لتطبيق Laravel فيه CSRF من غير ما تقفل الـ CSRF؟</summary>

تعامل زي المتصفح: GET الفورم، استخرج `_token`، احتفظ بالـ cookie jar، ابعت الـ POST. بعد الـ login الـ session بتتعمل regenerate فالـ token بيتغير — خده من أول صفحة بعد الـ redirect وحدّثه من كل صفحة. login مرة لكل VU. وأي 419 تتعد كـ failure (مش تتجاهلها) لأنها بتكشف مشاكل حقيقية (sessions مش مشتركة، `APP_KEY` مختلف بين replicas).

</details>

<details><summary>إزاي تحسب الـ capacity من breakpoint test وتحوّله لـ autoscaling config؟</summary>

اقرا الـ rate عند الـ knee (الـ throughput بيـ flatten والـ p95 بيطلع) جوه الـ SLO لـ N instances. capacity لكل instance = knee/N. خطط على ~60–70% (headroom للـ spikes ووقت الـ scale-out). الـ target tracking: `ALBRequestCountPerTarget` = 60–70% من الـ capacity لكل target × 60 (الـ metric per minute) — أو CPU target لو الـ CPU هو اللي بيوصل الأول. وبعدين `autoscale-cpu.js`/spike تثبت إنه بيلحق.

</details>

<details><summary>k6 كـ CI gate — إيه المشاكل وإزاي تحلها؟</summary>

ضوضاء: الـ runners مشتركة وضعيفة → thresholds أرخى في الـ CI (`P95_MS=500`) والحقيقية (300) ضد environment ثابت. tests بتقيس بعض → `concurrency` لكل environment. الـ secrets → env مش command line. لازم artifacts (HTML + JSON) عشان التحليل. ومتعملش gate على حاجة مش deterministic (زي `error-budget-burn`). والأهم: الـ gate بيمنع regressions كبيرة، مش بيحل محل الـ SLO monitoring على 30 يوم.

</details>

## 13) Checklist

- [ ] شغّلت `LoadTestSeeder` بنفس `LOADTEST_USERS` اللي بعته لـ k6
- [ ] smoke و load و user-journey عدّوا محلياً (exit 0)
- [ ] شغّلت breakpoint على `ping` و `db-heavy` ولقيت الـ knee لكل واحد
- [ ] شغّلت stress أو spike وقريت Grafana جنب الـ summary
- [ ] كسرت test بـ `P95_MS` صارم وشفت exit 99
- [ ] شغّلت `perf-gate.yml` (أو قريت الـ job summary بتاعه) ونزّلت الـ HTML report
- [ ] أقدر أشرح Little's law والـ closed/open model
