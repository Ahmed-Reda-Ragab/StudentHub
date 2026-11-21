# AWS FIS — chaos experiments and the game-day checklist

Experiment templates for AWS Fault Injection Service. Each one states its hypothesis
in `description`, targets resources by the lab's names/tags, and has a **stop
condition**: a CloudWatch alarm that aborts the experiment if users start to suffer.

| Template | Fault | Question |
|---|---|---|
| [`ecs-stop-half-tasks.json`](ecs-stop-half-tasks.json) | `aws:ecs:stop-task` on `PERCENT(50)` of the service's tasks | Does the ALB drain them and ECS replace them before the SLO notices? Is `desiredCount` ≥ 2 and spread across AZs? |
| [`asg-terminate-one-instance.json`](asg-terminate-one-instance.json) | `aws:ec2:terminate-instances`, `COUNT(1)` instance tagged `aws:autoscaling:groupName` | Health check → replacement → back in service: how long, and how many 502s? |
| [`ec2-cpu-stress.json`](ec2-cpu-stress.json) | `aws:ssm:send-command` + `AWSFIS-Run-CPU-Stress` (80%, 5 min) on half the instances | Does CPU target tracking scale out? (compare with `loadtest/k6/autoscale-cpu.js`, which loads through the app) |
| [`ec2-network-latency.json`](ec2-network-latency.json) | `aws:ssm:send-command` + `AWSFIS-Run-Network-Latency` (+200ms, 5 min) on one instance | Does the latency burn-rate alert fire? Do timeouts/retries amplify it? |

For ECS on Fargate, CPU/network faults inside tasks use the ECS actions
(`aws:ecs:task-cpu-stress`, `aws:ecs:task-network-latency`) and need the SSM agent
sidecar — out of scope here. For EKS see `aws:eks:pod-*` actions or Chaos Mesh.

## Placeholders to replace

- `<ACCOUNT_ID>`, `<REGION>`
- `roleArn` → an IAM role trusted by `fis.amazonaws.com` with only what the action needs
  (`ecs:StopTask`, `ecs:ListTasks`, `ecs:DescribeTasks` · `ec2:TerminateInstances`, `ec2:DescribeInstances` ·
  `ssm:SendCommand`, `ssm:ListCommands`, `ssm:CancelCommand` · `cloudwatch:DescribeAlarms`). AWS managed
  policies exist per service (`AWSFaultInjectionSimulatorECSAccess`, `…EC2Access`, `…SSMAccess`).
- stop-condition alarm ARNs → the alarms from the Terraform `observability` module (`alarm_arns` output),
  e.g. the availability fast-burn and latency alarms. **Never run without a stop condition.**
- cluster / service / ASG names if yours differ from cluster `student-app-lab`, service `student-app-lab-app`, ASG `student-app-lab-blue` (or `-green`).

```bash
# create (JSON files can't have comments: edit the placeholders first)
aws fis create-experiment-template --cli-input-json file://observability/fis/ecs-stop-half-tasks.json \
  --query 'experimentTemplate.id' --output text

# run, watch, stop
aws fis start-experiment --experiment-template-id <TEMPLATE_ID> --tags Scenario=75
aws fis get-experiment --id <EXPERIMENT_ID> --query 'experiment.state'
aws fis stop-experiment --id <EXPERIMENT_ID>          # the big red button

# cleanup
aws fis delete-experiment-template --id <TEMPLATE_ID>
```

Cost: FIS bills per action-minute (about $0.10). The faults themselves cost nothing extra,
but the replacements / scale-out they trigger do.

## Game-day checklist

Run it as a meeting with roles: **facilitator** (runs the checklist), **operator**
(starts/stops the experiment), **observers** (watch dashboards and alerts), **scribe** (timeline).

### 1. Hypothesis — write it down before touching anything
"When **<fault>** happens, **<what the system does>**, and users see **<SLO-level impact>**."
Example: *When half of the ECS tasks are stopped, the ALB routes around them within 30s,
ECS restores `desiredCount` within 2 minutes, availability stays ≥ 99.5% and p95 < 300ms.*

### 2. Steady state — prove "normal" first (10 minutes)
- [ ] Dashboards open: CloudWatch `student-app-lab-slo` / Grafana "SLOs & error budget" + RED.
- [ ] Background traffic running and green: `k6 run -e BASE_URL=http://<alb> -e VUS=10 -e DURATION=30m loadtest/k6/load.js`
- [ ] Baseline noted: req/s, error ratio, p95, healthy hosts, task/instance count.
- [ ] No open incident, no deploy in progress, error budget not already exhausted.

### 3. Blast radius — smallest experiment that can falsify the hypothesis
- [ ] Lab account / environment only (`Env=lab` tags), never shared with real users.
- [ ] Target selection limited (`COUNT(1)`, `PERCENT(50)`), action duration bounded (`PT5M`).
- [ ] Capacity check: with the targets gone, is there still capacity for the load? (≥ 2 tasks/instances, ≥ 2 AZs)
- [ ] Everyone affected has been told (channel + time window).

### 4. Abort conditions — decided in advance, not during the panic
- [ ] FIS stop condition alarm(s) set and in `OK` state before starting.
- [ ] Human abort criteria: availability < 99% for 2 minutes, p95 > 1s for 5 minutes,
      data errors of any kind, or "we do not understand what we are seeing".
- [ ] Abort command ready in a terminal: `aws fis stop-experiment --id …`; rollback plan known.

### 5. Run and observe
- [ ] Scribe records timestamps: start, first symptom, alert fired (which, when), recovery, end.
- [ ] Watch: ALB 5xx (ELB vs target), healthy hosts, ECS events / ASG activity history,
      burn-rate panels, Alertmanager / SNS notifications, Logs Insights for errors.
- [ ] Did the right alert fire at the right severity — and only that one?

### 6. Learnings — within 48 hours, blameless
- [ ] Hypothesis confirmed or refuted? With numbers (time to detect, time to recover, errors served, budget burned).
- [ ] Surprises (things nobody predicted) — these are the valuable part.
- [ ] Action items with owners: alarms to tune, health-check / deregistration-delay changes,
      capacity or `minHealthyPercent` changes, runbook updates
      ([incident response runbook](../../docs/devops/scenarios/76-incident-response.md)).
- [ ] Schedule the re-run that proves the fix.
