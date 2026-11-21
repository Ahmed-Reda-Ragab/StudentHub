# 50 — ECS Fargate من الـ Console

> **الهدف في سطر:** تبني بإيدك من الـ AWS Console كل حتة في ستاك ECS: VPC + سلسلة الـ security groups (ALB → task → RDS)، الـ SSM parameters، الـ execution role والـ task role، الـ cluster، الـ task definition (container `app` على 8080، secrets من SSM، `awslogs`، healthcheck)، الـ ALB بالـ blue target group، الـ service، والـ migrations كـ "Run task" — وتعمل deploy لـ revision جديدة وteardown بالترتيب الصح. بعد كده [51](51-ecs-fargate-terraform.md) بيعمل نفس الحاجة بـ Terraform وهتفهم كل سطر.
> **المستوى:** Intermediate · **الوقت:** ~5 ساعات · **التكلفة التقريبية:** ~$2.5–3/يوم طول ما هو شغال (تقريبي — راجع صفحة الأسعار)
> **بيعتمد على:** [30 — CI](30-ci-github-actions.md) (image في ECR) · [40 — VPC](40-vpc-from-scratch.md) · [41 — RDS](41-rds-mysql.md) · **الملفات في الـ repo:** [`deploy/ecs/task-definition.json`](../../../deploy/ecs/task-definition.json) · [`deploy/ecs/render-taskdef.sh`](../../../deploy/ecs/render-taskdef.sh) · [`deploy/ecs/run-migrations.sh`](../../../deploy/ecs/run-migrations.sh) · [`deploy/ecs/README.md`](../../../deploy/ecs/README.md) · [`docker/Dockerfile`](../../../docker/Dockerfile) · [`infra/terraform/modules/ecs-fargate/`](../../../infra/terraform/modules/ecs-fargate/)

## 1) الفكرة (Concepts)

في الـ EC2 scenarios (20–49) إنت اللي بتدير السيرفر: AMI، Docker، patching، الـ capacity. **ECS** بيشيل منك الـ orchestration (مين يشتغل فين، restart، rolling، ربط بالـ ALB)، و**Fargate** بيشيل كمان السيرفرات نفسها: كل task بياخد micro-VM معزول بـ CPU/RAM إنت محددهم، وبتدفع بالثانية.

| المصطلح | المعنى |
|---|---|
| Cluster | grouping منطقي (namespace) للـ services والـ tasks + الـ capacity providers. على Fargate مفيهوش سيرفرات |
| Task definition | "الـ pod spec": image، CPU/RAM، ports، env، secrets، logs، healthcheck، الـ roles. **immutable** — أي تعديل = revision جديدة (`family:N`) |
| Task | نسخة شغالة من task definition (container واحد أو أكتر بيتشاركوا ENI) |
| Service | بيحافظ على `desiredCount` من الـ tasks، بيستبدل اللي بيموت، بيسجّلهم في الـ target group، وبيعمل الـ deployments |
| Capacity provider | منين الـ compute: `FARGATE` (on-demand) أو `FARGATE_SPOT` أو ASG بتاعك ([56](56-ecs-capacity-providers-spot.md)) |
| `awsvpc` | كل task ليه ENI و IP خاص بيه في الـ subnet → الـ target group لازم `target_type = ip` |
| Execution role | دور **الـ ECS agent**: يسحب الـ image من ECR، يكتب logs، يجيب الـ `secrets` من SSM قبل ما الـ container يقوم |
| Task role | دور **التطبيق نفسه** وهو شغال (AWS SDK جوه الكود، وقنوات ECS Exec) |
| Container healthCheck | ECS بيشغّل أمر جوه الـ container؛ لو فشل → الـ task unhealthy → يتقتل ويتستبدل |
| Target group health check | الـ ALB بيسأل `/ready` من بره؛ لو فشل → مبيبعتلوش traffic (والـ service بيستبدله بعد الـ grace period) |

### Execution role مقابل Task role (أكتر سؤال بيتسأل)

| | Execution role (`student-app-lab-ecs-execution`) | Task role (`student-app-lab-ecs-task`) |
|---|---|---|
| مين بيستخدمه | الـ ECS/Fargate agent **قبل وأثناء** تشغيل الـ container | الكود جوه الـ container (credentials من metadata endpoint) |
| بيعمل إيه عندنا | `ecr:GetAuthorizationToken` + pull من repo `student-app` بس، `logs:CreateLogStream/PutLogEvents`، `ssm:GetParameters` على `/student-app/lab/app/*` بس، `kms:Decrypt` عن طريق SSM | ECS Exec بس: قنوات `ssmmessages:*` الأربعة + كتابة output الـ session في log group الـ app — **ولا حاجة تانية** (التطبيق مش بيكلّم AWS APIs) |
| لو ناقص | الـ task مش بيقوم: `ResourceInitializationError` / `CannotPullContainerError` | الـ task شغال، بس `execute-command` بيفشل أو الـ SDK بياخد AccessDenied |

### Public subnets + public IP مقابل private subnets + NAT

الـ task محتاج يوصل لـ ECR و SSM و CloudWatch Logs (public AWS endpoints). عندك 3 طرق:

| الطريقة | إزاي | التكلفة (تقريبي) | الأمان |
|---|---|---|---|
| **Public subnet + public IP** (الـ lab default) | `Public IP: on`، الـ route `0.0.0.0/0 → IGW` | ~$0.005/ساعة لكل task (public IPv4) | الـ task عنده IP عام، **بس** الـ SG بيسمح بـ 8080 من الـ ALB SG بس → محدش يقدر يوصله من بره |
| **Private subnet + NAT gateway** (الـ production layout) | `Public IP: off`، الـ route → NAT | ~$0.045/ساعة لكل NAT (≈ $32/شهر) + $0.045/GB data processing | مفيش IP عام خالص؛ egress واحد معروف (EIP) |
| **Private + VPC endpoints** (من غير NAT) | interface endpoints لـ `ecr.api`، `ecr.dkr`، `logs`، `ssm`، `ssmmessages` + S3 gateway (مجاني) | ~$7/شهر لكل endpoint لكل AZ | أقفل حاجة؛ بس RDS/الإنترنت العام لسه محتاجين تفكير |

> 💡 الـ Terraform stack بيمسك نفس القرار بـ variable واحد `enable_nat` ([51](51-ecs-fargate-terraform.md)): `false` = public subnets + public IP، `true` = private subnets + NAT.

## 2) المعمارية (Architecture)

```text
                            Internet
                               │ :80
 ┌─────────── VPC student-app-lab 10.50.0.0/16 (2 AZ) ───────────────────────────────────────┐
 │  public subnets (AZ-a, AZ-b) ── route 0.0.0.0/0 → IGW                                       │
 │   ┌───────────────────────────────┐                                                         │
 │   │ ALB student-app-lab-alb        │ SG student-app-lab-alb: in 80 from 0.0.0.0/0           │
 │   │ listener HTTP:80               │                         out 8080 → VPC CIDR            │
 │   │  rule p1: /metrics* → 404      │                                                        │
 │   │  default: forward → TG blue    │                                                        │
 │   └──────────────┬────────────────┘                                                        │
 │                  ▼ TG student-app-lab-blue (ip, HTTP:8080, health /ready, 10s, 2/2, dereg 30s)
 │   ┌──────────────────────┐   ┌──────────────────────┐                                       │
 │   │ task (ENI + pub IP)  │   │ task (ENI + pub IP)  │  SG student-app-lab-ecs-app:          │
 │   │ container "app":8080 │   │ container "app":8080 │    in 8080 from SG alb only           │
 │   │ healthCheck /up      │   │ healthCheck /up      │    out all (ECR/SSM/Logs + RDS)       │
 │   └─────────┬────────────┘   └─────────┬────────────┘                                       │
 │             └──────────── 3306 ────────┘                                                    │
 │  private subnets (no internet route)   ▼                                                    │
 │   ┌────────────────────────────────────────────┐ SG student-app-lab-rds: in 3306 from SG ecs │
 │   │ RDS MySQL 8.4 student-app-lab-mysql         │                                           │
 │   └────────────────────────────────────────────┘                                           │
 └─────────────────────────────────────────────────────────────────────────────────────────────┘
   task boot: execution role → ECR pull student-app:<sha7> · SSM /student-app/lab/app/* → env · logs → /ecs/student-app-lab/app
```

## 3) المتطلبات (Prerequisites)

- [ ] image في ECR بـ tag = git short SHA (`ci.yml` على `master` — [30](30-ci-github-actions.md)):
  `aws ecr describe-images --repository-name student-app --query 'sort_by(imageDetails,&imagePushedAt)[-1].imageTags'`
- [ ] الـ bootstrap stack اتعمله apply (ECR repo `student-app`) — [02](02-aws-account-setup.md).
- [ ] Region: `us-east-1` في كل الصفحات (فوق يمين في الـ console).
- [ ] **مفيش** stack 20/40/50/60 شغال على `env=lab` — كلهم بيكتبوا نفس مسارات SSM `/student-app/lab/app/*`، وأسماء الـ roles/الـ SGs هنا نفس أسماء stack 50 (عشان القوالب في `deploy/ecs/` تشتغل). امسح الـ console resources قبل [51](51-ecs-fargate-terraform.md) أو اعملهم import ([91](91-terraform-import-and-drift.md)).
- الأدوات: `aws` CLI v2، `jq`، `openssl`، `curl` (للتحقق والـ CLI equivalents).

## 4) الطريقة الأولى: AWS Console (يدوي)

> ترتيب الخطوات مقصود: **الـ migrations قبل الـ service**. لو عملت الـ service الأول، الـ tasks هتقوم و`/ready` هيرجّع 503 (الجداول مش موجودة)، الـ ALB هيعلّمهم unhealthy، والـ service هيفضل يقتل ويبدّل tasks.

### 4.1 الـ Network

لو عندك VPC من [40](40-vpc-from-scratch.md) استخدمه. لو لأ:

1. **VPC → Create VPC → VPC and more**.
2. Name tag auto-generation: `student-app-lab` · IPv4 CIDR: `10.50.0.0/16` · Number of AZs: **2** · Public subnets: **2** · Private subnets: **2**.
3. **NAT gateways: None** (الـ tasks هتبقى في الـ public subnets) · **VPC endpoints: S3 Gateway** (مجاني، اختياري).
4. ✅ Enable DNS hostnames · ✅ Enable DNS resolution → **Create VPC**.
5. افتح كل public subnet → **Actions → Edit subnet settings** → ✅ **Enable auto-assign public IPv4 address** (مش لازم لـ ECS لأن الـ service نفسه بيطلب الـ public IP، بس بيفيد لو حطيت EC2 للتجارب).

### 4.2 سلسلة الـ Security Groups (ALB → task → RDS)

**EC2 → Security Groups → Create security group** (VPC = `student-app-lab`)، بالترتيب:

| SG | Inbound | Outbound | ليه |
|---|---|---|---|
| `student-app-lab-alb` | HTTP 80 من `0.0.0.0/0` (أو My IP وانت بتتعلم) | Custom TCP **8080** → `10.50.0.0/16` | الـ ALB مش محتاج يكلّم غير الـ targets على بورت الـ container |
| `student-app-lab-ecs-app` | Custom TCP **8080** — Source: **SG** `student-app-lab-alb` | All traffic → `0.0.0.0/0` | الـ traffic والـ health checks من الـ ALB بس. الـ egress مفتوح لأن ECR/SSM/Logs endpoints عامة (من غير VPC endpoints مينفعش تضيّقه) |
| `student-app-lab-rds` | MySQL/Aurora **3306** — Source: **SG** `student-app-lab-ecs-app` | (default) | الداتابيز مش بيوصلها غير الـ tasks |

> 💡 **SG referencing** بدل CIDRs: الـ tasks بتاخد IPs متغيرة كل deploy؛ الـ rule "من SG كذا" بيفضل صح مهما الـ IPs اتغيرت. ده نفس اللي `aws_vpc_security_group_ingress_rule.from_alb` بيعمله في [`modules/ecs-fargate/main.tf`](../../../infra/terraform/modules/ecs-fargate/main.tf).

### 4.3 الـ RDS (أو استخدم اللي من [41](41-rds-mysql.md))

1. **RDS → Subnet groups → Create DB subnet group**: name `student-app-lab-mysql`، VPC `student-app-lab`، الـ AZs الاتنين، الـ **private** subnets بس.
2. **RDS → Databases → Create database** → **Standard create** (أو Full configuration) → **MySQL** → Engine version: آخر **8.4.x**.
3. Templates: **Free tier** / **Sandbox** (حسب اللي ظاهر في حسابك) → Single-AZ.
4. DB instance identifier: `student-app-lab-mysql` · Master username: `student` · Credentials management: **Self managed** → اكتب password قوي (هتحطه في SSM في 4.4).
   (Managed in Secrets Manager أحسن للـ rotation — [81](81-secrets-management.md) — بس الـ repo بيقرا `DB_PASSWORD` من SSM.)
5. Instance class: `db.t4g.micro` · Storage: gp3، 20 GiB.
6. Connectivity: **Don't connect to an EC2 compute resource** · VPC `student-app-lab` · subnet group `student-app-lab-mysql` · **Public access: No** · VPC security group: **Choose existing** → `student-app-lab-rds` (شيل `default`).
7. **Additional configuration** → Initial database name: `student_app` · Backup retention: 1 day (lab) · امسح علامة Enable deletion protection.
8. **Create database** (~5–10 دقايق). خد الـ **Endpoint** من تاب Connectivity & security.

### 4.4 الـ SSM Parameters (مصدر الـ config والـ secrets)

نفس الـ layout بتاع [CONVENTIONS §4](../CONVENTIONS.md) — والمفاتيح هي بالظبط اللي في `secrets[]` في [`task-definition.json`](../../../deploy/ecs/task-definition.json).

من الـ console مرة واحدة عشان تعرف الشاشة: **Systems Manager → Parameter Store → Create parameter** → Name: `/student-app/lab/app/APP_KEY` · Tier: **Standard** · Type: **SecureString** · KMS key source: **My current account** → `alias/aws/ssm` · Value: ناتج `echo "base64:$(openssl rand -base64 32)"` → **Create parameter**.

الباقي بالـ CLI (أسرع وأقل غلط):

```bash
P=/student-app/lab/app
aws ssm put-parameter --name "$P/SRE_LAB_TOKEN" --type SecureString --value "$(openssl rand -hex 16)"
aws ssm put-parameter --name "$P/DB_PASSWORD"   --type SecureString --value '<RDS_MASTER_PASSWORD>'
for kv in DB_CONNECTION=mysql DB_HOST=<RDS_ENDPOINT> DB_PORT=3306 DB_DATABASE=student_app DB_USERNAME=student \
          SESSION_DRIVER=database CACHE_STORE=database SRE_LAB_ENABLED=true METRICS_ENABLED=true \
          APP_URL=http://placeholder; do
  aws ssm put-parameter --name "$P/${kv%%=*}" --type String --value "${kv#*=}" --overwrite
done
aws ssm get-parameters-by-path --path "$P" --query 'Parameters[].Name' --output table   # لازم 13 مفتاح
```

> - `APP_URL` هنصلّحه بعد ما الـ ALB يتعمل (4.8).
> - **الـ secrets بتتقري وقت start الـ task بس.** لو غيّرت parameter، الـ tasks الشغالة مش هتشوفه لحد deployment جديد (**Force new deployment**).
> - `METRICS_ENABLED=true` آمن هنا لأننا هنقفل `/metrics` على الـ ALB (4.8).

### 4.5 الـ IAM roles

**Execution role:**

1. **IAM → Roles → Create role** → Trusted entity type: **AWS service** → Service or use case: **Elastic Container Service** → **Elastic Container Service Task** → Next.
2. Permissions: `AmazonECSTaskExecutionRolePolicy` → Role name: `student-app-lab-ecs-execution` → **Create role**.
3. افتح الـ role → **Add permissions → Create inline policy → JSON** → اسم `read-app-ssm`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "ReadAppSecrets", "Effect": "Allow", "Action": "ssm:GetParameters",
      "Resource": "arn:aws:ssm:us-east-1:<ACCOUNT_ID>:parameter/student-app/lab/app/*" },
    { "Sid": "DecryptSecureStringViaSsm", "Effect": "Allow", "Action": "kms:Decrypt",
      "Resource": "arn:aws:kms:us-east-1:<ACCOUNT_ID>:key/*",
      "Condition": { "StringEquals": { "kms:ViaService": "ssm.us-east-1.amazonaws.com" } } }
  ]
}
```

4. **Trust relationships → Edit trust policy** — ضيف الـ confused-deputy guard زي الـ Terraform:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "ecs-tasks.amazonaws.com" },
    "Action": "sts:AssumeRole",
    "Condition": { "StringEquals": { "aws:SourceAccount": "<ACCOUNT_ID>" } }
  }]
}
```

> ⚠️ `AmazonECSTaskExecutionRolePolicy` بيدّي pull من **أي** ECR repo و logs على **أي** log group (`Resource: *`). الـ Terraform في [`modules/ecs-fargate/iam.tf`](../../../infra/terraform/modules/ecs-fargate/iam.tf) أضيق: repo واحد ولوج group واحد. ده الفرق بين "شغال" و "least privilege". (`kms:Decrypt` مطلوب فعلياً مع customer-managed key بس؛ مع `aws/ssm` بنحطه للتطابق مع الـ Terraform.)

**Task role:** نفس الخطوات 1 من غير أي managed policy → اسم `student-app-lab-ecs-task` → inline policy `ecs-exec` (نفس [`iam.tf`](../../../infra/terraform/modules/ecs-fargate/iam.tf): قنوات الـ Session Manager + كتابة output الـ Exec session في log group الـ app — الـ agent بيكتبه بالـ **task role**):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "EcsExecSessionManagerChannels", "Effect": "Allow",
      "Action": ["ssmmessages:CreateControlChannel", "ssmmessages:CreateDataChannel",
                 "ssmmessages:OpenControlChannel", "ssmmessages:OpenDataChannel"],
      "Resource": "*" },
    { "Sid": "EcsExecSessionLogs", "Effect": "Allow",
      "Action": ["logs:CreateLogStream", "logs:DescribeLogStreams", "logs:PutLogEvents"],
      "Resource": "arn:aws:logs:us-east-1:<ACCOUNT_ID>:log-group:/ecs/student-app-lab/app:*" },
    { "Sid": "EcsExecDescribeLogGroups", "Effect": "Allow",
      "Action": "logs:DescribeLogGroups", "Resource": "*" }
  ]
}
```

### 4.6 الـ Log group

**CloudWatch → Log groups → Create log group** → `/ecs/student-app-lab/app` · Retention: **2 weeks**. (لو سيبت الـ console يعمله أوتوماتيك هيبقى retention = Never expire → فلوس على المدى.)

### 4.7 الـ Cluster

1. **ECS → Clusters → Create cluster** → Cluster name: `student-app-lab`.
2. Infrastructure: **AWS Fargate (serverless)** بس.
3. Monitoring: **Container Insights with enhanced observability** (per-task metrics — هتحتاجها في [57](57-ecs-autoscaling-under-load.md)؛ فيه تكلفة CloudWatch زيادة).
4. Tags: `Project=student-app`، `Env=lab`، `ManagedBy=console`، `Scenario=50` → **Create**.
5. افتح الـ cluster → تاب **Infrastructure** → اتأكد إن `FARGATE` و `FARGATE_SPOT` ظاهرين كـ capacity providers.

### 4.8 الـ Target groups والـ ALB

**Target group blue** — **EC2 → Target groups → Create target group**:

| الحقل | القيمة | ليه |
|---|---|---|
| Target type | **IP addresses** | `awsvpc`: كل task ليه IP |
| Name | `student-app-lab-blue` | |
| Protocol : Port | HTTP : **8080** | بورت الـ container مباشرة (مفيش host port mapping على Fargate) |
| VPC | `student-app-lab` | |
| Health check path | `/ready` | readiness: بيعمل DB ping |
| Advanced: Healthy / Unhealthy threshold | 2 / 2 | release سيء يطلع في ~20s، وسليم ياخد traffic في ~20s |
| Timeout / Interval | 5 / 10 | |
| Success codes | 200 | |

**Next** → Register targets: **متسجّلش حاجة** (الـ ECS service هو اللي بيسجّل الـ IPs) → **Create**. بعدها افتح الـ TG → **Attributes → Edit** → Deregistration delay: **30** (الـ default 300 ثانية = كل deploy بيستنى 5 دقايق على الفاضي).

كرر نفس الحاجة لـ `student-app-lab-green` (هنستخدمه في [54](54-ecs-codedeploy-bluegreen-canary.md) و [55](55-ecs-native-bluegreen-linear-canary.md)).

**الـ ALB** — **EC2 → Load balancers → Create load balancer → Application Load Balancer**:

1. Name: `student-app-lab-alb` · Scheme: **Internet-facing** · IP address type: IPv4.
2. VPC `student-app-lab` · Mappings: الـ AZs الاتنين، الـ **public** subnets.
3. Security groups: `student-app-lab-alb` بس (شيل `default`).
4. Listeners: HTTP:80 → Default action: **Forward to** `student-app-lab-blue` → **Create load balancer**.
5. افتح الـ listener **HTTP:80 → Add rule** → Name `block-metrics` → Condition: **Path** = `/metrics` و `/metrics/*` → Action: **Return fixed response** 404، `text/plain`، body `Not Found` → Priority **1**.
6. حدّث `APP_URL`:

```bash
ALB_DNS=$(aws elbv2 describe-load-balancers --names student-app-lab-alb --query 'LoadBalancers[0].DNSName' --output text)
aws ssm put-parameter --name /student-app/lab/app/APP_URL --type String --value "http://$ALB_DNS" --overwrite
```

### 4.9 الـ Task definition

**الطريقة السريعة (ومن غير غلط): JSON من الـ repo.** القالب [`deploy/ecs/task-definition.json`](../../../deploy/ecs/task-definition.json) مكتوب بأسماء stack 50 بالظبط (اللي استخدمناها فوق):

```bash
AWS_ACCOUNT_ID=<ACCOUNT_ID> AWS_REGION=us-east-1 ENV_NAME=lab \
IMAGE_URI=<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/student-app:<SHA7> \
  bash deploy/ecs/render-taskdef.sh repo deploy/ecs/task-definition.json > td-console.json
jq '{family, cpu, memory, image: .containerDefinitions[0].image, secrets: (.containerDefinitions[0].secrets|length)}' td-console.json
```

**ECS → Task definitions → Create new task definition → Create new task definition with JSON** → الصق محتوى `td-console.json` → **Create**.

**عشان تفهم كل حقل، اعملها مرة من الـ form** (**Create new task definition**):

| الحقل في الـ console | القيمة | ملاحظة Senior |
|---|---|---|
| Task definition family | `student-app-lab-app` | الـ CI بيعمل revisions جديدة في نفس الـ family |
| Launch type | AWS Fargate | |
| Operating system/Architecture | Linux/X86_64 | الـ CI بيبني amd64 بس — ARM64 محتاج multi-arch ([56](56-ecs-capacity-providers-spot.md)) |
| Network mode | awsvpc | إجباري على Fargate |
| Task size | CPU **.5 vCPU** · Memory **1 GB** | لازم combination صالحة على Fargate |
| Task role / Task execution role | `student-app-lab-ecs-task` / `student-app-lab-ecs-execution` | |
| Container — Name | **`app`** | كل الـ pipelines (imagedefinitions.json، appspec) بتدوّر على `app` |
| Image URI | `<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/student-app:<SHA7>` | **ممنوع `latest`** — الـ rollback لازم يرجّع نفس الـ bytes |
| Essential container | Yes | |
| Port mappings | Container port **8080**، TCP، Port name `http`، App protocol HTTP | |
| Environment variables (Value) | `APP_ENV=production`، `APP_DEBUG=false`، `DEPLOY_COLOR=stable`، `LOG_LEVEL=info`، `QUEUE_CONNECTION=sync` | |
| Environment variables (**ValueFrom**) | الـ 13 مفتاح: Key = `APP_KEY`، ValueFrom = `arn:aws:ssm:us-east-1:<ACCOUNT_ID>:parameter/student-app/lab/app/APP_KEY` ... | الـ value مش بتتخزن في الـ task definition — بس الـ ARN. اللي يقرا الـ task def مش بيشوف الـ secret |
| Log collection | ✅ Amazon CloudWatch: `awslogs-group=/ecs/student-app-lab/app`، `awslogs-region=us-east-1`، `awslogs-stream-prefix=app`، `mode=non-blocking`، `max-buffer-size=25m` | `non-blocking`: لو CloudWatch اتأخر، PHP ميتعلقش وهو بيكتب على stderr (الـ trade-off: ممكن تخسر logs لو الـ buffer اتملى) |
| HealthCheck | Command: `CMD-SHELL,wget -q -O /dev/null http://127.0.0.1:8080/up \|\| exit 1` · Interval 15 · Timeout 5 · Start period 60 · Retries 3 | **`/up` مش `/ready`**: لو الـ RDS وقع ثانية، `/ready` يفشل في كل الـ tasks → ECS يقتلهم كلهم → outage أكبر من المشكلة. Readiness مكانها الـ ALB |
| Container timeouts → Stop timeout | 30 | بين الـ STOPSIGNAL (`SIGQUIT` في الـ Dockerfile) والـ SIGKILL |
| `linuxParameters.initProcessEnabled` | `false` (من الـ JSON) | الـ image بتشغّل S6 overlay ولازم يبقى PID 1 ([52](52-ecs-migrations-and-exec.md)) |

### 4.10 الـ Migrations كـ "Run task" (قبل الـ service)

**ECS → Clusters → `student-app-lab` → تاب Tasks → Run new task** (أو من صفحة الـ task definition: **Deploy → Run task**):

1. Compute configuration: **Launch type → FARGATE** (أو Capacity provider strategy → Use custom → `FARGATE` weight 1). **مش Spot**: لو الـ Spot task اتسحب في نص `ALTER TABLE` ده outage إنت عملته بإيدك.
2. Deployment configuration: Task definition `student-app-lab-app` (آخر revision) · Desired tasks: **1**.
3. Networking: VPC `student-app-lab` · Subnets: الـ public · Security group: `student-app-lab-ecs-app` · **Public IP: Turned on**.
4. **Container overrides → app → Command override**: `php,artisan,migrate,--force` (قيم مفصولة بـ comma).
5. **Create** → افتح الـ task → استنى `Stopped` → في جزء **Containers** شوف **Exit code = 0** · تاب **Logs** فيه `Running migrations` و `DONE`.

> ⚠️ "Stopped" مش معناها "نجح". لازم الـ **exit code بتاع الـ container `app`** = 0. ده بالظبط اللي [`run-migrations.sh`](../../../deploy/ecs/run-migrations.sh) بيعمله أوتوماتيك ([52](52-ecs-migrations-and-exec.md)):

```bash
SUBNETS='"subnet-<PUBLIC_A>","subnet-<PUBLIC_B>"'
NET="{\"awsvpcConfiguration\":{\"subnets\":[$SUBNETS],\"securityGroups\":[\"sg-<ECS_APP_SG>\"],\"assignPublicIp\":\"ENABLED\"}}"
AWS_REGION=us-east-1 bash deploy/ecs/run-migrations.sh --cluster student-app-lab \
  --task-definition student-app-lab-app --network-configuration "$NET"
```

### 4.11 الـ Service

**ECS → Clusters → `student-app-lab` → Services → Create**:

| القسم / الحقل | القيمة | ليه |
|---|---|---|
| Task definition family / revision | `student-app-lab-app` / LATEST | |
| Service name | `student-app-lab-app` | نفس اسم Terraform → الـ scripts والـ workflows شغالة من غير تعديل |
| Compute options | **Capacity provider strategy → Use custom**: `FARGATE` base **1** weight **0** + `FARGATE_SPOT` base 0 weight **1** (أو `FARGATE` weight 1 بس) | task واحد on-demand دايماً (floor)، الباقي Spot أرخص ~70% ([56](56-ecs-capacity-providers-spot.md)) |
| Platform version | LATEST | |
| Troubleshooting configuration | ✅ **Turn on ECS Exec** | قرار وقت start الـ task؛ لو نسيته محتاج redeploy |
| Service type / Desired tasks | Replica / **2** | واحد في كل AZ |
| Availability Zone service rebalancing | ✅ | يعيد التوزيع بعد مشكلة في AZ |
| Health check grace period | **60** | وقت boot + `php artisan optimize` قبل ما ECS يصدّق الـ ALB health checks |
| Deployment options | **Rolling update** · Min running tasks **100** % · Max running tasks **200** % | يقوّم الجديد قبل ما يشيل القديم — تفاصيل في [53](53-ecs-rolling-circuit-breaker.md) |
| Deployment failure detection | ✅ Use the Amazon ECS deployment circuit breaker · ✅ Rollback on failures | release مش بيقوم → يرجع لوحده |
| Networking | VPC `student-app-lab` · Subnets: **public** الاتنين · Security group: `student-app-lab-ecs-app` (شيل `default`) · **Public IP: Turned on** | من غير NAT، الـ public IP هو طريق الـ task لـ ECR/SSM/Logs |
| Load balancing | Application Load Balancer → **Use an existing load balancer** `student-app-lab-alb` · container `app 8080:8080` · Listener: **Use an existing listener** `80:HTTP` · Target group: **Use an existing target group** `student-app-lab-blue` | |
| Service auto scaling | سيبه (هنعمله في [57](57-ecs-autoscaling-under-load.md)) | |
| Tags | ✅ Turn on Amazon ECS managed tags · Propagate tags from: **Service** + `Project/Env/ManagedBy/Scenario` | الـ tags توصل للـ tasks (cost allocation) |

**Create** → تاب **Deployments** و **Events**: المفروض تشوف `has started 2 tasks` ثم `registered 2 targets in target-group student-app-lab-blue` ثم `has reached a steady state`.

### 4.12 Deploy لـ revision جديدة من الـ console

1. **Task definitions → `student-app-lab-app`** → اختار آخر revision → **Create new revision** → في الـ container `app` غيّر **Image URI** للـ SHA الجديد → **Create** (= revision N+1).
2. **Migrations الأول** بالـ revision الجديدة (4.10 بنفس الخطوات بس اختار revision N+1). Expand/contract ([95](95-zero-downtime-db-migrations.md)) هو اللي بيخلّي الكود القديم لسه شغال على الـ schema الجديد.
3. **Clusters → service `student-app-lab-app` → Update service** → Task definition revision: **N+1** → **Update**.
4. تاب **Deployments**: الـ deployment الجديد `In progress` → tasks جديدة → healthy في الـ TG → القديمة draining 30s → `Completed`.
5. **Force new deployment** (نفس الشاشة) = نفس الـ revision بس tasks جديدة — تستخدمه بعد تغيير SSM parameter.

## 5) الطريقة التانية: Infrastructure as Code

ده بالظبط اللي [`infra/terraform/stacks/50-ecs-fargate`](../../../infra/terraform/stacks/50-ecs-fargate/) بيعمله — الشرح الكامل في [51](51-ecs-fargate-terraform.md). كل خطوة فوق ليها مقابل:

| Console (هنا) | Terraform |
|---|---|
| 4.1 VPC | `module.network` (`enable_nat = false`) |
| 4.2 SGs | `module.alb` (SG الـ ALB) · `aws_security_group.service` · `module.rds` (SG الـ RDS) |
| 4.3 RDS + 4.4 DB_* | `module.rds` (بيكتب `DB_HOST/DB_PORT/DB_DATABASE/DB_USERNAME/DB_PASSWORD` في SSM) |
| 4.4 باقي الـ params | [`ssm.tf`](../../../infra/terraform/stacks/50-ecs-fargate/ssm.tf) |
| 4.5 roles · 4.6 logs · 4.7 cluster · 4.9 task def · 4.11 service | `module.ecs` ([`iam.tf`](../../../infra/terraform/modules/ecs-fargate/iam.tf)، [`main.tf`](../../../infra/terraform/modules/ecs-fargate/main.tf)، [`service.tf`](../../../infra/terraform/modules/ecs-fargate/service.tf)) |
| 4.8 ALB + TGs + `/metrics` rule | `module.alb` |
| 4.10 migrations | output `migration_script_command` |

## 6) الـ Deploy (نفس 4.12 بالـ CLI — اللي الـ pipelines بتعمله)

```bash
export AWS_REGION=us-east-1 ECS_CLUSTER=student-app-lab ECS_SERVICE=student-app-lab-app
IMG=<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/student-app:<NEW_SHA7>

bash deploy/ecs/render-taskdef.sh live student-app-lab-app "$IMG" > td.json     # آخر revision + image جديدة
TD_ARN=$(aws ecs register-task-definition --cli-input-json file://td.json --query taskDefinition.taskDefinitionArn --output text)
bash deploy/ecs/run-migrations.sh --task-definition "$TD_ARN"                   # الشبكة من الـ service نفسه
aws ecs update-service --cluster "$ECS_CLUSTER" --service "$ECS_SERVICE" --task-definition "$TD_ARN" >/dev/null
aws ecs wait services-stable --cluster "$ECS_CLUSTER" --services "$ECS_SERVICE"
```

## 7) التحقق (Verify)

```bash
URL="http://$ALB_DNS"
curl -s "$URL/ready" | jq                                  # {"status":"ready","checks":{"database":"ok"},"version":"<sha7>","color":"stable"}
curl -s -o /dev/null -w '%{http_code}\n' "$URL/metrics"     # 404 من الـ ALB rule
aws ecs describe-services --cluster student-app-lab --services student-app-lab-app \
  --query 'services[0].{running:runningCount,desired:desiredCount,td:taskDefinition,deployments:deployments[].rolloutState}'
TG_ARN=$(aws elbv2 describe-target-groups --names student-app-lab-blue --query 'TargetGroups[0].TargetGroupArn' --output text)
aws elbv2 describe-target-health --target-group-arn "$TG_ARN" --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State]' --output table
aws logs tail /ecs/student-app-lab/app --since 10m --follow    # JSON logs (LOG_CHANNEL=stderr)
bash deploy/scripts/probe.sh "$URL/ready" 120 0.2              # شغّله وانت بتعمل 4.12: المفروض failed: 0
```

افتح `$URL/login` في المتصفح، اعمل register واعمل student — كده الـ sessions (database) والـ RDS شغالين.

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر/التعديل | المتوقع (فين تشوفه) |
|---|---|---|
| ARN غلط لـ secret | revision فيها `ValueFrom` لـ `.../app/APP_KEYX` | الـ task يقف قبل ما الـ container يقوم: `ResourceInitializationError: unable to pull secrets or registry auth` (Task → Stopped reason) |
| Tag مش موجود | Image URI بـ `:doesnotexist` | `CannotPullContainerError ... not found`، والـ circuit breaker يرجّع |
| الـ task SG من غير rule الـ ALB | امسح inbound 8080 من `student-app-lab-ecs-app` | الـ targets `unhealthy` بـ `Request timed out`؛ بعد الـ grace period الـ service يقتلهم ويبدّلهم (loop) |
| الـ RDS SG مقفول | امسح inbound 3306 | `/up` شغال (liveness)، `/ready` = 503 `database unreachable` → الـ ALB يبطّل يبعت → 503 للمستخدم. **مفيش** restart storm لأن الـ container healthCheck على `/up` |
| Public IP off من غير NAT | Update service → Networking → Public IP off → Force new deployment | الـ tasks الجديدة: `ResourceInitializationError` (مش قادر يوصل SSM/ECR)؛ الـ circuit breaker يرجّع |
| healthCheck على `/ready` | revision بـ `.../ready` في الـ HealthCheck + اقفل الـ RDS SG | الـ tasks كلها unhealthy → تتقتل كلها → outage كامل. ده سبب `/up` |

## 9) الرجوع (Rollback)

- **من الـ console:** Service → **Update service** → Task definition revision = الـ revision القديمة (N) → Update. الـ revisions القديمة لسه موجودة (ACTIVE) ونفس الـ image بالـ SHA.
- **أوتوماتيك:** الـ circuit breaker بيرجع لآخر deployment `COMPLETED` لو الـ tasks الجديدة مش بتقوم.
- **بالـ CLI:** `aws ecs update-service --cluster student-app-lab --service student-app-lab-app --task-definition student-app-lab-app:<N>`
- ⚠️ الـ migrations مش بترجع. الـ rollback آمن بس لو الـ migration كانت expand ([95](95-zero-downtime-db-migrations.md)).

## 10) المسح (Teardown) ⚠️

**الترتيب مهم** (الـ dependencies: service ← cluster، ALB ← TGs، RDS ← SG، SGs بتشاور على بعض):

1. **ECS → service → Delete service** (✅ Force delete لو طلب) — الـ tasks بتقف والـ targets بتتشال.
2. **Tasks** — اتأكد إن مفيش tasks شغالة (`aws ecs list-tasks --cluster student-app-lab`).
3. **ECS → Clusters → `student-app-lab` → Delete cluster**.
4. **EC2 → Load balancers → `student-app-lab-alb` → Delete** ← بعده **Target groups** blue و green.
5. **RDS → `student-app-lab-mysql` → Actions → Delete** → شيل ✔ Create final snapshot، شيل ✔ Retain automated backups، اكتب `delete me` ← بعد ما يخلص: **Subnet groups → Delete**.
6. **SSM:**

```bash
aws ssm get-parameters-by-path --path /student-app/lab/app --query 'Parameters[].Name' --output text | \
  xargs -n 10 aws ssm delete-parameters --names
```

7. **IAM:** امسح `student-app-lab-ecs-execution` و `student-app-lab-ecs-task`.
8. **CloudWatch:** log group `/ecs/student-app-lab/app` + أي `/aws/ecs/containerinsights/student-app-lab/*`.
9. **Task definitions:** كل revision → **Deregister** ← بعدها **Delete** (الـ INACTIVE بس اللي بتتمسح).
10. **Security groups:** `student-app-lab-rds` ← `student-app-lab-ecs-app` ← `student-app-lab-alb` (لو رفض، فيه rule بتشاور على الـ SG أو ENI لسه موجود — استنى دقيقة).
11. **VPC → `student-app-lab-vpc` → Delete VPC** (بيمسح الـ subnets والـ IGW والـ route tables والـ S3 endpoint).

تأكد إن مفيش حاجة لسه بتعدّ فلوس:

```bash
aws ecs list-clusters
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName'
aws rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier'
aws ec2 describe-network-interfaces --filters Name=description,Values='*ecs*' --query 'NetworkInterfaces[].NetworkInterfaceId'
```

## 11) التكلفة (Cost)

| Resource | السعر التقريبي (us-east-1، تقريبي — راجع صفحة الأسعار) |
|---|---|
| Fargate on-demand (0.5 vCPU / 1 GB) | ~$0.04048/vCPU-hour + ~$0.004445/GB-hour ≈ **$0.025/ساعة لكل task** |
| Fargate Spot | خصم لحد ~70% (متغير) ≈ ~$0.008/ساعة لكل task |
| ALB | ~$0.0225/ساعة + LCU (~$0.008/LCU-hour) |
| Public IPv4 | ~$0.005/ساعة لكل IP (الـ ALB في 2 AZ + كل task) |
| RDS `db.t4g.micro` + 20 GiB gp3 | ~$0.016/ساعة + ~$0.115/GB-شهر (ممكن يبقى ضمن الـ free tier/credits حسب حسابك) |
| Container Insights enhanced + logs | سنتات/يوم في الـ lab |
| NAT gateway (لو اخترته) | ~$0.045/ساعة + ~$0.045/GB |
| **الإجمالي (2 tasks، من غير NAT)** | **≈ $0.11/ساعة ≈ $2.5–3/يوم** |

## 12) أسئلة Interview

<details><summary>إيه الفرق بين الـ execution role والـ task role؟ وإيه اللي يحصل لو حطيت صلاحيات SSM في الـ task role بدل الـ execution role؟</summary>

الـ execution role بيستخدمه الـ ECS agent قبل تشغيل الـ container: pull الـ image، يكتب logs، ويحل `secrets[].valueFrom`. الـ task role بيستخدمه الكود جوه الـ container. لو حطيت `ssm:GetParameters` في الـ task role بس، الـ task هيفشل في الـ init بـ `ResourceInitializationError` لأن الـ agent (مش التطبيق) هو اللي بيجيب الـ secrets. والعكس: أي صلاحية للتطبيق في الـ execution role مش هتوصل للكود. الفصل ده least privilege: التطبيق عندنا مالوش أي صلاحية AWS غير اللي ECS Exec محتاجه (القنوات + كتابة الـ session logs في log group واحد).

</details>

<details><summary>ليه الـ container healthCheck على `/up` والـ ALB على `/ready`؟</summary>

Liveness مقابل readiness. `/up` بيقول "الـ process عايش" — لو فشل، القتل والإعادة هي العلاج الصح. `/ready` بيقول "أقدر أخدم دلوقتي" (DB ping) — لو فشل، العلاج إنك تبطّل تبعتله traffic، مش تقتله. لو الاتنين على `/ready`، أي blip في RDS بيقتل كل الـ tasks في نفس اللحظة ويحوّل مشكلة مؤقتة لـ outage + cold start لكل الـ fleet.

</details>

<details><summary>Public subnets + public IP للـ tasks — مش ده خطر أمني؟</summary>

الـ exposure بيتحدد بالـ SG مش بوجود IP عام: الـ SG بيقبل 8080 من SG الـ ALB بس، فمحدش يقدر يفتح connection للـ task من الإنترنت. المخاطر الحقيقية: الـ egress مفتوح (data exfiltration لو اتعمل compromise)، والـ IP بيظهر في الـ inventory/scanners. في production: private subnets + NAT (egress واحد معروف وممكن تراقبه/تفلتره) أو VPC endpoints. القرار هنا cost-driven (~$32/شهر للـ NAT) ومقصود للـ lab.

</details>

<details><summary>ليه الـ migrations كـ one-off task مش في الـ entrypoint بتاع الـ container؟</summary>

لو كل replica بيعمل migrate عند الـ boot: N tasks بتتسابق على نفس الـ schema، deployment فيه 4 tasks = 4 محاولات، migration فاشلة = crash loop لكل الـ fleet الجديدة، وصعب تربط "الـ release اتعمله migrate ولا لأ". الـ one-off task بيجري **مرة واحدة**، قبل ما أي task جديد ياخد traffic، على on-demand (مش Spot)، وبـ exit code واضح يوقف الـ pipeline. عشان كده الـ image فيها `AUTORUN_LARAVEL_MIGRATION=false`.

</details>

<details><summary>غيّرت قيمة في SSM والتطبيق لسه بيقرا القديمة. ليه؟ وإيه الحل؟</summary>

ECS بيحل الـ `secrets` مرة واحدة وقت start الـ task ويحطها كـ env vars. مفيش re-read. الحل: **Force new deployment** (tasks جديدة بنفس الـ revision). لو محتاج rotation من غير restart، التطبيق نفسه لازم يقرا من SSM/Secrets Manager runtime (بالـ task role) مع cache — trade-off في التعقيد والـ latency.

</details>

<details><summary>إيه اللي بيحصل في الـ 60 ثانية الأولى من عمر task؟</summary>

ENI بتتعمل وتاخد IP → الـ execution role بيجيب الـ secrets ويسحب الـ image → الـ container بيقوم (entrypoint → `php artisan optimize` → S6 يشغّل nginx + php-fpm) → ECS بيسجّل الـ IP في الـ TG → الـ ALB يبدأ `/ready` كل 10s ويحتاج 2 ناجحين. الـ health check grace period (60s) بيمنع الـ service إنه يقتل الـ task بسبب فشل الـ health checks في الفترة دي، والـ container healthCheck `startPeriod` (60s) بيعمل نفس الحاجة للـ `/up`.

</details>

<details><summary>Fargate مقابل EC2 launch type مقابل EKS — تختار إمتى؟</summary>

Fargate: مفيش سيرفرات، تسعير بالثانية، isolation قوي — مثالي لفرق صغيرة وworkloads متغيرة. EC2 capacity provider: لما الـ utilization عالي وثابت (bin-packing أرخص)، GPUs، daemons، أو Savings Plans على EC2. EKS: لما محتاج الـ Kubernetes ecosystem (operators، GitOps، portability، multi-tenant)، والتمن control plane + تعقيد تشغيلي أكبر بكتير ([60](60-kubernetes-on-kind.md)–[62](62-eks-terraform.md)).

</details>

## 13) Checklist

- [ ] عملت الـ VPC وسلسلة الـ SGs (ALB → task → RDS) وفاهم ليه SG referencing
- [ ] عملت الـ RDS والـ 13 SSM parameter
- [ ] عملت الـ execution role والـ task role وفاهم الفرق
- [ ] عملت الـ task definition (form مرة و JSON مرة) وفاهم `/up` مقابل `/ready`
- [ ] شغّلت الـ migrations كـ Run task وتأكدت من الـ exit code
- [ ] عملت الـ service ووصلت للتطبيق من الـ ALB
- [ ] عملت deploy لـ revision جديدة و rollback وقست بـ `probe.sh`
- [ ] جرّبت الـ break-it
- [ ] عملت teardown بالترتيب وتأكدت إن مفيش حاجة باقية
