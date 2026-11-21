# 81 — إدارة الـ Secrets (SSM مقابل Secrets Manager، rotation)

> **الهدف في سطر:** تفهم layout الـ SSM Parameter Store بتاع المعمل (SecureString + KMS)، إزاي كل platform بيستهلك الـ secrets (EC2 script، ASG user data، ECS `valueFrom`، External Secrets على EKS)، تقارن بـ Secrets Manager و rotation الـ RDS master password (`use_secrets_manager`) وإيه اللي ناقص عشان تشغّله، تعرف مصايد rotation الـ `APP_KEY`، وليه الـ Terraform state نفسه secret.
> **المستوى:** Intermediate → Advanced · **الوقت:** ~3 ساعات · **التكلفة التقريبية:** سنتات
> **بيعتمد على:** [80](80-iam-oidc-least-privilege.md) · [41](41-rds-mysql.md) · **الملفات في الـ repo:** [`CONVENTIONS §4`](../CONVENTIONS.md) · [`deploy/ec2/render-env-from-ssm.sh`](../../../deploy/ec2/render-env-from-ssm.sh) · [`asg-app/user-data.sh.tftpl`](../../../infra/terraform/modules/asg-app/user-data.sh.tftpl) · [`stacks/20-ec2-single/ssm.tf`](../../../infra/terraform/stacks/20-ec2-single/ssm.tf) · [`stacks/40-ec2-alb-asg/ssm.tf`](../../../infra/terraform/stacks/40-ec2-alb-asg/ssm.tf) · [`stacks/50-ecs-fargate/ssm.tf`](../../../infra/terraform/stacks/50-ecs-fargate/ssm.tf) · [`modules/rds-mysql/`](../../../infra/terraform/modules/rds-mysql) · [`modules/ecs-fargate/iam.tf`](../../../infra/terraform/modules/ecs-fargate/iam.tf) · [`bootstrap/main.tf`](../../../infra/terraform/bootstrap/main.tf) · [`config/app.php`](../../../config/app.php)

## 1) الفكرة (Concepts)

الـ secret = أي قيمة لو اتسرّبت حد يقدر يعمل بيها حاجة: `APP_KEY`، `DB_PASSWORD`، `SRE_LAB_TOKEN`، `METRICS_TOKEN`، API keys. القواعد:

1. **مصدر حقيقة واحد** (هنا SSM)، والـ platforms بتقرا منه وقت التشغيل — مش في الـ image ولا في git.
2. **Least privilege**: كل consumer يقرا الـ subtree بتاعه بس.
3. **Encryption at rest** (KMS) و in transit (TLS).
4. **Rotation** ممكن من غير downtime — وده محتاج تصميم.
5. **Audit**: مين قرا إيه (CloudTrail).

| المصطلح | المعنى |
|---|---|
| SSM Parameter `String` | نص عادي (DB_HOST، APP_URL) |
| `SecureString` | مشفّر بـ KMS (افتراضياً AWS-managed key `aws/ssm`)، بيتفك بـ `--with-decryption` + `kms:Decrypt` |
| Standard vs Advanced tier | Standard: مجاني، لحد 4KB. Advanced: لحد 8KB، policies (expiration)، مدفوع |
| Secrets Manager | secrets بـ rotation (Lambda أو managed)، versions (`AWSCURRENT`/`AWSPREVIOUS`)، replication، resource policies |
| Managed master password (RDS) | RDS بيعمل ويدير ويعمل rotation للـ password في Secrets Manager |
| KMS CMK | key انت بتتحكم في الـ policy بتاعته (cross-account، audit لكل decrypt) — ~$1/شهر |

### 1.1 الـ layout (CONVENTIONS §4)

```text
/student-app/<env>/app/<ENV_KEY>      → env التطبيق (app.env / ECS secrets / K8s Secret عن طريق ESO)
/student-app/<env>/mysql/<ENV_KEY>    → env الـ MySQL container (stacks 20–27 بس)
/student-app/<env>/deploy/<color>/IMAGE_URI   → الـ release (CI بيملكه، String)
```

اسم الـ parameter **بعد آخر `/`** = اسم الـ env var بالظبط. مين بيكتب إيه:

| Stack/module | String | SecureString |
|---|---|---|
| stack 20 `ssm.tf` | `APP_URL`، `DB_CONNECTION`، `DB_HOST=mysql`، `DB_PORT`، `DB_DATABASE`، `DB_USERNAME`، `SESSION_DRIVER`، `CACHE_STORE`، `SRE_LAB_ENABLED`، `METRICS_ENABLED`؛ mysql: `MYSQL_DATABASE`، `MYSQL_USER` | `APP_KEY`، `DB_PASSWORD`، `SRE_LAB_TOKEN`؛ mysql: `MYSQL_PASSWORD`، `MYSQL_ROOT_PASSWORD` |
| stacks 40/50 `ssm.tf` | `APP_URL`، `DB_CONNECTION`، `SESSION_DRIVER`، `CACHE_STORE`، `SRE_LAB_ENABLED`، `METRICS_ENABLED` (+ `SESSION_SECURE_COOKIE` = `true` لما الـ HTTPS متفعّل — stack 40 بس، [83](83-edge-security-waf-https.md)) | `APP_KEY`، `SRE_LAB_TOKEN` |
| `modules/rds-mysql` | `DB_HOST`، `DB_PORT`، `DB_DATABASE`، `DB_USERNAME` | `DB_PASSWORD` (لو `use_secrets_manager = false`) |
| `modules/elasticache-redis` | `REDIS_HOST`، `REDIS_PORT` | — |

الـ secrets بتتولد في Terraform (`random_bytes.app_key` 32 byte → `base64:…`، `random_password` 32 حرف alphanumeric — من غير `$ # " '` اللي بتكسر env files والـ shells). والـ stacks 20/40/50/60 بيكتبوا **نفس الـ paths** → stack واحد بس لكل env في نفس الوقت.

## 2) المعمارية (Architecture)

```text
                        ┌───────────── SSM Parameter Store (/student-app/lab/…) ──────────────┐
 Terraform (state! ───► │ String: APP_URL, DB_HOST…   SecureString (aws/ssm KMS): APP_KEY, DB_PASSWORD, SRE_LAB_TOKEN │
 encrypted S3 bucket)   └──────┬───────────────────┬─────────────────────┬──────────────────────┬─┘
                               │                   │                     │                      │
 EC2 single host               │ ASG instance      │ ECS task start      │ EKS
 render-env-from-ssm.sh ◄──────┘ user data ◄───────┘ execution role ◄────┘ External Secrets ◄───┘
 get-parameters-by-path        render_env (retry)  secrets[].valueFrom    ClusterSecretStore ParameterStore
 --recursive --with-decryption → app.env 600       = parameter ARN        → Secret student-app-secrets
 → /opt/student-app/app.env 600 → docker --env-file → container env        → envFrom
                                                    
 Secrets Manager (use_secrets_manager = true): RDS master password, rotation كل 7 أيام
   → ECS: valueFrom "<secret-arn>:password::" (محتاج wiring — §5.5)
```

## 3) المتطلبات (Prerequisites)

- [ ] stack 20 أو 40 أو 50 متعمله apply (عشان الـ parameters موجودة).
- [ ] [80](80-iam-oidc-least-privilege.md): فهمت الـ instance profiles والـ execution role.
- الأدوات: `aws`، `terraform`، `jq`.

## 4) الطريقة الأولى: AWS Console (يدوي)

### 4.1 Parameter Store

1. **Systems Manager → Parameter Store → Create parameter**:
   - Name: `/student-app/lab/app/METRICS_TOKEN` · Tier **Standard** · Type **SecureString** · KMS key source: **My current account** → `alias/aws/ssm` · Value: (عشوائي) → **Create**.
2. افتح أي parameter → **History**: كل version مين عملها وإمتى (للـ audit والـ rollback).
3. **Show decrypted value**: بيحتاج `kms:Decrypt` — جرّب بـ user من غير الصلاحية وشوف الرفض.

> ⚠️ لو حطيت `METRICS_TOKEN`، Prometheus لازم يبعته (`authorization` block في `prometheus.yml`)، و `canary.sh` بيعمل curl على `/metrics` **من غير** token فهيعمي الـ gate ([24](24-canary-single-host.md)). امسحه بعد التجربة.

### 4.2 RDS master password في Secrets Manager

1. **RDS → Databases → `student-app-lab-mysql` → Modify → Credentials management** → **Managed in AWS Secrets Manager** (encryption key: `aws/secretsmanager` أو CMK) → Continue → **Apply immediately**.
2. **Secrets Manager → Secrets** → هتلاقي secret اسمه بيبدأ بـ `rds!db-…` → **Rotation**: enabled، كل 7 أيام افتراضياً → **Retrieve secret value** (`username`، `password`).
3. ⚠️ من اللحظة دي `/student-app/lab/app/DB_PASSWORD` في SSM **مبقاش صحيح** — والتطبيق (اللي بيقرا من SSM) هيقع عند أول connection جديدة بعد الـ restart. (الـ Terraform هيعمل drift كمان.) اعملها في stack تجريبي أو بالـ IaC في §5.5.

### 4.3 Secret scanning على GitHub

**Repo → Settings → Code security** → **Secret scanning** + **Push protection** → enable. أي push فيه AWS key/token معروف بيترفض قبل ما يدخل الـ history.

## 5) الطريقة التانية: as Code

### 5.1 EC2: [`render-env-from-ssm.sh`](../../../deploy/ec2/render-env-from-ssm.sh)

```bash
aws ssm get-parameters-by-path --path "$PREFIX/$section/" --recursive --with-decryption \
    --query 'Parameters[*].[Name,Value]' --output text \
  | while IFS=$'\t' read -r name value; do printf '%s=%s\n' "${name##*/}" "$value"; done > "$tmp"
install -m 600 "$tmp" "$target"
```

- `ENV_NAME` (`lab`)، `APP_DIR` (`/opt/student-app`)؛ الـ region من IMDSv2 لو `AWS_REGION` مش متحدد.
- بيكتب `app.env` و `mysql.env` بـ **chmod 600** (`install -m 600` — مفيش لحظة الملف فيها world-readable).
- لو مفيش parameters تحت الـ path: الملف **بيفضل زي ما هو** (warning) — آمن ضد مسح كل الـ config بالغلط، بس معناه إن parameter اتمسح مش هيختفي من الـ env لحد ما تمسحه بإيدك.
- الصلاحيات (stack 20 role): `ssm:GetParametersByPath` على `/student-app/lab` و `/student-app/lab/*` + `kms:Decrypt` via SSM.
- ⚠️ القيم بتتكتب `KEY=value` من غير quoting — قيمة فيها newline أو `#` ممكن تتقري غلط في `--env-file`. عشان كده الـ passwords المولّدة alphanumeric.

### 5.2 ASG: الـ user data ([`user-data.sh.tftpl`](../../../infra/terraform/modules/asg-app/user-data.sh.tftpl))

نفس المنطق (`render_env` مع `retry` 10 × 6s — الـ instance profile والـ parameters الجديدة ممكن يتأخروا ثواني وقت الـ boot)، ثم `docker run --env-file /opt/student-app/app.env`. **أي تغيير في secret = instance refresh** (الـ env بيتقري وقت الـ boot بس).

### 5.3 ECS: `secrets[].valueFrom`

stack 50 بيبعت للـ module:

```hcl
secrets = merge(
  module.rds.ssm_parameter_arns,                                  # DB_HOST … DB_PASSWORD
  { for k, p in aws_ssm_parameter.app : k => p.arn },             # APP_URL, SESSION_DRIVER …
  { for k, p in aws_ssm_parameter.app_secret : k => p.arn },      # APP_KEY, SRE_LAB_TOKEN
)
```

وفي الـ task definition: `secrets = [{ name = "APP_KEY", valueFrom = "arn:aws:ssm:us-east-1:<acct>:parameter/student-app/lab/app/APP_KEY" }, …]`. الـ **execution role** (مش الـ task role) بيحلّها **وقت بداية الـ task** — بـ `ssm:GetParameters` على `/student-app/lab/app/*` و `kms:Decrypt` via SSM (أو على `kms_key_arns` لو CMK). الـ ARNs (مش strings) = الـ task definition مش بيتسجل غير بعد ما الـ parameters تتعمل. والقيم **مش بتظهر** في الـ task definition (بعكس `environment`).

**rotation على ECS** = tasks جديدة (`update-service --force-new-deployment`) — الـ tasks الشغالة شايلة القيمة القديمة.

### 5.4 EKS: External Secrets Operator

`ClusterSecretStore` (provider `ParameterStore`) → `ExternalSecret` بيعمل `find` بالـ path ويعمل rewrite للـ key (آخر جزء) → Secret `student-app-secrets` → `envFrom`. الـ ESO عنده Pod Identity/IRSA بصلاحية قراية الـ path ([64](64-eks-external-secrets.md)، و values `externalSecrets.*` في [`k8s/helm/student-app`](../../../k8s/helm/student-app)). الـ `refreshInterval` بيحدّث الـ Secret، بس الـ pods محتاجة restart (أو reloader) عشان الـ env يتغير.

### 5.5 Secrets Manager + RDS managed password (`use_secrets_manager`)

في [`modules/rds-mysql`](../../../infra/terraform/modules/rds-mysql):

```hcl
password                    = var.use_secrets_manager ? null : random_password.master[0].result
manage_master_user_password = var.use_secrets_manager ? true : null
```

لما `use_secrets_manager = true`:
- مفيش `random_password` → **الـ password مش في الـ Terraform state** (ميزة أمان حقيقية).
- `DB_PASSWORD` **مش بيتكتب في SSM**؛ output `master_user_secret_arn` بيرجّع الـ secret؛ `password_ssm_arn` = `null`.
- RDS بيعمل rotation (default كل 7 أيام).

**إيه اللي ناقص عشان تشغّله (مش موجود في الـ stacks):**

1. ولا stack بيمرر `use_secrets_manager` — لازم تضيفه في استدعاء `module "rds"`.
2. **ECS (stack 50):** ضيف لـ `secrets`:
   ```hcl
   DB_PASSWORD = "${module.rds.master_user_secret_arn}:password::"
   ```
   والـ execution role محتاج statement جديد (الـ module دلوقتي SSM بس):
   ```hcl
   statement {
     actions   = ["secretsmanager:GetSecretValue"]
     resources = [module.rds.master_user_secret_arn]
   }
   # + kms:Decrypt بشرط kms:ViaService = secretsmanager.<region>.amazonaws.com
   ```
3. **EC2/ASG:** الـ render scripts بتقرا SSM بس → تضيف خطوة:
   ```bash
   DB_PASSWORD=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" --query SecretString --output text | jq -r .password)
   ```
   أو تستخدم الـ reference `/aws/reference/secretsmanager/<secret-name>` مع `ssm get-parameter --with-decryption` (مش بيظهر في `get-parameters-by-path`).
4. **أهم مصيدة — الـ rotation بيكسر الـ connections الجديدة:** RDS بيغيّر الـ password، والتطبيق شايل القديم في الـ env لحد ما يتعمل restart → `SQLSTATE[HY000] [1045] Access denied` (اللوج query "Database trouble" في [70](70-logging.md)). الحلول: restart/redeploy بعد كل rotation (EventBridge على حدث الـ rotation → ECS force-new-deployment)، أو التطبيق يقرا الـ secret وقت الـ connection مع cache قصير، أو RDS Proxy (بيقرا من Secrets Manager)، أو IAM database authentication (tokens قصيرة العمر).

### 5.6 `APP_KEY` rotation

`APP_KEY` بيشفّر: الـ cookies (`EncryptCookies` — يعني الـ session cookie)، أي حاجة بـ `encrypt()`/`Crypt`، وبيوقّع الـ signed URLs. تغييره فجأة = **كل المستخدمين يتعملهم logout** (419 على أي فورم مفتوح) + أي داتا مشفرة في الـ DB مش هتتقري.

Laravel بيدعم rotation ناعم بـ `APP_PREVIOUS_KEYS` ([`config/app.php`](../../../config/app.php): `'previous_keys' => [...explode(',', env('APP_PREVIOUS_KEYS', ''))]`) — الـ decrypt بيجرب الـ keys القديمة لو الجديد فشل:

```bash
NEW="base64:$(openssl rand -base64 32)"                                          # نفس format الـ php artisan key:generate --show
OLD=$(aws ssm get-parameter --name /student-app/lab/app/APP_KEY --with-decryption --query Parameter.Value --output text)
aws ssm put-parameter --name /student-app/lab/app/APP_PREVIOUS_KEYS --type SecureString --value "$OLD" --overwrite
aws ssm put-parameter --name /student-app/lab/app/APP_KEY --type SecureString --value "$NEW" --overwrite
# roll **كل** الـ replicas (لازم كلهم بنفس مجموعة الـ keys):
aws ecs update-service --cluster student-app-lab --service student-app-lab-app --force-new-deployment   # أو instance refresh / render + redeploy
# بعد ما الـ sessions القديمة تخلص (SESSION_LIFETIME) وتعيد تشفير الداتا: امسح APP_PREVIOUS_KEYS
```

> ⚠️ الـ `APP_KEY` متولّد في Terraform (`random_bytes.app_key`) — `terraform apply` الجاي هيرجّعه للقيمة اللي في الـ state. لو عملت rotation بإيدك، حدّث الـ Terraform (مثلاً `-replace=random_bytes.app_key` كـ rotation مقصود، أو `ignore_changes`). وكل الـ replicas — وموقع الـ DR ([77](77-backup-and-dr.md)) — لازم نفس الـ key، وإلا الـ sessions بتبوظ مع كل request بيروح replica تاني.

### 5.7 الـ secrets في git وفي الـ Terraform state

- **git:** `.env` في `.gitignore`؛ `deploy/env/*.example` بس placeholders؛ الـ secrets في GitHub = `secrets.*` (زي `SRE_LAB_TOKEN`) والـ AWS access = OIDC (مفيش keys). لو secret اتعمله commit: **rotate فوراً** (الـ history والـ forks فيها نسخة) — مسح الـ commit لوحده مش كفاية. أدوات: GitHub push protection، `gitleaks`/`trufflehog` في الـ CI.
- **Terraform state = secret:** الـ `random_password`/`random_bytes` و قيم الـ `aws_ssm_parameter` **مكتوبة plain text** في الـ state JSON. `sensitive = true` بيخفيها من الـ CLI output بس. عشان كده الـ state bucket ([`bootstrap/main.tf`](../../../infra/terraform/bootstrap/main.tf)): SSE (AES256)، public access block، `BucketOwnerEnforced`، policy `DenyInsecureTransport`، versioning (⚠️ الـ versions القديمة فيها الـ secrets القديمة لحد 90 يوم — `state_noncurrent_days`)، والوصول محدود (والـ plan role بيقرا الـ state — [80](80-iam-oidc-least-privilege.md)). للتحسين: `aws:kms` بـ CMK (audit لكل decrypt + key policy)، و `use_secrets_manager` للـ DB، و write-only arguments في Terraform الحديث (Terraform ≥ 1.11 — زي `password_wo` على بعض الـ resources؛ راجع docs الـ AWS provider للـ resource بتاعك).

## 6) الـ Deploy

```bash
# اقرا layout الـ env
aws ssm get-parameters-by-path --path /student-app/lab/ --recursive \
  --query 'Parameters[].[Name,Type,Version]' --output table

# على الـ host (stack 20): render + redeploy
sudo bash /opt/student-app/src/deploy/ec2/render-env-from-ssm.sh
ls -l /opt/student-app/app.env                                  # -rw------- 
bash /opt/student-app/src/deploy/ec2/deploy-pull-image.sh <IMAGE_URI>   # الـ env الجديدة بتدخل مع recreate

# ASG: instance refresh · ECS: force-new-deployment
aws autoscaling start-instance-refresh --auto-scaling-group-name student-app-lab-blue
aws ecs update-service --cluster student-app-lab --service student-app-lab-app --force-new-deployment
```

## 7) التحقق (Verify)

```bash
aws ssm get-parameter --name /student-app/lab/app/APP_KEY --query 'Parameter.[Type,Version,LastModifiedDate]'
aws ssm get-parameter-history --name /student-app/lab/app/SRE_LAB_TOKEN --query 'Parameters[].[Version,LastModifiedDate,LastModifiedUser]' --output table
aws ecs describe-task-definition --task-definition student-app-lab-app \
  --query 'taskDefinition.containerDefinitions[0].secrets[].[name,valueFrom]' --output table   # ARNs مش قيم
aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue=GetParametersByPath --max-results 5 \
  --query 'Events[].[EventTime,Username]' --output table
aws s3api get-bucket-encryption --bucket student-app-tfstate-<ACCOUNT_ID>
```

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر | المتوقع |
|---|---|---|
| شيل `kms:Decrypt` من الـ execution role | (stack تجريبي) | الـ task مش بيبدأ: `ResourceInitializationError: unable to pull secrets or registry auth` |
| parameter مش موجود | امسح `/student-app/lab/app/SRE_LAB_TOKEN` واعمل ECS deploy | فشل الـ task (الـ ARN مش موجود)؛ على EC2: `render` بيشيله من الملف الجديد (الملف بيتعمل من اللي موجود) |
| `APP_KEY` مختلف بين blue و green | `SLOT_ENV="APP_KEY=base64:$(openssl rand -base64 32)"` في ستاك [23](23-bluegreen-single-host.md) | بعد الـ switch كل المستخدمين logout و 419 (k6: `csrf_failures`/`session_relogins`) |
| Rotation للـ DB password من غير restart | (managed rotation) | الـ connections الجديدة بعد الـ restart بالـ env القديم: `[1045] Access denied` |
| قيمة فيها `#` | password يدوي فيه `#` في SSM | ممكن يتقطع في `--env-file` — ليه الـ generator alphanumeric |
| Secret في git | جرّب push لملف فيه AWS key وهمي بالـ format الصحيح (push protection شغال) | GitHub يرفض الـ push |

## 9) الرجوع (Rollback)

```bash
aws ssm get-parameter-history --name /student-app/lab/app/APP_KEY --with-decryption --query 'Parameters[-2].Value' --output text   # القيمة السابقة
aws ssm put-parameter --name /student-app/lab/app/APP_KEY --type SecureString --value '<PREVIOUS>' --overwrite
# ثم redeploy/refresh — أو terraform apply (بيرجّع القيمة اللي في الـ state)
```

Secrets Manager: الـ version السابقة متعلّم عليها `AWSPREVIOUS` (`aws secretsmanager get-secret-value --secret-id <ARN> --version-stage AWSPREVIOUS`).

## 10) المسح (Teardown) ⚠️

```bash
aws ssm delete-parameter --name /student-app/lab/app/METRICS_TOKEN
aws ssm delete-parameter --name /student-app/lab/app/APP_PREVIOUS_KEYS
aws secretsmanager list-secrets --query 'SecretList[?starts_with(Name,`rds!`)].[Name,ARN]'   # بيتمسح مع الـ RDS instance
```

`terraform destroy` بيمسح الـ parameters اللي هو عاملها. الـ parameters اللي عملتها بإيدك (أو `SRE_FAULT_*` من [75](75-chaos-engineering-fis.md)) **بتفضل** — و stack تاني على نفس الـ env هيقراها.

## 11) التكلفة (Cost)

| Resource | السعر التقريبي (تقريبي — راجع صفحة الأسعار) |
|---|---|
| SSM Standard parameters (String/SecureString) | مجاني (standard throughput) |
| SSM Advanced parameter | ~$0.05/parameter/شهر |
| KMS `aws/ssm`، `aws/secretsmanager` | الـ key مجاني؛ الـ API calls ليها free tier ثم ~$0.03/10k |
| KMS CMK | ~$1/key/شهر |
| Secrets Manager | ~$0.40/secret/شهر + ~$0.05/10k API calls |

## 12) أسئلة Interview

<details><summary>SSM Parameter Store ولا Secrets Manager؟</summary>

SSM: مجاني (standard)، بسيط، hierarchical paths و `GetParametersByPath`، ممتاز للـ config والـ secrets الثابتة. Secrets Manager: rotation مدمج (RDS managed، Lambda)، versions staging، cross-region replication، resource policies للـ cross-account — ومدفوع لكل secret. الشائع (وده المعمل): SSM للـ config والـ secrets العادية، و Secrets Manager للـ DB credentials اللي محتاجة rotation.

</details>

<details><summary>ECS: إيه الفرق بين `environment` و `secrets` وبين الـ execution role والـ task role؟</summary>

`environment` قيم plain في الـ task definition (أي حد يقرا الـ task def يشوفها). `secrets` = ARN بس، والقيمة بتتحل وقت بداية الـ task. الـ execution role هو اللي بيحل الـ secrets ويعمل pull للـ image ويكتب اللوجز (الـ ECS agent)؛ الـ task role هو صلاحيات كود التطبيق نفسه (هنا ECS Exec بس). يعني التطبيق مش محتاج صلاحية SSM خالص.

</details>

<details><summary>إزاي تعمل rotation لـ DB password من غير downtime؟</summary>

Single-user rotation بتكسر أي connection جديدة بالـ password القديم لحد ما التطبيق ياخد الجديد. الحلول: alternating users (اتنين users، الـ rotation بيبدّل)، التطبيق يقرا من Secrets Manager وقت الـ connect مع retry على auth error، RDS Proxy (هو اللي بيقرا الـ secret)، أو IAM DB auth. ولو التطبيق بياخد الـ env وقت البداية (زي هنا): restart منسق بعد كل rotation (EventBridge → deploy).

</details>

<details><summary>ليه الـ Terraform state حساس، وإزاي تحميه؟</summary>

لأن أي قيمة Terraform يعرفها (generated passwords، قيم SSM، outputs) مكتوبة plain في الـ state. الحماية: backend مشفّر (S3 SSE/KMS) بـ access محدود جداً، TLS-only، versioning مع expiry، مفيش state محلي متشارك، والأفضل إن Terraform **ميعرفش** الـ secret أصلاً: managed passwords (RDS → Secrets Manager)، write-only arguments، أو الـ secret يتولد بره Terraform.

</details>

<details><summary>إيه اللي بيحصل لو غيّرت `APP_KEY`، وإزاي تعمله صح؟</summary>

كل الـ cookies المشفرة (الـ session) والداتا المشفرة بـ `encrypt()` والـ signed URLs تبقى invalid → logout جماعي، 419، داتا مش بتتقري. الصح: `APP_PREVIOUS_KEYS` = القديم، `APP_KEY` = الجديد، roll كل الـ replicas مع بعض، re-encrypt للداتا المشفرة، وبعد ما الـ sessions القديمة تنتهي امسح القديم. وكل الـ replicas والـ DR لازم نفس الـ key set.

</details>

<details><summary>secret اتعمله commit في repo public — الخطوات؟</summary>

1) rotate/revoke فوراً (افترض إنه اتسرق — في bots بتمسح GitHub في ثواني). 2) شوف الـ audit (CloudTrail/الـ provider logs) لأي استخدام. 3) شيله من الـ history (`git filter-repo`) — للنضافة، مش للأمان. 4) postmortem: ليه push protection/pre-commit ما مسكهوش. ومع OIDC مفيش AWS keys أصلاً تتسرّب.

</details>

## 13) Checklist

- [ ] عرفت مين بيكتب كل parameter في `/student-app/lab/app/*` (الـ stack ولا الـ module)
- [ ] شغّلت `render-env-from-ssm.sh` واتأكدت إن `app.env` بـ 600
- [ ] شفت الـ ECS task definition فيها ARNs مش قيم
- [ ] فهمت إيه اللي ناقص عشان `use_secrets_manager` يشتغل على كل platform
- [ ] جرّبت `APP_KEY` rotation بـ `APP_PREVIOUS_KEYS` (أو قريت الخطوات وفهمت ليه)
- [ ] فعّلت secret scanning + push protection على الـ repo
- [ ] أقدر أشرح ليه الـ state bucket مشفّر وليه الـ versions القديمة فيها secrets
