# 42 — ALB + ASG + Launch Template + ACM/Route 53

> **الهدف في سطر:** تبني الـ fleet الـ immutable بتاع stack 40: **ALB** بـ target groups blue/green و listener **weighted**، health check على `/ready` و deregistration delay، **Launch Template** بـ IMDSv2 و user data بيقرا الـ release من SSM، **ASG** بـ ELB health checks و grace period و warmup — مرة بإيدك من الـ Console ومرة `terraform apply` — وتضيف HTTPS بـ **ACM** و alias في **Route 53** من متغيرين بس.
> **المستوى:** Intermediate → Advanced · **الوقت:** ~4 ساعات · **التكلفة التقريبية:** ~$1.5–2/يوم للـ stack كله (تقريبي، راجع صفحة الأسعار)
> **بيعتمد على:** [40](40-vpc-from-scratch.md) · [41](41-rds-mysql.md) · [30 — CI (image في ECR)](30-ci-github-actions.md) · **الملفات في الـ repo:** [`stacks/40-ec2-alb-asg/main.tf`](../../../infra/terraform/stacks/40-ec2-alb-asg/main.tf) · [`variables.tf`](../../../infra/terraform/stacks/40-ec2-alb-asg/variables.tf) · [`outputs.tf`](../../../infra/terraform/stacks/40-ec2-alb-asg/outputs.tf) · [`iam.tf`](../../../infra/terraform/stacks/40-ec2-alb-asg/iam.tf) · [`ssm.tf`](../../../infra/terraform/stacks/40-ec2-alb-asg/ssm.tf) · [`dns.tf`](../../../infra/terraform/stacks/40-ec2-alb-asg/dns.tf) · [`modules/alb/main.tf`](../../../infra/terraform/modules/alb/main.tf) · [`modules/asg-app/main.tf`](../../../infra/terraform/modules/asg-app/main.tf) · [`modules/asg-app/user-data.sh.tftpl`](../../../infra/terraform/modules/asg-app/user-data.sh.tftpl)

## 1) الفكرة (Concepts)

| المصطلح | المعنى |
|---|---|
| ALB | Layer 7 load balancer؛ nodes في كل AZ (public subnets) |
| Listener | port + protocol (80/443) + **default action** + rules بأولويات |
| Target group (TG) | مجموعة targets + health check + attributes (deregistration delay، stickiness) |
| Weighted forward | action واحد بيوزّع على أكتر من TG بأوزان (0–999، لحد 5 TGs) — أساس blue/green و canary ([45](45-bluegreen-two-asgs.md)، [46](46-canary-weighted-target-groups.md)) |
| Deregistration delay (draining) | الـ target اللي بيتشال بيكمّل الـ in-flight requests لحد المدة دي ومبياخدش requests جديدة |
| Launch Template (LT) | "وصفة" الـ instance: AMI، type، SG، IAM profile، IMDS، user data. **versioned** |
| User data | سكريبت cloud-init بيجري مرة واحدة كـ root أول boot |
| ASG | بيحافظ على `desired` بين `min` و `max`، يوزّع على AZs، يبدّل الـ unhealthy |
| Health check type | `EC2` (الـ instance شغالة؟) أو **`ELB`** (الـ TG شايفها healthy؟) |
| Health check grace period | ثواني بعد الـ InService قبل ما الـ ASG يحاسب الـ instance على الـ health checks |
| Default instance warmup | ثواني قبل ما metrics الـ instance تدخل في الـ scaling، وقبل ما الـ instance refresh يكمّل |
| ACM | شهادات TLS public **ببلاش**، والـ DNS validation بيجدّدها لوحده |
| Route 53 alias | record بيشاور على الـ ALB مباشرة (بيتبع الـ IPs المتغيرة، والـ queries عليه ببلاش) |

### 1.1 الـ health check — الأرقام وليه

من [`modules/alb/main.tf`](../../../infra/terraform/modules/alb/main.tf): path **`/ready`**، port `traffic-port`، matcher `200`، interval **10s**، timeout 5s، healthy/unhealthy threshold **2/2** → release سيء بيطلع من الـ traffic في ~20s، وسليم بياخد traffic بعد ~20s من ما يبقى ready. والـ `deregistration_delay = 30` (الـ default بتاع AWS 300 = كل deploy بيستنى 5 دقايق على الفاضي).

`/ready` (بره الـ web group: مفيش session row لكل check) بيعمل `select 1` على الداتابيز → instance مش شايفة الداتابيز مبتاخدش traffic. **التمن** ([41 §8](41-rds-mysql.md)): لو الداتابيز نفسها وقعت، كل الـ targets بتفشل مرة واحدة → الـ ALB بيعمل **fail open** (يبعت لكل الـ targets)، بس الـ ASG بـ `health_check_type = "ELB"` بيبدأ يبدّلهم كلهم. حلول الـ senior: ASG على health check سطحي (`/up` أو EC2) والـ LB على العميق، أو alarm يعلّق `ReplaceUnhealthy` وقت حوادث الداتابيز. الـ repo اختار البساطة (ELB) وده نقطة نقاش ممتازة.

### 1.2 الـ release مش جوه الـ Launch Template

دي أهم فكرة في الـ stack: الـ LT **ثابت**، والـ image اللي هيشتغل في SSM:

```text
/student-app/<env>/deploy/<blue|green>/IMAGE_URI    ← Terraform بيعمله مرة (ignore_changes = [value])، والـ CI بيملكه
```

الـ user data بيقراه وقت الـ boot. فالـ release = `put-parameter` + instance جديدة ([44](44-rolling-instance-refresh.md)). الـ LT بيتغيّر بس لما الـ **infra** تتغيّر (AMI، type، user data) — وده بيعمل instance refresh أوتوماتيك من الـ `instance_refresh` block.

### 1.3 Grace period و warmup

| الإعداد | في الـ module | معناه هنا |
|---|---|---|
| `health_check_grace_period` | 120 | boot + `dnf install docker` + `docker pull` + `php artisan optimize` لازم يخلصوا قبل كده، وإلا الـ ASG يقتل instance سليمة لسه بتقوم |
| `default_instance_warmup` | 120 | الـ instance الجديدة مش بتتحسب في الـ CPU average لحد ما تسخن، والـ instance refresh مش بيكمّل قبلها |
| `wait_for_capacity_timeout` | `10m` | `terraform apply` بيستنى الـ desired يبقى InService (وهنا healthy في الـ TG) |

## 2) المعمارية (Architecture)

```text
 Internet ─► Route 53 lab.example.com (A alias, اختياري) ─► ALB student-app-lab-alb  (public subnets, SG student-app-lab-alb)
             ACM cert (DNS validation)                     :443 HTTPS (TLS13-1-2-2021-06)  ← لو domain_name
                                                           :80  → redirect 443 (أو forward لو مفيش cert)
                                                           rule prio 1: /metrics, /metrics/* → 404 fixed
                                                           default: forward weighted ┬ TG student-app-lab-blue  (w=100)
                                                                                     └ TG student-app-lab-green (w=0)
            TG: instance targets, HTTP :80, /ready 10s 2/2, dereg 30s                       │
 ┌──────────────────────────────────────────────────────────────────────────────────────────┘
 ▼
 ASG student-app-lab-blue (min 1 / desired 2 / max 4, ELB health, grace 120, warmup 120)   [ASG green لو green_enabled]
   LT student-app-lab-blue-*  (AL2023 latest أو Packer AMI, t3.micro, IMDSv2 hop 1, gp3 20 GiB encrypted,
                               profile student-app-lab-asg-app, SG student-app-lab-app: in 80 من ALB SG بس)
     user data: docker → app.env من SSM /student-app/lab/app/* → IMAGE_URI من /student-app/lab/deploy/blue/IMAGE_URI
                → docker run --name student-app -p 80:8080 --env-file app.env -e DEPLOY_COLOR=blue (awslogs)
 │ 3306 / 6379 (egress → VPC CIDR)
 ▼
 RDS student-app-lab-mysql (private) · ElastiCache (redis_enabled) · CloudWatch alarms + dashboard (observability)
```

## 3) المتطلبات (Prerequisites)

- [ ] [40](40-vpc-from-scratch.md) و [41](41-rds-mysql.md) مفهومين.
- [ ] image في ECR بـ SHA tag من [30](30-ci-github-actions.md): `aws ecr list-images --repository-name student-app --query 'imageIds[].imageTag'`.
- [ ] (اختياري لـ HTTPS) domain عندك hosted zone ليه في Route 53 (~$0.50/شهر).
- [ ] مفيش stack 20/50/60 على `env=lab`.
- الأدوات: `aws` · `terraform` · `jq` · `gh` (لمتغيرات الـ GitHub).

## 4) الطريقة الأولى: AWS Console (يدوي)

اعمل ده في VPC الـ console من [40 §4](40-vpc-from-scratch.md) (أعده لو مسحته)، وامسح كل حاجة في §10 قبل الـ Terraform (نفس الأسماء والـ SSM paths).

### 4.1 الـ Security Groups

**EC2 → Security Groups → Create security group** (VPC = `student-app-lab-vpc`):

| SG | Inbound | Outbound | يقابل في الـ Terraform |
|---|---|---|---|
| `student-app-lab-alb` | HTTP 80 و HTTPS 443 من `0.0.0.0/0` | Custom TCP **80** → `10.20.0.0/16` | `module.alb`: `ingress_cidrs` + egress `target_port` للـ VPC CIDR |
| `student-app-lab-app` | HTTP 80 — Source: SG `student-app-lab-alb` | TCP 80 و 443 → `0.0.0.0/0` · TCP 3306 و 6379 → `10.20.0.0/16` | `aws_security_group.app` + rules في `main.tf` |

> 💡 الـ ALB بيكلّم الـ instances على **80** (host port) مش 8080: الـ user data بيعمل `docker run -p 80:8080`، و stack 40 بيبعت `target_port = 80` للـ alb module.

### 4.2 الـ IAM role (نسخة من [`iam.tf`](../../../infra/terraform/stacks/40-ec2-alb-asg/iam.tf))

1. **IAM → Roles → Create role** → AWS service → EC2 → Policies: `AmazonSSMManagedInstanceCore` + `CloudWatchAgentServerPolicy` → Name: `student-app-lab-asg-app`.
2. **Add permissions → Create inline policy → JSON** (اسمها `student-app-instance`):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "EcrLogin", "Effect": "Allow", "Action": "ecr:GetAuthorizationToken", "Resource": "*" },
    { "Sid": "EcrPullAppRepo", "Effect": "Allow",
      "Action": ["ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"],
      "Resource": "arn:aws:ecr:us-east-1:<ACCOUNT_ID>:repository/student-app" },
    { "Sid": "ReadOwnParameters", "Effect": "Allow",
      "Action": ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"],
      "Resource": ["arn:aws:ssm:us-east-1:<ACCOUNT_ID>:parameter/student-app/lab",
                   "arn:aws:ssm:us-east-1:<ACCOUNT_ID>:parameter/student-app/lab/*"] },
    { "Sid": "DecryptSecureStringsViaSsm", "Effect": "Allow", "Action": "kms:Decrypt",
      "Resource": "arn:aws:kms:us-east-1:<ACCOUNT_ID>:key/*",
      "Condition": { "StringEquals": { "kms:ViaService": "ssm.us-east-1.amazonaws.com" } } }
  ]
}
```

### 4.3 الـ SSM parameters والـ log group

لو الـ parameters بتاعة `/student-app/lab/app/*` مش موجودة (APP_KEY، DB_*، SESSION_DRIVER…)، اعملهم زي [50 §4.4](50-ecs-fargate-console.md) و `DB_*` من [41](41-rds-mysql.md). وبعدين:

```bash
ACCT=$(aws sts get-caller-identity --query Account --output text)
aws ssm put-parameter --name /student-app/lab/deploy/blue/IMAGE_URI --type String \
  --value "$ACCT.dkr.ecr.us-east-1.amazonaws.com/student-app:<SHA>"
aws logs create-log-group --log-group-name /student-app/lab/app
aws logs put-retention-policy --log-group-name /student-app/lab/app --retention-in-days 7
```

### 4.4 الـ Target groups (blue و green)

**EC2 → Target groups → Create target group**:

| الحقل | القيمة | ليه |
|---|---|---|
| Target type | **Instances** | الـ ASG بيسجّل الـ instance IDs |
| Name | `student-app-lab-blue` | |
| Protocol : Port | HTTP : **80** | host port |
| VPC | `student-app-lab-vpc` | |
| Health check path | `/ready` · Advanced: port **Traffic port**، healthy/unhealthy **2/2**، timeout **5**، interval **10**، success codes **200** | |

**Next** → متسجّلش targets (الـ ASG هيسجّل) → **Create**. افتح الـ TG → **Attributes → Edit** → **Deregistration delay: 30**. كرر لـ `student-app-lab-green`.

### 4.5 الـ ALB والـ weighted listener

1. **EC2 → Load balancers → Create load balancer → Application Load Balancer**.
2. Name `student-app-lab-alb` · **Internet-facing** · IPv4 · VPC `student-app-lab-vpc` · Mappings: الـ AZs الاتنين، **public** subnets · SG: `student-app-lab-alb` بس (شيل `default`).
3. Listener **HTTP:80** → Default action **Forward to target groups** → **Add target group** مرتين: `student-app-lab-blue` weight **100**، `student-app-lab-green` weight **0** → (Target group stickiness: Off) → **Create load balancer**.
4. **Attributes → Edit** → ✅ Drop invalid header fields (`drop_invalid_header_fields = true` في الـ module) · Idle timeout 60.
5. Listener **HTTP:80 → Rules → Add rule** → Name `block-metrics` → Condition **Path** = `/metrics` و `/metrics/*` → Action **Return fixed response**: 404، `text/plain`، `Not Found` → Priority **1**.
6. `APP_URL`:

```bash
ALB_DNS=$(aws elbv2 describe-load-balancers --names student-app-lab-alb --query 'LoadBalancers[0].DNSName' --output text)
aws ssm put-parameter --name /student-app/lab/app/APP_URL --type String --value "http://$ALB_DNS" --overwrite
```

### 4.6 الـ Launch Template (و user data بنفس سكريبت الـ module)

اعمل نسخة من الـ template بالقيم بتاعة blue (من WSL أو Git Bash، في جذر الـ repo):

```bash
T=infra/terraform/modules/asg-app/user-data.sh.tftpl
sed -e '/^%{ if install_codedeploy_agent ~}$/,/^%{ endif ~}$/d' \
    -e '/^%{ if install_docker ~}$/d' -e '/^%{ endif ~}$/d' \
    -e 's#\${ssm_prefix}#/student-app/lab/app#g' \
    -e 's#\${image_parameter_name}#/student-app/lab/deploy/blue/IMAGE_URI#g' \
    -e 's#\${color}#blue#g' \
    -e 's#\${log_group_name}#/student-app/lab/app#g' \
    -e 's#\${host_port}#80#g' -e 's#\${container_port}#8080#g' \
    -e 's#\$\$#$#g' \
    "$T" > /tmp/user-data-blue.sh
bash -n /tmp/user-data-blue.sh && grep -nE 'SSM_PREFIX=|IMAGE_PARAM=|DEPLOY_COLOR=|-p 80' /tmp/user-data-blue.sh
```

(`$${…}` في الـ template = `${…}` حرفي في bash؛ و `%{ if … }` شروط Terraform — شيلنا بلوك الـ CodeDeploy agent بتاع [37](37-aws-codedeploy-ec2.md).)

**EC2 → Launch templates → Create launch template**:

| الحقل | القيمة | يقابل في `aws_launch_template.this` |
|---|---|---|
| Name | `student-app-lab-blue` · ✅ Provide guidance to help me set up a template that I can use with EC2 Auto Scaling | `name_prefix` |
| AMI | **Amazon Linux 2023** (kernel-default، x86_64) | `data.aws_ssm_parameter.al2023` (`/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64`) |
| Instance type | `t3.micro` | `instance_type` |
| Key pair | **Don't include in launch template** | `key_name = null` (Session Manager) |
| Network settings | Subnet: **Don't include** · SG: `student-app-lab-app` | `vpc_security_group_ids` |
| Storage | 20 GiB **gp3**، Encrypted ✅، Delete on termination ✅ | `block_device_mappings` |
| Resource tags | `Name=student-app-lab-blue`، `Role=app`، `Color=blue`، `Project/Env/ManagedBy=console/Scenario=42` → Resource types: Instances + Volumes + Network interfaces | `tag_specifications` (الـ ASG مش بيورّث الـ `default_tags`) |
| Advanced → IAM instance profile | `student-app-lab-asg-app` | `iam_instance_profile` |
| Advanced → Credit specification | Standard | `cpu_credits = "standard"` |
| Advanced → Metadata accessible | Enabled · **Metadata version: V2 only (token required)** · **Metadata response hop limit: 1** · **Allow tags in metadata: Enable** | `metadata_options` |
| Advanced → Detailed CloudWatch monitoring | Disable | `monitoring.enabled = var.detailed_monitoring` (default `false`؛ `true` = CPU كل دقيقة بفلوس — [48](48-autoscaling-under-load.md)) |
| Advanced → User data | محتوى `/tmp/user-data-blue.sh` | `user_data = base64encode(templatefile(...))` |

> 💡 **Hop limit 1**: الـ container على bridge network = hop زيادة → مش هيقدر يوصل لـ IMDS ويسرق credentials الـ instance role. الـ user data نفسه (على الـ host) بيوصل عادي.

### 4.7 الـ Auto Scaling group

**EC2 → Auto Scaling groups → Create Auto Scaling group**:

1. **Choose launch template**: Name `student-app-lab-blue` · LT `student-app-lab-blue` · Version: **Latest** (الـ Terraform بيثبّت رقم version — `latest_version` — وده مهم للـ rollback في [43](43-golden-ami-packer.md)).
2. **Choose instance launch options**: VPC `student-app-lab-vpc` · Subnets: الـ **public** الاتنين (cheap mode؛ الـ private + NAT = `private_instances`) · Availability Zone distribution: **Balanced best effort**.
3. **Integrate with other services**: Load balancing: **Attach to an existing load balancer** → **Choose from your load balancer target groups** → `student-app-lab-blue` · Health checks: ✅ **Turn on Elastic Load Balancing health checks** · Health check grace period: **120**.
4. **Configure group size and scaling**: Desired **2** · Min **1** · Max **4** · Automatic scaling: **Target tracking scaling policy** → Metric type **Average CPU utilization** → Target **50** ([48](48-autoscaling-under-load.md)) · Instance maintenance policy: **Prioritize availability** (launch before terminate) أو سيبه · ✅ **Enable group metrics collection within CloudWatch** · ✅ **Enable default instance warmup** = **120**.
5. Notifications: skip · Tags: `Project/Env/ManagedBy/Scenario` (Tag new instances: ⬜ — الـ LT بيحط tags الـ instance) → **Create Auto Scaling group**.

راقب **Activity** و **Instance management**، وبعدين **Target groups → `student-app-lab-blue` → Targets**: `initial` → `healthy`.

### 4.8 HTTPS بـ ACM + Route 53 (اختياري)

1. **Certificate Manager → Request certificate → Request a public certificate** → FQDN: `lab.<your-domain>` → Validation method: **DNS validation** → Key algorithm: RSA 2048 → **Request**.
2. افتح الشهادة → **Create records in Route 53** → اختار الـ hosted zone → **Create records** → استنى **Issued** (دقايق).
3. **ALB → Listeners → Add listener**: **HTTPS:443** → Default action: Forward to target groups (blue 100 / green 0) → Security policy: `ELBSecurityPolicy-TLS13-1-2-2021-06` → Certificate: من ACM → **Add**.
4. انقل rule الـ `/metrics` للـ HTTPS listener (Priority 1)، وعدّل default action بتاع **HTTP:80** → **Redirect to URL**: HTTPS، port 443، **301**.
5. **Route 53 → Hosted zones → zone → Create record**: Name `lab` · Type **A** · ✅ **Alias** → Route traffic to: **Alias to Application and Classic Load Balancer** → us-east-1 → `student-app-lab-alb` → Evaluate target health: **Yes** → **Create records**.
6. `APP_URL` = `https://lab.<your-domain>` في SSM، وبعدين instance refresh ([44](44-rolling-instance-refresh.md)) عشان الـ instances تقرا القيمة الجديدة.

## 5) الطريقة التانية: Infrastructure as Code (Terraform)

### 5.1 الـ Variables اللي تهمك هنا ([`variables.tf`](../../../infra/terraform/stacks/40-ec2-alb-asg/variables.tf))

| Variable | Default | الأثر |
|---|---|---|
| `image_tag` / `image_uri` | `"unset"` / `null` | **القيمة الأولى بس** لـ `deploy/<color>/IMAGE_URI`. الـ `check "image_is_set"` بيحذّرك لو لسه `unset` |
| `instance_type` / `arch` | `t3.micro` / `x86_64` | `arm64` محتاج `t4g` و image arm64 |
| `ami_id` / `golden_ami` | `null` / `false` | [43](43-golden-ami-packer.md) |
| `min_size` / `max_size` / `desired_capacity` | 1 / 4 / 2 | **لكل لون**. الـ desired أول مرة بس (`ignore_changes = [desired_capacity]`) |
| `green_enabled` | `false` | ASG green ([45](45-bluegreen-two-asgs.md)) |
| `blue_weight` / `green_weight` / `stickiness_duration` | 100 / 0 / 0 | الـ listener ([45](45-bluegreen-two-asgs.md)، [46](46-canary-weighted-target-groups.md)) |
| `listener_weights_managed_externally` | `false` | `true` = الـ CI بيملك الأوزان (تغييره **بيعمل recreate للـ listener**) |
| `refresh_rollback_on_alarms` | `true` | alarms الـ 5xx ratio و unhealthy hosts على الـ `instance_refresh` |
| `cpu_target` / `enable_request_scaling` / `requests_per_target` | 50 / true / 1000 | [48](48-autoscaling-under-load.md) |
| `detailed_monitoring` | `false` | EC2 metrics كل دقيقة على الـ instances (CPU scaling أسرع، تكلفة زيادة) — [48](48-autoscaling-under-load.md) |
| `spot_enabled` / `spot_instance_types` | `false` / `[]` | mixed instances + `capacity_rebalance` — [48](48-autoscaling-under-load.md) |
| `codedeploy_enabled` / `codedeploy_revision_bucket` / `codedeploy_deployment_config_name` | `false` / `""` / `null` | CodeDeploy in-place على ASG blue ([`codedeploy.tf`](../../../infra/terraform/stacks/40-ec2-alb-asg/codedeploy.tf)، bucket بيتعمل لو فاضي) — [37](37-aws-codedeploy-ec2.md) |
| `domain_name` / `hosted_zone_id` | `null` | ACM + HTTPS + alias (validation: الـ zone إجباري مع الـ domain) |
| `alarm_email` | `null` | SNS subscription (أكّد الإيميل) |
| `log_retention_days` | 7 | `/student-app/<env>/app` |
| `sre_lab_enabled` | `true` | `SRE_LAB_ENABLED` في SSM |
| `private_instances` / `single_nat` | `false` / `true` | [40](40-vpc-from-scratch.md) |

### 5.2 Apply

```bash
cd infra/terraform/stacks/40-ec2-alb-asg
cp -n terraform.tfvars.example terraform.tfvars
# عدّل: image_tag = "<SHA>"   (واختياري: domain_name / hosted_zone_id / alarm_email)
terraform init -backend-config=../../backend.hcl
terraform plan -out=tfplan
terraform apply tfplan                  # ~10 دقايق
terraform output
```

### 5.3 الـ wiring في [`main.tf`](../../../infra/terraform/stacks/40-ec2-alb-asg/main.tf)

| Block | أهم حاجة |
|---|---|
| `module "alb"` | `target_type = "instance"`، `target_port = 80`، `https_enabled = local.https_enabled` (`domain_name != null` — معروف وقت الـ plan، عكس الـ cert ARN، فينفع يتحكم في `count`)، الأوزان والـ stickiness، `weights_managed_externally` |
| `aws_security_group.app` | **SG واحد** لـ blue و green: الـ RDS/ElastiCache بيسمحوا لـ source واحد، والـ SG موجود قبل الـ ASGs (مفيش انتظار على module بيستنى الداتابيز) |
| `module "rds"` / `module "redis"` | [41](41-rds-mysql.md) / [49](49-redis-sessions-cache.md) |
| `aws_cloudwatch_log_group.app` | `/student-app/lab/app` — stream لكل `color/instance-id` |
| `local.boot_parameters` → `wait_for` | ARNs كل الـ SSM parameters اللي الـ user data بيعملها render: أول instance مش بتبوت قبلهم (بدل `depends_on` على الـ module اللي كان هيأجّل الـ AMI lookup ويطلع diff في كل plan) |
| `local.refresh_alarms` | `alb_5xx_ratio` + `unhealthy_hosts_<color>` من `module.observability` |
| `local.asg_names` | الأسماء محسوبة (مش من الـ modules) عشان الـ observability يستخدمها والـ ASGs تستخدم alarms الـ observability من غير **dependency cycle** |
| `module "asg_blue"` / `module "asg_green"` (`count = green_enabled`) | `create_security_group = false`، `host_port = 80`، `color` |
| `module "observability"` | alarms + dashboard |
| [`codedeploy.tf`](../../../infra/terraform/stacks/40-ec2-alb-asg/codedeploy.tf) (`codedeploy_enabled`) | revision bucket + CodeDeploy app + IN_PLACE deployment group على ASG/TG blue؛ أوامر الـ release في `terraform output codedeploy` ([37](37-aws-codedeploy-ec2.md)) |

وفي [`modules/asg-app/main.tf`](../../../infra/terraform/modules/asg-app/main.tf): `aws_ssm_parameter.image_uri` بـ `ignore_changes = [value]`؛ الـ LT (`update_default_version`، IMDSv2 hop 1، gp3 encrypted، `tag_specifications` من `data.aws_default_tags`)؛ الـ LT `monitoring.enabled = var.detailed_monitoring`؛ الـ ASG (`health_check_type = "ELB"`، grace/warmup 120، `capacity_rebalance = var.spot_enabled`، `enabled_metrics`، `instance_refresh` block بـ `min_healthy 50 / max_healthy 100`، `skip_matching = false`، `auto_rollback = true`، alarms)، و `ignore_changes = [desired_capacity]`.

### 5.4 الـ user data سطر بسطر ([`user-data.sh.tftpl`](../../../infra/terraform/modules/asg-app/user-data.sh.tftpl))

| # | الخطوة | التفاصيل | لو فشلت |
|---|---|---|---|
| 0 | `set -euo pipefail` | أي أمر يفشل يوقف السكريبت | الـ log في `/var/log/cloud-init-output.log` |
| 1 | IMDSv2 token | `PUT /latest/api/token` (TTL 300) → `region` و `instance-id` | — |
| 2 | `retry()` | 10 محاولات × 6s: الـ instance profile والـ parameters الجديدة ممكن يتأخروا ثواني وقت الـ boot | `giving up: …` |
| 3 | Docker | `dnf -y install docker` (لو مش `golden_ami`) ثم `systemctl enable --now docker` | — |
| 3b | CodeDeploy agent + compose | بس لو `install_codedeploy_agent` ([37](37-aws-codedeploy-ec2.md)) | — |
| 4 | `render_env` | `get-parameters-by-path /student-app/lab/app/ --recursive --with-decryption` → `KEY=value` → `install -m 600 … /opt/student-app/app.env` (نفس منطق [`render-env-from-ssm.sh`](../../../deploy/ec2/render-env-from-ssm.sh)) | لو فاضي: `no parameters under …` + retry |
| 5 | الـ release | `get-parameter /student-app/lab/deploy/<color>/IMAGE_URI` | — |
| 6 | ECR login + pull | login بس لو الـ registry `*.dkr.ecr.*.amazonaws.com`؛ `retry docker pull` | tag مش موجود → 10 محاولات ثم exit → مفيش container → unhealthy |
| 7 | الـ logs | `awslogs` على `/student-app/lab/app`، stream `<color>/<instance-id>` (وإلا json-file) | — |
| 8 | `docker run` | `--name student-app --restart unless-stopped -p 80:8080 --env-file app.env -e DEPLOY_COLOR=<color> --stop-signal SIGQUIT --stop-timeout 30` | الـ container لو وقع بيتعاد (restart policy) |
| 9 | `CURRENT_RELEASE` | `echo "$IMAGE" > /opt/student-app/CURRENT_RELEASE` | — |

مفيش migrations هنا (CONVENTIONS §2: مرة لكل release، مش لكل replica).

## 6) الـ Deploy (أول release)

```bash
cd infra/terraform/stacks/40-ec2-alb-asg
export AWS_REGION=us-east-1
APP_URL=$(terraform output -raw app_url)
TOKEN=$(terraform output -raw sre_lab_token)

# 1) الـ migrations مرة واحدة (أو restore من 41 §6 الأول)
eval "$(terraform output -raw migrate_command)"
aws ssm list-command-invocations --details --max-items 1 \
  --query 'CommandInvocations[0].{status:Status,out:CommandPlugins[0].Output}' --output json

# 2) داتا للـ load tests (loadtest1..20@example.com / password) — container مؤقت بالـ image نفسها
IID=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names student-app-lab-blue \
        --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`]|[0].InstanceId' --output text)
aws ssm send-command --instance-ids "$IID" --document-name AWS-RunShellScript --parameters \
  'commands=["IMG=$(cat /opt/student-app/CURRENT_RELEASE)","docker run --rm --env-file /opt/student-app/app.env -e LOADTEST_USERS=20 -e LOADTEST_STUDENTS_PER_USER=100 $IMG php artisan db:seed --class=LoadTestSeeder --force"]'

# 3) متغيرات GitHub لـ deploy-asg.yml (44–46) من الـ outputs
gh variable set ALB_LISTENER_ARN --body "$(terraform output -raw listener_arn)"
gh variable set TG_BLUE_ARN      --body "$(terraform output -json target_group_arns | jq -r .blue)"
gh variable set TG_GREEN_ARN     --body "$(terraform output -json target_group_arns | jq -r .green)"
gh variable set APP_URL --env lab --body "$APP_URL"
gh secret set SRE_LAB_TOKEN --body "$TOKEN"
```

> 💡 الـ seed بـ `docker run --rm` (container جديد بيعمل `optimize` بالـ env الجديد) مش `docker exec` على الـ container الشغال: الـ config هناك متخزن cache من وقت الـ boot، فـ `-e LOADTEST_USERS` مش هيأثر.

## 7) التحقق (Verify)

```bash
curl -s "$APP_URL/ready" | jq .
curl -s -o /dev/null -w '%{http_code}\n' "$APP_URL/metrics"                 # 404 من الـ ALB (rule priority 1)
curl -s -H "X-Lab-Token: $TOKEN" "$APP_URL/sre-lab/version" | jq .          # hostname = الـ container ID
bash deploy/scripts/version-split.sh "$APP_URL/sre-lab/version" 40 "X-Lab-Token: $TOKEN"
aws elbv2 describe-target-health --target-group-arn "$(terraform output -json target_group_arns | jq -r .blue)" \
  --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State,TargetHealth.Reason]' --output table
aws autoscaling describe-scaling-activities --auto-scaling-group-name student-app-lab-blue --max-items 5 \
  --query 'Activities[].[StartTime,StatusCode,Description]' --output table
aws logs tail /student-app/lab/app --since 10m --format short | head -20
echo "$(terraform output -raw dashboard_url)"
```

المفروض: `{"status":"ready","checks":{"database":"ok"},"version":"<sha>","color":"blue"}`، الـ `/metrics` = 404، 2 targets `healthy` في AZs مختلفة، والـ dashboard فيه requests/latency/targets.

## 8) اكسرها (Break it): تمرين على الأعطال

شغّل الـ probe: `bash deploy/scripts/probe.sh "$APP_URL/ready" 0 0.2`.

| التمرين | الأمر | المتوقع |
|---|---|---|
| Instance ماتت فجأة | `aws ec2 terminate-instances --instance-ids <IID>` (أو FIS بـ [`asg-terminate-one-instance.json`](../../../observability/fis/asg-terminate-one-instance.json) — بيستهدف `student-app-lab-blue` — [75](75-chaos-engineering-fis.md)) | الـ ALB بيطلّعها (أو الـ ASG بيلاحظ) → replacement في ~2–3 دقايق؛ الـ probe: عدد قليل من 502 أو صفر |
| Drain يدوي لـ instance | `curl -X POST -H "X-Lab-Token: $TOKEN" "$APP_URL/sre-lab/unready"` | الـ instance اللي ردّت `/ready` = 503 → unhealthy في ~20s → الـ ASG (ELB health) **بيبدّلها**. ده الفرق بين readiness في K8s (مش بيعمل restart) و ELB health هنا |
| Release مش موجود | `aws ssm put-parameter --name /student-app/lab/deploy/blue/IMAGE_URI --value <acct>.dkr.ecr.us-east-1.amazonaws.com/student-app:doesnotexist --overwrite` + terminate instance | الـ user data: `retry docker pull` 10 مرات ثم exit → unhealthy → الـ ASG يبدّل ويعيد… loop. اقرا `/var/log/cloud-init-output.log` من Session Manager. رجّع الـ SHA الصح |
| Grace period قصير | Console: ASG → Edit → Health check grace period = **10** + terminate instance | الـ instance بتتقتل قبل ما تخلص boot (لو الـ ELB لحق يعلّمها unhealthy) → churn. رجّعه 120 (الـ Terraform هيرجّعه في أول apply) |
| Deep health cascade | [41 §8](41-rds-mysql.md) | كل الـ fleet بيتبدّل بسبب الداتابيز |

## 9) الرجوع (Rollback)

- **Infra:** `git revert` + `terraform apply`، أو الـ `instance_refresh` بيعمل auto rollback لو LT جديد كسر الـ alarms ([43](43-golden-ami-packer.md)).
- **Release:** [44](44-rolling-instance-refresh.md) (pointer + refresh) أو [45](45-bluegreen-two-asgs.md) (flip weights).
- **Drift يدوي** (grace period، SG، listener): `terraform plan` يوريك، `terraform apply` يرجّع.

## 10) المسح (Teardown) ⚠️

**Console** (بالترتيب): ASG `student-app-lab-blue` → **Delete** (بيقفل الـ instances) → Launch template → Load balancer → Target groups → Route 53 alias + validation CNAME → ACM certificate → Security groups → IAM role → log group → SSM parameters اللي عملتها (`/student-app/lab/deploy/*` و `/student-app/lab/app/*`).

**Terraform:**

```bash
cd infra/terraform/stacks/40-ec2-alb-asg
terraform destroy
aws resourcegroupstaggingapi get-resources --tag-filters Key=Project,Values=student-app --query 'ResourceTagMappingList[].ResourceARN'
aws ssm get-parameters-by-path --path /student-app/lab --recursive --query 'Parameters[].Name'
```

> ⚠️ الـ resource groups API ممكن يفضل يرجّع ARNs لثواني بعد المسح. والـ hosted zone بتاعتك نفسها مش من الـ stack (بتفضل).

## 11) التكلفة (Cost)

| Resource | السعر التقريبي (us-east-1 — تقريبي، راجع صفحة الأسعار) |
|---|---|
| ALB | ~$0.0225/ساعة + LCU (~$0.008/LCU-hour) + public IPv4 لكل AZ |
| 2 × `t3.micro` | ~$0.0104/ساعة لكل واحدة + public IPv4 ~$0.005/ساعة + gp3 20 GiB |
| RDS `db.t4g.micro` | [41](41-rds-mysql.md) (~$0.016/ساعة) |
| CloudWatch alarms (~14، الـ metric math بيتحسب لكل metric) + dashboard | ~$3/شهر |
| ACM public certificate | مجاني |
| Route 53 hosted zone | ~$0.50/شهر (الـ alias queries للـ ALB مجانية) |
| **الإجمالي** | **≈ $0.08/ساعة ≈ $2/يوم** ([README الـ stack](../../../infra/terraform/stacks/40-ec2-alb-asg/README.md)) |

## 12) أسئلة Interview

<details><summary>ASG health check type: EC2 ولا ELB؟</summary>

EC2 بيشوف الـ instance status checks بس (الـ VM شغالة؟) — app واقع جوه instance سليمة هيفضل في الـ fleet. ELB بيضيف رأي الـ target group، فالـ app اللي مش ready بيتبدّل. التمن: health check عميق (DB) + ELB = cascade لو الـ dependency وقعت. الحل المتوازن: ELB health على endpoint بيعكس صحة الـ instance نفسها، والـ dependency failures تتعالج بـ alarms، مش بـ replacement.

</details>

<details><summary>إيه اللي بيحصل بالظبط لما instance تتشال من الـ TG؟</summary>

الـ target بيدخل `draining`: الـ ALB يبطّل يبعتله requests جديدة ويستنى الـ in-flight لحد `deregistration_delay` (30s هنا). الـ ASG بيستنى الـ draining قبل الـ terminate. وبعدين الـ shutdown بيبعت للـ container `SIGQUIT` (graceful PHP-FPM) بـ timeout 30s. لو الـ requests أطول من الـ delay هتتقطع → ظبّط الرقم على أطول request حقيقي، مش الـ default 300.

</details>

<details><summary>ليه الـ image في SSM مش في الـ Launch Template؟</summary>

عشان release الـ app يبقى عملية خفيفة (put-parameter + refresh) ومنفصلة عن تغييرات الـ infra (AMI/type/user data)، و Terraform ميعملش rollback صامت لـ production في أول apply بعد CI deploy (`ignore_changes`). التمن: الـ LT مش بيوصف الـ release، فـ AWS auto rollback مش هيرجّع الـ image ([44](44-rolling-instance-refresh.md))، ولازم تتبّع التاريخ بـ `get-parameter-history`.

</details>

<details><summary>IMDSv2 و hop limit 1 بيحموا من إيه؟</summary>

IMDSv2 بيحتاج PUT بـ token قبل أي GET → SSRF بسيط (GET لـ `169.254.169.254`) مبيقدرش يسرق الـ credentials. الـ hop limit 1 بيخلّي رد الـ token مبيعدّيش أكتر من hop واحد → الـ containers على bridge network مش بتوصل لـ IMDS خالص، فـ RCE في الـ app مبيدّيش credentials الـ instance role.

</details>

<details><summary>Grace period مقابل instance warmup؟</summary>

الـ grace period بيحمي الـ instance من الـ **health checks** وهي بتبوت (من غير ما يتقتل قبل ما يقوم). الـ warmup بيأثر على الـ **metrics والـ pacing**: الـ instance مش بتدخل في الـ CPU average لحد ما تسخن (عشان scaling ميعملش overshoot)، والـ instance refresh مش بيكمّل للدفعة الجاية قبلها. الاتنين لازم ≥ وقت الـ boot الحقيقي (قيسه — [43](43-golden-ami-packer.md)).

</details>

<details><summary>ACM DNS validation مقابل email؟ وليه alias مش CNAME؟</summary>

DNS validation = CNAME ثابت؛ طول ما هو موجود ACM بيجدّد الشهادة لوحده (الـ `create_before_destroy` في `dns.tf` بيضمن شهادة بديلة قبل ما الـ listener يسيب القديمة). Email محتاج إنسان كل renewal. والـ alias A record بيشاور على الـ ALB كـ AWS resource: بيشتغل على zone apex (CNAME مينفعش هناك)، الـ queries ببلاش، و `evaluate_target_health` بيدخل في الـ DNS failover.

</details>

<details><summary>ليه الـ ALB على `target_port = 80` مش 8080؟</summary>

مع instance targets، الـ ALB بيكلّم الـ host port. الـ container بيسمع 8080 جوه، والـ user data بيعمل `-p 80:8080`. على ECS/EKS (ip targets) الـ ALB بيكلّم الـ container IP على 8080 مباشرة — عشان كده الـ module default 8080 و stack 40 بيبعت 80. لو اتلخبطوا: كل الـ targets unhealthy بـ `Target.FailedHealthChecks` / timeout.

</details>

## 13) Checklist

- [ ] بنيت SGs + role + TGs + ALB weighted + LT + ASG من الـ console، وشفت الـ targets بقت healthy
- [ ] عملت render للـ user data من الـ template وفهمت كل خطوة
- [ ] عملت `terraform apply` لـ stack 40 وقارنت الـ resources بالـ console
- [ ] شغّلت الـ migrations والـ seed وظبطت متغيرات GitHub من الـ outputs
- [ ] (اختياري) HTTPS بـ ACM + Route 53 alias
- [ ] جرّبت terminate و drain و release مكسور وقرأت `cloud-init-output.log`
- [ ] عملت teardown (console و Terraform)
