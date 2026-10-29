#!/usr/bin/env bash
# Change control for the Harbour Bank repos, applied to GitHub (run by a repo admin; re-runnable).
#
# harbourbank-gitops (what runs where):
#   * main changes only through pull requests with 1 approval; paths in .github/CODEOWNERS
#     (everything that reaches production) need a code owner's approval; new commits
#     dismiss approvals; squash merges only (one revertable commit per change)
#   * exceptions: harbourbank-app CI's deploy key pushes dev image bumps directly;
#     admins may merge a PR without approval (recorded as "bypass") but never push directly
#   * GitHub Actions may open PRs (the promote workflow)
# harbourbank-app (the code) and harbourbank-ops-mcp (the agents' read-only MCP server):
#   * main changes only through pull requests with 1 approval and a passing `test` check;
#     squash merges only; admins may bypass on a PR (recorded), never push directly
# All: no force-push to or deletion of main; merged branches are deleted.
#
# Note: GitHub ignores "require code owner review" unless at least 1 approval is required.
# Verify enforcement in Settings -> Rules -> Insights (each merge shows pass/bypass/fail).
set -euo pipefail
OWNER=kuwid73
RULESET_NAME="main: reviewed changes only"
ADMIN_ROLE_ID=5         # built-in repository role "admin"
ACTIONS_APP_ID=15368    # GitHub Actions, the source of the `test` status check

apply_ruleset() {  # repo bypass-actors-json extra-rules-json
  local repo=$1 ruleset id
  ruleset=$(cat <<JSON
{
  "name": "$RULESET_NAME",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "bypass_actors": $2,
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    { "type": "pull_request", "parameters": {
        "required_approving_review_count": 1,
        "require_code_owner_review": true,
        "dismiss_stale_reviews_on_push": true,
        "require_last_push_approval": false,
        "required_review_thread_resolution": false,
        "allowed_merge_methods": ["squash"]
    } }
    $3
  ]
}
JSON
)
  id=$(gh api "repos/$repo/rulesets" --jq ".[] | select(.name == \"$RULESET_NAME\") | .id")
  if [[ -n "$id" ]]; then
    gh api -X PUT "repos/$repo/rulesets/$id" --input - <<<"$ruleset" --silent
  else
    gh api -X POST "repos/$repo/rulesets" --input - <<<"$ruleset" --silent
  fi
  gh api -X PATCH "repos/$repo" -F delete_branch_on_merge=true --silent
}

admin_on_prs='{ "actor_type": "RepositoryRole", "actor_id": '$ADMIN_ROLE_ID', "bypass_mode": "pull_request" }'

apply_ruleset "$OWNER/harbourbank-gitops" \
  "[ { \"actor_type\": \"DeployKey\", \"bypass_mode\": \"always\" }, $admin_on_prs ]" ""
gh api -X PUT "repos/$OWNER/harbourbank-gitops/actions/permissions/workflow" \
  -f default_workflow_permissions=read -F can_approve_pull_request_reviews=true

for repo in harbourbank-app harbourbank-ops-mcp; do
  apply_ruleset "$OWNER/$repo" "[ $admin_on_prs ]" ',
    { "type": "required_status_checks", "parameters": {
        "strict_required_status_checks_policy": false,
        "required_status_checks": [ { "context": "test", "integration_id": '$ACTIONS_APP_ID' } ]
    } }'
done

echo "Applied. Current state:"
for repo in harbourbank-gitops harbourbank-app harbourbank-ops-mcp; do
  gh api "repos/$OWNER/$repo/rulesets" --jq '.[].id' | while read -r id; do
    gh api "repos/$OWNER/$repo/rulesets/$id" --jq "\"  $repo: \" + .name + \" [\" + .enforcement + \"] rules=\" + ([.rules[].type] | join(\",\")) + \" approvals=\" + ((.rules[] | select(.type==\"pull_request\") | .parameters.required_approving_review_count) | tostring)"
  done
done
gh api "repos/$OWNER/harbourbank-gitops/actions/permissions/workflow" --jq '"  harbourbank-gitops: actions can open PRs: \(.can_approve_pull_request_reviews)"'
