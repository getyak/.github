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
   changes, secret rotation, account linking, and external messages always
   retain a human checkpoint.
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
from automated Slack summaries.

## Operator entry points

- Run `automation/scripts/portfolio-health.sh` for a read-only JSON Lines
  snapshot of current public-repository health.
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
