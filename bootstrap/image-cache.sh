#!/usr/bin/env bash
# Pull-through image caches for the lab, so each image is downloaded from the internet once
# instead of once per node (a 74 MB image took 7-12 min per node, exceeding the rollout deadline).
#
#   image-cache.sh up          create (first time) or start the caches
#   image-cache.sh down        stop them; the cached images are kept in Docker volumes
#   image-cache.sh configure   point the running nodes at the caches (needs a lab stop/start once)
#
# The caches join the cluster's Docker network with no host port: only the nodes can reach them.
set -euo pipefail
cd "$(dirname "$0")/.."

CLUSTER=agentic-lab
NETWORK="k3d-$CLUSTER"
REGISTRY_IMAGE="registry:3.0.0@sha256:6c5666b861f3505b116bb9aa9b25175e71210414bd010d92035ff64018f9457e"
declare -A UPSTREAMS=(
  [ghcr]=https://ghcr.io
  [dockerhub]=https://registry-1.docker.io
)

up() {
  for name in "${!UPSTREAMS[@]}"; do
    local c="lab-cache-$name"
    if docker container inspect "$c" >/dev/null 2>&1; then
      docker start "$c" >/dev/null
    else
      # REGISTRY_PROXY_TTL: keep cached images 30 days (the default is 7)
      docker run -d --name "$c" --network "$NETWORK" \
        -v "$c:/var/lib/registry" \
        -e REGISTRY_PROXY_REMOTEURL="${UPSTREAMS[$name]}" \
        -e REGISTRY_PROXY_TTL=720h \
        -e OTEL_TRACES_EXPORTER=none \
        -e REGISTRY_LOG_LEVEL=info \
        "$REGISTRY_IMAGE" >/dev/null
    fi
    echo "started $c -> ${UPSTREAMS[$name]}"
  done
}

down() {
  for name in "${!UPSTREAMS[@]}"; do
    docker stop "lab-cache-$name" >/dev/null 2>&1 && echo "stopped lab-cache-$name" || true
  done
}

configure() {
  local wanted changed=0
  wanted=$(yq '.registries.config' bootstrap/k3d-config.yaml)
  for node in $(docker ps --filter "label=k3d.cluster=$CLUSTER" --format '{{.Names}} {{.Label "k3d.role"}}' \
                 | awk '$2 == "server" || $2 == "agent" {print $1}'); do
    if [[ "$(docker exec "$node" cat /etc/rancher/k3s/registries.yaml 2>/dev/null)" == "$wanted" ]]; then
      echo "$node: already configured"
    else
      printf '%s\n' "$wanted" | docker exec -i "$node" sh -c 'mkdir -p /etc/rancher/k3s && cat > /etc/rancher/k3s/registries.yaml'
      echo "$node: configured"
      changed=1
    fi
  done
  # k3s reads registries.yaml only at startup. Agent nodes have no /etc/rancher/k3s until then, hence mkdir -p
  (( changed )) && echo "restart the lab to apply: ./bootstrap/lab-stop.sh && ./bootstrap/lab-start.sh" || true
}

case "${1:-}" in
  up) up ;;
  down) down ;;
  configure) configure ;;
  *) echo "usage: $0 up|down|configure" >&2; exit 2 ;;
esac
