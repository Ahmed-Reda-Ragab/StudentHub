# infra/terraform — AWS for the student-app lab

Everything here follows the lab contract in [`docs/devops/CONVENTIONS.md`](../../docs/devops/CONVENTIONS.md)
(§1 names/tags, §4 SSM layout, §5 SLOs, §6 Terraform). Terraform `>= 1.11` (CI pins `~1.14`), AWS provider `~> 6.0`.

```
infra/terraform/
├── backend.hcl.example     partial S3 backend (bucket, region, use_lockfile) shared by every stack
├── .tflint.hcl             tflint + AWS ruleset (CI: lint-infra.yml)
├── bootstrap/              ONCE per account, long-lived: state bucket, GitHub OIDC roles, ECR, CodeConnections
├── modules/                reusable building blocks (no provider/backend config)
│   ├── network             VPC, public/private subnets per AZ, optional NAT, free S3 gateway endpoint
│   ├── alb                 ALB + blue/green target groups + weighted listener, /metrics blocked
│   ├── rds-mysql           MySQL 8.4, encrypted, PITR, writes DB_* to SSM
│   ├── ec2-docker-host     single AL2023 Docker host (IMDSv2, EIP)
│   ├── asg-app             launch template + ASG (instance refresh, Spot, target tracking)
│   ├── elasticache-redis   single-node Valkey/Redis, writes REDIS_* to SSM
│   ├── observability       SNS, symptom + SLO burn-rate alarms, dashboard
│   └── ecs-fargate, codebuild, codepipeline, codedeploy, fis
└── stacks/                 EPHEMERAL root modules: apply -> practise -> destroy
    ├── 20-ec2-single       scenarios 20–27, 31–33
    ├── 35-codebuild        35
    ├── 36-codepipeline     36, 37, 58
    ├── 40-ec2-alb-asg      40–49
    ├── 50-ecs-fargate      50–58
    └── 60-eks              60–6A
```

## Order of apply

1. **bootstrap** (laptop, admin credentials, local state) → migrate its state into the bucket it created →
   set the GitHub repository variables from `terraform output github_repository_variables`
   (see [bootstrap/README.md](bootstrap/README.md)).
2. Push to `master` once so `ci.yml` puts a first image (`student-app:<sha>`) in ECR.
3. Any **one** application stack (20, 40, 50 or 60) per `env`, from your laptop or from GitHub
   (Actions → *Terraform* → Run workflow → stack + action). 35/36 build on 50 (and bootstrap's connection).

```bash
cp infra/terraform/backend.hcl.example infra/terraform/backend.hcl   # fill in bucket/region
cd infra/terraform/stacks/40-ec2-alb-asg
terraform init -backend-config=../../backend.hcl
terraform plan -out=tfplan && terraform apply tfplan
terraform destroy
```

## State

- One S3 bucket `student-app-tfstate-<account_id>` (versioned, SSE, TLS-only, public access blocked).
- One key per root module: `bootstrap/terraform.tfstate`, `stacks/<NN-name>/terraform.tfstate`. Each
  stack pins its key in `backend "s3" { key = ... }`; `backend.hcl` carries only bucket/region/locking.
- Locking: `use_lockfile = true` — S3-native lock object `<key>.tflock` (GA since Terraform 1.11), no DynamoDB.
- State contains secrets (random passwords, `APP_KEY`): access to the bucket = access to secrets.
  Old versions are kept 90 days (min. 10 versions) as an undo button.

## How stacks share data

Stacks never read each other's state (`terraform_remote_state` couples lifecycles: destroying one
would break the other's plan). Instead:

| Shared thing | Mechanism |
|---|---|
| Names | Deterministic from `project` + `env` (`student-app-lab-*`, CONVENTIONS §1) |
| Account / region | `data.aws_caller_identity`, `data.aws_region` — no hardcoded IDs |
| ECR repo | Built from account + region + `ecr_repository_name` (created by bootstrap) |
| Runtime config & secrets | SSM `/student-app/<env>/app/*` — written by the stack, read by EC2 user data, ECS `secrets`, External Secrets |
| Current release | SSM `/student-app/<env>/deploy/<color>/IMAGE_URI` — seeded by Terraform (`ignore_changes`), owned by CI |
| Role ARNs, bucket | bootstrap outputs → GitHub repository variables (CONVENTIONS §9) |

Because 20/40/50/60 all write `/student-app/<env>/app/*`, run one of them per `env` at a time, or give
the second one another env (`-var env=lab2`).

## Module interfaces (CONVENTIONS §6, extras have defaults)

| Module | Required/main inputs | Outputs |
|---|---|---|
| `network` | `name, cidr="10.20.0.0/16", az_count=2, enable_nat=false, single_nat=true` (+ `enable_s3_endpoint`, subnet tags) | `vpc_id, vpc_cidr, azs, public_subnet_ids, private_subnet_ids` (+ route tables, `nat_public_ips`) |
| `alb` | `name, vpc_id, subnet_ids, certificate_arn=null, health_check_path="/ready"` (+ `target_type`, `target_port=8080`, `blue_weight=100`, `green_weight=0`, `https_enabled`, `stickiness_duration`) | `alb_arn, alb_arn_suffix, dns_name, zone_id, security_group_id, listener_http_arn, listener_https_arn, target_group_arns{blue,green}, target_group_arn_suffixes{blue,green}` (+ `target_group_names`, `listener_arn`) |
| `rds-mysql` | `name, vpc_id, subnet_ids, allowed_security_group_ids, instance_class="db.t4g.micro", engine_version="8.4", multi_az=false, ssm_prefix` (+ `deletion_protection`, `skip_final_snapshot`, `use_secrets_manager`) | `address, port, db_name, username, security_group_id, password_ssm_arn` (+ `identifier`, `master_user_secret_arn`, `ssm_parameter_arns`) |
| `ec2-docker-host` | `name, vpc_id, subnet_id, instance_type, arch, key_name=null, ingress_cidrs, ssh_cidrs=[], user_data, instance_profile` | `instance_id, public_ip, public_dns, security_group_id` |
| `asg-app` | `name, vpc_id, subnet_ids, target_group_arns, image_uri, ami_id=null, instance_type, min, max, desired, ssm_prefix, instance_profile` (+ `color`, refresh/Spot/scaling inputs) | `asg_name, launch_template_id, security_group_id` (+ `image_parameter_name`) |
| `elasticache-redis` | `name, vpc_id, subnet_ids, allowed_security_group_ids, ssm_prefix` | `primary_endpoint_address, port, security_group_id` |
| `observability` | `name, alarm_email, alb_arn_suffix, target_group_arn_suffixes, asg_name / asg_names, ecs_cluster_name, ecs_service_name` (+ `rds_instance_id`, `log_group_name`, `enable_alb_alarms`) | `sns_topic_arn, dashboard_name, alarm_arns` (+ `alarm_names`, `dashboard_url`) |

Pitfall handled in the modules: `count` cannot depend on values unknown until apply. Hence explicit
switches such as `alb.https_enabled`, `observability.enable_alb_alarms`, `asg-app.enable_request_scaling`,
and `count = length(list)` (not `for_each`) for security-group references created in the same plan.

## CI

- [`lint-infra.yml`](../../.github/workflows/lint-infra.yml): `fmt -check`, `validate` every root module
  (no backend), tflint (AWS ruleset), checkov (report only).
- [`terraform.yml`](../../.github/workflows/terraform.yml) (scenario 92): PR → plan of every affected stack
  as a PR comment (read-only role, optional Infracost); manual run → plan, then apply/destroy behind the
  `lab` environment with the admin role.

## Cost (us-east-1, defaults, on-demand, approximate)

| Root module | Idle cost | Notes |
|---|---|---|
| bootstrap | < 0.50 USD/month | S3 state, ECR storage (30 images max); IAM/OIDC/CodeConnections free |
| 20-ec2-single | ~0.03 USD/h | t3.small + 20 GiB gp3 + Elastic IP |
| 40-ec2-alb-asg | ~0.08 USD/h | ALB, 2 × t3.micro, RDS db.t4g.micro, ~3 USD/month alarms; NAT +0.045/h, Redis +0.013/h |
| 50-ecs-fargate | see its README | ALB + Fargate tasks + RDS |
| 60-eks | see its README | EKS control plane alone is 0.10 USD/h |

Biggest traps: NAT gateways (~32 USD/month each, off by default), forgotten stacks, EKS control plane,
public IPv4 addresses (0.005 USD/h each). Set an AWS Budget alert before the first apply.

## Destroy order

1. Dependent stacks first: `36-codepipeline` → `35-codebuild` → `50-ecs-fargate` / `40-ec2-alb-asg` /
   `20-ec2-single` / `60-eks` (each `terraform destroy` in its directory, or the workflow with `destroy`).
2. Check nothing is left: `aws resourcegroupstaggingapi get-resources --tag-filters Key=Project,Values=student-app`.
3. bootstrap only when leaving the lab for good (see [bootstrap/README.md](bootstrap/README.md#destroy-only-when-leaving-the-lab-for-good)).
