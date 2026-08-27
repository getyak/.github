#!/usr/bin/env bash
set -euo pipefail

for required_command in gh jq ruby grep; do
  command -v "$required_command" >/dev/null || {
    echo "$required_command is required" >&2
    exit 2
  }
done

repository_root="$(cd "$(dirname "$BASH_SOURCE")/../.." && pwd)"
registry_path="$repository_root/automation/registry.yml"
organization="${1:-getyak}"
run_limit="${EVAL_HEALTH_RUN_LIMIT:-20}"

if [[ ! "$run_limit" =~ ^[1-9][0-9]*$ ]] || ((run_limit > 100)); then
  echo "EVAL_HEALTH_RUN_LIMIT must be an integer from 1 to 100" >&2
  exit 2
fi

audit_output_dir="$(mktemp -d "${TMPDIR:-/tmp}/getyak-eval-health.XXXXXX")"
trap 'rm -rf "$audit_output_dir"' EXIT

append_reason() {
  local reasons="$1"
  local value="$2"
  jq -cn --argjson reasons "$reasons" --arg value "$value" '$reasons + [$value]'
}

registry_records="$({
  ruby - "$registry_path" <<'RUBY'
require "base64"
require "json"
require "yaml"

registry = YAML.load_file(ARGV.fetch(0))
registry.fetch("repositories").each do |name, repository|
  next unless repository["lifecycle"] == "active"

  contract = repository.fetch("eval_contract")
  record = {
    name: name,
    maturity: contract.fetch("maturity"),
    primary_suite: contract.fetch("primary_suite"),
    ci_workflow: contract["ci_workflow"],
    ci_job: contract["ci_job"],
    ci_step: contract["ci_step"],
    artifact_prefix: contract["artifact_prefix"],
    artifact_partial_pattern: contract["artifact_partial_pattern"]
  }
  puts Base64.strict_encode64(JSON.generate(record))
end
RUBY
} )"

while IFS= read -r encoded_record; do
  [[ -n "$encoded_record" ]] || continue

  record="$(printf '%s' "$encoded_record" | base64 --decode)"
  repository_name="$(jq -r '.name' <<<"$record")"
  maturity="$(jq -r '.maturity' <<<"$record")"
  primary_suite="$(jq -r '.primary_suite' <<<"$record")"
  ci_workflow="$(jq -r '.ci_workflow // empty' <<<"$record")"
  ci_job="$(jq -r '.ci_job // empty' <<<"$record")"
  ci_step="$(jq -r '.ci_step // empty' <<<"$record")"
  artifact_prefix="$(jq -r '.artifact_prefix // empty' <<<"$record")"
  artifact_partial_pattern="$(jq -r '.artifact_partial_pattern // empty' <<<"$record")"
  repository="$organization/$repository_name"

  invalid_reasons='[]'
  partial_reasons='[]'
  default_branch=""
  suite_state="unavailable"
  workflow_state="not_declared"
  job_state="not_applicable"
  step_state="not_applicable"
  artifact_state="not_required"
  qualifying_run_id=""
  qualifying_run_url=""
  qualifying_run_sha=""
  artifact_name=""

  if repository_json="$(gh api "repos/$repository" 2>/dev/null)"; then
    default_branch="$(jq -r '.default_branch // empty' <<<"$repository_json")"
  else
    invalid_reasons="$(append_reason "$invalid_reasons" "repository_unavailable")"
  fi

  tree_json=''
  if [[ -n "$default_branch" ]] &&
    tree_json="$(gh api "repos/$repository/git/trees/$default_branch?recursive=1" 2>/dev/null)" &&
    jq -e '.truncated != true and (.tree | type == "array")' >/dev/null 2>&1 <<<"$tree_json"; then
    normalized_suite="${primary_suite%/}"
    if jq -e --arg path "$normalized_suite" '
      any(.tree[]?; .path == $path or (.path | startswith($path + "/")))
    ' >/dev/null <<<"$tree_json"; then
      suite_state="available"
    else
      suite_state="missing"
      invalid_reasons="$(append_reason "$invalid_reasons" "primary_suite_missing")"
    fi

    if [[ -n "$ci_workflow" ]]; then
      if jq -e --arg path "$ci_workflow" '
        any(.tree[]?; .type == "blob" and .path == $path)
      ' >/dev/null <<<"$tree_json"; then
        workflow_state="available"
      else
        workflow_state="missing"
        invalid_reasons="$(append_reason "$invalid_reasons" "ci_workflow_missing")"
      fi
    fi
  else
    invalid_reasons="$(append_reason "$invalid_reasons" "default_branch_tree_unavailable")"
  fi

  if [[ "$maturity" != "ci_gated" ]]; then
    partial_reasons="$(append_reason "$partial_reasons" "maturity_$maturity")"
  elif [[ "$workflow_state" == "available" ]]; then
    if [[ -z "$ci_job" || -z "$ci_step" ]]; then
      invalid_reasons="$(append_reason "$invalid_reasons" "ci_execution_metadata_missing")"
    else
      runs_json="$(gh run list \
        --repo "$repository" \
        --workflow "$ci_workflow" \
        --branch "$default_branch" \
        --limit "$run_limit" \
        --json databaseId,event,status,conclusion,headSha,url 2>/dev/null || printf '[]')"

      while IFS= read -r candidate_run_id; do
        [[ -n "$candidate_run_id" ]] || continue
        jobs_json="$(gh api \
          "repos/$repository/actions/runs/$candidate_run_id/jobs?per_page=100" \
          2>/dev/null || printf '{"jobs":[]}')"
        if jq -e --arg job "$ci_job" --arg step "$ci_step" '
          any(
            .jobs[]?;
            .name == $job and
            .conclusion == "success" and
            any(.steps[]?; .name == $step and .conclusion == "success")
          )
        ' >/dev/null <<<"$jobs_json"; then
          qualifying_run_id="$candidate_run_id"
          qualifying_run_url="$(jq -r --argjson id "$candidate_run_id" '.[] | select(.databaseId == $id) | .url' <<<"$runs_json")"
          qualifying_run_sha="$(jq -r --argjson id "$candidate_run_id" '.[] | select(.databaseId == $id) | .headSha' <<<"$runs_json")"
          job_state="success"
          step_state="success"
          break
        fi
      done < <(jq -r '.[] | select(.event != "pull_request" and .status == "completed" and .conclusion == "success") | .databaseId' <<<"$runs_json")

      if [[ -z "$qualifying_run_id" ]]; then
        job_state="missing_successful_run"
        step_state="missing_successful_run"
        invalid_reasons="$(append_reason "$invalid_reasons" "successful_eval_step_not_found")"
      fi
    fi
  fi

  if [[ -n "$qualifying_run_id" && -n "$artifact_prefix" ]]; then
    artifacts_json="$(gh api \
      "repos/$repository/actions/runs/$qualifying_run_id/artifacts?per_page=100" \
      2>/dev/null || printf '{"artifacts":[]}')"
    artifact_name="$(jq -r --arg prefix "$artifact_prefix" '
      [.artifacts[]? | select(.expired == false and (.name | startswith($prefix)))][0].name // empty
    ' <<<"$artifacts_json")"
    if [[ -z "$artifact_name" ]]; then
      artifact_state="missing"
      invalid_reasons="$(append_reason "$invalid_reasons" "eval_artifact_missing")"
    else
      artifact_directory="$audit_output_dir/$repository_name"
      mkdir -p "$artifact_directory"
      if gh run download "$qualifying_run_id" \
        --repo "$repository" \
        --name "$artifact_name" \
        --dir "$artifact_directory" >/dev/null 2>&1; then
        artifact_state="available"
        if [[ -n "$artifact_partial_pattern" ]] &&
          grep -Eirqs -- "$artifact_partial_pattern" "$artifact_directory"; then
          partial_reasons="$(append_reason "$partial_reasons" "artifact_contains_partial_coverage_marker")"
        fi
      else
        artifact_state="download_failed"
        invalid_reasons="$(append_reason "$invalid_reasons" "eval_artifact_download_failed")"
      fi
    fi
  fi

  if (( $(jq 'length' <<<"$invalid_reasons") > 0 )); then
    coverage_state="invalid"
  elif (( $(jq 'length' <<<"$partial_reasons") > 0 )); then
    coverage_state="partial"
  else
    coverage_state="complete"
  fi

  jq -cn \
    --arg observed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg repository "$repository" \
    --arg default_branch "$default_branch" \
    --arg maturity "$maturity" \
    --arg primary_suite "$primary_suite" \
    --arg suite_state "$suite_state" \
    --arg ci_workflow "$ci_workflow" \
    --arg workflow_state "$workflow_state" \
    --arg ci_job "$ci_job" \
    --arg job_state "$job_state" \
    --arg ci_step "$ci_step" \
    --arg step_state "$step_state" \
    --arg artifact_name "$artifact_name" \
    --arg artifact_state "$artifact_state" \
    --arg qualifying_run_id "$qualifying_run_id" \
    --arg qualifying_run_url "$qualifying_run_url" \
    --arg qualifying_run_sha "$qualifying_run_sha" \
    --arg coverage_state "$coverage_state" \
    --argjson invalid_reasons "$invalid_reasons" \
    --argjson partial_reasons "$partial_reasons" \
    '{
      observed_at: $observed_at,
      repository: $repository,
      default_branch: ($default_branch | if length > 0 then . else null end),
      maturity: $maturity,
      primary_suite: $primary_suite,
      suite_state: $suite_state,
      ci: {
        workflow: ($ci_workflow | if length > 0 then . else null end),
        workflow_state: $workflow_state,
        job: ($ci_job | if length > 0 then . else null end),
        job_state: $job_state,
        step: ($ci_step | if length > 0 then . else null end),
        step_state: $step_state,
        run_id: ($qualifying_run_id | if length > 0 then tonumber else null end),
        run_url: ($qualifying_run_url | if length > 0 then . else null end),
        head_sha: ($qualifying_run_sha | if length > 0 then . else null end)
      },
      artifact: {
        name: ($artifact_name | if length > 0 then . else null end),
        state: $artifact_state
      },
      coverage_state: $coverage_state,
      coverage_reasons: ($invalid_reasons + $partial_reasons)
    }'
done <<<"$registry_records"
