# 26 — A/B testing و Shadow traffic و Feature flags

> **الهدف في سطر:** تفرّق بين 3 أدوات بتفصل الـ deploy عن الـ release: **A/B** (`ab-test.sh`: تقسيم مستخدمين sticky بـ `split_clients` + header + cookie)، **Shadow** (`shadow.sh`: nginx `mirror` لـ GET بس والردود بتترمي)، و **Feature flags** (مفهوم + مثال Laravel Pennant كتمرين اختياري).
> **المستوى:** Intermediate → Advanced · **الوقت:** ~3 ساعات · **التكلفة التقريبية:** نفس [20](20-ec2-compose-console.md)
> **بيعتمد على:** [23](23-bluegreen-single-host.md) · [24 — Canary](24-canary-single-host.md) · **الملفات في الـ repo:** [`deploy/ec2/lb/bin/ab-test.sh`](../../../deploy/ec2/lb/bin/ab-test.sh) · [`deploy/ec2/lb/bin/shadow.sh`](../../../deploy/ec2/lb/bin/shadow.sh) · [`deploy/ec2/lb/bin/lib.sh`](../../../deploy/ec2/lb/bin/lib.sh) · [`deploy/scripts/version-split.sh`](../../../deploy/scripts/version-split.sh) · [`config/sre_lab.php`](../../../config/sre_lab.php)

## 1) الفكرة (Concepts)

| | Canary ([24](24-canary-single-host.md)) | A/B testing | Shadow (mirroring) | Feature flag |
|---|---|---|---|---|
| بيقسّم إيه | **requests** عشوائية | **مستخدمين** (sticky) | نسخة من كل request | منطق جوه الكود |
| المستخدم بيشوف الجديد؟ | أيوه (نسبة) | أيوه (مجموعة ثابتة) | **لأ أبداً** | حسب الـ flag |
| السؤال | "الإصدار سليم؟" (تشغيلي) | "النسخة دي أحسن؟" (منتج) | "الجديد بيستحمل الـ traffic الحقيقي؟" | "نشغّل الـ feature لمين وإمتى؟" |
| الحكم | error rate / latency | conversion / business KPIs | مقارنة metrics و logs | أي حاجة |
| محتاج deploy عشان يتغير؟ | لأ (weights) | لأ (maps) | لأ | **لأ** (runtime) |

الفكرة المشتركة: **Deploy ≠ Release**. الكود يوصل الـ production مقفول أو مخفي، والـ "release" قرار منفصل وقابل للرجوع في ثواني.

## 2) المعمارية (Architecture)

```text
 A/B  (ab-test.sh <image> 20)
   request ─► map $http_x_variant  (X-Variant: green|blue — QA/forced)
                 └─ default ─► map $cookie_ab_variant (sticky)
                                  └─ "" ─► split_clients "${remote_addr}${http_user_agent}" 20% → variant
           ─► proxy_pass http://$ab_upstream  (app_<color>_only)
           ◄─ add_header X-Variant <color> + Set-Cookie ab_variant=<color>; Max-Age=86400

 Shadow  (shadow.sh <image>)
   request ─► location / { mirror /__shadow; proxy_pass http://app_main; } ─► LIVE ─► user
                    └─► /__shadow (internal): GET/HEAD فقط، غير كده return 204
                          proxy_pass http://app_<shadow>_only$request_uri  (timeouts 1s/3s)
                          header X-Shadow-Request: 1   ← الرد بيترمي

 Feature flag  (Pennant — تمرين)
   request ─► code: Feature::active('new-renewal-flow') ─► old path | new path
```

## 3) المتطلبات (Prerequisites)

- [ ] ستاك `deploy/ec2/lb` شغال ([23](23-bluegreen-single-host.md)) أو هتشغّل على GitHub Actions.
- [ ] release جديد مبني (`student-app:v2`).
- [ ] للـ feature flags: نسخة محلية من الكود + PHP (Laragon أو WSL) — **Pennant مش متثبت في الـ repo**.

## 4) الطريقة الأولى: AWS Console (يدوي)

على السيرفر الواحد مفيش موارد جديدة. المقابل الـ managed في AWS (للمعرفة وللتجربة الاختيارية):

1. **A/B على ALB:** listener rule بـ **Forward to target groups** بوزنين + **Group-level stickiness** (مدة الـ stickiness) — نفس فكرة الـ cookie هنا. (سيناريو [46](46-canary-weighted-target-groups.md) بيبني الـ weighted target groups.)
2. **Feature flags managed — AWS AppConfig (اختياري):**
   - **AWS AppConfig → Create application** → Name `student-app`.
   - **Create configuration profile → Feature flag** → Name `student-app-flags` → **Add new flag** `new-renewal-flow` (off) → **Save new version**.
   - **Environments → Create environment** `lab` → **Start deployment** → اختار profile و version و deployment strategy (مثلاً `AppConfig.AllAtOnce` للتجربة، أو `AppConfig.Linear50PercentEvery30Seconds`) — ممكن تربط CloudWatch alarm يعمل rollback للـ config نفسها.
   - التكلفة بالـ config requests (صغيرة — راجع صفحة الأسعار). امسح الـ application بعد التجربة.

> 💡 الـ feature flag "managed" بيديك audit و rollback و validators. الـ flag اللي في الداتابيز (Pennant) أبسط ومجاني. الـ flag اللي في env (زي `SRE_LAB_ENABLED`) محتاج recreate للـ container عشان الـ config cache.

## 5) الطريقة التانية: as Code

### 5.1 `ab-test.sh <image> [percent] | stop`

1. `load_state` → `STABLE=$ACTIVE`، `VARIANT=$(other STABLE)`.
2. `stop`: `render_single STABLE` → reload → `MODE=single` → خلاص.
3. غير كده: `PERCENT` (افتراضي `20`) → **`ensure_single_live`** → `set_image VARIANT` → `MODE=ab` → `start_slot VARIANT` (pull → migrate → recreate → ready → smoke). لو الـ variant فشل في أي خطوة: `MODE=single` يترجع ويتحفظ، والسكريبت يقف بـ `variant failed its checks - traffic unchanged on <stable>` (الـ nginx لسه single على الـ stable).
4. `render_single STABLE` (عشان `upstreams.conf`؛ الـ upstreams `app_blue_only`/`app_green_only` دايماً متعرّفة) ثم يكتب `maps.conf` و `routing.conf` (شوف المعمارية) → `reload_proxy`.

الأولوية: **header `X-Variant`** (للـ QA والـ internal testers) ← **cookie `ab_variant`** (sticky) ← **`split_clients`** (hash على `remote_addr + user_agent`). كل رد بيرجع `X-Variant: <color>` و `Set-Cookie: ab_variant=<color>; Path=/; Max-Age=86400; SameSite=Lax`.

> ⚠️ نقاط Senior:
> - **الـ hash على `remote_addr`**: من نفس الجهاز (نفس IP و UA) كل الـ requests بتروح لنفس المجموعة — `version-split.sh` من السيرفر هيوريك 100% لواحد. ولو nginx ده ورا ALB، `remote_addr` = IP الـ ALB → كل الناس في bucket واحد لحد ما تضبط `real_ip`.
> - **أسماء الـ variants = ألوان infra** (`blue`/`green`). بعد blue/green deploy معنى الألوان بيتبدل، والـ cookie (يوم كامل) ممكن يشاور على إصدار تاني في تجربة جاية. في نظام حقيقي: اسم التجربة والـ variant (`exp42=B`) مش اسم الـ slot.
> - **A/B مش safety mechanism**: مفيش gate. لو الـ variant بايظ، الـ 20% دول هيفضلوا شايفينه (sticky) لحد ما توقفه.
> - الـ `state/<color>.env` و `SLOT_ENV` بيشتغلوا هنا زي باقي السكريبتات.

### 5.2 `shadow.sh <image> | stop`

1. `load_state` → `LIVE=$ACTIVE`، `SHADOW=$(other LIVE)`.
2. `stop`: `render_single LIVE` → reload → `MODE=single`.
3. غير كده: **`ensure_single_live`** → `set_image SHADOW` → `MODE=shadow` → `start_slot SHADOW` → `render_single LIVE` → `routing.conf` بالـ `mirror` → reload. لو الـ shadow release فشل قبل الـ mirror: `MODE=single` و die بـ `shadow release failed its checks - traffic unchanged on <live>`.

```nginx
location / {
    mirror /__shadow;
    mirror_request_body off;
    proxy_pass http://app_main;
}
location = /__shadow {
    internal;
    if ($request_method !~ ^(GET|HEAD)$) { return 204; }
    proxy_set_header X-Shadow-Request "1";
    proxy_connect_timeout 1s;
    proxy_read_timeout 3s;
    proxy_pass http://app_<shadow>_only$request_uri;
}
```

- **الردود بتترمي**: المستخدم دايماً بيتخدم من الـ LIVE.
- **GET/HEAD بس** لأن الداتابيز مشتركة: POST/PUT/DELETE كانت هتتنفذ مرتين (طالب يتسجل مرتين، تجديد مرتين).
- `mirror_request_body off` لأننا مش بنعمل mirror لأي body أصلاً.
- الـ timeouts القصيرة (1s/3s) مهمة: في nginx الـ request الأصلي مبيخلصش تماماً (من ناحية الـ connection) غير لما الـ mirror subrequests تخلص، فـ shadow بطيء ممكن يأثر على الـ client (مثلاً الـ request الجاي على نفس الـ keepalive connection).

> ⚠️ **GET مش دايماً side-effect free** — في التطبيق ده بالذات:
> - `SESSION_DRIVER=database`: الـ mirror بينسخ الـ headers ومنها الـ **Cookie**، فالـ shadow بيفتح **نفس الـ session** (نفس `APP_KEY`) ويكتبها في آخر الـ request → ممكن يسابق الـ live على نفس الـ row (مثلاً يستهلك flash messages).
> - `GET /students` و `GET /dashboard` عليهم middleware `sync.notifications` اللي بينادي `NotificationSyncService::syncFor()` → **بيكتب في الداتابيز** (`users.notified_on` + `RenewalDueNotification`). الـ atomic claim بيمنع التكرار، بس ممكن الـ **shadow** هو اللي يكسب الـ claim ويعمل الـ write بكوده الجديد بدل الـ live.
>
> عشان كده الـ shadow "الحقيقي" بيروح لبيئة معزولة (نسخة داتابيز، writes متعطّلة، أو stubs). تمرين: ضيف `proxy_set_header Cookie "";` جوه `/__shadow` في نسخة تجريبية — الـ shadow هيبقى anonymous (الصفحات المحمية هتعمل redirect للـ login) بس آمن.

### 5.3 Feature flags بـ Laravel Pennant (تمرين اختياري — مش متثبت)

```bash
composer require laravel/pennant
php artisan vendor:publish --provider="Laravel\Pennant\PennantServiceProvider"
php artisan migrate          # جدول features (الـ store الافتراضي database)
```

تعريف flag (في `AppServiceProvider::boot()`):

```php
use App\Models\User;
use Illuminate\Support\Lottery;
use Laravel\Pennant\Feature;

Feature::define('new-renewal-flow', fn (User $user) => match (true) {
    str_ends_with($user->email, '@example.com') => true,   // internal / QA
    default => Lottery::odds(1, 10),                       // 10% من الباقي
});
```

الاستخدام:

```php
if (Feature::active('new-renewal-flow')) {
    // المسار الجديد
}
```

```blade
@feature('new-renewal-flow')
    {{-- UI الجديد --}}
@else
    {{-- القديم --}}
@endfeature
```

Kill switch و rollout من غير deploy:

```bash
php artisan tinker --execute="Laravel\Pennant\Feature::deactivateForEveryone('new-renewal-flow');"   # kill switch
php artisan tinker --execute="Laravel\Pennant\Feature::activateForEveryone('new-renewal-flow');"     # release للكل
php artisan pennant:purge new-renewal-flow                                                          # امسح القيم المتخزنة (يعيد الحساب)
```

> 💡 Pennant بيخزّن القيمة المحسوبة لكل user (scope)، فالـ `Lottery` sticky تلقائياً — نفس فكرة الـ cookie في A/B بس على مستوى الكود. ومع الـ container setup: الـ store `database` بيخلّي التغيير فوري لكل الـ replicas؛ لو استخدمت الـ `array` driver كل container هيقرر لوحده.

أنواع الـ flags وإدارتها:

| النوع | مثال | عمره |
|---|---|---|
| Release flag | `new-renewal-flow` (dark launch → rollout تدريجي) | أيام/أسابيع — امسحه بعد 100% |
| Ops / kill switch | `SRE_LAB_ENABLED` في [`config/sre_lab.php`](../../../config/sre_lab.php) (master kill-switch للـ endpoints والـ faults) | دائم |
| Experiment | variant لـ A/B | لحد ما التجربة تخلص |
| Permission | feature لـ plan معين | دائم |

**Dark launch:** الكود الجديد يتعمله deploy مقفول (flag off)، وممكن يتنفذ في الخلفية من غير ما يأثر على الـ response (shadow جوه الكود)، وبعدين تفتحه تدريجياً. **Flag debt:** كل flag = فرع زيادة في الكود والـ tests؛ حط owner وتاريخ انتهاء وامسحه.

## 6) الـ Deploy

### 6.1 A/B على EC2

```bash
cd /opt/student-app/src/deploy/ec2/lb
SKIP_PULL=true bash bin/ab-test.sh student-app:v2 30
source state/release.env; VARIANT=$([ "$ACTIVE" = blue ] && echo green || echo blue); echo "stable=$ACTIVE variant=$VARIANT"

curl -s -D - -o /dev/null http://127.0.0.1/ready | grep -i -E 'x-variant|set-cookie: ab_variant'
curl -s -H "X-Variant: $VARIANT" http://127.0.0.1/ready | jq -r .color      # forced
curl -s -b "ab_variant=$ACTIVE"   http://127.0.0.1/ready | jq -r .color      # sticky cookie
# شوف التقسيم الحقيقي: غيّر الـ User-Agent عشان الـ hash يتغير
for i in $(seq 1 200); do curl -s -A "user-$i" http://127.0.0.1/ready | jq -r .color; done | sort | uniq -c
bash bin/ab-test.sh stop
```

### 6.2 Shadow على EC2

```bash
cd /opt/student-app/src/deploy/ec2/lb
SKIP_PULL=true bash bin/shadow.sh student-app:v2
source state/release.env; SHADOW=$([ "$ACTIVE" = blue ] && echo green || echo blue)
PORT=$([ "$SHADOW" = blue ] && echo 8081 || echo 8082)
count() { curl -fsS "http://127.0.0.1:$PORT/metrics" | awk '/http_requests_total\{method="GET",route="health.ready"/ {s+=$NF} END {print s+0}'; }
before=$(count); for i in $(seq 1 20); do curl -fsS http://127.0.0.1/ready >/dev/null; done; sleep 2; after=$(count)
echo "shadow saw $((after - before)) mirrored GETs"
curl -s -X POST -o /dev/null -w '%{http_code}\n' http://127.0.0.1/login       # الـ POST مش بيتعمله mirror
bash bin/shadow.sh stop
```

قارن الـ live بالـ shadow:

```bash
for p in 8081 8082; do echo "== $p"; curl -s http://127.0.0.1:$p/metrics | grep -E '^student_app_http_requests_total' | sort | head -15; done
```

### 6.3 على GitHub Actions

الـ job **Zero-downtime scripts** في [`lab-integration.yml`](../../../.github/workflows/lab-integration.yml):

- **A/B test (forced header + sticky cookie):** `ab-test.sh student-app:ci-v2 30` ← header `X-Variant: <variant>` لازم يرجّع لون الـ variant ← cookie `ab_variant=<stable>` لازم يرجّع الـ stable ← الرد لازم فيه `set-cookie: ab_variant=` ← `version-split.sh` (للعرض) ← `ab-test.sh stop`.
- **Shadow traffic:** `shadow.sh student-app:ci-v2` ← 20 GET على `/ready` عبر الـ proxy كلهم لازم يتخدموا من الـ live ← عدّاد `health.ready` على الـ shadow slot لازم زاد **≥ 15** ← `shadow.sh stop`.

## 7) التحقق (Verify)

```bash
cd /opt/student-app/src/deploy/ec2/lb
bash bin/status.sh                 # بيطبع maps.conf لو A/B شغال
cat state/nginx/maps.conf
cat state/nginx/routing.conf
docker compose -f docker-compose.yml --env-file state/release.env logs proxy --tail=20    # up=<ip:port> بيوضح مين خدم
```

المفروض: في A/B الـ `X-Variant` و الـ cookie موجودين في كل رد؛ في shadow الـ `color` في الردود دايماً الـ live، وعدّادات الـ shadow بتزيد مع الـ GETs بس.

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر | المتوقع |
|---|---|---|
| Shadow لإصدار بايظ | `SLOT_ENV="SRE_FAULT_ERROR_RATE=1" SKIP_PULL=true bash bin/shadow.sh student-app:v2` + traffic على `/login` بـ `probe.sh` | الـ probe = **0 failures** (المستخدم مش شايف)، وعدّادات الـ shadow مليانة `status="500"` — ده قيمة الـ shadow |
| Shadow بطيء | `SLOT_ENV="SRE_FAULT_LATENCY_MS=5000" ... shadow.sh` + قيس latency `/login` عبر الـ proxy | الـ mirror بيعمل timeout بعد 3s؛ قيس هل الـ client اتأثر (اقرا `rt=` في logs الـ proxy) |
| A/B لـ variant بايظ | `SLOT_ENV="SRE_FAULT_ERROR_RATE=0.5" ... ab-test.sh student-app:v2 20` | ~20% من المستخدمين (بالـ hash) بيشوفوا errors **باستمرار** — A/B مش canary |
| `rollback.sh` أثناء A/B | `bash bin/rollback.sh` وانت في `MODE=ab` | `experiment cancelled: 100% on <stable>` — نفس أثر `ab-test.sh stop` (الـ variant slot بيفضل شغال للتحقيق) |
| Variant مش بيقوم | `SLOT_ENV="SRE_FAULT_BOOT_FAIL=true" SKIP_PULL=true bash bin/ab-test.sh student-app:v2 20` | بيقع في الـ migrate ← `variant failed its checks - traffic unchanged on <stable>`، و `MODE=single` |

## 9) الرجوع (Rollback)

```bash
cd /opt/student-app/src/deploy/ec2/lb
bash bin/ab-test.sh stop          # 100% على الـ stable، MODE=single
bash bin/shadow.sh stop           # يوقف الـ mirroring
bash bin/rollback.sh              # بديل عام: MODE=ab|shadow → 100% على ACTIVE و MODE=single
```

- `rollback.sh` mode-aware: في `MODE=ab` أو `shadow` (أو canary اتقطع) بيلغي التجربة ويرجّع 100% للـ `ACTIVE` بعد ما يتأكد إنه ready ([23 §9](23-bluegreen-single-host.md)).
- الـ variant/shadow slot بيفضل شغال (مش بيتوقف) — أي deploy جاي هيستبدله.
- الـ cookies اللي اتوزعت بتفضل في المتصفحات يوم، بس الـ routing الافتراضي مش بيقراها.
- Feature flag: `Feature::deactivateForEveryone('new-renewal-flow')` — من غير deploy ولا restart.

## 10) المسح (Teardown) ⚠️

```bash
cd /opt/student-app/src/deploy/ec2/lb && bash bin/status.sh     # MODE=single و maps.conf فاضي
```

لو جرّبت AppConfig: **AWS AppConfig → Applications → student-app** → امسح الـ environment والـ configuration profile والـ application. ولو جرّبت Pennant محلياً: `git checkout composer.json composer.lock` (أو اعمله في branch منفصل).

## 11) التكلفة (Cost)

| Resource | السعر التقريبي (راجع صفحة الأسعار) |
|---|---|
| نفس host سيناريو 20 | ~$0.65/يوم |
| AWS AppConfig (اختياري) | بالـ configuration requests — سنتات في المعمل |
| Laravel Pennant | مجاني (جدول في نفس الداتابيز) |

## 12) أسئلة Interview

<details><summary>الفرق بين canary و A/B testing؟</summary>

Canary: أداة **تشغيلية** — requests عشوائية، هدفها كشف الأعطال بسرعة، الحكم بالـ error rate/latency، والقرار أوتوماتيك (promote/abort) في دقايق. A/B: أداة **منتج** — مستخدمين ثابتين في كل variant (sticky) عشان التجربة متتلخبطش، الحكم بـ business metrics وبـ statistical significance، والمدة أيام أو أسابيع. ممكن تعمل الاتنين: canary للإصدار، وجوه الإصدار feature flag للتجربة.

</details>

<details><summary>إمتى تستخدم shadow traffic وإيه مخاطره؟</summary>

لما عايز تختبر الإصدار الجديد (أو rewrite، أو DB جديدة) تحت traffic حقيقي بشكله وحجمه من غير أي أثر على المستخدم: performance، errors، مقارنة الردود. المخاطر: الـ side effects (writes مضاعفة، emails، payments، sessions)، الحمل المضاعف على dependencies مشتركة، والـ PII في بيئة الاختبار. عشان كده: read-only أو بيئة معزولة، stubs للـ external calls، وtimeouts قصيرة.

</details>

<details><summary>ليه الـ feature flags بتعتبر deployment strategy؟</summary>

لأنها بتفصل الـ deploy (حركة كود) عن الـ release (تعرّض المستخدم). فبتقدر تعمل deploy كتير وبأمان (trunk-based)، تعمل dark launch، rollout تدريجي لكل user أو نسبة، و kill switch في ثانية من غير rollback للكود. التمن: complexity في الكود والـ testing (combinations)، و flag debt لو متمسحتش.

</details>

<details><summary>إزاي تضمن إن الـ A/B split عادل؟</summary>

hash ثابت على identity مستقرة (user id أحسن من IP+UA)، sticky assignment، وتتأكد من الـ **sample ratio** (لو المفروض 20/80 وطلع 30/70 يبقى فيه bug في الـ assignment — SRM). كمان تستبعد الـ bots والـ internal traffic، وتحدد الـ sample size والمدة قبل ما تبدأ (مش تبص كل ساعة وتوقف لما يعجبك الرقم).

</details>

<details><summary>Kill switch في env variable مقابل Pennant مقابل AppConfig؟</summary>

Env (زي `SRE_LAB_ENABLED`): بسيط ومش محتاج dependencies، بس التغيير = render + recreate لكل container (والـ config cached عند الـ boot). Pennant (database): runtime، per-user، مجاني، بس من غير audit/approvals built-in. AppConfig/LaunchDarkly: runtime + deployment strategies للـ config نفسها + validators + rollback بالـ alarms + audit، مقابل تكلفة و dependency خارجية.

</details>

<details><summary>إيه مشكلة استخدام أسماء الـ slots (blue/green) كـ variant names؟</summary>

الألوان بتعبّر عن infra (مين الـ live دلوقتي) ومعناها بيتبدّل مع كل deploy، بينما الـ experiment محتاج identity ثابتة طول مدته. لو cookie عمرها يوم بتقول `green` وحصل switch، المستخدم ممكن يتحط في إصدار تاني من غير ما حد يقصد. افصل الـ experiment assignment (في الكود أو flag service) عن الـ infra routing.

</details>

## 13) Checklist

- [ ] شغّلت A/B وجرّبت الـ header والـ cookie وشفت التقسيم بتغيير الـ User-Agent
- [ ] شغّلت shadow واتأكدت إن المستخدم مش بيتأثر وإن الـ POST مش بيتعمله mirror
- [ ] فهمت ليه GET مش دايماً آمن في التطبيق ده (sessions، `sync.notifications`)
- [ ] جرّبت Pennant محلياً في branch (اختياري) و kill switch
- [ ] قريت steps الـ A/B و shadow في `lab-integration.yml`
- [ ] رجّعت لـ `MODE=single` بـ `stop`
