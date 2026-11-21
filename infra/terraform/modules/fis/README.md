# modules/fis

Optional AWS Fault Injection Service experiment templates (scenario 75). Templates are free;
experiments are billed per action-minute while they run.

| Template | Created when | Hypothesis to verify |
|---|---|---|
| `ecs_stop_tasks` | `ecs_cluster_name` + `ecs_service_name` | stopping 50% of tasks keeps availability ≥ 99.5% (ALB + ECS replace capacity) |
| `asg_terminate_one` | `asg_name` | the ASG replaces the instance, `/ready` health checks hide it from users |
| `cpu_stress` | `cpu_stress_target_tags` | CPU target tracking adds capacity before p95 latency breaks 300 ms |

Always pass `stop_condition_alarm_arn` (e.g. an ALB 5xx alarm): FIS aborts the experiment as soon as
the alarm fires. Stack 50 reuses its `student-app-lab-alb-5xx-ratio` alarm as the stop condition when `enable_fis = true`.

```bash
aws fis start-experiment --experiment-template-id "$(terraform output -json fis_experiment_template_ids | jq -r .ecs_stop_tasks)"
```
