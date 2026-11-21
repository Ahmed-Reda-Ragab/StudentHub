# 10 — تحويل التطبيق لـ container (Dockerfile + Compose + MySQL)

> **الهدف في سطر:** تفهم الـ Dockerfile بتاعنا stage بـ stage، والـ `docker-compose.yml`، وتشغّل التطبيق + MySQL محلياً (WSL) **أو** على GitHub Actions، بمبادئ الـ 12-factor.
> **المستوى:** Beginner → Intermediate · **الوقت:** ~3 ساعات · **التكلفة التقريبية:** مجاني
> **بيعتمد على:** [01 — الأدوات](01-tools-primer.md) · [03 — تجهيز الجهاز](03-workstation-setup.md) · **الملفات في الـ repo:** [`docker/Dockerfile`](../../../docker/Dockerfile) · [`docker-compose.yml`](../../../docker-compose.yml) · [`.dockerignore`](../../../.dockerignore) · [`docker/php/zz-student-app.ini`](../../../docker/php/zz-student-app.ini) · [`docker/entrypoint.d/2-sre-boot-fault.sh`](../../../docker/entrypoint.d/2-sre-boot-fault.sh)

## 1) الفكرة (Concepts)

الـ container image = **artifact واحد immutable** فيه الكود + الـ dependencies + الـ runtime. نفس الـ image بالظبط بيشتغل على جهازك، وفي الـ CI، وعلى EC2/ECS/EKS — اللي بيتغيّر بس هو الـ **env** (config). ده أساس كل اللي جاي في المعمل.

| المصطلح | المعنى |
|---|---|
| Multi-stage build | كذا `FROM` في Dockerfile واحد؛ الـ stage الأخير بس هو اللي بيتشحن، فأدوات البناء (node، dev deps) مش بتوصل للـ runtime |
| Build context | الفولدر اللي بيتبعت للـ builder — `.dockerignore` بيصغّره ويمنع الأسرار |
| Layer cache | كل instruction = layer؛ لو المدخلات متغيرتش بتتاخد من الـ cache. الترتيب = سرعة |
| 12-factor | منهجية لتطبيقات cloud-native (config في env، logs على stdout، stateless...) |
| Healthcheck | أمر Docker بيحدد الـ container `healthy` ولا لأ — compose بيستخدمه في `depends_on` و `--wait` |
| Liveness vs Readiness | `/up` = الـ process عايش (من غير DB) · `/ready` = يقدر يخدم (DB ping) |

## 2) المعمارية (Architecture)

```text
                 docker/Dockerfile (multi-stage)
 ┌──────────────────────────┐  ┌──────────────────────────┐
 │ 1) vendor                │  │ 2) assets                │
 │ serversideup/php (same   │  │ node:22-alpine           │
 │ as runtime)              │  │ npm ci (ignore-scripts)  │
 │ composer install --no-dev│─►│ vite build (Tailwind     │
 │ dump-autoload --optimize │  │ scans app/Enums + vendor │
 └────────────┬─────────────┘  │ pagination views)        │
              │ /var/www/html  └────────────┬─────────────┘
              ▼                             │ public/build
 ┌──────────────────────────────────────────▼─────────────┐
 │ 3) runtime: serversideup/php:8.3-fpm-nginx-alpine      │
 │  S6 (PID 1) ─► php-fpm + nginx :8080   user www-data 82│
 │  + APCu (metrics)  + entrypoint.d/2-sre-boot-fault.sh  │
 │  AUTORUN: optimize ✔  migrate ✘  storage:link ✘        │
 └────────────────────────────────────────────────────────┘

 docker-compose.yml (project "student-app")
   app :8080 ──► mysql:8.4 (volume mysql-data, 127.0.0.1:33060)
   [--profile redis] redis:7.4     [--profile tools] adminer 127.0.0.1:8090
```

## 3) المتطلبات (Prerequisites)

- [ ] [03](03-workstation-setup.md) خلصان: إما Docker جوه WSL (مسار B/C) أو هتشتغل على GitHub Actions (مسار A).
- [ ] الـ repo في `~/src/StudentHub` على branch `devops-lab`.
- الأدوات: `docker` · `docker compose` · `openssl` · `curl` · `gh` (لمسار A)

## 4) الطريقة الأولى: AWS Console (يدوي)

مفيش AWS في السيناريو ده — كله محلي أو على GitHub runners. نفس الـ image هيشتغل على EC2 في [20 — EC2 + Docker Compose (Console)](20-ec2-compose-console.md).

## 5) الطريقة التانية: as Code — الـ Dockerfile والـ Compose سطر بسطر

### 5.1 ليه `serversideup/php` fpm-nginx؟

| القرار | السبب | الـ trade-off |
|---|---|---|
| nginx + PHP-FPM في container واحد (S6 بيراقبهم) | deploy unit واحد، بورت واحد، health واحد — مناسب لـ EC2/ECS/K8s من غير sidecar | مش "process واحد لكل container"، بس S6 بيعمل supervise صح |
| `www-data` **UID/GID 82** (Alpine) | non-root افتراضياً | أي volume متركّب لازم يكون writable لـ 82؛ في K8s `runAsUser: 82` |
| بورت **8080** | الـ non-root ميقدرش يعمل bind على بورت < 1024 | الـ host/LB بيعمل map ‏(`80:8080`) |
| `STOPSIGNAL SIGQUIT` | ده الـ graceful stop لـ PHP-FPM (و nginx): يخلّص الـ requests الشغالة | لازم `stop_grace_period` (30s) أكبر من أطول request |
| `AUTORUN_*` | الـ image بيعمل `php artisan optimize` (config/route/view/event cache) **عند تشغيل الـ container** بالـ env الحقيقي | الأوتوميشن بتجري مع **أي** container حتى `docker compose run`، فلازم نقفل الـ migrations |
| `install-php-extensions` و Composer جاهزين | تثبيت `apcu` في سطر | — |

### 5.2 Stage 1 — `vendor`

```dockerfile
FROM ${PHP_IMAGE} AS vendor
COPY --chown=www-data:www-data composer.json composer.lock ./
RUN composer install --no-dev --no-scripts --no-autoloader --prefer-dist --no-interaction --no-progress
COPY --chown=www-data:www-data . .
RUN composer dump-autoload --optimize --no-dev --no-interaction
```

- **نفس الـ PHP image بتاع الـ runtime** → نفس الـ extensions ونفس نسخة PHP، فـ `composer` platform checks بتطابق اللي هيشتغل فعلاً.
- `composer.json/lock` بيتنسخوا **لوحدهم الأول** → طول ما الـ lock متغيرش، layer الـ `composer install` (الأتقل) جاية من الـ cache حتى لو غيّرت كود.
- `--no-scripts --no-autoloader` لأن الكود لسه مش موجود؛ بعد `COPY . .` بنعمل `dump-autoload --optimize` اللي بيشغّل `post-autoload-dump` → `package:discover` (مش محتاج `.env`).
- `--no-dev`: Boost و Pint و PHPUnit مش بيدخلوا الـ image. (الـ Faker استثناء متعمّد — في `require` عشان الـ seeders؛ شوف §6.1.)

### 5.3 Stage 2 — `assets`

```dockerfile
FROM ${NODE_IMAGE} AS assets
COPY package.json package-lock.json .npmrc ./
RUN npm ci --no-audit --no-fund
COPY vite.config.js ./
COPY resources ./resources
COPY app/Enums ./app/Enums
COPY --from=vendor /var/www/html/vendor/laravel/framework/src/Illuminate/Pagination/resources/views ./vendor/...
RUN npm run build
```

- [`.npmrc`](../../../.npmrc) فيه `ignore-scripts=true` → مفيش `postinstall` scripts بتجري وقت الـ build (حماية supply-chain).
- Tailwind v4 بيعمل scan للملفات عشان يطلّع الـ CSS classes المستخدمة بس. الـ classes موجودة كمان في `app/Enums` (ألوان الـ badges) وفي pagination views بتاعة Laravel، فلازم الملفات دي تكون موجودة جوه الـ stage، وإلا الـ CSS هيطلع ناقص **من غير أي error**.
- الـ output (`public/build`) بس هو اللي بيتنقل للـ runtime؛ `node_modules` بتتساب.

### 5.4 Stage 3 — `runtime`

```dockerfile
USER root
RUN install-php-extensions apcu
COPY docker/php/zz-student-app.ini /usr/local/etc/php/conf.d/zz-student-app.ini
COPY docker/entrypoint.d/ /etc/entrypoint.d/
USER www-data
COPY --chown=www-data:www-data --from=vendor /var/www/html /var/www/html
COPY --chown=www-data:www-data --from=assets /app/public/build /var/www/html/public/build
```

- **APCu**: الـ Prometheus counters (`/metrics`) لازم تكون مشتركة بين كل الـ PHP-FPM workers في الـ container. APCu = shared memory جوه الـ container، والـ app بيستخدم adapter `APCng` من `promphp/prometheus_client_php` ([`RequestMetrics.php`](../../../app/Support/Metrics/RequestMetrics.php)). من غيره كل worker هيعدّ لوحده والأرقام هتبقى عشوائية.
- [`zz-student-app.ini`](../../../docker/php/zz-student-app.ini): `expose_php = Off`، `apc.shm_size = 32M`، و `apc.enable_cli = 0` (أوامر `artisan` مش بتشوف APCu، فالـ metrics بترجع لـ `InMemory` في الـ CLI — طبيعي).
- `USER root` لحظة واحدة للتثبيت وبعدين `USER www-data` قبل نسخ الكود → الملفات ملك 82 والـ process non-root.
- [`2-sre-boot-fault.sh`](../../../docker/entrypoint.d/2-sre-boot-fault.sh): لو `SRE_FAULT_BOOT_FAIL=true` الـ entrypoint يخرج بـ 1 → release "مش بيقوم" (لتمارين ECS circuit breaker و CrashLoopBackOff).

### 5.5 الـ ENV defaults (كلها تتغيّر وقت التشغيل)

| ENV | القيمة | ليه |
|---|---|---|
| `APP_ENV` / `APP_DEBUG` | `production` / `false` | آمن افتراضياً — مفيش stack traces للمستخدم |
| `APP_VERSION` | build arg (= git SHA) | بيظهر في `/ready` و `/metrics` و `/sre-lab/version` |
| `LOG_CHANNEL=stderr` + `LOG_STDERR_FORMATTER=JsonFormatter` | logs JSON على stderr | 12-factor: Docker/CloudWatch/Loki بياخدوها من غير ملفات |
| `METRICS_STORAGE=apcu` | APCu | شوف فوق |
| `PHP_OPCACHE_ENABLE=1` | OPcache | مقفول افتراضياً في serversideup عشان الـ dev |
| `HEALTHCHECK_PATH=/up` | الـ healthcheck الداخلي للـ image يتأكد إن Laravel نفسه بيقوم | مش بس nginx |
| `TRUSTED_PROXY=local` | الـ nginx الداخلي يرجّع IP العميل الحقيقي | |
| `AUTORUN_ENABLED=true` | `php artisan optimize` عند الـ boot | |
| `AUTORUN_LARAVEL_MIGRATION=false` | **ممنوع** migrations مع كل replica ([CONVENTIONS §2](../CONVENTIONS.md)) | الـ migrations خطوة منفصلة مرة لكل release |
| `AUTORUN_LARAVEL_STORAGE_LINK=false` | مفيش uploads على disk محلي | |

ومعاهم OCI `LABEL`s (`version`، `revision`، `created`، `source`) و `EXPOSE 8080` و `STOPSIGNAL SIGQUIT`.

### 5.6 الـ `.dockerignore` — ليه كل سطر مهم

- `.env` و `.env.*` و `auth.json`: **الأسرار مش بتدخل الـ image أبداً** — الـ config من env وقت التشغيل.
- `vendor`، `node_modules`، `public/build`: بتتبني جوه الـ image (لو دخلت من جهازك هتجيب dev deps أو binaries Windows).
- `bootstrap/cache/*.php`: الملفات دي (`packages.php`، `services.php`) اتولّدت على جهازك **وفيها dev providers زي Boost**. لو دخلت الـ image (اللي مفيهوش dev deps) هيطلع `Class "Laravel\Boost\..." not found` عند أول request.
- `tests`، `docs`، `infra`، `k8s`، `deploy`، `docker-compose*.yml`... : مش محتاجينها في الـ runtime، وتغييرها مايبوّظش الـ cache.

### 5.7 الـ `docker-compose.yml`

```yaml
name: student-app
x-app-env: &app-env
    APP_ENV: ${LAB_APP_ENV:-production}
    APP_KEY: ${APP_KEY:?APP_KEY is required - ...}
    DB_PASSWORD: ${LAB_DB_PASSWORD:-student-secret}
    SESSION_DRIVER: ${LAB_SESSION_DRIVER:-database}
    ...
```

- **ليه البادئة `LAB_`؟** `docker compose` بيقرا تلقائياً ملف `.env` اللي في الفولدر عشان الـ interpolation — وده **نفس `.env` بتاع Laravel** (فيه `APP_ENV=local`، `DB_HOST=127.0.0.1`، `DB_PASSWORD=`...). لو الـ compose استخدم `${DB_PASSWORD}` كان هياخد قيم Laragon المحلية. البادئة بتفصل الاتنين. الاستثناء المقصود: `APP_KEY` (ممكن تعيد استخدام بتاع `.env`). خلي بالك إن `SRE_LAB_ENABLED` و `METRICS_ENABLED` و `SRE_FAULT_*` و `LOADTEST_*` و `APP_VERSION` من غير بادئة — لو حطيتهم في `.env` بتاع Laravel هيأثروا على الـ compose.
- **`app`**: `build` من `docker/Dockerfile` + `image: ${LAB_IMAGE:-student-app:local}` (في الـ CI بنحط `LAB_IMAGE=student-app:ci-v1` و `--no-build`)، بورت `${LAB_APP_PORT:-8080}:8080`، `depends_on: mysql: condition: service_healthy`، healthcheck `wget .../up` كل 5s (12 retry، `start_period` 20s)، `stop_grace_period: 30s`.
- **`mysql`**: `mysql:8.4` بـ `utf8mb4_unicode_ci`، volume `mysql-data`، البورت على `127.0.0.1:${LAB_DB_PORT:-33060}` بس (مش مفتوح على الشبكة)، healthcheck `mysqladmin ping` (الـ `$$` عشان compose ميعملش interpolation لـ `$MYSQL_ROOT_PASSWORD`).
- **Profiles**: `--profile redis` (sessions/cache في Redis، [49](49-redis-sessions-cache.md)) و `--profile tools` (adminer على `127.0.0.1:8090`).
- `QUEUE_CONNECTION: sync` و `APP_TIMEZONE: Africa/Cairo` و `APP_LOCALE: ar`.

### 5.8 الـ 12-factor في المعمل ده

| Factor | عندنا |
|---|---|
| Config | كله env؛ مفيش `.env` جوه الـ image |
| Backing services | `DB_HOST=mysql` → يبقى RDS endpoint بتغيير env بس (41) |
| Build, release, run | build = image بـ SHA؛ release = image + env؛ run = container |
| Processes (stateless) | sessions/cache في DB أو Redis، مش ملفات |
| Port binding | 8080 |
| Disposability | boot سريع + `SIGQUIT` graceful |
| Dev/prod parity | نفس الـ image محلي/CI/EC2/ECS/EKS |
| Logs | JSON على stderr |
| Admin processes | `docker compose run --rm app php artisan migrate --force` |

## 6) الـ Deploy

### 6.1 محلياً (WSL + Docker)

```bash
cd ~/src/StudentHub
export APP_KEY=base64:$(openssl rand -base64 32)        # أو: php artisan key:generate --show
export APP_VERSION=$(git rev-parse --short HEAD)
docker compose up -d --build --wait
docker compose run --rm app php artisan migrate --force
docker compose run --rm app php artisan db:seed --class=DemoSeeder --force
```

افتح `http://localhost:8080` وادخل بـ **`demo@example.com` / `password`**.

> 💡 **ليه الـ seeding بيشتغل جوه image مبنية بـ `--no-dev`؟** `DemoSeeder` و `LoadTestSeeder` بيستخدموا `User::factory()` و `fake()`، فـ `fakerphp/faker` اتنقل لـ `require` في [`composer.json`](../../../composer.json) (مش `require-dev`). ده **قرار للمعمل**: محتاجين داتا تجريبية جوه نفس الـ image على EC2 و ECS و K8s وفي الـ CI. الـ trade-off: الـ image فيها package زيادة (حجم + سطح CVEs)، وأي حد عنده shell على الـ container يقدر يشغّل seeders. في production حقيقي الـ image مش بتشيل Faker ولا seeders تجريبية؛ الـ seed بيبقى job منفصل من image مخصوصة (أو مفيش seed أصلاً)، والـ reference data بتتعمل بـ migrations.

بيانات الـ load test (للـ k6):

```bash
LOADTEST_USERS=5 LOADTEST_STUDENTS_PER_USER=20 docker compose run --rm app php artisan db:seed --class=LoadTestSeeder --force
```
(المستخدمين `loadtest1@example.com` … بنفس الباسورد `password`، والـ seeder idempotent.)

### 6.2 على GitHub Actions (من غير Docker محلي)

الـ job `compose` في [`lab-integration.yml`](../../../.github/workflows/lab-integration.yml) بيعمل نفس الخطوات بالظبط:

```yaml
env: { LAB_IMAGE: student-app:ci-v1, APP_VERSION: ci-v1, LOADTEST_USERS: "5", LOADTEST_STUDENTS_PER_USER: "20" }
- run: echo "APP_KEY=base64:$(openssl rand -base64 32)" >> "$GITHUB_ENV"
- run: docker compose up -d --no-build --wait app mysql
- run: |
    docker compose exec -T app php artisan migrate --force
    docker compose exec -T app php artisan db:seed --class=DemoSeeder --force
    docker compose exec -T app php artisan db:seed --class=LoadTestSeeder --force
```

```bash
gh workflow run lab-integration.yml --ref devops-lab
gh run watch
gh run view --log-failed
```

> الفرق: الـ CI بيستخدم `exec` في الـ container الشغال، وأنا محلياً بستخدم `run --rm` (container مؤقت بنفس الـ image). الاتنين صح؛ `run --rm` أنضف لأنه مش بيعتمد إن الـ app شغال.

## 7) التحقق (Verify)

```bash
docker compose ps                                   # app و mysql: healthy
curl -s http://localhost:8080/up -o /dev/null -w '%{http_code}\n'      # 200
curl -s http://localhost:8080/ready                 # {"status":"ready","checks":{"database":"ok"},"version":"...","color":"none"}
curl -s http://localhost:8080/sre-lab/version
curl -s http://localhost:8080/metrics | grep student_app_app_info
docker compose exec app id                          # uid=82(www-data)
docker compose exec app php -m | grep -i apcu
docker compose logs app --tail=5                    # JSON lines
docker inspect --format '{{.Config.StopSignal}} {{.Config.User}}' student-app:local
```

## 8) اكسرها (Break it): تمرين على الأعطال

نفس الـ drills اللي في `lab-integration.yml`، بس محلياً:

| التمرين | الأمر | المتوقع |
|---|---|---|
| SRE lab مقفول | `SRE_LAB_ENABLED=false docker compose up -d --no-build --wait app` | `/sre-lab/ping` = 404 و `/ready` لسه 200 |
| Release مش healthy | `SRE_FAULT_UNHEALTHY=true docker compose up -d --no-build app` (من غير `--wait`، لأن الـ healthcheck هيفشل) | `/up` = 500، `/ready` = 503، `docker compose ps` = unhealthy |
| Release مش بيقوم | `SRE_FAULT_BOOT_FAIL=true docker compose run --rm --no-deps app php -v` | exit ≠ 0 والرسالة `refusing to start` |
| Bad release (errors) | `SRE_FAULT_ERROR_RATE=0.5 docker compose up -d --no-build --wait app` ثم `for i in $(seq 20); do curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/login; done \| sort \| uniq -c` | ~نص الـ requests 500، و `/up` و `/ready` **ناجحين** (الـ health checks مش هتكشفه) |
| الداتابيز وقعت | `docker compose stop mysql` | `/up` = 200 و `/ready` = 503 — ده بالظبط الفرق بين liveness و readiness |

رجّع كل حاجة: `docker compose up -d --no-build --wait` (من غير الـ env الزيادة).

## 9) الرجوع (Rollback)

الـ image بـ tag = SHA، فالـ rollback = شغّل الـ tag القديم:

```bash
docker images student-app --format '{{.Tag}}  {{.CreatedSince}}'
LAB_IMAGE=student-app:<OLD_TAG> docker compose up -d --no-build --wait app
curl -s http://localhost:8080/ready
```

> الـ migrations مش بترجع لوحدها. عشان كده لازم تكون backward compatible — [95](95-zero-downtime-db-migrations.md).

## 10) المسح (Teardown) ⚠️

```bash
docker compose down                 # الداتابيز تفضل في volume student-app_mysql-data
docker compose down -v              # ⚠️ يمسح الداتابيز كمان
docker image prune -f
```

## 11) التكلفة (Cost)

| Resource | السعر التقريبي |
|---|---|
| محلي | مجاني |
| GitHub Actions (`lab-integration.yml`) | مجاني للـ public repo؛ دقائق من الـ quota للـ private |

## 12) أسئلة Interview

<details><summary>ليه multi-stage؟ وإيه اللي بيفرق في حجم وأمان الـ image؟</summary>

أدوات البناء (node/npm، Composer dev deps، headers) مش بتوصل للـ runtime، فالـ image أصغر والـ attack surface أقل (مفيش npm ولا dev packages فيها ثغرات تتحسب عليك). كمان كل stage له cache مستقل، فتغيير CSS مش بيعيد `composer install`.

</details>

<details><summary>ليه الـ migrations مش بتجري عند الـ boot؟</summary>

لو عندك 4 replicas هيجروا 4 مرات في نفس الوقت (race على جدول `migrations`)، وأي replica بتعمل restart هتحاول تعمل migrate. الأخطر: الـ migration بتحصل والـ traffic شغال على replicas قديمة. الصح: خطوة واحدة متحكّم فيها لكل release (compose `run --rm`، ECS one-off task، K8s Job/Helm hook) قبل ما الكود الجديد ياخد traffic.

</details>

<details><summary>إيه مشكلة `latest`؟</summary>

Mutable: مش عارف إيه اللي شغال فعلاً، والـ rollback مستحيل تثبته، وكل node ممكن تسحب نسخة مختلفة. بنستخدم git SHA (immutable، وECR مقفول على IMMUTABLE tags) فأي container تعرف بالظبط اتبنى من أنهي commit.

</details>

<details><summary>ليه APCu للـ metrics؟ وإيه البديل؟</summary>

PHP-FPM بيشغّل workers منفصلين ومفيش memory مشتركة بين الـ requests. Prometheus بيعمل scrape لـ endpoint واحد، فلازم counters مشتركة على مستوى الـ container: APCu (shared memory، سريع، بيتصفّر مع الـ restart — ده مقبول لأن Prometheus بيتعامل مع counter resets). البدائل: Redis storage (مشترك بين containers بس بيضيف dependency وlatency)، أو StatsD/OTel exporter.

</details>

<details><summary>إيه اللي بيحصل لما `docker stop` يتبعت للـ container؟</summary>

Docker بيبعت الـ `STOPSIGNAL` (عندنا `SIGQUIT`) لـ PID 1 (S6) اللي بيوصّله لـ FPM و nginx فيخلّصوا الـ requests الشغالة ويقفلوا. لو معدّاش `stop_grace_period` (30s) بيبعت `SIGKILL`. لو كنا سبنا `SIGTERM` الـ FPM كان هيقطع الـ requests فوراً → 502 وقت كل deploy.

</details>

<details><summary>الـ config cache بيتعمل إمتى؟ وليه ده مهم؟</summary>

عند تشغيل الـ container (`AUTORUN_ENABLED` → `php artisan optimize`) بالـ env الحقيقي، مش وقت الـ build. لو عملته وقت الـ build كنت هتحبس env الـ build جوه الـ image. ونتيجة كده: تغيير env يحتاج **recreate** للـ container (`docker compose up -d`)، مش `restart` (الـ env بتاع الـ container ثابت من وقت ما اتعمل).

</details>

## 13) Checklist

- [ ] فاهم كل stage في الـ Dockerfile وليه الترتيب كده
- [ ] شغّلت الـ stack محلياً **أو** على `lab-integration.yml` وشفت الـ job أخضر
- [ ] عملت migrate + seed ودخلت بـ `demo@example.com`
- [ ] جرّبت الـ break-it الخمسة وفهمت ليه `/ready` بيفرق عن `/up`
- [ ] عملت rollback بـ `LAB_IMAGE=<old tag>`
- [ ] عملت `docker compose down`
