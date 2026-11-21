# 70 — Logging (JSON → CloudWatch Logs Insights، Loki)

> **الهدف في سطر:** تفهم ليه اللوجز JSON على stderr، وإزاي بتوصل من الـ container لـ CloudWatch Logs (awslogs) أو لـ Loki (Alloy)، تكتب Logs Insights و LogQL queries بتجاوب على أسئلة incident حقيقية، تظبط الـ retention والتكلفة، وتعرف إيه اللي **ممنوع** يتكتب في لوج.
> **المستوى:** Intermediate · **الوقت:** ~3 ساعات · **التكلفة التقريبية:** سنتات (CloudWatch Logs) / مجاني محلياً
> **بيعتمد على:** [12](12-sre-lab-endpoints-and-local-observability.md) · [20](20-ec2-compose-console.md) أو [42](42-alb-asg-launch-template.md) أو [51](51-ecs-fargate-terraform.md) · **الملفات في الـ repo:** [`config/logging.php`](../../../config/logging.php) · [`docker/Dockerfile`](../../../docker/Dockerfile) · [`deploy/ec2/compose.awslogs.yml`](../../../deploy/ec2/compose.awslogs.yml) · [`docker-compose.prod.yml`](../../../docker-compose.prod.yml) · [`observability/cloudwatch/logs-insights-queries.md`](../../../observability/cloudwatch/logs-insights-queries.md) · [`observability/compose/alloy/config.alloy`](../../../observability/compose/alloy/config.alloy) · [`observability/compose/loki/config.yaml`](../../../observability/compose/loki/config.yaml) · [`infra/terraform/modules/observability/main.tf`](../../../infra/terraform/modules/observability/main.tf)

## 1) الفكرة (Concepts)

الـ metrics بتقولك **إن** فيه مشكلة (5xx ratio طلع)؛ اللوجز بتقولك **إيه** المشكلة (`SQLSTATE[HY000] [2002] Connection refused`). في الـ containers القاعدة (12-factor): **التطبيق مش بيدير ملفات لوج** — بيكتب stream على stdout/stderr، والـ platform (Docker، ECS، K8s) هي اللي بتوديه مكان ما.

**Structured logging** = كل سطر JSON بـ fields ثابتة (`level_name`، `message`، `context`...) بدل نص حر. الفايدة: تعمل `filter level_name = "ERROR"` و `stats count(*) by context.exception.class` بدل regex هش.

| المصطلح | المعنى |
|---|---|
| Log level | شدة الحدث. Monolog: DEBUG=100، INFO=200، NOTICE=250، WARNING=300، ERROR=400، CRITICAL=500، ALERT=550، EMERGENCY=600 |
| Channel | في Laravel: وجهة اللوج (`stack`، `single`، `stderr`...) — `LOG_CHANNEL` |
| Formatter | شكل السطر: `LineFormatter` (نص) أو `JsonFormatter` |
| Log driver | إزاي Docker بيتعامل مع stdout/stderr: `json-file` (ملف على الـ host)، `awslogs` (CloudWatch)، `local`... |
| Log group / stream | في CloudWatch: الـ group = التطبيق/البيئة (retention بتتحدد عليه)، الـ stream = مصدر واحد (container/task) |
| Metric filter | pattern على اللوجز بيطلّع CloudWatch metric (عدد الـ ERROR في الدقيقة) |
| Logs Insights | query language على CloudWatch Logs، بتدفع على الـ GB اللي اتعمله scan |
| Loki labels | Loki بيعمل index على الـ labels بس (مش المحتوى) — لازم يبقوا قليلين (low cardinality) |

## 2) المعمارية (Architecture)

```text
 PHP-FPM worker ── Log::error(...) ── Monolog stderr channel + JsonFormatter ──► stderr
 nginx (نفس الـ container) ── access log سطر نصي لكل request ──────────────────► stdout/stderr
                                     │
            ┌────────────────────────┼─────────────────────────────┬───────────────────────┐
            ▼                        ▼                             ▼                       ▼
   json-file (default)       awslogs (EC2 override)         awslogs (ASG user-data)   awslogs (ECS task def)
   10m × 5 rotation          compose.awslogs.yml            stream <color>/<instance>  stream app/app/<task-id>
   docker logs / Alloy       group /student-app/lab/app     group /student-app/lab/app group /ecs/student-app-lab/app
            │                        └──────────────┬──────────────┴───────────────────────┘
            ▼                                       ▼
   Alloy ─► Loki (7d) ─► Grafana Explore    CloudWatch Logs ─► Logs Insights · metric filter AppErrorLogs
                                                              (ALB access logs → S3 → Athena، مش Logs Insights)
```

## 3) المتطلبات (Prerequisites)

- [ ] محلياً: ستاك [12](12-sre-lab-endpoints-and-local-observability.md) (Loki + Alloy).
- [ ] على AWS: واحد من: host [20](20-ec2-compose-console.md)/stack `20-ec2-single`، أو stack `40-ec2-alb-asg` ([42](42-alb-asg-launch-template.md))، أو stack `50-ecs-fargate` ([51](51-ecs-fargate-terraform.md)).
- الأدوات: `aws` CLI v2، `jq`.

### 3.1 إزاي التطبيق بيكتب اللوج (من الكود)

[`docker/Dockerfile`](../../../docker/Dockerfile) بيحط الـ defaults:

```dockerfile
ENV LOG_CHANNEL=stderr \
    LOG_LEVEL=info \
    LOG_STDERR_FORMATTER="Monolog\\Formatter\\JsonFormatter"
```

و [`config/logging.php`](../../../config/logging.php) الـ channel `stderr`:

```php
'stderr' => [
    'driver' => 'monolog',
    'level' => env('LOG_LEVEL', 'debug'),
    'handler' => StreamHandler::class,
    'handler_with' => ['stream' => 'php://stderr'],
    'formatter' => env('LOG_STDERR_FORMATTER'),
    'processors' => [PsrLogMessageProcessor::class],   // بيبدّل {placeholders} في الـ message من الـ context
],
```

سطر حقيقي (من [`logs-insights-queries.md`](../../../observability/cloudwatch/logs-insights-queries.md)):

```json
{"message":"SQLSTATE[HY000] [2002] Connection refused","context":{"exception":{"class":"Illuminate\\Database\\QueryException","message":"…","code":2002,"file":"/var/www/html/vendor/…:825"}},"level":500,"level_name":"CRITICAL","channel":"production","datetime":"2026-11-21T10:15:03.123456+02:00","extra":{}}
```

> ⚠️ **إيه اللي مش هتلاقيه في لوج Laravel:** الـ `HttpException`s (404، 419 CSRF، والـ 500 المحقونة من `SRE_FAULT_ERROR_RATE`) و validation errors — Laravel مش بيعملهم report. هتلاقيهم في سطور nginx access log (نص) وفي الـ metrics/ALB. يعني: **عدد الـ 5xx تجيبه من الـ metrics، وسبب الـ 5xx الحقيقية (exceptions) من اللوجز.**

> 💡 الـ `LOG_LEVEL` بيتقري وقت الـ boot (`AUTORUN_ENABLED=true` بيعمل `php artisan optimize` = config cache). تغييره = restart/redeploy للـ container، مش "live".

## 4) الطريقة الأولى: AWS Console (يدوي)

### 4.1 الـ log group بـ retention (قبل أي حاجة)

1. **CloudWatch → Logs → Log groups → Create log group**.
2. Name: `/student-app/lab/app` · **Retention setting:** 1 week · Log class: **Standard** → **Create**.

> 💡 ليه الـ group لازم يبقى موجود قبل الـ container؟ `awslogs-create-group: "true"` في [`compose.awslogs.yml`](../../../deploy/ec2/compose.awslogs.yml) بيعمل الـ group لو مش موجود — بس بـ retention **Never expire**، ولوج lab بيفضل يتراكم ويتحاسب storage للأبد. الـ Terraform بيعمله مسبقاً في كل الـ stacks: stack 20 → `/student-app/<env>/app` بـ `log_retention_days` (14)، stack 40 → نفس الاسم بـ retention 7، والـ ECS module → `/ecs/student-app-lab/app` بـ retention 14. الخطوات اليدوية دي للـ host اللي عملته من الـ Console ([20](20-ec2-compose-console.md)).

### 4.2 شحن لوجز الـ EC2 host لـ CloudWatch

الـ instance profile بتاع stack 20/40 فيه `CloudWatchAgentServerPolicy` (فيه `logs:CreateLogStream`/`PutLogEvents`/`CreateLogGroup`). على الـ host (Session Manager):

```bash
cd /opt/student-app/src
export AWS_REGION=us-east-1 HOSTNAME=$(hostname)          # HOSTNAME لازم يبقى exported وإلا الـ stream = "ec2-app"
docker compose -f docker-compose.prod.yml -f deploy/ec2/compose.awslogs.yml up -d --no-deps app
docker inspect --format '{{.HostConfig.LogConfig.Type}}' $(docker compose -f docker-compose.prod.yml ps -q app)   # awslogs
docker compose -f docker-compose.prod.yml logs --tail=5 app   # لسه شغال: Docker ≥ 20.10 "dual logging" (cache محلي)
```

`mode: non-blocking` + `max-buffer-size: 4m`: لو CloudWatch بطيء/مش متاح، Docker بيحط في buffer، ولو اتملى **بيرمي سطور** بدل ما يوقف PHP عن الكتابة على stderr. الـ trade-off: availability للتطبيق > اكتمال اللوج. الـ `blocking` (الافتراضي) ممكن يعلّق الـ requests لو CloudWatch مش بيرد.

> ⚠️ الـ override ده على service `app` بس (ستاك الـ Recreate). ستاك الـ blue/green ([`deploy/ec2/lb/docker-compose.yml`](../../../deploy/ec2/lb/docker-compose.yml)) بيستخدم `json-file` لـ `app_blue`/`app_green` — لو عايزه في CloudWatch اعمل override مشابه للـ services دي.

### 4.3 Logs Insights

1. **CloudWatch → Logs → Logs Insights** → اختار `/student-app/lab/app` (أو `/ecs/student-app-lab/app`).
2. ضيّق الـ time range (**أهم حاجة في التكلفة** — بتدفع على الـ scan).
3. الصق query من §5.2 → **Run query**. Logs Insights بيكتشف الـ JSON fields لوحده (`level_name`، `message`، `context.exception.class`)، والسطور اللي مش JSON (nginx) ليها `@message` بس.
4. **Save** للـ queries اللي هتحتاجها في الـ incidents (بتظهر في **Saved queries**).

### 4.4 Metric filter + alarm على عدد الـ ERROR

1. Log group → **Metric filters → Create metric filter**.
2. Filter pattern:
   ```text
   { ($.level_name = "ERROR") || ($.level_name = "CRITICAL") || ($.level_name = "ALERT") || ($.level_name = "EMERGENCY") }
   ```
3. **Test pattern** على sample → Next.
4. Filter name `student-app-lab-app-error-logs` · Namespace `StudentApp/student-app-lab` · Metric name `AppErrorLogs` · Value `1` · Default value `0` → **Create**.
5. (اختياري) **Create alarm** على الـ metric: Sum > 10 في 5 دقايق → SNS `student-app-lab-alerts`.

## 5) الطريقة التانية: Infrastructure as Code

### 5.1 فين الـ logging متعرّف في الـ IaC

| المكان | اللي بيعمله |
|---|---|
| [`docker-compose.prod.yml`](../../../docker-compose.prod.yml) | `json-file` بـ `max-size: 10m`، `max-file: 5` للـ app و 3 للـ MySQL → حد أقصى ~50MB لوج للـ app على الـ disk |
| [`deploy/ec2/compose.awslogs.yml`](../../../deploy/ec2/compose.awslogs.yml) | override: `awslogs`، group `/student-app/lab/app`، stream `${HOSTNAME:-ec2}-app`، non-blocking 4m |
| stack [`20-ec2-single/main.tf`](../../../infra/terraform/stacks/20-ec2-single/main.tf) | `aws_cloudwatch_log_group.app` = `/student-app/<env>/app`، retention `log_retention_days` (14) — جاهز للـ override قبل أول container |
| [`asg-app/user-data.sh.tftpl`](../../../infra/terraform/modules/asg-app/user-data.sh.tftpl) | لو `log_group_name` متحدد: `--log-driver awslogs` و `awslogs-stream=<color>/<instance-id>`، وإلا `json-file` 10m × 5 |
| stack [`40-ec2-alb-asg/main.tf`](../../../infra/terraform/stacks/40-ec2-alb-asg/main.tf) | `aws_cloudwatch_log_group.app` = `/student-app/lab/app`، retention 7 |
| [`ecs-fargate/main.tf`](../../../infra/terraform/modules/ecs-fargate/main.tf) | log group `/ecs/student-app-lab/app` (retention 14)، `awslogs-stream-prefix = "app"` → stream `app/app/<task-id>`، `mode: non-blocking`، `max-buffer-size: 25m` |
| [`observability/main.tf`](../../../infra/terraform/modules/observability/main.tf) | `aws_cloudwatch_log_metric_filter.app_errors` → metric `AppErrorLogs` في namespace `StudentApp/<name>` (لو `log_group_name` متمرر — stacks 40 و 50 بيمرروه) + widget "App ERROR+ log lines / min" في الـ dashboard |
| [`rds-mysql/main.tf`](../../../infra/terraform/modules/rds-mysql/main.tf) | `error` و `slowquery` exports لـ `/aws/rds/instance/student-app-lab-mysql/<type>` بـ retention 7، و `long_query_time = 1` |
| [`fis/main.tf`](../../../infra/terraform/modules/fis/main.tf) | `/aws/fis/student-app-lab` (retention 14) للـ experiment logs |

لاحظ إن الـ module بيعمل الـ metric filter والـ widget بس — **مفيش alarm** على `AppErrorLogs`. ده مقصود (عدد اللوجز symptom ضعيف للـ paging؛ الـ burn rate أدق)، بس ممكن تضيفه كـ ticket.

```bash
cd infra/terraform/stacks/40-ec2-alb-asg        # أو 50-ecs-fargate
terraform output -raw log_group_name             # stack 40
terraform output -raw log_group                  # stack 50
aws logs describe-log-groups --log-group-name-prefix /student-app --query 'logGroups[].[logGroupName,retentionInDays]' --output table
aws logs describe-metric-filters --log-group-name /student-app/lab/app --query 'metricFilters[].[filterName,filterPattern]'
```

### 5.2 Logs Insights queries (من [`logs-insights-queries.md`](../../../observability/cloudwatch/logs-insights-queries.md))

**Errors كل 5 دقايق بالـ level** — أول query في أي incident:

```text
fields @timestamp, level_name
| filter level_name in ["ERROR", "CRITICAL", "ALERT", "EMERGENCY"]
| stats count(*) as errors by bin(5m), level_name
| sort bin(5m) desc
```

**الـ exceptions بالـ class** — `JsonFormatter` بيحط الـ exception في `context.exception`:

```text
fields @timestamp, context.exception.class as exception, context.exception.message as detail, context.exception.file as where
| filter ispresent(exception)
| stats count(*) as hits, latest(detail) as example, latest(where) as at by exception
| sort hits desc
```

**مشاكل الداتابيز** (RDS failover، max connections، password غلط بعد rotation):

```text
fields @timestamp, @logStream, message
| filter message like /SQLSTATE|Connection refused|Too many connections|Deadlock|server has gone away/
| stats count(*) as hits by bin(1m), @logStream
| sort bin(1m) desc
```

**مين الـ instance/task اللي بيزعّق** (`@logStream` = `blue/i-0abc…` أو `app/app/<task-id>`):

```text
fields @logStream, level_name
| filter level_name = "ERROR"
| stats count(*) as errors by @logStream
| sort errors desc
```

**مقارنة blue و green** (ASG: الـ stream بيبدأ بالـ color):

```text
fields @logStream, level_name
| filter level_name in ["ERROR", "CRITICAL"]
| parse @logStream /^(?<color>[a-z]+)\//
| stats count(*) as errors by color, bin(5m)
```

**nginx access lines** (نص، `parse` بـ regex — عدّل الـ pattern لو الـ format مختلف):

```text
fields @timestamp, @message
| filter @message like /HTTP\/[0-9.]+"/
| parse @message /"(?<method>[A-Z]+) (?<path>[^ ?"]+)[^"]* HTTP\/[0-9.]+" (?<status>\d{3})/
| filter ispresent(status)
| stats count(*) as requests by bin(5m), status
| sort bin(5m) desc
```

من الـ CLI (مفيد في الـ runbooks — [76](76-incident-response.md)):

```bash
aws logs tail /student-app/lab/app --since 15m --follow --format short
aws logs tail /ecs/student-app-lab/app --since 30m --filter-pattern '{ $.level_name = "ERROR" }'

QID=$(aws logs start-query --log-group-name /student-app/lab/app \
  --start-time $(date -d '-1 hour' +%s) --end-time $(date +%s) \
  --query-string 'fields @timestamp, level_name, message | filter level_name = "ERROR" | sort @timestamp desc | limit 20' \
  --query queryId --output text)
sleep 5; aws logs get-query-results --query-id "$QID" --query 'results[].[0].value'
```

**ALB access logs** مش في CloudWatch — بتروح S3 (`access_logs_bucket` في الـ alb module، افتراضياً مقفول) وبتتعمل query بـ Athena. الـ DDL و queries الـ availability/latency/مين طلّع الـ 5xx (target ولا الـ ALB) في نفس الملف — ده الـ SLI "زي ما المستخدم شافه" بما فيه الـ 502/504 اللي التطبيق عمره ما شافها.

### 5.3 Loki + Alloy محلياً

[`config.alloy`](../../../observability/compose/alloy/config.alloy) خطوة بخطوة:

1. `discovery.docker` — يلاقي كل container عن طريق الـ Docker API.
2. `discovery.relabel` — يحوّل metadata Docker لـ labels قليلة: `container`، `service` (compose service)، `compose_project`، `stream` (stdout/stderr). **عمره ما بيعمل label بـ request id أو user أو URL.**
3. `loki.source.docker` — يعمل tail للوجز ويضيف `source="docker"`.
4. `loki.process "laravel"` — على `{service=~"app|app_blue|app_green"}` بس: `stage.json` يطلّع `level_name` و `channel` → `level` يبقى **label** (5 قيم بس: رخيص) و `channel` **structured metadata** (مش indexed). سطور nginx مش JSON فـ `stage.json` بيعدّيها زي ما هي.
5. `loki.write` → `http://loki:3100/loki/api/v1/push`.

[`loki/config.yaml`](../../../observability/compose/loki/config.yaml): single binary، filesystem، schema `v13`/`tsdb`، `retention_period: 168h` (7 أيام) والـ compactor هو اللي بيمسح فعلاً (`retention_enabled: true`)، و `auth_enabled: false` (متعرّضوش من غير auth).

LogQL في Grafana → **Explore** → Loki:

```text
{service=~"app.*", level="ERROR"}                                   # index lookup (رخيص)
{service=~"app.*"} | json | level_name="CRITICAL"                    # parse وقت الـ query
{service="app"} |= "SQLSTATE"                                        # بحث نصي
{service="app"} | json | line_format "{{.level_name}} {{.message}}"
sum by (level) (count_over_time({compose_project="student-app"}[5m]))
sum by (service) (rate({compose_project="student-app"}[5m]))        # حجم اللوج لكل service
{service=~"app.*"} |~ `HTTP/[0-9.]+" 5[0-9]{2} `                     # سطور nginx بـ 5xx (عدّل لو الـ format مختلف)
```

## 6) الـ Deploy

### 6.1 محلياً

```bash
docker compose up -d --wait
docker compose -f observability/compose/docker-compose.yml up -d
# ولّد errors حقيقية: وقّف MySQL والتطبيق شغال
docker compose stop mysql
for i in $(seq 1 5); do curl -s -o /dev/null -w '%{http_code} ' http://localhost:8080/login; done; echo
docker compose logs --tail=5 app | grep -m3 level_name
docker compose start mysql
```

افتح Grafana → Explore → `{service="app", level=~"ERROR|CRITICAL"}` — هتلاقي `SQLSTATE[HY000] [2002]`. وقارن: `SRE_FAULT_ERROR_RATE=0.5` بيطلّع 500 بس **مفيش** سطر ERROR (HttpException مش بيتعمله report) — شوفه في `{service="app"} |~ "\" 500 "`.

### 6.2 على AWS

- **EC2 single host:** §4.2.
- **ASG (stack 40):** تلقائي — الـ user data بيستخدم `awslogs` على `/student-app/lab/app`.
- **ECS (stack 50):** تلقائي — `/ecs/student-app-lab/app`. اقرا لوج migration task: `aws logs tail /ecs/student-app-lab/app --since 10m` ([52](52-ecs-migrations-and-exec.md)).

### 6.3 على GitHub Actions

`lab-integration.yml` بيعمل `docker compose logs --tail=200` في step **Logs on failure** — نفس الـ JSON. اقراه بـ:

```bash
gh run view <RUN_ID> --log-failed | grep -o '{"message".*' | head
```

## 7) التحقق (Verify)

```bash
docker compose exec -T app php -r 'echo getenv("LOG_CHANNEL"), " ", getenv("LOG_STDERR_FORMATTER"), PHP_EOL;'
docker compose logs --tail=20 app | grep -c '"level_name"'                      # > 0 بعد أي خطأ
aws logs describe-log-streams --log-group-name /student-app/lab/app --order-by LastEventTime --descending --max-items 5 --query 'logStreams[].logStreamName'
aws cloudwatch get-metric-statistics --namespace StudentApp/student-app-lab --metric-name AppErrorLogs \
  --start-time $(date -u -d '-1 hour' +%FT%TZ) --end-time $(date -u +%FT%TZ) --period 300 --statistics Sum
```

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر | المتوقع |
|---|---|---|
| الـ formatter اتشال | `LOG_STDERR_FORMATTER=` (فاضي) في env | سطور نصية `[2026-…] production.ERROR: …` — Logs Insights مش شايف `level_name`، والـ metric filter بيطلّع صفر رغم وجود errors |
| `LOG_LEVEL=debug` | redeploy | حجم اللوج يتضاعف (= فاتورة ingestion) — شوفه بـ `stats count(*) by level_name, bin(1h)` |
| مفيش صلاحية CloudWatch (blocking) | شيل `CloudWatchAgentServerPolicy` واعمل container بـ `mode: blocking` | الـ container ممكن يفشل يبدأ (`failed to initialize logging driver`) — اللوج بقى dependency للتطبيق |
| نفس الحالة بـ non-blocking | سيب `mode: non-blocking` | التطبيق شغال، اللوجز بتضيع بصمت — محتاج alarm على غياب اللوج |
| `json-file` من غير rotation | شيل `max-size` في branch تجريبي + soak ([74](74-load-testing-k6.md)) | `/var/lib/docker/containers/*/*-json.log` بيكبر لحد ما الـ disk يتملى |
| Label بـ cardinality عالية | ضيف `stage.labels` بـ `message` في Alloy | Loki: "maximum active stream limit exceeded" وبطء — رجّعه |

## 9) الرجوع (Rollback)

```bash
docker compose -f docker-compose.prod.yml up -d --no-deps app          # من غير override = json-file تاني
aws logs put-retention-policy --log-group-name /student-app/lab/app --retention-in-days 7
```

## 10) المسح (Teardown) ⚠️

```bash
aws logs delete-log-group --log-group-name /student-app/lab/app          # بس لو اتعمل بإيدك/بـ create-group (stacks 20/40 بيمسحوه مع destroy)
aws logs describe-log-groups --log-group-name-prefix /aws/rds/instance/student-app --query 'logGroups[].logGroupName'
docker compose -f observability/compose/docker-compose.yml down -v       # Loki محلي
```

`terraform destroy` في stacks 40/50 بيمسح الـ log groups اللي هو عاملها. اتأكد من مفيش groups بـ **Never expire** فاضلة: `aws logs describe-log-groups --query 'logGroups[?!retentionInDays].logGroupName'`.

## 11) التكلفة (Cost)

| Resource | السعر التقريبي (us-east-1 — تقريبي، راجع صفحة الأسعار) |
|---|---|
| Ingestion (Standard) | ~$0.50/GB |
| Ingestion (Infrequent Access log class) | ~$0.25/GB (features أقل) |
| Storage | ~$0.03/GB-month (بعد الضغط) |
| Logs Insights | ~$0.005/GB scanned |
| Metric filter metric | custom metric (~$0.30/metric-month بعد الـ free tier) |
| Loki محلي | مجاني |

حسبة سريعة: سطر nginx ~200 byte لكل request → مليون request ≈ 0.2GB ≈ $0.10 ingestion. `LOG_LEVEL=debug` مع SQL logging ممكن يضرب ده في 10. الـ retention القصيرة + Standard vs IA + عدم لوج الـ health checks (هما أصلاً مش بيعملوا لوج Laravel، بس nginx بيكتب سطر لكل `/ready` كل 10s من كل target group) = أكبر 3 levers.

## 12) أسئلة Interview

<details><summary>ليه stderr و JSON بدل ملف `laravel.log`؟</summary>

الـ container ephemeral: الملف بيضيع مع الـ container، ومحتاج volume و rotation وagent يقراه. stdout/stderr بيخلي الـ platform (Docker driver، ECS awslogs، K8s node agent) مسؤولة عن الشحن والـ rotation. والـ JSON بيخلي الـ backend (Logs Insights، Loki) يفهم الـ fields من غير regex، فالـ queries أدق وأرخص.

</details>

<details><summary>awslogs `blocking` ولا `non-blocking`؟</summary>

`blocking` (default): مفيش سطر بيضيع، بس لو CloudWatch بطيء أو الـ credentials اتكسرت، الكتابة على stderr بتعلّق → الـ requests بتعلّق. `non-blocking` + `max-buffer-size`: التطبيق مش بيتأثر، بس لما الـ buffer يتملى السطور بتضيع. لـ web app الـ availability أهم، فـ non-blocking + alarm على "مفيش لوج وصل" أو على `IncomingLogEvents`. لـ audit logs إلزامية ممكن تختار العكس أو agent بـ disk buffer.

</details>

<details><summary>Loki ولا CloudWatch Logs ولا OpenSearch؟</summary>

CloudWatch: managed، متكامل مع IAM/alarms/ECS، بتدفع ingestion غالي نسبياً و scan. Loki: رخيص لأنه بيعمل index للـ labels بس والمحتوى chunks مضغوطة على object storage — بس الـ queries على المحتوى أبطأ ومحتاج تديره (أو Grafana Cloud). OpenSearch: full-text index قوي وغالي في التشغيل. القرار: الحجم، مين هيدير، ومحتاج full-text ولا لأ.

</details>

<details><summary>إزاي تربط سطر لوج بـ request معين وبـ trace؟</summary>

correlation id: middleware يقرا `X-Request-Id` (أو يولّده) ويحطه في الـ log context لكل اللوجز (في Laravel: `Log::withContext()` أو الـ `Context` facade) ويرجّعه في الـ response header. مع ALB: `X-Amzn-Trace-Id` بيتسجل في الـ access logs (`trace_id`) فممكن تربطه. مع OpenTelemetry: `trace_id`/`span_id` في كل سطر لوج → من الـ trace للوجز بضغطة ([72](72-tracing-opentelemetry.md)). ده **مش متطبق** في الـ repo — تمرين.

</details>

<details><summary>إيه اللي ممنوع يتكتب في اللوج؟</summary>

passwords، `APP_KEY`، session IDs و CSRF tokens، `Authorization`/`X-Lab-Token`/`METRICS_TOKEN` headers، الـ request bodies كاملة، و PII (أسماء وتليفونات الطلاب هنا — في مصر فيه قانون حماية البيانات الشخصية رقم 151 لسنة 2020). مصيدة Laravel: رسالة `QueryException` فيها الـ SQL **بالـ bindings** — يعني ممكن email أو تليفون يدخل اللوج. والـ stack traces فيها arguments (PHP 8.2 `#[\SensitiveParameter]` بيخفيها). وطبعاً `APP_DEBUG=false` دايماً.

</details>

<details><summary>إزاي تخلي الـ alerts مش معتمدة على اللوجز؟</summary>

اللوجز للتشخيص؛ الـ paging يبقى على SLO symptoms من الـ metrics (burn rate، 5xx ratio) لأنها أرخص وأسرع ومش بتتأثر بتغيير صياغة رسالة. الـ metric filters مفيدة لحاجات مالهاش metric (مثلاً `Deadlock found`)، بس كـ ticket مش page.

</details>

## 13) Checklist

- [ ] فهمت `LOG_CHANNEL`/`LOG_STDERR_FORMATTER` وشفت سطر JSON حقيقي
- [ ] اتأكدت إن الـ log group موجود بـ retention (Terraform أو بإيدك) قبل ما Docker يعمله
- [ ] شحنت لوجز host لـ CloudWatch بـ `compose.awslogs.yml` (أو استخدمت stack 40/50)
- [ ] شغّلت 4 queries على الأقل من `logs-insights-queries.md` وحفظتهم
- [ ] عملت metric filter `AppErrorLogs` (Console) وقارنته بالـ Terraform
- [ ] جرّبت LogQL في Grafana على Loki المحلي
- [ ] أقدر أقول إيه الممنوع في اللوج وليه
- [ ] مسحت أي log group بـ Never expire
