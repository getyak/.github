# Daily Getyak Operations Triage

Run once on weekdays in `Asia/Shanghai`. This is a read-mostly control loop.

1. Read `AUTOMATION.md`, `automation/registry.yml`, and
   `automation/slack-routing.md` from `getyak/.github`.
2. Run `automation/scripts/portfolio-health.sh` or perform equivalent read-only
   checks with GitHub CLI for every public, non-archived repository.
3. Run `automation/scripts/codex-review-health.sh`. Treat an environment that
   changed from `ready` to another state or a newly missing review rule as
   configuration drift. Known `pending_verification` setup is planned debt and
   must not create repeated hourly or daily incidents.
4. Review `configuration_drift`. Secret scanning, push protection, Dependabot
   security updates, read-only default workflow permissions, and immutable
   Action SHA enforcement are the expected public-repository baseline. Each
   repository must allow only GitHub-owned Actions plus the exact external
   Action repositories its default branch uses; verified creators are not a
   blanket exception. The default branch must also block deletion and force
   pushes and require a pull request with resolved review threads or a merge
   queue, with no bypass outside organization administrators. Treat missing or
   stale allowlist entries, a missing branch ruleset, an unavailable
   `workflow_supply_chain` scan, an unpinned external Action, or any remote
   script piped directly into a shell as configuration drift requiring
   inspection.
5. Inspect only newly failing or still-unresolved workflow runs, deployment
   failures, high/critical Dependabot alerts, code-scanning alerts, and missing
   security coverage. Treat `recent_failed_runs` as default-branch candidates,
   not proof of an incident, and inspect failure steps before classifying them.
6. Check the automation host for disk pressure, memory pressure, unhealthy
   containers, stopped required services, and expiring certificates. Read the
   cached macOS update inventory and reject it as stale when its successful scan
   is older than 48 hours. A restart update is maintenance debt, not an incident;
   include it only when its version differs from the last version recorded after
   a verified digest post. Never include secret values or private data in output.
7. Compare each finding with the latest `#ops` threads. Reuse an unresolved
   thread with the same fingerprint; do not create a duplicate root.
8. Post immediately only for new SEV-1/2 findings. Otherwise create at most one
   concise daily digest in `#ops`. If there is no actionable change, post
   nothing.
9. Put scoped engineering work in `#build`, preferably as a reply linking the
   original `#ops` thread. Build the request from
   `automation/templates/codex-task.md` and require
   `automation/scripts/codex-task-lint.sh` to pass before mentioning `@Codex`.
   Do not deploy, rotate secrets, change permissions, grant OAuth access,
   install system updates, restart the host, or send external communications
   without explicit human approval naming the action and target.
10. When evidence confirms recovery, reply once to the original incident and
   mark the state resolved. Never infer recovery from elapsed time.

The final task result must state what changed since the previous run, what was
posted, and what requires a human decision. Silence is a valid successful run.
