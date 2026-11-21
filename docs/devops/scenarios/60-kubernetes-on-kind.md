# 60 — Kubernetes محلي على kind (أو على GitHub Actions)

> **الهدف في سطر:** تفهم الـ Kubernetes objects الأساسية والتطبيق بتاعنا هو المثال (Namespace، ConfigMap/Secret، Deployment، Service، StatefulSet، Job، HPA، PDB، NetworkPolicy)، تنشره بـ **plain manifests + kustomize** الأول وبعدين بالـ **Helm chart**، وتقرا [`k8s-integration.yml`](../../../.github/workflows/k8s-integration.yml) step بـ step (هو اللي بيعمل كل ده على GitHub runner من غير Docker عندك)، وتعرف تشغّل نفس الحاجة على kind جوه WSL2 لما الموارد تسمح.
> **المستوى:** Beginner → Intermediate · **الوقت:** ~4 ساعات · **التكلفة التقريبية:** مجاني
> **بيعتمد على:** [10 — Containerize](10-containerize-app.md) · [12 — SRE lab endpoints](12-sre-lab-endpoints-and-local-observability.md) · [03 — تجهيز الجهاز](03-workstation-setup.md) (للمسار المحلي بس) · **الملفات في الـ repo:** [`k8s/README.md`](../../../k8s/README.md) · [`k8s/kind/cluster.yaml`](../../../k8s/kind/cluster.yaml) · [`k8s/kind/mysql.yaml`](../../../k8s/kind/mysql.yaml) · [`k8s/manifests/base/`](../../../k8s/manifests/base/kustomization.yaml) · [`k8s/manifests/overlays/kind/kustomization.yaml`](../../../k8s/manifests/overlays/kind/kustomization.yaml) · [`k8s/helm/student-app/values-kind.yaml`](../../../k8s/helm/student-app/values-kind.yaml) · [`.github/workflows/k8s-integration.yml`](../../../.github/workflows/k8s-integration.yml) · [`deploy/scripts/probe.sh`](../../../deploy/scripts/probe.sh)

## 1) الفكرة (Concepts)

Kubernetes مش "بيشغّل containers" وبس؛ هو **reconciliation engine**: إنت بتكتب الـ **desired state** (YAML)، والـ controllers بتفضل تقارن الحالة الفعلية بيها وتصلّح الفرق للأبد. الـ Deployment controller بيعمل ReplicaSet، والـ ReplicaSet بيعمل Pods، والـ scheduler بيحطهم على nodes، والـ kubelet بيشغّلهم ويعمل الـ probes. لو pod مات، محدش "بيعمل restart" بإيده — الـ ReplicaSet شايف 1 بدل 2 فبيعمل واحد جديد.

نفس الـ image بتاع [10](10-containerize-app.md) ونفس العقد ([CONVENTIONS §8](../CONVENTIONS.md)) على 3 مستويات تجريد في [`k8s/`](../../../k8s/README.md): **plain YAML** (تتعلم الـ objects) → **Helm** (chart واحد بـ parameters لـ kind و EKS) → **Argo Rollouts / Argo CD** (progressive delivery و GitOps — [67](67-k8s-bluegreen.md)–[69](69-gitops-argocd.md)).

| الـ Object | في التطبيق بتاعنا | الملف |
|---|---|---|
| **Namespace** | `student-app` + labels الـ Pod Security `restricted` (الـ API server بيرفض أي pod بـ root أو capabilities) | [`namespace.yaml`](../../../k8s/manifests/base/namespace.yaml) |
| **ServiceAccount** | `student-app`، `automountServiceAccountToken: false` (التطبيق مبيكلمش الـ API) | [`serviceaccount.yaml`](../../../k8s/manifests/base/serviceaccount.yaml) |
| **ConfigMap** | `student-app-config`: `APP_ENV`، `DB_HOST=mysql`، `SRE_LAB_ENABLED`... (مش سرّي) | [`configmap.yaml`](../../../k8s/manifests/base/configmap.yaml) |
| **Secret** | `student-app-secrets`: `APP_KEY`، `DB_PASSWORD` — بـ `kubectl create secret` على kind، وبـ ESO من SSM على EKS ([64](64-eks-external-secrets.md)) | [`secret.example.yaml`](../../../k8s/manifests/base/secret.example.yaml) (مش بيتعمله apply) |
| **Pod** | container واحد `app` (PHP-FPM + nginx تحت S6) على بورت `http`=8080، UID 82 | |
| **Deployment → ReplicaSet → Pods** | 2 replicas، `RollingUpdate` بـ `maxSurge: 1` و `maxUnavailable: 0` | [`deployment.yaml`](../../../k8s/manifests/base/deployment.yaml) |
| **Probes** | startup `/up` (لحد 90s)، liveness `/up` (من غير DB)، readiness `/ready` (DB ping) | نفس الملف |
| **Service** | ClusterIP `student-app:80 → targetPort http`؛ على kind بيتحول NodePort `30080` | [`service.yaml`](../../../k8s/manifests/base/service.yaml) |
| **StatefulSet + PVC + headless Service** | MySQL 8.4 **للـ lab بس** (على EKS بنستخدم RDS) | [`k8s/kind/mysql.yaml`](../../../k8s/kind/mysql.yaml) |
| **Job** | `php artisan migrate --force` **مرة لكل release** (مش مع boot كل replica) | [`migrate-job.yaml`](../../../k8s/manifests/base/migrate-job.yaml) |
| **HPA** | 2→6 pods على CPU 70% **من الـ request** (100m) — محتاج metrics-server | [`hpa.yaml`](../../../k8s/manifests/base/hpa.yaml) |
| **PDB** | `maxUnavailable: 1` أثناء drain/upgrade | [`pdb.yaml`](../../../k8s/manifests/base/pdb.yaml) |
| **NetworkPolicy** | ingress على 8080 بس؛ egress: DNS لـ CoreDNS + 3306/6379 | [`networkpolicy.yaml`](../../../k8s/manifests/base/networkpolicy.yaml) |
| **Ingress** | ALB على EKS بس ([63](63-eks-load-balancer-controller-ingress.md)) | [`overlays/eks/ingress.yaml`](../../../k8s/manifests/overlays/eks/ingress.yaml) |

**Labels و selectors = الغراء.** الـ Service بيختار `app.kubernetes.io/name=student-app` + `component=web`، فـ pods الـ migration (`component=migrate`) عمرها ما تبقى endpoints. الـ NetworkPolicy بيختار بالـ `name` بس، فبيغطي الـ app والـ Job مع بعض. والـ selector بتاع Deployment **immutable** بعد أول apply — عشان كده الـ version بيتحط في labels عادية مش في الـ selector.

**kind** = Kubernetes in Docker: كل node عبارة عن container. مفيش registry: الـ images بتتحمّل جوه الـ nodes بـ `kind load docker-image`. البورت الوحيد اللي بيطلع للـ host هو `127.0.0.1:8088` ← NodePort `30080`.

## 2) المعمارية (Architecture)

```text
 laptop (WSL2) أو GitHub runner
   curl / probe.sh / k6 ──► 127.0.0.1:8088
                               │ extraPortMappings (cluster.yaml): 8088 → 30080
 ┌─ kind cluster "student-app-lab" (كل node = Docker container، image kindest/node:v1.36.4@sha256) ┐
 │ control-plane ── NodePort 30080 ── kube-proxy ──► Service student-app (port 80 → http)          │
 │                                                     │  endpoints = الـ pods الـ Ready بس          │
 │  worker  (zone=lab-a)                 worker2 (zone=lab-b)   ◄── fake zones للـ topology spread  │
 │  ┌ student-app-<hash>-aaaa ┐          ┌ student-app-<hash>-bbbb ┐                              │
 │  │ app :8080  /up /ready   │          │ app :8080               │  securityContext UID 82       │
 │  │ preStop sleep 10s       │          │ envFrom: ConfigMap → Secret (الـ Secret بيكسب)          │
 │  └───────────┬─────────────┘          └────────────┬────────────┘                              │
 │              └── NetworkPolicy: egress 3306 للـ mysql pod بس + DNS ──┐                          │
 │  Job student-app-migrate (Helm hook / kubectl wait) ─────────────────►  mysql-0                 │
 │                                    StatefulSet + PVC 2Gi (local-path "standard") + Secret      │
 └──────────────────────────────────────────────────────────────────────────────────────────────┘

 3 طرق تنشر نفس الـ pod spec:
   kubectl apply -k k8s/manifests/overlays/kind          (plain YAML + kustomize — تعليمي)
   helm upgrade --install ... -f values-kind.yaml        (الـ chart — نفس اللي على EKS)
   .github/workflows/k8s-integration.yml                 (نفس الـ Helm path + drills على GitHub runner)
```

## 3) المتطلبات (Prerequisites)

**المسار A — GitHub Actions (من غير أي حاجة على جهازك):**

- [ ] الـ repo على GitHub (Actions متفعّلة) و `gh` متسطب ومعمول له `gh auth login`.
- [ ] قريت [10](10-containerize-app.md) (الـ image والـ endpoints) و [30](30-ci-github-actions.md) (إزاي تقرا الـ workflows).

**المسار B — kind محلي في WSL2 (بعدين لما الموارد تسمح):**

- [ ] WSL2 Ubuntu + Docker Engine جواه ([03 §5.3](03-workstation-setup.md)) و `kind` و `kubectl` و `helm` (v4) متسطبين ([03](03-workstation-setup.md)).
- [ ] الـ repo متعمله clone جوه `~` مش `/mnt/c` (أسرع بكتير في الـ build).
- [ ] RAM: الـ cluster بـ 3 nodes + MySQL + pod-ين للتطبيق ≈ 3–4 GB. خلّي `memory=6GB` على الأقل في `.wslconfig`. لو الجهاز أضعف استخدم الـ **single-node variant** في §6.4.
- الأدوات: `kind` (v0.33.0 في الـ CI) · `kubectl` · `helm` v4 · `docker` · `curl` · `openssl`.

## 4) الطريقة الأولى: "Console" — GitHub Actions UI

مفيش موارد AWS في السيناريو ده. الـ "console" بتاعك هو تاب **Actions**:

1. **GitHub → repo → Actions → K8s integration → Run workflow** → branch `devops-lab` → **Run workflow**.
2. افتح الـ run → الـ job **kind · Helm · zero-downtime · Argo Rollouts canary** → كل step بيتفتح لوحده.
3. تحت الـ run في صفحة **Summary**: جدولين من `probe.sh` (RollingUpdate و Argo Rollouts drills) — دول "الإثبات".
4. لو فشل: افتح step **Diagnostics on failure** — فيه `describe pods` و events و logs و `helm history` و الـ AnalysisRuns.

> 💡 الـ workflow بيشتغل لوحده مع أي push على `devops-lab`/`main`/`master` بيلمس `k8s/**` أو `docker/**` أو `app/**` أو `routes/**` أو `bootstrap/**` أو `config/**` أو `database/**` أو `deploy/scripts/**` أو الـ workflow نفسه. push فيه docs بس **مش** بيشغّله.

## 5) الطريقة التانية: as Code — الـ manifests سطر بسطر

### 5.1 الـ base والـ kustomize

[`kustomization.yaml`](../../../k8s/manifests/base/kustomization.yaml) في الـ base بيعمل 3 حاجات: `namespace: student-app` على كل object، labels مشتركة (`part-of`، `managed-by: kustomize`) **حتى على الـ pod templates** (`includeTemplates: true`)، وقائمة الـ resources. لاحظ إن `secret.example.yaml` **مش** في القائمة: الأسرار عمرها ما تيجي من git.

الـ overlay بتاع kind ([`overlays/kind/kustomization.yaml`](../../../k8s/manifests/overlays/kind/kustomization.yaml)):

| الجزء | بيعمل إيه | الـ gotcha |
|---|---|---|
| `images: [{name: student-app, newTag: ci-v1}]` | يحط الـ tag على الـ Deployment والـ Job مع بعض | الـ tag = SHA في الحقيقة؛ هنا `ci-v1` لأن الـ image متبنية محلياً |
| patch على الـ Service | `type: NodePort` و `nodePort: 30080` | الـ ports بتتعمل merge على (port, protocol): **من غير `protocol: TCP` الـ patch مش بيطابق والـ nodePort بيقع بصمت** |
| JSON patch على الـ NetworkPolicy | `op: add` على `/spec/egress/1/to` → podSelector `name=mysql` | الـ DB egress بيبقى للـ MySQL pod بس، مش أي IP على 3306 |

الـ patches **inline** عن قصد: [`lint-infra.yml`](../../../.github/workflows/lint-infra.yml) بيعدّي `kubeconform -strict` على كل YAML تحت `k8s/` كـ object كامل، وملف patch جزئي كان هيفشل الـ check.

```bash
kubectl kustomize k8s/manifests/overlays/kind | less        # شوف الناتج قبل أي apply
kubectl kustomize k8s/manifests/overlays/kind | grep -n "nodePort\|image:\|namespace:"
```

### 5.2 الـ Deployment — كل field ليه سبب

| Field | القيمة | ليه |
|---|---|---|
| `strategy.rollingUpdate` | `maxSurge: 1`، `maxUnavailable: 0` | الـ capacity عمرها ما تقل عن 2؛ pod جديد لازم يبقى Ready قبل ما قديم يمشي ([66](66-k8s-rolling-recreate.md)) |
| `progressDeadlineSeconds` | 300 | release مبيوصلش Ready (`SRE_FAULT_UNHEALTHY`) بيتعلّم `ProgressDeadlineExceeded` والقديم شغال |
| `topologySpreadConstraints` | zone ثم hostname، `ScheduleAnyway`، `matchLabelKeys: [pod-template-hash]` | توزيع على الـ zones المزيفة (`lab-a`/`lab-b`) زي 2 AZs؛ best effort فمبيوقفش rollout على cluster صغير؛ الـ skew محسوب لكل revision |
| `startupProbe` | `/up` كل 2s × 45 | أول boot بطيء (S6 + `php artisan optimize`) من غير ما الـ liveness يقتل الـ pod |
| `livenessProbe` | `/up` | "الـ process واقف؟" — `/up` مبيلمسش الـ DB، فالـ DB outage **مش** بيعمل restart storm |
| `readinessProbe` | `/ready` كل 5s، `failureThreshold: 2` | "أستقبل traffic؟" — بيعمل DB ping وبيحترم `POST /sre-lab/unready`؛ الفشل = خروج من الـ endpoints بس |
| `lifecycle.preStop.sleep` | 10s (native sleep action، من غير shell) | إزالة الـ endpoint بتنتشر async (kube-proxy، الـ ALB)؛ نفضل نخدم 10s وبعدين `SIGQUIT` |
| `terminationGracePeriodSeconds` | 40 | لازم يساع preStop (10) + graceful PHP-FPM (≤ 30) وإلا SIGKILL للـ requests |
| `resources` | requests 100m/256Mi، limits 1 CPU/512Mi | الـ requests = الـ scheduling والـ HPA math؛ الـ memory limit = OOMKill لـ pod واحد مش مشكلة node |
| `securityContext` | non-root 82، drop ALL، seccomp RuntimeDefault | يعدّي PSS `restricted` |
| `enableServiceLinks: false` | | من غير env var لكل Service في الـ namespace (زي `MYSQL_PORT` اللي بيتخانق مع إعدادات التطبيق) |

### 5.3 مشكلة الـ migrate Job في الـ plain YAML

[`migrate-job.yaml`](../../../k8s/manifests/base/migrate-job.yaml) بيوضّح حدود الـ plain YAML بصراحة:

1. `kubectl apply -k` بيعمل الـ Job **مع** الـ Deployment في نفس اللحظة → pods جديدة ممكن تقوم قبل الـ schema (الـ readiness بيشيّك على الاتصال بالـ DB، مش على الـ tables).
2. الـ pod template بتاع Job **immutable** → release جديد = لازم تمسح الـ Job القديم الأول (`ttlSecondsAfterFinished: 600` بيمسحه لوحده بعد 10 دقايق).
3. `backoffLimit: 1` و `activeDeadlineSeconds: 300`: retry واحد لـ hiccup، و migration بايظة تفشل بصوت عالي مش تلف للأبد.
4. `args` مش `command` → الـ ENTRYPOINT والـ `/etc/entrypoint.d` شغالين. و `AUTORUN_ENABLED=false` → من غير `optimize`. ومن غير `--isolated` (محتاج `cache_locks` اللي مش موجود على DB فاضية — [CONVENTIONS §2](../CONVENTIONS.md)).

الحل الصح: **Helm hook** (`pre-install,pre-upgrade`) أو **Argo CD sync wave** — وده سبب وجود الـ chart ([65](65-helm-chart.md)) والـ annotations `argocd.argoproj.io/*` اللي في نفس الملف ([69](69-gitops-argocd.md)).

### 5.4 نفس الحاجة بالـ Helm chart

الـ chart ([`k8s/helm/student-app`](../../../k8s/helm/student-app/Chart.yaml)) بيعمل **نفس الـ pod spec** (`_helpers.tpl` → `student-app.podTemplate`) وبيحل المشاكل اللي فوق: الـ migration hook، `checksum/config` (تغيير الـ ConfigMap بيعمل roll للـ pods)، وإن الـ HPA لما يبقى شغال الـ `replicas` field بيتشال. [`values-kind.yaml`](../../../k8s/helm/student-app/values-kind.yaml) بيغيّر: `image.pullPolicy: Never` (أي image ناقصة = `ErrImageNeverPull` فوراً بدل ما يدوّر على Docker Hub)، `service.type: NodePort` + `nodePort: 30080`، `config.DB_HOST: mysql`، `autoscaling.enabled: false` (kind من غير metrics-server)، و `networkPolicy.databaseTo` = الـ MySQL pod. التفاصيل كلها في [65](65-helm-chart.md).

## 6) الـ Deploy

### 6.1 المسار A: `k8s-integration.yml` بيثبت إيه، step بـ step

الـ env في أول الـ workflow: `CLUSTER=student-app-lab`، `NS=student-app`، `RELEASE=student-app`، `BASE=http://127.0.0.1:8088`، والـ versions متثبتة (`KIND_VERSION: v0.33.0`، `HELM_VERSION: v4.3.2`، `ARGO_ROLLOUTS_VERSION: v1.10.2`، `PROMETHEUS_CHART_VERSION: 29.48.0`). `concurrency` بيلغي الـ run القديم على نفس الـ ref، و `timeout-minutes: 45` للـ job.

| # | Step | بيعمل إيه | بيثبت إيه |
|---|---|---|---|
| 1 | Build ci-v1 / ci-v2 | `docker/build-push-action` بـ `load: true` و `APP_VERSION=ci-v1/ci-v2`، cache `type=gha` | الـ Dockerfile بيتبني؛ release تاني = نفس الكود و layer أخير مختلف (فالـ version في `/ready` بيفرّق بينهم) |
| 2 | Create kind cluster | `helm/kind-action` بـ `k8s/kind/cluster.yaml` و `wait: 180s` | الـ cluster definition نفسه اللي بتستخدمه محلياً |
| 3 | Load both images | `kind load docker-image student-app:ci-v1 student-app:ci-v2` | مفيش registry؛ ولهذا `pullPolicy: Never` |
| 4 | kubectl-argo-rollouts plugin | download + **`sha256sum -c`** على الـ checksums | supply chain: binary متثبت بالـ version والـ checksum |
| 5 | Namespace + lab MySQL | `namespace.yaml` ثم `mysql.yaml` ثم `rollout status statefulset/mysql` | الـ PSS `restricted` بيسمح للـ MySQL (UID 999) |
| 6 | App Secret | يقرا `MYSQL_PASSWORD` من `mysql-credentials`، `::add-mask::`، و `create secret --dry-run=client -o yaml \| kubectl apply -f -` | مصدر واحد للـ password؛ والـ pattern ده idempotent (re-run مبيفشلش بـ AlreadyExists) |
| 7 | helm install ci-v1 | `helm upgrade --install ... -f values-kind.yaml --set-string image.tag=ci-v1 --wait --timeout 6m` | الـ pre-install hook عمل migrate **قبل** الـ pods، والـ pods بقت Ready |
| 8 | Smoke tests | `/up`، `/ready` فيه `"status":"ready"` و `"version":"ci-v1"`، `/login` = 200، `/metrics` فيه `student_app_app_info{version="ci-v1"` | الـ NodePort شغال؛ **`/login` محتاج جدول `sessions` → إثبات إن الـ migration hook اشتغل قبل التطبيق** |
| 9 | Zero-downtime RollingUpdate | `probe.sh` على `/ready` كل 50ms بـ `MAX_FAILURES=0` في الخلفية → `helm upgrade` لـ ci-v2 → يستنى لحد ما pods الـ ci-v1 تختفي خالص → `touch $stop` → `wait $probe` | **0 failed requests** طول الـ rollout **وطول الـ preStop والـ graceful shutdown** للقديم (هنا بالظبط بتظهر الـ requests اللي بتقع) |
| 10 | Install Argo Rollouts | `kubectl apply --server-side` للـ `install.yaml` المتثبت | الـ CRDs كبيرة على client-side apply (حد الـ 256KiB annotation) |
| 11 | Minimal Prometheus | chart `prometheus` 29.48.0، scrape كل 10s بالـ annotations، من غير alertmanager/PV | الـ analysis محتاج metrics حقيقية |
| 12 | Switch to an Argo Rollout | `helm upgrade ... --set rollout.enabled=true` → `kubectl argo rollouts status` | نفس الـ pod template؛ أول revision للـ Rollout بيتعمل full scale من غير steps ([68](68-k8s-canary-argo-rollouts.md)) |
| 13 | Canary drills | traffic على `/login` + probe على `/ready` بـ `MAX_FAILURES=0` → canary سليم ci-v1 (promoted) → canary سيء ci-v2 بـ `extraEnv.SRE_FAULT_ERROR_RATE=0.5` (لازم **ميتعملوش promote**، phase = `Degraded`، `abort=true`) → `helm rollback` → Healthy | الـ analysis بيمسك الـ bad release لوحده، والـ stable مقعش ولا request على `/ready` |
| 14 | Diagnostics on failure | `if: failure()`: nodes، pods، describe، logs، events، `helm history`، AnalysisRuns، logs الـ controller | كل اللي محتاجه عشان تحقق من غير ما تعيد التشغيل |

> 💡 **ليه step 9 بيستنى الـ pods القديمة تختفي؟** `helm --wait` بيرجع أول ما الـ pods الجديدة تبقى Ready، بس القديمة لسه في الـ preStop sleep والـ SIGQUIT. لو وقفت الـ probe ساعتها هتفوّت بالظبط الفترة اللي فيها الـ requests بتقع لو الـ preStop غلط. ده فرق بين "اختبار بيعدّي" و "اختبار بيثبت حاجة".

### 6.2 إزاي تقرا الـ logs

```bash
gh workflow run k8s-integration.yml --ref devops-lab        # تشغيل يدوي
gh run list --workflow=k8s-integration.yml --limit 5
gh run watch <RUN_ID>
gh run view <RUN_ID> --log | grep -E "probe summary|requests|failed|availability|answered by" | head -40
gh run view <RUN_ID> --log-failed                           # الـ steps اللي فشلت بس
gh run view <RUN_ID> --web                                  # الـ Summary فيه جداول الـ probe
```

شكل الـ summary اللي `probe.sh` بيطبعه (الحقول من [`probe.sh`](../../../deploy/scripts/probe.sh) نفسه):

```text
================ probe summary ================
url            : http://127.0.0.1:8088/ready
duration       : <N>s
requests       : <N>
failed         : 0
availability   : 100.000%
answered by    :
  ci-v1                            <N>
  ci-v2                            <N>
===============================================
```

`answered by` فيه الإصدارين = الـ traffic اتنقل فعلاً أثناء الـ probe. `failed : 0` = الإثبات.

| العَرَض في الـ log | السبب الغالب | تبص فين |
|---|---|---|
| step 7 timeout | الـ hook Job فشل (DB مش جاهزة، migration بايظة) أو `ErrImageNeverPull` | Diagnostics: `get job`، `logs`، events |
| `ci-v1 pods still present after 120 s` | preStop/grace أطول من المتوقع أو pod معلّق في Terminating | `describe pods` |
| `[probe] ... FAIL http=000` في step 9 | request وقع أثناء الـ rollout (preStop قصير، readiness غلط) | قارن التوقيت بـ events الـ pods |
| `the bad release was promoted` | الـ analysis مشافش الـ errors (scraping، الـ query، مفيش traffic) | AnalysisRun YAML في الـ Diagnostics |

### 6.3 المسار B: kind محلي في WSL2

```bash
cd ~/src/StudentHub
kind create cluster --config k8s/kind/cluster.yaml                       # ~1 دقيقة، 3 nodes
docker build -f docker/Dockerfile --build-arg APP_VERSION=ci-v1 -t student-app:ci-v1 .
docker build -f docker/Dockerfile --build-arg APP_VERSION=ci-v2 -t student-app:ci-v2 .
kind load docker-image student-app:ci-v1 student-app:ci-v2 --name student-app-lab

kubectl apply -f k8s/manifests/base/namespace.yaml                       # namespace + PSS labels
kubectl apply -f k8s/kind/mysql.yaml
kubectl -n student-app rollout status statefulset/mysql --timeout=240s

DB_PASSWORD=$(kubectl -n student-app get secret mysql-credentials -o jsonpath='{.data.MYSQL_PASSWORD}' | base64 -d)
kubectl -n student-app create secret generic student-app-secrets \
  --from-literal=APP_KEY="base64:$(openssl rand -base64 32)" \
  --from-literal=DB_USERNAME=student \
  --from-literal=DB_PASSWORD="$DB_PASSWORD"
```

**اختيار 1 — plain manifests (تعليمي):**

```bash
kubectl apply -k k8s/manifests/overlays/kind
kubectl -n student-app wait --for=condition=complete job/student-app-migrate --timeout=300s
kubectl -n student-app rollout status deployment/student-app --timeout=180s
curl -s localhost:8088/ready; echo

# release جديد بالـ plain YAML: امسح الـ Job (immutable) → غيّر الـ tag → apply → استنى الـ Job
kubectl -n student-app delete job student-app-migrate --ignore-not-found
(cd k8s/manifests/overlays/kind && kustomize edit set image student-app=student-app:ci-v2)   # أو عدّل newTag بإيدك
kubectl apply -k k8s/manifests/overlays/kind
git checkout k8s/manifests/overlays/kind/kustomization.yaml        # متعملش commit للتجربة
```

**اختيار 2 — الـ Helm chart (نفس اللي في الـ CI وعلى EKS):** امسح الـ plain objects الأول عشان الاتنين بيستخدموا نفس الأسماء (`student-app`):

```bash
kubectl delete -k k8s/manifests/overlays/kind --ignore-not-found     # بيمسح الـ namespace كمان!
# ↑ لو مسحته، أعد الـ namespace و mysql والـ Secret من أول الـ block اللي فوق
helm upgrade --install student-app k8s/helm/student-app -n student-app \
  -f k8s/helm/student-app/values-kind.yaml --set-string image.tag=ci-v1 --wait --timeout 6m
helm -n student-app status student-app            # بيطبع الـ NOTES.txt: أوامر الـ check
curl -s localhost:8088/ready; echo
```

> ⚠️ `kubectl delete -k` على الـ overlay بيمسح الـ **Namespace** لأنه جزء من الـ base — وده بيمسح MySQL والـ Secret معاه. لو عايز تحتفظ بيهم: `kubectl -n student-app delete deploy,svc,hpa,pdb,networkpolicy,cm,sa,job -l app.kubernetes.io/managed-by=kustomize`.

### 6.4 Single-node variant (لو الـ RAM قليلة)

نفس اسم الـ cluster ونفس الـ port mapping، node واحدة (الـ topology spread `ScheduleAnyway` فمش هيمنع حاجة؛ بس drain/PDB في [66](66-k8s-rolling-recreate.md) محتاجين worker-ين):

```bash
cat <<'EOF' | kind create cluster --config -
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: student-app-lab
nodes:
  - role: control-plane
    image: kindest/node:v1.36.4@sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed
    extraPortMappings:
      - containerPort: 30080
        hostPort: 8088
        listenAddress: "127.0.0.1"
        protocol: TCP
EOF
```

## 7) التحقق (Verify)

```bash
kubectl get nodes -L topology.kubernetes.io/zone
kubectl -n student-app get deploy,rs,pods,svc,endpointslices,pdb,networkpolicy,cm,secret -o wide
kubectl -n student-app describe pod -l app.kubernetes.io/component=web | grep -A3 -E "Liveness|Readiness|Startup"
kubectl -n student-app logs -l app.kubernetes.io/component=web --prefix --tail=20     # JSON على stderr
curl -s localhost:8088/ready; echo                                                    # {"status":"ready","checks":{"database":"ok"},"version":"ci-v1",...}
curl -s localhost:8088/metrics | grep student_app_app_info
curl -s -o /dev/null -w '%{http_code}\n' localhost:8088/login                         # 200 = الـ migrations اتعملت
bash deploy/scripts/probe.sh http://localhost:8088/ready 20 0.2
```

اختبر الـ NetworkPolicy من جوه الـ pod (الـ image فيه PHP أكيد، مش لازم curl):

```bash
POD=$(kubectl -n student-app get pod -l app.kubernetes.io/component=web -o name | head -1)
kubectl -n student-app exec "$POD" -- php -r 'var_dump(@fsockopen("1.1.1.1", 443, $e, $s, 3));'   # bool(false) = الـ egress مقفول
kubectl -n student-app exec "$POD" -- php -r 'var_dump((bool) @fsockopen("mysql", 3306, $e, $s, 3));'  # bool(true)
```

المفروض: pod-ين `Running` و `1/1` على worker-ين مختلفين (zones مختلفة)، الـ EndpointSlice فيه IPs الاتنين، `/ready` = 200، والإنترنت مقفول من الـ pod.

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر | المتوقع |
|---|---|---|
| Image مش موجودة | `helm upgrade ... --set-string image.tag=ci-v9` | الـ pod الجديد `ErrImageNeverPull`، القديمة شغالة (`maxUnavailable: 0`)، و `helm --wait` بيفشل بعد الـ timeout |
| `latest` | `helm template x k8s/helm/student-app --set-string image.tag=latest` | الـ render نفسه بيفشل: `image.tag=latest is not allowed` |
| الـ Secret اتمسح | `kubectl -n student-app delete secret student-app-secrets` ثم `kubectl -n student-app rollout restart deploy/student-app` | الـ pods الجديدة `CreateContainerConfigError`؛ القديمة شغالة لحد ما ترجّع الـ Secret |
| الـ DB وقعت | `kubectl -n student-app scale statefulset mysql --replicas=0` | `/ready` = 503 والـ pods `0/1` (خرجت من الـ endpoints) **من غير restarts** لأن الـ liveness على `/up`. رجّع بـ `--replicas=1` |
| PSS | `kubectl -n student-app run root-test --image=busybox -- sleep 3600` | رفض: violates PodSecurity "restricted" |
| self-healing | `kubectl -n student-app delete pod -l app.kubernetes.io/component=web --wait=false` | الـ ReplicaSet بيعمل pods جديدة فوراً (وفيه لحظة من غير endpoints — ده سبب الـ PDB في الـ drains) |
| ConfigMap بالـ plain YAML | غيّر `LOG_LEVEL` في الـ ConfigMap و `kubectl apply -k` | الـ pods **مش** بتتأثر لحد `kubectl rollout restart`؛ في الـ chart الـ `checksum/config` بيحلها |

## 9) الرجوع (Rollback)

```bash
helm -n student-app history student-app
helm -n student-app rollback student-app <REVISION> --wait     # Helm
kubectl -n student-app rollout undo deployment/student-app     # plain YAML (الـ ReplicaSet القديم لسه موجود: revisionHistoryLimit 5)
kubectl -n student-app rollout history deployment/student-app
```

الـ migrations مش بترجع مع الـ rollback — نفس شرط الـ expand/contract ([95](95-zero-downtime-db-migrations.md)). في الـ CI: `git revert <SHA>` → push → run جديد.

## 10) المسح (Teardown) ⚠️

```bash
kind delete cluster --name student-app-lab
docker image rm student-app:ci-v1 student-app:ci-v2
docker system prune -f            # الـ build cache بياكل GBs
```

ومن PowerShell لو عايز ترجّع الـ RAM لـ Windows: `wsl --shutdown`. على GitHub مفيش حاجة تتمسح (الـ runner بيتمسح لوحده).

## 11) التكلفة (Cost)

| Resource | السعر التقريبي |
|---|---|
| kind محلي | مجاني (RAM/CPU جهازك) |
| GitHub Actions | مجاني للـ public repo؛ الـ private بياكل من الدقائق الشهرية المجانية (الـ run ~20–35 دقيقة) |
| GitHub Actions cache | مجاني في حدود الـ quota الافتراضية للـ repo |

## 12) أسئلة Interview

<details><summary>liveness و readiness و startup — الفرق؟ وليه الـ liveness عندنا مبيلمسش الـ DB؟</summary>

الـ startup بيحمي أول boot بطيء (لحد ما ينجح الـ liveness/readiness مش بيشتغلوا). الـ liveness سؤاله "الـ process واقف ومحتاج restart؟" — فشله = kill. الـ readiness سؤاله "أبعتله traffic؟" — فشله = يخرج من الـ endpoints بس. لو الـ liveness شيّك على الـ DB، أي blip في الداتابيز هيعمل restart لكل الـ pods مع بعض (restart storm) والـ restart مبيصلحش الداتابيز أصلاً. القاعدة: الـ liveness يشيّك على حاجة الـ restart بيصلحها بس.

</details>

<details><summary>إزاي `maxUnavailable: 0` + readiness بيدّوا zero-downtime؟ وليه لسه محتاج preStop؟</summary>

`maxUnavailable: 0` + `maxSurge: 1` = الـ controller بيعمل pod جديد، يستنى الـ readiness، وبعدين يشيل قديم — الـ capacity عمرها ما تقل. بس شيل القديم بيحصل بالتوازي: الـ kubelet بيبعت الـ signal وفي نفس الوقت الـ endpoint controller بيشيل الـ IP، و kube-proxy (أو الـ ALB) بياخد وقت عشان يعرف. الـ preStop sleep بيخلي الـ pod يكمّل يخدم الـ requests اللي لسه جاية لحد ما الانتشار يخلص، وبعدها `SIGQUIT` graceful. ولازم `terminationGracePeriodSeconds` يساع الاتنين.

</details>

<details><summary>ليه الـ migrations Job/hook مش init container؟</summary>

الـ init container بيشتغل مع **كل pod**: مع 6 replicas و rolling update هيبقى عندك migrations متوازية على نفس الـ schema (race، locks، أو migration نص معمولة). كمان الـ HPA لما يعمل scale بيشغّلها تاني من غير داعي. الـ Job/hook = مرة واحدة لكل release، في مكان واحد، وفشلها بيوقف الـ release قبل ما أي pod جديد يقوم.

</details>

<details><summary>kustomize ولا Helm؟</summary>

kustomize: YAML عادي + patches، مفيش templating، سهل تقراه وتعمله diff، مدمج في kubectl — ممتاز لـ overlays بسيطة. Helm: templates + values + packaging + release history + hooks + rollback — ممتاز لما الـ logic يكبر (Deployment أو Rollout حسب flag، Ingress حسب الـ class، ordering للـ migrations). عندنا الاتنين: الـ plain YAML للتعلم، والـ chart للـ environments الحقيقية. وكتير من الفرق بتعمل Helm chart وتعدّل عليه بـ kustomize (post-rendering).

</details>

<details><summary>NetworkPolicy موجودة يبقى آمن؟</summary>

لأ لوحدها. الـ NetworkPolicy object مجرد API؛ لازم CNI بيطبقها (kindnet من kind v0.24، والـ VPC CNI على EKS بـ `enableNetworkPolicy`). من غيره الـ object موجود ومفيش أي أثر. وأول ما pod يتختار بـ policy فيها `Egress` كل حاجة مش مذكورة بتتقفل — بما فيها DNS (عشان كده أول rule هو CoreDNS) والـ metadata endpoint `169.254.169.254` (ودي ميزة: pod مخترق مياخدش credentials الـ node).

</details>

<details><summary>Pod Security Standard `restricted` بيفرض إيه؟</summary>

non-root (`runAsNonRoot`)، ممنوع privilege escalation، drop ALL capabilities، seccomp profile (`RuntimeDefault`)، ومن غير hostPath/hostNetwork/privileged. بيتفرض بـ labels على الـ namespace (`enforce`/`warn`/`audit`) من الـ admission controller المدمج. عشان كده التطبيق (UID 82) والـ Job والـ MySQL (UID 999) كلهم مكتوبين يعدّوه.

</details>

<details><summary>ليه kind بـ 3 nodes و zones مزيفة؟</summary>

عشان الـ topologySpreadConstraints والـ PDB والـ drain يتصرفوا زي cluster حقيقي صغير (2 AZs). على node واحدة كل pods هتبقى على نفس الـ node، ومفيش drain تقدر تجرّبه من غير downtime. والـ node image متثبتة بالـ digest (v1.36، جوه الـ EKS standard support)، فاللي يعدّي هنا بيتصرف نفس الشيء على EKS.

</details>

## 13) Checklist

- [ ] قريت `k8s-integration.yml` وعارف كل step بيثبت إيه (خصوصاً step الـ smoke على `/login` وانتظار الـ pods القديمة)
- [ ] شغّلت الـ workflow يدوي وقريت جداول الـ probe في الـ Summary
- [ ] فهمت الـ base والـ overlay (NodePort + `protocol: TCP`، الـ JSON patch على الـ NetworkPolicy)
- [ ] (محلي) شغّلت kind ونشرت بالـ plain manifests وبعدين بالـ chart
- [ ] جرّبت الـ break-it (DB وقعت من غير restarts، PSS، Secret ناقص)
- [ ] أقدر أشرح liveness vs readiness وليه الـ migration hook مش init container
- [ ] عملت `kind delete cluster`
