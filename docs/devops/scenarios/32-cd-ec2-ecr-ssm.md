# 32 — CD → EC2 بـ ECR + SSM Run Command

> **الهدف في سطر:** تشغّل [`deploy-ec2-ssm.yml`](../../../.github/workflows/deploy-ec2-ssm.yml): **build once / deploy many** — الـ tag بيتحوّل لـ **digest** في ECR، سكريبتات الـ deploy بتاعة نفس الـ commit بتتشحن جوه الأمر (`git archive`)، و **SSM Run Command** بيشغّلها على السيرفر من غير بورت 22 ولا keys، مع polling و timeouts و cancel، و continuous deploy اختياري بعد نجاح الـ CI (`workflow_run` + `EC2_CONTINUOUS_DEPLOY`).
> **المستوى:** Intermediate → Advanced · **الوقت:** ~3 ساعات · **التكلفة التقريبية:** نفس [20](20-ec2-compose-console.md) (`t3.micro` يكفي — مفيش build على السيرفر) + سنتات CloudWatch Logs
> **بيعتمد على:** [02](02-aws-account-setup.md) · [21](21-ec2-compose-terraform-ansible.md) · [30](30-ci-github-actions.md) · [31](31-cd-ec2-ssh-build-on-server.md) (للمقارنة) · **الملفات في الـ repo:** [`.github/workflows/deploy-ec2-ssm.yml`](../../../.github/workflows/deploy-ec2-ssm.yml) · [`deploy/ec2/deploy-pull-image.sh`](../../../deploy/ec2/deploy-pull-image.sh) · [`deploy/ec2/render-env-from-ssm.sh`](../../../deploy/ec2/render-env-from-ssm.sh) · [`docker-compose.prod.yml`](../../../docker-compose.prod.yml) · [`infra/terraform/bootstrap/github-oidc.tf`](../../../infra/terraform/bootstrap/github-oidc.tf) (deploy role) · [`infra/terraform/stacks/20-ec2-single/iam.tf`](../../../infra/terraform/stacks/20-ec2-single/iam.tf)

## 1) الفكرة (Concepts)

الفرق الجوهري عن [31](31-cd-ec2-ssh-build-on-server.md): **الـ CI بيبني artifact واحد** (image بـ tag = short SHA، اتعمله test وscan — [30](30-ci-github-actions.md))، والـ CD **مبيبنيش حاجة**: بيقول للسيرفر "اسحب الـ digest ده وشغّله". والقناة مش SSH: الـ SSM agent على السيرفر عامل outbound 443 لـ Systems Manager، والـ workflow بياخد credentials مؤقتة بـ OIDC وبيعمل `ssm:SendCommand` — مسموح بس على instances عليها `Project=student-app`.

| | 31 (SSH build) | **32 (ECR + SSM)** |
|---|---|---|
| Inbound | 22 مفتوح | **مفيش** |
| Secret في GitHub | private key دائم | **مفيش** (OIDC → STS، ساعة) |
| Artifact | image local مختلفة لكل سيرفر | **digest واحد** اتعمله scan |
| Build على السيرفر | أيوه | **لأ** (`t3.micro` يكفي) |
| Audit | sshd logs | CloudTrail + Command history + CloudWatch Logs |
| Rollback | rebuild | redeploy لـ digest قديم (نفس الـ bytes) |
| Multi-host | loop بإيدك | `Targets` بالـ tags + `MaxConcurrency`/`MaxErrors` |

| المصطلح | المعنى |
|---|---|
| Digest | `sha256:...` = hash محتوى الـ image manifest. الـ tag ممكن يتنقل (لو mutable)، الـ digest لأ |
| `repo:tag@digest` | Docker بيتجاهل الـ tag لما يلاقي digest؛ الـ tag موجود للبني آدمين |
| `AWS-RunShellScript` | SSM document بيشغّل shell commands كـ **root** |
| `TimeoutSeconds` | delivery timeout: لو الأمر مبدأش على الـ instance خلال المدة دي (الـ agent offline) → يفشل |
| `executionTimeout` | أقصى مدة لتنفيذ السكريبت نفسه على الـ instance |
| `MaxConcurrency` / `MaxErrors` | كام instance في نفس الوقت / كام فشل مسموح قبل ما يوقف الباقي |
| `workflow_run` | workflow بيتشغّل لما workflow تاني يخلص (هنا: بعد `CI`) |
| Reusable workflow (`workflow_call`) | نفس الـ workflow بيتنده من workflows تانية (blue/green، canary، promote) |

## 2) المعمارية (Architecture)

```text
 trigger: workflow_dispatch (image_tag, use_local_mysql)
        | workflow_run: CI completed على main/master  (opt-in: vars.EC2_CONTINUOUS_DEPLOY == 'true')
        | workflow_call (deploy-ec2-bluegreen / -canary / release-promote: environment, strategy, expected_digest...)
 job deploy · environment: <lab|production> · concurrency deploy-<env>-ec2-single (no cancel) · timeout 90m
 ┌──────────────────────────────────────────────────────────────────────────────────────────┐
 │ 1 checkout SOURCE_SHA (workflow_run.head_sha || github.sha)                              │
 │ 2 validate: strategy, canary_steps, numbers, slot_env, tag regex, tag != latest          │
 │ 3 OIDC → student-app-gha-deploy (sub = repo:...:environment:lab)                         │
 │   guard: non-lab env ⇒ own ENV_NAME == env name ; instance tag Env == ENV_NAME           │
 │ 4 ecr describe-images tag → digest ; [expected_digest ≠ → fail] ; uri = repo:tag@digest  │
 │ 5 targets: EC2_INSTANCE_ID → InstanceIds | else tags Project/Env/Role=app/Scenario       │
 │ 6 remote.sh = vars (printf %q) + PAYLOAD=base64(git archive HEAD compose + deploy/ec2 …) │
 │ 7 probe APP_URL/ready (أو /login مع generate_traffic)                                     │
 │ 8 ssm send-command AWS-RunShellScript (MaxConcurrency 1, MaxErrors 0, CW Logs)          │
 │   poll list-commands كل 10s → Success|Failed|TimedOut|Cancelled ; deadline → cancel     │
 │   get-command-invocation لكل instance → stdout/stderr ; outcome deployed|aborted|failed  │
 │ 9 smoke APP_URL/ready: status ready && version == tag ; 10 summary ; 11 verdict          │
 └───────────────┬──────────────────────────────────────────────────────────────────────────┘
                 │ HTTPS (SSM API)                    ▲ agent outbound 443 (مفيش inbound)
                 ▼                                    │
 Systems Manager ──────────────────────────────► EC2 (stack 20) — root:
                                                  tar -xz payload → /opt/student-app/{compose, *.sh}
                                                  recreate: deploy-pull-image.sh repo:tag@digest
                                                    ECR login (instance role) → render-env-from-ssm.sh
                                                    → compose pull → migrate --force → up -d --wait app
                                                    → CURRENT_RELEASE / PREVIOUS_RELEASE
                                                  bluegreen|canary: lb/bin/init.sh | bluegreen.sh | canary.sh
                 stdout/stderr ──► CloudWatch Logs /student-app/<env>/ssm-deploy
```

## 3) المتطلبات (Prerequisites)

- [ ] stack 20 شغال ([21](21-ec2-compose-terraform-ansible.md))، والـ instance **Online** في Fleet Manager.
- [ ] الـ CI عمل push لـ tag في ECR (`aws ecr describe-images --repository-name student-app --query 'imageDetails[].imageTags[]'`).
- [ ] Repository variables من [02 §5.8](02-aws-account-setup.md): `AWS_DEPLOY_ROLE_ARN`، `AWS_REGION`، `ECR_REPOSITORY`.
- [ ] `EC2_INSTANCE_ID` (repo variable أو environment variable على `lab`) و `APP_URL` على environment `lab`. والـ instance عليه tag `Env` = `ENV_NAME` (`lab`) — stack 20 بيحطه لوحده؛ الـ guard (§6.2) بيرفض غير كده.
- [ ] **الـ deploy files committed**: الـ payload بيتعمل بـ `git archive HEAD` — ملف مش committed مش هيتشحن. والـ workflow موجود على `master` (شرط `workflow_dispatch` و `workflow_run`).

## 4) الطريقة الأولى: AWS Console (يدوي)

### 4.1 Run Command بإيدك (نفس اللي الـ workflow بيعمله)

1. **ECR → student-app → اختار الـ tag** → خد الـ **Image URI** والـ **Digest**.
2. **Systems Manager → Run Command** (تحت Node Tools) **→ Run command**.
3. **Command document:** `AWS-RunShellScript`.
4. **Commands:**

```bash
set -euo pipefail
cd /opt/student-app
IMAGE=<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/student-app:<TAG>@sha256:<DIGEST>
./deploy-pull-image.sh "$IMAGE"
```

   (الأمر ده بيفترض إن السكريبتات موجودة على السيرفر من [21](21-ec2-compose-terraform-ansible.md)/Ansible. الـ workflow بيشحنها بنفسه.)

5. **Targets:** **Choose instances manually** → اختار الـ instance — أو **Specify instance tags** → `Project=student-app`، `Role=app`.
6. **Other parameters → Timeout (seconds):** `1200` (ده الـ `executionTimeout`).
7. **Rate control:** Concurrency **1 target** · Error threshold **0 errors**.
8. **Output options:** ✅ **Enable CloudWatch logs** → Log group `/student-app/lab/ssm-deploy`.
9. **Run** → صفحة الـ command: Status لكل instance → **Output** (أول 24,000 حرف) أو الـ CloudWatch link (كامل).

### 4.2 الـ history والـ audit

- **Systems Manager → Run Command → Command history** → كل deploy بالـ Comment بتاعه (`recreate 3f2c1ab by <actor> run <id>`) والـ status.
- **CloudWatch → Log groups → `/student-app/lab/ssm-deploy`** → stream لكل command/instance.
- **CloudTrail → Event history** → Event name `SendCommand` → User name = `deploy-ec2-<run_id>-<attempt>` (الـ `role-session-name`) → تعرف أنهي GitHub run عمل أنهي deploy.

### 4.3 الـ IAM

- **IAM → Roles → `student-app-gha-deploy` → Trust relationships**: الـ `sub` فيه `environment:lab` و `environment:production`.
- **Permissions → inline `deploy`**: دوّر على `SsmSendCommandProjectInstances` (condition `ssm:resourceTag/Project = student-app`)، `SsmSendCommandShellDocument`، `SsmCommandResults`، `SsmCancelTimedOutCommands`، `EcrPull`.

## 5) الطريقة التانية: Infrastructure as Code

كل حاجة موجودة already:

**الـ deploy role** ([`github-oidc.tf`](../../../infra/terraform/bootstrap/github-oidc.tf)):

| Statement | Actions | Resource / Condition | ليه |
|---|---|---|---|
| `EcrLogin` + `EcrPull` | `GetAuthorizationToken`، `DescribeImages`، ... | repo `student-app` | tag → digest |
| `SsmSendCommandProjectInstances` | `ssm:SendCommand` | `instance/*` + `ssm:resourceTag/Project = student-app` | مايقدرش يشغّل أوامر على أي instance تاني في الحساب |
| `SsmSendCommandShellDocument` | `ssm:SendCommand` | `document/AWS-RunShellScript` | document واحد بس |
| `SsmCommandResults` | `DescribeInstanceInformation`، `GetCommandInvocation`، `ListCommandInvocations`، `ListCommands`، `ec2:DescribeInstances` | `*` (مش resource-scopable) | الـ polling |
| `SsmCancelTimedOutCommands` | `ssm:CancelCommand` | `*` | cleanup لما الـ deadline يعدّي |

**الـ instance role** ([`iam.tf`](../../../infra/terraform/stacks/20-ec2-single/iam.tf)): `AmazonSSMManagedInstanceCore` (الـ agent)، ECR pull على `student-app`، قراءة `/student-app/lab/*` + decrypt، و `CloudWatchAgentServerPolicy` (فيها `logs:CreateLogGroup`/`CreateLogStream`/`PutLogEvents` — اللي الـ agent محتاجها عشان يكتب output الأمر في CloudWatch).

**الـ GitHub wiring:**

```bash
cd infra/terraform/stacks/20-ec2-single
gh variable set EC2_INSTANCE_ID --body "$(terraform output -raw instance_id)"
gh variable set APP_URL --env lab --body "$(terraform output -raw app_url)"
gh secret set SRE_LAB_TOKEN --body "$(terraform output -raw sre_lab_token)"
gh variable list
```

> 💡 لو `EC2_INSTANCE_ID` فاضي، الـ workflow بيستهدف بالـ tags: `Project=student-app`، `Env=<ENV_NAME>`، `Role=app`، `Scenario=<EC2_TARGET_SCENARIO أو 20>`. لو غيّرت `scenario` في tfvars الـ stack لازم تغيّر `EC2_TARGET_SCENARIO`. الـ instance ID أوضح؛ الـ tags أنسب لـ fleet بيتغيّر.

## 6) الـ Deploy

### 6.1 تشغيل يدوي

```bash
TAG=$(aws ecr describe-images --repository-name student-app \
      --query 'sort_by(imageDetails,&imagePushedAt)[-1].imageTags[0]' --output text)
gh workflow run deploy-ec2-ssm.yml --ref devops-lab -f image_tag=$TAG
gh run watch "$(gh run list --workflow=deploy-ec2-ssm.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
```

`image_tag` فاضي = أول 7 حروف من الـ commit بتاع الـ run (لازم الـ CI يكون عمل push للـ tag ده). `use_local_mysql` (افتراضي ✅) — شيله لو `DB_HOST` = RDS ([41](41-rds-mysql.md)).

### 6.2 الـ workflow خطوة بخطوة

| # | Step | التفاصيل | نقطة senior |
|---|---|---|---|
| — | `if:` على الـ job | لو `workflow_run`: لازم `EC2_CONTINUOUS_DEPLOY == 'true'` و الـ CI `success` و الحدث الأصلي `push` و `head_repository == github.repository` | fork PR من branch اسمه `main` عمره ما يعمل deploy |
| — | `environment` / `concurrency` / `permissions` | `inputs.environment \|\| 'lab'`؛ group `deploy-<env>-ec2-single` بـ `cancel-in-progress: false`؛ `id-token: write` على الـ job بس | lock مشترك مع 31/33/blue-green/canary — deploy واحد على الـ host |
| — | `env:` | `SOURCE_SHA = workflow_run.head_sha \|\| github.sha`؛ الـ booleans بـ `inputs.x == false && 'false' \|\| 'true'` | في `workflow_run` مفيش inputs (null) → الـ defaults |
| 1 | checkout `SOURCE_SHA` | `persist-credentials: false` | السكريبتات من نفس الـ commit اللي عمل الـ image (في CD)، أو من الـ ref اللي اخترته (dispatch) |
| 2 | Validate inputs | `strategy ∈ recreate\|bluegreen\|canary`، أرقام بـ regex، `slot_env` = `KEY=value` pairs، tag `^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$` و **≠ `latest`** | الـ inputs بتنتهي في shell على السيرفر كـ root → whitelist |
| 3 | `configure-aws-credentials@v6` | `role-session-name: deploy-ec2-<run_id>-<attempt>` | الاسم بيظهر في CloudTrail |
| 3b | **Guard - never deploy across environments** | (1) أي environment غير `lab` لازم يعرّف **environment variable** `ENV_NAME` = اسم الـ environment نفسه، وإلا: `environment '<env>' must define its own variable ENV_NAME=<env> (plus EC2_INSTANCE_ID, APP_URL)`؛ (2) لو `EC2_INSTANCE_ID` متحدد: `describe-instances` → الـ tag `Env` لازم = `ENV_NAME`، وإلا `refusing` | بيقفل أخطر غلطة: job الـ production يقع على repo-level `EC2_INSTANCE_ID` بتاع lab (environment variable ناقص = fallback صامت). محتاج `ec2:DescribeInstances` (موجود في الـ deploy role) — تفاصيل في [34](34-environments-approvals-promotion.md) |
| 4 | Resolve digest | `describe-images --image-ids imageTag=$TAG` → `imageDigest`؛ لو `expected_digest` مختلف → fail؛ output `uri=repo:tag@digest` | **tag للبني آدمين، digest للماكينة** — اللي بيشتغل هو بالظبط اللي الـ CI عمله scan |
| 5 | Resolve targets | `InstanceIds` أو 4 tags (JSON بـ `jq -nc`) | |
| 6 | Build the remote script | `git archive --format=tar.gz HEAD <files>` → base64 (~5 KB، ~18 KB مع `deploy/ec2/lb`) → حد 40,000 → `remote.sh` = متغيرات بـ `printf '%s=%q'` + `PAYLOAD=` + heredoc → `bash -n` | **committed files only** = اللي بيتنفّذ قابل للمراجعة في الـ commit؛ `%q` = quoting آمن؛ `bash -n` = syntax check قبل الإرسال |
| 7 | Availability probe | `probe.sh` على `/ready` (0.2s) أو `/login` (0.05s) لو `generate_traffic` | قياس الـ downtime ([22](22-recreate-and-measuring-downtime.md)) |
| 8 | Run via SSM | `send-command --cli-input-json` (`AWS-RunShellScript`، `Comment` ≤ 100 حرف، `commands` = سطور السكريبت، `executionTimeout` = 1200 أو `900 + steps × step_seconds × 2` للـ canary، `TimeoutSeconds: 600`، `MaxConcurrency: "1"`، `MaxErrors: "0"`، CloudWatch output) | مع أكتر من host = **rolling يقف عند أول فشل** |
| 8b | Polling | `list-commands` كل 10s؛ `deadline = executionTimeout + 600`؛ لو عدّى → `cancel-command` + `TimedOut` | الـ runner مايستناش للأبد، والأمر مايفضلش شغال لوحده |
| 8c | النتايج | `target_count == 0` → `failed` ("no instance matched")؛ لكل invocation: status/exit code + stdout/stderr في `::group::`؛ canary exit 2 → `aborted` | SSM بيحتفظ بأول 24,000 حرف بس؛ الكامل في CloudWatch |
| 9 | Smoke | `/ready` لحد 24 × 5s؛ `status == ready`؛ ولو الـ tag SHA (7 hex) لازم `version == tag` | بيثبت إن **النسخة الجديدة** هي اللي بتخدم، مش بس إن حاجة بتخدم |
| 10–11 | Summary + Verdict | جدول image/command/outcome/smoke + نتيجة الـ probe؛ `deployed/false` نجاح، `aborted/true` نجاح الـ drill، غير كده fail | |

### 6.3 السكريبت اللي بيجري على السيرفر (root)

```text
tar -xz PAYLOAD → install compose + compose.awslogs.yml (0644) و deploy/ec2/*.sh (0755) في /opt/student-app
recreate:
   lb/state/release.env موجود؟ → exit 3 ("the zero-downtime lb stack owns :80 ...")
   deploy-pull-image.sh <repo:tag@digest>
      ECR login (المنطقة من الـ registry host) → render-env-from-ssm.sh → compose pull app
      → up -d --wait mysql (USE_LOCAL_MYSQL) → run --rm migrate --force → up -d --no-deps --wait app
      → curl /ready → CURRENT_RELEASE (والقديم → PREVIOUS_RELEASE لو مختلف) → image prune 168h
bluegreen|canary: cp lb/ (state/ مش في الـ payload → الـ routing الحي بيفضل) → render env → ECR login
   أول مرة: يشيل app container بتاع Recreate ويشغّل init.sh ؛ بعدها bluegreen.sh / canary.sh  ([23], [24], [34])
```

### 6.4 Continuous deployment (opt-in)

```bash
gh variable set EC2_CONTINUOUS_DEPLOY --body true      # لازم repo-level: الـ job-level `if` بيتقيّم قبل ما الـ environment يتحمّل
git commit --allow-empty -m "ci: trigger cd" && git push origin master   # أو merge PR على master
gh run list --workflow=deploy-ec2-ssm.yml --limit 3    # event = workflow_run
```

ليه opt-in؟ الـ lab host موجود بس وانت عامل apply لـ stack 20؛ من غيره كل push على master هيبقى deploy أحمر على حاجة مش موجودة. وخلي بالك: **`workflow_run` بيشتغل بس لو الـ workflow file موجود على الـ default branch**.

> 💡 الـ `workflow_run` بيدّيك الـ `head_sha` بتاع الـ CI run → الـ tag = أول 7 حروف منه = نفس الـ tag اللي الـ CI لسه عامله push. سلسلة نضيفة: commit → CI (test/scan/push) → CD (نفس الـ bytes).

## 7) التحقق (Verify)

```bash
CID=$(aws ssm list-commands --max-results 1 --query 'Commands[0].CommandId' --output text)
aws ssm list-commands --command-id "$CID" --query 'Commands[0].{status:Status,comment:Comment,targets:TargetCount,done:CompletedCount}'
aws ssm get-command-invocation --command-id "$CID" --instance-id <INSTANCE_ID> --query '{st:Status,rc:ResponseCode}'
aws logs tail /student-app/lab/ssm-deploy --since 30m

aws ssm start-session --target <INSTANCE_ID>
#   sudo cat /opt/student-app/CURRENT_RELEASE        → ...student-app:3f2c1ab@sha256:...
#   sudo docker inspect --format '{{index .RepoDigests 0}}' $(sudo docker ps -qf label=com.docker.compose.service=app)
curl -s <APP_URL>/ready | jq '{status, version}'
```

المفروض: Status `Success`، الـ `CURRENT_RELEASE` فيه **`@sha256:`**، الـ digest على الـ container = الـ digest في ECR، والـ version = الـ tag.

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر | المتوقع |
|---|---|---|
| tag مش في ECR | `-f image_tag=deadbee` | `::error::student-app:deadbee is not in ECR - did CI (ci.yml) push it?` — fail قبل ما يلمس السيرفر |
| `latest` | `-f image_tag=latest` | `':latest' is never deployed` |
| instance غلط | `gh variable set EC2_INSTANCE_ID --body i-0000000000000000` | `send-command` يفشل (`InvalidInstanceId`) أو `no instance matched` |
| الـ tag condition | شيل tag `Project` من الـ instance (Console) | `AccessDenied ... ssm:SendCommand` — الـ IAM condition شغال. رجّعه |
| Env tag مش مطابق | غيّر tag `Env` على الـ instance لـ `prod` (Console) ثم deploy | الـ guard: `instance i-... is tagged Env=prod but this deploy targets ENV_NAME=lab - refusing` — قبل أي `send-command`. رجّعه `lab` |
| الـ agent واقف | Session Manager → `sudo systemctl stop amazon-ssm-agent` (هتتقطع!) — أو Stop الـ instance | الأمر يفضل Pending → بعد `TimeoutSeconds` (600) `Failed`/delivery timed out. رجّعه بـ Start أو reboot |
| Release مش healthy | `aws ssm put-parameter --name /student-app/lab/app/SRE_FAULT_UNHEALTHY --type String --value true` ثم deploy | `up --wait` يفشل → invocation `Failed` (exit ≠ 0) → outcome `failed` → smoke متخطّى → verdict أحمر. **امسح الـ parameter** |
| lb stack + recreate | بعد [23](23-bluegreen-single-host.md) شغّل deploy عادي | exit 3: `the zero-downtime lb stack owns :80` |
| ملف مش committed | عدّل `deploy-pull-image.sh` locally من غير commit وشغّل | الـ payload فيه النسخة الـ committed — اللي على جهازك ملوش أثر (ده الهدف) |

## 9) الرجوع (Rollback)

```bash
# الطريقة الرسمية: redeploy للـ tag القديم (نفس الـ digest اللي كان شغال)
aws ecr describe-images --repository-name student-app --query 'sort_by(imageDetails,&imagePushedAt)[-5:].[imageTags[0],imagePushedAt]' --output table
gh workflow run deploy-ec2-ssm.yml --ref devops-lab -f image_tag=<PREVIOUS_TAG>

# طوارئ من غير GitHub: نفس السكريبت على السيرفر
aws ssm send-command --instance-ids <INSTANCE_ID> --document-name AWS-RunShellScript \
  --comment "manual rollback" --parameters 'commands=["/opt/student-app/deploy-pull-image.sh rollback"]'
```

> ⚠️ الـ migrations مبترجعش ([95](95-zero-downtime-db-migrations.md)). والـ ECR lifecycle بيحتفظ بآخر 30 image بس — rollback لأقدم من كده مش ممكن.

## 10) المسح (Teardown) ⚠️

```bash
gh variable set EC2_CONTINUOUS_DEPLOY --body false        # أو gh variable delete
aws logs delete-log-group --log-group-name /student-app/lab/ssm-deploy    # اتعمل من الـ agent: Terraform مبيعرفهوش، ومن غير retention
# والسيرفر: terraform destroy في stack 20 (21 §10)
gh variable delete EC2_INSTANCE_ID
```

## 11) التكلفة (Cost)

| Resource | السعر التقريبي (تقريبي — راجع صفحة الأسعار) |
|---|---|
| SSM Run Command / Session Manager | مجاني |
| CloudWatch Logs (output الأوامر) | ~$0.50/GB ingestion + storage (KBs لكل deploy) |
| ECR → EC2 (نفس الـ region) | مجاني (عبر الـ S3 gateway endpoint كمان) |
| EC2 | `t3.micro` يكفي (~نص تكلفة `t3.small`) لأن مفيش build |
| GitHub Actions | دقيقتين–5 لكل deploy |

## 12) أسئلة Interview

<details><summary>ليه SSM Run Command أحسن من SSH للـ deploy؟</summary>

مفيش inbound port، مفيش long-lived secret (OIDC → STS)، الـ authorization بـ IAM ومقفول بـ tag condition على instances المشروع وdocument واحد، كل أمر في CloudTrail + Command history بالـ actor والـ comment، الـ output في CloudWatch، و targeting بالـ tags مع rate control (`MaxConcurrency`/`MaxErrors`) بيدّيك rolling على fleet ببلاش. العيوب: latency أعلى، حدود حجم الـ parameters والـ output، ومحتاج الـ agent شغال وواصل لـ endpoints SSM (VPC endpoints في private subnets من غير NAT).

</details>

<details><summary>ليه deploy بالـ digest مش بالـ tag؟ الـ repo أصلاً IMMUTABLE.</summary>

الـ immutability بتمنع الكتابة فوق الـ tag **في الـ repo ده**، بس الـ digest بيثبت المحتوى في أي مكان: لو حد غيّر الإعداد، أو replication لحساب تاني، أو registry تاني. وبيخلّي الـ promotion verifiable: production بيرفض أي digest غير اللي عدّى lab ([34](34-environments-approvals-promotion.md)). وكمان `CURRENT_RELEASE` بيسجّل بالظبط إيه اللي شغال.

</details>

<details><summary>ليه السكريبتات بتتشحن بـ `git archive` جوه الأمر بدل ما تبقى على السيرفر أو في S3؟</summary>

عشان الكود اللي بيتنفّذ كـ root يبقى **بالظبط** اللي في الـ commit (reviewable، مفيش ملفات local مش committed)، ومن غير ما السيرفر يحتاج git أو access للـ repo، ومن غير bucket وصلاحيات زيادة. الحد: SSM parameters مش معمولة للـ artifacts — الـ workflow بيفشل فوق 40 KB، والحل وقتها S3 بـ presigned URL أو SSM document versioned.

</details>

<details><summary>إيه الفرق بين `TimeoutSeconds` و `executionTimeout`؟ وليه في polling deadline كمان؟</summary>

`TimeoutSeconds` = وقت التسليم: لو الـ agent ماستلمش الأمر (offline) خلال المدة → فشل. `executionTimeout` = أقصى وقت تنفيذ على الـ instance. والـ deadline في الـ workflow (`executionTimeout + 600`) حماية من إن الـ runner يستنى للأبد لو حاجة علّقت، ومعاه `cancel-command` عشان الأمر مايكمّلش لوحده بعد ما الـ CI "استسلم" (وإلا هتلاقي deploy شغال والـ CI بيقول failed).

</details>

<details><summary>إزاي `workflow_run` ممكن يبقى ثغرة؟ وإزاي الـ workflow ده محمي؟</summary>

`workflow_run` بيجري في context الـ repo الأساسي بصلاحياته وsecrets-ه حتى لو الـ workflow الأصلي جه من fork PR. لو فلترت بـ `branches: [main]` بس، fork عنده branch اسمه `main` يقدر يشغّله. هنا الشرط: `conclusion == success` و `event == push` و `head_repository.full_name == github.repository`، والـ checkout بالـ `head_sha` بتاع push حقيقي على الـ repo.

</details>

<details><summary>`MaxConcurrency: 1` و `MaxErrors: 0` — ده إيه عملياً؟</summary>

لو الـ targets أكتر من instance (بالـ tags)، SSM بيشغّل واحد واحد، وأول فشل بيوقف الباقي — rolling deploy بـ fail-fast من غير orchestrator. بس من غير load balancer مفيش drain، فده rolling "على السيرفرات" مش "على الـ traffic" — للـ traffic محتاج ALB + deregistration ([47](47-ansible-rolling-deploy.md)) أو CodeDeploy ([37](37-aws-codedeploy-ec2.md)).

</details>

<details><summary>ليه الـ smoke test بيقارن الـ version بالـ tag؟</summary>

لأن `/ready` = 200 ممكن يجي من النسخة القديمة لو الـ recreate فشل بصمت أو الـ DNS/LB لسه على حاجة تانية. `APP_VERSION` متخبّز في الـ image من الـ short SHA ([30](30-ci-github-actions.md))، فـ `version == tag` بيثبت إن الـ release الجديد هو اللي بيرد فعلاً.

</details>

## 13) Checklist

- [ ] عملت Run Command بإيدك من الـ Console وشفت الـ output في CloudWatch
- [ ] ضبطت `EC2_INSTANCE_ID` و `APP_URL` (env lab) و `SRE_LAB_TOKEN`
- [ ] شغّلت `deploy-ec2-ssm.yml` وشفت الـ digest في `CURRENT_RELEASE` و `version == tag`
- [ ] شفت الـ deploy في Command history و CloudTrail (session name)
- [ ] فعّلت `EC2_CONTINUOUS_DEPLOY` وشفت CI → CD تلقائي (وبعدين قفلته)
- [ ] جرّبت الـ break-it (tag مش موجود، tag condition، Env guard، unhealthy release)
- [ ] عملت rollback بـ tag قديم
