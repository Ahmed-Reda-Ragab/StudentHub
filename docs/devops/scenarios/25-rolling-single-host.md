# 25 — Rolling update بأكتر من replica (single host)

> **الهدف في سطر:** تشغّل `rolling.sh` في **pool mode** (الـ slotين بيخدموا traffic)، وتفهم الـ `down` + drain في nginx، وحساب الـ capacity (N-1)، وليه الـ migrations بتجري مرة واحدة مع أول slot — وتقارنه بـ ASG instance refresh و ECS و Kubernetes `maxSurge/maxUnavailable`.
> **المستوى:** Intermediate · **الوقت:** ~2 ساعة · **التكلفة التقريبية:** نفس [20](20-ec2-compose-console.md)
> **بيعتمد على:** [23 — Blue/Green على سيرفر واحد](23-bluegreen-single-host.md) · **الملفات في الـ repo:** [`deploy/ec2/lb/bin/rolling.sh`](../../../deploy/ec2/lb/bin/rolling.sh) · [`deploy/ec2/lb/bin/lib.sh`](../../../deploy/ec2/lb/bin/lib.sh) · [`deploy/ec2/lb/nginx/nginx.conf`](../../../deploy/ec2/lb/nginx/nginx.conf)

## 1) الفكرة (Concepts)

**Rolling** = عندك N replicas بيخدموا كلهم، بتبدّلهم **واحد واحد**: تشيله من الـ load balancer → تستنى الـ requests تخلص (drain) → تبدّله بالإصدار الجديد → health check → ترجّعه. الـ capacity عمرها ما بتوصل صفر، ومش محتاج ضعف الموارد زي blue/green.

| المصطلح | المعنى |
|---|---|
| Pool mode | كل الـ slots في الـ upstream وبياخدوا traffic |
| `down` | علامة في nginx upstream: متبعتش requests جديدة للـ server ده |
| Drain | وقت الانتظار عشان الـ in-flight requests تخلص قبل الإيقاف |
| maxUnavailable | كام replica ممكن يبقوا بره الخدمة في نفس الوقت (هنا 1) |
| maxSurge | كام replica زيادة ممكن تتعمل مؤقتاً (هنا 0 — البورتات ثابتة) |
| Mixed-version window | الفترة اللي الإصدارين بيخدموا فيها مع بعض |

| | Recreate | Blue/Green | Rolling | Canary |
|---|---|---|---|---|
| Downtime | فيه | لأ | لأ | لأ |
| موارد زيادة | لأ | 2× | 0 (أو surge) | قليل |
| الإصدارين مع بعض | لأ | لحظة | **أيوه، طول الـ rollout** | أيوه، بنسب |
| Rollback | redeploy | فوري | rollout تاني | abort فوري |

## 2) المعمارية (Architecture)

```text
 Pool:  upstream app_main { server app_blue:8080 resolve;  server app_green:8080 resolve; }

 الخطوة 1 (blue):  app_blue:8080 resolve down; │ app_green ← 100% traffic
                   drain DRAIN_SECONDS → migrate (مرة واحدة) → recreate blue (v2) → ready → smoke
                   upstream: blue up + green up        (v2 + v1 بيخدموا مع بعض)
 الخطوة 2 (green): app_green:8080 resolve down; │ app_blue (v2) ← 100%
                   drain → recreate green (v2, SKIP_MIGRATE) → ready → smoke
                   upstream: blue up + green up        (v2 + v2)

 capacity أثناء كل خطوة = (N-1)/N = 50% مع slotين
```

## 3) المتطلبات (Prerequisites)

- [ ] ستاك `deploy/ec2/lb` شغال ([23](23-bluegreen-single-host.md)) أو هتشغّل على GitHub Actions.
- [ ] release جديد مبني (`student-app:v2`).
- [ ] الـ instance فيه RAM لـ slotين شغالين دايماً (`free -h`؛ `t3.medium` لو ضاقت).

## 4) الطريقة الأولى: AWS Console (يدوي)

مفيش موارد جديدة. الـ rolling الحقيقي محتاج **أكتر من instance** — ده اللي هتعمله بـ ASG Instance Refresh في [44](44-rolling-instance-refresh.md). هنا بنحاكيه بـ slotين على نفس الـ host. من الـ Console:

1. **CloudWatch → Metrics → EC2 → CPUUtilization** للـ instance وقت الـ rolling — لاحظ إن الـ slot الباقي شايل الـ load كله في كل خطوة.
2. فكّر في الـ capacity: لو الـ peak محتاج slotين كاملين، الـ rolling بـ `maxUnavailable=1` هيعمل overload. الحل في الـ cloud: **surge** (instance زيادة الأول) — `MaxHealthyPercentage` > 100 في الـ instance refresh.

## 5) الطريقة التانية: as Code — `rolling.sh` من جوه

| Env | الافتراضي | المعنى |
|---|---|---|
| `DRAIN_SECONDS` | `3` | انتظار بعد ما الـ slot يتعلّم `down` |
| `SLOT_ENV` | — | لاحظ: هنا بيتطبّق على **كل** slot بيتعمله start (الاتنين) |
| + knobs `lib.sh` | | `SKIP_PULL`، `READY_TIMEOUT`، `SKIP_MIGRATE`... |

الـ flow:

1. `load_state` → **`ensure_single_live`** (لو `MODE` مش `single` بيتأكد إن الـ `ACTIVE` ready ويرجّعله 100%؛ لو الـ live مش ready بيرفض يكمّل) → `LIVE_IMAGE = image_of ACTIVE`.
2. **تجهيز الـ pool:** أي slot **مش شغال أو الـ image بتاعته مختلفة عن `LIVE_IMAGE`** (مثلاً idle فاضل عليه إصدار أقدم من blue/green قديم) بيتعمله (re)start بالـ live image بـ `SKIP_MIGRATE=true` — **قبل** ما يدخل الـ pool. لو فشل: die و الـ traffic زي ما هو على `ACTIVE`. كده عمر ما slot قديم/بايظ يدخل الـ pool.
3. `PREVIOUS_IMAGE = LIVE_IMAGE` → `render_pool "blue:up green:up"` → `reload_proxy` → `MODE=rolling` → `save_state`.
4. لكل `color` في `(blue green)`:
   - `render_pool "<color>:down <peer>:up"` → `reload_proxy` → nginx بيبطّل يبعت requests جديدة للـ slot (الـ workers القديمة بتكمّل اللي معاها).
   - `sleep DRAIN_SECONDS`.
   - `set_image color IMAGE` → `save_state`.
   - **أول slot:** `start_slot` بالـ migrate (إلا لو أنت مدّي `SKIP_MIGRATE=true`). **التاني:** دايماً `SKIP_MIGRATE=true`.
     (`start_slot` بيعمل `--force-recreate` → الـ container القديم بياخد `SIGQUIT` ويخلّص الـ requests لحد 30s.)
   - **لو `start_slot` فشل:** الـ peer (لسه على الإصدار القديم) ياخد 100% (`render_single peer`) → `ACTIVE=peer`، `MODE=single` → die: `rolling update stopped; live=<peer> ...`.
   - غير كده: `render_pool "blue:up green:up"` → `reload_proxy`.
5. في الآخر: `ACTIVE=blue` → `save_state` (الـ `MODE` بيفضل `rolling` و `PREVIOUS_IMAGE` = الإصدار اللي اتبدّل — ده هدف الـ rollback).

> 💡 ليه الـ drain على مرحلتين؟ `down` في nginx بيمنع الـ **requests الجديدة**، و `SIGQUIT` + `stop_grace_period` بيخلي الـ FPM يكمّل الـ **in-flight**. في Kubernetes نفس الفكرة: الـ pod بيتشال من الـ Endpoints، و `preStop: sleep 10` بيدّي وقت للـ kube-proxy/LB يعرفوا قبل الـ SIGTERM ([66](66-k8s-rolling-recreate.md)).

### الـ capacity math

مع N slots و `maxUnavailable=1`: الـ capacity أثناء كل خطوة = `(N-1)/N`.

| N | أثناء الخطوة | ملاحظة |
|---|---|---|
| 2 (عندنا) | 50% | لازم الـ peak يتشال بـ slot واحد |
| 4 | 75% | |
| 10 | 90% | rollout أطول (10 خطوات) |

القاعدة: `(N - maxUnavailable) × capacity_per_replica ≥ peak load` — وإلا استخدم `maxSurge` (تعمل الجديد قبل ما تشيل القديم) أو اعمل الـ deploy بره الـ peak.

### الـ migrations مرة واحدة

الـ migrate بيجري مع **أول slot جديد**، والـ peer لسه على الكود القديم وبيخدم 100% → الـ schema الجديد لازم يشتغل مع الكود القديم. وبعد ما الـ slot الأول يرجع الـ pool، الإصدارين بيخدموا requests عشوائية لنفس المستخدمين → نفس شروط [24](24-canary-single-host.md) و [95](95-zero-downtime-db-migrations.md).

## 6) الـ Deploy

على EC2:

```bash
# Terminal على جهازك
bash deploy/scripts/probe.sh http://<ELASTIC_IP>/ready 120 0.1

# Terminal على السيرفر
cd /opt/student-app/src/deploy/ec2/lb
DRAIN_SECONDS=5 SKIP_PULL=true bash ../../scripts/with-probe.sh -- bash bin/rolling.sh student-app:v2
bash bin/status.sh
```

على GitHub Actions ([`lab-integration.yml`](../../../.github/workflows/lab-integration.yml)) بعد خطوة الـ rollback (يعني الـ live = `ci-v1`):

```yaml
- name: Rolling ci-v1 → ci-v2 across both slots (0 failed requests)
  run: |
    bash $PROBE -- bash $LB/rolling.sh student-app:ci-v2
    curl -fsS http://127.0.0.1:8081/ready | grep -q '"version":"ci-v2"'
    curl -fsS http://127.0.0.1:8082/ready | grep -q '"version":"ci-v2"'
```

## 7) التحقق (Verify)

```bash
cd /opt/student-app/src/deploy/ec2/lb
sed -n '/upstream app_main/,/}/p' state/nginx/upstreams.conf     # server-ين من غير down
cat state/release.env                                             # BLUE_IMAGE = GREEN_IMAGE = v2، MODE=rolling
for p in 8081 8082; do curl -s http://127.0.0.1:$p/ready | jq -c '{version,color}'; done
bash ../../scripts/version-split.sh http://127.0.0.1/ready 100    # ~50/50 بين blue و green، نفس الـ version
```

راقب الـ rollout لايف من terminal تالت:

```bash
watch -n 1 "sed -n '/upstream app_main/,/}/p' /opt/student-app/src/deploy/ec2/lb/state/nginx/upstreams.conf"
```

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر | المتوقع |
|---|---|---|
| Release فاشل في النص | `READY_TIMEOUT=30 SLOT_ENV="SRE_FAULT_UNHEALTHY=true" SKIP_PULL=true bash bin/rolling.sh student-app:v2` | `app_blue not ready` ← `app_blue failed with student-app:v2 — green takes 100% of traffic` ← die `rolling update stopped; live=green`. الـ probe = 0 failures، و `state/release.env`: `ACTIVE=green`، `MODE=single` |
| Slot قديم في الـ idle | `bluegreen.sh` لـ v2 ثم `rollback.sh` (الـ idle بقى عليه v2 والـ live v1) ثم `rolling.sh student-app:v3` | في خطوة التجهيز: `(re)starting app_<idle> with the live image ...` — الـ v2 القديم مش بيدخل الـ pool أبداً |
| Drain = 0 | `DRAIN_SECONDS=0` + requests طويلة عبر الـ proxy: `curl -H "X-Lab-Token: <TOKEN>" "http://127.0.0.1/sre-lab/latency?ms=5000"` في loop | قيس: هل فيه requests اتقطعت؟ (الـ `SIGQUIT` graceful المفروض يحميك) |
| Overload وقت الخطوة | load على `/sre-lab/cpu?ms=200` (بـ token) أثناء الـ rolling | الـ latency بتزيد لما slot واحد شايل الكل — ده الـ N-1 |
| Rollback بعد rolling ناجح | `bash ../../scripts/with-probe.sh -- bash bin/rollback.sh` | `pool mode: rolling both slots back to <PREVIOUS_IMAGE>` — rolling تاني للإصدار القديم بـ 0 failures |

> 💡 **بعد rolling فاشل في النص:** السكريبت نفسه عمل الـ "rollback": الـ peer السليم بقى `ACTIVE` بـ 100% و `MODE=single`، والـ slot اللي فشل اتعلّم `BROKEN`. صلّح الـ image وأعد `rolling.sh`. لو شغّلت `rollback.sh` هنا هيرفض بأمان ("nothing to roll back to") لأن اللون التاني متعلّم `BROKEN`.

## 9) الرجوع (Rollback)

بعد rolling ناجح الـ slotين على الإصدار الجديد و `MODE=rolling`. `rollback.sh` بيشوف ده ويعيد `rolling.sh` بـ `PREVIOUS_IMAGE` (اللي اتسجل في الـ state) و `SKIP_MIGRATE=true`:

```bash
cd /opt/student-app/src/deploy/ec2/lb
grep PREVIOUS_IMAGE state/release.env
SKIP_PULL=true bash ../../scripts/with-probe.sh -- bash bin/rollback.sh
bash bin/status.sh
```

- الـ rollback نفسه rolling (slot بـ slot، الـ capacity 50% في كل خطوة)، مش switch فوري زي blue/green.
- بعده `PREVIOUS_IMAGE` = الإصدار اللي رجعت منه، فـ `rollback.sh` تاني = roll-forward.
- لو مفيش `PREVIOUS_IMAGE` (state قديم): `rollback.sh` بيرفض ويقولك تشغّل `rolling.sh <old-image>` بإيدك. وبديل أسرع (slot واحد): `SKIP_PULL=true bash bin/bluegreen.sh <OLD_IMAGE>`.
- الـ migrations مش بترجع (`SKIP_MIGRATE=true`) — الـ schema الجديد فاضل، وده سبب expand/contract ([95](95-zero-downtime-db-migrations.md)).

## 10) المسح (Teardown) ⚠️

مفيش موارد جديدة. الـ `MODE=rolling` مش محتاج تنضيف — أي deploy جاي (bluegreen/canary/ab/shadow/rolling) بيبدأ بـ `ensure_single_live`. Teardown الـ host من [20 §10](20-ec2-compose-console.md).

## 11) التكلفة (Cost)

| Resource | السعر التقريبي |
|---|---|
| نفس host سيناريو 20 | ~$0.65/يوم |
| النسخة الحقيقية (ASG ≥ 2 instances + ALB) | [42](42-alb-asg-launch-template.md) ~$1.5/يوم |

## 12) أسئلة Interview

<details><summary>قارن rolling هنا بـ ASG Instance Refresh و ECS و Kubernetes.</summary>

نفس الـ loop: اشيل → drain → استبدل → health → رجّع. ASG Instance Refresh: `MinHealthyPercentage` (≈ maxUnavailable) و `MaxHealthyPercentage` (> 100 = surge)، `InstanceWarmup`، checkpoints، و auto-rollback ([44](44-rolling-instance-refresh.md)). ECS rolling: `minimumHealthyPercent` و `maximumPercent` + deployment circuit breaker ([53](53-ecs-rolling-circuit-breaker.md)). Kubernetes `RollingUpdate`: `maxUnavailable` و `maxSurge` + readiness probes + PDB + `preStop` ([66](66-k8s-rolling-recreate.md)). الفرق إنهم بيعملوا surge بسهولة لأن الـ capacity مرنة؛ هنا البورتات ثابتة فـ surge = 0.

</details>

<details><summary>maxSurge ولا maxUnavailable؟</summary>

`maxSurge` بيحافظ على الـ capacity كاملة (بيعمل الجديد الأول) بس محتاج موارد زيادة مؤقتاً. `maxUnavailable` مش محتاج موارد بس بيقلل الـ capacity. لخدمة شغالة قريب من الـ peak: surge > 0 و unavailable = 0. لـ cluster مضغوط في الموارد ومش في peak: unavailable = 1 و surge = 0.

</details>

<details><summary>إيه الـ drain وليه مش كفاية تبعت SIGTERM وخلاص؟</summary>

لازم الـ LB يبطّل يبعت requests جديدة **الأول**، وإلا requests هتوصل لـ process بيقفل → errors. وبعدين الـ process يخلّص الـ in-flight (graceful signal + grace period). في K8s فيه race معروف: الـ SIGTERM ممكن يوصل قبل ما الـ endpoints تتحدّث عند كل الـ nodes، عشان كده `preStop: sleep`. والـ deregistration delay في الـ ALB target groups نفس الفكرة.

</details>

<details><summary>إيه المشاكل اللي بتظهر في الـ mixed-version window؟</summary>

نفس المستخدم بيتنقل بين الإصدارين: schema لازم يكون متوافق، الـ sessions/cache serialization لازم يتقري من الاتنين، API responses بين services، الـ asset hashes (CSS/JS) ممكن تبقى مش موجودة على الإصدار التاني، والـ background jobs اللي اتعملت enqueue بشكل جديد ممكن الـ worker القديم ميفهمهاش.

</details>

<details><summary>الـ rolling وقع في نص الطريق — تعمل إيه؟</summary>

أول حاجة: الـ traffic كله يروح للـ replicas السليمة، وده لازم يحصل **أوتوماتيك** — `rolling.sh` بيدّي الـ peer اللي على الإصدار القديم 100% ويسجّله `ACTIVE` قبل ما يقف، وفي المنصات الـ managed ده دور الـ circuit breaker / auto-rollback. بعدين أقرر: roll forward بـ fix، أو rollback بـ rollout للإصدار القديم. ودرس تصميم: الـ automation لازم تتحقق من الـ state قبل ما تثق فيه — عشان كده `ensure_single_live` بيرفض يحوّل traffic لـ live مش ready، وخطوة التجهيز بتمنع أي slot بـ image مختلفة من دخول الـ pool.

</details>

## 13) Checklist

- [ ] عملت rolling بـ 0 failed requests وراقبت الـ upstream وهو بيتغير
- [ ] فهمت الـ capacity math (N-1) وإمتى تحتاج surge
- [ ] جرّبت release فاشل في النص وشفت الـ peer بياخد 100% (`ACTIVE=peer`، `MODE=single`)
- [ ] عملت `rollback.sh` بعد rolling ناجح وشفته بيرجع لـ `PREVIOUS_IMAGE`
- [ ] قارنت بـ ASG / ECS / K8s
