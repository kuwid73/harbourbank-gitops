#!/usr/bin/env bash
# Seal the Slack webhook URL that Alertmanager posts prod alerts to (run by the engineer).
#
# The URL comes from a Slack app's Incoming Webhook (https://hooks.slack.com/...). Anyone who has it can post
# to the channel, so it is a secret: it is read without echo, encrypted for this cluster's
# sealed-secrets controller, and only the SealedSecret is written to the repo. Commit that file
# through a PR; ArgoCD creates the Secret and Alertmanager reads it from a file.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=platform/manifests/monitoring/alertmanager-slack.sealedsecret.yaml

read -rsp "Slack webhook URL (input hidden): " url; echo
case "$url" in
  https://hooks.slack.com/*) ;;
  *) echo "expected a https://hooks.slack.com/... URL" >&2; exit 1 ;;
esac

{
  echo "# The Slack webhook URL Alertmanager posts prod alerts to, encrypted for this cluster's"
  echo "# sealed-secrets controller. Re-create it with bootstrap/seal-slack-webhook.sh."
  echo "---"
  printf '%s' "$url" | kubectl create secret generic alertmanager-slack -n monitoring \
      --from-file=webhook-url=/dev/stdin --dry-run=client -o yaml |
    kubeseal --controller-namespace kube-system --controller-name sealed-secrets-controller -o yaml
} > "$OUT"
unset url
echo "wrote $OUT (encrypted; safe to commit)"
