# 30 — CI على GitHub Actions (tests، scans، ECR بـ OIDC)

> **الهدف في سطر:** تفهم `ci.yml` job بـ job (Pint، tests على SQLite و MySQL، audit، hadolint، build مرة واحدة، smoke، Trivy، SBOM، push لـ ECR بـ **OIDC** من غير AWS keys)، تعمل الـ OIDC provider والـ role بإيدك من الـ Console مرة وبـ Terraform bootstrap مرة، وتقفل الـ branch بـ required checks.
> **المستوى:** Intermediate · **الوقت:** ~4 ساعات · **التكلفة التقريبية:** مجاني/سنتات (ECR storage)
> **بيعتمد على:** [02 — تجهيز حساب AWS](02-aws-account-setup.md) · [10](10-containerize-app.md) · [11](11-image-hardening.md) · **الملفات في الـ repo:** [`.github/workflows/ci.yml`](../../../.github/workflows/ci.yml) · [`.github/workflows/lab-integration.yml`](../../../.github/workflows/lab-integration.yml) · [`.github/workflows/lint-infra.yml`](../../../.github/workflows/lint-infra.yml) · [`phpunit.xml`](../../../phpunit.xml) · [`.github/dependabot.yml`](../../../.github/dependabot.yml)

## 1) الفكرة (Concepts)

الـ CI بيجاوب على سؤال واحد لكل commit: **"الـ artifact ده يستاهل يتعمله deploy؟"** — وبيطلّع artifact واحد immutable (image بـ tag = SHA) اتعمله test و scan، عشان الـ CD بعد كده يعمل deploy لنفس الـ digest في كل مكان ("build once, deploy many").

| المصطلح | المعنى |
|---|---|
| Job / step | الـ jobs بتجري بالتوازي على runners منفصلة (إلا لو `needs`)، والـ steps جوه الـ job بالترتيب |
| Matrix | نفس الـ job بقيم مختلفة (`db: [sqlite, mysql]`) |
| Service container | container جنب الـ job (MySQL 8.4 هنا) |
| OIDC | الـ job بياخد JWT من GitHub، وAWS STS بيبدّله بـ credentials مؤقتة لو الـ claims مطابقة للـ trust policy |
| `id-token: write` | الصلاحية اللي بتسمح للـ job يطلب الـ OIDC token |
| Required status checks | الـ merge ممنوع لحد ما jobs معينة تنجح |

## 2) المعمارية (Architecture)

```text
 push (master|main|devops-lab) [paths-ignore: docs/**, **/*.md] · pull_request [كل الـ paths] · workflow_dispatch
 concurrency: ci-<ref>, cancel-in-progress
 ┌──────────────┐ ┌────────────────────────┐ ┌────────────────────┐ ┌──────────────┐
 │ lint (Pint)  │ │ test [sqlite | mysql]  │ │ audit (report only) │ │ hadolint     │
 └──────┬───────┘ └───────────┬────────────┘ └────────────────────┘ └──────┬───────┘
        └─────────────────────┼────────────── needs ────────────────────────┘
                              ▼
 ┌─ image (id-token: write, packages: write) ─────────────────────────────────────────┐
 │ buildx build --load (cache type=gha) → smoke (/up, apcu, id) → Trivy → SBOM artifact │
 │ if push && (master|main) && vars.AWS_ROLE_ARN:                                      │
 │   configure-aws-credentials (OIDC → student-app-gha-ci) → ECR login → push :<sha7> │
 │ if push && vars.PUSH_GHCR == 'true':  push ghcr.io/<owner>/<repo>:<sha7>           │
 └─────────────────────────────────────────────────────────────────────────────────────┘
          │ JWT: iss=token.actions.githubusercontent.com  aud=sts.amazonaws.com
          ▼      sub=repo:Ahmed-Reda-Ragab/StudentHub:ref:refs/heads/master
 AWS STS AssumeRoleWithWebIdentity ─► role student-app-gha-ci ─► ECR student-app (IMMUTABLE)
```

## 3) المتطلبات (Prerequisites)

- [ ] الـ repo `Ahmed-Reda-Ragab/StudentHub` وصلاحية admin عليه (للـ variables والـ rulesets).
- [ ] حساب AWS + profile شغال ([02](02-aws-account-setup.md)).
- [ ] واحدة من الاتنين: الـ **bootstrap stack** (`infra/terraform/bootstrap`) اتعمله apply، **أو** هتعمل الـ OIDC provider والـ role والـ ECR repo بإيدك (§4).
- الأدوات: `gh`، `aws`، `terraform` (للطريقة التانية).

## 4) الطريقة الأولى: AWS Console (يدوي)

> ⚠️ لو الـ bootstrap stack اتعمله apply، الموارد دي موجودة — **متعملهاش تاني** (الـ OIDC provider واحد بس لكل URL في الحساب، والتكرار هيعمل conflict مع Terraform). اعمل الـ Console path في حساب نضيف، أو اعمل `terraform import` بعدها ([91](91-terraform-import-and-drift.md)).

### 4.1 الـ OIDC identity provider

1. **IAM → Identity providers → Add provider**.
2. **Provider type:** OpenID Connect.
3. **Provider URL:** `https://token.actions.githubusercontent.com`
4. **Audience:** `sts.amazonaws.com`
5. لو ظهر زرار **Get thumbprint** دوس عليه (AWS بقت بتتحقق من GitHub بـ trusted root CAs فالـ thumbprint مش هو الحماية، بس الـ console القديم كان بيطلبه).
6. Tags: `Project=student-app`، `ManagedBy=console`، `Scenario=30` → **Add provider**.

### 4.2 الـ ECR repository (لو مش موجود)

1. **ECR → Private registry → Repositories → Create repository**.
2. Name: `student-app` · **Image tag mutability: Immutable** · Encryption: AES-256 → **Create**.
3. فعّل scan on push (من إعدادات الـ scanning — [11 §4](11-image-hardening.md)).

### 4.3 الـ permissions policy (push لـ repo واحد بس)

**IAM → Policies → Create policy → JSON** → اسم `student-app-gha-ci-ecr-push`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "EcrAuth", "Effect": "Allow", "Action": "ecr:GetAuthorizationToken", "Resource": "*" },
    {
      "Sid": "PushStudentApp",
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer",
        "ecr:DescribeImages"
      ],
      "Resource": "arn:aws:ecr:us-east-1:<ACCOUNT_ID>:repository/student-app"
    }
  ]
}
```

(`GetAuthorizationToken` مينفعش يتحدد بـ resource؛ الباقي مقفول على الـ repo.)

### 4.4 الـ role

1. **IAM → Roles → Create role** → **Trusted entity type: Web identity**.
2. **Identity provider:** `token.actions.githubusercontent.com` · **Audience:** `sts.amazonaws.com`.
3. لو الـ wizard طلّعلك حقول **GitHub organization / repository / branch** املاها (`Ahmed-Reda-Ragab` / `StudentHub` / `master`). لو مطلعتش، هنكتب الـ trust policy بإيدنا في الخطوة 6.
4. **Permissions:** `student-app-gha-ci-ecr-push` → Next.
5. **Role name:** `student-app-gha-ci` → **Create role**.
6. افتح الـ role → **Trust relationships → Edit trust policy**:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com" },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": [
            "repo:Ahmed-Reda-Ragab/StudentHub:ref:refs/heads/master",
            "repo:Ahmed-Reda-Ragab/StudentHub:ref:refs/heads/main"
          ]
        }
      }
    }
  ]
}
```

أشكال الـ `sub` claim اللي لازم تعرفها:

| الحالة | `sub` |
|---|---|
| push على branch | `repo:<owner>/<repo>:ref:refs/heads/<branch>` |
| tag | `repo:<owner>/<repo>:ref:refs/tags/<tag>` |
| job بـ `environment:` | `repo:<owner>/<repo>:environment:<name>` (بيحل محل الـ ref! — مهم في [34](34-environments-approvals-promotion.md)) |
| pull request | `repo:<owner>/<repo>:pull_request` |

> 🔐 **أخطر غلطة:** trust policy من غير شرط على `sub` (أو `repo:*` / `repo:<owner>/*`) = أي repo على GitHub (أو أي repo عندك) يقدر ياخد الـ role. دايماً `aud` + `sub` محدد. والـ role ده push بس — الـ deploy role (`student-app-gha-deploy`) منفصل وبصلاحيات تانية.

### 4.5 الـ repo variables (GitHub)

**Settings → Secrets and variables → Actions → Variables → New repository variable** — أو بـ `gh`:

```bash
gh variable set AWS_REGION --body us-east-1
gh variable set AWS_ROLE_ARN --body arn:aws:iam::<ACCOUNT_ID>:role/student-app-gha-ci
gh variable set ECR_REPOSITORY --body student-app
gh variable set PUSH_GHCR --body false          # true = push لـ ghcr.io كمان
gh variable list
```

الجدول الكامل من [CONVENTIONS §9](../CONVENTIONS.md) (هتحتاج الباقي في السيناريوهات الجاية):

| Name | النوع | المصدر | بيستخدمه |
|---|---|---|---|
| `AWS_REGION` | variable | `us-east-1` | كل الـ AWS workflows |
| `AWS_ROLE_ARN` | variable | bootstrap output `github_ci_role_arn` | `ci.yml` (push لـ ECR) |
| `AWS_DEPLOY_ROLE_ARN` | variable | bootstrap output `github_deploy_role_arn` | 32، 34، 58 |
| `AWS_TERRAFORM_ROLE_ARN` | variable | bootstrap output `github_terraform_role_arn` | 92 |
| `ECR_REPOSITORY` | variable | `student-app` | `ci.yml` |
| `EC2_INSTANCE_ID` | variable | stack 20 output | 32 |
| `EC2_HOST` | variable | stack 20 output | 31 بس |
| `ECS_CLUSTER` / `ECS_SERVICE` | variable | stack 50 outputs | 58 |
| `EKS_CLUSTER` | variable | stack 60 output | 6x |
| `EC2_SSH_PRIVATE_KEY` | **secret** | — | 31 بس (الطريقة القديمة) |
| `SRE_LAB_TOKEN` | **secret** | نفس `/student-app/lab/app/SRE_LAB_TOKEN` | smoke/load على EC2 |

## 5) الطريقة التانية: Infrastructure as Code (Terraform bootstrap)

الـ stack `infra/terraform/bootstrap` (مرة واحدة، long-lived — [CONVENTIONS §6](../CONVENTIONS.md)) بيعمل: state bucket، الـ GitHub OIDC provider + roles (`student-app-gha-ci`، `student-app-gha-deploy`، `student-app-gha-terraform`)، الـ ECR repo (IMMUTABLE، scan on push، lifecycle)، و CodeConnections.

```bash
cd infra/terraform/bootstrap
terraform init
terraform plan -out tfplan
terraform apply tfplan
terraform output -raw github_ci_role_arn
terraform output -raw ecr_repository_url

gh variable set AWS_ROLE_ARN --body "$(terraform output -raw github_ci_role_arn)"
gh variable set AWS_REGION --body us-east-1
gh variable set ECR_REPOSITORY --body student-app
```

(الـ backend والـ variables بالتفصيل في README الـ stack وفي [02](02-aws-account-setup.md). المقارنة اللي تهمك: الـ trust policy اللي Terraform عملها لازم تبقى بنفس الـ conditions اللي كتبتها بإيدك في §4.4.)

## 6) الـ Deploy — `ci.yml` job بـ job

**الـ triggers:** `push` على `master`/`main`/`devops-lab` مع `paths-ignore: ["docs/**", "**/*.md"]` (push فيه docs بس مش بيشغّل CI)، و `pull_request` **من غير أي paths filter** (عشان الـ required status checks تتبعت دايماً، حتى في PR فيه docs بس — §6.7)، و `workflow_dispatch`. `concurrency: ci-${{ github.ref }}` مع `cancel-in-progress: true` (push جديد بيلغي القديم على نفس الـ ref). `permissions: contents: read` على مستوى الـ workflow (least privilege)، والـ `image` job بس هو اللي بياخد `id-token: write` و `packages: write`.

### 6.1 `lint` — Pint

`shivammathur/setup-php@v2` (PHP 8.3، Composer v2، من غير coverage) → `actions/cache@v4` لـ `~/.composer/cache/files` بـ key = hash الـ `composer.lock` → `composer install` (بالـ dev) → `vendor/bin/pint --test` (بيفشل لو فيه ملف محتاج format، من غير ما يعدّل).

### 6.2 `test` — SQLite و MySQL (matrix)

```yaml
services:
  mysql: { image: mysql:8.4, env: { MYSQL_ROOT_PASSWORD: root, MYSQL_DATABASE: testing }, ports: ["3306:3306"], options: --health-cmd=... }
env:
  DB_CONNECTION: ${{ matrix.db }}
  DB_DATABASE: ${{ matrix.db == 'mysql' && 'testing' || ':memory:' }}
  DB_HOST: 127.0.0.1 ... DB_USERNAME: root  DB_PASSWORD: root
steps: ... cp .env.example .env && php artisan key:generate → php artisan test --compact
```

**إزاي الـ env بتتغلب على `phpunit.xml`؟** [`phpunit.xml`](../../../phpunit.xml) فيه `<env name="DB_CONNECTION" value="sqlite"/>` و `DB_DATABASE=:memory:` **من غير `force="true"`**. PHPUnit بيحط قيمة الـ `<env>` بس لو المتغير **مش موجود** في الـ environment. فالأولوية:

1. env الـ job (الـ OS) ← بيكسب.
2. `<env>` في `phpunit.xml` ← لو مش موجود فوق (`CACHE_STORE=array`، `SESSION_DRIVER=array`، `SRE_LAB_ENABLED=false`، `METRICS_ENABLED=false`، `METRICS_STORAGE=memory`...).
3. `.env` ← Laravel's Dotenv immutable، مش بيغيّر متغير موجود.

ليه الاتنين؟ SQLite سريع ومن غير dependencies، بس MySQL هو اللي في الـ production: `->change()`، الـ collations (`utf8mb4_unicode_ci`)، strict mode، و `->after()` بيتصرفوا مختلف. migration زي `add_pricing_to_subscriptions_table` ممكن تعدّي على SQLite وتقع على MySQL أو العكس. (ملاحظة: الـ MySQL service بيقوم في الـ leg بتاع sqlite كمان — وقت ضايع صغير.)

### 6.3 `audit` — report only

step اسمه `composer audit` (`composer audit --locked --format=table`) و step اسمه `npm audit` (`npm audit --audit-level=high`)، **كل واحد `continue-on-error: true` لوحده**، والـ job كمان `continue-on-error: true`.

**ليه على المستويين؟** على مستوى الـ step: فشل `composer audit` ميمنعش `npm audit` إنه يجري (من غيرها الـ steps بتقف عند أول فشل وكنت هتخسر نص التقرير). على مستوى الـ job: الـ workflow ميبقاش أحمر بسبب الـ audit.

**ليه report-only؟** advisories موجودة في dependencies مش لازم تمنع كل delivery (ممكن ملهاش fix، أو مش reachable)؛ بتتتبع في [82](82-supply-chain-security.md) و Dependabot. الـ trade-off: لو محدش بيبص عليه بيتحول لضوضاء. الأحسن على المدى: gate على advisories **جديدة** بس.

### 6.4 `dockerfile-lint` — hadolint

`hadolint/hadolint-action@v3.1.0` على `docker/Dockerfile` بـ `failure-threshold: error`.

### 6.5 `image` — build مرة واحدة → smoke → scan → SBOM → push

| Step | بيعمل إيه | ليه |
|---|---|---|
| Short SHA + build date | `sha=${GITHUB_SHA::7}` و `date=$(date -u +%Y-%m-%dT%H:%M:%SZ)` | الـ tag الرسمي ([CONVENTIONS §2](../CONVENTIONS.md)) + تاريخ build موجود في كل الأحداث (push و PR و dispatch) |
| `docker/setup-buildx-action@v3` | BuildKit builder | الـ gha cache |
| `docker/build-push-action@v7` | `load: true`، tag `student-app:<full sha>`، build-args `APP_VERSION=<sha7>`، `VCS_REF=<sha>`، `BUILD_DATE=<steps.vars.outputs.date>`، `cache-from/to: type=gha` (mode=max) | الـ image بتتبني **مرة واحدة** وتتحمّل في الـ runner للـ smoke والـ scan |
| Container smoke test | `docker run` بـ SQLite و `array` drivers → يستنى `/up` (30 × 2s) → `php -m \| grep apcu` → `id` | الـ image بتقوم فعلاً، فيها APCu، و non-root |
| Trivy | `aquasecurity/trivy-action@0.36.0`، CRITICAL/HIGH، `ignore-unfixed`، `exit-code: "0"` | report-only؛ قصة الـ pin في [11](11-image-hardening.md) |
| SBOM | `anchore/sbom-action@v0` → `sbom.spdx.json` → `upload-artifact` (`sbom`) | inventory |
| OIDC | `aws-actions/configure-aws-credentials@v6` بـ `role-to-assume: vars.AWS_ROLE_ARN` — **بس** لو `push` على `master`/`main` و `AWS_ROLE_ARN` متحدد | مفيش keys؛ والـ PRs و `devops-lab` مش بيعملوا push |
| ECR login | `aws-actions/amazon-ecr-login@v2` | |
| Push | لو الـ tag `<sha7>` موجود أصلاً (`aws ecr describe-images ... imageTag=<sha7>`): يكتب `already exists (immutable) - push skipped` في الـ step summary ويخرج بنجاح. غير كده `docker tag` + `docker push $REGISTRY/student-app:<sha7>` | نفس الـ image اللي اتعملها scan — مش build تاني؛ والـ re-run لنفس الـ commit مبيفشلش |
| GHCR | لو `vars.PUSH_GHCR == 'true'` على أي push: login بـ `GITHUB_TOKEN` → `ghcr.io/<owner>/<repo>:<sha7>` (lowercase) | بديل من غير AWS |

نقاط Senior:

- **ECR IMMUTABLE + re-run**: الـ tag مش ممكن يتكتب فوقه (`ImageTagAlreadyExistsException`)، فالـ step بيتأكد الأول بـ `describe-images` ويعدّي لو الـ tag موجود — الـ re-run لنفس الـ commit بقى idempotent. ده محتاج `ecr:DescribeImages` في policy الـ CI role (موجودة في §4.3)؛ لو الصلاحية ناقصة الـ check بيفشل بصمت (output متوجّه لـ `/dev/null`) ويحاول push → وهيقع بالـ exception على الـ re-run.
- **`BUILD_DATE`** بيتحسب في step الـ vars بـ `date -u`، فالـ label `org.opencontainers.image.created` موجودة في كل الأحداث.
- **`load: true`** بيدعم platform واحدة؛ الـ multi-arch ([11](11-image-hardening.md)) محتاج push مباشر من buildx.

**GHCR مقابل ECR:** GHCR مجاني للـ public ومش محتاج AWS، بس الـ pull من EC2/ECS محتاج token (أو package public) وبيعدّي على الإنترنت. ECR جوه الـ region (أسرع، من غير egress)، متكامل مع IAM (instance profile / task role)، وفيه scanning و lifecycle.

### 6.6 جرّب

```bash
git switch devops-lab
git commit --allow-empty -m "ci: trigger"          # ملحوظة: commit فاضي = مفيش ملفات اتغيرت، فـ paths filters ممكن تتخطاه
gh workflow run ci.yml --ref devops-lab             # الأضمن
gh run watch
gh pr create --base master --head devops-lab --fill # PR = نفس الـ jobs من غير push
```

بعد merge على `master` (و `AWS_ROLE_ARN` متحدد):

```bash
gh run list --workflow=ci.yml --branch master --limit 1
gh run view <RUN_ID> --log | grep -i "Pushed\|assumed\|already exists"
aws ecr describe-images --repository-name student-app --query 'sort_by(imageDetails,&imagePushedAt)[-1].{tags:imageTags,digest:imageDigest,pushed:imagePushedAt}'
```

### 6.7 Branch protection + required checks

**Settings → Rules → Rulesets → New ruleset → New branch ruleset**:

- Name: `protect-master` · Enforcement: **Active** · Target branches: **Include default branch**.
- ✅ **Require a pull request before merging** (approvals حسب الفريق).
- ✅ **Require status checks to pass** → Add checks: `Pint (code style)`، `Tests (sqlite)`، `Tests (mysql)`، `Hadolint`، `Build · scan · (push)` (والـ jobs بتاعة `lab-integration.yml` لو عايز).
- ✅ **Block force pushes**.

(الطريقة الكلاسيك: **Settings → Branches → Add branch protection rule**.)

> 💡 **ليه الـ `pull_request` في `ci.yml` من غير paths filter؟** لو كان عليه `paths-ignore`، PR بيعدّل `docs/**` بس كان هيخلّي `ci.yml` ميشتغلش → الـ checks المطلوبة عمرها ما تتبعت → الـ PR يفضل "Expected — Waiting for status to be reported" للأبد. عشان كده الـ filter على الـ `push` بس. الحلول التانية المعروفة: job "gate" خفيف دايماً بيجري ويبقى هو الـ required (وجواه يقرر هل يعمل الشغل التقيل)، أو متخليش الـ workflow ده required. خلي بالك إن `lab-integration.yml` و `lint-infra.yml` ليهم paths filter على الـ `push` بس كمان (الـ `pull_request` من غير filter)، فممكن تضيف jobs منهم للـ required.

### 6.8 `lab-integration.yml` — كل step بيثبت إيه

| Job / step | بيثبت إيه |
|---|---|
| Build ci-v1 + ci-v2 | الـ Dockerfile بيتبني، والـ cache بيخلي التاني سريع (نفس الكود، release id مختلف) |
| Start app + MySQL (`--wait`) | الـ healthchecks و `depends_on: service_healthy` شغالين |
| Migrate and seed | الـ migrations بتجري على MySQL حقيقي من جوه الـ image + الـ seeders |
| Smoke tests | `/up`، `/ready` (status + version)، `/sre-lab/ping`، `/sre-lab/db/heavy`، `/metrics` (`app_info{version="ci-v1"`)، `/sre-lab/error?rate=1&code=503` = 503 |
| Real login flow | CSRF token + session في MySQL + redirect 302 + صفحة `/students` فيها logout |
| k6 smoke / load | الـ SLO thresholds معدّية (الـ job بيفشل لو اتكسرت) |
| Drills | `SRE_LAB_ENABLED=false` → 404؛ `SRE_FAULT_UNHEALTHY` → `/up` 500 و `/ready` 503؛ `SRE_FAULT_BOOT_FAIL` → الـ container مش بيقوم |
| Zero-downtime | init → blue/green → rollback → rolling → canary (promote) → canary سيء (abort، exit 2) → A/B → shadow، كل واحدة بـ probe و 0 failures ([23](23-bluegreen-single-host.md)–[26](26-ab-testing-shadow-feature-flags.md)) |

و [`lint-infra.yml`](../../../.github/workflows/lint-infra.yml): ShellCheck لكل `*.sh`، actionlint، `docker compose config` للـ 3 compose files، Terraform fmt/validate/tflint/checkov (soft fail)، ansible-lint، helm lint + kubeconform، packer validate.

## 7) التحقق (Verify)

```bash
gh run list --workflow=ci.yml --limit 5
gh run view <RUN_ID>                                   # الـ jobs وحالتها
gh run download <RUN_ID> -n sbom && jq '.packages | length' sbom.spdx.json
aws ecr describe-images --repository-name student-app --image-ids imageTag=<SHA7>
aws iam get-role --role-name student-app-gha-ci --query Role.AssumeRolePolicyDocument
```

المفروض: كل الـ jobs خضرا (الـ audit ممكن أحمر ومسموح)، الـ image في ECR بالـ SHA بتاع الـ commit، والـ trust policy فيها `aud` و `sub` محددين.

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر/التعديل (في branch تجريبي) | المتوقع |
|---|---|---|
| Test بيفشل | `$this->assertTrue(false);` في أي test | `test` أحمر → `image` **skipped** (بسبب `needs`) |
| Code style | سيب مسافات زيادة في ملف PHP | `pint --test` يفشل ويوريك الملف |
| `sub` مش مطابق | غيّر الـ trust policy لـ `refs/heads/release` | `Not authorized to perform sts:AssumeRoleWithWebIdentity` |
| من غير `id-token: write` | شيلها من الـ `image` job | الـ action مش قادر يجيب OIDC token (credentials could not be loaded) |
| Re-run لنفس الـ SHA | `gh run rerun <RUN_ID>` على `master` | الـ job أخضر والـ summary بيقول `already exists (immutable) - push skipped`. جرّب تشيل `ecr:DescribeImages` من الـ policy → الـ re-run هيقع بـ `ImageTagAlreadyExistsException` (الـ immutability نفسها شغالة) |
| Trivy gate | `exit-code: "1"` | يفشل لو فيه CRITICAL/HIGH ليها fix |

## 9) الرجوع (Rollback)

- الـ CI نفسه: `git revert <SHA>` → push → CI جديد. الـ images القديمة لسه في ECR بالـ SHA بتاعها.
- job فشل بسبب flake: `gh run rerun <RUN_ID> --failed`.
- لو role اتسرّب أو اتعمله misuse: شيل الـ trust (أو الـ role كله) — مفيش keys تعملها rotate، وده ميزة OIDC.

## 10) المسح (Teardown) ⚠️

```bash
aws ecr list-images --repository-name student-app --query 'imageIds[].imageTag'
aws ecr batch-delete-image --repository-name student-app --image-ids imageTag=<TEST_TAG>
```

الـ OIDC provider والـ roles مجانيين — سيبهم (السيناريوهات الجاية محتاجاهم). لو عملتهم من الـ Console وهتستخدم الـ bootstrap بعدين: امسحهم أو اعملهم `terraform import`. الـ ECR lifecycle policy بتنضّف القديم.

## 11) التكلفة (Cost)

| Resource | السعر التقريبي (راجع صفحة الأسعار) |
|---|---|
| GitHub Actions | مجاني للـ public repo؛ الـ private عنده دقائق شهرية مجانية |
| GitHub Actions cache (`type=gha`) | مجاني في حدود الـ quota الافتراضية للـ repo (~10 GB) |
| ECR storage | ~$0.10/GB/شهر |
| IAM / OIDC / STS | مجاني |
| GHCR | مجاني للـ public packages |

## 12) أسئلة Interview

<details><summary>اشرح OIDC بين GitHub Actions و AWS من أوله لآخره.</summary>

الـ job (بـ `id-token: write`) بيطلب JWT من GitHub OIDC provider فيه claims (`iss`، `aud=sts.amazonaws.com`، `sub=repo:owner/repo:ref:...`، `repository`، `ref`، `environment`...). الـ action بيبعته لـ `sts:AssumeRoleWithWebIdentity`. AWS بيتحقق من التوقيع (الـ IdP المسجّل في IAM) ومن الـ trust policy conditions، ويرجّع credentials مؤقتة (ساعة افتراضياً). مفيش secret متخزّن، والـ credentials مربوطة بـ repo/branch/environment معين.

</details>

<details><summary>ليه "build once, deploy many"؟ وإزاي `ci.yml` بيطبّقها؟</summary>

عشان اللي اتعمله test و scan هو بالظبط اللي يشتغل (نفس الـ digest)، من غير "rebuild" ممكن يجيب dependencies مختلفة. في `ci.yml` الـ image بتتبني مرة بـ `load: true`، وعليها نفس الـ smoke و Trivy و SBOM، وبعدين **نفس** الـ image بتتعمل tag و push. الـ CD ([32](32-cd-ec2-ecr-ssm.md)) بيعمل pull بالـ SHA بس.

</details>

<details><summary>ليه tests على SQLite و MySQL مع بعض؟</summary>

SQLite بيدّي feedback سريع ومن غير services، بس بيخبّي فروقات: strict mode، `ALTER TABLE ... MODIFY` (`->change()`)، الـ collations، الـ JSON functions، الـ locking. MySQL هو الـ production engine، فالـ leg ده بيمسك الـ migrations والـ queries اللي هتقع هناك. الـ matrix بـ `fail-fast: false` عشان تشوف الاتنين.

</details>

<details><summary>إزاي تحمي الـ role من forks و PRs؟</summary>

الـ trust policy على `sub` لـ branches محمية بس (`ref:refs/heads/master`) أو environment عليه required reviewers. الـ PRs من forks مش بتاخد `id-token` افتراضياً، وحتى لو، الـ `sub` بتاعها `pull_request` فمش هيطابق. ومتستخدمش `pull_request_target` مع checkout لكود الـ PR — ده بالظبط الـ vector اللي فتح اختراق Trivy في مارس 2026.

</details>

<details><summary>required checks مع path filters — إيه المشكلة وإيه الحل؟</summary>

لو الـ workflow مش بيجري (بسبب `paths-ignore`)، الـ check المطلوب مش بيتبعت، والـ PR بيفضل مستني للأبد. الحلول: تشيل الـ filter من الـ `pull_request` (اللي عملناه في `ci.yml` — الـ filter فاضل على الـ `push` بس عشان نوفر دقائق)، أو workflow دايماً بيجري بـ job "gate" خفيف بيقرر جوه هل يعمل الشغل التقيل، أو تختار checks مطلوبة بتجري دايماً.

</details>

<details><summary>الـ audit report-only — مش ده خطر؟</summary>

خطر لو محدش بيتابعه. البديل الأسوأ إن الـ gate يمنع كل release بسبب advisory قديمة ملهاش fix فالفريق يقفله خالص. الحل الوسط: report-only + Dependabot alerts و PRs، و gate على CRITICAL جديدة أو على قائمة allowlist بتاريخ انتهاء، ومراجعة دورية ([82](82-supply-chain-security.md)).

</details>

<details><summary>إمتى CodeBuild بدل GitHub Actions؟</summary>

لما محتاج الـ build جوه الـ VPC (يوصل لموارد private)، أو compute كبير/ARM/GPU بالدقيقة من غير ما تدير runners، أو compliance بيطلب إن الـ build يحصل جوه حسابك، أو كـ managed self-hosted runners لـ GitHub Actions. غير كده GitHub Actions أبسط والـ ecosystem أوسع ([35](35-aws-codebuild.md)).

</details>

## 13) Checklist

- [ ] عملت الـ OIDC provider والـ role من الـ Console (أو فهمت الخطوات) وكتبت الـ trust policy بـ `aud` و `sub`
- [ ] عملت/راجعت الـ bootstrap stack وخدت `github_ci_role_arn` و `ecr_repository_url`
- [ ] ضبطت الـ repo variables
- [ ] الـ CI عدّى والـ image وصلت ECR بالـ SHA
- [ ] فعّلت ruleset بـ required checks وفهمت مشكلة الـ path filters
- [ ] جرّبت الـ break-it (sub غلط، re-run immutable)
- [ ] قريت `lab-integration.yml` وعارف كل step بيثبت إيه
