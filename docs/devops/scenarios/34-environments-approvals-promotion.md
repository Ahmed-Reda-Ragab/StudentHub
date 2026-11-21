# 34 — Environments و approvals و promotion و rollback

> **الهدف في سطر:** تبني مسار release حقيقي: GitHub **environments** (`lab`، `production`) بـ required reviewers و wait timer و deployment branch policy و env-scoped variables، و [`release-promote.yml`](../../../.github/workflows/release-promote.yml) اللي بيرقّي **نفس الـ digest** من lab لـ production من غير rebuild ويعمل release tag، وworkflows الـ blue/green و canary على EC2، و rollback = redeploy للـ digest اللي قبله، وفي الآخر **DORA metrics** وإزاي تقيسها من الـ repo ده.
> **المستوى:** Advanced · **الوقت:** ~3–4 ساعات · **التكلفة التقريبية:** مجاني (GitHub) + host تاني لـ production لو عملته (~نفس [20](20-ec2-compose-console.md))
> **بيعتمد على:** [02](02-aws-account-setup.md) (environments + deploy role) · [21](21-ec2-compose-terraform-ansible.md) · [23](23-bluegreen-single-host.md) · [24](24-canary-single-host.md) · [32](32-cd-ec2-ecr-ssm.md) · **الملفات في الـ repo:** [`.github/workflows/release-promote.yml`](../../../.github/workflows/release-promote.yml) · [`.github/workflows/deploy-ec2-ssm.yml`](../../../.github/workflows/deploy-ec2-ssm.yml) · [`.github/workflows/deploy-ec2-bluegreen.yml`](../../../.github/workflows/deploy-ec2-bluegreen.yml) · [`.github/workflows/deploy-ec2-canary.yml`](../../../.github/workflows/deploy-ec2-canary.yml) · [`deploy/ec2/lb/bin/`](../../../deploy/ec2/lb/bin/) · [`infra/terraform/bootstrap/github-oidc.tf`](../../../infra/terraform/bootstrap/github-oidc.tf)

## 1) الفكرة (Concepts)

لحد دلوقتي كل deploy كان على `lab`. في الحقيقة فيه **أكتر من بيئة**، والـ release بيمشي فيهم بالترتيب، وكل خطوة ليها **gate**. القاعدة الذهبية: **اللي بيوصل production هو بالظبط (نفس الـ bytes) اللي اتجرّب في lab** — مفيش rebuild بين البيئات، والـ config بس هو اللي بيختلف (SSM prefix، URL، instance).

| المصطلح | المعنى |
|---|---|
| Environment (GitHub) | اسم منطقي (`lab`، `production`) بيتربط بيه: protection rules، variables، secrets، وسجل deployments |
| Required reviewers | الـ job بيقف لحد ما واحد من القايمة (لحد 6 users/teams) يوافق |
| Wait timer | تأخير إجباري (1 دقيقة → 30 يوم) قبل ما الـ job يبدأ — "cool-off" أو وقت تراقب فيه |
| Prevent self-review | اللي شغّل الـ run مايقدرش يوافق عليه (four-eyes principle) |
| Deployment branches and tags | مين يقدر يعمل deploy على الـ environment: كله / protected branches / patterns |
| Environment variables/secrets | بتكسب على الـ repo-level بنفس الاسم جوه الـ job اللي عامل `environment:` |
| Cross-environment guard | step في `deploy-ec2-ssm.yml`: أي environment غير `lab` لازم `ENV_NAME` = اسمه، والـ tag `Env` على الـ instance = `ENV_NAME` — وإلا يرفض |
| Promotion | نقل artifact موجود (digest) لبيئة أعلى — مش build جديد |
| Release tag | `release-YYYYMMDD-<sha7>` annotated tag = سجل "إيه اتعمله release إمتى" |
| DORA metrics | Deployment frequency، Lead time for changes، Change failure rate، Time to restore (failed deployment recovery time) |

| القرار | اخترنا | البديل | ليه |
|---|---|---|---|
| الـ gate | GitHub environment protection | approval step مخصص / Slack bot | built-in، مربوط بالـ OIDC `sub`، ومتسجّل في الـ deployments history |
| الـ promotion | نفس الـ digest + `expected_digest` | rebuild من نفس الـ commit | rebuild ممكن يطلّع bytes مختلفة (base image/dependencies) |
| الـ production deploy | نفس `deploy-ec2-ssm.yml` (`workflow_call`) | workflow منفصل لـ prod | الكود اللي بيعمل deploy لـ prod اتجرّب في كل deploy على lab |
| التتبّع | git tag + GitHub deployments | spreadsheet | آلي ومن مصدر الحقيقة → DORA من غير شغل يدوي |

## 2) المعمارية (Architecture)

```text
 Actions → Release promote → Run workflow (image_tag = 3f2c1ab)     [workflow_dispatch على master]
 ┌──────────────────────────┐   needs   ┌───────────────────────────────┐   needs   ┌──────────────────────┐
 │ deploy-lab               │──────────►│ deploy-production             │──────────►│ tag-release          │
 │ uses deploy-ec2-ssm.yml  │           │ uses deploy-ec2-ssm.yml       │           │ contents: write      │
 │ environment: lab         │           │ environment: production       │           │ git tag -a           │
 │  (مفيش approval عادةً)    │           │  ⏸ required reviewers         │           │  release-<date>-<sha>│
 │ tag → digest D           │           │  ⏳ wait timer                 │           │  msg: image@digest   │
 │ deploy repo:tag@D        │           │  🔒 protected branches only    │           │  + run URL           │
 │ smoke: version == tag    │           │ expected_digest = D ──► يرفض   │           └──────────────────────┘
 │ outputs: image_digest=D  │           │   لو tag ≠ D                   │
 └────────────┬─────────────┘           │ vars (environment-scoped):    │
              │ OIDC sub=…:environment:lab   EC2_INSTANCE_ID, APP_URL,  │
              ▼                          │   ENV_NAME=production, [AWS_DEPLOY_ROLE_ARN]
     lab host (/student-app/lab/*)       └──────────────┬────────────────┘
                                                        │ OIDC sub=…:environment:production
                                                        ▼
                                          production host (Env=production, /student-app/production/*)

 deploy-ec2-bluegreen.yml / deploy-ec2-canary.yml ──uses──► deploy-ec2-ssm.yml (environment: lab, strategy bluegreen|canary)
 Rollback = Release promote بالـ tag اللي قبله (git tag -l 'release-*')  |  lb stack: bin/rollback.sh (nginx switch فوري)
```

## 3) المتطلبات (Prerequisites)

- [ ] [32](32-cd-ec2-ecr-ssm.md) شغال على lab (`EC2_INSTANCE_ID`، `APP_URL`، deploy role).
- [ ] environments `lab` و `production` ([02 §5.8](02-aws-account-setup.md)).
- [ ] bootstrap `deploy_environments` فيها `production` (الافتراضي `["lab","production"]`).
- [ ] **host لـ production** (الـ promotion محتاج host حقيقي منفصل):
  - stack 20 تاني بـ `env=production` في Terraform workspace منفصل (§5.2) → instance عليه tag `Env=production` و SSM prefix `/student-app/production/*`.
  - ⚠️ الاختصار "environment `production` يشاور على نفس الـ lab instance" **مبقاش ينفع**: الـ guard في `deploy-ec2-ssm.yml` بيرفض أي environment غير `lab` من غير `ENV_NAME` = اسمه، وبيرفض أي instance الـ tag `Env` بتاعه ≠ `ENV_NAME` (§5.3). وده صح: "production" وهمي على host الـ lab بيعلّمك عادة غلط.
- [ ] الـ repo **public** أو GitHub Enterprise — required reviewers والـ wait timer على Free/Pro/Team متاحين للـ public repos بس.
- [ ] الـ workflows على `master`.

## 4) الطريقة الأولى: GitHub UI (يدوي)

### 4.1 الـ environment `production`

**Settings → Environments → production** (أو **New environment**):

1. **Deployment protection rules:**
   - ✅ **Required reviewers** → ضيف نفسك (ولو فريق: team).
   - **Prevent self-review:** سيبها **off** لو انت لوحدك (وإلا مش هتعرف توافق). في فريق حقيقي: **on**.
   - ✅ **Wait timer** → `5` دقايق.
   - **Allow administrators to bypass configured protection rules:** شيلها في prod الحقيقي (الـ admin كمان يستنى).
2. **Deployment branches and tags** → **Protected branches only** (أو **Selected branches and tags** → `master`).
   > 🔐 ده مش تجميل: لما الـ job فيه `environment: production`، الـ OIDC `sub` = `repo:…:environment:production` **من غير branch**. من غير الـ policy دي، أي branch (حتى branch تجريبي فيه workflow معدّل) يقدر ياخد الـ deploy role باسم production.
3. **Environment variables → Add variable:**
   - `ENV_NAME` = **`production`** — لازم = اسم الـ environment بالظبط (الـ guard)، وهو كمان الـ SSM prefix (`/student-app/production/...`) وقيمة الـ tag `Env` على الـ host.
   - `APP_URL` = `http://<PROD_EIP>`.
   - `EC2_INSTANCE_ID` = الـ production instance.
   - (اختياري) `AWS_DEPLOY_ROLE_ARN` = role تاني لـ prod (مثلاً في حساب تاني) — الـ bootstrap بيعمل role واحد بس، فدي لو عملت role إضافي بنفسك.
4. **Environment secrets:** `SRE_LAB_TOKEN` الخاص بـ prod (لو هتعمل smoke/load عليه).

### 4.2 الموافقة على deploy

**Actions → الـ run** → banner **"Review deployments"** → علّم `production` → comment → **Approve and deploy** (أو **Reject**). بعدها الـ wait timer بيعدّ. السجل: **Code → Deployments** (أو `https://github.com/Ahmed-Reda-Ragab/StudentHub/deployments`) → كل environment وآخر deployment والـ commit.

## 5) الطريقة التانية: Infrastructure as Code (gh + Terraform)

### 5.1 الـ environments as code

```bash
REPO=Ahmed-Reda-Ragab/StudentHub
MY_ID=$(gh api user --jq .id)
gh api -X PUT "repos/$REPO/environments/production" --input - <<JSON
{
  "wait_timer": 5,
  "prevent_self_review": false,
  "reviewers": [{ "type": "User", "id": $MY_ID }],
  "deployment_branch_policy": { "protected_branches": true, "custom_branch_policies": false }
}
JSON
gh variable set ENV_NAME --env production --body production
gh variable set APP_URL --env production --body "http://<PROD_EIP>"
gh variable set EC2_INSTANCE_ID --env production --body "<PROD_INSTANCE_ID>"
gh variable set ENV_NAME --env lab --body lab
gh variable list --env production
gh api "repos/$REPO/environments/production" --jq '{rules: [.protection_rules[] | {type, wait_timer}], policy: .deployment_branch_policy}'
```

> ⚠️ "Protected branches only" بيشتغل بس لو `master` عليه branch protection/ruleset فعلاً ([30 §6.7](30-ci-github-actions.md)). لو مفيش ولا branch محمي، **كل الـ branches** تقدر تعمل deploy.

### 5.2 الـ production host بـ Terraform workspace

الـ stack 20 مثبّت الـ backend key، فبنستخدم **workspace** (الـ S3 backend بيحط الـ state في `env:/production/stacks/20-ec2-single/terraform.tfstate`) و `-var env=production` (كل الأسماء ومسار SSM والـ tag `Env` بتتغيّر: `student-app-production-*`، `/student-app/production/*`، `Env=production` — بالظبط اللي الـ guard مستنيه):

```bash
cd infra/terraform/stacks/20-ec2-single
terraform workspace new production          # terraform workspace list → * production
terraform plan -var env=production -var scenario=34 -var instance_type=t3.micro -out=tfplan-prod
terraform apply tfplan-prod
PROD_IID=$(terraform output -raw instance_id); PROD_URL=$(terraform output -raw app_url)
gh variable set EC2_INSTANCE_ID --env production --body "$PROD_IID"
gh variable set APP_URL --env production --body "$PROD_URL"
terraform workspace select default          # ⚠️ ارجع دايماً — أي apply بعدها على الـ workspace الغلط = كارثة
```

> 💡 الـ deploy role مش محتاج تعديل: الـ `SendCommand` مقفول على `Project=student-app` (الـ prod host عليه نفس الـ tag)، والـ instance role بتاع production بيقرا `/student-app/production/*` بس. في شركة حقيقية: **production في AWS account منفصل** و role منفصل (environment variable `AWS_DEPLOY_ROLE_ARN`) — الـ environments في GitHub مش بديل عن عزل الحسابات.

### 5.3 ⚠️ الفخ الأخطر: fallback للـ repo variable — والـ guard اللي بيقفله

`deploy-ec2-ssm.yml` بيقرا `vars.EC2_INSTANCE_ID` و `vars.APP_URL` و `vars.ENV_NAME`. جوه job بـ `environment: production`، لو **مفيش** environment variable بالاسم ده، GitHub بيرجع للـ **repo-level** — يعني قيم الـ lab. من غير حماية، الـ "production deploy" كان هيروح على الـ lab host بصمت (والـ digest check هيعدّي لأنه نفس الـ image).

الـ step **"Guard - never deploy across environments"** (بعد الـ OIDC) بيقفل ده بطبقتين:

1. أي environment غير `lab` لازم يعرّف **environment variable** `ENV_NAME` = اسم الـ environment (`production`)، وإلا: `environment 'production' must define its own variable ENV_NAME=production (plus EC2_INSTANCE_ID, APP_URL) - refusing to fall back to repo-level (lab) values`.
2. لو `EC2_INSTANCE_ID` متحدد: الـ tag `Env` على الـ instance لازم = `ENV_NAME`، وإلا: `instance i-... is tagged Env=lab but this deploy targets ENV_NAME=production - refusing`.

اللي **لسه** عليك: الـ guard بيتأكد من `ENV_NAME` والـ instance، بس **`APP_URL` مالوش check** — لو ناقص على `production`، الـ smoke test هيضرب الـ lab URL ويعدّي غلط. فعرّف `EC2_INSTANCE_ID` و `APP_URL` (و `ENV_NAME`) على كل environment، وراجع `gh variable list --env production` قبل أول promote. القاعدة العامة: **defense in depth** — الـ config ممكن تغلط، فالـ pipeline يتحقق من الهدف بمصدر مستقل (الـ tag على الـ resource نفسه).

## 6) الـ Deploy

### 6.1 `release-promote.yml` خطوة بخطوة

```bash
TAG=$(aws ecr describe-images --repository-name student-app --query 'sort_by(imageDetails,&imagePushedAt)[-1].imageTags[0]' --output text)
gh workflow run release-promote.yml --ref master -f image_tag=$TAG
gh run watch "$(gh run list --workflow=release-promote.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
# لما يوصل deploy-production: Actions → Review deployments → Approve → الـ wait timer → الـ deploy
```

| Job | التفاصيل | نقطة senior |
|---|---|---|
| `deploy-lab` | `uses: ./.github/workflows/deploy-ec2-ssm.yml` مع `environment: lab`، `image_tag`؛ `permissions: id-token: write` (الـ called workflow محتاجها) | الـ outputs: `image_uri`، `image_digest`، `outcome` |
| `deploy-production` | `needs: deploy-lab`؛ نفس الـ workflow بـ `environment: production` و **`expected_digest: needs.deploy-lab.outputs.image_digest`** | الـ guard بيتأكد إن `ENV_NAME=production` متعرّف على الـ environment وإن الـ instance عليه `Env=production` (§5.3)؛ ولو الـ tag بقى يشاور على digest تاني (مستحيل في نفس الـ repo IMMUTABLE، ممكن عبر حسابات/registries) → `refusing to promote different bytes` |
| `tag-release` | `needs: [deploy-lab, deploy-production]`؛ `contents: write`؛ `fetch-depth: 0`؛ `git rev-parse --verify "${IMAGE_TAG}^{commit}"`؛ `release-$(date -u +%Y%m%d)-<sha7>`؛ لو موجود (`ls-remote`) → notice؛ غير كده annotated tag فيه `Released to production: <uri>` + `digest:` + run URL → push | idempotent: re-run في نفس اليوم مش هيفشل |

نقاط مهمة:

- **مفيش rebuild:** الـ CI عمل الـ image مرة ([30](30-ci-github-actions.md))؛ الـ promote بيستخدمها بالـ digest في البيئتين.
- **نفس code path:** production بيتعمله deploy بنفس الـ workflow اللي اتجرّب عشرات المرات على lab.
- السكريبتات اللي بتتشحن للـ host (`git archive`) من الـ ref اللي شغّلت عليه الـ promote (`master`)، مش من الـ commit بتاع الـ image.
- concurrency: كل environment ليه group (`deploy-lab-ec2-single`، `deploy-production-ec2-single`).
- لو حطيت required reviewer على `lab` (عشان `terraform apply` — [02 §5.8](02-aws-account-setup.md))، `deploy-lab` كمان هيستنى موافقة.

### 6.2 Blue/Green و Canary على EC2 من GitHub

[`deploy-ec2-bluegreen.yml`](../../../.github/workflows/deploy-ec2-bluegreen.yml) و [`deploy-ec2-canary.yml`](../../../.github/workflows/deploy-ec2-canary.yml) wrappers فوق `deploy-ec2-ssm.yml` (`environment: lab` ثابت، ومن غير `concurrency` بتاعهم — الـ called job هو اللي ماسك الـ lock، ولو الـ caller مسك نفس الـ group كان هيحصل deadlock).

| Workflow | Inputs | بيعمل إيه على الـ host |
|---|---|---|
| blue/green | `image_tag`، `keep_old` (✅)، `drain_seconds` (10)، `slot_env` (drill)، `use_local_mysql` | أول مرة: يشيل Recreate app و `init.sh`؛ بعدها `bluegreen.sh` ([23](23-bluegreen-single-host.md)) |
| canary | `image_tag`، `steps` (`10 25 50 100`)، `step_seconds` (60)، `max_error_rate` (0.01)، `min_requests` (10)، `slot_env`، `expect_abort`، `generate_traffic` (✅)، `use_local_mysql` | `canary.sh`: exit 2 = الـ gate عمل abort → outcome `aborted` ([24](24-canary-single-host.md)) |

```bash
gh workflow run deploy-ec2-bluegreen.yml --ref master -f image_tag=$TAG
gh workflow run deploy-ec2-bluegreen.yml --ref master -f image_tag=$TAG -f slot_env=SRE_FAULT_UNHEALTHY=true   # drill: الـ traffic ميتحركش
gh workflow run deploy-ec2-canary.yml --ref master -f image_tag=$TAG
gh workflow run deploy-ec2-canary.yml --ref master -f image_tag=$TAG -f slot_env=SRE_FAULT_ERROR_RATE=0.5 -f expect_abort=true   # drill: لازم abort
```

> 💡 الـ verdict في الـ drill معكوس: `expect_abort=true` + aborted = **أخضر** (الـ gate اشتغل)، و promoted = **أحمر** (الـ gate فشل يمسك release سيء). كده الـ drill نفسه بيتعمله test في الـ CI.

> ⚠️ بعد ما تنقل الـ host لـ lb stack، `deploy-ec2-ssm.yml` بـ `strategy=recreate` (اللي `release-promote` بيستخدمه افتراضياً) بيرفض بـ exit 3. يعني يا تفضل على Recreate في الـ promote، يا تخلّي الـ host كله blue/green.

### 6.3 الـ Rollback = redeploy للـ digest اللي قبله

```bash
git fetch --tags
git tag -l 'release-*' --sort=-creatordate | head -5
git tag -n3 release-<DATE>-<SHA>                      # الـ annotation: image@digest + run
PREV=$(git rev-parse --short=7 "$(git tag -l 'release-*' --sort=-creatordate | sed -n 2p)^{commit}")
gh workflow run release-promote.yml --ref master -f image_tag=$PREV
```

| الموقف | Rollback | الوقت |
|---|---|---|
| Recreate (lab أو prod) | `release-promote` بالـ tag اللي قبله (lab → approval → prod) | دقايق + الـ approval + الـ wait timer |
| lab بس / طوارئ على lab | `gh workflow run deploy-ec2-ssm.yml -f image_tag=<PREV>` | دقايق |
| lb stack (blue/green لسه شغال القديم) | `bin/rollback.sh` = nginx switch فوري | ثواني |

```bash
# lb stack rollback فوري عن طريق SSM
aws ssm send-command --instance-ids <INSTANCE_ID> --document-name AWS-RunShellScript \
  --comment "lb rollback" --parameters 'commands=["/opt/student-app/lb/bin/rollback.sh"]'
```

> 💡 **Trade-off للـ interview:** الـ rollback عن طريق `release-promote` بيعدّي على lab والـ approval والـ wait timer → بيزوّد الـ MTTR. حلول: environment `production-rollback` بـ reviewers من غير wait timer مع workflow بيقبل بس digests موجودة في release tags قديمة، أو "break-glass" موثّق. القاعدة: الرجوع لنسخة اتجرّبت قبل كده أقل خطورة من release جديد، فممكن يبقى gate-ه أخف — بس لازم يتسجّل.

### 6.4 DORA metrics — إزاي تقيسها من الـ repo ده

| Metric | التعريف | Elite (تقريبي، تقارير DORA) | المصدر هنا |
|---|---|---|---|
| **Deployment frequency** | كام مرة بتعمل deploy لـ production | on-demand (أكتر من مرة في اليوم) | release tags / GitHub deployments على `production` |
| **Lead time for changes** | من الـ commit لحد ما يبقى في production | أقل من يوم | تاريخ الـ commit مقابل تاريخ الـ release tag |
| **Change failure rate** | نسبة الـ deploys اللي سببت مشكلة احتاجت remediation (rollback/hotfix/incident) | ~0–15% | rollbacks (promote لـ tag أقدم) + incidents مربوطة بـ deploy |
| **Time to restore / failed deployment recovery time** | من بداية العطل لحد ما الخدمة ترجع | أقل من ساعة | deployment statuses / وقت الـ rollback |

**Deployment frequency:**

```bash
git fetch --tags
git for-each-ref 'refs/tags/release-*' --format='%(creatordate:format:%G-W%V)' | sort | uniq -c   # deploys لكل أسبوع
REPO=Ahmed-Reda-Ragab/StudentHub
gh api "repos/$REPO/deployments?environment=production&per_page=100" --paginate --jq '.[].created_at' | cut -c1-10 | sort | uniq -c
```

**Lead time for changes** (لكل commit دخل في كل release، مش آخر commit بس):

```bash
prev=""
for t in $(git tag -l 'release-*' --sort=creatordate); do
  released=$(git for-each-ref "refs/tags/$t" --format='%(creatordate:unix)')
  range=${prev:+$prev..}$t
  git log --format=%ct "$range" | while read -r c; do echo $(( (released - c) / 3600 )); done
  prev=$t
done | sort -n | awk '{a[NR]=$1} END {print "commits:", NR, " median lead time (h):", a[int((NR+1)/2)], " p90 (h):", a[int(NR*0.9)]}'
```

**Change failure rate** (proxy آلي + تصنيف بشري):

```bash
# rollback = promote لـ commit أقدم من آخر release
git for-each-ref 'refs/tags/release-*' --sort=creatordate --format='%(refname:short) %(*objectname)' | \
  awk 'BEGIN{n=0;r=0} {if (seen[$2]) r++; seen[$2]=1; n++} END {printf "releases=%d redeploy-of-old-commit=%d\n", n, r}'
gh run list --workflow=release-promote.yml --limit 100 --json conclusion --jq 'group_by(.conclusion) | map({(.[0].conclusion): length}) | add'
```

> ⚠️ run أحمر ≠ change failure. deploy فشل في lab ووقف قبل production = الـ pipeline **نجح** في حمايتك. الـ CFR بيعدّ التغييرات اللي **وصلت production وأذت**؛ الأدق إنك تفتح issue بـ label `incident` لكل مشكلة سببها deploy وتربطه بالـ release tag، والـ CFR = incidents ÷ releases.

**Time to restore:**

```bash
gh api "repos/$REPO/deployments?environment=production&per_page=20" --jq '.[] | "\(.id) \(.sha[0:7]) \(.created_at)"'
gh api "repos/$REPO/deployments/<DEPLOYMENT_ID>/statuses" --jq '.[] | "\(.state) \(.created_at)"'
# MTTR ≈ وقت أول deployment ناجح بعد العطل − وقت بداية العطل (من الـ alarm/incident، مش من وقت الـ deploy)
```

> 💡 للـ portfolio ([98](98-portfolio-and-interview.md)): اعمل جدول أسبوعي بالأرقام الأربعة من الأوامر دي. والكلام اللي يفرق في الـ interview: الأرقام دي بتتقاس على **مستوى الفريق/الخدمة** عشان تحسّن الـ system، مش عشان تقيّم أفراد (وإلا الناس هتلعب في الأرقام).

## 7) التحقق (Verify)

```bash
gh run view <PROMOTE_RUN_ID>          # 3 jobs خضرا؛ Summary: image + digest (نفس الـ digest في البيئتين) + git tag
git fetch --tags && git show --no-patch release-<DATE>-<SHA>
curl -s <LAB_URL>/ready  | jq -r .version
curl -s <PROD_URL>/ready | jq -r .version     # نفس الـ version
aws ssm start-session --target <PROD_INSTANCE_ID>    # sudo cat /opt/student-app/CURRENT_RELEASE → نفس @sha256:... بتاع lab
gh api repos/Ahmed-Reda-Ragab/StudentHub/deployments --jq '.[0:4][] | {environment, sha: .sha[0:7], created_at}'
```

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر | المتوقع |
|---|---|---|
| deploy لـ prod من branch مش محمي | `gh workflow run release-promote.yml --ref devops-lab -f image_tag=$TAG` | `deploy-lab` ينجح، و `deploy-production` يقف: `Branch "devops-lab" is not allowed to deploy to production due to environment protection rules` |
| Reject | في الـ approval اختار **Reject** | `deploy-production` failed، و `tag-release` مبيشتغلش — مفيش tag لـ release متعملش |
| Smoke في lab فشل | خلّي lab unhealthy (`SRE_FAULT_UNHEALTHY=true` في `/student-app/lab/app/`) ثم promote | `deploy-lab` أحمر → production عمره ما بيبدأ (ده الـ gate الحقيقي — مش الـ approval) |
| `ENV_NAME` ناقص | `gh variable delete ENV_NAME --env production` ثم promote | `deploy-production` يقف في الـ guard: `must define its own variable ENV_NAME=production` (§5.3) — رجّعه |
| instance غلط | `gh variable set EC2_INSTANCE_ID --env production --body <LAB_INSTANCE_ID>` | الـ guard: `instance ... is tagged Env=lab but this deploy targets ENV_NAME=production - refusing` — رجّع الـ production ID |
| `APP_URL` ناقص | امسح `APP_URL` من environment `production` | الـ deploy يتم صح، بس الـ smoke بيكلّم الـ **lab URL** (fallback) — الـ guard مابيغطّيش ده؛ رجّعه |
| tag مش commit | `-f image_tag=ci-v2` (لو موجود في ECR) | `tag-release`: `image tag ci-v2 is not a commit in this repository - cannot tag the release` |
| Canary سيء | canary drill بـ `SRE_FAULT_ERROR_RATE=0.5` و `expect_abort=false` | outcome `aborted` → verdict أحمر `canary aborted - the release was NOT promoted` |
| Self-review | فعّل Prevent self-review وانت لوحدك | مش هتلاقي زرار Approve — الـ run هيفضل مستني (اقفلها تاني) |

## 9) الرجوع (Rollback)

§6.3. والـ checklist: (1) حدّد آخر release سليم من `git tag -l 'release-*'`، (2) promote بالـ tag بتاعه، (3) راقب `/ready` و الـ version، (4) افتح incident وسجّل الأوقات (للـ MTTR والـ CFR)، (5) افتكر إن الـ migrations مبترجعش ([95](95-zero-downtime-db-migrations.md)) — لو الـ release السيء عمل migration مش backward compatible، الـ rollback للكود لوحده مش هيكفي.

## 10) المسح (Teardown) ⚠️

```bash
# production host
cd infra/terraform/stacks/20-ec2-single
terraform workspace select production
terraform destroy -var env=production
terraform workspace select default && terraform workspace delete production
aws logs delete-log-group --log-group-name /student-app/production/ssm-deploy 2>/dev/null
# GitHub (اختياري — الـ environments مجانية)
gh variable delete EC2_INSTANCE_ID --env production; gh variable delete APP_URL --env production
# الـ release tags: سيبها (تاريخ + DORA)
```

## 11) التكلفة (Cost)

| Resource | السعر التقريبي (تقريبي — راجع صفحة الأسعار) |
|---|---|
| GitHub environments، approvals، deployments API | مجاني (protection rules في الـ private repos محتاجة plan أعلى) |
| الـ wait timer | مش بيتحسب من دقائق الـ Actions |
| production host | stack 20 تاني: `t3.micro` + EBS + EIP ≈ $0.4/يوم |

## 12) أسئلة Interview

<details><summary>ليه promotion بالـ digest بدل rebuild لكل بيئة؟</summary>

الـ rebuild من نفس الـ commit مش deterministic (base image اتحدّثت، dependency بـ range، build date) → اللي في production مش اللي اتجرّب. بالـ digest الـ bytes متطابقة، والـ `expected_digest` بيخلي ده enforced مش مجرد اتفاق. الـ config بس اللي بيختلف بين البيئات (12-factor)، وعشان كده الـ config برّه الـ image (SSM prefix لكل env).

</details>

<details><summary>الـ GitHub environment protection بيحمي إيه بالظبط؟ وإيه اللي مبيحميهوش؟</summary>

بيحمي إن الـ job اللي بيدّعي إنه production يستنى موافقة/وقت ويكون من branch مسموح، ولأن الـ OIDC `sub` بيبقى `environment:production`، الـ AWS role ممكن يتقفل على ده. مبيحميش لو حد عنده admin وبيعمل bypass (اقفل الـ admin bypass)، ولا لو الـ role نفسه بيثق في branches من غير environment، ولا من fallback الـ variables للـ repo-level (ده اللي الـ guard في `deploy-ec2-ssm.yml` بيقفله بالتحقق من `ENV_NAME` والـ tag `Env` على الـ instance). والأهم: مش بديل عن عزل الحسابات (prod في AWS account منفصل بـ role منفصل).

</details>

<details><summary>الـ wait timer و required reviewers — مش بيبطّأوا الـ delivery؟ إزاي توازن؟</summary>

بيزوّدوا الـ lead time والـ MTTR. الـ elite teams بتقلّل الـ gates اليدوية وبتعتمد على gates آلية (tests، canary analysis، SLO burn rate) + deploys صغيرة متكررة. الـ approval اليدوي مفيد لـ compliance (SOX/PCI: four-eyes) أو للتغييرات الخطيرة. الحل الوسط: approval على production بس، wait timer قصير بيستخدم كـ "bake time" على lab، ومسار rollback أخف.

</details>

<details><summary>عرّف DORA الأربعة وقولّي إزاي بتقيسهم هنا.</summary>

Deployment frequency (release tags/deployments على production لكل أسبوع)، Lead time for changes (لكل commit: وقت الـ release tag − وقت الـ commit، median و p90)، Change failure rate (releases سببت incident/rollback ÷ كل الـ releases)، Time to restore (من بداية العطل لأول deployment ناجح بعده). الأولين throughput والتانيين stability، والمهم إنهم مع بعض: سرعة من غير استقرار أو العكس مش نجاح.

</details>

<details><summary>Rollback ولا roll-forward؟</summary>

Rollback لما فيه نسخة سليمة معروفة والـ schema متوافقة (expand/contract)، وده أسرع وأقل مخاطرة. Roll-forward (fix + deploy) لما الـ rollback مستحيل (migration هدّامة، داتا اتكتبت بشكل جديد) أو الـ fix صغير وواضح والـ pipeline سريع. القاعدة: صمّم بحيث الـ rollback دايماً ممكن (backward compatible migrations، feature flags) وبعدين قرّر وقت الـ incident.

</details>

<details><summary>ليه production بيتعمله deploy بنفس الـ reusable workflow بتاع lab؟</summary>

عشان كود الـ deploy نفسه يتجرّب في كل deploy على lab — أي bug فيه هيبان في lab الأول. workflow منفصل لـ prod بيتشغّل نادراً ويتعفّن، وأول مرة تكتشف إنه بايظ تبقى وقت release مهم. الفروق بين البيئات تبقى data (environment variables) مش code.

</details>

<details><summary>الـ release tag بيتعمل بعد production — ليه مش قبل؟</summary>

الـ tag = "ده اللي اتعمله release فعلاً في production"، فلو اتعمل قبل وفشل الـ deploy أو اترفض، السجل يبقى كداب والـ DORA تتلخبط. وفيه `needs: [deploy-lab, deploy-production]` عشان كده، والـ annotation فيها الـ digest والـ run URL للـ audit.

</details>

## 13) Checklist

- [ ] `production` environment بـ reviewers + wait timer + protected branches + env variables (`ENV_NAME=production`، `EC2_INSTANCE_ID`، `APP_URL`)
- [ ] production host (workspace `production`، tag `Env=production`) وجرّبت الـ guard (ENV_NAME ناقص / instance غلط)
- [ ] `release-promote.yml` عدّى: نفس الـ digest في البيئتين + release tag
- [ ] جرّبت deploy من branch مش محمي و Reject
- [ ] شغّلت blue/green و canary drills من GitHub
- [ ] عملت rollback بالـ tag اللي قبله
- [ ] طلّعت الأربع DORA metrics بالأوامر
