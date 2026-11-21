# 43 — Golden AMI بـ Packer + Ansible

> **الهدف في سطر:** تبطّل "تطبخ" كل instance وقت الـ boot (`dnf install docker` على كل scale-out) وتبني **golden AMI** مرة واحدة بـ **Packer** و **نفس Ansible playbook** بتاع الـ hosts الحية، تديه لـ stack 40 بـ `ami_id` + `golden_ami = true`، وتشوف الـ instance refresh بيعمل **auto rollback حقيقي** لأن الـ Launch Template هو اللي اتغيّر — مع AMI lifecycle (deprecate/deregister/snapshots) وقياس فرق الـ boot.
> **المستوى:** Intermediate → Advanced · **الوقت:** ~3 ساعات · **التكلفة التقريبية:** سنتات لكل build + تخزين الـ snapshots (تقريبي، راجع صفحة الأسعار)
> **بيعتمد على:** [42](42-alb-asg-launch-template.md) · [21 — Terraform + Ansible](21-ec2-compose-terraform-ansible.md) · **الملفات في الـ repo:** [`infra/packer/app-ami.pkr.hcl`](../../../infra/packer/app-ami.pkr.hcl) · [`infra/packer/variables.pkr.hcl`](../../../infra/packer/variables.pkr.hcl) · [`infra/packer/README.md`](../../../infra/packer/README.md) · [`infra/ansible/playbooks/provision.yml`](../../../infra/ansible/playbooks/provision.yml) · [`infra/ansible/roles/`](../../../infra/ansible/roles) · [`modules/asg-app/main.tf`](../../../infra/terraform/modules/asg-app/main.tf) · [`modules/asg-app/user-data.sh.tftpl`](../../../infra/terraform/modules/asg-app/user-data.sh.tftpl)

## 1) الفكرة (Concepts)

**Immutable infrastructure**: السيرفر عمره ما بيتعدّل وهو شغال. أي تغيير (patch، package، config) = image جديدة → test → استبدال الـ instances. المكسب: كل instance **متطابقة**، الـ boot أسرع وأضمن (مفيش mirror واقع في نص الـ boot)، والـ rollback = ارجع للـ AMI القديمة.

| المصطلح | المعنى |
|---|---|
| Golden AMI | AMI فيها كل اللي الـ host محتاجه (OS patches، Docker، agents) قبل أي boot |
| Bake | تجهيز وقت **البناء** (Packer) |
| Fry | تجهيز وقت **الـ boot** (user data / cloud-init / Ansible pull) |
| Packer `source` | الـ builder (`amazon-ebs`): instance مؤقتة → provisioners → snapshot → AMI |
| Provisioner | `shell` / `ansible` بيجروا على الـ instance المؤقتة |
| Post-processor | بعد الـ build (هنا `manifest` → `manifest.json` فيه الـ AMI ID) |
| AMI deprecation | الـ AMI تختفي من الـ listings الافتراضية بعد تاريخ معين (لسه شغالة لو حد بيستخدمها) |
| Deregister | مسح الـ AMI (الـ snapshot **مبيتمسحش** معاها تلقائياً) |

### Bake مقابل Fry — وإيه اللي الـ repo عامله

| | Fry (stack 40 الـ default) | Bake (السيناريو ده) | Hybrid (الـ repo فعلياً) |
|---|---|---|---|
| Docker | `dnf -y install docker` كل boot | جوه الـ AMI | جوه الـ AMI |
| CloudWatch agent، node_exporter، sysctl، swap، journald | مش موجودين | جوه الـ AMI (roles الـ `provision.yml`) | جوه الـ AMI |
| الـ release (image الـ app) | من SSM وقت الـ boot | ممكن `prepull_image` | **من SSM وقت الـ boot دايماً** (+ prepull اختياري للـ layers) |
| الـ config والـ secrets | `app.env` من SSM | — | `app.env` من SSM وقت الـ boot |
| سرعة الـ boot | أبطأ (dnf + pull كامل) | أسرع | أسرع |
| الاعتماد على الإنترنت وقت الـ boot | dnf repos + ECR | ECR بس | ECR بس |
| تغيير صغير في الـ host | تعديل user data (LT version جديدة) | build جديد (~8 دقايق) | build جديد |

الـ repo مش بيحط الـ **release** جوه الـ AMI (ده "full bake" — AMI لكل commit): build لكل commit بطيء، والـ AMIs بتتراكم، والـ release بيبقى مربوط بالـ OS. الفصل ده بيخلّي: **الـ OS/runtime = AMI (Terraform/Packer)**، و **الـ app = IMAGE_URI (CI)**.

## 2) المعمارية (Architecture)

```text
 packer build .   (من WSL، credentials بتاعتك)
  └─ source "amazon-ebs" "app"
       source_ami_filter: al2023-ami-2023.*-<arch> (owner amazon, most_recent)   ← بيستبعد الـ minimal (مفيهاش SSM agent)
       instance: t3.small | t4g.small · temp key pair + temp SG (SSH من IP جهازك بس) · IMDSv2 (imds_support v2.0)
       root gp3 16 GiB encrypted → encrypt_boot
       provisioners:
         1) shell : cloud-init status --wait            (عشان Ansible ميصطدمش بـ rpm lock)
         2) ansible: ../ansible/playbooks/provision.yml  groups=[role_app]  use_proxy=false
                     common · docker (compose/buildx pinned, live-restore) · cloudwatch_agent · node_exporter
         3) shell : docker pull $prepull_image           (لو متحدد؛ محتاج iam_instance_profile)
         4) shell : cleanup (agent state, ~/.docker/config.json, journal, image prune)
       ─► AMI student-app-lab-<arch>-<YYYYMMDDhhmmss>  (tags Project/Env/ManagedBy=packer/Scenario=43/Arch, deprecate_at +90d)
       ─► manifest.json  builds[-1].artifact_id = "us-east-1:ami-0abc…"
                      │
                      ▼
 stack 40: ami_id = "ami-0abc…", golden_ami = true
   → aws_launch_template: image_id جديد → version جديدة (update_default_version)
   → aws_autoscaling_group.launch_template.version = latest_version (رقم)
   → instance_refresh block: Rolling, min 50 / max 100, warmup 120, auto_rollback = true, alarms (5xx + unhealthy)
   → user data: install_docker = false (مفيش dnf) → app.env + IMAGE_URI من SSM → docker run
```

## 3) المتطلبات (Prerequisites)

- [ ] stack 40 شغال ([42](42-alb-asg-launch-template.md)).
- [ ] على WSL: `packer >= 1.11` و Ansible (+ collections) من [`infra/ansible/README.md`](../../../infra/ansible/README.md#1-install-wsl2-ubuntu). الـ repo جوه filesystem الـ WSL (مش `/mnt/c`) عشان `ansible.cfg` يتقري.
- [ ] credentials تقدر تعمل instances/volumes/snapshots/AMIs + key pairs و SGs مؤقتة.
- [ ] Default VPC موجود (أو `-var subnet_id=<public subnet>`).

## 4) الطريقة الأولى: AWS Console (يدوي)

### 4.1 AMI بإيدك (عشان تحس باللي Packer بيأتمته)

1. **EC2 → Launch instance**: Name `student-app-lab-ami-builder` · AMI: Amazon Linux 2023 · `t3.small` · من غير key pair · Network: default VPC، public subnet · IAM instance profile: `student-app-lab-asg-app` (فيه SSM) → **Launch**.
2. **Connect → Session Manager**:

```bash
sudo cloud-init status --wait
sudo dnf -y install docker && sudo systemctl enable docker
sudo dnf -y install amazon-cloudwatch-agent
sudo rm -f /root/.docker/config.json && sudo journalctl --rotate && sudo journalctl --vacuum-time=1s
```

3. **Instances → الـ instance → Actions → Image and templates → Create image**: Name `student-app-lab-x86_64-manual-<date>` · ✅ Reboot instance (filesystem متّسق) · Tags: `Project=student-app`، `Env=lab`، `ManagedBy=console`، `Scenario=43` → **Create image**.
4. **AMIs** → استنى `Available` → **Actions → Manage AMI deprecation** → ✅ Enable → بعد 90 يوم.
5. **Terminate** الـ builder instance.

> 💡 البديل الـ managed: **EC2 Image Builder** (recipes + components + pipeline بـ schedule + distribution لـ regions/accounts + tests). Packer أبسط ومحمول (نفس الأداة لـ GCP/Azure/Docker).

### 4.2 Launch Template version جديدة + instance refresh بـ auto rollback

1. **Launch templates → `student-app-lab-blue-…` → Actions → Modify template (Create new version)** → AMI: **My AMIs** → الـ AMI الجديدة → **Create template version**. (لو الـ ASG على "Latest" هيستخدمها في الـ launches الجاية.)
2. **Auto Scaling groups → `student-app-lab-blue` → Instance refresh → Start instance refresh**:
   - Instance replacement method: **Launch before terminating** (أو Terminate and launch) · Min healthy 100% · Max healthy 150%
   - Instance warmup: 120 · **Skip matching**: ✅ (هنا مفيد: الـ instances اللي على الـ AMI الجديدة فعلاً تتساب)
   - **Desired configuration**: Launch template version = الرقم الجديد (مش `$Latest`)
   - CloudWatch alarms: ✅ `student-app-lab-alb-5xx-ratio` و `student-app-lab-blue-unhealthy-hosts`
   - Rollback settings: ✅ **Enable auto rollback**
3. راقب التاب لحد `Successful`.

> ⚠️ لو الـ stack 40 بالـ Terraform: التعديل اليدوي على الـ LT = drift؛ الـ apply الجاي هيرجّع الـ AMI بتاعة الـ code. عشان كده الطريقة الصح §5.

## 5) الطريقة التانية: Infrastructure as Code (Packer + Terraform)

### 5.1 الـ Variables ([`variables.pkr.hcl`](../../../infra/packer/variables.pkr.hcl))

| Variable | Default | ملاحظة |
|---|---|---|
| `region` | `us-east-1` | الـ AMI regional (انسخها بـ `ami_regions` لو محتاج) |
| `project` / `env` | `student-app` / `lab` | الاسم والـ tags |
| `arch` | `x86_64` | `arm64` = Graviton (`t4g`)؛ **لازم يساوي `arch` في stack 40** |
| `instance_type` | `""` | فاضي = `t3.small` أو `t4g.small` (instance الـ build) |
| `root_volume_size` | `16` | **لازم ≤ 20** (`root_volume_size` في `modules/asg-app`) |
| `kms_key_id` | `""` | فاضي = `aws/ebs` |
| `ssh_interface` | `public_ip` | أو `session_manager` (مفيش inbound خالص؛ محتاج `iam_instance_profile`) |
| `iam_instance_profile` | `""` | لـ `session_manager` و `prepull_image`: `student-app-lab-asg-app` (من stack 40) فيه بالظبط اللي محتاجه |
| `subnet_id` | `""` | فاضي = default VPC (لازم public: dnf/GitHub) |
| `prepull_image` | `""` | image من ECR تتخزن layers بتاعتها في الـ AMI |
| `ami_deprecate_days` | `90` | `deprecate_at` |

### 5.2 أهم سطور الـ template ([`app-ami.pkr.hcl`](../../../infra/packer/app-ami.pkr.hcl))

| السطر | ليه |
|---|---|
| `source_ami_filter name = "al2023-ami-2023.*-${var.arch}"`، `owners = ["amazon"]`، `most_recent = true` | دايماً آخر AL2023 رسمية (patching = rebuild)، ومن غير الـ minimal |
| `imds_support = "v2.0"` + `metadata_options` (tokens required، hop 1) | كل instance من الـ AMI دي IMDSv2-only حتى لو حد نسي في الـ LT |
| `launch_block_device_mappings { encrypted = true }` + `encrypt_boot = true` | snapshot encrypted → AMI encrypted |
| `temporary_security_group_source_public_ip = true` | الـ SG المؤقت بيفتح SSH للـ IP بتاعك بس |
| `ssh_clear_authorized_keys = true` | المفتاح المؤقت مبيفضلش في الـ image |
| `provisioner "ansible"` بـ `playbook_file = .../provision.yml`، `groups = ["role_app"]`، `use_proxy = false` | **نفس التعريف** بتاع host الـ [21](21-ec2-compose-terraform-ansible.md)؛ الاتصال مباشر بالمفتاح المؤقت (الـ proxy أبطأ وبيكسر scp مع OpenSSH 9) |
| `extra_arguments = ["--extra-vars", "env_name=${var.env} aws_region=${var.region}"]` | الـ roles بتستخدمهم (log group prefix…) |
| cleanup provisioner | الـ AMI متشيلش credentials الـ registry، ولا offsets بتاعة الـ agent، ولا journal الـ build |
| `post-processor "manifest"` | `manifest.json` (gitignored) → `artifact_id` |
| `tags` فيها `SourceAMI` و `SourceAMIName` | تعرف كل golden AMI اتبنت من أنهي base (audit / CVE triage) |

### 5.3 Build

```bash
cd infra/packer
packer init .
packer fmt -check . && packer validate .
packer build .                                     # ~8 دقايق
jq -r '.builds[-1].artifact_id' manifest.json      # us-east-1:ami-0abc123...

# بديل من غير أي inbound port + layers الـ release الحالي متخزنة:
ACCT=$(aws sts get-caller-identity --query Account --output text)
packer build -var ssh_interface=session_manager -var iam_instance_profile=student-app-lab-asg-app \
             -var prepull_image=$ACCT.dkr.ecr.us-east-1.amazonaws.com/student-app:<SHA> .
```

### 5.4 استخدمها في stack 40

```bash
AMI=$(jq -r '.builds[-1].artifact_id' infra/packer/manifest.json | cut -d: -f2)
cd infra/terraform/stacks/40-ec2-alb-asg
# terraform.tfvars:  ami_id = "<AMI>"   golden_ami = true    (أحسن من -var: الـ apply الجاي ميرجّعش الـ AL2023)
terraform plan -out=tfplan        # ~ aws_launch_template.this (image_id, user_data) + ~ aws_autoscaling_group.this (launch_template.version)
terraform apply tfplan
aws autoscaling describe-instance-refreshes --auto-scaling-group-name student-app-lab-blue --max-records 1 \
  --query 'InstanceRefreshes[0].{status:Status,pct:PercentageComplete,reason:StatusReason,desired:DesiredConfiguration.LaunchTemplate.Version}'
```

ليه الـ refresh هنا عنده **auto rollback حقيقي** (عكس [44](44-rolling-instance-refresh.md))؟ الـ `instance_refresh` block في الـ ASG بيتشغّل لما الـ LT يتغيّر، والـ ASG بيشاور على **رقم version محدد** (`latest_version`)، فـ AWS عنده "configuration سابقة" يرجعلها: الـ LT version القديمة = الـ AMI القديمة. (AWS مش بيعمل rollback لو الـ ASG على `$Latest`/`$Default`، ولا لو الـ LT نفسه بيستخدم AMI alias من SSM — والـ module بيحوّل `/aws/service/ami-amazon-linux-latest/...` لـ AMI ID وقت الـ plan، فالـ LT فيه ID حقيقي.)

> ⚠️ `terraform apply` بيبدأ الـ refresh **ومبيستناهوش**. لو الـ refresh فشل ورجع، الـ ASG بقى على الـ version القديمة والـ code لسه بيقول الجديدة → الـ plan الجاي هيحاول تاني بنفس الـ AMI البايظة. **صلّح الـ code** (`ami_id`) قبل أي apply جديد. وكمان: لو alarm من الـ alarms في `ALARM` أو `INSUFFICIENT_DATA` لحظة البدء، الـ API بيرفض يبدأ الـ refresh والـ apply نفسه بيفشل.

## 6) الـ Deploy — قياس فرق الـ boot

الـ user data بيطبع `student-app boot finished: <date -Iseconds>` في آخره. قارن بـ `LaunchTime` (قبل وبعد الـ golden AMI):

```bash
for IID in $(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names student-app-lab-blue \
               --query 'AutoScalingGroups[0].Instances[].InstanceId' --output text); do
  LAUNCH=$(aws ec2 describe-instances --instance-ids "$IID" --query 'Reservations[0].Instances[0].LaunchTime' --output text)
  CID=$(aws ssm send-command --instance-ids "$IID" --document-name AWS-RunShellScript \
          --parameters 'commands=["grep \"boot finished\" /var/log/cloud-init-output.log","grep -c \"retry\" /var/log/cloud-init-output.log || true","cloud-init analyze show | tail -3"]' \
          --query Command.CommandId --output text)
  sleep 5
  echo "== $IID launched $LAUNCH"
  aws ssm get-command-invocation --command-id "$CID" --instance-id "$IID" --query StandardOutputContent --output text
done
```

| المقياس | AL2023 + fry | Golden AMI | Golden + `prepull_image` |
|---|---|---|---|
| LaunchTime → `boot finished` | سجّل الرقم | سجّل الرقم | سجّل الرقم |
| LaunchTime → target `healthy` (من الـ TG / activity history) | | | |
| مصادر خارجية وقت الـ boot | dnf repos + ECR | ECR | ECR (layers متغيرة بس) |

الـ module بيقول "boot is ~30s faster" مع `golden_ami` — قيسه بنفسك؛ الرقم الحقيقي بيفرق في سرعة الـ scale-out ([48](48-autoscaling-under-load.md)) وفي الـ grace period/warmup اللي تقدر تقللهم.

## 7) التحقق (Verify)

```bash
aws ec2 describe-images --owners self --filters Name=tag:Project,Values=student-app \
  --query 'sort_by(Images,&CreationDate)[].{id:ImageId,name:Name,created:CreationDate,deprecate:DeprecationTime,src:Tags[?Key==`SourceAMIName`]|[0].Value}' --output table
LT=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names student-app-lab-blue --query 'AutoScalingGroups[0].LaunchTemplate' --output json)
echo "$LT"
aws ec2 describe-launch-template-versions --launch-template-id "$(jq -r .LaunchTemplateId <<<"$LT")" --versions "$(jq -r .Version <<<"$LT")" \
  --query 'LaunchTemplateVersions[0].LaunchTemplateData.ImageId'
curl -s "$(terraform -chdir=infra/terraform/stacks/40-ec2-alb-asg output -raw app_url)/ready" | jq .
```

وعلى instance (Session Manager): `docker version --format '{{.Server.Version}}'`، `systemctl is-active amazon-cloudwatch-agent`، `docker ps --format '{{.Names}}'` (لازم `student-app` و `node-exporter`)، و `grep -c 'dnf -y install docker' /var/log/cloud-init-output.log` = 0.

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر | المتوقع |
|---|---|---|
| "golden_ami" كدّاب | `ami_id` = AL2023 العادية (`aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --query Parameter.Value --output text`) + `golden_ami = true` → apply | الـ user data بيتخطى الـ install، و `systemctl enable --now docker` يفشل (`Unit docker.service not found`) → `set -e` يوقف السكريبت → مفيش container → unhealthy → alarm `blue-unhealthy-hosts` → الـ refresh **Failed + auto rollback** للـ LT version القديمة. بعدها `terraform plan` هيطلب نفس التغيير تاني (§5.4 ⚠️) |
| Arch غلط | `packer build -var arch=arm64` واستخدمها مع `t3.micro` | الـ launch نفسه بيفشل (architecture mismatch) → الـ refresh يفشل ويرجع |
| الـ build وقع في النص | Ctrl+C أثناء `packer build` | Packer بينضّف الـ instance والـ SG والـ key pair المؤقتين؛ اتأكد: `aws ec2 describe-instances --filters Name=tag:Name,Values=student-app-lab-packer-build Name=instance-state-name,Values=running` |
| Rollback يدوي أثناء refresh | `aws autoscaling rollback-instance-refresh --auto-scaling-group-name student-app-lab-blue` | ينفع بس والـ refresh لسه شغال، ولأن الـ LT version رقم |

## 9) الرجوع (Rollback)

```bash
# AMI سليمة قديمة (أحدث واحدة قبل الحالية):
aws ec2 describe-images --owners self --filters Name=tag:Scenario,Values=43 Name=tag:Arch,Values=x86_64 \
  --include-deprecated --query 'sort_by(Images,&CreationDate)[-2].ImageId' --output text
# حطها في terraform.tfvars (ami_id) ثم:
terraform -chdir=infra/terraform/stacks/40-ec2-alb-asg apply
# أو ارجع للـ fry: امسح ami_id و golden_ami من tfvars → AL2023 + docker install
```

## 10) المسح (Teardown) ⚠️

الـ AMI بتتحاسب بالـ **snapshot** بتاعها، و `deregister-image` مبيمسحش الـ snapshot:

```bash
for AMI in $(aws ec2 describe-images --owners self --include-deprecated --filters Name=tag:Project,Values=student-app \
               --query 'Images[].ImageId' --output text); do
  SNAPS=$(aws ec2 describe-images --image-ids "$AMI" --include-deprecated --query 'Images[0].BlockDeviceMappings[].Ebs.SnapshotId' --output text)
  aws ec2 deregister-image --image-id "$AMI" && echo "deregistered $AMI"
  for S in $SNAPS; do aws ec2 delete-snapshot --snapshot-id "$S" && echo "  deleted $S"; done
done
aws ec2 describe-snapshots --owner-ids self --filters Name=tag:Project,Values=student-app --query 'Snapshots[].SnapshotId'
```

⚠️ متمسحش AMI لسه في LT version مستخدم (الـ scale-out الجاي هيفشل). شيل `ami_id`/`golden_ami` من tfvars واعمل apply الأول، أو امسح الـ stack كله. ولو عندك Recycle Bin retention rule للـ snapshots/AMIs، المسح بيحطهم فيه.

## 11) التكلفة (Cost)

| Resource | السعر التقريبي (us-east-1 — تقريبي، راجع صفحة الأسعار) |
|---|---|
| Build instance `t3.small` (~8–10 دقايق) | ~$0.0208/ساعة → أقل من سنت |
| EBS volume مؤقت (16 GiB gp3، دقايق) | أقل من سنت |
| EBS snapshot (incremental، البلوكات المستخدمة بس ~ كام GiB) | ~$0.05/GB-شهر لكل AMI لحد ما تمسحها |
| AMI deprecated لسه متمسحتش | **لسه بتتحاسب** (الـ snapshot) |
| EC2 Image Builder (البديل) | الخدمة مجانية؛ بتدفع الـ instances والـ snapshots |

## 12) أسئلة Interview

<details><summary>Bake ولا fry؟</summary>

Bake للحاجات البطيئة أو الهشة أو اللي لازم تبقى متطابقة (OS patches، runtime، agents) → boot سريع وأكيد، و scale-out أسرع. Fry للحاجات اللي بتتغير كتير أو بتختلف لكل environment (config، secrets، الـ release) → AMI واحدة لكل البيئات. الـ hybrid (الـ repo): AMI للـ host + الـ app image/config من SSM وقت الـ boot. Full bake لكل commit بيبطّأ الـ CI ويكدّس AMIs، ومفيدة لما الـ boot time هو كل حاجة.

</details>

<details><summary>إزاي بتعمل patching لـ fleet immutable؟</summary>

pipeline بيبني AMI جديدة من آخر base (schedule أسبوعي + عند CVE حرج)، يعمل tests (instance من الـ AMI + smoke/inspector scan)، ينشر الـ AMI ID (tfvars/SSM parameter)، والـ ASG يعمل instance refresh بـ alarms و auto rollback. مفيش SSH ولا `yum update` على instance شغالة. ملحوظة: الـ `common` role مفعّل `dnf-automatic` (security) — ده بيخلّي الـ instances تتغيّر بعد الـ boot، وده تنازل عن الـ immutability لصالح سرعة الـ patching؛ فريق تاني ممكن يقفله ويعتمد على الـ rebuild.

</details>

<details><summary>ليه instance refresh بعد AMI جديدة عنده auto rollback، وبعد image جديدة في SSM لأ؟</summary>

الـ auto rollback محتاج **desired configuration** ويرجع لـ "آخر configuration محفوظة على الـ ASG" = LT version (رقم محدد). مع AMI جديدة الـ LT اتغيّر فعلاً → فيه حاجة يرجعلها. مع release في SSM الـ LT متغيّرش → الـ rollback هيرجّع نفس الـ LT والـ instances هتبوت نفس الـ image البايظة. عشان كده `deploy-asg.yml` بيعمل `AutoRollback=false` ويرجّع الـ pointer بنفسه ([44](44-rolling-instance-refresh.md)).

</details>

<details><summary>إيه الـ lifecycle الصح للـ AMIs؟</summary>

tags (source AMI، commit، arch، تاريخ)، deprecation تلقائي (`deprecate_at`)، retention (آخر N أو M يوم + أي AMI لسه مستخدمة في LT/ASG)، deregister **+ delete snapshot** (أو Data Lifecycle Manager / Recycle Bin)، ومشاركة cross-account/region بـ launch permissions و KMS key policy لو encrypted. وخلّي آخر AMI سليمة موجودة دايماً للـ rollback.

</details>

<details><summary>ليه نفس الـ Ansible playbook في Packer وعلى الـ hosts الحية؟</summary>

تعريف واحد لـ "host الـ student-app" (DRY): الـ standalone host ([21](21-ec2-compose-terraform-ansible.md)) والـ golden AMI بيتبنوا من نفس الـ roles، فمفيش drift بين الاتنين، والـ playbook نفسه بيتعمله lint في الـ CI. الفرق إن مع Packer الـ playbook بيجري مرة وقت البناء، مش على كل instance.

</details>

<details><summary>إيه اللي ممكن يبوظ في golden AMI pipeline؟</summary>

base AMI اتغيرت وكسرت حاجة (pin أو test)، credentials/keys اتخبزت في الـ image (الـ cleanup provisioner + `ssh_clear_authorized_keys`)، cloud-init لسه شغال وقت الـ provisioning (rpm lock — الـ `cloud-init status --wait`)، arch/root volume مش متوافقين مع الـ LT، snapshots يتيمة بتتحاسب، و AMI encrypted بـ KMS key مش متشارك مع الـ ASG service-linked role (الـ launch يفشل).

</details>

## 13) Checklist

- [ ] عملت AMI بإيدك من الـ console وفهمت ليه ده مش scalable
- [ ] بنيت golden AMI بـ `packer build` وقريت `manifest.json`
- [ ] استخدمتها في stack 40 (`ami_id` + `golden_ami`) وتابعت الـ instance refresh
- [ ] قست الـ boot time قبل وبعد
- [ ] جرّبت "golden_ami الكدّاب" وشفت الـ auto rollback
- [ ] نضّفت الـ AMIs **والـ snapshots**
