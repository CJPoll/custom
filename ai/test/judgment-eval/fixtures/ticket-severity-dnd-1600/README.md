# ticket_severity one-level-up fixture (DND-1600)

**Kind: dated record (2026-10-01).**

A labelled set for comparing `ticket_severity` question-set versions with
`ai/bin/judgment-eval`. Every ref, path, sha and phrase is synthetic or
paraphrased; refs are `TKT-9xxx` placeholders.

- `over-1..6`: paraphrases of six owner overrides of `ticket-severity-v1`
  where Jev rated one level up (two for `over-5`). The label is the filer's
  value (`tracker_record`). Calls 78b68848, 4a150e6e, d7784635, 90454c71,
  0a878983 (to LOW) and e110384b (CRITICAL to HIGH).
- `under-1..2`: two overrides in the other direction, kept so a fix for
  the over-rating cannot hide a drop here. Calls 41b70e33 (LOW to MEDIUM)
  and 503dbd4c (MEDIUM to HIGH).

The paraphrases keep only what the original said, with the same hedges
("not a collision today", "No instance has failed in CI yet", "a local dev
credential, not a prod one").

Measurement only. Never `--apply` a run of this set: eight cases cannot
calibrate a threshold.

## The second set

The DND-1590 provenance fixture
(`ai/eval/judgment-fixtures/ticket-severity-provenance`) sent through
`Classify.sent_body`, the body ticket-classify sends (sha256 `b7139e53…`).
It holds the CRITICAL, HIGH, MEDIUM and LOW controls, and five more
one-level-up cases (`OVR-3`, `OVR-5..8`).

```
ai/bin/judgment-eval --use-case ticket_severity \
  --labels ai/test/judgment-eval/fixtures/ticket-severity-dnd-1600/labels.jsonl \
  --corpus ai/test/judgment-eval/fixtures/ticket-severity-dnd-1600/corpus.jsonl
```

Space the two runs more than 60 s apart (the server judges 60 calls a
minute). A case left unscored is n/a, never wrong: re-run that set.

## The held-out set

v2's criteria were written from the cases in the two sets above, so a pass
there is in-sample: necessary, not sufficient. The held-out set H is the
tracker corpus `ai/bin/ticket-corpus` wrote on 2026-09-30, before any of
tonight's overrides, sent through `Classify.sent_body`. It keeps only
`tracker_record` labels (281 cases: LOW 172, MEDIUM 90, HIGH 19, no
CRITICAL); the weak `title_prefix` labels are left out. It holds real
ticket text, so it is machine-local and never committed:
`~/.local/share/athena/evals/dnd-1600-held-out-{corpus,labels}.jsonl`
(sha256 `bdb9e4a1…` and `0bc10bee…`). Some later tickets' filer values may
already follow v1's advice, which biases H toward v1.

## The bar for `ticket-severity-v2` (registered before any v2 run)

The one-level-up cluster U is 11 cases: `over-1..6` here and `OVR-3`,
`OVR-5..8` in the second set. Keep v2 only if all eight hold, comparing
the post-deploy v2 runs with the v1 runs below on the same files:

1. U exactly right: at least 6 of 11.
2. All 5 CRITICAL controls stay CRITICAL, and no case labelled below
   CRITICAL is judged CRITICAL.
3. Of the cases v1 got exactly right, at most 1 moves, and none moves two
   levels.
4. `under-2` is not judged lower than v1's MEDIUM. (`under-1` was LOW under
   v1, so it cannot go lower; it is reported, not gated.)
5. No case labelled HIGH or CRITICAL, in either set, is judged lower than v1
   judged it.
6. HIGH precision and accuracy, over both sets, are strictly above v1's. No
   HIGH prediction at all is a fail, not n/a.
7. On H, the cases judged above their label drop by at least a fifth from
   v1's count, and accuracy is not lower than v1's.
8. On H, HIGH-labelled cases judged below HIGH are at most v1's count
   plus 2.

If any fails, revert v2 in gen_saas (back to `ticket-severity-v1`).

Items 4 to 8 were added in the review round (2026-10-01, about 19:55Z),
after the v1 runs on the two small sets and before the v1 run on H and
any v2 run. Item 1 lost "and v1's count plus 3", which v1's 0/11 made
redundant.

## v1 baseline (`ticket-severity-v1`, `jev-1.13.0`, 2026-10-01)

Runs `a16c9454` (this set) and `b8729379` (the second set). The second
set's labels match DND-1590's two after runs case for case.

| case | label | v1 |
|---|---|---|
| over-1 | LOW | MEDIUM |
| over-2 | LOW | MEDIUM |
| over-3 | LOW | MEDIUM |
| over-4 | LOW | MEDIUM |
| over-5 | LOW | HIGH |
| over-6 | HIGH | CRITICAL |
| under-1 | MEDIUM | LOW |
| under-2 | HIGH | MEDIUM |
| OVR-3 | MEDIUM | HIGH |
| OVR-5..8 | LOW | HIGH (all four) |
| the other 16 of the second set | | exactly right |

- U exactly right: 0/11.
- Both sets: accuracy 16/29, HIGH precision 5/11, CRITICAL 5/5 kept,
  CRITICAL precision 5/6.
- H (runs `c57665f6`, 150 cases before a deploy's HTTP 502 stopped it, and
  `a5fb13dc`, the other 131): accuracy 118/281, 146 judged above their
  label, 17 below, 6 of 19 HIGH judged below HIGH. LOW recall 48/172,
  MEDIUM precision 57/165, HIGH precision 13/55. So item 7 needs at most
  116 above and at least 118/281 right, and item 8 at most 8 HIGH below.
