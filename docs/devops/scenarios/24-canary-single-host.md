# 24 — Canary على سيرفر واحد (weights + metric gate + auto-abort)

> **الهدف في سطر:** تشغّل `canary.sh` اللي بيدّي الإصدار الجديد 10% → 25% → 50% → 100% من الـ traffic، ويحكم عليه من الـ `/metrics` بتاعه هو بعد كل خطوة، ويعمل **auto-abort** (exit 2) لو الـ error rate عدّى الحد — وتفهم حدود الحكم الإحصائي ده.
> **المستوى:** Intermediate → Advanced · **الوقت:** ~3 ساعات · **التكلفة التقريبية:** نفس [20](20-ec2-compose-console.md)
> **بيعتمد على:** [23 — Blue/Green على سيرفر واحد](23-bluegreen-single-host.md) · **الملفات في الـ repo:** [`deploy/ec2/lb/bin/canary.sh`](../../../deploy/ec2/lb/bin/canary.sh) · [`deploy/ec2/lb/bin/lib.sh`](../../../deploy/ec2/lb/bin/lib.sh) · [`app/Http/Middleware/RecordRequestMetrics.php`](../../../app/Http/Middleware/RecordRequestMetrics.php) · [`app/Http/Middleware/InjectFaults.php`](../../../app/Http/Middleware/InjectFaults.php) · [`deploy/scripts/probe.sh`](../../../deploy/scripts/probe.sh)

## 1) الفكرة (Concepts)

Blue/green بيحوّل 100% مرة واحدة — لو الإصدار فيه bug بيظهر بس تحت traffic حقيقي (مش في الـ smoke)، **كل** المستخدمين بيتأثروا. الـ **Canary** بيقلل الـ blast radius: نسبة صغيرة من الـ requests تروح للجديد، نقيس، ونكبّر أو نرجع **أوتوماتيك**.

| المصطلح | المعنى |
|---|---|
| Step | نسبة traffic للـ canary لمدة `STEP_SECONDS` |
| Metric gate / analysis | قرار promote/abort مبني على metrics (هنا: 5xx ratio على صفحات حقيقية) |
| Auto-abort | رجوع 100% للـ stable من غير إنسان |
| Blast radius | نسبة المستخدمين اللي ممكن يتأثروا لو الإصدار سيء |
| Bake time | وقت الانتظار عند كل خطوة عشان المشاكل تظهر |

**Canary مقابل A/B:** الـ canary بيقسّم **requests عشوائية** ويحكم بالـ error rate (سؤال تشغيلي: "الإصدار سليم؟"). الـ A/B بيقسّم **مستخدمين** بشكل sticky ويحكم بـ business metrics (سؤال منتج: "النسخة دي أحسن؟") — [26](26-ab-testing-shadow-feature-flags.md).

## 2) المعمارية (Architecture)

```text
 traffic (users / probe على /login)
        │
        ▼
 proxy nginx ── upstream app_main (zone مشتركة بين الـ workers) ─────────────┐
                 server app_<stable>:8080 resolve weight=90;                 │
                 server app_<canary>:8080 resolve weight=10;   ◄── render_weighted
        │                                                                     │
        ├──► app_<stable>  (ACTIVE في state طول الـ canary)                   │
        └──► app_<canary>  ──► 127.0.0.1:<port>/metrics ──► slot_counters ──┘
                                   │  "<5xx> <total>" قبل وبعد STEP_SECONDS
                                   ▼
                     rate = Δerrors / Δtotal > MAX_ERROR_RATE ?
                         yes → abort: 100% stable، stop canary، exit 2
                         no  → الخطوة الجاية … → promote (render_single canary)
```

## 3) المتطلبات (Prerequisites)

- [ ] ستاك `deploy/ec2/lb` شغال من [23](23-bluegreen-single-host.md) (أو هتشغّل على GitHub Actions).
- [ ] `METRICS_ENABLED=true` في `app.env`. `METRICS_TOKEN` اختياري: لو متحدد، `slot_counters` بيبعته كـ `Authorization: Bearer <token>` (من متغير البيئة `METRICS_TOKEN` لو موجود، وإلا من سطر `METRICS_TOKEN=` في `APP_ENV_FILE`).
- [ ] release جديد مبني (`student-app:v2` أو SHA).
- الأدوات: `curl`، `bash`، terminal تاني للـ traffic.

## 4) الطريقة الأولى: AWS Console (يدوي)

مفيش موارد جديدة. اتأكد من حاجتين:

1. **Systems Manager → Parameter Store** → `/student-app/lab/app/METRICS_ENABLED` = `true`. لو عايز تقفل `/metrics` بـ token (مستحسن على أي host مكشوف): **Create parameter** `/student-app/lab/app/METRICS_TOKEN` (SecureString، `openssl rand -hex 16`) → على السيرفر `bash deploy/ec2/render-env-from-ssm.sh` → الـ slots الجديدة هتاخده، والـ gate هيقراه من `app.env`.
2. **EC2 → Security Groups** → بورت 80 من **My IP** بس. الـ `/metrics` مقفول على الـ proxy (`location = /metrics { return 404; }`)، والـ script بيقراه من `127.0.0.1:8081/8082` مباشرة.

> 💡 في [46](46-canary-weighted-target-groups.md) نفس الفكرة بتتعمل بـ ALB weighted target groups، والـ gate بيبقى CloudWatch alarm على `HTTPCode_Target_5XX_Count` للـ target group بتاع الـ canary.

## 5) الطريقة التانية: as Code — `canary.sh` من جوه

### 5.1 الـ knobs

| Env | الافتراضي | المعنى |
|---|---|---|
| `STEPS` | `"10 25 50 100"` | النِسب بالترتيب؛ أول قيمة ≥ 100 = promote |
| `STEP_SECONDS` | `30` | مدة كل خطوة (والـ "hold" لو الـ traffic قليل) |
| `MAX_ERROR_RATE` | `0.01` | أقصى نسبة 5xx مسموحة على الـ canary |
| `MIN_REQUESTS` | `10` | أقل عدد requests للحكم |
| `SLOT_ENV` | — | env للـ canary بس (تمارين bad release) |
| + كل knobs `lib.sh` | | `SKIP_PULL`، `SKIP_MIGRATE`، `READY_TIMEOUT`... ([23](23-bluegreen-single-host.md)) |

### 5.2 الـ flow

1. `load_state` → **`ensure_single_live`** (لو `MODE` مش `single` يرجّع 100% للـ `ACTIVE` الأول).
2. `STABLE=$ACTIVE`، `CANARY=$(other STABLE)` → `set_image CANARY` → `MODE=canary` → `save_state`.
3. `start_slot CANARY` = pull → slot env → **migrate** → recreate → `wait_ready` → `smoke` (`/up`، `/ready`، `/login`). الدوال دي **بترجع 1** لو فشلت (مش بتقفل السكريبت)، و `canary.sh` بيعتبر أي فشل هنا **canary aborted** (exit **2**): "canary failed its pre-traffic checks (migrate / ready / smoke)" — الإصدار مخدش ولا request من المستخدمين.
4. لكل `pct` في `STEPS` (لحد أول قيمة ≥ 100):
   - `render_weighted STABLE CANARY pct` → `weight=$((100-pct))` و `weight=pct` → `reload_proxy`.
   - `slot_counters CANARY` → `e0 t0` · `sleep STEP_SECONDS` · `slot_counters` → `e1 t1`.
   - `total = t1 - t0`. لو `< MIN_REQUESTS`: warning، يستنى `STEP_SECONDS` كمان، يعيد القراية (من نفس `e0/t0`)، ولو لسه قليل → **abort** "no traffic reached the canary - cannot judge it".
   - `rate = errors / total` (4 أرقام عشرية). لو `rate > MAX_ERROR_RATE` → **abort**.
5. **Promote:** `render_single CANARY` → reload → `ACTIVE=CANARY`، `MODE=single` → الـ stable القديم **فاضل شغال** للـ rollback.

`abort()`: `render_single STABLE` → reload → `ACTIVE=STABLE`، `MODE=single` → `stop_slot CANARY` → **exit 2**.

| Exit | المعنى |
|---|---|
| `0` | promoted |
| `2` | **aborted**: فشل قبل الـ traffic (migrate/ready/smoke)، أو الـ gate (error rate)، أو مفيش traffic كفاية — في كل الحالات 100% على الـ stable والـ canary slot متوقف |
| `1` | حاجة تانية منعت السكريبت يبدأ أو يكمّل: مفيش state، `ensure_single_live` رفض لأن الـ live مش ready، أو `nginx -t` فشل |

> 💡 لو قطعت السكريبت بـ Ctrl+C في نص الخطوات، الـ nginx هيفضل على الـ weights الأخيرة و `MODE=canary`. `bash bin/rollback.sh` بيشوف `MODE=canary` فيرجّع 100% للـ `ACTIVE` (الـ stable) ويخلي `MODE=single` — والـ canary slot بيفضل شغال للتحقيق. (وأول deploy جاي كمان بيعمل `ensure_single_live`.)

### 5.3 الـ metric gate: `slot_counters`

```bash
token="${METRICS_TOKEN:-$(grep -E '^METRICS_TOKEN=' "$APP_ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"')}"
[[ -n "$token" ]] && auth=(-H "Authorization: Bearer $token")
curl -fsS -m 3 "${auth[@]}" "http://127.0.0.1:$port/metrics" \
  | awk '/^student_app_http_requests_total\{/ {
           if ($0 ~ /route="(sre-lab\.|health\.ready|up)/) next
           total += $NF
           if ($0 ~ /status="5[0-9][0-9]"/) errors += $NF
         }
         END { printf "%d %d\n", errors, total }'
```

- العداد `student_app_http_requests_total{method,route,status}` بيتسجّل من `RecordRequestMetrics` (global middleware) في **APCu** — مشترك بين كل الـ FPM workers في الـ container، وبيبدأ من صفر مع كل container جديد. عشان كده السكريبت بياخد **الفرق** قبل/بعد.
- الـ `route` label = اسم الـ route (أو الـ URI لو مفيش اسم): `login`، `students.index`، `sre-lab.ping`، `health.ready`، و `up` (الـ health route بتاع Laravel). الـ awk بيستبعد `sre-lab.*` و `health.ready` و `up` → **بنحكم على صفحات حقيقية بس**. والـ `/metrics` نفسه مش بيتعد أصلاً.
- الـ token: لو `METRICS_TOKEN` متحدد في الـ shell بيكسب، وإلا بيتقري من `APP_ENV_FILE` (نفس الملف اللي الـ slots بتاخد منه الـ env، فالقيمتين متطابقين تلقائياً).
- لو الـ curl فشل لأي سبب (`METRICS_ENABLED=false`، token غلط، الـ slot واقع) الناتج `0 0` → يبان كأن مفيش traffic → abort "no traffic".

### 5.4 ليه الـ fault بيوصل للـ gate ومش للـ health checks؟

`InjectFaults` متسجّل على الـ **web** middleware group بس ([`bootstrap/app.php`](../../../bootstrap/app.php))، و `/ready` و `/metrics` و `/sre-lab/*` متسجلين **بره** الـ web group. فـ `SRE_FAULT_ERROR_RATE=0.5` بيخلّي نص صفحات الـ web (زي `/login`) ترجع 500 مع header `X-SRE-Fault: error-rate`، و `/up` و `/ready` بيفضلوا ناجحين. ده بالظبط الـ "bad release" اللي الـ LB health checks مش هتشوفه، والـ canary analysis هي اللي بتمسكه.

## 6) الـ Deploy

### 6.1 Canary سليم (على EC2)

Terminal 1 — traffic على صفحات حقيقية (~20 req/s):

```bash
cd /opt/student-app/src
bash deploy/scripts/probe.sh http://localhost/login 0 0.05
```

Terminal 2 — الـ canary:

```bash
cd /opt/student-app/src/deploy/ec2/lb
STEPS="10 25 50 100" STEP_SECONDS=60 MAX_ERROR_RATE=0.01 SKIP_PULL=true bash bin/canary.sh student-app:v2
echo "exit=$?"
bash bin/status.sh
```

تابع في Terminal 3: `watch -n 2 'bash ../../scripts/version-split.sh http://127.0.0.1/ready 20'` — هتشوف النسبة بتكبر مع كل خطوة.

أوقف الـ probe بـ Ctrl+C — هيطبع الـ summary (المفروض `failed : 0`).

### 6.2 تمرين الـ bad release

```bash
# Terminal 1: نفس الـ traffic على /login
# Terminal 2:
SLOT_ENV="SRE_FAULT_ERROR_RATE=0.5" STEPS="25 100" STEP_SECONDS=20 MIN_REQUESTS=5 SKIP_PULL=true \
  bash bin/canary.sh student-app:v2
echo "exit=$?"                     # 2 = aborted (دايماً)
cat state/release.env              # ACTIVE = الـ stable، MODE=single
```

الـ exit هيبقى **2 في كل مرة**، بس من واحد من طريقين (الاتنين صح):

| الطريق | إمتى | اللي هتشوفه |
|---|---|---|
| **Pre-traffic abort** | الـ `smoke` (request واحد على `/login`) وقع في الـ 50% — حوالي نص المرات | `smoke test failed: app_<canary> /login` ثم `ABORT: canary failed its pre-traffic checks (migrate / ready / smoke)` — ولا مستخدم شاف الإصدار |
| **Metric-gate abort** | الـ smoke عدّى | `canary analysis: N errors / M requests = 0.5xxx (max 0.01)` ثم `ABORT: error rate ... at 25%` — الـ probe في Terminal 1 هيبيّن failures **في فترة الـ 25% بس** (ده الـ blast radius) |

وفي الحالتين: `canary aborted - 100% of traffic back on <stable>` والـ canary slot بيتوقف. لو عايز تشوف الـ gate بالذات أغلب المرات، استخدم نسبة أقل زي `SRE_FAULT_ERROR_RATE=0.2` (الـ smoke بيعدّي ~80%، و 20% أكبر بكتير من `MAX_ERROR_RATE`).

### 6.3 على GitHub Actions

في [`lab-integration.yml`](../../../.github/workflows/lab-integration.yml) (job **Zero-downtime scripts**):

```yaml
- name: Canary ci-v2 → ci-v1, healthy → promoted (real-page traffic, 0 failures)
  run: |
    PROBE_URL=http://localhost/login PROBE_INTERVAL=0.02 \
    STEPS="25 50 100" STEP_SECONDS=10 MIN_REQUESTS=5 \
      bash $PROBE -- bash $LB/canary.sh student-app:ci-v1

- name: Canary with a BAD release → metric gate aborts, traffic back on stable
  run: |
    STOP_FILE=/tmp/stop-traffic bash deploy/scripts/probe.sh http://localhost/login 0 0.02 > /tmp/traffic.log 2>&1 &
    SLOT_ENV="SRE_FAULT_ERROR_RATE=0.5" STEPS="25 100" STEP_SECONDS=10 MIN_REQUESTS=5 EXPECT_EXIT=2 \
      bash $PROBE -- bash $LB/canary.sh student-app:ci-v2
```

- الأول: الـ `with-probe.sh` نفسه بيولّد الـ traffic على `/login` كل 20ms ويشترط **0 failures** على صفحات حقيقية طول الـ canary السليم.
- التاني: traffic منفصل على `/login` (هيشوف errors من نصيب الـ canary — مقصود)، والـ `with-probe.sh` بيراقب `/ready` (الافتراضي) بـ `MAX_FAILURES=0` و `EXPECT_EXIT=2`. الـ step ده deterministic: سواء الـ smoke مسك الإصدار قبل الـ traffic أو الـ gate مسكه بعد الـ 25%، الـ exit = 2 والـ stable path فاضل سليم.

```bash
gh run view <RUN_ID> --log | grep -E "canary analysis|ABORT|promot|smoke" | head -20
```

## 7) التحقق (Verify)

```bash
cd /opt/student-app/src/deploy/ec2/lb
TOKEN=$(grep -E '^METRICS_TOKEN=' /opt/student-app/app.env | cut -d= -f2-)    # فاضي لو مش متحدد
sed -n '/upstream app_main/,/}/p' state/nginx/upstreams.conf      # الـ weights الحالية
curl -s ${TOKEN:+-H "Authorization: Bearer $TOKEN"} http://127.0.0.1:8081/metrics | grep '^student_app_http_requests_total' | grep -v 'sre-lab\|health.ready\|route="up"'
curl -s ${TOKEN:+-H "Authorization: Bearer $TOKEN"} http://127.0.0.1:8082/metrics | grep student_app_app_info
bash ../../scripts/version-split.sh http://127.0.0.1/ready 100
```

احسب الـ gate بإيدك (نفس الـ awk):

```bash
port=8082
curl -fsS -m 3 ${TOKEN:+-H "Authorization: Bearer $TOKEN"} "http://127.0.0.1:$port/metrics" | awk '/^student_app_http_requests_total\{/ { if ($0 ~ /route="(sre-lab\.|health\.ready|up)/) next; t+=$NF; if ($0 ~ /status="5[0-9][0-9]"/) e+=$NF } END { printf "%d errors / %d total\n", e, t }'
```

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر | المتوقع |
|---|---|---|
| مفيش traffic | شغّل `canary.sh` من غير probe | بعد `2 × STEP_SECONDS`: `ABORT: no traffic reached the canary` (exit 2) |
| `/metrics` بـ token | حط `METRICS_TOKEN` في SSM → render → canary سليم | الـ gate شغال عادي (بيقرا الـ token من `app.env`)، و `curl 127.0.0.1:8082/metrics` من غير header = 403 |
| Token غلط (و `app.env` فيه token) | `METRICS_TOKEN=wrong bash bin/canary.sh student-app:v2` (الـ shell بيكسب على `app.env` في الـ gate بس؛ الـ slots بتاخد الـ token الحقيقي من `app.env`) | الـ scrape بيرجع 403 → `0 0` → `ABORT: no traffic reached the canary` (exit 2) — gate أعمى بيعمل abort، مش promote |
| Latency بس | `SLOT_ENV="SRE_FAULT_LATENCY_MS=800" ... canary.sh` | **promoted!** الـ gate بيبص على 5xx بس. تمرين: زوّد الـ gate بنسبة `le="0.3"` من `student_app_http_request_duration_seconds_bucket` (الـ latency SLO 95% < 300ms) |
| حد صارم جداً | `MAX_ERROR_RATE=0` مع traffic قليل | أي 500 عشوائي واحد = abort (false positive) |
| `/ready` كـ traffic | الـ probe على `/ready` بدل `/login` | الـ gate يشوف `total=0` (مستبعد) → abort "no traffic" |

## 9) الرجوع (Rollback)

- **أثناء الـ canary:** الـ abort أوتوماتيك (exit 2). لو اتقطع يدوي (Ctrl+C): `bash bin/rollback.sh` — `MODE=canary` → 100% يرجع للـ stable والـ canary slot بيفضل شغال.
- **بعد الـ promote:** `MODE=single` والـ stable القديم شغال → `bash bin/rollback.sh` بيقلب للونه فوراً ([23 §9](23-bluegreen-single-host.md)).
- الـ migrations اتعملت قبل أول خطوة ومش بترجع — نفس شرط الـ backward compatibility، ومع الـ canary أهم لأن الإصدارين بيخدموا traffic **في نفس الوقت** لدقايق.

## 10) المسح (Teardown) ⚠️

مفيش موارد جديدة. اتأكد إن الـ state نضيف وامسح أي fault parameters:

```bash
cd /opt/student-app/src/deploy/ec2/lb && bash bin/status.sh
: > state/blue.env; : > state/green.env       # SLOT_ENV extras (بتتصفّر لوحدها مع أي deploy للـ slot)
```

## 11) التكلفة (Cost)

| Resource | السعر التقريبي |
|---|---|
| نفس host سيناريو 20 | ~$0.65/يوم |
| الـ traffic الصناعي على localhost | مجاني (بيضيف rows في جدول `sessions` لأن كل GET على `/login` من غير cookie = session جديدة) |

## 12) أسئلة Interview

<details><summary>الـ canary اتعمله promote بـ 0 errors في 10 requests عند 10% — ده كافي؟</summary>

لأ. بقاعدة الـ "rule of three": 0 أحداث في n محاولة معناها إن الحد الأعلى للـ error rate بثقة 95% ≈ 3/n = 30%. عشان تقول إن الـ error rate أقل من 1% بثقة معقولة محتاج مئات الـ requests لكل خطوة. يعني الـ gate عندنا بيمسك الأعطال الكبيرة (50%) بس. الحلول: خطوات أطول، traffic أكتر (أو synthetic)، ومقارنة الـ canary بالـ baseline بدل threshold مطلق.

</details>

<details><summary>ليه تقارن الـ canary بالـ stable بدل threshold ثابت؟</summary>

لأن مشكلة عامة (الداتابيز بطيئة، dependency واقعة) بتأثر على الاتنين، فالـ threshold المطلق هيعمل abort لإصدار سليم، أو العكس: baseline بيرجع 0.5% أصلاً فـ 1% مش إشارة. Kayenta و Argo Rollouts analysis بيقارنوا canary بـ baseline (والأحسن baseline جديد بنفس عمر الـ canary عشان الـ cold caches).

</details>

<details><summary>إيه مشكلة الـ canary من غير sticky sessions في تطبيق web؟</summary>

نفس المستخدم ممكن يتنقل بين الإصدارين request بـ request: UI بيتغير، و **asset skew** — صفحة HTML من الإصدار الجديد بتطلب `/build/assets/app-<hash>.js` والـ request ده يروح للـ stable اللي معندوش الملف → 404 (وده 4xx فمش هيبان في الـ gate). الحلول: assets على S3/CDN بالإصدارين، أو sticky routing (cookie)، أو الإصدار الجديد يشيل الـ assets القديمة كمان.

</details>

<details><summary>قارن `canary.sh` بـ Argo Rollouts و CodeDeploy و ECS.</summary>

`canary.sh`: weights في nginx، gate على 5xx من `/metrics` الـ canary، abort بـ exit 2 — تعليمي وبسيط. Argo Rollouts: steps (`setWeight`/`pause`) + AnalysisTemplate (Prometheus queries) + abort/undo، والـ traffic split بالـ replicas أو ingress/mesh. CodeDeploy (ECS): canary/linear configs (مثلاً 10% لمدة 5 دقايق) مع CloudWatch alarms → rollback أوتوماتيك. ECS native deployments كمان بقى فيها canary/linear بـ bake time و alarms. ALB weighted target groups + alarm في [46](46-canary-weighted-target-groups.md). المبدأ واحد: نسبة صغيرة → قياس → قرار أوتوماتيك.

</details>

<details><summary>إيه الـ metrics اللي تحطها في gate حقيقي؟</summary>

الـ golden signals على الـ canary مقابل الـ baseline: error rate (5xx على app routes)، latency (p95/p99 أو نسبة تحت الـ SLO threshold)، saturation (CPU/memory/restarts)، وbusiness metrics (logins ناجحة، orders). ويتحسب بالـ burn rate بالنسبة للـ SLO مش بأرقام عشوائية.

</details>

<details><summary>الـ migrations في canary أصعب من blue/green ليه؟</summary>

في blue/green الإصدارين بيشتغلوا مع بعض لحظات (والقديم idle بعدها). في canary الاتنين بيخدموا traffic حقيقي على نفس الـ schema لدقايق أو ساعات، فالـ data اللي الجديد بيكتبها لازم القديم يقراها والعكس (مثلاً enum values جديدة). يعني expand/contract إجباري، والـ contract بعد ما الـ canary يخلص والـ rollback window يقفل.

</details>

## 13) Checklist

- [ ] اتأكدت إن `/metrics` بيرد على 8081/8082 (بالـ Bearer token لو `METRICS_TOKEN` متحدد)
- [ ] عملت canary سليم مع traffic على `/login` واتعمله promote بـ 0 failures
- [ ] عملت تمرين الـ bad release وشفت exit 2 من الطريقين (pre-traffic abort و metric-gate abort)
- [ ] جرّبت حالة "مفيش traffic" و fault الـ latency وفهمت حدود الـ gate
- [ ] قريت الـ canary steps في `lab-integration.yml`
- [ ] أقدر أشرح الـ rule of three وليه المقارنة بالـ baseline أحسن
