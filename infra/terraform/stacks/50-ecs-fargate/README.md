# Stack 50 — ECS on Fargate (scenarios 50–58)

- [`modules/network`](../../modules/network): VPC, 2 AZs, **no NAT** (tasks in public subnets, inbound only from the ALB SG)
- [`modules/alb`](../../modules/alb): `target_type = ip`, TGs `blue`/`green` (health check `/ready`), `/metrics` blocked
- [`modules/ecs-fargate`](../../modules/ecs-fargate): cluster (Container Insights enhanced, FARGATE + FARGATE_SPOT),
  task `app` (0.5 vCPU / 1 GiB, port 8080, `/up` container health check, secrets from SSM), service with ECS Exec,
  circuit breaker, deployment strategy, autoscaling 2–6 (CPU 50% + requests per target)
- [`modules/rds-mysql`](../../modules/rds-mysql): MySQL 8.4 in private subnets, writes `DB_*` to SSM
- [`ssm.tf`](ssm.tf): `APP_KEY` (`base64:` + 32 random bytes), `SRE_LAB_TOKEN`, `APP_URL`, `DB_CONNECTION`, `SESSION_DRIVER`/`CACHE_STORE=database`, `SRE_LAB_ENABLED`, `METRICS_ENABLED`
- [`modules/codedeploy`](../../modules/codedeploy) when `deployment_controller = "CODE_DEPLOY"`
- [`modules/observability`](../../modules/observability): 5xx ratio, p95, unhealthy hosts, SLO burn rate, dashboard
- [`modules/fis`](../../modules/fis) when `enable_fis = true`

| Scenario | Change |
|---|---|
| 50–52 | defaults; `deploy/ecs/ecs-exec.sh` for Exec |
| 53 rolling + circuit breaker | defaults; boot-fail drill: `deploy-ecs.yml` with `run_migrations=false` + `extra_env=SRE_FAULT_BOOT_FAIL=true` → automatic rollback |
| 54 CodeDeploy blue/green / canary / linear | `deployment_controller = "CODE_DEPLOY"`, `codedeploy_deployment_config_name` (listener weights then owned by CodeDeploy) |
| 55 ECS-native blue/green | `deployment_strategy = "BLUE_GREEN"` (test traffic: `curl -H 'X-Lab-Target: green' <app_url>/ready`) |
| 55 ECS-native linear / canary | `deployment_strategy = "LINEAR"` / `"CANARY"` |
| 53–55 alarm rollback | `use_deployment_alarms = true`; deploy with `extra_env=SRE_FAULT_ERROR_RATE=0.5` |
| 56 capacity providers + Spot | `use_fargate_spot` |
| 57 autoscaling under load | k6 `loadtest/k6/autoscale-cpu.js` + `/sre-lab/cpu` (target tracking CPU 50%, 2–6 tasks) |
| 58 GitHub Actions vs CodePipeline | `.github/workflows/deploy-ecs.yml` vs [stack 36](../36-codepipeline/) |
| 75 chaos | `enable_fis = true` |

Switching between ROLLING and the traffic-shifting strategies, or between ECS and CODE_DEPLOY, on an
**existing** service: `terraform apply -replace=module.ecs.aws_ecs_service.app` (the service ignores
`load_balancer` changes because blue/green deployers swap the target groups).

## Use

```bash
cd infra/terraform/stacks/50-ecs-fargate
cp terraform.tfvars.example terraform.tfvars          # image_tag = a SHA CI pushed to ECR
terraform init -backend-config=../../backend.hcl
terraform plan -out=tfplan
terraform apply tfplan                                 # ~10 min (RDS)

# once, before the first real traffic (tasks start fine and /ready is 200 — it only pings the DB — but real pages like /login fail until the schema exists)
cmd="$(terraform output -raw migration_script_command)" && (cd ../../../.. && eval "$cmd")   # the script path is relative to the repo root
curl -s "$(terraform output -raw app_url)/ready"

# repository variables for deploy-ecs.yml
terraform output github_repository_variables
```

After the first apply **CI owns the image** (`ignore_changes = [task_definition]`): deploy with
`.github/workflows/deploy-ecs.yml` or stack 36. Terraform changes to env/secrets reach the tasks with
the next CI deploy (`taskdef_source=live` copies the newest revision of the family).

## Destroy

```bash
terraform destroy
```

Leaves nothing behind except CI-registered task definition revisions (INACTIVE after
deregistration, free). Destroy before applying stack 20/40/60 for the same `env` (shared SSM paths).

## Cost (us-east-1, defaults, ≈)

| Item | USD/hour |
|---|---|
| ALB (+ ~1 LCU) | 0.03 |
| Fargate: 1 × on-demand 0.5 vCPU/1 GiB + 1 × Spot | 0.025 + 0.008 |
| Public IPv4 (2 ALB + 2 tasks) | 0.02 |
| RDS db.t4g.micro + 20 GiB gp3 (free tier eligible) | 0.019 |
| Container Insights enhanced, logs, alarms, dashboard | ~0.01 |
| **Total** | **≈ 0.11 (≈ 2.70/day, ≈ 80/month)** |

`enable_nat = true` adds ≈ 0.045/h + data processing. Apply → practise → destroy the same day.

## Outputs

`app_url`, `cluster_name`, `service_name`, `task_family`, `log_group`, `migration_command` (raw
`aws ecs run-task`), `migration_script_command`, `ecs_exec_command`, `target_group_names`,
`listener_arn`, `run_task_network_configuration`, `deployment`, `codedeploy_*`, `rds_address`,
`ssm_prefix`, `dashboard_url`, `github_repository_variables`, `pipeline_inputs` (feeds stack 36).
