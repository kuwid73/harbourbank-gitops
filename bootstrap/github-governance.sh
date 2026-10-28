#!/usr/bin/env bash
# Change control for harbourbank-gitops, applied to the GitHub repo (run by a repo admin; re-runnable).
#
#   * main changes only through pull requests; paths in .github/CODEOWNERS (everything
#     that reaches production) need a code owner's approval; new commits dismiss approvals
#   * no force-push to or deletion of main
#   * exceptions: harbourbank-app CI's deploy key pushes dev image bumps directly;
#     admins may merge a PR without approval (recorded by GitHub) but never push directly
#   * GitHub Actions may open PRs (the promote workflow); merged branches are deleted
set -euo pipefail
REPO=kuwid73/harbourbank-gitops
RULESET_NAME="main: reviewed changes only"

gh api -X PUT "repos/$REPO/actions/permissions/workflow" \
  -f default_workflow_permissions=read -F can_approve_pull_request_reviews=true
gh api -X PATCH "repos/$REPO" -F delete_branch_on_merge=true --silent

ruleset=$(cat <<JSON
{
  "name": "$RULESET_NAME",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "bypass_actors": [
    { "actor_type": "DeployKey", "bypass_mode": "always" },
    { "actor_type": "RepositoryRole", "actor_id": 5, "bypass_mode": "pull_request" }
  ],
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    { "type": "pull_request", "parameters": {
        "required_approving_review_count": 0,
        "require_code_owner_review": true,
        "dismiss_stale_reviews_on_push": true,
        "require_last_push_approval": false,
        "required_review_thread_resolution": false
    } }
  ]
}
JSON
)
id=$(gh api "repos/$REPO/rulesets" --jq ".[] | select(.name == \"$RULESET_NAME\") | .id")
if [[ -n "$id" ]]; then
  gh api -X PUT "repos/$REPO/rulesets/$id" --input - <<<"$ruleset" --silent
else
  gh api -X POST "repos/$REPO/rulesets" --input - <<<"$ruleset" --silent
fi

echo "Applied. Current state:"
gh api "repos/$REPO/rulesets" --jq '.[] | "  ruleset: \(.name) [\(.enforcement)]"'
gh api "repos/$REPO/actions/permissions/workflow" --jq '"  actions can open PRs: \(.can_approve_pull_request_reviews)"'
gh api "repos/$REPO" --jq '"  delete branch on merge: \(.delete_branch_on_merge)"'
