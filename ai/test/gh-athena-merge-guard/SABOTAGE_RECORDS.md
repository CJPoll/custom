# Sabotage records — gh-athena merge guard

A test is not finished until you have watched it fail. Each row below is a
mutation applied to a COPY of `ai/bin` + `ai/lib` (the suite ran against the
copy with `GH_ATHENA_UNDER_TEST`). The working tree was never mutated.

## How to use this

Pick a row. Re-apply the mutation to a copy. The named cases should fail. If one
still passes, the check it protects has stopped being load-bearing, and the row
is now a bug report.

---

## 2026-09-26 — DND-728: `gh api` merges bypass the DND-609 guard

- **Code under test:** `ai/lib/gh-merge-guard.sh` (`gmg_api_guard`,
  `gmg_api_path`, `gmg_api_merge_route`), `ai/hooks/forge-identity-guard.sh`
- **Suites:** `bash ai/test/gh-athena-merge-guard/self-test.sh` (no network;
  stub `gh` on PATH), `sh ai/hooks/forge-identity-guard.self-test.sh`
- **Baseline (fixed code):** `RESULT: 94 passed, 0 failed`;
  hook `RESULT: 139 passed, 0 failed`

### Fail-first: the suites against the unfixed sources (d2fb1c9)

`ai/bin`, `ai/lib` and `ai/hooks` from d2fb1c9, current tests.

Wrapper: `RESULT: 50 passed, 44 failed`. Every REST, GraphQL, unreadable-input,
alias and dry-run merge case failed; every negative (N*) case passed. Verbatim:

```
FAIL  A1. REST: api -X PUT repos/<o>/<r>/pulls/<n>/merge
      rc=0 out=stub:\ passthrough\ api\ -X\ PUT\ repos/CJPoll/gen_saas/pulls/388/merge err='' calls=api\ -X\ PUT\ repos/CJPoll/gen_saas/pulls/388/merge
FAIL  A18. REST: POST repos/<o>/<r>/merges (branch merge, no PR)
      rc=0 out=stub:\ passthrough\ api\ -X\ POST\ repos/CJPoll/gen_saas/merges\ -f\ base=main\ -f\ head=feat ...
FAIL  G1. GraphQL: mergePullRequest via -f query=
      rc=0 out=stub:\ passthrough\ api\ graphql\ -f\ query=mutation\ \{\ mergePullRequest\(...
FAIL  G7. GraphQL: --input file (JSON body)
      rc=0 out=stub:\ passthrough\ api\ graphql\ --input\ $TMP/merge-body.json ...
```

Failed set: A1–A22, G1–G12, U1–U6, F1, F2, L1, D1.

Hook: `RESULT: 129 passed, 10 failed` — 2d–2l and 2k2, each
`(expected deny) status=0 out=[]`.

### Fail-first: the salvaged WIP (61b1fe1) against the final tests

The first draft of the fix failed open on its own internal errors and misread
an inline `-F` value: `RESULT: 88 passed, 4 failed` — G12, F1 (scan scratch
file cannot be made), F2 (the scan's grep exits 2, read as "no merge"), N11.

### Mutations on the fixed code

| Mutation | Cases that fail |
| --- | --- |
| M1 `--input` read with `cat` instead of `jq -r '.. \| strings'` | G8, U5 |
| M2 method not upper-cased | N12 |
| M3 no %-decoding | N13 |
| M4 X-HTTP-Method-Override header ignored | A17 |
| M5 grep exit >1 read as "no match" | F2 |
| M6 `--input -` not refused | U1 |
| M7 `..` segments kept, not applied | A11 |
| M8 no default POST when fields/`--input` are given | A8, A9 |
| M9 an unknown `--flag` ignored | A21 |
| H1 hook rule removed (the d2fb1c9 hook) | 2d–2l, 2k2 |
