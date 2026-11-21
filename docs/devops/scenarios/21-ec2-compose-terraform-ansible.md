# 21 — نفس الحاجة بـ Terraform + Ansible

> **الهدف في سطر:** تعمل سيناريو [20](20-ec2-compose-console.md) كله as code: الـ stack `20-ec2-single` (VPC + EC2 + SG + EIP + IAM + backups bucket + SSM params فيها `APP_KEY` متولّد بـ Terraform)، وبعدين Ansible (dynamic inventory، `provision.yml`، `deploy.yml -e app_image=...`) وتثبت إن التشغيل التاني **مبيغيّرش حاجة** (idempotency)، وتفهم SSM مقابل SSH والـ vault، وتعمل teardown نضيف.
> **المستوى:** Intermediate · **الوقت:** ~4 ساعات · **التكلفة التقريبية:** ~$0.03/ساعة (~$0.7/يوم لو سبته)
> **بيعتمد على:** [02](02-aws-account-setup.md) (bootstrap + `backend.hcl`) · [03](03-workstation-setup.md) (WSL + Ansible) · [20](20-ec2-compose-console.md) · [30](30-ci-github-actions.md) (image في ECR) · **الملفات في الـ repo:** [`infra/terraform/stacks/20-ec2-single/`](../../../infra/terraform/stacks/20-ec2-single/) ([`main.tf`](../../../infra/terraform/stacks/20-ec2-single/main.tf) · [`iam.tf`](../../../infra/terraform/stacks/20-ec2-single/iam.tf) · [`ssm.tf`](../../../infra/terraform/stacks/20-ec2-single/ssm.tf) · [`variables.tf`](../../../infra/terraform/stacks/20-ec2-single/variables.tf) · [`outputs.tf`](../../../infra/terraform/stacks/20-ec2-single/outputs.tf)) · [`modules/ec2-docker-host`](../../../infra/terraform/modules/ec2-docker-host/main.tf) · [`modules/network`](../../../infra/terraform/modules/network/main.tf) · [`infra/ansible/`](../../../infra/ansible/) ([`README.md`](../../../infra/ansible/README.md) · [`ansible.cfg`](../../../infra/ansible/ansible.cfg) · [`aws_ec2.yml`](../../../infra/ansible/inventories/lab/aws_ec2.yml) · [`group_vars/all/main.yml`](../../../infra/ansible/inventories/lab/group_vars/all/main.yml) · [`provision.yml`](../../../infra/ansible/playbooks/provision.yml) · [`deploy.yml`](../../../infra/ansible/playbooks/deploy.yml) · [`roles/app`](../../../infra/ansible/roles/app/)) · [`deploy/ec2/deploy-pull-image.sh`](../../../deploy/ec2/deploy-pull-image.sh)

## 1) الفكرة (Concepts)

في [20](20-ec2-compose-console.md) عملت كل حاجة بإيدك. هنا بنقسّم نفس الشغل على **3 طبقات**، وكل طبقة ليها أداة ومالك:

| الطبقة | الأداة | بتملك إيه | بتتغيّر كل قد إيه |
|---|---|---|---|
| **Infrastructure** | Terraform (stack 20) | VPC، SG، EC2، EIP، IAM، bucket، SSM params | نادراً |
| **Configuration** | Ansible (`provision.yml`) | packages، swap، sysctl، journald، Docker/Compose pinned، CloudWatch agent، node_exporter | مع كل baseline change |
| **Release** | Ansible (`deploy.yml`) → `deploy-pull-image.sh` | أنهي image شغالة + `app.env` | مع كل deploy |

الـ roles **مبتعيدش كتابة** منطق الـ deploy: بتنسخ وتشغّل نفس السكريبتات اللي بيستخدمها SSM ([32](32-cd-ec2-ecr-ssm.md)) والإنسان على السيرفر (`deploy/ec2/*.sh`). يعني deploy من Ansible = deploy من SSM = deploy بإيدك.

| المصطلح | المعنى |
|---|---|
| Idempotency | تشغيل نفس الـ playbook مرتين = نفس الحالة، والتانية بتقول `changed=0` |
| Convergence | Ansible بيوصّل السيرفر للحالة المكتوبة، مش بينفّذ أوامر عمياني |
| Dynamic inventory | الـ hosts جايين من AWS API بالـ tags (مش ملف IPs ثابت) |
| `aws_ssm` connection | Ansible بيكلّم السيرفر عن طريق Session Manager (من غير بورت 22) |
| Pets vs cattle | الـ host ده **pet** (MySQL عليه) → Terraform مش هيستبدله لوحده (`ignore_changes = [ami, user_data]`) |
| `random_bytes` | resource في Terraform بيولّد bytes عشوائية مرة واحدة ويحفظها في الـ state |

| القرار | اخترنا | البديل | ليه |
|---|---|---|---|
| الشبكة | VPC خاص بـ public subnets من غير NAT | default VPC (20) | نفس الـ module اللي هتستخدمه في 40/50، و NAT = ~$32/شهر على الفاضي |
| الـ secrets | Terraform بيولّدها ويكتبها في SSM | `openssl` بإيدك (20) | مصدر واحد، و reproducible؛ الثمن: الـ secrets في الـ state (bucket مشفّر) |
| الدخول | SSM (افتراضي) | SSH | مفيش 22، مفيش keys، IAM + CloudTrail |
| الـ release | image من ECR بالـ SHA | build على السيرفر | build once, deploy many |

## 2) المعمارية (Architecture)

```text
 WSL (أنت)                                               AWS us-east-1
 ─────────                                               ─────────────
 terraform ── S3 state (stacks/20-ec2-single) ──► VPC 10.20.0.0/16 (student-app-lab)
                                                   public  10.20.0.0/20  (az a) ─┐  IGW, no NAT
                                                   public  10.20.16.0/20 (az b)  │  S3 gateway endpoint
                                                   private 10.20.128.0/20, .144.0/20 (فاضيين)
                                                          │
                                                  ┌───────┴─ EC2 student-app-lab-app (t3.small, AL2023)
                                                  │  tags: Project, Env=lab, Scenario=20, Role=app
                                                  │  SG student-app-lab-app-host: in 80 (http_cidrs) · 22 فقط لو ssh_cidrs
                                                  │                               out 80/443 فقط
                                                  │  IMDSv2 (hop limit 1) · gp3 20GiB encrypted · EIP
                                                  │  role student-app-lab-ec2-single:
                                                  │    SSM core · CloudWatch agent · ECR pull (student-app)
                                                  │    ssm:GetParameters* /student-app/lab/* · kms:Decrypt via SSM
                                                  │    s3 Get/Put student-app-lab-backups-<acct>
                                                  └─────────────────────────────────────────
                                                  SSM /student-app/lab/app/*  (APP_KEY, DB_PASSWORD, SRE_LAB_TOKEN = SecureString)
                                                  SSM /student-app/lab/mysql/*
                                                  S3  student-app-lab-backups-<acct> (expire 30d) ── [27]

 ansible-playbook ── aws_ec2 inventory (DescribeInstances, tag:Project=student-app)
        │            groups: role_app · standalone · env_lab · scenario_20 · az_us_east_1a
        └── amazon.aws.aws_ssm ──► session-manager-plugin ──► SSM ──► agent على الـ instance
                 ملفات الـ modules ⇄ S3 student-app-ansible-ssm-<acct> (presigned URLs، expire 1 day)
```

## 3) المتطلبات (Prerequisites)

- [ ] [02](02-aws-account-setup.md): bootstrap معمول، `infra/terraform/backend.hcl` موجود، و `AWS_PROFILE=student-lab-admin` + `aws sso login`.
- [ ] image في ECR بـ tag = short SHA ([30](30-ci-github-actions.md)): `aws ecr describe-images --repository-name student-app --query 'imageDetails[].imageTags[]'`.
- [ ] مفيش stack تاني (40/50/60) شغال على نفس `env` — كلهم بيكتبوا `/student-app/lab/app/*`.
- [ ] WSL فيه: `terraform` ≥ 1.10، Python venv بـ Ansible (§5.5)، `session-manager-plugin`، `jq`، والـ repo **جوه** الـ WSL filesystem (مش `/mnt/c/...`).

## 4) الطريقة الأولى: AWS Console (يدوي)

الـ Console path الكامل هو [20](20-ec2-compose-console.md). هنا الـ Console للمراجعة بعد الـ apply — اتعلّم تقرا اللي Terraform عمله:

1. **VPC → Your VPCs** → `student-app-lab` → **Resource map**: 4 subnets، route table public فيها `0.0.0.0/0 → igw`، وS3 gateway endpoint.
2. **VPC → Security groups** → `student-app-lab-default-deny`: الـ default SG من غير rules (CIS). و `student-app-lab-app-host`: inbound 80 بس، outbound 80/443 بس (مش "All traffic" زي 20).
3. **EC2 → Instances** → `student-app-lab-app` → تاب **Tags** (لاحظ `Role=app` — ده اللي Ansible بيعمل منه `role_app`)، و **Security → IAM Role**، و **Details → IMDSv2 = Required**.
4. **IAM → Roles → `student-app-lab-ec2-single`** → policies: `AmazonSSMManagedInstanceCore`، `CloudWatchAgentServerPolicy`، و inline `student-app-host` (قارنها بالـ inline policy اللي كتبتها في [20 §4.3](20-ec2-compose-console.md)).
5. **Systems Manager → Parameter Store** → فلتر `/student-app/lab/` → لاحظ `Type` وإن الـ Description `Managed by Terraform (stacks/20-ec2-single)`.
6. **Systems Manager → Fleet Manager** → الـ instance لازم يبقى **Online** (ده شرط Session Manager و Run Command و Ansible over SSM).
7. **S3 → `student-app-lab-backups-<acct>` → Management → Lifecycle rules** → `expire-dumps` (30 يوم).

> 💡 أي تعديل هنا بإيدك = **drift**. جرّب: زوّد rule في الـ SG من الـ Console، وبعدين `terraform plan` هيقولك إنه هيشيلها. ده درس [91](91-terraform-import-and-drift.md).

## 5) الطريقة التانية: Infrastructure as Code (Terraform + Ansible)

### 5.1 الـ variables (من [`variables.tf`](../../../infra/terraform/stacks/20-ec2-single/variables.tf))

| Variable | الافتراضي | ملاحظات |
|---|---|---|
| `project` / `env` / `region` | `student-app` / `lab` / `us-east-1` | `env` = جزء من أسماء الموارد ومسار SSM |
| `scenario` | `"20"` | tag بس — غيّره للسيناريو اللي بتعمله (`-var scenario=32`) |
| `vpc_cidr` | `10.20.0.0/16` | |
| `instance_type` / `arch` | `t3.small` / `x86_64` | `t3.micro` يكفي لو pull بس (32/33)؛ `arm64` + `t4g.small` محتاج image arm64 |
| `ami_id` | `null` | `null` = آخر AL2023 من الـ SSM public parameter؛ أو golden AMI ([43](43-golden-ami-packer.md)) |
| `http_cidrs` | `["0.0.0.0/0"]` | ضيّقه لـ IP بتاعك `/32` (اقرا تحذير `/metrics` في [20 §4.2](20-ec2-compose-console.md)) |
| `ssh_cidrs` / `key_name` | `[]` / `null` | لسيناريو 31 والـ SSH mode بس |
| `ecr_repository_name` | `student-app` | |
| `db_name` / `db_username` | `student_app` / `student` | |
| `sre_lab_enabled` | `true` | أبداً على production حقيقي |
| `backup_retention_days` / `backup_bucket_force_destroy` | `30` / `true` | [27](27-mysql-backup-restore.md) |

### 5.2 الـ stack بيعمل إيه بالظبط

- **`module.network`**: VPC + IGW + 2 public subnets (`map_public_ip_on_launch`) + 2 private (من غير route للإنترنت) + S3 gateway endpoint مجاني + `aws_default_security_group` فاضي.
- **`module.host`** ([`ec2-docker-host`](../../../infra/terraform/modules/ec2-docker-host/main.tf)):
  - الـ AMI من `/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-<arch>` — مفيش AMI ID hardcoded.
  - `user_data = file(".../deploy/ec2/user-data.sh")` — **نفس السكريبت** اللي لصقته في الـ Console في 20.
  - IMDSv2 `http_tokens = required` و `http_put_response_hop_limit = 1` → الـ containers على الـ docker bridge **مش هتوصل** للـ IMDS، يعني الـ app container مستحيل "يستلف" الـ instance role.
  - `credit_specification = standard` → عمرك ما هتدفع زيادة عن سعر الساعة حتى وانت بتعمل `/sre-lab/cpu` load test.
  - `lifecycle { ignore_changes = [ami, user_data] }` → AMI أحدث أو تعديل في `user-data.sh` **مش** هيستبدل السيرفر (عليه MySQL). الاستبدال عن قصد: `terraform apply -replace=module.host.aws_instance.this`.
  - SG ingress بـ `setproduct(ingress_cidrs, ingress_ports)`، و SSH rule بيتعمل **بس** لو `ssh_cidrs` مش فاضي.
  - EIP (`create_eip = true`).
- **IAM** ([`iam.tf`](../../../infra/terraform/stacks/20-ec2-single/iam.tf)): role + instance profile بنفس الاسم `student-app-lab-ec2-single`.
- **Backups bucket**: SSE-S3، public access block، TLS-only policy، lifecycle 30 يوم ([27](27-mysql-backup-restore.md)).
- **SSM parameters** (§5.3).

### 5.3 الـ SSM parameters و `APP_KEY` المتولّد في Terraform

من [`ssm.tf`](../../../infra/terraform/stacks/20-ec2-single/ssm.tf):

| Path | Type | القيمة |
|---|---|---|
| `/student-app/lab/app/APP_URL` | String | `http://<EIP>` |
| `.../app/DB_CONNECTION`, `DB_HOST`, `DB_PORT`, `DB_DATABASE`, `DB_USERNAME` | String | `mysql`، `mysql` (اسم الـ compose service)، `3306`، `student_app`، `student` |
| `.../app/SESSION_DRIVER`, `CACHE_STORE` | String | `database` |
| `.../app/SRE_LAB_ENABLED`, `METRICS_ENABLED` | String | `true` |
| `.../app/APP_KEY` | **SecureString** | `base64:` + `random_bytes.app_key` (32 byte) |
| `.../app/DB_PASSWORD`, `SRE_LAB_TOKEN` | **SecureString** | `random_password` (32 حرف alphanumeric) |
| `/student-app/lab/mysql/MYSQL_DATABASE`, `MYSQL_USER` | String | |
| `.../mysql/MYSQL_PASSWORD` | SecureString | **نفس** `random_password.db` (الـ app والـ MySQL user لازم يتطابقوا) |
| `.../mysql/MYSQL_ROOT_PASSWORD` | SecureString | |

نقاط senior:

- `APP_ENV=production` و `APP_DEBUG=false` مش في SSM هنا لأنهم **defaults جوه الـ image** (`ENV` في [`docker/Dockerfile`](../../../docker/Dockerfile)).
- الـ passwords **alphanumeric بس** (`special = false`) لأنها بتعدّي على env files وshells وcompose interpolation — `$` أو `#` في باسورد = bug صعب تلاقيه.
- `for_each = toset(local.app_secret_keys)` على **قائمة أسماء** مش على map القيم: Terraform مبيسمحش لـ map فيها sensitive values إنها تسوق `for_each`.
- الـ String params بـ `insecure_value` (بيظهر في الـ plan)، والـ SecureString بـ `value` (sensitive).
- **الثمن:** كل الـ secrets دي في الـ state. الـ state bucket مشفّر و TLS-only، بس **أي حد يقرا الـ bucket يقرا الـ secrets**. البديل: Terraform يعمل الـ parameter بقيمة placeholder + `ignore_changes = [value]` وحد تاني يحط القيمة، أو Secrets Manager مع rotation ([81](81-secrets-management.md)).
- **`APP_KEY` rotation** = `terraform apply -replace=random_bytes.app_key` → كل الـ sessions والـ encrypted data بتبوظ. مش زرار تدوس عليه عشوائي.

### 5.4 الـ apply

```bash
export AWS_PROFILE=student-lab-admin && aws sso login --sso-session student
cd infra/terraform/stacks/20-ec2-single
cp terraform.tfvars.example terraform.tfvars        # scenario tag بس (سيبه "20" أو "21" — لو غيّرته افتكر EC2_TARGET_SCENARIO في [32])، و http_cidrs لو عايز
terraform init -backend-config=../../backend.hcl
terraform plan -out=tfplan                          # ~30 resource
terraform apply tfplan

terraform output
# instance_id, public_ip, public_dns, app_url, ssm_start_session, backup_bucket, ssm_prefix,
# ecr_repository_url, sre_lab_token (sensitive)
terraform output -raw sre_lab_token; echo
```

بديل من غير اللابتوب: **Actions → Terraform → Run workflow** → stack `20-ec2-single` → action `apply` ([`terraform.yml`](../../../.github/workflows/terraform.yml)، تفاصيله في [92](92-terraform-in-ci.md)).

### 5.5 Session Manager — أول دخول

```bash
$(terraform output -raw ssm_start_session)          # aws ssm start-session --target i-... --region us-east-1
# جوه الـ session:
cat /opt/student-app/.bootstrapped                  # user-data finished: ...
docker compose version && free -h
exit
```

لو `TargetNotConnected`: استنى 2–5 دقايق (cloud-init + agent registration)، وتأكد من Fleet Manager.

### 5.6 تجهيز Ansible (WSL)

```bash
sudo apt-get update && sudo apt-get install -y python3-venv unzip
python3 -m venv ~/.venvs/ansible && source ~/.venvs/ansible/bin/activate
pip install "ansible-core>=2.18,<2.22" "boto3>=1.38" "botocore>=1.38" ansible-lint
curl -fsSLo /tmp/smp.deb https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb
sudo dpkg -i /tmp/smp.deb && session-manager-plugin --version
cd ~/src/StudentHub/infra/ansible                   # repo جوه WSL، مش /mnt/c
ansible-galaxy collection install -r requirements.yml   # amazon.aws 12.x, community.aws 12.x, community.docker 5.x
ansible --version | head -3                          # config file = .../infra/ansible/ansible.cfg
```

> ⚠️ لو `ansible --version` بيقول `config file = None`: انت في directory world-writable (`/mnt/c/...`) و Ansible بيتجاهل `ansible.cfg` لأسباب أمنية → الـ inventory والـ roles مش هيتلاقوا. الحل: clone جوه `~` أو `export ANSIBLE_CONFIG=$PWD/ansible.cfg`.

### 5.7 اختبار الـ inventory

```bash
aws sts get-caller-identity                          # الـ plugin بيستخدم نفس الـ credentials
ansible-inventory --graph
# @all:
#   |--@aws_ec2:            i-0abc...
#   |--@role_app:           i-0abc...
#   |--@env_lab:            i-0abc...
#   |--@scenario_21:        i-0abc...     (أو scenario_20 حسب الـ tag)
#   |--@az_us_east_1a:      i-0abc...
#   |--@standalone:         i-0abc...     ← مفيش tag aws:autoscaling:groupName
IID=$(terraform -chdir=../terraform/stacks/20-ec2-single output -raw instance_id)
ansible-inventory --host "$IID" | jq '{ansible_host, ansible_aws_ssm_instance_id, tags}'
```

ليه الـ hostname = instance id؟ فريد وثابت وهو بالظبط اللي SSM محتاجه كـ target؛ الـ Name tag أو الـ DNS ممكن يتغيّروا. والـ groups `standalone` / `in_asg` ([`aws_ec2.yml`](../../../infra/ansible/inventories/lab/aws_ec2.yml)) هما اللي بيمنعوا `deploy.yml` إنه يلمس instance في ASG بالغلط (الـ playbooks الـ single-host كلها `hosts: role_app:&standalone`).

### 5.8 الـ connection: SSM (افتراضي) أو SSH

```bash
SSM_BUCKET=$(terraform -chdir=../terraform/bootstrap output -raw ansible_ssm_bucket)
export ANSIBLE_EXTRA="-e ssm_bucket_name=$SSM_BUCKET"
ansible role_app -m ansible.builtin.ping $ANSIBLE_EXTRA          # i-0abc... | SUCCESS => {"ping": "pong"}
```

إزاي بيشتغل ([`group_vars/all/main.yml`](../../../infra/ansible/inventories/lab/group_vars/all/main.yml)): `deploy_connection: ssm` → `ansible_connection: amazon.aws.aws_ssm`؛ الـ plugin بيفتح session بالـ session-manager-plugin، ويرفع ملفات الـ module للـ bucket، والـ instance بينزّلها بـ `curl` على presigned URL → **الـ instance مش محتاج أي S3 permission**، والـ controller (انت) هو اللي محتاج write على الـ bucket. (الـ transfer bucket = bootstrap `ansible_ssm_bucket` (`SSM_BUCKET` في الـ [README](../../../infra/ansible/README.md)): objects بتتمسح بعد يوم، وده نفس اللي الـ CI بيستخدمه في [33](33-cd-ec2-ansible.md). متخلطوش بالـ backups bucket بتاع stack 20 (`BACKUP_BUCKET`) — ده للـ dumps بس ([27](27-mysql-backup-restore.md)).)

| | SSM (`deploy_connection: ssm`) | SSH (`-e deploy_connection=ssh`) |
|---|---|---|
| الشبكة | outbound 443 بس، مفيش 22 | 22 مفتوح لك (`ssh_cidrs`) |
| الـ credentials | IAM مؤقتة (`ssm:StartSession`) | private key مبيخلصش |
| الـ audit | CloudTrail + session history | sshd logs على box ممكن يتمسح |
| السرعة | أبطأ (session + S3 لكل module) | أسرع (pipelining + ControlPersist في `ansible.cfg`) |
| Setup زيادة | plugin + bucket | key pair + `key_name` |

عشان تجرّب SSH (اختياري، نفس setup [31](31-cd-ec2-ssh-build-on-server.md)):

```bash
aws ec2 create-key-pair --key-name student-app-lab --key-type ed25519 --query KeyMaterial --output text > ~/.ssh/student-app-lab.pem
chmod 600 ~/.ssh/student-app-lab.pem
# terraform.tfvars:  ssh_cidrs = ["<YOUR_IP>/32"]   key_name = "student-app-lab"
terraform -chdir=../terraform/stacks/20-ec2-single plan     # ⚠️ key_name على instance موجود = replace (المkey بيتحط وقت الـ launch بس)
ansible role_app -m ansible.builtin.ping -e deploy_connection=ssh --private-key ~/.ssh/student-app-lab.pem
```

> ⚠️ `key_name` بيتطبّق وقت الـ launch بس، فتغييره على instance شغال = **instance جديد** (وMySQL القديمة بتروح). قرّر قبل أول apply، أو اكتفي بـ SSM.

### 5.9 `provision.yml` — الـ baseline

```bash
ansible-playbook playbooks/provision.yml $ANSIBLE_EXTRA
```

| Role | بيعمل إيه | ليه |
|---|---|---|
| [`common`](../../../infra/ansible/roles/common/tasks/main.yml) | git/jq/curl-minimal/unzip/tar، timezone `Africa/Cairo`، swap 2G (`creates:` guard + temp file ثم rename)، sysctl (`somaxconn`، `tcp_max_syn_backlog`، `swappiness=10`)، journald cap (200M/14 يوم)، `dnf-automatic` security-only | baseline قابل للتكرار؛ مفيش reboot تلقائي (الـ kernel fixes بتيجي بـ AMI جديدة) |
| [`docker`](../../../infra/ansible/roles/docker/tasks/main.yml) | Docker من AL2023، Compose `v2.39.4` و Buildx `v0.39.1` **pinned** (versioned files + symlink)، `daemon.json` (log rotation + `live-restore`)، `ec2-user` في group docker | الـ user-data بينزّل Buildx "latest" — هنا بنثبّت النسخة؛ و `live-restore` يخلّي الـ containers تعيش لو dockerd اتعمله restart |
| [`cloudwatch_agent`](../../../infra/ansible/roles/cloudwatch_agent/tasks/main.yml) | mem/swap/disk metrics + logs الـ containers و cloud-init لـ `/student-app/lab/ec2/*` (retention 7 أيام) | [70](70-logging.md)/[71](71-metrics-dashboards.md) |
| [`node_exporter`](../../../infra/ansible/roles/node_exporter/tasks/main.yml) | `prom/node-exporter:v1.13.1` بـ host network/pid، read-only، cap_drop ALL | بورت 9100 **مش** مفتوح في الـ SG — scrape من جوه الـ VPC أو SSM port-forward |

> 💡 الـ handlers في الـ docker role: `Reload docker` قبل `Restart docker` عن قصد — الـ reload (SIGHUP) بيفعّل `live-restore` الأول، فالـ restart اللي بعده مبيوقفش الـ containers.

### 5.10 `deploy.yml -e app_image=...` — الـ release

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
TAG=$(aws ecr describe-images --repository-name student-app \
      --query 'sort_by(imageDetails,&imagePushedAt)[-1].imageTags[0]' --output text)
IMG=$ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/student-app:$TAG
ansible-playbook playbooks/deploy.yml -e app_image=$IMG $ANSIBLE_EXTRA
```

الـ role [`app`](../../../infra/ansible/roles/app/tasks/main.yml) خطوة بخطوة:

| # | Task file | بيعمل إيه | Idempotent إزاي |
|---|---|---|---|
| 0 | `main.yml` assert | `app_image` مش فاضي، **مش `:latest`**، فيه `/` أو `:` | يفشل بدري برسالة واضحة |
| 1 | [`files.yml`](../../../infra/ansible/roles/app/tasks/files.yml) | `/opt/student-app` (owner `ec2-user`)، `docker-compose.prod.yml`، `render-env-from-ssm.sh` + `deploy-pull-image.sh` + `backup-mysql-to-s3.sh` (0755)، `compose.awslogs.yml` | `copy` بيقارن checksum |
| 2 | [`env.yml`](../../../infra/ansible/roles/app/tasks/env.yml) | يشغّل `render-env-from-ssm.sh` في **staging dir** (`.env-staging`)، وبعدين `copy remote_src` لـ `app.env`/`mysql.env` (owner `app_owner` = `ec2-user`، mode 0600)، و `diff: false` + `no_log` في الـ vault path | السكريبت دايماً بيعيد الكتابة، فالـ copy هو اللي بيقرر "اتغيّر ولا لأ" → `app_env_changed` |
| 3 | [`deploy.yml`](../../../infra/ansible/roles/app/tasks/deploy.yml) | يقرا `CURRENT_RELEASE`؛ يشغّل `deploy-pull-image.sh <image>` (بـ `RENDER_ENV=false`) **بس لو** الـ image اتغيّرت (المقارنة بتتجاهل `@sha256:…`، فـ `repo:tag` و `repo:tag@digest` بتاع [32](32-cd-ec2-ecr-ssm.md) = نفس الـ release) أو الـ env اتغيّر أو `app_force_deploy` | الـ deploy نفسه (pull → migrate → recreate) مش idempotent، فبنحميه بشرط |
| 4 | [`smoke.yml`](../../../infra/ansible/roles/app/tasks/smoke.yml) | `GET http://127.0.0.1/ready` لحد `status == ready` (20 × 3s) ويطبع الـ version | read-only |

### 5.11 إثبات الـ idempotency

```bash
ansible-playbook playbooks/provision.yml $ANSIBLE_EXTRA | tail -4
ansible-playbook playbooks/deploy.yml -e app_image=$IMG $ANSIBLE_EXTRA | tail -4
# PLAY RECAP *********************************************************************
# i-0abc...  : ok=NN   changed=0    unreachable=0    failed=0    skipped=N    rescued=0    ignored=0

ansible-playbook playbooks/deploy.yml -e app_image=$IMG $ANSIBLE_EXTRA --check --diff   # dry run: إيه اللي كان هيتغيّر
```

التشغيل الأول: `changed` كتير (provision) أو كام واحد (deploy). **التاني: `changed=0`** ومهمة "Deploy …" **skipped**. لو شفت `changed` في التشغيل التاني يبقى فيه task مش idempotent — ده bug في الـ role (أشهر الأسباب: `command`/`shell` من غير `changed_when`، template فيه timestamp، أو ملف بيتولّد بترتيب مختلف).

> 💡 `--check` مبيشغّلش `command`/`shell` (مش بيدعموا check mode) فـ"Deploy" هيظهر skipped. يعني check mode بيوريك تغييرات الملفات، مش نتيجة السكريبتات.

### 5.12 Vault — بديل SSM (اختياري، [93](93-ansible-deep-dive.md))

```bash
cd inventories/lab/group_vars/all
cp vault.yml.example vault.yml                    # vault.yml متجاهَل في git في المعمل
# حط قيم حقيقية: vault_app_key ("base64:" + openssl rand -base64 32)، vault_db_password، ...
ansible-vault encrypt vault.yml
openssl rand -base64 32 > ~/.vault-pass-student-app && chmod 600 ~/.vault-pass-student-app   # (أو passphrase من password manager)
cd ../../../..
ansible-playbook playbooks/deploy.yml -e app_image=$IMG -e app_env_source=vault \
  --vault-password-file ~/.vault-pass-student-app $ANSIBLE_EXTRA
ansible-vault edit inventories/lab/group_vars/all/vault.yml --vault-password-file ~/.vault-pass-student-app
```

**SSM مقابل vault:** مع SSM الـ secret عمره ما بيعدّي على الـ controller (السيرفر بيقراه بالـ instance profile)، ومصدر الحقيقة واحد لـ EC2/ECS/EKS. مع vault الـ secret في git مشفّر وبيتكتب من الـ controller — مناسب لو مفيش AWS API (on-prem). خلي بالك: `DB_PASSWORD` في الـ vault لازم يطابق اللي MySQL اتعمل بيه أول مرة.

## 6) الـ Deploy

### 6.1 الطريق الكامل (Terraform → Ansible)

```bash
cd ~/src/StudentHub/infra/terraform/stacks/20-ec2-single
terraform apply tfplan
cd ../../../ansible && source ~/.venvs/ansible/bin/activate
export ANSIBLE_EXTRA="-e ssm_bucket_name=$(terraform -chdir=../terraform/bootstrap output -raw ansible_ssm_bucket)"
ansible-inventory --graph
ansible-playbook playbooks/provision.yml $ANSIBLE_EXTRA
ansible-playbook playbooks/deploy.yml -e app_image=$IMG $ANSIBLE_EXTRA
ansible-playbook playbooks/deploy.yml -e app_image=$IMG $ANSIBLE_EXTRA      # changed=0
```

الـ seed (مرة واحدة، من Session Manager — `app.env` ملك `ec2-user`، فتشتغل بيه زي [20](20-ec2-compose-console.md)):

```bash
sudo su - ec2-user
cd /opt/student-app
export APP_IMAGE="$(cat CURRENT_RELEASE)" APP_ENV_FILE=/opt/student-app/app.env MYSQL_ENV_FILE=/opt/student-app/mysql.env
docker compose -f docker-compose.prod.yml run --rm --no-deps app php artisan db:seed --class=DemoSeeder --force
```

### 6.2 الـ variant: build على السيرفر (نفس 20، على host بتاع Terraform)

```bash
$(terraform -chdir=../terraform/stacks/20-ec2-single output -raw ssm_start_session)
sudo -i                                             # root: CURRENT_RELEASE/PREVIOUS_RELEASE كتبهم deploy-pull-image.sh كـ root
cd /opt/student-app
git clone https://github.com/Ahmed-Reda-Ragab/StudentHub.git src
cd src && git switch devops-lab
APP_DIR=/opt/student-app bash deploy/ec2/render-env-from-ssm.sh
bash deploy/ec2/deploy-build-on-server.sh devops-lab      # t3.small + swap: ~5–10 دقايق
```

> ⚠️ خلط الطريقتين على نفس الـ host: Ansible بيكتب `app.env`/`mysql.env` ملك `ec2-user` (0600) فـ `ec2-user` يقدر يشغّل `docker compose` عادي، بس `CURRENT_RELEASE`/`PREVIOUS_RELEASE` اللي `deploy-pull-image.sh` كتبهم كـ root مش هيتكتب فوقهم من `ec2-user` — عشان كده الـ build هنا بـ `sudo -i`. وخلي بالك إن `render-env-from-ssm.sh` كـ root بيكتب `app.env` ملك root → أول `deploy.yml` بعدها هيرجّع الـ owner (changed → recreate). و `CURRENT_RELEASE` بعد الـ build = `student-app:<sha>` (local)، فأي `deploy.yml` بعدها هيعمل deploy تاني للـ ECR URI — وده صح.

## 7) التحقق (Verify)

```bash
HOST=$(terraform -chdir=../terraform/stacks/20-ec2-single output -raw public_ip)
TOKEN=$(terraform -chdir=../terraform/stacks/20-ec2-single output -raw sre_lab_token)
curl -s http://$HOST/ready | jq                                  # status ready، version = $TAG
curl -s -H "X-Lab-Token: $TOKEN" http://$HOST/sre-lab/version | jq
bash ../../deploy/scripts/probe.sh http://$HOST/ready 30 0.5

ansible role_app -b -m ansible.builtin.command -a 'cat /opt/student-app/CURRENT_RELEASE' $ANSIBLE_EXTRA
ansible role_app -b -m ansible.builtin.command -a 'stat -c "%U:%G %a %n" /opt/student-app/app.env' $ANSIBLE_EXTRA   # ec2-user:ec2-user 600
ansible role_app -b -m ansible.builtin.command -a 'docker ps' $ANSIBLE_EXTRA      # ({{ }} في -a بيتفسّر Jinja، فبلاش --format هنا)
aws ssm get-parameters-by-path --path /student-app/lab/app --query 'Parameters[].[Name,Type]' --output table
```

المفروض: `/ready` = ready بنفس الـ tag اللي في `CURRENT_RELEASE`، `app` و `mysql` و `node-exporter` شغالين، والتشغيل التاني للـ playbooks `changed=0`.

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر | المتوقع |
|---|---|---|
| `:latest` | `ansible-playbook playbooks/deploy.yml -e app_image=$ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/student-app:latest $ANSIBLE_EXTRA` | يفشل في أول task: `':latest' is not allowed - CONVENTIONS §2` |
| tag مش موجود | `-e app_image=...:deadbee` | `deploy-pull-image.sh` يفشل في `compose pull` (`manifest unknown`) — والـ container القديم لسه شغال (الـ pull قبل الـ recreate) |
| Drift في الـ config | من Session Manager: `sudo sed -i 's/^LOG_LEVEL=.*//' /opt/student-app/app.env` ثم `deploy.yml` بنفس الـ image | `Install env files rendered from SSM` = changed → `app_env_changed` → redeploy حتى لو الـ image نفسها |
| Parameter اتغيّر | `aws ssm put-parameter --name /student-app/lab/app/LOG_LEVEL --type String --value debug --overwrite` ثم `deploy.yml` | نفس اللي فوق: الـ env اتغيّر → recreate. امسحه بعدها |
| من غير SSM bucket | `ansible role_app -m ping` (من غير `$ANSIBLE_EXTRA`) | الـ aws_ssm plugin يفشل لأن `ansible_aws_ssm_bucket_name` فاضي |
| config file متجاهَل | شغّل من `/mnt/c/...` | `config file = None` و `Could not match supplied host pattern` |
| Drift في Terraform | زوّد SG rule من الـ Console ثم `terraform plan` | الـ plan هيشيلها |
| تعديل `user-data.sh` | عدّل comment وبعدين `terraform plan` | **No changes** (`ignore_changes`) — الاستبدال لازم `-replace` |

## 9) الرجوع (Rollback)

```bash
ansible-playbook playbooks/rollback.yml $ANSIBLE_EXTRA          # auto: مفيش lb/state → يعيد deploy لـ PREVIOUS_RELEASE
ansible-playbook playbooks/deploy.yml -e app_image=$ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/student-app:<OLD_TAG> $ANSIBLE_EXTRA
# أو على السيرفر:
sudo /opt/student-app/deploy-pull-image.sh rollback
```

> ⚠️ الـ migrations مبترجعش ([95](95-zero-downtime-db-migrations.md)). و `docker image prune -af --filter until=168h` في السكريبت ممكن يكون مسح الـ image القديمة → الـ rollback هيعمل pull تاني من ECR (عشان كده الـ registry مصدر الحقيقة، مش الـ host).

## 10) المسح (Teardown) ⚠️

```bash
cd ~/src/StudentHub/infra/terraform/stacks/20-ec2-single
# لو عايز نسخة من الداتا: [27] backup → aws s3 cp لمكان برّه الـ bucket (الـ bucket بيتمسح مع الـ stack)
terraform destroy

# اللي Terraform مبيملكوش (اتعمل من الـ agents) — retention 7 أيام بس امسحه لو مش محتاجه:
aws logs describe-log-groups --log-group-name-prefix /student-app/lab --query 'logGroups[].logGroupName'
aws logs delete-log-group --log-group-name /student-app/lab/ec2/docker
aws logs delete-log-group --log-group-name /student-app/lab/ec2/cloud-init
aws ec2 delete-key-pair --key-name student-app-lab 2>/dev/null; rm -f ~/.ssh/student-app-lab.pem

aws resourcegroupstaggingapi get-resources --tag-filters Key=Project,Values=student-app --query 'ResourceTagMappingList[].ResourceARN'   # المفروض الـ bootstrap بس
aws ec2 describe-addresses --query 'Addresses[].PublicIp'
```

- [ ] `terraform destroy` خلص من غير errors · [ ] مفيش EIP · [ ] log groups بتاعة الـ agent ممسوحة أو مقبولة · [ ] key pair ممسوح

## 11) التكلفة (Cost)

| Resource | السعر التقريبي (us-east-1، تقريبي — راجع صفحة الأسعار) |
|---|---|
| EC2 `t3.small` (standard credits) | ~$0.0208/ساعة |
| EBS gp3 20 GiB | ~$1.6/شهر |
| Elastic IP / public IPv4 | ~$0.005/ساعة |
| VPC، subnets، IGW، S3 gateway endpoint | مجاني |
| SSM Standard params، Session Manager | مجاني |
| CloudWatch agent metrics (3 custom metrics) + logs | سنتات/شهر |
| **جلسة 3–4 ساعات** | **≈ $0.10–0.15** |

## 12) أسئلة Interview

<details><summary>إمتى Terraform وإمتى Ansible؟ مش الاتنين بيعملوا configuration؟</summary>

Terraform declarative للـ **lifecycle بتاع الـ resources** (create/update/destroy) مع state وdependency graph. Ansible procedural-ish idempotent للـ **جوه السيرفر** (packages، files، services) من غير state. ممكن Terraform يعمل user-data كبيرة، أو Ansible يعمل EC2، بس كل واحد هيبقى ضعيف: user-data بتجري مرة وصعب تعمل لها drift detection، و Ansible مالوش state يعرف بيه إيه يتمسح. الاتجاه الحديث: Terraform للـ infra، و Packer + Ansible لـ golden AMI ([43](43-golden-ami-packer.md))، والـ release بالـ image.

</details>

<details><summary>إزاي تثبت إن playbook idempotent؟ وإيه اللي بيكسرها عادةً؟</summary>

شغّله مرتين وتأكد إن التانية `changed=0`، وفي الـ CI ممكن Molecule بيعمل ده تلقائي (idempotence test). أشهر الكسرات: `command`/`shell` من غير `creates`/`removes`/`changed_when`، templates فيها تواريخ أو ترتيب dict مش ثابت، `get_url` بـ `force`، وسكريبتات بتعيد كتابة ملف دايماً (هنا اتحلّت بـ staging dir + `copy remote_src`). والـ deploy نفسه (pull/migrate/recreate) مش idempotent بطبيعته، فبنحطه ورا شرط على الحالة (`CURRENT_RELEASE`).

</details>

<details><summary>الـ secrets اتولّدت في Terraform — إيه المشكلة؟</summary>

كلها في الـ state بـ plaintext (الـ state مش بيتشفّر field-level). لازم: bucket مشفّر، access مقفول، versioning (بس دي كمان نسخ قديمة فيها secrets)، و plan role read-only بيقدر يقراها. البدائل: `ephemeral` resources و write-only arguments في Terraform الحديث (القيمة مبتتحفظش في الـ state)، أو Terraform يعمل placeholder و`ignore_changes` والقيمة تتحط برّه، أو RDS managed master password في Secrets Manager.

</details>

<details><summary>ليه `ignore_changes = [ami, user_data]` على الـ instance؟ مش ده بيخبّي drift؟</summary>

ده قرار واعي لـ **pet** server عليه داتا: AMI جديدة كل أسبوعين أو تعديل في سكريبت كان هيعمل replace صامت في أي `apply` → MySQL تروح. التكلفة إن التغيير ده محتاج `-replace` عن قصد. في الـ ASG (cattle) العكس: أي تغيير = launch template version جديدة + instance refresh ([44](44-rolling-instance-refresh.md)).

</details>

<details><summary>Ansible over SSM بيشتغل إزاي من غير بورت 22؟ وليه محتاج S3 bucket؟</summary>

الـ plugin بيفتح Session Manager session (الـ agent على السيرفر عامل outbound 443 لـ SSM)، وبيبعت الأوامر جوه الـ session. نقل الملفات (Python modules) جوه الـ session بطيء وغير موثوق، فالـ controller بيرفعها لـ S3 ويبعت للسيرفر presigned URL ينزّلها بـ curl. الـ IAM المطلوب على الـ controller: `ssm:StartSession`/`TerminateSession` + S3 على الـ bucket؛ السيرفر محتاج SSM core بس.

</details>

<details><summary>الـ dynamic inventory بيعمل groups إزاي؟ وإزاي بتحمي الـ ASG instances من deploy غلط؟</summary>

`keyed_groups` من الـ tags (`Role=app` → `role_app`، `Env=lab` → `env_lab`...) و `groups` بـ Jinja conditions: `standalone` = مفيش `aws:autoscaling:groupName`، `in_asg` = فيه. الـ playbooks بتستخدم intersection (`role_app:&standalone`)، فـ `deploy.yml` عمره ما يلمس instance immutable في ASG (اللي بيتعمله release بـ instance refresh أو `rolling-asg.yml`).

</details>

## 13) Checklist

- [ ] `terraform apply` للـ stack 20 وقريت الـ outputs
- [ ] فهمت كل SSM param ومنين `APP_KEY` اتولّد وإيه ثمنه
- [ ] دخلت بـ Session Manager من `ssm_start_session`
- [ ] `ansible-inventory --graph` بيطلّع `role_app` و `standalone`
- [ ] `provision.yml` و `deploy.yml` عدّوا، والتشغيل التاني `changed=0`
- [ ] جرّبت SSM و (اختياري) SSH، و (اختياري) vault
- [ ] جرّبت الـ break-it والـ rollback
- [ ] `terraform destroy` + تنضيف الـ log groups
