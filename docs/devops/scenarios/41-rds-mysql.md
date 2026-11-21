# 41 — RDS MySQL + نقل الداتا من الـ container

> **الهدف في سطر:** تطلّع الداتابيز من جوه الـ box لـ **RDS MySQL 8.4** (private، encrypted، backups + PITR)، تفهم كل قرار في [`modules/rds-mysql`](../../../infra/terraform/modules/rds-mysql/main.tf) (subnet group، سلسلة الـ SGs، parameter group بـ utf8mb4، Multi-AZ، deletion protection والـ final snapshot)، تنقل الداتا من الـ MySQL container بـ `mysqldump` عن طريق **Session Manager** من غير bastion، وتغيّر `DB_HOST` وانت عارف حدود "zero downtime" في نقل الداتابيز.
> **المستوى:** Intermediate → Advanced · **الوقت:** ~3–4 ساعات · **التكلفة التقريبية:** ~$0.5/يوم (`db.t4g.micro` + 20 GiB gp3 — تقريبي، راجع صفحة الأسعار)
> **بيعتمد على:** [40 — VPC من الصفر](40-vpc-from-scratch.md) · [20](20-ec2-compose-console.md) · [27 — Backup لـ MySQL](27-mysql-backup-restore.md) · **الملفات في الـ repo:** [`modules/rds-mysql/main.tf`](../../../infra/terraform/modules/rds-mysql/main.tf) · [`modules/rds-mysql/variables.tf`](../../../infra/terraform/modules/rds-mysql/variables.tf) · [`modules/rds-mysql/outputs.tf`](../../../infra/terraform/modules/rds-mysql/outputs.tf) · [`stacks/40-ec2-alb-asg/main.tf`](../../../infra/terraform/stacks/40-ec2-alb-asg/main.tf) · [`deploy/ec2/backup-mysql-to-s3.sh`](../../../deploy/ec2/backup-mysql-to-s3.sh) · [`docker-compose.prod.yml`](../../../docker-compose.prod.yml)

## 1) الفكرة (Concepts)

الـ MySQL container على نفس السيرفر (20–27) معناه: السيرفر يقع = الداتابيز تقع، الـ backup مسؤوليتك ([27](27-mysql-backup-restore.md))، ومينفعش تزوّد app servers لأن الداتا محبوسة في volume على box واحد. **RDS** بياخد منك: الـ patching، الـ backups الأوتوماتيك + **PITR**، الـ Multi-AZ failover، الـ monitoring، والـ storage autoscaling. وبيسيبلك: الـ schema، الـ queries، الـ sizing، والـ connection management.

| المصطلح | المعنى |
|---|---|
| DB subnet group | الـ subnets اللي RDS يقدر يحط فيها الـ instance (لازم **2 AZ** على الأقل حتى لو Single-AZ) |
| Parameter group | إعدادات الـ engine (`my.cnf`). الـ default مش بيتعدّل؛ بتعمل custom |
| Automated backups | snapshot يومي + transaction logs → **PITR** لأي ثانية في الـ retention (هنا 7 أيام) |
| PITR | restore لـ **instance جديد** (endpoint جديد) في لحظة معينة — مش "undo" على نفس الـ instance |
| Multi-AZ DB instance | standby **synchronous** في AZ تانية، مش بيخدم reads؛ الـ failover = DNS flip (~1–2 دقيقة) |
| Multi-AZ DB cluster | writer + 2 readable standbys (أغلى، failover أسرع) |
| Read replica | async، للـ reads/scale — **مش** HA بديل للـ Multi-AZ |
| Deletion protection | الـ API يرفض الـ delete لحد ما تقفلها |
| Final snapshot | snapshot بيتعمل وقت الـ delete (بيعيش بعد الـ instance وبيتحاسب) |

### قرارات الـ module (ليه كده؟)

| القرار في [`main.tf`](../../../infra/terraform/modules/rds-mysql/main.tf) | ليه |
|---|---|
| `publicly_accessible = false` + private subnets | الداتابيز ملهاش أي طريق من الإنترنت |
| SG بـ ingress 3306 من SG الـ app بس، **ومن غير egress** | الداتابيز عمرها ما بتبدأ connection؛ و "من SG" بدل CIDR يفضل صح مهما الـ IPs اتغيرت |
| `storage_encrypted = true` (مفتاح `aws/rds`) | ببلاش، و**مينفعش تضيفه بعدين** (لازم snapshot → copy encrypted → restore) |
| `engine_version = "8.4"` + `auto_minor_version_upgrade = true` | prefix major.minor: RDS يختار آخر patch ويرقّي الـ minors في الـ maintenance window |
| parameter group: `utf8mb4` / `utf8mb4_unicode_ci` + `slow_query_log=1` + `long_query_time=1` | نفس charset الـ container (`--character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci` في `docker-compose.prod.yml`) عشان النقل ميغيّرش الـ collation، والـ slow log هيلزمنا في [49](49-redis-sessions-cache.md) |
| `name_prefix` + `create_before_destroy` على الـ parameter group | لو غيّرت الـ family (8.4 → 9.x) الـ group الجديد يتعمل قبل ما القديم (المربوط بالـ instance) يتمسح |
| log groups `/aws/rds/instance/<id>/{error,slowquery}` بـ retention 7 أيام | RDS بيعملهم "never expire" لو سبته |
| `backup_retention_period = 7`، window `03:00-03:30` UTC، maintenance `sun:04:00-04:30` | PITR أسبوع؛ الـ backup قبل الـ maintenance |
| password: `random_password` 32 حرف **alphanumeric بس** | القيمة بتعدّي على `--env-file` و shells و URLs؛ `$ # " ' / @` بتكسر حاجات. 32 حرف ≈ 190 bit |
| `require_secure_transport` **مقفول** | الـ mysql driver بتاع Laravel مش بيستخدم TLS إلا لو `MYSQL_ATTR_SSL_CA` متحدد — hardening في [81](81-secrets-management.md) |
| `deletion_protection = false`، `skip_final_snapshot = true`، `delete_automated_backups = true` | **defaults للـ lab** عشان `terraform destroy` يشتغل ومفيش snapshots يتيمة. في production: العكس (شوف §1.1) |
| `final_snapshot_identifier` بـ `random_id` suffix | اسم الـ final snapshot لازم يبقى unique في الحساب؛ الـ lab بيتعمل ويتمسح كتير |

### 1.1 Deletion protection والـ final snapshot — الـ trade-off

| الإعداد | Lab (الـ default) | Production |
|---|---|---|
| `db_deletion_protection` | `false` | `true` — `terraform destroy` أو typo في الـ code مش هيمسح الـ prod |
| `db_skip_final_snapshot` | `true` | `false` — آخر نسخة قبل المسح |
| `delete_automated_backups` (module) | `true` | فكّر تخليه `false`: الـ automated backups تفضل للـ retention بعد المسح (PITR بعد كارثة "اتمسح بالغلط") |
| السعر | ولا مليم بعد الـ destroy | الـ snapshot بيتحاسب لحد ما تمسحه |

### 1.2 الـ SSM parameters اللي الـ module بيكتبها

الـ module بيكتب في `ssm_prefix` (= `/student-app/lab/app` من stack 40) — **مصدر حقيقة واحد** يقراه الـ EC2 user data و ECS و External Secrets:

| Parameter | النوع | القيمة |
|---|---|---|
| `/student-app/lab/app/DB_HOST` | String | `aws_db_instance.this.address` |
| `/student-app/lab/app/DB_PORT` | String | `3306` |
| `/student-app/lab/app/DB_DATABASE` | String | `student_app` |
| `/student-app/lab/app/DB_USERNAME` | String | `student` (الـ master user — lab shortcut؛ production = user بصلاحيات أقل) |
| `/student-app/lab/app/DB_PASSWORD` | SecureString | الـ random password (**مش** بيتكتب لو `use_secrets_manager = true`) |

### 1.3 `use_secrets_manager`

`use_secrets_manager = true` → `manage_master_user_password = true`: RDS نفسه بيملك الباسورد في **Secrets Manager** مع rotation كل 7 أيام، والباسورد **مبيدخلش الـ Terraform state** خالص، و `DB_PASSWORD` **مبيتكتبش** في SSM (الـ output `master_user_secret_arn` بيدّيك الـ secret).

⚠️ الـ variable ده موجود في الـ **module** بس، و stack 40 **مش بيعرّضه** — ولو فعّلته، الـ user data في [`user-data.sh.tftpl`](../../../infra/terraform/modules/asg-app/user-data.sh.tftpl) بيقرا `app.env` من SSM بس، فالـ app هيقوم من غير `DB_PASSWORD`. التفعيل محتاج تعديل في الـ boot script (يقرا `secretsmanager get-secret-value` ويكتب `DB_PASSWORD`) + صلاحية `secretsmanager:GetSecretValue` للـ instance role. ECS أسهل: `valueFrom "<secret_arn>:password::"` ([81](81-secrets-management.md)).

## 2) المعمارية (Architecture)

```text
 قبل (20–27)                                   بعد (41+)
 ┌─ EC2 ─────────────────────────┐            ┌─ VPC 10.20.0.0/16 ──────────────────────────────────┐
 │ app ──► mysql:8.4 (volume)    │   dump     │ public:  ALB ─► app instances (SG student-app-lab-app)│
 │         └─ mysqldump ─────────┼──► .sql.gz │                     │ 3306 (egress → VPC CIDR)        │
 └───────────────────────────────┘     │      │ private: RDS student-app-lab-mysql                    │
                                       │      │          SG student-app-lab-rds: in 3306 ◄ app SG     │
                                       │      │          (no egress) · gp3 encrypted · PITR 7d        │
                                       │      │          param group mysql8.4: utf8mb4, slow log       │
                                       ▼      └───────────────────────▲─────────────────────────────┘
 laptop/WSL ── aws ssm start-session ── AWS-StartPortForwardingSessionToRemoteHost
              localhost:13306 ─────────► app instance (SSM agent) ─────► RDS:3306      (من غير bastion)

 SSM /student-app/lab/app/{DB_HOST,DB_PORT,DB_DATABASE,DB_USERNAME,DB_PASSWORD} ◄── modules/rds-mysql
```

## 3) المتطلبات (Prerequisites)

- [ ] [40](40-vpc-from-scratch.md) مفهوم، و `backend.hcl` جاهز.
- [ ] host من [20](20-ec2-compose-console.md) شغال بالداتا (للـ Console path) **أو** dump موجود من [27](27-mysql-backup-restore.md).
- [ ] على WSL: `session-manager-plugin` (شوف [`infra/ansible/README.md`](../../../infra/ansible/README.md#1-install-wsl2-ubuntu)) و `mysql-client` (`sudo apt-get install -y mysql-client`).
- الأدوات: `aws` · `terraform` · `jq` · `gzip`.

## 4) الطريقة الأولى: AWS Console (يدوي) — نقل الـ host بتاع 20 لـ RDS

الطريق الأقصر للتعلم: تعمل RDS في **نفس VPC بتاع host سيناريو 20**، تنقل الداتا عليه مباشرة، وتغيّر `DB_HOST`. (لو الـ host من stack 20 بالـ Terraform: الـ SG بتاعه بيسمح بـ egress على 80/443 بس، والـ RDS wizard هيضيفله SG جديد للـ 3306 → ده drift هيتشال في أول `terraform apply` لـ stack 20. الأفضل تجرّب على host الـ console.)

### 4.1 الـ Parameter group

1. **RDS → Parameter groups → Create parameter group**.
2. Engine type: **MySQL Community** · Parameter group family: **mysql8.4** · Type: **DB Parameter Group** · Name: `student-app-lab-mysql84` · Description: `utf8mb4 + slow log` → **Create**.
3. افتحه → **Edit** → دوّر وعدّل: `character_set_server` = `utf8mb4` · `collation_server` = `utf8mb4_unicode_ci` · `slow_query_log` = `1` · `long_query_time` = `1` → **Save changes**.

### 4.2 الـ Database

1. **RDS → Databases → Create database** → **Standard create** (أو Full configuration) → **MySQL** → Engine version: آخر **8.4.x**.
2. **Templates**: Dev/Test (أو Free tier / Sandbox حسب اللي ظاهر في حسابك). لاحظ إن **Production** بيختار Multi-AZ و io1 و deletion protection لوحده.
3. **Availability and durability**: **Single DB instance** (الـ Multi-AZ في §8).
4. DB instance identifier: `student-app-lab-mysql` · Master username: `student` · Credentials management: **Self managed** → الباسورد = **نفس `DB_PASSWORD` الحالي** (كده الـ app محتاج يغيّر `DB_HOST` بس):

```bash
aws ssm get-parameter --name /student-app/lab/app/DB_PASSWORD --with-decryption --query Parameter.Value --output text
```

5. Instance configuration: Burstable → `db.t4g.micro` · Storage: **gp3**، 20 GiB · افتح Storage autoscaling وسيبها مقفولة (الـ module: `max_allocated_storage = 0`).
6. **Connectivity**: **Connect to an EC2 compute resource** → اختار الـ instance بتاع 20. الـ console هيعمل لوحده: DB subnet group (private subnets)، SG `rds-ec2-N` على الـ RDS (inbound 3306 من SG الـ EC2)، و SG `ec2-rds-N` على الـ EC2 (outbound 3306). **Public access: No**.
7. **Additional configuration**: Initial database name: `student_app` · DB parameter group: `student-app-lab-mysql84` · Backup retention: **7 days** · ✅ Enable encryption · Log exports: ✅ Error log ✅ Slow query log · ⬜ Enable deletion protection (lab).
8. **Create database** (~5–10 دقايق) → خد الـ **Endpoint** من تاب **Connectivity & security**.

> 💡 قارن الـ SG chain اللي الـ wizard عمله بالـ module: `rds-ec2-N` ≈ `aws_security_group.this` + `from_sg`، و `ec2-rds-N` ≈ الـ egress `app_data` (3306 → VPC CIDR) في stack 40.

### 4.3 النقل (على الـ host — Session Manager)

**EC2 → Instances → الـ host → Connect → Session Manager**:

```bash
sudo su - ec2-user
cd /opt/student-app/src
export APP_IMAGE="$(cat /opt/student-app/CURRENT_RELEASE)"
RDS=<RDS_ENDPOINT>                                   # student-app-lab-mysql.xxxx.us-east-1.rds.amazonaws.com
PW=$(grep '^DB_PASSWORD=' /opt/student-app/app.env | cut -d= -f2-)

# 0) اتأكد إن الـ host شايف الـ RDS
docker run --rm -e MYSQL_PWD="$PW" mysql:8.4 mysql -h "$RDS" -u student -e 'SELECT VERSION(), @@character_set_server, @@collation_server'

# 1) أوقف الكتابة (maintenance mode) — من اللحظة دي الـ downtime بدأ
docker compose -f docker-compose.prod.yml exec -T app php artisan down --retry=30

# 2) dump متّسق من الـ container
docker compose -f docker-compose.prod.yml exec -T mysql sh -c \
  'mysqldump --single-transaction --quick --routines --triggers --set-gtid-purged=OFF -uroot -p"$MYSQL_ROOT_PASSWORD" student_app' \
  | gzip > /tmp/student_app.sql.gz
ls -lh /tmp/student_app.sql.gz

# 3) restore على RDS
gunzip -c /tmp/student_app.sql.gz | docker run --rm -i -e MYSQL_PWD="$PW" mysql:8.4 mysql -h "$RDS" -u student student_app

# 4) قارن العدد قبل ما تحوّل
for t in users students subscriptions sessions migrations; do
  a=$(docker compose -f docker-compose.prod.yml exec -T mysql sh -c "mysql -N -uroot -p\"\$MYSQL_ROOT_PASSWORD\" student_app -e 'SELECT COUNT(*) FROM $t'" 2>/dev/null)
  b=$(docker run --rm -e MYSQL_PWD="$PW" mysql:8.4 mysql -N -h "$RDS" -u student student_app -e "SELECT COUNT(*) FROM $t")
  echo "$t container=$a rds=$b"
done
```

### 4.4 التحويل (`DB_HOST`)

من CloudShell أو جهازك (الـ instance role بيقرا بس):

```bash
aws ssm put-parameter --name /student-app/lab/app/DB_HOST --type String --value <RDS_ENDPOINT> --overwrite
```

وعلى الـ host:

```bash
cd /opt/student-app/src && export APP_IMAGE="$(cat /opt/student-app/CURRENT_RELEASE)"
bash deploy/ec2/render-env-from-ssm.sh
grep '^DB_HOST=' /opt/student-app/app.env
docker compose -f docker-compose.prod.yml up -d --no-deps --force-recreate app   # container جديد = بيقرا app.env الجديد، ومن غير ملف "down"
curl -s http://127.0.0.1/ready | jq .
docker compose -f docker-compose.prod.yml stop mysql                             # الـ volume فاضل = خطة رجوع
```

> 💡 `php artisan down` بيكتب `storage/framework/down` **جوه الـ container**؛ الـ recreate بيشيله تلقائياً. ولو بتستخدم ستاك `lb` ([23](23-bluegreen-single-host.md)): `USE_LOCAL_MYSQL=false` + deploy بنفس الـ image، بس اقرا §4.5 الأول.

### 4.5 ⚠️ "Zero downtime" في نقل الداتابيز — الحقيقة

| الطريقة | الـ downtime | الثمن |
|---|---|---|
| **Freeze → dump → restore → switch** (اللي عملناه) | من `artisan down` لحد الـ switch (دقايق، حسب حجم الداتا) | بسيطة ومضمونة؛ مفيش كتابة بتضيع |
| dump من غير freeze ثم switch | "صفر" ظاهرياً | **كل كتابة بعد الـ dump بتضيع** (subscriptions اتعملت على القديم) — data loss صامت |
| blue/green بلونين على داتابيزين | صفر | **split brain**: slot بيكتب في الـ container والتاني في RDS في نفس الوقت |
| initial dump + **binlog replication** (RDS كـ replica من الـ external source، `mysql.rds_set_external_source…`) ثم cutover لما الـ lag = 0 | ثواني (write freeze قصير وقت الـ cutover) | binlog/GTID على المصدر، network بين الاتنين، و runbook |
| **AWS DMS** full load + CDC | ثواني | خدمة إضافية بفلوس، وتعقيد في الـ validation |

والرجوع بعد الـ switch **باب اتجاه واحد**: أي كتابة على RDS بعد التحويل مش موجودة في الـ container. الرجوع بـ `DB_HOST=mysql` = خسارة الكتابات دي، إلا لو عملت reverse replication. عشان كده الـ verification (§4.3 خطوة 4) **قبل** الـ switch، مش بعده.

## 5) الطريقة التانية: Infrastructure as Code (Terraform)

### 5.1 الـ Variables (stack 40 → module)

| Stack 40 | Default | Module input | ملاحظة |
|---|---|---|---|
| `db_name` | `student_app` | `db_name` | |
| `db_username` | `student` | `username` | |
| `db_instance_class` | `db.t4g.micro` | `instance_class` | Graviton، أرخص class |
| `db_multi_az` | `false` | `multi_az` | بيضاعف التكلفة |
| `db_deletion_protection` | `false` | `deletion_protection` | |
| `db_skip_final_snapshot` | `true` | `skip_final_snapshot` | |
| — | — | `subnet_ids = module.network.private_subnet_ids` | |
| — | — | `allowed_security_group_ids = [aws_security_group.app.id]` | SG واحد مشترك بين blue و green |
| — | — | `ssm_prefix = local.ssm_app` (`/student-app/lab/app`) | |

Inputs موجودة في الـ module ومش متعرّضة في الـ stack (الـ defaults): `engine_version` (`8.4`)، `allocated_storage` (20)، `max_allocated_storage` (0)، `backup_retention_period` (7)، `use_secrets_manager` (false)، `apply_immediately` (true)، `cloudwatch_logs_exports` (`["error","slowquery"]`)، `log_retention_days` (7)، `long_query_time` (1)، `allowed_cidr_blocks` ([]).

### 5.2 Apply

الخيار الأنضف إنك تعمل الـ stack كله دلوقتي (الـ ALB والـ ASG هنشرحهم في [42](42-alb-asg-launch-template.md)) — محتاج instance جوه الـ VPC عشان النقل:

```bash
cd infra/terraform/stacks/40-ec2-alb-asg
# terraform.tfvars: image_tag = "<sha موجود في ECR>"   (aws ecr list-images --repository-name student-app)
terraform plan -out=tfplan
terraform apply tfplan                                   # ~10 دقايق (RDS هو الأبطأ)
```

لو عايز الـ RDS لوحده للتعلم: `terraform plan -target=module.rds -out=rds.tfplan && terraform apply rds.tfplan` (بيجيب الشبكة معاه).

> ⚠️ لو عملت parameters بإيدك في §4 (`/student-app/lab/app/DB_HOST`…)، أو الـ RDS بنفس الـ identifier لسه موجود، الـ apply هيفشل (`ParameterAlreadyExists` / `DBInstanceAlreadyExists`). امسح بتوع الـ console الأول (§10)، أو اعمل `terraform import` ([91](91-terraform-import-and-drift.md)).

```bash
terraform output -raw rds_address
terraform state show 'module.rds.aws_db_instance.this' | grep -E 'multi_az|backup_retention|deletion_protection|storage_encrypted|parameter_group_name'
aws ssm get-parameters-by-path --path /student-app/lab/app --query 'Parameters[?starts_with(Name, `/student-app/lab/app/DB_`)].[Name,Type]' --output table
```

## 6) الـ Deploy — نقل الداتا لـ RDS بتاع stack 40

stack 20 و stack 40 **مينفعش يعيشوا مع بعض** على `env=lab` (نفس الـ SSM paths)، و stack 20 بيمسح الـ backups bucket مع الـ destroy (`backup_bucket_force_destroy = true`). فالترتيب:

```bash
# 1) على stack 20 (قبل الـ destroy): freeze + dump لـ S3 (سكريبت 27)
#    Session Manager على الـ host:
#      cd /opt/student-app/src && docker compose -f docker-compose.prod.yml exec -T app php artisan down
#      BACKUP_BUCKET=<backup_bucket> bash deploy/ec2/backup-mysql-to-s3.sh
# 2) من WSL: انسخ الـ dump عندك (الـ bucket هيتمسح مع stack 20)
aws s3 ls s3://<backup_bucket>/mysql/
aws s3 cp s3://<backup_bucket>/mysql/<student_app-YYYY-MM-DDTHHMM.sql.gz> ./student_app.sql.gz
# 3) terraform destroy لـ stack 20، ثم apply لـ stack 40 (§5.2)
```

### 6.1 Restore عن طريق Session Manager port forwarding (من غير bastion)

```bash
cd infra/terraform/stacks/40-ec2-alb-asg
RDS=$(terraform output -raw rds_address)
IID=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names student-app-lab-blue \
        --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`]|[0].InstanceId' --output text)

# Terminal 1: نفق localhost:13306 → (instance) → RDS:3306
aws ssm start-session --target "$IID" --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"$RDS\"],\"portNumber\":[\"3306\"],\"localPortNumber\":[\"13306\"]}"
```

```bash
# Terminal 2:
export MYSQL_PWD=$(aws ssm get-parameter --name /student-app/lab/app/DB_PASSWORD --with-decryption --query Parameter.Value --output text)
mysql -h 127.0.0.1 -P 13306 -u student -e 'SELECT @@version, @@character_set_server, @@collation_server'
gunzip -c student_app.sql.gz | mysql -h 127.0.0.1 -P 13306 -u student student_app
mysql -h 127.0.0.1 -P 13306 -u student student_app -e 'SELECT COUNT(*) FROM students; SELECT COUNT(*) FROM migrations;'
unset MYSQL_PWD
```

ليه ده شغال من غير ما تفتح أي port؟ الـ SSM agent على الـ instance بيعمل outbound 443 لـ SSM، والـ instance نفسها مسموح لها 3306 للـ VPC CIDR (`app_data` egress) والـ RDS SG بيقبل من SG الـ app. صلاحيتك بالـ IAM (`ssm:StartSession`)، ومتسجلة في CloudTrail.

### 6.2 بعد الـ restore

```bash
eval "$(terraform output -raw migrate_command)"        # الـ migrations اللي ناقصة (أو "Nothing to migrate")
curl -s "$(terraform output -raw app_url)/ready" | jq .
```

> - لو مفيش dump (بداية نضيفة): `migrate_command` وبعدين الـ seed من [42 §6](42-alb-asg-launch-template.md).
> - stack 40 بيعمل **`APP_KEY` جديد** (`random_bytes`)، فالـ sessions اللي في الـ dump مش هتتفك → كل المستخدمين هيعملوا login تاني. ده متوقع (التطبيق مفيهوش encrypted casts، فمفيش داتا بتبوظ).

## 7) التحقق (Verify)

```bash
aws rds describe-db-instances --db-instance-identifier student-app-lab-mysql \
  --query 'DBInstances[0].{status:DBInstanceStatus,class:DBInstanceClass,ver:EngineVersion,multiAZ:MultiAZ,public:PubliclyAccessible,encrypted:StorageEncrypted,backup:BackupRetentionPeriod,pg:DBParameterGroups[0].DBParameterGroupName,latestRestorable:LatestRestorableTime}'
aws rds describe-db-parameters --db-parameter-group-name "$(aws rds describe-db-instances --db-instance-identifier student-app-lab-mysql --query 'DBInstances[0].DBParameterGroups[0].DBParameterGroupName' --output text)" \
  --source user --query 'Parameters[].[ParameterName,ParameterValue]' --output table
aws logs describe-log-groups --log-group-name-prefix /aws/rds/instance/student-app-lab-mysql --query 'logGroups[].[logGroupName,retentionInDays]' --output table
curl -s "$(terraform -chdir=infra/terraform/stacks/40-ec2-alb-asg output -raw app_url)/sre-lab/db" \
  -H "X-Lab-Token: $(terraform -chdir=infra/terraform/stacks/40-ec2-alb-asg output -raw sre_lab_token)" | jq .
```

المفروض: `public=false`، `encrypted=true`، `backup=7`، `latestRestorable` من دقايق، الـ parameters الأربعة متغيرين، والـ log groups بـ retention 7.

## 8) اكسرها (Break it): تمرين على الأعطال

شغّل الـ probe على جهازك الأول: `bash deploy/scripts/probe.sh http://<ALB_DNS>/ready 0 0.5`.

| التمرين | الأمر | المتوقع |
|---|---|---|
| Reboot (Single-AZ) | `aws rds reboot-db-instance --db-instance-identifier student-app-lab-mysql` | `/ready` = 503 لكل الـ instances لمدة الـ reboot (دقيقة–اتنين). الـ ALB لو كل الـ targets unhealthy بيعمل **fail open** (يبعت للكل) |
| ⚠️ الـ deep health check cascade | خلّي الـ reboot أطول (أو امسح rule الـ 3306 من `student-app-lab-rds` لمدة 3 دقايق) وراقب **EC2 → Auto Scaling groups → Activity** | `/ready` بيعمل DB ping → كل الـ targets unhealthy → الـ ASG (health check type **ELB**) **بيبدّل كل الـ instances** رغم إن المشكلة في الداتابيز. رجّع الـ rule بـ `terraform apply` ([42 §1](42-alb-asg-launch-template.md) فيه الحل) |
| Multi-AZ failover | `terraform apply -var db_multi_az=true` (~15–20 دقيقة) ثم `aws rds reboot-db-instance --db-instance-identifier student-app-lab-mysql --force-failover` | الـ endpoint نفسه بيشاور على الـ standby بعد ~1–2 دقيقة؛ الـ probe بيعدّ الـ failures. رجّع `db_multi_az=false` (التكلفة ×2) |
| باسورد غلط في SSM | `aws ssm put-parameter --name /student-app/lab/app/DB_PASSWORD --type SecureString --value wrong --overwrite` + terminate instance واحدة | الـ instance الجديدة `/ready` = 503 (`database unreachable`) ومبتاخدش traffic؛ القديمة شغالة (الـ env بيتقري وقت الـ boot بس). رجّع بـ `terraform apply` (الـ module بيكتب القيمة الصح) |
| PITR | §9 | instance جديد بـ endpoint جديد |

## 9) الرجوع (Rollback)

**بيانات اتمسحت بالغلط** → Point-in-time restore (لـ instance **جديد**):

```bash
aws rds describe-db-instances --db-instance-identifier student-app-lab-mysql --query 'DBInstances[0].LatestRestorableTime'
aws rds restore-db-instance-to-point-in-time \
  --source-db-instance-identifier student-app-lab-mysql \
  --target-db-instance-identifier student-app-lab-mysql-pitr \
  --restore-time 2026-11-21T10:15:00Z \
  --db-instance-class db.t4g.micro --no-publicly-accessible \
  --db-subnet-group-name student-app-lab-mysql \
  --vpc-security-group-ids "$(aws rds describe-db-instances --db-instance-identifier student-app-lab-mysql --query 'DBInstances[0].VpcSecurityGroups[0].VpcSecurityGroupId' --output text)" \
  --tags Key=Project,Value=student-app Key=Env,Value=lab Key=ManagedBy,Value=console Key=Scenario,Value=41
aws rds wait db-instance-available --db-instance-identifier student-app-lab-mysql-pitr
```

بعدها يا إما تنسخ الجداول المطلوبة من الـ PITR instance للأصلي (أأمن)، يا إما تحوّل `DB_HOST` للـ instance الجديد (وده **خارج الـ Terraform** → drift). امسح `student-app-lab-mysql-pitr` بعد ما تخلص. الـ DR الكامل (RTO/RPO) في [77](77-backup-and-dr.md).

**الرجوع من RDS للـ container (Console path):** `DB_HOST=mysql` في SSM → `render-env-from-ssm.sh` → `docker compose -f docker-compose.prod.yml up -d mysql` → `up -d --no-deps --force-recreate app`. افتكر §4.5: الكتابات اللي حصلت على RDS بتضيع.

## 10) المسح (Teardown) ⚠️

**Console:**
1. **RDS → Databases → `student-app-lab-mysql` → Actions → Delete** → ⬜ Create final snapshot → ⬜ Retain automated backups → اكتب `delete me`.
2. بعد ما يخلص: **Parameter groups** → امسح `student-app-lab-mysql84` · **Subnet groups** → امسح الـ group اللي الـ wizard عمله · **EC2 → Security groups** → `rds-ec2-N` و `ec2-rds-N` (شيل الـ SG من الـ instance الأول).
3. رجّع `DB_HOST` لو هتكمّل على host الـ 20، أو امسح الـ parameters اللي عملتها.

**Terraform:**

```bash
cd infra/terraform/stacks/40-ec2-alb-asg
terraform destroy           # الـ RDS من غير final snapshot (lab defaults)
aws rds describe-db-instances --query 'DBInstances[?starts_with(DBInstanceIdentifier, `student-app`)].DBInstanceIdentifier'
aws rds describe-db-snapshots --snapshot-type manual --query 'DBSnapshots[?starts_with(DBSnapshotIdentifier, `student-app`)].DBSnapshotIdentifier'
aws rds describe-db-instance-automated-backups --query 'DBInstanceAutomatedBackups[?starts_with(DBInstanceIdentifier, `student-app`)].[DBInstanceIdentifier,Status]'
```

كلهم لازم فاضيين (أي snapshot باقي = فلوس كل شهر).

## 11) التكلفة (Cost)

| Resource | السعر التقريبي (us-east-1 — تقريبي، راجع صفحة الأسعار) |
|---|---|
| RDS `db.t4g.micro` Single-AZ | ~$0.016/ساعة ≈ $0.38/يوم (ممكن يبقى ضمن الـ free tier/credits حسب حسابك) |
| Multi-AZ | ~×2 (instance + storage) |
| gp3 storage 20 GiB | ~$0.115/GB-شهر ≈ $0.08/يوم |
| Automated backups | مجاني لحد حجم الـ storage المحجوز؛ بعد كده ~$0.095/GB-شهر |
| Manual / final snapshots | ~$0.095/GB-شهر لحد ما تمسحها |
| Secrets Manager (`use_secrets_manager`) | ~$0.40/secret/شهر |
| CloudWatch Logs (error + slowquery) | سنتات |

## 12) أسئلة Interview

<details><summary>Multi-AZ مقابل Read Replica؟</summary>

Multi-AZ (instance) = standby synchronous في AZ تانية، مش بيخدم traffic، والـ failover أوتوماتيك بنفس الـ endpoint (DNS) في دقيقة–اتنين → **availability**. Read replica = async، بيخدم reads، ممكن cross-region، والـ promote يدوي (أو جزء من DR) → **scale reads / DR**، وفيه replication lag (read-after-write ممكن يرجّع داتا قديمة). Multi-AZ DB cluster بيجمع الاتنين جزئياً (2 readable standbys، failover أسرع).

</details>

<details><summary>إزاي تنقل داتابيز production لـ RDS بأقل downtime؟</summary>

initial full load (mysqldump/mydumper أو snapshot) + **CDC**: binlog replication مع RDS كـ replica للـ external source، أو AWS DMS. استنى الـ lag يبقى صفر، اعمل write freeze قصير، اتأكد (row counts / checksums)، حوّل الـ connection string (DNS بـ TTL قصير أو config release)، وخلّي خطة رجوع (reverse replication) لو محتاجها. الـ dump-and-switch من غير freeze = data loss صامت.

</details>

<details><summary>PITR بيشتغل إزاي وإيه حدوده؟</summary>

RDS بياخد snapshot يومي ويرفع الـ transaction logs كل ~5 دقايق لـ S3 → تقدر ترجع لأي ثانية في الـ retention (لحد `LatestRestorableTime`). الـ restore بيعمل **instance جديد** بـ endpoint جديد (مش بيكتب فوق القديم)، وبياخد وقت يتناسب مع الحجم والـ logs. يعني RPO دقايق، و RTO = وقت الـ restore + تحويل الـ app. ولو مسحت الـ instance والـ `delete_automated_backups = true` → PITR راح.

</details>

<details><summary>ليه الـ health check العميق (`/ready` بـ DB ping) خطر مع ASG؟</summary>

لو الداتابيز وقعت أو عملت failover، **كل** الـ targets بتفشل في نفس الوقت. الـ ALB بيعمل fail open (كويس)، لكن الـ ASG بـ `health_check_type = "ELB"` هيعتبرهم unhealthy ويبدّلهم كلهم → instances جديدة بتبوت (دقايق) والمشكلة لسه في الداتابيز = outage أطول. الحلول: readiness عميق للـ LB و liveness سطحي (`/up`) للـ ASG، أو EC2 health checks للـ ASG مع alarms، أو تعليق `ReplaceUnhealthy` وقت حوادث الداتابيز، أو readiness يفشل بس لو المشكلة محلية.

</details>

<details><summary>Deletion protection و final snapshot — ليه مش true دايماً؟</summary>

في production لازم: deletion protection بيمنع `terraform destroy`/typo من مسح الداتا، والـ final snapshot نسخة أخيرة. في lab ephemeral بيعطّلوا الـ destroy ويسيبوا snapshots بتتحاسب للأبد. الحل الـ senior: defaults آمنة في الـ module للـ prod، و override صريح للـ lab (زي ما الـ stack عامل) — ومراجعة أي plan فيه `must be replaced` على RDS.

</details>

<details><summary>الباسورد في الـ Terraform state — مشكلة؟</summary>

أيوه: `random_password` بيتخزن في الـ state، فـ access على الـ state bucket = access على الباسورد (عشان كده الـ bucket encrypted ومقفول). البدائل: `manage_master_user_password` (RDS + Secrets Manager، الباسورد مبيدخلش الـ state، و rotation)، أو IAM database authentication. التمن: الـ consumers لازم يقروا من Secrets Manager (وده سبب إن stack 40 مش مفعّله: الـ user data بيقرا SSM بس).

</details>

<details><summary>ليه utf8mb4 والـ collation مهمين في النقل؟</summary>

`utf8` القديم في MySQL = 3 bytes (مش بيشيل emoji وبعض الحروف). لو الـ server default اختلف بين المصدر والهدف، الجداول اللي بتتعمل بعدين (أو بـ `CREATE TABLE` من غير collation) هتاخد collation مختلف → `Illegal mix of collations` في الـ joins، وترتيب/مقارنة مختلفة. الـ dump بيحتفظ بالـ collation بتاع كل جدول، والـ parameter group بيوحّد الـ default.

</details>

## 13) Checklist

- [ ] عملت parameter group + RDS من الـ console بـ "Connect to an EC2 compute resource" وفهمت الـ SGs اللي اتعملت
- [ ] نقلت الداتا بـ freeze → dump → restore → verify → switch
- [ ] عملت RDS بالـ Terraform وشفت الـ SSM parameters اللي الـ module كتبها
- [ ] عملت restore عن طريق SSM port forwarding من غير bastion
- [ ] جرّبت reboot و (اختياري) Multi-AZ failover وقست بالـ probe، وشفت الـ cascade بتاع الـ ELB health check
- [ ] جرّبت PITR لـ instance جديد ومسحته
- [ ] عملت teardown واتأكدت مفيش snapshots
