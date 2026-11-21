# Argo CD — GitOps for the lab (scenario 69)

Git is the desired state; Argo CD makes the cluster match it, continuously.

| File | What it is |
|---|---|
| [`application.yaml`](application.yaml) | The app: Helm chart `k8s/helm/student-app` + `values-eks.yaml`, automated sync (prune + selfHeal), `CreateNamespace=true`, retry with backoff, namespace labels (Pod Security `restricted`, ALB readiness gates). |
| [`app-of-apps.yaml`](app-of-apps.yaml) | Root Application → every file in [`apps/`](apps/). |
| [`apps/aws-load-balancer-controller.yaml`](apps/aws-load-balancer-controller.yaml) | eks-charts `aws-load-balancer-controller` **3.6.3**, `kube-system`, wave -3. Fill `clusterName`/`vpcId`/`region` from the 60-eks outputs. |
| [`apps/external-secrets.yaml`](apps/external-secrets.yaml) | `external-secrets` **2.15.0**, namespace `external-secrets`, wave -2. |
| [`apps/argo-rollouts.yaml`](apps/argo-rollouts.yaml) | `argo-rollouts` **2.43.12** (Argo Rollouts v1.10.2) + dashboard, namespace `argo-rollouts`, wave -2. |
| [`apps/kube-prometheus-stack.yaml`](apps/kube-prometheus-stack.yaml) | `kube-prometheus-stack` **93.6.1**, namespace `monitoring`, values from `observability/k8s/kube-prometheus-stack-values.yaml` (multi-source). |
| [`apps/student-app.yaml`](apps/student-app.yaml) | Same Application as `application.yaml`, wave 0. |

All chart versions are pinned. Upgrading an add-on = a reviewed commit that changes `targetRevision`.

## The flow

```
developer ──push──▶ CI (lab-integration, k8s-integration) ──▶ image <sha> in ECR
                                                                 │
              deploy-eks.yml  mode=gitops-bump  ◀────────────────┘
                     │  edits image.tag (+ repository) in k8s/helm/student-app/values-eks.yaml
                     ▼
               Pull request ──review/merge──▶ master
                                                 │  Argo CD polls / webhook
                                                 ▼
                          Argo CD sync: ExternalSecret (wave -1) → migrate Job (wave 0) → Rollout (wave 1)
                                                 │
                          Argo Rollouts canary 10 → 25 → 50 → 100 % with Prometheus analysis
                                   └─ bad release → automatic abort, traffic stays on stable
```

- **Nobody runs `kubectl apply` or `helm upgrade` against the cluster** in this mode — the pipeline only
  writes to git. Cluster credentials stay inside the cluster (pull model).
- **Rollback = `git revert <bump commit>`** → Argo syncs the previous tag. The history of what ran when is
  `git log k8s/helm/student-app/values-eks.yaml`.
- **Drift**: `selfHeal: true` reverts manual edits (`kubectl scale`, `kubectl edit`) within seconds.
  `kubectl argo rollouts promote/abort` still work: they act on the Rollout's status, not its spec.
- **Migrations**: the chart's Job carries `argocd.argoproj.io/hook: Sync` + `sync-wave: "0"`. When an
  Argo CD hook annotation is present Argo ignores all Helm hooks, so the Job runs after the
  ExternalSecret (wave -1) has produced the Secret and before the Rollout (wave 1).

## Bootstrap

```bash
# Argo CD itself is installed by Terraform (60-eks, install_addons=true: release "argo-cd", namespace
# "argocd", server.insecure) or by hand with the same names:
helm upgrade --install argo-cd argo-cd --repo https://argoproj.github.io/argo-helm --version 10.18.2 \
  -n argocd --create-namespace --set 'configs.params.server\.insecure=true'

kubectl apply -n argocd -f k8s/argocd/app-of-apps.yaml      # everything
# or only the app (add-ons already installed by Terraform):
kubectl apply -n argocd -f k8s/argocd/application.yaml

kubectl -n argocd get applications
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
kubectl -n argocd port-forward svc/argo-cd-argocd-server 8080:80     # release "argo-cd" → service name
```

## Gotchas

- **One owner per add-on.** Terraform 60-eks installs the same add-ons with the same release names, namespaces
  and pinned versions when `install_addons = true`. Use either that (then apply only `application.yaml`) or
  `app-of-apps.yaml` with `install_addons = false` — two controllers "fixing" the same release fight forever.
- **Scraping.** The canary analysis needs the app pods scraped. `apps/kube-prometheus-stack.yaml` uses
  `observability/k8s/kube-prometheus-stack-values.yaml` (PodMonitor). When it comes from
  Terraform instead (stack 60 `install_addons`), `addons.tf` already loads that same values file. Either way,
  without the PodMonitor the analysis finds no series and (by design) aborts every canary.
- **Sync waves between Applications** only order creation: Argo CD has no health check for the
  `Application` kind by default. CRD-dependent children rely on `SkipDryRunOnMissingResource=true` +
  `retry`. To make waves blocking, add the Application health customization to `argocd-cm`
  (Argo CD docs: "App of Apps" → health assessment).
- **Private repo?** Register it once: `argocd repo add https://github.com/<org>/<repo>.git --username x --password <PAT>`
  (or a GitHub App / deploy key).
- `targetRevision: master` must be the branch the gitops-bump PRs target.
