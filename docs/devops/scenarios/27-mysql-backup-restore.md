# 27 — Backup لـ MySQL على S3 + تجربة restore

> **الهدف في سطر:** تعمل backup يومي متسق لـ MySQL container بـ `mysqldump --single-transaction` → gzip → S3 (مشفّر، retention بالـ lifecycle)، تجدوله بـ **systemd timer** من الـ role `mysql_backup`، وتعمل **restore drill** حقيقي تقيس فيه الـ **RPO** والـ **RTO** — لأن الـ backup اللي عمرك ما رجّعته هو أمل، مش backup.
> **المستوى:** Intermediate · **الوقت:** ~2–3 ساعات · **التكلفة التقريبية:** سنتات (S3) فوق تكلفة [20](20-ec2-compose-console.md)/[21](21-ec2-compose-terraform-ansible.md)
> **بيعتمد على:** [21 — Terraform + Ansible](21-ec2-compose-terraform-ansible.md) (أو [20](20-ec2-compose-console.md)) · **الملفات في الـ repo:** [`deploy/ec2/backup-mysql-to-s3.sh`](../../../deploy/ec2/backup-mysql-to-s3.sh) · [`infra/ansible/playbooks/backup.yml`](../../../infra/ansible/playbooks/backup.yml) · [`infra/ansible/roles/mysql_backup/`](../../../infra/ansible/roles/mysql_backup/) ([`defaults`](../../../infra/ansible/roles/mysql_backup/defaults/main.yml) · [`tasks`](../../../infra/ansible/roles/mysql_backup/tasks/main.yml) · [`backup.service.j2`](../../../infra/ansible/roles/mysql_backup/templates/backup.service.j2) · [`backup.timer.j2`](../../../infra/ansible/roles/mysql_backup/templates/backup.timer.j2)) · [`infra/terraform/stacks/20-ec2-single/main.tf`](../../../infra/terraform/stacks/20-ec2-single/main.tf) (backups bucket) · [`iam.tf`](../../../infra/terraform/stacks/20-ec2-single/iam.tf)

## 1) الفكرة (Concepts)

الـ MySQL في سيناريوهات 20–27 container على نفس الـ EC2، والداتا في volume على الـ root EBS. لو الـ instance اتعمله terminate، أو حد عمل `DROP TABLE`، أو migration بوّظت الداتا، أو `docker volume rm` بالغلط → **الداتا راحت**. الحل: نسخة **برّه** الـ host، متسقة، مشفّرة، بـ retention محدد، و**متجرّبة**.

| المصطلح | المعنى |
|---|---|
| **RPO** (Recovery Point Objective) | أقصى داتا مسموح تخسرها (بالوقت). backup يومي = RPO لحد 24 ساعة |
| **RTO** (Recovery Time Objective) | أقصى وقت مسموح لحد ما الخدمة ترجع. بيتقاس من بداية الـ restore لحد `/ready` = 200 بالداتا الصح |
| Logical backup | SQL statements (`mysqldump`) — portable، بطيء في الـ restore للداتا الكبيرة |
| Physical backup | نسخ ملفات الـ data dir (Percona XtraBackup، EBS snapshot، RDS snapshot) — أسرع بكتير للكبير |
| `--single-transaction` | `START TRANSACTION WITH CONSISTENT SNAPSHOT` → snapshot متسق لكل جداول **InnoDB** من غير locks على الكتابة (MVCC) |
| PITR | Point-in-time recovery = backup + binlogs (RDS بيعملها لوحده — [41](41-rds-mysql.md)) |
| 3-2-1 | 3 نسخ، على نوعين storage، واحدة منهم offsite/حساب تاني |

| القرار | اخترنا | البديل | ليه |
|---|---|---|---|
| النوع | `mysqldump` logical | XtraBackup / EBS snapshot | الداتا صغيرة، portable لأي MySQL (حتى RDS في [41](41-rds-mysql.md))، ومفيش أدوات زيادة |
| النقل | stream: `mysqldump \| gzip \| aws s3 cp -` | ملف على الـ disk ثم upload | مفيش مساحة disk مطلوبة، ومفيش dump plaintext بيقعد على الـ host |
| الجدولة | systemd timer | cron | logs في journald، `Persistent=true` (يعوّض لو السيرفر كان واقف)، `Type=oneshot` بيفشل بوضوح، و Nice/IO idle |
| الـ retention | S3 lifecycle (30 يوم) | السكريبت يمسح القديم | السكريبت ممكن يفشل أو يتمسح؛ الـ bucket هو اللي بيضمن |
| التشفير | SSE-S3 (AES256) + TLS-only policy | SSE-KMS CMK | مجاني؛ الـ CMK لما تحتاج key policy منفصلة و audit لكل decrypt |

## 2) المعمارية (Architecture)

```text
 EC2 (stack 20)                                              S3 student-app-lab-backups-<acct>
 ──────────────                                              ─────────────────────────────────
 systemd: student-app-mysql-backup.timer                     Block public access · BucketOwnerEnforced
   OnCalendar=*-*-* 03:00:00 Africa/Cairo · Persistent=true  SSE-S3 default + --sse AES256 لكل object
        │                                                     policy: Deny s3:* if aws:SecureTransport=false
        ▼                                                     lifecycle expire-dumps: 30 days (backup_retention_days)
 student-app-mysql-backup.service (Type=oneshot, Nice=10,             ▲
   IOSchedulingClass=idle, TimeoutStartSec=1h)                         │ PutObject (instance role:
   ExecStart=/opt/student-app/backup-mysql-to-s3.sh                    │  s3:ListBucket + Get/PutObject)
        │                                                              │
        ▼                                                              │
 docker compose exec -T mysql mysqldump --single-transaction --quick \ │
     --routines --triggers -uroot student_app  ── gzip -9 ── aws s3 cp - s3://.../mysql/student_app-<UTC>.sql.gz.partial
     نجح؟ ── aws s3 mv <key>.partial → <key>   ·   فشل؟ ── aws s3 rm <key>.partial + exit 1

 Restore drill (backup.yml -e backup_restore_drill=true):
   newest key ── aws s3 cp - ── gunzip ── mysql student_app_restore_drill ── compare rows ── DROP scratch DB
```

## 3) المتطلبات (Prerequisites)

- [ ] الـ host شغال والتطبيق عليه داتا ([21](21-ec2-compose-terraform-ansible.md): `deploy.yml` + seed).
- [ ] اسم الـ bucket: `terraform -chdir=infra/terraform/stacks/20-ec2-single output -raw backup_bucket`.
- [ ] Ansible جاهز و `ANSIBLE_EXTRA="-e ssm_bucket_name=..."` ([21 §5.8](21-ec2-compose-terraform-ansible.md)).
- لو جاي من [20](20-ec2-compose-console.md) (Console، من غير Terraform): الـ bucket والـ IAM مش موجودين — اعملهم في §4.

## 4) الطريقة الأولى: AWS Console (يدوي)

### 4.1 الـ bucket (لو مفيش stack 20)

1. **S3 → Create bucket** → Name `student-app-lab-backups-<ACCOUNT_ID>` · Region us-east-1 · Object Ownership **ACLs disabled** · ✅ **Block all public access** · Default encryption **SSE-S3** · Tags `Project=student-app`، `Env=lab`، `ManagedBy=console`، `Scenario=27` → Create.
2. الـ bucket → **Management → Create lifecycle rule** → Name `expire-dumps` · Apply to all objects · ✅ Expire current versions **30** days · ✅ Delete expired object delete markers or incomplete multipart uploads → incomplete multipart **1** day → Create.
3. **Permissions → Bucket policy → Edit**:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "DenyInsecureTransport",
    "Effect": "Deny",
    "Principal": "*",
    "Action": "s3:*",
    "Resource": ["arn:aws:s3:::student-app-lab-backups-<ACCOUNT_ID>", "arn:aws:s3:::student-app-lab-backups-<ACCOUNT_ID>/*"],
    "Condition": { "Bool": { "aws:SecureTransport": "false" } }
  }]
}
```

4. **IAM → Roles → `student-app-lab-ec2-role`** (بتاع 20) → **Add permissions → Create inline policy → JSON** → اسم `student-app-lab-backups`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "BackupsList", "Effect": "Allow", "Action": "s3:ListBucket", "Resource": "arn:aws:s3:::student-app-lab-backups-<ACCOUNT_ID>" },
    { "Sid": "BackupsReadWrite", "Effect": "Allow", "Action": ["s3:GetObject", "s3:PutObject"], "Resource": "arn:aws:s3:::student-app-lab-backups-<ACCOUNT_ID>/*" },
    { "Sid": "BackupsCleanupPartialUploads", "Effect": "Allow", "Action": "s3:DeleteObject", "Resource": "arn:aws:s3:::student-app-lab-backups-<ACCOUNT_ID>/mysql/*.partial" }
  ]
}
```

> 💡 الـ `s3:DeleteObject` مسموح على `mysql/*.partial` **بس** (السكريبت بيعمل `s3 mv` من الـ `.partial` للـ key النهائي = copy + delete، و `s3 rm` للـ `.partial` لو فشل). الـ dumps الكاملة نفسها مايقدرش يمسحها: لو السيرفر اتخترق، المهاجم يقدر يرفع ملفات بس مايمسحش الـ backups — المسح شغلة الـ lifecycle. ده مبدأ مهم ضد الـ ransomware (الـ IAM بيقبل wildcards جوه الـ key، فتقدر تحدد بالـ suffix). ثغرة باقية: `PutObject` على نفس الـ key بيكتب فوقه والـ bucket مش versioned — الـ keys فيها timestamp فالخطر أقل، والحل الكامل Versioning + Object Lock.

### 4.2 backup يدوي من Session Manager

```bash
sudo -i
cd /opt/student-app
# لو جاي من 20 الملفات في src/: السكريبت بيستخدم /opt/student-app/docker-compose.prod.yml افتراضياً
BACKUP_BUCKET=student-app-lab-backups-<ACCOUNT_ID> COMPOSE_FILE=/opt/student-app/src/docker-compose.prod.yml \
  bash /opt/student-app/src/deploy/ec2/backup-mysql-to-s3.sh
# ✔ s3://student-app-lab-backups-<ACCOUNT_ID>/mysql/student_app-2026-11-21T1015.sql.gz (3s)
```

### 4.3 شوف النتيجة في الـ Console

**S3 → الـ bucket → `mysql/`** → الـ object → **Properties → Server-side encryption = SSE-S3**. جرّب **Open**: بيتنزل `.sql.gz` (ده ليه الـ IAM مقفول: الـ dump فيه كل الداتا).

## 5) الطريقة التانية: Infrastructure as Code (Terraform + Ansible)

### 5.1 Terraform (موجود في stack 20 من [21](21-ec2-compose-terraform-ansible.md))

- `aws_s3_bucket.backups` → `${project}-${env}-backups-${account_id}` (الـ account ID في الاسم لأن أسماء الـ buckets global).
- `aws_s3_bucket_lifecycle_configuration.backups` → `expiration { days = var.backup_retention_days }` (30) + abort multipart بعد يوم.
- SSE-S3 default، public access block، `BucketOwnerEnforced`، policy `DenyInsecureTransport`.
- `force_destroy = var.backup_bucket_force_destroy` (**`true`** افتراضياً: الـ stack مؤقت → الـ dumps بتتمسح مع `terraform destroy`!).
- الـ instance role: `BackupsList` (`s3:ListBucket` على الـ bucket) + `BackupsReadWrite` (`s3:GetObject`/`PutObject` على `bucket/*`) + **`BackupsCleanupPartialUploads`** (`s3:DeleteObject` على `bucket/mysql/*.partial` **بس**) — ده اللي بيخلّي `s3 mv` (copy + delete) و `s3 rm` بتوع السكريبت يشتغلوا، والـ dumps الكاملة (`*.sql.gz`) تفضل مايتمسحش من الـ host.

### 5.2 السكريبت سطر بسطر ([`backup-mysql-to-s3.sh`](../../../deploy/ec2/backup-mysql-to-s3.sh))

| الجزء | ليه |
|---|---|
| `set -euo pipefail` | **`pipefail` أهم سطر:** من غيره فشل `mysqldump` في أول الـ pipe كان هيتخبّى ورا نجاح `aws s3 cp` |
| `COMPOSE_FILE` (افتراضي `/opt/student-app/docker-compose.prod.yml`) + `APP_ENV_FILE`/`MYSQL_ENV_FILE` | `compose exec` محتاج نفس الـ project (`student-app`) عشان يلاقي الـ container — شغال مع Recreate stack ومع lb stack ([23](23-bluegreen-single-host.md)) لأنهم نفس الـ project والـ service |
| `exec -T mysql sh -c "mysqldump ... -p\"\$MYSQL_ROOT_PASSWORD\" ..."` | الـ `\$` بيخلي المتغير يتفك **جوه الـ container** (من `mysql.env`)؛ الباسورد مبيعدّيش على الـ host ولا بيظهر في `ps` بتاع الـ host. `-T` = من غير TTY (لازم للـ pipes) |
| `--single-transaction` | snapshot متسق لـ InnoDB من غير ما يقفل الكتابة. **مش** بيحمي جداول MyISAM ولا DDL أثناء الـ dump |
| `--quick` | row-by-row بدل ما يحمّل الجدول كله في الـ RAM |
| `--routines --triggers` | الـ stored procedures والـ triggers (الـ triggers default أصلاً، الـ routines لأ) |
| `gzip -9` | SQL بيتضغط ~5–10× |
| `aws s3 cp - "s3://$BUCKET/$KEY.partial"` | upload من stdin (multipart تلقائي) لـ key مؤقت |
| `if …; then aws s3 mv $KEY.partial $KEY; else aws s3 rm $KEY.partial; exit 1; fi` | **الـ dump الناقص عمره ما يظهر بالاسم النهائي**: لو `mysqldump` مات في النص (pipefail)، الـ `.partial` بيتمسح ومفيش حاجة بتتنشر؛ لو نجح، `mv` (copy + delete) بينشره. يعني "أحدث `.sql.gz`" دايماً dump كامل |
| `--sse AES256` | تشفير صريح لكل object (حتى لو حد غيّر الـ default encryption) |
| `KEY=mysql/<db>-<UTC>.sql.gz` | بالـ UTC: مفيش تضارب مع الـ DST، والترتيب الأبجدي = ترتيب زمني |
| `restore s3://...` | `aws s3 cp - \| gunzip \| mysql <DB>` — بيكتب **فوق** الجداول الموجودة في الـ dump (`DROP TABLE IF EXISTS` جزء من `--opt` الافتراضي) |

### 5.3 الـ role `mysql_backup` والـ playbook

| Variable | الافتراضي | |
|---|---|---|
| `mysql_backup_bucket` | `{{ backup_bucket }}` | لازم (الـ role بيعمل assert) |
| `mysql_backup_db_name` | `student_app` | |
| `mysql_backup_on_calendar` | `*-*-* 03:00:00 Africa/Cairo` | بالـ timezone صريحة: صح حتى لو timezone الـ host اتغيّرت |
| `mysql_backup_unit` | `student-app-mysql-backup` | |

الـ service (`Type=oneshot`، `After=network-online.target docker.service`، `Requires=docker.service`، `Nice=10`، `IOSchedulingClass=idle`، `TimeoutStartSec=1h`) والـ timer (`Persistent=true` → لو الـ instance كانت stopped الساعة 3، الـ backup بيجري أول ما تقوم).

[`backup.yml`](../../../infra/ansible/playbooks/backup.yml) بيعمل: `app` role `files` (compose + scripts) → `mysql_backup` (script + units + enable timer) → **`systemctl start` للـ service** (نفس الكود اللي الـ timer بيشغّله — code path واحد) → يجيب أحدث key → (اختياري) restore drill في scratch DB.

## 6) الـ Deploy

```bash
cd ~/src/StudentHub/infra/ansible && source ~/.venvs/ansible/bin/activate
BUCKET=$(terraform -chdir=../terraform/stacks/20-ec2-single output -raw backup_bucket)
ansible-playbook playbooks/backup.yml -e backup_bucket=$BUCKET $ANSIBLE_EXTRA
# TASK [Report the backup] → "latest dump: s3://student-app-lab-backups-<acct>/mysql/student_app-2026-11-21T1015.sql.gz"
```

على السيرفر (Session Manager):

```bash
systemctl list-timers student-app-mysql-backup.timer          # NEXT = 03:00 بتوقيت القاهرة
systemctl cat student-app-mysql-backup.service
sudo systemctl start student-app-mysql-backup.service          # backup دلوقتي (blocking لحد ما يخلص)
journalctl -u student-app-mysql-backup.service -n 20 --no-pager
```

## 7) التحقق (Verify) والـ Restore drill

### 7.1 الـ dump سليم؟

```bash
B=$BUCKET
aws s3 ls s3://$B/mysql/ --human-readable
LATEST=$(aws s3api list-objects-v2 --bucket "$B" --prefix mysql/ --query "sort_by(Contents[?ends_with(Key, '.sql.gz')], &LastModified)[-1].Key" --output text)
aws s3api head-object --bucket "$B" --key "$LATEST" --query '{size:ContentLength,sse:ServerSideEncryption,at:LastModified}'
aws s3 cp "s3://$B/$LATEST" - | gunzip -t && echo "gzip OK"
aws s3 cp "s3://$B/$LATEST" - | gunzip | tail -1          # -- Dump completed on 2026-11-21 10:15:03   ← الدليل إن الـ dump كامل
aws s3 cp "s3://$B/$LATEST" - | gunzip | grep -c '^CREATE TABLE'
aws s3api get-bucket-lifecycle-configuration --bucket "$B"
```

> 💡 **ليه `.partial` + `tail -1`؟** لو `mysqldump` اتقطع في النص، `gzip` بيقفل الـ stream بشكل سليم و`aws s3 cp` بيرفع ملف **صالح بس ناقص**. عشان كده السكريبت بيرفع على `<key>.partial` وبينقله للاسم النهائي بس لو الـ pipeline كله نجح. السطر `-- Dump completed on ...` تأكيد تاني مستقل (defense in depth)، و `.partial` موجود = backup لسه شغال (أو انقطع قبل الـ cleanup) — عشان كده كل "latest" query (الأوامر فوق والـ playbook) بتفلتر على `*.sql.gz` بس. الخطوة الجاية في production: manifest/checksum لكل dump.

### 7.2 Restore drill آمن (scratch DB) — بالـ playbook

```bash
ansible-playbook playbooks/backup.yml -e backup_bucket=$BUCKET -e backup_restore_drill=true $ANSIBLE_EXTRA
# "Restore drill passed in 4.2s (migrations rows live/restored = 11/11)"
```

> 💡 الـ playbook بيجيب "الأحدث" بـ `sort_by(Contents[?ends_with(Key, '.sql.gz')], &LastModified)[-1].Key` → الـ `.partial` عمره ما بيترجّع، حتى لو فيه واحد متساب.

بيعمل: `CREATE DATABASE student_app_restore_drill` → `backup-mysql-to-s3.sh restore` بـ `DB_NAME=student_app_restore_drill` → يقارن `COUNT(*)` بتاع `migrations` في الاتنين → `DROP DATABASE` (في `always:` حتى لو فشل).

> 💡 نقطة senior: مقارنة `migrations` بس بتثبت إن الـ schema رجعت، مش إن الداتا كلها سليمة. في الشغل الحقيقي قارن جداول البيزنس (`students`، `subscriptions`، `users`) أو `CHECKSUM TABLE`، وشغّل smoke test للتطبيق على الـ restored DB.

### 7.3 Disaster drill كامل على الـ lab — قياس RPO و RTO

⚠️ **مدمّر:** بيمسح الـ volume. اعمله على lab بس، وبعد backup جديد ناجح.

**على السيرفر** (Session Manager، `sudo -i`):

```bash
cd /opt/student-app
export APP_ENV_FILE=/opt/student-app/app.env MYSQL_ENV_FILE=/opt/student-app/mysql.env APP_IMAGE="$(cat CURRENT_RELEASE)"
C="docker compose -f docker-compose.prod.yml"
B=student-app-lab-backups-<ACCOUNT_ID>

# 0) اعرف الـ baseline
$C exec -T mysql sh -c 'mysql -N -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT (SELECT COUNT(*) FROM student_app.students),(SELECT COUNT(*) FROM student_app.subscriptions)"'
systemctl start student-app-mysql-backup.service                     # T_backup
LAST_BACKUP=$(aws s3api list-objects-v2 --bucket $B --prefix mysql/ --query "sort_by(Contents[?ends_with(Key, '.sql.gz')], &LastModified)[-1].[Key,LastModified]" --output text); echo "$LAST_BACKUP"

# 1) داتا اتكتبت بعد الـ backup (دي اللي هتضيع = الـ RPO الفعلي) — ضيف طالب من الـ UI دلوقتي

# 2) الكارثة
date -u +%FT%TZ | tee /tmp/T_failure
$C stop app mysql && $C rm -f mysql
docker volume rm student-app_mysql-data

# 3) الـ recovery (ابدأ التايمر)
date +%s > /tmp/T0
$C up -d --wait mysql                                                # MySQL جديد فاضي (MYSQL_* من mysql.env بيعمل الـ DB والـ user)
KEY=$(aws s3api list-objects-v2 --bucket $B --prefix mysql/ --query "sort_by(Contents[?ends_with(Key, '.sql.gz')], &LastModified)[-1].Key" --output text)
BACKUP_BUCKET=$B /opt/student-app/backup-mysql-to-s3.sh restore "s3://$B/$KEY"
$C up -d --no-deps --wait app
until curl -fsS http://127.0.0.1/ready >/dev/null; do sleep 1; done
echo "RTO = $(( $(date +%s) - $(cat /tmp/T0) ))s"

# 4) تحقق
$C exec -T mysql sh -c 'mysql -N -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT (SELECT COUNT(*) FROM student_app.students),(SELECT COUNT(*) FROM student_app.subscriptions)"'
$C run --rm --no-deps app php artisan migrate:status | tail -3
```

**من جهازك** في نفس الوقت: `bash deploy/scripts/probe.sh http://<HOST>/ready 0 1` → بيقيس الـ downtime اللي المستخدم شافه (ده الـ RTO "من برّه"، أكبر من اللي فوق لأنه بيشمل وقت الاكتشاف).

**سجّل النتيجة** (ده الـ evidence اللي بيتسأل عليه في الـ interview والـ audit):

| البند | القيمة |
|---|---|
| آخر backup ناجح | `<LastModified>` |
| وقت الفشل | `$(cat /tmp/T_failure)` |
| **RPO الفعلي** | الفرق بينهم (+ الطالب اللي ضاع) — الأسوأ مع timer يومي ≈ 24 ساعة |
| **RTO الفعلي** | من `T0` لحد `/ready` = 200 |
| حجم الـ dump / وقت الـ restore | |
| مشاكل ظهرت | (مثلاً: نسيت `APP_IMAGE`، الـ sessions ضاعت فالمستخدمين اتعملهم logout) |

### 7.4 تقليل الـ RPO والـ RTO (قرارات معمارية)

| عايز | الحل | الثمن |
|---|---|---|
| RPO دقايق | backup كل ساعة (`OnCalendar=hourly`) أو binlog shipping | load و storage أكتر |
| RPO ثواني + PITR | RDS automated backups (PITR لحد ~5 دقايق) — [41](41-rds-mysql.md) | تكلفة RDS |
| RTO دقايق لداتا كبيرة | physical backups / EBS snapshots / RDS snapshot restore | تعقيد/تكلفة |
| ضد حذف الـ backups (ransomware) | S3 **Versioning + Object Lock** (compliance mode) + نسخة في حساب تاني | storage أكتر، ومينفعش تمسح قبل المدة |
| ضد سقوط region | S3 Cross-Region Replication — [77](77-backup-and-dr.md) | |

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر | المتوقع |
|---|---|---|
| مفيش صلاحية PutObject | IAM → شيل `BackupsReadWrite` من الـ role ثم `systemctl start ...service` | `journalctl` فيه `AccessDenied`، الـ unit = `failed`. **لاحظ:** مين هيعرف؟ محدش — اعمل alarm على فشل الـ unit (CloudWatch agent / metric filter على الـ journal) |
| MySQL واقف | `docker compose -f /opt/student-app/docker-compose.prod.yml stop mysql` ثم backup | `service "mysql" is not running` → unit failed (والـ app كمان `/ready` = 503) |
| bucket اسم غلط | `ansible-playbook playbooks/backup.yml -e backup_bucket=nope $ANSIBLE_EXTRA` | `NoSuchBucket`/`AccessDenied` من `aws s3 cp` |
| من غير bucket | `ansible-playbook playbooks/backup.yml $ANSIBLE_EXTRA` | الـ role assert: `Set backup_bucket (terraform ... output -raw backup_bucket)` |
| Dump ناقص | `docker compose ... exec mysql` واعمل `kill` لـ `mysqldump` في النص | `✘ backup FAILED — nothing published`، exit 1، والـ `.partial` اتمسح (`BackupsCleanupPartialUploads`) → آخر `.sql.gz` لسه الـ dump الكامل اللي قبله، والـ drill بيستخدمه |
| Restore في DB غلط | `DB_NAME=student_app backup-mysql-to-s3.sh restore <dump قديم>` | بيكتب فوق الداتا الحالية من غير سؤال — عشان كده الـ drill دايماً في scratch DB الأول |
| الـ instance كانت stopped الساعة 3 | stop قبل 3 و start بعدها | `Persistent=true` → الـ backup بيجري بعد الـ boot (`systemctl list-timers` → LAST) |

## 9) الرجوع (Rollback)

- **Restore بوّظ الداتا؟** رجّع من dump أقدم: `aws s3 ls s3://$B/mysql/` واختار الـ key، ونفس أمر الـ `restore`.
- **الـ backups نفسها اتمسحت؟** الـ bucket ده **مش versioned** → مفيش رجوع. في production: versioning + Object Lock + نسخة cross-account.
- **Migration بوّظت الداتا؟** الـ restore بيرجّع الـ schema القديمة كمان → لازم تعمل deploy للـ image القديمة (أو تعمل `migrate` تاني) عشان الكود والـ schema يتطابقوا.

## 10) المسح (Teardown) ⚠️

```bash
# لو عايز تحتفظ بآخر dump برّه الـ bucket (لأنه هيتمسح مع الـ stack: force_destroy = true)
aws s3 cp "s3://$B/$LATEST" ~/backups/
# وقّف الـ timer (لو الـ host هيفضل)
ansible role_app -b -m ansible.builtin.systemd_service -a 'name=student-app-mysql-backup.timer state=stopped enabled=false' $ANSIBLE_EXTRA
# مع الـ stack كله:
terraform -chdir=../terraform/stacks/20-ec2-single destroy
# لو عملت bucket بالـ Console (§4):
aws s3 rm "s3://student-app-lab-backups-<ACCOUNT_ID>" --recursive && aws s3 rb "s3://student-app-lab-backups-<ACCOUNT_ID>"
```

## 11) التكلفة (Cost)

| Resource | السعر التقريبي (us-east-1، تقريبي — راجع صفحة الأسعار) |
|---|---|
| S3 Standard storage | ~$0.023/GB/شهر — 30 dump × بضعة MB = أقل من سنت |
| PUT/GET requests | ~$0.005 لكل 1000 PUT — مهمل |
| Data transfer EC2 → S3 (نفس الـ region) | مجاني (وكمان عبر الـ S3 gateway endpoint) |
| CPU على الـ host | `Nice=10` + IO idle → أثر بسيط على الـ app |

## 12) أسئلة Interview

<details><summary>إيه الفرق بين RPO و RTO؟ وإزاي قستهم هنا؟</summary>

RPO = كمية الداتا (بالوقت) اللي تقدر تخسرها؛ بتتحدد بتكرار الـ backup/replication. RTO = الوقت لحد ما الخدمة ترجع؛ بيتحدد بسرعة الـ restore والأتمتة والاكتشاف. قستهم بـ drill: RPO = وقت الفشل − آخر backup ناجح، RTO = من بداية الـ recovery لحد `/ready` 200 بالداتا الصح، ومن برّه بـ `probe.sh`. والأرقام دي لازم تتقارن بالـ targets اللي البيزنس اتفق عليها، مش العكس.

</details>

<details><summary>`--single-transaction` بيعمل إيه بالظبط؟ وإمتى مبيكفيش؟</summary>

بيفتح transaction بـ consistent snapshot (REPEATABLE READ) فكل جداول InnoDB بتتقري من نفس اللحظة من غير ما تقفل الكتابة (MVCC). مبيكفيش لو فيه جداول MyISAM (محتاجة `--lock-tables`)، أو لو حصل DDL (`ALTER`/`TRUNCATE`) أثناء الـ dump (ممكن يكسر الـ snapshot)، وطبعاً مبيدّيش PITR — ده محتاج binlogs (`--source-data` + binlog shipping) أو RDS.

</details>

<details><summary>ليه الـ retention في الـ lifecycle مش في السكريبت؟ وليه الـ role مش عنده DeleteObject؟</summary>

السكريبت ممكن يفشل، يتعدّل غلط، أو يتمسح، والـ retention يتكسر بصمت (يا تتراكم تكلفة، يا تمسح أكتر من اللازم). الـ lifecycle policy declarative ومتطبّقة من S3 نفسه. ومنع `DeleteObject` عن الـ dumps الكاملة (مسموح على `*.partial` بس عشان الـ publish) = لو السيرفر اتخترق، المهاجم مايقدرش يمسح الـ backups (least privilege ضد ransomware). الخطوة الأقوى: Object Lock + حساب backup منفصل.

</details>

<details><summary>"عندنا backups يومية" — إيه أول سؤال تسأله؟</summary>

"إمتى آخر مرة عملتوا restore ناجح، وفي قد إيه؟" — backup من غير restore drill دوري (أوتوماتيكي يفضّل) = مجهول. وبعدها: الـ backups متسقة؟ مشفّرة؟ مين يقدر يمسحها؟ برّه الحساب/الـ region؟ فيه alert لو backup فشل؟ والـ RPO/RTO المتقاسة بتطابق الـ SLA؟

</details>

<details><summary>Logical ولا physical backup؟</summary>

Logical (`mysqldump`) portable بين versions و engines وسهل تعمل منه restore جزئي، بس بطيء جداً في الـ restore للداتا الكبيرة (بيعيد بناء الـ indexes) وتقيل على الـ CPU. Physical (XtraBackup، snapshots) أسرع بكتير للـ GBs/TBs ويدعم incremental، بس مربوط بنفس الـ version/engine. الشائع: physical/snapshots للـ DR السريع + logical دوري للـ portability والـ restore الجزئي.

</details>

<details><summary>إزاي تتأكد إن الـ backup مش ناقص أو فاسد؟</summary>

exit code للـ pipeline كله (`pipefail`)، `gunzip -t`، السطر الأخير `-- Dump completed`، حجم معقول مقارنة بالأيام اللي قبله (alert لو قلّ فجأة)، checksum متسجّل، وأهم حاجة restore drill دوري يقارن counts/checksums ويشغّل smoke test. وفي الكتابة: upload لـ key مؤقت (`.partial`) ثم `mv` بعد النجاح — اللي السكريبت بيعمله — عشان "الأحدث" يبقى دايماً كامل.

</details>

## 13) Checklist

- [ ] الـ bucket فيه SSE + TLS-only + lifecycle 30 يوم، والـ role مفيهوش DeleteObject غير على `mysql/*.partial`
- [ ] `backup.yml` نصّب الـ timer وعمل backup، و `systemctl list-timers` بيوري 03:00
- [ ] اتأكدت من الـ dump (`gunzip -t` + `Dump completed`)
- [ ] عملت الـ drill الآمن (scratch DB) ونجح
- [ ] عملت الـ disaster drill وسجّلت RPO و RTO الفعليين
- [ ] جرّبت الـ break-it (AccessDenied، mysql واقف، dump ناقص)
- [ ] قريت [77](77-backup-and-dr.md) للـ RDS/PITR/cross-region
