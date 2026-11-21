# 02 — تجهيز حساب AWS (MFA، Identity Center، Budgets، CLI، bootstrap)

> **الهدف في سطر:** تجهّز حساب AWS زي ما senior بيجهّزه: root مقفول بـ MFA ومبيتستخدمش، دخول يومي بـ **IAM Identity Center** و `aws configure sso` (من غير access keys خالص)، Budgets و Cost Anomaly Detection و billing alarm، cost allocation tags، وبعدين الـ **bootstrap stack** (state bucket، OIDC roles، ECR، CodeConnections، Ansible SSM bucket) وتوصيل GitHub (repository variables + environments `lab` و `production`).
> **المستوى:** Beginner → Intermediate · **الوقت:** ~3 ساعات · **التكلفة التقريبية:** ~$0 (S3 state + ECR بسنتات في الشهر)
> **بيعتمد على:** [01 — الأدوات](01-tools-primer.md) · [03 — تجهيز الجهاز](03-workstation-setup.md) (aws CLI v2، terraform، gh، jq) · **الملفات في الـ repo:** [`infra/terraform/bootstrap/`](../../../infra/terraform/bootstrap/) ([`README.md`](../../../infra/terraform/bootstrap/README.md) · [`main.tf`](../../../infra/terraform/bootstrap/main.tf) · [`github-oidc.tf`](../../../infra/terraform/bootstrap/github-oidc.tf) · [`ecr.tf`](../../../infra/terraform/bootstrap/ecr.tf) · [`codeconnections.tf`](../../../infra/terraform/bootstrap/codeconnections.tf) · [`ansible-ssm.tf`](../../../infra/terraform/bootstrap/ansible-ssm.tf) · [`outputs.tf`](../../../infra/terraform/bootstrap/outputs.tf) · [`versions.tf`](../../../infra/terraform/bootstrap/versions.tf)) · [`infra/terraform/backend.hcl.example`](../../../infra/terraform/backend.hcl.example) · [`infra/terraform/README.md`](../../../infra/terraform/README.md)

## 1) الفكرة (Concepts)

أول ساعة في أي حساب AWS بتحدد هل الحساب ده هيبقى **آمن ورخيص** ولا هيبقى قنبلة. الغلطات الكلاسيكية: تشتغل بالـ root، تعمل IAM user بـ access key تحطه في `~/.aws/credentials` لحد ما يتسرّب في commit، تنسى NAT Gateway شغال شهر، أو تحط keys في GitHub secrets. السيناريو ده بيقفل الأبواب دي كلها **قبل** ما تعمل أي resource.

ترتيب الطبقات:

1. **الـ root**: MFA + مفيش access keys + مبيتستخدمش غير في المهام اللي محتاجاه بس.
2. **الإنسان (أنت)**: IAM Identity Center → credentials مؤقتة من المتصفح للـ CLI (`aws sso login`).
3. **الماكينات (GitHub Actions)**: OIDC → roles بصلاحيات محددة لكل نوع شغل (CI / deploy / terraform / plan). مفيش keys في GitHub خالص.
4. **الفلوس**: Budget + Anomaly Detection + billing alarm → إيميل قبل ما الفاتورة تفاجئك.
5. **الأساس طويل العمر**: الـ bootstrap stack (state bucket + ECR + roles + connection)، وكل حاجة تانية stacks مؤقتة (apply → جرّب → destroy).

| القرار | اخترنا | البديل | ليه |
|---|---|---|---|
| دخولك اليومي | **IAM Identity Center** (organization instance) | IAM user + access key | credentials مؤقتة (ساعات)، MFA مركزي، مفيش secret على الـ disk يتسرّب؛ وده نفس اللي الشركات بتستخدمه |
| الـ region | **us-east-1** | eu-central-1 / me-central-1 | أرخص وأوسع توافر للخدمات، والـ billing metrics أصلاً في us-east-1. الـ latency من مصر مش مهمة لمعمل |
| الـ state | **S3 + `use_lockfile`** | DynamoDB lock / Terraform Cloud | Terraform ≥ 1.10 بيعمل lock بـ object جنب الـ state؛ resource أقل وتكلفة أقل |
| الـ CI auth | **GitHub OIDC** | access keys في GitHub secrets | مفيش حاجة تعملها rotate، والـ trust مربوط بـ repo + branch/environment |
| الـ images | **ECR IMMUTABLE** | tags mutable | الـ tag (SHA) عمره ما يتكتب فوقه → "اللي شغال" دايماً قابل للتكرار |
| GitHub → CodePipeline | **CodeConnections** (GitHub App) | personal access token | مفيش PAT يعيش للأبد؛ الصلاحية على repo معين |

| المصطلح | المعنى |
|---|---|
| Root user | صاحب الحساب (الإيميل). صلاحياته مطلقة ومينفعش تتقيّد بـ IAM |
| AWS Organizations / management account | لما تفعّل Identity Center بالـ organization، حسابك بيبقى الـ management account لـ org فيها حساب واحد (ينفع تزوّد حسابات lab/prod بعدين) |
| Permission set | "قالب صلاحيات" في Identity Center؛ لما تعمله assign على حساب بيتحول لـ IAM role اسمها `AWSReservedSSO_<name>_...` |
| SSO session | جلسة الـ CLI مع Identity Center؛ الـ token متخزّن في `~/.aws/sso/cache` وبيتجدد لوحده لحد ما الجلسة تخلص |
| Budget | حد صرف شهري بإيميلات عند نسب معينة (فعلي أو متوقّع) |
| Cost Anomaly Detection | ML بيقارن الصرف بالنمط الطبيعي ويبعتلك لو حاجة شذّت (مثلاً NAT اتعمل وانت ناسيه) |
| Cost allocation tag | tag لازم "تفعّله" في الـ Billing عشان يظهر في Cost Explorer والفاتورة |
| Bootstrap (chicken-and-egg) | الـ stack اللي بيعمل الـ state bucket مينفعش يخزّن state-ه فيه قبل ما يعمله → local state الأول وبعدين migrate |

## 2) المعمارية (Architecture)

```text
 ┌─ AWS account (management account لـ organization فيها حساب واحد) ──────────────────────────┐
 │                                                                                               │
 │  root ── MFA (2 devices) · no access keys · alternate contacts · locked in a drawer           │
 │                                                                                               │
 │  IAM Identity Center (us-east-1, organization instance)                                       │
 │    user ahmed ─► group admins ─► permission sets: AdministratorAccess (4h) · ReadOnlyAccess   │
 │        │                                                                                      │
 │        └─► access portal https://d-xxxxxxxxxx.awsapps.com/start ─► aws sso login (WSL)        │
 │                 ~/.aws/config: [sso-session student] · [profile student-lab-admin] · [-ro]    │
 │                                                                                               │
 │  Billing: Budgets ($0.01 zero-spend + $10/month) · Cost Anomaly Detection · CloudWatch        │
 │           billing alarm (us-east-1) · cost allocation tags Project/Env/Scenario/ManagedBy     │
 │                                                                                               │
 │  bootstrap stack (Terraform, long-lived, Scenario=02)                                          │
 │    S3  student-app-tfstate-<acct>   versioned · SSE · TLS-only · old versions 90d            │
 │        ├─ bootstrap/terraform.tfstate        (بعد الـ migrate)                                │
 │        └─ stacks/<NN-name>/terraform.tfstate (+ .tflock وقت الـ apply)                       │
 │    ECR student-app                  IMMUTABLE · scan on push · keep 30 · untagged 7d          │
 │    OIDC token.actions.githubusercontent.com ─► roles:                                         │
 │        student-app-gha-ci  · -deploy · -terraform (admin, gated) · -terraform-plan (RO)       │
 │    CodeConnections student-app-github   PENDING ──(handshake في الـ Console)──► AVAILABLE    │
 │    S3  student-app-ansible-ssm-<acct>   transfer bucket لـ Ansible over SSM (expire 1 day)    │
 └───────────────────────────────────────────────────────────────────────────────────────────────┘
          ▲ OIDC JWT (sub = repo:Ahmed-Reda-Ragab/StudentHub:ref:... | :environment:<env>)
 ┌─ GitHub repo Ahmed-Reda-Ragab/StudentHub ──────────────────────────────────────────────────┐
 │  Repository variables ◄── terraform output github_repository_variables                      │
 │  Environments: lab (reviewer اختياري) · production (required reviewers + wait timer +       │
 │                protected branches + env variables EC2_INSTANCE_ID / APP_URL / ENV_NAME)      │
 └──────────────────────────────────────────────────────────────────────────────────────────────┘
```

## 3) المتطلبات (Prerequisites)

- [ ] إيميل خاص بالحساب (يفضّل alias زي `you+aws-lab@gmail.com`) + كارت + رقم موبايل.
- [ ] تطبيق Authenticator (أو passkey/security key) — والأحسن **جهازين** MFA للـ root.
- [ ] من [03](03-workstation-setup.md): WSL2 فيه `aws` v2 (`aws --version` ≥ 2.22 عشان PKCE)، `terraform` ≥ 1.10، `gh` (عامل `gh auth login`)، `jq`، والـ repo متعمله clone **جوه** الـ WSL filesystem.
- [ ] صلاحية admin على الـ repo `Ahmed-Reda-Ragab/StudentHub` (variables + environments).

## 4) الطريقة الأولى: AWS Console (يدوي)

### 4.1 تأمين الـ root

1. ادخل بالـ root على `https://console.aws.amazon.com` (Root user + الإيميل).
2. فوق يمين اسم الحساب → **Security credentials**:
   - **Multi-factor authentication (MFA) → Assign MFA device** → اختار **Passkey or security key** أو **Authenticator app** → امسح الـ QR وادخل كودين ورا بعض. كرّرها بجهاز تاني (AWS بيسمح بأكتر من MFA device للـ root، وده بيحميك لو موبايلك ضاع).
   - **Access keys:** لازم القائمة تبقى **فاضية**. لو فيه key قديم: **Actions → Deactivate** ثم **Delete**.
3. **Account** (من نفس القائمة):
   - **Alternate contacts → Edit:** Billing / Operations / Security (ممكن نفس إيميلك) — AWS بتبعت تنبيهات الأمان هنا.
   - **IAM user and role access to Billing information → Edit → Activate IAM Access** — من غيرها الـ permission set بتاعك (حتى لو Administrator) مش هيشوف Billing و Budgets.
4. اطلع (Sign out). من هنا ورايح الـ root للطوارئ بس.

> 💡 مهام لازم root فيها (احفظها للـ interview): تغيير إعدادات الحساب أو الإيميل، قفل الحساب، استرجاع صلاحيات IAM لو قفلت نفسك برّه، بعض إعدادات الـ billing/tax، وتفعيل/إلغاء بعض الحاجات على مستوى الحساب. كل حاجة غير كده من Identity Center.

### 4.2 اختيار الـ region

اختار **N. Virginia (us-east-1)** من فوق يمين. الـ lab كله مبني عليها ([CONVENTIONS §1](../CONVENTIONS.md)).

| Region | الميزة | العيب |
|---|---|---|
| **us-east-1** | أرخص أسعار، كل الخدمات بتنزل فيها الأول، billing metrics و ACM لـ CloudFront هناك | latency من مصر ~150ms (مش مهم لمعمل) |
| eu-central-1 (Frankfurt) | latency أقل من مصر | أغلى شوية |
| me-central-1 (UAE) | الأقرب | region لازم تعملها opt-in، وأغلى، وخدمات أقل |

> ⚠️ أي resource بتعمله في region تانية بالغلط هيفضل يتحاسب وانت مش شايفه. استخدم **Tag Editor** (Resource Groups → Tag Editor → Regions: All) أو الأمر في §7 عشان تدوّر في كل الـ regions.

### 4.3 IAM Identity Center (الدخول اليومي)

1. **IAM Identity Center → Enable**. هتلاقي اختيارين:
   - **Enable with AWS Organizations** ← ده اللي عايزه. بيعمل organization وحسابك يبقى الـ management account.
   - account instance ← **لأ**: الـ account instances **مبتدعمش permission sets ولا الدخول على AWS accounts** (بتنفع لـ applications بس)، يعني مش هتعرف تعمل `aws configure sso` عليها.
2. **Settings → Identity source:** سيبه **Identity Center directory**. خد نسخة من **AWS access portal URL** (`https://d-xxxxxxxxxx.awsapps.com/start`).
3. **Settings → Authentication → Multi-factor authentication → Configure:** "Every time they sign in"، وأنواع الـ MFA: authenticator apps + security keys/passkeys، ولو المستخدم معندوش MFA: "Require them to register an MFA device at sign in".
4. **Users → Add user:** Username `ahmed`، الإيميل، الاسم → "Send an email to this user with password setup instructions" → Next.
5. **Groups → Create group:** `admins` → ضيف `ahmed`.
6. **Permission sets → Create permission set:**
   - **Predefined permission set → AdministratorAccess** → Session duration **4 hours** (الافتراضي ساعة، والحد الأقصى 12) → Create.
   - كرّر لـ **ReadOnlyAccess** (للتصفّح الآمن ولـ "اتفرج من غير ما تبوّظ").
7. **AWS accounts** (تحت Multi-account permissions) → علّم حسابك → **Assign users or groups** → Groups: `admins` → Permission sets: الاتنين → **Submit**.
8. افتح إيميل الدعوة → **Accept invitation** → حط باسورد → سجّل MFA. ادخل الـ access portal: هتلاقي الحساب وتحته `AdministratorAccess` و `ReadOnlyAccess`.

> 💡 لاحظ في **IAM → Roles** ظهر roles اسمها `AWSReservedSSO_AdministratorAccess_xxxx` — دي اللي Identity Center بيعملها لكل permission set متعمله assign. **متعدّلهاش بإيدك**؛ عدّل الـ permission set وهو يعمل provision تاني.

### 4.4 الـ CLI بـ SSO profiles (من WSL)

```bash
aws configure sso
# SSO session name (Recommended): student
# SSO start URL [None]: https://d-xxxxxxxxxx.awsapps.com/start
# SSO region [None]: us-east-1
# SSO registration scopes [None]: sso:account:access
#   → المتصفح بيفتح (PKCE) → Allow
#   → اختار الحساب ← اختار AdministratorAccess
# Default client Region [None]: us-east-1
# CLI default output format (json if not specified) [None]: json
# Profile name [...]: student-lab-admin

aws configure sso          # تاني مرة: نفس الـ session "student"، اختار ReadOnlyAccess، Profile name: student-lab-ro
```

النتيجة في `~/.aws/config`:

```ini
[profile student-lab-admin]
sso_session = student
sso_account_id = <ACCOUNT_ID>
sso_role_name = AdministratorAccess
region = us-east-1
output = json

[profile student-lab-ro]
sso_session = student
sso_account_id = <ACCOUNT_ID>
sso_role_name = ReadOnlyAccess
region = us-east-1
output = json

[sso-session student]
sso_start_url = https://d-xxxxxxxxxx.awsapps.com/start
sso_region = us-east-1
sso_registration_scopes = sso:account:access
```

```bash
aws sso login --sso-session student          # مرة في اليوم (أو لما الـ session تخلص)
export AWS_PROFILE=student-lab-admin         # Terraform و Ansible و boto3 بيقروا نفس المتغير
aws sts get-caller-identity                   # Arn: ...assumed-role/AWSReservedSSO_AdministratorAccess_.../ahmed
aws sso logout                                # آخر اليوم
```

> 💡 لو الـ WSL مش بيفتح المتصفح: انسخ الـ URL اللي بيطبعه وافتحه في Windows، أو استخدم `aws sso login --sso-session student --use-device-code`.

### 4.5 AWS Budgets

**Billing and Cost Management → Budgets → Create budget**:

1. **Use a template (simplified) → Zero spend budget** → الإيميل → Create. ده بيبعتلك أول ما الصرف يعدّي $0.01 — ممتاز في الأول عشان تعرف إن فيه حاجة بتتحاسب.
2. **Create budget** تاني → **Customize (advanced) → Cost budget**:
   - Name `student-app-lab-monthly` · Period **Monthly** · Recurring · Budgeting method **Fixed** · Amount **$10**.
   - Scope: All AWS services (أو Filter by tag `Project=student-app` بعد ما تفعّل الـ tag في §4.8).
   - **Alert thresholds:** 50% **Actual**، 80% **Actual**، 100% **Forecasted** → الإيميل.
   - (اختياري، متقدم) **Budget actions:** apply IAM policy بـ deny على `ec2:RunInstances` لما توصل 100% — مفيد بس خطر لو نسيته.

نفس الـ budget الشهري بالـ CLI:

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
EMAIL=<YOUR_EMAIL>
aws budgets create-budget --account-id "$ACCOUNT_ID" \
  --budget '{"BudgetName":"student-app-lab-monthly","BudgetLimit":{"Amount":"10","Unit":"USD"},"TimeUnit":"MONTHLY","BudgetType":"COST"}' \
  --notifications-with-subscribers "[
    {\"Notification\":{\"NotificationType\":\"ACTUAL\",\"ComparisonOperator\":\"GREATER_THAN\",\"Threshold\":50,\"ThresholdType\":\"PERCENTAGE\"},\"Subscribers\":[{\"SubscriptionType\":\"EMAIL\",\"Address\":\"$EMAIL\"}]},
    {\"Notification\":{\"NotificationType\":\"ACTUAL\",\"ComparisonOperator\":\"GREATER_THAN\",\"Threshold\":80,\"ThresholdType\":\"PERCENTAGE\"},\"Subscribers\":[{\"SubscriptionType\":\"EMAIL\",\"Address\":\"$EMAIL\"}]},
    {\"Notification\":{\"NotificationType\":\"FORECASTED\",\"ComparisonOperator\":\"GREATER_THAN\",\"Threshold\":100,\"ThresholdType\":\"PERCENTAGE\"},\"Subscribers\":[{\"SubscriptionType\":\"EMAIL\",\"Address\":\"$EMAIL\"}]}
  ]"
aws budgets describe-budgets --account-id "$ACCOUNT_ID" --query 'Budgets[].BudgetName'
```

> ⚠️ الـ Budget **بينبّه بس** ومبيوقفش حاجة، وبيتحدّث كل كام ساعة (مش real-time). الحماية الحقيقية: teardown بعد كل سيناريو ([97](97-cost-and-teardown.md)).

### 4.6 Cost Anomaly Detection

**Billing and Cost Management → Cost Anomaly Detection**:

1. **Cost monitors → Create monitor** → Monitor type **AWS services** → Name `student-app-services`. (ممكن تلاقي monitor افتراضي اتعمل لوحده — كفاية.)
2. **Alert subscriptions → Create subscription** → Name `student-app-anomalies` → Frequency **Individual alerts** → الإيميل → Threshold: **Absolute impact above $5** → اربطها بالـ monitor.

> 💡 الفرق: الـ Budget بيقولك "عدّيت رقم"، الـ anomaly بيقولك "ده مش طبيعي" حتى لو لسه تحت الرقم — زي NAT Gateway اتعمل امبارح وبيصرف $1/يوم.

### 4.7 Billing alarm (الطريقة الكلاسيكية — interview favorite)

1. **Billing and Cost Management → Billing preferences → Alert preferences → Edit** → ✅ **Receive CloudWatch billing alerts** → Save.
2. غيّر الـ region لـ **us-east-1** (الـ billing metrics موجودة هناك بس) → **CloudWatch → Alarms → Create alarm → Select metric → Billing → Total Estimated Charge → USD**.
3. Static، Greater than **10** → Notification: Create new SNS topic `billing-alerts` + الإيميل → Name `billing-over-10usd` → Create. أكّد الـ subscription من الإيميل.

```bash
aws sns create-topic --name billing-alerts --region us-east-1
aws sns subscribe --region us-east-1 --topic-arn arn:aws:sns:us-east-1:<ACCOUNT_ID>:billing-alerts \
  --protocol email --notification-endpoint <YOUR_EMAIL>
aws cloudwatch put-metric-alarm --region us-east-1 --alarm-name billing-over-10usd \
  --namespace AWS/Billing --metric-name EstimatedCharges --dimensions Name=Currency,Value=USD \
  --statistic Maximum --period 21600 --evaluation-periods 1 --threshold 10 \
  --comparison-operator GreaterThanThreshold \
  --alarm-actions arn:aws:sns:us-east-1:<ACCOUNT_ID>:billing-alerts
```

> 💡 الحسابات اللي اتفتحت بعد 15 يوليو 2025 بتبقى على نظام Free Tier الجديد (Free plan أو Paid plan + credits). الـ Free plan بيقفل نفسه لما الـ credits تخلص أو بعد 6 شهور، وفيه خدمات مش متاحة عليه. راجع **Billing → Free Tier** في حسابك عشان تعرف انت على أنهي نظام.

### 4.8 Tagging و cost allocation tags

كل الـ stacks بتحط `Project`، `Env`، `ManagedBy`، `Scenario` تلقائي (`default_tags` في كل `providers.tf` — [CONVENTIONS §1](../CONVENTIONS.md)). عشان تشوف التكلفة متقسّمة بيهم:

1. اعمل الـ bootstrap الأول (§5) عشان الـ tags تظهر على resources حقيقية.
2. **Billing and Cost Management → Cost allocation tags → User-defined cost allocation tags** → علّم `Project`، `Env`، `Scenario`، `ManagedBy` → **Activate**.
3. بعد ~24 ساعة: **Cost Explorer → Group by → Tag → Scenario** → تشوف كل سيناريو كلّفك كام.

```bash
aws ce update-cost-allocation-tags-status --cost-allocation-tags-status \
  TagKey=Project,Status=Active TagKey=Env,Status=Active TagKey=Scenario,Status=Active TagKey=ManagedBy,Status=Active
aws ce list-cost-allocation-tags --status Active --query 'CostAllocationTags[].TagKey'
```

> ⚠️ الـ tag لازم يكون اتشاف على resource قبل ما يظهر في القائمة، والتفعيل **مش بأثر رجعي**: التكلفة القديمة مش هتتقسّم.

### 4.9 موارد الـ bootstrap من الـ Console (للفهم — متعملهاش لو هتعمل الـ Terraform)

| المورد | فين في الـ Console | الإعدادات المهمة |
|---|---|---|
| State bucket | S3 → Create bucket `student-app-tfstate-<ACCOUNT_ID>` | Block all public access ✅، Bucket Versioning **Enable**، Default encryption SSE-S3، Object Ownership **Bucket owner enforced**، Management → Lifecycle: noncurrent versions expire 90 days، Permissions → policy `DenyInsecureTransport` |
| ECR | [30 §4.2](30-ci-github-actions.md) | Immutable tags، scan on push |
| OIDC provider + roles | [30 §4.1–4.4](30-ci-github-actions.md) | `aud` + `sub` محددين دايماً |
| CodeConnections | **Developer Tools → Settings → Connections → Create connection** → GitHub → name `student-app-github` → **Connect to GitHub** → Install a new app (اختار الـ repo بس) → Connect | Status = Available |
| Ansible SSM bucket | S3 → Create bucket `student-app-ansible-ssm-<ACCOUNT_ID>` | Block public، SSE-S3، Lifecycle expire 1 day |

> ⚠️ لو عملت أي واحد بإيدك وبعدين عملت `terraform apply` للـ bootstrap → conflicts (`BucketAlreadyOwnedByYou`، `EntityAlreadyExists`). يا تمسح اللي عملته، يا تعمله `terraform import` ([91](91-terraform-import-and-drift.md)).

## 5) الطريقة التانية: Infrastructure as Code (bootstrap)

### 5.1 أول apply بـ local state

```bash
export AWS_PROFILE=student-lab-admin && aws sso login --sso-session student
cd infra/terraform/bootstrap
cp terraform.tfvars.example terraform.tfvars     # اختياري: الـ defaults مطابقة لـ CONVENTIONS (terraform.tfvars متجاهَل في git)
terraform init                                    # local backend (الـ backend block لسه commented)
terraform plan -out=tfplan
terraform apply tfplan
```

الـ variables المهمة (من [`variables.tf`](../../../infra/terraform/bootstrap/variables.tf)):

| Variable | الافتراضي | المعنى |
|---|---|---|
| `region` | `us-east-1` | |
| `github_repo` | `Ahmed-Reda-Ragab/StudentHub` | case-sensitive — غلطة في حرف = الـ OIDC مش هيشتغل |
| `ci_branches` | `["main","master"]` | مين يقدر ياخد `student-app-gha-ci` |
| `deploy_branches` / `deploy_environments` | `["main","master"]` / `["lab","production"]` | مين ياخد `student-app-gha-deploy` |
| `terraform_branches` / `terraform_environments` | `[]` / `["lab"]` | مين ياخد الـ admin role — الـ jobs اللي في environment `lab` بس (من غير branch، عشان مفيش حد يعدّي الـ reviewer) |
| `create_terraform_plan_role` | `true` | role read-only للـ plans على الـ PRs |
| `create_github_oidc_provider` | `true` | `false` لو الحساب فيه provider من مشروع تاني (واحد بس مسموح لكل URL) |
| `create_codeconnection` | `true` | |
| `ecr_force_delete` / `state_bucket_force_destroy` | `false` / `false` | `true` بس وانت بتقفل المعمل نهائي |
| `state_noncurrent_days` | `90` | مدة الاحتفاظ بنسخ الـ state القديمة (زرار undo) |

### 5.2 نقل الـ state للـ bucket اللي لسه عامله

```bash
terraform output -raw backend_hcl > ../backend.hcl     # bucket / region / use_lockfile / encrypt (gitignored)
cat ../backend.hcl
# افتح versions.tf وشيل الـ comment من:
#   backend "s3" {
#     key = "bootstrap/terraform.tfstate"
#   }
terraform init -migrate-state -backend-config=../backend.hcl    # "Do you want to copy existing state?" → yes
terraform plan                                                   # لازم: No changes. Your infrastructure matches the configuration.
rm terraform.tfstate terraform.tfstate.backup
aws s3 ls "s3://$(terraform output -raw state_bucket)/bootstrap/"
```

ليه كده؟

- **Chicken-and-egg:** الـ bucket مكانش موجود وقت أول `init`. بعد الـ migrate الـ state بقى في S3 (versioned + مشفّر + TLS-only)، ومفيش نسخة على اللابتوب ممكن تضيع أو تتسرّب (الـ state فيه secrets).
- **الـ key متثبت في كل stack** (`bootstrap/terraform.tfstate`، `stacks/<NN>/terraform.tfstate`) و `backend.hcl` فيه bucket/region/locking بس → ملف واحد لكل الـ stacks، ومستحيل اتنين stacks يكتبوا على نفس الـ state بالغلط.
- **`use_lockfile = true`:** وقت الـ apply بيتعمل object اسمه `<key>.tflock` جنب الـ state؛ أي apply تاني بيفشل بـ `Error acquiring the state lock` بدل ما يبوّظ الـ state.
- تعديل `versions.tf` ده **commit-ه**: الـ key مش سر، وأي حد (أو CI) يعمل init بعدك لازم يلاقي نفس الـ backend.

### 5.3 الـ outputs

```bash
terraform output
# account_id, region, state_bucket, github_oidc_provider_arn, github_ci_role_arn, github_deploy_role_arn,
# github_terraform_role_arn, github_terraform_plan_role_arn, ecr_repository_url, codeconnections_arn,
# codeconnections_status, backend_hcl, github_repository_variables, ansible_ssm_bucket
```

### 5.4 الـ OIDC roles

| Role | الـ `sub` المسموح | الصلاحيات | بيستخدمه |
|---|---|---|---|
| `student-app-gha-ci` | `ref:refs/heads/{main,master}` | push/pull على `student-app` بس | [`ci.yml`](../../../.github/workflows/ci.yml) ([30](30-ci-github-actions.md)) |
| `student-app-gha-deploy` | main/master + `environment:{lab,production}` | SSM Run Command/Sessions على instances عليها `Project=student-app`، transfer bucket بتاع Ansible، `/student-app/*/deploy/*`، ECS، ASG refresh، listener weights، CodeDeploy، alarms | [32](32-cd-ec2-ecr-ssm.md)–[34](34-environments-approvals-promotion.md)، 4x، 5x |
| `student-app-gha-terraform` | main/master + `environment:lab` | `AdministratorAccess` (اختصار للمعمل) | [`terraform.yml`](../../../.github/workflows/terraform.yml) apply/destroy ([92](92-terraform-in-ci.md)) |
| `student-app-gha-terraform-plan` | `pull_request` + أي branch | `ReadOnlyAccess` + decrypt SecureStrings | plans على الـ PRs |

> 🔐 **نقطة senior:** لما الـ job فيه `environment: lab`، الـ `sub` بيبقى `repo:<owner>/<repo>:environment:lab` — **من غير اسم الـ branch**. يعني أي branch يقدر يعمل deploy على lab لو الـ environment مسموح له. عشان كده الـ **deployment branch policy** على `production` (protected branches بس) جزء من الـ security، مش رفاهية (§5.8).

### 5.5 ECR

`student-app`: `image_tag_mutability = IMMUTABLE`، `scan_on_push = true` (basic scanning مجاني لـ OS packages؛ Trivy في الـ CI بيغطي الـ app dependencies)، AES256، والـ lifecycle: الـ untagged بعد 7 أيام، ويحتفظ بآخر 30 image. **Long-lived عن قصد:** لو عملت destroy لـ stack وعملته تاني، تقدر تعمل deploy لنفس الـ SHA بالظبط.

### 5.6 Ansible SSM transfer bucket

`student-app-ansible-ssm-<ACCOUNT_ID>` ([`ansible-ssm.tf`](../../../infra/terraform/bootstrap/ansible-ssm.tf)): الـ connection plugin `amazon.aws.aws_ssm` بيرفع ملفات الـ modules هنا والـ instance بينزّلها بـ presigned URLs → الـ instance مش محتاج S3 permission، وبورت 22 مقفول. الـ objects بتتمسح بعد يوم، و `force_destroy = true` (ملفات مؤقتة). الـ deploy role عنده Get/Put/Delete/List عليه بس ([33](33-cd-ec2-ansible.md)).

### 5.7 الـ CodeConnections handshake (مرة واحدة)

Terraform بيقدر يعمل الـ connection بحالة **`PENDING`** بس (التفويض لازم إنسان يوافق عليه في GitHub):

1. **Developer Tools → Settings → Connections** → `student-app-github` (Status: Pending) → **Update pending connection**.
2. نافذة GitHub: **Install a new app** (لو أول مرة) → Only select repositories → `StudentHub` → Install → **Connect**.
3. الحالة تبقى **Available**.

```bash
aws codeconnections get-connection --connection-arn "$(terraform output -raw codeconnections_arn)" \
  --query Connection.ConnectionStatus --output text      # AVAILABLE
```

> ⚠️ `terraform output codeconnections_status` بيعرض القيمة اللي في الـ state (PENDING) لحد ما تعمل `terraform apply -refresh-only`. اعتمد على الأمر اللي فوق. الـ connection ده هتحتاجه في [35](35-aws-codebuild.md) و [36](36-aws-codepipeline.md).

### 5.8 GitHub: repository variables و environments

**الـ variables** (القيم كلها من الـ output — مفيش copy/paste):

```bash
terraform output github_repository_variables
terraform output -json github_repository_variables \
  | jq -r 'to_entries[] | select(.value != "" and .value != null) | "\(.key) \(.value)"' \
  | while read -r k v; do gh variable set "$k" --body "$v"; done      # القيم الفاضية (feature متقفلة) بتتخطّى
gh variable list
# AWS_REGION, AWS_ROLE_ARN, AWS_DEPLOY_ROLE_ARN, AWS_TERRAFORM_ROLE_ARN, AWS_TERRAFORM_PLAN_ROLE_ARN,
# ECR_REPOSITORY, TF_STATE_BUCKET, ANSIBLE_SSM_BUCKET
```

الباقي بييجي من الـ stacks لما تعملها ([CONVENTIONS §9](../CONVENTIONS.md)): `EC2_INSTANCE_ID`/`EC2_HOST` (stack 20)، `ECS_*` (stack 50)، `EKS_CLUSTER` (stack 60)، والـ secret `SRE_LAB_TOKEN` (`terraform output -raw sre_lab_token` من الـ stack).

> 💡 الـ UI: **Settings → Secrets and variables → Actions → Variables → New repository variable**.

**الـ environments** (UI): **Settings → Environments → New environment**:

- `lab`: من غير protection في الأول. ضيف نفسك **Required reviewer** لو عايز approval قبل `terraform apply` (كل الـ deploys على lab هتستنى نفس الموافقة).
- `production`: **Required reviewers** (نفسك)، **Wait timer** (مثلاً 5 دقايق)، **Prevent self-review** سيبها **مش متعلّمة** طالما انت لوحدك (وإلا مش هتعرف توافق على run انت اللي شغّلته)، **Deployment branches and tags → Protected branches only**، و **Environment variables**: `ENV_NAME`، `APP_URL`، `EC2_INSTANCE_ID` (تفاصيلها في [34](34-environments-approvals-promotion.md)).

نفس الحاجة بـ `gh api`:

```bash
REPO=Ahmed-Reda-Ragab/StudentHub
gh api -X PUT "repos/$REPO/environments/lab" >/dev/null
MY_ID=$(gh api user --jq .id)
gh api -X PUT "repos/$REPO/environments/production" --input - <<JSON
{
  "wait_timer": 5,
  "prevent_self_review": false,
  "reviewers": [{ "type": "User", "id": $MY_ID }],
  "deployment_branch_policy": { "protected_branches": true, "custom_branch_policies": false }
}
JSON
gh api "repos/$REPO/environments" --jq '.environments[] | {name, rules: [.protection_rules[].type]}'
```

> ⚠️ **حدود الـ plan:** على GitHub Free/Pro/Team، الـ required reviewers والـ wait timer متاحين للـ **public repos بس**؛ الـ private repo محتاج Enterprise. والـ environment secrets في الـ private repo محتاجة Pro/Team على الأقل. لو الـ repo private على Free: الـ environments هتشتغل بس من غير gate.

## 6) الـ Deploy — أول image في ECR

الـ bootstrap نفسه هو "الـ deploy" هنا. الخطوة الوحيدة الباقية عشان باقي المعمل يشتغل: image أولى في ECR. [`ci.yml`](../../../.github/workflows/ci.yml) بيعمل push **بس** على `push` لـ `master`/`main` (مش `workflow_dispatch` ومش `devops-lab`):

```bash
gh pr create --base master --head devops-lab --fill
gh pr merge --merge                      # بعد ما الـ checks تعدّي
gh run watch "$(gh run list --workflow=ci.yml --branch master --limit 1 --json databaseId --jq '.[0].databaseId')"
aws ecr describe-images --repository-name student-app \
  --query 'sort_by(imageDetails,&imagePushedAt)[-1].{tags:imageTags,digest:imageDigest}'
```

## 7) التحقق (Verify)

```bash
aws sts get-caller-identity --profile student-lab-admin --query Arn
aws sts get-caller-identity --profile student-lab-ro --query Arn
aws iam get-account-summary --query 'SummaryMap.{rootMFA:AccountMFAEnabled,rootKeys:AccountAccessKeysPresent}'   # {1, 0}
aws budgets describe-budgets --account-id "$(aws sts get-caller-identity --query Account --output text)" --query 'Budgets[].BudgetName'

cd infra/terraform/bootstrap
terraform state list | head -30
B=$(terraform output -raw state_bucket)
aws s3api get-bucket-versioning --bucket "$B"                    # Enabled
aws s3api get-bucket-encryption --bucket "$B" --query 'ServerSideEncryptionConfiguration.Rules[0]'
aws ecr describe-repositories --repository-names student-app --query 'repositories[0].{mut:imageTagMutability,scan:imageScanningConfiguration}'
aws iam list-roles --query "Roles[?starts_with(RoleName,'student-app-gha')].RoleName"
aws iam get-role --role-name student-app-gha-deploy --query Role.AssumeRolePolicyDocument.Statement[0].Condition
gh variable list && gh api repos/Ahmed-Reda-Ragab/StudentHub/environments --jq '.environments[].name'

# أي resource بالـ tag في كل الـ regions (يكشف حاجة اتعملت في region غلط)
for r in $(aws ec2 describe-regions --query 'Regions[].RegionName' --output text); do
  n=$(aws resourcegroupstaggingapi get-resources --region "$r" --tag-filters Key=Project,Values=student-app --query 'length(ResourceTagMappingList)')
  [ "$n" != "0" ] && echo "$r: $n"
done
```

المفروض: root فيه MFA ومفيش keys، الـ profiles شغالة بـ `AWSReservedSSO_*`، الـ bucket versioned ومشفّر، ECR immutable، 4 roles، الـ connection AVAILABLE، 8 variables، والـ environments موجودين.

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر | المتوقع |
|---|---|---|
| Session خلصت | `aws sso logout && aws s3 ls` | `Error when retrieving token from sso: Token has expired and refresh failed` → `aws sso login` |
| ReadOnly بيحاول يكتب | `aws s3 mb s3://test-$RANDOM --profile student-lab-ro` | `AccessDenied` — الـ permission set شغال |
| Lock على الـ state | شغّل `terraform apply` في terminal وفي التاني `terraform plan` (في stack بعد [21](21-ec2-compose-terraform-ansible.md)) | التاني: `Error acquiring the state lock` + Lock ID (و `force-unlock` آخر حل) |
| `sub` مش مسموح | شغّل workflow فيه `role-to-assume: ${{ vars.AWS_ROLE_ARN }}` من branch تجريبي من غير environment | `Not authorized to perform sts:AssumeRoleWithWebIdentity` |
| Connection PENDING | استخدم الـ connection في [35](35-aws-codebuild.md) قبل الـ handshake | `The connection ... is not in AVAILABLE state` |
| Budget بيشتغل؟ | خلّي الـ amount `0.01` مؤقتاً | إيميل خلال ساعات (مش لحظي — اعرف ده عن الـ Budgets) |
| `backend.hcl` اتمسح | `rm ../backend.hcl && terraform init -reconfigure` | Terraform يسألك على الـ bucket — رجّعه بـ `terraform output -raw backend_hcl` (من نسخة شغالة) أو من `backend.hcl.example` |

## 9) الرجوع (Rollback)

- **State اتبوّظ** (apply اتقطع، تعديل غلط): الـ bucket versioned:

```bash
B=student-app-tfstate-<ACCOUNT_ID>; K=stacks/20-ec2-single/terraform.tfstate
aws s3api list-object-versions --bucket "$B" --prefix "$K" --query 'Versions[].{v:VersionId,at:LastModified,latest:IsLatest}' --output table
aws s3api get-object --bucket "$B" --key "$K" --version-id <GOOD_VERSION_ID> /tmp/good.tfstate
terraform state push /tmp/good.tfstate          # من جوه الـ stack؛ Terraform بيرفض لو الـ serial أقدم (عن قصد) — اقرا الرسالة قبل -force
```

- **trust policy اتعدّلت غلط:** `terraform apply` من اللابتوب بيرجّعها (الـ console edits = drift — [91](91-terraform-import-and-drift.md)).
- **variable اتمسح:** شغّل loop الـ `gh variable set` تاني.
- **عايز ترجع الـ bootstrap لـ local state:** comment الـ backend block → `terraform init -migrate-state` → yes.

## 10) المسح (Teardown) ⚠️

**الـ bootstrap بيفضل** طول ما انت في المعمل (تكلفته سنتات). امسح الـ stacks المؤقتة بس بعد كل سيناريو.

لو هتقفل المعمل نهائي (بالترتيب):

```bash
# 1) امسح كل الـ stacks الأول (36 → 35 → 50/40/20/60) — infra/terraform/README.md "Destroy order"
aws resourcegroupstaggingapi get-resources --tag-filters Key=Project,Values=student-app --query 'ResourceTagMappingList[].ResourceARN'

# 2) رجّع الـ state لـ local (عشان الـ bucket نفسه هيتمسح)
cd infra/terraform/bootstrap
#    comment الـ backend "s3" block في versions.tf
terraform init -migrate-state
# 3) اسمح بمسح الـ bucket والـ repo وهما مش فاضيين
terraform apply -var ecr_force_delete=true -var state_bucket_force_destroy=true
terraform destroy -var ecr_force_delete=true -var state_bucket_force_destroy=true
```

بعدها: امسح الـ GitHub variables/environments، وفي GitHub → Settings → Applications → شيل **AWS Connector for GitHub** لو مش محتاجه. الـ Budgets والـ Identity Center والـ anomaly monitor مجانيين — سيبهم.

- [ ] مفيش resources عليها `Project=student-app` في أي region · [ ] الـ state bucket ممسوح (أو سايبه عن قصد) · [ ] مفيش OIDC roles يتيمة

## 11) التكلفة (Cost)

| Resource | السعر التقريبي (us-east-1، تقريبي — راجع صفحة الأسعار) |
|---|---|
| IAM Identity Center / Organizations / IAM / OIDC / STS | مجاني |
| AWS Budgets (من غير actions) / Cost Anomaly Detection | مجاني |
| CloudWatch billing alarm | ضمن الـ alarms المجانية (أول 10) |
| S3 state bucket (KBs + versions) | سنتات/شهر |
| ECR storage (حد أقصى 30 image × ~150 MB) | ~$0.10/GB/شهر → < $0.50/شهر |
| CodeConnections | مجاني |
| Ansible SSM bucket | ~$0 (الملفات بتتمسح بعد يوم) |
| **الإجمالي** | **< $1/شهر** |

## 12) أسئلة Interview

<details><summary>ليه IAM Identity Center بدل IAM users بـ access keys؟</summary>

الـ credentials مؤقتة (بتنتهي حسب session duration) ومبتتكتبش كـ long-lived secret على الـ disk، الـ MFA والـ lifecycle بتوع المستخدمين في مكان واحد، الـ permission sets بتتعمل assign على حسابات متعددة، والـ offboarding = disable user واحد. الـ access keys بتتسرّب (commits، لابتوبات، CI logs) ومحتاجة rotation محدش بيعملها. الاستثناء الوحيد المقبول للـ keys: أنظمة برّه AWS مفيهاش federation (وحتى دي Roles Anywhere بقت بديل).

</details>

<details><summary>الـ bootstrap stack عنده chicken-and-egg — اشرحه وإزاي اتحلّ.</summary>

الـ stack بيعمل الـ S3 bucket اللي المفروض يخزّن الـ state، فأول `init` مينفعش يستخدمه. الحل: apply بـ local state، وبعدين نضيف الـ backend block و `terraform init -migrate-state`، نتأكد إن `plan` = No changes، ونمسح الـ local state. بدائل: bucket بإيدك (CLI/Console) وبعدين import، أو CloudFormation/Terraform Cloud للـ bootstrap. والـ bootstrap نفسه **مش** بيتعمله apply من الـ CI لأنه بيعمل الـ roles اللي الـ CI بيستخدمها.

</details>

<details><summary>ليه أربع roles لـ GitHub بدل role واحد؟</summary>

Least privilege + blast radius: الـ CI بيعمل push لـ ECR بس؛ الـ deploy بيعمل rollout من غير ما يقدر يعمل/يمسح infra؛ الـ terraform admin بس من main/master أو environment `lab` اللي ممكن يكون عليه reviewer؛ والـ plan read-only لأن أي collaborator يقدر يعدّل workflow في PR. ولو role اتسرّب، الضرر محصور في نوع شغل واحد. والـ trust policy (`aud` + `sub`) هي اللي بتحدد "مين"، والـ permission policy بتحدد "إيه".

</details>

<details><summary>الـ plan role read-only — يعني آمن 100%؟</summary>

لأ. الـ plan محتاج يقرا الـ state والـ SecureStrings عشان يعمل refresh، يعني أي حد عنده write على الـ repo يقدر يفتح PR يغيّر الـ workflow ويطبع secrets. الحلول: required reviewers على workflow changes، CODEOWNERS على `.github/`، plan role من غير decrypt (مع قبول plan ناقص)، أو حسابات منفصلة لـ prod. الـ fork PRs مبتاخدش OIDC token أصلاً.

</details>

<details><summary>Budget alert وصلك الساعة 2 الصبح إن الـ forecast عدّى 100% — هتعمل إيه؟</summary>

Cost Explorer → Group by Service ثم Usage type ثم tag `Scenario` عشان أعرف المصدر. الأشهر: NAT Gateway، EKS control plane، RDS/ALB منسيين، EIP مش مربوط، EBS snapshots/volumes `available`، log ingestion كبير. أعمل `terraform destroy` للـ stack، وأتأكد بـ `resourcegroupstaggingapi` في كل الـ regions، وأكتب postmortem صغير (ليه الـ teardown اتنسى، وإزاي أمنعه: schedule destroy أو budget action).

</details>

<details><summary>ليه S3 native locking بدل DynamoDB؟</summary>

من Terraform 1.10 الـ S3 backend بيعمل lock بـ conditional write لـ object `<key>.tflock` (S3 بقى strongly consistent وبيدعم conditional writes). ده resource أقل يتدار ويتحاسب ويتعمله IAM. الـ DynamoDB locking بقى deprecated في الـ S3 backend. المهم في الحالتين: الـ plan في الـ CI بـ `-lock=false` (read-only role) عشان ميمنعش apply.

</details>

<details><summary>ليه us-east-1 وانت في مصر؟</summary>

للمعمل: أرخص أسعار وأكبر توافر للخدمات والـ instance types، والـ billing metrics و ACM لـ CloudFront هناك أصلاً. للـ production الحقيقي القرار بيتحسب بـ latency للمستخدمين، data residency/compliance، توافر الخدمات المطلوبة، والسعر — وممكن multi-region للـ DR ([77](77-backup-and-dr.md)).

</details>

## 13) Checklist

- [ ] الـ root عليه MFA (جهازين)، مفيش access keys، alternate contacts متسجّلة، و IAM access to billing متفعّل
- [ ] Identity Center (organization instance) + user + group + permission sets AdministratorAccess و ReadOnlyAccess
- [ ] `aws configure sso` → `student-lab-admin` و `student-lab-ro` شغالين
- [ ] Zero-spend budget + monthly budget + anomaly subscription + billing alarm (أكّدت الإيميلات)
- [ ] الـ bootstrap اتعمله apply، والـ state اتنقل لـ S3، و `plan` = No changes
- [ ] CodeConnections = AVAILABLE
- [ ] الـ repository variables من `github_repository_variables`، و environments `lab` و `production`
- [ ] Cost allocation tags متفعّلة
- [ ] أول image وصلت ECR من `master`
