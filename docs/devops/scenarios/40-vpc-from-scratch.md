# 40 — VPC من الصفر

> **الهدف في سطر:** تبني شبكة production-grade بإيدك: تخطيط الـ CIDR، public/private subnets على 2 AZ، Internet Gateway، NAT (واحد ولا لكل AZ؟ وبكام؟)، route tables، S3 gateway endpoint، والفرق الحقيقي بين Security Group و NACL — مرة من الـ **VPC wizard** ومرة من [`modules/network`](../../../infra/terraform/modules/network/main.tf) — وتفهم ليه stack 40 بيشتغل افتراضياً **من غير NAT**.
> **المستوى:** Intermediate · **الوقت:** ~2–3 ساعات · **التكلفة التقريبية:** مجاني من غير NAT (NAT ≈ $1.1/يوم لكل واحد + data — تقريبي، راجع صفحة الأسعار)
> **بيعتمد على:** [02 — تجهيز حساب AWS](02-aws-account-setup.md) · [20 — EC2 + Compose](20-ec2-compose-console.md) · **الملفات في الـ repo:** [`modules/network/main.tf`](../../../infra/terraform/modules/network/main.tf) · [`modules/network/variables.tf`](../../../infra/terraform/modules/network/variables.tf) · [`modules/network/outputs.tf`](../../../infra/terraform/modules/network/outputs.tf) · [`stacks/40-ec2-alb-asg/main.tf`](../../../infra/terraform/stacks/40-ec2-alb-asg/main.tf) · [`stacks/40-ec2-alb-asg/variables.tf`](../../../infra/terraform/stacks/40-ec2-alb-asg/variables.tf)

## 1) الفكرة (Concepts)

في [20](20-ec2-compose-console.md) استخدمنا الـ **Default VPC**: كل الـ subnets فيها public، ومفيش مكان "مستخبي" تحط فيه الداتابيز. من السيناريو ده لحد [49](49-redis-sessions-cache.md) كل حاجة (ALB، ASG، RDS، ElastiCache) هتعيش في VPC إحنا مصممينه، فلازم تفهم كل طبقة فيه.

| المصطلح | المعنى |
|---|---|
| VPC | شبكة معزولة ليك في Region واحدة، ليها IPv4 CIDR (هنا `10.20.0.0/16` = 65,536 IP) |
| Subnet | جزء من الـ CIDR في **AZ واحدة بس**. AWS بتحجز **5 IPs** في كل subnet (أول 4 وآخر واحد) |
| Route table | بتقرر الـ packet الخارج من الـ subnet يروح فين. كل subnet مربوطة بـ route table واحدة |
| Internet Gateway (IGW) | باب الـ VPC على الإنترنت (في الاتجاهين). مجاني |
| **Public subnet** | subnet الـ route table بتاعتها فيها `0.0.0.0/0 → igw-…`. **ده التعريف الوحيد** — مش الاسم ولا الـ tag |
| Private subnet | مفيش route للـ IGW. لو عايزة تطلع للإنترنت (outbound بس) يبقى عن طريق **NAT gateway** |
| NAT gateway | بيعمل SNAT للـ private subnets عشان تطلع للإنترنت من غير ما حد يقدر يدخل عليها. **بفلوس كل ساعة + كل GB** |
| Gateway endpoint | route في الـ route table لـ S3/DynamoDB من غير إنترنت ومن غير NAT. **مجاني** |
| Interface endpoint | ENI جوه الـ subnet لخدمة AWS (SSM، ECR API، Logs…). ~$7/شهر لكل AZ لكل endpoint |
| Security Group (SG) | firewall **stateful** على مستوى الـ ENI، allow بس |
| NACL | firewall **stateless** على مستوى الـ subnet، allow و deny بترتيب الأرقام |
| VPC Flow Logs | سجل metadata لكل flow (ACCEPT/REJECT) على VPC/subnet/ENI — أداة debugging وأمان |

### 1.1 تخطيط الـ CIDR (اللي الـ module بيعمله بالظبط)

الـ module بيستخدم `cidrsubnet(var.cidr, var.subnet_newbits, i)` بـ `subnet_newbits = 4` → كل subnet **/20** (4,096 IP − 5 محجوزين = **4,091**):

| Subnet | الحساب | الناتج (الافتراضي `10.20.0.0/16`) |
|---|---|---|
| public AZ-a | `cidrsubnet(cidr, 4, 0)` | `10.20.0.0/20` |
| public AZ-b | `cidrsubnet(cidr, 4, 1)` | `10.20.16.0/20` |
| private AZ-a | `cidrsubnet(cidr, 4, 0 + 2^3)` = index 8 | `10.20.128.0/20` |
| private AZ-b | `cidrsubnet(cidr, 4, 1 + 8)` = index 9 | `10.20.144.0/20` |

الـ private بتبدأ من **نص الـ VPC** (`i + pow(2, subnet_newbits - 1)`) — عشان لو زوّدت `az_count` لـ 3 أو 4 بعدين، الـ subnet الجديدة تاخد index 2/3 (أو 10/11) ومفيش subnet موجودة يتغيّر رقمها (تغيير CIDR بتاع subnet = replace = كل اللي فيها يتمسح).

قواعد الـ senior في الـ CIDR:
- **متداخلش** مع أي شبكة ممكن تتوصل بيها يوم (VPN للمكتب، VPC peering، Transit Gateway، on-prem). عشان كده الـ stacks واخدة `10.20` (20/40)، `10.50` (50)، `10.60` (60). ملحوظة: 20 و 40 الاتنين `10.20.0.0/16` — ده مقبول لأنهم عمرهم ما بيشتغلوا مع بعض على نفس الـ env، بس مينفعش تعملهم peering.
- **كبّر من الأول**: `/16` + subnets `/20` مريحين جداً لـ EC2، بس على EKS كل pod بياخد IP من الـ VPC ([62](62-eks-terraform.md)) — وده سبب تعليق الـ module على الـ `/16`.
- لو الـ IPs خلصت: تقدر تضيف **secondary CIDR** للـ VPC، بس مش تكبّر subnet موجودة.

### 1.2 NAT: واحد ولا لكل AZ؟

| الاختيار | في الـ module | التكلفة (تقريبي) | الـ failure domain |
|---|---|---|---|
| مفيش NAT | `enable_nat = false` (**الافتراضي**) | $0 | الـ private subnets ملهاش إنترنت خالص |
| NAT واحد مشترك | `enable_nat = true`, `single_nat = true` | ~$0.045/ساعة ≈ $32/شهر + $0.045/GB | لو الـ AZ بتاعة الـ NAT وقعت، الـ private subnets في الـ AZ التانية برضه ملهاش إنترنت. + **cross-AZ data** من الـ AZ التانية للـ NAT |
| NAT لكل AZ | `single_nat = false` | نفس الرقم × `az_count` | كل AZ مستقلة (الـ HA الحقيقي)؛ عشان كده الـ module عامل **route table لكل private subnet** |
| Regional NAT gateway | مش في الـ module | راجع صفحة VPC pricing | ميزة جديدة (2025): NAT واحد بـ "Availability mode: Regional" بيتمدد لوحده على الـ AZs اللي فيها workloads، ومش محتاج public subnet. تمرين: قارنه بالـ zonal |

**قرار stack 40** ([`variables.tf`](../../../infra/terraform/stacks/40-ec2-alb-asg/variables.tf)): `private_instances = false` افتراضياً → الـ app instances في الـ **public** subnets بـ public IP، بس الـ SG بتاعها بيسمح بـ port 80 من SG الـ ALB **بس** → محدش يقدر يوصلها من بره، ومفيش NAT (توفير ~$32/شهر). `private_instances = true` → الـ instances في الـ private subnets + NAT (`enable_nat = var.private_instances`) = الـ production layout.

| | public + SG (الـ lab) | private + NAT (production) |
|---|---|---|
| مين يقدر يفتح connection للـ instance | محدش (SG) | محدش (مفيش route أصلاً) |
| لو حد غلط في الـ SG بعدين | الـ instance مكشوفة | لسه مش reachable |
| الـ egress IP | IP كل instance (بيتغيّر) | IP الـ NAT ثابت (allow-list عند طرف تالت: `nat_public_ips` output) |
| التكلفة | $0.005/ساعة لكل public IPv4 | NAT + data processing |

### 1.3 الـ S3 gateway endpoint (مجاني ومهم)

`enable_s3_endpoint = true` افتراضياً، ومربوط على **كل** الـ route tables (public + private). ليه؟ الـ **image layers بتاعة ECR بتتخزن في S3**: من غيره، كل `docker pull` من private subnet بيعدّي على الـ NAT وبتدفع $0.045/GB processing. مع الـ endpoint، الـ layers بتنزل مباشرة. ⚠️ ده بيغطي الـ layers بس — الـ ECR API نفسه (`api.ecr`، `*.dkr.ecr`) و SSM و CloudWatch Logs محتاجين NAT أو interface endpoints.

### 1.4 Security Group مقابل NACL

| | Security Group | NACL |
|---|---|---|
| المستوى | ENI (instance، ALB، RDS…) | subnet |
| الحالة | **stateful**: الرد بيرجع لوحده | **stateless**: لازم تسمح بالرد صراحة (ephemeral ports 1024–65535) |
| القواعد | allow بس | allow + **deny** |
| التقييم | كل القواعد مع بعض | بالترتيب (أقل رقم الأول)، أول match يكسب |
| المرجع | ممكن يشاور على **SG تاني** (`referenced_security_group_id`) | CIDRs بس |
| في الـ repo | سلسلة ALB → app → RDS/Redis | الـ default NACL (allow all) — مقصود |

الـ module كمان بيعمل [`aws_default_security_group`](../../../infra/terraform/modules/network/main.tf) **من غير rules** → الـ default SG بقى deny-all (CIS 5.4)، فأي resource حد نسي يحدد له SG مش هياخد صلاحيات بالغلط.

## 2) المعمارية (Architecture)

```text
 VPC student-app-lab  10.20.0.0/16   (enable_dns_support + enable_dns_hostnames)
 ┌──────────────────────────────── us-east-1a ─────────┬──────────────── us-east-1b ─────────────┐
 │ public-us-east-1a  10.20.0.0/20                     │ public-us-east-1b  10.20.16.0/20         │
 │   ALB node · (cheap mode) app instances + public IP │   ALB node · app instances               │
 │   [NAT-a]  (enable_nat)                             │   [NAT-b]  (enable_nat && !single_nat)   │
 │      │ rtb student-app-lab-public: 0.0.0.0/0 → IGW  ─┼─ (route table واحدة للـ public)          │
 ├─────────────────────────────────────────────────────┼──────────────────────────────────────────┤
 │ private-us-east-1a 10.20.128.0/20                   │ private-us-east-1b 10.20.144.0/20        │
 │   RDS · ElastiCache · (private_instances) app       │   RDS standby (Multi-AZ) · app           │
 │   rtb private-us-east-1a: 0.0.0.0/0 → NAT-a (opt.)  │   rtb private-us-east-1b: → NAT-b أو NAT-a│
 └─────────────────────────────────────────────────────┴──────────────────────────────────────────┘
        ▲ IGW (student-app-lab)                 S3 gateway endpoint ── prefix list على كل الـ route tables
        │
     Internet
 default SG = deny all (student-app-lab-default-deny) · NACL = default (allow all)
```

## 3) المتطلبات (Prerequisites)

- [ ] الحساب متجهّز ([02](02-aws-account-setup.md)) و Budget alert شغال.
- [ ] `infra/terraform/backend.hcl` موجود (من الـ bootstrap).
- [ ] **مفيش** stack 20/50/60 شغال على `env=lab` (الـ SSM paths مشتركة — [README](../../../infra/terraform/README.md)).
- الأدوات: `aws` · `terraform >= 1.10` · `jq`.

## 4) الطريقة الأولى: AWS Console (يدوي)

### 4.1 الـ VPC wizard

1. **VPC → Your VPCs → Create VPC**.
2. **Resources to create: VPC and more**.
3. **Name tag auto-generation**: ✅ → `student-app-lab` (الـ wizard هيسمّي كل حاجة `student-app-lab-subnet-public1-us-east-1a`… إلخ).
4. **IPv4 CIDR block**: `10.20.0.0/16` · **IPv6 CIDR block**: No IPv6 CIDR block · **Tenancy**: Default.
5. **Number of Availability Zones (AZs)**: **2** (افتح **Customize AZs** واختار `us-east-1a` و `us-east-1b`).
6. **Number of public subnets**: 2 · **Number of private subnets**: 2.
7. افتح **Customize subnets CIDR blocks** وحط نفس أرقام الـ module: public `10.20.0.0/20` و `10.20.16.0/20`، private `10.20.128.0/20` و `10.20.144.0/20`.
   (الـ wizard افتراضياً بيعمل `/20` متتالية — هنا بنقلّد الـ module عشان تقارن بالـ Terraform بعدين.)
8. **NAT gateways ($)**: **None**. (الخيارات التانية: *In 1 AZ* = `single_nat`، *1 per AZ* = HA؛ ولو ظهرلك خيار regional فده الـ regional NAT gateway من §1.2. الـ $ جنب الاسم مش ديكور.)
9. **VPC endpoints**: **S3 Gateway**.
10. **DNS options**: ✅ Enable DNS hostnames · ✅ Enable DNS resolution (RDS/ElastiCache endpoints محتاجينهم).
11. **Additional tags**: `Project=student-app`، `Env=lab`، `ManagedBy=console`، `Scenario=40`.
12. بص على الـ **Preview** (الخطوط المتقطعة = traffic للـ IGW/NAT/endpoint) → **Create VPC**.

### 4.2 اتفرّج على اللي اتعمل وصلّح الناقص

1. **Your VPCs → `student-app-lab-vpc` → Resource map**: هتشوف route table للـ public (مربوطة بالـ 2 public subnets) و **route table لكل private subnet** — نفس فكرة الـ module بالظبط (عشان NAT per AZ ممكن بعدين).
2. **Route tables → `…-rtb-public`** → Routes: `10.20.0.0/16 → local` و `0.0.0.0/0 → igw-…` و `pl-… → vpce-…` (الـ S3 prefix list). الـ private: `local` + `pl-…` بس.
3. **Subnets → كل public subnet → Actions → Edit subnet settings** → ✅ **Enable auto-assign public IPv4 address** (الـ module بيعمل `map_public_ip_on_launch = true`؛ الـ wizard مش بيعملها).
4. **Security groups →** الـ `default` بتاع الـ VPC الجديد → **Inbound rules → Edit** → امسح الـ rule → **Outbound rules → Edit** → امسح الـ rule. (ده اللي `aws_default_security_group` بيعمله.)

### 4.3 VPC Flow Logs (اختياري، بس اعمله مرة)

1. **CloudWatch → Log groups → Create log group**: `/student-app/lab/vpc-flow-logs`، Retention: **3 days**.
2. **Your VPCs → `student-app-lab-vpc` → Flow logs → Create flow log**:
   Filter: **Reject** (أرخص، وكفاية للـ debugging) · Maximum aggregation interval: 1 minute · Destination: CloudWatch Logs → الـ log group · IAM role: **Create new** (أو اختار role بـ trust لـ `vpc-flow-logs.amazonaws.com`) → **Create flow log**.
3. بعد ما تعمل stack 40 (لو سبته)، Logs Insights:

```text
fields @timestamp, srcAddr, dstAddr, dstPort, action
| filter action = "REJECT"
| stats count(*) as rejects by dstPort
| sort rejects desc
| limit 20
```

> 💡 الـ Flow Logs مش في الـ module عن قصد (تكلفة ingestion على كل GB). في production شغّلها على S3 (أرخص) وحلّلها بـ Athena.

### 4.4 امسح الـ VPC بتاع الـ console قبل الـ Terraform

**Your VPCs → `student-app-lab-vpc` → Actions → Delete VPC** (بيمسح الـ subnets والـ route tables والـ IGW والـ endpoint معاه). لو عملت NAT: امسحه الأول من **NAT gateways** واستنى `Deleted`، وبعدين **Elastic IPs → Release**. الـ Flow log والـ log group والـ IAM role امسحهم بإيدك.

## 5) الطريقة التانية: Infrastructure as Code (Terraform)

الـ network module متستخدم جوه stack 40 كـ `module "network"` ([`main.tf`](../../../infra/terraform/stacks/40-ec2-alb-asg/main.tf)):

```hcl
module "network" {
  source     = "../../modules/network"
  name       = local.name           # student-app-lab
  cidr       = var.vpc_cidr         # 10.20.0.0/16
  az_count   = 2                    # ALB and the RDS subnet group both need two AZs
  enable_nat = var.private_instances
  single_nat = var.single_nat
}
```

### 5.1 الـ Variables

| مكان | Variable | Default | الأثر |
|---|---|---|---|
| stack 40 | `vpc_cidr` | `10.20.0.0/16` | → `module.network.cidr` |
| stack 40 | `private_instances` | `false` | → `enable_nat` + الـ ASG يستخدم `private_subnet_ids` بدل `public_subnet_ids` (`local.app_subnet_ids`) |
| stack 40 | `single_nat` | `true` | NAT واحد ولا لكل AZ (ليه معنى بس مع `private_instances`) |
| module | `az_count` | `2` (stack 40 مثبّتها) | 1–4 (validation) |
| module | `enable_s3_endpoint` | `true` | الـ S3 gateway endpoint |
| module | `subnet_newbits` | `4` | `/20` على `/16` |
| module | `public_subnet_tags` / `private_subnet_tags` | `{}` | tags زيادة (الـ module بيحط `kubernetes.io/role/elb` و `internal-elb` للـ EKS LBC — مالهمش أثر هنا) |

Outputs: `vpc_id`، `vpc_cidr`، `azs`، `public_subnet_ids`، `private_subnet_ids`، `public_route_table_id`، `private_route_table_ids`، `nat_public_ips`.

### 5.2 جرّب الحسابات قبل الـ apply

```bash
cd infra/terraform/stacks/40-ec2-alb-asg
cp -n terraform.tfvars.example terraform.tfvars      # حط image_tag لـ SHA موجود في ECR (هتحتاجه في 42)
terraform init -backend-config=../../backend.hcl
terraform console <<'EOF'
cidrsubnet("10.20.0.0/16", 4, 0)
cidrsubnet("10.20.0.0/16", 4, 8)
[for i in range(2) : cidrsubnet("10.20.0.0/16", 4, i + pow(2, 3))]
EOF
```

### 5.3 الشبكة لوحدها (`-target`)

الـ stack متصمم يتعمل apply مرة واحدة ([42](42-alb-asg-launch-template.md))، بس عشان تتعلم طبقة طبقة:

```bash
terraform plan  -target=module.network -out=net.tfplan
terraform apply net.tfplan
terraform state list | grep '^module.network'
terraform state show 'module.network.aws_route_table.public'
```

> ⚠️ `-target` أداة للطوارئ والتعلم بس: Terraform بيحذرك إن الـ plan "incomplete". متخليهاش عادة في الـ CI. في [41](41-rds-mysql.md)/[42](42-alb-asg-launch-template.md) هنعمل الـ apply الكامل.

### 5.4 الـ Console مقابل الـ Terraform

| اللي عملته بإيدك | الـ resource في الـ module |
|---|---|
| VPC + DNS options | `aws_vpc.this` (`enable_dns_support`, `enable_dns_hostnames`) |
| تفريغ الـ default SG | `aws_default_security_group.this` (من غير `ingress`/`egress`) |
| IGW | `aws_internet_gateway.this` |
| public subnets + auto-assign IP | `aws_subnet.public[*]` (`map_public_ip_on_launch = true`) |
| private subnets | `aws_subnet.private[*]` |
| public route table + route للـ IGW + associations | `aws_route_table.public`، `aws_route.public_internet`، `aws_route_table_association.public[*]` |
| route table لكل private subnet | `aws_route_table.private[*]` + associations |
| NAT + EIP + route (لو اخترته) | `aws_eip.nat[*]`، `aws_nat_gateway.this[*]`، `aws_route.private_nat[*]` (`nat_gateway_id = this[single_nat ? 0 : count.index]`) |
| S3 Gateway endpoint | `aws_vpc_endpoint.s3[0]` على `concat([public], private[*])` |
| Flow logs | **مش موجود** (اختياري، شوف §4.3) |

## 6) الـ Deploy

مفيش تطبيق في السيناريو ده؛ "الـ deploy" هو الشبكة نفسها. عشان تشوف الـ NAT بعينك (اختياري — **بفلوس**):

```bash
terraform plan -target=module.network -var private_instances=true -out=nat.tfplan   # 1 EIP + 1 NAT + 2 routes
terraform apply nat.tfplan
aws ec2 describe-nat-gateways --filter Name=tag:Project,Values=student-app \
  --query 'NatGateways[].{id:NatGatewayId,state:State,ip:NatGatewayAddresses[0].PublicIp,subnet:SubnetId}' --output table
# رجّعه فوراً (من غير NAT):
terraform apply -target=module.network -var private_instances=false
```

## 7) التحقق (Verify)

```bash
VPC=$(aws ec2 describe-vpcs --filters Name=tag:Name,Values=student-app-lab Name=tag:ManagedBy,Values=terraform \
        --query 'Vpcs[0].VpcId' --output text)
aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC \
  --query 'Subnets[].{name:Tags[?Key==`Name`]|[0].Value,cidr:CidrBlock,az:AvailabilityZone,publicIp:MapPublicIpOnLaunch,free:AvailableIpAddressCount}' --output table
aws ec2 describe-route-tables --filters Name=vpc-id,Values=$VPC \
  --query 'RouteTables[].{name:Tags[?Key==`Name`]|[0].Value,routes:Routes[].[DestinationCidrBlock||DestinationPrefixListId,GatewayId||NatGatewayId]}' --output json
aws ec2 describe-security-groups --filters Name=vpc-id,Values=$VPC Name=group-name,Values=default \
  --query 'SecurityGroups[0].{in:IpPermissions,out:IpPermissionsEgress}'          # لازم الاتنين []
aws ec2 describe-vpc-endpoints --filters Name=vpc-id,Values=$VPC --query 'VpcEndpoints[].[ServiceName,VpcEndpointType,State]' --output table
```

المفروض: 4 subnets (`free` = 4091 في كل واحدة)، الـ public بس اللي فيها `publicIp=true` وفيها route لـ `igw-`، الـ private فيها `local` و `pl-` بس، الـ default SG فاضي، و endpoint `com.amazonaws.us-east-1.s3` من نوع `Gateway`.

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر | المتوقع |
|---|---|---|
| Drift: حد مسح route الإنترنت بإيده | Console: **Route tables → `student-app-lab-public` → Edit routes → Remove `0.0.0.0/0`** ثم `terraform plan -target=module.network` | الـ plan يقول `aws_route.public_internet will be created` — Terraform شايف الـ drift ([91](91-terraform-import-and-drift.md)). بعد [42](42-alb-asg-launch-template.md): الـ ALB بيبطّل يرد والـ instances مش قادرة تعمل `dnf`/ECR pull |
| فخ الـ NACL الـ stateless (بعد 42) | **Network ACLs → Create** `nacl-trap` على الـ VPC → Inbound: rule 100 allow TCP 80 من `0.0.0.0/0` → Outbound: rule 100 allow TCP 80 بس → **Edit subnet associations** → الـ public subnets | الـ ALB بيبطّل يرد رغم إن "80 مسموح": الرد خارج على **ephemeral port** (1024–65535) والـ NACL بيرميه. صلّح بـ outbound allow TCP 1024–65535، أو رجّع الـ default NACL |
| Private subnet من غير NAT | `aws ec2 describe-route-tables --route-table-ids <private-rtb>` | مفيش `0.0.0.0/0` → أي instance هنا مش هتوصل لـ SSM/ECR (ولا Session Manager) إلا بـ NAT أو interface endpoints. ده بالظبط ليه `private_instances` و `enable_nat` مربوطين ببعض في stack 40 |
| الـ default SG | اعمل instance للتجربة من غير ما تختار SG (هياخد الـ default) | مفيش أي traffic داخل أو خارج — ولا حتى SSM agent. ده الهدف |

## 9) الرجوع (Rollback)

```bash
terraform apply -target=module.network          # يرجّع أي drift في الـ routes / الـ default SG
```

للـ NACL: **Network ACLs → الـ default NACL → Edit subnet associations** → رجّع الـ subnets، وبعدين امسح `nacl-trap`.

## 10) المسح (Teardown) ⚠️

لو هتكمّل على [41](41-rds-mysql.md) سيب الشبكة (مجانية من غير NAT). لو خلصت:

```bash
cd infra/terraform/stacks/40-ec2-alb-asg
terraform destroy -target=module.network        # أو terraform destroy للستاك كله بعد 42
aws ec2 describe-nat-gateways --filter Name=tag:Project,Values=student-app Name=state,Values=available --query 'NatGateways[].NatGatewayId'
aws ec2 describe-addresses --filters Name=tag:Project,Values=student-app --query 'Addresses[].[PublicIp,AllocationId]'
aws ec2 describe-vpcs --filters Name=tag:Project,Values=student-app --query 'Vpcs[].[VpcId,Tags[?Key==`ManagedBy`]|[0].Value]'
```

كلهم لازم يرجعوا فاضيين. وماتنساش الـ VPC بتاع الـ console (§4.4) والـ Flow logs.

## 11) التكلفة (Cost)

| Resource | السعر التقريبي (us-east-1 — تقريبي، راجع صفحة الأسعار) |
|---|---|
| VPC، subnets، route tables، IGW، NACLs، SGs | مجاني |
| S3 / DynamoDB gateway endpoint | مجاني |
| NAT gateway | ~$0.045/ساعة (≈ $32/شهر) **لكل واحد** + ~$0.045/GB processing |
| Interface endpoint | ~$0.01/ساعة لكل AZ (≈ $7/شهر) + ~$0.01/GB |
| Public IPv4 (instance، ALB، NAT EIP) | ~$0.005/ساعة لكل IP |
| Cross-AZ data transfer | ~$0.01/GB في كل اتجاه |
| Flow Logs → CloudWatch Logs | ingestion بالـ GB (vended logs، ~$0.50/GB أول شريحة) + التخزين |

## 12) أسئلة Interview

<details><summary>إيه اللي بيخلّي الـ subnet "public" فعلاً؟</summary>

الـ route table المربوطة بيها فيها `0.0.0.0/0` (أو `::/0`) رايح على **Internet Gateway**. مش الاسم، ومش `map_public_ip_on_launch`. instance في public subnet من غير public IP مش هتطلع للإنترنت، و instance بـ public IP في subnet مفيهاش route للـ IGW برضه لأ. والـ private subnet "بتطلع" بس عن طريق NAT (outbound فقط).

</details>

<details><summary>NAT واحد ولا NAT لكل AZ؟ وإزاي تقلل فاتورة الـ NAT؟</summary>

واحد = أرخص بس single-AZ failure domain + cross-AZ data. لكل AZ = HA حقيقي وكل AZ بتطلع من الـ NAT بتاعها (route table لكل private subnet). تقليل التكلفة: gateway endpoints لـ S3/DynamoDB (مجانية، وبتشيل الـ ECR layers من على الـ NAT)، interface endpoints للخدمات اللي traffic بتاعها كبير، IPv6 + egress-only IGW، caching للـ images (golden AMI/[43](43-golden-ami-packer.md))، وتبص على `BytesOutToDestination` بتاع الـ NAT. وفيه دلوقتي الـ regional NAT gateway لو عايز HA من غير ما تدير NAT لكل AZ.

</details>

<details><summary>Security Group مقابل NACL — وإمتى تستخدم NACL أصلاً؟</summary>

الـ SG stateful على الـ ENI، allow بس، وتقدر تشاور بيه على SG تاني (ALB → app → RDS بدل IPs). الـ NACL stateless على الـ subnet، فيه deny وبالترتيب، ولازم تفتكر الـ ephemeral ports للرد. الـ SG هو أداة الشغل اليومي؛ الـ NACL guardrail خشن: block لـ CIDR معروف إنه سيء، أو عزل subnet كامل (مثلاً الداتا) كـ defence in depth، أو compliance.

</details>

<details><summary>إزاي بتخطط الـ CIDR لـ VPC جديد؟</summary>

ابدأ من خريطة الشبكات كلها (on-prem، VPNs، VPCs تانية، accounts تانية) وخد range ميتداخلش، يفضّل من IPAM. خليه كبير (/16) لأن الـ IPs صعب تتوسع (secondary CIDR ممكن بس معقد مع الـ routing). subnets متساوية لكل AZ، واترك مساحة لـ AZs و tiers جديدة من غير renumbering — نفس فكرة "الـ private تبدأ من النص" في الـ module. وافتكر الـ 5 IPs المحجوزة، وإن EKS/ENIs بتاكل IPs بسرعة.

</details>

<details><summary>ليه الـ RDS subnet group محتاج 2 AZ حتى لو Single-AZ؟</summary>

عشان RDS يقدر يعمل Multi-AZ standby أو failover أو restore في AZ تانية من غير ما تعدّل الشبكة. عشان كده الـ stack مثبّت `az_count = 2` (والـ ALB نفسه محتاج subnets في 2 AZ على الأقل).

</details>

<details><summary>Instance مش قادرة توصل للإنترنت — بتعمل debug إزاي؟</summary>

بالترتيب: الـ subnet route table (IGW ولا NAT؟ والـ NAT نفسه `available` وفي public subnet؟) → public IP لو في public subnet → SG egress → NACL (inbound للرد على ephemeral ports!) → DNS (`enable_dns_support`) → الـ OS (proxy، firewall). أدوات: **Reachability Analyzer** (بيقولك أي hop بيمنع)، **Flow Logs** بـ `REJECT`، و `curl -v` من Session Manager — لو الـ SSM agent نفسه offline يبقى غالباً مفيش طريق لـ 443.

</details>

<details><summary>ليه تقفل الـ default security group؟</summary>

لأن أي resource بيتعمل من غير SG صريح بياخده، والـ default بيسمح بكل traffic بين أعضائه. لو حد عمل RDS أو instance بالغلط عليه، اتفتح طريق محدش قصده. تفريغه (CIS benchmark) بيخلّي الغلط يبان فوراً (مفيش connectivity) بدل ما يبقى ثغرة صامتة.

</details>

## 13) Checklist

- [ ] عملت الـ VPC بالـ wizard وفهمت الـ Resource map والـ route tables
- [ ] حسبت الـ CIDRs بـ `terraform console` وطابقتها مع الـ wizard
- [ ] عملت `module.network` بالـ Terraform وقارنته بجدول §5.4
- [ ] جرّبت الـ drift على الـ route وفخ الـ NACL الـ stateless
- [ ] فهمت ليه stack 40 من غير NAT افتراضياً، وإمتى تقلب `private_instances = true`
- [ ] مسحت الـ VPC بتاع الـ console (و NAT/EIP لو عملتهم)
