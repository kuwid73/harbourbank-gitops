#!/usr/bin/env bash
# Check that every NetworkPolicy pod selector in each environment matches a pod that environment
# runs, before merge. See check_network_policies.py for why (drill 5, 2026-11-11).
#
#   .github/scripts/check-network-policies.sh [env ...]     default: dev qa prod
set -euo pipefail
cd "$(dirname "$0")/../.."
envs=("${@:-dev qa prod}"); read -ra envs <<< "${envs[*]}"
failed=0
for env in "${envs[@]}"; do
  echo "== $env"
  kubectl kustomize "apps/harbourbank/overlays/$env" | yq -o=json -I=0 '.' \
    | python3 -I .github/scripts/check_network_policies.py || failed=1
done
exit $failed
