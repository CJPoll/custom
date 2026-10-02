# ticket_blocking live-override fixture (DND-1607)

The second measurement set for ticket_blocking question-set versions, used
beside `../ticket-blocking-dnd-1579/`. That set stays byte-identical, so its
v1, v2 and v3 runs stay comparable. This one holds what was learned after it.
One case is one (finding, candidate) pair. Every text is paraphrased or
synthetic; refs are `TKT-93xx` placeholders.

- `live-1..3`: paraphrases of the three distinct live calls whose `blocks`
  answer the filer overrode to `does_not_block` after the DND-1579 fixture
  was cut. Call fb06b4f2 (ticket-blocking-v1), then 663d2531 and a90f7e48
  (ticket-blocking-v2). The label is the filer's decision (`tracker_record`).
  In all three the candidate is the same activation ticket. Its paraphrase
  keeps the summary the server was sent, superseded eval and shadow steps
  included, unlike `override-3` in the DND-1579 set, whose candidate states
  the waiver outright.
- `control-7`: a finding that truly blocks that same activation ticket: the
  feature it switches on loses every routed conversation. It guards against a
  version that learns "never block an activation ticket".
- `control-8`: live-1's finding against a ticket whose only deliverable is
  running that eval. It truly blocks. It guards against a version that
  learns "an eval-tool defect never blocks".

Controls are labelled `rule_confirmed` by `dnd-1607-synthetic-control`.

Measurement only. Never `--apply` a run of this set: five cases cannot
calibrate a threshold, and the labels are not the owner's.

```
ai/bin/judgment-eval --use-case ticket_blocking \
  --labels ai/test/judgment-eval/fixtures/ticket-blocking-dnd-1607/labels.jsonl \
  --corpus ai/test/judgment-eval/fixtures/ticket-blocking-dnd-1607/corpus.jsonl
```

## The ticket-blocking-v3 bar (stated 2026-10-01, before any run)

Run both sets against the deployed version, more than 60 s apart.

Accept v3 only if all of these hold:

1. DND-1579 set: `override-2` and `override-4` match their labels.
2. DND-1579 set: `override-1` and `override-3` still match.
3. DND-1579 set: all six controls still match (10 of 10 overall).
4. This set: `control-7` and `control-8` match.
5. This set: at least 2 of `live-1..3` match.

Otherwise revert to ticket-blocking-v2.

The review round, before any v3 run, added `control-8` and replaced item
5's second half ("no live case v2 got right is lost"): v2 got only live-2
right, and that at confidence 0.02 (see below), so the clause measured
nothing.

## v2 baselines (ticket-blocking-v2, jev-1.13.0)

| case | label | c7a0e5c0 (4 cases) | 076b2ebe (5 cases) |
|---|---|---|---|
| live-1 | does_not_block | blocks 0.60 | blocks 0.64 |
| live-2 | does_not_block | blocks 0.09 | does_not_block 0.02 |
| live-3 | does_not_block | blocks 0.57 | blocks 0.59 |
| control-7 | blocks | blocks 0.98 | blocks 0.98 |
| control-8 | blocks | n/a (not yet added) | blocks 0.78 |

live-2 sits at the decision boundary and flips between runs.

## The ticket-blocking-v4 bar (stated 2026-10-02, before any v4 run)

### v2 baseline, `--repeat 3` (ticket-blocking-v2, jev-1.13.0)

Measured with `ai/bin/judgment-eval --repeat 3` (DND-1637), never
`--apply`, against the deployed v2. These verdicts replace the
single-sample baselines above for every comparison below.

DND-1579 set, 02:38:42Z, runs 7e0ccddb, 2c81046a, 6778cc18: 8 of 10 match.

| case | label | verdict | samples |
|---|---|---|---|
| control-1-required-gate-red | blocks | match | blocks 1.00, 0.99, 0.98 |
| control-2-missing-dependency | blocks | match | blocks 0.95, 0.93, 0.96 |
| control-3-dropped-column | blocks | match | blocks 0.97, 0.97, 0.97 |
| control-4-severe-unrelated | does_not_block | match | does_not_block 1.00, 1.00, 1.00 |
| control-5-same-area-cosmetic | does_not_block | match | does_not_block 1.00, 1.00, 1.00 |
| control-6-optional-job-flake | does_not_block | match | does_not_block 0.99, 0.99, 0.99 |
| override-1-race-residual | does_not_block | match | does_not_block 0.21, 0.34, 0.27 |
| override-2-ordering-residual | does_not_block | miss | blocks 0.35, 0.43, 0.42 |
| override-3-sibling-eval | does_not_block | match | does_not_block 0.89, 0.90, 0.87 |
| override-4-ci-red-every-pr | blocks | miss | does_not_block 0.38, 0.46, 0.40 |

This set, 02:44:17Z, runs b5d44376, 9cf5d3a7, ee642d7b: 2 of 5 match.

| case | label | verdict | samples |
|---|---|---|---|
| control-7-activation-path-broken | blocks | match | blocks 0.97, 0.97, 0.98 |
| control-8-eval-only-deliverable | blocks | match | blocks 0.78, 0.76, 0.80 |
| live-1-eval-grammar-lag | does_not_block | miss | blocks 0.65, 0.65, 0.61 |
| live-2-eval-undeployed-version | does_not_block | unstable | blocks 0.15, blocks 0.10, does_not_block 0.01 |
| live-3-router-claim-not-freed | does_not_block | miss | blocks 0.52, 0.52, 0.51 |

An earlier run of this set, 02:40:50Z (833090a9, c6e041db, 4ba16388),
started 6 s after the DND-1579 run ended, so it broke the 60 s spacing and
is not the baseline. It read the same except live-2: miss (blocks 0.10,
0.19, 0.04). Either way live-2 did not match under v2.

No new ticket_blocking feedback since 2026-10-01 19:00Z names a new call:
the four rows (c5ead76b, 04d0d496, eafde618, 4c8d8d2b) are two reports
each of calls 663d2531 and a90f7e48, already live-2 and live-3. No case
was added.

### The bar

- Measured with `--repeat 3` on both sets, against the deployed version,
  runs more than 60 s apart.
- Verdict counting: only `match` counts as right. `unstable` counts as NOT
  right (a miss for the bar). `n/a` means the bar could not be measured:
  re-run that set once; a second `n/a` is "could not measure", reported,
  never scored as 0 or as a pass.
- Item ordering for "no worse": match > unstable > miss.

Accept ticket-blocking-v4 only if all of these hold:

1. DND-1579 set: at least 8 of 10 match (v2's count).
2. No override case lost: every `override-N` that matched in the v2
   baseline above (override-1, override-3) still matches.
3. All six DND-1579 controls match, and `control-7` and `control-8` match.
4. No `live-N` case that matched in the v2 baseline is lost (none did, so
   this item is met by any result).
5. At least one case that did not match in the v2 baseline (override-2,
   override-4, live-1, live-2, live-3) now matches. Otherwise v4 changes
   nothing.

Otherwise: if v4 is no worse than v2 on every case (by the ordering
above), the admiral reports to the coordinator before any revert. If it is
worse on any case, revert to ticket-blocking-v2.

Item 1 stays 8 even if a v2 repeat-3 baseline reads below 8 of 10. Never
lower an item. Here the baseline read exactly 8.

### Scoring a v4 run

After ticket-blocking-v4 deploys, run the two sets more than 60 s apart:

```
ai/bin/judgment-eval --use-case ticket_blocking --repeat 3 \
  --labels ai/test/judgment-eval/fixtures/ticket-blocking-dnd-1579/labels.jsonl \
  --corpus ai/test/judgment-eval/fixtures/ticket-blocking-dnd-1579/corpus.jsonl
ai/bin/judgment-eval --use-case ticket_blocking --repeat 3 \
  --labels ai/test/judgment-eval/fixtures/ticket-blocking-dnd-1607/labels.jsonl \
  --corpus ai/test/judgment-eval/fixtures/ticket-blocking-dnd-1607/corpus.jsonl
```

1. Every `sample K of 3` line names `question set ticket-blocking-v4`.
   Any other version means v4 is not deployed: stop, nothing is scored.
2. Read each set's `per-case verdicts over 3 samples:` block. One line per
   case: `<id> (<label>): <verdict> [...]`.
3. Any `n/a` verdict: re-run that set once, more than 60 s later. A second
   `n/a` is "could not measure"; report it and score nothing.
4. Check items 1 to 5 above against the two blocks, and compare each case
   with its baseline row by match > unstable > miss.
