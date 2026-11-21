# 35 — AWS CodeBuild (buildspec، webhook، GitHub Actions runners)

> **الهدف في سطر:** تعيد بناء الـ CI على **AWS CodeBuild** بـ stack 35 والـ module (projects `ci` / `image` / `gha-runner`)، تفهم الـ buildspecs سطر بسطر، الـ source عن طريق **CodeConnections** (GitHub App، من غير PAT)، الـ privileged Docker والـ local layer cache، وتشغّل **CodeBuild-hosted GitHub Actions runner** (`runs-on: codebuild-<project>-${{ github.run_id }}-${{ github.run_attempt }}`)، وتقارن التكلفة والقرار مع GitHub-hosted runners.
> **المستوى:** Intermediate · **الوقت:** ~3 ساعات · **التكلفة التقريبية:** سنتات (بالدقيقة؛ مفيش idle cost)
> **بيعتمد على:** [02](02-aws-account-setup.md) (CodeConnections = AVAILABLE، ECR) · [30](30-ci-github-actions.md) · **الملفات في الـ repo:** [`infra/terraform/stacks/35-codebuild/`](../../../infra/terraform/stacks/35-codebuild/) ([`main.tf`](../../../infra/terraform/stacks/35-codebuild/main.tf) · [`variables.tf`](../../../infra/terraform/stacks/35-codebuild/variables.tf) · [`outputs.tf`](../../../infra/terraform/stacks/35-codebuild/outputs.tf) · [`README.md`](../../../infra/terraform/stacks/35-codebuild/README.md)) · [`infra/terraform/modules/codebuild/`](../../../infra/terraform/modules/codebuild/main.tf) · [`deploy/codebuild/buildspec-ci.yml`](../../../deploy/codebuild/buildspec-ci.yml) · [`deploy/codebuild/buildspec-build.yml`](../../../deploy/codebuild/buildspec-build.yml) · [`deploy/codebuild/README.md`](../../../deploy/codebuild/README.md)

## 1) الفكرة (Concepts)

**CodeBuild** = build service managed: كل build بيقوم في container جديد (على compute بتاع AWS)، بيعمل clone للـ source، ينفّذ **buildspec** (phases)، يرفع logs و reports و artifacts، ويختفي. بتدفع **بالدقيقة**، ومفيش servers تديرها. ليه تستخدمه وعندك GitHub Actions؟

- الـ build **جوه حسابك** (و ممكن جوه الـ VPC — يوصل لـ RDS/private APIs).
- صلاحيات بـ **IAM role للـ project** (مفيش OIDC setup، مفيش secrets في GitHub).
- compute أكبر/ARM/GPU بالدقيقة، و reserved fleets.
- جزء طبيعي من **CodePipeline** ([36](36-aws-codepipeline.md)).
- كـ **runner لـ GitHub Actions**: تفضل كاتب workflows بـ YAML بتاع GitHub، بس الـ job بيجري على CodeBuild بالـ role بتاعه.

| المصطلح | المعنى |
|---|---|
| Project | تعريف الـ build: source، environment (image/compute/privileged)، buildspec، role، logs، cache، webhook |
| Buildspec (`version: 0.2`) | YAML: `env` → `phases` (`install` → `pre_build` → `build` → `post_build`) → `reports` → `artifacts` → `cache` |
| `runtime-versions` | اختيار نسخة اللغة من اللي جوه الـ image (`php: 8.3`) |
| Privileged mode | Docker daemon جوه الـ build container (لـ `docker build`) |
| Local cache | `LOCAL_DOCKER_LAYER_CACHE` / `LOCAL_SOURCE_CACHE` / `LOCAL_CUSTOM_CACHE` على الـ build host — مجاني، best effort |
| Report group | JUnit/coverage بيظهروا في تاب Reports (pass/fail لكل test) |
| Webhook filter groups | الـ groups بينهم **OR**، والـ filters جوه الـ group **AND** |
| `CODEBUILD_RESOLVED_SOURCE_VERSION` | الـ commit SHA الفعلي اللي اتعمله build |
| Exported variables | متغيرات buildspec بتطلع لـ CodePipeline (`#{BuildVariables.IMAGE_URI}`) |

## 2) المعمارية (Architecture)

```text
 GitHub repo ──(AWS Connector for GitHub app / CodeConnections student-app-github)──┐
   push / PR / workflow_job queued  ──► webhooks اللي CodeBuild عملها                 │
                                                                                     ▼
 ┌─ CodeBuild (stack 35, module codebuild: role + log group لكل project) ───────────────────────────┐
 │ student-app-ci          buildspec-ci.yml     webhook: PUSH on ^refs/heads/(master|main|devops-lab)$ │
 │                                              OR PULL_REQUEST_CREATED/UPDATED/REOPENED               │
 │                         standard:8.0 · SMALL · not privileged · cache LOCAL_CUSTOM + LOCAL_SOURCE   │
 │                         → report group student-app-ci-phpunit (JUnit) · commit status على GitHub    │
 │ student-app-image       buildspec-build.yml  manual (أو enable_image_webhook → push على master)     │
 │                         privileged · cache LOCAL_DOCKER_LAYER + LOCAL_SOURCE · ECR push (repo بس)   │
 │                         → <acct>.dkr.ecr.<region>.amazonaws.com/student-app:<sha7> (skip لو موجود)  │
 │ student-app-gha-runner  (enable_gha_runner) webhook: WORKFLOW_JOB_QUEUED · privileged                │
 │                         ephemeral runner لكل job بـ runs-on: codebuild-student-app-gha-runner-…     │
 │                         بـ role الـ project (+ ECR push لو gha_runner_ecr_push)                     │
 └──────────────────────────────────────────────────────────────────────────────────────────────────────┘
        logs ──► CloudWatch /aws/codebuild/<project> (14 days)
```

## 3) المتطلبات (Prerequisites)

- [ ] bootstrap: `codeconnections_arn`، والـ connection **AVAILABLE** ([02 §5.7](02-aws-account-setup.md)) والـ app متنصّب على الـ repo.
- [ ] ECR `student-app` موجود.
- [ ] `infra/terraform/backend.hcl` و `AWS_PROFILE=student-lab-admin`.
- الأدوات: `aws`، `terraform`، `gh`.

## 4) الطريقة الأولى: AWS Console (يدوي)

> ⚠️ لو هتعمل stack 35 بـ Terraform، استخدم أسماء مختلفة هنا (مثلاً `student-app-ci-console`) أو امسح اللي عملته قبل الـ apply.

### 4.1 Project الـ CI

**CodeBuild → Build projects → Create build project**:

1. **Project configuration:** Name `student-app-ci-console` · Project type **Default project**.
2. **Source:** Source provider **GitHub** → Credential: **Manage account credential → GitHub App** → Connection `student-app-github` → **Repository in my GitHub account** → `Ahmed-Reda-Ragab/StudentHub` · Source version (فاضي = default branch) · Git clone depth **1**.
3. **Primary source webhook events:** ✅ **Rebuild every time a code change is pushed to this repository** · Build type **Single build** · Filter group 1: Event type **PUSH** + Start a build under these conditions → **HEAD_REF** `^refs/heads/(master|main|devops-lab)$` · **Add filter group** → Event type **PULL_REQUEST_CREATED, PULL_REQUEST_UPDATED, PULL_REQUEST_REOPENED**.
4. **Environment:** Provisioning **On-demand** · **Managed image** · Compute **EC2** · OS **Ubuntu** · Runtime **Standard** · Image **aws/codebuild/standard:8.0** · Service role **New service role** · Additional configuration: Timeout 20 min · Compute 3 GB / 2 vCPUs (= `BUILD_GENERAL1_SMALL`).
5. **Buildspec:** **Use a buildspec file** → `deploy/codebuild/buildspec-ci.yml`.
6. **Artifacts:** No artifacts · **Additional configuration → Cache type: Local** → ✅ Source cache، ✅ Custom cache.
7. **Logs:** ✅ CloudWatch logs.
8. **Create build project** → **Start build**.

تابع: **Build history → الـ build → Phase details** (مدة كل phase) و **Build logs** و تاب **Reports** (الـ JUnit). وعلى GitHub هتلاقي commit status من CodeBuild جنب الـ checks.

### 4.2 Project الـ image (Docker)

نفس الخطوات مع: Name `student-app-image-console` · من غير webhook · Environment → Additional configuration → ✅ **Privileged** · **Environment variables:** `ECR_REPO=student-app`، `ENV_NAME=lab`، `AWS_ACCOUNT_ID=<ACCOUNT_ID>` · Buildspec `deploy/codebuild/buildspec-build.yml` · Cache: Local → ✅ **Docker layer cache**، ✅ Source cache.

بعد الإنشاء: **IAM → الـ service role اللي اتعمل** → ضيف ECR push على `student-app` بس (نفس statements بتاعة `student-app-gha-ci` في [30 §4.3](30-ci-github-actions.md)) — الـ role اللي الـ Console بيعمله مفيهوش ECR.

### 4.3 Runner project (GitHub Actions)

**Create build project** → Project type **Runner project** → Runner provider **GitHub** → Runner location **Repository** → الـ repo → Environment زي 4.2 (privileged لو الـ jobs بتعمل `docker build`) → Create. الـ buildspec بيتجاهل (إلا لو استخدمت label `buildspec-override:true`). تأكد في GitHub: **Settings → Webhooks** → webhook بيبعت **Workflow jobs**.

## 5) الطريقة التانية: Infrastructure as Code (stack 35)

### 5.1 الـ variables

| Variable | الافتراضي | المعنى |
|---|---|---|
| `codeconnections_arn` | (required) | `terraform -chdir=../../bootstrap output -raw codeconnections_arn` |
| `build_image` | `aws/codebuild/standard:8.0` | Ubuntu 24.04؛ PHP 8.2–8.5 (الافتراضي 8.4 — عشان كده الـ buildspec بيثبّت 8.3) |
| `ci_branches` | `["master","main","devops-lab"]` | pushes اللي بتشغّل الـ CI (الـ PRs دايماً) |
| `enable_ci_webhook` | `true` | |
| `enable_image_webhook` / `image_branch` | `false` / `master` | الـ image بيتبني بإيدك افتراضياً (GitHub Actions بيعمل push already — مفيش داعي لاتنين يتسابقوا) |
| `enable_gha_runner` / `gha_runner_ecr_push` | `false` / `false` | |
| `dockerhub_username_parameter` / `dockerhub_token_parameter` | `null` | **أسماء** SSM parameters (القيم عمرها ما بتعدّي على Terraform) |

### 5.2 الـ module ([`modules/codebuild`](../../../infra/terraform/modules/codebuild/main.tf))

- **role لكل project** (`<name>-codebuild`) بـ trust على `codebuild.amazonaws.com` + `aws:SourceAccount` (ضد confused deputy) → الـ CI project **مايقدرش** يعمل push لـ ECR، والـ runner مايلمسش ECR إلا لو طلبت.
- Statements حسب الإعدادات: `WriteOwnLogs` (log group بتاعه بس)، `UseGitHubConnection` (بالـ prefixين `codeconnections:` و `codestar-connections:` — الـ connections القديمة قبل rename 2024 ليها ARNs `codestar-connections`)، `EcrPushAppRepository` (لو `ecr_push`)، `TestReports` (report groups `<name>-*`)، `ReadBuildParameters` (`ssm:GetParameters` على الـ parameters المحددة بس).
- **log group** `/aws/codebuild/<project>` بـ retention 14 يوم (Terraform بيعمله، فبيتمسح مع الـ destroy).
- **source** `GITHUB` + `auth { type = "CODECONNECTIONS" }` + `report_build_status = true` + clone depth 1.
- **cache** `type = "LOCAL"` بالـ modes.
- **webhook** (`aws_codebuild_webhook`) — CodeBuild بيعمله في GitHub عن طريق الـ GitHub App.

### 5.3 الـ apply

```bash
cd infra/terraform/stacks/35-codebuild
cp terraform.tfvars.example terraform.tfvars
sed -i "s|^codeconnections_arn = .*|codeconnections_arn = \"$(terraform -chdir=../../bootstrap output -raw codeconnections_arn)\"|" terraform.tfvars
echo 'enable_gha_runner = true' >> terraform.tfvars        # اختياري (§6.3)
terraform init -backend-config=../../backend.hcl
terraform plan -out=tfplan
terraform apply tfplan
terraform output
# project_names = { ci = "student-app-ci", image = "student-app-image", gha-runner = "student-app-gha-runner" }
# role_arns, log_groups, start_build_commands, gha_runner_label
```

### 5.4 `buildspec-ci.yml` سطر بسطر

| الجزء | السطر | ليه |
|---|---|---|
| `env.variables` | `COMPOSER_NO_INTERACTION=1`، `COMPOSER_CACHE_DIR=/root/.composer/cache` | مفيش prompts؛ والـ cache في مسار ثابت عشان الـ `cache.paths` |
| `install.runtime-versions` | `php: 8.3` | الـ image default 8.4 وبيتغيّر مع الوقت — pin للـ CONVENTIONS |
| `install.commands` | `php -v` · `php -m \| grep -qi pdo_sqlite` · نزّل composer لو مش موجود | fail بدري لو الـ extension ناقصة (الـ tests على SQLite in-memory) |
| `pre_build` | `composer install --prefer-dist --no-progress` · `cp .env.example .env` · `php artisan key:generate` | نفس `ci.yml` |
| `build` | `vendor/bin/pint --test` · `mkdir -p reports` · `php artisan test --compact --log-junit reports/junit.xml` | أي command بيفشل → الـ phase يفشل → الـ build FAILED |
| `reports.phpunit` | `base-directory: reports`، `junit.xml`، `JUNITXML` | report group اسمه `<project>-phpunit` = `student-app-ci-phpunit` |
| `cache.paths` | `/root/.composer/cache/**/*` | مع `LOCAL_CUSTOM_CACHE` |

> 💡 في `version: 0.2` كل الأوامر بتجري في **shell واحد** — المتغير اللي اتعمله export في phase بيكمّل للي بعدها (عكس 0.1).

### 5.5 `buildspec-build.yml` سطر بسطر

| الجزء | السطر | ليه |
|---|---|---|
| `env.variables` | `ECR_REPO`، `ENV_NAME`، `TASKDEF_SOURCE=repo`، `TASK_FAMILY`، `DOCKER_BUILDKIT=1` | defaults؛ الـ project بيـ override (`ECR_REPO`، `ENV_NAME`، `AWS_ACCOUNT_ID`) |
| `env.exported-variables` | `IMAGE_URI`، `IMAGE_TAG` | لـ CodePipeline: `#{BuildVariables.IMAGE_URI}` ([36](36-aws-codepipeline.md)) |
| `pre_build` 1 | `AWS_ACCOUNT_ID` من الـ env أو من `CODEBUILD_BUILD_ARN` (field 5)؛ `REGISTRY`؛ `IMAGE_TAG` = أول 7 من `CODEBUILD_RESOLVED_SOURCE_VERSION`؛ يرفض فاضي أو `latest` | الـ tag = نفس الـ tag بتاع GitHub Actions → نفس الـ ECR repo من غير تضارب |
| `pre_build` 2 | `aws ecr get-login-password \| docker login` | |
| `pre_build` 3 | `docker login` لـ Docker Hub لو `DOCKERHUB_USERNAME`/`TOKEN` | الـ IPs بتاعة CodeBuild مشتركة → anonymous pulls بتاخد `429 toomanyrequests` |
| `build` | لو `describe-images imageTag=$IMAGE_TAG` موجود → skip؛ غير كده `docker build -f docker/Dockerfile --build-arg APP_VERSION VCS_REF BUILD_DATE` + `docker push` | الـ repo **IMMUTABLE**: re-run لنفس الـ commit (أو GitHub Actions سبقه) مايفشلش — build once |
| `post_build` | `CODEBUILD_BUILD_SUCCEEDING != 1` → exit 1 | **`post_build` بيجري حتى لو `build` فشل** — من غير الـ guard كنت هتطلّع artifacts لـ build بايظ |
| `post_build` | `imagedefinitions.json` · `imageDetail.json` · `taskdef.json` (`render-taskdef.sh repo\|live`) · `appspec.yaml` | للـ ECS/CodeDeployToECS deploy actions في [36](36-aws-codepipeline.md) |
| `artifacts` | الـ 4 ملفات، `discard-paths: yes` | في stack 35 الـ project `NO_ARTIFACTS` فبتتجاهل؛ في 36 بتبقى `build_output` |

### 5.6 Privileged Docker والـ layer cache

- **Privileged** = الـ build container بيشغّل Docker daemon (Docker-in-Docker) بـ capabilities واسعة. لازم لـ `docker build`، و**ماتفعّلهوش** على projects مش محتاجاه (الـ `ci` مش privileged). البدائل من غير privileged: Kaniko/BuildKit rootless.
- **`LOCAL_DOCKER_LAYER_CACHE`**: الـ layers بتتحفظ على الـ build host؛ build تاني خلال دقايق ممكن ينزل على نفس الـ host ويعيد استخدام `vendor`/`npm` layers. **مش مضمون** (host مختلف = cold). للـ cache الموثوق: `docker buildx --cache-to type=registry` (ECR cache image) أو S3 cache.

## 6) الـ Deploy (تشغيل الـ builds)

### 6.1 Builds يدوي ومتابعة

```bash
aws codebuild start-build --project-name student-app-ci --source-version devops-lab --query 'build.id' --output text
BID=$(aws codebuild start-build --project-name student-app-image --source-version master --query 'build.id' --output text)
aws logs tail /aws/codebuild/student-app-image --follow
aws codebuild batch-get-builds --ids "$BID" --query 'builds[0].{status:buildStatus,phase:currentPhase,sha:resolvedSourceVersion,mins:phases[?phaseType==`BUILD`].durationInSeconds}'
aws codebuild list-reports-for-report-group --report-group-arn \
  "arn:aws:codebuild:us-east-1:<ACCOUNT_ID>:report-group/student-app-ci-phpunit" --max-items 1
```

### 6.2 الـ webhook

```bash
git switch devops-lab && git commit --allow-empty -m "ci: codebuild webhook" && git push
aws codebuild list-builds-for-project --project-name student-app-ci --max-items 1
gh api repos/Ahmed-Reda-Ragab/StudentHub/commits/$(git rev-parse HEAD)/statuses --jq '.[] | {context, state}'   # CodeBuild status
```

### 6.3 CodeBuild-hosted GitHub Actions runner

مع `enable_gha_runner = true`: أي job بـ label `codebuild-<project-name>-${{ github.run_id }}-${{ github.run_attempt }}` → GitHub بيبعت `workflow_job` queued → CodeBuild بيقوّم build بيسجّل **ephemeral runner** (JIT) للـ job ده بس، وبعد الـ job يختفي. الـ `run_id` بيربط الـ build بالـ run (لو الـ run اتلغى الـ build بيقف).

مثال workflow (للتجربة في branch — **مش موجود في الـ repo**):

```yaml
name: CodeBuild runner demo
on: workflow_dispatch
permissions:
  contents: read
jobs:
  build:
    runs-on: codebuild-student-app-gha-runner-${{ github.run_id }}-${{ github.run_attempt }}
    steps:
      - uses: actions/checkout@v6
      - run: docker build -f docker/Dockerfile -t student-app:test .
      - run: aws sts get-caller-identity     # credentials الـ project role — من غير OIDC ولا secrets
```

Overrides لكل job (نفس شكل [`deploy/codebuild/README.md`](../../../deploy/codebuild/README.md) وصفحة "Label overrides" في docs الـ CodeBuild — كل override **label منفصل** في القايمة):

```yaml
    runs-on:
      - codebuild-student-app-gha-runner-${{ github.run_id }}-${{ github.run_attempt }}
      - image:arm-3.0
      - instance-size:medium
      - build-job          # label فريد للـ job: لو فيه أكتر من job بعدد overrides مختلف، يمنع runner ياخد job مش بتاعه
```

البديل "single label" (كل الـ overrides في label واحد): `runs-on: codebuild-student-app-gha-runner-${{ github.run_id }}-${{ github.run_attempt }}-arm-3.0-medium`.

> ⚠️ **أمان الـ runner:** الـ job بياخد credentials الـ project role تلقائي. أي حد يقدر يشغّل workflow في الـ repo (أو يفتح PR من branch، أو fork PR في repo public لو الـ workflow بيجري على `pull_request`) ممكن يطلب الـ label ده. حدّد الـ role (`gha_runner_ecr_push = false` افتراضياً)، فعّل **Require approval for fork pull request workflows**، وفكّر في filter على الـ webhook (مثلاً `WORKFLOW_NAME`/`ACTOR_ACCOUNT_ID`). ده نفس تحذير GitHub من self-hosted runners على public repos.

### 6.4 CodeBuild مقابل GitHub-hosted runners

| | GitHub-hosted | CodeBuild (buildspec) | CodeBuild-hosted GHA runner |
|---|---|---|---|
| الـ syntax | Actions YAML + marketplace | buildspec | Actions YAML |
| الـ AWS auth | OIDC (setup مرة) | project role | project role |
| الشبكة | إنترنت عام | ممكن جوه VPC | ممكن جوه VPC |
| الـ compute | sizes ثابتة (larger runners بفلوس) | small→2xlarge، ARM، GPU، Lambda، reserved fleets | زي CodeBuild + overrides في الـ label |
| الـ cache | `actions/cache`، `type=gha` (~10 GB/repo) | LOCAL (best effort) / S3 | الاتنين |
| التكلفة | مجاني للـ public؛ الـ private دقائق مجانية ثم بالدقيقة | بالدقيقة (§11)، free tier للحسابات القديمة | بالدقيقة CodeBuild |
| الـ ecosystem | الأكبر | أقل | Actions ecosystem كامل |
| Compliance (build جوه حسابك) | لأ | أيوه | أيوه |

**القرار:** ابدأ بـ GitHub-hosted. روح لـ CodeBuild لما: محتاج VPC access، compute خاص/ARM أرخص، compliance، أو انت جوه CodePipeline. الـ runner mode أحسن الاتنين لو الفريق بيحب Actions بس محتاج الـ build في AWS.

## 7) التحقق (Verify)

```bash
aws codebuild batch-get-projects --names student-app-ci student-app-image \
  --query 'projects[].{name:name,image:environment.image,privileged:environment.privilegedMode,cache:cache.modes,role:serviceRole}'
aws codebuild list-builds-for-project --project-name student-app-image --max-items 3
aws ecr describe-images --repository-name student-app --image-ids imageTag=$(git rev-parse --short=7 origin/master)
gh api repos/Ahmed-Reda-Ragab/StudentHub/hooks --jq '.[] | {url: .config.url, events}'      # webhooks بتاعة CodeBuild (لو عندك صلاحية)
```

المفروض: الـ `ci` أخضر + report فيه الـ tests، الـ `image` إما بنى وعمل push أو قال `already exists in ECR, skipping build`، والـ commit عليه status من CodeBuild.

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر | المتوقع |
|---|---|---|
| Connection مش AVAILABLE | اعمل الـ apply قبل الـ handshake | الـ webhook creation أو أول build يفشل (`connection ... is not available`) |
| من غير privileged | Console → Edit environment → شيل Privileged من الـ image project → build | `Cannot connect to the Docker daemon at unix:///var/run/docker.sock` |
| Test بيفشل | branch فيه `assertTrue(false)` | phase `BUILD` FAILED، الـ report فيه الـ test الأحمر، و commit status = failure |
| Docker Hub rate limit | builds كتير ورا بعض | `toomanyrequests: You have reached your pull rate limit` → `dockerhub_*_parameter` أو ECR pull-through cache |
| Re-run لنفس الـ commit | `start-build` مرتين بنفس `--source-version` | التانية: `already exists in ECR, skipping build` (IMMUTABLE + build once) |
| post_build guard | خلّي الـ `docker build` يفشل (Dockerfile غلط في branch) | `build failed - no deploy artifacts` — مفيش `imagedefinitions.json` لحاجة بايظة |
| label غلط | `runs-on: codebuild-wrong-name-${{ github.run_id }}-${{ github.run_attempt }}` | الـ job يفضل **Queued** (مفيش project بالاسم ده) — الغه |

## 9) الرجوع (Rollback)

CodeBuild مبيعملش deploy، فالـ "rollback" هنا: `git revert` للـ commit اللي كسر الـ build، أو redeploy لـ tag قديم ([32](32-cd-ec2-ecr-ssm.md)) — الـ images القديمة لسه في ECR بالـ SHA. ولو إعداد project اتبوّظ من الـ Console: `terraform apply` بيرجّعه.

## 10) المسح (Teardown) ⚠️

```bash
cd infra/terraform/stacks/35-codebuild
terraform destroy                     # projects + roles + log groups + webhooks
# لو عملت projects من الـ Console:
aws codebuild delete-project --name student-app-ci-console
aws codebuild delete-project --name student-app-image-console
aws logs describe-log-groups --log-group-name-prefix /aws/codebuild/ --query 'logGroups[].logGroupName'
aws iam list-roles --query "Roles[?contains(RoleName,'codebuild')].RoleName"     # roles الـ Console (codebuild-<name>-service-role)
```

تأكد في GitHub إن الـ webhooks اتشالت (Settings → Webhooks).

## 11) التكلفة (Cost)

| Resource | السعر التقريبي (us-east-1، on-demand، تقريبي — راجع صفحة الأسعار) |
|---|---|
| `BUILD_GENERAL1_SMALL` Linux | ~$0.005/build-minute |
| `BUILD_GENERAL1_MEDIUM` / `LARGE` | ~$0.01 / ~$0.02 للدقيقة |
| ARM (`arm-3.0` small) | أرخص من x86 بنفس الحجم |
| Free tier (الحسابات على الـ legacy Free Tier) | 100 build-minutes/شهر على general1.small |
| CloudWatch Logs | ~$0.50/GB ingestion (14-day retention) |
| مثال | CI ~3 دقايق + image ~5–8 دقايق ≈ **$0.05 لكل push** |

> 💡 مفيش idle cost خالص — الـ projects والـ webhooks مجانية. الفلوس بس وقت الـ build. (أسعار GitHub Actions بتتغيّر من وقت للتاني — راجع صفحة GitHub billing قبل ما تقارن أرقام.)

## 12) أسئلة Interview

<details><summary>إمتى تختار CodeBuild بدل GitHub Actions؟</summary>

لما الـ build محتاج يوصل لموارد private في الـ VPC، أو compliance بيطلب إن الـ build والـ credentials جوه حسابك، أو compute خاص (ARM/GPU/large) بالدقيقة، أو انت بتبني على CodePipeline. لو مفيش ده، GitHub Actions أبسط وأغنى. والحل الوسط: CodeBuild-hosted runners — Actions YAML بـ compute و IAM بتوع AWS.

</details>

<details><summary>ليه role لكل project بدل role واحد للـ CodeBuild كله؟</summary>

Least privilege: الـ CI بيشغّل كود الـ PRs (أي collaborator يقدر يعدّل الـ tests أو الـ buildspec) فلازم مايقدرش يعمل push لـ ECR أو يقرا secrets. الـ image project بيعمل push لـ repo واحد بس. الـ runner مالوش ECR إلا لو طلبت. ولو project اتخترق، الضرر محصور فيه.

</details>

<details><summary>ليه `post_build` محتاج guard على `CODEBUILD_BUILD_SUCCEEDING`؟</summary>

في CodeBuild، `post_build` بيجري حتى لو `build` فشل (عشان cleanup/notifications). لو بيكتب `imagedefinitions.json`، الـ artifact هيطلع لـ build فاشل وممكن pipeline ياخده. الـ guard بيخلّي الـ phase يفشل لو الـ build فشل → مفيش artifacts.

</details>

<details><summary>Privileged mode — إيه المخاطر والبدائل؟</summary>

الـ container بياخد capabilities واسعة وبيشغّل Docker daemon؛ كود خبيث في الـ build عنده سطح هجوم أكبر على الـ host (وإن كان CodeBuild بيعزل كل build). البدائل: Kaniko أو BuildKit rootless، أو build على compute منفصل. والقاعدة: privileged بس على الـ projects اللي بتبني images، ومش على اللي بتشغّل كود PRs غير موثوق.

</details>

<details><summary>الـ CodeBuild runner لـ GitHub Actions بيشتغل إزاي؟ وإيه خطره؟</summary>

CodeBuild بيعمل webhook على `workflow_job` queued؛ لما job الـ label بتاعه بيطابق `codebuild-<project>-<run_id>-<attempt>`، بيقوّم build بيسجّل JIT ephemeral runner للـ job ده ويموت بعده. الخطر إن الـ job بياخد الـ project role من غير OIDC conditions، فأي workflow يطلب الـ label ياخد الصلاحية — لازم role ضيق، approval لـ fork PRs، وfilters على الـ webhook.

</details>

<details><summary>إزاي تخلي الـ Docker builds سريعة على CodeBuild؟</summary>

ترتيب الـ Dockerfile (dependencies قبل الكود)، `LOCAL_DOCKER_LAYER_CACHE` للـ builds المتقاربة، والأضمن remote cache (`buildx --cache-from/--cache-to type=registry` على ECR)، و base images من ECR (pull-through cache) بدل Docker Hub، و compute أكبر للـ builds التقيلة (الدقيقة أغلى بس العدد أقل)، و skip لو الـ tag موجود (build once).

</details>

## 13) Checklist

- [ ] عملت project من الـ Console (CI) وشفت phases و reports و commit status
- [ ] عملت stack 35 بـ Terraform وفهمت الـ module (role لكل project)
- [ ] قريت الـ buildspecs سطر بسطر (pin الـ PHP، guard الـ post_build، skip لو الـ tag موجود)
- [ ] شغّلت `student-app-image` وشفت الـ image في ECR (أو skip)
- [ ] (اختياري) جرّبت الـ GHA runner بـ workflow demo في branch
- [ ] جرّبت الـ break-it (privileged، rate limit، label غلط)
- [ ] `terraform destroy` واتأكدت إن الـ webhooks اتشالت
