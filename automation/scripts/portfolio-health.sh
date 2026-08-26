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
concurrency="${PORTFOLIO_HEALTH_CONCURRENCY:-6}"
if [[ ! "$concurrency" =~ ^[1-9][0-9]*$ ]] || ((concurrency > 16)); then
  echo "PORTFOLIO_HEALTH_CONCURRENCY must be an integer from 1 to 16" >&2
  exit 2
fi
if cutoff_epoch="$(date -u -v-7d +%s 2>/dev/null)"; then
  :
else
  cutoff_epoch="$(date -u -d '7 days ago' +%s)"
fi

portfolio_output_dir="$(mktemp -d "${TMPDIR:-/tmp}/getyak-portfolio-health.XXXXXX")"
trap 'rm -rf "$portfolio_output_dir"' EXIT

portfolio_api_collection() {
  local endpoint="$1"
  local pages
  if pages="$(gh api --paginate --slurp "$endpoint" 2>/dev/null)"; then
    jq -c '{state: "enabled", items: (add // [])}' <<<"$pages"
  else
    printf '{"state":"unavailable","items":[]}\n'
  fi
}

portfolio_api_object() {
  local endpoint="$1"
  local value
  if value="$(gh api "$endpoint" 2>/dev/null)" && jq -e . >/dev/null 2>&1 <<<"$value"; then
    jq -cn --argjson value "$value" '{state: "available", value: $value}'
  else
    printf '{"state":"unavailable","value":null}\n'
  fi
}

portfolio_inspect_repo() {
  local encoded="$1"
  local repo_json repo branch pushed_at recent_runs
  local dependabot code_scanning secret_scanning
  local repository_settings actions_permissions workflow_permissions output_path

  repo_json="$(printf '%s' "$encoded" | base64 --decode)"
  repo="$(jq -r '.nameWithOwner' <<<"$repo_json")"
  branch="$(jq -r '.defaultBranchRef.name // ""' <<<"$repo_json")"
  pushed_at="$(jq -r '.pushedAt // ""' <<<"$repo_json")"

  recent_runs="$(gh run list -R "$repo" --limit 20 \
    --json databaseId,name,status,conclusion,event,headBranch,headSha,createdAt,url \
    2>/dev/null || printf '[]')"

  dependabot="$(portfolio_api_collection \
    "repos/$repo/dependabot/alerts?state=open&per_page=100")"
  code_scanning="$(portfolio_api_collection \
    "repos/$repo/code-scanning/alerts?state=open&per_page=100")"
  secret_scanning="$(portfolio_api_collection \
    "repos/$repo/secret-scanning/alerts?state=open&per_page=100")"
  repository_settings="$(portfolio_api_object "repos/$repo")"
  actions_permissions="$(portfolio_api_object "repos/$repo/actions/permissions")"
  workflow_permissions="$(portfolio_api_object "repos/$repo/actions/permissions/workflow")"

  output_path="$portfolio_output_dir/${repo//\//__}.json"
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
    --argjson repository_settings "$repository_settings" \
    --argjson actions_permissions "$actions_permissions" \
    --argjson workflow_permissions "$workflow_permissions" \
    '{
      observed_at: $observed_at,
      repository: $repository,
      default_branch: $default_branch,
      pushed_at: $pushed_at,
      latest_run: ($recent_runs[0] // null),
      latest_default_branch_run: ([
        $recent_runs[]?
        | select((.headBranch // "") == $default_branch)
        | select(.event != "pull_request" and .event != "dynamic")
      ][0] // null),
      failure_filter: "latest_decisive_default_branch_non_dynamic",
      recent_failed_runs: ([
        $recent_runs[]? as $failed
        | select($failed.conclusion == "failure")
        | select(($failed.createdAt | fromdateiso8601) >= $cutoff_epoch)
        | select(($failed.headBranch // "") == $default_branch)
        | select($failed.event != "pull_request" and $failed.event != "dynamic")
        | select(([
            $recent_runs[]? as $later
            | select($later.name == $failed.name)
            | select(($later.headBranch // "") == ($failed.headBranch // ""))
            | select($later.event == $failed.event)
            | select(
                $later.conclusion == "failure" or
                $later.conclusion == "success"
              )
            | select(
                $later.createdAt > $failed.createdAt or
                (
                  $later.createdAt == $failed.createdAt and
                  $later.databaseId > $failed.databaseId
                )
              )
          ] | length) == 0)
        | $failed
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
        code_scanning_high_or_critical: ([
          $code_scanning.items[]?
          | select(
              .rule.security_severity_level == "high" or
              .rule.security_severity_level == "critical"
            )
        ] | length),
        code_scanning_by_severity: (
          reduce $code_scanning.items[]? as $alert (
            {critical: 0, high: 0, medium: 0, low: 0, unknown: 0};
            ($alert.rule.security_severity_level // "unknown") as $severity
            | if $severity == "critical" then
                .critical += 1
              elif $severity == "high" then
                .high += 1
              elif $severity == "medium" then
                .medium += 1
              elif $severity == "low" then
                .low += 1
              else
                .unknown += 1
              end
          )
        ),
        secret_scanning_state: $secret_scanning.state,
        secret_scanning: ($secret_scanning.items | length)
      },
      security_configuration: {
        repository_settings_state: $repository_settings.state,
        secret_scanning: ($repository_settings.value.security_and_analysis.secret_scanning.status // "unknown"),
        secret_scanning_push_protection: ($repository_settings.value.security_and_analysis.secret_scanning_push_protection.status // "unknown"),
        dependabot_security_updates: ($repository_settings.value.security_and_analysis.dependabot_security_updates.status // "unknown"),
        actions_permissions_state: $actions_permissions.state,
        actions_enabled: ($actions_permissions.value.enabled // null),
        actions_allowed: ($actions_permissions.value.allowed_actions // "unknown"),
        actions_sha_pinning_required: ($actions_permissions.value.sha_pinning_required // false),
        workflow_permissions_state: $workflow_permissions.state,
        default_workflow_permissions: ($workflow_permissions.value.default_workflow_permissions // "unknown"),
        actions_can_approve_pull_request_reviews: ($workflow_permissions.value.can_approve_pull_request_reviews // false)
      },
      configuration_drift: ([
        if $repository_settings.state != "available" then
          "repository_settings_unavailable"
        else empty end,
        if $repository_settings.state == "available" and
          ($repository_settings.value.security_and_analysis.secret_scanning.status // "unknown") != "enabled"
        then "secret_scanning_not_enabled" else empty end,
        if $repository_settings.state == "available" and
          ($repository_settings.value.security_and_analysis.secret_scanning_push_protection.status // "unknown") != "enabled"
        then "secret_scanning_push_protection_not_enabled" else empty end,
        if $repository_settings.state == "available" and
          ($repository_settings.value.security_and_analysis.dependabot_security_updates.status // "unknown") != "enabled"
        then "dependabot_security_updates_not_enabled" else empty end,
        if $actions_permissions.state != "available" then
          "actions_permissions_unavailable"
        else empty end,
        if $actions_permissions.state == "available" and
          ($actions_permissions.value.sha_pinning_required // false) != true
        then "actions_sha_pinning_not_required" else empty end,
        if $workflow_permissions.state != "available" then
          "workflow_permissions_unavailable"
        else empty end,
        if $workflow_permissions.state == "available" and
          ($workflow_permissions.value.default_workflow_permissions // "unknown") != "read"
        then "default_workflow_permissions_not_read" else empty end
      ])
    }' >"$output_path"
}

export -f portfolio_api_collection portfolio_api_object portfolio_inspect_repo
export now cutoff_epoch portfolio_output_dir

repo_records="$(gh repo list "$org" --visibility public --no-archived --limit 200 \
  --json nameWithOwner,isFork,defaultBranchRef,pushedAt \
  --jq '.[] | select(.isFork == false) | @base64')"

if [[ -z "$repo_records" ]]; then
  exit 0
fi

printf '%s\n' "$repo_records" \
  | xargs -P "$concurrency" -n 1 bash -c 'portfolio_inspect_repo "$1"' _

for output_path in "$portfolio_output_dir"/*.json; do
  cat "$output_path"
done
