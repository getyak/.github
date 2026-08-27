#!/usr/bin/env bash
set -euo pipefail

command -v jq >/dev/null || {
  echo "jq is required" >&2
  exit 2
}

repository_root="$(cd "$(dirname "$BASH_SOURCE")/../.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/codex-review-health-test.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT
mkdir -p "$test_root/bin"

cat >"$test_root/targets.yml" <<'YAML'
version: 1
targets:
  example:
    repository: getyak/example
    desired_environment: getyak-example
    repo_map: [getyak/example]
    integration_state: ready
    review_mode: manual_p0_p1_after_setup
YAML

cat >"$test_root/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

[[ "$1" == "api" ]] || exit 1
endpoint="$2"
case "$endpoint" in
  repos/getyak/example)
    printf '%s\n' '{"default_branch":"main"}'
    ;;
  'repos/getyak/example/git/trees/main?recursive=1')
    printf '%s\n' '{"truncated":false,"tree":[{"path":"AGENTS.md","type":"blob","sha":"agents-sha"},{"path":"src/app.ts","type":"blob","sha":"app-sha"}]}'
    ;;
  repos/getyak/example/git/blobs/agents-sha)
    if [[ "${MOCK_NO_RULES:-0}" == "1" ]]; then
      content='# Instructions\n\nKeep tests green.\n'
    else
      content='# Instructions\n\n## Code Review Rules\n\n- Flag unsafe migrations.\n'
    fi
    encoded="$(printf '%b' "$content" | base64 | tr -d '\n')"
    printf '{"content":"%s"}\n' "$encoded"
    ;;
  *)
    exit 1
    ;;
esac
MOCK
chmod +x "$test_root/bin/gh"

snapshot="$(
  PATH="$test_root/bin:$PATH" \
    CODEX_TARGETS_PATH="$test_root/targets.yml" \
    CODEX_REVIEW_API_RETRY_DELAY_SECONDS=0 \
    "$repository_root/automation/scripts/codex-review-health.sh"
)"
jq -e '
  .repository == "getyak/example" and
  .repository_state == "available" and
  .default_branch == "main" and
  .integration_state == "ready" and
  .agents_files == ["AGENTS.md"] and
  .code_review_rules_files == ["AGENTS.md"] and
  .review_debt == []
' <<<"$snapshot" >/dev/null

missing_rules_snapshot="$(
  PATH="$test_root/bin:$PATH" \
    MOCK_NO_RULES=1 \
    CODEX_TARGETS_PATH="$test_root/targets.yml" \
    CODEX_REVIEW_API_RETRY_DELAY_SECONDS=0 \
    "$repository_root/automation/scripts/codex-review-health.sh"
)"
jq -e '
  .code_review_rules_files == [] and
  .review_debt == ["code_review_rules_missing"]
' <<<"$missing_rules_snapshot" >/dev/null

echo "Codex review health tests passed"
