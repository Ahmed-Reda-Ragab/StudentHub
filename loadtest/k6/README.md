# k6 load tests — measuring the SLOs for real

Scenarios 70–77 (SLOs, load testing, perf gate, autoscaling, canary, incident drills).
Every script logs in like a real user (CSRF token + session cookie), browses a
realistic read-heavy mix and gates on the **same SLO numbers** as Prometheus and
CloudWatch ([CONVENTIONS §5 and §10](../../docs/devops/CONVENTIONS.md)).

| Script | SRE question it answers | Executor / shape | Defaults |
|---|---|---|---|
| `smoke.js` | Does this deploy work at all? (health, login, read, one write) | 2 VUs, constant | `DURATION=30s` |
| `load.js` | Do we meet the SLO at expected traffic? | ramping VUs 20% / 60% / 20% | `VUS=10 DURATION=5m` |
| `stress.js` | What breaks first above normal load? Graceful degradation? | steps 1×,2×,3×,4× `VUS` | `VUS=20 DURATION=2m` per step, `STEPS=1,2,3,4` |
| `spike.js` | Survive a 10× jump in seconds? How fast do we recover? | baseline → spike → recovery | `VUS=5 SPIKE_VUS=50 DURATION=1m` |
| `soak.js` | Still healthy after hours? (leaks, table growth, disk) | constant VUs | `VUS=20 DURATION=2h` |
| `breakpoint.js` | What is our capacity (req/s) inside the SLO? | ramping-arrival-rate + `abortOnFail` | `START_RATE=5 MAX_RATE=200 DURATION=20m TARGET=journey` |
| `user-journey.js` | How long does a real task take, step by step? Idempotent writes? | constant VUs, k6 groups | `VUS=5 DURATION=5m` |
| `autoscale-cpu.js` | Does CPU autoscaling (ASG / ECS / HPA) add capacity in time? | constant-arrival-rate on `/sre-lab/cpu` | `RATE=10 CPU_MS=200 DURATION=10m` |
| `canary-watch.js` | Which release answers, in what share? Zero failed requests during the shift? | constant-arrival-rate on `/ready` | `RATE=10 DURATION=5m` |
| `error-budget-burn.js` | Do burn-rate alerts fire, and how long does detection take? | constant-arrival-rate on `/sre-lab/error` | `BURN_RATE=20 RATE=10 DURATION=15m MODE=lab` |

Shared code lives in [`lib/`](lib): `config.js` (env + SLO thresholds), `auth.js`
(login once per VU), `journey.js` (weighted page mix, student creation),
`helpers.js` (UUID v4, random picks, lab headers), `metrics.js` (custom metrics).
No remote imports — the scripts run offline and inside the stock `grafana/k6` image.

## Before you run

1. App running with `SRE_LAB_ENABLED=true` (only needed for `/sre-lab/*` scripts and the smoke ping).
2. Load-test users seeded (`loadtest1@example.com … loadtestN@example.com` / `password`):
   ```bash
   docker compose exec -T app sh -c 'LOADTEST_USERS=20 LOADTEST_STUDENTS_PER_USER=100 php artisan db:seed --class=LoadTestSeeder --force'
   ```
   Pass the same number as `-e LOADTEST_USERS=20` (VUs above that share accounts).
3. If the app has `SRE_LAB_TOKEN` set, pass `-e LAB_TOKEN=<value>` (sent as `X-Lab-Token`).

## Install / run k6

```bash
# native (k6 v2.x; v1.x works too)
winget install k6 --source winget        # Windows
brew install k6                          # macOS
sudo apt-get install k6                  # Debian/Ubuntu after adding the k6 apt repo (grafana.com/docs/k6/latest/set-up/install-k6/)

k6 run -e BASE_URL=http://localhost:8080 -e LOADTEST_USERS=5 loadtest/k6/smoke.js
k6 run -e BASE_URL=http://localhost:8080 -e LOADTEST_USERS=5 -e VUS=5 -e DURATION=45s loadtest/k6/load.js
```

Without installing anything — the official image, on the app's Docker network
(so `app:8080` resolves; use `http://host.docker.internal:8080` on Docker Desktop instead):

```bash
mkdir -p loadtest/results
docker run --rm -i --network student-app_default \
  -u "$(id -u):$(id -g)" -v "$PWD/loadtest:/loadtest" \
  grafana/k6:2.4.0 run -e BASE_URL=http://app:8080 -e LOADTEST_USERS=5 \
  --summary-export /loadtest/results/smoke-summary.json /loadtest/k6/smoke.js
```

PowerShell: replace `$PWD/loadtest` with `${PWD}/loadtest` and drop `-u ...`.

## Environment variables

| Var | Default | Used by | Meaning |
|---|---|---|---|
| `BASE_URL` | `http://localhost:8080` | all | Target (ALB DNS, nginx LB, ingress, `http://app:8080`) |
| `LOADTEST_USERS` | `20` | journeys | How many `loadtest{N}` users were seeded |
| `PASSWORD` | `password` | journeys | Their password |
| `LAB_TOKEN` | empty | `/sre-lab/*` | Sent as `X-Lab-Token` when set |
| `VUS` | per script | VU-based | Virtual users (baseline for stress/spike) |
| `DURATION` | per script | all | `45s`, `5m`, `1h30m` (per step in `stress.js`) |
| `P95_MS` | `500` | gates | p95 threshold on successful responses. **Real SLO = 300** (CI default is looser: weak runner) |
| `P99_MS` | `1000` | gates | Latency-tail SLO |
| `THINK_TIME` | `1` | VU-based | Seconds between page views (±50% jitter) |
| `WRITE_PCT` | `5` | journeys | % of page views that create a student (user-journey: 4× per journey) |
| `LAB_ENDPOINTS` | `true` | smoke | `false` when the target has the lab disabled |
| `TEST_ID` | empty | all | Adds a `testid` tag to every sample (filter runs in Grafana) |
| `INSECURE_TLS` | `false` | all | Skip TLS verification (self-signed lab certs) |
| `SPIKE_VUS` | `VUS×10` | spike | Spike height |
| `STEPS` | `1,2,3,4` | stress | Multipliers of `VUS` |
| `START_RATE` / `MAX_RATE` | `5` / `200` | breakpoint | Iterations per second, linear ramp |
| `TARGET` | `journey` | breakpoint | `journey`, `ping`, `db`, `db-heavy`, `cpu` |
| `PRE_VUS` / `MAX_VUS` / `MAX_DROPPED` | `50` / `1000` / `100` | breakpoint | VU pool; abort after N dropped iterations |
| `RATE` | `10` | arrival-rate scripts | Requests per second |
| `CPU_MS` | `200` (`50` breakpoint) | autoscale-cpu, breakpoint cpu | CPU burned per request |
| `WATCH_PATH` | `/ready` | canary-watch | Or `/sre-lab/version` (adds hostname, needs lab) |
| `EXPECT_VERSIONS` | empty | canary-watch | `v1,v2` → per-version rows in the summary |
| `CANARY_COLOR` / `CANARY_VERSION` | empty | canary-watch | Which responses count as "canary" |
| `EXPECT_CANARY_PCT` / `TOLERANCE_PCT` | off / `5` | canary-watch | Fail if the canary share is outside pct ± tolerance |
| `MAX_ERROR_RATE` | `0.005` | canary-watch | Allowed error rate while traffic moves |
| `BURN_RATE` / `MODE` / `WARMUP` / `CODE` | `20` / `lab` / `0s` / `500` | error-budget-burn | See the math in the script header |

## Thresholds are the SLOs

`lib/config.js → sloThresholds()`:

| Threshold | SLO | Why |
|---|---|---|
| `http_req_failed: rate<0.005` | availability 99.5% | 0.5% = the 30-day error budget; 4xx/5xx/network errors (419 included) |
| `http_req_duration{expected_response:true}: p(95)<P95_MS` | 95% < 300ms | only successful responses — a fast 500 must not improve latency |
| `…: p(99)<P99_MS` | p99 < 1s | the tail users complain about (not gated in smoke: 2 VUs) |
| `checks: rate>0.99` | correctness | a 200 that is the login page is a failure |
| `csrf_failures`, `login_failures`, `session_relogins: count==0` | correctness | Laravel-specific failure modes that look like 200 OK |

k6 exits **99** when a threshold is crossed (that fails CI), non-zero on script
errors, 0 on success. Per-page p95 is printed (`http_req_duration{name:students.show}`)
without gating — `name` tags are the Laravel route names, so they line up with
`student_app_http_requests_total{route="students.show"}` in Prometheus.

## How the login works (and the Laravel traps)

`GET /login` → regex `_token` from the `@csrf` hidden input → `POST /login`
(form-encoded, `_token` + `_submission_token`) → follow 302 to `/students` →
verify the page has the logout form. `session()->regenerate()` rotates the CSRF
token on login, so the token is re-read from every authenticated page. Each VU
keeps its cookie jar for its whole life (`noCookiesReset: true`): **one login per
VU**, not per iteration. Student creation sends a fresh UUID v4 `_submission_token`
(`PreventDuplicateSubmissions`); `user-journey.js` replays it and asserts no duplicate.

| Symptom | Meaning |
|---|---|
| `csrf_failures > 0` / 419 | stale `_token`, cookie not kept, sessions not shared between replicas (`SESSION_DRIVER=file` behind a LB!) |
| `login_failures > 0` | users not seeded / wrong `LOADTEST_USERS` / throttled after 5 bad attempts per email+IP |
| `session_relogins > 0` | session lost mid-test: session store, GC, different `APP_KEY` per replica |
| 403 on `/sre-lab/*` | app has `SRE_LAB_TOKEN`: pass `-e LAB_TOKEN=...`; 404 = lab disabled |

## Outputs

```bash
mkdir -p loadtest/results          # gitignored

# 1) end-of-test summary as JSON (what perf-gate.yml uploads)
k6 run --summary-export loadtest/results/summary.json loadtest/k6/load.js

# 2) live web dashboard + self-contained HTML report (built into k6)
K6_WEB_DASHBOARD=true K6_WEB_DASHBOARD_EXPORT=loadtest/results/report.html \
  k6 run loadtest/k6/load.js          # open http://localhost:5665 while it runs
# CI: add K6_WEB_DASHBOARD_PORT=-1 (no HTTP server, still writes the report)
# Docker: add -p 5665:5665 -e K6_WEB_DASHBOARD_HOST=0.0.0.0

# 3) stream to the lab Prometheus (observability/compose) → Grafana next to the app's own metrics
K6_PROMETHEUS_RW_SERVER_URL=http://localhost:9090/api/v1/write \
K6_PROMETHEUS_RW_TREND_STATS="p(95),p(99),min,max" \
  k6 run -o experimental-prometheus-rw -e TEST_ID=load-$(date +%s) loadtest/k6/load.js
```

`experimental-prometheus-rw` still works in k6 v2.4 but is **deprecated** (removal
planned for k6 v3). The forward-compatible path is OpenTelemetry into Prometheus'
native OTLP receiver (enabled in the lab Prometheus with `--web.enable-otlp-receiver`;
metric names then follow OTLP→Prometheus translation, e.g. a `_total` suffix on counters):

```bash
K6_OTEL_EXPORTER_PROTOCOL=http/protobuf K6_OTEL_HTTP_EXPORTER_ENDPOINT=localhost:9090 \
K6_OTEL_HTTP_EXPORTER_URL_PATH=/api/v1/otlp/v1/metrics K6_OTEL_HTTP_EXPORTER_INSECURE=true \
K6_OTEL_METRIC_PREFIX=k6_ k6 run -o opentelemetry loadtest/k6/load.js
```

## Where these run in CI

- [`.github/workflows/lab-integration.yml`](../../.github/workflows/lab-integration.yml) — `smoke.js` and `load.js` against the compose stack on every push.
- [`.github/workflows/perf-gate.yml`](../../.github/workflows/perf-gate.yml) — any script against a deployed environment (manual or `workflow_call` from a deploy), HTML report + summary as artifacts.
- [`.github/workflows/observability-lint.yml`](../../.github/workflows/observability-lint.yml) — `k6 inspect` on every script (syntax + options).

## Good habits

- Never load-test an environment that real users share; tag runs with `TEST_ID`.
- Read results next to the server side: Grafana RED / SLO dashboards (`observability/`), not only the k6 summary.
- Before a test on AWS, check ALB / RDS / account limits and stop the test with `Ctrl+C` (k6 still writes the summary).
- Students created by k6 are easy to find and clean up: code `k6-<vu>-…`, name `k6 Student …`, note `created by k6`.
