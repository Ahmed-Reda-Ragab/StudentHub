# 90 — Terraform بالتفصيل (modules، state، environments)

> **الهدف في سطر:** تفهم Terraform بمستوى Senior من الكود اللي في [`infra/terraform`](../../../infra/terraform/) نفسه: الـ providers والـ versions و `default_tags`، الـ variables/locals/outputs، `count` مقابل `for_each`، الـ dynamic blocks، تصميم الـ modules كـ "عقد"، الـ `lifecycle` (وليه كل `ignore_changes` في الـ repo موجود)، الـ remote state بـ S3 native locking، أوامر الـ `state`، `moved`/`removed`، استراتيجية الـ environments، الـ secrets جوه الـ state، و `terraform test` و tflint/checkov.
> **المستوى:** Intermediate → Advanced · **الوقت:** ~5 ساعات (قراءة + تمارين) · **التكلفة التقريبية:** القراءة والـ `validate`/`test`/`console` مجانية؛ تمارين الـ apply على stack 20 ≈ $0.03/ساعة
> **بيعتمد على:** [01 — الأدوات](01-tools-primer.md) · [03 — تجهيز الجهاز](03-workstation-setup.md) · [21 — EC2 بـ Terraform + Ansible](21-ec2-compose-terraform-ansible.md) · [51 — ECS بـ Terraform](51-ecs-fargate-terraform.md) · **الملفات في الـ repo:** [`infra/terraform/README.md`](../../../infra/terraform/README.md) · [`backend.hcl.example`](../../../infra/terraform/backend.hcl.example) · [`.tflint.hcl`](../../../infra/terraform/.tflint.hcl) · [`bootstrap/`](../../../infra/terraform/bootstrap/) · [`modules/`](../../../infra/terraform/modules/) · [`stacks/`](../../../infra/terraform/stacks/) · [`lint-infra.yml`](../../../.github/workflows/lint-infra.yml) · [CONVENTIONS §6](../CONVENTIONS.md)

## 1) الفكرة (Concepts)

Terraform أداة **declarative**: انت بتكتب الشكل النهائي (desired state)، وهو بيحسب الفرق بين 3 حاجات ويطلّع **plan**:

```text
   الكود (config)  ──┐
                     ├──► plan = إيه اللي لازم يتعمل/يتغيّر/يتمسح عشان الواقع يبقى زي الكود
   الـ state  ───────┤        (الـ state هو الخريطة: address في الكود ⇄ ID حقيقي في AWS)
   الواقع (AWS) ─────┘        refresh بيقرا الواقع ويحدّث الـ state قبل الحساب
```

أهم جملة تفهمها: **Terraform مبيعرفش غير اللي في الـ state.** أي resource مش في الـ state (اتعمل من الـ Console مثلاً) بالنسبة له مش موجود — ولو حاولت تعمله بنفس الاسم هيقع بـ `AlreadyExists` ([91](91-terraform-import-and-drift.md)).

| المصطلح | المعنى |
|---|---|
| Provider | plugin بيترجم الـ HCL لـ API calls (`hashicorp/aws` ~> 6.x هنا) |
| Resource / Data source | `resource` = حاجة Terraform بيملكها ويعملها/يمسحها · `data` = قراءة بس (`aws_caller_identity`، آخر AMI من SSM) |
| Root module / child module | الـ root = الفولدر اللي بتعمل فيه `init/plan/apply` (stack). الـ child = `module "x" { source = ... }` |
| Address | اسم الـ resource جوه الـ state: `module.alb.aws_lb_listener.http[0]`، `aws_ssm_parameter.app["APP_URL"]` |
| State / Backend / Lock | الـ state = JSON فيه كل الـ IDs والـ attributes (وكمان الـ secrets!) · الـ backend = مكانه (S3) · الـ lock = يمنع اتنين يكتبوا في نفس الوقت |
| Plan / Apply | الـ plan حساب، والـ apply تنفيذ. `-out=tfplan` بيحفظ الـ plan عشان تطبّق **نفس** اللي راجعته |
| Drift | الواقع اتغيّر برّه Terraform ([91](91-terraform-import-and-drift.md)) |
| Lifecycle | meta-arguments بتغيّر سلوك الـ resource (`ignore_changes`، `create_before_destroy`، `prevent_destroy`، `replace_triggered_by`) |

**الـ mental model بتاع الـ repo ده** (من [`infra/terraform/README.md`](../../../infra/terraform/README.md)):

| الطبقة | العمر | فيها إيه |
|---|---|---|
| `bootstrap/` | **long-lived**، مرة واحدة لكل account | state bucket، GitHub OIDC roles، ECR، CodeConnections، bucket الـ Ansible SSM |
| `modules/` | مكتبة | building blocks **من غير** `provider` ولا `backend` |
| `stacks/NN-*` | **ephemeral** | root modules: apply ← اتعلم ← destroy في نفس اليوم |

## 2) المعمارية (Architecture)

```text
 s3://student-app-tfstate-<account_id>/            (versioned · SSE · TLS-only · public access blocked)
 ├─ bootstrap/terraform.tfstate                     ← بعد الـ migrate-state (أول apply local)
 ├─ stacks/20-ec2-single/terraform.tfstate          + terraform.tfstate.tflock وقت الـ apply بس
 ├─ stacks/40-ec2-alb-asg/terraform.tfstate
 ├─ stacks/50-ecs-fargate/terraform.tfstate
 └─ ...                                             key متثبّت جوه كل stack (backend "s3" { key = ... })

 الـ stacks مبتقراش state بعض (مفيش terraform_remote_state). الـ data بتعدّي كده:

  bootstrap ──outputs (github_repository_variables)──► GitHub repo variables ──► workflows
  stack 50  ──terraform output -json pipeline_inputs──► stacks/36-codepipeline/stack50.auto.tfvars.json
  أي stack  ──aws_ssm_parameter──► /student-app/<env>/app/*  ◄── user-data / ECS secrets / ESO
  الأسماء   ── deterministic: "${var.project}-${var.env}" = student-app-lab-*  (CONVENTIONS §1)
  account/region ── data.aws_caller_identity / data.aws_region (مفيش IDs مكتوبة بإيدك)
```

ليه مفيش `terraform_remote_state`؟ لأنه بيربط الـ lifecycles: لو مسحت stack 50، الـ plan بتاع stack 36 اللي بيقرا الـ state بتاعه يقع. وكمان أي حد بيقرا state حد تاني بيقرا **كل** الـ secrets اللي فيه. الـ repo اختار "contracts" صريحة (أسماء + SSM + outputs مولّدة لملفات).

## 3) المتطلبات (Prerequisites)

- [ ] `terraform version` ≥ 1.11 (الـ `required_version` في كل `versions.tf` — الـ S3 native locking بقى GA في 1.11). الـ CI ([`terraform.yml`](../../../.github/workflows/terraform.yml)) مثبّت على `~1.14`، وآخر stable وقت كتابة الكلام ده **1.17.x** (نوفمبر 2026).
- [ ] `tflint` و (اختياري) `checkov` — نفس اللي بيشتغل في [`lint-infra.yml`](../../../.github/workflows/lint-infra.yml).
- [ ] للتمارين اللي فيها plan/apply: الـ [bootstrap](../../../infra/terraform/bootstrap/README.md) اتعمله apply و `infra/terraform/backend.hcl` موجود، و credentials بـ admin على الـ laptop.
- [ ] `jq` (لقراية `terraform show -json`) و `graphviz` (اختياري، لـ `terraform graph`).

## 4) الطريقة الأولى: من غير IaC (للمقارنة)

مفيش Console هنا — السيناريو ده عن الأداة نفسها. بس لازم تعرف تبرر ليه Terraform أصلاً:

| الطريقة | Reproducible؟ | Review قبل التنفيذ؟ | بيعرف يمسح اللي عمله؟ | Drift detection |
|---|---|---|---|---|
| Console (ClickOps) — [20](20-ec2-compose-console.md)، [50](50-ecs-fargate-console.md) | لأ | لأ | انت فاكر؟ | لأ |
| سكريبتات `aws cli` | نص نص (مش idempotent غالباً) | `git diff` على السكريبت بس | لازم تكتب سكريبت مسح | لأ |
| **Terraform / OpenTofu** | آه | **plan** | `destroy` من الـ state | `plan` / `-refresh-only` |
| CloudFormation / CDK | آه | change sets | stack delete | drift detection مدمج |
| Pulumi | آه | preview | destroy | refresh |

> 💡 الـ trade-off الحقيقي في الـ interview مش "Terraform أحسن": CloudFormation بيملك الـ state بنفسه (مفيش bucket تحميه ولا lock تديره) بس AWS-only وأبطأ في دعم الـ features؛ Terraform multi-provider وفيه ecosystem modules ضخم بس انت مسؤول عن الـ state وأمانه.

## 5) الطريقة التانية: Terraform من جوه الـ repo

### 5.1 الـ Layout والملفات

كل stack فيه نفس الملفات ([CONVENTIONS §6](../CONVENTIONS.md)): `versions.tf` (Terraform + providers + backend) · `providers.tf` · `variables.tf` · `main.tf` (+ ملفات حسب الموضوع زي `iam.tf`، `ssm.tf`، `dns.tf`) · `outputs.tf` · `terraform.tfvars.example` · `README.md`. Terraform بيقرا **كل** الـ `*.tf` في الفولدر كأنهم ملف واحد — تقسيم الملفات للبني آدمين بس.

### 5.2 الـ Providers والـ versions و `default_tags`

```hcl
# stacks/40-ec2-alb-asg/versions.tf  (مختصر — نفس المعنى)
terraform {
  required_version = ">= 1.11" # S3 native locking (use_lockfile) is GA since 1.11
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 6.0" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
  backend "s3" {
    key = "stacks/40-ec2-alb-asg/terraform.tfstate"
  }
}
```

- **الـ stacks بتثبّت (`~> 6.0`) والـ modules بتحدد حد أدنى بس (`>= 6.0`)** — شوف [`modules/alb/versions.tf`](../../../infra/terraform/modules/alb/versions.tf). القاعدة: الـ module بيقول "أنا محتاج على الأقل كذا"، والـ root هو اللي يختار النسخة الفعلية. لو الـ module ثبّت `~> 6.0` وجه root محتاج 7.x، الاتنين مش هيتفقوا أبداً.
- stack 50 بيطلب `~> 6.21` (الـ ECS native LINEAR/CANARY) و stack 60 بيطلب `~> 6.59` و `helm ~> 3.1` — كل stack بيرفع الحد على قد الـ features اللي بيستخدمها.
- **`.terraform.lock.hcl` مش موجود في الـ repo.** ده ملف بيتعمل بعد `terraform init` فيه النسخة الفعلية والـ checksums بتاعة كل provider. من غيره، CI النهارده ممكن ياخد 6.60 وبكرة 6.61 من غير ما حد يعرف. في production اعمله commit:

```bash
cd infra/terraform/stacks/40-ec2-alb-asg
terraform init -backend=false
terraform providers lock -platform=linux_amd64 -platform=darwin_arm64 -platform=windows_amd64
git add .terraform.lock.hcl     # ترقية مقصودة بعد كده: terraform init -upgrade
```

- **`default_tags`** في [`providers.tf`](../../../infra/terraform/stacks/40-ec2-alb-asg/providers.tf) بيحط `Project/Env/ManagedBy/Scenario` على كل resource مرة واحدة ([CONVENTIONS §1](../CONVENTIONS.md)). **الـ gotcha:** الـ instances اللي الـ ASG بيعملها مش بتورث الـ `default_tags` (الـ ASG هو اللي بيعملها مش Terraform). عشان كده [`modules/asg-app/main.tf`](../../../infra/terraform/modules/asg-app/main.tf) بيقرا `data "aws_default_tags" "this" {}` وبيحطهم في `tag_specifications` بتاع الـ launch template — ومن غير ده الـ Ansible inventory (`tag:Project=student-app`) والـ SSM Run Command scoping كانوا هيتعموا عن الـ fleet كله.

### 5.3 الـ Variables والـ Locals والـ Outputs

**Variables = الـ API بتاع الـ stack.** أمثلة حقيقية:

| النمط | المثال في الـ repo | ليه |
|---|---|---|
| Validation على قيمة | [`modules/alb/variables.tf`](../../../infra/terraform/modules/alb/variables.tf): `length(var.name) <= 26` | `"<name>-green"` لازم يدخل في حد الـ 32 حرف بتاع الـ TG — تفشل في الـ plan مش بعد 5 دقايق apply |
| Validation بين variables | [`stacks/40-ec2-alb-asg/variables.tf`](../../../infra/terraform/stacks/40-ec2-alb-asg/variables.tf): `var.domain_name == null \|\| var.hosted_zone_id != null` | الإشارة لـ variable تاني جوه `validation` متاحة من Terraform 1.9 |
| Validation بـ regex | stack 50: `image_tag` مش `latest` ([51](51-ecs-fargate-terraform.md)) | CONVENTIONS §2: ممنوع `latest` |
| Default "مستحيل" + `check` | stack 40: `image_tag = "unset"` + `check "image_is_set"` | warning مش error — الـ plan يكمّل، بس يحذّرك |
| Heredoc description | `private_instances`، `https_enabled` | الـ description هي الـ docs (و tflint بيجبرها) |

**ترتيب قيم الـ variables** (الأعلى يكسب): `-var` / `-var-file` على الـ command line ← `*.auto.tfvars` / `*.auto.tfvars.json` (أبجدي) ← `terraform.tfvars` ← `TF_VAR_<name>` env ← الـ default. أمثلة في الـ repo: stack 36 بيقرا `stack50.auto.tfvars.json` أوتوماتيك، و [`terraform.yml`](../../../.github/workflows/terraform.yml) بيمرر `TF_VAR_region` كـ env.

**Locals = مصدر حقيقة واحد للقيم المحسوبة** ([`stacks/40-ec2-alb-asg/main.tf`](../../../infra/terraform/stacks/40-ec2-alb-asg/main.tf)):

```hcl
locals {
  name      = "${var.project}-${var.env}" # student-app-lab
  image_uri = var.image_uri != null ? var.image_uri : "${local.ecr_repository_url}:${var.image_tag}"

  # Names are computed here (not read from the ASG modules) so observability can use them
  # while the ASGs consume observability's alarm names — no dependency cycle.
  asg_names = merge(
    { blue = "${local.name}-blue" },
    var.green_enabled ? { green = "${local.name}-green" } : {},
  )
}
```

السطر الأخير درس مهم: الـ ASG محتاج أسماء alarms من `module.observability`، والـ observability محتاج أسماء الـ ASGs. لو الاتنين أخدوا outputs من بعض = **cycle**. الحل: الاسم deterministic، فاحسبه في `locals` بدل ما تستناه كـ output. (نفس الحيلة في stack 50 — [51 §2](51-ecs-fargate-terraform.md).)

**Outputs = العقد مع العالم الخارجي:** `github_repository_variables` (bootstrap/stack 50) بيتحول لـ GitHub variables بـ `jq`، `backend_hcl` بيتكتب في `backend.hcl`، `migrate_command` / `release_commands` (stack 40) أوامر جاهزة، و `sre_lab_token` عليه `sensitive = true` (بيتخفى من الـ CLI output — **مش من الـ state**).

### 5.4 `count` مقابل `for_each`

| | `count` | `for_each` |
|---|---|---|
| الـ address | `aws_subnet.public[0]` (رقم) | `aws_ssm_parameter.app["APP_URL"]` (key) |
| لو شلت عنصر من النص | **كل اللي بعده يتنقل index** → destroy/recreate | العنصر ده بس يتمسح |
| الاستخدام الصح | on/off (`? 1 : 0`)، أو N نسخ متطابقة | مجموعة عناصر ليها هوية (أسماء، ports، colors) |
| شرط مهم | الـ **عدد** لازم يكون معروف وقت الـ plan | الـ **keys** لازم تكون معروفة وقت الـ plan |

أمثلة من الـ repo:

```hcl
# on/off toggle (bootstrap/github-oidc.tf, stacks/40 module "redis" / "asg_green")
resource "aws_iam_role" "terraform_plan" {
  count = var.create_terraform_plan_role ? 1 : 0
}
output "github_terraform_plan_role_arn" {
  value = var.create_terraform_plan_role ? aws_iam_role.terraform_plan[0].arn : null
}

# مجموعة ليها أسماء (stacks/20-ec2-single/ssm.tf)
resource "aws_ssm_parameter" "app" {
  for_each       = local.app_plain            # map: key = اسم الـ parameter
  name           = "${local.ssm_app}/${each.key}"
  insecure_value = each.value
}

# الـ secrets: for_each على list ثابتة من الأسماء، مش على الـ map نفسها
# "for_each over a literal key list: a map holding sensitive values cannot drive for_each."
resource "aws_ssm_parameter" "app_secret" {
  for_each = toset(local.app_secret_keys)     # ["APP_KEY", "DB_PASSWORD", "SRE_LAB_TOKEN"]
  value    = local.app_secrets[each.key]
}
```

**قاعدة "معروف وقت الـ plan"** — أكتر سبب للـ error `Invalid count argument` / `Invalid for_each argument`:

- [`modules/rds-mysql/main.tf`](../../../infra/terraform/modules/rds-mysql/main.tf) بيستخدم `count = length(var.allowed_security_group_ids)` **عن قصد** مش `for_each`: الـ SG IDs اللي بتتعمل في نفس الـ plan لسه unknown، فمينفعش تبقى keys — بس **طول** الـ list معروف.
- [`modules/observability/main.tf`](../../../infra/terraform/modules/observability/main.tf): `for_each = var.target_group_arn_suffixes` شغال رغم إن الـ suffixes unknown — لأن الـ **keys** (`blue`/`green`) ثابتة، والـ values بس اللي unknown.
- stack 40: `https_enabled = var.domain_name != null` بيتبعت للـ ALB module كـ switch صريح، لأن الـ `certificate_arn` جاي من resource في نفس الـ plan (unknown) ومينفعش يحرّك `count`. ([`modules/alb/variables.tf`](../../../infra/terraform/modules/alb/variables.tf) — شوف description الـ `https_enabled`.)

**`count` على الـ subnets** في [`modules/network/main.tf`](../../../infra/terraform/modules/network/main.tf) مقبول لأن الـ AZs بتتاخد بـ `slice(..., 0, var.az_count)` — زيادة AZ بتضيف في الآخر بس. لكن لو حد غيّر الـ list من النص، `aws_subnet.public[1]` يبقى AZ تانية = replace للـ subnet وكل اللي فيه. ده بالظبط نوع الـ refactor اللي `moved` بيحلّه (§5.10).

**Helpers للـ resources الاختيارية:** `one(module.redis[*].primary_endpoint_address)` (stack 40) بيرجّع القيمة أو `null`، و `try(module.codedeploy[0].app_name, null)` (stack 50). و `[for r in module.redis : ...]` بيلف على module عليه `count`.

### 5.5 الـ Dynamic blocks

بتستخدمها لـ nested block **اختياري** أو **متكرر**. أوضح مثال: الـ listener في [`modules/alb/main.tf`](../../../infra/terraform/modules/alb/main.tf):

```hcl
locals {
  http_forwards  = local.https ? [] : [1] # without a certificate HTTP carries traffic
  http_redirects = local.https ? [1] : [] # with one, HTTP only redirects to HTTPS
}

resource "aws_lb_listener" "http" {
  dynamic "default_action" {          # بيظهر بس لو فيه certificate
    for_each = local.http_redirects
    content { type = "redirect" ... }
  }
  dynamic "default_action" {          # بيظهر بس لو مفيش certificate
    for_each = local.http_forwards
    content {
      type = "forward"
      forward {
        dynamic "target_group" {      # متكرر: blue + green بالـ weights
          for_each = local.forward_groups
          content {
            arn    = target_group.value.arn
            weight = target_group.value.weight
          }
        }
        dynamic "stickiness" {        # اختياري
          for_each = var.stickiness_duration > 0 ? [var.stickiness_duration] : []
          content {
            enabled  = true
            duration = stickiness.value
          }
        }
      }
    }
  }
}
```

أمثلة تانية: `dynamic "launch_template"` مقابل `dynamic "mixed_instances_policy"` في [`asg-app`](../../../infra/terraform/modules/asg-app/main.tf) (واحد بس يظهر حسب `spot_enabled`)، `dynamic "tag_specifications"` على `toset(["instance","volume","network-interface"])`، `dynamic "access_logs"` في الـ ALB، و `dynamic "statement"` جوه `aws_iam_policy_document` في [`modules/codebuild/main.tf`](../../../infra/terraform/modules/codebuild/main.tf).

> ⚠️ متكترش منها: config فيه 4 مستويات dynamic محدش هيعرف يقراه. لو الـ block دايماً موجود اكتبه عادي.

### 5.6 تصميم الـ Modules (العقد)

الـ interfaces مكتوبة في [CONVENTIONS §6](../CONVENTIONS.md) و [`infra/terraform/README.md`](../../../infra/terraform/README.md). المبادئ اللي الـ repo ماشي عليها:

1. **مفيش `provider` ولا `backend` جوه module** — الـ root بيقرر الـ region والـ credentials والـ tags.
2. **inputs أساسية + extras بـ defaults**: `alb` محتاج `name, vpc_id, subnet_ids` بس، والباقي (`target_type`، `blue_weight`، `stickiness_duration`...) ليه defaults معقولة.
3. **outputs كـ maps بهوية**: `target_group_arns = { blue = ..., green = ... }` بدل list بترتيب محدش فاكره.
4. **switches صريحة لكل حاجة بتحرّك `count`**: `https_enabled`، `enable_alb_alarms`، `enable_request_scaling`، `create_security_group` (README: *"`count` cannot depend on values unknown until apply"*).
5. **`wait_for` + `terraform_data` بدل `depends_on` على الـ module كله** ([`asg-app/variables.tf`](../../../infra/terraform/modules/asg-app/variables.tf)): `depends_on` على module بيأجّل **كل** الـ data sources اللي جواه لوقت الـ apply (زي lookup الـ AMI) → كل plan يطلّع "launch template will be updated" على الفاضي. الحل:

```hcl
resource "terraform_data" "wait_for" {
  input = var.wait_for          # ARNs بتاعة SSM params اللي الـ user-data محتاجها
}
resource "aws_autoscaling_group" "this" {
  depends_on = [terraform_data.wait_for]   # ordering edge على resource واحد بس
}
```

6. **Guardrails جوه الـ module**: `precondition` في `aws_autoscaling_policy.requests` (لازم `alb_arn_suffix` و `target_group_arn_suffix`)، و `validation` على الـ variables. الفرق: `validation` على input واحد، `precondition`/`postcondition` على resource وبيشوف أي قيمة، و `check` (stack 40) بيطلّع warning ومبيوقفش.
7. **Registry modules بنسخة متثبتة**: stack 60 بيستخدم `terraform-aws-modules/vpc/aws ~> 6.8` و `terraform-aws-modules/eks/aws ~> 21.30`. الـ local modules (`../../modules/x`) مالهاش version — بتتغير مع الـ commit. لو هتشارك modules بين repos: git source بـ tag (`?ref=v1.4.0`) أو private registry.

### 5.7 الـ `lifecycle` — كل سطر وليه موجود

ده أهم جزء في الـ deep dive لأنه بيوضّح **حدود الملكية (ownership boundaries)** بين Terraform والـ CI والـ AWS نفسه:

| الـ resource | الـ lifecycle | السبب الحقيقي |
|---|---|---|
| `aws_ssm_parameter.image_uri` ([asg-app](../../../infra/terraform/modules/asg-app/main.tf)) | `ignore_changes = [value]` | `/student-app/<env>/deploy/<color>/IMAGE_URI` — Terraform بيعمله بقيمة أولية، والـ CI ([`deploy-asg.yml`](../../../.github/workflows/deploy-asg.yml)) بيعمل `put-parameter` لكل release. من غير ده أي apply = **rollback صامت** للـ image |
| `aws_ecs_service.app` ([ecs-fargate/service.tf](../../../infra/terraform/modules/ecs-fargate/service.tf)) | `ignore_changes = [task_definition, desired_count, load_balancer]` | الـ CI يملك الـ revision، الـ Auto Scaling يملك العدد، والـ deployer (ECS native / CodeDeploy) بيبدّل blue ⇄ green — تفاصيل في [51 §5.3](51-ecs-fargate-terraform.md) |
| `aws_lb_listener_rule.production` / `.test` (ECS native) | `ignore_changes = [action]` | ECS بيكتب الـ weights أثناء الـ deploy |
| `aws_lb_listener.http_external` / `.https_external` ([alb](../../../infra/terraform/modules/alb/main.tf)) | `ignore_changes = [default_action]` | CodeDeploy أو CI (`modify-listener`) بيملكوا الـ weights |
| `aws_autoscaling_group.this` | `ignore_changes = [desired_capacity]` | الـ scaling policies (والـ CI لما بيكبّر الـ idle color) |
| `aws_instance.this` ([ec2-docker-host](../../../infra/terraform/modules/ec2-docker-host/main.tf)) | `ignore_changes = [ami, user_data]` | **pet** فيه MySQL data: AL2023 جديد أو تعديل في `user-data.sh` ميعملش replace للسيرفر في السر. التغيير المقصود: `terraform apply -replace=module.host.aws_instance.this` |
| `aws_launch_template.this` | `create_before_destroy = true` (+ `name_prefix`) | النسخة الجديدة تتعمل قبل ما القديمة تتمسح والـ ASG لسه بيشاور عليها |
| `aws_db_parameter_group.this` ([rds-mysql](../../../infra/terraform/modules/rds-mysql/main.tf)) | `create_before_destroy = true` (+ `name_prefix`) | تغيير الـ family (8.4 → 9.x) محتاج group جديد قبل ما القديم (المربوط بالـ instance) يتمسح |
| `aws_acm_certificate.this` ([stack 40 dns.tf](../../../infra/terraform/stacks/40-ec2-alb-asg/dns.tf)) | `create_before_destroy = true` | الـ cert الجديد يتصدر قبل ما الـ listener يسيب القديم |

**ليه الـ ALB module فيه listener "مرتين"؟** لأن الـ `lifecycle` **مينفعش يبقى conditional** — الـ meta-arguments لازم تبقى literal وقت الـ parse (مينفعش `ignore_changes = var.x ? [...] : []`). فالـ module عامل نسختين وبيختار واحدة بـ `count`:

```hcl
resource "aws_lb_listener" "http" {
  count = var.weights_managed_externally ? 0 : 1      # Terraform يملك الـ weights
  ...
}
resource "aws_lb_listener" "http_external" {
  count = var.weights_managed_externally ? 1 : 0      # CI/CodeDeploy يملكوها
  ...
  lifecycle { ignore_changes = [default_action] }
}
locals {
  http_listener_arn = one(concat(aws_lb_listener.http[*].arn, aws_lb_listener.http_external[*].arn))
}
```

stack 50 بيحطها `= var.deployment_controller == "CODE_DEPLOY"`، و stack 40 بيعرّضها كـ `listener_weights_managed_externally` (الـ description بيقول *"Changing it recreates the listener"* — في §5.9 هتشوف إزاي تتجنب ده بـ `state mv`).

**`prevent_destroy` مش مستخدم في أي حتة في الـ repo — وده قرار:** الـ stacks ephemeral وموديلها كله `apply → destroy`، و `prevent_destroy = true` بيوقّف `terraform destroy` نفسه. وكمان هو مش حماية حقيقية: أي حد يقدر يشيل السطر أو يعمل `state rm`. ولأنه meta-argument مينفعش تخليه `var.protect`. الحماية في الـ repo بديلة:

| الحماية | فين |
|---|---|
| `force_destroy = var.state_bucket_force_destroy` (default `false`) | الـ state bucket ([bootstrap/main.tf](../../../infra/terraform/bootstrap/main.tf)) |
| `force_delete = var.ecr_force_delete` (default `false`) | ECR — الـ destroy يفشل لو فيه images |
| `deletion_protection = var.db_deletion_protection` | RDS (lab: `false`) — حماية على مستوى الـ API نفسه، أقوى من `prevent_destroy` |
| `enable_deletion_protection = var.enable_deletion_protection` | الـ ALB |
| S3 versioning 90 يوم | الـ state نفسه (undo) |

في production: `prevent_destroy` على الـ state bucket و RDS و ECR و Route 53 zones **بالإضافة** لـ `deletion_protection` على مستوى AWS.

> 💡 `replace_triggered_by` مش مستخدم هنا. مثال (مش في الـ repo) لو عايز الـ pet يتعمله replace لما سكريبت معين يتغير بس: `replace_triggered_by = [terraform_data.bootstrap_hash]` حيث `terraform_data.bootstrap_hash.input = filesha256("...")`.

### 5.8 الـ Remote state و S3 native locking

```hcl
# infra/terraform/backend.hcl.example  (partial config — مفيش key هنا عن قصد)
bucket       = "student-app-tfstate-123456789012"
region       = "us-east-1"
use_lockfile = true   # S3-native lock: <key>.tflock — مفيش DynamoDB
encrypt      = true
```

- **الـ `key` متثبّت جوه كل stack** (`backend "s3" { key = "stacks/40-ec2-alb-asg/terraform.tfstate" }`) فـ `backend.hcl` واحد يخدم كل الـ stacks، ومستحيل اتنين يكتبوا في نفس الـ state بالغلط. الـ CI بيمرر نفس الـ key صراحةً.
- **`use_lockfile`**: اتضاف experimental في Terraform 1.10 وبقى **GA في 1.11**، ومعاه بقت الـ arguments بتاعة DynamoDB (`dynamodb_table`) **deprecated** وهتتشال في minor version جاية. عشان كده كل `versions.tf` في الـ repo بيطلب `>= 1.11` ([CONVENTIONS §6](../CONVENTIONS.md)). الـ lock = object اسمه `stacks/40-ec2-alb-asg/terraform.tfstate.tflock` في نفس الـ bucket (يعني الـ IAM لازم يسمح بـ Put/Delete عليه).
- **الـ chicken-and-egg**: الـ bootstrap بيعمل الـ bucket نفسه، فأول apply بـ local state، وبعدين `terraform init -migrate-state -backend-config=../backend.hcl` ([bootstrap/README.md](../../../infra/terraform/bootstrap/README.md)).
- **حماية الـ bucket** ([bootstrap/main.tf](../../../infra/terraform/bootstrap/main.tf)): versioning (كل write بيحفظ النسخة اللي قبلها)، lifecycle بيمسح النسخ القديمة بعد 90 يوم **مع الاحتفاظ بآخر 10 دايماً**، SSE-S3، policy بتمنع أي request مش TLS، و public access block.

**لما الـ lock يعلّق** (apply اتقتل في النص):

```bash
terraform plan            # Error acquiring the state lock ... Lock Info: ID: 3c5d...  Who: ...  Operation: OperationTypeApply
# اتأكد إن مفيش apply شغال فعلاً (Actions tab، زميلك، terminal تاني) — وبعدين بس:
terraform force-unlock 3c5d0f3e-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

**لما الـ state يبوظ** (آخر حل — مش أول حل):

```bash
B=student-app-tfstate-<ACCOUNT_ID>; K=stacks/20-ec2-single/terraform.tfstate
aws s3api list-object-versions --bucket "$B" --prefix "$K" \
  --query 'Versions[].{v:VersionId,t:LastModified,latest:IsLatest}' --output table
aws s3api get-object --bucket "$B" --key "$K" --version-id <VERSION_ID> old.tfstate
terraform state push old.tfstate     # بيرفض لو الـ lineage مختلف أو الـ serial أقدم؛ -force = انت متأكد 100%
```

### 5.9 أوامر الـ `state` (state surgery)

```bash
cd infra/terraform/stacks/40-ec2-alb-asg
terraform init -backend-config=../../backend.hcl

terraform state list                                   # كل الـ addresses
terraform state list module.alb                        # جوه module واحد
terraform state show 'module.alb.aws_lb_listener.http[0]'
terraform state show 'aws_ssm_parameter.app["APP_URL"]'
terraform state pull > backup-$(date +%Y%m%d-%H%M).tfstate   # نسخة احتياطية قبل أي surgery
```

> ⚠️ في bash/zsh حط الـ address بين `'...'` (الأقواس والـ `"` ليهم معنى في الـ shell). في PowerShell الـ quoting مختلف — استخدم Git Bash أو WSL.

**مثال حقيقي لـ `state mv`: تحويل الـ weights لـ "CI-owned" من غير ما الـ listener يتمسح.** لو قلبت `listener_weights_managed_externally = true` في stack 40 مباشرة، الـ plan هيقول `destroy module.alb.aws_lb_listener.http[0]` و `create ...http_external[0]` — يعني الـ listener يتمسح (والـ rule بتاع `/metrics` معاه) ويتعمل تاني = ثواني من الـ 503. الاتنين نفس الـ resource type ونفس الـ attributes، الفرق `lifecycle` بس، فانقل الـ state:

```bash
terraform state pull > before-mv.tfstate
terraform state mv 'module.alb.aws_lb_listener.http[0]' 'module.alb.aws_lb_listener.http_external[0]'
# لو عندك HTTPS (domain_name متحدد) انقل التاني كمان:
# terraform state mv 'module.alb.aws_lb_listener.https[0]' 'module.alb.aws_lb_listener.https_external[0]'
terraform plan -var listener_weights_managed_externally=true     # المفروض: No changes
```

وبعدين حط `listener_weights_managed_externally = true` في `terraform.tfvars`. **ليه مش `moved` block؟** لأن الـ `moved` unconditional: لو اتحط جوه الـ module، أي caller سايب الـ variable `false` هيتنقل الـ state بتاعه لـ address مش موجود في الـ config → destroy. الـ switch ده قرار per-environment فمكانه `state mv` (وده كمان شغل laptop: [`terraform.yml`](../../../.github/workflows/terraform.yml) مبيعملش state commands).

**`state rm`** = "انسى الـ resource ده من غير ما تمسحه" (مثلاً هتنقله لـ stack تاني بـ import). بعده أي plan هيحاول يعمله تاني → `AlreadyExists`. البديل الأحسن من 1.7 هو `removed` block (الجزء الجاي) لأنه بيعدّي على PR وreview.

### 5.10 `moved` و `removed` blocks (refactoring من غير state surgery)

```hcl
# (مثال — مش في الـ repo) refactor للـ network module من count لـ for_each بالـ AZ name،
# عشان تغيير ترتيب الـ AZs ميعملش replace للـ subnets:
moved {
  from = aws_subnet.public[0]
  to   = aws_subnet.public["us-east-1a"]
}
moved {
  from = aws_subnet.public[1]
  to   = aws_subnet.public["us-east-1b"]
}

# (مثال) نقل resource لجوه module:
moved {
  from = aws_s3_bucket.backups
  to   = module.backups.aws_s3_bucket.this
}

# (مثال) إخراج bucket الـ Ansible SSM من الـ bootstrap من غير ما يتمسح (Terraform 1.7+):
removed {
  from = aws_s3_bucket.ansible_ssm
  lifecycle {
    destroy = false     # يتشال من الـ state بس، الـ bucket يفضل موجود
  }
}
```

| | `terraform state mv/rm` | `moved` / `removed` |
|---|---|---|
| بيعدّي على PR وreview؟ | لأ، بيتنفذ فوراً على الـ state | آه، جزء من الكود والـ plan |
| بيوصل لكل الـ environments؟ | لازم تعيده يدوي لكل state | أي state بيتطبّق عليه الكود |
| الإصدار | قديم | `moved` من 1.1 · `removed` من 1.7 · `import` block من 1.5 (و `for_each` جواه من 1.7) |
| إمتى | قرارات per-state (زي §5.9) أو طوارئ | refactor دائم للكود |

سيب الـ `moved` blocks فترة (كل الـ states تكون اتطبقت) وبعدين امسحها. الـ modules اللي بتتشارك بين فرق: سيبها للأبد تقريباً.

### 5.11 استراتيجية الـ Environments

| الطريقة | الفكرة | مزايا | عيوب |
|---|---|---|---|
| **dir-per-stack** (الـ repo ده) | فولدر لكل root module، state key لكل واحد | blast radius صغير، lifecycles مختلفة (bootstrap دايم / stacks مؤقتة)، roles وreviews مختلفة لكل stack، الـ plan صغير وسريع | تكرار wiring، لازم contracts بين الـ stacks |
| workspaces (CLI) | نفس الكود، state لكل workspace | سهل لنسخ متطابقة (`lab`, `lab2`) | الـ backend والـ credentials واحدة لكل الـ workspaces، سهل تعمل apply على الغلط، والفرق بين البيئات بيتحول لـ `terraform.workspace == "prod" ? ...` في كل حتة |
| dir-per-env (`envs/prod`, `envs/staging`) + modules | فولدر لكل بيئة | فصل واضح، backend/role مختلف لكل بيئة | تكرار (Terragrunt/Terramate بيقللوه) |
| HCP Terraform workspaces | workspace لكل stack×env | remote runs، RBAC، policies | تكلفة/vendor |

**ليه الـ repo اختار stacks:** كل stack = نوع deploy مختلف (EC2 / ASG / ECS / EKS) مش نفس الحاجة ببيئات مختلفة، والـ lifecycle مختلف جذرياً (bootstrap مينفعش يتمسح مع stack 40). البُعد "environment" موجود كـ variable `env` (CONVENTIONS §1) بيغيّر الأسماء ومسار SSM.

> ⚠️ **Gotcha:** `-var env=lab2` بيغيّر الأسماء بس — **مش** الـ state key. الـ README بيقترحها لتشغيل **stack تاني مختلف** جنب الأول (كل stack ليه key خاص فمفيش مشكلة). لكن لو شغّلت **نفس** الـ stack بـ `env=lab2` على نفس الـ key، الـ plan هيقولك replace لكل موارد `lab` بدل ما يعمل بيئة جنبها. لنسختين من نفس الـ stack استخدم workspace (الـ state بيتحط في `env:/lab2/stacks/40-ec2-alb-asg/terraform.tfstate`) أو key مختلف:

```bash
terraform workspace new lab2 && terraform plan -var env=lab2
# أو
terraform init -reconfigure -backend-config=../../backend.hcl -backend-config="key=stacks/40-ec2-alb-asg-lab2/terraform.tfstate"
```

### 5.12 الـ Secrets جوه الـ state

الـ state بيحتوي كل attribute — **حتى اللي عليه `sensitive`**. في الـ repo ده جوه الـ state: `random_password.*.result`، `random_bytes.app_key`، قيم الـ `SecureString` في `aws_ssm_parameter.app_secret`، و `password` بتاع RDS. [`modules/rds-mysql/main.tf`](../../../infra/terraform/modules/rds-mysql/main.tf) بيقولها صريحة: *"The password is in Terraform state ... use_secrets_manager = true removes it."*

| الأسلوب | في الـ repo؟ | الـ secret في الـ state؟ | ملاحظة |
|---|---|---|---|
| `random_password` + SSM `value` | ✅ (الافتراضي) | آه | محمي بـ bucket مشفّر + TLS-only + IAM. **مين يقرا الـ bucket يقرا الـ secrets** |
| `sensitive = true` | ✅ (`sre_lab_token`) | آه | بيخفي من الـ CLI output بس |
| `insecure_value` للقيم العادية | ✅ (`DB_HOST`، `APP_URL`) | — | عشان الـ plan يفضل مقروء (الـ `value` دايماً sensitive في الـ plan) |
| RDS `manage_master_user_password` | ✅ (`use_secrets_manager = true`) | لأ | AWS بيولّد الباسورد ويحطه في Secrets Manager ويعمل rotation |
| Ephemeral resources (1.10) + write-only args (1.11) | ❌ | **لأ** | الطريقة الحديثة (تحت) |
| OpenTofu state encryption | ❌ | مشفّر client-side | لو بتستخدم OpenTofu بدل Terraform |

```hcl
# (مثال — مش في الـ repo) SSM secret من غير ما يتكتب في الـ state:
ephemeral "random_password" "sre_lab_token" {   # random provider >= 3.7
  length  = 32
  special = false
}
resource "aws_ssm_parameter" "sre_lab_token" {
  name             = "${local.ssm_app}/SRE_LAB_TOKEN"
  type             = "SecureString"
  value_wo         = ephemeral.random_password.sre_lab_token.result   # write-only: مبيتخزنش
  value_wo_version = 1                                                 # زوّده = rotate
}
```

الـ trade-offs: Terraform مبقاش شايف القيمة → مفيش drift detection عليها، والـ rotation يدوي (تزوّد `value_wo_version`)، ومينفعش تعمل `output` بالقيمة (الـ `sre_lab_token` output بتاع stack 20/40 كان هيتشال). وأي حد بيقرا الـ plan JSON القديم برضه مش هيلاقيها — وده المكسب.

> 💡 **نقطة interview من [`github-oidc.tf`](../../../infra/terraform/bootstrap/github-oidc.tf):** الـ plan role "read-only" بس محتاج يقرا الـ state bucket ويعمل decrypt للـ SecureStrings عشان الـ refresh → **أي حد عنده write على الـ repo يقدر يقرا الـ secrets** من plan على PR. ده سبب قوي للـ write-only attributes.

### 5.13 `terraform test` (مقدمة)

Terraform 1.6 جاب `terraform test` بملفات `*.tftest.hcl`، و 1.7 جاب `mock_provider` (تختبر من غير AWS credentials ولا فلوس). الـ repo لسه مفيهوش tests — ده تمرين:

```hcl
# infra/terraform/modules/network/tests/network.tftest.hcl   (تمرين — مش في الـ repo)
mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = { names = ["us-east-1a", "us-east-1b", "us-east-1c"] }
  }
}

variables {
  name = "student-app-test"
}

run "cidr_layout_two_azs" {
  command = plan
  assert {
    condition     = aws_subnet.public[0].cidr_block == "10.20.0.0/20" && aws_subnet.public[1].cidr_block == "10.20.16.0/20"
    error_message = "public subnets must take the first /20 blocks"
  }
  assert {
    condition     = aws_subnet.private[0].cidr_block == "10.20.128.0/20"
    error_message = "private subnets must start halfway through the VPC (no renumbering when AZs are added)"
  }
  assert {
    condition     = length(aws_nat_gateway.this) == 0
    error_message = "NAT must be OFF by default (~32 USD/month each)"
  }
}

run "single_nat_when_enabled" {
  command = plan
  variables {
    enable_nat = true
    az_count   = 3
  }
  assert {
    condition     = length(aws_nat_gateway.this) == 1 && length(aws_route.private_nat) == 3
    error_message = "single_nat=true: one NAT shared by every private route table"
  }
}
```

```hcl
# infra/terraform/modules/alb/tests/alb.tftest.hcl   (تمرين)
mock_provider "aws" {
  mock_data "aws_vpc" {
    defaults = { cidr_block = "10.20.0.0/16" }   # بيتستخدم في egress rule الـ ALB SG — قيمة CIDR صالحة بدل string عشوائي
  }
}

variables {
  vpc_id     = "vpc-0123456789abcdef0"
  subnet_ids = ["subnet-aaaa", "subnet-bbbb"]
  name       = "student-app-lab"
}

run "name_too_long_is_rejected" {
  command = plan
  variables {
    name = "student-app-lab-very-long-x"   # 27 حرف
  }
  expect_failures = [var.name]
}

run "external_weights_use_the_ignore_variant" {
  command = plan
  variables {
    weights_managed_externally = true
  }
  assert {
    condition     = length(aws_lb_listener.http) == 0 && length(aws_lb_listener.http_external) == 1
    error_message = "weights_managed_externally must select the listener with ignore_changes"
  }
}
```

```bash
cd infra/terraform/modules/network
terraform init                 # mock provider لسه محتاج الـ schema بتاع الـ provider
terraform test                 # Success! 2 passed, 0 failed.
terraform test -verbose        # يطبع الـ plan لكل run
```

الـ `[0].cidr_block` معروف وقت الـ plan لأنه جاي من الـ config (`cidrsubnet`)، فـ `command = plan` كفاية. الـ attributes الـ computed (زي `id`) قيمتها مولّدة من الـ mock. ضيف `terraform test` لـ job الـ terraform في `lint-infra.yml` لما تكتب tests.

### 5.14 tflint و checkov

[`.tflint.hcl`](../../../infra/terraform/.tflint.hcl):

| الإعداد | ليه |
|---|---|
| `call_module_type = "local"` | يفحص الـ calls لـ `../../modules/*` بقيم الـ caller (مثلاً instance type غلط بيتبعت للـ module) |
| `plugin "terraform" { preset = "recommended" }` | قواعد اللغة: unused declarations، deprecated syntax، required_version/providers |
| `plugin "aws" { version = "0.50.0" ... deep_check = false }` | قواعد AWS (instance types، invalid values) — من غير API calls لأن الـ CI مالوش credentials في الـ lint |
| `terraform_documented_variables` / `_outputs` | كل variable وoutput لازم ليه `description` |

الـ job في [`lint-infra.yml`](../../../.github/workflows/lint-infra.yml): `fmt -check -recursive` → `init -backend=false` + `validate` لكل root (bootstrap + كل stack، من غير backend ولا AWS) → `tflint --init` ثم `tflint --recursive --chdir=infra/terraform --config "$PWD/infra/terraform/.tflint.hcl" --minimum-failure-severity=error` (الـ config بـ **absolute path** لأن `--recursive` بيدوّر على `.tflint.hcl` في كل فولدر) → checkov بـ `soft_fail: true` (report only — الـ findings بتتناقش في [82](82-supply-chain-security.md)).

```bash
# نفس الـ CI على جهازك
terraform fmt -check -recursive -diff infra/terraform
cfg="$PWD/infra/terraform/.tflint.hcl"
tflint --init --config="$cfg" && tflint --recursive --chdir=infra/terraform --config="$cfg"
checkov -d infra/terraform --framework terraform --compact --quiet
```

لما checkov يطلع finding مقبول في الـ lab، الصح تكتب السبب جنب الـ resource بدل ما تقفل الـ check كله: `# checkov:skip=<CHECK_ID>:<السبب>` — زي التعليق الموجود فعلاً فوق `aws_sns_topic.alerts` في [`modules/observability/main.tf`](../../../infra/terraform/modules/observability/main.tf) اللي بيشرح ليه مفيش SSE (لكن من غير الـ skip annotation).

## 6) التمارين (بدل الـ Deploy)

**تمرين 1 — offline (مجاني):**

```bash
cd infra/terraform/stacks/40-ec2-alb-asg
terraform init -backend=false
terraform validate
terraform console <<'EOF'
cidrsubnet("10.20.0.0/16", 4, 0)
cidrsubnet("10.20.0.0/16", 4, 0 + pow(2, 4 - 1))
trimsuffix(trimsuffix("/student-app/lab/app", "/"), "/app")
can(regex("^t[0-9]", "t3.micro"))
EOF
```

المتوقع: `10.20.0.0/20`، `10.20.128.0/20`، `/student-app/lab` (نفس الحسبة اللي [asg-app](../../../infra/terraform/modules/asg-app/main.tf) بيعملها لاسم الـ IMAGE_URI parameter)، `true` (اللي بيقرر `credit_specification`).

**تمرين 2 — اقرا plan زي الـ reviewer:**

```bash
cd infra/terraform/stacks/20-ec2-single
cp terraform.tfvars.example terraform.tfvars
terraform init -backend-config=../../backend.hcl
terraform plan -out=tfplan
terraform show -json tfplan | jq -r '.resource_changes[] | "\(.change.actions | join(",")) \(.address)"' | sort | uniq -c | sort -rn | head -40
terraform graph | dot -Tsvg > graph.svg     # اختياري: الـ DAG
```

**تمرين 3 — apply و state و lifecycle:**

```bash
terraform apply tfplan
terraform state list | wc -l
terraform state show module.host.aws_instance.this | grep -E 'ami |user_data|instance_type'
# ignore_changes = [ami, user_data]: عدّل سطر comment في deploy/ec2/user-data.sh محلياً ثم:
terraform plan          # No changes — الـ pet محمي
git checkout -- ../../../../deploy/ec2/user-data.sh
terraform plan -replace=module.host.aws_instance.this   # كده بس هيتعمل replace (متطبّقش)
```

**تمرين 4 — `terraform test`:** انسخ ملفات §5.13 لفولدر شخصي أو branch تجريبي وشغّلها (`terraform test`) — مفيش AWS calls.

## 7) التحقق (Verify)

```bash
terraform plan -detailed-exitcode; echo "exit=$?"        # 0 = الواقع = الكود
aws s3 ls "s3://student-app-tfstate-$(aws sts get-caller-identity --query Account --output text)/stacks/" --recursive
# أثناء apply في terminal تاني — المفروض تشوف الـ lock object:
aws s3 ls "s3://student-app-tfstate-<ACCOUNT_ID>/stacks/20-ec2-single/"
aws resourcegroupstaggingapi get-resources --tag-filters Key=ManagedBy,Values=terraform Key=Scenario,Values=20 \
  --query 'ResourceTagMappingList[].ResourceARN' --output text | tr '\t' '\n' | head
```

المفروض: exit=0 بعد الـ apply، key واحد لكل stack، `terraform.tfstate.tflock` يظهر وقت الـ apply ويختفي بعده، وكل resource عليه الـ default tags.

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر | المتوقع |
|---|---|---|
| Apply متوازي | `terraform apply` في terminal-ين على stack 20 | التاني: `Error acquiring the state lock` ومعاه Who/Operation |
| Lock معلّق | Ctrl+C مرتين في نص apply | الـ `.tflock` بيفضل → `terraform force-unlock <ID>` بعد ما تتأكد |
| `latest` | `terraform -chdir=infra/terraform/stacks/50-ecs-fargate plan -var image_tag=latest` | validation error قبل أي API call |
| `check` مش `validation` | `terraform plan` في stack 40 من غير `image_tag` | **Warning** `image_tag is still "unset"` والـ plan بيكمّل |
| اسم طويل | `-var project=student-app-long-name` في stack 40 | validation الـ ALB module (`<= 26`) |
| شيل `ignore_changes` | علّق `ignore_changes = [value]` في asg-app محلياً بعد CI deploy ثم `plan` على stack 40 | update لـ `IMAGE_URI` بالقيمة القديمة = الـ rollback الصامت اللي السطر بيمنعه |
| `state rm` | `terraform state rm 'aws_ssm_parameter.app["METRICS_ENABLED"]'` ثم `apply` | `ParameterAlreadyExists` → رجّعه بـ import ([91](91-terraform-import-and-drift.md)) |
| Drift يدوي | `aws ssm put-parameter --name /student-app/lab/app/SRE_LAB_ENABLED --value false --overwrite` ثم `plan` | update in-place يرجّعها `true` — Terraform مالك القيمة |

## 9) الرجوع (Rollback)

- **تغيير infra بايظ:** `git revert` → `terraform plan` → `apply`. ده الطريق الطبيعي — الـ state بيتبع الكود.
- **Resource اتعمله replace غلط:** مفيش undo؛ الحماية قبلها: اقرا الـ plan (`must be replaced`)، و `deletion_protection` / `prevent_destroy` على الـ stateful.
- **State بايظ:** نسخة من S3 versioning + `terraform state push` (§5.8) — بعد `state pull` backup للحالي.
- **Refactor غلط بـ `moved`:** امسح الـ `moved` block قبل الـ apply؛ لو اتطبّق اعمل `moved` عكسي.

## 10) المسح (Teardown) ⚠️

```bash
cd infra/terraform/stacks/20-ec2-single
terraform destroy
rm -f tfplan graph.svg before-mv.tfstate backup-*.tfstate     # ملفات محلية فيها secrets
aws resourcegroupstaggingapi get-resources --tag-filters Key=Project,Values=student-app \
  --query 'ResourceTagMappingList[].ResourceARN' --output text
```

> ⚠️ ملفات الـ `*.tfstate` اللي سحبتها بـ `state pull` فيها **كل الـ secrets** بـ plain text. الـ `.gitignore` بيمنع الـ commit بتاعها (`*.tfstate`، `*.tfstate.*`) بس متسيبهاش على الـ disk.

## 11) التكلفة (Cost)

| البند | التكلفة |
|---|---|
| `validate` / `console` / `test` بـ mocks / tflint / checkov | مجاني |
| stack 20 للتمارين 2–3 | ≈ $0.03/ساعة ([stack 20 README](../../../infra/terraform/stacks/20-ec2-single/README.md)) |
| الـ state bucket (versions + lock objects) | سنتات/شهر |

## 12) أسئلة Interview

<details><summary>إيه الفرق بين <code>count</code> و <code>for_each</code>؟ وإمتى <code>count</code> هو الاختيار الصح رغم كل حاجة؟</summary>

`count` بيعمل addresses برقم، فشيل عنصر من النص بيعمل shift لكل اللي بعده (destroy/recreate). `for_each` بيعمل addresses بـ key ثابت. `count` صح في: on/off (`? 1 : 0`)، ولما الـ keys مش معروفة وقت الـ plan بس الطول معروف — زي `aws_vpc_security_group_ingress_rule.from_sg` في `rds-mysql` اللي بيلف على SG IDs بتتعمل في نفس الـ plan. القاعدة: `for_each` keys و `count` length لازم يبقوا known at plan.

</details>

<details><summary>ليه الـ ALB module فيه نسختين من نفس الـ listener؟</summary>

لأن `lifecycle.ignore_changes` لازم يبقى literal — مينفعش يبقى conditional على variable. عايزين حالتين: Terraform يملك الـ weights (blue/green بالـ tfvars) أو CI/CodeDeploy يملكوها (ignore `default_action`). فيه resource لكل حالة بـ `count` متعاكس، و `one(concat(a[*].arn, b[*].arn))` بيوحّد الـ output. التحويل بين الحالتين على stack شغال بيتعمل بـ `terraform state mv` عشان الـ listener ميتمسحش.

</details>

<details><summary>إمتى <code>ignore_changes</code> صح وإمتى بيبقى code smell؟</summary>

صح لما فيه **مالك تاني شرعي** للحقل بعد الإنشاء: CI بيملك الـ image (`task_definition`، `IMAGE_URI`)، Auto Scaling بيملك `desired_count`، CodeDeploy بيملك الـ listener. Smell لما بيتستخدم عشان "يسكّت" diff مش فاهمه (provider bug، default بيتغير، حد بيعدّل من الـ Console) — كده انت بتخبّي drift. كل `ignore_changes` لازم تعليق يقول مين المالك، زي اللي في الـ repo.

</details>

<details><summary>Workspaces ولا فولدر لكل stack/env؟ دافع عن اختيار الـ repo.</summary>

الـ workspaces مناسبة لنسخ متطابقة بنفس الـ backend والـ credentials. هنا الـ stacks مش بيئات لنفس الحاجة — دي معماريات مختلفة بـ lifecycles مختلفة (bootstrap دايم، الباقي ephemeral)، وكل stack محتاج plan صغير وblast radius صغير وممكن role مختلف. الـ env موجود كـ variable للأسماء. لو احتجت prod حقيقي: backend/account منفصل لكل env (dir-per-env أو Terragrunt) عشان credentials الـ staging متقدرش تلمس prod أصلاً.

</details>

<details><summary>الـ state فيه secrets. إزاي تحميها؟ وإيه اللي اتغير في Terraform الحديث؟</summary>

تقليدياً: backend مشفّر (SSE/KMS)، TLS-only، versioning، IAM ضيق على الـ bucket والـ `.tflock`، ومتعملش outputs للـ secrets إلا `sensitive`. بس `sensitive` بيخفي من الـ output بس. الحديث: ephemeral resources (1.10) و write-only arguments (1.11) زي `value_wo` في `aws_ssm_parameter` و `password_wo` في `aws_db_instance` — القيمة بتتبعت للـ API ومبتتخزنش. أو تخلي AWS يولّدها (`manage_master_user_password`). الـ trade-off: مفيش drift detection على القيمة والـ rotation بـ version bump.

</details>

<details><summary>إيه الفرق بين <code>moved</code> و <code>terraform state mv</code>؟</summary>

`state mv` imperative: بيتنفذ فوراً على state واحد، من غير review، ولازم تعيده لكل environment. `moved` declarative: جزء من الكود، بيظهر في الـ plan، بيعدّي على PR، وبيتطبّق على أي state يشغّل الكود ده. استخدم `moved` للـ refactor الدائم، و `state mv` للقرارات per-state (زي تحويل listener stack 40 لـ external weights) لأن `moved` unconditional.

</details>

<details><summary>ليه الـ modules بتقول <code>>= 6.0</code> والـ stacks <code>~> 6.0</code>؟ وإيه دور <code>.terraform.lock.hcl</code>؟</summary>

الـ module بيعلن أقل نسخة محتاجها؛ الـ root هو اللي بيختار النسخة الفعلية — لو كل module ثبّت range ضيق، الـ constraints هتتعارض. الـ constraint بيحدد المسموح، لكن الـ lock file هو اللي بيثبّت النسخة **والـ checksums** فعلاً عشان كل init (laptop وCI) ياخد نفس الـ binary. الـ repo مش عامل commit للـ lock files — في production لازم، والترقية تبقى PR مقصود بـ `terraform init -upgrade`.

</details>

<details><summary>ليه <code>depends_on</code> على module كامل ممكن يعمل diff في كل plan؟</summary>

لأن Terraform بيأجّل قراءة **كل** الـ data sources جوه الـ module لوقت الـ apply لو الـ module نفسه depends_on حاجة لسه هتتغير/unknown — فقيم زي AMI ID تبقى "known after apply" والـ launch template يظهر كأنه هيتغير. الـ repo حلّها بـ `var.wait_for` → `terraform_data` → `depends_on` على الـ ASG بس.

</details>

<details><summary><code>check</code> و <code>precondition</code> و <code>validation</code> — الفرق؟</summary>

`validation` على variable واحد (من 1.9 يقدر يشوف variables تانية) وبيوقف الـ plan. `precondition`/`postcondition` على resource/output وبتشوف أي قيمة وبتوقف (زي `asg-app` requests policy). `check` block (1.5+) بيطلّع **warning** بس ومبيوقفش — مناسب لـ "حاجة غلط بس مش مستاهلة توقف" زي `image_tag = "unset"` في stack 40، ومناسب كمان للـ health assertions بعد الـ apply.

</details>

## 13) Checklist

- [ ] فاهم الـ 3 طبقات (bootstrap / modules / stacks) وإزاي الـ stacks بتشارك data من غير remote state
- [ ] أقدر أشرح كل `ignore_changes` و `create_before_destroy` في الـ repo ومين المالك
- [ ] جرّبت `state list/show/pull` وفاهم إمتى `state mv` وإمتى `moved`
- [ ] شفت الـ `.tflock` وجرّبت `force-unlock`
- [ ] كتبت وشغّلت `terraform test` بـ `mock_provider`
- [ ] شغّلت fmt/validate/tflint/checkov زي الـ CI
- [ ] عملت destroy ومسحت ملفات الـ state المحلية
