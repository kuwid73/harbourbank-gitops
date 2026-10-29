#!/usr/bin/env bash
# End of day: stop the lab without losing anything. Resume with lab-start.sh.
set -euo pipefail

CLUSTER=agentic-lab

# Stops the node containers; cluster state (etcd/sqlite, volumes, sealed-secrets key) is kept
k3d cluster stop "$CLUSTER"
"$(dirname "$0")/image-cache.sh" down   # cached images stay in their Docker volumes
