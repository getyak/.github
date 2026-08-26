# Slack Routing and Message Contract

Slack is the control surface for attention, discussion, and approval. It is not
the database for automation state. Every message must link back to durable
evidence in GitHub, an Eval artifact, or an operator runbook.

## Channel routes

| Channel | Send | Do not send |
| --- | --- | --- |
| `#hq` | One weekly portfolio summary; a decision that needs a human; a material launch or incident postmortem | Raw CI, dependency-update failures, routine deploys, model traces |
| `#build` | A scoped `@Codex` task; a pull request ready for review; a release or deploy requiring approval; the final release result | Every commit, every successful job, duplicate PR updates |
| `#signals` | Eval regressions with a baseline; clustered user evidence; a measurable product trend; a weekly Eval digest | Unsupported ideas, raw private content, individual flaky tests |
| `#ops` | New actionable CI or scheduled-job failure; production degradation; high/critical security debt; host-capacity risk; recovery for a prior alert | Green runs with no prior incident, known repeated failures as new roots, full logs |
| `#lounge` | No automated messages | All automation |

## One incident, one thread

The root message uses this compact contract:

```text
[SEV] repository / surface — outcome
Why it matters: one sentence
Evidence: durable URL
Owner: person or automation
Next: one reversible action, approval request, or explicit blocked state
Fingerprint: repository:workflow-or-eval:failure-class
```

The fingerprint stays stable until the cause changes. Subsequent occurrences,
diagnosis, approval, execution, and recovery are thread replies. Do not open a
second root message for the same unresolved fingerprint.

## Severity and interruption budget

- **SEV-1:** confirmed production or data-safety impact. Send immediately to
  `#ops`; surface the required human decision in `#hq` only if one exists.
- **SEV-2:** release blocker, repeated scheduled-job failure, high/critical
  security exposure, or a machine-health condition that threatens automation.
  Send to `#ops` during working hours, or immediately when production is at
  risk.
- **SEV-3:** isolated CI regression, flaky test, or non-urgent configuration
  drift. Include in the next digest unless it blocks active work.
- **INFO:** successful routine activity. Keep in GitHub. Only reply with a
  recovery when it closes an existing incident.

At most one daily operational digest and one weekly Eval digest may create new
summary roots. Immediate SEV-1/2 incidents are exempt.

## Eval routing

An Eval notification must contain:

- suite and dataset version;
- candidate and baseline revisions;
- deterministic metric or grader result;
- delta and threshold;
- artifact URL;
- known uncertainty or sample-size limitation;
- proposed next experiment.

Models may explain a grader result, but the message must distinguish measured
facts from model interpretation. A regression enters `#signals`; it enters
`#build` only when there is a scoped implementation task.

## Approval reactions

Reactions are acknowledgements, not general-purpose authorization:

- `:eyes:` means an owner is investigating.
- `:white_check_mark:` means evidence was reviewed or an incident is resolved.
- `:no_entry:` means stop or reject the proposed action.

Production deploys, permission changes, secret rotation, OAuth connections, and
external communications require an explicit human message that names the
action and target. A reaction alone is insufficient.

## Codex and ChatGPT roles

- Use **Codex in `#build`** for repository-scoped diagnosis, implementation,
  tests, and pull requests. Start from a message containing the repository,
  desired outcome, constraints, and evidence URL.
- Use **ChatGPT** for cross-channel synthesis, canvases, and decision summaries.
  Keep it out of private or data-heavy channels unless the task requires that
  context and the access is explicitly approved.
- Use **GitHub in Slack** for linked pull-request and run context. Prefer the
  native artifact link over mirroring every GitHub event into Slack.

## Retention and redaction

Never paste secrets, signing material, full environment dumps, raw user data,
or private-repository file contents into Slack. Redact tokens and personal data
before sharing a log excerpt. Prefer an access-controlled artifact URL and a
short diagnosis.
