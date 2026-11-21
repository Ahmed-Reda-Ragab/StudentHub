# 61 — EKS من الـ Console و eksctl

> **الهدف في سطر:** تعمل EKS cluster بإيدك مرتين — مرة من **AWS Console** (Custom configuration + managed node group + access entries + add-ons) ومرة بـ **eksctl** (ملف `ClusterConfig` واحد) — وتفهم مين بيدير إيه (control plane / data plane)، وإزاي `kubectl` بيتوثّق (IAM → access entry → RBAC)، وتنشر التطبيق عليه بالـ chart، وتعرف إمتى **EKS Auto Mode** هو الاختيار الصح.
> **المستوى:** Intermediate · **الوقت:** ~4 ساعات (منهم ~30 دقيقة استنى) · **التكلفة التقريبية:** ~$4–5/يوم لكل cluster (تقريبي — راجع صفحة الأسعار)
> **بيعتمد على:** [02 — حساب AWS](02-aws-account-setup.md) · [30 — CI و OIDC](30-ci-github-actions.md) (الـ image في ECR والـ deploy role) · [40 — VPC من الصفر](40-vpc-from-scratch.md) · [60 — kind](60-kubernetes-on-kind.md) · **الملفات في الـ repo:** [`k8s/helm/student-app/values.yaml`](../../../k8s/helm/student-app/values.yaml) · [`k8s/kind/mysql.yaml`](../../../k8s/kind/mysql.yaml) · [`k8s/manifests/base/namespace.yaml`](../../../k8s/manifests/base/namespace.yaml) · [`infra/terraform/stacks/60-eks/main.tf`](../../../infra/terraform/stacks/60-eks/main.tf) (للمقارنة مع [62](62-eks-terraform.md)) · [`.github/workflows/deploy-eks.yml`](../../../.github/workflows/deploy-eks.yml)

## 1) الفكرة (Concepts)

**EKS = control plane مُدار.** AWS بتشغّل الـ API server و etcd على أكتر من AZ في حسابها، وبتحط ENIs في الـ subnets بتاعتك عشان الـ control plane يكلّم الـ nodes. إنت مسؤول عن الـ **data plane** (الـ nodes اللي بتشغّل الـ pods) — إلا لو اخترت **Auto Mode** أو Fargate.

| المصطلح | المعنى |
|---|---|
| Cluster IAM role | الـ role اللي الـ control plane بيستخدمه عشان يدير موارد AWS (ENIs...). policy: `AmazonEKSClusterPolicy` |
| Node IAM role | الـ role بتاع الـ EC2 nodes: `AmazonEKSWorkerNodePolicy` + `AmazonEC2ContainerRegistryReadOnly` + `AmazonEKS_CNI_Policy` (+ `AmazonSSMManagedInstanceCore` للـ Session Manager) |
| Managed node group (MNG) | ASG بتديرها EKS: AMI، upgrades بـ drain، Spot |
| Access entry + access policy | الطريقة الحديثة لربط IAM principal بصلاحيات Kubernetes (`AmazonEKSClusterAdminPolicy`، `AmazonEKSEditPolicy`...) من الـ EKS API — بدل الـ `aws-auth` ConfigMap القديم |
| Cluster authentication mode | `API` (access entries بس) · `API_AND_CONFIG_MAP` · `CONFIG_MAP` (قديم) |
| EKS add-on | component بتدير AWS الـ lifecycle بتاعه (VPC CNI، CoreDNS، kube-proxy، Pod Identity Agent، EBS CSI، metrics-server كـ community add-on) |
| VPC CNI | كل pod بياخد IP حقيقي من الـ VPC؛ عدد الـ pods محدود بالـ ENIs/IPs إلا مع **prefix delegation** |
| Pod Identity | IAM role لـ ServiceAccount معين عن طريق association في الـ EKS API + الـ `eks-pod-identity-agent` (أبسط من IRSA: من غير OIDC provider ولا trust لكل cluster) |
| Endpoint access | Public (بـ CIDR allowlist) و/أو Private (من جوه الـ VPC) |
| Support type | **Standard** (~14 شهر لكل version) أو **Extended** (أغلى بكتير — §11) |
| EKS Auto Mode | AWS بتدير الـ compute (Karpenter مُدار) والـ load balancing والـ block storage والـ networking add-ons كمان، بـ fee فوق سعر الـ EC2 |

**اختيار الـ data plane:**

| | Managed node group | Karpenter ([6A](6A-hpa-karpenter-under-load.md)) | EKS Auto Mode | Fargate |
|---|---|---|---|---|
| مين بيختار الـ instance | إنت (قائمة ثابتة) | Karpenter حسب الـ pending pods | AWS (managed Karpenter) | مفيش nodes |
| Scale | Cluster Autoscaler / يدوي | ثواني، consolidation | تلقائي | لكل pod |
| تدير upgrades/AMIs | جزئياً | جزئياً | لأ | لأ |
| التكلفة الإضافية | — | — | management fee على كل instance | سعر أعلى لكل vCPU، من غير DaemonSets |
| في المعمل | 61، 62 | 6A | ملاحظة (§5.3) | — |

## 2) المعمارية (Architecture)

```text
 laptop (aws sso / kubectl) ──HTTPS──► EKS public endpoint (CIDR = <MY_IP>/32)
                                          │ IAM authN (aws eks get-token)
                                          ▼
 ┌── AWS-managed account ───────────────────────────────────────────────┐
 │  EKS control plane: API server + etcd (multi-AZ)  ── access entries  │
 └──────────────┬───────────────────────────────────────────────────────┘
                │ cross-account ENIs في الـ private subnets
 ┌── VPC 10.60.0.0/16 (2 AZs، من غير NAT) ─────────────────────────────────────────────┐
 │  public  10.60.0.0/20  (az-a)  role/elb=1        public  10.60.16.0/20 (az-b)        │
 │   ├─ node t3.medium (MNG "default", public IP)    ├─ node t3.medium                  │
 │   │    pods بـ IPs من الـ VPC (VPC CNI)            │                                  │
 │  private 10.60.128.0/20 (az-a) internal-elb=1    private 10.60.144.0/20 (az-b)       │
 │   └─ control-plane ENIs                           └─ control-plane ENIs              │
 │  IGW ◄── الـ nodes بتسحب من ECR عن طريق الـ public IP (من غير NAT = توفير ~$32/شهر)   │
 └────────────────────────────────────────────────────────────────────────────────────┘
 add-ons: vpc-cni (network policy + prefix delegation) · coredns · kube-proxy
          eks-pod-identity-agent · metrics-server · aws-ebs-csi-driver (للـ MySQL PVC في التجربة)
 access : <your SSO role> (creator → admin) · student-app-gha-deploy (cluster admin، لـ deploy-eks.yml)
```

نفس الـ layout اللي Terraform بيعمله في [62](62-eks-terraform.md) (`vpc_cidr = 10.60.0.0/16`، `/20` subnets، من غير NAT، الـ nodes في الـ public subnets)، عشان `values-eks.yaml` (الـ NetworkPolicy على `10.60.0.0/16`) يفضل صح.

## 3) المتطلبات (Prerequisites)

- [ ] AWS CLI v2 بـ profile شغال ([02](02-aws-account-setup.md)) و **AWS Budget** متظبط.
- [ ] `kubectl` (±1 minor من الـ cluster)، `helm` v4، `eksctl` (EKS docs بتطلب ≥ `0.215.0` — راجع `eksctl version`) — التسطيب في [03](03-workstation-setup.md).
- [ ] image للتطبيق في ECR بـ SHA tag ([30](30-ci-github-actions.md)): `aws ecr describe-images --repository-name student-app --query 'imageDetails[].imageTags[]'`.
- [ ] (اختياري) الـ bootstrap اتعمله apply فالـ role `student-app-gha-deploy` موجود ([30](30-ci-github-actions.md)).
- [ ] الـ IP بتاعك: `curl -s https://checkip.amazonaws.com`.

> ⚠️ متعملش الـ Console cluster والـ eksctl cluster والـ Terraform stack في نفس الوقت — كل واحد ~$0.20/ساعة. اعمل واحد، جرّب، امسح.

## 4) الطريقة الأولى: AWS Console (يدوي)

### 4.1 الـ VPC (لو مش عندك واحدة من [40](40-vpc-from-scratch.md))

1. **VPC → Create VPC → VPC and more**: Name `student-app-lab-eks` · IPv4 CIDR `10.60.0.0/16` · AZs **2** · Public subnets **2** · Private subnets **2** · **NAT gateways: None** · VPC endpoints: S3 Gateway (مجاني) · DNS hostnames + DNS resolution ✅ → **Create VPC**.
2. لكل **public** subnet: **Actions → Edit subnet settings → Enable auto-assign public IPv4 address** ✅، و **Tags**: `kubernetes.io/role/elb` = `1`.
3. لكل **private** subnet: Tag `kubernetes.io/role/internal-elb` = `1`.

> 💡 من غير NAT، الـ node محتاجة public IP عشان تسحب images وتكلّم الـ EKS endpoint — والـ managed node group بيرفض public subnet مش عاملة auto-assign. والـ tags دي هي اللي الـ AWS Load Balancer Controller بيدوّر بيها على الـ subnets ([63](63-eks-load-balancer-controller-ingress.md)).

### 4.2 الـ IAM roles

ممكن تسيب الـ wizard يعملهم (**Create recommended role**)، بس اعملهم مرة بإيدك عشان تفهم:

1. **IAM → Roles → Create role → AWS service → EKS → EKS - Cluster** → `AmazonEKSClusterPolicy` → اسم `student-app-lab-eks-cluster-role`.
2. **Create role → AWS service → EC2** → policies: `AmazonEKSWorkerNodePolicy`، `AmazonEC2ContainerRegistryReadOnly`، `AmazonEKS_CNI_Policy`، `AmazonSSMManagedInstanceCore` → اسم `student-app-lab-eks-node-role`.

### 4.3 الـ cluster

1. **EKS → Clusters → Add cluster → Create**.
2. **Configuration options: Custom configuration** · **EKS Auto Mode → Use EKS Auto Mode: off**.
3. **Configure cluster**: Name `student-app-lab-console` · Cluster IAM role `student-app-lab-eks-cluster-role` · Kubernetes version **1.36** · **Support type: Standard support** · Secrets encryption: اختياري (KMS) · Tags: `Project=student-app`، `Env=lab`، `ManagedBy=console`، `Scenario=61`.
4. **Cluster access**: Bootstrap cluster administrator access = **Allow** (الافتراضي — إنت admin) · **Cluster authentication mode: EKS API** → **Next**.
5. **Specify networking**: VPC `student-app-lab-eks` · Subnets: الـ **2 private** (هنا بتتحط الـ control-plane ENIs) · IPv4 · **Cluster endpoint access: Public and private** → وسّع الإعدادات المتقدمة وحط **`<MY_IP>/32`** بدل `0.0.0.0/0` → **Next**.
6. **Configure observability**: Control plane logging: `API`، `Audit`، `Authenticator` (كل نوع بيتحاسب ingestion — سيبهم off لو مش محتاجهم) → **Next**.
7. **Select add-ons**: سيب `Amazon VPC CNI` و `CoreDNS` و `kube-proxy` (متعلّمين افتراضياً)، واتأكد إن `Amazon EKS Pod Identity Agent` متعلّم (لو مش متعلّم اختاره)، وضيف من الـ community add-ons **Metrics Server** → **Next**.
8. **Configure selected add-ons settings**: الـ versions الافتراضية. للـ VPC CNI، في **Optional configuration settings → Configuration values** حط:

   ```json
   {"enableNetworkPolicy": "true", "env": {"ENABLE_PREFIX_DELEGATION": "true", "WARM_PREFIX_TARGET": "1"}}
   ```

   (لو الحقل مش ظاهر في الـ wizard: بعد الإنشاء **Add-ons → Amazon VPC CNI → Edit**.) → **Next → Review and create → Create**. الحالة `CREATING` ~10 دقايق.

> 💡 `enableNetworkPolicy` = الـ chart بيشحن NetworkPolicy، ومن غير ده الـ object موجود ومش متطبق. الـ prefix delegation = t3.medium بيشيل ~110 pod بدل ~17 (حدود الـ ENI IPs) — من غيرها Argo CD + Prometheus + التطبيق مش هيساعوا على 2 nodes ([62](62-eks-terraform.md)).

### 4.4 الـ managed node group

1. الـ cluster → تاب **Compute → Add node group**.
2. Name `default` · Node IAM role `student-app-lab-eks-node-role` → **Next**.
3. AMI type **Amazon Linux 2023 (x86_64) Standard** · Capacity type **On-Demand** (أو **Spot** — [62](62-eks-terraform.md)) · Instance types `t3.medium` · Disk 20 GiB · Scaling: Desired **2**، Min **2**، Max **4** · Update config: Max unavailable 1 → **Next**.
4. Subnets: الـ **2 public** · Configure remote access: **off** (هندخل بـ SSM) → **Next → Create**. ~3–5 دقايق.

### 4.5 الـ kubeconfig والـ access

```bash
aws eks update-kubeconfig --region us-east-1 --name student-app-lab-console --alias console
kubectl get nodes -o wide              # 2 nodes Ready، OS-IMAGE Amazon Linux 2023
kubectl get pods -A                    # aws-node، coredns، kube-proxy، eks-pod-identity-agent، metrics-server
kubectl auth can-i '*' '*' --all-namespaces
```

**الـ deploy role (لـ `deploy-eks.yml`):** الـ cluster → تاب **Access → IAM access entries → Create access entry** → IAM principal ARN `arn:aws:iam::<ACCOUNT_ID>:role/student-app-gha-deploy` · Type **Standard** → **Next** → Access policy **AmazonEKSClusterAdminPolicy** · Access scope **Cluster** → **Add policy → Next → Create**. نفس الحاجة بالـ CLI:

```bash
aws eks create-access-entry --cluster-name student-app-lab-console \
  --principal-arn arn:aws:iam::<ACCOUNT_ID>:role/student-app-gha-deploy --type STANDARD
aws eks associate-access-policy --cluster-name student-app-lab-console \
  --principal-arn arn:aws:iam::<ACCOUNT_ID>:role/student-app-gha-deploy \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster
aws eks list-access-entries --cluster-name student-app-lab-console
```

> 🔐 ليه **cluster** admin مش namespace؟ لأن `deploy-eks.yml` بيعمل `kubectl apply -f namespace.yaml` والـ chart بيعمل `ClusterSecretStore` (cluster-scoped). البديل الـ least-privilege: `AmazonEKSEditPolicy` بـ scope `namespace` = `student-app`، والـ namespace والـ store يعملهم الـ platform (Terraform/Argo) مرة واحدة.

### 4.6 الـ EBS CSI add-on (عشان الـ MySQL PVC في التجربة)

EKS **من غير Auto Mode** مفيهوش driver للـ EBS افتراضياً، والـ `gp2` StorageClass في الـ clusters الجديدة مش default — فالـ PVC بتاع [`mysql.yaml`](../../../k8s/kind/mysql.yaml) هيفضل `Pending`.

1. **Add-ons → Get more add-ons → Amazon EBS CSI Driver → Next**.
2. **Pod Identity IAM role → Create recommended role** (الـ console بيملا الـ trust `pods.eks.amazonaws.com` والـ policy `AmazonEBSCSIDriverPolicy`) → ارجع واختاره → **Next → Create**.
3. تاب **Access → Pod Identity associations**: هتلاقي association لـ `kube-system/ebs-csi-controller-sa` — ده نفس الآلية اللي Terraform بيستخدمها للـ LBC والـ ESO ([`pod-identity.tf`](../../../infra/terraform/stacks/60-eks/pod-identity.tf)).

> 💡 التاب **Resources** في الـ console بيعرض الـ pods والـ Deployments… بس محتاج إن الـ IAM principal اللي فاتح الـ console يبقى عنده access entry (وإلا: "Your current IAM principal doesn't have access to Kubernetes objects").

## 5) الطريقة التانية: eksctl (ملف واحد)

### 5.1 الـ ClusterConfig

eksctl بيترجم الملف لـ CloudFormation stacks (`eksctl-<name>-cluster`، `eksctl-<name>-nodegroup-default`، و stacks للـ addon roles). الملف ده بيعمل نفس شكل §4 (افتكر: **الـ NAT افتراضياً `Single` في eksctl** — قفلناه):

```bash
MY_IP=$(curl -s https://checkip.amazonaws.com)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
cat > /tmp/eksctl-61.yaml <<EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: student-app-lab-eksctl
  region: us-east-1
  version: "1.36"
  tags: {Project: student-app, Env: lab, ManagedBy: eksctl, Scenario: "61"}

vpc:
  cidr: 10.60.0.0/16
  nat:
    gateway: Disable            # الافتراضي Single = NAT بـ ~\$32/شهر
  clusterEndpoints:
    publicAccess: true
    privateAccess: true
  publicAccessCIDRs: ["${MY_IP}/32"]

accessConfig:
  authenticationMode: API
  accessEntries:
    - principalARN: arn:aws:iam::${ACCOUNT_ID}:role/student-app-gha-deploy
      accessPolicies:
        - policyARN: arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy
          accessScope: {type: cluster}

addonsConfig:
  autoApplyPodIdentityAssociations: true     # الـ add-ons اللي بتدعم Pod Identity تاخد الـ role الموصى بيه
addons:
  - name: eks-pod-identity-agent
  - name: vpc-cni
    configurationValues: '{"enableNetworkPolicy":"true","env":{"ENABLE_PREFIX_DELEGATION":"true","WARM_PREFIX_TARGET":"1"}}'
  - name: coredns
  - name: kube-proxy
  - name: metrics-server
  - name: aws-ebs-csi-driver

managedNodeGroups:
  - name: default
    amiFamily: AmazonLinux2023
    instanceTypes: ["t3.medium"]
    # spot: true                 # + instanceTypes: ["t3.medium","t3a.medium"]
    minSize: 2
    desiredCapacity: 2
    maxSize: 4
    volumeSize: 20
    privateNetworking: false     # public subnets (من غير NAT)
    labels: {student-app/pool: default}
    iam:
      # attachPolicyARNs بيستبدل الـ defaults، فلازم تكتبهم كلهم
      attachPolicyARNs:
        - arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy
        - arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy
        - arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
        - arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

cloudWatch:
  clusterLogging:
    enableTypes: ["api", "audit", "authenticator"]
    logRetentionInDays: 7
EOF
```

لو الـ deploy role مش موجود لسه (الـ bootstrap متعملش)، امسح الـ `accessEntries` — الـ principal لازم يكون موجود.

```bash
eksctl create cluster -f /tmp/eksctl-61.yaml --dry-run | less    # الـ config بعد الـ defaults، من غير ما يعمل حاجة
eksctl create cluster -f /tmp/eksctl-61.yaml                      # ~15–20 دقيقة؛ بيكتب الـ kubeconfig لوحده
eksctl get cluster --region us-east-1
eksctl get nodegroup --cluster student-app-lab-eksctl --region us-east-1
eksctl get addon --cluster student-app-lab-eksctl --region us-east-1
eksctl get podidentityassociation --cluster student-app-lab-eksctl --region us-east-1
```

> 💡 لو فشل add-on بسبب الترتيب (مثلاً الـ Pod Identity لسه مش جاهز)، شيله من الملف واعمله بعدين: `eksctl create addon -f /tmp/eksctl-61.yaml`. eksctl هو "IaC خفيف": declarative للإنشاء، بس الـ updates لكل جزء ليها أمر (`eksctl upgrade cluster`، `eksctl update addon`...) — مفيش `plan`/drift زي Terraform ([62](62-eks-terraform.md)).

### 5.2 Pod Identity بـ eksctl (للـ controllers في [63](63-eks-load-balancer-controller-ingress.md)/[64](64-eks-external-secrets.md))

```bash
eksctl create podidentityassociation --cluster student-app-lab-eksctl --region us-east-1 \
  --namespace kube-system --service-account-name aws-load-balancer-controller \
  --well-known-policies awsLoadBalancerController
eksctl get podidentityassociation --cluster student-app-lab-eksctl --region us-east-1
```

(في Terraform نفس الفكرة: `aws_iam_role` بـ trust `pods.eks.amazonaws.com` + `aws_eks_pod_identity_association`.)

### 5.3 ملاحظة: EKS Auto Mode

- **Console:** Add cluster → Create → **Quick configuration (with EKS Auto Mode)** — اسم و cluster role و node role و VPC، وخلاص.
- **eksctl:** `autoModeConfig: {enabled: true}` في الـ `ClusterConfig` (بيعمل node pools `general-purpose` و `system` و node role لوحده).
- **Terraform:** الـ module بيدعم Auto Mode بـ input خاص (`compute_config` في v21 — راجع README الـ module)؛ الستاك بتاعنا **مش** بيستخدمه.

Auto Mode بيدير الـ compute (Karpenter مُدار، AMIs، patching)، والـ load balancing، والـ EBS، والـ VPC CNI/CoreDNS/kube-proxy كجزء من الـ platform. **التكلفة:** fee لكل instance بيديره، فوق سعر الـ EC2 (مثال صفحة الأسعار بيطلع ~12% من سعر الـ instance — تقريبي، راجع الصفحة). **إمتى:** فريق صغير عايز يشيل الـ undifferentiated heavy lifting. **ليه مش في المعمل:** هدفنا نتعلم الأجزاء دي بإيدينا (LBC، Karpenter، add-ons)، والـ chart مكتوب للـ AWS Load Balancer Controller بـ IngressClass `alb`؛ Auto Mode بيستخدم controller اسمه `eks.amazonaws.com/alb` بـ IngressClass + IngressClassParams بتوعه — مش نفس الـ setup.

## 6) الـ Deploy — التطبيق على الـ cluster

مفيش RDS ولا LBC ولا ESO هنا (دول [62](62-eks-terraform.md)–[64](64-eks-external-secrets.md)) — فهنشغّل الـ lab MySQL من [60](60-kubernetes-on-kind.md) على EBS، والتطبيق بالـ chart، ونوصله بـ port-forward.

```bash
# 1) StorageClass gp3 default (الـ EBS CSI driver من §4.6 / eksctl)
cat <<'EOF' | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
parameters:
  type: gp3
  encrypted: "true"
EOF

# 2) namespace (PSS restricted) + MySQL + Secret — نفس خطوات kind
kubectl apply -f k8s/manifests/base/namespace.yaml
kubectl apply -f k8s/kind/mysql.yaml
kubectl -n student-app rollout status statefulset/mysql --timeout=300s
DB_PASSWORD=$(kubectl -n student-app get secret mysql-credentials -o jsonpath='{.data.MYSQL_PASSWORD}' | base64 -d)
kubectl -n student-app create secret generic student-app-secrets \
  --from-literal=APP_KEY="base64:$(openssl rand -base64 32)" \
  --from-literal=DB_USERNAME=student --from-literal=DB_PASSWORD="$DB_PASSWORD"

# 3) values للتجربة دي (برا الـ repo)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
cat > /tmp/values-61.yaml <<EOF
image:
  repository: ${ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com/student-app
config:
  DB_HOST: mysql
networkPolicy:
  databaseTo:
    - podSelector:
        matchLabels:
          app.kubernetes.io/name: mysql
EOF

# 4) التطبيق: Deployment + HPA (metrics-server موجود) + migration hook
helm upgrade --install student-app k8s/helm/student-app -n student-app \
  -f /tmp/values-61.yaml --set-string image.tag=<GIT_SHA> --wait --timeout 10m
kubectl -n student-app port-forward svc/student-app 8080:80
```

## 7) التحقق (Verify)

```bash
curl -s localhost:8080/ready; echo                         # من terminal تاني: version = <GIT_SHA>
aws eks describe-cluster --name student-app-lab-console \
  --query 'cluster.{status:status,version:version,auth:accessConfig.authenticationMode,public:resourcesVpcConfig.publicAccessCidrs}'
aws eks list-addons --cluster-name student-app-lab-console
kubectl get nodes -L eks.amazonaws.com/capacityType,topology.kubernetes.io/zone
kubectl -n student-app get pods -o wide                     # الـ pod IPs من 10.60.x.x (VPC CNI)
kubectl top nodes && kubectl -n student-app get hpa
kubectl get pvc -n student-app                              # Bound على gp3
kubectl describe node | grep -i "pods:" | head -2           # الـ allocatable pods (prefix delegation)
```

المفروض: الـ cluster `ACTIVE` بـ `API` auth والـ CIDR بتاعك بس، 2 nodes على AZs مختلفة، الـ pods بـ IPs من الـ VPC، والـ HPA شايف CPU (مش `<unknown>`).

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر | المتوقع |
|---|---|---|
| IP اتغيّر | `aws eks update-cluster-config --name <CLUSTER> --resources-vpc-config publicAccessCidrs=203.0.113.1/32` | `kubectl` بيعمل timeout (مش 403) — الـ endpoint مش reachable أصلاً. رجّع الـ CIDR بتاعك |
| access entry اتمسح | امسح الـ entry بتاع principal تاني (مش إنت) وجرّب بيه | `error: You must be logged in to the server (Unauthorized)` |
| public subnet من غير auto-assign IP | node group على subnet الإعداد ده فيها off | الـ node group يفشل (`Instances failed to join the kubernetes cluster` / health issue) |
| EBS CSI من غير role | امسح الـ Pod Identity association بتاعته | الـ PVC الجديد `Pending`، و logs الـ `ebs-csi-controller` فيها AccessDenied |
| مفيش capacity | `--set autoscaling.minReplicas=12` (requests 100m × 12 + MySQL) | لو مكفّتش: pods `Pending` بـ `Insufficient cpu` — ده اللي Karpenter بيحله في [6A](6A-hpa-karpenter-under-load.md) |
| kubectl قديم | client أقدم من الـ cluster بـ 2 minor | warnings/سلوك غريب — التزم بـ ±1 |

## 9) الرجوع (Rollback)

- **Kubernetes version:** مفيش downgrade للـ control plane. الـ upgrade بيتعمل خطوة minor واحدة (control plane → add-ons → node groups) بعد ما تقرا الـ deprecated APIs. عشان كده الستاك بيثبت `kubernetes_version` والـ upgrade policy `STANDARD` ([62](62-eks-terraform.md)).
- **Node group:** update فاشل (AMI جديدة) بيرجع لوحده؛ أو اعمل node group جديدة وامسح القديمة (blue/green للـ nodes).
- **التطبيق:** `helm -n student-app rollback student-app <REVISION>` ([65](65-helm-chart.md)).
- **Access:** لو قفلت نفسك برا — الـ creator access entry موجود؛ لو اتشال، أي principal عنده `eks:CreateAccessEntry` (IAM) يقدر يرجّعه. ده سبب إن الـ EKS API mode أأمن من `aws-auth` (ConfigMap غلط = قفل كامل).

## 10) المسح (Teardown) ⚠️

```bash
helm -n student-app uninstall student-app
kubectl delete namespace student-app          # بيمسح الـ PVC → الـ EBS volume (reclaimPolicy Delete)
kubectl get pv                                 # لازم تبقى فاضية قبل ما تمسح الـ cluster

# eksctl
eksctl delete cluster -f /tmp/eksctl-61.yaml --disable-nodegroup-eviction --wait

# Console: الترتيب مهم
#   EKS → cluster → Compute → node group → Delete (استنى)  →  Delete cluster
#   IAM roles (cluster/node/EBS CSI) → VPC (Delete VPC بيمسح الـ subnets/IGW)
```

اتأكد إن مفيش حاجة فاضلة:

```bash
aws eks list-clusters
aws ec2 describe-volumes --filters Name=tag-key,Values=kubernetes.io/created-for/pvc/name --query 'Volumes[].VolumeId'
aws cloudformation list-stacks --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE --query "StackSummaries[?starts_with(StackName,'eksctl-')].StackName"
aws logs describe-log-groups --log-group-name-prefix /aws/eks/
```

## 11) التكلفة (Cost)

| Resource | السعر التقريبي (us-east-1 — تقريبي، راجع صفحة الأسعار) |
|---|---|
| EKS control plane — Standard support | $0.10/ساعة (~$2.4/يوم) |
| EKS control plane — Extended support | $0.60/ساعة (6×) — سبب `Support type: Standard` |
| 2 × t3.medium On-Demand | ~$0.083/ساعة (Spot عادةً أرخص بـ 60–70%) |
| 2 × public IPv4 | ~$0.005/ساعة لكل IP |
| EBS (2 × 20 GiB root + 2 GiB MySQL، gp3) | ~$0.08/GB/شهر |
| Control plane logs | ingestion لكل GB — اقفلها لو مش محتاجها |
| NAT gateway (لو سبت default eksctl) | ~$0.045/ساعة + data — **قفلناه** |
| EKS Auto Mode | fee فوق سعر كل instance (~12% في مثال صفحة الأسعار) |
| **الإجمالي (default هنا)** | **~$0.20/ساعة ≈ $4.5–5/يوم** |

## 12) أسئلة Interview

<details><summary>إيه اللي EKS بيديره وإيه اللي عليك؟</summary>

AWS: الـ API server و etcd (multi-AZ، backups، patching للـ control plane)، والـ endpoint. إنت: الـ data plane (AMIs، upgrades للـ node groups، الـ capacity)، الـ add-ons versions (حتى لو managed add-ons إنت اللي بتعمل upgrade)، الـ networking (VPC، subnets، IPs)، الـ IAM والـ RBAC، والـ workloads. Auto Mode بيزحزح الخط ده: الـ compute والـ LB والـ storage بقوا على AWS.

</details>

<details><summary>Access entries مقابل `aws-auth` ConfigMap؟</summary>

`aws-auth` = ConfigMap جوه الـ cluster بيربط IAM ARNs بـ Kubernetes groups — أي غلطة YAML ممكن تقفل الكل برا، ومحتاج access للـ cluster عشان تعدّله، ومفيش audit كويس. Access entries = جزء من الـ EKS API: بتتدار بـ IAM permissions و CloudTrail و Terraform، وفيه access policies جاهزة بـ scope (cluster/namespace)، وتقدر ترجّع access من برا الـ cluster. مع `authenticationMode: API` الـ ConfigMap بيتجاهل خالص.

</details>

<details><summary>Pod Identity مقابل IRSA؟</summary>

IRSA: OIDC provider لكل cluster، والـ role trust policy فيها الـ issuer والـ `sub` (namespace/SA)، والـ SA عليه annotation. نقل لـ cluster جديد = تعديل الـ trust. Pod Identity: الـ trust ثابت (`pods.eks.amazonaws.com`)، والربط association في الـ EKS API، والـ agent DaemonSet بيدّي الـ credentials، وفيه session tags (cluster/namespace/SA) تقدر تستخدمها في ABAC. IRSA لسه مطلوب في حالات (Fargate، بعض الـ add-ons القديمة، clusters برا EKS).

</details>

<details><summary>إيه مشكلة الـ IPs مع الـ VPC CNI وإزاي تحلها؟</summary>

كل pod بياخد IP من الـ subnet، والـ instance ليها حد ENIs × IPs (t3.medium ≈ 17 pod). الحلول: **prefix delegation** (كل slot = /28 = 16 IP → ~110 pod/node بس الـ subnets لازم تكون واسعة ومش متقطعة — عشان كده `/20`)، custom networking (secondary CIDR زي 100.64.0.0/10 للـ pods)، IPv6، أو subnets أكبر. والـ `WARM_*` settings بتوازن بين سرعة تشغيل الـ pods وهدر الـ IPs.

</details>

<details><summary>Public ولا private endpoint؟</summary>

Private بس = لازم VPN/bastion/CI جوه الـ VPC (أأمن). Public بـ CIDR allowlist = مريح للـ lab و GitHub-hosted runners — بس الـ runners IPs كتير ومتغيرة، فعملياً `0.0.0.0/0` + الاعتماد على IAM auth، أو self-hosted runners جوه الـ VPC. "Public and private" = الـ nodes بتكلّم الـ API من جوه الـ VPC، والـ admins من برا بالـ allowlist.

</details>

<details><summary>Managed node groups ولا Karpenter ولا Auto Mode؟</summary>

MNG: بسيطة ومتوقعة، بس instance types ثابتة والـ scale بطيء (Cluster Autoscaler). Karpenter: bin-packing وتنوع instance types و Spot و consolidation في ثواني — بس إنت بتديره (controller، NodePools، interruption queue). Auto Mode: Karpenter مُدار + LB + storage، بـ fee، وتحكم أقل. عملياً كتير بيعملوا MNG صغيرة للـ system/controllers + Karpenter للـ workloads (ده اللي الستاك بيعمله لما `enable_karpenter = true` — [6A](6A-hpa-karpenter-under-load.md)).

</details>

<details><summary>Standard ولا Extended support؟</summary>

كل Kubernetes minor ليه ~14 شهر standard support، وبعدها extended (~12 شهر) بسعر $0.60/ساعة بدل $0.10. لو الـ policy = Standard، EKS بيعمل upgrade لوحده آخر الـ standard. الصح: جدول upgrades منتظم (كل minor أو اتنين)، وتستخدم Extended كشبكة أمان مؤقتة بس.

</details>

## 13) Checklist

- [ ] عملت الـ VPC (من غير NAT) والـ roles والـ cluster والـ node group من الـ Console
- [ ] ضفت access entry للـ deploy role وفهمت ليه cluster scope
- [ ] عملت نفس الـ cluster بـ `eksctl` من ملف واحد (و `--dry-run`)
- [ ] نشرت التطبيق بالـ chart (EBS CSI + gp3 + lab MySQL) ووصلت له بـ port-forward
- [ ] فهمت Pod Identity و Auto Mode وإمتى أختار كل data plane
- [ ] جرّبت الـ break-it (CIDR، access entry، PVC Pending)
- [ ] مسحت كل حاجة واتأكدت إن مفيش EBS volumes أو CloudFormation stacks فاضلة
