# 91 — Import لموارد الـ Console جوه Terraform + drift

> **الهدف في سطر:** الجسر بين الـ Console والـ IaC: تاخد موارد عملتها بإيدك في [20](20-ec2-compose-console.md) و [30](30-ci-github-actions.md) و [50](50-ecs-fargate-console.md) (security group، EC2، ECR، SSM parameters، log group) وتدخّلها تحت Terraform بـ `import` blocks و `terraform plan -generate-config-out`، تنضّف الكود المولّد وتحطه في الـ modules الحقيقية لحد ما الـ plan يبقى **zero-diff**، وتفهم الـ drift: إزاي تكتشفه (`-refresh-only`، scheduled check)، تحلّه (adopt ولا revert)، وإيه الـ drift **المقصود** في الـ repo ده (الـ images والـ weights اللي الـ CI بيملكها).
> **المستوى:** Advanced · **الوقت:** ~4 ساعات · **التكلفة التقريبية:** الـ import نفسه مجاني (API reads)؛ الموارد بتتكلف زي ما هي (الـ EC2 بتاع 20 ≈ $0.5/يوم لو لسه شغال)
> **بيعتمد على:** [20 — EC2 من الـ Console](20-ec2-compose-console.md) · [30 — CI و ECR](30-ci-github-actions.md) · [50 — ECS من الـ Console](50-ecs-fargate-console.md) · [90 — Terraform بالتفصيل](90-terraform-deep-dive.md) · **الملفات في الـ repo:** [`bootstrap/ecr.tf`](../../../infra/terraform/bootstrap/ecr.tf) · [`bootstrap/github-oidc.tf`](../../../infra/terraform/bootstrap/github-oidc.tf) · [`stacks/20-ec2-single/ssm.tf`](../../../infra/terraform/stacks/20-ec2-single/ssm.tf) · [`modules/ecs-fargate/main.tf`](../../../infra/terraform/modules/ecs-fargate/main.tf) · [`modules/alb/main.tf`](../../../infra/terraform/modules/alb/main.tf) · [`modules/asg-app/main.tf`](../../../infra/terraform/modules/asg-app/main.tf) · [`deploy-asg.yml`](../../../.github/workflows/deploy-asg.yml)

## 1) الفكرة (Concepts)

**الـ import = إضافة object موجود فعلاً في AWS للـ state** (من غير ما يتعمل تاني). Terraform مبيكتشفش حاجة لوحده: انت بتقوله "الـ address ده = الـ ID ده"، وهو بيقرا الـ attributes من الـ API ويحطها في الـ state. بعد كده الكود لازم **يوصف نفس الحالة** وإلا الـ plan الجاي هيغيّر الـ resource عشان يطابق الكود.

```text
 قبل:   AWS: sg-0abc (student-app-lab-web-sg)      state: —          code: —
 import: AWS: sg-0abc                              state: aws_security_group.web = sg-0abc   code: resource "aws_security_group" "web" {...}
 هدف:   terraform plan  →  No changes   (zero-diff = الكود بيوصف الواقع بالظبط)
```

| الأداة | من إمتى | إيه هي | إمتى |
|---|---|---|---|
| `import` block | Terraform 1.5 | declarative: جزء من الكود، بيظهر في الـ plan (`N to import`)، بيعدّي على PR | **الطريقة الأساسية** |
| `for_each` جوه `import` | 1.7 | import لمجموعة (كل SSM params مثلاً) في block واحد | مجموعات |
| `plan -generate-config-out=FILE` | 1.5 (لسه **experimental**) | Terraform يكتب الـ `resource` blocks بالـ attributes الحالية | نقطة بداية للكود — مش الكود النهائي. **مينفعش مع `for_each`** |
| `terraform import ADDR ID` (CLI) | قديم | imperative: بيكتب في الـ state فوراً، من غير plan، resource واحد، والـ resource block لازم يكون مكتوب قبلها | legacy / state surgery سريعة |
| `terraform query` + `list` blocks | 1.14 | bulk discovery بملفات `*.tfquery.hcl` + `-generate-config-out` | لما مش عارف الـ IDs وعندك مئات الموارد (لو الـ provider بيدعم الـ resource type ده) |

**الـ Drift** = الواقع اتغيّر برّه Terraform. 3 أنواع، وكل نوع Terraform بيشوفه بشكل مختلف:

| النوع | مثال | Terraform بيشوفه؟ |
|---|---|---|
| attribute اتغيّر على resource في الـ state | حد غيّر `/student-app/lab/app/SRE_LAB_ENABLED` لـ `false` | آه — الـ plan بيرجّعه |
| resource في الـ state اتمسح | حد مسح parameter | آه — الـ plan بيعمله تاني |
| resource **جديد** اتعمل برّه Terraform | rule بورت 22 اتضافت كـ rule منفصلة، أو parameter جديد تحت `/student-app/lab/app/` | **لأ** (unmanaged) — إلا بشكل غير مباشر (§6.2) |

## 2) المعمارية (Architecture)

```text
  ┌──── Console (20 / 30 / 50) ────┐      ┌───────────── import workflow ─────────────┐
  │ SG student-app-lab-web-sg       │      │ 1. lookup IDs (aws cli)                    │
  │ EC2 student-app-lab-ec2 + EIP   │ ───► │ 2. imports.tf  (import blocks)             │
  │ ECR student-app (+ images!)     │      │ 3. plan -generate-config-out=generated.tf  │
  │ OIDC provider, role gha-ci      │      │ 4. نضّف: references، شيل الـ computed،     │
  │ SSM /student-app/lab/{app,mysql}│      │    قرارات الـ secrets، الـ lifecycle        │
  │ log group /ecs/student-app-lab/ │      │ 5. plan → "N to import, 0 to destroy"      │
  │   app                           │      │ 6. apply (state write بس) → شيل الـ imports │
  └─────────────────────────────────┘      └─────────────────────────────────────────────┘

  drift loop:   AWS ──refresh──► state ◄──diff──► code
                plan -refresh-only : "إيه اللي اتغيّر برّه؟"   (مبيقترحش يرجّع حاجة)
                plan               : "إيه اللي هيتعمل عشان الواقع = الكود؟" (بيحترم ignore_changes)
```

## 3) المتطلبات (Prerequisites)

- [ ] موارد Console موجودة من [20](20-ec2-compose-console.md) (SG، instance، EIP، params) و/أو [30](30-ci-github-actions.md) (ECR، OIDC، role) و/أو [50](50-ecs-fargate-console.md) (log group). مش عندك؟ اعمل موارد تمرين في §5.1 (Plan B).
- [ ] Terraform ≥ 1.11 (اللي كل `versions.tf` في الـ repo بيطلبه؛ `for_each` في الـ import محتاج 1.7+ بس). ≥ 1.14 لو هتجرب `terraform query` (نفس نسخة الـ CI `~1.14`)؛ آخر stable 1.17 وقت الكتابة.
- [ ] credentials بـ admin على الـ laptop (`aws sts get-caller-identity`) و `jq`.

## 4) قبل أي import: تعمل import ولا تعيد الإنشاء؟

مش كل حاجة اتعملت بالإيد تستاهل import. **Import للحاجات الـ stateful أو الغالية أو اللي حاجات تانية بتشاور عليها، وإعادة إنشاء للـ cattle.**

| المورد (من سيناريو) | القرار | ليه |
|---|---|---|
| ECR `student-app` (30) | **import** في `bootstrap` (`aws_ecr_repository.app`) | فيه images بالـ SHA = تاريخ الـ releases وأهداف الـ rollback. لو مسحته خسرتهم |
| GitHub OIDC provider (30) | **import** أو `create_github_oidc_provider = false` | مسموح provider واحد بس لكل URL في الـ account — الـ bootstrap عامل toggle بالظبط للحالة دي (data source بدل resource) |
| Role `student-app-gha-ci` (30) | import أو امسح واعمل | الـ ARN بيتحدد بالاسم، فإعادة الإنشاء بنفس الاسم مش بتكسر الـ GitHub variable. بس الـ import تمرين ممتاز (§5.3) |
| Log group `/ecs/student-app-lab/app` (50) | **import** في `module.ecs.aws_cloudwatch_log_group.app` | نفس الاسم والـ retention (14 يوم) بالظبط اللي الـ module بيعمله، وفيه logs |
| SG `student-app-lab-web-sg` (20) | **متعملهوش import في stack 20** — تمرين في scratch بس | في الـ default VPC، و stack 20 بيعمل VPC و SG خاصين بيه. الـ import مش هيخلّيه "جزء من" الـ stack |
| EC2 `student-app-lab-ec2` (20) | تمرين scratch، بعدين **migrate** للـ stack | تغيير `subnet_id` (default VPC ← VPC الـ stack) = replace إجباري. الصح: backup لـ MySQL ([27](27-mysql-backup-restore.md)) → stack 20 → restore |
| SSM params (20) | import **بس افهم** إن القيم هتتغيّر (§5.3) | الـ stack بيولّد secrets جديدة؛ الـ import ≠ تبني القيم |
| ALB / TGs / IAM roles بتوع (50) | امسحهم ([51 §3](51-ecs-fargate-terraform.md)) | cattle، ونفس الأسماء هتعمل conflict |

## 5) الطريقة: Import خطوة بخطوة

### 5.1 Lab A — scratch directory (تتعلم الأداة من غير ما تلمس الـ repo)

فولدر برّه الـ repo بـ local state (مش هيتعمله commit):

```bash
mkdir -p ~/tf-import-lab && cd ~/tf-import-lab
export AWS_REGION=us-east-1
cat > providers.tf <<'EOF'
terraform {
  required_version = ">= 1.11" # نفس الـ repo (import blocks 1.5+، for_each جواها 1.7+)
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

provider "aws" {
  region = "us-east-1"
  # عن قصد من غير default_tags في الأول: عايزين نشوف zero-diff صافي
}
EOF
```

دوّر على الـ IDs (الـ `import.id` لازم يكون معروف وقت الـ plan):

```bash
SG_ID=$(aws ec2 describe-security-groups --filters Name=group-name,Values=student-app-lab-web-sg \
  --query 'SecurityGroups[0].GroupId' --output text)
IID=$(aws ec2 describe-instances --filters Name=tag:Name,Values=student-app-lab-ec2 \
  Name=instance-state-name,Values=running,stopped --query 'Reservations[0].Instances[0].InstanceId' --output text)
EIP_ALLOC=$(aws ec2 describe-addresses --filters Name=instance-id,Values="$IID" \
  --query 'Addresses[0].AllocationId' --output text)
echo "SG=$SG_ID INSTANCE=$IID EIP=$EIP_ALLOC"
aws ecr describe-repositories --repository-names student-app --query 'repositories[0].repositoryUri' --output text
aws logs describe-log-groups --log-group-name-prefix /ecs/student-app-lab/app --query 'logGroups[].logGroupName'
```

> **Plan B (مسحت موارد الـ Console؟)** اعمل موارد تمرين رخيصة بالـ tags بتاعة الـ Console واستخدم الأسماء دي بدل اللي فوق (وشيل الـ blocks بتاعة الـ EC2/EIP/ECR):
>
> ```bash
> VPC=$(aws ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)
> SG_ID=$(aws ec2 create-security-group --group-name student-app-lab-import-sg --description "scenario 91 import practice" \
>   --vpc-id "$VPC" --query GroupId --output text \
>   --tag-specifications 'ResourceType=security-group,Tags=[{Key=Project,Value=student-app},{Key=Env,Value=lab},{Key=ManagedBy,Value=console},{Key=Scenario,Value=91}]')
> aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 80 --cidr 203.0.113.10/32
> aws logs create-log-group --log-group-name /ecs/student-app-lab/app --tags Project=student-app,Env=lab,ManagedBy=console,Scenario=91
> aws logs put-retention-policy --log-group-name /ecs/student-app-lab/app --retention-in-days 14
> aws ssm put-parameter --name /student-app/lab/app/APP_URL --type String --value http://203.0.113.10
> aws ssm put-parameter --name /student-app/lab/app/APP_KEY --type SecureString --value "base64:$(openssl rand -base64 32)"
> ```

اكتب الـ import blocks (الـ heredoc من غير `'EOF'` عشان الـ shell يحط الـ IDs):

```bash
cat > imports.tf <<EOF
import {
  to = aws_security_group.web
  id = "${SG_ID}"
}
import {
  to = aws_instance.app
  id = "${IID}"
}
import {
  to = aws_eip.app
  id = "${EIP_ALLOC}"
}
import {
  to = aws_ecr_repository.app
  id = "student-app"
}
import {
  to = aws_cloudwatch_log_group.ecs_app
  id = "/ecs/student-app-lab/app"
}
import {
  to = aws_ssm_parameter.app_url
  id = "/student-app/lab/app/APP_URL"
}
import {
  to = aws_ssm_parameter.app_key
  id = "/student-app/lab/app/APP_KEY"
}
EOF

terraform init
terraform plan -generate-config-out=generated.tf
```

المتوقع: `generated.tf` اتكتب، وفي الآخر `Plan: 7 to import, 0 to add, 0 to change, 0 to destroy.` — **أو** error. الشائع:

- `"ipv6_address_count": conflicts with ipv6_addresses` (أو conflicts تانية على `aws_instance`) — ده المثال اللي في docs HashiCorp نفسها: Terraform مش دايماً بيقدر يبني config صالح لـ resource الـ schema بتاعه معقد. **امسح واحد من الاتنين** وشغّل `terraform plan` تاني (من غير `-generate-config-out` — الملف لازم ميكونش موجود، وإلا error).

### 5.2 تنضيف الكود المولّد (ده الشغل الحقيقي)

افتح `generated.tf`. هتلاقي كل attribute متاح بقيمته الحالية أو `null`. قواعد التنضيف:

| في الملف المولّد | اعمل إيه | ليه |
|---|---|---|
| `vpc_id = "vpc-0..."`، `vpc_security_group_ids = ["sg-0..."]` | `data.aws_vpc.default.id`، `[aws_security_group.web.id]` | IDs مكتوبة = الـ config مش هيشتغل في account/بيئة تانية، والـ graph مش هيعرف الـ dependencies |
| `xxx = null` و defaults | امسحها | ضوضاء — اكتب اللي يفرق بس |
| `value = null # sensitive` في `aws_ssm_parameter` | قرار (تحت) | Terraform **مبيكتبش** أي قيمة sensitive في الملف — و `value` في الـ resource ده sensitive دايماً، حتى لـ `String` |
| `ingress { ... }` / `egress { ... }` inline في `aws_security_group` | اختار: inline **أو** `aws_vpc_security_group_*_rule` منفصلة (أسلوب الـ repo) — **مش الاتنين** | الخلط بيعمل diff أبدي. لو منفصلة: اعمل import لكل rule بالـ `sgr-...` بتاعها |
| `user_data` في `aws_instance` | `file(...)` + `lifecycle { ignore_changes = [ami, user_data] }` | تغيير `user_data` على instance شغال = الـ provider بيعمل **stop/start** (أو replace مع `user_data_replace_on_change`) — نفس سبب الـ `ignore_changes` في [`ec2-docker-host`](../../../infra/terraform/modules/ec2-docker-host/main.tf) |
| `tags = { ManagedBy = "console" ... }` | سيبها دلوقتي، وبعد ما يبقى zero-diff غيّرها لـ `terraform` | تغيير مقصود واحد في المرة |

**قرار الـ secrets بعد الـ import** (`APP_KEY`):

```hcl
# خيار 1: Terraform يتبنّى الـ resource بس مش القيمة (القيمة الحالية تفضل زي ما هي)
resource "aws_ssm_parameter" "app_key" {
  name  = "/student-app/lab/app/APP_KEY"
  type  = "SecureString"
  value = "managed-outside-terraform"   # placeholder عمره ما هيتكتب
  lifecycle {
    ignore_changes = [value]
  }
}

# خيار 2: Terraform يملك القيمة (زي stacks/20-ec2-single/ssm.tf) — الـ apply هيكتب قيمة جديدة.
# APP_KEY جديد = كل الـ sessions والداتا المشفّرة بيه تبوظ (شوف التحذير في سيناريو 20).
```

**الـ String parameter** (`APP_URL`): استبدل `value = null # sensitive` بـ `insecure_value = "http://<EIP>"` — نفس أسلوب الـ repo عشان القيمة تبان في الـ plan.

**الـ SG بالأسلوب المنفصل** (لو اخترته):

```bash
aws ec2 describe-security-group-rules --filters Name=group-id,Values="$SG_ID" \
  --query 'SecurityGroupRules[].{id:SecurityGroupRuleId,egress:IsEgress,proto:IpProtocol,from:FromPort,cidr:CidrIpv4}' --output table
```

```hcl
import {
  to = aws_vpc_security_group_ingress_rule.http
  id = "sgr-0123456789abcdef0"
}
resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.web.id
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "203.0.113.10/32"
}
```

كرّر لحد ما:

```bash
terraform fmt && terraform validate
terraform plan        # الهدف: Plan: 7 to import, 0 to add, 0 to change, 0 to destroy.
terraform apply       # Apply complete! Resources: 7 imported, 0 added, 0 changed, 0 destroyed.
rm imports.tf         # اختياري: بعد الـ import الـ blocks ملهاش أثر (أو سيبها كتاريخ)
terraform plan        # No changes. Your infrastructure matches the configuration.
```

> 💡 **القاعدة الذهبية:** `0 to destroy` إجباري، وكل سطر في `to change` لازم تكون فاهمه وموافق عليه. أي `must be replaced` على resource مستورد = **وقف**، الكود لسه مش بيوصف الواقع.

بعد الـ zero-diff ضيف `default_tags` (`ManagedBy = "terraform"`) للـ provider → الـ plan هيطلع update على الـ tags بس → apply. دلوقتي الموارد "اتبنّت" رسمياً.

### 5.3 Lab B — تدخيلها في كود الـ repo الحقيقي

> ⚠️ **object واحد = state واحد.** قبل ما تعمل import لحاجة هنا كنت استوردتها في الـ scratch، شيلها من هناك الأول (من غير ما تتمسح):
>
> ```bash
> terraform -chdir="$HOME/tf-import-lab" state rm aws_ecr_repository.app aws_cloudwatch_log_group.ecs_app
> ```

**B1: الـ bootstrap بعد ما عملت [30](30-ci-github-actions.md) من الـ Console.** من غير import، أول `terraform apply` للـ bootstrap هيقع بـ `RepositoryAlreadyExistsException` (ECR) و `EntityAlreadyExists` (الـ role والـ OIDC provider). ملف مؤقت جوه [`infra/terraform/bootstrap/`](../../../infra/terraform/bootstrap/):

```bash
cd infra/terraform/bootstrap
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
cat > imports.tf <<EOF
import {
  to = aws_ecr_repository.app
  id = "student-app"
}
import {
  to = aws_iam_openid_connect_provider.github[0]
  id = "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
}
import {
  to = aws_iam_role.ci
  id = "student-app-gha-ci"
}
EOF
terraform init
terraform plan -out=tfplan
```

المتوقع: `3 to import` + `to add` لحاجات الـ Console معملهاش (الـ ECR lifecycle policy، الـ inline policy `ecr-push`، باقي الـ roles والـ buckets) + `to change` لحاجات زي الـ trust policy بتاعة الـ role (Terraform هيكتب الـ `sub` conditions بتاعته) والـ tags. ممكن كمان تشوف update لـ attributes مالهاش مقابل في الـ API زي `force_delete` — دي Terraform-only وطبيعي تظهر بعد import. **`0 to destroy`.** بعدها:

```bash
terraform apply tfplan
rm imports.tf
# الـ Console كان عامل customer-managed policy متعلّقة على الـ role — Terraform مش بيديرها
# (aws_iam_role مش بيشوف الـ attachments اللي مش في الكود) = صلاحية "مخفية":
aws iam list-attached-role-policies --role-name student-app-gha-ci
aws iam detach-role-policy --role-name student-app-gha-ci --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/student-app-gha-ci-ecr-push"
aws iam delete-policy --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/student-app-gha-ci-ecr-push"
```

> ⚠️ السطر الأخير ده بالظبط نوع الـ drift اللي Terraform **مش هيشوفه أبداً**: resource منفصل (policy attachment) مش في الـ state. الـ import بيدخّل الـ object اللي سمّيته بس، مش كل حاجة مربوطة بيه.

**B2: الـ log group بتاع [50](50-ecs-fargate-console.md) جوه stack 50.** الـ `import` block لازم يكون في الـ **root module**، بس الـ `to` ممكن يشاور على resource جوه module:

```hcl
# infra/terraform/stacks/50-ecs-fargate/imports.tf  (مؤقت)
import {
  to = module.ecs.aws_cloudwatch_log_group.app
  id = "/ecs/student-app-lab/app"
}
```

```bash
cd infra/terraform/stacks/50-ecs-fargate
terraform plan -var image_tag=<SHA> -out=tfplan | grep -E 'import|aws_cloudwatch_log_group.app'
```

الـ module بيعمل نفس الاسم (`/ecs/<name>/app`) ونفس الـ retention (14)، فالـ diff على الـ log group = الـ tags بس. باقي موارد 50 اللي ليها نفس الأسماء (`student-app-lab-alb`، الـ TGs، `student-app-lab-ecs-execution`/`-ecs-task`) امسحها زي [51 §3](51-ecs-fargate-terraform.md) — cattle.

**B3: الـ SSM params بتاعة [20](20-ec2-compose-console.md) جوه stack 20 بـ `for_each` import** (مينفعش `-generate-config-out` مع `for_each` — ومش محتاجه: الـ resources مكتوبة في [`ssm.tf`](../../../infra/terraform/stacks/20-ec2-single/ssm.tf)):

```hcl
# infra/terraform/stacks/20-ec2-single/imports.tf  (مؤقت)
import {
  for_each = toset(["APP_URL", "DB_CONNECTION", "DB_HOST", "DB_PORT", "DB_DATABASE", "DB_USERNAME",
                    "SESSION_DRIVER", "CACHE_STORE", "SRE_LAB_ENABLED", "METRICS_ENABLED"])
  to = aws_ssm_parameter.app[each.key]
  id = "/student-app/lab/app/${each.key}"
}
import {
  for_each = toset(["APP_KEY", "DB_PASSWORD", "SRE_LAB_TOKEN"])
  to       = aws_ssm_parameter.app_secret[each.key]
  id       = "/student-app/lab/app/${each.key}"
}
import {
  for_each = toset(["MYSQL_DATABASE", "MYSQL_USER"])
  to       = aws_ssm_parameter.mysql[each.key]
  id       = "/student-app/lab/mysql/${each.key}"
}
import {
  for_each = toset(["MYSQL_PASSWORD", "MYSQL_ROOT_PASSWORD"])
  to       = aws_ssm_parameter.mysql_secret[each.key]
  id       = "/student-app/lab/mysql/${each.key}"
}
```

اقرا الـ plan كويس — ده الدرس:

1. **`17 to import`** وبعدين **update in-place على `value`** للـ secrets (`(sensitive value)`): الـ stack بيولّد `random_password` جديد، فالـ apply هيكتب باسوردات و `APP_KEY` جديدة. على stack 20 ده مقبول (instance جديد و MySQL volume جديد)، بس الـ instance القديم بتاع الـ Console هيتكسر أول ما يعمل render. **الـ import بيتبنّى الـ resource، مش القيمة.**
2. `APP_URL` هيتغير للـ EIP الجديد.
3. الـ Console كان عامل params زيادة: `APP_NAME`، `APP_ENV`، `APP_DEBUG`، `APP_TIMEZONE`، `APP_LOCALE`، `QUEUE_CONNECTION`، `LOG_LEVEL`. الـ stack مش بيديرها → **unmanaged**، بس [`render-env-from-ssm.sh`](../../../deploy/ec2/render-env-from-ssm.sh) بيقرا بالـ path، فهتوصل لـ `app.env` برضه. ده "shadow config": يا تضيفها لـ `local.app_plain` (وتعمل import)، يا تمسحها.

### 5.4 `terraform import` (الـ CLI القديم)

```bash
cd infra/terraform/stacks/50-ecs-fargate
terraform import -var image_tag=<SHA> 'module.ecs.aws_cloudwatch_log_group.app' /ecs/student-app-lab/app
cd ../20-ec2-single
terraform import 'aws_ssm_parameter.app_secret["APP_KEY"]' /student-app/lab/app/APP_KEY
```

| | `import` block | `terraform import` |
|---|---|---|
| Plan قبل التنفيذ | آه | لأ — بيكتب في الـ state فوراً |
| Review في PR / CI | آه | لأ (laptop) |
| مجموعة | `for_each` | واحد واحد |
| توليد كود | `-generate-config-out` | لأ — الـ block لازم يكون موجود وإلا `resource address does not exist in the configuration` |
| Variables إجبارية | من الـ tfvars/`-var` عادي | برضه محتاجها (بيعمل evaluate للـ config) — عشان كده `-var image_tag` فوق |

### 5.5 `terraform query` — bulk discovery (Terraform 1.14+)

لما مش عارف الـ IDs (مثلاً "كل الـ instances اللي اتعملت بالإيد في الـ account"): ملف `*.tfquery.hcl` فيه `list` blocks، و `terraform query` بيعرض النتايج، و `terraform query -generate-config-out=generated.tf` بيكتب الـ `import` + `resource` blocks (بالـ resource identity) جاهزين.

```hcl
# discovery.tfquery.hcl  (هيكل — الـ config/filters بتختلف حسب كل resource type في الـ provider)
list "aws_instance" "unmanaged" {
  provider = aws
  limit    = 50            # الافتراضي 100
  config {
    # filters خاصة بالـ provider — راجع docs الـ list resource للـ type ده
  }
}
```

```bash
terraform query                                   # يعرض اللي لقاه
terraform query -generate-config-out=generated.tf # الملف لازم ميكونش موجود
```

الشرط: الـ provider لازم يدعم الـ "list resource" للـ type ده — راجع docs الـ AWS provider قبل ما تعتمد عليه.

## 6) الـ Drift: اكتشاف وحل

### 6.1 الأوامر

| الأمر | بيعمل إيه | بيحترم `ignore_changes`؟ |
|---|---|---|
| `terraform plan` | refresh + diff مع الكود → الـ actions اللي هترجّع الواقع للكود | آه |
| `terraform plan -refresh-only` | يوريك **إيه اللي اتغيّر برّه Terraform** بس، من غير ما يقترح يرجّعه | لأ — بيعرض كل تغيير (حتى في الحقول المتجاهلة) |
| `terraform apply -refresh-only` | يقبل الواقع ويكتبه في الـ state (من غير ما يلمس AWS) | — |
| `-detailed-exitcode` | `0` مفيش تغيير · `1` error · `2` فيه تغيير | — |

### 6.2 تمرين: اعمل drift بإيدك واتفرّج (على stack 20 بعد الـ apply)

```bash
cd infra/terraform/stacks/20-ec2-single

# (أ) attribute على resource Terraform بيملكه
aws ssm put-parameter --name /student-app/lab/app/SRE_LAB_ENABLED --value false --overwrite
terraform plan            # ~ update in-place: insecure_value "false" -> "true"

# (ب) rule جديدة على الـ SG (Terraform بيدير الـ rules كـ resources منفصلة)
SG=$(aws ec2 describe-security-groups --filters Name=group-name,Values=student-app-lab-app-host \
  --query 'SecurityGroups[0].GroupId' --output text)          # module.host.aws_security_group.this
aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol tcp --port 22 --cidr 0.0.0.0/0
terraform plan -detailed-exitcode; echo "exit=$?"          # No changes, exit=0  ← !!
terraform plan -refresh-only                                # aws_security_group.this: ingress اتغيّر برّه Terraform
```

السطر (ب) أهم درس في السيناريو: الـ plan العادي قال **No changes** رغم إن بورت 22 مفتوح للعالم. الـ rule الجديدة resource مش في الـ state، والـ `aws_security_group` نفسه مش عامل `ingress` inline في الكود فمبيعترضش. الـ `-refresh-only` بيكشفها بشكل غير مباشر لأن attribute الـ `ingress` في الـ SG بيتقري من AWS (اتأكد بنفسك من الـ output). عشان كده الـ drift detection الحقيقي محتاج طبقة تانية: **AWS Config rules** (مثلاً SG بيفتح 22 للعالم)، Security Hub، أو EventBridge على `AuthorizeSecurityGroupIngress` من principal مش الـ pipeline.

```bash
# رجّع كل حاجة
aws ec2 revoke-security-group-ingress --group-id "$SG" --protocol tcp --port 22 --cidr 0.0.0.0/0
terraform apply           # يرجّع SRE_LAB_ENABLED=true
```

### 6.3 الـ Drift **المقصود** في الـ repo (ownership boundaries)

| الحقل | المالك بعد أول apply | الآلية | `plan` | `plan -refresh-only` |
|---|---|---|---|---|
| `aws_ssm_parameter.image_uri.value` ([asg-app](../../../infra/terraform/modules/asg-app/main.tf)) — `/student-app/<env>/deploy/<color>/IMAGE_URI` | CI (`deploy-asg.yml` / `rolling-asg.yml`) | `ignore_changes = [value]` | هادي | بيعرض القيمة الجديدة |
| `aws_ecs_service.app` `task_definition` / `desired_count` / `load_balancer` | CI / Auto Scaling / الـ deployer | `ignore_changes` | هادي | بيعرضها |
| `aws_lb_listener_rule.production/test` `action` (ECS native) | ECS | `ignore_changes = [action]` | هادي | بيعرضها |
| `aws_lb_listener.*_external` `default_action` (stack 50 مع `CODE_DEPLOY`، أو stack 40 مع `listener_weights_managed_externally = true`) | CodeDeploy / CI | `ignore_changes = [default_action]` | هادي | بيعرضها |
| `aws_lb_listener.http/https` `default_action` في stack 40 **بالـ default** (`listener_weights_managed_externally = false`) | **Terraform** — بس [`deploy-asg.yml`](../../../.github/workflows/deploy-asg.yml) بيعمل `modify-listener` | ولا حاجة | **بيرجّع الـ weights** = drift حقيقي | بيعرضها |
| `aws_autoscaling_group.desired_capacity` | scaling policies | `ignore_changes` | هادي | بيعرضها |
| `aws_instance.this` `ami` / `user_data` ([ec2-docker-host](../../../infra/terraform/modules/ec2-docker-host/main.tf)) | — (pet) | `ignore_changes` | هادي | — |

الصف الخامس هو الفخ الحقيقي. الـ workflow نفسه بيحذّر في الـ summary: *"Copy the final weights into stack 40 tfvars (blue_weight / green_weight) or the next apply reverts them."* عندك 3 حلول:

1. **Adopt بالكود:** انسخ الـ weights النهائية لـ `terraform.tfvars` (`blue_weight = 0`، `green_weight = 100`) → `plan` = No changes.
2. **Hand-off دائم:** `listener_weights_managed_externally = true` — بـ `terraform state mv` عشان الـ listener ميتمسحش ([90 §5.9](90-terraform-deep-dive.md)).
3. **Revert:** `terraform apply` يرجّع الـ weights اللي في الكود (لو الـ CI عمل حاجة غلط).

وفيه موارد بيعملها الـ CI أو AWS **برّه أي state** خالص (مش drift، بس لازم تعرفها للـ teardown): task definition revisions بتاعة الـ CI، log groups بتاعة Container Insights، log groups الـ CloudWatch agent (`/student-app/lab/ec2/*` — [93](93-ansible-deep-dive.md))، و AMIs بتاعة Packer.

### 6.4 حل الـ Drift: شجرة القرار

```text
 الـ drift ده...
 ├─ تغيير غلط / مش مصرّح بيه (حد فتح بورت، غيّر config)  → REVERT: terraform apply  + RCA: ليه قدر يعمله؟
 ├─ تغيير صح ولازم يفضل (hotfix وقت incident)            → ADOPT: عدّل الكود يطابق → plan = No changes → PR
 │                                                          (attribute مش في الكود أصلاً: apply -refresh-only)
 ├─ الحقل ده مالكه الطبيعي حد تاني (CI, ASG, CodeDeploy)  → HAND-OFF: ignore_changes + تعليق بالمالك
 ├─ resource جديد اتعمل برّه                              → IMPORT (§5) أو امسحه
 └─ resource Terraform بيملكه اتمسح                       → apply يعمله تاني (لو stateful: restore الأول!)
```

**منع الـ drift أحسن من اكتشافه:** الناس تاخد read-only في الـ Console، و break-glass role للطوارئ بس (ومراقَب)، و IAM/SCP بيمنع التعديل على الموارد اللي عليها `ManagedBy=terraform` لأي principal غير الـ pipeline (`aws:ResourceTag/ManagedBy`)، و CloudTrail → EventBridge alert على write calls من بني آدمين.

### 6.5 فكرة: scheduled drift check (مش موجود في الـ repo)

```yaml
# .github/workflows/terraform-drift.yml   (فكرة للتطبيق — مش في الـ repo)
name: Terraform drift
on:
  schedule:
    - cron: "0 5 * * 1-5"      # 05:00 UTC = 07:00/08:00 القاهرة، أيام الشغل
  workflow_dispatch:
permissions:
  contents: read
  id-token: write
  issues: write
jobs:
  drift:
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        stack: [20-ec2-single, 40-ec2-alb-asg]
    defaults:
      run:
        shell: bash
        working-directory: infra/terraform/stacks/${{ matrix.stack }}
    env:
      TF_IN_AUTOMATION: "true"
      TF_INPUT: "false"
      TF_VAR_region: ${{ vars.AWS_REGION }}
    steps:
      - uses: actions/checkout@v6
      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "~1.14"   # نفس terraform.yml
          terraform_wrapper: false
      - uses: aws-actions/configure-aws-credentials@v6
        with:
          role-to-assume: ${{ vars.AWS_TERRAFORM_PLAN_ROLE_ARN }}
          aws-region: ${{ vars.AWS_REGION }}
      - name: plan (read-only, no lock)
        id: plan
        run: |
          terraform init -no-color \
            -backend-config="bucket=${{ vars.TF_STATE_BUCKET }}" -backend-config="region=${{ vars.AWS_REGION }}" \
            -backend-config="key=stacks/${{ matrix.stack }}/terraform.tfstate" -backend-config="use_lockfile=true"
          # state فاضي (اتعمله destroy) = مش deployed، مش drift
          if [[ -z "$(terraform state list)" ]]; then echo "code=0" >> "$GITHUB_OUTPUT"; exit 0; fi
          set +e
          terraform plan -no-color -lock=false -detailed-exitcode > plan.txt 2>&1
          echo "code=$?" >> "$GITHUB_OUTPUT"
      - name: open or update the drift issue
        if: steps.plan.outputs.code == '2'
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          fence="$(printf '\140\140\140')"
          title="Terraform drift: ${{ matrix.stack }}"
          { echo "Scheduled plan found changes."; echo; echo "$fence"; tail -c 60000 plan.txt; echo "$fence"; } > body.md
          n=$(gh issue list --state open --label drift --search "\"$title\" in:title" --json number --jq '.[0].number')
          if [[ -n "$n" ]]; then gh issue comment "$n" --body-file body.md
          else gh issue create --title "$title" --label drift --body-file body.md; fi
```

قرارات التصميم اللي لازم تدافع عنها:

- **plan عادي مش `-refresh-only`:** في الـ repo ده الـ refresh-only هيصرخ كل يوم على الحقول اللي الـ CI بيملكها (الـ images، الـ desired count). الـ plan العادي بيحترم `ignore_changes` فبيطلّع اللي **هيتغير فعلاً** لو حد عمل apply. (لو عايز refresh-only: فلتر `terraform show -json` على `.resource_drift[]` واستبعد الحقول المعروفة.)
- **نفس الـ inputs اللي اتعمل بيها الـ apply:** الـ stacks بتتعمل apply من الـ laptop بـ `terraform.tfvars` (gitignored). الـ job ده بيشوف الـ defaults بس، فأي قيمة مختلفة (instance type، weights) هتطلع "drift" كاذب. الحل الصح: tfvars غير سرّية لكل env في الـ repo (`lab.tfvars`) و `-var-file` في كل مكان. وstack 50: `image_tag` لازم نفس اللي اتعمل بيه الـ apply (وإلا الـ task definition هيبان إنه `must be replaced`).
- **`-lock=false` + الـ plan role:** read-only ومبيعطّلش أي apply. الـ OIDC `sub` بتاع الـ schedule = `ref:refs/heads/<default branch>`، والـ plan role بيثق في `ref:refs/heads/*`.
- الـ label `drift` لازم يكون موجود: `gh label create drift --color B60205`.

## 7) التحقق (Verify)

```bash
terraform plan -detailed-exitcode; echo "exit=$?"                 # 0 بعد كل import
terraform state list | grep -E 'ecr_repository|openid_connect|cloudwatch_log_group.app|ssm_parameter'
aws ecr describe-repositories --repository-names student-app --query 'repositories[0].imageTagMutability'
aws ecr list-images --repository-name student-app --query 'length(imageIds)'     # الـ images لسه موجودة
aws resourcegroupstaggingapi get-resources --tag-filters Key=ManagedBy,Values=console \
  --query 'ResourceTagMappingList[].ResourceARN' --output text                   # اللي لسه "console"
```

المفروض: exit=0، الموارد المستوردة في الـ state، الـ images زي ما هي، والـ tags اتحولت لـ `ManagedBy=terraform` (عن طريق `default_tags`).

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر | المتوقع |
|---|---|---|
| ID غلط | غيّر `id = "student-app"` لـ `id = "student-ap"` في الـ import block | `Cannot import non-existent remote object` |
| Address موجود في الـ state | import تاني لنفس الـ address | `Resource already managed by Terraform` |
| الملف موجود | `plan -generate-config-out=generated.tf` تاني | error — Terraform مبيكتبش فوق ملف موجود |
| `for_each` + generate | import بـ `for_each` مع `-generate-config-out` | مش مدعوم — اكتب الـ resource بإيدك |
| نفس الـ object في state-ين | import الـ log group في Lab A وفي stack 50 | الاتنين "بيملكوه": destroy في واحد يمسحه من تحت التاني. **object واحد = state واحد** — `terraform state rm` من الـ scratch |
| Import من غير variables | `terraform import ...` في stack 50 من غير `-var image_tag` | `No value for required variable` |
| Drift على حقل CI | deploy بالـ CI ثم `plan` ثم `plan -refresh-only` على stack 40 | الأول هادي، التاني بيعرض `IMAGE_URI` الجديد |
| Weights | شغّل `deploy-asg.yml` بـ `bluegreen-switch` ثم `terraform plan` على stack 40 | `~ default_action` بيرجّع blue=100 — طبّق حل من §6.3 |

## 9) الرجوع (Rollback)

- **إلغاء import (من غير مسح الـ object):** `terraform state rm <ADDR>` (فوري) أو الأحسن:

```hcl
removed {
  from = aws_ecr_repository.app
  lifecycle {
    destroy = false
  }
}
```

- **apply بعد import عمل تغيير غلط:** `git revert` للكود + apply، أو ارجع لنسخة state من S3 versioning ([90 §5.8](90-terraform-deep-dive.md)).
- **secret اتكتب فوقه:** لو `APP_KEY` القديم مهم ومش محفوظ في حتة → `aws ssm get-parameter-history --name /student-app/lab/app/APP_KEY --with-decryption` (SSM بيحتفظ بآخر 100 version).

## 10) المسح (Teardown) ⚠️

```bash
# Lab A: Terraform ينضّف الـ ClickOps بداله (destroy للي استوردته في الـ scratch بس):
cd ~/tf-import-lab
terraform state list                                                         # لو الـ ECR / log group لسه هنا (معملتش Lab B):
terraform state rm aws_ecr_repository.app aws_cloudwatch_log_group.ecs_app   # متمسحهمش بـ destroy — الـ images والـ logs مهمين
terraform destroy                                                            # SG + EC2 + EIP + params بتوع 20
cd ~ && rm -rf ~/tf-import-lab                                               # فيه local state بـ secrets

# الـ repo: شيل ملفات imports.tf المؤقتة
git -C /path/to/student-app status --short infra/terraform
```

بعدها كمّل teardown [20 §10](20-ec2-compose-console.md) للي فاضل (الـ instance profile و الـ role `student-app-lab-ec2-role`).

## 11) التكلفة (Cost)

| البند | التكلفة |
|---|---|
| `import` / `plan` / `query` | مجاني (read APIs) |
| موارد الـ Console المستوردة | نفس تكلفتها قبل الـ import (EC2 t3.small + EIP ≈ $0.5/يوم) |
| موارد Plan B (SG، log group، params) | ≈ $0 |
| scheduled drift check | GitHub Actions minutes بس |

## 12) أسئلة Interview

<details><summary>إيه الفرق بين <code>import</code> block و <code>terraform import</code>؟ وليه الـ block أحسن في فريق؟</summary>

الـ block declarative: بيظهر في الـ plan كـ "N to import"، بيعدّي على PR وreview، بيدعم `for_each` (1.7+) و `-generate-config-out`، وممكن يتنفذ من الـ CI. الـ CLI بيكتب في الـ state فوراً من laptop واحد من غير plan، resource واحد، ولازم تكتب الـ resource block قبله. في فريق، أي تغيير على الـ state لازم يبقى reviewable — فالـ block.

</details>

<details><summary>عملت import والـ plan بيقول <code>1 to import, 3 to change</code>. تعمل apply؟</summary>

مش قبل ما أفهم كل change. الـ import نفسه مش بيغيّر AWS، بس الـ apply بيطبق الـ changes معاه. Tags من `default_tags` أو trust policy مقصودة = تمام. أي `must be replaced` أو `destroy` = وقف، الكود مش بيوصف الواقع. الهدف الأول zero-diff (أو diffs مفهومة ومقبولة)، وبعدين تغييرات مقصودة واحدة واحدة.

</details>

<details><summary>ليه <code>terraform plan</code> قال No changes رغم إن حد فتح بورت 22 على الـ SG؟</summary>

لأن الـ rules متدارة كـ `aws_vpc_security_group_ingress_rule` منفصلة، والـ rule الجديدة object مش في الـ state — Terraform مبيعرفش غير اللي في الـ state. ومع `aws_security_group` من غير `ingress` inline، الـ attribute ده computed فمفيش diff. `-refresh-only` ممكن يبيّنها بشكل غير مباشر، بس الحل الحقيقي طبقة compliance (AWS Config / Security Hub / EventBridge على CloudTrail) + منع الـ ClickOps بالـ IAM.

</details>

<details><summary>Drift detection: <code>plan</code> ولا <code>plan -refresh-only</code>؟</summary>

`-refresh-only` بيوريك كل اللي اتغير برّه Terraform — بما فيه الحقول المتجاهلة عن قصد (الـ CI بيملكها) فبيعمل noise. الـ `plan` العادي بيحترم `ignore_changes` وبيقول إيه اللي هيتغير فعلاً لو حد عمل apply — ده الـ signal اللي يهم. الاتنين لازم بنفس الـ inputs اللي اتعمل بيها الـ apply وإلا false positives.

</details>

<details><summary>إمتى تختار تعيد الإنشاء بدل الـ import؟</summary>

لما الـ resource cattle ورخيص (SG، ALB، role)، أو لما الـ import مش هيدخل في الـ module من غير replace أصلاً (instance في default VPC والـ stack بيعمل VPC خاص)، أو لما الإعدادات اليدوية مش موثوقة. import للـ stateful (DB، buckets بداتا، ECR بـ images)، والحاجات اللي بتتشاور عليها من برّه (Route 53 zone، OIDC provider، KMS keys)، أو اللي ليها limit زي OIDC provider واحد لكل URL.

</details>

<details><summary>الـ CI بيغيّر weights الـ ALB و Terraform بيرجّعها. صمّم الحل.</summary>

قرّر المالك. لو الـ CI (canary/blue-green أوتوماتيك): Terraform يعمل الـ listener مرة ويتجاهل `default_action` (`weights_managed_externally = true` في الـ ALB module — نسخة listener تانية لأن الـ lifecycle مش conditional)، والتحويل على stack شغال بـ `state mv` عشان الـ listener ميتمسحش. لو Terraform المالك: الـ CI يفتح PR بالـ weights الجديدة أو الـ engineer ينسخها للـ tfvars. الممنوع: الاتنين مالكين.

</details>

<details><summary>إزاي تمنع إن نفس الـ resource يتدار من اتنين states؟</summary>

قاعدة: object واحد = address واحد في state واحد. عملياً: tags `ManagedBy` و `Scenario`/stack على كل resource (موجود في الـ repo عن طريق `default_tags`)، كود review على أي `import`، أسماء deterministic بـ prefix لكل stack، وAWS Config/inventory يكشف resource عليه tags من stack-ين. لو اتنقل بين stacks: `removed { destroy = false }` من القديم ثم `import` في الجديد في نفس الـ change.

</details>

<details><summary>استوردت <code>aws_ssm_parameter</code> SecureString. ليه الملف المولّد فيه <code>value = null # sensitive</code>؟ وإيه الخيارات؟</summary>

Terraform مبيكتبش أي قيمة sensitive في الكود المولّد. الخيارات: (1) Terraform يملك الـ resource بس مش القيمة: placeholder + `ignore_changes = [value]`؛ (2) Terraform يملك القيمة (من `random_password` أو variable) ويكتبها في الـ apply — يعني rotation، وتأثيرها على `APP_KEY` = logout لكل المستخدمين؛ (3) write-only `value_wo` + `value_wo_version` عشان القيمة متتخزنش في الـ state أصلاً.

</details>

## 13) Checklist

- [ ] عملت import بـ `import` blocks و `-generate-config-out` في scratch ووصلت لـ zero-diff
- [ ] نضّفت الكود المولّد (references، secrets، SG rules، `ignore_changes` للـ pet)
- [ ] دخّلت ECR/OIDC/role في الـ bootstrap من غير ما تخسر الـ images، ونضّفت الـ policy attachment اليتيمة
- [ ] استخدمت `for_each` import للـ SSM params وفهمت ليه القيم بتتغير
- [ ] شفت الفرق بين `plan` و `plan -refresh-only` على drift حقيقي (بورت 22)
- [ ] فاهم كل drift مقصود في الـ repo ومين مالكه، وحل مشكلة الـ weights في stack 40
- [ ] مسحت الـ scratch state والـ `imports.tf` المؤقتة
