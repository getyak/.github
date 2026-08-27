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
command -v ruby >/dev/null || {
  echo "ruby is required" >&2
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

portfolio_default_branch_ruleset() {
  local repo="$1"
  local branch="$2"
  local rulesets_json ruleset_id ruleset_json
  local ruleset_details='[]'

  if [[ -z "$branch" ]] ||
    ! rulesets_json="$(gh api "repos/$repo/rulesets?includes_parents=true" 2>/dev/null)" ||
    ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$rulesets_json"; then
    printf '{"state":"unavailable","matching_count":0,"qualifying_count":0,"qualifying_rulesets":[],"insufficient_rulesets":[],"unexpected_bypass_actors":[]}\n'
    return
  fi

  while IFS= read -r ruleset_id; do
    [[ -n "$ruleset_id" ]] || continue
    if ! ruleset_json="$(gh api "repos/$repo/rulesets/$ruleset_id" 2>/dev/null)" ||
      ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$ruleset_json"; then
      printf '{"state":"unavailable","matching_count":0,"qualifying_count":0,"qualifying_rulesets":[],"insufficient_rulesets":[],"unexpected_bypass_actors":[]}\n'
      return
    fi
    ruleset_details="$(jq -cn \
      --argjson details "$ruleset_details" \
      --argjson ruleset "$ruleset_json" \
      '$details + [$ruleset]')"
  done < <(jq -r '.[]? | select(.target == "branch" and .enforcement == "active") | .id' <<<"$rulesets_json")

  jq -cn \
    --arg branch "$branch" \
    --argjson details "$ruleset_details" '
    [
      $details[]?
      | select(.target == "branch" and .enforcement == "active")
      | select(any(
          (.conditions.ref_name.include // [])[]?;
          . == "~DEFAULT_BRANCH" or . == ("refs/heads/" + $branch) or . == $branch
        ))
    ] as $matching |
    [
      $matching[]
      | select(any(.rules[]?; .type == "deletion"))
      | select(any(.rules[]?; .type == "non_fast_forward"))
      | select(any(
          .rules[]?;
          .type == "merge_queue" or
          (
            .type == "pull_request" and
            (.parameters.required_review_thread_resolution // false) == true and
            (.parameters.require_extra_approval_for_unattributed_changes // false) == true
          )
        ))
    ] as $qualifying |
    {
      state: "available",
      matching_count: ($matching | length),
      qualifying_count: ($qualifying | length),
      qualifying_rulesets: [
        $qualifying[]
        | {
            id,
            name,
            source_type,
            gate: (
              if any(.rules[]?; .type == "merge_queue") then "merge_queue"
              else "pull_request" end
            )
          }
      ],
      insufficient_rulesets: [
        $matching[] as $ruleset
        | select(any($qualifying[]?; .id == $ruleset.id) | not)
        | {id: $ruleset.id, name: $ruleset.name, source_type: $ruleset.source_type}
      ],
      unexpected_bypass_actors: [
        $matching[]
        | .id as $ruleset_id
        | .name as $ruleset_name
        | (.bypass_actors // [])[]?
        | select(.actor_type != "OrganizationAdmin")
        | {ruleset_id: $ruleset_id, ruleset_name: $ruleset_name, actor_type, actor_id, bypass_mode}
      ]
    }'
}

portfolio_workflow_supply_chain() {
  local repo="$1"
  local branch="$2"
  local tree_json workflow_records workflow_path blob_sha blob_json content matches line_number
  local action_lines action_line action_ref action_pattern action_pinned
  local findings='[]'
  local action_findings='[]'

  if [[ -z "$branch" ]] ||
    ! tree_json="$(gh api "repos/$repo/git/trees/$branch?recursive=1" 2>/dev/null)" ||
    ! jq -e '.truncated != true and (.tree | type == "array")' >/dev/null 2>&1 <<<"$tree_json"; then
    printf '{"state":"unavailable","remote_script_pipe_count":0,"findings":[],"external_action_refs":[],"expected_action_patterns":[],"unpinned_external_action_count":0,"unpinned_external_action_findings":[]}\n'
    return
  fi

  workflow_records="$(jq -r '
    .tree[]?
    | select(.type == "blob")
    | select(.path | test("^\\.github/workflows/.*\\.ya?ml$"))
    | [.path, .sha]
    | @tsv
  ' <<<"$tree_json")"

  while IFS=$'\t' read -r workflow_path blob_sha; do
    [[ -n "$workflow_path" && -n "$blob_sha" ]] || continue
    if ! blob_json="$(gh api "repos/$repo/git/blobs/$blob_sha" 2>/dev/null)" ||
      ! jq -e '.encoding == "base64" and (.content | type == "string")' >/dev/null 2>&1 <<<"$blob_json" ||
      ! content="$(jq -r 'select(.encoding == "base64") | .content // empty' <<<"$blob_json" \
        | tr -d '\r\n' \
        | base64 --decode 2>/dev/null)"; then
      printf '{"state":"unavailable","remote_script_pipe_count":0,"findings":[],"external_action_refs":[],"expected_action_patterns":[],"unpinned_external_action_count":0,"unpinned_external_action_findings":[]}\n'
      return
    fi

    matches="$(awk '
      function inspect(value, number, normalized) {
        normalized = tolower(value)
        sub(/^[[:space:]]+/, "", normalized)
        if (normalized ~ /^#/) return
        if (normalized ~ /(curl|wget)[^|]*\|[[:space:]\\]*(sudo[[:space:]]+)?(bash|sh|zsh)([[:space:];&]|$)/ || normalized ~ /(bash|sh|zsh)[[:space:]]*<\([[:space:]]*(curl|wget)([[:space:]]|$)/) print number
      }
      {
        value = $0
        sub(/\r$/, "", value)
        if (logical == "") start = NR
        logical = logical value
        if (logical ~ /\\[[:space:]]*$/) {
          sub(/\\[[:space:]]*$/, " ", logical)
          next
        }
        if (tolower(logical) ~ /(curl|wget)[^|]*\|[[:space:]]*$/) {
          logical = logical " "
          next
        }
        inspect(logical, start)
        logical = ""
      }
      END {
        if (logical != "") inspect(logical, start)
      }
    ' <<<"$content")"

    while IFS= read -r line_number; do
      [[ -n "$line_number" ]] || continue
      findings="$(jq -cn \
        --argjson findings "$findings" \
        --arg path "$workflow_path" \
        --argjson line "$line_number" \
        '$findings + [{path: $path, line: $line}]')"
    done <<<"$matches"

    action_lines="$(ruby -ne '
      if (match = $_.match(%r{^\s*-?\s*uses:\s*["\x27]?([^\s#"\x27]+)}))
        puts "#{$.}\t#{match[1]}"
      end
    ' <<<"$content")"

    while IFS=$'\t' read -r action_line action_ref; do
      [[ -n "$action_line" && -n "$action_ref" ]] || continue
      case "$action_ref" in
        ./* | docker://* | actions/* | github/*) continue ;;
      esac

      action_pattern="${action_ref%@*}@*"
      action_pinned=false
      if [[ "$action_ref" =~ @[0-9a-f]{40}$ ]]; then
        action_pinned=true
      fi
      action_findings="$(jq -cn \
        --argjson findings "$action_findings" \
        --arg path "$workflow_path" \
        --argjson line "$action_line" \
        --arg ref "$action_ref" \
        --arg pattern "$action_pattern" \
        --argjson pinned "$action_pinned" \
        '$findings + [{path: $path, line: $line, ref: $ref, pattern: $pattern, pinned: $pinned}]')"
    done <<<"$action_lines"
  done <<<"$workflow_records"

  jq -cn --argjson findings "$findings" --argjson action_findings "$action_findings" '{
    state: "available",
    remote_script_pipe_count: ($findings | length),
    findings: $findings,
    external_action_refs: ([$action_findings[].ref] | unique),
    expected_action_patterns: ([$action_findings[].pattern] | unique),
    unpinned_external_action_count: ([$action_findings[] | select(.pinned != true)] | length),
    unpinned_external_action_findings: ([$action_findings[] | select(.pinned != true)])
  }'
}

portfolio_inspect_repo() {
  local encoded="$1"
  local repo_json repo branch pushed_at recent_runs
  local dependabot code_scanning secret_scanning
  local repository_settings actions_permissions selected_actions workflow_permissions default_branch_ruleset workflow_supply_chain output_path

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
  if [[ "$(jq -r '.value.allowed_actions // ""' <<<"$actions_permissions")" == "selected" ]]; then
    selected_actions="$(portfolio_api_object "repos/$repo/actions/permissions/selected-actions")"
  else
    selected_actions='{"state":"not_applicable","value":null}'
  fi
  workflow_permissions="$(portfolio_api_object "repos/$repo/actions/permissions/workflow")"
  default_branch_ruleset="$(portfolio_default_branch_ruleset "$repo" "$branch")"
  workflow_supply_chain="$(portfolio_workflow_supply_chain "$repo" "$branch")"

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
    --argjson selected_actions "$selected_actions" \
    --argjson workflow_permissions "$workflow_permissions" \
    --argjson default_branch_ruleset "$default_branch_ruleset" \
    --argjson workflow_supply_chain "$workflow_supply_chain" \
    '($selected_actions.value.patterns_allowed // []) as $allowed_action_patterns |
    ($workflow_supply_chain.expected_action_patterns // []) as $expected_action_patterns |
    ([$expected_action_patterns[] as $pattern | select(($allowed_action_patterns | index($pattern)) == null) | $pattern]) as $missing_action_patterns |
    ([$allowed_action_patterns[] as $pattern | select(($expected_action_patterns | index($pattern)) == null) | $pattern]) as $unexpected_action_patterns |
    {
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
        selected_actions_state: $selected_actions.state,
        github_owned_actions_allowed: ($selected_actions.value.github_owned_allowed // null),
        verified_creator_actions_allowed: (
          if ($selected_actions.value | type) == "object" and
            ($selected_actions.value | has("verified_allowed"))
          then $selected_actions.value.verified_allowed
          else null end
        ),
        allowed_action_patterns: $allowed_action_patterns,
        workflow_permissions_state: $workflow_permissions.state,
        default_workflow_permissions: ($workflow_permissions.value.default_workflow_permissions // "unknown"),
        actions_can_approve_pull_request_reviews: ($workflow_permissions.value.can_approve_pull_request_reviews // false)
      },
      default_branch_ruleset: $default_branch_ruleset,
      workflow_supply_chain: $workflow_supply_chain,
      actions_allowlist: {
        state: $selected_actions.state,
        expected_patterns: $expected_action_patterns,
        allowed_patterns: $allowed_action_patterns,
        missing_patterns: $missing_action_patterns,
        unexpected_patterns: $unexpected_action_patterns
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
        if $actions_permissions.state == "available" and
          ($actions_permissions.value.allowed_actions // "unknown") != "selected"
        then "actions_allowlist_not_selected" else empty end,
        if $actions_permissions.state == "available" and
          ($actions_permissions.value.allowed_actions // "unknown") == "selected" and
          $selected_actions.state != "available"
        then "actions_selected_policy_unavailable" else empty end,
        if $selected_actions.state == "available" and
          ($selected_actions.value.github_owned_allowed // false) != true
        then "github_owned_actions_not_allowed" else empty end,
        if $selected_actions.state == "available" and
          ($selected_actions.value.verified_allowed // false) != false
        then "verified_creator_actions_broadly_allowed" else empty end,
        if $workflow_supply_chain.state == "available" and
          ($workflow_supply_chain.unpinned_external_action_count // 0) > 0
        then "workflow_external_action_not_sha_pinned" else empty end,
        if $workflow_supply_chain.state == "available" and
          $selected_actions.state == "available" and
          ($missing_action_patterns | length) > 0
        then "actions_allowlist_missing_pattern" else empty end,
        if $workflow_supply_chain.state == "available" and
          $selected_actions.state == "available" and
          ($unexpected_action_patterns | length) > 0
        then "actions_allowlist_unexpected_pattern" else empty end,
        if $workflow_permissions.state != "available" then
          "workflow_permissions_unavailable"
        else empty end,
        if $workflow_permissions.state == "available" and
          ($workflow_permissions.value.default_workflow_permissions // "unknown") != "read"
        then "default_workflow_permissions_not_read" else empty end,
        if $default_branch_ruleset.state != "available" then
          "default_branch_ruleset_unavailable"
        else empty end,
        if $default_branch_ruleset.state == "available" and
          ($default_branch_ruleset.qualifying_count // 0) == 0
        then "default_branch_ruleset_missing" else empty end,
        if $default_branch_ruleset.state == "available" and
          (($default_branch_ruleset.unexpected_bypass_actors // []) | length) > 0
        then "default_branch_ruleset_unexpected_bypass" else empty end,
        if $workflow_supply_chain.state != "available" then
          "workflow_supply_chain_scan_unavailable"
        else empty end,
        if $workflow_supply_chain.state == "available" and
          $workflow_supply_chain.remote_script_pipe_count > 0
        then "workflow_remote_script_pipe_present" else empty end
      ])
    }' >"$output_path"
}

export -f portfolio_api_collection portfolio_api_object portfolio_default_branch_ruleset portfolio_workflow_supply_chain portfolio_inspect_repo
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
