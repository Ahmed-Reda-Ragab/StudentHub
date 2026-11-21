# 77 — Backup و Disaster Recovery (RTO/RPO)

> **الهدف في سطر:** تحدد RTO/RPO بأرقام، تعمل backup وrestore drill **متقاس** لـ MySQL الـ container (السكريبت الحقيقي)، تفهم RDS automated backups و PITR و snapshots و cross-region copy (Console + إعدادات الـ Terraform module)، تعرف AWS Backup، وتختار استراتيجية DR (backup & restore، pilot light، warm standby، multi-site) بالتكلفة والـ RTO.
> **المستوى:** Intermediate → Advanced · **الوقت:** ~4 ساعات · **التكلفة التقريبية:** سنتات (snapshots/S3) + ساعة RDS إضافية للـ restore
> **بيعتمد على:** [27](27-mysql-backup-restore.md) · [41](41-rds-mysql.md) · **الملفات في الـ repo:** [`deploy/ec2/backup-mysql-to-s3.sh`](../../../deploy/ec2/backup-mysql-to-s3.sh) · [`stacks/20-ec2-single/main.tf`](../../../infra/terraform/stacks/20-ec2-single/main.tf) (backups bucket) · [`stacks/20-ec2-single/iam.tf`](../../../infra/terraform/stacks/20-ec2-single/iam.tf) · [`modules/rds-mysql/main.tf`](../../../infra/terraform/modules/rds-mysql/main.tf) · [`modules/rds-mysql/variables.tf`](../../../infra/terraform/modules/rds-mysql/variables.tf) · [`infra/ansible/roles/mysql_backup`](../../../infra/ansible/roles/mysql_backup)

## 1) الفكرة (Concepts)

| المصطلح | المعنى |
|---|---|
| **RPO** (Recovery Point Objective) | أقصى **داتا** مسموح تضيع — "نرجع لحالة من قد إيه؟" (backup يومي = RPO لحد 24 ساعة) |
| **RTO** (Recovery Time Objective) | أقصى **وقت** لحد ما الخدمة ترجع |
| Backup | نسخة منفصلة تقدر ترجعلها (ضد الحذف، الـ corruption، الـ ransomware، الـ bugs) |
| Replica / Multi-AZ | **High availability** مش backup — `DROP TABLE` بيتنسخ للـ standby في نفس اللحظة |
| Logical backup | `mysqldump` → SQL (portable، بطيء في الـ restore للداتا الكبيرة) |
| Physical / snapshot | نسخة من الـ storage (سريعة، نفس الـ engine) |
| PITR | Point-in-time recovery = snapshot + transaction logs → أي ثانية في نافذة الـ retention |
| 3-2-1 | 3 نسخ، على 2 media مختلفين، 1 بره الموقع (region/account تاني) |
| Immutable backup | مستحيل يتمسح/يتعدّل قبل مدة (S3 Object Lock، AWS Backup Vault Lock) |

**القاعدة الذهبية:** الـ backup اللي ما اتعملوش restore drill = **أمل** مش backup. بتعرف الـ RTO الحقيقي من الـ drill بس.

### 1.1 الـ RTO/RPO في المعمل

| Setup | الـ backup | RPO الواقعي | RTO الواقعي (للداتا الصغيرة دي) |
|---|---|---|---|
| MySQL container (stacks 20–27) | `backup-mysql-to-s3.sh` (يومي عن طريق systemd timer — role `mysql_backup`) | لحد 24 ساعة (التكرار) | دقايق (download + `mysql` import) + وقت ما تلاحظ |
| RDS (41+) | automated backups 7 أيام + PITR | ~5 دقايق (الـ transaction logs بتترفع كل ~5 دقايق) | 10–30 دقيقة (instance جديد) + تحويل الـ app للـ endpoint الجديد |
| RDS + cross-region backups | replication لـ region تاني | دقايق | نفس + الـ infra في الـ region التاني (ده الجزء الصعب) |

## 2) المعمارية (Architecture)

```text
 Single host (stack 20)                                RDS (stacks 40/50/60)
 ┌───────────────────────────────┐                     ┌────────────────────────────────────────┐
 │ mysql container ─ mysqldump   │                     │ student-app-lab-mysql (encrypted aws/rds)│
 │  --single-transaction --quick │                     │ backup window 03:00-03:30 UTC            │
 │  | gzip -9 | aws s3 cp - --sse │                     │ automated backups 7d + binlogs → PITR    │
 └──────────────┬────────────────┘                     └──────┬───────────────┬──────────────────┘
                ▼                                             │ manual        │ cross-region
 s3://student-app-lab-backups-<acct>/mysql/student_app-<UTC>.sql.gz   snapshot ▼ copy / replication ▼
   SSE-S3 · public access block · TLS-only · lifecycle: expire 30d   (survive destroy) us-west-2 (DR)
                │ restore drill                               │
                ▼                                             ▼
 scratch DB student_app_restore ─► counts/checksums      restore-db-instance-to-point-in-time ─► new endpoint
                                                         ─► SSM /student-app/lab/app/DB_HOST ─► redeploy/refresh
```

## 3) المتطلبات (Prerequisites)

- [ ] للجزء الأول: host stack 20 (فيه `aws_s3_bucket.backups` و الـ instance profile عنده `s3:GetObject/PutObject/ListBucket` على الـ bucket ده).
- [ ] للجزء التاني: RDS من stack 40/50 (أو [41](41-rds-mysql.md)).
- [ ] داتا حقيقية: `LoadTestSeeder` ([74](74-load-testing-k6.md)) عشان الـ restore يبقى ليه معنى.
- الأدوات: `aws`، `terraform`، `mysql` client (جوه الـ container أو instance)، `jq`.

## 4) الطريقة الأولى: AWS Console (يدوي)

### 4.1 RDS automated backups و PITR

1. **RDS → Databases → `student-app-lab-mysql` → Maintenance & backups**: Automated backups **Enabled (7 Days)**، Backup window، **Latest restore time** (عادةً من خمس دقايق).
2. **Actions → Restore to point in time** → Custom date and time (قبل "الحادثة" بدقيقة) → DB instance identifier `student-app-lab-mysql-pitr` → **نفس** الـ VPC و DB subnet group (`student-app-lab-mysql`) و security group (`student-app-lab-rds`) و **parameter group** (`student-app-lab-mysql-…` — مهم: من غيره utf8mb4 والـ slow log مش هيبقوا مظبوطين) → Public access **No** → **Restore**.
3. استنى **Available** — وده الـ RTO بتاعك (سجّل الوقت).

### 4.2 Manual snapshot و cross-region copy

1. **Actions → Take snapshot** → `student-app-lab-mysql-drill-<YYYYMMDD>`.
2. **Snapshots → Manual → اختار → Actions → Copy snapshot** → Destination Region `us-west-2` → **Encryption**: لازم تختار KMS key **في الـ destination region** → Copy.
3. لاحظ: الـ snapshot مشفّر بالـ AWS-managed key `aws/rds` → **مينفعش يتشير لـ account تاني** (محتاج customer-managed KMS key). ده قرار لازم يتاخد قبل ما تحتاجه.

### 4.3 Cross-region automated backups (PITR في region تاني)

**RDS → Automated backups → Replicated** (أو من الـ instance → Actions → **Manage cross-Region automated backups**) → destination `us-west-2`، retention، KMS key → Save. بيتنسخ الـ snapshots والـ transaction logs → تقدر تعمل PITR في الـ DR region.

### 4.4 AWS Backup

1. **AWS Backup → Backup vaults → Create** `student-app-lab-vault` (اختياري **Vault Lock** — WORM: compliance mode مستحيل يتلغي حتى من root بعد الـ grace period، فجرّب governance الأول).
2. **Backup plans → Create backup plan → Build a new plan** → `student-app-lab-daily` → rule: daily، retention 7 days، **Copy to destination**: `us-west-2` vault (cross-region)، (اختياري) **Continuous backups for supported resources** (PITR لـ RDS حتى 35 يوم).
3. **Assign resources** → IAM role default (`AWSBackupDefaultServiceRole`) → **Include specific resource types** RDS أو **tags** `Project=student-app` → Assign.
4. **Jobs** → اتأكد إن أول job نجح؛ و **Restore testing** (feature في AWS Backup لاختبار الـ restore أوتوماتيك) لو عايز drill دوري.

> 💡 RDS automated backups كفاية للمعمل؛ AWS Backup بيدّيك سياسة **مركزية** على كل الموارد (RDS، EBS، S3، EFS، DynamoDB...) و vault lock و cross-account copy — ده اللي الـ auditors بيسألوا عليه.

## 5) الطريقة التانية: as Code

### 5.1 السكريبت: [`backup-mysql-to-s3.sh`](../../../deploy/ec2/backup-mysql-to-s3.sh)

```bash
KEY="mysql/${DB}-$(date -u +%Y-%m-%dT%H%M).sql.gz"
compose exec -T mysql sh -c "mysqldump --single-transaction --quick --routines --triggers -uroot -p\"\$MYSQL_ROOT_PASSWORD\" $DB" \
    | gzip -9 | aws s3 cp - "s3://$BUCKET/$KEY" --sse AES256
```

- `--single-transaction`: snapshot متسق لـ InnoDB **من غير locks** (الـ app شغال عادي). `--quick`: row بـ row (memory ثابتة). `--routines --triggers`: الـ stored code.
- stream مباشرة (`|`) من غير ملف مؤقت على الـ disk. والـ password بيتقري من env الـ container (`$MYSQL_ROOT_PASSWORD` مـ escaped فبيتفك جوه الـ container مش على الـ host).
- `set -euo pipefail`: لو `mysqldump` فشل الـ pipeline كله يفشل (مش هيرفع ملف فاضي "ناجح").
- Env: `BACKUP_BUCKET` (إجباري)، `DB_NAME` (`student_app`)، `APP_DIR` (`/opt/student-app`)، `COMPOSE_FILE`.
- **Restore:** `./backup-mysql-to-s3.sh restore s3://bucket/key.sql.gz` → `aws s3 cp - | gunzip | mysql $DB` (بيكتب فوق الداتا).
- الـ dump من غير `--databases` → مفيهوش `CREATE DATABASE`/`USE` → تقدر ترجّعه في database باسم مختلف (`DB_NAME=student_app_restore`) — ده اللي بيخلّي الـ drill آمن.
- الجدولة: Ansible role [`mysql_backup`](../../../infra/ansible/roles/mysql_backup) (systemd timer — بيتكتب).

**الـ bucket** (stack 20 [`main.tf`](../../../infra/terraform/stacks/20-ec2-single/main.tf)): `student-app-lab-backups-<account_id>`، `BucketOwnerEnforced`، public access block، SSE-S3، policy `DenyInsecureTransport`، lifecycle `expire-dumps` بعد `backup_retention_days` (30)، `force_destroy = true` (lab). **مفيهوش versioning ولا Object Lock** — الـ host role عنده `s3:PutObject` فـ host مخترق يقدر يكتب فوق dump بنفس الاسم. لـ backups جدية: versioning + Object Lock (governance) + replication لـ account تاني.

### 5.2 RDS module ([`modules/rds-mysql`](../../../infra/terraform/modules/rds-mysql))

| Setting | القيمة | الأثر على الـ DR |
|---|---|---|
| `backup_retention_period` | `7` | automated backups + PITR لـ 7 أيام (0 = مفيش PITR) |
| `backup_window` | `03:00-03:30` UTC | قبل الـ maintenance window (`sun:04:00-04:30`) |
| `copy_tags_to_snapshot` | `true` | الـ snapshots عليها `Project`/`Env` (cost + AWS Backup selection) |
| `storage_encrypted` | `true` (`aws/rds`) | مجاني، ومينفعش يتضاف بعدين — بس snapshot مش قابل للـ share cross-account |
| `multi_az` | `false` (variable) | HA (failover ~1–2 دقيقة) — **مش backup** |
| `deletion_protection` | `false` (lab) | `true` لأي حاجة حقيقية |
| `skip_final_snapshot` | `true` (lab) | ⚠️ `terraform destroy` = مفيش snapshot أخير |
| `delete_automated_backups` | `true` (module input، default = lab hygiene) | ⚠️ مسح الـ instance = مسح الـ automated backups (الـ PITR) كمان. مع `skip_final_snapshot = true` يعني **destroy = الداتا راحت**. أي حاجة ممكن تحتاج restore منها: `delete_automated_backups = false` **و** `skip_final_snapshot = false` |
| `final_snapshot_identifier` | `<id>-final-<random hex>` | اسم unique لو قفلت الـ skip |
| cross-region | **مش متعمل** | إضافة مقترحة تحت |

stack 40 بيعرض `db_skip_final_snapshot` و `db_deletion_protection` كـ variables؛ الـ `delete_automated_backups` input في الـ module بس (الـ stacks بيستخدموا الـ default `true`) — عشان تقفله ضيف `delete_automated_backups = false` في استدعاء `module "rds"` في [`stacks/40-ec2-alb-asg/main.tf`](../../../infra/terraform/stacks/40-ec2-alb-asg/main.tf) (أو اعمله variable زي الاتنين التانيين):

```bash
cd infra/terraform/stacks/40-ec2-alb-asg
# بعد ما تضيف delete_automated_backups = false لـ module "rds":
terraform apply -var db_skip_final_snapshot=false -var db_deletion_protection=true -var image_tag=<SHA7>   # "وضع production"
```

إضافة مقترحة لـ cross-region automated backups (**مش في الـ repo**):

```hcl
provider "aws" {
  alias  = "dr"
  region = "us-west-2"
}

resource "aws_kms_key" "dr_backups" {
  provider            = aws.dr
  description         = "student-app-lab RDS cross-region backups"
  enable_key_rotation = true
}

resource "aws_db_instance_automated_backups_replication" "dr" {
  provider               = aws.dr
  source_db_instance_arn = module.rds.arn
  retention_period       = 7
  kms_key_id             = aws_kms_key.dr_backups.arn
}
```

و AWS Backup (**مش في الـ repo**) — الهيكل: `aws_backup_vault` + `aws_backup_plan` (rule بـ `schedule = "cron(0 3 * * ? *)"`، `lifecycle { delete_after = 7 }`، `copy_action { destination_vault_arn = … }`) + `aws_backup_selection` بـ `selection_tag { type = "STRINGEQUALS", key = "Project", value = "student-app" }` و IAM role بـ `AWSBackupServiceRolePolicyForBackup` / `…ForRestores`.

## 6) الـ Deploy — restore drills متقاسة

### 6.1 Drill 1: الـ container MySQL → S3 → scratch DB

على الـ host (Session Manager):

```bash
cd /opt/student-app/src
export BACKUP_BUCKET=$(aws s3api list-buckets --query "Buckets[?starts_with(Name,'student-app-lab-backups-')].Name | [0]" --output text)
export APP_ENV_FILE=/opt/student-app/app.env MYSQL_ENV_FILE=/opt/student-app/mysql.env
C="docker compose -f docker-compose.prod.yml"
SQL() { $C exec -T mysql sh -c "mysql -uroot -p\"\$MYSQL_ROOT_PASSWORD\" -N -e \"$1\""; }

# 0) baseline
SQL "SELECT COUNT(*) FROM student_app.students; SELECT COUNT(*) FROM student_app.subscriptions;"

# 1) backup (سجّل المدة)
time bash deploy/ec2/backup-mysql-to-s3.sh
KEY=$(aws s3 ls "s3://$BACKUP_BUCKET/mysql/" | sort | tail -1 | awk '{print $4}')
aws s3 ls "s3://$BACKUP_BUCKET/mysql/$KEY" --human-readable

# 2) restore في database منفصلة (مش الـ production DB!)
SQL "CREATE DATABASE IF NOT EXISTS student_app_restore CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
T0=$(date +%s)
DB_NAME=student_app_restore bash deploy/ec2/backup-mysql-to-s3.sh restore "s3://$BACKUP_BUCKET/mysql/$KEY"
echo "restore took $(( $(date +%s) - T0 ))s"

# 3) verify
SQL "SELECT COUNT(*) FROM student_app_restore.students; SELECT COUNT(*) FROM student_app_restore.subscriptions;"
SQL "CHECKSUM TABLE student_app.students, student_app_restore.students;"   # ممكن يختلف لو فيه كتابة حصلت بعد الـ dump

# 4) cleanup
SQL "DROP DATABASE student_app_restore;"
```

المحلي (WSL، من غير S3): نفس الفكرة بـ `docker compose exec -T mysql mysqldump … | gzip > /tmp/x.sql.gz` ثم `gunzip -c | mysql student_app_restore`.

### 6.2 Drill 2: RDS PITR (CLI)

```bash
DB=student-app-lab-mysql
aws rds describe-db-instances --db-instance-identifier $DB \
  --query 'DBInstances[0].[LatestRestorableTime,BackupRetentionPeriod,DBParameterGroups[0].DBParameterGroupName,VpcSecurityGroups[0].VpcSecurityGroupId,DBSubnetGroup.DBSubnetGroupName]' --output text

# "الحادثة": امسح حاجة (على lab بس)، وسجّل الوقت قبلها بدقيقة
RESTORE_TIME=$(date -u -d '-2 min' +%Y-%m-%dT%H:%M:%SZ)

T0=$(date +%s)
aws rds restore-db-instance-to-point-in-time \
  --source-db-instance-identifier $DB --target-db-instance-identifier ${DB}-pitr \
  --restore-time "$RESTORE_TIME" \
  --db-subnet-group-name <SUBNET_GROUP> --vpc-security-group-ids <RDS_SG_ID> \
  --db-parameter-group-name <PARAM_GROUP> --db-instance-class db.t4g.micro --no-publicly-accessible \
  --tags Key=Project,Value=student-app Key=Env,Value=lab Key=Scenario,Value=77
aws rds wait db-instance-available --db-instance-identifier ${DB}-pitr
echo "PITR available after $(( $(date +%s) - T0 ))s"
NEW_HOST=$(aws rds describe-db-instances --db-instance-identifier ${DB}-pitr --query 'DBInstances[0].Endpoint.Address' --output text)
```

**تحويل التطبيق** (ده نص الـ RTO):

```bash
aws ssm put-parameter --name /student-app/lab/app/DB_HOST --type String --value "$NEW_HOST" --overwrite
# ASG (stack 40): الـ user data بيقرا SSM وقت الـ boot
aws autoscaling start-instance-refresh --auto-scaling-group-name student-app-lab-blue --preferences '{"MinHealthyPercentage":50,"InstanceWarmup":120}'
# ECS (stack 50): الـ secrets بتتقري وقت بداية الـ task
aws ecs update-service --cluster student-app-lab --service student-app-lab-app --force-new-deployment
```

> ⚠️ `DB_HOST` متملوك لـ Terraform (`modules/rds-mysql`) — الـ `apply` الجاي هيرجّعه للـ endpoint القديم. في incident حقيقي: يا إما ترجع تعمل الـ instance القديم بنفس الاسم (rename القديم، rename الـ PITR للاسم الأصلي → نفس الـ endpoint DNS)، يا إما تعمل `terraform import`/تحدّث الـ state. ده سؤال لازم يتجاوب في الـ DR plan قبل الحادثة.

### 6.3 Snapshot + cross-region copy (CLI)

```bash
SNAP=student-app-lab-mysql-drill-$(date +%Y%m%d%H%M)
aws rds create-db-snapshot --db-instance-identifier student-app-lab-mysql --db-snapshot-identifier $SNAP \
  --tags Key=Project,Value=student-app Key=Scenario,Value=77
aws rds wait db-snapshot-available --db-snapshot-identifier $SNAP

ACCT=$(aws sts get-caller-identity --query Account --output text)
aws rds copy-db-snapshot --region us-west-2 --source-region us-east-1 \
  --source-db-snapshot-identifier arn:aws:rds:us-east-1:$ACCT:snapshot:$SNAP \
  --target-db-snapshot-identifier ${SNAP}-dr --kms-key-id <DEST_REGION_KMS_KEY_ARN> --copy-tags

# أو replication مستمرة للـ automated backups (بتتنفذ في الـ destination region)
aws rds start-db-instance-automated-backups-replication --region us-west-2 \
  --source-db-instance-arn arn:aws:rds:us-east-1:$ACCT:db:student-app-lab-mysql \
  --backup-retention-period 7 --kms-key-id <DEST_REGION_KMS_KEY_ARN>
```

### 6.4 استراتيجيات الـ DR

| الاستراتيجية | الفكرة | RPO | RTO | التكلفة | في المعمل ده |
|---|---|---|---|---|---|
| Backup & restore | backups في region تاني؛ وقت الكارثة تبني كل حاجة (Terraform) وترجّع الداتا | ساعات (أو دقايق مع cross-region PITR) | ساعات | $ | snapshots/backups replication + `terraform apply` للـ stack في `us-west-2` |
| Pilot light | الـ data layer شغالة في الـ DR (cross-region read replica)، والـ compute متعمل بس مطفي/0 | دقايق | عشرات الدقايق | $$ | RDS read replica cross-region + ASG `desired=0` / ECS `desired_count=0` |
| Warm standby | نسخة مصغّرة شغالة فعلاً في الـ DR وبتستقبل traffic تجريبي | ثواني–دقايق | دقايق | $$$ | stack كامل بـ 1 task/instance + Route 53 failover |
| Multi-site active/active | الاتنين بيخدموا traffic | ~صفر | ~صفر | $$$$ | محتاج write strategy (Aurora Global Database / تقسيم الـ users) — بره نطاق المعمل |

حاجات بتتنسى في الـ DR (مش الداتا بس):
- **ECR images**: replication لـ الـ region التاني (ECR replication rules) وإلا مفيش حاجة تعملها deploy.
- **SSM parameters** مش بتتنسخ لوحدها — و **`APP_KEY` لازم يبقى نفس القيمة** في الـ DR (وإلا كل الـ sessions والـ encrypted data/cookies تبوظ — [81](81-secrets-management.md)).
- **Terraform state bucket**: S3 replication، وإلا مش هتعرف تعمل `apply` في الـ DR لو الـ region الأساسي واقع.
- **DNS**: Route 53 health checks + failover records؛ TTL قصير.
- **الـ runbook نفسه** والـ access (IAM Identity Center مش معتمد على الـ region الواقع؟).

## 7) التحقق (Verify) — سجّل الـ drill

```markdown
| Drill | التاريخ | حجم الداتا | Backup duration | Restore duration | Switch-over | RTO الكلي | RPO الفعلي | Data check |
|---|---|---|---|---|---|---|---|---|
| container dump → scratch | … | … MB gz | …s | …s | — | … | آخر dump: … | counts ✅ |
| RDS PITR | … | 20 GiB alloc | — | …m | …m (SSM + refresh) | …m | restore time − incident | counts ✅ |
```

```bash
aws s3api list-objects-v2 --bucket "$BACKUP_BUCKET" --prefix mysql/ --query 'sort_by(Contents,&LastModified)[-3:].[Key,Size,LastModified]' --output table
aws s3api get-bucket-lifecycle-configuration --bucket "$BACKUP_BUCKET"
aws rds describe-db-snapshots --db-instance-identifier student-app-lab-mysql --query 'DBSnapshots[].[DBSnapshotIdentifier,SnapshotType,Status,SnapshotCreateTime]' --output table
aws rds describe-db-instance-automated-backups --region us-west-2 --query 'DBInstanceAutomatedBackups[].[DBInstanceIdentifier,Status,RestoreWindow]'
```

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر | المتوقع / الدرس |
|---|---|---|
| Backup "ناجح" فاضي | `BACKUP_BUCKET=x DB_NAME=wrong_db bash deploy/ec2/backup-mysql-to-s3.sh` | `mysqldump` يفشل → `pipefail` يفشّل السكريبت. شيل `pipefail` في نسخة تجريبية وشوف ملف صغير بيترفع — ليه لازم تتحقق من الحجم/الـ restore |
| Restore فوق الـ production | `restore` من غير `DB_NAME` | بيكتب فوق `student_app` — عشان كده الـ drill على scratch DB |
| `DROP TABLE` على Multi-AZ | (فكّر) | بيتنسخ للـ standby — الـ HA مش backup؛ الحل PITR |
| `terraform destroy` بالـ defaults | (فكّر، متعملهوش على داتا مهمة) | مفيش final snapshot و `delete_automated_backups = true` (default) → الداتا راحت — ليه الاتنين `false` في أي environment حقيقي |
| PITR من غير parameter group | شيل `--db-parameter-group-name` | الـ instance بـ default group: charset/collation/slow log مختلفين |
| Snapshot cross-account | share snapshot مشفّر بـ `aws/rds` | مش مسموح — محتاج CMK |

## 9) الرجوع (Rollback)

- رجّع `DB_HOST` للـ endpoint الأصلي (أو `terraform apply` بيعمل ده) + refresh/redeploy.
- Restore غلط على الـ production DB في الـ container: restore من الـ dump اللي قبله (لهذا retention 30 يوم).

## 10) المسح (Teardown) ⚠️

```bash
aws rds delete-db-instance --db-instance-identifier student-app-lab-mysql-pitr --skip-final-snapshot --delete-automated-backups
aws rds delete-db-snapshot --db-snapshot-identifier <SNAP>
aws rds delete-db-snapshot --region us-west-2 --db-snapshot-identifier <SNAP>-dr
aws rds stop-db-instance-automated-backups-replication --region us-west-2 \
  --source-db-instance-arn arn:aws:rds:us-east-1:<ACCOUNT_ID>:db:student-app-lab-mysql
aws backup list-backup-plans --query 'BackupPlansList[].[BackupPlanName,BackupPlanId]'   # امسح الـ plan + recovery points + vault لو عملتهم
```

الـ manual snapshots **بتعيش بعد** `terraform destroy` وبتتحاسب — راجع `describe-db-snapshots --snapshot-type manual` في الـ regions الاتنين ([97](97-cost-and-teardown.md)).

## 11) التكلفة (Cost)

| Resource | السعر التقريبي (us-east-1 — تقريبي، راجع صفحة الأسعار) |
|---|---|
| RDS automated backup storage | مجاني لحد 100% من الـ provisioned storage في الـ region |
| Manual snapshots / storage زيادة | ~$0.095/GB-month |
| Cross-region copy / replication | data transfer ~$0.02/GB + storage في الـ destination |
| PITR instance للـ drill | `db.t4g.micro` ~$0.016/ساعة + storage (امسحه بعد الـ drill) |
| S3 dumps | ~$0.023/GB-month (dump مضغوط للمعمل = KBs–MBs) |
| AWS Backup | storage لكل GB (قريب من أسعار الـ snapshots) + cross-region transfer |
| KMS CMK (للـ cross-region/cross-account) | ~$1/key/month |

## 12) أسئلة Interview

<details><summary>RTO و RPO — مين بيحددهم وإزاي بيأثروا على التصميم؟</summary>

الـ business (كام ساعة down مقبولة، كام داتا ممكن تضيع) — مش الـ engineering. RPO صغير = backups/replication أكتر تكراراً (PITR، replicas)؛ RTO صغير = حاجات جاهزة/شغالة مسبقاً (pilot light/warm standby) و automation. كل تخفيض = تكلفة أعلى، فالقرار trade-off بالأرقام.

</details>

<details><summary>Multi-AZ مش كفاية كـ backup؟</summary>

لأ. Multi-AZ = synchronous standby للـ HA (failover لو AZ/instance وقع). أي `DELETE`/`DROP`/corruption/ransomware بيتنسخ فوراً. الـ backup لازم يبقى منفصل ومتأخر زمنياً (PITR، snapshots) ويفضل في account/region تاني و immutable.

</details>

<details><summary>إزاي تعمل backup متسق لـ MySQL من غير downtime؟</summary>

`mysqldump --single-transaction` بيفتح transaction بـ consistent snapshot (InnoDB MVCC) فالـ dump متسق من غير locks على الجداول — بشرط مفيش DDL أثناءه وكل الجداول InnoDB. للداتا الكبيرة: physical backups (Percona XtraBackup) أو RDS snapshots + binlogs للـ PITR.

</details>

<details><summary>الـ RDS PITR بيعمل instance جديد — إزاي التطبيق يوصله؟</summary>

endpoint جديد = لازم تحدّث config (`DB_HOST` في SSM) وتعمل restart/refresh للـ app لأن الـ env بيتقري وقت البداية. البدائل: rename الـ instances عشان الـ endpoint الأصلي يرجع (الـ DNS بيتبع الاسم)، CNAME خاص بيك في Route 53 private zone بتغيّره، أو RDS Proxy. ولو Terraform بيملك الـ instance/الـ params لازم تصالح الـ state بعدها.

</details>

<details><summary>إيه اللي بيتنسى في DR plan غير الداتا؟</summary>

الـ container images (ECR replication)، الـ secrets/config (SSM مش بيتنسخ؛ و `APP_KEY` لازم يبقى هو هو)، الـ Terraform state، الـ DNS failover، الـ quotas في الـ region التاني، الـ IAM/الـ access للناس، والـ runbook متجرّب. وأهم حاجة: drill دوري بيقيس الـ RTO الحقيقي.

</details>

<details><summary>إزاي تحمي الـ backups من ransomware أو admin مخترق؟</summary>

Immutable: S3 Object Lock (compliance/governance) أو AWS Backup Vault Lock؛ copy لـ account منفصل (backup account) بـ IAM مختلف؛ least privilege (الـ host يقدر `PutObject` بس — مش `Delete`/`PutLifecycle`)؛ versioning؛ MFA delete؛ و alarms على أي تغيير في الـ backup policies.

</details>

## 13) Checklist

- [ ] حددت RTO/RPO للمعمل وكتبتهم
- [ ] عملت backup بالسكريبت وrestore في scratch DB وسجّلت الأوقات والـ counts
- [ ] عملت RDS PITR (Console أو CLI) وحوّلت التطبيق للـ endpoint الجديد وقست الـ RTO
- [ ] عملت snapshot و cross-region copy (أو replication)
- [ ] فهمت `skip_final_snapshot` و `delete_automated_backups` (module input، default `true`) وإمتى تقفلهم الاتنين
- [ ] قارنت استراتيجيات الـ DR الـ 4 لتطبيقنا
- [ ] مسحت الـ PITR instance والـ snapshots في الـ regions الاتنين
