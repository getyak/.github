# Weekly Getyak Eval Review

Run once each Friday in `Asia/Shanghai`.

1. Read the control-plane policy in `getyak/.github`.
2. For each active product, read its `eval_contract` from
   `automation/registry.yml`, then verify the declared suite, command, workflow,
   and evidence path against the repository's current default branch. The
   product repository remains authoritative; registry data is a discovery
   contract, not proof that a gate ran.
3. Classify maturity exactly as declared. `ci_gated` requires a successful
   run and retrievable evidence; `versioned_manual` is coverage debt until an
   equivalent run is observed; `deterministic_test_proxy` is useful evidence
   but must never be described as a product-quality Eval.
4. Compare the newest candidate with its declared baseline. Never compare
   incomparable datasets or silently substitute a missing baseline.
5. Record suite version, dataset version, sample size, metric, threshold,
   candidate revision, baseline revision, delta, artifact URL, and uncertainty.
6. Route real regressions or meaningful improvements to one weekly `#signals`
   digest. Put implementation work in `#build` only when it can be expressed as
   a bounded task with acceptance evidence.
7. Escalate to `#hq` only when a result changes a product decision, release
   decision, safety boundary, or portfolio priority. Do not copy the full
   `#signals` digest.
8. Treat a missing contract, missing baseline, missing required CI run, skipped
   secret-dependent job, or stale declared path as coverage debt, never as a
   passing result. Propose the smallest representative fixture and one
   deterministic metric.
9. Do not expose raw candidate, journal, customer, conversation, or location
   data in Slack. Use synthetic fixtures or access-controlled artifacts.

If nothing changed materially, post nothing and return a concise no-change
result to the automation task.
