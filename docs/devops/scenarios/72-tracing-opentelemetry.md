# 72 — Tracing بـ OpenTelemetry

> **الهدف في سطر:** تفهم الـ distributed tracing (trace، span، context propagation، sampling)، تشغّل الـ OpenTelemetry Collector + Jaeger جنب التطبيق وتبعتله spans، تقرا الـ collector configs (X-Ray و Jaeger) سطر بسطر، وتعرف بالظبط إيه اللي التطبيق محتاجه عشان يتعمله instrumentation — مع فصل واضح بين **المتطبق** و **الـ design بس**.
> **المستوى:** Advanced · **الوقت:** ~3 ساعات · **التكلفة التقريبية:** مجاني محلياً / سنتات على X-Ray
> **بيعتمد على:** [12](12-sre-lab-endpoints-and-local-observability.md) · [71](71-metrics-dashboards.md) · **الملفات في الـ repo:** [`observability/otel/README.md`](../../../observability/otel/README.md) · [`collector-xray.yaml`](../../../observability/otel/collector-xray.yaml) · [`collector-jaeger.yaml`](../../../observability/otel/collector-jaeger.yaml) · [`observability/otel/docker-compose.yml`](../../../observability/otel/docker-compose.yml) · [`.github/workflows/observability-lint.yml`](../../../.github/workflows/observability-lint.yml)

## 1) الفكرة (Concepts)

الـ metrics بتقول **إن** الـ p95 طلع 900ms؛ اللوج بيقول **إيه** الـ error؛ الـ trace بيقول **الوقت راح فين**: 30ms في الـ middleware، 750ms في query واحدة على `subscriptions`، 80ms في الـ Blade render. في microservices الـ trace بيعدّي على كذا service، بس حتى في monolith زي ده الـ trace جوه الـ request الواحد (spans للـ SQL والـ cache) مفيد جداً.

| المصطلح | المعنى |
|---|---|
| Trace | رحلة request واحد من أوله لآخره — ليه `trace_id` (16 byte = 32 hex) |
| Span | عملية واحدة جوه الـ trace (HTTP server، SQL query، HTTP client call): اسم، start/end، attributes، status، `span_id` (8 byte) و `parent_span_id` |
| Context propagation | نقل `trace_id`/`span_id` بين الـ services في headers — المعيار W3C `traceparent` |
| `traceparent` | `00-<trace-id 32 hex>-<parent-span-id 16 hex>-<flags 2 hex>` — الـ flag `01` = sampled |
| Baggage | key/values بتتنقل مع الـ context (مثلاً `tenant=42`) |
| Resource | attributes عن مصدر الـ telemetry: `service.name`، `service.version`، `deployment.environment.name`، cloud/host |
| Sampling | تختار تحتفظ بأنهي traces. **Head** (القرار في أول الـ trace — رخيص، أعمى عن النتيجة) أو **tail** (بعد ما الـ trace يخلص — تقدر تحتفظ بالـ errors والبطيء، محتاج كل spans الـ trace في نفس الـ collector) |
| OTLP | بروتوكول OpenTelemetry (gRPC على 4317، HTTP على 4318) |
| Collector | pipeline: **receivers → processors → exporters**، بيفصل التطبيق عن الـ backend |
| Auto-instrumentation | hooks بتلف كود الـ framework من غير ما تعدّل الكود (في PHP: extension `opentelemetry`) |

### 1.1 المتطبق مقابل الـ design بس

| الحاجة | الحالة |
|---|---|
| `collector-xray.yaml` و `collector-jaeger.yaml` | ✅ في الـ repo، ومتعملهم `otelcol validate` في `observability-lint.yml` على كل push |
| `observability/otel/docker-compose.yml` (collector + Jaeger v2) | ✅ بيقوم ويستقبل OTLP — تقدر تبعتله spans بإيدك (§6.2) |
| Instrumentation التطبيق (PHP extension، composer packages، `OTEL_*` env) | ❌ **design بس** — الـ app مش instrumented، ومفيش ولا سطر من دول في `docker/Dockerfile` أو `composer.json` |
| Collector كـ sidecar في ECS / Operator على EKS | ❌ design |
| ربط traces الـ ALB (`X-Amzn-Trace-Id`) بالتطبيق (X-Ray propagator) | ❌ design |
| Trace ↔ logs correlation (`trace_id` في اللوج) | ❌ design |

> 💡 ليه الـ repo سايبه design؟ الـ instrumentation تغيير في الـ image والـ dependencies والـ latency، ولازم يتعمله review وقياس (overhead تحت load) قبل ما يدخل. الـ README كاتب المطلوب بالظبط عشان الـ PR يبقى واضح.

## 2) المعمارية (Architecture)

```text
 (design)                                              (موجود)
 Laravel (PHP-FPM + ext-opentelemetry + auto-laravel + auto-pdo)
   │  span لكل request + span لكل SQL، flush في آخر الـ request
   │  OTLP/HTTP protobuf → otel-collector:4318   (لازم collector محلي: sidecar / نفس الـ host)
   ▼
 ┌──────────────── OpenTelemetry Collector (contrib 0.165.0) ────────────────┐
 │ receivers: otlp (grpc 4317, http 4318)                                    │
 │ processors: memory_limiter → [resourcedetection env/ecs/ec2] → batch      │
 │ exporters:  otlp_grpc/jaeger ─► Jaeger v2 :4317 → UI :16686   (local)     │
 │             awsxray          ─► AWS X-Ray → CloudWatch → X-Ray traces     │
 │             debug            ─► سطر summary في لوج الـ collector           │
 │ extensions: health_check :13133                                           │
 └────────────────────────────────────────────────────────────────────────────┘
 ALB ── X-Amzn-Trace-Id ──► app   (ربطهم محتاج xray propagator — design)
```

## 3) المتطلبات (Prerequisites)

- [ ] الـ app stack شغال (`docker compose up -d`) — بيعمل الـ network `student-app_default`.
- [ ] للـ X-Ray: حساب AWS + role/profile بـ `AWSXrayWriteOnlyAccess`.
- الأدوات: `docker`، `curl`، `openssl`.

## 4) الطريقة الأولى: AWS Console (يدوي)

الـ X-Ray features بقت جوه **CloudWatch console** (ممكن لسه تلاقي الـ X-Ray console القديم):

1. **CloudWatch → X-Ray traces → Traces**: بحث بالـ filter expressions، مثلاً `annotation.http_route = "students.index"` (الـ `indexed_attributes` في الـ exporter بتتحول لـ annotations قابلة للبحث؛ النقطة في اسم الـ attribute بتتحول لـ `_` — اتأكد من الاسم في trace حقيقي).
2. **CloudWatch → X-Ray traces → Trace Map**: الـ service map (اتدمج فيه ServiceLens map).
3. **CloudWatch → Settings → X-Ray traces → Transaction Search** (اختياري): الـ spans بتتخزن في log group اسمه `aws/spans` وبتقدر تعمل عليها search/analytics، وبتتحاسب بأسعار CloudWatch Logs — راجع صفحة الأسعار قبل ما تفعّله.
4. **X-Ray → Sampling rules** (أو من CloudWatch settings): الـ default rule = أول request كل ثانية + 5% من الباقي، لكل host. تقدر تعمل rule بـ `URLPath = /ready` و rate 0 عشان الـ probes متملاش الـ traces.
5. **IAM**: الـ role اللي بيشغّل الـ collector (instance profile / ECS task role) محتاج `AWSXrayWriteOnlyAccess` (`xray:PutTraceSegments`، `xray:PutTelemetryRecords`، `xray:GetSamplingRules`/`Targets`...).

> ⚠️ **X-Ray SDKs والـ daemon** دخلوا maintenance mode في **25 فبراير 2026** والـ end of support **25 فبراير 2027**. الخدمة نفسها مستمرة وبتستقبل OpenTelemetry. يعني أي instrumentation جديد = **OpenTelemetry** (SDK أو ADOT)، مش X-Ray SDK — وده بالظبط اختيار الـ repo.

## 5) الطريقة التانية: as Code — الـ configs سطر بسطر

### 5.1 [`collector-xray.yaml`](../../../observability/otel/collector-xray.yaml)

```yaml
receivers:
  otlp: { protocols: { grpc: { endpoint: 0.0.0.0:4317 }, http: { endpoint: 0.0.0.0:4318 } } }
processors:
  memory_limiter: { check_interval: 1s, limit_percentage: 80, spike_limit_percentage: 25 }
  resourcedetection: { detectors: [env, ecs, ec2], timeout: 5s, override: false }
  batch: { send_batch_size: 512, timeout: 5s }
exporters:
  awsxray:
    region: ${env:AWS_REGION}
    indexed_attributes: [http.route, deployment.environment.name, service.version]
  debug: { verbosity: basic }
service:
  pipelines:
    traces: { receivers: [otlp], processors: [memory_limiter, resourcedetection, batch], exporters: [awsxray, debug] }
```

- **`memory_limiter` الأول في الـ pipeline**: لو الـ collector وصل 80% من الـ memory limit بيرفض data (التطبيق بيعمل retry/drop) بدل ما يتعمله OOM kill — ده بيحمي الـ task/الـ host.
- **`resourcedetection`**: بيضيف `cloud.*`، `aws.ecs.*`، `host.*` (من ECS metadata endpoint أو EC2 IMDS) — X-Ray بيعرضهم كـ metadata. `override: false` = اللي التطبيق باعته بيكسب.
- **`batch`**: يجمع 512 span أو 5 ثواني — أقل API calls وأرخص.
- **`indexed_attributes`**: الـ attributes دي بس بتبقى X-Ray **annotations** (searchable)؛ الباقي metadata. اختار attributes قليلة ومفيدة: الـ route، البيئة، الـ version (عشان تقارن canary/stable).
- **`debug`**: سطر لكل batch في لوج الـ collector — أسرع طريقة تثبت إن الـ data بتعدّي.

### 5.2 [`collector-jaeger.yaml`](../../../observability/otel/collector-jaeger.yaml)

نفس الـ receivers، `memory_limiter` + `batch` (2s)، والـ exporter:

```yaml
exporters:
  otlp_grpc/jaeger:          # otlp_grpc = الاسم الجديد للـ OTLP/gRPC exporter (otlp بقى alias deprecated)
    endpoint: jaeger:4317
    tls: { insecure: true }
```

Jaeger v2 بيستقبل OTLP مباشرة، فالـ collector هنا "مجرد forward" — بس وجوده في النص بيدّيك مكان واحد للـ batching، الـ memory limit، الـ sampling، تنضيف attributes حساسة، أو backend تاني بعدين من غير ما تلمس التطبيق.

### 5.3 اللي التطبيق محتاجه (design — من [`otel/README.md`](../../../observability/otel/README.md))

1. **الـ extension** في `docker/Dockerfile` (runtime stage):
   ```dockerfile
   USER root
   RUN install-php-extensions opentelemetry protobuf   # protobuf اختياري: encoding أسرع
   USER www-data
   ```
2. **Composer packages:**
   ```bash
   composer require open-telemetry/sdk open-telemetry/exporter-otlp \
     open-telemetry/opentelemetry-auto-laravel open-telemetry/opentelemetry-auto-pdo
   ```
   `auto-laravel` بيعمل spans للـ HTTP kernel والـ routes والـ cache والـ queue والـ Eloquent؛ `auto-pdo` span لكل SQL statement. الـ OTLP/HTTP exporter محتاج PSR-18 client — Guzzle موجود مع Laravel.
3. **Env (من غير كود):**

   | Var | قيمة المعمل | ليه |
   |---|---|---|
   | `OTEL_PHP_AUTOLOAD_ENABLED` | `true` | يشغّل الـ SDK والـ auto-instrumentation |
   | `OTEL_SERVICE_NAME` | `student-app` | |
   | `OTEL_RESOURCE_ATTRIBUTES` | `service.version=${APP_VERSION},deployment.environment.name=lab,deployment.color=${DEPLOY_COLOR}` | مقارنة canary/stable |
   | `OTEL_TRACES_EXPORTER` | `otlp` | |
   | `OTEL_EXPORTER_OTLP_PROTOCOL` | `http/protobuf` | من غير gRPC extension |
   | `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://otel-collector:4318` (compose) · `http://localhost:4318` (ECS sidecar) | |
   | `OTEL_PROPAGATORS` | `tracecontext,baggage` (+ `xray` من `open-telemetry/contrib-aws` لربط الـ ALB) | |
   | `OTEL_TRACES_SAMPLER` / `_ARG` | `parentbased_traceidratio` / `0.1` | 10% (100% وقت load test في lab مقبول) |
   | `OTEL_METRICS_EXPORTER` / `OTEL_LOGS_EXPORTER` | `none` | الـ metrics على `/metrics` واللوجز على stderr |
   | `OTEL_PHP_EXCLUDED_URLS` | `up,ready,metrics` | الـ probes متملاش الـ traces |

4. **Caveats:** PHP-FPM share-nothing → الـ spans بتتعمل flush في **آخر كل request** — لازم الـ exporter يكلّم collector **محلي** (sidecar/نفس الـ host) عشان backend بطيء ميزودش latency على المستخدم. وتتبع كل SQL statement تحت load test = data كتير جداً → sample.

### 5.4 فين الـ collector يشتغل (design)

- **Compose / EC2:** `observability/otel/docker-compose.yml` (Jaeger)، أو بدّل الـ config المتركّب بـ `collector-xray.yaml` واعطي الـ instance profile `AWSXrayWriteOnlyAccess`.
- **ECS Fargate:** sidecar في نفس الـ task (`otel/opentelemetry-collector-contrib` أو ADOT `public.ecr.aws/aws-observability/aws-otel-collector`) والـ app → `localhost:4318`؛ الـ task role يحتاج `AWSXrayWriteOnlyAccess`. ده محتاج تعديل في [`modules/ecs-fargate`](../../../infra/terraform/modules/ecs-fargate) (container definition تانية + policy attachment للـ task role) — **مش موجود**. شكل تقريبي للـ container الإضافي:
  ```json
  { "name": "otel-collector", "image": "otel/opentelemetry-collector-contrib:0.165.0", "essential": false,
    "command": ["--config=env:OTEL_CONFIG"],
    "secrets": [{ "name": "OTEL_CONFIG", "valueFrom": "arn:aws:ssm:<REGION>:<ACCOUNT_ID>:parameter/student-app/lab/otel/collector-xray" }],
    "environment": [{ "name": "AWS_REGION", "value": "<REGION>" }] }
  ```
  (الـ config نفسه كـ SSM parameter — Advanced tier لو الحجم > 4KB. وخلي بالك إن الـ execution role الحالي بيقرا `/student-app/lab/app/*` بس.)
- **EKS:** OpenTelemetry Operator (`OpenTelemetryCollector` CR) أو ADOT EKS add-on، و Pod Identity/IRSA للـ X-Ray ([`k8s/`](../../../k8s) بيتكتب).

## 6) الـ Deploy

### 6.1 الـ collector + Jaeger محلياً

```bash
docker compose up -d --wait                                            # الـ app الأول (الـ network)
docker compose -f observability/otel/docker-compose.yml up -d
docker compose -f observability/otel/docker-compose.yml ps
docker compose -f observability/otel/docker-compose.yml logs --tail=20 otel-collector   # "Everything is ready"
```

Jaeger UI: http://localhost:16686 — الـ collector على `127.0.0.1:4317/4318` من الـ host، و `otel-collector:4318` من جوه network التطبيق.

### 6.2 ابعت span بإيدك (OTLP/HTTP JSON) — تثبت الـ pipeline من غير instrumentation

```bash
TRACE_ID="$(printf '%08x' "$(date +%s)")$(openssl rand -hex 12)"      # أول 8 hex = epoch (متوافق مع X-Ray كمان)
ROOT=$(openssl rand -hex 8); CHILD=$(openssl rand -hex 8)
START=$(date +%s%N); MID=$((START + 120000000)); END=$((START + 150000000))

curl -sS -X POST http://localhost:4318/v1/traces -H 'Content-Type: application/json' -d @- <<EOF
{"resourceSpans":[{"resource":{"attributes":[
   {"key":"service.name","value":{"stringValue":"student-app-synthetic"}},
   {"key":"service.version","value":{"stringValue":"manual"}},
   {"key":"deployment.environment.name","value":{"stringValue":"lab"}}]},
 "scopeSpans":[{"scope":{"name":"manual-curl"},"spans":[
   {"traceId":"$TRACE_ID","spanId":"$ROOT","name":"GET students.index","kind":2,
    "startTimeUnixNano":"$START","endTimeUnixNano":"$END",
    "attributes":[{"key":"http.route","value":{"stringValue":"students.index"}},
                  {"key":"http.response.status_code","value":{"intValue":"200"}}]},
   {"traceId":"$TRACE_ID","spanId":"$CHILD","parentSpanId":"$ROOT","name":"SELECT students","kind":3,
    "startTimeUnixNano":"$((START + 10000000))","endTimeUnixNano":"$MID",
    "attributes":[{"key":"db.system.name","value":{"stringValue":"mysql"}}]}]}]}]}
EOF
echo "trace: $TRACE_ID"
docker compose -f observability/otel/docker-compose.yml logs --tail=5 otel-collector   # debug exporter: "spans": 2
```

في Jaeger: Service `student-app-synthetic` → **Find Traces** → هتلاقي span أب (`kind 2` = SERVER، 150ms) وجواه child (`kind 3` = CLIENT، 110ms) — ده بالظبط الشكل اللي `auto-pdo` هيطلّعه: "الـ request خد 150ms، منهم 110 في SQL".

### 6.3 نفس الحاجة لـ X-Ray (اختياري — سنتات)

```bash
# بدّل الـ config وادّي الـ collector credentials (profile من جهازك — للتجربة بس)
docker run --rm -d --name otel-xray -p 127.0.0.1:4318:4318 \
  -e AWS_REGION=us-east-1 -e AWS_PROFILE=lab -v ~/.aws:/root/.aws:ro \
  -v "$PWD/observability/otel/collector-xray.yaml:/etc/otelcol/config.yaml:ro" \
  otel/opentelemetry-collector-contrib:0.165.0 --config=/etc/otelcol/config.yaml
```

(وقّف collector الـ Jaeger الأول عشان البورت 4318.) ابعت نفس الـ curl، وبعد دقيقة: **CloudWatch → X-Ray traces → Traces**. الـ image ممكن ميبقاش بيجري كـ root فـ `/root/.aws` مش هيتقري — لو حصل، مرّر `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_SESSION_TOKEN` مؤقتة من `aws configure export-credentials --profile lab --format env`. على AWS الحقيقي الـ credentials من الـ role (instance profile / task role)، عمرها ما بتبقى keys.

```bash
docker rm -f otel-xray
```

### 6.4 على GitHub Actions

`observability-lint.yml` (job **Loki · Alloy · OTel · compose · dashboards**):

```bash
docker run --rm -e AWS_REGION=us-east-1 -v "$PWD/observability/otel:/cfg:ro" \
  otel/opentelemetry-collector-contrib:0.165.0 validate --config=/cfg/collector-xray.yaml
```

و `docker compose -f observability/otel/docker-compose.yml config -q`. يعني أي typo في الـ config بيقع في الـ CI قبل ما يوصل sidecar.

## 7) التحقق (Verify)

```bash
curl -s http://localhost:13133/ 2>/dev/null || docker compose -f observability/otel/docker-compose.yml exec otel-collector true   # health_check على 13133 (مش published)
curl -s "http://localhost:16686/api/services" | jq                    # فيها student-app-synthetic
curl -s "http://localhost:16686/api/traces/$TRACE_ID" | jq '.data[0].spans | length'   # 2
aws xray get-trace-summaries --start-time $(date -d '-10 min' +%s) --end-time $(date +%s) --query 'TraceSummaries[].Id'
```

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر | المتوقع |
|---|---|---|
| Jaeger واقع | `docker compose -f observability/otel/docker-compose.yml stop jaeger` + ابعت spans | الـ collector بيعمل retry وبيلوج export errors؛ الـ `curl` نفسه بينجح (الـ collector استلم) — ده الـ decoupling |
| بروتوكول غلط | ابعت الـ JSON على `:4317` | فشل — 4317 gRPC، 4318 HTTP. نفس المصيدة لو `OTEL_EXPORTER_OTLP_PROTOCOL=grpc` من غير extension |
| X-Ray من غير صلاحية | شغّل `collector-xray` من غير credentials | `AccessDeniedException`/no credentials في لوج الـ collector |
| Sampling صفر | (design) `OTEL_TRACES_SAMPLER_ARG=0` | مفيش traces خالص — ومع `parentbased` لو الـ ALB/الـ caller بعت `traceparent` بـ flag `01` هيتعمله sample برضه |
| Probes في الـ traces | (design) من غير `OTEL_PHP_EXCLUDED_URLS` | آلاف traces لـ `/ready` كل دقيقة من الـ ALB — مالية الـ UI والفاتورة |

## 9) الرجوع (Rollback)

- الـ collector stack مستقل: `down` ومفيش أثر على التطبيق.
- (design) لو الـ instrumentation زوّد الـ latency: `OTEL_PHP_AUTOLOAD_ENABLED=false` (env بس، من غير image جديد) → redeploy.

## 10) المسح (Teardown) ⚠️

```bash
docker compose -f observability/otel/docker-compose.yml down
docker rm -f otel-xray 2>/dev/null || true
```

لو فعّلت Transaction Search: رجّعه من **CloudWatch → Settings** وامسح/قصّر retention الـ log group `aws/spans`.

## 11) التكلفة (Cost)

| Resource | السعر التقريبي (us-east-1 — تقريبي، راجع صفحة الأسعار) |
|---|---|
| X-Ray traces recorded | ~$5 لكل مليون trace (أول ~100k/شهر مجاناً) |
| X-Ray traces retrieved/scanned | ~$0.50 لكل مليون |
| Transaction Search | spans بتتحاسب كـ CloudWatch Logs ingestion + indexing |
| Collector sidecar على Fargate | جزء من الـ task CPU/memory (مثلاً 0.25 vCPU / 512MB لو عملته task أكبر) |
| Jaeger محلي | مجاني (in-memory — بيضيع مع الـ restart) |

حسبة: 20 req/s × 10% sampling = 2 trace/s ≈ 5.2 مليون/شهر ≈ $26. الـ sampling هو أهم knob في الفاتورة.

## 12) أسئلة Interview

<details><summary>Head sampling مقابل tail sampling؟</summary>

Head: القرار في أول request (مثلاً 10% random بالـ trace id) وبيتنقل مع الـ context (`parentbased`) — رخيص وبسيط، بس هيفوّت 90% من الـ errors النادرة. Tail: الـ collector يستنى الـ trace يخلص ويقرر (احتفظ بكل الـ errors وكل اللي > 1s و 1% من الباقي) — أذكى بس محتاج كل spans الـ trace توصل لنفس الـ collector instance (load balancing بالـ trace id) و memory. الشائع: head خفيف في التطبيق + tail في gateway collectors.

</details>

<details><summary>ليه Collector بدل ما التطبيق يبعت لـ X-Ray مباشرة؟</summary>

Decoupling: التطبيق بيتكلم OTLP بس؛ تغيير الـ backend (Jaeger → X-Ray → vendor) أو إضافة تاني = تغيير config الـ collector. والـ collector بيعمل batching، retries، memory limiting، sampling، و scrubbing للـ PII في مكان واحد. وفي PHP بالذات: export لـ localhost سريع، فالـ request مش بيستنى network لـ AWS.

</details>

<details><summary>إزاي الـ context بيتنقل، وإيه اللي بيكسره؟</summary>

W3C `traceparent` (و `tracestate`/`baggage`) في الـ HTTP headers؛ الـ SDK بيقراه في الـ server span ويحقنه في الـ client calls. بيتكسر لما: proxy بيشيل headers، queue/async job مش بيمرر الـ context في الـ message، propagators مختلفة بين services (W3C هنا و X-Ray هناك — عشان كده `OTEL_PROPAGATORS=tracecontext,baggage,xray`)، أو thread pool بيضيّع الـ context.

</details>

<details><summary>الـ tracing بيزود latency قد إيه، وتقيسه إزاي؟</summary>

الـ auto-instrumentation فيها overhead (hooks + إنشاء spans + serialization)، وفي PHP-FPM الـ export في آخر الـ request. تقيسه: k6 `load.js` بنفس الـ VUs قبل/بعد (`OTEL_PHP_AUTOLOAD_ENABLED=false` vs `true`) وتقارن p95 في RED dashboard. بتقلله بـ sampling، `batch`، collector محلي، وتعطيل instrumentations مش محتاجها (`auto-pdo` تحت load).

</details>

<details><summary>X-Ray SDK ولا OpenTelemetry دلوقتي؟</summary>

OpenTelemetry. الـ X-Ray SDKs والـ daemon في maintenance من فبراير 2026 والـ end of support فبراير 2027؛ AWS بنفسها بتوجّه لـ OTel (SDK أو ADOT) والـ X-Ray بيستقبل OTLP/W3C. ميزة OTel كمان: vendor-neutral — نفس الـ instrumentation يروح Jaeger محلياً و X-Ray على AWS.

</details>

<details><summary>إزاي تربط الـ trace باللوج والـ metric؟</summary>

اللوج: حط `trace_id`/`span_id` في كل سطر (log context) → من الـ trace للوجز والعكس. الـ metric: **exemplars** — الـ histogram بيخزّن trace id لعيّنة في كل bucket، فـ Grafana يوريك "النقطة دي في p99 = الـ trace ده". الاتنين مش متطبقين في الـ repo؛ ده الـ "observability" الكاملة بدل 3 أدوات منفصلة.

</details>

## 13) Checklist

- [ ] أقدر أشرح trace/span/`traceparent`/head vs tail sampling
- [ ] شغّلت الـ collector + Jaeger وبعت span بالـ curl وشفته في Jaeger
- [ ] قريت `collector-xray.yaml` وأعرف ليه `memory_limiter` الأول
- [ ] (اختياري) بعت نفس الـ span لـ X-Ray وشفته في CloudWatch → X-Ray traces
- [ ] أعرف بالظبط إيه اللي ناقص عشان التطبيق يبقى instrumented (extension، packages، env)
- [ ] عملت teardown
