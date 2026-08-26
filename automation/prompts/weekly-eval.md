# Weekly Getyak Eval Review

Run once each Friday in `Asia/Shanghai`.

1. Read the control-plane policy in `getyak/.github`.
2. For each active product, discover versioned Eval suites, deterministic
   fixtures, model graders, CI artifacts, and product-feedback evidence.
3. Compare the newest candidate with its declared baseline. Never compare
   incomparable datasets or silently substitute a missing baseline.
4. Record suite version, dataset version, sample size, metric, threshold,
   candidate revision, baseline revision, delta, artifact URL, and uncertainty.
5. Route real regressions or meaningful improvements to one weekly `#signals`
   digest. Put implementation work in `#build` only when it can be expressed as
   a bounded task with acceptance evidence.
6. Escalate to `#hq` only when a result changes a product decision, release
   decision, safety boundary, or portfolio priority. Do not copy the full
   `#signals` digest.
7. If a repository has no declared Eval contract, report that as coverage debt,
   not as a passing result. Propose the smallest representative fixture and one
   deterministic metric.
8. Do not expose raw candidate, journal, customer, conversation, or location
   data in Slack. Use synthetic fixtures or access-controlled artifacts.

If nothing changed materially, post nothing and return a concise no-change
result to the automation task.
