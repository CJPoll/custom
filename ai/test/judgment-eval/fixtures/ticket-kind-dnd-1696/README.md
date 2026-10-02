# ticket_kind coverage-gap fixture (DND-1696)

**Kind: dated record (2026-10-02).**

A labelled set for comparing `ticket_kind` question-set versions with
`ai/bin/judgment-eval`. Built from the `ticket_kind` feedback rows
(`ai/bin/judgment-feedback list --with-payloads`). Every text is paraphrased
or synthetic; refs are `TKT-96xx` placeholders.

- `hard-1..4`: paraphrases of the four distinct `ticket-kind-v1` calls whose
  `bug` answer the filer corrected to `hardening`: calls 40dfbc83, 03c8a73b,
  45de8ba3, 2200b2b5. Each subject is a check or tool with a blind spot, a
  case it was never built to cover, and the ticket says nothing is wrong
  today. Label `Hardening`, provenance `tracker_record`.
- `other-1..5`: the other distinct corrections in the feedback: two to
  `refactor`, one to `test`, one `flake` to `bug`, and one `hardening` to
  `bug` (calls d95beb03, b11fc580, 7dbdbe68, 9be62d7d, 831357e2). v1 is wrong
  on all but `other-5`. They are tracked, not part of the bar: a coverage-gap
  fix is not meant to move them.
- `ctl-1..4`: synthetic `Bug` controls, label `rule_confirmed` by
  `dnd-1696-synthetic-control`. Three are plain defects (wrong total, crash,
  lost event). `ctl-3` is a check that misses a case it was specified to
  catch: it guards the other direction, a version that learns "a check gap is
  never a bug".

A fifth control (`ctl-5`, a plain `Hardening` ticket) was cut before any
candidate run: the server rate-limited it in all three baseline samples
(`rate_limited_local`), so it was n/a and never scored. The set is 13 cases.

Measurement only. Never `--apply` a run of this set: thirteen cases cannot
calibrate a threshold.

```
ai/bin/judgment-eval --use-case ticket_kind \
  --labels ai/test/judgment-eval/fixtures/ticket-kind-dnd-1696/labels.jsonl \
  --corpus ai/test/judgment-eval/fixtures/ticket-kind-dnd-1696/corpus.jsonl \
  --repeat 3 [--question-set-version ticket-kind-v2]
```

Space runs more than 60 s apart. A case left unscored is n/a, never wrong.

## v1 baseline, `--repeat 3` (ticket-kind-v1, jev-1.13.0), 2026-10-02 07:23Z

Runs 6f2735b4, 5fcdad5b, ad7eba5e. Never `--apply`.

| case | label | verdict | samples |
|---|---|---|---|
| hard-1-eval-undeployed-candidate | Hardening | miss | Bug 0.92, 0.92, 0.89 |
| hard-2-credo-bound-phrase | Hardening | miss | Bug 0.97, 0.95, 0.94 |
| hard-3-forge-stub-helper | Hardening | unstable | Vulnerability 0.43, Bug 0.44, Bug 0.54 |
| hard-4-unique-index-audit-one-way | Hardening | miss | Bug 0.54, 0.58, 0.50 |
| other-1-installer-exit-codes | Refactor | miss | Bug 0.97 x3 |
| other-2-duplicated-regex | Refactor | miss | Bug 0.73, 0.77, 0.76 |
| other-3-selftest-helper-order | Test | miss | Bug 0.97, 0.98, 0.98 |
| other-4-main-red-pipefail-grep | Bug | miss | Flake 0.89, 0.91, 0.89 |
| other-5-changeset-missing-unique | Bug | match | Bug 0.53, 0.54, 0.54 |
| ctl-1-wrong-total | Bug | match | Bug 1.00 x3 |
| ctl-2-crash-on-empty | Bug | match | Bug 1.00 x3 |
| ctl-3-check-misses-specified-case | Bug | match | Bug 1.00 x3 |
| ctl-4-lost-webhook-event | Bug | match | Bug 1.00 x3 |

5 of 13 match, 7 miss, 1 unstable. The 14-case run also held `ctl-5`
(n/a, cut). `other-5` is the one case where the filer chose `bug` for a gap
that is not exercised today, so it sits on the new boundary: it may move to
`hardening` under v2 by design.

## The ticket-kind-v2 bar (stated 2026-10-02, before any v2 run)

- Measured with `--repeat 3` and `--question-set-version ticket-kind-v2`
  (DND-1608), runs more than 60 s apart, never `--apply`.
- Only `match` counts as right. `unstable` counts as NOT right. `n/a` means
  the bar could not be measured: re-run once; a second `n/a` is "could not
  measure", reported, never scored as 0 or as a pass.

Register and activate v2 only if all hold:

1. `hard-1..4` all match `Hardening` (the ticket's regression set: the four
   calls must read `hardening`).
2. `ctl-1..4` all match `Bug` (the v1 bug rows that were right stay `bug`).
3. No case that matched under v1 is lost, except `other-5`, which is watched
   and reported but does not gate.

If 1 reads 3 of 4 and 2 and 3 hold, report to the admiral before any
decision. If any `ctl` case is lost, or 1 reads 2 or fewer, do not register
v2: it was never active, so there is nothing to revert.

`other-1..4` are reported against their v1 verdicts (all miss) and never
gate.
