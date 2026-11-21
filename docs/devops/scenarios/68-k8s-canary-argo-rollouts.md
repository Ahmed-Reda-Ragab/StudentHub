# 68 — Canary بـ Argo Rollouts + analysis (auto-abort)

> **الهدف في سطر:** تشغّل canary بـ **Argo Rollouts** — على kind بالـ replicas (50%) وعلى EKS بـ **ALB weights** حقيقية 10→25→50→100% — مع **background analysis** بيحكم على الـ 5xx ratio بتاع الـ pods الجديدة بس من **Prometheus** (أو **CloudWatch** أو web check)، وتشوف **bad release** (`SRE_FAULT_ERROR_RATE=0.5`) بيتعمله **abort أوتوماتيك** والـ stable مقعش ولا request، وتفهم ليه الـ gate **fail closed**.
> **المستوى:** Advanced · **الوقت:** ~4 ساعات · **التكلفة التقريبية:** مجاني على kind؛ على EKS الـ cluster + ALB + Prometheus (node زيادة غالباً)
> **بيعتمد على:** [67 — Blue/Green](67-k8s-bluegreen.md) (Argo Rollouts متركّب) · [24 — Canary على سيرفر واحد](24-canary-single-host.md) (نفس الفكرة بـ nginx) · [63](63-eks-load-balancer-controller-ingress.md) · [71 — Metrics](71-metrics-dashboards.md) · [73 — SLO](73-slo-error-budget-burn-rate.md) · **الملفات في الـ repo:** [`templates/rollout.yaml`](../../../k8s/helm/student-app/templates/rollout.yaml) · [`templates/analysistemplate.yaml`](../../../k8s/helm/student-app/templates/analysistemplate.yaml) · [`templates/_helpers.tpl`](../../../k8s/helm/student-app/templates/_helpers.tpl) (`releaseEnv`) · [`values-kind.yaml`](../../../k8s/helm/student-app/values-kind.yaml) · [`values-eks.yaml`](../../../k8s/helm/student-app/values-eks.yaml) · [`k8s/rollouts/canary.yaml`](../../../k8s/rollouts/canary.yaml) · [`analysis-prometheus.yaml`](../../../k8s/rollouts/analysis-prometheus.yaml) · [`analysis-cloudwatch.yaml`](../../../k8s/rollouts/analysis-cloudwatch.yaml) · [`analysis-web.yaml`](../../../k8s/rollouts/analysis-web.yaml) · [`observability/k8s/kube-prometheus-stack-values.yaml`](../../../observability/k8s/kube-prometheus-stack-values.yaml) · [`.github/workflows/k8s-integration.yml`](../../../.github/workflows/k8s-integration.yml) · [`.github/workflows/deploy-eks.yml`](../../../.github/workflows/deploy-eks.yml) · [`loadtest/k6/canary-watch.js`](../../../loadtest/k6/canary-watch.js)

## 1) الفكرة (Concepts)

في [24](24-canary-single-host.md) عملنا canary بـ nginx weights و gate بـ awk على `/metrics`. Argo Rollouts بيعمل نفس الفكرة كـ **controller**: الـ `Rollout` بديل للـ Deployment (نفس الـ pod template) بـ steps، وبيشغّل `AnalysisRun` من `AnalysisTemplate`، ولو الـ analysis فشل بيعمل **abort**: الـ traffic يرجع 100% stable والـ canary يتشال — من غير إنسان.

| المصطلح | المعنى |
|---|---|
| `setWeight` / `pause` | نسبة الـ canary / soak time (`pause: {}` من غير مدة = استنى `promote` يدوي) |
| من غير traffic routing | الـ weight = نسبة الـ replicas (1 من 2 = 50%) — تقريبي |
| `trafficRouting.alb` | Argo بيكتب forward action بـ weights في الـ Ingress → ALB بيقسّم بالظبط (10% = 10% حتى بـ 2 pods) |
| Background analysis | `strategy.canary.analysis` بـ `startingStep`: شغال من الخطوة دي لحد الـ promotion؛ أي verdict فاشل = abort |
| Measurement | Successful / Failed (الشرط اتكسر) / **Error** (الـ query فشلت أو رجعت فاضي) / Inconclusive |
| `failureLimit` | الـ analysis يفشل بعد `failureLimit + 1` measurement فاشلة |
| `consecutiveErrorLimit` | errors ورا بعض مسموحة؛ بعدها الـ analysis = Error → abort (**fail closed**) |
| `podTemplateHashValue: Latest` | Argo بيبعت hash الـ ReplicaSet الجديد كـ arg → الـ query بتختار pods الـ canary بالاسم |
| Abort → `Degraded` | الـ traffic على الـ stable، بس الـ spec لسه الإصدار السيء → بيتصلّح بـ `helm rollback` / `git revert` |
| `abortScaleDownDelaySeconds` | مع traffic routing: سيب الـ canary pods شوية بعد الـ abort للتحقيق (30s) |
| `progressDeadlineAbort: true` | canary مبيوصلش Ready في 300s → abort (Deployment عادي مبيعملش كده — [66](66-k8s-rolling-recreate.md)) |

**ليه الـ gate 5% والـ SLO 0.5%؟** canary بدقايق وشوية requests مينفعش يقيس 0.5% إحصائياً (rule of three — [24 §12](24-canary-single-host.md)). الـ gate بيمسك الإصدار "البايظ بوضوح"؛ الـ SLO نفسه بتحرسه الـ burn-rate alerts ([73](73-slo-error-budget-burn-rate.md)).

**ليه الـ faults في الـ pod template؟** ([`_helpers.tpl`](../../../k8s/helm/student-app/templates/_helpers.tpl) `releaseEnv`) — لو `SRE_FAULT_ERROR_RATE` كان في الـ ConfigMap المشترك، أي pod stable يعمل restart أو scale up **أثناء الـ abort نفسه** كان هياخد الـ fault. في الـ pod template كل ReplicaSet شايل نسخته، وتغييره = revision جديدة = canary جديد.

## 2) المعمارية (Architecture)

```text
 kind (CI و محلي) — من غير traffic router                EKS — ALB traffic routing
 ───────────────────────────────────────                ─────────────────────────────────────────────
 Service student-app (NodePort) → كل الـ Ready pods      ALB listener rule "/" ← action annotation (Argo بيكتبها)
   stable RS ●  (1)     canary RS ○ (1)  ⇒ ~50%            forward: TG(student-app)=90  TG(student-app-canary)=10
 steps: setWeight 50 → pause 2m                         Services: student-app (stable hash) · student-app-canary (canary hash)
                                                        steps: 10 → pause 2m → 25 → pause 2m → 50 → pause 3m → 100

 Prometheus ──scrape /metrics (port http)──► كل الـ pods (stable + canary)
   kind: prometheus chart، annotation discovery (prometheus.io/*)، كل 10s
   EKS : kube-prometheus-stack، PodMonitor "student-app" (observability/k8s/...-values.yaml)، كل 15s
        ▲
 AnalysisRun (student-app-error-rate) كل interval:
   5xx ÷ total  على  pod=~".+-<canary-hash>-.+"  و route!~"sre-lab\..*|health\.ready|up|metrics"
   ✔ ≤ maxErrorRate (أو NaN = مفيش traffic)   ✖ > maxErrorRate   ⚠ نتيجة فاضية = Error
        │ failureLimit+1 ✖  أو  consecutiveErrorLimit+1 ⚠
        ▼
 ABORT: weight → 0 (stable 100%) → canary scaled down → Rollout phase=Degraded, status.abort=true
        → helm rollback / git revert → spec == stable → Healthy (من غير steps)
```

## 3) المتطلبات (Prerequisites)

- [ ] Argo Rollouts + الـ plugin ([67 §3](67-k8s-bluegreen.md)).
- [ ] **Prometheus بيعمل scrape للـ pods** — من غيره الـ analysis بيعمل abort لكل canary (عن قصد):
  - **kind** (زي الـ CI بالظبط):

```bash
helm upgrade --install prometheus prometheus --repo https://prometheus-community.github.io/helm-charts \
  --version 29.48.0 -n monitoring --create-namespace \
  --set alertmanager.enabled=false --set prometheus-pushgateway.enabled=false \
  --set prometheus-node-exporter.enabled=false --set kube-state-metrics.enabled=false \
  --set server.persistentVolume.enabled=false --set server.retention=2h \
  --set server.global.scrape_interval=10s --set server.global.evaluation_interval=30s \
  --wait --timeout 5m
```

  - **EKS:** `addons.kube_prometheus_stack = true` في الستاك ([62](62-eks-terraform.md) — بيحمّل `kube-prometheus-stack-values.yaml` بالـ PodMonitor)، أو Argo CD app ([69](69-gitops-argocd.md)). ومعاه `serviceMonitor.enabled: false` في `values-eks.yaml` (الاتنين = double counting).
- [ ] traffic على صفحات حقيقية (`/login`) أثناء الـ canary — من غيره الـ NaN بيعدّي (§8).
- [ ] (EKS) LBC + الـ Ingress ([63](63-eks-load-balancer-controller-ingress.md)).

## 4) الطريقة الأولى: "Console" — Dashboards و AWS Console

1. **Argo Rollouts dashboard** (`kubectl argo rollouts dashboard` → `localhost:3100`): الخطوة الحالية، الـ weight، الـ AnalysisRuns وكل measurement.
2. **Prometheus UI**: kind `kubectl -n monitoring port-forward svc/prometheus-server 9090:80`؛ EKS `kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090` → جرّب الـ query (§5.2) بالـ hash بتاعك.
3. **EC2 → Load Balancers → `student-app-lab-eks` → Listeners → View/edit rules**: الـ rule الـ default **forward** لـ target group-ين بـ weights بتتغير مع كل `setWeight`.
4. **CloudWatch → Metrics → ApplicationELB → Per AppELB, per TG Metrics** → `HTTPCode_Target_5XX_Count` و `RequestCount` للـ canary TG (ده اللي [`analysis-cloudwatch.yaml`](../../../k8s/rollouts/analysis-cloudwatch.yaml) بيقراه).

## 5) الطريقة التانية: as Code

### 5.1 الـ Rollout من الـ chart

[`rollout.yaml`](../../../k8s/helm/student-app/templates/rollout.yaml) لما `strategy: canary`: `maxSurge: 1`/`maxUnavailable: 0`، و **لو** `trafficRouting.alb.enabled` (ومعاه `ingress.enabled` و `className: alb` وإلا الـ render بيفشل): `stableService: student-app`، `canaryService: student-app-canary`، `trafficRouting.alb.ingress: student-app`، `servicePort: 80`، `abortScaleDownDelaySeconds: 30`. والـ background analysis: template `student-app-error-rate` بـ args `namespace` و `canary-hash` (`podTemplateHashValue: Latest`). والـ HPA بيستهدف الـ Rollout نفسه ([6A](6A-hpa-karpenter-under-load.md)).

| | [`values-kind.yaml`](../../../k8s/helm/student-app/values-kind.yaml) | [`values-eks.yaml`](../../../k8s/helm/student-app/values-eks.yaml) |
|---|---|---|
| `rollout.enabled` | `false` (الـ CI بيقلبها بـ `--set`) | `true` |
| Steps | `setWeight: 50` → `pause: 2m` | 10 → 2m → 25 → 2m → 50 → 3m → (100) |
| Traffic routing | replicas (1 من 2) | ALB weights |
| `analysis.prometheus.address` | `http://prometheus-server.monitoring.svc.cluster.local` | `http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090` |
| `interval` / `rateWindow` / `failureLimit` | `15s` / `1m` / `1` | `1m` / `2m` / `2` |
| `maxErrorRate` | `0.05` (من `values.yaml`) | `0.05` |
| متوسط وقت الـ abort لـ 50% errors | ~45s من أول 2 scrapes للـ pod الجديد | ~3 دقايق (3 measurements فاشلة) |

### 5.2 الـ AnalysisTemplate — الـ query سطر بسطر

```promql
(
  sum(rate(student_app_http_requests_total{namespace="<ns>", pod=~".+-<canary-hash>-.+", status=~"5..",
           route!~"sre-lab\\..*|health\\.ready|up|metrics"}[<rateWindow>]))
  or
  0 * sum(rate(student_app_http_requests_total{namespace="<ns>", pod=~".+-<canary-hash>-.+",
           route!~"sre-lab\\..*|health\\.ready|up|metrics"}[<rateWindow>]))
)
/
sum(rate(student_app_http_requests_total{namespace="<ns>", pod=~".+-<canary-hash>-.+",
         route!~"sre-lab\\..*|health\\.ready|up|metrics"}[<rateWindow>]))
```

- **`pod=~".+-<hash>-.+"`**: pods الـ Rollout اسمها `<rollout>-<pod-template-hash>-<suffix>`، والـ `pod` label موجود في أي scrape setup (annotation job، PodMonitor، ServiceMonitor) → مفيش relabeling محتاج. الـ **canary بس** بيتقاس، مش الـ stable.
- **`route!~...`**: نفس تعريف الـ availability SLI ([CONVENTIONS §5](../CONVENTIONS.md)): الـ probes و `/metrics` و `/sre-lab/*` مستبعدين. والـ fault بيضرب صفحات الـ web بس (`InjectFaults` على الـ web group)، فالـ health checks بتعدّي — **الـ metric ده الوحيد اللي بيمسك الـ bad release**.
- **`errors or 0 * total`**: canary سليم لسه معندوش أي series بـ `status=5xx` → من غير الـ `or` الناتج فاضي. كده = 0. ولو **مفيش series خالص** (scraping بايظ، labels غلط) الناتج يفضل فاضي → **Error**.
- **`successCondition: "isNaN(result[0]) || result[0] <= 0.05"`**: NaN = 0/0 = series موجودة بس مفيش requests في الـ window → مفيش حاجة نحكم عليها → pass (gate في الـ production المفروض يشترط حد أدنى من الـ requests).
- **`consecutiveErrorLimit: 4`**: 5 errors ورا بعض → الـ analysis Error → abort. **Fail closed**: gate أعمى ميعملش promote.
- النسبة **immune للـ double scraping** (PodMonitor + ServiceMonitor بيضاعفوا البسط والمقام) — بس الـ SLO counters والـ dashboards لأ، عشان كده واحد بس.

### 5.3 الـ standalone examples

| الملف | فيه إيه | ملاحظات |
|---|---|---|
| [`canary.yaml`](../../../k8s/rollouts/canary.yaml) | Services `student-app-canary-stable`/`-canary` + Ingress `student-app-canary` (ALB منفصل `student-app-lab-canary`) + Rollout بـ 10/25/50/100 | محتاج الـ plain manifests + LBC؛ بيعمل **ALB تاني** (تكلفة) |
| [`analysis-prometheus.yaml`](../../../k8s/rollouts/analysis-prometheus.yaml) | `error-rate`: نفس الـ query بـ `[2m]`، `interval: 1m`، `failureLimit: 2`، arg `prometheus-address` | الـ default = kube-prometheus-stack |
| [`analysis-cloudwatch.yaml`](../../../k8s/rollouts/analysis-cloudwatch.yaml) | `alb-5xx-rate`: metric math `IF(requests > 0, errors / requests, 0)` على الـ **canary target group**، `initialDelay: 2m`، `interval: 2m`، lookback 5m، كل datapoint ≤ 5% | الـ ALB metrics 1-دقيقة بتوصل متأخرة 1–2 دقيقة: أبطأ وأخشن، بس بيقيس اللي المستخدم شافه فعلاً من الـ LB |
| [`analysis-web.yaml`](../../../k8s/rollouts/analysis-web.yaml) | `ready-check`: `/ready` = `ready` ×3 | أرخص gate؛ مش بيمسك error rate ([67](67-k8s-bluegreen.md)) |

**CloudWatch provider محتاج** (مش متعمل في الستاك — Terraform مبيعملش Pod Identity لـ Argo Rollouts، وكمان الـ `helm_release` بتاعه مفيهوش `AWS_REGION`؛ الـ Argo CD app [`apps/argo-rollouts.yaml`](../../../k8s/argocd/apps/argo-rollouts.yaml) فيه الـ env):

```bash
cat > /tmp/pod-identity-trust.json <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"pods.eks.amazonaws.com"},"Action":["sts:AssumeRole","sts:TagSession"]}]}
EOF
aws iam create-role --role-name student-app-lab-argo-rollouts --assume-role-policy-document file:///tmp/pod-identity-trust.json
aws iam put-role-policy --role-name student-app-lab-argo-rollouts --policy-name read-alb-metrics --policy-document \
  '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["cloudwatch:GetMetricData","elasticloadbalancing:DescribeTargetGroups","elasticloadbalancing:DescribeTargetHealth","elasticloadbalancing:DescribeLoadBalancers"],"Resource":"*"}]}'
aws eks create-pod-identity-association --cluster-name student-app-lab --namespace argo-rollouts \
  --service-account argo-rollouts --role-arn arn:aws:iam::<ACCOUNT_ID>:role/student-app-lab-argo-rollouts
# + AWS_REGION على الـ controller (في Terraform: ضيفه لـ values الـ helm_release؛ أو استخدم الـ Argo CD app)
kubectl -n argo-rollouts rollout restart deploy/argo-rollouts
```

وعشان تستخدمه: في نسخة من `canary.yaml` غيّر `templateName: error-rate` لـ `alb-5xx-rate` وابعت `args` `load-balancer` (`app/student-app-lab-canary/<id>`) و `target-group` (`targetgroup/<name>/<id>` بتاع الـ canary TG — الجزء بعد `:` في الـ ARN). الـ chart نفسه بيستخدم Prometheus بس.

### 5.4 `deploy-eks.yml` mode `rollouts`

| Step | الفرق عن mode `helm` |
|---|---|
| kubectl-argo-rollouts plugin | download + `sha256sum -c` (بس في الـ mode ده) |
| submit the canary release | `helm upgrade --install ... --set rollout.enabled=true --timeout 10m` **من غير `--wait` ولا `--rollback-on-failure`**: الـ canary بياخد دقايق والـ rollback شغلة Argo Rollouts (Helm لسه بيستنى الـ hooks — الـ migration Job) |
| follow the canary | `kubectl argo rollouts status --timeout 15m`: Healthy = promoted؛ غير كده `get rollout` + `get analysisrun` + `::error::` |
| Job summary | `get rollout` + أوامر watch/promote/abort/undo |

> ⚠️ التبديل بين `helm` و `rollouts` بيستبدل الـ Deployment بـ Rollout (أو العكس) → الـ pods بتتعمل recreate مرة. اختار mode واحد لكل environment (أو `workloadRef` للهجرة من غير downtime).

## 6) الـ Deploy

### 6.1 kind — نفس drills الـ CI يدوي

```bash
CHART=k8s/helm/student-app
# Deployment → Rollout (أول revision = full scale من غير steps)
helm upgrade --install student-app $CHART -n student-app -f $CHART/values-kind.yaml \
  --set-string image.tag=ci-v2 --set rollout.enabled=true --timeout 5m
kubectl argo rollouts status student-app -n student-app --timeout 240s

# Terminal 1 — traffic حقيقي للـ analysis:
STOP_FILE=/tmp/stop-traffic bash deploy/scripts/probe.sh http://localhost:8088/login 0 0.05 > /tmp/traffic.log 2>&1 &
# Terminal 2 — الـ availability لازم تفضل 100%:
MAX_FAILURES=0 bash deploy/scripts/probe.sh http://localhost:8088/ready 0 0.1

# (أ) canary سليم → promoted
helm upgrade student-app $CHART -n student-app -f $CHART/values-kind.yaml \
  --set-string image.tag=ci-v1 --set rollout.enabled=true --timeout 5m
kubectl argo rollouts get rollout student-app -n student-app --watch          # Ctrl+C لما يبقى Healthy

# (ب) bad canary → abort أوتوماتيك
helm upgrade student-app $CHART -n student-app -f $CHART/values-kind.yaml \
  --set-string image.tag=ci-v2 --set rollout.enabled=true --set-string extraEnv.SRE_FAULT_ERROR_RATE=0.5 --timeout 5m
kubectl argo rollouts status student-app -n student-app --timeout 300s || echo "aborted (expected)"
kubectl -n student-app get rollout student-app -o jsonpath='{.status.phase} abort={.status.abort}{"\n"}'   # Degraded abort=true
kubectl -n student-app get analysisrun

# (ج) "git revert" = spec يرجع للـ stable → Healthy من غير steps
helm -n student-app rollback student-app --timeout 5m
kubectl argo rollouts status student-app -n student-app --timeout 180s
touch /tmp/stop-traffic
```

المتوقع: probe الـ `/ready` = `failed : 0` طول الـ 3 مراحل؛ الـ `/login` traffic فيه failures **في فترة الـ bad canary بس** (نصيب الـ canary × 50%) — ده الـ blast radius.

### 6.2 EKS — ALB weights

```bash
gh workflow run deploy-eks.yml --ref master -f image_tag=<GIT_SHA> -f mode=rollouts
# أو من جهازك:
helm upgrade --install student-app k8s/helm/student-app -n student-app -f k8s/helm/student-app/values-eks.yaml \
  --set-string image.repository=<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/student-app \
  --set-string image.tag=<GIT_SHA> --set rollout.enabled=true --timeout 10m
```

```bash
ALB=$(kubectl -n student-app get ingress student-app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
bash deploy/scripts/probe.sh "http://$ALB/login" 0 0.05 > /tmp/traffic.log 2>&1 &         # traffic للـ analysis
k6 run -e BASE_URL="http://$ALB" -e DURATION=10m -e EXPECT_VERSIONS=<OLD_SHA>,<NEW_SHA> \
  -e CANARY_VERSION=<NEW_SHA> loadtest/k6/canary-watch.js                                 # الـ split الفعلي
kubectl -n student-app get ingress student-app -o jsonpath='{.metadata.annotations}' | tr ',' '\n' | grep actions
kubectl argo rollouts get rollout student-app -n student-app --watch
```

عشان تتحقق من weight خطوة معينة: شغّل `canary-watch.js` بـ `-e EXPECT_CANARY_PCT=10 -e TOLERANCE_PCT=5 -e DURATION=90s` وهي على خطوة الـ 10% — الـ threshold بيفشل لو الـ ALB مش بيطبق الـ weight.

**Bad release على EKS:** نفس الأمر + `--set-string extraEnv.SRE_FAULT_ERROR_RATE=0.5` (من جهازك — الـ workflow مفيهوش input للـ faults). المتوقع بعد ~3 measurements فاشلة (interval 1m، failureLimit 2): الـ weight يرجع 0، الـ canary pods تفضل 30s (`abortScaleDownDelaySeconds`) وبعدين تتشال، و `deploy-eks.yml` (لو منه) بيخلص بـ error.

## 7) التحقق (Verify)

```bash
kubectl argo rollouts get rollout student-app -n student-app
kubectl -n student-app get analysisrun -o wide
AR=$(kubectl -n student-app get analysisrun -o name | tail -1)
kubectl -n student-app get "$AR" -o jsonpath='{range .status.metricResults[*]}{.name}: phase={.phase} ok={.successful} fail={.failed} err={.error}{"\n"}{range .measurements[*]}  {.phase} {.value}{"\n"}{end}{end}'
kubectl -n student-app get rs -L rollouts-pod-template-hash,app.kubernetes.io/version
kubectl -n argo-rollouts logs deploy/argo-rollouts --tail=50 | grep -i -E "abort|analysis|weight"
```

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر | المتوقع |
|---|---|---|
| مفيش traffic | canary سيء من غير الـ probe على `/login` | **promoted!** الـ NaN بيعدّي — gate حقيقي لازم حد أدنى requests (أو synthetic traffic) |
| Scraping بايظ | kind: `--set metrics.podAnnotations=false` (من غير annotations الـ prometheus chart مش بيشوف الـ pods) + canary **سليم** | measurements = Error ×5 → **abort** لإصدار سليم: fail closed |
| `METRICS_TOKEN` | على EKS حط `/student-app/lab/app/METRICS_TOKEN` في SSM ([64](64-eks-external-secrets.md)) | الـ PodMonitor بياخد 403 → مفيش series جديدة → كل canary يتعمله abort. الحل: auth في الـ scrape أو امسح الـ token |
| Latency بس | `--set-string extraEnv.SRE_FAULT_LATENCY_MS=800` | **promoted** — الـ gate على 5xx بس. تمرين: metric تاني على الـ latency SLO (تحت) |
| Unhealthy | `--set faults.unhealthy=true` | الـ canary مش Ready → مفيش traffic عليه → بعد 300s abort (`progressDeadlineAbort`) |
| Kill switch يدوي | `kubectl argo rollouts abort student-app -n student-app` وهو على 25% | 100% stable فوراً |
| Skip | `kubectl argo rollouts promote student-app -n student-app --full` | يتخطى كل الـ steps والـ analysis — استخدمه في الطوارئ بس |
| Double scraping | EKS: `--set serviceMonitor.enabled=true` مع الـ PodMonitor | الـ canary gate كما هو (نسبة)، بس `student_app_http_requests_total` متضاعف في الـ SLO rules والـ dashboards |

**تمرين الـ latency gate** — metric تاني في نسخة من الـ AnalysisTemplate (نسبة الـ requests الأسرع من 300ms، SLO 95%):

```yaml
    - name: latency-good
      interval: 1m
      failureLimit: 2
      successCondition: "isNaN(result[0]) || result[0] >= 0.95"
      provider:
        prometheus:
          address: http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090
          query: |
            sum(rate(student_app_http_request_duration_seconds_bucket{namespace="{{args.namespace}}", pod=~".+-{{args.canary-hash}}-.+", le="0.3", route!~"sre-lab\\..*|health\\.ready|up|metrics"}[2m]))
            /
            sum(rate(student_app_http_request_duration_seconds_bucket{namespace="{{args.namespace}}", pod=~".+-{{args.canary-hash}}-.+", le="+Inf", route!~"sre-lab\\..*|health\\.ready|up|metrics"}[2m]))
```

## 9) الرجوع (Rollback)

```bash
kubectl argo rollouts abort student-app -n student-app       # أثناء الـ canary: stable 100% دلوقتي
helm -n student-app rollback student-app                     # الـ spec يرجع للـ stable → Healthy من غير steps
kubectl argo rollouts undo student-app -n student-app        # بعد الـ promote: canary جديد بالإصدار القديم (بالـ steps!)
```

- **بعد promote** الـ "undo" = rollout جديد للإصدار القديم **بنفس الـ steps والـ analysis** (دقايق). لو مستعجل: `undo` + `promote --full`.
- في GitOps: `git revert` للـ bump commit ([69](69-gitops-argocd.md)) — ده بالظبط اللي step (ج) في الـ CI بيحاكيه بـ `helm rollback`.
- الـ migrations اتعملت قبل الـ canary ومش بترجع؛ والإصدارين بيخدموا مع بعض دقايق → expand/contract إجباري ([95](95-zero-downtime-db-migrations.md)).

## 10) المسح (Teardown) ⚠️

```bash
kubectl -n student-app delete analysisrun --all
helm -n monitoring uninstall prometheus                         # kind
kubectl delete -f k8s/rollouts/canary.yaml --ignore-not-found   # لو جرّبت الـ standalone (بيمسح الـ ALB التاني)
aws eks delete-pod-identity-association --cluster-name student-app-lab --association-id <ID>   # لو عملت CloudWatch IAM
aws iam delete-role-policy --role-name student-app-lab-argo-rollouts --policy-name read-alb-metrics
aws iam delete-role --role-name student-app-lab-argo-rollouts
```

## 11) التكلفة (Cost)

| Resource | السعر التقريبي (تقريبي — راجع صفحة الأسعار) |
|---|---|
| kind + Prometheus | مجاني |
| kube-prometheus-stack على EKS | requests ~0.5–1 vCPU / ~1–1.5 GiB → غالباً node تالتة (~$0.04/ساعة t3.medium) |
| ALB weighted routing | مفيش زيادة (نفس الـ ALB، target group تاني) |
| `canary.yaml` standalone | **ALB تاني** (~$0.0225/ساعة + LCU) |
| CloudWatch `GetMetricData` | سنتات (بالـ metrics المطلوبة) |

## 12) أسئلة Interview

<details><summary>صمّم canary analysis لخدمة production.</summary>

Metrics: error rate (5xx على user routes) و latency (نسبة تحت الـ SLO threshold أو p99) — للـ canary **مقارنة بـ baseline** (مش threshold مطلق)، وحد أدنى للـ requests لكل measurement، و saturation (restarts، OOM). Steps بـ traffic routing حقيقي (1→5→25→50%) و soak time كفاية عشان الـ cold caches والـ cron/jobs. Fail closed لما الـ metrics مش موجودة. وabort أوتوماتيك + إشعار + الـ canary pods تفضل شوية للتحقيق. والـ SLO نفسه تحرسه burn-rate alerts منفصلة.

</details>

<details><summary>Canary بالـ replicas مقابل traffic routing؟</summary>

بالـ replicas: الـ Service بيوزّع على كل الـ Ready pods، فالـ weight = نسبة الـ pods (مع 2 replicas أقل خطوة 50%!) ومش دقيق مع keep-alive. Traffic routing (ALB/NGINX/Istio/Gateway API): الـ weight بيتطبق على الـ requests مستقل عن عدد الـ pods → 1% ممكن، والـ canary ممكن يبقى pod واحد (`setCanaryScale`). التكلفة: Ingress controller يدعمها + Services اتنين.

</details>

<details><summary>Fail open ولا fail closed للـ analysis؟</summary>

Fail closed (الـ default عندنا): مفيش بيانات = abort. أأمن: gate أعمى مينفعش يعمل promote، والـ rollback رخيص (الـ stable لسه شغال). العيب: Prometheus واقع = مفيش deploys — وده غالباً مقبول (متعملش deploy وإنت أعمى). Fail open مناسب لما الـ gate إضافي مش أساسي. المهم إن الفرق بين "0 errors" و "مفيش series" يكون صريح في الـ query (`errors or 0 * total`).

</details>

<details><summary>ليه بنقيس الـ canary pods بس مش الـ service كله؟</summary>

لأن الـ canary بياخد 10% — لو بيرجع 50% errors، الـ service كله بيبان 5% بس (ومع noise الـ stable ممكن يتخبى). القياس على الـ hash الجديد بيدّي الإشارة كاملة. والأحسن كمان مقارنة بـ baseline بنفس العمر (Argo Experiments / Kayenta) عشان مشكلة عامة (DB بطيئة) متتحسبش على الـ canary.

</details>

<details><summary>إيه اللي بيحصل بالظبط في الـ abort؟ وليه الـ Rollout يبقى Degraded؟</summary>

الـ controller بيرجّع الـ weight لـ 0 (ALB annotation أو scale الـ stable للـ full)، وبعد `abortScaleDownDelaySeconds` بيعمل scale down للـ canary RS، ويحط `status.abort=true` و phase `Degraded`. الـ spec (الـ desired state) لسه الإصدار السيء — Argo مبيكتبش على الـ spec بتاعك. عشان كده لازم الـ source of truth يرجع (helm rollback / git revert)؛ أول ما الـ spec == stable الـ Rollout يبقى Healthy من غير steps.

</details>

<details><summary>Argo Rollouts مقابل Flagger مقابل CodeDeploy/ECS؟</summary>

Argo Rollouts: CRD بديل للـ Deployment، steps صريحة، analysis providers كتير، dashboard، يتكامل مع Argo CD. Flagger: بيلف Deployment عادي (بيعمل نسخة primary)، أوتوماتيك أكتر، قوي مع service meshes. CodeDeploy (ECS/Lambda): canary/linear configs + CloudWatch alarms → rollback ([54](54-ecs-codedeploy-bluegreen-canary.md)). ECS native deployments كمان فيها canary/linear ([55](55-ecs-native-bluegreen-linear-canary.md)). المبدأ واحد: نسبة صغيرة → قياس → قرار أوتوماتيك.

</details>

<details><summary>الـ canary والـ HPA مع بعض؟</summary>

الـ HPA بيستهدف الـ Rollout (مش الـ ReplicaSets)، وArgo بيوزّع الـ replicas حسب الـ weight (مع traffic routing الـ canary بيتعمله scale بنسبة الـ weight من الـ total افتراضياً). خلي بالك: CPU الـ canary ممكن يختلف عن الـ stable (bug في الأداء) فالـ HPA يكبّر الكل؛ و scale down أثناء الـ canary ممكن يقلل عينة الـ analysis.

</details>

## 13) Checklist

- [ ] ركّبت Prometheus وفهمت ليه الـ analysis معتمد على الـ scraping (PodMonitor / annotations)
- [ ] قريت الـ query وفهمت `pod=~hash` و `or 0 * total` و الـ NaN
- [ ] على kind: canary سليم promoted، bad canary aborted (`Degraded`، `abort=true`)، `helm rollback` → Healthy، و `/ready` = 0 failures
- [ ] على EKS: شفت الـ ALB weights بتتغير والـ split في `canary-watch.js`
- [ ] جرّبت fail closed (scraping بايظ) و NaN (مفيش traffic) و latency fault
- [ ] فهمت متطلبات الـ CloudWatch provider (IAM + `AWS_REGION`)
- [ ] أقدر أشرح الفرق بين abort و undo و rollback
