# Stack 20 — single EC2 Docker host (scenarios 20–27, 31–33)

One Amazon Linux 2023 instance with Docker Compose, an Elastic IP, a local MySQL container and
everything the deploy scripts in [`deploy/ec2/`](../../../../deploy/ec2/) expect:

- VPC from [`modules/network`](../../modules/network) (public subnets, **no NAT**)
- EC2 from [`modules/ec2-docker-host`](../../modules/ec2-docker-host): IMDSv2, encrypted gp3, user data =
  [`deploy/ec2/user-data.sh`](../../../../deploy/ec2/user-data.sh), port 80 open, **no port 22** by default
- Instance role: SSM core (Session Manager / Run Command), ECR pull (`student-app` only),
  read `/student-app/<env>/*` + decrypt via SSM, CloudWatch agent, S3 backups bucket
- Backups bucket `student-app-<env>-backups-<account>` (SSE, private, TLS-only, dumps expire after 30 days)
- SSM parameters: `app/{APP_KEY,APP_URL,DB_*,SESSION_DRIVER,CACHE_STORE,SRE_LAB_*,METRICS_ENABLED}`
  and `mysql/{MYSQL_DATABASE,MYSQL_USER,MYSQL_PASSWORD,MYSQL_ROOT_PASSWORD}`

## Use

```bash
cd infra/terraform/stacks/20-ec2-single
cp terraform.tfvars.example terraform.tfvars
terraform init -backend-config=../../backend.hcl
terraform plan -out=tfplan
terraform apply tfplan

$(terraform output -raw ssm_start_session)     # shell on the box, no SSH key
cat /opt/student-app/.bootstrapped              # user data finished?
```

Then follow the scenario docs: render the env (`deploy/ec2/render-env-from-ssm.sh`), build on the
server (scenario 20) or pull from ECR (scenario 32/33), blue/green on one host (`deploy/ec2/lb/`, 23–26),
backups (`deploy/ec2/backup-mysql-to-s3.sh` with `BACKUP_BUCKET=$(terraform output -raw backup_bucket)`, 27).

GitHub wiring: `EC2_INSTANCE_ID` = `instance_id`, `EC2_HOST` = `public_ip`, secret `SRE_LAB_TOKEN` =
`terraform output -raw sre_lab_token`.

## Destroy

```bash
terraform destroy
```

The backups bucket is deleted with its dumps (`backup_bucket_force_destroy = true`), the local MySQL
volume dies with the instance. Stacks 40/50/60 write the same `/student-app/<env>/app/*` parameters:
destroy this stack before applying another one for the same `env`.

## Cost (us-east-1, on-demand)

| Item | ≈ USD |
|---|---|
| t3.small | 0.0208/h → ~15/month if left running |
| 20 GiB gp3 | 1.60/month |
| Elastic IP | 0.005/h (every public IPv4 is billed) |
| S3, SSM Standard params, CloudWatch basic | cents |

A 3-hour practice session costs ~0.10 USD. **Destroy when done.**

## Outputs

`instance_id`, `public_ip`, `public_dns`, `app_url`, `ssm_start_session`, `backup_bucket`, `ssm_prefix`,
`ecr_repository_url`, `sre_lab_token` (sensitive).
