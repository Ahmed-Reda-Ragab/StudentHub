# 67 — Blue/Green على Kubernetes

> **الهدف في سطر:** تعمل blue/green مرتين: مرة **بإيدك** بـ Deployment-ين و **Service selector switch** (عشان تفهم الآلية)، ومرة بـ **Argo Rollouts `blueGreen`** من الـ chart (`values-bluegreen.yaml`): preview Service، **pre-promotion analysis**، promote يدوي، `scaleDownDelaySeconds` كـ rollback window — وتعرف حدود كل gate.
> **المستوى:** Intermediate → Advanced · **الوقت:** ~3 ساعات · **التكلفة التقريبية:** مجاني على kind (على EKS: capacity مضاعفة وقت الـ release)
> **بيعتمد على:** [66 — Rolling و Recreate](66-k8s-rolling-recreate.md) · [23 — Blue/Green على سيرفر واحد](23-bluegreen-single-host.md) · [45 — Blue/Green بـ ASG-ين](45-bluegreen-two-asgs.md) · **الملفات في الـ repo:** [`values-bluegreen.yaml`](../../../k8s/helm/student-app/values-bluegreen.yaml) · [`templates/rollout.yaml`](../../../k8s/helm/student-app/templates/rollout.yaml) · [`templates/analysistemplate.yaml`](../../../k8s/helm/student-app/templates/analysistemplate.yaml) · [`templates/service.yaml`](../../../k8s/helm/student-app/templates/service.yaml) · [`k8s/rollouts/bluegreen.yaml`](../../../k8s/rollouts/bluegreen.yaml) · [`k8s/rollouts/analysis-web.yaml`](../../../k8s/rollouts/analysis-web.yaml) · [`k8s/rollouts/analysis-prometheus.yaml`](../../../k8s/rollouts/analysis-prometheus.yaml) · [`k8s/manifests/base/service.yaml`](../../../k8s/manifests/base/service.yaml) · [`loadtest/k6/canary-watch.js`](../../../loadtest/k6/canary-watch.js)

## 1) الفكرة (Concepts)

**Blue/Green** = بيئتين كاملتين؛ واحدة live والتانية idle. بتنشر على الـ idle، تختبرها وهي **مش واخدة traffic من المستخدمين**، وبعدين تحوّل 100% مرة واحدة. الـ rollback = تحويل تاني للقديمة اللي لسه شغالة.

في Kubernetes "التحويل" = تغيير **الـ selector بتاع الـ Service** (أو الـ ALB target group). الـ API update ذري، بس الانتشار مش لحظي: kube-proxy على كل node بيتحدّث خلال ثواني، والـ ALB بيعمل register/deregister، والـ connections الـ keep-alive القديمة بتفضل على الـ blue لحد ما تتقفل — عشان كده الـ blue **لازم يفضل شغال** شوية بعد الـ switch.

| المصطلح | المعنى |
|---|---|
| Active / Preview Service | اللي المستخدمين عليه / اللي بيشاور على الإصدار الجديد قبل الـ promote (للاختبار والـ analysis) |
| `autoPromotionEnabled: false` | الـ switch قرار إنسان (أو pipeline step): `kubectl argo rollouts promote` |
| `prePromotionAnalysis` | gate **قبل** الـ switch؛ فشله = abort والـ active متغيّرش |
| `postPromotionAnalysis` | gate **بعد** الـ switch (traffic حقيقي)؛ فشله = رجوع للـ blue اللي لسه شغال |
| `scaleDownDelaySeconds` | الـ blue يفضل كام ثانية بعد الـ switch: rollback فوري + وقت للـ kube-proxy/ALB |
| `previewReplicaCount` | تشغّل الـ preview بعدد أقل (توفير) وبعدين يكبر قبل الـ switch |
| Abort / Undo | abort = ارمي الـ preview والـ active زي ما هو؛ undo = ارجع لـ revision سابقة |

**مقارنة سريعة:**

| | Rolling ([66](66-k8s-rolling-recreate.md)) | Blue/Green | Canary ([68](68-k8s-canary-argo-rollouts.md)) |
|---|---|---|---|
| إصدارين بيخدموا مع بعض | أيوه (دقايق) | لأ (لحظات) | أيوه (عن قصد، بنسب) |
| اختبار قبل أي traffic | لأ | **أيوه** (preview) | جزئياً (أول خطوة صغيرة) |
| Rollback | rollout تاني | **فوري** (لو الـ blue لسه موجود) | abort فوري |
| Capacity إضافية | `maxSurge` | **×2** وقت الـ release | جزء |
| Blast radius لو الـ bug بيظهر تحت traffic بس | تدريجي | **100% مرة واحدة** | صغير |

## 2) المعمارية (Architecture)

```text
 (A) يدوي — Service selector switch
                 Service student-app (NodePort 30080 على kind)
                 selector: {name: student-app, component: bg-plain, slot: blue}
                        │                                     kubectl patch svc … slot: green
           ┌────────────┴───────────┐                                   │
   Deployment student-app-blue        Deployment student-app-green  ◄────┘ (اتختبر قبلها بـ port-forward)
   ci-v1, DEPLOY_COLOR=blue ×2        ci-v2, DEPLOY_COLOR=green ×2

 (B) Argo Rollouts blueGreen (الـ chart + values-bluegreen.yaml)
   users ──► Service student-app (active) ── selector += rollouts-pod-template-hash=<blue hash>
   tests ──► Service student-app-preview  ── selector += rollouts-pod-template-hash=<green hash>
                         ▲
   AnalysisRun student-app-ready (web): GET http://student-app-preview.student-app.svc.cluster.local:80/ready
                         └ $.status == "ready" ×3 كل 10s (503 = measurement error، 3 ورا بعض = فشل)
   Rollout:  new RS (green) → Available → prePromotionAnalysis ✔ → Paused (BlueGreenPause)
             → kubectl argo rollouts promote → active selector = green hash (خطوة واحدة)
             → blue RS يفضل scaleDownDelaySeconds (60 في values-bluegreen) → scale to 0
             [postPromotionAnalysis: error-rate من Prometheus على الـ active الجديد — off افتراضياً]
```

## 3) المتطلبات (Prerequisites)

- [ ] kind بـ 3 nodes ([60](60-kubernetes-on-kind.md)) و `ci-v1`/`ci-v2` محمّلين، و MySQL + `student-app-secrets`.
- [ ] Argo Rollouts controller + الـ plugin `kubectl-argo-rollouts` (نفس versions الـ CI):

```bash
kubectl create namespace argo-rollouts --dry-run=client -o yaml | kubectl apply -f -
kubectl apply --server-side -n argo-rollouts \
  -f https://github.com/argoproj/argo-rollouts/releases/download/v1.10.2/install.yaml
kubectl -n argo-rollouts rollout status deployment/argo-rollouts --timeout=180s
base=https://github.com/argoproj/argo-rollouts/releases/download/v1.10.2
curl -fsSLO "$base/kubectl-argo-rollouts-linux-amd64"
curl -fsSL "$base/argo-rollouts-checksums.txt" | grep ' kubectl-argo-rollouts-linux-amd64$' | sha256sum -c -
sudo install -m 0755 kubectl-argo-rollouts-linux-amd64 /usr/local/bin/kubectl-argo-rollouts
kubectl argo rollouts version
```

(على EKS: Terraform بيركّب `argo-rollouts` 2.43.12 بالـ dashboard لما `install_addons = true` — [62](62-eks-terraform.md).)

## 4) الطريقة الأولى: "Console" — Argo Rollouts dashboard

```bash
kubectl argo rollouts dashboard                                            # محلي → http://localhost:3100
kubectl -n argo-rollouts port-forward svc/argo-rollouts-dashboard 3100:3100   # الـ dashboard اللي Terraform ركّبه على EKS
```

الـ UI بيوريك الـ ReplicaSets (stable/active/preview)، الـ AnalysisRuns، وزراير **Promote** و **Abort** و **Rollback** — نفس أوامر الـ CLI. استخدمه في §6.2 جنب الـ terminal.

## 5) الطريقة التانية: as Code

### 5.1 (A) الطريقة اليدوية — Deployment-ين + selector

مش موجودة كملفات في الـ repo (عن قصد — هي تمرين فهم). الـ manifest ده بيعيد استخدام `student-app-config` و `student-app-secrets` و الـ ServiceAccount من الـ plain manifests، ويعدّي PSS `restricted`:

```bash
cat > /tmp/bg-blue.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: student-app-blue
  namespace: student-app
  labels: {app.kubernetes.io/name: student-app, app.kubernetes.io/component: bg-plain, slot: blue}
spec:
  replicas: 2
  selector:
    matchLabels: {app.kubernetes.io/name: student-app, app.kubernetes.io/component: bg-plain, slot: blue}
  template:
    metadata:
      labels: {app.kubernetes.io/name: student-app, app.kubernetes.io/component: bg-plain, slot: blue}
    spec:
      serviceAccountName: student-app
      automountServiceAccountToken: false
      enableServiceLinks: false
      terminationGracePeriodSeconds: 40
      securityContext: {runAsNonRoot: true, runAsUser: 82, runAsGroup: 82, fsGroup: 82, seccompProfile: {type: RuntimeDefault}}
      containers:
        - name: app
          image: student-app:ci-v1
          imagePullPolicy: IfNotPresent
          ports: [{name: http, containerPort: 8080}]
          envFrom:
            - configMapRef: {name: student-app-config}
            - secretRef: {name: student-app-secrets}
          env: [{name: DEPLOY_COLOR, value: blue}]
          startupProbe: {httpGet: {path: /up, port: http}, periodSeconds: 2, failureThreshold: 45}
          readinessProbe: {httpGet: {path: /ready, port: http}, periodSeconds: 5, failureThreshold: 2}
          lifecycle: {preStop: {sleep: {seconds: 10}}}
          resources: {requests: {cpu: 100m, memory: 256Mi}, limits: {cpu: "1", memory: 512Mi}}
          securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: ["ALL"]}}
EOF
sed 's/blue/green/g; s/ci-v1/ci-v2/' /tmp/bg-blue.yaml > /tmp/bg-green.yaml
```

الـ NetworkPolicy الموجودة بتختار `app.kubernetes.io/name=student-app` → بتغطي الـ pods دي (ingress 8080، egress للـ mysql). والـ PDB بيختار `component: web` → **مش** بيغطيهم (تمرين: اعمل PDB لـ `bg-plain`).

### 5.2 (B) Argo Rollouts من الـ chart

[`values-bluegreen.yaml`](../../../k8s/helm/student-app/values-bluegreen.yaml) بيتحط **فوق** أي env file: `rollout.enabled: true`، `strategy: blueGreen`، `autoPromotionEnabled: false`، `scaleDownDelaySeconds: 60`، `prePromotionAnalysis.enabled: true`، `postPromotionAnalysis.enabled: false`.

| الجزء | من فين | التفاصيل |
|---|---|---|
| `activeService` | [`rollout.yaml`](../../../k8s/helm/student-app/templates/rollout.yaml) | `student-app` (نفس الـ Service الأساسي: NodePort على kind، backend الـ Ingress على EKS) |
| `previewService` | [`service.yaml`](../../../k8s/helm/student-app/templates/service.yaml) | `student-app-preview` بيترسم لما `strategy=blueGreen` |
| Pre-promotion | [`analysistemplate.yaml`](../../../k8s/helm/student-app/templates/analysistemplate.yaml) `student-app-ready` | web provider على `http://<preview>.<ns>.svc.cluster.local:<service.port>/ready`، `jsonPath: "{$.status}"`، `count: 3`، `interval: 10s`، `failureLimit: 0`، `consecutiveErrorLimit: 2`، `successCondition: result == "ready"` |
| Post-promotion | `student-app-error-rate` | نفس الـ Prometheus query بتاع الـ canary على الـ hash الجديد ([68](68-k8s-canary-argo-rollouts.md)) — محتاج Prometheus و traffic |
| `progressDeadlineAbort: true` | `rollout.yaml` | green مبيوصلش Ready في 300s → abort أوتوماتيك |
| `deployColor` | `--set deployColor=green` | بيظهر في `/ready` و `student_app_app_info{color}` — وتغييره = pod template جديد |

**حدود الـ web gate (مهم):** هو بيثبت إن الـ preview **reachable عن طريق الـ Service** ومتصل بالـ DB. مش بيثبت إنه **بيخدم صح**: release بـ `SRE_FAULT_ERROR_RATE=0.5` بيعدّيه (`/ready` سليم). اللي بيمسك ده: اختبار الـ preview (smoke/E2E) قبل الـ promote، أو `postPromotionAnalysis` على الـ error rate ([`analysis-web.yaml`](../../../k8s/rollouts/analysis-web.yaml) نفسه مكتوب فيه كده).

### 5.3 النسخة الـ standalone

[`k8s/rollouts/bluegreen.yaml`](../../../k8s/rollouts/bluegreen.yaml): Services `student-app-bg-active` و `student-app-bg-preview` و Rollout `student-app-bg` بـ `prePromotionAnalysis` (`ready-check` من [`analysis-web.yaml`](../../../k8s/rollouts/analysis-web.yaml)) **و** `postPromotionAnalysis` (`error-rate` من [`analysis-prometheus.yaml`](../../../k8s/rollouts/analysis-prometheus.yaml))، و `scaleDownDelaySeconds: 120`. محتاج الـ plain manifests (ConfigMap/Secret/SA). على kind: الـ `prometheus-address` الافتراضي في `analysis-prometheus.yaml` مكتوب لـ kube-prometheus-stack — بدّله لـ Prometheus بتاعك وإلا الـ post-promotion هيعمل errors ويرجّع (fail closed).

## 6) الـ Deploy

### 6.1 (A) الـ switch اليدوي على kind

```bash
# الـ plain manifests (لو الـ chart متركّب: helm -n student-app uninstall student-app)
kubectl apply -k k8s/manifests/overlays/kind
kubectl -n student-app wait --for=condition=complete job/student-app-migrate --timeout=300s
kubectl -n student-app delete deploy,hpa student-app          # الـ Service هيشاور على blue/green بدله

kubectl apply -f /tmp/bg-blue.yaml -f /tmp/bg-green.yaml
kubectl -n student-app rollout status deploy/student-app-blue
kubectl -n student-app rollout status deploy/student-app-green

# المستخدمين → blue
kubectl -n student-app patch svc student-app --type merge \
  -p '{"spec":{"selector":{"app.kubernetes.io/component":"bg-plain","slot":"blue"}}}'
curl -s localhost:8088/ready; echo                            # version ci-v1، color blue

# اختبر green **بشكل خاص** قبل الـ switch
kubectl -n student-app port-forward deploy/student-app-green 8081:8080 &
curl -s localhost:8081/ready; echo; kill %1                   # version ci-v2، color green

# Terminal 1: bash deploy/scripts/probe.sh http://localhost:8088/ready 0 0.05
kubectl -n student-app patch svc student-app --type merge -p '{"spec":{"selector":{"slot":"green"}}}'
# rollback = نفس الأمر بـ blue — فوري لأن الـ blue لسه شغال
kubectl -n student-app patch svc student-app --type merge -p '{"spec":{"selector":{"slot":"blue"}}}'
```

> ⚠️ `kubectl port-forward svc/...` بيختار **pod واحد** وقت التشغيل ومش بيتبع تغيير الـ selector — متختبرش الـ switch بيه. اختبر عن طريق الـ NodePort (`localhost:8088`) أو من pod جوه الـ cluster.

### 6.2 (B) Argo Rollouts blueGreen على kind

```bash
# نظّف (A) وارجع للـ chart
kubectl -n student-app delete deploy student-app-blue student-app-green --ignore-not-found
kubectl -n student-app patch svc student-app --type json -p '[{"op":"remove","path":"/spec/selector/slot"}]'
kubectl delete -k k8s/manifests/overlays/kind --ignore-not-found   # بيمسح الـ namespace → أعد namespace + mysql + Secret من 60 §6.3

CHART=k8s/helm/student-app
# أول revision لـ Rollout = full scale، active مباشرة، من غير analysis
helm upgrade --install student-app $CHART -n student-app -f $CHART/values-kind.yaml -f $CHART/values-bluegreen.yaml \
  --set-string image.tag=ci-v1 --set deployColor=blue --timeout 5m
kubectl argo rollouts status student-app -n student-app --timeout 240s

# Terminal 1: probe على localhost:8088/ready (هيفضل يشوف blue لحد الـ promote)
helm upgrade student-app $CHART -n student-app -f $CHART/values-kind.yaml -f $CHART/values-bluegreen.yaml \
  --set-string image.tag=ci-v2 --set deployColor=green --timeout 5m
kubectl argo rollouts get rollout student-app -n student-app --watch     # preview → AnalysisRun → Paused
```

```bash
kubectl -n student-app get analysisrun
kubectl -n student-app port-forward svc/student-app-preview 8081:80 &    # اختبر green: /ready، /login
curl -s localhost:8081/ready; echo; kill %1
kubectl argo rollouts promote student-app -n student-app                  # الـ switch
# الـ probe: "answered by" فيه ci-v1 (blue) و ci-v2 (green)، و failed : 0
kubectl -n student-app get svc student-app -o jsonpath='{.spec.selector}{"\n"}'   # فيه rollouts-pod-template-hash
```

بعد 60s (`scaleDownDelaySeconds`) الـ blue RS بيبقى 0. جرّب `k6 run -e BASE_URL=http://localhost:8088 -e DURATION=3m -e EXPECT_VERSIONS=ci-v1,ci-v2 loadtest/k6/canary-watch.js` أثناء الـ promote: الـ summary فيه `release_responses{color:blue}` و `{color:green}` و `http_req_failed` ~0.

### 6.3 على EKS

```bash
helm upgrade --install student-app k8s/helm/student-app -n student-app \
  -f k8s/helm/student-app/values-eks.yaml -f k8s/helm/student-app/values-bluegreen.yaml \
  --set-string image.repository=<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/student-app \
  --set-string image.tag=<GIT_SHA> --set deployColor=green --timeout 10m
```

مع `blueGreen` الـ chart بيلغي الـ ALB canary routing لوحده (الـ Ingress backend = `student-app` port `http`)، والـ ALB بيتبع الـ active Service: الـ LBC بيعمل register للـ green pod IPs و deregister للـ blue بعد الـ switch. الـ `scaleDownDelaySeconds` لازم يبقى أطول من الـ deregistration (30s) + انتشار الـ targets. Argo Rollouts عنده feature للتحقق من الـ target group قبل الـ scale down (flag الـ controller `--aws-verify-target-group`، محتاج IAM `elasticloadbalancing:Describe*`) — **مش متفعّلة في المعمل**؛ راجع docs Argo Rollouts لو هتستخدمها.

## 7) التحقق (Verify)

```bash
kubectl argo rollouts get rollout student-app -n student-app
kubectl -n student-app get rs -L rollouts-pod-template-hash,app.kubernetes.io/version
kubectl -n student-app get svc student-app student-app-preview -o custom-columns=NAME:.metadata.name,SELECTOR:.spec.selector
kubectl -n student-app get analysisrun -o wide
kubectl -n student-app describe analysisrun "$(kubectl -n student-app get analysisrun -o name | tail -1 | cut -d/ -f2)" | tail -20
curl -s localhost:8088/ready; echo                                         # color = اللي اتعمله promote
```

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر | المتوقع |
|---|---|---|
| Green مبيقومش | `helm upgrade ... --set-string image.tag=ci-v2 --set faults.bootFail=true` | الـ preview `CrashLoopBackOff`، مفيش analysis، وبعد 300s **aborted** (`progressDeadlineAbort`)؛ الـ active (blue) سليم طول الوقت |
| Green بيرجع errors | `--set-string extraEnv.SRE_FAULT_ERROR_RATE=0.5` | الـ pre-promotion analysis **بيعدّي** (`/ready` سليم)! افتح `/login` على الـ preview → 500 نص المرات → `kubectl argo rollouts abort student-app -n student-app` — ده حدود الـ web gate |
| Promote من غير ما تختبر | promote الحالة اللي فوق | 50% errors لكل المستخدمين → `kubectl argo rollouts undo student-app -n student-app` جوه الـ 60s |
| Post-promotion gate | فعّل `--set rollout.blueGreen.postPromotionAnalysis.enabled=true` مع Prometheus ([68 §3](68-k8s-canary-argo-rollouts.md)) و traffic على `/login`، وكرر الـ bad release | بعد الـ promote الـ analysis بيفشل → الـ active بيرجع للـ blue (لسه موجود) |
| scaleDownDelay صغير | `--set rollout.blueGreen.scaleDownDelaySeconds=0` | الـ blue بيتشال فوراً: مفيش rollback فوري، وعلى EKS ممكن errors لو الـ ALB لسه بيبعت للـ blue |
| (A) cleanup غلط | `kubectl apply -k` من غير ما تشيل `slot` من الـ selector | الـ selector = `component: web` + `slot: blue` → **مفيش pods** → outage. الـ 3-way merge مبيشيلش field مكانش في الـ last-applied |

## 9) الرجوع (Rollback)

```bash
kubectl argo rollouts abort student-app -n student-app       # قبل الـ promote: ارمي الـ preview، الـ active زي ما هو
kubectl argo rollouts undo student-app -n student-app        # بعد الـ promote: ارجع للـ revision اللي قبلها
kubectl argo rollouts promote student-app -n student-app --full   # لو وقف على pause تاني بعد الـ undo
helm -n student-app rollback student-app                     # يرجّع الـ spec نفسه (Degraded بعد abort → Healthy)
```

- بعد **abort** الـ Rollout بيبقى `Degraded` لأن الـ spec (الإصدار السيء) لسه مختلف عن الـ stable. بيتصلّح لما الـ spec يرجع للـ stable: `helm rollback` (أو `git revert` في GitOps — [69](69-gitops-argocd.md)).
- الـ **undo** بيغيّر الـ spec (drift مع Helm/Git) — في GitOps الأحسن revert.
- مع `autoPromotionEnabled: false` الـ undo ممكن يمشي في نفس الـ flow (preview + analysis + pause) — راجع `get rollout` واعمل `promote` لو محتاج. لو الـ blue RS لسه جوه الـ `scaleDownDelaySeconds` الـ pods جاهزة فالرجوع سريع.

## 10) المسح (Teardown) ⚠️

```bash
helm -n student-app uninstall student-app
kubectl -n student-app delete analysisrun --all
kubectl delete -f https://github.com/argoproj/argo-rollouts/releases/download/v1.10.2/install.yaml -n argo-rollouts   # لو مش محتاجه في 68
rm -f /tmp/bg-blue.yaml /tmp/bg-green.yaml
```

## 11) التكلفة (Cost)

| Resource | السعر التقريبي |
|---|---|
| kind | مجاني |
| EKS | الـ cluster ([62 §11](62-eks-terraform.md)) + **capacity ×2 وقت الـ release** (لو الـ nodes مش مستحملة: node زيادة أو Karpenter — [6A](6A-hpa-karpenter-under-load.md)) |
| `previewReplicaCount` | يقلل التكلفة: preview بعدد أقل، ويكبر قبل الـ switch |

## 12) أسئلة Interview

<details><summary>الـ Service selector switch ذري — يبقى zero-downtime مضمون؟</summary>

الـ update في الـ API ذري، بس التنفيذ موزّع: كل kube-proxy بيحدّث iptables/IPVS في وقته، والـ ALB بيعمل register/deregister وhealth checks، والـ connections المفتوحة (keep-alive، HTTP/2) بتفضل على الـ pods القديمة. عشان كده: الـ blue يفضل شغال (`scaleDownDelaySeconds`) أطول من الـ propagation + الـ deregistration delay، والـ preStop/graceful shutdown بيكمّلوا الـ requests الأخيرة. والـ green لازم يكون Ready **قبل** الـ switch (warm caches).

</details>

<details><summary>Pre-promotion مقابل post-promotion analysis — تحط إيه في كل واحد؟</summary>

Pre: حاجات تتقاس من غير traffic مستخدمين — smoke/E2E على الـ preview Service، health، contract tests، synthetic load. فشله = مفيش switch أصلاً. Post: حاجات محتاجة traffic حقيقي — error rate و latency للـ active الجديد مقارنة بالـ SLO. فشله = رجوع للـ blue (لازم يكون لسه موجود). الـ web check عندنا pre-gate رخيص بس ضعيف؛ الـ gate الحقيقي error-rate post-promotion أو canary.

</details>

<details><summary>Blue/green والـ database migrations؟</summary>

الداتابيز مشتركة غالباً، فالـ blue والـ green لازم يشتغلوا على نفس الـ schema وقت الـ switch والـ rollback window. يعني expand/contract: الـ migration الـ additive قبل الـ release (Job/hook)، والـ contract (حذف columns) بعد ما الـ rollback window يقفل بـ release تاني ([95](95-zero-downtime-db-migrations.md)). Blue/green "بيئتين كاملتين" بالداتابيز = نادر ومكلف (replication ومزامنة الكتابة).

</details>

<details><summary>إمتى blue/green أحسن من canary؟</summary>

لما محتاج اختبار كامل للإصدار الجديد على infrastructure حقيقية قبل أي مستخدم (compliance، تغيير كبير في dependencies)، أو لما الإصدارين **مينفعش** يخدموا traffic مع بعض (protocol/session format مختلف)، أو rollback لحظي أهم من تقليل الـ blast radius. Canary أحسن لما المشاكل بتظهر تحت traffic حقيقي بس وعايز تقلل عدد المتأثرين، ومش عايز تدفع ×2 capacity.

</details>

<details><summary>إزاي تعمل blue/green ورا ALB على EKS؟ وإيه الطرق؟</summary>

(1) Argo Rollouts blueGreen: switch الـ Service selector، والـ LBC بيحدّث نفس الـ target group (ip mode) — مع readiness gates و target group verification. (2) اتنين target groups + ALB listener rule weights 100/0 → 0/100 (زي [45](45-bluegreen-two-asgs.md)) — Argo canary بـ ALB routing بـ `setWeight: 100` قريب منها. (3) اتنين Ingresses/ALBs + DNS switch (Route 53 weighted) — أبطأ بسبب الـ DNS TTL. (1) و (2) أسرع وأدق.

</details>

<details><summary>إيه دور `scaleDownDelaySeconds` بالظبط؟</summary>

حاجتين: rollback فوري (الـ blue pods لسه Ready، الـ undo/abort بيرجّع الـ selector من غير ما تستنى pods تقوم)، وأمان الـ propagation (kube-proxy على كل الـ nodes والـ ALB يكونوا بطّلوا يبعتوا للـ blue قبل ما يتقفل). أقل من الـ propagation = errors بعد الـ switch؛ أكبر بكتير = تكلفة capacity مضاعفة أطول.

</details>

## 13) Checklist

- [ ] عملت blue/green يدوي بـ selector switch واختبرت green بـ port-forward على الـ Deployment قبل الـ switch
- [ ] فهمت ليه `port-forward svc` مينفعش لاختبار الـ switch، وفخ الـ 3-way merge في الـ cleanup
- [ ] عملت blueGreen بـ Argo Rollouts: preview → AnalysisRun → promote بـ 0 failures
- [ ] جرّبت green بـ boot failure (abort تلقائي) و green بـ error rate (الـ web gate عدّاه)
- [ ] عملت abort و undo و `helm rollback` وفهمت حالة `Degraded`
- [ ] أقدر أقارن blue/green بـ rolling و canary (capacity، blast radius، rollback)
