# 97 — التكلفة والمسح (Cost & Teardown)

> **الهدف في سطر:** تعرف كل stack بيكلّف كام في الساعة واليوم، فين المصايد اللي بتعمل فاتورة من غير ما تحس (NAT، EKS، ALB، RDS، IPv4، Logs…)، وتمسح كل حاجة **بالترتيب الصح** وتتأكد إن مفيش موارد يتيمة — بروتين "lab day": apply الصبح، destroy بالليل.
> **المستوى:** Beginner → Advanced (إجباري للكل) · **الوقت:** ~1 ساعة أول مرة، 10 دقايق كل يوم بعد كده · **التكلفة التقريبية:** مجاني (بل بيوفّر)
> **بيعتمد على:** [02 — الحساب و Budgets](02-aws-account-setup.md) · [90 — Terraform](90-terraform-deep-dive.md) · [92 — Terraform في الـ CI](92-terraform-in-ci.md) · **الملفات في الـ repo:** [`infra/terraform/README.md`](../../../infra/terraform/README.md) · [`bootstrap/README.md`](../../../infra/terraform/bootstrap/README.md) · [`stacks/*/README.md`](../../../infra/terraform/stacks) · [`.github/workflows/terraform.yml`](../../../.github/workflows/terraform.yml)

## 1) الفكرة (Concepts)

المعمل مبني على قاعدة واحدة: **bootstrap طويل العمر (سنتات/شهر) + stacks مؤقتة (apply → جرّب → destroy في نفس اليوم)**. الفلوس مش بتروح في اللي بتجربه، بتروح في اللي **نسيته**.

| المصطلح | المعنى |
|---|---|
| Idle cost | اللي بتدفعه والموارد قاعدة من غير traffic (ALB، NAT، control plane، RDS، IPv4) |
| Usage cost | بالاستخدام (build minutes، Logs ingestion، data transfer، LCU) |
| Orphaned resource | مورد اتعمل برّه Terraform (controller، CI، Console، AWS نفسه) ومبيتمسحش مع `terraform destroy` |
| `default_tags` | كل stack بيحط `Project=student-app`، `Env`، `ManagedBy=terraform`، `Scenario=<NN>` على كل حاجة → بنلاقي البواقي بالـ tags |
| Budget vs Anomaly | Budget: "عدّيت رقم". Anomaly Detection: "ده مش طبيعي" حتى لو لسه تحت الرقم |

> ⚠️ كل الأسعار هنا **تقريبية — راجع صفحة الأسعار**، us-east-1، on-demand، الـ defaults بتاعة كل stack. الأرقام متاخدة من `README.md` بتاع كل stack (هو المرجع لو لقيت رقم مقرّب مختلف في الكتالوج).

## 2) التكلفة لكل stack وسيناريو

### 2.1 الـ Terraform stacks

| Stack | السيناريوهات | ≈ USD/ساعة | ≈ USD/يوم (24h) | جلسة 3 ساعات | أهم بند |
|---|---|---|---|---|---|
| `bootstrap` | 02، 30، 80 | — | < $0.50/**شهر** | — | ECR storage (أقصى 30 image) + state versions |
| `20-ec2-single` | 20–27، 31–33 | ~0.03 | ~0.70 | ~0.10 | `t3.small` 0.0208/h + EIP 0.005/h + gp3 20 GiB |
| `35-codebuild` | 35 | 0 idle | 0 idle | — | ~$0.005/build-minute ⇒ ~$0.05 لكل push (100 دقيقة/شهر مجاناً) |
| `36-codepipeline` | 36، 37، 58 | 0 idle | 0 idle | — | V2: $0.002/action-minute + CodeBuild ⇒ ~$0.05 لكل release |
| `40-ec2-alb-asg` | 40–49 | ~0.08 | ~2 | ~0.25 | ALB 0.03 + 2× `t3.micro` 0.03 + RDS 0.02 + alarms ~$3/شهر |
| `50-ecs-fargate` | 50–58 | ~0.11 | ~2.70 (~80/شهر) | ~0.35 | ALB + Fargate (on-demand + Spot) + 4 public IPv4 + RDS |
| `60-eks` | 60–6A | ~0.23 | ~5.50 | ~0.70 | **EKS control plane 0.10/h** + 2× `t3.medium` + RDS |

### 2.2 الإضافات (toggles وسيناريوهات)

| الإضافة | السيناريو | ≈ التكلفة | ملاحظة |
|---|---|---|---|
| NAT gateway (`enable_nat` / `private_instances`) | 40، 50، 60 | +0.045/h + data processing (~$32/شهر لكل واحد) | مقفول افتراضياً في كل الـ stacks |
| ElastiCache `t4g.micro` (`redis_enabled`) | 49 | +0.013/h | |
| ALB من الـ AWS Load Balancer Controller | 63 | +~0.03/h + LCU | برّه Terraform! |
| node تالتة لـ kube-prometheus-stack / Argo CD | 62، 71، 73 | +~0.04/h | |
| RDS Multi-AZ (`db_multi_az`) | 41، 77 | ~×2 instance + storage | |
| Manual / cross-region RDS snapshots | 41، 77 | ~$0.095/GB-شهر لحد ما تمسحها | **بتعيش بعد `terraform destroy`** |
| Golden AMI (Packer) | 43 | build بسنتات؛ الـ snapshot بيتحاسب لحد ما تمسحه | `deregister-image` مبيمسحش الـ snapshot |
| CloudWatch Logs | 70 | ingestion ~$0.50/GB، storage ~$0.03/GB-شهر | |
| Dashboards | 71 | أول 3 مجاناً، بعد كده ~$3/شهر | |
| X-Ray | 72 | ~$5 لكل مليون trace | الـ sampling أهم knob |
| AWS FIS | 75 | ~$0.10/action-minute | الـ replacements اللي بتحصل بتتحاسب |
| Secrets Manager | 41، 81 | ~$0.40/secret/شهر | |
| KMS CMK | 81 | ~$1/شهر | |
| WAF | 83 | ~$5/web ACL + ~$1/rule ⇒ ~$8–12/شهر + requests | disassociate + delete بعد التجربة |
| Route 53 hosted zone | 42، 83 | ~$0.50/شهر | |
| EKS من الـ Console/eksctl (`student-app-lab-console`) | 61 | نفس EKS (cluster تاني!) | `eksctl delete cluster` |

### 2.3 أكبر المصايد

| المصيدة | ليه بتوجع | إزاي تتجنبها |
|---|---|---|
| **NAT gateway** | ~$0.045/h (~$32/شهر) **لكل AZ** + $ لكل GB بيعدّي — حتى لو مفيش traffic | `enable_nat = false` (الافتراضي): الـ tasks/nodes في public subnets والـ inbound من الـ ALB SG بس، و S3 gateway endpoint مجاني |
| **EKS control plane** | $0.10/h (~$73/شهر) بمجرد ما الـ cluster موجود، حتى من غير nodes | destroy نفس اليوم؛ جرّب الـ K8s على kind أو `k8s-integration.yml` الأول (مجاني) |
| **ALB قاعد idle** | ~$0.0225/h + LCU + الـ public IPv4 بتاعته (~$0.03/h إجمالي ≈ $22/شهر) | ALB واحد لكل stack؛ امسح الـ Ingresses قبل destroy الـ EKS |
| **RDS** | ~$0.016/h + storage — وبيفضل شغال لو نسيت الـ stack | destroy الـ stack. الـ stop مؤقت: AWS بيشغّل الـ instance المتوقف تاني لوحده بعد 7 أيام |
| **EIP / public IPv4 والـ instance stopped** | كل public IPv4 بيتحاسب ~$0.005/h سواء مربوط أو لأ، والـ EBS بيتحاسب والـ instance stopped | **destroy مش stop**. `describe-addresses` للـ EIPs اللي مش مربوطة |
| **CloudWatch Logs من غير retention** | الافتراضي **Never expire** → storage بيتراكم للأبد. `awslogs-create-group: "true"` ([`compose.awslogs.yml`](../../../deploy/ec2/compose.awslogs.yml)) بيعمل group من غير retention | Terraform بيعمل الـ groups مسبقاً بـ retention (7/14 يوم)؛ دوّر على `retentionInDays==null` |
| **ECR storage** | ~$0.10/GB-شهر لكل الـ images (multi-arch = أكتر) | lifecycle في الـ bootstrap: keep 30 image، untagged تتمسح بعد 7 أيام |
| **Container Insights (enhanced)** | per-task metrics و log groups `/aws/ecs/containerinsights/<cluster>/*` بيعملها AWS (برّه Terraform) | سنتات/يوم في المعمل؛ امسح الـ log groups بعد الـ destroy |
| **Fargate** | بيتحاسب بالـ vCPU/GB-second طول ما الـ task شغال؛ الـ autoscaling (2–6) بعد load test ممكن يفضل عالي لحد الـ scale-in | `use_fargate_spot`؛ راقب `desiredCount` بعد k6؛ destroy |
| Stacks نسيتها | الكل | روتين §8 + Budget + Anomaly Detection |

## 3) ترتيب المسح (Teardown order) ⚠️

```text
0) اللي اتعمل برّه Terraform (controllers / CI / Console / AWS)   ← الأول دايماً
      kubectl delete ingress/LoadBalancer svc · Karpenter NodePools · ASG اللي CodeDeploy عمله copy
      FIS templates · WAF web ACL · RDS manual/PITR/cross-region snapshots · AMIs + snapshots
      موارد الـ Console (20، 50) · eksctl cluster (61) · AppConfig (26) · AWS Backup plans (77)
1) 36-codepipeline   ← لازم قبل 50 (الـ pipeline بيعمل deploy على service بتاع 50)
2) 35-codebuild      ← بيستخدم الـ CodeConnections بتاعة الـ bootstrap بس
3) الـ app stack الوحيد الشغال: 20 أو 40 أو 50 أو 60   ← stack واحد بس لكل env في نفس الوقت
4) فحص البواقي (§5)
5) bootstrap         ← آخر حاجة، وبس لو خلصت المعمل نهائياً
```

**ليه stack واحد بس من 20/40/50/60؟** الأربعة بيكتبوا **نفس** الـ SSM paths `/student-app/<env>/app/*`. لو عايز اتنين مع بعض لازم env تاني، و `-var env=lab2` لوحده **مش كفاية**: الـ backend `key` متثبت جوه الـ stack، فهتحتاج key مختلف كمان ([90](90-terraform-deep-dive.md)، [92](92-terraform-in-ci.md)).

**ليه الـ bootstrap آخر حاجة؟** فيه الـ state bucket نفسه (كل الـ stacks بتقرا منه)، والـ OIDC roles اللي `terraform.yml` بيستخدمها، والـ ECR. الـ bucket عليه **versioning** والنسخ القديمة بتتحفظ 90 يوم (أقل حاجة 10 versions) كـ undo button، وده معناه إن مسحه محتاج `state_bucket_force_destroy = true` (و ECR محتاج `ecr_force_delete = true` لو فيه images). تكلفته سنتات — سيبه طول ما انت في المعمل.

## 4) أوامر المسح لكل stack

من الـ laptop (أو `gh workflow run terraform.yml --ref master -f stack=<NN> -f action=destroy` — بيستنى موافقة environment `lab`):

| Stack | قبل الـ destroy | الأمر | بعده اتأكد |
|---|---|---|---|
| `36-codepipeline` | — | `terraform -chdir=infra/terraform/stacks/36-codepipeline destroy` | `aws codepipeline list-pipelines` فاضية (الـ artifact bucket `force_destroy = true`) |
| `35-codebuild` | — | `terraform -chdir=infra/terraform/stacks/35-codebuild destroy` | `aws codebuild list-projects`؛ الـ webhooks اتشالت من GitHub |
| `60-eks` | `kubectl delete ingress --all -A` · `kubectl delete svc -A --field-selector spec.type=LoadBalancer` · Karpenter: `kubectl delete nodepools --all` | `terraform -chdir=infra/terraform/stacks/60-eks destroy` | مفيش ALB اسمه `k8s-*` أو `student-app-lab-eks`، مفيش EBS `available`، مفيش instances `karpenter.sh/nodepool` |
| `50-ecs-fargate` | 36 اتمسح | `terraform -chdir=infra/terraform/stacks/50-ecs-fargate destroy` | الـ task definitions اللي الـ CI سجّلها INACTIVE (مجانية)؛ log groups `/aws/ecs/containerinsights/student-app-lab/*` |
| `40-ec2-alb-asg` | لو عملت 37 بـ `BLUE_GREEN`: امسح الـ ASG اللي CodeDeploy عمله copy | `terraform -chdir=infra/terraform/stacks/40-ec2-alb-asg destroy` | RDS اتمسح (من غير final snapshot — lab default)؛ مفيش manual snapshots |
| `20-ec2-single` | خد backup لو محتاجه (الـ bucket بيتمسح بالـ dumps) | `terraform -chdir=infra/terraform/stacks/20-ec2-single destroy` | الـ EIP اتعمله release؛ الـ MySQL volume مات مع الـ instance |
| `bootstrap` | كل اللي فوق + §5 نضيف | تحت | GitHub variables/environments، و **AWS Connector for GitHub** app |

```bash
# bootstrap — بس لو خلصت المعمل نهائياً (bootstrap/README.md)
cd infra/terraform/bootstrap
#  1) comment الـ backend "s3" block في versions.tf، ورجّع الـ state local:
terraform init -migrate-state
#  2) اسمح بمسح bucket فيه versions و repo فيه images:
terraform apply   -var ecr_force_delete=true -var state_bucket_force_destroy=true
terraform destroy -var ecr_force_delete=true -var state_bucket_force_destroy=true
```

موارد الـ **Console** (سيناريوهات [20](20-ec2-compose-console.md)، [50](50-ecs-fargate-console.md)، [61](61-eks-console-eksctl.md)) مش في أي state: امشِ على §10 بتاع كل سيناريو بالترتيب (service ← cluster ← ALB ← TGs ← RDS ← SSM ← IAM ← log groups ← SGs ← VPC). لـ eksctl:

```bash
eksctl delete cluster -f /tmp/eksctl-61.yaml --disable-nodegroup-eviction --wait
```

## 5) Checklist البواقي (Leftovers)

### 5.1 بالـ tag (الأول)

```bash
export AWS_REGION=us-east-1
# كل حاجة عليها Project=student-app (هتلاقي الـ bootstrap: Scenario=02 — ده طبيعي)
aws resourcegroupstaggingapi get-resources --tag-filters Key=Project,Values=student-app \
  --query 'ResourceTagMappingList[].ResourceARN' --output text | tr '\t' '\n' | sort

# لكل stack لوحده (الـ filters بيتعملهم AND)
for s in 20 35 36 40 50 60 63; do
  echo "== Scenario=$s"
  aws resourcegroupstaggingapi get-resources \
    --tag-filters Key=Project,Values=student-app Key=Scenario,Values=$s \
    --query 'ResourceTagMappingList[].ResourceARN' --output text
done

# اللي اتعمل من الـ Console (لو حطيت الـ tags بتاعة CONVENTIONS: ManagedBy=console)
aws resourcegroupstaggingapi get-resources --tag-filters Key=Project,Values=student-app Key=ManagedBy,Values=console \
  --query 'ResourceTagMappingList[].ResourceARN' --output text
```

> 💡 الـ Tagging API **per region** (عيد الأوامر بـ `--region us-west-2` لو عملت DR في [77](77-backup-and-dr.md))، ومبيشوفش غير اللي عليه tags. ولو ARN ظهر وانت متأكد إنه اتمسح، اتأكد بالـ `describe` بتاع الخدمة نفسها. Scenario `63` = الـ ALB اللي الـ LBC عمله (`alb.ingress.kubernetes.io/tags` في `values-eks.yaml`).

### 5.2 اللي ممكن يكون من غير tags (بالخدمة)

| البند | الأمر | المفروض |
|---|---|---|
| EC2 شغالة/متوقفة | `aws ec2 describe-instances --filters Name=instance-state-name,Values=running,stopped --query 'Reservations[].Instances[].[InstanceId,InstanceType,State.Name]' --output table` | فاضي |
| EIPs مش مربوطة | `aws ec2 describe-addresses --query 'Addresses[?AssociationId==null].[PublicIp,AllocationId]' --output table` | فاضي (`aws ec2 release-address --allocation-id <ID>`) |
| NAT gateways | `aws ec2 describe-nat-gateways --filter Name=state,Values=available --query 'NatGateways[].[NatGatewayId,VpcId]' --output table` | فاضي |
| Load balancers | `aws elbv2 describe-load-balancers --query 'LoadBalancers[].[LoadBalancerName,State.Code]' --output table` | فاضي |
| EBS مش مربوطة | `aws ec2 describe-volumes --filters Name=status,Values=available --query 'Volumes[].[VolumeId,Size]' --output table` | فاضي |
| AMIs + snapshots | `aws ec2 describe-images --owners self --query 'Images[].[ImageId,Name]' --output table` · `aws ec2 describe-snapshots --owner-ids self --query 'Snapshots[].[SnapshotId,VolumeSize,StartTime]' --output table` | فاضي (أو اللي قاصد تسيبه) |
| RDS | `aws rds describe-db-instances --query 'DBInstances[].[DBInstanceIdentifier,DBInstanceStatus]' --output table` (فيه `student-app-lab-mysql-pitr` من 77؟) | فاضي |
| RDS manual snapshots | `aws rds describe-db-snapshots --snapshot-type manual --query 'DBSnapshots[].[DBSnapshotIdentifier,AllocatedStorage]' --output table` (us-east-1 **و** us-west-2) | فاضي |
| ElastiCache | `aws elasticache describe-replication-groups --query 'ReplicationGroups[].ReplicationGroupId'` | فاضي |
| ECS / EKS | `aws ecs list-clusters` · `aws eks list-clusters` | فاضي |
| Log groups من غير retention | `aws logs describe-log-groups --query 'logGroups[?retentionInDays==null].[logGroupName,storedBytes]' --output table` | فاضي (أو `aws logs put-retention-policy --log-group-name <NAME> --retention-in-days 7`) |
| Log groups بتاعة المعمل | `aws logs describe-log-groups --log-group-name-prefix /student-app --query 'logGroups[].logGroupName'` · نفس الأمر بـ `/ecs/student-app-lab` و `/aws/ecs/containerinsights/student-app-lab` و `/aws/rds/instance/student-app-lab-mysql` | فاضي بعد الـ destroy |
| Alarms / dashboards | `aws cloudwatch describe-alarms --alarm-name-prefix student-app --alarm-types MetricAlarm CompositeAlarm --query '[MetricAlarms[].AlarmName, CompositeAlarms[].AlarmName]'` · `aws cloudwatch list-dashboards --dashboard-name-prefix student-app` | فاضي |
| CodePipeline / CodeBuild | `aws codepipeline list-pipelines --query 'pipelines[].name'` · `aws codebuild list-projects` | فاضي |
| FIS / WAF / Secrets Manager | `aws fis list-experiment-templates --query 'experimentTemplates[].id'` · `aws wafv2 list-web-acls --scope REGIONAL --query 'WebACLs[].Name'` · `aws secretsmanager list-secrets --query 'SecretList[].Name'` | فاضي |
| S3 buckets | `aws s3api list-buckets --query "Buckets[?starts_with(Name,'student-app')].Name" --output text` | الـ state bucket + الـ Ansible SSM bucket بس (bootstrap) |
| ECR | `aws ecr describe-images --repository-name student-app --query 'length(imageDetails)'` | ≤ 30 (الـ lifecycle) |
| SSM parameters | `aws ssm get-parameters-by-path --path /student-app --recursive --query 'Parameters[].Name' --output text` | فاضي (مجانية، بس فيها secrets — امسحها) |
| Route 53 | `aws route53 list-hosted-zones --query 'HostedZones[].Name'` | اللي قاصد تسيبه بس |

### 5.3 الـ checklist

- [ ] الـ tagging API مفيهوش غير `Scenario=02` (bootstrap)
- [ ] مفيش EC2 / EIP / NAT / ALB / RDS / EKS / ECS / ElastiCache
- [ ] مفيش EBS `available` ولا snapshots/AMIs منسية ولا RDS manual snapshots (في الـ regionين)
- [ ] كل الـ log groups عليها retention، ومفيش log groups لـ stacks اتمسحت
- [ ] مفيش FIS templates / WAF web ACLs / Secrets Manager secrets من التجارب
- [ ] الـ Cost Explorer بكرة الصبح ≈ سنتات

## 6) Budgets و Anomaly alerts

اتعملت في [02 §4.5–4.7](02-aws-account-setup.md). مراجعة سريعة:

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws budgets describe-budgets --account-id "$ACCOUNT_ID" --query 'Budgets[].[BudgetName,BudgetLimit.Amount]' --output table

# zero-spend budget (لو مش موجود): أي سنت يوصلك email
aws budgets create-budget --account-id "$ACCOUNT_ID" \
  --budget '{"BudgetName":"zero-spend","BudgetLimit":{"Amount":"0.01","Unit":"USD"},"TimeUnit":"MONTHLY","BudgetType":"COST"}' \
  --notifications-with-subscribers '[{"Notification":{"NotificationType":"ACTUAL","ComparisonOperator":"GREATER_THAN","Threshold":100,"ThresholdType":"PERCENTAGE"},"Subscribers":[{"SubscriptionType":"EMAIL","Address":"<YOUR_EMAIL>"}]}]'

# Cost Anomaly Detection: فيه monitor؟ (غالباً AWS عمل واحد افتراضي)
aws ce get-anomaly-monitors --query 'AnomalyMonitors[].[MonitorName,MonitorType]' --output table
aws ce get-anomalies --date-interval StartDate=$(date -d '-7 days' +%F) \
  --query 'Anomalies[].[AnomalyStartDate,Impact.TotalImpact,RootCauses[0].Service]' --output table
```

| الأداة | بتعمل إيه | مجاني؟ |
|---|---|---|
| Zero-spend budget ($0.01) | email مع أول سنت | ✅ |
| Monthly budget ($10: 50% / 80% actual، 100% forecasted) | إنذار بدري | ✅ (من غير actions) |
| Cost Anomaly Detection | "NAT اتعمل امبارح وبيصرف $1/يوم" حتى تحت الـ budget | ✅ |
| Billing alarm (CloudWatch، us-east-1 بس) | `EstimatedCharges > 10` | ضمن الـ alarms المجانية |

> ⚠️ الـ Budget **بينبّه بس، مبيوقفش حاجة**، وبيتحدّث كل كام ساعة. والـ Cost Explorer API نفسه بيتحاسب (~$0.01 لكل request) — استخدمه مرة في اليوم مش في loop. الحماية الحقيقية هي الـ teardown.

```bash
# فاتورة آخر 7 أيام (يوم بيوم) — وامبارح حسب الخدمة
aws ce get-cost-and-usage --time-period Start=$(date -d '-7 days' +%F),End=$(date +%F) \
  --granularity DAILY --metrics UnblendedCost \
  --query 'ResultsByTime[].[TimePeriod.Start,Total.UnblendedCost.Amount]' --output table
aws ce get-cost-and-usage --time-period Start=$(date -d yesterday +%F),End=$(date +%F) \
  --granularity DAILY --metrics UnblendedCost --group-by Type=DIMENSION,Key=SERVICE \
  --query 'ResultsByTime[0].Groups[].[Keys[0],Metrics.UnblendedCost.Amount]' --output table
```

## 7) اكسرها (Break it): تمارين على الفلوس

| التمرين | الأمر | المتوقع / الدرس |
|---|---|---|
| Stop بدل destroy | stop الـ EC2 بتاع 20 يوم كامل | الـ Cost Explorer: EBS + public IPv4 لسه بيتحسبوا |
| Log group من غير retention | شغّل [`compose.awslogs.yml`](../../../deploy/ec2/compose.awslogs.yml) على host من غير الـ group | group بـ **Never expire** → ظاهر في أمر `retentionInDays==null` |
| Ingress منسي | `terraform destroy` لـ 60 من غير `kubectl delete ingress` | الـ destroy بيقف على الـ VPC/SGs (الـ ALB والـ SGs بتاعة الـ controller برّه Terraform) → امسح الـ ALB والـ SGs بإيدك وكمّل |
| Snapshot يتيم | manual snapshot في [41](41-rds-mysql.md) ثم destroy لـ 40 | الـ snapshot لسه موجود وبيتحاسب |
| NAT ليوم | `enable_nat = true` في 50 لمدة ساعة ثم destroy | سطر "NAT Gateway" في الفاتورة + data processing — قارنه بـ S3 gateway endpoint المجاني |

## 8) روتين الـ "Lab day" (apply الصبح → destroy بالليل)

**الصبح (~15 دقيقة):**

```bash
aws sso login --profile lab && export AWS_PROFILE=lab
aws resourcegroupstaggingapi get-resources --tag-filters Key=Project,Values=student-app \
  --query 'ResourceTagMappingList[].ResourceARN' --output text      # bootstrap بس؟
# stack واحد بس للنهارده:
cd infra/terraform/stacks/50-ecs-fargate
terraform init -backend-config=../../backend.hcl
terraform plan -out=tfplan && terraform apply tfplan                # ~10 دقايق (RDS)؛ EKS ~15
terraform output github_repository_variables                       # لو هتستخدم deploy-ecs.yml
```

**أثناء اليوم:** load tests قصيرة (`DURATION` دقايق مش ساعات)، drills بـ `SRE_FAULT_*`، صوّر الـ screenshots والـ logs للـ portfolio ([98](98-portfolio-and-interview.md))، واكتب ملاحظاتك.

**بالليل (~15 دقيقة):**

```bash
# 0) اللي برّه Terraform (حسب اللي عملته النهارده): ingress، FIS، snapshots، AMIs…
# 1) الـ stacks المعتمدة الأول، وبعدين الـ app stack
terraform -chdir=infra/terraform/stacks/36-codepipeline destroy   # لو كان شغال
terraform -chdir=infra/terraform/stacks/50-ecs-fargate destroy
# 2) فحص البواقي (§5.1 + أهم سطور §5.2)
aws resourcegroupstaggingapi get-resources --tag-filters Key=Project,Values=student-app \
  --query 'ResourceTagMappingList[].ResourceARN' --output text
aws ec2 describe-addresses --query 'Addresses[?AssociationId==null].PublicIp'
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName'
aws rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier'
```

> 💡 "هكمّل بكرة، هسيبه" = أغلى جملة في المعمل. stack 50 بيتعمل apply في ~10 دقايق و 60 في ~15 — أرخص بكتير من ليلة كاملة (≈ $1.3 لـ 50، ≈ $2.8 لـ 60 في 12 ساعة).

## 9) أسئلة Interview

<details><summary>إزاي بتمنع مفاجآت الفاتورة في حساب dev/lab؟</summary>

طبقات: (1) design: مفيش NAT افتراضياً، stacks مؤقتة، retention على الـ logs، lifecycle على ECR/S3؛ (2) tags إجبارية (`default_tags`) + cost allocation tags؛ (3) Budgets (zero-spend + شهري) و Cost Anomaly Detection؛ (4) روتين teardown + فحص بالـ tagging API؛ (5) في organization: SCPs تمنع instance types غالية أو regions مش مستخدمة. والأهم: الـ ownership — كل مورد ليه stack أو صاحب.

</details>

<details><summary>ليه `terraform destroy` مش كفاية عشان تتأكد إن الحساب نضيف؟</summary>

لأن فيه موارد بتتعمل برّه الـ state: الـ AWS Load Balancer Controller بيعمل ALBs و SGs، Karpenter بيعمل instances، CodeDeploy `BLUE_GREEN` بيعمل copy للـ ASG، AWS بيعمل log groups (Container Insights، `awslogs-create-group`)، والـ manual snapshots بتعيش بعد مسح الـ DB. عشان كده: امسح اللي الـ controllers عملوه الأول، وبعدين destroy، وبعدين فحص بالـ tags وبالخدمات.

</details>

<details><summary>NAT gateway: ليه غالي وإيه البدائل؟</summary>

~$0.045/h لكل NAT (~$32/شهر) + رسوم لكل GB بيعدّي، و HA = واحد لكل AZ. البدائل: public subnets مع SG مقفول (اللي عملناه في المعمل)، VPC endpoints (S3/DynamoDB gateway مجانية؛ interface endpoints لـ ECR/SSM/Logs ليها تكلفة بالساعة برضه)، NAT instance لبيئات dev، أو IPv6 + egress-only IGW. في production الـ private subnets + NAT غالباً صح — بس اعرف تمنه.

</details>

<details><summary>إيه الفرق بين AWS Budgets و Cost Anomaly Detection و billing alarm؟</summary>

Budget: threshold ثابت (actual أو forecasted) وتقدر تفلتره بالـ tags، وممكن actions. Anomaly Detection: ML على نمط الصرف بيكتشف الشاذ حتى لو تحت الـ budget (مورد جديد بيصرف $1/يوم). Billing alarm: CloudWatch على `EstimatedCharges` في us-east-1 — الطريقة الكلاسيكية. الكل بينبّه بس، محدش بيوقف موارد إلا budget actions/SCPs.

</details>

<details><summary>إزاي تحسب تكلفة بيئة قبل ما تعملها؟</summary>

Infracost على الـ plan في الـ PR (الـ `terraform.yml` بيدعمه لو فيه `INFRACOST_API_KEY`)، أو AWS Pricing Calculator. وبعد الـ apply: Cost Explorer بالـ tag `Scenario`. الـ README بتاع كل stack فيه جدول بالساعة — الرقم الصح هو اللي بتقارنه بالفاتورة الفعلية بعد يوم.

</details>

<details><summary>Stop ولا destroy لبيئة dev بالليل؟</summary>

Destroy لو الـ IaC يقدر يرجّعها في دقايق (ده اختبار كمان إن الـ IaC شغال). Stop بيوفّر الـ compute بس: الـ EBS والـ public IPv4 والـ ALB والـ NAT والـ EKS control plane بيفضلوا يتحاسبوا، والـ RDS المتوقف بيرجع يشتغل لوحده بعد 7 أيام. Instance Scheduler أو ASG scale-to-0 حل وسط لبيئات لازم تفضل موجودة.

</details>

## 10) Checklist

- [ ] الـ Budgets والـ Anomaly monitor شغالين والإيميلات متأكدة
- [ ] حفظت أوامر §5 في مكان قريب (أو alias)
- [ ] عملت يوم معمل كامل بالروتين: apply → جرّب → destroy → فحص
- [ ] جرّبت تمرين واحد على الأقل من §7 وشفته في الـ Cost Explorer
- [ ] عارف ترتيب الـ teardown من غير ما تبص: برّه Terraform ← 36 ← 35 ← app stack ← فحص ← (bootstrap)
