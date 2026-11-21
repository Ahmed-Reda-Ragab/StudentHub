# 22 — Recreate وقياس الـ downtime

> **الهدف في سطر:** تقيس بالأرقام الـ downtime بتاع استراتيجية **Recreate** بـ `probe.sh` / `probe.ps1` / `with-probe.sh`، تقرا الـ summary صح (availability % و failure window)، وتحوّل الرقم ده لـ error budget عشان تعرف إمتى Recreate "كفاية" وإمتى لأ.
> **المستوى:** Beginner → Intermediate · **الوقت:** ~2 ساعة · **التكلفة التقريبية:** نفس [20](20-ec2-compose-console.md) (~$0.65/يوم)
> **بيعتمد على:** [20 — EC2 + Docker Compose (Console)](20-ec2-compose-console.md) · **الملفات في الـ repo:** [`deploy/scripts/probe.sh`](../../../deploy/scripts/probe.sh) · [`deploy/scripts/probe.ps1`](../../../deploy/scripts/probe.ps1) · [`deploy/scripts/with-probe.sh`](../../../deploy/scripts/with-probe.sh) · [`deploy/ec2/deploy-build-on-server.sh`](../../../deploy/ec2/deploy-build-on-server.sh) · [`docker-compose.prod.yml`](../../../docker-compose.prod.yml)

## 1) الفكرة (Concepts)

**Recreate** = وقّف القديم، شغّل الجديد. أبسط استراتيجية، ومفيش وقت بيشتغل فيه إصداران مع بعض (ميزة لو الـ migrations مش متوافقة)، بس فيه **فجوة** مفيش فيها حد بيخدم.

اللي بيحصل بالظبط في `docker compose up -d --no-deps --wait app`:

```text
 t0  compose يبعت SIGQUIT للـ container القديم (STOPSIGNAL)
     └─ nginx/FPM بيخلّصوا الـ requests الشغالة (لحد stop_grace_period = 30s)
     └─ أي connection جديد على :80 ← refused  ◄── الـ downtime بدأ
 t1  الـ container القديم اتشال، الجديد اتعمل واشتغل
     └─ S6 → entrypoint.d (2-sre-boot-fault.sh) → AUTORUN: php artisan optimize
     └─ PHP-FPM ثم nginx بيبدأوا يسمعوا على 8080   ◄── الـ downtime خلص
 t2  healthcheck (/up كل 10s، start_period 30s) يقول healthy → `--wait` يرجع
```

> 💡 نقطة Senior: **Docker مش بيمنع الـ traffic عن container لسه مش healthy.** الـ port mapping شغال من أول ما الـ container يبدأ. الـ healthcheck بيأثر على `depends_on` و `--wait` (وعلى الـ orchestrators زي ECS/K8s)، مش على الـ traffic اللي جاي على `80:8080`.

| المصطلح | المعنى |
|---|---|
| Downtime window | الوقت من أول request فشل لآخر request فشل |
| Availability (probe) | `(requests - failed) / requests` في فترة القياس |
| Error budget | `1 - SLO` — كمية الفشل المسموح بيها في الفترة (عندنا 0.5% / 30 يوم ≈ 3h 36m) |
| Sampling | الـ probe بيبعت request كل `INTERVAL` — الدقة محدودة بيه |

## 2) المعمارية (Architecture)

```text
 laptop (WSL أو PowerShell)                    EC2 (Session Manager)
 ┌──────────────────────────────┐              ┌───────────────────────────────────────┐
 │ probe.sh http://<EIP>/ready  │── HTTP :80 ─►│ app (old) ──stop──► app (new)         │
 │   كل 0.2s، timeout 2s        │              │ deploy-build-on-server.sh devops-lab  │
 │ → summary: availability %,   │              │   build → migrate → up -d --wait app  │
 │   failure window, versions   │              └───────────────────────────────────────┘
 └──────────────────────────────┘
 أو على نفس الـ host:  with-probe.sh -- <deploy command>   (probe في الخلفية + exit code)
```

## 3) المتطلبات (Prerequisites)

- [ ] [20](20-ec2-compose-console.md) شغال: التطبيق على `http://<ELASTIC_IP>/`.
- [ ] الـ SG بيسمح بـ 80 من الـ IP بتاعك (لو الـ IP اتغيّر: عدّل الـ rule لـ **My IP** تاني).
- [ ] نسخة من الـ repo على جهازك (عشان `deploy/scripts/`).
- الأدوات: `bash` + `curl` (WSL) أو PowerShell 5.1+.

## 4) الطريقة الأولى: AWS Console (يدوي)

مفيش موارد جديدة. اللي محتاجه من الـ Console:

1. **EC2 → Security Groups → `student-app-lab-web-sg` → Edit inbound rules** → اتأكد إن source بتاع الـ 80 هو الـ IP الحالي بتاعك (`curl -s https://checkip.amazonaws.com`).
2. **EC2 → Instances → Connect → Session Manager** — هتحتاج terminal على السيرفر وterminal على جهازك في نفس الوقت.
3. اختياري: **CloudWatch → Metrics → EC2 → Per-Instance Metrics → CPUUtilization** للـ instance — هتشوف الـ spike بتاع الـ build على السيرفر وقت الـ deploy.

## 5) الطريقة التانية: Infrastructure as Code

نفس الـ host من [21 — Terraform + Ansible](21-ec2-compose-terraform-ansible.md) (stack `infra/terraform/stacks/20-ec2-single`). القياس نفسه مش محتاج IaC؛ المهم إن الـ host يبقى نفس الـ instance type عشان أرقامك تبقى قابلة للمقارنة بين الجولات.

### أدوات القياس — بتعمل إيه بالظبط

**`probe.sh URL [DURATION] [INTERVAL]`**

| المدخل | الافتراضي | المعنى |
|---|---|---|
| `URL` | `http://localhost/ready` | الـ endpoint (الأفضل `/ready` عشان بيرجّع `version`/`color`) |
| `DURATION` | `60` | ثواني؛ `0` = لحد ما `STOP_FILE` يظهر أو `SIGTERM`/`SIGINT` |
| `INTERVAL` | `0.2` | ثواني بين كل request والتاني |
| `TIMEOUT` (env) | `2` | timeout الـ curl بالثواني |
| `OUT` (env) | — | يكتب الـ summary في ملف كمان (`tee`) |
| `STOP_FILE` (env) | — | يقف لما الملف ده يتعمل (للـ CI) |
| `MAX_FAILURES` (env) | — | لو اتحدد: exit 1 لو الـ failures أكتر منه |

أي رد مش `2xx/3xx` أو مفيش رد (`000`) = فشل، وبيطبع `[probe] HH:MM:SS FAIL http=<code>` على stderr. في الآخر summary فيه: `url`، `duration`، `requests`، `failed`، `availability` (3 أرقام عشرية)، `failure window` (أول → آخر فشل، بدقة الثانية)، و `answered by` (عدد الردود لكل `version (color)` مقروءة من الـ JSON).

**`probe.ps1 -Url -Seconds -IntervalMs`** (لو هتقيس من PowerShell): افتراضياً `http://localhost/ready`، 60 ثانية، 200ms، و timeout ثانيتين. بيطبع `requests` و `failed` و `availability` و `answered by` — **مفيش** failure window ولا exit code.

**`with-probe.sh -- <command...>`**: بيشغّل `probe.sh` في الخلفية (بـ `STOP_FILE`)، يستنى ثانية، يشغّل الأمر، يستنى ثانيتين، يقفل الـ probe. الـ env: `PROBE_URL` (`http://localhost/ready`)، `PROBE_INTERVAL` (`0.05`)، `MAX_FAILURES` (`0`)، `EXPECT_EXIT` (`0`). بيرجع non-zero لو exit الأمر ≠ `EXPECT_EXIT` **أو** الـ probe شاف failures أكتر من `MAX_FAILURES`. ده اللي `lab-integration.yml` بيستخدمه عشان يثبت **0 failed requests** في الـ zero-downtime scripts.

## 6) الـ Deploy (مع القياس)

### 6.1 القياس من جهازك (الأدق — الـ probe بره السيرفر)

Terminal 1 (WSL على جهازك):

```bash
cd ~/src/StudentHub
bash deploy/scripts/probe.sh http://<ELASTIC_IP>/ready 180 0.2 2>&1 | tee /tmp/recreate-run1.txt
```

أو من PowerShell:

```powershell
.\deploy\scripts\probe.ps1 -Url http://<ELASTIC_IP>/ready -Seconds 180 -IntervalMs 200
```

Terminal 2 (Session Manager على السيرفر، خلال الـ 180 ثانية):

```bash
sudo su - ec2-user
cd /opt/student-app/src && git pull --ff-only
bash deploy/ec2/deploy-build-on-server.sh devops-lab
```

> 💡 لو مفيش commit جديد، الـ build هييجي من الـ cache والـ image هتبقى نفس الـ tag، و `compose up` ممكن ميعملش recreate أصلاً (مفيش تغيير). عشان تقيس الـ **Recreate الصافي** من غير build:
> ```bash
> export APP_IMAGE="$(cat /opt/student-app/CURRENT_RELEASE)"
> docker compose -f docker-compose.prod.yml up -d --no-deps --force-recreate --wait app
> ```

### 6.2 القياس على نفس السيرفر بـ `with-probe.sh`

```bash
cd /opt/student-app/src
export APP_IMAGE="$(cat /opt/student-app/CURRENT_RELEASE)"
MAX_FAILURES=100000 PROBE_INTERVAL=0.1 bash deploy/scripts/with-probe.sh -- \
  docker compose -f docker-compose.prod.yml up -d --no-deps --force-recreate --wait app
```

حطينا `MAX_FAILURES` كبير لأننا **متوقعين** فشل مع Recreate؛ الافتراضي `0` كان هيخلي الأمر يرجع exit 1 (وده بالظبط اللي هيحصل في [23](23-bluegreen-single-host.md) لو حصل أي فشل).

> ⚠️ الـ probe على نفس الـ host بيتنافس على الـ CPU مع الـ container اللي بيقوم، والطريق مش بيعدّي على الشبكة/الـ SG. استخدمه للمقارنة، والقياس الرسمي من بره.

### 6.3 من غير EC2 ومن غير Docker محلي (GitHub Actions)

`lab-integration.yml` مفيهوش step بيقيس Recreate. تمرين: في branch تجريبي ضيف step للـ job `compose` بعد الـ smoke tests:

```yaml
- name: "Measure Recreate downtime"
  run: |
    MAX_FAILURES=100000 PROBE_URL=http://localhost:8080/ready PROBE_INTERVAL=0.05 \
      bash deploy/scripts/with-probe.sh -- docker compose up -d --no-build --no-deps --force-recreate --wait app
```

وشوف الـ `probe summary` في اللوج (`gh run view <RUN_ID> --log | grep -A12 "probe summary"`).

## 7) التحقق (Verify) — قراية الـ summary

مثال **توضيحي** (أرقامك هتختلف حسب الـ instance والـ image):

```text
================ probe summary ================
url            : http://<ELASTIC_IP>/ready
duration       : 180s
requests       : 790
failed         : 41
availability   : 94.810%
failure window : 14:02:11 → 14:02:20
answered by    :
  3f2c1ab (none)                   402
  9d81e07 (none)                   347
===============================================
```

إزاي تقراه:

- **`failure window`** هو رقم الـ downtime الحقيقي (هنا ~9–10 ثواني بدقة الثانية). ده أهم من عدد الـ failures.
- **`failed` بيقلّل من الحقيقة لو فيه timeouts**: الـ probe sequential، فـ request بيعمل hang بياخد `TIMEOUT` (2s) ويتحسب فشل **واحد**. الـ connection refused بيرجع فوراً فبيتعد صح. عشان كده الـ window أصدق من العدد.
- **`availability`** مرتبطة بطول فترة القياس: نفس الـ 10 ثواني في 60 ثانية = ~83%، وفي 180 = ~94%. متقارنش أرقام من فترات مختلفة.
- **`answered by`** بيثبت إن الـ release اتغيّر فعلاً (version قديمة → جديدة) ومفيش وقت كانوا الاتنين بيردّوا مع بعض (ده Recreate).
- `color = none` لأن `DEPLOY_COLOR` مش متحدد في الـ Recreate stack.

سجّل نتايجك (3 جولات على الأقل وخد الـ median):

| الجولة | نوع الـ deploy | failure window | failed / requests | ملاحظات |
|---|---|---|---|---|
| 1 | `--force-recreate` بس | | | |
| 2 | build + migrate + recreate | | | |
| 3 | `t4g.small` بدل `t3.small` | | | |

> التوقع التقريبي على `t3.small`: فجوة من **ثواني قليلة لحد ~15 ثانية** (stop + boot + `artisan optimize`). لو لقيت أكتر بكتير، دوّر على: الـ build شغال وقت الـ recreate؟ (السكريبت بيبني **قبل** الـ recreate، فالمفروض لأ)، الـ swap شغال؟ (`free -h`)، الـ image كبيرة؟

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر | المتوقع |
|---|---|---|
| Release مش بيقوم | `aws ssm put-parameter --name /student-app/lab/app/SRE_FAULT_BOOT_FAIL --type String --value true --overwrite` ← على السيرفر: `bash deploy/ec2/render-env-from-ssm.sh` ← `APP_IMAGE=$(cat /opt/student-app/CURRENT_RELEASE) docker compose -f docker-compose.prod.yml up -d --no-deps --force-recreate --wait app` | `--wait` يفشل، والـ probe بيفشل **لحد ما تصلّح** — مع Recreate الـ container القديم اتشال خلاص، مفيش safety net |
| Latency على صفحات حقيقية | نفس الطريقة بـ `SRE_FAULT_LATENCY_MS=800`، وقيس بـ `probe.sh http://<EIP>/login 60 0.2` | مفيش failures بس كل request أبطأ — `/ready` مش هيبيّن حاجة لأنه بره الـ web group (الـ fault على صفحات الـ web بس) |
| Probe timeout | `TIMEOUT=0.3 bash deploy/scripts/probe.sh http://<EIP>/ready 60 0.2` | ممكن تشوف failures من غير deploy — الـ timeout الضيق بيعمل false positives؛ اختار timeout أكبر من p99 بتاعك |
| Grace period | قلّل `stop_grace_period` لـ `1s` في نسخة تجريبية وابعت load على `/sre-lab/latency?ms=3000` (بـ `X-Lab-Token`) وقت الـ recreate | الـ requests الطويلة بتتقطع (SIGKILL) بدل ما تخلص |

رجّع الحالة: `aws ssm delete-parameter --name /student-app/lab/app/SRE_FAULT_BOOT_FAIL` ← `bash deploy/ec2/render-env-from-ssm.sh` (بيعيد كتابة `app.env` كامل من الموجود في SSM) ← `docker compose -f docker-compose.prod.yml up -d --no-deps --wait app`.

## 9) الرجوع (Rollback)

مع Recreate الـ rollback هو **Recreate تاني** بالـ image القديمة — يعني downtime تاني:

```bash
export APP_IMAGE="$(cat /opt/student-app/PREVIOUS_RELEASE)"
docker compose -f docker-compose.prod.yml up -d --no-deps --wait app
```

قيسه بنفس الـ probe. ده أهم درس هنا: **وقت الـ recovery = وقت الـ detection + وقت الـ redeploy**، ومع Recreate الاتنين بيتحسبوا من الـ error budget.

### الـ SLO math: deploy واحد سيء مقابل الـ error budget

الـ SLO بتاعنا ([CONVENTIONS §5](../CONVENTIONS.md)): **99.5% / 30 يوم** → budget = 0.5% × 43,200 دقيقة = **216 دقيقة**.

| الموقف | الحساب | من الـ budget |
|---|---|---|
| Recreate بـ 10s downtime، deploy واحد/يوم | 10s × 30 = 5 دقايق | ~2.3% |
| Recreate بـ 10s، 10 deploys/يوم | 100s × 30 = 50 دقيقة | ~23% |
| Bad release اتلاحظ بعد 15 دقيقة + rollback | ~15.5 دقيقة | ~7% في حادثة واحدة |
| نفس الـ 10 deploys/يوم لو الـ SLO 99.9% (budget 43.2 دقيقة) | 50 دقيقة | **116% — الـ budget اتحرق** |

الخلاصة: Recreate ممكن يبقى مقبول لـ SLO مريح و deploys قليلة. لما الـ deploys تكتر أو الـ SLO يشتد، لازم zero-downtime ([23](23-bluegreen-single-host.md)) و detection أسرع (canary + burn-rate alerts، [24](24-canary-single-host.md) و [73](73-slo-error-budget-burn-rate.md)). وخلي بالك إن الـ SLI عندنا request-based على app routes (مش `/ready`)، فالـ downtime وقت الـ traffic العالي أغلى من نفس الثواني بالليل.

## 10) المسح (Teardown) ⚠️

مفيش موارد جديدة. امسح أي fault parameters فضلت:

```bash
aws ssm get-parameters-by-path --path /student-app/lab/app --query "Parameters[?contains(Name,'SRE_FAULT')].Name" --output text
aws ssm delete-parameter --name /student-app/lab/app/SRE_FAULT_BOOT_FAIL
```

ولو خلصت الجلسة: stop أو teardown كامل حسب [20 §10](20-ec2-compose-console.md).

## 11) التكلفة (Cost)

| Resource | السعر التقريبي |
|---|---|
| نفس الـ host بتاع 20 | ~$0.65/يوم |
| الـ probe من جهازك | مجاني (traffic صغير جداً) |

## 12) أسئلة Interview

<details><summary>إزاي تقيس الـ downtime بتاع deploy بشكل موثوق؟</summary>

synthetic probe من **بره** الـ host (عشان يعدّي على الشبكة والـ LB والـ SG زي المستخدم)، بـ interval صغير، و timeout أكبر من p99 العادي، وأسجّل الـ failure window مش بس العدد، وأكرر القياس كذا مرة. وفي production أقارن مع الـ SLI الحقيقي من الـ metrics (5xx/total على app routes) عشان الـ probe بيشوف endpoint واحد بس.

</details>

<details><summary>الـ healthcheck و `--wait` بيقللوا الـ downtime؟</summary>

لأ مع Docker Compose العادي — الـ traffic بيوصل للـ container من أول ما يبدأ. `--wait` بيخلي الـ deploy script يفشل بصوت عالي لو الـ container الجديد مبقاش healthy، بدل ما يقول "deployed" وهو واقع. الـ healthcheck بيقلل الـ downtime فعلاً لما يكون فيه حاجة بتمنع الـ traffic لحد ما يبقى ready: ALB target group، K8s readiness، أو nginx upstream بـ `proxy_next_upstream` زي [23](23-bluegreen-single-host.md).

</details>

<details><summary>إمتى Recreate هو الاختيار الصح؟</summary>

لما ميبقاش ينفع إصداران يشتغلوا مع بعض: migration مش متوافقة ومش هتعمل expand/contract، singleton (consumer لازم يبقى instance واحد، scheduler)، أو license/lock. وكمان للـ dev/staging. ولو اخترته في production: maintenance window، صفحة maintenance من الـ LB، وإبلاغ المستخدمين.

</details>

<details><summary>ليه الـ availability في الـ probe ممكن تضللك؟</summary>

بتعتمد على طول فترة القياس (نفس الفجوة تبان أصغر في فترة أطول)، والـ probe الـ sequential بيقلل عدد العينات وقت الـ timeouts، وبيقيس endpoint واحد (`/ready` ممكن ينجح والـ login واقع — زي `SRE_FAULT_ERROR_RATE`). الأرقام اللي تتقارن: failure window، و error budget consumed من الـ SLI الحقيقي.

</details>

<details><summary>Deploy بياخد 10 ثواني downtime — اشرح أثره على error budget لـ 99.9%.</summary>

Budget 99.9% في 30 يوم = 43.2 دقيقة. Deploy واحد/يوم = 5 دقايق/شهر (~12%). لو 10 deploys/يوم = 50 دقيقة = الـ budget كله وزيادة، من غير أي incident. يعني الـ deploy strategy نفسها بتبقى أكبر مصدر للـ unavailability، والحل zero-downtime deploys + فصل الـ deploy عن الـ release (feature flags).

</details>

## 13) Checklist

- [ ] قست Recreate من جهازك بـ `probe.sh` أو `probe.ps1` (3 جولات)
- [ ] جرّبت `with-probe.sh` وفهمت ليه `MAX_FAILURES` لازم يتحدد
- [ ] قريت الـ failure window وفهمت ليه أصدق من عدد الـ failures
- [ ] جرّبت release مش بيقوم وشفت إن Recreate مفيهوش safety net
- [ ] حسبت أثر الـ deploys على الـ error budget لـ 99.5% و 99.9%
- [ ] مسحت الـ fault parameters
