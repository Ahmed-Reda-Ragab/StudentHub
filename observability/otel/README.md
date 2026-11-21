# Distributed tracing with OpenTelemetry (scenario 72) — design notes

Metrics tell you *that* p95 went up; a trace tells you *where the time went*
(which query, which middleware, which outbound call). This folder holds the
collector side, ready to run. **The app is not instrumented in this repo** — below is
exactly what it would take, so the change can be reviewed before it is made.

| File | Purpose |
|---|---|
| [`collector-xray.yaml`](collector-xray.yaml) | OTLP in → `memory_limiter` → `resourcedetection` (env/ecs/ec2) → `batch` → **AWS X-Ray** + `debug` |
| [`collector-jaeger.yaml`](collector-jaeger.yaml) | OTLP in → **Jaeger** (local, no AWS) + `debug` |
| [`docker-compose.yml`](docker-compose.yml) | `otel/opentelemetry-collector-contrib:0.165.0` + `jaegertracing/jaeger:2.23.0` (v2 all-in-one) on the app network |

```
Laravel (PHP-FPM, ext-opentelemetry + auto-laravel) ──OTLP/HTTP──► collector ──► X-Ray   (AWS)
                                                                         └────► Jaeger  (local)
```

## What app-side instrumentation requires

1. **PHP extension** `opentelemetry` (PECL) — it provides the hooks that let auto-instrumentation
   wrap framework code without code changes. In `docker/Dockerfile` (runtime stage, the
   serversideup images ship `install-php-extensions`):
   ```dockerfile
   USER root
   RUN install-php-extensions opentelemetry protobuf   # protobuf: faster OTLP encoding (optional)
   USER www-data
   ```
2. **Composer packages**
   ```bash
   composer require open-telemetry/sdk open-telemetry/exporter-otlp \
     open-telemetry/opentelemetry-auto-laravel open-telemetry/opentelemetry-auto-pdo
   ```
   The OTLP/HTTP exporter needs a PSR-18 client + PSR-17 factories; Laravel already ships
   Guzzle 7 (`php-http/discovery` finds it). `auto-laravel` traces the HTTP kernel, routes,
   cache, queue and Eloquent; `auto-pdo` adds one span per SQL statement.
3. **Runtime env** (container env / ECS task definition / Helm values — no code):

   | Var | Lab value | Why |
   |---|---|---|
   | `OTEL_PHP_AUTOLOAD_ENABLED` | `true` | turn on SDK autoload + auto-instrumentation |
   | `OTEL_SERVICE_NAME` | `student-app` | service name in X-Ray / Jaeger |
   | `OTEL_RESOURCE_ATTRIBUTES` | `service.version=${APP_VERSION},deployment.environment.name=lab,deployment.color=${DEPLOY_COLOR}` | compare canary vs stable traces |
   | `OTEL_TRACES_EXPORTER` | `otlp` | |
   | `OTEL_EXPORTER_OTLP_PROTOCOL` | `http/protobuf` | no gRPC extension needed |
   | `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://otel-collector:4318` (compose) · `http://localhost:4318` (ECS sidecar) | |
   | `OTEL_PROPAGATORS` | `tracecontext,baggage` | W3C context in/out |
   | `OTEL_TRACES_SAMPLER` / `_ARG` | `parentbased_traceidratio` / `0.1` | keep 10% (100% while load testing a lab is fine) |
   | `OTEL_METRICS_EXPORTER` / `OTEL_LOGS_EXPORTER` | `none` | metrics stay on `/metrics`, logs on stderr |

   Keep `/up`, `/ready`, `/metrics` out of traces (sampling rule in the collector or
   `OTEL_PHP_EXCLUDED_URLS=up,ready,metrics`) — probes would dominate the trace list.

## Where the collector runs

- **Compose / EC2:** `docker compose -f observability/otel/docker-compose.yml up -d` (Jaeger), or swap
  the mounted config for `collector-xray.yaml` and give the instance profile `AWSXrayWriteOnlyAccess`.
- **ECS Fargate:** a sidecar container in the same task (`otel/opentelemetry-collector-contrib` or AWS's ADOT
  image) with `collector-xray.yaml` from SSM/S3; app → `localhost:4318`; task role `AWSXrayWriteOnlyAccess`.
- **EKS:** the OpenTelemetry Operator (`OpenTelemetryCollector` CR) or the ADOT EKS add-on; IRSA / Pod Identity for X-Ray.

## Caveats worth knowing

- PHP-FPM is share-nothing: spans are flushed at the end of each request. Export to a
  **local** collector (sidecar / same host) so a slow backend never adds latency to users.
- X-Ray accepts W3C trace ids; the ALB adds its own `X-Amzn-Trace-Id` header. To join ALB and app
  traces, add the X-Ray propagator from `open-telemetry/contrib-aws` (`OTEL_PROPAGATORS=tracecontext,baggage,xray`).
- Tracing every SQL statement under a load test produces a lot of data: sample.
