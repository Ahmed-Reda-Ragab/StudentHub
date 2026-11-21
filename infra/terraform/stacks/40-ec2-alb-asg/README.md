# Stack 40 — EC2 + ALB + Auto Scaling (scenarios 40–49)

Immutable EC2 fleet behind a public ALB:

- [`modules/network`](../../modules/network): 2 AZs; NAT only with `private_instances = true`
- [`modules/alb`](../../modules/alb): target groups `blue`/`green` (health check `/ready`), **weighted**
  forward (`blue_weight`/`green_weight`), `/metrics` blocked with a fixed 404, optional HTTPS (ACM + Route 53)
- [`modules/asg-app`](../../modules/asg-app): launch template (AL2023 or Packer AMI, IMDSv2) whose user
  data renders `app.env` from SSM, reads `/student-app/<env>/deploy/<color>/IMAGE_URI` and runs the container;
  ELB health checks, instance refresh with auto rollback on alarms, CPU + request-count target tracking, optional Spot
- [`modules/rds-mysql`](../../modules/rds-mysql): MySQL 8.4 `db.t4g.micro`, encrypted, 7-day PITR, writes `DB_*` to SSM
- [`modules/elasticache-redis`](../../modules/elasticache-redis) (`redis_enabled`): sessions/cache → Redis (scenario 49)
- [`modules/observability`](../../modules/observability): 5xx ratio, p95 latency, unhealthy hosts, SLO burn-rate
  composites, RDS alarms, JSON error-log metric, dashboard

| Scenario | What to change |
|---|---|
| 40 VPC · 41 RDS · 42 ALB + ASG | defaults (`domain_name`/`hosted_zone_id` for ACM + Route 53) |
| 43 golden AMI | `ami_id`, `golden_ami = true` |
| 44 rolling (instance refresh) | CI: put-parameter + `start-instance-refresh` (see `terraform output release_commands`, `.github/workflows/deploy-asg.yml`) |
| 45 blue/green (two ASGs) | `green_enabled = true`, deploy to green, then `blue_weight = 0`, `green_weight = 100` (or CI with `listener_weights_managed_externally = true`) |
| 46 canary (weighted TGs) | weights 90/10 → 50/50 → 0/100 (+ `stickiness_duration`) |
| 47 Ansible rolling | `infra/ansible/playbooks/rolling-asg.yml` (no Terraform change) |
| 48 autoscaling / Spot | target-tracking policies are on by default (asg-app: CPU + requests per target); `spot_enabled` |
| 49 Redis | `redis_enabled = true` |
| 37 CodeDeploy on this ASG | `codedeploy_enabled = true`, `codedeploy_revision_bucket` |
| 77 DR | RDS point-in-time restore (console/CLI), `db_multi_az` |

## Use

```bash
cd infra/terraform/stacks/40-ec2-alb-asg
cp terraform.tfvars.example terraform.tfvars        # set image_tag to a SHA CI pushed to ECR
terraform init -backend-config=../../backend.hcl
terraform plan -out=tfplan
terraform apply tfplan                               # ~10 min (RDS)

eval "$(terraform output -raw migrate_command)"     # once, on one instance
curl -s "$(terraform output -raw app_url)/ready"
```

After the first apply, **CI owns the image**: `deploy/<color>/IMAGE_URI` has `ignore_changes`, so
changing `image_tag` later does nothing. If CI shifts weights with `modify-listener`, copy the new
weights into tfvars, or the next apply reverts them (drift — a good interview topic).

A CI-started refresh (no launch-template change) cannot "auto roll back" the image: the alarm
specification stops the refresh, and rollback = put the previous IMAGE_URI back + refresh again
(`aws ssm get-parameter-history`).

## Destroy

```bash
terraform destroy
```

RDS is deleted without a final snapshot (`db_skip_final_snapshot = true`) and without deletion
protection — lab defaults. Destroy before applying stack 20/50/60 for the same `env` (shared SSM paths).

## Cost (us-east-1, defaults)

| Item | ≈ USD/hour |
|---|---|
| ALB (+ its public IPv4s, low LCU) | 0.03 |
| 2 × t3.micro + public IPv4 | 0.03 |
| RDS db.t4g.micro + 20 GiB gp3 | 0.02 |
| CloudWatch alarms (~14, metric math counts per metric) | ~3/month |
| NAT (`private_instances`) | +0.045 + data |
| ElastiCache t4g.micro (`redis_enabled`) | +0.013 |

≈ 0.08 USD/hour ≈ 2 USD/day. **Destroy when done.**

## Outputs

`alb_dns_name`, `app_url`, `asg_names`, `image_parameter_names`, `target_group_arns`, `target_group_names`,
`listener_arn`, `rds_address`, `redis_endpoint`, `sns_topic_arn`, `dashboard_url`, `log_group_name`, `ssm_prefix`,
`sre_lab_token` (sensitive), `migrate_command`, `release_commands`.
