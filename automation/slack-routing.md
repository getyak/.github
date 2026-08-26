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
| `#ops` | New actionable CI or scheduled-job failure; production degradation; high/critical security debt; host-capacity risk; deduplicated planned-maintenance debt; recovery for a prior alert | Green runs with no prior incident, known repeated failures as new roots, full logs |
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

## Host maintenance routing

- A recommended macOS update that requires restart is planned maintenance debt,
  not an incident. Include it in the daily `#ops` digest only when the available
  version changes; routine hourly sentinels remain silent.
- Use the cached, timestamped update inventory as evidence. A stale or failed
  inventory scan is a host-observability failure, not proof that the machine is
  current.
- Installing an update or restarting the automation host requires an explicit
  human message naming the host, target version, and maintenance window.
- Before execution, verify a fresh off-machine backup and restore drill, drain
  active builds and deployments, and pause stateful automation cleanly. After
  reboot, verify the host-health endpoint and required services before replying
  with recovery.
- If an update exceeds an operator-defined security SLA or blocks a required
  security fix, promote it to one stable `#ops` incident thread. Do not create a
  new root for each scan.

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

Production deploys, permission changes, secret rotation, OAuth connections,
host updates or restarts, and external communications require an explicit human
message that names the action and target. A reaction alone is insufficient.

## Codex and ChatGPT roles

- Use **Codex in `#build`** for repository-scoped diagnosis, implementation,
  tests, and pull requests. Start from a message containing the repository,
  desired outcome, constraints, and evidence URL.
- Use **ChatGPT** for cross-channel synthesis, canvases, and decision summaries.
  Keep it out of private or data-heavy channels unless the task requires that
  context and the access is explicitly approved.
- Use **GitHub in Slack** for linked pull-request and run context. Prefer the
  native artifact link over mirroring every GitHub event into Slack.

### Integration topology

- Install the Codex Slack app only in `#build`. Its GitHub App and Cloud
  environments may access public product repositories listed in the registry,
  but never private signing or credential repositories.
- Keep ChatGPT available for deliberate synthesis and Canvas work. Do not add
  automatic ChatGPT responses to incident channels.
- Link the GitHub Slack app to the public Getyak repositories for rich previews
  and operator commands. In `#build`, subscribe only to `pulls`, `reviews`,
  `releases`, and deployment approvals for actively maintained products.
- Do not subscribe `#ops` to unfiltered `workflows`, `commits`, or every
  repository event. The control loop owns failure-only workflow routing because
  the native workflow subscription reports successful runs too.
- A Codex request must name one repository and one verifiable outcome. The
  resulting pull request is the durable artifact; discussion and approval stay
  in the originating Slack thread.

### Persistent-access checklist

Before an operator installs or reconnects an integration, record and review:

1. the Slack channels the app can read or post to;
2. the exact GitHub repositories the app can access;
3. whether write, workflow, pull-request, or deployment permissions are needed;
4. the human approval boundary and revocation owner; and
5. an end-to-end test that creates no production deployment or secret change.

Use selected-repository access. Re-run this review when a repository becomes
private, begins storing signing material, or changes ownership.

## Retention and redaction

Never paste secrets, signing material, full environment dumps, raw user data,
or private-repository file contents into Slack. Redact tokens and personal data
before sharing a log excerpt. Prefer an access-controlled artifact URL and a
short diagnosis.
