# Getyak Automation Control Plane

This repository is the durable policy layer for automation that spans Getyak
projects. Product repositories still own their builds, tests, deployments, and
release approvals. This repository owns the shared language used to observe
those systems and route the smallest useful signal to people.

## Operating contract

Every automation follows the same loop:

1. **Observe** an immutable source such as a workflow run, test artifact,
   security alert, deployment, or machine-health snapshot.
2. **Normalize** it into a repository, environment, severity, fingerprint,
   owner, and evidence URL.
3. **Evaluate** whether the event is new, actionable, and above the channel's
   threshold. A model may summarize evidence but may not invent it.
4. **Route** one root message to the channel named in
   [`automation/slack-routing.md`](automation/slack-routing.md). Later updates
   remain in that thread.
5. **Approve** any consequential action. Production deploys, permission
   changes, secret rotation, account linking, host updates or restarts, and
   external messages always retain a human checkpoint.
6. **Execute and verify** the approved action against the original source.
7. **Close the loop** in the original thread with the observed recovery or a
   concise statement of what remains blocked.

## Default boundaries

- Slack is an attention and approval surface, not the source of truth.
- GitHub remains the source of truth for code, CI, releases, and security.
- Eval artifacts remain versioned with the product that produces them.
- Private signing repositories, credentials, raw customer content, journals,
  candidate conversations, and precise location data are never copied into
  Slack.
- A green recovery message is sent only when an earlier alert existed.
- Repeated failures with the same fingerprint update one thread instead of
  creating new messages.

## Repository map

The public portfolio and its routing metadata live in
[`automation/registry.yml`](automation/registry.yml). Private credential and
signing repositories are deliberately excluded from that public registry and
from automated Slack summaries. Every active product also declares an
`eval_contract` with a maturity level, primary suite, reproducible command,
evidence location, CI workflow (when present), acceptance statement, privacy
boundary, and explicit coverage gap. These fields guide discovery; the product
repository and immutable run artifacts remain the source of truth.

The desired one-environment/one-repository mapping for Slack-driven Codex work
lives in [`automation/codex-targets.yml`](automation/codex-targets.yml). A
target marked `pending_verification` or `paused` is not runnable. Every request
must pass the fail-closed
[`automation/codex-task-contract.md`](automation/codex-task-contract.md) before
an operator mentions `@Codex`.

## Operator entry points

- Run `automation/scripts/portfolio-health.sh` for a read-only JSON Lines
  snapshot of current public-repository health. Its `recent_failed_runs` field
  contains only the latest decisive failure for each workflow on the default
  branch; superseded, pull-request-only, and GitHub-internal dynamic runs stay
  out of `#ops`. Security API state remains the authority for CodeQL,
  Dependabot, and secret-scanning coverage.
  Code-scanning output includes both total and severity counts so high or
  critical debt cannot be hidden by a portfolio-wide total. The
  `configuration_drift` field also reports missing secret scanning, push
  protection, Dependabot security updates, immutable Action pins, or read-only
  default workflow permissions. It also verifies that each repository permits
  only GitHub-owned Actions plus the exact external Action repositories used on
  its default branch. External references must remain pinned to full commit
  SHAs; the allowlist uses `owner/action@*` so Dependabot can propose a new SHA
  without granting a new vendor. Missing, stale, or broadly verified-creator
  allowlist entries are configuration drift. Every public repository must also
  keep an active ruleset on its default branch that blocks deletion and
  non-fast-forward updates and gates changes through a pull request with
  resolved review threads or a merge queue. Only organization administrators
  may retain an emergency bypass. The `workflow_supply_chain` field also scans
  default-branch workflow sources for remote scripts piped directly into a
  shell (including shell process substitution); scan failures and matches are
  configuration drift rather than a silent clean result.
- Run `automation/scripts/registry.test.sh` after changing repository
  lifecycle, Eval metadata, or Codex targets. Every active product must keep a
  complete, machine-readable Eval discovery contract and exactly one desired
  Codex environment mapping.
- Run `automation/scripts/codex-task-lint.sh TASK.md` before dispatching a
  Slack task to Codex. It rejects ambiguous, secret-bearing, unapproved, or
  unverified targets and requires the source thread, acceptance evidence,
  recovery path, and human boundary.
- Run `automation/scripts/codex-review-health.sh` for a read-only JSON Lines
  inventory of Codex environment readiness, applicable `AGENTS.md` files, and
  repository-owned `## Code Review Rules` coverage.
- Run `automation/scripts/eval-health.sh` before the weekly Eval review. It
  proves the declared suite and workflow exist on the default branch, finds a
  successful run where the exact Eval job and step actually executed, verifies
  the declared artifact when required, and emits `complete`, `partial`, or
  `invalid` JSON Lines without reading secrets.
- Use [`automation/prompts/daily-ops.md`](automation/prompts/daily-ops.md) for
  daily CI, dependency, security, and host triage.
- Use [`automation/prompts/weekly-eval.md`](automation/prompts/weekly-eval.md)
  for the weekly cross-product Eval review.
- Follow [`automation/slack-routing.md`](automation/slack-routing.md) when
  introducing a new notification or Slack-driven command.

## Change standard

Control-plane changes should be proposed through a pull request. Include a
sample input, the expected route, the deduplication fingerprint, the human
approval boundary, and the evidence used to verify the behavior.
