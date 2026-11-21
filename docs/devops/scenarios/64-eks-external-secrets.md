# 64 — External Secrets + SSM Parameter Store

> **الهدف في سطر:** الـ Secret `student-app-secrets` عمره ما يتكتب بإيد ولا يدخل git: **External Secrets Operator (ESO)** بـ **Pod Identity** بيقرا كل parameter تحت `/student-app/lab/app/` من **SSM Parameter Store** ويحوّله لـ key في الـ Secret — وتفهم الـ 3 أشكال للـ store (من الـ chart، من Terraform، namespaced)، وترتيب الـ migration hook مع ESO، والـ rotation، والـ precedence.
> **المستوى:** Intermediate · **الوقت:** ~2–3 ساعات · **التكلفة التقريبية:** مجاني (standard parameters) فوق تكلفة الـ cluster
> **بيعتمد على:** [62 — EKS بـ Terraform](62-eks-terraform.md) · [81 — إدارة الـ Secrets](81-secrets-management.md) · [CONVENTIONS §4](../CONVENTIONS.md) · **الملفات في الـ repo:** [`templates/externalsecret.yaml`](../../../k8s/helm/student-app/templates/externalsecret.yaml) · [`templates/clustersecretstore.yaml`](../../../k8s/helm/student-app/templates/clustersecretstore.yaml) · [`templates/migrate-job.yaml`](../../../k8s/helm/student-app/templates/migrate-job.yaml) · [`values.yaml`](../../../k8s/helm/student-app/values.yaml) · [`values-eks.yaml`](../../../k8s/helm/student-app/values-eks.yaml) · [`overlays/eks/secretstore.yaml`](../../../k8s/manifests/overlays/eks/secretstore.yaml) · [`overlays/eks/externalsecret.yaml`](../../../k8s/manifests/overlays/eks/externalsecret.yaml) · [`infra/terraform/stacks/60-eks/pod-identity.tf`](../../../infra/terraform/stacks/60-eks/pod-identity.tf) · [`ssm.tf`](../../../infra/terraform/stacks/60-eks/ssm.tf) · [`outputs.tf`](../../../infra/terraform/stacks/60-eks/outputs.tf)

## 1) الفكرة (Concepts)

الـ Kubernetes `Secret` = base64 مش تشفير. لو حطيته في git (حتى private) أو عملته بـ `kubectl create` بإيدك: مفيش مصدر حقيقة، مفيش rotation، ومفيش audit. الحل: **مصدر الحقيقة برا الـ cluster** (SSM — نفس المكان اللي EC2 و ECS بيقروا منه في السيناريوهات اللي فاتت) و controller بيزامن.

| المصطلح | المعنى |
|---|---|
| `SecretStore` / `ClusterSecretStore` | "إزاي أوصل للـ provider" (ParameterStore، region، auth). الأول namespaced، التاني cluster-wide (ممكن تقفله على namespaces بـ `conditions`) |
| `ExternalSecret` | "إيه اللي أجيبه وأحطه فين": `secretStoreRef` + `target` + `data`/`dataFrom` |
| `dataFrom.find` + `rewrite` | هات **كل** الـ parameters تحت path (GetParametersByPath، recursive، decrypted) وقص الاسم لآخر جزء (`/student-app/lab/app/APP_KEY` → `APP_KEY`) |
| `refreshInterval` | كل قد إيه ESO يعيد القراية (1h عندنا) |
| `creationPolicy: Owner` | ESO بيملك الـ Secret (ownerReference): مسح الـ ExternalSecret = مسح الـ Secret |
| `deletionPolicy: Retain` | لو الـ parameters اختفت من SSM، سيب آخر Secret سليم بدل ما كل pod جديد يقع |
| No `auth` block | ESO بيستخدم الـ identity بتاعة الـ controller نفسه = IAM role عن طريق **Pod Identity** على `external-secrets/external-secrets` |

**الـ layout ومين بيكتب إيه** ([CONVENTIONS §4](../CONVENTIONS.md)، [`ssm.tf`](../../../infra/terraform/stacks/60-eks/ssm.tf)):

| Parameter تحت `/student-app/lab/app/` | النوع | الكاتب |
|---|---|---|
| `APP_KEY`، `SRE_LAB_TOKEN` | SecureString | `ssm.tf` (random) |
| `APP_URL`، `DB_CONNECTION`، `SESSION_DRIVER`، `CACHE_STORE`، `SRE_LAB_ENABLED`، `METRICS_ENABLED` | String | `ssm.tf` |
| `DB_HOST`، `DB_PORT`، `DB_DATABASE`، `DB_USERNAME`، `DB_PASSWORD` | String / SecureString | `modules/rds-mysql` |
| `METRICS_TOKEN` (اختياري) | SecureString | إنت (Console/CLI) |

**الـ precedence في الـ pod:** `envFrom` ConfigMap ← ثم Secret (**الـ Secret بيكسب**) ← ثم `env` (release env + `extraEnv`، بيكسب على الكل). يعني أي key في SSM بيغلب `config.*` في الـ chart — زي `APP_URL` و `DB_HOST`. ده مقصود (مصدر واحد للـ DB endpoint)، بس لازم تعرفه.

**البدائل:** Secrets Store CSI Driver (بيعمل mount لملفات من غير K8s Secret، اختياري sync)، Sealed Secrets / SOPS (secret متشفّر في git)، أو التطبيق نفسه يقرا SSM بـ Pod Identity (من غير Secret خالص، بس كود خاص بـ AWS).

## 2) المعمارية (Architecture)

```text
 Terraform 60-eks                                   SSM Parameter Store (us-east-1)
   ssm.tf ─────────────┐                             /student-app/lab/app/APP_KEY        (SecureString)
   modules/rds-mysql ──┴──── put-parameter ────────► /student-app/lab/app/DB_PASSWORD    (SecureString)
   pod-identity.tf:                                   /student-app/lab/app/DB_HOST ...    (String)
     role student-app-lab-external-secrets                       ▲
       ssm:GetParameter/GetParameters/GetParametersByPath        │ GetParametersByPath (recursive, decrypt)
         on /student-app/lab/app + /*                            │ kms:Decrypt (kms:ViaService = ssm)
       ssm:DescribeParameters (*)                                │
     association → external-secrets/external-secrets ──┐        │
                                                        ▼        │
 ┌─ namespace external-secrets ─────────────────────────────────┴─┐
 │  ESO controller (Pod Identity Agent بيدّيه credentials)         │
 └──────────────┬──────────────────────────────────────────────────┘
                │ reconcile كل refreshInterval (1h) أو force-sync
 ┌─ cluster ────▼────────────────────────────────────────────────────────────────────────────┐
 │ ClusterSecretStore student-app-parameter-store  (chart، conditions: [student-app])  wave -2│
 │   أو aws-parameter-store (Terraform output، كل الـ namespaces)                              │
 │ ┌─ namespace student-app ──────────────────────────────────────────────────────────────┐   │
 │ │ ExternalSecret student-app-secrets  (find path + rewrite)                    wave -1 │   │
 │ │        └──► Secret student-app-secrets {APP_KEY, DB_HOST, DB_PASSWORD, ...}          │   │
 │ │ migrate Job (post-install أول مرة / pre-upgrade بعد كده)                      wave 0 │   │
 │ │ Deployment/Rollout: envFrom ConfigMap → Secret (يكسب) → env                  wave 1 │   │
 │ └──────────────────────────────────────────────────────────────────────────────────────┘   │
 └────────────────────────────────────────────────────────────────────────────────────────────┘
```

## 3) المتطلبات (Prerequisites)

- [ ] الستاك [62](62-eks-terraform.md) متعمله apply بـ `install_addons = true` و `addons.external_secrets = true` (ESO 2.15.0 + الـ Pod Identity association)، أو §4.2 على cluster تاني.
- [ ] الـ parameters موجودة: `aws ssm get-parameters-by-path --path /student-app/lab/app --query 'Parameters[].Name'`.
- الأدوات: `kubectl`، `helm`، `aws`، `jq`.

## 4) الطريقة الأولى: AWS Console (يدوي)

### 4.1 الـ parameters

1. **Systems Manager → Parameter Store** → ابحث بـ `/student-app/lab/app/` → افتح `DB_HOST` (String، كاتبه الـ RDS module) و `APP_KEY` (SecureString، **Show decrypted value** بيحتاج `kms:Decrypt`).
2. **Create parameter**: Name `/student-app/lab/app/METRICS_TOKEN` · Tier **Standard** · Type **SecureString** · KMS key source: **My current account** · KMS Key ID: `alias/aws/ssm` · Value: ناتج `openssl rand -hex 16` → **Create parameter**.
3. افتح أي parameter → تاب **History**: كل تعديل version جديد (ده الـ rollback بتاعك — §9).

> 💡 الـ parameter الجديد هيظهر في الـ Secret لوحده (الـ `find` بيجيب أي حاجة تحت الـ path) بعد الـ refresh أو force-sync. ولاحظ: ده هيفعّل الـ Bearer auth على `/metrics` — الـ PodMonitor محتاج يبعت الـ token وإلا الـ scraping (وبالتالي الـ canary analysis) هيقع. امسحه بعد التجربة أو اظبط الـ scrape auth ([68](68-k8s-canary-argo-rollouts.md)).

### 4.2 الـ IAM و Pod Identity (لو مش Terraform)

1. **IAM → Policies → Create policy → JSON** (نفس `data.aws_iam_policy_document.eso` في [`pod-identity.tf`](../../../infra/terraform/stacks/60-eks/pod-identity.tf)):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "ReadAppParameters", "Effect": "Allow",
      "Action": ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"],
      "Resource": ["arn:aws:ssm:us-east-1:<ACCOUNT_ID>:parameter/student-app/lab/app",
                   "arn:aws:ssm:us-east-1:<ACCOUNT_ID>:parameter/student-app/lab/app/*"] },
    { "Sid": "DescribeParameters", "Effect": "Allow", "Action": "ssm:DescribeParameters", "Resource": "*" },
    { "Sid": "DecryptSecureStringViaSsm", "Effect": "Allow", "Action": "kms:Decrypt", "Resource": "*",
      "Condition": { "StringEquals": { "kms:ViaService": "ssm.us-east-1.amazonaws.com" } } }
  ]
}
```

2. **IAM → Roles → Create role → AWS service → EKS → EKS - Pod Identity** → الـ policy → اسم `student-app-lab-external-secrets`.
3. **EKS → cluster → Access → Pod Identity associations → Create** → الـ role · Namespace `external-secrets` · Service account `external-secrets`.
4. ESO نفسه:

```bash
helm upgrade --install external-secrets external-secrets --repo https://charts.external-secrets.io \
  --version 2.15.0 -n external-secrets --create-namespace \
  --set installCRDs=true --set serviceAccount.create=true --set serviceAccount.name=external-secrets
kubectl -n external-secrets rollout status deploy/external-secrets
```

> 🔐 لاحظ الـ least privilege: الـ path ده بس (مش `/student-app/lab/mysql/*` ولا `/deploy/*` ولا `prod`)، و `kms:Decrypt` بشرط إن الـ call جاي **عن طريق SSM** — مش أي decrypt لأي key.

## 5) الطريقة التانية: as Code

### 5.1 الـ chart

[`externalsecret.yaml`](../../../k8s/helm/student-app/templates/externalsecret.yaml) (لو `externalSecrets.enabled`):

- `name` و `target.name` = `existingSecret` (`student-app-secrets`)، `creationPolicy: Owner`، `deletionPolicy: Retain`.
- `dataFrom.find.path` = `externalSecrets.ssmPath` بعد `trimSuffix "/"`، `name.regexp: ".*"`، و `rewrite` بـ regex مبني بـ `regexQuoteMeta` على نفس الـ path → `$1`.
- `argocd.argoproj.io/sync-wave: "-1"` (قبل الـ Job والـ app).

[`clustersecretstore.yaml`](../../../k8s/helm/student-app/templates/clustersecretstore.yaml) (لو `enabled` **و** `store.create`): بيفشل الـ render لو `store.kind` مش `ClusterSecretStore`، provider `aws` / `ParameterStore` / `region`، **`conditions: [{namespaces: [<release namespace>]}]`** (cluster-wide object بس namespace واحدة تستخدمه)، و wave `-2`.

| Values key | `values.yaml` | `values-eks.yaml` |
|---|---|---|
| `externalSecrets.enabled` | `false` | `true` |
| `externalSecrets.refreshInterval` | `1h` | (نفسه) |
| `externalSecrets.ssmPath` | `/student-app/lab/app` | `/student-app/lab/app` |
| `externalSecrets.store.create` | `false` | `true` |
| `externalSecrets.store.kind` / `.name` | `ClusterSecretStore` / `aws-parameter-store` | `ClusterSecretStore` / `student-app-parameter-store` |
| `externalSecrets.store.region` | `us-east-1` | `us-east-1` |

### 5.2 الـ 3 أشكال للـ store

| | A) الـ chart بيعمله | B) Terraform output | C) Plain overlay |
|---|---|---|---|
| Object | `ClusterSecretStore student-app-parameter-store` | `ClusterSecretStore aws-parameter-store` | `SecretStore aws-parameter-store` (namespaced) |
| مين يستخدمه | namespace الـ release بس (`conditions`) | أي namespace | الـ namespace بتاعه بس |
| إزاي | `values-eks.yaml` كما هو | `terraform output -raw cluster_secret_store_manifest \| kubectl apply -f -` ثم `store.create=false` + `store.name=aws-parameter-store` | [`overlays/eks/secretstore.yaml`](../../../k8s/manifests/overlays/eks/secretstore.yaml) |
| Lifecycle | مع الـ release (uninstall يمسحه) | platform-owned (مرة لكل cluster) | مع الـ kustomization |
| متى | app واحد / lab | كذا app، الـ platform team بيدير الـ store | تعلّم الـ objects |

### 5.3 الـ migration hook مع ESO (ليه post-install أول مرة)

من [`migrate-job.yaml`](../../../k8s/helm/student-app/templates/migrate-job.yaml): `$helmHook := ternary "post-install,pre-upgrade" "pre-install,pre-upgrade" .Values.externalSecrets.enabled`.

- **Helm من غير ESO:** الـ Secret موجود قبل الـ install (kubectl) → `pre-install` → الـ schema جاهز قبل أي pod.
- **Helm مع ESO:** الـ ExternalSecret resource عادي بيتعمل **بعد** الـ pre-install hooks → Job `pre-install` كان هيستنى Secret مش موجود للأبد. فأول install = `post-install` (مفيش إصدار قديم يتوافق معاه؛ الـ pods ممكن تبقى Ready والـ `/login` يرجع 500 لحظات لحد ما الـ Job يخلص)، وكل upgrade بعد كده `pre-upgrade`.
- الـ hook ConfigMap `<fullname>-migrate` (weight `-10`) موجود عشان الـ release ConfigMap مبيبقاش موجود وقت الـ pre-install hooks.
- **Argo CD:** وجود `argocd.argoproj.io/hook` بيخلي Argo **يتجاهل كل الـ Helm hooks**؛ الترتيب بالـ waves: store `-2` → ExternalSecret و hook ConfigMap `-1` → Job `0` → app `1` ([69](69-gitops-argocd.md)).

## 6) الـ Deploy

**A) الـ default (الـ chart بيعمل الـ store):** نفس أمر [63 §6](63-eks-load-balancer-controller-ingress.md) — `-f values-eks.yaml --set rollout.enabled=false`. بعدها:

```bash
kubectl get clustersecretstore
kubectl -n student-app get externalsecret student-app-secrets
kubectl -n student-app get secret student-app-secrets -o json | jq -r '.data | keys[]'
```

**B) الـ store من Terraform:**

```bash
terraform -chdir=infra/terraform/stacks/60-eks output -raw cluster_secret_store_manifest | kubectl apply -f -
kubectl get clustersecretstore aws-parameter-store
helm upgrade --install student-app k8s/helm/student-app -n student-app \
  -f k8s/helm/student-app/values-eks.yaml \
  --set externalSecrets.store.create=false --set externalSecrets.store.name=aws-parameter-store \
  --set-string image.repository=<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/student-app \
  --set-string image.tag=<GIT_SHA> --set rollout.enabled=false --wait --timeout 10m
```

**C) Plain YAML:**

```bash
cd k8s/manifests/overlays/eks
kustomize edit set image student-app=<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/student-app:<GIT_SHA>
kubectl apply -k .
kubectl -n student-app wait --for=condition=complete job/student-app-migrate --timeout=300s
git checkout kustomization.yaml          # التجربة متتعملهاش commit
```

## 7) التحقق (Verify)

```bash
kubectl get clustersecretstore -o wide                                 # STATUS Valid · READY True
kubectl -n student-app get externalsecret student-app-secrets          # STATUS SecretSynced · READY True
kubectl -n student-app describe externalsecret student-app-secrets | tail -15   # Events
diff <(aws ssm get-parameters-by-path --path /student-app/lab/app --query 'Parameters[].Name' --output text \
        | tr '\t' '\n' | sed 's#.*/##' | sort) \
     <(kubectl -n student-app get secret student-app-secrets -o json | jq -r '.data | keys[]' | sort) && echo "same keys"
POD=$(kubectl -n student-app get pod -l app.kubernetes.io/component=web -o name | head -1)
kubectl -n student-app exec "$POD" -- printenv DB_HOST                 # الـ RDS endpoint (من الـ Secret مش الـ ConfigMap)
kubectl -n external-secrets logs deploy/external-secrets --tail=20
```

**Rotation يدوي:**

```bash
aws ssm put-parameter --name /student-app/lab/app/SRE_LAB_TOKEN --type SecureString --overwrite --value "$(openssl rand -hex 16)"
kubectl -n student-app annotate externalsecret student-app-secrets force-sync="$(date +%s)" --overwrite
kubectl -n student-app rollout restart deploy/student-app      # الـ env بيتقري وقت الـ start بس
```

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر | المتوقع |
|---|---|---|
| Path غلط | `--set externalSecrets.ssmPath=/student-app/lab/nope` | الـ ExternalSecret مش synced/الـ Secret فاضي؛ pods جديدة من غير `APP_KEY` → errors. شوف `describe externalsecret` |
| IAM اتشال | امسح الـ Pod Identity association + `kubectl -n external-secrets rollout restart deploy/external-secrets` + force-sync | `SecretSyncedError` و `AccessDenied` في الـ events؛ **الـ Secret الموجود بيفضل** والـ pods الشغالة مش متأثرة |
| Path برا الـ policy | `--set externalSecrets.ssmPath=/student-app/lab/mysql` | AccessDenied — الـ role مقفول على `/app` بس |
| `conditions` | ExternalSecret في namespace `default` بيشاور على `student-app-parameter-store` | مرفوض — الـ store مسموح لـ `student-app` بس |
| Rotation من غير restart | §7 من غير `rollout restart` | الـ Secret اتحدّث، بس `printenv` في الـ pod القديم لسه القيمة القديمة |
| Key في المكانين | `--set-string config.DB_HOST=wrong-host` | ولا حاجة! الـ Secret (من SSM) بيكسب على الـ ConfigMap |
| Uninstall | `helm -n student-app uninstall student-app` | الـ ExternalSecret اتمسح → الـ Secret اتمسح معاه (`creationPolicy: Owner`) |

## 9) الرجوع (Rollback)

قيمة غلط اتكتبت في SSM:

```bash
aws ssm get-parameter-history --name /student-app/lab/app/<KEY> --with-decryption \
  --query 'Parameters[].{v:Version,date:LastModifiedDate}' --output table
aws ssm put-parameter --name /student-app/lab/app/<KEY> --type SecureString --overwrite --value '<OLD_VALUE>'
kubectl -n student-app annotate externalsecret student-app-secrets force-sync="$(date +%s)" --overwrite
kubectl -n student-app rollout restart deploy/student-app
```

لو parameter يملكه Terraform (زي `APP_URL`): صلّحه في الـ tfvars و apply — التعديل اليدوي هيتعمله revert في الـ apply الجاي (drift).

## 10) المسح (Teardown) ⚠️

مفيش موارد جديدة غير اللي عملتها بإيدك:

```bash
aws ssm delete-parameter --name /student-app/lab/app/METRICS_TOKEN
kubectl delete clustersecretstore aws-parameter-store --ignore-not-found     # لو عملت B
```

الباقي بيتمسح مع `terraform destroy` ([62 §10](62-eks-terraform.md)).

## 11) التكلفة (Cost)

| Resource | السعر التقريبي (تقريبي — راجع صفحة الأسعار) |
|---|---|
| SSM Standard parameters | مجاني (لحد 10,000، standard throughput) |
| SSM Advanced parameters | ~$0.05/parameter/شهر (مش محتاجينها) |
| KMS `aws/ssm` (AWS managed key) | الـ key مجاني؛ الـ API calls سنتات |
| Secrets Manager (البديل، [81](81-secrets-management.md)) | ~$0.40/secret/شهر + API calls — بس فيه rotation مدمج |
| ESO | مجاني (pod على الـ nodes) |

## 12) أسئلة Interview

<details><summary>ESO ولا Secrets Store CSI Driver ولا Sealed Secrets؟</summary>

ESO: بيعمل K8s Secret عادي من provider خارجي — بسيط للتطبيقات (envFrom)، بس السر بيبقى في etcd (لازم encryption at rest + RBAC). CSI Driver: بيعمل mount لملفات وقت تشغيل الـ pod من غير Secret object (اختياري sync)، أنسب لو مش عايز السر في etcd، بس الـ pod معتمد على الـ provider وقت الـ start. Sealed Secrets/SOPS: السر متشفّر في git (GitOps خالص)، بس الـ rotation والـ source of truth في git مش في vault. الاختيار حسب: مصدر الحقيقة فين، والـ rotation، والـ threat model.

</details>

<details><summary>السر اتغيّر في SSM — إمتى التطبيق يشوفه؟</summary>

ESO بيحدّث الـ Secret خلال `refreshInterval` (أو force-sync). الـ env vars بتتقري وقت تشغيل الـ container بس، فالـ pods لازم تتعمل restart: `kubectl rollout restart` أو Stakater Reloader (بيراقب الـ Secret ويعمل rollout) أو mounted files + تطبيق بيعيد القراية. والـ rotation الآمن للـ DB password = اتنين credentials صالحين لفترة (dual-user / Secrets Manager rotation) عشان مفيش لحظة pods قديمة بباسورد اتلغى.

</details>

<details><summary>ليه ClusterSecretStore بـ `conditions`؟</summary>

الـ ClusterSecretStore بيستخدم IAM role الـ controller، فأي namespace تقدر تعمل ExternalSecret عليه تقدر تقرا كل اللي الـ role يقدر يقراه. `conditions.namespaces` بيقفله على namespace التطبيق (least privilege جوه الـ cluster). البديل: SecretStore namespaced، أو role لكل namespace بـ `auth` (ESO بيعمل AssumeRole لكل store).

</details>

<details><summary>الـ Secret base64 — هل ده مشكلة؟</summary>

base64 encoding مش تشفير. الحماية الحقيقية: etcd encryption at rest (الستاك عامل KMS envelope encryption للـ secrets)، RBAC ضيّق على `get/list secrets` (الـ `list` بيرجّع القيم!)، `automountServiceAccountToken: false` للـ pods اللي مش محتاجة API، audit logs، ومحدش يحتاج `kubectl get secret` في الشغل العادي.

</details>

<details><summary>env vars ولا mounted files للأسرار؟</summary>

env: بسيط وكل framework بيدعمه (Laravel بيقرا env)، بس بيظهر في `/proc/<pid>/environ` وممكن يتسرّب في crash dumps أو debug pages، ومحتاج restart للتحديث. files: ممكن تتحدّث من غير restart (projected volumes بتتحدّث لوحدها)، وصلاحيات ملف، بس التطبيق لازم يقرا من ملف. للمعمل env كفاية (12-factor + `APP_DEBUG=false`).

</details>

<details><summary>ليه ESO بـ Pod Identity على الـ controller مش على كل app؟</summary>

التطبيق نفسه مبيكلمش AWS خالص (من غير SDK، من غير credentials) — ده blast radius أصغر: pod مخترق ميقدرش ينادي SSM. الـ controller بس عنده الـ role، ومقفول على path واحد و `kms:ViaService`. العيب: الـ controller بقى target مهم (cluster-wide)، فلازم تحميه (namespace منفصل، RBAC، تحديثات).

</details>

## 13) Checklist

- [ ] شفت الـ parameters في Parameter Store وفهمت مين بيكتب إيه
- [ ] فهمت الـ IAM policy بتاعة ESO (path scoping + `kms:ViaService`) و Pod Identity association
- [ ] الـ ClusterSecretStore `Valid` والـ ExternalSecret `SecretSynced` والـ keys مطابقة لـ SSM
- [ ] جرّبت الأشكال التلاتة للـ store (على الأقل A و B)
- [ ] فهمت ليه الـ migration Job `post-install` أول مرة مع ESO
- [ ] عملت rotation + force-sync + restart
- [ ] جرّبت الـ break-it (IAM، conditions، precedence)
