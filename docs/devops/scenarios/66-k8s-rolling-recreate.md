# 66 — RollingUpdate و Recreate (probes، preStop، PDB)

> **الهدف في سطر:** تقيس بنفسك الفرق بين **RollingUpdate** (`maxSurge`/`maxUnavailable`) و **Recreate** بـ `probe.sh`، وتفهم بالأرقام دورة حياة الـ pod وهو بيقفل (endpoints → preStop → `SIGQUIT` → grace → SIGKILL)، وضبط الـ probes، و **PDB** أثناء `kubectl drain`، وإيه اللي بيحصل لما release مبيوصلش Ready (`progressDeadlineSeconds`).
> **المستوى:** Intermediate · **الوقت:** ~3 ساعات · **التكلفة التقريبية:** مجاني على kind (أو نفس [62](62-eks-terraform.md) على EKS)
> **بيعتمد على:** [60 — kind](60-kubernetes-on-kind.md) · [65 — Helm chart](65-helm-chart.md) · [22 — Recreate وقياس الـ downtime](22-recreate-and-measuring-downtime.md) · [25 — Rolling على سيرفر واحد](25-rolling-single-host.md) · **الملفات في الـ repo:** [`k8s/manifests/base/deployment.yaml`](../../../k8s/manifests/base/deployment.yaml) · [`k8s/manifests/base/pdb.yaml`](../../../k8s/manifests/base/pdb.yaml) · [`templates/_helpers.tpl`](../../../k8s/helm/student-app/templates/_helpers.tpl) (`podTemplate`) · [`templates/deployment.yaml`](../../../k8s/helm/student-app/templates/deployment.yaml) · [`templates/pdb.yaml`](../../../k8s/helm/student-app/templates/pdb.yaml) · [`values.yaml`](../../../k8s/helm/student-app/values.yaml) · [`deploy/scripts/probe.sh`](../../../deploy/scripts/probe.sh) · [`.github/workflows/k8s-integration.yml`](../../../.github/workflows/k8s-integration.yml) (step "Zero-downtime RollingUpdate")

## 1) الفكرة (Concepts)

| المصطلح | المعنى |
|---|---|
| `RollingUpdate` | ReplicaSet جديد يكبر والقديم يصغر بالتدريج، محكوم بـ `maxSurge` و `maxUnavailable` |
| `maxSurge` | كام pod **زيادة** عن الـ desired مسموح أثناء الـ rollout (النسبة بتتقرّب **لفوق**) |
| `maxUnavailable` | كام pod **أقل** من الـ desired مسموح (النسبة بتتقرّب **لتحت**) |
| `Recreate` | امسح كل القديم → استنى يختفوا → اعمل الجديد. **downtime مضمون** |
| `progressDeadlineSeconds` | لو الـ rollout مبيتقدمش في المدة دي → condition `Progressing=False` (`ProgressDeadlineExceeded`) — **من غير rollback تلقائي** في الـ Deployment |
| PDB | حد للـ **voluntary disruptions** (drain، upgrade، Karpenter consolidation) عن طريق الـ Eviction API — مش بيحمي من node بتقع |
| `unhealthyPodEvictionPolicy: AlwaysAllow` | pod مش Ready أصلاً (crash loop) مينفعش يوقف drain للأبد |

**الأرقام مع 2 replicas (الـ default عندنا):**

| `maxSurge` / `maxUnavailable` | أقصى pods | أقل pods Ready | ملاحظة |
|---|---|---|---|
| **1 / 0** (عندنا) | 3 | 2 | الـ capacity عمرها ما تقل؛ محتاج مكان لـ pod زيادة |
| 0 / 1 | 2 | 1 | من غير موارد زيادة، بس نص الـ capacity لفترة |
| 25% / 25% (default الـ Kubernetes) | 3 | 2 | مع 2 replicas: surge = ceil(0.5) = 1، unavailable = floor(0.5) = 0 → نفس 1/0 |
| 100% / 0 | 4 | 2 | "blue/green جوه Deployment": ReplicaSet كامل جديد قبل ما القديم يتشال — بس مفيش switch ذري ولا preview ([67](67-k8s-bluegreen.md)) |

**دورة حياة الـ pod وهو بيقفل** (القيم من الـ chart):

```text
 t=0   الـ pod اتعلّم Terminating ─┬─► endpoint controller يشيل الـ IP من الـ EndpointSlice
                                   │      └─► kube-proxy (ثواني) / ALB deregistration (أطول) ← async!
                                   └─► kubelet يشغّل preStop: sleep 10s   ← لسه بيخدم الـ requests اللي جاية
 t=10  الـ runtime يبعت STOPSIGNAL = SIGQUIT (من الـ Dockerfile) → PHP-FPM يخلّص الـ requests الحالية (≤ 30s)
 t≤40  terminationGracePeriodSeconds = 40 → لو لسه عايش: SIGKILL (الـ requests اللي في إيده بتقع)
```

**Recreate إمتى؟** لما الإصدارين **مينفعش** يشتغلوا مع بعض: volume `ReadWriteOnce` واحد، singleton (cron/leader من غير lock)، migration مش backward compatible ومش قادر تعمل expand/contract، أو license لـ instance واحد. غير كده RollingUpdate.

## 2) المعمارية (Architecture)

```text
 RollingUpdate (maxSurge 1, maxUnavailable 0), replicas 2:

 الوقت ─────────────────────────────────────────────────────────────────►
 RS v1:  ●● ──────────────────────── ●  ─────────────────────── (0)
 RS v2:      ○ (starting… startup /up) ● Ready (/ready + gate)    ○ … ● Ready
 Service endpoints:  v1 v1 │ v1 v1 v2 │ v1 v2 │ v1(terminating: preStop) v2 v2 │ v2 v2
 probe.sh (/ready كل 50ms):        ✓✓✓✓✓✓✓✓✓✓✓✓✓✓✓✓✓✓✓✓✓✓✓✓✓✓✓✓✓✓  failed: 0

 Recreate:
 RS v1:  ●● → terminating (preStop 10s + SIGQUIT) → (0)
 RS v2:                                              ○○ (startup) → ●●
 probe.sh:  ✓✓✓✓✓✓✓✓ ✗✗✗✗✗✗✗✗✗✗✗✗✗✗✗✗✗✗✗✗✗✗✗✗ ✓✓✓✓   ← failure window ≈ shutdown + boot

 kubectl drain worker (PDB maxUnavailable 1):
   evict pod A ✔ (allowed disruptions 1→0) … pod A' Ready on worker2 … evict pod B ✔
   أي eviction تاني قبل ما A' يبقى Ready → 429 "would violate the pod's disruption budget" → retry
```

## 3) المتطلبات (Prerequisites)

- [ ] kind بـ **3 nodes** ([60](60-kubernetes-on-kind.md) — الـ single-node variant مينفعش للـ drain) والـ images `ci-v1` و `ci-v2` محمّلين، و MySQL + الـ Secret.
- [ ] الـ chart متركّب بـ `values-kind.yaml` (أو التطبيق على EKS من [63](63-eks-load-balancer-controller-ingress.md) — الفروق أوضح هناك بسبب الـ ALB).
- [ ] 3 terminals: probe، أوامر، و `kubectl get pods -w`.

## 4) الطريقة الأولى: "Console"

مفيش موارد AWS جديدة. اللي يقابل الـ Console:

1. **GitHub → Actions → K8s integration** → step **Zero-downtime RollingUpdate ci-v1 → ci-v2** + جدول **RollingUpdate** في الـ Summary — نفس تجربة §6.1 أوتوماتيك.
2. على EKS: **EKS → cluster → Resources → Workloads → Deployments → student-app** → الـ ReplicaSets والـ events أثناء الـ rollout، و **EC2 → Target groups → Targets** (draining / initial / healthy) ([63](63-eks-load-balancer-controller-ingress.md)).

## 5) الطريقة التانية: as Code — الـ knobs

| Values key (الـ chart) | Default | في الـ manifest |
|---|---|---|
| `rollingUpdate.maxSurge` / `.maxUnavailable` | `1` / `0` | `spec.strategy.rollingUpdate` (الـ `type` ثابت `RollingUpdate` في [`deployment.yaml`](../../../k8s/helm/student-app/templates/deployment.yaml)) |
| `progressDeadlineSeconds` | `300` | `spec.progressDeadlineSeconds` |
| `probes.startup` | `/up`، period 2، timeout 2، failure 45 | لحد **90s** للـ boot |
| `probes.liveness` | `/up`، period 10، timeout 3، failure 3 | pod واقف يتعمله restart بعد ~30s |
| `probes.readiness` | `/ready`، period 5، timeout 3، failure 2 (success 1) | يخرج من الـ endpoints بعد ~10s، ويرجع بعد ~5s |
| `preStopSleepSeconds` | `10` | `lifecycle.preStop.sleep.seconds` (native، `kubeVersion: >=1.30`) |
| `terminationGracePeriodSeconds` | `40` | ≥ preStop + graceful PHP-FPM |
| `pdb.enabled` / `pdb.maxUnavailable` | `true` / `1` | `PodDisruptionBudget` بـ `unhealthyPodEvictionPolicy: AlwaysAllow` |
| `topologySpread.enabled` / `.whenUnsatisfiable` | `true` / `ScheduleAnyway` | zone + hostname، `matchLabelKeys` = hash الـ revision |

**ليه `maxUnavailable` في الـ PDB مش `minAvailable`؟** `minAvailable: 2` مع HPA scale لـ 6 = يسمح بـ 4 evictions مرة واحدة؛ ومع replicas = 2 بيمنع أي drain خالص. `maxUnavailable: 1` بيفضل منطقي في أي عدد.

**Recreate مش في الـ chart** (عن قصد — الـ chart للـ production). هنجرّبه على الـ plain manifests.

## 6) الـ Deploy — التجارب

> في كل تجربة: Terminal 1 = probe، Terminal 2 = الأوامر، Terminal 3 = `kubectl -n student-app get pods -L app.kubernetes.io/version -w`.

### 6.1 RollingUpdate الأساسي (الـ baseline)

```bash
# Terminal 1
bash deploy/scripts/probe.sh http://localhost:8088/ready 0 0.05
# Terminal 2
helm upgrade student-app k8s/helm/student-app -n student-app \
  -f k8s/helm/student-app/values-kind.yaml --set-string image.tag=ci-v2 --wait --timeout 6m
kubectl -n student-app rollout status deploy/student-app
# استنى لحد ما pods الـ ci-v1 تختفي خالص (preStop + shutdown) وبعدين Ctrl+C في Terminal 1
```

المتوقع: `failed : 0` و `answered by` فيه `ci-v1` و `ci-v2`. ده بالظبط step 9 في الـ CI.

### 6.2 `maxUnavailable: 1` / `maxSurge: 0`

```bash
helm upgrade student-app k8s/helm/student-app -n student-app -f k8s/helm/student-app/values-kind.yaml \
  --set-string image.tag=ci-v1 --set rollingUpdate.maxSurge=0 --set rollingUpdate.maxUnavailable=1 --wait
```

Terminal 3: هتشوف pod واحد بس Ready لفترة. الـ probe غالباً 0 failures (الـ pod الفاضل بيخدم)، بس **الـ capacity نص** — تحت load ده latency و errors. شغّل `k6 run -e BASE_URL=http://localhost:8088 -e DURATION=2m loadtest/k6/canary-watch.js` بدل الـ probe وقارن الـ latency بين 6.1 و 6.2.

### 6.3 preStop قصير

```bash
helm upgrade student-app k8s/helm/student-app -n student-app -f k8s/helm/student-app/values-kind.yaml \
  --set-string image.tag=ci-v2 --set preStopSleepSeconds=1 --wait
```

على kind الـ kube-proxy بيحدّث بسرعة فممكن تشوف failures قليلة أو مفيش؛ على **EKS ورا ALB** (deregistration أبطأ بكتير) هتشوف 502 متفرقة بوضوح ([63 §8](63-eks-load-balancer-controller-ingress.md)). الدرس: الـ preStop مش "احتياط" — ده بيغطي الـ propagation delay.

### 6.4 Recreate (plain manifests)

الـ plain والـ chart بيستخدموا نفس الأسماء، فشيل الـ release الأول:

```bash
helm -n student-app uninstall student-app
kubectl apply -k k8s/manifests/overlays/kind
kubectl -n student-app wait --for=condition=complete job/student-app-migrate --timeout=300s
kubectl -n student-app rollout status deploy/student-app

kubectl -n student-app patch deployment student-app --type merge \
  -p '{"spec":{"strategy":{"type":"Recreate","rollingUpdate":null}}}'
# Terminal 1: probe.sh على localhost:8088/ready
kubectl -n student-app set image deployment/student-app app=student-app:ci-v2
kubectl -n student-app rollout status deploy/student-app
```

المتوقع: `failure window : HH:MM:SS → HH:MM:SS` قد الـ shutdown (preStop 10s + SIGQUIT) + الـ boot (startup probe) — غالباً 15–40 ثانية، و `availability` أقل من 100%. قارنها بـ [22](22-recreate-and-measuring-downtime.md) (نفس الفكرة على EC2).

رجّع الـ strategy (عشان التجارب الجاية):

```bash
kubectl -n student-app patch deployment student-app --type merge \
  -p '{"spec":{"strategy":{"type":"RollingUpdate","rollingUpdate":{"maxSurge":1,"maxUnavailable":0}}}}'
```

### 6.5 Drain مع PDB

```bash
kubectl -n student-app get pods -o wide                     # مين على worker ومين على worker2؟ وفين mysql-0؟
kubectl -n student-app get pdb                              # ALLOWED DISRUPTIONS = 1
# Terminal 1: probe على /ready
kubectl drain student-app-lab-worker2 --ignore-daemonsets --delete-emptydir-data --timeout=180s
kubectl uncordon student-app-lab-worker2
```

> ⚠️ **اعمل drain للـ worker اللي مفيهوش `mysql-0`.** الـ lab MySQL replica واحدة من غير PDB، والـ PV بتاعه `local-path` **مربوط بالـ node** — لو اتعمله evict مش هيقدر يقوم على node تانية (هيفضل `Pending` لحد الـ uncordon) والتطبيق كله يبقى unready. ده درس حقيقي: الـ stateful على node storage = الـ drain بقى outage (عشان كده RDS على EKS).

**التجربة اللي PDB بيبان فيها:** cordon الـ worker التاني، وبعدين drain الأول — أول pod يتعمله evict، وبديله `Pending` (مفيش node: الاتنين cordoned، والـ control-plane عليه taint)، فالـ eviction التاني مرفوض والـ drain يفضل يعيد المحاولة:

```bash
kubectl cordon student-app-lab-worker            # (لو mysql-0 هنا، اعكس الـ nodes)
kubectl drain student-app-lab-worker2 --ignore-daemonsets --delete-emptydir-data --timeout=60s
# "Cannot evict pod as it would violate the pod's disruption budget" → timeout — الـ PDB حمى آخر pod
kubectl uncordon student-app-lab-worker student-app-lab-worker2
```

### 6.6 Release مبيوصلش Ready

```bash
helm upgrade student-app k8s/helm/student-app -n student-app -f k8s/helm/student-app/values-kind.yaml \
  --set-string image.tag=ci-v2 --set faults.unhealthy=true --timeout 7m --wait || echo "helm failed"
kubectl -n student-app get deploy student-app -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}{"\n"}{end}'
```

المتوقع: الـ pod الجديد `/up` = 500 → الـ startup probe بيفشل بعد 90s → restarts؛ `/ready` = 503 → مش Ready أبداً. القديم (2 pods) شغال طول الوقت (`maxUnavailable: 0`) والـ probe = 0 failures. بعد 300s: `Progressing=False ProgressDeadlineExceeded`. **الـ Deployment مبيرجعش لوحده** — ده دور `helm --rollback-on-failure` ([65](65-helm-chart.md)) أو Argo Rollouts `progressDeadlineAbort` ([68](68-k8s-canary-argo-rollouts.md)). رجّع: `helm -n student-app rollback student-app --wait`.

### 6.7 Drain يدوي لـ pod واحد (readiness من غير restart)

```bash
POD=$(kubectl -n student-app get pod -l app.kubernetes.io/component=web -o name | head -1)
kubectl -n student-app port-forward "$POD" 9090:8080 &
curl -s -X POST localhost:9090/sre-lab/unready; echo        # على kind مفيش SRE_LAB_TOKEN؛ على EKS ضيف -H "X-Lab-Token: <TOKEN>"
kubectl -n student-app get pods                              # الـ pod ده 0/1 — مفيش RESTARTS
kubectl -n student-app get endpointslices -o wide            # خرج من الـ endpoints
curl -s -X POST localhost:9090/sre-lab/ready; echo; kill %1
```

## 7) التحقق (Verify)

```bash
kubectl -n student-app rollout history deploy/student-app
kubectl -n student-app get rs -L app.kubernetes.io/version          # الـ ReplicaSets القديمة (revisionHistoryLimit 5) بـ 0 replicas
kubectl -n student-app describe deploy student-app | sed -n '/StrategyType/,/Events/p'
kubectl -n student-app get pdb student-app -o wide
kubectl -n student-app get events --sort-by=.lastTimestamp | tail -20
kubectl -n student-app get pods -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName,VER:.metadata.labels.app\\.kubernetes\\.io/version,READY:.status.containerStatuses[0].ready
```

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر | المتوقع |
|---|---|---|
| Grace أقل من preStop | `--set terminationGracePeriodSeconds=5` (preStop 10) | الـ kubelet بيعمل SIGKILL قبل ما الـ preStop يخلص → requests تقع (والـ events فيها FailedPreStopHook/Killing) |
| Liveness صارم جداً | `--set probes.liveness.timeoutSeconds=1 --set probes.liveness.failureThreshold=1` + `k6` على `/sre-lab/cpu?ms=1500` | restarts تحت الـ load (الـ liveness بيعدّي الـ timeout لما الـ FPM workers مشغولين) — liveness ضيق = restart storm |
| من غير startup probe (فكرة) | تخيّل liveness بـ initialDelay قليل وبوت 60s | الـ pod بيتقتل قبل ما يقوم → CrashLoop؛ عشان كده startup منفصل |
| PDB مستحيل | `kubectl -n student-app patch pdb student-app --type merge -p '{"spec":{"maxUnavailable":0}}'` + drain | الـ drain عمره ما يخلص — PDB غلط بيوقف upgrades الـ cluster كله. رجّعه `1` |
| Boot failure | `--set faults.bootFail=true` | `CrashLoopBackOff`، القديم شغال، `ProgressDeadlineExceeded` |
| Recreate تحت load | 6.4 مع `canary-watch.js` | errors لكل الـ users طول الـ window |

## 9) الرجوع (Rollback)

```bash
kubectl -n student-app rollout undo deploy/student-app                     # الـ revision اللي قبلها
kubectl -n student-app rollout undo deploy/student-app --to-revision=<N>
kubectl -n student-app rollout pause deploy/student-app                    # وقّف rollout في النص (تحقيق)
kubectl -n student-app rollout resume deploy/student-app
helm -n student-app rollback student-app --wait                            # لو بـ Helm (متخلطش الاتنين)
```

> ⚠️ `kubectl rollout undo` على release بتاع Helm = drift: Helm مش عارف، والـ upgrade الجاي هيكتب فوقه. مع Helm استخدم `helm rollback`؛ مع GitOps استخدم `git revert` ([69](69-gitops-argocd.md)).

## 10) المسح (Teardown) ⚠️

```bash
kubectl uncordon student-app-lab-worker student-app-lab-worker2
kubectl -n student-app patch pdb student-app --type merge -p '{"spec":{"maxUnavailable":1}}' 2>/dev/null
kubectl delete -k k8s/manifests/overlays/kind --ignore-not-found     # لو لسه على الـ plain (بيمسح الـ namespace)
kind delete cluster --name student-app-lab                           # لو خلصت
```

## 11) التكلفة (Cost)

| Resource | السعر التقريبي |
|---|---|
| kind | مجاني |
| EKS (لو جرّبت هناك) | نفس [62 §11](62-eks-terraform.md) + ALB |

## 12) أسئلة Interview

<details><summary>اشرح اللي بيحصل من لحظة `kubectl delete pod` لحد ما الـ process تموت.</summary>

الـ API بيحط `deletionTimestamp` → (1) الـ endpoint controller بيشيل الـ pod من الـ EndpointSlices، والـ consumers (kube-proxy، الـ LBC → ALB) بيتحدّثوا async؛ (2) بالتوازي الـ kubelet بيشغّل الـ preStop hook، وبعده بيبعت الـ STOPSIGNAL (هنا SIGQUIT)، والـ countdown بتاع `terminationGracePeriodSeconds` شغال من البداية (شامل الـ preStop)؛ لو الـ process مماتتش → SIGKILL. المشكلة إن (1) و (2) مش متزامنين، فالـ preStop sleep بيدّي (1) وقت يخلص قبل ما التطبيق يبطّل يقبل connections.

</details>

<details><summary>maxSurge و maxUnavailable — اختار قيم لـ 3 سيناريوهات.</summary>

API stateless بـ capacity كفاية في الـ cluster: `maxSurge 25%+ / maxUnavailable 0` (مفيش dip). Cluster مليان ومفيش مكان لـ pods زيادة: `maxSurge 0 / maxUnavailable 1` (dip صغير مقبول). Fleet كبير وعايز سرعة: `maxSurge 50% / maxUnavailable 0` على حساب موارد مؤقتة. وافتكر التقريب: surge لفوق، unavailable لتحت — مع replicas قليلة النِسب ممكن تطلع 0.

</details>

<details><summary>الـ Deployment وصل `ProgressDeadlineExceeded` — هل بيرجع لوحده؟</summary>

لأ. الـ Deployment بيعلّم الـ condition بس (والـ `kubectl rollout status` بيخرج بـ error). الـ rollback لازم حاجة برا: Helm `--rollback-on-failure`، pipeline بيعمل `rollout undo`، Argo Rollouts `progressDeadlineAbort: true`، أو Flagger. مع `maxUnavailable: 0` الإصدار القديم بيفضل شغال كامل فمفيش outage — بس فيه release معلّق لازم حد يقفله.

</details>

<details><summary>إيه أشهر أخطاء الـ PDB؟</summary>

`minAvailable` = عدد الـ replicas (أو PDB على deployment بـ replica واحدة) → الـ drain مستحيل، والـ node upgrades و Karpenter consolidation بيقفوا. PDB selector مش مطابق → ملوش أثر. نسيان إن PDB مش بيحمي من node crash ولا من `kubectl delete pod`. Crash-looping pods بتمنع drains (عشان كده `unhealthyPodEvictionPolicy: AlwaysAllow`). والـ PDB من غير topology spread ممكن يسيب كل الـ replicas على node واحدة.

</details>

<details><summary>Recreate إمتى يبقى الاختيار الصح؟</summary>

لما الإصدارين مينفعش يتعايشوا: RWO volume لـ pod واحد، singleton من غير leader election، schema change مش متوافقة ومفيش وقت لـ expand/contract، أو قيود license. وخليه مع maintenance window ورسالة للمستخدمين. ولو المشكلة الداتابيز بس، الحل الأصح غالباً expand/contract ([95](95-zero-downtime-db-migrations.md)) مش Recreate.

</details>

<details><summary>ليه الـ startup probe بدل `initialDelaySeconds` كبير على الـ liveness؟</summary>

`initialDelaySeconds` ثابت: لو كبير، pod واقف فعلاً في أول دقيقة مبيتكشفش؛ لو صغير، boot بطيء (cold cache، node مشغولة) بيتقتل. الـ startup probe بيدّي budget (هنا 45 × 2s = 90s) **لحد أول نجاح** بس، وبعده الـ liveness يبقى صارم. وكمان الـ readiness مبيبدأش يحسب لحد ما الـ startup ينجح.

</details>

## 13) Checklist

- [ ] قست RollingUpdate بـ 0 failures وفهمت ليه لازم تستنى الـ pods القديمة تختفي
- [ ] جرّبت `maxSurge 0 / maxUnavailable 1` وشفت الـ capacity dip
- [ ] قست downtime الـ Recreate (failure window) وقارنته بـ 22
- [ ] عملت drain بـ PDB وشفت الـ eviction المرفوض — وعرفت ليه mysql-0 على local-path مشكلة
- [ ] شفت `ProgressDeadlineExceeded` مع `faults.unhealthy` وإن الـ Deployment مبيرجعش لوحده
- [ ] عملت drain يدوي لـ pod بـ `/sre-lab/unready`
- [ ] أقدر أشرح تسلسل الـ termination بالأرقام (10 / 30 / 40)
