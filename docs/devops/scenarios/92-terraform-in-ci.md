# 92 — Terraform في الـ CI (plan على PR، approvals، infracost)

> **الهدف في سطر:** تفهم [`terraform.yml`](../../../.github/workflows/terraform.yml) step بـ step: plan لكل stack اتأثر على الـ PR بالـ role الـ **read-only** (`-lock=false`) ونتيجته comment على الـ PR، apply/destroy بـ `workflow_dispatch` تحت environment `lab` بالـ admin role (اللي بيثق في `environment:lab` بس — مفيش branch subject افتراضياً)، الـ backend config من الـ repo variables، Infracost اختياري، الـ concurrency، "plan once, apply the same plan"، policy-as-code (checkov / OPA conftest)، البدائل (Atlantis، HCP Terraform، Spacelift)، و job الـ terraform في [`lint-infra.yml`](../../../.github/workflows/lint-infra.yml).
> **المستوى:** Advanced · **الوقت:** ~3 ساعات · **التكلفة التقريبية:** الـ workflow نفسه GitHub minutes بس؛ الـ apply بيتكلف زي الـ stack (stack 20 ≈ $0.03/ساعة)
> **بيعتمد على:** [30 — CI و OIDC](30-ci-github-actions.md) · [34 — Environments و approvals](34-environments-approvals-promotion.md) · [80 — IAM و OIDC](80-iam-oidc-least-privilege.md) · [90 — Terraform بالتفصيل](90-terraform-deep-dive.md) · [91 — Import و drift](91-terraform-import-and-drift.md) · **الملفات في الـ repo:** [`.github/workflows/terraform.yml`](../../../.github/workflows/terraform.yml) · [`.github/workflows/lint-infra.yml`](../../../.github/workflows/lint-infra.yml) · [`bootstrap/github-oidc.tf`](../../../infra/terraform/bootstrap/github-oidc.tf) · [`bootstrap/outputs.tf`](../../../infra/terraform/bootstrap/outputs.tf) · [`.tflint.hcl`](../../../infra/terraform/.tflint.hcl) · [CONVENTIONS §9](../CONVENTIONS.md)

## 1) الفكرة (Concepts)

الـ infrastructure تتعامل زي الكود: **PR → plan ظاهر للـ reviewer → موافقة → apply من مكان موثوق**. المبادئ اللي الـ workflow مبني عليها:

1. **الـ plan read-only وعلى كل PR** — مينفعش PR (حتى لو عدّل الـ workflow نفسه) يقدر يغيّر infrastructure.
2. **الـ apply ورا approval ومن ref محمي** — الـ admin role مبيثقش غير في environment `lab` (`terraform_branches` فاضية افتراضياً)، والـ environment نفسه مقفول على main/master.
3. **مفيش long-lived keys** — OIDC بس ([30](30-ci-github-actions.md)).
4. **apply متسلسل لكل stack** — concurrency + S3 lock.
5. **تطبّق plan محفوظ** — مش `apply -auto-approve` على diff حي.
6. **تكلفة وسياسات ظاهرة قبل الـ merge** — Infracost، checkov، (conftest).

| المصطلح | المعنى |
|---|---|
| OIDC `sub` claim | هوية الـ job: `repo:<owner>/<repo>:ref:refs/heads/main` أو `:environment:lab` أو `:pull_request` — الـ trust policy بتقارن عليه |
| GitHub environment | gate قبل الـ job: required reviewers، wait timer، **deployment branches** |
| `-lock=false` | الـ plan ميحاولش يكتب `.tflock` (الـ role read-only، والـ plan ميعطّلش apply) |
| `-detailed-exitcode` | `0` مفيش تغيير · `1` error · `2` فيه تغيير |
| Saved plan (`-out=tfplan`) | الـ apply بينفّذ الملف ده بالظبط؛ لو الـ state اتغيّر بعده → `Saved plan is stale` |
| Concurrency group | job واحد شغال + واحد pending بالكتير لكل group |

## 2) المعمارية (Architecture)

```text
 pull_request (paths: infra/terraform/**, terraform.yml)          workflow_dispatch (stack, action)
          │                                                                  │
          ▼                                                                  ▼
  ┌─ fmt ─────────────┐   ┌─ targets ────────────────────────────┐   (stack = الـ input)
  │ fmt -check -diff  │   │ git diff base..head → stacks اتغيّرت │
  └───────┬───────────┘   │ + stacks بتنادي module اتغيّر        │
          │               └───────┬──────────────────────────────┘
          └──────────┬────────────┘
                     ▼
  ┌─ plan (matrix: stack) ─── role: gha-terraform-plan (ReadOnlyAccess + decrypt SecureStrings) ───┐
  │ init (bucket/region/key من vars) → plan -lock=false -detailed-exitcode -out=tfplan             │
  │ → plan.txt / plan.json → [Infracost] → PR comment (marker لكل stack، update in place) + summary│
  └───────────────────────────────┬─────────────────────────────────────────────────────────────────┘
                                  │ dispatch && action != plan
                                  ▼
  ┌─ apply ─── environment: lab (reviewers + branches) ─── role: gha-terraform (Admin, 2h) ───────────┐
  │ init → plan -out=tfplan (تحت الـ lock) → apply tfplan → outputs في الـ summary                    │
  └────────────────────────────────────────────────────────────────────────────────────────────────────┘
        state: s3://student-app-tfstate-<acct>/stacks/<stack>/terraform.tfstate (+ .tflock)
```

## 3) المتطلبات (Prerequisites)

- [ ] الـ [bootstrap](../../../infra/terraform/bootstrap/README.md) اتعمله apply (هو اللي بيعمل الـ roles — والـ workflow عمره ما بيشغّله: *"it creates the very roles this workflow assumes"*).
- [ ] Repository variables ([CONVENTIONS §9](../CONVENTIONS.md)) من `terraform output github_repository_variables`: `AWS_REGION`، `TF_STATE_BUCKET`، `AWS_TERRAFORM_ROLE_ARN`، `AWS_TERRAFORM_PLAN_ROLE_ARN`، `CODECONNECTIONS_ARN` (stacks 35/36)، و `ECS_IMAGE_TAG` (stack 50).
- [ ] GitHub environment `lab` بـ reviewers و branch policy (§4).
- [ ] (اختياري) secret `INFRACOST_API_KEY`.
- [ ] `gh` CLI عامل login (`gh auth status`).

```bash
cd infra/terraform/bootstrap
terraform output -json github_repository_variables \
  | jq -r 'to_entries[] | select(.value != "") | "\(.key)\t\(.value)"' \
  | while IFS=$'\t' read -r k v; do gh variable set "$k" --body "$v"; done
gh variable set ECS_IMAGE_TAG --body "$(aws ecr describe-images --repository-name student-app \
  --query 'sort_by(imageDetails,&imagePushedAt)[-1].imageTags[0]' --output text)"
gh variable list
```

## 4) الطريقة الأولى: GitHub UI (الـ environment والـ protections)

1. **Settings → Environments → New environment** → `lab`.
2. **Required reviewers** → ضيف نفسك (و **Prevent self-review** لو فيه فريق).
3. **Deployment branches and tags → Selected branches and tags → Add rule** → `main`، و `master`.
4. **Settings → Branches → Branch protection** على `master`: Require PR + required status checks: `terraform fmt`، `Terraform fmt · validate · tflint · checkov`.

> ⚠️ **ليه الخطوة 3 مش اختيارية:** الـ `sub` بتاع job عليه `environment: lab` بيبقى `repo:<owner>/<repo>:environment:lab` — **من غير الـ ref**. الـ admin role بيثق في الـ subject ده ([`github-oidc.tf`](../../../infra/terraform/bootstrap/github-oidc.tf)). يعني من غير branch policy، أي حد عنده write يعمل branch، يعدّل `terraform.yml` فيه، ويعمل dispatch → الـ job ياخد **AdministratorAccess** (ولو مفيش reviewers، من غير ما حد يوافق). الـ branch policy هي اللي بتربط الـ environment بالـ refs المحمية — ودي مكتوبة دلوقتي في [CONVENTIONS §9](../CONVENTIONS.md) و [bootstrap/README.md](../../../infra/terraform/bootstrap/README.md).
>
> والاتجاه التاني اتقفل كمان: `terraform_branches` في الـ bootstrap **فاضية افتراضياً**، يعني الـ admin role مبيثقش في أي `ref:refs/heads/...`. لو كان بيثق في `main`، أي job على main **من غير** `environment:` كان هياخد admin ويعدّي الـ reviewers. دلوقتي الطريق الوحيد للـ admin = job في environment `lab` (reviewers + branches). لو محتاج branch subject لسبب ما: `terraform_branches = ["main"]` في `terraform.tfvars` الـ bootstrap، وافهم إنك بتلغي الـ gate.

نفس الكلام بالـ API (اختياري — الـ UI أسهل):

```bash
REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
ME=$(gh api user --jq .id)
gh api -X PUT "repos/$REPO/environments/lab" --input - <<EOF
{
  "reviewers": [{ "type": "User", "id": $ME }],
  "deployment_branch_policy": { "protected_branches": false, "custom_branch_policies": true }
}
EOF
for b in main master; do
  gh api -X POST "repos/$REPO/environments/lab/deployment-branch-policies" -f name="$b" -f type=branch
done
gh api "repos/$REPO/environments/lab" --jq '{name, protection_rules: [.protection_rules[].type]}'
```

## 5) الطريقة التانية: `terraform.yml` سطر بسطر

### 5.1 الـ Triggers

```yaml
on:
  pull_request:
    paths: ["infra/terraform/**", ".github/workflows/terraform.yml"]
  workflow_dispatch:
    inputs:
      stack:  { type: choice, options: [20-ec2-single, 35-codebuild, 36-codepipeline, 40-ec2-alb-asg, 50-ecs-fargate, 60-eks] }
      action: { type: choice, options: [plan, apply, destroy], default: plan }
```

- **مفيش apply أوتوماتيك على push لـ main** — قرار مقصود: الـ stacks ephemeral وفلوس، فالـ apply **قرار** مش side effect للـ merge. (في production الشائع "merge ثم apply أوتوماتيك" أو Atlantis "apply قبل الـ merge" — §5.11.)
- `choice` = قيم محدودة → الـ input آمن يتحط في shell (`"stacks=[\"$INPUT_STACK\"]"` — التعليق في الـ workflow بيقولها).

### 5.2 الـ Permissions والـ Concurrency والـ env

```yaml
permissions:
  contents: read                     # الافتراضي لكل الـ jobs؛ كل job بيزوّد اللي محتاجه بس
concurrency:
  group: terraform-${{ github.event_name == 'workflow_dispatch' && inputs.stack || github.ref }}
  cancel-in-progress: false          # "a killed apply leaves a lock + half-built infra"
env:
  TF_VERSION: "~1.14"                # minor متثبت (آخر patch في 1.14.x)؛ الترقية = PR
  TF_IN_AUTOMATION: "true"           # output مناسب للـ CI (من غير "run terraform apply next")
  TF_INPUT: "false"                  # variable ناقص = error بدل prompt يعلّق الـ job
  TF_STATE_BUCKET: ${{ vars.TF_STATE_BUCKET }}
  TF_STATE_REGION: ${{ vars.AWS_REGION }}
  TF_VAR_region: ${{ vars.AWS_REGION }}
  TF_VAR_codeconnections_arn: ${{ vars.CODECONNECTIONS_ARN }}   # stacks 35, 36
  TF_VAR_image_tag: ${{ vars.ECS_IMAGE_TAG }}                    # stack 50
```

- **الـ concurrency:** dispatch → group لكل stack (اتنين apply على نفس الـ stack مستحيل يجروا مع بعض). PR → group لكل PR. **Gotcha:** الـ group بيسمح بـ run واحد شغال + **واحد pending**؛ لو عملت dispatch تالت والتاني لسه pending، الافتراضي إن الـ pending القديم يتلغى والجديد ياخد مكانه. يعني `apply` ثم `destroy` بسرعة ورا بعض ممكن يلغي الـ apply اللي مستني. وكمان الـ run كله (بما فيه انتظار الـ approval) شايل الـ slot.
- **`TF_VERSION: "~1.14"`**: الـ minor متثبت (الـ `versions.tf` بيطلب `>= 1.11`)، فـ Terraform 1.15+ مش هيتطبّق على الـ stacks من غير PR مقصود؛ الـ patch بس بيتحرك (1.14.x). عشان reproducibility كاملة: ثبّت الـ patch كمان (`1.14.N`) **و** اعمل commit لـ `.terraform.lock.hcl` — الـ lock files لسه مش في الـ repo ([90 §5.2](90-terraform-deep-dive.md))، فنسخ الـ providers بتتحرك جوه `~> 6.x`. ولاحظ إن job الـ terraform في `lint-infra.yml` بيستخدم `setup-terraform` من غير version (= أحدث نسخة)، يعني الـ lint والـ plan ممكن يجروا على نسختين مختلفتين.
- **`TF_VAR_*` من الـ repo variables:** الـ stacks اللي فيها inputs من غير defaults (`codeconnections_arn` في 35/36، `image_tag` في 50) كانت هتقع في الـ CI بـ `No value for required variable` لأن `TF_INPUT=false`. لو الـ variable مش متحدد في GitHub، `${{ vars.X }}` بيبقى string فاضي → stack 50 هيقع في الـ validation بتاع `image_tag` (regex محتاج حرف واحد على الأقل)، والرسالة بتقولك الحل: *"image_tag must be set to an immutable tag (git short SHA), never 'latest' or empty — in CI set the repo variable ECS_IMAGE_TAG."*

> ⚠️ **الـ CI بيشوف الـ defaults + الـ `TF_VAR_*` بس.** لو عملت apply لـ stack من الـ laptop بـ `terraform.tfvars` (gitignored) فيه قيم مختلفة (instance type، `green_enabled`، weights)، الـ plan في الـ CI هيطلّع diffs، و apply من الـ CI **هيرجّع** اختياراتك. اختار مكان واحد للـ apply لكل stack، أو حط tfvars غير سرّية لكل env في الـ repo (`lab.tfvars`) واستخدم `-var-file` في الاتنين.

### 5.3 Job `fmt`

`terraform fmt -check -recursive -diff infra/terraform` — رخيص ومبيحتاجش credentials، والـ `plan` job بيستناه (`needs: [fmt, targets]`). الإصلاح على جهازك: `terraform fmt -recursive infra/terraform`.

### 5.4 Job `targets` — مين يتعمله plan؟

```bash
git diff --name-only "$BASE_SHA" "$HEAD_SHA" -- infra/terraform .github/workflows/terraform.yml > changed.txt
mapfile -t modules < <(sed -n 's|^infra/terraform/modules/\([^/]*\)/.*|\1|p' changed.txt | sort -u)
# stack اتغيّر ملف فيه، أو بينادي module اتغيّر:  grep -qs "modules/$m\"" "$dir"*.tf
# تعديل الـ workflow نفسه = plan لكل الـ stacks
```

- **بيشتغل لأن الـ modules مسطّحة:** مفيش module بينادي module تاني جوه `modules/`. لو حصل، تغيير في الـ module الداخلي مش هيتكشف (الـ grep على ملفات الـ stack بس).
- الـ registry modules (`terraform-aws-modules/eks` في stack 60) مش جزء من الـ diff — ترقيتها بتبقى تعديل في `main.tf` الـ stack نفسه فبتتكشف.
- `bootstrap/` مستبعد عن قصد. تعديل فيه = apply من الـ laptop.
- `TF_STATE_BUCKET` مش متحدد → warning و `stacks=[]` (الـ workflow ميفشلش في repo لسه معملش bootstrap).

### 5.5 Job `plan`

```yaml
if: >-
  needs.targets.outputs.stacks != '[]' &&
  (github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository)
permissions: { contents: read, id-token: write, pull-requests: write }
strategy: { fail-fast: false, matrix: { stack: "${{ fromJSON(needs.targets.outputs.stacks) }}" } }
```

1. **Fork guard:** PRs من forks مبتاخدش OIDC token أصلاً، فالـ job بيتخطى بدل ما يقع.
2. **`fail-fast: false`:** stack فشل ميلغيش plans الـ stacks التانية — الـ reviewer محتاج يشوفهم كلهم.
3. **`terraform_wrapper: false`** في `setup-terraform`: الـ wrapper بيلف الـ stdout والـ exit code، وده بيبوّظ `terraform show -json > plan.json` و `-detailed-exitcode` في سكريبتات زي دي.
4. **الـ credentials:**

```yaml
role-to-assume: ${{ vars.AWS_TERRAFORM_PLAN_ROLE_ARN || vars.AWS_TERRAFORM_ROLE_ARN }}
```

الـ fallback للـ admin role عملياً **مبيشتغلش** في الـ plan job: الـ job ده مالوش `environment:`، فالـ `sub` = `:pull_request` (PR) أو `:ref:refs/heads/<branch>` (dispatch)، والـ admin role بقى بيثق في `environment:lab` بس → `Not authorized to perform sts:AssumeRoleWithWebIdentity`. يعني من غير `AWS_TERRAFORM_PLAN_ROLE_ARN` مفيش plans خالص (ولو حد رجّع `terraform_branches = ["master"]` في الـ bootstrap، الـ dispatch من master هيعمل plan بـ admin).

5. **الـ init من الـ repo variables** (نفس محتوى `backend.hcl` بس صريح، والـ key بنفس صيغة الـ `backend` block):

```bash
terraform init -no-color \
  -backend-config="bucket=$TF_STATE_BUCKET" -backend-config="region=$TF_STATE_REGION" \
  -backend-config="key=stacks/$STACK/terraform.tfstate" \
  -backend-config="use_lockfile=true" -backend-config="encrypt=true"
```

6. **الـ plan:**

```bash
args=(-no-color -lock=false -detailed-exitcode -out=tfplan)
if [[ "$DESTROY" == "true" ]]; then args+=(-destroy); fi
set +e; terraform plan "${args[@]}" > plan.log 2>&1; code=$?; set -e
```

- **`-lock=false`:** الـ plan role read-only ومش هيقدر يكتب `stacks/<stack>/terraform.tfstate.tflock`، ومش عايزين PR plan يعطّل apply. التمن: plan ممكن يقرا state في نص apply شغال → نتيجة inconsistent. مقبول لأن الـ plan ده **معلوماتي**؛ الـ apply بيعمل plan جديد تحت الـ lock.
- `set +e` عشان exit code `2` (changes) ميعتبرش فشل؛ `1` بس هو الفشل (step أخير `Fail on plan error`).
- `plan.txt` (للبني آدمين) و `plan.json` (`terraform show -json` — لـ Infracost والـ policies).

> 💡 **الـ read-only role مش "آمن" بالكامل:** عشان الـ refresh، الـ role ده بيقرا الـ state bucket ويعمل `kms:Decrypt` للـ SecureStrings عن طريق SSM وبيقرا secrets المشروع في Secrets Manager. التعليق في `github-oidc.tf`: *"repository write access = secret read access"*. الحل الجذري: write-only attributes ([90 §5.12](90-terraform-deep-dive.md)).

### 5.6 Infracost (اختياري)

```yaml
- uses: infracost/actions/setup@v3
  if: env.INFRACOST_API_KEY != '' && steps.plan.outputs.exitcode != '1'
- run: infracost breakdown --path plan.json --format table --no-color > infracost.txt
  continue-on-error: true           # "a cost estimate must never block a plan"
```

- بيقرا `plan.json` ويحسب **التكلفة الشهرية** للـ resources (ALB، RDS، NAT...). الـ API key مجاني من Infracost.
- **حدوده:** الحاجات اللي بالاستخدام (NAT data processing، ALB LCUs، CloudWatch logs، Fargate Spot) بتطلع 0 أو تقريبي من غير usage file (`infracost-usage.yml`). والـ stacks هنا ephemeral فالرقم الشهري أكبر بكتير من تكلفتك الحقيقية (ساعات).
- الأقوى في PR: `infracost diff` (الفرق عن الـ base branch) — الـ workflow عامل breakdown بس.

### 5.7 الـ PR comment والـ step summary

- **comment واحد لكل stack** بـ marker مخفي `<!-- terraform-plan:<stack> -->`؛ كل push بيعمل `PATCH` لنفس الـ comment بدل spam.
- الـ plan بيتقص عند 60,000 byte (حد الـ comment في GitHub حوالي 65k حرف) مع لينك للـ run.
- `fence="$(printf '\140\140\140')"` = 3 backticks من غير ما shellcheck يزعل.
- **أمان:** Terraform بيخفي الـ `sensitive` (`(sensitive value)`)، بس الـ `insecure_value`s والـ ARNs والـ account ID بيظهروا. لو الـ repo **public**، الـ PR comments والـ step summaries public.

### 5.8 Job `apply`

```yaml
apply:
  needs: plan
  if: github.event_name == 'workflow_dispatch' && inputs.action != 'plan'
  environment: lab                          # الـ gate + الـ OIDC sub (environment:lab)
  permissions: { contents: read, id-token: write }
  steps:
    - uses: aws-actions/configure-aws-credentials@v6
      with:
        role-to-assume: ${{ vars.AWS_TERRAFORM_ROLE_ARN }}
        role-duration-seconds: 7200         # الـ role نفسه max_session_duration = 7200 (EKS ممكن > ساعة)
    - run: terraform init ...
    - run: terraform plan -no-color -out=tfplan [-destroy]     # تحت الـ lock
    - run: terraform apply -no-color tfplan
    - run: terraform output -no-color >> "$GITHUB_STEP_SUMMARY" # الـ sensitive بتطلع <sensitive>
```

- `needs: plan` → لو الـ plan فشل (exit 1) مفيش apply.
- الـ reviewer بيوافق على الـ environment بعد ما يشوف plan الـ job الأول في الـ summary.

### 5.9 "Plan once, apply the same plan" — الـ repo عامل إيه بالظبط؟

الـ workflow بيعمل **plan مرتين**: (1) plan الـ review (read-only role، من غير lock)، (2) plan جديد في الـ apply job تحت الـ lock بالـ admin role، وبيطبّق **الملف ده بالظبط** (`apply tfplan`، مش `-auto-approve` على diff حي). التعليق: *"It matches the reviewed plan unless the stack changed in between (then review this log)."*

| | الـ repo (re-plan + saved plan) | Artifact (plan واحد بيتنقل للـ apply) |
|---|---|---|
| اللي اتطبّق = اللي اتراجع؟ | غالباً — مش مضمون لو حد عمل apply/drift في النص | آه بالظبط؛ ولو الـ state اتغيّر → `Saved plan is stale` والـ apply بيرفض |
| الـ secrets | الـ `tfplan` بيعيش جوه الـ runner بس | **الـ plan file فيه القيم بـ plain text** → artifact بيقدر ينزّله أي حد عنده read على الـ repo (public repo = الكل). لازم تشفير أو retention قصير جداً |
| شروط | — | نفس نسخة Terraform ونفس الـ providers بالظبط (lock file committed + `TF_VERSION` متثبت) ونفس الـ commit |
| تعقيد | قليل | upload/download + تشفير |

لو عايز الـ artifact approach (مش في الـ repo):

```yaml
# في plan job (بعد الـ plan):
      - uses: actions/upload-artifact@v4
        if: github.event_name == 'workflow_dispatch' && steps.plan.outputs.exitcode == '2'
        with:
          name: tfplan-${{ matrix.stack }}
          path: infra/terraform/stacks/${{ matrix.stack }}/tfplan
          retention-days: 1
# في apply job (بدل الـ "terraform plan (saved)"):
      - uses: actions/download-artifact@v4
        with:
          name: tfplan-${{ inputs.stack }}
          path: infra/terraform/stacks/${{ inputs.stack }}
      - run: terraform apply -no-color tfplan
```

> 💡 جواب الـ interview الكويس: "الهدف إن مفيش حاجة تتطبّق الـ reviewer مشافهاش. فيه طريقتين: نطبّق نفس الـ artifact (مع حماية الـ secrets جواه)، أو نعيد الـ plan تحت الـ lock ونخلّي الـ reviewer يوافق على **التاني** (manual gate بعد الـ re-plan). الـ repo بيعيد الـ plan قبل الـ gate مش بعده، فالـ gap صغير بس موجود."

### 5.10 تصميم الـ OIDC trust (اللي بيخلّي ده كله آمن)

من [`bootstrap/github-oidc.tf`](../../../infra/terraform/bootstrap/github-oidc.tf):

| Role | `sub` المسموح | الصلاحيات | بيستخدمه |
|---|---|---|---|
| `student-app-gha-terraform-plan` | `repo:<repo>:pull_request` + `repo:<repo>:ref:refs/heads/*` | `ReadOnlyAccess` + `kms:Decrypt` via SSM/Secrets Manager + `secretsmanager:GetSecretValue` على `student-app*` | plan job |
| `student-app-gha-terraform` | `environment:lab` بس (`terraform_environments`)؛ `terraform_branches` فاضية افتراضياً | `AdministratorAccess` (اختصار lab متعمّد)، session 2h | apply job |

الـ trust policy فيها `StringEquals` على `aud = sts.amazonaws.com` و `StringLike` على الـ `sub`. **تقوية الـ admin role** (من التعليق في الملف): CloudTrail + IAM Access Analyzer "generate policy" من كام apply/destroy، role لكل stack بالـ policy المولّدة، و permissions boundary يمنع `iam:*` على roles برّه `student-app-*` و APIs الـ org/billing. Advanced: GitHub بيسمح تخصيص صيغة الـ `sub` (مثلاً تضيف `job_workflow_ref`) عشان تربط الـ role بـ reusable workflow معين بدل أي workflow في الـ repo.

### 5.11 Policy as code

**checkov** شغال فعلاً في `lint-infra.yml` بس `soft_fail: true` (report only). تخليه blocking من غير ما تصلح كل حاجة مرة واحدة = baseline:

```bash
checkov -d infra/terraform --framework terraform --create-baseline      # بيكتب .checkov.baseline
checkov -d infra/terraform --framework terraform --baseline infra/terraform/.checkov.baseline   # findings جديدة بس
terraform show -json tfplan > plan.json && checkov -f plan.json --framework terraform_plan     # على الـ plan (قيم حقيقية)
```

**OPA / conftest على الـ `plan.json`** — قواعد خاصة بيك مش موجودة في أي scanner (مثال — مش في الـ repo):

```rego
# policy/terraform.rego
package main

import rego.v1

# NAT ≈ 32 USD/month لكل واحد — ممنوع إلا بقرار صريح
deny contains msg if {
  some rc in input.resource_changes
  rc.type == "aws_nat_gateway"
  "create" in rc.change.actions
  msg := sprintf("%s: NAT gateway needs an explicit cost approval", [rc.address])
}

# IMDSv2 إجباري (CONVENTIONS: http_tokens = required في كل launch template / instance)
deny contains msg if {
  some rc in input.resource_changes
  rc.type in {"aws_instance", "aws_launch_template"}
  some action in rc.change.actions
  action in {"create", "update"}
  rc.change.after.metadata_options[0].http_tokens != "required"
  msg := sprintf("%s: IMDSv2 (http_tokens = required) is mandatory", [rc.address])
}
```

```bash
terraform show -json tfplan > plan.json
docker run --rm -v "$PWD:/project" -w /project openpolicyagent/conftest test plan.json --policy policy
```

`import rego.v1` بيخلّي نفس الملف يشتغل على OPA قبل وبعد 1.0 (اللي خلّى صيغة `if`/`contains` هي الافتراضية). في الـ workflow: step بعد الـ plan ونتيجته في الـ PR comment. HCP Terraform بيقدّم نفس الفكرة كـ Sentinel أو OPA policy sets.

### 5.12 البدائل لـ "Terraform في GitHub Actions"

| الأداة | بتجري فين | الـ state/lock | الـ workflow | ملاحظات |
|---|---|---|---|---|
| **GitHub Actions يدوي** (الـ repo) | runners بتوعك/GitHub | S3 + `use_lockfile` | انت بتكتبه | تحكم كامل، كل حاجة (comments، policies، drift) لازم تبنيها |
| **Atlantis** | self-hosted server | backend بتاعك + lock per project لحد الـ merge | comments: `atlantis plan` / `atlantis apply` — غالباً **apply قبل الـ merge** | open source، محتاج تشغّله وتأمّنه (عنده credentials الـ apply) |
| **HCP Terraform** (Terraform Cloud سابقاً) | HashiCorp (أو agents) | remote state مدمج | VCS-driven runs، approvals، Sentinel/OPA، cost estimation، drift detection في tiers معينة | SaaS — راجع الـ pricing الحالي |
| **Spacelift / env0 / Scalr** | SaaS + private workers | مدمج أو بتاعك | stacks، OPA policies، drift detection، dependencies بين الـ stacks | TACOS تجارية |
| **Digger** | جوه GitHub Actions بتاعتك | backend بتاعك | Atlantis-style comments من غير server | open source |

**apply قبل الـ merge مقابل بعده:** بعد الـ merge = `main` هو الـ desired state، بس apply فاشل يسيب `main` ≠ الواقع لحد fix. قبل الـ merge (Atlantis) = اللي في `main` اتطبّق فعلاً، بس محتاج lock على الـ project لحد الـ merge عشان PR تاني ميعملش plan على state قديم.

### 5.13 Job الـ terraform في `lint-infra.yml`

| Step | الأمر | ملاحظة |
|---|---|---|
| fmt | `terraform fmt -check -recursive -diff infra/terraform` | نفس الـ terraform.yml |
| validate | لكل `bootstrap` و `stacks/*/`: `init -backend=false` + `validate` | من غير backend ولا AWS — بيمسك typos، types غلط، references مش موجودة، و `validation` blocks على الـ defaults |
| tflint | `tflint --init` ثم `tflint --recursive --chdir=infra/terraform --config "$PWD/infra/terraform/.tflint.hcl" --minimum-failure-severity=error` | الـ config بـ absolute path لأن `--recursive` بيقرا `.tflint.hcl` كل فولدر؛ `GITHUB_TOKEN` عشان rate limit تنزيل الـ AWS ruleset |
| checkov | `bridgecrewio/checkov-action@v12` (`soft_fail: true`) | report only |

`lint-infra.yml` بيشتغل على **كل** PR (الـ `pull_request` من غير `paths`)، بينما `terraform.yml` على تغييرات `infra/terraform` بس — فالـ lint check موجود دايماً ينفع يتعمل required.

## 6) الـ Deploy (شغّل الـ workflow)

```bash
# 1) PR تجريبي: تعديل comment في module → plans للـ stacks اللي بتناديه
git switch -c tf-ci-demo
sed -i '1s/^/# scenario 92 demo\n/' infra/terraform/modules/alb/outputs.tf
git commit -am "demo: touch alb module" && git push -u origin tf-ci-demo
gh pr create --fill
gh pr checks --watch                                   # plan (40-ec2-alb-asg), plan (50-ecs-fargate)

# 2) plan يدوي لـ stack
gh workflow run terraform.yml --ref master -f stack=20-ec2-single -f action=plan
RUN=$(gh run list --workflow terraform.yml -L 1 --json databaseId --jq '.[0].databaseId'); gh run watch "$RUN"

# 3) apply → بيستنى موافقة الـ environment
gh workflow run terraform.yml --ref master -f stack=20-ec2-single -f action=apply
RUN=$(gh run list --workflow terraform.yml -L 1 --json databaseId --jq '.[0].databaseId')
# وافق من الـ UI (Review deployments) أو:
REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
ENV_ID=$(gh api "repos/$REPO/environments/lab" --jq .id)
gh api -X POST "repos/$REPO/actions/runs/$RUN/pending_deployments" \
  -F "environment_ids[]=$ENV_ID" -f state=approved -f comment="reviewed plan for 20-ec2-single"
gh run watch "$RUN"
```

## 7) التحقق (Verify)

```bash
gh pr view --comments | grep -A3 'terraform-plan:'                    # comment لكل stack
gh run view "$RUN" --log | grep -E 'Plan:|Apply complete|No changes'
aws s3api head-object --bucket "$(gh variable get TF_STATE_BUCKET)" \
  --key stacks/20-ec2-single/terraform.tfstate --query LastModified
aws s3 ls "s3://$(gh variable get TF_STATE_BUCKET)/stacks/20-ec2-single/"   # مفيش .tflock بعد ما الـ run يخلص
aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRoleWithWebIdentity \
  --max-results 5 --query 'Events[].{t:EventTime,u:Username}'
```

المفروض: comment محدّث لكل stack، `Apply complete!` في الـ log، الـ state اتعدّل في نفس الدقيقة، مفيش lock معلّق، وفي CloudTrail session بالـ OIDC.

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر | المتوقع |
|---|---|---|
| PR من fork | fork + PR يعدّل `infra/terraform` | `plan` job **skipped** (مفيش token للـ forks) |
| شيل الـ plan role var | `gh variable delete AWS_TERRAFORM_PLAN_ROLE_ARN` ثم PR أو dispatch plan | الـ fallback للـ admin role → `Not authorized to perform sts:AssumeRoleWithWebIdentity` (الـ plan job مالوش environment، والـ admin بيثق في `environment:lab` بس) — رجّعه |
| apply من feature branch | `gh workflow run terraform.yml --ref tf-ci-demo -f stack=20-ec2-single -f action=apply` | مع branch policy: الـ apply job بيترفض (*branch is not allowed to deploy to lab*). من غيرها: بيشتغل بـ Admin بعد الموافقة = الثغرة اللي §4 بيقفلها |
| `ECS_IMAGE_TAG` فاضي | امسح الـ variable ثم plan لـ 50 | validation: *"... never 'latest' or empty — in CI set the repo variable ECS_IMAGE_TAG."* لأن القيمة `""` |
| Lock معلّق | Cancel للـ run أثناء `terraform apply` | الـ run الجاي: `Error acquiring the state lock` → `terraform force-unlock <ID>` من الـ laptop بعد التأكد |
| الـ state اتغيّر بين الـ plan-ين | apply من الـ laptop بعد plan الـ review وقبل الموافقة | plan الـ apply job مختلف عن اللي اتراجع — لازم تقرا الـ log قبل ما يكمّل (أو artifact approach يرفض بـ stale) |
| tfvars الـ laptop | apply من الـ laptop بـ `instance_type = "t3.micro"` ثم plan من الـ CI | الـ CI عايز يرجّعها `t3.small` (الـ default) |
| fmt | مسافة زيادة في أي `.tf` | `terraform fmt` job أحمر بالـ diff |
| tflint | variable من غير `description` | `terraform_documented_variables` |

## 9) الرجوع (Rollback)

- **تغيير infra بايظ:** revert للـ PR → merge → dispatch `apply` (نفس الطريق، نفس الـ gate).
- **destroy بالغلط:** dispatch `apply` تاني يعمل الموارد — بس الـ data: RDS في الـ lab `skip_final_snapshot = true` = الداتا راحت. في production: `deletion_protection` + final snapshot + `prevent_destroy`، و reviewer على `destroy` بالذات.
- **apply نص نص (timeout/cancel):** force-unlock ثم plan/apply تاني — Terraform بيكمّل من الـ state (الـ resources اللي اتعملت متسجلة).

## 10) المسح (Teardown) ⚠️

```bash
gh workflow run terraform.yml --ref master -f stack=20-ec2-single -f action=destroy   # + موافقة الـ environment
gh pr close tf-ci-demo --delete-branch
aws resourcegroupstaggingapi get-resources --tag-filters Key=Project,Values=student-app Key=Scenario,Values=20 \
  --query 'ResourceTagMappingList[].ResourceARN' --output text
```

لو عملت apply لأكتر من stack: الترتيب في [`infra/terraform/README.md`](../../../infra/terraform/README.md#destroy-order) (36 → 35 → الباقي). الـ environment `lab` والـ variables سيبهم (مجانيين).

## 11) التكلفة (Cost)

| البند | التكلفة |
|---|---|
| GitHub Actions | public repo مجاني؛ private حسب الـ minutes المتاحة في الـ plan بتاعك (الـ plan job دقيقة-اتنين لكل stack) |
| Infracost CLI + API key | مجاني للاستخدام ده |
| AWS | تكلفة الـ stack اللي عملتله apply فقط (state reads/writes سنتات) |

## 12) أسئلة Interview

<details><summary>ليه الـ plan على الـ PR بـ role مختلف عن الـ apply؟</summary>

لأن أي حد عنده write يقدر يفتح PR يعدّل الـ workflow نفسه ويشغّل أي كود بالـ credentials المتاحة للـ PR. فالـ PR ياخد read-only بس (ومن غير lock عشان ميعطّلش). الـ apply بـ admin لكن الـ trust مربوط بـ environment `lab` بس (reviewers + branch policy على main/master)، ومفيش branch subject يسمح لـ job برّه الـ environment ياخد admin. حتى الـ read-only بيقرا secrets (state + SecureStrings)، فده سبب إضافي لـ write-only attributes.

</details>

<details><summary>الـ admin role بيثق في <code>environment:lab</code>. إيه الثغرة وإزاي تتقفل؟</summary>

الـ `sub` بتاع environment مفيهوش الـ ref، فأي branch يقدر يعمل job في `lab` ياخد الـ role. القفل: deployment branch policy على الـ environment (main/master بس) + required reviewers + prevent self-review، وممكن تخصيص الـ `sub` claim يضيف `job_workflow_ref` أو تستخدم condition على claims تانية.

</details>

<details><summary>ليه <code>-lock=false</code> في الـ plan مقبول؟ ومتى مش مقبول؟</summary>

مقبول لأنه plan معلوماتي بـ role مش قادر يكتب الـ lock، والـ apply بيعمل plan جديد تحت الـ lock. مش مقبول لو الـ plan ده هو اللي هيتطبّق (artifact approach) — ساعتها الـ plan لازم يتعمل بـ lock، أو تعتمد على إن Terraform بيرفض saved plan لو الـ state serial اتغيّر (`Saved plan is stale`).

</details>

<details><summary>إزاي تضمن إن اللي اتطبّق هو اللي اتراجع؟</summary>

إما تطبّق نفس الـ plan artifact (مع نفس الـ Terraform/providers والـ lock file، وحماية الـ secrets اللي جواه — plain text)، أو تعيد الـ plan تحت الـ lock وتحط الـ approval **بعد** الـ re-plan. الـ repo بيعيد الـ plan بعد الموافقة ويطبّق الـ saved plan — gap صغير لو حد غيّر الـ state بين الاتنين. والـ concurrency group + S3 lock بيمنعوا اتنين applies.

</details>

<details><summary>ليه <code>cancel-in-progress: false</code>؟ وإيه الـ gotcha في الـ concurrency؟</summary>

إلغاء apply في النص = lock معلّق + infra نص مبنية. الـ gotcha: الـ group بيحتفظ بـ run شغال وواحد pending بس؛ run جديد بيلغي الـ pending القديم. فـ dispatches كتير ورا بعض على نفس الـ stack ممكن تضيع واحد مستني approval.

</details>

<details><summary>الـ CI بيعمل plan بالـ defaults، والـ stack اتعمله apply من الـ laptop بـ tfvars. المشكلة والحل؟</summary>

الـ CI هيشوف diff مزيّف، وأي apply من الـ CI هيرجّع اختيارات الـ laptop. الحل: مصدر واحد للـ inputs — tfvars غير سرّية لكل env في الـ repo وتتمرر بـ `-var-file` في كل مكان، والـ secrets من SSM/Secrets Manager مش من tfvars، والـ apply من مكان واحد (CI) بعد مرحلة الـ lab.

</details>

<details><summary>Infracost بيقول الـ stack بـ 60 دولار في الشهر وانت دفعت 2. مين صح؟</summary>

الاتنين: Infracost بيحسب monthly لو الموارد فضلت شغالة 730 ساعة، والـ stacks هنا بتعيش ساعات. وكمان الحاجات اللي بالاستخدام (NAT data، LCUs، logs) بتطلع تقريبية من غير usage file. قيمته الحقيقية في الـ **diff**: الـ PR ده زوّد كام (NAT جديد = +32/شهر) قبل الـ merge.

</details>

<details><summary>Atlantis ولا GitHub Actions ولا HCP Terraform؟</summary>

Actions: مرونة كاملة وصفر infra زيادة، بس انت بتبني الـ comments والـ locks والـ policies والـ drift. Atlantis: PR workflow جاهز وlocks per project، بس server لازم تشغّله وتأمّنه (عنده credentials الـ apply). HCP Terraform/Spacelift: remote state وruns وpolicies وdrift detection وRBAC جاهزين، بفلوس وvendor dependency. لفريق صغير على GitHub: Actions + OIDC + environments كفاية؛ لعشرات الـ stacks والفرق: TACOS.

</details>

<details><summary>إزاي تضيف policy-as-code من غير ما توقف الشغل كله؟</summary>

ابدأ report-only (زي checkov هنا بـ `soft_fail`)، اعمل baseline للـ findings الحالية وخلي الجديد بس blocking، واكتب قواعد OPA/conftest على `plan.json` للحاجات الخاصة بالمشروع (NAT، IMDSv2، tags إجبارية). الـ exceptions تبقى inline بسبب مكتوب (`checkov:skip=...:reason`) مش skip عام.

</details>

## 13) Checklist

- [ ] الـ repo variables متظبطة من `github_repository_variables` + `ECS_IMAGE_TAG`
- [ ] الـ environment `lab` عليه reviewers **و** deployment branches (main/master)
- [ ] فتحت PR وشفت الـ plan comment لكل stack اتأثر
- [ ] عملت dispatch plan/apply/destroy ووافقت على الـ environment
- [ ] فاهم الفرق بين re-plan و artifact وليه الـ plan file خطر
- [ ] جرّبت الـ fork guard والـ fallback role والـ branch policy
- [ ] كتبت قاعدة conftest واحدة على الأقل وشغّلتها على `plan.json`
