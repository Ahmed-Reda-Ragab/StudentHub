# H/I — Observability و SRE (12، 70–77) و الأمان (80–83): كروت الملخص

> كارت لكل سيناريو. التفاصيل في [`../scenarios/`](../scenarios/). الأسعار تقريبية (us-east-1) — راجع صفحة الأسعار.

### 12 — SRE lab endpoints + Prometheus/Grafana محلي + k6
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

### 70 — Logging (JSON → CloudWatch Logs Insights، Loki)
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

### 71 — Metrics و Dashboards (Prometheus، Grafana، CloudWatch)
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

### 72 — Tracing بـ OpenTelemetry
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

### 73 — SLI/SLO و Error budget و Burn-rate alerts
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

### 74 — Load testing بـ k6 (smoke→soak→breakpoint)
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

### 75 — Chaos engineering بـ AWS FIS + Game day
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

### 76 — Incident response (runbooks، postmortem)
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

### 77 — Backup و Disaster Recovery (RTO/RPO)
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

### 80 — IAM و OIDC و Least privilege و Session Manager
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

### 81 — إدارة الـ Secrets (SSM مقابل Secrets Manager، rotation)
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

### 82 — Supply chain (Trivy، SBOM، cosign، Dependabot، checkov)
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

### 83 — Edge security (WAF، HTTPS، headers، rate limiting)
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
