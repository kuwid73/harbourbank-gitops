# orders-gitops

Desired state of the **agentic DevOps lab** cluster. ArgoCD continuously syncs the
cluster to this repo, so Git is the only way anything changes - for humans and AI agents alike.

## Layout

| Path | Purpose |
|---|---|
| `bootstrap/` | One-time steps to (re)build the cluster: k3d config, ArgoCD install, root app |
| `platform/` | One ArgoCD `Application` per cluster add-on (watched by the `root` app) |
| `platform/values/` | Helm values for those add-ons |
| `apps/` | The orders application manifests |

## Rebuild from scratch

```bash
./bootstrap/bootstrap.sh
```

ArgoCD UI: <http://argocd.localhost:8080> (user `admin`).
