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

Measurement only. Never `--apply` a run of this set: four cases cannot
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
