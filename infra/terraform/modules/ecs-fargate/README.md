# modules/ecs-fargate

ECS cluster + Fargate service for student-app (scenarios 50–57). Used by
[`stacks/50-ecs-fargate`](../../stacks/50-ecs-fargate/).

| What | Choice | Why |
|---|---|---|
| Cluster | Container Insights `enhanced`, capacity providers FARGATE + FARGATE_SPOT | per-task metrics; Spot ≈ 70% cheaper |
| Task | 0.5 vCPU / 1 GiB, container `app`, port 8080, `stopTimeout` 30 | CONVENTIONS §2 |
| Health | container `healthCheck` = `/up` (liveness), ALB TG = `/ready` (readiness) | a DB outage must not get every task killed |
| Secrets | `secrets[].valueFrom` = SSM parameter ARNs | execution role can read `<ssm_prefix>/*` only |
| Network | public subnets + public IP by default (no NAT) | NAT ≈ 32 USD/month; switch to private subnets + `assign_public_ip=false` when NAT/endpoints exist |
| Exec | `enable_execute_command`, task role has the 4 `ssmmessages` actions | debug without SSH (scenario 52) |
| Scaling | target tracking CPU 50% (+ ALBRequestCountPerTarget for ROLLING), 2–6 tasks | scenario 57 |

## Deployment matrix

| `deployment_controller` | `deployment_strategy` | Traffic | Rollback |
|---|---|---|---|
| `ECS` | `ROLLING` | replace tasks behind the blue TG | circuit breaker + optional alarms |
| `ECS` | `BLUE_GREEN` / `LINEAR` / `CANARY` | ECS shifts weights on a listener rule (blue ⇄ green), optional header test rule `X-Lab-Target: green` | automatic during bake time, alarms |
| `CODE_DEPLOY` | — | CodeDeploy (`modules/codedeploy`) shifts the listener | CodeDeploy auto-rollback |

## Ownership boundaries (important)

`lifecycle.ignore_changes = [task_definition, desired_count, load_balancer]`:

- **task_definition** — CI owns the image. Pipelines copy the *newest revision of the family*
  (which carries Terraform's latest env/secrets/roles) and swap only the image
  (`deploy/ecs/render-taskdef.sh live`). A Terraform change to env/secrets therefore reaches the
  running tasks with the **next deploy** (GitHub Actions / CodeBuild). The CodePipeline `ECS`
  action is the exception: it copies the service's *current* revision.
- **desired_count** — Application Auto Scaling owns it.
- **load_balancer** — native blue/green and CodeDeploy flip the primary target group after each
  deployment. Switching strategy families on an existing service:
  `terraform apply -replace=module.ecs.aws_ecs_service.app`.

`initProcessEnabled` defaults to **false**: the serversideup image runs S6 overlay, which must be
PID 1 and already reaps zombie processes (ECS Exec works without the ECS-injected init).
