#!/usr/bin/env bash
set -euo pipefail

command -v gh >/dev/null || {
  echo "gh is required" >&2
  exit 2
}
command -v jq >/dev/null || {
  echo "jq is required" >&2
  exit 2
}

org="${1:-getyak}"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if cutoff_epoch="$(date -u -v-7d +%s 2>/dev/null)"; then
  :
else
  cutoff_epoch="$(date -u -d '7 days ago' +%s)"
fi

api_collection() {
  local endpoint="$1"
  local pages
  if pages="$(gh api --paginate --slurp "$endpoint" 2>/dev/null)"; then
    jq -c '{state: "enabled", items: (add // [])}' <<<"$pages"
  else
    printf '{"state":"unavailable","items":[]}\n'
  fi
}

gh repo list "$org" --visibility public --no-archived --limit 200 \
  --json nameWithOwner,isFork,defaultBranchRef,pushedAt \
  --jq '.[] | select(.isFork == false) | @base64' |
while IFS= read -r encoded; do
  repo_json="$(printf '%s' "$encoded" | base64 --decode)"
  repo="$(jq -r '.nameWithOwner' <<<"$repo_json")"
  branch="$(jq -r '.defaultBranchRef.name // ""' <<<"$repo_json")"
  pushed_at="$(jq -r '.pushedAt // ""' <<<"$repo_json")"

  recent_runs="$(gh run list -R "$repo" --limit 20 \
    --json databaseId,name,status,conclusion,event,createdAt,url 2>/dev/null || printf '[]')"

  dependabot="$(api_collection \
    "repos/$repo/dependabot/alerts?state=open&per_page=100")"
  code_scanning="$(api_collection \
    "repos/$repo/code-scanning/alerts?state=open&per_page=100")"
  secret_scanning="$(api_collection \
    "repos/$repo/secret-scanning/alerts?state=open&per_page=100")"

  jq -cn \
    --arg observed_at "$now" \
    --argjson cutoff_epoch "$cutoff_epoch" \
    --arg repository "$repo" \
    --arg default_branch "$branch" \
    --arg pushed_at "$pushed_at" \
    --argjson recent_runs "$recent_runs" \
    --argjson dependabot "$dependabot" \
    --argjson code_scanning "$code_scanning" \
    --argjson secret_scanning "$secret_scanning" \
    '{
      observed_at: $observed_at,
      repository: $repository,
      default_branch: $default_branch,
      pushed_at: $pushed_at,
      latest_run: ($recent_runs[0] // null),
      recent_failed_runs: ([
        $recent_runs[]?
        | select(.conclusion == "failure")
        | select((.createdAt | fromdateiso8601) >= $cutoff_epoch)
      ]),
      open_alerts: {
        dependabot_state: $dependabot.state,
        dependabot_total: ($dependabot.items | length),
        dependabot_high_or_critical: ([
          $dependabot.items[]?
          | select(.security_advisory.severity == "high" or .security_advisory.severity == "critical")
        ] | length),
        code_scanning_state: $code_scanning.state,
        code_scanning: ($code_scanning.items | length),
        secret_scanning_state: $secret_scanning.state,
        secret_scanning: ($secret_scanning.items | length)
      }
    }'
done
