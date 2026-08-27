# Codex task

Repository: getyak/REPOSITORY
Environment: getyak-REPOSITORY
Slack channel: #build
Source thread: https://getyak.slack.com/archives/CHANNEL_ID/pTIMESTAMP
Fingerprint: REPOSITORY:task:STABLE_ID
Outcome: Describe one observable repository outcome.
Evidence: https://github.com/getyak/REPOSITORY/issues/ISSUE_NUMBER

## Constraints

- Keep the change within the named repository and outcome.
- Preserve unrelated work and existing compatibility guarantees.

## Acceptance

- Name the exact tests, checks, artifact, or observable behavior that must pass.
- Return the pull request URL in the originating Slack thread.

## Rollback / recovery

- Revert the pull request or disable the new behavior through the documented,
  repository-owned recovery path.

## Human boundary

- Do not deploy, rotate or expose secrets, change permissions or OAuth,
  communicate externally, or perform another consequential action without an
  explicit human message naming the action and target.
