# 37 — AWS CodeDeploy لـ EC2/ASG

> **الهدف في سطر:** تعمل deploy للتطبيق على الـ ASG بتاع stack 40 بـ **CodeDeploy** (compute platform `Server`): revision صغيرة (image reference + سكريبتات، مش source code) بـ [`package-revision.sh`](../../../deploy/codedeploy/ec2/package-revision.sh)، `appspec.yml` و hooks الـ lifecycle (BlockTraffic → ApplicationStop … ValidateService → AllowTraffic)، in-place مقابل blue/green (نسخ الـ ASG)، deployment configs (OneAtATime/HalfAtATime/AllAtOnce)، و rollback تلقائي على الفشل والـ alarms.
> **المستوى:** Advanced · **الوقت:** ~3–4 ساعات · **التكلفة التقريبية:** نفس [42](42-alb-asg-launch-template.md) (~$0.08/ساعة لـ stack 40)؛ CodeDeploy على EC2 مجاني
> **بيعتمد على:** [42 — ALB + ASG](42-alb-asg-launch-template.md) (stack 40) · [32](32-cd-ec2-ecr-ssm.md) (نفس `deploy-pull-image.sh`) · [44](44-rolling-instance-refresh.md) (للمقارنة) · **الملفات في الـ repo:** [`deploy/codedeploy/ec2/`](../../../deploy/codedeploy/ec2/) ([`README.md`](../../../deploy/codedeploy/ec2/README.md) · [`appspec.yml`](../../../deploy/codedeploy/ec2/appspec.yml) · [`package-revision.sh`](../../../deploy/codedeploy/ec2/package-revision.sh) · [`hooks/`](../../../deploy/codedeploy/ec2/hooks/)) · [`infra/terraform/modules/codedeploy/`](../../../infra/terraform/modules/codedeploy/main.tf) · [`infra/terraform/stacks/40-ec2-alb-asg/codedeploy.tf`](../../../infra/terraform/stacks/40-ec2-alb-asg/codedeploy.tf) (`codedeploy_enabled`، `codedeploy_revision_bucket`، `codedeploy_deployment_config_name`، output `codedeploy`) · [`infra/terraform/modules/asg-app/user-data.sh.tftpl`](../../../infra/terraform/modules/asg-app/user-data.sh.tftpl) · [`deploy/ec2/deploy-pull-image.sh`](../../../deploy/ec2/deploy-pull-image.sh)

## 1) الفكرة (Concepts)

في [44](44-rolling-instance-refresh.md) الـ release على الـ ASG = تغيير الـ SSM pointer + **instance refresh** (instances جديدة — immutable). **CodeDeploy** طريقة تانية: **agent** على كل instance بينزّل **revision** من S3 ويشغّل **hooks** بترتيب ثابت، وCodeDeploy بيتحكم في الـ traffic (يشيل الـ instance من الـ target group، يحدّثه، يتحقق منه، يرجّعه) و في الـ pace (واحد واحد/نص/كله) وبيعمل **rollback تلقائي**.

| المصطلح | المعنى |
|---|---|
| Application | حاوية منطقية (`student-app-lab-ec2`) بـ compute platform (`Server` = EC2/on-prem) |
| Deployment group | الـ targets (ASGs و/أو EC2 tags) + service role + config + LB + alarms + rollback |
| Revision | zip في S3 فيه `appspec.yml` + ملفات + hooks |
| AppSpec (`version: 0.0`) | `files` (تتنسخ فين) + `hooks` (سكريبت + timeout + runas لكل lifecycle event) |
| Deployment config | الـ pace: `OneAtATime` (افتراضي)، `HalfAtATime`، `AllAtOnce`، أو custom (minimum healthy hosts) |
| In-place | نفس الـ instances بتتحدّث (مع traffic control: deregister → hooks → register) |
| Blue/green (Server) | CodeDeploy **بينسخ الـ ASG** (`COPY_AUTO_SCALING_GROUP`)، يعمل deploy على الجديد، يحوّل الـ LB، ويمسح القديم |
| Auto rollback | deployment جديد بيعيد نشر **آخر revision ناجحة** لما يحصل `DEPLOYMENT_FAILURE` أو `DEPLOYMENT_STOP_ON_ALARM` |

| القرار | اخترنا | البديل | ليه |
|---|---|---|---|
| محتوى الـ revision | **image reference** + سكريبتات | source code + build على الـ instance | build once (الـ image اتعمله test/scan في CI)؛ الـ revision بـ KBs |
| منطق الـ deploy | نفس `deploy-pull-image.sh` (32/33) | سكريبتات جديدة | code path واحد لكل الطرق |
| النوع | **IN_PLACE** + traffic control | BLUE_GREEN | الـ blue/green بينسخ الـ ASG لنسخة Terraform مايعرفهاش (drift) — في-place شغال مع الـ ASG المُدار |
| Config | `OneAtATime` | Half/All | N-1 capacity، والـ migration بتحصل مرة (أول instance) |

## 2) المعمارية (Architecture)

```text
 laptop/CI: package-revision.sh <ecr>/student-app:<sha> → dir (appspec.yml, IMAGE_URI, deploy.env, compose, scripts/, hooks/)
            aws deploy push → s3://<REVISION_BUCKET>/codedeploy/student-app-<sha>.zip (+ register revision)
            aws deploy create-deployment (app student-app-lab-ec2, group student-app-lab-ec2)
                       │
                       ▼
 CodeDeploy (service role: AWSCodeDeployRole) ── OneAtATime ── alarms: student-app-lab-alb-5xx-ratio ── auto rollback
   │ لكل instance في ASG student-app-lab-blue:
   │  BlockTraffic: deregister من TG blue (ALB draining)                      ┌ ALB ─ listener ─ TG blue ─┐
   │  ApplicationStop  (hooks من الـ revision القديمة)                         │   ▲ register (AllowTraffic)│
   │  DownloadBundle → BeforeInstall → Install (files → /opt/student-app/release)│   ▼ deregister (BlockTraffic)
   │  AfterInstall → ApplicationStart (deploy-pull-image.sh) → ValidateService  └──── EC2 (asg-app) ─────────┘
   │  AllowTraffic: register + healthy في الـ TG                                codedeploy-agent (user data لما
   ▼                                                                             codedeploy_enabled = true)
 instance التالي ... ── فشل/alarm → STOP → rollback = deployment جديد بآخر revision ناجحة
 ASG launch lifecycle hook (بيضيفه CodeDeploy) → أي instance جديد (scale-out) بياخد آخر revision ناجحة
```

## 3) المتطلبات (Prerequisites)

- [ ] stack 40 شغال ([42](42-alb-asg-launch-template.md)) — instances healthy خلف الـ ALB، RDS، والـ SSM params.
- [ ] image في ECR بـ tag SHA.
- [ ] `codedeploy_enabled = true` في stack 40 (§5.1) — ده بيعمل **كل حاجة**: الـ agent + Compose على الـ instances، الـ revision bucket، الـ IAM، والـ CodeDeploy application + deployment group ([`codedeploy.tf`](../../../infra/terraform/stacks/40-ec2-alb-asg/codedeploy.tf)).
- الأدوات: `aws`، `terraform`، `jq`، Linux/WSL (الـ `package-revision.sh` بيظبط الـ executable bit — من Windows هيضيع).

> ⚠️ **مفيش GitHub workflow لـ 37:** الـ release بالـ CLI (أو الـ Console). والـ deploy role (`student-app-gha-deploy`) عنده صلاحيات CodeDeploy بس **مالوش S3 write على الـ revision bucket**، فـ `aws deploy push` من GitHub Actions هيفشل لحد ما تضيف الصلاحية دي (تمرين: statement `s3:PutObject` على `<revision_bucket>/codedeploy/*` في [`github-oidc.tf`](../../../infra/terraform/bootstrap/github-oidc.tf) + workflow).

## 4) الطريقة الأولى: AWS Console (يدوي)

الـ Terraform (§5) بيعمل الـ app والـ group؛ هنا بتقرا اللي اتعمل في الـ Console، وبتبني deployment group **تاني بإيدك** في نفس الـ application عشان تتعلّم الـ wizard، وبتعمل deployment من الـ Console.

### 4.1 اقرا اللي Terraform عمله

1. **CodeDeploy → Applications → `student-app-lab-ec2`** (Compute platform: EC2/On-premises) → **Deployment groups → `student-app-lab-ec2`** → **Edit** (من غير Save) — كل field قصاده الـ input في الـ module:
   - Service role `student-app-lab-ec2-codedeploy` (`AWSCodeDeployRole`) · Deployment type **In-place** (`deployment_type = "IN_PLACE"`).
   - Environment configuration: **Amazon EC2 Auto Scaling groups** → `student-app-lab-blue` (`autoscaling_group_names`).
   - Deployment settings: `CodeDeployDefault.OneAtATime` (`codedeploy_deployment_config_name` = null).
   - Load balancer: ✅ **Application Load Balancer** → target group blue (`server_target_group_names` → `WITH_TRAFFIC_CONTROL`).
   - Advanced → Alarms: `student-app-lab-alb-5xx-ratio` (`alarm_names`) · Rollbacks: on failure + on alarm (`auto_rollback_events`).
2. **S3 → `student-app-lab-codedeploy-<acct>`** → Properties (SSE-S3) · Management (lifecycle `expire-old-revisions` 30 يوم) · Permissions (public access blocked).
3. **EC2 → Auto Scaling groups → `student-app-lab-blue` → Instance management → Lifecycle hooks** → hook اسمه `CodeDeploy-managed-automatic-launch-deployment-hook-...` (CodeDeploy بيضيفه).

### 4.2 Deployment group بإيدك (تمرين على الـ wizard)

**`student-app-lab-ec2` → Create deployment group:**

- Name `student-app-lab-ec2-console` · Service role `student-app-lab-ec2-codedeploy` (نفس الـ role).
- Deployment type **In-place** · Environment: ✅ **Amazon EC2 Auto Scaling groups** → `student-app-lab-blue`.
- **Install AWS CodeDeploy Agent:** **Never** (الـ user data بيعمله).
- Deployment settings: `CodeDeployDefault.HalfAtATime` (عشان تشوف الفرق).
- Load balancer: ✅ **Application Load Balancer** → TG blue (`terraform -chdir=infra/terraform/stacks/40-ec2-alb-asg output -json target_group_names`).
- Advanced → Alarms: `student-app-lab-alb-5xx-ratio` · Rollbacks: ✅ when a deployment fails · ✅ when alarm thresholds are met.
- **Create deployment group**.

> ⚠️ طول ما الـ group ده موجود، الـ ASG عليه **اتنين** launch hooks (واحد لكل group) — أي scale-out هيعمل deployment من الاتنين. امسحه بعد التمرين (§10). نفس الـ bucket والـ instance role بيشتغلوا (الـ role عنده `s3:GetObject` على الـ bucket).

### 4.3 Deployment من الـ Console

بعد ما ترفع revision (§6.1): **Deployment group → Create deployment** → Revision type **My application is stored in Amazon S3** → `s3://student-app-lab-codedeploy-<acct>/codedeploy/student-app-<sha>.zip` · File type **.zip** → Create. افتح الـ deployment → **Deployment lifecycle events** → **View events** لكل instance: كل hook بالمدة والـ status، ولو فشل → **View logs** (آخر output من السكريبت).

## 5) الطريقة التانية: Infrastructure as Code (stack 40)

### 5.1 الـ toggles

```bash
cd infra/terraform/stacks/40-ec2-alb-asg
cat >> terraform.tfvars <<'EOF'
codedeploy_enabled = true
# codedeploy_revision_bucket        = "<EXISTING_BUCKET>"         # اختياري: فاضي = الـ stack يعمل <name>-codedeploy-<account>
# codedeploy_deployment_config_name = "CodeDeployDefault.HalfAtATime"   # null = OneAtATime
EOF
terraform plan -out=tfplan && terraform apply tfplan
terraform output codedeploy
# { application = "student-app-lab-ec2", deployment_group = "student-app-lab-ec2",
#   revision_bucket = "student-app-lab-codedeploy-<acct>", release = "dir=$(…package-revision.sh …) && aws deploy push … && aws deploy create-deployment …" }
```

| Variable | الافتراضي | المعنى |
|---|---|---|
| `codedeploy_enabled` | `false` | agent + Compose في الـ user data، الـ bucket، الـ IAM، والـ app + deployment group |
| `codedeploy_revision_bucket` | `""` | bucket موجود؛ فاضي = الـ stack يعمل `student-app-lab-codedeploy-<account>` |
| `codedeploy_deployment_config_name` | `null` | `CodeDeployDefault.OneAtATime` \| `HalfAtATime` \| `AllAtOnce` (null = OneAtATime) |

### 5.2 اللي بيتعمل

| Resource | فين | التفاصيل |
|---|---|---|
| user data: Compose plugin (`compose_version` = `v2.39.4`) + `dnf install ruby wget` + `install auto` للـ **CodeDeploy agent** | [`user-data.sh.tftpl`](../../../infra/terraform/modules/asg-app/user-data.sh.tftpl) (`install_codedeploy_agent`) | الـ hooks بتشغّل التطبيق بـ `docker compose`؛ الـ agent محتاج Ruby |
| Revision bucket `student-app-lab-codedeploy-<acct>` (لو `codedeploy_revision_bucket` فاضي) | [`codedeploy.tf`](../../../infra/terraform/stacks/40-ec2-alb-asg/codedeploy.tf) | public access block، SSE-S3، lifecycle `expire-old-revisions` **30 يوم**، `force_destroy = true` (الـ revisions بتتعمل تاني من git) — **مش versioned** |
| Inline policy `student-app-codedeploy-revisions` على `student-app-lab-asg-app`: `s3:GetObject`/`GetObjectVersion` على `bucket/*` | [`iam.tf`](../../../infra/terraform/stacks/40-ec2-alb-asg/iam.tf) | الـ agent بينزّل الـ revision بالـ instance role |
| `module "codedeploy"` (`name = student-app-lab-ec2`، `compute_platform = "Server"`، `deployment_type = "IN_PLACE"`) | `codedeploy.tf` → [`modules/codedeploy`](../../../infra/terraform/modules/codedeploy/main.tf) | application + deployment group على `module.asg_blue.asg_name`، traffic control على TG blue، alarm `alb_5xx_ratio`، auto rollback (`DEPLOYMENT_FAILURE`، `DEPLOYMENT_STOP_ON_ALARM`)، service role `student-app-lab-ec2-codedeploy` (`AWSCodeDeployRole` + trust بـ `aws:SourceAccount`) |
| output `codedeploy` | [`outputs.tf`](../../../infra/terraform/stacks/40-ec2-alb-asg/outputs.tf) | الأسماء + أوامر الـ release (`package-revision.sh` → `aws deploy push` → `create-deployment`) |

> ⚠️ تغيير الـ user data = launch template version جديدة → الـ ASG بيعمل **instance refresh** (instances جديدة فيها الـ agent). استنى لحد ما يخلص (`aws autoscaling describe-instance-refreshes --auto-scaling-group-name student-app-lab-blue`) قبل أول deployment.

> 💡 ليه `IN_PLACE` في الـ stack؟ الـ comment في `codedeploy.tf`: `BLUE_GREEN` بينسخ الـ ASG برّه الـ Terraform state (§6.4). والـ group على **blue بس** — لو `green_enabled = true` (السيناريو 45) الـ green ASG مش جزء منه.

## 6) الـ Deploy

### 6.1 Package → push → deploy

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REV_BUCKET=$(terraform -chdir=infra/terraform/stacks/40-ec2-alb-asg output -json codedeploy | jq -r .revision_bucket)
terraform -chdir=infra/terraform/stacks/40-ec2-alb-asg output -json codedeploy | jq -r .release   # نفس الأوامر اللي تحت
TAG=$(aws ecr describe-images --repository-name student-app --query 'sort_by(imageDetails,&imagePushedAt)[-1].imageTags[0]' --output text)
IMAGE=$ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/student-app:$TAG       # (repo:tag@sha256:… كمان شغال — §6.4)
DIR=$(deploy/codedeploy/ec2/package-revision.sh "$IMAGE")              # stack 40 = RDS → من غير --local-mysql
ls -la "$DIR" "$DIR/hooks"                                              # appspec.yml IMAGE_URI deploy.env docker-compose.prod.yml scripts/ hooks/ (0755)
cat "$DIR/deploy.env"                                                   # USE_LOCAL_MYSQL=false  ENV_NAME=lab

aws deploy push --application-name student-app-lab-ec2 \
  --s3-location "s3://$REV_BUCKET/codedeploy/student-app-$TAG.zip" --source "$DIR"
DID=$(aws deploy create-deployment --application-name student-app-lab-ec2 \
  --deployment-group-name student-app-lab-ec2 \
  --s3-location "bucket=$REV_BUCKET,key=codedeploy/student-app-$TAG.zip,bundleType=zip" \
  --description "release $TAG" --query deploymentId --output text)
aws deploy wait deployment-successful --deployment-id "$DID"
```

متابعة كل instance و hook:

```bash
aws deploy get-deployment --deployment-id "$DID" --query 'deploymentInfo.{status:status,overview:deploymentOverview,rollback:rollbackInfo}'
for t in $(aws deploy list-deployment-targets --deployment-id "$DID" --query targetIds --output text); do
  aws deploy get-deployment-target --deployment-id "$DID" --target-id "$t" \
    --query 'deploymentTarget.instanceTarget.lifecycleEvents[].[lifecycleEventName,status]' --output text
done
```

### 6.2 الـ AppSpec والـ hooks lifecycle

```yaml
version: 0.0
os: linux
files:
  - source: /
    destination: /opt/student-app/release
file_exists_behavior: OVERWRITE
hooks:
  ApplicationStop:  [{ location: hooks/application-stop.sh,  timeout: 120, runas: root }]
  BeforeInstall:    [{ location: hooks/before-install.sh,    timeout: 300, runas: root }]
  AfterInstall:     [{ location: hooks/after-install.sh,     timeout: 120, runas: root }]
  ApplicationStart: [{ location: hooks/application-start.sh, timeout: 900, runas: root }]   # pull + migrate بياخدوا وقت
  ValidateService:  [{ location: hooks/validate-service.sh,  timeout: 300, runas: root }]
```

(ده نفس [`appspec.yml`](../../../deploy/codedeploy/ec2/appspec.yml) بشكل مضغوط.) `file_exists_behavior: OVERWRITE` عشان الـ redeploy على نفس المسار مايفشلش بـ "file already exists".

ترتيب الـ events لـ **in-place مع load balancer** (اللي بالخط العريض هو اللي فيه سكريبت بتاعنا):

| # | Event | مين | بيعمل إيه هنا |
|---|---|---|---|
| 1 | BeforeBlockTraffic | (scriptable) | — |
| 2 | **BlockTraffic** | CodeDeploy | deregister من الـ TG + انتظار الـ draining (ALB `deregistration_delay`) |
| 3 | AfterBlockTraffic | (scriptable) | — |
| 4 | **ApplicationStop** | [`application-stop.sh`](../../../deploy/codedeploy/ec2/hooks/application-stop.sh) — **من الـ revision القديمة** (مش بيجري أول مرة) | افتراضياً **بيسيب** الـ container شغال (لو الـ deploy فشل قبل ApplicationStart، الـ rollback يلاقي نسخة شغالة)؛ `STOP_APP_ON_APPLICATION_STOP=true` = `compose stop app` |
| 5 | DownloadBundle | agent | ينزّل الـ zip من S3 (instance role) |
| 6 | **BeforeInstall** | [`before-install.sh`](../../../deploy/codedeploy/ec2/hooks/before-install.sh) | Docker شغال، `docker compose version`، `aws` موجود؛ **يشيل الـ container `student-app`** اللي الـ user data شغّله بـ `docker run` (عشان compose ياخد بورت 80)؛ يمسح `release/` القديم |
| 7 | Install | agent | ينسخ الـ `files` لـ `/opt/student-app/release` |
| 8 | **AfterInstall** | [`after-install.sh`](../../../deploy/codedeploy/ec2/hooks/after-install.sh) | يرفض `IMAGE_URI` فاضي أو من غير tag أو `:latest`؛ `chmod`؛ ينسخ `docker-compose.prod.yml` لـ `/opt/student-app` |
| 9 | **ApplicationStart** | [`application-start.sh`](../../../deploy/codedeploy/ec2/hooks/application-start.sh) | يقرا `deploy.env`؛ `mysql.env` فاضي لو مش موجود (compose بيحمّل env files كل الـ services)؛ `deploy-pull-image.sh <IMAGE_URI>`: ECR login → SSM → `app.env` → pull → **migrate** → recreate → `CURRENT_RELEASE` |
| 10 | **ValidateService** | [`validate-service.sh`](../../../deploy/codedeploy/ec2/hooks/validate-service.sh) | `/ready` لازم 200 **و** `"version"` = الـ tag (30 × 5s)؛ لو فشل يطبع آخر 50 سطر logs ويخرج 1 |
| 11 | BeforeAllowTraffic | (scriptable) | — |
| 12 | **AllowTraffic** | CodeDeploy | register في الـ TG واستنى healthy (الـ ALB health check على `/ready`) |
| 13 | AfterAllowTraffic | (scriptable) | — |

> 💡 **Migrations:** بتجري في ApplicationStart على **كل** instance، بس مع `OneAtATime` أول واحد بس هو اللي عنده شغل (الباقي `Nothing to migrate`). وأثناء ده الـ instances التانية لسه بالكود القديم على الـ schema الجديدة → **expand/contract إجباري** ([95](95-zero-downtime-db-migrations.md)). مع `AllAtOnce` كل الـ instances هتحاول تعمل migrate في نفس الوقت — محتاج migrations idempotent و lock-safe.

### 6.3 Deployment configs

| Config | Minimum healthy | السلوك | الاستخدام |
|---|---|---|---|
| `CodeDeployDefault.OneAtATime` (افتراضي الـ module) | كل الـ instances ماعدا واحد | instance واحد في المرة؛ أول فشل يوقف (لو مش آخر instance) | الأأمن، الأبطأ؛ N-1 capacity |
| `CodeDeployDefault.HalfAtATime` | 50% | نص الـ fleet في المرة | توازن |
| `CodeDeployDefault.AllAtOnce` | 0 | الكل مرة واحدة (مع traffic control = كل الـ instances برّه الـ TG = **outage**) | dev بس |
| Custom | `FLEET_PERCENT` أو `HOST_COUNT` | | |

```bash
aws deploy create-deployment-config --deployment-config-name student-app-75pct \
  --minimum-healthy-hosts type=FLEET_PERCENT,value=75 --compute-platform Server
```

### 6.4 In-place مقابل blue/green (نسخ الـ ASG)

| | In-place (اخترناه) | Blue/green (`COPY_AUTO_SCALING_GROUP`) |
|---|---|---|
| الـ instances | نفسها بتتحدّث | ASG جديد (نسخة) بـ instances جديدة |
| الـ capacity أثناء الـ deploy | N-1 (OneAtATime) | 2N مؤقتاً |
| Rollback | redeploy للـ revision القديمة (دقايق) | الـ LB يرجع للقديم لو لسه مامسحوش (`termination_wait_time_in_minutes`، افتراضي 5) |
| Terraform | الـ ASG المُدار بيفضل هو هو | الـ ASG الجديد **مش في الـ state** → drift؛ الـ module بيحذّر: استخدمه على ASG تجريبي |
| محتاج | agent + traffic control اختياري | load balancer + `instance_role_arns` (PassRole) + `RunInstances` |
| Events | الجدول فوق | على الجديد: ApplicationStop…ValidateService ثم BeforeAllowTraffic/AllowTraffic؛ على القديم: Before/Block/AfterBlockTraffic ثم termination |

قارنه بالـ blue/green بتاع [45](45-bluegreen-two-asgs.md) (اتنين ASG في Terraform + listener weights) — ده Terraform-friendly أكتر.

> 💡 **tag ولا digest في `IMAGE_URI`؟** الاتنين: `validate-service.sh` بيشيل `@sha256:…` الأول (`ref="${image%@*}"`) وبعدين ياخد الـ tag (`${ref##*:}`) ويقارنه بـ `"version"` من `/ready`. يعني تقدر تثبّت الـ revision على digest (زي [32](32-cd-ec2-ecr-ssm.md)) والـ validation بتفضل شغالة — والـ digest أحسن: الـ revision بتشاور على bytes محددة.

## 7) التحقق (Verify)

```bash
URL=$(terraform -chdir=infra/terraform/stacks/40-ec2-alb-asg output -raw app_url)
for i in $(seq 1 6); do curl -s "$URL/ready" | jq -r '.version'; done      # كله = $TAG
bash deploy/scripts/probe.sh "$URL/ready" 0 0.2                            # شغّله أثناء deployment تاني: OneAtATime + traffic control = 0 failures (مع instances ≥ 2)
aws elbv2 describe-target-health --target-group-arn "$(terraform -chdir=infra/terraform/stacks/40-ec2-alb-asg output -json target_group_arns | jq -r .blue)" \
  --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State]' --output text
aws deploy list-deployments --application-name student-app-lab-ec2 --deployment-group-name student-app-lab-ec2 --max-items 5
aws autoscaling describe-lifecycle-hooks --auto-scaling-group-name student-app-lab-blue --query 'LifecycleHooks[].LifecycleHookName'   # CodeDeploy-managed-automatic-launch-deployment-hook-...
```

على instance (Session Manager):

```bash
systemctl status codedeploy-agent --no-pager
sudo tail -50 /var/log/aws/codedeploy-agent/codedeploy-agent.log
sudo tail -50 /opt/codedeploy-agent/deployment-root/deployment-logs/codedeploy-agent-deployments.log   # output الـ hooks
sudo cat /opt/student-app/CURRENT_RELEASE; sudo docker ps --format '{{.Names}} {{.Image}}'           # student-app-app-1 (compose) بدل student-app
```

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر | المتوقع |
|---|---|---|
| image مش موجودة | `package-revision.sh <ecr>/student-app:deadbee` → push → deploy | ApplicationStart يفشل (`manifest unknown`) على أول instance → deployment Failed → **auto rollback** (deployment جديد بآخر revision ناجحة) → الباقي مااتلمسش |
| `:latest` | `package-revision.sh <ecr>/student-app:latest` | `package-revision.sh` نفسه بيرفض (exit 64)؛ ولو عدّى، `after-install.sh` بيرفض |
| Version غلط | revision بـ `IMAGE_URI` لـ image شغالة بس الـ tag مش هو الـ `APP_VERSION` بتاعها (مثلاً tag `ci-v2`) | ValidateService يفشل (`ready but version '...' != 'ci-v2'`) → rollback — الـ hook بيتأكد إن **النسخة الجديدة** هي اللي بترد، مش بس إن حاجة بترد |
| Alarm أثناء الـ deploy | ابدأ deployment، وفي نفس الوقت: `for i in $(seq 300); do curl -s -o /dev/null -H "X-Lab-Token: <TOKEN>" "$URL/sre-lab/error?rate=1"; done` | `student-app-lab-alb-5xx-ratio` → ALARM → `DEPLOYMENT_STOP_ON_ALARM` → stop + rollback |
| Config fault (الدرس المهم) | `aws ssm put-parameter --name /student-app/lab/app/SRE_FAULT_UNHEALTHY --type String --value true --overwrite` ثم deploy | ValidateService يفشل → rollback… **والـ rollback كمان يفشل**: الـ revision القديمة بتعمل render لنفس الـ SSM → نفس العطل. الـ rollback بيرجّع **الكود**، مش الـ **config**. امسح الـ parameter |
| الـ agent واقف | Session Manager → `sudo systemctl stop codedeploy-agent` على instance ثم deploy | الـ instance ده يفضل Pending → بعد timeout الـ deployment Failed (`The CodeDeploy agent did not ... `) — شغّله تاني |
| Hook من غير exec bit | ارفع revision معمولة من Windows (`aws deploy push --source deploy/codedeploy/ec2`) | الـ hook يفشل بـ permission denied — عشان كده `package-revision.sh` بيعمل `chmod 0755` |
| Scale-out بعد deploy | `aws autoscaling set-desired-capacity --auto-scaling-group-name student-app-lab-blue --desired-capacity 3` | الـ instance الجديد بيبوت بالـ image من الـ SSM pointer، وبعدين الـ launch hook بيخلي CodeDeploy يحط آخر revision → InService بالنسخة الصح. لاحظ إن `/student-app/lab/deploy/blue/IMAGE_URI` **مااتحدّثش** → drift بين الـ pointer و CodeDeploy |

## 9) الرجوع (Rollback)

```bash
# 1) تلقائي: DEPLOYMENT_FAILURE / DEPLOYMENT_STOP_ON_ALARM → deployment جديد (rollbackInfo فيه الـ ID)
aws deploy get-deployment --deployment-id "$DID" --query 'deploymentInfo.rollbackInfo'
# 2) يدوي أثناء deployment شغال: stop + rollback
aws deploy stop-deployment --deployment-id "$DID" --auto-rollback-enabled
# 3) يدوي بعد ما خلص: deploy للـ revision القديمة (الـ zip في الـ bucket بالـ tag — الـ lifecycle بيمسح بعد 30 يوم؛
#    أقدم من كده: package-revision.sh للـ tag القديم تاني (الـ image لسه في ECR لو ضمن آخر 30) ثم push)
aws deploy create-deployment --application-name student-app-lab-ec2 --deployment-group-name student-app-lab-ec2 \
  --s3-location "bucket=$REV_BUCKET,key=codedeploy/student-app-<OLD_TAG>.zip,bundleType=zip" --description "rollback to <OLD_TAG>"
```

> ⚠️ الـ migrations مبترجعش، والـ config (SSM) مش جزء من الـ revision (شوف الـ break-it).

## 10) المسح (Teardown) ⚠️

```bash
# 1) الـ group اللي عملته بإيدك في §4.2 (Terraform مايعرفهوش)
aws deploy delete-deployment-group --application-name student-app-lab-ec2 --deployment-group-name student-app-lab-ec2-console   # بيشيل الـ lifecycle hook بتاعه

# 2) CodeDeploy بتاع الـ stack: يا تقفله وتسيب stack 40 (app + group + role + bucket بيتمسحوا؛ الـ bucket force_destroy)
cd infra/terraform/stacks/40-ec2-alb-asg
sed -i 's/^codedeploy_enabled = true/codedeploy_enabled = false/' terraform.tfvars
terraform plan -out=tfplan && terraform apply tfplan          # user data اتغيّر → instance refresh (من غير agent)
#    ... يا تمسح stack 40 كله ([42]): terraform destroy

# 3) اتأكد
aws deploy list-applications --query 'applications'
aws autoscaling describe-lifecycle-hooks --auto-scaling-group-name student-app-lab-blue --query 'LifecycleHooks[].LifecycleHookName'
aws autoscaling describe-auto-scaling-groups --query "AutoScalingGroups[?starts_with(AutoScalingGroupName,'CodeDeploy_')].AutoScalingGroupName"   # نسخ blue/green يتيمة لو جرّبته
```

> ⚠️ لو استخدمت `codedeploy_revision_bucket` لـ bucket موجود، الـ stack **مش** هيمسحه (مش بتاعه) — امسحه بإيدك لو مش محتاجه.

## 11) التكلفة (Cost)

| Resource | السعر التقريبي (تقريبي — راجع صفحة الأسعار) |
|---|---|
| CodeDeploy على EC2/ASG | مجاني (الـ on-premises بس بيتحاسب لكل instance update) |
| S3 revisions | سنتات (كل revision بـ KBs) |
| stack 40 (ALB + 2× t3.micro + RDS + alarms) | ~$0.08/ساعة ([42](42-alb-asg-launch-template.md)) |
| Blue/green | الـ fleet بيتضاعف لدقايق أثناء الـ deploy |

## 12) أسئلة Interview

<details><summary>اشرح lifecycle الـ in-place deployment مع load balancer.</summary>

لكل instance حسب الـ config: BeforeBlockTraffic → BlockTraffic (deregister + draining) → AfterBlockTraffic → ApplicationStop (من الـ revision القديمة) → DownloadBundle → BeforeInstall → Install → AfterInstall → ApplicationStart → ValidateService → BeforeAllowTraffic → AllowTraffic (register + healthy) → AfterAllowTraffic. الـ events بتاعة الـ traffic والـ download/install بيعملها CodeDeploy/الـ agent؛ الباقي hooks بتاعتك. أي hook يرجّع exit ≠ 0 أو يعدّي الـ timeout → الـ instance فشل.

</details>

<details><summary>ليه ApplicationStop بيجري من الـ revision القديمة؟ وإيه مشكلته؟</summary>

لأن الـ revision الجديدة لسه مانزلتش (ApplicationStop قبل DownloadBundle)، فالـ agent بيستخدم الـ hooks بتاعة آخر deployment ناجح على الـ instance. المشكلة: لو الـ script القديم بايظ، كل deployment جديد بيفشل في ApplicationStop — الحل `--ignore-application-stop-failures` مرة، أو تصليح الـ instance. وأول deployment مالوش ApplicationStop أصلاً.

</details>

<details><summary>CodeDeploy in-place مقابل ASG instance refresh؟</summary>

Instance refresh = immutable: instances جديدة من launch template/pointer، الـ rollback = refresh تاني، ومفيش agent. CodeDeploy in-place = mutable: نفس الـ instances بتتحدّث بالـ hooks، أسرع (مفيش boot)، فيه lifecycle hooks غنية و alarm-based stop، بس حالة الـ instances بتتراكم (drift)، ومحتاج agent، وفيه source of truth تاني غير الـ launch template (الـ revision). الاتجاه الحديث: immutable (refresh/blue-green)؛ CodeDeploy مفيد لـ legacy أو لما الـ boot بطيء.

</details>

<details><summary>Auto rollback في CodeDeploy بيعمل إيه بالظبط؟ وإمتى مبيكفيش؟</summary>

بيعمل **deployment جديد** بآخر revision ناجحة على الـ group (مش undo سحري). مبيكفيش لما المشكلة في الـ config/secrets (SSM) أو الـ data/schema (migration هدّامة) — الكود القديم هيقابل نفس المشكلة. عشان كده: config versioned مع الـ release أو feature flags، و migrations backward compatible، و alarms بتمسك الأعراض (5xx/latency) مش بس الـ health checks.

</details>

<details><summary>إزاي CodeDeploy بيتعامل مع scale-out في الـ ASG؟</summary>

لما تضيف ASG للـ deployment group، CodeDeploy بيحط launch lifecycle hook على الـ ASG؛ أي instance جديد بيستنى في `Pending:Wait` لحد ما CodeDeploy ينزّل عليه آخر revision ناجحة، وبعدها يبقى InService. لو deployment شغال وقت الـ scale-out ممكن الـ instance ياخد النسخة القديمة (فيه سيناريوهات معروفة لده). وفي الـ repo ده الـ user data نفسه بيشغّل image من الـ SSM pointer الأول، فلازم تفتكر إن الـ pointer مابيتحدّثش مع CodeDeploy.

</details>

<details><summary>ليه blue/green بتاع CodeDeploy على EC2 مش صاحب Terraform؟</summary>

`COPY_AUTO_SCALING_GROUP` بيعمل ASG جديد باسم من عنده ويمسح القديم بعد الـ switch. Terraform فاكر الـ ASG القديم → الـ plan الجاي عايز يعمله تاني (أو يلاقي اسم مختلف) = drift دائم. البدائل: blue/green بـ اتنين ASG في Terraform والـ CI يحرّك الـ listener weights ([45](45-bluegreen-two-asgs.md))، أو in-place، أو ECS/K8s.

</details>

<details><summary>الـ revision فيها image reference بس — ليه ده أحسن من source code؟</summary>

build once: الـ image اتعمله test وscan في الـ CI، والـ instance مبيبنيش (مفيش build tools على الـ prod، مفيش اختلافات بين instances). الـ revision صغيرة وسريعة، والـ rollback = revision فيها image قديمة. والـ hooks بتعيد استخدام نفس `deploy-pull-image.sh` اللي SSM و Ansible بيستخدموه → سلوك واحد.

</details>

## 13) Checklist

- [ ] `codedeploy_enabled = true` في stack 40، والـ instance refresh خلص، والـ agent شغال على الـ instances
- [ ] قريت الـ app + deployment group اللي Terraform عملهم في الـ Console، وعملت group تاني بإيدك (§4.2)
- [ ] `package-revision.sh` → `aws deploy push` → `create-deployment` نجح، و `/ready` بالـ version الجديدة
- [ ] قريت lifecycle events لكل instance وفهمت كل hook
- [ ] جرّبت image مش موجودة (auto rollback) و alarm-triggered stop
- [ ] شفت إن الـ rollback مابيصلّحش config fault
- [ ] مسحت الـ group اليدوي، وقفلت `codedeploy_enabled` (أو destroy لـ stack 40)
