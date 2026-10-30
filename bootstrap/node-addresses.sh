#!/usr/bin/env bash
# Fixed Docker network addresses for the lab's long-lived containers (server, agents, load balancer).
#
#   node-addresses.sh record   while the lab runs: remember each unpinned container's address,
#                              after checking it matches the address Kubernetes has for that node
#   node-addresses.sh pin      while the lab is stopped: fix each recorded container to its address
#   node-addresses.sh check    before a start: fail if a running container holds a pinned address
#   node-addresses.sh status   show each container's address and whether it is pinned
#
# Why: k3s refuses to start if a node comes up on a different address from the one Kubernetes
# stored. Docker hands addresses out afresh on every start, so the two agents sometimes swapped and
# restart-looped until each landed on its own (NOTES.md, 2026-10-30).
#
# Caution: Docker does not reserve a stopped container's pinned address. A new container started
# first can take it, and the pinned container then fails to start ("Address already in use").
# k3d re-creates its tools container on every start and gets the lowest free address (.2), so it
# never collides as long as everything long-lived is pinned (the caches sit at .255.x) and nothing
# else joins the network first. `check` enforces that.
set -euo pipefail

CLUSTER=agentic-lab
NETWORK="k3d-$CLUSTER"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/agentic-lab/node-addresses"

containers() {   # the long-lived k3d containers; tools is re-created on every start, so not pinned
  docker ps -a --filter "label=k3d.cluster=$CLUSTER" --format '{{.Names}} {{.Label "k3d.role"}}' \
    | awk '$2 == "server" || $2 == "agent" || $2 == "loadbalancer"'
}

pinned_ip() {
  docker container inspect "$1" \
    --format "{{with index .NetworkSettings.Networks \"$NETWORK\"}}{{with .IPAMConfig}}{{.IPv4Address}}{{end}}{{end}}"
}

current_ip() {   # empty while stopped (Docker would print "invalid IP")
  docker container inspect "$1" \
    --format "{{if .State.Running}}{{with index .NetworkSettings.Networks \"$NETWORK\"}}{{.IPAddress}}{{end}}{{end}}"
}

record() {
  local name role pinned ip node_ip
  mkdir -p "$(dirname "$STATE")"
  : > "$STATE"
  while read -r name role; do
    pinned=$(pinned_ip "$name")
    if [[ -n $pinned ]]; then echo "$name: already pinned at $pinned"; continue; fi
    ip=$(current_ip "$name")
    [[ -n $ip ]] || { echo "$name has no address: is the lab running?" >&2; exit 1; }
    if [[ $role != loadbalancer ]]; then
      # Never pin an address Kubernetes doesn't expect: that would make the restart loop permanent
      node_ip=$(kubectl --context "k3d-$CLUSTER" get node "$name" \
        -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
      [[ $ip == "$node_ip" ]] || { echo "$name is on $ip but Kubernetes expects $node_ip; not pinning" >&2; exit 1; }
    fi
    echo "$name $ip" >> "$STATE"
    echo "$name: will pin at $ip"
  done < <(containers)
}

pin() {
  local name ip
  [[ -s $STATE ]] || { echo "nothing to pin"; return; }
  while read -r name ip; do
    [[ $(docker container inspect "$name" --format '{{.State.Running}}') == false ]] \
      || { echo "$name is running; stop the lab first" >&2; exit 1; }
    docker network disconnect "$NETWORK" "$name"
    docker network connect --ip "$ip" "$NETWORK" "$name"
    echo "$name: pinned at $(pinned_ip "$name")"
  done < "$STATE"
  rm -f "$STATE"
}

check() {
  local name role ip holder
  while read -r name role; do
    ip=$(pinned_ip "$name")
    [[ -n $ip ]] || continue
    holder=$(docker network inspect "$NETWORK" \
      --format "{{range .Containers}}{{if eq .IPv4Address \"$ip/16\"}}{{.Name}}{{end}}{{end}}")
    if [[ -n $holder && $holder != "$name" ]]; then
      echo "$holder holds $ip, which belongs to $name: stop it before starting the lab" >&2
      exit 1
    fi
  done < <(containers)
  echo "pinned addresses are free"
}

status() {
  local name role
  while read -r name role; do
    printf '%-26s %-13s now=%-14s pinned=%s\n' "$name" "$role" "$(current_ip "$name" | grep . || echo stopped)" \
      "$(pinned_ip "$name" | grep . || echo no)"
  done < <(containers)
}

case "${1:-}" in
  record|pin|check|status) "$1" ;;
  *) echo "usage: $0 record|pin|check|status" >&2; exit 2 ;;
esac
