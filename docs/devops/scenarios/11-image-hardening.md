# 11 — تقوية الـ image (non-root، الحجم، multi-arch، SBOM، Trivy، cosign)

> **الهدف في سطر:** تاخد الـ image بتاع [10](10-containerize-app.md) وتخليها production-grade: non-root متأكد منه، صغيرة ومفهومة layer بـ layer، amd64 + arm64 (Graviton)، متفحوصة بـ Trivy، معاها SBOM، وموقّعة بـ cosign (keyless)، وبتتحدّث بـ Dependabot.
> **المستوى:** Intermediate → Advanced · **الوقت:** ~4 ساعات · **التكلفة التقريبية:** مجاني (سنتات لو رفعت على ECR)
> **بيعتمد على:** [10 — تحويل التطبيق لـ container](10-containerize-app.md) · **الملفات في الـ repo:** [`docker/Dockerfile`](../../../docker/Dockerfile) · [`.github/workflows/ci.yml`](../../../.github/workflows/ci.yml) · [`.github/dependabot.yml`](../../../.github/dependabot.yml) · [`.dockerignore`](../../../.dockerignore)

## 1) الفكرة (Concepts)

الـ image هي أكتر artifact بيتنقل في الـ pipeline، وأي حاجة فيها (package قديم، root user، tag اتغيّر من ورا ضهرك) بتوصل الـ production. الـ hardening هنا 5 طبقات:

| الطبقة | السؤال | الأداة |
|---|---|---|
| Least privilege | الـ process بيجري بإيه؟ | `USER www-data` (82)، `cap-drop`، `no-new-privileges` |
| Minimal | إيه اللي جوه ومش محتاجه؟ | multi-stage، `.dockerignore`، `docker history` |
| Known vulns | فيه CVEs معروفة؟ | Trivy (في CI)، ECR scanning |
| Inventory | إيه اللي جوه بالظبط (لبكرة)؟ | Syft → SBOM (SPDX) |
| Provenance | الـ image دي اتبنت فين ومين بناها؟ | cosign keyless + GitHub OIDC، pin بالـ digest |

| المصطلح | المعنى |
|---|---|
| Digest | `sha256:...` = بصمة المحتوى — immutable بعكس الـ tag |
| Manifest list / index | image واحدة بكذا platform (amd64 + arm64) |
| SBOM | Software Bill of Materials: قايمة بكل package ونسخته |
| Keyless signing | توقيع بـ certificate قصير العمر من OIDC identity (Fulcio) + transparency log (Rekor) من غير مفتاح تحفظه |

## 2) المعمارية (Architecture)

```text
 ci.yml (job "image")
 checkout ─► buildx (cache gha) ─► load image ─► smoke test (/up, apcu, id)
                                         │
                                         ├─► Trivy (CRITICAL,HIGH, ignore-unfixed) — report-only الآن
                                         ├─► Syft (anchore/sbom-action) ─► sbom.spdx.json artifact
                                         └─► master/main: OIDC ─► ECR push :<sha7>  (IMMUTABLE)
                                                                       │
                                     (تمرين هنا) cosign sign @digest ◄──┘ ─► Rekor log
                                                                       │
                       deploy side: cosign verify / admission policy ◄─┘   (82)
 Dependabot (weekly): composer · npm · github-actions · docker(/docker) · terraform ─► PR ─► CI
```

## 3) المتطلبات (Prerequisites)

- [ ] [10](10-containerize-app.md) خلصان (الـ image بتتبني).
- [ ] اختياري محلياً: `trivy`، `syft`، `grype`، `cosign`، `hadolint`، `dive` — أو سيبهم للـ CI.
- [ ] اختياري: ECR repo `student-app` من الـ bootstrap stack ([30](30-ci-github-actions.md)) عشان تجرّب الـ multi-arch push والتوقيع.

## 4) الطريقة الأولى: AWS Console (يدوي) — ECR scanning

مش إجباري، بس مفيد تشوف رأي AWS في نفس الـ image:

1. **ECR → Private registry → Repositories → `student-app`** → اتأكد إن **Tag immutability = Immutable**.
2. **ECR → Private registry → Settings → Scanning** (الـ scanning configuration بقت على مستوى الـ registry): Basic scanning + **Scan on push** للـ repo (filter `student-app`). الـ **Enhanced scanning** (Amazon Inspector) بيعمل re-scan مستمر لما CVEs جديدة تطلع، وبيتحاسب.
3. افتح أي image tag → **Vulnerabilities** → قارن مع تقرير Trivy في الـ CI.
4. **Repositories → student-app → Lifecycle policy** → اتأكد إن فيه rule بتمسح الـ untagged/القديم (الـ bootstrap بيعملها).

> 💡 ليه scan في مكانين؟ Trivy في الـ CI بيمنع (لما يبقى gate) قبل الـ push. ECR/Inspector بيكتشف CVEs اتنشرت **بعد** ما الـ image اتبنت وهي شغالة.

## 5) الطريقة التانية: as Code

### 5.1 Non-root — اتأكد مش افترض

```bash
docker inspect --format 'User={{.Config.User}} Stop={{.Config.StopSignal}}' student-app:local
docker run --rm --entrypoint id student-app:local          # uid=82(www-data) gid=82(www-data)
```

الـ CI بيعمل نفس التأكيد في `docker exec smoke id`. وفي الـ runtime زوّد الطبقات اللي مش في الـ image نفسها:

```bash
APP_KEY=base64:$(openssl rand -base64 32)
docker run -d --name hardened -p 8080:8080 \
  --cap-drop ALL --security-opt no-new-privileges:true \
  -e APP_KEY="$APP_KEY" -e DB_CONNECTION=sqlite -e DB_DATABASE=/tmp/db.sqlite \
  -e SESSION_DRIVER=array -e CACHE_STORE=array \
  student-app:local
curl -fsS http://localhost:8080/up && docker rm -f hardened
```

> تمرين: جرّب تضيف `--read-only --tmpfs /tmp` وشوف إيه اللي بيفشل (logs الـ container هتقولك أنهي path محتاج write: `storage/`، `bootstrap/cache`، temp dirs بتاعة nginx). ده نفس اللي هتواجهه مع `readOnlyRootFilesystem: true` في K8s.

### 5.2 الحجم والـ layers

```bash
docker images student-app:local --format '{{.Repository}}:{{.Tag}} {{.Size}}'
docker history --no-trunc --format '{{.Size}}\t{{.CreatedBy}}' student-app:local | head -20
docker run --rm -it -v /var/run/docker.sock:/var/run/docker.sock wagoodman/dive student-app:local
```

اللي بيكبّر الـ image عادةً وإزاي اتعامل معاه عندنا:

| السبب | عندنا |
|---|---|
| node_modules و dev deps | stage `assets` منفصل؛ بس `public/build` بيتنقل؛ `--no-dev` |
| `COPY . .` بيجيب كل حاجة | `.dockerignore` بيشيل `tests`، `docs`، `infra`، `k8s`، `.git`... |
| ملفات بتتمسح في layer تانية | ممسوحة بس لسه في الـ layer القديمة — امسح في نفس الـ `RUN` |
| `chown -R` بعد الـ COPY | بيكرر الملفات في layer جديدة؛ إحنا بنستخدم `COPY --chown` |

### 5.3 Multi-arch (amd64 + arm64 لـ Graviton)

Graviton (`t4g`، `c7g`...) أرخص بـ ~20% لنفس الأداء تقريباً. الـ base images (`serversideup/php`، `node:22-alpine`، `mysql:8.4`، `nginx`) كلها multi-arch، و [`user-data.sh`](../../../deploy/ec2/user-data.sh) بيدعم `aarch64`.

```bash
docker buildx create --name multi --driver docker-container --use
docker run --privileged --rm tonistiigi/binfmt --install arm64     # QEMU لو جهازك amd64
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com
docker buildx build --platform linux/amd64,linux/arm64 \
  -f docker/Dockerfile \
  --build-arg APP_VERSION=$(git rev-parse --short HEAD) \
  -t <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/student-app:$(git rev-parse --short HEAD) \
  --push .
docker buildx imagetools inspect <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/student-app:$(git rev-parse --short HEAD)
```

في GitHub Actions: `docker/setup-qemu-action` + `platforms: linux/amd64,linux/arm64` في `build-push-action`، أو أسرع: build native على runner `ubuntu-24.04-arm` وادمج الـ manifests.

> ⚡ Trade-off: تحت QEMU الـ `install-php-extensions apcu` (compile) و `npm ci` بطيئين جداً. تحسين معروف (تمرين، مش متطبّق في الـ Dockerfile): الـ assets ناتجها JS/CSS مستقل عن المعمارية، فممكن stage الـ `assets` يجري على platform الـ builder:
> ```dockerfile
> FROM --platform=$BUILDPLATFORM ${NODE_IMAGE} AS assets
> ```
> بكده npm/vite بيجروا native مرة واحدة والناتج يتنسخ للـ arm64 والـ amd64.

### 5.4 Trivy — ولماذا الـ pin مهم بعد مارس 2026

```bash
trivy image --severity HIGH,CRITICAL --ignore-unfixed student-app:local
trivy image --severity CRITICAL --exit-code 1 --ignore-unfixed student-app:local   # كده يبقى gate
trivy image --scanners secret student-app:local                                  # أسرار اتنسيت جوه الـ image؟
trivy config docker/Dockerfile
```

في [`ci.yml`](../../../.github/workflows/ci.yml):

```yaml
- name: Trivy (OS + PHP/npm packages)
  uses: aquasecurity/trivy-action@0.36.0   # >= 0.35.0: earlier tags were hit by the March 2026 supply-chain compromise
  with: { image-ref: ..., severity: CRITICAL,HIGH, ignore-unfixed: true, exit-code: "0" }
```

**القصة باختصار:** يوم 19 مارس 2026 مهاجمين استخدموا credentials اتسرقت في اختراق سابق (أول مارس، عن طريق workflow فيه `pull_request_target`) وعملوا **force-push لكل tags تقريباً** بتاعة `aquasecurity/trivy-action` (76 من 77 حسب advisory بتاعة Aqua) وكل tags بتاعة `aquasecurity/setup-trivy`، لـ commits فيها **infostealer** بيجري كـ step قبل Trivy الحقيقي ويسرق secrets الـ pipeline، ومعاها release خبيثة من Trivy نفسه (v0.69.4). النافذة كانت حوالي 12 ساعة. الـ tag الوحيد اللي سلم كان `0.35.0` لأنه كان محمي بـ **immutable releases** بتاعة GitHub. (المصادر: GHSA-69fq-xp46-6x23، و CVE-2026-33634.)

الدرس: **الـ tag في GitHub Actions مؤشر قابل للتحريك**، مش نسخة. `@0.36.0` أحسن من `@master`، بس اللي بيحميك فعلاً هو الـ **full commit SHA**:

```bash
git ls-remote --tags https://github.com/aquasecurity/trivy-action | grep -E 'refs/tags/0\.36\.0(\^\{\})?$'
```

```yaml
- uses: aquasecurity/trivy-action@<FULL_40_CHAR_SHA>   # 0.36.0
```

Dependabot (ecosystem `github-actions` عندنا) بيعرف يحدّث الـ SHA pins ويحافظ على الـ comment بالنسخة. ولو workflow بتاعك جري بـ tag مخترق في النافذة: **rotate** كل secret كان متاح للـ job (GITHUB_TOKEN، registry، cloud credentials) — ميزة OIDC هنا إن مفيش AWS keys طويلة العمر تتسرق أصلاً.

> لاحظ إن باقي الـ actions في `ci.yml` متثبتة بـ major tags (`@v6`، `@v3`، و `anchore/sbom-action@v0` أوسعهم). تحويلهم لـ SHA تمرين في [82](82-supply-chain-security.md).

### 5.5 SBOM (Syft)

```bash
syft student-app:local -o spdx-json > sbom.spdx.json
syft student-app:local -o cyclonedx-json > sbom.cdx.json
jq '.packages | length' sbom.spdx.json
jq -r '.packages[] | select(.name=="laravel/framework") | .versionInfo' sbom.spdx.json
grype sbom:./sbom.spdx.json --only-fixed          # scan من الـ SBOM من غير الـ image
```

الـ CI بيعمل `anchore/sbom-action@v0` → `sbom.spdx.json` ويرفعه artifact اسمه `sbom`:

```bash
gh run download <RUN_ID> -n sbom
```

**SPDX ولا CycloneDX؟** الاتنين standards؛ SPDX أقدم وقوي في الـ licensing، CycloneDX أخف ومنتشر في أدوات الـ security. البديل الأحدث: `docker buildx build --sbom=true --provenance=mode=max` بيلزق الـ SBOM والـ provenance كـ **attestations** مع الـ image نفسها في الـ registry.

### 5.6 cosign — توقيع keyless بـ GitHub OIDC (تمرين، مش في `ci.yml` لسه)

الـ job `image` عنده أصلاً `id-token: write`. بعد خطوة الـ push، الإضافة هتبقى كده:

```yaml
- uses: sigstore/cosign-installer@<FULL_40_CHAR_SHA>   # pin by SHA
  if: steps.ecr.outcome == 'success'
- name: Sign image (keyless)
  if: steps.ecr.outcome == 'success'
  env:
    REPO: ${{ steps.ecr.outputs.registry }}/${{ vars.ECR_REPOSITORY || 'student-app' }}
  run: |
    DIGEST=$(docker inspect --format '{{index .RepoDigests 0}}' "$REPO:${{ steps.vars.outputs.sha }}" | cut -d@ -f2)
    cosign sign --yes "$REPO@$DIGEST"
```

- **دايماً وقّع وتحقّق بالـ digest** مش الـ tag.
- الـ certificate بيحتوي identity الـ workflow (`https://github.com/<owner>/<repo>/.github/workflows/ci.yml@refs/heads/master`) والـ issuer `https://token.actions.githubusercontent.com`.

التحقق (من جهازك أو قبل الـ deploy):

```bash
cosign verify <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/student-app@sha256:<DIGEST> \
  --certificate-identity-regexp '^https://github.com/Ahmed-Reda-Ragab/StudentHub/\.github/workflows/ci\.yml@refs/heads/(master|main)$' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
cosign tree <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/student-app@sha256:<DIGEST>
```

> ⚠️ ECR repo عندنا **IMMUTABLE**. النسخ اللي بتخزّن التوقيع كـ tag (`sha256-<digest>.sig`) ممكن تفشل لو حاولت توقّع نفس الـ digest مرتين. ECR بيدعم OCI referrers، والنسخ الحديثة من cosign بتستخدمها — اتأكد بـ `cosign tree` بعد أول توقيع. الفرض (enforcement) على الـ cluster (Kyverno / Sigstore policy-controller) في [82](82-supply-chain-security.md).

### 5.7 hadolint

```bash
docker run --rm -i hadolint/hadolint hadolint --failure-threshold error - < docker/Dockerfile
```

في الـ CI: `hadolint/hadolint-action@v3.1.0` بـ `failure-threshold: error` (الـ warnings بتظهر بس مش بتكسر). لو عندك سبب حقيقي تتجاهل rule: `# hadolint ignore=DL3018` فوق السطر مع comment بالسبب — مش تقفل الـ rule للملف كله.

### 5.8 تثبيت الـ base image وتحديثه

| الأسلوب | مثال | المميزات | العيوب |
|---|---|---|---|
| floating tag | `node:22-alpine` | بياخد security patches لوحده | الـ build مش reproducible؛ ممكن يتكسر فجأة |
| version tag | `serversideup/php:8.3-fpm-nginx-alpine-v5.0.5` | ثابت ومقروء | serversideup بيقول إن الـ version-pinned tags **مش بيتعملها rebuild** → مفيش OS patches لحد ما تعمل bump |
| digest | `...@sha256:<DIGEST>` | ثابت 100% وآمن ضد tag hijack | مش مقروء، ولازم bot يحدّثه |

الاستراتيجية الصح: **version tag (أو digest) + bot بيعمل bump أسبوعي + CI/lab-integration بيتحقق**. عندنا Dependabot `package-ecosystem: docker` على `directory: "/docker"`.

> ⚠️ الـ Dockerfile بيعرّف الـ images كـ `ARG PHP_IMAGE=...` و `FROM ${PHP_IMAGE}`. Dependabot بيدوّر على سطور `FROM`، ومش متأكد إنه بيحلّ الـ `ARG` defaults (لم أتحقق من دعمه للنمط ده). اتأكد إن أول PR بتاع docker وصل فعلاً؛ لو موصلش يا إما تكتب الـ image صريح في `FROM` وتسيب الـ `ARG` للـ override، يا إما تستخدم Renovate (بيفهم `ARG` defaults). ولاحظ إن آخر إصدار في changelog بتاع serversideup وقت كتابة الملف ده كان في خط `v5.1.x` بينما الـ repo على `v5.0.5`.

### 5.9 Alpine ولا Debian ولا distroless؟

| | Alpine (اللي عندنا) | Debian slim (`-bookworm`/`-trixie` variants) | Distroless / Chainguard |
|---|---|---|---|
| الحجم | الأصغر | أكبر | صغير جداً |
| libc | **musl** — فروقات DNS وأداء أحياناً، وبعض الـ extensions | glibc — أوسع توافق | glibc غالباً |
| shell للـ debug | موجود (`sh`) | موجود | **مفيش** — debug بـ ephemeral containers |
| CVEs | قليلة | أكتر (packages أكتر) | الأقل |
| مناسب لـ nginx + FPM + S6؟ | ✅ | ✅ | ❌ عملياً (محتاج supervisor و shell scripts) |

الخلاصة: لـ Laravel مع nginx+FPM في container واحد، Alpine/Debian من serversideup اختيار عملي. distroless بيكسب مع binaries static (Go) أو runtimes بـ process واحد.

## 6) الـ Deploy

```bash
docker build -f docker/Dockerfile --build-arg APP_VERSION=$(git rev-parse --short HEAD) -t student-app:local .
trivy image --severity HIGH,CRITICAL --ignore-unfixed student-app:local
syft student-app:local -o spdx-json > sbom.spdx.json
docker run --rm -i hadolint/hadolint hadolint --failure-threshold error - < docker/Dockerfile
```

من غير Docker محلي: اعمل push لـ `devops-lab` واقرا job **Build · scan · (push)** في `ci.yml`:

```bash
git push origin devops-lab
gh run list --workflow=ci.yml --limit 3
gh run view <RUN_ID> --log | grep -A40 "Trivy"
gh run download <RUN_ID> -n sbom
```

## 7) التحقق (Verify)

```bash
docker run --rm --entrypoint id student-app:local                         # uid=82
docker inspect --format '{{.Config.StopSignal}}' student-app:local          # SIGQUIT
docker inspect --format '{{json .Config.Labels}}' student-app:local | jq    # OCI labels (version/revision)
docker buildx imagetools inspect <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/student-app:<SHA7> | grep Platform
jq '.packages | length' sbom.spdx.json
```

المفروض: non-root، `SIGQUIT`، labels فيها الـ SHA، الـ manifest فيه `linux/amd64` و `linux/arm64`، والـ SBOM فيه مئات الـ packages.

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر | المتوقع |
|---|---|---|
| Trivy كـ gate | غيّر `exit-code: "0"` لـ `"1"` في branch تجريبي | الـ job يقع لو فيه CRITICAL/HIGH ليها fix — هتحس بضغط "مين يصلّح؟" وده نقاش 82 |
| Base image أقدم | `docker build -f docker/Dockerfile --build-arg PHP_IMAGE=serversideup/php:<OLDER_TAG> -t student-app:old .` ثم `trivy image student-app:old` | عدد CVEs أكبر — ده تمن عدم الـ bump |
| تشغيل كـ root | `docker run --rm --user 0 --entrypoint id student-app:local` | بيشتغل! الـ image non-root افتراضياً بس الـ runtime يقدر يغيّره — عشان كده `runAsNonRoot` في K8s |
| توقيع مزوّر | `cosign verify` على image تانية باسم نفس الـ repo بس digest مختلف | `no matching signatures` |
| hadolint warning | ضيف `RUN apk add curl` في branch | warning `DL3018` بس الـ job ينجح (threshold = error) |

## 9) الرجوع (Rollback)

- Dependabot bump كسّر حاجة؟ اعمل revert للـ PR — الـ image القديمة لسه في ECR بالـ SHA بتاعها (immutable)، والـ deploy بالـ tag القديم.
- Trivy gate بيمنع release مستعجل؟ متقفلش الـ gate؛ ضيف `.trivyignore` بـ CVE محدد + سبب + تاريخ انتهاء، واعمل review له.

## 10) المسح (Teardown) ⚠️

```bash
docker buildx rm multi
docker image rm student-app:old 2>/dev/null || true
aws ecr batch-delete-image --repository-name student-app --image-ids imageTag=<TEST_TAG>    # لو رفعت tags تجريبية
```

## 11) التكلفة (Cost)

| Resource | السعر التقريبي (راجع صفحة الأسعار) |
|---|---|
| ECR storage | ~$0.10/GB/شهر (multi-arch = نسختين من الـ layers) |
| ECR basic scanning | مجاني |
| Enhanced scanning (Inspector) | بالـ image scan — مفيد بس بيتحاسب |
| Rekor / Fulcio (Sigstore public) | مجاني |

## 12) أسئلة Interview

<details><summary>إيه الفرق بين pin بالـ tag و pin بالـ SHA في GitHub Actions، وإيه علاقته بحادثة Trivy؟</summary>

الـ tag مجرد pointer صاحب الـ repo (أو أي حد سرق credentials بتاعته) يقدر يحرّكه لـ commit تاني. في مارس 2026 المهاجمين عملوا force-push لتقريباً كل tags بتاعة `trivy-action` لـ commits بتسرق secrets، فأي workflow بيستخدم tag اتأثر من غير ما يتغيّر فيه سطر. الـ full SHA immutable — أسوأ حالة إنك متاخدش تحديث. ومع Dependabot بتاخد التحديثات كـ PRs بتعدّي على review و CI.

</details>

<details><summary>الـ image بتاعك non-root — ده كفاية؟</summary>

لأ. الـ runtime ممكن يغيّره (`--user 0`)، فلازم يتفرض في الـ orchestrator (`runAsNonRoot`، `runAsUser: 82`، `allowPrivilegeEscalation: false`، drop ALL capabilities، و `readOnlyRootFilesystem` لو أمكن). وكمان SG/NetworkPolicy، و IAM role بأقل صلاحيات للـ task/pod. الـ non-root بيقلل الـ blast radius، مش بيلغيه.

</details>

<details><summary>Trivy لقى 30 HIGH — هتعمل إيه؟</summary>

أفصل: كام منهم `fixed` فعلاً (`--ignore-unfixed`)، وفين (OS package من الـ base image؟ ولا composer/npm؟). الـ base image → bump. الـ app deps → `composer update <pkg>`. اللي ملوش fix أو مش reachable → `.trivyignore` موثّق بسبب وتاريخ مراجعة. وبعدين أحوّل الـ scan لـ gate على CRITICAL الأول (عشان مكسرش الـ delivery مرة واحدة) وأشدّها تدريجياً.

</details>

<details><summary>ليه SBOM لو بعمل scan أصلاً؟</summary>

الـ scan لحظي. الـ SBOM inventory دائم: لما CVE جديدة تطلع بكرة (Log4Shell-style) أقدر أعرف في دقايق أنهي images/releases فيها الـ library دي من غير ما أعيد build أو scan لكل حاجة. وكمان مطلوب compliance (SSDF، EO 14028) ولمراجعة الـ licenses.

</details>

<details><summary>إزاي keyless signing بيشتغل من غير مفتاح؟</summary>

الـ job بياخد OIDC token من GitHub، cosign بيبعته لـ Fulcio اللي بيدي certificate قصير العمر (دقايق) فيه identity الـ workflow. cosign بيوقّع الـ digest، والتوقيع + الـ certificate بيتسجلوا في Rekor (transparency log عام). وقت التحقق بتشترط الـ identity (repo/workflow/branch) والـ issuer. مفيش مفتاح يتسرق أو يتعمله rotation.

</details>

<details><summary>Multi-arch: QEMU ولا native runners؟</summary>

QEMU أسهل (runner واحد) بس بطيء جداً في أي compile (هنا `install-php-extensions`). native arm64 runners أسرع بكتير وبعدين `docker buildx imagetools create` يدمج الـ manifests. وفي الحالتين: الـ stages اللي ناتجها مستقل عن الـ CPU (assets) خليها على `$BUILDPLATFORM`.

</details>

<details><summary>Alpine و musl — فيه مشاكل حقيقية؟</summary>

أحياناً: الـ DNS resolver بتاع musl بيتصرف مختلف (search domains، TCP fallback) وده بيبان في K8s، وبعض الـ native extensions/binaries مبنية لـ glibc. لو قابلت ده، serversideup عنده Debian variants بنفس الـ API فالانتقال سهل. القرار بالقياس، مش بالعقيدة.

</details>

## 13) Checklist

- [ ] اتأكدت إن الـ image non-root و `SIGQUIT` وفيها OCI labels
- [ ] حللت الـ layers بـ `docker history` أو `dive`
- [ ] بنيت multi-arch (أو فهمت الخطوات والـ trade-offs)
- [ ] قريت تقرير Trivy في الـ CI وفهمت قصة الـ pin بالـ SHA
- [ ] نزّلت الـ SBOM artifact وسألته بـ `jq`
- [ ] جرّبت cosign sign/verify (لو عندك ECR)
- [ ] راجعت إن Dependabot docker PRs بتوصل فعلاً
