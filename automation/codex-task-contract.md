# Slack to Codex Task Contract

This contract makes a Slack request safe to hand to Codex. It is intentionally
fail closed: a task is not ready merely because it is understandable to a
person.

Codex in Slack can use the most recently used environment when a request is
ambiguous, and a chat runs against the default branch of the first repository
in an environment's repository map. Therefore every Getyak Codex environment
has one repository and every request names both values explicitly. The desired
mapping and its verified state live in
[`codex-targets.yml`](codex-targets.yml). This defensive rule follows the
[official Codex in Slack behavior](https://learn.chatgpt.com/docs/third-party/slack).

## Required envelope

Start from [`templates/codex-task.md`](templates/codex-task.md). A task must
contain:

- exactly one approved public Getyak repository;
- that repository's exact desired Codex environment;
- the originating `#build` Slack thread permalink;
- one stable fingerprint for retries and follow-up;
- one observable outcome and one durable GitHub evidence URL;
- explicit constraints, acceptance checks, and rollback or recovery steps;
- the human boundary for deploys, secrets, permissions, OAuth, external
  communication, and other consequential actions.

Run the local validator before mentioning `@Codex`:

```bash
automation/scripts/codex-task-lint.sh path/to/task.md
```

The validator rejects an environment whose `integration_state` is not `ready`.
`CODEX_TASK_ALLOW_PENDING_TARGET=true` exists only for testing the contract
before an integration is configured; it must not be used to dispatch a real
Slack task.

The resulting pull request is the durable artifact. Diagnosis, approval, and
completion remain replies in the originating Slack thread. A completion link
does not prove acceptance: verify the named checks and evidence before closing
the task.

## Review rollout

Begin with an explicit `@codex review` on selected pull requests. Add two or
three concise, outcome-focused rules under `## Code Review Rules` in the
repository's applicable `AGENTS.md`. Mechanical formatting and test checks stay
in CI. Enable automatic review only after the manual sample demonstrates useful
signal and an acceptable false-positive rate.

The rollout follows the
[official Codex code-review guidance](https://learn.chatgpt.com/docs/third-party/github):
keep repository-specific review instructions concise, and use CI for
mechanical checks and enforcement.

Use `automation/scripts/codex-review-health.sh` for a read-only inventory of
environment readiness and review-rule coverage. A pending integration or
missing review rule is planned setup debt, not an hourly incident.
