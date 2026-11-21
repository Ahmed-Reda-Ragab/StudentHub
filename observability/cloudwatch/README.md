# CloudWatch — the same SLOs on AWS-native telemetry

For the AWS scenarios (ALB + ECS / ASG + RDS) where there is no Prometheus. The
numbers match k6 and Prometheus (CONVENTIONS §5): availability 99.5%, latency 95% < 300ms, p99 < 1s.

| File | What |
|---|---|
| [`dashboard.json`](dashboard.json) | Dashboard body: ALB requests / 5xx / availability % / burn rate, p50-p95-p99 + latency SLI (percentile rank `PR(:0.3)`), healthy hosts per target group, ECS and ASG CPU, ALB connections, RDS CPU / connections / latency / memory / storage |
| [`logs-insights-queries.md`](logs-insights-queries.md) | Logs Insights queries for the Laravel JSON logs, plus Athena SQL for ALB access logs (those live in S3) |

The Terraform `observability` module (CONVENTIONS §6) creates the alarms and an
equivalent dashboard; this file is for the console path and for learning what each widget means.

## Import

The JSON has `${…}` tokens instead of hard-coded ids. Fill them from Terraform outputs
(`alb_arn_suffix`, `target_group_arn_suffixes`, ECS / ASG names, RDS identifier) and push:

```bash
export AWS_REGION=us-east-1
export ALB_ARN_SUFFIX=app/student-app-lab-alb/0123456789abcdef            # LoadBalancer dimension
export TG_BLUE_ARN_SUFFIX=targetgroup/student-app-lab-blue/0123456789abcdef
export TG_GREEN_ARN_SUFFIX=targetgroup/student-app-lab-green/0123456789abcdef
export ECS_CLUSTER=student-app-lab ECS_SERVICE=student-app-lab-app
export ASG_NAME=student-app-lab-blue   # stack 40 ASGs: student-app-lab-blue / student-app-lab-green
export RDS_INSTANCE_ID=student-app-lab-mysql

envsubst < observability/cloudwatch/dashboard.json > /tmp/student-app-dashboard.json
aws cloudwatch put-dashboard --dashboard-name student-app-lab-slo \
  --dashboard-body file:///tmp/student-app-dashboard.json
```

Console alternative: CloudWatch → Dashboards → Create → Actions → **View/edit source**,
paste the JSON after replacing the tokens. Widgets for parts you have not deployed (ECS
when you run on an ASG, or the reverse) just stay empty.

## How the SLO widgets work

- **Availability %** = `100 × (1 − (Target 5xx + ELB 5xx) / RequestCount)` per 5 minutes.
  ELB 5xx (502/503/504) count because users saw them even though the app never did. CloudWatch
  cannot exclude `/sre-lab/*` or `/ready` here (ALB metrics have no path dimension) — health
  checks are not counted in `RequestCount`, but lab traffic is: use Athena or Prometheus for the exact SLI.
- **Burn rate** = error ratio / 0.005. Horizontal lines at 14.4 and 6 (page) and 1 (ticket).
  CloudWatch alarms can implement the multi-window rule with a metric-math alarm per window
  and a **composite alarm** (`ALARM(burn_1h) AND ALARM(burn_5m)`).
- **Latency SLI** uses the percentile-rank statistic `PR(:0.3)`: the percentage of requests
  with `TargetResponseTime ≤ 0.3s`. The SLO line is 95.
- `HTTPCode_*` metrics are only emitted when non-zero, hence `FILL(m, 0)` in the math.
- `ECS/ContainerInsights RunningTaskCount` needs Container Insights on the cluster;
  `AWS/AutoScaling Group*` metrics need group metrics collection enabled on the ASG.

## Cost

Dashboards: first 3 per account are free, then ~$3/month each. Logs Insights: $0.005 per
GB scanned — always narrow the time range. Athena: $5 per TB scanned — always filter on `day`.
Delete with `aws cloudwatch delete-dashboards --dashboard-names student-app-lab-slo`.
