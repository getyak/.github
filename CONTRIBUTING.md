# Contributing to Getyak

Thank you for taking the time to improve a Getyak project.

Getyak repositories range from product foundations and public design
specifications to working applications. Read the target repository's README,
local contribution guide, and agent instructions before making a change.
Repository-specific instructions override this default guide.

## Before opening an issue

First check existing issues and documentation. A useful issue contains:

- **User job:** who is trying to do what?
- **Observed behavior:** what happened, including the smallest reproducible
  example when relevant?
- **Evidence:** logs, screenshots, exact copy, or test output with sensitive
  data removed.
- **Desired outcome:** what would a successful result make possible?
- **Boundary:** what should the product explicitly not do?

Feature requests that describe only a solution may be reframed around the
underlying user decision before they are accepted.

## Before opening a pull request

1. Choose the smallest complete change that can be reviewed and verified.
2. Explain the user-facing outcome and the tradeoff you chose.
3. Add or update tests, fixtures, screenshots, or other proportionate proof.
4. Run the repository's documented checks.
5. Update documentation when behavior, contracts, setup, or product language
   changes.

A pull request description should answer:

- What changed?
- Why is this the smallest useful change?
- How was it verified?
- What remains intentionally out of scope?
- Does it affect privacy, security, human approval, or external side effects?

## AI-assisted contributions

AI assistance is welcome, but authorship still carries responsibility.

- Review generated code and prose before submitting it.
- Do not present model output as evidence.
- Document new model-dependent behavior, failure modes, and human checkpoints.
- Keep deterministic tests or fixtures around consequential behavior whenever
  possible.
- Preserve required attribution and comply with dependency licenses.

## Data and privacy

Use synthetic or explicitly authorized data in code, fixtures, screenshots, and
issues. Do not commit:

- credentials, tokens, or private configuration;
- real candidate, customer, or conversation data;
- personal journals, raw archives, or precise location history;
- third-party content that you do not have the right to redistribute.

If a report contains a vulnerability or sensitive data, follow
[SECURITY.md](SECURITY.md) instead of opening a public issue.

## Review standard

We favor changes that are:

- grounded in a real user job;
- inspectable and reversible;
- explicit about uncertainty and state;
- narrow enough to test;
- honest about what exists today.

Maintainers may close work that is unsafe, untestable, unrelated to the product
boundary, or broader than the repository can responsibly support.
