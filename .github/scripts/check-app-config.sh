#!/usr/bin/env bash
# Check each environment's accounts-api config the way the app itself will read it, before merge.
#
# Kustomize accepts any string as a config value; only the app knows that DB_POOL_TIMEOUT_SECONDS
# must be a number (drill 2, 2026-11-02: "5s" stalled prod's rollout). So render each overlay, take
# the API's ConfigMap and the image it is pinned to, and load the settings with that image's own
# validation. DATABASE_URL comes from a Secret at runtime; a placeholder stands in for it here.
#
#   .github/scripts/check-app-config.sh [env ...]     default: dev qa prod
set -euo pipefail
cd "$(dirname "$0")/../.."
envs=("${@:-dev qa prod}"); read -ra envs <<< "${envs[*]}"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
failed=0

for env in "${envs[@]}"; do
  kubectl kustomize "apps/harbourbank/overlays/$env" > "$work/$env.yaml"
  yq 'select(.kind == "ConfigMap" and (.metadata.name | test("^accounts-api-config-"))) | .data
      | to_entries | .[] | .key + "=" + .value' "$work/$env.yaml" > "$work/$env.env"
  image=$(yq 'select(.kind == "Deployment" and .metadata.name == "accounts-api")
              | .spec.template.spec.containers[] | select(.name == "accounts-api") | .image' "$work/$env.yaml")
  echo "== $env: $(wc -l < "$work/$env.env") settings, image ${image%@*}"
  if docker run --rm --env-file "$work/$env.env" -e DATABASE_URL=postgresql://check:check@localhost/check \
       "$image" python -c "from accounts_api.config import load_settings; load_settings()"; then
    echo "   ok"
  else
    echo "   FAILED: $env's config would stop accounts-api from starting (the error above names the variable)"
    failed=1
  fi
done
exit $failed
