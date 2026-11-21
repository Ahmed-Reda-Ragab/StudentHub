# kind — local Kubernetes for scenario 60

The same cluster definition is used locally and by
[`.github/workflows/k8s-integration.yml`](../../.github/workflows/k8s-integration.yml) on GitHub runners
(no Docker needed on your laptop if you only read the CI logs).

| File | What it is |
|---|---|
| [`cluster.yaml`](cluster.yaml) | 1 control-plane + 2 workers, node image pinned by digest (Kubernetes v1.36, kind v0.33). NodePort `30080` → `localhost:8088`. Workers carry fake zone labels (`lab-a`, `lab-b`) so zone spreading works like 2 AZs. |
| [`mysql.yaml`](mysql.yaml) | **Lab-only** MySQL 8.4 StatefulSet + headless Service `mysql` + Secret `mysql-credentials` (utf8mb4, readiness = TCP `mysqladmin ping`, non-root UID 999). |

## Up

```bash
kind create cluster --config k8s/kind/cluster.yaml          # ~1 min
docker build -f docker/Dockerfile --build-arg APP_VERSION=ci-v1 -t student-app:ci-v1 .
kind load docker-image student-app:ci-v1 --name student-app-lab

kubectl apply -f k8s/manifests/base/namespace.yaml          # namespace + Pod Security labels
kubectl apply -f k8s/kind/mysql.yaml
kubectl -n student-app rollout status statefulset/mysql --timeout=180s

# App secret (on EKS this Secret is written by External Secrets from SSM)
DB_PASSWORD=$(kubectl -n student-app get secret mysql-credentials -o jsonpath='{.data.MYSQL_PASSWORD}' | base64 -d)
kubectl -n student-app create secret generic student-app-secrets \
  --from-literal=APP_KEY="base64:$(openssl rand -base64 32)" \
  --from-literal=DB_USERNAME=student \
  --from-literal=DB_PASSWORD="$DB_PASSWORD"
```

Then deploy one of:

```bash
# A) Helm (production chart; migrations run as a pre-install/pre-upgrade hook)
helm upgrade --install student-app k8s/helm/student-app -n student-app \
  -f k8s/helm/student-app/values-kind.yaml --set image.tag=ci-v1 --wait --timeout 5m

# B) Plain manifests (teaching) — see k8s/README.md for the migration-order caveat
kubectl apply -k k8s/manifests/overlays/kind

curl -s localhost:8088/ready      # {"status":"ready","checks":{"database":"ok"},"version":"ci-v1",...}
```

## Notes

- **Ports**: only `127.0.0.1:8088` is published. Anything else: `kubectl port-forward`.
- **Images** are side-loaded (`kind load`), so the chart uses `image.pullPolicy: Never` in `values-kind.yaml` —
  a missing image fails fast with `ErrImageNeverPull` instead of trying Docker Hub.
- **NetworkPolicy** is enforced: kind's default CNI (kindnet) implements it since kind v0.24.
- **No metrics-server** by default, so `values-kind.yaml` disables the HPA. To practise autoscaling (scenario 6A):
  `helm upgrade --install metrics-server metrics-server --repo https://kubernetes-sigs.github.io/metrics-server/ --version 3.14.0 -n kube-system --set 'args={--kubelet-insecure-tls}'`
  and then `--set autoscaling.enabled=true`.
- The MySQL password is a static lab default. Replace the Secret before applying if the cluster is shared.

## Down

```bash
kind delete cluster --name student-app-lab
```
