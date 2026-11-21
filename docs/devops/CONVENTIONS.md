# CONVENTIONS — ثوابت المعمل (Lab Contract)

> الملف ده هو "العقد" اللي كل أجزاء المعمل ماشية عليه: Docker و Terraform و Ansible و Kubernetes و GitHub Actions و CodeBuild.
> لو غيّرت اسم أو بورت أو متغير، غيّره هنا الأول وبعدين في الكود.

---

## 1) الأسماء والـ Tags

| البند | القيمة |
|---|---|
| Project | `student-app` |
| Environment | `lab` (ممكن `staging` / `prod` بنفس الهيكل) |
| AWS Region | variable، الافتراضي `us-east-1` |
| GitHub repo | `Ahmed-Reda-Ragab/StudentHub` (Terraform variable `github_repo`) |
| Resource name prefix | `student-app-lab-<thing>` مثال: `student-app-lab-alb` |
| Tags إجبارية | `Project=student-app`, `Env=lab`, `ManagedBy=terraform\|console\|ansible`, `Scenario=<id>` |

في Terraform الـ tags بتتحط مرة واحدة في `provider "aws" { default_tags { ... } }`.

---

## 2) الـ Container

| البند | القيمة |
|---|---|
| Dockerfile | `docker/Dockerfile` (multi-stage: vendor → assets → runtime) |
| Base image | `serversideup/php:8.3-fpm-nginx-alpine-v5.0.5` (build arg `PHP_IMAGE`) |
| User | `www-data` (UID/GID **82** على Alpine) — non-root |
| Port | **8080** (HTTP) |
| Stop signal | `SIGQUIT` (graceful لـ PHP-FPM)، `stop_grace_period` 30s |
| Image name | `student-app` — في ECR: `<account>.dkr.ecr.<region>.amazonaws.com/student-app` |
| Tags | **git short SHA (7)** — immutable. ممنوع `latest` في أي deploy |
| Build args | `APP_VERSION` (= SHA), `VCS_REF` (full SHA), `BUILD_DATE` |
| Logs | JSON على stderr (`LOG_CHANNEL=stderr`, `LOG_STDERR_FORMATTER=Monolog\Formatter\JsonFormatter`) |
| Migrations | **مرة واحدة لكل release** كخطوة منفصلة: `php artisan migrate --force` (compose `run --rm` / ECS one-off task / K8s Job أو Helm hook). ممنوع تشغيلها مع كل replica عند الـ boot (`AUTORUN_LARAVEL_MIGRATION=false`) |
| Laravel caches | `AUTORUN_ENABLED=true` → `php artisan optimize` عند تشغيل الـ container (config/route/view/event cache) بالـ env وقت التشغيل |

> ملاحظة عن `migrate --isolated`: محتاج cache lock. مع `CACHE_STORE=database` الجدول `cache_locks` مش موجود في أول migration، فالأمر هيفشل على قاعدة بيانات فاضية. استخدمه بس لما يكون الـ cache على Redis (scenario 49) أو بعد أول migration.

---

## 3) Endpoints

| Endpoint | النوع | Middleware | الاستخدام |
|---|---|---|---|
| `GET /up` | **Liveness** | بدون session | Docker healthcheck، K8s livenessProbe، ECS container healthCheck. مش بيلمس الداتابيز |
| `GET /ready` | **Readiness** | بدون session | ALB target group health check، K8s readinessProbe. بيعمل DB ping. بيرجع `{"status","checks","version","color"}`، 200 أو 503 |
| `GET /metrics` | Prometheus | بدون session | محتاج `METRICS_ENABLED=true`، والـ token اختياري (`METRICS_TOKEN`، Bearer). **يتقفل على الـ LB** |
| `/sre-lab/*` | Load / chaos | `EnsureSreLabEnabled` | 404 لو `SRE_LAB_ENABLED` مش `true`. لو `SRE_LAB_TOKEN` متحدد → لازم header `X-Lab-Token` |

### SRE lab endpoints

| Endpoint | Params (مع الـ caps) | الغرض |
|---|---|---|
| `GET /sre-lab/ping` | — | baseline بدون DB |
| `GET /sre-lab/version` | — | version / color / hostname (عشان تشوف توزيع الـ traffic) |
| `GET /sre-lab/latency` | `ms` (200)، `jitter` (0) ≤ `SRE_LAB_MAX_LATENCY_MS` (10000) | latency SLO |
| `GET /sre-lab/error` | `rate` 0..1 (1)، `code` 500..599 (500) | error budget burn |
| `GET /sre-lab/cpu` | `ms` (200) ≤ `SRE_LAB_MAX_CPU_MS` (5000) | autoscaling على CPU |
| `GET /sre-lab/memory` | `mb` (32) ≤ `SRE_LAB_MAX_MEMORY_MB` (128)، `hold_ms` (100) | memory limits / OOM |
| `GET /sre-lab/db` | `limit` (50) ≤ 500 | قراءة عادية بـ index |
| `GET /sre-lab/db/heavy` | — | aggregate تقيل (group by): bottleneck الداتابيز |
| `POST /sre-lab/unready` / `POST /sre-lab/ready` | — | drain يدوي لـ instance معيّن (flag في `storage/framework/sre-lab-unready`) |

### Bad-release fault injection (بالـ env بس، نفس الـ image)

| Env | الأثر | مين يكشفه |
|---|---|---|
| `SRE_FAULT_ERROR_RATE=0.5` | 50% من صفحات الـ web بترجع 500 | canary analysis / burn-rate alarms (الـ health checks بتفضل ناجحة) |
| `SRE_FAULT_LATENCY_MS=800` | latency زيادة على صفحات الـ web | latency SLO alarms |
| `SRE_FAULT_UNHEALTHY=true` | `/up` = 500 و `/ready` = 503 | LB / K8s health checks → rollback |
| `SRE_FAULT_BOOT_FAIL=true` | الـ container يقفل نفسه عند الـ boot | ECS circuit breaker / CrashLoopBackOff / ASG refresh rollback |

> كل الـ faults (ما عدا BOOT_FAIL) مش بتشتغل غير لو `SRE_LAB_ENABLED=true`.

---

## 4) متغيرات التطبيق (Runtime env)

| Key | Lab default | سرّي؟ |
|---|---|---|
| `APP_KEY` | `base64:` + 32 random bytes | ✅ |
| `APP_ENV` / `APP_DEBUG` | `production` / `false` | |
| `APP_URL` | `http://<alb-or-host>` | |
| `APP_VERSION` | جوه الـ image (build arg) | |
| `DEPLOY_COLOR` | `blue` / `green` / `canary` / `stable` / `none` | |
| `DB_CONNECTION`, `DB_HOST`, `DB_PORT`, `DB_DATABASE`, `DB_USERNAME` | `mysql`, `mysql` أو RDS endpoint, `3306`, `student_app`, `student` | |
| `DB_PASSWORD` | random | ✅ |
| `SESSION_DRIVER` / `CACHE_STORE` | `database` (أو `redis` في scenario 49) | |
| `REDIS_HOST` | ElastiCache endpoint (scenario 49) | |
| `SRE_LAB_ENABLED`, `SRE_LAB_TOKEN`, `METRICS_ENABLED`, `METRICS_TOKEN` | `true`, random, `true`, اختياري | token ✅ |
| `SRE_FAULT_*` | `0` / `false` | |
| `LOADTEST_USERS`, `LOADTEST_STUDENTS_PER_USER` | `20`, `100` | |

### SSM Parameter Store layout (مصدر الحقيقة للـ secrets)

```
/student-app/<env>/app/<ENV_KEY>      → يتحول لـ env للتطبيق (app.env / ECS secrets / K8s Secret عن طريق ESO)
/student-app/<env>/mysql/<ENV_KEY>    → env لـ MySQL container (scenarios 20–27 بس)
```

أمثلة: `/student-app/lab/app/APP_KEY` (SecureString)، `/student-app/lab/app/DB_PASSWORD` (SecureString)، `/student-app/lab/app/DB_HOST` (String).

### الـ image اللي المفروض يشتغل (ASG / immutable instances)

```
/student-app/<env>/deploy/<blue|green>/IMAGE_URI    (String)  مثال: 123456789012.dkr.ecr.us-east-1.amazonaws.com/student-app:3f2c1ab
```

الـ user-data بتاع الـ Launch Template بيقرا الـ parameter ده وقت الـ boot. الـ deploy على ASG = `put-parameter` بالـ image الجديد ثم `start-instance-refresh`. Terraform بيعمل الـ parameter بقيمة أولية بس، وبيعمل `ignore_changes = [value]` عشان الـ CI هو اللي بيملكه.

- **EC2:** `deploy/ec2/render-env-from-ssm.sh` → `/opt/student-app/app.env` (chmod 600)
- **ECS:** `secrets[].valueFrom = arn:aws:ssm:<region>:<acct>:parameter/student-app/lab/app/APP_KEY`
- **EKS:** External Secrets Operator (`ClusterSecretStore` provider `ParameterStore`) → Secret `student-app-secrets`
- **Secrets Manager:** للـ RDS master password مع rotation (scenario 81) كبديل

---

## 5) SLOs (نفس الأرقام في k6 و Prometheus و CloudWatch والـ docs)

| SLI | التعريف | SLO |
|---|---|---|
| Availability | requests مش 5xx ÷ كل الـ requests على app routes (من غير `sre-lab.*` و `up` و `health.ready` و `metrics`) | **99.5% / 30 يوم** (error budget = 0.5% ≈ 3h 36m) |
| Latency | نسبة الـ requests الأسرع من **300ms** (histogram bucket `le="0.3"`) | **95%** |
| Latency tail | p99 | < 1s |

- Prometheus metrics: `student_app_http_requests_total{method,route,status}`، `student_app_http_request_duration_seconds_bucket{method,route,le}`، `student_app_app_info{version,color}`
- Burn-rate alerts (multi-window): 14.4× (1h و 5m) → page، 6× (6h و 30m) → page، 1× (3d و 6h) → ticket
- **Drill SLI منفصل:** traffic على `/sre-lab/error` عمره ما بيحرق الـ budget الحقيقي. ليه recording rules خاصة بيه (`job:student_app_sli_drill_errors:ratio_rate*`) و alerts بـ label `drill="true"` بتروح لـ receiver اسمه "drill" مش للـ pager. عشان تحرق الـ SLO الحقيقي استخدم `SRE_FAULT_ERROR_RATE` (أو `error-budget-burn.js MODE=app`).
- Recording rules: `job:student_app_sli_availability_errors:ratio_rate{5m,30m,1h,2h,6h,1d,3d,30d}`، `job:student_app_sli_latency_good:ratio_rate*`. Alerts: `SLOAvailability{FastBurn,SlowBurn,BudgetBurn}`، `SLOLatency{FastBurn,SlowBurn,BudgetBurn}`، `SLOLatencyTailP99High`، `SLODrill*`، `StudentAppNoTargetsUp`
- CloudWatch (Terraform `modules/observability`): `student-app-lab-slo-fast-burn` / `-slo-slow-burn` (composite)، `-alb-5xx-ratio`، `-alb-latency-p95`، `-<blue|green>-unhealthy-hosts`، `-rds-cpu`، `-rds-free-storage`. الـ FIS stop conditions بتستخدمهم
- ⚠️ **الـ alarms اللي على CloudWatch مبنية على ALB metrics، والـ ALB مش بيقدر يستثني `/sre-lab/*`.** يعني drill بـ `/sre-lab/error` (أو `error-budget-burn.js MODE=lab`) على الـ ALB **هيشغّل** `slo-fast-burn` وهيبعت email. الفصل بين الـ drill والـ budget الحقيقي موجود في Prometheus بس. على AWS اعمل الـ drills وانت عارف كده، أو اعمل mute للـ SNS subscription وقتها
- `/sre-lab/*` على الـ ALB محمي بـ `SRE_LAB_TOKEN` بس. خلي `sre_lab_enabled = false` في أي stack مش بتعمل عليه drills
- k6 thresholds: `http_req_failed: rate<0.005` (load)، `http_req_duration{expected_response:true}: p(95)<${P95_MS:-500}` (الـ default في CI أعلى شوية لأن الـ runner ضعيف؛ الـ SLO الحقيقي 300ms)

---

## 6) Terraform

| البند | القيمة |
|---|---|
| Terraform | `>= 1.11` (S3 native locking `use_lockfile = true` بقى GA في 1.11، من غير DynamoDB). الـ CI مثبت على `~1.14` |
| AWS provider | `~> 6.0` |
| Layout | `infra/terraform/bootstrap/` (مرة واحدة، long-lived) · `infra/terraform/modules/<name>/` · `infra/terraform/stacks/<NN-name>/` (ephemeral: apply → جرّب → destroy) |
| State | S3 bucket `student-app-tfstate-<account_id>` · key `stacks/<NN-name>/terraform.tfstate` |
| Backend config | الـ `key` متثبت جوه كل stack (`backend "s3" { key = "stacks/<NN>/terraform.tfstate" }`)، والـ bucket/region/`use_lockfile` من `terraform init -backend-config=../../backend.hcl` (`backend.hcl.example` جنبها، والـ `backend.hcl` نفسه gitignored) |
| Variables مشتركة | `project` (student-app)، `env` (lab)، `region` (us-east-1)، `github_repo` |
| Files لكل stack | `versions.tf`، `providers.tf`، `variables.tf`، `main.tf`، `outputs.tf`، `terraform.tfvars.example`، `README.md` |

### Stacks

| Stack | Scenarios | فيه إيه |
|---|---|---|
| `bootstrap` | 02, 30, 80 | state bucket، GitHub OIDC provider + roles (`student-app-gha-ci`, `student-app-gha-deploy`, `student-app-gha-terraform`)، ECR repo (IMMUTABLE، scan on push، lifecycle)، CodeConnections (GitHub) |
| `20-ec2-single` | 20–27, 31–33 | network (no NAT) + EC2 (AL2023، user-data) + SG + EIP + instance profile (SSM, ECR pull, SSM params, CW agent, S3 backups) + backups bucket + SSM params |
| `35-codebuild` | 35 | CodeBuild projects (CI، image build+push، runner لـ GitHub Actions) |
| `36-codepipeline` | 36, 37, 58 | CodePipeline: Source (CodeConnections) → Build → Deploy (ECS standard / CodeDeploy blue-green) |
| `40-ec2-alb-asg` | 40–49 | network + ALB (blue/green TGs، weighted listener) + Launch Template + ASG(s) + RDS + Redis (اختياري) + scaling + alarms + ACM/Route53 (اختياري) |
| `50-ecs-fargate` | 50–58 | network + ALB + RDS + ECS cluster/service/task def، deployment controller (ECS rolling/native B-G/linear/canary أو CODE_DEPLOY)، autoscaling، Spot، Exec |
| `60-eks` | 60–6A | VPC + EKS (managed nodes / Spot) + add-ons + Pod Identity (LBC, ESO) + Helm releases اختيارية + RDS |

### Module interfaces (inputs → outputs)

- `network`: `name, cidr="10.20.0.0/16", az_count=2, enable_nat=false, single_nat=true` → `vpc_id, vpc_cidr, azs, public_subnet_ids, private_subnet_ids`
- `alb`: `name, vpc_id, subnet_ids, certificate_arn=null, health_check_path="/ready"` → `alb_arn, alb_arn_suffix, dns_name, zone_id, security_group_id, listener_http_arn, listener_https_arn, target_group_arns{blue,green}, target_group_arn_suffixes{blue,green}`
- `rds-mysql`: `name, vpc_id, subnet_ids, allowed_security_group_ids, instance_class="db.t4g.micro", engine_version="8.4", multi_az=false, ssm_prefix` → `address, port, db_name, username, security_group_id, password_ssm_arn` (وبيكتب `DB_HOST/DB_PORT/DB_DATABASE/DB_USERNAME/DB_PASSWORD` في `ssm_prefix`)
- `ec2-docker-host`: `name, vpc_id, subnet_id, instance_type, arch, key_name=null, ingress_cidrs, ssh_cidrs=[], user_data, instance_profile` → `instance_id, public_ip, public_dns, security_group_id`
- `asg-app`: `name, vpc_id, subnet_ids, target_group_arns, image_uri, ami_id=null, instance_type, min, max, desired, ssm_prefix` → `asg_name, launch_template_id, security_group_id`
- `ecs-fargate`: `name, vpc_id, subnet_ids, alb_security_group_id, target_group_arns, image_uri, ssm_prefix, deployment_controller="ECS", deployment_strategy="ROLLING"` → `cluster_name, service_name, task_definition_arn, task_role_arn, execution_role_arn, log_group_name, security_group_id`
- `observability`: `name, alarm_email, alb_arn_suffix, target_group_arn_suffixes, asg_name/ecs names (optional)` → `sns_topic_arn, dashboard_name, alarm_arns`

---

## 7) Ansible

- `infra/ansible/` (`ansible.cfg`، `requirements.yml`، `inventories/lab/{aws_ec2.yml,hosts.ini.example}`، `group_vars/`، `roles/`، `playbooks/`)
- Dynamic inventory: plugin `amazon.aws.aws_ec2`، filter `tag:Project=student-app`، groups من `tag:Role` (`role_app`).
- Connection: SSH (`ec2-user`) أو **SSM** (`amazon.aws.aws_ssm`، من غير بورت 22). الاختيار في `group_vars`.
- App dir على السيرفر: `/opt/student-app` (`app.env`، `mysql.env`، `docker-compose.prod.yml`، `CURRENT_RELEASE`، `PREVIOUS_RELEASE`، `lb/`).

---

## 8) Kubernetes

| البند | القيمة |
|---|---|
| Namespace | `student-app` |
| Labels | `app.kubernetes.io/name=student-app`، `app.kubernetes.io/part-of=student-app-lab` |
| Probes | startup `/up`، liveness `/up`، readiness `/ready` (port `http`=8080) |
| Graceful | `preStop` sleep 10s، `terminationGracePeriodSeconds: 40` |
| Security | `runAsNonRoot`، `runAsUser/Group 82`، `allowPrivilegeEscalation: false`، drop ALL caps |
| Secret | `student-app-secrets` (من ESO على EKS، أو `kubectl create secret` على kind) |
| Migrations | Helm hook Job (`pre-install,pre-upgrade`) |
| Metrics | annotations `prometheus.io/scrape: "true"`، `prometheus.io/port: "8080"`، `prometheus.io/path: /metrics` + ServiceMonitor اختياري |

---

## 9) GitHub Actions — Repository variables / secrets

| Name | النوع | المصدر |
|---|---|---|
| `AWS_REGION` | variable | `us-east-1` |
| `AWS_ROLE_ARN` | variable | bootstrap output `github_ci_role_arn` (push لـ ECR) |
| `AWS_DEPLOY_ROLE_ARN` | variable | bootstrap output `github_deploy_role_arn` |
| `AWS_TERRAFORM_ROLE_ARN` | variable | bootstrap output `github_terraform_role_arn` (apply/destroy، بيثق في main/master و `environment:lab` بس) |
| `AWS_TERRAFORM_PLAN_ROLE_ARN` | variable | bootstrap output (read-only، للـ plan على الـ PRs) |
| `TF_STATE_BUCKET` | variable | bootstrap output `state_bucket` |
| `CODECONNECTIONS_ARN` | variable | bootstrap output `codeconnections_arn`، terraform.yml بيبعته `TF_VAR_codeconnections_arn` (stacks 35/36) |
| `ECS_IMAGE_TAG` | variable | أول image لـ stack 50 (`TF_VAR_image_tag`)، وبعد كده `deploy-ecs.yml` هو اللي بيملكه |
| `ECR_REPOSITORY` | variable | `student-app` |
| `EC2_INSTANCE_ID` | variable | stack 20 output |
| `EC2_HOST` | variable | stack 20 output (لسيناريو SSH بس) |
| `ECS_CLUSTER` / `ECS_SERVICE` | variable | stack 50 outputs |
| `ECS_APP_URL` | variable | stack 50 output `app_url` (smoke test بعد الـ deploy) |
| `ECS_CODEDEPLOY_APPLICATION` / `ECS_CODEDEPLOY_DEPLOYMENT_GROUP` | variable | stack 50 (لو `deployment_controller = "CODE_DEPLOY"`)، الافتراضي `student-app-lab-ecs` |
| `EKS_CLUSTER` | variable | stack 60 output |
| `EC2_TARGET_SCENARIO` | variable | الـ tag `Scenario` للسيرفر اللي الـ SSM workflows بتستهدفه (افتراضي `20`) |
| `EC2_CONTINUOUS_DEPLOY` | variable | `true` = deploy تلقائي لـ EC2 بعد نجاح CI على main (opt-in) |
| `ANSIBLE_SSM_BUCKET` | variable | bootstrap output `ansible_ssm_bucket` (Ansible over SSM) |
| `EC2_SSH_USER` / `EC2_SSH_KNOWN_HOSTS` | variable | scenario 31 بس (`ec2-user` + سطر `ssh-keyscan`) |
| `ALB_LISTENER_ARN` / `TG_BLUE_ARN` / `TG_GREEN_ARN` | variable | stack 40 outputs (deploy-asg.yml) |
| `ASG_NAME_BLUE` / `ASG_NAME_GREEN` | variable | stack 40 outputs (افتراضي `student-app-<env>-<color>`) |
| `CANARY_ALARM_NAME` / `REFRESH_ALARM_NAMES` | variable | افتراضي `student-app-<env>-alb-5xx-ratio` |
| `ENV_NAME` / `APP_URL` | environment variable | لكل GitHub environment (`lab`، `production`)؛ و production كمان `EC2_INSTANCE_ID` و `AWS_DEPLOY_ROLE_ARN` |
| `EC2_SSH_PRIVATE_KEY` | **secret** | scenario 31 بس (الطريقة القديمة؛ SSM أحسن) |
| `SRE_LAB_TOKEN` | **secret** | نفس قيمة `/student-app/lab/app/SRE_LAB_TOKEN` |

Environments: `lab` (ضيف required reviewer عليه لو عايز approval قبل الـ `terraform apply`. الـ deploys على lab هتستنى نفس الموافقة)، `production` (required reviewers + wait timer) — scenario 34.
**مهم:** الـ OIDC subject بتاع `environment:lab` مفيهوش branch، والـ admin Terraform role بيثق فيه. عشان كده في **Settings → Environments → lab → Deployment branches and tags** اختار **Selected branches** (`main`/`master` بس)، وإلا أي branch هيقدر يعمل apply بعد الموافقة.
`bootstrap` بيطلع output اسمه `github_repository_variables` فيه كل القيم دي جاهزة.

---

## 10) k6 (loadtest/k6)

- Env: `BASE_URL` (افتراضي `http://localhost:8080`)، `LAB_TOKEN`، `LOADTEST_USERS` (عدد مستخدمي `loadtest{N}@example.com`)، `PASSWORD` (`password`)، `VUS`، `DURATION`، `P95_MS`.
- الـ scripts بتفشل (exit ≠ 0) لو حصل threshold breach. **الـ thresholds هي الـ SLOs.**
- Login: `GET /login` → استخرج `_token` → `POST /login`. الفورمز محتاجة `_token` و `_submission_token` (UUID v4).

---

## 11) Docs (scenarios/*.md)

- اسم الملف: `docs/devops/scenarios/NN-<slug>.md` على قالب `_scenario-template.md`.
- اللغة: شرح بالعربي، والمصطلحات والأوامر والكود بالإنجليزي.
- كل أمر يتكتب في code block كامل ينفع ينسخ ويشتغل (مع placeholders واضحة زي `<ACCOUNT_ID>`).
- كل سيناريو بيشاور على الملفات الحقيقية في الـ repo بـ relative links.
- التكلفة التقريبية + خطوات المسح (Teardown) **إجباري** في كل سيناريو فيه موارد AWS.
