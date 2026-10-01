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
4. This set: `control-7` matches.
5. This set: at least 2 of `live-1..3` match, and no live case v2 got right
   is lost.

Otherwise revert to ticket-blocking-v2.
