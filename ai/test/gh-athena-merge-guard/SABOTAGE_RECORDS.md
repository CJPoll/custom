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

---

## 2026-09-26 — DND-741: `gh api` ref writes put commits on a branch with no check

- **Code under test:** `ai/lib/gh-merge-guard.sh` (`gmg_api_guard`,
  `gmg_api_ref_route`, `GMG_REF_MUTATIONS`), `ai/hooks/forge-identity-guard.sh`
  (`api_ref_write`)
- **Suites:** as above.
- **Baseline (fixed code):** wrapper `RESULT: 136 passed, 0 failed`; hook
  `RESULT: 162 passed, 0 failed`.

### Fail-first: the suites against the unfixed sources (a4b8c68)

The current tests, with the worktree's sources still at a4b8c68 (tests edited,
no source edited yet).

Wrapper: `RESULT: 106 passed, 30 failed`. Every ref-write case failed; every
negative case (N*, NR*) passed. Verbatim:

```
FAIL  R1. REST: PATCH git/refs/heads/main (move the default branch)
      rc=0 out=stub:\ passthrough\ api\ -X\ PATCH\ repos/CJPoll/gen_saas/git/refs/heads/main\ -f\ sha=b712de1d0000000000000000000000000000beef\ -F\ force=true err='' ...
FAIL  R14. REST: PUT contents/<path> (a commit on a branch)
      rc=0 out=stub:\ passthrough\ api\ -X\ PUT\ repos/CJPoll/gen_saas/contents/lib/a.ex\ -f\ message=x\ -f\ content=eA==\ -f\ branch=main err='' ...
FAIL  RG1. GraphQL: createCommitOnBranch via -f query=
      rc=0 out=stub:\ passthrough\ api\ graphql\ -f\ query=mutation\ \{\ createCommitOnBranch\(...
FAIL  RG9. GraphQL: --input with the name in \u escapes
      rc=0 out=stub:\ passthrough\ api\ graphql\ --input\ /tmp/tmp.p5YiXJ7Ydv/ref-body-escaped.json err='' ...
```

Failed set: R1–R18, RG1–RG10, RL1, RD1. (RG11 carries a merge mutation too, so
DND-728 already refused it.)

Hook: `RESULT: 146 passed, 16 failed` — 4a–4n (4a2, 4a3 included), each
`(expected deny) status=0 out=[]`.

Three DND-728 negatives moved, because the ref-write scope now covers them:
N3 (`PUT pulls/<n>/update-branch`, now R17), N5 (`PATCH git/refs/heads/merge-x`,
now a GET) and N13 (a `%`-escaped `PUT contents/…`, now a `%`-escaped labels
PUT; M3 still turns it red). Hook 2n (`PUT …/update-branch`, now 4h) moved to a
labels PUT the same way.

### Mutations on the fixed code

| Mutation | Cases that fail |
| --- | --- |
| M10 ref mutations dropped from the GraphQL scan | RG1–RG10 |
| M11 a plain DELETE of a ref refused too | NR4 |
| M12 the DELETE exception matches `DELETE with a method-override header` | R10 |
| M13 the contents rule removed | R14, R15 |
| M14 the update-branch rule removed | R17 |
| M15 the rename rule removed | R16 |
| M16 every scanned name reported as a merge (ref Fix lost) | RG1–RG10 |
| M17 `git/ref` (singular) not matched | R11 |
| M18 no `.json`/`;x` suffix strip on the ref route | R12 |
| H2 hook ref-write deny removed | 4a–4n |
| H3 hook refuses a plain DELETE of a ref | 4p |
| H4 hook treats an explicit `-X GET` as a write | 4q |
| H5 hook ignores fields (no default POST) | 4b |
| H6 hook ignores the method-override header | 4d |
