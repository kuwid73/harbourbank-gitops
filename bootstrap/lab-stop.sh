#!/usr/bin/env bash
# End of day: stop the lab without losing anything. Resume with lab-start.sh.
set -euo pipefail

CLUSTER=agentic-lab
LOCAL_CONTAINERS=(hb-api hb-pg)   # local docker rehearsal of accounts-api, if present

for c in "${LOCAL_CONTAINERS[@]}"; do
  docker stop "$c" >/dev/null 2>&1 && echo "stopped $c" || true
done
# Stops the node containers; cluster state (etcd/sqlite, volumes, sealed-secrets key) is kept
k3d cluster stop "$CLUSTER"
