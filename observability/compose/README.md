# Lab observability stack (Docker Compose) — scenarios 12 & 71

Metrics, SLO alerting, dashboards and logs for the app running in Docker on your
machine, a CI runner or the EC2 host. Everything is pinned and provisioned from git.

| Component | Image | Role |
|---|---|---|
| Prometheus | `prom/prometheus:v3.16.0` | scrapes the app slots, evaluates the SLO recording + burn-rate rules, receives k6 results (remote-write / OTLP) |
| Alertmanager | `prom/alertmanager:v0.35.0` | routes `severity=page` / `ticket`, inhibits slower burns, keeps drills off the pager |
| alert-sink | `mendhak/http-https-echo:43` | fake pager: prints every notification it receives |
| Grafana | `grafana/grafana:13.3.1` | provisioned datasources + the 3 dashboards in [`../grafana/dashboards`](../grafana/dashboards) |
| Loki | `grafana/loki:3.7.10` | log store (7 days) |
| Grafana Alloy | `grafana/alloy:v1.22.0` | ships every container's stdout/stderr to Loki (Promtail is deprecated); parses Laravel JSON logs |
| node-exporter | `prom/node-exporter:v1.13.1` | host CPU / memory / disk / network |
| cAdvisor | `ghcr.io/google/cadvisor:0.61.1` | per-container CPU / memory / network (registry moved from gcr.io at v0.53) |

Config lives next door: [`../prometheus/prometheus.yml`](../prometheus/prometheus.yml),
[`../prometheus/rules/`](../prometheus/rules) (+ promtool unit tests), [`../prometheus/alertmanager.yml`](../prometheus/alertmanager.yml),
[`loki/config.yaml`](loki/config.yaml), [`alloy/config.alloy`](alloy/config.alloy), [`grafana/provisioning/`](grafana/provisioning).

## Run order

The app stack must be up first: it owns the Docker network `student-app_default`
that Prometheus joins to reach `app:8080`, `app_blue:8080`, `app_green:8080`.

```bash
# 1. the app (any of the three; all use compose project "student-app")
export APP_KEY=base64:$(openssl rand -base64 32)
docker compose up -d --wait                         # single container: app
# or: bash deploy/ec2/lb/bin/init.sh <image>        # blue/green slots: app_blue + app_green

# 2. this stack
docker compose -f observability/compose/docker-compose.yml up -d
docker compose -f observability/compose/docker-compose.yml ps

# 3. generate traffic and look at it
k6 run -e BASE_URL=http://localhost:8080 -e LOADTEST_USERS=5 -e VUS=5 -e DURATION=5m loadtest/k6/load.js
```

Error `network student-app_default declared as external, but could not be found` → step 1 was skipped.

## URLs (bound to 127.0.0.1)

| UI | URL | Notes |
|---|---|---|
| Grafana | http://localhost:3000 | `admin` / `admin` (set `LAB_GRAFANA_PASSWORD`); home = SLO dashboard |
| Prometheus | http://localhost:9090 | Status → Targets (absent slots are DOWN, that is fine), Alerts, Rules |
| Alertmanager | http://localhost:9093 | silences, inhibitions, routing tree |
| Alloy | http://localhost:12345 | live pipeline graph |
| Loki | http://localhost:3100/ready | query through Grafana → Explore |
| cAdvisor | http://localhost:8089 | raw container stats |

On EC2 nothing is public: forward a port over SSM instead of opening the security group:

```bash
aws ssm start-session --target <INSTANCE_ID> \
  --document-name AWS-StartPortForwardingSession --parameters '{"portNumber":["3000"],"localPortNumber":["3000"]}'
```

## Things to try

```bash
# Which release answers? (needs /metrics on the app: METRICS_ENABLED=true)
curl -s localhost:9090/api/v1/query --data-urlencode 'query=student_app_app_info' | jq '.data.result[].metric'

# Burn the drill budget and watch SLODrillFastBurn go pending → firing → alert-sink
k6 run -e BASE_URL=http://localhost:8080 -e BURN_RATE=20 -e DURATION=20m loadtest/k6/error-budget-burn.js
docker compose -f observability/compose/docker-compose.yml logs -f alert-sink

# Stream k6 metrics into the same Prometheus
K6_PROMETHEUS_RW_SERVER_URL=http://localhost:9090/api/v1/write k6 run -o experimental-prometheus-rw loadtest/k6/load.js

# Logs: Grafana → Explore → Loki
#   {service="app"} | json | level_name="ERROR"
#   sum by (level) (count_over_time({compose_project="student-app"} [5m]))

# Validate config like CI does (.github/workflows/observability-lint.yml)
docker run --rm -v "$PWD/observability/prometheus:/p" -w /p --entrypoint promtool prom/prometheus:v3.16.0 check config prometheus.yml
docker run --rm -v "$PWD/observability/prometheus:/p" -w /p --entrypoint promtool prom/prometheus:v3.16.0 test rules rules/tests/slo-burn-rate.test.yml
docker run --rm -v "$PWD/observability/prometheus:/p" --entrypoint amtool prom/alertmanager:v0.35.0 check-config /p/alertmanager.yml
```

## Notes

- **Docker Desktop (Windows/macOS):** node-exporter and cAdvisor see the Docker VM, not your laptop, and cAdvisor may need `/dev/kmsg` removed. They are meant for the Linux EC2 host.
- **Security:** Alloy and cAdvisor read the Docker socket / host filesystem — fine for a lab host, review before anything shared. Never expose these ports publicly.
- **Retention:** Prometheus 31 days or 5 GB (the SLO window is 30 days); Loki 7 days.
- **Reload after editing rules:** `curl -X POST localhost:9090/-/reload` (or restart the container).
- **Teardown:** `docker compose -f observability/compose/docker-compose.yml down -v` removes the data volumes too.
