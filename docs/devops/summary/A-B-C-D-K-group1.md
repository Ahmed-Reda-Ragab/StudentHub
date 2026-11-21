### 01 — نبذة عن كل tool بنستخدمها

**الهدف:** تعرف كل أداة بتحل مشكلة إيه وبتقعد فين في الـ pipeline، وبديلها إيه.

| الأداة | بنستخدمها في إيه (السيناريوهات) |
|---|---|
| Docker · Compose · buildx | build/run الـ image، 3 compose files (local/CI، Recreate، `lb`)، multi-arch (10–27) |
| serversideup/php (FPM + S6) | base image: `www-data` 82، بورت 8080، `SIGQUIT`، `AUTORUN` (10–11) |
| nginx | جوه الـ image + LB قدام الـ slots: weights، `split_clients`، `mirror`، graceful reload (23–26) |
| MySQL 8.4 / RDS | container على EC2 (20–27) ثم RDS (41) |
| GitHub Actions | `ci.yml` · `lab-integration.yml` · `lint-infra.yml`، و OIDC لـ AWS (30–34) |
| Terraform | bootstrap + modules + stacks، state في S3 بـ native lock (21، 90–92) |
| Ansible · Packer | configuration على EC2 · Golden AMI (21، 33، 43، 47) |
| EC2 · ALB · ASG | من سيرفر واحد لـ scale + instance refresh (20–27، 42–48) |
| ECR | registry، tags immutable = git SHA (30+) |
| SSM (Session Manager · Parameter Store) | دخول من غير SSH + مصدر الـ secrets `/student-app/<env>/...` (20، 32، 64) |
| ECS Fargate · EKS | orchestration managed (50–58، 61–6A) |
| Helm · Argo CD · Argo Rollouts | packaging · GitOps · canary analysis على K8s (65–69) |
| Prometheus · Grafana · Loki | metrics (APCu)، dashboards، logs (12، 70–73) |
| CloudWatch · SNS | logs/metrics/alarms → rollback وتنبيهات (42، 46، 70–73) |
| k6 | load tests؛ الـ thresholds = الـ SLOs (74) |
| Trivy · Syft · cosign | scan، SBOM، توقيع keyless (11، 30، 82) |

**التحقق:** تقدر تشرح لكل أداة بديلها وليه اخترناها · **Gotchas:** • ثبّت النسخ (images، actions بالـ SHA، Terraform lock file) • tags الـ GitHub Actions بتتحرك (حادثة Trivy مارس 2026) · **التكلفة:** الأدوات مجانية؛ الفلوس في موارد AWS

### 03 — تجهيز الجهاز (WSL2، Docker، Ansible، Terraform، kubectl، helm، k6)

**الهدف:** Windows 11 + WSL2 Ubuntu فيه كل أدوات المعمل، ومسار كامل من غير Docker محلي عن طريق GitHub Actions.

**أهم الأوامر:**
```bash
wsl --install -d Ubuntu-24.04                                    # PowerShell كـ Administrator
curl -fsSL https://get.docker.com -o /tmp/get-docker.sh && sudo sh /tmp/get-docker.sh   # اختياري
aws configure sso && aws sso login --profile lab
gh workflow run lab-integration.yml --ref devops-lab            # المعمل على runner بدل جهازك
gh run watch && gh run view --log-failed
```
**التحقق:** `aws sts get-caller-identity --profile lab` · `terraform version` (≥ 1.11) · `kubectl version --client` · **Gotchas:** • اشتغل في `~/src` مش `/mnt/c` • حدّد RAM بـ `.wslconfig` • الـ exec bit بيضيع مع commit من Windows → `bash script.sh` · **التكلفة:** مجاني

### 10 — تحويل التطبيق لـ container (Dockerfile + Compose + MySQL)

**الهدف:** image multi-stage (vendor → assets → runtime) بتشتغل محلياً وفي الـ CI وعلى AWS بنفس الشكل، والـ config من env بس.

**أهم الأوامر:**
```bash
export APP_KEY=base64:$(openssl rand -base64 32)
docker compose up -d --build --wait
docker compose run --rm app php artisan migrate --force
docker compose run --rm app php artisan db:seed --class=DemoSeeder --force
curl -s http://localhost:8080/ready          # login: demo@example.com / password
```
**التحقق:** `/up` = 200، `/ready` = `{"status":"ready",...,"version":"<sha>"}`، `docker compose exec app id` → `uid=82` · **Gotchas:** • متغيرات الـ compose بـ `LAB_` عشان متتخانقش مع `.env` بتاع Laravel • `AUTORUN_LARAVEL_MIGRATION=false` — الـ migrate خطوة منفصلة • Faker في `require` (قرار معمل عشان الـ seed)، و `bootstrap/cache/*.php` مستبعد في `.dockerignore` · **التكلفة:** مجاني

### 11 — تقوية الـ image (non-root، الحجم، multi-arch، SBOM، Trivy، cosign)

**الهدف:** image non-root، صغيرة، amd64 + arm64، متفحوصة ومعاها SBOM وموقّعة، وبتتحدّث بـ bot.

**أهم الأوامر:**
```bash
docker run --rm --entrypoint id student-app:local                          # uid=82
trivy image --severity HIGH,CRITICAL --ignore-unfixed student-app:local
syft student-app:local -o spdx-json > sbom.spdx.json
docker buildx build --platform linux/amd64,linux/arm64 -f docker/Dockerfile -t <ECR_REPO>:<SHA7> --push .
cosign sign --yes <ECR_REPO>@sha256:<DIGEST>
git ls-remote --tags https://github.com/aquasecurity/trivy-action | grep 0.36.0   # SHA للـ pin
```
**التحقق:** `docker buildx imagetools inspect` فيه `linux/amd64` و `linux/arm64`؛ `cosign verify` بالـ identity والـ issuer · **Gotchas:** • الـ tags بتتحرك (76 من 77 tag لـ `trivy-action` اتعملها hijack في مارس 2026) → pin بالـ full SHA • version tags بتاعة serversideup مش بتتعمل rebuild → bump بـ bot (Dependabot مع `ARG` في `FROM` محتاج تحقق) • وقّع وتحقّق بالـ digest مش الـ tag · **التكلفة:** مجاني؛ ECR ~$0.10/GB/شهر

### 20 — EC2 + Docker Compose + MySQL container، build على السيرفر (Console)

**الهدف:** التطبيق على الإنترنت بإيدك: SG (80 بس)، IAM role، SSM params، EC2 AL2023 بـ user-data، EIP، Session Manager.

**أهم الأوامر:**
```bash
aws ssm put-parameter --name /student-app/lab/app/APP_KEY --type SecureString --value "base64:$(openssl rand -base64 32)"
# على السيرفر (Session Manager → sudo su - ec2-user):
cd /opt/student-app && git clone https://github.com/Ahmed-Reda-Ragab/StudentHub.git src
cd src && git switch devops-lab
bash deploy/ec2/render-env-from-ssm.sh                       # → app.env / mysql.env (chmod 600)
bash deploy/ec2/deploy-build-on-server.sh devops-lab
APP_IMAGE=$(cat /opt/student-app/CURRENT_RELEASE) docker compose -f docker-compose.prod.yml run --rm --no-deps app php artisan db:seed --class=DemoSeeder --force
```
**التحقق:** `curl http://<EIP>/ready` بيرجّع نفس الـ SHA اللي في `CURRENT_RELEASE`؛ `/sre-lab/*` = 403 من غير `X-Lab-Token` · **Gotchas:** • السكريبت افتراضياً `master` — ادّيله `devops-lab` • `/metrics` مكشوف على :80 (مفيش nginx في ستاك Recreate) → SG "My IP" أو `METRICS_TOKEN` • الـ EIP بيتحاسب حتى وهو مش مربوط — release في الـ teardown · **التكلفة:** ~$0.65/يوم (`t3.small` + 20GB gp3 + IPv4)

### 22 — Recreate وقياس الـ downtime

**الهدف:** تقيس فجوة الـ Recreate بالأرقام وتحوّلها لـ error budget.

**أهم الأوامر:**
```bash
bash deploy/scripts/probe.sh http://<EIP>/ready 180 0.2                        # من جهازك
.\deploy\scripts\probe.ps1 -Url http://<EIP>/ready -Seconds 180 -IntervalMs 200  # PowerShell
export APP_IMAGE="$(cat /opt/student-app/CURRENT_RELEASE)"                       # على السيرفر
MAX_FAILURES=100000 bash deploy/scripts/with-probe.sh -- \
  docker compose -f docker-compose.prod.yml up -d --no-deps --force-recreate --wait app
```
**التحقق:** الـ summary: `failure window` (الـ downtime الحقيقي) + `availability` + `answered by` (version قديمة ← جديدة) · **Gotchas:** • Docker مش بيمنع traffic عن container مش healthy — `--wait` مش بيقلل الـ downtime • الـ timeouts بتقلل العينات → صدّق الـ window مش العدد • 99.5% = 216 دقيقة/شهر؛ 10 deploys/يوم × 10s ≈ 23% منها · **التكلفة:** نفس 20

### 23 — Blue/Green على سيرفر واحد (nginx switch)

**الهدف:** deploy على الـ slot الـ idle، اختباره من غير traffic، وswitch بـ graceful reload بـ 0 failed requests ورجوع فوري.

**أهم الأوامر:**
```bash
cd /opt/student-app/src && docker build -f docker/Dockerfile --build-arg APP_VERSION=v2 -t student-app:v2 .
cd deploy/ec2/lb
SKIP_PULL=true bash bin/init.sh student-app:<SHA>              # أول مرة (بعد إيقاف app بتاع Recreate)
SKIP_PULL=true bash ../../scripts/with-probe.sh -- bash bin/bluegreen.sh student-app:v2
bash bin/status.sh
bash ../../scripts/with-probe.sh -- bash bin/rollback.sh
```
**التحقق:** `with-probe` يطبع `✔ ... availability within budget` (0 failures)، و `/ready` عبر الـ proxy بيرجّع الـ `"color"` الجديد · **Gotchas:** • فشل قبل الـ switch (migrate/ready/smoke) → `traffic is still 100% on <live>` والـ slot بيتسجّل `BROKEN` — `rollback.sh` يرفض يحوّل له • `rollback.sh` mode-aware: single → اللون التاني (بعد ready + smoke)، canary/ab/shadow → 100% لـ `ACTIVE`، rolling → `PREVIOUS_IMAGE` • الـ migrations مش بترجع → expand/contract (95) · **التكلفة:** نفس 20 (`t3.medium` ~$1/يوم لو الـ RAM ضاقت)

### 24 — Canary على سيرفر واحد (weights + metric gate + auto-abort)

**الهدف:** 10 → 25 → 50 → 100% للإصدار الجديد مع حكم من `/metrics` بتاعه بعد كل خطوة و auto-abort (exit 2).

**أهم الأوامر:**
```bash
cd /opt/student-app/src && bash deploy/scripts/probe.sh http://localhost/login 0 0.05   # traffic (terminal تاني)
cd /opt/student-app/src/deploy/ec2/lb
STEPS="10 25 50 100" STEP_SECONDS=60 MAX_ERROR_RATE=0.01 SKIP_PULL=true bash bin/canary.sh student-app:v2
SLOT_ENV="SRE_FAULT_ERROR_RATE=0.5" STEPS="25 100" STEP_SECONDS=20 MIN_REQUESTS=5 SKIP_PULL=true \
  bash bin/canary.sh student-app:v2; echo "exit=$?"                                  # 2 دايماً
cat state/release.env                                   # ACTIVE=<stable> MODE=single BROKEN=<canary>
```
**التحقق:** exit `0` = promoted، `2` = aborted (pre-traffic أو الـ gate أو مفيش traffic) والـ traffic 100% على الـ stable · **Gotchas:** • الـ gate = Δ5xx/Δtotal على صفحات حقيقية (من غير `sre-lab.*`/`health.ready`/`up`)، وبيبعت `METRICS_TOKEN` من `app.env` • traffic قليل = حكم ضعيف (0 errors في n → حد أعلى ~3/n)؛ `MIN_REQUESTS` • latency مش في الـ gate (5xx بس) · **التكلفة:** نفس 20

### 25 — Rolling update بأكتر من replica

**الهدف:** الـ slotين في الـ pool؛ واحد واحد: `down` → drain → recreate → ready → يرجع، والـ capacity عمرها ما توصل صفر.

**أهم الأوامر:**
```bash
cd /opt/student-app/src/deploy/ec2/lb
DRAIN_SECONDS=5 SKIP_PULL=true bash ../../scripts/with-probe.sh -- bash bin/rolling.sh student-app:v2
grep -E '^(MODE|PREVIOUS_IMAGE)=' state/release.env      # rolling + الإصدار اللي اتبدّل
SKIP_PULL=true bash ../../scripts/with-probe.sh -- bash bin/rollback.sh   # rolling تاني لـ PREVIOUS_IMAGE
```
**التحقق:** 8081 و 8082 على نفس الـ version، و `version-split.sh` ~50/50 بين blue و green · **Gotchas:** • الـ capacity أثناء كل خطوة = (N-1)/N = 50% هنا • slot فشل → الـ peer ياخد 100% (`ACTIVE=peer`، `MODE=single`)، الفاشل بيتسجّل `BROKEN` و `rollback.sh` يرفض يحوّل له؛ صلّح وأعد `rolling.sh` • أي slot الـ image بتاعته مختلفة عن الـ live بيتعمله restart قبل الـ pool؛ الـ migrate مع أول slot بس · **التكلفة:** نفس 20

### 26 — A/B testing و Shadow traffic و Feature flags

**الهدف:** تفصل الـ deploy عن الـ release: A/B لمستخدمين sticky، shadow لـ GET بس والرد بيترمي، و feature flags (Pennant كتمرين).

**أهم الأوامر:**
```bash
cd /opt/student-app/src/deploy/ec2/lb
SKIP_PULL=true bash bin/ab-test.sh student-app:v2 30
curl -s -H "X-Variant: <VARIANT_COLOR>" http://127.0.0.1/ready | jq -r .color
for i in $(seq 1 200); do curl -s -A "user-$i" http://127.0.0.1/ready | jq -r .color; done | sort | uniq -c
bash bin/ab-test.sh stop
SKIP_PULL=true bash bin/shadow.sh student-app:v2 && bash bin/shadow.sh stop
composer require laravel/pennant                 # تمرين اختياري — مش متثبت في الـ repo
```
**التحقق:** كل رد فيه `X-Variant` و `Set-Cookie: ab_variant=`؛ في shadow عدّاد `health.ready` على الـ shadow slot بيزيد والرد دايماً من الـ live · **Gotchas:** • `split_clients` على `remote_addr+UA` → نفس الجهاز = bucket واحد • GET مش آمن 100% في الـ shadow هنا (sessions في الداتابيز، `sync.notifications` بيكتب) • `rollback.sh` في `MODE=ab|shadow` = إلغاء التجربة (100% لـ `ACTIVE`) · **التكلفة:** نفس 20؛ AppConfig (اختياري) سنتات

### 30 — CI على GitHub Actions (tests، scans، ECR بـ OIDC)

**الهدف:** Pint + tests (SQLite و MySQL) + audit + hadolint → build مرة واحدة → smoke + Trivy + SBOM → push لـ ECR بـ OIDC من غير keys.

**أهم الأوامر:**
```bash
gh variable set AWS_REGION --body us-east-1
gh variable set AWS_ROLE_ARN --body "$(terraform -chdir=infra/terraform/bootstrap output -raw github_ci_role_arn)"
gh variable set ECR_REPOSITORY --body student-app
gh workflow run ci.yml --ref devops-lab && gh run watch
aws ecr describe-images --repository-name student-app --image-ids imageTag=<SHA7>
```
**التحقق:** كل الـ jobs خضرا (الـ audit report-only)، الـ image في ECR بالـ SHA بعد push على `master`/`main`، والـ trust policy فيها `aud` و `sub=repo:Ahmed-Reda-Ragab/StudentHub:ref:refs/heads/master` · **Gotchas:** • trust policy من غير شرط `sub` = أي repo ياخد الـ role • الـ push بيتخطى لو الـ SHA tag موجود (immutable) — محتاج `ecr:DescribeImages` • `pull_request` من غير paths filter عشان الـ required checks تتبعت دايماً · **التكلفة:** مجاني للـ public repo؛ ECR ~$0.10/GB/شهر

### 95 — Database migrations من غير downtime (expand/contract)

**الهدف:** كل migration تشتغل مع الكود القديم والجديد: expand → backfill (batches) → contract، و roll forward بدل `down()`.

**أهم الأوامر:**
```bash
php artisan migrate --pretend && php artisan migrate:status
mysql student_app -e "SET SESSION lock_wait_timeout=5; ALTER TABLE students ADD COLUMN mobile VARCHAR(20) NULL, ALGORITHM=INSTANT;"   # expand
mysql student_app -e "SELECT section, COUNT(*) FROM students GROUP BY section;"   # تحقق قبل الـ contract
docker compose run --rm app php artisan migrate --force      # مرة واحدة لكل release، مش عند الـ boot
```
**التحقق:** الـ migration expand بس، الكود N-1 شغال على الـ schema الجديد، و `migrate:status` من غير Pending · **Gotchas:** • `add_pricing_to_subscriptions_table` (NOT NULL + drop `amount` في خطوة واحدة) بيكسر الكود القديم في الـ window وفي الـ rollback • `--isolated` مع `CACHE_STORE=database` بيقع على DB فاضية (`cache_locks` لسه مش موجود) • حتى INSTANT محتاج metadata lock → `lock_wait_timeout` صغير · **التكلفة:** مجاني؛ RDS snapshots بالـ GB
