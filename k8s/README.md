# k8s/ — Kubernetes for the student-app lab (scenarios 60–6A)

Same image, same contract ([`docs/devops/CONVENTIONS.md`](../docs/devops/CONVENTIONS.md) §8) at three levels of
abstraction: **plain YAML** (learn the objects) → **Helm** (one parameterised chart for kind and EKS) →
**Argo Rollouts / Argo CD** (progressive delivery and GitOps).

```
k8s/
├── kind/                     local cluster (also used by CI)
│   ├── cluster.yaml          1 control-plane + 2 workers, NodePort 30080 → localhost:8088
│   └── mysql.yaml            lab-only MySQL 8.4 StatefulSet + headless Service + Secret
├── manifests/                plain YAML + kustomize (teaching)
│   ├── base/                 namespace, configmap, deployment, service, hpa, pdb, migrate-job, networkpolicy,
│   │                         serviceaccount, secret.example.yaml (never applied)
│   └── overlays/{kind,eks}   kind: NodePort + CI image · eks: ALB Ingress, SecretStore + ExternalSecret (SSM), ECR image
├── helm/student-app/         production chart (Deployment or Argo Rollout, hooks, ALB, ESO, analysis, ...)
│   └── values.yaml · values-kind.yaml · values-eks.yaml · values-bluegreen.yaml
├── rollouts/                 standalone Argo Rollouts examples: bluegreen, canary (ALB), analysis (Prometheus / CloudWatch / web)
└── argocd/                   Application, app-of-apps + pinned add-on Applications, GitOps README
```

## Scenario map

| # | Topic | Files |
|---|---|---|
| 60 | First deployment on kind, objects one by one (plain YAML + kustomize, then the chart) | `kind/`, `manifests/base`, `manifests/overlays/kind` |
| 61–62 | EKS cluster (Console / eksctl, then Terraform `stacks/60-eks`) | — |
| 63 | ALB Ingress via the AWS Load Balancer Controller (target-type ip, /ready health check) | `manifests/overlays/eks/ingress.yaml`, chart `ingress.yaml` |
| 64 | External Secrets from SSM Parameter Store | `manifests/overlays/eks/externalsecret.yaml`, chart `externalsecret.yaml` |
| 65 | Helm chart (+ migrate hook), deploy-eks mode `helm` | `helm/student-app`, `.github/workflows/deploy-eks.yml` |
| 66 | Zero-downtime RollingUpdate (maxSurge 1 / maxUnavailable 0, readiness `/ready`, preStop 10 s, SIGQUIT) + Recreate, PDB, NetworkPolicy | `manifests/base/deployment.yaml`, `pdb.yaml`, `networkpolicy.yaml`, CI step "Zero-downtime RollingUpdate" |
| 67 | Blue-green (Service selector switch; Argo Rollouts preview + pre-promotion analysis) | `rollouts/bluegreen.yaml`, `values-bluegreen.yaml` |
| 68 | Canary with ALB weights + automated analysis → auto-abort; bad-release drills (`faults.*` / `extraEnv`) | `rollouts/canary.yaml`, `rollouts/analysis-*.yaml`, chart `analysistemplate.yaml`, CI step "Canary" |
| 69 | GitOps with Argo CD (PR bumps the tag, rollback = git revert) | `argocd/`, deploy-eks mode `gitops-bump` |
| 6A | HPA on CPU (`/sre-lab/cpu`, k6) + requests/limits, OOMKill (`/sre-lab/memory`) + Karpenter | `hpa.yaml` (needs metrics-server), deployment resources |

## Quick start (kind)

```bash
kind create cluster --config k8s/kind/cluster.yaml
docker build -f docker/Dockerfile --build-arg APP_VERSION=ci-v1 -t student-app:ci-v1 .
kind load docker-image student-app:ci-v1 --name student-app-lab
kubectl apply -f k8s/manifests/base/namespace.yaml -f k8s/kind/mysql.yaml
kubectl -n student-app rollout status statefulset/mysql --timeout=180s
DB_PASSWORD=$(kubectl -n student-app get secret mysql-credentials -o jsonpath='{.data.MYSQL_PASSWORD}' | base64 -d)
kubectl -n student-app create secret generic student-app-secrets \
  --from-literal=APP_KEY="base64:$(openssl rand -base64 32)" --from-literal=DB_PASSWORD="$DB_PASSWORD"

helm upgrade --install student-app k8s/helm/student-app -n student-app \
  -f k8s/helm/student-app/values-kind.yaml --set-string image.tag=ci-v1 --wait
curl -s localhost:8088/ready
```

No Docker locally? Read [`.github/workflows/k8s-integration.yml`](../.github/workflows/k8s-integration.yml): it runs all
of this (plus the zero-downtime and canary drills) on a GitHub runner on every push touching `k8s/`, `app/`, `docker/`...

Plain-YAML variant: `kubectl apply -k k8s/manifests/overlays/kind`. Caveat: the migrate Job is created together
with the Deployment (and is immutable) — run/wait for it first and delete it before the next release:
`kubectl -n student-app wait --for=condition=complete job/student-app-migrate --timeout=300s`.

## Helm chart — values worth knowing

| Key | Default | Why |
|---|---|---|
| `image.repository` / `image.tag` | `student-app` / appVersion | Tag = git SHA, pass with `--set-string`; `latest` fails the render. |
| `config.*` | app defaults | Environment-scoped env → ConfigMap (envFrom, before the Secret: Secret wins). `KEY: null` removes one. |
| `deployColor`, `faults.*`, `extraEnv` | `none`, off, `{}` | Release-scoped env → **pod template** (not the ConfigMap), so a bad canary's settings can't leak into stable pods. `--set extraEnv.SRE_FAULT_ERROR_RATE=0.5` = bad release. |
| `existingSecret` | `student-app-secrets` | APP_KEY, DB_PASSWORD... (kubectl on kind, ESO on EKS). |
| `externalSecrets.enabled` / `.ssmPath` / `.store.{create,kind,name,region}` | off | `external-secrets.io/v1`, `find` by path + key rewrite. `store.create` renders a ClusterSecretStore limited to the release namespace. |
| `rollout.enabled` / `rollout.strategy` | `false` / `canary` | Deployment vs Argo Rollout with the same pod template. `canary` or `blueGreen`. |
| `rollout.canary.steps` / `.analysis` / `.trafficRouting.alb.enabled` | 10/25/50 % | ALB routing needs `ingress.enabled` + `className: alb`. |
| `rollout.blueGreen.*` | manual promotion | `autoPromotionEnabled`, `scaleDownDelaySeconds`, pre/post promotion analysis. |
| `analysis.prometheus.address`, `.maxErrorRate`, `.interval`, `.failureLimit`, `.rateWindow` | prometheus-server, 5 % | Canary gate: 5xx ratio of the new pods (`pod=~".+-<hash>-.+"`) on app routes. |
| `ingress.*` | off | `className` alb/nginx, annotations, `blockPaths: [/metrics]` answered 404 by the ALB. |
| `migrations.*` | on | Hook Job (`pre-install,pre-upgrade`; `post-install` on first install when ESO creates the Secret), backoffLimit 1, activeDeadlineSeconds. |
| `autoscaling.*`, `pdb.*`, `topologySpread.*`, `networkPolicy.*` | on | `networkPolicy.databaseTo` narrows DB egress (MySQL pod on kind, VPC CIDR on EKS). |
| `serviceMonitor.enabled` | **off** | The PodMonitor in `observability/k8s/kube-prometheus-stack-values.yaml` already scrapes the pods; both = double counting. |

Render locally: `helm template lab k8s/helm/student-app -f k8s/helm/student-app/values-eks.yaml`.
CI lint (`lint-infra.yml`): `helm lint` + `helm template -f values*.yaml | kubeconform -strict`, and kubeconform
over every other YAML under `k8s/` (that is why kustomize patches are inline, never separate partial files).

## Versions (verified Nov 2026)

kind v0.33.0 · node image Kubernetes v1.36.4 (EKS standard support: 1.34–1.37) · Helm v4.3.2 · Argo Rollouts v1.10.2
(chart 2.43.12) · External Secrets 2.15.0 (`external-secrets.io/v1`) · AWS LBC chart 3.6.3 · kube-prometheus-stack
93.6.1 · prometheus chart 29.48.0 (CI only) · Argo CD chart 10.18.2 (v3.6.2).
