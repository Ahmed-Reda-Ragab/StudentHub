# 98 — الـ Portfolio وأسئلة الـ Interview

> **الهدف في سطر:** تحوّل المعمل ده لـ portfolio بيقنع hiring manager في دقيقتين: README بـ hero section، رسم معمارية، 3 demo stories بأوامر حقيقية، ADRs لقرارات اتاخدت فعلاً في الـ repo، CV bullets بأرقام انت قستها، وبنك أسئلة **50 سؤال** Senior DevOps/SRE بإجابات مختصرة كل واحد مربوط بسيناريو.
> **المستوى:** Advanced · **الوقت:** ~4 ساعات تجهيز + مراجعة مستمرة · **التكلفة التقريبية:** مجاني (الـ demos الأرخص بتشتغل على GitHub Actions من غير AWS)
> **بيعتمد على:** كل المعمل، خصوصاً [24](24-canary-single-host.md) · [68](68-k8s-canary-argo-rollouts.md) · [73](73-slo-error-budget-burn-rate.md) · [76](76-incident-response.md) · [91](91-terraform-import-and-drift.md) · [96](96-comparison-matrices.md) · [97](97-cost-and-teardown.md) · **الملفات في الـ repo:** [`docs/devops/CONVENTIONS.md`](../CONVENTIONS.md) · [`.github/workflows/`](../../../.github/workflows) · [`deploy/ec2/lb/bin/`](../../../deploy/ec2/lb/bin) · [`observability/prometheus/rules/`](../../../observability/prometheus/rules)

## 1) الفكرة (Concepts)

الـ portfolio مش "عملت كذا tool". الـ portfolio = **دليل إنك بتاخد قرارات وبتقيس نتايجها**. الـ repo ده فيه ميزة نادرة: تطبيق **حقيقي** (مش hello world) متعمله deploy بـ 4 طرق، وكل ادعاء ليه أمر يثبته (`probe.sh`، k6، promtool، workflows خضرا).

| اللي الـ interviewer بيدوّر عليه | الدليل في الـ repo |
|---|---|
| بتفهم الـ trade-offs؟ | [96](96-comparison-matrices.md) + ADRs (§4) |
| بتقيس؟ | `probe.sh` (0 failed requests)، k6 thresholds = SLOs، burn-rate rules متختبرة بـ `promtool test rules` |
| بتفكّر في الفشل؟ | `SRE_FAULT_*`، gates بـ auto-abort، `BROKEN` marker، runbooks لكل alert |
| أمان؟ | OIDC من غير keys، SSM بدل SSH، least privilege، Trivy/SBOM/cosign |
| فلوس؟ | stacks مؤقتة، مفيش NAT، روتين teardown ([97](97-cost-and-teardown.md)) |
| بتكتب للناس؟ | 70+ سيناريو docs بقالب ثابت + CONVENTIONS كـ "عقد" |

## 2) إزاي تعرض الـ repo

### 2.1 فكرة الـ README hero section

الـ README الرئيسي بالإنجليزي (الـ recruiters والـ ATS)، والـ docs بالعربي ميزة إضافية. اقتراح للحتة اللي فوق خالص (انسخه وعدّل — الـ badges بتشاور على workflows موجودة فعلاً):

```markdown
# StudentHub — a real Laravel app, deployed 4 ways on AWS, with SRE you can measure

> One image, one contract: EC2 + Docker Compose → ASG/ALB → ECS Fargate → EKS.
> Every zero-downtime strategy (rolling, blue/green, canary, linear, A/B, shadow) with automatic rollback,
> SLOs with multi-window burn-rate alerts, Terraform + Ansible, GitHub Actions and CodePipeline.

![CI](https://github.com/Ahmed-Reda-Ragab/StudentHub/actions/workflows/ci.yml/badge.svg)
![Lab integration](https://github.com/Ahmed-Reda-Ragab/StudentHub/actions/workflows/lab-integration.yml/badge.svg)
![K8s integration](https://github.com/Ahmed-Reda-Ragab/StudentHub/actions/workflows/k8s-integration.yml/badge.svg)
![Lint infrastructure](https://github.com/Ahmed-Reda-Ragab/StudentHub/actions/workflows/lint-infra.yml/badge.svg)

| Claim | Proof |
|---|---|
| 0 failed requests during blue/green, rolling and canary | probe-asserted in `lab-integration.yml` and `k8s-integration.yml` |
| A bad release is aborted automatically | nginx metric gate (`canary.sh`, exit 2) · Argo Rollouts analysis (Degraded) |
| SLO 99.5% / 95% < 300 ms, burn-rate alerts unit-tested | `observability-lint.yml` (`promtool test rules`) |
| Infrastructure as code, plan on every PR | `terraform.yml` · bootstrap + 12 modules + 6 ephemeral stacks |
| No long-lived cloud keys | GitHub OIDC roles · SSM Run Command / Session Manager |
```

وتحته: الرسم (§2.2)، جدول "Start here" بـ 5 لينكات (CONVENTIONS، 96، 97، demo videos/GIFs، الـ HANDBOOK.pdf)، وسطر "How to run without AWS" (`gh workflow run lab-integration.yml`).

### 2.2 رسم المعمارية (ASCII)

```text
                 GitHub repo ─── push / PR
                      │
   ci.yml: pint · tests (SQLite + MySQL) · audit · hadolint · build once · Trivy · SBOM
   lab-integration.yml / k8s-integration.yml: compose · k6 · B/G · rolling · canary · Argo (no AWS)
                      │ OIDC (no keys)
                      ▼
           ECR student-app:<sha7>  (IMMUTABLE · scan on push · keep 30)
                      │
   ┌──────────────────┼──────────────────────┬────────────────────────┬────────────────────┐
   ▼                  ▼                      ▼                        ▼                    ▼
 EC2 single        ASG + ALB              ECS Fargate              EKS                  CodePipeline
 (stack 20)        (stack 40)             (stack 50)               (stack 60)           (stacks 35/36)
 SSM Run Command   SSM IMAGE_URI pointer  taskdef + update-service helm RollingUpdate    Source → Build
 nginx: B/G ·      instance refresh ·     rolling + breaker ·      Argo Rollouts canary  → [Approve]
 canary · rolling  weighted TGs ·         native B/G/linear/canary + Prometheus analysis → Deploy (ECS /
 A/B · shadow      CodeDeploy · Ansible   CodeDeploy               Argo CD (GitOps)        CodeDeploy)
   │                  │                      │                        │
   └──── config & secrets: SSM /student-app/<env>/app/*  (ECS secrets · ESO on EKS) ────────┘
   └──── data: MySQL container (20) → RDS MySQL 8.4 (40/50/60) · ElastiCache (49)
   Observability: /metrics → Prometheus (SLO rules, burn rate) → Alertmanager → Grafana
                  ALB/ECS/RDS → CloudWatch alarms (slo-fast-burn…) → SNS · JSON logs → CW Logs / Loki
   Reliability:   k6 (thresholds = SLOs) · /sre-lab/* · SRE_FAULT_* · AWS FIS · runbooks · postmortems
   IaC:           Terraform (S3 native lock) · Ansible (SSM) · Packer · Helm · kustomize
```

### 2.3 الـ repo في 60 ثانية (لو حد فتحه قدامك)

| افتح | قول |
|---|---|
| [`CONVENTIONS.md`](../CONVENTIONS.md) | "ده العقد: أسماء، بورتات، endpoints، SLOs، SSM layout. كل الأدوات ماشية عليه." |
| [`deploy/ec2/lb/bin/canary.sh`](../../../deploy/ec2/lb/bin/canary.sh) | "canary بـ metric gate في 78 سطر bash — نفس فكرة Argo Rollouts." |
| [`.github/workflows/deploy-asg.yml`](../../../.github/workflows/deploy-asg.yml) (أول 30 سطر) | "3 استراتيجيات على ASG، وليه الـ rollback بتاع الـ instance refresh في الـ workflow مش في AWS." |
| [`observability/prometheus/rules/`](../../../observability/prometheus/rules) | "burn-rate multi-window + unit tests + drill SLI منفصل." |
| [`infra/terraform/README.md`](../../../infra/terraform/README.md) | "bootstrap + stacks مؤقتة، مفيش remote_state، الـ CI بيملك الـ image." |
| Actions tab | "كل ده بيتختبر على كل push من غير ما ألمس AWS." |

### 2.4 الـ pitch (60 ثانية)

> "خدت تطبيق Laravel حقيقي وعملتله deploy على AWS بأربع منصات — EC2، ASG، ECS، EKS — بكل استراتيجيات الـ zero-downtime. كل release بيتقاس: probe بيأكد صفر requests فاشلة، والـ canary بيعمل abort لوحده لما الـ error rate يعدّي الحد. عرّفت SLOs بـ burn-rate alerts متختبرة، وكتبت runbook لكل alert. الـ infra كلها Terraform بـ stacks مؤقتة عشان التكلفة، والـ CI من غير أي AWS keys. وفي جداول بتقارن كل اختيار بالتمن بتاعه."

## 3) الـ 3 Demo stories

كل story: **الجملة اللي بتفتح بيها · التجهيز · الأوامر · تفرّج على إيه · الأرقام اللي تقولها**. سجّل كل واحدة GIF/فيديو 2–3 دقايق وحط لينك الـ GitHub run.

### Story 1 — "Zero-downtime canary بيعمل abort لوحده لـ release بايظ"

**الجملة:** "الـ health checks كانت خضرا، والـ release كان بيرجّع 500 على نص الصفحات. الـ canary مسكه على 10% ورجّع الـ traffic في أقل من دقيقة."

**مجاناً (من غير AWS):** الـ job **Zero-downtime scripts (single host)** في [`lab-integration.yml`](../../../.github/workflows/lab-integration.yml) بيعمل canary سليم (promote) وبعده canary بايظ (auto-abort) والـ probe بيأكد 0 failed requests، و [`k8s-integration.yml`](../../../.github/workflows/k8s-integration.yml) بيعمل نفس الحاجة بـ Argo Rollouts (`Degraded`).

```bash
gh workflow run lab-integration.yml --ref devops-lab
gh run watch
gh run view <RUN_ID> --log | grep -E "canary analysis|ABORT|aborted|probe summary|failed" | head -40
```

**على AWS (stack 20):**

```bash
# من الـ laptop: الـ runner بيولّد traffic على صفحات حقيقية عشان الـ gate يلاقي data
gh workflow run deploy-ec2-canary.yml --ref devops-lab -f image_tag=<SHA7> \
  -f slot_env=SRE_FAULT_ERROR_RATE=0.5 -f expect_abort=true
gh run watch

# أو على السيرفر نفسه (terminal 1: traffic، terminal 2: الـ release)
bash /opt/student-app/src/deploy/scripts/probe.sh http://localhost/login 0 0.05
cd /opt/student-app/src/deploy/ec2/lb
SLOT_ENV="SRE_FAULT_ERROR_RATE=0.5" SKIP_PULL=true EXPECT_EXIT=2 bash ../../scripts/with-probe.sh -- bash bin/canary.sh student-app:v2
bash bin/status.sh            # ACTIVE = القديم، MODE=single، BROKEN=<canary>
bash bin/rollback.sh          # بيرفض: "nothing to roll back to" — الـ BROKEN marker
```

**تفرّج على:** `canary analysis: N errors / M requests = 0.5xxx (max 0.01)` ← `ABORT: error rate … at 10%` ← `canary aborted - 100% of traffic back on <stable>` ← exit **2** ← `✔ command exit=2 as expected, availability within budget`.

**الأرقام والصراحة:** وزن 10% × `STEP_SECONDS` 30s، threshold 1%. الـ probe على `/ready` = 0 failures، **بس** المستخدمين اللي جم على الـ canary في الـ 30 ثانية دول شافوا 500 — الـ blast radius ≈ 10% × 50% من الـ requests لمدة خطوة واحدة. "zero-downtime" مش "zero errors"؛ ده الـ trade-off اللي بتختار حجمه بـ `STEPS` و `STEP_SECONDS`. وقارن: نفس الـ release عدّى `bluegreen.sh` لأن الـ smoke request واحد ([23 §8](23-bluegreen-single-host.md)).

### Story 2 — "SLO burn-rate alert ← runbook ← rollback"

**الجملة:** "release فيه bug صغير (10% errors) عدّى الـ blue/green. الـ fast-burn alert ضرب، الـ runbook قال: deploy حديث = rollback الأول وبعدين نفهم. رجعنا في دقيقة، والـ postmortem طلّع إن الناقص كان metric gate."

**التجهيز:** ستاك [23](23-bluegreen-single-host.md) + ستاك الـ observability ([`observability/compose`](../../../observability/compose)) على نفس الـ host/WSL، والسيناريو بالتفصيل في [76 §7](76-incident-response.md).

```bash
docker compose -f observability/compose/docker-compose.yml up -d
# terminal 1: traffic ثابت على صفحات حقيقية
k6 run -e BASE_URL=http://localhost -e LOADTEST_USERS=5 -e VUS=10 -e DURATION=2h -e P95_MS=2000 loadtest/k6/load.js
# terminal 2: الـ "release" البايظ
cd deploy/ec2/lb
SLOT_ENV="SRE_FAULT_ERROR_RATE=0.1" SKIP_PULL=true bash bin/bluegreen.sh student-app:v2
# بعد ما SLOAvailabilityFastBurn يضرب (Alertmanager :9093 / alert-sink logs):
bash bin/status.sh && bash bin/rollback.sh
curl -s localhost:9093/api/v2/alerts | jq -r '.[] | "\(.labels.alertname) \(.status.state)"'
```

**تفرّج على:** Grafana "SLOs & error budget" (الـ burn rate بيطلع) و RED ("5xx ratio by release" = v2 بس) ← الـ alert ← runbook [`SLOAvailabilityFastBurn`](76-incident-response.md) (أول 5 دقايق: حصل deploy؟ `by (version, color)`) ← `rollback.sh` ← الـ alert بيتحل في دقايق (الـ 5m window).

**الأرقام:** 10% errors = burn rate 20 → الـ fast tier (14.4× على 1h و 5m) بياخد ≈ 60 × 14.4 / 20 ≈ **43 دقيقة** + `for` (تاريخ نضيف). عايز demo أسرع؟ `SRE_FAULT_ERROR_RATE=0.3` (B = 60 → ~15 دقيقة، والـ smoke غالباً بيعدّي). اختم بالـ postmortem template ([76 §13.1](76-incident-response.md)) و action item: "canary إجباري للـ releases" — ده بيربط Story 2 بـ Story 1.

### Story 3 — "من الـ Console لـ Terraform بـ import لحد zero-diff"

**الجملة:** "ورثت موارد معمولة بإيد في الـ Console. دخّلتها تحت Terraform من غير ما أمسح حاجة، ووصلت لـ plan فيه `No changes`، وفصلت الـ drift المقصود (اللي الـ CI بيملكه) عن الحقيقي."

```bash
# imports.tf فيه import blocks للـ SG والـ EC2 والـ EIP والـ ECR والـ log group والـ SSM params (91 §5.1)
terraform init
terraform plan -generate-config-out=generated.tf     # Plan: 7 to import, 0 to add, 0 to change, 0 to destroy
# نضّف generated.tf (conflicts، defaults، computed attrs) وانقله للـ modules الحقيقية
terraform plan                                        # لحد ما يبقى zero-diff
terraform apply && rm imports.tf
terraform plan -refresh-only                          # drift detection
terraform plan -detailed-exitcode; echo "exit=$?"     # 0 = نضيف، 2 = فيه تغيير
```

**تفرّج على:** الـ generated code قبل/بعد التنضيف، والـ drift المقصود: weights الـ listener في stack 40 (`listener_weights_managed_externally`) و `IMAGE_URI` (`ignore_changes`).

**الأرقام:** عدد الموارد اللي اتعملها import، عدد الـ diffs اللي اتحلّت، والوقت لحد zero-diff. والدرس: الـ import بيتبنّى الـ resource مش القيمة (`value` للـ SecureString).

## 4) ADRs (Architecture Decision Records)

ADR = صفحة واحدة بتقول **إيه القرار، ليه، وإيه التمن**. الـ interviewers بيحبوها لأنها بتوري إنك عارف البدائل. حطهم في `docs/adr/` لما تقرر تضيفهم للـ repo.

### 4.1 القالب

```markdown
# ADR-NNN: <القرار في جملة>

- **Status:** Proposed | Accepted | Superseded by ADR-XXX
- **Date:** YYYY-MM-DD · **Deciders:** <names>

## Context
إيه المشكلة والقيود (أرقام لو موجودة).

## Decision
إحنا هنعمل كذا. (تفاصيل كفاية حد يطبّقها.)

## Alternatives considered
| البديل | ليه لأ |
|---|---|

## Consequences
- ✅ الإيجابيات
- ⚠️ التمن / المخاطر وإزاي بنتعامل معاها

## References
روابط للكود والـ docs.
```

### 4.2 ADR-001: SSM Parameter Store هو مصدر الحقيقة للـ config والـ secrets

- **Status:** Accepted

**Context:** نفس التطبيق بيشتغل على 4 منصات (compose على EC2، ASG، ECS، EKS) ومحتاج نفس الـ env. الـ secrets ممنوع تبقى في الـ image أو git. الميزانية صفر تقريباً.

**Decision:** layout واحد `/student-app/<env>/app/<ENV_KEY>` (اسم الـ parameter بعد آخر `/` = اسم الـ env var)، SecureString للـ secrets (`APP_KEY`، `DB_PASSWORD`، `SRE_LAB_TOKEN`). الـ consumers: EC2 بـ [`render-env-from-ssm.sh`](../../../deploy/ec2/render-env-from-ssm.sh) → `app.env` (chmod 600)، ECS بـ `secrets[].valueFrom`، EKS بـ ESO (`ClusterSecretStore` provider `ParameterStore`). Terraform بيولّد القيم الأولى (`random_bytes` 32 → `base64:…`). Secrets Manager بس للـ RDS master password لو محتاجين rotation (`use_secrets_manager`).

| البديل | ليه لأ |
|---|---|
| Secrets Manager لكل حاجة | ~$0.40/secret/شهر، والـ rotation مش محتاجينه لمعظم القيم |
| `.env` في الـ image أو git | تسريب أكيد، والـ image مبقتش واحدة لكل البيئات |
| ansible-vault | موجود كبديل (`app_env_source: vault`) بس EC2 بس، ومش بيخدم ECS/EKS |
| Secrets في git (sealed/SOPS) | K8s بس، ومفتاح زيادة نديره |

**Consequences:** ✅ تكلفة صفر، layout واحد في كل حتة، least privilege بالـ path (ESO مقفول على `/app` بس). ⚠️ مفيش rotation مدمج. الـ secrets موجودة في الـ Terraform state (الوصول للـ bucket = الوصول للـ secrets). الـ stacks 20/40/50/60 بيكتبوا نفس الـ paths → stack واحد لكل env. تغيير قيمة محتاج refresh (ESO كل 1h أو force-sync، ECS tasks جديدة، EC2 render تاني).

**References:** [CONVENTIONS §4](../CONVENTIONS.md) · [81](81-secrets-management.md) · [64](64-eks-external-secrets.md)

### 4.3 ADR-002: الـ CI بيملك الـ image، و Terraform بيملك الـ infra

- **Status:** Accepted

**Context:** الـ image بتتغير مع كل commit، والـ infra نادراً. لو كل deploy = `terraform apply` يبقى الـ deploy محتاج صلاحيات admin، وأي apply لتغيير صغير ممكن يرجّع image قديمة.

**Decision:** Terraform بيعمل **القيمة الأولى** بس وبيتجاهل التغييرات: `ignore_changes = [value]` على `/student-app/<env>/deploy/<color>/IMAGE_URI` (stack 40) و `ignore_changes = [task_definition]` (stack 50). الـ CI بيعمل deploy بالـ deploy role الضيق: `put-parameter` + `start-instance-refresh`، register task definition + `update-service`، `helm upgrade` أو PR بـ `image.tag` (GitOps). الـ tags = git SHA7 immutable (ECR `IMMUTABLE`)، ممنوع `latest`.

| البديل | ليه لأ |
|---|---|
| `image_tag` variable و `terraform apply` لكل deploy | deploy بـ admin، بطيء، وبيخلط تغييرات الـ infra بالـ releases |
| الـ CI يملك كل حاجة (CLI scripts) | مفيش plan/review للـ infra، و drift مش مرئي |

**Consequences:** ✅ deploy سريع بصلاحيات ضيقة، و `terraform apply` عمره ما بيعمل rollback للتطبيق. ⚠️ drift مقصود لازم يتوثّق (الـ weights: `listener_weights_managed_externally`). تغيير `image_tag` بعد أول apply مبيعملش حاجة (بيلخبط الناس). تغييرات Terraform على env الـ ECS بتوصل مع الـ CI deploy الجاي بس (`taskdef_source=live`).

**References:** [`infra/terraform/README.md`](../../../infra/terraform/README.md) · [44](44-rolling-instance-refresh.md) · [51](51-ecs-fargate-terraform.md) · [91 §6.3](91-terraform-import-and-drift.md)

### 4.4 ADR-003: Drill SLI منفصل عن الـ SLO الحقيقي

- **Status:** Accepted

**Context:** بنعمل drills كتير على `/sre-lab/error` عشان نختبر الـ alerting. لو الـ drills دي بتحرق الـ error budget الحقيقي، الـ SLO يفقد معناه والـ pager يرن على تمارين.

**Decision:** الـ availability SLI بيستثني `sre-lab.*` و `up` و `health.ready` و `metrics`. الـ drills ليها recording rules خاصة (`job:student_app_sli_drill_errors:ratio_rate*`) و alerts بـ label `drill="true"` بتروح لـ receiver اسمه "drill" مش للـ pager. عشان نحرق الـ budget الحقيقي عن قصد: `SRE_FAULT_ERROR_RATE` (release بايظ على routes حقيقية) أو `error-budget-burn.js MODE=app`. الـ rules متختبرة بـ `promtool test rules` في [`observability-lint.yml`](../../../.github/workflows/observability-lint.yml).

| البديل | ليه لأ |
|---|---|
| مفيش drills | الـ alerting مبيتختبرش لحد أول incident حقيقي |
| silence وقت الـ drill | silence منسي = alert حقيقي ضايع ([76 §8](76-incident-response.md)) |
| drills في environment منفصل بس | مفيدة، بس مش بتختبر الـ pipeline الحقيقي |

**Consequences:** ✅ drills آمنة ومستمرة، والـ routing نفسه متختبر. ⚠️ CloudWatch مش قادر يفصل (الـ ALB مالوش path dimension): drill على الـ ALB هيشغّل `slo-fast-burn` ويبعت email — اعمل mute للـ SNS subscription أو اقبل ده. وفيه مجموعتين rules لازم يفضلوا متزامنين.

**References:** [CONVENTIONS §5](../CONVENTIONS.md) · [73](73-slo-error-budget-burn-rate.md) · [`slo-burn-rate.yml`](../../../observability/prometheus/rules/slo-burn-rate.yml)

### 4.5 ADRs تانية تستاهل تكتبها

| القرار | الملخص | المرجع |
|---|---|---|
| `serversideup/php` fpm-nginx كـ base image | nginx + FPM في container واحد تحت S6: deploy unit/بورت/health واحد، non-root UID 82، `SIGQUIT`، `AUTORUN_*`؛ التمن: مش "process واحد لكل container" وأي volume لازم writable لـ 82 | [10 §5.1](10-containerize-app.md) |
| S3 native locking (`use_lockfile`) من غير DynamoDB | مورد أقل، lock object `<key>.tflock` | [90](90-terraform-deep-dive.md) |
| مفيش `terraform_remote_state` بين الـ stacks | الـ lifecycles مستقلة؛ المشاركة بالأسماء والـ data sources و SSM | [`infra/terraform/README.md`](../../../infra/terraform/README.md) |
| `AutoRollback=false` في الـ instance refresh | الـ release في SSM مش في الـ launch template؛ الـ workflow بيرجّع الـ pointer | [44](44-rolling-instance-refresh.md) |
| الـ migrations خطوة منفصلة مرة لكل release | `AUTORUN_LARAVEL_MIGRATION=false`؛ compose `run --rm` / ECS one-off task / Helm hook | [CONVENTIONS §2](../CONVENTIONS.md)، [52](52-ecs-migrations-and-exec.md) |
| PodMonitor بدل ServiceMonitor على EKS | واحد بس؛ الاتنين = double counting | [68](68-k8s-canary-argo-rollouts.md) |

## 5) CV bullets (بأرقام)

> ⚠️ **متكتبش رقم مقستهوش.** الأرقام اللي جاية من الـ repo (عدد الـ workflows، الـ thresholds، الـ SLOs) ثابتة؛ اللي بين `< >` قيسه بنفسك من الـ probe/k6/Cost Explorer قبل ما تكتبه.

- Designed zero-downtime delivery for a production Laravel app on **4 AWS platforms** (EC2/Docker Compose, ASG + ALB, ECS Fargate, EKS) covering rolling, blue/green, canary and linear strategies with automatic rollback; every release verified at **0 failed requests** by a probe-based CI gate.
- Built progressive delivery with automated canary analysis (nginx metric gate, CloudWatch alarm gates, Argo Rollouts + Prometheus) that aborts a bad release at the **first 10% step (~30 s)** and returns 100% of traffic to stable.
- Defined SLOs (**99.5%** availability, **95% < 300 ms**) with multi-window burn-rate alerts (**14.4× / 6× / 1×**) unit-tested with promtool, a separate drill SLI, a runbook per alert, and k6 thresholds equal to the SLOs as a CI performance gate.
- Codified AWS in Terraform — **bootstrap + 12 reusable modules + 6 ephemeral stacks** — with S3-native state locking, PR plans through a read-only OIDC role, approval-gated apply, and Console-built resources imported to zero-diff.
- Removed long-lived cloud credentials: GitHub OIDC roles scoped by repo/branch/environment, SSM Run Command / Session Manager instead of SSH, secrets from SSM Parameter Store via ECS secrets and External Secrets.
- Kept lab cost at **~$0.03–0.23/hour per environment** through NAT-free networking, ephemeral stacks, tag-based leftover detection, budgets and anomaly alerts; `<N>`% lower than an always-on equivalent.
- Hardened the supply chain: non-root multi-stage image, Trivy gating, SBOM, keyless cosign signatures, immutable ECR tags and digest-pinned promotion lab → production (**16 GitHub Actions workflows**).
- Measured Recreate downtime at `<N>` s per deploy and replaced it with blue/green (0 failed requests, rollback in `<N>` s); found capacity knee at `<N>` req/s with k6 breakpoint tests.

## 6) بنك الأسئلة (50 سؤال Senior DevOps/SRE)

جرّب تجاوب بصوت عالي قبل ما تفتح الإجابة. الإجابة المثالية: **المفهوم ← مثال من الـ repo ← الـ trade-off**.

### 6.1 Linux و Networking

<details><summary>1. إزاي <code>nginx -s reload</code> بيغيّر الـ routing من غير ما يقطع ولا request؟</summary>

الـ master بيقرا الـ config، يعمل `nginx -t` ضمنياً، يشغّل workers جديدة، ويبعت للقديمة graceful shutdown: تبطّل تقبل connections جديدة وتكمّل اللي معاها. الـ listening socket مبيتقفلش. السكريبتات بتعمل `nginx -t -q` الأول وتعمل die قبل الـ switch لو فشل. → [23](23-bluegreen-single-host.md)

</details>

<details><summary>2. ليه الـ container بيسمع على 8080 مش 80؟</summary>

الـ process non-root (`www-data` UID 82) ومينفعش يعمل bind على بورت أقل من 1024 من غير capability. الـ host أو الـ LB بيعمل map (`80:8080` في compose، TG على 8080 في ECS/EKS، host port 80 في ASG). → [10](10-containerize-app.md)

</details>

<details><summary>3. إيه سلسلة الـ signals في graceful shutdown للتطبيق ده؟</summary>

`STOPSIGNAL SIGQUIT` = graceful لـ PHP-FPM (يخلّص الـ in-flight). Compose: `stop_grace_period: 30s` ثم SIGKILL. ECS: الـ ALB يعمل drain (`deregistration_delay` 30s) ثم SIGQUIT ثم `stopTimeout`. K8s: `preStop` sleep 10s (عشان الـ endpoints تتشال) ثم SIGQUIT، و `terminationGracePeriodSeconds: 40`. → [53](53-ecs-rolling-circuit-breaker.md)، [66](66-k8s-rolling-recreate.md)

</details>

<details><summary>4. ليه الـ upstreams في nginx فيها <code>resolve</code>؟</summary>

nginx بيعمل resolve لأسماء الـ upstream مرة عند الـ start. لما slot يتعمله recreate وياخد IP جديد، nginx هيفضل يبعت على IP ميت. `resolver 127.0.0.11 valid=5s` (Docker DNS) + `server app_blue:8080 resolve` + `zone` = re-resolve لوحده (nginx ≥ 1.27.3 open source). → [23](23-bluegreen-single-host.md)

</details>

<details><summary>5. إيه اللي بيمنع 502 لما instance/task بيخرج من الـ ALB؟</summary>

الترتيب: deregister → الـ target "draining" (مفيش requests جديدة، والقديمة تكمّل لحد `deregistration_delay`) → وبعدها بس الـ stop signal. لو الـ app اتقفل قبل الـ drain يخلص = 502. وعلى K8s: `preStop` sleep + ALB readiness gate عشان الـ pod الجديد ميتحسبش Ready قبل ما الـ target يبقى healthy. → [53](53-ecs-rolling-circuit-breaker.md)، [63](63-eks-load-balancer-controller-ingress.md)

</details>

### 6.2 Containers

<details><summary>6. اشرح الـ Dockerfile بتاعك في 30 ثانية.</summary>

3 stages: `vendor` (composer `--no-dev` بنفس PHP image عشان نفس الـ extensions) → `assets` (`npm ci` + vite) → `runtime` (`serversideup/php` fpm-nginx، APCu للـ metrics، non-root، 8080، `SIGQUIT`). الـ config كله env وقت التشغيل (12-factor)، والـ caches بتتعمل عند الـ start بالـ env الحقيقي (`AUTORUN_ENABLED`). → [10](10-containerize-app.md)

</details>

<details><summary>7. الفرق بين <code>/up</code> و <code>/ready</code>؟ وليه الـ liveness مبيلمسش الداتابيز؟</summary>

`/up` = liveness (الـ process عايش، من غير DB)؛ فشله = restart. `/ready` = readiness (DB ping + version/color)؛ فشله = يتشال من الـ LB من غير restart. لو الـ liveness فيه DB، وقوع الداتابيز = restart لكل الـ pods مع بعض (cascade) ومش هيصلّح حاجة. → [12](12-sre-lab-endpoints-and-local-observability.md)، [66](66-k8s-rolling-recreate.md)

</details>

<details><summary>8. ليه tags immutable و promotion بالـ digest؟</summary>

الـ tag = git SHA7 و ECR `IMMUTABLE` (الكتابة فوقه = `ImageTagAlreadyExistsException`)، فاللي اتختبر هو اللي بيشتغل. `release-promote.yml` بيحوّل الـ tag لـ digest في lab، و production بيرفض يشتغل لو الـ tag مبقاش بيشاور على نفس الـ digest — "promote the bytes". → [30](30-ci-github-actions.md)، [34](34-environments-approvals-promotion.md)

</details>

<details><summary>9. ليه الـ migrations مش بتجري مع كل container عند الـ boot؟</summary>

N replicas = N migrations في نفس اللحظة (race، locks)، والـ release الفاشل ممكن يغيّر الـ schema قبل ما حد يحكم عليه. القاعدة: مرة لكل release كخطوة منفصلة قبل الـ traffic (`AUTORUN_LARAVEL_MIGRATION=false`): compose `run --rm`، ECS one-off task (على on-demand Fargate حتى لو الـ service على Spot)، Helm hook Job. → [CONVENTIONS §2](../CONVENTIONS.md)، [52](52-ecs-migrations-and-exec.md)

</details>

<details><summary>10. إزاي تأمّن الـ image والـ pipeline؟</summary>

non-root، base صغيرة، Trivy على HIGH/CRITICAL، SBOM، توقيع keyless بـ cosign على الـ digest، actions متثبتة بالـ full SHA (الـ tags بتتحرك)، Dependabot للـ base image، و Hadolint. وفي الـ runtime: `runAsNonRoot`، drop ALL caps، Pod Security `restricted`. → [11](11-image-hardening.md)، [82](82-supply-chain-security.md)

</details>

### 6.3 AWS

<details><summary>11. الـ target group health check بيفشل والتطبيق شغال. هتدوّر على إيه؟</summary>

(1) البورت: stack 40 الـ TG على **80** (host port، `docker run -p 80:8080`)، stack 50/EKS على **8080** (ip targets). (2) `/ready` بيرجّع 503: DB مش reachable، أو `SRE_FAULT_UNHEALTHY`، أو drain يدوي. (3) الـ SG بتاع الـ targets مش سامح من الـ ALB SG. (4) الـ matcher `200` بس. (5) grace period/warmup قصير. → [42](42-alb-asg-launch-template.md)، [51](51-ecs-fargate-terraform.md)

</details>

<details><summary>12. ECS execution role مقابل task role؟</summary>

الـ execution role للـ agent: pull من ECR، يجيب الـ secrets من SSM (+ `kms:Decrypt`)، يكتب logs. الـ task role للتطبيق نفسه (AWS SDK) و ECS Exec. execution ناقص = الـ task مبيقومش (`ResourceInitializationError` / `CannotPullContainerError`)؛ task ناقص = AccessDenied جوه التطبيق. → [50](50-ecs-fargate-console.md)

</details>

<details><summary>13. ليه <code>AutoRollback=false</code> في الـ instance refresh بتاعك؟</summary>

الـ release مش في الـ launch template؛ هو في SSM parameter (`deploy/<color>/IMAGE_URI`) بيتقري عند الـ boot. الـ auto rollback بتاع AWS بيرجّع الـ launch template — اللي متغيرش — فالـ instances البديلة هتبوت بالـ image البايظة تاني. الـ workflow بيرجّع الـ pointer القديم ويعمل refresh تاني (deterministic). → [44](44-rolling-instance-refresh.md)

</details>

<details><summary>14. الـ ECS circuit breaker بيكشف إيه ومبيكشفش إيه؟</summary>

بيكشف tasks مبتقومش أو بتفشل الـ health checks (threshold ≈ نص الـ desired، أقل حاجة 3) وبيرجّع لآخر deployment `COMPLETED`. **مبيكشفش** error rate أو latency: release بيرجّع 500 على نص الصفحات وهو healthy هيعدّي — ده شغل الـ deployment alarms. وأول deployment مالوش حاجة يرجعلها. → [53](53-ecs-rolling-circuit-breaker.md)

</details>

<details><summary>15. Multi-AZ و automated backups و PITR و manual snapshots — الفرق؟</summary>

Multi-AZ = high availability (failover)، مش backup: الـ `DROP TABLE` بيتنسخ للـ standby. Automated backups + binlogs = PITR جوه الـ retention (7 أيام في المعمل). Manual snapshots بتعيش بعد مسح الـ DB (وبتتحاسب). Cross-region copy = DR. وكل ده محتاج restore drill عشان الـ RTO/RPO يبقوا أرقام مش أمنيات. → [41](41-rds-mysql.md)، [77](77-backup-and-dr.md)

</details>

<details><summary>16. ليه SSM (Session Manager / Run Command) بدل SSH؟</summary>

مفيش inbound port 22، مفيش private key طويل العمر، كل أمر بـ IAM (scoped بالـ tag `Project=student-app`) ومتسجّل في CloudTrail وفي الـ command history، وport forwarding للـ Grafana من غير ما تفتح SG. `deploy-ec2-ssh-build.yml` موجود عن قصد كـ baseline للمقارنة. → [31](31-cd-ec2-ssh-build-on-server.md)، [32](32-cd-ec2-ecr-ssm.md)

</details>

### 6.4 Infrastructure as Code

<details><summary>17. الـ state locking عندك شغال إزاي؟</summary>

S3 native: `use_lockfile = true` بيعمل object `<key>.tflock` جنب الـ state وقت الـ apply (GA في Terraform 1.11) — من غير DynamoDB. apply تاني بيفشل بـ `Error acquiring the state lock` ومعاه Who/Operation. `force-unlock` آخر حل، وبعد ما تتأكد إن مفيش apply شغال. → [02](02-aws-account-setup.md)، [90](90-terraform-deep-dive.md)

</details>

<details><summary>18. ليه الـ stacks مش بتقرا state بعض (<code>terraform_remote_state</code>)؟</summary>

بيربط الـ lifecycles: مسح stack يكسر plan التاني. البديل: أسماء deterministic (`student-app-<env>-*`)، `data` sources، و SSM للقيم المشتركة، و bootstrap outputs → GitHub variables. → [`infra/terraform/README.md`](../../../infra/terraform/README.md)

</details>

<details><summary>19. امتى تستخدم <code>ignore_changes</code>؟ وإيه مشكلته؟</summary>

لما فيه مالك تاني للقيمة: الـ CI (الـ image)، CodeDeploy/CI (listener weights)، الـ ASG (desired). مشكلته إنه مينفعش يبقى conditional، فالـ `alb` module عامل نسختين من الـ listener بـ `count` (`weights_managed_externally`). وكمان بيخبّي drift حقيقي لو استخدمته بزيادة. → [90](90-terraform-deep-dive.md)، [91](91-terraform-import-and-drift.md)

</details>

<details><summary>20. ورثت infra معمولة من الـ Console. هتعمل إيه؟</summary>

قرار الأول: import ولا إعادة إنشاء (stateful؟ downtime مقبول؟). بعدين `import` blocks + `terraform plan -generate-config-out`، تنضيف الكود ونقله للـ modules، لحد zero-diff، وبعدين `-refresh-only` و drift check دوري. والـ drift المقصود (اللي الـ CI بيملكه) يتوثّق. → [91](91-terraform-import-and-drift.md)

</details>

<details><summary>21. إزاي تشغّل Terraform في الـ CI بأمان؟</summary>

plan على كل PR بـ role read-only (`ReadOnlyAccess` + decrypt) كـ comment؛ apply/destroy بـ dispatch ورا environment `lab` (required reviewers) بالـ admin role، و apply للـ plan المحفوظ بالظبط؛ `concurrency` من غير cancel (apply مقتول = lock + infra نص نص). وانتبه: ملف الـ plan فيه secrets plain text، و `sub` بتاع environment مفيهوش branch. → [92](92-terraform-in-ci.md)

</details>

### 6.5 CI/CD

<details><summary>22. OIDC بين GitHub و AWS بيشتغل إزاي، وإيه أشهر غلطة؟</summary>

الـ job (بـ `id-token: write`) بياخد JWT من GitHub؛ AWS بيتحقق من التوقيع والـ conditions (`aud = sts.amazonaws.com`، `sub` = `repo:<owner>/<repo>:ref:refs/heads/<branch>` أو `:environment:<name>` أو `:pull_request`) ويرجّع credentials لساعة. أشهر غلطة: job فيه `environment:` فالـ `sub` بيبقى environment مش branch → `Not authorized to perform sts:AssumeRoleWithWebIdentity`؛ وأخطر غلطة: role بيثق في environment من غير ما الـ environment يتقفل على branches معينة. → [30](30-ci-github-actions.md)، [80](80-iam-oidc-least-privilege.md)

</details>

<details><summary>23. يعني إيه "build once, deploy many" عندك؟</summary>

`ci.yml` بيبني ويعمل scan مرة ويعمل push بالـ SHA. كل deploy workflow بيتأكد إن الـ tag موجود في ECR ومبيبنيش (`deploy-eks.yml`، `deploy-ecs.yml`، `deploy-ec2-ssm.yml` بيحوّل الـ tag لـ digest). عكسها `deploy-ec2-ssh-build.yml`: كل سيرفر بيبني image مختلفة شوية ومحدش عمل لها scan. → [32](32-cd-ec2-ecr-ssm.md)

</details>

<details><summary>24. ليه <code>cancel-in-progress: false</code> في الـ deploy workflows؟</summary>

deploy بيحرّك traffic (weights، refresh، CodeDeploy) لو اتقتل في النص يسيب حالة نص نص (weights 25/75، refresh suspended، lock). الـ deploys بتتعمل queue مش cancel؛ الـ CI بس اللي بيعمل cancel للـ runs القديمة. → [32](32-cd-ec2-ecr-ssm.md)، [58](58-ecs-github-actions-vs-codepipeline.md)

</details>

<details><summary>25. GitHub Actions ولا CodePipeline؟</summary>

GitHub Actions: الكود هناك أصلاً، ecosystem كبير، OIDC، environments. CodePipeline: كل حاجة جوه AWS (compliance، private networking)، service roles من غير credentials برّه، `QUEUED`. الـ repo عامل نفس الـ ECS deploy بالاتنين (`deploy-ecs.yml` و stack 36) — والفرق المهم: الـ `ECS` action بيعمل copy لـ revision الـ service الحالية، فتغييرات Terraform على الـ env مبتوصلش. → [58](58-ecs-github-actions-vs-codepipeline.md)

</details>

<details><summary>26. إزاي تعمل approvals و promotion لـ production؟</summary>

GitHub environments: `production` بـ required reviewers + wait timer + protected branches، وقيم لكل environment (`EC2_INSTANCE_ID`، `APP_URL`، `ENV_NAME`). نفس الـ image بالـ digest، ونفس الـ code path (`deploy-ec2-ssm.yml` كـ `workflow_call`)، و git tag `release-<date>-<sha>` بعد النجاح. → [34](34-environments-approvals-promotion.md)

</details>

### 6.6 Deployments

<details><summary>27. اديني مثال حقيقي لـ migration بتكسر الـ zero-downtime.</summary>

`add_pricing_to_subscriptions_table` بيعمل `price`/`commission` NOT NULL **وبيمسح** `amount` في نفس الخطوة. الكود القديم (لسه شغال في B/G أو rolling) بيكتب `amount` ومبيكتبش `price` → يقع من لحظة الـ migration، والـ rollback يرجّعك لكود واقع. الحل expand/contract على كذا release. → [23 §5.5](23-bluegreen-single-host.md)، [95](95-zero-downtime-db-migrations.md)

</details>

<details><summary>28. إيه الـ <code>BROKEN</code> marker وليه موجود؟</summary>

بعد deploy فاشل الـ traffic عمره ما اتحرك، والـ slot التاني فيه الإصدار البايظ. `rollback.sh` العادي كان هيقلب عليه! أي `start_slot` فاشل أو canary abort بيسجّل `BROKEN=<color>`، و `rollback.sh` بيرفض يقلب عليه ("nothing to roll back to")، وبيعمل smoke قبل أي تحويل. الـ marker بيتمسح لما نفس اللون ينجح. → [23 §9](23-bluegreen-single-host.md)

</details>

<details><summary>29. امتى الـ canary analysis بيدّي قرار غلط؟</summary>

traffic قليل (sample صغير/NaN)، metric مش بتقيس اللي اتكسر (latency بس والـ gate على 5xx)، scraping بايظ أو `METRICS_TOKEN` (gate أعمى)، sticky sessions بتوزّع غلط، ومقارنة بـ threshold ثابت بدل baseline. الحلول: `MIN_REQUESTS`، synthetic traffic، أكتر من metric، fail closed. → [24](24-canary-single-host.md)، [68](68-k8s-canary-argo-rollouts.md)

</details>

<details><summary>30. Canary مقابل A/B مقابل feature flags؟</summary>

Canary أداة تشغيلية: requests عشوائية، error rate/latency، قرار أوتوماتيك في دقايق. A/B أداة منتج: مستخدمين ثابتين (sticky)، business metrics + statistical significance، أيام. Feature flag: بيفصل الـ deploy عن الـ release جوه الكود، kill switch من غير deploy. ممكن الاتنين: canary للإصدار، وجواه flag للتجربة. → [26](26-ab-testing-shadow-feature-flags.md)

</details>

<details><summary>31. Blue/green على host واحد مقابل blue/green بـ ALB؟</summary>

نفس الفكرة (deploy على idle، test، switch، rollback فوري)، بس الـ host الواحد single point of failure، والـ capacity محدودة، والداتابيز مشتركة. على AWS: TGs + `modify-listener` أو CodeDeploy/ECS native، والتمن ضعف الـ capacity وقت الـ deploy. → [23](23-bluegreen-single-host.md)، [45](45-bluegreen-two-asgs.md)

</details>

### 6.7 Kubernetes

<details><summary>32. إزاي تضمن RollingUpdate من غير ولا request فاشل؟</summary>

`maxUnavailable: 0` و `maxSurge: 1`، readiness على `/ready`، ALB readiness gate (`elbv2.k8s.aws/pod-readiness-gate-inject=enabled`)، `preStop` sleep 10s، `terminationGracePeriodSeconds: 40`، `SIGQUIT`، PDB للـ drains. `k8s-integration.yml` بيثبتها بـ probe بـ 0 failures. → [66](66-k8s-rolling-recreate.md)

</details>

<details><summary>33. EKS Pod Identity مقابل IRSA؟</summary>

الاتنين بيدّوا الـ pod صلاحيات AWS من غير keys. IRSA: OIDC provider لكل cluster + annotation على الـ ServiceAccount + trust policy فيها الـ cluster. Pod Identity: association من الـ EKS API و agent add-on، والـ trust policy عامة (`pods.eks.amazonaws.com`) فالـ role ينفع لأكتر من cluster. الـ repo بيستخدم Pod Identity لـ LBC و ESO و Karpenter. → [62](62-eks-terraform.md)

</details>

<details><summary>34. ESO بيحل إيه؟ ولو الـ sync وقف؟</summary>

الـ secrets تفضل في SSM والـ ExternalSecret بيعمل K8s Secret (`creationPolicy: Owner`) ويحدّثه كل `refreshInterval`. لو وقف: `kubectl describe externalsecret` (AccessDenied؟ path غلط؟ الـ store conditions؟)، الـ Secret الموجود بيفضل والـ pods الشغالة مش متأثرة، و force-sync بـ annotation. والـ pods محتاجة `rollout restart` عشان تاخد القيمة الجديدة. → [64](64-eks-external-secrets.md)

</details>

<details><summary>35. HPA و Karpenter بيشتغلوا مع بعض إزاي؟</summary>

HPA بيزوّد الـ pods على الـ CPU (metrics-server؛ 2–6، 70%) — محتاج `requests` صح. لو مفيش مكان، الـ pods بتبقى Pending و Karpenter بيعمل nodes مناسبة (NodePool/EC2NodeClass) ويقفلها لما تفضى. الـ k6 `autoscale-cpu.js` على `/sre-lab/cpu` بيقيس الوقت. → [6A](6A-hpa-karpenter-under-load.md)

</details>

<details><summary>36. الـ canary على EKS بيعمل abort لكل release حتى السليم. ليه؟</summary>

غالباً الـ analysis مش لاقي series: scraping مش شغال (الـ PodMonitor مش متركّب)، أو `METRICS_TOKEN` اتحط في SSM فالـ PodMonitor بياخد 403. ولو فعّلت ServiceMonitor جنب الـ PodMonitor = double counting في الـ SLO rules. → [68](68-k8s-canary-argo-rollouts.md)، [64](64-eks-external-secrets.md)

</details>

### 6.8 Observability و SRE

<details><summary>37. الـ SLOs بتاعتك إيه والـ error budget كام؟</summary>

Availability 99.5% على 30 يوم (non-5xx على app routes) → budget 0.5% ≈ 3h 36m. Latency 95% أسرع من 300ms، و p99 < 1s. نفس الأرقام في k6 و Prometheus و CloudWatch. → [73](73-slo-error-budget-burn-rate.md)

</details>

<details><summary>38. ليه multi-window burn-rate alerts؟</summary>

14.4× على 1h **و** 5m → page؛ 6× على 6h و 30m → page؛ 1× على 3d و 6h → ticket. الـ long window بيضمن إن الحرق حقيقي، والـ short بيخلّي الـ alert يتحل بسرعة بعد الـ fix. الـ trade-off: 10% errors بياخد ~43 دقيقة للـ fast tier، و outage كامل ~4 دقايق — عشان كده الـ canary ضروري للحاجات الصغيرة. → [73](73-slo-error-budget-burn-rate.md)

</details>

<details><summary>39. إزاي تعمل drills من غير ما تحرق الـ budget؟</summary>

Drill SLI منفصل: الـ SLI الحقيقي بيستثني `sre-lab.*`، والـ drills ليها recording rules و alerts بـ `drill="true"` لـ receiver منفصل. على CloudWatch مينفعش (مفيش path dimension). → [CONVENTIONS §5](../CONVENTIONS.md)، [73](73-slo-error-budget-burn-rate.md)

</details>

<details><summary>40. RED و USE، وليه الـ label اسمه route مش path؟</summary>

RED (Rate، Errors، Duration) للـ services؛ USE (Utilization، Saturation، Errors) للموارد. الـ label = اسم الـ Laravel route (`students.show`) مش الـ URL (`/students/123`) عشان الـ cardinality متنفجرش. والـ counters في APCu مشتركة بين workers الـ FPM، والـ scrape لكل container. → [71](71-metrics-dashboards.md)

</details>

<details><summary>41. أنواع الـ load tests وإيه علاقتها بالـ SLO؟</summary>

smoke (شغال؟)، load (الـ SLO عند الـ traffic المتوقع)، stress (إيه يقع الأول)، spike، soak (leaks)، breakpoint (الـ capacity جوه الـ SLO). الـ thresholds = الـ SLOs (`http_req_failed < 0.005`، p95)، و k6 بيخرج 99 لو اتكسرت فالـ CI يفشل (`perf-gate.yml`). → [74](74-load-testing-k6.md)

</details>

### 6.9 Security

<details><summary>42. الـ deploy role بتاعك صلاحياته إيه بالظبط؟</summary>

ECS update/run-task + PassRole لـ `student-app-lab-*` بس، SSM Run Command على instances عليها `Project=student-app`، params `/student-app/*/deploy/*`، ASG refresh، listener weights، CodeDeploy، `eks:DescribeCluster`، alarms. ومش بيثق غير في main/master و `environment:{lab,production}`. الـ Terraform admin role منفصل ورا approval. → [80](80-iam-oidc-least-privilege.md)

</details>

<details><summary>43. إزاي تعمل rotation لـ <code>APP_KEY</code> من غير ما الكل يعمل logout؟</summary>

`APP_PREVIOUS_KEYS` = القديم، `APP_KEY` = الجديد، roll لكل الـ replicas مع بعض، re-encrypt للداتا المشفرة، وبعد ما الـ sessions القديمة تنتهي امسح القديم. تغييره فجأة = logout جماعي و 419 وداتا مش بتتقري. → [81](81-secrets-management.md)

</details>

<details><summary>44. ليه <code>trustProxies</code> مهم ورا الـ ALB؟</summary>

الـ TLS بيخلص على الـ ALB والـ request بيوصل PHP كـ HTTP. من غير ما Laravel يثق في `X-Forwarded-Proto`، الروابط والـ redirects بتطلع `http://` → mixed content، redirect loops، والـ POST يتحول GET بعد redirect. الـ repo: `trustProxies(at: '*', headers: HEADER_X_FORWARDED_PROTO)` — آمن لأن الـ SG بيسمح من الـ ALB بس. → [83](83-edge-security-waf-https.md)

</details>

<details><summary>45. إزاي تحمي <code>/metrics</code> و <code>/sre-lab/*</code>؟</summary>

طبقات: الـ ALB بيرد fixed 404 على `/metrics` (ونفس الحاجة `blockPaths` في الـ Ingress، و nginx الـ lb)، `METRICS_TOKEN` اختياري، `/sre-lab/*` بيرجّع 404 لو `SRE_LAB_ENABLED` مش `true` و 403 من غير `X-Lab-Token`، و WAF (managed rules + rate-based). → [83](83-edge-security-waf-https.md)

</details>

### 6.10 Incident response و Behavioral

<details><summary>46. أول 5 دقايق في page؟</summary>

Ack، وأعلن incident لو مكمّل. "حصل deploy في آخر ساعة؟" (`student_app_app_info`، `status.sh`، `gh run list`، ECS deployments، `get-parameter-history`). مين بيفشل: `by (route, status)` و `by (version, color)`. deploy حديث = **rollback فوراً** من غير ما تستنى تفهم. وبعدين comms. → [76](76-incident-response.md)

</details>

<details><summary>47. rollback ولا fix-forward؟</summary>

Rollback الافتراضي لو الـ release الأخير هو السبب والـ rollback آمن (الـ schema متوافق). Fix-forward لو الـ rollback نفسه خطر (migration مش backward compatible)، أو الـ fix صغير ومتختبر وأسرع. القاعدة: mitigation أولاً، والـ root cause بعدين. → [76](76-incident-response.md)، [95](95-zero-downtime-db-migrations.md)

</details>

<details><summary>48. إيه اللي بيخلّي الـ postmortem مفيد؟</summary>

Blameless (النظام سمح بالغلطة)، timeline بالـ UTC، impact بأرقام (budget اتصرف قد إيه)، contributing factors مش "root cause" واحد، و action items ليها owner وميعاد — زي "ليه الـ gate ما مسكوش قبل المستخدمين؟". → [76 §13.1](76-incident-response.md)

</details>

<details><summary>49. (STAR) احكي عن مرة حاجة اتكسرت بسببك وصلّحتها.</summary>

مثال من الـ break-it بتاع المعمل (احكيه زي ما حصل معاك): **S:** canary gate على single host بيقرا `/metrics` بتاع الـ slot. **T:** نقفل `/metrics` بـ `METRICS_TOKEN`. **A:** بـ token غلط في الـ shell الـ scrape رجع 403 → `0 0` → كل canary اتعمله abort ("no traffic reached the canary") حتى السليم. فهمت إن الـ gate fail-closed (أحسن من promote أعمى)، وإن الـ token لازم يجي من نفس المصدر اللي الـ slots بتقرا منه (`slot_counters` بيقراه من `APP_ENV_FILE`)، وعملت نفس المراجعة على EKS (الـ PodMonitor والـ 403). **R:** الـ gate بيشتغل بالـ token، والحالة دي بقت تمرين ثابت. → [24](24-canary-single-host.md)، [68](68-k8s-canary-argo-rollouts.md)

</details>

<details><summary>50. (STAR) احكي عن مرة وفّرت فلوس من غير ما تضر الـ reliability.</summary>

**S:** معمل AWS بـ 4 منصات. **T:** نجرّب كل حاجة بميزانية صغيرة. **A:** شيلت الـ NAT افتراضياً (public subnets + SG من الـ ALB بس + S3 gateway endpoint)، stacks مؤقتة بـ apply/destroy يومي، retention على الـ logs، ECR lifecycle، فحص بالـ tags، Budgets + Anomaly. **R:** `<N>`$/شهر بدل `<N>`$ لو كله شغال 24/7 — وأرقام الساعة: stack 20 ≈ $0.03، 50 ≈ $0.11، 60 ≈ $0.23. → [97](97-cost-and-teardown.md)

</details>

## 7) التحقق (Verify)

- [ ] الـ README فيه hero + badges شغالة + الرسم + "Start here"
- [ ] الـ 3 stories متسجّلين (GIF/فيديو) ومعاهم لينكات GitHub runs خضرا
- [ ] 3 ADRs على الأقل مكتوبين بالقالب
- [ ] الـ CV فيه 4–6 bullets بأرقام انت قستها
- [ ] جاوبت على الـ 50 سؤال بصوت عالي، وكل إجابة فيها مثال من الـ repo

## 8) أسئلة Interview (عن الـ portfolio نفسه)

<details><summary>"ده lab مش production. ليه أصدّق إنه بيعكس شغل حقيقي؟"</summary>

التطبيق حقيقي (مش hello world) والقيود حقيقية: داتابيز مشتركة، migrations، sessions، CSRF. كل ادعاء ليه أمر بيثبته وبيتشغّل على كل push (probe، k6، promtool). والأهم: الـ trade-offs والـ failure modes اللي لقيتها (gate أعمى، drill بيحرق CloudWatch budget، weights drift) هي نفس اللي بتحصل في production.

</details>

<details><summary>"لو هتبدأ من الصفر لشركة، هتاخد إيه من ده؟"</summary>

ECS Fargate + rolling/circuit breaker + deployment alarms كبداية، وبعدين native canary. OIDC و SSM من أول يوم. SLO واحد أو اتنين بـ burn-rate alerts و runbooks. Terraform بـ bootstrap/stacks وplan على الـ PR. و EKS بس لما يبقى فيه سبب وفريق.

</details>

<details><summary>"إيه أكتر حاجة اتعلمتها؟"</summary>

إن الـ health checks مش بتقيس اللي المستخدم شايفه، والـ migrations هي أصعب جزء في الـ zero-downtime، وإن كل gate لازم تعرف هو fail-open ولا fail-closed. وإن الـ teardown جزء من التصميم مش حاجة بتتعمل في الآخر.

</details>

## 9) Checklist

- [ ] الـ README hero section + الرسم
- [ ] 3 demo stories متسجّلة
- [ ] 3+ ADRs
- [ ] CV bullets بأرقام حقيقية
- [ ] بنك الأسئلة متراجع مرتين (مرة قراية ومرة بصوت عالي من غير ما تفتح الإجابات)
- [ ] الجداول في [96](96-comparison-matrices.md) والـ cheat sheet في [99](99-cheatsheets-and-troubleshooting.md) قريبين يوم الـ interview
