# 62 — EKS بـ Terraform

> **الهدف في سطر:** تعمل apply للستاك [`infra/terraform/stacks/60-eks`](../../../infra/terraform/stacks/60-eks/README.md) وتفهمه ملف بـ ملف: VPC من غير NAT، EKS (module v21) بـ managed node group (**On-Demand أو Spot**)، add-ons (VPC CNI بـ network policy + prefix delegation، Pod Identity Agent، metrics-server)، access entries (منهم الـ GitHub deploy role)، Pod Identity للـ LBC و ESO، RDS + SSM، والـ Helm add-ons في **apply تاني** — من جهازك ومن GitHub Actions — وتعرف مكان **EKS Auto Mode** في الصورة.
> **المستوى:** Intermediate → Advanced · **الوقت:** ~4 ساعات (~15–20 دقيقة apply) · **التكلفة التقريبية:** ~$5.5/يوم بالـ defaults (تقريبي — راجع صفحة الأسعار)
> **بيعتمد على:** [61 — EKS من الـ Console و eksctl](61-eks-console-eksctl.md) · [30](30-ci-github-actions.md) (bootstrap + الـ deploy role) · [41 — RDS](41-rds-mysql.md) · [90 — Terraform بالتفصيل](90-terraform-deep-dive.md) · **الملفات في الـ repo:** [`main.tf`](../../../infra/terraform/stacks/60-eks/main.tf) · [`variables.tf`](../../../infra/terraform/stacks/60-eks/variables.tf) · [`addons.tf`](../../../infra/terraform/stacks/60-eks/addons.tf) · [`pod-identity.tf`](../../../infra/terraform/stacks/60-eks/pod-identity.tf) · [`ssm.tf`](../../../infra/terraform/stacks/60-eks/ssm.tf) · [`outputs.tf`](../../../infra/terraform/stacks/60-eks/outputs.tf) · [`providers.tf`](../../../infra/terraform/stacks/60-eks/providers.tf) · [`terraform.tfvars.example`](../../../infra/terraform/stacks/60-eks/terraform.tfvars.example) · [`infra/terraform/README.md`](../../../infra/terraform/README.md) · [`.github/workflows/terraform.yml`](../../../.github/workflows/terraform.yml)

## 1) الفكرة (Concepts)

في [61](61-eks-console-eksctl.md) عملت كل حاجة بإيدك (أو بـ eksctl اللي بيعمل CloudFormation). هنا نفس الـ cluster **declarative** مع `plan` و state و drift detection، وكل الحاجات اللي حوالين الـ cluster في نفس المكان: الـ IAM roles للـ controllers، الـ RDS، والـ SSM parameters اللي ESO هيقراها.

| المصطلح | المعنى |
|---|---|
| `terraform-aws-modules/vpc` `~> 6.8` / `eks` `~> 21.30` | الـ modules الرسمية للمجتمع؛ v21 غيّرت أسماء الـ inputs (`name`، `kubernetes_version`، `endpoint_public_access`، `addons`) |
| Two-phase apply | الـ `helm` provider محتاج cluster موجود يكلّمه → apply أول للـ cluster، وتاني بـ `install_addons = true` |
| `enable_cluster_creator_admin_permissions` | الـ identity اللي بتعمل apply تبقى cluster admin (access entry) — الـ helm provider محتاجها |
| `grant_github_deploy_role` | (default **true**) access entry بـ `AmazonEKSClusterAdminPolicy` للـ role `student-app-gha-deploy` اللي [`deploy-eks.yml`](../../../.github/workflows/deploy-eks.yml) بيستخدمه |
| `enable_irsa = false` | Pod Identity بدل IRSA — من غير OIDC provider |
| `upgrade_policy = { support_type = "STANDARD" }` | upgrade تلقائي آخر الـ standard support بدل extended (6× السعر) |
| `node_capacity_type` | `ON_DEMAND` أو `SPOT` (validation في `variables.tf`) |
| One owner per add-on | add-on واحد = owner واحد: Terraform (`install_addons`) **أو** Argo CD app-of-apps ([69](69-gitops-argocd.md)) |

**ليه الستاك مش بيقرا state ستاك تاني؟** ([`infra/terraform/README.md`](../../../infra/terraform/README.md)) `terraform_remote_state` بيربط الـ lifecycles. هنا الأسماء deterministic (`student-app-lab-*`)، والـ config في SSM `/student-app/<env>/app/*`، والـ role ARNs من bootstrap outputs → GitHub variables.

## 2) المعمارية (Architecture)

```text
 terraform apply #1 (install_addons = false)
 ├─ module.vpc            10.60.0.0/16، 2 AZs، public /20 (role/elb) + private /20 (role/internal-elb)
 │                        enable_nat=false → nodes في الـ public subnets بـ public IP
 ├─ module.eks            student-app-lab، 1.36، STANDARD، endpoint public(CIDRs)+private، KMS secrets encryption
 │   ├─ access_entries    creator (admin) + cluster_admin_principal_arns + student-app-gha-deploy (grant_github_deploy_role)
 │   ├─ addons            vpc-cni{enableNetworkPolicy, prefix delegation} · coredns · kube-proxy
 │   │                    eks-pod-identity-agent (before_compute) · metrics-server
 │   └─ MNG "default"     AL2023، t3.medium × 2 (2..4)، ON_DEMAND|SPOT، SSM policy، label student-app/pool=default
 ├─ pod-identity.tf       role LBC (policy رسمية v3.6.3) → kube-system/aws-load-balancer-controller
 │                        role ESO (ssm:Get* على /student-app/lab/app/* + kms:Decrypt via SSM) → external-secrets/external-secrets
 ├─ module.rds            MySQL 8.4 db.t4g.micro في الـ private subnets، SG يسمح للـ node SG، يكتب DB_* في SSM
 ├─ ssm.tf                APP_URL، DB_CONNECTION، SESSION_DRIVER، CACHE_STORE، SRE_LAB_ENABLED، METRICS_ENABLED
 │                        + SecureString: APP_KEY، SRE_LAB_TOKEN
 └─ module.observability  RDS alarms + dashboard (ALB alarms off: الـ ALB ملك الـ controller)

 terraform apply #2 (install_addons = true)  ── helm provider (aws eks get-token) ──►
   aws-load-balancer-controller 3.6.3 · external-secrets 2.15.0 · argo-rollouts 2.43.12
   [argo-cd 10.18.2] · [kube-prometheus-stack 93.6.1 + observability/k8s/kube-prometheus-stack-values.yaml]
   [karpenter 1.15.3 + module.karpenter (IAM، SQS interruption queue)]   ← enable_karpenter

 outputs ──► cluster_name (→ repo variable EKS_CLUSTER) · update_kubeconfig · vpc_id · ssm_prefix
             pod_identity_roles · karpenter · cluster_secret_store_manifest
```

## 3) المتطلبات (Prerequisites)

- [ ] الـ **bootstrap** اتعمله apply ([30](30-ci-github-actions.md)): الـ state bucket، و `infra/terraform/backend.hcl` (من `backend.hcl.example`)، والـ role `student-app-gha-deploy` **موجود** — وإلا `grant_github_deploy_role = true` (الافتراضي) هيفشّل الـ access entry. لو مش عايزه: `grant_github_deploy_role = false`.
- [ ] Terraform `>= 1.10`، AWS CLI v2 (الـ helm provider بيستدعي `aws eks get-token`)، `kubectl`، `helm`.
- [ ] مفيش ستاك تاني (20/40/50) شغال على نفس الـ `env` — كلهم بيكتبوا `/student-app/lab/app/*` ([`ssm.tf`](../../../infra/terraform/stacks/60-eks/ssm.tf)). لو لازم: `-var env=lab2`.
- [ ] شيلت الـ cluster بتاع [61](61-eks-console-eksctl.md) (أو مستعد تدفع للاتنين).

## 4) الطريقة الأولى: AWS Console — اتفرّج على اللي Terraform عمله (+ GitHub UI)

مفيش إنشاء يدوي هنا — بس افتح الـ Console بعد الـ apply وقارن بـ [61](61-eks-console-eksctl.md):

1. **EKS → Clusters → student-app-lab → Overview**: version 1.36، **Upgrade policy: Standard**، Secrets encryption: KMS.
2. **Access → IAM access entries**: الـ creator + `student-app-gha-deploy` (+ أي `cluster_admin_principal_arns`). **Pod Identity associations**: `kube-system/aws-load-balancer-controller` و `external-secrets/external-secrets` (+ `kube-system/karpenter` لو مفعّل).
3. **Add-ons**: 5 add-ons؛ افتح **Amazon VPC CNI → Advanced configuration** وشوف الـ JSON (`enableNetworkPolicy`، `ENABLE_PREFIX_DELEGATION`).
4. **Compute → default**: Capacity type، instance types، labels.
5. **Systems Manager → Parameter Store** → فلتر `/student-app/lab/app/` → الـ parameters من `ssm.tf` ومن الـ RDS module.

**من GitHub (من غير جهازك):** **Actions → Terraform → Run workflow** → stack `60-eks` → action `plan` ثم `apply` (الـ apply ورا environment `lab` والـ admin role — [92](92-terraform-in-ci.md)). الـ CI بيطبّق الـ **defaults** (مفيش `terraform.tfvars` في git): `install_addons = false`، والـ endpoint `0.0.0.0/0` (الـ GitHub runners IPs متغيرة).

## 5) الطريقة التانية: Infrastructure as Code — الستاك ملف بـ ملف

### 5.1 الـ variables اللي تهمك

| Variable | Default | ليه |
|---|---|---|
| `vpc_cidr` | `10.60.0.0/16` | /16 لأن كل pod بياخد IP من الـ VPC؛ و`values-eks.yaml` بيقفل الـ DB egress على نفس الـ CIDR |
| `enable_nat` | `false` | true = nodes في private subnets ورا NAT واحدة (~$32/شهر + data) — الـ production layout |
| `kubernetes_version` | `1.36` | standard support لحد أغسطس 2027 حسب وصف المتغير (1.34–1.37 في الـ standard support، نوفمبر 2026) |
| `cluster_endpoint_public_access_cidrs` | `["0.0.0.0/0"]` | **حط IP/32 بتاعك** من جهازك؛ الـ CI محتاج مفتوح |
| `cluster_admin_principal_arns` | `[]` | الـ SSO role بتاعك لو بتبدّل بين الـ CI وجهازك (§8) |
| `grant_github_deploy_role` | `true` | access entry للـ `<project>-gha-deploy` |
| `node_instance_types` / `node_capacity_type` | `["t3.medium"]` / `ON_DEMAND` | Spot = نوّع الـ types |
| `node_min_size` / `max` / `desired` | 2 / 4 / 2 | |
| `enable_karpenter` | `false` | IAM/SQS + chart (لو `install_addons`) — [6A](6A-hpa-karpenter-under-load.md) |
| `install_addons` | `false` | الـ Helm releases — **apply تاني** |
| `addons` | LBC/ESO/Rollouts = true، Argo CD/kube-prometheus-stack = false | الاتنين الأخيرين تقال على 2 × t3.medium |
| `chart_versions` | pinned (Nov 2026) | bump واحد واحد |
| `app_url` | `http://localhost` | **بيتكتب في SSM و بيكسب على `config.APP_URL` في الـ chart** (الـ Secret بييجي بعد الـ ConfigMap في `envFrom`) — حدّثه بالـ ALB hostname ([63](63-eks-load-balancer-controller-ingress.md)) |

### 5.2 [`main.tf`](../../../infra/terraform/stacks/60-eks/main.tf)

- **VPC:** `public_subnets = cidrsubnet(vpc_cidr, 4, i)` و `private_subnets = cidrsubnet(vpc_cidr, 4, i + 8)` → `/20` (مساحة للـ /28 prefixes). `map_public_ip_on_launch = !var.enable_nat`. الـ subnet tags للـ LBC، و `karpenter.sh/discovery` على الـ node subnets لو Karpenter مفعّل.
- **EKS:** `endpoint_public_access = true` (v21 الافتراضي false)، `endpoint_private_access = true`، logs `api/audit/authenticator` بـ retention 7 أيام، KMS deletion window 7 أيام. `subnet_ids = local.node_subnet_ids` (public أو private حسب الـ NAT)، و `control_plane_subnet_ids = module.vpc.private_subnets`.
- **access_entries:** `for i, arn in local.cluster_admins` — `local.cluster_admins = distinct(concat(var.cluster_admin_principal_arns, grant ? [role/<project>-gha-deploy] : []))`، كل واحد بـ `AmazonEKSClusterAdminPolicy` و scope `cluster`. ليه cluster scope؟ الـ deploy role بيعمل الـ Namespace والـ `ClusterSecretStore`.
- **addons:** `vpc-cni` بـ `before_compute = true` (لازم قبل الـ nodes عشان الـ config يتطبق من أول pod) و `configuration_values` = `enableNetworkPolicy = "true"` + `ENABLE_PREFIX_DELEGATION`/`WARM_PREFIX_TARGET`؛ `eks-pod-identity-agent` بـ `before_compute`؛ و `metrics-server` (community add-on — الـ HPA في [6A](6A-hpa-karpenter-under-load.md)).
- **MNG `default`:** `AL2023_x86_64_STANDARD`، `capacity_type = var.node_capacity_type`، `AmazonSSMManagedInstanceCore` (shell من غير SSH)، label `student-app/pool=default` + `karpenter.sh/controller=true` لو Karpenter (الـ controller بيتحط على nodes مش بيديرها هو).
- **RDS:** `allowed_security_group_ids = [module.eks.node_security_group_id]` — الـ pods بتستخدم الـ node SG (مفيش security groups for pods)، فـ "أي pod" على الـ nodes يوصل للـ RDS من ناحية الـ SG، والـ NetworkPolicy هي اللي بتضيّق.

### 5.3 [`pod-identity.tf`](../../../infra/terraform/stacks/60-eks/pod-identity.tf) و [`ssm.tf`](../../../infra/terraform/stacks/60-eks/ssm.tf)

- Trust واحد لكل الـ roles: `pods.eks.amazonaws.com` بـ `sts:AssumeRole` + `sts:TagSession`.
- **LBC:** الـ policy الرسمية v3.6.3 **من غير تعديل** في [`policies/`](../../../infra/terraform/stacks/60-eks/policies/aws-load-balancer-controller-iam-policy.json) (أسهل في الـ diff وقت الـ upgrade).
- **ESO:** `ssm:GetParameter/GetParameters/GetParametersByPath` على `/student-app/lab/app` و `/*` بس (مش mysql ولا deploy ولا env تاني) + `ssm:DescribeParameters` (`*`، مش resource-scopable) + `kms:Decrypt` بشرط `kms:ViaService = ssm.<region>.amazonaws.com`.
- **SSM:** الستاك بيملك `APP_KEY` (random 32 bytes)، `SRE_LAB_TOKEN` (SecureString)، و `APP_URL`/`DB_CONNECTION`/`SESSION_DRIVER`/`CACHE_STORE`/`SRE_LAB_ENABLED`/`METRICS_ENABLED`؛ الـ RDS module بيملك `DB_HOST/PORT/DATABASE/USERNAME/PASSWORD`. التفاصيل في [64](64-eks-external-secrets.md).

> 🔐 الـ state فيه `APP_KEY` وباسورد الـ RDS. access للـ state bucket = access للأسرار ([`infra/terraform/README.md`](../../../infra/terraform/README.md) §State).

### 5.4 [`addons.tf`](../../../infra/terraform/stacks/60-eks/addons.tf) — الـ apply التاني

`local.helm.<x> = var.install_addons && var.addons.<x>`. كل release بـ version من `var.chart_versions`:

| Release | Namespace | Values مهمة |
|---|---|---|
| `aws-load-balancer-controller` | `kube-system` | `clusterName`، `region`، `vpcId` صريحين (IMDS hop limit 1 بيمنع الـ pods من الـ metadata)، `replicaCount = 1`، الـ SA name من الـ association |
| `external-secrets` | `external-secrets` | `installCRDs = true`، SA `external-secrets` |
| `argo-rollouts` | `argo-rollouts` | `dashboard.enabled = true` |
| `argo-cd` | `argocd` | `dex` و `notifications` off، `server.insecure = true` |
| `kube-prometheus-stack` | `monitoring` | **`file(observability/k8s/kube-prometheus-stack-values.yaml)`** أولاً (فيه الـ PodMonitor اللي الـ canary analysis معتمد عليه — [68](68-k8s-canary-argo-rollouts.md)) + overrides (`retention = "2d"`، الـ selectors من أي namespace)، `timeout = 900` |
| `karpenter` | `kube-system` | `nodeSelector karpenter.sh/controller=true`، `interruptionQueue`، `webhook.enabled = false` |

### 5.5 Spot و node groups

```hcl
# terraform.tfvars
node_instance_types = ["t3.medium", "t3a.medium"]   # تنويع = احتمال أقل لنفاد الـ Spot capacity
node_capacity_type  = "SPOT"
```

- الـ **capacity type** بتاع managed node group **مش بيتغير in-place** → الـ plan هيقول إن الـ node group **must be replaced**: nodes جديدة ونقل الـ pods. اقرا الـ plan، وخلي الـ PDB والـ 2 replicas على AZs مختلفة يحموا التطبيق ([66](66-k8s-rolling-recreate.md)).
- Spot = خصم كبير (عادةً 60–70%) مقابل **interruption بإنذار دقيقتين**. الـ MNG بيستخدم allocation strategy مناسبة للـ capacity وبيستجيب لـ rebalance recommendations بإنه يجيب node بديلة بدري.
- **الطريقة الـ Senior** (تعديل منك، مش في الـ repo): node group صغيرة On-Demand للـ system/controllers (CoreDNS، LBC، Karpenter) + node group (أو Karpenter NodePool) Spot للـ workloads الـ stateless. مثال لإضافة تانية جوه `eks_managed_node_groups`:

```hcl
spot = {
  ami_type       = "AL2023_x86_64_STANDARD"
  instance_types = ["t3.medium", "t3a.medium", "t3.large"]
  capacity_type  = "SPOT"
  min_size       = 0
  max_size       = 4
  desired_size   = 1
  subnet_ids     = local.node_subnet_ids
  labels         = { "student-app/pool" = "spot" }
}
```

### 5.6 ملاحظة: EKS Auto Mode في Terraform

الـ eks module بيدعم Auto Mode (input للـ compute config بـ node pools `general-purpose`/`system` — اتأكد من الاسم في README الـ module للإصدار اللي عندك). لو فعّلته: مفيش MNG ولا Karpenter ولا LBC helm release (الـ platform بيعملهم)، والـ IngressClass بيبقى `eks.amazonaws.com/alb`. الستاك بتاعنا مختار يعمل الأجزاء دي صريحة عشان تتعلمها ([61 §5.3](61-eks-console-eksctl.md)).

## 6) الـ Deploy

### 6.1 من جهازك

```bash
cd infra/terraform/stacks/60-eks
cp terraform.tfvars.example terraform.tfvars
# عدّل: cluster_endpoint_public_access_cidrs = ["<MY_IP>/32"]
#       cluster_admin_principal_arns = ["arn:aws:iam::<ACCOUNT_ID>:role/<YOUR_SSO_ROLE>"]   (اختياري، §8)
terraform init -backend-config=../../backend.hcl
terraform plan -out=tfplan
terraform apply tfplan                                   # ~15 دقيقة (cluster + nodes + RDS)

eval "$(terraform output -raw update_kubeconfig)"
kubectl get nodes -o wide
```

**الـ apply التاني** — حط الـ toggle **في `terraform.tfvars`** مش `-var` (§8 ليه):

```hcl
# terraform.tfvars
install_addons = true
addons = {
  aws_load_balancer_controller = true
  external_secrets             = true
  argo_rollouts                = true
  argo_cd                      = false   # 69 — أو Argo CD يملك كل الـ add-ons (one owner)
  kube_prometheus_stack        = false   # 68 — محتاجه للـ canary analysis على EKS
}
```

```bash
terraform plan -out=tfplan && terraform apply tfplan
helm list -A
gh variable set EKS_CLUSTER --body "$(terraform output -raw cluster_name)"
```

### 6.2 من GitHub Actions

```bash
gh workflow run terraform.yml -f stack=60-eks -f action=plan
gh workflow run terraform.yml -f stack=60-eks -f action=apply     # بيستنى موافقة environment "lab" لو عليه reviewer
gh run watch
```

## 7) التحقق (Verify)

```bash
terraform output
aws eks describe-cluster --name student-app-lab --query 'cluster.{v:version,status:status,upgrade:upgradePolicy.supportType,auth:accessConfig.authenticationMode}'
aws eks list-access-entries --cluster-name student-app-lab
aws eks list-pod-identity-associations --cluster-name student-app-lab \
  --query 'associations[].{ns:namespace,sa:serviceAccount}' --output table
aws eks describe-addon --cluster-name student-app-lab --addon-name vpc-cni --query addon.configurationValues --output text
aws ssm get-parameters-by-path --path /student-app/lab/app --query 'Parameters[].Name'
kubectl get nodes -L eks.amazonaws.com/capacityType,student-app/pool,topology.kubernetes.io/zone
kubectl get pods -A
kubectl top nodes
```

وجرّب الـ deploy role بالظبط زي `deploy-eks.yml` (step "kubeconfig for the cluster"):

```bash
gh workflow run deploy-eks.yml -f image_tag=<GIT_SHA> -f mode=helm      # [65]
```

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر | المتوقع |
|---|---|---|
| نسيت الـ toggle | بعد apply بـ `-var install_addons=true`، اعمل `terraform plan` عادي | الـ plan بيقول **destroy** لكل `helm_release` — عشان كده الـ toggle في الـ tfvars. اقرا كل plan |
| CI مقابل laptop | apply من الـ CI بعد apply من جهازك | الـ creator access entry بيتغيّر لـ role الـ CI (و الـ CI مش شايف tfvars → `install_addons = false` → add-ons هتتشال). الحل: الـ SSO role في `cluster_admin_principal_arns`، والـ tfvars مصدر واحد |
| الـ deploy role مش موجود | `grant_github_deploy_role = true` من غير bootstrap | الـ apply بيفشل في إنشاء الـ access entry (principal مش موجود) |
| الـ CIDR بيقفل نفسك | `cluster_endpoint_public_access_cidrs = ["203.0.113.1/32"]` ثم `install_addons = true` | الـ helm provider مش قادر يوصل للـ API (timeout) |
| Spot | `node_capacity_type = "SPOT"` | plan: node group replacement؛ تابع `kubectl get nodes -w` و `probe.sh` على الـ ALB — مع PDB و 2 replicas المفروض 0 failures |
| Destroy مع Ingress | `terraform destroy` والـ Ingress لسه موجود | الـ VPC بيفشل يتمسح (`DependencyViolation`): الـ ALB والـ SGs اتعملوا من الـ controller برا Terraform |
| Drift | من الـ Console غيّر الـ node group max size | `terraform plan` بيورّيك الفرق ويرجّعه — [91](91-terraform-import-and-drift.md) |

## 9) الرجوع (Rollback)

- **Config:** `git revert` للتعديل → `plan` → `apply`. الـ state bucket versioned (90 يوم) كـ undo button للـ state نفسه.
- **Kubernetes version:** upgrade بس (مفيش downgrade). خطوة minor واحدة: `kubernetes_version = "1.37"` → الـ control plane، وبعدين الـ add-ons والـ node group (AMI جديدة بـ rolling replace).
- **Spot مسبب مشاكل:** رجّع `node_capacity_type = "ON_DEMAND"` → replacement تاني.
- **Add-on بايظ بعد bump:** رجّع `chart_versions.<x>` للـ version القديمة → apply.

## 10) المسح (Teardown) ⚠️

```bash
# 1) اللي الـ controllers عملوه برا Terraform الأول
kubectl delete ingress --all -A                     # ALBs + target groups + SGs (LBC)
kubectl delete svc -A --field-selector spec.type=LoadBalancer
helm -n student-app uninstall student-app 2>/dev/null; kubectl delete ns student-app --ignore-not-found
kubectl get nodeclaims 2>/dev/null                   # Karpenter: امسح الـ NodePools (kubectl delete nodepools --all) واستنى الـ nodes تمشي

# 2) الستاك
cd infra/terraform/stacks/60-eks
terraform destroy
```

اتأكد إن مفيش حاجة فاضلة:

```bash
aws resourcegroupstaggingapi get-resources --tag-filters Key=Project,Values=student-app --query 'ResourceTagMappingList[].ResourceARN'
aws elbv2 describe-load-balancers --query "LoadBalancers[?starts_with(LoadBalancerName,'k8s-') || starts_with(LoadBalancerName,'student-app')].LoadBalancerName"
aws ec2 describe-volumes --filters Name=status,Values=available --query 'Volumes[].VolumeId'
aws ec2 describe-instances --filters Name=tag:karpenter.sh/nodepool,Values=* Name=instance-state-name,Values=running --query 'Reservations[].Instances[].InstanceId'
```

## 11) التكلفة (Cost)

| Resource | السعر التقريبي (us-east-1 — تقريبي، راجع صفحة الأسعار) |
|---|---|
| EKS control plane (standard support) | $0.10/ساعة |
| 2 × t3.medium On-Demand | ~$0.083/ساعة (Spot ≈ $0.03 للاتنين) |
| EBS 2 × 20 GiB gp3 + 2 public IPv4 | ~$0.015/ساعة |
| RDS db.t4g.micro + 20 GiB | ~$0.019/ساعة |
| KMS key + control-plane logs + alarms | ~$0.01/ساعة |
| **الإجمالي (defaults)** | **≈ $0.23/ساعة ≈ $5.5/يوم** ([README الستاك](../../../infra/terraform/stacks/60-eks/README.md)) |
| + ALB من الـ controller | ~$0.0225/ساعة + LCU |
| + `enable_nat = true` | ~$0.045/ساعة + data processing |
| + kube-prometheus-stack / Argo CD | غالباً محتاج node تالتة (~$0.04/ساعة) |

## 12) أسئلة Interview

<details><summary>ليه الـ add-ons في apply تاني؟ مش ينفع كله مرة واحدة؟</summary>

الـ `helm` provider بيتعمله configure بـ `module.eks.cluster_endpoint` والـ CA — قيم مش معروفة وقت الـ plan الأول، والـ provider configuration مينفعش تعتمد على resources لسه متعملتش بشكل موثوق (الـ plan ممكن يفشل أو يتصرف غلط). الحلول: two-phase apply (اللي عملناه بـ toggle)، أو ستاكين منفصلين (cluster / platform)، أو GitOps (Argo CD بيركّب الـ add-ons — [69](69-gitops-argocd.md)). في الـ production الفصل لستاكين أنضف.

</details>

<details><summary>EKS managed add-on ولا `helm_release` ولا Argo CD؟</summary>

Managed add-on: AWS بتختبر التوافق مع الـ version وفيه `configuration_values` و Pod Identity integration — ممتاز للـ core (CNI، CoreDNS، kube-proxy، EBS CSI، metrics-server). `helm_release`: أي chart، بس Terraform مش بيصلّح drift جوه الـ cluster إلا في الـ apply الجاي. Argo CD: reconciliation مستمر و self-heal و UI. القاعدة الوحيدة الإجبارية: **owner واحد لكل add-on**، وإلا اتنين controllers بيصلّحوا نفس الـ release للأبد.

</details>

<details><summary>إزاي تعمل upgrade لـ EKS بـ Terraform من غير downtime؟</summary>

اقرا الـ deprecated APIs (kubent/pluto أو insights بتاعة EKS)، حدّث الـ charts. bump `kubernetes_version` minor واحدة → الـ control plane in-place (الـ API ممكن يرجع errors لحظية للـ clients)، بعدين الـ add-ons، بعدين الـ node groups (rolling replace بيحترم الـ PDB — أو blue/green node groups). الـ app لازم يكون عنده PDB و ≥ 2 replicas على AZs مختلفة وreadiness صح. والـ `upgrade_policy STANDARD` بيضمن إنك متتحاسبش extended بالغلط.

</details>

<details><summary>مين "cluster creator" وليه ده مهم في الـ automation؟</summary>

`enable_cluster_creator_admin_permissions` بيعمل access entry للـ identity اللي بتعمل apply. لو بتبدّل بين laptop (SSO role) و CI (terraform role)، الـ entry ده بيتغيّر مع كل apply من مكان مختلف — وممكن تقفل الطرف التاني برا. الحل: كل الـ admins الدائمين صريحين في `cluster_admin_principal_arns`، والـ applies من مكان واحد (CI) في الـ production.

</details>

<details><summary>Spot على EKS — إيه اللي لازم يكون موجود؟</summary>

workloads stateless بـ replicas ≥ 2 و PDB و topology spread، graceful shutdown أقل من الـ 2 دقيقة (preStop + grace 40s عندنا)، تنويع instance types/AZs، ومعالجة الـ interruption (الـ MNG بيعمل drain؛ Karpenter بـ SQS interruption queue). الـ controllers والـ stateful على On-Demand. وراقب الـ interruption rate.

</details>

<details><summary>الـ pods بتستخدم الـ node SG في الوصول للـ RDS — إيه المشكلة؟</summary>

أي pod على أي node يعدّي الـ SG للـ RDS، فالـ SG مش بيفرّق بين التطبيق و pod تاني مخترق. الطبقة التانية: NetworkPolicy (egress 3306 للتطبيق بس على الـ VPC CIDR) + DB credentials منفصلة. البديل الأدق: Security Groups for Pods (branch ENIs) أو RDS IAM auth.

</details>

## 13) Checklist

- [ ] قريت `main.tf` و `addons.tf` و `pod-identity.tf` و `ssm.tf` وعارف كل block بيعمل إيه
- [ ] عملت apply أول (cluster) وتاني (add-ons) والـ toggle في الـ tfvars
- [ ] اتأكدت من الـ access entries والـ Pod Identity associations والـ VPC CNI config من الـ Console
- [ ] جرّبت Spot وفهمت الـ node group replacement
- [ ] (اختياري) عملت plan/apply من `terraform.yml`
- [ ] عملت teardown بالترتيب الصح (Ingress الأول) واتأكدت إن مفيش ALB/EBS فاضل
