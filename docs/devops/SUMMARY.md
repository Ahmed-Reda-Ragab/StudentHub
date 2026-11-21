# StudentHub DevOps / SRE Lab — الملخص الشامل

> الملخص ده بيجمع **كل السيناريوهات** في مكان واحد عشان تراجع بسرعة: الهدف، أهم الأوامر، إزاي تتأكد، والـ gotchas، والتكلفة.
> التفاصيل الكاملة لكل سيناريو في ملفه في `docs/devops/scenarios/`. الـ HANDBOOK.pdf فيه كل السيناريوهات كاملة.

## المعمل في سطور

مشروع Laravel حقيقي (Students Subscriptions) بنستخدمه معمل لكل طرق الـ deploy على AWS. كل سيناريو بيتعمل **مرتين**: مرة من الـ **Console** ومرة بـ **Terraform + Ansible**. الـ CI/CD موجود على **GitHub Actions** وعلى **CodeBuild/CodePipeline/CodeDeploy**، ومعاه كل أنواع الـ **zero-downtime deployment**، ومفاهيم **SRE** بتتقاس بجد.

```text
A. الأساسيات (01–03)
   │
B. Containers (10–12) ──► C. EC2 سيرفر واحد (20–27) ──► D. CI/CD (30–37)
                                   │                          │
                                   ▼                          ▼
                        E. EC2 على نطاق أكبر (40–49) ◄────────┘
                                   │
            ┌──────────────────────┼──────────────────────┐
            ▼                      ▼                      ▼
     F. ECS (50–58)      G. Kubernetes/EKS (60–6A)   H. Observability & SRE (70–77)
            └──────────────────────┼──────────────────────┘
                                   ▼
        I. Security (80–83) · J. IaC deep dives (90–93) · K. Wrap-up (95–99)
```

## إزاي تستخدم الملخص

1. ابدأ بـ **01** (الأدوات) و **02/03** (الحساب والجهاز).
2. كل كارت فيه أهم أوامر السيناريو. التفاصيل والـ Console click-path في ملف السيناريو.
3. **مفيش Docker على جهازك؟** اعمل push على branch، وتابع:
   - `ci.yml`
   - `lab-integration.yml`: compose و k6 والـ zero-downtime scripts
   - `k8s-integration.yml`: kind و Helm و Argo Rollouts
   - `lint-infra.yml`
4. أي سيناريو فيه موارد AWS: **Teardown فوراً** بعد ما تخلص. راجع كارت **97**.

## مرجع سريع: الـ endpoints والـ SLOs

| Endpoint | الاستخدام |
|---|---|
| `GET /up` | Liveness (من غير DB) |
| `GET /ready` | Readiness (DB ping)، بيرجّع `version` و `color` |
| `GET /metrics` | Prometheus (`METRICS_ENABLED`، و `METRICS_TOKEN` اختياري) |
| `/sre-lab/{ping,version,latency,error,cpu,memory,db,db/heavy,unready,ready}` | load/chaos. بيرجّع 404 لو `SRE_LAB_ENABLED` مش `true`، والـ header `X-Lab-Token` مطلوب لو الـ token متحدد |

| Bad release (env) | مين يكشفه |
|---|---|
| `SRE_FAULT_ERROR_RATE=0.5` | canary analysis / burn-rate alerts |
| `SRE_FAULT_LATENCY_MS=800` | latency SLO |
| `SRE_FAULT_UNHEALTHY=true` | health checks → rollback |
| `SRE_FAULT_BOOT_FAIL=true` | circuit breaker / CrashLoopBackOff |

**الـ SLOs:**

- **Availability:** 99.5% على 30 يوم. الـ error budget حوالي 3 ساعات و36 دقيقة.
- **Latency:** 95% من الـ requests أقل من 300ms، والـ p99 أقل من 1s.

**الـ Burn-rate alerts:**

| السرعة | النوافذ | الإجراء |
|---|---|---|
| 14.4× | 1h و 5m | page |
| 6× | 6h و 30m | page |
| 1× | 3d و 6h | ticket |

# A. الأساسيات

## 01 — نبذة عن كل tool بنستخدمها

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

---

## 02 — تجهيز حساب AWS (MFA، Identity Center، Budgets، CLI، bootstrap)

**الهدف:** root مقفول بـ MFA، دخول يومي بـ Identity Center و `aws configure sso`، Budgets/anomaly/billing alarm، وبعدين bootstrap (state bucket، OIDC roles، ECR، CodeConnections) وتوصيل GitHub.

**أهم الأوامر:**
```bash
aws configure sso && aws sso login --sso-session student && export AWS_PROFILE=student-lab-admin
cd infra/terraform/bootstrap && terraform init && terraform apply
terraform output -raw backend_hcl > ../backend.hcl     # + uncomment backend "s3" في versions.tf
terraform init -migrate-state -backend-config=../backend.hcl && terraform plan   # No changes
terraform output -json github_repository_variables | jq -r 'to_entries[] | "\(.key) \(.value)"' \
  | while read -r k v; do gh variable set "$k" --body "$v"; done
aws codeconnections get-connection --connection-arn "$(terraform output -raw codeconnections_arn)" --query Connection.ConnectionStatus
```
**التحقق:** `aws sts get-caller-identity` = `AWSReservedSSO_*` · الـ connection `AVAILABLE` · `gh variable list` فيها 8 قيم · **Gotchas:** • Identity Center لازم **organization instance** (الـ account instance مافيهوش permission sets) • الـ CodeConnections بيتعمل PENDING ومحتاج handshake في الـ Console • required reviewers على الـ private repos محتاجة Enterprise · **التكلفة:** < $1/شهر

---

## 03 — تجهيز الجهاز (WSL2، Docker، Ansible، Terraform، kubectl، helm، k6)

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

# B. الـ Containers

## 10 — تحويل التطبيق لـ container (Dockerfile + Compose + MySQL)

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

---

## 11 — تقوية الـ image (non-root، الحجم، multi-arch، SBOM، Trivy، cosign)

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

---

## 12 — SRE lab endpoints + Prometheus/Grafana محلي + k6
**الهدف:** تعرف كل `/sre-lab/*` endpoint بيجاوب على أنهي سؤال، تعمل bad release بالـ env بس، وتشغّل ستاك الـ observability جنب التطبيق.
**أهم الأوامر:**
```bash
export APP_KEY=base64:$(openssl rand -base64 32) && docker compose up -d --build --wait
docker compose -f observability/compose/docker-compose.yml up -d          # بعد الـ app (network student-app_default)
curl -s localhost:8080/sre-lab/error?rate=1\&code=503 -o /dev/null -w '%{http_code}\n'
SRE_FAULT_ERROR_RATE=0.3 docker compose up -d --no-build --wait app        # /ready يفضل 200
curl -s localhost:8080/metrics | grep student_app_app_info
k6 run -e BASE_URL=http://localhost:8080 -e LOADTEST_USERS=5 loadtest/k6/smoke.js
gh workflow run lab-integration.yml --ref devops-lab
```
**التحقق:** Prometheus → Targets: `app:8080` UP · Grafana (localhost:3000) فيه الـ 3 dashboards · **Gotchas:** • الستاك قبل الـ app = external network error • الـ faults محتاجة `SRE_LAB_ENABLED=true` (ما عدا BOOT_FAIL) • كل `up` = عدادات APCu من صفر · **التكلفة:** مجاني

# C. EC2 — سيرفر واحد

## 20 — EC2 + Docker Compose + MySQL container، build على السيرفر (Console)

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

---

## 21 — نفس الحاجة بـ Terraform + Ansible

**الهدف:** stack `20-ec2-single` (VPC + EC2 + EIP + IAM + backups bucket + SSM params بـ `APP_KEY` متولّد) ثم Ansible: dynamic inventory و `provision.yml` و `deploy.yml` idempotent.

**أهم الأوامر:**
```bash
cd infra/terraform/stacks/20-ec2-single && terraform init -backend-config=../../backend.hcl && terraform apply
$(terraform output -raw ssm_start_session)
cd ../../../ansible && ansible-galaxy collection install -r requirements.yml
export ANSIBLE_EXTRA="-e ssm_bucket_name=$(terraform -chdir=../terraform/bootstrap output -raw ansible_ssm_bucket)"
ansible-inventory --graph && ansible role_app -m ping $ANSIBLE_EXTRA
ansible-playbook playbooks/provision.yml $ANSIBLE_EXTRA
ansible-playbook playbooks/deploy.yml -e app_image=<acct>.dkr.ecr.us-east-1.amazonaws.com/student-app:<sha> $ANSIBLE_EXTRA   # مرتين → changed=0
```
**التحقق:** `curl http://<EIP>/ready` = version الـ tag · التشغيل التاني `changed=0` · **Gotchas:** • الـ secrets في الـ Terraform state • `ansible.cfg` بيتجاهل في `/mnt/c` • `key_name` على instance شغال = replacement · **التكلفة:** ~$0.03/ساعة

---

## 22 — Recreate وقياس الـ downtime

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

---

## 23 — Blue/Green على سيرفر واحد (nginx switch)

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

---

## 24 — Canary على سيرفر واحد (weights + metric gate + auto-abort)

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

---

## 25 — Rolling update بأكتر من replica

**الهدف:** الـ slotين في الـ pool؛ واحد واحد: `down` → drain → recreate → ready → يرجع، والـ capacity عمرها ما توصل صفر.

**أهم الأوامر:**
```bash
cd /opt/student-app/src/deploy/ec2/lb
DRAIN_SECONDS=5 SKIP_PULL=true bash ../../scripts/with-probe.sh -- bash bin/rolling.sh student-app:v2
grep -E '^(MODE|PREVIOUS_IMAGE)=' state/release.env      # rolling + الإصدار اللي اتبدّل
SKIP_PULL=true bash ../../scripts/with-probe.sh -- bash bin/rollback.sh   # rolling تاني لـ PREVIOUS_IMAGE
```
**التحقق:** 8081 و 8082 على نفس الـ version، و `version-split.sh` ~50/50 بين blue و green · **Gotchas:** • الـ capacity أثناء كل خطوة = (N-1)/N = 50% هنا • slot فشل → الـ peer ياخد 100% (`ACTIVE=peer`، `MODE=single`)، الفاشل بيتسجّل `BROKEN` و `rollback.sh` يرفض يحوّل له؛ صلّح وأعد `rolling.sh` • أي slot الـ image بتاعته مختلفة عن الـ live بيتعمله restart قبل الـ pool؛ الـ migrate مع أول slot بس · **التكلفة:** نفس 20

---

## 26 — A/B testing و Shadow traffic و Feature flags

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

---

## 27 — Backup لـ MySQL على S3 + تجربة restore

**الهدف:** `mysqldump --single-transaction | gzip | aws s3 cp -` يومي بـ systemd timer، retention بالـ lifecycle، و restore drill بيقيس RPO/RTO.

**أهم الأوامر:**
```bash
BUCKET=$(terraform -chdir=../terraform/stacks/20-ec2-single output -raw backup_bucket)
ansible-playbook playbooks/backup.yml -e backup_bucket=$BUCKET $ANSIBLE_EXTRA
ansible-playbook playbooks/backup.yml -e backup_bucket=$BUCKET -e backup_restore_drill=true $ANSIBLE_EXTRA
systemctl list-timers student-app-mysql-backup.timer && journalctl -u student-app-mysql-backup.service -n 20
aws s3 ls s3://$BUCKET/mysql/ | grep -v '\.partial$' | tail -3   # .partial = backup فشل/شغال
aws s3 cp s3://$BUCKET/<key>.sql.gz - | gunzip | tail -1        # -- Dump completed on ...
BACKUP_BUCKET=$BUCKET /opt/student-app/backup-mysql-to-s3.sh restore s3://$BUCKET/<key>.sql.gz
```
**التحقق:** الـ drill: `Restore drill passed` · RPO = الفشل − آخر backup · RTO = لحد `/ready` 200 · **Gotchas:** • السكريبت بيرفع على `.partial` وبيعمل `s3 mv` بعد النجاح (الـ host يقدر يمسح `*.partial` بس، مش الـ dumps) • الـ bucket بيتمسح مع الـ stack (`force_destroy`) • الـ rollback للكود مايرجّعش الـ schema · **التكلفة:** سنتات

# D. CI/CD

## 30 — CI على GitHub Actions (tests، scans، ECR بـ OIDC)

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

---

## 31 — CD → EC2 بـ SSH + build على السيرفر (الطريقة القديمة)

**الهدف:** تشغّل `deploy-ec2-ssh-build.yml` (ssh → checkout → build → Recreate) وتشرح ليه anti-pattern وإزاي تعمله بأمان لو مضطر.

**أهم الأوامر:**
```bash
aws ec2 create-key-pair --key-name student-app-lab --key-type ed25519 --query KeyMaterial --output text > ~/.ssh/student-app-lab.pem
# terraform.tfvars (stack 20): ssh_cidrs = ["0.0.0.0/0"]  key_name = "student-app-lab"  → apply
gh secret set EC2_SSH_PRIVATE_KEY < ~/.ssh/student-app-lab.pem
gh variable set EC2_HOST --body <EIP> && gh variable set EC2_SSH_KNOWN_HOSTS --body "<EIP> ssh-ed25519 AAAA..."
gh workflow run deploy-ec2-ssh-build.yml --ref devops-lab -f ref=devops-lab
```
**التحقق:** الـ summary فيه downtime بالثواني و `version` = الـ commit · **Gotchas:** • الـ host key من SSM مش `ssh-keyscan` (TOFU) • `key_name` = replacement للـ instance • الـ rollback = rebuild (مش نفس الـ bytes) · **التكلفة:** نفس 20 (`t3.small` إجباري للـ build)

---

## 32 — CD → EC2 بـ ECR + SSM Run Command

**الهدف:** `deploy-ec2-ssm.yml`: tag → digest، سكريبتات الـ commit بـ `git archive`، `ssm send-command` + polling، و CD اختياري بعد الـ CI.

**أهم الأوامر:**
```bash
gh variable set EC2_INSTANCE_ID --body "$(terraform output -raw instance_id)"
gh variable set APP_URL --env lab --body "$(terraform output -raw app_url)"
gh workflow run deploy-ec2-ssm.yml --ref devops-lab -f image_tag=<sha7>
gh variable set EC2_CONTINUOUS_DEPLOY --body true         # opt-in: deploy بعد كل CI ناجح على master
aws ssm list-commands --max-results 1 --query 'Commands[0].[Status,Comment]'
aws logs tail /student-app/lab/ssm-deploy --since 30m
```
**التحقق:** `CURRENT_RELEASE` فيه `@sha256:` و `/ready` version = الـ tag · **Gotchas:** • الـ deploy files لازم committed (git archive) • `workflow_run`/`dispatch` محتاجين الـ workflow على الـ default branch • الـ SendCommand مقفول على tag `Project=student-app` · **التكلفة:** SSM مجاني، `t3.micro` يكفي

---

## 33 — CD → EC2 بـ Ansible

**الهدف:** `deploy-ec2-ansible.yml`: الـ runner controller، aws_ec2 inventory، connection SSM عبر transfer bucket، deploy idempotent.

**أهم الأوامر:**
```bash
gh variable set ANSIBLE_SSM_BUCKET --body "$(terraform -chdir=infra/terraform/bootstrap output -raw ansible_ssm_bucket)"
gh workflow run deploy-ec2-ansible.yml --ref devops-lab -f image_tag=<sha7> -f connection=ssm -f check_mode=true
gh workflow run deploy-ec2-ansible.yml --ref devops-lab -f image_tag=<sha7> -f connection=ssm   # مرتين → changed=0
gh run view <RUN_ID> --log | grep -A3 "PLAY RECAP"
aws ssm describe-sessions --state History --max-results 5
```
**التحقق:** الـ summary فيه PLAY RECAP بـ `changed=0` في التشغيل التاني · **Gotchas:** • الـ instance مش محتاج S3 permission (presigned URLs) • `role_app:&standalone` بيطابق prod و lab لو الاتنين موجودين → زوّد `:&env_lab` • check mode بيتخطّى الـ `command` tasks · **التكلفة:** ~$0 فوق 20

---

## 34 — Environments و approvals و promotion و rollback

**الهدف:** environments `lab`/`production` بـ reviewers و wait timer و branch policy، `release-promote.yml` بنفس الـ digest + release tag، rollback بالـ tag اللي قبله، و DORA.

**أهم الأوامر:**
```bash
gh api -X PUT repos/Ahmed-Reda-Ragab/StudentHub/environments/production --input env-production.json
gh variable set ENV_NAME --env production --body production          # لازم = اسم الـ environment (الـ guard)
gh variable set EC2_INSTANCE_ID --env production --body <PROD_IID>     # instance عليه Env=production + APP_URL
gh workflow run release-promote.yml --ref master -f image_tag=<sha7>   # Actions → Review deployments → Approve
gh workflow run deploy-ec2-canary.yml --ref master -f image_tag=<sha7> -f slot_env=SRE_FAULT_ERROR_RATE=0.5 -f expect_abort=true
git tag -l 'release-*' --sort=-creatordate | head -3
git for-each-ref 'refs/tags/release-*' --format='%(creatordate:format:%G-W%V)' | sort | uniq -c   # deployment frequency
```
**التحقق:** نفس الـ digest في lab و prod + tag `release-<date>-<sha>` · **Gotchas:** • الـ guard بيرفض environment غير lab من غير `ENV_NAME` = اسمه أو instance الـ `Env` tag بتاعه مختلف — بس `APP_URL` ناقص لسه بيعمل fallback لـ lab • الـ OIDC `sub` بتاع environment مافيهوش branch → branch policy إجباري • "Protected branches only" محتاجة branch محمي فعلاً · **التكلفة:** مجاني (+ host production: stack 20 workspace بـ `env=production`)

---

## 35 — AWS CodeBuild (buildspec، webhook، GitHub Actions runners)

**الهدف:** stack 35 (projects `ci`/`image`/`gha-runner`، role لكل project)، الـ buildspecs سطر بسطر، privileged + layer cache، و runner لـ GitHub Actions.

**أهم الأوامر:**
```bash
cd infra/terraform/stacks/35-codebuild && cp terraform.tfvars.example terraform.tfvars   # codeconnections_arn
terraform init -backend-config=../../backend.hcl && terraform apply
aws codebuild start-build --project-name student-app-image --source-version master
aws logs tail /aws/codebuild/student-app-image --follow
aws codebuild batch-get-builds --ids <BUILD_ID> --query 'builds[0].buildStatus'
# workflow: runs-on: codebuild-student-app-gha-runner-${{ github.run_id }}-${{ github.run_attempt }}
```
**التحقق:** report group `student-app-ci-phpunit` + commit status على GitHub + image في ECR (أو `already exists ... skipping`) · **Gotchas:** • `post_build` بيجري حتى لو الـ build فشل (guard) • Docker Hub rate limits على IPs مشتركة • الـ runner job بياخد الـ project role تلقائي · **التكلفة:** ~$0.005/دقيقة (small)، مفيش idle

---

## 36 — AWS CodePipeline

**الهدف:** stack 36: V2 pipeline (Source CodeConnections → Build → [Approve] → [Migrate] + ECS/CodeDeployToECS/CodeBuild) لخدمة stack 50.

**أهم الأوامر:**
```bash
cd infra/terraform/stacks/36-codepipeline && cp terraform.tfvars.example terraform.tfvars   # codeconnections_arn, deploy_mode
terraform -chdir=../50-ecs-fargate output -json pipeline_inputs > stack50.auto.tfvars.json   # gitignored
terraform init -backend-config=../../backend.hcl && terraform apply
aws codepipeline start-pipeline-execution --name student-app-lab-pipeline
aws codepipeline get-pipeline-state --name student-app-lab-pipeline --query 'stageStates[].[stageName,latestExecution.status]'
terraform destroy && cd ../50-ecs-fargate && terraform destroy    # 36 قبل 50
```
**التحقق:** كل الـ stages Succeeded و `/ready` على الـ ALB بالـ version الجديدة · **Gotchas:** • الـ ECS action بياخد task def الخدمة الحالية مش آخر revision Terraform • أعد توليد `stack50.auto.tfvars.json` بعد `CODE_DEPLOY` • docs-only commits مبتشغّلش الـ pipeline · **التكلفة:** ~$0.002/action-minute + CodeBuild (~$0.05/release)

---

## 37 — AWS CodeDeploy لـ EC2/ASG

**الهدف:** CodeDeploy in-place على ASG stack 40 (`codedeploy.tf`: revision bucket + app + group بـ traffic control و alarm)، revision فيها image reference + hooks، و rollback على الفشل/الـ alarms.

**أهم الأوامر:**
```bash
echo 'codedeploy_enabled = true' >> terraform.tfvars && terraform apply     # stack 40: agent + bucket + app/group (instance refresh)
REV_BUCKET=$(terraform output -json codedeploy | jq -r .revision_bucket); terraform output -json codedeploy | jq -r .release
DIR=$(deploy/codedeploy/ec2/package-revision.sh <acct>.dkr.ecr.us-east-1.amazonaws.com/student-app:<sha7>)
aws deploy push --application-name student-app-lab-ec2 --s3-location s3://$REV_BUCKET/codedeploy/student-app-<sha7>.zip --source "$DIR"
aws deploy create-deployment --application-name student-app-lab-ec2 --deployment-group-name student-app-lab-ec2 \
  --s3-location bucket=$REV_BUCKET,key=codedeploy/student-app-<sha7>.zip,bundleType=zip
aws deploy wait deployment-successful --deployment-id <ID>
```
**التحقق:** lifecycle events كلها Succeeded و `/ready` version = الـ tag على كل الـ instances · **Gotchas:** • مفيش GitHub workflow، والـ deploy role مالوش S3 write على الـ revision bucket (CLI/Console بس) • الـ rollback بيرجّع الكود مش الـ SSM config • CodeDeploy مابيحدّثش `/student-app/lab/deploy/blue/IMAGE_URI` (scale-out بيبوت القديم لحد الـ launch hook) · **التكلفة:** CodeDeploy على EC2 مجاني؛ stack 40 ~$0.08/ساعة

# E. EC2 على نطاق أكبر

## 40 — VPC من الصفر
**الهدف:** VPC `10.20.0.0/16` بـ public/private `/20` على 2 AZ، IGW، route tables، S3 gateway endpoint، default SG مقفول — بالـ wizard ثم `modules/network` — وتفهم قرار "من غير NAT".
**أهم الأوامر:**
```bash
cd infra/terraform/stacks/40-ec2-alb-asg && terraform init -backend-config=../../backend.hcl
echo 'cidrsubnet("10.20.0.0/16", 4, 8)' | terraform console        # 10.20.128.0/20 (أول private)
terraform plan -target=module.network -out=net.tfplan && terraform apply net.tfplan
aws ec2 describe-route-tables --filters Name=tag:Project,Values=student-app --query 'RouteTables[].Routes[].[DestinationCidrBlock,GatewayId||NatGatewayId]' --output text
terraform plan -target=module.network -var private_instances=true    # شوف NAT + EIP + routes (متعملش apply)
terraform destroy -target=module.network
```
**التحقق:** الـ public بس فيها `0.0.0.0/0 → igw`، الـ private فيها `local` + `pl-` (S3)، والـ default SG من غير rules · **Gotchas:** • "public" = route للـ IGW، مش الاسم • NACL stateless: الرد على ephemeral ports 1024–65535 • `-target` للتعلم بس · **التكلفة:** مجاني؛ NAT ~$0.045/ساعة لكل واحد + $0.045/GB

---

## 41 — RDS MySQL + نقل الداتا من الـ container
**الهدف:** RDS MySQL 8.4 private/encrypted/PITR بـ parameter group utf8mb4، الـ module بيكتب `DB_*` في SSM، ونقل الداتا بـ freeze → mysqldump → restore عن طريق Session Manager.
**أهم الأوامر:**
```bash
terraform -chdir=infra/terraform/stacks/40-ec2-alb-asg apply -target=module.rds    # أو الـ stack كله
aws ssm get-parameters-by-path --path /student-app/lab/app --query 'Parameters[?contains(Name, `DB_`)].Name'
aws ssm start-session --target <IID> --document-name AWS-StartPortForwardingSessionToRemoteHost --parameters '{"host":["<RDS>"],"portNumber":["3306"],"localPortNumber":["13306"]}'
export MYSQL_PWD=$(aws ssm get-parameter --name /student-app/lab/app/DB_PASSWORD --with-decryption --query Parameter.Value --output text)
gunzip -c student_app.sql.gz | mysql -h 127.0.0.1 -P 13306 -u student student_app
aws rds restore-db-instance-to-point-in-time --source-db-instance-identifier student-app-lab-mysql --target-db-instance-identifier student-app-lab-mysql-pitr --restore-time <UTC>
```
**التحقق:** `PubliclyAccessible=false`، `StorageEncrypted=true`، backup 7 أيام، row counts متطابقة، `/ready` = ready · **Gotchas:** • dump من غير write freeze = data loss صامت • PITR = instance **جديد** بـ endpoint جديد • `use_secrets_manager` مش متعرّض في stack 40 والـ user data بيقرا SSM بس · **التكلفة:** ~$0.016/ساعة + gp3 ≈ $0.5/يوم؛ Multi-AZ ×2

---

## 42 — ALB + ASG + Launch Template + ACM/Route 53
**الهدف:** ALB بـ TGs blue/green (`/ready`، 2/2، dereg 30s) و listener weighted، LT بـ IMDSv2 و user data بيقرا IMAGE_URI من SSM، ASG بـ ELB health (grace/warmup 120)، و HTTPS بـ `domain_name`.
**أهم الأوامر:**
```bash
cd infra/terraform/stacks/40-ec2-alb-asg && cp -n terraform.tfvars.example terraform.tfvars   # image_tag = SHA
terraform plan -out=tfplan && terraform apply tfplan
eval "$(terraform output -raw migrate_command)"
curl -s "$(terraform output -raw app_url)/ready" | jq .
aws elbv2 describe-target-health --target-group-arn "$(terraform output -json target_group_arns | jq -r .blue)" --query 'TargetHealthDescriptions[].TargetHealth.State'
gh variable set ALB_LISTENER_ARN --body "$(terraform output -raw listener_arn)"
```
**التحقق:** 2 targets `healthy`، `/metrics` = 404 من الـ ALB، logs في `/student-app/lab/app` · **Gotchas:** • الـ ALB على host port 80 (`-p 80:8080`) • `/ready` عميق + ELB health = الـ fleet كله يتبدّل لو الـ DB وقعت • الـ seed بـ `docker run --rm` مش `docker exec` (config cached) · **التكلفة:** ≈ $0.08/ساعة ≈ $2/يوم للـ stack

---

## 43 — Golden AMI بـ Packer + Ansible
**الهدف:** AMI فيها Docker + agents بنفس `provision.yml`، تتدّي لـ stack 40 بـ `ami_id` + `golden_ami = true` → instance refresh بـ auto rollback حقيقي (الـ LT اتغيّر).
**أهم الأوامر:**
```bash
cd infra/packer && packer init . && packer validate . && packer build .
AMI=$(jq -r '.builds[-1].artifact_id' manifest.json | cut -d: -f2)
# stack 40 tfvars: ami_id = "<AMI>"  golden_ami = true  → terraform apply
aws autoscaling describe-instance-refreshes --auto-scaling-group-name student-app-lab-blue --max-records 1 --query 'InstanceRefreshes[0].[Status,StatusReason]'
aws ec2 describe-images --owners self --filters Name=tag:Project,Values=student-app --query 'Images[].[ImageId,Name,DeprecationTime]' --output table
aws ec2 deregister-image --image-id <AMI> && aws ec2 delete-snapshot --snapshot-id <SNAP>
```
**التحقق:** `cloud-init-output.log` من غير `dnf install docker`، و boot أسرع (LaunchTime → `boot finished`) · **Gotchas:** • `arch` و root volume (16 ≤ 20) لازم يطابقوا stack 40 • `terraform apply` مبيستناش الـ refresh: بعد auto rollback صلّح `ami_id` قبل أي apply • deregister مبيمسحش الـ snapshot · **التكلفة:** سنتات لكل build + ~$0.05/GB-شهر snapshots

---

## 44 — Rolling بـ ASG Instance Refresh
**الهدف:** release = `put-parameter` IMAGE_URI + `start-instance-refresh` (Min 100 / Max 150، SkipMatching=false، alarms)، يدوي و بـ `deploy-asg.yml strategy=instance-refresh`، والـ rollback بالـ pointer.
**أهم الأوامر:**
```bash
aws ssm put-parameter --name /student-app/lab/deploy/blue/IMAGE_URI --type String --value <REPO>:<SHA> --overwrite
aws autoscaling start-instance-refresh --auto-scaling-group-name student-app-lab-blue --strategy Rolling --preferences '{"MinHealthyPercentage":100,"MaxHealthyPercentage":150,"InstanceWarmup":120,"SkipMatching":false,"AutoRollback":false,"AlarmSpecification":{"Alarms":["student-app-lab-alb-5xx-ratio","student-app-lab-blue-unhealthy-hosts"]}}'
aws autoscaling describe-instance-refreshes --auto-scaling-group-name student-app-lab-blue --max-records 1 --query 'InstanceRefreshes[0].[Status,PercentageComplete]'
gh workflow run deploy-asg.yml -f strategy=instance-refresh -f image_tag=<SHA> -f min_healthy_percentage=100
bash deploy/scripts/probe.sh "$APP_URL/ready" 0 0.2
aws ssm get-parameter-history --name /student-app/lab/deploy/blue/IMAGE_URI --query 'Parameters[-3:].Value'
```
**التحقق:** الـ probe `failed : 0` والإصدارين مخلوطين ثم الجديد بس · **Gotchas:** • Skip matching (default في الـ console) + LT ثابت = مفيش ولا instance اتبدّلت • AWS auto rollback بيرجّع الـ LT مش الـ image → الـ workflow بيرجّع الـ pointer بنفسه • `SRE_FAULT_BOOT_FAIL` في SSM = عطل config: رجوع الـ image مش هيصلّحه · **التكلفة:** نفس 42 + instance زيادة دقايق

---

## 45 — Blue/Green بـ اتنين ASG + listener switch
**الهدف:** green جاهز على الـ release الجديد بوزن 0، switch 100/0 → 0/100 في call واحد و rollback فوري؛ Terraform way (tfvars) أو CI way (`bluegreen-switch` + `listener_weights_managed_externally`).
**أهم الأوامر:**
```bash
# tfvars: green_enabled = true  [listener_weights_managed_externally = true → recreate للـ listener + حدّث ALB_LISTENER_ARN]
terraform apply
aws ssm put-parameter --name /student-app/lab/deploy/green/IMAGE_URI --type String --value <REPO>:<SHA> --overwrite
gh workflow run deploy-asg.yml -f strategy=bluegreen-switch -f image_tag=<SHA> -f bake_seconds=300 -f scale_down_old=false
aws elbv2 modify-listener --listener-arn "$L" --default-actions "[{\"Type\":\"forward\",\"ForwardConfig\":{\"TargetGroups\":[{\"TargetGroupArn\":\"$TGB\",\"Weight\":100},{\"TargetGroupArn\":\"$TGG\",\"Weight\":0}]}}]"
bash deploy/scripts/version-split.sh "$APP_URL/ready" 50
```
**التحقق:** الـ probe بيقلب من `blue` لـ `green` بـ 0 failures، والـ rollback ثانية · **Gotchas:** • من غير `managed_externally` أول `terraform apply` يرجّع الأوزان (drift) • قارن الـ desired بين اللونين قبل الـ switch (الـ idle ممكن يبقى على min) • متعملش `green_enabled = false` و green live → 503 · **التكلفة:** + لون كامل (~$0.75/يوم)؛ `scale_down_old` بيوفّره ويبطّأ الـ rollback

---

## 46 — Canary بـ weighted target groups + alarm rollback
**الهدف:** green 10 → 25 → 50 → 100 مع `CANARY_ALARM_NAME` gate بين الخطوات، و abort أوتوماتيك لـ bad release بـ `SRE_FAULT_ERROR_RATE` على green.
**أهم الأوامر:**
```bash
aws ssm put-parameter --name /student-app/lab/app/SRE_FAULT_ERROR_RATE --type String --value 0.5    # امسحه أول ما green يقوم
gh workflow run deploy-asg.yml -f strategy=canary-weights -f image_tag=<SHA> -f canary_steps="10 25 50 100" -f step_seconds=300
aws ssm delete-parameter --name /student-app/lab/app/SRE_FAULT_ERROR_RATE
bash deploy/scripts/probe.sh "$APP_URL/login" 0 0.05
k6 run -e BASE_URL="$APP_URL" -e CANARY_COLOR=green -e EXPECT_CANARY_PCT=10 -e TOLERANCE_PCT=5 loadtest/k6/canary-watch.js
aws cloudwatch describe-alarms --alarm-names student-app-lab-alb-5xx-ratio --query 'MetricAlarms[0].StateValue'
```
**التحقق:** `canary aborted at 10%: alarm student-app-lab-alb-5xx-ratio - 100% back on blue` · **Gotchas:** • الـ alarm الافتراضي ALB-wide: 10% × 5% errors = 0.5% بيعدّي → per-TG alarm أدق • ALB metrics 1-min + window 5 دقايق = `step_seconds` 300 • الـ stickiness بتكسب على الأوزان؛ وعلى الـ `*_external` listener بتتطبّق وقت الإنشاء بس (بعد كده CLI) · **التكلفة:** نفس 45 (~20+ دقيقة لونين)

---

## 47 — Rolling deploy بـ Ansible (serial + drain)
**الهدف:** in-place على الـ ASG: migrate مرة، suspend processes، لكل instance (serial 1): drain → `docker run --name student-app` → `/ready` → register + `target-in-service`، ثم IMAGE_URI و resume.
**أهم الأوامر:**
```bash
cd infra/ansible && ansible-inventory --graph
TG=$(terraform -chdir=../terraform/stacks/40-ec2-alb-asg output -json target_group_arns)
BUCKET=$(terraform -chdir=../terraform/bootstrap output -raw ansible_ssm_bucket)
ansible-playbook playbooks/rolling-asg.yml -e app_image=<REPO>:<SHA> -e "{\"rolling_target_group_arns\": $TG}" -e ssm_bucket_name=$BUCKET
aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names student-app-lab-blue --query 'AutoScalingGroups[0].SuspendedProcesses'
aws autoscaling resume-processes --auto-scaling-group-name student-app-lab-blue     # لو الـ play وقف
```
**التحقق:** probe = 0 failures، `SuspendedProcesses` فاضية، و re-run = no-op (`end_host`) · **Gotchas:** • credentials بتاعتك (RegisterTargets/SuspendProcesses) مش الـ deploy role • فشل = host بره الـ TG + processes متعلقة (مقصود) • rollback بنفس الـ image القديمة بيعمل `end_host` للـ host المتشال → سجّله بإيدك · **التكلفة:** صفر زيادة (capacity N−1 أثناء الـ roll)

---

## 48 — Autoscaling تحت load
**الهدف:** target tracking على CPU (50%) و ALBRequestCountPerTarget (1000/دقيقة)، `autoscale-cpu.js` على `/sre-lab/cpu` بالـ token، timeline الـ scale-out/in، و Spot بـ mixed instances.
**أهم الأوامر:**
```bash
TOKEN=$(terraform -chdir=infra/terraform/stacks/40-ec2-alb-asg output -raw sre_lab_token)
k6 run -e BASE_URL="$APP_URL" -e LAB_TOKEN="$TOKEN" -e RATE=4 -e CPU_MS=200 -e DURATION=20m loadtest/k6/autoscale-cpu.js
k6 run -e BASE_URL="$APP_URL" -e LOADTEST_USERS=20 -e VUS=60 -e DURATION=15m loadtest/k6/load.js
aws autoscaling describe-scaling-activities --auto-scaling-group-name student-app-lab-blue --max-items 5 --query 'Activities[].[StartTime,Cause]'
aws cloudwatch describe-alarms --alarm-name-prefix TargetTracking-student-app-lab-blue --query 'MetricAlarms[].[AlarmName,StateValue]'
# tfvars: detailed_monitoring = true   (CPU كل دقيقة → CPU policy أسرع، بفلوس)
# tfvars: spot_enabled = true  spot_instance_types = ["t3.micro","t3a.micro","t2.micro"]   (capacity_rebalance بيتفعّل معاه)
```
**التحقق:** `instance serving traffic: <hostname>` في k6، desired بيطلع وبعدين ينزل (أبطأ) · **Gotchas:** • الـ default CPU كل 5 دقايق (`detailed_monitoring = false`) — الـ requests policy أسرع • `t3` standard credits بتخلص → CPU metric مضلل (`CPUCreditBalance`) • Spot = كله Spot (on-demand base 0)؛ الـ base مش متعرّض في stack 40 → `on_demand_base_capacity` في `module "asg_*"` · **التكلفة:** instances زيادة بالثانية؛ Spot خصم ~60–70%

---

## 49 — ElastiCache Redis للـ sessions/cache
**الهدف:** قيس الأول (DB sessions = write لكل صفحة، `db/heavy` = query تقيلة)، فعّل `redis_enabled` (Valkey) + instance refresh، اتأكد من phpredis و `tls://`، `migrate --isolated`، وقارن بالأرقام.
**أهم الأوامر:**
```bash
k6 run -e BASE_URL="$APP_URL" -e VUS=40 -e DURATION=10m -e TEST_ID=db-sessions --summary-export loadtest/results/49-before-load.json loadtest/k6/load.js
k6 run -e BASE_URL="$APP_URL" -e LAB_TOKEN="$TOKEN" -e TARGET=db-heavy -e MAX_RATE=60 -e DURATION=10m loadtest/k6/breakpoint.js
# tfvars: redis_enabled = true [redis_transit_encryption = true] → terraform apply
aws autoscaling start-instance-refresh --auto-scaling-group-name student-app-lab-blue --preferences '{"MinHealthyPercentage":100,"MaxHealthyPercentage":150,"SkipMatching":false}'
aws ssm send-command --instance-ids <IID> --document-name AWS-RunShellScript --parameters 'commands=["docker exec student-app php -m | grep -i redis"]'
docker run --rm valkey/valkey:8 valkey-cli -h <ENDPOINT> -p 6379 INFO keyspace        # على instance
```
**التحقق:** RDS `WriteIOPS` نزل في `load.js`، `db0` keys بتزيد، و `db/heavy` تقريباً زي ما هو · **Gotchas:** • الـ env بيتقري وقت الـ boot: refresh إجباري، والـ fleet المخلوط = logout مرة • `redis_enabled = false` في apply واحد = 500 لحد الـ refresh (رجّع SSM + refresh الأول) • node واحد من غير replica، والـ sessions والـ cache على نفس الـ memory (evictions) · **التكلفة:** Valkey `cache.t4g.micro` ~$0.0128/ساعة ≈ $0.31/يوم

# F. ECS

## 50 — ECS Fargate من الـ Console
**الهدف:** تبني VPC + SGs (ALB→task→RDS) + SSM + roles + cluster + task def `app:8080` + ALB/TG blue + service بإيدك، وmigrations كـ Run task.
**أهم الأوامر:**
```bash
bash deploy/ecs/render-taskdef.sh repo deploy/ecs/task-definition.json > td-console.json   # مع AWS_ACCOUNT_ID/AWS_REGION/ENV_NAME/IMAGE_URI
aws ssm get-parameters-by-path --path /student-app/lab/app --query 'Parameters[].Name'
bash deploy/ecs/run-migrations.sh --cluster student-app-lab --task-definition student-app-lab-app --network-configuration "$NET"
aws ecs describe-services --cluster student-app-lab --services student-app-lab-app --query 'services[0].[runningCount,desiredCount]'
curl -s http://<ALB_DNS>/ready | jq
aws logs tail /ecs/student-app-lab/app --since 10m
```
**التحقق:** `/ready` = `ready` بالـ version الصح، الـ targets `healthy`، و `/metrics` = 404 · **Gotchas:** • الـ migrations قبل الـ service وإلا `/ready` 503 والـ tasks تتبدّل • container healthCheck على `/up` مش `/ready` • تغيير SSM محتاج Force new deployment · **التكلفة:** ≈ $0.11/ساعة (2 tasks + ALB + RDS، من غير NAT)

---

## 51 — ECS Fargate بـ Terraform
**الهدف:** تقرا وتشغّل stack 50 وتفهم الـ ownership: Terraform للـ infra، الـ CI للـ image، الـ autoscaling للـ count، الـ deployer للـ TG.
**أهم الأوامر:**
```bash
cd infra/terraform/stacks/50-ecs-fargate && cp terraform.tfvars.example terraform.tfvars   # image_tag = SHA في ECR
terraform init -backend-config=../../backend.hcl
terraform plan -out=tfplan && terraform apply tfplan
CMD=$(terraform output -raw migration_script_command); (cd ../../../.. && eval "$CMD")
terraform output github_repository_variables
terraform apply -replace=module.ecs.aws_ecs_service.app      # تغيير عائلة الـ strategy/controller بس
terraform destroy                                            # بعد stack 36
```
**التحقق:** `terraform plan` = No changes بعد CI deploy (الـ `ignore_changes` شغال) · **Gotchas:** • `-replace` = downtime ويرجع لـ `image_tag` بتاع الـ tfvars • تعديل env بيوصل مع الـ deploy الجاي بس (و `SRE_FAULT_*` في `app_environment` بتتشال — الـ faults بـ `extra_env`) • من GitHub (`terraform.yml`) لازم repo variable `ECS_IMAGE_TAG` · **التكلفة:** ≈ $2.7/يوم؛ NAT +~$1/يوم

---

## 52 — Migrations كـ one-off task + ECS Exec
**الهدف:** migration مرة لكل release على on-demand بـ exit code يوقف الـ pipeline، و shell جوه الـ task من غير SSH.
**أهم الأوامر:**
```bash
export AWS_REGION=us-east-1 ECS_CLUSTER=student-app-lab ECS_SERVICE=student-app-lab-app
bash deploy/ecs/run-migrations.sh                                   # revision الـ service الحالية
bash deploy/ecs/run-migrations.sh --task-definition "$TD_ARN" --timeout 1800
bash deploy/ecs/ecs-exec.sh -- php artisan migrate:status
bash deploy/ecs/ecs-exec.sh -- wget -qO- http://127.0.0.1:8080/ready
aws ecs describe-tasks --cluster $ECS_CLUSTER --tasks <ID> --query 'tasks[0].containers[].exitCode'
```
**التحقق:** `✔ migrations done` و exit 0؛ `ExecuteCommandAgent` = RUNNING؛ output الـ session في `/ecs/student-app-lab/app` + `ExecuteCommand` في CloudTrail · **Gotchas:** • STOPPED ≠ نجح — الـ `exitCode` هو الحكم • `initProcessEnabled=false` لأن S6 لازم PID 1 • Exec بيتقرر وقت start الـ task؛ والـ session logs بتتكتب بالـ **task role** (`logs:*` على log group الـ app) · **التكلفة:** أقل من سنت لكل one-off task

---

## 53 — Rolling + circuit breaker rollback
**الهدف:** min 100% / max 200%، circuit breaker + rollback، grace period، drain 30s + SIGQUIT، و drills الـ boot-fail والـ unhealthy بـ 0 failures.
**أهم الأوامر:**
```bash
gh workflow run deploy-ecs.yml --ref master -f strategy=rolling -f taskdef_source=live
bash deploy/scripts/probe.sh "$URL/ready" 300 0.2
gh workflow run deploy-ecs.yml --ref master -f strategy=rolling -f run_migrations=false -f extra_env="SRE_FAULT_BOOT_FAIL=true"
gh workflow run deploy-ecs.yml --ref master -f strategy=rolling -f extra_env="SRE_FAULT_UNHEALTHY=true"
aws ecs describe-services --cluster student-app-lab --services student-app-lab-app --query 'services[0].deployments[].[rolloutState,failedTasks]'
bash deploy/ecs/render-taskdef.sh live student-app-lab-app | jq '[.containerDefinitions[0].environment[].name]'   # مفيش SRE_FAULT_*
```
**التحقق:** `rolloutState FAILED` → rollback لـ `COMPLETED`، الـ job أحمر (smoke: version ≠ tag)، و `probe.sh` = `failed : 0` · **Gotchas:** • `run_migrations=false` للـ boot-fail drill بس (غير كده الـ migration step بيوقفه بدري) • الـ `live` render بيشيل `SRE_FAULT_*` — الـ faults مبتتورّثش (`KEEP_FAULT_ENV=true` للعكس) • الـ circuit breaker مش بيشوف error rate (ده شغل الـ alarms) · **التكلفة:** surge دقايق لكل deploy (سنتات)

---

## 54 — Blue/Green و Canary و Linear بـ CodeDeploy
**الهدف:** `CODE_DEPLOY` controller: TGين، prod listener، appspec، deployment configs، alarm rollback، termination wait.
**أهم الأوامر:**
```bash
terraform apply -var deployment_controller=CODE_DEPLOY -var codedeploy_deployment_config_name=CodeDeployDefault.ECSCanary10Percent15Minutes -var use_deployment_alarms=true -replace=module.ecs.aws_ecs_service.app
gh workflow run deploy-ecs.yml --ref master -f strategy=codedeploy -f taskdef_source=live
aws deploy get-deployment --deployment-id <ID> --query 'deploymentInfo.[status,deploymentOverview]'
aws elbv2 describe-listeners --listener-arns "$L" --query 'Listeners[0].DefaultActions[0].ForwardConfig.TargetGroups'
aws deploy stop-deployment --deployment-id <ID> --auto-rollback-enabled
terraform apply -var deployment_controller=ECS -replace=module.ecs.aws_ecs_service.app
```
**التحقق:** الـ weights 100/0 → 90/10 → 0/100 والـ plan = No changes والـ live على green · **Gotchas:** • `update-service --task-definition` مرفوض مع CODE_DEPLOY • الـ listener بيتعمل replace لما `weights_managed_externally` يتغير • نافذة الـ canary لازم أطول من الـ alarm (5 دقايق) · **التكلفة:** CodeDeploy مجاني؛ capacity مضاعفة لحد آخر الـ wait

---

## 55 — ECS native blue/green و linear و canary
**الهدف:** traffic shifting من غير CodeDeploy: alternate TG + production/test listener rules + infrastructure role + bake time.
**أهم الأوامر:**
```bash
terraform apply -var deployment_strategy=CANARY -replace=module.ecs.aws_ecs_service.app   # BLUE_GREEN | LINEAR | CANARY
terraform output deployment
gh workflow run deploy-ecs.yml --ref master -f strategy=native -f taskdef_source=live
aws ecs list-service-deployments --cluster student-app-lab --service student-app-lab-app
curl -s -H 'X-Lab-Target: green' "$URL/ready" | jq .version
k6 run -e BASE_URL="$URL" -e EXPECT_VERSIONS=<OLD>,<NEW> loadtest/k6/canary-watch.js
aws ecs stop-service-deployment --service-deployment-arn "$SD" --stop-type ROLLBACK
```
**التحقق:** الـ lifecycle stages لحد `CLEAN_UP` والـ weights على rule priority 100 · **Gotchas:** • من غير Pause hook نافذة الـ test header ثواني • `ALBRequestCountPerTarget` بيتشال مع الـ strategies دي • `DEPLOY_COLOR=stable` على الكل — قيس بالـ version · **التكلفة:** مجاني؛ green 100% من `SCALE_UP` لحد `CLEAN_UP`

---

## 56 — Capacity providers و Fargate Spot
**الهدف:** `base`/`weight` بين FARGATE و FARGATE_SPOT، الـ Spot interruption والـ graceful shutdown، وإمتى EC2/Graviton.
**أهم الأوامر:**
```bash
aws ecs describe-services --cluster student-app-lab --services student-app-lab-app --query 'services[0].capacityProviderStrategy'
aws ecs describe-tasks --cluster student-app-lab --tasks $(aws ecs list-tasks --cluster student-app-lab --query 'taskArns' --output text) --query 'tasks[].[capacityProviderName,availabilityZone]'
aws ecs update-service --cluster student-app-lab --service student-app-lab-app --desired-count 6
aws ecs stop-task --cluster student-app-lab --task "$SPOT_TASK" --reason "drill: simulated spot interruption"
terraform apply -var use_fargate_spot=false
```
**التحقق:** 6 tasks = 1 FARGATE + 5 SPOT؛ `probe.sh` = 0 failures بعد الـ stop · **Gotchas:** • مفيش fallback أوتوماتيك من Spot لـ on-demand • ARM64 محتاج image multi-arch (الـ CI بيبني amd64) • الـ migrations دايماً على FARGATE · **التكلفة:** Spot ~$0.008/ساعة/task مقابل ~$0.025 on-demand؛ ARM ~20% أرخص

---

## 57 — ECS autoscaling تحت load
**الهدف:** target tracking (CPU 50% + 600 req/min/task)، cooldowns 60/180، capacity math، و SLOs ثابتة أثناء الـ scale-out.
**أهم الأوامر:**
```bash
TOKEN=$(aws ssm get-parameter --name /student-app/lab/app/SRE_LAB_TOKEN --with-decryption --query Parameter.Value --output text)
k6 run -e BASE_URL="$URL" -e LAB_TOKEN="$TOKEN" -e RATE=5 -e CPU_MS=200 -e DURATION=15m loadtest/k6/autoscale-cpu.js
k6 run -e BASE_URL="$URL" -e LOADTEST_USERS=20 -e VUS=50 -e DURATION=10m -e P95_MS=300 loadtest/k6/load.js
aws application-autoscaling describe-scaling-activities --service-namespace ecs --resource-id service/student-app-lab/student-app-lab-app --max-items 5
aws ecs describe-services --cluster student-app-lab --services student-app-lab-app --query 'services[0].[desiredCount,runningCount]'
gh workflow run perf-gate.yml -f base_url="$URL" -f script=autoscale-cpu.js -f duration=15m -f k6_env="RATE=5 CPU_MS=200"
```
**التحقق:** `desired count to 4` خلال ~5 دقايق لـ RATE=5، و k6 `load.js` exit 0 · **Gotchas:** • demand = RATE×CPU_MS/1000 ÷ (0.5×0.5) — RATE=10 = 8 tasks بيخبط في max 6 (RATE≤6 جوه الـ max) • الـ request policy لـ ROLLING بس • الـ DB connections هي الـ bottleneck الجاي · **التكلفة:** أقل من 5 سنت لكل drill

---

## 58 — ECS deploy بـ GitHub Actions مقابل CodePipeline
**الهدف:** نفس الـ release بـ `deploy-ecs.yml` (OIDC) وبـ stack 36 (CodeConnections + CodeBuild + modes ecs/codedeploy-ecs/codebuild) وتقارن التكلفة والـ audit.
**أهم الأوامر:**
```bash
gh workflow run deploy-ecs.yml --ref master -f strategy=rolling -f taskdef_source=live
cd infra/terraform/stacks/36-codepipeline
terraform -chdir=../50-ecs-fargate output -json pipeline_inputs > stack50.auto.tfvars.json
terraform init -backend-config=../../backend.hcl && terraform apply
aws codepipeline start-pipeline-execution --name student-app-lab-pipeline
aws codepipeline put-approval-result --pipeline-name student-app-lab-pipeline --stage-name Approve --action-name Promote --result summary=ok,status=Approved --token "$T"
terraform destroy && terraform -chdir=../50-ecs-fargate destroy     # 36 قبل 50
```
**التحقق:** الاتنين بيوصلوا `rolloutState COMPLETED` و `/ready` بالـ version الجديدة؛ execution history / job summary · **Gotchas:** • الـ `ECS` action بيعمل copy لـ revision الـ service (env Terraform مش واصل) • race بين `ci.yml` و الـ pipeline على نفس الـ tag (IMMUTABLE) • CodeConnections لازم AVAILABLE · **التكلفة:** GHA مجاني (public)؛ CodePipeline V2 ~$0.002/action-min + CodeBuild ~$0.05/release

# G. Kubernetes / EKS

## 60 — Kubernetes محلي على kind (أو على GitHub Actions)
**الهدف:** تفهم الـ objects (Namespace، ConfigMap/Secret، Deployment، Service، StatefulSet، Job، HPA، PDB، NetworkPolicy) بالتطبيق كمثال، plain YAML + kustomize ثم الـ chart، وتقرا `k8s-integration.yml`.
**أهم الأوامر:**
```bash
gh workflow run k8s-integration.yml --ref devops-lab && gh run watch
kind create cluster --config k8s/kind/cluster.yaml
kind load docker-image student-app:ci-v1 student-app:ci-v2 --name student-app-lab
kubectl apply -f k8s/manifests/base/namespace.yaml -f k8s/kind/mysql.yaml
kubectl apply -k k8s/manifests/overlays/kind
helm upgrade --install student-app k8s/helm/student-app -n student-app -f k8s/helm/student-app/values-kind.yaml --set-string image.tag=ci-v1 --wait
curl -s localhost:8088/ready
kind delete cluster --name student-app-lab
```
**التحقق:** `/ready` = `"status":"ready"`، `/login` = 200 (الـ migration hook اشتغل)، و probe الـ RollingUpdate في الـ CI Summary = `failed : 0`.
**Gotchas:**
- الـ plain migrate Job immutable وبيتعمل مع الـ Deployment — استنى `job/student-app-migrate` وامسحه قبل الـ release الجاي.
- `kubectl delete -k` على الـ overlay بيمسح الـ Namespace (و MySQL والـ Secret).
- patch الـ NodePort من غير `protocol: TCP` بيقع بصمت.
**التكلفة:** مجاني.

---

## 61 — EKS من الـ Console و eksctl
**الهدف:** cluster بإيدك مرتين (Console Custom configuration + `eksctl` ClusterConfig)، access entries، add-ons، Pod Identity، وتعرف Auto Mode.
**أهم الأوامر:**
```bash
eksctl create cluster -f /tmp/eksctl-61.yaml --dry-run
eksctl create cluster -f /tmp/eksctl-61.yaml
aws eks update-kubeconfig --region us-east-1 --name student-app-lab-console --alias console
aws eks create-access-entry --cluster-name <CLUSTER> --principal-arn arn:aws:iam::<ACCOUNT_ID>:role/student-app-gha-deploy
aws eks associate-access-policy --cluster-name <CLUSTER> --principal-arn arn:aws:iam::<ACCOUNT_ID>:role/student-app-gha-deploy --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy --access-scope type=cluster
kubectl get nodes -o wide && kubectl get pods -A
helm upgrade --install student-app k8s/helm/student-app -n student-app -f /tmp/values-61.yaml --set-string image.tag=<GIT_SHA> --wait
eksctl delete cluster -f /tmp/eksctl-61.yaml --disable-nodegroup-eviction --wait
```
**التحقق:** الـ cluster `ACTIVE` بـ auth `API` والـ endpoint على IP/32 بتاعك، 2 nodes على AZs مختلفة، والـ pod IPs من `10.60.x.x`.
**Gotchas:**
- eksctl بيعمل NAT gateway افتراضياً — `vpc.nat.gateway: Disable`.
- الـ public subnets لازم auto-assign public IP وإلا الـ nodes مبتعملش join.
- PVC للـ MySQL محتاج EBS CSI add-on + StorageClass default (gp2 مش default في الـ clusters الجديدة).
**التكلفة:** ~$0.20/ساعة (~$4.5–5/يوم) لكل cluster؛ extended support $0.60/ساعة.

---

## 62 — EKS بـ Terraform
**الهدف:** الستاك `60-eks`: VPC من غير NAT، EKS v21، MNG On-Demand/Spot، add-ons، access entries، Pod Identity، RDS + SSM، والـ Helm add-ons في apply تاني.
**أهم الأوامر:**
```bash
cd infra/terraform/stacks/60-eks && cp terraform.tfvars.example terraform.tfvars
terraform init -backend-config=../../backend.hcl
terraform plan -out=tfplan && terraform apply tfplan
eval "$(terraform output -raw update_kubeconfig)" && kubectl get nodes
# terraform.tfvars: install_addons = true  (+ addons = {...})
terraform plan -out=tfplan && terraform apply tfplan && helm list -A
gh variable set EKS_CLUSTER --body "$(terraform output -raw cluster_name)"
kubectl delete ingress --all -A && terraform destroy
```
**التحقق:** `aws eks list-access-entries` فيه الـ deploy role، `list-pod-identity-associations` فيه LBC و ESO، والـ VPC CNI config فيه `enableNetworkPolicy`.
**Gotchas:**
- `install_addons` في الـ tfvars مش `-var` — apply من غيره بيمسح كل الـ helm releases.
- `grant_github_deploy_role` (default true) بيفشل لو الـ bootstrap role مش موجود؛ والـ creator admin بيتغيّر لو بدّلت بين laptop و CI.
- الـ Spot بيعمل replace للـ node group؛ امسح الـ Ingress قبل الـ destroy.
**التكلفة:** ≈ $0.23/ساعة (~$5.5/يوم) + ALB ~$0.0225/ساعة + NAT لو اتفعّل.

---

## 63 — AWS Load Balancer Controller + Ingress + ACM
**الهدف:** Ingress بـ class `alb` → ALB (target-type ip، health `/ready`، `/metrics` 404 من الـ ALB، readiness gates)، HTTPS بـ ACM، وفكرة ExternalDNS.
**أهم الأوامر:**
```bash
kubectl label namespace student-app elbv2.k8s.aws/pod-readiness-gate-inject=enabled --overwrite
helm upgrade --install student-app k8s/helm/student-app -n student-app -f k8s/helm/student-app/values-eks.yaml --set-string image.repository=<REGISTRY>/student-app --set-string image.tag=<GIT_SHA> --set rollout.enabled=false --wait --rollback-on-failure
ALB=$(kubectl -n student-app get ingress student-app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -s "http://$ALB/ready"; curl -sI "http://$ALB/metrics" | head -3
kubectl -n student-app get pods -o wide && kubectl -n student-app get targetgroupbindings
aws elbv2 describe-target-health --target-group-arn <TG_ARN>
helm upgrade ... -f /tmp/values-https.yaml     # certificate-arn + listen-ports + ssl-redirect
kubectl -n student-app delete ingress student-app
```
**التحقق:** الـ targets = pod IPs `healthy`، `READINESS GATES 1/1`، و `/metrics` = 404 بـ `Server: awselb/2.0`.
**Gotchas:**
- label الـ readiness gate لازم قبل إنشاء الـ pods.
- `APP_URL` من SSM بيكسب على `config.APP_URL` — غيّره من `app_url` في Terraform.
- امسح الـ Ingress قبل `terraform destroy` وإلا الـ VPC مش هيتمسح.
**التكلفة:** ALB ~$0.0225/ساعة + LCU؛ ACM مجاني؛ Route 53 zone ~$0.50/شهر.

---

## 64 — External Secrets + SSM Parameter Store
**الهدف:** ESO بـ Pod Identity يحوّل `/student-app/lab/app/*` لـ Secret `student-app-secrets`، بـ 3 أشكال للـ store، و rotation.
**أهم الأوامر:**
```bash
aws ssm get-parameters-by-path --path /student-app/lab/app --query 'Parameters[].Name'
kubectl get clustersecretstore
kubectl -n student-app get externalsecret student-app-secrets
kubectl -n student-app get secret student-app-secrets -o json | jq -r '.data | keys[]'
terraform -chdir=infra/terraform/stacks/60-eks output -raw cluster_secret_store_manifest | kubectl apply -f -
aws ssm put-parameter --name /student-app/lab/app/<KEY> --type SecureString --overwrite --value '<VALUE>'
kubectl -n student-app annotate externalsecret student-app-secrets force-sync="$(date +%s)" --overwrite
kubectl -n student-app rollout restart deploy/student-app
```
**التحقق:** الـ store `Valid`، الـ ExternalSecret `SecretSynced`، والـ keys في الـ Secret = أسماء الـ parameters.
**Gotchas:**
- الـ env بيتقري وقت الـ start بس — rotation = force-sync + restart.
- الـ Secret بيكسب على الـ ConfigMap (`DB_HOST`، `APP_URL`).
- مع ESO الـ migration Job `post-install` أول مرة؛ و `METRICS_TOKEN` في SSM بيكسر الـ PodMonitor scraping.
**التكلفة:** Standard parameters مجاني؛ Secrets Manager ~$0.40/secret/شهر كبديل.

---

## 65 — Helm chart للتطبيق (+ migrate hook)
**الهدف:** تقرا الـ chart (helpers، pod template مشترك، release env، hook الـ migration) وتنشر بـ `deploy-eks.yml` mode `helm` بـ `--wait --rollback-on-failure`.
**أهم الأوامر:**
```bash
helm lint k8s/helm/student-app
for v in k8s/helm/student-app/values*.yaml; do helm template lab k8s/helm/student-app -f "$v" >/dev/null && echo "ok $v"; done
helm template x k8s/helm/student-app --set-string image.tag=latest     # لازم يفشل
gh workflow run deploy-eks.yml --ref master -f image_tag=<GIT_SHA> -f mode=helm
helm -n student-app history student-app
helm -n student-app get values student-app --all | head -30
helm -n student-app rollback student-app --wait
helm -n student-app uninstall student-app
```
**التحقق:** `helm history` فيه `deploy-eks run <id>`، والـ release `deployed`، والـ hook annotations حسب الـ ESO (pre-install vs post-install).
**Gotchas:**
- دايماً `--set-string` للـ tags (SHA رقمي بيبوظ مع `--set`).
- Helm 4: `--rollback-on-failure` بدل `--atomic` (لسه شغال بـ deprecation warning).
- الـ rollback مبيرجّعش الـ migrations؛ hook فاشل بيفضل بعد الـ uninstall.
**التكلفة:** مجاني (فوق تكلفة الـ cluster).

---

## 66 — RollingUpdate و Recreate (probes، preStop، PDB)
**الهدف:** تقيس rolling بـ 0 failures مقابل downtime الـ Recreate، وتفهم الـ termination (preStop 10 / SIGQUIT / grace 40)، والـ probes، و PDB مع drain.
**أهم الأوامر:**
```bash
bash deploy/scripts/probe.sh http://localhost:8088/ready 0 0.05
helm upgrade student-app k8s/helm/student-app -n student-app -f k8s/helm/student-app/values-kind.yaml --set-string image.tag=ci-v2 --wait
kubectl -n student-app patch deployment student-app --type merge -p '{"spec":{"strategy":{"type":"Recreate","rollingUpdate":null}}}'
kubectl -n student-app set image deployment/student-app app=student-app:ci-v2
kubectl drain student-app-lab-worker2 --ignore-daemonsets --delete-emptydir-data --timeout=180s
kubectl uncordon student-app-lab-worker2
kubectl -n student-app get deploy student-app -o jsonpath='{.status.conditions}'
kubectl -n student-app rollout undo deploy/student-app
```
**التحقق:** Rolling: `failed : 0`؛ Recreate: `failure window` قد الـ shutdown + boot؛ الـ drain بيعمل evict pod واحد في المرة.
**Gotchas:**
- متعملش drain للـ node اللي عليها `mysql-0` (local-path PV مربوط بالـ node).
- `ProgressDeadlineExceeded` مبيعملش rollback لوحده في الـ Deployment.
- `kubectl rollout undo` على release Helm = drift.
**التكلفة:** مجاني على kind.

---

## 67 — Blue/Green على Kubernetes
**الهدف:** blue/green يدوي بـ Service selector switch، وبـ Argo Rollouts `blueGreen` (preview، pre-promotion analysis، promote، scaleDownDelay).
**أهم الأوامر:**
```bash
kubectl -n student-app patch svc student-app --type merge -p '{"spec":{"selector":{"slot":"green"}}}'
helm upgrade --install student-app k8s/helm/student-app -n student-app -f k8s/helm/student-app/values-kind.yaml -f k8s/helm/student-app/values-bluegreen.yaml --set-string image.tag=ci-v2 --set deployColor=green
kubectl argo rollouts get rollout student-app -n student-app --watch
kubectl -n student-app port-forward svc/student-app-preview 8081:80
kubectl argo rollouts promote student-app -n student-app
kubectl argo rollouts abort student-app -n student-app
kubectl argo rollouts undo student-app -n student-app
helm -n student-app rollback student-app
```
**التحقق:** قبل الـ promote الـ probe على `localhost:8088` بيشوف blue بس؛ بعده green و `failed : 0`؛ الـ AnalysisRun `Successful`.
**Gotchas:**
- `port-forward svc` مش بيتبع تغيير الـ selector.
- الـ web gate (`/ready`) بيعدّي release بيرجع 500 — محتاج post-promotion error-rate أو اختبار الـ preview.
- بعد abort الـ Rollout `Degraded` لحد ما الـ spec يرجع (helm rollback / git revert).
**التكلفة:** مجاني على kind؛ على EKS capacity ×2 وقت الـ release.

---

## 68 — Canary بـ Argo Rollouts + analysis
**الهدف:** canary (replicas على kind، ALB weights على EKS) بـ background analysis على 5xx الـ canary pods من Prometheus، و auto-abort للـ bad release (fail closed).
**أهم الأوامر:**
```bash
helm upgrade student-app k8s/helm/student-app -n student-app -f k8s/helm/student-app/values-kind.yaml --set-string image.tag=ci-v1 --set rollout.enabled=true
bash deploy/scripts/probe.sh http://localhost:8088/login 0 0.05 > /tmp/traffic.log 2>&1 &
helm upgrade student-app k8s/helm/student-app -n student-app -f k8s/helm/student-app/values-kind.yaml --set-string image.tag=ci-v2 --set rollout.enabled=true --set-string extraEnv.SRE_FAULT_ERROR_RATE=0.5
kubectl argo rollouts status student-app -n student-app --timeout 300s || echo aborted
kubectl -n student-app get rollout student-app -o jsonpath='{.status.phase} {.status.abort}'
kubectl -n student-app get analysisrun
helm -n student-app rollback student-app
gh workflow run deploy-eks.yml --ref master -f image_tag=<GIT_SHA> -f mode=rollouts
```
**التحقق:** الـ bad canary: `Degraded true`، و probe الـ `/ready` = `failed : 0`؛ على EKS الـ Ingress action annotation بيبيّن الـ weights.
**Gotchas:**
- من غير scraping (PodMonitor / annotations) كل canary يتعمله abort — مقصود (fail closed).
- مفيش traffic = NaN = pass؛ والـ gate على 5xx بس (الـ latency fault بيعدّي).
- CloudWatch provider محتاج IAM لـ argo-rollouts + `AWS_REGION` (مش في الستاك).
**التكلفة:** مجاني على kind؛ EKS: kube-prometheus-stack (غالباً node تالتة).

---

## 69 — GitOps بـ Argo CD
**الهدف:** Argo CD بيعمل sync للـ chart بـ `values-eks.yaml`، الـ app-of-apps للـ add-ons، الـ release = gitops-bump PR، والـ rollback = `git revert`.
**أهم الأوامر:**
```bash
helm upgrade --install argo-cd argo-cd --repo https://argoproj.github.io/argo-helm --version 10.18.2 -n argocd --create-namespace --set 'configs.params.server\.insecure=true'
kubectl apply -n argocd -f k8s/argocd/application.yaml      # أو app-of-apps.yaml (owner واحد!)
kubectl -n argocd get applications
gh workflow run deploy-eks.yml --ref master -f image_tag=<GIT_SHA> -f mode=gitops-bump
gh pr list --label gitops && gh pr merge <PR> --squash
kubectl argo rollouts get rollout student-app -n student-app --watch
git revert <BUMP_COMMIT> --no-edit    # الـ rollback (عن طريق PR)
kubectl -n argocd delete application student-app --wait=true
```
**التحقق:** الـ apps `Synced/Healthy`، `argocd app diff` فاضي، وتعديل يدوي على الـ ConfigMap بيرجع لوحده (selfHeal).
**Gotchas:**
- owner واحد لكل add-on (Terraform `install_addons` أو app-of-apps)؛ املا `vpcId` و `repoURL`.
- فعّل "Allow GitHub Actions to create and approve pull requests"؛ والـ PR بـ `GITHUB_TOKEN` مبيشغّلش CI.
- امسح الـ app قبل الـ add-ons (الـ LBC لازم يمسح الـ ALB).
**التكلفة:** Argo CD مجاني كـ software، بس غالباً محتاج node زيادة.

---

## 6A — HPA + Karpenter تحت load
**الهدف:** k6 بيحرق CPU محسوب، الـ HPA يكبّر بالأرقام، والـ Pending pods تخلي Karpenter يجيب nodes، وبعدين scale-down و consolidation.
**أهم الأوامر:**
```bash
kubectl apply -f /tmp/karpenter-default.yaml && kubectl get ec2nodeclass,nodepool
helm upgrade student-app k8s/helm/student-app -n student-app -f k8s/helm/student-app/values-eks.yaml --set rollout.enabled=false --set resources.requests.cpu=500m --set autoscaling.maxReplicas=12 --set-string image.repository=<REGISTRY>/student-app --set-string image.tag=<GIT_SHA>
LAB_TOKEN=$(aws ssm get-parameter --name /student-app/lab/app/SRE_LAB_TOKEN --with-decryption --query Parameter.Value --output text)
k6 run -e BASE_URL="http://$ALB" -e LAB_TOKEN="$LAB_TOKEN" -e RATE=15 -e CPU_MS=200 -e DURATION=15m loadtest/k6/autoscale-cpu.js
kubectl -n student-app get hpa -w
kubectl get nodeclaims -w
kubectl top nodes && kubectl top pods -n student-app
kubectl delete nodepool --all && kubectl delete ec2nodeclass --all
```
**التحقق:** الـ HPA بيوصل الـ desired المحسوب (`RATE × CPU_MS/1000 ÷ (request × 0.7)`)، و `nodeclaims` جديدة بتبقى Ready في ~1 دقيقة.
**Gotchas:**
- الـ NodePool/EC2NodeClass مصدرهم الرسمي سيناريو 6A §5.3 (الستاك بيشاور عليه) — القيم من `terraform output karpenter`.
- الـ utilization نسبة من الـ request (100m) — `RATE=10` ≈ 29 pod فمقفول على `maxReplicas: 6`؛ `RATE=2 CPU_MS=100` عشان تشوف الـ scaling.
- امسح الـ NodePools قبل `terraform destroy` (الـ EC2 بتاعة Karpenter برا الـ state).
**التكلفة:** nodes Karpenter (~$0.04/ساعة لكل t3.medium On-Demand، Spot أقل)؛ سقف `limits.cpu: 8`.

# H. Observability و SRE

## 70 — Logging (JSON → CloudWatch Logs Insights، Loki)
**الهدف:** لوجز JSON على stderr توصل CloudWatch (awslogs) أو Loki (Alloy)، و queries بتجاوب على أسئلة incident.
**أهم الأوامر:**
```bash
aws logs describe-log-groups --log-group-name-prefix /student-app --query 'logGroups[].[logGroupName,retentionInDays]'   # stacks 20/40 بيعملوه بـ retention
export HOSTNAME=$(hostname); docker compose -f docker-compose.prod.yml -f deploy/ec2/compose.awslogs.yml up -d --no-deps app
aws logs tail /ecs/student-app-lab/app --since 15m --filter-pattern '{ $.level_name = "ERROR" }'
aws logs start-query --log-group-name /student-app/lab/app --start-time $(date -d '-1 hour' +%s) --end-time $(date +%s) --query-string 'stats count(*) by level_name, bin(5m)'
# Grafana → Explore → Loki:  {service=~"app.*", level="ERROR"}
```
**التحقق:** سطر فيه `"level_name"` في Logs Insights، والـ metric `StudentApp/student-app-lab AppErrorLogs` بيتحرك · **Gotchas:** • لو الـ group مش موجود `awslogs-create-group` بيعمله Never expire • الـ override بيغطي `app` بس (مش `app_blue`/`app_green`) • الـ 500 المحقونة (HttpException) مش في لوج Laravel · **التكلفة:** ~$0.50/GB ingestion + $0.005/GB scanned

---

## 71 — Metrics و Dashboards (Prometheus، Grafana، CloudWatch)
**الهدف:** RED/USE، metrics التطبيق (route name، APCu، scrape لكل container، `app_info` join)، و نفس الصورة على CloudWatch.
**أهم الأوامر:**
```bash
curl -s localhost:9090/api/v1/query --data-urlencode 'query=count by (__name__) ({__name__=~"student_app_.*"})' | jq
curl -s localhost:9090/api/v1/query --data-urlencode 'query=sum by (version,color) (rate(student_app_http_requests_total[5m]) * on(instance) group_left(version,color) student_app_app_info)' | jq
export ECS_SERVICE=student-app-lab-app ASG_NAME=student-app-lab-blue   # + باقي الـ tokens
envsubst < observability/cloudwatch/dashboard.json > /tmp/d.json && aws cloudwatch put-dashboard --dashboard-name student-app-lab-slo --dashboard-body file:///tmp/d.json
terraform -chdir=infra/terraform/stacks/40-ec2-alb-asg output -raw dashboard_url
```
**التحقق:** RED → Requests/s by release بيبيّن الـ split؛ الـ CloudWatch widgets مليانة · **Gotchas:** • متعملش scrape من ورا الـ LB (العدادات per container) • `sum by (le)` قبل `histogram_quantile` • الـ ECS service اسمه `student-app-lab-app` (مثال الـ README لسه `ECS_SERVICE=student-app-lab`) والـ ASG `student-app-lab-blue` · **التكلفة:** dashboards أول 3 مجاناً ثم ~$3؛ alarm ~$0.10/metric

---

## 72 — Tracing بـ OpenTelemetry
**الهدف:** trace/span/context propagation/sampling، تشغّل Collector + Jaeger وتبعت span بإيدك، وتعرف المطلوب لـ instrumentation التطبيق (design بس).
**أهم الأوامر:**
```bash
docker compose -f observability/otel/docker-compose.yml up -d                # Jaeger UI: localhost:16686
TRACE_ID="$(printf '%08x' "$(date +%s)")$(openssl rand -hex 12)"
curl -sS -X POST localhost:4318/v1/traces -H 'Content-Type: application/json' -d @span.json   # OTLP/HTTP JSON (§6.2)
docker compose -f observability/otel/docker-compose.yml logs --tail=5 otel-collector
docker run --rm -e AWS_REGION=us-east-1 -v "$PWD/observability/otel:/cfg:ro" otel/opentelemetry-collector-contrib:0.165.0 validate --config=/cfg/collector-xray.yaml
```
**التحقق:** الـ span ظاهر في Jaeger (service `student-app-synthetic`) و `debug` exporter طبع batch · **Gotchas:** • التطبيق **مش** instrumented (extension + packages + `OTEL_*` = design) • X-Ray SDK/daemon في maintenance (EOS فبراير 2027) → OTel • استبعد `/up`/`/ready`/`/metrics` من الـ traces · **التكلفة:** محلي مجاني؛ X-Ray ~$5/مليون trace

---

## 73 — SLI/SLO و Error budget و Burn-rate alerts
**الهدف:** 99.5%/30d = 216 دقيقة budget؛ burn rate 14.4×/6×/1× بنافذتين؛ recording rules + alerts متختبرة؛ drill SLI معزول؛ CloudWatch composites.
**أهم الأوامر:**
```bash
docker run --rm -v "$PWD/observability/prometheus:/p:ro" -w /p --entrypoint promtool prom/prometheus:v3.16.0 test rules rules/tests/slo-burn-rate.test.yml
k6 run -e BASE_URL=http://localhost:8080 -e BURN_RATE=20 -e DURATION=60m loadtest/k6/error-budget-burn.js      # SLODrillFastBurn → /drill
SRE_FAULT_ERROR_RATE=0.1 docker compose up -d --no-build --wait app
k6 run -e BASE_URL=http://localhost:8080 -e MODE=app -e BURN_RATE=20 -e LOADTEST_USERS=5 loadtest/k6/error-budget-burn.js   # SLOAvailabilityFastBurn → /page
aws cloudwatch describe-alarms --alarm-types CompositeAlarm --alarm-name-prefix student-app-lab --query 'CompositeAlarms[].[AlarmName,StateValue]'
```
**التحقق:** الـ 5 promtool tests عدّت؛ الـ drill بيروح `/drill` والـ real SLO ساكت · **Gotchas:** • detection عند B=20 ≈ 43+2 دقيقة (مش فوري) • الـ ALB SLI مش بيستبعد `/sre-lab/*` → الـ drills ضد الـ ALB بتحرق CloudWatch • متختارش B = 14.4 بالظبط (flapping) · **التكلفة:** ~$2/شهر alarms

---

## 74 — Load testing بـ k6 (smoke→soak→breakpoint)
**الهدف:** كل نوع test بيجاوب على سؤال، الـ thresholds = SLOs، مصايد Laravel (419، token rotation، `_submission_token`)، الـ knee و Little's law، و perf gate.
**أهم الأوامر:**
```bash
docker compose exec -T app sh -c 'LOADTEST_USERS=20 LOADTEST_STUDENTS_PER_USER=100 php artisan db:seed --class=LoadTestSeeder --force'
k6 run -e BASE_URL=http://localhost:8080 -e LOADTEST_USERS=20 -e VUS=10 -e DURATION=5m loadtest/k6/load.js; echo "exit=$?"
k6 run -e BASE_URL=http://localhost:8080 -e TARGET=db-heavy -e MAX_RATE=100 loadtest/k6/breakpoint.js
K6_WEB_DASHBOARD=true K6_WEB_DASHBOARD_EXPORT=loadtest/results/report.html k6 run loadtest/k6/user-journey.js
gh workflow run perf-gate.yml -f base_url=http://<ALB_DNS> -f script=load.js -f vus=20 -f duration=10m -f p95_ms=300
```
**التحقق:** exit 0 (99 = SLO اتكسر)؛ `csrf_failures`/`login_failures`/`duplicate_submissions` = 0 · **Gotchas:** • `LOADTEST_USERS` لازم = اللي اتسيد • `P95_MS` default 500 (الـ SLO الحقيقي 300) • closed model بيخبّي البطء — الـ capacity بالـ arrival-rate · **التكلفة:** مجاني محلياً؛ على AWS = الستاك + الـ scale-out

---

## 75 — Chaos engineering بـ AWS FIS + Game day
**الهدف:** hypothesis → steady state → blast radius → stop conditions → learnings؛ FIS (ECS stop، ASG terminate، CPU، latency) + faults على مستوى التطبيق.
**أهم الأوامر:**
```bash
sed -e "s/<ACCOUNT_ID>/$ACCT/g;s/<REGION>/us-east-1/g" observability/fis/ecs-stop-half-tasks.json > /tmp/t.json   # بيستهدف student-app-lab-app
TID=$(aws fis create-experiment-template --cli-input-json file:///tmp/t.json --query experimentTemplate.id --output text)
EID=$(aws fis start-experiment --experiment-template-id $TID --tags Scenario=75 --query experiment.id --output text)
aws fis get-experiment --id $EID --query 'experiment.state'; aws fis stop-experiment --id $EID   # الزرار الأحمر
terraform -chdir=infra/terraform/stacks/50-ecs-fargate apply -var enable_fis=true -var image_tag=<SHA7>
```
**التحقق:** الـ experiment `completed` أو `stopped` بسبب الـ alarm؛ ECS رجّع `desiredCount` · **Gotchas:** • الـ fast-burn بطيء كـ stop condition — stack 50 بيستخدم `alb-5xx-ratio` • الـ ALB alarms بتضرب على drills `/sre-lab` كمان (بتوقف الـ experiment) — mute SNS وافصل التجارب • ≥ 2 tasks في ≥ 2 AZs قبل أي تجربة · **التكلفة:** ~$0.10/action-minute

---

## 76 — Incident response (runbooks، postmortem)
**الهدف:** runbook لكل alert (Prometheus + CloudWatch)، severities، أدوار IC/comms/ops/scribe، mitigation-first بأوامر rollback، و postmortem blameless.
**أهم الأوامر:**
```bash
curl -s localhost:9090/api/v1/query --data-urlencode 'query=sum by (version,color) (rate(student_app_http_requests_total{status=~"5.."}[5m]) * on(instance) group_left(version,color) student_app_app_info)'
cd deploy/ec2/lb && bash bin/status.sh && bash bin/rollback.sh
aws ecs update-service --cluster student-app-lab --service student-app-lab-app --task-definition <PREVIOUS_TASKDEF_ARN>
aws autoscaling rollback-instance-refresh --auto-scaling-group-name student-app-lab-blue
helm rollback student-app <REVISION> -n student-app
aws cloudwatch describe-alarms --state-value ALARM --alarm-name-prefix student-app-lab --query 'MetricAlarms[].AlarmName'
```
**التحقق:** المحاكاة (SLOT_ENV=`SRE_FAULT_ERROR_RATE=0.1` + bluegreen) → page → rollback → resolved، و postmortem مكتوب · **Gotchas:** • rollback الأول، الـ debugging بعدين • الـ migrations مش بترجع • canary اتقطع = `ab-test.sh stop` مش `rollback.sh` · **التكلفة:** مجاني

---

## 77 — Backup و Disaster Recovery (RTO/RPO)
**الهدف:** RTO/RPO بأرقام، restore drill متقاس للـ container MySQL، RDS PITR/snapshots/cross-region، AWS Backup، واستراتيجيات الـ DR.
**أهم الأوامر:**
```bash
BACKUP_BUCKET=student-app-lab-backups-<ACCOUNT_ID> bash deploy/ec2/backup-mysql-to-s3.sh
DB_NAME=student_app_restore BACKUP_BUCKET=… bash deploy/ec2/backup-mysql-to-s3.sh restore s3://…/mysql/<KEY>.sql.gz   # scratch DB
aws rds restore-db-instance-to-point-in-time --source-db-instance-identifier student-app-lab-mysql --target-db-instance-identifier student-app-lab-mysql-pitr --restore-time <UTC> --db-subnet-group-name <SG> --vpc-security-group-ids <SG_ID> --db-parameter-group-name <PG>
aws rds wait db-instance-available --db-instance-identifier student-app-lab-mysql-pitr
aws rds copy-db-snapshot --region us-west-2 --source-region us-east-1 --source-db-snapshot-identifier <ARN> --target-db-snapshot-identifier <ID>-dr --kms-key-id <DEST_KMS>
aws rds start-db-instance-automated-backups-replication --region us-west-2 --source-db-instance-arn <DB_ARN> --kms-key-id <DEST_KMS>
```
**التحقق:** counts في الـ scratch DB = الأصل، و RTO متسجل في جدول الـ drill · **Gotchas:** • Multi-AZ مش backup • defaults الـ lab: `skip_final_snapshot = true` و `delete_automated_backups = true` (module input) → destroy = الداتا راحت؛ اقفل الاتنين لما الـ backups تفرق • الـ PITR = endpoint جديد (حدّث `DB_HOST` + refresh) · **التكلفة:** سنتات (snapshots ~$0.095/GB-month + ساعة RDS للـ drill)

# I. الأمان (DevSecOps)

## 80 — IAM و OIDC و Least privilege و Session Manager
**الهدف:** IAM evaluation، الـ 4 OIDC roles (ci، deploy، terraform admin، plan read-only) ونقط ضعفهم، instance profiles، Session Manager بدل SSH، boundaries/SCPs/Access Analyzer.
**أهم الأوامر:**
```bash
cd infra/terraform/bootstrap && terraform apply && terraform output github_repository_variables
aws iam get-role --role-name student-app-gha-terraform --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition'
aws iam simulate-principal-policy --policy-source-arn arn:aws:iam::<ACCOUNT_ID>:role/student-app-gha-deploy --action-names ecs:UpdateService iam:CreateRole --query 'EvaluationResults[].[EvalActionName,EvalDecision]'
aws ssm start-session --target <INSTANCE_ID>
aws accessanalyzer create-analyzer --analyzer-name student-app-account --type ACCOUNT
aws accessanalyzer validate-policy --policy-type IDENTITY_POLICY --policy-document file://policy.json
```
**التحقق:** IMDSv2 required + hop limit 1، مفيش port 22، والـ simulate بيطلّع `implicitDeny` للـ IAM · **Gotchas:** • الـ admin role بيثق في `environment:lab` بس (`terraform_branches = []`) — متضيفش branches • الـ plan role (أي branch) بيقرا الـ state والـ SecureStrings • `sub` بـ `environment:` مفيهوش ref · **التكلفة:** مجاني

---

## 81 — إدارة الـ Secrets (SSM مقابل Secrets Manager، rotation)
**الهدف:** layout `/student-app/<env>/app/*`، إزاي كل platform بيستهلك الـ secrets، `use_secrets_manager` وإيه الناقص، `APP_KEY` rotation، والـ state كـ secret.
**أهم الأوامر:**
```bash
aws ssm get-parameters-by-path --path /student-app/lab/ --recursive --query 'Parameters[].[Name,Type,Version]' --output table
sudo bash deploy/ec2/render-env-from-ssm.sh && ls -l /opt/student-app/app.env          # -rw-------
aws ecs describe-task-definition --task-definition student-app-lab-app --query 'taskDefinition.containerDefinitions[0].secrets'
aws ssm put-parameter --name /student-app/lab/app/APP_PREVIOUS_KEYS --type SecureString --value "$OLD" --overwrite
aws ssm put-parameter --name /student-app/lab/app/APP_KEY --type SecureString --value "base64:$(openssl rand -base64 32)" --overwrite
aws ecs update-service --cluster student-app-lab --service student-app-lab-app --force-new-deployment
```
**التحقق:** الـ task def فيها ARNs مش قيم؛ `app.env` بـ 600 · **Gotchas:** • أي تغيير secret = restart/refresh/deploy • `use_secrets_manager = true` بيشيل `DB_PASSWORD` من SSM ومحدش من الـ stacks بيقرا Secrets Manager لسه • الـ state فيه الـ secrets plain (والـ versions القديمة كمان) · **التكلفة:** SSM standard مجاني؛ Secrets Manager ~$0.40/secret

---

## 82 — Supply chain (Trivy، SBOM، cosign، Dependabot، checkov)
**الهدف:** كل أداة في الـ repo بتحمي من إيه، الـ pin بالـ SHA بعد حادثة trivy-action (مارس 2026)، triage لـ `composer audit`/`npm audit`، cosign policy، و SLSA.
**أهم الأوامر:**
```bash
git ls-remote --tags https://github.com/aquasecurity/trivy-action | grep -E 'refs/tags/0\.36\.0'   # SHA للـ pin
gh run download <RUN_ID> -n sbom && grype sbom:./sbom.spdx.json --only-fixed
composer audit --locked --format=table && composer why <vendor/package>
composer update <vendor/package> --with-dependencies && php artisan test --compact
npm audit --audit-level=high && npm audit fix
grep -rhoE 'uses: [^ ]+@[^ ]+' .github/workflows | sort | uniq -c | sort -rn
```
**التحقق:** الـ audit نضيف قبل ما تشيل `continue-on-error`؛ actions متثبتة بـ SHA · **Gotchas:** • `@0.36.0` لسه tag مش SHA وباقي الـ actions major tags (kubeconform `v0.6.7` و k6 `2.4.0` متثبتين) • Composer ≥ 2.9 بيمنع النسخ الـ insecure وقت الـ update (`audit.block-insecure`) • checkov `soft_fail` — suppress بسبب في الكود مش global · **التكلفة:** مجاني (Inspector enhanced مدفوع)

---

## 83 — Edge security (WAF، HTTPS، headers، rate limiting)
**الهدف:** ACM + HTTPS + redirect على الـ ALB، `trustProxies` في Laravel، security headers، WAF (managed rules + rate-based)، وقفل `/metrics` و `/sre-lab/*` من برّه.
**أهم الأوامر:**
```bash
terraform -chdir=infra/terraform/stacks/40-ec2-alb-asg apply -var domain_name=lab.<DOMAIN> -var hosted_zone_id=<ZONE_ID> -var image_tag=<SHA7>
aws ssm get-parameter --name /student-app/lab/app/SESSION_SECURE_COOKIE --query Parameter.Value   # true أوتوماتيك (stack 40 + HTTPS)
aws elbv2 modify-listener-attributes --listener-arn <LISTENER_ARN> --attributes '[{"Key":"routing.http.response.strict_transport_security.header_value","Value":"max-age=300"}]'
curl -sI http://lab.<DOMAIN>/ | grep -i location; curl -sI https://lab.<DOMAIN>/login | grep -iE 'strict|set-cookie'
curl -s -o /dev/null -w '%{http_code}\n' https://lab.<DOMAIN>/metrics                 # 404 من الـ ALB
aws wafv2 disassociate-web-acl --resource-arn <ALB_ARN>                              # off switch
```
**التحقق:** 301 → https، الروابط في الـ HTML بـ https، الـ WAF بيرجّع 403 بعد حد الـ `/login` · **Gotchas:** • `/sre-lab/*` على الـ ALB token-only → `sre_lab_enabled = false` على الـ stacks اللي مش بتعمل عليها drills • Common rule set: Count الأول • log group الـ WAF لازم يبدأ بـ `aws-waf-logs-` · **التكلفة:** WAF ~$5 + $1/rule/شهر + $0.60/مليون request؛ ACM مجاني

# J. الـ IaC بالتفصيل

## 90 — Terraform بالتفصيل (modules، state، environments)
**الهدف:** تفهم الـ HCL والـ modules والـ `lifecycle` والـ remote state من كود `infra/terraform` نفسه.
**أهم الأوامر:**
```bash
terraform init -backend-config=../../backend.hcl
terraform plan -out=tfplan && terraform apply tfplan
terraform state list && terraform state show 'module.alb.aws_lb_listener.http[0]'
terraform state mv 'module.alb.aws_lb_listener.http[0]' 'module.alb.aws_lb_listener.http_external[0]'
terraform force-unlock <LOCK_ID>
terraform apply -replace=module.host.aws_instance.this
terraform test
tflint --recursive --chdir=infra/terraform --config "$PWD/infra/terraform/.tflint.hcl"
```
**التحقق:** `terraform plan -detailed-exitcode` = 0 بعد الـ apply، و `<key>.tflock` بيظهر وقت الـ apply بس · **Gotchas:** • `ignore_changes` = فيه مالك تاني (CI / ASG / CodeDeploy) ومينفعش يبقى conditional • الـ secrets في الـ state حتى مع `sensitive = true` • `-var env=lab2` مبيغيّرش الـ state key · **التكلفة:** مجاني offline؛ stack 20 ≈ $0.03/ساعة

---

## 91 — Import لموارد الـ Console جوه Terraform + drift
**الهدف:** تدخّل موارد الـ Console (SG، EC2، ECR، SSM، log group) تحت Terraform لحد zero-diff وتفرّق بين الـ drift الحقيقي والمقصود.
**أهم الأوامر:**
```bash
terraform plan -generate-config-out=generated.tf
terraform plan
terraform apply && rm imports.tf
terraform import 'aws_ssm_parameter.app_secret["APP_KEY"]' /student-app/lab/app/APP_KEY
terraform plan -refresh-only
terraform apply -refresh-only
terraform plan -detailed-exitcode; echo "exit=$?"
terraform query -generate-config-out=generated.tf
```
**التحقق:** `Plan: N to import, 0 to add, 0 to change, 0 to destroy` ثم `No changes` بعد الـ apply · **Gotchas:** • الـ import بيتبنّى الـ resource مش القيمة (`value = null # sensitive`) • rule SG اتضافت برّه = الـ plan العادي مش شايفها • weights stack 40 بترجع لو الـ CI غيّرها و `listener_weights_managed_externally = false` · **التكلفة:** الـ import مجاني؛ الموارد بتكلفتها

---

## 92 — Terraform في الـ CI (plan على PR، approvals، infracost)
**الهدف:** plan read-only على كل PR كـ comment، و apply/destroy بـ dispatch ورا environment `lab` بالـ admin role عن طريق OIDC.
**أهم الأوامر:**
```bash
gh variable set ECS_IMAGE_TAG --body <SHA>
gh pr create --fill && gh pr checks --watch
gh workflow run terraform.yml --ref master -f stack=20-ec2-single -f action=plan
gh workflow run terraform.yml --ref master -f stack=20-ec2-single -f action=apply
gh run watch "$(gh run list --workflow terraform.yml -L 1 --json databaseId --jq '.[0].databaseId')"
gh workflow run terraform.yml --ref master -f stack=20-ec2-single -f action=destroy
checkov -f plan.json --framework terraform_plan
docker run --rm -v "$PWD:/project" -w /project openpolicyagent/conftest test plan.json --policy policy
```
**التحقق:** comment `terraform-plan:<stack>` على الـ PR، و `Apply complete!` في الـ log ومفيش `.tflock` معلّق · **Gotchas:** • الـ admin role بيثق في `environment:lab` بس — قفل الـ environment على main/master (الـ `sub` مفيهوش ref) • الـ CI بيشوف الـ defaults + `TF_VAR_*` بس مش tfvars الـ laptop • ملف الـ plan فيه الـ secrets plain text (خطر كـ artifact) · **التكلفة:** GitHub minutes + تكلفة الـ stack اللي اتعمله apply

---

## 93 — Ansible بالتفصيل (roles، vault، dynamic inventory)
**الهدف:** تفهم الـ inventory الـ dynamic والـ SSM connection والـ roles والـ variables والـ vault والـ rolling بـ `serial`.
**أهم الأوامر:**
```bash
cd infra/ansible && ansible-galaxy collection install -r requirements.yml
ansible-inventory --graph
ansible role_app -m ansible.builtin.ping -e ssm_bucket_name=$SSM_BUCKET
ansible-playbook playbooks/provision.yml -e ssm_bucket_name=$SSM_BUCKET -e target_hosts=standalone
ansible-playbook playbooks/deploy.yml -e ssm_bucket_name=$SSM_BUCKET -e app_image=$IMG --check --diff
ansible-vault encrypt --vault-id "lab@$HOME/.vault-pass-student-app" inventories/lab/group_vars/all/vault.yml
ansible-playbook playbooks/rolling-asg.yml -e ssm_bucket_name=$SSM_BUCKET -e app_image=$IMG -e "{\"rolling_target_group_arns\": $TG}"
ansible-lint --profile=production
```
**التحقق:** التشغيل التاني `changed=0`، و `/opt/student-app/CURRENT_RELEASE` = الـ image · **Gotchas:** • `group_vars/` بيتقري جنب الـ inventory أو الـ playbook بس • `command`/`shell` بيتعملهم skip في `--check` (الـ probes الـ read-only: `check_mode: false`) • `rolling-asg.yml` بيسيب الـ ASG suspended لو فشل (مقصود) · **التكلفة:** مجاني؛ stack 20 ≈ $0.03/ساعة، stack 40 ≈ $0.08/ساعة

# K. الختام

## 95 — Database migrations من غير downtime (expand/contract)

**الهدف:** كل migration تشتغل مع الكود القديم والجديد: expand → backfill (batches) → contract، و roll forward بدل `down()`.

**أهم الأوامر:**
```bash
php artisan migrate --pretend && php artisan migrate:status
mysql student_app -e "SET SESSION lock_wait_timeout=5; ALTER TABLE students ADD COLUMN mobile VARCHAR(20) NULL, ALGORITHM=INSTANT;"   # expand
mysql student_app -e "SELECT section, COUNT(*) FROM students GROUP BY section;"   # تحقق قبل الـ contract
docker compose run --rm app php artisan migrate --force      # مرة واحدة لكل release، مش عند الـ boot
```
**التحقق:** الـ migration expand بس، الكود N-1 شغال على الـ schema الجديد، و `migrate:status` من غير Pending · **Gotchas:** • `add_pricing_to_subscriptions_table` (NOT NULL + drop `amount` في خطوة واحدة) بيكسر الكود القديم في الـ window وفي الـ rollback • `--isolated` مع `CACHE_STORE=database` بيقع على DB فاضية (`cache_locks` لسه مش موجود) • حتى INSTANT محتاج metadata lock → `lock_wait_timeout` صغير · **التكلفة:** مجاني؛ RDS snapshots بالـ GB

---

## 96 — جداول المقارنة (الاستراتيجيات، المنصات، أدوات الـ CI)
**الهدف:** تختار الـ strategy والمنصة والأداة في دقيقة: downtime، سرعة الـ rollback، التكلفة، قيد الـ migrations، الـ gate، وفين متطبّقة في الـ repo.
**أهم الأوامر:**
```bash
bash deploy/ec2/lb/bin/canary.sh "$REPO:<SHA7>"                                  # single host: metric gate (exit 2)
gh workflow run deploy-asg.yml -f strategy=canary-weights -f image_tag=<SHA7>      # ASG: weighted TGs + alarm
gh workflow run deploy-ecs.yml -f strategy=native -f image_tag=<SHA7>              # ECS-native B/G / linear / canary
gh workflow run deploy-ecs.yml -f strategy=codedeploy -f image_tag=<SHA7>          # ECS + CodeDeploy
gh workflow run deploy-eks.yml -f mode=rollouts -f image_tag=<SHA7>                # EKS: Argo Rollouts + analysis
gh workflow run deploy-eks.yml -f mode=gitops-bump -f image_tag=<SHA7>             # Argo CD (pull)
gh workflow run lab-integration.yml --ref devops-lab                               # كل استراتيجيات الـ single host من غير AWS
```
**التحقق:** تقدر تقول لكل gate بيقيس إيه، والـ threshold بتاعه، وبيعمل إيه لو مفيش traffic (`canary.sh` fail closed، Argo `isNaN` fail open) · **Gotchas:** • الـ health checks مبتشوفش `SRE_FAULT_ERROR_RATE` — rolling و B/G من غير metric gate بيعدّوه • أي zero-downtime = إصدارين على نفس الـ schema → expand/contract • `AutoRollback=false` في الـ instance refresh لأن الـ release في SSM مش في الـ launch template · **التكلفة:** مجاني (مراجعة)

---

## 97 — التكلفة والمسح
**الهدف:** تعرف تكلفة كل stack بالساعة وأكبر المصايد، وتمسح بالترتيب الصح وتتأكد إن مفيش بواقي — apply الصبح، destroy بالليل.
**أهم الأوامر:**
```bash
kubectl delete ingress --all -A                                                   # قبل destroy الـ 60
terraform -chdir=infra/terraform/stacks/36-codepipeline destroy                    # قبل 50 دايماً
terraform -chdir=infra/terraform/stacks/50-ecs-fargate destroy
aws resourcegroupstaggingapi get-resources --tag-filters Key=Project,Values=student-app --query 'ResourceTagMappingList[].ResourceARN' --output text
aws ec2 describe-addresses --query 'Addresses[?AssociationId==null].PublicIp'
aws logs describe-log-groups --query 'logGroups[?retentionInDays==null].logGroupName'
aws rds describe-db-snapshots --snapshot-type manual --query 'DBSnapshots[].DBSnapshotIdentifier'
aws ce get-cost-and-usage --time-period Start=$(date -d yesterday +%F),End=$(date +%F) --granularity DAILY --metrics UnblendedCost --query 'ResultsByTime[0].Total'
```
**التحقق:** الـ tagging API مفيهوش غير `Scenario=02` (bootstrap)، ومفيش EIP/NAT/ALB/RDS/EKS، والفاتورة بكرة ≈ سنتات · **Gotchas:** • ترتيب: برّه Terraform ← 36 ← 35 ← app stack واحد (20/40/50/60) ← فحص ← bootstrap آخر حاجة • stop ≠ destroy (EBS و IPv4 بيتحاسبوا، و RDS بيصحى لوحده بعد 7 أيام) • manual snapshots و log groups من غير retention بيعيشوا بعد الـ destroy · **التكلفة:** stack 20 ≈ $0.03/h · 40 ≈ $0.08/h · 50 ≈ $0.11/h · 60 ≈ $0.23/h · NAT +$0.045/h

---

## 98 — الـ Portfolio وأسئلة الـ Interview
**الهدف:** README hero + رسم معمارية + 3 demo stories + ADRs + CV bullets بأرقام + 50 سؤال Senior DevOps/SRE مربوطين بالسيناريوهات.
**أهم الأوامر:**
```bash
gh workflow run lab-integration.yml --ref devops-lab && gh run watch               # demo 1 مجاناً (canary abort)
gh workflow run deploy-ec2-canary.yml -f image_tag=<SHA7> -f slot_env=SRE_FAULT_ERROR_RATE=0.5 -f expect_abort=true
cd deploy/ec2/lb && SLOT_ENV="SRE_FAULT_ERROR_RATE=0.1" SKIP_PULL=true bash bin/bluegreen.sh student-app:v2   # demo 2
bash bin/rollback.sh && bash bin/status.sh
terraform plan -generate-config-out=generated.tf                                   # demo 3 (import blocks)
terraform plan -detailed-exitcode; echo "exit=$?"
```
**التحقق:** كل demo ليها GIF/فيديو + لينك run أخضر، و 3 ADRs بالقالب، وجاوبت الـ 50 سؤال بصوت عالي بمثال من الـ repo · **Gotchas:** • متكتبش في الـ CV رقم مقستهوش • "zero-downtime" مش "zero errors": الـ canary ليه blast radius (10% × خطوة) • 10% errors بياخد ~43 دقيقة للـ fast-burn tier — عشان كده الـ canary · **التكلفة:** مجاني على GitHub Actions؛ demo على AWS = تكلفة الـ stack لساعة

---

## 99 — Cheat sheets و Troubleshooting
**الهدف:** أوامر كل أداة في صفحة، وسكريبتات المعمل بالـ env vars بتاعتها، وجدول عَرَض ← سبب ← حل لأشهر أعطال المعمل.
**أهم الأوامر:**
```bash
curl -s http://<HOST>/ready | jq '{status,reason,version,color}'
bash deploy/ec2/lb/bin/status.sh
aws ecs describe-services --cluster student-app-lab --services student-app-lab-app --query 'services[0].deployments[].[status,rolloutState]'
aws ecs describe-tasks --cluster student-app-lab --tasks <TASK_ARN> --query 'tasks[0].stoppedReason'
aws elbv2 describe-target-health --target-group-arn <TG_ARN> --query 'TargetHealthDescriptions[].TargetHealth'
kubectl -n student-app describe externalsecret student-app-secrets
kubectl argo rollouts get rollout student-app -n student-app && kubectl -n student-app get analysisrun
terraform force-unlock <LOCK_ID>
```
**التحقق:** حلّيت 5 أعطال على الأقل من الجدول بنفسك وعارف تقرا `reason` بتاع `/ready` و `stoppedReason` و `TargetHealth.Reason` · **Gotchas:** • بورت الـ TG: stack 40 = 80 (host)، stack 50/EKS = 8080 (ip) • `canary.sh` exit 2 = pre-traffic checks أو مفيش traffic (`/metrics` أعمى) أو error rate • OIDC: job فيه `environment` → الـ `sub` = `environment:<name>` مش branch · **التكلفة:** مجاني

# ملاحق

> مراجع سريعة للطباعة. التفاصيل في [96](scenarios/96-comparison-matrices.md) (المقارنات)، [97](scenarios/97-cost-and-teardown.md) (التكلفة والمسح)، و [99](scenarios/99-cheatsheets-and-troubleshooting.md) (الأوامر والأعطال).

## أ) مصفوفة استراتيجيات الـ deployment

| الاستراتيجية | Downtime | الـ rollback | تكلفة زيادة | الـ gate | Single EC2 | ASG | ECS | EKS |
|---|---|---|---|---|---|---|---|---|
| Recreate | ثواني–دقايق | redeploy (بطيء) | صفر | healthcheck | `docker-compose.prod.yml` | CodeDeploy AllAtOnce ≈ | — | `Recreate` (manifests) |
| Rolling | صفر | rolling تاني / circuit breaker | surge صغير | readiness / ELB health | `rolling.sh` | instance refresh · Ansible serial · CodeDeploy OneAtATime | `ROLLING` + breaker | RollingUpdate (helm) |
| Blue/Green | صفر | **ثواني** | 2× وقت الـ deploy | smoke قبل الـ switch + bake | `bluegreen.sh` | `bluegreen-switch` (ASG-ين) | CodeDeploy / native `BLUE_GREEN` | selector / Argo `blueGreen` |
| Canary | صفر | ثواني (weight → 0) | slot/pod أو لون كامل | **metric gate** (5xx ratio) | `canary.sh` (exit 2) | `canary-weights` + alarm | CodeDeploy Canary / native `CANARY` | Argo Rollouts + analysis |
| Linear | صفر | زي canary | زي B/G على ECS | alarms بين الخطوات | `STEPS` متساوية ≈ | `canary_steps` ≈ | CodeDeploy Linear / native `LINEAR` | steps ≈ |
| A/B | صفر | `ab-test.sh stop` | نسختين لأيام | business metrics | `ab-test.sh` | — | — | — |
| Shadow | صفر | `shadow.sh stop` | 2× + load على الـ DB | مقارنة metrics | `shadow.sh` (GET/HEAD) | — | — | — |
| Feature flags | صفر | toggle من غير deploy | ~صفر | product metrics | مفهوم + Pennant (تمرين) | ← | ← | ← |

- أي zero-downtime = إصدارين على نفس الـ schema ← **expand/contract** ([95](scenarios/95-zero-downtime-db-migrations.md)). الـ migrations مبترجعش مع أي rollback.
- الـ health checks مبتشوفش `SRE_FAULT_ERROR_RATE` ← محتاج metric gate أو deployment alarms.
- الـ gates: `canary.sh` (`MAX_ERROR_RATE` 0.01، `MIN_REQUESTS` 10، fail closed) · ASG (`student-app-lab-alb-5xx-ratio`، خطوة 300s) · ECS (`use_deployment_alarms`) · Argo (`maxErrorRate` 0.05، `failureLimit` 1، `isNaN` = fail open).

## ب) EC2 مقابل ECS مقابل EKS

| | EC2 (single / ASG) | ECS Fargate | EKS |
|---|---|---|---|
| الـ ops burden | الأعلى (OS، Docker، AMIs) | الأقل (مفيش servers) | عالي (upgrades، add-ons، nodes) |
| أقل تكلفة idle (المعمل) | stack 20 ≈ $0.03/h · 40 ≈ $0.08/h | ≈ $0.11/h | ≈ $0.23/h (control plane $0.10/h) |
| الـ scaling | ASG target tracking (CPU + requests) — دقايق | 2–6 tasks (CPU 50% + requests) — أقل من دقيقة | HPA 2–6 (CPU 70%) + Karpenter |
| الـ deploy | refresh، weighted TGs، CodeDeploy، Ansible | rolling + breaker، native B/G/linear/canary، CodeDeploy | RollingUpdate، Argo Rollouts، Argo CD |
| الـ secrets | `render-env-from-ssm.sh` → `app.env` | `secrets[].valueFrom` (SSM ARN) | ESO → `student-app-secrets` |
| الـ debug | Session Manager | ECS Exec | `kubectl` |
| اختاره لما | حمل صغير / تحكم في الـ host / legacy | **الافتراضي** لفريق صغير/متوسط على AWS | فرق كتير + ecosystem الـ K8s + platform team |

## ج) التكلفة وترتيب المسح

| Stack | السيناريوهات | ≈ $/ساعة | ≈ $/يوم | أهم بند / مصيدة |
|---|---|---|---|---|
| bootstrap | 02، 30، 80 | — | < $0.50/شهر | ECR (30 image) + state versions |
| 20-ec2-single | 20–27، 31–33 | 0.03 | ~0.70 | EIP + EBS بيتحاسبوا والـ instance stopped |
| 35-codebuild | 35 | 0 idle | — | ~$0.05/push |
| 36-codepipeline | 36، 37، 58 | 0 idle | — | ~$0.05/release |
| 40-ec2-alb-asg | 40–49 | 0.08 | ~2 | ALB + RDS؛ NAT +0.045/h، Redis +0.013/h |
| 50-ecs-fargate | 50–58 | 0.11 | ~2.70 | Fargate + 4 IPv4 + RDS؛ Container Insights |
| 60-eks | 60–6A | 0.23 | ~5.50 | control plane $0.10/h؛ ALB الـ LBC +0.03/h |

**أكبر المصايد:** NAT (~$32/شهر لكل واحد) · EKS control plane · ALB قاعد idle · RDS (والـ stop بيصحى بعد 7 أيام) · public IPv4 ($0.005/h لكل واحد) · CloudWatch Logs من غير retention · ECR storage · Container Insights · Fargate بعد load test · manual snapshots وAMIs بعد الـ destroy.

```text
0) اللي برّه Terraform: kubectl delete ingress --all -A · LoadBalancer svcs · Karpenter NodePools
   FIS templates · WAF · RDS manual/PITR/cross-region snapshots · AMIs+snapshots · Console resources · eksctl
1) 36-codepipeline   (لازم قبل 50)
2) 35-codebuild
3) الـ app stack الوحيد: 20 | 40 | 50 | 60   (نفس SSM paths ← واحد بس لكل env)
4) فحص البواقي (tagging API + EIP/NAT/ALB/RDS/EBS/snapshots/log groups)
5) bootstrap — بس لو خلصت نهائياً: state local ← apply بـ ecr_force_delete + state_bucket_force_destroy ← destroy
```

## د) Cheat sheet في صفحة

```bash
# --- Local / CI
export APP_KEY=base64:$(openssl rand -base64 32); docker compose up -d --build --wait
docker compose run --rm app php artisan migrate --force
gh workflow run lab-integration.yml --ref devops-lab && gh run watch        # كمان: k8s-integration.yml
# --- Single host (deploy/ec2/lb)
SKIP_PULL=true bash bin/init.sh <IMAGE>
bash ../../scripts/with-probe.sh -- bash bin/bluegreen.sh <IMAGE>            # KEEP_OLD, DRAIN_SECONDS, SLOT_ENV
STEPS="10 25 50 100" STEP_SECONDS=30 MAX_ERROR_RATE=0.01 bash bin/canary.sh <IMAGE>
bash bin/rollback.sh && bash bin/status.sh
bash deploy/scripts/probe.sh http://<HOST>/ready 120 0.2                     # MAX_FAILURES=0 → exit 1 لو فشل
# --- Terraform
terraform init -backend-config=../../backend.hcl && terraform plan -out=tfplan && terraform apply tfplan
terraform plan -refresh-only                                                 # drift
terraform force-unlock <LOCK_ID>                                             # آخر حل
terraform destroy
gh workflow run terraform.yml --ref master -f stack=<NN-name> -f action=plan  # apply | destroy
# --- AWS
aws ssm start-session --target <INSTANCE_ID>
aws ssm get-parameter-history --name /student-app/lab/deploy/blue/IMAGE_URI --query 'Parameters[-3:].Value'
aws ecs describe-services --cluster student-app-lab --services student-app-lab-app --query 'services[0].deployments[].[rolloutState,taskDefinition]'
aws elbv2 describe-target-health --target-group-arn <TG_ARN> --query 'TargetHealthDescriptions[].TargetHealth'
aws autoscaling describe-instance-refreshes --auto-scaling-group-name student-app-lab-blue --query 'InstanceRefreshes[0].Status'
aws logs tail /ecs/student-app-lab/app --follow --since 10m
# --- Deploy workflows
gh workflow run deploy-ecs.yml -f image_tag=<SHA7> -f strategy=rolling           # native | codedeploy
gh workflow run deploy-asg.yml -f image_tag=<SHA7> -f strategy=instance-refresh  # bluegreen-switch | canary-weights
gh workflow run deploy-eks.yml -f image_tag=<SHA7> -f mode=helm                  # rollouts | gitops-bump
# --- Kubernetes
aws eks update-kubeconfig --name student-app-lab
kubectl -n student-app get pods,ingress,rollout,analysisrun,externalsecret
kubectl -n student-app get events --sort-by=.lastTimestamp | tail -20
helm -n student-app history student-app && helm -n student-app rollback student-app
kubectl argo rollouts get rollout student-app -n student-app --watch          # promote | abort | retry rollout | undo
# --- k6 (exit 99 = SLO threshold اتكسر)
k6 run -e BASE_URL=http://<HOST> -e LOADTEST_USERS=20 -e VUS=10 -e DURATION=5m -e P95_MS=300 loadtest/k6/load.js
```

## هـ) أشهر 10 أعطال

| العَرَض | السبب | الحل |
|---|---|---|
| Targets unhealthy في الـ TG | بورت غلط (stack 40 = **80**، 50/EKS = **8080**)، `/ready` 503، SG | `describe-target-health` (Reason) + `curl /ready \| jq .reason` |
| `/ready` = 503 | `database unreachable` / `SRE_FAULT_UNHEALTHY` / unready flag | صلّح الـ DB أو الـ fault، أو `POST /sre-lab/ready` |
| 419 أو mixed content ورا ALB | sessions مش مشتركة / `APP_KEY` مختلف / `X-Forwarded-Proto` | `SESSION_DRIVER=database`، `APP_KEY` واحد من SSM، `trustProxies` + `APP_URL=https://` |
| `canary.sh` exit 2 | pre-traffic checks / مفيش traffic (أو `/metrics` 403/404) / error rate | ولّد traffic على `/login`، راجع `METRICS_ENABLED`/`METRICS_TOKEN`، أو صلّح الـ release |
| `rollback.sh`: nothing to roll back to | `BROKEN` marker — الـ deploy الفاشل مخدش traffic أصلاً | طبيعي؛ deploy إصدار سليم |
| ECS `rolloutState = FAILED` | circuit breaker (boot fail، image، secrets) | `describe-tasks` → `stoppedReason` |
| `CannotPullContainerError` / `ResourceInitializationError` | tag مش في ECR، مفيش طريق لـ ECR/SSM، execution role، arch | `ecr describe-images`، public IP/NAT، الـ role، multi-arch |
| Rollout `Degraded` | analysis فشل، أو مفيش series (PodMonitor/`METRICS_TOKEN`) | `get analysisrun`، صلّح ثم `retry rollout` أو `helm rollback` |
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | `sub` مش مطابق (environment بدل branch، PR، branch جديد) أو role var غلط | قارن الـ `sub` بـ `github-oidc.tf`؛ deployment branches على الـ environment |
| `Error acquiring the state lock` | apply شغال أو run اتلغى وساب `.tflock` | اتأكد مفيش run، وبعدين `terraform force-unlock <ID>` |
