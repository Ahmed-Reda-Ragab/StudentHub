# 93 — Ansible بالتفصيل (roles، vault، dynamic inventory)

> **الهدف في سطر:** تفهم [`infra/ansible`](../../../infra/ansible/) بمستوى Senior: الـ inventory (static مقابل `amazon.aws.aws_ec2` الـ dynamic، الـ `keyed_groups`، و patterns زي `role_app:&standalone` و `role_app:&in_asg`)، الـ connections (SSH مقابل `amazon.aws.aws_ssm` + الـ transfer bucket)، كل role في الـ repo، أولوية الـ variables (وفخ مكان الـ `group_vars`)، الـ handlers، الـ idempotency (`changed_when`، `creates`)، check mode و diff، الـ tags، الـ vault و vault IDs، `serial` و `max_fail_percentage` في [`rolling-asg.yml`](../../../infra/ansible/playbooks/rolling-asg.yml)، ansible-lint بالـ production profile، مقدمة Molecule، وإمتى Ansible مقابل Terraform مقابل user-data مقابل golden AMI.
> **المستوى:** Intermediate → Advanced · **الوقت:** ~5 ساعات · **التكلفة التقريبية:** Ansible نفسه مجاني؛ stack 20 ≈ $0.03/ساعة، و stack 40 (للـ rolling) ≈ $0.08/ساعة
> **بيعتمد على:** [03 — تجهيز الجهاز](03-workstation-setup.md) · [21 — EC2 بـ Terraform + Ansible](21-ec2-compose-terraform-ansible.md) · [33 — CD بـ Ansible](33-cd-ec2-ansible.md) · [43 — Golden AMI](43-golden-ami-packer.md) · [47 — Rolling بـ Ansible](47-ansible-rolling-deploy.md) · **الملفات في الـ repo:** [`infra/ansible/README.md`](../../../infra/ansible/README.md) · [`ansible.cfg`](../../../infra/ansible/ansible.cfg) · [`requirements.yml`](../../../infra/ansible/requirements.yml) · [`.ansible-lint`](../../../infra/ansible/.ansible-lint) · [`inventories/lab/`](../../../infra/ansible/inventories/lab/) · [`roles/`](../../../infra/ansible/roles/) · [`playbooks/`](../../../infra/ansible/playbooks/) · [`infra/packer/app-ami.pkr.hcl`](../../../infra/packer/app-ami.pkr.hcl) · [`deploy-ec2-ansible.yml`](../../../.github/workflows/deploy-ec2-ansible.yml) · [CONVENTIONS §7](../CONVENTIONS.md)

## 1) الفكرة (Concepts)

Ansible = **agentless push configuration management**: الـ controller (WSL أو GitHub runner) بيوصل للسيرفرات (SSH أو SSM)، بيبعت **modules** صغيرة (Python) تنفّذ وتقول `ok` / `changed` / `failed`، وبيمسحها. كل task بتوصف **حالة** ("الـ package ده موجود"، "الملف ده بالمحتوى ده") مش أمر — فلو الحالة موجودة الـ task بيقول `ok` ومبيعملش حاجة (**idempotency**).

```text
 playbook ─► plays (hosts: pattern) ─► tasks / roles ─► modules على كل host  ─► ok | changed | failed | skipped
                         │                                   │
                inventory (مين؟) ◄── aws_ec2 plugin       handlers (تتنفذ مرة في الآخر لو حد عمل notify)
```

**فلسفة الـ repo** ([README](../../../infra/ansible/README.md)): الـ roles **مش بتعيد كتابة** منطق الـ deploy — بتنسخ وتشغّل نفس السكريبتات اللي باقي المعمل بيستخدمها (`deploy/ec2/*.sh`، `deploy/ec2/lb/bin/*.sh`، `docker-compose.prod.yml`). يعني الـ deploy بيتصرف بنفس الشكل من Ansible أو SSM Run Command أو shell على السيرفر. Ansible هنا **orchestrator**.

| المصطلح | المعنى |
|---|---|
| Inventory | قايمة الـ hosts والـ groups (ملف ثابت أو plugin بيسأل AWS) |
| Pattern | اختيار hosts: `role_app`، `role_app:&standalone` (تقاطع)، `role_app:!in_asg` (استبعاد) |
| Role | وحدة قابلة لإعادة الاستخدام: `defaults/ tasks/ handlers/ templates/ meta/` |
| Collection | حزمة modules/plugins (`amazon.aws`، `community.aws`، `community.docker`) |
| Facts | معلومات عن الـ host (`ansible_architecture`) — `gather_facts` |
| Handler | task بيتنفذ **مرة واحدة** في آخر الـ section لو اتعمله notify |
| Check mode / diff | `--check` = dry run، `--diff` = يوريك الفرق في الملفات |
| Vault | تشفير ملفات/قيم بـ AES256 جوه الـ repo |

## 2) المعمارية (Architecture)

```text
 Controller: WSL Ubuntu (venv: ansible-core + boto3) أو GitHub runner (deploy-ec2-ansible.yml)
   │
   ├─ ansible.cfg (لازم تشغّل من infra/ansible/)  → inventory = inventories/lab/aws_ec2.yml
   │
   ├─ inventories/lab/aws_ec2.yml ──EC2 DescribeInstances (tag:Project=student-app, running)──► AWS
   │     hostnames = instance-id · groups: role_app, env_lab, scenario_20, color_blue, az_..., standalone, in_asg
   ├─ inventories/lab/group_vars/all/main.yml  ← جنب الـ inventory (بيتحمّل للـ aws_ec2.yml و hosts.ini الاتنين)
   │
   ├─ deploy_connection = ssm (default):
   │     amazon.aws.aws_ssm ── session-manager-plugin ──► SSM ──► instance (outbound 443 بس، مفيش بورت 22)
   │          └─ ملفات الـ modules بتعدّي على S3 bucket (student-app-ansible-ssm-<acct>، تتمسح بعد يوم)
   │             الـ controller يكتب، والـ instance ينزّل بـ presigned URL (مالوش صلاحية S3)
   └─ deploy_connection = ssh:  ansible.builtin.ssh ──► ec2-user@public_dns :22 (stack 20 + ssh_cidrs)

 الأدوار:  provision.yml = common · docker · cloudwatch_agent · node_exporter   (وكمان Packer → golden AMI)
           deploy.yml = app · bluegreen/canary.yml = app(files,env) + nginx_lb · backup.yml = mysql_backup
           rolling-asg.yml = ASG fleet (stack 40) · rollback.yml
```

## 3) المتطلبات (Prerequisites)

- [ ] **WSL** (Ansible مبيشتغلش على Windows natively). الـ repo **جوه filesystem الـ WSL** — Ansible بيتجاهل `ansible.cfg` في فولدر world-writable زي `/mnt/c/...` (أو `export ANSIBLE_CONFIG=$PWD/ansible.cfg`).
- [ ] `ansible-core`: الـ **current** دلوقتي 2.21 (مايو 2026)؛ 2.22 مجدول نوفمبر 2026 وبيطلب Python ≥ 3.13 على الـ controller. 2.18 خلص (EOL مايو 2026) و 2.19 بيخلص نوفمبر 2026، عشان كده الـ README و [`deploy-ec2-ansible.yml`](../../../.github/workflows/deploy-ec2-ansible.yml) بيثبّتوا `>=2.20,<2.22` (الـ collections 12.x نفسها محتاجة `>= 2.18`، و `min_ansible_version` في `meta/main.yml` لسه `2.18`).
- [ ] الـ collections من [`requirements.yml`](../../../infra/ansible/requirements.yml): `amazon.aws >=12.1,<13` (آخر نسخة على Galaxy 12.1.0)، `community.aws >=12,<13`، `community.docker >=5.4,<6`.
- [ ] `session-manager-plugin` + `boto3`/`botocore >= 1.38` (للـ SSM).
- [ ] stack 20 اتعمله apply ([21](21-ec2-compose-terraform-ansible.md))، و stack 40 لتمرين الـ rolling ([47](47-ansible-rolling-deploy.md)).

```bash
python3 -m venv ~/.venvs/ansible && source ~/.venvs/ansible/bin/activate
pip install "ansible-core>=2.20,<2.22" "boto3>=1.38" "botocore>=1.38" ansible-lint
cd infra/ansible && ansible-galaxy collection install -r requirements.yml
ansible --version | head -3 && session-manager-plugin --version
export SSM_BUCKET=$(terraform -chdir=../terraform/bootstrap output -raw ansible_ssm_bucket)   # = student-app-ansible-ssm-<acct>
export ANSIBLE_EXTRA="-e ssm_bucket_name=$SSM_BUCKET"
```

## 4) من غير Ansible (للمقارنة)

| الطريقة | Idempotent؟ | ترتيب/health gates عبر hosts | مناسبة لـ |
|---|---|---|---|
| SSH + bash ([31](31-cd-ec2-ssh-build-on-server.md)) | لو كتبته كده | يدوي | سيرفر واحد، مرة |
| SSM Run Command ([32](32-cd-ec2-ecr-ssm.md)) | السكريبت بيقرر | rate control بسيط | أوامر بعيدة من غير بورت 22 |
| user-data | مرة واحدة عند أول boot | — | bootstrap لـ instance immutable |
| Packer golden AMI ([43](43-golden-ami-packer.md)) | بيتبني مرة | — | الحاجات التقيلة اللي نادراً بتتغير |
| **Ansible** | آه (modules) | `serial`، `max_fail_percentage`، `delegate_to`، `run_once` | day-2 config على hosts mutable، rolling منظّم |
| Chef / Puppet | آه | agents (pull) | fleets كبيرة بـ config دائم |

## 5) الطريقة: Ansible من جوه الـ repo

### 5.1 `ansible.cfg` سطر بسطر

| الإعداد | القيمة | ليه |
|---|---|---|
| `inventory` | `inventories/lab/aws_ec2.yml` | الـ dynamic inventory افتراضي؛ `-i` بيغيّره |
| `roles_path` | `roles` | |
| `remote_user` | `ec2-user` | AL2023 |
| `forks` | `10` | 10 hosts بالتوازي (الافتراضي 5) |
| `interpreter_python` | `auto_silent` | يكتشف Python من غير warnings |
| `stdout_callback` + `callback_result_format = yaml` | | output السكريبتات المتعدد الأسطر يبان مقروء بدل JSON |
| `host_key_checking` | `False` | **lab بس** — كل instance جديد بـ host key جديد. في production: pin للـ keys أو SSH certificates أو SSM (مفيش SSH أصلاً) |
| `[inventory] enable_plugins` | `amazon.aws.aws_ec2, host_list, ini, yaml, auto` | |
| `pipelining = True` + `ControlPersist=60s` | | SSH أسرع (modules على نفس الـ channel). آمن على AL2023 (sudo من غير tty) |

### 5.2 الـ Inventory: static مقابل dynamic

**Static** — [`hosts.ini.example`](../../../infra/ansible/inventories/lab/hosts.ini.example): نفس الـ groups بإيدك. مفيد من غير AWS calls، وهو اللي الـ CI بيستخدمه في `--syntax-check`.

**Dynamic** — [`aws_ec2.yml`](../../../infra/ansible/inventories/lab/aws_ec2.yml):

```yaml
plugin: amazon.aws.aws_ec2
regions: [us-east-1]
filters:
  tag:Project: student-app
  instance-state-name: running
hostnames:
  - instance-id              # ثابت ومميّز، وهو اللي SSM محتاجه — الـ Name والـ DNS بيتغيروا
compose:
  ansible_host: public_dns_name | default(private_ip_address, true)   # للـ SSH
  ansible_aws_ssm_instance_id: instance_id                            # للـ SSM
keyed_groups:
  - { key: tags.Role, prefix: role }              # Role=app → role_app
  - { key: tags.Env, prefix: env }                # env_lab
  - { key: tags.Scenario, prefix: scenario }      # scenario_20 / scenario_40
  - { key: tags.Color, prefix: color }            # color_blue / color_green
  - { key: placement.availability_zone, prefix: az }
groups:
  standalone: "'aws:autoscaling:groupName' not in tags"   # stack 20 (pet)
  in_asg: "'aws:autoscaling:groupName' in tags"           # stack 40 (الـ ASG بيحط الـ tag ده بنفسه)
strict: false
```

- الـ tags دي جاية من Terraform: `Role = "app"` في [stack 20](../../../infra/terraform/stacks/20-ec2-single/main.tf)، و `instance_tags` في [asg-app](../../../infra/terraform/modules/asg-app/main.tf) (بما فيها الـ `default_tags` المنسوخة — [90 §5.2](90-terraform-deep-dive.md)). من غير الـ tags دي الـ inventory فاضي.
- الحروف اللي مينفعش تبقى في اسم group (زي `-` في `us-east-1a`) بتتحول لـ `_`.
- `strict: false`: expression في `compose`/`groups` فشل (tag مش موجود) ميوقفش الـ inventory.

**الـ Patterns — حماية من الغلط:** كل playbook ليه default آمن:

| Playbook | Default hosts | ليه |
|---|---|---|
| `deploy.yml`، `bluegreen.yml`، `canary.yml`، `rollback.yml`، `backup.yml` | `role_app:&standalone` | ميلمسش instance في ASG بالغلط (الـ ASG immutable — بيتعمله release بـ instance refresh) |
| `rolling-asg.yml` | `role_app:&in_asg` | ميلمسش الـ pet بتاع stack 20 |
| `provision.yml` | `role_app` | الـ baseline للكل (والـ Packer) |

```bash
ansible-inventory --graph                                   # @role_app، @standalone، @in_asg، @color_blue ...
ansible-inventory --graph 'role_app:&in_asg'
ansible-inventory --host i-0123456789abcdef0 | jq '{ansible_host, ansible_aws_ssm_instance_id, tags}'
ansible 'role_app:&standalone' --list-hosts
ansible-playbook playbooks/deploy.yml -e target_hosts='color_green:&in_asg' --list-hosts   # override
```

### 5.3 الـ Connections: SSH مقابل SSM

الاختيار في [`group_vars/all/main.yml`](../../../infra/ansible/inventories/lab/group_vars/all/main.yml):

```yaml
deploy_connection: ssm
ssm_bucket_name: ""
ansible_connection: "{{ 'amazon.aws.aws_ssm' if deploy_connection == 'ssm' else 'ansible.builtin.ssh' }}"
ansible_aws_ssm_region: "{{ aws_region }}"
ansible_aws_ssm_bucket_name: "{{ ssm_bucket_name }}"
ansible_aws_ssm_bucket_sse_mode: AES256
```

| | SSM (الافتراضي) | SSH (`-e deploy_connection=ssh`) |
|---|---|---|
| الشبكة | outbound 443 بس، **مفيش بورت 22** | بورت 22 مفتوح ليك (`ssh_cidrs` في stack 20) |
| الـ credentials | IAM (`ssm:StartSession`) مؤقتة | private key مبيخلصش |
| Audit | CloudTrail (+ session logs اختياري) | sshd logs على box ممكن يكون اتمسح |
| Setup زيادة | `session-manager-plugin` + S3 bucket الـ **controller** يكتب فيه | key pair |
| الأداء | أبطأ (كل module بيعدّي على S3) | أسرع (pipelining) |

**الـ transfer bucket:** الـ `aws_ssm` plugin بيرفع ملفات الـ modules على S3 والـ instance بينزّلها بـ presigned URL — يعني الـ instance **مش محتاج** أي صلاحية S3. الـ bucket الرسمي من الـ bootstrap ([`ansible-ssm.tf`](../../../infra/terraform/bootstrap/ansible-ssm.tf)): `student-app-ansible-ssm-<account>`، objects بتتمسح بعد يوم، والـ deploy role ليه Get/Put/Delete عليه بس. الـ CI بياخده من `ANSIBLE_SSM_BUCKET`.

> 💡 **bucket-ين بأدوار مختلفة، متخلطش بينهم** (الـ [README](../../../infra/ansible/README.md) بقى بيفصلهم): `SSM_BUCKET` = bucket الـ bootstrap للـ SSM transfers (موجود مع stack 20 و 40، والـ CI deploy role ليه صلاحية عليه بس)، و `BACKUP_BUCKET` = `backup_bucket` بتاع stack 20 للـ MySQL dumps بس (`backup.yml`). الـ backups bucket كان بيشتغل كـ transfer bucket على stack 20 من الـ laptop، بس مش موجود مع stack 40 والـ CI مايقدرش يكتب فيه.

**الـ localhost:** الـ plays اللي بتكلّم AWS APIs (`delegate_to: localhost`، أول وآخر play في `rolling-asg.yml`) بتجري على الـ controller. الـ implicit localhost عنده `ansible_connection: local` كـ host var، والـ host var بيكسب الـ group var — عشان كده الـ `ansible_connection` اللي في `group_vars/all` مبيأثرش عليه (التعليق في آخر الملف).

**Long tasks على SSM:** الـ session ممكن تعمل idle timeout في canary طويل. الـ [`nginx_lb/tasks/release.yml`](../../../infra/ansible/roles/nginx_lb/tasks/release.yml) بيشغّل السكريبت `async: 3600` و `poll: 15` (job في الخلفية والـ controller بيسأل عليه).

### 5.4 الـ Roles (كل واحد في الـ repo)

```text
roles/<name>/
├── defaults/main.yml   أقل أولوية — كل variable بـ prefix اسم الـ role (common_*، docker_*، app_*)
├── tasks/main.yml      (+ ملفات entry points: app/tasks/{files,env,deploy,smoke}.yml، nginx_lb/tasks/release.yml)
├── handlers/main.yml
├── templates/*.j2
└── meta/main.yml       galaxy_info (min_ansible_version 2.18، platforms Amazon Linux 2023) + dependencies: []
```

| Role | بيعمل إيه | حيلة الـ idempotency / التصميم | بيستخدمه |
|---|---|---|---|
| [`common`](../../../infra/ansible/roles/common/) | packages، timezone `Africa/Cairo`، swap 2G، sysctl، journald cap، `dnf-automatic` (security بس، من غير reboot) | swap بـ `.tmp` + `mv` بعد `mkswap` → `creates:` آمن؛ `swapon` بس لو مش active | `provision.yml`، Packer |
| [`docker`](../../../infra/ansible/roles/docker/) | Docker من AL2023 + Compose/Buildx متثبتين من GitHub (checksum اختياري)، `daemon.json` (`live-restore`) | ملفات بأسماء فيها الـ version + symlink = الترقية؛ `validate: dockerd --validate`؛ handlers reload قبل restart | `provision.yml`، Packer |
| [`app`](../../../infra/ansible/roles/app/) | Recreate deploy: نسخ compose + scripts، `app.env` من SSM (أو vault)، deploy لو الـ release أو الـ env اتغيّر، smoke على `/ready` | render في staging dir + `copy remote_src` = `changed` حقيقي؛ deploy بس لو `CURRENT_RELEASE != app_image` | `deploy.yml`، `rollback.yml`، (files/env في bluegreen/canary/backup) |
| [`nginx_lb`](../../../infra/ansible/roles/nginx_lb/) | sync لـ `deploy/ec2/lb` + release بـ `bluegreen.sh`/`canary.sh` | أول مرة `init.sh`؛ release بس لو اللون الـ live مش شغال الـ image ده؛ canary exit 2 = abort مقبول (`failed_when`) | `bluegreen.yml`، `canary.yml` |
| [`cloudwatch_agent`](../../../infra/ansible/roles/cloudwatch_agent/) | agent + config (docker json logs، cloud-init log، mem/disk/swap) | `flush_handlers` عشان `fetch-config` يحصل قبل أول start | `provision.yml` |
| [`node_exporter`](../../../infra/ansible/roles/node_exporter/) | container `prom/node-exporter:v1.13.1` (host network/pid، read-only، cap_drop ALL) | `community.docker.docker_container` declarative | `provision.yml` |
| [`mysql_backup`](../../../infra/ansible/roles/mysql_backup/) | systemd service + timer يومي 03:00 Cairo (`Persistent=true`) | assert على الـ bucket؛ `daemon_reload` handler + flush قبل enable | `backup.yml` |

**`include_role` + `tasks_from` (dynamic) مقابل `roles:` (static):** `bluegreen.yml` بيعمل `include_role: name=app tasks_from=files` — بياخد جزء من الـ role بس، وبيتقرر وقت التشغيل. `deploy.yml` و `provision.yml` بيستخدموا `roles:` (static، بيتحمّلوا وقت الـ parse). الفرق بيبان مع الـ tags والـ `when` (§5.9).

### 5.5 أولوية الـ Variables (وفخ مكان الـ `group_vars`)

الترتيب الرسمي فيه 22 مستوى؛ المهم منهم (من الأضعف للأقوى):

```text
 1. role defaults                (roles/app/defaults/main.yml: app_env_source: ssm)
 2. inventory group_vars/all     (inventories/lab/group_vars/all/main.yml)       ← الـ repo
 3. playbook group_vars/all      (playbooks/group_vars/all/...)
 4. inventory group_vars/<group> → playbook group_vars/<group>
 5. inventory host_vars → playbook host_vars
 6. facts / cached set_fact
 7. play vars → vars_prompt → vars_files
 8. role vars                     (roles/x/vars/main.yml — مش مستخدمة هنا)
 9. block vars → task vars
10. include_vars
11. set_fact / registered vars    (app_env_changed، rolling_asg_names)
12. role params / include params  (vars: nginx_lb_strategy: bluegreen جوه include_role)
13. extra vars (-e)               ← دايماً تكسب
```

أمثلة من الـ repo:

- `app_env_source` موجود في `roles/app/defaults` **و** في `group_vars/all` → الـ group_vars بتكسب، و `-e app_env_source=vault` بيكسب الاتنين.
- **Prefix + mapping:** الـ role بيعرّف `app_use_local_mysql: "{{ use_local_mysql | default(true) }}"` — الـ role بيقرا الـ variable العام لو موجود بس اسمه الداخلي ليه prefix (ده اللي `var-naming[no-role-prefix]` في ansible-lint بيطلبه).
- `-e` بـ JSON للـ types المعقدة: `-e "{\"rolling_target_group_arns\": $TG}"` (dict من `terraform output -json`).

> ⚠️ **فخ الـ `group_vars`:** Ansible بيدوّر على `group_vars/` في مكانين بس: **جنب الـ inventory source** و **جنب الـ playbook**. الـ inventory هنا `inventories/lab/aws_ec2.yml` فالـ vars في `inventories/lab/group_vars/` — وده بيتحمّل للـ `aws_ec2.yml` و `hosts.ini` الاتنين. لو حطيت `group_vars/` في `infra/ansible/` (جنب `ansible.cfg`) **مش هيتقري خالص**: مفيش error، بس `ansible_connection` يرجع ssh و `app_dir` و `ssm_prefix` undefined. ولو حطيته في `playbooks/group_vars/` هيشتغل بس بأولوية مختلفة وهيتنسى مع inventory تاني.

```bash
ansible-inventory --host i-0123456789abcdef0 | jq '{ansible_connection, app_dir, ssm_prefix}'   # اتأكد إن الـ vars وصلت
ansible -m ansible.builtin.debug -a "var=ansible_connection" 'role_app:&standalone'
```

### 5.6 الـ Handlers

- `notify` بيعلّم الـ handler، والـ handler بيتنفذ **مرة واحدة** في آخر الـ section (بعد `pre_tasks`، بعد `roles`+`tasks`، بعد `post_tasks`) حتى لو 5 tasks عملوله notify.
- **الترتيب = ترتيب التعريف في `handlers/main.yml`، مش ترتيب الـ notify.** [`docker/handlers/main.yml`](../../../infra/ansible/roles/docker/handlers/main.yml): `Reload docker` الأول (SIGHUP بيفعّل `live-restore`) وبعدين `Restart docker` (يطبّق الـ log options من غير ما يوقف الـ containers).
- `meta: flush_handlers` = نفّذ الـ handlers دلوقتي: الـ docker role (قبل ما أي حاجة تستخدم Docker)، الـ cloudwatch_agent (الـ `fetch-config` قبل أول start)، الـ mysql_backup (`daemon-reload` قبل enable للـ timer).
- **لو الـ play فشل، الـ handlers اللي اتعملها notify مش بتتنفذ** → config اتغيّر والـ service متعملهوش restart. `--force-handlers` أو `force_handlers: true` بيحل ده.
- handler بـ `command` (زي `sysctl --system`) لازم `changed_when: true` — ansible-lint `no-changed-when`.

### 5.7 الـ Idempotency: `changed_when` و `creates` وأخواتهم

`command`/`shell` مش idempotent لوحدهم وبيقولوا `changed` دايماً. الأدوات:

| الأداة | المثال في الـ repo |
|---|---|
| `creates:` | swap: `creates: "{{ common_swap_file }}"` + الكتابة لـ `.tmp` والـ `mv` بعد `mkswap` → الملف يا مش موجود يا swap صالح، فالـ guard آمن |
| `changed_when: false` | أي probe للقراية (`swapon --show`، `aws s3api list-objects-v2`، `docker login`) |
| `changed_when: <expression>` | `rolling-asg.yml`: `changed_when: "'Nothing to migrate' not in rolling_migrate.stdout"` |
| `failed_when` | `nginx_lb`: canary exit 2 = نجاح للـ drill — `failed_when: rc not in [0, 2]` |
| شرط على حالة | `app/tasks/deploy.yml`: deploy بس لو `app_current_release != app_image` أو الـ env اتغيّر |
| staging + module declarative | `env.yml`: السكريبت بيكتب في `.env-staging`، و `copy remote_src` هو اللي يقرر `changed` بالـ checksum |
| `meta: end_host` | `rolling-asg.yml`: الـ instance اللي شغال الـ image ده فعلاً بيخرج من الـ play (مبيتعملوش drain تاني) |
| أسماء ملفات بالـ version | `docker`: `get_url` مبينزّلش تاني لو الـ dest موجود؛ version جديد = ملف جديد + symlink |

**الاختبار:** شغّل الـ playbook مرتين — التانية لازم `changed=0`:

```bash
ansible-playbook playbooks/provision.yml $ANSIBLE_EXTRA --limit 'role_app:&standalone'
ansible-playbook playbooks/provision.yml $ANSIBLE_EXTRA --limit 'role_app:&standalone' | tail -4   # changed=0
```

### 5.8 Check mode و Diff

```bash
ansible-playbook playbooks/deploy.yml $ANSIBLE_EXTRA -e app_image=$IMG --check --diff
```

- الـ modules الـ declarative (`copy`، `template`، `dnf`، `file`) بتدعم check mode وبتقول "كان هيتغير".
- **`command`/`shell` بيتعملهم skip في check mode** (إلا مع `creates`/`removes`). أي task بعدهم بيعتمد على `register` بتاعهم ممكن يقع. لو الـ command قراية بس، ضيف `check_mode: false` عليه عشان يشتغل حتى في الـ dry run — زي `List active swap areas` في [`common/tasks/main.yml`](../../../infra/ansible/roles/common/tasks/main.yml) (`swapon --show`): من غيره `Activate the swap file` كان هيقع في `--check` لأن مفيش `stdout_lines`. القاعدة: `check_mode: false` للـ probes الـ read-only بس، مش لأي حاجة بتغيّر.
- **الـ diff والـ secrets:** `--diff` على `template` لـ `app.env` كان هيطبع الباسوردات في الـ CI log. عشان كده [`env.yml`](../../../infra/ansible/roles/app/tasks/env.yml) فيه `diff: false` على كل task بتلمس env files و `no_log: true` على الـ templates بتاعة الـ vault.

### 5.9 الـ Tags

الـ repo **مش بيستخدم tags** — قرار تصميم: الـ entry points هي playbooks منفصلة و `include_role` + `tasks_from`. بس لازم تفهمها:

```bash
ansible-playbook playbooks/provision.yml --list-tags
ansible-playbook playbooks/provision.yml --tags docker            # لو ضفت tags (مثال تحت)
ansible-playbook playbooks/provision.yml --skip-tags node_exporter
```

```yaml
# (مثال — مش في الـ repo) playbooks/provision.yml
  roles:
    - role: common
      tags: [common, baseline]
    - role: docker
      tags: [docker]
```

- الـ tags على `roles:` / `import_*` (static) **بتتورث** لكل task جوه.
- الـ tags على `include_role` / `include_tasks` (dynamic) بتتطبق على الـ include نفسه **بس** — عشان توصل للـ tasks جوه لازم `apply: { tags: [...] }`. ده نفس الفرق مع `when`: على `roles:` الشرط بيتقيّم على كل task، وعلى `include_role` بيتقيّم مرة.
- `always` (بتتنفذ حتى مع `--tags`) و `never` (مبتتنفذش غير لو طلبتها) — مفيدين للـ asserts وللـ tasks الخطيرة.

### 5.10 Ansible Vault (البديل لـ SSM)

الافتراضي `app_env_source: ssm`: السيرفر نفسه بيقرا من SSM بالـ instance profile — **ولا secret بيعدّي على الـ controller**. الـ vault بديل opt-in ([`vault.yml.example`](../../../infra/ansible/inventories/lab/group_vars/all/vault.yml.example)):

```bash
cd infra/ansible/inventories/lab/group_vars/all
openssl rand -base64 48 > "$HOME/.vault-pass-student-app" && chmod 600 "$HOME/.vault-pass-student-app"
cp vault.yml.example vault.yml && $EDITOR vault.yml                      # قيم حقيقية

ansible-vault encrypt --vault-id "lab@$HOME/.vault-pass-student-app" vault.yml
head -1 vault.yml                                                         # $ANSIBLE_VAULT;1.2;AES256;lab
ansible-vault view    --vault-id "lab@$HOME/.vault-pass-student-app" vault.yml
ansible-vault edit    --vault-id "lab@$HOME/.vault-pass-student-app" vault.yml   # من غير ما تفك على الـ disk
ansible-vault create  --vault-id "lab@prompt" other-secrets.yml          # ملف جديد مشفّر من الأول

# قيمة واحدة inline بدل ملف كامل:
ansible-vault encrypt_string --vault-id "lab@$HOME/.vault-pass-student-app" --name vault_sre_lab_token "$(openssl rand -hex 16)"

# تغيير الباسورد (لو اتسرّب):
ansible-vault rekey --vault-id "lab@$HOME/.vault-pass-student-app" --new-vault-id "lab@prompt" vault.yml

cd ../../../..   # infra/ansible
ansible-playbook playbooks/deploy.yml $ANSIBLE_EXTRA -e app_image=$IMG -e app_env_source=vault \
  --vault-id "lab@$HOME/.vault-pass-student-app"
```

- **Vault IDs** (`label@source`): أكتر من باسورد في نفس الوقت (`dev@...`، `prod@...`)، والـ label بيتكتب في الـ header (`1.2;AES256;lab`) فـ Ansible يعرف يجرّب أنهي باسورد. `--vault-password-file FILE` = النسخة القديمة من غير label. ممكن `vault_identity_list` في `ansible.cfg`.
- **الـ convention:** كل secret اسمه `vault_*` في `vault.yml`، و `main.yml` بيشاور عليه (`APP_KEY: "{{ vault_app_key }}"`) — `grep -r vault_` يوريك فين كل secret بيتستخدم والقيم مشفّرة.
- **الـ repo بيعمل gitignore لـ `vault.yml`** (والـ `.ansible-lint` بيستبعده): ملف مشفّر آمن يتعمل commit في repo حقيقي، بس هنا الخوف إن حد يعمل push لنسخة **قبل** `ansible-vault encrypt`. البديل الاحترافي: pre-commit hook بيرفض أي `vault.yml` مش بادئ بـ `$ANSIBLE_VAULT`.

| | SSM (الافتراضي) | Vault |
|---|---|---|
| الـ secret بيعدّي على الـ controller؟ | لأ | آه (بيتفك على الـ controller وبيتبعت) |
| Rotation | `put-parameter` + re-render | re-encrypt + commit + deploy لكل host |
| صلاحيات/audit | IAM + CloudTrail | اللي معاه الباسورد يقرا كل حاجة |
| من غير AWS | لأ | آه (on-prem، أي cloud) |
| الـ CI | OIDC role | الباسورد كـ GitHub secret (long-lived) |

### 5.11 `serial` و `max_fail_percentage` — تشريح `rolling-asg.yml`

[`rolling-asg.yml`](../../../infra/ansible/playbooks/rolling-asg.yml) هو البديل الـ in-place للـ instance refresh ([44](44-rolling-instance-refresh.md)): نفس الـ image بس Ansible اللي بيتحكم في الترتيب. 4 plays:

```text
 Play 1 (localhost)   assert (image مش :latest، فيه hosts، فيه TG ARNs)
                      → أسماء الـ ASGs من hostvars[*].tags['aws:autoscaling:groupName']
                      → suspend-processes: HealthCheck ReplaceUnhealthy AZRebalance AlarmNotification ScheduledActions
 Play 2 (in_asg)      run_once: docker login + migrate بالـ image الجديد (مرة واحدة، قبل أي instance يخدم)
                      any_errors_fatal: true
 Play 3 (in_asg)      serial: 1 · any_errors_fatal: true · max_fail_percentage: 0
   pre_tasks:         docker_container_info → meta: end_host لو شغال الـ image ده
                      elb_target state=absent target_status=unused (drain، delegate_to localhost)
   tasks:             docker login → docker_image_pull → docker_container (نفس spec الـ user-data: -p 80:8080،
                      SIGQUIT/30s، awslogs) → CURRENT_RELEASE → uri /ready لحد "ready"
   post_tasks:        elb_target state=present → aws elbv2 wait target-in-service  (الـ health gate من الـ ALB نفسه)
 Play 4 (localhost)   ssm_parameter deploy/<color>/IMAGE_URI = الـ image  (بعد ما كل الـ instances نجحوا بس)
                      → resume-processes
```

| المفتاح | القيمة هنا | المعنى |
|---|---|---|
| `serial` | `1` | batch = instance واحد → السعة N-1 طول الـ roll. ممكن `"25%"` أو ramp-up `[1, 5, "50%"]` (canary على مستوى الـ hosts) |
| `max_fail_percentage` | `0` | لو نسبة الفشل في الـ batch **عدّت** القيمة، الـ play يقف (مع 0: أي فشل). مع `serial` أكبر هو اللي بيحدد كام فشل الـ batch يستحمل |
| `any_errors_fatal` | `true` | أول فشل يوقف الـ play فوراً لكل الـ hosts — مفيش instance تاني يتلمس |
| `run_once` | الـ migrate | مرة واحدة على أول host في الـ batch (CONVENTIONS §2: migrations مرة لكل release) |
| `delegate_to: localhost` | AWS API calls | الـ task بيتنفذ على الـ controller بالـ credentials بتاعتك، "نيابة عن" الـ host |

**Failure mode مقصود** (README): لو فشل في النص، الـ instance الفاشل **بيفضل برّه** الـ target group (عمره ما بيخدم الـ release البايظ)، والـ ASG processes بتفضل **suspended** (frozen للتحقيق) — والـ IMAGE_URI **مبيتغيرش** (Play 4 مجاش)، فأي scale-out هيقوم على الـ release القديم السليم. الرجوع:

```bash
aws autoscaling resume-processes --auto-scaling-group-name student-app-lab-blue
# بعد ما تصلّح: شغّل الـ playbook تاني بنفس الـ image أو بالـ image القديم — الـ end_host بيتخطى اللي خلصوا
```

> 💡 **Ansible على ASG = config drift مقصود ومؤقت:** الـ instances بقت شغالة image غير اللي في الـ launch template/الـ SSM لحد Play 4. لو Play 4 متعملش، أي instance جديد هيقوم بـ image مختلف. عشان كده Play 4 جزء أساسي مش تجميل — وده سبب إن الـ default في الـ lab هو الـ instance refresh ([`deploy-asg.yml`](../../../.github/workflows/deploy-asg.yml)).

`rolling-asg.yml` بيشتغل **بالـ credentials بتاعتك** (WSL): محتاج `elasticloadbalancing:RegisterTargets/DeregisterTargets` و `autoscaling:SuspendProcesses/ResumeProcesses` — أكتر من اللي الـ CI deploy role مسموحله.

### 5.12 ansible-lint بالـ production profile

[`.ansible-lint`](../../../infra/ansible/.ansible-lint): `profile: production` + استبعاد `.cache/`، `.ansible/`، `collections/`، و `vault.yml` (مش YAML لحد ما يتفك). الـ profiles متدرجة: `min` ← `basic` ← `moderate` ← `safety` ← `shared` ← **`production`** (الأشد، وبيشمل كل اللي قبله).

أمثلة على اللي بيفرضه وتشوفه في كود الـ repo:

| القاعدة | الشكل في الـ repo |
|---|---|
| `fqcn` | `ansible.builtin.copy` مش `copy`، `community.docker.docker_container` |
| `name[...]` | كل play وtask ليه اسم يبدأ بحرف كبير |
| `no-changed-when` | كل `command`/`shell` عليه `changed_when` |
| `risky-shell-pipe` | أي pipe في `shell` معاه `set -euo pipefail` + `executable: /bin/bash` |
| `risky-file-permissions` | `mode:` صريح على كل `copy`/`template`/`file` |
| `no-free-form` | `argv:` أو `cmd:` بدل `command: foo bar` |
| `var-naming[no-role-prefix]` | variables الـ role بـ prefix (`docker_*`، `nginx_lb_*`) |
| `meta-*` / `schema` | `meta/main.yml` بـ `galaxy_info` كامل لكل role |

```bash
cd infra/ansible
for pb in playbooks/*.yml; do ansible-playbook --syntax-check -i inventories/lab/hosts.ini.example "$pb"; done
ansible-lint --profile=production
ansible-lint -L | head -40                     # كل القواعد
# استثناء محدد بسبب مكتوب (أحسن من skip_list عام):
#   - name: Something unusual   # noqa: no-changed-when -- السبب
```

الـ `--syntax-check` بيستخدم `hosts.ini.example` عشان الـ CI مالوش AWS credentials (الـ dynamic inventory كان هيحاول يكلّم EC2).

### 5.13 Molecule (مقدمة لاختبار الـ roles)

الـ repo مفيهوش Molecule — اختبار الـ roles حالياً = idempotency يدوي + الـ Packer build (اللي بيشغّل `provision.yml` على instance نضيف كل مرة). Molecule بيعمل ده أوتوماتيك: يعمل instance/container، `converge` (يشغّل الـ role)، `idempotence` (يشغّله تاني ولازم `changed=0`)، `verify`، `destroy`.

```text
roles/docker/molecule/default/      (role mode)
├── molecule.yml      الـ driver والـ platforms
├── converge.yml      playbook بيطبّق الـ role
└── verify.yml        asserts بعد التطبيق
```

```yaml
# roles/docker/molecule/default/molecule.yml   (مثال — مش في الـ repo؛ صيغة الـ docker driver الكلاسيكية)
driver:
  name: docker
platforms:
  - name: al2023
    image: amazonlinux:2023
    pre_build_image: false        # يبني من Dockerfile.j2 (بتكتبه انت: dnf install systemd python3)
    command: /usr/sbin/init
    privileged: true
    cgroupns_mode: host
    volumes:
      - /sys/fs/cgroup:/sys/fs/cgroup:rw
provisioner:
  name: ansible
verifier:
  name: ansible
```

```bash
pip install molecule "molecule-plugins[docker]"
cd infra/ansible/roles/docker && molecule test      # create → converge → idempotence → verify → destroy
```

**الواقع بتاع الـ repo ده:** كل الـ roles بتعتمد على **systemd** (journald، docker، timers)، و `common` بيلمس swap و sysctl بتوع الـ **host** — حاجات مش مكانها container. فالخيارات: container بـ systemd (privileged — زي فوق، مع override لـ `common_swap_enabled: false` و `common_auto_updates: false` و `common_sysctl: {}` في `converge.yml`)، أو driver بيعمل EC2 حقيقي (create/destroy playbooks بـ `amazon.aws.ec2_instance`) — أدق وبسنتات. ومفيش Docker على جهازك → شغّله على GitHub Actions. Molecule بيدعم آخر نسختين major من Ansible، والنسخ الجديدة بتتحرك ناحية config "ansible-native" و collections (`extensions/molecule/`) — راجع `molecule --version` والـ docs قبل ما تنسخ أي صيغة.

### 5.14 Ansible مقابل Terraform مقابل user-data مقابل golden AMI

| | Terraform | user-data | Golden AMI (Packer) | Ansible |
|---|---|---|---|---|
| بيدير | **موارد AWS** (VPC، ALB، IAM، SSM params) | أول boot لـ instance | محتوى الـ image | حالة OS/app على hosts شغالة |
| إمتى بيشتغل | `apply` | مرة، عند الـ boot | وقت الـ build | عند الطلب / CI |
| مثال في الـ repo | كل `infra/terraform` | [`asg-app/user-data.sh.tftpl`](../../../infra/terraform/modules/asg-app/user-data.sh.tftpl): SSM → `app.env` → IMAGE_URI → `docker run` · stack 20: [`deploy/ec2/user-data.sh`](../../../deploy/ec2/user-data.sh) | [`app-ami.pkr.hcl`](../../../infra/packer/app-ami.pkr.hcl) بيشغّل **نفس** `provision.yml` | stack 20 day-2، `rolling-asg.yml`، backups |
| Drift | `plan` | — (instance immutable) | — (image ثابت) | re-run (idempotent) |
| نقطة الضعف | مش مصمم لـ config جوه الـ OS | boot بطيء/بيفشل لو mirror وقع؛ مفيش re-run | build pipeline + إدارة AMIs | push من controller؛ hosts mutable ممكن تختلف |

**القاعدة العملية:**

- **الحاجة بطيئة ونادراً بتتغير** (Docker، agents، hardening) → اخبزها في **AMI** (نفس الـ playbook = تعريف واحد للـ "student-app host").
- **الحاجة بتختلف لكل instance/release** (أنهي image، env من SSM) → **user-data** بيقراها وقت الـ boot.
- **موارد cloud** → **Terraform** دايماً.
- **hosts mutable** (stack 20 pet) أو **orchestration بترتيب** (drain → deploy → gate) أو عمليات (backup + restore drill) → **Ansible**.
- **Anti-patterns:** Ansible بيعمل EC2/SGs جنب Terraform (مصدرين للحقيقة)، Terraform `remote-exec` لـ config الـ OS، و patch in-place لـ ASG من غير ما تحدّث الـ launch template/IMAGE_URI.

## 6) الـ Deploy (التمارين بالترتيب)

```bash
cd infra/ansible
IMG=<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/student-app:<SHA>      # tag CI عمله push
ansible role_app -m ansible.builtin.ping $ANSIBLE_EXTRA

# 21/43 — baseline (مرتين: التانية changed=0)
ansible-playbook playbooks/provision.yml $ANSIBLE_EXTRA -e target_hosts=standalone

# 33 — Recreate deploy (مرتين: التانية Deploy = skipped)
ansible-playbook playbooks/deploy.yml $ANSIBLE_EXTRA -e app_image=$IMG

# 23/24 — blue/green ثم canary drill لازم يعمل abort
ansible-playbook playbooks/bluegreen.yml $ANSIBLE_EXTRA -e app_image=$IMG
ansible-playbook playbooks/canary.yml $ANSIBLE_EXTRA -e app_image=$IMG \
  -e nginx_lb_slot_env=SRE_FAULT_ERROR_RATE=0.5 -e nginx_lb_canary_expect_abort=true
#   (الـ canary محتاج traffic: deploy/scripts/probe.sh http://<host>/login 0 0.05 في terminal تاني)

# rollback (lb stack → nginx switch فوري)
ansible-playbook playbooks/rollback.yml $ANSIBLE_EXTRA

# 27 — backup + restore drill
BACKUP_BUCKET=$(terraform -chdir=../terraform/stacks/20-ec2-single output -raw backup_bucket)
ansible-playbook playbooks/backup.yml $ANSIBLE_EXTRA -e backup_bucket=$BACKUP_BUCKET -e backup_restore_drill=true

# 47 — rolling على الـ ASG (stack 40)
TG=$(terraform -chdir=../terraform/stacks/40-ec2-alb-asg output -json target_group_arns)
ansible-playbook playbooks/rolling-asg.yml $ANSIBLE_EXTRA -e app_image=$IMG -e "{\"rolling_target_group_arns\": $TG}"
```

## 7) التحقق (Verify)

```bash
ansible 'role_app:&standalone' -b -a "cat /opt/student-app/CURRENT_RELEASE" $ANSIBLE_EXTRA
ansible 'role_app:&standalone' -b -a "cat /etc/docker/daemon.json" $ANSIBLE_EXTRA          # "live-restore": true
ansible 'role_app:&standalone' -b -a "systemctl list-timers student-app-mysql-backup.timer --no-pager" $ANSIBLE_EXTRA
ansible-playbook playbooks/deploy.yml $ANSIBLE_EXTRA -e app_image=$IMG | grep -E 'changed=|skipping: .*Deploy'
aws ssm get-parameter --name /student-app/lab/deploy/blue/IMAGE_URI --query Parameter.Value --output text   # بعد rolling-asg
```

المفروض: الـ release الصح، `true` للـ live-restore، الـ timer مجدول، التشغيل التاني `changed=0`، والـ IMAGE_URI = الـ image بعد الـ rolling.

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر | المتوقع |
|---|---|---|
| `group_vars` في المكان الغلط | `mv inventories/lab/group_vars ./group_vars` ثم `ansible-inventory --host <id>` | `ansible_connection` مش موجود → ssh، `app_dir` undefined. رجّعه |
| SSM من غير bucket | `ansible role_app -m ansible.builtin.ping` (من غير `$ANSIBLE_EXTRA`) | الـ `aws_ssm` plugin بيقع لأن مفيش bucket لنقل الـ module |
| check mode مع `command` | علّق `check_mode: false` على `List active swap areas` (محلياً) ثم `ansible-playbook playbooks/provision.yml --check $ANSIBLE_EXTRA -e target_hosts=standalone` | فشل عند `Activate the swap file`: الـ probe اتعمله skip فمفيش `stdout_lines`. رجّع السطر → الـ `--check` يعدّي |
| `:latest` | `ansible-playbook playbooks/deploy.yml -e app_image=student-app:latest` | الـ assert: *':latest' is not allowed* |
| Canary drill | السطر بتاع `nginx_lb_canary_expect_abort=true` | exit 2 من `canary.sh` → الـ playbook ناجح؛ من غير الـ flag → `Canary ABORTED by the error-rate gate` |
| Rolling بـ image مش موجود | `rolling-asg.yml -e app_image=<ecr>/student-app:0000000` | الـ migrate (Play 2) يقع **قبل** أي drain؛ الـ processes تفضل suspended والـ IMAGE_URI زي ما هو. ومع `-e rolling_run_migrations=false`: أول instance يتعمله drain والـ pull يقع → يفضل برّه الـ TG والـ play يقف |
| باسورد vault غلط | `--vault-id lab@prompt` بكلمة غلط | `Decryption failed` |
| lint | شيل `mode:` من أي `copy` | `risky-file-permissions` |

## 9) الرجوع (Rollback)

- **single host:** `ansible-playbook playbooks/rollback.yml` — lb stack = switch فوري في nginx؛ Recreate = redeploy لـ `PREVIOUS_RELEASE`. الـ migrations **مبترجعش** ([95](95-zero-downtime-db-migrations.md)).
- **ASG بعد rolling:** نفس الـ playbook بالـ image القديم (`aws ssm get-parameter-history --name /student-app/lab/deploy/blue/IMAGE_URI`)، أو instance refresh بالقيمة القديمة.
- **vault password اتسرّب:** `ansible-vault rekey` + غيّر الـ secrets نفسها (الـ rekey بيغيّر القفل مش المحتوى).

## 10) المسح (Teardown) ⚠️

```bash
terraform -chdir=../terraform/stacks/40-ec2-alb-asg destroy
terraform -chdir=../terraform/stacks/20-ec2-single destroy
# log groups بتاعة الـ CloudWatch agent (مش في أي Terraform state):
aws logs describe-log-groups --log-group-name-prefix /student-app/lab/ec2 --query 'logGroups[].logGroupName' --output text \
  | tr '\t' '\n' | xargs -r -n1 aws logs delete-log-group --log-group-name
rm -f inventories/lab/group_vars/all/vault.yml "$HOME/.vault-pass-student-app"     # لو كانت تجربة
deactivate
```

الـ transfer bucket بتاع SSM بيفضل (bootstrap) والـ objects بتتمسح لوحدها بعد يوم.

## 11) التكلفة (Cost)

| البند | التكلفة |
|---|---|
| Ansible / ansible-lint / Molecule | مجاني |
| stack 20 | ≈ $0.03/ساعة |
| stack 40 (rolling) | ≈ $0.08/ساعة |
| SSM sessions | مجاني؛ الـ S3 transfer سنتات |
| CloudWatch agent logs | سنتات (retention 7 أيام من الـ role) |

## 12) أسئلة Interview

<details><summary>ليه الـ hostname في الـ inventory هو الـ instance ID مش الـ Name أو الـ DNS؟</summary>

الـ instance ID ثابت ومميّز طول عمر الـ instance، وهو بالظبط الـ target اللي SSM محتاجه. الـ Name tag ممكن يتكرر (كل instances الـ ASG اسمها واحد) والـ public DNS بيتغير مع stop/start. الـ `ansible_host` بيتحسب للـ SSH بس (`compose`)، و `ansible_aws_ssm_instance_id` للـ SSM.

</details>

<details><summary>SSM ولا SSH لـ Ansible؟ وإيه اللي بيخلّي SSM يشتغل من غير ما الـ instance يكون عنده صلاحية S3؟</summary>

SSM: مفيش بورت 22 ولا keys، IAM مؤقت، وCloudTrail. التمن: أبطأ، ومحتاج plugin على الـ controller وbucket. الـ plugin بيرفع الـ modules على S3 بـ credentials الـ controller، والـ instance بينزّلها بـ presigned URL (curl) — فالـ instance مالوش أي S3 permission. الـ bucket بـ lifecycle يوم واحد لأن المحتوى مؤقت.

</details>

<details><summary>اشرح أولوية الـ variables بمثال، والفخ بتاع <code>group_vars</code>.</summary>

role defaults أضعف حاجة، بعدها inventory group_vars، ... ، set_fact، و `-e` دايماً تكسب. `app_env_source` في defaults الـ role وفي group_vars → group_vars تكسب، و `-e app_env_source=vault` يكسب الكل. الفخ: `group_vars/` بيتقري جنب الـ inventory أو جنب الـ playbook بس — لو جنب `ansible.cfg` مبيتقريش ومفيش error، فالـ connection يرجع ssh والـ vars undefined.

</details>

<details><summary><code>serial: 1</code> و <code>max_fail_percentage: 0</code> و <code>any_errors_fatal</code> — ليه الثلاثة مع بعض؟</summary>

`serial: 1` = instance واحد خارج الـ pool في كل وقت. `any_errors_fatal` = أول فشل يوقف كل حاجة فوراً. `max_fail_percentage: 0` نفس المعنى لكل batch، ومتساب صريح لأنه المفتاح اللي هيفرق لو زوّدت `serial` لـ `"25%"`. والنتيجة المقصودة: الـ instance الفاشل برّه الـ TG، الـ ASG frozen، والـ IMAGE_URI مبيتحدّثش غير لو الكل نجح.

</details>

<details><summary>إزاي تخلي <code>command</code> / <code>shell</code> idempotent؟</summary>

أفضّل module declarative لو موجود. لو لأ: `creates`/`removes`، `changed_when` بشرط على الـ output (`'Nothing to migrate' not in stdout`)، `changed_when: false` للقراية، شرط `when` على حالة مقروءة (زي `CURRENT_RELEASE`)، أو تكتب لـ staging وتخلي `copy` يقرر بالـ checksum. واختبرها بتشغيل تاني لازم `changed=0`.

</details>

<details><summary>Vault ولا SSM للـ secrets؟</summary>

SSM لما الـ hosts على AWS: الـ host بيقرا بالـ instance profile، والـ secret عمره ما بيعدّي على الـ controller، وrotation مركزي وIAM-audited. Vault لما مفيش secret store (on-prem) أو لـ secrets الـ controller نفسه: بس الباسورد بقى long-lived secret لازم توزّعه، والـ rotation = re-encrypt + deploy. Vault IDs لو عندك أكتر من بيئة بباسوردات مختلفة.

</details>

<details><summary>الـ handlers مش اتنفذت بعد ما غيّرت <code>daemon.json</code>. ليه؟</summary>

غالباً task بعدها فشل والـ play وقف — الـ handlers اللي اتعملها notify مش بتتنفذ لو الـ play فشل (إلا `--force-handlers`). أو الـ task مكانش `changed` (نفس المحتوى). والترتيب بيتحدد من ملف الـ handlers مش من الـ notify. لو محتاج التطبيق فوراً: `meta: flush_handlers` زي الـ docker role.

</details>

<details><summary>إمتى Ansible وإمتى golden AMI وإمتى user-data؟</summary>

اللي بطيء ونادر التغيير (Docker، agents، hardening) → AMI (هنا Packer بيشغّل نفس `provision.yml`). اللي بيتغير لكل release/instance (image، env) → user-data بيقراه من SSM وقت الـ boot. الـ hosts الـ mutable والـ orchestration بترتيب (drain → deploy → health gate) والعمليات → Ansible. موارد الـ cloud → Terraform. والـ anti-pattern: Ansible بيعدّل ASG in-place من غير ما يحدّث الـ launch template أو IMAGE_URI.

</details>

<details><summary>إزاي تختبر role قبل ما تشغّله على production؟</summary>

lint بالـ production profile و `--syntax-check` في الـ CI، `--check --diff` (مع فهم إن `command`/`shell` بيتعملهم skip)، Molecule (converge + idempotence + verify) على container بـ systemd أو EC2 مؤقت، والـ Packer build كـ integration test لأنه بيشغّل الـ playbook على instance نضيف كل مرة. وبعدين `--limit` على host واحد قبل الكل.

</details>

## 13) Checklist

- [ ] شغّلت `ansible-inventory --graph` وفاهم كل group جاي منين (tags من Terraform)
- [ ] جرّبت SSM و SSH وفاهم الـ transfer bucket
- [ ] أقدر أشرح كل role وحيلة الـ idempotency بتاعته، وشغّلت provision/deploy مرتين بـ `changed=0`
- [ ] جرّبت فخ الـ `group_vars` وأولوية `-e`
- [ ] عملت vault بـ vault ID وشغّلت deploy بـ `app_env_source=vault`
- [ ] شغّلت `rolling-asg.yml` وفاهم الـ failure mode و Play 4
- [ ] `ansible-lint --profile=production` نضيف
- [ ] عملت destroy ومسحت الـ log groups بتاعة الـ agent
