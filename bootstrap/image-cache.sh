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
# Fixed addresses at the top of the network. Docker hands out addresses from the bottom in start
# order, and k3s refuses to start if a node's address changes: a cache started before the nodes
# once took their addresses and put both agents in a restart loop (NOTES.md, 2026-10-29).
declare -A HOST_PART=([ghcr]=255.250 [dockerhub]=255.251)

network_prefix() {   # "172.19" for 172.19.0.0/16 (k3d's default size)
  local subnet
  subnet=$(docker network inspect "$NETWORK" --format '{{(index .IPAM.Config 0).Subnet}}')
  [[ $subnet == *.0.0/16 ]] || { echo "expected a /16 network, got $subnet" >&2; exit 1; }
  echo "${subnet%.0.0/16}"
}

up() {
  local prefix ip current
  prefix=$(network_prefix)
  for name in "${!UPSTREAMS[@]}"; do
    local c="lab-cache-$name"
    ip="$prefix.${HOST_PART[$name]}"
    current=$(docker container inspect "$c" --format "{{with index .NetworkSettings.Networks \"$NETWORK\"}}{{with .IPAMConfig}}{{.IPv4Address}}{{end}}{{end}}" 2>/dev/null || true)
    if docker container inspect "$c" >/dev/null 2>&1 && [[ $current != "$ip" ]]; then
      docker rm -f "$c" >/dev/null   # not on its fixed address: recreate (the cached data stays in the volume)
    fi
    if docker container inspect "$c" >/dev/null 2>&1; then
      docker start "$c" >/dev/null
    else
      # REGISTRY_PROXY_TTL: keep cached images 30 days (the default is 7)
      docker run -d --name "$c" --network "$NETWORK" --ip "$ip" \
        -v "$c:/var/lib/registry" \
        -e REGISTRY_PROXY_REMOTEURL="${UPSTREAMS[$name]}" \
        -e REGISTRY_PROXY_TTL=720h \
        -e OTEL_TRACES_EXPORTER=none \
        -e REGISTRY_LOG_LEVEL=info \
        "$REGISTRY_IMAGE" >/dev/null
    fi
    echo "started $c ($ip) -> ${UPSTREAMS[$name]}"
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
