# harbourbank-gitops

Desired state of the **Harbour Bank** agentic DevOps lab cluster (a fictional bank, synthetic data only).
ArgoCD continuously syncs the cluster to this repo, so Git is the only way anything changes -
for humans and AI agents alike.

## Layout

| Path | Purpose |
|---|---|
| `bootstrap/` | One-time steps to (re)build the cluster: k3d config, ArgoCD install, root app |
| `platform/` | One ArgoCD `Application` per cluster add-on (watched by the `root` app) |
| `platform/values/` | Helm values for those add-ons |
| `platform/manifests/` | Plain manifests deployed alongside add-ons (e.g. SealedSecrets) |
| `apps/harbourbank/base/` | accounts-api, its Postgres (CloudNativePG) and the migration Job |
| `apps/harbourbank/overlays/` | dev / qa / prod differences; each folder becomes an ArgoCD app (`platform/harbourbank.yaml`) |

## Daily stop / start

State survives a stop: ArgoCD, Grafana, Loki logs and the sealed-secrets key all live in the node containers' volumes.

```bash
./bootstrap/lab-stop.sh    # end of day (~10s)
./bootstrap/lab-start.sh   # next day: starts the cluster, waits until every ArgoCD app is Synced/Healthy (~30s-2min)
```

Start Docker Desktop first. Don't `k3d cluster delete` - that destroys the sealed-secrets key, so the
committed SealedSecrets could no longer be decrypted.

## Rebuild from scratch

```bash
./bootstrap/bootstrap.sh
```

## Harbour Bank environments

| Env | URL | Changed by |
|---|---|---|
| dev | <http://accounts-dev.localhost:8080> | CI, on every merge to `harbourbank-app` main |
| qa | <http://accounts-qa.localhost:8080> | promotion PR |
| prod | <http://accounts.localhost:8080> | promotion PR approved by a code owner |

Rollout order inside each environment (ArgoCD sync waves): database healthy -> migration Job succeeds -> API.

## UIs

| UI | URL |
|---|---|
| ArgoCD | <http://argocd.localhost:8080> |
| Grafana | <http://grafana.localhost:8080> |
| Prometheus | <http://prometheus.localhost:8080> |
| Alertmanager | <http://alertmanager.localhost:8080> |
