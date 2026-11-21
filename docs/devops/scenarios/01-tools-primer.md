# 01 — نبذة عن كل tool بنستخدمها في المعمل

> **الهدف في سطر:** تعرف كل أداة في المعمل هي إيه، بنستخدمها فين بالظبط (أنهي سيناريو)، بديلها إيه، وأهم أوامرها، عشان لما تقابلها في أي سيناريو متبقاش غريبة عليك.
> **المستوى:** Beginner → Intermediate · **الوقت:** ~3 ساعات قراية (وارجعله كـ reference) · **التكلفة التقريبية:** مجاني
> **بيعتمد على:** مفيش · **الملفات في الـ repo:** [`docs/devops/CONVENTIONS.md`](../CONVENTIONS.md) · [`.github/workflows/`](../../../.github/workflows) · [`docker/Dockerfile`](../../../docker/Dockerfile) · [`deploy/`](../../../deploy)

## 1) الفكرة (Concepts)

الـ Senior DevOps مش لازم يكون خبير في كل أداة، بس لازم يعرف **كل أداة بتحل مشكلة إيه، وبتتحط فين في الـ pipeline، وإيه الـ trade-off بتاعها مقابل بديلها**. أسئلة الـ interview غالباً بتبقى "ليه اخترت X مش Y؟" مش "اكتبلي الـ flag الفلانية".

كل أداة تحت ليها **كارت** فيه: إيه هي، بنستخدمها في أنهي سيناريو، البدائل، وأهم 3–6 أوامر. الأوامر حقيقية وبتشتغل على المعمل ده (أسماء الملفات والـ resources من [CONVENTIONS](../CONVENTIONS.md)).

### الملخص في جدول واحد

| الفئة | الأدوات | السيناريوهات |
|---|---|---|
| Source & CI | Git/GitHub، GitHub Actions، Dependabot | كلها، 30–34، 58، 82، 92 |
| Containers | Docker، Docker Compose، BuildKit/buildx، nginx، PHP-FPM + S6، MySQL، Redis | 10–12، 20–27، 49 |
| AWS — Identity & Network | IAM، IAM Identity Center، VPC، Security Groups، Route 53، ACM | 02، 20، 40، 42، 80، 83 |
| AWS — Compute | EC2، EBS، AMI، ELB/ALB، Auto Scaling، ECS، Fargate، EKS | 20–27، 40–48، 50–58، 61–6A |
| AWS — Data | RDS، ElastiCache، S3، ECR | 27، 30، 41، 49، 77 |
| AWS — Config & Secrets | SSM (Session Manager، Run Command، Parameter Store)، Secrets Manager، KMS | 20، 32، 64، 81 |
| AWS — Observability | CloudWatch (Logs، Metrics، Alarms، Dashboards، Container Insights)، X-Ray، SNS | 70–73 |
| AWS — Delivery | CodeBuild، CodePipeline، CodeDeploy، CodeConnections | 35–37، 54، 58 |
| AWS — Resilience & Cost | FIS، WAF، Budgets/Cost Explorer | 02، 75، 83، 97 |
| IaC | Terraform، Ansible، Packer | 21، 33، 43، 47، 90–93 |
| Kubernetes | Kubernetes، kubectl، kind، eksctl، Helm، Kustomize، Argo CD، Argo Rollouts، Karpenter، AWS LBC، ESO، metrics-server/HPA | 60–6A |
| Observability | Prometheus، Alertmanager، Grafana، Loki، Grafana Alloy، OpenTelemetry، k6 | 12، 70–74 |
| Security & Lint | Trivy، Syft/SBOM، cosign، hadolint، ShellCheck، actionlint، tflint، checkov، ansible-lint، kubeconform، Infracost | 11، 30، 82، 92 |

## 2) المعمارية (Architecture): كل أداة بتقعد فين

```text
 laptop (WSL2)                GitHub                                 AWS
 ─────────────                ──────                                 ───
 git ──push──► repo ──► GitHub Actions ─────────────┐
 docker/compose            │  pint · phpunit · hadolint                │ OIDC (no keys)
 terraform/ansible         │  buildx → Trivy → Syft(SBOM) → cosign      ▼
 kubectl/helm/k6           │                                    ECR (image:<sha>)
                           │  Dependabot · actionlint · tflint          │
                           │  checkov · kubeconform · Infracost         │
                           └──► deploy ──────────────────────────────────┤
                                                                         ▼
   Route 53 → ACM/ALB (+WAF) → EC2/ASG  │  ECS/Fargate  │  EKS (+LBC, Karpenter, Argo)
                                  │            │               │
                     SSM Parameter Store / Secrets Manager (KMS) → env للتطبيق
                                  │
                     RDS MySQL · ElastiCache Redis · S3 (backups)
                                  │
   metrics/logs/traces → CloudWatch | Prometheus + Grafana + Loki (Alloy/OTel) → Alertmanager/SNS
   chaos → FIS          cost → Budgets / Cost Explorer / Infracost
```

## 3) المتطلبات (Prerequisites)

- [ ] مفيش حاجة تتثبت عشان تقرا الملف ده. التثبيت الفعلي في [03 — تجهيز الجهاز](03-workstation-setup.md).
- [ ] الأوامر اللي فيها `aws` محتاجة profile شغال (اقرا [02 — تجهيز حساب AWS](02-aws-account-setup.md)).
- [ ] الأوامر اللي فيها `docker` محتاجة Docker (محلي على WSL2) **أو** شغّلها على GitHub Actions (شوف [03](03-workstation-setup.md)).

## 4) الطريقة الأولى: AWS Console — كروت خدمات AWS

> كل خدمة هنا هتقابلها في الـ Console الأول (سيناريوهات الـ ✅ Console) وبعدين في Terraform. الأسعار **تقريبية لـ us-east-1 — راجع صفحة الأسعار**.

### Identity

#### IAM
- **إيه هو:** نظام الصلاحيات: Users، Roles، Policies. القاعدة في المعمل: **مفيش access keys طويلة العمر** — الناس بتدخل بـ Identity Center، والـ machines (EC2/ECS/GitHub) بـ Roles.
- **في المعمل:** 02، 20 (instance profile)، 30 (OIDC role)، 80 (least privilege).
- **البدائل:** مفيش جوه AWS؛ خارجها Okta/Entra كـ IdP.
```bash
aws sts get-caller-identity
aws iam list-roles --query "Roles[?starts_with(RoleName,'student-app')].RoleName"
aws iam get-role --role-name student-app-gha-ci --query Role.AssumeRolePolicyDocument
aws iam simulate-principal-policy --policy-source-arn arn:aws:iam::<ACCOUNT_ID>:role/student-app-gha-ci --action-names ecr:PutImage
```

#### IAM Identity Center
- **إيه هو:** SSO للحساب (أو الـ Organization): user واحد + Permission sets → credentials مؤقتة للـ Console والـ CLI.
- **في المعمل:** 02، 03 (`aws configure sso`).
- **البدائل:** IAM users + MFA (قديم ومش مستحب)، IdP خارجي.
```bash
aws configure sso                       # مرة واحدة: start URL + region + account + role
aws sso login --profile lab
aws sts get-caller-identity --profile lab
export AWS_PROFILE=lab
```

### Network & Edge

#### VPC
- **إيه هو:** الشبكة الخاصة بتاعتك: CIDR، subnets (public/private)، route tables، Internet Gateway، NAT Gateway.
- **في المعمل:** 20 (default VPC)، 40 (VPC من الصفر)، 50/60. الـ module `network` في Terraform (`enable_nat=false` افتراضياً عشان الـ NAT غالي ~$32/شهر).
- **البدائل:** الـ default VPC (سريع للتجارب بس كل الـ subnets public).
```bash
aws ec2 describe-vpcs --query 'Vpcs[].{id:VpcId,cidr:CidrBlock,default:IsDefault}' --output table
aws ec2 describe-subnets --filters Name=vpc-id,Values=<VPC_ID> --query 'Subnets[].{id:SubnetId,az:AvailabilityZone,public:MapPublicIpOnLaunch}' --output table
aws ec2 describe-nat-gateways --query 'NatGateways[?State==`available`].NatGatewayId'
```

#### Security Groups
- **إيه هو:** firewall **stateful** على مستوى الـ ENI. بتسمح بس (مفيش deny). أحسن ممارسة: SG يشاور على SG (`ALB-SG → App-SG → DB-SG`) بدل CIDRs.
- **في المعمل:** 20 (بورت 80 بس، من غير 22)، 41، 42.
- **البدائل:** NACLs (stateless، على مستوى الـ subnet)، AWS Network Firewall.
```bash
aws ec2 describe-security-groups --filters Name=tag:Project,Values=student-app --query 'SecurityGroups[].{id:GroupId,name:GroupName}'
aws ec2 authorize-security-group-ingress --group-id <SG_ID> --protocol tcp --port 80 --cidr <MY_IP>/32
aws ec2 revoke-security-group-ingress --group-id <SG_ID> --protocol tcp --port 22 --cidr 0.0.0.0/0
```

#### Route 53
- **إيه هو:** DNS (hosted zones، records، alias لـ ALB، health checks، weighted/failover routing).
- **في المعمل:** 42، 63، 83 (اختياري — محتاج domain). الـ hosted zone ~$0.50/شهر.
- **البدائل:** Cloudflare DNS.
```bash
aws route53 list-hosted-zones --query 'HostedZones[].{name:Name,id:Id}'
aws route53 list-resource-record-sets --hosted-zone-id <ZONE_ID> --query "ResourceRecordSets[?Type=='A']"
dig +short app.<DOMAIN>
```

#### ACM
- **إيه هو:** شهادات TLS **مجانية** للـ ALB/CloudFront، بتتجدد لوحدها لو الـ validation بالـ DNS.
- **في المعمل:** 42، 63، 83.
- **البدائل:** Let's Encrypt (certbot / cert-manager على K8s).
```bash
aws acm request-certificate --domain-name app.<DOMAIN> --validation-method DNS
aws acm describe-certificate --certificate-arn <CERT_ARN> --query 'Certificate.{status:Status,validation:DomainValidationOptions[0].ResourceRecord}'
aws acm list-certificates --certificate-statuses ISSUED
```

#### WAF
- **إيه هو:** Web Application Firewall قدام الـ ALB/CloudFront: managed rule groups (OWASP، bad inputs)، rate-based rules.
- **في المعمل:** 83. تقريباً $5/web ACL/شهر + $1/rule + رسوم لكل مليون request.
- **البدائل:** Cloudflare WAF، ModSecurity على nginx.
```bash
aws wafv2 list-web-acls --scope REGIONAL
aws wafv2 get-web-acl --scope REGIONAL --name <ACL_NAME> --id <ACL_ID>
aws wafv2 get-sampled-requests --web-acl-arn <ACL_ARN> --rule-metric-name <RULE_METRIC> --scope REGIONAL --time-window StartTime=<ISO_START>,EndTime=<ISO_END> --max-items 50
```

### Compute

#### EC2
- **إيه هو:** Virtual machines. في المعمل: Amazon Linux 2023، `t3.small` (أو `t4g.small` Graviton أرخص بـ ~20%).
- **في المعمل:** 20–27، 31–33، 42–48.
- **البدائل:** Lightsail (أبسط)، ECS/Fargate (من غير سيرفرات تديرها).
```bash
aws ec2 describe-instances --filters Name=tag:Project,Values=student-app Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].{id:InstanceId,type:InstanceType,ip:PublicIpAddress}' --output table
aws ec2 stop-instances --instance-ids <INSTANCE_ID>
aws ec2 terminate-instances --instance-ids <INSTANCE_ID>
aws ec2 get-console-output --instance-id <INSTANCE_ID> --latest --output text | tail -50
```

#### EBS
- **إيه هو:** الـ disks بتاعة EC2 (gp3 هو الـ default الصح). بتفضل موجودة ومتحاسب عليها لو الـ instance اتمسح من غير `DeleteOnTermination`.
- **في المعمل:** 20 (root volume)، 77 (snapshots). gp3 تقريباً $0.08/GB/شهر.
- **البدائل:** Instance store (سريع ومؤقت)، EFS (shared NFS).
```bash
aws ec2 describe-volumes --filters Name=status,Values=available --query 'Volumes[].{id:VolumeId,size:Size}'   # volumes يتيمة بتتحاسب
aws ec2 create-snapshot --volume-id <VOLUME_ID> --description "student-app lab before upgrade"
aws ec2 describe-snapshots --owner-ids self --query 'Snapshots[].{id:SnapshotId,start:StartTime}'
```

#### AMI
- **إيه هو:** صورة الـ disk اللي الـ instance بيقوم منها. ممكن تستخدم AMI عامة (AL2023) أو **Golden AMI** معمولة بـ Packer فيها Docker جاهز.
- **في المعمل:** 20 (AL2023)، 43 (Packer)، 44 (instance refresh بـ AMI جديدة).
- **البدائل:** user-data بيثبت كل حاجة عند الـ boot (أبطأ وأقل reproducible).
```bash
aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --query Parameter.Value --output text
aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64 --query Parameter.Value --output text
aws ec2 describe-images --owners self --query 'Images[].{id:ImageId,name:Name,created:CreationDate}'
aws ec2 deregister-image --image-id <AMI_ID>
```

#### ELB / ALB
- **إيه هو:** Application Load Balancer (L7): listeners، rules، target groups، health checks على `/ready`، و **weighted target groups** (canary/blue-green من غير DNS).
- **في المعمل:** 42، 44–46، 50–55، 63. تقريباً $0.0225/ساعة + LCU (~$16+/شهر).
- **البدائل:** NLB (L4)، nginx/HAProxy على EC2 (زي `deploy/ec2/lb` في 23–26).
```bash
aws elbv2 describe-load-balancers --query 'LoadBalancers[].{name:LoadBalancerName,dns:DNSName}'
aws elbv2 describe-target-health --target-group-arn <TG_ARN> --query 'TargetHealthDescriptions[].{id:Target.Id,state:TargetHealth.State,reason:TargetHealth.Reason}'
aws elbv2 modify-listener --listener-arn <LISTENER_ARN> --default-actions \
  'Type=forward,ForwardConfig={TargetGroups=[{TargetGroupArn=<BLUE_TG_ARN>,Weight=90},{TargetGroupArn=<GREEN_TG_ARN>,Weight=10}]}'
```

#### Auto Scaling (ASG)
- **إيه هو:** بيحافظ على عدد instances (min/desired/max) من Launch Template، بيبدّل الـ unhealthy، وبيعمل scaling بـ target tracking و **Instance Refresh** (rolling deploy).
- **في المعمل:** 42، 44، 45، 48.
- **البدائل:** ECS service autoscaling، Karpenter على EKS.
```bash
aws autoscaling describe-auto-scaling-groups --query 'AutoScalingGroups[].{name:AutoScalingGroupName,desired:DesiredCapacity,inService:length(Instances)}'
aws autoscaling start-instance-refresh --auto-scaling-group-name <ASG_NAME> --preferences '{"MinHealthyPercentage":90,"InstanceWarmup":60}'
aws autoscaling describe-instance-refreshes --auto-scaling-group-name <ASG_NAME> --max-records 1
aws autoscaling cancel-instance-refresh --auto-scaling-group-name <ASG_NAME>
```

#### ECS
- **إيه هو:** Container orchestrator بتاع AWS: cluster → service → tasks من task definition. deployment controllers: ECS rolling (+ circuit breaker)، ECS native blue/green/linear/canary، أو CodeDeploy.
- **في المعمل:** 50–58.
- **البدائل:** EKS (أقوى وأعقد)، App Runner (أبسط).
```bash
aws ecs list-services --cluster <ECS_CLUSTER>
aws ecs describe-services --cluster <ECS_CLUSTER> --services <ECS_SERVICE> --query 'services[0].deployments[].{status:status,rollout:rolloutState,running:runningCount,taskDef:taskDefinition}'
aws ecs update-service --cluster <ECS_CLUSTER> --service <ECS_SERVICE> --force-new-deployment
aws ecs execute-command --cluster <ECS_CLUSTER> --task <TASK_ID> --container app --interactive --command "/bin/sh"
```

#### Fargate
- **إيه هو:** compute serverless للـ containers (ECS/EKS): بتدفع لكل vCPU/GB-ساعة للـ task، من غير ما تدير EC2. Fargate Spot أرخص لحد ~70% بس ممكن يتسحب.
- **في المعمل:** 50–58 (و 56 للـ Spot).
- **البدائل:** ECS على EC2 capacity providers (أرخص عند الـ utilization العالي).
```bash
aws ecs describe-clusters --clusters <ECS_CLUSTER> --include ATTACHMENTS --query 'clusters[0].capacityProviders'
aws ecs list-tasks --cluster <ECS_CLUSTER> --launch-type FARGATE
aws ecs describe-tasks --cluster <ECS_CLUSTER> --tasks <TASK_ID> --query 'tasks[0].{cpu:cpu,mem:memory,stopped:stoppedReason}'
```

#### EKS
- **إيه هو:** Kubernetes managed (الـ control plane عليهم ~$0.10/ساعة ≈ $73/شهر + الـ nodes).
- **في المعمل:** 61–6A. أغلى ستاك في المعمل — **اعمل destroy في نفس اليوم**.
- **البدائل:** kind محلي (60)، ECS.
```bash
aws eks list-clusters
aws eks update-kubeconfig --name <EKS_CLUSTER> --region us-east-1
aws eks describe-cluster --name <EKS_CLUSTER> --query 'cluster.{version:version,status:status,endpoint:endpoint}'
aws eks list-addons --cluster-name <EKS_CLUSTER>
```

### Data & Registry

#### RDS (MySQL)
- **إيه هو:** MySQL managed: backups تلقائية + PITR، Multi-AZ failover، patching. في المعمل `db.t4g.micro`، engine `8.4`.
- **في المعمل:** 41، 50، 60، 77.
- **البدائل:** MySQL container على EC2 (20–27)، Aurora MySQL.
```bash
aws rds describe-db-instances --query 'DBInstances[].{id:DBInstanceIdentifier,status:DBInstanceStatus,endpoint:Endpoint.Address,multiAz:MultiAZ}'
aws rds create-db-snapshot --db-instance-identifier <DB_ID> --db-snapshot-identifier student-app-lab-manual-1
aws rds reboot-db-instance --db-instance-identifier <DB_ID> --force-failover   # Multi-AZ بس
```

#### ElastiCache (Redis / Valkey)
- **إيه هو:** Redis-compatible managed (و Valkey engine أرخص). بنستخدمه للـ sessions والـ cache بدل الـ database driver.
- **في المعمل:** 49.
- **البدائل:** Redis container، DynamoDB للـ sessions.
```bash
aws elasticache describe-cache-clusters --show-cache-node-info --query 'CacheClusters[].{id:CacheClusterId,engine:Engine,status:CacheClusterStatus}'
aws elasticache describe-replication-groups --query 'ReplicationGroups[].{id:ReplicationGroupId,primary:NodeGroups[0].PrimaryEndpoint.Address}'
```

#### S3
- **إيه هو:** object storage: backups الـ MySQL، state بتاع Terraform (`student-app-tfstate-<account_id>`)، logs.
- **في المعمل:** 02 (state bucket)، 27 (backups)، 77.
- **البدائل:** EFS، أي S3-compatible (MinIO).
```bash
aws s3 ls s3://student-app-tfstate-<ACCOUNT_ID>/stacks/ --recursive
aws s3 cp backup.sql.gz s3://<BACKUP_BUCKET>/mysql/ --sse AES256
aws s3api get-bucket-versioning --bucket student-app-tfstate-<ACCOUNT_ID>
aws s3 rb s3://<BUCKET> --force     # ⚠️ بيمسح كل حاجة
```

#### ECR
- **إيه هو:** Docker registry private. في المعمل: repo `student-app`، **IMMUTABLE tags** (git SHA)، scan on push، lifecycle policy. تقريباً $0.10/GB/شهر.
- **في المعمل:** 30، 32، 42–58، 6x.
- **البدائل:** GHCR (`PUSH_GHCR=true` في `ci.yml`)، Docker Hub.
```bash
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com
aws ecr describe-images --repository-name student-app --query 'sort_by(imageDetails,&imagePushedAt)[-5:].{tags:imageTags,pushed:imagePushedAt}'
aws ecr describe-image-scan-findings --repository-name student-app --image-id imageTag=<SHA7> --query 'imageScanFindings.findingSeverityCounts'
```

### Config & Secrets

#### SSM (Session Manager · Run Command · Parameter Store)
- **إيه هو:** ثلاث حاجات بنستخدمها كتير:
  - **Session Manager:** shell على الـ instance **من غير بورت 22 ولا SSH keys**، ومتسجّل في CloudTrail.
  - **Run Command:** تشغيل أمر على instances (الـ CD في 32 بيستخدم `AWS-RunShellScript`).
  - **Parameter Store:** مصدر الحقيقة للـ config والـ secrets (`/student-app/<env>/app/<KEY>`). الـ Standard tier مجاني.
- **في المعمل:** 20، 32، 41، 42، 64، 81.
- **البدائل:** SSH + bastion، Ansible، HashiCorp Vault.
```bash
aws ssm start-session --target <INSTANCE_ID>
aws ssm send-command --document-name AWS-RunShellScript --targets Key=instanceids,Values=<INSTANCE_ID> \
  --parameters 'commands=["docker ps"]' --query Command.CommandId --output text
aws ssm get-command-invocation --command-id <COMMAND_ID> --instance-id <INSTANCE_ID> --query StandardOutputContent --output text
aws ssm put-parameter --name /student-app/lab/app/APP_DEBUG --type String --value false --overwrite
aws ssm get-parameters-by-path --path /student-app/lab/app/ --recursive --with-decryption --query 'Parameters[].Name'
```

#### Secrets Manager
- **إيه هو:** secrets مع **rotation** تلقائية (Lambda) وcross-account. ~$0.40/secret/شهر.
- **في المعمل:** 81 (الـ RDS master password)، مقارنة بـ Parameter Store.
- **البدائل:** SSM SecureString (أرخص، من غير rotation built-in)، Vault.
```bash
aws secretsmanager list-secrets --query 'SecretList[].Name'
aws secretsmanager get-secret-value --secret-id <SECRET_ARN> --query SecretString --output text
aws secretsmanager rotate-secret --secret-id <SECRET_ARN>
```

#### KMS
- **إيه هو:** مفاتيح التشفير ورا SecureString وEBS وS3 وRDS. الـ AWS managed keys (`alias/aws/ssm`) مجانية؛ الـ customer managed key ~$1/شهر وبتديك تحكم في الـ key policy.
- **في المعمل:** 20 (SecureString)، 81.
- **البدائل:** CloudHSM (غالي جداً).
```bash
aws kms list-aliases --query "Aliases[?starts_with(AliasName,'alias/aws/')].AliasName"
aws kms describe-key --key-id alias/aws/ssm --query 'KeyMetadata.{manager:KeyManager,state:KeyState}'
```

### Observability

#### CloudWatch (Logs · Metrics · Alarms · Dashboards · Container Insights)
- **إيه هو:** الـ observability الافتراضية في AWS. **Logs** (التطبيق بيكتب JSON على stderr → Logs Insights)، **Metrics** (ALB/EC2/ECS/RDS)، **Alarms** (→ SNS / rollback)، **Dashboards**، و**Container Insights** لـ ECS/EKS.
- **في المعمل:** 42، 46 (alarm rollback)، 53، 70–73. الـ logs تقريباً $0.50/GB ingestion.
- **البدائل:** Prometheus + Grafana + Loki (نفس المعمل)، Datadog.
```bash
aws logs tail /student-app/lab/app --follow --since 10m
aws logs start-query --log-group-name /student-app/lab/app --start-time $(date -d '-1 hour' +%s) --end-time $(date +%s) \
  --query-string 'fields @timestamp, level_name, message | filter level_name = "ERROR" | sort @timestamp desc | limit 20'
aws cloudwatch describe-alarms --state-value ALARM --query 'MetricAlarms[].AlarmName'
aws cloudwatch set-alarm-state --alarm-name <ALARM_NAME> --state-value ALARM --state-reason "drill"
```

#### X-Ray
- **إيه هو:** distributed tracing بتاع AWS. AWS بقت بتوجّه لـ **OpenTelemetry (ADOT)** كـ instrumentation بدل الـ X-Ray SDKs، والـ backend لسه X-Ray / CloudWatch.
- **في المعمل:** 72 (مقارنة مع OTel + Tempo/Jaeger).
- **البدائل:** Jaeger، Grafana Tempo، Datadog APM.
```bash
aws xray get-trace-summaries --start-time $(date -d '-15 min' +%s) --end-time $(date +%s) --query 'TraceSummaries[].{id:Id,duration:Duration}'
aws xray get-service-graph --start-time $(date -d '-15 min' +%s) --end-time $(date +%s)
```

#### SNS
- **إيه هو:** pub/sub: الـ alarms بتبعت لـ topic → email/Slack (عن طريق Chatbot/Lambda)/PagerDuty.
- **في المعمل:** 42، 46، 73.
- **البدائل:** Alertmanager receivers، EventBridge.
```bash
aws sns create-topic --name student-app-lab-alerts
aws sns subscribe --topic-arn <TOPIC_ARN> --protocol email --notification-endpoint <YOUR_EMAIL>
aws sns publish --topic-arn <TOPIC_ARN> --subject "drill" --message "test alert"
```

### Delivery (AWS CI/CD)

#### CodeBuild
- **إيه هو:** build containers managed بـ `buildspec.yml`، بالدقيقة. ممكن كمان يشغّل **GitHub Actions self-hosted runners** managed.
- **في المعمل:** 35، 36.
- **البدائل:** GitHub Actions (الأساسي عندنا)، Jenkins.
```bash
aws codebuild list-projects
aws codebuild start-build --project-name <PROJECT_NAME>
aws codebuild batch-get-builds --ids <BUILD_ID> --query 'builds[0].{status:buildStatus,phase:currentPhase}'
```

#### CodePipeline
- **إيه هو:** orchestration: Source (CodeConnections) → Build (CodeBuild) → Deploy (ECS / CodeDeploy). الـ V2 بيتحاسب بالدقيقة لكل action execution (راجع صفحة الأسعار).
- **في المعمل:** 36، 37، 58.
- **البدائل:** GitHub Actions environments (34).
```bash
aws codepipeline list-pipelines
aws codepipeline start-pipeline-execution --name <PIPELINE_NAME>
aws codepipeline get-pipeline-state --name <PIPELINE_NAME> --query 'stageStates[].{stage:stageName,status:latestExecution.status}'
```

#### CodeDeploy
- **إيه هو:** deployments لـ EC2/ASG (`appspec.yml` + hooks) و ECS (blue/green + canary/linear بـ alarms + auto-rollback). مجاني لـ EC2/ECS.
- **في المعمل:** 37، 54.
- **البدائل:** ECS native blue/green (55)، Argo Rollouts (68).
```bash
aws deploy list-applications
aws deploy get-deployment --deployment-id <DEPLOYMENT_ID> --query 'deploymentInfo.{status:status,overview:deploymentOverview}'
aws deploy stop-deployment --deployment-id <DEPLOYMENT_ID> --auto-rollback-enabled
```

#### CodeConnections
- **إيه هو:** الربط بين AWS و GitHub (كان اسمه CodeStar Connections). الـ connection بتتعمل بحالة `PENDING` ولازم تكمّل الـ handshake من الـ Console مرة واحدة.
- **في المعمل:** bootstrap، 36.
- **البدائل:** GitHub webhook + token (قديم).
```bash
aws codeconnections list-connections --query 'Connections[].{name:ConnectionName,status:ConnectionStatus}'
aws codeconnections get-connection --connection-arn <CONNECTION_ARN>
```

### Resilience & Cost

#### FIS (Fault Injection Service)
- **إيه هو:** chaos engineering managed: experiment templates (stop instances، CPU stress عن طريق SSM، network latency، AZ failure) مع **stop conditions** مربوطة بـ alarms.
- **في المعمل:** 75. بيتحاسب بالدقيقة لكل action.
- **البدائل:** Chaos Mesh / Litmus على K8s، الـ `SRE_FAULT_*` في التطبيق نفسه.
```bash
aws fis list-experiment-templates --query 'experimentTemplates[].{id:id,desc:description}'
aws fis start-experiment --experiment-template-id <TEMPLATE_ID>
aws fis stop-experiment --id <EXPERIMENT_ID>
```

#### Budgets / Cost Explorer
- **إيه هو:** **Budgets** = تنبيه لما الصرف يعدّي حد (اعمله يوم 1). **Cost Explorer** = تحليل الصرف بالخدمة/الـ tag (فعّل `Project` و `Scenario` كـ cost allocation tags).
- **في المعمل:** 02، 97.
- **البدائل:** Infracost (قبل الـ apply)، CUR + Athena.
```bash
aws budgets describe-budgets --account-id <ACCOUNT_ID> --query 'Budgets[].{name:BudgetName,limit:BudgetLimit.Amount}'
aws ce get-cost-and-usage --time-period Start=<YYYY-MM-01>,End=<YYYY-MM-DD> --granularity DAILY \
  --metrics UnblendedCost --group-by Type=DIMENSION,Key=SERVICE
```
> كل call لـ Cost Explorer API بيتحاسب (~$0.01). استخدم الـ Console للتصفح.

## 5) الطريقة التانية: Infrastructure as Code — كروت أدوات الـ IaC

#### Terraform
- **إيه هو:** IaC declarative: بتوصف الـ resources في HCL، وهو بيحسب الفرق (`plan`) وينفّذه (`apply`)، والـ state في S3 بـ native locking (`use_lockfile = true`، Terraform `>= 1.10`).
- **في المعمل:** `infra/terraform/` (bootstrap + modules + stacks)، كل السيناريوهات الـ ✅ IaC، و 90–92.
- **البدائل:** OpenTofu (fork مفتوح متوافق)، CloudFormation/CDK، Pulumi.
```bash
cd infra/terraform/stacks/20-ec2-single
terraform init -backend-config=../../backend.hcl
terraform fmt -recursive && terraform validate
terraform plan -out tfplan && terraform apply tfplan
terraform state list
terraform destroy
```

#### Ansible
- **إيه هو:** configuration management agentless (SSH أو **SSM**) بـ YAML playbooks وroles؛ dynamic inventory من الـ tags (`amazon.aws.aws_ec2`).
- **في المعمل:** `infra/ansible/`، 21، 33، 47، 93.
- **البدائل:** user-data/cloud-init، Chef/Puppet، SSM State Manager.
```bash
cd infra/ansible
ansible-galaxy collection install -r requirements.yml
ansible-inventory -i inventories/lab/aws_ec2.yml --graph
ansible role_app -i inventories/lab/aws_ec2.yml -m ping
ansible-playbook -i inventories/lab/aws_ec2.yml playbooks/<PLAYBOOK>.yml --check --diff
```

#### Packer
- **إيه هو:** بيبني machine images (AMI) من template (HCL) + provisioners (Ansible) → **Golden AMI** (immutable infrastructure).
- **في المعمل:** `infra/packer/`، 43.
- **البدائل:** EC2 Image Builder.
```bash
cd infra/packer
packer init .
packer fmt -check .
packer validate .
packer build .
```

#### tflint · checkov · Infracost
- **tflint:** linter لـ Terraform (أخطاء provider-specific زي instance type غلط). **checkov:** policy-as-code security scan (S3 public، SG مفتوح...). **Infracost:** تكلفة الـ plan قبل الـ apply (وعلى الـ PR في 92).
- **في المعمل:** [`lint-infra.yml`](../../../.github/workflows/lint-infra.yml)، 82، 92.
- **البدائل:** trivy config (بديل checkov)، OPA/Conftest.
```bash
tflint --init --chdir=infra/terraform && tflint --recursive --chdir=infra/terraform --minimum-failure-severity=error
checkov -d infra/terraform --framework terraform --quiet --soft-fail
infracost auth login
infracost breakdown --path infra/terraform/stacks/40-ec2-alb-asg
```

#### ansible-lint
- **إيه هو:** linter للـ playbooks/roles (best practices، idempotency، FQCN).
- **في المعمل:** `lint-infra.yml` (job `ansible`)، 93.
```bash
cd infra/ansible && ansible-lint --profile=production
ansible-playbook --syntax-check -i inventories/lab/hosts.ini.example playbooks/<PLAYBOOK>.yml
```

## 6) الـ Deploy — كروت البناء والتشغيل

### Source & CI

#### Git / GitHub
- **إيه هو:** الـ version control والـ hosting. في المعمل **الـ git short SHA هو الـ image tag** (immutable، ممنوع `latest`).
- **في المعمل:** كله. الشغل على branch `devops-lab`.
- **البدائل:** GitLab، Bitbucket، AWS CodeCommit (اتقفل لعملاء جداد).
```bash
git switch devops-lab
git log --oneline --graph -15
git rev-parse --short HEAD          # = APP_VERSION = image tag
gh pr create --base master --head devops-lab --fill
gh pr checks
```

#### GitHub Actions
- **إيه هو:** CI/CD جوه GitHub: workflows YAML في `.github/workflows/`، jobs على runners، و**OIDC** للدخول على AWS من غير keys.
- **في المعمل:** [`ci.yml`](../../../.github/workflows/ci.yml) (30)، [`lab-integration.yml`](../../../.github/workflows/lab-integration.yml) (المعمل المحلي على runners)، [`lint-infra.yml`](../../../.github/workflows/lint-infra.yml)، 31–34، 58.
- **البدائل:** GitLab CI، CodeBuild/CodePipeline، Jenkins.
```bash
gh workflow list
gh workflow run lab-integration.yml --ref devops-lab
gh run list --workflow=lab-integration.yml --limit 5
gh run watch
gh run view --log-failed
```

#### Dependabot
- **إيه هو:** PRs تلقائية لتحديث الـ dependencies. عندنا في [`.github/dependabot.yml`](../../../.github/dependabot.yml): composer، npm، github-actions، docker (`/docker`)، terraform — أسبوعي ومجمّع (groups).
- **في المعمل:** 11، 82.
- **البدائل:** Renovate (أمرن، بيفهم `ARG` في الـ Dockerfile و regex managers).
```bash
gh pr list --author "app/dependabot"
gh pr merge <PR_NUMBER> --squash --auto      # بعد ما CI و lab-integration يعدّوا
```
> أوامر الـ bot بتتكتب كـ comment على الـ PR: `@dependabot rebase` أو `@dependabot recreate`.

### Containers

#### Docker
- **إيه هو:** بناء وتشغيل الـ containers. الـ image بتاعتنا multi-stage: `vendor` → `assets` → `runtime` ([`docker/Dockerfile`](../../../docker/Dockerfile)).
- **في المعمل:** [10](10-containerize-app.md)، [11](11-image-hardening.md)، 20–27.
- **البدائل:** Podman (daemonless، rootless)، nerdctl/containerd.
```bash
docker build -f docker/Dockerfile --build-arg APP_VERSION=$(git rev-parse --short HEAD) -t student-app:local .
docker images student-app
docker history student-app:local
docker inspect --format '{{.Config.User}} {{.Config.StopSignal}} {{json .Config.ExposedPorts}}' student-app:local
docker logs -f <CONTAINER>
docker exec -it <CONTAINER> sh
```

#### Docker Compose
- **إيه هو:** تعريف multi-container stack في YAML. عندنا 3 ملفات: [`docker-compose.yml`](../../../docker-compose.yml) (local/CI)، [`docker-compose.prod.yml`](../../../docker-compose.prod.yml) (EC2 Recreate)، [`deploy/ec2/lb/docker-compose.yml`](../../../deploy/ec2/lb/docker-compose.yml) (zero-downtime). كلهم project name `student-app`.
- **في المعمل:** 10، 12، 20–27.
- **البدائل:** Kubernetes (60+)، ECS task definitions.
```bash
export APP_KEY=base64:$(openssl rand -base64 32)
docker compose up -d --build --wait
docker compose ps
docker compose logs -f app
docker compose run --rm app php artisan migrate --force
docker compose down          # ⚠️ ضيف -v بس لو عايز تمسح الداتابيز
```

#### BuildKit / buildx
- **إيه هو:** الـ build engine الحديث: multi-stage بالتوازي، cache mounts، cache export (`type=gha`)، و**multi-arch** (`linux/amd64,linux/arm64`) لـ Graviton.
- **في المعمل:** 11، 30 (`docker/build-push-action` + `cache-from: type=gha`).
- **البدائل:** kaniko (من غير daemon)، buildah.
```bash
docker buildx create --name lab --use
docker buildx build --platform linux/amd64,linux/arm64 -f docker/Dockerfile -t <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/student-app:<SHA7> --push .
docker buildx imagetools inspect <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/student-app:<SHA7>
docker buildx du
```

#### nginx
- **إيه هو:** web server / reverse proxy. عندنا في مكانين: **جوه الـ image** (serversideup بيخدم PHP-FPM على 8080)، و**قدام الـ slots** في [`deploy/ec2/lb/nginx/nginx.conf`](../../../deploy/ec2/lb/nginx/nginx.conf) (weights، `split_clients`، `mirror`، graceful reload).
- **في المعمل:** 10، 23–26.
- **البدائل:** HAProxy، Envoy، Traefik، ALB. (ملحوظة: الـ ingress-nginx controller بتاع Kubernetes اتعمله retirement — احنا بنستخدم AWS LBC على EKS.)
```bash
LBSTACK="docker compose -f deploy/ec2/lb/docker-compose.yml --env-file deploy/ec2/lb/state/release.env"
$LBSTACK exec -T proxy nginx -t
$LBSTACK exec -T proxy nginx -T | less          # الـ config الكاملة بعد الـ includes
$LBSTACK exec -T proxy nginx -s reload          # graceful: الـ workers القديمة بتخلّص الـ requests
$LBSTACK logs -f proxy
```

#### PHP-FPM + S6 (serversideup/php)
- **إيه هو:** base image `serversideup/php:8.3-fpm-nginx-alpine-v5.0.5`: nginx + PHP-FPM جوه container واحد، و**S6 Overlay** هو PID 1 اللي بيشغّلهم ويراقبهم. non-root (`www-data` UID 82)، بورت 8080، `STOPSIGNAL SIGQUIT` (graceful لـ FPM)، وسكريبتات `/etc/entrypoint.d/` (منها `AUTORUN_*` و `2-sre-boot-fault.sh` بتاعنا).
- **في المعمل:** 10، 11.
- **البدائل:** `php:8.3-fpm` الرسمي + nginx container منفصل، FrankenPHP، Laravel Octane.
```bash
docker compose exec app php -v
docker compose exec app php -m | grep -i apcu
docker compose exec app php artisan about --only=environment
docker compose exec app id                 # uid=82(www-data)
docker inspect --format '{{.Config.StopSignal}}' student-app:local
```

#### MySQL
- **إيه هو:** الداتابيز (`mysql:8.4`، utf8mb4). container في 10 و 20–27، و RDS من 41.
- **في المعمل:** 10، 20–27، 41، 95.
- **البدائل:** Aurora MySQL، PostgreSQL.
```bash
docker compose exec mysql mysql -ustudent -pstudent-secret student_app -e "SHOW TABLES;"
docker compose exec mysql sh -c 'mysqladmin ping -uroot -p"$MYSQL_ROOT_PASSWORD"'
docker compose exec mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SHOW FULL PROCESSLIST;"'
docker compose exec -T mysql sh -c 'mysqldump --single-transaction -uroot -p"$MYSQL_ROOT_PASSWORD" student_app' | gzip > backup.sql.gz
```

#### Redis
- **إيه هو:** in-memory store للـ sessions والـ cache والـ locks (بيحل مشكلة `migrate --isolated` مع database cache — شوف [CONVENTIONS §2](../CONVENTIONS.md)).
- **في المعمل:** profile `redis` في compose، 49 (ElastiCache).
- **البدائل:** Valkey، Memcached (cache بس).
```bash
docker compose --profile redis up -d redis
LAB_SESSION_DRIVER=redis LAB_CACHE_STORE=redis docker compose up -d --wait app
docker compose exec redis redis-cli ping
docker compose exec redis redis-cli INFO keyspace
```

### Kubernetes

#### Kubernetes
- **إيه هو:** container orchestrator: Deployments، Services، Ingress، probes (`/up` liveness، `/ready` readiness)، HPA، PDB. namespace المعمل `student-app`.
- **في المعمل:** `k8s/`، 60–6A.
- **البدائل:** ECS، Nomad.
```bash
kubectl get deploy,po,svc,ing -n student-app
kubectl describe pod <POD> -n student-app
kubectl rollout status deploy/student-app -n student-app
kubectl rollout undo deploy/student-app -n student-app
```

#### kubectl
- **إيه هو:** الـ CLI بتاع Kubernetes (و Kustomize مدمج فيه `-k`).
- **في المعمل:** 60–6A.
- **البدائل:** k9s (TUI)، Lens.
```bash
kubectl config get-contexts
kubectl logs -f deploy/student-app -n student-app
kubectl exec -it deploy/student-app -n student-app -- php artisan about
kubectl port-forward svc/student-app 8080:80 -n student-app
kubectl get events -n student-app --sort-by=.lastTimestamp
```

#### kind
- **إيه هو:** Kubernetes جوه Docker containers — cluster محلي في دقيقة، أو على GitHub Actions (`k8s-integration.yml`).
- **في المعمل:** 60.
- **البدائل:** minikube، k3d.
```bash
kind create cluster --name student-app
kind load docker-image student-app:local --name student-app
kind get clusters
kind delete cluster --name student-app
```

#### eksctl
- **إيه هو:** CLI بيعمل EKS cluster كامل (CloudFormation تحت الغطا) من أمر أو YAML.
- **في المعمل:** 61 (والـ IaC الحقيقي في 62 بـ Terraform).
- **البدائل:** Terraform EKS module، الـ Console.
```bash
eksctl get cluster --region us-east-1
eksctl get nodegroup --cluster <EKS_CLUSTER>
eksctl utils write-kubeconfig --cluster <EKS_CLUSTER>
eksctl delete cluster --name <EKS_CLUSTER> --wait
```

#### Helm
- **إيه هو:** package manager لـ K8s: chart بـ templates + values، و releases بـ history (rollback). عندنا chart في `k8s/helm/student-app` فيه migrate hook Job.
- **في المعمل:** 65–69.
- **البدائل:** Kustomize، cdk8s.
```bash
helm lint k8s/helm/student-app
helm template lab k8s/helm/student-app -f k8s/helm/student-app/values.yaml | less
helm upgrade --install lab k8s/helm/student-app -n student-app --create-namespace --wait
helm history lab -n student-app
helm rollback lab <REVISION> -n student-app
```

#### Kustomize
- **إيه هو:** overlays فوق YAML عادي من غير templates (base + patches لكل environment).
- **في المعمل:** الـ plain manifests في `k8s/` (60، 66–67).
- **البدائل:** Helm.
```bash
kubectl kustomize k8s/<OVERLAY_DIR>
kubectl apply -k k8s/<OVERLAY_DIR>
kubectl diff -k k8s/<OVERLAY_DIR>
```

#### Argo CD
- **إيه هو:** **GitOps**: الـ cluster بيسحب الحالة المطلوبة من Git ويصلّح أي drift (sync، self-heal، prune).
- **في المعمل:** 69.
- **البدائل:** Flux.
```bash
argocd app list
argocd app diff student-app
argocd app sync student-app
argocd app history student-app
argocd app rollback student-app <HISTORY_ID>
```

#### Argo Rollouts
- **إيه هو:** بديل للـ Deployment بيعمل canary/blue-green بخطوات + **AnalysisTemplate** (Prometheus query → promote أو abort تلقائي).
- **في المعمل:** 68 (نفس فكرة [`canary.sh`](../../../deploy/ec2/lb/bin/canary.sh) بس على K8s).
- **البدائل:** Flagger، CodeDeploy، ECS native canary.
```bash
kubectl argo rollouts get rollout student-app -n student-app --watch
kubectl argo rollouts promote student-app -n student-app
kubectl argo rollouts abort student-app -n student-app
kubectl argo rollouts undo student-app -n student-app
```

#### Karpenter
- **إيه هو:** node autoscaler لـ EKS: بيشوف الـ pods الـ Pending ويعمل الـ node المناسب (Spot/On-Demand، Graviton) في ثواني، وبيعمل consolidation.
- **في المعمل:** 6A.
- **البدائل:** Cluster Autoscaler، EKS Auto Mode.
```bash
kubectl get nodepools,ec2nodeclasses
kubectl get nodeclaims -o wide
kubectl get pods -A -l app.kubernetes.io/name=karpenter
```

#### AWS Load Balancer Controller (LBC)
- **إيه هو:** controller بيحوّل `Ingress`/`Service` لـ ALB/NLB حقيقي (target type `ip` للـ pods مباشرة).
- **في المعمل:** 63.
- **البدائل:** NGINX Gateway Fabric / Gateway API implementations.
```bash
kubectl get ingress -n student-app
kubectl get targetgroupbindings -A
kubectl logs -n kube-system deploy/aws-load-balancer-controller --tail=50
```

#### External Secrets Operator (ESO)
- **إيه هو:** بيقرا من SSM Parameter Store / Secrets Manager ويعمل Kubernetes Secret (`student-app-secrets`) ويحدّثه.
- **في المعمل:** 64.
- **البدائل:** Secrets Store CSI Driver، Sealed Secrets.
```bash
kubectl get clustersecretstore
kubectl get externalsecret -n student-app
kubectl describe externalsecret <NAME> -n student-app
kubectl get secret student-app-secrets -n student-app -o jsonpath='{.data}' | jq 'keys'
```

#### metrics-server / HPA
- **إيه هو:** metrics-server بيجمع CPU/memory من الـ kubelets؛ الـ HPA بيعمل scale للـ pods على أساسها (أو custom metrics).
- **في المعمل:** 6A (مع `/sre-lab/cpu` كـ load).
- **البدائل:** KEDA (event-driven scaling).
```bash
kubectl top nodes
kubectl top pods -n student-app
kubectl get hpa -n student-app -w
```

## 7) التحقق (Verify) — كروت الـ Observability والـ Load testing

#### Prometheus
- **إيه هو:** time-series DB بيعمل **scrape** لـ `/metrics`. التطبيق بيطلّع `student_app_http_requests_total{method,route,status}` و `student_app_http_request_duration_seconds_bucket` و `student_app_app_info{version,color}` (counters في APCu مشتركة بين الـ FPM workers).
- **في المعمل:** `observability/`، 12، 71، 73.
- **البدائل:** Amazon Managed Prometheus، VictoriaMetrics، CloudWatch.
```bash
curl -s http://localhost:8080/metrics | grep '^student_app_http_requests_total' | head
curl -s 'http://localhost:9090/api/v1/query' --data-urlencode 'query=sum(rate(student_app_http_requests_total{status=~"5.."}[5m]))'
promtool check rules <RULES_FILE>.yml
```

#### Alertmanager
- **إيه هو:** بياخد الـ alerts من Prometheus ويعمل grouping/dedup/silences/routing (Slack، email، PagerDuty). الـ burn-rate alerts (14.4× و 6× → page).
- **في المعمل:** 73، 76.
- **البدائل:** Grafana Alerting، CloudWatch Alarms + SNS.
```bash
amtool check-config <ALERTMANAGER_CONFIG>.yml
amtool --alertmanager.url=http://localhost:9093 alert query
amtool --alertmanager.url=http://localhost:9093 silence add alertname=<ALERT> --duration=1h --comment="deploy"
```

#### Grafana
- **إيه هو:** dashboards فوق Prometheus/Loki/CloudWatch/Tempo، بـ provisioning as code.
- **في المعمل:** 12، 71، 73.
- **البدائل:** Amazon Managed Grafana، CloudWatch Dashboards.
```bash
curl -s http://localhost:3000/api/health
curl -s -u admin:<GRAFANA_PASSWORD> http://localhost:3000/api/search?type=dash-db | jq '.[].title'
```

#### Loki
- **إيه هو:** logs aggregation بيعمل index للـ labels بس (رخيص)، وبتسأله بـ LogQL. لوجات التطبيق JSON فـ `| json` بيفكّها.
- **في المعمل:** 70.
- **البدائل:** CloudWatch Logs Insights، Elasticsearch/OpenSearch.
```bash
logcli query '{compose_service="app"} | json | level_name="ERROR"' --since=1h --limit=20
logcli labels
```

#### Grafana Alloy
- **إيه هو:** الـ collector بتاع Grafana (OTel-compatible): بيجمع logs/metrics/traces ويبعتهم لـ Loki/Prometheus/Tempo. بيحل محل Grafana Agent و Promtail (اللي اتعملهم deprecate).
- **في المعمل:** 70، 71.
- **البدائل:** OpenTelemetry Collector، Fluent Bit، Vector.
```bash
alloy fmt <CONFIG>.alloy
curl -s http://localhost:12345/-/ready      # الـ UI بتاع Alloy على 12345
```

#### OpenTelemetry
- **إيه هو:** المعيار المفتوح للـ traces/metrics/logs: SDK في التطبيق + **Collector** (receivers → processors → exporters). AWS عندها توزيعة ADOT.
- **في المعمل:** 72.
- **البدائل:** X-Ray SDK، vendor agents (Datadog/New Relic).
```bash
export OTEL_SERVICE_NAME=student-app
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
otelcol-contrib validate --config=<COLLECTOR_CONFIG>.yaml
```

#### k6
- **إيه هو:** load testing بـ JavaScript؛ **الـ thresholds هي الـ SLOs** (`http_req_failed: rate<0.005`، `p(95)<${P95_MS:-500}`) والـ exit code ≠ 0 لو اتكسرت.
- **في المعمل:** `loadtest/k6/`، 12، 48، 57، 6A، 74، و `lab-integration.yml`.
- **البدائل:** Locust، JMeter، Gatling، Distributed Load Testing on AWS.
```bash
k6 run -e BASE_URL=http://localhost:8080 -e LOADTEST_USERS=5 loadtest/k6/smoke.js
k6 run -e BASE_URL=http://<HOST> -e VUS=20 -e DURATION=5m loadtest/k6/load.js
k6 run --out json=loadtest/results/load.json loadtest/k6/load.js
```

## 8) اكسرها (Break it) — كروت أدوات الأمان والـ Linting

> الأدوات دي وظيفتها **تكسر الـ build قبل ما الـ production يتكسر**. في المعمل أغلبها report-only الأول، وفي 82 بنحولها لـ gates.

#### Trivy
- **إيه هو:** scanner للـ vulnerabilities (OS packages + composer/npm)، misconfig (Terraform/Dockerfile/K8s)، وsecrets. في `ci.yml` بنستخدم `aquasecurity/trivy-action@0.36.0` — الـ tags القديمة اتعملها hijack في مارس 2026 (شوف [11](11-image-hardening.md)).
- **في المعمل:** 11، 30، 82.
- **البدائل:** Grype، Docker Scout، ECR scanning (Inspector).
```bash
trivy image --severity HIGH,CRITICAL --ignore-unfixed student-app:local
trivy fs --scanners vuln,secret .
trivy config infra/terraform
trivy image --format cyclonedx --output sbom.cdx.json student-app:local
```

#### Syft / SBOM
- **إيه هو:** Syft بيطلّع **SBOM** (قايمة بكل package جوه الـ image) بصيغة SPDX أو CycloneDX. `anchore/sbom-action` في `ci.yml` بيرفعه كـ artifact.
- **في المعمل:** 11، 30، 82.
- **البدائل:** `trivy --format spdx-json`، `docker buildx build --sbom=true` (attestation).
```bash
syft student-app:local -o spdx-json > sbom.spdx.json
grype sbom:./sbom.spdx.json --only-fixed
jq '.packages | length' sbom.spdx.json
```

#### cosign
- **إيه هو:** توقيع الـ images (Sigstore). **keyless** في GitHub Actions: الـ OIDC token بيتحول لـ certificate قصير العمر، والتوقيع متسجل في Rekor transparency log.
- **في المعمل:** 11، 82.
- **البدائل:** Notation (Notary v2) + AWS Signer.
```bash
cosign sign --yes <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/student-app@sha256:<DIGEST>
cosign verify <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/student-app@sha256:<DIGEST> \
  --certificate-identity-regexp '^https://github.com/Ahmed-Reda-Ragab/StudentHub/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
cosign tree <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/student-app@sha256:<DIGEST>
```

#### hadolint
- **إيه هو:** linter للـ Dockerfile (+ ShellCheck على الـ `RUN`). في `ci.yml` بـ `failure-threshold: error`.
- **في المعمل:** 11، 30.
```bash
docker run --rm -i hadolint/hadolint < docker/Dockerfile
hadolint --failure-threshold error docker/Dockerfile
```

#### ShellCheck
- **إيه هو:** static analysis لـ bash/sh: quoting، `set -e` traps، globbing. `lint-infra.yml` بيشغّله على كل `*.sh` في الـ repo.
- **في المعمل:** كل سكريبتات `deploy/`.
```bash
shellcheck -x -S warning deploy/ec2/lb/bin/*.sh deploy/scripts/*.sh deploy/ec2/*.sh
git ls-files '*.sh' | xargs shellcheck -x -S warning
```

#### actionlint
- **إيه هو:** linter للـ GitHub Actions workflows (expressions، `needs`، shellcheck جوه `run:`).
- **في المعمل:** `lint-infra.yml`.
```bash
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:1.7.7 -color
```

#### kubeconform
- **إيه هو:** validation للـ manifests ضد الـ Kubernetes JSON schemas (+ CRDs catalog) من غير cluster.
- **في المعمل:** `lint-infra.yml` (job `kubernetes`)، 65.
```bash
helm template lab k8s/helm/student-app | kubeconform -strict -summary -ignore-missing-schemas
find k8s -name '*.yaml' -not -path 'k8s/helm/*' | xargs kubeconform -strict -summary -ignore-missing-schemas
```

## 9) الرجوع (Rollback): تثبيت النسخ ونقلها

الـ "rollback" في عالم الأدوات = **pinning**. أي أداة بتجري في CI لازم نسختها تكون ثابتة، والتحديث بيبقى PR (Dependabot) بيعدّي على CI:

| الحاجة | إزاي بنثبّتها | ملاحظة |
|---|---|---|
| Base images | `serversideup/php:8.3-fpm-nginx-alpine-v5.0.5`، `mysql:8.4`، `nginx:1.28-alpine` | الأحسن كمان `@sha256:<digest>` |
| GitHub Actions | tag (`@v6`) دلوقتي في الـ workflows | الأأمن **full commit SHA** (درس Trivy، 11) |
| Terraform | `>= 1.10` + provider `~> 6.0` + `.terraform.lock.hcl` | الـ lock file يتعمله commit |
| Composer/npm | `composer.lock` + `package-lock.json` (`npm ci`) | `.npmrc` فيه `ignore-scripts=true` |
| أدوات الجهاز | نسخة محددة في [03](03-workstation-setup.md) | `terraform version`، `kubectl version --client` |

## 10) المسح (Teardown) ⚠️

الملف ده مفيهوش موارد. بس اتعوّد من دلوقتي على أمر "فيه إيه شغال وبيتحاسب؟":

```bash
aws resourcegroupstaggingapi get-resources --tag-filters Key=Project,Values=student-app \
  --query 'ResourceTagMappingList[].ResourceARN' --output table
```

## 11) التكلفة (Cost)

| فئة | بتتحاسب إزاي (تقريبي، us-east-1 — راجع صفحة الأسعار) |
|---|---|
| أدوات open source (Terraform، Ansible، K8s tools، Prometheus...) | مجاني — بتدفع بس على الـ compute اللي شغّالة عليه |
| GitHub Actions | مجاني للـ public repos؛ الـ private عندها دقائق مجانية شهرية |
| EC2 / Fargate / EKS | بالساعة/الثانية — أكبر بند (EKS control plane لوحده ~$73/شهر) |
| ALB / NAT Gateway | بالساعة + traffic — الـ NAT (~$32/شهر) أكتر حاجة بتتنسي |
| Public IPv4 | ~$0.005/ساعة لكل IP (حتى الـ Elastic IP) |
| CloudWatch Logs | بالـ GB ingestion + storage |
| KMS CMK / Secrets Manager | ~$1 / ~$0.40 لكل مفتاح/secret شهرياً |

## 12) أسئلة Interview

<details><summary>إمتى تختار ECS بدل EKS لتطبيق زي ده؟</summary>

ECS أبسط تشغيلياً ومفيش control plane تدفع عليه أو تعمله upgrade كل كام شهر، ومتكامل مع ALB/IAM/CloudWatch من غير controllers إضافية. EKS بيكسب لما يكون عندك فريق بيعرف K8s، أو محتاج ecosystem (Argo، Karpenter، operators)، أو portability بين clouds. لتطبيق Laravel واحد بفريق صغير: ECS Fargate. لمنصة فيها عشرات الخدمات وفرق كتير: EKS.

</details>

<details><summary>Parameter Store ولا Secrets Manager؟</summary>

Parameter Store (SecureString) مجاني في الـ Standard tier وكفاية لأغلب الـ config والـ secrets الثابتة. Secrets Manager بيكسب لما تحتاج **rotation تلقائية** (RDS master password)، أو cross-account sharing، أو secrets أكبر من 4KB. في المعمل: Parameter Store مصدر الحقيقة، و Secrets Manager للـ RDS في 81.

</details>

<details><summary>Terraform ولا Ansible؟ ليه الاتنين؟</summary>

Terraform للـ **provisioning** (declarative، فيه state، بيعرف يعمل destroy). Ansible للـ **configuration** جوه السيرفر (packages، files، deploy steps) وهو procedural نسبياً ومن غير state. الحدود بتقل مع immutable infrastructure: لو بتبني Golden AMI بـ Packer أو بتشغّل containers على ECS، دور Ansible بيتقلص لـ AMI build أو بيختفي.

</details>

<details><summary>ليه OIDC بدل AWS access keys في GitHub Actions؟</summary>

الـ keys طويلة العمر بتتسرّب (logs، forks، laptops) ومحتاجة rotation يدوي. مع OIDC الـ job بياخد token قصير العمر من GitHub، وAWS بيتحقق من الـ claims (`aud`، و `sub` = repo + branch/environment) قبل `AssumeRoleWithWebIdentity`. يعني credentials بتعيش دقايق، ومربوطة بـ branch معين، ومفيش secret تتخزن أصلاً.

</details>

<details><summary>إيه الفرق بين liveness و readiness، وليه عندنا `/up` و `/ready`؟</summary>

liveness = "الـ process عايش؟" لو فشل الـ orchestrator بيعمل restart. readiness = "أقدر أستقبل traffic دلوقتي؟" لو فشل بيشيل الـ instance من الـ load balancer **من غير restart**. لو حطيت DB check في الـ liveness، وقعة الداتابيز هتعمل restart storm لكل الـ pods. عشان كده `/up` مبيلمسش الداتابيز و `/ready` بيعمل DB ping.

</details>

<details><summary>Prometheus ولا CloudWatch؟</summary>

CloudWatch جاهز ومتكامل مع خدمات AWS (ALB/RDS metrics، alarms → ASG/CodeDeploy rollback) ومن غير تشغيل. Prometheus أرخص على الـ high-cardinality custom metrics، PromQL أقوى للـ SLO math، وportable. عملياً الاتنين: CloudWatch للـ infra metrics والـ alarms اللي بتعمل actions، و Prometheus/Grafana للـ application SLOs.

</details>

<details><summary>إيه أهمية الـ SBOM والتوقيع لو عندي vulnerability scan أصلاً؟</summary>

الـ scan بيقولك "فيه ثغرات معروفة النهارده". الـ SBOM بيخليك تجاوب بكرة على "أنهي image في الـ production فيها library X؟" من غير ما تعيد scan لكل حاجة (Log4Shell-style incident). التوقيع (cosign) بيثبت إن الـ image اللي بيشتغل هو اللي الـ CI بتاعك بناه فعلاً، وممكن تفرضه بـ admission policy.

</details>

## 13) Checklist

- [ ] قريت كل الكروت وعارف كل أداة بتحل مشكلة إيه
- [ ] أقدر أشرح البديل لكل أداة وليه اخترنا اللي عندنا
- [ ] جرّبت أوامر الـ `aws` الـ read-only (بعد [02](02-aws-account-setup.md))
- [ ] جرّبت أوامر الـ `docker`/`compose` محلياً أو فهمت إزاي بتجري على GitHub Actions ([03](03-workstation-setup.md))
- [ ] عملت bookmark للملف ده كـ reference
