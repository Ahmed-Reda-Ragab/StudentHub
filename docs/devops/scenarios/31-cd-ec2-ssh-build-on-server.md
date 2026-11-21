# 31 — CD → EC2 بـ SSH + build على السيرفر (الطريقة القديمة)

> **الهدف في سطر:** تشغّل [`deploy-ec2-ssh-build.yml`](../../../.github/workflows/deploy-ec2-ssh-build.yml) (GitHub Actions → `ssh` عادي → `git checkout` → render env → build على السيرفر → Recreate) وتقيس الـ downtime، وتفهم بعمق **ليه ده anti-pattern** (secret طويل العمر، بورت 22، build على الـ production، مفيش artifact)، ولو مضطر تعمله: إزاي تعمله بأمان.
> **المستوى:** Intermediate · **الوقت:** ~2 ساعة · **التكلفة التقريبية:** نفس [20](20-ec2-compose-console.md) (`t3.small` لازم — الـ build محتاج RAM)
> **بيعتمد على:** [21](21-ec2-compose-terraform-ansible.md) (stack 20) · [22](22-recreate-and-measuring-downtime.md) · [30](30-ci-github-actions.md) · **الملفات في الـ repo:** [`.github/workflows/deploy-ec2-ssh-build.yml`](../../../.github/workflows/deploy-ec2-ssh-build.yml) · [`deploy/ec2/deploy-build-on-server.sh`](../../../deploy/ec2/deploy-build-on-server.sh) · [`deploy/ec2/render-env-from-ssm.sh`](../../../deploy/ec2/render-env-from-ssm.sh) · [`deploy/scripts/probe.sh`](../../../deploy/scripts/probe.sh) · [`infra/terraform/stacks/20-ec2-single/variables.tf`](../../../infra/terraform/stacks/20-ec2-single/variables.tf) (`ssh_cidrs`، `key_name`)

## 1) الفكرة (Concepts)

ده الـ CD اللي أغلب الشركات الصغيرة بدأت بيه: workflow بيعمل `ssh` على السيرفر ويقوله "اعمل pull واعمل build وشغّل". بيشتغل، وسهل، و**كل نقطة فيه مشكلة**. إحنا بنعمله عن قصد كـ **baseline** نقارن بيه [32](32-cd-ec2-ecr-ssm.md) (ECR + SSM) و [33](33-cd-ec2-ansible.md) (Ansible).

| المشكلة | التفاصيل | الحل الصح (فين) |
|---|---|---|
| **بورت 22 مفتوح** | GitHub-hosted runners IPs آلاف ranges وبتتغيّر → عملياً `0.0.0.0/0` | SSM: مفيش inbound ([32](32-cd-ec2-ecr-ssm.md)) |
| **Secret طويل العمر** | private key في GitHub secrets؛ اتسرّب مرة = shell على الـ prod لحد ما تعمله rotate (ومحدش بيعمل) | OIDC + IAM مؤقت |
| **Build على الـ prod** | composer/npm/Docker layers بياكلوا CPU/RAM جنب الـ traffic الحقيقي؛ `t3.micro` بيعمل OOM | build في CI ([30](30-ci-github-actions.md)) |
| **مفيش artifact** | كل سيرفر بيبني image مختلفة شوية (dependencies اتغيّرت)، ومحدش عمل لها scan | image واحدة بـ digest في ECR |
| **السيرفر محتاج access للـ repo** | repo private = deploy key/PAT **على السيرفر** كمان | السيرفر بيعمل pull لـ image بس |
| **Recreate** | ثواني downtime مع كل deploy | blue/green ([23](23-bluegreen-single-host.md)) |
| **Rollback = rebuild** | الـ commit القديم بيتبني تاني → مش نفس الـ bytes | redeploy لـ digest قديم |
| **TOFU** | من غير known_hosts متثبت، أول اتصال بيثق في أي host key → MITM ياخد الـ deploy | pin الـ host key |

| المصطلح | المعنى |
|---|---|
| Push-based CD | الـ CI بيوصل للسيرفر ويأمره (عكس pull-based: السيرفر/agent بيسحب) |
| `known_hosts` | قايمة الـ host keys اللي الـ client بيثق فيها؛ `StrictHostKeyChecking=yes` = ارفض أي key مش فيها |
| TOFU | Trust On First Use — `ssh-keyscan` من غير تحقق |
| `BatchMode=yes` | مفيش prompts (password/passphrase) — لو محتاج input يفشل بدل ما يعلّق |
| Heredoc `<<'REMOTE'` | السكريبت بيتبعت لـ `bash -s` على السيرفر؛ الـ quotes بتمنع الـ runner إنه يفك المتغيرات |

## 2) المعمارية (Architecture)

```text
 GitHub Actions runner (ubuntu-latest, IP عشوائي من Azure)
   workflow_dispatch(ref) · environment: lab · concurrency: deploy-lab-ec2-single
   1. checkout (persist-credentials: false)
   2. validate EC2_HOST + ref regex
   3. ~/.ssh/deploy_key ◄── secrets.EC2_SSH_PRIVATE_KEY
      ~/.ssh/known_hosts ◄── vars.EC2_SSH_KNOWN_HOSTS  (أو ssh-keyscan = TOFU + warning)
   4. probe.sh $APP_URL/ready كل 0.2s (background)
   5. ssh -i deploy_key -o BatchMode=yes -o StrictHostKeyChecking=yes ec2-user@EC2_HOST bash -s -- REF REPO_URL
        │  TCP 22 (SG: ssh_cidrs — غالباً 0.0.0.0/0 للـ GitHub runners)
        ▼
 EC2 (stack 20, key_name = student-app-lab)
   /opt/student-app/src  ◄── git clone (أول مرة) / git fetch + checkout REF  ◄── github.com (public repo)
   render-env-from-ssm.sh  → /opt/student-app/app.env, mysql.env   (instance role → SSM)
   deploy-build-on-server.sh REF:
       docker compose build app  (CPU 100% على السيرفر اللي بيخدم المستخدمين)
       up -d --wait mysql → run --rm migrate → up -d --no-deps --wait app  ← downtime هنا
       CURRENT_RELEASE=student-app:<sha> → PREVIOUS_RELEASE
   6. stop probe → 7. smoke /ready → 8. job summary (downtime) → 9. rm deploy_key
```

## 3) المتطلبات (Prerequisites)

- [ ] stack 20 ([21](21-ec2-compose-terraform-ansible.md)) بـ `instance_type = "t3.small"`، والـ SSM params موجودة.
- [ ] الـ repo **public** (السيرفر بيعمل `git clone` بـ HTTPS من غير credentials). لو private: هتحتاج deploy key **على السيرفر** — secret تاني (وده سبب إضافي إن الطريقة دي سيئة).
- [ ] الـ workflow موجود على الـ **default branch** (`master`) — GitHub مبيعرضش/مبيشغّلش `workflow_dispatch` لـ workflow مش موجود على الـ default branch. بعد كده تقدر تختار `--ref devops-lab`.
- [ ] environment `lab` موجود ([02 §5.8](02-aws-account-setup.md)).
- الأدوات: `gh`، `aws`، `ssh-keygen`.

## 4) الطريقة الأولى: AWS Console + GitHub UI (يدوي)

### 4.1 Key pair

**EC2 → Network & Security → Key pairs → Create key pair** → Name `student-app-lab` · Type **ED25519** · Format **.pem** → Create → الملف بيتنزل مرة واحدة بس.

```bash
mv ~/Downloads/student-app-lab.pem ~/.ssh/ && chmod 600 ~/.ssh/student-app-lab.pem   # من WSL: انقله من /mnt/c/Users/<you>/Downloads
```

### 4.2 فتح بورت 22 (اللي هو أصل المشكلة)

**EC2 → Security groups → `student-app-lab-app-host` → Edit inbound rules → Add rule** → SSH · 22 · Source:

- **My IP** — لو هتعمل ssh من جهازك بس (اختبار).
- للـ GitHub-hosted runners: مفيش IP ثابت. `curl -s https://api.github.com/meta | jq '.actions | length'` → آلاف الـ CIDRs (ومينفعش تحطهم في SG: الحد الافتراضي 60 rule). فعملياً **`0.0.0.0/0`** — وده بالظبط ليه الطريقة دي سيئة.

> ⚠️ لو عملت الـ instance من Terraform (stack 20)، الأحسن تعمل ده بـ `ssh_cidrs` (§5) — الـ rule اليدوي = drift، و `terraform apply` الجاي هيشيله.

### 4.3 الـ host key (pin بدل TOFU)

اجيب الـ host key من **قناة موثوقة** (Session Manager — مش ssh-keyscan على الشبكة):

```bash
aws ssm start-session --target <INSTANCE_ID>
# جوه الـ session:
sudo cat /etc/ssh/ssh_host_ed25519_key.pub          # ssh-ed25519 AAAAC3Nza... root@ip-10-20-...
exit
# على جهازك: سطر known_hosts = "<EIP> <type> <key>"
echo "<ELASTIC_IP> ssh-ed25519 AAAAC3Nza..." > /tmp/known_hosts_line
```

(بديل: **EC2 → Instance → Actions → Monitor and troubleshoot → Get system log** → cloud-init بيطبع `BEGIN SSH HOST KEY FINGERPRINTS` تقارن بيها.)

### 4.4 GitHub secrets و variables

**Settings → Secrets and variables → Actions**:

- **Secrets → New repository secret:** `EC2_SSH_PRIVATE_KEY` = محتوى `student-app-lab.pem` كامل (من `-----BEGIN` لـ `-----END`).
- **Variables:** `EC2_HOST` = الـ EIP، `EC2_SSH_USER` = `ec2-user` (اختياري، ده الافتراضي)، `EC2_SSH_KNOWN_HOSTS` = السطر من §4.3.
- **Environments → lab → Environment variables:** `APP_URL` = `http://<EIP>`.

## 5) الطريقة التانية: Infrastructure as Code (Terraform + gh)

```bash
aws ec2 create-key-pair --key-name student-app-lab --key-type ed25519 \
  --query KeyMaterial --output text > ~/.ssh/student-app-lab.pem && chmod 600 ~/.ssh/student-app-lab.pem

cd infra/terraform/stacks/20-ec2-single
cat >> terraform.tfvars <<'EOF'
scenario  = "31"
ssh_cidrs = ["0.0.0.0/0"]     # GitHub-hosted runners: مفيش IP ثابت (ده الـ anti-pattern نفسه)
key_name  = "student-app-lab"
EOF
terraform plan -out=tfplan     # ⚠️ لو الـ instance موجود من غير key_name: "must be replaced" (الـ key بيتحط وقت الـ launch بس)
terraform apply tfplan
```

> ⚠️ **`key_name` = replacement:** على instance شغال، إضافة/تغيير `key_name` بيعمل instance جديد (والـ MySQL volume بيروح معاه — اعمل [27](27-mysql-backup-restore.md) الأول). قرّر قبل أول apply. (`ignore_changes` في الـ module على `ami` و `user_data` بس.)

```bash
HOST=$(terraform output -raw public_ip)
IID=$(terraform output -raw instance_id)
CID=$(aws ssm send-command --instance-ids "$IID" --document-name AWS-RunShellScript \
      --parameters 'commands=["cat /etc/ssh/ssh_host_ed25519_key.pub"]' --query Command.CommandId --output text)
aws ssm wait command-executed --command-id "$CID" --instance-id "$IID"
KH="$HOST $(aws ssm get-command-invocation --command-id "$CID" --instance-id "$IID" \
      --query StandardOutputContent --output text | awk '{print $1" "$2}')"
echo "$KH"                                             # <EIP> ssh-ed25519 AAAAC3Nza...

gh secret set EC2_SSH_PRIVATE_KEY < ~/.ssh/student-app-lab.pem
gh variable set EC2_HOST --body "$HOST"
gh variable set EC2_SSH_USER --body ec2-user
gh variable set EC2_SSH_KNOWN_HOSTS --body "$KH"
gh variable set APP_URL --env lab --body "http://$HOST"
gh secret set SRE_LAB_TOKEN --body "$(terraform output -raw sre_lab_token)"
```

> 💡 الـ host key جه عن طريق **SSM** (IAM-authenticated)، مش `ssh-keyscan` على الشبكة → مفيش TOFU.

## 6) الـ Deploy

### 6.1 تشغيل الـ workflow

```bash
gh workflow run deploy-ec2-ssh-build.yml --ref devops-lab -f ref=devops-lab
gh run watch "$(gh run list --workflow=deploy-ec2-ssh-build.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
gh run view --log | grep -E "building|migrations|recreate|live:|deployed"
```

`ref` فاضي = الـ commit بتاع الـ run (`github.sha`)؛ ممكن branch أو SHA.

### 6.2 الـ workflow خطوة بخطوة

| Step | بيعمل إيه | ليه / الـ gotcha |
|---|---|---|
| `on: workflow_dispatch` (input `ref`) | يدوي بس | مفيش auto-deploy للطريقة دي عن قصد |
| `permissions: contents: read` | least privilege | مفيش `id-token` — مفيش AWS خالص من الـ runner |
| `environment: lab` + `url: vars.APP_URL` | الـ run بيظهر في Deployments، ولو `lab` عليه reviewer الـ job بيستنى | |
| `concurrency: deploy-lab-ec2-single`، `cancel-in-progress: false` | نفس الـ group بتاع SSM/Ansible/blue-green workflows | deploy واحد على الـ host في نفس الوقت، ومحدش يقطع deploy شغال (migration نصها اتعمل) |
| `timeout-minutes: 45` | | الـ build على السيرفر بطيء |
| `actions/checkout` بـ `persist-credentials: false` | محتاجين `deploy/scripts/probe.sh` بس | الـ `GITHUB_TOKEN` مبيتسابش في `.git/config` |
| Validate | `EC2_HOST` موجود، و `REF` يطابق `^[A-Za-z0-9._/-]{1,100}$` | الـ ref بيتبعت لـ shell على السيرفر → whitelist ضد الـ injection |
| Install the SSH key | `printf '%s\n' "$SSH_KEY" > ~/.ssh/deploy_key` + `chmod 600`؛ `known_hosts` من الـ variable، أو `ssh-keyscan -t ed25519,ecdsa` + `::warning::` | الـ secret في `env:` مش في الـ `run:` مباشرة (مبيتكتبش في السكريبت)؛ الـ `\n` في الآخر مهم (OpenSSH بيرفض key من غير newline) |
| Start the downtime probe | `probe.sh "$APP_URL/ready" 0 0.2` في الخلفية (`STOP_FILE`/`OUT`) | قياس Recreate ([22](22-recreate-and-measuring-downtime.md)) |
| Build and deploy on the server | `ssh -i ... -o BatchMode=yes -o StrictHostKeyChecking=yes -o ServerAliveInterval=30 -o ConnectTimeout=15 user@host bash -s -- "$REF" "$REPO_URL" <<'REMOTE'` | **plain `ssh`** بدل marketplace action: مفيش third-party code بيشوف الـ private key |
| (جوه REMOTE) | `git clone` لو مفيش `src/.git` → `fetch --prune` → `checkout $ref` → `render-env-from-ssm.sh` → `deploy-build-on-server.sh $ref` | بيشغّل سكريبتات **الـ commit اللي بيتعمله deploy** (بعد الـ checkout)، مش القديمة |
| Stop probe + Smoke | `curl --retry 12 --retry-all-errors $APP_URL/ready` → `status == ready` → `version` | |
| Job summary | جدول Host/Ref/Smoke/Version + نتيجة الـ probe | |
| Remove the key | `rm -f ~/.ssh/deploy_key` (`if: always()`) | الـ runner ephemeral أصلاً، بس defense in depth (مهم لو self-hosted) |

### 6.3 لو مضطر تعمل SSH deploy — إزاي تعمله بأمان

أحياناً مفيش اختيار (vendor box، on-prem، legacy). الترتيب من الأحسن:

1. **متفتحش 22 للعالم:** self-hosted runner بـ IP ثابت جوه الـ VPC أو VPN، أو **EC2 Instance Connect Endpoint** (SSH لـ instance في private subnet من غير public IP)، أو bastion بـ allowlist.
2. **متخزّنش key طويل العمر:** **EC2 Instance Connect** — الـ workflow ياخد OIDC role فيه `ec2-instance-connect:SendSSHPublicKey`، يولّد key مؤقت، ويبعته (صالح **60 ثانية**):

```bash
ssh-keygen -t ed25519 -N '' -f /tmp/ek -q
aws ec2-instance-connect send-ssh-public-key --instance-id <INSTANCE_ID> \
  --instance-os-user ec2-user --ssh-public-key file:///tmp/ek.pub
ssh -i /tmp/ek -o StrictHostKeyChecking=yes ec2-user@<HOST> 'true'    # خلال 60 ثانية
```

   (AL2023 فيه الـ EC2 Instance Connect agent جاهز.) البديل الـ enterprise: **SSH certificates** قصيرة العمر (Vault/step-ca).
3. **Pin الـ host key** (`EC2_SSH_KNOWN_HOSTS`) — دايماً.
4. **Deploy user مقيّد:** مش `ec2-user` اللي في group docker (= root)؛ user مخصوص و `authorized_keys` بـ `command="/opt/student-app/deploy.sh",no-pty,no-port-forwarding` → الـ key ميقدرش يعمل غير الـ deploy.
5. **متبنيش على السيرفر:** حتى لو الـ transport SSH، ابعت **image digest** واعمل pull (زي `deploy-pull-image.sh`) — ده بيحل نص المشاكل في الجدول فوق.
6. Rotation دوري للـ key، و GitHub **environment secret** (مش repo secret) مع required reviewers.

## 7) التحقق (Verify)

```bash
gh run view <RUN_ID>                                   # Summary: Host · Ref · Smoke · Live version + Downtime
curl -s http://$HOST/ready | jq '{status, version}'    # version = أول 7 حروف من الـ commit
ssh -i ~/.ssh/student-app-lab.pem ec2-user@$HOST 'cat /opt/student-app/CURRENT_RELEASE /opt/student-app/PREVIOUS_RELEASE; docker images student-app'
```

المفروض: الـ job أخضر، الـ summary فيه **downtime** (ثواني — قارنه بـ 0 في [23](23-bluegreen-single-host.md))، و `CURRENT_RELEASE` = `student-app:<sha>` (image **local** — مش موجودة في أي registry).

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر | المتوقع |
|---|---|---|
| host key غلط | `gh variable set EC2_SSH_KNOWN_HOSTS --body "$HOST ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBadKeyBadKeyBadKeyBadKeyBadKeyBadKeyBad"` | `Host key verification failed` — ده `StrictHostKeyChecking=yes` بيحميك من MITM |
| من غير known_hosts | `gh variable delete EC2_SSH_KNOWN_HOSTS` | بيعدّي بـ `::warning::... trusting the host key on first use` (اقرا الـ warning ده كـ red flag) |
| الـ secret مش موجود | `gh secret delete EC2_SSH_PRIVATE_KEY` | `::error::secret EC2_SSH_PRIVATE_KEY is not set` |
| SG مقفول | `ssh_cidrs = []` + apply | `ssh: connect to host ... port 22: Connection timed out` (timeout مش refused = SG/NACL) |
| ref فيه injection | `-f ref='master;id'` | `::error::invalid ref` — الـ regex |
| OOM | `instance_type = "t3.micro"` (⚠️ replacement) وشيل الـ swap | الـ build يموت (`exit code 137` / `Killed`) والـ app ممكن يتأثر — build على الـ prod |
| الـ key اتسرّب | تخيّل إن `EC2_SSH_PRIVATE_KEY` اتسرّب | لازم: تشيل الـ public key من `~ec2-user/.ssh/authorized_keys` على كل سيرفر + key جديد + تحقيق في `/var/log/secure` — قارن بـ OIDC: "شيل الـ trust" وخلاص |

## 9) الرجوع (Rollback)

```bash
# "rollback" هنا = rebuild لـ commit قديم (مش نفس الـ bytes!)
gh workflow run deploy-ec2-ssh-build.yml --ref devops-lab -f ref=<OLD_SHA>

# أسرع: الـ image القديمة لسه local على السيرفر (لو الـ prune مامسحهاش — 168h)
ssh -i ~/.ssh/student-app-lab.pem ec2-user@$HOST '
  cd /opt/student-app/src && export APP_IMAGE=$(cat /opt/student-app/PREVIOUS_RELEASE) \
    APP_ENV_FILE=/opt/student-app/app.env MYSQL_ENV_FILE=/opt/student-app/mysql.env &&
  docker compose -f docker-compose.prod.yml up -d --no-deps --wait app && curl -fsS http://127.0.0.1/ready'
```

> ⚠️ الـ rebuild ممكن يطلّع image مختلفة عن اللي كانت شغالة (base image اتحدّثت، package اتغيّر) — ده بالظبط معنى "no artifact".

## 10) المسح (Teardown) ⚠️

```bash
# 1) اقفل بورت 22 (من غير ما تستبدل السيرفر: سيب key_name، شيل ssh_cidrs بس)
#    terraform.tfvars:  ssh_cidrs = []
terraform -chdir=infra/terraform/stacks/20-ec2-single apply
# 2) امسح الأسرار
gh secret delete EC2_SSH_PRIVATE_KEY
gh variable delete EC2_SSH_KNOWN_HOSTS; gh variable delete EC2_HOST; gh variable delete EC2_SSH_USER
aws ec2 delete-key-pair --key-name student-app-lab && rm -f ~/.ssh/student-app-lab.pem
# 3) السيرفر نفسه: terraform destroy (21 §10)
```

- [ ] مفيش SG rule على 22 · [ ] الـ secret والـ key pair ممسوحين · [ ] (لو هتكمّل) السيرفر لسه شغال بـ SSM

## 11) التكلفة (Cost)

| Resource | السعر التقريبي (تقريبي — راجع صفحة الأسعار) |
|---|---|
| EC2 `t3.small` + EBS + EIP | نفس [20](20-ec2-compose-console.md) (~$0.65/يوم) |
| GitHub Actions | مجاني للـ public repo؛ الـ private من الدقائق الشهرية |
| **التكلفة المخفية** | `t3.small` بدل `t3.micro` عشان الـ build بس (~2×)، و CPU credits بتتصرف على build مش على مستخدمين |

## 12) أسئلة Interview

<details><summary>اشرح ليه SSH + build على السيرفر anti-pattern (في دقيقة).</summary>

أمنياً: بورت 22 مفتوح لـ IP ranges ضخمة، وprivate key طويل العمر في الـ CI = shell دائم على الـ prod لو اتسرّب، وTOFU بيفتح MITM. هندسياً: مفيش artifact immutable — كل سيرفر بيبني نسخته، محدش عمل لها test/scan، والـ rollback rebuild مش redeploy. تشغيلياً: الـ build بياكل موارد السيرفر اللي بيخدم، ومحتاج access للـ repo وbuild tools على الـ prod، والـ Recreate بيعمل downtime. الحل: build once في CI → ECR → deploy بالـ digest عن طريق SSM/agent.

</details>

<details><summary>ليه الـ workflow بيستخدم `ssh` عادي مش action زي appleboy/ssh-action؟</summary>

أي action بتاخد الـ private key كـ input = third-party code بيشوف الـ secret، ولو الـ action اتخترقت (tag اتنقل لـ commit خبيث — حصل فعلاً مع actions مشهورة) الـ key راح. `ssh` موجود على الـ runner، فمفيش dependency. ولو لازم action: pin بالـ commit SHA مش tag.

</details>

<details><summary>إيه فايدة `StrictHostKeyChecking=yes` لو انت أصلاً عامل `ssh-keyscan`؟</summary>

ولا حاجة تقريباً — `ssh-keyscan` في نفس الـ run بيثق في أي key بيرد (TOFU)؛ اللي بيعمل MITM هيرد بالـ key بتاعه. الحماية الحقيقية لما الـ `known_hosts` يتجاب من قناة موثوقة (SSM، console output، أو SSH CA) ويتثبّت في variable. عشان كده الـ workflow بيطلّع warning لما `EC2_SSH_KNOWN_HOSTS` مش موجود.

</details>

<details><summary>الـ deploy key اتسرّب من GitHub — خطوات الـ incident؟</summary>

احتواء: شيل الـ public key من `authorized_keys` على كل السيرفرات (أو اقفل 22 في الـ SG فوراً)، وامسح الـ secret. تحقيق: `/var/log/secure` و CloudTrail (هل حد عمل حاجة بالـ instance role من السيرفر؟)، وافترض إن الـ `app.env` (secrets) اتقرى → rotate DB password و `APP_KEY` حسب الحاجة. منع: انتقل لـ SSM/OIDC أو Instance Connect بـ keys مؤقتة، و environment secrets بـ reviewers.

</details>

<details><summary>لو مضطر SSH، إزاي تصمّمه صح؟</summary>

شبكة: self-hosted runner/VPN/Instance Connect Endpoint بدل 22 مفتوح. هوية: keys مؤقتة (EC2 Instance Connect بـ OIDC، أو SSH certificates بـ TTL دقايق) بدل key دائم. تحقق: known_hosts متثبّت أو host certificates. صلاحيات: deploy user بـ forced command، مش في group docker/sudo. محتوى: ابعت digest واعمل pull — متبنيش. وكل ده ورا environment بـ required reviewers.

</details>

<details><summary>ليه `concurrency` من غير `cancel-in-progress`؟</summary>

deploy اتقطع في النص ممكن يسيب migration نصها متعمل أو containers في حالة غريبة. فالـ group بيضمن deploy واحد على الـ host (مشترك مع كل الـ EC2 workflows)، والـ run الجديد بيستنى؛ ولو فيه أكتر من واحد مستني، GitHub بيسيب الأحدث بس (الأقدم المستني بيتلغي) — وده منطقي: مفيش داعي تعمل deploy لـ commit اتعدّى.

</details>

## 13) Checklist

- [ ] عملت key pair وفتحت 22 (وفهمت ليه `0.0.0.0/0` هو الواقع مع GitHub-hosted runners)
- [ ] جبت الـ host key من SSM وحطيته في `EC2_SSH_KNOWN_HOSTS`
- [ ] شغّلت الـ workflow وشفت الـ downtime في الـ summary
- [ ] جرّبت host key غلط و ref injection و SG مقفول
- [ ] عارف تشرح 6 أسباب إنه anti-pattern، و6 خطوات لو مضطر تعمله
- [ ] قفلت 22 ومسحت الـ key والـ secret
