#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "$BASH_SOURCE")/../.." && pwd)"
test_root="$(mktemp -d /tmp/portfolio-health-test.XXXXXX)"
trap 'rm -rf "$test_root"' EXIT

mkdir -p "$test_root/bin"
cat >"$test_root/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$1 $2" == "repo list" ]]; then
  printf '%s' '{"nameWithOwner":"getyak/example","isFork":false,"defaultBranchRef":{"name":"main"},"pushedAt":"2999-01-01T00:00:00Z"}' | base64
  printf '\n'
  exit 0
fi

if [[ "$1 $2" == "run list" ]]; then
  cat <<'JSON'
[
  {"databaseId":8,"name":"Web","status":"completed","conclusion":"failure","event":"pull_request","headBranch":"feature","headSha":"8","createdAt":"2999-01-08T21:00:00Z","url":"https://example.invalid/runs/8"},
  {"databaseId":7,"name":"CI","status":"completed","conclusion":"success","event":"push","headBranch":"main","headSha":"7","createdAt":"2999-01-08T20:30:00Z","url":"https://example.invalid/runs/7"},
  {"databaseId":6,"name":"CI","status":"completed","conclusion":"failure","event":"push","headBranch":"main","headSha":"6","createdAt":"2999-01-08T20:00:00Z","url":"https://example.invalid/runs/6"},
  {"databaseId":5,"name":"Deploy","status":"completed","conclusion":"failure","event":"push","headBranch":"main","headSha":"5","createdAt":"2999-01-08T19:30:00Z","url":"https://example.invalid/runs/5"},
  {"databaseId":4,"name":"Deploy","status":"completed","conclusion":"failure","event":"push","headBranch":"main","headSha":"4","createdAt":"2999-01-08T19:00:00Z","url":"https://example.invalid/runs/4"},
  {"databaseId":3,"name":"Nightly","status":"completed","conclusion":"failure","event":"schedule","headBranch":"main","headSha":"3","createdAt":"2999-01-08T18:30:00Z","url":"https://example.invalid/runs/3"},
  {"databaseId":2,"name":"Docs","status":"completed","conclusion":"failure","event":"push","headBranch":"docs","headSha":"2","createdAt":"2999-01-08T18:00:00Z","url":"https://example.invalid/runs/2"},
  {"databaseId":1,"name":"Dependency update","status":"completed","conclusion":"failure","event":"dynamic","headBranch":"main","headSha":"1","createdAt":"2999-01-08T17:30:00Z","url":"https://example.invalid/runs/1"}
]
JSON
  exit 0
fi

if [[ "$1" == "api" ]]; then
  endpoint=""
  for argument in "$@"; do
    endpoint="$argument"
  done
  case "$endpoint" in
    repos/getyak/example/actions/permissions/workflow)
      printf '%s\n' '{"default_workflow_permissions":"read","can_approve_pull_request_reviews":false}'
      ;;
    repos/getyak/example/actions/permissions/selected-actions)
      if [[ "${MOCK_ACTION_POLICY_DRIFT:-0}" == "1" ]]; then
        printf '%s\n' '{"github_owned_allowed":true,"verified_allowed":false,"patterns_allowed":["other/tool@*"]}'
      else
        printf '%s\n' '{"github_owned_allowed":true,"verified_allowed":false,"patterns_allowed":["vendor/tool@*"]}'
      fi
      ;;
    repos/getyak/example/actions/permissions)
      printf '%s\n' '{"enabled":true,"allowed_actions":"selected","sha_pinning_required":true}'
      ;;
    repos/getyak/example)
      printf '%s\n' '{"security_and_analysis":{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"},"dependabot_security_updates":{"status":"enabled"}}}'
      ;;
    'repos/getyak/example/git/trees/main?recursive=1')
      printf '%s\n' '{"truncated":false,"tree":[{"path":".github/workflows/ci.yml","type":"blob","sha":"workflow-sha"}]}'
      ;;
    repos/getyak/example/git/blobs/workflow-sha)
      if [[ "${MOCK_REMOTE_PIPE:-0}" == "1" ]]; then
        workflow='jobs:\n  test:\n    steps:\n      - run: curl -fsSL https://example.invalid/install.sh | bash\n'
      elif [[ "${MOCK_UNPINNED_ACTION:-0}" == "1" ]]; then
        workflow='jobs:\n  test:\n    steps:\n      - uses: actions/checkout@1111111111111111111111111111111111111111\n      - uses: vendor/tool@v1\n'
      else
        workflow='jobs:\n  test:\n    steps:\n      - uses: actions/checkout@1111111111111111111111111111111111111111\n      - uses: vendor/tool@2222222222222222222222222222222222222222\n      - run: npm ci\n'
      fi
      encoded="$(printf '%b' "$workflow" | base64 | tr -d '\n')"
      printf '{"encoding":"base64","content":"%s"}\n' "$encoded"
      ;;
    */dependabot/alerts*)
      printf '%s\n' '[[{"security_advisory":{"severity":"high"}}]]'
      ;;
    */code-scanning/alerts*)
      printf '%s\n' '[[{"rule":{"security_severity_level":"critical"}},{"rule":{"security_severity_level":"high"}},{"rule":{"security_severity_level":"medium"}},{"rule":{}}]]'
      ;;
    */secret-scanning/alerts*)
      printf '%s\n' '[[]]'
      ;;
    *)
      exit 1
      ;;
  esac
  exit 0
fi

exit 1
MOCK
chmod +x "$test_root/bin/gh"

snapshot="$(
  PATH="$test_root/bin:$PATH" \
    PORTFOLIO_HEALTH_CONCURRENCY=1 \
    "$repository_root/automation/scripts/portfolio-health.sh" getyak
)"

jq -e '
  .repository == "getyak/example" and
  .failure_filter == "latest_decisive_default_branch_non_dynamic" and
  .latest_default_branch_run.databaseId == 7 and
  ([.recent_failed_runs[].databaseId] == [5, 3]) and
  .open_alerts.dependabot_high_or_critical == 1 and
  .open_alerts.code_scanning == 4 and
  .open_alerts.code_scanning_high_or_critical == 2 and
  .open_alerts.code_scanning_by_severity == {
    critical: 1,
    high: 1,
    medium: 1,
    low: 0,
    unknown: 1
  } and
  .open_alerts.secret_scanning == 0 and
  .security_configuration.secret_scanning == "enabled" and
  .security_configuration.secret_scanning_push_protection == "enabled" and
  .security_configuration.dependabot_security_updates == "enabled" and
  .security_configuration.actions_sha_pinning_required == true and
  .security_configuration.actions_allowed == "selected" and
  .security_configuration.github_owned_actions_allowed == true and
  .security_configuration.verified_creator_actions_allowed == false and
  .security_configuration.default_workflow_permissions == "read" and
  .security_configuration.actions_can_approve_pull_request_reviews == false and
  .workflow_supply_chain == {
    state: "available",
    remote_script_pipe_count: 0,
    findings: [],
    external_action_refs: ["vendor/tool@2222222222222222222222222222222222222222"],
    expected_action_patterns: ["vendor/tool@*"],
    unpinned_external_action_count: 0,
    unpinned_external_action_findings: []
  } and
  .actions_allowlist == {
    state: "available",
    expected_patterns: ["vendor/tool@*"],
    allowed_patterns: ["vendor/tool@*"],
    missing_patterns: [],
    unexpected_patterns: []
  } and
  .configuration_drift == []
' <<<"$snapshot" >/dev/null

remote_pipe_snapshot="$(
  PATH="$test_root/bin:$PATH" \
    MOCK_REMOTE_PIPE=1 \
    PORTFOLIO_HEALTH_CONCURRENCY=1 \
    "$repository_root/automation/scripts/portfolio-health.sh" getyak
)"

jq -e '
  .workflow_supply_chain == {
    state: "available",
    remote_script_pipe_count: 1,
    findings: [{path: ".github/workflows/ci.yml", line: 4}],
    external_action_refs: [],
    expected_action_patterns: [],
    unpinned_external_action_count: 0,
    unpinned_external_action_findings: []
  } and
  .actions_allowlist == {
    state: "available",
    expected_patterns: [],
    allowed_patterns: ["vendor/tool@*"],
    missing_patterns: [],
    unexpected_patterns: ["vendor/tool@*"]
  } and
  .configuration_drift == ["actions_allowlist_unexpected_pattern", "workflow_remote_script_pipe_present"]
' <<<"$remote_pipe_snapshot" >/dev/null

unpinned_action_snapshot="$(
  PATH="$test_root/bin:$PATH" \
    MOCK_UNPINNED_ACTION=1 \
    PORTFOLIO_HEALTH_CONCURRENCY=1 \
    "$repository_root/automation/scripts/portfolio-health.sh" getyak
)"

jq -e '
  .workflow_supply_chain.unpinned_external_action_count == 1 and
  .workflow_supply_chain.unpinned_external_action_findings == [{
    path: ".github/workflows/ci.yml",
    line: 5,
    ref: "vendor/tool@v1",
    pattern: "vendor/tool@*",
    pinned: false
  }] and
  .configuration_drift == ["workflow_external_action_not_sha_pinned"]
' <<<"$unpinned_action_snapshot" >/dev/null

action_policy_drift_snapshot="$(
  PATH="$test_root/bin:$PATH" \
    MOCK_ACTION_POLICY_DRIFT=1 \
    PORTFOLIO_HEALTH_CONCURRENCY=1 \
    "$repository_root/automation/scripts/portfolio-health.sh" getyak
)"

jq -e '
  .actions_allowlist.missing_patterns == ["vendor/tool@*"] and
  .actions_allowlist.unexpected_patterns == ["other/tool@*"] and
  .configuration_drift == [
    "actions_allowlist_missing_pattern",
    "actions_allowlist_unexpected_pattern"
  ]
' <<<"$action_policy_drift_snapshot" >/dev/null

printf 'portfolio-health tests passed\n'
