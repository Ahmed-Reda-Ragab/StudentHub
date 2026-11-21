# 20 — EC2 + Docker Compose + MySQL container، build على السيرفر (Console)

> **الهدف في سطر:** تطلّع التطبيق على الإنترنت بإيدك من الـ AWS Console: Security Group، IAM role، SSM Parameter Store، EC2 بـ user-data، Elastic IP، دخول بـ Session Manager (من غير SSH)، build على السيرفر، و seed — وبعدين teardown نضيف.
> **المستوى:** Beginner → Intermediate · **الوقت:** ~3 ساعات · **التكلفة التقريبية:** ~$0.5–0.7/يوم
> **بيعتمد على:** [02 — تجهيز حساب AWS](02-aws-account-setup.md) · [10 — تحويل التطبيق لـ container](10-containerize-app.md) · **الملفات في الـ repo:** [`deploy/ec2/user-data.sh`](../../../deploy/ec2/user-data.sh) · [`deploy/ec2/render-env-from-ssm.sh`](../../../deploy/ec2/render-env-from-ssm.sh) · [`deploy/ec2/deploy-build-on-server.sh`](../../../deploy/ec2/deploy-build-on-server.sh) · [`docker-compose.prod.yml`](../../../docker-compose.prod.yml) · [`deploy/env/app.env.example`](../../../deploy/env/app.env.example) · [`deploy/env/mysql.env.example`](../../../deploy/env/mysql.env.example)

## 1) الفكرة (Concepts)

ده أبسط deploy حقيقي: **سيرفر واحد**، عليه Docker Compose بيشغّل container للتطبيق و container لـ MySQL، والـ image **بتتبني على السيرفر نفسه** من الـ git repo. الاستراتيجية **Recreate** (الـ container القديم يقف والجديد يقوم → ثواني downtime، هنقيسها في [22](22-recreate-and-measuring-downtime.md)).

الطريقة دي **مش** اللي هتعملها في production (الـ build على السيرفر ده anti-pattern، وهنصلّحه في [32](32-cd-ec2-ecr-ssm.md))، بس هي أحسن طريقة تفهم بيها كل قطعة بإيدك قبل ما تأتمتها.

| القرار | اخترنا | البديل | ليه |
|---|---|---|---|
| الشبكة | **Default VPC** | VPC custom ([40](40-vpc-from-scratch.md)) | سريع؛ كل الـ subnets public وفيها Internet Gateway. عيبه: مفيش private subnets، ومحدش يعرف مين عمل إيه فيه |
| الدخول | **Session Manager** | SSH + key pair | مفيش بورت 22 مفتوح، مفيش keys تتسرّب، الـ IAM هو اللي بيتحكم، وكل session متسجلة في CloudTrail |
| الـ secrets | **SSM Parameter Store** (`/student-app/lab/...`) | `.env` منسوخ بإيدك | مصدر حقيقة واحد، مشفّر بـ KMS، صلاحيات بالـ IAM، ونفس الـ layout هيستخدمه ECS و EKS |
| الـ IP | **Elastic IP** | الـ public IP التلقائي | الـ IP التلقائي بيتغيّر مع كل stop/start → `APP_URL` يبوظ |
| الـ metadata | **IMDSv2 only** | IMDSv1 | بيمنع SSRF من إنه يسرق credentials الـ role |

| المصطلح | المعنى |
|---|---|
| Instance profile | الـ "حاوية" اللي بتربط IAM role بـ EC2؛ الـ Console بيعملها تلقائي بنفس اسم الـ role |
| User data | سكريبت بيجري **مرة واحدة** كـ root أول boot (cloud-init) |
| SecureString | parameter مشفّر بـ KMS (الافتراضي `alias/aws/ssm`) |

## 2) المعمارية (Architecture)

```text
 Internet (أنت: My IP)
      │ HTTP :80
      ▼
 ┌─ Default VPC ── public subnet ─────────────────────────────────────────┐
 │  SG student-app-lab-web-sg: in 80 (My IP) · no 22 · out all            │
 │  ┌─ EC2 t3.small · AL2023 · EIP · IMDSv2 · role student-app-lab-ec2-role ┐
 │  │  user-data: docker + compose + buildx + git + jq + 2G swap          │ │
 │  │  /opt/student-app/                                                   │ │
 │  │    app.env, mysql.env (chmod 600) ◄── render-env-from-ssm.sh ◄──────┼─┼── SSM Parameter Store
 │  │    src/ (git clone)  CURRENT_RELEASE  PREVIOUS_RELEASE               │ │   /student-app/lab/{app,mysql}/*
 │  │    docker compose (project student-app, docker-compose.prod.yml):   │ │
 │  │      app  :80→8080  (image student-app:<sha> built here)            │ │
 │  │      mysql:8.4      (volume student-app_mysql-data)                 │ │
 │  └──────────────────────────────────────────────────────────────────────┘ │
 └───────────────────────────────────────────────────────────────────────────┘
        ▲ Session Manager (443 outbound من الـ agent — مفيش inbound)
   أنت من الـ Console أو `aws ssm start-session`
```

## 3) المتطلبات (Prerequisites)

- [ ] حساب AWS متجهّز ([02](02-aws-account-setup.md)) و Budget alert شغال.
- [ ] Region: **us-east-1** (اختارها فوق يمين في الـ Console).
- [ ] تعرف الـ IP بتاعك: `curl -s https://checkip.amazonaws.com`.
- [ ] الـ repo فيه ملفات `deploy/` على branch `devops-lab` (لو الـ repo private هتحتاج fine-grained PAT read-only للـ clone).
- الأدوات: المتصفح + **CloudShell** (أيقونة `>_` فوق في الـ Console) أو `aws` من WSL.

## 4) الطريقة الأولى: AWS Console (يدوي)

### 4.1 الـ VPC

1. **VPC → Your VPCs** → اتأكد إن فيه VPC عليه `Default VPC = Yes`.
2. لو مش موجود: **Actions → Create default VPC**.

> 💡 الـ default VPC كويس للتجربة دي بس. في [40](40-vpc-from-scratch.md) هنعمل VPC بـ public/private subnets ونعرف ليه الـ DB مكانها مش subnet public.

### 4.2 الـ Security Group

1. **EC2 → Network & Security → Security groups → Create security group**.
2. القيم:
   - Name: `student-app-lab-web-sg` · Description: `student-app lab web (scenario 20)` · VPC: الـ default.
   - **Inbound rules → Add rule:** Type `HTTP`، Port `80`، Source **My IP**.
   - **مفيش rule لـ SSH (22).**
   - Outbound: سيب الافتراضي (All traffic) — الـ instance محتاج يوصل لـ `dnf` و GitHub و Docker Hub وendpoints بتاعة SSM على 443.
   - Tags: `Project=student-app`، `Env=lab`، `ManagedBy=console`، `Scenario=20`.
3. **Create security group**.

> ⚠️ ليه **My IP** مش `0.0.0.0/0`؟ في `docker-compose.prod.yml` بورت 80 رايح على الـ app container مباشرة، يعني `/metrics` مكشوف لأي حد (الـ nginx اللي بيقفله على الـ LB بييجي في [23](23-bluegreen-single-host.md)). و `/sre-lab/*` محمي بـ `SRE_LAB_TOKEN` بس. لو احتجت تفتحه للعالم (مثلاً probe من مكان تاني) افتحه وقت التجربة واقفله بعدها. أو حط `METRICS_TOKEN` (SecureString في `/student-app/lab/app/METRICS_TOKEN`) فـ `/metrics` يبقى محتاج `Authorization: Bearer <token>` — ده متوافق مع الـ metric gate في [24](24-canary-single-host.md) (`lib.sh` بيقرا الـ token من `app.env` ويبعته).

### 4.3 الـ IAM role للـ instance

1. **IAM → Roles → Create role**.
2. **Trusted entity type:** AWS service · **Use case:** EC2 → Next.
3. **Permissions policies:** اختار:
   - `AmazonSSMManagedInstanceCore` (Session Manager + Run Command)
   - `AmazonEC2ContainerRegistryReadOnly` (هنحتاجها في [32](32-cd-ec2-ecr-ssm.md) للـ pull من ECR)
4. **Role name:** `student-app-lab-ec2-role` · Tags زي فوق → **Create role**.
5. افتح الـ role → **Permissions → Add permissions → Create inline policy → JSON**:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ReadLabParameters",
      "Effect": "Allow",
      "Action": ["ssm:GetParametersByPath", "ssm:GetParameters", "ssm:GetParameter"],
      "Resource": "arn:aws:ssm:us-east-1:<ACCOUNT_ID>:parameter/student-app/lab/*"
    },
    {
      "Sid": "DecryptSecureStringViaSsm",
      "Effect": "Allow",
      "Action": "kms:Decrypt",
      "Resource": "*",
      "Condition": { "StringEquals": { "kms:ViaService": "ssm.us-east-1.amazonaws.com" } }
    }
  ]
}
```

6. Policy name: `student-app-lab-read-params` → **Create policy**.

> 💡 مع المفتاح الافتراضي `alias/aws/ssm` الـ key policy بتاعته بتسمح بالـ decrypt عن طريق SSM لأي principal في الحساب عنده صلاحية SSM، فالـ statement التاني احتياطي؛ لكن لو استخدمت **customer managed key** هيبقى ضروري. الـ `kms:ViaService` بيضمن إن المفتاح يتستخدم عن طريق SSM بس.

### 4.4 الـ Parameters في SSM Parameter Store

أسرع طريقة: **CloudShell**. الأسماء من [CONVENTIONS §4](../CONVENTIONS.md):

```bash
REGION=us-east-1
P=/student-app/lab
APP_KEY="base64:$(openssl rand -base64 32)"
DB_PASSWORD="$(openssl rand -hex 24)"
ROOT_PASSWORD="$(openssl rand -hex 24)"
SRE_LAB_TOKEN="$(openssl rand -hex 16)"
# من غير --overwrite عن قصد: لو شغّلت السكريبت تاني مش هيغيّر APP_KEY أو الباسوردات (ParameterAlreadyExists)
put() { aws ssm put-parameter --region "$REGION" --name "$1" --type "$2" --value "$3" >/dev/null && echo "created $1"; }

put $P/app/APP_KEY            SecureString "$APP_KEY"
put $P/app/APP_NAME           String "Students Subscriptions"
put $P/app/APP_ENV            String production
put $P/app/APP_DEBUG          String false
put $P/app/APP_TIMEZONE       String Africa/Cairo
put $P/app/APP_LOCALE         String ar
put $P/app/DB_CONNECTION      String mysql
put $P/app/DB_HOST            String mysql
put $P/app/DB_PORT            String 3306
put $P/app/DB_DATABASE        String student_app
put $P/app/DB_USERNAME        String student
put $P/app/DB_PASSWORD        SecureString "$DB_PASSWORD"
put $P/app/SESSION_DRIVER     String database
put $P/app/CACHE_STORE        String database
put $P/app/QUEUE_CONNECTION   String sync
put $P/app/LOG_LEVEL          String info
put $P/app/SRE_LAB_ENABLED    String true
put $P/app/SRE_LAB_TOKEN      SecureString "$SRE_LAB_TOKEN"
put $P/app/METRICS_ENABLED    String true
put $P/mysql/MYSQL_DATABASE      String student_app
put $P/mysql/MYSQL_USER          String student
put $P/mysql/MYSQL_PASSWORD      SecureString "$DB_PASSWORD"
put $P/mysql/MYSQL_ROOT_PASSWORD SecureString "$ROOT_PASSWORD"
echo "SRE_LAB_TOKEN=$SRE_LAB_TOKEN   ← احفظه (هتحتاجه كـ header X-Lab-Token و GitHub secret)"
```

> - `DB_PASSWORD` و `MYSQL_PASSWORD` **لازم نفس القيمة**. والـ `MYSQL_*` بتتقري **أول مرة الـ volume بيتعمل بس** — لو غيّرتها بعدين لازم تغيّرها جوه MySQL كمان.
> - استخدمنا `-hex` للباسوردات عشان مفيش رموز (`$`، `#`، `"`) تبوّظ الـ env file.
> - `APP_KEY` لو اتغيّر: كل الـ sessions و أي داتا متشفّرة بيه بتبوظ. **متعملهوش rotate عشوائي.**

من الـ Console بدل CloudShell: **Systems Manager → Parameter Store** (تحت *Application Tools*) **→ Create parameter** → Name `/student-app/lab/app/APP_KEY` · Tier **Standard** · Type **SecureString** · KMS key source **My current account** (`alias/aws/ssm`) · Value → **Create parameter**. كرّرها لكل key (عشان كده الـ CLI أسرع).

### 4.5 تشغيل الـ EC2

1. **EC2 → Instances → Launch instances**.
2. **Name and tags:** `student-app-lab-ec2` → **Add additional tags**: `Project=student-app`، `Env=lab`، `ManagedBy=console`، `Scenario=20`، و `Role=app` (Resource types: Instances + Volumes).
3. **Application and OS Images:** **Amazon Linux 2023 AMI** · Architecture **64-bit (x86)** (أو Arm مع `t4g.small` — الـ user-data بيدعم الاتنين).
4. **Instance type:** `t3.small` (2 vCPU، 2 GiB). الـ `t3.micro` (1 GiB) هيتعب في الـ build حتى مع الـ swap.
5. **Key pair (login):** **Proceed without a key pair (Not recommended)** — مش محتاجينه مع Session Manager.
6. **Network settings → Edit:** VPC الـ default · Subnet: أي واحدة · **Auto-assign public IP: Enable** (الـ agent محتاج إنترنت قبل ما الـ EIP يتربط) · Firewall: **Select existing security group** → `student-app-lab-web-sg`.
7. **Configure storage:** `20` GiB **gp3** (الـ 8 الافتراضية بتتملي من الـ images والـ build cache).
8. **Advanced details:**
   - **IAM instance profile:** `student-app-lab-ec2-role`
   - **Metadata version:** **V2 only (token required)**
   - **User data:** الصق محتوى [`deploy/ec2/user-data.sh`](../../../deploy/ec2/user-data.sh) كامل.
9. **Launch instance**.

> 💡 الـ user-data بيثبّت `docker` و `git` و `jq` من `dnf`، ويشغّل Docker، ويضيف `ec2-user` لـ group docker، وينزّل **Compose** (`v2.39.4` افتراضياً) و **Buildx** (آخر release من GitHub API — مش pinned، trade-off في الـ reproducibility) كـ CLI plugins، ويعمل **swap 2G** (composer/npm بيعملوا OOM من غيره)، ويجهّز `/opt/student-app` لـ `ec2-user`، ويكتب `/opt/student-app/.bootstrapped` في الآخر. اللوج في `/var/log/cloud-init-output.log`.

### 4.6 الـ Elastic IP

1. **EC2 → Network & Security → Elastic IPs → Allocate Elastic IP address** → Network border group `us-east-1` → **Allocate**.
2. اختاره → **Actions → Associate Elastic IP address** → Resource type **Instance** → اختار `student-app-lab-ec2` → **Associate**.
3. ضيف الـ `APP_URL` (من CloudShell):

```bash
aws ssm put-parameter --region us-east-1 --name /student-app/lab/app/APP_URL --type String --value "http://<ELASTIC_IP>"
```

> 💡 من فبراير 2024 كل public IPv4 بيتحاسب (~$0.005/ساعة) سواء EIP أو تلقائي، ولما تربط EIP الـ IP التلقائي بيتشال. الـ EIP اللي **مش مربوط بـ instance شغال** برضه بيتحاسب — متنساهوش في الـ teardown.

### 4.7 الدخول بـ Session Manager

1. **EC2 → Instances** → اختار الـ instance → **Connect** → تاب **Session Manager** → **Connect**.
   (أو من WSL: `aws ssm start-session --target <INSTANCE_ID>`)
2. الـ session بتفتح كـ `ssm-user`. اتحوّل لـ `ec2-user`:

```bash
sudo su - ec2-user
cat /opt/student-app/.bootstrapped        # user-data finished: ...
docker version --format '{{.Server.Version}}' && docker compose version && docker buildx version
free -h                                   # لازم تشوف Swap 2.0Gi
```

لو الـ Connect button رمادي / "SSM Agent is not online": استنى 2–5 دقايق بعد الـ launch، اتأكد إن الـ instance profile متربط، وإن الـ outbound 443 مفتوح. لو `.bootstrapped` مش موجود: `sudo tail -50 /var/log/cloud-init-output.log`.

## 5) الطريقة التانية: Infrastructure as Code

السيناريو ده Console بس عن قصد. نفس الموارد بالظبط (network من غير NAT + EC2 AL2023 بـ user-data + SG + EIP + instance profile + SSM params) بيعملها الـ stack `infra/terraform/stacks/20-ec2-single`، والـ configuration بـ Ansible — كل ده في [21 — نفس الحاجة بـ Terraform + Ansible](21-ec2-compose-terraform-ansible.md). وفي [91](91-terraform-import-and-drift.md) هتعمل `import` للموارد اللي عملتها هنا بإيدك.

## 6) الـ Deploy

جوه الـ session كـ `ec2-user`:

```bash
cd /opt/student-app
git clone https://github.com/Ahmed-Reda-Ragab/StudentHub.git src
cd src && git switch devops-lab

# 1) secrets → env files (chmod 600)
bash deploy/ec2/render-env-from-ssm.sh
ls -l /opt/student-app/*.env              # -rw------- app.env / mysql.env

# 2) build + migrate + recreate
bash deploy/ec2/deploy-build-on-server.sh devops-lab
```

> ⚠️ السكريبت الافتراضي بيعمل deploy لـ `master`. طول ما ملفات الـ deploy على `devops-lab` بس، **لازم** تديله `devops-lab`.

اللي `render-env-from-ssm.sh` بيعمله: يجيب الـ region من IMDSv2 لو `AWS_REGION` مش متحدد، يعمل `get-parameters-by-path --recursive --with-decryption` على `/student-app/lab/app/` و `/student-app/lab/mysql/`، ويكتب كل parameter كـ `KEY=value` (اسم الـ key = آخر جزء في الـ path) في ملف مؤقت، وبعدين `install -m 600` لـ `/opt/student-app/app.env` و `mysql.env`. لو مفيش parameters تحت path معين بيسيب الملف زي ما هو. (متغيرات: `ENV_NAME` افتراضي `lab`، `APP_DIR` افتراضي `/opt/student-app`.)

واللي `deploy-build-on-server.sh <ref>` بيعمله:

| الخطوة | الأمر جوه السكريبت | ليه |
|---|---|---|
| 1 | `git fetch --prune origin` + `git checkout <ref>` + `merge --ff-only` | الكود المطلوب |
| 2 | `APP_IMAGE=student-app:<sha>` و `APP_VERSION=<sha>` | الـ tag = الـ commit |
| 3 | `docker compose -f docker-compose.prod.yml build app` | build على السيرفر (هنا الـ CPU بيضرب) |
| 4 | `up -d --wait mysql` (لو `USE_LOCAL_MYSQL=true`) | الداتابيز جاهزة |
| 5 | `run --rm --no-deps app php artisan migrate --force` | migrations مرة واحدة بالـ image الجديدة |
| 6 | `up -d --no-deps --wait app` | **Recreate** — هنا الـ downtime |
| 7 | `curl -fsS http://127.0.0.1/ready` | تأكيد |
| 8 | `CURRENT_RELEASE` → `PREVIOUS_RELEASE`، والجديد في `CURRENT_RELEASE` | للـ rollback |
| 9 | `docker image prune -f --filter until=168h` | مساحة الـ disk |

### الـ Seed (بيانات تجريبية)

```bash
cd /opt/student-app/src
export APP_IMAGE="$(cat /opt/student-app/CURRENT_RELEASE)"   # مهم: من غيره compose هيدوّر على student-app:local ويعيد الـ build
docker compose -f docker-compose.prod.yml run --rm --no-deps app php artisan db:seed --class=DemoSeeder --force
```

> 💡 الـ seeders بتشتغل جوه الـ image لأن `fakerphp/faker` في `require` (قرار للمعمل — الـ trade-off في [10 §6.1](10-containerize-app.md)). ولو عايز بيانات للـ load test: `LOADTEST_USERS=5 LOADTEST_STUDENTS_PER_USER=20 docker compose -f docker-compose.prod.yml run --rm --no-deps app php artisan db:seed --class=LoadTestSeeder --force` (الـ seeder idempotent).

افتح **`http://<ELASTIC_IP>/`** وادخل بـ `demo@example.com` / `password`.

## 7) التحقق (Verify)

من جهازك (WSL):

```bash
HOST=<ELASTIC_IP>
curl -s http://$HOST/ready                   # {"status":"ready",...,"version":"<sha>","color":"none"}
curl -s -o /dev/null -w '%{http_code}\n' http://$HOST/sre-lab/ping                      # 403 (مفيش token)
curl -s -H "X-Lab-Token: <SRE_LAB_TOKEN>" http://$HOST/sre-lab/version
bash deploy/scripts/probe.sh http://$HOST/ready 30 0.5
```

على السيرفر:

```bash
cd /opt/student-app/src
docker compose -f docker-compose.prod.yml ps
cat /opt/student-app/CURRENT_RELEASE
docker compose -f docker-compose.prod.yml logs app --tail=5
docker stats --no-stream
```

المفروض: `app` و `mysql` **healthy**، و `/ready` بيرجّع نفس الـ SHA اللي في `CURRENT_RELEASE`، و `/sre-lab/*` بيرفض من غير token.

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر | المتوقع |
|---|---|---|
| باسورد DB غلط | `aws ssm put-parameter --name /student-app/lab/app/DB_PASSWORD --type SecureString --value wrong --overwrite` ثم `bash deploy/ec2/render-env-from-ssm.sh && APP_IMAGE=$(cat /opt/student-app/CURRENT_RELEASE) docker compose -f docker-compose.prod.yml up -d --no-deps app` | `/up` = 200 بس `/ready` = 503 `database unreachable` — رجّع القيمة الصح |
| Release مش healthy | حط `/student-app/lab/app/SRE_FAULT_UNHEALTHY=true` واعمل render + `up -d --no-deps app` | `docker compose ps` = unhealthy، و `--wait` كان هيفشل |
| شيل الـ SSM role | IAM → الـ role → Detach `AmazonSSMManagedInstanceCore` | بعد دقايق الـ Session Manager مش هيوصل — رجّعها |
| Stop/Start | EC2 → Instance state → Stop ثم Start | نفس الـ EIP، والـ containers بترجع لوحدها (`restart: unless-stopped`) |
| SG مقفول | امسح rule الـ 80 | `curl` بيعمل timeout (مش refused) — ده فرق مهم وانت بتعمل debug |

## 9) الرجوع (Rollback)

```bash
cd /opt/student-app/src
cat /opt/student-app/PREVIOUS_RELEASE
export APP_IMAGE="$(cat /opt/student-app/PREVIOUS_RELEASE)"
docker compose -f docker-compose.prod.yml up -d --no-deps --wait app
curl -fsS http://127.0.0.1/ready
```

أو ابني commit قديم: `bash deploy/ec2/deploy-build-on-server.sh <OLD_SHA>`.

> ⚠️ الـ rollback بيرجّع الكود بس — الـ migrations اللي اتعملت فاضلة. ولو `PREVIOUS_RELEASE` مش موجود (أول deploy) مفيش حاجة ترجعلها.

## 10) المسح (Teardown) ⚠️

لو هتكمل [22](22-recreate-and-measuring-downtime.md)–[27](27-mysql-backup-restore.md) قريب: **Stop** الـ instance بس (الـ EBS والـ EIP لسه بيتحاسبوا بسنتات). غير كده امسح كل حاجة:

```bash
INSTANCE_ID=<INSTANCE_ID>
aws ec2 terminate-instances --instance-ids $INSTANCE_ID
aws ec2 wait instance-terminated --instance-ids $INSTANCE_ID
aws ec2 describe-addresses --query 'Addresses[].{ip:PublicIp,alloc:AllocationId,assoc:AssociationId}'
aws ec2 release-address --allocation-id <EIPALLOC_ID>
aws ec2 delete-security-group --group-id <SG_ID>

ROLE=student-app-lab-ec2-role
aws iam remove-role-from-instance-profile --instance-profile-name $ROLE --role-name $ROLE
aws iam delete-instance-profile --instance-profile-name $ROLE
aws iam detach-role-policy --role-name $ROLE --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam detach-role-policy --role-name $ROLE --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
aws iam delete-role-policy --role-name $ROLE --policy-name student-app-lab-read-params
aws iam delete-role --role-name $ROLE

aws ssm get-parameters-by-path --path /student-app/lab --recursive --query 'Parameters[].Name' --output text \
  | tr '\t' '\n' | xargs -n 10 aws ssm delete-parameters --names
```

تأكد إن مفيش حاجة لسه شغالة:

```bash
aws ec2 describe-instances --filters Name=tag:Project,Values=student-app Name=instance-state-name,Values=running,stopped --query 'Reservations[].Instances[].InstanceId'
aws ec2 describe-addresses --query 'Addresses[].PublicIp'
aws ec2 describe-volumes --filters Name=status,Values=available --query 'Volumes[].VolumeId'
```

- [ ] Instance terminated · [ ] EIP released · [ ] مفيش volumes `available` · [ ] SG ممسوح · [ ] Role + instance profile ممسوحين · [ ] Parameters ممسوحة (أو سايبها عن قصد — مجانية)

## 11) التكلفة (Cost)

| Resource | السعر التقريبي (us-east-1، راجع صفحة الأسعار) |
|---|---|
| EC2 `t3.small` on-demand | ~$0.0208/ساعة ≈ $0.50/يوم |
| EBS gp3 20 GiB | ~$0.08/GB/شهر ≈ $0.05/يوم |
| Public IPv4 / Elastic IP | ~$0.005/ساعة ≈ $0.12/يوم (حتى وهو مش مربوط) |
| SSM Parameter Store (Standard) و Session Manager | مجاني |
| Data transfer out | أول 100 GB/شهر مجاناً (على مستوى الحساب) |
| **الإجمالي** | **≈ $0.65/يوم** (الحسابات الجديدة ممكن يكون عندها free-tier credits — راجع صفحة Free Tier) |

## 12) أسئلة Interview

<details><summary>ليه Session Manager أحسن من SSH و bastion؟</summary>

مفيش inbound port خالص (الـ agent بيعمل outbound لـ SSM)، فمفيش attack surface على 22. الصلاحية بالـ IAM (تقدر تحددها بـ tags، وتلغيها فوراً)، مفيش keys تتوزّع أو تتسرّب أو تحتاج rotation، وكل session متسجلة في CloudTrail (وممكن تسجّل الـ output في S3/CloudWatch). وكمان بيدعم port forwarding للـ RDS من غير bastion.

</details>

<details><summary>إيه عيوب الـ build على السيرفر؟</summary>

السيرفر محتاج build tools وإنترنت وصلاحية على الـ repo، الـ CPU/RAM بيضربوا على نفس الـ box اللي بيخدم المستخدمين، كل سيرفر بيبني نسخة ممكن تختلف (dependencies اتغيّرت بين build والتاني)، والـ image عمرها ما اتفحصت (Trivy) قبل ما تشتغل. الحل: build once في CI → registry (ECR) → deploy نفس الـ digest في كل مكان ([32](32-cd-ec2-ecr-ssm.md)).

</details>

<details><summary>الـ secrets بتتكتب في `app.env` على الـ disk — ده مقبول؟</summary>

مقبول بحدود: `chmod 600`، ملك `ec2-user`، والـ EBS مشفّر. بس أي حد عنده root أو صلاحية docker يقدر يشوفها (`docker inspect` بيعرض الـ env). الأحسن: الـ app يقرا من SSM وقت الـ boot، أو ECS `secrets` / ESO على K8s حيث الـ secret مش بيتكتب في ملف على الـ host. والأهم إن مصدر الحقيقة مش الملف — SSM — فالـ rotation = تحديث parameter + re-render + recreate.

</details>

<details><summary>إيه اللي بيحصل للـ public IP لو عملت stop/start؟ وليه EIP؟</summary>

الـ auto-assigned public IP بيتغيّر مع كل stop/start، فـ `APP_URL` وأي DNS بيبوظوا. الـ EIP ثابت لحد ما تعمله release. في production الحل الصح غالباً ALB + Route 53 alias، والـ instances نفسها تبقى في private subnets من غير public IP خالص.

</details>

<details><summary>ليه IMDSv2؟</summary>

IMDSv1 بيرد على أي GET لـ `169.254.169.254`، فثغرة SSRF في التطبيق تقدر تسرق credentials الـ role. IMDSv2 بيحتاج PUT الأول عشان token وheader، وده بيكسر أغلب هجمات الـ SSRF. السكريبت `render-env-from-ssm.sh` نفسه بيستخدم IMDSv2 (`X-aws-ec2-metadata-token`) عشان يعرف الـ region.

</details>

<details><summary>ليه `MYSQL_PASSWORD` لما تغيّره في SSM مش بيتطبّق؟</summary>

الـ MySQL image بتقرا `MYSQL_*` بس لما الـ data directory فاضي (أول init للـ volume). بعد كده الباسورد جوه الداتابيز نفسها. تغيير الباسورد = `ALTER USER` جوه MySQL + تحديث الـ parameter + re-render + recreate للـ app. وده سبب من أسباب RDS + Secrets Manager rotation ([81](81-secrets-management.md)).

</details>

## 13) Checklist

- [ ] عملتها من الـ Console (SG، role، params، EC2، EIP، Session Manager)
- [ ] الـ app شغال على `http://<ELASTIC_IP>/` ودخلت بـ demo user
- [ ] `/ready` بيرجّع نفس الـ SHA اللي في `CURRENT_RELEASE`
- [ ] جرّبت الـ break-it والـ rollback لـ `PREVIOUS_RELEASE`
- [ ] عملت teardown (أو stop) واتأكدت إن مفيش EIP/volumes يتيمة
