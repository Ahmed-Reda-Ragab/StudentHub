# 6A — HPA + Karpenter تحت load

> **الهدف في سطر:** تخلي k6 ([`autoscale-cpu.js`](../../../loadtest/k6/autoscale-cpu.js)) يحرق CPU محسوب على `/sre-lab/cpu`، وتشوف الـ **HPA** (بـ metrics-server) بيكبّر الـ pods بالأرقام اللي حسبتها، ولما الـ nodes تخلص الـ pods تبقى **Pending** و **Karpenter** يجيب node جديدة (Spot/On-Demand) في أقل من دقيقة، وبعد الـ load الاتنين يصغّروا (stabilization + consolidation) من غير ما الـ PDB يتكسر.
> **المستوى:** Advanced · **الوقت:** ~3–4 ساعات · **التكلفة التقريبية:** الـ cluster ([62](62-eks-terraform.md)) + nodes Karpenter وقت التجربة (سنتات لكل ساعة node — تقريبي)
> **بيعتمد على:** [62 — EKS بـ Terraform](62-eks-terraform.md) · [63](63-eks-load-balancer-controller-ingress.md) (الـ ALB) · [66](66-k8s-rolling-recreate.md) (PDB) · [48 — Autoscaling على ASG](48-autoscaling-under-load.md) · [57 — ECS autoscaling](57-ecs-autoscaling-under-load.md) · [74 — k6](74-load-testing-k6.md) · **الملفات في الـ repo:** [`templates/hpa.yaml`](../../../k8s/helm/student-app/templates/hpa.yaml) · [`values.yaml`](../../../k8s/helm/student-app/values.yaml) (`autoscaling`، `resources`، `pdb`) · [`k8s/manifests/base/hpa.yaml`](../../../k8s/manifests/base/hpa.yaml) · [`infra/terraform/stacks/60-eks/addons.tf`](../../../infra/terraform/stacks/60-eks/addons.tf) (Karpenter) · [`main.tf`](../../../infra/terraform/stacks/60-eks/main.tf) (metrics-server، discovery tags) · [`outputs.tf`](../../../infra/terraform/stacks/60-eks/outputs.tf) (`karpenter`) · [`loadtest/k6/autoscale-cpu.js`](../../../loadtest/k6/autoscale-cpu.js) · [`loadtest/k6/README.md`](../../../loadtest/k6/README.md) · [`config/sre_lab.php`](../../../config/sre_lab.php) · [`k8s/kind/README.md`](../../../k8s/kind/README.md)

## 1) الفكرة (Concepts)

طبقتين autoscaling لازم يشتغلوا مع بعض:

1. **Pods (HPA):** metrics-server بيجمع CPU/memory من الـ kubelets، والـ HPA (كل ~15s) بيحسب: **`desired = ceil(current × currentUtilization / target)`**، والـ utilization **نسبة من الـ request** مش من الـ node.
2. **Nodes (Karpenter):** pod `Pending` بسبب `Insufficient cpu` → Karpenter بيقرا الـ requirements (من الـ NodePool) ويختار أرخص instance مناسب → `NodeClaim` → EC2 → الـ node بتعمل join (~1 دقيقة). ولما الـ load يقل: **consolidation** بيشيل/يستبدل nodes فاضية أو قليلة الاستخدام (بيحترم الـ PDB).

| المصطلح | المعنى |
|---|---|
| `averageUtilization: 70` | متوسط CPU الـ pods = 70% من `requests.cpu` (100m) = **70m** لكل pod |
| `behavior.scaleUp` | `stabilizationWindowSeconds: 0` + زوّد لحد **2 pods كل 30s** — الـ spikes بتوجع المستخدمين دلوقتي |
| `behavior.scaleDown` | استنى **300s** stabilization، وبعدين **pod واحد كل 60s** — من غير flapping |
| `replicas` في الـ manifest | الـ chart **بيشيله** لما `autoscaling.enabled` (وإلا كل `helm upgrade`/Argo sync يرجّع الـ HPA لـ 2) |
| NodePool | "إيه أنواع الـ nodes المسموحة" (capacity type، arch، families، limits، disruption) |
| EC2NodeClass | "إزاي تتعمل" (AMI alias، subnets/SGs بالـ discovery tag، الـ IAM role) |
| Consolidation | `WhenEmptyOrUnderutilized` + `consolidateAfter` |
| Interruption queue | SQS بيستقبل Spot interruption / rebalance / health events → Karpenter يعمل drain بدري |

**الحسبة** ([`autoscale-cpu.js`](../../../loadtest/k6/autoscale-cpu.js)): كل request بيحرق `CPU_MS` CPU خالص، فالطلب = **`RATE × CPU_MS / 1000` vCPU**، والـ pods المطلوبة = الطلب ÷ (request × target):

| السيناريو | الطلب | Pods (request 100m، target 70%) | النتيجة |
|---|---|---|---|
| `RATE=2 CPU_MS=100` (اللي الـ script بيرشّحه للمشاهدة) | 0.2 vCPU | 0.2 / 0.07 ≈ **3** | scale-up جزئي 2→3 من غير ما تلمس السقف |
| `RATE=2 CPU_MS=200` | 0.4 vCPU | 0.4 / 0.07 ≈ **6** | الـ HPA يوصل `maxReplicas: 6` |
| `RATE=10 CPU_MS=200` (default الـ script) | 2 vCPU | ≈ 29 → محدود بـ **6** | الـ HPA على الـ max والـ latency بتعلى — **الـ maxReplicas هو الـ bottleneck** |
| `RATE=15 CPU_MS=200` + request **500m** + `maxReplicas: 12` | 3 vCPU | 3 / 0.35 ≈ **9** → 9 × 500m = 4.5 vCPU requests | أكتر من الـ 2 × t3.medium → **Pending → Karpenter** |

> 💡 الـ header بتاع الـ script بيستخدم نفس أرقام الـ chart (request `100m`، target 70% → ~29 pod عند `RATE=10`، يعني مقفول على `maxReplicas: 6`). لو غيّرت الـ requests (زي تجربة Karpenter تحت) أعد الحسبة بالـ request الحقيقي: `kubectl -n student-app get deploy student-app -o jsonpath='{.spec.template.spec.containers[0].resources}'`.

## 2) المعمارية (Architecture)

```text
 k6 autoscale-cpu.js ──RATE req/s──► ALB ──► pods  GET /sre-lab/cpu?ms=200  (X-Lab-Token على EKS)
   └ whoami 1 req/s على /sre-lab/version → "instance serving traffic: <pod>" لكل pod جديد

 kubelet (cAdvisor) ─► metrics-server (EKS community add-on) ─► metrics.k8s.io
                                                                     │ كل ~15s
 HPA student-app (scaleTargetRef: Deployment أو Rollout) ◄───────────┘
   desired = ceil(n × util/70%) ، +2 pods/30s ، min 2 / max 6 (أو 12 في التجربة)
        │ pods جديدة
        ▼
 scheduler: مفيش مكان (Insufficient cpu) → Pending
        │
 Karpenter (kube-system، على MNG nodes بـ label karpenter.sh/controller=true، Pod Identity)
   NodePool "default" (spot + on-demand، t/c/m medium/large، limits cpu 8)
   EC2NodeClass "default" (al2023، subnets/SG بـ karpenter.sh/discovery=student-app-lab،
                           role student-app-lab-karpenter-node)
        │ CreateFleet → NodeClaim → EC2 → join → pods Running (~60–90s)
        ▼
 بعد الـ load: HPA scale-down (300s ثم 1/60s) → nodes فاضية → consolidation (consolidateAfter 1m، PDB maxUnavailable 1)
 SQS interruption queue ◄── EventBridge (Spot interruption 2-min warning، rebalance، instance state)
```

## 3) المتطلبات (Prerequisites)

**على kind (HPA بس، من غير Karpenter):**

- [ ] [60](60-kubernetes-on-kind.md) شغال + metrics-server (الأمر من [`k8s/kind/README.md`](../../../k8s/kind/README.md)):

```bash
helm upgrade --install metrics-server metrics-server --repo https://kubernetes-sigs.github.io/metrics-server/ \
  --version 3.14.0 -n kube-system --set 'args={--kubelet-insecure-tls}'
kubectl -n kube-system rollout status deploy/metrics-server && kubectl top nodes
```

**على EKS (HPA + Karpenter):**

- [ ] الستاك [62](62-eks-terraform.md) — `metrics-server` add-on موجود افتراضياً.
- [ ] في `terraform.tfvars`: `enable_karpenter = true` + `install_addons = true` → `plan`/`apply` (الـ module بيعمل الـ IAM والـ SQS والـ node role؛ والـ discovery tags على الـ node subnets والـ node SG؛ و label `karpenter.sh/controller=true` على الـ MNG — **الـ node group بيتعدّل**، اقرا الـ plan).
- [ ] الـ Spot service-linked role (لو عمرك ما استخدمت Spot في الحساب): `aws iam create-service-linked-role --aws-service-name spot.amazonaws.com` (لو موجود هيرجع error — عادي).
- [ ] التطبيق ورا الـ ALB ([63](63-eks-load-balancer-controller-ingress.md)) و k6 على جهازك ([`loadtest/k6/README.md`](../../../loadtest/k6/README.md)).
- [ ] الـ lab token (الستاك بيحط `SRE_LAB_TOKEN` في SSM، فالـ `/sre-lab/*` بيطلب `X-Lab-Token`):

```bash
LAB_TOKEN=$(aws ssm get-parameter --name /student-app/lab/app/SRE_LAB_TOKEN --with-decryption --query Parameter.Value --output text)
```

## 4) الطريقة الأولى: AWS Console

1. **EKS → cluster → Add-ons → Metrics Server** (community add-on): Active، والـ version.
2. **EC2 → Instances** → فلتر `tag:karpenter.sh/nodepool` → الـ nodes اللي Karpenter عملها (instance type، lifecycle spot/on-demand، AZ).
3. **SQS → Queues** → queue الـ interruption اللي الـ module عمله (`terraform output karpenter` → `interrupt_queue`)، و **EventBridge → Rules** اللي بتبعتله.
4. **CloudWatch → Metrics → ApplicationELB** → `RequestCount` و `TargetResponseTime` أثناء الـ test (الـ latency بتنزل لما الـ capacity تزيد).
5. **EC2 → Spot Requests / Savings summary**: الخصم الفعلي على الـ Spot nodes.

## 5) الطريقة التانية: as Code

### 5.1 الـ HPA في الـ chart

[`hpa.yaml`](../../../k8s/helm/student-app/templates/hpa.yaml): `autoscaling/v2`، `scaleTargetRef` = **Rollout** لو `rollout.enabled` وإلا Deployment (Argo بيحافظ على نسبة canary/stable)، `minReplicas`/`maxReplicas`، CPU `Utilization` = `targetCPUUtilizationPercentage`، و `behavior` من الـ values كما هو. `values-kind.yaml` بيقفله (مفيش metrics-server افتراضياً)؛ `values-eks.yaml` شغال 2→6.

الـ resources (`requests` 100m/256Mi، `limits` 1 CPU/512Mi): الـ CPU limit بيقفل request جامح (`/sre-lab/cpu`) على core واحدة؛ والـ memory limit = OOMKill لـ pod مش مشكلة node. لاحظ: pod ممكن يستخدم لحد 10× الـ request → utilization 1000% → الـ HPA بيقفز للـ max بسرعة.

### 5.2 Karpenter في Terraform

من [`addons.tf`](../../../infra/terraform/stacks/60-eks/addons.tf):

- `module "karpenter"` (`terraform-aws-modules/eks/aws//modules/karpenter` `~> 21.30`): `create_pod_identity_association = true` (الـ controller على `kube-system/karpenter`)، `node_iam_role_name = "student-app-lab-karpenter-node"` (من غير prefix عشان الـ EC2NodeClass يشاور عليه بالاسم)، + `AmazonSSMManagedInstanceCore`، و SQS للـ interruptions.
- `helm_release "karpenter"` (`oci://public.ecr.aws/karpenter`، 1.15.3، `wait = false`): `nodeSelector karpenter.sh/controller=true` (الـ controller **مش** على nodes هو بيديرها — وإلا ممكن يعمل consolidate للـ node اللي هو عليها)، `dnsPolicy: Default`، `settings.clusterName/clusterEndpoint/interruptionQueue`، `webhook.enabled = false`.
- من [`main.tf`](../../../infra/terraform/stacks/60-eks/main.tf): `karpenter.sh/discovery = student-app-lab` على الـ node subnets (الـ public لو `enable_nat = false`) والـ node security group.

### 5.3 الـ NodePool و الـ EC2NodeClass

> 📌 **الـ manifests دي هي المصدر الرسمي للـ NodePool و الـ EC2NodeClass في المعمل** — مش ملفات في `k8s/`؛ تعليقات `variables.tf` و `addons.tf` و README الستاك بتشاور على السيناريو ده. الـ API بتاع Karpenter v1، والقيم من `terraform output karpenter`:

```bash
terraform -chdir=infra/terraform/stacks/60-eks output -json karpenter     # node_role، discovery_tag، interrupt_queue
cat > /tmp/karpenter-default.yaml <<'EOF'
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: default
spec:
  role: student-app-lab-karpenter-node          # output karpenter.node_role
  amiSelectorTerms:
    - alias: al2023@latest                       # في الـ production ثبّت version بدل latest
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: student-app-lab  # output karpenter.discovery_tag
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: student-app-lab
  tags:
    Project: student-app
    Env: lab
    ManagedBy: karpenter
    Scenario: 6A
---
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: default
spec:
  template:
    metadata:
      labels:
        student-app/pool: karpenter
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot", "on-demand"]          # Spot الأول لو متاح وأرخص
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]                      # الـ image متبنية amd64 في الـ CI
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["t", "c", "m"]
        - key: karpenter.k8s.aws/instance-size
          operator: In
          values: ["medium", "large"]
      expireAfter: 720h
  limits:
    cpu: "8"                                     # سقف التكلفة: مجموع الـ vCPUs اللي Karpenter يقدر يعملها
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 1m
EOF
kubectl apply -f /tmp/karpenter-default.yaml
kubectl get ec2nodeclass,nodepool
```

`kubectl get ec2nodeclass default -o yaml` → الـ status لازم يبيّن الـ subnets والـ SGs والـ AMI اللي اتلقوا (لو فاضي: الـ discovery tags أو الـ role غلط).

## 6) الـ Deploy

### 6.1 HPA على kind

```bash
helm upgrade student-app k8s/helm/student-app -n student-app -f k8s/helm/student-app/values-kind.yaml \
  --set-string image.tag=ci-v1 --set autoscaling.enabled=true --wait
kubectl -n student-app get hpa -w                  # Terminal 2
k6 run -e BASE_URL=http://localhost:8088 -e RATE=2 -e CPU_MS=200 -e DURATION=8m loadtest/k6/autoscale-cpu.js
```

المتوقع: الـ TARGETS تطلع فوق 70% خلال دقيقة → 2 → 4 → 6 (خطوات 2 كل 30s)، و k6 بيطبع `instance serving traffic: student-app-…` لكل pod جديد. بعد ما الـ test يخلص: 5 دقايق ثابت، وبعدين pod كل دقيقة لحد 2.

**محاكاة اللي Karpenter بيحله (من غير Karpenter):**

```bash
# الـ request لازم ≤ الـ limit، فبنرفع الاتنين؛ و minReplicas عالي عشان الـ pods تتطلب فوراً
helm upgrade student-app k8s/helm/student-app -n student-app -f k8s/helm/student-app/values-kind.yaml \
  --set-string image.tag=ci-v1 --set autoscaling.enabled=true \
  --set resources.requests.cpu=2 --set resources.limits.cpu=2 \
  --set autoscaling.minReplicas=10 --set autoscaling.maxReplicas=12 --timeout 2m || true
kubectl -n student-app get pods --field-selector=status.phase=Pending
kubectl -n student-app describe pod <PENDING_POD> | grep -A3 Events       # 0/3 nodes are available: ... Insufficient cpu
helm -n student-app rollback student-app --wait                          # رجّع الـ requests الطبيعية
```

(الـ kind nodes بتشوف عدد cores الجهاز كله؛ لو مفيش Pending زوّد `minReplicas` أو الـ request.)

### 6.2 HPA + Karpenter على EKS

```bash
# التطبيق بحجم يخلي الـ nodes تخلص (Deployment عادي عشان التجربة تبقى بسيطة)
helm upgrade --install student-app k8s/helm/student-app -n student-app -f k8s/helm/student-app/values-eks.yaml \
  --set-string image.repository=<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/student-app --set-string image.tag=<GIT_SHA> \
  --set rollout.enabled=false --set resources.requests.cpu=500m --set autoscaling.maxReplicas=12 \
  --wait --timeout 10m
ALB=$(kubectl -n student-app get ingress student-app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
```

افتح 4 terminals:

```bash
kubectl -n student-app get hpa student-app -w
kubectl get nodeclaims -w
kubectl get nodes -L karpenter.sh/capacity-type,node.kubernetes.io/instance-type,topology.kubernetes.io/zone -w
kubectl -n kube-system logs -l app.kubernetes.io/name=karpenter -f --tail=20
```

والـ load:

```bash
k6 run -e BASE_URL="http://$ALB" -e LAB_TOKEN="$LAB_TOKEN" -e RATE=15 -e CPU_MS=200 -e DURATION=15m \
  loadtest/k6/autoscale-cpu.js
```

الـ timeline المتوقع: الـ HPA يكبّر (2/30s) → pods `Pending` → Karpenter يعمل `NodeClaim` خلال ثواني (الـ log فيه الـ instance type المختار) → node `Ready` في ~1 دقيقة → الـ pods `Running` → k6 بيشوف hostnames جديدة و الـ p95 بينزل. بعد الـ test: الـ HPA يصغّر بعد 300s، والـ nodes الفاضية تتشال بالـ consolidation (`consolidateAfter: 1m`).

> 💡 الـ test ده **مش الـ SLO**: الـ threshold `http_req_failed{scenario:cpu} < 5%` — السؤال "الـ capacity لحقت؟". افصل بين ده وبين `load.js` (الـ SLO thresholds — [74](74-load-testing-k6.md)). ولو عايز `load.js` على EKS محتاج users متسيّدة: `kubectl -n student-app exec deploy/student-app -- php artisan db:seed --class=LoadTestSeeder --force`.

## 7) التحقق (Verify)

```bash
kubectl -n student-app describe hpa student-app | sed -n '/Metrics/,/Events/p'      # current/target، conditions (AbleToScale، ScalingLimited)
kubectl -n student-app get hpa student-app -o jsonpath='{.status.currentReplicas}/{.status.desiredReplicas}{"\n"}'
kubectl top pods -n student-app
kubectl top nodes
kubectl get nodeclaims -o wide                                                      # TYPE، CAPACITY (spot/on-demand)، ZONE
kubectl describe nodepool default | sed -n '/Status/,$p'                            # الـ resources المستخدمة مقابل الـ limits
kubectl -n student-app get events --sort-by=.lastTimestamp | grep -i -E "scaled|FailedScheduling|Nominated" | tail
aws ec2 describe-instances --filters Name=tag:karpenter.sh/nodepool,Values=default Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].{id:InstanceId,type:InstanceType,life:InstanceLifecycle,az:Placement.AvailabilityZone}' --output table
```

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر | المتوقع |
|---|---|---|
| مفيش metrics-server | kind من غير §3، و `autoscaling.enabled=true` | `TARGETS <unknown>/70%`، و `FailedGetResourceMetric` في الـ events — الـ HPA مبيعملش حاجة |
| Request مش متحدد | `--set resources.requests=null` (تجربة) | الـ HPA مش قادر يحسب utilization (`missing request for cpu`) |
| الـ maxReplicas هو السقف | `RATE=10` بالـ defaults | `ScalingLimited` / الـ HPA على 6، الـ latency والـ errors بتعلى — الـ capacity planning مش بس autoscaling |
| NodePool limits | `kubectl patch nodepool default --type merge -p '{"spec":{"limits":{"cpu":"1"}}}'` | pods `Pending` و logs Karpenter: الـ NodePool وصل حده — الـ limit هو حماية التكلفة |
| Discovery tag غلط | غيّر الـ tag في الـ EC2NodeClass | الـ status من غير subnets → مفيش nodes |
| PDB بيمنع consolidation | `kubectl -n student-app patch pdb student-app --type merge -p '{"spec":{"maxUnavailable":0}}'` بعد الـ test | الـ nodes الفاضية جزئياً متتشالش (Karpenter بيحترم الـ PDB). رجّعه `1` |
| Flapping | `--set autoscaling.behavior.scaleDown.stabilizationWindowSeconds=0` + load متقطع | الـ replicas بتطلع وتنزل كل دقيقة — ليه الـ 300s |
| OOMKill | `for i in $(seq 1 6); do curl -s -H "X-Lab-Token: $LAB_TOKEN" "http://$ALB/sre-lab/memory?mb=128&hold_ms=5000" >/dev/null & done; wait` | غالباً pod بيتقتل `OOMKilled` (limit 512Mi) والـ ReplicaSet بيعيده؛ `kubectl describe pod` → Last State |
| Spot interruption | AWS FIS action `aws:ec2:send-spot-instance-interruptions` على node Spot ([75](75-chaos-engineering-fis.md)) | Karpenter بيستقبل الحدث من SQS → cordon + drain + node بديلة قبل الـ 2 دقيقة |

## 9) الرجوع (Rollback)

```bash
helm -n student-app rollback student-app --wait                 # يرجّع الـ requests/maxReplicas الأصلية
kubectl delete nodepool default                                 # Karpenter بيعمل drain ويمسح الـ nodes بتاعته
kubectl -n student-app patch pdb student-app --type merge -p '{"spec":{"maxUnavailable":1}}'
```

لو Karpenter عمل مشكلة (instance types غلط، تكلفة): ضيّق الـ `requirements` أو قلل الـ `limits` — الـ nodes الموجودة بتتستبدل بالـ drift/consolidation.

## 10) المسح (Teardown) ⚠️

**الـ nodes اللي Karpenter عملها مش في Terraform state** — امسحها قبل `terraform destroy`:

```bash
kubectl delete nodepool --all
kubectl get nodeclaims -w                                        # استنى لحد ما تبقى فاضية
kubectl delete ec2nodeclass --all
aws ec2 describe-instances --filters Name=tag:karpenter.sh/nodepool,Values=* Name=instance-state-name,Values=pending,running \
  --query 'Reservations[].Instances[].InstanceId'                # لازم فاضية
# بعدها: enable_karpenter = false (أو مباشرة) terraform destroy — 62 §10
```

ولو مش هتستخدم الـ HPA على kind: `helm -n kube-system uninstall metrics-server`.

## 11) التكلفة (Cost)

| Resource | السعر التقريبي (us-east-1 — تقريبي، راجع صفحة الأسعار) |
|---|---|
| Karpenter / metrics-server / HPA | مجاني (pods) |
| Node إضافية t3.medium On-Demand | ~$0.0416/ساعة (Spot غالباً أقل بكتير) |
| `t3.large` لو Karpenter اختاره | ~$0.083/ساعة |
| SQS + EventBridge (interruptions) | سنتات |
| ALB LCU وقت الـ load | بيزيد مع الـ requests (سنتات لتجربة 15 دقيقة) |
| سقف التكلفة | `NodePool.spec.limits.cpu = 8` + Budget alert ([97](97-cost-and-teardown.md)) |

## 12) أسئلة Interview

<details><summary>اشرح خوارزمية الـ HPA وليه الـ requests مهمة.</summary>

`desired = ceil(currentReplicas × currentMetric / targetMetric)` مع tolerance (~10%) عشان التغييرات الصغيرة متعملش scale، وبعدين الـ behavior policies والـ stabilization. الـ utilization = usage ÷ request، فلو الـ request صغير جداً (100m) أي load بسيط = 300%، ولو كبير جداً الـ HPA مش هيتحرك لحد ما الـ node تتخنق. الـ requests كمان هي اللي الـ scheduler و Karpenter بيحسبوا بيها الـ capacity — يعني requests غلط = autoscaling غلط على المستويين.

</details>

<details><summary>Karpenter مقابل Cluster Autoscaler مقابل EKS Auto Mode؟</summary>

Cluster Autoscaler: بيكبّر/يصغّر ASGs (node groups) موجودة بـ instance types ثابتة، أبطأ، وكل node group لازم تتعرّف مسبقاً. Karpenter: بيتعامل مع EC2 Fleet مباشرة، بيختار instance type لكل batch من الـ pending pods (bin-packing)، Spot diversification، consolidation و drift. Auto Mode: Karpenter مُدار من AWS (من غير ما تركّبه أو تعمل upgrade) بـ fee لكل instance ([61 §5.3](61-eks-console-eksctl.md)).

</details>

<details><summary>الـ scale-up بياخد قد إيه من أول الـ spike؟ وإزاي تقلله؟</summary>

metrics-server resolution (~15s) + HPA sync (~15s) + الـ scheduling + **node provisioning (~45–90s)** + image pull + startup probe (لحد ما `/ready` ينجح) + ALB target health (2 × 10s). يعني دقيقتين-تلاتة في الأسوأ. التقليل: headroom (pause pods بـ PriorityClass واطية بتتطرد لما pods حقيقية تحتاج المكان)، images أصغر/pre-pulled، startup أسرع، scale-up policy أعدى، أو scaling على metric بيسبق (RPS/queue length بـ KEDA) بدل CPU.

</details>

<details><summary>CPU limits — تحطها ولا لأ؟</summary>

الـ limit بيعمل CFS throttling: pod بيستخدم أكتر من حصته بيتبطّأ حتى لو الـ node فاضية → latency. ناس كتير بتشيل CPU limits وتسيب requests صح (الـ memory limit لازم يفضل). عندنا limit = 1 core كحماية من `/sre-lab/cpu` (request واحد ميقدرش ياكل node) — trade-off مقصود في lab فيه endpoints بتحرق CPU عن قصد.

</details>

<details><summary>إزاي Karpenter بيتعامل مع Spot interruptions؟ وإيه اللي لازم في التطبيق؟</summary>

الـ EventBridge rules بتبعت الـ interruption warning (دقيقتين) و rebalance recommendations لـ SQS؛ Karpenter بيعمل cordon و drain (بيحترم الـ PDB في حدود الوقت) ويجيب node بديلة. التطبيق لازم: replicas ≥ 2 على AZs مختلفة، PDB، graceful shutdown أقل من دقيقتين (عندنا 40s)، stateless، وتنويع instance types في الـ NodePool عشان الـ Spot capacity.

</details>

<details><summary>HPA على CPU مش مناسب لكل حاجة — إيه البدائل؟</summary>

تطبيق I/O-bound (بيستنى DB) ممكن الـ latency تبوظ والـ CPU واطي. البدائل: custom/external metrics (RPS أو in-flight requests من Prometheus عن طريق Prometheus Adapter، أو KEDA بـ triggers: SQS queue length، Prometheus query، cron)، VPA لضبط الـ requests نفسها (مش مع HPA على نفس الـ metric)، وتحسين الـ bottleneck الحقيقي (DB، cache — [49](49-redis-sessions-cache.md)).

</details>

<details><summary>إيه علاقة الـ PDB بالـ consolidation والـ scale down؟</summary>

Karpenter بيستخدم الـ Eviction API، فالـ PDB بيحدد كام pod يقدر يطلع مرة واحدة؛ PDB بـ `maxUnavailable: 0` (أو `minAvailable` = replicas) بيوقف الـ consolidation والـ node upgrades خالص → تكلفة. والـ HPA scale down نفسه **مش** eviction (بيمسح pods مباشرة) فالـ PDB مش بيأثر عليه. عشان كده `maxUnavailable: 1` + replicas ≥ 2 هو التوازن.

</details>

## 13) Checklist

- [ ] حسبت الـ pods المطلوبة بالـ formula (RATE × CPU_MS / 1000 ÷ request × target) قبل التجربة
- [ ] على kind: الـ HPA كبّر لـ 6 وصغّر بعد الـ stabilization، وشفت `Insufficient cpu`
- [ ] فعّلت Karpenter في Terraform وعملت الـ EC2NodeClass و الـ NodePool من §5.3 (المصدر الرسمي ليهم)
- [ ] على EKS: الـ pods بقت Pending و Karpenter جاب node (وعرفت نوعها و spot/on-demand)
- [ ] شفت الـ consolidation بعد الـ load، وجرّبت أثر الـ PDB والـ NodePool limits
- [ ] مسحت الـ NodePools قبل `terraform destroy` واتأكدت إن مفيش EC2 instances فاضلة
