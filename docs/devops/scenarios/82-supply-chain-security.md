# 82 — Supply chain security (Trivy، SBOM، cosign، Dependabot، checkov)

> **الهدف في سطر:** تفهم الـ software supply chain (source → dependencies → build → artifact → deploy) والهجمات عليها، تقرا كل أداة متركبة في الـ repo (Trivy والـ pin بالـ SHA بعد حادثة مارس 2026، SBOM، ECR scan on push، Dependabot، hadolint/shellcheck/actionlint/tflint/checkov)، تعرف تعمل triage وإصلاح لـ `composer audit`/`npm audit` (اللي لسه report-only)، وتحط خطة cosign + verification policy و SLSA levels.
> **المستوى:** Advanced · **الوقت:** ~4 ساعات · **التكلفة التقريبية:** مجاني
> **بيعتمد على:** [11](11-image-hardening.md) · [30](30-ci-github-actions.md) · **الملفات في الـ repo:** [`.github/workflows/ci.yml`](../../../.github/workflows/ci.yml) · [`.github/workflows/lint-infra.yml`](../../../.github/workflows/lint-infra.yml) · [`.github/dependabot.yml`](../../../.github/dependabot.yml) · [`bootstrap/ecr.tf`](../../../infra/terraform/bootstrap/ecr.tf) · [`docker/Dockerfile`](../../../docker/Dockerfile) · [`composer.json`](../../../composer.json) · [`package.json`](../../../package.json)

## 1) الفكرة (Concepts)

الـ supply chain = كل حاجة بتدخل الـ artifact اللي بيوصل production من غير ما تكتبها انت: packages (Composer/npm)، الـ base image (`serversideup/php`، `node:22-alpine`)، الـ GitHub Actions اللي الـ CI بيشغّلها، الـ build system نفسه، والـ registry. الهجمات الحقيقية: package خبيث/typosquatting، maintainer اتخترق، **CI action اتخترق** (Trivy — مارس 2026)، build server اتخترق (SolarWinds)، image اتبدّلت في الـ registry.

| المصطلح | المعنى |
|---|---|
| SCA | Software Composition Analysis: CVEs في الـ dependencies (Trivy، `composer audit`، `npm audit`، Dependabot alerts) |
| SBOM | قايمة بكل component ونسخته (SPDX / CycloneDX) — عشان لما CVE جديد يطلع تعرف أنت متأثر في ثواني |
| Provenance | شهادة موقّعة "الـ artifact ده اتبنى من commit كذا بـ workflow كذا على builder كذا" |
| Signing | توقيع الـ image digest (cosign keyless بـ OIDC → Fulcio cert + Rekor log) |
| Admission policy | الـ cluster/الـ deploy يرفض image مش موقعة من identity معينة |
| Pinning | تثبيت نسخة لا تتغير: **commit SHA** للـ actions، **digest** للـ images، lockfiles للـ packages |
| IaC scanning | checkov/tflint بيلاقوا misconfigurations قبل الـ apply |

### 1.1 SLSA levels (build track)

| Level | المعنى | فين احنا |
|---|---|---|
| L0 | مفيش ضمانات | — |
| L1 | فيه provenance (حتى لو مش موقّع) والـ build scripted | قريب: الـ build scripted في `ci.yml`، والـ SBOM موجود — بس مفيش provenance attestation |
| L2 | build على hosted platform والـ provenance **موقّع** من الـ platform | ممكن بسهولة: `docker buildx --provenance=mode=max` أو `actions/attest-build-provenance` على GitHub-hosted runner |
| L3 | build معزول ومقوّى، الـ provenance مش قابل للتزوير من الـ build steps نفسها | reusable workflow معزول + GitHub artifact attestations / SLSA generator |

(الـ spec بيتطور — النسخ الأحدث ضافت tracks تانية؛ راجع slsa.dev.)

## 2) المعمارية (Architecture)

```text
 Source (GitHub)            Dependencies                 Build (ci.yml / lint-infra.yml)                Registry / Deploy
 ─────────────              ─────────────                ──────────────────────────────                 ─────────────────
 branch ruleset             composer.lock / package-lock  Pint · tests · audit (report-only)            ECR student-app
 secret scanning            Dependabot weekly:            hadolint · shellcheck · actionlint            IMMUTABLE tags
 push protection             composer · npm ·             compose config · tf fmt/validate/tflint       scan_on_push (basic)
 Dependabot alerts           github-actions · docker ·    checkov (soft_fail)                           lifecycle 30 images
                             terraform                    buildx (load) → smoke → Trivy (exit 0)        (تمرين) cosign sign @digest
                                                          → SBOM (SPDX artifact) → OIDC → ECR push      deploy: cosign verify /
                                                                                                         Kyverno / policy-controller
```

## 3) المتطلبات (Prerequisites)

- [ ] [11](11-image-hardening.md) و [30](30-ci-github-actions.md) (الـ CI شغال والـ image بتوصل ECR).
- محلياً (اختياري — أو سيبهم للـ CI): `composer`، `npm`، `trivy`، `syft`، `grype`، `cosign`، `hadolint`، `shellcheck`، `actionlint`، `tflint`، `checkov`.

## 4) الطريقة الأولى: Console (GitHub + AWS)

### 4.1 GitHub

1. **Settings → Code security**: Dependabot **alerts** + **security updates**، **Secret scanning** + **Push protection**، و (للـ public repos) **Code scanning** (CodeQL default setup).
2. **Security → Dependabot**: اقرا الـ alerts — كل واحد فيه الـ advisory، الـ affected range، والـ patched version.
3. **Settings → Actions → General**: "Allow actions" → اختار **Allow select actions** أو على الأقل اتأكد من الـ policy؛ و **Workflow permissions** = Read repository contents (الـ workflows هنا بتحدد `permissions` بنفسها). وفيه option تفرض SHA pinning للـ actions على مستوى الـ repo/org في إعدادات GitHub الحديثة — شوفه في نفس الصفحة.
4. **Releases (لو بتنشر actions/أدوات):** فعّل **immutable releases** — ده اللي حمى tag `0.35.0` بتاع trivy-action في مارس 2026.

### 4.2 ECR scanning

1. **ECR → Private registry → Settings → Scanning**: Basic (scan on push) — الـ bootstrap بيحط `scan_on_push = true` على الـ repo. **Enhanced** (Amazon Inspector): continuous re-scan لما CVEs جديدة تطلع للـ images اللي في الـ registry (مدفوع).
2. **Repositories → student-app → image** → **Vulnerabilities**: قارن بتقرير Trivy.

```bash
aws ecr describe-image-scan-findings --repository-name student-app --image-id imageTag=<SHA7> \
  --query 'imageScanFindings.findingSeverityCounts'
```

## 5) الطريقة التانية: as Code — كل أداة في الـ repo

### 5.1 Trivy ([`ci.yml`](../../../.github/workflows/ci.yml) job `image`)

```yaml
- name: Trivy (OS + PHP/npm packages)
  uses: aquasecurity/trivy-action@0.36.0   # >= 0.35.0: earlier tags were hit by the March 2026 supply-chain compromise
  with: { image-ref: ${{ env.IMAGE }}, format: table, severity: CRITICAL,HIGH, ignore-unfixed: true, exit-code: "0" }
```

- بيفحص نفس الـ image اللي اتبنت مرة واحدة (`load: true`) **قبل** الـ push.
- `ignore-unfixed: true`: CVEs ملهاش fix مش هتفيدك في gate (مفيش حاجة تعملها غير تغيير الـ base).
- `exit-code: "0"` = report-only. الـ gate = `"1"` (يمكن على CRITICAL بس الأول).

**حادثة مارس 2026 باختصار** (التفاصيل في [11 §5.4](11-image-hardening.md)): مهاجمين استخدموا credentials اتسرقت (عن طريق workflow فيه `pull_request_target`) وعملوا force-push لتقريباً كل tags بتاعة `aquasecurity/trivy-action` و `setup-trivy` لـ commits فيها infostealer بيسرق secrets الـ pipeline قبل ما Trivy الحقيقي يجري. اللي كان عامل `@0.33.0` أو `@master` اتسرق منه. الدرس: **الـ tag مؤشر متحرك**؛ الحماية = **full commit SHA**:

```bash
git ls-remote --tags https://github.com/aquasecurity/trivy-action | grep -E 'refs/tags/0\.36\.0(\^\{\})?$'
```

```yaml
- uses: aquasecurity/trivy-action@<FULL_40_CHAR_SHA>   # 0.36.0
```

**حالة الـ repo دلوقتي:** trivy-action متثبت بـ **tag** (`@0.36.0`)، وباقي الـ actions بـ major tags: `actions/checkout@v6`، `docker/build-push-action@v7`، `anchore/sbom-action@v0` (أوسع واحد)، `aws-actions/configure-aws-credentials@v6`، `grafana/setup-k6-action@v1`، `bridgecrewio/checkov-action@v12`... الأدوات اللي بتتنزل بـ `curl` بقت متثبتة بنسخة: kubeconform `v0.6.7` (`KUBECONFORM_VERSION` في `lint-infra.yml` — Dependabot مش شايفها، الـ bump يدوي) و k6 `2.4.0` في كل الـ workflows (`lab-integration.yml`، `perf-gate.yml`، `observability-lint.yml`). التمرين (لسه **مش** متعمل): حوّل الـ actions لـ SHA + comment بالنسخة (Dependabot `github-actions` بيعرف يحدّث الـ SHA ويحافظ على الـ comment)، وضيف `sha256sum -c` لتنزيل kubeconform (النسخة متثبتة بس الـ checksum مش متحقق منه). ولو workflow جري بـ tag مخترق: **rotate كل secret كان متاح للـ job** — و OIDC بيقلل الضرر (مفيش AWS keys طويلة العمر).

### 5.2 SBOM

`anchore/sbom-action@v0` → `sbom.spdx.json` → artifact `sbom`:

```bash
gh run download <RUN_ID> -n sbom
jq '.packages | length' sbom.spdx.json
jq -r '.packages[] | select(.name=="laravel/framework") | .versionInfo' sbom.spdx.json
grype sbom:./sbom.spdx.json --only-fixed                # scan من الـ SBOM من غير الـ image
```

الـ SBOM كـ artifact بيعيش 90 يوم (default retention للـ artifacts). الأحسن: attestation مربوطة بالـ image نفسها في الـ registry (`docker buildx build --sbom=true --provenance=mode=max` أو `cosign attest --type spdxjson`)، ومنصة زي Dependency-Track تعمل re-check مستمر.

### 5.3 cosign + verification policy (تصميم — مش في `ci.yml`)

الإضافة بعد الـ push في الـ job `image` (عنده `id-token: write` أصلاً) — [11 §5.6](11-image-hardening.md):

```yaml
- uses: sigstore/cosign-installer@<FULL_40_CHAR_SHA>
  if: steps.ecr.outcome == 'success'
- name: Sign image (keyless)
  if: steps.ecr.outcome == 'success'
  env: { REPO: "${{ steps.ecr.outputs.registry }}/${{ vars.ECR_REPOSITORY || 'student-app' }}" }
  run: |
    DIGEST=$(docker inspect --format '{{index .RepoDigests 0}}' "$REPO:${{ steps.vars.outputs.sha }}" | cut -d@ -f2)
    cosign sign --yes "$REPO@$DIGEST"
```

**Policy (الفكرة):** "مفيش deploy لأي image غير لو موقّعة بـ identity الـ workflow `ci.yml` على `master`/`main` من الـ repo ده":

```bash
cosign verify <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/student-app@sha256:<DIGEST> \
  --certificate-identity-regexp '^https://github.com/Ahmed-Reda-Ragab/StudentHub/\.github/workflows/ci\.yml@refs/heads/(master|main)$' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

فين تفرضها: **EKS** → Kyverno `verifyImages` أو Sigstore policy-controller (admission — بيرفض الـ pod)؛ **ECS/EC2** → مفيش admission، فالـ verify يبقى step في الـ deploy workflow قبل `update-service`/`put-parameter` (والـ deploy role ميقدرش يتخطاه — أو AWS Signer/Notation كبديل AWS-native). ودايماً بالـ **digest** مش الـ tag.

### 5.4 Dependabot ([`.github/dependabot.yml`](../../../.github/dependabot.yml))

| Ecosystem | Directory | الجدول | Groups |
|---|---|---|---|
| `composer` | `/` | weekly (sunday) | `laravel-and-symfony` (`laravel/*`، `symfony/*`)، `php-other` (`*`)، `open-pull-requests-limit: 5` |
| `npm` | `/` | weekly | `frontend` (`*`) |
| `github-actions` | `/` | weekly | `actions` (`*`) |
| `docker` | `/docker` | weekly | — |
| `terraform` | `/infra/terraform/bootstrap`، `/infra/terraform/stacks/*`، `/infra/terraform/modules/*` | weekly | `terraform` (`*`) |

- الـ groups = PRs أقل (PR واحد لكل group في الأسبوع) والـ CI + `lab-integration` بيتحقق من كل bump.
- ملاحظات: الـ `terraform` بيغطي الـ bootstrap والـ stacks (الـ lock files) والـ modules (الـ provider constraints في `versions.tf`)؛ والـ `docker` ecosystem بيقرا سطور `FROM` — الـ Dockerfile بيستخدم `FROM ${PHP_IMAGE}` مع `ARG PHP_IMAGE=serversideup/php:8.3-fpm-nginx-alpine-v5.0.5`، فاتأكد إن Dependabot فعلاً بيفتح PRs للـ base image (لو لأ، حدّثه يدوي أو استخدم Renovate بـ regex manager).
- Security updates (من الـ alerts) بتيجي PRs منفصلة بغض النظر عن الجدول.

### 5.5 Linters ([`lint-infra.yml`](../../../.github/workflows/lint-infra.yml) + hadolint في `ci.yml`)

| Job | الأداة | بيمسك إيه | Gate؟ |
|---|---|---|---|
| `dockerfile-lint` (ci.yml) | `hadolint/hadolint-action@v3.1.0` (`failure-threshold: error`) | Dockerfile anti-patterns (unpinned packages، `ADD` من URL، root...) | errors بس |
| `shell` | `shellcheck -x -S warning` على كل `git ls-files '*.sh'` | quoting، `set -e` traps، word splitting | ✅ |
| `actionlint` | `rhysd/actionlint:1.7.7` | expressions غلط، **script injection** (`${{ github.event.* }}` جوه `run:`)، shellcheck جوه `run:` | ✅ |
| `compose` | `docker compose config -q` لكل compose file | syntax/interpolation | ✅ |
| `terraform` | `fmt -check`، `validate` (من غير backend)، `tflint --recursive` (config `infra/terraform/.tflint.hcl`، `--minimum-failure-severity=error`) | format، types، provider-specific mistakes | ✅ |
| `terraform` | `bridgecrewio/checkov-action@v12` (`soft_fail: true`) | misconfigurations (S3 من غير logging، SG مفتوحة، RDS من غير deletion protection...) | ❌ report |
| `ansible` / `kubernetes` / `packer` | ansible-lint (`--profile=production`)، helm lint + kubeconform، packer validate | | ✅ (لو الـ dirs موجودة) |

**الـ checkov findings المتوقعة** (soft fail مقصود): كتير منها **قرارات lab** — RDS `deletion_protection = false`/`skip_final_snapshot = true`، ALB من غير access logs/WAF، ECR AES256 مش KMS، SNS من غير encryption (مكتوب في الكود ليه: CloudWatch alarms مش بتقدر تنشر لـ topic مشفّر بالـ AWS-managed key)، public subnets من غير NAT. الصح: suppression **في الكود** جنب الـ resource بسبب مكتوب:

```hcl
resource "aws_sns_topic" "alerts" {
  #checkov:skip=CKV_AWS_26:CloudWatch alarms cannot publish to a topic encrypted with aws/sns (CMK = 1 USD/month); lab choice
  name = "${var.name}-alerts"
}
```

(راجع الـ check ID الفعلي من تقرير checkov قبل ما تكتبه.) بعد ما الـ findings تبقى كلها مُبررة أو متصلحة → شيل `soft_fail`.

### 5.6 `composer audit` / `npm audit` — triage وإصلاح

في `ci.yml` الـ job `audit` بـ `continue-on-error: true` (والـ steps كمان): advisories موجودة حالياً في الـ dependencies، ومش لازم تمنع كل delivery — بس لازم تتعالج. الخطوات:

```bash
# 1) الصورة
composer audit --locked --format=table              # من الـ lock (اللي بيتعمله deploy فعلاً)
composer audit --locked --format=json > /tmp/composer-audit.json
npm audit --audit-level=high
npm audit --json > /tmp/npm-audit.json

# 2) لكل advisory: مين جايبه؟ direct ولا transitive؟ prod ولا dev؟
composer why <vendor/package>                       # مين بيطلبه
composer show <vendor/package> --all | head -20     # النسخ المتاحة
npm ls <package>                                    # الشجرة
```

أسئلة الـ triage:
1. **Reachable؟** الكود المصاب بيتنفذ فعلاً؟ (dev-only زي أدوات الـ testing مش بيوصل الـ image — الـ Dockerfile بيعمل `composer install --no-dev`؛ و npm بيُستخدم في stage الـ `assets` بس، والـ runtime مفيهوش `node_modules`.) بس الـ build-time برضه supply chain (package خبيث في `npm ci` بيجري وقت الـ build).
2. **فيه fix؟** patched version في نفس الـ major؟
3. **الـ severity في سياقنا** (CVSS لوحده مش كفاية).

الإصلاح:

```bash
git switch -c fix/deps-audit
composer update <vendor/package> --with-dependencies     # أضيق تغيير ممكن (مش composer update لكل حاجة)
# لو محتاج major جديد: composer require <vendor/package>:^<NEW_MAJOR> وراجع الـ changelog
php artisan test --compact && vendor/bin/pint --test
composer audit --locked

npm audit fix                                            # من غير --force (الـ force بيعمل major bumps)
npm ls <package>; npm run build
git add composer.lock package-lock.json && git commit -m "fix(deps): patch <advisories>"
gh pr create --fill                                      # CI + lab-integration بيتحققوا
```

- **Composer ≥ 2.9** بقى بيمنع (`audit.block-insecure`، default true) الـ resolution لنسخ عليها advisories وقت `update`/`require` — يعني ممكن `composer update` يرفض نسخة معينة ويقولك ليه. في 2.10 الـ settings دي اتنقلت لـ `policy.*` (مثلاً `policy.advisories.block`). متقفلهاش globally؛ لو advisory مش reachable ومفيش fix: `audit.ignore` في `composer.json` بالـ ID + سبب، وراجعه دورياً.
- **npm**: transitive ملوش fix في الـ parent → `overrides` في `package.json` بنسخة patched (وجرّب الـ build).
- لما `composer audit` و `npm audit --audit-level=high` يبقوا نضاف: شيل `continue-on-error` → الـ audit يبقى **gate**؛ أو gate على advisories **جديدة** بس (مقارنة بـ baseline).

## 6) الـ Deploy

```bash
# كل حاجة على GitHub Actions (من غير tools محلي)
gh workflow run ci.yml --ref devops-lab
gh workflow run lint-infra.yml --ref devops-lab
gh run watch
gh run view <RUN_ID> --log | grep -A30 "Trivy\|composer audit\|npm audit" | head -80
gh run view <RUN_ID> --log | grep -i "checkov" -A40 | grep -E "Check:|FAILED|PASSED" | head -40

# محلياً (WSL) — نفس الأدوات
docker run --rm -i hadolint/hadolint hadolint --failure-threshold error - < docker/Dockerfile
shellcheck -x -S warning $(git ls-files '*.sh')
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:1.7.7 -color
trivy image --severity HIGH,CRITICAL --ignore-unfixed student-app:local
trivy config infra/terraform                          # IaC scan بديل/مكمّل لـ checkov
docker run --rm -v "$PWD/infra/terraform:/tf" bridgecrew/checkov -d /tf --framework terraform --compact --quiet
```

## 7) التحقق (Verify)

```bash
gh api repos/Ahmed-Reda-Ragab/StudentHub/dependabot/alerts --jq '.[] | select(.state=="open") | "\(.security_advisory.severity) \(.dependency.package.name)"' | sort | uniq -c
gh pr list --author app/dependabot
grep -rhoE 'uses: [^ ]+@[^ ]+' .github/workflows | sort | uniq -c | sort -rn      # مين لسه بـ tag مش SHA
aws ecr describe-repositories --repository-names student-app --query 'repositories[0].[imageTagMutability,imageScanningConfiguration.scanOnPush]'
```

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | التعديل (branch تجريبي) | المتوقع |
|---|---|---|
| Trivy gate | `exit-code: "1"` | الـ job يقع لو فيه HIGH/CRITICAL ليها fix — والـ push لـ ECR مش هيحصل |
| Script injection | step فيه `run: echo "${{ github.event.pull_request.title }}"` | actionlint يعلّم عليه (untrusted input جوه `run:`) — الصح: `env:` ثم `"$TITLE"` (زي `perf-gate.yml`) |
| Shell bug | سكريبت فيه `rm -rf $DIR/` من غير quotes | shellcheck SC2086 |
| Unpinned apk | `RUN apk add curl` في الـ Dockerfile | hadolint DL3018 (warning — الـ job ينجح لأن الـ threshold = error) |
| IaC misconfig | SG فيه `0.0.0.0/0` على 22 | checkov finding (soft fail) — جرّب تشيل `soft_fail` |
| Dependency vuln | `composer require <package>:<OLD_VULNERABLE_VERSION>` | `composer audit` بيطلّعه (و Composer ≥ 2.9 ممكن يرفض الـ require أصلاً) |
| Tag اتغيّر | (فكّر) action بـ `@v1` والـ maintainer اتخترق | الـ CI بيشغّل كود جديد من غير أي تغيير عندك — ده ليه SHA |

## 9) الرجوع (Rollback)

- Dependabot bump كسّر حاجة → revert للـ PR؛ الـ image القديمة في ECR بالـ SHA (immutable).
- Gate بيمنع release مستعجل → **متقفلش الـ gate**: `.trivyignore` بـ CVE محدد + سبب + تاريخ، أو `audit.ignore` بنفس المنطق، وreview.
- Action اتخترق → pin على SHA معروف كويس، rotate الـ secrets، اقرا الـ logs بتاعة الـ runs في الفترة.

## 10) المسح (Teardown) ⚠️

مفيش موارد. لو جرّبت Inspector enhanced scanning ارجع Basic (**ECR → Settings → Scanning**) — الـ enhanced بيتحاسب per image مفحوصة.

## 11) التكلفة (Cost)

| Resource | السعر التقريبي |
|---|---|
| Trivy، Syft، Grype، cosign، hadolint، shellcheck، actionlint، tflint، checkov | مجاني (OSS) |
| Dependabot، secret scanning (public repos)، CodeQL (public) | مجاني |
| ECR basic scanning | مجاني |
| ECR enhanced (Inspector) | per image scan — تقريبي، راجع صفحة الأسعار |
| Sigstore public good (Fulcio/Rekor) | مجاني |

## 12) أسئلة Interview

<details><summary>ليه تثبت GitHub Actions بالـ SHA مش بالـ tag؟</summary>

الـ tag (حتى `0.36.0`) مجرد pointer الـ maintainer — أو اللي سرق الـ credentials بتاعته — يقدر يحركه (`git push --force`). ده بالظبط اللي حصل لـ trivy-action في مارس 2026: tags اتنقلت لـ commits فيها infostealer. الـ full SHA immutable. Dependabot بيحدّث الـ SHA pins، و immutable releases على GitHub بتمنع تحريك الـ release tags.

</details>

<details><summary>SBOM بيفيد في إيه عملياً؟</summary>

لما CVE كبير يطلع (Log4Shell-style) بتسأل "أنهي images/releases فيها الـ package ده؟" وتجاوب في دقايق من الـ SBOMs بدل ما تعمل rebuild/scan لكل حاجة. وكمان licensing compliance، وبيدّي الـ scanners input ثابت (`grype sbom:…`). أقوى لما يبقى attestation موقّعة مربوطة بالـ digest.

</details>

<details><summary>Trivy في الـ CI و ECR scan on push — ليه الاتنين؟</summary>

Trivy قبل الـ push = gate (يمنع). ECR/Inspector بعد الـ push = monitoring مستمر: CVE اتنشر بعد ما الـ image اتبنت وهي شغالة في production — Trivy في الـ CI مش هيشوفه لأنه جري زمان. Enhanced scanning بيعمل re-scan أوتوماتيك.

</details>

<details><summary>الـ audit report-only — مش خطر؟ وإمتى تخليه gate؟</summary>

خطر لو محدش بيتابعه. البديل (gate من أول يوم على advisories قديمة ملهاش fix) بيخلي الفريق يقفل الأداة. الطريق: report-only + Dependabot + triage أسبوعي → إصلاح أو ignore موثّق بتاريخ → لما يبقى نضيف حوّله gate (أو gate على الجديد بس). ومع Composer ≥ 2.9 الـ resolution نفسه بيمنع نسخ insecure جديدة.

</details>

<details><summary>إزاي تضمن إن اللي بيشتغل في production هو اللي الـ CI بناه؟</summary>

Immutable tags + deploy بالـ digest، توقيع keyless (cosign) بـ identity الـ workflow، verification policy في الـ admission (Kyverno/policy-controller على EKS) أو step إجباري في الـ deploy pipeline، و provenance attestation (SLSA L2/L3). والـ registry write محصور في role الـ CI بس (OIDC `student-app-gha-ci` على main/master).

</details>

<details><summary>checkov طلّع 40 finding — تعمل إيه؟</summary>

Triage: صلّح الحقيقي (SG مفتوحة، encryption ناقص)، و suppress في الكود جنب الـ resource للقرارات المقصودة بسبب مكتوب (lab: deletion protection off، SNS من غير CMK). متعملش skip global للـ check. وبعد ما الـ baseline يبقى نضيف شيل `soft_fail` عشان أي misconfig جديد يقع في الـ PR.

</details>

## 13) Checklist

- [ ] قريت قصة trivy-action وحوّلت action واحد على الأقل لـ SHA (في branch)
- [ ] نزّلت الـ SBOM وعملت عليه `grype`
- [ ] عملت triage لـ `composer audit` و `npm audit` وصلحت advisory واحد بـ `composer update <pkg> --with-dependencies` + tests
- [ ] قريت تقرير checkov وكتبت suppression مُبرر واحد على الأقل
- [ ] فعّلت secret scanning + push protection + Dependabot alerts
- [ ] أقدر أشرح SLSA L1/L2/L3 وفين الـ repo منهم
- [ ] (اختياري) وقّعت image بـ cosign وعملت verify بالـ identity regexp
