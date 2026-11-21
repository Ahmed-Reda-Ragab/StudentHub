# 65 — Helm chart للتطبيق (+ migrate hook)

> **الهدف في سطر:** تقرا الـ chart [`k8s/helm/student-app`](../../../k8s/helm/student-app/Chart.yaml) template بـ template (الـ helpers، الـ pod template المشترك بين Deployment و Rollout، release env في الـ pod template، الـ **migration hook** وترتيبه مع ESO و Argo CD)، تفهم طبقات الـ values (`values.yaml` ← `values-kind.yaml` / `values-eks.yaml` ← `values-bluegreen.yaml`)، وتنشر على EKS بـ [`deploy-eks.yml`](../../../.github/workflows/deploy-eks.yml) mode **`helm`** (OIDC، `--wait`، و **`--rollback-on-failure`** بتاع Helm 4).
> **المستوى:** Intermediate → Advanced · **الوقت:** ~3 ساعات · **التكلفة التقريبية:** مفيش جديد (kind مجاني؛ على EKS نفس [62](62-eks-terraform.md))
> **بيعتمد على:** [60](60-kubernetes-on-kind.md) · [63](63-eks-load-balancer-controller-ingress.md) · [64](64-eks-external-secrets.md) · [34 — Environments](34-environments-approvals-promotion.md) · **الملفات في الـ repo:** [`Chart.yaml`](../../../k8s/helm/student-app/Chart.yaml) · [`values.yaml`](../../../k8s/helm/student-app/values.yaml) · [`values-kind.yaml`](../../../k8s/helm/student-app/values-kind.yaml) · [`values-eks.yaml`](../../../k8s/helm/student-app/values-eks.yaml) · [`values-bluegreen.yaml`](../../../k8s/helm/student-app/values-bluegreen.yaml) · [`templates/_helpers.tpl`](../../../k8s/helm/student-app/templates/_helpers.tpl) · [`templates/migrate-job.yaml`](../../../k8s/helm/student-app/templates/migrate-job.yaml) · [`templates/deployment.yaml`](../../../k8s/helm/student-app/templates/deployment.yaml) · [`templates/NOTES.txt`](../../../k8s/helm/student-app/templates/NOTES.txt) · [`.github/workflows/deploy-eks.yml`](../../../.github/workflows/deploy-eks.yml) · [`.github/workflows/lint-infra.yml`](../../../.github/workflows/lint-infra.yml)

## 1) الفكرة (Concepts)

الـ plain YAML في [60](60-kubernetes-on-kind.md) وضّح المشاكل: Job immutable بيتعمل مع الـ Deployment، ConfigMap بيتغيّر من غير restart، و "Deployment ولا Rollout؟" و "Ingress ولا لأ؟" محتاجين نسخ مختلفة. Helm = **templates + values + release history + hooks**.

| المصطلح | المعنى |
|---|---|
| Chart / Release / Revision | الـ package / نسخة متركّبة منه باسم (`student-app`) / كل `upgrade` أو `rollback` = revision جديدة (متخزّنة كـ Secret `sh.helm.release.v1.<name>.v<N>` في الـ namespace) |
| `version` / `appVersion` | version الـ chart (packaging، `0.1.0`) / الـ app (`dev` = fallback بس؛ كل deploy بيبعت `image.tag`) |
| Values layering | `values.yaml` ← `-f values-<env>.yaml` ← `-f` تاني ← `--set` (الأخير بيكسب؛ الـ maps بتتعمل deep merge) |
| Hook | resource بيتعمل في لحظة معينة (`pre-install`، `pre-upgrade`، `post-install`...) بـ `hook-weight` و `hook-delete-policy` |
| `--wait` | النجاح = كل الـ resources Ready (pods Ready + الـ hooks خلصت) مش "اتبعتت للـ API" |
| `--rollback-on-failure` | **Helm 4**: الاسم الجديد لـ `--atomic` — لو الـ upgrade فشل/timeout، Helm يرجع لآخر revision ناجحة لوحده (`--atomic` لسه شغال بـ deprecation warning) |
| `--set` مقابل `--set-string` | `--set image.tag=1234567` بيتقري **رقم** (وممكن يطلع `1.234567e+06`)؛ SHA زي `12e4567` بيتقري float. **دايماً `--set-string` للـ tags** |

## 2) المعمارية (Architecture)

```text
 values.yaml (defaults: Deployment، HPA on، PDB، NetworkPolicy، migrations on، ESO off، rollout off)
   ⊕ values-kind.yaml   (pullPolicy Never، NodePort 30080، DB_HOST mysql، HPA off، databaseTo mysql pod)
   ⊕ values-eks.yaml    (ECR، Ingress alb، ESO + ClusterSecretStore، databaseTo 10.60.0.0/16، Rollout canary ALB)
   ⊕ values-bluegreen.yaml (rollout.strategy blueGreen — فوق أي env)
   ⊕ --set-string image.tag=<sha> / --set rollout.enabled=false / --set-string extraEnv.X=Y
        │
        ▼  helm template (helpers → manifests)
 ┌───────────────────────────────────────────────────────────────────────────────────────────┐
 │ hooks (Helm):  ConfigMap <fullname>-migrate (weight -10) → Job <fullname>-migrate (0)       │
 │                pre-install,pre-upgrade  |  post-install,pre-upgrade لو externalSecrets.enabled │
 │ release:       ServiceAccount · ConfigMap <fullname> · Secret? (لأ: existingSecret)          │
 │                [ClusterSecretStore -2] [ExternalSecret -1] · Service(s) · [Ingress]          │
 │                Deployment (rollout.enabled=false) │ Rollout + AnalysisTemplates (true)  wave 1│
 │                HPA · PDB · NetworkPolicy · [ServiceMonitor + headless metrics Service]       │
 │ NOTES.txt:     أوامر الـ check حسب NodePort/Ingress/port-forward و Deployment/Rollout       │
 └───────────────────────────────────────────────────────────────────────────────────────────┘
        │  helm upgrade --install --wait --rollback-on-failure
        ▼
 revision N  ──fail/timeout──►  rollback تلقائي لـ revision N-1 (الـ pods القديمة كانت شغالة أصلاً: maxUnavailable 0)
```

## 3) المتطلبات (Prerequisites)

- [ ] `helm` v4 (الـ CI بيستخدم `v4.3.2`) — `helm version --short`.
- [ ] للـ kind: [60](60-kubernetes-on-kind.md) شغال. للـ EKS: [62](62-eks-terraform.md) بـ LBC + ESO ([63](63-eks-load-balancer-controller-ingress.md)، [64](64-eks-external-secrets.md)).
- [ ] للـ workflow: repo variables `AWS_REGION`، `AWS_DEPLOY_ROLE_ARN`، `ECR_REPOSITORY`، `EKS_CLUSTER` ([CONVENTIONS §9](../CONVENTIONS.md))، و environment `lab` موجود، والـ deploy role عليه access entry (`grant_github_deploy_role`، الافتراضي true).
- [ ] image بـ SHA في ECR.

## 4) الطريقة الأولى: "Console" — GitHub Actions UI

1. **Actions → Deploy to EKS → Run workflow** → branch `master` · `image_tag` = SHA موجود في ECR · `mode` = **helm** → **Run workflow**.
2. لو الـ environment `lab` عليه required reviewer: الـ run بيقف **Waiting** → **Review deployments → Approve** ([34](34-environments-approvals-promotion.md)).
3. الـ **Summary**: Cluster، Image، ALB hostname، و `helm history --max 5`، وأمر الـ smoke.
4. لو فشل: step **Diagnostics on failure** (`get all,ingress,externalsecret,...`، describe، events، logs، `describe externalsecret`) — والـ release اترجّع لوحده.

## 5) الطريقة التانية: as Code — الـ chart من جوه

### 5.1 [`_helpers.tpl`](../../../k8s/helm/student-app/templates/_helpers.tpl)

| Helper | بيعمل إيه | ليه |
|---|---|---|
| `student-app.fullname` | لو اسم الـ release فيه اسم الـ chart → اسم الـ release؛ غير كده `<release>-student-app` | release `student-app` → كل الـ objects اسمها `student-app` (الـ CI والـ Argo بيعتمدوا على ده)؛ `helm template lab ...` → `lab-student-app` |
| `student-app.imageTag` | `default .Chart.AppVersion .Values.image.tag` و **`fail` لو `latest`** | [CONVENTIONS §2](../CONVENTIONS.md): مفيش mutable tags توصل cluster |
| `student-app.selectorLabels` | `name` + `instance` + `component: web` | الـ selectors immutable، فالـ version **مش** فيها (موجود في الـ labels العادية) |
| `student-app.configData` | `config.*` → ConfigMap؛ **`KEY: null` بيتشال** | environment file يقدر يشيل default |
| `student-app.releaseEnv` | `DEPLOY_COLOR` + `SRE_FAULT_*` (من `faults.*`) + `extraEnv` (بيكسب) → **`env` في الـ pod template** | (1) كل ReplicaSet ليه نسخته: لو كانوا في الـ ConfigMap المشترك، fault الـ canary السيء كان هيتسرّب لـ pods الـ stable اللي بتعمل restart أو scale أثناء الـ abort. (2) تغييرهم = تغيير الـ pod template = Argo Rollouts يبدأ canary جديد. (3) dict واحد = مفيش env مكرر (بيكسر server-side apply) |
| `student-app.jobEnv` | `extraEnv` **من غير** `SRE_FAULT_*` + `AUTORUN_ENABLED=false` | الـ faults بتحاكي pod تطبيق سيء، مش migration سيئة؛ ومن غير `optimize` في one-off |
| `student-app.podTemplate` | الـ pod spec كله، بـ `hashLabel` (`pod-template-hash` للـ Deployment، `rollouts-pod-template-hash` للـ Rollout) | `rollout.enabled` بيغيّر **مين** بيعمل roll بس، مش **إيه** اللي بيشتغل؛ والـ `checksum/config` annotation = تغيير الـ ConfigMap بيعمل roll |

### 5.2 الـ templates

| Template | بيترسم إمتى | ملاحظات |
|---|---|---|
| `configmap.yaml` | دايماً | `config.*` بس (environment-scoped) |
| `deployment.yaml` | `rollout.enabled=false` | `replicas` بيتشال لو الـ HPA شغال (Helm/Argo ميتخانقوش مع الـ HPA)؛ wave `1` |
| `rollout.yaml` + `analysistemplate.yaml` | `rollout.enabled=true` | canary/blueGreen، `progressDeadlineAbort: true` — [67](67-k8s-bluegreen.md)/[68](68-k8s-canary-argo-rollouts.md) |
| `service.yaml` | دايماً (+ `-canary` / `-preview` / `-metrics` حسب الحالة) | `nodePort` بس لو `type: NodePort` |
| `ingress.yaml` | `ingress.enabled` | `blockPaths`، `use-annotation` مع canary ALB — [63](63-eks-load-balancer-controller-ingress.md) |
| `migrate-job.yaml` | `migrations.enabled` | hook ConfigMap + Job (§5.3) |
| `externalsecret.yaml` / `clustersecretstore.yaml` | `externalSecrets.enabled` (+ `store.create`) | [64](64-eks-external-secrets.md) |
| `hpa.yaml` | `autoscaling.enabled` | بيستهدف الـ Rollout لو موجود — [6A](6A-hpa-karpenter-under-load.md) |
| `pdb.yaml` / `networkpolicy.yaml` | `pdb.enabled` / `networkPolicy.enabled` | الـ NetworkPolicy selector من غير `component` → بيغطي الـ Job كمان |
| `servicemonitor.yaml` | `serviceMonitor.enabled` (**off**) | الـ PodMonitor في `observability/` بيعمل scrape أصلاً؛ الاتنين = double counting |
| `serviceaccount.yaml` | `serviceAccount.create` | `automountServiceAccountToken: false` |

### 5.3 الـ migration hook بالتفصيل

```yaml
# migrate-job.yaml (مختصر)
helm.sh/hook: {{ $helmHook }}          # pre-install,pre-upgrade | post-install,pre-upgrade (ESO)
helm.sh/hook-weight: "-10"             # الـ ConfigMap <fullname>-migrate الأول
helm.sh/hook-weight: "0"               # بعده الـ Job
helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded
argocd.argoproj.io/hook: Sync          # Argo: تجاهل الـ Helm hooks، شغّله في الـ Sync phase
argocd.argoproj.io/sync-wave: "0"      # بعد ExternalSecret (-1) وقبل الـ app (1)
```

- **pre-upgrade** = الـ migrations بتخلص **قبل** ما أي pod جديد يتعمل → الـ pods القديمة بتشتغل على الـ schema الجديد للحظات (expand/contract إجباري — [95](95-zero-downtime-db-migrations.md)).
- `hook-succeeded` بيمسح الـ Job الناجح؛ الـ **فاشل بيفضل** لحد المحاولة الجاية (`before-hook-creation`) عشان `kubectl logs job/student-app-migrate`.
- `backoffLimit: 1`، `activeDeadlineSeconds: 300`، و **من غير `serviceAccountName`**: الـ ServiceAccount بتاع الـ chart resource عادي ومش موجود وقت pre-install.
- ليه hook ConfigMap منفصل؟ وقت pre-install الـ release ConfigMap لسه متعملش.
- **مع ESO** أول install `post-install` (التفاصيل في [64 §5.3](64-eks-external-secrets.md)).

### 5.4 Render و lint (زي الـ CI بالظبط)

```bash
helm lint k8s/helm/student-app
for v in k8s/helm/student-app/values*.yaml; do
  echo "== $v"; helm template lab k8s/helm/student-app -f "$v" | grep -E '^kind:' | sort | uniq -c
done
helm template lab k8s/helm/student-app -f k8s/helm/student-app/values-eks.yaml --set rollout.enabled=false \
  --show-only templates/migrate-job.yaml | grep -A1 "helm.sh/hook:"          # post-install,pre-upgrade (ESO on)
helm template lab k8s/helm/student-app -f k8s/helm/student-app/values-kind.yaml \
  --show-only templates/migrate-job.yaml | grep -A1 "helm.sh/hook:"          # pre-install,pre-upgrade
```

[`lint-infra.yml`](../../../.github/workflows/lint-infra.yml) بيعمل `helm lint` + `helm template -f values*.yaml | kubeconform -strict` (بـ CRDs catalog للـ Rollout/ExternalSecret...) لكل values file، بـ kubeconform متثبت على `v0.6.7` (`KUBECONFORM_VERSION` — Dependabot مش بيشوف الـ curl downloads، فالـ bump يدوي).

## 6) الـ Deploy

### 6.1 kind

```bash
helm upgrade --install student-app k8s/helm/student-app -n student-app \
  -f k8s/helm/student-app/values-kind.yaml --set-string image.tag=ci-v1 --wait --timeout 6m
helm upgrade student-app k8s/helm/student-app -n student-app \
  -f k8s/helm/student-app/values-kind.yaml --set-string image.tag=ci-v2 --wait --timeout 6m
helm -n student-app history student-app
```

### 6.2 `deploy-eks.yml` mode `helm` — step بـ step

```bash
gh workflow run deploy-eks.yml --ref master -f image_tag=<GIT_SHA> -f mode=helm
gh run watch
```

| Step | بيعمل إيه | ليه |
|---|---|---|
| `concurrency: deploy-eks-lab`، `cancel-in-progress: false` | deploy واحد في المرة، ومحدش يتلغي في النص | الـ helm release نص متطبّق أخطر من deploy متأخر |
| `environment: lab` + `id-token: write` | الـ OIDC token بـ `sub = repo:<owner>/<repo>:environment:lab` | الـ bootstrap trust بيسمح لـ `deploy_environments = ["lab","production"]`؛ والـ approval (لو موجود) قبل أي credentials |
| Validate the image tag | regex `^[0-9a-f]{7,40}$` | مفيش `latest` ولا tags متغيرة |
| AWS credentials (OIDC) | `configure-aws-credentials@v6` → `AWS_DEPLOY_ROLE_ARN` | من غير keys ([30](30-ci-github-actions.md)) |
| The image must exist in ECR | `aws ecr describe-images --image-ids imageTag=$IMAGE_TAG` | يفشل **قبل** ما يلمس الـ cluster (بدل `ImagePullBackOff` بعد 10 دقايق) |
| kubeconfig | `aws eks update-kubeconfig` + `kubectl version` + `kubectl auth can-i create deployments.apps -n student-app` | بيثبت إن الـ access entry شغال (الـ role محتاج `eks:DescribeCluster` في IAM + access entry في EKS — اتنين مختلفين) |
| setup-helm `v4.3.2` | | نفس الـ version في الـ CI والـ kind |
| Namespace | `kubectl apply -f k8s/manifests/base/namespace.yaml` + label الـ readiness gate | PSS `restricted` + gates **قبل** الـ pods |
| helm upgrade | `-f values-eks.yaml --set-string image.repository=$REGISTRY/$ECR_REPOSITORY --set-string image.tag=$IMAGE_TAG --set rollout.enabled=false --wait --rollback-on-failure --timeout 10m --description "deploy-eks run <id> (<actor>)"` | Deployment عادي؛ نجاح = pods Ready (readiness + ALB gate) + الـ hook خلص؛ غير كده rollback تلقائي |
| `rollout status deployment/student-app` | تأكيد إضافي | |
| Job summary / Diagnostics | `if: always()` / `if: failure()` | |

> 💡 `--description` بيظهر في `helm history` → تعرف كل revision جه من أنهي run ومين. ده audit trail رخيص.

## 7) التحقق (Verify)

```bash
helm -n student-app list
helm -n student-app history student-app                        # DESCRIPTION = deploy-eks run ...
helm -n student-app get values student-app                      # الـ user-supplied values بس
helm -n student-app get values student-app --all | head -40     # الـ values النهائية بعد الدمج
helm -n student-app get manifest student-app | grep -E '^kind:' | sort | uniq -c
helm -n student-app get hooks student-app | grep -E 'kind:|helm.sh/hook'
helm -n student-app status student-app                          # الـ NOTES.txt
kubectl -n student-app get pods -L app.kubernetes.io/version
kubectl -n student-app get deploy student-app -o jsonpath='{.spec.template.metadata.annotations.checksum/config}{"\n"}'
```

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر | المتوقع |
|---|---|---|
| `latest` | `helm template x k8s/helm/student-app --set-string image.tag=latest` | `image.tag=latest is not allowed — deploy an immutable git SHA` |
| tag رقمي بـ `--set` | `helm template x k8s/helm/student-app --set image.tag=1234567 \| grep image:` | الـ tag بيطلع رقم متحوّر (scientific notation) — عشان كده `--set-string` |
| Strategy غلط | `--set rollout.enabled=true --set rollout.strategy=linear` | `rollout.strategy must be canary or blueGreen` |
| ALB canary من غير Ingress | `--set rollout.enabled=true --set rollout.canary.trafficRouting.alb.enabled=true` (kind) | `... needs ingress.enabled=true and ingress.className=alb` |
| Tag مش في ECR | الـ workflow بـ `image_tag=deadbee` | يفشل في "The image must exist in ECR" — الـ cluster متلمسش |
| Release unhealthy | `helm upgrade ... --set faults.unhealthy=true --wait --rollback-on-failure --timeout 5m` | الـ pods الجديدة مش Ready (`/ready` 503) → timeout → **rollback تلقائي**؛ `probe.sh` على الـ ALB: 0 failures (القديمة شغالة) |
| Boot failure | `--set faults.bootFail=true` | `CrashLoopBackOff` → نفس الـ rollback |
| Migration فاشلة | `--set-string extraEnv.DB_DATABASE=does_not_exist` | الـ pre-upgrade Job يفشل → الـ upgrade يفشل **قبل** أي pod يتغيّر → rollback؛ `kubectl -n student-app logs job/student-app-migrate` |
| ConfigMap change | `--set-string config.LOG_LEVEL=debug` | الـ `checksum/config` اتغيّر → rolling update لوحده |

## 9) الرجوع (Rollback)

```bash
helm -n student-app history student-app
helm -n student-app rollback student-app <REVISION> --wait --timeout 10m
helm -n student-app rollback student-app --wait            # من غير رقم = الـ revision اللي قبلها
```

- الـ rollback = revision **جديدة** بالـ manifests القديمة (مش بيمسح التاريخ).
- **مش** بيرجّع: الـ migrations (`pre-upgrade` بس — مفيش `pre-rollback` hook عندنا)، ولا قيم SSM/ESO، ولا الـ data.
- في الـ workflow: `--rollback-on-failure` بيعملها لوحده؛ اليدوي = الـ Job summary فيه الأمر.

## 10) المسح (Teardown) ⚠️

```bash
helm -n student-app uninstall student-app
kubectl -n student-app delete job,configmap -l app.kubernetes.io/component=migrate --ignore-not-found   # hook فاشل فاضل
kubectl -n student-app get all
```

الـ hooks مش جزء من الـ release resources، فـ Job فاشل ممكن يفضل بعد الـ uninstall. على EKS: الـ Ingress بيتمسح مع الـ uninstall → الـ ALB يتمسح (اتأكد قبل `terraform destroy`).

## 11) التكلفة (Cost)

| Resource | السعر التقريبي |
|---|---|
| Helm / الـ chart | مجاني |
| GitHub Actions (deploy run) | دقايق قليلة |
| EKS | نفس [62 §11](62-eks-terraform.md) |

## 12) أسئلة Interview

<details><summary>Helm hooks مقابل Argo CD sync waves — إيه الفرق؟</summary>

Helm hooks: بتشتغل جوه `helm install/upgrade` (pre/post) ومش جزء من الـ release resources (مش بتظهر في `helm get manifest`، ومش بتتمسح مع uninstall إلا بالـ delete policy). Argo CD: بيعمل render للـ chart بـ `helm template` ومبينفّذش Helm hooks بالظبط زي Helm؛ عنده phases (PreSync/Sync/PostSync) و waves جوه كل phase وبيستنى الـ health. الـ chart عندنا بيدعم الاتنين: `helm.sh/hook` لـ Helm، و `argocd.argoproj.io/hook: Sync` + wave `0` لـ Argo (ولما الـ annotation ده موجود Argo بيتجاهل الـ Helm hooks).

</details>

<details><summary>`--wait` بيستنى إيه بالظبط؟ وليه مهم مع `--rollback-on-failure`؟</summary>

بيستنى الـ Deployments يوصلوا الـ replicas المطلوبة Ready (بما فيها الـ readiness gates)، والـ Services، والـ PVCs، والـ Jobs (hooks) تخلص — لحد `--timeout`. من غيره Helm بيعلن نجاح أول ما الـ API يقبل الـ objects، و `--rollback-on-failure` مش هيشوف فشل أصلاً. الاتنين مع بعض = deploy transactional تقريباً: يا الإصدار الجديد Ready كله، يا يرجع القديم.

</details>

<details><summary>ليه الـ fault env في الـ pod template مش في الـ ConfigMap؟</summary>

الـ ConfigMap object واحد مشترك بين كل الـ ReplicaSets. لو `SRE_FAULT_ERROR_RATE=0.5` في الـ ConfigMap ومعاه canary، أي pod stable يعمل restart (OOM، node drain، HPA scale up) هياخد القيمة السيئة — وأثناء الـ abort نفسه الـ stable بيعمل scale up! في الـ pod template كل ReplicaSet شايل نسخته، فالـ stable عمره ما يشوف إعداد الـ canary. نفس المبدأ لأي release-scoped config (feature flags مربوطة بإصدار).

</details>

<details><summary>chart version و appVersion و image tag — مين بيتغيّر إمتى؟</summary>

`version`: لما الـ templates تتغيّر (semver، packaging/OCI registry). `appVersion`: افتراضي للـ app (عندنا `dev` fallback بس). `image.tag`: كل deploy (SHA). الفصل ده بيخليك تعمل upgrade للـ chart من غير deploy للتطبيق والعكس. في GitOps ([69](69-gitops-argocd.md)) الـ tag في values file في git، مش parameter.

</details>

<details><summary>إيه المشاكل المشهورة في Helm في الـ production؟</summary>

(1) drift: `kubectl edit` بيتعمله overwrite (أو العكس — حسب الـ field ownership). (2) release متعلّق في `pending-upgrade` بعد timeout/cancel → `helm rollback` أو تصلّح الـ state. (3) الـ release Secret ليه حد ~1MB (charts ضخمة). (4) CRDs: Helm بيركّبها أول مرة بس ومبيعملهاش upgrade (عشان كده كتير من الـ charts بـ `installCRDs` كـ templates أو Argo بـ ServerSideApply). (5) `--reuse-values` بيخبّي defaults جديدة في الـ chart. (6) hooks فاشلة بتفضل وتتراكم.

</details>

<details><summary>ليه الـ workflow بيشيّك على الـ image في ECR قبل الـ deploy؟</summary>

Fail fast and safe: من غيره الـ pods هتقع `ImagePullBackOff`، Helm يستنى 10 دقايق، وبعدين يعمل rollback — وقت ضايع وإنذار كاذب. والتحقق بيأكد إن الـ SHA اتبنى واتعمله scan في الـ CI ([30](30-ci-github-actions.md)) — "build once, deploy many". الأحسن كمان: deploy بالـ digest مش بالـ tag (immutable 100%).

</details>

## 13) Checklist

- [ ] قريت `_helpers.tpl` وفهمت `releaseEnv` و `jobEnv` و `podTemplate`
- [ ] عملت `helm template` لكل values file وقارنت الـ kinds والـ hook annotations
- [ ] نشرت على kind (ci-v1 → ci-v2) وقريت `helm history`
- [ ] شغّلت `deploy-eks.yml` mode `helm` وفهمت كل step (OIDC sub، ECR check، `auth can-i`)
- [ ] جرّبت `--rollback-on-failure` مع release unhealthy و migration فاشلة
- [ ] أقدر أشرح Helm hooks مقابل Argo waves، و `--set-string`
