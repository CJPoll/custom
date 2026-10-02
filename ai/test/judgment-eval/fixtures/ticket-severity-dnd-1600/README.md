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

**Later (2026-10-02):** v2 shipped and was kept by coordinator judgement
(gen_saas #683). Its single-sample runs `3a82162e` (this set), `c035bcdb`
(the second set) and `946decd4` (H) passed items 2-6 and 8 and missed 1
(5/11) and 7 (139 above). The rest of this file is the v3 bar.

## The bar for `ticket-severity-v3` (registered before any v3 run)

Coordinator decision, recorded on DND-1600 before any v3 run:

1. Every number is measured with `judgment-eval --repeat 3`.
2. v3 is no worse than live v2 on every one of the 8 items above.
3. On H, MEDIUM recall is at least 57/90 (v1's level).
4. The live one-level-up cases on DND-1600 are added as labelled cases.

**The live set L** (item 4). Every `ticket_severity` call a filer
corrected after the eight in this set (strong `field_changed`, a
correction, the payload kept), sent with the exact ticket state the live
call sent and labelled with the correction: 25 calls (5 on v1, 20 on v2).
Plus DND-1648 (filer LOW) and DND-1653 (filer MEDIUM), where Jev's value
was set and the filer's level survives in prose only; their bodies are the
page text with the Jev sentence removed. 27 cases: 26 one level up, 1 one
level under (LOW 15, MEDIUM 12). L holds real ticket text, so it is
machine-local and never committed:
`~/.local/share/athena/evals/dnd-1600v3-live-corpus.jsonl` and
`dnd-1600v3-live-labels.jsonl` beside it (sha256 `c3288991…` and
`e1a3ba1e…`).

**How a case is read with 3 samples.** A case's reading is the level at
least 2 of its 3 samples gave. A case with no such level, or with any
sample unscored, is n/a. An n/a case counts against the version it was
measured on: it is not right, it counts as moved (item 3), and a HIGH- or
CRITICAL-labelled n/a counts as below (items 5 and 8). It counts as
neither above nor below in item 7's "above" count. Every n/a is reported
by case, and `judgment-eval`'s own verdicts (match, miss, unstable) are
reported too.

**Comparison.** v2 and v3 are each run at `--repeat 3` on A (this set), B
(the second set), H and L, with the same files. Each item is a number per
version, and v3's must be no worse than v2's:

| item | number compared |
|---|---|
| 1 | U (the 11 cases above) right; and U plus L's 26 one-level-up cases (37) right |
| 2 | CRITICAL controls kept (of 5); cases labelled below CRITICAL read CRITICAL |
| 3 | of the 16 v1-exact cases in A+B, how many moved; how many moved two levels |
| 4 | `under-2`'s reading (not below MEDIUM) |
| 5 | HIGH- or CRITICAL-labelled cases in A+B read below v1's reading |
| 6 | A+B HIGH precision; A+B accuracy |
| 7 | H cases read above their label; H right |
| 8 | H HIGH-labelled cases read below HIGH |

Plus bar item 3: H MEDIUM recall at least 57/90. L's accuracy, per-label
recall and over/under counts are reported for both versions. v3 is
measured as a candidate (`--question-set-version ticket-severity-v3`,
DND-1608) before it is registered.

## v2 baseline at `--repeat 3` (2026-10-02, before any v3 run)

`ticket-severity-v2`, `jev-1.13.0`. Runs `e84417cf` (A), `56f3509d` (B),
`b4a7446b` (L) and `bcbab906` (H). The v1 readings for items 3 and 5 are
the v1 runs of record above (`a16c9454`, `b8729379`).

| item | v2 |
|---|---|
| 1 | U 4/11; U plus L-up 7/37 |
| 2 | CRITICAL kept 5/5; read CRITICAL below that label 0 |
| 3 | 1 of 16 moved (`OVR-4`, one level); none two levels |
| 4 | `under-2` HIGH (`under-1` MEDIUM) |
| 5 | 0 |
| 6 | HIGH precision 7/13; accuracy 21/29 |
| 7 | 133 above; 125/281 right |
| 8 | 5 |
| bar 3 | H MEDIUM recall 48/90 |

- Verdicts (match / miss / unstable / n/a): A 6/2/0/0, B 15/5/1/0, L
  3/24/0/0, H 117/152/11/1. One H case (`DND-1399`) has no 2-of-3 reading.
- L: 3/27 right, 23 above, 1 below. LOW recall 2/15, MEDIUM 1/12; 10 read
  HIGH.
- H per label: LOW recall 63/172, precision 63/82; MEDIUM 48/90, 48/137;
  HIGH 14/19, 14/61.

**Later (2026-10-02):** `ticket-severity-v3` measured as a candidate
(`--repeat 3`, `jev-1.13.0`; runs `014d843f` A, `6481f987` B, `fe7cdcac` L,
`e065da3f` H). It missed the bar and was not strictly no worse than v2, so
it was not registered.

| item | v2 | v3 |
|---|---|---|
| 1 | U 4/11; U+L-up 7/37 | 5/11; 24/37 |
| 2 | 5/5; 0 | 5/5; 0 |
| 3 | 1 moved; 0 two | 2 moved (`OVR-2`, `OVR-4`); 0 two |
| 4 | `under-2` HIGH | MEDIUM |
| 5 | 0 | 1 (`OVR-2`) |
| 6 | 7/13; 21/29 | 5/9; 19/29 |
| 7 | 133 above; 125/281 | 122 above; 141/281 |
| 8 | 5 | 4 |
| bar 3 | 48/90 | 53/90 |

`ticket-severity-v4` (coordinator decision, the last iteration) is v3
plus three clause fixes aimed at the four controls v3 moved down:

1. Demand computed against a configured limit counts as HIGH exhaustion
   (`OVR-2`).
2. A test that has already turned main or a gate red is HIGH, even when a
   re-run cleared it (`under-2`).
3. LOW's "not reached" does not cover a test that can flake today or an
   unchecked production capacity question (`under-1`, `OVR-4`).

v4 is measured against this same v3 bar, unchanged: the same files, the
same 2-of-3 reading rule, and the v2 baseline above. It is a candidate
only and is not registered here.
