#!/usr/bin/env bash
set -euo pipefail

for required_command in jq sed; do
  command -v "$required_command" >/dev/null || {
    echo "$required_command is required" >&2
    exit 2
  }
done

repository_root="$(cd "$(dirname "$BASH_SOURCE")/../.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/codex-task-lint-test.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

write_valid_task() {
  cat >"$1" <<'TASK'
# Codex task

Repository: getyak/daypage
Environment: getyak-daypage
Slack channel: #build
Source thread: https://getyak.slack.com/archives/C0123456789/p1234567890123456
Fingerprint: daypage:task:issue-904
Outcome: Make the backend static checks runner-portable.
Evidence: https://github.com/getyak/daypage/issues/904

## Constraints

- Preserve the current test semantics.

## Acceptance

- The backend static check and pull-request checks pass.

## Rollback / recovery

- Revert the pull request if the check changes semantics.

## Human boundary

- Do not deploy, expose secrets or credentials, change permissions or OAuth,
  communicate externally, or proceed without an explicit human message.
TASK
}

assert_rejected() {
  local task_path="$1"
  local expected="$2"
  if CODEX_TASK_ALLOW_PENDING_TARGET=true \
    "$repository_root/automation/scripts/codex-task-lint.sh" "$task_path" \
    >"$test_root/stdout" 2>"$test_root/stderr"; then
    echo "expected task to be rejected: $expected" >&2
    exit 1
  fi
  grep -Fq "$expected" "$test_root/stderr"
}

valid_task="$test_root/valid.md"
write_valid_task "$valid_task"

if "$repository_root/automation/scripts/codex-task-lint.sh" "$valid_task" \
  >"$test_root/stdout" 2>"$test_root/stderr"; then
  echo "pending target unexpectedly passed without test override" >&2
  exit 1
fi
grep -Fq 'not ready' "$test_root/stderr"

valid_output="$(CODEX_TASK_ALLOW_PENDING_TARGET=true \
  "$repository_root/automation/scripts/codex-task-lint.sh" "$valid_task")"
jq -e '
  .valid == true and
  .repository == "getyak/daypage" and
  .environment == "getyak-daypage" and
  .integration_state == "pending_verification"
' <<<"$valid_output" >/dev/null

stdin_output="$(CODEX_TASK_ALLOW_PENDING_TARGET=true \
  "$repository_root/automation/scripts/codex-task-lint.sh" - <"$valid_task")"
jq -e '.valid == true and .repository == "getyak/daypage"' <<<"$stdin_output" >/dev/null

environment_task="$test_root/environment.md"
cp "$valid_task" "$environment_task"
sed -i.bak 's/Environment: getyak-daypage/Environment: getyak-other/' "$environment_task"
assert_rejected "$environment_task" "Environment does not match"

rollback_task="$test_root/rollback.md"
cp "$valid_task" "$rollback_task"
sed -i.bak '/^## Rollback \/ recovery$/,/^## Human boundary$/ { /^-/d; }' "$rollback_task"
assert_rejected "$rollback_task" "Rollback / Recovery must contain a list item"

secret_task="$test_root/secret.md"
cp "$valid_task" "$secret_task"
sed -i.bak 's/Preserve the current test semantics./Preserve token github_pat_ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890./' "$secret_task"
assert_rejected "$secret_task" "possible GitHub token"

source_task="$test_root/source.md"
cp "$valid_task" "$source_task"
sed -i.bak 's#https://getyak.slack.com/archives/C0123456789/p1234567890123456#https://example.invalid/thread#' "$source_task"
assert_rejected "$source_task" "getyak Slack message permalink"

mutable_evidence_task="$test_root/mutable-evidence.md"
cp "$valid_task" "$mutable_evidence_task"
sed -i.bak 's#https://github.com/getyak/daypage/issues/904#https://github.com/getyak/daypage/blob/main/README.md#' "$mutable_evidence_task"
assert_rejected "$mutable_evidence_task" "issue, pull request, run, commit, or immutable blob"

excluded_task="$test_root/excluded.md"
cp "$valid_task" "$excluded_task"
sed -i.bak 's#getyak/daypage#getyak/signing#g' "$excluded_task"
assert_rejected "$excluded_task" "not an approved Codex target"

echo "Codex task lint tests passed"
