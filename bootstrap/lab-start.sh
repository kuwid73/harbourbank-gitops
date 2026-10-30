#!/usr/bin/env bash
# Start of day: resume the stopped lab and wait until ArgoCD reports every app healthy.
set -euo pipefail

CLUSTER=agentic-lab
TIMEOUT_SECONDS=600

"$(dirname "$0")/image-cache.sh" up   # before the nodes, so their first pulls go through the cache
"$(dirname "$0")/node-addresses.sh" check   # nothing running may hold a node's pinned address
k3d cluster start "$CLUSTER"
kubectl config use-context "k3d-$CLUSTER"
kubectl wait --for=condition=Ready nodes --all --timeout=180s
# A node that restarted during start-up came up on the wrong address (see node-addresses.sh)
docker ps --filter "label=k3d.cluster=$CLUSTER" --format '{{.Names}}' \
  | xargs docker inspect --format '{{.Name}} {{.RestartCount}}' \
  | awk '$2 > 0 { print "warning: " substr($1, 2) " restarted " $2 " times during start-up" }'

echo "waiting for ArgoCD apps to be Synced and Healthy..."
deadline=$((SECONDS + TIMEOUT_SECONDS))
while true; do
  not_ready=$(kubectl -n argocd get applications.argoproj.io -o json 2>/dev/null \
    | jq -r '.items[] | select(.status.sync.status != "Synced" or .status.health.status != "Healthy")
             | "  \(.metadata.name): \(.status.sync.status // "?")/\(.status.health.status // "?")"') || not_ready="  (ArgoCD API not ready yet)"
  [[ -z "$not_ready" ]] && break
  if (( SECONDS > deadline )); then
    echo "still not ready after ${TIMEOUT_SECONDS}s:"; echo "$not_ready"; exit 1
  fi
  sleep 10
done
kubectl -n argocd get applications.argoproj.io

echo "lab ready: http://argocd.localhost:8080  http://grafana.localhost:8080"
echo "bank:      http://accounts-dev.localhost:8080  http://accounts-qa.localhost:8080  http://accounts.localhost:8080"
