# ticket_blocking measurement fixture (DND-1579)

A small labelled set for comparing ticket_blocking question-set versions with
`ai/bin/judgment-eval`. One case is one (finding, candidate) pair. Every text
is synthetic or paraphrased; refs are `TKT-9xxx` placeholders.

- `override-1..4`: paraphrases of the four owner overrides of
  `ticket-blocking-v1` that motivated `ticket-blocking-v2`. The label is the
  filer's decision (`tracker_record`). Calls 67925f14, c7755a30 and 75420832
  (blocks -> does_not_block) and ece29d30 (does_not_block -> blocks).
- `control-1..3`: findings that truly block (a required CI gate red on every
  change, a missing endpoint the candidate calls, a dropped column the
  candidate reads).
- `control-4..6`: findings that truly do not block (a severe defect in an
  unrelated subsystem, a cosmetic issue in the candidate's own area, a flake
  in an optional job that never gates a merge).

The paraphrases keep only what the original finding said. Override 1's
original named the contract residual; override 2's did not (only the
filer's note did), so its paraphrase does not either. Override 4's candidate
never mentions CI, as in the original.

Controls are labelled `rule_confirmed` by `dnd-1579-synthetic-control`.

Measurement only. Never `--apply` a run of this set: ten cases cannot
calibrate a threshold, and the labels are not the owner's.

```
ai/bin/judgment-eval --use-case ticket_blocking \
  --labels ai/test/judgment-eval/fixtures/ticket-blocking-dnd-1579/labels.jsonl \
  --corpus ai/test/judgment-eval/fixtures/ticket-blocking-dnd-1579/corpus.jsonl
```

The run line names the server's question-set version. Per-label recall and
precision come from the run file's `labels` and `results`.
