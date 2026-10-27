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
| `apps/` | Harbour Bank application manifests (dev, qa, prod overlays) |

## Rebuild from scratch

```bash
./bootstrap/bootstrap.sh
```

## UIs

| UI | URL |
|---|---|
| ArgoCD | <http://argocd.localhost:8080> |
| Grafana | <http://grafana.localhost:8080> |
| Prometheus | <http://prometheus.localhost:8080> |
| Alertmanager | <http://alertmanager.localhost:8080> |
