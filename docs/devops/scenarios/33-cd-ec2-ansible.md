# 33 — CD → EC2 بـ Ansible

> **الهدف في سطر:** تشغّل [`deploy-ec2-ansible.yml`](../../../.github/workflows/deploy-ec2-ansible.yml): الـ GitHub runner هو الـ **Ansible controller**، الـ inventory **dynamic** من AWS بالـ tags، والـ connection **SSM** (session-manager-plugin + S3 transfer bucket، من غير بورت 22) أو SSH، وتثبت إن الـ deploy **idempotent** (نفس الـ image مرتين = `changed=0`)، وتقارن بموضوعية بـ [32](32-cd-ec2-ecr-ssm.md).
> **المستوى:** Intermediate → Advanced · **الوقت:** ~2–3 ساعات · **التكلفة التقريبية:** نفس [20](20-ec2-compose-console.md) (+ ~$0 للـ transfer bucket)
> **بيعتمد على:** [21](21-ec2-compose-terraform-ansible.md) (Ansible locally) · [32](32-cd-ec2-ecr-ssm.md) · **الملفات في الـ repo:** [`.github/workflows/deploy-ec2-ansible.yml`](../../../.github/workflows/deploy-ec2-ansible.yml) · [`infra/ansible/playbooks/deploy.yml`](../../../infra/ansible/playbooks/deploy.yml) · [`infra/ansible/roles/app/`](../../../infra/ansible/roles/app/) · [`infra/ansible/inventories/lab/aws_ec2.yml`](../../../infra/ansible/inventories/lab/aws_ec2.yml) · [`group_vars/all/main.yml`](../../../infra/ansible/inventories/lab/group_vars/all/main.yml) · [`infra/ansible/requirements.yml`](../../../infra/ansible/requirements.yml) · [`infra/terraform/bootstrap/ansible-ssm.tf`](../../../infra/terraform/bootstrap/ansible-ssm.tf) · [`infra/terraform/bootstrap/github-oidc.tf`](../../../infra/terraform/bootstrap/github-oidc.tf)

## 1) الفكرة (Concepts)

في [21](21-ec2-compose-terraform-ansible.md) شغّلت Ansible من WSL بالـ credentials بتاعتك. هنا نفس الـ playbook بالظبط بيجري من **GitHub Actions** بـ OIDC role. الفرق عن [32](32-cd-ec2-ecr-ssm.md):

- **32** بيبعت **سكريبت** (imperative): "اعمل الخطوات دي".
- **33** بيبعت **حالة مطلوبة** (declarative-ish): "السيرفر لازم يبقى عليه الملفات دي، والـ env ده، والـ release دي" — وAnsible بيقرر يعمل إيه (ولو مفيش فرق → مبيعملش حاجة).

| المصطلح | المعنى |
|---|---|
| Controller | الماكينة اللي بتشغّل `ansible-playbook` (هنا: الـ runner) — الـ managed nodes مبيحتاجوش Ansible |
| `amazon.aws.aws_ec2` | inventory plugin بيعمل `DescribeInstances` بالـ filters ويبني groups من الـ tags |
| `amazon.aws.aws_ssm` | connection plugin: بيشغّل الـ modules جوه Session Manager session |
| Transfer bucket | S3 bucket الـ controller بيرفع عليه ملفات الـ modules، والـ instance بينزّلها بـ presigned URL |
| Check mode | `--check --diff`: يوريك إيه اللي **كان** هيتغيّر من غير ما يغيّر |
| PLAY RECAP | ملخص `ok/changed/failed/skipped` لكل host — الدليل على الـ idempotency |

## 2) المعمارية (Architecture)

```text
 GitHub Actions runner = Ansible controller           workflow_dispatch: image_tag, connection (ssm|ssh),
 environment: lab · concurrency deploy-lab-ec2-single                    target_hosts (role_app:&standalone), check_mode
 ┌────────────────────────────────────────────────────────────────────────────────────────────┐
 │ setup-python 3.12 · pip ansible-core>=2.18,<2.22 boto3/botocore>=1.38 · cache collections  │
 │ ansible-galaxy collection install -r requirements.yml  (amazon.aws 12.x, community.*)       │
 │ [ssm] session-manager-plugin .deb     [ssh] ~/.ssh/deploy_key ◄── secrets.EC2_SSH_PRIVATE_KEY│
 │ OIDC → student-app-gha-deploy                                                               │
 │ ecr describe-images tag → uri = <acct>.dkr.ecr.<region>.amazonaws.com/student-app:<tag>     │
 │ ansible-inventory --graph ; ansible "$TARGET_HOSTS" --list-hosts                            │
 │ ansible-playbook playbooks/deploy.yml -e app_image=… -e target_hosts=… -e deploy_connection=…│
 │                                       -e aws_region=… [-e ssm_bucket_name=$ANSIBLE_SSM_BUCKET]│
 └──────────┬──────────────────────────────────┬───────────────────────────────────────────────┘
            │ ec2:DescribeInstances            │ ssm:StartSession (tag Project=student-app)
            ▼                                  ▼                         S3 student-app-ansible-ssm-<acct>
     inventory: role_app:&standalone      Session Manager  ◄── agent ──►  ▲ PutObject (controller)
                                               │                         │ GET presigned URL (instance, curl)
                                               ▼
                                EC2 (stack 20) — become root:
                                  files.yml → env.yml (SSM → staging → copy ec2-user 0600) → deploy.yml (لو اتغيّر)
                                  → deploy-pull-image.sh <image> → smoke /ready
 ┌─ job summary: image · hosts · smoke · live version · PLAY RECAP ─┐
```

## 3) المتطلبات (Prerequisites)

- [ ] stack 20 شغال والـ instance Online ([21](21-ec2-compose-terraform-ansible.md)).
- [ ] Repository variables: `AWS_DEPLOY_ROLE_ARN`، `AWS_REGION`، `ECR_REPOSITORY`، **`ANSIBLE_SSM_BUCKET`** (bootstrap output `ansible_ssm_bucket` — [02 §5.8](02-aws-account-setup.md)).
- [ ] `APP_URL` على environment `lab`.
- [ ] الـ tag في ECR.
- [ ] الـ workflow على `master` (شرط `workflow_dispatch`).
- لـ SSH mode بس: secret `EC2_SSH_PRIVATE_KEY` + `ssh_cidrs`/`key_name` في stack 20 ([31](31-cd-ec2-ssh-build-on-server.md)).

## 4) الطريقة الأولى: AWS Console (المراقبة)

مفيش "Console way" لـ Ansible — بس الـ Console بيوريك اللي حصل فعلاً، وده مهم في الـ debugging والـ audit:

1. **Systems Manager → Session Manager → Session history** → sessions بـ Owner = `.../student-app-gha-deploy/deploy-ansible-<run_id>-<attempt>` — Ansible بيفتح sessions (أكتر من واحدة) طول الـ playbook.
2. **S3 → `student-app-ansible-ssm-<acct>`** وقت الـ run → objects مؤقتة (ملفات الـ modules) — بتتمسح بعد يوم بالـ lifecycle.
3. **CloudTrail → Event history** → `StartSession` و `TerminateSession` بنفس الـ session name.
4. **IAM → Roles → `student-app-gha-deploy`** → statements `SsmSessionsProjectInstances` (`ssm:StartSession` على instances عليها `Project=student-app`)، `SsmSessionDocuments` (`AWS-StartInteractiveCommand`، `SSM-SessionManagerRunShell`)، `SsmOwnSessions`، `AnsibleSsmTransferBucket`(`List`).

## 5) الطريقة التانية: Infrastructure as Code

### 5.1 اللي محتاجه موجود في الـ bootstrap

- **الـ bucket** ([`ansible-ssm.tf`](../../../infra/terraform/bootstrap/ansible-ssm.tf)): `student-app-ansible-ssm-<acct>`، SSE-S3، public block، expire بعد يوم، `force_destroy = true`.
- **الـ deploy role**: Sessions مقفولة بالـ tag، و S3 `GetObject`/`PutObject`/`DeleteObject` على `bucket/*` + `ListBucket`/`GetBucketLocation` على الـ bucket، و `ec2:DescribeInstances` (للـ inventory). **الـ instance مش محتاج أي S3 permission.**
- **الـ group_vars**: `deploy_connection: ssm` → `ansible_connection: amazon.aws.aws_ssm`، `ansible_aws_ssm_bucket_name: "{{ ssm_bucket_name }}"`، `ansible_aws_ssm_bucket_sse_mode: AES256`، `ansible_aws_ssm_region: "{{ aws_region }}"`.

```bash
gh variable set ANSIBLE_SSM_BUCKET --body "$(terraform -chdir=infra/terraform/bootstrap output -raw ansible_ssm_bucket)"
```

### 5.2 نفس الـ deploy من WSL (عشان تفهم اللي الـ runner بيعمله)

```bash
cd ~/src/StudentHub/infra/ansible && source ~/.venvs/ansible/bin/activate
IMG=<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/student-app:<TAG>
ansible-playbook playbooks/deploy.yml -e app_image=$IMG -e target_hosts='role_app:&standalone' \
  -e deploy_connection=ssm -e aws_region=us-east-1 \
  -e ssm_bucket_name=$(terraform -chdir=../terraform/bootstrap output -raw ansible_ssm_bucket)
```

## 6) الـ Deploy

### 6.1 تشغيل الـ workflow

```bash
TAG=$(aws ecr describe-images --repository-name student-app --query 'sort_by(imageDetails,&imagePushedAt)[-1].imageTags[0]' --output text)

# dry run الأول
gh workflow run deploy-ec2-ansible.yml --ref devops-lab -f image_tag=$TAG -f connection=ssm -f check_mode=true
# الحقيقي
gh workflow run deploy-ec2-ansible.yml --ref devops-lab -f image_tag=$TAG -f connection=ssm
# تاني مرة بنفس الـ tag — إثبات الـ idempotency
gh workflow run deploy-ec2-ansible.yml --ref devops-lab -f image_tag=$TAG -f connection=ssm
gh run view "$(gh run list --workflow=deploy-ec2-ansible.yml --limit 1 --json databaseId --jq '.[0].databaseId')" --log | grep -A3 "PLAY RECAP"
```

### 6.2 الـ workflow خطوة بخطوة

| Step | التفاصيل | نقطة senior |
|---|---|---|
| Inputs | `image_tag`، `connection` (choice ssm/ssh)، `target_hosts` (افتراضي `role_app:&standalone`)، `check_mode` | |
| Job | `environment: lab`، concurrency `deploy-lab-ec2-single` (مشترك مع 31/32/23/24)، `id-token: write`، `working-directory: infra/ansible` | `ansible.cfg` بيتقري من هنا → الـ inventory والـ roles |
| Validate inputs | tag regex و ≠ `latest`؛ `target_hosts` يطابق `^[A-Za-z0-9_:\&\!.*,-]+$` | الـ pattern بيروح لـ CLI → whitelist |
| setup-python 3.12 + pip | `ansible-core>=2.18,<2.22`، `boto3`/`botocore>=1.38` (cache pip بـ hash الـ workflow file) | 2.22 محتاج Python 3.13؛ والـ collections 12.x محتاجة core ≥ 2.18 |
| Cache + install collections | `~/.ansible/collections` بـ key = hash `requirements.yml` | |
| Session Manager plugin | `.deb` من `session-manager-downloads` (لو ssm) | الـ `aws_ssm` plugin بيستخدمه عشان يفتح الـ session |
| SSH key | لو ssh: `~/.ssh/deploy_key` من الـ secret | `ansible.cfg`: `host_key_checking = False` (lab بس — في prod pin أو SSM) |
| OIDC | `role-session-name: deploy-ansible-<run_id>-<attempt>` | |
| Resolve image | `describe-images` للتأكد إن الـ tag موجود → `uri=<repo>:<tag>` | **بالـ tag مش بالـ digest** (فرق عن 32 — §6.4) |
| Show the inventory | `ansible-inventory --graph` + `ansible "$TARGET_HOSTS" --list-hosts` | تشوف هتعمل deploy على مين **قبل** ما تعمل |
| Run deploy.yml | `-e app_image -e target_hosts -e deploy_connection -e aws_region` + `ssm_bucket_name` (يفشل برسالة واضحة لو `ANSIBLE_SSM_BUCKET` فاضي) أو `--private-key`؛ `--check --diff` لو check_mode؛ `tee ansible.log` | |
| Smoke | `/ready` بـ `--retry 12`، و `version == tag` (لو مش check mode) | |
| Summary | image/hosts/smoke/version + **PLAY RECAP** (من غير ألوان ANSI) | الـ idempotency بتبان في الـ summary على طول |
| Remove the key | لو ssh، `if: always()` | |

### 6.3 الـ idempotency في الـ CD

أول run بـ tag جديد: `changed` في "Deploy …" (والـ env لو اتغيّر). **التاني بنفس الـ tag:**

```text
TASK [app : Deploy 123456789012.dkr.ecr.us-east-1.amazonaws.com/student-app:3f2c1ab] ***
skipping: [i-0abc...]
PLAY RECAP *********************************************************************
i-0abc...  : ok=NN   changed=0    unreachable=0    failed=0    skipped=N
```

ليه ده مهم في الـ CD؟ تقدر تعيد تشغيل الـ pipeline (flake في الـ smoke، runner مات) **من غير** downtime زيادة ولا migrate تاني. وكمان **drift correction**: لو حد عدّل `app.env` بإيده، الـ run الجاي بيرجّعه ويعمل recreate (`app_env_changed`).

### 6.4 مقارنة 32 مقابل 33

| | 32 — SSM Run Command | 33 — Ansible |
|---|---|---|
| النموذج | سكريبت imperative بيتبعت مرة | desired state، idempotent |
| Dependencies على الـ runner | `aws` + `jq` بس | Python + ansible-core + 3 collections + session-manager-plugin (~1–2 دقيقة setup) |
| السرعة | أسرع (أمر واحد) | أبطأ (session + S3 round-trip لكل task) |
| التشغيل التاني بنفس الـ image | deploy كامل تاني (pull/migrate/recreate = downtime ثواني) | **no-op** |
| Drift في `app.env` | بيتكتب فوقه كل مرة | بيتكشف (`changed`) ويتصلّح |
| الـ image reference | `repo:tag@digest` (verifiable) | `repo:tag` |
| Dry run | مفيش | `--check --diff` (الملفات بس؛ الـ `command` tasks بتتخطّى) |
| Multi-host | `MaxConcurrency`/`MaxErrors` | `serial`، `max_fail_percentage`، `delegate_to` للـ LB ([47](47-ansible-rolling-deploy.md)) |
| Logs | Command history + CloudWatch Logs | الـ job log + Session history (مفيش output مركزي على AWS) |
| IAM | SendCommand + document | StartSession + documents + S3 bucket |
| الأنسب لـ | deploy سريع لـ release واحد، rollback، emergency | config management + deploy مع بعض، fleets، orchestration (drain → deploy → health-gate) |

> 💡 **خلط الاتنين على نفس الـ host:** 32 بيكتب `CURRENT_RELEASE = repo:tag@digest` و 33 بيمرّر `repo:tag`؛ الـ role بيقارن **بعد ما يشيل `@sha256:…`** من الناحيتين ([`roles/app/tasks/deploy.yml`](../../../infra/ansible/roles/app/tasks/deploy.yml))، فـ run من 33 بعد deploy من 32 بنفس الـ tag = **no-op** (مفيش recreate زيادة). الفرق الوحيد إن 33 مابيتحققش من الـ digest — الـ verification دي ميزة 32 و [34](34-environments-approvals-promotion.md).

## 7) التحقق (Verify)

```bash
gh run view <RUN_ID>                         # Summary: PLAY RECAP + Live version
aws ssm describe-sessions --state History --max-results 5 \
  --query 'Sessions[].{owner:Owner,target:Target,start:StartDate,end:EndDate}' --output table
aws s3 ls "s3://$(gh variable get ANSIBLE_SSM_BUCKET)/" --recursive | tail -5
curl -s <APP_URL>/ready | jq '{status, version}'
```

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر | المتوقع |
|---|---|---|
| مفيش bucket | `gh variable delete ANSIBLE_SSM_BUCKET` ثم run بـ ssm | `::error::set the ANSIBLE_SSM_BUCKET variable (bootstrap output ansible_ssm_bucket)` |
| bucket مش مسموح | `gh variable set ANSIBLE_SSM_BUCKET --body student-app-lab-backups-<acct>` | الـ deploy role مالوش S3 على الـ bucket ده → `AccessDenied` وقت نقل أول module (من اللابتوب كـ admin كان هيشتغل — الفرق في الـ IAM) |
| مفيش hosts | Stop الـ instance ثم run | `ansible "$TARGET_HOSTS" --list-hosts` → `hosts (0)` و `Could not match supplied host pattern` |
| pattern غلط | `-f target_hosts='role_app;rm'` | `::error::invalid target_hosts` |
| SSH من غير بورت | `-f connection=ssh` و `ssh_cidrs = []` | `UNREACHABLE! ... Connection timed out` |
| Check mode | `-f check_mode=true` بـ tag جديد | الـ RECAP بيقول changed في الملفات، و "Deploy" skipped (الـ `command` مش بيدعم check mode)، والـ smoke متخطّى — check mode مابيتنبّأش بنتيجة السكريبتات |
| `:latest` | `-f image_tag=latest` | يفشل في Validate inputs (وحتى لو عدّى: assert في الـ role) |
| Prod وlab في نفس الـ inventory | بعد [34](34-environments-approvals-promotion.md) لو عملت host `production` (workspace بـ `env=production`) | `role_app:&standalone` هيطابق **الاتنين** → استخدم `-f target_hosts='role_app:&standalone:&env_lab'` |

## 9) الرجوع (Rollback)

```bash
gh workflow run deploy-ec2-ansible.yml --ref devops-lab -f image_tag=<PREVIOUS_TAG> -f connection=ssm
# أو من WSL: الـ playbook بيختار الطريق (lb stack → rollback.sh ، Recreate → PREVIOUS_RELEASE)
ansible-playbook playbooks/rollback.yml -e target_hosts='role_app:&standalone' -e ssm_bucket_name=<BUCKET>
```

## 10) المسح (Teardown) ⚠️

الـ transfer bucket بيفضل (bootstrap، الـ objects بتتمسح لوحدها بعد يوم). امسح الـ SSH secret لو جرّبت ssh mode (`gh secret delete EC2_SSH_PRIVATE_KEY`)، والسيرفر بـ `terraform destroy` في stack 20 ([21 §10](21-ec2-compose-terraform-ansible.md)).

```bash
aws s3 ls "s3://$(terraform -chdir=infra/terraform/bootstrap output -raw ansible_ssm_bucket)/" --recursive | wc -l   # بيقل لـ 0 خلال يوم
```

## 11) التكلفة (Cost)

| Resource | السعر التقريبي (تقريبي — راجع صفحة الأسعار) |
|---|---|
| Session Manager | مجاني |
| S3 transfer bucket | ~$0 (KBs، بتتمسح بعد يوم؛ requests بسنتات) |
| GitHub Actions | ~3–6 دقايق لكل run (setup Python/Ansible/collections + الـ playbook) — أطول من 32 |
| EC2 | نفس [20](20-ec2-compose-console.md) |

## 12) أسئلة Interview

<details><summary>Ansible over SSM بيشتغل إزاي؟ ومين محتاج صلاحية إيه؟</summary>

الـ controller بيعمل `StartSession` (SSM API) والـ session-manager-plugin بيفتح websocket للـ agent على السيرفر (اللي عامل outbound 443). الأوامر بتتبعت جوه الـ session؛ ملفات الـ modules بتترفع على S3 بالـ controller، والسيرفر بينزّلها بـ curl على presigned URL. الـ controller: `ssm:StartSession`/`TerminateSession` على instances المشروع + documents + S3 على الـ bucket + `ec2:DescribeInstances`. السيرفر: SSM core بس.

</details>

<details><summary>ليه الـ deploy idempotent مهم في CD pipeline؟</summary>

re-runs آمنة (flake/timeout → اعمل retry من غير downtime أو migration تاني)، drift correction (التشغيل بيرجّع الـ config للحالة المكتوبة)، وتقدر تعمل "reconcile" دوري (cron يشغّل نفس الـ playbook) زي GitOps للـ VMs. السر: الـ deploy غير الـ idempotent (pull/migrate/recreate) محمي بشرط على الحالة (`CURRENT_RELEASE` و `app_env_changed`).

</details>

<details><summary>Push-based (Ansible من الـ CI) مقابل pull-based (agent على السيرفر بيسحب) — الفرق؟</summary>

Push: الـ controller محتاج يوصل لكل السيرفرات وcredentials عليها، التنفيذ متزامن وتشوف النتيجة فوراً، وسهل تعمل orchestration (serial، drain). Pull (ansible-pull، SSM State Manager، Argo CD للـ K8s): السيرفر بيسحب الحالة دورياً، بيتوسّع لآلاف السيرفرات، ومفيش credentials مركزية بتوصل لكل حاجة، بس الـ feedback أبطأ والـ orchestration أصعب.

</details>

<details><summary>الـ dynamic inventory بيحميك من إيه؟ وإيه مخاطره؟</summary>

مفيش IPs قديمة في ملف، السيرفرات الجديدة بتدخل لوحدها، والـ groups من الـ tags (`env_lab`، `standalone`). المخاطرة إن الـ tags **هي** الـ access control: instance اتعمله tag غلط (أو prod و lab بنفس الـ tags) هياخد deploy مش بتاعه. عشان كده patterns زي `role_app:&standalone:&env_lab`، وعرض `--list-hosts` قبل التنفيذ، و IAM condition على `ssm:resourceTag/Project`.

</details>

<details><summary>إمتى تختار Ansible على SSM Run Command للـ deploy؟</summary>

لما الـ deploy جزء من config management (ملفات، services، packages مع الـ release)، أو محتاج orchestration حقيقي (drain من الـ LB → deploy → health gate → رجوع للـ pool، serial batches)، أو عايز idempotency و dry run. SSM Run Command أنسب لأمر سريع واحد، emergency rollback، وبيئات مش عايز فيها Python/collections على الـ runner. وكتير من الفرق بتستخدم الاتنين: Ansible للـ baseline (أو Packer)، و SSM/CodeDeploy للـ release.

</details>

<details><summary>`host_key_checking = False` في `ansible.cfg` — ليه ده مقبول هنا ومش مقبول في prod؟</summary>

في الـ lab الـ instances disposable وكل واحد جديد بـ host key جديد؛ الـ strict checking هيعلّمك تكتب "yes" وخلاص. والـ default connection أصلاً SSM (مفيش SSH host keys). في prod: يا SSM، يا pin الـ host keys (من console output/SSM)، يا SSH host certificates من CA — وإلا أي MITM ياخد الـ deploy والـ secrets.

</details>

## 13) Checklist

- [ ] ضبطت `ANSIBLE_SSM_BUCKET` وفهمت ليه الـ instance مش محتاج S3 permission
- [ ] شغّلت check mode، وبعدين deploy حقيقي، وبعدين نفس الـ tag تاني → `changed=0`
- [ ] شفت الـ sessions في Session history و CloudTrail
- [ ] جرّبت bucket مش مسموح، مفيش hosts، و pattern غلط
- [ ] تقدر تشرح جدول 32 مقابل 33 وإمتى تختار كل واحد
