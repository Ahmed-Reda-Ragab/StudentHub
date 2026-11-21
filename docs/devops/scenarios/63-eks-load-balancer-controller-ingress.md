# 63 — AWS Load Balancer Controller + Ingress + ACM

> **الهدف في سطر:** تفهم إزاي `Ingress` بـ class `alb` بيتحول لـ ALB حقيقي على إيد الـ **AWS Load Balancer Controller** (target-type **ip** على الـ pods مباشرة، health check على `/ready`، `/metrics` بيرجع 404 من الـ ALB نفسه، readiness gates، deregistration delay)، تضيف **HTTPS بشهادة ACM** و redirect، وتعرف فكرة **ExternalDNS** (Route 53 records من الـ Ingress أوتوماتيك).
> **المستوى:** Intermediate · **الوقت:** ~3 ساعات · **التكلفة التقريبية:** الـ cluster + ALB (~$0.03/ساعة + LCU — تقريبي، راجع صفحة الأسعار)
> **بيعتمد على:** [62 — EKS بـ Terraform](62-eks-terraform.md) (أو [61](61-eks-console-eksctl.md)) · [42 — ALB + ASG](42-alb-asg-launch-template.md) (الـ ALB concepts) · [64](64-eks-external-secrets.md) (الـ Secret بييجي من SSM) · **الملفات في الـ repo:** [`k8s/helm/student-app/templates/ingress.yaml`](../../../k8s/helm/student-app/templates/ingress.yaml) · [`values-eks.yaml`](../../../k8s/helm/student-app/values-eks.yaml) · [`k8s/manifests/overlays/eks/ingress.yaml`](../../../k8s/manifests/overlays/eks/ingress.yaml) · [`k8s/manifests/overlays/eks/kustomization.yaml`](../../../k8s/manifests/overlays/eks/kustomization.yaml) · [`infra/terraform/stacks/60-eks/addons.tf`](../../../infra/terraform/stacks/60-eks/addons.tf) · [`pod-identity.tf`](../../../infra/terraform/stacks/60-eks/pod-identity.tf) · [`policies/aws-load-balancer-controller-iam-policy.json`](../../../infra/terraform/stacks/60-eks/policies/aws-load-balancer-controller-iam-policy.json) · [`k8s/argocd/apps/aws-load-balancer-controller.yaml`](../../../k8s/argocd/apps/aws-load-balancer-controller.yaml)

## 1) الفكرة (Concepts)

Kubernetes بيعرّف الـ `Ingress` كـ API بس (rules: host/path → Service). مين يحوّله لـ load balancer حقيقي؟ **Ingress controller**. على EKS الـ **AWS Load Balancer Controller (LBC)** بيعمل watch على Ingresses بـ `ingressClassName: alb` (و Services بـ `type: LoadBalancer` → NLB) وبيعمل ALB + listeners + rules + target groups، ويفضل يحدّث الـ targets كل ما pods تقوم أو تموت.

| المصطلح | المعنى |
|---|---|
| IngressClass `alb` | بيقول "الـ LBC هو المسؤول عن الـ Ingress ده" |
| `target-type: ip` | الـ ALB بيبعت لـ **pod IPs** مباشرة (الـ VPC CNI بيدّيهم IPs حقيقية) — من غير NodePort ولا kube-proxy hop |
| `target-type: instance` | الـ ALB → NodePort على كل node → kube-proxy → pod (hop زيادة، و health check على الـ node مش الـ pod) |
| TargetGroupBinding | CRD الـ LBC بيستخدمه يربط Service بـ target group ويزامن الـ endpoints |
| Pod readiness gate | label على الـ namespace (`elbv2.k8s.aws/pod-readiness-gate-inject: enabled`) → الـ LBC بيحقن condition: الـ pod مش Ready لحد ما الـ ALB target يبقى **healthy** |
| Deregistration delay | الـ ALB بيدّي الـ in-flight requests وقت يخلصوا بعد ما الـ target يتشال (30s عندنا) |
| Action annotation | `alb.ingress.kubernetes.io/actions.<name>`: fixed-response / redirect / forward بـ weights (Argo Rollouts بيستخدمها للـ canary — [68](68-k8s-canary-argo-rollouts.md)) |
| ACM | شهادات TLS مجانية (public) مع auto-renew لما الـ DNS validation record يفضل موجود |
| IngressGroup | `alb.ingress.kubernetes.io/group.name`: كذا Ingress على **ALB واحد** (توفير) |
| ExternalDNS | controller بيقرا الـ hosts من الـ Ingress ويعمل Route 53 records (و TXT records للـ ownership) |

**ليه ALB بالذات وليه ip mode؟** نفس الإشارة في الـ 3 أماكن: readiness probe على `/ready`، و ALB health check على `/ready` لكل pod، و readiness gate بيربط الاتنين. وده الأساس اللي الـ zero-downtime ([66](66-k8s-rolling-recreate.md)) والـ canary بالـ weights ([68](68-k8s-canary-argo-rollouts.md)) مبنيين عليه.

## 2) المعمارية (Architecture)

```text
 user ──► Route 53  student-app.<DOMAIN>  (alias A/AAAA — يدوي أو ExternalDNS)
            │
            ▼
 ┌─ ALB "student-app-lab-eks" (internet-facing، public subnets role/elb=1) ────────────────────┐
 │  :80   → redirect 443 (ssl-redirect)          :443 → ACM cert، TLS policy                  │
 │  rules (بالترتيب):  /metrics (Exact) → fixed-response 404  ← action "blocked-paths"         │
 │                     /         (Prefix) → forward → TG k8s-studenta-studenta-… (target-type ip)│
 │  TG health check: GET /ready → 200، interval 10s، healthy/unhealthy 2، deregistration 30s   │
 └──────────────┬──────────────────────────────────────────────────────────────────────────────┘
                │ مباشرة لـ pod IPs (10.60.x.x) على 8080 — NetworkPolicy: ingress 8080 من غير `from`
     ┌──────────┴──────────┐
  pod A (Ready ✔ + gate ✔)  pod B          ◄── readiness gate: target-health.elbv2.k8s.aws/…

 kube-system/aws-load-balancer-controller (Helm من Terraform أو Argo CD)
   ├─ Pod Identity → IAM role student-app-lab-aws-load-balancer-controller (policy رسمية v3.6.3)
   ├─ watches: Ingress(class alb) · Service(LoadBalancer) · Endpoints/Pods · TargetGroupBinding
   └─ webhook: يحقن الـ readiness gates في pods الـ namespaces المعلّمة
 [external-dns] (اختياري) Ingress host → Route 53 record + TXT owner
```

## 3) المتطلبات (Prerequisites)

- [ ] الستاك [62](62-eks-terraform.md) بـ `install_addons = true` و `addons.aws_load_balancer_controller = true` (و `external_secrets = true` عشان الـ Secret)، أو cluster [61](61-eks-console-eksctl.md) + §4.2.
- [ ] الـ public subnets عليها `kubernetes.io/role/elb=1` (Terraform بيعملها).
- [ ] image للتطبيق في ECR بـ SHA.
- [ ] (للـ HTTPS) domain عندك hosted zone ليه في Route 53 (`<DOMAIN>`). من غير domain: كمّل HTTP بس على الـ ALB DNS name.
- الأدوات: `kubectl`، `helm`، `aws`، `curl`.

## 4) الطريقة الأولى: AWS Console (يدوي)

### 4.1 شهادة ACM

1. **Certificate Manager (us-east-1 — نفس region الـ ALB) → Request certificate → Request a public certificate → Next**.
2. Fully qualified domain name: `student-app.<DOMAIN>` · Validation method: **DNS validation** · Key algorithm: RSA 2048 → **Request**.
3. افتح الشهادة → **Create records in Route 53** → **Create records**. استنى الـ Status يبقى **Issued** (دقايق).
4. انسخ الـ **ARN**: `arn:aws:acm:us-east-1:<ACCOUNT_ID>:certificate/<CERT_ID>`.

> 💡 سيب الـ CNAME بتاع الـ validation موجود: ده اللي بيخلي الـ auto-renew يشتغل.

### 4.2 الـ LBC من غير Terraform (لو على cluster [61](61-eks-console-eksctl.md))

1. **IAM → Policies → Create policy → JSON** → الصق محتوى [`aws-load-balancer-controller-iam-policy.json`](../../../infra/terraform/stacks/60-eks/policies/aws-load-balancer-controller-iam-policy.json) → اسم `student-app-lab-aws-load-balancer-controller`.
2. **IAM → Roles → Create role → AWS service → EKS → EKS - Pod Identity** → الـ policy اللي فوق → اسم `student-app-lab-aws-load-balancer-controller`.
3. **EKS → cluster → Access → Pod Identity associations → Create** → IAM role ده · Namespace `kube-system` · Service account `aws-load-balancer-controller` → **Create**.
4. الـ chart (من جهازك — نفس الـ values اللي Terraform بيحطها):

```bash
helm upgrade --install aws-load-balancer-controller aws-load-balancer-controller \
  --repo https://aws.github.io/eks-charts --version 3.6.3 -n kube-system \
  --set clusterName=<CLUSTER_NAME> --set region=us-east-1 --set vpcId=<VPC_ID> \
  --set replicaCount=1 --set serviceAccount.create=true --set serviceAccount.name=aws-load-balancer-controller
kubectl -n kube-system rollout status deploy/aws-load-balancer-controller
```

### 4.3 اتفرّج على اللي الـ controller عمله (بعد §6)

1. **EC2 → Load Balancers → `student-app-lab-eks`** → Listeners: HTTP:80 (وبعد §5.3 HTTPS:443 + redirect) → **View/edit rules**: rule بـ path `/metrics` → **Return fixed response 404**، و default → forward للـ target group.
2. **EC2 → Target groups → `k8s-studenta-…`** → Target type **IP** → Targets = pod IPs → Health checks: path `/ready`، success codes 200 → Attributes: Deregistration delay 30s.
3. **Route 53 → Hosted zones → `<DOMAIN>` → Create record**: `student-app` · Type A · **Alias → Alias to Application and Classic Load Balancer** → us-east-1 → الـ ALB → **Create** (ده اللي ExternalDNS بيعمله لوحده — §5.4).

## 5) الطريقة التانية: as Code

### 5.1 الـ Ingress في الـ chart

[`ingress.yaml`](../../../k8s/helm/student-app/templates/ingress.yaml) بيعمل 3 حاجات لما `className: alb`:

1. ياخد `ingress.annotations` من الـ values (`deepCopy`) ويضيف annotation `alb.ingress.kubernetes.io/actions.blocked-paths` = fixed-response 404.
2. لكل path في `ingress.blockPaths` (الافتراضي `[/metrics]`) يعمل rule **Exact** بـ backend `blocked-paths` / port `use-annotation` — **قبل** الـ catch-all `/` لأن الـ rules بتتقيّم بالترتيب ([CONVENTIONS §3](../CONVENTIONS.md): `/metrics` داخلي بس).
3. الـ `/` → Service `<fullname>` port `http` — **إلا** لو canary بـ ALB routing: ساعتها `use-annotation` لأن Argo Rollouts هو اللي بيكتب الـ forward action بالـ weights ([68](68-k8s-canary-argo-rollouts.md)).

الـ annotations من [`values-eks.yaml`](../../../k8s/helm/student-app/values-eks.yaml):

| Annotation | القيمة | ليه |
|---|---|---|
| `scheme` | `internet-facing` | ALB عام في الـ public subnets |
| `target-type` | `ip` | pod IPs مباشرة؛ health check لكل pod |
| `load-balancer-name` | `student-app-lab-eks` | اسم ثابت بدل `k8s-<ns>-<name>-<hash>` |
| `listen-ports` | `[{"HTTP": 80}]` | HTTPS في §5.3 |
| `healthcheck-path` / `success-codes` | `/ready` / `200` | نفس الـ readiness probe |
| `healthcheck-interval-seconds` / `healthy-threshold-count` / `unhealthy-threshold-count` | `10` / `2` / `2` | target جديد healthy في ~20s، ووقع في ~20s |
| `target-group-attributes` | `deregistration_delay.timeout_seconds=30` | الـ in-flight requests ياخدوا 30s (زي الـ graceful PHP-FPM) |
| `tags` | `Project=student-app,Env=lab,ManagedBy=helm,Scenario=63` | الـ ALB متعمل برا Terraform — الـ tags هي اللي بتلاقيه بيها |

والـ readiness gate: `deploy-eks.yml` بيعمل `kubectl label namespace student-app elbv2.k8s.aws/pod-readiness-gate-inject=enabled --overwrite`، و Argo CD بيحطه في `managedNamespaceMetadata` ([69](69-gitops-argocd.md))، والـ kustomize overlay بيعمله patch على الـ Namespace ([`overlays/eks/kustomization.yaml`](../../../k8s/manifests/overlays/eks/kustomization.yaml)). **لازم الـ label يبقى موجود قبل ما الـ pods تتعمل** (الـ webhook بيحقن وقت الإنشاء).

### 5.2 نفس الحاجة بالـ plain YAML

[`overlays/eks/ingress.yaml`](../../../k8s/manifests/overlays/eks/ingress.yaml) = نفس الـ annotations بالظبط، بـ action اسمه `block-metrics`. الـ overlay محتاج تحط الـ ECR image بـ `kustomize edit set image` والـ `APP_URL` و الـ VPC CIDR في الـ NetworkPolicy patch.

### 5.3 HTTPS بـ ACM

الـ values files بتتعمل **deep merge** في Helm، فملف صغير بيضيف/يغيّر annotations من غير ما تكرر الباقي (برا الـ repo):

```bash
cat > /tmp/values-https.yaml <<'EOF'
ingress:
  host: student-app.<DOMAIN>
  annotations:
    alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:us-east-1:<ACCOUNT_ID>:certificate/<CERT_ID>
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS": 443}]'
    alb.ingress.kubernetes.io/ssl-redirect: "443"
    alb.ingress.kubernetes.io/ssl-policy: ELBSecurityPolicy-TLS13-1-2-2021-06
EOF
```

- الـ TLS بيخلص على الـ ALB؛ التطبيق بيشوف HTTP + `X-Forwarded-Proto: https`. [`bootstrap/app.php`](../../../bootstrap/app.php) بيعمل `trustProxies(at: '*', headers: HEADER_X_FORWARDED_PROTO)` فـ Laravel بيطلّع روابط و forms بـ `https://` (من غيره: mixed content، والـ POST على http → redirect 301 → يتحول GET → الـ login يبوظ).
- **`APP_URL`**: الـ Secret (من SSM) بيكسب على `config.APP_URL` في الـ chart. غيّره من المصدر: `app_url = "https://student-app.<DOMAIN>"` في `terraform.tfvars` الستاك → apply → (ESO بيحدّث الـ Secret خلال `refreshInterval`) → `kubectl -n student-app rollout restart deploy/student-app` ([64](64-eks-external-secrets.md)).

### 5.4 ExternalDNS (الفكرة)

بدل ما تعمل الـ alias record بإيدك (§4.3)، ExternalDNS بيقرا `spec.rules[].host` من الـ Ingress (والـ ALB hostname من الـ status) ويعمل الـ record في Route 53، ومعاه **TXT record** بيقول "أنا صاحب الـ record ده" (`txtOwnerId`) عشان ميمسحش records حد تاني.

- متاح كـ **EKS community add-on** اسمه `external-dns` (namespace `external-dns`، SA `external-dns`) — الـ managed policy الافتراضية `AmazonRoute53FullAccess`، **ضيّقها**: `route53:ChangeResourceRecordSets` على `hostedzone/<ZONE_ID>` بس + `route53:ListHostedZones` + `route53:ListResourceRecordSets`.
- **policy**: `upsert-only` (مبيمسحش — أأمن) مقابل `sync` (بيمسح الـ records لما الـ Ingress يتشال). و `domainFilters` بيقفله على zone واحدة.

```bash
# role بـ trust pods.eks.amazonaws.com + الـ policy المضيقة (زي pod-identity.tf) ← <EXTERNAL_DNS_ROLE_ARN>
aws eks describe-addon-versions --addon-name external-dns --query 'addons[0].addonVersions[0].addonVersion'
aws eks describe-addon-configuration --addon-name external-dns --addon-version <VERSION>   # الـ schema الحقيقي للـ config
aws eks create-addon --cluster-name student-app-lab --addon-name external-dns \
  --pod-identity-associations serviceAccount=external-dns,roleArn=<EXTERNAL_DNS_ROLE_ARN> \
  --configuration-values file://external-dns-values.json      # domain filter / policy حسب الـ schema اللي فوق
```

(مش متعمل في الستاك عن قصد — Route 53 zone مش موجودة عند كل الناس.)

## 6) الـ Deploy

نفس اللي `deploy-eks.yml` بيعمله في mode `helm` ([65](65-helm-chart.md))، من جهازك:

```bash
aws eks update-kubeconfig --region us-east-1 --name student-app-lab
REGISTRY=<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com
kubectl apply -f k8s/manifests/base/namespace.yaml
kubectl label namespace student-app elbv2.k8s.aws/pod-readiness-gate-inject=enabled --overwrite   # قبل الـ pods!

helm upgrade --install student-app k8s/helm/student-app -n student-app \
  -f k8s/helm/student-app/values-eks.yaml \
  --set-string image.repository="$REGISTRY/student-app" --set-string image.tag=<GIT_SHA> \
  --set rollout.enabled=false \
  --wait --rollback-on-failure --timeout 10m
# HTTPS: أضف  -f /tmp/values-https.yaml

kubectl -n student-app get ingress student-app -w      # استنى الـ ADDRESS (~2–3 دقايق للـ ALB + DNS)
```

> 💡 `--set rollout.enabled=false` لأن `values-eks.yaml` افتراضياً Rollout (canary بالـ ALB). هنا عايزين Deployment عادي؛ الـ canary في [68](68-k8s-canary-argo-rollouts.md).

## 7) التحقق (Verify)

```bash
ALB=$(kubectl -n student-app get ingress student-app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -s "http://$ALB/ready"; echo
curl -s -o /dev/null -w '%{http_code}\n' "http://$ALB/metrics"          # 404 من الـ ALB (مش من التطبيق)
curl -sI "http://$ALB/metrics" | grep -i server                          # awselb/2.0 = الـ ALB هو اللي رد
curl -s -o /dev/null -w '%{http_code}\n' "http://$ALB/login"
# HTTPS:
curl -sI "http://student-app.<DOMAIN>/login" | grep -i location          # https://... (redirect)
curl -s "https://student-app.<DOMAIN>/ready"; echo

kubectl -n student-app get pods -o wide                                   # عمود READINESS GATES = 1/1
kubectl -n student-app get targetgroupbindings
TG=$(aws elbv2 describe-target-groups --load-balancer-arn \
      "$(aws elbv2 describe-load-balancers --names student-app-lab-eks --query 'LoadBalancers[0].LoadBalancerArn' --output text)" \
      --query 'TargetGroups[0].TargetGroupArn' --output text)
aws elbv2 describe-target-health --target-group-arn "$TG" --query 'TargetHealthDescriptions[].{ip:Target.Id,state:TargetHealth.State}'
kubectl -n kube-system logs deploy/aws-load-balancer-controller --tail=30
```

المفروض: الـ targets = pod IPs و `healthy`، `/metrics` = 404 بـ `Server: awselb/2.0`، والـ readiness gates `1/1`. وجرّب zero-downtime من برا: `bash deploy/scripts/probe.sh "http://$ALB/ready" 0 0.2` وفي terminal تاني `helm upgrade` بـ tag تاني → `failed : 0`.

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر | المتوقع |
|---|---|---|
| Subnet tag ناقص | شيل `kubernetes.io/role/elb` من الـ public subnets وامسح/أعد الـ Ingress | الـ Ingress من غير ADDRESS، و events/logs: الـ controller مش لاقي subnets مناسبة |
| من غير IAM | امسح الـ Pod Identity association وأعد تشغيل الـ controller | `AccessDenied` في logs الـ controller، ومفيش ALB |
| Health check غلط | `--set-string 'ingress.annotations.alb\.ingress\.kubernetes\.io/healthcheck-path=/nope'` | الـ targets `unhealthy` → الـ ALB يرجع 502/503؛ والـ readiness gate بيمنع الـ rollout يكمّل |
| preStop قصير | `--set preStopSleepSeconds=1` + rollout تحت `probe.sh` على الـ ALB | 502 متفرقة وقت ما الـ pods القديمة بتقفل قبل ما الـ ALB يبطّل يبعتلها |
| من غير readiness gate | شيل الـ label من الـ namespace وأعد إنشاء الـ pods + rollout سريع | الـ pod بيبقى Ready قبل ما الـ ALB target يبقى healthy → فترة capacity أقل/errors ممكنة |
| `/metrics` | `curl http://$ALB/metrics` | 404 من الـ ALB؛ من جوه الـ cluster `/metrics` شغال (Prometheus) |
| NetworkPolicy `from` | `--set 'networkPolicy.ingressFrom[0].podSelector.matchLabels.x=y'` | الـ ALB (مش pod) مبيوصلش → health checks تفشل. عشان كده الـ ingress rule من غير `from` |

## 9) الرجوع (Rollback)

```bash
helm -n student-app rollback student-app <REVISION> --wait      # annotations/Ingress القديمة ترجع والـ LBC يعدّل الـ ALB
helm -n student-app history student-app
```

- الـ LBC نفسه: رجّع `chart_versions.aws_load_balancer_controller` في Terraform (أو `targetRevision` في Argo CD — [69](69-gitops-argocd.md)).
- ACM cert غلط: رجّع الـ annotation بتاع الـ certificate للـ ARN القديم.

## 10) المسح (Teardown) ⚠️

```bash
kubectl -n student-app delete ingress student-app      # الأول! الـ controller بيمسح الـ ALB والـ TGs والـ SGs
aws elbv2 describe-load-balancers --names student-app-lab-eks 2>&1 | grep -q LoadBalancerNotFound && echo "ALB gone"
aws ec2 describe-security-groups --filters Name=tag:elbv2.k8s.aws/cluster,Values=student-app-lab --query 'SecurityGroups[].GroupId'
```

- لو عملت Route 53 record بإيدك امسحه؛ ExternalDNS بـ `upsert-only` **مبيمسحش** — امسح الـ A و الـ TXT بإيدك.
- الـ ACM cert مجاني — سيبه للسيناريوهات الجاية، أو **Delete** لو مش محتاجه.
- بعدها `terraform destroy` ([62 §10](62-eks-terraform.md)).

## 11) التكلفة (Cost)

| Resource | السعر التقريبي (us-east-1 — تقريبي، راجع صفحة الأسعار) |
|---|---|
| ALB | ~$0.0225/ساعة + LCU (~$0.008/LCU-ساعة) ≈ $17+/شهر |
| Public IPv4 للـ ALB | ~$0.005/ساعة لكل IP (IP لكل AZ) |
| ACM public certificate | مجاني |
| Route 53 hosted zone | ~$0.50/شهر + queries (الـ alias queries للـ AWS resources مجانية) |
| LBC / ExternalDNS | مجاني (pods على nodes موجودة) |
| IngressGroup | كذا app على ALB واحد بدل ALB لكل Ingress |

## 12) أسئلة Interview

<details><summary>Ingress بـ ALB ولا Service type LoadBalancer؟</summary>

`Service type: LoadBalancer` مع الـ LBC = **NLB** (L4، TCP/UDP، static IPs، أداء عالي، TLS passthrough أو termination). `Ingress` = **ALB** (L7: path/host routing، redirects، fixed responses، WAF، OIDC auth، weighted forward للـ canary). تطبيق web زي بتاعنا = ALB. NLB لـ gRPC/TCP أو لما محتاج static IP.

</details>

<details><summary>ليه target-type ip أحسن من instance هنا؟</summary>

ip: الـ ALB بيكلّم الـ pod مباشرة → health check لكل pod (مش لكل node)، مفيش hop تاني ولا SNAT من kube-proxy، الـ deregistration لكل pod لوحده، والـ readiness gates ممكنة، وبيشتغل مع Fargate. instance: كل node target والـ traffic بيعدّي NodePort → kube-proxy ممكن يوديه لـ node تانية (cross-AZ cost + latency) ومش بتشوف صحة كل pod. ip محتاج VPC CNI (pod IPs routable).

</details>

<details><summary>502/503 أثناء الـ deploy على EKS — إيه الأسباب وإزاي تحلها؟</summary>

(1) pod اتشال من الـ target group متأخر وهو بيقفل → preStop sleep أطول من وقت الـ deregistration propagation، و `terminationGracePeriodSeconds` يساع. (2) pod جديد اتعتبر Ready قبل ما الـ ALB يشوفه healthy → readiness gates. (3) health check مختلف عن الـ readiness → خليهم نفس الـ endpoint. (4) keep-alive: الـ ALB idle timeout (60s) لازم يبقى أقل من الـ keep-alive بتاع الـ backend، وإلا الـ backend يقفل connection الـ ALB لسه شايفها مفتوحة. (5) `maxUnavailable > 0` على replicas قليلة.

</details>

<details><summary>إزاي الـ readiness gate بيشتغل؟</summary>

الـ LBC عنده mutating webhook: أي pod جديد في namespace عليه الـ label بياخد `readinessGates` بـ condition type خاص بالـ target group. الـ kubelet بيعتبر الـ pod Ready لما الـ containers Ready **و** كل الـ gates `True`؛ والـ LBC بيحط الـ condition `True` بس لما الـ ALB target health = healthy. فالـ Deployment controller مش هيشيل pod قديم لحد ما الجديد يبقى فعلاً بياخد traffic من الـ ALB.

</details>

<details><summary>ليه `/metrics` بيتقفل على الـ ALB مش جوه التطبيق؟</summary>

defense in depth وتوفير: الـ ALB بيرد 404 من غير ما الـ request يوصل pod أصلاً، والتطبيق يفضل يخدم `/metrics` لـ Prometheus جوه الـ cluster من غير token لازم. وكمان الـ `METRICS_TOKEN` اختياري كطبقة تانية ([CONVENTIONS §3](../CONVENTIONS.md)).

</details>

<details><summary>ExternalDNS بيعرف إزاي إن الـ record بتاعه؟ وإيه خطر `sync`؟</summary>

بيكتب TXT record جنب كل record فيه الـ owner id. مبيعدّلش/يمسحش record من غير TXT بتاعه. `sync` بيمسح الـ records لما الـ Ingress يتشال — خطر لو اتنين clusters بنفس الـ owner id أو حد مسح Ingress بالغلط (DNS outage). `upsert-only` أأمن للـ production، مع domain filter ضيق و IAM على zone واحدة.

</details>

<details><summary>Gateway API — هل هيستبدل Ingress؟</summary>

Gateway API هو الجيل الجديد: roles منفصلة (GatewayClass للـ platform، Gateway للـ ops، HTTPRoute للـ app teams)، traffic splitting و header matching جزء من الـ spec بدل annotations خاصة بكل vendor. Ingress مش هيتشال قريب بس مفيش features جديدة فيه. الـ LBC بيدعم Gateway API في إصداراته الحديثة (راجع الـ docs)، و Argo Rollouts عنده plugin ليه. للمعمل Ingress أبسط ومدعوم كامل.

</details>

## 13) Checklist

- [ ] طلبت شهادة ACM بـ DNS validation
- [ ] الـ LBC شغال بـ Pod Identity (Terraform أو يدوي) وفهمت الـ IAM policy الرسمية
- [ ] نشرت التطبيق والـ Ingress عمل ALB؛ `/metrics` = 404 من الـ ALB
- [ ] شفت الـ targets (pod IPs) والـ readiness gates `1/1`
- [ ] ضفت HTTPS + redirect وفهمت `X-Forwarded-Proto` و `APP_URL` من SSM
- [ ] فهمت ExternalDNS (ownership، upsert-only)
- [ ] جرّبت الـ break-it (health check غلط، preStop قصير)
- [ ] مسحت الـ Ingress قبل الـ destroy واتأكدت إن الـ ALB اتشال
