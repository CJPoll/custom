# Eval noise band — when a numeric eval delta can be trusted (DND-225)

**Kind: dated record.** Measured and written 2026-09-24. It records the A/A noise
band of the admiral eval, the method, and the delta rule derived from it. The
code of the rule is `ai/lib/eval_score.rb`; the raw numbers are
`ai/eval/noise-band.json`.

## Result, first

- **Numeric score.** Each sampled case scores its pass-rate `k/n` with a Wilson
  95% interval. The aggregate is the mean per-case pass-rate over sampled (T2)
  cases. An unmeasured case is `n/a`, never 0. `admiral-eval --run` prints this
  block with a corpus fingerprint. `variant-eval --corpus full` prints each
  case's score for both sides.
- **Noise threshold (the delta rule).** For each case, take the Newcombe
  hybrid-score 95% interval for `p_var - p_base`.
  - Regression = the interval lies below 0 **or** `p_base - p_var > 0.3` (the
    DND-174 pilot envelope).
  - Improvement = the interval lies above 0 **and** `p_var - p_base > 0.3`.
  - Anything else is **inconclusive**: inside the noise band.
  - A case measured on one side only is `n/a` (`:new`, never an improvement) or
    fails closed (`:missing`, a regression).
- **Measured band (A/A, current admiral).** Of 25 model-sampled cases:
  - 23 never failed: 0 failures in 940 samples. Each is at least 0.91 (Wilson
    lower bound).
  - **AE-18-refused-spawn-is-pause** is the one stochastic case: 31/40,
    p = 0.78, 95% interval [0.63, 0.88].
  - **AE-19c-drained-after-last-return** never passed: 0/40. This is a defect,
    not noise, and its flip rate is 0.
  - The deterministic eval (harness-eval, T1 hook cases) has zero variance
    across 5 runs.
- **Recommended N: 10 samples per side** (variant-eval's default). At N=10 the
  rule's false-REVERT probability per A/A comparison is 0.029 at the point
  estimates. It is 0.127 in the pessimistic worst case. At K=3 (admiral-eval's
  default) it is 0.30, from AE-18 alone. A K=3 REVERT is therefore expected
  noise about one comparison in three.

## Why the rule is asymmetric

`variant-eval` is not a gate, but its REVERT verdict is a safety signal: never
trade a known regression for an unproven gain. So DND-225 may only make it
**more cautious**:

- Regression keeps the pilot envelope and **adds** the statistical rule (OR).
  Nothing the pilot flagged goes unflagged. At larger N the interval also
  catches smaller drops the pilot missed. For example, 30/30 → 24/30 is Δ=0.2:
  the pilot misses it, the interval does not.
- Improvement needs **both** rules (AND). A KEEP claim only gets harder. For
  example, 5/10 → 9/10 clears the pilot, but its interval includes 0.

The cost is known: at small N the pilot envelope alone produces noise REVERTs
(3/3 → 2/3 is Δ=0.33). The table below prices it. The remedy is more samples,
not a looser rule.

## Method

1. **Fix the input.** All runs used harness rev `ee53cab` and the admiral render
   sha `623d9db8…` (499 lines). That sha was recorded before and after every
   run and did not change. The corpus fingerprint was `8c2097cbac69` (26 cases:
   25 T2 + 1 T1). The fixtures and the agent are byte-identical at `61418c7`.
2. **Deterministic part (no model).** `harness-eval` ran 5×: one distinct
   pass-set. AE-13a (T1 hook-stdin) ran 5×: 5/5. Variance is 0 by
   construction, and the measurement confirms it.
3. **Model part (A/A).** `admiral-eval --run --runs 20` ran twice concurrently
   (R1, R2). AE-01 and AE-02 each got 10 extra samples. Total: 1020 admiral
   calls, 0 invocation failures, about 66 minutes of wall time. Tokens: `n/a`,
   because admiral-eval discards claude's usage report.
4. **Per-case estimate.** Each case's samples were pooled across R1 and R2. The
   stated interval is Wilson 95%, chosen because it behaves at `k = 0` and
   `k = n`, where most of this corpus sits.
5. **Delta noise.** Two numbers:
   - **Observed:** the rule classified R1 against R2 (N=20 each). 0 of 25 cases
     were conclusive. AE-18's 17/20 vs 14/20 has d = −0.15, interval
     [−0.39, 0.11]: inconclusive.
   - **Expected:** `EvalScore.aa_false_regression_rate(p, N)` gives the exact
     probability, over two Binomial(N, p) draws, that the rule calls a
     regression.

### Why N=20 per run

At N=20, a case that passes every sample has a Wilson lower bound of 0.84. Two
runs pool to N=40, which gives 0.91. That is enough to tell a stable case
(≥ 0.9) from a stochastic one. AE-18 is separated cleanly: its interval upper
bound is 0.88. Going further buys little. The lower bound for n/n rises slowly
(0.93 at 50/50), and the table shows N beyond 10–20 does not lower the
false-REVERT rate. The original budget cap was lifted mid-run by the owner.
This N was chosen to characterize the band, not to minimise calls.

### A/A false-REVERT probability per comparison

"Point" uses each case's point estimate. Stable cases then contribute 0, so the
corpus rate is AE-18's. "Worst" puts AE-18 at 0.625 and all 23 stable cases at
their Wilson lower bound (0.912), each independent. This is deliberately
pessimistic.

| N per side | AE-18 alone | corpus, point | corpus, worst | smallest statistically detectable drop from n/n |
|---|---|---|---|---|
| 3  | 0.303 | 0.303 | 0.994 | 3 (only 3/3 → 0/3) |
| 5  | 0.123 | 0.123 | 0.691 | 3 |
| 10 | 0.029 | 0.029 | 0.127 | 4 (10/10 → 6/10) |
| 15 | 0.028 | 0.028 | 0.236 | 4 |
| 20 | 0.024 | 0.024 | 0.153 | 5 |
| 30 | 0.024 | 0.024 | 0.241 | 5 |

The worst-case column is not monotone in N. At larger N the statistical rule
becomes sensitive enough to fire on a true p of 0.91. N=10 is the knee.

## What is comparable, and what is n/a

- **Comparable:** any run at the same subject sha **and** the same corpus
  fingerprint. `admiral-eval --run` now prints the fingerprint on its score
  line.
- **Not comparable:** `ai/eval/admiral-baseline.json`. It was captured
  2026-09-20 against admiral sha `76505fe5` (496 lines), with 19 cases at K=3.
  Its AE-02 2/3 was the flaky case that motivated this ticket. On today's agent
  AE-02 is 50/50. That difference is a subject change, not a measured
  improvement.
- **Not comparable:** `ai/eval/critic-baseline.json`. The critic judge was not
  re-run here: `n/a`. Its N=3 history stands under its own prompt revision.
- **A/B deltas:** `n/a`. DND-225 measured A/A only. A T2 A/B delta is
  comparable only when both refs are at or after `35be30f` (DND-503: each side
  evaluates its own render), with each side's subject sha recorded.
  `variant-eval` prints both shas.

## Confidence and limits

- Each stable case: true pass-rate ≥ 0.91 at 95% (per case, not
  simultaneous).
- The corpus false-REVERT rate at N=10 lies between 0.029 (point) and 0.127
  (worst). The point figure rests on the 23 stable cases being truly ≥ 0.99,
  which 0/940 supports (pooled upper bound 0.0041) if they share one rate.
- The band holds for **this** subject and corpus. A new or edited fixture has
  no measured rate: it is `n/a` until sampled. An agent change can move any
  case, as AE-02 showed. Re-measure with the same commands after either.
- Samples are assumed independent. R1 and R2 ran concurrently against the same
  API. Nothing measured suggests correlation (0 invocation failures), but this
  was not tested.
