# G — Kubernetes / EKS (60–6A) — كروت الملخص

> كارت لكل سيناريو. التفاصيل في [`../scenarios/`](../scenarios/60-kubernetes-on-kind.md)، والعقد في [CONVENTIONS §8](../CONVENTIONS.md).

### 60 — Kubernetes محلي على kind (أو على GitHub Actions)
**الهدف:** تفهم الـ objects (Namespace، ConfigMap/Secret، Deployment، Service، StatefulSet، Job، HPA، PDB، NetworkPolicy) بالتطبيق كمثال، plain YAML + kustomize ثم الـ chart، وتقرا `k8s-integration.yml`.
**أهم الأوامر:**
```bash
gh workflow run k8s-integration.yml --ref devops-lab && gh run watch
kind create cluster --config k8s/kind/cluster.yaml
kind load docker-image student-app:ci-v1 student-app:ci-v2 --name student-app-lab
kubectl apply -f k8s/manifests/base/namespace.yaml -f k8s/kind/mysql.yaml
kubectl apply -k k8s/manifests/overlays/kind
helm upgrade --install student-app k8s/helm/student-app -n student-app -f k8s/helm/student-app/values-kind.yaml --set-string image.tag=ci-v1 --wait
curl -s localhost:8088/ready
kind delete cluster --name student-app-lab
```
**التحقق:** `/ready` = `"status":"ready"`، `/login` = 200 (الـ migration hook اشتغل)، و probe الـ RollingUpdate في الـ CI Summary = `failed : 0`.
**Gotchas:**
- الـ plain migrate Job immutable وبيتعمل مع الـ Deployment — استنى `job/student-app-migrate` وامسحه قبل الـ release الجاي.
- `kubectl delete -k` على الـ overlay بيمسح الـ Namespace (و MySQL والـ Secret).
- patch الـ NodePort من غير `protocol: TCP` بيقع بصمت.
**التكلفة:** مجاني.

### 61 — EKS من الـ Console و eksctl
**الهدف:** cluster بإيدك مرتين (Console Custom configuration + `eksctl` ClusterConfig)، access entries، add-ons، Pod Identity، وتعرف Auto Mode.
**أهم الأوامر:**
```bash
eksctl create cluster -f /tmp/eksctl-61.yaml --dry-run
eksctl create cluster -f /tmp/eksctl-61.yaml
aws eks update-kubeconfig --region us-east-1 --name student-app-lab-console --alias console
aws eks create-access-entry --cluster-name <CLUSTER> --principal-arn arn:aws:iam::<ACCOUNT_ID>:role/student-app-gha-deploy
aws eks associate-access-policy --cluster-name <CLUSTER> --principal-arn arn:aws:iam::<ACCOUNT_ID>:role/student-app-gha-deploy --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy --access-scope type=cluster
kubectl get nodes -o wide && kubectl get pods -A
helm upgrade --install student-app k8s/helm/student-app -n student-app -f /tmp/values-61.yaml --set-string image.tag=<GIT_SHA> --wait
eksctl delete cluster -f /tmp/eksctl-61.yaml --disable-nodegroup-eviction --wait
```
**التحقق:** الـ cluster `ACTIVE` بـ auth `API` والـ endpoint على IP/32 بتاعك، 2 nodes على AZs مختلفة، والـ pod IPs من `10.60.x.x`.
**Gotchas:**
- eksctl بيعمل NAT gateway افتراضياً — `vpc.nat.gateway: Disable`.
- الـ public subnets لازم auto-assign public IP وإلا الـ nodes مبتعملش join.
- PVC للـ MySQL محتاج EBS CSI add-on + StorageClass default (gp2 مش default في الـ clusters الجديدة).
**التكلفة:** ~$0.20/ساعة (~$4.5–5/يوم) لكل cluster؛ extended support $0.60/ساعة.

### 62 — EKS بـ Terraform
**الهدف:** الستاك `60-eks`: VPC من غير NAT، EKS v21، MNG On-Demand/Spot، add-ons، access entries، Pod Identity، RDS + SSM، والـ Helm add-ons في apply تاني.
**أهم الأوامر:**
```bash
cd infra/terraform/stacks/60-eks && cp terraform.tfvars.example terraform.tfvars
terraform init -backend-config=../../backend.hcl
terraform plan -out=tfplan && terraform apply tfplan
eval "$(terraform output -raw update_kubeconfig)" && kubectl get nodes
# terraform.tfvars: install_addons = true  (+ addons = {...})
terraform plan -out=tfplan && terraform apply tfplan && helm list -A
gh variable set EKS_CLUSTER --body "$(terraform output -raw cluster_name)"
kubectl delete ingress --all -A && terraform destroy
```
**التحقق:** `aws eks list-access-entries` فيه الـ deploy role، `list-pod-identity-associations` فيه LBC و ESO، والـ VPC CNI config فيه `enableNetworkPolicy`.
**Gotchas:**
- `install_addons` في الـ tfvars مش `-var` — apply من غيره بيمسح كل الـ helm releases.
- `grant_github_deploy_role` (default true) بيفشل لو الـ bootstrap role مش موجود؛ والـ creator admin بيتغيّر لو بدّلت بين laptop و CI.
- الـ Spot بيعمل replace للـ node group؛ امسح الـ Ingress قبل الـ destroy.
**التكلفة:** ≈ $0.23/ساعة (~$5.5/يوم) + ALB ~$0.0225/ساعة + NAT لو اتفعّل.

### 63 — AWS Load Balancer Controller + Ingress + ACM
**الهدف:** Ingress بـ class `alb` → ALB (target-type ip، health `/ready`، `/metrics` 404 من الـ ALB، readiness gates)، HTTPS بـ ACM، وفكرة ExternalDNS.
**أهم الأوامر:**
```bash
kubectl label namespace student-app elbv2.k8s.aws/pod-readiness-gate-inject=enabled --overwrite
helm upgrade --install student-app k8s/helm/student-app -n student-app -f k8s/helm/student-app/values-eks.yaml --set-string image.repository=<REGISTRY>/student-app --set-string image.tag=<GIT_SHA> --set rollout.enabled=false --wait --rollback-on-failure
ALB=$(kubectl -n student-app get ingress student-app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -s "http://$ALB/ready"; curl -sI "http://$ALB/metrics" | head -3
kubectl -n student-app get pods -o wide && kubectl -n student-app get targetgroupbindings
aws elbv2 describe-target-health --target-group-arn <TG_ARN>
helm upgrade ... -f /tmp/values-https.yaml     # certificate-arn + listen-ports + ssl-redirect
kubectl -n student-app delete ingress student-app
```
**التحقق:** الـ targets = pod IPs `healthy`، `READINESS GATES 1/1`، و `/metrics` = 404 بـ `Server: awselb/2.0`.
**Gotchas:**
- label الـ readiness gate لازم قبل إنشاء الـ pods.
- `APP_URL` من SSM بيكسب على `config.APP_URL` — غيّره من `app_url` في Terraform.
- امسح الـ Ingress قبل `terraform destroy` وإلا الـ VPC مش هيتمسح.
**التكلفة:** ALB ~$0.0225/ساعة + LCU؛ ACM مجاني؛ Route 53 zone ~$0.50/شهر.

### 64 — External Secrets + SSM Parameter Store
**الهدف:** ESO بـ Pod Identity يحوّل `/student-app/lab/app/*` لـ Secret `student-app-secrets`، بـ 3 أشكال للـ store، و rotation.
**أهم الأوامر:**
```bash
aws ssm get-parameters-by-path --path /student-app/lab/app --query 'Parameters[].Name'
kubectl get clustersecretstore
kubectl -n student-app get externalsecret student-app-secrets
kubectl -n student-app get secret student-app-secrets -o json | jq -r '.data | keys[]'
terraform -chdir=infra/terraform/stacks/60-eks output -raw cluster_secret_store_manifest | kubectl apply -f -
aws ssm put-parameter --name /student-app/lab/app/<KEY> --type SecureString --overwrite --value '<VALUE>'
kubectl -n student-app annotate externalsecret student-app-secrets force-sync="$(date +%s)" --overwrite
kubectl -n student-app rollout restart deploy/student-app
```
**التحقق:** الـ store `Valid`، الـ ExternalSecret `SecretSynced`، والـ keys في الـ Secret = أسماء الـ parameters.
**Gotchas:**
- الـ env بيتقري وقت الـ start بس — rotation = force-sync + restart.
- الـ Secret بيكسب على الـ ConfigMap (`DB_HOST`، `APP_URL`).
- مع ESO الـ migration Job `post-install` أول مرة؛ و `METRICS_TOKEN` في SSM بيكسر الـ PodMonitor scraping.
**التكلفة:** Standard parameters مجاني؛ Secrets Manager ~$0.40/secret/شهر كبديل.

### 65 — Helm chart للتطبيق (+ migrate hook)
**الهدف:** تقرا الـ chart (helpers، pod template مشترك، release env، hook الـ migration) وتنشر بـ `deploy-eks.yml` mode `helm` بـ `--wait --rollback-on-failure`.
**أهم الأوامر:**
```bash
helm lint k8s/helm/student-app
for v in k8s/helm/student-app/values*.yaml; do helm template lab k8s/helm/student-app -f "$v" >/dev/null && echo "ok $v"; done
helm template x k8s/helm/student-app --set-string image.tag=latest     # لازم يفشل
gh workflow run deploy-eks.yml --ref master -f image_tag=<GIT_SHA> -f mode=helm
helm -n student-app history student-app
helm -n student-app get values student-app --all | head -30
helm -n student-app rollback student-app --wait
helm -n student-app uninstall student-app
```
**التحقق:** `helm history` فيه `deploy-eks run <id>`، والـ release `deployed`، والـ hook annotations حسب الـ ESO (pre-install vs post-install).
**Gotchas:**
- دايماً `--set-string` للـ tags (SHA رقمي بيبوظ مع `--set`).
- Helm 4: `--rollback-on-failure` بدل `--atomic` (لسه شغال بـ deprecation warning).
- الـ rollback مبيرجّعش الـ migrations؛ hook فاشل بيفضل بعد الـ uninstall.
**التكلفة:** مجاني (فوق تكلفة الـ cluster).

### 66 — RollingUpdate و Recreate (probes، preStop، PDB)
**الهدف:** تقيس rolling بـ 0 failures مقابل downtime الـ Recreate، وتفهم الـ termination (preStop 10 / SIGQUIT / grace 40)، والـ probes، و PDB مع drain.
**أهم الأوامر:**
```bash
bash deploy/scripts/probe.sh http://localhost:8088/ready 0 0.05
helm upgrade student-app k8s/helm/student-app -n student-app -f k8s/helm/student-app/values-kind.yaml --set-string image.tag=ci-v2 --wait
kubectl -n student-app patch deployment student-app --type merge -p '{"spec":{"strategy":{"type":"Recreate","rollingUpdate":null}}}'
kubectl -n student-app set image deployment/student-app app=student-app:ci-v2
kubectl drain student-app-lab-worker2 --ignore-daemonsets --delete-emptydir-data --timeout=180s
kubectl uncordon student-app-lab-worker2
kubectl -n student-app get deploy student-app -o jsonpath='{.status.conditions}'
kubectl -n student-app rollout undo deploy/student-app
```
**التحقق:** Rolling: `failed : 0`؛ Recreate: `failure window` قد الـ shutdown + boot؛ الـ drain بيعمل evict pod واحد في المرة.
**Gotchas:**
- متعملش drain للـ node اللي عليها `mysql-0` (local-path PV مربوط بالـ node).
- `ProgressDeadlineExceeded` مبيعملش rollback لوحده في الـ Deployment.
- `kubectl rollout undo` على release Helm = drift.
**التكلفة:** مجاني على kind.

### 67 — Blue/Green على Kubernetes
**الهدف:** blue/green يدوي بـ Service selector switch، وبـ Argo Rollouts `blueGreen` (preview، pre-promotion analysis، promote، scaleDownDelay).
**أهم الأوامر:**
```bash
kubectl -n student-app patch svc student-app --type merge -p '{"spec":{"selector":{"slot":"green"}}}'
helm upgrade --install student-app k8s/helm/student-app -n student-app -f k8s/helm/student-app/values-kind.yaml -f k8s/helm/student-app/values-bluegreen.yaml --set-string image.tag=ci-v2 --set deployColor=green
kubectl argo rollouts get rollout student-app -n student-app --watch
kubectl -n student-app port-forward svc/student-app-preview 8081:80
kubectl argo rollouts promote student-app -n student-app
kubectl argo rollouts abort student-app -n student-app
kubectl argo rollouts undo student-app -n student-app
helm -n student-app rollback student-app
```
**التحقق:** قبل الـ promote الـ probe على `localhost:8088` بيشوف blue بس؛ بعده green و `failed : 0`؛ الـ AnalysisRun `Successful`.
**Gotchas:**
- `port-forward svc` مش بيتبع تغيير الـ selector.
- الـ web gate (`/ready`) بيعدّي release بيرجع 500 — محتاج post-promotion error-rate أو اختبار الـ preview.
- بعد abort الـ Rollout `Degraded` لحد ما الـ spec يرجع (helm rollback / git revert).
**التكلفة:** مجاني على kind؛ على EKS capacity ×2 وقت الـ release.

### 68 — Canary بـ Argo Rollouts + analysis
**الهدف:** canary (replicas على kind، ALB weights على EKS) بـ background analysis على 5xx الـ canary pods من Prometheus، و auto-abort للـ bad release (fail closed).
**أهم الأوامر:**
```bash
helm upgrade student-app k8s/helm/student-app -n student-app -f k8s/helm/student-app/values-kind.yaml --set-string image.tag=ci-v1 --set rollout.enabled=true
bash deploy/scripts/probe.sh http://localhost:8088/login 0 0.05 > /tmp/traffic.log 2>&1 &
helm upgrade student-app k8s/helm/student-app -n student-app -f k8s/helm/student-app/values-kind.yaml --set-string image.tag=ci-v2 --set rollout.enabled=true --set-string extraEnv.SRE_FAULT_ERROR_RATE=0.5
kubectl argo rollouts status student-app -n student-app --timeout 300s || echo aborted
kubectl -n student-app get rollout student-app -o jsonpath='{.status.phase} {.status.abort}'
kubectl -n student-app get analysisrun
helm -n student-app rollback student-app
gh workflow run deploy-eks.yml --ref master -f image_tag=<GIT_SHA> -f mode=rollouts
```
**التحقق:** الـ bad canary: `Degraded true`، و probe الـ `/ready` = `failed : 0`؛ على EKS الـ Ingress action annotation بيبيّن الـ weights.
**Gotchas:**
- من غير scraping (PodMonitor / annotations) كل canary يتعمله abort — مقصود (fail closed).
- مفيش traffic = NaN = pass؛ والـ gate على 5xx بس (الـ latency fault بيعدّي).
- CloudWatch provider محتاج IAM لـ argo-rollouts + `AWS_REGION` (مش في الستاك).
**التكلفة:** مجاني على kind؛ EKS: kube-prometheus-stack (غالباً node تالتة).

### 69 — GitOps بـ Argo CD
**الهدف:** Argo CD بيعمل sync للـ chart بـ `values-eks.yaml`، الـ app-of-apps للـ add-ons، الـ release = gitops-bump PR، والـ rollback = `git revert`.
**أهم الأوامر:**
```bash
helm upgrade --install argo-cd argo-cd --repo https://argoproj.github.io/argo-helm --version 10.18.2 -n argocd --create-namespace --set 'configs.params.server\.insecure=true'
kubectl apply -n argocd -f k8s/argocd/application.yaml      # أو app-of-apps.yaml (owner واحد!)
kubectl -n argocd get applications
gh workflow run deploy-eks.yml --ref master -f image_tag=<GIT_SHA> -f mode=gitops-bump
gh pr list --label gitops && gh pr merge <PR> --squash
kubectl argo rollouts get rollout student-app -n student-app --watch
git revert <BUMP_COMMIT> --no-edit    # الـ rollback (عن طريق PR)
kubectl -n argocd delete application student-app --wait=true
```
**التحقق:** الـ apps `Synced/Healthy`، `argocd app diff` فاضي، وتعديل يدوي على الـ ConfigMap بيرجع لوحده (selfHeal).
**Gotchas:**
- owner واحد لكل add-on (Terraform `install_addons` أو app-of-apps)؛ املا `vpcId` و `repoURL`.
- فعّل "Allow GitHub Actions to create and approve pull requests"؛ والـ PR بـ `GITHUB_TOKEN` مبيشغّلش CI.
- امسح الـ app قبل الـ add-ons (الـ LBC لازم يمسح الـ ALB).
**التكلفة:** Argo CD مجاني كـ software، بس غالباً محتاج node زيادة.

### 6A — HPA + Karpenter تحت load
**الهدف:** k6 بيحرق CPU محسوب، الـ HPA يكبّر بالأرقام، والـ Pending pods تخلي Karpenter يجيب nodes، وبعدين scale-down و consolidation.
**أهم الأوامر:**
```bash
kubectl apply -f /tmp/karpenter-default.yaml && kubectl get ec2nodeclass,nodepool
helm upgrade student-app k8s/helm/student-app -n student-app -f k8s/helm/student-app/values-eks.yaml --set rollout.enabled=false --set resources.requests.cpu=500m --set autoscaling.maxReplicas=12 --set-string image.repository=<REGISTRY>/student-app --set-string image.tag=<GIT_SHA>
LAB_TOKEN=$(aws ssm get-parameter --name /student-app/lab/app/SRE_LAB_TOKEN --with-decryption --query Parameter.Value --output text)
k6 run -e BASE_URL="http://$ALB" -e LAB_TOKEN="$LAB_TOKEN" -e RATE=15 -e CPU_MS=200 -e DURATION=15m loadtest/k6/autoscale-cpu.js
kubectl -n student-app get hpa -w
kubectl get nodeclaims -w
kubectl top nodes && kubectl top pods -n student-app
kubectl delete nodepool --all && kubectl delete ec2nodeclass --all
```
**التحقق:** الـ HPA بيوصل الـ desired المحسوب (`RATE × CPU_MS/1000 ÷ (request × 0.7)`)، و `nodeclaims` جديدة بتبقى Ready في ~1 دقيقة.
**Gotchas:**
- الـ NodePool/EC2NodeClass مصدرهم الرسمي سيناريو 6A §5.3 (الستاك بيشاور عليه) — القيم من `terraform output karpenter`.
- الـ utilization نسبة من الـ request (100m) — `RATE=10` ≈ 29 pod فمقفول على `maxReplicas: 6`؛ `RATE=2 CPU_MS=100` عشان تشوف الـ scaling.
- امسح الـ NodePools قبل `terraform destroy` (الـ EC2 بتاعة Karpenter برا الـ state).
**التكلفة:** nodes Karpenter (~$0.04/ساعة لكل t3.medium On-Demand، Spot أقل)؛ سقف `limits.cpu: 8`.
