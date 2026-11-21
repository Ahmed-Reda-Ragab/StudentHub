# 23 — Blue/Green على سيرفر واحد (nginx switch)

> **الهدف في سطر:** تشغّل ستاك الـ zero-downtime في `deploy/ec2/lb` (nginx قدام slotين `app_blue` و `app_green`)، تفهم `bluegreen.sh` خطوة بخطوة من `lib.sh`، تعمل switch و rollback فوري بـ **0 failed requests**، وتعرف حدود الطريقة دي (الداتابيز المشتركة، الـ host الواحد).
> **المستوى:** Intermediate · **الوقت:** ~3 ساعات · **التكلفة التقريبية:** نفس [20](20-ec2-compose-console.md) (~$0.65/يوم؛ `t3.medium` ~$1.1/يوم لو الـ RAM ضاقت)
> **بيعتمد على:** [20](20-ec2-compose-console.md) · [22 — Recreate وقياس الـ downtime](22-recreate-and-measuring-downtime.md) · **الملفات في الـ repo:** [`deploy/ec2/lb/docker-compose.yml`](../../../deploy/ec2/lb/docker-compose.yml) · [`deploy/ec2/lb/nginx/nginx.conf`](../../../deploy/ec2/lb/nginx/nginx.conf) · [`deploy/ec2/lb/bin/lib.sh`](../../../deploy/ec2/lb/bin/lib.sh) · [`deploy/ec2/lb/bin/init.sh`](../../../deploy/ec2/lb/bin/init.sh) · [`deploy/ec2/lb/bin/bluegreen.sh`](../../../deploy/ec2/lb/bin/bluegreen.sh) · [`deploy/ec2/lb/bin/rollback.sh`](../../../deploy/ec2/lb/bin/rollback.sh) · [`deploy/ec2/lb/bin/status.sh`](../../../deploy/ec2/lb/bin/status.sh)

## 1) الفكرة (Concepts)

**Blue/Green** = بيئتين متطابقتين؛ واحدة live والتانية idle. بتعمل deploy على الـ idle، تختبرها وهي **مش واخدة traffic**، وبعدين تحوّل 100% من الـ traffic مرة واحدة. الـ rollback = تحويل تاني للقديمة اللي لسه شغالة → **فوري**.

على سيرفر واحد: "البيئتين" = container-ين للتطبيق، و "الـ router" = nginx بيعمل graceful reload.

| المصطلح | المعنى |
|---|---|
| Live / Idle | الـ slot اللي واخد الـ traffic / اللي بنعمل عليه deploy |
| Switch | تغيير الـ upstream في nginx + `nginx -s reload` |
| Graceful reload | nginx بيشغّل workers جديدة بالـ config الجديدة، والقديمة بتخلّص الـ requests اللي في إيدها وتقفل |
| `KEEP_OLD` | تسيب الـ slot القديم شغال (rollback فوري) ولا توقفه (توفير RAM) |
| Expand/contract | طريقة كتابة migrations متوافقة مع الإصدارين ([95](95-zero-downtime-db-migrations.md)) |

**الفرق عن Recreate:** الـ release الجديد بيقوم ويتختبر **قبل** ما ياخد أي traffic. لو فشل، المستخدمين مش حاسين بحاجة.

## 2) المعمارية (Architecture)

```text
                        EC2 (نفس host سيناريو 20)
 Internet :80 ─► ┌─ proxy (nginx:1.28-alpine) ───────────────────────────┐
                 │  nginx.conf ─ include state/nginx/{upstreams,maps,routing}.conf
                 │  /lb-health → 200   /metrics → 404 (يتقفل على الـ LB)  │
                 │  upstream app_main ──► app_blue:8080 resolve (live)   │
                 └───────────────┬───────────────────────────────────────┘
                     Docker DNS 127.0.0.11 (resolve كل 5s)
              ┌──────────────────┴──────────────────┐
     app_blue (DEPLOY_COLOR=blue)          app_green (DEPLOY_COLOR=green)
     127.0.0.1:8081 → 8080                 127.0.0.1:8082 → 8080
     env: app.env + state/blue.env         env: app.env + state/green.env
              └──────────────► mysql:8.4 (volume student-app_mysql-data) ◄── shared!

 deploy/ec2/lb/state/   (gitignored، الـ scripts بس اللي بتكتبه)
   release.env   BLUE_IMAGE=… GREEN_IMAGE=… ACTIVE=blue MODE=single PREVIOUS_IMAGE=…
                 (MODE = single | canary | ab | shadow | rolling؛ PREVIOUS_IMAGE بيكتبه rolling.sh)
   blue.env / green.env   (SLOT_ENV extras لـ slot معين)
   nginx/upstreams.conf · maps.conf · routing.conf
```

- الـ slots مربوطين على `127.0.0.1` بس → مش مكشوفين على الإنترنت، بس `lib.sh` يقدر يكلّمهم مباشرة (`wait_ready`، `smoke`، `/metrics`).
- نفس compose project (`name: student-app`) ونفس الـ volume بتوع `docker-compose.prod.yml` → النقل من Recreate بيحافظ على الداتابيز.
- مع RDS ([41](41-rds-mysql.md)): `DB_HOST` في `app.env` و `USE_LOCAL_MYSQL=false` → الـ mysql مش بيقوم أصلاً.

## 3) المتطلبات (Prerequisites)

- [ ] [20](20-ec2-compose-console.md) شغال (`/opt/student-app/app.env` و `mysql.env` موجودين، الـ repo في `/opt/student-app/src` على `devops-lab`).
- [ ] قريت [22](22-recreate-and-measuring-downtime.md) وعارف تستخدم `probe.sh` و `with-probe.sh`.
- الأدوات: Session Manager، `curl`، `jq` (موجود من الـ user-data).

## 4) الطريقة الأولى: AWS Console (يدوي) — تجهيز الـ host

1. **EC2 → Security Groups → `student-app-lab-web-sg`**: نفس الـ rule (HTTP 80 من **My IP**). **مفيش** حاجة تتفتح لـ 8081/8082 — الـ slots على localhost.
2. **الـ RAM:** هيبقى عندك container-ين للتطبيق + MySQL + nginx (+ build لو بتبني على السيرفر). من Session Manager: `free -h` و `docker stats --no-stream`. لو ضاقت:
   **EC2 → Instances → Instance state → Stop** → **Actions → Instance settings → Change instance type** → `t3.medium` → **Start** (الـ EIP بيفضل).
3. اختياري: **CloudWatch → Alarms → Create alarm** على `StatusCheckFailed` للـ instance — لأن الـ host ده **single point of failure** (blue/green هنا بيحميك من release سيء، مش من وقوع السيرفر).

## 5) الطريقة التانية: Infrastructure as Code

الـ host نفسه من stack `infra/terraform/stacks/20-ec2-single` ([21](21-ec2-compose-terraform-ansible.md))، ونسخ `lb/` لـ `/opt/student-app/lb` بـ Ansible ([33](33-cd-ec2-ansible.md)). الـ "IaC" الحقيقي في السيناريو ده هو الستاك نفسه as code:

### 5.1 الـ knobs (env) من `lib.sh`

| Env | الافتراضي | المعنى |
|---|---|---|
| `APP_ENV_FILE` | `/opt/student-app/app.env` | env الـ app (من `render-env-from-ssm.sh`) |
| `MYSQL_ENV_FILE` | `/opt/student-app/mysql.env` | env الـ MySQL container |
| `USE_LOCAL_MYSQL` | `true` | `false` مع RDS |
| `LB_HTTP_PORT` | `80` | بورت الـ proxy على الـ host |
| `READY_TIMEOUT` | `120` | ثواني يستنى الـ slot يبقى ready |
| `SKIP_PULL` | — | `true` لـ image local من غير `docker compose pull` |
| `SKIP_MIGRATE` | — | `true` يتخطى `migrate --force` |
| `SLOT_ENV` | — | env زيادة للـ slot **الجديد بس** (`"SRE_FAULT_ERROR_RATE=0.5"`)؛ مفصولة بمسافات، فالقيم نفسها مينفعش يبقى فيها مسافة |
| `KEEP_OLD` (bluegreen) | `true` | `false` = وقّف القديم بعد `DRAIN_SECONDS` |
| `DRAIN_SECONDS` (bluegreen) | `10` | |

### 5.2 `init.sh <image>` — أول تشغيل

`BLUE_IMAGE=GREEN_IMAGE=<image>`، `ACTIVE=blue`، `MODE=single` → `save_state` → `render_single blue` (يكتب `upstreams.conf` و `routing.conf`) → لو `USE_LOCAL_MYSQL=true`: `compose up -d --wait mysql` → `start_slot blue` (لو فشل: `die "first release failed its checks"`) → `reload_proxy` (لو الـ proxy مش شغال بيشغّله) → `via_proxy /ready`.

### 5.3 `bluegreen.sh <image>` خطوة بخطوة

دوال الـ slot في `lib.sh` (`is_ready`، `wait_ready`، `smoke`، `migrate`، `start_slot`) **بترجع 1** لو فشلت بدل ما تقفل السكريبت، وكل strategy بتقرر الفشل معناه إيه. في blue/green المعنى: **الـ traffic ميتحركش**.

| # | الخطوة (`lib.sh`) | بيحصل إيه | لو فشلت |
|---|---|---|---|
| 0 | `load_state` + **`ensure_single_live`** | لو `MODE` مش `single` (بعد rolling الاتنين في الـ pool، أو تجربة اتقطعت) بيتأكد إن الـ `ACTIVE` ready (`is_ready`) وبعدين يرجّعله 100% قبل ما يلمس الـ idle | لو الـ live نفسه مش ready: die (`inspect with bin/status.sh before deploying`) — مش هيحوّل traffic لـ slot واقع |
| 1 | `set_image IDLE` + `save_state` | الـ image الجديدة اتسجلت للـ idle | — |
| 2 | `compose pull app_IDLE` | لو فشل: warning ويكمّل بالـ image الـ local (أو `SKIP_PULL=true`) | — |
| 3 | `write_slot_env` | يصفّر `state/IDLE.env` أو يكتب فيه `SLOT_ENV` | ↓ |
| 4 | `migrate` | `compose run --rm --no-deps app_IDLE php artisan migrate --force` — **والـ live لسه بيخدم 100%** | warning `migrations failed with <image>` (الـ schema ممكن يكون اتغيّر جزئياً!) ↓ |
| 5 | `compose up -d --no-deps --force-recreate app_IDLE` | `--no-deps` عشان ميلمسش mysql/proxy | ↓ |
| 6 | `wait_ready` | `curl 127.0.0.1:<port>/ready` كل 2s لحد `READY_TIMEOUT`؛ لو خلص الوقت بيطبع آخر 50 سطر logs | warning `not ready after Ns` ↓ |
| 7 | `smoke` | `/up`، `/ready`، `/login` لازم 2xx/3xx | warning `smoke test failed: app_IDLE <path>` ↓ |
| ↓ | أي فشل في 3–7 | `start_slot` بيرجع 1 | die: `new release failed its pre-traffic checks - traffic is still 100% on <live> (<image>)` |
| 8 | `render_single IDLE` | `upstream app_main { server app_IDLE:8080 resolve; keepalive 16; }` | — |
| 9 | `reload_proxy` | `nginx -t -q` (لو فشل: `traffic NOT switched`) ثم `nginx -s reload` | die قبل الـ switch |
| 10 | verify | `via_proxy /ready` لازم `"color"` = IDLE | die |
| 11 | `ACTIVE=IDLE`، `MODE=single`، `save_state` | | |
| 12 | `KEEP_OLD` | `true`: القديم شغال للـ rollback · `false`: `sleep DRAIN_SECONDS` ثم `compose stop` (SIGQUIT، لحد 30s) | |

### 5.4 ليه الـ switch من غير ولا request فاشل؟

1. **الجديد جاهز 100% قبل الـ switch** (ready + smoke على الـ port المباشر).
2. **Graceful reload**: الـ workers القديمة في nginx بتكمّل الـ requests اللي معاها على الـ upstream القديم، والجديدة بتاخد الـ connections الجديدة.
3. **`resolve` + Docker DNS**: `resolver 127.0.0.11 valid=5s` و `server app_X:8080 resolve` (nginx ≥ 1.27.3 open source، ومحتاج `zone`) → لما slot يتعمله recreate وياخد IP جديد، nginx بيعيد الـ resolve لوحده بدل ما يفضل يبعت على IP ميت لحد الـ reload الجاي. وده كمان اللي بيخلّي الـ upstreams `app_blue_only`/`app_green_only` تتعرّف حتى لو الـ container مش موجود لسه.
4. **`proxy_next_upstream error timeout http_502 http_503 http_504` + `proxy_next_upstream_tries 2`**: لو upstream فيه أكتر من server (canary/rolling) وواحد رفض الـ connection، الـ request بيتعاد على التاني. الـ POST مش بيتعاد لو اتبعت فعلاً (non-idempotent). في الـ single mode مفيش server تاني، فالحماية هنا جاية من 1 و 2.
5. **Sessions في الداتابيز** (`SESSION_DRIVER=database`) ونفس `APP_KEY` → المستخدم مش بيعمل logout لما ينتقل من blue لـ green.

### 5.5 ⚠️ الداتابيز المشتركة — أهم caveat

الـ migration بتجري بالـ image الجديدة **والكود القديم لسه بيخدم**، وبعد الـ switch الكود القديم فاضل شغال للـ rollback. يعني **الـ schema الجديد لازم يشتغل مع الكود القديم والجديد**. مثال حقيقي من الـ repo: [`2026_09_30_151013_add_pricing_to_subscriptions_table.php`](../../../database/migrations/2026_09_30_151013_add_pricing_to_subscriptions_table.php) بيعمل `price`/`commission` NOT NULL **وبيمسح** `amount` في نفس الخطوة → الكود القديم (اللي `fillable` بتاعه فيه `amount` ومبيكتبش `price`) هيقع في أي اشتراك جديد من لحظة الـ migration، والـ rollback هيرجّعك لكود واقع. الحل expand/contract في [95](95-zero-downtime-db-migrations.md).

## 6) الـ Deploy

### 6.1 النقل من ستاك Recreate (مرة واحدة)

```bash
sudo su - ec2-user
cd /opt/student-app/src && git pull --ff-only
export APP_IMAGE="$(cat /opt/student-app/CURRENT_RELEASE)"

# الـ proxy محتاج بورت 80 → وقّف app بتاع ستاك Recreate (downtime قصير لمرة واحدة)
docker compose -f docker-compose.prod.yml stop app
docker compose -f docker-compose.prod.yml rm -f app

cd deploy/ec2/lb
SKIP_PULL=true bash bin/init.sh "$APP_IMAGE"
bash bin/status.sh
```

> - ممكن compose يعيد إنشاء container الـ `mysql` لأن تعريفه في `lb/docker-compose.yml` مختلف شوية (healthcheck interval) — الداتا في الـ volume فبتفضل. ولو طلع warning عن orphan containers فده من ستاك Recreate.
> - شغّل السكريبتات بـ `bash bin/...` عشان لو الـ executable bit ضاع وقت الـ commit من Windows.

### 6.2 جهّز release جديد

```bash
cd /opt/student-app/src
SHA=$(git rev-parse --short HEAD)
docker build -f docker/Dockerfile --build-arg APP_VERSION="$SHA" -t "student-app:$SHA" .
# أو نفس الكود بـ release id جديد (زي ci-v2 في الـ CI):
docker build -f docker/Dockerfile --build-arg APP_VERSION=v2 -t student-app:v2 .
```

### 6.3 Blue/Green مع القياس

Terminal على جهازك:

```bash
bash deploy/scripts/probe.sh http://<ELASTIC_IP>/ready 120 0.1
```

Terminal على السيرفر:

```bash
cd /opt/student-app/src/deploy/ec2/lb
SKIP_PULL=true bash ../../scripts/with-probe.sh -- bash bin/bluegreen.sh student-app:v2
bash bin/status.sh
```

المفروض: `with-probe.sh` يطبع `✔ command exit=0 as expected, availability within budget` (`MAX_FAILURES=0` افتراضي)، والـ probe بتاع جهازك `failed : 0` و `answered by` فيه الإصدارين (`blue` ثم `green`).

### 6.4 على GitHub Actions (من غير EC2 ومن غير Docker محلي)

الـ job **Zero-downtime scripts (single host)** في [`lab-integration.yml`](../../../.github/workflows/lab-integration.yml) بيعمل نفس الحاجة على runner:

```yaml
env:
  APP_ENV_FILE: ${{ github.workspace }}/.lab/app.env      # بدل render-env-from-ssm.sh
  MYSQL_ENV_FILE: ${{ github.workspace }}/.lab/mysql.env
  SKIP_PULL: "true"
  LB_HTTP_PORT: "80"
steps:
  - run: bash $LB/init.sh student-app:ci-v1
  - run: |
      bash $PROBE -- bash $LB/bluegreen.sh student-app:ci-v2
      curl -fsS http://localhost/ready | grep -q '"version":"ci-v2"'
  - run: |
      bash $PROBE -- bash $LB/rollback.sh
      curl -fsS http://localhost/ready | grep -q '"version":"ci-v1"'
```

```bash
gh workflow run lab-integration.yml --ref devops-lab
gh run watch
gh run view <RUN_ID> --log | grep -E "probe summary|failed|✔|✘" | head -40
```

## 7) التحقق (Verify)

```bash
cd /opt/student-app/src/deploy/ec2/lb
bash bin/status.sh                                  # state + containers + upstream + /ready لكل slot + عبر الـ proxy
cat state/release.env
curl -s http://127.0.0.1/ready | jq '{version,color}'
curl -s http://127.0.0.1:8081/ready | jq -c '{version,color}'
curl -s http://127.0.0.1:8082/ready | jq -c '{version,color}'
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1/metrics        # 404 من الـ proxy
bash ../../scripts/version-split.sh http://127.0.0.1/ready 50            # 100% على الـ live
```

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر | المتوقع |
|---|---|---|
| Release مش ready | `READY_TIMEOUT=30 SLOT_ENV="SRE_FAULT_UNHEALTHY=true" SKIP_PULL=true bash bin/bluegreen.sh student-app:v2` | `app_<idle> not ready after 30s` + logs ثم `traffic is still 100% on <live>`؛ الـ probe = 0 failures |
| Release مش بيقوم | `SLOT_ENV="SRE_FAULT_BOOT_FAIL=true" SKIP_PULL=true bash bin/bluegreen.sh student-app:v2` | بيقع في خطوة **الـ migrate** نفسها (الـ one-off container بيقرا `state/<idle>.env` والـ entrypoint بيرفض يقوم): `migrations failed with ...` ثم نفس رسالة الـ die |
| صفحات بتطلع 500 | `SLOT_ENV="SRE_FAULT_ERROR_RATE=1" SKIP_PULL=true bash bin/bluegreen.sh student-app:v2` | `smoke test failed: app_<idle> /login` ثم die — الـ smoke test مسك اللي الـ health checks مش هتمسكه |
| الـ live نفسه واقع | `bash -c 'source bin/lib.sh; load_state; MODE=rolling; save_state'` (محاكاة state مش single) + `docker compose -f docker-compose.yml --env-file state/release.env stop app_<live>` ثم `bluegreen.sh` | `ensure_single_live` بيرفض: `live color <x> is not ready — inspect with bin/status.sh`. رجّع: `start app_<live>` وبعدين `MODE=single` بنفس الطريقة |
| أخطاء جزئية | `SLOT_ENV="SRE_FAULT_ERROR_RATE=0.3" ...` | الـ smoke (request واحد) بينجح غالباً → switch → 30% من الصفحات 500 للمستخدمين. **Blue/green مفيهوش metric gate** — ده سبب [24](24-canary-single-host.md) |
| nginx config بايظ | `cp state/nginx/routing.conf /tmp/r.bak && echo 'location / {' > state/nginx/routing.conf && docker compose -f docker-compose.yml --env-file state/release.env exec -T proxy nginx -t` | `nginx -t` يفشل — والسكريبتات بتعمل die قبل الـ reload. رجّع `/tmp/r.bak` |

بعد أي تمرين: `bash bin/status.sh` — الـ `ACTIVE` لازم يكون لسه القديم في كل حالات الفشل.

## 9) الرجوع (Rollback)

```bash
cd /opt/student-app/src/deploy/ec2/lb
bash ../../scripts/with-probe.sh -- bash bin/rollback.sh
bash bin/status.sh
```

`rollback.sh` بيقرا الـ `MODE` من `state/release.env` ويتصرف حسبه ("undo the last change, whatever the strategy was"):

| `MODE` | يعني إيه | `rollback.sh` بيعمل |
|---|---|---|
| `single` (بعد blue/green أو canary اتعمله promote) | لون واحد live | يحوّل للون **التاني**: فوري لو شغال (`KEEP_OLD=true`)؛ لو متوقف (`KEEP_OLD=false`) يعمل `start_slot` بـ `SKIP_MIGRATE=true` الأول. بيرفض لو اللون التاني متعلّم `BROKEN`، وبيعمل `wait_ready` + `smoke` قبل التحويل. لو أي حاجة فشلت: die والـ traffic مكانه |
| `canary` / `ab` / `shadow` | تجربة شغالة أو اتقطعت (Ctrl+C) | 100% يرجع لـ `ACTIVE` (لازم يكون ready) و `MODE=single` — "experiment cancelled"، والـ slot التاني بيفضل شغال للتحقيق |
| `rolling` | الـ slotين على الإصدار الجديد | يعيد `rolling.sh` بـ `PREVIOUS_IMAGE` (اللي سجّله الـ rolling) و `SKIP_MIGRATE=true` ([25](25-rolling-single-host.md)) |

- في `single`: تشغيله مرتين = roll-forward تاني.
- في كل الحالات بيطبع warning إن **الـ migrations مش بترجع**.

> 🛡️ **بعد deploy فاشل `rollback.sh` بقى آمن:** أي slot بيفشل في `start_slot` (migrate / ready / smoke)، أو canary اتعمله abort، بيتسجّل في الـ state كـ `BROKEN=<color>`. `rollback.sh` في `MODE=single` بيرفض يقلب لـ slot متعلّم `BROKEN` ("nothing to roll back to")، وكمان بيعمل `smoke` (`/up` و `/ready` و `/login`) على اللون اللي راجع له قبل ما يحوّل الـ traffic. الـ marker بيتمسح أول ما نفس اللون ينجح في deploy جديد.

## 10) المسح (Teardown) ⚠️

```bash
cd /opt/student-app/src/deploy/ec2/lb
docker compose -f docker-compose.yml --env-file state/release.env down      # الـ volume بيفضل
# للرجوع لستاك Recreate:
cd /opt/student-app/src && export APP_IMAGE="$(cat /opt/student-app/CURRENT_RELEASE)"
docker compose -f docker-compose.prod.yml up -d --wait
```

ولو خلصت: teardown الـ EC2 من [20 §10](20-ec2-compose-console.md). `rm -rf state/` لو عايز تبدأ من الصفر.

## 11) التكلفة (Cost)

| Resource | السعر التقريبي (راجع صفحة الأسعار) |
|---|---|
| نفس host سيناريو 20 (`t3.small`) | ~$0.65/يوم |
| لو كبّرت لـ `t3.medium` | ~$0.0416/ساعة ≈ $1/يوم + IPv4 + EBS |
| الـ slot القديم شغال (`KEEP_OLD=true`) | RAM بس — نفس الـ instance |

## 12) أسئلة Interview

<details><summary>Blue/green على host واحد مقابل blue/green حقيقي بـ ALB و 2 ASGs؟</summary>

نفس الفكرة (deploy على idle، test، switch، instant rollback)، بس الـ host الواحد single point of failure، والـ proxy نفسه محتاج maintenance، والـ capacity محدودة بالـ box. على AWS: target groups (blue/green) و listener switch أو weighted forward ([45](45-bluegreen-two-asgs.md))، أو CodeDeploy/ECS native. التمن: ضعف الـ capacity وقت الـ deploy.

</details>

<details><summary>إزاي nginx reload مش بيقطع requests؟</summary>

الـ master process بيقرا الـ config الجديدة، يعمل workers جديدة بيها، ويبعت للقديمة إشارة graceful shutdown: تبطّل تقبل connections جديدة وتكمّل اللي معاها لحد ما تخلص (أو `worker_shutdown_timeout` لو متحدد). الـ listening socket نفسه مش بيتقفل، فمفيش لحظة refused.

</details>

<details><summary>ليه الـ migrations أكبر خطر في blue/green؟</summary>

لأن الكود القديم بيشتغل على الـ schema الجديد في الفترة بين الـ migrate والـ switch، وبعد الـ switch طول ما القديم موجود للـ rollback. أي drop/rename/NOT NULL من غير default بيكسر القديم، والـ rollback بيبقى rollback لكود مش شغال. الحل: expand/contract على كذا release، والـ destructive changes بعد ما الـ rollback window يخلص.

</details>

<details><summary>إيه اللي بتختبره على الـ idle قبل الـ switch؟</summary>

عندنا: readiness (DB) و smoke على `/up` و `/ready` و `/login` مباشرة على `127.0.0.1:<port>`. في production كمان: synthetic transactions (login، create، read)، و contract tests، وممكن traffic داخلي/QA على الـ idle بـ header. الـ health checks لوحدها مش كفاية (fault الـ error rate بيعدّي منها).

</details>

<details><summary>القديم تسيبه شغال قد إيه بعد الـ switch؟</summary>

trade-off بين تكلفة الـ capacity الزيادة وسرعة الـ rollback. عملياً لحد ما الـ metrics الأساسية (error rate، latency، business KPIs) تستقر — دقايق لساعات، أو لحد الـ deploy الجاي. `KEEP_OLD=true` بيديك rollback في ثانية؛ `false` بيوفّر RAM بس الـ rollback بيبقى start + ready.

</details>

<details><summary>إيه اللي ممكن يبوظ مع sessions و long-lived connections وقت الـ switch؟</summary>

لو الـ sessions في ملفات/ذاكرة الـ container المستخدمين هيعملوا logout — عشان كده DB/Redis. الـ WebSockets/SSE على الـ workers القديمة بتفضل لحد ما تتقفل (أو `worker_shutdown_timeout`)، فلازم الـ client يعمل reconnect. وأي caches محلية أو jobs في الـ container القديم لازم تخلص قبل ما يتوقف (drain).

</details>

## 13) Checklist

- [ ] نقلت من ستاك Recreate لستاك `lb` من غير ما الداتا تضيع
- [ ] عملت blue/green بـ `with-probe.sh` و 0 failed requests
- [ ] عملت rollback فوري وفهمت إنه mode-aware (single / canary·ab·shadow / rolling) وليه متشغّلوش بعد deploy فاشل
- [ ] جرّبت الـ break-it وتأكدت إن الـ traffic مبيتحوّلش لما الـ release فاشل
- [ ] شغّلت الـ job في `lab-integration.yml` وقريت النتيجة
- [ ] عملت teardown أو رجعت لستاك Recreate
