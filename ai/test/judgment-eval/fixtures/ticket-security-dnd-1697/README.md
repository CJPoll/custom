# ticket_security quality-gate fixture (DND-1697)

**Kind: dated record (2026-10-02).**

A labelled set for comparing `ticket_security` question-set versions with
`ai/bin/judgment-eval`. Every ref, path, sha and phrase is synthetic or
paraphrased; refs are `TKT-97xx` placeholders, the sha is made up.

- `override-1..4`: paraphrases of the four filer overrides of
  `ticket-security-v1` (security corrected to none). Each subject is a
  harness quality control, not an access control: a per-machine config
  resolver (`override-1`, call 9999b07b), test PATH stubs that fall through
  (`override-2`, call 353126de), a push to main with no gate receipt
  (`override-3`, call 703e0b76), and a stub check that misses helper
  functions (`override-4`, call bda05af4). Label `none`, the filer's value.
- `control-1..9`: paraphrases of nine tickets the filer kept at `security`,
  from the 2026-09-30 tracker corpus. Five are harness or app guards close
  to the boundary v2 draws (a secret-boundary scanner run as a test, an
  eval sandbox's push block, a forge-identity guard, a stash guard, an
  unenforced installer rule); four are plain exposures or hardening (a token
  in a crash report, a token in process state, pre-auth body parsing, Slack
  display spoofing). Label `security`.
- `untagged-3..7`: controls 3 to 7 with their self-labels removed. Seven of
  the nine controls name their own label ("(security)", "[security]",
  "(hardening)", "Exposure path:", "Classification: a security control"),
  so a match on them shows little about an untagged boundary ticket. The
  untagged copies keep the same facts and hedges without those words.
  Label `security`. Added in the review round, before any v2 run; the v1
  baseline below was re-run on all 18 cases.

The paraphrases keep only what the original said, with the same hedges
("No live leak observed", "no concrete exploit shown", "grants no access the
agent did not already have").

Measurement only. Never `--apply` a run of this set: eighteen cases cannot
calibrate a threshold.

```
ai/bin/judgment-eval --use-case ticket_security --repeat 3 \
  --labels ai/test/judgment-eval/fixtures/ticket-security-dnd-1697/labels.jsonl \
  --corpus ai/test/judgment-eval/fixtures/ticket-security-dnd-1697/corpus.jsonl
```

Add `--question-set-version ticket-security-v2` to score the candidate once
a deploy carries it (DND-1608). Space runs more than 60 s apart (the server
judges 60 calls a minute).

## The held-out set

v2's criteria were written from the overrides above, so a pass here is
in-sample: necessary, not sufficient. The held-out set H is the tracker
corpus `ai/bin/ticket-corpus` wrote on 2026-09-30, before any of the four
overrides: 324 cases, 27 `security` and 297 `none`. Every label is weak (an
agent filer set it), and nine of the 27 are this set's controls. It holds
real ticket text, so it is machine-local and never committed:
`~/.local/share/athena/evals/ticket-security-{corpus,labels}.jsonl`.
Run it with `--repeat 1` (324 judged calls per run).

`score-held-out.rb` (beside this README; it reads run files, which hold no
input) scores items 3 and 4:

```
ruby ai/test/judgment-eval/fixtures/ticket-security-dnd-1697/score-held-out.rb \
  <v1 H run file> <v2 H run file> ~/.local/share/athena/evals/ticket-security-labels.jsonl
```

## The ticket-security-v2 bar (committed before any v2 run)

This bar decides whether the version change ships: whether a later change
moves v2 from `QuestionSets.candidates/0` into `registered/0`. It is not a
mode or threshold gate. Once registered, v2 runs `on` at once and its
wrong-rate judges it (gen_saas ADR 22 rule 7).

Measured against the deployed v1 and the deployed v2 candidate on the same
files. This set with `--repeat 3`; H with `--repeat 1`.

- Verdict counting on this set: only `match` counts as right. `unstable`
  counts as not right. `n/a` means the bar could not be measured: re-run
  that set once; a second `n/a` is "could not measure", reported, never
  scored as 0 or as a pass.
- On H a case is right when its one answer equals its label. A case
  unscored in either run is n/a, named, and left out of BOTH versions'
  counts; v1's count in items 3 and 4 is over the cases scored in both runs.

Register v2 only if all hold:

1. All four overrides match (`none` in every sample). The ticket names
   them as the regression set.
2. All nine controls and all five untagged controls match (`security` in
   every sample). Every one of them matched under v1.
3. On H, the `security` cases v2 judges `security` are at least v1's count
   minus 1, both over the cases scored in both runs.
4. On H, the `none` cases v2 judges `security` are at most v1's count,
   over the cases scored in both runs.

Otherwise v2 stays an unregistered candidate and the ticket is reopened
with the per-case table. Nothing needs reverting: a candidate never reaches
the product path.

## v1 baseline (`ticket-security-v1`, `jev-1.13.0`, 2026-10-02)

All 18 cases, `--repeat 3`, runs `cdadd151`, `a08b2685`, `149ec8d2`
(07:41Z to 07:43Z): match 14, miss 4, unstable 0, n/a 0.

| case | label | v1 (3 samples) |
|---|---|---|
| override-1 | none | miss: security 0.19, 0.20, 0.10 |
| override-2 | none | miss: security 0.74, 0.73, 0.73 |
| override-3 | none | miss: security 0.32, 0.32, 0.35 |
| override-4 | none | miss: security 0.48, 0.49, 0.50 |
| control-1..9 | security | match, confidence 0.99 to 1.00 |
| untagged-3 | security | match, 0.98 |
| untagged-4 | security | match, 0.99 to 1.00 |
| untagged-5 | security | match, 0.91 to 0.93 |
| untagged-6 | security | match, 0.94 to 0.96 |
| untagged-7 | security | match, 1.00 |

The first 13 cases were also run before the review round (runs `3c11eef3`,
`3216cffa`, `2232edbb`, 07:18Z), with the same verdicts.

H, `--repeat 1`, run `08ce8aee` (07:21Z to 07:27Z, after the first bar
commit): scored 323, unscored 1 (`rate_limited_local`, DND-1381, a `none`
case). `security` cases judged `security`: 26/27. `none` cases judged
`security`: 43/296. If v2's run leaves no other case unscored, item 3 needs
at least 25 and item 4 at most 43; otherwise the scorer recomputes both
over the cases scored in both runs.
