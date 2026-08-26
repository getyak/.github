# Daily Getyak Operations Triage

Run once on weekdays in `Asia/Shanghai`. This is a read-mostly control loop.

1. Read `AUTOMATION.md`, `automation/registry.yml`, and
   `automation/slack-routing.md` from `getyak/.github`.
2. Run `automation/scripts/portfolio-health.sh` or perform equivalent read-only
   checks with GitHub CLI for every public, non-archived repository.
3. Inspect only newly failing or still-unresolved workflow runs, deployment
   failures, high/critical Dependabot alerts, code-scanning alerts, and missing
   security coverage. Inspect failure steps before classifying them.
4. Check the automation host for disk pressure, memory pressure, unhealthy
   containers, stopped required services, and expiring certificates. Never
   include secret values or private data in output.
5. Compare each finding with the latest `#ops` threads. Reuse an unresolved
   thread with the same fingerprint; do not create a duplicate root.
6. Post immediately only for new SEV-1/2 findings. Otherwise create at most one
   concise daily digest in `#ops`. If there is no actionable change, post
   nothing.
7. Put scoped engineering work in `#build`, preferably as a reply linking the
   original `#ops` thread. Do not deploy, rotate secrets, change permissions,
   grant OAuth access, or send external communications without explicit human
   approval.
8. When evidence confirms recovery, reply once to the original incident and
   mark the state resolved. Never infer recovery from elapsed time.

The final task result must state what changed since the previous run, what was
posted, and what requires a human decision. Silence is a valid successful run.
