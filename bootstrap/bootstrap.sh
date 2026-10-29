#!/usr/bin/env bash
# Rebuild the lab from scratch: k3d cluster -> ArgoCD -> root app.
# Everything after that is installed by ArgoCD from Git.
set -euo pipefail
cd "$(dirname "$0")/.."

CLUSTER=agentic-lab
# Read the chart version from the Application so bootstrap and self-management never disagree
ARGOCD_CHART_VERSION=$(yq '.spec.sources[0].targetRevision' platform/argocd.yaml)

if ! k3d cluster list "$CLUSTER" >/dev/null 2>&1; then
  k3d cluster create --config bootstrap/k3d-config.yaml
fi
# The cluster network exists now; the nodes already point at the caches (k3d-config.yaml)
./bootstrap/image-cache.sh up
kubectl config use-context "k3d-$CLUSTER"

helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null
helm upgrade --install argocd argo/argo-cd \
  --version "$ARGOCD_CHART_VERSION" \
  --namespace argocd --create-namespace \
  --values platform/values/argocd.yaml \
  --wait

kubectl apply -f bootstrap/root-app.yaml

echo
echo "ArgoCD UI: http://argocd.localhost:8080  (user: admin)"
echo "Password:  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
