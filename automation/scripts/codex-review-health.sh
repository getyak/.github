#!/usr/bin/env bash
set -euo pipefail

for required_command in gh jq ruby base64 grep; do
  command -v "$required_command" >/dev/null || {
    echo "$required_command is required" >&2
    exit 2
  }
done

repository_root="$(cd "$(dirname "$BASH_SOURCE")/../.." && pwd)"
targets_path="${CODEX_TARGETS_PATH:-$repository_root/automation/codex-targets.yml}"
retry_delay="${CODEX_REVIEW_API_RETRY_DELAY_SECONDS:-1}"

api_json() {
  local endpoint="$1"
  local attempt output
  for attempt in 1 2 3; do
    if output="$(gh api "$endpoint" 2>/dev/null)" && jq -e . >/dev/null 2>&1 <<<"$output"; then
      printf '%s\n' "$output"
      return 0
    fi
    if ((attempt < 3)); then
      sleep "$retry_delay"
    fi
  done
  return 1
}

target_records="$({
  ruby - "$targets_path" <<'RUBY'
require "base64"
require "json"
require "yaml"

YAML.load_file(ARGV.fetch(0)).fetch("targets").each do |name, target|
  puts Base64.strict_encode64(JSON.generate(
    name: name,
    repository: target.fetch("repository"),
    desired_environment: target.fetch("desired_environment"),
    integration_state: target.fetch("integration_state"),
    review_mode: target.fetch("review_mode")
  ))
end
RUBY
} )"

while IFS= read -r encoded_record; do
  [[ -n "$encoded_record" ]] || continue
  record="$(printf '%s' "$encoded_record" | base64 --decode)"
  repository="$(jq -r '.repository' <<<"$record")"
  desired_environment="$(jq -r '.desired_environment' <<<"$record")"
  integration_state="$(jq -r '.integration_state' <<<"$record")"
  review_mode="$(jq -r '.review_mode' <<<"$record")"
  default_branch=""
  repository_state="unavailable"
  agents_files='[]'
  review_rules_files='[]'
  review_debt='[]'

  if repository_json="$(api_json "repos/$repository")"; then
    default_branch="$(jq -r '.default_branch // empty' <<<"$repository_json")"
    repository_state="available"
  else
    review_debt='["repository_unavailable"]'
  fi

  if [[ -n "$default_branch" ]]; then
    if tree_json="$(api_json "repos/$repository/git/trees/$default_branch?recursive=1")" &&
      jq -e '.truncated != true and (.tree | type == "array")' >/dev/null 2>&1 <<<"$tree_json"; then
      agents_files="$(jq -c '[.tree[]? | select(.type == "blob" and (.path | test("(^|/)AGENTS\\.md$"))) | .path] | sort' <<<"$tree_json")"

      while IFS=$'\t' read -r agents_path blob_sha; do
        [[ -n "$agents_path" && -n "$blob_sha" ]] || continue
        if blob_json="$(api_json "repos/$repository/git/blobs/$blob_sha")"; then
          content="$(jq -r '.content // empty' <<<"$blob_json" | tr -d '\n' | base64 --decode 2>/dev/null || true)"
          if grep -Eq '^##[[:space:]]+Code Review Rules[[:space:]]*$' <<<"$content"; then
            review_rules_files="$(jq -c --arg path "$agents_path" '. + [$path]' <<<"$review_rules_files")"
          fi
        else
          review_debt="$(jq -c '. + ["agents_file_unavailable"] | unique' <<<"$review_debt")"
        fi
      done < <(jq -r '.tree[]? | select(.type == "blob" and (.path | test("(^|/)AGENTS\\.md$"))) | [.path, .sha] | @tsv' <<<"$tree_json")
    else
      review_debt="$(jq -c '. + ["default_branch_tree_unavailable"] | unique' <<<"$review_debt")"
    fi
  fi

  if [[ "$integration_state" != "ready" ]]; then
    review_debt="$(jq -c '. + ["codex_slack_environment_not_ready"] | unique' <<<"$review_debt")"
  fi
  if [[ "$(jq 'length' <<<"$agents_files")" == "0" ]]; then
    review_debt="$(jq -c '. + ["agents_instructions_missing"] | unique' <<<"$review_debt")"
  elif [[ "$(jq 'length' <<<"$review_rules_files")" == "0" ]]; then
    review_debt="$(jq -c '. + ["code_review_rules_missing"] | unique' <<<"$review_debt")"
  fi

  jq -cn \
    --arg observed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg repository "$repository" \
    --arg repository_state "$repository_state" \
    --arg default_branch "$default_branch" \
    --arg desired_environment "$desired_environment" \
    --arg integration_state "$integration_state" \
    --arg review_mode "$review_mode" \
    --argjson agents_files "$agents_files" \
    --argjson review_rules_files "$review_rules_files" \
    --argjson review_debt "$review_debt" \
    '{
      observed_at: $observed_at,
      repository: $repository,
      repository_state: $repository_state,
      default_branch: ($default_branch | if length > 0 then . else null end),
      desired_environment: $desired_environment,
      integration_state: $integration_state,
      review_mode: $review_mode,
      agents_files: $agents_files,
      code_review_rules_files: $review_rules_files,
      review_debt: $review_debt
    }'
done <<<"$target_records"
