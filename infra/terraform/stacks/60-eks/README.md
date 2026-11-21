# Stack 60 — Amazon EKS (scenarios 60–6A)

| Piece | Choice |
|---|---|
| VPC | `terraform-aws-modules/vpc/aws` **~> 6.8**, 2 AZs, `/20` subnets tagged for the AWS Load Balancer Controller; no NAT by default (nodes in public subnets, inbound limited by the node SG) |
| Cluster | `terraform-aws-modules/eks/aws` **~> 21.30** (v21 inputs: `name`, `kubernetes_version`, `endpoint_public_access`, `addons`), Kubernetes **1.36**, upgrade policy `STANDARD` (no extended-support surcharge), secrets envelope encryption (KMS) |
| Access | access entries: Terraform's identity is admin (`enable_cluster_creator_admin_permissions`), plus `cluster_admin_principal_arns` |
| Nodes | managed node group, 2 × `t3.medium` AL2023, `node_capacity_type = "SPOT"` toggle, SSM instead of SSH |
| EKS add-ons | coredns, kube-proxy, vpc-cni (**prefix delegation** → 110 pods/node), eks-pod-identity-agent, metrics-server (community add-on) |
| IAM for pods | **EKS Pod Identity**: AWS Load Balancer Controller (official policy v3.6.3 in [`policies/`](policies/)), External Secrets (`ssm:GetParameter*` on `/student-app/<env>/app/*` only), Karpenter (optional) |
| Helm (`install_addons`) | aws-load-balancer-controller 3.6.3, external-secrets 2.15.0, argo-rollouts 2.43.12, argo-cd 10.18.2, kube-prometheus-stack 93.6.1, karpenter 1.15.3 — helm provider v3 syntax |
| Data | `modules/rds-mysql` in private subnets (access from the node SG), app SSM parameters ([`ssm.tf`](ssm.tf)), RDS alarms (`modules/observability`, `enable_alb_alarms = false`) |

| Scenario | What |
|---|---|
| 61 | cluster from the Console / eksctl (compare with this stack) |
| 62 | this stack: cluster + node group (`node_capacity_type = "SPOT"` for Spot) + `kubectl get nodes` |
| 63 | `install_addons = true` → AWS Load Balancer Controller → Ingress → ALB |
| 64 | ESO: `terraform output -raw cluster_secret_store_manifest \| kubectl apply -f -` + ExternalSecret `student-app-secrets` |
| 65 | Helm chart deploy from GitHub Actions (`grant_github_deploy_role = true` gives the deploy role an access entry) |
| 66 | RollingUpdate / Recreate, PDB, NetworkPolicy (vpc-cni `enableNetworkPolicy`) |
| 67–68 | Argo Rollouts blue/green + canary with analysis (kube-prometheus-stack loads the PodMonitor values) |
| 69 | Argo CD (`addons.argo_cd = true`) — GitOps |
| 6A | HPA (metrics-server add-on) + `enable_karpenter = true` (NodePool/EC2NodeClass manifests: docs/devops/scenarios/6A-hpa-karpenter-under-load.md; node role: `terraform output karpenter`) |
| 71/73 | kube-prometheus-stack (`addons.kube_prometheus_stack = true`, consider 3 nodes) + `observability/k8s/prometheusrule-slo.yaml` |

## Use

```bash
cd infra/terraform/stacks/60-eks
cp terraform.tfvars.example terraform.tfvars          # lock cluster_endpoint_public_access_cidrs to your IP
terraform init -backend-config=../../backend.hcl
terraform plan -out=tfplan && terraform apply tfplan   # ~15 min (cluster + nodes + RDS)

eval "$(terraform output -raw update_kubeconfig)"
kubectl get nodes -o wide

# second apply: controllers via Helm (the provider needs a reachable cluster)
terraform apply -var install_addons=true
```

## Destroy

```bash
# Delete Ingresses / LoadBalancer Services FIRST: the controller created those ALBs/NLBs and their
# security groups outside Terraform; leftovers block the VPC deletion.
kubectl delete ingress --all -A
terraform destroy
```

## Cost (us-east-1, defaults, ≈)

| Item | USD/hour |
|---|---|
| EKS control plane (standard support) | 0.10 |
| 2 × t3.medium on-demand (Spot ≈ 0.03 total) | 0.083 |
| EBS 2 × 20 GiB gp3, public IPv4 × 2 | 0.015 |
| RDS db.t4g.micro + 20 GiB | 0.019 |
| KMS key, control-plane logs, alarms | ~0.01 |
| **Total** | **≈ 0.23 (≈ 5.50/day)** |

ALB from the controller: + ≈ 0.03/h. `enable_nat = true`: + ≈ 0.045/h + data. Apply → practise → destroy.

## Outputs

`cluster_name`, `cluster_endpoint`, `kubernetes_version`, `region`, `update_kubeconfig`, `vpc_id`,
`node_security_group_id`, `rds_address`, `ssm_prefix`, `pod_identity_roles`, `karpenter`,
`cluster_secret_store_manifest`.
