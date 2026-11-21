# 69 — GitOps بـ Argo CD

> **الهدف في سطر:** الـ git يبقى هو الـ desired state والـ cluster يتبعه لوحده: **Argo CD** بيعمل sync للـ chart بـ `values-eks.yaml` (automated، prune، selfHeal)، الـ **app-of-apps** بيركّب الـ add-ons بـ versions متثبتة، والـ release = **PR** بيفتحه `deploy-eks.yml` mode **`gitops-bump`** (من غير أي access للـ cluster)، والـ rollback = **`git revert`** — مع قاعدة **owner واحد لكل add-on**.
> **المستوى:** Advanced · **الوقت:** ~4 ساعات · **التكلفة التقريبية:** نفس [62](62-eks-terraform.md) + Argo CD (غالباً node زيادة)
> **بيعتمد على:** [62](62-eks-terraform.md) · [65 — Helm chart](65-helm-chart.md) · [68 — Canary](68-k8s-canary-argo-rollouts.md) · [34 — Environments](34-environments-approvals-promotion.md) · **الملفات في الـ repo:** [`k8s/argocd/README.md`](../../../k8s/argocd/README.md) · [`application.yaml`](../../../k8s/argocd/application.yaml) · [`app-of-apps.yaml`](../../../k8s/argocd/app-of-apps.yaml) · [`apps/`](../../../k8s/argocd/apps/student-app.yaml) ([`aws-load-balancer-controller.yaml`](../../../k8s/argocd/apps/aws-load-balancer-controller.yaml) · [`external-secrets.yaml`](../../../k8s/argocd/apps/external-secrets.yaml) · [`argo-rollouts.yaml`](../../../k8s/argocd/apps/argo-rollouts.yaml) · [`kube-prometheus-stack.yaml`](../../../k8s/argocd/apps/kube-prometheus-stack.yaml) · [`student-app.yaml`](../../../k8s/argocd/apps/student-app.yaml)) · [`values-eks.yaml`](../../../k8s/helm/student-app/values-eks.yaml) · [`.github/workflows/deploy-eks.yml`](../../../.github/workflows/deploy-eks.yml) · [`infra/terraform/stacks/60-eks/addons.tf`](../../../infra/terraform/stacks/60-eks/addons.tf)

## 1) الفكرة (Concepts)

في [65](65-helm-chart.md)/[68](68-k8s-canary-argo-rollouts.md) الـ CI كان بيعمل `helm upgrade` **على** الـ cluster (push model): الـ CI محتاج credentials قوية للـ cluster، واللي في الـ cluster ممكن يختلف عن الـ git (حد عمل `kubectl edit`). **GitOps**: الحالة المطلوبة declarative في git (versioned، reviewed)، و agent **جوه** الـ cluster بيسحبها (pull) ويفضل يصلّح أي فرق.

| المصطلح | المعنى |
|---|---|
| `Application` | "الـ source ده (repo/path/chart + values) → الـ destination ده (cluster/namespace)" |
| `syncPolicy.automated` | sync أوتوماتيك لما الـ git يتغيّر؛ `prune: true` يمسح اللي اتشال من git؛ `selfHeal: true` يرجّع أي تعديل يدوي |
| Sync status / Health | Synced/OutOfSync (الـ git مقابل الـ live) · Healthy/Progressing/Degraded/Suspended (Argo بيفهم الـ `Rollout` كمان) |
| Sync waves / hooks | ترتيب جوه الـ sync (`argocd.argoproj.io/sync-wave`)؛ hooks (`PreSync`/`Sync`/`PostSync`) زي الـ migration Job |
| App of apps | `Application` بيشاور على folder فيه `Application`s تانية → bootstrap كامل بـ `kubectl apply` واحد |
| Multi-source | chart من Helm repo + values file من git repo (`$values/...`) |
| `managedNamespaceMetadata` | labels على الـ namespace اللي Argo بيعمله (PSS `restricted`، ALB readiness gate) |
| `resources-finalizer.argocd.argoproj.io` | مسح الـ Application = مسح كل اللي عمله (cascade) |
| One owner per add-on | Terraform `install_addons` **أو** Argo app-of-apps — مش الاتنين |

**إزاي الـ image tag بيتغيّر؟** 3 طرق: (1) **PR bump** في values file (اللي عملناه: review، audit في `git log`، revert)، (2) Argo CD Image Updater (بيكتب في git أو parameters لوحده)، (3) `argocd app set -p image.tag=...` — **ممنوع عندنا**: بيقسم الـ desired state بين git والـ Argo (أو برا git خالص). [`application.yaml`](../../../k8s/argocd/application.yaml) فيه الـ parameters commented بالتحذير ده.

## 2) المعمارية (Architecture)

```text
 developer ──push──► CI (ci.yml، lab-integration، k8s-integration) ──► image <sha> في ECR
                                                                         │
            deploy-eks.yml  mode=gitops-bump (OIDC: ECR describe-images بس، مفيش kubeconfig) ◄┘
                 │ yq: values-eks.yaml → image.repository + image.tag "<sha>"
                 ▼
          PR "deploy(eks): student-app → <sha>"  (branch gitops/student-app-<sha>، labels gitops/deploy)
                 │ review + merge على master
                 ▼
 ┌─ cluster ───────────────────────────────────────────────────────────────────────────────────┐
 │ argocd: Application student-app-lab (app-of-apps → k8s/argocd/apps، recurse false)          │
 │   wave -3  aws-load-balancer-controller 3.6.3 (kube-system)                                  │
 │   wave -2  external-secrets 2.15.0 · argo-rollouts 2.43.12 · kube-prometheus-stack 93.6.1    │
 │   wave  0  student-app  (chart k8s/helm/student-app + values-eks.yaml، targetRevision master)│
 │             poll (~3 دقايق افتراضياً) أو webhook → sync جوه الـ app:                        │
 │               -2 ClusterSecretStore → -1 ExternalSecret + hook ConfigMap → 0 migrate Job     │
 │               (Sync hook) → 1 Rollout ──► canary 10→25→50→100 + Prometheus analysis          │
 │                                              └ bad release → abort → app Degraded            │
 └──────────────────────────────────────────────────────────────────────────────────────────────┘
 rollback = git revert <bump commit> → PR → merge → Argo sync → spec == stable → Healthy
```

## 3) المتطلبات (Prerequisites)

- [ ] الستاك [62](62-eks-terraform.md) شغال (الـ Pod Identity associations للـ LBC و ESO بيتعملوا **دايماً** في [`pod-identity.tf`](../../../infra/terraform/stacks/60-eks/pod-identity.tf) — مستقلين عن `install_addons` — فالـ add-ons اللي Argo بيركّبها بنفس أسماء الـ ServiceAccounts بتاخد الـ IAM).
- [ ] **اختار owner الـ add-ons من الأول** (على cluster جديد):
  - **A)** Terraform: `install_addons = true` + `addons.argo_cd = true` + `addons.kube_prometheus_stack = true` → Argo يملك **التطبيق بس** (`application.yaml`).
  - **B)** Argo: `install_addons = false` → Argo CD نفسه بتركّبه بـ helm (§6.1) → `app-of-apps.yaml`.
- [ ] الـ placeholders اتملت واتعملها commit على `master`:

| الملف | Placeholder | القيمة |
|---|---|---|
| `k8s/argocd/*.yaml`، `apps/*.yaml` | `repoURL: https://github.com/Ahmed-Reda-Ragab/StudentHub.git` | الـ repo بتاعك (لو fork) |
| نفس الملفات | `targetRevision: master` | الـ branch اللي الـ bump PRs بتتعمل عليها |
| [`apps/aws-load-balancer-controller.yaml`](../../../k8s/argocd/apps/aws-load-balancer-controller.yaml) | `clusterName: student-app-lab`، `region: us-east-1`، **`vpcId: vpc-0123456789abcdef0`** | `terraform -chdir=infra/terraform/stacks/60-eks output -raw vpc_id` |
| [`apps/argo-rollouts.yaml`](../../../k8s/argocd/apps/argo-rollouts.yaml) | `AWS_REGION: us-east-1` | الـ region بتاعك |
| [`values-eks.yaml`](../../../k8s/helm/student-app/values-eks.yaml) | `image.repository: 123456789012.dkr...`، `tag: "0000000"` | أول gitops-bump PR بيكتبهم |
| نفس الملف | `config.APP_URL: https://student-app.example.com`، `databaseTo` `10.60.0.0/16` | (الـ `APP_URL` الفعلي من SSM — [64](64-eks-external-secrets.md)) |

- [ ] **GitHub → Settings → Actions → General → Workflow permissions → ✅ Allow GitHub Actions to create and approve pull requests** (من غيرها الـ bump job بيفشل يفتح الـ PR).
- [ ] Private repo؟ سجّله في Argo CD (§6.1).
- الأدوات: `kubectl`، `helm`، `argocd` CLI (اختياري)، `gh`.

## 4) الطريقة الأولى: "Console" — Argo CD UI و GitHub

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
kubectl -n argocd port-forward svc/argo-cd-argocd-server 8080:80        # release "argo-cd" → اسم الـ Service
```

1. افتح `http://localhost:8080` → user `admin` + الباسورد اللي فوق (`server.insecure = true`: الـ TLS المفروض يخلص على ALB/port-forward).
2. **Applications → student-app** → الـ resource tree (Rollout ← ReplicaSets ← Pods، ExternalSecret ← Secret، Ingress)، **App Diff**، **History and Rollback**، و الـ Rollout steps.
3. **GitHub → Actions → Deploy to EKS → Run workflow** (branch `master`) → `mode` = **gitops-bump** → الـ Summary فيه لينك الـ PR → **Files changed**: سطرين في `values-eks.yaml` بس → **Merge**.

## 5) الطريقة التانية: as Code

### 5.1 [`application.yaml`](../../../k8s/argocd/application.yaml)

| Field | القيمة | ليه |
|---|---|---|
| `source.path` / `helm.valueFiles` | `k8s/helm/student-app` / `values-eks.yaml` | الـ desired state = الـ chart + ملف واحد |
| `helm.releaseName` | `student-app` | الأسماء نفسها (`student-app`، `student-app-canary`) زي `deploy-eks.yml` |
| `automated.prune` / `selfHeal` | `true` / `true` | اللي اتشال من git يتشال؛ الـ `kubectl edit` يتعمله revert |
| `managedNamespaceMetadata.labels` | PSS `enforce: restricted` + `elbv2.k8s.aws/pod-readiness-gate-inject: enabled` | نفس اللي الـ workflow بيعمله بـ `kubectl` |
| `syncOptions` | `CreateNamespace=true`، `SkipDryRunOnMissingResource=true` (الـ Rollout/ExternalSecret CRDs ممكن لسه متركبتش)، `PruneLast=true` | |
| `retry` | 5 مرات، backoff 10s ×2 لحد 3m | الـ CRDs/webhooks بتاخد وقت أول مرة |
| finalizer | `resources-finalizer.argocd.argoproj.io` | مسح الـ Application = teardown |

[`apps/student-app.yaml`](../../../k8s/argocd/apps/student-app.yaml) نفس الـ object (نفس الاسم) + `sync-wave: "0"` — **استخدم واحد بس**.

### 5.2 الـ app-of-apps و الـ add-ons

| Child | Chart / version | Namespace | Wave | ملاحظات |
|---|---|---|---|---|
| `aws-load-balancer-controller` | eks-charts 3.6.3 | `kube-system` | -3 | `replicaCount: 2`، SA `aws-load-balancer-controller`، `ServerSideApply` |
| `external-secrets` | 2.15.0 | `external-secrets` | -2 | `installCRDs`، `ServerSideApply` (الـ CRDs أكبر من حد الـ last-applied annotation) |
| `argo-rollouts` | 2.43.12 (v1.10.2) | `argo-rollouts` | -2 | dashboard، `AWS_REGION`، metrics + ServiceMonitor (`SkipDryRunOnMissingResource`) |
| `kube-prometheus-stack` | 93.6.1 | `monitoring` | -2 | **multi-source**: الـ values من `$values/observability/k8s/kube-prometheus-stack-values.yaml` (الـ PodMonitor اللي الـ canary محتاجه) |
| `student-app` | الـ chart من git | `student-app` | 0 | |

> ⚠️ **الـ waves بين الـ Applications بترتّب الإنشاء بس**: Argo CD معندوش health check للـ `Application` kind افتراضياً، فالـ wave -2 مش "بيستنى" الـ LBC يبقى Healthy. اللي بيخلي الـ bootstrap يشتغل: `SkipDryRunOnMissingResource` + `retry`. لو عايز waves blocking: ضيف health customization للـ Application في `argocd-cm` ([`k8s/argocd/README.md`](../../../k8s/argocd/README.md)).

> ⚠️ الـ values مش متطابقة 100% بين الـ owners: الـ LBC `replicaCount` 2 في Argo و 1 في Terraform، و `AWS_REGION`/ServiceMonitor موجودين في Argo app بتاع argo-rollouts ومش في Terraform. تغيير الـ owner = تغيير config.

### 5.3 الترتيب جوه الـ student-app

| Wave / phase | Object | المصدر |
|---|---|---|
| -2 | `ClusterSecretStore student-app-parameter-store` | `clustersecretstore.yaml` |
| -1 | `ExternalSecret student-app-secrets` + hook `ConfigMap student-app-migrate` (Sync hook) | `externalsecret.yaml`، `migrate-job.yaml` |
| 0 | ConfigMap، Services، Ingress، HPA، PDB، NetworkPolicy... (الـ default) + **`Job student-app-migrate`** (Sync hook، `BeforeHookCreation,HookSucceeded`) | |
| 1 | `Rollout student-app` (أو Deployment) | `rollout.yaml` / `deployment.yaml` |

- لما `argocd.argoproj.io/hook` موجود Argo **بيتجاهل كل الـ Helm hooks** — فـ `post-install` الخاص بـ ESO ([64](64-eks-external-secrets.md)) مش بيفرق هنا: الـ Job بيستنى الـ ExternalSecret (wave -1) يبقى Healthy.
- الـ Sync hook بيشتغل مع **كل sync** (مش بس لما الـ image يتغيّر) → `migrate --force` لازم يبقى idempotent (Laravel كده أصلاً).

### 5.4 الـ `gitops-bump` job

| Step | بيعمل إيه |
|---|---|
| `permissions` | `contents: write` (push الـ branch)، `pull-requests: write`، `id-token: write` (ECR check بس) |
| Validate | regex SHA |
| OIDC + ECR | `describe-images` — "Never propose an image that doesn't exist" |
| Bump | `yq -i '.image.repository = strenv(IMAGE_REPOSITORY) \| .image.tag = strenv(IMAGE_TAG) \| .image.tag style="double"'` — mikefarah/yq بيحافظ على الـ comments، والـ tag string بين `"` |
| PR | `peter-evans/create-pull-request@v8.1.3`: `base: ${{ github.ref_name }}` (**شغّله من `master`** — نفس الـ `targetRevision`)، branch `gitops/student-app-<tag>`، `add-paths` الملف ده بس، `delete-branch: true` |

> ⚠️ **PRs اتعملت بـ `GITHUB_TOKEN` مبتشغّلش workflows تانية** — `ci.yml` مش هيجري على الـ bump PR. لو الـ ruleset بيطلب required checks ([30 §6.7](30-ci-github-actions.md))، الـ PR هيفضل مستني. الحل: GitHub App token أو PAT في `token:` بتاع الـ action، أو bypass للـ bot على الـ ruleset (الـ image نفسها اتعملها test في الـ CI قبل الـ push).

## 6) الـ Deploy

### 6.1 Argo CD نفسه

```bash
# A) Terraform: addons.argo_cd = true (release "argo-cd"، namespace "argocd"، server.insecure) — 62 §6
# B) يدوي بنفس الأسماء:
helm upgrade --install argo-cd argo-cd --repo https://argoproj.github.io/argo-helm --version 10.18.2 \
  -n argocd --create-namespace --set 'configs.params.server\.insecure=true'
kubectl -n argocd rollout status deploy/argo-cd-argocd-server

# private repo فقط:
argocd login localhost:8080 --username admin --password "<PASSWORD>" --insecure     # بعد الـ port-forward
argocd repo add https://github.com/<OWNER>/<REPO>.git --username x --password <PAT>
```

### 6.2 Bootstrap

```bash
# A) Terraform يملك الـ add-ons → التطبيق بس
kubectl apply -n argocd -f k8s/argocd/application.yaml

# B) Argo يملك كل حاجة (install_addons = false، الـ vpcId متعمله commit)
kubectl apply -n argocd -f k8s/argocd/app-of-apps.yaml

kubectl -n argocd get applications -w            # Synced/Healthy واحدة ورا التانية
```

أول sync: لو `values-eks.yaml` لسه فيه الـ placeholder image (`123456789012...:0000000`) الـ pods هتبقى `ImagePullBackOff` — طبيعي؛ أول bump بيصلّحه.

### 6.3 Release = PR

```bash
gh workflow run deploy-eks.yml --ref master -f image_tag=<GIT_SHA> -f mode=gitops-bump
gh run watch
gh pr list --label gitops
gh pr diff <PR_NUMBER>                                # سطرين: image.repository و image.tag
gh pr merge <PR_NUMBER> --squash
kubectl -n argocd get application student-app        # OutOfSync → Syncing → Synced
kubectl argo rollouts get rollout student-app -n student-app --watch
```

(الـ refresh الافتراضي polling كل ~3 دقايق؛ للـ تسريع: `argocd app get student-app --refresh` أو GitHub webhook على `/api/webhook`.)

### 6.4 Rollback = revert

```bash
git switch master && git pull
git log --oneline -5 -- k8s/helm/student-app/values-eks.yaml      # تاريخ اللي اتعمله deploy إمتى
git revert <BUMP_COMMIT_SHA> --no-edit
git switch -c revert/student-app-<GIT_SHA> && git push -u origin HEAD
gh pr create --fill --base master && gh pr merge --squash
```

## 7) التحقق (Verify)

```bash
kubectl -n argocd get applications -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REV:.status.sync.revision
argocd app get student-app
argocd app history student-app
argocd app diff student-app                                        # فاضي = الـ cluster == git
kubectl -n student-app get rollout student-app -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

**اختبار الـ selfHeal** (field موجود في الـ desired state):

```bash
kubectl -n student-app patch configmap student-app --type merge -p '{"data":{"LOG_LEVEL":"debug"}}'
kubectl -n student-app get configmap student-app -o jsonpath='{.data.LOG_LEVEL}{"\n"}'   # debug
sleep 20; kubectl -n student-app get configmap student-app -o jsonpath='{.data.LOG_LEVEL}{"\n"}'   # info (Argo رجّعه)
```

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر | المتوقع |
|---|---|---|
| Drift | `kubectl -n student-app edit hpa student-app` (غيّر `maxReplicas`) | يرجع خلال ثواني (selfHeal) — وده لازم يبقى في الـ runbook: الـ hotfix اليدوي هيتمسح |
| `helm upgrade` على app بتاع Argo | `helm upgrade ... --set-string image.tag=<OTHER>` | Argo يشوف OutOfSync ويرجّع الـ git version — اتنين owners بيتخانقوا |
| Parameter override | `argocd app set student-app -p image.tag=<SHA>` | الـ app بقى بيقول حاجة مش في git؛ الـ bump الجاي "مش بيشتغل". امسحه: `argocd app unset student-app -p image.tag` |
| Two owners | `install_addons = true` + app-of-apps على نفس الـ LBC | الـ release بيتعدّل من الاتنين للأبد (values مختلفة: replicaCount 1↔2) |
| Bad release بـ GitOps | bump لإصدار فيه bug (أو merge PR بيعدّل `extraEnv` في `values-eks.yaml` لـ `SRE_FAULT_ERROR_RATE: "0.5"`) | الـ canary analysis بيعمل abort → الـ app `Degraded` → `git revert` → Healthy |
| Rollback من Argo | `argocd app rollback student-app <ID>` | مرفوض طول ما الـ auto-sync شغال — الـ rollback في GitOps = git |
| الـ PR مبيشغّلش CI | افتح الـ bump PR وشوف الـ checks | مفيش `ci.yml` run (GITHUB_TOKEN) |
| الـ scraping مش موجود | Argo يملك الـ app و kube-prometheus-stack من Terraform **من غير** الـ values file | كل canary يتعمله abort (fail closed — [68](68-k8s-canary-argo-rollouts.md)) |

## 9) الرجوع (Rollback)

- **العادي:** `git revert` (§6.4). الـ history = `git log` على `values-eks.yaml`.
- **طوارئ والـ git مش متاح:** اقفل الـ auto-sync مؤقتاً ثم rollback من Argo:

```bash
argocd app set student-app --sync-policy none
argocd app rollback student-app <HISTORY_ID>
# … وبعدين صلّح الـ git ورجّع الـ automated sync:
argocd app set student-app --sync-policy automated --self-heal --auto-prune
```

- **أثناء canary:** `kubectl argo rollouts abort` بيشتغل حتى مع selfHeal (بيغيّر الـ status مش الـ spec) — بس الحالة النهائية لازم تيجي من git.

## 10) المسح (Teardown) ⚠️

الترتيب مهم: التطبيق الأول (الـ LBC لازم يكون لسه موجود عشان يمسح الـ ALB):

```bash
kubectl -n argocd delete application student-app --wait=true           # cascade: الـ Ingress → الـ LBC يمسح الـ ALB
aws elbv2 describe-load-balancers --names student-app-lab-eks 2>&1 | grep -q LoadBalancerNotFound && echo "ALB gone"
kubectl -n argocd delete application student-app-lab --wait=true        # app-of-apps → الـ add-ons
helm -n argocd uninstall argo-cd                                        # لو ركّبته يدوي (أو addons.argo_cd = false + apply)
kubectl get crd | grep -E "argoproj|external-secrets|monitoring.coreos" # CRDs فاضلة؟
```

> ⚠️ لو مسحت الـ app-of-apps الأول، ممكن الـ LBC يتشال قبل ما يمسح الـ ALB → ALB يتيم و Ingress متعلّق بـ finalizer. وبعدها `terraform destroy` ([62 §10](62-eks-terraform.md)).

## 11) التكلفة (Cost)

| Resource | السعر التقريبي (تقريبي — راجع صفحة الأسعار) |
|---|---|
| Argo CD (server، repo-server، application-controller، redis) | مجاني كـ software؛ requests محسوسة على 2 × t3.medium ("heavy" في `variables.tf`) → غالباً node تالتة ~$0.04/ساعة |
| kube-prometheus-stack | زي [68 §11](68-k8s-canary-argo-rollouts.md) |
| GitHub Actions / PRs | مجاني تقريباً |

## 12) أسئلة Interview

<details><summary>GitOps (pull) مقابل CI push (`helm upgrade` من الـ pipeline)؟</summary>

Push: بسيط، بس الـ CI محتاج credentials admin للـ cluster (blast radius لو الـ CI اتخترق)، ومفيش reconciliation (drift بيفضل)، والـ rollback = تشغيل pipeline. Pull: الـ credentials جوه الـ cluster، الـ git = audit trail كامل (مين غيّر إيه وإمتى ومين وافق)، الـ drift بيتصلّح، والـ rollback = revert. العيوب: tooling زيادة، الـ secrets محتاجة حل (ESO)، والـ "deploy" بقى async (لازم تراقب الـ sync/health مش exit code).

</details>

<details><summary>إزاي بتعمل promotion بين environments في GitOps؟</summary>

ملف values لكل env (أو folder/overlay)، والـ promotion = PR بينقل نفس الـ tag من `values-staging` لـ `values-prod` (أوتوماتيك بعد نجاح الـ staging أو يدوي بـ approval). أو branch/repo لكل env (أصعب في الـ merge). أدوات: Argo CD Image Updater، Kargo، أو workflow زي الـ `gitops-bump`. المبدأ: نفس الـ artifact (digest)، والـ diff الوحيد بين envs config.

</details>

<details><summary>App of apps مقابل ApplicationSet؟</summary>

App of apps: Application بيشاور على folder فيه Applications (static، بسيط، كويس للـ bootstrap). ApplicationSet: generator (list، cluster، git directories، PRs) بيولّد Applications من template — للـ multi-cluster/multi-tenant أو preview environments لكل PR. عندنا cluster واحد و 5 add-ons → app of apps كفاية.

</details>

<details><summary>إزاي GitOps بيتعامل مع الـ secrets؟</summary>

مبتحطش secrets في git plain. الخيارات: ESO (الـ git فيه `ExternalSecret` = "هات X من SSM"، والقيمة برا git — اللي عملناه)، Sealed Secrets/SOPS (متشفّرة في git)، أو CSI driver. الـ GitOps repo يفضل public-safe.

</details>

<details><summary>selfHeal شغال وفيه incident محتاج hotfix يدوي — تعمل إيه؟</summary>

يا إما الـ hotfix يعدّي على git (PR سريع — الأحسن، وهو اللي هيفضل)، يا إما تقفل الـ auto-sync للـ app ده مؤقتاً (`--sync-policy none`)، تصلّح، وبعدين ترجّع الـ git يطابق وتفعّل الـ sync. والـ runbook لازم يقول كده صراحة — وإلا الـ on-call هيصلّح والـ Argo هيرجّع المشكلة بعد ثواني.

</details>

<details><summary>ليه "one owner per add-on" مهم؟</summary>

اتنين controllers (Terraform helm_release و Argo Application) بيطبقوا نفس الـ release بـ values مختلفة → كل واحد "يصلّح" تعديل التاني (flapping)، و Terraform plan دايماً فيه diff، وتغيير owner على cluster شغال ممكن يعمل uninstall للـ chart → **مسح الـ CRDs → مسح كل الـ custom resources** (ExternalSecrets، Rollouts). اختار owner من الأول، ونقل الـ ownership بخطة (orphan/adopt) مش بقلب toggle.

</details>

<details><summary>Sync waves و hooks — إمتى تستخدم إيه؟</summary>

Waves: ترتيب resources عادية (store قبل ExternalSecret قبل app) — Argo بيستنى كل wave تبقى Healthy قبل اللي بعدها. Hooks: حاجات one-off بتتنفذ في phase (PreSync migration، PostSync smoke test، SyncFail notification) وبيتعملها delete حسب الـ policy. الـ migration عندنا Sync hook في wave 0 بدل PreSync عشان تيجي **بعد** الـ ExternalSecret (wave -1) اللي في الـ Sync phase.

</details>

## 13) Checklist

- [ ] اخترت owner الـ add-ons (Terraform أو Argo) قبل أي حاجة
- [ ] ملّيت الـ placeholders (repoURL، targetRevision، vpcId، region) وعملتهم commit
- [ ] فعّلت "Allow GitHub Actions to create and approve pull requests" وفهمت مشكلة الـ GITHUB_TOKEN مع الـ CI
- [ ] ركّبت Argo CD وعملت bootstrap (application.yaml أو app-of-apps) وشفت الـ waves
- [ ] عملت release بـ gitops-bump PR وتابعت الـ canary من Argo UI
- [ ] جرّبت selfHeal و parameter override و rollback بـ `git revert`
- [ ] مسحت بالترتيب (التطبيق قبل الـ add-ons) واتأكدت إن الـ ALB اتشال
